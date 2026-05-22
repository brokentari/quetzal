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

pub const CloseCode = enum(u16) {
    normal = 1000,
    protocol_error = 1002,
    invalid_payload = 1007,
    message_too_big = 1009,
};

const drain_reads_max: u32 = 64;

options: Options,
read_buffer: []u8,
message_buffer: []u8,
read_start: usize,
read_end: usize,
message_kind: ?Kind,
message_length: usize,
utf8_checked: usize,

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
        .utf8_checked = 0,
    };
}

pub fn serve(connection: *Connection, io: Io, stream: net.Stream) !void {
    assert(connection.read_buffer.len > 0);
    connection.read_start = 0;
    connection.read_end = 0;
    connection.resetMessage();
    var writer = stream.writer(io, &.{});
    try connection.upgrade(io, stream, &writer.interface);
    while (true) {
        if (try connection.process(&writer.interface) == .closed) {
            connection.drain(io, stream);
            return;
        }
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
            error.ProtocolError => return fail(out, .protocol_error),
        };
        if (header.payload_length > connection.options.message_size_max) {
            return fail(out, .message_too_big);
        }
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
        .close => return onClose(out, payload),
        .text, .binary, .continuation => return connection.onData(out, header, payload),
    }
    return .need_more;
}

fn onClose(out: *Io.Writer, payload: []const u8) Io.Writer.Error!Outcome {
    assert(payload.len <= frame.control_payload_max);
    if (payload.len == 0) {
        try writeClose(out, @backingInt(CloseCode.normal));
        return .closed;
    }
    if (payload.len == 1) return fail(out, .protocol_error);
    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!closeCodeIsValid(code)) return fail(out, .protocol_error);
    if (!std.unicode.utf8ValidateSlice(payload[2..])) return fail(out, .invalid_payload);
    try writeClose(out, code);
    return .closed;
}

fn closeCodeIsValid(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1011, 3000...4999 => true,
        else => false,
    };
}

fn onData(
    connection: *Connection,
    out: *Io.Writer,
    header: frame.Header,
    payload: []const u8,
) Io.Writer.Error!Outcome {
    if (header.opcode == .continuation) {
        const kind = connection.message_kind orelse return fail(out, .protocol_error);
        return connection.append(out, kind, header.fin, payload);
    }
    if (connection.message_kind != null) return fail(out, .protocol_error);
    const kind: Kind = if (header.opcode == .text) .text else .binary;
    if (header.fin) {
        if (kind == .text and !std.unicode.utf8ValidateSlice(payload)) {
            return fail(out, .invalid_payload);
        }
        try writeMessage(out, .{ .kind = kind, .payload = payload });
        return .need_more;
    }
    connection.message_kind = kind;
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
    if (end > connection.message_buffer.len) return fail(out, .message_too_big);
    @memcpy(connection.message_buffer[connection.message_length..end], payload);
    connection.message_length = end;
    if (kind == .text) {
        const pending = connection.message_buffer[connection.utf8_checked..end];
        const valid_length = utf8ValidLength(pending, fin) orelse {
            return fail(out, .invalid_payload);
        };
        connection.utf8_checked += valid_length;
    }
    if (!fin) return .need_more;
    try writeMessage(out, .{ .kind = kind, .payload = connection.message_buffer[0..end] });
    connection.resetMessage();
    return .need_more;
}

fn resetMessage(connection: *Connection) void {
    connection.message_kind = null;
    connection.message_length = 0;
    connection.utf8_checked = 0;
}

