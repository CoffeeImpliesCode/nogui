//! External consumer: text-only.
//!
//! Depends on the `nogui` package by path and asks for the `text` product,
//! which is the smallest upstream graph that still carries FreeType and
//! HarfBuzz. No SDL, no window, no GPU, no demo artifact.
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
        .product = "text",
    });
    const text_mod = requireModule(nogui_dep, "nogui_text") orelse return;
    const core_mod = requireModule(nogui_dep, "nogui") orelse return;
    const test_mod = requireModule(nogui_dep, "nogui_test") orelse return;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nogui_text", .module = text_mod },
            .{ .name = "nogui", .module = core_mod },
            .{ .name = "nogui_test", .module = test_mod },
        },
    });

    // The font is packaged data, not a demo file: copy it out of the
    // dependency and expose it through a one-line generated module, because
    // `@embedFile` only reaches inside the module's own package path.
    const assets = b.addWriteFiles();
    _ = assets.addCopyFile(nogui_dep.path("src/InterVariable.ttf"), "InterVariable.ttf");
    const shim = assets.add("font_embed.zig",
        \\pub const bytes = @embedFile("InterVariable.ttf");
        \\
    );
    exe_mod.addAnonymousImport("font_bytes", .{ .root_source_file = shim });

    const exe = b.addExecutable(.{ .name = "text_only", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    const run_step = b.step("run", "Run the text-only consumer");
    run_step.dependOn(&run.step);
}
