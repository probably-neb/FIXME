const std = @import("std");
const config = @import("config.zig");
const linear = @import("linear.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.skip(); // Skip program name

    const path = args.next() orelse return error.NoArgs;
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));

    const comments = try extract_c_style_comments(allocator, contents);
    const issues = try extract_issues(allocator, contents, path, comments);

    std.debug.print("Issues: {any}\n", .{issues});

    if (false) {
        const cfg = try config.load(allocator);
        std.debug.print("Config: {any}\n", .{cfg});

        std.debug.print("API Key: |{s}|\n", .{cfg.api_key});
        var client = try linear.client_init(allocator, cfg.api_key);

        const labels = try linear.Labels.get(allocator, cfg, &client);
        std.debug.print("Labels: {any}\n", .{labels});

        const team_id = try linear.Teams.get_id_of_config_team(allocator, cfg, &client);
        std.debug.print("Team ID: |{s}|\n", .{team_id});
        const fake_issues = [3]linear.Issues.NewIssue{
            .{
                .team_id = team_id,
                .title = "First Issue",
                .description = "Description for first issue",
                .label_id = labels[0].id,
            },
            .{
                .team_id = team_id,
                .title = "Second Issue",
                .description = "Description for second issue",
                .label_id = labels[0].id,
            },
            .{
                .team_id = team_id,
                .title = "Third Issue",
                .description = "Description for third issue",
                .label_id = labels[0].id,
            },
        };

        const created_issues = try linear.Issues.create(allocator, cfg, &client, &fake_issues);
        for (created_issues) |created_issue| {
            std.debug.print("CREATED {s}: {s}\n", .{ created_issue.identifier, created_issue.title });
        }
    }

    var test_identfiers = std.ArrayList(Issue.ID).init(allocator);
    try test_identfiers.ensureTotalCapacity(issues.issues.len);
    const new_prefix: *const Issue.ID.Prefix = "NEW";
    for (issues.issues, 0..) |*issue, issue_num| {
        if (issue.id != null) {
            issue.*.id = null;
        }
        try test_identfiers.append(Issue.ID{
            .prefix = new_prefix.*,
            .num = @intCast(issue_num),
        });
    }

    var dbg_file = try std.fs.cwd().createFile("./account.updated.ts", .{});
    defer dbg_file.close();
    try update_issues_in_txt(allocator, contents, dbg_file.writer(), issues.issues, test_identfiers.items);
}

const Range = struct {
    start: u32,
    end: u32,
    fn new(start: u32, end: u32) @This() {
        return .{ .start = start, .end = end };
    }
};

const Comment = struct {
    txt: Range,
    line: u32,
    col: u32,
    kind: enum {
        Basic,
        Block,
    },
};

fn trim_range(input: []const u8, range: Range) Range {
    var txt = input[range.start..range.end];
    const start: u32 = start: {
        const original_len = txt.len;
        txt = std.mem.trimLeft(u8, txt, " \t/*");
        const len_diff = original_len - txt.len;
        break :start @intCast(range.start + len_diff);
    };

    const end: u32 = end: {
        const original_len = txt.len;
        txt = std.mem.trimRight(u8, txt, " \t\n/*");
        const len_diff = original_len - txt.len;
        break :end @intCast(range.end - len_diff);
    };
    return .{
        .start = start,
        .end = end,
    };
}

fn extract_c_style_comments(allocator: std.mem.Allocator, input: []const u8) ![]const Comment {
    var comments = std.ArrayList(Comment).init(allocator);

    const State = union(enum) {
        None,
        Basic: struct {
            start: u32,
            line: u32,
            col: u32,
        },
        Block: struct {
            start: u32,
            line: u32,
            col: u32,
        },
    };

    var state: State = .None;
    var cur_line: u32 = 0;

    var cur_col: u32 = 0;

    for (input, 0..) |char, char_index_usize| {
        const char_index: u32 = @intCast(char_index_usize);
        switch (state) {
            .None => switch (char) {
                '/' => {
                    if (char_index + 1 < input.len) {
                        switch (input[char_index + 1]) {
                            '/' => {
                                state = .{ .Basic = .{ .start = char_index, .line = cur_line, .col = cur_col + 1 } };
                            },
                            '*' => {
                                state = .{ .Block = .{ .start = char_index, .line = cur_line, .col = cur_col + 1 } };
                            },
                            else => {},
                        }
                    }
                },
                '\n' => {
                    cur_line += 1;
                    cur_col = 0;
                },
                else => {},
            },
            .Basic => |basic| {
                if (char == '\n') {
                    const comment = .{
                        .kind = .Basic,
                        .txt = trim_range(
                            input,
                            .{ .start = basic.start, .end = char_index },
                        ),
                        .line = basic.line,
                        .col = basic.col,
                    };
                    try comments.append(comment);
                    state = .None;
                    cur_line += 1;
                    cur_col = 0;
                }
            },
            .Block => |block| {
                if (char == '*' and char_index + 1 < input.len and input[char_index + 1] == '/') {
                    try comments.append(.{
                        .kind = .Block,
                        .txt = trim_range(
                            input,
                            .{ .start = block.start, .end = char_index + 2 },
                        ),
                        .line = block.line,
                        .col = block.col,
                    });
                    state = .None;
                } else if (char == '\n') {
                    cur_line += 1;
                    cur_col = 0;
                }
            },
        }
        cur_col += 1;
    }

    return comments.items;
}

