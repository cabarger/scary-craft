const std = @import("std");
const rl = @import("raylib.zig");
const rlgl = rl.rlgl;

// TODO(caleb):
// -----------------------------------------------------------------------------------
// Function which maps cursor in middle of screen to a block
// Lighting see learnopengl tutorial
// Build a toy map in a voxel editor and import it
// Player collision volume
// Gravity/Jump

// OBJECTIVES (possibly in the form of notes that you can pick up?)
// INSERT SCARY ENEMY IDEAS HERE...

const block_length = 1;
const block_width = 1;
const block_height = 1;
const chunk_dim = 16;

const cursor_thickness_in_pixels = 2;
const cursor_length_in_pixels = 30;

const target_range_in_blocks = 4;
const move_speed = 0.05;
const mouse_sens = 0.05;

const font_size = 30;
const font_spacing = 2;

inline fn worldToBlock(x: f32, y: f32, z: f32) rl.Vector3 {
    return rl.Vector3{ .x = @floor(x - block_width / 2), .y = @floor(y - block_height / 2), .z = @floor(z - block_length / 2) };
}

inline fn blockToWorld(x: f32, y: f32, z: f32) rl.Vector3 {
    return rl.Vector3{ .x = x + block_width / 2, .y = y + block_height / 2, .z = z + block_length / 2 };
}

