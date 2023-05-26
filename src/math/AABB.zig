const rl = @cImport({
    @cInclude("raylib.h");
});

const Self = @This();

min: rl.Vector3,
max: rl.Vector3,

pub fn getVertices(this: *Self, verticies: []rl.Vector3) void {
    std.debug.assert(verticies.len == 8);

    verticies[0] = rl.Vector3{ .x = this.min.x, .y = this.min.y, .z = this.min.z }; // fbl
    verticies[1] = rl.Vector3{ .x = this.min.x, .y = this.max.y, .z = this.min.z }; // ftl
    verticies[2] = rl.Vector3{ .x = this.max.x, .y = this.min.y, .z = this.min.z }; // fbr
    verticies[3] = rl.Vector3{ .x = this.max.x, .y = this.max.y, .z = this.min.z }; // ftr

    verticies[4] = rl.Vector3{ .x = this.min.x, .y = this.min.y, .z = this.max.z }; // nbl
    verticies[5] = rl.Vector3{ .x = this.min.x, .y = this.max.y, .z = this.max.z }; // ntl
    verticies[6] = rl.Vector3{ .x = this.max.x, .y = this.min.y, .z = this.max.z }; // nbr
    verticies[7] = rl.Vector3{ .x = this.max.x, .y = this.max.y, .z = this.max.z }; // ntr
}

fn getVectorP(this: *Self, normal: rl.Vector3) rl.Vector3 {
    var result = this.min;
    if (normal.x >= 0) {
        result.x += this.max.x;
    }
    if (normal.y >= 0) {
        result.y += this.max.y;
    }
    if (normal.z >= 0) {
        result.z += this.max.z;
    }
    return result;
}
