const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const Connection = @import("Connection.zig");
const testing = @import("testing.zig");

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

const test_options: Options = .{
    .connections_max = 1,
    .message_size_max = 1024,
    .handshake_size_max = 1024,
    .handshake_timeout_ms = 2000,
    .idle_timeout_ms = 2000,
};

const upgrade_request =
    "GET /chat HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" ++
    "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
    "Sec-WebSocket-Version: 13\r\n\r\n";

const TestClient = struct {
    stream: net.Stream,
    writer: net.Stream.Writer,
    reader: net.Stream.Reader,
    read_buffer: [2048]u8,

    fn connect(client: *TestClient, io: Io, port: u16) !void {
        const address = try net.IpAddress.parse("127.0.0.1", port);
        client.stream = try address.connect(io, .{ .mode = .stream });
        client.writer = client.stream.writer(io, &.{});
        client.reader = client.stream.reader(io, &client.read_buffer);
    }

    fn upgrade(client: *TestClient) !void {
        try client.writer.interface.writeAll(upgrade_request);
        const status = try client.reader.interface.takeDelimiterInclusive('\n');
        try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols\r\n", status);
        for (0..8) |_| {
            const line = try client.reader.interface.takeDelimiterInclusive('\n');
            if (line.len == 2) break;
        }
    }
};

const TestServer = struct {
    server: Server,
    listener: net.Server,
    group: Io.Group,

    fn start(test_server: *TestServer, io: Io) !u16 {
        test_server.server = try Server.init(std.testing.allocator, test_options);
        errdefer test_server.server.deinit();
        const address = try net.IpAddress.parse("127.0.0.1", 0);
        test_server.listener = try test_server.server.listen(io, address);
        test_server.group = .init;
        const server = &test_server.server;
        try test_server.group.concurrent(io, serve, .{ server, io, &test_server.listener });
        return test_server.listener.socket.address.getPort();
    }

    fn stop(test_server: *TestServer, io: Io) void {
        test_server.group.cancel(io);
        test_server.listener.deinit(io);
        test_server.server.deinit();
    }
};

test "server echoes text and binary messages over TCP" {
    const io = std.testing.io;
    var test_server: TestServer = undefined;
    const port = try test_server.start(io);
    defer test_server.stop(io);

    var client: TestClient = undefined;
    try client.connect(io, port);
    defer client.stream.close(io);
    try client.upgrade();

    var frame_buffer: [64]u8 = undefined;
    const text = testing.clientFrame(&frame_buffer, true, .text, "Hello");
    try client.writer.interface.writeAll(text);
    try std.testing.expectEqualSlices(u8, "\x81\x05Hello", try client.reader.interface.take(7));
    const binary = testing.clientFrame(&frame_buffer, true, .binary, "\x00\x01");
    try client.writer.interface.writeAll(binary);
    try std.testing.expectEqualSlices(u8, "\x82\x02\x00\x01", try client.reader.interface.take(4));
}

test "server closes a connection that arrives when the pool is full" {
    const io = std.testing.io;
    var test_server: TestServer = undefined;
    const port = try test_server.start(io);
    defer test_server.stop(io);

    var first: TestClient = undefined;
    try first.connect(io, port);
    defer first.stream.close(io);
    try first.upgrade();

    var second: TestClient = undefined;
    try second.connect(io, port);
    defer second.stream.close(io);
    try std.testing.expectError(error.EndOfStream, second.reader.interface.takeByte());
}
