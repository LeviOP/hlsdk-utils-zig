const std = @import("std");

pub fn qerror(comptime fmt: []const u8, args: anytype, err: anyerror) anyerror {
    if (comptime @import("config").print_errors) {
        std.debug.print("\n************ ERROR ************\n", .{});
        std.debug.print(fmt ++ "\n", args);
    }

    return err;
}

