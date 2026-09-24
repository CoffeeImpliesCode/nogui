//! Two live virtualized lists, and the pixels their frames actually produce.
//!
//! The list widgets are driven the way a host drives them: a uniform list of
//! 200,000 records and a mixed-height list of 20,000, side by side, laid out,
//! scrolled and mutated through `App` frames while both lists are away from
//! the top. What it drives, in order, asserting after every step:
//!
//!   1. A first frame at a requested 900x600: built rows and requested bytes
//!      for both.
//!   2. A scroll of both lists through their stable handles.
//!   3. A RESIZE WHILE SCROLLED, down to a requested 640x280: fewer rows, same
//!      records. The frame is laid out in whatever the viewport really became.
//!   4. An INSERT above the viewport of the mixed list: the anchor follows
//!      its key to its new index, and the same key is on screen where it was.
//!   5. A REMEASURE of a row above the viewport: the anchor key holds and its
//!      screen offset is unchanged.
//!   6. END FOLLOW across appends: the newest row is in view, built, and
//!      INKED in the pixels at the bottom of the viewport.
//!   7. FOCUS REMOVAL: a focused row that scrolls out of the built range is
//!      blurred, because a widget that is not built cannot take the focus ring.
//!   8. The TWO-FRAME LIFETIME: the previous committed tree is still readable
//!      after the next frame commits, with its own geometry intact.
//!   9. REAL VISIBLE ROWS, twice over. `nogui.drawcmd.collectDrawCmds` walks
//!      the committed tree and every built row contributes painted geometry
//!      inside its own list. Then the tree is LOWERED AND DRAWN, and the
//!      pixels read back are checked row by row: the box a row laid out for
//!      itself is on the framebuffer in that row's own fill, the box its text
//!      was measured into is not that fill, and the rest of the row is
//!      neither. A row that only exists in the tree fails this.
//!
//! The render path is the public one, not demo code, and which half of it runs
//! is `--native`'s to choose. Nothing here imports `v7_demo`.
//!
//!   * DEFAULT: `v7_frame` lowers the committed tree (`scene.buildFrameScene`)
//!     and records it (`scene.recordFrameScene`) into a windowless
//!     `v7_frame.Offscreen` target with the shared text engine, then reads the
//!     Oklab pixels back out of that same submission. No window is opened, no
//!     surface exists and SDL is never started, so the run needs no display at
//!     all: `SDL_VIDEODRIVER=dummy` works and so does having no session.
//!   * `--native`: the SAME lowering and the SAME text engine, over
//!     `v7_frame.NativeFrame`, into a real window's swapchain image — one Oklab
//!     pass, the Oklab-to-sRGB blit that pass is sampled by, then the present.
//!     The readback comes out of the Oklab target those passes wrote, so every
//!     pixel reported below is one the PRESENTED frame drew.
//!
//! ONE model, ONE scenario, ONE row check for both modes. The lists, the
//! scrolling, the resize, the insert, the remeasure, the end follow and the
//! row-by-row pixel probe are the same code; only the four calls that reach
//! the GPU differ, and the App registers exactly one endpoint either way: the
//! one the chosen path owns.
//!
//! The presented path lays every frame out in the geometry the WINDOW reports,
//! never in the size that was requested for it. A compositor that refuses a
//! resize leaves the viewport where it was, and the run then reports the
//! geometry it observed rather than the one it asked for.
//!
//! The canvas behind the two lists paints NOTHING, so the Oklab clear the pass
//! clears to is the background every row is read against, and any painted
//! pixel in the frame belongs to a row or to its text.
//!
//! Run it: `zig build run-parity-list-live -- <vert.spv> <frag.spv> <sort.spv>`.
//! Add `--ppm PATH` to write the last frame as a P6 PPM, `--native` for the
//! real-window variant. `--native` records a blit too, and reads those two
//! modules from `shaders/fullscreen_vert.spv` and `shaders/blit_oklab.spv`
//! unless `--fullscreen-vert PATH` / `--blit-oklab PATH` name them instead.
const std = @import("std");
const sdl3 = @import("sdl3");

const nogui = @import("nogui");
const host = @import("nogui_host");
// `v7_frame_mod`/`renderer`, not `frame`/`render`: this file has a `frame`
// method and a `render` method, and a shorter alias would be ambiguous.
const v7_frame_mod = @import("v7_frame");
const renderer = @import("v7_render");
const font_bytes = @import("font_bytes").bytes;

const NativeFrame = v7_frame_mod.NativeFrame;
const noapi = v7_frame_mod.noapi;
const list = nogui.list;
const uniform_list = nogui.uniform_list;
const paint = nogui.paint;
const virtual_list = nogui.virtual_list;
const drawcmd = nogui.drawcmd;
const App = nogui.App;
const DrawCtx = nogui.DrawCtx;
const Session = nogui.Session;
const ScrollState = nogui.ScrollState;
const AllocationCounter = nogui.virtual_list.AllocationCounter;
const FrameOutput = nogui.FrameOutput;
const FrameNodeId = nogui.FrameNodeId;
const Rect = nogui.Rect;
const WidgetTree = nogui.WidgetTree;
const Size = nogui.window_contract.Size;
const WindowSize = nogui.geometry.WindowSize;
const PixelScale = nogui.geometry.PixelScale;

/// The two client sizes this run asks for. They are REQUESTS: the presented
/// path lays the frame out in whatever the window observed, and reports that
/// instead when the two disagree.
const first_width: u32 = 900;
const first_height: u32 = 600;
const resized_width: u32 = 640;
const resized_height: u32 = 280;
/// Compositor round trips spent waiting for a requested resize to land, and
/// acquires spent waiting for a swapchain that was out of date. Both are
/// bounds, not timeouts a run may quietly grow past.
const resize_polls: u32 = 16;
const acquire_polls: u32 = 8;

const window_title = "nogui virtualized lists";

const uniform_row: f64 = 18;
const uniform_count: usize = 200_000;
const variable_count: usize = 20_000;
const overdraw_items: usize = 1;
const app_id: [:0]const u8 = "dev.nogui.examples.parity.list-live";

/// A generated model: a count, and the key of row 0. 200,000 records cost one
/// usize, which is the point of testing frame cost against the viewport.
pub const Model = struct {
    count: usize,
    first_key: u64 = 1,

    pub fn keyAt(self: *const Model, index: usize) u64 {
        return self.first_key + @as(u64, @intCast(index));
    }

    pub fn find(self: *const Model, key: u64) ?usize {
        if (key < self.first_key) return null;
        const index = key - self.first_key;
        return if (index < self.count) @intCast(index) else null;
    }

    pub fn keys(self: *const Model) uniform_list.Keys {
        return .{ .context = @constCast(self), .at = keyAtCallback, .find = findCallback };
    }
};

fn keyAtCallback(raw: *anyopaque, index: usize) u64 {
    const self: *const Model = @ptrCast(@alignCast(raw));
    return self.keyAt(index);
}

fn findCallback(raw: *anyopaque, key: u64) ?usize {
    const self: *const Model = @ptrCast(@alignCast(raw));
    return self.find(key);
}

/// What one frame built, and the geometry the widget gave each row.
pub const RowLog = struct {
    count: usize = 0,
    first_key: ?u64 = null,
    last_key: ?u64 = null,
    /// The model index and the height the widget laid this row out with.
    indices: [256]usize = undefined,
    heights: [256]f64 = undefined,
    /// The node each row got, so a check can read the row's geometry back out
    /// of the committed tree instead of trusting the numbers the builder saw.
    nodes: [256]FrameNodeId = undefined,
    used: usize = 0,
    fail_after: ?usize = null,
    /// Row text is drawn, so the row is not an empty box.
    labels: usize = 0,

    pub fn reset(self: *RowLog) void {
        self.* = .{};
    }

    pub fn note(self: *RowLog, item: uniform_list.Item, node: FrameNodeId) void {
        if (self.used < self.indices.len) {
            self.indices[self.used] = item.index;
            self.heights[self.used] = item.height;
            self.nodes[self.used] = node;
            self.used += 1;
        }
        if (self.first_key == null) self.first_key = item.key;
        self.last_key = item.key;
        self.count += 1;
    }
};

/// The row builder. Every built row gets a real node with real geometry, and a
/// real label, so the committed tree has something a renderer can draw.
pub const RowBuilder = struct {
    log: *RowLog,

    pub fn build(self: *RowBuilder, item: uniform_list.Item, ctx: *DrawCtx) !void {
        if (self.log.fail_after) |limit| {
            if (self.log.count >= limit) return error.RowBuildRefused;
        }
        const text = try std.fmt.allocPrint(ctx.arena, "row {d}", .{item.key});
        const node = try ctx.label(.{ .text = text, .height = @as(f32, @floatCast(item.height)) });
        self.log.note(item, node);
        self.log.labels += 1;
    }
};

