//! Headless mode — drop-in replacement for Window that captures the
//! widget tree + draw list as structured JSON instead of rendering to GPU.
//!
//! Enables LLM-driven regression testing, CI without GPU, and automated
//! visual diffing by snapshot comparison.
//!
//! Usage:
//!   var ctx = try HeadlessContext.init(gpa, "test_slider_layout");
//!   defer ctx.deinit();
//!   var win = try HeadlessWindow.init(&ctx, .{ .width = 800, .height = 600 });
//!   defer win.deinit();
//!   const frames = try win.run(&gui, 1);  // capture 1 frame
//!   // frames[0] is FrameOutput — serialize to JSON for snapshot
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const Widget = @import("widget.zig").Widget;
const Id = @import("widget.zig").Id;
const Rect = @import("widget.zig").Rect;
const Sizing = @import("widget.zig").Sizing;
const SizingAxis = @import("widget.zig").SizingAxis;
const SceneRect = @import("render_9slice.zig").SceneRect;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const GlyphSweeper = @import("sweeper.zig").GlyphSweeper;
const Curve = @import("sweeper.zig").Curve;
const GlyphMaterial = @import("sweeper.zig").GlyphMaterial;
const drawctx = @import("drawctx.zig");
const RenderCommand = @import("render_command.zig").RenderCommand;
const RenderCommandList = @import("render_command.zig").RenderCommandList;
const RectCollectCtx = @import("render_command.zig").RectCollectCtx;
const processRenderCommands = @import("render_command.zig").processRenderCommands;

const frame_arenas = 2;

// ─── Headless Context ──────────────────────────────

/// Application context without GPU dependency. Replaces `Context`
/// in headless mode — no GPU instance, no SDL3, no Vulkan.
pub const HeadlessContext = struct {
    gpa: std.mem.Allocator,
    frame_count: u64 = 0,
    test_name: []const u8,

    /// Optional: known glyph data for resolving material_index →
    /// character references in draw list serialization.
    glyph_entries: ?[]const GlyphInfo = null,

    pub fn init(gpa: std.mem.Allocator, test_name: []const u8) HeadlessContext {
        return .{ .gpa = gpa, .test_name = test_name };
    }

    pub fn deinit(self: *HeadlessContext) void {
        if (self.glyph_entries) |entries| {
            self.gpa.free(entries);
        }
        self.* = undefined;
    }
};

/// Static glyph metadata available at serialization time.
pub const GlyphInfo = struct {
    char: u8,
    material_slot: u32,
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
    glyph_w: f32,
    glyph_h: f32,
    curve_ref: ?[]const u8, // e.g. "A" for the glyph character
};

// ─── Headless Window ──────────────────────────────

/// Drop-in replacement for `Window`. Same `run()` / `beginFrame()` /
/// `endFrame()` lifecycle, but instead of GPU rendering, serializes
/// the widget tree and draw list to structured JSON.
/// Window dimensions for the frame.
pub const WindowSize = struct { width: f32, height: f32 };

pub const HeadlessWindow = struct {
    context: *HeadlessContext,
    /// Window dimensions for the frame.
    size: WindowSize,
    /// Ping-pong frame arenas (same pattern as Window).
    arenas: [frame_arenas]std.heap.ArenaAllocator,
    current_arena: usize = 0,
    should_close: bool = false,

    /// Pre-allocated rect buffer for draw list collection.
    rect_buf: []SceneRect,

    /// Per-frame RenderCommand buffer (arena-allocated).
    cmd_buf: RenderCommandList = undefined,

    /// Per-frame material refs for headless JSON serialization.
    /// Reset each frame; populated by emitGlyphCommands.
    material_refs: std.ArrayList(MaterialRef) = .empty,

    pub fn init(ctx: *HeadlessContext, size: WindowSize) !HeadlessWindow {
        var arenas: [frame_arenas]std.heap.ArenaAllocator = undefined;
        for (&arenas) |*a| {
            a.* = std.heap.ArenaAllocator.init(ctx.gpa);
        }
        const rect_buf = try ctx.gpa.alloc(SceneRect, 1024);
        return .{
            .context = ctx,
            .size = size,
            .arenas = arenas,
            .rect_buf = rect_buf,
        };
    }

    pub fn deinit(self: *HeadlessWindow) void {
        for (&self.arenas) |*a| a.deinit();
        self.context.gpa.free(self.rect_buf);
        self.material_refs.deinit(self.context.gpa);
        self.* = undefined;
    }

    /// Begin a new frame. Returns a DrawCtx with a fresh arena allocator.
    /// Identical API to Window.beginFrame() but skip GPU swapchain acquire.
    pub fn beginFrame(self: *HeadlessWindow) DrawCtx {
        self.current_arena = (self.current_arena + 1) % frame_arenas;
        drawctx.resetTempId();
        const arena = &self.arenas[self.current_arena];
        _ = arena.reset(.retain_capacity);

        // Allocate RenderCommand buffer from frame arena
        const cmd_buf_slice = arena.allocator().alloc(RenderCommand, 2048) catch unreachable;
        self.cmd_buf = RenderCommandList.init(cmd_buf_slice);

        // Reset material refs (retain backing alloc but clear entries)
        self.material_refs.clearRetainingCapacity();

        return .{
            .allocator = arena.allocator(),
            .surface_size = .{ .width = self.size.width, .height = self.size.height },
        };
    }

    /// End the frame: collect RenderCommands → process → serialize.
    /// Returns a FrameOutput that can be JSON-encoded for snapshot comparison.
    pub fn endFrame(self: *HeadlessWindow, allocator: std.mem.Allocator, root: *Widget) !FrameOutput {
        // Phase 1: Collect RenderCommands from widget tree
        const ctx: RectCollectCtx = .{ .headless = .{
            .ctx = self.context,
            .material_refs = &self.material_refs,
        } };
        collectWidgetRectsHeadless(self, root, &self.cmd_buf, &ctx);
        self.cmd_buf.push(.blit_oklab);

        // Phase 2: Process RenderCommands → SceneRects
        const rect_count = processRenderCommands(
            self.cmd_buf.slice(),
            self.rect_buf,
            0, // material_buf_bda: not used in headless mode
            null, // material_cpu: not used in headless mode
            undefined, // next_material_slot: not used in headless mode
            self,
        );

        // Phase 3: Serialize to JSON
        const draw_cmds = try collectDrawCommands(allocator, self.rect_buf[0..rect_count], self.context);
        const tree = try serializeWidgetTree(allocator, root);

        return .{
            .frame_number = self.context.frame_count,
            .timestamp_ms = std.time.milliTimestamp(),
            .window_size = self.size,
            .test_name = self.context.test_name,
            .widget_tree = tree,
            .draw_list = draw_cmds,
        };
    }

    /// Run the event loop for `max_frames` frames. Each frame:
    ///   beginFrame() → gui.draw(dc) → dc.layoutAndRender(root) → endFrame(root)
    /// Returns all captured frame outputs.
    pub fn run(self: *HeadlessWindow, gui: anytype, max_frames: u64) ![]FrameOutput {
        const frames = try self.context.gpa.alloc(FrameOutput, max_frames);
        errdefer self.context.gpa.free(frames);

        self.context.frame_count = 0;
        var fi: usize = 0;

        while (fi < max_frames) : (fi += 1) {
            var dc = self.beginFrame();
            const root = try gui.draw(&dc);
            dc.layoutAndRender(root);

            frames[fi] = try self.endFrame(self.context.gpa, root);
            self.context.frame_count += 1;
        }

        return frames;
    }
};

