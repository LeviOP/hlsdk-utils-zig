const std = @import("std");

pub const WorkPool = struct {
    counter: std.atomic.Value(usize) = .init(0),
    total: usize,
    errored: std.atomic.Value(bool) = .init(false),
    @"error": std.atomic.Value(u16) = .init(undefined),

    pub fn next(self: *WorkPool) ?usize {
        if (self.errored.load(.monotonic)) return null;

        const i = self.counter.fetchAdd(1, .monotonic);
        if (i >= self.total) return null;
        return i;
    }
};

pub fn runThreadsOnIndividual(
    allocator: std.mem.Allocator,
    numthreads: usize,
    workcount: usize,
    comptime item_func: anytype,
    args: anytype,
) !void {
    const Args = @TypeOf(args);

    const ReturnType = @typeInfo(@TypeOf(item_func)).@"fn".return_type.?;
    const returns_error = @typeInfo(ReturnType) == .error_union;

    const worker = struct {
        fn run(a: Args, pool: *WorkPool) !void {
            while (pool.next()) |i| {
                const full_args = a ++ .{i};
                if (comptime returns_error) {
                    try @call(.auto, item_func, full_args);
                } else {
                    @call(.auto, item_func, full_args);
                }
            }
        }
    }.run;

    try runThreadsOn(allocator, numthreads, workcount, worker, .{args});
}

pub fn runThreadsOn(
    allocator: std.mem.Allocator,
    numthreads: usize,
    workcount: usize,
    comptime func: anytype,
    args: anytype,
) !void {
    var pool = WorkPool{ .total = workcount };
    const Args = @TypeOf(args);

    const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const returns_error = @typeInfo(ReturnType) == .error_union;

    const worker = struct {
        fn run(a: Args, p: *WorkPool) void {
            const full_args = a ++ .{p};
            if (comptime returns_error) {
                @call(.auto, func, full_args) catch |err| {
                    if (p.errored.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                        p.@"error".store(@intFromError(err), .release);
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(&.{
                                .return_addresses = trace.instruction_addresses[0..trace.index],
                                .skipped = .none
                            });
                        }
                    }
                };
            } else {
                @call(.auto, func, full_args);
            }
        }
    }.run;

    const threads = try allocator.alloc(std.Thread, numthreads);
    defer allocator.free(threads);
    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{ args, &pool });
    }
    for (threads) |t| t.join();

    if (pool.errored.load(.monotonic)) {
        return @errorFromInt(pool.@"error".load(.monotonic));
    }
}
