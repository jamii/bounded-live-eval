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
        if (mode == .Sync) return;
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

    fn reset(self: *Runner, code_len: usize) ![]u8 {
        const child_allocator = self.arena.child_allocator;
        self.arena.deinit();
        self.arena = ArenaAllocator.init(child_allocator);

        self.bounder = Bounder.init();
        self.code = try self.arena.allocator.alloc(u8, code_len);
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
            std.fmt.format(writer, "{}", .{err}) catch {};
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

    fn getOutput(self: *Runner) []const u8 {
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
}){};

var runner = Runner.init(&gpa.allocator);

export fn runnerReset(memory_limit: usize, code_len: usize) usize {
    gpa.requested_memory_limit = memory_limit;
    if (runner.reset(code_len)) |code| {
        return @ptrToInt(@ptrCast([*c]const u8, code));
    } else |err| {
        switch (err) {
            error.OutOfMemory => return 0,
        }
    }
}

export fn runnerStart() void {
    runner.start();
}

export fn runnerStep(work_budget: usize) bool {
    if (runner.state == .Running) nosuspend runner.step(work_budget);
    return (runner.state == .Running);
}

export fn runnerOutputPtr() usize {
    return @ptrToInt(@ptrCast([*c]const u8, runner.getOutput()));
}

export fn runnerOutputLen() usize {
    return runner.getOutput().len;
}

// --- crude benchmarks ---

const mode: enum { Sync, Async } = .Async;

pub fn main() !void {
    if (@import("builtin").os.tag != .freestanding) {
        gpa.requested_memory_limit = std.math.maxInt(usize);
        const code = try std.io.getStdIn().reader().readAllAlloc(&gpa.allocator, std.math.maxInt(usize));
        var num_evals: usize = 10;
        switch (mode) {
            .Async => {
                var arena = ArenaAllocator.init(&gpa.allocator);
                var bounder = Bounder.init();
                const exprs = try parse(&arena, code);
                var total_len: usize = 0;
                var timer = try std.time.Timer.start();
                while (num_evals > 0) : (num_evals -= 1) {
                    var frame = async eval(&arena, &bounder, exprs);
                    while (bounder.hasWork()) bounder.doWork(1);
                    const bag = nosuspend try await frame;
                    total_len += bag.len;
                }
                const time = timer.lap();
                std.debug.print("time={}\ntotal_len={}\n", .{ time, total_len });
            },
            .Sync => {
                var arena = ArenaAllocator.init(&gpa.allocator);
                var bounder = Bounder.init();
                const exprs = try parse(&arena, code);
                var total_len: usize = 0;
                var timer = try std.time.Timer.start();
                while (num_evals > 0) : (num_evals -= 1) {
                    const bag = try eval(&arena, &bounder, exprs);
                    total_len += bag.len;
                }
                const time = timer.lap();
                std.debug.print("time={}\ntotal_len={}\n", .{ time, total_len });
            },
        }
    }
}
