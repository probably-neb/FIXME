const std = @import("std");
const graphql = @import("graphql");

const Config = @import("config.zig").Config;
const IssueKind = @import("main.zig").IssueKind;

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
                return data.teams.nodes[0].id;
            },
        }
    }
};

pub const Labels = struct {
    pub const Label = struct {
        kind: IssueKind,
        label_id: []const u8,

        pub fn format(self: *const Label, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("Label [{s}, .id = {s}]", .{ @tagName(self.kind), self.label_id });
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
                            issue_ids[i] = node.id;
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
                    .{ .kind = IssueKind.ALL_ISSUES[0], .label_id = issue_ids[0].? },
                    .{ .kind = IssueKind.ALL_ISSUES[1], .label_id = issue_ids[1].? },
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
