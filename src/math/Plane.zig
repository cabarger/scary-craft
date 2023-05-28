const rl = @import("../rl.zig");
const Self = @This();

normal: rl.Vector3,
distance: f32,

/// Returns signed distance from this plane to a given point.
pub fn distanceToPoint(this: *const Self, point: rl.Vector3) f32 {
    var result = rl.Vector3DotProduct(this.normal, point) + this.distance;
    return result;
}

pub fn normalize(plane: *Self) void {
    const scale = 1 / rl.Vector3Length(plane.normal);
    plane.normal.x *= scale;
    plane.normal.y *= scale;
    plane.normal.z *= scale;
    plane.distance *= scale;
}