// ─── Frame Output ────────────────────────

/// Complete frame snapshot: widget tree + draw list + metadata.
/// This is the top-level JSON object emitted per frame.
pub const FrameOutput = struct {
    frame_number: u64,
    timestamp_ms: i64,
    window_size: struct { width: f32, height: f32 },
    test_name: []const u8,
    widget_tree: WidgetNode,
    draw_list: []const DrawCommand,

    /// Optional: system info, git hash, build mode.
    debug_info: ?DebugInfo = null,

    /// Serialize this frame to a JSON string. Caller owns the returned memory.
    pub fn toJson(self: *const FrameOutput, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        try self.writeJson(buf.writer(allocator));
        return buf.toOwnedSlice(allocator);
    }

    /// Write JSON directly to a writer.
    pub fn writeJson(self: *const FrameOutput, writer: anytype) !void {
        try writer.writeAll("{");

        try writer.writeAll("\"meta\":{");
        try writer.print(
            "\"frame\":{d},\"ts\":{d},\"win_w\":{d},\"win_h\":{d}",
            .{ self.frame_number, self.timestamp_ms, self.window_size.width, self.window_size.height },
        );
        try writer.print(",\"test\":\"{s}\"", .{self.test_name});
        if (self.debug_info) |di| {
            try writer.print(",\"commit\":\"{s}\",\"build_mode\":\"{s}\"", .{ di.commit_hash, di.build_mode });
        }
        try writer.writeAll("}");

        try writer.writeAll(",\"widget_tree\":");
        try self.widget_tree.writeJson(writer);

        try writer.writeAll(",\"draw_list\":[");
        for (self.draw_list, 0..) |cmd, i| {
            if (i > 0) try writer.writeAll(",");
            try cmd.writeJson(writer);
        }
        try writer.writeAll("]");

        try writer.writeAll("}");
    }
};

/// Optional debug metadata in the snapshot.
pub const DebugInfo = struct {
    commit_hash: []const u8,
    build_mode: []const u8,
};

// ─── Widget Tree Serialization ───────────────────────────

