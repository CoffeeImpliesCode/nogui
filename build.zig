const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release_safe = std.builtin.OptimizeMode.ReleaseSafe;

    // zig-cov instrumentation (see https://github.com/ericsssan/zcov):
    // `zig-cov test` passes these options; without them the build is unchanged.
    const coverage = b.option(bool, "coverage", "Instrument tests with zig-cov") orelse false;
    const coverage_rt = b.option([]const u8, "coverage-rt", "Path to zig-cov-rt.o") orelse null;

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
    // Each test target gets its own module instance so zig-cov
    // instrumentation (rt object + fuzz/llvm flags) never lands on
    // a module shared with a production artifact or another test —
    // sharing would link zig-cov-rt.o twice and fail with
    // "duplicate symbol: zig_cov_ctor".
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
            },
        }),
    });
    if (coverage) instrument(mod_tests, coverage_rt);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const proto_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proto.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    if (coverage) instrument(proto_tests, coverage_rt);
    const run_proto_tests = b.addRunArtifact(proto_tests);

    const exe_tests = b.addTest(.{
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
    if (coverage) instrument(exe_tests, coverage_rt);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_proto_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ── Check step ─────────────────────────────────────────
    const check_step = b.step("check", "Quick errors only");
    check_step.dependOn(&exe.step);

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

    // ── v7 prototype (pure Zig core; demo-side window backend) ──
    const v7_mod = b.addModule("v7", .{
        .root_source_file = b.path("src/v7/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const v7_demo = b.addExecutable(.{
        .name = "v7-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    v7_demo.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    b.installArtifact(v7_demo);

    const v7_run_step = b.step("v7", "Run the v7 demo (add -- --window for graphical mode)");
    const v7_run_cmd = b.addRunArtifact(v7_demo);
    v7_run_step.dependOn(&v7_run_cmd.step);
    v7_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| v7_run_cmd.addArgs(args);

    // Headless layout check: layout one frame with the CPU measure, verify
    // invariants, and diff the rect fingerprint against the golden. Fails
    // (non-zero) on any violation or layout drift — CI-gateable.
    const layout_check_step = b.step("layout-check", "Verify the headless layout against notes/layout-golden.json");
    const layout_check_cmd = b.addRunArtifact(v7_demo);
    layout_check_cmd.addArgs(&.{ "--layout", "/tmp/v7-layout-check.txt", "--diff", "notes/layout-golden.json" });
    layout_check_cmd.step.dependOn(b.getInstallStep());
    layout_check_step.dependOn(&layout_check_cmd.step);

    const v7_tests = b.addTest(.{ .root_module = v7_mod });
    const run_v7_tests = b.addRunArtifact(v7_tests);
    test_step.dependOn(&run_v7_tests.step);

    const v7_text_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/text.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = noapi_mod },
            },
        }),
    });
    v7_text_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    const run_v7_text_tests = b.addRunArtifact(v7_text_tests);
    test_step.dependOn(&run_v7_text_tests.step);

    const v7_ui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/v7_demo/ui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    v7_ui_tests.root_module.linkLibrary(freetype_dep.artifact("freetype"));
    const run_v7_ui_tests = b.addRunArtifact(v7_ui_tests);
    test_step.dependOn(&run_v7_ui_tests.step);

    check_step.dependOn(&v7_demo.step);

    // ── Lint step (house linters on the ACTIVE tree) ───────
    // ziglint: enforced rules only — the pre-existing style debt
    // (Z004/Z020/Z024/Z006/Z023) and Z030 (poison-as-last-statement, house
    // exclusion: proven write-through-freed-memory) are documented debt,
    // see AGENTS.md. zlint: every finding fails the step (--deny-warnings).
    // src/proto/* is prototype debt — excluded from the gate.
    const lint_step = b.step("lint", "Run ziglint (enforced rules) + zlint on src/v7 + src/v7_demo");
    const ziglint_cmd = b.addSystemCommand(&.{
        "~/.local/bin/ziglint",
        "--ignore",
        "Z004",
        "--ignore",
        "Z020",
        "--ignore",
        "Z024",
        "--ignore",
        "Z006",
        "--ignore",
        "Z023",
        "--ignore",
        "Z030",
        "src/v7",
        "src/v7_demo",
    });
    lint_step.dependOn(&ziglint_cmd.step);
    const zlint_cmd = b.addSystemCommand(&.{
        "/bin/sh",                                                                                 "-c",
        "find src/v7 src/v7_demo -name '*.zig' | ~/.local/bin/zlint -S --deny-warnings",
    });
    lint_step.dependOn(&zlint_cmd.step);
}

/// Apply zig-cov instrumentation to a test binary:
///   * use_llvm: coverage instrumentation is only emitted by the LLVM backend
///   * fuzz: emits inline 8-bit counters and the PC table zig-cov reads
///   * link_libc: the runtime writes its .zcov from a libc atexit handler
fn instrument(compile: *std.Build.Step.Compile, rt_path: ?[]const u8) void {
    compile.use_llvm = true;
    compile.root_module.fuzz = true;
    compile.root_module.link_libc = true;
    if (rt_path) |p| compile.root_module.addObjectFile(.{ .cwd_relative = p });
}