/// The root component: one row, two lists, each half the window wide.
pub const LiveView = struct {
    const Self = @This();
    uniform_model: *Model,
    variable_model: *Model,
    uniform_state: *uniform_list.State,
    variable_state: *list.State,
    uniform_scroll: *ScrollState,
    variable_scroll: *ScrollState,
    uniform_log: *RowLog,
    variable_log: *RowLog,
    uniform_builder: *RowBuilder,
    variable_builder: *RowBuilder,
    list_width: f32 = 400,
    list_height: f32 = 500,

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        // The canvas paints NOTHING, on purpose. A container would otherwise
        // cover the whole viewport in its own fill, and then every non-clear
        // pixel in the frame would belong to this layout scaffolding rather
        // than to a list row. Transparent makes the readback unambiguous:
        // whatever is not the Oklab clear came out of a row.
        _ = try ctx.row(.{
            .width = .{ .length = self.list_width * 2 + 20 },
            .height = .{ .length = self.list_height },
            .fill = paint.Color{ .srgb = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        });
        _ = try virtual_list.uniformList(
            RowBuilder,
            ctx,
            self.uniform_state,
            self.uniform_model.keys(),
            self.uniform_builder,
            .{
                .key = @as(nogui.ComponentKey, .{ .static = "uniform" }),
                .scroll_state = self.uniform_scroll,
                .width = .{ .length = self.list_width },
                .height = .{ .length = self.list_height },
            },
        );
        _ = try virtual_list.variableList(
            RowBuilder,
            ctx,
            self.variable_state,
            self.variable_model.keys(),
            self.variable_builder,
            .{
                .key = @as(nogui.ComponentKey, .{ .static = "variable" }),
                .scroll_state = self.variable_scroll,
                .width = .{ .length = self.list_width },
                .height = .{ .length = self.list_height },
            },
        );
        ctx.pop();
    }
};

/// The two extra SPIR-V modules the PRESENTED path records with: the
/// fullscreen vertex stage and the Oklab-to-sRGB fragment stage its final blit
/// samples the Oklab target through. Only `--native` loads them; the windowless
/// path presents nothing and has no blit.
const BlitShaders = struct {
    fullscreen: []const u32,
    oklab: []const u32,
};

/// The three SPIR-V modules the batched quad pipeline draws with. The words
/// borrow the loaded files, which the caller keeps alive.
const Shaders = struct {
    vert: []const u32,
    frag: []const u32,
    sort: []const u32,
};

