const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const frame = @import("frame.zig");
const handshake = @import("handshake.zig");
const testing = @import("testing.zig");
const Options = @import("Server.zig").Options;

const Connection = @This();

comptime {
    assert(frame.encoded_length_max <= frame.header_length_max);
}

pub const Kind = enum { text, binary };

pub const Message = struct {
    kind: Kind,
    payload: []const u8,
};

pub const Outcome = enum { need_more, closed };

options: Options,
read_buffer: []u8,
message_buffer: []u8,
read_start: usize,
read_end: usize,
message_kind: ?Kind,
message_length: usize,

pub fn readBufferLength(options: Options) usize {
    return @max(options.message_size_max + frame.header_length_max, options.handshake_size_max);
}

pub fn init(options: Options, read_buffer: []u8, message_buffer: []u8) Connection {
    assert(read_buffer.len == readBufferLength(options));
    assert(message_buffer.len == options.message_size_max);
    return .{
        .options = options,
        .read_buffer = read_buffer,
        .message_buffer = message_buffer,
        .read_start = 0,
        .read_end = 0,
        .message_kind = null,
        .message_length = 0,
    };
}

pub fn serve(connection: *Connection, io: Io, stream: net.Stream) !void {
    assert(connection.read_buffer.len > 0);
    connection.read_start = 0;
    connection.read_end = 0;
    connection.message_kind = null;
    connection.message_length = 0;
    var writer = stream.writer(io, &.{});
    try connection.upgrade(io, stream, &writer.interface);
    while (true) {
        if (try connection.process(&writer.interface) == .closed) return;
        connection.compact();
        const idle = timeoutFromMilliseconds(connection.options.idle_timeout_ms);
        try connection.readMore(io, stream, idle, connection.read_buffer.len);
    }
}

pub fn process(connection: *Connection, out: *Io.Writer) Io.Writer.Error!Outcome {
    assert(connection.read_start <= connection.read_end);
    while (connection.read_start < connection.read_end) {
        const available = connection.read_buffer[connection.read_start..connection.read_end];
        const header = frame.decode(available) catch |err| switch (err) {
            error.Incomplete => return .need_more,
            error.ProtocolError => return .closed,
        };
        if (header.payload_length > connection.options.message_size_max) return .closed;
        const payload_length: usize = @intCast(header.payload_length);
        const frame_length = header.header_length + payload_length;
        if (available.len < frame_length) return .need_more;

        const payload = available[header.header_length..frame_length];
        frame.mask(payload, header.mask_key);
        connection.read_start += frame_length;
        if (try connection.onFrame(out, header, payload) == .closed) return .closed;
    }
    return .need_more;
}

fn onFrame(
    connection: *Connection,
    out: *Io.Writer,
    header: frame.Header,
    payload: []const u8,
) Io.Writer.Error!Outcome {
    switch (header.opcode) {
        .ping => try writeFrame(out, .pong, payload),
        .pong => {},
        .close => return .closed,
        .text, .binary, .continuation => return connection.onData(out, header, payload),
    }
    return .need_more;
}

fn onData(
    connection: *Connection,
    out: *Io.Writer,
    header: frame.Header,
    payload: []const u8,
) Io.Writer.Error!Outcome {
    if (header.opcode == .continuation) {
        const kind = connection.message_kind orelse return .closed;
        return connection.append(out, kind, header.fin, payload);
    }
    if (connection.message_kind != null) return .closed;
    const kind: Kind = if (header.opcode == .text) .text else .binary;
    if (header.fin) {
        try writeMessage(out, .{ .kind = kind, .payload = payload });
        return .need_more;
    }
    connection.message_kind = kind;
    connection.message_length = 0;
    return connection.append(out, kind, false, payload);
}

fn append(
    connection: *Connection,
    out: *Io.Writer,
    kind: Kind,
    fin: bool,
    payload: []const u8,
) Io.Writer.Error!Outcome {
    const end = connection.message_length + payload.len;
    if (end > connection.message_buffer.len) return .closed;
    @memcpy(connection.message_buffer[connection.message_length..end], payload);
    connection.message_length = end;
    if (!fin) return .need_more;
    try writeMessage(out, .{ .kind = kind, .payload = connection.message_buffer[0..end] });
    connection.message_kind = null;
    connection.message_length = 0;
    return .need_more;
}

pub fn writeMessage(out: *Io.Writer, message: Message) Io.Writer.Error!void {
    const opcode: frame.Opcode = switch (message.kind) {
        .text => .text,
        .binary => .binary,
    };
    try writeFrame(out, opcode, message.payload);
}

fn writeFrame(out: *Io.Writer, opcode: frame.Opcode, payload: []const u8) Io.Writer.Error!void {
    var header_buffer: [frame.encoded_length_max]u8 = undefined;
    const header = frame.encode(&header_buffer, true, opcode, payload.len);
    var vectors = [_][]const u8{ header, payload };
    try out.writeVecAll(&vectors);
}

fn compact(connection: *Connection) void {
    if (connection.read_start == connection.read_end) {
        connection.read_start = 0;
        connection.read_end = 0;
        return;
    }
    const remaining = connection.read_end - connection.read_start;
    std.mem.copyForwards(
        u8,
        connection.read_buffer[0..remaining],
        connection.read_buffer[connection.read_start..connection.read_end],
    );
    connection.read_start = 0;
    connection.read_end = remaining;
}

fn upgrade(connection: *Connection, io: Io, stream: net.Stream, out: *Io.Writer) !void {
    const head_length = connection.readHead(io, stream) catch |err| {
        switch (err) {
            error.HeadTooLarge => try rejectWith(out, error.BadRequest),
            else => {},
        }
        return err;
    };
    const request = handshake.parse(connection.read_buffer[0..head_length]) catch |err| {
        try rejectWith(out, err);
        return err;
    };
    var response: [256]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response);
    try handshake.writeAccept(&response_writer, request);
    try out.writeAll(response_writer.buffered());
    connection.read_start = head_length;
}

