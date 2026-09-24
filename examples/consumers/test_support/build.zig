//! External consumer: test support.
//!
//! Depends on the `nogui` package by path and asks for the `core` product.
//! `nogui_test` drives a real App through a virtual clock and a scripted input
//! path, so nothing native is required.
const std = @import("std");

/// The `nogui` build graph only materialises its modules once every lazy
/// dependency the requested product needs has been fetched. On a configure
/// pass where that has not happened yet, produce no steps and let the build
/// runner fetch and re-run, instead of aborting on a missing module.
fn requireModule(dep: *std.Build.Dependency, name: []const u8) ?*std.Build.Module {
    return dep.builder.modules.get(name);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nogui_dep = b.dependency("nogui", .{
        .target = target,
        .optimize = optimize,
        .product = "core",
    });
    const nogui_mod = requireModule(nogui_dep, "nogui") orelse return;
    const test_mod = requireModule(nogui_dep, "nogui_test") orelse return;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nogui", .module = nogui_mod },
            .{ .name = "nogui_test", .module = test_mod },
        },
    });

    const exe = b.addExecutable(.{ .name = "test_support", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the test-support consumer");
    run_step.dependOn(&run.step);

    const test_exe = b.addTest(.{ .name = "test_support", .root_module = exe_mod });
    const test_step = b.step("test", "Run the test-support consumer's checks");
    test_step.dependOn(&b.addRunArtifact(test_exe).step);
}
