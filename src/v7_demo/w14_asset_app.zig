//! W14 asset + animated-image smoke — one real native window, one real
//! mounted `ImageView`, real bindless uploads, real rendered pixels.
//!
//! The audit found the whole asset and external-frame surface reachable only
//! from tests. This binary is the executable that reaches it: it drives
//! `AssetManager` through an embedded byte source, a file source, request
//! deduplication, the pending-to-ready transition, a byte-budget eviction and
//! an explicit invalidation, then builds an `AnimatedSequence` from a
//! `FrameSource`, uploads each frame into a real bindless descriptor heap, and
//! mounts the published timeline on a real `ImageView` through
//! `DrawCtx.elementLeaf`.
//!
//! What it observes:
//!   1. Embedded bytes decoded to the authored image, and a real file on disk.
//!   2. Two requests for one key: the loader runs once, both callers get the
//!      same bytes.
//!   3. A load handle that reports `pending` and then `ready`.
//!   4. A byte-budget eviction that drops the least recently used entry.
//!   5. An invalidation that bumps the version and forces a re-read.
//!   6. The animated timeline: frame count, wrap period, the frame selected
//!      at four clock readings, and the pin that keeps a retired slot's
//!      pixels alive for two presented frames.
//!   7. The element's own choice of primitive through the public
//!      `PaintWriter`, for a live slot, a later clock reading, and a stale
//!      generation.
//!   8. PIXELS. The scene is rendered through `v7_render.Renderer` into an
//!      offscreen Oklab target, blitted to the swapchain, and the Oklab target
//!      is copied back and read. Three arms are asserted on the centre pixel:
//!      the authored color, the same image with a full grayscale amount, and a
//!      later clock reading that must show the next frame's color.
//!   9. The W05 wake, on the real host. A mounted non-looping image publishes
//!      its frame request into the WINDOW'S OWN `FrameDemand`, and the run then
//!      does nothing but sleep for the wait that demand reports and step the
//!      host: no invalidation, no `requestPresentation`, no forced layout. Every
//!      frame the host commits in that arm is committed because the image asked
//!      for one, and the arm observes the deadline armed, the frames the host
//!      woke for, the colour each of those frames rendered, and the frames it
//!      stopped committing once the image ended.
//!  10. The SVG specimen, on the display. A bounded authored document with its
//!      own intrinsic size exercises a group under a transform, two elliptical
//!      arcs covering both flag combinations, a local `use` reference, and every
//!      curve family the removed demo parser skipped: a quadratic `Q`, a
//!      chained smooth-quadratic `T`, a cubic `C` and a chained smooth-cubic `S`.
//!      It is loaded through the asset manager, rasterized by librsvg/Cairo,
//!      uploaded and mounted, and each probe answers from the DOCUMENT: the
//!      interior of a named shape, the middle of a named stroke, the body a
//!      `use` instantiates, a point each curve command's own polynomial puts on
//!      the curve, and the region the document leaves empty, which must reach
//!      the window as the background this run authors rather than as ink.
//!  11. Object fit, in pixels. One authored 12x4 image with three differently
//!      coloured regions is mounted at `.contain`, `.cover` and `.fill` in turn;
//!      the probes are placed so each fit answers with a DIFFERENT authored
//!      colour at the same window point, which is the claim a centre texel
//!      cannot make. The root is a container that covers the whole window, so
//!      every point the image does not reach shows a fill THIS FILE authors;
//!      `.contain`'s letterbox is proven against that colour too.
//!  12. The pending and failed fallback fills, in pixels: two colours this run
//!      authors, mounted as the two non-ready source states, each read back from
//!      the window as Oklab.
//!
//! One thing it deliberately does NOT do: treat the host `TextureRegistry`'s
//! own index as a heap index. That index is CPU-side bookkeeping and sampling
//! it would read whatever texture happens to own that descriptor slot, so the
//! sequence is given an explicit mapper and refuses to publish a timeline
//! without one.
//!
//! It drives the host as an EXTERNAL loop: `Application.step()` is called
//! here, never `Application.run()`.
//!
//! Run it: `zig build w14-asset-smoke -- [--hold-ms 4000]`.

const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const noapi = @import("noapi");

const nogui = @import("nogui");
const host = @import("nogui_host");
const renderer = @import("v7_render");

const Renderer = renderer.Renderer;
const Session = nogui.Session;
const App = nogui.App;
const contract = host.window_contract;
const Application = host.Application;
const assets = host.assets;
const image = host.image;
const frame_source = host.frame_source;
const AssetKey = assets.AssetKey;
const image_types = nogui.image_types;
const ImageView = nogui.image_view.ImageView;
const paint = nogui.paint;
const drawcmd = nogui.drawcmd;

/// The host module does not re-export `ManagedWindow`; the hook that receives
/// one is typed against it, so the pointer type is recovered from the hook's
/// own function-pointer type.
const OnFrameFn = @typeInfo(@FieldType(Application.Hooks, "on_frame")).optional.child;
const managed_window_ptr =
    @typeInfo(@typeInfo(OnFrameFn).pointer.child).@"fn".param_types[2].?;

/// The label the mounted image carries, so a committed snapshot can name the
/// node this run put on screen.
const image_label = "w14 asset image";

/// A 2x2 binary PPM the run decodes for real: red, green, blue, then white.
const badge_ppm: []const u8 = "P6\n2 2\n255\n" ++
    "\xFF\x00\x00" ++ "\x00\xFF\x00" ++
    "\x00\x00\xFF" ++ "\xFF\xFF\xFF";

/// A file that exists in this repository, loaded through the asset manager's
/// rooted file source rather than through `@embedFile`.
const repo_file_key = "tiger.svg";
const repo_file_root = "src/v7_demo";

/// Per-frame timings the element then samples: 40ms + 60ms + 20ms = 120ms.
const sequence_frame_durations_ns = [_]u64{
    40 * std.time.ns_per_ms,
    60 * std.time.ns_per_ms,
    20 * std.time.ns_per_ms,
};
/// Square frames, so the uploaded image is uniform under any sampler and the
/// centre pixel of the render is unambiguous.
const sequence_frame_side: u32 = 8;
const sequence_frame_rgba_bytes = sequence_frame_side * sequence_frame_side * 4;
/// One authored sRGB color per frame, distinct enough that a frame switch is
/// visible in three channels at once.
const sequence_frame_colors = [_][3]u8{
    .{ 255, 0, 0 },
    .{ 0, 255, 0 },
    .{ 0, 0, 255 },
};

/// The host-driven timeline: three frames, one authored colour each, so a wake
/// that paints the wrong frame is visible in the pixels the run reads back.
/// Its colours are deliberately DISJOINT from the sequence above, so a frame
/// from the wrong timeline cannot pass for one from this one. It does not
/// loop, so its end is the thing that has to stop the host.
const host_frame_durations_ns = [_]u64{
    60 * std.time.ns_per_ms,
    60 * std.time.ns_per_ms,
    60 * std.time.ns_per_ms,
};
const host_frame_colors = [_][3]u8{
    .{ 255, 255, 0 },
    .{ 0, 255, 255 },
    .{ 255, 0, 255 },
};
const host_total_ns: u64 = host_frame_durations_ns[0] +
    host_frame_durations_ns[1] + host_frame_durations_ns[2];
/// The owner identity the frame requests are published under. It is this
/// run's own, so a handle from the CPU arm's registry cannot retire it.
const host_frame_owner: nogui.WidgetId = .{ .owner = 22, .slot = 1, .generation = 1 };
/// How long the arm watches AFTER the image ended, which is long enough for a
/// host that had failed to stop to commit several more frames.
const host_idle_watch_ms: u64 = 200;
/// A host wait is never longer than this in this run's own timelines, so a cap
/// here costs nothing and bounds a missed deadline instead of hanging.
const host_sleep_cap_ms: u64 = 40;

/// The SVG specimen the run authored itself, because the repository's own
/// document contains no arc command and no `<use>`: it exercises a group under
/// a translate, two elliptical arcs covering both flag combinations, a local
/// `use` reference into `<defs>`, and the four curve families the demo parser
/// that shipped before librsvg skipped outright. Every shape is authored here,
/// nothing is fetched, and the document leaves the area around its transparent
/// probe empty on purpose, so "the renderer invented nothing" is a probe like
/// any other.
///
/// The sheet grew from 96x48 to 160x68. The original layout keeps its exact
/// document coordinates at the top left, so every probe it already had keeps
/// the value it already had, and a right-hand column at x 102..158 carries the
/// curve families. Only the WINDOW placement moves: `.contain` scales 160x68
/// into 480x260 at 3.0 with its origin at (0, 28), where 96x48 scaled at 5.0
/// from (0, 10). Every placement downstream is arithmetic from the constants
/// below, never a reading taken back from the fit code it sits beside.
const specimen_key = "w14-specimen.svg";
const specimen_width: u32 = 160;
const specimen_height: u32 = 68;
const specimen_svg_bytes: []const u8 =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"" ++
    " width=\"160\" height=\"68\" viewBox=\"0 0 160 68\">\n" ++
    "  <defs>\n" ++
    "    <rect id=\"badge\" x=\"0\" y=\"0\" width=\"20\" height=\"12\" fill=\"#00ff00\"/>\n" ++
    "  </defs>\n" ++
    "  <g transform=\"translate(8,8)\">\n" ++
    "    <rect x=\"0\" y=\"0\" width=\"24\" height=\"16\" fill=\"#ff0000\"/>\n" ++
    "  </g>\n" ++
    "  <path d=\"M 40 24 A 12 12 0 0 1 64 24\" fill=\"none\" stroke=\"#0000ff\" stroke-width=\"6\"/>\n" ++
    "  <path d=\"M 40 24 A 12 12 0 1 0 64 24\" fill=\"none\" stroke=\"#0000ff\" stroke-width=\"6\"/>\n" ++
    "  <use href=\"#badge\" xlink:href=\"#badge\" x=\"68\" y=\"8\"/>\n" ++
    "  <path d=\"M 102 30 Q 114 6 126 30 L 102 30 Z\" fill=\"#ff00ff\"/>\n" ++
    "  <path d=\"M 133 30 Q 140 8 144 16 T 153 30\" fill=\"none\" stroke=\"#00ffff\" stroke-width=\"8\"/>\n" ++
    "  <path d=\"M 102 62 C 108 38 120 38 126 62 L 102 62 Z\" fill=\"#ffff00\"/>\n" ++
    "  <path d=\"M 133 62 C 138 42 143 42 146 48 S 146 48 154 62\" fill=\"none\" " ++
    "stroke=\"#ff8000\" stroke-width=\"8\"/>\n" ++
    "</svg>\n";

/// What each specimen probe point is authored to be, in the document's own
/// coordinates. Every coloured point sits at least three units inside the shape
/// that owns it, so antialiased edges cannot reach a probe, and the empty point
/// is authored to nothing at all.
///
/// The four curve probes are placed from the commands' OWN polynomials, which
/// are written out beside each entry. A position read back from the rasterizer
/// would prove nothing about it: the probe has to be independent of the thing
/// it measures, exactly as an authored colour is.
const SpecimenProbe = struct {
    name: []const u8,
    x: u32,
    y: u32,
    /// The authored sRGB of the shape that owns this point, or null where the
    /// document authors nothing.
    color: ?[3]u8,
};
const specimen_probes = [_]SpecimenProbe{
    .{ .name = "group-interior", .x = 16, .y = 16, .color = .{ 255, 0, 0 } },
    .{ .name = "arc-sweep-flag-1", .x = 52, .y = 12, .color = .{ 0, 0, 255 } },
    .{ .name = "arc-large-sweep-flag-0", .x = 52, .y = 36, .color = .{ 0, 0, 255 } },
    .{ .name = "use-reference-body", .x = 78, .y = 14, .color = .{ 0, 255, 0 } },
    .{ .name = "empty-quadrant", .x = 4, .y = 44, .color = null },
    // `Q` FILLED. On `M 102 30 Q 114 6 126 30` the control's x is the midpoint
    // of the endpoints, so x(t) = 102 + 24t, and y(t) = 30 - 48t + 48t² is
    // minimal at t = 1/2, where the curve sits at (114, 18) with a horizontal
    // tangent. The closing segment is the line y = 30, so the enclosed region
    // is 12 units deep at x = 114 and this probe is 6 below the curve and 6
    // above the line.
    .{ .name = "quadratic-fill-body", .x = 114, .y = 24, .color = .{ 255, 0, 255 } },
    // `Q` STROKED, the leading segment of the `T` chain. On `M 133 30 Q 140 8
    // 144 16` the centre-line is x(t) = 133 + 14t - 3t² and y(t) = 30 - 44t +
    // 30t², so x reaches 139 at t = 0.477 with y = 15.8. The probe is 0.46 off
    // that measured perpendicular to the tangent, 3.5 inside an 8-wide stroke.
    .{ .name = "quadratic-stroke-segment", .x = 139, .y = 15, .color = .{ 0, 255, 255 } },
    // `T` STROKED. `T 153 30` reflects the quadratic's control (140, 8) about
    // the join (144, 16) to (148, 24), so the second segment runs (144, 16) to
    // (153, 30) under that control: x(u) = 144 + 8u + u² and y(u) = 16 + 16u -
    // 2u². x reaches 148 at u = 0.472, y = 23.1, which is 0.06 off the probe,
    // so the chained half of the command is probed and not merely drawn.
    .{ .name = "smooth-quadratic-stroke-segment", .x = 148, .y = 23, .color = .{ 0, 255, 255 } },
    // `C` FILLED. On `M 102 62 C 108 38 120 38 126 62` the equal end heights
    // and equal control heights give x(t) = 102 + 18t + 18t² - 12t³ and
    // y(t) = 62 - 72t + 72t², minimal at t = 1/2 where the curve sits at
    // (114, 44). The closing segment is y = 62, so the region is 18 units deep
    // at x = 114 and this probe is 9 from each boundary.
    .{ .name = "cubic-fill-body", .x = 114, .y = 53, .color = .{ 255, 255, 0 } },
    // `C` STROKED, the leading segment of the `S` chain. On `M 133 62 C 138 42
    // 143 42 146 48` the centre-line is x(t) = 133 + 15t - 2t³ and
    // y(t) = 62 - 60t + 60t² - 14t³, so x reaches 140 at t = 0.482 with
    // y = 45.5. The probe is 0.34 off it perpendicular, 3.7 inside the stroke.
    .{ .name = "cubic-stroke-segment", .x = 140, .y = 45, .color = .{ 255, 128, 0 } },
    // `S` STROKED. `S 146 48 154 62` reflects the cubic's second control (143, 42)
    // about the join (146, 48) to (149, 54) and reuses the join as the segment's
    // own second control, so the second segment runs (146, 48) to (154, 62)
    // under controls (149, 54) and (146, 48): x(u) = 146 + 9u - 18u² + 17u³ and
    // y(u) = 48 + 18u - 36u² + 32u³. x reaches 150 at u = 0.767 with y = 55.1,
    // 0.04 off the probe. Both joins are tangent-continuous, which is the whole
    // property `S` exists to express, so no miter spike reaches a probe.
    .{ .name = "smooth-cubic-stroke-segment", .x = 150, .y = 55, .color = .{ 255, 128, 0 } },
};
/// How far a rasterized probe may sit from the channel the document authored.
/// The probes are inside flat regions, so a real renderer misses by nothing
/// and only premultiplied rounding shows up here.
const specimen_channel_tolerance: u8 = 4;

/// The object-fit image: a 12x4 binary PPM this run decodes for real. Its left
/// quarter is one authored colour in every row and the rest is split
/// horizontally, so a fit that letterboxes, a fit that crops and a fit that
/// stretches each put a DIFFERENT authored colour at the same window point.
/// That is the whole reason this arm exists: one centre texel lies inside every
/// fit, so it cannot tell them apart.
const fit_image_width: usize = 12;
const fit_image_height: usize = 4;
const fit_marker_columns: usize = 2;
const fit_top_rows: usize = 2;
const fit_marker_color = [3]u8{ 255, 0, 0 };
const fit_top_color = [3]u8{ 0, 255, 0 };
const fit_bottom_color = [3]u8{ 0, 0, 255 };
const fit_image_header = "P6\n12 4\n255\n";
const fit_image_bytes: usize = fit_image_header.len + fit_image_width * fit_image_height * 3;

/// The authored colour at `(column, row)` of the object-fit image. Written out
/// rather than stored as a literal blob so the regions the probes name are
/// visible in the source: the left quarter is one colour in EVERY row, and the
/// rest changes once, halfway down.
fn fitImageColor(column: usize, row: usize) [3]u8 {
    if (column < fit_marker_columns) return fit_marker_color;
    return if (row < fit_top_rows) fit_top_color else fit_bottom_color;
}

/// Fills the PPM bytes this run hands to the real decoder.
fn writeFitImage(buffer: *[fit_image_bytes]u8) void {
    @memcpy(buffer[0..fit_image_header.len], fit_image_header);
    var offset: usize = fit_image_header.len;
    for (0..fit_image_height) |row| {
        for (0..fit_image_width) |column| {
            const color = fitImageColor(column, row);
            buffer[offset] = color[0];
            buffer[offset + 1] = color[1];
            buffer[offset + 2] = color[2];
            offset += 3;
        }
    }
}

/// The two fallback fills this run authors. They are NOT the library's own
/// defaults: an authored colour that reaches the window as Oklab proves the
/// element painted the fill it was given, rather than re-proving a constant.
const pending_fill_color: paint.Srgb = .{ .r = 0.10, .g = 0.35, .b = 0.85 };
const failed_fill_color: paint.Srgb = .{ .r = 0.90, .g = 0.25, .b = 0.05 };

