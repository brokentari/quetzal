const std = @import("std");
const assert = std.debug.assert;

pub const control_payload_max: u8 = 125;
pub const header_length_max: u8 = 14;
pub const encoded_length_max: u8 = 10;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,

    pub fn fromInt(value: u4) ?Opcode {
        return switch (value) {
            0x0, 0x1, 0x2, 0x8, 0x9, 0xa => @fromBackingInt(@intCast(value)),
            else => null,
        };
    }

    pub fn isControl(opcode: Opcode) bool {
        return @backingInt(opcode) >= 0x8;
    }
};

pub const Header = struct {
    fin: bool,
    opcode: Opcode,
    mask_key: [4]u8,
    payload_length: u64,
    header_length: u8,
};

pub const DecodeError = error{
    Incomplete,
    ProtocolError,
};

pub fn decode(bytes: []const u8) DecodeError!Header {
    if (bytes.len < 2) return error.Incomplete;
    const fin = bytes[0] & 0x80 != 0;
    if (bytes[0] & 0x70 != 0) return error.ProtocolError;
    const opcode = Opcode.fromInt(@truncate(bytes[0])) orelse return error.ProtocolError;
    if (bytes[1] & 0x80 == 0) return error.ProtocolError;
    const length_code: u8 = bytes[1] & 0x7f;
    if (opcode.isControl() and (!fin or length_code > control_payload_max)) {
        return error.ProtocolError;
    }

    var header_length: u8 = 2;
    var payload_length: u64 = length_code;
    if (length_code == 126) {
        if (bytes.len < 4) return error.Incomplete;
        payload_length = std.mem.readInt(u16, bytes[2..4], .big);
        if (payload_length <= 125) return error.ProtocolError;
        header_length = 4;
    } else if (length_code == 127) {
        if (bytes.len < 10) return error.Incomplete;
        payload_length = std.mem.readInt(u64, bytes[2..10], .big);
        if (payload_length >> 63 != 0) return error.ProtocolError;
        if (payload_length <= std.math.maxInt(u16)) return error.ProtocolError;
        header_length = 10;
    }

    if (bytes.len < header_length + 4) return error.Incomplete;
    const mask_key = bytes[header_length..][0..4].*;
    header_length += 4;
    assert(header_length <= header_length_max);
    return .{
        .fin = fin,
        .opcode = opcode,
        .mask_key = mask_key,
        .payload_length = payload_length,
        .header_length = header_length,
    };
}

pub fn encode(
    buffer: *[encoded_length_max]u8,
    fin: bool,
    opcode: Opcode,
    payload_length: u64,
) []const u8 {
    assert(!opcode.isControl() or payload_length <= control_payload_max);
    buffer[0] = (if (fin) @as(u8, 0x80) else 0) | @backingInt(opcode);
    if (payload_length <= 125) {
        buffer[1] = @intCast(payload_length);
        return buffer[0..2];
    }
    if (payload_length <= std.math.maxInt(u16)) {
        buffer[1] = 126;
        std.mem.writeInt(u16, buffer[2..4], @intCast(payload_length), .big);
        return buffer[0..4];
    }
    assert(payload_length >> 63 == 0);
    buffer[1] = 127;
    std.mem.writeInt(u64, buffer[2..10], payload_length, .big);
    return buffer[0..10];
}

pub fn mask(bytes: []u8, key: [4]u8) void {
    var wide: [8]u8 = undefined;
    @memcpy(wide[0..4], &key);
    @memcpy(wide[4..8], &key);
    const key_word: u64 = @bitCast(wide);

    var index: usize = 0;
    while (index + 8 <= bytes.len) : (index += 8) {
        const word: u64 = @bitCast(bytes[index..][0..8].*);
        bytes[index..][0..8].* = @bitCast(word ^ key_word);
    }
    for (bytes[index..], 0..) |*byte, offset| {
        byte.* ^= key[offset % 4];
    }
}

test "decode reads the masked text frame from RFC 6455 section 5.7" {
    const bytes = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    const header = try decode(&bytes);
    try std.testing.expect(header.fin);
    try std.testing.expectEqual(Opcode.text, header.opcode);
    try std.testing.expectEqual(5, header.payload_length);
    try std.testing.expectEqual(6, header.header_length);
    try std.testing.expectEqualSlices(u8, &.{ 0x37, 0xfa, 0x21, 0x3d }, &header.mask_key);
}

test "decode reads 16-bit and 64-bit lengths from RFC 6455 section 5.7" {
    const key = [_]u8{ 1, 2, 3, 4 };
    const medium = try decode(&([_]u8{ 0x82, 0xfe, 0x01, 0x00 } ++ key));
    try std.testing.expectEqual(256, medium.payload_length);
    try std.testing.expectEqual(8, medium.header_length);
    const large_prefix = [_]u8{ 0x82, 0xff, 0, 0, 0, 0, 0, 1, 0, 0 };
    const large = try decode(&(large_prefix ++ key));
    try std.testing.expectEqual(65536, large.payload_length);
    try std.testing.expectEqual(14, large.header_length);
}

