const std = @import("std");
const rl = @import("rl.zig");
const scary_types = @import("scary_types.zig");
const Chunk = @import("Chunk.zig");

const SmolQ = scary_types.SmolQ;
const BST = scary_types.BST;
const Vector3 = scary_types.Vector3;
const AutoHashMap = std.AutoHashMap;

const hashString = std.hash_map.hashString;

const Self = @This();

pub const loaded_chunk_capacity = 7;

const WorldSaveHeader = packed struct {
    chunk_count: u32,
};

const WorldSaveChunk = packed struct {
    id: u32, // NOTE(caleb): This will act as an index into the world save.
    coords: Vector3(i32),
};

ally: std.mem.Allocator,
chunk_map: AutoHashMap(u64, Chunk),
chunk_search_tree: BST(WorldSaveChunk, cstGoLeft, cstFoundTarget),
loaded_chunks: [loaded_chunk_capacity]*Chunk,

pub fn init(ally: std.mem.Allocator) Self {
    var result: Self = undefined;
    result.ally = ally;
    result.chunk_map = AutoHashMap(u64, Chunk).init(ally);
    result.chunk_map.ensureTotalCapacity(loaded_chunk_capacity) catch unreachable;
    result.chunk_search_tree = BST(WorldSaveChunk, cstGoLeft, cstFoundTarget).init(ally);
    return result;
}

pub fn hashChunk(coords: Vector3(i32)) u64 {
    var chunk_hash_buf: [128]u8 = undefined;
    const chunk_coords_str = std.fmt.bufPrint(&chunk_hash_buf, "{d}{d}{d}", .{ coords.x, coords.y, coords.z }) catch unreachable;
    return hashString(chunk_coords_str);
}

pub fn chunkFromCoords(self: *Self, coords: Vector3(i32)) ?*Chunk {
    for (self.loaded_chunks) |chunk| {
        if (chunk.coords.equals(coords))
            return chunk;
    }
    return null;
}

/// Creates a dummy world save.
/// NOTE(caleb): This function will clobber the world save at 'world_save_path'.
pub fn writeDummySave(world_save_path: []const u8) !void {
    const world_save_file = try std.fs.cwd().createFile(world_save_path, .{ .truncate = true });
    defer world_save_file.close();

    // Create a chunk slice 16x16 at y = 0;
    var test_chunk: Chunk = undefined;
    test_chunk.coords = Vector3(i32){ .x = 0, .y = 0, .z = 0 };
    test_chunk.id = 1;
    for (&test_chunk.block_data) |*byte| byte.* = 0;

    var block_z: u8 = 0;
    while (block_z < Chunk.dim.z) : (block_z += 1) {
        var block_x: u8 = 0;
        while (block_x < Chunk.dim.x) : (block_x += 1) {
            test_chunk.put(1, block_x, 0, block_z);
        }
    }

    const world_save_writer = world_save_file.writer();
    try world_save_writer.writeStruct(WorldSaveHeader{ .chunk_count = 1 });
    try world_save_writer.writeStruct(WorldSaveChunk{ .id = test_chunk.id, .coords = test_chunk.coords });
    try world_save_writer.writeAll(&test_chunk.block_data);
}

pub fn loadSave(world: *Self, world_save_path: []const u8) !void {
    const world_save_file = try std.fs.cwd().openFile(world_save_path, .{});
    defer world_save_file.close();
    const save_file_reader = world_save_file.reader();
    const world_save_header = try save_file_reader.readStruct(WorldSaveHeader);
    for (0..world_save_header.chunk_count) |_| {
        const world_save_chunk = try save_file_reader.readStruct(WorldSaveChunk);
        try world.chunk_search_tree.insert(world_save_chunk);
    }
}

/// Given a Vector(i32) in world space, return the eqv. chunk space coords.
inline fn worldi32ToChunki32(pos: Vector3(i32)) Vector3(i32) {
    var result: Vector3(i32) = undefined;
    result.x = @divFloor(pos.x, Chunk.dim.x);
    result.y = @divFloor(pos.y, Chunk.dim.y);
    result.z = @divFloor(pos.z, Chunk.dim.z);
    return result;
}

