const std = @import("std");
const quetzal = @import("quetzal");

const port: u16 = 9001;
const options: quetzal.Options = .{
    .connections_max = 16,
    .message_size_max = 16 * 1024 * 1024,
    .handshake_size_max = 4096,
    .handshake_timeout_ms = 5_000,
    .idle_timeout_ms = 60_000,
};

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try quetzal.Server.init(std.heap.page_allocator, options);
    defer server.deinit();
    var listener = try server.listen(io, .{ .ip4 = .loopback(port) });
    defer listener.deinit(io);
    try server.serve(io, &listener);
}