/// A loaded SPIR-V module: the bytes, and the u32 view the GPU wants.
const ShaderFile = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ShaderFile {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Which pipeline this run paints through. `--native` picks `presented`; the
/// default is `windowless`, which opens no window and makes no surface.
pub const Mode = enum { windowless, presented };

/// The frame pipeline, in the two forms the two modes need.
///
/// The caller owns the SPIR-V and the font. This owns the GPU objects, the
/// per-frame scratch, and — in the presented form — the window, the device and
/// the surface. The App mounts exactly one endpoint, `endpoint()`, which is
/// the one this path owns, and detaches from it before any device-side
/// resource goes.
///
/// It lives behind a pointer because the scene scratch, the endpoint and the
/// noapi state all hold addresses into it. It is never moved.
pub const Painter = struct {
    pub const Path = union(enum) {
        windowless: Windowless,
        presented: Presented,
    };

    pub const Options = struct {
        mode: Mode,
        /// The three modules the batched quad pipeline draws with. Both paths
        /// record with them.
        shaders: Shaders,
        /// The presented path's blit pair. `init` copies the words into shader
        /// objects, so they need not outlive it.
        blit: BlitShaders,
        /// The App the window belongs to. A host window owns exactly one App,
        /// so the presented path opens its window against this one and the
        /// windowless path ignores both.
        app: *App,
        session: *Session,
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    mode: Mode,
    path: Path,
    /// The Oklab pixels of the last submission. The readback buffer is reused,
    /// so these die at the next render.
    pixels: []const f32 = &.{},
    /// The device extent those pixels are: the offscreen target's own size, or
    /// the swapchain image the presented passes wrote.
    extent: noapi.Extent2D = .{ .width = 0, .height = 0 },
    /// What the App lays the next frame out in, and the observed device pixels
    /// per logical unit. The windowless path answers its own request and is
    /// 1:1 by construction; the presented path answers the WINDOW.
    logical: WindowSize = .{ .width = 1, .height = 1 },
    scale: PixelScale = .{ .x = 1, .y = 1 },
    /// Frames this painter submitted and read back.
    submitted: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Painter.Options) !*Painter {
        const self = try gpa.create(Painter);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .mode = options.mode,
            .path = undefined,
            .submitted = 0,
        };
        // Both paths initialise IN PLACE: the scene scratch borrows the
        // renderer, the renderer borrows the device, and a moved copy would
        // leave every one of them holding the address of the original.
        switch (options.mode) {
            .windowless => {
                self.path = .{ .windowless = undefined };
                try self.path.windowless.init(gpa, io, options.shaders);
            },
            .presented => {
                self.path = .{ .presented = undefined };
                try self.path.presented.init(gpa, io, options);
            },
        }
        return self;
    }

    /// The App must already have detached from `endpoint()`.
    pub fn deinit(self: *Painter) void {
        switch (self.path) {
            .windowless => |*w| w.deinit(),
            .presented => |*p| p.deinit(self.gpa),
        }
        self.gpa.destroy(self);
    }

    /// The one endpoint the App mounts: this path's own.
    pub fn endpoint(self: *Painter) *nogui.GpuEndpoint {
        return switch (self.path) {
            .windowless => |*w| w.offscreen.endpoint(),
            .presented => |*p| p.adapter.gpuEndpoint(),
        };
    }

    /// The measure source this painter's OWN text engine provides, on either
    /// path. The App holds the value; there is no scope to enter and no
    /// ambient engine, so a measured label and a painted glyph are one
    /// measurement whichever path this run took.
    pub fn measurer(self: *Painter) nogui.layout.MeasureSource {
        return switch (self.path) {
            .windowless => |*w| w.text.measurer(),
            .presented => |*p| p.adapter.measurer(),
        };
    }

    /// Glyph slots the engine rasterized into, whichever engine this is.
    pub fn glyphSlots(self: *Painter) u32 {
        return switch (self.path) {
            .windowless => |*w| w.text.glyphSlotCount(),
            .presented => |*p| p.adapter.textEngine().glyphSlotCount(),
        };
    }

    /// Ask for a client size and take the viewport that answers it. In the
    /// windowless path the request IS the answer: the offscreen target follows
    /// it and the scale is 1:1. In the presented path the request goes to the
    /// window, the compositor answers, and what is stored afterwards is what
    /// the window OBSERVED — never what was asked for.
    pub fn requestViewport(self: *Painter, size: Size) !void {
        switch (self.path) {
            .windowless => {
                self.extent = .{ .width = size.width, .height = size.height };
                self.logical = .{
                    .width = @floatFromInt(size.width),
                    .height = @floatFromInt(size.height),
                };
                self.scale = .{ .x = 1, .y = 1 };
            },
            .presented => |*p| {
                const observed = try p.requestViewport(size);
                self.logical = observed.logical;
                self.scale = observed.scale;
            },
        }
    }

    /// Open the recording this frame is built in. Every frame this program
    /// builds is recorded: `App` refuses a GPU frame that is not the active
    /// recording of the endpoint it was handed.
    pub fn beginFrame(self: *Painter) !void {
        self.pixels = &.{};
        switch (self.path) {
            .windowless => |*w| try w.beginFrame(self.extent),
            .presented => |*p| {
                try p.beginFrame(self.logical, self.scale);
                // Both passes size themselves to the image the driver handed
                // out, so that image — not the requested window pixel size —
                // is what the readback is measured against.
                self.extent = p.frame.image;
            },
        }
    }

    /// The recording `App` builds this frame in.
    pub fn gpuFrame(self: *Painter) *nogui.GpuFrame {
        return switch (self.path) {
            .windowless => |*w| &w.gpu_frame,
            .presented => |*p| &p.frame.gpu_frame,
        };
    }

    /// Lower the committed tree, record it, submit it, and read the Oklab
    /// pixels back out of the target those passes wrote.
    pub fn render(self: *Painter, output: *const FrameOutput) !void {
        self.pixels = switch (self.path) {
            .windowless => |*w| try w.render(output),
            .presented => |*p| try p.render(output),
        };
        self.submitted += 1;
    }

    /// Discard a recording whose frame failed before the submission. Cheap and
    /// terminal either way, so a caller may also run it from an errdefer.
    pub fn cancelFrame(self: *Painter) void {
        switch (self.path) {
            .windowless => |*w| w.cancelFrame(),
            .presented => |*p| p.adapter.cancelFrame(&p.frame) catch |err| switch (err) {
                error.FrameNotRecording => {},
                else => @panic("list-live presented recording cancellation failed"),
            },
        }
    }

    /// What the presented path observed about its own presentation, or null in
    /// the windowless path, which presents nothing and counts nothing.
    pub fn presentation(self: *const Painter) ?NativeFrame.Stats {
        return switch (self.path) {
            .windowless => null,
            .presented => |p| p.adapter.stats,
        };
    }

    /// Acquires the presented path's swapchain refused, or zero in the
    /// windowless path, which acquires nothing.
    pub fn acquireRetries(self: *const Painter) u32 {
        return switch (self.path) {
            .windowless => 0,
            .presented => |p| p.retries,
        };
    }

    /// What the real window reports about itself, or null in the windowless
    /// path: there is no window there, and saying so is the honest report.
    pub const WindowState = struct {
        driver: [:0]const u8,
        logical: Size,
        device: noapi.Extent2D,
        visible: bool,
    };

    pub fn windowState(self: *const Painter) ?WindowState {
        return switch (self.path) {
            .windowless => null,
            .presented => |p| .{
                .driver = p.driver,
                .logical = p.managed.observed.size,
                .device = .{
                    .width = p.managed.observed.pixels.width,
                    .height = p.managed.observed.pixels.height,
                },
                .visible = p.managed.observed.visible,
            },
        };
    }

    /// The windowless pipeline: the shared `v7_frame` scene lowering and text
    /// engine over a `v7_frame.Offscreen` target. No window, no surface, no
    /// swapchain and no present.
    const Windowless = struct {
        loader: v7_frame_mod.SystemVulkanLoader,
        offscreen: v7_frame_mod.Offscreen,
        text: v7_frame_mod.TextEngine,
        gui: renderer.Renderer,
        scratch: v7_frame_mod.scene.SceneScratch,
        cmd: noapi.CommandBuffer = undefined,
        gpu_frame: nogui.GpuFrame = undefined,
        frame_index: u32 = 0,

        fn init(self: *Windowless, gpa: std.mem.Allocator, io: std.Io, shaders: Shaders) !void {
            // The loader stays open until every GPU made from its options is gone.
            self.loader = try v7_frame_mod.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.offscreen = try v7_frame_mod.Offscreen.init(.{
                .allocator = gpa,
                .io = io,
                .loader = self.loader.options(),
                .extent = .{ .width = first_width, .height = first_height },
                .app_name = "nogui-list-live",
            });
            errdefer self.offscreen.deinit();
            self.text = try v7_frame_mod.TextEngine.init(gpa, self.offscreen.gpu(), &.{
                .{ .family = "InterVariable", .bytes = font_bytes },
            });
            errdefer self.text.deinit();
            try self.text.setGlyphSlotLimit(v7_frame_mod.scene.glyph_material_ceiling);
            self.gui = try renderer.Renderer.init(
                self.offscreen.gpu(),
                shaders.vert,
                shaders.frag,
                shaders.sort,
            );
            errdefer self.gui.deinit();
            self.gui.configure(.{ .material_bda = self.text.materialBda() });
            self.scratch = v7_frame_mod.scene.SceneScratch.init(gpa, &self.gui);
            self.frame_index = 0;
        }

        fn deinit(self: *Windowless) void {
            self.scratch.deinit();
            self.gui.deinit();
            self.text.deinit();
            self.offscreen.deinit();
            self.loader.close();
        }

        fn beginFrame(self: *Windowless, extent: noapi.Extent2D) !void {
            try self.offscreen.resize(extent);
            try self.offscreen.beginFrame(self.frame_index, &self.cmd, &self.gpu_frame);
            self.frame_index = (self.frame_index + 1) %
                @as(u32, self.offscreen.gpu().frames_in_flight);
        }

        /// This is the whole submission stage: the same lowering and the same
        /// record the presented path uses, with no window in sight.
        fn render(self: *Windowless, output: *const FrameOutput) ![]const f32 {
            errdefer self.cancelFrame();
            self.scratch.beginFrame();
            var painted = try v7_frame_mod.scene.buildFrameScene(
                &self.scratch,
                &self.text,
                .{},
                output,
                false,
            );
            defer painted.deinit();
            const device = self.offscreen.extent();
            const record: v7_frame_mod.scene.RecordContext = .{
                .arena = output.tree.allocator,
                .renderer = &self.gui,
                .text = &self.text,
                .logical = .{
                    .width = @floatFromInt(device.width),
                    .height = @floatFromInt(device.height),
                },
                .device = device,
                .texture_heap = self.offscreen.heap().handle,
                .clips = output.tree.clip_rects[0..output.tree.clip_count],
            };
            _ = try v7_frame_mod.scene.recordFrameScene(
                &record,
                &self.cmd,
                &self.scratch,
                self.scratch.rects.items,
                &painted,
                self.offscreen.target(),
            );
            return self.offscreen.submitRead(&self.gpu_frame);
        }

        fn cancelFrame(self: *Windowless) void {
            if (self.gpu_frame.recording != .active) return;
            self.gpu_frame.cancelRecording() catch
                @panic("list-live recording cancellation failed");
        }
    };

    /// The presented pipeline: the SAME scene lowering and the SAME text
    /// engine, over `v7_frame.NativeFrame`, into a real window's swapchain
    /// image.
    ///
    /// TEARDOWN ORDER, which this value owns: the App detaches from the
    /// endpoint first (the caller does that), then the adapter, then the
    /// surface, then the device, then this path's loader, and only then the
    /// window and SDL. The swapchain and the platform surface live on the
    /// device AND reference the native window, so nothing device-side may
    /// outlive the window it presents to.
    const Presented = struct {
        /// What the window answers with, as opposed to what it was asked for.
        const Observed = struct {
            logical: WindowSize,
            scale: PixelScale,
        };

        /// The video driver SDL picked, read once while it is up. Reported so a
        /// run can say which platform it actually painted on.
        driver: [:0]const u8,

        application: *host.Application,
        handle: nogui.window_contract.WindowHandle,
        managed: *host.ManagedWindow,
        io: std.Io,
        /// The frame module's own loader, the same one the windowless path
        /// builds its device from. It stays open until the device made from
        /// it is destroyed, so it closes after the surface and the device and
        /// before the window.
        loader: v7_frame_mod.SystemVulkanLoader,
        gpu: noapi.Gpu,
        /// The platform surface `noapi.Surface.initSdl` created from the SDL
        /// window and adopted. It owns the `VkSurfaceKHR` on the way out, so
        /// no SDL wrapper is kept beside it: there is no second owner of one
        /// handle.
        surface: noapi.Surface,
        adapter: NativeFrame,
        frame: NativeFrame.Frame = undefined,
        /// Acquires the swapchain refused, retried inside `beginFrame`.
        retries: u32 = 0,
        /// Compositor round trips spent waiting for a requested resize.
        polls: u32 = 0,

        fn init(self: *Presented, gpa: std.mem.Allocator, io: std.Io, options: Painter.Options) !void {
            self.* = .{
                .application = undefined,
                .handle = undefined,
                .managed = undefined,
                .io = io,
                .driver = sdl3.video.getCurrentDriverName() orelse "<null>",
                .loader = undefined,
                .gpu = undefined,
                .surface = undefined,
                .adapter = undefined,
                .retries = 0,
                .polls = 0,
            };
            // The default run never reaches this, so the presented path can
            // ask for the session's own driver: a Vulkan surface cannot be
            // made for the hidden window the dummy driver keeps.
            self.application = try gpa.create(host.Application);
            errdefer gpa.destroy(self.application);
            self.application.* = try host.Application.init(gpa, options.session, .{
                .app_id = app_id,
            });
            errdefer self.application.deinit();
            self.handle = try self.application.openWindowWithApp(options.app, .{
                .title = window_title,
                .width = first_width,
                .height = first_height,
                .resizable = true,
                .visible = true,
                .gpu_surface = true,
            });
            self.managed = try self.application.getWindow(self.handle);
            // The device comes from the frame module's own loader, the same
            // one the windowless path builds its device from, so both halves of
            // this run resolve their entry points the same way. The backend
            // enables the platform surface extensions the instance needs, so
            // there is no extension list to borrow from the window system here.
            self.loader = try v7_frame_mod.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.gpu = try noapi.Gpu.init(.{
                // Three, not two: the renderer rings its per-frame paint
                // buffers over three slots, one per in-flight frame.
                .frames_in_flight = v7_frame_mod.scene.frames_in_flight,
                .app_name = "nogui-list-live",
                .validation = false,
                .loader = self.loader.options(),
                .io = io,
                .allocator = gpa,
            });
            errdefer self.gpu.deinit();
            // SDL's own Vulkan subsystem, for the platform surface call and
            // nothing else: on Wayland `SDL_Vulkan_CreateSurface` refuses with
            // "Vulkan is not loaded" unless this has run. The device above is
            // built from the frame module's loader, not from this one.
            try sdl3.vulkan.loadLibrary(null);
            // One call hands the window to the platform and takes the surface
            // back: the instance and the platform handle never leave noapi,
            // and a failed call destroys what the platform made.
            self.surface = try noapi.Surface.initSdl(
                &self.gpu,
                @ptrCast(self.managed.native.sdl.value),
                @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
                // A platform call, so it can fail; the surface is not built on
                // an unmeasured size.
                .{ .extent = try self.deviceExtent() },
            );
            errdefer self.surface.deinit();
            try self.adapter.init(.{
                .allocator = gpa,
                .gpu = &self.gpu,
                .fonts = &.{.{ .family = "InterVariable", .bytes = font_bytes }},
                .shaders = .{
                    .quad_vert = options.shaders.vert,
                    .quad_frag = options.shaders.frag,
                    .sort_comp = options.shaders.sort,
                    .fullscreen_vert = options.blit.fullscreen,
                    .blit_oklab = options.blit.oklab,
                },
                .name = "nogui_list_live_blit_oklab",
            });
        }

        /// The App must already have detached from `adapter.gpuEndpoint()`.
        fn deinit(self: *Presented, gpa: std.mem.Allocator) void {
            self.adapter.deinit();
            // Before the device: the swapchain and the platform surface live
            // on it, and the platform surface references the native window.
            self.surface.deinit();
            self.gpu.deinit();
            // The loader outlives every device made from it, so it closes last.
            self.loader.close();
            // A refused close is a veto this run never raises; it is reported
            // rather than swallowed, and the window is gone either way.
            if (self.application.closeWindow(self.handle)) |_| {} else |err| {
                std.debug.print(
                    "  list_live: the host refused to close the window: {s}\n",
                    .{@errorName(err)},
                );
            }
            self.application.deinit();
            gpa.destroy(self.application);
        }

        /// The window's own pixel extent, read from the platform rather than
        /// assumed. The driver may clamp the image it hands back, and both
        /// passes size themselves to that image instead.
        fn deviceExtent(self: *Presented) !noapi.Extent2D {
            const pixels = try self.managed.native.pixelExtent();
            return .{ .width = pixels.width, .height = pixels.height };
        }

        /// Ask the window for a client size and let the compositor answer it.
        /// A size it refuses leaves the viewport where it was, and what comes
        /// back is that, not the request.
        fn requestViewport(self: *Presented, size: Size) !Observed {
            const before = self.managed.observed.size;
            if (before.width != size.width or before.height != size.height) {
                try self.managed.requestSize(size);
                var polls: u32 = 0;
                while (polls < resize_polls) : (polls += 1) {
                    self.polls += 1;
                    _ = try self.application.step();
                    const now = self.managed.observed.size;
                    if (now.width == size.width and now.height == size.height) break;
                    try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(20), .real);
                }
            }
            const observed = self.managed.observed;
            return .{
                .logical = .{
                    .width = @floatFromInt(observed.size.width),
                    .height = @floatFromInt(observed.size.height),
                },
                .scale = try observed.pixelScale(),
            };
        }

        /// Acquire the next image, retarget the Oklab pass to it and open the
        /// recording. A swapchain that is out of date is not a failure: the
        /// adapter asks for the window's real pixel size and the acquire is
        /// retried, bounded, so a driver that never settles fails the run
        /// instead of spinning.
        fn beginFrame(self: *Presented, logical: WindowSize, scale: PixelScale) !void {
            var attempts: u32 = 0;
            while (attempts < acquire_polls) : (attempts += 1) {
                const viewport: NativeFrame.Viewport = .{
                    .logical = logical,
                    .device = try self.deviceExtent(),
                    .scale = scale,
                };
                if (try self.adapter.beginFrame(&self.surface, viewport, &self.frame)) return;
                self.retries += 1;
            }
            return error.SwapchainNeverSettled;
        }

        /// The App's tree, the Oklab pass, the blit and the present are ONE
        /// event: a frame this run calls committed is a frame whose pixels
        /// reached the swapchain image. The readback that follows is out of
        /// the Oklab target those same passes wrote.
        fn render(self: *Presented, output: *const FrameOutput) ![]const f32 {
            var painted = try self.adapter.buildScene(.{}, output);
            defer painted.deinit();
            try self.adapter.recordScene(&self.surface, &self.frame, output, &painted);
            // `present` closes the recording itself, so a present that fails
            // must propagate its own error rather than reach a cancellation of
            // a recording that is gone.
            try self.adapter.present(&self.surface, &self.frame);
            self.managed.markPresented();
            return self.adapter.readTarget();
        }
    };
};