/// The background the mounted root authors. A container that authors no fill
/// is painted with the library's own widget default, which is a colour this
/// run neither chose nor can predict, so the root authors one instead: the
/// letterbox an object fit leaves and the area an SVG document leaves empty
/// are then both proven against a colour THIS FILE wrote. Neutral mid
/// grey, far from the clear, from the two fallback fills and from the widget
/// default it replaces, so a fill that silently stopped applying reads as a
/// different pixel instead of passing on the default.
const background_color: paint.Srgb = .{ .r = 0.50, .g = 0.50, .b = 0.50 };

/// The Oklab the renderer converts `background_color` into, which is the value
/// a pixel covered by the root's background has to read back as. Derived
/// through the same two functions the renderer's own fill path uses.
const authored_background = floatsToOklab(
    srgbToLinear(background_color.r),
    srgbToLinear(background_color.g),
    srgbToLinear(background_color.b),
);

/// How close a read-back pixel has to be to the Oklab colour this run authored,
/// in the pipeline's own units. A texel in the middle of a flat authored region
/// comes back exactly, so anything above this is a real difference.
const authored_pixel_tolerance: f32 = 0.02;

/// The budget the tight manager evicts under: one 40-byte entry fits, two
/// do not.
const tight_entry_bytes = 40;
const tight_cache_bytes = tight_entry_bytes;

/// The window the mounted image fills, so the centre pixel of the offscreen
/// target is the centre of the image.
const window_width: u32 = 480;
const window_height: u32 = 260;

/// Scratch sizes for the one scene this binary draws. Deliberately small: a
/// scene that needs more fails loudly through `preparePaint` rather than
/// quietly growing.
const scene_rect_capacity: usize = 64;
const scene_curve_capacity: usize = 0;
const scene_material_capacity: usize = 0;
/// The frame material partition, mirroring the demo's glyph ceiling so a
/// future text engine cannot collide with it. This scene allocates no
/// materials, so only the range's validity matters.
const material_ceiling: u32 = 1024;
const material_slots_per_frame: u32 = 768;
const material_slot_ceiling: u32 = material_ceiling + 3 * material_slots_per_frame;

/// The clear the Oklab target starts from, before the scene is drawn.
const oklab_clear = [4]f32{ 0.20, 0.0, -0.008, 1.0 };

// ── Reporting ──────────────────────────

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// Every expectation in the run, each printed whether it held or not, so a
/// failing run names the claim it could not make.
const Checks = struct {
    report: *Reporter,
    passed: u32 = 0,
    failed: u32 = 0,

    fn expect(self: *Checks, label: []const u8, held: bool) void {
        if (held) self.passed += 1 else self.failed += 1;
        self.report.emit("check: {s} {s}\n", .{
            label,
            if (held) "ok" else "FAILED",
        }) catch @panic("W14 asset smoke could not report a check result");
    }
};

/// The observable state of one key, in one word plus its size.
fn statusText(status: assets.Status, out: []u8) []const u8 {
    return switch (status) {
        .pending => "pending",
        .ready => std.fmt.bufPrint(out, "ready({d} bytes)", .{status.ready.len}) catch "<overflow>",
        .failed => std.fmt.bufPrint(out, "failed({s})", .{@errorName(status.failed)}) catch "<overflow>",
    };
}

/// True only for a ready status. A tagged union is never compared against an
/// enum literal here, so a status variant this run does not know about cannot
/// silently read as ready.
fn isReady(status: assets.Status) bool {
    return switch (status) {
        .ready => true,
        .pending, .failed => false,
    };
}

// ── Shader loading ──────────────────────

/// A SPIR-V module read from the build's `shaders/` output directory. The
/// bytes stay owned for as long as `shaderCreate` and `Renderer.init` need
/// them.
const ShaderFile = struct {
    bytes: []u8,
    spv: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !ShaderFile {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) {
            gpa.free(bytes);
            return error.ShaderModuleMalformed;
        }
        return .{ .bytes = bytes, .spv = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

// ── Bindless heap ───────────────────────

/// The app's bindless descriptor heap plus the handle-to-index map and the
/// per-index generation the element's staleness check relies on.
///
/// The generation is the point: a heap index handed back and reused for
/// another texture carries a new generation, so a timeline that still names
/// the old one is refused instead of sampling a stranger's pixels.
const Bindless = struct {
    /// Room for every image this run uploads at once: the looping timeline's
    /// three frames, the host-driven timeline's three, the object-fit image and
    /// the SVG specimen. It has to exceed that count on purpose, because a heap
    /// that ran out mid-arm would fail as `HeapSlotsExhausted` instead of as
    /// the claim it was meant to prove.
    const capacity: u32 = 16;

    gpu: *noapi.Gpu,
    gpa: std.mem.Allocator,
    heap: noapi.DescriptorHeap,
    map: std.AutoHashMapUnmanaged(noapi.TextureHandle, u32) = .empty,
    generations: [capacity]u64 = @splat(1),
    live: [capacity]bool = @splat(false),

    fn init(gpa: std.mem.Allocator, gpu: *noapi.Gpu) !Bindless {
        const heap = try gpu.descHeapCreate(capacity, 0, 1);
        errdefer gpu.descHeapDestroy(heap);
        const sampler = gpu.samplerDescriptor(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mip_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        gpu.descHeapSetSamplers(heap, 0, &.{sampler});
        return .{ .gpu = gpu, .gpa = gpa, .heap = heap };
    }

    /// Destroys every texture it was handed, then the heap that described them.
    /// The heap outlives nothing: this run tears the device down in the `defer`
    /// registered before the heap was created, so both calls below reach a live
    /// VkDevice on the ordinary and the failing path alike.
    fn deinit(self: *Bindless) void {
        var it = self.map.keyIterator();
        while (it.next()) |handle| self.gpu.textureDestroy(handle.*);
        self.map.deinit(self.gpa);
        self.gpu.descHeapDestroy(self.heap);
        self.* = undefined;
    }

    /// Writes `texture`'s view descriptor into a free heap slot and returns
    /// the slot the element samples.
    fn register(self: *Bindless, texture: noapi.TextureHandle) !image_types.TextureSlot {
        var index: ?u32 = null;
        for (self.live, 0..) |occupied, position| {
            if (!occupied) {
                index = @intCast(position);
                break;
            }
        }
        const slot = index orelse return error.HeapSlotsExhausted;
        const descriptor = self.gpu.textureViewDescriptor(texture, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.heap, slot, &.{descriptor});
        try self.map.put(self.gpa, texture, slot);
        self.live[slot] = true;
        return .{ .index = slot, .generation = self.generations[slot] };
    }

    /// Frees the slot and bumps its generation. The heap descriptor is NOT
    /// overwritten with a null image view: a sampled-image descriptor may not
    /// name a null view unless the device enables `nullDescriptor`, and noapi
    /// writes descriptors verbatim, so that write is a Vulkan violation
    /// rather than a clear. The slot stops being live instead, which is what
    /// `slotOf` consults, and the generation moves so a timeline still naming
    /// it is refused. The retired texture outlives the heap it was registered
    /// in — `deinit` destroys every registered texture before the heap — so
    /// the view the slot still holds is never dangling.
    fn unregister(self: *Bindless, texture: noapi.TextureHandle) void {
        const entry = self.map.fetchRemove(texture) orelse return;
        self.live[entry.value] = false;
        self.generations[entry.value] +%= 1;
    }

    /// The mapper an `AnimatedSequence` needs: a registry handle to the heap
    /// slot the element may sample. Null once the handle is unregistered,
    /// because a slot whose generation moved on is not the same image.
    fn slotOf(self: *const Bindless, texture: noapi.TextureHandle) ?image_types.TextureSlot {
        const slot = self.map.get(texture) orelse return null;
        if (slot >= capacity or !self.live[slot]) return null;
        return .{ .index = slot, .generation = self.generations[slot] };
    }
};

/// The heap generation a texture currently occupies, so a run can assert the
/// element and the heap agree on which image a slot names.
fn generationOf(heap: *const Bindless, texture: noapi.TextureHandle) u64 {
    const slot = heap.slotOf(texture) orelse return 0;
    return slot.generation;
}

// ── The registry to heap mapping ────────

/// The owner side of the mapping. The registry owns decoded CPU images and
/// has no GPU texture behind it, so the owner uploads each decoded image once
/// and registers it. Nothing here treats the registry's own index as a heap
/// index: that index is CPU-side bookkeeping, and sampling it would read
/// whatever texture happens to own that descriptor slot.
const Uploader = struct {
    const Published = struct {
        texture: noapi.TextureHandle,
        slot: image_types.TextureSlot,
    };

    gpu: *noapi.Gpu,
    gpa: std.mem.Allocator,
    bindless: *Bindless,
    textures: *image.TextureRegistry,
    published: std.AutoHashMapUnmanaged(frame_source.TextureHandle, Published) = .empty,

    /// The uploader owns no GPU object: every texture it created was
    /// registered in the heap, and the heap destroys what it registered.
    /// Destroying here as well would free the same texture twice.
    fn deinit(self: *Uploader) void {
        self.published.deinit(self.gpa);
        self.* = undefined;
    }

    /// The texture a published registry handle was uploaded to.
    fn textureFor(self: *const Uploader, handle: frame_source.TextureHandle) ?noapi.TextureHandle {
        const entry = self.published.get(handle) orelse return null;
        return entry.texture;
    }

    /// The mapper an `AnimatedSequence` calls. Uploading here, rather than
    /// inside the sequence, is what keeps the registry free of GPU state.
    fn map(
        context: ?*anyopaque,
        handle: frame_source.TextureHandle,
    ) anyerror!image_types.TextureSlot {
        const self: *Uploader = @ptrCast(@alignCast(context.?));
        // A cached entry is only returned while the heap slot is still live, so
        // a recycled index is reported instead of republished.
        if (self.published.get(handle)) |entry| {
            return self.bindless.slotOf(entry.texture) orelse error.SlotRecycled;
        }
        const decoded = self.textures.get(handle) orelse return error.SlotNotMapped;
        if (decoded.format != .rgba8) return error.UnsupportedUploadFormat;

        const upload: DecodedUpload = .{ .image = decoded };
        const texture = try createOklabTexture(self.gpu, .{
            .width = decoded.width,
            .height = decoded.height,
        }, &upload);
        errdefer self.gpu.textureDestroy(texture);
        const slot = try self.bindless.register(texture);
        try self.published.put(self.gpa, handle, .{ .texture = texture, .slot = slot });
        return slot;
    }
};

/// A decoded RGBA8 image as pipeline floats. Rows are read through the
/// image's own stride, and the conversion to Oklab happens here because the
/// renderer samples Oklab and converts to sRGB only in the final blit.
const DecodedUpload = struct {
    image: *const image.DecodedImage,

    fn write(context: *const anyopaque, out: [*]f32, pixel_count: usize) !void {
        const self: *const DecodedUpload = @ptrCast(@alignCast(context));
        const stride = std.math.cast(usize, self.image.stride) orelse
            return error.UnsupportedUploadFormat;
        if (self.image.pixels.len < stride * @as(usize, self.image.height)) return error.BufferUnderflow;
        for (0..pixel_count) |index| {
            const row = index / @as(usize, self.image.width);
            const column = index % @as(usize, self.image.width);
            const source = row * stride + column * 4;
            const lab = srgbToOklab(
                self.image.pixels[source],
                self.image.pixels[source + 1],
                self.image.pixels[source + 2],
            );
            out[index * 4 + 0] = lab[0];
            out[index * 4 + 1] = lab[1];
            out[index * 4 + 2] = lab[2];
            out[index * 4 + 3] = @as(f32, @floatFromInt(self.image.pixels[source + 3])) / 255.0;
        }
    }
};

// ── Color ───────────────────────────────

/// sRGB byte to linear, the transfer function the Oklab definition assumes.
fn srgbByteToLinear(channel: u8) f32 {
    return srgbToLinear(@as(f32, @floatFromInt(channel)) / 255.0);
}

/// One normalized sRGB channel to linear. Both authored sources use it: an
/// image byte divided by 255, and a fill the paint record already carries in
/// 0..1, so the two are converted by one function rather than two.
fn srgbToLinear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

/// The Oklab the renderer samples. The pipeline works in Oklab throughout and
/// converts to sRGB only in the final blit, so an uploaded image is converted
/// here rather than left in gamma-coded bytes.
fn srgbToOklab(r: u8, g: u8, b: u8) [3]f32 {
    return floatsToOklab(
        srgbByteToLinear(r),
        srgbByteToLinear(g),
        srgbByteToLinear(b),
    );
}

/// The same conversion from already-linear channels. `srgbToOklab` and the
/// fill colours in `paint` use the same matrices and the same transfer
/// function, so this is where both meet.
fn floatsToOklab(red: f32, green: f32, blue: f32) [3]f32 {
    const long = std.math.cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue);
    const medium = std.math.cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue);
    const short = std.math.cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue);

    return .{
        0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
        1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
        0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short,
    };
}

/// An authored `paint.Srgb` fill as the Oklab the frame is read back in. The
/// renderer converts a record's sRGB fill exactly this way, so this is the
/// colour the window has to show.
fn fillToOklab(color: paint.Srgb) [3]f32 {
    return floatsToOklab(srgbToLinear(color.r), srgbToLinear(color.g), srgbToLinear(color.b));
}

/// True when a read-back pixel is the authored colour within the tolerance the
/// run allows, in the pipeline's own units.
fn matchesAuthored(oklab: [3]f32, authored: [3]f32) bool {
    return @abs(oklab[0] - authored[0]) < authored_pixel_tolerance and
        @abs(oklab[1] - authored[1]) < authored_pixel_tolerance and
        @abs(oklab[2] - authored[2]) < authored_pixel_tolerance;
}

/// The chroma magnitude of an Oklab pixel, which is exactly what a grayscale
/// amount scales away.
fn chroma(oklab: [3]f32) f32 {
    return @sqrt(oklab[1] * oklab[1] + oklab[2] * oklab[2]);
}

// ── Texture upload ──────────────────────