/// Given a vector of floats in world space, return the eqv. chunk space coords.
inline fn worldf32ToChunki32(pos: rl.Vector3) Vector3(i32) {
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
    var current_chunk_ptr: *Chunk = undefined;
    var chunk_coords: Vector3(i32) = undefined;
    var chunk_hash_buf: [128]u8 = undefined;
    var chunk_coords_str: []u8 = undefined;

    var load_queue = SmolQ(Vector3(i32), loaded_chunk_capacity){
        .items = undefined,
        .len = 0,
    };

    const start_chunk_coords = worldf32ToChunki32(pos);
    load_queue.pushAssumeCapacity(start_chunk_coords); // Push start chunk
    while (loaded_chunk_count < loaded_chunk_capacity) {
        chunk_coords = load_queue.popAssumeNotEmpty();
        queueChunks(&load_queue, chunk_coords, &self.loaded_chunks, loaded_chunk_count);
        chunk_coords_str = try std.fmt.bufPrint(&chunk_hash_buf, "{d}{d}{d}", .{ chunk_coords.x, chunk_coords.y, chunk_coords.z });
        current_chunk_ptr = self.chunk_map.getPtr(hashString(chunk_coords_str)) orelse blk: { // Miss. Chunk probably needs to be loaded from disk :|
            var world_chunk: Chunk = undefined;

            const world_chunk_node = self.chunk_search_tree.search(.{ .id = 0, .coords = chunk_coords });
            if (world_chunk_node == null) { // Chunk isn't on disk. Initialize a new chunk.
                world_chunk.coords = chunk_coords;
                // NOTE(caleb): Chunk id is assigned either on world save or on chunk map eviction
                //     a value of 0 indicates that it needs a new entry in the save file.
                world_chunk.id = 0;
                for (&world_chunk.block_data) |*block| block.* = 0;

                // var block_z: u8 = 0;
                // while (block_z < Chunk.dim.z) : (block_z += 1) {
                //     var block_x: u8 = 0;
                //     while (block_x < Chunk.dim.x) : (block_x += 1) {
                //         world_chunk.put(1, block_x, 0, block_z);
                //     }
                // }
            } else { // Use save chunk's id to retrive from disk
                const world_save_file = try std.fs.cwd().openFile("data/world.sav", .{});
                defer world_save_file.close();
                const world_save_reader = world_save_file.reader();
                try world_save_reader.skipBytes(@sizeOf(WorldSaveHeader), .{});
                try world_save_reader.skipBytes((@sizeOf(WorldSaveChunk) + @intCast(u32, Chunk.dim.x) * @intCast(u32, Chunk.dim.y) * @intCast(i32, Chunk.dim.z)) * (world_chunk_node.?.id - 1), .{});
                const world_save_chunk = try world_save_reader.readStruct(WorldSaveChunk);
                world_chunk.id = world_save_chunk.id;
                world_chunk.coords = world_save_chunk.coords;
                world_chunk.block_data = try world_save_reader.readBytesNoEof(Chunk.dim.x * Chunk.dim.y * Chunk.dim.z);
            }

            if (self.chunk_map.unmanaged.available == 0) { // Remove an entry from the chunk map
                var chunk_to_remove_key: u64 = undefined;
                var chunk_to_remove_distance: i32 = 0;
                var chunk_map_iter = self.chunk_map.iterator();
                outer: while (chunk_map_iter.next()) |entry| {

                    // If this chunk is in loaded chunks than don't remove it
                    for (self.loaded_chunks[0..loaded_chunk_count]) |chunk_ptr| {
                        if (entry.value_ptr.coords.equals(chunk_ptr.coords))
                            continue :outer;
                    }

                    // How far is this chunk from the start chunk pos?
                    const distance_to_start = (try std.math.absInt(entry.value_ptr.coords.x) + try std.math.absInt(start_chunk_coords.x)) +
                        (try std.math.absInt(entry.value_ptr.coords.x) + try std.math.absInt(start_chunk_coords.y)) +
                        (try std.math.absInt(entry.value_ptr.coords.z) + try std.math.absInt(start_chunk_coords.z));

                    if (distance_to_start > chunk_to_remove_distance) { // Update farthest chunk
                        chunk_to_remove_key = hashChunk(entry.value_ptr.coords);
                        chunk_to_remove_distance = distance_to_start;
                    }
                }

                const removed_chunk_kv = self.chunk_map.fetchRemove(chunk_to_remove_key) orelse unreachable;
                std.debug.print("removed chunk (x: {d}, y: {d}, z: {d})\n", .{ removed_chunk_kv.value.coords.x, removed_chunk_kv.value.coords.y, removed_chunk_kv.value.coords.z }); // TODO(caleb): write this to disk

                self.chunk_map.clearRetainingCapacity();
            }

            self.chunk_map.putAssumeCapacityNoClobber(hashString(chunk_coords_str), world_chunk);
            break :blk self.chunk_map.getPtr(hashString(chunk_coords_str)) orelse unreachable;
        };
        self.loaded_chunks[loaded_chunk_count] = current_chunk_ptr;
        loaded_chunk_count += 1;
        std.debug.print("Loaded chunk: ({d},{d},{d})\n", .{ current_chunk_ptr.coords.x, current_chunk_ptr.coords.y, current_chunk_ptr.coords.z });
    }
}

fn cstFoundTarget(a: WorldSaveChunk, b: WorldSaveChunk) bool {
    var result = false;
    result = a.coords.equals(b.coords);
    return result;
}

fn cstGoLeft(a: WorldSaveChunk, b: WorldSaveChunk) bool {
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
