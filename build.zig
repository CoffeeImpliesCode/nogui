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
    const harfbuzz_dep = b.dependency("harfbuzz", .{ .target = target, .optimize = optimize });
    const libxml2_dep = b.dependency("libxml2", .{ .target = target, .optimize = optimize });

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

    // ── Storage-image isolation probe ───────────────────────
    // TEMP: standalone compute → storage-image write probe (probe_main.zig
    // + shaders/storage_probe.comp.slang). Prints three readback pixels:
    // (0.25,0.75,0.5,1.0) → the noapi storage-image write works in
    // isolation; (0,0,0,0) → the noapi storage-image path is broken.

    // ── v7 demo executable ────────────────────────────────
    const v7_demo = b.addExecutable(.{
        .name = "v7-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_enabled") },
            },
        }),
        // The LLVM codegen backend: the tracy client's stack capture +
        // symbolication depend on the LLVM-emitted debug info (the native
        // backend's DWARF is incomplete).
        .use_llvm = true,
    });
    v7_demo.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_demo.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    // libxml2 (the SVG parser's XML layer): link the hermetic build + emit
    // its headers so the consumer's @cImport can find them.
    v7_demo.root_module.linkLibrary(libxml2_dep.artifact("xml2"));
    v7_demo.root_module.addIncludePath(libxml2_dep.artifact("xml2").getEmittedIncludeTree());
    b.installArtifact(v7_demo);

    const v7_run_cmd = b.addRunArtifact(v7_demo);
    const v7_run_step = b.step("v7", "Run the v7 demo");
    v7_run_step.dependOn(&v7_run_cmd.step);
    v7_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| v7_run_cmd.addArgs(args);

    // Recompile the demo's shaders from the Slang sources before every run so
    // a stale committed .spv can never silently render wrong toggles.
    // Attached ONLY to the interactive demo run — test/check/lint gates stay
    // hermetic (slangc is not guaranteed on PATH).
    const quad_frag_spv_step = b.addSystemCommand(&.{
        "slangc", "-target", "spirv", "-I", "shaders", "-o", "shaders/quad_frag.spv", "shaders/quad_frag.slang",
    });
    v7_run_cmd.step.dependOn(&quad_frag_spv_step.step);
    const quad_vert_spv_step = b.addSystemCommand(&.{
        "slangc", "-target", "spirv", "-I", "shaders", "-o", "shaders/quad_vert.spv", "shaders/quad_vert.slang",
    });
    v7_run_cmd.step.dependOn(&quad_vert_spv_step.step);
    const blit_spv_step = b.addSystemCommand(&.{
        "slangc", "-target", "spirv", "-I", "shaders", "-o", "shaders/blit_oklab.spv", "shaders/blit_oklab.slang",
    });
    v7_run_cmd.step.dependOn(&blit_spv_step.step);
    const fullscreen_spv_step = b.addSystemCommand(&.{
        "slangc", "-target", "spirv", "-I", "shaders", "-o", "shaders/fullscreen_vert.spv", "shaders/fullscreen_vert.slang",
    });
    v7_run_cmd.step.dependOn(&fullscreen_spv_step.step);
    // The mandelbrot compute shader — compiled here too so the .spv can
    // never silently lag the .slang source (it did once: a stale f32 .spv
    // with an f64 layout mismatch read the scale's low bytes as max_iter
    // and hung the GPU on scroll).
    const mandelbrot_spv_step = b.addSystemCommand(&.{
        "slangc", "-target", "spirv", "-I", "shaders", "-o", "shaders/mandelbrot_comp.spv", "shaders/mandelbrot.comp.slang",
    });
    v7_run_cmd.step.dependOn(&mandelbrot_spv_step.step);
    // The CS1 radix-sort compute shader (V1b) — same staleness rule: the
    // sort key layout must never silently lag the batch's SceneRect.
    const sort_spv_step = b.addSystemCommand(&.{
        "slangc", "-target", "spirv", "-I", "shaders", "-o", "shaders/sort_comp.spv", "shaders/sort.comp.slang",
    });
    v7_run_cmd.step.dependOn(&sort_spv_step.step);

    // ── Tests ─────────────────────────────────────────────
    const v7_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    const run_v7_tests = b.addRunArtifact(v7_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_v7_tests.step);

    const v7_text_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/text.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    v7_text_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_text_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    const run_v7_text_tests = b.addRunArtifact(v7_text_tests);
    test_step.dependOn(&run_v7_text_tests.step);

    const v7_ui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/ui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    v7_ui_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_ui_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    const run_v7_ui_tests = b.addRunArtifact(v7_ui_tests);
    test_step.dependOn(&run_v7_ui_tests.step);

    const v7_svg_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/svg_xml.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    v7_svg_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_svg_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    v7_svg_tests.root_module.linkLibrary(libxml2_dep.artifact("xml2"));
    v7_svg_tests.root_module.addIncludePath(libxml2_dep.artifact("xml2").getEmittedIncludeTree());
    const run_v7_svg_tests = b.addRunArtifact(v7_svg_tests);
    test_step.dependOn(&run_v7_svg_tests.step);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    exe_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    exe_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    // ── Layout check ──────────────────────────────────────
    const layout_check_step = b.step("layout-check", "Verify the headless layout against notes/layout-golden.json");
    const layout_check_cmd = b.addRunArtifact(v7_demo);
    layout_check_cmd.addArgs(&.{ "--layout", "/tmp/layout-check.txt", "--diff", "notes/layout-golden.json" });
    layout_check_step.dependOn(&layout_check_cmd.step);

    // ── Lint step (house linters on the ACTIVE tree) ──────
    const lint_step = b.step("lint", "Run ziglint (enforced rules) + zlint on src/v7 + src/v7_demo");
    const ziglint_cmd = b.addSystemCommand(&.{
        "~/.local/bin/ziglint",
        // The only remaining findings (component.zig, documented): Z023
        // (the vtable fn-ptr contract fn(*anyopaque, Allocator) — the
        // reorder breaks the type-erased vtable) + Z030 ×2 (the
        // type-erased deinit adapter whose poison cannot compile on
        // *anyopaque, and a test struct whose assertions read the fields
        // after deinit).
        "--ignore",
        "Z023",
        "--ignore",
        "Z030",
        "src/v7",
        "src/v7_demo",
    });
    lint_step.dependOn(&ziglint_cmd.step);
    const zlint_cmd = b.addSystemCommand(&.{
        "/bin/sh", "-c", "find src/v7 src/v7_demo -name '*.zig' | ~/.local/bin/zlint -S --deny-warnings",
    });
    lint_step.dependOn(&zlint_cmd.step);
}
