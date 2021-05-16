const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const assert = std.debug.assert;

// --- interpreter ---

const Expr = union(enum) {
    Constant: u64,
    Union,
    Product,
    Dup,
};

pub fn parse(arena: *ArenaAllocator, code: []const u8) ![]const Expr {
    var stack_size: usize = 0;
    var exprs = std.ArrayList(Expr).init(&arena.allocator);
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

fn eval(arena: *ArenaAllocator, bounder: *Bounder, exprs: []const Expr) ![]const []const u64 {
    var stack = std.ArrayList([]const []const u64).init(&arena.allocator);
    for (exprs) |expr| {
        switch (expr) {
            .Constant => |number| {
                bounder.spendBudget();
                const row = try arena.allocator.alloc(u64, 1);
                const bag = try arena.allocator.alloc([]const u64, 1);
                row[0] = number;
                bag[0] = row;
                try stack.append(bag);
            },
            .Union => {
                const left_bag = stack.pop();
                const right_bag = stack.pop();
                bounder.spendBudget();
                const bag = try std.mem.concat(&arena.allocator, []const u64, &[_][]const []const u64{ left_bag, right_bag });
                try stack.append(bag);
            },
            .Product => {
                const left_bag = stack.pop();
                const right_bag = stack.pop();
                const bag = try arena.allocator.alloc([]const u64, left_bag.len * right_bag.len);
                var i: usize = 0;
                for (left_bag) |left_row| {
                    for (right_bag) |right_row| {
                        bounder.spendBudget();
                        bag[i] = try std.mem.concat(&arena.allocator, u64, &[_][]const u64{ left_row, right_row });
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

// --- bounder ---

const Bounder = union(enum) {
    HasWorkBudget: usize,
    Suspended: anyframe,

    fn init() Bounder {
        return .{ .HasWorkBudget = 0 };
    }

    fn hasWork(self: *Bounder) bool {
        return (self.* == .Suspended);
    }

    fn doWork(self: *Bounder, work_budget: usize) void {
        const frame = self.Suspended;
        self.* = .{ .HasWorkBudget = work_budget };
        resume frame;
    }

    fn spendBudget(self: *Bounder) void {
        if (self.HasWorkBudget == 0) {
            suspend {
                self.* = .{ .Suspended = @frame() };
            }
        }
        self.HasWorkBudget -= 1;
    }
};

// --- ui state machine ---

const Runner = struct {
    arena: ArenaAllocator,
    bounder: Bounder,
    code: []u8,
    exprs: []const Expr,
    state: union(enum) {
        Init,
        Ok: []const u8,
        Error: []const u8,
        Running: @Frame(eval),
    },

    fn init(allocator: *Allocator) Runner {
        return .{
            .arena = ArenaAllocator.init(allocator),
            .bounder = Bounder.init(),
            .code = "",
            .exprs = &[0]Expr{},
            .state = .Init,
        };
    }

    fn reset(self: *Runner, code_len: usize) []u8 {
        const child_allocator = self.arena.child_allocator;
        self.arena.deinit();
        self.arena = ArenaAllocator.init(child_allocator);

        self.code = self.arena.allocator.alloc(u8, code_len) catch @panic("OOM while receiving code");
        self.exprs = &[0]Expr{};
        self.state = .Init;

        // js will write into this before calling start
        return self.code;
    }

    fn start(self: *Runner) void {
        assert(self.state == .Init);
        if (parse(&self.arena, self.code)) |exprs| {
            self.exprs = exprs;
            self.state = .{ .Running = async eval(&self.arena, &self.bounder, self.exprs) };
        } else |err| {
            var string = std.ArrayList(u8).init(&self.arena.allocator);
            var writer = string.writer();
            std.fmt.format(writer, "{}", .{err}) catch @panic("OOM while writing error");
            self.state = .{ .Error = string.toOwnedSlice() };
        }
    }

    fn step(self: *Runner, work_budget: usize) void {
        assert(self.state == .Running);
        if (self.bounder.hasWork()) {
            self.bounder.doWork(work_budget);
        } else {
            var string = std.ArrayList(u8).init(&self.arena.allocator);
            var writer = string.writer();
            if (await self.state.Running) |bag| {
                for (bag) |row| {
                    for (row) |number| {
                        std.fmt.format(writer, "{}, ", .{number}) catch {};
                    }
                    std.fmt.format(writer, "\n", .{}) catch {};
                }
                self.state = .{ .Ok = string.toOwnedSlice() };
            } else |err| {
                std.fmt.format(writer, "{}", .{err}) catch {};
                self.state = .{ .Error = string.toOwnedSlice() };
            }
        }
    }

    fn get_output(self: *Runner) []const u8 {
        return switch (self.state) {
            .Init => "",
            .Ok => |string| string,
            .Error => |string| string,
            .Running => |_| "Running...",
        };
    }
};

// --- globals and exports ---

var gpa = GeneralPurposeAllocator(.{
    .enable_memory_limit = true,
}){
    .requested_memory_limit = 100000,
};

var runner = Runner.init(&gpa.allocator);

export fn runner_reset(code_len: usize) usize {
    const code = runner.reset(code_len);
    return @ptrToInt(@ptrCast(*u8, code));
}

export fn runner_start() void {
    runner.start();
}

export fn runner_step(work_budget: usize) void {
    if (runner.state == .Running) nosuspend runner.step(work_budget);
}

export fn runner_output_ptr() usize {
    return @ptrToInt(@ptrCast(*const u8, runner.get_output()));
}

export fn runner_output_len() usize {
    return runner.get_output().len;
}