/// Serialized widget node — recursive tree structure.
/// Fields are nullable; only relevant fields are populated per kind.
pub const WidgetNode = struct {
    id: u64,
    kind: []const u8,
    rect: struct { x: f32, y: f32, w: f32, h: f32 },
    sizing: SizingNode,
    border: f32,
    corner_radius: f32,
    /// Oklab color (L, a, b, alpha).
    color: [4]f32,
    border_color: [4]f32,

    // Kind-specific payload (nullable — only populated for matching kind)
    label: ?[]const u8 = null,
    value: ?f32 = null,
    value_min: ?f32 = null,
    value_max: ?f32 = null,
    padding: ?f32 = null,
    gap: ?f32 = null,
    children: ?[]const WidgetNode = null,

    pub fn deinit(self: *WidgetNode, allocator: std.mem.Allocator) void {
        if (self.children) |kids| {
            for (kids) |*child| @constCast(child).deinit(allocator);
            allocator.free(kids);
        }
        self.* = undefined;
    }

    pub fn writeJson(self: *const WidgetNode, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"id\":{d},\"kind\":\"{s}\"", .{ self.id, self.kind });
        try writer.print(
            ",\"rect\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}",
            .{ self.rect.x, self.rect.y, self.rect.w, self.rect.h },
        );
        try writer.print(",\"sizing\":{{\"x\":\"{s}\",\"y\":\"{s}\"", .{
            @tagName(self.sizing.x),
            @tagName(self.sizing.y),
        });
        if (self.sizing.x_min != 0 or self.sizing.y_min != 0) {
            try writer.print(",\"x_min\":{d},\"y_min\":{d}", .{ self.sizing.x_min, self.sizing.y_min });
        }
        if (self.sizing.x_max != std.math.floatMax(f32) or self.sizing.y_max != std.math.floatMax(f32)) {
            try writer.print(",\"x_max\":{d},\"y_max\":{d}", .{ self.sizing.x_max, self.sizing.y_max });
        }
        try writer.writeAll("}");
        try writer.print(",\"border\":{d},\"corner_radius\":{d}", .{ self.border, self.corner_radius });
        try writer.print(
            ",\"color\":[{d},{d},{d},{d}]",
            .{ self.color[0], self.color[1], self.color[2], self.color[3] },
        );
        try writer.print(
            ",\"border_color\":[{d},{d},{d},{d}]",
            .{ self.border_color[0], self.border_color[1], self.border_color[2], self.border_color[3] },
        );

        if (self.label) |l| try writer.print(",\"label\":\"{s}\"", .{l});
        if (self.value) |v| try writer.print(",\"value\":{d}", .{v});
        if (self.value_min) |v| try writer.print(",\"value_min\":{d}", .{v});
        if (self.value_max) |v| try writer.print(",\"value_max\":{d}", .{v});
        if (self.padding) |p| try writer.print(",\"padding\":{d}", .{p});
        if (self.gap) |g| try writer.print(",\"gap\":{d}", .{g});

        if (self.children) |kids| {
            try writer.writeAll(",\"children\":[");
            for (kids, 0..) |*child, i| {
                if (i > 0) try writer.writeAll(",");
                try child.writeJson(writer);
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("}");
    }
};

pub const SizingNode = struct {
    x: SizingAxis,
    y: SizingAxis,
    x_min: f32 = 0,
    x_max: f32 = std.math.floatMax(f32),
    y_min: f32 = 0,
    y_max: f32 = std.math.floatMax(f32),
};

/// Recursively serialize a widget tree into WidgetNodes.
pub fn serializeWidgetTree(allocator: std.mem.Allocator, root: *const Widget) std.mem.Allocator.Error!WidgetNode {
    const kind_str = switch (root.kind) {
        .column => "column",
        .row => "row",
        .button => "button",
        .slider => "slider",
        .label => "label",
    };

    var node: WidgetNode = .{
        .id = @intFromEnum(root.id),
        .kind = kind_str,
        .rect = .{ .x = root.rect.x, .y = root.rect.y, .w = root.rect.w, .h = root.rect.h },
        .sizing = .{
            .x = root.sizing.x,
            .y = root.sizing.y,
            .x_min = root.sizing.x_min,
            .x_max = root.sizing.x_max,
            .y_min = root.sizing.y_min,
            .y_max = root.sizing.y_max,
        },
        .border = root.border,
        .corner_radius = root.corner_radius,
        .color = root.color,
        .border_color = root.border_color,
    };

    switch (root.kind) {
        .button => |b| {
            node.label = b.label;
        },
        .slider => |s| {
            node.label = s.label;
            node.value = s.value.*;
            node.value_min = s.min;
            node.value_max = s.max;
        },
        .label => |l| {
            node.label = l.text;
        },
        .column => |c| {
            node.padding = c.padding;
            node.gap = c.gap;
            node.children = try allocChildren(allocator, c.children);
        },
        .row => |r| {
            node.padding = r.padding;
            node.gap = r.gap;
            node.children = try allocChildren(allocator, r.children);
        },
    }

    return node;
}

fn allocChildren(allocator: std.mem.Allocator, kids: []const *Widget) ![]const WidgetNode {
    const out = try allocator.alloc(WidgetNode, kids.len);
    for (kids, out) |child, *out_node| {
        out_node.* = try serializeWidgetTree(allocator, child);
    }
    return out;
}

// ─── Draw List Serialization ───────────────────────────

/// One draw command — JSON-friendly representation of a SceneRect.
pub const DrawCommand = struct {
    cmd_type: []const u8, // "fill_rect" | "border_rect" | "glyph"

    /// Destination rectangle in screen space (pixels).
    dst: struct { x: f32, y: f32, w: f32, h: f32 },
    /// Oklab color (L, a, b, alpha). [0,0,0,0] for glyphs (color in material).
    color: [4]f32,
    /// 9-slice corner sizes (pixels).
    corners: ?struct { l: f32, r: f32, t: f32, b: f32 } = null,
    /// Source UV rectangle (normalized 0..1). Null for non-textured.
    src_uv: ?struct { u: f32, v: f32, w: f32, h: f32 } = null,
    /// Glyph-specific data (null for non-glyph draws).
    glyph: ?GlyphRef = null,
    /// Material reference for glyph/rounded-rect draws.
    material: ?MaterialRef = null,

    pub fn writeJson(self: *const DrawCommand, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"cmd\":\"{s}\"", .{self.cmd_type});
        try writer.print(
            ",\"dst\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}",
            .{ self.dst.x, self.dst.y, self.dst.w, self.dst.h },
        );
        try writer.print(
            ",\"color\":[{d},{d},{d},{d}]",
            .{ self.color[0], self.color[1], self.color[2], self.color[3] },
        );

        if (self.corners) |c| {
            try writer.print(",\"corners\":{{\"l\":{d},\"r\":{d},\"t\":{d},\"b\":{d}}}", .{ c.l, c.r, c.t, c.b });
        }
        if (self.src_uv) |uv| {
            try writer.print(",\"src_uv\":{{\"u\":{d},\"v\":{d},\"w\":{d},\"h\":{d}}}", .{ uv.u, uv.v, uv.w, uv.h });
        }
        if (self.glyph) |g| {
            try writer.print(
                ",\"glyph\":{{\"char\":\"{c}\",\"advance\":{d},\"bearing\":[{d},{d}]}}",
                .{ g.char, g.advance, g.bearing_x, g.bearing_y },
            );
        }
        if (self.material) |m| {
            try writer.print(",\"material\":{{\"type\":\"{s}\",\"slot\":{d}}}", .{ m.mat_type, m.slot });
            if (m.curve_ref) |cr| {
                try writer.print(",\"curve\":\"{s}\"", .{cr});
            }
        }

        try writer.writeAll("}");
    }
};

