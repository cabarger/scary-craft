const std = @import("std");

pub fn VectorOps(comptime len: comptime_int, comptime T: type) type {
    return struct {
        pub inline fn scale(v: @Vector(len, T), s: f32) @Vector(len, T) {
            return v * @splat(len, s);
        }

        pub inline fn normalize(v: @Vector(len, T)) @Vector(len, T) {
            const mag = magnitude(v);
            if (mag != 0)
                return v * @splat(len, 1.0 / mag);
            return v;
        }

        pub inline fn magnitude(a: @Vector(len, T)) T {
            return @sqrt(dot(a, a));
        }

        pub inline fn dot(a: @Vector(len, T), b: @Vector(len, T)) T {
            return @reduce(.Add, a * b);
        }

        pub inline fn cross(a: @Vector(3, T), b: @Vector(3, T)) @Vector(3, T) {
            return @Vector(3, T){
                a[1] * b[2] - a[2] * b[1],
                a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0],
            };
        }

        pub inline fn forward(v1: @Vector(3, T), v2: @Vector(3, T)) @Vector(3, T) {
            return normalize(v2 - v1);
        }

        pub inline fn right(v1: @Vector(3, T), v2: @Vector(3, T), up: @Vector(3, T)) @Vector(3, T) {
            var forward_vec = forward(v1, v2);
            return cross(forward_vec, normalize(up));
        }

        pub fn rotateByAxisAngle(v: @Vector(3, T), axis_: @Vector(3, T), angle__: T) @Vector(3, T) {
            var angle_ = angle__;
            var axis = axis_;
            var result = v;

            axis = normalize(axis);

            angle_ /= 2;
            var a = @sin(angle_);
            const w = axis * @splat(3, a);
            a = @cos(angle_);

            var wv = cross(w, v);
            var wwv = cross(w, wv);

            a *= 2;
            wv *= @splat(3, a);
            wwv *= @splat(3, @as(f32, 2.0));

            result += wv;
            result += wwv;

            return result;
        }

        pub fn angle(v1: @Vector(3, T), v2: @Vector(3, T)) T {
            var result: f32 = 0.0;
            const cross_mag = magnitude(cross(v1, v2));
            result = std.math.atan2(T, cross_mag, dot(v1, v2));

            return result;
        }
    };
}
