const std = @import("std");
const graphql = @import("graphql");

const Config = @import("config.zig").Config;
const IssueKind = @import("main.zig").Issue.Kind;
const assert = @import("assert.zig");

const URL: []const u8 = "https://api.linear.app/graphql";

pub fn client_init(alloc: std.mem.Allocator, api_key: []const u8) !graphql.Client {
    return try graphql.Client.init(
        alloc,
        .{
            .endpoint = .{ .url = "https://api.linear.app/graphql" },
            .authorization = api_key,
        },
    );
}

const RequestError = error{
    RequestFailed,
    NotAuthorized,
};

pub const Teams = struct {
    pub fn get_id_of_config_team(alloc: std.mem.Allocator, config: Config, client: *graphql.Client) ![]const u8 {
        const result = client.sendWithVariables(
            struct {
                filter: struct {
                    key: struct {
                        eq: []const u8,
                    },
                },
            },
            .{
                .query =
                \\query Teams($filter: TeamFilter) {
                \\  teams(filter: $filter) {
                \\    nodes {
                \\      id,
                \\    }
                \\  }
                \\}
                ,
                .variables = .{
                    .filter = .{
                        .key = .{
                            .eq = config.team_key,
                        },
                    },
                },
            },
            struct {
                teams: struct {
                    nodes: []struct {
                        id: []const u8,
                    },
                },
            },
        ) catch |err| {
            std.log.err(
                "Request failed with {any}",
                .{err},
            );
            if (err == error.NotAuthorized) return error.NotAuthorized;
            return error.RequestFailed;
        };

        defer result.deinit();
        switch (result.value.result()) {
            .errors => |errors| {
                for (errors) |err| {
                    std.debug.print("Error: {s}", .{err.message});
                    if (err.path) |p| {
                        const path = std.mem.join(alloc, "/", p) catch unreachable;
                        defer alloc.free(path);
                        std.debug.print(" @ {s}", .{path});
                    }
                }
                return error.RequestFailed;
            },
            .data => |data| {
                if (data.teams.nodes.len == 0) {
                    std.log.err("Team with key '{s}' not found", .{config.team_key});
                    return error.TeamNotFound;
                }
                std.debug.assert(data.teams.nodes.len == 1);
                return try alloc.dupe(u8, data.teams.nodes[0].id);
            },
        }
    }
};

pub const Labels = struct {
    pub const Label = struct {
        kind: IssueKind,
        id: []const u8,

        pub fn format(self: *const Label, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("Label [{s}, .id = {s}]", .{ @tagName(self.kind), self.id });
        }
    };

    pub fn get(alloc: std.mem.Allocator, config: Config, client: *graphql.Client) ![IssueKind.COUNT]Label {
        const result = client.send(
            .{
                .query =
                \\query ListLabels {
                \\  issueLabels {
                \\    nodes {
                \\      id,
                \\      name
                \\    }
                \\  }
                \\}
                ,
            },
            struct {
                issueLabels: struct {
                    nodes: []struct {
                        id: []const u8,
                        name: []const u8,
                    },
                },
            },
        ) catch |err| {
            std.log.err(
                "Request failed with {any}",
                .{err},
            );
            if (err == error.NotAuthorized) return error.NotAuthorized;
            return error.RequestFailed;
        };
        defer result.deinit();
        switch (result.value.result()) {
            .data => |data| {
                var issue_ids = [IssueKind.COUNT]?[]const u8{ null, null };
                for (IssueKind.ALL_ISSUES, 0..) |issue_kind, i| {
                    for (data.issueLabels.nodes) |node| {
                        if (std.mem.eql(u8, node.name, config.label_names.label_name_for(issue_kind))) {
                            issue_ids[i] = try alloc.dupe(u8, node.id);
                        }
                    }
                }
                for (IssueKind.ALL_ISSUES, 0..) |issue_kind, i| {
                    if (issue_ids[i] == null) {
                        std.log.err("Missing label for {s}. Either enter a rename in your fixme.toml or create a new label with the name \"{s}\" on linear", .{ @tagName(issue_kind), config.label_names.label_name_for(issue_kind) });
                        return error.MissingLabel;
                    }
                }
                const labels = [IssueKind.COUNT]Label{
                    .{ .kind = IssueKind.ALL_ISSUES[0], .id = issue_ids[0].? },
                    .{ .kind = IssueKind.ALL_ISSUES[1], .id = issue_ids[1].? },
                };
                return labels;
            },
            .errors => |errors| {
                for (errors) |err| {
                    std.debug.print("Error: {s}", .{err.message});
                    if (err.path) |p| {
                        const path = std.mem.join(alloc, "/", p) catch unreachable;
                        defer alloc.free(path);
                        std.debug.print(" @ {s}", .{path});
                    }
                }
                return error.RequestFailed;
            },
        }
    }
};