/// Creates a sampled rgba32_float texture from a decoded image and fills it
/// through the noapi staging path. rgba8 UNORM cannot hold the negative Oklab
/// ab chroma the pipeline renders in, so every image uploaded here is floats.
/// Ends in a queue idle, so it runs outside the frame loop.
fn createOklabTexture(
    gpu: *noapi.Gpu,
    size: struct { width: u32, height: u32 },
    context: *const DecodedUpload,
) !noapi.TextureHandle {
    const pixel_count = std.math.mul(usize, size.width, size.height) catch
        return error.TextureCapacity;
    const staging_bytes: u64 = @intCast(pixel_count * 4 * @sizeOf(f32));

    const texture = try gpu.textureCreate(.{
        .dimensions = .{ size.width, size.height, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    errdefer gpu.textureDestroy(texture);

    const staging = try gpu.gpuMalloc(staging_bytes, 64, .default);
    defer gpu.gpuFree(staging);
    try DecodedUpload.write(context, @ptrCast(@alignCast(staging.cpu)), pixel_count);

    var command = try gpu.commandsBegin();
    var command_pending = true;
    errdefer if (command_pending) {
        gpu.commandsCancel(&command) catch @panic("upload recording cancellation failed");
    };
    command.copyToTexture(.{
        .gpu = gpu,
        .handle = texture,
        .dimensions = .{ size.width, size.height, 1 },
        .format = .rgba32_float,
    }, staging, .{ .size = .{ size.width, size.height, 1 } });
    try gpu.queueSubmit(&.{command});
    command_pending = false;
    try gpu.waitIdle();
    return texture;
}

// ── Asset fixtures ──────────────────────

/// An application loader that counts its own calls, so a deduplicated key is
/// observable as a call count rather than as an internal flag.
const CountingLoader = struct {
    calls: u32 = 0,
    body: []const u8 = "first",

    fn load(
        allocator: std.mem.Allocator,
        context: ?*anyopaque,
        _: []const u8,
    ) assets.AssetError![]u8 {
        const self: *CountingLoader = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        return allocator.dupe(u8, self.body) catch error.OutOfMemory;
    }
};

// ── Frame producer ──────────────────────

/// One producer-owned buffer handed to a `FrameSource` as a
/// `FrameDescriptor`. `released` is the proof that the descriptor went back
/// through the source's own return path exactly once.
const ProducerFrame = struct {
    pixels: []u8,
    duration_ns: u64,
    released: bool = false,

    fn release(context: ?*anyopaque) void {
        const self: *ProducerFrame = @ptrCast(@alignCast(context.?));
        self.released = true;
    }

    fn descriptor(self: *ProducerFrame) image.FrameDescriptor {
        return .{
            .width = sequence_frame_side,
            .height = sequence_frame_side,
            .format = .rgba8,
            .stride = sequence_frame_side * 4,
            .duration_ns = self.duration_ns,
            .pixels = self.pixels.ptr,
            .release_fn = ProducerFrame.release,
            .release_ctx = self,
        };
    }
};

// ── The mounted view ────────────────────

/// The model the mounted root reads. It holds the published timeline and the
/// generation the view must agree with, so a draw call is a plain struct
/// literal exactly like every other element in the demo.
///
/// `source_state` is what the element is told, so one model can mount an
/// animated timeline, a single ready texture, or one of the two fallback
/// states, without a second root. `anchor_ns` switches the clock the element is
/// timed by: null keeps the authored reading, and a real anchor makes the
/// element follow the same monotonic clock the host's deadlines are timed by,
/// which is the only way a host-driven animation can paint the frame its own
/// wake selected.
pub const Panel = struct {
    timeline: ?image_types.ImageSequence = null,
    ready_slot: ?image_types.TextureSlot = null,
    source_state: SourceState = .timeline,
    intrinsic: image_types.Size = .{
        .width = @floatFromInt(sequence_frame_side),
        .height = @floatFromInt(sequence_frame_side),
    },
    fit: image_types.ObjectFit = .contain,
    generation: u64 = 1,
    grayscale: image_types.Grayscale = .none,
    elapsed_ns: u64 = 0,
    anchor_ns: ?u64 = null,

    /// Which source state the element is mounted with. `pending` is also the
    /// element's own default, so a model with no timeline still paints the
    /// authored pending fill instead of failing.
    pub const SourceState = enum { timeline, ready, pending, failed };

    pub fn deinit(self: *Panel, _: *Session) void {
        self.* = undefined;
    }
};

/// One clock reading and the element stamped from it. The painted frame and the
/// frame request published beside that paint both come from `view`, so they
/// cannot be anchored at two different instants.
const Stamped = struct {
    view: ImageView,
    now_ns: u64,
};

/// The element this model mounts, built from ONE clock reading. A caller that
/// needs the same element outside the tree — the frame request this run
/// publishes beside each real host frame — calls this rather than repeating the
/// literal, so the painted source and the armed wake are one record.
fn stampElement(panel: *const Panel) Stamped {
    const now_ns = sdl3.timer.getNanosecondsSinceInit();
    const elapsed_ns = if (panel.anchor_ns) |anchor| now_ns -| anchor else panel.elapsed_ns;
    const source: nogui.image_view.Source = switch (panel.source_state) {
        .timeline => if (panel.timeline) |timeline|
            .{ .animating = timeline }
        else
            .{ .ready = .invalid },
        .ready => if (panel.ready_slot) |slot|
            .{ .ready = slot }
        else
            .{ .ready = .invalid },
        .pending => .pending,
        .failed => .failed,
    };
    return .{
        .now_ns = now_ns,
        .view = .{
            .intrinsic = panel.intrinsic,
            .source = source,
            .generation = panel.generation,
            .grayscale = panel.grayscale,
            .elapsed_ns = elapsed_ns,
            .fit = panel.fit,
            .label = image_label,
            // The two fallback fills are this run's own authored colours, so the
            // pixels that reach the window are the ones it wrote, not a re-proof
            // of the library's defaults.
            .pending_fill = .{ .srgb = pending_fill_color },
            .failed_fill = .{ .srgb = failed_fill_color },
        },
    };
}

/// The mounted root. It draws the image over an authored background and
/// nothing else: this binary owns no text engine, and a glyph record would
/// need one for its material slots. The image fills the window, so the centre
/// pixel of the render is the centre of the image and the readback assertions
/// address exactly one texel. The background is what every point the image
/// does not cover shows, so it is authored rather than defaulted.
///
/// `stamped` keeps the element the last draw built, so a caller standing beside
/// that frame can publish the matching frame request without reconstructing the
/// element from a second clock reading.
pub const PanelView = struct {
    drawn: u32 = 0,
    stamped: ?Stamped = null,

    pub fn draw(self: *PanelView, panel: *const Panel, ctx: *nogui.DrawCtx) !void {
        self.drawn += 1;
        // The root is a container and fills the window, so it is what an object
        // fit's letterbox and the empty area a document leaves show. The fill is
        // authored rather than defaulted so that colour is this run's own.
        _ = try ctx.column(.{ .fill = paint.Color{ .srgb = background_color } });
        const stamped = stampElement(panel);
        self.stamped = stamped;
        _ = try ctx.elementLeaf(ImageView, .{
            .intrinsic = stamped.view.intrinsic,
            .source = stamped.view.source,
            .generation = stamped.view.generation,
            .grayscale = stamped.view.grayscale,
            .elapsed_ns = stamped.view.elapsed_ns,
            .fit = stamped.view.fit,
            .label = stamped.view.label,
            .pending_fill = stamped.view.pending_fill,
            .failed_fill = stamped.view.failed_fill,
        }, .{
            .key = @as(nogui.ComponentKey, .{ .static = "w14-asset-image" }),
            .width = @as(f32, @floatFromInt(window_width)),
            .height = @as(f32, @floatFromInt(window_height)),
        });
        ctx.pop();
    }
};

// ── Readback ────────────────────────────

/// One captured Oklab pixel. The render target is rgba32_float, so a capture
/// is the pipeline's own color, not a converted approximation. The address is
/// kept so a failing run can name the texel it could not prove.
const Sample = struct {
    x: u32 = 0,
    y: u32 = 0,
    oklab: [3]f32 = .{ 0, 0, 0 },
    alpha: f32 = 0,
    found: bool = false,
};

/// What one captured frame looked like at several addresses. The copy is the
/// whole target either way, so a second probe costs no extra frame: an arm that
/// wants three texels asks for three and reads them all out of one capture.
const Capture = struct {
    /// Sixteen probes covers the specimen sheet, which asks for one address per
    /// authored point, and is still small enough to stay a fixed array, so a
    /// capture never allocates. Nothing here bounds the host wake count: that
    /// arm counts COMMITTED frames against its own timeline length, so a wider
    /// capture cannot let an extra wake pass.
    const capacity = 16;

    samples: [capacity]Sample = @splat(.{}),
    requested: u32 = 0,
    captured: bool = false,

    /// Asks for the target pixel at `(x, y)` in the NEXT captured frame.
    fn want(self: *Capture, x: u32, y: u32) error{TooManyProbes}!void {
        if (self.requested >= capacity) return error.TooManyProbes;
        self.samples[self.requested] = .{ .x = x, .y = y };
        self.requested += 1;
    }

    fn at(self: *const Capture, index: u32) Sample {
        return self.samples[index];
    }
};

/// A target-pixel address. An arm thinks in window content coordinates and
/// converts once, through `targetPixel`, because the offscreen target is in
/// device pixels and the window is in logical ones.
const ProbePoint = struct { x: u32, y: u32 };

/// The live frame request this run publishes beside every real host frame.
///
/// The request goes into the window's OWN `FrameDemand`, so what the arm
/// observes afterwards is the host's own wake state: the deadline the element
/// armed, how many frames it has published, and what that deadline was after
/// the host's next step.
const AnimationArm = struct {
    owner: nogui.WidgetId,
    requests: *image_types.FrameRequests,
    /// How many real frames have published a request since the arm started.
    published: u32 = 0,
    /// The deadline the window's demand carried right after the last publish.
    last_deadline_ms: ?u64 = null,
};

/// The frame this run's OWN authored durations select at `elapsed_ns`,
/// accumulated here rather than read back from the timeline under test. A
/// rendered pixel is paired with this, so "the host woke and painted the frame
/// that deadline reached" is not a claim the timeline makes about itself.
fn hostFrameIndex(elapsed_ns: u64) usize {
    var accumulated: u64 = 0;
    for (host_frame_durations_ns, 0..) |duration_ns, position| {
        accumulated += duration_ns;
        if (elapsed_ns < accumulated) return position;
    }
    return host_frame_durations_ns.len - 1;
}

// ── The smoke ──────────────────────────

const Smoke = struct {
    io: Io,
    gpu: *noapi.Gpu,
    application: *Application,
    app: *App,
    handle: contract.WindowHandle,
    surface: noapi.Surface,
    endpoint: *nogui.GpuEndpoint,
    gui_renderer: *Renderer,
    gui_heap: noapi.DescriptorHeap,
    oklab_target: noapi.TextureHandle,
    oklab_extent: noapi.Extent2D,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_heap: noapi.DescriptorHeap,
    material_buffer: noapi.GpuPtr,
    readback: noapi.GpuPtr,
    /// Set for exactly one frame: the next render copies the Oklab target
    /// into `readback` and fills this in.
    capture: ?*Capture = null,
    /// The mounted root, so a frame can publish the request for the element the
    /// draw it just ran actually built.
    root: *PanelView,
    /// Set while this run wants the mounted image to drive the W05 frame demand.
    /// It names the window's OWN `FrameDemand` as the demand the view arms, so
    /// the wake the host serves is the one the image asked for.
    animation: ?*AnimationArm = null,
    /// The logical size the last frame laid out against, which is what an arm's
    /// content coordinates are relative to.
    logical_width: f32 = 0,
    logical_height: f32 = 0,
    /// The elapsed reading the last drawn element carried, so a caller can pair
    /// a captured pixel with the frame that was on screen when it was read.
    frame_elapsed_ns: u64 = 0,

    tick: u32 = 1,
    frames_committed: u32 = 0,
    frames_presented: u32 = 0,
    host_running: bool = true,

    /// One frame: the mounted scene lowered into the offscreen Oklab target,
    /// blitted to the swapchain, and optionally copied back for an assertion.
    fn render(self: *Smoke) !bool {
        const managed = try self.application.getWindow(self.handle);
        const extent = deviceExtent(managed) catch self.oklab_extent;
        _ = self.surface.beginFrame() catch |err| {
            if (err == error.OutOfDateKHR) {
                self.surface.notifyResize(extent);
                return false;
            }
            return err;
        };
        var cmd = self.surface.commandsBegin();
        var gpu_frame: nogui.GpuFrame = .{
            .endpoint = self.endpoint,
            .command_buffer = &cmd,
            .extent = extent,
            .frame_index = self.frames_committed,
            .recording = .{ .active = .{
                .context = &self.surface,
                .abort = cancelSurfaceRecording,
            } },
        };
        var recording_active = true;
        errdefer if (recording_active) gpu_frame.cancelRecording() catch
            @panic("surface recording cancellation failed");

        const logical = managed.observed.size;
        self.logical_width = @floatFromInt(logical.width);
        self.logical_height = @floatFromInt(logical.height);
        const time_ms = sdl3.timer.getMillisecondsSinceInit();
        self.app.dispatchRootFrame(time_ms);
        const out = try self.app.frameWithGpuAtTime(
            self.tick,
            time_ms,
            .{ .width = @floatFromInt(logical.width), .height = @floatFromInt(logical.height) },
            &gpu_frame,
        );
        // Beside that draw, the element the root JUST built publishes what it
        // owes into the window's own frame demand. One call per animated view
        // per frame, beside the host's own `setDeadline`: the element and the
        // request come from one clock reading, and the demand being armed is
        // the real one the host's step loop consults.
        if (self.animation) |arm| {
            const stamped = self.root.stamped orelse return error.NoStampedElement;
            self.frame_elapsed_ns = stamped.view.elapsed_ns;
            try stamped.view.requestFrameAt(
                arm.owner,
                arm.requests,
                &managed.demand,
                stamped.now_ns,
            );
            arm.published += 1;
            arm.last_deadline_ms = managed.demand.deadline_ms;
        }

        // Every buffer the scene lowering needs comes from the frame arena, so
        // a frame allocates nothing on the heap.
        try self.paintScene(&cmd, out, extent, @floatFromInt(logical.width), @floatFromInt(logical.height));

        const capture = self.capture;
        if (capture != null) {
            // The copy reads what the GUI pass just wrote, so the color
            // output has to be visible to a transfer before the copy is
            // recorded; recorded before that barrier it copies the cleared
            // attachment instead of the frame.
            cmd.barrier(.{ .color_output = true }, .{ .transfer = true }, .{});
            cmd.copyFromTexture(.{
                .gpu = self.gpu,
                .handle = self.oklab_target,
                .dimensions = .{ self.oklab_extent.width, self.oklab_extent.height, 1 },
                .format = .rgba32_float,
            }, self.readback, .{
                .size = .{ self.oklab_extent.width, self.oklab_extent.height, 1 },
            });
        }

        // Barrier: render target color output to fragment shader read.
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});
        self.blit(&cmd, self.surface.currentImage(), extent);

        gpu_frame.finishRecording();
        recording_active = false;
        _ = try self.surface.endFrame(.{ .blit_to_swapchain = true });
        self.frames_committed += 1;
        self.frames_presented += 1;
        self.tick += 1;
        // The copy is only submitted by `endFrame`, so the readback is read
        // after the queue is idle. Reading it earlier would report the
        // PREVIOUS frame's pixels.
        if (capture) |slot| {
            try self.gpu.waitIdle();
            var index: u32 = 0;
            while (index < slot.requested) : (index += 1) {
                const address = slot.samples[index];
                slot.samples[index] = readPixel(self.readback, self.oklab_extent, address.x, address.y);
            }
            slot.captured = true;
            self.capture = null;
        }
        return true;
    }

    /// Lowers the committed frame's authored paint and records the GUI draw
    /// into the offscreen Oklab target.
    fn paintScene(
        self: *Smoke,
        cmd: *noapi.CommandBuffer,
        out: nogui.FrameOutput,
        extent: noapi.Extent2D,
        logical_w: f32,
        logical_h: f32,
    ) !void {
        const arena = out.tree.allocator;
        const commands = try drawcmd.collectDrawCmds(arena, @constCast(out.tree), out.pressed, 0);
        var list = paint.PaintList.init(arena, &.{}, commands.len);
        for (commands) |command| {
            if (command.image_paint) |spec| {
                try list.addImage(spec);
            } else if (command.path_paint) |spec| {
                try list.addPath(spec);
            } else {
                try list.addRect(command.rect_paint);
            }
        }

        const frame_slot = self.gui_renderer.nextFrameSlot();
        if (frame_slot >= 3) return error.InvalidFrameSlot;
        const material_floor = material_ceiling + frame_slot * material_slots_per_frame;
        const rects = try arena.alloc(renderer.SceneRect, scene_rect_capacity);
        const curves = try arena.alloc(nogui.path.Quadratic, scene_curve_capacity);
        const materials = try arena.alloc(renderer.PaintMaterial, scene_material_capacity);
        try self.gui_renderer.preparePaint(cmd, .{
            .legacy_rects = &.{},
            .records = list.records.items,
            .clips = @ptrCast(out.tree.clip_rects[0..out.tree.clip_count]),
        }, .{
            .rects = rects,
            .curves = curves,
            .materials = materials,
            .material_buffer = self.material_buffer,
            .material_slots = material_slot_ceiling,
            .range = .{ .first = material_floor, .end = material_floor },
            .frame_slot = frame_slot,
        });

        cmd.beginRendering(.{
            .color_attachments = &.{.{
                .texture = self.oklab_target,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = oklab_clear,
            }},
            .render_area_size = .{ extent.width, extent.height },
        });
        cmd.setBlendState(.{
            .enable = true,
            .color_op = .add,
            .src_color_factor = .src_alpha,
            .dst_color_factor = .one_minus_src_alpha,
            .alpha_op = .add,
            .src_alpha_factor = .one,
            .dst_alpha_factor = .one_minus_src_alpha,
        });
        cmd.bindDescriptorSets(self.gui_heap);
        self.gui_renderer.draw(
            cmd,
            logical_w,
            logical_h,
            @floatFromInt(extent.width),
            @floatFromInt(extent.height),
        );
        cmd.setBlendEnable(false);
        cmd.endRendering();
    }

    /// The final blit: Oklab to sRGB over the whole target.
    fn blit(self: *Smoke, cmd: *noapi.CommandBuffer, destination: noapi.TextureHandle, extent: noapi.Extent2D) void {
        cmd.beginRendering(.{
            .color_attachments = &.{.{
                .texture = destination,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = .{ 0, 0, 0, 1 },
            }},
            .render_area_size = .{ extent.width, extent.height },
        });
        cmd.setShaders(self.blit_vert, self.blit_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.bindDescriptorSets(self.blit_heap);
        cmd.setBlendEnable(false);
        cmd.draw(noapi.PushData{}, 3, 1);
        cmd.endRendering();
    }

    fn onFrame(
        context: *anyopaque,
        _: *Application,
        _: managed_window_ptr,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *Smoke = @ptrCast(@alignCast(context));
        return self.render();
    }

    fn onQuitRequest(_: *anyopaque, _: *Application, _: Application.QuitToken) Application.QuitDecision {
        return .approve;
    }
};

/// One pixel of the readback, in the pipeline's own Oklab, at the target
/// address the caller asked for. The address travels back with the sample so a
/// failing arm can name the texel it could not prove.
fn readPixel(
    readback: noapi.GpuPtr,
    extent: noapi.Extent2D,
    x: u32,
    y: u32,
) Sample {
    std.debug.assert(x < extent.width);
    std.debug.assert(y < extent.height);
    const pixels: [*]const f32 = @ptrCast(@alignCast(readback.cpu));
    const base = (@as(usize, y) * @as(usize, extent.width) + @as(usize, x)) * 4;
    return .{
        .x = x,
        .y = y,
        .oklab = .{ pixels[base], pixels[base + 1], pixels[base + 2] },
        .alpha = pixels[base + 3],
        .found = true,
    };
}

/// The target texel a window CONTENT coordinate lands on. The scene is laid out
/// in logical units and read back from a target in device pixels, so an arm
/// states its probe where it means it and the scale is applied once here.
fn targetPixel(smoke: *const Smoke, x: f32, y: f32) ProbePoint {
    const scale_x = @as(f32, @floatFromInt(smoke.oklab_extent.width)) / smoke.logical_width;
    const scale_y = @as(f32, @floatFromInt(smoke.oklab_extent.height)) / smoke.logical_height;
    return .{
        .x = std.math.clamp(
            @as(u32, @intFromFloat(@round(x * scale_x))),
            0,
            smoke.oklab_extent.width - 1,
        ),
        .y = std.math.clamp(
            @as(u32, @intFromFloat(@round(y * scale_y))),
            0,
            smoke.oklab_extent.height - 1,
        ),
    };
}

/// The middle of the mounted image: the content rectangle the root fills, in
/// window content coordinates.
const content_centre: ProbePoint = .{ .x = window_width / 2, .y = window_height / 2 };

fn cancelSurfaceRecording(context: *anyopaque, _: *noapi.CommandBuffer) !void {
    const surface: *noapi.Surface = @ptrCast(@alignCast(context));
    try surface.abortFrame();
}

var exts_storage: [][*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_storage;
}

fn deviceExtent(managed: managed_window_ptr) !noapi.Extent2D {
    const pixels = try managed.native.sdl.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

fn framesSettled(smoke: *Smoke) bool {
    return smoke.frames_committed >= 1;
}

fn pumpUntil(
    smoke: *Smoke,
    deadline_ms: u64,
    context: *const fn (*Smoke) bool,
) !bool {
    while (sdl3.timer.getMillisecondsSinceInit() < deadline_ms) {
        if (!try smoke.application.step()) {
            smoke.host_running = false;
            break;
        }
        if (context(smoke)) return true;
        try Io.sleep(smoke.io, Io.Duration.fromMilliseconds(2), .real);
    }
    return context(smoke);
}

/// Drive exactly `count` further committed frames, one invalidation per host
/// step. The window is never told to re-present, so the only frames that can
/// commit are the ones requested here.
fn driveFrames(smoke: *Smoke, count: u32) !u64 {
    const start = smoke.app.frame_generation;
    const deadline = sdl3.timer.getMillisecondsSinceInit() + 10_000;
    while (smoke.app.frame_generation - start < count) {
        if (sdl3.timer.getMillisecondsSinceInit() > deadline) return error.FrameBudgetExpired;
        const managed = try smoke.application.getWindow(smoke.handle);
        managed.demand.invalidateLayout();
        _ = try smoke.application.step();
    }
    return smoke.app.frame_generation - start;
}

// ── Element probe ──────────────────────

/// What one `ImageView` emitted, counted through the public `PaintWriter`.
const Probe = struct {
    images: usize = 0,
    rects: usize = 0,
    texture_index: ?u32 = null,
    grayscale: ?f32 = null,
};

/// Runs the element's own paint through a real writer and reports what it
/// emitted. The window rasterizes the same record, but this says exactly which
/// primitive the element chose: which slot it sampled at a given clock
/// reading, whether a stale generation falls back to the pending fill, and
/// what grayscale amount it forwarded.
fn probeView(allocator: std.mem.Allocator, view: ImageView) !Probe {
    var records: std.ArrayList(nogui.element.PaintRecord) = .empty;
    defer records.deinit(allocator);
    var writer: nogui.element.PaintWriter = .{ .allocator = allocator, .records = &records };
    var phase: ImageView.PhaseState = .{};
    const bounds: nogui.element.Geometry = .{
        .border = .{ .x = 0, .y = 0, .w = 96, .h = 96 },
        .content = .{ .x = 0, .y = 0, .w = 96, .h = 96 },
    };
    try view.paint(&phase, bounds, &writer);

    var probe: Probe = .{};
    for (records.items) |record| {
        switch (record) {
            .image => |spec| {
                probe.images += 1;
                probe.texture_index = spec.texture_index;
                probe.grayscale = spec.grayscale;
            },
            .rect => {
                probe.rects += 1;
            },
            .path => {},
        }
    }
    return probe;
}

/// Without a GPU heap there is no bindless index to publish, and the registry
/// handle IS the generational slot type, so this mapping gives the element a
/// real generation instead of a fabricated index no device owns. The demand
/// arm never samples a pixel, so it needs no heap behind the slot.
fn registrySlotMap(_: ?*anyopaque, handle: image.TextureHandle) anyerror!image_types.TextureSlot {
    return handle;
}

/// Drives the W05 frame demand with a real published timeline.
///
/// An idle host with nothing dirty sleeps exactly to the next frame boundary,
/// paints there and not in between, and goes back to sleep once the image has
/// ended or its source is gone. The element is probed through its own
/// `PaintWriter` at every boundary, so the slot the wake produced is the slot
/// the paint sampled rather than two unrelated claims.
///
/// This arm needs no window and no GPU, so `--no-window` runs it alone and the
/// windowed run adds the rendered pixels on top of the same deadlines.
fn runDeadlineArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    checks: *Checks,
) !void {
    const ms = std.time.ns_per_ms;
    // Zeroed first, so the free below covers every frame even when an
    // allocation in the middle of the loop fails.
    var frames: [sequence_frame_durations_ns.len]ProducerFrame = @splat(.{
        .pixels = &.{},
        .duration_ns = 0,
    });
    defer for (&frames) |*frame| gpa.free(frame.pixels);
    for (&frames, 0..) |*frame, position| {
        const color = sequence_frame_colors[position];
        frame.* = .{
            .pixels = try gpa.alloc(u8, sequence_frame_rgba_bytes),
            .duration_ns = sequence_frame_durations_ns[position],
        };
        var offset: usize = 0;
        while (offset < frame.pixels.len) : (offset += 4) {
            frame.pixels[offset + 0] = color[0];
            frame.pixels[offset + 1] = color[1];
            frame.pixels[offset + 2] = color[2];
            frame.pixels[offset + 3] = 255;
        }
    }

    var source = frame_source.FrameSource.init(gpa, io, frames.len);
    defer source.deinit() catch
        @panic("W14 animation smoke teardown still has borrowed frames");
    for (&frames) |*frame| try source.pushFrame(frame.descriptor());

    var textures = image.TextureRegistry.init(gpa, io);
    defer textures.deinit();
    var sequence = frame_source.AnimatedSequence.init(&source, &textures, .{
        // A non-looping image ends: that end is what has to stop the loop.
        .loop = false,
        .slot_mapper = registrySlotMap,
        .mapper_context = null,
    });
    defer sequence.deinit();
    while (try sequence.submitNext()) {}
    const timeline = sequence.timeline();
    if (!timeline.isValid()) return error.InvalidTimeline;

    const owner: nogui.WidgetId = .{ .owner = 21, .slot = 1, .generation = 1 };
    var requests = image_types.FrameRequests.init(gpa, owner.owner);
    defer requests.deinit();
    var demand: nogui.frame_demand.FrameDemand = .{};
    // Consume the one frame an idle window starts dirty with, so everything
    // below is an idle host: no layout, paint, presentation or continuous.
    _ = demand.take(0).?;
    demand.finish(true);

    var view: ImageView = .{
        .intrinsic = .{
            .width = @floatFromInt(sequence_frame_side),
            .height = @floatFromInt(sequence_frame_side),
        },
        .source = .{ .animating = timeline },
        .generation = timeline.frames[0].slot.generation,
        .elapsed_ns = 0,
        .label = image_label,
    };
    try view.requestFrameAt(owner, &requests, &demand, 0);
    const armed = demand.deadline_ms orelse return error.NoFrameDeadline;
    try report.emit("demand: first_deadline_ms={d} period_ns={d} frames={d}\n", .{
        armed,
        timeline.totalDurationNs(),
        timeline.frameCount(),
    });
    checks.expect("the first frame deadline is the first boundary", armed == sequence_frame_durations_ns[0] / ms);

    // Walk every boundary: sleep that long, paint there, and never between.
    var now_ns: u64 = 0;
    var previous_slot = timeline.frameAt(0).?.slot.index;
    for (sequence_frame_durations_ns[0..], 0..) |duration_ns, position| {
        const deadline_ms = (duration_ns + now_ns) / ms;
        if (deadline_ms != demand.deadline_ms.? or
            demand.waitMilliseconds(now_ns / ms) != @as(?u31, @intCast(deadline_ms - now_ns / ms)))
        {
            try report.emit("demand: boundary {d} missed deadline={?d} wait={?d}\n", .{
                position,
                demand.deadline_ms,
                demand.waitMilliseconds(now_ns / ms),
            });
            return error.MissedFrameDeadline;
        }
        if (demand.take(deadline_ms - 1) != null) return error.EarlyFrame;
        const work = demand.take(deadline_ms) orelse return error.NoFrameAtDeadline;
        if (!work.animation or !work.paint or !work.present or work.layout) {
            return error.NotAnAnimationFrame;
        }
        demand.finish(true);

        now_ns = deadline_ms * ms;
        view.elapsed_ns = now_ns;
        try view.requestFrameAt(owner, &requests, &demand, now_ns);
        const probe = try probeView(gpa, view);
        const selected = timeline.frameAt(now_ns).?.slot.index;
        try report.emit("demand: t={d}ms slot={d} painted_slot={?d} next_deadline_ms={?d}\n", .{
            deadline_ms,
            selected,
            probe.texture_index,
            demand.deadline_ms,
        });
        checks.expect(
            "the frame at the deadline reached the element",
            probe.images == 1 and probe.texture_index != null and probe.texture_index.? == selected,
        );
        // The last boundary of a non-looping image is its end rather than a
        // change of frame: the final frame stays on screen instead of wrapping.
        checks.expect(
            if (position + 1 == sequence_frame_durations_ns.len)
                "the end holds the last frame"
            else
                "each boundary advanced to a different frame",
            if (position + 1 == sequence_frame_durations_ns.len)
                selected == previous_slot
            else
                selected != previous_slot,
        );
        previous_slot = selected;
    }

    // The image has ended. Its last frame is still the one the element paints,
    // but it owes nothing, so the host that was sleeping on it stays asleep.
    const ended = try probeView(gpa, view);
    try report.emit("demand: ended deadline_ms={?d} wait_ms={?d} outstanding={d} slot={?d}\n", .{
        demand.deadline_ms,
        demand.waitMilliseconds(now_ns / ms),
        requests.count(),
        ended.texture_index,
    });
    checks.expect("a finished image owes no frame", demand.deadline_ms == null);
    checks.expect("an idle host sleeps with no deadline", demand.waitMilliseconds(now_ns / ms) == null);
    checks.expect("no frame is claimed once the image ended", demand.take(now_ns / ms) == null);
    checks.expect("the last frame stays on screen", ended.images == 1 and ended.rects == 0);
    checks.expect("the timeline reports itself complete", timeline.isComplete(view.elapsed_ns));

    // Source removal is the other stop: the owner owes nothing from the first
    // request after its source is gone, and the element paints the pending
    // fill instead of a frame that no longer exists.
    view.source = .pending;
    try view.requestFrameAt(owner, &requests, &demand, now_ns);
    const gone = try probeView(gpa, view);
    try report.emit("demand: retired owners={d} deadline_ms={?d} element_images={d}\n", .{
        requests.count(),
        demand.deadline_ms,
        gone.images,
    });
    checks.expect("a removed source retires its frame request", requests.count() == 0);
    checks.expect("a removed source leaves the host idle", demand.deadline_ms == null);
    checks.expect(
        "a removed source paints the pending fill",
        gone.images == 0 and gone.rects == 1,
    );
}

// ── The HTTP fixture ────────────────────

/// The SVG document the fixture server hands out: a real document with its own
/// intrinsic size, so the FETCHED bytes can be measured and rasterized instead
/// of only compared with what was sent.
const fixture_svg_bytes =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32">
    \\  <rect x="0" y="0" width="64" height="32" fill="#ff0000"/>
    \\</svg>
;

/// Loopback ports this run may bind, in order. The port is fixed rather than
/// ephemeral because Zig 0.16 exposes no way to read the port back from a bound
/// socket, so the run scans a short range and fails loudly when every port in
/// it is taken instead of quietly serving nothing.
const fixture_ports = [_]u16{ 47311, 47312, 47313, 47314, 47315 };

const FixtureListener = struct {
    server: Io.net.Server,
    port: u16,
};

/// Binds the first free loopback port from `fixture_ports`.
fn bindFixturePort(io: Io) !FixtureListener {
    for (fixture_ports) |port| {
        const address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
        const server = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => return err,
        };
        return .{ .server = server, .port = port };
    }
    return error.NoFixturePort;
}

/// Answers up to `capacity` requests on an already-bound loopback listener, one
/// connection each, with the fixture document the request target names. The
/// bytes travel through a socket and an HTTP/1.1 exchange rather than through a
/// callback that hands them straight back.
fn serveFixtureRequests(
    io: Io,
    server: *Io.net.Server,
    capacity: u32,
    served: *std.atomic.Value(u32),
) void {
    var answered: u32 = 0;
    while (answered < capacity) : (answered += 1) {
        const stream = server.accept(io) catch return;
        // A Stream is a handle, not an owner: dropping it would leave the
        // connection open until the process exits.
        defer stream.close(io);
        var in_buffer: [4096]u8 = undefined;
        var out_buffer: [4096]u8 = undefined;
        var reader: Io.net.Stream.Reader = .init(stream, io, &in_buffer);
        var writer: Io.net.Stream.Writer = .init(stream, io, &out_buffer);
        var server_http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server_http.receiveHead() catch return;
        _ = served.fetchAdd(1, .release);
        const body: []const u8 = if (std.mem.startsWith(u8, request.head.target, "/badge.ppm"))
            badge_ppm
        else if (std.mem.startsWith(u8, request.head.target, "/specimen.svg"))
            fixture_svg_bytes
        else {
            request.respond("not found", .{ .status = .not_found, .keep_alive = false }) catch return;
            continue;
        };
        request.respond(body, .{ .status = .ok, .keep_alive = false }) catch return;
    }
}

/// The `HttpSource` transport for one fixture server. It fetches over a real
/// loopback socket and refuses any URL outside this process's own authority,
/// so no key can redirect the run to a public network address.
const LoopbackFixture = struct {
    const body_limit: usize = 64 * 1024;

    client: std.http.Client,
    /// `http://127.0.0.1:<port>`, borrowed from the caller's buffer.
    authority: []const u8 = "",
    /// Counted on the loading thread, which is where `AssetManager.load` runs.
    fetches: u32 = 0,

    fn deinit(self: *LoopbackFixture) void {
        self.client.deinit();
        self.* = undefined;
    }

    fn fetch(allocator: std.mem.Allocator, ctx: ?*anyopaque, url: []const u8) assets.AssetError![]u8 {
        const self: *LoopbackFixture = @ptrCast(@alignCast(ctx.?));
        if (url.len <= self.authority.len or url[self.authority.len] != '/' or
            !std.mem.startsWith(u8, url, self.authority)) return error.NotFound;
        self.fetches += 1;
        var storage: [body_limit]u8 = undefined;
        var out: Io.Writer = .fixed(&storage);
        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &out,
            .keep_alive = false,
        }) catch return error.NetworkError;
        if (result.status != .ok) return error.NetworkError;
        return allocator.dupe(u8, out.buffered()) catch error.OutOfMemory;
    }
};

