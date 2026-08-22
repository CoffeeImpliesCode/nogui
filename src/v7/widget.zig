//! v7 widget types — geometry, per-child flex data, kind union, and the
//! per-frame widget tree.
//! Per the prototype spec (notes/v7-prototype-spec.md §2).
const std = @import("std");

const Id = @import("id.zig").Id;
const callback = @import("callback.zig");
const style = @import("style.zig");

pub const Style = style.Style;
pub const PaintStyle = style.PaintStyle;
pub const StyleOverride = style.StyleOverride;
pub const PaintStyleOverride = style.PaintStyleOverride;
pub const Display = style.Display;
pub const FlexDirection = style.FlexDirection;
pub const Justify = style.Justify;
pub const Align = style.Align;
pub const BoxSizing = style.BoxSizing;
pub const Sides = style.Sides;
pub const Dimension = style.Dimension;
pub const LengthPercentage = style.LengthPercentage;
pub const LengthPercentageAuto = style.LengthPercentageAuto;
pub const TypedSize = style.Size;
pub const TypedRect = style.Rect;
pub const Insets = style.Insets;
pub const Overflow = style.Overflow;
pub const OverflowAxes = style.OverflowAxes;
pub const ResolvedStyle = style.ResolvedStyle;
pub const ResolvedDimensions = style.ResolvedDimensions;
pub const ResolvedConstraints = style.ResolvedConstraints;
pub const ResolvedInsets = style.ResolvedInsets;
pub const DimensionSize = style.DimensionSize;
pub const LengthPercentageSize = style.LengthPercentageSize;
pub const LengthPercentageAutoSize = style.LengthPercentageAutoSize;
pub const LengthPercentageRect = style.LengthPercentageRect;
pub const DimensionOverride = style.DimensionOverride;
pub const ExplicitOverride = style.ExplicitOverride;
/// Axis-aligned rectangle in layout space.
///
/// RELATIVE semantics: a node's rect is its BORDER box, positioned relative
/// to its PARENT'S CONTENT box (root-level nodes: relative to the surface).
/// Absolute positions are resolved on demand via `absoluteRect` /
/// `absoluteBorderOrigin` (a parent walk). Keeping rects relative lets a
/// subtree move as a unit and makes the double-buffered prev_tree diff
/// meaningful (a parent offset change does not invalidate child rects).
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

/// Available / required space.
pub const Size = struct { width: f32, height: f32 };

/// A clip rectangle in layout (framebuffer px) space. The GPU clip
/// buffer stores these verbatim (four f32, 16 bytes — the fragment
/// shader's `pc.indirect + 16 * clip_id` stride); the shader discards
/// fragments outside the rect indexed by a vertex's clip_id.
/// 0xFFFFFFFF (no clip id) = no clip.
pub const ClipRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// The CSS box model for one node: margin (outside, handled by the parent
/// when positioning), border + radius (painted as a ring), padding (inside,
/// separating the border from the content). `node.rect` is the BORDER box;
/// the content box = rect inset by border + padding.
pub const Box = struct {
    margin: Sides = .{},
    border: Sides = .{}, // widths only; color/radius are paint
    border_color: [4]f32 = .{ 0, 0, 0, 1 },
    /// Per-axis corner radii (l/r/t/b) of the OUTER border edge, matching
    /// SceneRect's corners[0..4] geometry (each corner = l|r x t|b). The
    /// inner (fill) radius = max(0, radius - border) per axis.
    radius: Sides = .{},
    padding: Sides = .{},
    box_sizing: BoxSizing = .content_box,
    /// Paint-only: drop-shadow softness/offset in px (0 = none). Never
    /// affects layout; excluded from the layout fingerprint.
    shadow: f32 = 0,
    /// Paint-only: the gradient's bottom color in Oklab (all-zero = flat
    /// fill). The vertex color is the gradient's top. Excluded from the
    /// layout fingerprint.
    gradient: [4]f32 = .{ 0, 0, 0, 0 },
    /// Paint-only: the node's FLAT fill color in sRGB (alpha 0 = the
    /// renderer's palette fallback). The gradient's top vertex color —
    /// set it to the same color as the gradient for a flat fill. Excluded
    /// from the layout fingerprint.
    color: [4]f32 = .{ 0, 0, 0, 0 },
    /// When true, the node participates in layout and interaction but emits no fill.
    transparent: bool = false,
    /// Paint-only: this container clips its own + descendants' content to
    /// its border box (collectDrawCmds stamps a clip id on the subtree's
    /// draw commands; the fragment shader discards outside the rect).
    /// Never affects layout; excluded from the layout fingerprint.
    clip: bool = false,
    /// Paint-only: the bindless texture heap index of a texture registered
    /// by the host (the `.texture` box option). When set, the node's FILL
    /// samples the texture instead of the flat color (the fragment shader's
    /// TYPE_TEXTURE branch, before the material dispatch); the border ring
    /// and shadow stay untextured. Null = flat fill. The fill's vColor is
    /// white (identity tint) so the texture's own pixels show through.
    /// Never affects layout; excluded from the layout fingerprint.
    texture: ?u32 = null,
    /// Paint-only: the layer key (the GPU sort's z) this node's drawables
    /// submit with. 0 = the base tree; >0 = overlays/popups that paint over
    /// the WHOLE z=0 tree regardless of their position in the drawable bag
    /// (the v1 spec §2: the stable radix sorts on (z << 32) | order).
    /// collectDrawCmds stamps it onto every cmd the node emits (shadow,
    /// ring, fill) and buildSliceRects stamps it onto the node's glyphs, so
    /// a layered node paints as one unit. Never affects layout; excluded
    /// from the layout fingerprint.
    layer: u32 = 0,
};