pub const Issues = struct {
    pub const NewIssue = struct {
        label_id: []const u8,
        description: ?[]const u8,
        title: []const u8,
        team_id: []const u8,
    };

    fn StringHashMap(comptime T: type) type {
        const Inner = std.StringArrayHashMap(T);
        return struct {
            map: Inner,

            const Self = @This();

            pub fn init(allocator: std.mem.Allocator) Self {
                return .{
                    .map = Inner.init(allocator),
                };
            }

            pub fn keys(self: *const Self) [][]const u8 {
                return self.map.keys();
            }

            pub fn put(self: *Self, key: []const u8, value: T) !void {
                return self.map.put(key, value);
            }

            pub fn jsonStringify(self: *const Self, writer: anytype) !void {
                var items_iter = self.map.iterator();
                try writer.beginObject();
                while (items_iter.next()) |item| {
                    try writer.objectField(item.key_ptr.*);
                    try writer.write(item.value_ptr.*);
                }
                try writer.endObject();
            }
        };
    }

    const Output = struct {
        inner: Inner,

        pub fn init(allocator: std.mem.Allocator) Output {
            return Inner.init(allocator);
        }

        const Item = struct {
            identifier: []const u8,
            title: []const u8,
        };

        const Inner = std.ArrayList(Item);

        pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            {
                const start = try source.next();
                if (.object_begin != start) {
                    std.log.err("Expected object begin, got {s}", .{@tagName(start)});
                    return error.UnexpectedToken;
                }
            }

            var issues_list = Inner.init(alloc);

            while (true) {
                const issue_key_token: ?std.json.Token = try source.nextAllocMax(alloc, .alloc_if_needed, options.max_value_len.?);
                if (issue_key_token == null) {
                    std.log.warn("no created issues", .{});
                    break;
                }
                const issue_key = switch (issue_key_token.?) {
                    .string, .allocated_string => |slice| slice,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };

                // assert the index of the issue_key is the same as the next index in our list of issues
                {
                    const just_prefix = std.mem.trimRight(u8, issue_key, "0123456789");
                    if (just_prefix.len == issue_key.len) {
                        std.log.err("returned issue key `{s}` does not end with index", .{issue_key});
                        return error.UnexpectedToken;
                    }
                    const just_index = issue_key[just_prefix.len..];
                    const parsed_index = std.fmt.parseUnsigned(usize, just_index, 10) catch {
                        std.log.err("returned issue key `{s}` does not end with index", .{issue_key});
                        return error.UnexpectedToken;
                    };
                    assert.eql(parsed_index, issues_list.items.len);
                }
                const value = try std.json.innerParse(struct {
                    issue: Item,
                }, alloc, source, options);

                try issues_list.append(value.issue);
            }
            return .{ .inner = issues_list };
        }
    };

    pub fn create(alloc: std.mem.Allocator, _: Config, client: *graphql.Client, new_issues: []const NewIssue) ![]const Output.Item {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const scratch = arena.allocator();

        const IssueCreateInput = struct {
            teamId: []const u8,
            title: []const u8,
            description: ?[]const u8,
            labelIds: [1][]const u8,
        };
        const Variables = StringHashMap(IssueCreateInput);
        var issues_map = Variables.init(scratch);

        for (new_issues, 0..) |issue, i| {
            try issues_map.put(try std.fmt.allocPrint(scratch, "issue{d}", .{i}), .{
                .teamId = issue.team_id,
                .title = issue.title,
                .description = issue.description,
                .labelIds = .{issue.label_id},
            });
        }

        var query = std.ArrayList(u8).init(scratch);
        {
            var query_writer = query.writer();

            try query_writer.writeAll("mutation CreateMultipleIssues(\n");

            for (issues_map.keys()) |issue_key| {
                try query_writer.print("    ${s}: IssueCreateInput!\n", .{issue_key});
            }
            try query_writer.writeAll(") {\n");

            for (issues_map.keys()) |issue_key| {
                try query_writer.print(
                    \\   {s}: issueCreate(input: ${s}) {{
                    \\      issue {{
                    \\        identifier,
                    \\        title,
                    \\      }}
                    \\   }}
                    \\
                , .{ issue_key, issue_key });
            }

            try query_writer.writeAll("}\n");
        }

        std.debug.print("{s}\n", .{query.items});
        try std.json.stringify(issues_map, .{ .whitespace = .indent_2 }, std.io.getStdErr().writer());

        const result = client.sendWithVariables(Variables, .{
            .query = query.items,
            .variables = issues_map,
        }, Output) catch |err| {
            std.log.err(
                "Create Issues Request failed with {any}",
                .{err},
            );
            if (err == error.NotAuthorized) return error.NotAuthorized;
            return error.RequestFailed;
        };

        defer result.deinit();
        switch (result.value.result()) {
            .data => |data| {
                var created_issues = try alloc.alloc(Output.Item, new_issues.len);
                for (data.inner.items, 0..) |issue, issue_index| {
                    created_issues[issue_index] = .{
                        .identifier = try alloc.dupe(u8, issue.identifier),
                        .title = try alloc.dupe(u8, issue.title),
                    };
                }
                return created_issues;
            },
            .errors => |errors| {
                for (errors) |err| {
                    std.debug.print("Create Issues Error: {s}", .{err.message});
                    if (err.path) |p| {
                        const path = std.mem.join(alloc, "/", p) catch unreachable;
                        defer alloc.free(path);
                        std.debug.print(" @ {s}", .{path});
                    }
                }
                return error.RequestFailed;
            },
        }
    }
};
