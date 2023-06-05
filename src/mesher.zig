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

pub const block_dim = rl.Vector3{ .x = 1, .y = 1, .z = 1 };
pub const mem_per_chunk = 150 * 1024; //150 kb per chunk /// World.loaded_chunk_capacity;

pub const ChunkMesh = struct {
    mem: *align(@alignOf(?*MemoryPoolExtra([mem_per_chunk]u8, .{ .alignment = null, .growable = false }))) [mem_per_chunk]u8,
    coords: Vector3(i32),
    needs_update: bool, // NOTE(caleb): Possibly make this a chunk_rel value?
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
    const border_or_same_chunk_index = world.chunkIndexFromCoords(chunk_coords) orelse return false;

    var wrapped_x: Chunk.u_dimx = if (face_normal.x >= 0) @intCast(Chunk.u_dimx, block_x) +% @intCast(Chunk.u_dimx, face_normal.x) else @intCast(Chunk.u_dimx, block_x) -% 1;
    var wrapped_y: Chunk.u_dimy = if (face_normal.y >= 0) @intCast(Chunk.u_dimy, block_y) +% @intCast(Chunk.u_dimy, face_normal.y) else @intCast(Chunk.u_dimy, block_y) -% 1;
    var wrapped_z: Chunk.u_dimz = if (face_normal.z >= 0) @intCast(Chunk.u_dimz, block_z) +% @intCast(Chunk.u_dimz, face_normal.z) else @intCast(Chunk.u_dimz, block_z) -% 1;

    return !isSolidBlock(&world.loaded_chunks[border_or_same_chunk_index].block_data, wrapped_x, wrapped_y, wrapped_z);
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
        .needs_update = false,
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
    var normals_offset: u32 = 0;
    var texcoords_offset: u32 = 0;
    var verticies_offset: u32 = 0;

    // TODO(caleb): Side and bottom textures
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

                    const id = world.loaded_chunks[chunk_index].fetch(block_x, block_y, block_z) orelse unreachable;
                    const tile_row = @divTrunc(id, sprite_sheet.columns);
                    const tile_column = @mod(id, sprite_sheet.columns);
                    const texcoord_start_x = 128 * @intToFloat(f32, tile_column) / @intToFloat(f32, sprite_sheet.texture.width);
                    const texcoord_end_x = texcoord_start_x + 128 / @intToFloat(f32, sprite_sheet.texture.width);
                    const texcoord_start_y = 128 * @intToFloat(f32, tile_row) / @intToFloat(f32, sprite_sheet.texture.height);
                    const texcoord_end_y = texcoord_start_y + 128 / @intToFloat(f32, sprite_sheet.texture.height);

                    // Top Face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 0, .y = 1, .z = 0 })) {
                        setFaceNormals(normals, &normals_offset, 0, 1, 0); // Normals pointing up
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Bottom right texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top right texture and vertex
                    }

                    // Front face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 0, .y = 0, .z = 1 })) {
                        setFaceNormals(normals, &normals_offset, 0, 0, 1); // Normals pointing towards viewer

                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);

                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top left texture and vertex.

                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z + block_dim.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_end_y);

                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top right texture and vertex
                    }

                    // Back face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 0, .y = 0, .z = -1 })) {
                        setFaceNormals(normals, &normals_offset, 0, 0, -1); // Normals pointing away from viewer
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z); // Top right texture and vertex
                    }

                    // Bottom face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 0, .y = -1, .z = 0 })) {
                        setFaceNormals(normals, &normals_offset, 0.0, -1.0, 0.0); // Normals pointing down
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Top right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z + block_dim.z); // Top left texture and vertex.
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom left texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z); // Bottom right texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Top right texture and vertex
                    }

                    // Right face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = 1, .y = 0, .z = 0 })) {
                        setFaceNormals(normals, &normals_offset, 1.0, 0.0, 0.0); // Normals pointing right
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Bottom left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top right of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z + block_dim.z); // Bottom left of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y, block_pos.z); // Bottom right of the texture and vertex
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x + block_dim.x, block_pos.y + block_dim.y, block_pos.z); // Top right of the texture and vertex
                    }

                    // Left Face
                    if (shouldDrawFace(world, chunk_index, block_x, block_y, block_z, Vector3(i32){ .x = -1, .y = 0, .z = 0 })) {
                        setFaceNormals(normals, &normals_offset, -1.0, 0.0, 0.0); // Normals Pointing Left
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z + block_dim.z); // Top right of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_start_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y + block_dim.y, block_pos.z); // Top left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_start_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z); // Bottom left of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_end_y);
                        setVertex3f(verticies, &verticies_offset, block_pos.x, block_pos.y, block_pos.z + block_dim.z); // Bottom right of the texture and texture
                        setTexcoord2f(texcoords, &texcoords_offset, texcoord_end_x, texcoord_start_y);
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
/// TODO(caleb): Make this function smarter.... i.e. if a block is placed solely within a chunk don't update it's neighbors
pub fn updateChunkMeshes(
    mesh_pool: *MemoryPoolExtra([mem_per_chunk]u8, .{ .alignment = null, .growable = false }),
    chunk_meshes: []ChunkMesh,
    world: *World,
    atlas: *Atlas,
) void {
    std.debug.print("-----------------------------\n", .{});
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

        if (!has_loaded_chunk or chunk_mesh.needs_update) {
            mesh_pool.destroy(chunk_mesh.mem);
            unloadMesh(chunk_mesh.mesh);
            removed_chunk_indicies[removed_chunk_count] = chunk_mesh_index;
            removed_chunk_count += 1;
        }
    }

    // Update chunk_meshes with missing chunks from loaded_chunks.
    for (world.loaded_chunks, 0..) |loaded_chunk, loaded_chunk_index| {
        var has_mesh_chunk = false;
        outer: for (chunk_meshes, 0..) |chunk_mesh, chunk_mesh_index| {
            for (removed_chunk_indicies[0..removed_chunk_count]) |removed_index| // Ignore free chunks
                if (removed_index == chunk_mesh_index)
                    continue :outer;

            if (Vector3(i32).equals(loaded_chunk.coords, chunk_mesh.coords)) {
                has_mesh_chunk = true;
                break;
            }
        }
        if (!has_mesh_chunk) {
            std.debug.assert(removed_chunk_count > 0);
            const free_mesh_index = removed_chunk_indicies[removed_chunk_count - 1];
            chunk_meshes[free_mesh_index] = cullMesh(mesh_pool, @intCast(u8, loaded_chunk_index), world, atlas) catch unreachable;
            rl.UploadMesh(&chunk_meshes[free_mesh_index].mesh, false);
            chunk_meshes[free_mesh_index].needs_update = false;

            std.debug.print("{?}\n", .{chunk_meshes[free_mesh_index].coords});

            // Is this chunk a neighboring chunk?
            outer: for (chunk_meshes, 0..) |*chunk_mesh, chunk_mesh_index| {
                for (removed_chunk_indicies[0..removed_chunk_count]) |removed_index| // Ignore free chunks
                    if (removed_index == chunk_mesh_index)
                        continue :outer;

                for (World.d_chunk_coordses) |d_chunk_coords| {
                    const neighbor_coords = Vector3(i32).add(d_chunk_coords, chunk_meshes[free_mesh_index].coords);
                    if (Vector3(i32).equals(neighbor_coords, chunk_mesh.coords)) {
                        chunk_mesh.needs_update = true;
                    }
                }
            }

            removed_chunk_count -= 1;
        }
    }
    std.debug.assert(removed_chunk_count == 0);

    // Update loaded border chunks of chunks which were just loaded
    for (chunk_meshes) |*chunk_mesh| {
        if (chunk_mesh.needs_update) {
            mesh_pool.destroy(chunk_mesh.mem);
            unloadMesh(chunk_mesh.mesh);
            const loaded_chunk_index = world.chunkIndexFromCoords(chunk_mesh.coords) orelse unreachable;
            chunk_mesh.* = cullMesh(mesh_pool, @intCast(u8, loaded_chunk_index), world, atlas) catch unreachable;
            std.debug.print("{?}\n", .{chunk_mesh.coords});

            rl.UploadMesh(&chunk_mesh.mesh, false);
            chunk_mesh.needs_update = false;
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
