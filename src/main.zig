const std = @import("std");
const rl = @import("raylib.zig");
const rlgl = rl.rlgl;

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const hashString = std.hash_map.hashString;

// TODO(caleb):
// -----------------------------------------------------------------------------------
// Lighting see learnopengl tutorial
// Build a toy map in a voxel editor and import it
// Player collision volume
// Gravity/Jump

// OBJECTIVES (possibly in the form of notes that you can pick up?)
// INSERT SCARY ENEMY IDEAS HERE...

const block_dim = rl.Vector3{ .x = 1, .y = 1, .z = 1 };
const chunk_dim = rl.Vector3{ .x = 16, .y = 1, .z = 16 };

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
    texture: rl.Texture,
    name_to_id: AutoHashMap(u64, u16),
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

fn updateLightValues(shader: rl.Shader, light: *Light) void {

    // Send to shader light enabled state and type
    rl.SetShaderValue(shader, light.enabled_loc, &light.enabled, @enumToInt(rl.ShaderUniformDataType.SHADER_UNIFORM_INT));
    rl.SetShaderValue(shader, light.type_loc, &light.type, @enumToInt(rl.ShaderUniformDataType.SHADER_UNIFORM_INT));

    // Send to shader light position, target, and color values
    rl.SetShaderValue(shader, light.position_loc, &light.position, @enumToInt(rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3));
    rl.SetShaderValue(shader, light.target_loc, &light.target, @enumToInt(rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3));
    rl.SetShaderValue(shader, light.color_loc, &light.color, @enumToInt(rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4));
}

inline fn denseMapLookup(dense_map: []i16, x: i16, y: i16, z: i16) ?i16 {
    const map_width = @floatToInt(u16, chunk_dim.x);
    const map_height = @floatToInt(u16, chunk_dim.y);
    const map_length = @floatToInt(u16, chunk_dim.z);
    if (x >= map_width or y >= map_height or z >= map_length or x < 0 or y < 0 or z < 0)
        return null; // Block index out of bounds.
    return dense_map[map_width * map_height * @intCast(u16, z) + @intCast(u16, y) * map_width + @intCast(u16, x)];
}

fn blockCoordsFromPoint(dense_map: []i16, p: rl.Vector3) rl.Vector3 {
    const block_x = @floatToInt(i16, p.x);
    const block_y = @floatToInt(i16, p.y);
    const block_z = @floatToInt(i16, p.z);

    const val = denseMapLookup(dense_map, block_x, block_y, block_z);
    if (val != null and val.? == 1)
        return rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z) };

    // NOTE(caleb): sqrt(floatEps(f32)), meaning that the two numbers are considered equal if at least half of the digits are equal.
    if (std.math.approxEqRel(f32, @floor(p.x), p.x, std.math.sqrt(std.math.floatEps(f32)))) {
        return rl.Vector3{ .x = @intToFloat(f32, block_x - 1), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z) };
    } else if (std.math.approxEqRel(f32, @floor(p.y), p.y, std.math.sqrt(std.math.floatEps(f32)))) {
        return rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y - 1), .z = @intToFloat(f32, block_z) };
    } else if (std.math.approxEqRel(f32, @floor(p.z), p.z, std.math.sqrt(std.math.floatEps(f32)))) {
        return rl.Vector3{ .x = @intToFloat(f32, block_x), .y = @intToFloat(f32, block_y), .z = @intToFloat(f32, block_z - 1) };
    }
    unreachable;
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

