const std = @import("std");
const rl = @import("rl.zig");
const scary_types = @import("scary_types.zig");
const Atlas = @import("Atlas.zig");
const Chunk = @import("Chunk.zig");

const SmolQ = scary_types.SmolQ;
const BST = scary_types.BST;
const BSTExtra = scary_types.BSTExtra;
const Vector3 = scary_types.Vector3;
const AutoHashMap = std.AutoHashMap;

const hashString = std.hash_map.hashString;

const Self = @This();

pub const loaded_chunk_capacity = 7;
pub const chunk_cache_capacity = loaded_chunk_capacity * 3;

pub const WorldSaveHeader = packed struct {
    chunk_count: u32,
};

pub const ChunkHandle = packed struct {
    index: u32,
    coords: Vector3(i32),
};

ally: std.mem.Allocator,
chunk_cache: [chunk_cache_capacity]Chunk,
loaded_chunks: [loaded_chunk_capacity]*Chunk,
chunk_cache_st: BSTExtra(ChunkHandle, .{ .preheated_node_count = chunk_cache_capacity, .growable = false }, cstGoLeft, cstFoundTarget),
world_chunk_st: BST(ChunkHandle, cstGoLeft, cstFoundTarget),

pub fn init(ally: std.mem.Allocator) Self {
    var result: Self = undefined;
    result.ally = ally;
    result.chunk_cache_st = BSTExtra(ChunkHandle, .{ .preheated_node_count = chunk_cache_capacity, .growable = false }, cstGoLeft, cstFoundTarget).init(ally);
    result.world_chunk_st = BST(ChunkHandle, cstGoLeft, cstFoundTarget).init(ally);
    return result;
}

pub fn chunkIndexFromCoords(self: *Self, coords: Vector3(i32)) ?usize {
    for (self.loaded_chunks, 0..) |chunk, chunk_index| {
        if (chunk.coords.equals(coords))
            return chunk_index;
    }
    return null;
}

/// Creates a dummy world save.
/// NOTE(caleb): This function will clobber the world save at 'world_save_path'.
pub fn writeDummySave(world_save_path: []const u8, atlas: *Atlas) !void {
    const world_save_file = try std.fs.cwd().createFile(world_save_path, .{ .truncate = true });
    defer world_save_file.close();

    // Create a chunk slice 16x16 at y = 0;
    var test_chunk: Chunk = undefined;
    test_chunk.coords = Vector3(i32){ .x = 0, .y = 0, .z = 0 };
    test_chunk.index = 1;
    for (&test_chunk.block_data) |*byte| byte.* = 0;

    var block_z: u8 = 0;
    while (block_z < Chunk.dim.z) : (block_z += 1) {
        var block_x: u8 = 0;
        while (block_x < Chunk.dim.x) : (block_x += 1)
            test_chunk.put(atlas.name_to_id.get(hashString("default_grass")) orelse unreachable, block_x, 0, block_z);
    }

    const world_save_writer = world_save_file.writer();
    try world_save_writer.writeStruct(WorldSaveHeader{ .chunk_count = 1 });
    try world_save_writer.writeStruct(ChunkHandle{ .index = test_chunk.index, .coords = test_chunk.coords });
    try world_save_writer.writeAll(&test_chunk.block_data);
}

pub fn loadSave(world: *Self, world_save_path: []const u8) !void {
    const world_save_file = try std.fs.cwd().openFile(world_save_path, .{});
    defer world_save_file.close();
    const save_file_reader = world_save_file.reader();
    const world_save_header = try save_file_reader.readStruct(WorldSaveHeader);
    for (0..world_save_header.chunk_count) |_| {
        const world_save_chunk = try save_file_reader.readStruct(ChunkHandle);
        try save_file_reader.skipBytes(@intCast(u32, Chunk.dim.x) * @intCast(u32, Chunk.dim.y) * @intCast(i32, Chunk.dim.z), .{});
        try world.world_chunk_st.insert(world_save_chunk);
    }
}

// TODO(caleb): Convention:
// world - block position in world space
// chunk - chunk coords
// rel - chunk relative block coords

pub inline fn worldi32ToRel(pos: Vector3(i32)) Vector3(u8) {
    var result: Vector3(u8) = undefined;
    result.x = @intCast(u8, @mod(pos.x, @intCast(i32, Chunk.dim.x)));
    result.y = @intCast(u8, @mod(pos.y, @intCast(i32, Chunk.dim.y)));
    result.z = @intCast(u8, @mod(pos.z, @intCast(i32, Chunk.dim.z)));
    return result;
}

pub inline fn worldf32ToChunkRel(pos: rl.Vector3) Vector3(u8) {
    var result: Vector3(u8) = undefined;
    result.x = @intCast(u8, @mod(@floatToInt(i32, @floor(pos.x)), @intCast(i32, Chunk.dim.x)));
    result.y = @intCast(u8, @mod(@floatToInt(i32, @floor(pos.y)), @intCast(i32, Chunk.dim.y)));
    result.z = @intCast(u8, @mod(@floatToInt(i32, @floor(pos.z)), @intCast(i32, Chunk.dim.z)));
    return result;
}

