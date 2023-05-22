const std = @import("std");

const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rcamera.h");
    @cInclude("rlgl.h");
});

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const hashString = std.hash_map.hashString;

// TODO(caleb):
// -----------------------------------------------------------------------------------
// World space coords to chunk space coords function
// Player collision volume
// Gravity/Jump

// OBJECTIVES (possibly in the form of notes that you can pick up?)
// INSERT SCARY ENEMY IDEAS HERE...

const block_dim = rl.Vector3{ .x = 1, .y = 1, .z = 1 };
const chunk_dim = rl.Vector3{ .x = 16, .y = 16, .z = 16 };

const crosshair_thickness_in_pixels = 2;
const crosshair_length_in_pixels = 20;

const fovy = 60.0;
const target_range_in_blocks = 4;
const meters_per_block = 1;
const move_speed_blocks_per_second = 3;
const mouse_sens = 0.1;

const font_size = 20;
const font_spacing = 2;

const target_fps = 120;

const SpriteSheet = struct {
    columns: u16,
    texture: rl.Texture,
    name_to_id: AutoHashMap(u64, u16),
};

const Plane = struct {
    normal: rl.Vector3,
    distance: f32,

    /// Returns signed distance from this plane to a given point.
    pub fn distanceToPoint(this: *const Plane, point: rl.Vector3) f32 {
        var result = rl.Vector3DotProduct(this.normal, point) + this.distance;
        return result;
    }

    pub fn normalize(plane: *Plane) void {
        const scale = 1 / rl.Vector3Length(plane.normal);
        plane.normal.x *= scale;
        plane.normal.y *= scale;
        plane.normal.z *= scale;
        plane.distance *= scale;
    }
};

