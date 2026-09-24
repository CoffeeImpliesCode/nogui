//! Independent GPU-frame consumer: the default build names no host module and
//! no SDL at all.
//!
//! `-Dnative=true` additionally compiles the OPTIONAL presented arm: a real
//! owned SDL window through the public `nogui_host` module, presenting the SAME
//! specimen through `v7_frame.NativeFrame` into that window's swapchain image.
//! The default build requests the upstream `frame` product, which never fetches
//! SDL, so the windowless proof keeps no host dependency. The native build
//! requests `all`, the only product that materialises `nogui_host`.
const std = @import("std");

/// The `nogui` build graph only materialises its modules once every lazy
/// dependency the requested product needs has been fetched. On a configure pass
/// where that has not happened yet, produce no steps and let the build runner
/// fetch and re-run, instead of aborting on a missing module.
fn requireModule(dep: *std.Build.Dependency, name: []const u8) ?*std.Build.Module {
    return dep.builder.modules.get(name);
}

fn addImport(
    list: *std.ArrayList(std.Build.Module.Import),
    gpa: std.mem.Allocator,
    name: []const u8,
    module: *std.Build.Module,
) void {
    list.append(gpa, .{ .name = name, .module = module }) catch @panic("out of memory");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Explicit, and off by default: the presented arm brings a platform
    // surface, a swapchain and a live window into this executable. That is a
    // dependency the windowless proof must not acquire and a cost it must not
    // pay, so the arm is behind this option rather than behind a runtime flag
    // alone.
    const native = b.option(
        bool,
        "native",
        "Compile the optional presented arm: a real SDL window over v7_frame.NativeFrame",
    ) orelse false;
    const dep = b.dependency("nogui", .{
        .target = target,
        .optimize = optimize,
        // `all` is the only product that materialises `nogui_host`. `frame` is
        // the one that keeps SDL out of the graph entirely.
        .product = if (native) "all" else "frame",
        // The W21 AccessKit bridge is a Rust toolchain plus AT-SPI, and this
        // consumer names no accessibility API, so it is pinned OFF rather than
        // inherited. The option name is hyphenated upstream, so the field needs
        // the quoted form. A caller who wants the bridge for the host module
        // turns it on through the upstream `nogui` build instead.
        .@"accesskit-bridge" = false,
    });
    // The parent materializes modules after fetching lazy FreeType/HarfBuzz.
    const frame_mod = requireModule(dep, "v7_frame") orelse return;
    const nogui_mod = requireModule(dep, "nogui") orelse return;
    const render_mod = requireModule(dep, "v7_render") orelse return;
    const text_mod = requireModule(dep, "nogui_text") orelse return;

    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    addImport(&imports, b.allocator, "v7_frame", frame_mod);
    addImport(&imports, b.allocator, "nogui", nogui_mod);
    addImport(&imports, b.allocator, "v7_render", render_mod);
    addImport(&imports, b.allocator, "nogui_text", text_mod);

    // The public host module, which owns the window, and SDL itself, for the
    // one call that makes a Vulkan surface. Both arrive ONLY in a native build.
    if (native) {
        const host_mod = requireModule(dep, "nogui_host") orelse return;
        // `sdl3` is a LAZY dependency of `nogui`, not of this package, and a
        // lazy dependency may only be fetched through the manifest that
        // declares it. Going through the `nogui` builder is what keeps this
        // package's own manifest free of a second entry for the same package.
        //
        // The arguments are the ones the upstream build passes, and they MUST
        // stay identical: dependencies are cached by build root plus these
        // user input options, so matching them resolves the SAME SDL the host
        // module links. A second, separately built SDL in one process would be
        // two SDL runtimes. If the upstream `lazyDependency("sdl3", ...)` call
        // ever changes its arguments, this call has to change with it.
        const sdl3_dep = dep.builder.lazyDependency("sdl3", .{
            .target = target,
            .optimize = .ReleaseSafe,
        }) orelse return;
        const sdl3_mod = requireModule(sdl3_dep, "sdl3") orelse return;
        addImport(&imports, b.allocator, "nogui_host", host_mod);
        addImport(&imports, b.allocator, "sdl3", sdl3_mod);
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports.items,
    });
    exe_mod.link_libc = true; // std.DynLib opens the caller-selected Vulkan loader.

    // The one thing the source branches on. `@import("consumer_options")` is
    // always present, so a default build reads a plain `false` and never
    // resolves a host or SDL import.
    const consumer_options = b.addOptions();
    consumer_options.addOption(bool, "native", native);
    exe_mod.addOptions("consumer_options", consumer_options);

    // Test data is packaged with nogui but is not baked into its frame engine.
    const assets = b.addWriteFiles();
    _ = assets.addCopyFile(dep.path("src/InterVariable.ttf"), "InterVariable.ttf");
    _ = assets.addCopyFile(dep.path("src/DejaVuSans.ttf"), "DejaVuSans.ttf");
    const font_shim = assets.add("font_embed.zig",
        \\pub const bytes = @embedFile("InterVariable.ttf");
        \\pub const rtl_bytes = @embedFile("DejaVuSans.ttf");
        \\
    );
    exe_mod.addAnonymousImport("font_bytes", .{ .root_source_file = font_shim });

    const exe = b.addExecutable(.{ .name = "offscreen_consumer", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addFileArg(dep.path("shaders/quad_vert.spv"));
    run.addFileArg(dep.path("shaders/quad_frag.spv"));
    run.addFileArg(dep.path("shaders/sort_comp.spv"));
    if (b.args) |args| run.addArgs(args);
    const step = b.step("run", "Render one real windowless GPU frame and check text pixels");
    step.dependOn(&run.step);

    // The presented arm records a blit, so it needs two more SPIR-V modules on
    // its command line and a real display. Its own step, so `run` above stays
    // exactly the windowless invocation it has always been.
    if (native) {
        const native_run = b.addRunArtifact(exe);
        native_run.step.dependOn(b.getInstallStep());
        native_run.addFileArg(dep.path("shaders/quad_vert.spv"));
        native_run.addFileArg(dep.path("shaders/quad_frag.spv"));
        native_run.addFileArg(dep.path("shaders/sort_comp.spv"));
        native_run.addArg("--native");
        native_run.addArg("--fullscreen-vert");
        native_run.addFileArg(dep.path("shaders/fullscreen_vert.spv"));
        native_run.addArg("--blit-oklab");
        native_run.addFileArg(dep.path("shaders/blit_oklab.spv"));
        if (b.args) |args| native_run.addArgs(args);
        const native_step = b.step(
            "run-native",
            "Present the same specimen into a real window and check the pixels it drew",
        );
        native_step.dependOn(&native_run.step);
    }
}
