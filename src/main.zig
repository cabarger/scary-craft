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
const lag = @import("math/lag.zig");

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const MemoryPoolExtra = std.heap.MemoryPoolExtra;
const Vector3 = scary_types.Vector3;
const VectorOps = lag.VectorOps;
const Vector3f32Ops = VectorOps(3, f32);
const Vector3f32 = @Vector(3, f32);

// FIXME(caleb):
// Fix the renderer :( - glass

// TODO(caleb):
// @Vector - inside of source files that aren't main.
// OBJECTIVES (possibly in the form of notes that you can pick up?)
// INSERT SCARY ENEMY IDEAS HERE...
// Frustum culling ( do this when game gets slow? )
// NON JANK console

// Constants -------------------------------------------------------------------------
const meters_per_block = 1.0;

const crosshair_thickness_in_pixels = 2;
const crosshair_length_in_pixels = 20;

const camera_offset_y = meters_per_block * 0.6;
const player_width = meters_per_block * 0.1;
const player_height = meters_per_block * 1.5;
const player_length = player_width;

const gravity_y_per_second = meters_per_block * 0.2;
const jump_y_velocity = 0.07;

const target_fps = 120;
const fovy = 60.0;
const crosshair_block_range = 4;
const move_speed_blocks_per_second = 4;
const mouse_sens = 0.1;

const font_size = 20;
const font_spacing = 2;

// One off main structs -------------------------------------------------------------------------
const Player = struct {
    position: Vector3f32,
    up: Vector3f32,
    target: Vector3f32,
    in_air: bool,
};