/// Reference to a glyph character in the draw list.
pub const GlyphRef = struct {
    char: u8,
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
};

/// Reference to a GPU material (resolved to named reference for JSON).
pub const MaterialRef = struct {
    mat_type: []const u8, // "solid" | "glyph" | "rounded_rect"
    slot: u32,
    curve_ref: ?[]const u8 = null,
};

/// Convert SceneRect array into DrawCommand array.
pub fn collectDrawCommands(
    allocator: std.mem.Allocator,
    rects: []const SceneRect,
    ctx: *const HeadlessContext,
) ![]const DrawCommand {
    const cmds = try allocator.alloc(DrawCommand, rects.len);
    for (rects, cmds) |r, *cmd| {
        cmd.* = sliceRectToCommand(r, ctx);
    }
    return cmds;
}

fn sliceRectToCommand(r: SceneRect, ctx: *const HeadlessContext) DrawCommand {
    // Determine command type
    const is_glyph = r.material_index > 0 and r.curve[2] > 0 and r.curve[3] > 0;
    const is_border = r.color[3] > 0 and (r.corners[0] > 0 or r.corners[1] > 0 or r.corners[2] > 0 or r.corners[3] > 0);

    const cmd_type: []const u8 = if (is_glyph)
        "glyph"
    else if (is_border)
        "border_rect"
    else
        "fill_rect";

    var glyph: ?GlyphRef = null;
    var material: ?MaterialRef = null;

    if (is_glyph) {
        if (ctx.glyph_entries) |entries| {
            for (entries) |entry| {
                if (entry.material_slot + 1 == r.material_index) {
                    glyph = .{
                        .char = entry.char,
                        .advance = entry.advance,
                        .bearing_x = entry.bearing_x,
                        .bearing_y = entry.bearing_y,
                    };
                    material = .{
                        .mat_type = "glyph",
                        .slot = r.material_index,
                        .curve_ref = entry.curve_ref,
                    };
                    break;
                }
            }
        }
    } else if (r.material_index > 0 and !is_glyph) {
        material = .{
            .mat_type = "rounded_rect",
            .slot = r.material_index,
        };
    }

    return .{
        .cmd_type = cmd_type,
        .dst = .{ .x = r.dst[0], .y = r.dst[1], .w = r.dst[2], .h = r.dst[3] },
        .color = r.color,
        .corners = if (r.corners[0] > 0 or r.corners[1] > 0 or r.corners[2] > 0 or r.corners[3] > 0)
            .{ .l = r.corners[0], .r = r.corners[1], .t = r.corners[2], .b = r.corners[3] }
        else
            null,
        .src_uv = if (r.src[2] < 1.0 or r.src[3] < 1.0 or r.src[0] > 0 or r.src[1] > 0)
            .{ .u = r.src[0], .v = r.src[1], .w = r.src[2], .h = r.src[3] }
        else
            null,
        .glyph = glyph,
        .material = material,
    };
}

// ─── Draw List Collection (widget tree → RenderCommands) ─────────

/// Headless widget tree walker. Mirrors Window.collectWidgetRects()
/// but sources glyph data from HeadlessContext.glyph_entries instead
/// of Window.glyphs[]. Both write RenderCommands to the same list type.
///
/// The RectCollectCtx.headless variant records material_slot→char mappings
/// for JSON serialization instead of writing GPU material buffers.
fn collectWidgetRectsHeadless(
    win: *HeadlessWindow,
    root: *Widget,
    cmds: *RenderCommandList,
    ctx: *const RectCollectCtx,
) void {
    _ = win;
    var stack: [512]*Widget = undefined;
    var sp: u32 = 0;
    stack[sp] = root;
    sp += 1;

    while (sp > 0) {
        sp -= 1;
        const w = stack[sp];

        // Emit background rect if widget has color or border
        if (w.color[3] > 0 or w.border > 0) {
            cmds.push(.{ .solid_rect = .{
                .rect = .{ .x = w.rect.x, .y = w.rect.y, .w = w.rect.w, .h = w.rect.h },
                .color = w.color,
                .border = w.border,
                .border_color = w.border_color,
                .corner_l = w.corner_radius,
                .corner_r = w.corner_radius,
                .corner_t = w.corner_radius,
                .corner_b = w.corner_radius,
            } });
        }

        if (w.isContainer()) {
            if (w.children()) |kids| {
                var i: usize = kids.len;
                while (i > 0) {
                    i -= 1;
                    stack[sp] = kids[i];
                    sp += 1;
                }
            }
        } else {
            switch (w.kind) {
                .button => |btn| emitGlyphRectsHeadless(btn.label, w.rect, cmds, ctx),
                .slider => |s| {
                    const frac = if (s.max == s.min)
                        @as(f32, 0.5)
                    else
                        @max(0, @min(1, (s.value.* - s.min) / (s.max - s.min)));
                    const fill_w = @max(4, w.rect.w * frac);
                    const b = w.border;
                    cmds.push(.{ .solid_rect = .{
                        .rect = .{ .x = w.rect.x + b, .y = w.rect.y + b, .w = fill_w - 2 * b, .h = w.rect.h - 2 * b },
                        .color = .{ 0.824501, -0.095832, 0.068573, 1.0 },
                    } });
                },
                .label => |lbl| emitGlyphRectsHeadless(lbl.text, w.rect, cmds, ctx),
                else => {},
            }
        }
    }
}

