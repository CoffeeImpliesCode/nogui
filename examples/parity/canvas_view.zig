//! W25's named consumer: a custom canvas, a REAL decoded image and a REAL
//! rendered SVG in ONE frame, drawn through the public seams.
//!
//! The custom element contract is unchanged and is the point of the file:
//!
//!   * `T.measure` is pure and read-only. It gets the known dimensions and the
//!     available space and returns the intrinsic size.
//!   * `T.prepaint` sees the FINAL resolved geometry. It runs once per frame
//!     after layout, and the geometry it receives is exactly what `paint` gets.
//!   * `T.paint` writes records through `element.PaintWriter`. Records are
//!     content-relative, and any borrowed slice (path commands, dash arrays)
//!     is COPIED into the frame arena before `paint` returns.
//!   * The frame PUBLISHES those records: after the frame commits they are
//!     readable from the committed tree, in the order the hook wrote them.
//!
//! What is REAL here, and was a fixed `texture = 7` before:
//!
//!   * `assets/canvas_badge.ppm` is decoded by `nogui_host.image.decodePpm`:
//!     a real P6 decode of a synthetic 8x8 with four authored quadrants.
//!   * `assets/canvas_mark.svg` is measured by
//!     `nogui_host.svg.queryIntrinsicSize` and rasterized by
//!     `nogui_host.svg.renderSvg` (librsvg + Cairo) into a 48x48 raster whose
//!     pixels are checked against the colours the document authored.
//!   * Both rasters are uploaded as Oklab `rgba32_float` textures and
//!     registered in the SAME bindless heap the frame binds. The custom
//!     element borrows the heap INDEX the heap returned; it never uploads,
//!     never owns a pixel and never sees image bytes in a paint hook. The
//!     decoded raster is ALSO mounted through the public `nogui.ImageView`
//!     seam, so the image path is exercised both as a custom record and as a
//!     built-in element.
//!   * Bound assets RETIRE: the heap slot is released, the texture destroyed,
//!     the decoded buffer freed and the asset-cache entry invalidated. A frame
//!     drawn after retirement shows the plate and the element's authored
//!     pending fill, and the probes check exactly that.
//!
//! THREE arms, all reachable from the command line:
//!
//!   * DEFAULT — windowless offscreen. `v7_frame.Offscreen` owns a noapi
//!     device and an Oklab render target; the shared scene lowering
//!     (`scene.buildFrameScene` / `scene.recordFrameScene`) draws into it, and
//!     the pixels are read back out of that same submission. NO window is
//!     opened, NO surface exists, NO swapchain is created and SDL is never
//!     started, so this arm runs with the display unset.
//!   * `--native` — the SAME scenario through a REAL `nogui_host.Application`
//!     window: `noapi.Surface.initSdl` adopts the SDL window's Vulkan surface,
//!     `v7_frame.NativeFrame` records the Oklab pass plus the Oklab→sRGB blit
//!     and presents, and the readback comes out of the Oklab target those same
//!     passes wrote. The window must answer with the authored 320x220 at 1:1
//!     or the run refuses rather than measuring geometry it did not author.
//!   * `--structural` — the explicit CPU-ONLY structural arm: an App, a tree
//!     and published records, with no device at all. It says so in its own
//!     output and it is NOT the acceptance arm.
//!
//! Run it: `zig build run-parity-canvas-view -- --ppm canvas.ppm`.
//! `zig build run-parity-canvas-view-native -- --ppm canvas.ppm` presents the
//! same scenario; `run-parity-canvas-view-structural` opens no GPU. The build
//! steps supply the shader paths. A direct executable takes the three scene
//! shader paths followed by `--fullscreen-vert PATH` and `--blit-oklab PATH`
//! for native presentation.
const std = @import("std");

const nogui = @import("nogui");
const host = @import("nogui_host");
const v7_frame = @import("v7_frame");
const renderer = @import("v7_render");
const sdl3 = @import("sdl3");
const font_bytes = @import("font_bytes").bytes;

const noapi = v7_frame.noapi;
const scene = v7_frame.scene;
const NativeFrame = v7_frame.NativeFrame;

const element = nogui.element;
const drawcmd = nogui.drawcmd;
const paint = nogui.paint;
const paths = nogui.path;
const widget = nogui.widget;
const App = nogui.App;
const DrawCtx = nogui.DrawCtx;
const Session = nogui.Session;
const FrameOutput = nogui.FrameOutput;
const Rect = nogui.Rect;
const WindowSize = nogui.geometry.WindowSize;
const PixelScale = nogui.geometry.PixelScale;
const TextureSlot = nogui.image_types.TextureSlot;
const ImageView = nogui.image_view.ImageView;

// ── The authored scene ───────────────────────────────────────────────────────

/// The authored logical target, and the device extent both GPU arms render at.
/// The presented arm refuses a window that answers with anything else, so the
/// logical↔device mapping is 1:1 and a probe coordinate means one thing.
const target: noapi.Extent2D = .{ .width = 320, .height = 220 };
const logical: WindowSize = .{
    .width = @floatFromInt(target.width),
    .height = @floatFromInt(target.height),
};

/// The layout surface both arms author, in the core's layout unit type. The
/// App lays out in LOGICAL units; this run authors one target, and the
/// presented arm refuses a window that answers with anything else.
fn surface() widget.Size {
    return .{ .width = logical.width, .height = logical.height };
}

const app_id: [:0]const u8 = "dev.nogui.examples.parity.canvas-view";
const window_title = "nogui canvas view";

/// Root padding, so every child's position is authored arithmetic rather than
/// a consequence of flow that a layout change could move.
const root_padding = .{ .top = 10, .right = 8, .bottom = 10, .left = 12 };
/// The custom canvas element: a border box with a real inset, so the prepaint
/// content box differs from the border box and the difference is checkable.
const spark_width: f32 = 200;
const spark_height: f32 = 120;
const spark_padding = .{ .top = 2, .right = 3, .bottom = 4, .left = 5 };
const spark_content_width: f32 = spark_width - 5 - 3;
const spark_content_height: f32 = spark_height - 2 - 4;
/// The polyline band inside the sparkline content box.
const band_height: f32 = spark_content_height;
/// Where the rasterized SVG sits inside the same content box, and at what size.
/// A 48x48 document drawn into 44x44, so the raster is really rescaled.
const mark_local = paths.Rect{ .x = 140, .y = 4, .w = 44, .h = 44 };
/// The decoded PPM, mounted through the public `ImageView` seam.
const raster_box_width: f32 = 64;
const raster_box_height: f32 = 64;

const background_color: paint.Srgb = .{ .r = 0.06, .g = 0.07, .b = 0.09 };
const ink_srgb: paint.Srgb = .{ .r = 0.1, .g = 0.4, .b = 0.9 };
const accent_srgb: paint.Srgb = .{ .r = 0.9, .g = 0.3, .b = 0.1 };
const badge_color: [4]f32 = .{ 0.2, 0.2, 0.2, 1 };
/// The fill `ImageView` authors for a source that is not ready. It is this
/// run's own colour, so the retirement frame is a probe and not a re-proof of
/// a library default.
const pending_srgb: paint.Srgb = .{ .r = 0.55, .g = 0.15, .b = 0.62 };

/// The samples the polyline walks. Fixed, so a frame is reproducible.
const sample_count = 8;
const samples_authored = [sample_count]f32{ 0.1, 0.9, 0.3, 0.7, 0.5, 0.8, 0.2, 0.6 };

// ── The assets ───────────────────────────────────────────────────────────────

/// Both files live beside this example and are embedded at compile time, so a
/// run cannot silently pick up a different file than the one it authored.
const raster_key = "canvas-badge.ppm";
const raster_bytes: []const u8 = @embedFile("assets/canvas_badge.ppm");
const mark_key = "canvas-mark.svg";
const mark_bytes: []const u8 = @embedFile("assets/canvas_mark.svg");

/// The decoded PPM's own quadrants, in authored bytes. Each quadrant is 4x4
/// texels, so a quadrant centre is two texels clear of every edge.
const raster_width: u32 = 8;
const raster_height: u32 = 8;
const raster_tl = [3]u8{ 0xE0, 0x50, 0x50 };
const raster_tr = [3]u8{ 0x50, 0xC0, 0x80 };
const raster_bl = [3]u8{ 0x50, 0x70, 0xE0 };
const raster_br = [3]u8{ 0xF0, 0xE8, 0xD0 };

fn rasterTexel(x: u32, y: u32) [3]u8 {
    return if (y < 4) (if (x < 4) raster_tl else raster_tr) else if (x < 4) raster_bl else raster_br;
}

/// The authored SVG document and the extent it must measure and rasterize to.
/// Its bottom-right quadrant authors NOTHING, so "the rasterizer invented a
/// background" is a probe like any other.
const mark_document_width: u32 = 48;
const mark_document_height: u32 = 48;
const mark_tl = [3]u8{ 0xE0, 0x40, 0x40 };
const mark_tr = [3]u8{ 0x40, 0xC0, 0x60 };
const mark_bl = [3]u8{ 0x40, 0x70, 0xE0 };

/// How far a readback pixel may sit from the authored Oklab. Every probe sits
/// in a flat interior, so a real renderer misses by nothing and only float
/// rounding shows up here.
const probe_tolerance: f32 = 0.01;
/// Bounds, never timeouts a run may quietly grow past.
const readiness_polls: u32 = 32;
const acquire_polls: u32 = 8;
const poll_delay_ms: i64 = 20;

// ── The custom elements ──────────────────────────────────────────────────────

/// The custom element's phase state, private to one frame's instance.
pub const Phase = struct {
    /// The content box `prepaint` resolved. `paint` asserts it matches.
    content: Rect = .{},
    prepaint_ran: bool = false,
    /// The number of records `paint` emitted, for the consumer to check.
    emitted: usize = 0,
};