/// Generate chunk sized mesh starting at world origin.
fn stupidMesh(ally: *Allocator, sprite_sheet: *SpriteSheet) !rl.Mesh {
    var result = std.mem.zeroes(rl.Mesh);
    result.triangleCount = 2 * 6 * @floatToInt(c_int, chunk_dim.x) * @floatToInt(c_int, chunk_dim.y) * @floatToInt(c_int, chunk_dim.z);
    result.vertexCount = 3 * result.triangleCount;

    var normals = try ally.alloc(f32, @intCast(u32, result.vertexCount * 3));
    var texcoords = try ally.alloc(f32, @intCast(u32, result.vertexCount * 2));
    var verticies = try ally.alloc(f32, @intCast(u32, result.vertexCount * 3));
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

    var block_z: f32 = 0;
    while (block_z < chunk_dim.z) : (block_z += 1) {
        var block_y: f32 = 0;
        while (block_y < chunk_dim.y) : (block_y += 1) {
            var block_x: f32 = 0;
            while (block_x < chunk_dim.x) : (block_x += 1) {

                // Top face
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

                // Front face
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

                // Back face
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

                // Bottom face
                setFaceNormals(normals, &normals_offset, 0, -1, 0); // Normals pointing away from viewer
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

                // Right face
                setFaceNormals(normals, &normals_offset, 1.0, 0.0, 0.0); // Normals Pointing Right
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

                // Left Face
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
    result.normals = @ptrCast([*c]f32, normals);
    result.texcoords = @ptrCast([*c]f32, texcoords);
    result.vertices = @ptrCast([*c]f32, verticies);

    rl.UploadMesh(&result, false);

    return result;
}

pub fn main() !void {
    const screen_width: c_int = 1600;
    const screen_height: c_int = 900;
    rl.InitWindow(screen_width, screen_height, "Scary Craft");
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(target_fps);
    rl.DisableCursor();

    var ally = std.heap.page_allocator;

    const font = rl.LoadFont("data/FiraCode-Medium.ttf");

    var sprite_sheet: SpriteSheet = undefined;
    sprite_sheet.texture = rl.LoadTexture("data/atlas.png");
    sprite_sheet.name_to_id = AutoHashMap(u64, u16).init(ally);
    {
        var parser = std.json.Parser.init(ally, false);
        defer parser.deinit();

        const atlas_data_file = try std.fs.cwd().openFile("data/atlas_data.json", .{});
        defer atlas_data_file.close();

        var raw_atlas_json = try atlas_data_file.reader().readAllAlloc(ally, 1024 * 5); // 5kib should be enough
        defer ally.free(raw_atlas_json);

        var parsed_atlas_data = try parser.parse(raw_atlas_json);
        const columns_value = parsed_atlas_data.root.Object.get("columns") orelse unreachable;
        sprite_sheet.columns = @intCast(u16, columns_value.Integer);

        const tile_data = parsed_atlas_data.root.Object.get("tiles") orelse unreachable;
        for (tile_data.Array.items) |tile| {
            var tile_id = tile.Object.get("id") orelse unreachable;
            var tile_type = tile.Object.get("type") orelse unreachable;
            try sprite_sheet.name_to_id.put(hashString(tile_type.String), @intCast(u16, tile_id.Integer));
        }
    }

    var shader: rl.Shader = rl.LoadShader(rl.TextFormat("data/shaders/lighting.vs", @intCast(c_int, 330)), rl.TextFormat("data/shaders/lighting.fs", @intCast(c_int, 330)));
    shader.locs[@enumToInt(rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW)] = rl.GetShaderLocation(shader, "viewPos");

    const ambient_loc = rl.GetShaderLocation(shader, "ambient");
    rl.SetShaderValue(shader, ambient_loc, &[_]f32{ 0.001, 0.001, 0.001, 1.0 }, @enumToInt(rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4));

    var light_source: Light = undefined;
    // NOTE(caleb): Lighting shader naming must be the provided ones
    light_source.enabled_loc = rl.GetShaderLocation(shader, "light.enabled");
    light_source.type_loc = rl.GetShaderLocation(shader, "light.type");
    light_source.position_loc = rl.GetShaderLocation(shader, "light.position");
    light_source.target_loc = rl.GetShaderLocation(shader, "light.target");
    light_source.color_loc = rl.GetShaderLocation(shader, "light.color");
    light_source.color = [4]f32{ 1, 1, 1, 1 };

    var default_material = rl.LoadMaterialDefault();
    default_material.shader = shader;
    rl.SetMaterialTexture(&default_material, @enumToInt(rl.MATERIAL_MAP_DIFFUSE), sprite_sheet.texture);

    var debug_axes = false;
    var debug_text_info = false;

    var camera: rl.Camera = undefined;
    camera.position = rl.Vector3{ .x = 0.0, .y = 10.0, .z = 10.0 };
    camera.target = rl.Vector3{ .x = 0.0, .y = 0.0, .z = -1.0 };
    camera.up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 60.0;
    camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;

    // Debug chunk slice 16x16 at y = 0;
    var dense_map = try ally.alloc(i16, @floatToInt(i16, chunk_dim.x * chunk_dim.y * chunk_dim.z));
    for (dense_map) |*item|
        item.* = 0;

    var block_z: u16 = 0;
    while (block_z < @floatToInt(i16, chunk_dim.z)) : (block_z += 1) {
        var block_x: u16 = 0;
        while (block_x < @floatToInt(i16, chunk_dim.x)) : (block_x += 1) {
            dense_map[@floatToInt(u16, chunk_dim.x * chunk_dim.y) * block_z + block_x] = 1;
        }
    }

    // NOTE(caleb): This will need to happen every time block geo. is changed.
    var chunk_mesh = try stupidMesh(&ally, &sprite_sheet);

    while (!rl.WindowShouldClose()) {
        const screen_dim = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()), .y = @intToFloat(f32, rl.GetScreenHeight()) };
        const screen_mid = rl.Vector2Scale(screen_dim, 0.5);

        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_F1)) {
            debug_axes = !debug_axes;
            debug_text_info = !debug_text_info;
        }

        var speed_scalar: f32 = 1;
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_SHIFT)) {
            speed_scalar = 2;
        }

        var camera_move = rl.Vector3{ .x = 0, .y = 0, .z = 0 };
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_W)) {
            camera_move.x += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_S)) {
            camera_move.x -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_A)) {
            camera_move.y -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_D)) {
            camera_move.y += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE)) {
            camera_move.z += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL)) {
            camera_move.z -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }

        rl.UpdateCameraPro(&camera, camera_move, rl.Vector3{ .x = rl.GetMouseDelta().x * mouse_sens, .y = rl.GetMouseDelta().y * mouse_sens, .z = 0 }, 0); //rl.GetMouseWheelMove());

        // Update uniform shader values.
        const camera_position = [3]f32{ camera.position.x, camera.position.y, camera.position.z };
        const camera_target = [3]f32{ camera.target.x, camera.target.y, camera.target.z };
        light_source.position = camera_position;
        light_source.target = camera_target;
        updateLightValues(shader, &light_source);
        rl.SetShaderValue(shader, shader.locs[@enumToInt(rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW)], &camera_position, @enumToInt(rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3));

        const crosshair_ray = rl.Ray{ .position = camera.position, .direction = rl.GetCameraForward(&camera) };
        const crosshair_ray_collision = rl.GetRayCollisionMesh(crosshair_ray, chunk_mesh, rl.MatrixIdentity());

        var target_block_coords: rl.Vector3 = undefined;
        if (crosshair_ray_collision.hit) {
            target_block_coords = blockCoordsFromPoint(dense_map, crosshair_ray_collision.point);
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.BeginMode3D(camera);

        rl.DrawMesh(chunk_mesh, default_material, rl.MatrixIdentity());
        rl.DrawGrid(10, 1);

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
                target_block_point_strz = try std.fmt.bufPrintZ(&strz_buffer, "Target block: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ target_block_coords.x, target_block_coords.y, target_block_coords.z });
                _ = target_block_point_strz_dim;
            }
            rl.DrawTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), rl.Vector2{ .x = 0, .y = fps_strz_dim.y + camera_pos_strz_dim.y }, font_size, font_spacing, rl.WHITE);
        }

        rl.EndDrawing();
    }

    rl.CloseWindow();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

