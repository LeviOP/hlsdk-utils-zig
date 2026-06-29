const std = @import("std");

const Bsp = @import("bspfile.zig");
const radWorld = @import("qrad.zig").radWorld;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // const bsp = try loadBspFile(allocator, io, "/home/levi/.local/share/Steam/steamapps/common/Half-Life/valve/maps/c1a0.bsp");
    var bsp = try Bsp.init(allocator, io, "/home/levi/.local/share/Steam/steamapps/common/Half-Life/valve/maps/crossfire.bsp");
    defer bsp.deinit(allocator);

    if (bsp.visdata.len == 0) {
        std.debug.print("No vis information, direct lighting only.\n", .{});
        @import("qrad.zig").numbounce = 0;
        // TODO: ambient
    }

    try radWorld(allocator, &bsp);

    try bsp.writeFile(io, "/home/levi/.local/share/Steam/steamapps/common/Half-Life/valve/maps/crossfire.bsp");
}