/// Takes a relative chunk position, chunk coords. Returns the block position in world space.
pub inline fn relToWorldi32(pos: Vector3(u8), chunk_coords: Vector3(i32)) Vector3(i32) {
    var result: Vector3(i32) = undefined;
    result.x = chunk_coords.x * Chunk.dim.x + pos.x;
    result.y = chunk_coords.y * Chunk.dim.y + pos.y;
    result.z = chunk_coords.z * Chunk.dim.z + pos.z;
    return result;
}

/// Given a Vector(i32) in world space, return the eqv. chunk space coords.
pub inline fn worldi32ToChunki32(pos: Vector3(i32)) Vector3(i32) {
    var result: Vector3(i32) = undefined;
    result.x = @divFloor(pos.x, Chunk.dim.x);
    result.y = @divFloor(pos.y, Chunk.dim.y);
    result.z = @divFloor(pos.z, Chunk.dim.z);
    return result;
}

/// Given a vector of floats in world space, return the eqv. chunk space coords.
pub inline fn worldf32ToChunki32(pos: rl.Vector3) Vector3(i32) {
    var result: Vector3(i32) = undefined;
    result.x = @floatToInt(i32, @divFloor(pos.x, @intToFloat(f32, Chunk.dim.x)));
    result.y = @floatToInt(i32, @divFloor(pos.y, @intToFloat(f32, Chunk.dim.y)));
    result.z = @floatToInt(i32, @divFloor(pos.z, @intToFloat(f32, Chunk.dim.z)));
    return result;
}

pub const d_chunk_coordses = [_]Vector3(i32){
    Vector3(i32){ .x = 0, .y = 1, .z = 0 },
    Vector3(i32){ .x = 0, .y = -1, .z = 0 },
    Vector3(i32){ .x = -1, .y = 0, .z = 0 },
    Vector3(i32){ .x = 1, .y = 0, .z = 0 },
    Vector3(i32){ .x = 0, .y = 0, .z = -1 },
    Vector3(i32){ .x = 0, .y = 0, .z = 1 },
};

fn queueChunks(
    load_queue: *SmolQ(Vector3(i32), loaded_chunk_capacity),
    current_chunk_coords: Vector3(i32),
    loaded_chunks: []*Chunk,
    loaded_chunk_count: u8,
) void {
    outer: for (d_chunk_coordses) |d_chunk_coords| {
        if (load_queue.len + 1 > loaded_chunk_capacity - loaded_chunk_count) return;
        const next_chunk_coords = current_chunk_coords.add(d_chunk_coords);

        // Next chunk coords don't exist in either load queue or loaded chunks
        for (load_queue.items[0..load_queue.len]) |chunk_coords|
            if (next_chunk_coords.equals(chunk_coords)) continue :outer;
        for (loaded_chunks[0..loaded_chunk_count]) |chunk|
            if (next_chunk_coords.equals(chunk.coords)) continue :outer;
        load_queue.pushAssumeCapacity(next_chunk_coords);
    }
}

