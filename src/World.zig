const std = @import("std");
const rl = @import("rl.zig");
const scary_types = @import("scary_types.zig");
const Atlas = @import("Atlas.zig");
const Chunk = @import("Chunk.zig");

const SmolQ = scary_types.SmolQ;
const BST = scary_types.BST;
const BSTExtra = scary_types.BSTExtra;
const AutoHashMap = std.AutoHashMap;

const hashString = std.hash_map.hashString;

const Self = @This();

pub const loaded_chunk_capacity = 10;
pub const chunk_cache_capacity = loaded_chunk_capacity * 3;

pub const WorldSaveHeader = packed struct {
    chunk_count: u32,
};

pub const ChunkHandle = packed struct {
    index: u32,
    coords: @Vector(3, i32),
};

ally: std.mem.Allocator,
chunk_cache: [chunk_cache_capacity]Chunk,
loaded_chunks: [loaded_chunk_capacity]*Chunk,
chunk_cache_st: BSTExtra(ChunkHandle, .{ .preheated_node_count = chunk_cache_capacity, .growable = false }, cstGoLeft, cstFoundTarget),
world_chunk_st: BST(ChunkHandle, cstGoLeft, cstFoundTarget),
save_file: std.fs.File,

pub fn init(ally: std.mem.Allocator) Self {
    var result: Self = undefined;
    result.ally = ally;
    result.chunk_cache_st = BSTExtra(ChunkHandle, .{ .preheated_node_count = chunk_cache_capacity, .growable = false }, cstGoLeft, cstFoundTarget).init(ally);
    result.world_chunk_st = BST(ChunkHandle, cstGoLeft, cstFoundTarget).init(ally);
    return result;
}

pub fn chunkIndexFromCoords(self: *Self, coords: @Vector(3, i32)) ?usize {
    for (self.loaded_chunks, 0..) |chunk, chunk_index| {
        if (@reduce(.And, chunk.coords == coords))
            return chunk_index;
    }
    return null;
}

pub fn writeCachedChunksToDisk(self: *Self, save_path: []const u8) !void {
    const world_save_file = try std.fs.cwd().openFile(save_path, .{ .mode = std.fs.File.OpenMode.read_write });
    defer world_save_file.close();

    const world_save_reader = world_save_file.reader(); // Read header
    const world_save_writer = world_save_file.writer(); // Update header
    for (self.chunk_cache[0..self.chunk_cache_st.count]) |chunk| {
        try world_save_file.seekTo(0);
        var save_header = world_save_reader.readStruct(WorldSaveHeader) catch unreachable;
        const world_chunk_handle = self.world_chunk_st.search(.{ .index = undefined, .coords = chunk.coords }) orelse ablk: {
            try world_save_file.seekTo(0);
            save_header.chunk_count += 1;
            try world_save_writer.writeStruct(save_header);
            break :ablk ChunkHandle{ .index = save_header.chunk_count, .coords = chunk.coords };
        };
        try world_save_reader.skipBytes((@sizeOf(ChunkHandle) + @intCast(u32, Chunk.dim) * @intCast(u32, Chunk.dim) * @intCast(i32, Chunk.dim)) * (world_chunk_handle.index - 1), .{});
        try world_save_writer.writeStruct(ChunkHandle{ .index = world_chunk_handle.index, .coords = world_chunk_handle.coords });
        try world_save_writer.writeAll(&chunk.block_data);
    }
}

/// Creates a dummy world save.
/// NOTE(caleb): This function will clobber the world save at 'world_save_path'.
pub fn writeDummySave(world_save_path: []const u8, atlas: *Atlas) !void {
    const world_save_file = try std.fs.cwd().createFile(world_save_path, .{ .truncate = true });
    defer world_save_file.close();

    // Create a chunk slice 16x16 at y = 0;
    var test_chunk: Chunk = undefined;
    test_chunk.coords = @Vector(3, i32){ 0, 0, 0 };
    test_chunk.index = 1;
    for (&test_chunk.block_data) |*byte| byte.* = 0;

    var block_z: u8 = 0;
    while (block_z < Chunk.dim) : (block_z += 1) {
        var block_x: u8 = 0;
        while (block_x < Chunk.dim) : (block_x += 1)
            test_chunk.put(atlas.name_to_id.get(hashString("default_grass")) orelse unreachable, block_x, 0, block_z);
    }

    const world_save_writer = world_save_file.writer();
    try world_save_writer.writeStruct(WorldSaveHeader{ .chunk_count = 1 });
    try world_save_writer.writeStruct(ChunkHandle{ .index = test_chunk.index, .coords = test_chunk.coords });
    try world_save_writer.writeAll(&test_chunk.block_data);
}