pub const Scenario = struct {
    gpa: std.mem.Allocator,
    counter: AllocationCounter,
    /// The ONE pipeline this scenario renders through, mounted by
    /// `attachGpu`. Whichever mode was chosen owns it, and the App knows one
    /// endpoint: that one's.
    painter: ?*Painter = null,
    session: *Session,
    app: *App,
    uniform_model: *Model,
    variable_model: *Model,
    uniform_state: *uniform_list.State,
    variable_state: *list.State,
    uniform_scroll: ScrollState,
    variable_scroll: ScrollState,
    uniform_log: RowLog,
    variable_log: RowLog,
    uniform_builder: RowBuilder,
    variable_builder: RowBuilder,
    view: *LiveView,
    last_tick: u32 = 0,
    /// The client size the last frame ASKED for. What it was laid out in is
    /// `observed()`, which on the presented path is the window's own answer.
    requested: Size = .{ .width = first_width, .height = first_height },
    /// The frame's own allocation window, read before the render pass spends
    /// anything from the arena the paint list is built in.
    frame_bytes: usize = 0,
    frame_calls: usize = 0,
    /// Frames this scenario built and rendered, including the extra ones the
    /// geometry sync commits on its own.
    frames: u32 = 0,

    /// The model, both lists and the mounted root. No endpoint is attached
    /// yet, because the painter that owns one does not exist yet either: the
    /// default run never builds a window, a surface or a device, and the
    /// `--native` run builds them behind the App this returns.
    pub fn init(gpa: std.mem.Allocator) !*Scenario {
        const self = try gpa.create(Scenario);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .counter = .init(gpa),
            .session = undefined,
            .app = undefined,
            .uniform_model = undefined,
            .variable_model = undefined,
            .uniform_state = undefined,
            .variable_state = undefined,
            .uniform_scroll = .{},
            .variable_scroll = .{},
            .uniform_log = .{},
            .variable_log = .{},
            .uniform_builder = undefined,
            .variable_builder = undefined,
            .view = undefined,
        };
        const counted = self.counter.allocator();
        self.session = try counted.create(Session);
        errdefer counted.destroy(self.session);
        self.session.* = try Session.init(counted);
        self.app = try counted.create(App);
        errdefer counted.destroy(self.app);
        self.app.* = try App.init(counted, self.session);
        errdefer self.app.deinit();
        self.uniform_model = try counted.create(Model);
        errdefer counted.destroy(self.uniform_model);
        self.uniform_model.* = .{ .count = uniform_count };
        self.variable_model = try counted.create(Model);
        errdefer counted.destroy(self.variable_model);
        self.variable_model.* = .{ .count = variable_count };
        self.uniform_state = try counted.create(uniform_list.State);
        errdefer counted.destroy(self.uniform_state);
        self.uniform_state.* = try uniform_list.State.init(.{
            .count = uniform_count,
            .item_height = uniform_row,
            .viewport_height = 500,
            .overdraw_items = overdraw_items,
        });
        self.variable_state = try counted.create(list.State);
        errdefer counted.destroy(self.variable_state);
        self.variable_state.* = try list.State.init(counted, .{
            .count = variable_count,
            .estimated_height = 20,
            .viewport_height = 500,
            .overdraw_items = overdraw_items,
        });
        self.uniform_builder = .{ .log = &self.uniform_log };
        self.variable_builder = .{ .log = &self.variable_log };
        self.view = try counted.create(LiveView);
        errdefer counted.destroy(self.view);
        self.view.* = .{
            .uniform_model = self.uniform_model,
            .variable_model = self.variable_model,
            .uniform_state = self.uniform_state,
            .variable_state = self.variable_state,
            .uniform_scroll = &self.uniform_scroll,
            .variable_scroll = &self.variable_scroll,
            .uniform_log = &self.uniform_log,
            .variable_log = &self.variable_log,
            .uniform_builder = &self.uniform_builder,
            .variable_builder = &self.variable_builder,
            .list_width = 440,
            .list_height = 500,
        };
        try self.app.mountRoot(LiveView, self.view);
        self.counter.reset();
        return self;
    }

    /// Mount the chosen pipeline's ONE endpoint. The App renders through this
    /// painter and nothing else, and `detachGpu` runs before any device-side
    /// resource the painter owns is released.
    pub fn attachGpu(self: *Scenario, painter: *Painter) !void {
        // The App measures through the painter's own text engine, bound as a
        // value it holds: a measured label and a painted glyph are one
        // measurement on either path.
        self.app.measure = painter.measurer();
        try self.app.attachGpu(painter.endpoint());
        self.painter = painter;
    }

    /// The geometry the last frame was laid out in. This is the OBSERVED
    /// viewport, never the requested size: on the windowless path the request
    /// is the answer, and on the presented path the window's is.
    pub fn observed(self: *Scenario) WindowSize {
        return self.painter.?.logical;
    }

    /// True when the compositor gave the window the size that was asked for on
    /// the last frame. A false answer is a run that reports the geometry it
    /// observed instead of claiming the request landed.
    pub fn viewportHonoured(self: *Scenario) bool {
        const painter = self.painter.?;
        const logical = painter.logical;
        return @as(u32, @intFromFloat(logical.width)) == self.requested.width and
            @as(u32, @intFromFloat(logical.height)) == self.requested.height;
    }

    pub fn deinit(self: *Scenario) void {
        const counted = self.counter.allocator();
        // The App's GPU mounts go first. The adapter, the surface, the device
        // and the window behind that endpoint are released by the painter,
        // which the caller destroys after this returns.
        if (self.painter != null) self.app.detachGpu();
        self.app.deinit();
        counted.destroy(self.view);
        self.variable_state.deinit();
        counted.destroy(self.variable_state);
        counted.destroy(self.uniform_state);
        counted.destroy(self.variable_model);
        counted.destroy(self.uniform_model);
        self.session.deinit() catch unreachable;
        counted.destroy(self.session);
        counted.destroy(self.app);
        self.gpa.destroy(self);
    }

    /// Run one frame against the viewport, then render it. `width`/`height`
    /// are a REQUEST. The painter turns that request into the geometry this
    /// frame is really laid out in — its own offscreen target on the
    /// windowless path, the window's observed size on the presented one — and
    /// the view, the App's surface and the pixel probes all follow that one
    /// number, so a resize while scrolled is a genuine viewport change rather
    /// than a simulation of one.
    pub fn frame(self: *Scenario, tick: u32, width: u32, height: u32) !FrameOutput {
        const painter = self.painter.?;
        self.last_tick = tick;
        self.requested = .{ .width = width, .height = height };
        try painter.requestViewport(self.requested);
        const logical = painter.logical;
        self.view.list_width = logical.width / 2 - 10;
        self.view.list_height = logical.height;
        self.uniform_log.reset();
        self.variable_log.reset();
        self.counter.reset();
        self.frames += 1;
        try painter.beginFrame();
        errdefer painter.cancelFrame();
        const output = try self.app.frameWithGpuAtTime(
            tick,
            // Time starts at zero on purpose. Nothing in this scenario is
            // time-driven, so a clock here would only make the same run report
            // different numbers twice.
            0,
            .{ .width = logical.width, .height = logical.height },
            painter.gpuFrame(),
        );
        const totals = self.counter.totals();
        self.frame_bytes = totals.bytes;
        self.frame_calls = totals.calls;
        try painter.render(&output);
        return output;
    }

    fn uniformHandle(self: *Scenario) !nogui.scroll.Handle {
        const id = self.app.widgetIdForKey(
            nogui.ComponentId.root,
            @as(nogui.ComponentKey, .{ .static = "uniform" }),
        ) orelse return error.MissingUniformIdentity;
        return self.app.scrollHandle(id) orelse error.MissingUniformHandle;
    }

    fn variableHandle(self: *Scenario) !nogui.scroll.Handle {
        const id = self.app.widgetIdForKey(
            nogui.ComponentId.root,
            @as(nogui.ComponentKey, .{ .static = "variable" }),
        ) orelse return error.MissingVariableIdentity;
        return self.app.scrollHandle(id) orelse error.MissingVariableHandle;
    }

    /// Tell the list where the mixed list now is. The list reads its offset
    /// back from `ScrollState` at the start of the next frame, so an edit made
    /// outside a frame has to publish the result through the stable handle.
    pub fn syncVariable(self: *Scenario) !void {
        const handle = try self.variableHandle();
        const snapshot = self.app.scrollSnapshot(handle) orelse
            return error.MissingScrollSnapshot;
        const desired: f32 = @floatCast(self.variable_state.offset);
        if (desired > snapshot.max_offset[1]) {
            // The model grew past the maximum the last committed frame
            // published, so commit that frame and set the offset against the
            // refreshed maximum.
            const was_following = self.variable_state.end_follow;
            const viewport = self.observed();
            _ = try self.frame(self.last_tick + 1, @intFromFloat(viewport.width), @intFromFloat(viewport.height));
            if (was_following) {
                self.variable_state.followEnd(true, self.variable_model.keys());
            }
            const rebuilt = try self.variableHandle();
            const refreshed = self.app.scrollSnapshot(rebuilt) orelse
                return error.MissingScrollSnapshot;
            const target: f32 = @floatCast(self.variable_state.offset);
            if (target > refreshed.max_offset[1]) return error.ScrollTargetBeyondCommittedMaximum;
            _ = try self.app.scrollTo(rebuilt, .{ 0, target });
            return;
        }
        _ = try self.app.scrollTo(handle, .{ 0, desired });
    }
};