const Frustum = struct {
    planes: [6]Plane,

    /// Returns true if any point of the aabb exists in postivie halfspace of all planes in this frustum.
    pub fn containsAABB(this: *const Frustum, aabb: *AABB) bool {
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

    pub fn containsPoint(this: *const Frustum, point: rl.Vector3) bool {
        for (this.planes) |plane| {
            if (plane.distanceToPoint(point) < 0) {
                return false;
            }
        }
        return true;
    }
};

const PlaneIndex = enum(u8) {
    top = 0,
    bottom,
    left,
    right,
    near,
    far,
};

const BlockHit = struct {
    coords: rl.Vector3,
    face: PlaneIndex,
};

/// Gribb-Hartmann viewing frustum extraction.
fn extractFrustum(camera: *rl.Camera, aspect: f32) Frustum {
    var result: Frustum = undefined;

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

const AABB = struct {
    min: rl.Vector3,
    max: rl.Vector3,

    pub fn getVertices(this: *AABB, verticies: []rl.Vector3) void {
        std.debug.assert(verticies.len == 8);

        verticies[0] = rl.Vector3{ .x = this.min.x, .y = this.min.y, .z = this.min.z }; // fbl
        verticies[1] = rl.Vector3{ .x = this.min.x, .y = this.max.y, .z = this.min.z }; // ftl
        verticies[2] = rl.Vector3{ .x = this.max.x, .y = this.min.y, .z = this.min.z }; // fbr
        verticies[3] = rl.Vector3{ .x = this.max.x, .y = this.max.y, .z = this.min.z }; // ftr

        verticies[4] = rl.Vector3{ .x = this.min.x, .y = this.min.y, .z = this.max.z }; // nbl
        verticies[5] = rl.Vector3{ .x = this.min.x, .y = this.max.y, .z = this.max.z }; // ntl
        verticies[6] = rl.Vector3{ .x = this.max.x, .y = this.min.y, .z = this.max.z }; // nbr
        verticies[7] = rl.Vector3{ .x = this.max.x, .y = this.max.y, .z = this.max.z }; // ntr
    }

    fn getVectorP(this: *AABB, normal: rl.Vector3) rl.Vector3 {
        var result = this.min;
        if (normal.x >= 0) {
            result.x += this.max.x;
        }
        if (normal.y >= 0) {
            result.y += this.max.y;
        }
        if (normal.z >= 0) {
            result.z += this.max.z;
        }
        return result;
    }
};

const Light = struct {
    enabled: c_int,
    type: c_int,
    position: [3]f32,
    target: [3]f32,
    color: [4]f32,

    enabled_loc: c_int,
    type_loc: c_int,
    position_loc: c_int,
    target_loc: c_int,
    color_loc: c_int,
};

const Direction = enum {
    up,
    down,
    right,
    left,
    forward,
    backward,
};

/// Unload mesh from memory (RAM and VRAM)
fn unloadMesh(mesh: rl.Mesh) void {

    // Unload rlgl mesh vboId data
    rl.rlUnloadVertexArray(mesh.vaoId);
    if (mesh.vboId != null) {
        const max_mesh_vertex_buffers = 7;
        var vertex_buffer_index: u8 = 0;
        while (vertex_buffer_index < max_mesh_vertex_buffers) : (vertex_buffer_index += 1) {
            rl.rlUnloadVertexBuffer(mesh.vboId[vertex_buffer_index]);
        }
    }
    rl.MemFree(mesh.vboId);
}

fn updateLightValues(shader: rl.Shader, light: *Light) void {

    // Send to shader light enabled state and type
    rl.SetShaderValue(shader, light.enabled_loc, &light.enabled, rl.SHADER_UNIFORM_INT);
    rl.SetShaderValue(shader, light.type_loc, &light.type, rl.SHADER_UNIFORM_INT);

    // Send to shader light position, target, and color values
    rl.SetShaderValue(shader, light.position_loc, &light.position, rl.SHADER_UNIFORM_VEC3);
    rl.SetShaderValue(shader, light.target_loc, &light.target, rl.SHADER_UNIFORM_VEC3);
    rl.SetShaderValue(shader, light.color_loc, &light.color, rl.SHADER_UNIFORM_VEC4);
}

inline fn denseMapPut(dense_map: []i16, val: i16, x: i16, y: i16, z: i16) void {
    const map_width = @floatToInt(u16, chunk_dim.x);
    const map_height = @floatToInt(u16, chunk_dim.y);
    dense_map[map_width * map_height * @intCast(u16, z) + @intCast(u16, y) * map_width + @intCast(u16, x)] = val;
}

inline fn denseMapLookup(dense_map: []i16, x: i16, y: i16, z: i16) ?i16 {
    const map_width = @floatToInt(u16, chunk_dim.x);
    const map_height = @floatToInt(u16, chunk_dim.y);
    const map_length = @floatToInt(u16, chunk_dim.z);
    if (x >= map_width or y >= map_height or z >= map_length or x < 0 or y < 0 or z < 0)
        return null; // Block index out of bounds.
    return dense_map[map_width * map_height * @intCast(u16, z) + @intCast(u16, y) * map_width + @intCast(u16, x)];
}

fn blockHitFromPoint(dense_map: []i16, p: rl.Vector3) BlockHit {
    var result: BlockHit = undefined;
    const block_x = @floatToInt(i16, p.x + rl.EPSILON);
    const block_y = @floatToInt(i16, p.y + rl.EPSILON);
    const block_z = @floatToInt(i16, p.z + rl.EPSILON);
    const val = denseMapLookup(dense_map, block_x, block_y, block_z);
    if (val != null and val.? == 1) { // Left, bottom, or back face
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
            result.face = PlaneIndex.left;
        } else { // Bottom face
            point_on_face = rl.Vector3{ .x = 0, .y = @intToFloat(f32, block_y), .z = 0 };
            face_normal = rl.Vector3{ .x = 0, .y = 1, .z = 0 };
            plane = Plane{
                .normal = face_normal,
                .distance = rl.Vector3DotProduct(rl.Vector3Negate(face_normal), point_on_face),
            };
            if (std.math.approxEqAbs(f32, plane.distanceToPoint(p), 0, rl.EPSILON)) {
                result.face = PlaneIndex.bottom;
            } else { // Back face
                point_on_face = rl.Vector3{ .x = 0, .y = 0, .z = @intToFloat(f32, block_z) };
                face_normal = rl.Vector3{ .x = 0, .y = 0, .z = 1 };
                plane = Plane{
                    .normal = face_normal,
                    .distance = rl.Vector3DotProduct(rl.Vector3Negate(face_normal), point_on_face),
                };
                if (std.math.approxEqAbs(f32, plane.distanceToPoint(p), 0, rl.EPSILON)) {
                    result.face = PlaneIndex.far;
                } else unreachable;
            }
        }
        result.coords = rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z) };
    } else {
        if (std.math.approxEqRel(f32, @round(p.x), p.x, rl.EPSILON)) { // Right face
            result.coords = rl.Vector3{ .x = @intToFloat(f32, block_x - 1), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z) };
            result.face = PlaneIndex.right;
        } else if (std.math.approxEqRel(f32, @round(p.y), p.y, rl.EPSILON)) { // Top face
            result.coords = rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y - 1), .z = @intToFloat(f32, block_z) };
            result.face = PlaneIndex.top;
        } else if (std.math.approxEqRel(f32, @round(p.z), p.z, rl.EPSILON)) { // Front face
            result.coords = rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z - 1) };
            result.face = PlaneIndex.near;
        } else unreachable;
    }
    return result;
}

