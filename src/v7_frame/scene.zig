//! Frame scene lowering and GPU scene recording, lifted out of the demo.
//!
//! MOVED from `src/v7_demo/window.zig`: `noteSceneGrowth`, `appendControlRect`,
//! `controlFraction`/`controlContrastColor`, `buildSliceRects`,
//! `FramePaint`, `buildFrameScene`, `buildFrameSceneInto`, `hasSceneBorder`,
//! `recordFrameScene`, `recordBlit` (was `recordColorConversion`),
//! `resolveShowcaseBox` (was `svgCardRect`), `devicePixels`, and the material
//! partition constants.
//!
//! What changed in the move, and nothing else:
//!   * `?*SvgScene` / `?*IconCache` became the caller-implemented `OverlaySource`
//!     and `IconSource` interfaces. The demo keeps the librsvg clients.
//!   * The `demo_palette` table became `SceneOptions.palette` (caller-owned).
//!   * `ui.svg_box_id` became `SceneOptions.showcase_box`.
//!   * `svgScene`/`iconCache` pixel-scale wiring stayed in the demo; only
//!     `TextEngine.setPixelScale` is public.
//!   * `text_engine.materials` became `text_engine.materialBuffer()`.
//!   * The per-frame `std.ArrayList(SceneRect).empty` and the throwaway
//!     `draw_cmds` list became `SceneScratch`, whose two lists RETAIN capacity
//!     across frames, so the hot path performs no per-frame heap allocation.
//!
//! Invariants (see the module's callers for the proofs):
//!   I1  Frame-slot coherence. `SceneScratch.beginFrame` captures
//!       `Renderer.nextFrameSlot()` ONCE; build and record both read that
//!       field, so the two can no longer disagree between the two reads.
//!   I2  Material ring disjointness. Decoration materials descend from
//!       `frame_material_base + slot * frame_material_slots` and never below the
//!       text engine's live glyph count; `recordFrameScene` re-checks the
//!       range before lowering.
//!   I7  Texture index liveness. Every `tex_idx` a rect carries is `no_texture`
//!       or an index the caller registered in the same heap the frame binds,
//!       before the bind. A provider returning null (not a stale index) is
//!       what preserves this across a re-raster.
//!   I8  One physical layer. Every scene rect this module emits takes its z
//!       from `widget.effectiveLayer`: the authored local layer raised by the
//!       band overlay placement assigned. Backgrounds, generated control
//!       chrome, glyphs, icons and interaction rings therefore all ride the
//!       band of the node they belong to, and a placed subtree can never be
//!       painted over by the application it covers. Draw commands arrive with
//!       that same resolved layer inside them and are forwarded unchanged, so
//!       no rect is banded twice.
//!   Oklab intermediate, sRGB final. The GUI pass clears and draws in Oklab
//!   (`oklab_clear`, `render_target_format`); `recordBlit` converts on the way out.

const std = @import("std");
const noapi = @import("noapi");
const tracy = @import("tracy");

const nogui = @import("nogui");
const paint = nogui.paint;
const renderer = @import("v7_render");
const text_gpu = @import("text_gpu.zig");

const Renderer = renderer.Renderer;
const SceneRect = renderer.SceneRect;
const TextEngine = text_gpu.TextEngine;
const srgbToOklab = text_gpu.srgbToOklab;

/// Re-exported so a caller can name the ids these entry points take without a
/// second import of the core module for the types alone.
pub const FrameNodeId = nogui.FrameNodeId;
pub const WidgetId = nogui.WidgetId;
const WidgetTree = nogui.WidgetTree;
const Rect = nogui.Rect;
const ClipRect = nogui.widget.ClipRect;
const IconId = nogui.widget.IconId;
/// ONE definition of the physical layer every scene rect paints in: the
/// authored local layer raised by the band overlay placement assigned. Read
/// it instead of `node.paint.layer`, so a placed popup's own chrome, glyphs
/// and rings ride its band and can never be painted over by the application
/// it covers. Checked and typed: an overflow fails the frame.
const effectiveLayer = nogui.widget.effectiveLayer;
const DrawCmd = nogui.drawcmd.DrawCmd;
const visualBorderRect = nogui.visualBorderRect;
const visualContentRect = nogui.visualContentRect;
const sliderThumbRect = nogui.widget.sliderThumbRect;
const sliderVisualLabel = nogui.widget.sliderVisualLabel;
const collectDrawCmdsInto = nogui.drawcmd.collectDrawCmdsInto;

/// The ONE description of how a text-bearing node's caption is laid out and
/// where its glyphs are emitted: the bytes, the request the tree resolved, the
/// box policy its content box implies, and the origin the text pass emits at.
/// `buildSliceRects` builds it, so nothing else reads a caption's geometry from
/// a second set of rules.
const CaptionLayout = struct {
    content: []const u8,
    request: nogui.text.NodeText,
    options: text_gpu.NodeLayoutOptions,
    origin: [2]f32,
};

/// The caption layout one node paints, or null when it paints no text into a
/// non-empty content box. The SAME inset table, `.clip` cap rule and width
/// clamp the text pass applies are applied here, because this IS the text
/// pass's own arithmetic.
fn captionLayout(
    tree: *const WidgetTree,
    n: *const nogui.widget.WidgetNode,
) ?CaptionLayout {
    const content: ?[]const u8 = switch (n.kind) {
        // Buttons emit through their child label node — one text path.
        .label => |l| l.text,
        .slider => sliderVisualLabel(n.kind),
        .checkbox => |c| c.label,
        .switch_control => |s| s.label,
        .radio => |r| r.label,
        .progress => |p| p.label,
        else => null,
    };
    const t = content orelse return null;
    if (t.len == 0) return null;
    // The published request carries the resolved style, inline ranges and
    // foreground for this node. A node without one has nothing to paint.
    const request = n.text_request orelse return null;
    var box = visualContentRect(tree, n.id);
    if (box.w == 0 or box.h == 0) return null;
    // The SAME inset table measure decoration applies, so a caption and
    // its box cannot disagree about where the text column starts.
    const insets = nogui.widget.textInsets(n.kind);
    box.x += insets.leading;
    box.w = @max(0, box.w - insets.leading - insets.trailing);
    box.y += insets.top;
    box.h = @max(0, box.h - insets.top - insets.bottom);
    if (box.w == 0 or box.h == 0) return null;
    // `.clip` is enforced by the node's clip id, not by the request, so a
    // capped clip is the single-line request and an uncapped one flows
    // exactly as `.visible` does.
    const capped_clip = n.text_overflow == .clip and n.text_max_width != null;
    const overflow: nogui.widget.TextOverflow = if (n.text_overflow == .clip and !capped_clip)
        .visible
    else
        n.text_overflow;
    const width: f32 = if (capped_clip or n.text_overflow == .ellipsis)
        @min(box.w, n.text_max_width orelse box.w)
    else
        box.w;
    return .{
        .content = t,
        .request = request.*,
        .options = .{
            .width = width,
            .overflow = overflow,
            .suffix = default_truncation_suffix,
            .box_height = box.h,
        },
        .origin = .{ box.x, box.y },
    };
}