/// Fetches two fixture documents over a real loopback HTTP connection and
/// proves the FETCHED bytes are the documents that render: the PPM decodes to
/// its authored 2x2 pixels and the SVG measures and rasterizes at its own
/// intrinsic size. Nothing here reaches a public network: the transport serves
/// only this process's own authority, and a key naming another host is refused
/// before a socket is opened.
fn runHttpFixtureArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    checks: *Checks,
    manager: *assets.AssetManager,
) !void {
    // One request more than the run needs, so a repeated key that wrongly
    // missed the cache is answered and fails a check instead of hanging on a
    // connection nobody serves.
    const capacity: u32 = 3;
    var listener = try bindFixturePort(io);
    defer listener.server.deinit(io);

    var fixture: LoopbackFixture = .{ .client = .{ .allocator = gpa, .io = io } };
    defer fixture.deinit();
    var authority_buffer: [64]u8 = undefined;
    fixture.authority = try std.fmt.bufPrint(&authority_buffer, "http://127.0.0.1:{d}", .{listener.port});
    const old_transport = manager.http.transport;
    const old_transport_ctx = manager.http.transport_ctx;
    defer {
        manager.http.transport = old_transport;
        manager.http.transport_ctx = old_transport_ctx;
    }
    manager.http.setTransport(&fixture, LoopbackFixture.fetch);
    var image_url_buffer: [96]u8 = undefined;
    var svg_url_buffer: [96]u8 = undefined;
    const image_url = try std.fmt.bufPrint(&image_url_buffer, "{s}/badge.ppm", .{fixture.authority});
    const svg_url = try std.fmt.bufPrint(&svg_url_buffer, "{s}/specimen.svg", .{fixture.authority});

    var served = std.atomic.Value(u32).init(0);
    var serving: Io.Group = .init;
    defer serving.cancel(io);
    try serving.concurrent(io, serveFixtureRequests, .{
        io,
        &listener.server,
        capacity,
        &served,
    });
    // A cache hit sends only two requests. Cancel and await the spare accept
    // after the conversation, before its borrowed listener or counter retires.
    const foreign = manager.load(AssetKey.init(.http, "http://example.invalid/badge.ppm"));
    const image_status = manager.load(AssetKey.init(.http, image_url));
    const svg_status = manager.load(AssetKey.init(.http, svg_url));
    const cached = manager.load(AssetKey.init(.http, image_url));
    serving.cancel(io);

    const foreign_state = switch (foreign) {
        .ready => "ready",
        .pending => "pending",
        .failed => "failed",
    };
    try report.emit("http: authority={s} fetches={d} served={d} foreign={s} cache_hit={}\n", .{
        fixture.authority,
        fixture.fetches,
        served.load(.acquire),
        foreign_state,
        isReady(cached),
    });
    checks.expect(
        "a key outside the fixture server is refused",
        std.mem.eql(u8, foreign_state, "failed"),
    );
    checks.expect("one transport fetch per uncached request", fixture.fetches == 2);
    checks.expect("the repeated key came from the cache, not the socket", served.load(.acquire) == 2);

    const fetched_image = switch (image_status) {
        .ready => |bytes| bytes,
        .pending, .failed => return error.MissingHttpImage,
    };
    const fetched_svg = switch (svg_status) {
        .ready => |bytes| bytes,
        .pending, .failed => return error.MissingHttpSvg,
    };
    var decoded = try image.decode(gpa, io, fetched_image);
    defer decoded.deinit();
    checks.expect(
        "the fetched PPM decodes to the authored document",
        decoded.width == 2 and decoded.height == 2 and decoded.format == .rgba8 and
            decoded.pixels[0] == 255 and decoded.pixels[1] == 0 and
            decoded.pixels[2] == 0 and decoded.pixels[3] == 255,
    );

    const engine = host.svg.SvgEngine.getGlobal(io);
    if (engine.isAvailable()) {
        const size = try host.svg.queryIntrinsicSize(io, fetched_svg);
        checks.expect(
            "the fetched SVG carries its own intrinsic size",
            size != null and size.?.width == 64 and size.?.height == 32,
        );
        var rendered = try host.svg.renderSvg(gpa, io, fetched_svg, .{
            .viewport_width = 64,
            .viewport_height = 32,
            .dpi_scale = 1.0,
        });
        defer rendered.deinit();
        const top_left = rendered.pixels[0..4];
        try report.emit("http: fetched SVG rendered {d}x{d} corner=({d},{d},{d},{d})\n", .{
            rendered.width,
            rendered.height,
            top_left[0],
            top_left[1],
            top_left[2],
            top_left[3],
        });
        checks.expect(
            "the fetched SVG rasterizes at its intrinsic viewport",
            rendered.width == 64 and rendered.height == 32,
        );
        // Pixels, not a size: the document's own fill, in its own channels.
        checks.expect(
            "the fetched SVG rasterized its authored fill",
            top_left[0] >= 250 and top_left[1] <= 5 and top_left[2] <= 5 and top_left[3] >= 250,
        );
    } else {
        // Name the reason, so a mislinked librsvg reads as an unrun rasterizer
        // instead of as a passing pixel check.
        try report.emit("http: svg engine unavailable: {t}\n", .{engine.unavailableReason()});
        checks.expect(
            "the fetched SVG bytes are the served document",
            std.mem.eql(u8, fetched_svg, fixture_svg_bytes),
        );
    }
}