inline fn setNormal3f(normals: []f32, normals_offset: *u32, x: f32, y: f32, z: f32) void {
    normals[normals_offset.*] = x;
    normals[normals_offset.* + 1] = y;
    normals[normals_offset.* + 2] = z;
    normals_offset.* += 3;
}

inline fn setFaceNormals(normals: []f32, normals_offset: *u32, x: f32, y: f32, z: f32) void {
    var normal_index: u8 = 0;
    while (normal_index < 6) : (normal_index += 1)
        setNormal3f(normals, normals_offset, x, y, z);
}

inline fn setTexcoord2f(texcoords: []f32, texcoords_offset: *u32, x: f32, y: f32) void {
    texcoords[texcoords_offset.*] = x;
    texcoords[texcoords_offset.* + 1] = y;
    texcoords_offset.* += 2;
}

inline fn setVertex3f(verticies: []f32, verticies_offset: *u32, x: f32, y: f32, z: f32) void {
    verticies[verticies_offset.*] = x;
    verticies[verticies_offset.* + 1] = y;
    verticies[verticies_offset.* + 2] = z;
    verticies_offset.* += 3;
}

inline fn solidBlock(dense_map: []i16, x: i16, y: i16, z: i16) bool {
    var result = false;
    if (denseMapLookup(dense_map, x, y, z)) |block| {
        if (block == 1)
            result = true;
    }
    return result;
}

