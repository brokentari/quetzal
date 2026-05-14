const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const frame = @import("frame.zig");
const handshake = @import("handshake.zig");
const Options = @import("Server.zig").Options;

const Connection = @This();

options: Options,
read_buffer: []u8,
message_buffer: []u8,
read_start: usize,
read_end: usize,

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
    };
}

pub fn serve(connection: *Connection, io: Io, stream: net.Stream) !void {
    connection.read_start = 0;
    connection.read_end = 0;
    var writer = stream.writer(io, &.{});
    try connection.upgrade(io, stream, &writer.interface);
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