// ── The authored specimen ──────────────

/// True when the rasterized document carries what the DOCUMENT authored at one
/// probe: the shape's own colour inside a flat region, or nothing at all where
/// the document authors no shape. The comparison is against the authored
/// channel, never against another rendering, so a rasterizer that agreed with
/// itself about the wrong colour still fails here.
fn specimenProbeHolds(raster: image.DecodedImage, probe: SpecimenProbe) bool {
    const stride = std.math.cast(usize, raster.stride) orelse return false;
    const base = @as(usize, probe.y) * stride + @as(usize, probe.x) * 4;
    if (base + 4 > raster.pixels.len) return false;
    const authored = probe.color orelse
        return raster.pixels[base] == 0 and raster.pixels[base + 1] == 0 and
            raster.pixels[base + 2] == 0 and raster.pixels[base + 3] == 0;
    const tolerance: i32 = specimen_channel_tolerance;
    for ([_]usize{ 0, 1, 2 }) |channel| {
        const actual: i32 = @intCast(raster.pixels[base + channel]);
        const wanted: i32 = @intCast(authored[channel]);
        if (@abs(actual - wanted) > tolerance) return false;
    }
    // A shape's own body is opaque, so an alpha short of that is a hole in it.
    return raster.pixels[base + 3] >= 250;
}

/// One probe read out of the raster, printed with the document's own authoring
/// beside it, so a failing run names the point rather than a boolean.
fn reportSpecimenProbe(
    report: *Reporter,
    raster: image.DecodedImage,
    probe: SpecimenProbe,
) !void {
    const stride = std.math.cast(usize, raster.stride) orelse return error.InvalidStride;
    const base = @as(usize, probe.y) * stride + @as(usize, probe.x) * 4;
    if (base + 4 > raster.pixels.len) return error.ShortRaster;
    const held = specimenProbeHolds(raster, probe);
    // A probe with no authored colour is the empty area, so its authored value
    // is spelled as zeros and the word says which case this was.
    const authored = probe.color orelse [3]u8{ 0, 0, 0 };
    try report.emit(
        "specimen: {s} ({d},{d}) raster=({d},{d},{d},{d}) authored=({d},{d},{d}) " ++
            "transparent={} {s}\n",
        .{
            probe.name,
            probe.x,
            probe.y,
            raster.pixels[base],
            raster.pixels[base + 1],
            raster.pixels[base + 2],
            raster.pixels[base + 3],
            authored[0],
            authored[1],
            authored[2],
            probe.color == null,
            if (held) "ok" else "MISMATCH",
        },
    );
}

/// Loads the authored specimen through the asset manager and rasterizes it with
/// librsvg, then answers every probe from the document's own authoring: a group
/// under a transform, both arc flag combinations, a local `use` reference, a
/// quadratic, a cubic, both of them also as the smooth chained commands, and
/// the region the document leaves empty.
///
/// The raster comes back to the caller so the display arm uploads the very bytes
/// that were probed. An unavailable rasterizer returns null with its reason
/// named, because a missing librsvg is an unrun rasterizer and not a passing
/// pixel claim.
fn runSpecimenArm(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    checks: *Checks,
    manager: *assets.AssetManager,
) !?image.DecodedImage {
    const engine = host.svg.SvgEngine.getGlobal(io);
    if (!engine.isAvailable()) {
        try report.emit("specimen: svg engine unavailable: {t}\n", .{engine.unavailableReason()});
        return null;
    }

    const bytes = switch (manager.load(AssetKey.init(.embedded, specimen_key))) {
        .ready => |body| body,
        .pending, .failed => return error.MissingSpecimenBytes,
    };
    checks.expect(
        "the embedded specimen is the authored document",
        std.mem.eql(u8, bytes, specimen_svg_bytes),
    );

    const size = try host.svg.queryIntrinsicSize(io, bytes);
    checks.expect(
        "the specimen carries its authored intrinsic size",
        size != null and size.?.width == @as(f32, @floatFromInt(specimen_width)) and
            size.?.height == @as(f32, @floatFromInt(specimen_height)),
    );

    var raster = try host.svg.renderSvg(gpa, io, bytes, .{
        .viewport_width = specimen_width,
        .viewport_height = specimen_height,
        .dpi_scale = 1.0,
    });
    errdefer raster.deinit();
    checks.expect(
        "the specimen rasterizes at its authored viewport",
        raster.width == specimen_width and raster.height == specimen_height,
    );

    var matched: usize = 0;
    for (specimen_probes) |probe| {
        if (specimenProbeHolds(raster, probe)) matched += 1;
        try reportSpecimenProbe(report, raster, probe);
    }
    checks.expect("every specimen probe answered from the document", matched == specimen_probes.len);
    return raster;
}

/// Where a `.contain` fit puts an image inside the window content, derived here
/// from the authored numbers rather than read back from `fitRect`. The specimen
/// arm must not stand on the fit code it is placed beside, so the scale and the
/// letterbox are arithmetic here and the probe addresses follow from them.
fn containedPlacement(intrinsic_w: f32, intrinsic_h: f32) struct { x: f32, y: f32, scale: f32 } {
    const content_w: f32 = @floatFromInt(window_width);
    const content_h: f32 = @floatFromInt(window_height);
    const scale = @min(content_w / intrinsic_w, content_h / intrinsic_h);
    return .{
        .x = (content_w - intrinsic_w * scale) / 2.0,
        .y = (content_h - intrinsic_h * scale) / 2.0,
        .scale = scale,
    };
}

/// The specimen on the DISPLAY. The rasterized document is uploaded through the
/// same bindless path every other image in this run uses, mounted as a ready
/// texture, and read back from the window's own pixels: the interior of a named
/// shape, the middle of a named stroke, the body a `use` instantiates, each
/// curve command's own polynomial, and the region the document leaves empty,
/// which has to arrive as the background the root authors. The document authors
/// nothing there, so whatever is under the image is what the window shows, and
/// that has to be the colour this run wrote rather than whatever a container
/// would default to.
fn runSpecimenPixelArm(
    report: *Reporter,
    checks: *Checks,
    session: *Session,
    smoke: *Smoke,
    panel: anytype,
    slot: image_types.TextureSlot,
) !void {
    try session.update(Panel, panel, slot, struct {
        fn mount(target: *Panel, value: image_types.TextureSlot) void {
            target.source_state = .ready;
            target.ready_slot = value;
            target.timeline = null;
            target.generation = value.generation;
            target.grayscale = .none;
            target.fit = .contain;
            target.elapsed_ns = 0;
            target.anchor_ns = null;
            target.intrinsic = .{
                .width = @floatFromInt(specimen_width),
                .height = @floatFromInt(specimen_height),
            };
        }
    }.mount);

    const placement = containedPlacement(
        @floatFromInt(specimen_width),
        @floatFromInt(specimen_height),
    );
    var capture: Capture = .{};
    for (specimen_probes) |probe| {
        // Half a texel in: a probe on a texel BOUNDARY samples half of the
        // neighbour, and the empty area next to a shape would then read as
        // half ink. The centre of the texel the document authored is the only
        // address that carries that texel's own colour.
        const point = targetPixel(
            smoke,
            placement.x + (@as(f32, @floatFromInt(probe.x)) + 0.5) * placement.scale,
            placement.y + (@as(f32, @floatFromInt(probe.y)) + 0.5) * placement.scale,
        );
        try capture.want(point.x, point.y);
    }
    smoke.capture = &capture;
    _ = try driveFrames(smoke, 1);

    var matched: usize = 0;
    for (specimen_probes, 0..) |probe, position| {
        const sample = capture.at(@intCast(position));
        // An authored colour is compared against the pixel. The empty area
        // is compared against the root's authored background, because the
        // document draws nothing there: any ink at that address, or the widget
        // default a container would fall back to, is a different pixel and
        // fails. The alpha carries the same claim: the point is opaque.
        const held = if (probe.color) |authored|
            matchesAuthored(sample.oklab, srgbToOklab(authored[0], authored[1], authored[2]))
        else
            matchesAuthored(sample.oklab, authored_background) and sample.alpha > 0.99;
        if (held) matched += 1;
        try report.emit("window specimen: {s} texel=({d},{d}) L={d:.4} a={d:.4} b={d:.4} {s}\n", .{
            probe.name,
            sample.x,
            sample.y,
            sample.oklab[0],
            sample.oklab[1],
            sample.oklab[2],
            if (held) "ok" else "MISMATCH",
        });
    }
    try report.emit("window specimen: scale={d:.3} offset=({d:.2},{d:.2}) probes={d}/{d}\n", .{
        placement.scale,
        placement.x,
        placement.y,
        matched,
        specimen_probes.len,
    });
    checks.expect("the mounted specimen was read back", capture.captured);
    checks.expect("the window shows what the document authored", matched == specimen_probes.len);
}

// ── Object fit, in pixels ─────────────

/// True when two read-back pixels differ by more than the tolerance this run
/// allows, i.e. when they are two different colours rather than one colour read
/// twice. Used where the claim is that two states produced two pixels, rather
/// than that either pixel was a particular authored one.
fn pixelsDiffer(left: [3]f32, right: [3]f32) bool {
    return @abs(left[0] - right[0]) > authored_pixel_tolerance or
        @abs(left[1] - right[1]) > authored_pixel_tolerance or
        @abs(left[2] - right[2]) > authored_pixel_tolerance;
}

/// The three content coordinates every fit is probed at, each chosen so the
/// answer differs per fit:
///   * `(30, 32)` sits inside the letterbox `.contain` leaves above a 12x4
///     image, inside the crop `.cover` leaves at the left, and on the image's
///     marker column under `.fill`. It is the point the whole arm is about.
///   * `(240, 240)` sits inside the bottom letterbox `.contain` leaves and
///     inside the stretched/cropped image under the other two.
///   * `(240, 70)` is inside the authored image under all three, so a run cannot
///     pass this arm by leaving the image undrawn.
const fit_edge_probe: ProbePoint = .{ .x = 30, .y = 32 };
const fit_bottom_probe: ProbePoint = .{ .x = 240, .y = 240 };
const fit_interior_probe: ProbePoint = .{ .x = 240, .y = 70 };

/// Object fit as pixels. One authored 12x4 image with three differently
/// coloured regions is mounted at `.contain`, `.cover` and `.fill` in turn and
/// probed in the window. A single centre texel lies inside every fit, so it can
/// only ever prove that an image was drawn; these three addresses prove WHICH
/// fit drew it.
fn runFitPixelArm(
    report: *Reporter,
    checks: *Checks,
    session: *Session,
    smoke: *Smoke,
    panel: anytype,
    slot: image_types.TextureSlot,
) !void {
    const Fit = struct {
        fit: image_types.ObjectFit,
        edge: [3]f32,
        bottom: [3]f32,
        interior: [3]f32,
    };
    // A `.contain` fit leaves the root's own background in the letterbox, and
    // that background is the colour THIS RUN authored, not a library default
    // and not the clear: the root is a container and covers the whole window.
    const letterbox: [3]f32 = authored_background;
    // What each fit must show at each probe, taken from the authored image and
    // the window size rather than from the renderer.
    const expectations = [_]Fit{
        .{
            .fit = .contain,
            .edge = letterbox,
            .bottom = letterbox,
            .interior = srgbToOklab(fit_top_color[0], fit_top_color[1], fit_top_color[2]),
        },
        .{
            .fit = .cover,
            .edge = srgbToOklab(fit_top_color[0], fit_top_color[1], fit_top_color[2]),
            .bottom = srgbToOklab(fit_bottom_color[0], fit_bottom_color[1], fit_bottom_color[2]),
            .interior = srgbToOklab(fit_top_color[0], fit_top_color[1], fit_top_color[2]),
        },
        .{
            .fit = .fill,
            .edge = srgbToOklab(fit_marker_color[0], fit_marker_color[1], fit_marker_color[2]),
            .bottom = srgbToOklab(fit_bottom_color[0], fit_bottom_color[1], fit_bottom_color[2]),
            .interior = srgbToOklab(fit_top_color[0], fit_top_color[1], fit_top_color[2]),
        },
    };

    var edges: [expectations.len][3]f32 = undefined;
    for (expectations, 0..) |expected, fit_position| {
        const Mount = struct {
            slot: image_types.TextureSlot,
            fit: image_types.ObjectFit,
        };
        try session.update(Panel, panel, Mount{ .slot = slot, .fit = expected.fit }, struct {
            fn mount(target: *Panel, value: Mount) void {
                target.source_state = .ready;
                target.ready_slot = value.slot;
                target.timeline = null;
                target.generation = value.slot.generation;
                target.grayscale = .none;
                target.fit = value.fit;
                target.elapsed_ns = 0;
                target.anchor_ns = null;
                target.intrinsic = .{
                    .width = @floatFromInt(fit_image_width),
                    .height = @floatFromInt(fit_image_height),
                };
            }
        }.mount);

        const edge_point = targetPixel(
            smoke,
            @floatFromInt(fit_edge_probe.x),
            @floatFromInt(fit_edge_probe.y),
        );
        const bottom_point = targetPixel(
            smoke,
            @floatFromInt(fit_bottom_probe.x),
            @floatFromInt(fit_bottom_probe.y),
        );
        const interior_point = targetPixel(
            smoke,
            @floatFromInt(fit_interior_probe.x),
            @floatFromInt(fit_interior_probe.y),
        );
        var capture: Capture = .{};
        try capture.want(edge_point.x, edge_point.y);
        try capture.want(bottom_point.x, bottom_point.y);
        try capture.want(interior_point.x, interior_point.y);
        smoke.capture = &capture;
        _ = try driveFrames(smoke, 1);

        const edge = capture.at(0);
        const bottom = capture.at(1);
        const interior = capture.at(2);
        edges[fit_position] = edge.oklab;
        try report.emit(
            "fit {s}: edge({d},{d}) L={d:.4} a={d:.4} b={d:.4} | " ++
                "bottom({d},{d}) L={d:.4} a={d:.4} b={d:.4} | " ++
                "interior({d},{d}) L={d:.4} a={d:.4} b={d:.4}\n",
            .{
                @tagName(expected.fit),
                edge.x,
                edge.y,
                edge.oklab[0],
                edge.oklab[1],
                edge.oklab[2],
                bottom.x,
                bottom.y,
                bottom.oklab[0],
                bottom.oklab[1],
                bottom.oklab[2],
                interior.x,
                interior.y,
                interior.oklab[0],
                interior.oklab[1],
                interior.oklab[2],
            },
        );
        const label = switch (expected.fit) {
            .contain => "the contain fit letterboxed above and below the image",
            .cover => "the cover fit cropped the sides and filled the height",
            .fill => "the fill fit stretched the image across the whole window",
            else => return error.UnprobedFit,
        };
        checks.expect("the fit arm read back its three probes", capture.captured);
        checks.expect(
            label,
            matchesAuthored(edge.oklab, expected.edge) and
                matchesAuthored(bottom.oklab, expected.bottom) and
                matchesAuthored(interior.oklab, expected.interior),
        );
    }
    checks.expect(
        "the three fits disagree at the same window point",
        pixelsDiffer(edges[0], edges[1]) and pixelsDiffer(edges[1], edges[2]) and
            pixelsDiffer(edges[0], edges[2]),
    );
}