pub fn main() !void {
    const screen_width: c_int = 1600;
    const screen_height: c_int = 900;

    rl.InitWindow(screen_width, screen_height, "Scary Craft");
    rl.SetTargetFPS(60);
    rl.DisableCursor();

    const font = rl.LoadFont("data/FiraCode-Medium.ttf");
    var grass_texture = rl.LoadTexture("data/textures/default_desert_sand.png");
    var dirt_texture = rl.LoadTexture("data/textures/default_dirt.png");

    var debug_axes = false;
    var debug_text_info = false;

    var camera: rl.Camera = undefined;
    camera.position = rl.Vector3{ .x = 0.0, .y = 10.0, .z = 10.0 };
    camera.target = rl.Vector3{ .x = 0.0, .y = 0.0, .z = -1.0 };
    camera.up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 60.0;
    camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;

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
            camera_move.x += move_speed * speed_scalar;
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_S)) {
            camera_move.x -= move_speed * speed_scalar;
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_A)) {
            camera_move.y -= move_speed * speed_scalar;
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_D)) {
            camera_move.y += move_speed * speed_scalar;
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE)) {
            camera_move.z += move_speed * speed_scalar;
        }
        if (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL)) {
            camera_move.z -= move_speed * speed_scalar;
        }

        rl.UpdateCameraPro(&camera, camera_move, rl.Vector3{ .x = rl.GetMouseDelta().x * mouse_sens, .y = rl.GetMouseDelta().y * mouse_sens, .z = 0 }, rl.GetMouseWheelMove());

        // const debug_color_axes_pos = rl.Vector3Add(camera.position, rl.Vector3Scale(rl.GetCameraForward(&camera), 0.3));
        var target_block_coords: rl.Vector3 = undefined;
        var target_block_collision: rl.RayCollision = undefined;
        const target_block_ray = rl.Ray{ .position = camera.position, .direction = rl.GetCameraForward(&camera) };
        target_block_collision.hit = false;
        {
            var block_z: i16 = -chunk_dim;
            outer: while (block_z < chunk_dim) : (block_z += 1) {
                var block_x: i16 = -chunk_dim;
                while (block_x < chunk_dim) : (block_x += 1) {
                    const block_start = blockToWorld(@intToFloat(f32, block_x), 0, @intToFloat(f32, block_z));
                    const bounding_box = rl.BoundingBox{
                        .min = block_start,
                        .max = rl.Vector3Add(block_start, rl.Vector3{ .x = block_width, .y = -block_height, .z = block_length }),
                    };
                    target_block_collision = rl.GetRayCollisionBox(target_block_ray, bounding_box);
                    if (target_block_collision.hit) { //and target_block_collision.distance < target_range_in_blocks) {
                        target_block_coords = target_block_collision.point; //rl.Vector3{ .x = @floor(target_block_collision.point.x), .y = @floor(target_block_collision.point.y), .z = @floor(target_block_collision.point.z) };
                        break :outer;
                    }
                }
            }
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.BeginMode3D(camera);

        // Draw 4 16x16 chunks
        var block_z: i16 = -chunk_dim;
        while (block_z < chunk_dim) : (block_z += 1) {
            var block_x: i16 = -chunk_dim;
            while (block_x < chunk_dim) : (block_x += 1) {
                const tint = if (target_block_collision.hit and block_z == @floatToInt(i16, target_block_coords.z) and block_x == @floatToInt(i16, target_block_coords.x)) rl.GRAY else rl.WHITE;
                DrawCubeTexture(grass_texture, dirt_texture, blockToWorld(@intToFloat(f32, block_x), 0, @intToFloat(f32, block_z)), block_width, block_height, block_length, tint);
            }
        }

        // if (debug_axes) {
        //     rl.DrawLine3D(debug_color_axes_pos, rl.Vector3Add(debug_color_axes_pos, rl.Vector3{ .x = 0.03, .y = 0, .z = 0 }), rl.RED);
        //     rl.DrawLine3D(debug_color_axes_pos, rl.Vector3Add(debug_color_axes_pos, rl.Vector3{ .x = 0, .y = 0.03, .z = 0 }), rl.GREEN);
        //     rl.DrawLine3D(debug_color_axes_pos, rl.Vector3Add(debug_color_axes_pos, rl.Vector3{ .x = 0, .y = 0, .z = 0.03 }), rl.BLUE);
        // }

        rl.EndMode3D();

        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = -cursor_length_in_pixels, .y = 0 }), cursor_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = cursor_length_in_pixels, .y = 0 }), cursor_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = 0, .y = -cursor_length_in_pixels }), cursor_thickness_in_pixels, rl.WHITE);
        rl.DrawLineEx(screen_mid, rl.Vector2Add(screen_mid, rl.Vector2{ .x = 0, .y = cursor_length_in_pixels }), cursor_thickness_in_pixels, rl.WHITE);

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
            if (target_block_collision.hit) {
                target_block_point_strz = try std.fmt.bufPrintZ(&strz_buffer, "Block target point: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ target_block_collision.point.x, target_block_collision.point.y, target_block_collision.point.z });
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
fn DrawCubeTexture(top_texture: rl.Texture2D, not_top_texture: rl.Texture2D, pos: rl.Vector3, width: f32, height: f32, length: f32, color: rl.Color) void {
    const x = pos.x;
    const y = pos.y;
    const z = pos.z;

    rlgl.Begin(@enumToInt(rlgl.DrawMode.QUADS));
    rlgl.Color4ub(color.r, color.g, color.b, color.a);

    rlgl.SetTexture(not_top_texture.id);

    // Front Face
    rlgl.Normal3f(0.0, 0.0, 1.0); // Normal Pointing Towards Viewer
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x - width / 2, y - height / 2, z + length / 2); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x + width / 2, y - height / 2, z + length / 2); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x + width / 2, y + height / 2, z + length / 2); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x - width / 2, y + height / 2, z + length / 2); // Top Left Of The Texture and Quad

    // Back Face
    rlgl.Normal3f(0.0, 0.0, -1.0); // Normal Pointing Away From Viewer
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x - width / 2, y - height / 2, z - length / 2); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x - width / 2, y + height / 2, z - length / 2); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x + width / 2, y + height / 2, z - length / 2); // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x + width / 2, y - height / 2, z - length / 2); // Bottom Left Of The Texture and Quad

    rlgl.SetTexture(top_texture.id);

    // Top Face
    rlgl.Normal3f(0.0, 1.0, 0.0); // Normal Pointing Up
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x - width / 2, y + height / 2, z - length / 2); // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x - width / 2, y + height / 2, z + length / 2); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x + width / 2, y + height / 2, z + length / 2); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x + width / 2, y + height / 2, z - length / 2); // Top Right Of The Texture and Quad

    rlgl.SetTexture(not_top_texture.id);

    // Bottom Face
    rlgl.Normal3f(0.0, -1.0, 0.0); // Normal Pointing Down
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x - width / 2, y - height / 2, z - length / 2); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x + width / 2, y - height / 2, z - length / 2); // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x + width / 2, y - height / 2, z + length / 2); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x - width / 2, y - height / 2, z + length / 2); // Bottom Right Of The Texture and Quad

    // Right face
    rlgl.Normal3f(1.0, 0.0, 0.0); // Normal Pointing Right
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x + width / 2, y - height / 2, z - length / 2); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x + width / 2, y + height / 2, z - length / 2); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x + width / 2, y + height / 2, z + length / 2); // Top Left Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x + width / 2, y - height / 2, z + length / 2); // Bottom Left Of The Texture and Quad

    // Left Face
    rlgl.Normal3f(-1.0, 0.0, 0.0); // Normal Pointing Left
    rlgl.TexCoord2f(0.0, 0.0);
    rlgl.Vertex3f(x - width / 2, y - height / 2, z - length / 2); // Bottom Left Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 0.0);
    rlgl.Vertex3f(x - width / 2, y - height / 2, z + length / 2); // Bottom Right Of The Texture and Quad
    rlgl.TexCoord2f(1.0, 1.0);
    rlgl.Vertex3f(x - width / 2, y + height / 2, z + length / 2); // Top Right Of The Texture and Quad
    rlgl.TexCoord2f(0.0, 1.0);
    rlgl.Vertex3f(x - width / 2, y + height / 2, z - length / 2); // Top Left Of The Texture and Quad

    rlgl.SetTexture(0);
    rlgl.End();
}
