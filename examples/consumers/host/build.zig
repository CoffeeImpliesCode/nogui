//! External consumer: host.
//!
//! Depends on the `nogui` package by path and asks for the `host` product.
//! SDL is selected with the `dummy` video driver, so the window opens without
//! a compositor or a physical display.
//!
//! The W21 AccessKit bridge is ON by default, matching the `nogui` package.
//! `-Daccesskit-bridge=false` keeps this consumer Rust-free. With the bridge
//! enabled, the `host` product builds and links it through `nogui`.
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

    // Match the package default. The explicit opt-out needs no Rust toolchain.
    // The option name is hyphenated, so the field needs the quoted form.
    const accesskit_bridge = b.option(
        bool,
        "accesskit-bridge",
        "Build and link the W21 AccessKit bridge into the host product",
    ) orelse true;
    const nogui_dep = b.dependency("nogui", .{
        .target = target,
        .optimize = optimize,
        .product = "host",
        .@"accesskit-bridge" = accesskit_bridge,
    });
    const nogui_mod = requireModule(nogui_dep, "nogui") orelse return;
    const host_mod = requireModule(nogui_dep, "nogui_host") orelse return;

    const exe = b.addExecutable(.{
        .name = "host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = nogui_mod },
                .{ .name = "nogui_host", .module = host_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the host consumer");
    run_step.dependOn(&run.step);
}