/// Every built row must contribute painted geometry inside its own list, or
/// the window has nothing to show and the frame cost claim is hollow.
fn checkVisibleRows(
    gpa: std.mem.Allocator,
    output: *const FrameOutput,
    built: usize,
    label: []const u8,
) !usize {
    const cmds = try drawcmd.collectDrawCmds(
        gpa,
        @constCast(output.tree),
        output.pressed,
        output.press_alpha,
    );
    defer gpa.free(cmds);
    if (cmds.len == 0) return error.NoPaintedGeometry;
    // Rows plus their labels, plus the scrollers themselves.
    if (cmds.len < built) return error.FewerPaintsThanRows;
    var inside: usize = 0;
    for (cmds) |cmd| {
        if (cmd.rect.w > 0 and cmd.rect.h > 0) inside += 1;
    }
    if (inside < built) return error.DegenerateRowGeometry;
    std.debug.print("  {s}: {d} rows, {d} paint commands, {d} with real area\n", .{
        label,
        built,
        cmds.len,
        inside,
    });
    return cmds.len;
}

/// A row's node in the committed tree must sit at its content-space top with
/// the height the geometry state reported. This is the widget's contract with
/// the list geometry, checked against the tree a renderer would consume.
fn checkRowGeometry(
    output: *const FrameOutput,
    state: *const list.State,
    log: *const RowLog,
) !void {
    if (log.used == 0) return error.NoRowsToCheck;
    for (log.indices[0..log.used], log.heights[0..log.used], log.nodes[0..log.used]) |index, height, id| {
        // The recorded node is the row's CONTENT. The row's placement is its
        // container's rect: reading the child's own rect would only ever
        // restate the inside of the row and pass whatever the list did.
        const content = output.tree.nodeConst(id) orelse return error.MissingRowNode;
        const row = output.tree.nodeConst(content.parent) orelse return error.MissingRowNode;
        if (row.rect.h != @as(f32, @floatCast(height))) return error.RowHeightIsNotTheMeasuredHeight;
        // The geometry state owns the truth about where row N belongs; the
        // node read back out of the committed tree is the renderer input, and
        // the two have to agree.
        if (!closeEnough(row.rect.y, state.itemTop(index))) return error.RowNotAtItsContentTop;
    }
}

// ── The pixels ───────────────────────────────────────────────────────

/// A half-open box of device pixels, already clipped to the target.
const Box = struct {
    x0: i32 = 0,
    y0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,

    fn isEmpty(self: Box) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }

    fn clipped(self: Box, width: u32, height: u32) Box {
        return .{
            .x0 = std.math.clamp(self.x0, 0, @as(i32, @intCast(width))),
            .y0 = std.math.clamp(self.y0, 0, @as(i32, @intCast(height))),
            .x1 = std.math.clamp(self.x1, 0, @as(i32, @intCast(width))),
            .y1 = std.math.clamp(self.y1, 0, @as(i32, @intCast(height))),
        };
    }
};

/// The Oklab colour of one readback pixel. The pass renders in Oklab, so this
/// is the value the pipeline itself wrote, never a rounded sRGB byte.
const Lab = [3]f32;

/// The clear the GUI pass begins from, as a colour to compare against.
const clear_lab: Lab = .{
    v7_frame_mod.scene.oklab_clear[0],
    v7_frame_mod.scene.oklab_clear[1],
    v7_frame_mod.scene.oklab_clear[2],
};

/// One 8-bit sRGB step is far wider than this, so nothing a glyph draws is
/// under it, and it still ignores the last bit of a solid fill.
const color_epsilon: f32 = 1.0 / 512.0;

fn differs(a: Lab, b: Lab) bool {
    return @abs(a[0] - b[0]) > color_epsilon or
        @abs(a[1] - b[1]) > color_epsilon or
        @abs(a[2] - b[2]) > color_epsilon;
}

/// How wide the sampled strip at a row's right end is, and how far from the
/// row's border it is kept: wide enough to average over, clear of any
/// scroller the list draws along its own edge, and narrow enough that no row
/// text in this scenario ever reaches it. Both are LOGICAL units, so a scaled
/// window measures them in its own device pixels.
const strip_columns: f32 = 40;
const strip_inset: f32 = 16;

/// The columns at the right edge of the viewport the two lists cannot reach.
/// The frame is 20 units wider than the two lists together.
const frame_edge_columns: i32 = 8;

/// The tightest box around every pixel the pass painted over its clear, empty
/// when the frame is. With the layout row transparent, that is the union of
/// the two lists' row bands and nothing else.
const PaintBounds = struct {
    x0: i32 = 0,
    y0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,

    fn isEmpty(self: PaintBounds) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }
};

/// One rendered frame's pixels together with the geometry they were drawn
/// for: the device extent they came back at, the window-logical units the App
/// laid the tree out in, and the ratio between the two.
///
/// They are one number on a 1:1 display and two on a scaled one, which is
/// exactly why a probe carries all three: a logical rect measured against a
/// device pixel count reads the wrong box on a HiDPI window, and every margin
/// below would be off by the scale with it.
const Probe = struct {
    pixels: []const f32,
    extent: noapi.Extent2D,
    logical: WindowSize,
    scale: PixelScale,

    fn of(painter: *const Painter) Probe {
        return .{
            .pixels = painter.pixels,
            .extent = painter.extent,
            .logical = painter.logical,
            .scale = painter.scale,
        };
    }

    fn width(self: Probe) u32 {
        return self.extent.width;
    }

    fn height(self: Probe) u32 {
        return self.extent.height;
    }

    fn labAt(self: Probe, x: usize, y: usize) Lab {
        const w: usize = @intCast(self.extent.width);
        const pixel = self.pixels[(y * w + x) * 4 ..][0..4];
        return .{ pixel[0], pixel[1], pixel[2] };
    }

    /// A logical length in device pixels, on each axis.
    fn pxX(self: Probe, units: f32) f32 {
        return units * self.scale.x;
    }

    fn px(self: Probe, units: f32) f32 {
        return units * self.scale.y;
    }

    /// The device-pixel box a logical rect covers, clipped to the target.
    fn box(self: Probe, rect: Rect) Box {
        const raw: Box = .{
            .x0 = @intFromFloat(@floor(rect.x * self.scale.x)),
            .y0 = @intFromFloat(@floor(rect.y * self.scale.y)),
            .x1 = @intFromFloat(@ceil((rect.x + rect.w) * self.scale.x)),
            .y1 = @intFromFloat(@ceil((rect.y + rect.h) * self.scale.y)),
        };
        return raw.clipped(self.width(), self.height());
    }

    /// The device column or row a logical edge lands on, floored where a box
    /// starts and ceiled where it ends, so the two match the coverage the
    /// layout really asked for.
    fn deviceX(self: Probe, x: f32) i32 {
        return @intFromFloat(@floor(x * self.scale.x));
    }

    fn deviceCeilX(self: Probe, x: f32) i32 {
        return @intFromFloat(@ceil(x * self.scale.x));
    }

    fn deviceY(self: Probe, y: f32) i32 {
        return @intFromFloat(@floor(y * self.scale.y));
    }

    fn deviceCeilY(self: Probe, y: f32) i32 {
        return @intFromFloat(@ceil(y * self.scale.y));
    }

    /// Wholly inside the viewport, with a pixel of slack for the float layout
    /// did the geometry in. A partially clipped row proves nothing either way:
    /// its text may be scrolled out of sight above or below, so it is not
    /// probed.
    fn inside(self: Probe, rect: Rect) bool {
        if (!(rect.w > 0) or !(rect.h > 0)) return false;
        return rect.x >= -1 and rect.y >= -1 and
            rect.x + rect.w <= self.logical.width + 1 and
            rect.y + rect.h <= self.logical.height + 1;
    }

    /// The colour in the middle of `target`, or null when the target is empty.
    fn sample(self: Probe, target: Box) ?Lab {
        if (target.isEmpty()) return null;
        const x: usize = @intCast(@divFloor(target.x0 + target.x1, 2));
        const y: usize = @intCast(@divFloor(target.y0 + target.y1, 2));
        return self.labAt(x, y);
    }

    /// Pixels in `target` that are not `reference`. Measured against the Oklab
    /// clear this counts everything the pass painted; measured against a row's
    /// own fill it counts that row's text.
    fn count(self: Probe, target: Box, reference: Lab) usize {
        if (target.isEmpty()) return 0;
        var n: usize = 0;
        var y: usize = @intCast(target.y0);
        while (y < @as(usize, @intCast(target.y1))) : (y += 1) {
            var x: usize = @intCast(target.x0);
            while (x < @as(usize, @intCast(target.x1))) : (x += 1) {
                if (differs(self.labAt(x, y), reference)) n += 1;
            }
        }
        return n;
    }

    fn paintBounds(self: Probe) PaintBounds {
        var bounds: PaintBounds = .{ .x1 = -1, .y1 = -1 };
        for (0..@as(usize, self.height())) |y| {
            for (0..@as(usize, self.width())) |x| {
                if (!differs(self.labAt(x, y), clear_lab)) continue;
                const ix: i32 = @intCast(x);
                const iy: i32 = @intCast(y);
                if (bounds.x1 < 0) {
                    bounds = .{ .x0 = ix, .y0 = iy, .x1 = ix + 1, .y1 = iy + 1 };
                    continue;
                }
                bounds.x0 = @min(bounds.x0, ix);
                bounds.y0 = @min(bounds.y0, iy);
                bounds.x1 = @max(bounds.x1, ix + 1);
                bounds.y1 = @max(bounds.y1, iy + 1);
            }
        }
        return bounds;
    }
};

