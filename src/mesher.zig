const std = @import("std");
const rl = @import("rl.zig");
const scary_types = @import("scary_types.zig");

const Chunk = @import("Chunk.zig");
const World = @import("World.zig");
const Atlas = @import("Atlas.zig");

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const MemoryPoolExtra = std.heap.MemoryPoolExtra;

const SmolQ = scary_types.SmolQ;
const BST = scary_types.BST;
const Vector3 = scary_types.Vector3;

const hashString = std.hash_map.hashString;

const block_dim = rl.Vector3{ .x = 1, .y = 1, .z = 1 };
pub const mem_per_chunk = 1024 * 1024 / World.loaded_chunk_capacity;

pub const ChunkMesh = struct {
    mem: *align(@alignOf(?*MemoryPoolExtra([mem_per_chunk]u8, .{ .alignment = null, .growable = false }))) [mem_per_chunk]u8,
    coords: Vector3(i32),
    mesh: rl.Mesh,
};

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

inline fn shouldDrawFace(world: *World, chunk_index: usize, block_x: u8, block_y: u8, block_z: u8, face_normal: Vector3(i32)) bool {
    var chunk_coords = Vector3(i32){
        .x = @divFloor(@intCast(i32, block_x) + face_normal.x, Chunk.dim.x),
        .y = @divFloor(@intCast(i32, block_y) + face_normal.y, Chunk.dim.y),
        .z = @divFloor(@intCast(i32, block_z) + face_normal.z, Chunk.dim.z),
    };
    chunk_coords = Vector3(i32).add(world.loaded_chunks[chunk_index].coords, chunk_coords);
    const chunk_ptr = world.chunkFromCoords(chunk_coords) orelse return false;

    var wrapped_x: Chunk.u_dimx = if (face_normal.x >= 0) @intCast(Chunk.u_dimx, block_x) +% @intCast(Chunk.u_dimx, face_normal.x) else @intCast(Chunk.u_dimx, block_x) -% 1;
    var wrapped_y: Chunk.u_dimy = if (face_normal.y >= 0) @intCast(Chunk.u_dimy, block_y) +% @intCast(Chunk.u_dimy, face_normal.y) else @intCast(Chunk.u_dimy, block_y) -% 1;
    var wrapped_z: Chunk.u_dimz = if (face_normal.z >= 0) @intCast(Chunk.u_dimz, block_z) +% @intCast(Chunk.u_dimz, face_normal.z) else @intCast(Chunk.u_dimz, block_z) -% 1;

    return !isSolidBlock(&chunk_ptr.block_data, wrapped_x, wrapped_y, wrapped_z);
}

inline fn isSolidBlock(dense_map: []u8, x: u8, y: u8, z: u8) bool {
    var result = false;
    if (dense_map[@intCast(u16, Chunk.dim.x * Chunk.dim.y) * z + y * @intCast(u16, Chunk.dim.x) + x] != 0) {
        result = true;
    }
    return result;
}