const Issue = struct {
    kind: Kind,
    txt: []const u8,
    id: ?ID,
    col: u32,
    line_beg: u32,
    line_end: u32,

    pub const Kind = enum {
        FIXME,
        TODO,

        pub const COUNT: u32 = 2;
        pub const ALL_ISSUES = [COUNT]Issue.Kind{ .FIXME, .TODO };

        pub const MAX_LEN: u32 = 5;
        pub const MIN_LEN: u32 = 4;
    };

    const ID = struct {
        prefix: [PREFIX_LEN]u8,
        num: u32,

        const PREFIX_LEN = 3;

        const Prefix = [PREFIX_LEN]u8;
        pub fn format(self: *const ID, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            return writer.print("{s}-{d}", .{ self.prefix, self.num });
        }
    };

    pub fn format(self: *const Issue, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Issue {s} ({d}:{d}-{d})\n", .{ @tagName(self.kind), self.line_beg, self.col, self.line_end });
        const new_prefix: *const ID.Prefix = "NEW";
        try writer.print("\t[{any}] ", .{self.id orelse Issue.ID{ .prefix = new_prefix.*, .num = 0 }});
        var split_iter = std.mem.splitScalar(u8, self.txt, '\n');
        var i: u32 = 0;
        while (split_iter.next()) |line| : (i += 1) {
            if (i > 0) {
                try writer.writeAll("\n\t");
            }
            try writer.writeAll(line);
        }
    }
};

const IssueList = struct {
    file_name: []const u8,
    txt_buf: []u8,
    issues: []Issue,
    allocator: std.mem.Allocator,

    pub fn format(self: *const IssueList, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("IssueList ({s}) [\n", .{self.file_name});
        for (self.issues) |issue| {
            try writer.print("  {any}\n", .{issue});
        }
        try writer.print("]\n", .{});
    }
};

fn extract_issues(allocator: std.mem.Allocator, input: []const u8, file_name: []const u8, comments: []const Comment) !IssueList {
    var issues_txt_buf = std.ArrayList(u8).init(allocator);
    var issues = std.ArrayList(Issue).init(allocator);
    var issue_ranges = std.ArrayList(Range).init(allocator);

    for (comments, 0..) |comment, comment_index_usize| {
        const comment_index: u32 = @intCast(comment_index_usize);
        switch (comment.kind) {
            .Basic => {
                const issue_txt = input[comment.txt.start..comment.txt.end];

                const issue_info = identify_type_and_id(issue_txt);
                if (issue_info) |info| {
                    const txt_start = issues_txt_buf.items.len;
                    try issues_txt_buf.appendSlice(issue_txt);

                    var prev_comment_line_end = comment.line;
                    var next_comment_index: u32 = comment_index + 1;

                    // identify multi-line basic comments
                    // such as this comment
                    while (next_comment_index < comments.len) : (next_comment_index += 1) {
                        const is_next_comment_basic = comments[next_comment_index].kind == .Basic;
                        if (!is_next_comment_basic) break;

                        const next_basic_comment = comments[next_comment_index];
                        const next_basic_comment_txt = input[next_basic_comment.txt.start..next_basic_comment.txt.end];

                        const is_next_comment_on_next_line = next_basic_comment.line == prev_comment_line_end + 1;
                        const has_issue_info = identify_type_and_id(next_basic_comment_txt) != null;
                        if (!is_next_comment_on_next_line or has_issue_info) break;

                        try issues_txt_buf.append('\n');
                        try issues_txt_buf.appendSlice(next_basic_comment_txt);

                        prev_comment_line_end = next_basic_comment.line;
                    }

                    const txt_range = Range{
                        .start = @intCast(txt_start + info.trim),
                        .end = @intCast(issues_txt_buf.items.len),
                    };
                    try issue_ranges.append(txt_range);
                    try issues.append(.{
                        .kind = info.kind,
                        .txt = undefined,
                        .id = info.id,
                        .line_beg = comment.line,
                        .line_end = prev_comment_line_end,
                        .col = comment.col + info.trim,
                    });
                }
            },
            .Block => {
                const issue_txt = input[comment.txt.start..comment.txt.end];
                const issue_info = identify_type_and_id(issue_txt);
                if (issue_info) |info| {
                    const txt_start = issues_txt_buf.items.len;

                    try issues_txt_buf.appendSlice(issue_txt);

                    const line_count = std.mem.count(u8, issue_txt, "\n");

                    const txt_range = Range{
                        .start = @intCast(txt_start + info.trim),
                        .end = @intCast(issues_txt_buf.items.len),
                    };
                    try issue_ranges.append(txt_range);

                    try issues.append(.{
                        .kind = info.kind,
                        .txt = undefined,
                        .id = info.id,
                        .line_beg = comment.line,
                        .line_end = comment.line + @as(u32, @intCast(line_count)),
                        .col = comment.col + info.trim,
                    });
                }
            },
        }
    }

    // cannot create txt slices before issues_txt_buf is full as when it reallocs the previous
    // slices taken die
    for (issues.items, issue_ranges.items) |*issue, range| {
        issue.txt = issues_txt_buf.items[range.start..range.end];
    }

    return IssueList{
        .file_name = file_name,
        .txt_buf = issues_txt_buf.items,
        .issues = issues.items,
        .allocator = allocator,
    };
}