// ── Fallback fills, in pixels ────────

/// The two non-ready source states as pixels. Each is mounted with a fill this
/// run authored, and the fill that reached the window is read back as Oklab: a
/// record shape proving the element emits a rect is not the claim, the colour
/// on the display is. The two states are then required to be DIFFERENT pixels,
/// because a fallback that renders as whatever the last one rendered is not a
/// second state.
fn runFallbackPixelArm(
    report: *Reporter,
    checks: *Checks,
    session: *Session,
    smoke: *Smoke,
    panel: anytype,
) !void {
    const states = [_]struct { state: Panel.SourceState, color: paint.Srgb, label: []const u8 }{
        .{ .state = .pending, .color = pending_fill_color, .label = "pending" },
        .{ .state = .failed, .color = failed_fill_color, .label = "failed" },
    };
    const centre = targetPixel(
        smoke,
        @floatFromInt(content_centre.x),
        @floatFromInt(content_centre.y),
    );

    var samples: [states.len]Sample = undefined;
    for (states, 0..) |entry, position| {
        try session.update(Panel, panel, entry.state, struct {
            fn mount(target: *Panel, value: Panel.SourceState) void {
                target.source_state = value;
                target.timeline = null;
                target.ready_slot = null;
                target.grayscale = .none;
                target.elapsed_ns = 0;
                target.anchor_ns = null;
                target.intrinsic = .{
                    .width = @floatFromInt(window_width),
                    .height = @floatFromInt(window_height),
                };
            }
        }.mount);
        var capture: Capture = .{};
        try capture.want(centre.x, centre.y);
        smoke.capture = &capture;
        _ = try driveFrames(smoke, 1);
        samples[position] = capture.at(0);
        const authored = fillToOklab(entry.color);
        const held = matchesAuthored(capture.at(0).oklab, authored);
        try report.emit("fallback {s}: texel=({d},{d}) L={d:.4} a={d:.4} b={d:.4} " ++
            "authored L={d:.4} a={d:.4} b={d:.4} {s}\n", .{
            entry.label,
            centre.x,
            centre.y,
            capture.at(0).oklab[0],
            capture.at(0).oklab[1],
            capture.at(0).oklab[2],
            authored[0],
            authored[1],
            authored[2],
            if (held) "ok" else "MISMATCH",
        });
        checks.expect("the fallback arm read back its probe", capture.captured);
        const claim = switch (entry.state) {
            .pending => "the pending state paints the authored pending fill",
            .failed => "the failed state paints the authored failed fill",
            else => return error.UnprobedFallback,
        };
        checks.expect(claim, held);
    }
    checks.expect(
        "the two fallback states are two different pixels",
        pixelsDiffer(samples[0].oklab, samples[1].oklab),
    );
}

// ── The W05 wake, on the real host ────────

/// One real host step per image deadline, with nothing forcing the frames.
///
/// A mounted non-looping image publishes its frame request into the WINDOW'S OWN
/// `FrameDemand` from inside the real frame callback. From then on this arm does
/// nothing but read that demand, sleep for the wait it reports and step the
/// host: no layout invalidation, no `requestPresentation`, no forced frame. So
/// every frame the host commits inside this arm is one it committed because the
/// image asked for it, and what the arm can report is real: the deadline the
/// element armed, the wait the host reported for it, the frames it woke for, the
/// colour each of those frames rendered, and the frames it stopped committing
/// once the image ended.
fn runHostAnimationArm(
    io: Io,
    report: *Reporter,
    checks: *Checks,
    session: *Session,
    application: *Application,
    smoke: *Smoke,
    panel: anytype,
    timeline: image_types.ImageSequence,
    generation: u64,
    requests: *image_types.FrameRequests,
) !void {
    var arm: AnimationArm = .{ .owner = host_frame_owner, .requests = requests };
    const anchor_ns = sdl3.timer.getNanosecondsSinceInit();
    const HostStart = struct {
        timeline: image_types.ImageSequence,
        generation: u64,
        anchor_ns: u64,
    };
    try session.update(Panel, panel, HostStart{
        .timeline = timeline,
        .generation = generation,
        .anchor_ns = anchor_ns,
    }, struct {
        fn start(target: *Panel, value: HostStart) void {
            target.source_state = .timeline;
            target.timeline = value.timeline;
            target.ready_slot = null;
            target.generation = value.generation;
            target.grayscale = .none;
            target.fit = .contain;
            target.intrinsic = .{
                .width = @floatFromInt(sequence_frame_side),
                .height = @floatFromInt(sequence_frame_side),
            };
            target.elapsed_ns = 0;
            // The element follows the real clock from here, so the frame it
            // paints is the frame its own wake reached rather than a reading
            // this arm wrote into the model.
            target.anchor_ns = value.anchor_ns;
        }
    }.start);

    // Armed before the first frame, so the frame the swap dirties is also the
    // frame that publishes the first request.
    smoke.animation = &arm;
    defer smoke.animation = null;
    defer smoke.capture = null;

    const managed = try application.getWindow(smoke.handle);
    const settle_deadline_ms = sdl3.timer.getMillisecondsSinceInit() + 10_000;
    const committed_before_settle = smoke.frames_committed;
    while (smoke.frames_committed == committed_before_settle) {
        if (sdl3.timer.getMillisecondsSinceInit() > settle_deadline_ms) return error.HostNeverSettled;
        if (!try application.step()) return error.HostStopped;
    }

    const armed_deadline_ms = managed.demand.deadline_ms;
    const armed_wait_ms = managed.demand.waitMilliseconds(sdl3.timer.getMillisecondsSinceInit());
    checks.expect(
        "the image armed the real window's frame demand",
        armed_deadline_ms != null and armed_wait_ms != null and armed_wait_ms.? > 0,
    );

    const end_ns = anchor_ns + host_total_ns;
    const budget_deadline_ms = sdl3.timer.getMillisecondsSinceInit() + 10_000;
    var captures: Capture = .{};
    var next_capture: Capture = .{};
    var elapsed_at_frame: [Capture.capacity]u64 = @splat(0);
    var committed: u32 = 0;
    var sleeps: u32 = 0;
    var waits: u32 = 0;
    var longest_wait_ms: u32 = 0;
    var premature_idle = false;
    const centre = targetPixel(
        smoke,
        @floatFromInt(content_centre.x),
        @floatFromInt(content_centre.y),
    );
    while (arm.last_deadline_ms != null) {
        if (sdl3.timer.getMillisecondsSinceInit() > budget_deadline_ms) {
            return error.HostAnimationBudgetExpired;
        }
        const now_ms = sdl3.timer.getMillisecondsSinceInit();
        const wait = managed.demand.waitMilliseconds(now_ms);
        if (wait == null) {
            // The host owes nothing while a whole frame boundary is still ahead,
            // so it went idle in the middle of the animation. The grace is one
            // frame duration because the last wake and the end of the image are
            // the same instant: a host that wakes on time and then re-arms to
            // nothing is idle by a millisecond, not by a frame.
            if (sdl3.timer.getNanosecondsSinceInit() + host_frame_durations_ns[0] < end_ns) {
                premature_idle = true;
            }
            try Io.sleep(io, Io.Duration.fromMilliseconds(2), .real);
        } else {
            waits += 1;
            longest_wait_ms = @max(longest_wait_ms, wait.?);
            if (wait.? != 0) {
                sleeps += 1;
                try Io.sleep(
                    io,
                    Io.Duration.fromMilliseconds(@min(@as(u64, wait.?), host_sleep_cap_ms)),
                    .real,
                );
            }
        }
        next_capture = .{};
        if (managed.demand.pending(sdl3.timer.getMillisecondsSinceInit())) {
            try next_capture.want(centre.x, centre.y);
            smoke.capture = &next_capture;
        }
        const committed_before = smoke.frames_committed;
        if (!try application.step()) return error.HostStopped;
        if (smoke.frames_committed == committed_before) continue;
        committed += 1;
        if (!next_capture.captured) continue;
        if (captures.requested >= Capture.capacity) return error.TooManyProbes;
        const index = captures.requested;
        captures.samples[index] = next_capture.at(0);
        captures.requested += 1;
        elapsed_at_frame[index] = smoke.frame_elapsed_ns;
    }

    // Once the image is over the host owes nothing, and stepping for a while
    // longer has to commit nothing at all.
    const idle_from = smoke.frames_committed;
    const idle_until_ms = sdl3.timer.getMillisecondsSinceInit() + host_idle_watch_ms;
    while (sdl3.timer.getMillisecondsSinceInit() < idle_until_ms) {
        try Io.sleep(io, Io.Duration.fromMilliseconds(2), .real);
        if (!try application.step()) return error.HostStopped;
    }
    const idle_committed = smoke.frames_committed - idle_from;
    const settled_ms = sdl3.timer.getMillisecondsSinceInit();
    const ended_deadline_ms = managed.demand.deadline_ms;
    const ended_pending = managed.demand.pending(settled_ms);
    const ended_wait_ms = managed.demand.waitMilliseconds(settled_ms);

    try report.emit(
        "hostanim: armed_deadline_ms={?d} armed_wait_ms={?d} published={d} " ++
            "last_published_deadline_ms={?d} waits={d} sleeps={d} longest_wait_ms={d} " ++
            "committed={d} premature_idle={} ended_deadline_ms={?d} ended_pending={} " ++
            "ended_wait_ms={?d} idle_committed={d}\n",
        .{
            armed_deadline_ms,
            armed_wait_ms,
            arm.published,
            arm.last_deadline_ms,
            waits,
            sleeps,
            longest_wait_ms,
            committed,
            premature_idle,
            ended_deadline_ms,
            ended_pending,
            ended_wait_ms,
            idle_committed,
        },
    );
    var rendered: u32 = 0;
    var changed: u32 = 0;
    for (0..captures.requested) |position| {
        const index: u32 = @intCast(position);
        const sample = captures.at(index);
        const expected_position = hostFrameIndex(elapsed_at_frame[index]);
        const color = host_frame_colors[expected_position];
        const authored = srgbToOklab(color[0], color[1], color[2]);
        const held = sample.found and matchesAuthored(sample.oklab, authored);
        if (held) rendered += 1;
        const same_as_first = captures.at(0).found and
            !pixelsDiffer(sample.oklab, captures.at(0).oklab);
        if (!same_as_first) changed += 1;
        try report.emit(
            "hostanim: frame {d} at t={d}ms rendered L={d:.4} a={d:.4} b={d:.4} " ++
                "authored[{d}] L={d:.4} a={d:.4} b={d:.4} {s}\n",
            .{
                index,
                elapsed_at_frame[index] / std.time.ns_per_ms,
                sample.oklab[0],
                sample.oklab[1],
                sample.oklab[2],
                expected_position,
                authored[0],
                authored[1],
                authored[2],
                if (held) "ok" else "MISMATCH",
            },
        );
    }

    checks.expect("the host slept to the image deadline", sleeps > 0 and waits >= sleeps);
    checks.expect(
        "the host kept a deadline until the image's last frame was reached",
        !premature_idle,
    );
    checks.expect(
        "every image deadline woke the host for exactly one frame",
        committed == host_frame_colors.len,
    );
    checks.expect("the host did not spin between deadlines", committed <= host_frame_colors.len + 1);
    checks.expect(
        "each woken frame rendered the colour its own deadline reached",
        captures.requested == host_frame_colors.len and rendered == captures.requested,
    );
    checks.expect("the rendered frame changed while the image played", changed >= 2);
    checks.expect(
        "the finished image leaves the host asleep",
        ended_deadline_ms == null and !ended_pending and ended_wait_ms == null and
            idle_committed == 0,
    );
}