/// Horizontal+vertical sums of a Sides (for content-box derivation).
pub fn sidesSum(s: Sides) struct { w: f32, h: f32 } {
    return .{ .w = s.left + s.right, .h = s.top + s.bottom };
}
/// Per-child flexbox sizing parameters (main axis).
pub const FlexChild = struct {
    grow: f32 = 0,
    shrink: f32 = 1,
    basis: f32 = 0,
    min_main: ?f32 = null,
};

/// Sizing parameters for one shared column track.
pub const ColumnTrack = struct {
    grow: f32 = 0,
    shrink: f32 = 1,
    basis: f32 = 0,
    min_main: ?f32 = null,
};

/// Column tracks shared by compatible row children.
pub const SharedColumns = struct {
    tracks: []const ColumnTrack,
};

/// Scrollable axes.
pub const ScrollAxis = enum { vertical, horizontal, both };

/// Mutable scroll offsets and their layout-derived limits.
pub const ScrollState = struct {
    offset: [2]f32 = .{ 0, 0 },
    max_offset: [2]f32 = .{ 0, 0 },
};

/// Scroll behavior for a widget node.
pub const ScrollSpec = struct {
    state: *ScrollState,
    axis: ScrollAxis = .vertical,
};

/// Text overflow behavior.
pub const TextOverflow = enum { visible, clip, ellipsis };

/// A window-rendered SVG icon. This stays value-only so the widget tree
/// remains independent of the GPU cache that owns its path materials.
pub const IconId = enum {
    heart,
    heart_filled,
    shuffle,
    previous,
    play,
    pause,
    next,
    repeat,
    queue,
    devices,
    volume,
};
/// Visible rail height for sliders whose visual label is intentionally hidden.
/// Layout owns this shared intrinsic so such controls remain paintable and
/// interactive without caller-specific vertical padding.
pub const slider_rail_height: f32 = 4;

/// Paint-only thumb geometry. The fixed width keeps the marker visible over
/// both the filled progress and the unfilled rail; this does not increase the
/// slider's intrinsic or pointer-hit height.
pub const slider_thumb_width: f32 = 10;

pub fn sliderThumbRect(rail: Rect, fraction: f32) Rect {
    const width = @min(slider_thumb_width, rail.w);
    const x = rail.x + std.math.clamp(fraction, 0, 1) * @max(0, rail.w - width);
    return .{
        .x = x,
        .y = rail.y,
        .w = width,
        .h = rail.h,
    };
}