const CounterSink = nogui.CounterSink;

comptime {
    std.debug.assert(@sizeOf(ClipRect) == @sizeOf(renderer.ClipRect));
    std.debug.assert(@alignOf(ClipRect) == @alignOf(renderer.ClipRect));
    std.debug.assert(@offsetOf(ClipRect, "x") == @offsetOf(renderer.ClipRect, "x"));
    std.debug.assert(@offsetOf(ClipRect, "y") == @offsetOf(renderer.ClipRect, "y"));
    std.debug.assert(@offsetOf(ClipRect, "w") == @offsetOf(renderer.ClipRect, "w"));
    std.debug.assert(@offsetOf(ClipRect, "h") == @offsetOf(renderer.ClipRect, "h"));
}

/// render_9slice.zig hard-codes a three-slot ring, and `Renderer.paint_buffers`
/// is a three-element ring indexed by the frame slot. Not advisory.
pub const frames_in_flight: u32 = 3;
/// The shared material buffer's slot count. One source: the text engine's.
pub const material_slots: u32 = text_gpu.max_materials;
/// Glyph materials occupy [1, glyph_material_ceiling); the host owns the
/// ceiling and calls `TextEngine.setGlyphSlotLimit` with it before the first
/// frame.
pub const glyph_material_ceiling: u32 = 1024;
/// Per-frame decoration slots. Each in-flight frame owns one disjoint ring.
pub const frame_material_slots: u32 = 768;
pub const frame_material_base: u32 = glyph_material_ceiling;
comptime {
    std.debug.assert(frame_material_base + frames_in_flight * frame_material_slots < material_slots);
}

/// A scene rect with no bindless texture; the shader's own sentinel.
pub const no_texture: u32 = 0xFFFFFFFF;
/// A scene rect with no clip rect bound.
pub const no_clip: u32 = 0xFFFFFFFF;

/// The offscreen Oklab render target format (the GUI pass's workspace).
/// RGBA16F would halve the blend ROP traffic, but it is BLOCKED on this stack:
/// the shader-object output override is unsupported (Vulkan 341 headers reject
/// the flag/pNext) and the half4 SPIR-V output needs
/// shaderFloat16/storageInputOutput16, which this GTX 1660 Ti driver does not
/// expose (FeatureNotPresent). 32F stays.
pub const render_target_format: noapi.Texture.TextureFormat = .rgba32_float;

/// The modern dark canvas: the Oklab L≈0.20 neutral with a whisper of blue
/// (b < 0) — the deepest surface the cards sit on. Clears the Oklab target.
pub const oklab_clear: [4]f32 = .{ 0.20, 0.0, -0.008, 1.0 };

/// The UTF-8 text placed at a truncation site. Never an implicit ellipsis
/// character: the suffix glyphs come from the same fonts the caption does.
pub const default_truncation_suffix: []const u8 = "...";

/// Scene lowering also forwards the backend's unbounded recording errors
/// (Renderer.preparePaint and command-buffer submission); do not narrow them.
pub const SceneError = anyerror;

/// Caller-implemented showcase overlay. Mirrors the demo's SvgScene.prepare:
/// return a bindless heap index for an exact device-pixel box, or null to draw
/// nothing. Returning null (never a stale index) is what keeps invariant I7.
pub const OverlaySource = struct {
    ctx: *anyopaque,
    prepare: *const fn (ctx: *anyopaque, box: Rect) anyerror!?u32,
};

/// Caller-implemented icon set. Mirrors the demo's IconCache.
pub const IconSource = struct {
    ctx: *anyopaque,
    prepare: *const fn (ctx: *anyopaque) bool,
    index: *const fn (ctx: *anyopaque, icon: IconId) u32,
};

/// The showcase's reserved box: the node whose document the overlay samples.
/// The BORDER box (not the content box) — it is the rect the paint pass fills,
/// so rasterizing at its device size maps the sampled image onto the
/// framebuffer 1:1. `layer` is the card's PHYSICAL layer, so the quad sorts
/// ON TOP of the card's fill — not at the default z=0 behind every box, and
/// not behind a card a placement raised into a band of its own.
pub const ShowcaseBox = struct {
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    layer: u32 = 0,
};

/// Resolves the showcase box for a committed tree. A missing or invisible node
/// yields the zero rect, so the caller draws no overlay quad. The card's layer
/// is resolved through the shared `effectiveLayer`, so a layer space that
/// cannot hold it fails the frame instead of wrapping onto another card's.
/// A DORMANT overlay card yields the zero rect too: no anchor resolved, so no
/// document is sampled for a card that is not on screen.
pub fn resolveShowcaseBox(
    tree: *const WidgetTree,
    box_id: ?FrameNodeId,
) error{ InvalidStyle, PaintLayerOverflow }!ShowcaseBox {
    if (box_id) |id| {
        if (tree.nodeConst(id)) |node| {
            tree.addCounter(.svg_card_node_comparisons, 1);
            if (nogui.widget.isVisible(tree, id) and !node.overlay_dormant) {
                return .{
                    .rect = visualBorderRect(tree, id),
                    .layer = try effectiveLayer(node, 0),
                };
            }
            return .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .layer = 0 };
        }
        // Preserve the old scan for malformed maps that omit a live node.
        for (tree.nodes.items) |*node| {
            tree.addCounter(.svg_card_node_comparisons, 1);
            if (node.id == id) {
                // An indexed lookup can be malformed even when the node is
                // found by the fallback scan. Check it before visibility can
                // turn the invalid tree into a seemingly valid empty card.
                if (tree.nodeConst(id) == null) return error.InvalidStyle;
                if (nogui.widget.isVisible(tree, id) and !node.overlay_dormant) {
                    return .{
                        .rect = visualBorderRect(tree, id),
                        .layer = try effectiveLayer(node, 0),
                    };
                }
                return .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .layer = 0 };
            }
        }
    }
    return .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .layer = 0 };
}

/// One logical window unit expressed in whole device pixels. The overlay's
/// viewports are rasterized at exactly this size so the sampled quad lands on
/// the framebuffer 1:1 — no rescale, no second filter pass.
pub fn devicePixels(logical: f32, scale: f32) u32 {
    if (!(logical > 0) or !std.math.isFinite(logical) or
        !std.math.isFinite(scale) or scale <= 0) return 0;
    return @max(1, @as(u32, @intFromFloat(@round(logical * scale))));
}

