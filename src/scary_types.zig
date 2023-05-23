pub const Vector3I = packed struct {
    x: i32,
    y: i32,
    z: i32,

    pub inline fn equals(this: *const Vector3I, comp: Vector3I) bool {
        var result: bool = undefined;
        result = (this.x == comp.x and this.y == comp.y and this.z == comp.z);
        return result;
    }
};

pub inline fn vector3IZero() Vector3I {
    return Vector3I{ .x = 0, .y = 0, .z = 0 };
}