/// What a widget node is. Payload differs per kind; fields with defaults
/// may be omitted at construction.
pub const WidgetKind = union(enum) {
    column: struct { gap: f32 = 0 },
    row: struct { gap: f32 = 0 },
    /// `color` is the text color in sRGB (converted to Oklab by the
    /// renderer, like every widget color); default = white.
    label: struct { text: []const u8, color: [4]f32 = .{ 1, 1, 1, 1 } },
    button: struct {
        /// Semantic name retained for input dispatch and accessibility.
        label: []const u8,
        /// Optional visible text. Null uses `label` for text buttons; icons
        /// default to no text. An empty slice explicitly suppresses text.
        visual_label: ?[]const u8 = null,
        /// Optional window-owned SVG cache key; no GPU state belongs here.
        icon: ?IconId = null,
        /// Optional semantic name for assistive technologies; `label` remains
        /// the semantic fallback when this is absent.
        accessible_label: ?[]const u8 = null,
        color: [4]f32 = .{ 1, 1, 1, 1 },
        on_click: ?*const fn (*anyopaque) void = null, // set via callback.wrap()
        owner: Id = .root, // component_id at creation time
        user_callback: ?callback.UserCallback = null,
    },
    slider: struct {
        /// Semantic label retained for diagnostics and machine-readable output.
        label: []const u8,
        /// Optional text shown beside the slider. Null falls back to `label`;
        /// an empty slice intentionally suppresses visible text.
        visual_label: ?[]const u8 = null,
        color: [4]f32 = .{ 1, 1, 1, 1 },
        value: *f32,
        min: f32,
        max: f32,
    },
    spacer: struct { size: f32 = 0 },
};

/// Return a button's visible text while keeping its semantic label intact.
/// Icon buttons intentionally default to no text; an explicit visual label
/// can still opt into a mixed icon-and-text button.
pub fn buttonVisualLabel(kind: WidgetKind) []const u8 {
    return switch (kind) {
        .button => |b| b.visual_label orelse if (b.icon != null) "" else b.label,
        else => unreachable,
    };
}

/// Return the text a slider should display while preserving its semantic label
/// in the slider payload. A null visual label falls back to that label; an
/// explicitly empty visual label remains empty and suppresses visible text.
pub fn sliderVisualLabel(kind: WidgetKind) []const u8 {
    return switch (kind) {
        .slider => |s| s.visual_label orelse s.label,
        else => unreachable,
    };
}

