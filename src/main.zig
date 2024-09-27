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

    const comments = try extract_comments(allocator, contents);
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
        const fake_issues = [3]linear.Issues.NewIssue{ .{
            .team_id = team_id,
            .title = "First Issue",
            .description = "Description for first issue",
            .label_id = labels[0].id,
        }, .{
            .team_id = team_id,
            .title = "Second Issue",
            .description = "Description for second issue",
            .label_id = labels[0].id,
        }, .{
            .team_id = team_id,
            .title = "Third Issue",
            .description = "Description for third issue",
            .label_id = labels[0].id,
        } };

        const created_issues = try linear.Issues.create(allocator, cfg, &client, &fake_issues);
        for (created_issues) |created_issue| {
            std.debug.print("CREATED {s}: {s}\n", .{ created_issue.identifier, created_issue.title });
        }
    }
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

fn extract_comments(allocator: std.mem.Allocator, input: []const u8) ![]const Comment {
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
                                state = .{ .Basic = .{ .start = char_index, .line = cur_line, .col = cur_col } };
                            },
                            '*' => {
                                state = .{ .Block = .{ .start = char_index, .line = cur_line, .col = cur_col } };
                            },
                            '\n' => {
                                cur_line += 1;
                                cur_col = 0;
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
                        .txt = .{ .start = basic.start, .end = char_index },
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
                        .txt = .{ .start = block.start, .end = char_index + 2 },
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

pub const IssueKind = enum {
    FIXME,
    TODO,

    pub const COUNT: u32 = 2;
    pub const ALL_ISSUES = [COUNT]IssueKind{ .FIXME, .TODO };

    pub const MAX_LEN: u32 = 5;
    pub const MIN_LEN: u32 = 4;
};

const Issue = struct {
    kind: IssueKind,
    txt: []const u8,
    id: ?[]const u8,
    file_name: []const u8,
    col: u32,
    line_beg: u32,
    line_end: u32,

    pub fn format(self: *const Issue, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Issue {s} ({s}:{d}:{d}-{d})\n", .{ @tagName(self.kind), self.file_name, self.line_beg, self.col, self.line_end });
        try writer.print("\t[{d}] ", .{self.txt.len});
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
    txt_buf: []u8,
    issues: []Issue,
    allocator: std.mem.Allocator,

    pub fn format(self: *const IssueList, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("IssueList [\n", .{});
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
                const issue_txt = std.mem.trim(
                    u8,
                    input[comment.txt.start..comment.txt.end],
                    " \t/",
                );
                const issue_info = try identify_type_and_id(allocator, issue_txt);
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
                        const next_basic_comment_txt = std.mem.trim(
                            u8,
                            input[next_basic_comment.txt.start..next_basic_comment.txt.end],
                            " \t/",
                        );

                        const is_next_comment_on_next_line = next_basic_comment.line == prev_comment_line_end + 1;
                        const has_issue_info = try identify_type_and_id(allocator, next_basic_comment_txt) != null;
                        if (!is_next_comment_on_next_line or has_issue_info) break;

                        try issues_txt_buf.append('\n');
                        try issues_txt_buf.appendSlice(next_basic_comment_txt);

                        prev_comment_line_end = next_basic_comment.line;
                    }

                    const txt_range = Range{
                        .start = @intCast(txt_start),
                        .end = @intCast(issues_txt_buf.items.len),
                    };
                    try issue_ranges.append(txt_range);
                    try issues.append(.{
                        .kind = info.kind,
                        .txt = undefined,
                        .id = info.id,
                        .file_name = file_name,
                        .line_beg = comment.line,
                        .line_end = prev_comment_line_end,
                        .col = comment.col,
                    });
                }
            },
            .Block => {
                const issue_txt = std.mem.trim(
                    u8,
                    input[comment.txt.start..comment.txt.end],
                    " \t/*",
                );
                const issue_info = try identify_type_and_id(allocator, issue_txt);
                if (issue_info) |info| {
                    const txt_start = issues_txt_buf.items.len;

                    try issues_txt_buf.appendSlice(issue_txt);

                    const line_count = std.mem.count(u8, issue_txt, "\n");

                    const txt_range = Range{
                        .start = @intCast(txt_start),
                        .end = @intCast(issues_txt_buf.items.len),
                    };
                    try issue_ranges.append(txt_range);

                    try issues.append(.{
                        .kind = info.kind,
                        .txt = undefined,
                        .id = info.id,
                        .file_name = file_name,
                        .line_beg = comment.line,
                        .line_end = comment.line + @as(u32, @intCast(line_count)),
                        .col = comment.col,
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
        .txt_buf = issues_txt_buf.items,
        .issues = issues.items,
        .allocator = allocator,
    };
}

fn identify_type_and_id(allocator: std.mem.Allocator, txt: []const u8) !?struct { kind: IssueKind, id: ?[]const u8 } {
    if (txt.len < IssueKind.MAX_LEN) {
        return null;
    }
    const issue_txt = std.mem.trim(u8, txt, " \t/*");

    var label = allocator.dupe(u8, issue_txt[0..@min(IssueKind.MAX_LEN, issue_txt.len)]) catch return null;
    label = std.ascii.upperString(label, issue_txt[0..@min(IssueKind.MAX_LEN, issue_txt.len)]);
    defer allocator.free(label);

    const kind = if (std.mem.startsWith(u8, label, "FIXME"))
        IssueKind.FIXME
    else if (std.mem.startsWith(u8, label, "TODO"))
        IssueKind.TODO
    else
        return null;

    var id: ?[]const u8 = null;
    var issue_txt_rest = issue_txt;
    if (std.mem.indexOf(u8, issue_txt_rest, ":")) |colon_idx| {
        issue_txt_rest = issue_txt_rest[colon_idx + 1 ..];
    }
    issue_txt_rest = std.mem.trimLeft(u8, issue_txt_rest, " ");
    if (issue_txt_rest.len == 0) return null;

    if (std.mem.indexOf(u8, issue_txt, ":")) |colon_idx| {
        const rest = std.mem.trim(u8, issue_txt[colon_idx + 1 ..], " ");

        if (std.mem.startsWith(u8, rest, "[")) {
            if (std.mem.indexOf(u8, rest, "]")) |bracket_idx| {
                id = try allocator.dupe(u8, rest[1..bracket_idx]);
            }
        }
    }

    return .{ .kind = kind, .id = id };
}

const CreateAndUpdateIssuesList = struct {
    txt_buf: []const u8,
    new: []const linear.Issues.NewIssue,
    update: []const struct {
        identifier: []const u8,
        kind: IssueKind,
        title: []const u8,
        description: ?[]const u8,
    },
};

// fn split_create_and_update_issues(allocator: std.mem.Allocator, issues: IssueList) !CreateAndUpdateIssuesList {
//
// }