/// Load 'loaded_chunk_capacity' chunks into active_chunks around the player.
pub fn loadChunks(
    self: *Self,
    pos: rl.Vector3,
) !void {
    var loaded_chunk_count: u8 = 0;
    var chunk_coords: Vector3(i32) = undefined;

    var load_queue = SmolQ(Vector3(i32), loaded_chunk_capacity){
        .items = undefined,
        .len = 0,
    };

    const start_chunk_coords = worldf32ToChunki32(pos);
    load_queue.pushAssumeCapacity(start_chunk_coords); // Push start chunk
    while (loaded_chunk_count < loaded_chunk_capacity) {
        chunk_coords = load_queue.popAssumeNotEmpty();
        queueChunks(&load_queue, chunk_coords, &self.loaded_chunks, loaded_chunk_count);
        const chunk_cache_handle = self.chunk_cache_st.search(.{ .index = 0, .coords = chunk_coords }) orelse blk: { // Miss. Chunk probably needs to be loaded from disk :|
            var chunk_cache_index = self.chunk_cache_st.count;

            // Find a chunk to remove from the chunk cache
            if (self.chunk_cache_st.count + 1 > chunk_cache_capacity) {
                var chunk_to_remove_ptr: *Chunk = undefined;
                var chunk_to_remove_distance: i32 = 0;
                outer: for (&self.chunk_cache) |*cached_chunk_ptr| {
                    // If this chunk is in loaded chunks than don't remove it
                    for (self.loaded_chunks[0..loaded_chunk_count]) |loaded_chunk_ptr| {
                        if (cached_chunk_ptr == loaded_chunk_ptr) continue :outer;
                    }
                    // How far is this chunk from the start chunk pos?
                    const distance_to_start = (try std.math.absInt(start_chunk_coords.x - cached_chunk_ptr.coords.x)) +
                        (try std.math.absInt(start_chunk_coords.y - cached_chunk_ptr.coords.y)) +
                        (try std.math.absInt(start_chunk_coords.z - cached_chunk_ptr.coords.z));
                    // Update farthest chunk
                    if (distance_to_start > chunk_to_remove_distance) {
                        chunk_to_remove_ptr = cached_chunk_ptr;
                        chunk_to_remove_distance = distance_to_start;
                    }
                }

                const removed_chunk_handle = self.chunk_cache_st.remove(.{ .index = undefined, .coords = chunk_to_remove_ptr.coords }) orelse unreachable;
                chunk_cache_index = removed_chunk_handle.index;

                const world_save_file = try std.fs.cwd().openFile("data/world.sav", .{ .mode = std.fs.File.OpenMode.read_write });
                defer world_save_file.close();

                const world_save_reader = world_save_file.reader(); // Read header
                const save_header = world_save_reader.readStruct(WorldSaveHeader) catch unreachable;
                const world_save_writer = world_save_file.writer(); // Update header

                const world_chunk_handle = self.world_chunk_st.search(.{ .index = undefined, .coords = removed_chunk_handle.coords }) orelse ablk: {
                    try world_save_file.seekTo(0);
                    try world_save_writer.writeStruct(WorldSaveHeader{ .chunk_count = save_header.chunk_count + 1 });
                    try self.world_chunk_st.insert(.{ .index = save_header.chunk_count + 1, .coords = removed_chunk_handle.coords });
                    break :ablk ChunkHandle{ .index = save_header.chunk_count + 1, .coords = removed_chunk_handle.coords };
                };

                try world_save_reader.skipBytes((@sizeOf(ChunkHandle) + @intCast(u32, Chunk.dim.x) * @intCast(u32, Chunk.dim.y) * @intCast(i32, Chunk.dim.z)) * (world_chunk_handle.index - 1), .{});
                try world_save_writer.writeStruct(ChunkHandle{ .index = world_chunk_handle.index, .coords = world_chunk_handle.coords });
                try world_save_writer.writeAll(&self.chunk_cache[chunk_cache_index].block_data);
            }

            const world_chunk_handle = self.world_chunk_st.search(.{ .index = 0, .coords = chunk_coords });
            if (world_chunk_handle != null) { // Use save chunk's id to retrive from disk
                const world_save_file = try std.fs.cwd().openFile("data/world.sav", .{});
                defer world_save_file.close();
                const world_save_reader = world_save_file.reader();
                try world_save_reader.skipBytes(@sizeOf(WorldSaveHeader), .{});
                std.debug.assert(world_chunk_handle.?.index > 0);
                try world_save_reader.skipBytes((@sizeOf(ChunkHandle) + @intCast(u32, Chunk.dim.x) * @intCast(u32, Chunk.dim.y) * @intCast(i32, Chunk.dim.z)) * (world_chunk_handle.?.index - 1), .{});
                const world_save_chunk = try world_save_reader.readStruct(ChunkHandle);

                self.chunk_cache[chunk_cache_index].index = world_save_chunk.index;
                self.chunk_cache[chunk_cache_index].coords = world_save_chunk.coords;
                self.chunk_cache[chunk_cache_index].block_data = try world_save_reader.readBytesNoEof(Chunk.dim.x * Chunk.dim.y * Chunk.dim.z);
            } else {
                self.chunk_cache[chunk_cache_index].index = 0;
                self.chunk_cache[chunk_cache_index].coords = chunk_coords;
                for (&self.chunk_cache[chunk_cache_index].block_data) |*byte| byte.* = 0;
            }

            const inserted_chunk_handle = ChunkHandle{ .index = chunk_cache_index, .coords = chunk_coords };
            self.chunk_cache_st.insert(inserted_chunk_handle) catch unreachable;
            break :blk inserted_chunk_handle;
        };
        self.loaded_chunks[loaded_chunk_count] = &self.chunk_cache[chunk_cache_handle.index];
        loaded_chunk_count += 1;
        std.debug.print("Loaded chunk: ({d},{d},{d})\n", .{ chunk_coords.x, chunk_coords.y, chunk_coords.z });
    }
}

pub fn cstFoundTarget(a: ChunkHandle, b: ChunkHandle) bool {
    var result = false;
    result = a.coords.equals(b.coords);
    return result;
}

pub fn cstGoLeft(a: ChunkHandle, b: ChunkHandle) bool {
    var check_left: bool = undefined;
    if (a.coords.x < b.coords.x) { // Check x coords
        check_left = true;
    } else if (a.coords.x > b.coords.x) {
        check_left = false;
    } else { // X coord is equal check y
        if (a.coords.y < b.coords.y) {
            check_left = true;
        } else if (a.coords.y > b.coords.y) {
            check_left = false;
        } else { // Y coord is equal check z
            if (a.coords.z < b.coords.z) {
                check_left = true;
            } else if (a.coords.z > b.coords.z) {
                check_left = false;
            } else unreachable;
        }
    }
    return check_left;
}
