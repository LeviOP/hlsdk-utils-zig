const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const print_errors = b.option(bool, "print_errors", "Print error strings from library instead of returning error") orelse true;

    const mod_options = b.addOptions();
    mod_options.addOption(bool, "print_errors", print_errors);

    const mod = b.addModule("hlsdk_utils", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "c",
                .module = mod_c.createModule(),
            }
        },
    });

    mod.addOptions("config", mod_options);

    const qrad_c = b.addTranslateC(.{
        .root_source_file = b.path("utils/qrad.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const qrad = b.addExecutable(.{
        .name = "qrad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("utils/qrad.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{
                    .name = "c",
                    .module = qrad_c.createModule(),
                },
                .{
                    .name = "hlsdk_utils",
                    .module = mod,
                },
            },
        }),
    });

    const qrad_options = b.addOptions();
    qrad_options.addOption([]const u8, "__DATE__", "Apr  6 2000");
    qrad.root_module.addOptions("build", qrad_options);

    const qrad_art = b.addInstallArtifact(qrad, .{});
    const qrad_step = b.step("qrad", "Build qrad");
    qrad_step.dependOn(&qrad_art.step);
}
