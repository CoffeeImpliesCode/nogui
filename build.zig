const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release_safe = std.builtin.OptimizeMode.ReleaseSafe;

    // ── Dependencies ───────────────────────────────────────
    const sdl3 = b.dependency("sdl3", .{ .target = target, .optimize = release_safe });
    const tracy = b.dependency("tracy", .{ .target = target, .optimize = release_safe });
    const noapi_dep = b.dependency("noapi", .{ .target = target, .optimize = optimize });
    const freetype_dep = b.dependency("freetype", .{ .target = target, .optimize = optimize });

    // ── noapi module (borrowed from dependency) ────────────
    const noapi_mod = noapi_dep.module("noapi");

    // ── nogui module ───────────────────────────────────────
    const mod = b.addModule("nogui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "noapi", .module = noapi_mod },
        },
    });

    // Library artifact for C dep propagation
    const lib = b.addLibrary(.{ .name = "nogui", .root_module = mod });

    // ── Executable ─────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "nogui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
            },
        }),
    });
    exe.root_module.linkLibrary(lib);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ── Prototype module ─────────────────────────────────
    const proto_mod = b.addModule("proto", .{
        .root_source_file = b.path("src/proto.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "noapi", .module = noapi_mod },
            .{ .name = "sdl3", .module = sdl3.module("sdl3") },
        },
    });

    // ── Prototype executable ────────────────────────────────
    const proto_exe = b.addExecutable(.{
        .name = "nogui-proto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proto_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
            },
        }),
    });
    proto_exe.root_module.linkLibrary(lib);
    proto_exe.root_module.linkLibrary(freetype_dep.artifact("freetype"));

    b.installArtifact(proto_exe);

    const proto_run_step = b.step("proto", "Run the prototype");
    const proto_run_cmd = b.addRunArtifact(proto_exe);
    proto_run_step.dependOn(&proto_run_cmd.step);
    proto_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| proto_run_cmd.addArgs(args);

    // ── Tests ──────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const proto_tests = b.addTest(.{ .root_module = proto_mod });
    const run_proto_tests = b.addRunArtifact(proto_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_proto_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ── Glyph test (FreeType) ─────────────────────────────
    const glyph_test = b.addExecutable(.{
        .name = "glyph-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/glyph_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    glyph_test.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    b.installArtifact(glyph_test);
    const glyph_step = b.step("glyph", "Run glyph test");
    const glyph_cmd = b.addRunArtifact(glyph_test);
    glyph_step.dependOn(&glyph_cmd.step);
    glyph_cmd.step.dependOn(b.getInstallStep());
}
