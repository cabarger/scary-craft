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

const move_speed = 0.05;
const mouse_sens = 0.05;

const font_size = 30;
const font_spacing = 2;

inline fn blockSpace(x: f32, y: f32, z: f32) rl.Vector3 {
    return rl.Vector3{ .x = x + 0.5, .y = y + 0.5 - 1, .z = z + 0.5 };
}

pub fn main() !void {
    const screen_width: c_int = 1600;
    const screen_height: c_int = 900;

    rl.InitWindow(screen_width, screen_height, "Scary Craft");
    rl.SetTargetFPS(60);
    rl.DisableCursor();

    const font = rl.LoadFont("data/FiraCode-Medium.ttf");
    var grass_texture = rl.LoadTexture("data/textures/default_grass.png");
    var dirt_texture = rl.LoadTexture("data/textures/default_dirt.png");

    var debug_overlay = false;

    var camera: rl.Camera = undefined;
    camera.position = rl.Vector3{ .x = 0.0, .y = 10.0, .z = 10.0 };
    camera.target = rl.Vector3{ .x = 0.0, .y = 0.0, .z = -1.0 };
    camera.up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 60.0;
    camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE;

    while (!rl.WindowShouldClose()) {
        const screen_dim = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()), .y = @intToFloat(f32, rl.GetScreenHeight()) };
        _ = screen_dim;

        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_F1)) {
            debug_overlay = !debug_overlay;
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

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        rl.BeginMode3D(camera);

        // Draw 4 16x16 chunks
        var block_z: i16 = -chunk_dim;
        while (block_z < chunk_dim) : (block_z += 1) {
            var block_x: i16 = -chunk_dim;
            while (block_x < chunk_dim) : (block_x += 1) {
                DrawCubeTexture(grass_texture, dirt_texture, blockSpace(@intToFloat(f32, block_x), 0, @intToFloat(f32, block_z)), block_width, block_height, block_length, rl.WHITE);
            }
        }

        if (debug_overlay) {
            const start_pos = rl.Vector3Add(camera.position, rl.Vector3Scale(rl.GetCameraForward(&camera), 0.3));
            rl.DrawLine3D(start_pos, rl.Vector3Add(start_pos, rl.Vector3{ .x = 0.03, .y = 0, .z = 0 }), rl.RED);
            rl.DrawLine3D(start_pos, rl.Vector3Add(start_pos, rl.Vector3{ .x = 0, .y = 0.03, .z = 0 }), rl.GREEN);
            rl.DrawLine3D(start_pos, rl.Vector3Add(start_pos, rl.Vector3{ .x = 0, .y = 0, .z = 0.03 }), rl.BLUE);

            //rl.DrawLine3D(rl.Vector3{ .x = 0, .y = 0, .z = 0 }, rl.Vector3Normalize(rl.Vector3Subtract(camera.target, camera.position)), rl.RED);

            std.debug.print("{}\n", .{rl.GetCameraForward(&camera)});
            //            rl.DrawLine3D(start_pos, rl.Vector3Add(start_pos, rl.Vector3{}), rl.YELLOW);
        }

        // rl.DrawGrid(100, 1.0);
        rl.EndMode3D();

        if (debug_overlay) {
            var strz_buffer: [256]u8 = undefined;
            const fps_strz = try std.fmt.bufPrintZ(&strz_buffer, "FPS:{d}", .{rl.GetFPS()});
            const fps_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, fps_strz), font_size, font_spacing);
            rl.DrawTextEx(font, @ptrCast([*c]const u8, fps_strz), rl.Vector2{ .x = 0, .y = 0 }, font_size, font_spacing, rl.WHITE);

            const camera_pos_strz = try std.fmt.bufPrintZ(&strz_buffer, "camera pos: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ camera.position.x, camera.position.y, camera.position.z });
            const camera_pos_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, camera_pos_strz), font_size, font_spacing);
            rl.DrawTextEx(font, @ptrCast([*c]const u8, camera_pos_strz), rl.Vector2{ .x = 0, .y = fps_strz_dim.y }, font_size, font_spacing, rl.WHITE);

            const camera_target_strz = try std.fmt.bufPrintZ(&strz_buffer, "camera target: (x:{d:.2}, y:{d:.2}, z:{d:.2})", .{ camera.target.x, camera.target.y, camera.target.z });
            const camera_target_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, camera_target_strz), font_size, font_spacing);
            _ = camera_target_strz_dim;
            rl.DrawTextEx(font, @ptrCast([*c]const u8, camera_pos_strz), rl.Vector2{ .x = 0, .y = fps_strz_dim.y + camera_pos_strz_dim.y }, font_size, font_spacing, rl.WHITE);
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

    rlgl.End();
    rlgl.SetTexture(0);
}
