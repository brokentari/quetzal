const std = @import("std");
const assert = std.debug.assert;

const line_length_max: u32 = 100;
const function_lines_max: u32 = 70;
const entries_max: u32 = 100_000;
const skipped_directories = [_][]const u8{ ".git", ".zig-cache", "zig-out", "reports" };
const function_prefixes = [_][]const u8{
    "fn ",          "pub fn ",          "inline fn ", "pub inline fn ",
    "noinline fn ", "pub noinline fn ", "export fn ", "pub export fn ",
};

// Built from pieces so this file does not trip its own rules.
const assert_open = "assert" ++ "(";
const catch_empty = "catch " ++ "{}";
const catch_discard = "catch " ++ "|_|";

const Counts = struct {
    failures: u32 = 0,
    usize_uses: u32 = 0,

    fn fail(counts: *Counts, path: []const u8, line_number: u32, message: []const u8) void {
        std.debug.print("{s}:{d}: {s}\n", .{ path, line_number, message });
        counts.failures += 1;
    }
};

const FunctionSpan = struct {
    start_line: u32,
    indent: usize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var root = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walkSelectively(init.gpa);
    defer walker.deinit();

    var counts: Counts = .{};
    for (0..entries_max) |_| {
        const entry = try walker.next(io) orelse break;
        switch (entry.kind) {
            .directory => if (!isSkipped(entry.basename)) try walker.enter(io, entry),
            .file => try lintFile(init.gpa, io, root, entry.path, &counts),
            else => {},
        }
    } else unreachable;

    if (counts.usize_uses > 0) std.debug.print("note: {d} usize uses\n", .{counts.usize_uses});
    if (counts.failures > 0) std.process.exit(1);
}

fn isSkipped(name: []const u8) bool {
    assert(name.len > 0);
    for (skipped_directories) |skipped| {
        if (std.mem.eql(u8, name, skipped)) return true;
    }
    return false;
}

fn lintFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    path: []const u8,
    counts: *Counts,
) !void {
    assert(path.len > 0);
    if (std.mem.endsWith(u8, path, ".sh")) counts.fail(path, 0, "shell scripts are not allowed");
    const is_zig = std.mem.endsWith(u8, path, ".zig");
    const is_manifest = std.mem.eql(u8, path, "build.zig.zon");
    if (!is_zig and !is_manifest) return;

    const text = try root.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(text);
    if (is_manifest) checkManifest(path, text, counts);
    if (is_zig) checkText(path, text, counts);
}

fn checkManifest(path: []const u8, text: []const u8, counts: *Counts) void {
    assert(path.len > 0);
    const index = std.mem.find(u8, text, ".dependencies") orelse return;
    const rest = std.mem.trimStart(u8, text[index + ".dependencies".len ..], " =");
    if (!std.mem.startsWith(u8, rest, ".{")) return;
    const body_end = std.mem.findScalar(u8, rest, '}') orelse rest.len;
    const body = std.mem.trim(u8, rest[2..body_end], " \t\r\n");
    if (body.len > 0) counts.fail(path, 0, "dependencies are not allowed");
}

fn checkText(path: []const u8, text: []const u8, counts: *Counts) void {
    assert(path.len > 0);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: u32 = 0;
    var previous_was_comment = false;
    var span: ?FunctionSpan = null;
    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const is_comment = std.mem.startsWith(u8, trimmed, "//");
        if (is_comment and previous_was_comment) {
            counts.fail(path, line_number, "two adjacent comment lines");
        }
        previous_was_comment = is_comment;
        if (is_comment) continue;

        checkLine(path, line_number, line, counts);
        span = checkFunction(path, line_number, line, span, counts);
    }
}

fn checkLine(path: []const u8, line_number: u32, line: []const u8, counts: *Counts) void {
    assert(line_number > 0);
    if (line.len > line_length_max) counts.fail(path, line_number, "line over 100 columns");
    if (std.mem.find(u8, line, catch_empty) != null) counts.fail(path, line_number, "empty catch");
    if (std.mem.find(u8, line, catch_discard) != null) {
        counts.fail(path, line_number, "discarded error");
    }
    if (std.mem.find(u8, line, "usize") != null) counts.usize_uses += 1;
    const open = std.mem.find(u8, line, assert_open) orelse return;
    if (std.mem.find(u8, line[open..], " and ") != null) {
        counts.fail(path, line_number, "compound assertion; split it");
    }
}

fn checkFunction(
    path: []const u8,
    line_number: u32,
    line: []const u8,
    span: ?FunctionSpan,
    counts: *Counts,
) ?FunctionSpan {
    assert(line_number > 0);
    if (span) |open_span| {
        const closes = line.len == open_span.indent + 1 and line[open_span.indent] == '}';
        if (!closes) return span;
        const length = line_number - open_span.start_line + 1;
        if (length > function_lines_max) counts.fail(path, line_number, "function over 70 lines");
        return null;
    }
    const trimmed = std.mem.trimStart(u8, line, " ");
    for (function_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        if (!std.mem.endsWith(u8, trimmed, "{") and !std.mem.endsWith(u8, trimmed, "(")) {
            return null;
        }
        const indent = line.len - trimmed.len;
        return .{ .start_line = line_number, .indent = indent };
    }
    return null;
}

fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    const result = comptime blk: {
        var out: [text.len * count]u8 = undefined;
        for (0..count) |index| @memcpy(out[index * text.len ..][0..text.len], text);
        break :blk out;
    };
    return &result;
}

test "checkText flags each rule once" {
    var counts: Counts = .{};
    const long = "const x = 1;" ++ repeat(" ", 100);
    checkText("t.zig", long, &counts);
    try std.testing.expectEqual(1, counts.failures);
    checkText("t.zig", "// a\n// b\n", &counts);
    try std.testing.expectEqual(2, counts.failures);
    checkText("t.zig", "    " ++ assert_open ++ "a and b);\n", &counts);
    try std.testing.expectEqual(3, counts.failures);
    checkText("t.zig", "x catch " ++ "{};\n", &counts);
    try std.testing.expectEqual(4, counts.failures);
}

test "checkText measures function length" {
    var counts: Counts = .{};
    const body = repeat("    const x = 1;\n", 70);
    checkText("t.zig", "fn f() void {\n" ++ body ++ "}\n", &counts);
    try std.testing.expectEqual(1, counts.failures);
    checkText("t.zig", "fn g() void {\n" ++ repeat("    const x = 1;\n", 10) ++ "}\n", &counts);
    try std.testing.expectEqual(1, counts.failures);
}

test "checkManifest rejects dependencies" {
    var counts: Counts = .{};
    checkManifest("b.zon", ".{ .dependencies = .{} }", &counts);
    try std.testing.expectEqual(0, counts.failures);
    checkManifest("b.zon", ".{ .dependencies = .{ .x = .{} } }", &counts);
    try std.testing.expectEqual(1, counts.failures);
}