pub fn loadSave(world: *Self, world_save_path: []const u8) !void {
    world.save_file = try std.fs.cwd().openFile(world_save_path, .{ .mode = std.fs.File.OpenMode.read_write });
    const save_file_reader = world.save_file.reader();
    const world_save_header = try save_file_reader.readStruct(WorldSaveHeader);
    for (0..world_save_header.chunk_count) |_| {
        const world_save_chunk = try save_file_reader.readStruct(ChunkHandle);
        try save_file_reader.skipBytes(@intCast(u32, Chunk.dim) * @intCast(u32, Chunk.dim) * @intCast(i32, Chunk.dim), .{});
        try world.world_chunk_st.insert(world_save_chunk);
    }
}

// TODO(caleb): Convention:
// world - block position in world space
// chunk - chunk coords
// rel - chunk relative coords

pub inline fn worldi32ToRel(pos: @Vector(3, i32)) @Vector(3, u8) {
    return @Vector(3, u8){
        @intCast(u8, @mod(pos[0], @intCast(i32, Chunk.dim))),
        @intCast(u8, @mod(pos[1], @intCast(i32, Chunk.dim))),
        @intCast(u8, @mod(pos[2], @intCast(i32, Chunk.dim))),
    };
}

pub inline fn worldf32ToWorldi32(pos: rl.Vector3) @Vector(3, i32) {
    return @Vector(3, i32){
        @floatToInt(i32, @floor(pos.x)),
        @floatToInt(i32, @floor(pos.y)),
        @floatToInt(i32, @floor(pos.z)),
    };
}

pub inline fn worldf32ToChunkRel(pos: rl.Vector3) @Vector(3, u8) {
    return @Vector(3, u8){
        @intCast(u8, @mod(@floatToInt(i32, @floor(pos.x)), @intCast(i32, Chunk.dim))),
        @intCast(u8, @mod(@floatToInt(i32, @floor(pos.y)), @intCast(i32, Chunk.dim))),
        @intCast(u8, @mod(@floatToInt(i32, @floor(pos.z)), @intCast(i32, Chunk.dim))),
    };
}

/// Takes a relative chunk position, chunk coords. Returns the block position in world space.
pub inline fn relToWorldi32(pos: @Vector(3, u8), chunk_coords: @Vector(3, i32)) @Vector(3, i32) {
    return chunk_coords * @splat(3, @as(i32, Chunk.dim)) + pos;
}

/// Given a @Vector(3, i32) in world space, return the eqv. chunk space coords.
pub inline fn worldi32ToChunki32(pos: @Vector(3, i32)) @Vector(3, i32) {
    return @Vector(3, i32){
        @divFloor(pos[0], Chunk.dim),
        @divFloor(pos[1], Chunk.dim),
        @divFloor(pos[2], Chunk.dim),
    };
}

/// Given a vector of floats in world space, return the eqv. chunk space coords.
pub inline fn worldf32ToChunki32(pos: rl.Vector3) @Vector(3, i32) {
    return @Vector(3, i32){
        @floatToInt(i32, @divFloor(pos.x, @intToFloat(f32, Chunk.dim))),
        @floatToInt(i32, @divFloor(pos.y, @intToFloat(f32, Chunk.dim))),
        @floatToInt(i32, @divFloor(pos.z, @intToFloat(f32, Chunk.dim))),
    };
}

pub const d_chunk_coordses = [_]@Vector(3, i32){
    @Vector(3, i32){ 0, 1, 0 },
    @Vector(3, i32){ 0, -1, 0 },
    @Vector(3, i32){ -1, 0, 0 },
    @Vector(3, i32){ 1, 0, 0 },
    @Vector(3, i32){ 0, 0, -1 },
    @Vector(3, i32){ 0, 0, 1 },
};

fn queueChunks(
    load_queue: *SmolQ(@Vector(3, i32), loaded_chunk_capacity),
    current_chunk_coords: @Vector(3, i32),
    loaded_chunks: []*Chunk,
    loaded_chunk_count: u8,
) void {
    outer: for (d_chunk_coordses) |d_chunk_coords| {
        if (load_queue.len + 1 > loaded_chunk_capacity - loaded_chunk_count) return;
        const next_chunk_coords = current_chunk_coords + d_chunk_coords;

        // Next chunk coords don't exist in either load queue or loaded chunks
        for (load_queue.items[0..load_queue.len]) |chunk_coords|
            if (@reduce(.And, next_chunk_coords == chunk_coords)) continue :outer;
        for (loaded_chunks[0..loaded_chunk_count]) |chunk|
            if (@reduce(.And, next_chunk_coords == chunk.coords)) continue :outer;
        load_queue.pushAssumeCapacity(next_chunk_coords);
    }
}

