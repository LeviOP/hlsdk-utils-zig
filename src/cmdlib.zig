const std = @import("std");
const builtin = @import("builtin");

const config = @import("config");

pub const MAX_PATH = switch (builtin.os.tag) {
    .windows => std.os.windows.MAX_PATH,
    else => std.posix.PATH_MAX,
};

inline fn pathSeparator(c: u8) bool {
    return switch (builtin.os.tag) {
        .windows => c == '\\' or c == '/',
        else => c == '/',
    };
}

pub fn qError(comptime fmt: []const u8, args: anytype, err: anyerror) anyerror {
    if (comptime config.print_errors) {
        std.debug.print("\n************ ERROR ************\n", .{});
        std.debug.print(fmt ++ "\n", args);
        return error.QError;
    }

    return err;
}

pub inline fn handleQError(err: anyerror) !u8 {
    if (comptime !config.print_errors) {
        return err;
    }
    return switch (err) {
        error.QError => 1,
        else => err,
    };
}

pub fn stripExtension(path: []const u8) []const u8 {
    if (path.len == 0) return path;

    var i = path.len;
    while (i > 0) {
        i -= 1;
        switch (path[i]) {
            '.' => return path[0..i],
            '/' => return path, // no extension
            else => {},
        }
    }
    return path;
}

pub fn defaultExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (pathSeparator(path[i])) break;
        if (path[i] == '.') return allocator.dupe(u8, path); // already has an extension
    }
    return std.mem.concat(allocator, u8, &.{ path, extension });
}
