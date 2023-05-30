const std = @import("std");
const MemoryPoolExtra = std.heap.MemoryPoolExtra;

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

pub fn BST(
    comptime T: type,
    comptime goLeftFn: fn (lhs: T, rhs: T) bool,
    comptime foundTargetFn: fn (lhs: T, rhs: T) bool,
) type {
    return BSTExtra(T, .{}, goLeftFn, foundTargetFn);
}

pub const BSTOptions = struct {
    preheated_node_count: ?usize = null,
    growable: bool = true,
};

pub fn BSTExtra(
    comptime T: type,
    comptime bst_options: BSTOptions,
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
        pool: MemoryPoolExtra(BSTNode, .{ .alignment = @alignOf(BSTNode), .growable = bst_options.growable }),
        count: u32,

        pub fn init(ally: std.mem.Allocator) Self {
            if (bst_options.preheated_node_count != null) {
                return Self{
                    .root = null,
                    .ally = ally,
                    .pool = MemoryPoolExtra(BSTNode, .{ .alignment = @alignOf(BSTNode), .growable = bst_options.growable }).initPreheated(ally, bst_options.preheated_node_count.?) catch unreachable,
                    .count = 0,
                };
            } else {
                return Self{
                    .root = null,
                    .ally = ally,
                    .pool = MemoryPoolExtra(BSTNode, .{ .alignment = @alignOf(BSTNode), .growable = bst_options.growable }).init(ally),
                    .count = 0,
                };
            }
        }

        pub fn search(self: *Self, value: T) ?T {
            var current_node = self.root;
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

        fn removeStartingAt(self: *Self, start_node: ?*BSTNode, value: T) ?T {
            var current_node = start_node;
            var parent_edge: ?*?*BSTNode = null;
            while (current_node != null) {
                if (foundTargetFn(value, current_node.?.value)) {
                    const node = current_node.?;
                    if (parent_edge != null) {
                        parent_edge.?.* = null;
                    }
                    self.pool.destroy(@ptrCast(*BSTNode, current_node));
                    self.count -= 1;

                    if (node.left != null)
                        self.insert(self.removeStartingAt(node.left, node.left.?.value) orelse unreachable) catch unreachable;
                    if (node.right != null)
                        self.insert(self.removeStartingAt(node.right, node.right.?.value) orelse unreachable) catch unreachable;

                    return node.value;
                }
                if (goLeftFn(value, current_node.?.value)) {
                    parent_edge = &current_node.?.left;
                    current_node = current_node.?.left;
                } else {
                    parent_edge = &current_node.?.right;
                    current_node = current_node.?.right;
                }
            }
            return null;
        }

        pub fn remove(self: *Self, value: T) ?T {
            return self.removeStartingAt(self.root, value);
        }

        pub fn insert(self: *Self, value: T) !void {
            var current_node = self.root;
            while (current_node != null) {
                if (goLeftFn(value, current_node.?.value)) {
                    current_node = current_node.?.left;
                } else {
                    current_node = current_node.?.right;
                }
            }

            current_node = try self.pool.create();
            current_node.?.value = value;
            current_node.?.right = null;
            current_node.?.left = null;

            if (self.root == null) { // Tree is empty
                self.root = current_node;
            }

            self.count += 1;
        }
    };
}
