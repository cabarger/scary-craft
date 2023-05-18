const std = @import("std");

const c = @cImport({
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

const block_dim = c.Vector3{ .x = 1, .y = 1, .z = 1 };
const chunk_dim = c.Vector3{ .x = 16, .y = 16, .z = 16 };

const crosshair_thickness_in_pixels = 2;
const crosshair_length_in_pixels = 20;

const target_range_in_blocks = 4;
const meters_per_block = 1;
const move_speed_blocks_per_second = 3;
const mouse_sens = 0.1;

const font_size = 30;
const font_spacing = 2;

const target_fps = 60;

const SpriteSheet = struct {
    columns: u16,
    texture: c.Texture,
    name_to_id: AutoHashMap(u64, u16),
};

// Axis aligned bounding box
const AABB = struct {
    pos: c.Vector3, // Bottom left
    dim: c.Vector3,

    pub inline fn getVP(this: *AABB, normal: c.Vector3) c.Vector3 {
        var result = this.pos;
        if (normal.x > 0) {
            result.x += this.dim.x;
        }
        if (normal.y > 0) {
            result.y += this.dim.y;
        }
        if (normal.z > 0) {
            result.z += this.dim.z;
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
fn unloadMesh(mesh: c.Mesh) void {
    // Unload rlgl mesh vboId data
    c.rlUnloadVertexArray(mesh.vaoId);
    if (mesh.vboId != null) {
        var vertex_buffer_index: u8 = 0;
        while (vertex_buffer_index < 7) : (vertex_buffer_index += 1) {
            c.rlUnloadVertexBuffer(mesh.vboId[vertex_buffer_index]);
        }
    }
    c.MemFree(mesh.vboId);
}

fn updateLightValues(shader: c.Shader, light: *Light) void {

    // Send to shader light enabled state and type
    c.SetShaderValue(shader, light.enabled_loc, &light.enabled, c.SHADER_UNIFORM_INT);
    c.SetShaderValue(shader, light.type_loc, &light.type, c.SHADER_UNIFORM_INT);

    // Send to shader light position, target, and color values
    c.SetShaderValue(shader, light.position_loc, &light.position, c.SHADER_UNIFORM_VEC3);
    c.SetShaderValue(shader, light.target_loc, &light.target, c.SHADER_UNIFORM_VEC3);
    c.SetShaderValue(shader, light.color_loc, &light.color, c.SHADER_UNIFORM_VEC4);
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

fn blockCoordsFromPoint(dense_map: []i16, p: c.Vector3) c.Vector3 {
    const block_x = @floatToInt(i16, p.x);
    const block_y = @floatToInt(i16, p.y);
    const block_z = @floatToInt(i16, p.z);

    const val = denseMapLookup(dense_map, block_x, block_y, block_z);
    if (val != null and val.? == 1)
        return c.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z) };

    // NOTE(caleb): sqrt(floatEps(f32)), meaning that the two numbers are considered equal if at least half of the digits are equal.
    if (std.math.approxEqRel(f32, @round(p.x), p.x, std.math.sqrt(std.math.floatEps(f32)))) {
        return c.Vector3{ .x = @intToFloat(f32, block_x - 1), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z) };
    } else if (std.math.approxEqRel(f32, @round(p.y), p.y, std.math.sqrt(std.math.floatEps(f32)))) {
        return c.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y - 1), .z = @intToFloat(f32, block_z) };
    } else if (std.math.approxEqRel(f32, @round(p.z), p.z, std.math.sqrt(std.math.floatEps(f32)))) {
        return c.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z - 1) };
    }
    std.debug.print("{d}, {d}, {d}\n", .{ @floor(p.x), p.y, p.z });
    std.debug.print("{d}, {d}, {d}\n", .{ p.x, p.y, p.z });
    unreachable; // FIXME(caleb): This is still reachable :(
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
fn cullMesh(ally: Allocator, dense_map: []i16, sprite_sheet: *SpriteSheet) !c.Mesh {
    var result = std.mem.zeroes(c.Mesh);
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

inline fn lookDirection(direction: c.Vector3) Direction {
    var look_direction: Direction = undefined;

    const up_dot = c.Vector3DotProduct(direction, c.Vector3{ .x = 0, .y = 1, .z = 0 });
    const down_dot = c.Vector3DotProduct(direction, c.Vector3{ .x = 0, .y = -1, .z = 0 });
    const right_dot = c.Vector3DotProduct(direction, c.Vector3{ .x = 1, .y = 0, .z = 0 });
    const left_dot = c.Vector3DotProduct(direction, c.Vector3{ .x = -1, .y = 0, .z = 0 });
    const forward_dot = c.Vector3DotProduct(direction, c.Vector3{ .x = 0, .y = 0, .z = -1 });
    const backward_dot = c.Vector3DotProduct(direction, c.Vector3{ .x = 0, .y = 0, .z = 1 });

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
    const screen_width: c_int = 1600;
    const screen_height: c_int = 900;
    c.InitWindow(screen_width, screen_height, "Scary Craft");
    c.SetConfigFlags(c.FLAG_MSAA_4X_HINT);
    c.SetWindowState(c.FLAG_WINDOW_RESIZABLE);
    c.SetTargetFPS(target_fps);
    c.DisableCursor();

    var page_ally = std.heap.page_allocator;
    var back_buffer = try page_ally.alloc(u8, 1024 * 1024 * 1); // 1mb
    var fb_ally = std.heap.FixedBufferAllocator.init(back_buffer);
    var arena_ally = std.heap.ArenaAllocator.init(fb_ally.allocator());

    const font = c.LoadFont("data/FiraCode-Medium.ttf");

    var sprite_sheet: SpriteSheet = undefined;
    sprite_sheet.texture = c.LoadTexture("data/atlas.png");
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

    var shader: c.Shader = c.LoadShader(c.TextFormat("data/shaders/lighting.vs", @intCast(c_int, 330)), c.TextFormat("data/shaders/lighting.fs", @intCast(c_int, 330)));
    shader.locs[c.SHADER_LOC_VECTOR_VIEW] = c.GetShaderLocation(shader, "viewPos");

    const ambient_loc = c.GetShaderLocation(shader, "ambient");
    c.SetShaderValue(shader, ambient_loc, &[_]f32{ 0.01, 0.01, 0.01, 1.0 }, c.SHADER_UNIFORM_VEC4);

    var light_source: Light = undefined;
    // NOTE(caleb): Lighting shader naming must be the provided ones
    light_source.enabled_loc = c.GetShaderLocation(shader, "light.enabled");
    light_source.type_loc = c.GetShaderLocation(shader, "light.type");
    light_source.position_loc = c.GetShaderLocation(shader, "light.position");
    light_source.target_loc = c.GetShaderLocation(shader, "light.target");
    light_source.color_loc = c.GetShaderLocation(shader, "light.color");
    light_source.color = [4]f32{ 1, 1, 1, 1 };

    var default_material = c.LoadMaterialDefault();
    default_material.shader = shader;
    c.SetMaterialTexture(&default_material, c.MATERIAL_MAP_DIFFUSE, sprite_sheet.texture);

    var debug_axes = false;
    var debug_text_info = false;

    var camera: c.Camera = undefined;
    camera.position = c.Vector3{ .x = 0.0, .y = 10.0, .z = 10.0 };
    camera.target = c.Vector3{ .x = 0.0, .y = 0.0, .z = -1.0 };
    camera.up = c.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 60.0;
    camera.projection = c.CAMERA_PERSPECTIVE;

    // Debug chunk slice 16x16 at y = 0;
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
    c.UploadMesh(&chunk_mesh, false);

    while (!c.WindowShouldClose()) {
        const screen_dim = c.Vector2{ .x = @intToFloat(f32, c.GetScreenWidth()), .y = @intToFloat(f32, c.GetScreenHeight()) };
        const screen_mid = c.Vector2Scale(screen_dim, 0.5);

        if (c.IsKeyPressed(c.KEY_F1)) {
            debug_axes = !debug_axes;
            debug_text_info = !debug_text_info;
        }

        var speed_scalar: f32 = 1;
        if (c.IsKeyDown(c.KEY_LEFT_SHIFT)) {
            speed_scalar = 2;
        }

        var camera_move = c.Vector3{ .x = 0, .y = 0, .z = 0 };
        if (c.IsKeyDown(c.KEY_W)) {
            camera_move.x += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * c.GetFrameTime();
        }
        if (c.IsKeyDown(c.KEY_S)) {
            camera_move.x -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * c.GetFrameTime();
        }
        if (c.IsKeyDown(c.KEY_A)) {
            camera_move.y -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * c.GetFrameTime();
        }
        if (c.IsKeyDown(c.KEY_D)) {
            camera_move.y += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * c.GetFrameTime();
        }
        if (c.IsKeyDown(c.KEY_SPACE)) {
            camera_move.z += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * c.GetFrameTime();
        }
        if (c.IsKeyDown(c.KEY_LEFT_CONTROL)) {
            camera_move.z -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * c.GetFrameTime();
        }

        c.UpdateCameraPro(&camera, camera_move, c.Vector3{ .x = c.GetMouseDelta().x * mouse_sens, .y = c.GetMouseDelta().y * mouse_sens, .z = 0 }, 0); //c.GetMouseWheelMove());

        // Update uniform shader values.
        const camera_position = [3]f32{ camera.position.x, camera.position.y, camera.position.z };
        const camera_target = [3]f32{ camera.target.x, camera.target.y, camera.target.z };
        light_source.position = camera_position;
        light_source.target = camera_target;
        updateLightValues(shader, &light_source);
        c.SetShaderValue(shader, shader.locs[c.SHADER_LOC_VECTOR_VIEW], &camera_position, c.SHADER_UNIFORM_VEC3);

        const crosshair_ray = c.Ray{ .position = camera.position, .direction = c.GetCameraForward(&camera) };
        const crosshair_ray_collision = c.GetRayCollisionMesh(crosshair_ray, chunk_mesh, c.MatrixIdentity());
        const look_direction = lookDirection(crosshair_ray.direction);

        var target_block_coords: c.Vector3 = undefined;
        if (crosshair_ray_collision.hit) {
            target_block_coords = blockCoordsFromPoint(dense_map, crosshair_ray_collision.point);

            if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) { // Break block
                denseMapPut(dense_map, 0, @floatToInt(i16, target_block_coords.x), @floatToInt(i16, target_block_coords.y), @floatToInt(i16, target_block_coords.z));

                // Update chunk mesh
                unloadMesh(chunk_mesh);
                chunk_fb_ally.reset();
                chunk_mesh = try cullMesh(chunk_fb_ally.allocator(), dense_map, &sprite_sheet);
                c.UploadMesh(&chunk_mesh, false);
            }
        }

        c.BeginDrawing();
        c.ClearBackground(c.BLACK);
        c.BeginMode3D(camera);

        // Only draw this mesh if it's within the view frustum
        // var chunk_box = AABB{ .pos = c.Vector3Zero(), .dim = chunk_dim };
        // std.debug.print("{d:.2},{d:.2}\n", .{ screen_pos.x, screen_pos.y });

        c.DrawMesh(chunk_mesh, default_material, c.MatrixIdentity());
        // c.DrawGrid(10, 1);

        c.EndMode3D();

        c.DrawLineEx(screen_mid, c.Vector2Add(screen_mid, c.Vector2{ .x = -crosshair_length_in_pixels, .y = 0 }), crosshair_thickness_in_pixels, c.WHITE);
        c.DrawLineEx(screen_mid, c.Vector2Add(screen_mid, c.Vector2{ .x = crosshair_length_in_pixels, .y = 0 }), crosshair_thickness_in_pixels, c.WHITE);
        c.DrawLineEx(screen_mid, c.Vector2Add(screen_mid, c.Vector2{ .x = 0, .y = -crosshair_length_in_pixels }), crosshair_thickness_in_pixels, c.WHITE);
        c.DrawLineEx(screen_mid, c.Vector2Add(screen_mid, c.Vector2{ .x = 0, .y = crosshair_length_in_pixels }), crosshair_thickness_in_pixels, c.WHITE);

        if (debug_text_info) {
            var strz_buffer: [256]u8 = undefined;
            const fps_strz = try std.fmt.bufPrintZ(&strz_buffer, "FPS:{d}", .{c.GetFPS()});
            const fps_strz_dim = c.MeasureTextEx(font, @ptrCast([*c]const u8, fps_strz), font_size, font_spacing);
            c.DrawTextEx(font, @ptrCast([*c]const u8, fps_strz), c.Vector2{ .x = 0, .y = 0 }, font_size, font_spacing, c.WHITE);

            const camera_pos_strz = try std.fmt.bufPrintZ(&strz_buffer, "camera pos: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ camera.position.x, camera.position.y, camera.position.z });
            const camera_pos_strz_dim = c.MeasureTextEx(font, @ptrCast([*c]const u8, camera_pos_strz), font_size, font_spacing);
            c.DrawTextEx(font, @ptrCast([*c]const u8, camera_pos_strz), c.Vector2{ .x = 0, .y = fps_strz_dim.y }, font_size, font_spacing, c.WHITE);

            var target_block_point_strz = try std.fmt.bufPrintZ(&strz_buffer, "No collision", .{});
            var target_block_point_strz_dim = c.MeasureTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), font_size, font_spacing);
            if (crosshair_ray_collision.hit) {
                target_block_point_strz = try std.fmt.bufPrintZ(&strz_buffer, "Target block: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ target_block_coords.x, target_block_coords.y, target_block_coords.z });
                target_block_point_strz_dim = c.MeasureTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), font_size, font_spacing);
            }
            c.DrawTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), c.Vector2{ .x = 0, .y = fps_strz_dim.y + camera_pos_strz_dim.y }, font_size, font_spacing, c.WHITE);

            const look_direction_strz = try std.fmt.bufPrintZ(&strz_buffer, "Look direction: {s}", .{@tagName(look_direction)});
            const look_direction_strz_dim = c.MeasureTextEx(font, @ptrCast([*c]const u8, look_direction_strz), font_size, font_spacing);
            _ = look_direction_strz_dim;
            c.DrawTextEx(font, @ptrCast([*c]const u8, look_direction_strz), c.Vector2{ .x = 0, .y = fps_strz_dim.y + camera_pos_strz_dim.y + target_block_point_strz_dim.y }, font_size, font_spacing, c.WHITE);
        }

        c.EndDrawing();
    }

    c.CloseWindow();
}