/// Emit glyph RenderCommands using HeadlessContext.glyph_entries for
/// glyph data. Records material slot mappings via RectCollectCtx.headless
/// for JSON serialization.
/// Emit glyph RenderCommands using HeadlessContext.glyph_entries for
/// glyph data. Records material slot mappings via RectCollectCtx.headless
/// for JSON serialization.
fn emitGlyphRectsHeadless(
    text: []const u8,
    widget_rect: Rect,
    cmds: *RenderCommandList,
    ctx: *const RectCollectCtx,
    glyph_entries: ?[]const GlyphInfo,
) void {
    const hc = switch (ctx.*) {
        .headless => |h| h,
        .windowed => return, // should not be called in windowed mode
    };
    const entries = glyph_entries orelse return;

    const baseline_y = widget_rect.y + widget_rect.h * 0.75;
    var cursor_x = widget_rect.x;

    for (text) |ch| {
        var found: ?GlyphInfo = null;
        for (entries) |entry| {
            if (entry.char == ch) {
                found = entry;
                break;
            }
        }
        const entry = found orelse {
            cursor_x += 8; // approximate advance for unknown glyphs
            continue;
        };

        const ch_x = cursor_x + entry.bearing_x;
        const ch_y = baseline_y - entry.bearing_y;
        const ch_w = entry.glyph_w;
        const ch_h = entry.glyph_h;

        // Record material reference for JSON serialization
        hc.material_refs.append(hc.gpa, .{
            .mat_type = "glyph",
            .slot = entry.material_slot + 1,
            .curve_ref = &.{ch},
        }) catch unreachable;

        if (ch_w > 0 and ch_h > 0) {
            cmds.push(.{ .glyph = .{
                .rect = .{ .x = ch_x, .y = ch_y, .w = ch_w, .h = ch_h },
                .color = .{ 0, 0, 0, 0 },
                .material_index = entry.material_slot + 1,
                .curve_left = 0,
                .curve_bottom = 0,
                .curve_w = 1,
                .curve_h = 1,
            } });
        }
        cursor_x += entry.advance;
    }
}

// ─── LLM Snapshot Comparison ───────────────────────────

/// Compare mode: what an LLM (or test harness) checks between two snapshots.
pub const SnapshotDiffMode = enum {
    /// Exact match — every field must be identical (within float epsilon).
    exact,
    /// Structural match — same widget tree structure, positions may differ.
    structural,
    /// Semantic match — only user-visible properties (text, labels, values)
    /// must match; layout positions are ignored.
    semantic,
};

/// Float comparison epsilon for snapshot diffs.
pub const float_epsilon: f32 = 0.001;

/// Compare two FrameOutputs. Returns a list of differences (empty = pass).
/// Designed to produce human-readable diff descriptions that an LLM can
/// interpret for regression testing.
pub fn diffSnapshots(
    allocator: std.mem.Allocator,
    baseline: *const FrameOutput,
    current: *const FrameOutput,
    mode: SnapshotDiffMode,
) ![]const []const u8 {
    var diffs = std.ArrayList([]const u8).empty;
    errdefer {
        for (diffs.items) |d| allocator.free(d);
        diffs.deinit(allocator);
    }

    // Metadata check
    if (baseline.window_size.width != current.window_size.width or
        baseline.window_size.height != current.window_size.height)
    {
        try diffs.append(allocator, try std.fmt.allocPrint(
            allocator,
            "window_size: baseline={d}x{d} current={d}x{d}",
            .{
                baseline.window_size.width,
                baseline.window_size.height,
                current.window_size.width,
                current.window_size.height,
            },
        ));
    }

    // Widget tree diff
    try diffWidgetNodes(allocator, &baseline.widget_tree, &current.widget_tree, mode, &diffs, "root");

    // Draw list count
    if (baseline.draw_list.len != current.draw_list.len) {
        try diffs.append(allocator, try std.fmt.allocPrint(
            allocator,
            "draw_list length: baseline={d} current={d}",
            .{ baseline.draw_list.len, current.draw_list.len },
        ));
    } else if (mode == .exact) {
        // Per-command diff (only for exact mode)
        for (baseline.draw_list, current.draw_list, 0..) |bl, cur, i| {
            if (!std.mem.eql(u8, bl.cmd_type, cur.cmd_type)) {
                try diffs.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "draw[{d}].cmd_type: baseline={s} current={s}",
                    .{ i, bl.cmd_type, cur.cmd_type },
                ));
            }
            if (!floatsEqual(bl.dst.x, cur.dst.x) or !floatsEqual(bl.dst.y, cur.dst.y) or
                !floatsEqual(bl.dst.w, cur.dst.w) or !floatsEqual(bl.dst.h, cur.dst.h))
            {
                try diffs.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "draw[{d}].dst: baseline=({d:.1},{d:.1} {d:.1}x{d:.1}) current=({d:.1},{d:.1} {d:.1}x{d:.1})",
                    .{ i, bl.dst.x, bl.dst.y, bl.dst.w, bl.dst.h, cur.dst.x, cur.dst.y, cur.dst.w, cur.dst.h },
                ));
            }
            if (!floatsEqual(bl.color[0], cur.color[0]) or !floatsEqual(bl.color[1], cur.color[1]) or
                !floatsEqual(bl.color[2], cur.color[2]) or !floatsEqual(bl.color[3], cur.color[3]))
            {
                try diffs.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "draw[{d}].color: baseline=[{d},{d},{d},{d}] current=[{d},{d},{d},{d}]",
                    .{
                        i,
                        bl.color[0],
                        bl.color[1],
                        bl.color[2],
                        bl.color[3],
                        cur.color[0],
                        cur.color[1],
                        cur.color[2],
                        cur.color[3],
                    },
                ));
            }
        }
    }

    return diffs.toOwnedSlice(allocator);
}

