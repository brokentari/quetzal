const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;

const TimedWriter = @This();

interface: Io.Writer,
io: Io,
socket: net.Socket.Handle,
timeout: Io.Timeout,

pub fn init(io: Io, stream: net.Stream, timeout: Io.Timeout) TimedWriter {
    assert(timeout != .none);
    return .{
        .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        .io = io,
        .socket = stream.socket.handle,
        .timeout = timeout,
    };
}

// shortcut: the timeout covers each write call, so a peer that reads a little each time survives.
fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const writer: *TimedWriter = @alignCast(@fieldParentPtr("interface", w));
    assert(w.end == 0);
    assert(data.len > 0);
    const operation: Io.Operation = .{ .net_write = .{
        .socket_handle = writer.socket,
        .data = data,
        .splat = splat,
    } };
    const result = writer.io.operateTimeout(operation, writer.timeout) catch {
        return error.WriteFailed;
    };
    return result.net_write catch error.WriteFailed;
}

test "write fails after the timeout when the peer never reads" {
    const io = std.testing.io;
    const address = try net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const accepted = try listener.accept(io);
    defer accepted.close(io);

    const timeout: Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(100),
        .clock = .awake,
    } };
    var writer: TimedWriter = .init(io, accepted, timeout);
    const chunk: [64 * 1024]u8 = @splat(0);
    for (0..1024) |_| {
        writer.interface.writeAll(&chunk) catch |err| {
            try std.testing.expectEqual(error.WriteFailed, err);
            return;
        };
    }
    return error.TestUnexpectedResult;
}

test "write delivers every byte when the peer reads" {
    const io = std.testing.io;
    const address = try net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const accepted = try listener.accept(io);
    defer accepted.close(io);

    const timeout: Io.Timeout = .{ .duration = .{
        .raw = .fromSeconds(2),
        .clock = .awake,
    } };
    var writer: TimedWriter = .init(io, accepted, timeout);
    try writer.interface.writeAll("hello");
    var read_buffer: [8]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    try std.testing.expectEqualStrings("hello", try reader.interface.take(5));
}
