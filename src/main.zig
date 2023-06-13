const std = @import("std");
const rl = @import("rl.zig");
const rgui = @import("rgui.zig");
const scary_types = @import("scary_types.zig");
const mesher = @import("mesher.zig");
const block_caster = @import("block_caster.zig");

const Chunk = @import("Chunk.zig");
const World = @import("World.zig");
const Atlas = @import("Atlas.zig");
const Frustum = @import("math/Frustum.zig");
const Plane = @import("math/Plane.zig");

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

// FIXME(caleb):
// Fix the renderer :(
// Collision system

// TODO(caleb):
// -----------------------------------------------------------------------------------
// 3rd person camera
// Gravity/Jump/player collision
// Player collision volume
// @Vector
// NON JANK console

// OBJECTIVES (possibly in the form of notes that you can pick up?)
// INSERT SCARY ENEMY IDEAS HERE...

// Functional frustum culling ( do this when game gets slow? )

const meters_per_block = 1;

const crosshair_thickness_in_pixels = 2;
const crosshair_length_in_pixels = 20;

const camera_offset_y = -0.3;
const player_width = meters_per_block / 2;
const player_height = meters_per_block * 2 - rl.EPSILON;
const player_length = player_width;

const target_fps = 120;
const fovy = 60.0;
const crosshair_block_range = 4;
const move_speed_blocks_per_second = 4;
const mouse_sens = 0.1;

const font_size = 20;
const font_spacing = 2;

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

const Direction = enum(usize) {
    up = 0,
    down,
    right,
    left,
    forward,
    backward,
};

const directions = [_]rl.Vector3{
    rl.Vector3{ .x = 0, .y = 1, .z = 0 }, // Up
    rl.Vector3{ .x = 0, .y = -1, .z = 0 }, // Down
    rl.Vector3{ .x = 1, .y = 0, .z = 0 }, // Right
    rl.Vector3{ .x = -1, .y = 0, .z = 0 }, // Left
    rl.Vector3{ .x = 0, .y = 0, .z = -1 }, // Forward
    rl.Vector3{ .x = 0, .y = 0, .z = 1 }, // Backwrad
};

/// Moves the player and camera in camera's forward direction
fn playerAndCameraMoveForward(player_position: *rl.Vector3, camera: *rl.Camera, distance: f32, moveInWorldPlane: bool) void {
    var forward = rl.GetCameraForward(camera);

    if (moveInWorldPlane) {
        // Project vector onto world plane
        forward.y = 0;
        forward = rl.Vector3Normalize(forward);
    }

    // Scale by distance
    forward = rl.Vector3Scale(forward, distance);

    // Move position and target
    player_position.* = rl.Vector3Add(player_position.*, forward);
    camera.position = rl.Vector3Add(camera.position, forward);
    camera.target = rl.Vector3Add(camera.target, forward);
}

/// Moves player and camera in camera's right direction
fn playerAndCameraMoveRight(player_position: *rl.Vector3, camera: *rl.Camera, distance: f32, move_in_world_plane: bool) void {
    var right = rl.GetCameraRight(camera);

    if (move_in_world_plane) {
        // Project vector onto world plane
        right.y = 0;
        right = rl.Vector3Normalize(right);
    }

    // Scale by distance
    right = rl.Vector3Scale(right, distance);

    // Move position and target
    player_position.* = rl.Vector3Add(player_position.*, right);
    camera.position = rl.Vector3Add(camera.position, right);
    camera.target = rl.Vector3Add(camera.target, right);
}

/// Moves the player and camera in camera's up direction
fn playerAndCameraMoveUp(player_position: *rl.Vector3, camera: *rl.Camera, distance: f32) void {
    var up = rl.GetCameraUp(camera);

    // Scale by distance
    up = rl.Vector3Scale(up, distance);

    // Move position and target
    player_position.* = rl.Vector3Add(player_position.*, up);
    camera.position = rl.Vector3Add(camera.position, up);
    camera.target = rl.Vector3Add(camera.target, up);
}