fn diffWidgetNodes(
    allocator: std.mem.Allocator,
    bl: *const WidgetNode,
    cur: *const WidgetNode,
    mode: SnapshotDiffMode,
    diffs: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, bl.kind, cur.kind)) {
        try diffs.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}.kind: baseline={s} current={s}",
            .{ path, bl.kind, cur.kind },
        ));
        return; // different kind = different structure, stop recursing
    }

    if (mode == .exact) {
        if (bl.id != cur.id) {
            try diffs.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}.id: baseline={d} current={d}",
                .{ path, bl.id, cur.id },
            ));
        }
        if (!rectEqual(bl.rect, cur.rect)) {
            try diffs.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}.rect: baseline=({d:.1},{d:.1} {d:.1}x{d:.1}) current=({d:.1},{d:.1} {d:.1}x{d:.1})",
                .{ path, bl.rect.x, bl.rect.y, bl.rect.w, bl.rect.h, cur.rect.x, cur.rect.y, cur.rect.w, cur.rect.h },
            ));
        }
        if (!colorEqual(bl.color, cur.color)) {
            try diffs.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}.color: baseline=[{d},{d},{d},{d}] current=[{d},{d},{d},{d}]",
                .{
                    path,
                    bl.color[0],
                    bl.color[1],
                    bl.color[2],
                    bl.color[3],
                    cur.color[0],
                    cur.color[1],
                    cur.color[2],
                    cur.color[3],
                },
            ));
        }
    }

    // Leaf payload comparison (all modes)
    if (!std.mem.eql(u8, bl.label orelse "", cur.label orelse "")) {
        try diffs.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}.label: baseline=\"{s}\" current=\"{s}\"",
            .{ path, bl.label orelse "", cur.label orelse "" },
        ));
    }
    if (bl.value != null and cur.value != null and !floatsEqual(bl.value.?, cur.value.?)) {
        try diffs.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}.value: baseline={d} current={d}",
            .{ path, bl.value.?, cur.value.? },
        ));
    }

    // Recursive children comparison
    const bl_kids = bl.children orelse &.{};
    const cur_kids = cur.children orelse &.{};
    const min_kids = @min(bl_kids.len, cur_kids.len);

    if (bl_kids.len != cur_kids.len and mode != .semantic) {
        try diffs.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}.children count: baseline={d} current={d}",
            .{ path, bl_kids.len, cur_kids.len },
        ));
    }

    for (0..min_kids) |i| {
        const child_path = try std.fmt.allocPrint(allocator, "{s}.children[{d}]", .{ path, i });
        try diffWidgetNodes(allocator, &bl_kids[i], &cur_kids[i], mode, diffs, child_path);
    }
}

// ─── Helpers ────────────────────────────

fn floatsEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a == b) return true;
    const diff = if (a > b) a - b else b - a;
    return diff < float_epsilon;
}

fn rectEqual(a: anytype, b: @TypeOf(a)) bool {
    return floatsEqual(a.x, b.x) and floatsEqual(a.y, b.y) and
        floatsEqual(a.w, b.w) and floatsEqual(a.h, b.h);
}

fn colorEqual(a: [4]f32, b: [4]f32) bool {
    return floatsEqual(a[0], b[0]) and floatsEqual(a[1], b[1]) and
        floatsEqual(a[2], b[2]) and floatsEqual(a[3], b[3]);
}

// ─── Software Rasterizer (optional visual comparison) ─────────────