/// One node in the tree.
pub const WidgetNode = struct {
    id: Id,
    kind: WidgetKind,
    parent: Id,
    // SAFETY: items is filled by flex before any read; len tracks the filled count.
    children: struct { items: [32]Id = undefined, len: u8 = 0 } = .{}, // fixed cap, prototype
    /// BORDER box, positioned relative to the parent's CONTENT box (see
    /// Rect's doc). Filled by flex.layout().
    rect: Rect = .{},
    /// Legacy box mirror retained for draw command and caller compatibility.
    box: Box = .{},
    /// Resolved typed layout values. This is the canonical flex/style view.
    resolved_style: ResolvedStyle = .{},
    resolved_dimensions: ResolvedDimensions = .{},
    resolved_insets: ResolvedInsets = .{
        .top = null,
        .right = null,
        .bottom = null,
        .left = null,
    },
    resolved_constraints: ResolvedConstraints = .{},
    resolved_aspect_ratio: ?f32 = null,
    resolved_overflow: OverflowAxes = .{ .width = .visible, .height = .visible },
    /// Resolved typed layout values. This is the canonical flex/style view.
    style: Style = .{},
    /// Resolved typed paint values. This is the canonical paint view.
    paint: PaintStyle = .{},
    scroll: ?ScrollSpec = null,
    text_overflow: TextOverflow = .visible,
    text_max_width: ?f32 = null,
    shared_columns: ?*const SharedColumns = null,
    /// Font size in px for text-bearing nodes; 0 = the host's default.
    /// Set from opts.font_size; the measure hook and the text engine
    /// dispatch on it.
    font_size: f32 = 0,
    /// Font selection: 0 = the host default font, 1 = the second font.
    font_id: u8 = 0,
    /// Legacy per-child flex mirror retained for caller compatibility.
    flex: FlexChild = .{},
    /// The item's natural (measured/hugged) main size before any basis
    /// override, recorded by the parent when placing. The flex-shrink
    /// floor: shrink never crosses it (the canonical automatic minimum,
    /// CSS flexbox §4.5). Filled by flex.layout().
    natural_main: f32 = 0,
    /// The clip rect id (index into WidgetTree.clip_rects) enclosing this
    /// node, stamped by collectDrawCmds during its walk; 0xFFFFFFFF = no
    /// clip. The renderer clips the node's glyphs to that rect.
    clip_id: u32 = 0xFFFFFFFF,
    // Snapshots let layout accept either the canonical style or the legacy
    // mirror when an existing caller mutates a node after construction.
    box_snapshot: Box = .{},
    style_snapshot: Style = .{},
    paint_snapshot: PaintStyle = .{},
    flex_snapshot: FlexChild = .{},

    /// Resolve typed dimensions, constraints, insets, and overflow for the
    /// containing block known by the current layout pass.
    pub fn resolveTypedStyle(
        self: *WidgetNode,
        containing: ?Size,
        intrinsic: Size,
    ) void {
        const resolved = self.style.resolveTotal(
            if (containing) |value|
                style.Size(f32){ .width = value.width, .height = value.height }
            else
                null,
            style.Size(f32){ .width = intrinsic.width, .height = intrinsic.height },
        );
        self.resolved_style = resolved;
        self.resolved_dimensions = resolved.dimensions;
        self.resolved_insets = resolved.insets;
        self.resolved_constraints = resolved.constraints;
        self.resolved_aspect_ratio = resolved.aspect_ratio;
        self.resolved_overflow = resolved.overflow;
    }

    /// Reconcile legacy public mirrors before layout. This keeps old direct
    /// box/flex writes working while flex consumes the resolved values.
    pub fn syncResolvedStyle(self: *WidgetNode) void {
        const legacy_box_changed = !std.meta.eql(self.box, self.box_snapshot);
        const typed_box_changed = !std.meta.eql(self.style.margin, self.style_snapshot.margin) or
            !std.meta.eql(self.style.border, self.style_snapshot.border) or
            !std.meta.eql(self.style.padding, self.style_snapshot.padding) or
            self.style.box_sizing != self.style_snapshot.box_sizing;
        const legacy_paint_changed = !std.meta.eql(self.box.border_color, self.box_snapshot.border_color) or
            !std.meta.eql(self.box.radius, self.box_snapshot.radius) or
            self.box.shadow != self.box_snapshot.shadow or
            !std.meta.eql(self.box.gradient, self.box_snapshot.gradient) or
            !std.meta.eql(self.box.color, self.box_snapshot.color) or
            self.box.transparent != self.box_snapshot.transparent or
            self.box.clip != self.box_snapshot.clip or
            self.box.texture != self.box_snapshot.texture or
            self.box.layer != self.box_snapshot.layer;
        const typed_paint_changed = !std.meta.eql(self.paint, self.paint_snapshot);
        if (legacy_box_changed and !typed_box_changed) {
            self.style.margin = self.box.margin;
            self.style.border = self.box.border;
            self.style.padding = self.box.padding;
            self.style.box_sizing = self.box.box_sizing;
            self.style.margin_inset = .{
                .top = .{ .length = self.box.margin.top },
                .right = .{ .length = self.box.margin.right },
                .bottom = .{ .length = self.box.margin.bottom },
                .left = .{ .length = self.box.margin.left },
            };
            self.style.border_inset = .{
                .top = .{ .length = self.box.border.top },
                .right = .{ .length = self.box.border.right },
                .bottom = .{ .length = self.box.border.bottom },
                .left = .{ .length = self.box.border.left },
            };
            self.style.padding_inset = .{
                .top = .{ .length = self.box.padding.top },
                .right = .{ .length = self.box.padding.right },
                .bottom = .{ .length = self.box.padding.bottom },
                .left = .{ .length = self.box.padding.left },
            };
        } else if (typed_box_changed) {
            self.box.margin = self.style.margin;
            self.box.border = self.style.border;
            self.box.padding = self.style.padding;
            self.box.box_sizing = self.style.box_sizing;
        }
        if (legacy_paint_changed and !typed_paint_changed) {
            self.paint.fill = self.box.color;
            self.paint.border_color = self.box.border_color;
            self.paint.radius = self.box.radius;
            self.paint.shadow = self.box.shadow;
            self.paint.gradient = self.box.gradient;
            self.paint.transparent = self.box.transparent;
            self.paint.clip = self.box.clip;
            self.paint.texture = self.box.texture;
            self.paint.layer = self.box.layer;
        } else if (typed_paint_changed) {
            self.box.color = self.paint.fill;
            self.box.border_color = self.paint.border_color;
            self.box.radius = self.paint.radius;
            self.box.shadow = self.paint.shadow;
            self.box.gradient = self.paint.gradient;
            self.box.transparent = self.paint.transparent;
            self.box.clip = self.paint.clip;
            self.box.texture = self.paint.texture;
            self.box.layer = self.paint.layer;
        }
        const legacy_flex_changed = !std.meta.eql(self.flex, self.flex_snapshot);
        const typed_flex_changed = self.style.grow != self.style_snapshot.grow or
            self.style.shrink != self.style_snapshot.shrink or
            self.style.basis != self.style_snapshot.basis or
            !std.meta.eql(self.style.flex_basis, self.style_snapshot.flex_basis) or
            self.style.min_main != self.style_snapshot.min_main;
        if (legacy_flex_changed and !typed_flex_changed) {
            self.style.grow = self.flex.grow;
            self.style.shrink = self.flex.shrink;
            self.style.basis = self.flex.basis;
            self.style.flex_basis = if (self.flex.basis > 0)
                .{ .length = self.flex.basis }
            else
                .auto;
            self.style.min_main = self.flex.min_main;
        } else if (typed_flex_changed) {
            self.flex = .{
                .grow = self.style.grow,
                .shrink = self.style.shrink,
                .basis = self.style.basis,
                .min_main = self.style.min_main,
            };
        }
        self.box_snapshot = self.box;
        self.style_snapshot = self.style;
        self.paint_snapshot = self.paint;
        self.flex_snapshot = self.flex;
    }

    /// Populate both typed values and their legacy mirrors from one resolve.
    pub fn setResolvedStyle(self: *WidgetNode, resolved_style: Style, resolved_paint: PaintStyle) void {
        self.style = resolved_style;
        self.paint = resolved_paint;
        self.box = .{
            .margin = resolved_style.margin,
            .border = resolved_style.border,
            .border_color = resolved_paint.border_color,
            .radius = resolved_paint.radius,
            .padding = resolved_style.padding,
            .box_sizing = resolved_style.box_sizing,
            .shadow = resolved_paint.shadow,
            .gradient = resolved_paint.gradient,
            .color = resolved_paint.fill,
            .transparent = resolved_paint.transparent,
            .clip = resolved_paint.clip,
            .texture = resolved_paint.texture,
            .layer = resolved_paint.layer,
        };
        self.flex = .{
            .grow = resolved_style.grow,
            .shrink = resolved_style.shrink,
            .basis = resolved_style.basis,
            .min_main = resolved_style.min_main,
        };
        self.resolveTypedStyle(null, .{ .width = 0, .height = 0 });
        self.box_snapshot = self.box;
        self.style_snapshot = self.style;
        self.paint_snapshot = self.paint;
        self.flex_snapshot = self.flex;
    }
};

