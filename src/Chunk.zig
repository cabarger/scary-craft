const std = @import("std");
const scary_types = @import("scary_types.zig");

const BST = scary_types.BST;

const Self = @This();

pub const dim = @as(u16, 16);
pub const u_dim = std.meta.Int(std.builtin.Signedness.unsigned, std.math.log2_int(u16, std.math.ceilPowerOfTwoAssert(u16, dim)));

index: u32,
coords: @Vector(3, i32),
block_data: [dim * dim * dim]u8,

/// Sets block id at chunk relative coords (x, y, z)
pub inline fn put(self: *Self, val: u8, x: u8, y: u8, z: u8) void {
    self.block_data[@intCast(u16, dim * dim) * z + y * @intCast(u16, dim) + x] = val;
}

/// Return block id at chunk relative coords (x, y, z)
pub fn fetch(self: *const Self, x: u8, y: u8, z: u8) ?u8 {
    var result: ?u8 = null;
    if ((x < dim) and (y < dim) and (z < dim))
        result = self.block_data[@intCast(u16, dim * dim) * z + y * @intCast(u16, dim) + x];
    return result;
}
