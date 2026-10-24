//! W16 paint-band smoke — the consumer-visible half of the overlay contract,
//! measured on a real GPU readback of a real `App` frame.
//!
//! ONE specimen, eleven cases, one device. Every case publishes a frame through
//! `buildFrameScene` → `recordFrameScene` → `Offscreen.submitRead` — and every
//! claim is a PIXEL read out of that readback, a routing answer out of the
//! committed tree, or the layer the painter emitted. There is no second
//! painter, no private raster, no raw Vulkan handle and no window: the default
//! surface is `v7_frame.Offscreen`, so the run needs a GPU and nothing else.
//!
//! The contract under test is ONE `(priority, registration)` key. It decides
//! the band `overlay.Frame.finalizePaintOrder` assigns, the
//! `widget.effectiveLayer` every painter emits, the hit test and the App's own
//! routing. The cases are the ways that key can be wrong:
//!
//!   A  different priorities, the LOW one built and registered first
//!   B  the same priorities with the HIGH one built and registered first
//!      — A and B differ only in build/registration order and the same popup
//!        wins in both, so neither order is a paint lever
//!   C  equal priorities: the LATER registration wins
//!   D  the winning popup's own background, caption, checked checkbox + mark,
//!      slider + thumb, button icon and custom canvas, each visible above that
//!      popup's own fill, and the popup above the ordinary base
//!   E  a refused registration, a refused stage and a refused band
//!      finalization leave the committed routing, metadata and pixels exactly
//!      as they were, and the next real frame is byte-identical
//!   F  the authored local layer order INSIDE one band survives, in BOTH
//!      emission orders
//!   G  a custom layer bump that cannot hold its band is a typed failure and
//!      nothing is published
//!   H  an unplaced custom record with a high bump still paints below a placed
//!      popup, because the band starts above the application's own maximum
//!   I  a nested higher-priority popup registered FIRST keeps its band when a
//!      lower-priority ancestor is registered later around it
//!   J  a REGISTERED record whose content is built, filled and visible while
//!      nothing places it: it paints nothing, routes nothing and carries no
//!      band; a frame with a visible anchor places it above the ordinary
//!      control it covers, and the next frame with a hidden anchor excludes
//!      it again
//!
//! The App owns the ordering; this file only measures it. Every probe window is
//! derived from the committed tree's own boxes at run time, so a probe cannot
//! describe geometry the frame did not produce, and every colour is compared in
//! Oklab through the frame module's own converter.
//!
//! Run it: `zig build w16-paint-smoke -- [--case NAME] [--ppm-dir DIR]
//! [--prefix NAME]`. With no `--case` every case runs in the order above. PPM
//! output is off by default; with `--ppm-dir` one P6 file per case is written
//! as `<dir>/<prefix>-<case>.ppm`.

const std = @import("std");
const Io = std.Io;

const noapi = @import("noapi");
const nogui = @import("nogui");
const render = @import("v7_render");
const frame_mod = @import("v7_frame");

const App = nogui.App;
const Session = nogui.Session;
const WidgetId = nogui.WidgetId;
const FrameNodeId = nogui.FrameNodeId;
const widget = nogui.widget;
const overlay = nogui.overlay;
const paint = nogui.paint;

/// Logical window units. The device extent is identical, so one logical unit is
/// exactly one device pixel and every authored box lands on the pixel grid.
const window_w: f32 = 480;
const window_h: f32 = 320;
const device_extent: noapi.Extent2D = .{ .width = 480, .height = 320 };

/// The anchor's row, the ordinary panel behind everything, and the anchor
/// itself. Every popup in this specimen is placed BELOW that anchor with a fixed
/// gap, so two same-size popups land on the same rect and any interior pixel is
/// covered by both.
const anchor_w: f32 = 100;
const anchor_h: f32 = 24;
const anchor_gap: f32 = 4;
const base_w: f32 = 480;
const base_h: f32 = 140;

const popup_w: f32 = 150;
const popup_h: f32 = 100;
/// Case I's ancestor is wider because a nested popup has to fit inside it.
const ancestor_w: f32 = 200;
const ancestor_h: f32 = 120;
const nested_w: f32 = 90;
const nested_h: f32 = 60;

// ── authored colours (sRGB on the authored side of the authored/scene split) ──

/// The frame's background, authored directly in scene space so it reproduces
/// the Oklab clear EXACTLY and every "nothing painted here" probe has one known
/// value. A background authored in sRGB would compile to a different Oklab
/// value, so this is a compile-time failure rather than a runtime check.
const clear_fill: paint.Fill = .{ .solid = .{ .oklab = .{
    .l = frame_mod.scene.oklab_clear[0],
    .a = frame_mod.scene.oklab_clear[1],
    .b = frame_mod.scene.oklab_clear[2],
    .alpha = frame_mod.scene.oklab_clear[3],
} } };

const base_fill: [4]f32 = .{ 0.18, 0.24, 0.38, 1 };
const anchor_fill: [4]f32 = .{ 0.24, 0.26, 0.32, 1 };
const anchor_text: [4]f32 = .{ 0.88, 0.90, 0.94, 1 };

/// The two competing popups. Far apart in Oklab, so a pixel that matches one
/// can never be counted as the other, and neither is near the clear.
const low_fill: [4]f32 = .{ 0.42, 0.12, 0.14, 1 };
const high_fill: [4]f32 = .{ 0.12, 0.40, 0.24, 1 };

/// Case D's own foregrounds. Each is a colour no other element in the specimen
/// authors, so "this feature painted" is never satisfied by a neighbour.
const caption_fill: [4]f32 = .{ 0.30, 0.32, 0.40, 1 };
const caption_text: [4]f32 = .{ 0.95, 0.93, 0.72, 1 };
const check_fill: [4]f32 = .{ 0.10, 0.55, 0.25, 1 };
const slide_fill: [4]f32 = .{ 0.55, 0.20, 0.45, 1 };
const icon_fill: [4]f32 = .{ 0.20, 0.62, 0.72, 1 };
const canvas_fill: [4]f32 = .{ 0.72, 0.46, 0.10, 1 };
const bump_fill: [4]f32 = .{ 0.55, 0.55, 0.60, 1 };

/// Case J's own colours. The dismissed popup, the ordinary panel it covers
/// and that panel's own button are three colours no other element in this
/// specimen authors, and none of them is near the clear, so "this painted"
/// and "this did not" can never be satisfied by a neighbour.
const dormant_fill: [4]f32 = .{ 0.62, 0.16, 0.62, 1 };
const dormant_button_fill: [4]f32 = .{ 0.90, 0.55, 0.75, 1 };
const dormant_button_text: [4]f32 = .{ 0.08, 0.08, 0.10, 1 };
const dormant_canvas_fill: [4]f32 = .{ 0.36, 0.18, 0.86, 1 };
const under_fill: [4]f32 = .{ 0.10, 0.14, 0.20, 1 };
const under_button_fill: [4]f32 = .{ 0.85, 0.35, 0.10, 1 };
const under_button_text: [4]f32 = .{ 0.95, 0.95, 0.95, 1 };

/// Case F's two interior fills, at two AUTHORED local layers. Both cases emit
/// them in opposite orders, and the higher layer wins in both, so a painter
/// that ordered them by emission would pass one case and fail the other.
const interior_low: [4]f32 = .{ 0.80, 0.72, 0.20, 1 };
const interior_high: [4]f32 = .{ 0.20, 0.20, 0.80, 1 };
const interior_low_layer: u32 = 0;
const interior_high_layer: u32 = 5;

/// The slider's thumb is a fixed colour in the scene module, so the specimen
/// names it here once instead of hard-coding it at a second probe.
const thumb_fill: [4]f32 = .{ 0.82, 0.82, 0.85, 1 };

/// Case D's checkbox mark is the contrast colour the scene module derives from
/// the control's own colour, so the specimen derives it the same way from the
/// same authored colour rather than pinning the result.
fn markFill() [4]f32 {
    const luminance = 0.2126 * check_fill[0] + 0.7152 * check_fill[1] + 0.0722 * check_fill[2];
    return if (luminance > 0.55) .{ 0.12, 0.13, 0.15, 1 } else .{ 0.96, 0.96, 0.98, 1 };
}

/// How close an Oklab channel may be before a readback counts as a match. A
/// hard-edged rect over an opaque background blends exactly, and every probe
/// window is inset past its edges, so this sits far away from a coverage
/// boundary: a window of ±0.004 either side of the authored value contains the
/// whole exact blend and nothing that is even a tenth covered.
const match_tolerance: f32 = 0.004;
/// Logical units a probe window is inset by, so no rounded corner, border or
/// antialiased edge is ever read as a fill.
const probe_inset: f32 = 2;
/// The unpainted control window every foreground is also required to be ABSENT
/// from, in the ordinary panel well clear of any popup.
const control_window: widget.Rect = .{ .x = 320, .y = 40, .w = 60, .h = 60 };

/// The icon's quad is 16 logical units wide and the raster is 16x16, so the
/// middle window is sampled at full coverage and the corner at none. Both are
/// whole-texel windows of a hard-edged disc, so neither is an antialiased one.
const icon_middle: widget.Rect = .{ .x = 4, .y = 4, .w = 8, .h = 8 };
const icon_corner: widget.Rect = .{ .x = 0, .y = 0, .w = 6, .h = 6 };

// ── SPIR-V the GUI pass records with ──────────────────

const default_quad_vert = "shaders/quad_vert.spv";
const default_quad_frag = "shaders/quad_frag.spv";
const default_sort_comp = "shaders/sort_comp.spv";