/// FIXME(caleb): Assumes header bytes have already been read.
fn writeChunkToDisk(world_save_f: std.fs.File, chunk: *Chunk, chunk_handle: ChunkHandle) !void {
    var world_save_reader = world_save_f.reader();
    var world_save_writer = world_save_f.writer();

    try world_save_reader.skipBytes((@sizeOf(ChunkHandle) + @intCast(u32, Chunk.dim) * @intCast(u32, Chunk.dim) * @intCast(i32, Chunk.dim)) * (chunk_handle.index - 1), .{});
    try world_save_writer.writeStruct(ChunkHandle{ .index = chunk_handle.index, .coords = chunk_handle.coords });
    try world_save_writer.writeAll(&chunk.block_data);
}

fn readChunkFromDisk(world_save_f: std.fs.File, chunk: *Chunk, world_chunk_handle: ChunkHandle) !void {
    var world_save_reader = world_save_f.reader();
    try world_save_reader.skipBytes(@sizeOf(WorldSaveHeader), .{});
    std.debug.assert(world_chunk_handle.index > 0);
    try world_save_reader.skipBytes((@sizeOf(ChunkHandle) + @intCast(u32, Chunk.dim) * @intCast(u32, Chunk.dim) * @intCast(i32, Chunk.dim)) * (world_chunk_handle.index - 1), .{});
    const world_save_chunk = try world_save_reader.readStruct(ChunkHandle);

    chunk.index = world_save_chunk.index;
    chunk.coords = world_save_chunk.coords;
    chunk.block_data = try world_save_reader.readBytesNoEof(Chunk.dim * Chunk.dim * Chunk.dim);
}

///NOTE(caleb): Stop opening the file so much dum dum.
/// Load 'loaded_chunk_capacity' chunks into active_chunks around the player.
pub fn loadChunks(
    self: *Self,
    pos: rl.Vector3,
) !void {
    var loaded_chunk_count: u8 = 0;
    var chunk_coords: @Vector(3, i32) = undefined;

    var load_queue = SmolQ(@Vector(3, i32), loaded_chunk_capacity){
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
                    const diff_start_and_cached = start_chunk_coords - cached_chunk_ptr.coords;
                    var distance_to_start =
                        try std.math.absInt(diff_start_and_cached[0]) +
                        try std.math.absInt(diff_start_and_cached[1]) +
                        try std.math.absInt(diff_start_and_cached[2]);

                    // Update farthest chunk
                    if (distance_to_start > chunk_to_remove_distance) {
                        chunk_to_remove_ptr = cached_chunk_ptr;
                        chunk_to_remove_distance = distance_to_start;
                    }
                }

                const removed_chunk_handle = self.chunk_cache_st.remove(.{ .index = undefined, .coords = chunk_to_remove_ptr.coords }) orelse unreachable;
                chunk_cache_index = removed_chunk_handle.index;

                try self.save_file.seekTo(0);
                const world_save_reader = self.save_file.reader(); // Read header
                const save_header = world_save_reader.readStruct(WorldSaveHeader) catch unreachable;
                const world_save_writer = self.save_file.writer(); // Update header

                const world_chunk_handle = self.world_chunk_st.search(.{ .index = undefined, .coords = removed_chunk_handle.coords }) orelse ablk: {
                    try self.save_file.seekTo(0);
                    try world_save_writer.writeStruct(WorldSaveHeader{ .chunk_count = save_header.chunk_count + 1 });
                    try self.world_chunk_st.insert(.{ .index = save_header.chunk_count + 1, .coords = removed_chunk_handle.coords });
                    break :ablk ChunkHandle{ .index = save_header.chunk_count + 1, .coords = removed_chunk_handle.coords };
                };
                try writeChunkToDisk(self.save_file, &self.chunk_cache[chunk_cache_index], world_chunk_handle);
            }

            const world_chunk_handle = self.world_chunk_st.search(.{ .index = 0, .coords = chunk_coords });
            if (world_chunk_handle != null) { // Use save chunk's id to retrive from disk
                try self.save_file.seekTo(0);
                try readChunkFromDisk(self.save_file, &self.chunk_cache[chunk_cache_index], world_chunk_handle.?);
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
    }
}

pub fn cstFoundTarget(a: ChunkHandle, b: ChunkHandle) bool {
    return @reduce(.And, a.coords == b.coords);
}

pub fn cstGoLeft(a: ChunkHandle, b: ChunkHandle) bool {
    var check_left: bool = undefined;
    if (a.coords[0] < b.coords[0]) { // Check x coords
        check_left = true;
    } else if (a.coords[0] > b.coords[0]) {
        check_left = false;
    } else { // X coord is equal check y
        if (a.coords[1] < b.coords[1]) {
            check_left = true;
        } else if (a.coords[1] > b.coords[1]) {
            check_left = false;
        } else { // Y coord is equal check z
            if (a.coords[2] < b.coords[2]) {
                check_left = true;
            } else if (a.coords[2] > b.coords[2]) {
                check_left = false;
            } else unreachable;
        }
    }
    return check_left;
}