/// The per-frame widget tree.
///
/// Invariant: node order is **post-order** — a node's children are appended
/// before the node itself. A container therefore appears after all of its
/// descendants, so flex.layout() can run bottom-up in one pass.
///
/// Storage is owned by the caller (the frame arena, see drawctx.zig); the
/// tree must be re-created per frame, never reused across a reset.
pub const WidgetTree = struct {
    nodes: std.ArrayListUnmanaged(WidgetNode) = .empty,
    allocator: std.mem.Allocator,
    next_id: u32 = 1,
    /// Per-frame clip-rect list (cap 64 = the GPU clip buffer's size). Clip
    /// ids are indices into this list; 0xFFFFFFFF = no clip. The core
    /// appends here (DrawCtx.pushClip + drawcmd's clip-stack walk); the
    /// renderer copies the list into the GPU clip buffer each frame.
    /// Append-only per frame — ids must stay stable for the frame.
    // SAFETY: written only via pushClipRect before any read; clip_count tracks the filled count
    clip_rects: [64]ClipRect = undefined,
    clip_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) WidgetTree {
        return .{ .allocator = allocator };
    }

    /// Append a clip rect, returning its id (the index into clip_rects).
    /// Null when the list is full (64): the caller then skips clipping.
    pub fn pushClipRect(self: *WidgetTree, r: ClipRect) ?u32 {
        if (self.clip_count >= self.clip_rects.len) return null;
        const id = self.clip_count;
        self.clip_rects[id] = r;
        self.clip_count += 1;
        return id;
    }

    /// Linear scan by id. Null if absent.
    pub fn node(self: *WidgetTree, id: Id) ?*WidgetNode {
        for (self.nodes.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// Const-safe linear scan by id. Null if absent.
    pub fn nodeConst(self: *const WidgetTree, id: Id) ?*const WidgetNode {
        for (self.nodes.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// All nodes whose parent == .root (top-level).
    /// Fills `buf` (caller provides, cap 64) up to `buf.len` entries and
    /// returns the total count — truncation-safe: a too-small `buf` never
    /// overflows, the caller just gets the count that would have been written.
    pub fn roots(self: *WidgetTree, buf: []*WidgetNode) usize {
        var count: usize = 0;
        for (self.nodes.items) |*n| {
            if (n.parent != .root) continue;
            if (count < buf.len) buf[count] = n;
            count += 1;
        }
        return count;
    }
};

/// Resolve a node's absolute border-box origin by walking parents: each
/// ancestor contributes its own (relative) offset plus the step into its
/// CONTENT box (border + padding). The surface origin is (0,0).
pub fn absoluteBorderOrigin(tree: *const WidgetTree, id: Id) [2]f32 {
    var ox: f32 = 0;
    var oy: f32 = 0;
    var cur = id;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        ox += n.rect.x;
        oy += n.rect.y;
        const parent = tree.nodeConst(n.parent) orelse break;
        ox += parent.box.border.left + parent.box.padding.left;
        oy += parent.box.border.top + parent.box.padding.top;
        cur = n.parent;
    }
    return .{ ox, oy };
}

/// Absolute border box of a node (origin + its own w/h).
pub fn absoluteRect(tree: *const WidgetTree, id: Id) Rect {
    const origin = absoluteBorderOrigin(tree, id);
    const n = tree.nodeConst(id) orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = n.rect.w, .h = n.rect.h };
}

/// Resolve a node's visual border-box origin, accounting for ancestor scroll.
/// The target node's own scroll offset does not move its border box.
pub fn visualBorderOrigin(tree: *const WidgetTree, id: Id) [2]f32 {
    var ox: f32 = 0;
    var oy: f32 = 0;
    var cur = id;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        ox += n.rect.x;
        oy += n.rect.y;
        const parent = tree.nodeConst(n.parent) orelse break;
        ox += parent.box.border.left + parent.box.padding.left;
        oy += parent.box.border.top + parent.box.padding.top;
        if (parent.scroll) |scroll| {
            ox -= scroll.state.offset[0];
            oy -= scroll.state.offset[1];
        }
        cur = n.parent;
    }
    return .{ ox, oy };
}

