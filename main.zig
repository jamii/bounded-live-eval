const std = @import("std");
const Allocator = std.mem.Allocator;

const Expr = union(enum) {
    Constant: u64,
    Union: struct {
        left: *const Expr,
        right: *const Expr,
    },
    Product: struct {
        left: *const Expr,
        right: *const Expr,
    },
};

pub fn eval(allocator: *Allocator, expr: Expr) error{OutOfMemory}![]const []const u64 {
    switch (expr) {
        .Constant => |number| {
            const row = try allocator.alloc(u64, 1);
            const bag = try allocator.alloc([]const u64, 1);
            row[0] = number;
            bag[0] = row;
            return bag;
        },
        .Union => |pair| {
            const left_bag = try eval(allocator, pair.left.*);
            const right_bag = try eval(allocator, pair.right.*);
            const bag = try std.mem.concat(allocator, []const u64, &[_][]const []const u64{ left_bag, right_bag });
            return bag;
        },
        .Product => |pair| {
            const left_bag = try eval(allocator, pair.left.*);
            const right_bag = try eval(allocator, pair.right.*);
            const bag = try allocator.alloc([]const u64, left_bag.len * right_bag.len);
            var i: usize = 0;
            for (left_bag) |left_row| {
                for (right_bag) |right_row| {
                    bag[i] = try std.mem.concat(allocator, u64, &[_][]const u64{ left_row, right_row });
                    i += 1;
                }
            }
            return bag;
        },
    }
}

const BoundedAllocator = struct {
    parent: *Allocator,
    allocator: Allocator,

    fn init(parent: *Allocator) BoundedAllocator {
        return .{
            .parent = parent,
            .allocator = Allocator{
                .allocFn = alloc,
                .resizeFn = resize,
            },
        };
    }

    fn alloc(allocator: *Allocator, n: usize, ptr_align: u29, len_align: u29, ra: usize) ![]u8 {
        const self = @fieldParentPtr(BoundedAllocator, "allocator", allocator);
        return self.parent.allocFn(self.parent, n, ptr_align, len_align, ra);
    }

    fn resize(allocator: *Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) Allocator.Error!usize {
        const self = @fieldParentPtr(BoundedAllocator, "allocator", allocator);
        return self.parent.resizeFn(self.parent, buf, buf_align, new_len, len_align, ret_addr);
    }
};

pub fn main() !void {
    var parent_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var bounded_allocator = BoundedAllocator.init(&parent_allocator.allocator);
    const allocator = &bounded_allocator.allocator;
    const expr_0 = Expr{ .Constant = 0 };
    const expr_1 = Expr{ .Constant = 1 };
    const expr_01 = Expr{ .Union = .{ .left = &expr_0, .right = &expr_1 } };
    const expr = Expr{ .Product = .{ .left = &expr_01, .right = &expr_01 } };
    const bag = try eval(allocator, expr);
    for (bag) |row| {
        for (row) |number| {
            std.debug.print("{}, ", .{number});
        }
        std.debug.print("\n", .{});
    }
}