/// One verdict line for both exit paths: `--no-window` reports the CPU arms it
/// ran and stops, the windowed run adds the GPU and pixel arms first.
fn verdict(report: *Reporter, checks: *const Checks, tail: []const u8) !void {
    try report.emit("verdict: passed={d} failed={d}\n", .{ checks.passed, checks.failed });
    if (checks.failed != 0) {
        try report.emit("W14 asset and animated image smoke FAILED\n", .{});
        return error.ExpectationsFailed;
    }
    try report.emit("W14 asset and animated image smoke done{s}\n", .{tail});
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var hold_ms: u64 = 0;
    var no_window = false;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--hold-ms")) {
            hold_ms = try std.fmt.parseInt(u64, args_it.next() orelse return error.MissingHoldMs, 10);
        } else if (std.mem.eql(u8, arg, "--no-window")) {
            // The asset, decode and frame-demand arms need no window and no
            // GPU, so this run never brings up SDL's video subsystem or Vulkan.
            no_window = true;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    var report: Reporter = .{ .io = io };
    var checks: Checks = .{ .report = &report };
    try report.emit("W14 asset and animated image smoke\n", .{});

    // ── The asset service ──────────────────────
    var manager = assets.AssetManager.init(gpa, io, .{
        .max_cache_bytes = 1 << 20,
        .file_root = repo_file_root,
    });
    defer manager.deinit();
    manager.setClock(1_000);

    try manager.embedded.register("badge.ppm", badge_ppm);
    // The specimen is authored in this file rather than read from disk, so the
    // asset manager serves it the same way it serves the badge: no ambient file
    // lookup and no network, only bytes this run already holds.
    try manager.embedded.register(specimen_key, specimen_svg_bytes);
    var loader: CountingLoader = .{};
    manager.app.register(&loader, CountingLoader.load);

    var status_buffer: [96]u8 = undefined;
    const embedded_status = manager.load(AssetKey.init(.embedded, "badge.ppm"));
    try report.emit("assets: embedded {s}\n", .{
        statusText(embedded_status, &status_buffer),
    });
    checks.expect("embedded source returns its registered bytes", isReady(embedded_status));
    checks.expect(
        "embedded bytes match the registered document",
        switch (embedded_status) {
            .ready => |bytes| std.mem.eql(u8, bytes, badge_ppm),
            .pending, .failed => false,
        },
    );

    const file_status = manager.load(AssetKey.init(.file, repo_file_key));
    try report.emit("assets: file {s} root={s} key={s}\n", .{
        statusText(file_status, &status_buffer),
        repo_file_root,
        repo_file_key,
    });
    checks.expect("file source reads a real file", isReady(file_status));
    checks.expect(
        "a key that escapes the root is refused",
        switch (manager.load(AssetKey.init(.file, "../v7_demo/ui.zig"))) {
            .failed => |failure| failure == error.AccessDenied,
            .pending, .ready => false,
        },
    );

    const dedup_key = AssetKey.init(.app, "logo");
    const first = manager.load(dedup_key);
    const second = manager.load(dedup_key);
    // Two buffers: one `statusText` call would overwrite what the other
    // returned, and the line would report the same status twice.
    var second_buffer: [96]u8 = undefined;
    try report.emit("assets: dedup loader_calls={d} first={s} second={s}\n", .{
        loader.calls,
        statusText(first, &status_buffer),
        statusText(second, &second_buffer),
    });
    checks.expect("two requests for one key run the loader once", loader.calls == 1);
    checks.expect(
        "both requesters read the same bytes",
        switch (first) {
            .ready => |a| switch (second) {
                .ready => |b| std.mem.eql(u8, a, b),
                .pending, .failed => false,
            },
            .pending, .failed => false,
        },
    );

    // The in-flight handle, driven by hand: `AssetManager.load` runs a load
    // to completion, so the pending state is only observable through the
    // tracker a caller drives itself.
    const pending_key = AssetKey.init(.embedded, "badge.ppm");
    const load_handle = switch (try manager.loads.acquire(pending_key)) {
        .start => |started| started,
        .join, .finished => return error.ExpectedFirstRequest,
    };
    const before = load_handle.status().state();
    const bytes = try manager.loadDirect(load_handle.key);
    const published = manager.loads.publish(load_handle, .{ .ok = bytes });
    const after = load_handle.status().state();
    try report.emit("assets: handle before={s} publish={s} after={s}\n", .{
        @tagName(before),
        @tagName(published),
        @tagName(after),
    });
    checks.expect("a started load reports pending", before == .pending);
    checks.expect("a published load reports ready", after == .ready);
    checks.expect("the publication was accepted", published == .accepted);
    manager.loads.releaseHandle(load_handle);

    // A budget that holds one entry: the second load must evict the first.
    var tight = assets.AssetManager.init(gpa, io, .{ .max_cache_bytes = tight_cache_bytes });
    defer tight.deinit();
    var first_body: [tight_entry_bytes]u8 = undefined;
    var second_body: [tight_entry_bytes]u8 = undefined;
    @memset(first_body[0..], 'A');
    @memset(second_body[0..], 'B');
    try tight.embedded.register("first.bin", &first_body);
    try tight.embedded.register("second.bin", &second_body);
    const first_key = AssetKey.init(.embedded, "first.bin");
    const second_key = AssetKey.init(.embedded, "second.bin");
    tight.setClock(10);
    _ = tight.load(first_key);
    tight.setClock(20);
    _ = tight.load(second_key);
    try report.emit("assets: eviction used={d} budget={d} first_cached={} second_cached={}\n", .{
        tight.cache.used(),
        tight_cache_bytes,
        tight.cache.peek(first_key, 20) != null,
        tight.cache.peek(second_key, 20) != null,
    });
    checks.expect(
        "the byte budget evicted the least recently used entry",
        tight.cache.peek(first_key, 20) == null,
    );
    checks.expect(
        "the newest entry survived the eviction",
        tight.cache.peek(second_key, 20) != null,
    );
    checks.expect("the cache stayed inside its budget", tight.cache.used() <= tight_cache_bytes);

    const version = manager.invalidate(dedup_key);
    loader.body = "second";
    const after_invalidate = manager.load(dedup_key);
    try report.emit("assets: invalidate version={d} loader_calls={d} body={s} cache_used={d}\n", .{
        version,
        loader.calls,
        statusText(after_invalidate, &status_buffer),
        manager.cache.used(),
    });
    checks.expect("invalidation bumps the key version", version == 1);
    checks.expect("an invalidated key is read from its source again", loader.calls == 2);
    checks.expect(
        "the re-read key serves the new content",
        switch (after_invalidate) {
            .ready => |body| std.mem.eql(u8, body, "second"),
            .pending, .failed => false,
        },
    );

    // The embedded bytes are a real image, and they stay in color: the
    // element's grayscale rides on the paint record, so nothing on this path
    // rewrites a pixel.
    var decoded = try image.decode(gpa, io, badge_ppm);
    defer decoded.deinit();
    try report.emit("decode: embedded {d}x{d} format={s} first_pixel=({d},{d},{d},{d})\n", .{
        decoded.width,
        decoded.height,
        @tagName(decoded.format),
        decoded.pixels[0],
        decoded.pixels[1],
        decoded.pixels[2],
        decoded.pixels[3],
    });
    checks.expect(
        "the embedded bytes decode to the authored document",
        decoded.width == 2 and decoded.height == 2 and decoded.format == .rgba8 and
            decoded.stride == 8 and decoded.pixels.len == 16,
    );
    checks.expect(
        "the decoded pixels keep their authored color",
        decoded.pixels[0] == 255 and decoded.pixels[1] == 0 and
            decoded.pixels[2] == 0 and decoded.pixels[3] == 255,
    );

    // ── The W05 frame demand ───────────────
    // A real published timeline driven through the real `FrameDemand`: an idle
    // host sleeps to the next frame boundary and stops asking for frames once
    // the image ends or its source is retired.
    try runDeadlineArm(gpa, io, &report, &checks);

    // ── The HTTP fixture ───────────────
    // Real bytes over a real loopback socket: an image that decodes and an SVG
    // that rasterizes, both served by this process rather than by a callback.
    try runHttpFixtureArm(gpa, io, &report, &checks, &manager);

    // ── The authored specimen ───────────────
    // The document this run authored, through the asset manager and through
    // librsvg, probed against its own authoring. It runs without a window
    // because rasterizing needs neither a compositor nor a device; the display
    // arm below mounts the very bytes it probed.
    // Mutable so the deferred release below owns the payload: `deinit` takes a
    // mutable pointer, and the display arm borrows these very pixels.
    var specimen = try runSpecimenArm(gpa, io, &report, &checks, &manager);
    defer if (specimen) |*raster| raster.deinit();

    if (no_window) {
        try report.emit("no-window: no SDL window, no Vulkan device, no pixels\n", .{});
        try verdict(&report, &checks, " without a window");
        return;
    }

    // ── The host, before the GPU ───────────────
    // `Application.init` is what brings SDL's video subsystem up, and the
    // Vulkan loader cannot be loaded before that: `sdl3.vulkan.loadLibrary`
    // against an uninitialized video subsystem fails outright.
    // The Session outlives the Application: `Application.deinit` unregisters
    // its task wake through the session, and the models are released while the
    // session is still alive. Both teardowns are `defer`, not `errdefer`, so
    // the ordinary tail and a failed arm retire the same objects exactly once
    // — a failing `verdict` is the ordinary end of this binary, and an
    // `errdefer` pair would free a second time after the tail already had.
    const session = try gpa.create(Session);
    var session_live = false;
    defer gpa.destroy(session);
    session.* = try Session.init(gpa);
    session_live = true;
    defer {
        if (session_live) {
            session.deinit() catch
                @panic("W14 asset smoke teardown left the Session with live models");
            report.emit("shutdown: session_deinit=ok\n", .{}) catch
                @panic("W14 asset smoke teardown could not report Session retirement");
        }
    }

    const application = try gpa.create(Application);
    // `Application.init` can fail before any defer below is registered, so the
    // raw allocation is covered by an `errdefer`; from the moment the
    // Application exists the two defers own it. The flag is what stops the
    // `errdefer` and the later defer from retiring the same object twice when
    // a later arm fails.
    var application_owned = true;
    errdefer if (application_owned) gpa.destroy(application);
    application.* = try Application.init(gpa, session, .{
        .app_id = "dev.nogui.w14asset",
        .restart = .never,
    });
    // The heap free is registered FIRST so it runs LAST: a defer runs in
    // reverse registration order, and `Application.deinit` still reads the
    // struct it lives in. Quitting first, so the host is asked to stop before
    // SDL is torn down; the device is already gone by then, because every
    // object created on it was released by a defer registered below this one.
    defer if (application_owned) {
        application_owned = false;
        gpa.destroy(application);
    };
    defer if (application_owned) {
        application.requestQuit() catch
            @panic("W14 asset smoke teardown could not ask the host to quit");
        application.deinit();
    };

    // ── GPU ────────────────────────────────
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    exts_storage = try gpa.dupe([*:0]const u8, sdl_exts);

    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "w14-asset-smoke",
        .validation = false,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
    });
    gpa.free(exts_storage);
    exts_storage = &.{};
    // The device is the LAST thing retired on this device path, and the defer
    // is what does it: every noapi object below is created after this `defer`
    // and therefore released before it, so no shader, texture, descriptor heap
    // or buffer is still alive when the device goes. It also runs before
    // `Application.deinit` quits SDL, because that defer is registered above:
    // quitting SDL unmaps the Vulkan loader, and a live VkDevice would then
    // dispatch through an unmapped page.
    defer gpu.deinit();

    var quad_vert_file = try ShaderFile.load(gpa, io, "shaders/quad_vert.spv");
    defer quad_vert_file.deinit(gpa);
    var quad_frag_file = try ShaderFile.load(gpa, io, "shaders/quad_frag.spv");
    defer quad_frag_file.deinit(gpa);
    var sort_comp_file = try ShaderFile.load(gpa, io, "shaders/sort_comp.spv");
    defer sort_comp_file.deinit(gpa);
    var fullscreen_vert_file = try ShaderFile.load(gpa, io, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert_file.deinit(gpa);
    var blit_oklab_file = try ShaderFile.load(gpa, io, "shaders/blit_oklab.spv");
    defer blit_oklab_file.deinit(gpa);

    var gui_renderer = try Renderer.init(
        &gpu,
        quad_vert_file.spv,
        quad_frag_file.spv,
        sort_comp_file.spv,
    );
    defer gui_renderer.deinit();
    gui_renderer.configure(.{});

    var bindless = try Bindless.init(gpa, &gpu);
    defer bindless.deinit();

    // ── The animated sequence ──────────────────
    // Each frame is a real texture: uploaded as Oklab floats and registered in
    // the bindless heap, so the timeline the element samples names a genuine
    // descriptor index rather than the registry's own bookkeeping slot.
    var frames: [sequence_frame_durations_ns.len]ProducerFrame = undefined;
    for (&frames, 0..) |*frame, position| {
        // Each frame's pixels are its authored color, so the render under any
        // sampler is that color and a frame switch is visible in the pixels.
        const color = sequence_frame_colors[position];
        frame.* = .{
            .pixels = gpa.alloc(u8, sequence_frame_rgba_bytes) catch return error.OutOfMemory,
            .duration_ns = sequence_frame_durations_ns[position],
        };
        var offset: usize = 0;
        while (offset < frame.pixels.len) : (offset += 4) {
            frame.pixels[offset + 0] = color[0];
            frame.pixels[offset + 1] = color[1];
            frame.pixels[offset + 2] = color[2];
            frame.pixels[offset + 3] = 255;
        }
    }
    defer for (&frames) |*frame| gpa.free(frame.pixels);

    var source = frame_source.FrameSource.init(gpa, io, frames.len);
    defer source.deinit() catch
        @panic("W14 asset smoke teardown still has borrowed frames");
    for (&frames) |*frame| try source.pushFrame(frame.descriptor());

    var textures = image.TextureRegistry.init(gpa, io);
    defer textures.deinit();
    var uploader: Uploader = .{
        .gpu = &gpu,
        .gpa = gpa,
        .bindless = &bindless,
        .textures = &textures,
    };
    defer uploader.deinit();
    var sequence = frame_source.AnimatedSequence.init(&source, &textures, .{
        .loop = true,
        // The mapper is required: without it the registry's own index would
        // be published, and sampling it would read whatever texture owns that
        // heap slot.
        .slot_mapper = Uploader.map,
        .mapper_context = &uploader,
    });
    var sequence_live = true;
    defer if (sequence_live) sequence.deinit();

    var submitted: u32 = 0;
    while (try sequence.submitNext()) {
        submitted += 1;
    }
    const timeline = sequence.timeline();
    const period_ns = timeline.totalDurationNs();
    var released: u32 = 0;
    for (&frames) |*frame| {
        if (frame.released) released += 1;
    }
    try report.emit(
        "sequence: queued={d} submitted={d} frames={d} period_ns={d} outstanding={d} released={d}\n",
        .{
            frames.len,
            submitted,
            timeline.frameCount(),
            period_ns,
            source.outstandingFrames(),
            released,
        },
    );
    try report.emit("sequence: heap slots {d} {d} {d} (registry slots are NOT these)\n", .{
        timeline.frames[0].slot.index,
        timeline.frames[1].slot.index,
        timeline.frames[2].slot.index,
    });
    checks.expect("every pushed frame reached the sequence", submitted == frames.len);
    checks.expect("the timeline carries every frame", timeline.frameCount() == frames.len);
    checks.expect(
        "the wrap period is the sum of the frame durations",
        period_ns == 120 * std.time.ns_per_ms,
    );
    checks.expect("every descriptor went back to its source", released == frames.len);
    checks.expect("the source accounts no outstanding frame", source.outstandingFrames() == 0);
    checks.expect("a sequence the element can sample", timeline.isValid());
    checks.expect(
        "every published slot is a live heap index",
        timeline.frames[0].slot.index < Bindless.capacity and
            timeline.frames[1].slot.index < Bindless.capacity and
            timeline.frames[2].slot.index < Bindless.capacity,
    );

    var sampled: [4]bool = .{ false, false, false, false };
    var sampled_texture: [4]u32 = .{ 0, 0, 0, 0 };
    const probes = [_]u64{ 0, 40 * std.time.ns_per_ms, 100 * std.time.ns_per_ms, period_ns };
    for (probes, 0..) |elapsed_ns, position| {
        const frame = timeline.frameAt(elapsed_ns) orelse continue;
        sampled[position] = true;
        sampled_texture[position] = frame.slot.index;
    }
    try report.emit("sequence: sampled t=0 -> slot {d}, t=40ms -> slot {d}, " ++
        "t=100ms -> slot {d}, t=period -> slot {d}; next_deadline_ns={?d}\n", .{
        sampled_texture[0],
        sampled_texture[1],
        sampled_texture[2],
        sampled_texture[3],
        timeline.nextDeadlineNs(0),
    });
    checks.expect(
        "every clock reading selected a frame",
        sampled[0] and sampled[1] and sampled[2] and sampled[3],
    );
    checks.expect(
        "a distinct duration selects a distinct frame",
        sampled_texture[0] != sampled_texture[1],
    );
    checks.expect(
        "a reading inside the last frame selects it",
        sampled_texture[2] != sampled_texture[0],
    );
    checks.expect("the period wraps to the first frame", sampled_texture[3] == sampled_texture[0]);
    checks.expect(
        "the next deadline is the first frame boundary",
        timeline.nextDeadlineNs(0) == sequence_frame_durations_ns[0],
    );

    const first_slot = timeline.frames[0].slot;
    checks.expect(
        "the element's generation is the heap's generation",
        first_slot.generation == bindless.generations[first_slot.index],
    );

    // ── The pin that survives slot reuse ───────
    // Retirement is requested directly, bypassing the sequence, so the only
    // thing holding the decoded pixels is the pin the sequence still owns.
    const first_handle = sequence.registryHandle(0);
    textures.evict(first_handle);
    var frame_number: u64 = 0;
    while (frame_number < 3) : (frame_number += 1) {
        textures.onFramePresented(frame_number);
    }
    const held = textures.get(first_handle) != null;
    try report.emit("pin: retired registry_slot={d} generation={d} alive_after_3_frames={}\n", .{
        first_handle.index,
        first_handle.generation,
        held,
    });
    checks.expect("a pinned slot keeps its pixels past its two-frame retirement", held);

    // ── The host-driven timeline ─────────────────
    // A second real sequence, non-looping and with its own frames, because the
    // W05 arm needs an END to stop the host: the looping timeline above never
    // has one. Its frames go through the same source, registry and uploader, so
    // the wake it drives ends at a bindless slot the element really samples.
    var host_frames: [host_frame_durations_ns.len]ProducerFrame = undefined;
    for (&host_frames, 0..) |*frame, position| {
        const color = host_frame_colors[position];
        frame.* = .{
            .pixels = gpa.alloc(u8, sequence_frame_rgba_bytes) catch return error.OutOfMemory,
            .duration_ns = host_frame_durations_ns[position],
        };
        var offset: usize = 0;
        while (offset < frame.pixels.len) : (offset += 4) {
            frame.pixels[offset + 0] = color[0];
            frame.pixels[offset + 1] = color[1];
            frame.pixels[offset + 2] = color[2];
            frame.pixels[offset + 3] = 255;
        }
    }
    defer for (&host_frames) |*frame| gpa.free(frame.pixels);

    var host_source = frame_source.FrameSource.init(gpa, io, host_frames.len);
    defer host_source.deinit() catch
        @panic("W14 asset smoke teardown still has borrowed host frames");
    for (&host_frames) |*frame| try host_source.pushFrame(frame.descriptor());

    var host_sequence = frame_source.AnimatedSequence.init(&host_source, &textures, .{
        .loop = false,
        .slot_mapper = Uploader.map,
        .mapper_context = &uploader,
    });
    // No live flag: nothing here releases the sequence early, so it outlives
    // every borrowed timeline an arm below reads and is released last.
    defer host_sequence.deinit();
    while (try host_sequence.submitNext()) {}
    const host_timeline = host_sequence.timeline();
    if (!host_timeline.isValid()) return error.InvalidHostTimeline;
    const host_slot = host_timeline.frames[0].slot;
    var host_requests = image_types.FrameRequests.init(gpa, host_frame_owner.owner);
    defer host_requests.deinit();
    try report.emit(
        "host timeline: frames={d} period_ns={d} loop={} slots {d} {d} {d}\n",
        .{
            host_timeline.frameCount(),
            host_total_ns,
            host_timeline.loop,
            host_timeline.frames[0].slot.index,
            host_timeline.frames[1].slot.index,
            host_timeline.frames[2].slot.index,
        },
    );
    checks.expect(
        "the host timeline reaches every frame",
        host_timeline.frameCount() == host_frames.len,
    );
    checks.expect("the host timeline does not loop", !host_timeline.loop);
    checks.expect("the host source accounts no outstanding frame", host_source.outstandingFrames() == 0);

    var initial: Panel = .{
        .timeline = timeline,
        .generation = first_slot.generation,
        .grayscale = .none,
        .elapsed_ns = 0,
    };
    var panel = try session.create(Panel, &initial);
    // The model is released after the App has unmounted the root that holds
    // it and before the Session itself is torn down; the two defers that
    // bracket this one are registered later and earlier respectively, so both
    // paths reach that order.
    var panel_live = true;
    defer {
        if (panel_live) {
            session.release(Panel, &panel) catch
                @panic("W14 asset smoke teardown could not release the model");
        }
    }

    var endpoint: nogui.GpuEndpoint = .{ .gpu = &gpu };

    // The view is allocated before the App so a failed `App.init` cannot leak
    // a root the App never owned, and it is freed only after `app.deinit`,
    // which still holds the pointer to it.
    const view = try gpa.create(PanelView);
    defer gpa.destroy(view);
    view.* = .{};

    var app = try gpa.create(App);
    var app_allocated = true;
    errdefer if (app_allocated) gpa.destroy(app);
    app.* = try App.init(gpa, session);
    // `app_mounted` is what the tail clears when it retires the App itself, and
    // `app_allocated` is what keeps the `errdefer` and this `defer` from both
    // freeing the same App: this defer runs first, clears the flag, and the
    // `errdefer` then has nothing left to do.
    var app_mounted = true;
    defer {
        if (app_allocated) {
            // The App has to let go of the device and unmount its root before
            // the model and the Session are released, before the view it points
            // at is freed, and before the device itself is torn down.
            if (app_mounted) {
                app.detachGpu();
                app.deinit();
            }
            app_allocated = false;
            gpa.destroy(app);
        }
    }
    try app.mountModelRoot(Panel, PanelView, panel, view);
    try app.attachGpu(&endpoint);

    const title: [:0]const u8 = "w14-asset-smoke";
    const handle = try application.openWindowWithApp(app, .{
        .title = title,
        .width = window_width,
        .height = window_height,
        .resizable = false,
        .visible = true,
        .gpu_surface = true,
    });
    const managed = try application.getWindow(handle);
    // noapi creates the platform surface from the window and owns it from
    // that call on, on the success path and on the failure path alike. This
    // file therefore holds no SDL wrapper to destroy, frees no platform
    // surface itself and never sees a Vulkan handle.
    var surface = try noapi.Surface.initSdl(
        &gpu,
        @ptrCast(managed.native.sdl.value),
        @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
        .{ .extent = try deviceExtent(managed) },
    );
    // The noapi Surface borrows the Gpu, so its teardown has to be skipped
    // once the device is gone, and skipped again when the explicit shutdown
    // already released it. This is a `defer`, not an `errdefer`: the ordinary
    // tail releases it too, and one flag is the only thing that keeps the two
    // paths from releasing the same surface twice.
    var surface_live = true;
    defer if (surface_live) surface.deinit();
    // The Surface references this SDL window. Retire it before either close
    // path destroys the platform window; the device stays live until all
    // device-side resources have been released, and before Application quits.
    var window_open = true;
    defer if (window_open) {
        if (surface_live) {
            surface.deinit();
            surface_live = false;
        }
        _ = application.closeWindow(handle) catch
            @panic("W14 asset smoke teardown could not close the window");
        _ = application.step() catch
            @panic("W14 asset smoke teardown could not step the host");
    };

    const oklab_extent = try deviceExtent(managed);
    // The armed capture copies this target back, so it is also a transfer
    // SOURCE: `copyFromTexture` is what reads the rendered Oklab out of it,
    // and a copy whose source lacks the usage bit is a Vulkan violation, not
    // a warning.
    const oklab_target = try gpu.textureCreate(.{
        .dimensions = .{ oklab_extent.width, oklab_extent.height, 1 },
        .format = .rgba32_float,
        .usage = .{
            .sampled = true,
            .color_attachment = true,
            .transfer_src = true,
        },
    });
    defer gpu.textureDestroy(oklab_target);

    const blit_vert = try gpu.shaderCreate(fullscreen_vert_file.spv, .vertex, "main", "w14_blit_vert");
    defer gpu.shaderDestroy(blit_vert);
    const blit_frag = try gpu.shaderCreate(blit_oklab_file.spv, .fragment, "main", "w14_blit_frag");
    defer gpu.shaderDestroy(blit_frag);
    const blit_heap = try gpu.descHeapCreate(1, 0, 1);
    defer gpu.descHeapDestroy(blit_heap);
    const blit_sampler = gpu.samplerDescriptor(.{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mip_filter = .nearest,
    });
    gpu.descHeapSetTextures(
        blit_heap,
        0,
        &.{gpu.textureViewDescriptor(oklab_target, .{})},
    );
    gpu.descHeapSetSamplers(blit_heap, 0, &.{blit_sampler});

    const material_buffer = try gpu.gpuMalloc(256, 64, .default);
    defer gpu.gpuFree(material_buffer);
    const readback_bytes: u64 = @as(u64, oklab_extent.width) * oklab_extent.height * 4 * @sizeOf(f32);
    const readback = try gpu.gpuMalloc(readback_bytes, 64, .readback);
    defer gpu.gpuFree(readback);

    var smoke: Smoke = .{
        .io = io,
        .gpu = &gpu,
        .application = application,
        .app = app,
        .handle = handle,
        .surface = surface,
        .endpoint = &endpoint,
        .gui_renderer = &gui_renderer,
        .gui_heap = bindless.heap,
        .oklab_target = oklab_target,
        .oklab_extent = oklab_extent,
        .blit_vert = blit_vert,
        .blit_frag = blit_frag,
        .blit_heap = blit_heap,
        .material_buffer = material_buffer,
        .readback = readback,
        .root = view,
    };
    application.setHooks(.{
        .context = &smoke,
        .on_frame = Smoke.onFrame,
        .on_quit_request = Smoke.onQuitRequest,
    });
    try application.start();

    const settled = try pumpUntil(
        &smoke,
        sdl3.timer.getMillisecondsSinceInit() + 10_000,
        framesSettled,
    );
    try report.emit("window: title=\"{s}\" observed={d}x{d} target={d}x{d} video_driver={s} " ++
        "settled={} committed={d} presented={d} view_draws={d}\n", .{
        title,
        managed.observed.size.width,
        managed.observed.size.height,
        oklab_extent.width,
        oklab_extent.height,
        sdl3.video.getCurrentDriverName() orelse "<null>",
        settled,
        smoke.frames_committed,
        smoke.frames_presented,
        view.drawn,
    });
    checks.expect("a frame committed in the real window", smoke.frames_committed >= 1);
    checks.expect("the mounted root drew", view.drawn >= 1);

    // Every probe address below is stated in window content coordinates and was
    // authored against this window size, so a compositor that gave the window a
    // different one fails here by name instead of quietly probing other texels.
    checks.expect(
        "the observed window is the size the probes were authored for",
        managed.observed.size.width == window_width and
            managed.observed.size.height == window_height,
    );

    // ── The element's own output ───────────────
    const live = try probeView(gpa, .{
        .intrinsic = .{
            .width = @floatFromInt(sequence_frame_side),
            .height = @floatFromInt(sequence_frame_side),
        },
        .source = .{ .animating = timeline },
        .generation = first_slot.generation,
        .grayscale = .none,
        .elapsed_ns = 0,
        .label = image_label,
    });
    const advanced_probe = try probeView(gpa, .{
        .intrinsic = .{
            .width = @floatFromInt(sequence_frame_side),
            .height = @floatFromInt(sequence_frame_side),
        },
        .source = .{ .animating = timeline },
        .generation = first_slot.generation,
        .grayscale = .full,
        .elapsed_ns = 50 * std.time.ns_per_ms,
        .label = image_label,
    });
    const stale = try probeView(gpa, .{
        .intrinsic = .{
            .width = @floatFromInt(sequence_frame_side),
            .height = @floatFromInt(sequence_frame_side),
        },
        .source = .{ .animating = timeline },
        .generation = first_slot.generation + 1,
        .grayscale = .none,
        .elapsed_ns = 0,
        .label = image_label,
    });
    try report.emit("element: live images={d} slot={?d} gray={?d} advanced images={d} " ++
        "slot={?d} gray={?d} stale images={d} rects={d}\n", .{
        live.images,
        live.texture_index,
        live.grayscale,
        advanced_probe.images,
        advanced_probe.texture_index,
        advanced_probe.grayscale,
        stale.images,
        stale.rects,
    });
    checks.expect("a live sequence emits one image record", live.images == 1 and live.rects == 0);
    checks.expect(
        "the element samples the heap slot the timeline names",
        live.texture_index == first_slot.index,
    );
    checks.expect(
        "the element forwards the authored grayscale amount",
        live.grayscale == null or live.grayscale.? == 0.0,
    );
    checks.expect(
        "a full grayscale amount reaches the paint record",
        advanced_probe.grayscale != null and advanced_probe.grayscale.? == 1.0,
    );
    checks.expect(
        "a later clock reading moves the element to the next frame",
        advanced_probe.images == 1 and advanced_probe.texture_index != live.texture_index,
    );
    checks.expect(
        "a stale generation paints the pending fill instead of a slot",
        stale.images == 0 and stale.rects == 1,
    );

    // ── Rendered pixels ────────────────────────
    // Three arms through the real renderer, each read back from the offscreen
    // Oklab target: the authored color, the same frame with a full grayscale
    // amount, and a later clock reading that must show the next frame.
    const centre_texel = targetPixel(
        &smoke,
        @floatFromInt(content_centre.x),
        @floatFromInt(content_centre.y),
    );
    var color_arm: Capture = .{};
    try color_arm.want(centre_texel.x, centre_texel.y);
    smoke.capture = &color_arm;
    _ = try driveFrames(&smoke, 1);

    try session.update(Panel, panel, {}, struct {
        fn toGray(target: *Panel, _: void) void {
            target.grayscale = .full;
        }
    }.toGray);
    var gray_arm: Capture = .{};
    try gray_arm.want(centre_texel.x, centre_texel.y);
    smoke.capture = &gray_arm;
    _ = try driveFrames(&smoke, 1);

    try session.update(Panel, panel, {}, struct {
        fn toNextFrame(target: *Panel, _: void) void {
            target.grayscale = .none;
            target.elapsed_ns = 50 * std.time.ns_per_ms;
        }
    }.toNextFrame);
    var next_frame_arm: Capture = .{};
    try next_frame_arm.want(centre_texel.x, centre_texel.y);
    smoke.capture = &next_frame_arm;
    _ = try driveFrames(&smoke, 1);

    try report.emit(
        "pixels: color L={d:.4} a={d:.4} b={d:.4} | gray L={d:.4} a={d:.4} b={d:.4} | " ++
            "next-frame L={d:.4} a={d:.4} b={d:.4}\n",
        .{
            color_arm.at(0).oklab[0],
            color_arm.at(0).oklab[1],
            color_arm.at(0).oklab[2],
            gray_arm.at(0).oklab[0],
            gray_arm.at(0).oklab[1],
            gray_arm.at(0).oklab[2],
            next_frame_arm.at(0).oklab[0],
            next_frame_arm.at(0).oklab[1],
            next_frame_arm.at(0).oklab[2],
        },
    );
    const authored = srgbToOklab(
        sequence_frame_colors[0][0],
        sequence_frame_colors[0][1],
        sequence_frame_colors[0][2],
    );
    const authored_next = srgbToOklab(
        sequence_frame_colors[1][0],
        sequence_frame_colors[1][1],
        sequence_frame_colors[1][2],
    );
    try report.emit("pixels: authored frame0 L={d:.4} a={d:.4} b={d:.4}; frame1 L={d:.4} a={d:.4} b={d:.4}\n", .{
        authored[0],
        authored[1],
        authored[2],
        authored_next[0],
        authored_next[1],
        authored_next[2],
    });

    checks.expect(
        "all three arms were read back",
        color_arm.captured and gray_arm.captured and next_frame_arm.captured,
    );
    checks.expect(
        "the rendered pixel is the authored frame's color",
        matchesAuthored(color_arm.at(0).oklab, authored),
    );
    checks.expect(
        "the authored frame renders with real chroma",
        chroma(color_arm.at(0).oklab) > 0.05,
    );
    checks.expect(
        "a full grayscale amount removes the chroma",
        chroma(gray_arm.at(0).oklab) < 0.01,
    );
    checks.expect(
        "grayscale keeps the Oklab lightness the frame had",
        @abs(gray_arm.at(0).oklab[0] - color_arm.at(0).oklab[0]) < authored_pixel_tolerance,
    );
    checks.expect(
        "a later clock reading rendered the next frame's color",
        matchesAuthored(next_frame_arm.at(0).oklab, authored_next),
    );

    // ── The W05 wake on the real host ───────────
    // The mounted image arms the window's own frame demand from inside the real
    // frame callback, and this loop only sleeps for the wait that demand
    // reports and steps the host. Nothing here forces a frame.
    try runHostAnimationArm(
        io,
        &report,
        &checks,
        session,
        application,
        &smoke,
        panel,
        host_timeline,
        host_slot.generation,
        &host_requests,
    );

    // ── The fallback fills in pixels ────────────
    try runFallbackPixelArm(&report, &checks, session, &smoke, panel);

    // ── Object fit in pixels ────────────
    // One authored image, decoded by the real decoder and uploaded through the
    // real bindless path, mounted once per fit.
    var fit_buffer: [fit_image_bytes]u8 = undefined;
    writeFitImage(&fit_buffer);
    var fit_decoded = try image.decode(gpa, io, fit_buffer[0..]);
    defer fit_decoded.deinit();
    checks.expect(
        "the authored fit image decodes at its own size",
        fit_decoded.width == @as(u32, @intCast(fit_image_width)) and
            fit_decoded.height == @as(u32, @intCast(fit_image_height)) and
            fit_decoded.format == .rgba8,
    );
    const fit_upload: DecodedUpload = .{ .image = &fit_decoded };
    const fit_texture = try createOklabTexture(&gpu, .{
        .width = @intCast(fit_image_width),
        .height = @intCast(fit_image_height),
    }, &fit_upload);
    // Registered, not owned: the heap destroys every texture it was handed, so
    // destroying this one here would free the same handle twice at teardown.
    const fit_slot = try bindless.register(fit_texture);
    try runFitPixelArm(&report, &checks, session, &smoke, panel, fit_slot);

    // ── The specimen on the display ────────────
    // The very raster the CPU arm probed, uploaded and mounted, so what the
    // window shows is what was checked. It goes last, so a held window shows
    // the document rather than a flat fill.
    if (specimen) |*raster| {
        const specimen_upload: DecodedUpload = .{ .image = raster };
        const specimen_texture = try createOklabTexture(&gpu, .{
            .width = raster.width,
            .height = raster.height,
        }, &specimen_upload);
        // Registered, not owned, for the same reason as the fit texture.
        const specimen_slot = try bindless.register(specimen_texture);
        try runSpecimenPixelArm(&report, &checks, session, &smoke, panel, specimen_slot);
    } else {
        try report.emit("window specimen: not mounted, the rasterizer was unavailable\n", .{});
    }

    if (hold_ms > 0) {
        try report.emit("HOLD-BEGIN {d}ms\n", .{hold_ms});
        const until = sdl3.timer.getMillisecondsSinceInit() + hold_ms;
        while (sdl3.timer.getMillisecondsSinceInit() < until) {
            const live_window = try application.getWindow(handle);
            live_window.requestPresentation();
            _ = try application.step();
            try Io.sleep(io, Io.Duration.fromMilliseconds(8), .real);
        }
        try report.emit("HOLD-END presented={d} view_draws={d}\n", .{
            smoke.frames_presented,
            view.drawn,
        });
    }

    // ── Releasing the sequence ─────────────────
    // `timeline` BORROWS the sequence's own scratch, and `deinit` poisons it,
    // so the frames this run still needs are copied out first. Holding the
    // borrowed view across the release would read a poisoned struct.
    var copied_frames: [sequence_frame_durations_ns.len]image_types.ImageFrame = undefined;
    for (timeline.frames, 0..) |entry, position| copied_frames[position] = entry;
    const copied_timeline: image_types.ImageSequence = .{
        .frames = &copied_frames,
        .loop = timeline.loop,
    };
    sequence.deinit();
    sequence_live = false;
    frame_number = 4;
    textures.onFramePresented(frame_number);
    const recycled = textures.get(first_handle);
    const recycled_generation = first_slot.generation + 1;
    const after_release = try probeView(gpa, .{
        .intrinsic = .{
            .width = @floatFromInt(sequence_frame_side),
            .height = @floatFromInt(sequence_frame_side),
        },
        .source = .{ .animating = copied_timeline },
        .generation = recycled_generation,
        .grayscale = .none,
        .elapsed_ns = 0,
        .label = image_label,
    });
    try report.emit("release: registry_slot_live={} recycled_generation={d} element_images={d} " ++
        "element_rects={d}\n", .{
        recycled != null,
        recycled_generation,
        after_release.images,
        after_release.rects,
    });
    checks.expect("an unpinned retired slot is freed and its generation bumped", recycled == null);
    checks.expect(
        "a freed slot is not handed to another image as the old frame",
        after_release.rects >= 1,
    );

    // The heap side of the same rule: releasing the descriptor and reusing
    // the heap index must move its generation, so the element refuses the old
    // timeline instead of sampling whatever took the slot.
    const released_texture = uploader.textureFor(first_handle) orelse
        return error.MissingUploadedTexture;
    const released_slot = bindless.slotOf(released_texture) orelse
        return error.MissingHeapSlot;
    const generation_before = released_slot.generation;
    bindless.unregister(released_texture);
    // Read the heap's own generation, not `slotOf`: a released texture is
    // gone from the map by definition, so asking the map can only report
    // "absent" and would hide the generation the element must reject.
    const generation_after = bindless.generations[released_slot.index];
    const after_recycle = try probeView(gpa, .{
        .intrinsic = .{
            .width = @floatFromInt(sequence_frame_side),
            .height = @floatFromInt(sequence_frame_side),
        },
        .source = .{ .ready = first_slot },
        // The owner reads the heap's CURRENT generation, the way it would
        // after the release, while the slot it still holds names the old
        // one. That mismatch is the whole contract: the element must refuse
        // the pair rather than sample a descriptor the heap has freed.
        .generation = generation_after,
        .grayscale = .none,
        .elapsed_ns = 0,
        .label = image_label,
    });
    try report.emit("recycle: heap_generation {d} -> {d} element_images={d} element_rects={d}\n", .{
        generation_before,
        generation_after,
        after_recycle.images,
        after_recycle.rects,
    });
    checks.expect("releasing a heap slot bumps its generation", generation_after == generation_before + 1);
    checks.expect(
        "a released heap slot is not sampled as the old image",
        after_recycle.images == 0 and after_recycle.rects == 1,
    );

    // ── Shutdown ───────────────────────────────
    // The Surface retires before its platform window. The App then unmounts
    // before the model is released. Remaining device resources and the GPU
    // retire through their defers before Application quits SDL; Session
    // retires last, after Application unregisters its task-wake callback.
    surface.deinit();
    surface_live = false;
    try report.emit("retire: surface_before_window=true\n", .{});
    const closed = try application.closeWindow(handle);
    window_open = false;
    _ = try application.step();
    try report.emit("close: released={} window_count={d} host_running={}\n", .{
        closed,
        application.window_count,
        application.isRunning(),
    });

    app.detachGpu();
    app.deinit();
    app_mounted = false;
    try session.release(Panel, &panel);
    panel_live = false;
    try report.emit(
        "shutdown: app_unmounted=true frames_presented={d} view_draws={d}; Session retirement follows Application\n",
        .{ smoke.frames_presented, view.drawn },
    );

    try verdict(&report, &checks, "");
}
