const std = @import("std");
const rl = @import("rl.zig");

const AutoHashMap = std.AutoHashMap;

const Self = @This();

ally: std.mem.Allocator,
columns: u16,
texture: rl.Texture,
name_to_id: AutoHashMap(u64, u8),

pub fn init(ally: std.mem.Allocator) Self {
    return Self{
        .ally = ally,
        .columns = undefined,
        .texture = undefined,
        .name_to_id = undefined,
    };
}

pub fn load(self: *Self, comptime atlas_image_path: [:0]const u8, atlas_config_path: []const u8) !void {
    self.texture = rl.LoadTexture(atlas_image_path.ptr);
    self.name_to_id = AutoHashMap(u64, u8).init(self.ally);

    var arena_ally = std.heap.ArenaAllocator.init(self.ally);
    defer arena_ally.deinit();

    var parser = std.json.Parser.init(arena_ally.allocator(), std.json.AllocWhen.alloc_if_needed);

    const atlas_data_file = try std.fs.cwd().openFile(atlas_config_path, .{});
    defer atlas_data_file.close();

    var raw_atlas_json = try atlas_data_file.reader().readAllAlloc(arena_ally.allocator(), 1024 * 2); // 2kib should be enough

    var parsed_atlas_data = try parser.parse(raw_atlas_json);
    const columns_value = parsed_atlas_data.root.object.get("columns") orelse unreachable;
    self.columns = @intCast(u16, columns_value.integer);

    const tile_data = parsed_atlas_data.root.object.get("tiles") orelse unreachable;
    for (tile_data.array.items) |tile| {
        var tile_id = tile.object.get("id") orelse unreachable;
        var tile_type = tile.object.get("type") orelse unreachable;
        try self.name_to_id.put(std.hash_map.hashString(tile_type.string), @intCast(u8, tile_id.integer));
    }
}
