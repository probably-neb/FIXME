const std = @import("std");

pub const AssertionError = error{
    AssertionFailed,
};

pub fn eql(a: anytype, b: @TypeOf(a)) void {
    std.testing.expectEqual(a, b) catch |err| {
        std.debug.panic("Assertion Failed: Error {any}: {any} == {any}", .{ err, a, b });
    };
}

pub fn basic(cond: bool) void {
    if (!cond) {
        std.debug.panic("Assertion Failed", .{});
    }
}

pub fn with_message(cond: bool, comptime fmt: []const u8, args: anytype) void {
    if (!cond) {
        std.debug.panic("Assertion Failed: " ++ fmt, args);
    }
}