/// The screen box of a built row's text, or null when the row was not built.
fn textBoxOf(tree: *const WidgetTree, log: *const RowLog, index: usize) ?Rect {
    for (log.indices[0..log.used], log.nodes[0..log.used]) |built, id| {
        if (built != index) continue;
        return nogui.widget.visualContentRect(tree, id);
    }
    return null;
}

/// What one rendered frame's pixels say about one list's rows.
pub const ListPixels = struct {
    /// Built rows whose text box lies wholly inside the viewport, and that
    /// carry no focus or hover ring.
    visible: usize = 0,
    /// Of those, the ones whose text box carries something that is not the
    /// row's own fill.
    inked: usize = 0,
    /// Pixels in a row's remainder that are not that row's fill. Any of them
    /// is paint the list did not ask for.
    stray: usize = 0,
    /// Rows left unprobed because the pipeline drew a ring over them.
    ringed: usize = 0,
    /// The first and last model index the pixels prove, in build order.
    first_inked: ?usize = null,
    last_inked: ?usize = null,
    /// The device row the last proved text reaches down to.
    last_inked_bottom: i32 = 0,
};

/// Read one list's rows out of the rendered pixels. A row proves itself twice
/// over: the box it laid out for itself is on the framebuffer in the row's
/// own fill, and the box its text was measured into is not that fill. What
/// sits in between, past the text, is the row's own fill and nothing else.
fn probeList(
    probe: Probe,
    output: *const FrameOutput,
    log: *const RowLog,
) !ListPixels {
    const tree = output.tree;
    const focused = if (output.focus) |id| tree.frameNode(id) else null;
    const hovered = if (output.hover) |id| tree.frameNode(id) else null;
    const inset: i32 = @intFromFloat(probe.pxX(strip_inset));
    const columns: i32 = @intFromFloat(probe.pxX(strip_columns));
    var proof: ListPixels = .{};
    for (log.indices[0..log.used], log.nodes[0..log.used]) |index, label_id| {
        const label = tree.nodeConst(label_id) orelse return error.MissingRowNode;
        const row_node = tree.nodeConst(label.parent) orelse return error.MissingRowNode;
        const row = nogui.widget.visualBorderRect(tree, row_node.id);
        const text = nogui.widget.visualContentRect(tree, label.id);
        if (!probe.inside(text)) continue;
        // A ring is a 2px band inside the row's own border box, and it would
        // read as text and as stray paint. The row is reported and left alone.
        if (ringedNode(focused, hovered, row_node.id, label.id)) {
            proof.ringed += 1;
            continue;
        }
        proof.visible += 1;
        // The row's own remainder, taken at its right end. The strip is
        // clear of the border, so neither a ring nor a scroller along the
        // list's edge can be in it, and the text never reaches it: a row is
        // at least 300 units wide here and a label is about 75. If that ever
        // stops being true the probe refuses rather than read the row's own
        // text as its own paint.
        const row_right = probe.deviceX(row.x + row.w);
        const raw: Box = .{
            .x0 = row_right - inset - columns,
            .y0 = probe.deviceY(row.y) + 3,
            .x1 = row_right - inset,
            .y1 = probe.deviceCeilY(row.y + row.h) - 3,
        };
        const rest = raw.clipped(probe.width(), probe.height());
        if (rest.isEmpty()) return error.RowHasNoRemainderToRead;
        if (probe.deviceCeilX(text.x + text.w) > rest.x0) {
            return error.RowTextReachesTheSampledStrip;
        }
        const fill = probe.sample(rest) orelse return error.NoRowFillSample;
        // The row's own box reached the framebuffer. Nothing else in this
        // frame is painted, so a clear here would mean the widget laid a row
        // out that no one drew.
        if (!differs(fill, clear_lab)) return error.RowBoxWasNotPainted;
        proof.stray += probe.count(rest, fill);
        const text_box = probe.box(text);
        if (probe.count(text_box, fill) > 0) {
            proof.inked += 1;
            if (proof.first_inked == null) proof.first_inked = index;
            proof.last_inked = index;
            proof.last_inked_bottom = text_box.y1;
        }
    }
    return proof;
}

fn ringedNode(
    focused: ?FrameNodeId,
    hovered: ?FrameNodeId,
    row: FrameNodeId,
    label: FrameNodeId,
) bool {
    for ([_]?FrameNodeId{ focused, hovered }) |candidate| {
        const id = candidate orelse continue;
        if (id == row or id == label) return true;
    }
    return false;
}

/// Everything one rendered frame proves, for both lists at once.
pub const Rendered = struct {
    uniform: ListPixels,
    variable: ListPixels,
    bounds: PaintBounds,
    glyph_slots: u32,
};

/// Probe the pixels the last render produced, and refuse a frame that drew
/// anything other than the two lists' rows. Which target those pixels came
/// from is the painter's business: the windowless path reads its own offscreen
/// target back, and the presented path reads back the Oklab target its own
/// presented passes wrote.
fn checkRendered(
    output: *const FrameOutput,
    painter: *Painter,
    uniform_log: *const RowLog,
    variable_log: *const RowLog,
    label: []const u8,
) !Rendered {
    const probe = Probe.of(painter);
    if (probe.pixels.len == 0) return error.NoRenderedPixels;
    if (painter.glyphSlots() <= 1) return error.NoGlyphsRendered;
    const bounds = probe.paintBounds();
    if (bounds.isEmpty()) return error.BlankFrame;
    const rendered: Rendered = .{
        .uniform = try probeList(probe, output, uniform_log),
        .variable = try probeList(probe, output, variable_log),
        .bounds = bounds,
        .glyph_slots = painter.glyphSlots(),
    };
    try checkListPixels(&rendered.uniform);
    try checkListPixels(&rendered.variable);
    // The two lists stand side by side and together are 20 units narrower
    // than the frame, so the last columns of the viewport are still the clear
    // the pass began from. Paint out there would be something drawing outside
    // the lists.
    const frame_right: i32 = @intCast(probe.width());
    if (probe.count(.{
        .x0 = frame_right - frame_edge_columns,
        .y0 = 0,
        .x1 = frame_right,
        .y1 = @intCast(probe.height()),
    }, clear_lab) != 0) return error.PaintOutsideTheLists;
    std.debug.print(
        "  {s}: {d}x{d} device, {d}x{d} logical, {d} glyph slots, painted x {d}..{d} y {d}..{d}\n",
        .{
            label,
            probe.width(),
            probe.height(),
            @as(u32, @intFromFloat(probe.logical.width)),
            @as(u32, @intFromFloat(probe.logical.height)),
            rendered.glyph_slots,
            rendered.bounds.x0,
            rendered.bounds.x1,
            rendered.bounds.y0,
            rendered.bounds.y1,
        },
    );
    printListPixels("uniform", &rendered.uniform);
    printListPixels("variable", &rendered.variable);
    return rendered;
}

fn checkListPixels(proof: *const ListPixels) !void {
    if (proof.visible == 0) return error.NoRowWhollyInsideTheViewport;
    if (proof.inked != proof.visible) return error.RowTextMissingFromThePixels;
    if (proof.stray != 0) return error.PaintOutsideTheRowText;
}

fn printListPixels(label: []const u8, proof: *const ListPixels) void {
    std.debug.print(
        "    {s}: {d} of {d} visible rows inked, {d} stray pixels, {d} ringed\n",
        .{ label, proof.inked, proof.visible, proof.stray, proof.ringed },
    );
}

/// f32 widget geometry against f64 list geometry: a hundredth of a pixel.
fn closeEnough(a: f32, b: f64) bool {
    return @abs(@as(f64, a) - b) <= 0.01;
}

/// A tolerance of a hundredth of a pixel: the widget converts through f32, so
/// the two sides agree to float precision, not bit for bit.
fn nearEnough(a: f64, b: f64) bool {
    return @abs(a - b) <= 0.01;
}

