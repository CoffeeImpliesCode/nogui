//! External consumer: renderer.
//!
//! Depends on the `nogui` package by path and asks for the `render` product.
//! The CPU lowering stage never touches a window or a GPU, so this executable
//! needs no native display at all.
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
        .product = "render",
    });
    const nogui_mod = requireModule(nogui_dep, "nogui") orelse return;
    const render_mod = requireModule(nogui_dep, "v7_render") orelse return;

    const exe = b.addExecutable(.{
        .name = "renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = nogui_mod },
                .{ .name = "v7_render", .module = render_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the renderer consumer");
    run_step.dependOn(&run.step);
}