/// Simple scanline rasterizer for producing pixel buffers from the draw list.
/// Produces RGBA32 pixel data that can be compared pixel-by-pixel or written
/// to a PNG for visual inspection.
pub const SoftRasterizer = struct {
    width: u32,
    height: u32,
    /// RGBA8 pixel buffer (row-major, bottom-left origin).
    pixels: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !SoftRasterizer {
        const pixels = try allocator.alloc(u8, width * height * 4);
        @memset(pixels, 0);
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: *SoftRasterizer, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }

    /// Rasterize a draw list into the pixel buffer.
    /// Simple approach: fill rects, ignore glyphs (no curve rasterizer yet).
    /// For full visual comparison, glyphs need distance-field or scanline
    /// curve rasterization — left as future work.
    pub fn rasterize(self: *SoftRasterizer, draw_list: []const DrawCommand) void {
        for (draw_list) |cmd| {
            switch (cmd.cmd_type[0]) {
                'f', 'b' => self.fillRect(cmd),
                'g' => {}, // glyph: skip for now (needs curve rasterizer)
                else => {},
            }
        }
    }

    fn fillRect(self: *SoftRasterizer, cmd: DrawCommand) void {
        const max_w: f32 = @floatFromInt(self.width);
        const max_h: f32 = @floatFromInt(self.height);
        const x0 = @as(u32, @intFromFloat(@min(@max(0, cmd.dst.x), max_w)));
        const y0 = @as(u32, @intFromFloat(@min(@max(0, cmd.dst.y), max_h)));
        const x1 = @as(u32, @intFromFloat(@min(@max(0, cmd.dst.x + cmd.dst.w), max_w)));
        const y1 = @as(u32, @intFromFloat(@min(@max(0, cmd.dst.y + cmd.dst.h), max_h)));

        // Oklab → sRGB approximation (simplified — full conversion needs proper math)
        const r = colorComponentToU8(cmd.color[0], cmd.color[1], cmd.color[2], 0);
        const g = colorComponentToU8(cmd.color[0], cmd.color[1], cmd.color[2], 1);
        const b = colorComponentToU8(cmd.color[0], cmd.color[1], cmd.color[2], 2);
        const a = @as(u8, @intFromFloat(@min(255.0, cmd.color[3] * 255.0)));

        var y: u32 = y0;
        while (y < y1) : (y += 1) {
            var x: u32 = x0;
            while (x < x1) : (x += 1) {
                const idx = (y * self.width + x) * 4;
                // Alpha blending: over operator
                const src_a: f32 = @as(f32, @floatFromInt(a)) / 255.0;
                const dst_r: f32 = @floatFromInt(self.pixels[idx]);
                const dst_g: f32 = @floatFromInt(self.pixels[idx + 1]);
                const dst_b: f32 = @floatFromInt(self.pixels[idx + 2]);

                self.pixels[idx] = @intFromFloat(@min(255, dst_r * (1 - src_a) + @as(f32, @floatFromInt(r)) * src_a));
                self.pixels[idx + 1] = @intFromFloat(@min(
                    255,
                    dst_g * (1 - src_a) + @as(f32, @floatFromInt(g)) * src_a,
                ));
                self.pixels[idx + 2] = @intFromFloat(@min(
                    255,
                    dst_b * (1 - src_a) + @as(f32, @floatFromInt(b)) * src_a,
                ));
                self.pixels[idx + 3] = @intFromFloat(@min(
                    255,
                    @as(f32, @floatFromInt(self.pixels[idx + 3])) +
                        @as(f32, @floatFromInt(a)) *
                            (1 - @as(f32, @floatFromInt(self.pixels[idx + 3])) / 255.0),
                ));
            }
        }
    }

    /// Compare two pixel buffers. Returns number of differing pixels.
    /// Tolerance: per-channel difference < 2 is considered equal.
    pub fn diffPixels(a: []const u8, b: []const u8) u64 {
        std.debug.assert(a.len == b.len);
        var diff_count: u64 = 0;
        for (a, b) |pa, pb| {
            const da = if (pa > pb) pa - pb else pb - pa;
            if (da > 2) diff_count += 1;
        }
        return diff_count;
    }
};

/// Approximate Oklab → sRGB conversion for a single channel.
/// Full color pipeline needs the proper Oklab→linear sRGB→gamma matrix.
/// This is a simplified approximation suitable for visual inspection only.
fn colorComponentToU8(l: f32, a: f32, b: f32, component: u2) u8 {
    // Oklab approx: L maps roughly to luminance
    // R ≈ L + 0.4*a + 0.13*b, G ≈ L - 0.095*a - 0.03*b, B ≈ L - 0.012*a + 0.53*b
    const val: f32 = switch (component) {
        0 => l + 0.4 * a + 0.13 * b, // R
        1 => l - 0.095 * a - 0.03 * b, // G
        2 => l - 0.012 * a + 0.53 * b, // B
        3 => 0, // unreachable
    };
    return @intFromFloat(@min(255.0, @max(0.0, val * 255.0)));
}

// ─── JSON Snapshot File Format ───────────────────────────

/// Write a FrameOutput to a `.json` snapshot file.
/// The file format is a single JSON object per line (JSONL-friendly)
/// for multi-frame recordings.
pub fn writeSnapshot(frame: *const FrameOutput, writer: anytype) !void {
    try frame.writeJson(writer);
    try writer.writeAll("\n");
}

/// Read a snapshot from a JSON file. Returns parsed FrameOutput.
/// NOT IMPLEMENTED — deferred to when JSON parsing is needed.
/// For LLM testing, the LLM reads the raw JSON text directly.
pub fn readSnapshot(allocator: std.mem.Allocator, json: []const u8) !FrameOutput {
    _ = allocator;
    _ = json;
    return error.NotImplemented;
}

// ─── Tests ──────────────────────────────

const testing = std.testing;

fn testId(n: usize) Id {
    return @enumFromInt(n + 100);
}

test "HeadlessWindow: beginFrame creates DrawCtx" {
    var ctx = HeadlessContext.init(testing.allocator, "test");
    var win = try HeadlessWindow.init(&ctx, .{ .width = 800, .height = 600 });
    defer win.deinit();

    const dc = win.beginFrame();
    try testing.expectEqual(@as(f32, 800), dc.surface_size.width);
    try testing.expectEqual(@as(f32, 600), dc.surface_size.height);
}