fn identify_type_and_id(txt: []const u8) ?struct { kind: Issue.Kind, id: ?Issue.ID, trim: u32 } {
    if (txt.len < Issue.Kind.MAX_LEN) {
        return null;
    }

    var trim: u32 = 0;

    const kind = if (std.mem.startsWith(u8, txt, "FIXME"))
        Issue.Kind.FIXME
    else if (std.mem.startsWith(u8, txt, "TODO"))
        Issue.Kind.TODO
    else
        return null;

    const id: ?Issue.ID = id: {
        var issue_txt_rest = txt;
        if (std.mem.indexOf(u8, txt, ":")) |colon_idx| {
            trim += @intCast(colon_idx + 1);
            issue_txt_rest = issue_txt_rest[colon_idx + 1 ..];
        }
        const pre_trim_len = issue_txt_rest.len;
        issue_txt_rest = std.mem.trimLeft(u8, issue_txt_rest, " ");
        if (issue_txt_rest.len == 0) break :id null;
        trim += @intCast(pre_trim_len - issue_txt_rest.len);

        const has_open_brace = issue_txt_rest[0] == '[';
        const close_brace_idx = if (has_open_brace) std.mem.indexOfScalar(u8, issue_txt_rest, ']') else null;
        const has_close_brace = close_brace_idx != null;

        if (!has_open_brace or !has_close_brace) break :id null;

        trim += @intCast(close_brace_idx.? + 1);

        const id = std.mem.trim(
            u8,
            issue_txt_rest[1..close_brace_idx.?],
            " ",
        );

        // expect [prefix-num]
        const dash_idx = std.mem.indexOfScalar(u8, id, '-');
        const id_has_dash = dash_idx != null;
        if (!id_has_dash) break :id null;

        const prefix = prefix: {
            const maybe_prefix = id[0..dash_idx.?];
            if (maybe_prefix.len != Issue.ID.PREFIX_LEN) {
                std.log.warn("comment is not valid linear identifier: expected [ABC-123] got {s}", .{id});
                break :id null;
            }

            var prefix_buf: [Issue.ID.PREFIX_LEN]u8 = undefined;
            for (0..Issue.ID.PREFIX_LEN) |i| {
                prefix_buf[i] = maybe_prefix[i];
            }

            break :prefix prefix_buf;
        };

        const num = std.fmt.parseInt(u32, id[dash_idx.? + 1 ..], 10) catch {
            break :id null;
        };

        break :id .{
            .prefix = prefix,
            .num = num,
        };
    };

    {
        const txt_no_info = txt[trim..];
        const txt_no_info_trimmed = std.mem.trimLeft(u8, txt_no_info, " ");

        // add length of leading whitespace to trim
        trim += @intCast(txt_no_info.len - txt_no_info_trimmed.len);
    }

    return .{ .kind = kind, .id = id, .trim = trim };
}

fn update_issues_in_txt(alloc: std.mem.Allocator, txt: []const u8, writer: anytype, issues: []const Issue, identifiers: []const Issue.ID) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    const line_count = std.mem.count(u8, txt, "\n");
    var lines_with_comments = try std.DynamicBitSet.initEmpty(scratch, line_count + 1);
    for (issues) |issue| {
        lines_with_comments.set(issue.line_beg);
    }

    var line_iter = std.mem.split(u8, txt, "\n");
    var line_index: u32 = 0;
    while (line_iter.next()) |line| : (line_index += 1) {
        if (line_index > 0) {
            try writer.writeAll("\n");
        }
        const line_has_comment = lines_with_comments.isSet(line_index);
        if (!line_has_comment) {
            try writer.writeAll(line);
            continue;
        }

        var issue: ?Issue = null;
        var identifier: ?Issue.ID = null;
        for (issues, 0..) |check_issue, issue_index| {
            if (check_issue.line_beg == line_index) {
                issue = issues[issue_index];
                identifier = identifiers[issue_index];
                break;
            }
        }
        std.debug.assert(issue != null);
        std.debug.assert(identifier != null);
        std.debug.assert(line_index == issue.?.line_beg);

        const line_pre = line[0..issue.?.col];
        const line_post = line[issue.?.col..];

        try writer.writeAll(line_pre);
        if (issue.?.col > 0 and line[issue.?.col - 1] != ' ') {
            try writer.writeAll(" ");
        }
        try writer.print("[{s}-{d}]", .{ identifier.?.prefix, identifier.?.num });
        if (line.len > issue.?.col and line[issue.?.col] != ' ') {
            try writer.writeAll(" ");
        }
        try writer.writeAll(line_post);
    }
}
