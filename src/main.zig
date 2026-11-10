const std = @import("std");
const assert = std.debug.assert;
const quetzal = @import("quetzal");

const options: quetzal.Options = .{
    .connections_max = 16,
    .message_size_max = 16 * 1024 * 1024,
    .handshake_size_max = 4096,
    .handshake_timeout_ms = 5_000,
    .idle_timeout_ms = 60_000,
};

const Listen = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 9001,
};

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const listen = try parseArgs(argv);

    var threaded: std.Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try quetzal.Server.init(std.heap.page_allocator, options);
    defer server.deinit();
    const address = try std.Io.net.IpAddress.parse(listen.bind, listen.port);
    var listener = try server.listen(io, address);
    defer listener.deinit(io);
    try server.serve(io, &listener);
}

fn parseArgs(argv: []const [:0]const u8) !Listen {
    assert(argv.len > 0);
    var listen: Listen = .{};
    var index: u32 = 1;
    while (index < argv.len) : (index += 2) {
        if (index + 1 >= argv.len) return error.MissingValue;
        const value = argv[index + 1];
        if (std.mem.eql(u8, argv[index], "--bind")) {
            listen.bind = value;
        } else if (std.mem.eql(u8, argv[index], "--port")) {
            listen.port = try std.fmt.parseInt(u16, value, 10);
        } else {
            return error.UnknownArgument;
        }
    }
    return listen;
}

test "parseArgs keeps the defaults when no flag is given" {
    const listen = try parseArgs(&.{"quetzal"});
    try std.testing.expectEqualStrings("127.0.0.1", listen.bind);
    try std.testing.expectEqual(9001, listen.port);
}

test "parseArgs reads --bind and --port" {
    const listen = try parseArgs(&.{ "quetzal", "--port", "9100", "--bind", "0.0.0.0" });
    try std.testing.expectEqualStrings("0.0.0.0", listen.bind);
    try std.testing.expectEqual(9100, listen.port);
}

test "parseArgs rejects a missing value, an unknown flag and a bad port" {
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "quetzal", "--bind" }));
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "quetzal", "--x", "1" }));
    try std.testing.expectError(error.Overflow, parseArgs(&.{ "quetzal", "--port", "70000" }));
    try std.testing.expectError(error.InvalidCharacter, parseArgs(&.{ "quetzal", "--port", "x" }));
}
