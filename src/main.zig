const std = @import("std");
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
    const listen = try parseArgs(init.arena.allocator(), init.minimal.args);

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

fn parseArgs(arena: std.mem.Allocator, args: std.process.Args) !Listen {
    const argv = try args.toSlice(arena);
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