// Returns the length of the valid prefix, or null on bad UTF-8; a cut-off tail waits for more bytes.
fn utf8ValidLength(bytes: []const u8, final: bool) ?usize {
    var complete = bytes.len;
    if (!final) {
        for (1..@min(4, bytes.len + 1)) |back| {
            const lead = bytes[bytes.len - back];
            if (lead & 0xc0 == 0x80) continue;
            const sequence_length: usize = switch (lead) {
                0xc2...0xdf => 2,
                0xe0...0xef => 3,
                0xf0...0xf4 => 4,
                else => 1,
            };
            if (sequence_length > back) complete = bytes.len - back;
            break;
        }
    }
    if (!std.unicode.utf8ValidateSlice(bytes[0..complete])) return null;
    if (!partialSequenceIsValid(bytes[complete..])) return null;
    return complete;
}

// A cut-off sequence can already be invalid; failing now is what Autobahn 6.4 expects.
fn partialSequenceIsValid(tail: []const u8) bool {
    assert(tail.len < 4);
    if (tail.len < 2) return true;
    const second = tail[1];
    return switch (tail[0]) {
        0xe0 => second >= 0xa0,
        0xed => second <= 0x9f,
        0xf0 => second >= 0x90,
        0xf4 => second <= 0x8f,
        else => true,
    };
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

fn fail(out: *Io.Writer, code: CloseCode) Io.Writer.Error!Outcome {
    try writeClose(out, @backingInt(code));
    return .closed;
}

fn writeClose(out: *Io.Writer, code: u16) Io.Writer.Error!void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, code, .big);
    try writeFrame(out, .close, &payload);
}

