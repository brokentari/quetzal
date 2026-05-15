const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const server_port: u16 = 9001;
const server_wait_attempts_max: u32 = 100;
const cases_max: u32 = 100_000;
const full_marker = "\"exclude-cases\": []";
const quick_marker = "\"exclude-cases\": [\"9.*\"]";
const index_path = "reports/servers/index.json";

const Tally = struct {
    behaviors: std.StringArrayHashMapUnmanaged(u32) = .empty,
    closes: std.StringArrayHashMapUnmanaged(u32) = .empty,
    failures: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingServerPath;
    const quick = args.len > 2 and std.mem.eql(u8, args[2], "quick");

    const config_path = try prepareReports(gpa, io, quick);
    var server = try std.process.spawn(io, .{
        .argv = &.{args[1]},
        .stdin = .ignore,
    });
    defer server.kill(io);
    try waitForServer(io);
    try runDocker(gpa, io, config_path);

    const passed = try report(gpa, io);
    server.kill(io);
    if (!passed) std.process.exit(1);
}

fn prepareReports(gpa: std.mem.Allocator, io: Io, quick: bool) ![]const u8 {
    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(io, "reports/servers");
    try cwd.createDirPath(io, "reports");
    if (!quick) return "/config/fuzzingclient.json";

    const full = try cwd.readFileAlloc(io, "autobahn/fuzzingclient.json", gpa, .limited(1 << 16));
    defer gpa.free(full);
    const quick_text = try std.mem.replaceOwned(u8, gpa, full, full_marker, quick_marker);
    defer gpa.free(quick_text);
    if (std.mem.eql(u8, full, quick_text)) return error.ConfigMarkerMissing;
    try cwd.writeFile(io, .{ .sub_path = "reports/fuzzingclient.json", .data = quick_text });
    return "/reports/fuzzingclient.json";
}

fn waitForServer(io: Io) !void {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(server_port) };
    for (0..server_wait_attempts_max) |_| {
        if (address.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
            return;
        } else |_| {
            try io.sleep(.fromMilliseconds(100), .awake);
        }
    }
    return error.ServerDidNotStart;
}

fn runDocker(gpa: std.mem.Allocator, io: Io, config_path: []const u8) !void {
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const config_volume = try std.fmt.allocPrint(gpa, "{s}/autobahn:/config", .{cwd_path});
    defer gpa.free(config_volume);
    const reports_volume = try std.fmt.allocPrint(gpa, "{s}/reports:/reports", .{cwd_path});
    defer gpa.free(reports_volume);
    const user = try std.fmt.allocPrint(gpa, "{d}:{d}", .{
        std.os.linux.getuid(),
        std.os.linux.getgid(),
    });
    defer gpa.free(user);

    var child = try std.process.spawn(io, .{ .argv = &.{
        "docker",    "run",          "--rm",
        "--network", "host",         "--user",
        user,        "-v",           config_volume,
        "-v",        reports_volume, "crossbario/autobahn-testsuite",
        "wstest",    "-m",           "fuzzingclient",
        "-s",        config_path,
    } });
    const term = try child.wait(io);
    if (!term.success()) return error.DockerFailed;
}

fn report(gpa: std.mem.Allocator, io: Io) !bool {
    const text = try Io.Dir.cwd().readFileAlloc(io, index_path, gpa, .limited(1 << 26));
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    var tally: Tally = .{};
    defer tally.behaviors.deinit(gpa);
    defer tally.closes.deinit(gpa);

    for (parsed.value.object.values()) |agent_cases| {
        for (agent_cases.object.keys(), agent_cases.object.values()) |id, result| {
            try tallyCase(gpa, &tally, id, result.object);
        }
    }
    for (tally.behaviors.keys(), tally.behaviors.values()) |behavior, count| {
        std.debug.print("behavior {s}: {d}\n", .{ behavior, count });
    }
    for (tally.closes.keys(), tally.closes.values()) |behavior, count| {
        std.debug.print("close {s}: {d}\n", .{ behavior, count });
    }
    return tally.failures == 0;
}

fn tallyCase(
    gpa: std.mem.Allocator,
    tally: *Tally,
    id: []const u8,
    result: std.json.ObjectMap,
) !void {
    assert(id.len > 0);
    const behavior = result.get("behavior").?.string;
    const behavior_close = result.get("behaviorClose").?.string;
    try countBehavior(gpa, &tally.behaviors, behavior);
    try countBehavior(gpa, &tally.closes, behavior_close);
    if (isPass(behavior)) return;
    tally.failures += 1;
    std.debug.print("case {s}: {s}\n", .{ id, behavior });
}

fn countBehavior(
    gpa: std.mem.Allocator,
    counts: *std.StringArrayHashMapUnmanaged(u32),
    name: []const u8,
) !void {
    const entry = try counts.getOrPut(gpa, name);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    entry.value_ptr.* += 1;
}

fn isPass(behavior: []const u8) bool {
    const passing = [_][]const u8{ "OK", "NON-STRICT", "INFORMATIONAL" };
    for (passing) |name| {
        if (std.mem.eql(u8, behavior, name)) return true;
    }
    return false;
}

test "isPass accepts only the passing behaviors" {
    try std.testing.expect(isPass("OK"));
    try std.testing.expect(isPass("NON-STRICT"));
    try std.testing.expect(isPass("INFORMATIONAL"));
    try std.testing.expect(!isPass("FAILED"));
    try std.testing.expect(!isPass("UNIMPLEMENTED"));
}
