const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const Connection = @import("Connection.zig");

const Server = @This();

pub const Options = struct {
    connections_max: u32,
    message_size_max: u32,
    handshake_size_max: u32,
    handshake_timeout_ms: u32,
    idle_timeout_ms: u32,
};

const Slot = struct {
    connection: Connection,
    in_use: std.atomic.Value(bool),
};

allocator: std.mem.Allocator,
options: Options,
slots: []Slot,
buffers: []u8,

pub fn init(allocator: std.mem.Allocator, options: Options) !Server {
    assert(options.connections_max > 0);
    assert(options.message_size_max > 0);
    assert(options.handshake_size_max > 0);
    const read_length = Connection.readBufferLength(options);
    const message_length = options.message_size_max;
    const slots = try allocator.alloc(Slot, options.connections_max);
    errdefer allocator.free(slots);
    const stride = read_length + message_length;
    const buffers = try allocator.alloc(u8, options.connections_max * stride);
    for (slots, 0..) |*slot, index| {
        const start = index * stride;
        slot.* = .{
            .connection = .init(
                options,
                buffers[start..][0..read_length],
                buffers[start + read_length ..][0..message_length],
            ),
            .in_use = .init(false),
        };
    }
    return .{ .allocator = allocator, .options = options, .slots = slots, .buffers = buffers };
}

pub fn deinit(server: *Server) void {
    server.allocator.free(server.buffers);
    server.allocator.free(server.slots);
    server.* = undefined;
}

pub fn listen(server: *Server, io: Io, address: net.IpAddress) !net.Server {
    assert(server.slots.len > 0);
    return address.listen(io, .{ .reuse_address = true });
}

pub fn serve(server: *Server, io: Io, listener: *net.Server) Io.Cancelable!void {
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConnectionAborted => continue,
            else => {
                std.log.err("accept failed: {t}", .{err});
                return;
            },
        };
        const slot = server.claim() orelse {
            stream.close(io);
            continue;
        };
        group.concurrent(io, run, .{ slot, io, stream }) catch {
            slot.in_use.store(false, .release);
            stream.close(io);
        };
    }
}

fn claim(server: *Server) ?*Slot {
    for (server.slots) |*slot| {
        if (slot.in_use.cmpxchgStrong(false, true, .acquire, .monotonic) == null) return slot;
    }
    return null;
}

fn run(slot: *Slot, io: Io, stream: net.Stream) void {
    assert(slot.in_use.load(.monotonic));
    defer slot.in_use.store(false, .release);
    defer stream.close(io);
    slot.connection.serve(io, stream) catch |err| {
        std.log.debug("connection ended: {t}", .{err});
    };
}

test "server upgrades a client on a pool slot" {
    const io = std.testing.io;
    var server = try Server.init(std.testing.allocator, .{
        .connections_max = 2,
        .message_size_max = 1024,
        .handshake_size_max = 1024,
        .handshake_timeout_ms = 2000,
        .idle_timeout_ms = 2000,
    });
    defer server.deinit();
    var listener = try server.listen(io, try net.IpAddress.parse("127.0.0.1", 0));
    defer listener.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, serve, .{ &server, io, &listener });
    defer group.cancel(io);

    const port = listener.socket.address.getPort();
    const address = try net.IpAddress.parse("127.0.0.1", port);
    const client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var writer = client.writer(io, &.{});
    try writer.interface.writeAll(
        "GET /chat HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
    );
    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    const status = try reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols\r\n", status);
}