/// Caller-supplied inputs to one frame's lowering. Every field is either
/// caller-owned data or an injection point; the module holds no globals.
pub const SceneOptions = struct {
    /// The resolution table for authored `.palette = n` colors. Caller-owned
    /// and only read for the frame's duration. An empty table with a palette
    /// index authored is `error.PaletteOutOfRange`.
    palette: []const paint.Srgb = &.{},
    overlay: ?OverlaySource = null,
    icons: ?IconSource = null,
    /// The icon box in logical window units. A 16-unit viewBox is a caller
    /// convention, not an engine constant.
    icon_logical_size: f32 = 16,
    /// The reserved box the overlay samples. Null draws no overlay.
    showcase_box: ?FrameNodeId = null,
};

/// The retained per-frame scratch. Both lists keep their capacity across
/// frames, so the hot path appends without ever allocating. The scene rects
/// are cleared, not freed, at the start of every frame.
pub const SceneScratch = struct {
    gpa: std.mem.Allocator,
    gui_renderer: *Renderer,
    rects: std.ArrayList(SceneRect) = .empty,
    draw_cmds: std.ArrayList(DrawCmd) = .empty,
    /// Captured ONCE per frame by `beginFrame`; invariant I1.
    frame_slot: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, gui_renderer: *Renderer) SceneScratch {
        return .{ .gpa = gpa, .gui_renderer = gui_renderer };
    }

    pub fn deinit(self: *SceneScratch) void {
        self.rects.deinit(self.gpa);
        self.draw_cmds.deinit(self.gpa);
        self.* = undefined;
    }

    /// Starts a frame: drops the previous frame's rects while retaining the
    /// capacity, and captures the frame slot the build and the record must
    /// both agree on.
    pub fn beginFrame(self: *SceneScratch) void {
        self.rects.clearRetainingCapacity();
        self.frame_slot = self.gui_renderer.nextFrameSlot();
    }

    /// The slot the next record will use. Build and record read the same field.
    pub fn nextFrameSlot(self: *const SceneScratch) u32 {
        return self.frame_slot;
    }
};

/// The frame tree's arena owns converted paint until GPU scene preparation.
/// Must not outlive the App frame that produced `list`.
pub const FramePaint = struct {
    list: paint.PaintList,
    material_end: u32,

    pub fn deinit(self: *FramePaint) void {
        self.list.deinit();
        self.* = undefined;
    }

    /// The authored paint records, borrowed until `deinit`.
    pub fn records(self: *const FramePaint) []const paint.PaintRecord {
        return self.list.records.items;
    }
};

fn noteSceneGrowth(out: *const std.ArrayList(SceneRect), counter_sink: *const CounterSink) void {
    if (out.items.len != out.capacity) return;
    counter_sink.add(.slice_rect_growth_events, 1);
    counter_sink.add(
        .slice_rect_growth_copy_bytes,
        @as(u64, @intCast(out.items.len)) * @sizeOf(SceneRect),
    );
}

fn appendControlRect(
    gpa: std.mem.Allocator,
    text_engine: *TextEngine,
    counter_sink: *const CounterSink,
    out: *std.ArrayList(SceneRect),
    material_slot: *u32,
    material_floor: u32,
    rect: Rect,
    color: [4]f32,
    radius: f32,
    border: f32,
    clip_id: u32,
    layer: u32,
) !void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const corner = @min(radius, @min(rect.w, rect.h) / 2);
    var material_index: u32 = 0;
    if (corner > 0 or border > 0) {
        if (material_slot.* <= material_floor) return error.MaterialCapacity;
        material_slot.* -= 1;
        renderer.GlyphSweeper.writeRoundedRectMaterial(
            text_engine.materialBuffer(),
            material_slot.*,
            corner,
            corner,
            border,
            rect.w,
            rect.h,
            .{ 0, 0, 0, 0 },
        );
        material_index = material_slot.*;
    }
    noteSceneGrowth(out, counter_sink);
    try out.append(gpa, .{
        .dst = .{ rect.x, rect.y, rect.w, rect.h },
        .src = .{ 0, 0, 1, 1 },
        .corners = .{ corner, corner, corner, corner },
        .color = srgbToOklab(color),
        .curve = .{ 0, 0, 0, 0 },
        .material_index = material_index,
        .clip_id = clip_id,
        .origin = .{ rect.x, rect.y },
        .z = layer,
    });
}

fn controlFraction(value: f32, min: f32, max: f32) f32 {
    const range = max - min;
    if (!std.math.isFinite(value) or !std.math.isFinite(min) or
        !std.math.isFinite(max) or !std.math.isFinite(range) or range <= 0)
    {
        return 0;
    }
    return std.math.clamp((value - min) / range, 0, 1);
}

fn controlContrastColor(background: [4]f32) [4]f32 {
    const luminance = 0.2126 * background[0] +
        0.7152 * background[1] +
        0.0722 * background[2];
    return if (luminance > 0.55)
        .{ 0.12, 0.13, 0.15, 1 }
    else
        .{ 0.96, 0.96, 0.98, 1 };
}