const ShaderFile = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !ShaderFile {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

// ── the cases ──────────────────

const Case = enum {
    /// Different priorities, the LOW one built and registered first.
    a_priority_low_first,
    /// The same priorities with the HIGH one built and registered first.
    b_priority_high_first,
    /// Equal priorities: the LATER registration wins.
    c_equal_later_wins,
    /// The winning popup's own generated content, above its own fill.
    d_winning_content,
    /// A refused registration, a refused stage, a refused finalization.
    e_refusal_retains,
    /// The authored interior order, the high layer EMITTED first.
    f_interior_high_first,
    /// The same two fills with the high layer emitted last.
    f_interior_low_first,
    /// A custom bump that cannot hold its band.
    g_bump_overflow,
    /// An unplaced high custom bump below a placed popup.
    h_unplaced_bump,
    /// A nested higher-priority popup registered before a lower ancestor.
    i_nested_first,
    /// A registered record whose visible content nothing places.
    j_dormant_overlay,

    const names = [_][]const u8{
        "a-priority-low-first",
        "b-priority-high-first",
        "c-equal-later-wins",
        "d-winning-content",
        "e-refusal-retains",
        "f-interior-high-first",
        "f-interior-low-first",
        "g-bump-overflow",
        "h-unplaced-bump",
        "i-nested-first",
        "j-dormant-overlay",
    };

    fn parse(text: []const u8) ?Case {
        for (names, 0..) |name, index| {
            if (std.mem.eql(u8, name, text)) return @fromBackingInt(@intCast(index));
        }
        return null;
    }
};

/// The two priorities A and B share. The key is the same in both; only the
/// order the records were built and registered in differs.
const low_priority: u31 = 2;
const high_priority: u31 = 7;
const equal_priority: u31 = 4;
/// Case I's ancestor is LOWER than the nested popup registered inside it.
const ancestor_priority: u31 = 2;
const nested_priority: u31 = 9;
/// The layer the unplaced custom record in case H bumps to. Every band starts
/// above this, which is the whole claim.
const bump_layer: u32 = 40;
const icon_logical_size: f32 = 16;

/// Case J's geometry. The record's content and the ordinary control it covers
/// are both the ordinary panel's own content box, and the record's own
/// control is a band across the top of that same box, so every probe below
/// reads a box the committed tree published.
const dormant_control_w: f32 = 200;
const dormant_control_h: f32 = 40;
/// The custom record's own height, and the bare gap between the record's own
/// control and the record above it.
const dormant_record_h: f32 = 20;
/// The one priority case J's record carries. Nothing competes with it, so the
/// value is only here to be a real one.
const dormant_priority: u31 = 6;
/// The width of the strip along a control's own edge a focus ring is read
/// in, and the distance from the corners the strip starts at, so a rounded
/// ring is a straight band across the whole strip.
const ring_strip_w: f32 = 6;
const ring_strip_inset: f32 = 8;

/// The shared anchor's own visibility, named so the option field carries a
/// resolved enum instead of a literal whose type the call site must infer.
const anchor_visible_visibility: nogui.style.Visibility = .visible;
const anchor_hidden_visibility: nogui.style.Visibility = .hidden;

// ── reporting ──────────────────

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// A printed value that is not checked is not evidence, so every claim is
/// counted and a single failure ends the run.
const Checks = struct {
    report: *Reporter,
    passed: u32 = 0,
    failed: u32 = 0,

    fn claim(self: *Checks, label: []const u8, holds: bool) !void {
        if (holds) self.passed += 1 else self.failed += 1;
        try self.report.emit("{s} {s}\n", .{
            if (holds) "  ok  " else "  FAIL",
            label,
        });
    }

    /// A measurement read off the image, held to a window. The observed value is
    /// printed so a reader can see how far a census actually landed.
    fn count(
        self: *Checks,
        label: []const u8,
        observed: usize,
        low: usize,
        high: usize,
    ) !void {
        const holds = observed >= low and observed <= high;
        if (holds) self.passed += 1 else self.failed += 1;
        try self.report.emit("{s} {s}: {d} px (want {d}..{d})\n", .{
            if (holds) "  ok  " else "  FAIL",
            label,
            observed,
            low,
            high,
        });
    }
};

// ── pixel access ──────────────────

/// The readback, addressed the way the specimen is authored: logical units that
/// are device pixels one for one. Nothing here allocates.
const Image = struct {
    pixels: []const f32,
    extent: noapi.Extent2D,

    const Bounds = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

    fn at(self: Image, x: u32, y: u32) [4]f32 {
        const row = @as(usize, y) * @as(usize, self.extent.width);
        const base = (row + @as(usize, x)) * 4;
        return .{
            self.pixels[base],
            self.pixels[base + 1],
            self.pixels[base + 2],
            self.pixels[base + 3],
        };
    }

    /// Euclidean distance in Oklab over L, a and b. Alpha is not compared: the
    /// specimen's fills are opaque and so is the pass underneath them.
    fn distance(self: Image, x: u32, y: u32, want: [4]f32) f32 {
        const got = self.at(x, y);
        const dl = got[0] - want[0];
        const da = got[1] - want[1];
        const db = got[2] - want[2];
        return @sqrt(dl * dl + da * da + db * db);
    }

    /// The device-pixel window one logical rect probes, inset so no edge is ever
    /// read as a fill. It is the SAME window for every colour a census counts,
    /// so the counts are comparable.
    fn bounds(self: Image, rect: widget.Rect) Bounds {
        const empty: Bounds = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
        if (rect.w <= probe_inset * 2 or rect.h <= probe_inset * 2) return empty;
        const left = @max(0.0, rect.x + probe_inset);
        const top = @max(0.0, rect.y + probe_inset);
        const right = @min(
            @as(f32, @floatFromInt(self.extent.width)),
            rect.x + rect.w - probe_inset,
        );
        const bottom = @min(
            @as(f32, @floatFromInt(self.extent.height)),
            rect.y + rect.h - probe_inset,
        );
        if (right <= left or bottom <= top) return empty;
        return .{
            .x0 = @intFromFloat(@floor(left)),
            .y0 = @intFromFloat(@floor(top)),
            .x1 = @min(self.extent.width, @as(u32, @intFromFloat(@ceil(right)))),
            .y1 = @min(self.extent.height, @as(u32, @intFromFloat(@ceil(bottom)))),
        };
    }

    fn total(self: Image, rect: widget.Rect) usize {
        const window = self.bounds(rect);
        return @as(usize, window.x1 - window.x0) * @as(usize, window.y1 - window.y0);
    }

    /// How many of a rect's probed device pixels carry `srgb`. The authored
    /// colour goes through the frame module's own converter, so a probe can
    /// never agree with a drifted conversion of its own making.
    fn countColor(self: Image, rect: widget.Rect, srgb: [4]f32) usize {
        const want = frame_mod.srgbToOklab(srgb);
        const window = self.bounds(rect);
        var matches: usize = 0;
        var y = window.y0;
        while (y < window.y1) : (y += 1) {
            var x = window.x0;
            while (x < window.x1) : (x += 1) {
                if (self.distance(x, y, want) <= match_tolerance) matches += 1;
            }
        }
        return matches;
    }

    /// How many probed pixels are NEITHER of two colours. This is the caption
    /// oracle: inside a caption's own box the only things that can be are the
    /// button's fill, the popup's fill and glyph ink, so "not either fill" is
    /// ink by elimination — a behavioural claim about the caption, not a claim
    /// about which glyphs a font happened to produce.
    fn countNeither(self: Image, rect: widget.Rect, first: [4]f32, second: [4]f32) usize {
        const a = frame_mod.srgbToOklab(first);
        const b = frame_mod.srgbToOklab(second);
        const window = self.bounds(rect);
        var matches: usize = 0;
        var y = window.y0;
        while (y < window.y1) : (y += 1) {
            var x = window.x0;
            while (x < window.x1) : (x += 1) {
                if (self.distance(x, y, a) > match_tolerance and
                    self.distance(x, y, b) > match_tolerance) matches += 1;
            }
        }
        return matches;
    }

    /// How many of a window's pixels are NEITHER of two colours, read whole.
    /// The shared probe inset steps around a control's own edges, and a ring
    /// IS a control's own edge, so stepping around it would hide the one
    /// thing this census is for. The caller authors the window.
    fn countNeitherEdge(self: Image, rect: widget.Rect, first: [4]f32, second: [4]f32) usize {
        const a = frame_mod.srgbToOklab(first);
        const b = frame_mod.srgbToOklab(second);
        const x0: u32 = @intFromFloat(@floor(@max(0.0, rect.x)));
        const y0: u32 = @intFromFloat(@floor(@max(0.0, rect.y)));
        const x1 = @min(self.extent.width, @as(u32, @intFromFloat(@ceil(rect.x + rect.w))));
        const y1 = @min(self.extent.height, @as(u32, @intFromFloat(@ceil(rect.y + rect.h))));
        var matches: usize = 0;
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                if (self.distance(x, y, a) > match_tolerance and
                    self.distance(x, y, b) > match_tolerance) matches += 1;
            }
        }
        return matches;
    }
};

/// A rect expressed inside a placed box, resolved against that box's own placed
/// geometry. Probes are authored in local units so a probe cannot name a pixel
/// the placement never produced.
fn inside(host: widget.Rect, local: widget.Rect) widget.Rect {
    return .{ .x = host.x + local.x, .y = host.y + local.y, .w = local.w, .h = local.h };
}

/// The intersection of two rects, or null when they do not overlap.
fn overlap(a: widget.Rect, b: widget.Rect) ?widget.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= x or bottom <= y) return null;
    return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
}

/// Whether a node is the root or descends from it, read through the tree's own
/// parent chain.
fn descendsFrom(tree: *const widget.WidgetTree, child: FrameNodeId, root: FrameNodeId) bool {
    var current = child;
    var remaining = tree.nodes.items.len;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        if (current == root) return true;
        current = (tree.nodeConst(current) orelse return false).parent;
    }
    return false;
}

// ── the icon asset ──────────────────

/// The one icon this specimen paints: a 16x16 coverage disc, uploaded as the
/// pipeline's float4 and registered in the GUI bindless heap. It is a REAL asset
/// with a real heap index — `prepare` cannot report it missing and there is no
/// second shape to fall back to, so a button that shows no icon is a failed
/// claim rather than a silently absent feature.
///
/// The raster is a white coverage mask in the pipeline's colour space, which is
/// the identity element in Oklab, so the scene rect's button colour tints the
/// sample and the disc's middle reads as exactly that colour. The disc's edge is
/// a whole-texel step, so no probe window straddles a coverage boundary.
const icon_edge: u32 = 16;
const icon_radius: f32 = 5;

const IconSet = struct {
    index: u32,

    fn prepare(gpa: std.mem.Allocator, gpu: *noapi.Gpu, heap: *frame_mod.BindlessHeap) !IconSet {
        const texture = try gpu.textureCreate(.{
            .dimensions = .{ icon_edge, icon_edge, 1 },
            .format = .rgba32_float,
            .usage = .{ .sampled = true },
        });
        // The heap owns a registered texture and destroys it in its own deinit,
        // so this file never frees the handle itself.
        errdefer gpu.textureDestroy(texture);
        const bytes: u64 = @as(u64, icon_edge) * icon_edge * 4 * @sizeOf(f32);
        const staging = try gpu.gpuMalloc(bytes, 64, .default);
        defer gpu.gpuFree(staging);
        const out: [*]f32 = @ptrCast(@alignCast(staging.cpu));
        const centre = @as(f32, @floatFromInt(icon_edge)) / 2;
        var y: u32 = 0;
        while (y < icon_edge) : (y += 1) {
            var x: u32 = 0;
            while (x < icon_edge) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - centre;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - centre;
                const covered = @sqrt(dx * dx + dy * dy) <= icon_radius;
                const base = (@as(usize, y) * icon_edge + x) * 4;
                out[base + 0] = 1;
                out[base + 1] = 1;
                out[base + 2] = 1;
                out[base + 3] = if (covered) 1 else 0;
            }
        }
        var command = try gpu.commandsBegin();
        var pending = true;
        errdefer if (pending) {
            gpu.commandsCancel(&command) catch @panic("icon upload cancellation failed");
        };
        command.copyToTexture(.{
            .gpu = gpu,
            .handle = texture,
            .dimensions = .{ icon_edge, icon_edge, 1 },
            .format = .rgba32_float,
        }, staging, .{ .size = .{ icon_edge, icon_edge, 1 } });
        try gpu.queueSubmit(&.{command});
        pending = false;
        try gpu.waitIdle();
        return .{ .index = try heap.register(gpa, texture) };
    }

    fn source(self: *IconSet) frame_mod.scene.IconSource {
        return .{ .ctx = @ptrCast(self), .prepare = prepareSource, .index = sourceIndex };
    }

    fn prepareSource(raw: *anyopaque) bool {
        const self: *const IconSet = @ptrCast(@alignCast(raw));
        // The raster was uploaded and registered before the first frame, so the
        // set is live for the whole run. There is no path on which this icon is
        // legitimately missing, and no fallback to reach instead.
        return self.index != frame_mod.scene.no_texture;
    }

    fn sourceIndex(raw: *anyopaque, icon: widget.IconId) u32 {
        const self: *const IconSet = @ptrCast(@alignCast(raw));
        return switch (icon) {
            .heart => self.index,
            // Every other id is a DIFFERENT asset this specimen does not carry.
            // "No texture" is the truthful answer for those, never this one.
            else => frame_mod.scene.no_texture,
        };
    }
};

// ── the custom element ──────────────────

/// What the one custom element paints. Every mode is a set of records, each
/// with its own AUTHORED layer, which is the only lever this element has:
/// nothing here knows about overlays, bands or scene sorting.
const CanvasMode = enum {
    /// Two records over the same bounds, the high authored layer emitted first.
    interior_high_first,
    /// The same two records with the high authored layer emitted last.
    interior_low_first,
    /// One record in the ordinary base at a layer no popup band can start below.
    high_bump,
    /// One record whose bump cannot be added to anything.
    overflow,
    /// One record filling the element, at the popup's OWN authored layer. The
    /// collector emits a container before its descendants and the sort is
    /// stable on (layer, order), so a record at the same authored layer as the
    /// popup's fill is still painted above it.
    popup_canvas,
    /// One record filling the element at the very bump every band starts
    /// above, so a control nothing ever places still asks for a layer it must
    /// not be given.
    dormant_bump,
};

const Writer = nogui.element.PaintWriter;

/// One authored record, with its own authored layer. `local` is in the
/// element's own CONTENT-LOCAL units: `PaintWriter` places every record
/// against the final prepaint content origin, so a record that carried that
/// box's WINDOW origin would be translated twice and would paint outside the
/// element the probe reads. This is the same call the canonical draw-command
/// collector reads back, so the layer a probe measures is the layer the
/// painter emitted.
fn record(
    canvas: *Writer,
    local: widget.Rect,
    srgb: [4]f32,
    layer: u32,
) nogui.element.Error!void {
    try canvas.addRect(.{
        .bounds = .{ .x = local.x, .y = local.y, .w = local.w, .h = local.h },
        .fill = .{ .solid = .{ .srgb = .{ .r = srgb[0], .g = srgb[1], .b = srgb[2] } } },
        .layer = layer,
    });
}

