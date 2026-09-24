const std = @import("std");

const Product = enum { core, text, render, host, frame, all };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release_safe = std.builtin.OptimizeMode.ReleaseSafe;
    const product = b.option(Product, "product", "Build product: core, text, render, host, frame, or all") orelse .all;

    // zig-cov coverage (see zig-cov README): zig-gate --cov passes these
    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const cov_rt = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;
    const test_filter = b.option([]const u8, "test-filter", "Run tests matching a name substring");
    const test_filters: []const []const u8 = if (test_filter) |filter|
        b.allocator.dupe([]const u8, &.{filter}) catch @panic("out of memory")
    else
        &.{};
    const v7_tracy = b.option(bool, "v7-tracy", "Enable Tracy in v7-demo") orelse false;
    const v7_gpu_timestamps = b.option(bool, "v7-gpu-timestamps", "Enable v7 GPU timestamps") orelse false;
    const v7_perf_counters = b.option(bool, "v7-perf-counters", "Enable mechanism counters") orelse false;
    const accesskit_bridge = b.option(bool, "accesskit-bridge", "Build and link the W21 AccessKit bridge into the host") orelse true;
    const v7_options = b.addOptions();
    v7_options.addOption(bool, "tracy", v7_tracy);
    v7_options.addOption(bool, "gpu_timestamps", v7_gpu_timestamps);
    v7_options.addOption(bool, "perf_counters", v7_perf_counters);
    const fixture_filter = b.option([]const u8, "fixture-filter", "Run one normalized Taffy source");
    const fixture_options = b.addOptions();
    fixture_options.addOption([]const u8, "filter", fixture_filter orelse "");

    // A core consumer does not request graphical, font, SVG, or demo dependencies.
    const tracy = b.dependency("tracy", .{ .target = target, .optimize = release_safe });
    const noapi_dep = b.dependency("noapi", .{
        .target = target,
        .optimize = optimize,
        .@"library-only" = true,
    });
    const sdl3_dep = if (product == .host or product == .all)
        b.lazyDependency("sdl3", .{ .target = target, .optimize = release_safe })
    else
        null;
    // Match HarfBuzz's FreeType options so both requests share one build.
    const maybe_freetype = if (product == .text or product == .frame or product == .all)
        b.lazyDependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .@"enable-libpng" = true,
        })
    else
        null;
    const maybe_harfbuzz = if (product == .text or product == .frame or product == .all)
        b.lazyDependency("harfbuzz", .{ .target = target, .optimize = optimize })
    else
        null;
    // All requested lazy dependencies must be fetched before creating their modules.
    if ((product == .host or product == .all) and sdl3_dep == null) return;
    if ((product == .text or product == .frame or product == .all) and
        (maybe_freetype == null or maybe_harfbuzz == null)) return;
    const tracy_impl_mod = tracy.module(if (v7_tracy) "tracy_impl_enabled" else "tracy_impl_disabled");

    // ── noapi module (borrowed from dependency) ────────────
    const noapi_mod = noapi_dep.module("noapi");

    // ── nogui module ──────────────────────────────
    const mod = b.addModule("nogui", .{
        .root_source_file = b.path("src/v7/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "noapi", .module = noapi_mod },
            .{ .name = "tracy", .module = tracy.module("tracy") },
        },
    });
    mod.addOptions("v7_options", v7_options);

    // Library artifact for C dep propagation
    const lib = b.addLibrary(.{ .name = "nogui", .root_module = mod });

    const test_mod = b.addModule("nogui_test", .{
        .root_source_file = b.path("src/v7_test/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nogui", .module = mod }},
    });

    const text_mod = if (maybe_freetype) |freetype| blk: {
        const harfbuzz = maybe_harfbuzz.?;
        const module = b.addModule("nogui_text", .{
            .root_source_file = b.path("src/v7_text/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "harfbuzz", .module = harfbuzz.module("harfbuzz") },
            },
        });
        module.linkLibrary(freetype.artifact("freetype"));
        module.linkLibrary(harfbuzz.artifact("harfbuzz"));
        module.link_libc = true;
        module.linkSystemLibrary("fribidi", .{});
        module.linkSystemLibrary("utf8proc", .{});
        break :blk module;
    } else null;
    const render_mod = if (product == .render or product == .frame or product == .all)
        b.addModule("v7_render", .{
            .root_source_file = b.path("src/v7_render/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
            },
        })
    else
        null;
    // Reusable scene lowering and GPU text. This product has no SDL dependency.
    const frame_mod = if (product == .frame or product == .all) blk: {
        const module = b.addModule("v7_frame", .{
            .root_source_file = b.path("src/v7_frame/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_text", .module = text_mod.? },
                .{ .name = "v7_render", .module = render_mod.? },
                .{ .name = "harfbuzz", .module = maybe_harfbuzz.?.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
            },
        });
        module.addAnonymousImport("v7_frame_test_fonts", .{
            .root_source_file = b.path("src/v7_text/test_font_embed.zig"),
        });
        module.link_libc = true;
        break :blk module;
    } else null;
    const host_mod = if (sdl3_dep) |sdl3| b.addModule("nogui_host", .{
        .root_source_file = b.path("src/v7_host/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nogui", .module = mod },
            .{ .name = "noapi", .module = noapi_mod },
            .{ .name = "sdl3", .module = sdl3.module("sdl3") },
        },
    }) else null;
    // std.DynLib needs libc to resolve librsvg, Cairo, and libturbojpeg
    // through LD_LIBRARY_PATH instead of Zig's literal-soname ELF loader.
    if (host_mod) |module| module.link_libc = true;
    if (host_mod) |module| {
        module.addIncludePath(b.path("src/v7_host/macos/shim"));
        module.addIncludePath(b.path("src/v7_host/mobile/shim"));
        module.addIncludePath(b.path("src/v7_host/windows/native"));
        const android = target.result.os.tag == .linux and target.result.abi.isAndroid();
        if (target.result.os.tag == .macos) {
            module.addCSourceFiles(.{
                .files = &.{"src/v7_host/macos/shim/nogui_macos.m"},
                .flags = &.{ "-fobjc-arc", "-fblocks" },
            });
            for ([_][]const u8{
                "AppKit",       "ApplicationServices", "Foundation",        "CoreVideo",
                "CoreGraphics", "Security",            "UserNotifications",
            }) |framework| module.linkFramework(framework, .{});
        } else if (target.result.os.tag == .ios) {
            module.addCSourceFiles(.{
                .files = &.{"src/v7_host/mobile/shim/nogui_ios.m"},
                .flags = &.{ "-fobjc-arc", "-fblocks" },
            });
            module.linkFramework("UIKit", .{});
            module.linkFramework("Foundation", .{});
        } else if (android) {
            // The Android app must compile the matching Java provider into its APK:
            // src/v7_host/mobile/shim/NoguiAccessibilityProvider.java.
            // Keep package org.libsdl.app and its JNI method names. The consumer's
            // Gradle source set includes this directory; R8 must keep this class
            // and its members. This build links the C half, not a Java/dex toolchain.
            module.addCSourceFiles(.{
                .files = &.{"src/v7_host/mobile/shim/nogui_android.c"},
                .flags = &.{"-std=c11"},
            });
        } else if (target.result.os.tag == .windows) {
            module.addCSourceFiles(.{
                .files = &.{
                    "src/v7_host/windows/native/nogui_credui.c",
                    "src/v7_host/windows/native/nogui_toast.c",
                    "src/v7_host/windows/native/nogui_jumplist.c",
                },
                .flags = &.{"-std=c11"},
            });
            module.addCSourceFiles(.{
                .files = &.{"src/v7_host/windows/native/nogui_capture.cpp"},
                .flags = &.{ "-std=c++17", "-fexceptions" },
            });
            if (b.option([]const u8, "windows-cppwinrt-include", "Windows SDK cppwinrt include directory")) |path| {
                module.addSystemIncludePath(.{ .cwd_relative = path });
            }
            module.link_libcpp = true;
            for ([_][]const u8{
                "ole32", "shell32", "user32", "dwmapi",        "advapi32", "credui",
                "d3d11", "dxgi",    "uuid",   "runtimeobject",
            }) |library| module.linkSystemLibrary(library, .{});
        }
    }
    // ── W21 AccessKit bridge (OPTIONAL native dependency) ──
    // Only the host product has an accessibility adapter, so a core, text, or
    // render consumer never enters this block: no cargo, no header, no link.
    if (host_mod) |module| blk: {
        const bridge_options = b.addOptions();
        // The header is pure C declarations, so @cImport translates it whether
        // or not the static library is linked. The include path is therefore
        // unconditional: without it the host does not compile at all.
        module.addIncludePath(b.path("src/v7_host/accesskit_bridge/include"));
        const bridge_supported = target.result.os.tag == .macos or target.result.os.tag == .windows or
            (target.result.os.tag == .linux and !target.result.abi.isAndroid());
        // Zig's findProgram resolves symlinks, but a rustup-style shim
        // dispatches on the file name it was invoked under. Resolving turns
        // `cargo` into `rustup`, and the shim then reads `build` as a rustup
        // subcommand. Keep the bare name whenever the realpath is not a cargo
        // of its own: the child resolves it through PATH with argv[0] intact,
        // and a genuinely renamed cargo never looks at argv[0] anyway.
        const cargo = if (accesskit_bridge and bridge_supported) probe: {
            const found = b.findProgram(&.{"cargo"}, &.{}) catch break :probe @as(?[]const u8, null);
            break :probe if (std.mem.eql(u8, std.fs.path.basename(found), "cargo")) found else "cargo";
        } else null;
        if (accesskit_bridge and bridge_supported and cargo == null) std.log.warn(
            "cargo not found: the optional AccessKit bridge is unavailable in this build.",
            .{},
        );
        // `linked` is a fact about this build, never a request that was made.
        bridge_options.addOption(bool, "linked", cargo != null);
        module.addOptions("accesskit_bridge", bridge_options);
        const program = cargo orelse break :blk;
        const build_bridge = b.addSystemCommand(&.{
            program,
            "build",
            "--release",
            "--offline",
            "--manifest-path",
        });
        build_bridge.addFileArg(b.path("src/v7_host/accesskit_bridge/Cargo.toml"));
        build_bridge.setCwd(b.path("."));
        const rust_target = b.option([]const u8, "accesskit-target", "Rust target triple for the native accessibility bridge") orelse
            accesskitTargetTriple(b, target.result);
        build_bridge.addArgs(&.{ "--target", rust_target });
        // A generated archive is a module input, so downstream compiles inherit
        // its build dependency instead of relying on a checkout-local target/.
        build_bridge.addArg("--target-dir");
        const bridge_target = build_bridge.addOutputDirectoryArg("accesskit-target");
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/Cargo.lock"));
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/src/lib.rs"));
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/include/nogui_accesskit_bridge.h"));
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/src/teardown.rs"));
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/src/platform/mod.rs"));
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/src/platform/unix.rs"));
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/src/platform/macos.rs"));
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/src/platform/windows.rs"));
        // The AT-SPI adapter is a second local path dependency this bridge
        // patches in, with the same rule: every file that can change what
        // `cargo build --release` compiles has to invalidate this step, or an
        // edit to `InsertText` silently will not rebuild. Its manifest and all
        // twenty-one sources are listed; the licence files, the readme and
        // `Cargo.toml.orig` are not compile-relevant and are left out.
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/vendor/accesskit_unix/Cargo.toml"));
        for ([_][]const u8{
            "adapter",
            "context",
            "executor",
            "lib",
            "util",
        }) |stem| {
            build_bridge.addFileInput(b.path(b.fmt(
                "src/v7_host/accesskit_bridge/vendor/accesskit_unix/src/{s}.rs",
                .{stem},
            )));
        }
        for ([_][]const u8{
            "bus",
            "mod",
            "object_address",
            "object_id",
        }) |stem| {
            build_bridge.addFileInput(b.path(b.fmt(
                "src/v7_host/accesskit_bridge/vendor/accesskit_unix/src/atspi/{s}.rs",
                .{stem},
            )));
        }
        for ([_][]const u8{
            "accessible",
            "action",
            "application",
            "cache",
            "component",
            "document",
            "editable_text",
            "hyperlink",
            "mod",
            "selection",
            "text",
            "value",
        }) |stem| {
            build_bridge.addFileInput(b.path(b.fmt(
                "src/v7_host/accesskit_bridge/vendor/accesskit_unix/src/atspi/interfaces/{s}.rs",
                .{stem},
            )));
        }
        // The AT-SPI translation layer is a local path dependency that this
        // bridge patches in, so every file that can change what
        // `cargo build --release` compiles has to invalidate this step. The
        // manifest and all fourteen sources are listed; the license files and
        // the readme are not compile-relevant and are left out deliberately.
        build_bridge.addFileInput(b.path("src/v7_host/accesskit_bridge/vendor/accesskit_atspi_common/Cargo.toml"));
        for ([_][]const u8{
            "action",
            "actions",
            "adapter",
            "callback",
            "context",
            "error",
            "events",
            "filters",
            "lib",
            "node",
            "rect",
            "simplified",
            "text_attributes",
            "util",
        }) |stem| {
            build_bridge.addFileInput(b.path(b.fmt(
                "src/v7_host/accesskit_bridge/vendor/accesskit_atspi_common/src/{s}.rs",
                .{stem},
            )));
        }
        module.addObjectFile(bridge_target.path(b, b.fmt("{s}/release/{s}", .{
            rust_target,
            if (target.result.os.tag == .windows and target.result.abi == .msvc)
                "nogui_accesskit_bridge.lib"
            else
                "libnogui_accesskit_bridge.a",
        })));
        // Rust's staticlib carries the unwinder's callers but not the
        // unwinder. A C toolchain link line adds libgcc automatically; Zig's
        // driver does not, and AT-SPI needs no other C library, so this is
        // the only system library the bridge introduces. libgcc_s ships with
        // glibc, so the binary still starts on a bare runtime.
        if (target.result.os.tag == .linux) module.linkSystemLibrary("gcc_s", .{});
    }

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
    v7_tests.root_module.addOptions("v7_options", v7_options);
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
    fixture_exe.root_module.addOptions("v7_options", v7_options);
    const run_fixture = b.addRunArtifact(fixture_exe);
    const fixture_step = b.step("fixture", "Run the fixture oracle");
    fixture_step.dependOn(&run_fixture.step);
    // ── Compile-only check ────────────────────────
    // Keep this step free of addRunArtifact dependencies: it validates every
    // executable, library, and test binary without executing any of them.
    const check_step = b.step("check", "Compile all targets without running them");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&fixture_exe.step);
    check_step.dependOn(&v7_tests.step);
    const context_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = test_mod,
    });
    if (coverage) {
        context_tests.use_llvm = true;
        context_tests.root_module.fuzz = true;
        context_tests.root_module.link_libc = true;
        if (cov_rt) |p| context_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_context_tests = b.addRunArtifact(context_tests);
    test_step.dependOn(&run_context_tests.step);
    check_step.dependOn(&context_tests.step);
    // ── Lint step (house linters on the ACTIVE tree) ──────
    const lint_step = b.step("lint", "Run ziglint (enforced rules) + zlint on active source");
    const ziglint = b.findProgram(&.{"ziglint"}, &.{}) catch "ziglint";
    const ziglint_cmd = b.addSystemCommand(&.{
        ziglint,
        "src/v7",
        "src/v7_demo",
        "src/v7_render",
        "src/v7_frame",
        "src/v7_text",
        "src/v7_host",
    });
    lint_step.dependOn(&ziglint_cmd.step);
    const zlint = b.findProgram(&.{"zlint"}, &.{}) catch "zlint";
    const find = b.findProgram(&.{"find"}, &.{}) catch "find";
    const grep = b.findProgram(&.{"grep"}, &.{}) catch "grep";
    const lint_sources = b.addSystemCommand(&.{
        find,
        "src/v7",
        "src/v7_demo",
        "src/v7_render",
        "src/v7_frame",
        "src/v7_text",
        "src/v7_host",
        "-type",
        "f",
        "-name",
        "*.zig",
    });
    // Directory contents are not Run-step inputs; discover added files on every invocation.
    lint_sources.has_side_effects = true;
    const lint_source_list = lint_sources.captureStdOut(.{});
    // zlint's directory arguments are not recursive in the packaged release.
    // Feed it the explicit file list and fail if enumeration is empty.
    const lint_source_nonempty = b.addSystemCommand(&.{ grep, "-q", "." });
    lint_source_nonempty.setStdIn(.{ .lazy_path = lint_source_list });
    lint_step.dependOn(&lint_source_nonempty.step);
    const zlint_cmd = b.addSystemCommand(&.{
        zlint,
        "-S",
        "--deny-warnings",
    });
    zlint_cmd.setStdIn(.{ .lazy_path = lint_source_list });
    lint_step.dependOn(&zlint_cmd.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // Register each available library's behavioral tests for its product and all.
    for ([_]Product{ .text, .render, .host, .frame }) |test_product| {
        if (product != .all and product != test_product) continue;

        const library_test_mod = switch (test_product) {
            .text => text_mod.?,
            .render => render_mod.?,
            .host => host_mod.?,
            .frame => frame_mod.?,
            else => unreachable,
        };
        const library_tests = b.addTest(.{
            .filters = test_filters,
            .root_module = library_test_mod,
        });
        if (coverage) {
            library_tests.use_llvm = true;
            library_tests.root_module.fuzz = true;
            library_tests.root_module.link_libc = true;
            if (cov_rt) |p| library_tests.root_module.addObjectFile(.{ .cwd_relative = p });
        }
        const run_library_tests = b.addRunArtifact(library_tests);
        test_step.dependOn(&run_library_tests.step);
        check_step.dependOn(&library_tests.step);
    }

    // The remaining core-only parity examples. Each is its own executable with
    // its own `run-parity-<name>` step, and its own test artifact wired into
    // the project test step: an example's `test` blocks only run under an
    // artifact rooted at that example, never under src/v7/root.zig.
    for ([_]struct { name: []const u8, source: []const u8, description: []const u8 }{
        .{
            .name = "virtual-feed",
            .source = "examples/parity/virtual_feed.zig",
            .description = "Run the virtualized mixed-height feed example",
        },
        .{
            .name = "uniform-feed",
            .source = "examples/parity/uniform_feed.zig",
            .description = "Run the uniform virtualized list example",
        },
        .{
            .name = "query-consumer",
            .source = "examples/parity/query_consumer.zig",
            .description = "Run the container-query width-branch consumer",
        },
    }) |example| {
        const example_exe = b.addExecutable(.{
            .name = b.fmt("parity-{s}", .{example.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "nogui", .module = mod }},
            }),
        });
        const example_run = b.addRunArtifact(example_exe);
        const example_step = b.step(
            b.fmt("run-parity-{s}", .{example.name}),
            example.description,
        );
        example_step.dependOn(&example_run.step);
        const example_tests = b.addTest(.{
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "nogui", .module = mod }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
        check_step.dependOn(&example_exe.step);
        check_step.dependOn(&example_tests.step);
    }

    if (text_mod) |cpu_text| {
        const real_context_tests = b.addTest(.{
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/v7_test/text_context_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nogui", .module = mod },
                    .{ .name = "nogui_test", .module = test_mod },
                    .{ .name = "nogui_text", .module = cpu_text },
                },
            }),
        });
        real_context_tests.root_module.addAnonymousImport("context_test_fonts", .{
            .root_source_file = b.path("src/v7_text/test_font_embed.zig"),
        });
        test_step.dependOn(&b.addRunArtifact(real_context_tests).step);
        check_step.dependOn(&real_context_tests.step);
    }

    // Selected library products keep the core test, fixture, lint, and docs steps.
    // Only the all product configures the demo, media, and XML products below.
    if (product != .all) {
        b.installArtifact(lib);
        if (product != .core) {
            const selected_mod = switch (product) {
                .text => text_mod.?,
                .render => render_mod.?,
                .host => host_mod.?,
                .frame => frame_mod.?,
                else => unreachable,
            };
            const name: []const u8 = switch (product) {
                .text => "nogui_text",
                .render => "v7_render",
                .host => "nogui_host",
                .frame => "v7_frame",
                else => unreachable,
            };
            const selected_lib = b.addLibrary(.{ .name = name, .root_module = selected_mod });
            b.installArtifact(selected_lib);
            check_step.dependOn(&selected_lib.step);

            const selected_docs = b.addInstallDirectory(.{
                .source_dir = selected_lib.getEmittedDocs(),
                .install_dir = .prefix,
                .install_subdir = b.fmt("docs/{s}", .{@tagName(product)}),
            });
            docs_step.dependOn(&selected_docs.step);
        }
        return;
    }

    const sdl3 = sdl3_dep.?;
    const freetype_dep = maybe_freetype.?;
    const harfbuzz_dep = maybe_harfbuzz.?;
    const v7_render_mod = render_mod.?;
    const nogui_text_mod = text_mod.?;
    const nogui_host_mod = host_mod.?;
    const parity_font_assets = b.addWriteFiles();
    _ = parity_font_assets.addCopyFile(b.path("src/InterVariable.ttf"), "InterVariable.ttf");
    const parity_font_shim = parity_font_assets.add("font_embed.zig",
        \\pub const bytes = @embedFile("InterVariable.ttf");
        \\
    );
    // These consumers share pinned-font geometry across window-free and
    // presented paths. Keep their native dependencies in the all product.
    var parity_native_runs: [2]*std.Build.Step.Run = undefined;
    for ([_]struct { name: []const u8, source: []const u8, description: []const u8 }{
        .{
            .name = "shared-model",
            .source = "examples/parity/shared_model.zig",
            .description = "Exercise the shared model through two independent window-free views",
        },
        .{
            .name = "text-field",
            .source = "examples/parity/text_field.zig",
            .description = "Exercise editable text through the real-font window-free path",
        },
    }, 0..) |example, example_index| {
        const example_exe = b.addExecutable(.{
            .name = b.fmt("parity-{s}", .{example.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "nogui", .module = mod },
                    .{ .name = "nogui_host", .module = nogui_host_mod },
                    .{ .name = "nogui_text", .module = nogui_text_mod },
                    .{ .name = "v7_frame", .module = frame_mod.? },
                    .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                },
            }),
        });
        example_exe.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
        const example_run = b.addRunArtifact(example_exe);
        if (b.args) |args| example_run.addArgs(args);
        const native_run = b.addRunArtifact(example_exe);
        parity_native_runs[example_index] = native_run;
        native_run.addArg("--native");
        native_run.addArg("--quad-vert");
        native_run.addFileArg(b.path("shaders/quad_vert.spv"));
        native_run.addArg("--quad-frag");
        native_run.addFileArg(b.path("shaders/quad_frag.spv"));
        native_run.addArg("--sort-comp");
        native_run.addFileArg(b.path("shaders/sort_comp.spv"));
        native_run.addArg("--fullscreen-vert");
        native_run.addFileArg(b.path("shaders/fullscreen_vert.spv"));
        native_run.addArg("--blit-oklab");
        native_run.addFileArg(b.path("shaders/blit_oklab.spv"));
        if (b.args) |args| native_run.addArgs(args);
        b.step(
            b.fmt("run-parity-{s}-native", .{example.name}),
            b.fmt("Present the {s} consumer through the native host", .{example.name}),
        ).dependOn(&native_run.step);
        const example_step = b.step(b.fmt("run-parity-{s}", .{example.name}), example.description);
        example_step.dependOn(&example_run.step);
        const example_tests = b.addTest(.{
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "nogui", .module = mod },
                    .{ .name = "nogui_host", .module = nogui_host_mod },
                    .{ .name = "nogui_text", .module = nogui_text_mod },
                    .{ .name = "v7_frame", .module = frame_mod.? },
                    .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                },
            }),
        });
        example_tests.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
        check_step.dependOn(&example_exe.step);
        check_step.dependOn(&example_tests.step);
    }

    // The menu/overlay example needs nogui_host for `menus`, so it is
    // configured only in the full product, beside the other host consumers.
    const menu_overlay_example = b.addExecutable(.{
        .name = "parity-menu-overlay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parity/menu_overlay.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    menu_overlay_example.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
    const menu_overlay_run = b.addRunArtifact(menu_overlay_example);
    if (b.args) |args| menu_overlay_run.addArgs(args);
    const menu_overlay_step = b.step("run-parity-menu-overlay", "Run the menu, overlay and drag example");
    menu_overlay_step.dependOn(&menu_overlay_run.step);

    // Both list paths use the public frame adapter; the default has no window.
    // --native presents the same scene using the window's observed geometry.
    const list_live_example = b.addExecutable(.{
        .name = "parity-list-live",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parity/list_live.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    list_live_example.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
    const list_live_run = b.addRunArtifact(list_live_example);
    list_live_run.addFileArg(b.path("shaders/quad_vert.spv"));
    list_live_run.addFileArg(b.path("shaders/quad_frag.spv"));
    list_live_run.addFileArg(b.path("shaders/sort_comp.spv"));
    if (b.args) |args| list_live_run.addArgs(args);
    const list_live_step = b.step(
        "run-parity-list-live",
        "Render and exercise the two windowless virtualized lists",
    );
    list_live_step.dependOn(&list_live_run.step);
    const list_live_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parity/list_live.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    list_live_tests.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
    test_step.dependOn(&b.addRunArtifact(list_live_tests).step);
    check_step.dependOn(&list_live_example.step);
    check_step.dependOn(&list_live_tests.step);

    const canvas_example = b.addExecutable(.{
        .name = "parity-canvas-view",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parity/canvas_view.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    canvas_example.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
    const canvas_run = b.addRunArtifact(canvas_example);
    const canvas_native_run = b.addRunArtifact(canvas_example);
    const canvas_structural_run = b.addRunArtifact(canvas_example);
    for ([_]*std.Build.Step.Run{ canvas_run, canvas_native_run }) |run_canvas| {
        run_canvas.addFileArg(b.path("shaders/quad_vert.spv"));
        run_canvas.addFileArg(b.path("shaders/quad_frag.spv"));
        run_canvas.addFileArg(b.path("shaders/sort_comp.spv"));
        run_canvas.addArg("--fullscreen-vert");
        run_canvas.addFileArg(b.path("shaders/fullscreen_vert.spv"));
        run_canvas.addArg("--blit-oklab");
        run_canvas.addFileArg(b.path("shaders/blit_oklab.spv"));
        if (b.args) |args| run_canvas.addArgs(args);
    }
    canvas_native_run.addArg("--native");
    canvas_structural_run.addArg("--structural");
    if (b.args) |args| canvas_structural_run.addArgs(args);
    b.step("run-parity-canvas-view", "Render the bound image/SVG canvas without a window").dependOn(&canvas_run.step);
    b.step("run-parity-canvas-view-native", "Present the bound image/SVG canvas through the native host").dependOn(&canvas_native_run.step);
    b.step("run-parity-canvas-view-structural", "Exercise canvas records without a device or pixels").dependOn(&canvas_structural_run.step);
    const canvas_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parity/canvas_view.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    canvas_tests.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
    test_step.dependOn(&b.addRunArtifact(canvas_tests).step);
    check_step.dependOn(&canvas_example.step);
    check_step.dependOn(&canvas_tests.step);

    const test_context_example = b.addExecutable(.{
        .name = "parity-test-context",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parity/test_context.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_text", .module = nogui_text_mod },
                .{ .name = "nogui_test", .module = test_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "v7_render", .module = v7_render_mod },
            },
        }),
    });
    test_context_example.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
    const test_context_run = b.addRunArtifact(test_context_example);
    test_context_run.addFileArg(b.path("shaders/quad_vert.spv"));
    test_context_run.addFileArg(b.path("shaders/quad_frag.spv"));
    test_context_run.addFileArg(b.path("shaders/sort_comp.spv"));
    b.step("run-parity-test-context", "Exercise public real-font/windowless GPU test contexts").dependOn(&test_context_run.step);
    check_step.dependOn(&test_context_example.step);

    const state_pair_example = b.addExecutable(.{
        .name = "parity-state-pair",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parity/state_pair.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    state_pair_example.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
    const state_pair_run = b.addRunArtifact(state_pair_example);
    const state_pair_native_run = b.addRunArtifact(state_pair_example);
    for ([_]*std.Build.Step.Run{ state_pair_run, state_pair_native_run }) |run_pair| {
        run_pair.addFileArg(b.path("shaders/quad_vert.spv"));
        run_pair.addFileArg(b.path("shaders/quad_frag.spv"));
        run_pair.addFileArg(b.path("shaders/sort_comp.spv"));
        run_pair.addArg("--fullscreen-vert");
        run_pair.addFileArg(b.path("shaders/fullscreen_vert.spv"));
        run_pair.addArg("--blit-oklab");
        run_pair.addFileArg(b.path("shaders/blit_oklab.spv"));
        if (b.args) |args| run_pair.addArgs(args);
    }
    state_pair_native_run.addArg("--native");
    b.step("run-parity-state-pair", "Run the real-text windowless state comparison arm").dependOn(&state_pair_run.step);
    b.step("run-parity-state-pair-native", "Present the same state scenario through the native host").dependOn(
        &state_pair_native_run.step,
    );
    check_step.dependOn(&state_pair_example.step);
    const menu_overlay_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parity/menu_overlay.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    menu_overlay_tests.root_module.addAnonymousImport("font_bytes", .{ .root_source_file = parity_font_shim });
    test_step.dependOn(&b.addRunArtifact(menu_overlay_tests).step);
    check_step.dependOn(&menu_overlay_example.step);
    check_step.dependOn(&menu_overlay_tests.step);

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
    exe.root_module.addOptions("v7_options", v7_options);
    exe.root_module.linkLibrary(lib);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

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
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_test", .module = test_mod },
                .{ .name = "nogui_text", .module = nogui_text_mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy_impl_mod },
            },
        }),
        // The LLVM codegen backend: the tracy client's stack capture +
        // symbolication depend on the LLVM-emitted debug info (the native
        // backend's DWARF is incomplete).
        .use_llvm = true,
    });
    v7_demo.root_module.addOptions("v7_options", v7_options);
    v7_demo.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    v7_demo.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
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

    // Compile the demo shaders into Zig's cache, then update the runtime
    // SPIR-V only when an input changes. The v7, Spotify, and calculator
    // run steps depend on this update, including v7's headless default.
    // Test and lint do not require slangc; check includes shader-backed smoke builds.
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
    list_live_run.step.dependOn(&shader_updates.step);
    menu_overlay_run.step.dependOn(&shader_updates.step);
    state_pair_run.step.dependOn(&shader_updates.step);
    state_pair_native_run.step.dependOn(&shader_updates.step);
    for (parity_native_runs) |native_run| native_run.step.dependOn(&shader_updates.step);
    canvas_run.step.dependOn(&shader_updates.step);
    canvas_native_run.step.dependOn(&shader_updates.step);
    test_context_run.step.dependOn(&shader_updates.step);

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

    const w09_controls_smoke = b.addExecutable(.{
        .name = "w09-controls-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w09_controls_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "nogui_text", .module = nogui_text_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "v7_frame", .module = frame_mod.? },
            },
        }),
    });
    w09_controls_smoke.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    w09_controls_smoke.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    const w09_controls_run = b.addRunArtifact(w09_controls_smoke);
    w09_controls_run.step.dependOn(&shader_updates.step);
    if (b.args) |args| w09_controls_run.addArgs(args);
    const w09_controls_step = b.step("w09-controls-smoke", "Run the headless or native Todo control lifecycle smoke");
    w09_controls_step.dependOn(&w09_controls_run.step);
    check_step.dependOn(&w09_controls_smoke.step);

    // ── W07 native host smoke ─────────────────────
    // A NEW smoke binary, not a demo mode: it exists so the W07 host gate can
    // be exercised on a real display server (two live windows, one shared
    // model, external loop, close veto) without changing any demo mode's
    // single-window shape.
    const w07_smoke = b.addExecutable(.{
        .name = "w07-host-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w07_host_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "v7_render", .module = render_mod.? },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "nogui_text", .module = nogui_text_mod },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
            },
        }),
    });
    w07_smoke.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    w07_smoke.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    const w07_smoke_run = b.addRunArtifact(w07_smoke);
    w07_smoke_run.step.dependOn(&shader_updates.step);
    const w07_smoke_step = b.step("w07-host-smoke", "Run the W07 two-window native host smoke");
    w07_smoke_step.dependOn(&w07_smoke_run.step);
    if (b.args) |args| w07_smoke_run.addArgs(args);
    check_step.dependOn(&w07_smoke.step);

    // ── W22 Wayland layer-shell smoke ─────────────
    // A NEW smoke binary, not a demo mode: it drives the real
    // zwlr_layer_shell_v1 protocol on the session's own compositor (probe,
    // attach, configure, ack, buffer, close) and then opens an ordinary
    // toplevel in the same process as the control.
    const w22_layer_smoke = b.addExecutable(.{
        .name = "w22-layer-shell-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w22_layer_shell_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    const w22_layer_run = b.addRunArtifact(w22_layer_smoke);
    const w22_layer_step = b.step(
        "w22-layer-shell-smoke",
        "Run the W22 real Wayland layer-shell smoke",
    );
    w22_layer_step.dependOn(&w22_layer_run.step);
    if (b.args) |args| w22_layer_run.addArgs(args);
    // Compiled by the headless check, run only by its own step: the smoke
    // needs a live compositor.
    check_step.dependOn(&w22_layer_smoke.step);

    // ── W22 native popup smoke ────────────────────
    // A NEW smoke binary, not a demo mode: `w22-layer-shell-smoke` drives
    // zwlr_layer_shell_v1, which has no X11 counterpart at all. This one
    // drives the other W22 half, `linux.popup_real`, which has a real X11
    // branch, so "can this driver make a popup role at all?" is answered by a
    // run rather than by reading the adapter.
    const w22_popup_smoke = b.addExecutable(.{
        .name = "w22-popup-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w22_popup_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    const w22_popup_run = b.addRunArtifact(w22_popup_smoke);
    const w22_popup_step = b.step(
        "w22-popup-smoke",
        "Run the windowless popup refusal (--native for a real buffer)",
    );
    w22_popup_step.dependOn(&w22_popup_run.step);
    if (b.args) |args| w22_popup_run.addArgs(args);
    // Default: windowless refusal. --native requires a display server and GPU.
    check_step.dependOn(&w22_popup_smoke.step);

    const w10_keyboard_smoke = b.addExecutable(.{
        .name = "w10-keyboard-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w10_keyboard_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    const w10_keyboard_run = b.addRunArtifact(w10_keyboard_smoke);
    const w10_keyboard_step = b.step(
        "w10-keyboard-smoke",
        "Probe keyboard/cursor services (private X11 driver optional)",
    );
    w10_keyboard_step.dependOn(&w10_keyboard_run.step);
    if (b.args) |args| w10_keyboard_run.addArgs(args);
    check_step.dependOn(&w10_keyboard_smoke.step);

    const w17_anim_smoke = b.addExecutable(.{
        .name = "w17-anim-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w17_anim_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
            },
        }),
    });
    w17_anim_smoke.step.dependOn(&shader_updates.step);
    const w17_anim_run = b.addRunArtifact(w17_anim_smoke);
    const w17_anim_step = b.step("w17-anim-smoke", "Run the W17 authored-animation and reduced-motion host smoke");
    w17_anim_step.dependOn(&w17_anim_run.step);
    if (b.args) |args| w17_anim_run.addArgs(args);
    check_step.dependOn(&w17_anim_smoke.step);

    const w14_asset_app = b.addExecutable(.{
        .name = "w14-asset-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w14_asset_app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "v7_render", .module = render_mod.? },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    const w14_asset_run = b.addRunArtifact(w14_asset_app);
    w14_asset_run.step.dependOn(&shader_updates.step);
    const w14_asset_step = b.step("w14-asset-smoke", "Run the W14 asset and rendered-image smoke");
    w14_asset_step.dependOn(&w14_asset_run.step);
    if (b.args) |args| w14_asset_run.addArgs(args);
    check_step.dependOn(&w14_asset_app.step);

    // ── W24 inspector interaction smoke ─────────────
    // A NEW smoke binary, not a demo mode: no demo mode mounts an Inspector,
    // drives `App.handle` with a real pointer event, or runs the bounded
    // collectors against a real display server. It exists so the W24
    // interaction half can be observed on the session's own compositor.
    // ── W18 desktop-services smoke ─────────────
    // A NEW smoke binary: no demo mode opens a file dialog, probes the portal
    // provider-unavailable path, or drives the no-session-bus child.
    // Native arms stay off without their approval flags. The default run opens
    // no window and mutates no clipboard.
    const w18_dialog_smoke = b.addExecutable(.{
        .name = "w18-dialog-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w18_dialog_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    const w18_dialog_run = b.addRunArtifact(w18_dialog_smoke);
    const w18_dialog_step = b.step(
        "w18-dialog-smoke",
        "Run W18 refusal smoke; real dialogs need --authorize-dialog-round-trip and exact --dialog-scope",
    );
    w18_dialog_step.dependOn(&w18_dialog_run.step);
    if (b.args) |args| w18_dialog_run.addArgs(args);
    // Compiled by the headless check, run only by its own step. Clipboard and
    // real-dialog arms need their separate explicit approval flags.
    check_step.dependOn(&w18_dialog_smoke.step);

    for ([_]struct { name: []const u8, source: []const u8, description: []const u8 }{
        .{
            .name = "w19-service-smoke",
            .source = "src/v7_demo/w19_service_smoke.zig",
            .description = "Report W19 capabilities; native actions require exact authorization",
        },
        .{
            .name = "w20-capture-smoke",
            .source = "src/v7_demo/w20_capture_smoke.zig",
            .description = "Report W20 capabilities; capture requires explicit interactive approval",
        },
    }) |smoke| {
        const artifact = b.addExecutable(.{
            .name = smoke.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(smoke.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "nogui_host", .module = nogui_host_mod }},
            }),
        });
        const run = b.addRunArtifact(artifact);
        if (b.args) |args| run.addArgs(args);
        b.step(smoke.name, smoke.description).dependOn(&run.step);
        check_step.dependOn(&artifact.step);
        const smoke_tests = b.addTest(.{
            .filters = test_filters,
            .root_module = artifact.root_module,
        });
        test_step.dependOn(&b.addRunArtifact(smoke_tests).step);
        check_step.dependOn(&smoke_tests.step);
    }

    const w16_paint_smoke = b.addExecutable(.{
        .name = "w16-paint-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w16_paint_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "v7_render", .module = render_mod.? },
                .{ .name = "v7_frame", .module = frame_mod.? },
            },
        }),
    });
    w16_paint_smoke.step.dependOn(&shader_updates.step);
    const w16_paint_run = b.addRunArtifact(w16_paint_smoke);
    if (b.args) |args| w16_paint_run.addArgs(args);
    b.step("w16-paint-smoke", "Check overlay paint bands with real GPU pixels").dependOn(&w16_paint_run.step);
    check_step.dependOn(&w16_paint_smoke.step);

    const w24_inspector_smoke = b.addExecutable(.{
        .name = "w24-inspector-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w24_inspector_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                // The inspector smoke renders the inspected scene through the
                // public renderer, so the pixels it inspects are real ones.
                .{ .name = "v7_render", .module = render_mod.? },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    w24_inspector_smoke.step.dependOn(&shader_updates.step);
    const w24_inspector_run = b.addRunArtifact(w24_inspector_smoke);
    const w24_inspector_step = b.step(
        "w24-inspector-smoke",
        "Run the W24 headless inspector interaction smoke",
    );
    w24_inspector_step.dependOn(&w24_inspector_run.step);
    if (b.args) |args| w24_inspector_run.addArgs(args);
    // The default run is headless. Native presentation requires --native.
    check_step.dependOn(&w24_inspector_smoke.step);

    // ── W24 performance-recorder paired benchmark ─────────────
    // A NEW benchmark binary, not a demo mode: the demo's perf flags
    // describe ONE run, so nothing in it can repeat a configuration or
    // interleave two arms. It exists to run the existing recorder
    // (`src/v7_demo/perf.zig` through `window.zig`) twice per pair index
    // and report the paired distributions.
    const w24_perf_bench = b.addExecutable(.{
        .name = "w24-perf-pair-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w24_perf_pair_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_text", .module = nogui_text_mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
            },
        }),
        .use_llvm = true,
    });
    w24_perf_bench.root_module.addOptions("v7_options", v7_options);
    w24_perf_bench.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    w24_perf_bench.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    w24_perf_bench.root_module.linkSystemLibrary("avformat", .{});
    w24_perf_bench.root_module.linkSystemLibrary("avcodec", .{});
    w24_perf_bench.root_module.linkSystemLibrary("avutil", .{});
    w24_perf_bench.root_module.linkSystemLibrary("swresample", .{});
    w24_perf_bench.root_module.linkSystemLibrary("swscale", .{});
    const w24_perf_run = b.addRunArtifact(w24_perf_bench);
    const w24_perf_step = b.step(
        "w24-perf-pair-bench",
        "Run the W24 performance-recorder paired benchmark",
    );
    w24_perf_step.dependOn(&w24_perf_run.step);
    if (b.args) |args| w24_perf_run.addArgs(args);
    // Compiled by the headless check, run only by its own step: the
    // benchmark needs a live GPU and takes minutes by design.
    check_step.dependOn(&w24_perf_bench.step);
    // ── W21 semantic/accessibility smoke ────────────────
    // Default: headless model/action gate. --native publishes the same tree
    // through AccessKit on a real toplevel for an external AT-SPI client.
    const w21_atspi_smoke = b.addExecutable(.{
        .name = "w21-atspi-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w21_atspi_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "v7_frame", .module = frame_mod.? },
            },
        }),
    });
    w21_atspi_smoke.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    w21_atspi_smoke.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    // The W21 native run is launched by the W21 AT-SPI controller, which gates
    // on `zig-out/bin/w21-atspi-smoke` existing before it will start anything.
    // Without this install link the gate can never be satisfied and no real
    // reader run can happen, so the artifact is installed like every other
    // executable this build produces.
    b.installArtifact(w21_atspi_smoke);
    const w21_atspi_run = b.addRunArtifact(w21_atspi_smoke);
    w21_atspi_run.step.dependOn(&shader_updates.step);
    const w21_smoke_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = w21_atspi_smoke.root_module,
    });
    test_step.dependOn(&b.addRunArtifact(w21_smoke_tests).step);
    check_step.dependOn(&w21_smoke_tests.step);
    const w21_atspi_step = b.step(
        "w21-atspi-smoke",
        "Run the W21 headless semantic gate (--native for AT-SPI)",
    );
    w21_atspi_step.dependOn(&w21_atspi_run.step);
    if (b.args) |args| w21_atspi_run.addArgs(args);
    // The default is headless; native registry/screen-reader checks are opt-in.
    check_step.dependOn(&w21_atspi_smoke.step);
    const w23_diagnostics_smoke = b.addExecutable(.{
        .name = "w23-diagnostics-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w23_diagnostics_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "nogui_host", .module = nogui_host_mod },
            },
        }),
    });
    const w23_diagnostics_run = b.addRunArtifact(w23_diagnostics_smoke);
    const w23_diagnostics_step = b.step(
        "w23-diagnostics-smoke",
        "Report real windowless GPU metadata",
    );
    w23_diagnostics_step.dependOn(&w23_diagnostics_run.step);
    check_step.dependOn(&w23_diagnostics_smoke.step);
    const w12_ime_smoke = b.addExecutable(.{
        .name = "w12-ime-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w12_ime_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "nogui_text", .module = nogui_text_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "v7_render", .module = render_mod.? },
                .{ .name = "noapi", .module = noapi_mod },
            },
        }),
    });
    w12_ime_smoke.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    w12_ime_smoke.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    const w12_ime_run = b.addRunArtifact(w12_ime_smoke);
    w12_ime_run.step.dependOn(&shader_updates.step);
    const w12_ime_step = b.step(
        "w12-ime-smoke",
        "Exercise SDL dummy text-input lifecycle with synthetic events",
    );
    w12_ime_step.dependOn(&w12_ime_run.step);
    if (b.args) |args| w12_ime_run.addArgs(args);
    check_step.dependOn(&w12_ime_smoke.step);

    for ([_]struct { name: []const u8, source: []const u8, description: []const u8 }{
        .{
            .name = "w23-macos-smoke",
            .source = "src/v7_demo/w23_macos_smoke.zig",
            .description = "Exercise macOS native consumers with explicit action scopes",
        },
        .{
            .name = "w23-windows-smoke",
            .source = "src/v7_demo/w23_windows_smoke.zig",
            .description = "Exercise Windows native consumers with explicit action scopes",
        },
        .{
            .name = "w23-mobile-smoke",
            .source = "src/v7_demo/w23_mobile_smoke.zig",
            .description = "Exercise native mobile lifecycle, text and semantics",
        },
    }) |smoke| {
        const artifact = b.addExecutable(.{
            .name = smoke.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(smoke.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nogui", .module = mod },
                    .{ .name = "nogui_host", .module = nogui_host_mod },
                    .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                    .{ .name = "nogui_text", .module = nogui_text_mod },
                    .{ .name = "v7_frame", .module = frame_mod.? },
                    .{ .name = "v7_render", .module = render_mod.? },
                    .{ .name = "noapi", .module = noapi_mod },
                },
            }),
        });
        artifact.root_module.linkLibrary(freetype_dep.artifact("freetype"));
        artifact.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
        if (target.result.os.tag == .ios and std.mem.eql(u8, smoke.name, "w23-mobile-smoke")) {
            artifact.root_module.addCSourceFiles(.{
                .files = &.{"src/v7_demo/w23_mobile_probe.m"},
                .flags = &.{ "-fobjc-arc", "-fblocks" },
            });
            artifact.root_module.linkFramework("UIKit", .{});
            artifact.root_module.linkFramework("Foundation", .{});
        }
        const run = b.addRunArtifact(artifact);
        run.step.dependOn(&shader_updates.step);
        if (b.args) |args| run.addArgs(args);
        const step = b.step(smoke.name, smoke.description);
        step.dependOn(&run.step);
        const compile_step = b.step(
            b.fmt("{s}-check", .{smoke.name}),
            b.fmt("Compile {s} without launching a native process", .{smoke.name}),
        );
        compile_step.dependOn(&artifact.step);
        check_step.dependOn(&artifact.step);
        if (std.mem.eql(u8, smoke.name, "w23-windows-smoke")) {
            artifact.root_module.addImport("nogui_test", test_mod);
            const consumer_tests = b.addTest(.{
                .root_module = artifact.root_module,
                .filters = test_filters,
            });
            const run_consumer_tests = b.addRunArtifact(consumer_tests);
            test_step.dependOn(&run_consumer_tests.step);
            check_step.dependOn(&consumer_tests.step);
            const field_test_step = b.step(
                "w23-windows-field-test",
                "Exercise Windows consumer field logic with real fonts, without native Windows claims",
            );
            field_test_step.dependOn(&run_consumer_tests.step);
        }
        if (std.mem.eql(u8, smoke.name, "w23-mobile-smoke")) {
            const mobile_tests = b.addTest(.{
                .root_module = artifact.root_module,
                .filters = test_filters,
            });
            const run_mobile_tests = b.addRunArtifact(mobile_tests);
            test_step.dependOn(&run_mobile_tests.step);
            check_step.dependOn(&mobile_tests.step);
            b.step(
                "w23-mobile-field-test",
                "Exercise mobile consumer field logic without native Android or iOS claims",
            ).dependOn(&run_mobile_tests.step);
        }
    }

    const w13_canvas_smoke = b.addExecutable(.{
        .name = "w13-canvas-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/w13_canvas_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "nogui", .module = mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    w13_canvas_smoke.step.dependOn(&shader_updates.step);
    const w13_canvas_run = b.addRunArtifact(w13_canvas_smoke);
    const w13_canvas_step = b.step("w13-canvas-smoke", "Run the windowless paint pixel specimen");
    w13_canvas_step.dependOn(&w13_canvas_run.step);
    if (b.args) |args| w13_canvas_run.addArgs(args);
    check_step.dependOn(&w13_canvas_smoke.step);
    const exe_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "v7_render", .module = v7_render_mod },
                .{ .name = "v7_frame", .module = frame_mod.? },
                .{ .name = "nogui", .module = mod },
                .{ .name = "nogui_test", .module = test_mod },
                .{ .name = "nogui_text", .module = nogui_text_mod },
                .{ .name = "nogui_host", .module = nogui_host_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "harfbuzz", .module = harfbuzz_dep.module("harfbuzz") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy.module("tracy_impl_disabled") },
            },
        }),
    });
    exe_tests.root_module.addOptions("v7_options", v7_options);
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

    check_step.dependOn(&exe.step);
    check_step.dependOn(&v7_demo.step);
    check_step.dependOn(&exe_tests.step);

    // ── Layout check ──────────────────────────────
    const layout_check_step = b.step("layout-check", "Verify the headless layout against testdata/layout-golden.json");
    const layout_check_cmd = b.addRunArtifact(v7_demo);
    layout_check_cmd.addArgs(&.{ "--layout", "/tmp/layout-check.txt", "--diff", "testdata/layout-golden.json" });
    layout_check_step.dependOn(&layout_check_cmd.step);

    // Golden updates are explicit and never part of the verification gate.
    const layout_update_step = b.step("layout-update", "Regenerate testdata/layout-golden.json");
    const layout_update_cmd = b.addRunArtifact(v7_demo);
    layout_update_cmd.addArgs(&.{ "--layout", "/tmp/layout-update.txt", "--write-golden", "testdata/layout-golden.json" });
    layout_update_step.dependOn(&layout_update_cmd.step);
}

fn accesskitTargetTriple(b: *std.Build, target: std.Target) []const u8 {
    const arch: []const u8 = switch (target.cpu.arch) {
        .x86 => "i686",
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "armv7",
        .riscv64 => "riscv64gc",
        else => @tagName(target.cpu.arch),
    };
    const platform: []const u8 = switch (target.os.tag) {
        .macos => "apple-darwin",
        .windows => switch (target.abi) {
            .msvc => "pc-windows-msvc",
            else => "pc-windows-gnu",
        },
        .linux => switch (target.abi) {
            .musl => "unknown-linux-musl",
            .gnueabihf => "unknown-linux-gnueabihf",
            .musleabihf => "unknown-linux-musleabihf",
            else => "unknown-linux-gnu",
        },
        else => unreachable,
    };
    return b.fmt("{s}-{s}", .{ arch, platform });
}
