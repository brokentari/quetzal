const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const Connection = @import("Connection.zig");
const frame = @import("frame.zig");
const TimedWriter = @import("TimedWriter.zig");
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
    assert(options.message_size_max >= frame.control_payload_max);
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

pub fn serve(server: *Server, io: Io, listener: *net.Server) net.Server.AcceptError!void {
    assert(server.slots.len > 0);
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted, error.ProtocolFailure, error.BlockedByFirewall => continue,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            error.NetworkDown,
            error.Unexpected,
            => {
                std.log.warn("accept failed: {t}", .{err});
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            },
            else => return err,
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
    defer stream.close(io);
    defer slot.in_use.store(false, .release);
    slot.connection.serve(io, stream) catch |err| {
        std.log.debug("connection ended: {t}", .{err});
    };
}

fn testOptions(connections_max: u32, timeout_ms: u32) Options {
    return .{
        .connections_max = connections_max,
        .message_size_max = 1024,
        .handshake_size_max = 1024,
        .handshake_timeout_ms = timeout_ms,
        .idle_timeout_ms = timeout_ms,
    };
}

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

fn serveInTest(server: *Server, io: Io, listener: *net.Server) Io.Cancelable!void {
    server.serve(io, listener) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.debug.panic("serve failed: {t}", .{err}),
    };
}

const TestServer = struct {
    server: Server,
    listener: net.Server,
    group: Io.Group,

    fn start(test_server: *TestServer, io: Io, options: Options) !u16 {
        test_server.server = try Server.init(std.testing.allocator, options);
        errdefer test_server.server.deinit();
        const address = try net.IpAddress.parse("127.0.0.1", 0);
        test_server.listener = try test_server.server.listen(io, address);
        test_server.group = .init;
        const server = &test_server.server;
        try test_server.group.concurrent(io, serveInTest, .{ server, io, &test_server.listener });
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
    const port = try test_server.start(io, testOptions(2, 2000));
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
    const port = try test_server.start(io, testOptions(1, 2000));
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

test "server rejects a bad request with 400 and a wrong version with 426" {
    const io = std.testing.io;
    var test_server: TestServer = undefined;
    const port = try test_server.start(io, testOptions(2, 2000));
    defer test_server.stop(io);

    var bad: TestClient = undefined;
    try bad.connect(io, port);
    defer bad.stream.close(io);
    try bad.writer.interface.writeAll("POST / HTTP/1.1\r\nHost: a\r\n\r\n");
    const bad_status = try bad.reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request\r\n", bad_status);

    var old: TestClient = undefined;
    try old.connect(io, port);
    defer old.stream.close(io);
    const request = std.mem.replaceOwned(u8, std.testing.allocator, upgrade_request, ": 13", ": 8");
    const old_request = try request;
    defer std.testing.allocator.free(old_request);
    try old.writer.interface.writeAll(old_request);
    const old_status = try old.reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("HTTP/1.1 426 Upgrade Required\r\n", old_status);
}

test "server drops a client that sends no handshake in time and frees its slot" {
    const io = std.testing.io;
    var test_server: TestServer = undefined;
    const port = try test_server.start(io, testOptions(1, 100));
    defer test_server.stop(io);

    var silent: TestClient = undefined;
    try silent.connect(io, port);
    defer silent.stream.close(io);
    try std.testing.expectError(error.EndOfStream, silent.reader.interface.takeByte());

    var next: TestClient = undefined;
    try next.connect(io, port);
    defer next.stream.close(io);
    try next.upgrade();
}

test "server drops an upgraded client that stays idle" {
    const io = std.testing.io;
    var test_server: TestServer = undefined;
    const port = try test_server.start(io, testOptions(1, 100));
    defer test_server.stop(io);

    var client: TestClient = undefined;
    try client.connect(io, port);
    defer client.stream.close(io);
    try client.upgrade();
    try std.testing.expectError(error.EndOfStream, client.reader.interface.takeByte());
}

test "server answers a handshake that never ends with 400" {
    const io = std.testing.io;
    var test_server: TestServer = undefined;
    const port = try test_server.start(io, testOptions(1, 2000));
    defer test_server.stop(io);

    var client: TestClient = undefined;
    try client.connect(io, port);
    defer client.stream.close(io);
    const junk: [1100]u8 = @splat('a');
    try client.writer.interface.writeAll("GET / HTTP/1.1\r\nX-Filler: ");
    try client.writer.interface.writeAll(&junk);
    const status = try client.reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request\r\n", status);
}

test "server frees the slot of a client that never reads its echoes" {
    const io = std.testing.io;
    var test_server: TestServer = undefined;
    const port = try test_server.start(io, testOptions(1, 100));
    defer test_server.stop(io);

    var stalled: TestClient = undefined;
    try stalled.connect(io, port);
    defer stalled.stream.close(io);
    try stalled.upgrade();
    const give_up: Io.Timeout = .{ .duration = .{
        .raw = .fromSeconds(3),
        .clock = .awake,
    } };
    var writer: TimedWriter = .init(io, stalled.stream, give_up);
    var frame_buffer: [1100]u8 = undefined;
    const payload: [1000]u8 = @splat('x');
    const bytes = testing.clientFrame(&frame_buffer, true, .binary, &payload);
    for (0..1_000_000) |_| {
        writer.interface.writeAll(bytes) catch break;
    }

    var next: TestClient = undefined;
    try next.connect(io, port);
    defer next.stream.close(io);
    try next.upgrade();
}