/// Emit control decorations, text, and the sampled overlay art. Widget
/// backgrounds and custom canvas commands are lowered from PaintList by
/// Renderer.preparePaint. Decoration materials descend inside this
/// in-flight frame's slot partition.
///
/// Every rect this emits reads its z from the node's `effectiveLayer` — the
/// authored local layer raised by the band placement assigned — so generated
/// chrome, glyphs and interaction rings of a placed popup paint in that
/// popup's band and never at the default z=0 behind the application it
/// covers. The authored `paint.layer` is never mutated, and each node's
/// layer is resolved once and shared by all the rects it emits.
pub fn buildSliceRects(
    scratch: *SceneScratch,
    text_engine: *TextEngine,
    options: SceneOptions,
    material_floor: u32,
    material_end: *u32,
    tree: *const WidgetTree,
    hover_id: ?WidgetId,
    hover_alpha: f32,
    focus_id: ?WidgetId,
) SceneError!void {
    const gpa = scratch.gpa;
    const out = &scratch.rects;
    const counter_sink = text_engine.counterSink();
    const zone = tracy.Zone.begin(.{ .name = "buildSliceRects", .src = @src() });
    defer zone.end();
    // Text glyphs occupy [1, glyph_material_ceiling). Decorations descend from
    // this frame's exclusive ceiling. PaintList materials ascend from
    // material_floor and cannot overlap them.
    var material_slot = material_floor + frame_material_slots;

    // DORMANT OVERLAY CONTENT. A registered record no anchor resolved leaves
    // its subtree laid out and authored visible, and none of it is on screen.
    // Every pass below skips those nodes, exactly as the draw-command
    // collector and `input.hitTest` do, by the node's own `overlay_dormant`
    // flag: one flag for fills, chrome, glyphs, icons and rings alike, so they
    // cannot disagree with each other about a dismissed popup.
    // Slider progress and thumbs paint before glyphs so a thumb never covers
    // the slider's own visible label.
    for (tree.nodes.items) |*n| {
        if (n.paint_hidden or n.overlay_dormant) continue;
        if (n.kind != .slider) continue;
        const s = n.kind.slider;
        const r = visualBorderRect(tree, n.id);
        if (r.w <= 0 or r.h <= 0) continue;
        // Progress and thumb are the same control, so they share one
        const layer = try effectiveLayer(n, 0);
        // A max <= min slider has no valid range: 0/0 (or overflow) would
        // yield NaN/inf and poison the progress or thumb rect. Center both.
        const range = s.max - s.min;
        const frac = std.math.clamp(if (range <= 0) 0.5 else (s.value.* - s.min) / range, 0, 1);
        const progress_w = frac * r.w;
        if (progress_w > 0) {
            const progress_radius: f32 = @min(2, r.h / 2);
            if (material_slot <= material_floor) return error.MaterialCapacity;
            material_slot -= 1;
            renderer.GlyphSweeper.writeRoundedRectMaterial(
                text_engine.materialBuffer(),
                material_slot,
                progress_radius,
                progress_radius,
                0,
                progress_w,
                r.h,
                .{ 0, 0, 0, 0 },
            );
            noteSceneGrowth(out, counter_sink);
            try out.append(gpa, .{
                .dst = .{ r.x, r.y, progress_w, r.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ progress_radius, progress_radius, progress_radius, progress_radius },
                .color = srgbToOklab(s.color),
                .curve = .{ 0, 0, 0, 0 },
                .material_index = material_slot,
                .clip_id = n.paint_clip_id,
                .origin = .{ r.x, r.y },
                .z = layer,
            });
        }

        const thumb = sliderThumbRect(r, frac);
        if (thumb.w <= 0 or thumb.h <= 0) continue;
        const thumb_radius: f32 = @min(3, @min(thumb.w, thumb.h) / 2);
        if (material_slot <= material_floor) return error.MaterialCapacity;
        material_slot -= 1;
        renderer.GlyphSweeper.writeRoundedRectMaterial(
            text_engine.materialBuffer(),
            material_slot,
            thumb_radius,
            thumb_radius,
            0,
            thumb.w,
            thumb.h,
            .{ 0, 0, 0, 0 },
        );
        noteSceneGrowth(out, counter_sink);
        try out.append(gpa, .{
            .dst = .{ thumb.x, thumb.y, thumb.w, thumb.h },
            .src = .{ 0, 0, 1, 1 },
            .corners = .{ thumb_radius, thumb_radius, thumb_radius, thumb_radius },
            .color = srgbToOklab(.{ 0.82, 0.82, 0.85, 1 }),
            .curve = .{ 0, 0, 0, 0 },
            .material_index = material_slot,
            .clip_id = n.paint_clip_id,
            .origin = .{ thumb.x, thumb.y },
            .z = layer,
        });
    }
    // Native controls paint their semantic state before the label pass.
    for (tree.nodes.items) |*n| {
        if (n.paint_hidden or n.overlay_dormant) continue;
        switch (n.kind) {
            .checkbox, .switch_control, .radio, .progress, .separator => {},
            else => continue,
        }
        const content = visualContentRect(tree, n.id);
        if (content.w <= 0 or content.h <= 0) continue;
        // One resolution per control, shared by its fill, mark, thumb,
        // track and fill bar: the authored local layer raised by the band
        // placement assigned, so generated chrome rides its own control.
        const layer = try effectiveLayer(n, 0);
        switch (n.kind) {
            .checkbox => |control| {
                const size = @min(
                    nogui.widget.control_indicator_size,
                    @min(content.w, content.h),
                );
                const box = Rect{
                    .x = content.x,
                    .y = content.y + (content.h - size) / 2,
                    .w = size,
                    .h = size,
                };
                try appendControlRect(
                    gpa,
                    text_engine,
                    counter_sink,
                    out,
                    &material_slot,
                    material_floor,
                    box,
                    .{ 0.12, 0.13, 0.15, 1 },
                    3,
                    0,
                    n.paint_clip_id,
                    layer,
                );
                try appendControlRect(
                    gpa,
                    text_engine,
                    counter_sink,
                    out,
                    &material_slot,
                    material_floor,
                    box,
                    .{ 0.67, 0.69, 0.73, 1 },
                    3,
                    1,
                    n.paint_clip_id,
                    layer,
                );
                if (control.value.*) {
                    const inset = @min(1.5, size / 8);
                    const inner = Rect{
                        .x = box.x + inset,
                        .y = box.y + inset,
                        .w = @max(0, size - inset * 2),
                        .h = @max(0, size - inset * 2),
                    };
                    try appendControlRect(
                        gpa,
                        text_engine,
                        counter_sink,
                        out,
                        &material_slot,
                        material_floor,
                        inner,
                        control.color,
                        2,
                        0,
                        n.paint_clip_id,
                        layer,
                    );
                    const unit = size / 8;
                    const mark = [_]Rect{
                        .{ .x = box.x + unit, .y = box.y + 2 * unit, .w = unit, .h = unit },
                        .{ .x = box.x + 2 * unit, .y = box.y + 3 * unit, .w = unit, .h = unit },
                        .{ .x = box.x + 3 * unit, .y = box.y + 4 * unit, .w = unit, .h = unit },
                        .{ .x = box.x + 4 * unit, .y = box.y + 3 * unit, .w = unit, .h = unit },
                        .{ .x = box.x + 5 * unit, .y = box.y + 2 * unit, .w = unit, .h = unit },
                        .{ .x = box.x + 6 * unit, .y = box.y + unit, .w = unit, .h = unit },
                    };
                    const mark_color = controlContrastColor(control.color);
                    for (mark) |segment| {
                        try appendControlRect(
                            gpa,
                            text_engine,
                            counter_sink,
                            out,
                            &material_slot,
                            material_floor,
                            segment,
                            mark_color,
                            0,
                            0,
                            n.paint_clip_id,
                            layer,
                        );
                    }
                }
            },
            .switch_control => |control| {
                const track_width = @min(nogui.widget.switch_track_width, content.w);
                const track_height = @min(nogui.widget.control_indicator_size, content.h);
                const track = Rect{
                    .x = content.x,
                    .y = content.y + (content.h - track_height) / 2,
                    .w = track_width,
                    .h = track_height,
                };
                const track_color: [4]f32 = if (control.value.*)
                    control.color
                else
                    .{ 0.32, 0.34, 0.38, 1 };
                try appendControlRect(
                    gpa,
                    text_engine,
                    counter_sink,
                    out,
                    &material_slot,
                    material_floor,
                    track,
                    track_color,
                    track_height / 2,
                    0,
                    n.paint_clip_id,
                    layer,
                );
                const thumb_size = @min(14, @min(track_height, track_width));
                const thumb_inset = @min(2, @max(0, (track_width - thumb_size) / 2));
                const thumb_x = track.x + (if (control.value.*)
                    track_width - thumb_size - thumb_inset
                else
                    thumb_inset);
                const thumb = Rect{
                    .x = thumb_x,
                    .y = track.y + (track.h - thumb_size) / 2,
                    .w = thumb_size,
                    .h = thumb_size,
                };
                try appendControlRect(
                    gpa,
                    text_engine,
                    counter_sink,
                    out,
                    &material_slot,
                    material_floor,
                    thumb,
                    controlContrastColor(track_color),
                    thumb_size / 2,
                    0,
                    n.paint_clip_id,
                    layer,
                );
            },
            .radio => |control| {
                const size = @min(
                    nogui.widget.control_indicator_size,
                    @min(content.w, content.h),
                );
                const outer = Rect{
                    .x = content.x,
                    .y = content.y + (content.h - size) / 2,
                    .w = size,
                    .h = size,
                };
                try appendControlRect(
                    gpa,
                    text_engine,
                    counter_sink,
                    out,
                    &material_slot,
                    material_floor,
                    outer,
                    .{ 0.12, 0.13, 0.15, 1 },
                    size / 2,
                    0,
                    n.paint_clip_id,
                    layer,
                );
                try appendControlRect(
                    gpa,
                    text_engine,
                    counter_sink,
                    out,
                    &material_slot,
                    material_floor,
                    outer,
                    .{ 0.67, 0.69, 0.73, 1 },
                    size / 2,
                    1,
                    n.paint_clip_id,
                    layer,
                );
                if (control.selected.* == control.option) {
                    const dot_size = @max(0, @min(8, size - 4));
                    const dot = Rect{
                        .x = outer.x + (size - dot_size) / 2,
                        .y = outer.y + (size - dot_size) / 2,
                        .w = dot_size,
                        .h = dot_size,
                    };
                    try appendControlRect(
                        gpa,
                        text_engine,
                        counter_sink,
                        out,
                        &material_slot,
                        material_floor,
                        dot,
                        control.color,
                        dot_size / 2,
                        0,
                        n.paint_clip_id,
                        layer,
                    );
                }
            },
            .progress => |control| {
                const track_height = @min(8, content.h);
                const track = Rect{
                    .x = content.x,
                    .y = content.y + content.h - track_height,
                    .w = content.w,
                    .h = track_height,
                };
                try appendControlRect(
                    gpa,
                    text_engine,
                    counter_sink,
                    out,
                    &material_slot,
                    material_floor,
                    track,
                    .{ 0.22, 0.23, 0.26, 1 },
                    track_height / 2,
                    0,
                    n.paint_clip_id,
                    layer,
                );
                const fraction = controlFraction(control.value, control.min, control.max);
                const fill = Rect{ .x = track.x, .y = track.y, .w = fraction * track.w, .h = track.h };
                try appendControlRect(
                    gpa,
                    text_engine,
                    counter_sink,
                    out,
                    &material_slot,
                    material_floor,
                    fill,
                    control.color,
                    track_height / 2,
                    0,
                    n.paint_clip_id,
                    layer,
                );
            },
            .separator => |control| {
                if (!std.math.isFinite(control.thickness) or control.thickness <= 0) continue;
                switch (control.axis) {
                    .horizontal => {
                        const thickness = @min(control.thickness, content.h);
                        try appendControlRect(
                            gpa,
                            text_engine,
                            counter_sink,
                            out,
                            &material_slot,
                            material_floor,
                            .{
                                .x = content.x,
                                .y = content.y + (content.h - thickness) / 2,
                                .w = content.w,
                                .h = thickness,
                            },
                            control.color,
                            0,
                            0,
                            n.paint_clip_id,
                            layer,
                        );
                    },
                    .vertical => {
                        const thickness = @min(control.thickness, content.w);
                        try appendControlRect(
                            gpa,
                            text_engine,
                            counter_sink,
                            out,
                            &material_slot,
                            material_floor,
                            .{
                                .x = content.x + (content.w - thickness) / 2,
                                .y = content.y,
                                .w = thickness,
                                .h = content.h,
                            },
                            control.color,
                            0,
                            0,
                            n.paint_clip_id,
                            layer,
                        );
                    },
                }
            },
            else => {},
        }
    }

    // Hover outline: a 2px rounded ring around the hovered node (type-2
    // ring material — the SDF punches the interior), painted before the
    // glyphs so it never overdraws the text at the box edges. The ring
    // belongs to the node it outlines, so it paints in that node's band.
    if (hover_id) |hid| {
        hover_outline: {
            const frame_id = tree.frameNode(hid) orelse break :hover_outline;
            const n = tree.nodeConst(frame_id) orelse break :hover_outline;
            counter_sink.add(.hover_focus_node_comparisons, 1);
            const r = visualBorderRect(tree, n.id);
            if (r.w <= 0 or r.h <= 0) break :hover_outline;
            // A node nothing placed is not on screen, so it is not ringed
            // either: the same flag the paint and hit walks read.
            if (n.overlay_dormant) break :hover_outline;
            const layer = try effectiveLayer(n, 0);
            const ring_rx: f32 = @max(n.paint.radius.left, n.paint.radius.right);
            const ring_ry: f32 = @max(n.paint.radius.top, n.paint.radius.bottom);
            if (material_slot <= material_floor) return error.MaterialCapacity;
            material_slot -= 1;
            renderer.GlyphSweeper.writeRoundedRectMaterial(
                text_engine.materialBuffer(),
                material_slot,
                ring_rx,
                ring_ry,
                2,
                r.w,
                r.h,
                .{ 0, 0, 0, 0 },
            );
            noteSceneGrowth(out, counter_sink);
            try out.append(gpa, .{
                .dst = .{ r.x, r.y, r.w, r.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{
                    n.paint.radius.left,
                    n.paint.radius.right,
                    n.paint.radius.top,
                    n.paint.radius.bottom,
                },
                // Amber ring fades in by hover_alpha (the core eases it);
                // hover_alpha 1 reproduces the solid ring.
                .color = srgbToOklab(.{ 1.0, 0.8, 0.2, hover_alpha }),
                .curve = .{ 0, 0, 0, 0 },
                .material_index = material_slot,
                .clip_id = n.paint_clip_id,
                .origin = .{ r.x, r.y },
                .z = layer,
            });
        }
    }

    // Focus ring: a 2px cyan rounded ring around the keyboard-focused node.
    // Like the hover ring it rides its own node's resolved band, so a
    // focused control inside a placed popup is never ringed behind it.
    if (focus_id) |fid| {
        focus_outline: {
            const frame_id = tree.frameNode(fid) orelse break :focus_outline;
            const n = tree.nodeConst(frame_id) orelse break :focus_outline;
            counter_sink.add(.hover_focus_node_comparisons, 1);
            const r = visualBorderRect(tree, n.id);
            if (r.w <= 0 or r.h <= 0) break :focus_outline;
            // A control inside a dismissed popup is neither painted nor
            // pressable, and a ring around it would be the only thing left of
            // it on screen: the same flag the paint and hit walks read.
            if (n.overlay_dormant) break :focus_outline;
            const layer = try effectiveLayer(n, 0);
            const ring_rx: f32 = @max(n.paint.radius.left, n.paint.radius.right);
            const ring_ry: f32 = @max(n.paint.radius.top, n.paint.radius.bottom);
            if (material_slot <= material_floor) return error.MaterialCapacity;
            material_slot -= 1;
            renderer.GlyphSweeper.writeRoundedRectMaterial(
                text_engine.materialBuffer(),
                material_slot,
                ring_rx,
                ring_ry,
                2,
                r.w,
                r.h,
                .{ 0, 0, 0, 0 },
            );
            noteSceneGrowth(out, counter_sink);
            try out.append(gpa, .{
                .dst = .{ r.x, r.y, r.w, r.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{
                    n.paint.radius.left,
                    n.paint.radius.right,
                    n.paint.radius.top,
                    n.paint.radius.bottom,
                },
                .color = srgbToOklab(.{ 0.25, 0.85, 0.85, 1 }),
                .curve = .{ 0, 0, 0, 0 },
                .material_index = material_slot,
                .clip_id = n.paint_clip_id,
                .origin = .{ r.x, r.y },
                .z = layer,
            });
        }
    }

    for (tree.nodes.items) |*n| {
        if (n.paint_hidden or n.overlay_dormant) continue;
        const caption = captionLayout(tree, n) orelse continue;
        // The node's clip id (stamped by collectDrawCmds): glyphs inside
        // a `.clip` container are clipped to its rect like any other cmd.
        // The node's RESOLVED layer stamps the glyphs' z: a layered node's
        // text must ride its OWN layer (the layer-1 badge's caption would
        // otherwise sort below the badge's z=1 fill and vanish behind it),
        // and a placed node's caption must ride the band that covers the
        // application — the same key its fill and its chrome use.
        const layer = try effectiveLayer(n, 0);
        const before = out.items.len;
        try text_engine.emitNodeText(
            caption.content,
            caption.request,
            caption.options,
            caption.origin[0],
            caption.origin[1],
            n.clip_id,
            layer,
            out,
        );
        if (layer > 0) {
            for (out.items[before..]) |*r| r.z = layer;
        }
    }

    // Transport icons: one bindless-sampled quad per icon button. The
    // rasters are the caller's coverage masks, uploaded in the pipeline's
    // Oklab space, so the button's Oklab color tints the sample.
    if (options.icons) |icons| {
        if (icons.prepare(icons.ctx)) {
            for (tree.nodes.items) |*n| {
                if (n.paint_hidden or n.overlay_dormant) continue;
                const button = switch (n.kind) {
                    .button => |b| b,
                    else => continue,
                };
                const icon = button.icon orelse continue;
                const content = visualContentRect(tree, n.id);
                if (content.w <= 0 or content.h <= 0) continue;
                const index = icons.index(icons.ctx, icon);
                if (index == no_texture) continue;
                // The raster is the whole viewBox, so the quad is the icon
                // box itself; a button narrower than the icon shrinks the
                // quad rather than overflowing it. The quad rides the
                // button's resolved layer, so an icon inside a placed
                // popup is never sampled behind the card it covers.
                const side = @min(options.icon_logical_size, @min(content.w, content.h));
                const ox = content.x + (content.w - side) / 2;
                const oy = content.y + (content.h - side) / 2;
                noteSceneGrowth(out, counter_sink);
                try out.append(gpa, .{
                    .dst = .{ ox, oy, side, side },
                    .src = .{ 0, 0, 1, 1 },
                    .corners = .{ 0, 0, 0, 0 },
                    .color = srgbToOklab(button.color),
                    .curve = .{ 0, 0, 0, 0 },
                    .material_index = 0,
                    .clip_id = n.clip_id,
                    .origin = .{ ox, oy },
                    .tex_idx = index,
                    .z = try effectiveLayer(n, 0),
                });
            }
        }
    }

    // The showcase overlay: the caller's document rasterized for the reserved
    // box's device-pixel size and sampled as one quad over the box. The raster
    // IS the box's device-pixel size, so the document's viewBox fit and its
    // clip happen in the rasterizer and the sampler never rescales. The
    // re-raster runs only when the box's device size or the display scale
    // changed.
    if (options.overlay) |overlay| {
        const card = try resolveShowcaseBox(tree, options.showcase_box);
        const box = card.rect;
        if (box.w > 0 and box.h > 0) {
            if (try overlay.prepare(overlay.ctx, box)) |index| {
                noteSceneGrowth(out, counter_sink);
                try out.append(gpa, .{
                    .dst = .{ box.x, box.y, box.w, box.h },
                    .src = .{ 0, 0, 1, 1 },
                    .corners = .{ 0, 0, 0, 0 },
                    .color = .{ 1, 1, 1, 1 },
                    .curve = .{ 0, 0, 0, 0 },
                    .material_index = 0,
                    .clip_id = no_clip,
                    .origin = .{ box.x, box.y },
                    .tex_idx = index,
                    // Paint ON the card: the default z=0 would sort the
                    // quad BEHIND the card's fill (every box layer > 0).
                    // `card.layer` is ALREADY the card's resolved physical
                    // layer, band included, so it is forwarded as resolved
                    // and never banded a second time here.
                    .z = card.layer,
                });
            }
        }
    }

    // The v1 bag contract: stamp the submission counter — the stable
    // tiebreaker the CS1 sort keys on. The paint order IS the append
    // order; reversing the bag (--gpu-sort-verify) changes the buffer
    // positions but not the counters, so the sort restores the paint
    // order. Stamped at the END so the overlay injection's rects (appended
    // after the tree pass) get their true positions too.
    for (out.items, 0..) |*r, i| r.order = @intCast(i);
    material_end.* = material_slot;
}

/// Collect each authored primitive once; text and controls remain scene rects.
/// Appends the frame's slice rects into `scratch.rects` and returns the
/// converted paint list. The caller must call `scratch.beginFrame` first.
pub fn buildFrameScene(
    scratch: *SceneScratch,
    text_engine: *TextEngine,
    options: SceneOptions,
    frame: *const nogui.FrameOutput,
    gpu_sort_verify: bool,
) SceneError!FramePaint {
    const gpa = scratch.gpa;
    const out = &scratch.rects;
    const draw_cmds = &scratch.draw_cmds;
    // The draw-command list is retained, not reallocated, so the reservation
    // is a no-op once the tree's requirement is already covered. It stays
    // per frame because the requirement is per tree, and it must not move
    // the list's buffer between a build and its record.
    try draw_cmds.ensureTotalCapacity(gpa, nogui.drawcmd.requiredCapacity(frame.tree) catch
        return error.OutOfMemory);
    try collectDrawCmdsInto(
        @constCast(frame.tree),
        frame.pressed,
        frame.press_alpha,
        draw_cmds,
    );
    var list = paint.PaintList.init(frame.tree.allocator, options.palette, draw_cmds.items.len);
    errdefer list.deinit();
    // One authored primitive per draw command: an image samples a bound
    // texture, a path runs the curve fill/stroke, everything else is a
    // painted rect. PaintList keeps the submission order either way.
    //
    // The layer travels INSIDE each command: `collectDrawCmdsInto` already
    // stamped it through `widget.effectiveLayer`, band included. This pass
    // only converts, so a placed subtree's background, custom rect, path and
    // image are forwarded as resolved and are never banded a second time.
    for (draw_cmds.items) |*draw_cmd| {
        if (draw_cmd.image_paint) |image| {
            try list.addImage(image);
        } else if (draw_cmd.path_paint) |path_spec| {
            try list.addPath(path_spec);
        } else {
            try list.addRect(draw_cmd.rect_paint);
        }
    }
    const frame_slot = scratch.nextFrameSlot();
    if (frame_slot >= frames_in_flight) return error.InvalidFrameSlot;
    const material_floor = frame_material_base + frame_slot * frame_material_slots;
    // SAFETY: buildSliceRects writes material_end on every success path; the
    // call below returns on failure, so it is always set before the struct read.
    var material_end: u32 = undefined;
    try buildSliceRects(
        scratch,
        text_engine,
        options,
        material_floor,
        &material_end,
        frame.tree,
        frame.hover,
        frame.hover_alpha,
        frame.focus,
    );
    const background_count = std.math.cast(u32, draw_cmds.items.len) orelse
        return error.SceneCapacity;
    for (out.items) |*rect| {
        rect.order = std.math.add(u32, rect.order, background_count) catch
            return error.SceneCapacity;
    }
    if (gpu_sort_verify) std.mem.reverse(SceneRect, out.items);
    return .{ .list = list, .material_end = material_end };
}

fn hasSceneBorder(sides: paint.SceneBorders) bool {
    for (sides) |side| {
        if (side.width > 0 and side.style != .none) return true;
    }
    return false;
}

/// The recording inputs. `arena` is the scratch the lowering allocates from:
/// the demo passes the frame tree's arena, so every byte dies with the frame
/// that owns the tree. Pass any arena; it must outlive the recorded commands'
/// use of the buffers, which is only this call.
pub const RecordContext = struct {
    arena: std.mem.Allocator,
    renderer: *Renderer,
    text: *const TextEngine,
    /// Refines the permutation from `lowerPaint` for verification only.
    verify_sort: bool = false,
    logical: nogui.geometry.WindowSize,
    device: noapi.Extent2D,
    /// The GUI texture heap (the bindless textures the fragment shader
    /// samples) — bound ONCE per frame before the renderer draw; the blit
    /// pass binds its own heap later.
    texture_heap: noapi.DescriptorHeap,
    /// `frame.tree.clip_rects[0..frame.tree.clip_count]`.
    clips: []const ClipRect,
};

/// Render one app frame into the offscreen Oklab target. Shared by the
/// presented runner (which follows it with the blit pass) and the shot
/// runner (which reads back). Returns the sort's output rects when
/// `verify_sort` is set, and empty otherwise.
pub fn recordFrameScene(
    context: *const RecordContext,
    cmd: *noapi.CommandBuffer,
    scratch: *const SceneScratch,
    slice_rects: []const SceneRect,
    frame_paint: *const FramePaint,
    render_target: noapi.TextureHandle,
) SceneError![]const SceneRect {
    const arena = context.arena;
    const gui_renderer = context.renderer;
    const text_engine = context.text;
    const zone = tracy.Zone.begin(.{ .name = "renderPass1", .src = @src() });
    defer zone.end();
    const device_w: f32 = @floatFromInt(context.device.width);
    const device_h: f32 = @floatFromInt(context.device.height);

    // Lower all authored paint before entering dynamic rendering. The
    // preflight rejects scene, material, and path capacity before GPU present.
    var rect_capacity = slice_rects.len;
    var curve_capacity: usize = 0;
    for (frame_paint.list.records.items) |record| {
        switch (record.shape) {
            .rect => |shape| {
                const filled: usize = @intFromBool(shape.fill != null);
                const decorations = std.math.add(usize, shape.shadows.len, filled) catch
                    return error.SceneCapacity;
                const border: usize = @intFromBool(hasSceneBorder(shape.borders));
                const with_border = std.math.add(usize, decorations, border) catch
                    return error.SceneCapacity;
                rect_capacity = std.math.add(usize, rect_capacity, with_border) catch
                    return error.SceneCapacity;
            },
            .path => |shape| {
                rect_capacity = std.math.add(usize, rect_capacity, @as(usize, @intFromBool(shape.fill != null)) +
                    @as(usize, @intFromBool(shape.stroke != null))) catch
                    return error.SceneCapacity;
                const passes: usize = @intFromBool(shape.fill != null) +
                    @as(usize, @intFromBool(shape.stroke != null));
                const curves = std.math.mul(usize, shape.path.commands.len, 64) catch
                    return error.TessellationCapacity;
                curve_capacity = std.math.add(usize, curve_capacity, std.math.mul(usize, curves, passes) catch
                    return error.TessellationCapacity) catch
                    return error.TessellationCapacity;
            },
            .image => {
                // A textured image is one quad, and the renderer emits none
                // for an empty box, so the preflight counts the same way.
                if (record.bounds.w > 0 and record.bounds.h > 0) {
                    rect_capacity = std.math.add(usize, rect_capacity, 1) catch
                        return error.SceneCapacity;
                }
            },
        }
    }
    curve_capacity = @min(curve_capacity, 16_384);
    const rect_scratch = try arena.alloc(SceneRect, rect_capacity);
    const curve_scratch = try arena.alloc(nogui.path.Quadratic, curve_capacity);
    const frame_slot = scratch.nextFrameSlot();
    const material_floor = frame_material_base + frame_slot * frame_material_slots;
    if (frame_paint.material_end < material_floor or
        frame_paint.material_end > material_floor + frame_material_slots)
        return error.MaterialCapacity;
    const range: renderer.MaterialRange = .{
        .first = material_floor,
        .end = frame_paint.material_end,
    };
    const rich_primitives = rect_capacity - slice_rects.len;
    const material_capacity = @min(rich_primitives, range.end - range.first);
    const material_scratch = try arena.alloc(renderer.PaintMaterial, material_capacity);
    try gui_renderer.preparePaint(cmd, .{
        .legacy_rects = slice_rects,
        .records = frame_paint.list.records.items,
        .clips = @ptrCast(context.clips),
    }, .{
        .rects = rect_scratch,
        .curves = curve_scratch,
        .materials = material_scratch,
        .material_buffer = text_engine.materialBuffer(),
        .material_slots = material_slots,
        .range = range,
        .frame_slot = frame_slot,
    });
    const verified_rects: []const SceneRect = if (context.verify_sort)
        (try renderer.lowerPaint(
            slice_rects,
            frame_paint.list.records.items,
            rect_scratch,
            curve_scratch,
            material_scratch,
            range,
        )).rects
    else
        &.{};

    cmd.beginRendering(.{ .color_attachments = &.{
        .{
            .texture = render_target,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = oklab_clear,
        },
    }, .render_area_size = .{ context.device.width, context.device.height } });

    // The v1 general blending pipeline (spec §4): ONE uniform alpha blend
    // for every drawable — translucency is a material/color property,
    // never a pipeline switch. src_alpha/one_minus_src_alpha (the
    // straight-alpha convention: the blend scales the source rgb by the
    // source alpha, so the SDF branches' coverage × color and the solid
    // branch's straight output are both correct without shader-side
    // premultiplication).
    cmd.setBlendState(.{
        .enable = true,
        .color_op = .add,
        .src_color_factor = .src_alpha,
        .dst_color_factor = .one_minus_src_alpha,
        .alpha_op = .add,
        .src_alpha_factor = .one,
        .dst_alpha_factor = .one_minus_src_alpha,
    });
    // Bind the GUI texture heap (set 0 = app-registered textures, set 2 =
    // samplers) — ONE call; bindings are not draws, so the one-draw
    // invariant holds. The blit pass re-binds its own heap afterwards.
    cmd.bindDescriptorSets(context.texture_heap);
    // Renderer.draw records the one indirect GUI draw inside the pass.
    gui_renderer.draw(
        cmd,
        context.logical.width,
        context.logical.height,
        device_w,
        device_h,
    );
    cmd.setBlendEnable(false);
    cmd.endRendering();
    return verified_rects;
}

/// Records the Oklab -> sRGB fullscreen pass. MOVED from the demo's
/// `recordColorConversion`; the shader pair is the caller's.
pub fn recordBlit(
    cmd: *noapi.CommandBuffer,
    destination: noapi.TextureHandle,
    device_extent: noapi.Extent2D,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    blit_heap: noapi.DescriptorHeap,
) void {
    cmd.beginRendering(.{ .color_attachments = &.{
        .{
            .texture = destination,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ 0, 0, 0, 1 },
        },
    }, .render_area_size = .{ device_extent.width, device_extent.height } });

    cmd.setShaders(blit_vert, blit_frag);
    cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
    cmd.bindDescriptorSets(blit_heap);
    cmd.setBlendEnable(false);
    cmd.draw(noapi.PushData{}, 3, 1);
    cmd.endRendering();
}

test "resolveShowcaseBox preserves malformed-map fallback and missing-ID default" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const id: FrameNodeId = @fromBackingInt(@intCast(1));
    const unrelated_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const expected_rect: Rect = .{ .x = 5, .y = 7, .w = 30, .h = 20 };
    try tree.appendNode(.{
        .id = id,
        .kind = .{ .spacer = .{} },
        .parent = .root,
        .rect = expected_rect,
        .paint = .{ .layer = 7 },
    });

    const card = try resolveShowcaseBox(&tree, id);
    try std.testing.expectEqual(expected_rect, card.rect);
    try std.testing.expectEqual(@as(u32, 7), card.layer);

    // A placed card's document quad rides the card's band, so it stays on
    // the fill it covers instead of falling back to the app's z=0 plane.
    // The authored layer itself is untouched.
    tree.node(id).?.placement_paint = .{
        .record_index = 0,
        .layer = 40,
        .order = 1,
    };
    const placed = try resolveShowcaseBox(&tree, id);
    try std.testing.expectEqual(@as(u32, 47), placed.layer);
    try std.testing.expectEqual(@as(u32, 7), tree.nodeConst(id).?.paint.layer);
    tree.node(id).?.placement_paint = null;

    // A malformed map that omits the live node: the fallback scan finds it
    // and the indexed re-check rejects the tree.
    try std.testing.expect(tree.id_index.remove(id));
    try tree.id_index.put(tree.allocator, unrelated_id, 0);
    try std.testing.expectError(error.InvalidStyle, resolveShowcaseBox(&tree, id));

    const missing = try resolveShowcaseBox(&tree, @fromBackingInt(@intCast(99)));
    try std.testing.expectEqual(
        ShowcaseBox{
            .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .layer = 0,
        },
        missing,
    );

    // A null id is the same empty card, without touching the tree.
    try std.testing.expectEqual(missing, try resolveShowcaseBox(&tree, null));
}

test "scene append counters record allocation growth" {
    var counters: nogui.Counters = .{};
    var sink = CounterSink.init(&counters);
    var rects: std.ArrayList(SceneRect) = .empty;
    defer rects.deinit(std.testing.allocator);
    noteSceneGrowth(&rects, &sink);
    try rects.append(std.testing.allocator, .{
        .dst = .{ 0, 0, 0, 0 },
        .src = .{ 0, 0, 1, 1 },
        .corners = .{ 0, 0, 0, 0 },
        .color = .{ 0, 0, 0, 1 },
        .curve = .{ 0, 0, 0, 0 },
        .material_index = 0,
    });
    const snapshot = try counters.snapshot();
    if (comptime nogui.options.perf_counters) {
        try std.testing.expectEqual(@as(u64, 1), snapshot.value(.slice_rect_growth_events));
        try std.testing.expectEqual(
            @as(u64, 0),
            snapshot.value(.slice_rect_growth_copy_bytes),
        );
    } else {
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.slice_rect_growth_events));
        try std.testing.expectEqual(@as(u64, 0), snapshot.value(.slice_rect_growth_copy_bytes));
    }
}
