const std = @import("std");
const Allocator = std.mem.Allocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;

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
    parent: ParentAllocator,
    allocator: Allocator,
    state: union(enum) {
        Ok,
        OutOfMemory,
    },

    const ParentAllocator = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    });

    fn init(requested_memory_limit: usize) BoundedAllocator {
        return .{
            .parent = ParentAllocator{
                .requested_memory_limit = requested_memory_limit,
            },
            .allocator = Allocator{
                .allocFn = alloc,
                .resizeFn = resize,
            },
            .state = .Ok,
        };
    }

    fn doubleLimit(self: *BoundedAllocator) void {
        self.parent.requested_memory_limit = self.parent.requested_memory_limit * 2;
        self.state = .Ok;
    }

    fn alloc(allocator: *Allocator, n: usize, ptr_align: u29, len_align: u29, ra: usize) ![]u8 {
        const self = @fieldParentPtr(BoundedAllocator, "allocator", allocator);
        while (true) {
            const result = self.parent.allocator.allocFn(&self.parent.allocator, n, ptr_align, len_align, ra);
            if (result) |ok| {
                return ok;
            } else |err| {
                self.state = .OutOfMemory;
                // Request more memory
                suspend {}
                if (self.state == .Ok)
                    // Request granted, try again
                    continue
                else
                    return err;
            }
        }
    }

    fn resize(allocator: *Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) Allocator.Error!usize {
        const self = @fieldParentPtr(BoundedAllocator, "allocator", allocator);
        while (true) {
            const result = self.parent.allocator.resizeFn(&self.parent.allocator, buf, buf_align, new_len, len_align, ret_addr);
            if (result) |ok| {
                return ok;
            } else |err| {
                self.state = .OutOfMemory;
                // Request more memory
                suspend {}
                if (self.state == .Ok)
                    // Request granted, try again
                    continue
                else
                    return err;
            }
        }
    }
};

pub fn main() !void {
    var bounded_allocator = BoundedAllocator.init(256);
    const allocator = &bounded_allocator.allocator;
    const expr_0 = Expr{ .Constant = 0 };
    const expr_1 = Expr{ .Constant = 1 };
    const expr_01 = Expr{ .Union = .{ .left = &expr_0, .right = &expr_1 } };
    const expr = Expr{ .Product = .{ .left = &expr_01, .right = &expr_01 } };

    var frame = async eval(allocator, expr);
    while (bounded_allocator.state == .OutOfMemory)
        bounded_allocator.doubleLimit();
    const bag = try await frame;
    for (bag) |row| {
        for (row) |number| {
            std.debug.print("{}, ", .{number});
        }
        std.debug.print("\n", .{});
    }
}