fn drain(connection: *Connection, io: Io, stream: net.Stream) void {
    stream.shutdown(io, .send) catch return;
    const idle = timeoutFromMilliseconds(connection.options.idle_timeout_ms);
    const deadline = idle.toDeadline(io);
    for (0..drain_reads_max) |_| {
        connection.read_end = 0;
        connection.readMore(io, stream, deadline, connection.read_buffer.len) catch return;
    }
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

test "process answers each invalid frame with close code 1002" {
    const key = "\x01\x02\x03\x04";
    const cases = [_][]const u8{
        "\xc1\x80" ++ key,
        "\xa1\x80" ++ key,
        "\x91\x80" ++ key,
        "\x83\x80" ++ key,
        "\x8b\x80" ++ key,
        "\x81\x01x",
        "\x09\x80" ++ key,
        "\x89\xfe\x00\x7e" ++ key,
        "\x81\xfe\x00\x05" ++ key,
        "\x81\xff\x00\x00\x00\x00\x00\x00\xff\xff" ++ key,
        "\x81\xff\x80\x00\x00\x00\x00\x00\x00\x00" ++ key,
    };
    for (cases) |bytes| {
        var state: TestConnection = .{};
        state.start();
        state.feed(bytes);
        var out_buffer: [16]u8 = undefined;
        var out: Io.Writer = .fixed(&out_buffer);
        try std.testing.expectEqual(.closed, try state.connection.process(&out));
        try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xea", out.buffered());
    }
}

test "process answers a stray continuation and an interleaved data frame with 1002" {
    var frame_buffer: [32]u8 = undefined;
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var stray: TestConnection = .{};
    stray.start();
    stray.feed(testing.clientFrame(&frame_buffer, true, .continuation, "x"));
    try std.testing.expectEqual(.closed, try stray.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xea", out.buffered());

    out = .fixed(&out_buffer);
    var interleaved: TestConnection = .{};
    interleaved.start();
    interleaved.feed(testing.clientFrame(&frame_buffer, false, .text, "a"));
    interleaved.feed(testing.clientFrame(&frame_buffer, true, .text, "b"));
    try std.testing.expectEqual(.closed, try interleaved.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xea", out.buffered());
}

test "utf8ValidLength holds back a cut-off sequence until the message ends" {
    const euro = "\xe2\x82\xac";
    try std.testing.expectEqual(0, utf8ValidLength(euro[0..1], false));
    try std.testing.expectEqual(0, utf8ValidLength(euro[0..2], false));
    try std.testing.expectEqual(3, utf8ValidLength(euro, false));
    try std.testing.expectEqual(2, utf8ValidLength("ab" ++ euro[0..2], false));
    try std.testing.expectEqual(null, utf8ValidLength(euro[0..2], true));
    try std.testing.expectEqual(null, utf8ValidLength("\xf4\x90\x80\x80", false));
    try std.testing.expectEqual(null, utf8ValidLength("\xc0\xaf", false));
    try std.testing.expectEqual(null, utf8ValidLength("\xf4\x90", false));
    try std.testing.expectEqual(null, utf8ValidLength("\xe0\x80", false));
    try std.testing.expectEqual(null, utf8ValidLength("\xed\xa0", false));
    try std.testing.expectEqual(null, utf8ValidLength("\xf0\x80", false));
    try std.testing.expectEqual(0, utf8ValidLength("\xf4\x8f", false));
    try std.testing.expectEqual(null, utf8ValidLength("a\xff", false));
    try std.testing.expectEqual(0, utf8ValidLength("", false));
}

test "process answers invalid UTF-8 with close code 1007" {
    var frame_buffer: [32]u8 = undefined;
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var single: TestConnection = .{};
    single.start();
    single.feed(testing.clientFrame(&frame_buffer, true, .text, "\xff"));
    try std.testing.expectEqual(.closed, try single.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xef", out.buffered());

    out = .fixed(&out_buffer);
    var split: TestConnection = .{};
    split.start();
    split.feed(testing.clientFrame(&frame_buffer, false, .text, "ok\xf4"));
    split.feed(testing.clientFrame(&frame_buffer, false, .continuation, "\x90\x80\x80"));
    try std.testing.expectEqual(.closed, try split.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xef", out.buffered());
}

test "process fails at once on a cut-off sequence that can no longer be valid" {
    var frame_buffer: [32]u8 = undefined;
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var state: TestConnection = .{};
    state.start();
    state.feed(testing.clientFrame(&frame_buffer, false, .text, "ok\xf4"));
    state.feed(testing.clientFrame(&frame_buffer, false, .continuation, "\x90"));
    try std.testing.expectEqual(.closed, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xef", out.buffered());
}

test "process echoes a code point that spans two fragments" {
    var frame_buffer: [32]u8 = undefined;
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var state: TestConnection = .{};
    state.start();
    state.feed(testing.clientFrame(&frame_buffer, false, .text, "\xe2\x82"));
    state.feed(testing.clientFrame(&frame_buffer, true, .continuation, "\xac"));
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x81\x03\xe2\x82\xac", out.buffered());
}

test "process does not check binary messages for UTF-8" {
    var frame_buffer: [32]u8 = undefined;
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var state: TestConnection = .{};
    state.start();
    state.feed(testing.clientFrame(&frame_buffer, true, .binary, "\xff\xfe"));
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x82\x02\xff\xfe", out.buffered());
}

test "closeCodeIsValid accepts only the codes RFC 6455 allows on the wire" {
    const valid = [_]u16{ 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 3000, 4999 };
    for (valid) |code| try std.testing.expect(closeCodeIsValid(code));
    const invalid = [_]u16{ 0, 999, 1004, 1005, 1006, 1012, 1015, 1016, 2999, 5000, 65535 };
    for (invalid) |code| try std.testing.expect(!closeCodeIsValid(code));
}

test "process echoes the close code and closes" {
    var frame_buffer: [32]u8 = undefined;
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var state: TestConnection = .{};
    state.start();
    state.feed(testing.clientFrame(&frame_buffer, true, .close, "\x03\xe9bye"));
    try std.testing.expectEqual(.closed, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xe9", out.buffered());
}

test "process answers an empty close with 1000" {
    var frame_buffer: [32]u8 = undefined;
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    var state: TestConnection = .{};
    state.start();
    state.feed(testing.clientFrame(&frame_buffer, true, .close, ""));
    try std.testing.expectEqual(.closed, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xe8", out.buffered());
}

test "process maps bad close frames to close codes" {
    const Case = struct { payload: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .payload = "\x03", .expected = "\x88\x02\x03\xea" },
        .{ .payload = "\x03\xec", .expected = "\x88\x02\x03\xea" },
        .{ .payload = "\x03\xe8\xff", .expected = "\x88\x02\x03\xef" },
        .{ .payload = "\x00\x00", .expected = "\x88\x02\x03\xea" },
        .{ .payload = "\x13\x88", .expected = "\x88\x02\x03\xea" },
    };
    for (cases) |case| {
        var frame_buffer: [32]u8 = undefined;
        var out_buffer: [16]u8 = undefined;
        var out: Io.Writer = .fixed(&out_buffer);
        var state: TestConnection = .{};
        state.start();
        state.feed(testing.clientFrame(&frame_buffer, true, .close, case.payload));
        try std.testing.expectEqual(.closed, try state.connection.process(&out));
        try std.testing.expectEqualSlices(u8, case.expected, out.buffered());
    }
}

test "process answers an oversized frame with close code 1009" {
    var state: TestConnection = .{};
    state.start();
    state.feed("\x82\xfe\x04\x01\x01\x02\x03\x04");
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    try std.testing.expectEqual(.closed, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xf1", out.buffered());
}

test "process accepts a frame of exactly the size limit" {
    var state: TestConnection = .{};
    state.start();
    state.feed("\x82\xfe\x04\x00\x01\x02\x03\x04");
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    try std.testing.expectEqual(0, out.buffered().len);
}

test "process answers fragments that add up past the size limit with 1009" {
    var state: TestConnection = .{};
    state.start();
    var payload: [600]u8 = @splat('a');
    var frame_buffer: [700]u8 = undefined;
    state.feed(testing.clientFrame(&frame_buffer, false, .binary, &payload));
    var out_buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    try std.testing.expectEqual(.need_more, try state.connection.process(&out));
    state.connection.compact();
    state.feed(testing.clientFrame(&frame_buffer, true, .continuation, &payload));
    try std.testing.expectEqual(.closed, try state.connection.process(&out));
    try std.testing.expectEqualSlices(u8, "\x88\x02\x03\xf1", out.buffered());
}

fn fuzzProcess(_: void, smith: *std.testing.Smith) anyerror!void {
    var input: [3000]u8 = undefined;
    const input_length = smith.slice(&input);
    const chunk_length = smith.valueRangeAtMost(u16, 1, 200);
    var state: TestConnection = .{};
    state.start();
    const connection = &state.connection;
    var out_buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);

    var offset: usize = 0;
    while (offset < input_length) {
        const free = connection.read_buffer.len - connection.read_end;
        const length = @min(@min(chunk_length, input_length - offset), free);
        state.feed(input[offset..][0..length]);
        offset += length;
        const outcome = try connection.process(&out);
        try std.testing.expect(connection.read_start <= connection.read_end);
        try std.testing.expect(connection.read_end <= connection.read_buffer.len);
        try std.testing.expect(connection.message_length <= connection.message_buffer.len);
        if (outcome == .closed) {
            const written = out.buffered();
            try std.testing.expect(written.len >= 4);
            try std.testing.expectEqual(0x88, written[written.len - 4]);
            try std.testing.expectEqual(2, written[written.len - 3]);
            return;
        }
        connection.compact();
    }
}

test "process keeps its invariants on every input the fuzzer finds" {
    try std.testing.fuzz({}, fuzzProcess, .{ .corpus = &.{
        "\x0b\x00\x00\x00\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58\x10",
        "\x16\x00\x00\x00\x01\x81\x01\x02\x03\x04\x61\x80\x81\x01\x02\x03\x04\x62" ++
            "\x88\x80\x01\x02\x03\x04\x07",
        "\x06\x00\x00\x00\xc1\x80\x01\x02\x03\x04\x03",
    } });
}
