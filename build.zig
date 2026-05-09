const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("quetzal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "quetzal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "quetzal", .module = module }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the echo server");
    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);

    const test_step = b.step("test", "Run unit tests");
    const module_tests = b.addTest(.{ .root_module = module });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
