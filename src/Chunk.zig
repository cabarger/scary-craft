const scary_types = @import("scary_types.zig");

const BST = scary_types.BST;
const Vector3 = scary_types.Vector3;

const Self = @This();

pub const dim = Vector3(i32){ .x = 16, .y = 16, .z = 16 };

id: u32,
coords: Vector3(i32),
block_data: [dim.x * dim.y * dim.z]u8,

/// Sets block id at chunk relative coords (x, y, z)
pub inline fn put(self: *Self, val: u8, x: u8, y: u8, z: u8) void {
    self.block_data[@intCast(u16, dim.x * dim.y) * z + y * @intCast(u16, dim.x) + x] = val;
}

/// Return block id at chunk relative coords (x, y, z)
pub inline fn fetch(self: *const Self, x: u8, y: u8, z: u8) u8 {
    var result: u8 = undefined;
    result = self.block_data[@intCast(u16, dim.x * dim.y) * z + y * @intCast(u16, dim.x) + x];
    return result;
}