/// Generate chunk sized mesh starting at world origin.
fn cullMesh(ally: Allocator, dense_map: []i16, sprite_sheet: *SpriteSheet) !rl.Mesh {
    var result = std.mem.zeroes(rl.Mesh);
    var face_count: c_int = 0;
    {
        var block_y: f32 = 0;
        while (block_y < chunk_dim.y) : (block_y += 1) {
            var block_z: f32 = 0;
            while (block_z < chunk_dim.z) : (block_z += 1) {
                var block_x: f32 = 0;
                while (block_x < chunk_dim.x) : (block_x += 1) {
                    const curr_block = denseMapLookup(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y), @floatToInt(i16, block_z)) orelse unreachable;
                    if (curr_block == 0)
                        continue;
                    face_count += if (!solidBlock(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y + 1), @floatToInt(i16, block_z))) 1 else 0; // Top face
                    face_count += if (!solidBlock(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y - 1), @floatToInt(i16, block_z))) 1 else 0; // Bottom face
                    face_count += if (!solidBlock(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y), @floatToInt(i16, block_z + 1))) 1 else 0; // Front face
                    face_count += if (!solidBlock(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y), @floatToInt(i16, block_z - 1))) 1 else 0; // Back face
                    face_count += if (!solidBlock(dense_map, @floatToInt(i16, block_x + 1), @floatToInt(i16, block_y), @floatToInt(i16, block_z))) 1 else 0; // Right face
                    face_count += if (!solidBlock(dense_map, @floatToInt(i16, block_x - 1), @floatToInt(i16, block_y), @floatToInt(i16, block_z))) 1 else 0; // Left face
                }
            }
        }
    }

    result.triangleCount = face_count * 2;
    result.vertexCount = result.triangleCount * 3;
    var normals = try ally.alloc(f32, @intCast(u32, result.vertexCount * 3));
    var texcoords = try ally.alloc(f32, @intCast(u32, result.vertexCount * 2));
    var verticies = try ally.alloc(f32, @intCast(u32, result.vertexCount * 3));
    std.debug.print("required bytes: {d}\n", .{normals.len * 3 + texcoords.len * 3 + verticies.len * 3});
    var normals_offset: u32 = 0;
    var texcoords_offset: u32 = 0;
    var verticies_offset: u32 = 0;

    // TODO(caleb): Texture coords per block.
    const grass_id = sprite_sheet.name_to_id.get(hashString("default_grass")) orelse unreachable;
    const grass_tile_row = @divTrunc(grass_id, sprite_sheet.columns);
    const grass_tile_column = @mod(grass_id, sprite_sheet.columns);
    const grass_texcoord_start_x = 128 * @intToFloat(f32, grass_tile_column) / @intToFloat(f32, sprite_sheet.texture.width);
    const grass_texcoord_end_x = grass_texcoord_start_x + 128 / @intToFloat(f32, sprite_sheet.texture.width);
    const grass_texcoord_start_y = 128 * @intToFloat(f32, grass_tile_row) / @intToFloat(f32, sprite_sheet.texture.height);
    const grass_texcoord_end_y = grass_texcoord_start_y + 128 / @intToFloat(f32, sprite_sheet.texture.height);

    const dirt_id = sprite_sheet.name_to_id.get(hashString("default_dirt")) orelse unreachable;
    const dirt_tile_row = @divTrunc(dirt_id, sprite_sheet.columns);
    const dirt_tile_column = @mod(dirt_id, sprite_sheet.columns);
    const dirt_texcoord_start_x = 128 * @intToFloat(f32, dirt_tile_column) / @intToFloat(f32, sprite_sheet.texture.width);
    const dirt_texcoord_end_x = dirt_texcoord_start_x + 128 / @intToFloat(f32, sprite_sheet.texture.width);
    const dirt_texcoord_start_y = 128 * @intToFloat(f32, dirt_tile_row) / @intToFloat(f32, sprite_sheet.texture.height);
    const dirt_texcoord_end_y = dirt_texcoord_start_y + 128 / @intToFloat(f32, sprite_sheet.texture.height);

    {
        var block_y: f32 = 0;
        while (block_y < chunk_dim.y) : (block_y += 1) {
            var block_z: f32 = 0;
            while (block_z < chunk_dim.z) : (block_z += 1) {
                var block_x: f32 = 0;
                while (block_x < chunk_dim.x) : (block_x += 1) {
                    const curr_block = denseMapLookup(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y), @floatToInt(i16, block_z)) orelse unreachable;
                    if (curr_block == 0) // No block here so don't worry about writing mesh data
                        continue;

                    // Top Face
                    if (!solidBlock(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y + 1), @floatToInt(i16, block_z))) {
                        setFaceNormals(normals, &normals_offset, 0, 1, 0); // Normals pointing up
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_start_x, grass_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_end_x, grass_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_start_x, grass_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_start_x, grass_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_end_x, grass_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z + block_dim.z); // Bottom right texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_end_x, grass_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z); // Top right texture and vertex
                    }

                    // Front face
                    if (!solidBlock(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y), @floatToInt(i16, block_z + 1))) {
                        setFaceNormals(normals, &normals_offset, 0, 0, 1); // Normals pointing towards viewer
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z + block_dim.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z + block_dim.z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z + block_dim.z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z + block_dim.z); // Top right texture and vertex
                    }

                    // Back face
                    if (!solidBlock(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y), @floatToInt(i16, block_z - 1))) {
                        setFaceNormals(normals, &normals_offset, 0, 0, -1); // Normals pointing away from viewer
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z); // Top right texture and vertex
                    }

                    // Bottom face
                    if (!solidBlock(dense_map, @floatToInt(i16, block_x), @floatToInt(i16, block_y - 1), @floatToInt(i16, block_z))) {
                        setFaceNormals(normals, &normals_offset, 0.0, -1.0, 0.0); // Normals pointing down
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z + block_dim.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z + block_dim.z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z + block_dim.z); // Top right texture and vertex
                    }

                    // Right face
                    if (!solidBlock(dense_map, @floatToInt(i16, block_x + 1), @floatToInt(i16, block_y), @floatToInt(i16, block_z))) {
                        setFaceNormals(normals, &normals_offset, 1.0, 0.0, 0.0); // Normals pointing right
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z + block_dim.z); // Bottom left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z); // Top right of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z + block_dim.z); // Top left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z + block_dim.z); // Bottom left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y, block_z); // Bottom right of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x + block_dim.x, block_y + block_dim.y, block_z); // Top right of the texture and vertex
                    }

                    // Left Face
                    if (!solidBlock(dense_map, @floatToInt(i16, block_x - 1), @floatToInt(i16, block_y), @floatToInt(i16, block_z))) {
                        setFaceNormals(normals, &normals_offset, -1.0, 0.0, 0.0); // Normals Pointing Left
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z); // Bottom left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z + block_dim.z); // Top right of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z); // Top left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z); // Bottom left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y, block_z + block_dim.z); // Bottom right of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_x, block_y + block_dim.y, block_z + block_dim.z); // Top right of the texture and texture
                    }
                }
            }
        }
    }

    result.normals = @ptrCast([*c]f32, normals);
    result.texcoords = @ptrCast([*c]f32, texcoords);
    result.vertices = @ptrCast([*c]f32, verticies);

    return result;
}