const Canvas = struct {
    mode: CanvasMode,

    pub const PhaseState = struct {
        content: widget.Rect = .{},
        prepainted: bool = false,
    };

    pub fn measure(_: *const Canvas, input: nogui.element.MeasureInput) nogui.element.Error!widget.Size {
        return .{
            .width = input.known_dimensions.width orelse 0,
            .height = input.known_dimensions.height orelse 0,
        };
    }

    pub fn prepaint(
        _: *const Canvas,
        state: *PhaseState,
        geometry: nogui.element.Geometry,
    ) nogui.element.Error!void {
        state.content = geometry.content;
        state.prepainted = true;
    }

    pub fn paint(
        payload: *const Canvas,
        state: *PhaseState,
        geometry: nogui.element.Geometry,
        canvas: *Writer,
    ) nogui.element.Error!void {
        // A canvas paints against the FINAL prepaint box. A mismatch here would
        // silently move every probe that reads this element.
        if (!state.prepainted or !std.meta.eql(state.content, geometry.content)) {
            return error.PhaseReentry;
        }
        const content = geometry.content;
        if (content.w <= 0 or content.h <= 0) return;
        // The geometry box is the WINDOW box the collector places records
        // against, so every rect here starts at the content origin and is
        // sized by it: the painted rect is exactly the content box the
        // committed tree reports.
        const full: widget.Rect = .{ .x = 0, .y = 0, .w = content.w, .h = content.h };
        switch (payload.mode) {
            .interior_high_first => {
                try record(canvas, full, interior_high, interior_high_layer);
                try record(canvas, full, interior_low, interior_low_layer);
            },
            .interior_low_first => {
                try record(canvas, full, interior_low, interior_low_layer);
                try record(canvas, full, interior_high, interior_high_layer);
            },
            .high_bump => try record(canvas, full, bump_fill, bump_layer),
            .overflow => try record(canvas, full, bump_fill, std.math.maxInt(u32)),
            .popup_canvas => try record(canvas, full, canvas_fill, 0),
            .dormant_bump => try record(canvas, full, dormant_canvas_fill, bump_layer),
        }
    }
};

// ── the specimen ──────────────────

const key_anchor = "w16-anchor";
const key_base = "w16-base";
const key_low = "w16-low";
const key_high = "w16-high";
const key_caption = "w16-caption";
const key_check = "w16-check";
const key_slider = "w16-slider";
const key_icon = "w16-icon";
const key_canvas = "w16-canvas";
const key_bump = "w16-bump";
const key_ancestor = "w16-ancestor";
const key_nested_anchor = "w16-nested-anchor";
const key_nested = "w16-nested";
const key_under = "w16-under";
const key_under_button = "w16-under-button";
const key_dormant = "w16-dormant";
const key_dormant_button = "w16-dormant-button";
const key_dormant_canvas = "w16-dormant-canvas";

fn keyOf(name: []const u8) nogui.ComponentKey {
    return .{ .static = name };
}

/// The model the interactive controls are bound to. It is caller-owned state
/// that outlives both committed trees, which is what those controls require.
const Model = struct {
    check: bool = true,
    slide: f32 = 0.7,
};

/// Which extra scene the frame under test publishes. `refuse_record` and
/// `overflow_bump` are the two scenes the refusing cases draw. The two
/// `anchor_*` scenes belong to case J alone and change nothing but the shared
/// anchor: the same content, the same record, the same geometry.
const Scene = enum { normal, refuse_record, overflow_bump, anchor_hidden, anchor_absent };

/// The mounted root. It owns the overlay frame the App resolves and the model
/// the controls read; it is the whole consumer, and the App publishes whatever
/// it draws.
pub const View = struct {
    /// Non-owning back pointer, set before `mountRoot`. The view needs the App's
    /// committed tree to name a keyed widget; the App needs the view to draw.
    app: *App,
    frame: overlay.Frame,
    scene: Scene = .normal,
    case: Case = .a_priority_low_first,
    model: Model = .{},
    /// The shared anchor's stable handle, kept across the frame that builds
    /// no anchor. A consumer whose anchor disappears still registers its
    /// record; excluding the content is the frame's job, not the consumer's.
    anchor_handle: ?WidgetId = null,
    /// Real clicks that reached the ordinary control's own handler.
    under_clicks: u32 = 0,
    /// Real clicks that reached the record's own control.
    dormant_clicks: u32 = 0,
    /// Target-phase presses the App's own routing delivered, and the node the
    /// last one of them named.
    routed_presses: u32 = 0,
    routed_target: ?FrameNodeId = null,

    pub fn init(gpa: std.mem.Allocator, app: *App) View {
        return .{ .app = app, .frame = overlay.Frame.init(gpa) };
    }

    pub fn release(self: *View) void {
        self.frame.deinit();
    }

    /// The stable handle a keyed widget published in the committed tree.
    fn widget(self: *const View, name: []const u8) ?WidgetId {
        return self.app.widgetIdForKey(.root, keyOf(name));
    }

    /// Whether this frame builds the shared anchor at all. Case J's
    /// `anchor_absent` scene does not, and registers the record against the
    /// handle an earlier frame captured.
    fn drawsAnchor(self: *const View) bool {
        return self.case != .j_dormant_overlay or self.scene != .anchor_absent;
    }

    /// Whether this frame builds the shared anchor hidden. A hidden node keeps
    /// its layout box, so every other box in the frame is exactly where it was
    /// in the visible frame and only the record's ability to resolve changed.
    fn anchorHidden(self: *const View) bool {
        return self.case == .j_dormant_overlay and self.scene == .anchor_hidden;
    }

    /// A real click that reached the ordinary control's own handler.
    pub fn onUnderClick(self: *View, _: usize) void {
        self.under_clicks += 1;
    }

    /// A real click that reached the record's own control.
    pub fn onDormantClick(self: *View, _: usize) void {
        self.dormant_clicks += 1;
    }

    /// The App's own routing, counted as it arrives: one record per press
    /// that named a node, never one per node the walk touched. Routing is the
    /// claim; activation is only its consequence.
    pub fn onRoutedEvent(self: *View, context: *nogui.event.DispatchContext) void {
        if (context.phase != .target) return;
        if (context.current_target != context.target) return;
        switch (context.event.*) {
            .mouse_down => {
                self.routed_presses += 1;
                self.routed_target = context.current_target;
            },
            else => {},
        }
    }

    /// Publish `case` with `scene`. The build and registration order of the two
    /// competing popups is what the case selects; the geometry is identical in
    /// every case, so no case can win by being laid out differently.
    pub fn draw(self: *View, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.column(.{
            .width = window_w,
            .height = window_h,
            .fill = clear_fill,
            .gap = 0,
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .@"align" = .start,
            .justify = .start,
            .grow = 0,
            .shrink = 0,
        });
        defer ctx.pop();

        // The row only carries the anchor, which paints its own `anchor_fill`.
        // The surface behind the row is the root column's own `clear_fill`, so
        // the row inherits it rather than owning a background of its own. An
        // unset fill would repaint the whole band in the framework's
        // `palette.container`, a colour this specimen never authors, so the
        // band around the anchor would not be the clear the root painted.
        _ = try ctx.row(.{
            .height = anchor_h,
            .gap = 0,
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .@"align" = .start,
            .grow = 0,
            .shrink = 0,
            .transparent = true,
        });
        // The shared anchor. Case J's record names this very button, and only
        // the scene decides whether the record can resolve: built and visible,
        // built and hidden, or not built at all this frame.
        const anchor = if (self.drawsAnchor()) try ctx.button(.{
            .key = keyOf(key_anchor),
            .label = "anchor",
            .width = anchor_w,
            .height = anchor_h,
            .fill = anchor_fill,
            .color = anchor_text,
            .visibility = if (self.anchorHidden())
                anchor_hidden_visibility
            else
                anchor_visible_visibility,
        }) else null;
        ctx.pop();
        // The handle the record names. A frame that built the anchor captures
        // its own handle here; a frame that built no anchor at all registers
        // the handle an earlier frame captured, which is exactly what a
        // consumer whose anchor left the tree still does.
        var captured: ?WidgetId = self.anchor_handle;
        if (anchor) |node| captured = ctx.widgetIdOf(node);
        const anchor_id = captured orelse return error.MissingAnchor;
        self.anchor_handle = captured;

        // Case J's content is a child of this panel, so the panel's own
        // content box is the box every probe in that case reads, and the
        // record itself is registered after the panel closes like every other
        // record in this specimen.
        var dormant_content: ?WidgetId = null;

        // The ordinary panel the popups cover. Case H's unplaced custom record
        // lives in here, in the flow, with no band of its own.
        _ = try ctx.column(.{
            .key = keyOf(key_base),
            .width = base_w,
            .height = base_h,
            .fill = base_fill,
            .gap = 0,
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .@"align" = .start,
            .grow = 0,
            .shrink = 0,
        });
        if (self.case == .h_unplaced_bump) {
            _ = try ctx.elementLeaf(Canvas, .{ .mode = .high_bump }, .{
                .key = keyOf(key_bump),
                .position = .absolute,
                .inset = .{ .top = 40, .right = 0, .bottom = 0, .left = 0 },
                .width = 160,
                .height = 90,
                .box_sizing = .border_box,
                .grow = 0,
                .shrink = 0,
            });
        }
        if (self.case == .j_dormant_overlay) {
            dormant_content = try self.buildDormantContent(ctx);
        }
        ctx.pop();

        switch (self.case) {
            .a_priority_low_first, .h_unplaced_bump => try self.buildPair(
                ctx,
                anchor_id,
                .{ key_low, key_high },
                .{ low_priority, high_priority },
            ),
            .b_priority_high_first => try self.buildPair(
                ctx,
                anchor_id,
                .{ key_high, key_low },
                .{ high_priority, low_priority },
            ),
            .c_equal_later_wins => try self.buildPair(
                ctx,
                anchor_id,
                .{ key_high, key_low },
                .{ equal_priority, equal_priority },
            ),
            .d_winning_content => try self.buildRich(ctx, anchor_id),
            .e_refusal_retains => switch (self.scene) {
                .normal => try self.buildPair(
                    ctx,
                    anchor_id,
                    .{ key_low, key_high },
                    .{ low_priority, high_priority },
                ),
                .refuse_record => try self.buildRefused(ctx, anchor_id),
                .overflow_bump => try self.buildOverflow(ctx, anchor_id),
                // The two case J scenes are the only ones this case never
                // publishes, so reaching one here is a bug in the case, not
                // a state this draw has to answer for.
                .anchor_hidden, .anchor_absent => unreachable,
            },
            .f_interior_high_first => try self.buildInterior(ctx, anchor_id, .interior_high_first),
            .f_interior_low_first => try self.buildInterior(ctx, anchor_id, .interior_low_first),
            .g_bump_overflow => try self.buildOverflow(ctx, anchor_id),
            .i_nested_first => try self.buildNested(ctx, anchor_id),
            .j_dormant_overlay => try self.registerDormant(
                ctx,
                anchor_id,
                dormant_content orelse return error.MissingContent,
            ),
        }
    }

    /// A childless popup container. The rect given here is its laid-out SIZE
    /// only: placement moves it, and every probe reads the moved box. A popup
    /// with no children is what makes "every probed pixel is this fill" a
    /// statement about the popup instead of about its contents.
    fn beginPopup(ctx: *nogui.DrawCtx, name: []const u8, fill: [4]f32, w: f32, h: f32) !FrameNodeId {
        return ctx.column(.{
            .key = keyOf(name),
            .position = .absolute,
            .width = w,
            .height = h,
            .fill = fill,
            .gap = 0,
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .@"align" = .start,
            .grow = 0,
            .shrink = 0,
        });
    }

    fn register(
        ctx: *nogui.DrawCtx,
        anchor: WidgetId,
        content: FrameNodeId,
        priority: u31,
    ) !void {
        try ctx.place(.{
            .anchor = anchor,
            .content = ctx.widgetIdOf(content) orelse return error.MissingContent,
            .side = .below,
            .gap = anchor_gap,
            .clip = .window_escape,
            .priority = priority,
        });
    }

    /// Build and register two same-size popups, in the order the case names.
    fn buildPair(
        _: *View,
        ctx: *nogui.DrawCtx,
        anchor: WidgetId,
        names: [2][]const u8,
        priorities: [2]u31,
    ) !void {
        for (names, priorities) |name, priority| {
            const fill: [4]f32 = if (std.mem.eql(u8, name, key_low)) low_fill else high_fill;
            const content = try beginPopup(ctx, name, fill, popup_w, popup_h);
            ctx.pop();
            try register(ctx, anchor, content, priority);
        }
    }

    /// The winning popup with every generated foreground this specimen can
    /// paint: its own fill, a caption, a checked checkbox and its mark, a slider
    /// with a thumb, an icon button, and one custom canvas record. The rows are
    /// laid out so a strip of bare popup fill survives at the bottom.
    fn buildRich(self: *View, ctx: *nogui.DrawCtx, anchor: WidgetId) !void {
        const content = try beginPopup(ctx, key_high, high_fill, popup_w, popup_h);
        _ = try ctx.button(.{
            .key = keyOf(key_caption),
            .label = "caption",
            .width = 120,
            .height = 18,
            .fill = caption_fill,
            .color = caption_text,
        });
        _ = try ctx.checkbox(.{
            .key = keyOf(key_check),
            .label = "check",
            .value = &self.model.check,
            .color = check_fill,
            .width = 120,
            .height = 20,
        });
        _ = try ctx.slider(.{
            .key = keyOf(key_slider),
            .label = "slide",
            .value = &self.model.slide,
            .min = 0,
            .max = 1,
            .color = slide_fill,
            .width = 120,
            .height = 16,
        });
        // The icon button's own chrome is authored as ABSENT on purpose, so the
        // raster's uncovered corner shows whatever is behind the quad. A
        // zero-alpha fill would NOT do it: an unset fill resolves to the
        // control's default background, which is a colour this specimen does
        // not own. Transparency is the authored way to paint no background.
        _ = try ctx.button(.{
            .key = keyOf(key_icon),
            .label = "",
            .icon = .heart,
            .width = 24,
            .height = 24,
            .transparent = true,
            .color = icon_fill,
        });
        _ = try ctx.elementLeaf(Canvas, .{ .mode = .popup_canvas }, .{
            .key = keyOf(key_canvas),
            .position = .absolute,
            .inset = .{ .top = 78, .right = 0, .bottom = 0, .left = 4 },
            .width = 40,
            .height = 10,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
        });
        ctx.pop();
        try register(ctx, anchor, content, high_priority);
    }

    /// One popup whose interior is a custom canvas, so the two authored local
    /// layers are the only thing deciding which fill is on top.
    fn buildInterior(
        _: *View,
        ctx: *nogui.DrawCtx,
        anchor: WidgetId,
        mode: CanvasMode,
    ) !void {
        const content = try beginPopup(ctx, key_high, high_fill, popup_w, popup_h);
        _ = try ctx.elementLeaf(Canvas, .{ .mode = mode }, .{
            .key = keyOf(key_canvas),
            .position = .absolute,
            .inset = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .width = popup_w,
            .height = popup_h,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
        });
        ctx.pop();
        try register(ctx, anchor, content, high_priority);
    }

    /// A popup carrying the custom record whose layer bump cannot hold a band.
    /// The record is the LAST thing the frame draws, so nothing about the
    /// refusal depends on where in the frame it was authored.
    fn buildOverflow(
        _: *View,
        ctx: *nogui.DrawCtx,
        anchor: WidgetId,
    ) !void {
        const content = try beginPopup(ctx, key_high, high_fill, popup_w, popup_h);
        _ = try ctx.elementLeaf(Canvas, .{ .mode = .overflow }, .{
            .key = keyOf(key_canvas),
            .position = .absolute,
            .inset = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .width = popup_w,
            .height = popup_h,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
        });
        ctx.pop();
        try register(ctx, anchor, content, high_priority);
    }

    /// A popup that registers a record the frame refuses by name. The FIRST
    /// record is valid, so what is refused is the second one and not a scene
    /// that never got as far as placing anything.
    fn buildRefused(
        _: *View,
        ctx: *nogui.DrawCtx,
        anchor: WidgetId,
    ) !void {
        const content = try beginPopup(ctx, key_low, low_fill, popup_w, popup_h);
        ctx.pop();
        try register(ctx, anchor, content, low_priority);
        const refused = try beginPopup(ctx, key_high, high_fill, popup_w, popup_h);
        ctx.pop();
        try ctx.place(.{
            .anchor = anchor,
            .content = ctx.widgetIdOf(refused) orelse return error.MissingContent,
            .side = .below,
            .gap = anchor_gap,
            .clip = .window_escape,
            .priority = high_priority,
            .margin = std.math.nan(f32),
        });
    }

    /// An ancestor popup with a nested popup inside its own subtree. The nested
    /// record is registered FIRST and carries the HIGHER priority; the ancestor
    /// is registered afterwards, around it, at the lower one.
    fn buildNested(_: *View, ctx: *nogui.DrawCtx, anchor: WidgetId) !void {
        const ancestor = try beginPopup(ctx, key_ancestor, low_fill, ancestor_w, ancestor_h);
        // The nested popup's anchor. It only has to be a button the placement
        // can name, so it owns no background of its own: the surface behind it
        // is the ancestor popup's own `low_fill`. An unset fill resolves to the
        // framework's `palette.button`, which would paint a blue block over the
        // ancestor's own surface inside the region case I reads.
        const nested_anchor = try ctx.button(.{
            .key = keyOf(key_nested_anchor),
            .label = "na",
            .position = .absolute,
            .inset = .{ .top = 8, .right = 0, .bottom = 0, .left = 8 },
            .width = 80,
            .height = 20,
            .transparent = true,
        });
        const nested = try beginPopup(ctx, key_nested, high_fill, nested_w, nested_h);
        ctx.pop();
        ctx.pop();
        try ctx.place(.{
            .anchor = ctx.widgetIdOf(nested_anchor) orelse return error.MissingAnchor,
            .content = ctx.widgetIdOf(nested) orelse return error.MissingContent,
            .side = .right,
            .gap = 2,
            .clip = .window_escape,
            .priority = nested_priority,
        });
        try register(ctx, anchor, ancestor, ancestor_priority);
    }

    /// Case J's content: the record's own popup and the ordinary control it
    /// covers, both children of the ordinary panel and both positioned
    /// absolutely at the panel's own origin with the panel's own size. Their
    /// laid-out boxes are therefore the same box whether or not a placement
    /// ever moved one of them, which is what makes "the dismissed popup
    /// painted nothing in its own box" a claim about committed geometry
    /// rather than about arithmetic this file guessed.
    fn buildDormantContent(_: *View, ctx: *nogui.DrawCtx) !WidgetId {
        const content = try ctx.column(.{
            .key = keyOf(key_dormant),
            .position = .absolute,
            .inset = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .width = base_w,
            .height = base_h,
            .fill = dormant_fill,
            .gap = 0,
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .@"align" = .start,
            .justify = .start,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
        });
        // A real control with its own handler, so "the record's own handler
        // never ran" is a count and not an absence of anything to count.
        _ = try ctx.button(.{
            .key = keyOf(key_dormant_button),
            .label = "dormant",
            .width = dormant_control_w,
            .height = dormant_control_h,
            .fill = dormant_button_fill,
            .color = dormant_button_text,
            .on_click_with_data = nogui.bind(View.onDormantClick, 0),
        });
        // The record's own high custom record: content-local, at the very
        // layer every band starts above, so a painter that painted an
        // unplaced record would put it above everything else on screen.
        _ = try ctx.elementLeaf(Canvas, .{ .mode = .dormant_bump }, .{
            .key = keyOf(key_dormant_canvas),
            .position = .absolute,
            .inset = .{ .top = dormant_control_h + 20, .right = 0, .bottom = 0, .left = 0 },
            .width = dormant_control_w,
            .height = dormant_record_h,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
        });
        ctx.pop();
        // The ordinary control underneath: the panel's own fill with a real
        // keyed button on it, so a press inside the dismissed popup's own box
        // reaches THIS control and a census of its own box says what is
        // really drawn there. It is positioned exactly as the record's content
        // is, so the two boxes are the same box whether or not either of them
        // was ever placed, and no probe has to guess where that box is.
        _ = try ctx.column(.{
            .key = keyOf(key_under),
            .position = .absolute,
            .inset = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .width = base_w,
            .height = base_h,
            .fill = under_fill,
            .gap = 0,
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .@"align" = .start,
            .justify = .start,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
        });
        _ = try ctx.button(.{
            .key = keyOf(key_under_button),
            .label = "under",
            .width = base_w,
            .height = dormant_control_h,
            .fill = under_button_fill,
            .color = under_button_text,
            .on_click_with_data = nogui.bind(View.onUnderClick, 0),
        });
        ctx.pop();
        return ctx.widgetIdOf(content) orelse error.MissingContent;
    }

    /// Case J's one record, registered in every frame whatever the anchor
    /// did, with no gap so a placed popup lands exactly on the ordinary
    /// control it covers. Only the anchor changes between frames.
    fn registerDormant(_: *View, ctx: *nogui.DrawCtx, anchor: WidgetId, content: WidgetId) !void {
        try ctx.place(.{
            .anchor = anchor,
            .content = content,
            .side = .below,
            .gap = 0,
            .clip = .window_escape,
            .priority = dormant_priority,
        });
    }
};

