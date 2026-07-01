const std = @import("std");

fn formatCDate(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const ts = std.Io.Clock.real.now(io);

    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.toSeconds()) };
    const day = epoch.getEpochDay();

    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const year = year_day.year;

    const month_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    return try std.fmt.allocPrint(
        allocator,
        "{s} {d:>2} {d}",
        .{
            month_names[month_day.month.numeric() - 1],
            month_day.day_index + 1,
            year
        },
    );
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "qrad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{
                    .name = "c",
                    .module = translate_c.createModule(),
                },
            },
        }),
    });

    const build_date = formatCDate(b.allocator, b.graph.io) catch @panic("Out of memory");

    const options = b.addOptions();
    options.addOption([]const u8, "__DATE__", build_date);
    exe.root_module.addOptions("build", options);

    const qrad_options = b.addOptions();
    qrad_options.addOption(bool, "print_errors", true);
    exe.root_module.addOptions("config", qrad_options);

    b.installArtifact(exe);
}