/// A sparkline over a borrowed sample set. It is a CONTAINER element because
/// it also emits a child badge, and it declares `measure` so the layout engine
/// can size it intrinsically when the parent gives it `auto` dimensions.
///
/// `mark` is a bindless heap index the OWNER already registered, or the
/// sentinel when nothing is bound. The element never uploads, never owns a
/// texture and never sees a pixel: it only names the index in a record the
/// frame then publishes.
pub const Sparkline = struct {
    /// Samples are borrowed for the frame; `paint` copies what it needs.
    samples: []const f32,
    /// The bindless heap index of the rasterized document, or the sentinel
    /// when the owner has retired it.
    mark: u32,
    pub const PhaseState = Phase;

    pub fn measure(self: *const Sparkline, input: element.MeasureInput) element.Error!widget.Size {
        const intrinsic: f32 = @as(f32, @floatFromInt(self.samples.len)) * 12;
        const available: f32 = switch (input.available_space.width) {
            .definite => |value| value,
            .min_content, .max_content => intrinsic,
        };
        const width = input.known_dimensions.width orelse @min(intrinsic, available);
        const height = input.known_dimensions.height orelse 40;
        return .{ .width = width, .height = height };
    }

    pub fn prepaint(_: *const Sparkline, state: *PhaseState, resolved: element.Geometry) element.Error!void {
        state.content = resolved.content;
        state.prepaint_ran = true;
    }

    pub fn paint(
        self: *const Sparkline,
        state: *PhaseState,
        resolved: element.Geometry,
        writer: *element.PaintWriter,
    ) element.Error!void {
        // The paint hook runs after prepaint with the same geometry. A hook
        // that assumed otherwise would draw at stale coordinates.
        if (!state.prepaint_ran or !std.meta.eql(state.content, resolved.content)) {
            return error.PhaseReentry;
        }
        const content = resolved.content;

        // 1. The plate, in content-local coordinates.
        try writer.addRect(.{
            .bounds = .{ .x = 0, .y = 0, .w = content.w, .h = content.h },
            .fill = .{ .solid = .{ .srgb = ink_srgb } },
            .radii = .{ 3, 3, 3, 3 },
        });

        // 2. The polyline. Its commands live in a stack buffer the hook owns;
        //    `addPath` copies them into the frame arena before returning, so
        //    nothing borrowed escapes the hook.
        var scratch: [sample_count]paths.Command = undefined;
        for (self.samples, 0..) |sample, index| {
            const point: paths.Point = .{
                .x = @as(f32, @floatFromInt(index)) * step(content.w, self.samples.len),
                .y = content.h * (1 - std.math.clamp(sample, 0, 1)),
            };
            scratch[index] = if (index == 0) .{ .move = point } else .{ .line = point };
        }
        var dashes = [_]f32{ 4, 2 };
        try writer.addPath(.{
            .bounds = .{ .x = 0, .y = 0, .w = content.w, .h = content.h },
            .path = .{ .commands = &scratch },
            .stroke = .{ .color = .{ .srgb = accent_srgb }, .width = 2, .dash = &dashes },
        });

        // 3. The renderer-neutral image record for the rasterized SVG. The
        //    index is borrowed; the record names where its pixels already are.
        //    An owner that has retired the texture publishes the sentinel, and
        //    then this hook emits NO image at all: the writer would refuse the
        //    sentinel, and a frame with nothing bound must not name a texture.
        if (self.mark != 0xFFFFFFFF) {
            try writer.addImage(.{
                .bounds = mark_local,
                .src = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
                .texture_index = self.mark,
            });
        }
        state.emitted = writer.records.items.len;
    }
};

fn step(width: f32, count: usize) f32 {
    if (count <= 1) return 0;
    return width / @as(f32, @floatFromInt(count - 1));
}

/// A leaf badge: no children, so `elementLeaf` is the right call. It proves
/// both element entry points work and that a leaf still gets measure + paint.
pub const Badge = struct {
    text: []const u8,
    pub const PhaseState = struct {
        content: Rect = .{},
        emitted: usize = 0,
    };

    pub fn measure(_: *const Badge, input: element.MeasureInput) element.Error!widget.Size {
        return .{
            .width = input.known_dimensions.width orelse 24,
            .height = input.known_dimensions.height orelse 16,
        };
    }

    pub fn prepaint(_: *const Badge, state: *PhaseState, resolved: element.Geometry) element.Error!void {
        state.content = resolved.content;
    }

    pub fn paint(
        _: *const Badge,
        state: *PhaseState,
        resolved: element.Geometry,
        writer: *element.PaintWriter,
    ) element.Error!void {
        try writer.rect(
            .{ .x = 0, .y = 0, .w = resolved.content.w, .h = resolved.content.h },
            badge_color,
        );
        state.emitted = writer.records.items.len;
    }
};

// ── The model ────────────────────────────────────────────────────────────────

/// What the host published into the model about one bound asset. The model
/// carries IDs and versions ONLY: the pixels and the GPU textures stay with
/// their owner, which is what lets the elements borrow them.
pub const Bound = struct {
    /// The bindless heap index, or the sentinel when nothing is bound.
    index: u32 = 0xFFFFFFFF,
    /// The generation the SLOT carries. The owner sets it when it registers
    /// the index, and it does not change while that index is bound.
    slot_generation: u64 = 0,
    /// The asset version this binding is FOR. A binding whose version has
    /// moved on is STALE: the element must refuse it rather than sample
    /// whatever now owns the slot.
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub const none: Bound = .{};

    /// The heap slot this binding names, in the form the element seam takes.
    pub fn slot(self: Bound) TextureSlot {
        return .{ .index = self.index, .generation = self.slot_generation };
    }

    /// True only while the version this binding is for is still the version
    /// its slot carries.
    pub fn isFresh(self: Bound) bool {
        return self.index != 0xFFFFFFFF and self.slot_generation == self.generation;
    }
};

/// The Session model: the sample set and the two asset bindings. Nothing here
/// owns memory or a GPU handle, so releasing the model cannot leak one.
pub const Board = struct {
    samples: [sample_count]f32 = samples_authored,
    phase: u32 = 0,
    revision: u64 = 0,
    raster: Bound = Bound.none,
    mark: Bound = Bound.none,

    /// Called by the Session when the last owner releases the model.
    pub fn deinit(self: *Board, _: *Session) void {
        self.* = undefined;
    }

    /// Rotate the samples by the delivered step, so a later frame is
    /// observably a different polyline.
    pub fn applyStep(board: *Board, work: *Step, _: *Session) void {
        board.phase +%= work.steps;
        board.revision += 1;
        const rotation: usize = board.phase % sample_count;
        var rotated: [sample_count]f32 = undefined;
        for (0..sample_count) |index| {
            rotated[index] = samples_authored[(index + rotation) % sample_count];
        }
        board.samples = rotated;
    }
};

/// One delivered UI task. Small and plain: the payload is moved into the job.
pub const Step = struct { steps: u32 };

/// The mounted root. It COPIES what it needs out of the model inside `draw`,
/// because `prepaint` and `paint` run after the model borrow has ended.
pub const CanvasView = struct {
    /// The App window this view draws for. The model read is recorded against
    /// it, so a delivered task asks this window to repaint.
    window: u64,
    samples: [sample_count]f32 = samples_authored,
    raster: Bound = Bound.none,
    mark: Bound = Bound.none,
    /// The model revision this view last drew, taken while the borrow is
    /// live: the driver checks it against the step it delivered.
    seen_revision: u64 = 0,
    spark_id: ?nogui.FrameNodeId = null,
    badge_id: ?nogui.FrameNodeId = null,
    image_id: ?nogui.FrameNodeId = null,

    pub fn draw(self: *CanvasView, board: *const Board, ctx: *DrawCtx) !void {
        self.seen_revision = board.revision;
        self.samples = board.samples;
        self.raster = board.raster;
        self.mark = board.mark;

        // The root is a container that fills the window: what nothing else
        // covers shows the fill authored here, so an unpainted pixel is a
        // known colour rather than the pipeline's clear.
        _ = try ctx.column(.{
            .fill = paint.Color{ .srgb = background_color },
            .padding = root_padding,
        });

        self.spark_id = try ctx.elementContainer(Sparkline, .{
            .samples = &self.samples,
            // A binding whose version has moved on is refused HERE, so the
            // hook only ever sees an index the owner still stands behind.
            .mark = if (self.mark.isFresh()) self.mark.index else 0xFFFFFFFF,
        }, .{
            .key = @as(nogui.ComponentKey, .{ .static = "spark" }),
            .width = spark_width,
            .height = spark_height,
            // A border box with padding gives the prepaint content box a real,
            // checkable inset rather than the border box itself.
            .box_sizing = .border_box,
            .padding = spark_padding,
            .clip = true,
        });
        // The container is still open, so a real child nests inside it.
        self.badge_id = try ctx.elementLeaf(Badge, .{ .text = "new" }, .{
            .key = @as(nogui.ComponentKey, .{ .static = "badge" }),
            .width = 20,
            .height = 12,
        });
        ctx.pop();

        // The decoded raster through the PUBLIC image seam, so the same
        // texture is exercised as a built-in element and as a custom record.
        // The slot carries the generation the OWNER registered and the view
        // carries the version the MODEL is showing: when those two disagree
        // the element paints its pending fill instead of sampling a slot that
        // belongs to a retired asset. The value is typed here so the source
        // variant is never inferred from two different literals.
        const raster_source: nogui.image_view.Source = if (self.raster.index == 0xFFFFFFFF)
            .pending
        else
            .{ .ready = self.raster.slot() };
        self.image_id = try ctx.elementLeaf(ImageView, .{
            .intrinsic = .{
                .width = @floatFromInt(raster_width),
                .height = @floatFromInt(raster_height),
            },
            .source = raster_source,
            .generation = self.raster.generation,
            .fit = .fill,
            .alignment = .top_left,
            .label = "decoded badge",
            .pending_fill = .{ .srgb = pending_srgb },
        }, .{
            .key = @as(nogui.ComponentKey, .{ .static = "badge-image" }),
            .width = raster_box_width,
            .height = raster_box_height,
        });
        ctx.pop();
    }
};

// ── The asset owner ──────────────────────────────────────────────────────────

