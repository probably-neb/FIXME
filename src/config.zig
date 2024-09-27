const std = @import("std");
const toml = @import("toml");

pub const ConfigFile = struct {
    name: []const u8,
    api_key: []const u8,
    label_names: ?LabelNames,
    team_key: []const u8,
};
pub const Config = struct {
    name: []const u8,
    api_key: []const u8,
    team_key: []const u8,
    label_names: LabelNames,

    pub fn format(self: *const Config, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("config.Config {{.name = \"{s}\", .api_key = \"{s}\", .label_names = {any} }}", .{ self.name, self.api_key, self.label_names });
    }
};

pub const LabelNames = struct {
    FIXME: ?[]const u8,
    TODO: ?[]const u8,

    pub fn label_name_for(label_names: *const @This(), issue_kind: @import("main.zig").Issue.Kind) []const u8 {
        return switch (issue_kind) {
            .FIXME => label_names.FIXME orelse "FIXME",
            .TODO => label_names.TODO orelse "TODO",
        };
    }

    pub fn format(self: *const LabelNames, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("config.LabelNames {{.FIXME = \"{s}\", .TODO = \"{s}\" }}", .{ self.label_name_for(.FIXME), self.label_name_for(.TODO) });
    }
};

pub fn load(alloc: std.mem.Allocator) !Config {
    var parser = toml.Parser(ConfigFile).init(alloc);
    defer parser.deinit();

    var result = try parser.parseFile("./fixme.toml");
    defer result.deinit();

    const config = Config{
        .name = result.value.name,
        .api_key = result.value.api_key,
        .label_names = result.value.label_names orelse LabelNames{
            .FIXME = null,
            .TODO = null,
        },
        .team_key = result.value.team_key,
    };
    return config;
}
