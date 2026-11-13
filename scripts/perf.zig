const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const server_port: u16 = 9002;
const server_wait_attempts_max: u32 = 100;
const payload_length: u8 = 125;
const batch_messages: u32 = 100;
const batches: u32 = 2_000;
const handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" ++
    "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
    "Sec-WebSocket-Version: 13\r\n\r\n";
const payload: [payload_length]u8 = @splat('q');
// A zero mask key leaves the payload unchanged, so one encoded frame serves every send.
const request_frame = [_]u8{ 0x81, 0x80 | payload_length, 0, 0, 0, 0 } ++ payload;
const reply_frame = [_]u8{ 0x81, payload_length } ++ payload;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.MissingArguments;
    const floor = try std.fmt.parseInt(u64, args[2], 10);

    var server = try std.process.spawn(io, .{
        .argv = &.{ args[1], "--port", std.fmt.comptimePrint("{d}", .{server_port}) },
        .stdin = .ignore,
    });
    defer server.kill(io);
    std.debug.print("started {s} on port {d}\n", .{ args[1], server_port });
    const stream = try connect(io);
    defer stream.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    try upgrade(&reader.interface, &writer.interface);
    std.debug.print("upgraded; sending {d} batches of {d}\n", .{ batches, batch_messages });

    const start = Io.Timestamp.now(io, .awake);
    try echoBatches(io, start, &reader.interface, &writer.interface);
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
    const rate = messagesPerSecond(batches * batch_messages, elapsed);
    std.debug.print("{d} messages of {d} bytes in {d} ms: {d} messages/s (floor {d})\n", .{
        batches * batch_messages, payload_length, elapsed / std.time.ns_per_ms, rate, floor,
    });
    server.kill(io);
    if (rate < floor) std.process.exit(1);
}

fn connect(io: Io) !Io.net.Stream {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(server_port) };
    for (0..server_wait_attempts_max) |_| {
        if (address.connect(io, .{ .mode = .stream })) |stream| {
            return stream;
        } else |_| {
            try io.sleep(.fromMilliseconds(100), .awake);
        }
    }
    return error.ServerDidNotStart;
}

fn upgrade(reader: *Io.Reader, writer: *Io.Writer) !void {
    try writer.writeAll(handshake);
    try writer.flush();
    const status = try reader.takeDelimiterInclusive('\n');
    if (!std.mem.startsWith(u8, status, "HTTP/1.1 101")) return error.UpgradeRefused;
    while (!std.mem.eql(u8, try reader.takeDelimiterInclusive('\n'), "\r\n")) {}
}

fn echoBatches(io: Io, start: Io.Timestamp, reader: *Io.Reader, writer: *Io.Writer) !void {
    assert(request_frame.len * batch_messages <= writer.buffer.len);
    for (0..batches) |batch| {
        if (batch > 0 and batch % (batches / 10) == 0) {
            const sent: u64 = batch * batch_messages;
            const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
            std.debug.print("  {d}%: {d} messages, {d} messages/s\n", .{
                batch * 100 / batches, sent, messagesPerSecond(sent, elapsed),
            });
        }
        for (0..batch_messages) |_| try writer.writeAll(&request_frame);
        try writer.flush();
        for (0..batch_messages) |_| {
            const reply = try reader.take(reply_frame.len);
            if (!std.mem.eql(u8, reply, &reply_frame)) return error.BadEcho;
        }
    }
}

fn messagesPerSecond(messages: u64, elapsed_ns: u64) u64 {
    assert(elapsed_ns > 0);
    return messages * std.time.ns_per_s / elapsed_ns;
}

test "messagesPerSecond scales to one second" {
    try std.testing.expectEqual(1_000, messagesPerSecond(500, std.time.ns_per_s / 2));
    try std.testing.expectEqual(0, messagesPerSecond(1, 2 * std.time.ns_per_s));
}