fn rejectWith(out: *Io.Writer, reason: handshake.ParseError) !void {
    var response: [256]u8 = undefined;
    var response_writer: Io.Writer = .fixed(&response);
    try handshake.writeRejection(&response_writer, reason);
    try out.writeAll(response_writer.buffered());
}

fn readHead(connection: *Connection, io: Io, stream: net.Stream) !usize {
    const limit: usize = connection.options.handshake_size_max;
    assert(limit <= connection.read_buffer.len);
    const timeout = timeoutFromMilliseconds(connection.options.handshake_timeout_ms);
    const deadline = timeout.toDeadline(io);
    var parser: std.http.HeadParser = .{};
    var scanned: usize = 0;
    for (0..limit) |_| {
        try connection.readMore(io, stream, deadline, limit);
        scanned += parser.feed(connection.read_buffer[scanned..connection.read_end]);
        if (parser.state == .finished) return scanned;
        if (connection.read_end == limit) break;
    }
    return error.HeadTooLarge;
}

fn readMore(
    connection: *Connection,
    io: Io,
    stream: net.Stream,
    timeout: Io.Timeout,
    limit: usize,
) !void {
    assert(connection.read_end < limit);
    assert(limit <= connection.read_buffer.len);
    var data: [1][]u8 = .{connection.read_buffer[connection.read_end..limit]};
    const operation: Io.Operation = .{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = &data,
    } };
    const result = try io.operateTimeout(operation, timeout);
    const read = try result.net_read;
    if (read.data_len == 0) return error.EndOfStream;
    connection.read_end += read.data_len;
}

fn timeoutFromMilliseconds(milliseconds: u32) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } };
}

const test_options: Options = .{
    .connections_max = 1,
    .message_size_max = 1024,
    .handshake_size_max = 1024,
    .handshake_timeout_ms = 1000,
    .idle_timeout_ms = 1000,
};

const TestConnection = struct {
    read_buffer: [readBufferLength(test_options)]u8 = undefined,
    message_buffer: [test_options.message_size_max]u8 = undefined,
    connection: Connection = undefined,

    fn start(self: *TestConnection) void {
        self.connection = .init(test_options, &self.read_buffer, &self.message_buffer);
    }

    fn feed(self: *TestConnection, bytes: []const u8) void {
        const connection = &self.connection;
        @memcpy(connection.read_buffer[connection.read_end..][0..bytes.len], bytes);
        connection.read_end += bytes.len;
    }
};

test "process echoes a text frame as one unmasked frame" {
    var state: TestConnection = .{};
    state.start();
    var frame_buffer: [32]u8 = undefined;
    state.feed(testing.clientFrame(&frame_buffer, true, .text, "Hello"));
    var out_buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x81\x05Hello", out.buffered());
}

test "process waits for the rest of a split frame and then echoes it" {
    var state: TestConnection = .{};
    state.start();
    var frame_buffer: [32]u8 = undefined;
    const bytes = testing.clientFrame(&frame_buffer, true, .binary, "abc");
    var out_buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    for (bytes[0 .. bytes.len - 1]) |byte| {
        state.feed(&.{byte});
        try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    }
    try std.testing.expectEqual(0, out.buffered().len);
    state.feed(bytes[bytes.len - 1 ..]);
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x82\x03abc", out.buffered());
}

test "process echoes two frames that arrive together" {
    var state: TestConnection = .{};
    state.start();
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    state.feed(testing.clientFrame(&first, true, .text, "one"));
    state.feed(testing.clientFrame(&second, true, .text, ""));
    var out_buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    _ = try state.connection.process(&out);
    try std.testing.expectEqualSlices(u8, "\x81\x03one\x81\x00", out.buffered());
}

test "process answers a ping with a pong that carries the same payload" {
    var state: TestConnection = .{};
    state.start();
    var frame_buffer: [32]u8 = undefined;
    state.feed(testing.clientFrame(&frame_buffer, true, .ping, "beat"));
    var out_buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x8a\x04beat", out.buffered());
}

test "process ignores an unsolicited pong" {
    var state: TestConnection = .{};
    state.start();
    var frame_buffer: [32]u8 = undefined;
    state.feed(testing.clientFrame(&frame_buffer, true, .pong, "x"));
    var out_buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    try std.testing.expectEqual(0, out.buffered().len);
}

test "process joins fragments and answers a ping between them" {
    var state: TestConnection = .{};
    state.start();
    var frame_buffer: [32]u8 = undefined;
    state.feed(testing.clientFrame(&frame_buffer, false, .text, "Hel"));
    state.feed(testing.clientFrame(&frame_buffer, true, .ping, "p"));
    state.feed(testing.clientFrame(&frame_buffer, false, .continuation, "l"));
    state.feed(testing.clientFrame(&frame_buffer, true, .continuation, "o"));
    var out_buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x8a\x01p\x81\x05Hello", out.buffered());
}

test "process closes on a stray continuation or an interleaved data frame" {
    var frame_buffer: [32]u8 = undefined;
    var out_buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var stray: TestConnection = .{};
    stray.start();
    stray.feed(testing.clientFrame(&frame_buffer, true, .continuation, "x"));
    try std.testing.expectEqual(.closed, try stray.connection.process(&out));

    var interleaved: TestConnection = .{};
    interleaved.start();
    interleaved.feed(testing.clientFrame(&frame_buffer, false, .text, "a"));
    interleaved.feed(testing.clientFrame(&frame_buffer, true, .text, "b"));
    try std.testing.expectEqual(.closed, try interleaved.connection.process(&out));
}