// ── the command line ──────────────────

const Options = struct {
    only: ?[]const u8 = null,
    ppm_dir: ?[]const u8 = null,
    prefix: []const u8 = "w16-paint-smoke",

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        if (self.only) |owned| gpa.free(owned);
        if (self.ppm_dir) |owned| gpa.free(owned);
        self.* = undefined;
    }
};

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    var options: Options = .{};
    errdefer options.deinit(gpa);
    var case_seen = false;
    var dir_seen = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--case")) {
            if (case_seen) return error.RepeatedCase;
            case_seen = true;
            const text = args.next() orelse return error.MissingCaseName;
            if (Case.parse(text) == null) return error.UnknownCase;
            options.only = try gpa.dupe(u8, text);
        } else if (std.mem.eql(u8, arg, "--ppm-dir")) {
            if (dir_seen) return error.RepeatedPpmDir;
            dir_seen = true;
            const text = args.next() orelse return error.MissingPpmDir;
            options.ppm_dir = try gpa.dupe(u8, text);
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            const text = args.next() orelse return error.MissingPrefix;
            if (text.len == 0 or text.len > 64) return error.InvalidPrefix;
            options.prefix = text;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var options = try parseArgs(gpa, init);
    defer options.deinit(gpa);

    var report: Reporter = .{ .io = io };
    var checks: Checks = .{ .report = &report };
    try report.emit(
        "W16 paint-band smoke: {d}x{d} window and device, {d} cases, offscreen surface\n",
        .{ device_extent.width, device_extent.height, Case.names.len },
    );

    try run(gpa, io, &report, &checks, options);

    try report.emit("\n{d} passed, {d} failed\n", .{ checks.passed, checks.failed });
    if (checks.failed != 0) return error.PaintSmokeClaimFailed;
}

