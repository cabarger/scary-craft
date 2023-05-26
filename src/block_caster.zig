const std = @import("std");
const rl = @cImport({
    @cInclude("raylib.h");
});

const Chunk = @import("Chunk.zig");
const Plane = @import("math/Plane.zig");

const BlockHit = struct {
    coords: rl.Vector3, // TODO(caleb): Vector3(i32)
    face: Plane.PlaneIndex,
};

/// Given a ray collision point, figure out the the world space block coords of the block being
/// selected and the face it is being selected from.
/// FIXME(caleb): This function breaks down at collisions with distance exceeding ~30 blocks.
pub fn blockHitFromPoint(chunk: *Chunk, p: rl.Vector3) BlockHit {
    var result: BlockHit = undefined;
    const block_x = @floatToInt(u8, p.x + rl.EPSILON);
    const block_y = @floatToInt(u8, p.y + rl.EPSILON);
    const block_z = @floatToInt(u8, p.z + rl.EPSILON);
    const val = chunk.fetch(block_x, block_y, block_z);
    if (val == 1) { // Left, bottom, or back face
        var plane: Plane = undefined;
        var point_on_face: rl.Vector3 = undefined;
        var face_normal: rl.Vector3 = undefined;

        // Left face
        point_on_face = rl.Vector3{ .x = @intToFloat(f32, block_x), .y = 0, .z = 0 };
        face_normal = rl.Vector3{ .x = 1, .y = 0, .z = 0 };
        plane = Plane{
            .normal = face_normal,
            .distance = rl.Vector3DotProduct(rl.Vector3Negate(face_normal), point_on_face),
        };
        if (std.math.approxEqAbs(f32, plane.distanceToPoint(p), 0, rl.EPSILON)) {
            result.face = Plane.PlaneIndex.left;
        } else { // Bottom face
            point_on_face = rl.Vector3{ .x = 0, .y = @intToFloat(f32, block_y), .z = 0 };
            face_normal = rl.Vector3{ .x = 0, .y = 1, .z = 0 };
            plane = Plane{
                .normal = face_normal,
                .distance = rl.Vector3DotProduct(rl.Vector3Negate(face_normal), point_on_face),
            };
            if (std.math.approxEqAbs(f32, plane.distanceToPoint(p), 0, rl.EPSILON)) {
                result.face = Plane.PlaneIndex.bottom;
            } else { // Back face
                point_on_face = rl.Vector3{ .x = 0, .y = 0, .z = @intToFloat(f32, block_z) };
                face_normal = rl.Vector3{ .x = 0, .y = 0, .z = 1 };
                plane = Plane{
                    .normal = face_normal,
                    .distance = rl.Vector3DotProduct(rl.Vector3Negate(face_normal), point_on_face),
                };
                if (std.math.approxEqAbs(f32, plane.distanceToPoint(p), 0, rl.EPSILON)) {
                    result.face = Plane.PlaneIndex.far;
                } else unreachable; // NOTE(caleb): This was reacached after flying far away and looking at a block.
            }
        }
        result.coords = rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z) };
    } else {
        if (std.math.approxEqRel(f32, @round(p.x), p.x, rl.EPSILON)) { // Right face
            result.coords = rl.Vector3{ .x = @intToFloat(f32, block_x - 1), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z) };
            result.face = Plane.PlaneIndex.right;
        } else if (std.math.approxEqRel(f32, @round(p.y), p.y, rl.EPSILON)) { // Top face
            result.coords = rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y - 1), .z = @intToFloat(f32, block_z) };
            result.face = Plane.PlaneIndex.top;
        } else if (std.math.approxEqRel(f32, @round(p.z), p.z, rl.EPSILON)) { // Front face
            result.coords = rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z - 1) };
            result.face = Plane.PlaneIndex.near;
        } else unreachable;
    }
    return result;
}