/// Where the presented path's blit modules come from when the command line
/// does not name them. Both are relative to the working directory, so a
/// `--native` run executes with the repo root as its cwd, exactly as
/// `w12_ime_smoke` already requires.
const default_fullscreen_shader = "shaders/fullscreen_vert.spv";
const default_oklab_shader = "shaders/blit_oklab.spv";

/// The command line: three shader paths, then the flags. The two blit modules
/// matter to `--native` alone; the windowless run presents nothing and never
/// opens them.
const Options = struct {
    vert: []const u8,
    frag: []const u8,
    sort: []const u8,
    fullscreen: ?[]const u8 = null,
    oklab: ?[]const u8 = null,
    ppm: ?[]const u8 = null,
    native: bool = false,

    fn fullscreenPath(self: Options) []const u8 {
        return self.fullscreen orelse default_fullscreen_shader;
    }

    fn oklabPath(self: Options) []const u8 {
        return self.oklab orelse default_oklab_shader;
    }

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        gpa.free(self.vert);
        gpa.free(self.frag);
        gpa.free(self.sort);
        if (self.fullscreen) |path| gpa.free(path);
        if (self.oklab) |path| gpa.free(path);
        if (self.ppm) |path| gpa.free(path);
        self.* = undefined;
    }
};

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    const vert = try gpa.dupe(u8, args.next() orelse return error.MissingVertexShader);
    errdefer gpa.free(vert);
    const frag = try gpa.dupe(u8, args.next() orelse return error.MissingFragmentShader);
    errdefer gpa.free(frag);
    const sort = try gpa.dupe(u8, args.next() orelse return error.MissingSortShader);
    errdefer gpa.free(sort);
    var options: Options = .{ .vert = vert, .frag = frag, .sort = sort };
    errdefer options.deinit(gpa);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            if (options.ppm != null) return error.RepeatedOutputPath;
            options.ppm = try gpa.dupe(u8, args.next() orelse return error.MissingOutputPath);
        } else if (std.mem.eql(u8, arg, "--fullscreen-vert")) {
            if (options.fullscreen != null) return error.RepeatedShaderPath;
            options.fullscreen = try gpa.dupe(u8, args.next() orelse return error.MissingShaderPath);
        } else if (std.mem.eql(u8, arg, "--blit-oklab")) {
            if (options.oklab != null) return error.RepeatedShaderPath;
            options.oklab = try gpa.dupe(u8, args.next() orelse return error.MissingShaderPath);
        } else return error.UnknownArgument;
    }
    return options;
}