inline fn lookDirection(direction: rl.Vector3) Direction {
    var look_direction: Direction = undefined;

    const up_dot = rl.Vector3DotProduct(direction, rl.Vector3{ .x = 0, .y = 1, .z = 0 });
    const down_dot = rl.Vector3DotProduct(direction, rl.Vector3{ .x = 0, .y = -1, .z = 0 });
    const right_dot = rl.Vector3DotProduct(direction, rl.Vector3{ .x = 1, .y = 0, .z = 0 });
    const left_dot = rl.Vector3DotProduct(direction, rl.Vector3{ .x = -1, .y = 0, .z = 0 });
    const forward_dot = rl.Vector3DotProduct(direction, rl.Vector3{ .x = 0, .y = 0, .z = -1 });
    const backward_dot = rl.Vector3DotProduct(direction, rl.Vector3{ .x = 0, .y = 0, .z = 1 });

    look_direction = Direction.up;
    var closest_look_dot = up_dot;
    if (down_dot > closest_look_dot) {
        look_direction = Direction.down;
        closest_look_dot = down_dot;
    }
    if (right_dot > closest_look_dot) {
        look_direction = Direction.right;
        closest_look_dot = right_dot;
    }
    if (left_dot > closest_look_dot) {
        look_direction = Direction.left;
        closest_look_dot = left_dot;
    }
    if (forward_dot > closest_look_dot) {
        look_direction = Direction.forward;
        closest_look_dot = forward_dot;
    }
    if (backward_dot > closest_look_dot) {
        look_direction = Direction.backward;
    }

    return look_direction;
}

