const std = @import("std");
const assert = std.debug.assert;

pub const control_payload_max: u8 = 125;
pub const header_length_max: u8 = 14;

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
    const mask = [_]u8{ 1, 2, 3, 4 };
    const medium = try decode(&([_]u8{ 0x82, 0xfe, 0x01, 0x00 } ++ mask));
    try std.testing.expectEqual(256, medium.payload_length);
    try std.testing.expectEqual(8, medium.header_length);
    const large_prefix = [_]u8{ 0x82, 0xff, 0, 0, 0, 0, 0, 1, 0, 0 };
    const large = try decode(&(large_prefix ++ mask));
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
    const mask = [_]u8{ 1, 2, 3, 4 };
    const cases = [_][]const u8{
        &([_]u8{ 0xc1, 0x80 } ++ mask),
        &([_]u8{ 0xa1, 0x80 } ++ mask),
        &([_]u8{ 0x91, 0x80 } ++ mask),
        &([_]u8{ 0x83, 0x80 } ++ mask),
        &([_]u8{ 0x8b, 0x80 } ++ mask),
        &[_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' },
        &([_]u8{ 0x09, 0x80 } ++ mask),
        &([_]u8{ 0x89, 0xfe, 0, 126 } ++ mask),
        &([_]u8{ 0x88, 0xfe, 0, 126 } ++ mask),
        &([_]u8{ 0x81, 0xfe, 0, 5 } ++ mask),
        &([_]u8{ 0x81, 0xff, 0, 0, 0, 0, 0, 0, 0xff, 0xff } ++ mask),
        &([_]u8{ 0x81, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0 } ++ mask),
    };
    for (cases) |bytes| {
        try std.testing.expectError(error.ProtocolError, decode(bytes));
    }
}
