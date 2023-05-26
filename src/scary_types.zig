const std = @import("std");

pub fn Vector3(comptime T: type) type {
    return packed struct {
        const Self = @This();

        x: T,
        y: T,
        z: T,

        pub inline fn add(v1: Self, v2: Self) Self {
            return Self{
                .x = v1.x + v2.x,
                .y = v1.y + v2.y,
                .z = v1.z + v2.z,
            };
        }

        pub inline fn zero() Self {
            return Self{ .x = 0, .y = 0, .z = 0 };
        }

        pub inline fn equals(v1: Self, v2: Self) bool {
            return ((v1.x == v2.x) and
                (v1.y == v2.y) and
                (v1.z == v2.z));
        }
    };
}

pub fn SmolQ(comptime T: type, comptime capacity: u8) type {
    return struct {
        const Self = @This();

        items: [capacity]T,
        len: u8,

        pub fn pushAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.len + 1 <= self.items.len); // Has enough space?
            if (self.len > 0) {
                var item_index = @intCast(i16, self.len - 1);
                while (item_index >= 0) : (item_index -= 1)
                    self.items[@intCast(u8, item_index + 1)] = self.items[@intCast(u8, item_index)];
            }
            self.items[0] = item;
            self.len += 1;
        }

        pub fn popAssumeNotEmpty(self: *Self) T {
            std.debug.assert(self.len != 0);
            self.len -= 1;
            return self.items[self.len];
        }
    };
}

// NOTE(caleb): This might be better off *not* a generic. I'm not completly happy with this implementation.
//    If I end up needing another binary search tree than we will see how it holds up.
pub fn BST(
    comptime T: type,
    comptime goLeftFn: fn (lhs: T, rhs: T) bool,
    comptime foundTargetFn: fn (lhs: T, rhs: T) bool,
) type {
    return struct {
        const Self = @This();

        const BSTNode = struct {
            left: ?*BSTNode,
            right: ?*BSTNode,
            value: T,
        };

        root: ?*BSTNode,
        ally: std.mem.Allocator,

        pub fn init(ally: std.mem.Allocator) Self {
            return Self{
                .root = null,
                .ally = ally,
            };
        }

        pub fn search(this: *Self, value: T) ?T {
            var current_node = this.root;
            while (current_node != null) {
                if (foundTargetFn(value, current_node.?.value)) {
                    return current_node.?.value;
                }
                if (goLeftFn(value, current_node.?.value)) {
                    current_node = current_node.?.left;
                } else {
                    current_node = current_node.?.right;
                }
            }
            return null;
        }

        pub fn insert(this: *Self, value: T) !void {
            var current_node = this.root;
            while (current_node != null) {
                if (goLeftFn(value, current_node.?.value)) {
                    current_node = current_node.?.left;
                } else {
                    current_node = current_node.?.right;
                }
            }
            current_node = try this.ally.create(BSTNode);
            current_node.?.value = value;
            current_node.?.right = null;
            current_node.?.left = null;

            if (this.root == null) { // Edge case where this is the first insertion.
                this.root = current_node;
            }
        }
    };
}