/// Visual border box of a node, after ancestor scroll offsets are applied.
pub fn visualBorderRect(tree: *const WidgetTree, id: Id) Rect {
    const origin = visualBorderOrigin(tree, id);
    const n = tree.nodeConst(id) orelse return .{ .x = origin[0], .y = origin[1] };
    return .{ .x = origin[0], .y = origin[1], .w = n.rect.w, .h = n.rect.h };
}

/// Visual content box of a node, after ancestor scroll offsets are applied.
pub fn visualContentRect(tree: *const WidgetTree, id: Id) Rect {
    const r = visualBorderRect(tree, id);
    const n = tree.nodeConst(id) orelse return r;
    const b = n.box;
    return .{
        .x = r.x + b.border.left + b.padding.left,
        .y = r.y + b.border.top + b.padding.top,
        .w = @max(0, r.w - b.border.left - b.border.right - b.padding.left - b.padding.right),
        .h = @max(0, r.h - b.border.top - b.border.bottom - b.padding.top - b.padding.bottom),
    };
}

/// Return whether a point is inside every clipped ancestor of a node.
pub fn pointInClipChain(tree: *const WidgetTree, id: Id, pos: [2]f32) bool {
    var cur = id;
    while (cur != .root) {
        const n = tree.nodeConst(cur) orelse break;
        if (n.box.clip and !rectContainsPoint(visualBorderRect(tree, cur), pos)) return false;
        cur = n.parent;
    }
    return true;
}

fn rectContainsPoint(rect: Rect, pos: [2]f32) bool {
    return pos[0] >= rect.x and pos[0] < rect.x + rect.w and
        pos[1] >= rect.y and pos[1] < rect.y + rect.h;
}

/// Absolute CONTENT box of a node: the absolute border box inset by the
/// node's own border + padding. Where children live and text draws.
pub fn contentRect(tree: *const WidgetTree, id: Id) Rect {
    const r = absoluteRect(tree, id);
    const b = tree.nodeConst(id).?.box;
    return .{
        .x = r.x + b.border.left + b.padding.left,
        .y = r.y + b.border.top + b.padding.top,
        .w = @max(0, r.w - b.border.left - b.border.right - b.padding.left - b.padding.right),
        .h = @max(0, r.h - b.border.top - b.border.bottom - b.padding.top - b.padding.bottom),
    };
}