/// Generate chunk sized mesh starting at world origin.
pub fn cullMesh(
    mesh_pool: *MemoryPoolExtra([mem_per_chunk]u8, .{ .alignment = null, .growable = false }),
    chunk_index: usize,
    world: *World,
    sprite_sheet: *Atlas,
) !ChunkMesh {
    var result = ChunkMesh{
        .mesh = std.mem.zeroes(rl.Mesh),
        .mem = try mesh_pool.create(),
        .coords = world.loaded_chunks[chunk_index].coords,
    };
    var face_count: c_int = 0;
    {
        var block_y: u8 = 0;
        while (block_y < Chunk.dim.y) : (block_y += 1) {
            var block_z: u8 = 0;
            while (block_z < Chunk.dim.z) : (block_z += 1) {
                var block_x: u8 = 0;
                while (block_x < Chunk.dim.x) : (block_x += 1) {
                    for (World.d_chunk_coordses) |d_chunk_coords| {
                        if (!isSolidBlock(&world.loaded_chunks[chunk_index].block_data, block_x, block_y, block_z))
                            continue;
                        face_count += if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, d_chunk_coords)) 1 else 0;
                    }
                }
            }
        }
    }

    var fb = FixedBufferAllocator.init(result.mem);
    var ally = fb.allocator();

    result.mesh.triangleCount = face_count * 2;
    result.mesh.vertexCount = result.mesh.triangleCount * 3;
    var normals = try ally.alloc(f32, @intCast(u32, result.mesh.vertexCount * 3));
    var texcoords = try ally.alloc(f32, @intCast(u32, result.mesh.vertexCount * 2));
    var verticies = try ally.alloc(f32, @intCast(u32, result.mesh.vertexCount * 3));
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
        var block_y: u8 = 0;
        while (block_y < Chunk.dim.y) : (block_y += 1) {
            var block_z: u8 = 0;
            while (block_z < Chunk.dim.z) : (block_z += 1) {
                var block_x: u8 = 0;
                while (block_x < Chunk.dim.x) : (block_x += 1) {
                    if (!isSolidBlock(&world.loaded_chunks[chunk_index].block_data, block_x, block_y, block_z))
                        continue;

                    const block_pos = rl.Vector3{
                        .x = @intToFloat(f32, block_x) + @intToFloat(f32, world.loaded_chunks[chunk_index].coords.x * Chunk.dim.x),
                        .y = @intToFloat(f32, block_y) + @intToFloat(f32, world.loaded_chunks[chunk_index].coords.y * Chunk.dim.y),
                        .z = @intToFloat(f32, block_z) + @intToFloat(f32, world.loaded_chunks[chunk_index].coords.z * Chunk.dim.z),
                    };

                    // Top Face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 0, .y = 1, .z = 0 })) {
                        setFaceNormals(normals, &normals_offset, 0, 1, 0); // Normals pointing up
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_start_x, grass_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_end_x, grass_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_start_x, grass_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_start_x, grass_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_end_x, grass_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Bottom right texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, grass_texcoord_end_x, grass_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top right texture and vertex
                    }

                    // Front face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 0, .y = 0, .z = 1 })) {
                        setFaceNormals(normals, &normals_offset, 0, 0, 1); // Normals pointing towards viewer

                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);

                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top left texture and vertex.

                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);

                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top right texture and vertex
                    }

                    // Back face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 0, .y = 0, .z = -1 })) {
                        setFaceNormals(normals, &normals_offset, 0, 0, -1); // Normals pointing away from viewer
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z); // Top right texture and vertex
                    }

                    // Bottom face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 0, .y = -1, .z = 0 })) {
                        setFaceNormals(normals, &normals_offset, 0.0, -1.0, 0.0); // Normals pointing down
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z + block_dim.z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Top right texture and vertex
                    }

                    // Right face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 1, .y = 0, .z = 0 })) {
                        setFaceNormals(normals, &normals_offset, 1.0, 0.0, 0.0); // Normals pointing right
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Bottom left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top right of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Bottom left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z); // Bottom right of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top right of the texture and vertex
                    }

                    // Left Face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = -1, .y = 0, .z = 0 })) {
                        setFaceNormals(normals, &normals_offset, -1.0, 0.0, 0.0); // Normals Pointing Left
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top right of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z); // Top left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_start_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z + block_dim.z); // Bottom right of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, dirt_texcoord_end_x, dirt_texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top right of the texture and texture
                    }
                }
            }
        }
    }

    result.mesh.normals = @ptrCast([*c]f32, normals);
    result.mesh.texcoords = @ptrCast([*c]f32, texcoords);
    result.mesh.vertices = @ptrCast([*c]f32, verticies);

    return result;
}

/// NOTE(caleb): This function assumes chunk_meshes has already been initialized
pub fn updateChunkMeshes(
    mesh_pool: *MemoryPoolExtra([mem_per_chunk]u8, .{ .alignment = null, .growable = false }),
    chunk_meshes: []ChunkMesh,
    world: *World,
    atlas: *Atlas,
) void {
    var removed_chunk_count: usize = 0;
    var removed_chunk_indicies: [World.loaded_chunk_capacity]usize = undefined;

    // Unload meshes that don't exist in loaded_chunks, save the index of
    // the chunk mesh that was removed so a mesh can be generated in it's place.
    for (chunk_meshes, 0..) |*chunk_mesh, chunk_mesh_index| {
        var has_loaded_chunk = false;
        for (world.loaded_chunks) |loaded_chunk| {
            if (Vector3(i32).equals(loaded_chunk.coords, chunk_mesh.coords)) {
                has_loaded_chunk = true;
                break;
            }
        }
        if (!has_loaded_chunk) {
            mesh_pool.destroy(chunk_mesh.mem);
            unloadMesh(chunk_mesh.mesh);
            removed_chunk_indicies[removed_chunk_count] = chunk_mesh_index;
            removed_chunk_count += 1;
        }
    }

    // Update chunk_meshes with missing chunks from loaded_chunks.
    for (world.loaded_chunks, 0..) |loaded_chunk, loaded_chunk_index| {
        var has_mesh_chunk = false;
        for (chunk_meshes) |chunk_mesh| {
            if (Vector3(i32).equals(loaded_chunk.coords, chunk_mesh.coords)) {
                has_mesh_chunk = true;
                break;
            }
        }
        if (!has_mesh_chunk) {
            std.debug.assert(removed_chunk_count > 0);
            chunk_meshes[removed_chunk_indicies[removed_chunk_count - 1]] = cullMesh(mesh_pool, @intCast(u8, loaded_chunk_index), world, atlas) catch unreachable;
            rl.UploadMesh(&chunk_meshes[removed_chunk_indicies[removed_chunk_count - 1]].mesh, false);
            removed_chunk_count -= 1;
        }
    }
}

/// Unload mesh from memory (RAM and VRAM)
pub fn unloadMesh(mesh: rl.Mesh) void {
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