/// Drive the whole sequence, and print what each step observed.
pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var options = try parseArgs(init, gpa);
    defer options.deinit(gpa);

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var vert = try ShaderFile.load(gpa, io, options.vert);
    defer vert.deinit(gpa);
    var frag = try ShaderFile.load(gpa, io, options.frag);
    defer frag.deinit(gpa);
    var sort = try ShaderFile.load(gpa, io, options.sort);
    defer sort.deinit(gpa);

    // Only the presented path records a blit, so only it opens the two
    // modules that blit is drawn with.
    var fullscreen: ShaderFile = undefined;
    var oklab: ShaderFile = undefined;
    if (options.native) {
        fullscreen = try ShaderFile.load(gpa, io, options.fullscreenPath());
        defer fullscreen.deinit(gpa);
        oklab = try ShaderFile.load(gpa, io, options.oklabPath());
        defer oklab.deinit(gpa);
    }

    // The App exists before the window does: a host window owns exactly one
    // App, so the presented path opens its window against this one. The block
    // is there so a painter that fails to build still tears the scenario down
    // instead of leaking it.
    const scenario = try Scenario.init(gpa);
    var painter = blk: {
        errdefer scenario.deinit();
        break :blk try Painter.init(gpa, io, .{
            .mode = if (options.native) .presented else .windowless,
            .shaders = .{
                .vert = vert.words,
                .frag = frag.words,
                .sort = sort.words,
            },
            .blit = .{
                .fullscreen = if (options.native) fullscreen.words else &[_]u32{},
                .oklab = if (options.native) oklab.words else &[_]u32{},
            },
            .app = scenario.app,
            .session = scenario.session,
        });
    };
    // The painter outlives the scenario on purpose: `Scenario.deinit` detaches
    // the App from the endpoint, and only then does the adapter, the surface,
    // the device and the window go.
    defer painter.deinit();
    try scenario.attachGpu(painter);
    defer scenario.deinit();

    if (painter.windowState()) |state| {
        std.debug.print(
            "mode: native window on the {s} driver, {d}x{d} logical at {d}x{d} device;\n" ++
                "every pixel below is read back from the Oklab target the presented passes wrote\n",
            .{
                state.driver,
                state.logical.width,
                state.logical.height,
                state.device.width,
                state.device.height,
            },
        );
        if (!state.visible) return error.NativeWindowIsNotVisible;
    } else {
        std.debug.print(
            "mode: windowless offscreen proof; no window, no surface, no present, SDL never started\n",
            .{},
        );
    }

    // 1. First frame, at the requested 900x600.
    const first = try scenario.frame(1, first_width, first_height);
    const uniform_built = scenario.uniform_log.count;
    const variable_built = scenario.variable_log.count;
    const first_view = scenario.observed();
    std.debug.print(
        "first frame: requested {d}x{d}, laid out {d}x{d}; uniform {d} rows, variable {d} rows, {d}B in {d} allocs\n",
        .{
            first_width,
            first_height,
            @as(u32, @intFromFloat(first_view.width)),
            @as(u32, @intFromFloat(first_view.height)),
            uniform_built,
            variable_built,
            scenario.frame_bytes,
            scenario.frame_calls,
        },
    );
    if (uniform_built == 0 or variable_built == 0) return error.EmptyFirstFrame;
    // 200,000 and 20,000 records, a handful of rows each.
    if (uniform_built * 64 >= uniform_count) return error.UniformCostTracksModel;
    if (variable_built * 64 >= variable_count) return error.VariableCostTracksModel;
    _ = try checkVisibleRows(gpa, &first, uniform_built + variable_built, "first frame");
    const first_pixels = try checkRendered(&first, painter, &scenario.uniform_log, &scenario.variable_log, "first frame");
    // The tall frame really did paint below where the short viewport ends, so
    // the short frame that follows cannot be reusing these pixels. The bound
    // is the requested short size in this window's own device pixels; the
    // resize step below reports the geometry the compositor actually gave.
    const short_device_height: i32 = @intFromFloat(
        @as(f32, @floatFromInt(resized_height)) * painter.scale.y,
    );
    if (first_pixels.bounds.y1 <= short_device_height) return error.TallFrameDidNotPaintItsLowerViewport;
    const first_nodes = first.tree.nodes.items.len;

    // 2. Scroll both lists through their stable handles.
    const uniform = try scenario.uniformHandle();
    const variable = try scenario.variableHandle();
    const uniform_top = scenario.uniform_state.offset;
    const variable_top = scenario.variable_state.offset;
    if (!try scenario.app.scrollBy(uniform, .{ 0, 4_000 })) return error.UniformScrollRejected;
    if (!try scenario.app.scrollBy(variable, .{ 0, 4_000 })) return error.VariableScrollRejected;
    const scrolled = try scenario.frame(2, first_width, first_height);
    if (scenario.uniform_state.offset <= uniform_top) return error.UniformScrollDidNotMove;
    if (scenario.variable_state.offset <= variable_top) return error.VariableScrollDidNotMove;
    std.debug.print("scrolled 4000: uniform {d} rows at {d:.0}, variable {d} rows at {d:.0}\n", .{
        scenario.uniform_log.count,
        scenario.uniform_state.offset,
        scenario.variable_log.count,
        scenario.variable_state.offset,
    });
    const scrolled_pixels = try checkRendered(&scrolled, painter, &scenario.uniform_log, &scenario.variable_log, "scrolled");
    // Scrolled away from the top, the first row in view is a later record,
    // and the pixels say so.
    if (scrolled_pixels.uniform.first_inked.? == 0) return error.ScrolledFrameStillShowsRowZero;

    // 3. Resize WHILE SCROLLED. Fewer rows, the same records in view.
    const uniform_anchor = scenario.uniform_state.anchor.?.key;
    const variable_anchor = scenario.variable_state.anchor.?.key;
    const resized = try scenario.frame(3, resized_width, resized_height);
    // A viewport that changed under a scrolled list moved the window, not the
    // record the list was looking at: the anchored key is the one it had.
    if (scenario.uniform_state.anchor.?.key != uniform_anchor) return error.ResizeMovedUniformAnchor;
    if (scenario.variable_state.anchor.?.key != variable_anchor) return error.ResizeMovedVariableAnchor;
    const resized_view = scenario.observed();
    const resized_device_height: i32 = @intCast(painter.extent.height);
    std.debug.print(
        "resize while scrolled: requested {d}x{d}, observed {d}x{d} logical at {d}x{d} device; uniform {d} rows, variable {d} rows\n",
        .{
            resized_width,
            resized_height,
            @as(u32, @intFromFloat(resized_view.width)),
            @as(u32, @intFromFloat(resized_view.height)),
            painter.extent.width,
            painter.extent.height,
            scenario.uniform_log.count,
            scenario.variable_log.count,
        },
    );
    // A compositor that refused the resize leaves the viewport where it was,
    // and then the row counts below cannot be smaller. That is reported here,
    // with the observed geometry, instead of being passed off as a resize.
    if (!scenario.viewportHonoured()) {
        std.debug.print(
            "  the window did not take the requested size; the frame is laid out at {d}x{d}\n",
            .{
                @as(u32, @intFromFloat(resized_view.width)),
                @as(u32, @intFromFloat(resized_view.height)),
            },
        );
        return error.NativeResizeRefused;
    }
    _ = try checkVisibleRows(gpa, &resized, scenario.uniform_log.count + scenario.variable_log.count, "resized");
    const resized_pixels = try checkRendered(&resized, painter, &scenario.uniform_log, &scenario.variable_log, "resized");
    // The shorter viewport fits fewer rows, and the target the pixels came
    // back from is the short one.
    if (resized_pixels.uniform.visible >= first_pixels.uniform.visible) {
        return error.ResizeDidNotRemoveRowsFromThePixels;
    }
    if (resized_pixels.bounds.y1 > resized_device_height) return error.InkBelowTheResizedViewport;

    // 4. Insert above the viewport of the mixed list. The anchor follows its
    //    key to its new index.
    const anchor_index = scenario.variable_state.anchor.?.index;
    const anchor_key = scenario.variable_state.anchor.?.key;
    scenario.variable_model.first_key -= 1;
    try scenario.variable_state.splice(0, 0, 1, scenario.variable_model.keys());
    try scenario.syncVariable();
    const inserted = try scenario.frame(4, resized_width, resized_height);
    if (scenario.variable_state.anchor.?.key != anchor_key) return error.InsertMovedAnchorKey;
    if (scenario.variable_state.anchor.?.index != anchor_index + 1) return error.InsertDidNotShiftAnchor;
    if (scenario.variable_model.keyAt(anchor_index + 1) != anchor_key) return error.AnchorKeyNamesAnotherRecord;
    std.debug.print("insert above: anchor key {d} moved to index {d}\n", .{
        scenario.variable_state.anchor.?.key,
        scenario.variable_state.anchor.?.index,
    });

    // 5. Remeasure a row ABOVE the viewport. The anchor key holds and its
    //    screen offset is unchanged.
    const screen_y = scenario.variable_state.offset - scenario.variable_state.itemTop(anchor_index + 1);
    const revision: u64 = 1_000_000;
    if (!try scenario.variable_state.measure(anchor_index + 1, 96, revision, scenario.variable_model.keys())) {
        return error.RemeasureRefused;
    }
    try scenario.syncVariable();
    _ = try scenario.frame(5, resized_width, resized_height);
    if (scenario.variable_state.anchor.?.key != anchor_key) return error.RemeasureMovedAnchor;
    if (!nearEnough(scenario.variable_state.offset - scenario.variable_state.itemTop(anchor_index + 1), screen_y)) {
        return error.RemeasureMovedAnchorOnScreen;
    }
    std.debug.print("remeasure above: anchor key {d} held, screen offset {d:.1}\n", .{
        anchor_key,
        scenario.variable_state.offset - scenario.variable_state.itemTop(anchor_index + 1),
    });

    // 6. End follow across appends, through the handle.
    const variable_handle = try scenario.variableHandle();
    _ = try scenario.app.scrollTo(variable_handle, .{ 0, @floatCast(scenario.variable_state.maxOffset()) });
    scenario.variable_state.followEnd(true, scenario.variable_model.keys());
    try scenario.syncVariable();
    const tail_start = scenario.variable_model.count;
    scenario.variable_model.count += 3;
    try scenario.variable_state.splice(tail_start, 0, 3, scenario.variable_model.keys());
    try scenario.syncVariable();
    const followed = try scenario.frame(6, resized_width, resized_height);
    const step6_nodes = followed.tree.nodes.items.len;
    if (!nearEnough(scenario.variable_state.offset, scenario.variable_state.maxOffset())) {
        return error.EndFollowDidNotReachTheEnd;
    }
    const last_index = scenario.variable_model.count - 1;
    const range = scenario.variable_state.visible();
    if (range.first > last_index or last_index >= range.end) return error.EndFollowDidNotBuildNewest;
    std.debug.print("end follow: {d} rows built, newest index {d} in range {d}..{d}\n", .{
        scenario.variable_log.count,
        last_index,
        range.first,
        range.end,
    });
    _ = try checkVisibleRows(gpa, &followed, scenario.uniform_log.count + scenario.variable_log.count, "followed");
    const followed_pixels = try checkRendered(&followed, painter, &scenario.uniform_log, &scenario.variable_log, "followed");
    if (followed_pixels.variable.last_inked.? != last_index) {
        return error.NewestRecordIsNotTheLastRowInThePixels;
    }
    // Frame 7 resets the row log, so frame 6's rows are copied out while
    // frame 6 is the live one. Reading the log back afterwards would compare
    // frame 7's node ids against frame 6's tree.
    const frame6_log = scenario.variable_log;
    // The newest record's own text is the bottom of the rendered list: the
    // proof above says the pixels carry it, and here it is wholly in view and
    // sits below the record before it. Its text reaches the bottom of the
    // list box, which is where an end-followed viewport ends.
    const newest_text = textBoxOf(followed.tree, &scenario.variable_log, last_index) orelse
        return error.NewestRowTextNotInTheTree;
    const probe = Probe.of(painter);
    if (!probe.inside(newest_text)) return error.NewestRowNotWhollyVisible;
    // Two rows of slack, so the margin survives a measured row height. Both
    // are measured in the device pixels this window actually presented.
    const row_px: i32 = @intFromFloat(@as(f32, @floatCast(uniform_row)) * painter.scale.y);
    const bottom_band: i32 = @as(i32, @intCast(probe.height())) - 2 * row_px;
    if (followed_pixels.variable.last_inked_bottom < bottom_band) {
        return error.NewestRowTextIsNotAtTheBottomOfTheViewport;
    }
    const previous_text = textBoxOf(followed.tree, &scenario.variable_log, last_index - 1) orelse
        return error.PreviousRowTextNotInTheTree;
    if (newest_text.y <= previous_text.y) return error.NewestRowIsNotBelowTheOneBefore;

    // 7. Focus removal. A row that scrolls out of the built range is blurred,
    //    because a widget that is not built cannot own the focus ring.
    const focus_index = range.first;
    try scenario.uniform_state.setFocused(focus_index, scenario.uniform_model.keys());
    _ = scenario.uniform_state.takeFocusChange();
    if (!try scenario.app.scrollTo(uniform, .{ 0, @floatCast(scenario.uniform_state.itemTop(focus_index) + 4_000) })) {
        return error.FocusScrollRejected;
    }
    const blurred = try scenario.frame(7, resized_width, resized_height);
    switch (scenario.uniform_state.takeFocusChange() orelse return error.NoFocusChange) {
        .blur => {},
        .focus => return error.FocusSurvivedAnUnbuiltRow,
    }
    if (scenario.uniform_state.focusedKey() != null) return error.FocusNotCleared;
    std.debug.print("focus removal: index {d} scrolled out, focus blurred\n", .{focus_index});
    _ = try checkVisibleRows(gpa, &blurred, scenario.uniform_log.count + scenario.variable_log.count, "blurred");
    _ = try checkRendered(&blurred, painter, &scenario.uniform_log, &scenario.variable_log, "blurred");
    if (options.ppm) |path| {
        try v7_frame_mod.writePpm(gpa, io, path, painter.pixels, painter.extent);
    }
    // 8. Two-frame lifetime. The tree step 6 committed is still readable and
    //    still answers with the geometry it committed, and the App names it as
    //    the previous tree. This is the window a renderer gets to read.
    if (blurred.prev_tree != followed.tree) return error.PreviousTreeIsNotTheOneCommitted;
    if (followed.tree.nodes.items.len != step6_nodes) return error.PreviousTreeShrank;
    // The previous tree is readable as a tree: its own root resolves. A frame
    // arena that was reset under it would leave nothing to resolve.
    if (followed.tree.nodes.items.len == 0) return error.PreviousTreeUnreadable;
    if (followed.tree.nodeConst(followed.tree.nodes.items[0].id) == null) {
        return error.PreviousTreeUnreadable;
    }
    if (frame6_log.used > 0) {
        const oldest = followed.tree.nodeConst(frame6_log.nodes[0]) orelse
            return error.PreviousTreeLostARow;
        if (oldest.rect.h != @as(f32, @floatCast(frame6_log.heights[0]))) {
            return error.PreviousTreeGeometryRewritten;
        }
    }

    // 9. Row geometry, read back from the committed tree: a row sits at its
    //    content-space top with the height the geometry state reported, not at
    //    an index times a constant.
    try checkRowGeometry(&followed, scenario.variable_state, &frame6_log);
    std.debug.print("two-frame lifetime held at {d} nodes; rows sit at their content tops\n", .{step6_nodes});
    if (painter.presentation()) |stats| {
        std.debug.print(
            "present: {d} frames presented, {d} acquire retries, {d} resizes requested, {d} swapchains rebuilt, {d} extent mismatches, {d} presents out of date, {d} scale changes\n",
            .{
                stats.frames_presented,
                painter.acquireRetries(),
                stats.resizes_requested,
                stats.swapchains_recreated,
                stats.extent_mismatches,
                stats.present_out_of_date,
                stats.scale_changes,
            },
        );
        // Every frame this run built and rendered reached the swapchain image,
        // and the pixels read back are out of that frame's own Oklab target.
        if (stats.frames_presented != painter.submitted) return error.PresentDidNotFollowEveryFrame;
    }
    std.debug.print(
        "{s}: {d} frames built, {d} rendered and read back\n",
        .{
            if (options.native) "native proof complete" else "offscreen proof complete",
            scenario.frames,
            painter.submitted,
        },
    );
    if (options.ppm) |path| std.debug.print("wrote {s}\n", .{path});
    _ = first_nodes;
    _ = inserted;
}