/// Draw cube textured
fn drawCubeTexture(top_texture: rl.Texture2D, not_top_texture: rl.Texture2D, pos: rl.Vector3, width: f32, height: f32, length: f32, color: rl.Color) void {
    const x = pos.x;
    const y = pos.y;
    const z = pos.z;

    rlgl.Begin(@enumToInt(rlgl.DrawMode.QUADS));
    rlgl.Color4ub(color.r, color.g, color.b, color.a);

    rlgl.SetTexture(top_texture.id);

    // Top Face
    rlgl.Normal3f(0.0, 1.0, 0.0); // Normal Pointing Up
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x, y + height, z); // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x, y + height, z + length); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x + width, y + height, z + length); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x + width, y + height, z); // Top Right Of The Texture and Quad

    rlgl.SetTexture(not_top_texture.id);

    // Front Face
    rlgl.Normal3f(0.0, 0.0, 1.0); // Normal Pointing Towards Viewer
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x, y, z + length); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x + width, y, z + length); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x + width, y + height, z + length); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x, y + height, z + length); // Top Left Of The Texture and Quad

    // Back Face
    rlgl.Normal3f(0.0, 0.0, -1.0); // Normal Pointing Away From Viewer
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x + width, y, z); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x, y, z); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x, y + height, z); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x + width, y + height, z); // Top Left Of The Texture and Quad

    // Bottom Face
    rlgl.Normal3f(0.0, -1.0, 0.0); // Normal Pointing Down
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x + width, y, z + length); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x, y, z + width); // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x, y, z); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x + width, y, z); // Bottom Right Of The Texture and Quad

    // Right face
    rlgl.Normal3f(1.0, 0.0, 0.0); // Normal Pointing Right
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x + width, y, z); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x + width, y + height, z); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x + width, y + height, z + length); // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x + width, y, z + length); // Bottom Left Of The Texture and Quad

    // Left Face
    rlgl.Normal3f(-1.0, 0.0, 0.0); // Normal Pointing Left
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x, y, z); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x, y, z + length); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x, y + height, z + length); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x, y + height, z); // Top Left Of The Texture and Quad

    rlgl.SetTexture(0);
    rlgl.End();
}
