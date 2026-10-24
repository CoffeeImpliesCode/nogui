//! External consumer: core-only.
//!
//! Depends on the `nogui` package by path and links nothing else. The
//! `product = "core"` request keeps the upstream build graph away from SDL,
//! FreeType, HarfBuzz and every demo artifact, so this executable proves the
//! headless core is usable on its own.
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

    const exe = b.addExecutable(.{
        .name = "core_only",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nogui", .module = nogui_mod }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    const run_step = b.step("run", "Run the core-only consumer");
    run_step.dependOn(&run.step);
}
