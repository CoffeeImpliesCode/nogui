const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release_safe = std.builtin.OptimizeMode.ReleaseSafe;

    // zig-cov coverage (see zig-cov README): zig-gate --cov passes these
    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const cov_rt = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;
    const test_filter = b.option([]const u8, "test-filter", "Run tests matching a name substring");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const fixture_filter = b.option([]const u8, "fixture-filter", "Run one normalized Taffy source");
    const fixture_options = b.addOptions();
    fixture_options.addOption([]const u8, "filter", fixture_filter orelse "");

    // ── Dependencies ──────────────────────────────
    const sdl3 = b.dependency("sdl3", .{ .target = target, .optimize = release_safe });
    const tracy = b.dependency("tracy", .{ .target = target, .optimize = release_safe });
    const noapi_dep = b.dependency("noapi", .{ .target = target, .optimize = optimize });
    const freetype_dep = b.dependency("freetype", .{ .target = target, .optimize = optimize });
    const harfbuzz_dep = b.dependency("harfbuzz", .{ .target = target, .optimize = optimize });
    const libxml2_dep = b.dependency("libxml2", .{ .target = target, .optimize = optimize });

    // ── noapi module (borrowed from dependency) ────────────
    const noapi_mod = noapi_dep.module("noapi");
    // ── v7 renderer module ──────────────────────────
    const v7_render_mod = b.addModule("v7_render", .{
        .root_source_file = b.path("src/v7_render/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "noapi", .module = noapi_mod },
        },
    });

    // ── nogui module ──────────────────────────────
    const mod = b.addModule("nogui", .{
        .root_source_file = b.path("src/v7/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "noapi", .module = noapi_mod },
            .{ .name = "tracy", .module = tracy.module("tracy") },
        },
    });

    // Library artifact for C dep propagation
    const lib = b.addLibrary(.{ .name = "nogui", .root_module = mod });

    // ── Executable ───────────────────────────────
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

    // ── Storage-image isolation probe ───────────────────────
    // TEMP: standalone compute → storage-image write probe (probe_main.zig
    // + shaders/storage_probe.comp.slang). Prints three readback pixels:
    // (0.25,0.75,0.5,1.0) → the noapi storage-image write works in
    // isolation; (0,0,0,0) → the noapi storage-image path is broken.

    // ── v7 demo executable ────────────────────────────
    const v7_demo = b.addExecutable(.{
        .name = "v7-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "nogui", .module = mod },
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
    v7_demo.root_module.linkSystemLibrary("avformat", .{});
    v7_demo.root_module.linkSystemLibrary("avcodec", .{});
    v7_demo.root_module.linkSystemLibrary("avutil", .{});
    v7_demo.root_module.linkSystemLibrary("swresample", .{});
    v7_demo.root_module.linkSystemLibrary("swscale", .{});
    b.installArtifact(v7_demo);

    const v7_run_cmd = b.addRunArtifact(v7_demo);
    const v7_run_step = b.step("v7", "Run the v7 demo");
    v7_run_step.dependOn(&v7_run_cmd.step);
    v7_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| v7_run_cmd.addArgs(args);

    // Compile the demo shaders into Zig's cache, then update the committed
    // runtime paths only when an input changes. Declared inputs and outputs
    // make warm runs incremental while preventing stale SPIR-V binaries.
    // These steps remain exclusive to the interactive demos because slangc
    // is not guaranteed to be available to test/check/lint gates.
    const Shader = struct {
        source: []const u8,
        output: []const u8,
        imports: []const []const u8 = &.{},
    };
    const shaders = [_]Shader{
        .{
            .source = "shaders/quad_frag.slang",
            .output = "quad_frag.spv",
            .imports = &.{
                "shaders/lib/color.slang",
                "shaders/lib/coord.slang",
                "shaders/lib/coverage.slang",
            },
        },
        .{ .source = "shaders/quad_vert.slang", .output = "quad_vert.spv" },
        .{
            .source = "shaders/blit_oklab.slang",
            .output = "blit_oklab.spv",
            .imports = &.{"shaders/lib/color.slang"},
        },
        .{ .source = "shaders/fullscreen_vert.slang", .output = "fullscreen_vert.spv" },
        .{
            .source = "shaders/mandelbrot.comp.slang",
            .output = "mandelbrot_comp.spv",
            .imports = &.{"shaders/lib/color.slang"},
        },
        .{ .source = "shaders/sort.comp.slang", .output = "sort_comp.spv" },
    };
    const shader_updates = b.addUpdateSourceFiles();
    for (shaders) |shader| {
        const compile_shader = b.addSystemCommand(&.{
            "slangc", "-target", "spirv", "-I", "shaders", "-o",
        });
        const emitted_spv = compile_shader.addOutputFileArg(shader.output);
        compile_shader.addFileArg(b.path(shader.source));
        for (shader.imports) |import| compile_shader.addFileInput(b.path(import));
        shader_updates.addCopyFileToSource(emitted_spv, b.fmt("shaders/{s}", .{shader.output}));
    }
    v7_run_cmd.step.dependOn(&shader_updates.step);

    // The Spotify scene reuses the v7 renderer and differs only in its root
    // component. Keeping this as a separate run step makes the stress scene
    // easy to launch without duplicating the GPU/window backend.
    const spotify_run_cmd = b.addRunArtifact(v7_demo);
    spotify_run_cmd.addArgs(&.{"--spotify"});
    spotify_run_cmd.step.dependOn(b.getInstallStep());
    spotify_run_cmd.step.dependOn(&shader_updates.step);
    if (b.args) |args| spotify_run_cmd.addArgs(args);
    const spotify_run_step = b.step("spotify", "Run the Spotify UI stress scene");
    spotify_run_step.dependOn(&spotify_run_cmd.step);

    // The calculator demo: the small API-showcase component (buttons,
    // labels, cards, click routing) in its own window.
    const calculator_run_cmd = b.addRunArtifact(v7_demo);
    calculator_run_cmd.addArgs(&.{"--calculator"});
    calculator_run_cmd.step.dependOn(b.getInstallStep());
    calculator_run_cmd.step.dependOn(&shader_updates.step);
    if (b.args) |args| calculator_run_cmd.addArgs(args);
    const calculator_run_step = b.step("calculator", "Run the calculator demo");
    calculator_run_step.dependOn(&calculator_run_cmd.step);

    // ── Tests ────────────────────────────────
    const v7_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    v7_tests.root_module.addOptions("fixture_options", fixture_options);
    if (coverage) {
        v7_tests.use_llvm = true; // required: only the LLVM backend emits sancov counters
        v7_tests.root_module.fuzz = true; // emits __sancov_cntrs + __sancov_pcs1
        v7_tests.root_module.link_libc = true; // atexit handler writes the .zcov
        if (cov_rt) |p| v7_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_v7_tests = b.addRunArtifact(v7_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_v7_tests.step);

    const fixture_exe = b.addExecutable(.{
        .name = "fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7/fixture_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    fixture_exe.root_module.addOptions("fixture_options", fixture_options);
    const run_fixture = b.addRunArtifact(fixture_exe);
    const fixture_step = b.step("fixture", "Run the fixture oracle");
    fixture_step.dependOn(&run_fixture.step);

    const v7_text_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/text.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    v7_text_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_text_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    if (coverage) {
        v7_text_tests.use_llvm = true; // required: only the LLVM backend emits sancov counters
        v7_text_tests.root_module.fuzz = true; // emits __sancov_cntrs + __sancov_pcs1
        v7_text_tests.root_module.link_libc = true; // atexit handler writes the .zcov
        if (cov_rt) |p| v7_text_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_v7_text_tests = b.addRunArtifact(v7_text_tests);
    test_step.dependOn(&run_v7_text_tests.step);

    const v7_ui_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/ui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    v7_ui_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_ui_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    if (coverage) {
        v7_ui_tests.use_llvm = true; // required: only the LLVM backend emits sancov counters
        v7_ui_tests.root_module.fuzz = true; // emits __sancov_cntrs + __sancov_pcs1
        v7_ui_tests.root_module.link_libc = true; // atexit handler writes the .zcov
        if (cov_rt) |p| v7_ui_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_v7_ui_tests = b.addRunArtifact(v7_ui_tests);
    test_step.dependOn(&run_v7_ui_tests.step);

    const v7_spotify_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/spotify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    v7_spotify_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_spotify_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    if (coverage) {
        v7_spotify_tests.use_llvm = true;
        v7_spotify_tests.root_module.fuzz = true;
        v7_spotify_tests.root_module.link_libc = true;
        if (cov_rt) |p| v7_spotify_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_v7_spotify_tests = b.addRunArtifact(v7_spotify_tests);
    test_step.dependOn(&run_v7_spotify_tests.step);

    const v7_calculator_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/calculator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    v7_calculator_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_calculator_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    if (coverage) {
        v7_calculator_tests.use_llvm = true;
        v7_calculator_tests.root_module.fuzz = true;
        v7_calculator_tests.root_module.link_libc = true;
        if (cov_rt) |p| v7_calculator_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_v7_calculator_tests = b.addRunArtifact(v7_calculator_tests);
    test_step.dependOn(&run_v7_calculator_tests.step);

    const v7_svg_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/svg_xml.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
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
    if (coverage) {
        v7_svg_tests.use_llvm = true; // required: only the LLVM backend emits sancov counters
        v7_svg_tests.root_module.fuzz = true; // emits __sancov_cntrs + __sancov_pcs1
        v7_svg_tests.root_module.link_libc = true; // atexit handler writes the .zcov
        if (cov_rt) |p| v7_svg_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_v7_svg_tests = b.addRunArtifact(v7_svg_tests);
    test_step.dependOn(&run_v7_svg_tests.step);

    const exe_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    exe_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    exe_tests.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    exe_tests.root_module.linkSystemLibrary("avformat", .{});
    exe_tests.root_module.linkSystemLibrary("avcodec", .{});
    exe_tests.root_module.linkSystemLibrary("avutil", .{});
    exe_tests.root_module.linkSystemLibrary("swresample", .{});
    exe_tests.root_module.linkSystemLibrary("swscale", .{});
    if (coverage) {
        exe_tests.use_llvm = true; // required: only the LLVM backend emits sancov counters
        exe_tests.root_module.fuzz = true; // emits __sancov_cntrs + __sancov_pcs1
        exe_tests.root_module.link_libc = true; // atexit handler writes the .zcov
        if (cov_rt) |p| exe_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    // ── Layout check ──────────────────────────────
    const layout_check_step = b.step("layout-check", "Verify the headless layout against notes/layout-golden.json");
    const layout_check_cmd = b.addRunArtifact(v7_demo);
    layout_check_cmd.addArgs(&.{ "--layout", "/tmp/layout-check.txt", "--diff", "notes/layout-golden.json" });
    layout_check_step.dependOn(&layout_check_cmd.step);

    // ── Lint step (house linters on the ACTIVE tree) ──────
    const lint_step = b.step("lint", "Run ziglint (enforced rules) + zlint on src/v7 + src/v7_demo");
    const ziglint_cmd = b.addSystemCommand(&.{
        "~/.local/bin/ziglint",
        "src/v7",
        "src/v7_demo",
    });
    lint_step.dependOn(&ziglint_cmd.step);
    const zlint_cmd = b.addSystemCommand(&.{
        "/bin/sh", "-c", "find src/v7 src/v7_demo -name '*.zig' | ~/.local/bin/zlint -S --deny-warnings",
    });
    lint_step.dependOn(&zlint_cmd.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
