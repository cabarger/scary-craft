const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rcamera.h");
});
const Plane = @import("Plane.zig");
const AABB = @import("AABB.zig");

const Self = @This();

const PlaneIndex = enum(u8) {
    top = 0,
    bottom,
    left,
    right,
    near,
    far,
};

planes: [6]Plane,

/// Returns true if any point of the aabb exists in postivie halfspace of all planes in this frustum.
pub fn containsAABB(this: *const Self, aabb: *AABB) bool {
    var points_in_frustum: u8 = 8;
    var verticies: [8]rl.Vector3 = undefined;
    aabb.getVertices(&verticies);
    for (verticies) |point| {
        if (!this.containsPoint(point)) {
            points_in_frustum -= 1;
            break;
        }
    }
    if (points_in_frustum > 0)
        return true;
    return false;
}

pub fn containsPoint(this: *const Self, point: rl.Vector3) bool {
    for (this.planes) |plane| {
        if (plane.distanceToPoint(point) < 0) {
            return false;
        }
    }
    return true;
}

/// Gribb-Hartmann viewing frustum extraction.
pub fn extractFrustum(camera: *rl.Camera, aspect: f32) Self {
    var result: Self = undefined;

    const viewmat = rl.MatrixLookAt(camera.position, camera.target, camera.up);
    const projmat = rl.MatrixPerspective(camera.fovy * rl.DEG2RAD, aspect, rl.CAMERA_CULL_DISTANCE_NEAR, rl.CAMERA_CULL_DISTANCE_FAR);
    const combomat = rl.MatrixMultiply(projmat, viewmat);

    // Left plane
    result.planes[@enumToInt(PlaneIndex.left)].normal.x = combomat.m12 + combomat.m0;
    result.planes[@enumToInt(PlaneIndex.left)].normal.y = combomat.m13 + combomat.m1;
    result.planes[@enumToInt(PlaneIndex.left)].normal.z = combomat.m14 + combomat.m2;
    result.planes[@enumToInt(PlaneIndex.left)].distance = combomat.m15 + combomat.m3;

    // Right plane
    result.planes[@enumToInt(PlaneIndex.right)].normal.x = combomat.m12 - combomat.m0;
    result.planes[@enumToInt(PlaneIndex.right)].normal.y = combomat.m13 - combomat.m1;
    result.planes[@enumToInt(PlaneIndex.right)].normal.z = combomat.m14 - combomat.m2;
    result.planes[@enumToInt(PlaneIndex.right)].distance = combomat.m15 - combomat.m3;

    // Bottom plane
    result.planes[@enumToInt(PlaneIndex.bottom)].normal.x = combomat.m12 + combomat.m4;
    result.planes[@enumToInt(PlaneIndex.bottom)].normal.y = combomat.m13 + combomat.m5;
    result.planes[@enumToInt(PlaneIndex.bottom)].normal.z = combomat.m14 + combomat.m6;
    result.planes[@enumToInt(PlaneIndex.bottom)].distance = combomat.m15 + combomat.m7;

    // Top plane
    result.planes[@enumToInt(PlaneIndex.top)].normal.x = combomat.m12 - combomat.m4;
    result.planes[@enumToInt(PlaneIndex.top)].normal.y = combomat.m13 - combomat.m5;
    result.planes[@enumToInt(PlaneIndex.top)].normal.z = combomat.m14 - combomat.m6;
    result.planes[@enumToInt(PlaneIndex.top)].distance = combomat.m15 - combomat.m7;

    // Near plane
    result.planes[@enumToInt(PlaneIndex.near)].normal.x = combomat.m12 + combomat.m8;
    result.planes[@enumToInt(PlaneIndex.near)].normal.y = combomat.m13 + combomat.m9;
    result.planes[@enumToInt(PlaneIndex.near)].normal.z = combomat.m14 + combomat.m10;
    result.planes[@enumToInt(PlaneIndex.near)].distance = combomat.m15 + combomat.m11;

    // Far plane
    result.planes[@enumToInt(PlaneIndex.far)].normal.x = combomat.m12 - combomat.m8;
    result.planes[@enumToInt(PlaneIndex.far)].normal.y = combomat.m13 - combomat.m9;
    result.planes[@enumToInt(PlaneIndex.far)].normal.z = combomat.m14 - combomat.m10;
    result.planes[@enumToInt(PlaneIndex.far)].distance = combomat.m15 - combomat.m11;

    // Remember to normalize each plane
    for (&result.planes) |*plane|
        plane.normalize();

    return result;
}