pub fn main() !void {
    const screen_width: c_int = 1920;
    const screen_height: c_int = 1080;
    rl.InitWindow(screen_width, screen_height, "Scary Craft");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(target_fps);
    rl.DisableCursor();

    var page_ally = std.heap.page_allocator;
    var back_buffer = try page_ally.alloc(u8, 1024 * 1024 * 1); // 1mb
    var fb_ally = std.heap.FixedBufferAllocator.init(back_buffer);
    var arena_ally = std.heap.ArenaAllocator.init(fb_ally.allocator());

    const font = rl.LoadFont("data/FiraCode-Medium.ttf");

    var sprite_sheet: SpriteSheet = undefined;
    sprite_sheet.texture = rl.LoadTexture("data/atlas.png");
    sprite_sheet.name_to_id = AutoHashMap(u64, u16).init(arena_ally.allocator());
    {
        var tmp_arena_state = arena_ally.state;
        defer arena_ally = tmp_arena_state.promote(fb_ally.allocator());

        var parser = std.json.Parser.init(arena_ally.allocator(), std.json.AllocWhen.alloc_if_needed);

        const atlas_data_file = try std.fs.cwd().openFile("data/atlas_data.json", .{});
        defer atlas_data_file.close();

        var raw_atlas_json = try atlas_data_file.reader().readAllAlloc(arena_ally.allocator(), 1024 * 2); // 2kib should be enough

        var parsed_atlas_data = try parser.parse(raw_atlas_json);
        const columns_value = parsed_atlas_data.root.object.get("columns") orelse unreachable;
        sprite_sheet.columns = @intCast(u16, columns_value.integer);

        const tile_data = parsed_atlas_data.root.object.get("tiles") orelse unreachable;
        for (tile_data.array.items) |tile| {
            var tile_id = tile.object.get("id") orelse unreachable;
            var tile_type = tile.object.get("type") orelse unreachable;
            try sprite_sheet.name_to_id.put(hashString(tile_type.string), @intCast(u16, tile_id.integer));
        }
    }

    var shader: rl.Shader = rl.LoadShader(rl.TextFormat("data/shaders/lighting.vs", @intCast(c_int, 330)), rl.TextFormat("data/shaders/lighting.fs", @intCast(c_int, 330)));
    shader.locs[rl.SHADER_LOC_VECTOR_VIEW] = rl.GetShaderLocation(shader, "viewPos");

    const ambient_loc = rl.GetShaderLocation(shader, "ambient");
    rl.SetShaderValue(shader, ambient_loc, &[_]f32{ 0.01, 0.01, 0.01, 1.0 }, rl.SHADER_UNIFORM_VEC4);

    var light_source: Light = undefined;
    light_source.enabled_loc = rl.GetShaderLocation(shader, "light.enabled");
    light_source.type_loc = rl.GetShaderLocation(shader, "light.type");
    light_source.position_loc = rl.GetShaderLocation(shader, "light.position");
    light_source.target_loc = rl.GetShaderLocation(shader, "light.target");
    light_source.color_loc = rl.GetShaderLocation(shader, "light.color");
    light_source.color = [4]f32{ 1, 1, 1, 1 };

    var default_material = rl.LoadMaterialDefault();
    default_material.shader = shader;
    rl.SetMaterialTexture(&default_material, rl.MATERIAL_MAP_DIFFUSE, sprite_sheet.texture);

    var debug_axes = false;
    var debug_text_info = false;

    var camera: rl.Camera = undefined;
    camera.position = rl.Vector3{ .x = 0.0, .y = 10.0, .z = 10.0 };
    camera.target = rl.Vector3{ .x = 0.0, .y = 0.0, .z = -1.0 };
    camera.up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = fovy;
    camera.projection = rl.CAMERA_PERSPECTIVE;

    // Create a chunk slice 16x16 at y = 0;
    var dense_map = try arena_ally.allocator().alloc(i16, @floatToInt(i16, chunk_dim.x * chunk_dim.y * chunk_dim.z));
    for (dense_map) |*item|
        item.* = 0;

    var block_z: u16 = 0;
    while (block_z < @floatToInt(i16, chunk_dim.z)) : (block_z += 1) {
        var block_x: u16 = 0;
        while (block_x < @floatToInt(i16, chunk_dim.x)) : (block_x += 1) {
            dense_map[@floatToInt(u16, chunk_dim.x * chunk_dim.y) * block_z + block_x] = 1;
        }
    }

    // Reserve 512Kb for a chunk mesh
    var chunk_mem = try arena_ally.allocator().alloc(u8, 512 * 1024);
    var chunk_fb_ally = FixedBufferAllocator.init(chunk_mem);

    // Initial chunk mesh
    var chunk_mesh = try cullMesh(chunk_fb_ally.allocator(), dense_map, &sprite_sheet);
    rl.UploadMesh(&chunk_mesh, false);

    while (!rl.WindowShouldClose()) {
        const screen_dim = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()), .y = @intToFloat(f32, rl.GetScreenHeight()) };
        const screen_mid = rl.Vector2Scale(screen_dim, 0.5);
        const aspect = screen_dim.x / screen_dim.y;

        if (rl.IsKeyPressed(rl.KEY_F1)) {
            debug_axes = !debug_axes;
            debug_text_info = !debug_text_info;
        }

        var speed_scalar: f32 = 1;
        if (rl.IsKeyDown(rl.KEY_LEFT_SHIFT)) {
            speed_scalar = 2;
        }

        var camera_move = rl.Vector3{ .x = 0, .y = 0, .z = 0 };
        if (rl.IsKeyDown(rl.KEY_W)) {
            camera_move.x += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_S)) {
            camera_move.x -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_A)) {
            camera_move.y -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_D)) {
            camera_move.y += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_SPACE)) {
            camera_move.z += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_LEFT_CONTROL)) {
            camera_move.z -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }

        rl.UpdateCameraPro(&camera, camera_move, rl.Vector3{ .x = rl.GetMouseDelta().x * mouse_sens, .y = rl.GetMouseDelta().y * mouse_sens, .z = 0 }, 0); //rl.GetMouseWheelMove());

        // Update uniform shader values.
        const camera_position = [3]f32{ camera.position.x, camera.position.y, camera.position.z };
        const camera_target = [3]f32{ camera.target.x, camera.target.y, camera.target.z };
        light_source.position = camera_position;
        light_source.target = camera_target;
        updateLightValues(shader, &light_source);
        rl.SetShaderValue(shader, shader.locs[rl.SHADER_LOC_VECTOR_VIEW], &camera_position, rl.SHADER_UNIFORM_VEC3);

        const crosshair_ray = rl.Ray{ .position = camera.position, .direction = rl.GetCameraForward(&camera) };
        const crosshair_ray_collision = rl.GetRayCollisionMesh(crosshair_ray, chunk_mesh, rl.MatrixIdentity());
        const look_direction = lookDirection(crosshair_ray.direction);

        var target_block: BlockHit = undefined;
        if (crosshair_ray_collision.hit) {
            target_block = blockHitFromPoint(dense_map, crosshair_ray_collision.point);

            if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) { // Break block
                denseMapPut(dense_map, 0, @floatToInt(i16, target_block.coords.x), @floatToInt(i16, target_block.coords.y), @floatToInt(i16, target_block.coords.z));

                // Update chunk mesh
                unloadMesh(chunk_mesh);
                chunk_fb_ally.reset();
                chunk_mesh = try cullMesh(chunk_fb_ally.allocator(), dense_map, &sprite_sheet);
                rl.UploadMesh(&chunk_mesh, false);
            } else if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_RIGHT)) {
                switch (target_block.face) {
                    .top => denseMapPut(dense_map, 1, @floatToInt(i16, target_block.coords.x), @floatToInt(i16, target_block.coords.y) + 1, @floatToInt(i16, target_block.coords.z)),
                    .bottom => denseMapPut(dense_map, 1, @floatToInt(i16, target_block.coords.x), @floatToInt(i16, target_block.coords.y) - 1, @floatToInt(i16, target_block.coords.z)),
                    .left => denseMapPut(dense_map, 1, @floatToInt(i16, target_block.coords.x) - 1, @floatToInt(i16, target_block.coords.y), @floatToInt(i16, target_block.coords.z)),
                    .right => denseMapPut(dense_map, 1, @floatToInt(i16, target_block.coords.x) + 1, @floatToInt(i16, target_block.coords.y), @floatToInt(i16, target_block.coords.z)),
                    .near => denseMapPut(dense_map, 1, @floatToInt(i16, target_block.coords.x), @floatToInt(i16, target_block.coords.y), @floatToInt(i16, target_block.coords.z) + 1),
                    .far => denseMapPut(dense_map, 1, @floatToInt(i16, target_block.coords.x), @floatToInt(i16, target_block.coords.y), @floatToInt(i16, target_block.coords.z) - 1),
                }

                // Update chunk mesh
                unloadMesh(chunk_mesh);
                chunk_fb_ally.reset();
                chunk_mesh = try cullMesh(chunk_fb_ally.allocator(), dense_map, &sprite_sheet);
                rl.UploadMesh(&chunk_mesh, false);
            }
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.BeginMode3D(camera);

        const frustum = extractFrustum(&camera, aspect);
        var chunk_box = AABB{ .min = rl.Vector3Zero(), .max = rl.Vector3Add(rl.Vector3Zero(), chunk_dim) };

        var should_draw_chunk = false;
        if (frustum.containsAABB(&chunk_box)) { // FIXME(caleb): This is still borked...
            should_draw_chunk = true;
        }

        // Only draw this mesh if it's within the view frustum
        if (should_draw_chunk)
            rl.DrawMesh(chunk_mesh, default_material, rl.MatrixIdentity());

        rl.EndMode3D();

        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = -crosshair_length_in_pixels, .y = 0 }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = crosshair_length_in_pixels, .y = 0 }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = 0, .y = -crosshair_length_in_pixels }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = 0, .y = crosshair_length_in_pixels }), crosshair_thickness_in_pixels, rl.WHITE);

        if (debug_text_info) {
            var strz_buffer: [256]u8 = undefined;
            const fps_strz = try std.fmt.bufPrintZ(&strz_buffer, "FPS:{d}", .{rl.GetFPS()});
            const fps_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, fps_strz), font_size, font_spacing);
            rl.DrawTextEx(font, @ptrCast([*c]const u8, fps_strz), rl.Vector2{ .x = 0, .y = 0 }, font_size, font_spacing, rl.WHITE);

            const camera_pos_strz = try std.fmt.bufPrintZ(&strz_buffer, "camera pos: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ camera.position.x, camera.position.y, camera.position.z });
            const camera_pos_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, camera_pos_strz), font_size, font_spacing);
            rl.DrawTextEx(font, @ptrCast([*c]const u8, camera_pos_strz), rl.Vector2{ .x = 0, .y = fps_strz_dim.y }, font_size, font_spacing, rl.WHITE);

            var target_block_point_strz = try std.fmt.bufPrintZ(&strz_buffer, "No collision", .{});
            var target_block_point_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), font_size, font_spacing);
            if (crosshair_ray_collision.hit) {
                target_block_point_strz = try std.fmt.bufPrintZ(&strz_buffer, "Target block: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ target_block.coords.x, target_block.coords.y, target_block.coords.z });
                target_block_point_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), font_size, font_spacing);
            }
            rl.DrawTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), rl.Vector2{ .x = 0, .y = fps_strz_dim.y + camera_pos_strz_dim.y }, font_size, font_spacing, rl.WHITE);

            const look_direction_strz = try std.fmt.bufPrintZ(&strz_buffer, "Look direction: {s}", .{@tagName(look_direction)});
            const look_direction_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, look_direction_strz), font_size, font_spacing);
            _ = look_direction_strz_dim;
            rl.DrawTextEx(font, @ptrCast([*c]const u8, look_direction_strz), rl.Vector2{ .x = 0, .y = fps_strz_dim.y + camera_pos_strz_dim.y + target_block_point_strz_dim.y }, font_size, font_spacing, rl.WHITE);
        }

        rl.EndDrawing();
    }

    rl.CloseWindow();
}
