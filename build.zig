const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    const graphql = b.dependency("graphql", .{
        .target = target,
        .optimize = optimize,
    }).module("graphql");

    const toml = b.dependency("zig-toml", .{
        .target = target,
        .optimize = optimize,
    }).module("zig-toml");

    var exe = b.addExecutable(.{
        .name = "your-exe",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("graphql", graphql);
    exe.root_module.addImport("toml", toml);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