/// Owns everything the two assets really are: the asset-manager entries, the
/// decoded CPU rasters, the uploaded GPU textures and the bindless heap slots
/// the elements borrow. Nothing here is ever reached from a paint hook.
const Assets = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    gpu: *noapi.Gpu,
    heap: *v7_frame.BindlessHeap,
    manager: host.assets.AssetManager,
    raster: host.image.DecodedImage = undefined,
    mark: host.image.DecodedImage = undefined,
    mark_intrinsic: host.image.Size = .{ .width = 0, .height = 0 },
    raster_texture: noapi.TextureHandle = .{},
    mark_texture: noapi.TextureHandle = .{},
    raster_bound: Bound = Bound.none,
    mark_bound: Bound = Bound.none,
    live: bool = false,

    /// Decode both embedded assets for real, upload both for real and register
    /// both in the heap the frame will bind. Any failure releases whatever was
    /// already acquired and propagates the ORIGINAL error.
    fn bind(self: *Assets) !void {
        try self.manager.embedded.register(raster_key, raster_bytes);
        errdefer self.manager.embedded.unregister(raster_key);
        try self.manager.embedded.register(mark_key, mark_bytes);
        errdefer self.manager.embedded.unregister(mark_key);

        // The asset seam hands out cache-owned bytes; they stay resident for
        // as long as the texture derived from them is bound.
        const raster_source = switch (self.manager.load(host.assets.AssetKey.init(.embedded, raster_key))) {
            .ready => |bytes| bytes,
            .pending => return error.RasterAssetPending,
            .failed => |failure| return failure,
        };
        self.raster = try host.image.decodePpm(self.gpa, raster_source);
        errdefer self.raster.deinit();
        if (self.raster.width != raster_width or self.raster.height != raster_height) {
            return error.RasterIsNotTheAuthoredSize;
        }
        try self.checkDecodedRaster();

        const mark_source = switch (self.manager.load(host.assets.AssetKey.init(.embedded, mark_key))) {
            .ready => |bytes| bytes,
            .pending => return error.MarkAssetPending,
            .failed => |failure| return failure,
        };
        const engine = host.svg.SvgEngine.getGlobal(self.io);
        if (!engine.isAvailable()) return error.SvgEngineUnavailable;
        const intrinsic = (try host.svg.queryIntrinsicSize(self.io, mark_source)) orelse
            return error.SvgHasNoIntrinsicSize;
        if (intrinsic.width != @as(f32, @floatFromInt(mark_document_width)) or
            intrinsic.height != @as(f32, @floatFromInt(mark_document_height)))
        {
            return error.SvgIntrinsicSizeChanged;
        }
        self.mark_intrinsic = intrinsic;
        self.mark = try host.svg.renderSvg(self.gpa, self.io, mark_source, .{
            .viewport_width = mark_document_width,
            .viewport_height = mark_document_height,
            .dpi_scale = 1.0,
        });
        errdefer self.mark.deinit();
        try self.checkDecodedMark();

        self.raster_texture = try uploadOklab(self.gpu, &self.raster);
        errdefer self.gpu.textureDestroy(self.raster_texture);
        const raster_index = try self.heap.register(self.gpa, self.raster_texture);
        errdefer self.heap.release(self.gpa, self.raster_texture);

        self.mark_texture = try uploadOklab(self.gpu, &self.mark);
        errdefer self.gpu.textureDestroy(self.mark_texture);
        const mark_index = try self.heap.register(self.gpa, self.mark_texture);
        errdefer self.heap.release(self.gpa, self.mark_texture);

        // Both the slot generation and the served version start at 1. The
        // slot generation belongs to the registration; the version is what the
        // owner is currently showing.
        self.raster_bound = .{
            .index = raster_index,
            .slot_generation = 1,
            .generation = 1,
            .width = self.raster.width,
            .height = self.raster.height,
        };
        self.mark_bound = .{
            .index = mark_index,
            .slot_generation = 1,
            .generation = 1,
            .width = mark_document_width,
            .height = mark_document_height,
        };
        self.live = true;
    }

    /// Check the decoded raster against the authored bytes. This is a CPU
    /// check of the DECODER, kept beside the GPU probes that check the
    /// sampler, so a failure names which of the two moved.
    fn checkDecodedRaster(self: *const Assets) !void {
        const stride = std.math.cast(usize, self.raster.stride) orelse
            return error.RasterStrideUnreadable;
        if (self.raster.pixels.len < stride * self.raster.height) return error.RasterIsShort;
        var y: u32 = 0;
        while (y < raster_height) : (y += 1) {
            var x: u32 = 0;
            while (x < raster_width) : (x += 1) {
                const source = @as(usize, y) * stride + @as(usize, x) * 4;
                const wanted = rasterTexel(x, y);
                for (0..3) |channel| {
                    if (self.raster.pixels[source + channel] != wanted[channel]) {
                        return error.DecodedRasterTexelMismatch;
                    }
                }
                if (self.raster.pixels[source + 3] != 0xFF) return error.DecodedRasterIsNotOpaque;
            }
        }
    }

    /// Check the rasterized document against the colours it authored: one
    /// interior point per authored quadrant, plus the quadrant that authors
    /// nothing at all.
    fn checkDecodedMark(self: *const Assets) !void {
        if (self.mark.width != mark_document_width or self.mark.height != mark_document_height) {
            return error.RenderedMarkIsNotTheAuthoredViewport;
        }
        const stride = std.math.cast(usize, self.mark.stride) orelse
            return error.MarkStrideUnreadable;
        const probes = [_]struct { x: u32, y: u32, color: ?[3]u8 }{
            .{ .x = 12, .y = 12, .color = mark_tl },
            .{ .x = 36, .y = 12, .color = mark_tr },
            .{ .x = 12, .y = 36, .color = mark_bl },
            .{ .x = 36, .y = 36, .color = null },
        };
        for (probes) |probe| {
            const base = @as(usize, probe.y) * stride + @as(usize, probe.x) * 4;
            if (base + 4 > self.mark.pixels.len) return error.MarkIsShort;
            if (probe.color) |wanted_bytes| {
                if (self.mark.pixels[base + 3] < 250) return error.RenderedMarkIsTransparent;
                for (0..3) |channel| {
                    const actual: i32 = @intCast(self.mark.pixels[base + channel]);
                    const wanted: i32 = @intCast(wanted_bytes[channel]);
                    if (@abs(actual - wanted) > 4) return error.RenderedMarkChannelMismatch;
                }
            } else if (self.mark.pixels[base + 3] != 0) {
                return error.RenderedMarkInventedTheEmptyQuadrant;
            }
        }
    }

    /// Retire every bound asset: return the heap slot, destroy the texture,
    /// free the decoded buffer and drop the cache entry. The device is still
    /// alive here; nothing may be released after it.
    fn retire(self: *Assets) void {
        if (self.live) {
            self.heap.release(self.gpa, self.raster_texture);
            self.heap.release(self.gpa, self.mark_texture);
            self.gpu.textureDestroy(self.raster_texture);
            self.gpu.textureDestroy(self.mark_texture);
            self.raster_texture = .{};
            self.mark_texture = .{};
            self.raster_bound = Bound.none;
            self.mark_bound = Bound.none;
            self.raster.deinit();
            self.mark.deinit();
            _ = self.manager.invalidate(host.assets.AssetKey.init(.embedded, raster_key));
            _ = self.manager.invalidate(host.assets.AssetKey.init(.embedded, mark_key));
            self.live = false;
        }
        self.gpu.waitIdle() catch |err|
            std.debug.panic("canvas-view: asset retirement drain refused {s}", .{@errorName(err)});
    }

    fn deinit(self: *Assets) void {
        self.manager.deinit();
        self.* = undefined;
    }
};

