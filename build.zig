const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("quetzal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = addEchoServer(b, module, target, optimize, "quetzal");
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the echo server");
    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);

    const test_step = b.step("test", "Run unit tests");
    const module_tests = b.addTest(.{ .root_module = module });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    _ = addScript(b, test_step, "lint", "Check the style rules", &.{});
    const conformance = addEchoServer(b, module, target, .ReleaseSafe, "quetzal-conformance");
    const quick = b.option(bool, "quick", "Skip the slow 9.* cases") orelse false;
    const autobahn_args: []const *std.Build.Step.Compile = &.{conformance};
    const run_autobahn = addScript(b, test_step, "autobahn", "Run Autobahn", autobahn_args);
    if (quick) run_autobahn.addArg("quick");

    const perf_server = addEchoServer(b, module, target, .ReleaseFast, "quetzal-perf");
    const floor = b.option(u32, "perf-floor", "Fail below this many messages/s") orelse 0;
    const run_perf = addScript(b, test_step, "perf", "Run the echo benchmark", &.{perf_server});
    run_perf.addArg(b.fmt("{d}", .{floor}));
}

fn addEchoServer(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "quetzal", .module = module }},
        }),
    });
}

fn addScript(
    b: *std.Build,
    test_step: *std.Build.Step,
    name: []const u8,
    description: []const u8,
    artifact_args: []const *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const script = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("scripts/{s}.zig", .{name})),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(script);
    run.setCwd(b.path("."));
    for (artifact_args) |artifact| run.addArtifactArg(artifact);
    b.step(name, description).dependOn(&run.step);
    const script_tests = b.addTest(.{ .root_module = script.root_module });
    test_step.dependOn(&b.addRunArtifact(script_tests).step);
    return run;
}