test "WidgetTree: node() finds pushed ids, null for unknown" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    try tree.nodes.append(std.testing.allocator, .{
        .id = id1,
        .kind = .{ .label = .{ .text = "a" } },
        .parent = .root,
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = id2,
        .kind = .{ .spacer = .{} },
        .parent = id1,
    });

    const found = tree.node(id2).?;
    try std.testing.expectEqual(id2, found.id);
    try std.testing.expectEqual(id1, found.parent);
    try std.testing.expectEqual(@as(?*WidgetNode, null), tree.node(@enumFromInt(99)));
}

test "WidgetTree: roots() returns only top-level nodes in append order" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    const id3: Id = @enumFromInt(3);
    const id4: Id = @enumFromInt(4);
    const id5: Id = @enumFromInt(5);

    // Post-order: children first, then their containers.
    try tree.nodes.append(std.testing.allocator, .{ .id = id4, .kind = .{ .label = .{ .text = "c" } }, .parent = id1 });
    try tree.nodes.append(std.testing.allocator, .{ .id = id5, .kind = .{ .label = .{ .text = "d" } }, .parent = id2 });
    try tree.nodes.append(std.testing.allocator, .{ .id = id1, .kind = .{ .column = .{} }, .parent = .root });
    try tree.nodes.append(std.testing.allocator, .{ .id = id2, .kind = .{ .row = .{} }, .parent = .root });
    try tree.nodes.append(std.testing.allocator, .{ .id = id3, .kind = .{ .spacer = .{} }, .parent = .root });

    var buf: [8]*WidgetNode = undefined;
    const count = tree.roots(&buf);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(id1, buf[0].id);
    try std.testing.expectEqual(id2, buf[1].id);
    try std.testing.expectEqual(id3, buf[2].id);
}

test "WidgetTree: roots() with a too-small buf returns the full count, no overflow" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    for (0..5) |i| {
        try tree.nodes.append(std.testing.allocator, .{
            .id = @enumFromInt(@as(u32, @intCast(i + 1))),
            .kind = .{ .spacer = .{} },
            .parent = .root,
        });
    }

    var small: [2]*WidgetNode = undefined;
    const count = tree.roots(&small);
    // Count reflects everything that would have been written.
    try std.testing.expectEqual(@as(usize, 5), count);
    // The first entries still land, in append order.
    try std.testing.expectEqual(@as(Id, @enumFromInt(1)), small[0].id);
    try std.testing.expectEqual(@as(Id, @enumFromInt(2)), small[1].id);
    // Writing past buf.len would trip the slice bounds check under `zig test`.
}

test "absoluteRect: walks parent content boxes through border+padding" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    // root-level column with padding, holding a row with a border, holding
    // a label offset relative to the row's content box.
    const col: Id = @enumFromInt(1);
    const row: Id = @enumFromInt(2);
    const label: Id = @enumFromInt(3);

    try tree.nodes.append(std.testing.allocator, .{
        .id = label,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = row,
        .rect = .{ .x = 5, .y = 3, .w = 20, .h = 24 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = row,
        .kind = .{ .row = .{} },
        .parent = col,
        .rect = .{ .x = 10, .y = 10, .w = 100, .h = 40 },
        .box = .{ .border = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 },
        .box = .{ .padding = .{ .top = 8, .left = 8 } },
    });

    // Label absolute border box: col content origin (8,8) + row rect
    // (10,10) + row border (4,1) + label rect (5,3).
    const r = absoluteRect(&tree, label);
    try std.testing.expectEqual(Rect{ .x = 8 + 10 + 4 + 5, .y = 8 + 10 + 1 + 3, .w = 20, .h = 24 }, r);

    // Label content box: its own border+padding are zero, so identical.
    const c = contentRect(&tree, label);
    try std.testing.expectEqual(r, c);

    // Row content box: absolute border box (18,18,100,40) inset by its
    // border (4,1,2,3).
    const rc = contentRect(&tree, row);
    try std.testing.expectEqual(Rect{ .x = 18 + 4, .y = 18 + 1, .w = 100 - 6, .h = 40 - 4 }, rc);
}

test "absoluteRect: root-level node is relative to the surface (0,0)" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const col: Id = @enumFromInt(1);
    try tree.nodes.append(std.testing.allocator, .{
        .id = col,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });

    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, absoluteRect(&tree, col));
}

