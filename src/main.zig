const std = @import("std");

const b = @import("build");
const c = @import("c");

const Bsp = @import("bspfile.zig");
const cmdlib = @import("cmdlib.zig");
const qError = cmdlib.qError;
const handleQError = cmdlib.handleQError;
const MAX_PATH = cmdlib.MAX_PATH;
const qrad = @import("qrad.zig");
const State = qrad.State;
const readLightFile = qrad.readLightFile;
const radWorld = qrad.radWorld;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    const state = try allocator.create(State);
    state.* = .{};
    defer {
        state.deinit(allocator);
        allocator.destroy(state);
    }

    var designer_lights: []const u8 = "";

    std.debug.print("qrad.exe v 1.5 ({s})\n", .{b.__DATE__});
    std.debug.print("----- Radiosity ----\n", .{});

    state.verbose = true;
    state.smoothing_threshold = @cos(45.0 * (std.math.pi / 180.0));

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-dump")) {
            // state.dumppatches = true;
        } else if (std.mem.eql(u8, arg, "-bounce")) {
            i += 1;
            if (i < args.len) {
                state.numbounce = @intCast(c.atoi(args[i]));

                if (state.numbounce < 0) {
                    std.debug.print("Error: expected non-negative value after '-bounce'\n", .{});
                    return 1;
                }
            } else {
                std.debug.print("Error: expected a value after '-bounce'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-verbose")) {
            state.verbose = true;
        } else if (std.mem.eql(u8, arg, "-terse")) {
            state.verbose = false;
        } else if (std.mem.eql(u8, arg, "-threads")) {
            i += 1;
            if (i < args.len) {
                // state.numthreads = c.atoi(args[i]);
                //
                // if (state.numthreads <= 0) {
                //     std.debug.print("Error: expected positive value after '-threads'\n", .{});
                //     return 1;
                // }
            } else {
                std.debug.print("Error: expected a value after '-threads'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-maxchop")) {
            i += 1;
            if (i < args.len) {
                state.maxchop = @floatCast(c.atof(args[i]));

                if (state.maxchop < 2) {
                    std.debug.print("Error: expected positive value after '-maxchop'\n", .{});
                    return 1;
                }
            } else {
                std.debug.print("Error: expected a value after '-maxchop'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-chop")) {
            i += 1;
            if (i < args.len) {
                state.minchop = @floatCast(c.atof(args[i]));

                if (state.minchop < 1) {
                    std.debug.print("Error: expected positive value after '-chop'\n", .{});
                    return 1;
                }

                if (state.minchop < 32) {
                    std.debug.print("WARNING: Chop values below 32 are not recommended. Use -extra instead.\n", .{});
                }
            } else {
                std.debug.print("Error: expected a value after '-chop'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-scale")) {
            i += 1;
            if (i < args.len) {
                state.lightscale = @floatCast(c.atof(args[i]));
            } else {
                std.debug.print("Error: expected a value after '-scale'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-ambient")) {
            if (i + 3 < args.len) {
                i += 1;
                state.ambient[0] = @as(f32, @floatCast(c.atof(args[i]))) * 128;

                i += 1;
                state.ambient[1] = @as(f32, @floatCast(c.atof(args[i]))) * 128;

                i += 1;
                state.ambient[2] = @as(f32, @floatCast(c.atof(args[i]))) * 128;
            } else {
                std.debug.print("Error: expected three color values after '-ambient'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-proj")) {
            i += 1;
            if (i < args.len and args[i].len > 0) {
                // @memcpy(state.qproject[0..args[i].len], args[i]);
                // state.qproject[args[i].len] = 0;
            } else {
                std.debug.print("Error: expected path name after '-proj'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-maxlight")) {
            i += 1;
            if (i < args.len and args[i].len > 0) {
                state.maxlight = @as(f32, @floatCast(c.atof(args[i]))) * 128;

                if (state.maxlight <= 0) {
                    std.debug.print("Error: expected positive value after '-maxlight'\n", .{});
                    return 1;
                }
            } else {
                std.debug.print("Error: expected a value after '-maxlight'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-lights")) {
            i += 1;
            if (i < args.len and args[i].len > 0) {
                if (args[i].len >= MAX_PATH)
                    return error.PathCopyUnsafeOverflow;
                designer_lights = args[i];
            } else {
                std.debug.print("Error: expected a filepath after '-lights'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-inc")) {
            // state.incremental = true;
        } else if (std.mem.eql(u8, arg, "-gamma")) {
            i += 1;
            if (i < args.len) {
                state.gamma = @floatCast(c.atof(args[i]));
            } else {
                std.debug.print("Error: expected a value after '-gamma'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-dlight")) {
            i += 1;
            if (i < args.len) {
                state.dlight_threshold = @floatCast(c.atof(args[i]));
            } else {
                std.debug.print("Error: expected a value after '-dlight'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-extra")) {
            state.extra = true;
        } else if (std.mem.eql(u8, arg, "-sky")) {
            i += 1;
            if (i < args.len) {
                state.indirect_sun = @floatCast(c.atof(args[i]));
            } else {
                std.debug.print("Error: expected a value after '-sky'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-smooth")) {
            i += 1;
            if (i < args.len) {
                state.smoothing_threshold = @cos(@as(f32, @floatCast(c.atof(args[i]))) * (std.math.pi / 180.0));
            } else {
                std.debug.print("Error: expected an angle after '-smooth'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-coring")) {
            i += 1;
            if (i < args.len) {
                state.coring = @floatCast(c.atof(args[i]));
            } else {
                std.debug.print("Error: expected a light threshold after '-coring'\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-notexscale")) {
            state.texscale = false;
        } else {
            break;
        }
    }

    if (state.maxlight > 255)
        state.maxlight = 255;

    if (i != args.len - 1) {
        qError("usage: qrad [-dump] [-inc] [-bounce n] [-threads n] [-verbose] [-terse] [-chop n] [-maxchop n] [-scale n] [-ambient red green blue] [-proj file] [-maxlight n] [-threads n] [-lights file] [-gamma n] [-dlight n] [-extra] [-smooth n] [-coring n] [-notexscale] bspfile", .{}, error.QError) catch return 1;
    }

    if (args[i].len >= MAX_PATH) return error.PathCopyUnsafeOverflow;
    var source = cmdlib.stripExtension(args[i]);

    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);
    const global_lights = try std.fs.path.join(allocator, &.{ exe_dir, "lights.rad" });
    defer allocator.free(global_lights);

    var level_lights = try std.mem.concat(allocator, u8, &.{ source, ".rad" });
    std.Io.Dir.cwd().access(io, level_lights, .{ .read = true }) catch {
        allocator.free(level_lights);
        level_lights = &.{};
    };
    defer allocator.free(level_lights);

    readLightFile(allocator, io, state, global_lights) catch |e| return handleQError(e);
    if (designer_lights.len != 0) readLightFile(allocator, io, state, designer_lights) catch |e| return handleQError(e);
    if (level_lights.len != 0) readLightFile(allocator, io, state, level_lights) catch |e| return handleQError(e);

    source = try cmdlib.defaultExtension(allocator, source, ".bsp");
    defer allocator.free(source);

    var bsp = Bsp.init(allocator, io, source) catch |e| return handleQError(e);
    defer bsp.deinit(allocator);

    if (bsp.visdata.len == 0) {
        std.debug.print("No vis information, direct lighting only.\n", .{});
        state.numbounce = 0;
        state.ambient = @splat(0.1);
    }

    radWorld(allocator, state, &bsp) catch |e| return handleQError(e);

    if (state.verbose)
        bsp.printFileSizes();

    bsp.writeFile(io, source) catch |e| return handleQError(e);

    return 0;
}
