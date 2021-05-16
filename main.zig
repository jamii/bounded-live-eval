const std = @import("std");
const Allocator = std.mem.Allocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;

const Expr = union(enum) {
    Constant: u64,
    Union,
    Product,
    Dup,
};

pub fn parse(allocator: *Allocator, code: []const u8) ![]const Expr {
    var stack_size: usize = 0;
    var exprs = std.ArrayList(Expr).init(allocator);
    for (code) |char| {
        switch (char) {
            ' ' => continue,
            '0' => {
                try exprs.append(.{ .Constant = 0 });
                stack_size += 1;
            },
            '1' => {
                try exprs.append(.{ .Constant = 1 });
                stack_size += 1;
            },
            '|' => {
                if (stack_size < 2) return error.ParseError;
                stack_size -= 1;
                try exprs.append(.Union);
            },
            '*' => {
                if (stack_size < 2) return error.ParseError;
                stack_size -= 1;
                try exprs.append(.Product);
            },
            '^' => {
                if (stack_size < 1) return error.ParseError;
                stack_size += 1;
                try exprs.append(.Dup);
            },
            else => return error.ParseError,
        }
    }
    if (stack_size != 1) return error.ParseError;
    return exprs.toOwnedSlice();
}

const Evaluator = struct {
    allocator: *Allocator,
    work_budget_remaining: usize,
    state: union(enum) {
        NotSuspended,
        Suspended,
    },
    frame: ?anyframe,

    fn init(allocator: *Allocator) Evaluator {
        return .{
            .allocator = allocator,
            .work_budget_remaining = 0,
            .state = .NotSuspended,
            .frame = null,
        };
    }

    fn spend_budget(self: *Evaluator) void {
        if (self.work_budget_remaining == 0) {
            self.state = .Suspended;
            suspend {
                self.frame = @frame();
            }
            std.debug.assert(self.state == .NotSuspended);
        }
        self.work_budget_remaining -= 1;
    }

    fn eval(self: *Evaluator, exprs: []const Expr) ![]const []const u64 {
        var stack = std.ArrayList([]const []const u64).init(self.allocator);
        for (exprs) |expr| {
            switch (expr) {
                .Constant => |number| {
                    self.spend_budget();
                    const row = try self.allocator.alloc(u64, 1);
                    const bag = try self.allocator.alloc([]const u64, 1);
                    row[0] = number;
                    bag[0] = row;
                    try stack.append(bag);
                },
                .Union => {
                    const left_bag = stack.pop();
                    const right_bag = stack.pop();
                    self.spend_budget();
                    const bag = try std.mem.concat(self.allocator, []const u64, &[_][]const []const u64{ left_bag, right_bag });
                    try stack.append(bag);
                },
                .Product => {
                    const left_bag = stack.pop();
                    const right_bag = stack.pop();
                    const bag = try self.allocator.alloc([]const u64, left_bag.len * right_bag.len);
                    var i: usize = 0;
                    for (left_bag) |left_row| {
                        for (right_bag) |right_row| {
                            self.spend_budget();
                            bag[i] = try std.mem.concat(self.allocator, u64, &[_][]const u64{ left_row, right_row });
                            i += 1;
                        }
                    }
                    try stack.append(bag);
                },
                .Dup => {
                    const bag = stack.pop();
                    try stack.append(bag);
                    try stack.append(bag);
                },
            }
        }
        return stack.pop();
    }
};

fn run_to_finish(allocator: *Allocator, code: []const u8) ![]const []const u64 {
    const exprs = try parse(allocator, code);

    var evaluator = Evaluator.init(allocator);
    var frame = async evaluator.eval(exprs);
    while (evaluator.state == .Suspended) {
        evaluator.work_budget_remaining = 1;
        evaluator.state = .NotSuspended;
        resume evaluator.frame.?;
    }

    const bag = try await frame;
    return bag;
}

// --- wasm stuff from here ---

var gpa = GeneralPurposeAllocator(.{
    .enable_memory_limit = true,
}){
    .requested_memory_limit = 100000,
};
const global_allocator = &gpa.allocator;

export fn alloc_string(len: usize) usize {
    if (global_allocator.alloc(u8, len)) |slice|
        return @ptrToInt(@ptrCast(*u8, slice))
    else |_|
        return 0;
}

var last_eval_string: []const u8 = "";

export fn last_eval_ptr() usize {
    return @ptrToInt(@ptrCast(*const u8, last_eval_string));
}

export fn last_eval_len() usize {
    return last_eval_string.len;
}

export fn run(ptr: usize, len: usize) void {
    const code = @intToPtr([*]u8, ptr)[0..len];
    var string = std.ArrayList(u8).init(global_allocator);
    var writer = string.writer();
    if (nosuspend run_to_finish(global_allocator, code)) |bag| {
        for (bag) |row| {
            for (row) |number| {
                std.fmt.format(writer, "{}, ", .{number}) catch {};
            }
            std.fmt.format(writer, "\n", .{}) catch {};
        }
    } else |err| {
        std.fmt.format(writer, "{}", .{err}) catch {};
    }
    last_eval_string = string.toOwnedSlice();
}
