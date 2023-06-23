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

const hashString = std.hash_map.hashString;

pub const block_dim = rl.Vector3{ .x = 1, .y = 1, .z = 1 };
pub const mem_per_chunk = 150 * 1024; //150 kb per chunk /// World.loaded_chunk_capacity;

pub const ChunkMesh = struct {
    mem: *align(@alignOf(?*MemoryPoolExtra([mem_per_chunk]u8, .{ .alignment = null, .growable = false }))) [mem_per_chunk]u8,
    coords: @Vector(3, i32),
    updated_block_pos: ?@Vector(3, u8),
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

fn shouldDrawFace(world: *World, atlas: *Atlas, chunk_index: usize, block_x: u8, block_y: u8, block_z: u8, face_normal: @Vector(3, i32)) bool {
    var chunk_coords = @Vector(3, i32){
        @divFloor(@intCast(i32, block_x) + face_normal[0], Chunk.dim),
        @divFloor(@intCast(i32, block_y) + face_normal[1], Chunk.dim),
        @divFloor(@intCast(i32, block_z) + face_normal[2], Chunk.dim),
    };
    chunk_coords += world.loaded_chunks[chunk_index].coords;
    const border_or_same_chunk_index = world.chunkIndexFromCoords(chunk_coords) orelse return false;

    var wrapped_x: Chunk.u_dim = if (face_normal[0] >= 0) @intCast(Chunk.u_dim, block_x) +% @intCast(Chunk.u_dim, face_normal[0]) else @intCast(Chunk.u_dim, block_x) -% 1;
    var wrapped_y: Chunk.u_dim = if (face_normal[1] >= 0) @intCast(Chunk.u_dim, block_y) +% @intCast(Chunk.u_dim, face_normal[1]) else @intCast(Chunk.u_dim, block_y) -% 1;
    var wrapped_z: Chunk.u_dim = if (face_normal[2] >= 0) @intCast(Chunk.u_dim, block_z) +% @intCast(Chunk.u_dim, face_normal[2]) else @intCast(Chunk.u_dim, block_z) -% 1;

    return isAirBlock(world, border_or_same_chunk_index, wrapped_x, wrapped_y, wrapped_z) or isTransBlock(world, atlas, border_or_same_chunk_index, wrapped_x, wrapped_y, wrapped_z);
}

inline fn isAirBlock(world: *World, chunk_index: usize, x: u8, y: u8, z: u8) bool {
    if (world.loaded_chunks[chunk_index].fetch(x, y, z).? == 0)
        return true;
    return false;
}

inline fn isTransBlock(world: *World, atlas: *Atlas, chunk_index: usize, x: u8, y: u8, z: u8) bool {
    const block_id = world.loaded_chunks[chunk_index].fetch(x, y, z).?;
    if (block_id != 0 and (atlas.id_to_block_data.get(block_id) orelse unreachable).is_trans)
        return true;
    return false;
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
        .updated_block_pos = null,
        .coords = world.loaded_chunks[chunk_index].coords,
    };
    var face_count: c_int = 0;
    {
        var block_y: u8 = 0;
        while (block_y < Chunk.dim) : (block_y += 1) {
            var block_z: u8 = 0;
            while (block_z < Chunk.dim) : (block_z += 1) {
                var block_x: u8 = 0;
                while (block_x < Chunk.dim) : (block_x += 1) {
                    for (World.d_chunk_coordses) |d_chunk_coords| {
                        if (isAirBlock(world, chunk_index, block_x, block_y, block_z))
                            continue;
                        face_count += if (shouldDrawFace(world, sprite_sheet, chunk_index, block_x, block_y, block_z, d_chunk_coords)) 1 else 0;
                    }
                }
            }
        }
    }

    if (face_count == 0) { // Null mesh and exit
        result.mesh.vertices = null;
        result.mesh.texcoords = null;
        result.mesh.texcoords2 = null;
        result.mesh.normals = null;
        result.mesh.tangents = null;
        result.mesh.colors = null;
        result.mesh.indices = null;
        return result;
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
        while (block_y < Chunk.dim) : (block_y += 1) {
            var block_z: u8 = 0;
            while (block_z < Chunk.dim) : (block_z += 1) {
                var block_x: u8 = 0;
                while (block_x < Chunk.dim) : (block_x += 1) {
                    if (isAirBlock(world, chunk_index, block_x, block_y, block_z))
                        continue;

                    const block_pos = rl.Vector3{
                        .x = @intToFloat(f32, block_x) + @intToFloat(f32, world.loaded_chunks[chunk_index].coords[0] * Chunk.dim),
                        .y = @intToFloat(f32, block_y) + @intToFloat(f32, world.loaded_chunks[chunk_index].coords[1] * Chunk.dim),
                        .z = @intToFloat(f32, block_z) + @intToFloat(f32, world.loaded_chunks[chunk_index].coords[2] * Chunk.dim),
                    };

                    const id = world.loaded_chunks[chunk_index].fetch(block_x, block_y, block_z) orelse unreachable;
                    const tile_row = @divTrunc(id, sprite_sheet.columns);
                    const tile_column = @mod(id, sprite_sheet.columns);
                    const texcoord_start_x = 128 * @intToFloat(f32, tile_column) / @intToFloat(f32, sprite_sheet.texture.width);
                    const texcoord_end_x = texcoord_start_x + 128 / @intToFloat(f32, sprite_sheet.texture.width);
                    const texcoord_start_y = 128 * @intToFloat(f32, tile_row) / @intToFloat(f32, sprite_sheet.texture.height);
                    const texcoord_end_y = texcoord_start_y + 128 / @intToFloat(f32, sprite_sheet.texture.height);

                    // Top Face
                    if (shouldDrawFace(world, sprite_sheet, chunk_index, block_x, block_y, block_z, @Vector(3, i32){ 0, 1, 0 })) {
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
                    if (shouldDrawFace(world, sprite_sheet, chunk_index, block_x, block_y, block_z, @Vector(3, i32){ 0, 0, 1 })) {
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
                    if (shouldDrawFace(world, sprite_sheet, chunk_index, block_x, block_y, block_z, @Vector(3, i32){ 0, 0, -1 })) {
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
                    if (shouldDrawFace(world, sprite_sheet, chunk_index, block_x, block_y, block_z, @Vector(3, i32){ 0, -1, 0 })) {
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
                    if (shouldDrawFace(world, sprite_sheet, chunk_index, block_x, block_y, block_z, @Vector(3, i32){ 1, 0, 0 })) {
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
                    if (shouldDrawFace(world, sprite_sheet, chunk_index, block_x, block_y, block_z, @Vector(3, i32){ -1, 0, 0 })) {
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

/// NOTE(caleb): Updates chunk meshses based on block updates.
pub fn updateChunkMeshes(
    mesh_pool: *MemoryPoolExtra([mem_per_chunk]u8, .{ .alignment = null, .growable = false }),
    chunk_meshes: []ChunkMesh,
    mesh_index: usize,
    world: *World,
    atlas: *Atlas,
) void {
    for (World.d_chunk_coordses) |d_chunk_coords| {
        var world_pos = World.relToWorldi32(chunk_meshes[mesh_index].updated_block_pos.?, chunk_meshes[mesh_index].coords);
        world_pos += d_chunk_coords;
        const neighbor_coords = World.worldi32ToChunki32(world_pos);
        if (@reduce(.And, neighbor_coords == chunk_meshes[mesh_index].coords))
            continue;

        const loaded_chunk_index = world.chunkIndexFromCoords(neighbor_coords) orelse continue;

        const rel_block_pos = World.worldi32ToRel(world_pos);
        const block_val = world.loaded_chunks[loaded_chunk_index].fetch(rel_block_pos[0], rel_block_pos[1], rel_block_pos[2]) orelse 0;

        if (block_val != 0) {
            for (chunk_meshes) |*chunk_mesh| {
                if (@reduce(.And, chunk_mesh.coords == neighbor_coords)) {
                    mesh_pool.destroy(chunk_mesh.mem);
                    unloadMesh(chunk_mesh.mesh);
                    chunk_mesh.* = cullMesh(mesh_pool, @intCast(u8, loaded_chunk_index), world, atlas) catch unreachable;
                    rl.UploadMesh(&chunk_mesh.mesh, false);
                    break;
                }
            }
        }
    }

    const loaded_chunk_index = world.chunkIndexFromCoords(chunk_meshes[mesh_index].coords) orelse unreachable;
    mesh_pool.destroy(chunk_meshes[mesh_index].mem);
    unloadMesh(chunk_meshes[mesh_index].mesh);
    chunk_meshes[mesh_index] = cullMesh(mesh_pool, @intCast(u8, loaded_chunk_index), world, atlas) catch unreachable;
    rl.UploadMesh(&chunk_meshes[mesh_index].mesh, false);
}

/// NOTE(caleb): Syncs meshes with loaded chunks
pub fn updateChunkMeshesSpatially(
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
            if (@reduce(.And, loaded_chunk.coords == chunk_mesh.coords)) {
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
            if (@reduce(.And, loaded_chunk.coords == chunk_mesh.coords)) {
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

/// BUG(caleb): I think this is a bug? On linux VAO ids increment rather than using the
/// VAO id that was just made avaliable.
/// Unload mesh from memory (RAM and VRAM)
pub fn unloadMesh(mesh: rl.Mesh) void {
    // Unload rlgl mesh vboId data
    rl.rlUnloadVertexArray(mesh.vaoId);
    if (mesh.vboId != null) {
        const max_mesh_vertex_buffers = 7;
        for (0..max_mesh_vertex_buffers) |vbo_index|
            rl.rlUnloadVertexBuffer(mesh.vboId[vbo_index]);
    }
    rl.MemFree(mesh.vboId);
}
