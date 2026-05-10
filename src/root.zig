pub const frame = @import("frame.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