/// A decoded RGBA8 image as the pipeline's own Oklab floats, copied through
/// the noapi staging path. Ends in a queue idle, so it runs between frames.
/// rgba8 UNORM cannot hold the negative Oklab ab chroma the pipeline renders
/// in, which is why every uploaded asset here is floats.
fn uploadOklab(gpu: *noapi.Gpu, image: *const host.image.DecodedImage) !noapi.TextureHandle {
    const pixel_count = std.math.mul(usize, image.width, image.height) catch
        return error.ImageTooLarge;
    const stride = std.math.cast(usize, image.stride) orelse return error.UnsupportedUploadFormat;
    if (image.pixels.len < stride * @as(usize, image.height)) return error.BufferUnderflow;

    const texture = try gpu.textureCreate(.{
        .dimensions = .{ image.width, image.height, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    errdefer gpu.textureDestroy(texture);

    const staging = try gpu.gpuMalloc(
        @intCast(pixel_count * 4 * @sizeOf(f32)),
        64,
        .default,
    );
    defer gpu.gpuFree(staging);
    const out: [*]f32 = @ptrCast(@alignCast(staging.cpu));
    for (0..pixel_count) |index| {
        const row = index / @as(usize, image.width);
        const column = index % @as(usize, image.width);
        const source = row * stride + column * 4;
        const lab = v7_frame.srgbToOklab(.{
            @as(f32, @floatFromInt(image.pixels[source])) / 255.0,
            @as(f32, @floatFromInt(image.pixels[source + 1])) / 255.0,
            @as(f32, @floatFromInt(image.pixels[source + 2])) / 255.0,
            @as(f32, @floatFromInt(image.pixels[source + 3])) / 255.0,
        });
        out[index * 4 + 0] = lab[0];
        out[index * 4 + 1] = lab[1];
        out[index * 4 + 2] = lab[2];
        out[index * 4 + 3] = lab[3];
    }

    var command = try gpu.commandsBegin();
    var pending = true;
    errdefer if (pending) {
        gpu.commandsCancel(&command) catch
            @panic("canvas-view upload recording cancellation failed");
    };
    command.copyToTexture(.{
        .gpu = gpu,
        .handle = texture,
        .dimensions = .{ image.width, image.height, 1 },
        .format = .rgba32_float,
    }, staging, .{ .size = .{ image.width, image.height, 1 } });
    try gpu.queueSubmit(&.{command});
    pending = false;
    try gpu.waitIdle();
    return texture;
}

// ── The rendering arms ───────────────────────────────────────────────────────

const Mode = enum {
    windowless,
    presented,
    structural,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .windowless => "windowless offscreen",
            .presented => "native window",
            .structural => "CPU structural (no device)",
        };
    }
};

/// The two arms that reach a device. `structural` never constructs a Painter.
const PaintMode = enum { windowless, presented };

const Shaders = struct {
    vert: []const u32,
    frag: []const u32,
    sort: []const u32,
};

const BlitShaders = struct {
    fullscreen: []const u32,
    oklab: []const u32,
};

/// The frame pipeline, in the two forms the two GPU modes need. The caller
/// owns the SPIR-V and the font; this owns the GPU objects, the per-frame
/// scratch and — in the presented form — the window, the device and the
/// surface. It lives behind a pointer because the scene scratch, the endpoint
/// and the noapi state all hold addresses into it.
const Painter = struct {
    pub const Options = struct {
        mode: PaintMode,
        shaders: Shaders,
        /// The presented arm's blit pair. `init` copies the words into shader
        /// objects, so they need not outlive it.
        blit: BlitShaders,
        /// The App the window belongs to: a host window owns exactly one App.
        app: *App,
        session: *Session,
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    path: Path,
    /// The Oklab pixels of the last submission. The readback buffer is reused,
    /// so these die at the next render.
    pixels: []const f32 = &.{},
    /// Frames this painter submitted and read back.
    submitted: u32 = 0,

    const Path = union(enum) {
        windowless: Windowless,
        presented: Presented,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Painter.Options) !*Painter {
        const self = try gpa.create(Painter);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
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

    /// RETIRE every device-side resource. The App has already detached from
    /// the endpoint and the window and SDL are still up.
    pub fn retire(self: *Painter) void {
        switch (self.path) {
            .windowless => |*w| w.retire(),
            .presented => |*p| p.retire(),
        }
    }

    /// CLOSE the window and then the host. The borrowed App, view and model
    /// are still alive here, so a borrowed App outlives its window.
    pub fn closeHost(self: *Painter) void {
        switch (self.path) {
            .windowless => {},
            .presented => |*p| p.closeHost(self.gpa),
        }
    }

    pub fn destroy(self: *Painter) void {
        self.gpa.destroy(self);
    }

    /// The one endpoint the App mounts: this path's own.
    pub fn endpoint(self: *Painter) *nogui.GpuEndpoint {
        return switch (self.path) {
            .windowless => |*w| w.offscreen.endpoint(),
            .presented => |*p| p.adapter.gpuEndpoint(),
        };
    }

    /// The device the assets are uploaded to and destroyed on.
    pub fn gpu(self: *Painter) *noapi.Gpu {
        return switch (self.path) {
            .windowless => |*w| w.offscreen.gpu(),
            .presented => |*p| &p.gpu,
        };
    }

    /// The bindless heap the frame binds, so a registered index is one the
    /// sampled frame really has.
    pub fn heap(self: *Painter) *v7_frame.BindlessHeap {
        return switch (self.path) {
            .windowless => |*w| w.offscreen.heap(),
            .presented => |*p| p.adapter.textureHeap(),
        };
    }

    /// The measure source this painter's OWN text engine provides. The App
    /// holds the value, so a measured label and a painted glyph are one
    /// measurement whichever path this run took.
    pub fn measurer(self: *Painter) nogui.layout.MeasureSource {
        return switch (self.path) {
            .windowless => |*w| w.text.measurer(),
            .presented => |*p| p.adapter.measurer(),
        };
    }

    /// Glyph material slots the engine rasterized into, whichever engine this
    /// is. This scene draws no text, so it is reported rather than asserted.
    pub fn glyphSlots(self: *Painter) u32 {
        return switch (self.path) {
            .windowless => |*w| w.text.glyphSlotCount(),
            .presented => |*p| p.adapter.textEngine().glyphSlotCount(),
        };
    }

    /// The recording the App builds this frame in.
    pub fn gpuFrame(self: *Painter) *nogui.GpuFrame {
        return switch (self.path) {
            .windowless => |*w| &w.gpu_frame,
            .presented => |*p| &p.frame.gpu_frame,
        };
    }

    pub fn beginFrame(self: *Painter) !void {
        self.pixels = &.{};
        switch (self.path) {
            .windowless => |*w| try w.beginFrame(),
            .presented => |*p| try p.beginFrame(self.io),
        }
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

    /// Discard a recording whose frame failed before the submission.
    pub fn cancelFrame(self: *Painter) void {
        switch (self.path) {
            .windowless => |*w| w.cancelFrame(),
            .presented => |*p| p.cancelFrame(),
        }
    }

    /// What the presented path observed about its own presentation, or null in
    /// the windowless path, which presents nothing and counts nothing.
    pub fn presentation(self: *Painter) ?NativeFrame.Stats {
        return switch (self.path) {
            .windowless => null,
            .presented => |*p| p.adapter.stats,
        };
    }

    /// The windowless pipeline: the shared scene lowering and the shared text
    /// engine over a `v7_frame.Offscreen` target. No window, no surface, no
    /// swapchain and no present.
    const Windowless = struct {
        loader: v7_frame.SystemVulkanLoader,
        offscreen: v7_frame.Offscreen,
        text: v7_frame.TextEngine,
        gui: renderer.Renderer,
        scratch: scene.SceneScratch,
        cmd: noapi.CommandBuffer = undefined,
        gpu_frame: nogui.GpuFrame = undefined,
        index: u32 = 0,

        fn init(self: *Windowless, gpa: std.mem.Allocator, io: std.Io, shaders: Shaders) !void {
            // The loader stays open until every GPU made from its options is gone.
            self.loader = try v7_frame.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.offscreen = try v7_frame.Offscreen.init(.{
                .allocator = gpa,
                .io = io,
                .loader = self.loader.options(),
                .extent = target,
                .app_name = "nogui_canvas_view",
            });
            errdefer self.offscreen.deinit();
            self.text = try v7_frame.TextEngine.init(gpa, self.offscreen.gpu(), &.{
                .{ .family = "InterVariable", .bytes = font_bytes },
            });
            errdefer self.text.deinit();
            try self.text.setGlyphSlotLimit(scene.glyph_material_ceiling);
            self.gui = try renderer.Renderer.init(
                self.offscreen.gpu(),
                shaders.vert,
                shaders.frag,
                shaders.sort,
            );
            errdefer self.gui.deinit();
            self.gui.configure(.{ .material_bda = self.text.materialBda() });
            self.scratch = scene.SceneScratch.init(gpa, &self.gui);
            self.index = 0;
        }

        fn retire(self: *Windowless) void {
            self.scratch.deinit();
            self.gui.deinit();
            self.text.deinit();
            self.offscreen.deinit();
            self.loader.close();
        }

        fn beginFrame(self: *Windowless) !void {
            try self.offscreen.beginFrame(self.index, &self.cmd, &self.gpu_frame);
            self.index = (self.index + 1) % @as(u32, self.offscreen.gpu().frames_in_flight);
        }

        /// This is the whole submission stage: the same lowering and the same
        /// record the presented path uses, with no window in sight.
        fn render(self: *Windowless, output: *const FrameOutput) ![]const f32 {
            errdefer self.cancelFrame();
            self.scratch.beginFrame();
            var painted = try scene.buildFrameScene(&self.scratch, &self.text, .{}, output, false);
            defer painted.deinit();
            const device = self.offscreen.extent();
            const record: scene.RecordContext = .{
                .arena = output.tree.allocator,
                .renderer = &self.gui,
                .text = &self.text,
                .logical = logical,
                .device = device,
                .texture_heap = self.offscreen.heap().handle,
                .clips = output.tree.clip_rects[0..output.tree.clip_count],
            };
            _ = try scene.recordFrameScene(
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
                @panic("canvas-view offscreen recording cancellation failed");
        }
    };

    /// The presented pipeline: the SAME lowering and the SAME text engine over
    /// `v7_frame.NativeFrame`, into a real window's swapchain image.
    const Presented = struct {
        application: *host.Application,
        handle: nogui.window_contract.WindowHandle = undefined,
        managed: *host.ManagedWindow = undefined,
        native_id: sdl3.video.WindowId = 0,
        /// The frame module's own loader, the same one the windowless path
        /// builds its device from. It stays open until that device is gone.
        loader: v7_frame.SystemVulkanLoader = undefined,
        gpu: noapi.Gpu = undefined,
        /// The platform surface `noapi.Surface.initSdl` created from the SDL
        /// window and adopted. It owns the `VkSurfaceKHR` on the way out, so
        /// no SDL wrapper is kept beside it.
        surface: noapi.Surface = undefined,
        adapter: NativeFrame = undefined,
        frame: NativeFrame.Frame = undefined,
        /// Acquires the swapchain refused, retried inside `beginFrame`.
        retries: u32 = 0,
        scale: PixelScale = .{ .x = 1, .y = 1 },
        visible: bool = false,

        fn init(self: *Presented, gpa: std.mem.Allocator, io: std.Io, options: Painter.Options) !void {
            self.* = .{ .application = try gpa.create(host.Application) };
            errdefer gpa.destroy(self.application);
            self.application.* = try host.Application.init(gpa, options.session, .{ .app_id = app_id });
            errdefer self.application.deinit();
            // The window is this run's for the length of the measurement: a
            // platform close is vetoed and losing the last window does not ask
            // the process to quit. No input and no frame callback are
            // registered: this run drives its own frames.
            self.application.setHooks(.{
                .context = self,
                .on_close_request = vetoClose,
                .on_last_window_closed = keepRunning,
            });
            self.handle = try self.application.openWindowWithApp(options.app, .{
                .title = window_title,
                .width = target.width,
                .height = target.height,
                .resizable = false,
                .visible = true,
                .gpu_surface = true,
            });
            self.managed = try self.application.getWindow(self.handle);
            self.native_id = self.managed.native.id;
            // The authored target or no run at all: every probe below is
            // measured against `target`.
            try self.awaitAuthoredTarget(io);
            self.loader = try v7_frame.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.gpu = try noapi.Gpu.init(.{
                // Three, not two: the renderer rings its per-frame paint
                // buffers over three slots, one per in-flight frame.
                .frames_in_flight = scene.frames_in_flight,
                .app_name = "nogui_canvas_view",
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
            // back: the instance and the platform handle never leave noapi, and
            // a failed call destroys what the platform made. The surface is not
            // built on an unmeasured size.
            self.surface = try noapi.Surface.initSdl(
                &self.gpu,
                @ptrCast(self.managed.native.sdl.value),
                @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
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
                .name = "nogui_canvas_view_blit_oklab",
            });
        }

        /// Every device-side resource, in the order this arm owns them: the
        /// adapter, then the surface, then the device, then the loader. The
        /// window and SDL are still up when this returns.
        fn retire(self: *Presented) void {
            self.adapter.deinit();
            self.surface.deinit();
            self.gpu.deinit();
            self.loader.close();
        }

        /// The window goes, then the host. The App, view and model are still
        /// alive, so closing retires only the window's session identity.
        fn closeHost(self: *Presented, gpa: std.mem.Allocator) void {
            self.application.setHooks(.{});
            const closed = self.application.closeWindow(self.handle) catch |err| blk: {
                std.debug.print("  the host refused the close: {s}\n", .{@errorName(err)});
                break :blk false;
            };
            if (!closed) std.debug.print("  the host declined to close the window\n", .{});
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

        /// True when the window IS the authored target: the same logical size,
        /// the same device pixel size, and therefore a 1:1 scale.
        fn isAuthoredTarget(self: *Presented) bool {
            const state = self.managed.observed;
            return state.size.width == target.width and state.size.height == target.height and
                state.pixels.width == target.width and state.pixels.height == target.height;
        }

        /// Pump the host until the window has SHOWN at the authored geometry,
        /// bounded, and report what it actually answered if it never does.
        fn awaitAuthoredTarget(self: *Presented, io: std.Io) !void {
            var polls: u32 = 0;
            while (polls < readiness_polls) : (polls += 1) {
                _ = try self.application.step();
                try self.managed.refresh();
                if (!self.isAuthoredTarget()) {
                    self.reportGeometry(polls);
                    return error.NativeGeometryIsNotTheAuthoredTarget;
                }
                if (self.managed.observed.visible) {
                    self.scale = try self.managed.observed.pixelScale();
                    if (self.scale.x != 1 or self.scale.y != 1) {
                        self.reportGeometry(polls);
                        return error.NativeScaleIsNotOne;
                    }
                    self.visible = true;
                    return;
                }
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
            }
            self.reportGeometry(polls);
            return error.NativeWindowNeverBecameVisible;
        }

        /// The geometry the window ANSWERED, next to the one this run authored,
        /// so a refusal is never just a name.
        fn reportGeometry(self: *const Presented, polls: u32) void {
            const state = self.managed.observed;
            std.debug.print(
                "  authored {d}x{d}, window logical {d}x{d}, device {d}x{d}, visible={}, polls={d}\n",
                .{
                    target.width,
                    target.height,
                    state.size.width,
                    state.size.height,
                    state.pixels.width,
                    state.pixels.height,
                    state.visible,
                    polls,
                },
            );
        }

        /// Acquire the next image, retarget the Oklab pass to it and open the
        /// recording. A swapchain that is out of date is not a failure: the
        /// acquire is retried inside a bound, so a driver that never settles
        /// fails the run instead of spinning.
        fn beginFrame(self: *Presented, io: std.Io) !void {
            var attempts: u32 = 0;
            while (attempts < acquire_polls) : (attempts += 1) {
                const viewport: NativeFrame.Viewport = .{
                    .logical = logical,
                    .device = try self.deviceExtent(),
                    .scale = self.scale,
                };
                if (try self.adapter.beginFrame(&self.surface, viewport, &self.frame)) return;
                self.retries += 1;
                _ = try self.application.step();
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
            }
            return error.SwapchainNeverSettled;
        }

        /// The App's tree, the Oklab pass, the blit and the present are ONE
        /// event: a frame this run calls committed is a frame whose pixels
        /// reached the swapchain image.
        fn render(self: *Presented, output: *const FrameOutput) ![]const f32 {
            var painted = try self.adapter.buildScene(.{}, output);
            defer painted.deinit();
            try self.adapter.recordScene(&self.surface, &self.frame, output, &painted);
            // `present` closes the recording itself, so a present that fails
            // must propagate rather than reach a cancellation of a recording
            // that is gone.
            try self.adapter.present(&self.surface, &self.frame);
            self.managed.markPresented();
            return self.adapter.readTarget();
        }

        fn cancelFrame(self: *Presented) void {
            self.adapter.cancelFrame(&self.frame) catch |err| switch (err) {
                error.FrameNotRecording => {},
                else => @panic("canvas-view presented recording cancellation failed"),
            };
        }

        fn vetoClose(_: *anyopaque, _: nogui.window_contract.WindowHandle) bool {
            return false;
        }

        fn keepRunning(_: *anyopaque, _: *host.Application) host.Application.LastWindowDecision {
            return .keep_running;
        }
    };
};

// ── Probing the pixels ───────────────────────────────────────────────────────

/// The Oklab colour of one readback pixel. The pass renders in Oklab, so this
/// is the value the pipeline itself wrote, never a rounded sRGB byte.
const Lab = [3]f32;

const Probe = struct {
    pixels: []const f32,
    extent: noapi.Extent2D,

    fn labAt(self: Probe, x: u32, y: u32) Lab {
        const w: usize = self.extent.width;
        const base = (@as(usize, y) * w + @as(usize, x)) * 4;
        return .{ self.pixels[base], self.pixels[base + 1], self.pixels[base + 2] };
    }

    fn matches(self: Probe, x: u32, y: u32, expected: Lab) bool {
        const actual = self.labAt(x, y);
        return @abs(actual[0] - expected[0]) <= probe_tolerance and
            @abs(actual[1] - expected[1]) <= probe_tolerance and
            @abs(actual[2] - expected[2]) <= probe_tolerance;
    }

    fn countNear(self: Probe, box: Rect, expected: Lab) usize {
        var count: usize = 0;
        var y: u32 = @intFromFloat(@max(0, box.y));
        const y_end: u32 = @intFromFloat(@max(0, box.y + box.h));
        while (y < y_end and y < self.extent.height) : (y += 1) {
            var x: u32 = @intFromFloat(@max(0, box.x));
            const x_end: u32 = @intFromFloat(@max(0, box.x + box.w));
            while (x < x_end and x < self.extent.width) : (x += 1) {
                if (self.matches(x, y, expected)) count += 1;
            }
        }
        return count;
    }
};

/// The Oklab a fill authored in sRGB must read back as. It is computed with
/// the SAME public conversion the pipeline's own fill path uses, so a matched
/// probe says the authored colour survived the frame, not that this file can
/// repeat a matrix.
fn authored(srgb: paint.Srgb) Lab {
    const lab = v7_frame.srgbToOklab(.{ srgb.r, srgb.g, srgb.b, srgb.a });
    return .{ lab[0], lab[1], lab[2] };
}

/// The same for one authored byte triple.
fn authoredBytes(rgb: [3]u8) Lab {
    const lab = v7_frame.srgbToOklab(.{
        @as(f32, @floatFromInt(rgb[0])) / 255.0,
        @as(f32, @floatFromInt(rgb[1])) / 255.0,
        @as(f32, @floatFromInt(rgb[2])) / 255.0,
        1.0,
    });
    return .{ lab[0], lab[1], lab[2] };
}

fn reportProbe(probe: Probe, name: []const u8, x: u32, y: u32, expected: Lab) bool {
    const actual = probe.labAt(x, y);
    const held = probe.matches(x, y, expected);
    std.debug.print(
        "  probe {s} ({d},{d}) oklab=({d:.4},{d:.4},{d:.4}) expected=({d:.4},{d:.4},{d:.4}) {s}\n",
        .{
            name,      x,           y,           actual[0],   actual[1],
            actual[2], expected[0], expected[1], expected[2], if (held) "held" else "MISSED",
        },
    );
    return held;
}

/// Everything one rendered frame proves: the published records, the geometry
/// that produced them, the bound material indices and the pixels.
fn probeFrame(
    gpa: std.mem.Allocator,
    scenario: *Scenario,
    painter: *Painter,
    output: *const FrameOutput,
    pixels: []const f32,
    expect_bound: bool,
) !usize {
    const view = scenario.view;
    const spark = view.spark_id orelse return error.MissingSparkline;
    const badge = view.badge_id orelse return error.MissingBadge;
    const image = view.image_id orelse return error.MissingImageView;
    const node = output.tree.nodeConst(spark) orelse return error.MissingSparklineNode;
    const state = node.kind.element.phaseState(Phase);

    // 1. Geometry, read back from the committed tree. A 200x120 border box
    //    with 5/2/3/4 padding has a 192x114 content box, and prepaint recorded
    //    exactly the box the paint hook was handed.
    if (!state.prepaint_ran) return error.PrepaintDidNotRun;
    if (!std.meta.eql(state.content, widget.visualContentRect(output.tree, spark))) {
        return error.PublishedGeometryIsNotTheCommittedContentBox;
    }
    if (state.content.w != spark_content_width or state.content.h != spark_content_height) {
        return error.ContentBoxIsNotThePaddedInset;
    }
    // The child leaf is a real descendant of the container element.
    const badge_frame = output.tree.frameNode(
        scenario.app.widgetIdForKey(nogui.ComponentId.root, .{ .static = "badge" }) orelse
            return error.MissingBadgeId,
    ) orelse return error.MissingBadgeNode;
    if (output.tree.nodeConst(badge_frame).?.parent != spark) return error.BadgeIsNotAChildOfTheContainer;

    // 2. The published records, in the order the hook wrote them.
    const records = publishedRecords(output.tree, spark);
    if (expect_bound) {
        if (records.len != 3) return error.BoundFrameDidNotPublishThreeRecords;
        if (records[2].image.texture_index != view.mark.index) {
            return error.ImageRecordDoesNotNameTheBoundSlot;
        }
        const stroke = records[1].path.stroke orelse return error.MissingStroke;
        if (stroke.width != 2) return error.StrokeWidthMoved;
        // The dash array the hook wrote from a stack local survived the hook.
        if (!std.mem.eql(f32, stroke.dash, &.{ 4, 2 })) return error.DashArrayWasNotCopied;
        const commands = records[1].path.path.commands;
        if (commands.len != sample_count) return error.PathCommandCountMoved;
        const first = switch (commands[0]) {
            .move => |point| point,
            else => return error.ExpectedMoveFirst,
        };
        if (first.x != 0) return error.PathDoesNotStartAtTheContentOrigin;
        const last = switch (commands[commands.len - 1]) {
            .line => |point| point,
            else => return error.ExpectedLineLast,
        };
        if (last.x != state.content.w) return error.PathDoesNotSpanTheContentBox;
    } else {
        if (records.len != 2) return error.RetiredFrameStillPublishesAnImage;
        for (records) |record| {
            if (recordNamesATexture(record)) return error.RetiredFrameStillNamesATexture;
        }
        // The raster binding is deliberately STALE rather than absent: it
        // still names an index, and the element must refuse it because the
        // version it was published for has moved on.
        if (view.raster.index == 0xFFFFFFFF or view.raster.isFresh()) {
            return error.RetiredRasterWasNotStale;
        }
    }

    // 3. The material probe: the indices the elements name reach the renderer's
    //    own draw-command list, which is what the GPU submission is built from.
    const cmds = try drawcmd.collectDrawCmds(
        gpa,
        @constCast(output.tree),
        output.pressed,
        output.press_alpha,
    );
    defer gpa.free(cmds);
    var image_cmds: usize = 0;
    var saw_mark = false;
    var saw_raster = false;
    for (cmds) |cmd| {
        const image_cmd = cmd.image_paint orelse continue;
        image_cmds += 1;
        if (image_cmd.texture_index == view.mark.index) saw_mark = true;
        if (image_cmd.texture_index == view.raster.index) saw_raster = true;
    }
    if (expect_bound) {
        if (image_cmds != 2) return error.ImageCommandsDidNotReachTheRenderer;
        if (!saw_mark) return error.MarkTextureIsNotBoundInTheDrawCommands;
        if (!saw_raster) return error.RasterTextureIsNotBoundInTheDrawCommands;
    } else if (image_cmds != 0) {
        return error.RetiredFrameStillNamesDrawableTextures;
    }

    // 4. Pixels. Every point below is authored arithmetic on the geometry the
    //    tree published, never a coordinate copied from a previous run.
    const probe: Probe = .{ .pixels = pixels, .extent = target };
    if (pixels.len < @as(usize, target.width) * @as(usize, target.height) * 4) {
        return error.ShortReadback;
    }
    var held: usize = 0;
    if (!reportProbe(probe, "background", 280, 60, authored(background_color))) {
        return error.BackgroundProbeFailed;
    }
    held += 1;

    const spark_content = widget.visualContentRect(output.tree, spark);
    // A point inside the plate, below the polyline band and clear of both the
    // child badge and the rasterized mark: authored arithmetic on the box the
    // tree published.
    const plate_x: u32 = @intFromFloat(spark_content.x + 24);
    const plate_y: u32 = @intFromFloat(spark_content.y + 108);
    if (!reportProbe(probe, "plate", plate_x, plate_y, authored(ink_srgb))) {
        return error.PlateProbeFailed;
    }
    held += 1;

    const badge_box = widget.visualContentRect(output.tree, badge);
    const badge_point: struct { x: u32, y: u32 } = .{
        .x = @intFromFloat(badge_box.x + badge_box.w * 0.5),
        .y = @intFromFloat(badge_box.y + badge_box.h * 0.5),
    };
    if (!reportProbe(probe, "badge", badge_point.x, badge_point.y, authored(.{
        .r = badge_color[0],
        .g = badge_color[1],
        .b = badge_color[2],
        .a = badge_color[3],
    }))) return error.BadgeProbeFailed;
    held += 1;

    // The polyline really is inked: count pixels close to the authored accent
    // in the band left of the rasterized mark.
    const stroke_lane: Rect = .{
        .x = spark_content.x + 24,
        .y = spark_content.y,
        .w = 106,
        .h = band_height,
    };
    const accent_pixels = probe.countNear(stroke_lane, authored(accent_srgb));
    std.debug.print(
        "  probe {s} {d} accent pixels inside the polyline lane\n",
        .{ "polyline", accent_pixels },
    );
    if (accent_pixels < 24) return error.PolylineIsNotInked;
    held += 1;

    // The rasterized SVG, sampled where the DOCUMENT authored colour, plus the
    // quadrant it authored to nothing at all.
    const mark_box: Rect = .{
        .x = spark_content.x + mark_local.x,
        .y = spark_content.y + mark_local.y,
        .w = mark_local.w,
        .h = mark_local.h,
    };
    const mark_scale = mark_local.w / @as(f32, @floatFromInt(mark_document_width));
    const mark_probes = [_]struct { name: []const u8, x: f32, y: f32, color: [3]u8 }{
        .{ .name = "svg-mark-tl", .x = 12, .y = 12, .color = mark_tl },
        .{ .name = "svg-mark-tr", .x = 36, .y = 12, .color = mark_tr },
        .{ .name = "svg-mark-bl", .x = 12, .y = 36, .color = mark_bl },
    };
    for (mark_probes) |entry| {
        const x: u32 = @intFromFloat(mark_box.x + entry.x * mark_scale);
        const y: u32 = @intFromFloat(mark_box.y + entry.y * mark_scale);
        const expected = if (expect_bound) authoredBytes(entry.color) else authored(ink_srgb);
        if (!reportProbe(probe, entry.name, x, y, expected)) {
            return error.MarkProbeFailed;
        }
        held += 1;
    }
    // What the empty quadrant shows is whatever the element painted under it:
    // the plate while the texture is bound, and the same plate after it is
    // retired (the record is gone, so there is no image at all).
    const empty_x: u32 = @intFromFloat(mark_box.x + 36 * mark_scale);
    const empty_y: u32 = @intFromFloat(mark_box.y + 36 * mark_scale);
    if (!reportProbe(probe, "svg-mark-empty", empty_x, empty_y, authored(ink_srgb))) {
        return error.MarkEmptyQuadrantProbeFailed;
    }
    held += 1;

    // The decoded PPM through the public `ImageView` seam. While bound it shows
    // the decoded quadrants; after retirement it shows the authored pending
    // fill, because the source the element was handed is no longer ready.
    const raster_box = widget.visualContentRect(output.tree, image);
    const raster_probes = [_]struct { name: []const u8, x: u32, y: u32, color: [3]u8 }{
        .{ .name = "raster-tl", .x = 16, .y = 16, .color = raster_tl },
        .{ .name = "raster-tr", .x = 48, .y = 16, .color = raster_tr },
        .{ .name = "raster-bl", .x = 16, .y = 48, .color = raster_bl },
        .{ .name = "raster-br", .x = 48, .y = 48, .color = raster_br },
    };
    for (raster_probes) |entry| {
        const x: u32 = @intFromFloat(raster_box.x + @as(f32, @floatFromInt(entry.x)));
        const y: u32 = @intFromFloat(raster_box.y + @as(f32, @floatFromInt(entry.y)));
        if (expect_bound) {
            if (!reportProbe(probe, entry.name, x, y, authoredBytes(entry.color))) {
                return error.RasterProbeFailed;
            }
        } else if (!reportProbe(probe, entry.name, x, y, authored(pending_srgb))) {
            return error.PendingFillProbeFailed;
        }
        held += 1;
    }

    std.debug.print(
        "  {d} records, {d} image draw commands, spark {d:.0}x{d:.0} at ({d:.0},{d:.0}), glyph slots {d}\n",
        .{
            records.len,
            image_cmds,
            spark_content.w,
            spark_content.h,
            spark_content.x,
            spark_content.y,
            painter.glyphSlots(),
        },
    );
    return held;
}

pub fn publishedRecords(
    tree: *const widget.WidgetTree,
    id: nogui.FrameNodeId,
) []const element.PaintRecord {
    const node = tree.nodeConst(id) orelse return &.{};
    return node.kind.element.paint_records.items;
}

/// True when the element's record names a texture. Used to prove an unbound
/// or retired element publishes no image at all.
fn recordNamesATexture(record: element.PaintRecord) bool {
    return switch (record) {
        .image => true,
        else => false,
    };
}

// ── The scenario ─────────────────────────────────────────────────────────────

/// One Session, one App, one model, one view and one writer of the asset
/// bindings. The ARMS differ only in how a frame reaches pixels.
const Scenario = struct {
    gpa: std.mem.Allocator,
    /// The deterministic task clock. Nothing here sleeps: the run advances it
    /// past a deadline and drains, exactly as a test would.
    now_ns: i96 = 0,
    session: *Session,
    app: *App,
    view: *CanvasView,
    owner: nogui.Model(Board),
    painter: ?*Painter = null,
    assets: ?*Assets = null,
    tick: u32 = 0,
    /// The Oklab pixels of the frame the run last rendered.
    pixels: []const f32 = &.{},

    fn readNow(raw: *anyopaque) i96 {
        const self: *Scenario = @ptrCast(@alignCast(raw));
        return self.now_ns;
    }

    pub fn init(gpa: std.mem.Allocator) !*Scenario {
        const self = try gpa.create(Scenario);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .session = undefined,
            .app = undefined,
            .view = undefined,
            .owner = .{},
        };
        self.session = try gpa.create(Session);
        errdefer gpa.destroy(self.session);
        self.session.* = try Session.init(gpa);
        errdefer self.session.deinit() catch |err| std.debug.panic(
            "canvas-view: a partial build left a live session: {s}",
            .{@errorName(err)},
        );
        try self.session.startTasks(nogui.Clock.injected(self, readNow));
        self.app = try gpa.create(App);
        errdefer gpa.destroy(self.app);
        self.app.* = try App.init(gpa, self.session);
        errdefer self.app.deinit();
        self.view = try gpa.create(CanvasView);
        errdefer gpa.destroy(self.view);
        self.view.* = .{ .window = self.app.window };
        // The model is created BEFORE the root is mounted, because the mount
        // retains it by value. The caller keeps its own strong owner until
        // `release` consumes it.
        var board: Board = .{};
        self.owner = try self.session.create(Board, &board);
        errdefer self.session.release(Board, &self.owner) catch |err| std.debug.panic(
            "canvas-view: a partial build left a live model: {s}",
            .{@errorName(err)},
        );
        try self.app.mountModelRoot(Board, CanvasView, self.owner, self.view);
        return self;
    }

    /// Mount the chosen arm's ONE endpoint and measure through the text engine
    /// that same arm owns. The painter is owned from here on, so a REFUSED
    /// attach still retires it with everything else.
    fn attach(self: *Scenario, painter: *Painter) !void {
        self.app.measure = painter.measurer();
        self.painter = painter;
        try self.app.attachGpu(painter.endpoint());
    }

    /// Own the asset owner, so teardown retires it between the App's detach
    /// and the device.
    fn adoptAssets(self: *Scenario, assets: *Assets) !void {
        self.assets = assets;
        try self.publishBindings(assets.raster_bound, assets.mark_bound);
    }

    /// Publish both bindings into the model. The model sees IDs and sizes
    /// only; the pixels stay with `Assets`. The handler is the Session's typed
    /// scoped-update shape: the model pointer and the caller's value.
    fn publishBindings(self: *Scenario, raster: Bound, mark: Bound) !void {
        const update = struct {
            fn apply(board: *Board, next: [2]Bound) void {
                board.raster = next[0];
                board.mark = next[1];
            }
        };
        const next = [2]Bound{ raster, mark };
        try self.session.update(Board, self.owner, next, update.apply);
    }

    /// Arm one real UI task, advance the deterministic clock past its deadline
    /// and drain it. The delivered callback mutates the model, so the window
    /// this view draws for is invalidated by the Session itself.
    fn deliverStep(self: *Scenario) !void {
        var work: Step = .{ .steps = 1 };
        _ = try self.session.scheduleUi(
            Step,
            Board,
            Board.applyStep,
            self.owner.weak(),
            &work,
            self.now_ns + 1,
        );
        self.now_ns += 2;
        const delivered = try self.session.drainTasks();
        if (delivered != 1) return error.StepWasNotDelivered;
        if (!try self.session.takeRedraw(self.app.window)) {
            return error.ModelUpdateDidNotInvalidateTheWindow;
        }
    }

    /// Build and render one frame through the mounted arm and read the pixels.
    fn frame(self: *Scenario) !FrameOutput {
        const painter = self.painter orelse return error.NoPainterMounted;
        try painter.beginFrame();
        errdefer painter.cancelFrame();
        const output = try self.app.frameWithGpuAtTime(
            self.tick + 1,
            0,
            surface(),
            painter.gpuFrame(),
        );
        self.tick += 1;
        try painter.render(&output);
        self.pixels = painter.pixels;
        return output;
    }

    /// The teardown order this value owns, and the reason for it: the App
    /// detaches first, then the bound assets retire on the live device, then
    /// every device-side resource goes, then the window and the host, then the
    /// task service, the App and the models, and only then the Session.
    fn release(self: *Scenario) void {
        self.app.detachGpu();
        if (self.assets) |assets| {
            assets.retire();
            assets.deinit();
            self.gpa.destroy(assets);
            self.assets = null;
        }
        if (self.painter) |painter| {
            painter.retire();
            painter.closeHost();
            painter.destroy();
            self.painter = null;
        }
        if (self.session.tasksStarted()) {
            self.session.shutdownTasks(2_000 * std.time.ns_per_ms) catch |err|
                std.debug.panic("canvas-view: task shutdown refused {s}", .{@errorName(err)});
        }
        self.app.deinit();
        self.gpa.destroy(self.app);
        self.session.release(Board, &self.owner) catch |err|
            std.debug.panic("canvas-view: model release refused {s}", .{@errorName(err)});
        self.gpa.destroy(self.view);
        self.session.deinit() catch |err|
            std.debug.panic("canvas-view: Session retirement refused {s}", .{@errorName(err)});
        self.gpa.destroy(self.session);
        self.gpa.destroy(self);
    }
};

// ── The run ──────────────────────────────────────────────────────────────────

fn buildAssets(
    gpa: std.mem.Allocator,
    io: std.Io,
    painter: *Painter,
) !*Assets {
    const assets = try gpa.create(Assets);
    errdefer gpa.destroy(assets);
    assets.* = .{
        .gpa = gpa,
        .io = io,
        .gpu = painter.gpu(),
        .heap = painter.heap(),
        .manager = host.assets.AssetManager.init(gpa, io, .{}),
    };
    errdefer assets.deinit();
    try assets.bind();
    return assets;
}

/// The windowless arm: a noapi device and an Oklab target, no window anywhere.
fn runWindowless(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    const scenario = try Scenario.init(gpa);
    defer scenario.release();
    const painter = try Painter.init(gpa, io, .{
        .mode = .windowless,
        .shaders = options.shaders,
        .blit = options.blit,
        .app = scenario.app,
        .session = scenario.session,
    });
    try scenario.attach(painter);
    const assets = try buildAssets(gpa, io, painter);
    try scenario.adoptAssets(assets);

    std.debug.print(
        "mode: {s}; no window, no surface, no swapchain, no present, SDL never started\n",
        .{Mode.windowless.label()},
    );
    std.debug.print(
        "assets: raster {d}x{d} decoded -> heap[{d}]; mark authored {d}x{d}, measured {d:.0}x{d:.0}, rendered -> heap[{d}]\n",
        .{
            assets.raster_bound.width,
            assets.raster_bound.height,
            assets.raster_bound.index,
            mark_document_width,
            mark_document_height,
            assets.mark_intrinsic.width,
            assets.mark_intrinsic.height,
            assets.mark_bound.index,
        },
    );

    var held: usize = 0;
    const first = try scenario.frame();
    defer if (first.json) |json| gpa.free(json);
    held += try probeFrame(gpa, scenario, painter, &first, scenario.pixels, true);

    // A delivered UI task rotates the model's samples; the window it is
    // recorded against is invalidated by the Session, and the next frame
    // publishes a DIFFERENT polyline.
    const before = publishedRecords(first.tree, scenario.view.spark_id.?);
    const first_point = switch (before[1].path.path.commands[0]) {
        .move => |point| point,
        else => return error.ExpectedMoveFirst,
    };
    try scenario.deliverStep();
    const second = try scenario.frame();
    defer if (second.json) |json| gpa.free(json);
    const after = publishedRecords(second.tree, scenario.view.spark_id.?);
    const second_point = switch (after[1].path.path.commands[0]) {
        .move => |point| point,
        else => return error.ExpectedMoveFirst,
    };
    if (second_point.y == first_point.y) return error.DeliveredTaskDidNotMoveTheSamples;
    if (scenario.view.seen_revision != 1) return error.TheViewDidNotSeeTheDeliveredRevision;
    std.debug.print(
        "task: step delivered, samples rotated (first point y {d:.1} -> {d:.1}), revision {d}\n",
        .{ first_point.y, second_point.y, scenario.view.seen_revision },
    );
    held += try probeFrame(gpa, scenario, painter, &second, scenario.pixels, true);
    // The PPM is taken from the last frame that had BOTH assets bound: it is
    // the frame worth looking at, and the retirement frame below is a state
    // check rather than a picture.
    if (options.ppm) |path| {
        try v7_frame.writePpm(gpa, io, path, scenario.pixels, target);
        std.debug.print("wrote {s} (the last frame with both assets bound)\n", .{path});
    }

    // RETIREMENT. The heap slots go back, the textures are destroyed and the
    // cache entries are dropped. The model then says two different things, and
    // the next frame proves both in the tree, in the draw commands and in the
    // pixels: the mark is UNBOUND (no image record at all), and the raster is
    // STALE (the model carries a newer generation than the slot it holds), so
    // the element refuses to sample a retired slot and paints its pending fill
    // instead.
    const raster_index = scenario.assets.?.raster_bound.index;
    const mark_index = scenario.assets.?.mark_bound.index;
    scenario.assets.?.retire();
    try scenario.publishBindings(.{
        .index = raster_index,
        // The slot still carries what it was registered with; the version the
        // model is being shown has moved on. That disagreement is the stale
        // binding the element has to refuse.
        .slot_generation = scenario.assets.?.raster_bound.slot_generation,
        .generation = scenario.assets.?.raster_bound.generation + 1,
        .width = raster_width,
        .height = raster_height,
    }, Bound.none);
    const retired = try scenario.frame();
    defer if (retired.json) |json| gpa.free(json);
    held += try probeFrame(gpa, scenario, painter, &retired, scenario.pixels, false);
    // The heap really did take both indices back: the next registration the
    // heap serves is one of the two this run just released.
    const probe_texture = try painter.gpu().textureCreate(.{
        .dimensions = .{ 1, 1, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    const reused = try painter.heap().register(gpa, probe_texture);
    painter.heap().release(gpa, probe_texture);
    painter.gpu().textureDestroy(probe_texture);
    if (reused != raster_index and reused != mark_index) return error.RetiredSlotsWereNotReused;
    std.debug.print(
        "retire: released heap[{d}] and heap[{d}], next registration reused heap[{d}]; frame published no image\n",
        .{ raster_index, mark_index, reused },
    );

    std.debug.print("offscreen proof complete: {d} probes held, {d} frames rendered\n", .{
        held,
        painter.submitted,
    });
}

/// The presented arm: the SAME scenario through a real window.
fn runPresented(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    const scenario = try Scenario.init(gpa);
    defer scenario.release();
    const painter = try Painter.init(gpa, io, .{
        .mode = .presented,
        .shaders = options.shaders,
        .blit = options.blit,
        .app = scenario.app,
        .session = scenario.session,
    });
    try scenario.attach(painter);
    const assets = try buildAssets(gpa, io, painter);
    try scenario.adoptAssets(assets);

    const presented = &painter.path.presented;
    std.debug.print(
        "mode: {s}; driver {s}, native id {d}, window {d}x{d} logical at {d}x{d} device;\n" ++
            "every pixel below is read back from the Oklab target the presented passes wrote\n",
        .{
            Mode.presented.label(),
            sdl3.video.getCurrentDriverName() orelse "<null>",
            presented.native_id,
            target.width,
            target.height,
            target.width,
            target.height,
        },
    );

    var held: usize = 0;
    const first = try scenario.frame();
    defer if (first.json) |json| gpa.free(json);
    held += try probeFrame(gpa, scenario, painter, &first, scenario.pixels, true);

    try scenario.deliverStep();
    const second = try scenario.frame();
    defer if (second.json) |json| gpa.free(json);
    held += try probeFrame(gpa, scenario, painter, &second, scenario.pixels, true);
    if (scenario.view.seen_revision != 1) return error.TheViewDidNotSeeTheDeliveredRevision;
    // The PPM is taken from the last frame that had BOTH assets bound.
    if (options.ppm) |path| {
        try v7_frame.writePpm(gpa, io, path, scenario.pixels, target);
        std.debug.print("wrote {s} (the last frame with both assets bound)\n", .{path});
    }

    const raster_index = scenario.assets.?.raster_bound.index;
    const mark_index = scenario.assets.?.mark_bound.index;
    scenario.assets.?.retire();
    // Same two statements the windowless arm publishes: an UNBOUND mark and a
    // STALE raster, so both lifetime guards are exercised on the presented
    // route as well.
    try scenario.publishBindings(.{
        .index = raster_index,
        // The slot still carries what it was registered with; the version the
        // model is being shown has moved on. That disagreement is the stale
        // binding the element has to refuse.
        .slot_generation = scenario.assets.?.raster_bound.slot_generation,
        .generation = scenario.assets.?.raster_bound.generation + 1,
        .width = raster_width,
        .height = raster_height,
    }, Bound.none);
    const retired = try scenario.frame();
    defer if (retired.json) |json| gpa.free(json);
    held += try probeFrame(gpa, scenario, painter, &retired, scenario.pixels, false);

    if (painter.presentation()) |stats| {
        std.debug.print(
            "present: {d} frames presented, {d} acquire retries, {d} resizes, {d} swapchain rebuilds, {d} extent mismatches\n",
            .{
                stats.frames_presented,
                presented.retries,
                stats.resizes_requested,
                stats.swapchains_recreated,
                stats.extent_mismatches,
            },
        );
        if (stats.frames_presented != painter.submitted) {
            return error.PresentDidNotFollowEveryFrame;
        }
    }
    std.debug.print(
        "retire: released heap[{d}] and heap[{d}]; the presented frame published no image\n",
        .{ raster_index, mark_index },
    );

    std.debug.print("native proof complete: {d} probes held, {d} frames presented\n", .{
        held,
        painter.submitted,
    });
}

/// The explicit CPU structural arm. No device, no shader, no pixels: it proves
/// the tree, the prepaint geometry and the published records only, and it says
/// so.
fn runStructural(gpa: std.mem.Allocator) !void {
    const scenario = try Scenario.init(gpa);
    defer scenario.release();
    std.debug.print(
        "mode: {s}; no device, no shader and no pixels: this arm proves the tree,\n" ++
            "the prepaint geometry and the published records only\n",
        .{Mode.structural.label()},
    );
    const output = try scenario.app.frame(1, surface());
    defer if (output.json) |json| gpa.free(json);
    const spark = scenario.view.spark_id orelse return error.MissingSparkline;
    const records = publishedRecords(output.tree, spark);
    // No binding was published, so the custom element emits its plate and its
    // path and NO image record: an unbound frame cannot name a texture.
    if (records.len != 2) return error.UnboundFramePublishedAnImageRecord;
    const state = output.tree.nodeConst(spark).?.kind.element.phaseState(Phase);
    if (!state.prepaint_ran) return error.PrepaintDidNotRun;
    if (state.content.w != spark_content_width or state.content.h != spark_content_height) {
        return error.ContentBoxIsNotThePaddedInset;
    }
    if (scenario.view.raster.index != 0xFFFFFFFF) return error.StructuralArmBoundATexture;
    // The public `ImageView` seam says the same thing for its own node: an
    // unready source paints its authored pending fill, never an image.
    const image = scenario.view.image_id orelse return error.MissingImageView;
    const image_records = publishedRecords(output.tree, image);
    if (image_records.len != 1) return error.PendingImageViewDidNotPaintAFill;
    for (image_records) |record| {
        if (recordNamesATexture(record)) return error.PendingImageViewPaintedAnImage;
    }
    std.debug.print(
        "structural: {d} records published, prepaint content {d:.0}x{d:.0}, no texture named\n",
        .{ records.len, state.content.w, state.content.h },
    );
}

// ── The command line ─────────────────────────────────────────────────────────

const default_fullscreen_shader = "shaders/fullscreen_vert.spv";
const default_oklab_shader = "shaders/blit_oklab.spv";

const Options = struct {
    mode: Mode = .windowless,
    vert: ?[]const u8 = null,
    frag: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    fullscreen: ?[]const u8 = null,
    oklab: ?[]const u8 = null,
    ppm: ?[]const u8 = null,
    shaders: Shaders = .{ .vert = &.{}, .frag = &.{}, .sort = &.{} },
    blit: BlitShaders = .{ .fullscreen = &.{}, .oklab = &.{} },

    fn fullscreenPath(self: Options) []const u8 {
        return self.fullscreen orelse default_fullscreen_shader;
    }

    fn oklabPath(self: Options) []const u8 {
        return self.oklab orelse default_oklab_shader;
    }

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        if (self.vert) |value| gpa.free(value);
        if (self.frag) |value| gpa.free(value);
        if (self.sort) |value| gpa.free(value);
        if (self.fullscreen) |value| gpa.free(value);
        if (self.oklab) |value| gpa.free(value);
        if (self.ppm) |value| gpa.free(value);
        self.* = undefined;
    }
};

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;

    var options: Options = .{};
    errdefer options.deinit(gpa);
    var positional: [3]?[]const u8 = .{ null, null, null };
    var positional_count: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            options.mode = .presented;
        } else if (std.mem.eql(u8, arg, "--structural")) {
            options.mode = .structural;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            if (options.ppm != null) return error.RepeatedOutputPath;
            options.ppm = try gpa.dupe(u8, args.next() orelse return error.MissingOutputPath);
        } else if (std.mem.eql(u8, arg, "--fullscreen-vert")) {
            if (options.fullscreen != null) return error.RepeatedShaderPath;
            options.fullscreen = try gpa.dupe(u8, args.next() orelse return error.MissingShaderPath);
        } else if (std.mem.eql(u8, arg, "--blit-oklab")) {
            if (options.oklab != null) return error.RepeatedShaderPath;
            options.oklab = try gpa.dupe(u8, args.next() orelse return error.MissingShaderPath);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else {
            if (positional_count == positional.len) return error.UnexpectedArgument;
            positional[positional_count] = try gpa.dupe(u8, arg);
            positional_count += 1;
        }
    }
    options.vert = positional[0];
    options.frag = positional[1];
    options.sort = positional[2];
    if (options.mode != .structural and
        (options.vert == null or options.frag == null or options.sort == null))
    {
        return error.MissingShaderPath;
    }
    return options;
}

/// One loaded SPIR-V module: the bytes, and the u32 view the GPU wants.
const ShaderFile = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ShaderFile {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{
            .bytes = bytes,
            .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)),
        };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var options = try parseArgs(init, gpa);
    defer options.deinit(gpa);

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (options.mode == .structural) {
        try runStructural(gpa);
        return;
    }

    var vert = try ShaderFile.load(gpa, io, options.vert.?);
    defer vert.deinit(gpa);
    var frag = try ShaderFile.load(gpa, io, options.frag.?);
    defer frag.deinit(gpa);
    var sort = try ShaderFile.load(gpa, io, options.sort.?);
    defer sort.deinit(gpa);
    options.shaders = .{ .vert = vert.words, .frag = frag.words, .sort = sort.words };

    // Only the presented arm records a blit, so only it opens the two modules
    // that blit is drawn with. Both stay OWNED until this function returns:
    // the painter copies the words into shader objects, but the slices handed
    // to it must still be live when it does.
    var fullscreen: ?ShaderFile = if (options.mode == .presented)
        try ShaderFile.load(gpa, io, options.fullscreenPath())
    else
        null;
    defer if (fullscreen) |*file| file.deinit(gpa);
    var oklab: ?ShaderFile = if (options.mode == .presented)
        try ShaderFile.load(gpa, io, options.oklabPath())
    else
        null;
    defer if (oklab) |*file| file.deinit(gpa);
    options.blit = .{
        .fullscreen = if (fullscreen) |file| file.words else &.{},
        .oklab = if (oklab) |file| file.words else &.{},
    };

    switch (options.mode) {
        .structural => unreachable,
        .windowless => try runWindowless(gpa, io, options),
        .presented => try runPresented(gpa, io, options),
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "api-w25 custom element publishes prepaint geometry and its own paint records" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa_state.deinit() == .ok) catch {};
    const gpa = gpa_state.allocator();

    const scenario = try Scenario.init(gpa);
    defer scenario.release();
    const output = try scenario.app.frame(1, surface());
    defer if (output.json) |json| gpa.free(json);

    const spark = scenario.view.spark_id orelse return error.MissingSparkline;
    const badge = scenario.view.badge_id orelse return error.MissingBadge;
    const node = output.tree.nodeConst(spark) orelse return error.MissingSparklineNode;
    const state = node.kind.element.phaseState(Phase);

    // The prepaint hook recorded the FINAL content box, not the border box.
    if (state.content.w != spark_content_width or state.content.h != spark_content_height) {
        return error.ContentBoxIsNotThePaddedInset;
    }
    if (!state.prepaint_ran) return error.PrepaintDidNotRun;
    if (!std.meta.eql(state.content, widget.visualContentRect(output.tree, spark))) {
        return error.PublishedGeometryIsNotTheCommittedContentBox;
    }
    // The child leaf is a real descendant of the container element.
    const badge_node = output.tree.frameNode(
        scenario.app.widgetIdForKey(nogui.ComponentId.root, .{ .static = "badge" }) orelse
            return error.MissingBadgeId,
    ) orelse return error.MissingBadgeNode;
    if (output.tree.nodeConst(badge_node).?.parent != spark) {
        return error.BadgeIsNotAChildOfTheContainer;
    }

    // The frame PUBLISHES the records the paint hook wrote, in order, and the
    // UNBOUND element emits no image record at all.
    const records = publishedRecords(output.tree, spark);
    if (records.len != 2) return error.UnboundFramePublishedAnImageRecord;
    if (state.emitted != 2) return error.HookDidNotCountWhatItPublished;
    if (records[0].rect.bounds.x != 0 or records[0].rect.bounds.y != 0) {
        return error.PlateIsNotAuthoredAtTheContentOrigin;
    }
    if (records[0].rect.bounds.w != state.content.w) return error.PlateIsNotTheContentBox;
    // The polyline's borrowed commands and dash array were COPIED into the
    // frame arena: a slice that died with the hook would not read back here.
    const stroke = records[1].path.stroke orelse return error.MissingStroke;
    if (stroke.width != 2) return error.StrokeWidthMoved;
    if (!std.mem.eql(f32, stroke.dash, &.{ 4, 2 })) return error.DashArrayWasNotCopied;
    const commands = records[1].path.path.commands;
    if (commands.len != sample_count) return error.PathCommandCountMoved;
    const first_point = switch (commands[0]) {
        .move => |point| point,
        else => return error.ExpectedMoveFirst,
    };
    const last_point = switch (commands[commands.len - 1]) {
        .line => |point| point,
        else => return error.ExpectedLineLast,
    };
    if (first_point.x != 0) return error.PathDoesNotStartAtTheContentOrigin;
    if (last_point.x != state.content.w) return error.PathDoesNotSpanTheContentBox;
    // Sample 0 is 0.1, so the first point sits 90% down the content box.
    if (@abs(first_point.y - state.content.h * 0.9) > 0.001) return error.FirstSampleMoved;

    // A leaf element also gets measure + prepaint + paint.
    const badge_state = output.tree.nodeConst(badge).?.kind.element.phaseState(Badge.PhaseState);
    if (badge_state.emitted != 1) return error.BadgeDidNotPublishOneRecord;
    if (publishedRecords(output.tree, badge).len != 1) return error.BadgeRecordCountMoved;
    if (!std.meta.eql(widget.visualContentRect(output.tree, badge), badge_state.content)) {
        return error.BadgeGeometryIsNotTheCommittedContentBox;
    }

    // The records are FRAME-LOCAL: a new frame republishes them from scratch.
    const frame2 = try scenario.app.frame(2, surface());
    defer if (frame2.json) |json| gpa.free(json);
    if (publishedRecords(frame2.tree, scenario.view.spark_id.?).len != 2) {
        return error.SecondFrameRecordCountMoved;
    }

    // The decoded image through the public seam is UNBOUND here, and the
    // element says so instead of sampling a texture nobody uploaded.
    if (scenario.view.raster.index != 0xFFFFFFFF) return error.StructuralArmBoundATexture;
    const image_records = publishedRecords(frame2.tree, scenario.view.image_id.?);
    if (image_records.len != 1) return error.PendingImageViewDidNotPaintAFill;
    for (image_records) |record| {
        if (recordNamesATexture(record)) return error.PendingImageViewPaintedAnImage;
    }
}

test "api-w25 element paint records are validated, not silently accepted" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa_state.deinit() == .ok) catch {};
    const gpa = gpa_state.allocator();

    // A negative width is not a paintable rectangle, and the sentinel texture
    // index is not a paintable image. The writer rejects both at the seam, so
    // an element cannot hand the renderer a record it would have to guess at.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var records: std.ArrayListUnmanaged(element.PaintRecord) = .empty;
    var writer: element.PaintWriter = .{
        .allocator = arena.allocator(),
        .records = &records,
    };
    try std.testing.expectError(error.InvalidPaint, writer.addRect(.{
        .bounds = .{ .x = 0, .y = 0, .w = -4, .h = 10 },
        .fill = .{ .solid = .{ .srgb = ink_srgb } },
    }));
    try std.testing.expectError(error.InvalidPaint, writer.addImage(.{
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .src = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .texture_index = 0xFFFFFFFF,
    }));
    // A source rect that leaves the texture is rejected as well.
    try std.testing.expectError(error.InvalidPaint, writer.addImage(.{
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .src = .{ .x = 0.5, .y = 0, .w = 1, .h = 1 },
        .texture_index = 3,
    }));
    try std.testing.expectEqual(@as(usize, 0), records.items.len);

    // A well-formed record is accepted and owned by the arena.
    try writer.addRect(.{
        .bounds = .{ .x = 1, .y = 2, .w = 8, .h = 10 },
        .fill = .{ .solid = .{ .srgb = accent_srgb } },
    });
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
}

test "api-w25 embedded assets decode and rasterize to their authored pixels" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa_state.deinit() == .ok) catch {};
    const gpa = gpa_state.allocator();

    // The real P6 decoder, on the real embedded bytes.
    var raster = try host.image.decodePpm(gpa, raster_bytes);
    defer raster.deinit();
    try std.testing.expectEqual(raster_width, raster.width);
    try std.testing.expectEqual(raster_height, raster.height);
    const stride = std.math.cast(usize, raster.stride) orelse return error.RasterStrideUnreadable;
    var y: u32 = 0;
    while (y < raster_height) : (y += 1) {
        var x: u32 = 0;
        while (x < raster_width) : (x += 1) {
            const base = @as(usize, y) * stride + @as(usize, x) * 4;
            const wanted = rasterTexel(x, y);
            try std.testing.expectEqual(wanted[0], raster.pixels[base]);
            try std.testing.expectEqual(wanted[1], raster.pixels[base + 1]);
            try std.testing.expectEqual(wanted[2], raster.pixels[base + 2]);
            try std.testing.expectEqual(@as(u8, 0xFF), raster.pixels[base + 3]);
        }
    }

    // The real librsvg measure and rasterize, on the real embedded document.
    const engine = host.svg.SvgEngine.getGlobal(std.testing.io);
    try std.testing.expect(engine.isAvailable());
    const intrinsic = (try host.svg.queryIntrinsicSize(std.testing.io, mark_bytes)) orelse
        return error.SvgHasNoIntrinsicSize;
    try std.testing.expectEqual(@as(f32, @floatFromInt(mark_document_width)), intrinsic.width);
    try std.testing.expectEqual(@as(f32, @floatFromInt(mark_document_height)), intrinsic.height);
    var mark = try host.svg.renderSvg(gpa, std.testing.io, mark_bytes, .{
        .viewport_width = mark_document_width,
        .viewport_height = mark_document_height,
        .dpi_scale = 1.0,
    });
    defer mark.deinit();
    try std.testing.expectEqual(mark_document_width, mark.width);
    try std.testing.expectEqual(mark_document_height, mark.height);
    const mark_stride = std.math.cast(usize, mark.stride) orelse return error.MarkStrideUnreadable;
    const probes = [_]struct { x: u32, y: u32, color: ?[3]u8 }{
        .{ .x = 12, .y = 12, .color = mark_tl },
        .{ .x = 36, .y = 12, .color = mark_tr },
        .{ .x = 12, .y = 36, .color = mark_bl },
        .{ .x = 36, .y = 36, .color = null },
    };
    for (probes) |probe| {
        const base = @as(usize, probe.y) * mark_stride + @as(usize, probe.x) * 4;
        if (probe.color) |wanted| {
            try std.testing.expect(mark.pixels[base + 3] >= 250);
            for (0..3) |channel| {
                const actual: i32 = @intCast(mark.pixels[base + channel]);
                const expected: i32 = @intCast(wanted[channel]);
                try std.testing.expect(@abs(actual - expected) <= 4);
            }
        } else {
            try std.testing.expectEqual(@as(u8, 0), mark.pixels[base + 3]);
        }
    }
}