/// Everything the run owns, declared once and in dependency order. The teardown
/// is the reverse: the App detaches from the endpoint and dies before the
/// renderer, the text engine, the heap and the device it recorded into, and the
/// loader outlives every one of them because the device is loaded through it.
fn run(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    checks: *Checks,
    options: Options,
) !void {
    var vert = try ShaderFile.load(gpa, io, default_quad_vert);
    defer vert.deinit(gpa);
    var frag = try ShaderFile.load(gpa, io, default_quad_frag);
    defer frag.deinit(gpa);
    var sort = try ShaderFile.load(gpa, io, default_sort_comp);
    defer sort.deinit(gpa);

    var loader = try frame_mod.SystemVulkanLoader.open();
    defer loader.close();
    var offscreen = try frame_mod.Offscreen.init(.{
        .allocator = gpa,
        .io = io,
        .loader = loader.options(),
        .extent = device_extent,
        .app_name = "w16-paint-smoke",
    });
    defer offscreen.deinit();
    const gpu = offscreen.gpu();

    // The heap owns the icon texture once it is registered, so there is nothing
    // to release here beyond the heap's own deinit above.
    var icons = try IconSet.prepare(gpa, gpu, offscreen.heap());

    var text = try frame_mod.TextEngine.init(gpa, gpu, &.{
        .{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") },
    });
    defer text.deinit();
    try text.setGlyphSlotLimit(frame_mod.scene.glyph_material_ceiling);

    var gui_renderer = try render.Renderer.init(gpu, vert.words, frag.words, sort.words);
    defer gui_renderer.deinit();
    gui_renderer.configure(.{ .material_bda = text.materialBda() });
    var scratch = frame_mod.scene.SceneScratch.init(gpa, &gui_renderer);
    defer scratch.deinit();

    var session = try Session.init(gpa);
    defer session.deinit() catch @panic("w16 paint smoke left a live window");
    var app = try App.init(gpa, &session);
    defer app.deinit();
    var view = View.init(gpa, &app);
    defer view.release();
    try app.mountRoot(View, &view);
    app.measure = text.measurer();
    app.setOverlayFrame(&view.frame);
    try app.attachGpu(offscreen.endpoint());
    defer app.detachGpu();

    // One retained buffer for the refusal case's before/after comparison. It is
    // allocated once here and never per frame; nothing inside a frame allocates.
    const pixels_per_frame = try std.math.mul(
        usize,
        try std.math.mul(usize, device_extent.width, device_extent.height),
        4,
    );
    const retained = try gpa.alloc(f32, pixels_per_frame);
    defer gpa.free(retained);

    var runner: Runner = .{
        .gpa = gpa,
        .io = io,
        .report = report,
        .checks = checks,
        .options = options,
        .app = &app,
        .view = &view,
        .scratch = &scratch,
        .text = &text,
        .renderer = &gui_renderer,
        .offscreen = &offscreen,
        .icons = icons.source(),
        .retained = retained,
    };

    if (options.only) |name| {
        try runner.runCase(Case.parse(name).?);
    } else {
        for (Case.names, 0..) |_, index| {
            try runner.runCase(@fromBackingInt(@intCast(index)));
        }
    }
}

/// The bounded driver. Every case is a fixed number of frames: one publish, or
/// for the refusal cases one good publish, a fixed number of refused attempts,
/// and one more good publish. Nothing here loops on anything the frame produced.
const Runner = struct {
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    checks: *Checks,
    options: Options,
    app: *App,
    view: *View,
    scratch: *frame_mod.scene.SceneScratch,
    text: *frame_mod.TextEngine,
    renderer: *render.Renderer,
    offscreen: *frame_mod.Offscreen,
    icons: frame_mod.scene.IconSource,
    retained: []f32,
    frame_number: u32 = 0,
    /// How many frames reached the device, so a refusal can be told apart from
    /// a frame that never ran.
    published: u32 = 0,
    /// Set while this runner holds an open recording, so a second publish in the
    /// same case is a bug in the case rather than a silent interleaving.
    recording: bool = false,

    /// One real frame, recorded and read back. The App publishes the tree, the
    /// canonical scene lowers it, and the offscreen target's Oklab pixels come
    /// back before this returns.
    ///
    /// The command buffer and the GPU frame are declared in place and never
    /// moved: the runtime retains pointers into them until the submission ends.
    fn publish(self: *Runner) ![]const f32 {
        if (self.recording) return error.RecordingAlreadyOpen;
        // SAFETY: `beginFrame` below assigns both out-parameters before it returns.
        var cmd: noapi.CommandBuffer = undefined;
        // SAFETY: the second out-parameter of that same `beginFrame`.
        var gpu_frame: nogui.GpuFrame = undefined;
        try self.offscreen.beginFrame(
            @mod(self.frame_number, frame_mod.scene.frames_in_flight),
            &cmd,
            &gpu_frame,
        );
        self.recording = true;
        // `beginFrame` assigns both out-parameters before it returns and a
        // refusal propagates through the `try` on the next line with neither
        // value read, so this flag only ever guards a case that asks for a
        // second publish without having released the first.
        errdefer self.recording = false;
        const out = self.app.frameWithGpuAtTime(
            self.frame_number,
            @as(u64, self.frame_number) * 16,
            .{ .width = window_w, .height = window_h },
            &gpu_frame,
        ) catch |err| {
            // The App cancels its own recording on a refused frame, so the
            // offscreen is free again and nothing was ever submitted: the
            // device never saw a command from this frame.
            self.recording = false;
            return err;
        };
        defer if (out.json) |json| self.gpa.free(json);

        self.scratch.beginFrame();
        var painted = try frame_mod.scene.buildFrameScene(
            self.scratch,
            self.text,
            .{ .icons = self.icons, .icon_logical_size = icon_logical_size },
            &out,
            false,
        );
        defer painted.deinit();
        const context: frame_mod.scene.RecordContext = .{
            .arena = out.tree.allocator,
            .renderer = self.renderer,
            .text = self.text,
            .logical = .{ .width = window_w, .height = window_h },
            .device = device_extent,
            .texture_heap = self.offscreen.heap().handle,
            .clips = out.tree.clip_rects[0..out.tree.clip_count],
        };
        _ = try frame_mod.scene.recordFrameScene(
            &context,
            &cmd,
            self.scratch,
            self.scratch.rects.items,
            &painted,
            self.offscreen.target(),
        );
        const pixels = try self.offscreen.submitRead(&gpu_frame);
        self.recording = false;
        self.frame_number += 1;
        self.published += 1;
        return pixels;
    }

    /// The same publish, expected to be refused by name. A publish that was NOT
    /// refused is itself a failed claim, and the report says so.
    fn publishRefused(self: *Runner, case: Case, label: []const u8, want: anyerror) !void {
        const outcome = self.publish();
        if (outcome) |pixels| {
            _ = pixels;
            try self.checks.claim(label, false);
            try self.report.emit("       case {s} published instead of being refused\n", .{
                Case.names[@backingInt(case)],
            });
            return;
        } else |err| {
            try self.checks.claim(label, err == want);
        }
    }

    fn liveTree(self: *Runner) !*widget.WidgetTree {
        return self.app.tree_ptr orelse error.RootNotMounted;
    }

    /// The node a keyed widget published in the committed tree.
    fn node(self: *Runner, name: []const u8) !FrameNodeId {
        const tree = try self.liveTree();
        const id = self.view.widget(name) orelse return error.MissingWidget;
        return tree.frameNode(id) orelse return error.MissingWidget;
    }

    /// The placed box of a keyed popup, read from the frame's own resolution.
    fn placed(self: *Runner, name: []const u8) !widget.Rect {
        const tree = try self.liveTree();
        const id = self.view.widget(name) orelse return error.MissingWidget;
        const placement = self.view.frame.placement(tree, id) orelse
            return error.UnplacedPopup;
        return placement.rect;
    }

    /// The layer the painter emits for a keyed node, through the same function
    /// the scene sorts by.
    fn emitted(self: *Runner, name: []const u8) !u32 {
        const tree = try self.liveTree();
        return widget.effectiveLayer(
            tree.nodeConst(try self.node(name)) orelse return error.MissingWidget,
            0,
        );
    }

    /// The generated caption a button carries, found through the tree's own
    /// parent chain rather than by a hard-coded node id.
    fn captionOf(self: *Runner, button: FrameNodeId) !widget.Rect {
        const tree = try self.liveTree();
        for (tree.nodes.items) |child| {
            if (child.parent != button) continue;
            if (child.kind != .label) continue;
            return widget.visualContentRect(tree, child.id);
        }
        return error.MissingCaption;
    }

    /// One real press and release at `point`, through the App's own public
    /// event path. Nothing here rebuilds a frame: routing answers from the
    /// committed tree, which is the tree a consumer's pointer really hits.
    fn press(self: *Runner, point: [2]f32) !void {
        _ = try self.app.handle(.{ .mouse_move = .{ .x = point[0], .y = point[1] } });
        _ = try self.app.handle(.{ .mouse_down = .{ .button = .left, .x = point[0], .y = point[1] } });
        _ = try self.app.handle(.{ .mouse_up = .{ .button = .left, .x = point[0], .y = point[1] } });
    }

    /// Park the pointer where it can hover nothing, so a pixel census reads
    /// the frame's own content and not a cursor state an earlier probe left
    /// behind. The point is the window's own far corner, which the root
    /// container answers and no keyed control owns.
    fn parkPointer(self: *Runner) !void {
        _ = try self.app.handle(.{ .mouse_move = .{ .x = window_w - 1, .y = window_h - 1 } });
    }

    /// One PPM for one case, when the run was asked for them.
    fn writeCase(self: *Runner, case: Case, pixels: []const f32) !void {
        const dir = self.options.ppm_dir orelse return;
        const path = try std.fmt.allocPrint(
            self.gpa,
            "{s}/{s}-{s}.ppm",
            .{ dir, self.options.prefix, Case.names[@backingInt(case)] },
        );
        defer self.gpa.free(path);
        try frame_mod.writePpm(self.gpa, self.io, path, pixels, device_extent);
        try self.report.emit("       ppm {s}\n", .{path});
    }

    // ── the cases ──────────────────

    fn runCase(self: *Runner, case: Case) !void {
        const before = self.checks.passed + self.checks.failed;
        try self.report.emit("CASE {s}\n", .{Case.names[@backingInt(case)]});
        switch (case) {
            .a_priority_low_first => try self.caseOrder(
                case,
                key_low,
                key_high,
                "A: the higher priority wins although it was built and registered second",
            ),
            .b_priority_high_first => try self.caseOrder(
                case,
                key_high,
                key_high,
                "B: the same higher priority wins because it was built and registered first",
            ),
            .c_equal_later_wins => try self.caseEqualLater(),
            .d_winning_content => try self.caseWinningContent(),
            .e_refusal_retains => try self.caseRefusalRetains(),
            .f_interior_high_first => try self.caseInterior(case, "F: with the high layer emitted first"),
            .f_interior_low_first => try self.caseInterior(case, "F: with the high layer emitted last"),
            .g_bump_overflow => try self.caseBumpOverflow(),
            .h_unplaced_bump => try self.caseUnplacedBump(),
            .i_nested_first => try self.caseNested(),
            .j_dormant_overlay => try self.caseDormant(),
        }
        const made = self.checks.passed + self.checks.failed - before;
        try self.report.emit("CASE {s} done, {d} claims\n", .{ Case.names[@backingInt(case)], made });
    }

    /// The shared body of A and B: two same-size popups on the same rect, one of
    /// which must own every probed pixel and the overlapping point. Which of
    /// them was built and registered first is the only difference between the
    /// two cases, and it must not change the winner.
    fn caseOrder(
        self: *Runner,
        case: Case,
        first: []const u8,
        winner: []const u8,
        label: []const u8,
    ) !void {
        self.view.case = case;
        self.view.scene = .normal;
        const pixels = try self.publish();
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const loser = if (std.mem.eql(u8, winner, key_high)) key_low else key_high;
        const winner_fill = fillOf(winner);
        const loser_fill = fillOf(loser);
        try self.report.emit("       {s}; built and registered first: {s}\n", .{ label, first });

        // Both popups resolve to the same box from the same anchor, so this
        // census IS the overlap, not a corner of only one of them.
        const box = try self.placed(winner);
        const inner: widget.Rect = .{
            .x = box.x + probe_inset,
            .y = box.y + probe_inset,
            .w = box.w - probe_inset * 2,
            .h = box.h - probe_inset * 2,
        };
        try self.checks.claim("the popup's probe window is not empty", image.total(inner) > 0);
        try self.checks.count(
            "every probed popup pixel is the winner's own fill",
            image.countColor(inner, winner_fill),
            image.total(inner),
            image.total(inner),
        );
        try self.checks.count(
            "no probed popup pixel is the other popup's fill",
            image.countColor(inner, loser_fill),
            0,
            0,
        );
        // The emitted layers, read through the function the painter sorts by,
        // beside the application's own maximum, which every band starts above.
        const app_max = try widget.maximumPaintLayer(try self.liveTree());
        try self.checks.claim(
            "the winner's emitted layer is above the loser's, and the loser's clears the application maximum",
            (try self.emitted(winner)) > (try self.emitted(loser)) and
                (try self.emitted(loser)) > app_max,
        );
        // ROUTING, through the public total hit test, at the middle of the
        // overlap: the point belongs to the winner's subtree and to nothing in
        // the loser's.
        const point: [2]f32 = .{ box.x + box.w / 2, box.y + box.h / 2 };
        const tree = try self.liveTree();
        const hit = self.view.frame.hitTestTotal(tree, point) orelse return error.MissedRouting;
        try self.checks.claim(
            "the overlapping point routes into the winning popup's subtree",
            descendsFrom(tree, hit, try self.node(winner)) and
                !descendsFrom(tree, hit, try self.node(loser)),
        );
        try self.writeCase(case, pixels);
    }

    /// C: two popups at the SAME priority, so only the registration order can
    /// decide. The one registered second is built second, and must win.
    fn caseEqualLater(self: *Runner) !void {
        self.view.case = .c_equal_later_wins;
        self.view.scene = .normal;
        const pixels = try self.publish();
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const box = try self.placed(key_low);
        const inner: widget.Rect = .{
            .x = box.x + probe_inset,
            .y = box.y + probe_inset,
            .w = box.w - probe_inset * 2,
            .h = box.h - probe_inset * 2,
        };
        try self.checks.claim("the popup's probe window is not empty", image.total(inner) > 0);
        try self.checks.count(
            "equal priorities: every probed popup pixel is the later registration's fill",
            image.countColor(inner, low_fill),
            image.total(inner),
            image.total(inner),
        );
        try self.checks.count(
            "equal priorities: no probed popup pixel is the earlier registration's fill",
            image.countColor(inner, high_fill),
            0,
            0,
        );
        try self.checks.claim(
            "equal priorities: the later registration emitted the higher layer",
            (try self.emitted(key_low)) > (try self.emitted(key_high)),
        );
        try self.writeCase(.c_equal_later_wins, pixels);
    }

    /// D: every foreground the winning popup generates, each measured where it
    /// is and in a control window of the ordinary panel where it is not.
    fn caseWinningContent(self: *Runner) !void {
        self.view.case = .d_winning_content;
        self.view.scene = .normal;
        const pixels = try self.publish();
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const tree = try self.liveTree();
        const box = try self.placed(key_high);

        // The popup above the ordinary base it covers.
        const whole: widget.Rect = .{
            .x = box.x + probe_inset,
            .y = box.y + probe_inset,
            .w = box.w - probe_inset * 2,
            .h = box.h - probe_inset * 2,
        };
        try self.checks.count(
            "the popup's own fill survives inside the popup",
            image.countColor(whole, high_fill),
            16,
            image.total(whole),
        );
        try self.checks.count(
            "no pixel of the covered ordinary base survives inside the popup",
            image.countColor(whole, base_fill),
            0,
            0,
        );
        // A strip of the popup no control reaches, so the claim above is about
        // the popup's own fill and not about a gap between two controls.
        const bare: widget.Rect = inside(box, .{ .x = 4, .y = 90, .w = 140, .h = 8 });
        try self.checks.count(
            "the popup's own fill is present in the strip below its controls",
            image.countColor(bare, high_fill),
            image.total(bare),
            image.total(bare),
        );

        // The caption. Inside the caption's own box the only things that can be
        // are the button's fill, the popup's fill and glyph ink, so ink by
        // elimination is a behavioural claim about the caption, not a claim
        // about which glyphs a font happened to produce.
        const caption = try self.captionOf(try self.node(key_caption));
        try self.checks.count(
            "caption glyphs are painted inside the popup, above its own fill",
            image.countNeither(caption, caption_fill, high_fill),
            6,
            image.total(caption),
        );
        try self.checks.count(
            "no popup fill covers the caption's own box",
            image.countColor(caption, high_fill),
            0,
            0,
        );
        try self.checks.count(
            "no caption ink is painted in the ordinary panel outside the popup",
            image.countNeither(control_window, caption_fill, base_fill),
            0,
            0,
        );

        // The checked checkbox: its own filled indicator, and the mark the scene
        // module draws on top of it.
        const check_content = widget.visualContentRect(tree, try self.node(key_check));
        const size = @min(
            widget.control_indicator_size,
            @min(check_content.w, check_content.h),
        );
        const indicator: widget.Rect = .{
            .x = check_content.x,
            .y = check_content.y + (check_content.h - size) / 2,
            .w = size,
            .h = size,
        };
        try self.checks.count(
            "the checked indicator is painted inside the popup",
            image.countColor(indicator, check_fill),
            8,
            image.total(indicator),
        );
        try self.checks.count(
            "the check mark is painted on the indicator, above the popup's own fill",
            image.countColor(indicator, markFill()),
            4,
            image.total(indicator),
        );
        try self.checks.count(
            "no popup fill covers the checkbox indicator",
            image.countColor(indicator, high_fill),
            0,
            0,
        );
        try self.checks.count(
            "no check mark is painted in the ordinary panel outside the popup",
            image.countColor(control_window, markFill()),
            0,
            0,
        );

        // The slider: its progress fill and the thumb the scene module centres
        // on the value, both read from the node's own rail.
        const rail = widget.visualBorderRect(tree, try self.node(key_slider));
        const thumb = widget.sliderThumbRect(rail, std.math.clamp(self.view.model.slide, 0, 1));
        try self.checks.count(
            "the slider's progress fill is painted inside the popup",
            image.countColor(rail, slide_fill),
            8,
            image.total(rail),
        );
        try self.checks.count(
            "the slider's thumb is painted on its rail, above the popup's own fill",
            image.countColor(thumb, thumb_fill),
            4,
            image.total(thumb),
        );
        try self.checks.count(
            "no thumb is painted in the ordinary panel outside the popup",
            image.countColor(control_window, thumb_fill),
            0,
            0,
        );

        // The icon. The button behind the quad is authored transparent, so the
        // only thing that can be in the quad's uncovered corner is the popup's
        // own fill. The middle of the quad is the button's colour at full
        // coverage and the corner is the popup's fill, which is what proves the
        // quad is sampled with its coverage rather than replaced by a block.
        const icon_content = widget.visualContentRect(tree, try self.node(key_icon));
        const side = @min(
            icon_logical_size,
            @min(icon_content.w, icon_content.h),
        );
        const quad: widget.Rect = .{
            .x = icon_content.x + (icon_content.w - side) / 2,
            .y = icon_content.y + (icon_content.h - side) / 2,
            .w = side,
            .h = side,
        };
        try self.checks.count(
            "the icon raster is sampled at full coverage inside the popup",
            image.countColor(inside(quad, icon_middle), icon_fill),
            16,
            16,
        );
        try self.checks.count(
            "the icon's uncovered corner shows the popup's own fill",
            image.countColor(inside(quad, icon_corner), high_fill),
            4,
            4,
        );
        try self.checks.count(
            "no icon colour is painted in the ordinary panel outside the popup",
            image.countColor(control_window, icon_fill),
            0,
            0,
        );

        // The custom canvas record inside the popup, and the band it rides. It
        // is authored at the popup's OWN layer on purpose: that is the only way
        // to show it rides its placed subtree's band instead of the
        // application's.
        const canvas_box = widget.visualContentRect(tree, try self.node(key_canvas));
        try self.checks.count(
            "the popup's custom canvas record is painted inside the popup",
            image.countColor(canvas_box, canvas_fill),
            8,
            image.total(canvas_box),
        );
        try self.checks.count(
            "no popup fill covers the custom canvas record's box",
            image.countColor(canvas_box, high_fill),
            0,
            0,
        );
        try self.checks.claim(
            "the custom canvas record emits the same physical layer as the popup that owns it",
            (try self.emitted(key_canvas)) == (try self.emitted(key_high)),
        );
        try self.writeCase(.d_winning_content, pixels);
    }

    /// E: three refusals, and the committed state is identical afterwards. The
    /// refusals are ones a real consumer can hit: a record the frame refuses by
    /// name, a viewport its own stage refuses, and a band finalization it
    /// cannot complete.
    fn caseRefusalRetains(self: *Runner) !void {
        // A good frame to be compared against.
        self.view.case = .a_priority_low_first;
        self.view.scene = .normal;
        const pixels = try self.publish();
        @memcpy(self.retained, pixels);
        const box = try self.placed(key_high);
        const point: [2]f32 = .{ box.x + box.w / 2, box.y + box.h / 2 };
        const committed = try self.liveTree();
        const committed_layer = try self.emitted(key_high);
        const committed_hit = self.view.frame.hitTestTotal(committed, point);
        const published_before = self.published;

        // One: a record the frame refuses by name, through the App's own path.
        self.view.case = .e_refusal_retains;
        self.view.scene = .refuse_record;
        try self.publishRefused(
            .e_refusal_retains,
            "E: a record with a non-finite margin is refused by name",
            error.InvalidGeometry,
        );

        // Two: a stage the frame refuses, asked for directly. The App's viewport
        // is not caller-controlled, so this is the only way to reach a stage
        // refusal; it is the real `Frame.stage`, on the real committed tree, and
        // the claims below read the routing the App is still using.
        //
        // The public rule is that a viewport is a finite, NON-NEGATIVE size, so
        // the refusal is asked for with a negative extent. A zero extent is a
        // legal empty viewport and a claim about it would assert a policy this
        // contract does not make. The viewport is the first thing `stage` reads,
        // before it tags a node or moves an origin, so a refused stage cannot
        // have touched the committed tree.
        const invalid_viewport: widget.Rect = .{ .x = 0, .y = 0, .w = -1, .h = -1 };
        const staged = self.view.frame.stage(committed, invalid_viewport);
        try self.checks.claim(
            "E: a negative viewport is refused by the frame's own stage",
            isInvalidGeometry(staged),
        );

        // Three: a band the frame cannot finish, through the App's own path.
        self.view.scene = .overflow_bump;
        try self.publishRefused(
            .e_refusal_retains,
            "E: a custom bump that cannot hold its band is refused",
            error.PaintLayerOverflow,
        );

        // The committed tree, its metadata and its routing survived all three.
        try self.checks.claim(
            "E: the committed tree is the same tree after three refusals",
            @intFromPtr(try self.liveTree()) == @intFromPtr(committed),
        );
        try self.checks.claim(
            "E: the placed popup's box is unchanged after three refusals",
            std.meta.eql(try self.placed(key_high), box),
        );
        try self.checks.claim(
            "E: the placed popup's emitted layer is unchanged after three refusals",
            (try self.emitted(key_high)) == committed_layer,
        );
        try self.checks.claim(
            "E: the overlapping point still routes exactly where it did",
            std.meta.eql(self.view.frame.hitTestTotal(try self.liveTree(), point), committed_hit),
        );
        try self.checks.claim(
            "E: no frame reached the device during the refusals",
            self.published == published_before,
        );

        // And the next real frame is the same picture, byte for byte, which is
        // the only evidence that a refusal left the target alone.
        self.view.case = .a_priority_low_first;
        self.view.scene = .normal;
        const again = try self.publish();
        try self.checks.claim(
            "E: the frame after the refusals is byte-identical to the one before them",
            std.mem.eql(
                u8,
                std.mem.sliceAsBytes(self.retained),
                std.mem.sliceAsBytes(again),
            ),
        );
        try self.writeCase(.e_refusal_retains, again);
    }

    /// F: two records over the same bounds inside one popup, differing only in
    /// their AUTHORED local layer. The pair runs twice with the layers emitted
    /// in opposite orders and the higher layer wins in both, so a painter that
    /// ordered them by emission would pass one case and fail the other.
    fn caseInterior(self: *Runner, case: Case, label: []const u8) !void {
        self.view.case = case;
        self.view.scene = .normal;
        const pixels = try self.publish();
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const box = try self.placed(key_high);
        const interior: widget.Rect = .{
            .x = box.x + probe_inset,
            .y = box.y + probe_inset,
            .w = box.w - probe_inset * 2,
            .h = box.h - probe_inset * 2,
        };
        try self.checks.claim("the popup's probe window is not empty", image.total(interior) > 0);
        try self.report.emit("       {s}\n", .{label});
        try self.checks.count(
            "the higher authored local layer is the one inside the popup",
            image.countColor(interior, interior_high),
            image.total(interior),
            image.total(interior),
        );
        try self.checks.count(
            "the lower authored local layer is not painted over it",
            image.countColor(interior, interior_low),
            0,
            0,
        );
        try self.checks.count(
            "no ordinary base pixel survives inside the popup either",
            image.countColor(interior, base_fill),
            0,
            0,
        );
        try self.checks.claim(
            "both interior records ride the popup's own band, so the order inside it is the authored one",
            (try self.emitted(key_canvas)) == (try self.emitted(key_high)),
        );
        try self.writeCase(case, pixels);
    }

    /// G: the typed failure, and nothing published.
    fn caseBumpOverflow(self: *Runner) !void {
        self.view.case = .a_priority_low_first;
        self.view.scene = .normal;
        const pixels = try self.publish();
        const committed = try self.liveTree();
        const layer = try self.emitted(key_high);
        const published_before = self.published;

        self.view.case = .g_bump_overflow;
        self.view.scene = .normal;
        try self.publishRefused(
            .g_bump_overflow,
            "G: an overflowing custom bump is a typed failure, not a clamp",
            error.PaintLayerOverflow,
        );
        try self.checks.claim(
            "G: the committed tree survived the overflowing frame",
            @intFromPtr(try self.liveTree()) == @intFromPtr(committed),
        );
        try self.checks.claim(
            "G: the committed tree's layer metadata survived it",
            (try self.emitted(key_high)) == layer,
        );
        try self.checks.claim(
            "G: no frame reached the device for the overflowing scene",
            self.published == published_before,
        );
        try self.checks.claim(
            "G: the overflowing element never entered the committed tree",
            self.view.widget(key_canvas) == null,
        );
        try self.writeCase(.g_bump_overflow, pixels);
    }

    /// H: an unplaced custom record with a high bump, in the ordinary base. It
    /// has no band, and every band starts above the application's own maximum,
    /// so the popup still wins where they overlap.
    fn caseUnplacedBump(self: *Runner) !void {
        self.view.case = .h_unplaced_bump;
        self.view.scene = .normal;
        const pixels = try self.publish();
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const tree = try self.liveTree();

        const bump_node = try self.node(key_bump);
        try self.checks.claim(
            "H: the unplaced custom element has no band of its own",
            (tree.nodeConst(bump_node) orelse return error.MissingWidget).placement_paint == null,
        );
        const app_max = try widget.maximumPaintLayer(tree);
        try self.checks.claim(
            "H: the popup's band clears the high bump the unplaced record emits",
            (try self.emitted(key_high)) > app_max and app_max >= try self.emitted(key_bump),
        );
        // Where the popup covers the unplaced record, the popup's own fill is
        // what survives; where the record reaches past the popup, its own is.
        const popup_box = try self.placed(key_high);
        const bump_box = widget.visualContentRect(tree, bump_node);
        const covered = overlap(popup_box, bump_box) orelse return error.PopupMissesTheBump;
        try self.checks.claim("the popup and the unplaced record really do overlap", image.total(covered) > 0);
        try self.checks.count(
            "H: the popup's fill is what survives over the unplaced record",
            image.countColor(covered, high_fill),
            16,
            image.total(covered),
        );
        try self.checks.count(
            "H: no pixel of the unplaced record survives under the popup",
            image.countColor(covered, bump_fill),
            0,
            0,
        );
        const exposed: widget.Rect = .{
            .x = bump_box.x + bump_box.w - 10,
            .y = bump_box.y + 4,
            .w = 6,
            .h = bump_box.h - 8,
        };
        try self.checks.count(
            "H: the unplaced record really did paint, where the popup does not reach",
            image.countColor(exposed, bump_fill),
            8,
            image.total(exposed),
        );
        try self.writeCase(.h_unplaced_bump, pixels);
    }

    /// I: the nested popup is registered FIRST, at the higher priority, and the
    /// lower-priority ancestor is registered afterwards around it.
    fn caseNested(self: *Runner) !void {
        self.view.case = .i_nested_first;
        self.view.scene = .normal;
        const pixels = try self.publish();
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const tree = try self.liveTree();

        // Both boxes are the COMMITTED TREE's own boxes, not the fit rects the
        // records resolved. The nested popup is fitted against its anchor's
        // pre-move geometry, and the ancestor's later move composes onto it, so
        // the nested fit rect is a row above where the nested popup paints.
        const ancestor_box = widget.visualBorderRect(tree, try self.node(key_ancestor));
        const nested_box = widget.visualBorderRect(tree, try self.node(key_nested));
        const nested_point: [2]f32 = .{
            nested_box.x + nested_box.w / 2,
            nested_box.y + nested_box.h / 2,
        };
        try self.checks.claim(
            "I: the nested popup's own point lies inside the ancestor's own box",
            nested_point[0] >= ancestor_box.x and nested_point[0] < ancestor_box.x + ancestor_box.w and
                nested_point[1] >= ancestor_box.y and nested_point[1] < ancestor_box.y + ancestor_box.h,
        );
        const shared = overlap(ancestor_box, nested_box) orelse return error.PopupsDoNotOverlap;
        try self.checks.claim("the two popups' own boxes really do overlap", image.total(shared) > 0);
        try self.checks.count(
            "I: the nested popup's fill is what survives inside the ancestor",
            image.countColor(shared, high_fill),
            16,
            image.total(shared),
        );
        try self.checks.count(
            "I: no pixel of the later-registered ancestor survives over it",
            image.countColor(shared, low_fill),
            0,
            0,
        );
        try self.checks.claim(
            "I: the nested subtree kept the higher band",
            (try self.emitted(key_nested)) > (try self.emitted(key_ancestor)),
        );
        const hit = self.view.frame.hitTestTotal(tree, nested_point) orelse return error.MissedRouting;
        try self.checks.claim(
            "I: the nested popup's own point routes to the nested subtree",
            descendsFrom(tree, hit, try self.node(key_nested)),
        );
        try self.writeCase(.i_nested_first, pixels);
    }

    /// J: ONE registered record, built, filled and visible in every frame,
    /// over an ordinary control that fills the same box. Only the anchor
    /// changes: hidden, visible, hidden, then absent from the tree entirely.
    /// Each frame is measured on its own pixels, the App's own total routing
    /// and handlers, the inspector's answer, and whether the record was
    /// handed a band.
    fn caseDormant(self: *Runner) !void {
        self.view.case = .j_dormant_overlay;

        // Frame 1: the anchor is built and hidden, so the record resolves to
        // nothing while its content stays laid out, filled and visible.
        self.view.scene = .anchor_hidden;
        try self.parkPointer();
        try self.dormantFrame("J: the anchor is built and hidden", try self.publish());

        // The handles and the ordinary metadata this case measures, taken
        // from the frame just published.
        const first = try self.liveTree();
        const content_id = self.view.widget(key_dormant) orelse return error.MissingWidget;
        const inner_id = self.view.widget(key_dormant_button) orelse return error.MissingWidget;
        const under_id = self.view.widget(key_under_button) orelse return error.MissingWidget;
        const anchor_id = self.view.anchor_handle orelse return error.MissingAnchor;
        const under_layer = try self.emitted(key_under_button);
        const under_button = try self.node(key_under_button);
        const dismissed_root = try self.node(key_dormant);
        const under_box = widget.visualBorderRect(first, under_button);

        // The App's own press at the middle of the ordinary button, which is
        // inside the dismissed popup's own box: the ordinary control is
        // reached, the record is not, and only the ordinary handler runs.
        const press_point: [2]f32 = .{
            under_box.x + under_box.w / 2,
            under_box.y + under_box.h / 2,
        };
        const under_before = self.view.under_clicks;
        const dormant_before = self.view.dormant_clicks;
        const routed_before = self.view.routed_presses;
        try self.press(press_point);
        const routed = self.view.routed_target orelse return error.MissedRouting;
        try self.checks.claim(
            "J: the App's own routing named the ordinary control, not the dismissed subtree",
            descendsFrom(first, routed, under_button) and !descendsFrom(first, routed, dismissed_root),
        );
        try self.checks.claim(
            "J: the App routed exactly one press",
            self.view.routed_presses == routed_before + 1,
        );
        try self.checks.claim(
            "J: the ordinary control's own handler ran exactly once",
            self.view.under_clicks == under_before + 1,
        );
        try self.checks.claim(
            "J: the dismissed control's own handler never ran",
            self.view.dormant_clicks == dormant_before,
        );

        // Frame 2: the very same content with a visible anchor. The record
        // places, and every answer about it inverts.
        self.view.scene = .normal;
        try self.parkPointer();
        try self.placedFrame(try self.publish());
        try self.checks.claim(
            "J: the record's own content kept the same stable handle across both frames",
            (self.view.widget(key_dormant) orelse return error.MissingWidget).eql(content_id),
        );

        // Frame 3: the pointer parked and the keyboard focus still on the
        // record's own control, so the ring that control draws is a measured
        // pixel and not an assumption about the scene.
        try self.parkPointer();
        const ring = try self.ringCensus(try self.publish(), dormant_button_fill, dormant_fill);
        try self.checks.claim("J: the ring strip is not empty", ring.window > 0);
        try self.checks.count(
            "J: the focused control inside the placed popup is ringed",
            ring.other,
            4,
            ring.window,
        );

        // Frame 4: retiring the popup also revokes its focus target.
        self.view.scene = .anchor_hidden;
        try self.parkPointer();
        const retired = try self.publish();
        try self.dormantFrame("J: the anchor is hidden again, so the record is retired", retired);
        try self.checks.claim(
            "J: the retired popup no longer owns keyboard focus",
            if (self.app.focus_manager.current) |focused| !focused.eql(inner_id) else true,
        );
        const gone = try self.ringCensus(retired, under_button_fill, under_fill);
        try self.checks.claim("J: the ring strip is still not empty", gone.window > 0);
        try self.checks.count(
            "J: the same focused control is ringed no more once its record is retired",
            gone.other,
            0,
            0,
        );

        // Frame 5: the anchor is not built at all this frame, and the record
        // is registered against the handle the first frame captured.
        self.view.scene = .anchor_absent;
        try self.parkPointer();
        const absent = try self.publish();
        try self.dormantFrame("J: the anchor is not in this frame's tree at all", absent);

        // RETENTION. Every frame above rebuilt the tree, and the ordinary
        // side of it kept the same handles, the same emitted layers and the
        // same record; the retired record never carried a band of its own in
        // any of them.
        try self.checks.claim(
            "J: the ordinary control kept the same stable handle across every frame",
            (self.view.widget(key_under_button) orelse return error.MissingWidget).eql(under_id),
        );
        try self.checks.claim(
            "J: the ordinary control's own emitted layer never moved",
            (try self.emitted(key_under_button)) == under_layer,
        );
        try self.checks.claim(
            "J: the vanished anchor is not in the frame that kept its handle",
            (try self.liveTree()).frameNode(anchor_id) == null,
        );
        try self.checks.claim(
            "J: the record's own control is still registered, just not placed",
            (self.view.widget(key_dormant_button) orelse return error.MissingWidget).eql(inner_id),
        );
        try self.writeCase(.j_dormant_overlay, absent);
    }

    /// Everything a frame whose record resolved to nothing must satisfy. The
    /// label names the frame and the pixels are that frame's own readback.
    fn dormantFrame(self: *Runner, label: []const u8, pixels: []const f32) !void {
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const tree = try self.liveTree();
        const root = try self.node(key_dormant);
        const inner = try self.node(key_dormant_button);
        const canvas = try self.node(key_dormant_canvas);
        const under = try self.node(key_under);
        const under_button = try self.node(key_under_button);
        const content_id = self.view.widget(key_dormant) orelse return error.MissingWidget;
        try self.report.emit("       {s}\n", .{label});

        // It is still a REGISTERED overlay subtree, and nothing placed it.
        try self.checks.claim(
            "the record is still a registered overlay subtree",
            self.view.frame.isOverlayNode(tree, root),
        );
        try self.checks.claim(
            "nothing placed it",
            self.view.frame.placement(tree, content_id) == null,
        );

        // NO BAND. An unplaced record must not lift a single node, in this
        // subtree or anywhere else in the frame.
        var banded: usize = 0;
        for (tree.nodes.items) |entry| {
            if (entry.placement_paint != null) banded += 1;
        }
        try self.checks.claim("not one node in the frame carries a band", banded == 0);

        // And it does not lift the application maximum either: its own high
        // record is measured, and the maximum every band base starts from is
        // the maximum everything outside the dismissed subtree emits.
        const own = try widget.emittedLocalLayer(
            tree.nodeConst(canvas) orelse return error.MissingWidget,
        );
        const ordinary = try ordinaryMaximum(tree, root);
        try self.checks.claim(
            "its own high record still emits its own layer",
            own == bump_layer,
        );
        try self.checks.claim(
            "the application maximum counts the ordinary tree only",
            (try widget.maximumPaintLayer(tree)) == ordinary and ordinary < own,
        );

        // PIXELS. The window is the committed laid-out box of the dismissed
        // content, which is the ordinary panel's own content box.
        const flow = widget.visualBorderRect(tree, root);
        const panel = widget.visualBorderRect(tree, under);
        try self.checks.claim(
            "the dismissed content's laid-out box is the ordinary panel's own box",
            std.meta.eql(flow, panel),
        );
        try self.checks.claim("the probe window is not empty", image.total(flow) > 0);
        try self.checks.count(
            "the dismissed popup's own fill painted nothing",
            image.countColor(flow, dormant_fill),
            0,
            0,
        );
        try self.checks.count(
            "its own control's fill painted nothing",
            image.countColor(flow, dormant_button_fill),
            0,
            0,
        );
        try self.checks.count(
            "its own high custom record painted nothing",
            image.countColor(flow, dormant_canvas_fill),
            0,
            0,
        );

        // What the window shows instead is the ordinary control: its own
        // panel fill below its own button, and its own button where the
        // record's own control would have been.
        const under_button_box = widget.visualBorderRect(tree, under_button);
        const bare: widget.Rect = .{
            .x = panel.x + 4,
            .y = under_button_box.y + under_button_box.h + 4,
            .w = panel.w - 8,
            .h = panel.y + panel.h - under_button_box.y - under_button_box.h - 8,
        };
        try self.checks.claim(
            "the bare strip below the ordinary button is not empty",
            image.total(bare) > 0,
        );
        try self.checks.count(
            "the ordinary panel's own fill is what the dismissed box shows",
            image.countColor(bare, under_fill),
            image.total(bare),
            image.total(bare),
        );
        const ordinary_window: widget.Rect = .{
            .x = under_button_box.x + 16,
            .y = under_button_box.y + 8,
            .w = 48,
            .h = under_button_box.h - 16,
        };
        try self.checks.claim(
            "the ordinary button's own window is not empty",
            image.total(ordinary_window) > 0,
        );
        try self.checks.count(
            "the ordinary button's own fill is painted where the record's control was",
            image.countColor(ordinary_window, under_button_fill),
            image.total(ordinary_window),
            image.total(ordinary_window),
        );

        // ROUTING, through the App's own total hit test at the middle of the
        // ordinary button, which is inside the dismissed popup's own box.
        const point: [2]f32 = .{
            under_button_box.x + under_button_box.w / 2,
            under_button_box.y + under_button_box.h / 2,
        };
        try self.checks.claim(
            "that point is inside the dismissed popup's own box",
            contains(flow, point),
        );
        const hit = self.view.frame.hitTestTotal(tree, point) orelse return error.MissedRouting;
        try self.checks.claim(
            "total routing there reaches the ordinary control and nothing of the record",
            descendsFrom(tree, hit, under_button) and !descendsFrom(tree, hit, root),
        );
        try self.checks.claim(
            "the frame's own placement scan covers no point of that box",
            self.view.frame.hitTest(tree, point) == null,
        );

        // THE SNAPSHOT, which has to agree with the engine: still flagged as
        // overlay content, no order, and neither painted nor pressable.
        var snapshot = try nogui.inspection.captureFrame(self.gpa, .{
            .viewport = .{ .x = 0, .y = 0, .w = window_w, .h = window_h },
            .tree = tree,
            .overlay_frame = &self.view.frame,
        });
        defer snapshot.deinit();
        const snap_root = snapshot.findByFrameNodeId(root) orelse return error.MissingSnapshot;
        const snap_inner = snapshot.findByFrameNodeId(inner) orelse return error.MissingSnapshot;
        try self.checks.claim(
            "the snapshot still flags both nodes as overlay content",
            snap_root.is_overlay and snap_inner.is_overlay,
        );
        try self.checks.claim(
            "the dismissed content carries no overlay order",
            snap_root.overlay_order == null and snap_inner.overlay_order == null,
        );
        try self.checks.claim(
            "the snapshot reports it as neither painted nor pressable",
            !snap_root.is_visible and !snap_root.is_enabled and
                !snap_inner.is_visible and !snap_inner.is_enabled,
        );
        const picked = snapshot.pickResult(point);
        try self.checks.claim(
            "the snapshot's pick names the ordinary control, not the dismissed subtree",
            picked.node != null and descendsFrom(tree, picked.node.?, under_button) and
                !descendsFrom(tree, picked.node.?, root),
        );
        try self.checks.claim(
            "the snapshot's pick is exactly the App's own routing answer",
            picked.node != null and picked.node.? == hit,
        );
    }

    /// Frame 2: the same content with a visible anchor. The record places, the
    /// popup paints above the ordinary control it covers, and the App's own
    /// routing and handlers reach the record and not the control underneath.
    fn placedFrame(self: *Runner, pixels: []const f32) !void {
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const tree = try self.liveTree();
        const root = try self.node(key_dormant);
        const canvas = try self.node(key_dormant_canvas);
        const under = try self.node(key_under);
        const under_button = try self.node(key_under_button);

        // The frame's own resolution, with no gap to the anchor, so the
        // placed box IS the ordinary panel's own box and the two censuses
        // below are about the same pixels.
        const box = try self.placed(key_dormant);
        const panel = widget.visualBorderRect(tree, under);
        try self.checks.claim(
            "the reactivated popup landed on the ordinary panel's own box",
            std.meta.eql(box, panel),
        );

        // A BAND at last, above the whole application, with the record's own
        // control and its own custom record riding that one band.
        const app_max = try widget.maximumPaintLayer(tree);
        try self.checks.claim(
            "the reactivated subtree carries the band's record on every node",
            (tree.nodeConst(root) orelse return error.MissingWidget).placement_paint != null and
                (tree.nodeConst(canvas) orelse return error.MissingWidget).placement_paint != null,
        );
        try self.checks.claim(
            "the popup's band clears the application maximum",
            (try self.emitted(key_dormant)) > app_max,
        );
        try self.checks.claim(
            "its own control and its own custom record ride that one band",
            (try self.emitted(key_dormant_button)) == (try self.emitted(key_dormant)) and
                (try self.emitted(key_dormant_canvas)) == (try self.emitted(key_dormant)),
        );

        // PIXELS: the record's own fill where none of its own content
        // reaches, its own control, and its own high custom record.
        const bare: widget.Rect = .{
            .x = box.x + 4,
            .y = box.y + box.h - 40,
            .w = box.w - 8,
            .h = 30,
        };
        try self.checks.claim("the popup's own bare strip is not empty", image.total(bare) > 0);
        try self.checks.count(
            "the reactivated popup's own fill is painted",
            image.countColor(bare, dormant_fill),
            image.total(bare),
            image.total(bare),
        );
        try self.checks.count(
            "no ordinary control fill survives inside it",
            image.countColor(bare, under_fill) + image.countColor(bare, under_button_fill),
            0,
            0,
        );
        const inner = try self.node(key_dormant_button);
        const inner_box = widget.visualBorderRect(tree, inner);
        try self.checks.count(
            "the record's own control is painted",
            image.countColor(inner_box, dormant_button_fill),
            8,
            image.total(inner_box),
        );
        const canvas_box = widget.visualContentRect(tree, canvas);
        try self.checks.count(
            "the record's own high custom record is painted",
            image.countColor(canvas_box, dormant_canvas_fill),
            8,
            image.total(canvas_box),
        );
        // The ordinary control's own box, where the record's own content does
        // not reach, is the popup's fill: it is covered, not showing through.
        const under_button_box = widget.visualBorderRect(tree, under_button);
        const content_right = @max(inner_box.x + inner_box.w, canvas_box.x + canvas_box.w);
        const covered: widget.Rect = .{
            .x = content_right + 8,
            .y = under_button_box.y + 4,
            .w = under_button_box.x + under_button_box.w - content_right - 12,
            .h = under_button_box.h - 8,
        };
        try self.checks.claim(
            "the window past the record's own content is not empty",
            image.total(covered) > 0,
        );
        try self.checks.count(
            "the ordinary control's own box is covered by the popup",
            image.countColor(covered, dormant_fill),
            image.total(covered),
            image.total(covered),
        );
        try self.checks.count(
            "no ordinary control fill shows through the popup",
            image.countColor(covered, under_button_fill) + image.countColor(covered, under_fill),
            0,
            0,
        );

        // ROUTING at the record's own control and over the bare strip above
        // the ordinary control: both reach the record, neither reaches under.
        const inner_point: [2]f32 = .{
            inner_box.x + inner_box.w / 2,
            inner_box.y + inner_box.h / 2,
        };
        const hit = self.view.frame.hitTestTotal(tree, inner_point) orelse return error.MissedRouting;
        try self.checks.claim(
            "total routing at the record's own control reaches its own subtree",
            descendsFrom(tree, hit, root) and !descendsFrom(tree, hit, under_button),
        );
        const bare_point: [2]f32 = .{ bare.x + bare.w / 2, bare.y + bare.h / 2 };
        const bare_hit = self.view.frame.hitTestTotal(tree, bare_point) orelse return error.MissedRouting;
        try self.checks.claim(
            "total routing over the bare strip reaches the popup, not the control it covers",
            descendsFrom(tree, bare_hit, root) and !descendsFrom(tree, bare_hit, under_button),
        );

        // HANDLERS, through the App's own press and release.
        const under_before = self.view.under_clicks;
        const dormant_before = self.view.dormant_clicks;
        const routed_before = self.view.routed_presses;
        try self.press(inner_point);
        try self.checks.claim(
            "the record's own handler ran exactly once",
            self.view.dormant_clicks == dormant_before + 1,
        );
        try self.checks.claim(
            "the control it covers was not activated",
            self.view.under_clicks == under_before,
        );
        try self.checks.claim(
            "the App routed exactly one press",
            self.view.routed_presses == routed_before + 1,
        );
        try self.checks.claim(
            "the App's own routing named a node inside the popup",
            descendsFrom(tree, self.view.routed_target orelse return error.MissedRouting, root),
        );

        // THE SNAPSHOT, which now has an order to report.
        var snapshot = try nogui.inspection.captureFrame(self.gpa, .{
            .viewport = .{ .x = 0, .y = 0, .w = window_w, .h = window_h },
            .tree = tree,
            .overlay_frame = &self.view.frame,
        });
        defer snapshot.deinit();
        const snap_root = snapshot.findByFrameNodeId(root) orelse return error.MissingSnapshot;
        const snap_inner = snapshot.findByFrameNodeId(inner) orelse return error.MissingSnapshot;
        try self.checks.claim(
            "the snapshot flags it as placed overlay content with an order",
            snap_root.is_overlay and snap_root.overlay_order != null and
                snap_inner.overlay_order != null,
        );
        try self.checks.claim(
            "the snapshot reports it as painted and pressable",
            snap_root.is_visible and snap_root.is_enabled and snap_inner.is_visible,
        );
        const picked = snapshot.pickResult(inner_point);
        try self.checks.claim(
            "the snapshot's pick is exactly the App's own routing answer",
            picked.node != null and picked.node.? == hit,
        );
    }

    /// Read the control's right edge, away from its caption and rounded corners.
    /// The placed frame supplies the positive ring witness; after retirement,
    /// the same strip must contain only the underlying control and its backdrop.
    fn ringCensus(
        self: *Runner,
        pixels: []const f32,
        painted: [4]f32,
        behind: [4]f32,
    ) !struct { window: usize, other: usize } {
        const image: Image = .{ .pixels = pixels, .extent = device_extent };
        const tree = try self.liveTree();
        const box = widget.visualBorderRect(tree, try self.node(key_dormant_button));
        const strip: widget.Rect = .{
            .x = box.x + box.w - ring_strip_w,
            .y = box.y + ring_strip_inset,
            .w = ring_strip_w,
            .h = box.h - ring_strip_inset * 2,
        };
        return .{
            .window = @as(usize, @intFromFloat(strip.w)) *
                @as(usize, @intFromFloat(strip.h)),
            .other = image.countNeitherEdge(strip, painted, behind),
        };
    }
};

/// The fill one of the two competing popups authors.
fn fillOf(name: []const u8) [4]f32 {
    return if (std.mem.eql(u8, name, key_low)) low_fill else high_fill;
}

/// Whether a stage call was refused for the reason this run expected, read off
/// the returned error rather than off anything the frame chose.
fn isInvalidGeometry(staged: anyerror!void) bool {
    staged catch |err| return err == error.InvalidGeometry;
    return false;
}

/// Whether `point` is inside `rect`, with the tree's own edge rule: the left
/// and top edges belong to the box and the right and bottom edges do not.
fn contains(rect: widget.Rect, point: [2]f32) bool {
    return point[0] >= rect.x and point[0] < rect.x + rect.w and
        point[1] >= rect.y and point[1] < rect.y + rect.h;
}

/// The highest raw local layer everything OUTSIDE `excluded` emits, measured
/// with the engine's own function. It is the maximum a band base would start
/// from if that subtree were not in the tree at all, so comparing it with
/// `widget.maximumPaintLayer` says whether the subtree counted.
fn ordinaryMaximum(tree: *const widget.WidgetTree, excluded: FrameNodeId) !u32 {
    var maximum: u32 = 0;
    for (tree.nodes.items) |*node| {
        if (node.paint_hidden) continue;
        if (descendsFrom(tree, node.id, excluded)) continue;
        maximum = @max(maximum, try widget.emittedLocalLayer(node));
    }
    return maximum;
}