const ShaderLight = struct {
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

const Direction = enum(u8) {
    x_pos,
    x_neg,
    y_pos,
    y_neg,
    z_pos,
    z_neg,
};

const normalized_vector_set = [_]Vector3f32{
    Vector3f32{ 1, 0, 0 }, // X pos
    Vector3f32{ -1, 0, 0 }, // X neg
    Vector3f32{ 0, 1, 0 }, // Y pos
    Vector3f32{ 0, -1, 0 }, // Y neg
    Vector3f32{ 0, 0, 1 }, // Z pos
    Vector3f32{ 0, 0, -1 }, // Z neg
};

/// Update's position and target on z axis by distance.
fn moveForward(position: *Vector3f32, target: *Vector3f32, distance: f32, move_in_world_plane: bool) void {
    var forward = Vector3f32Ops.forward(position.*, target.*);
    if (move_in_world_plane) {
        forward[1] = 0;
        forward = Vector3f32Ops.normalize(forward);
    }

    // Scale by distance
    forward = Vector3f32Ops.scale(forward, distance);

    // Move position and target
    position.* += forward;
    target.* += forward;
}

/// Update's position and target on x axis by distance.
fn moveRight(position: *Vector3f32, target: *Vector3f32, up: Vector3f32, distance: f32, move_in_world_plane: bool) void {
    var right = Vector3f32Ops.right(position.*, target.*, up);
    if (move_in_world_plane) {
        right[1] = 0;
        right = Vector3f32Ops.normalize(right);
    }

    // Scale by distance
    right = Vector3f32Ops.scale(right, distance);

    // Move position and target
    position.* += right;
    target.* += right;
}

/// Update's position and target on y axis by distance.
fn moveUp(position: *Vector3f32, target: *Vector3f32, up: Vector3f32, distance: f32) void {
    // Scale by distance
    var scaled_up = Vector3f32Ops.scale(Vector3f32Ops.normalize(up), distance);

    // Move position and target
    position.* += scaled_up;
    target.* += scaled_up;
}

/// Rotates around right vector, "looking up and down"
///  - lockView prevents camera overrotation (aka "somersaults")
///  - rotateAroundTarget defines if rotation is around target or around its position
///  - rotateUp rotates the up direction as well (typically only usefull in CAMERA_FREE)
/// NOTE: angle must be provided in radians
/// NOTE(caleb): This is modified version of raylib's camera pitch rotation function.
fn rotateX(position: *Vector3f32, target: *Vector3f32, up: *Vector3f32, angle_: f32, lock_view: bool, rotate_around_target: bool, rotate_up: bool) void {
    var angle = angle_;

    // Up direction
    const norm_up = Vector3f32Ops.normalize(up.*);

    // View vector
    var target_position = target.* - position.*;

    if (lock_view) {
        // In these camera modes we clamp the Pitch angle
        // to allow only viewing straight up or down.

        // Clamp view up
        var max_angle_up = Vector3f32Ops.angle(norm_up, target_position);
        max_angle_up -= 0.001; // avoid numerical errors
        if (angle > max_angle_up) angle = max_angle_up;

        // Clamp view down
        var max_angle_down = Vector3f32Ops.angle(-norm_up, target_position);
        max_angle_down *= -1.0; // downwards angle is negative
        max_angle_down += 0.001; // avoid numerical errors
        if (angle < max_angle_down) angle = max_angle_down;
    }

    // Rotation axis
    const right = Vector3f32Ops.right(target.*, position.*, norm_up);

    // Rotate view vector around right axis
    target_position = Vector3f32Ops.rotateByAxisAngle(target_position, right, angle);

    if (rotate_around_target) {
        // Move position relative to target
        position.* = target.* - target_position;
    } else { // rotate around camera.position
        // Move target relative to position
        target.* = position.* + target_position;
    }

    if (rotate_up) // Rotate up direction around right axis
        up.* = Vector3f32Ops.rotateByAxisAngle(norm_up, right, angle);
}

/// Rotates around up vector "looking left and right"
/// If rotateAroundTarget is false, then rotates around its position
/// Note: angle must be provided in radians
/// NOTE(caleb): This is modified version of raylib's camera yaw rotation function.
fn rotateY(position: *Vector3f32, target: *Vector3f32, up_: Vector3f32, angle: f32, rotate_around_target: bool) void {
    const up = Vector3f32Ops.normalize(up_);

    var target_position = target.* - position.*;
    target_position = Vector3f32Ops.rotateByAxisAngle(target_position, up, angle);

    if (rotate_around_target) {
        position.* = target.* - target_position;
    } else {
        target.* = position.* + target_position;
    }
}

/// Rotates the camera by rotation amount x,y given in deg
fn rotateCamera(camera: *rl.Camera, rotation: rl.Vector3, rotate_around_target: bool) void {
    rl.CameraPitch(
        camera,
        -rotation.y * rl.DEG2RAD,
        true, // Lock view
        rotate_around_target,
        false, // Rotate up
    );
    rl.CameraYaw(
        camera,
        -rotation.x * rl.DEG2RAD,
        rotate_around_target,
    );
    // rl.CameraRoll(camera, rotation.z * rl.DEG2RAD);
}

fn updatePositionAndTargetRl(position: *rl.Vector3, target: *rl.Vector3, up: rl.Vector3, movement: Vector3f32) void {
    var builtin_position = @bitCast(Vector3f32, position.*);
    var builtin_target = @bitCast(Vector3f32, target.*);
    updatePositionAndTarget(&builtin_position, &builtin_target, @bitCast(Vector3f32, up), movement);
    position.* = @bitCast(rl.Vector3, builtin_position);
    target.* = @bitCast(rl.Vector3, builtin_target);
}

fn updatePositionAndTarget(position: *Vector3f32, target: *Vector3f32, up: Vector3f32, movment: Vector3f32) void {
    const move_in_world_space = true;
    moveRight(position, target, up, movment[0], move_in_world_space);
    moveUp(position, target, up, movment[1]);
    moveForward(position, target, movment[2], move_in_world_space);
}

/// Updates bounding box positions to point p
fn playerBoundingBox(p: Vector3f32) rl.BoundingBox {
    var bb: rl.BoundingBox = undefined;
    bb.min.x = p[0] - player_width * 0.5;
    bb.min.y = p[1] - player_height * 0.5;
    bb.min.z = p[2] - player_length * 0.5;
    bb.max.x = bb.min.x + player_width;
    bb.max.y = bb.min.y + player_height;
    bb.max.z = bb.min.z + player_length;
    return bb;
}

fn updateShaderLightValues(shader: rl.Shader, light: *ShaderLight) void {

    // Send to shader light enabled state and type
    rl.SetShaderValue(shader, light.enabled_loc, &light.enabled, rl.SHADER_UNIFORM_INT);
    rl.SetShaderValue(shader, light.type_loc, &light.type, rl.SHADER_UNIFORM_INT);

    // Send to shader light position, target, and color values
    rl.SetShaderValue(shader, light.position_loc, &light.position, rl.SHADER_UNIFORM_VEC3);
    rl.SetShaderValue(shader, light.target_loc, &light.target, rl.SHADER_UNIFORM_VEC3);
    rl.SetShaderValue(shader, light.color_loc, &light.color, rl.SHADER_UNIFORM_VEC4);
}

/// Given a direction vector return the index of the closest vector within normalized_vector_set.
fn lookDirection(direction: Vector3f32) Direction {
    var look_direction: Direction = undefined;
    var closest_look_dot: f32 = undefined;
    var vector_set_index: u8 = 0;
    while (vector_set_index < normalized_vector_set.len) : (vector_set_index += 1) {
        const dot = Vector3f32Ops.dot(direction, normalized_vector_set[vector_set_index]);
        if (vector_set_index == 0 or dot > closest_look_dot) {
            look_direction = @intToEnum(Direction, vector_set_index);
            closest_look_dot = dot;
        }
    }
    return look_direction;
}

fn playerWouldCollideWithBlock(world: *World, velocity_: Vector3f32, player: *Player) bool {
    const velocity = @bitCast(rl.Vector3, velocity_);

    var right = Vector3f32Ops.right(player.position, player.target, player.up);
    right[1] = 0;
    right = Vector3f32Ops.scale(Vector3f32Ops.normalize(right), velocity.x);

    const up = Vector3f32Ops.scale(Vector3f32Ops.normalize(player.up), velocity.y);

    var forward = Vector3f32Ops.forward(player.position, player.target);
    forward[1] = 0;
    forward = Vector3f32Ops.scale(Vector3f32Ops.normalize(forward), velocity.z);

    var next_player_position = player.position;
    next_player_position += right;
    next_player_position += up;
    next_player_position += forward;

    const aabb = playerBoundingBox(next_player_position);
    var world_block_min = World.worldf32ToWorldi32(aabb.min);
    const world_block_max = World.worldf32ToWorldi32(aabb.max);

    var world_block_pos: @Vector(3, i32) = undefined;
    world_block_pos[2] = world_block_min.z;
    while (world_block_pos[2] <= world_block_max.z) : (world_block_pos[2] += 1) {
        world_block_pos[1] = world_block_min.y;
        while (world_block_pos[1] <= world_block_max.y) : (world_block_pos[1] += 1) {
            world_block_pos[0] = world_block_min.x;
            while (world_block_pos[0] <= world_block_max.x) : (world_block_pos[0] += 1) {
                const chunk_coords = World.worldi32ToChunki32(Vector3(i32){ .x = world_block_pos[0], .y = world_block_pos[1], .z = world_block_pos[2] });
                const chunk_index = world.chunkIndexFromCoords(chunk_coords) orelse continue;
                const chunk_rel_pos = World.worldi32ToRel(Vector3(i32){ .x = world_block_pos[0], .y = world_block_pos[1], .z = world_block_pos[2] });

                if ((world.loaded_chunks[chunk_index].fetch(chunk_rel_pos.x, chunk_rel_pos.y, chunk_rel_pos.z) orelse unreachable) != 0)
                    return true;
            }
        }
    }
    return false;
}

pub fn main() !void {
    // Rayib init -------------------------------------------------------------------------
    const screen_width: c_int = 1920;
    const screen_height: c_int = 1080;
    rl.InitWindow(screen_width, screen_height, "Scary Craft :o");
    rl.SetConfigFlags(rl.FLAG_MSAA_4X_HINT);
    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(target_fps);
    rl.DisableCursor();

    const font = rl.LoadFont("data/FiraCode-Medium.ttf");

    // Arena init -------------------------------------------------------------------------
    var back_buffer = try std.heap.page_allocator.alloc(u8, 1024 * 1024 * 5); // 5mb
    var fb_instance = std.heap.FixedBufferAllocator.init(back_buffer);
    var arena_instance = std.heap.ArenaAllocator.init(fb_instance.allocator());
    var arena = arena_instance.allocator();

    // Load texture atlas
    var atlas = Atlas.init(arena);
    try atlas.load("data/atlas.png", "data/atlas_data.json");

    // Lighting shader init -------------------------------------------------------------------------
    var shader: rl.Shader = rl.LoadShader(rl.TextFormat("data/shaders/lighting.vs", @intCast(c_int, 330)), rl.TextFormat("data/shaders/lighting.fs", @intCast(c_int, 330)));
    shader.locs[rl.SHADER_LOC_VECTOR_VIEW] = rl.GetShaderLocation(shader, "viewPos");

    const ambient_loc = rl.GetShaderLocation(shader, "ambient");
    rl.SetShaderValue(shader, ambient_loc, &[_]f32{ 0.01, 0.01, 0.01, 1.0 }, rl.SHADER_UNIFORM_VEC4);

    var light_source: ShaderLight = undefined;
    light_source.enabled_loc = rl.GetShaderLocation(shader, "light.enabled");
    light_source.type_loc = rl.GetShaderLocation(shader, "light.type");
    light_source.position_loc = rl.GetShaderLocation(shader, "light.position");
    light_source.target_loc = rl.GetShaderLocation(shader, "light.target");
    light_source.color_loc = rl.GetShaderLocation(shader, "light.color");
    light_source.color = @Vector(4, f32){ 1, 1, 1, 1 };

    var default_material = rl.LoadMaterialDefault();
    default_material.shader = shader;
    rl.SetMaterialTexture(&default_material, rl.MATERIAL_MAP_DIFFUSE, atlas.texture);

    // Game vars -------------------------------------------------------------------------
    var debug_axes = false;
    var debug_text_info = false;
    var debug_draw_chunk_borders = false;

    var player = Player{
        .position = Vector3f32{ 8.0, 8.0, 8.0 },
        .up = Vector3f32{ 0.0, 1.0, 0.0 },
        .target = Vector3f32{ 8.0, 8.0, 7.0 },
        .in_air = false,
    };

    var god_mode = false; // Toggles player flight
    var camera_in_first_person = true;

    var camera: rl.Camera = undefined;
    camera.position = @bitCast(rl.Vector3, player.position + Vector3f32{ 0.0, camera_offset_y, 0.0 });
    camera.target = @bitCast(rl.Vector3, player.target);
    camera.up = @bitCast(rl.Vector3, player.up);
    camera.fovy = fovy;
    camera.projection = rl.CAMERA_PERSPECTIVE;

    var last_player_position = player.position;
    var player_velocity = Vector3f32{ 0, 0, 0 };

    var command_buffer: [128]u8 = undefined;
    var editing_command_buffer = false;
    var empty_str = try std.fmt.bufPrintZ(&command_buffer, "", .{});
    var held_block_id = atlas.nameToId("default_grass") orelse unreachable;

    // Initial chunk loading -------------------------------------------------------------------------
    try World.writeDummySave("data/world.sav", &atlas);
    var world = World.init(arena);
    try world.loadSave("data/world.sav");
    try world.loadChunks(camera.position);

    var mesh_pool = try MemoryPoolExtra([mesher.mem_per_chunk]u8, .{ .alignment = null, .growable = false }).initPreheated(arena, World.loaded_chunk_capacity);
    var chunk_meshes: [World.loaded_chunk_capacity]mesher.ChunkMesh = undefined;
    for (&chunk_meshes, 0..) |*chunk_mesh, chunk_index| {
        chunk_mesh.* = mesher.cullMesh(&mesh_pool, @intCast(u8, chunk_index), &world, &atlas) catch unreachable;
        rl.UploadMesh(&chunk_mesh.mesh, false);
    }

    while (!rl.WindowShouldClose()) { // Game loop
        // Update -------------------------------------------------------------------------
        const screen_dim = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()), .y = @intToFloat(f32, rl.GetScreenHeight()) };
        const screen_mid = rl.Vector2Scale(screen_dim, 0.5);
        const aspect = screen_dim.x / screen_dim.y;
        _ = aspect;
        const delta_time_ms = rl.GetFrameTime() * 1000;
        _ = delta_time_ms;

        if (rl.IsKeyPressed(rl.KEY_F1)) {
            debug_axes = !debug_axes;
            debug_text_info = !debug_text_info;
            debug_draw_chunk_borders = !debug_draw_chunk_borders;
        }

        if (rl.IsKeyPressed(rl.KEY_F2)) { // toggle god mode
            god_mode = !god_mode;
        }

        if (rl.IsKeyPressed(rl.KEY_F5)) {
            if (camera_in_first_person) { // Switching to third person
                camera.position = @bitCast(rl.Vector3, player.position + player.up * @splat(3, @as(f32, 5.0)) - Vector3f32Ops.forward(player.position, player.target) * @splat(3, @as(f32, 5.0)));
                camera.target = @bitCast(rl.Vector3, player.position);
            } else {
                camera.position = @bitCast(rl.Vector3, player.position + Vector3f32{ 0.0, camera_offset_y, 0.0 });
                camera.target = @bitCast(rl.Vector3, player.target);
            }
            camera_in_first_person = !camera_in_first_person;
        }

        var speed_scalar: f32 = 1;
        if (rl.IsKeyDown(rl.KEY_LEFT_SHIFT)) {
            speed_scalar = 2;
        }

        var player_velocity_this_frame = Vector3f32{ 0, 0, 0 };
        if (rl.IsKeyDown(rl.KEY_W)) player_velocity_this_frame += Vector3f32{ 0, 0, move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime() };
        if (rl.IsKeyDown(rl.KEY_S)) player_velocity_this_frame -= Vector3f32{ 0, 0, move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime() };
        if (rl.IsKeyDown(rl.KEY_A)) player_velocity_this_frame -= Vector3f32{ move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime(), 0, 0 };
        if (rl.IsKeyDown(rl.KEY_D)) player_velocity_this_frame += Vector3f32{ move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime(), 0, 0 };
        if (rl.IsKeyDown(rl.KEY_SPACE) and !player.in_air) {
            player_velocity[1] = jump_y_velocity;
        } else if (rl.IsKeyDown(rl.KEY_SPACE) and player.in_air and god_mode) {
            player_velocity_this_frame += Vector3f32{ 0, move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime(), 0 };
        }
        if (rl.IsKeyDown(rl.KEY_LEFT_CONTROL)) player_velocity_this_frame -= Vector3f32{ 0, move_speed_blocks_per_second * (1 / meters_per_block) * speed_scalar * rl.GetFrameTime(), 0 };
        if (rl.IsKeyPressed(rl.KEY_SLASH)) {
            editing_command_buffer = true; //TODO(caleb): Fix this jankness
            rgui.GuiEnable();
        }
        if (!god_mode) {
            player_velocity -= Vector3f32{ 0, gravity_y_per_second * rl.GetFrameTime(), 0 }; // TODO(caleb): Terminal velocity
        } else { // Remove any y velocity from previous frames.
            player_velocity[1] = 0;
        }

        if (playerWouldCollideWithBlock(&world, (player_velocity + player_velocity_this_frame) * Vector3f32{ 1, 0, 0 }, &player)) {
            player_velocity *= Vector3f32{ 0, 1, 1 };
            player_velocity_this_frame *= Vector3f32{ 0, 1, 1 };
        }
        if (playerWouldCollideWithBlock(&world, (player_velocity + player_velocity_this_frame) * Vector3f32{ 0, 1, 0 }, &player)) {
            player_velocity *= Vector3f32{ 1, 0, 1 };
            player_velocity_this_frame *= Vector3f32{ 1, 0, 1 };
            player.in_air = false;
        } else { // If the player isn't touching the ground they must be in the air.
            player.in_air = true;
        }
        if (playerWouldCollideWithBlock(&world, (player_velocity + player_velocity_this_frame) * Vector3f32{ 0, 0, 1 }, &player)) {
            player_velocity *= Vector3f32{ 1, 1, 0 };
            player_velocity_this_frame *= Vector3f32{ 1, 1, 0 };
        }

        rotateCamera(&camera, rl.Vector3{ .x = rl.GetMouseDelta().x * mouse_sens, .y = rl.GetMouseDelta().y * mouse_sens, .z = 0 }, !camera_in_first_person);
        updatePositionAndTargetRl(&camera.position, &camera.target, camera.up, player_velocity + player_velocity_this_frame);

        if (camera_in_first_person) {
            player.target = @bitCast(Vector3f32, camera.target);
        } else {
            rotateX(&player.position, &player.target, &player.up, rl.GetMouseDelta().y * mouse_sens * rl.DEG2RAD, true, false, false);
            rotateY(&player.position, &player.target, player.up, -rl.GetMouseDelta().x * mouse_sens * rl.DEG2RAD, false);
        }
        updatePositionAndTarget(&player.position, &player.target, player.up, player_velocity + player_velocity_this_frame);

        if (playerWouldCollideWithBlock(&world, Vector3f32{ 0, 0, 0 }, &player)) unreachable;

        const player_chunk_coords = @Vector(3, i32){
            @floatToInt(i32, @divFloor(player.position[0], @intToFloat(f32, Chunk.dim.x))),
            @floatToInt(i32, @divFloor(player.position[1], @intToFloat(f32, Chunk.dim.y))),
            @floatToInt(i32, @divFloor(player.position[2], @intToFloat(f32, Chunk.dim.z))),
        };

        const last_player_chunk_coords = @Vector(3, i32){
            @floatToInt(i32, @divFloor(last_player_position[0], @intToFloat(f32, Chunk.dim.x))),
            @floatToInt(i32, @divFloor(last_player_position[1], @intToFloat(f32, Chunk.dim.y))),
            @floatToInt(i32, @divFloor(last_player_position[2], @intToFloat(f32, Chunk.dim.z))),
        };
        if (@reduce(.Or, last_player_chunk_coords != player_chunk_coords)) {
            try world.loadChunks(@bitCast(rl.Vector3, player.position));
            mesher.updateChunkMeshesSpatially(&mesh_pool, &chunk_meshes, &world, &atlas);
        }
        last_player_position = player.position;

        // Update uniform shader values.
        light_source.position = player.position;
        light_source.target = player.target;
        updateShaderLightValues(shader, &light_source);
        rl.SetShaderValue(shader, shader.locs[rl.SHADER_LOC_VECTOR_VIEW], &player.position, rl.SHADER_UNIFORM_VEC3);

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
        const look_direction = lookDirection(@bitCast(Vector3f32, crosshair_ray.direction));

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

                // Place block in world
                world.loaded_chunks[border_or_same_chunk_index].put(
                    held_block_id,
                    @intCast(u8, wrapped_x),
                    @intCast(u8, wrapped_y),
                    @intCast(u8, wrapped_z),
                );

                // If player is trying to place block inside of own hitbox don't place the block.
                if (playerWouldCollideWithBlock(&world, Vector3f32{ 0, 0, 0 }, &player)) {
                    world.loaded_chunks[border_or_same_chunk_index].put(
                        0,
                        @intCast(u8, wrapped_x),
                        @intCast(u8, wrapped_y),
                        @intCast(u8, wrapped_z),
                    );
                } else { // Update mesh since this block isn't inside the player.
                    var mesh_index: usize = 0;
                    for (chunk_meshes) |mesh| {
                        if (mesh.coords.equals(world.loaded_chunks[border_or_same_chunk_index].coords)) break;
                        mesh_index += 1;
                    }

                    chunk_meshes[mesh_index].updated_block_pos = Vector3(u8){ .x = @intCast(u8, wrapped_x), .y = @intCast(u8, wrapped_y), .z = @intCast(u8, wrapped_z) };
                    mesher.updateChunkMeshes(&mesh_pool, &chunk_meshes, mesh_index, &world, &atlas);
                }
            }
        }

        // Drawing happens here  -------------------------------------------------------------------------
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
        for (chunk_meshes) |chunk_mesh| {
            rl.DrawMesh(chunk_mesh.mesh, default_material, rl.MatrixIdentity());

            if (debug_draw_chunk_borders) {
                const chunk_bounding_box = rl.BoundingBox{ .min = rl.Vector3{
                    .x = @intToFloat(f32, chunk_mesh.coords.x * Chunk.dim.x),
                    .y = @intToFloat(f32, chunk_mesh.coords.y * Chunk.dim.y),
                    .z = @intToFloat(f32, chunk_mesh.coords.z * Chunk.dim.z),
                }, .max = rl.Vector3{
                    .x = @intToFloat(f32, chunk_mesh.coords.x * Chunk.dim.x + Chunk.dim.x),
                    .y = @intToFloat(f32, chunk_mesh.coords.y * Chunk.dim.y + Chunk.dim.y),
                    .z = @intToFloat(f32, chunk_mesh.coords.z * Chunk.dim.z + Chunk.dim.z),
                } };
                rl.DrawBoundingBox(chunk_bounding_box, rl.GREEN);
            }
        }

        if (!camera_in_first_person) {
            rl.DrawBoundingBox(playerBoundingBox(player.position), rl.GREEN);
            rl.DrawSphere(@bitCast(rl.Vector3, player.position + Vector3f32{ 0.0, camera_offset_y, 0.0 }), 0.03, rl.RED);
            rl.DrawLine3D(@bitCast(rl.Vector3, player.position), @bitCast(rl.Vector3, player.position + Vector3f32Ops.forward(player.position, player.target)), rl.RED);
        }
        rl.EndMode3D();

        // Draw crosshair
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = -crosshair_length_in_pixels, .y = 0 }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = crosshair_length_in_pixels, .y = 0 }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = 0, .y = -crosshair_length_in_pixels }), crosshair_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = 0, .y = crosshair_length_in_pixels }), crosshair_thickness_in_pixels, rl.WHITE);

        // Draw command text box
        if (editing_command_buffer) {
            const tbox_rect = rgui.Rectangle{ .x = 0, .y = screen_dim.y - 25, .width = screen_dim.x / 3, .height = 25 };
            if (rgui.GuiTextBox(tbox_rect, empty_str, command_buffer.len, editing_command_buffer) == 1) {
                const bytes_written = std.zig.c_builtins.__builtin_strlen(&command_buffer);
                held_block_id = atlas.nameToId(command_buffer[1..bytes_written]) orelse held_block_id;
                for (0..bytes_written) |byte_index| command_buffer[byte_index] = 0;
                editing_command_buffer = false;
                rgui.GuiDisable();
            }
        }

        // Overlay a bunch of useful debugging info
        if (debug_text_info) {
            var strz_buffer: [256]u8 = undefined;
            var y_offset: f32 = 0;
            const fps_strz = try std.fmt.bufPrintZ(&strz_buffer, "FPS:{d}", .{rl.GetFPS()});
            rl.DrawTextEx(font, @ptrCast([*c]const u8, fps_strz), rl.Vector2{ .x = 0, .y = 0 }, font_size, font_spacing, rl.WHITE);
            y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, fps_strz), font_size, font_spacing).y;

            const player_pos_strz = try std.fmt.bufPrintZ(&strz_buffer, "Player position: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ player.position[0], player.position[1], player.position[2] });
            rl.DrawTextEx(font, @ptrCast([*c]const u8, player_pos_strz), rl.Vector2{ .x = 0, .y = y_offset }, font_size, font_spacing, rl.WHITE);
            y_offset += rl.MeasureTextEx(font, @ptrCast([*c]const u8, player_pos_strz), font_size, font_spacing).y;

            const player_chunk_strz = try std.fmt.bufPrintZ(&strz_buffer, "Chunk: (x:{d}, y:{d}, z:{d})", .{ player_chunk_coords[0], player_chunk_coords[1], player_chunk_coords[2] });
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

    try world.writeCachedChunksToDisk("./data/world.sav"); // Save the world
    rl.CloseWindow();
}