test "WidgetNode: leaf widget serialization" {
    var w: Widget = .{
        .id = testId(42),
        .sizing = .{ .x = .fit, .y = .fit },
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 30 },
        .color = .{ 0.5, 0.1, -0.0, 1.0 },
        .border_color = .{ 0, 0, 0, 1 },
        .kind = .{ .label = .{ .text = "hello" } },
    };

    var node = try serializeWidgetTree(testing.allocator, &w);
    defer node.deinit(testing.allocator);

    try testing.expectEqualStrings("label", node.kind);
    try testing.expectEqual(@as(u64, 142), node.id);
    try testing.expectEqualStrings("hello", node.label.?);
    try testing.expectEqual(@as(f32, 10), node.rect.x);
    try testing.expectEqual(@as(f32, 100), node.rect.w);
}

test "WidgetNode: container with children" {
    var child1: Widget = .{
        .id = testId(1),
        .sizing = .{},
        .kind = .{ .label = .{ .text = "a" } },
    };
    var child2: Widget = .{
        .id = testId(2),
        .sizing = .{},
        .kind = .{ .label = .{ .text = "b" } },
    };
    var col: Widget = .{
        .id = testId(0),
        .sizing = .{},
        .kind = .{ .column = .{
            .children = &.{ &child1, &child2 },
            .padding = 8,
            .gap = 4,
        } },
    };

    var node = try serializeWidgetTree(testing.allocator, &col);
    defer node.deinit(testing.allocator);

    try testing.expectEqualStrings("column", node.kind);
    try testing.expectEqual(@as(f32, 8), node.padding.?);
    try testing.expectEqual(@as(f32, 4), node.gap.?);

    const kids = node.children.?;
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqualStrings("label", kids[0].kind);
    try testing.expectEqualStrings("a", kids[0].label.?);
    try testing.expectEqualStrings("b", kids[1].label.?);
}

test "floatsEqual: within epsilon" {
    try testing.expect(floatsEqual(@as(f32, 1.0), @as(f32, 1.0)));
    try testing.expect(floatsEqual(@as(f32, 1.0), @as(f32, 1.0001)));
    try testing.expect(!floatsEqual(@as(f32, 1.0), @as(f32, 1.01)));
}

test "diffSnapshots: identical widgets produce no diffs" {
    var frame1 = makeTestFrame(testing.allocator, 0);
    var frame2 = makeTestFrame(testing.allocator, 0);
    defer {
        frame1.widget_tree.deinit(testing.allocator);
        frame2.widget_tree.deinit(testing.allocator);
        testing.allocator.free(frame1.draw_list);
        testing.allocator.free(frame2.draw_list);
    }

    const diffs = try diffSnapshots(testing.allocator, &frame1, &frame2, .exact);
    defer {
        for (diffs) |d| testing.allocator.free(d);
        testing.allocator.free(diffs);
    }
    try testing.expectEqual(@as(usize, 0), diffs.len);
}

test "diffSnapshots: different rects produce diffs" {
    var frame1 = makeTestFrame(testing.allocator, 0);
    var frame2 = makeTestFrame(testing.allocator, 10); // offset rect by 10
    defer {
        frame1.widget_tree.deinit(testing.allocator);
        frame2.widget_tree.deinit(testing.allocator);
        testing.allocator.free(frame1.draw_list);
        testing.allocator.free(frame2.draw_list);
    }

    const diffs = try diffSnapshots(testing.allocator, &frame1, &frame2, .exact);
    defer {
        for (diffs) |d| testing.allocator.free(d);
        testing.allocator.free(diffs);
    }
    try testing.expect(diffs.len > 0);
}

test "SnapshotDiffMode: semantic ignores position" {
    var frame1 = makeTestFrame(testing.allocator, 0);
    var frame2 = makeTestFrame(testing.allocator, 50); // large position diff
    defer {
        frame1.widget_tree.deinit(testing.allocator);
        frame2.widget_tree.deinit(testing.allocator);
        testing.allocator.free(frame1.draw_list);
        testing.allocator.free(frame2.draw_list);
    }

    const diffs = try diffSnapshots(testing.allocator, &frame1, &frame2, .semantic);
    defer {
        for (diffs) |d| testing.allocator.free(d);
        testing.allocator.free(diffs);
    }
    // Semantic mode: same label, same kind → no diffs (position ignored)
    try testing.expectEqual(@as(usize, 0), diffs.len);
}

fn makeTestFrame(allocator: std.mem.Allocator, offset: f32) FrameOutput {
    const label_node: WidgetNode = .{
        .id = 1,
        .kind = "label",
        .rect = .{ .x = 10 + offset, .y = 20 + offset, .w = 100, .h = 24 },
        .sizing = .{ .x = .fit, .y = .fit },
        .border = 0,
        .corner_radius = 0,
        .color = .{ 0, 0, 0, 0 },
        .border_color = .{ 0, 0, 0, 1 },
        .label = "hello",
    };

    const draw_cmds = allocator.alloc(DrawCommand, 1) catch unreachable;
    draw_cmds[0] = .{
        .cmd_type = "fill_rect",
        .dst = .{ .x = 10 + offset, .y = 20 + offset, .w = 100, .h = 24 },
        .color = .{ 0.5, 0.1, 0.0, 1.0 },
    };

    return .{
        .frame_number = 0,
        .timestamp_ms = 0,
        .window_size = .{ .width = 800, .height = 600 },
        .test_name = "test_frame",
        .widget_tree = label_node,
        .draw_list = draw_cmds,
    };
}
