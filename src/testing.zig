const std = @import("std");
const frame = @import("frame.zig");

const mask_key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

pub fn clientFrame(
    buffer: []u8,
    fin: bool,
    opcode: frame.Opcode,
    payload: []const u8,
) []const u8 {
    var header_buffer: [frame.encoded_length_max]u8 = undefined;
    const header = frame.encode(&header_buffer, fin, opcode, payload.len);
    @memcpy(buffer[0..header.len], header);
    buffer[1] |= 0x80;
    @memcpy(buffer[header.len..][0..4], &mask_key);
    const body = buffer[header.len + 4 ..][0..payload.len];
    @memcpy(body, payload);
    frame.mask(body, mask_key);
    return buffer[0 .. header.len + 4 + payload.len];
}

test "clientFrame produces the RFC 6455 section 5.7 masked text frame" {
    var buffer: [16]u8 = undefined;
    const bytes = clientFrame(&buffer, true, .text, "Hello");
    const expected = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}
