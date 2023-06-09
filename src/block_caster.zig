const std = @import("std");
const rl = @import("rl.zig");
const mesher = @import("mesher.zig");
const scary_types = @import("scary_types.zig");
const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const Plane = @import("math/Plane.zig");
const Frustum = @import("math/Frustum.zig");

pub const BlockHit = struct {
    coords: @Vector(3, u8),
    face: Frustum.PlaneIndex,
};

/// Just breathe it's ok
inline fn hackyWorldf32ToChunkRel(chunk_coords: @Vector(3, i32), pos: rl.Vector3) @Vector(3, u8) {
    const max_block_x = (chunk_coords[0] + 1) * Chunk.dim - 1; // NOTE(caleb): Inclusive
    const max_block_y = (chunk_coords[1] + 1) * Chunk.dim - 1;
    const max_block_z = (chunk_coords[2] + 1) * Chunk.dim - 1;

    var result: @Vector(3, u8) = undefined;
    if (@floatToInt(i32, @floor(pos.x)) <= max_block_x) {
        result[0] = @intCast(u8, @mod(@floatToInt(i32, @floor(pos.x)), @intCast(i32, Chunk.dim)));
    } else {
        result[0] = @intCast(u8, Chunk.dim);
    }

    if (@floatToInt(i32, @floor(pos.y)) <= max_block_y) {
        result[1] = @intCast(u8, @mod(@floatToInt(i32, @floor(pos.y)), @intCast(i32, Chunk.dim)));
    } else {
        result[1] = @intCast(u8, Chunk.dim);
    }

    if (@floatToInt(i32, @floor(pos.z)) <= max_block_z) {
        result[2] = @intCast(u8, @mod(@floatToInt(i32, @floor(pos.z)), @intCast(i32, Chunk.dim)));
    } else {
        result[2] = @intCast(u8, Chunk.dim);
    }

    return result;
}

/// Given a ray collision point, figure out the the world space block coords of the block being
/// selected and the face it is being selected from.
/// FIXME(caleb): This function breaks down at collisions with distance exceeding ~30 blocks.
pub fn blockHitFromPoint(chunk: *Chunk, p: rl.Vector3) BlockHit {
    var result: BlockHit = undefined;

    const chunk_rel_pos = hackyWorldf32ToChunkRel(chunk.coords, .{ .x = p.x + rl.EPSILON, .y = p.y + rl.EPSILON, .z = p.z + rl.EPSILON });
    const val = chunk.fetch(chunk_rel_pos[0], chunk_rel_pos[1], chunk_rel_pos[2]) orelse 0;
    if (val != 0) { // Left, bottom, or back face
        var plane: Plane = undefined;
        var point_on_face: rl.Vector3 = undefined;
        var face_normal: rl.Vector3 = undefined;

        // Left face
        point_on_face = rl.Vector3{ .x = @intToFloat(f32, @floatToInt(i32, @floor(p.x + rl.EPSILON))), .y = 0, .z = 0 };
        face_normal = rl.Vector3{ .x = 1, .y = 0, .z = 0 };
        plane = Plane{
            .normal = face_normal,
            .distance = rl.Vector3DotProduct(rl.Vector3Negate(face_normal), point_on_face),
        };
        if (std.math.approxEqAbs(f32, plane.distanceToPoint(p), 0, rl.EPSILON)) {
            result.face = Frustum.PlaneIndex.left;
        } else { // Bottom face
            point_on_face = rl.Vector3{ .x = 0, .y = @intToFloat(f32, @floatToInt(i32, @floor(p.y + rl.EPSILON))), .z = 0 };
            face_normal = rl.Vector3{ .x = 0, .y = 1, .z = 0 };
            plane = Plane{
                .normal = face_normal,
                .distance = rl.Vector3DotProduct(rl.Vector3Negate(face_normal), point_on_face),
            };
            if (std.math.approxEqAbs(f32, plane.distanceToPoint(p), 0, rl.EPSILON)) {
                result.face = Frustum.PlaneIndex.bottom;
            } else { // Back face
                point_on_face = rl.Vector3{ .x = 0, .y = 0, .z = @intToFloat(f32, @floatToInt(i32, @floor(p.z + rl.EPSILON))) };
                face_normal = rl.Vector3{ .x = 0, .y = 0, .z = 1 };
                plane = Plane{
                    .normal = face_normal,
                    .distance = rl.Vector3DotProduct(rl.Vector3Negate(face_normal), point_on_face),
                };
                if (std.math.approxEqAbs(f32, plane.distanceToPoint(p), 0, rl.EPSILON)) {
                    result.face = Frustum.PlaneIndex.far;
                } else unreachable;
            }
        }
        result.coords = chunk_rel_pos;
    } else {
        if (std.math.approxEqAbs(f32, @round(p.x), p.x, rl.EPSILON)) { // Right face
            result.coords = @Vector(3, u8){ chunk_rel_pos[0] - 1, chunk_rel_pos[1], chunk_rel_pos[2] };
            result.face = Frustum.PlaneIndex.right;
        } else if (std.math.approxEqAbs(f32, @round(p.y), p.y, rl.EPSILON)) { // Top face
            result.coords = @Vector(3, u8){ chunk_rel_pos[0], chunk_rel_pos[1] - 1, chunk_rel_pos[2] };
            result.face = Frustum.PlaneIndex.top;
        } else if (std.math.approxEqAbs(f32, @round(p.z), p.z, rl.EPSILON)) { // Front face
            result.coords = @Vector(3, u8){ chunk_rel_pos[0], chunk_rel_pos[1], chunk_rel_pos[2] - 1 };
            result.face = Frustum.PlaneIndex.near;
        } else {
            std.debug.print("Front face: {d}, {d}\n", .{ @round(p.z), p.z });
            std.debug.print("Top face: {d}, {d}\n", .{ @round(p.y), p.y });
            std.debug.print("Right face: {d}, {d}\n", .{ @round(p.x), p.x });
            unreachable;
        }
    }
    return result;
}