test "decode reports a short buffer as incomplete" {
    const bytes = [_]u8{ 0x82, 0xfe, 0x01, 0x00, 1, 2, 3, 4 };
    for (0..bytes.len) |length| {
        try std.testing.expectError(error.Incomplete, decode(bytes[0..length]));
    }
    _ = try decode(&bytes);
}

test "decode rejects each invalid frame with a protocol error" {
    const key = [_]u8{ 1, 2, 3, 4 };
    const cases = [_][]const u8{
        &([_]u8{ 0xc1, 0x80 } ++ key),
        &([_]u8{ 0xa1, 0x80 } ++ key),
        &([_]u8{ 0x91, 0x80 } ++ key),
        &([_]u8{ 0x83, 0x80 } ++ key),
        &([_]u8{ 0x8b, 0x80 } ++ key),
        &[_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' },
        &([_]u8{ 0x09, 0x80 } ++ key),
        &([_]u8{ 0x89, 0xfe, 0, 126 } ++ key),
        &([_]u8{ 0x88, 0xfe, 0, 126 } ++ key),
        &([_]u8{ 0x81, 0xfe, 0, 5 } ++ key),
        &([_]u8{ 0x81, 0xff, 0, 0, 0, 0, 0, 0, 0xff, 0xff } ++ key),
        &([_]u8{ 0x81, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0 } ++ key),
    };
    for (cases) |bytes| {
        try std.testing.expectError(error.ProtocolError, decode(bytes));
    }
}

test "encode matches the unmasked examples from RFC 6455 section 5.7" {
    var buffer: [encoded_length_max]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x05 }, encode(&buffer, true, .text, 5));
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 0x05 }, encode(&buffer, true, .ping, 5));
    try std.testing.expectEqualSlices(u8, &.{ 0x8a, 0x05 }, encode(&buffer, true, .pong, 5));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x03 }, encode(&buffer, false, .text, 3));
    const last = encode(&buffer, true, .continuation, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x02 }, last);
}

test "encode picks the shortest length form" {
    var buffer: [encoded_length_max]u8 = undefined;
    const medium = encode(&buffer, true, .binary, 256);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x7e, 0x01, 0x00 }, medium);
    const large = encode(&buffer, true, .binary, 65536);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x7f, 0, 0, 0, 0, 0, 1, 0, 0 }, large);
    try std.testing.expectEqual(2, encode(&buffer, true, .binary, 125).len);
    try std.testing.expectEqual(4, encode(&buffer, true, .binary, 126).len);
    try std.testing.expectEqual(4, encode(&buffer, true, .binary, 65535).len);
}

test "mask unmasks the RFC 6455 section 5.7 text payload" {
    var payload = [_]u8{ 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    mask(&payload, .{ 0x37, 0xfa, 0x21, 0x3d });
    try std.testing.expectEqualStrings("Hello", &payload);
}

test "mask matches a byte-by-byte reference at every length" {
    const key = [4]u8{ 0xde, 0xad, 0xbe, 0xef };
    var actual: [40]u8 = undefined;
    var expected: [40]u8 = undefined;
    for (0..actual.len + 1) |length| {
        for (&actual, &expected, 0..) |*a, *e, index| {
            a.* = @truncate(index * 7 + length);
            e.* = a.* ^ key[index % 4];
        }
        mask(actual[0..length], key);
        try std.testing.expectEqualSlices(u8, expected[0..length], actual[0..length]);
        mask(actual[0..length], key);
        try std.testing.expect(length == 0 or actual[0] != expected[0]);
    }
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [32]u8 = undefined;
    const length = smith.slice(&bytes);
    const header = decode(bytes[0..length]) catch return;
    try std.testing.expect(header.header_length >= 6);
    try std.testing.expect(header.header_length <= length);

    var buffer: [encoded_length_max]u8 = undefined;
    const encoded = encode(&buffer, header.fin, header.opcode, header.payload_length);
    try std.testing.expectEqual(header.header_length, encoded.len + 4);
    try std.testing.expectEqual(bytes[0], encoded[0]);
    try std.testing.expectEqual(bytes[1] & 0x7f, encoded[1]);
    try std.testing.expectEqualSlices(u8, encoded[2..], bytes[2..encoded.len]);
}

test "decode agrees with encode on every input the fuzzer finds" {
    try std.testing.fuzz({}, fuzzDecode, .{ .corpus = &.{
        "\x0b\x00\x00\x00\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58",
        "\x08\x00\x00\x00\x82\xfe\x01\x00\x01\x02\x03\x04",
        "\x0e\x00\x00\x00\x82\xff\x00\x00\x00\x00\x00\x01\x00\x00\x01\x02\x03\x04",
    } });
}