/// Rotates the camera by rotation amount x,y given in deg
fn rotateCamera(camera: *rl.Camera, rotation: rl.Vector3) void {
    rl.CameraPitch(
        camera,
        -rotation.y * rl.DEG2RAD,
        true, // Lock view
        false, // Rotate around target
        false, // Rotate up
    );
    rl.CameraYaw(
        camera,
        -rotation.x * rl.DEG2RAD,
        false, // Rotate around target
    );
    rl.CameraRoll(camera, rotation.z * rl.DEG2RAD);
}

/// Moves the player and camera
fn movePlayerAndCamera(player_position: *rl.Vector3, camera: *rl.Camera, movement: rl.Vector3) void {
    playerAndCameraMoveForward(
        player_position,
        camera,
        movement.x,
        true, // Move in world plane
    );
    playerAndCameraMoveRight(
        player_position,
        camera,
        movement.y,
        true, // Move in world plane
    );
    playerAndCameraMoveUp(player_position, camera, movement.z);
}

/// Updates bounding box positions to point p
fn shiftBoundingBox(bb: *rl.BoundingBox, p: rl.Vector3) void {
    bb.min.x = p.x - player_width * 0.5;
    bb.min.y = p.y;
    bb.min.z = p.z - player_length * 0.5;
    bb.max.x = bb.min.x + player_width;
    bb.max.y = bb.min.y + player_height;
    bb.max.z = bb.min.z + player_length;
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

fn asdf(world: *World, velocity: rl.Vector3, aabb: rl.BoundingBox) bool {
    const world_min = World.worldf32ToWorldi32(rl.Vector3Add(aabb.min, velocity));
    const world_max = World.worldf32ToWorldi32(rl.Vector3Add(aabb.max, velocity));

    var world_block_pos = world_min;
    while (world_block_pos.x <= world_max.x) : (world_block_pos.x += 1) {
        while (world_block_pos.y <= world_max.y) : (world_block_pos.y += 1) {
            while (world_block_pos.z <= world_max.z) : (world_block_pos.z += 1) {
                const chunk_coords = World.worldi32ToChunki32(world_block_pos);
                const chunk_index = world.chunkIndexFromCoords(chunk_coords) orelse unreachable;
                const chunk_rel_pos = World.worldi32ToRel(world_block_pos);

                if ((world.loaded_chunks[chunk_index].fetch(chunk_rel_pos.x, chunk_rel_pos.y, chunk_rel_pos.z) orelse unreachable) != 0) {
                    return true;
                }
            }
        }
    }
    return false;
}

pub fn main() !void {
    const screen_width: c_int = 1920;
    const screen_height: c_int = 1080;
    rl.InitWindow(screen_width, screen_height, "Scary Craft :o");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(target_fps);
    rl.DisableCursor();

    var page_ally = std.heap.page_allocator;
    var back_buffer = try page_ally.alloc(u8, 1024 * 1024 * 5); // 5mb
    var fb_ally = std.heap.FixedBufferAllocator.init(back_buffer);
    var arena_ally = std.heap.ArenaAllocator.init(fb_ally.allocator());

    const font = rl.LoadFont("data/FiraCode-Medium.ttf");

    rgui.GuiLoadStyle("raygui/styles/dark/dark.rgs");
    rgui.GuiDisable();

    var atlas = Atlas.init(arena_ally.allocator());
    try atlas.load("data/atlas.png", "data/atlas_data.json");

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
    rl.SetMaterialTexture(&default_material, rl.MATERIAL_MAP_DIFFUSE, atlas.texture);

    var debug_axes = false;
    var debug_text_info = false;

    var camera: rl.Camera = undefined;
    camera.position = rl.Vector3{ .x = 8.0, .y = 10.0, .z = 10.0 };
    camera.target = rl.Vector3{ .x = 0.0, .y = 0.0, .z = -1.0 };
    camera.up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = fovy;
    camera.projection = rl.CAMERA_PERSPECTIVE;

    var player_bounding_box: rl.BoundingBox = undefined;
    var last_camera_position = camera.position;

    // try World.writeDummySave("data/world.sav", &atlas);
    var world = World.init(arena_ally.allocator());
    try world.loadSave("data/world.sav");
    try world.loadChunks(camera.position);

    var mesh_pool = try MemoryPoolExtra([mesher.mem_per_chunk]u8, .{ .alignment = null, .growable = false }).initPreheated(arena_ally.allocator(), World.loaded_chunk_capacity);
    var chunk_meshes: [World.loaded_chunk_capacity]mesher.ChunkMesh = undefined;
    for (&chunk_meshes, 0..) |*chunk_mesh, chunk_index| {
        chunk_mesh.* = mesher.cullMesh(&mesh_pool, @intCast(u8, chunk_index), &world, &atlas) catch unreachable;
        rl.UploadMesh(&chunk_mesh.mesh, false);
    }

    var command_buffer: [128]u8 = undefined;
    var editing_command_buffer = false;
    var empty_str = try std.fmt.bufPrintZ(&command_buffer, "", .{});

    var held_block_id = atlas.name_to_id.get(hashString("default_grass")) orelse unreachable;

    while (!rl.WindowShouldClose()) {
        const screen_dim = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()), .y = @intToFloat(f32, rl.GetScreenHeight()) };
        const screen_mid = rl.Vector2Scale(screen_dim, 0.5);
        const aspect = screen_dim.x / screen_dim.y;
        _ = aspect;
        const delta_time_ms = rl.GetFrameTime() * 1000;
        _ = delta_time_ms;

        if (rl.IsKeyPressed(rl.KEY_F1)) {
            debug_axes = !debug_axes;
            debug_text_info = !debug_text_info;
        }

        var speed_scalar: f32 = 1;
        if (rl.IsKeyDown(rl.KEY_LEFT_SHIFT)) {
            speed_scalar = 2;
        }

        var player_velocity = rl.Vector3{ .x = 0, .y = 0, .z = 0 };
        if (rl.IsKeyDown(rl.KEY_W)) {
            player_velocity.x += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_S)) {
            player_velocity.x -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_A)) {
            player_velocity.y -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_D)) {
            player_velocity.y += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_SPACE)) {
            player_velocity.z += move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyDown(rl.KEY_LEFT_CONTROL)) {
            player_velocity.z -= move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime();
        }
        if (rl.IsKeyPressed(rl.KEY_SLASH)) {
            editing_command_buffer = true; //TODO(caleb): Fix this jankness
            rgui.GuiEnable();
        }

        var player_position = rl.Vector3Add(camera.position, rl.Vector3{ .x = -player_width * 0.5, .y = -player_height - camera_offset_y, .z = -player_length * 0.5 });
        shiftBoundingBox(&player_bounding_box, player_position);

        if (asdf(&world, rl.Vector3{ .x = player_velocity.y, .y = 0, .z = 0 }, player_bounding_box)) {
            player_velocity.y = 0;
        }
        if (asdf(&world, rl.Vector3{ .x = 0, .y = player_velocity.z, .z = 0 }, player_bounding_box)) {
            player_velocity.z = 0;
        }
        if (asdf(&world, rl.Vector3{ .x = 0, .y = 0, .z = player_velocity.x }, player_bounding_box)) {
            player_velocity.x = 0;
        }

        rotateCamera(&camera, rl.Vector3{ .x = rl.GetMouseDelta().x * mouse_sens, .y = rl.GetMouseDelta().y * mouse_sens, .z = 0 });
        movePlayerAndCamera(&player_position, &camera, player_velocity);

        if (asdf(&world, rl.Vector3{ .x = 0, .y = 0, .z = 0 }, player_bounding_box)) unreachable;

        const player_chunk_coords = Vector3(i32){
            .x = @floatToInt(i32, @divFloor(player_position.x, @intToFloat(f32, Chunk.dim.x))),
            .y = @floatToInt(i32, @divFloor(player_position.y, @intToFloat(f32, Chunk.dim.y))),
            .z = @floatToInt(i32, @divFloor(player_position.z, @intToFloat(f32, Chunk.dim.z))),
        };

        const last_player_position = rl.Vector3Add(last_camera_position, rl.Vector3{ .x = 0, .y = -player_height - camera_offset_y, .z = 0 });
        const last_player_chunk_coords = Vector3(i32){
            .x = @floatToInt(i32, @divFloor(last_player_position.x, @intToFloat(f32, Chunk.dim.x))),
            .y = @floatToInt(i32, @divFloor(last_player_position.y, @intToFloat(f32, Chunk.dim.y))),
            .z = @floatToInt(i32, @divFloor(last_player_position.z, @intToFloat(f32, Chunk.dim.z))),
        };
        if (!last_player_chunk_coords.equals(player_chunk_coords)) {
            try world.loadChunks(player_position);
            mesher.updateChunkMeshesSpatially(&mesh_pool, &chunk_meshes, &world, &atlas);
        }

        last_camera_position = camera.position;

        // Update uniform shader values.
        const camera_position = [3]f32{ camera.position.x, camera.position.y, camera.position.z };
        const camera_target = [3]f32{ camera.target.x, camera.target.y, camera.target.z };
        light_source.position = camera_position;
        light_source.target = camera_target;
        updateLightValues(shader, &light_source);
        rl.SetShaderValue(shader, shader.locs[rl.SHADER_LOC_VECTOR_VIEW], &camera_position, rl.SHADER_UNIFORM_VEC3);

        var collision_chunk_index: usize = undefined;
        const crosshair_ray = rl.Ray{ .position = camera.position, .direction = rl.GetCameraForward(&camera) };
        var crosshair_ray_collision: rl.RayCollision = undefined;
        crosshair_ray_collision.hit = false;
        crosshair_ray_collision.distance = crosshair_block_range + 1;
        for (chunk_meshes, 0..) |chunk_mesh, chunk_mesh_index| {
            const this_chunk_collision = rl.GetRayCollisionMesh(crosshair_ray, chunk_mesh.mesh, rl.MatrixIdentity());
            if (this_chunk_collision.hit and this_chunk_collision.distance < crosshair_ray_collision.distance) {
                crosshair_ray_collision = this_chunk_collision;
                collision_chunk_index = chunk_mesh_index; // TODO(caleb): collision_mesh_index?
            }
        }
        const look_direction = lookDirection(crosshair_ray.direction);

        var target_block: block_caster.BlockHit = undefined;
        if (crosshair_ray_collision.hit and crosshair_ray_collision.distance < crosshair_block_range) {
            const loaded_chunk_index = world.chunkIndexFromCoords(chunk_meshes[collision_chunk_index].coords) orelse unreachable;
            target_block = block_caster.blockHitFromPoint(world.loaded_chunks[loaded_chunk_index], crosshair_ray_collision.point);

            if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) { // Break block
                world.loaded_chunks[loaded_chunk_index].put(0, target_block.coords.x, target_block.coords.y, target_block.coords.z);
                chunk_meshes[collision_chunk_index].updated_block_pos = target_block.coords;
                mesher.updateChunkMeshes(&mesh_pool, &chunk_meshes, collision_chunk_index, &world, &atlas);
            } else if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_RIGHT)) { // Place block
                var d_target_block_coords = rl.Vector3Zero();
                switch (target_block.face) {
                    .top => d_target_block_coords = rl.Vector3{ .x = 0, .y = 1, .z = 0 },
                    .bottom => d_target_block_coords = rl.Vector3{ .x = 0, .y = -1, .z = 0 },
                    .left => d_target_block_coords = rl.Vector3{ .x = -1, .y = 0, .z = 0 },
                    .right => d_target_block_coords = rl.Vector3{ .x = 1, .y = 0, .z = 0 },
                    .near => d_target_block_coords = rl.Vector3{ .x = 0, .y = 0, .z = 1 },
                    .far => d_target_block_coords = rl.Vector3{ .x = 0, .y = 0, .z = -1 },
                }

                var chunk_coords = Vector3(i32){
                    .x = @divFloor(@intCast(i32, target_block.coords.x) + @floatToInt(i32, d_target_block_coords.x), Chunk.dim.x),
                    .y = @divFloor(@intCast(i32, target_block.coords.y) + @floatToInt(i32, d_target_block_coords.y), Chunk.dim.y),
                    .z = @divFloor(@intCast(i32, target_block.coords.z) + @floatToInt(i32, d_target_block_coords.z), Chunk.dim.z),
                };
                chunk_coords = Vector3(i32).add(world.loaded_chunks[loaded_chunk_index].coords, chunk_coords);
                const border_or_same_chunk_index = world.chunkIndexFromCoords(chunk_coords) orelse unreachable; // NOTE(caleb): This chunk hasn't been loaded but should be if it's a border chunk.

                const wrapped_x: Chunk.u_dimx = if (d_target_block_coords.x >= 0) @intCast(Chunk.u_dimx, target_block.coords.x) +% @floatToInt(Chunk.u_dimx, d_target_block_coords.x) else @intCast(Chunk.u_dimx, target_block.coords.x) -% 1;
                const wrapped_y: Chunk.u_dimy = if (d_target_block_coords.y >= 0) @intCast(Chunk.u_dimy, target_block.coords.y) +% @floatToInt(Chunk.u_dimy, d_target_block_coords.y) else @intCast(Chunk.u_dimy, target_block.coords.y) -% 1;
                const wrapped_z: Chunk.u_dimz = if (d_target_block_coords.z >= 0) @intCast(Chunk.u_dimz, target_block.coords.z) +% @floatToInt(Chunk.u_dimz, d_target_block_coords.z) else @intCast(Chunk.u_dimz, target_block.coords.z) -% 1;

                world.loaded_chunks[border_or_same_chunk_index].put(
                    held_block_id,
                    @intCast(u8, wrapped_x),
                    @intCast(u8, wrapped_y),
                    @intCast(u8, wrapped_z),
                );

                var mesh_index: usize = 0;
                for (chunk_meshes) |mesh| {
                    if (mesh.coords.equals(world.loaded_chunks[border_or_same_chunk_index].coords)) break;
                    mesh_index += 1;
                }

                chunk_meshes[mesh_index].updated_block_pos = Vector3(u8){ .x = @intCast(u8, wrapped_x), .y = @intCast(u8, wrapped_y), .z = @intCast(u8, wrapped_z) };
                mesher.updateChunkMeshes(&mesh_pool, &chunk_meshes, mesh_index, &world, &atlas);
            }
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.BeginMode3D(camera);

        // const frustum = Frustum.extractFrustum(&camera, aspect);
        // var chunk_box = AABB{ .min = rl.Vector3Zero(), .max = rl.Vector3Add(rl.Vector3Zero(), rl.Vector3{ .x = @intToFloat(f32, Chunk.dim.x), .y = @intToFloat(f32, Chunk.dim.x), .z = @intToFloat(f32, Chunk.dim.x) }) };

        // var should_draw_chunk = false;
        // if (frustum.containsAABB(&chunk_box)) { // FIXME(caleb): This is still borked...
        //     should_draw_chunk = true;
        // }

        // Only draw this mesh if it's within the view frustum
        for (chunk_meshes) |chunk_mesh|
            rl.DrawMesh(chunk_mesh.mesh, default_material, rl.MatrixIdentity());

        rl.EndMode3D();

        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = -crosshair_length_in_pixels, .y = 0 }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = crosshair_length_in_pixels, .y = 0 }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = 0, .y = -crosshair_length_in_pixels }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = 0, .y = crosshair_length_in_pixels }), crosshair_thickness_in_pixels, rl.WHITE);

        if (editing_command_buffer) {
            const tbox_rect = rgui.Rectangle{ .x = 0, .y = screen_dim.y - 25, .width = screen_dim.x / 3, .height = 25 };
            if (rgui.GuiTextBox(tbox_rect, empty_str, command_buffer.len, editing_command_buffer) == 1) {
                const bytes_written = std.zig.c_builtins.__builtin_strlen(&command_buffer);
                held_block_id = atlas.name_to_id.get(hashString(command_buffer[1..bytes_written])) orelse held_block_id;
                for (0..bytes_written) |byte_index| command_buffer[byte_index] = 0;
                editing_command_buffer = false;
                rgui.GuiDisable();
            }
        }

        if (debug_text_info) {
            var strz_buffer: [256]u8 = undefined;
            var y_offset: f32 = 0;
            const fps_strz = try std.fmt.bufPrintZ(&strz_buffer, "FPS:{d}", .{rl.GetFPS()});
            rl.DrawTextEx(font, @ptrCast([*c]const u8, fps_strz), rl.Vector2{ .x = 0, .y = 0 }, font_size, font_spacing, rl.WHITE);
            y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, fps_strz), font_size, font_spacing).y;

            const player_pos_strz = try std.fmt.bufPrintZ(&strz_buffer, "Player position: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ player_position.x, player_position.y, player_position.z });
            rl.DrawTextEx(font, @ptrCast([*c]const u8, player_pos_strz), rl.Vector2{ .x = 0, .y = y_offset }, font_size, font_spacing, rl.WHITE);
            y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, player_pos_strz), font_size, font_spacing).y;

            const player_chunk_strz = try std.fmt.bufPrintZ(&strz_buffer, "Chunk: (x:{d}, y:{d}, z:{d})", .{ player_chunk_coords.x, player_chunk_coords.y, player_chunk_coords.z });
            rl.DrawTextEx(font, @ptrCast([*c]const u8, player_chunk_strz), rl.Vector2{ .x = 0, .y = y_offset }, font_size, font_spacing, rl.WHITE);
            y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, player_chunk_strz), font_size, font_spacing).y;

            if (crosshair_ray_collision.hit and crosshair_ray_collision.distance < crosshair_block_range) {
                const target_block_point_strz = try std.fmt.bufPrintZ(&strz_buffer, "Target block: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ target_block.coords.x, target_block.coords.y, target_block.coords.z });
                rl.DrawTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), rl.Vector2{ .x = 0, .y = y_offset }, font_size, font_spacing, rl.WHITE);
                y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, target_block_point_strz), font_size, font_spacing).y;

                const target_block_face_strz = try std.fmt.bufPrintZ(&strz_buffer, "Target block face: {s}", .{@tagName(target_block.face)});
                rl.DrawTextEx(font, @ptrCast([*c]const u8, target_block_face_strz), rl.Vector2{ .x = 0, .y = y_offset }, font_size, font_spacing, rl.WHITE);
                y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, target_block_face_strz), font_size, font_spacing).y;
            } else {
                const no_target_block_strz = try std.fmt.bufPrintZ(&strz_buffer, "No target block", .{});
                rl.DrawTextEx(font, @ptrCast([*c]const u8, no_target_block_strz), rl.Vector2{ .x = 0, .y = y_offset }, font_size, font_spacing, rl.WHITE);
                y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, no_target_block_strz), font_size, font_spacing).y;
            }
            const look_direction_strz = try std.fmt.bufPrintZ(&strz_buffer, "Look direction: {s}", .{@tagName(look_direction)});
            rl.DrawTextEx(font, @ptrCast([*c]const u8, look_direction_strz), rl.Vector2{ .x = 0, .y = y_offset }, font_size, font_spacing, rl.WHITE);
            // y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, look_direction_strz), font_size, font_spacing);

        }

        rl.EndDrawing();
    }

    try world.writeCachedChunksToDisk("./data/world.sav");

    rl.CloseWindow();
}