test "WidgetNode: defaults are zero-valued" {
    const n: WidgetNode = .{
        .id = .root,
        .kind = .{ .label = .{ .text = "x" } },
        .parent = .root,
    };

    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, n.rect);
    try std.testing.expectEqual(Box{}, n.box);
    try std.testing.expectEqual(@as(u8, 0), n.children.len);
    try std.testing.expectEqual(@as(f32, 0), n.flex.grow);
    try std.testing.expectEqual(@as(f32, 1), n.flex.shrink);
    try std.testing.expectEqual(@as(f32, 0), n.flex.basis);
}
test "WidgetNode: typed dimensions and constraints are stored after resolution" {
    var node: WidgetNode = .{
        .id = .root,
        .kind = .{ .label = .{ .text = "typed" } },
        .parent = .root,
        .style = .{
            .size = .{ .width = .{ .percent = 0.5 }, .height = .auto },
            .min_size = .{ .width = .{ .length = 40 }, .height = .auto },
            .inset = .{
                .top = .auto,
                .right = .{ .length = 8 },
                .bottom = .auto,
                .left = .auto,
            },
        },
    };
    node.resolveTypedStyle(.{ .width = 200, .height = 100 }, .{ .width = 30, .height = 20 });
    try std.testing.expectEqual(@as(?f32, 100), node.resolved_dimensions.width);
    try std.testing.expectEqual(@as(?f32, 40), node.resolved_constraints.min_width);
    try std.testing.expectEqual(@as(?f32, 8), node.resolved_insets.right);
}

test "sliderVisualLabel: null falls back, empty suppresses visible text" {
    var value: f32 = 0.5;
    const fallback: WidgetKind = .{ .slider = .{
        .label = "volume",
        .value = &value,
        .min = 0,
        .max = 1,
    } };
    const override: WidgetKind = .{ .slider = .{
        .label = "semantic",
        .visual_label = "shown",
        .value = &value,
        .min = 0,
        .max = 1,
    } };
    const hidden: WidgetKind = .{ .slider = .{
        .label = "semantic",
        .visual_label = "",
        .value = &value,
        .min = 0,
        .max = 1,
    } };

    try std.testing.expectEqualStrings("volume", sliderVisualLabel(fallback));
    try std.testing.expectEqualStrings("shown", sliderVisualLabel(override));
    try std.testing.expectEqualStrings("", sliderVisualLabel(hidden));
}

test "visualBorderRect: scroll offset applies only to descendants" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const scroll_id: Id = @enumFromInt(1);
    const child_id: Id = @enumFromInt(2);
    var scroll_state: ScrollState = .{ .offset = .{ 4, 6 } };

    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = scroll_id,
        .rect = .{ .x = 5, .y = 7, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = scroll_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 80 },
        .box = .{
            .border = .{ .top = 3, .left = 2 },
            .padding = .{ .top = 2, .left = 1 },
        },
        .scroll = .{ .state = &scroll_state },
    });

    try std.testing.expectEqual(
        Rect{ .x = 10, .y = 20, .w = 100, .h = 80 },
        visualBorderRect(&tree, scroll_id),
    );
    try std.testing.expectEqual(
        Rect{ .x = 14, .y = 26, .w = 20, .h = 10 },
        visualBorderRect(&tree, child_id),
    );
}

test "pointInClipChain: rejects points outside a scrolled ancestor clip" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);

    const clip_id: Id = @enumFromInt(1);
    const child_id: Id = @enumFromInt(2);
    var scroll_state: ScrollState = .{ .offset = .{ 5, 0 } };

    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = clip_id,
        .rect = .{ .x = 25, .y = 5, .w = 20, .h = 10 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = clip_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 10, .y = 20, .w = 30, .h = 30 },
        .box = .{ .clip = true },
        .scroll = .{ .state = &scroll_state },
    });

    try std.testing.expect(pointInClipChain(&tree, child_id, .{ 35, 27 }));
    try std.testing.expect(!pointInClipChain(&tree, child_id, .{ 45, 27 }));
}

test "WidgetNode: typed flex sync compares dimension payloads" {
    var node: WidgetNode = .{
        .id = .root,
        .kind = .{ .label = .{ .text = "typed" } },
        .parent = .root,
    };

    node.style.flex_basis = .{ .length = 24 };
    node.syncResolvedStyle();
    try std.testing.expect(std.meta.eql(
        @as(Dimension, .{ .length = 24 }),
        node.style_snapshot.flex_basis,
    ));

    node.style.flex_basis = .{ .length = 36 };
    node.syncResolvedStyle();
    try std.testing.expect(std.meta.eql(
        @as(Dimension, .{ .length = 36 }),
        node.style_snapshot.flex_basis,
    ));
}
