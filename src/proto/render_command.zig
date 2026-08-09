//! RenderCommand — flat enum array, the sole cross-layer rendering contract.
//!
//! Architecture
//! ────────────
//! Widget tree → collectWidgetRects(RectCollectCtx) → []RenderCommand
//!   → processRenderCommands() → SceneRect[] + GPU material writes
//!   → Batch9Slice.draw()
//!
//! WHY a lightweight tagged union instead of gpui-style Scene IR:
//!   - 3 active variants today (solid_rect, nine_slice, glyph) vs gpui's 8+
//!     pipeline types (Quad, Path, Shadow, Sprite, Underline, MonochromeSprite,
//!     ResolvedShadow, Border). 3<<8 means 10x less dispatch complexity.
//!   - Flat array: no Scene struct, no batch iterator, no PrimitiveBatch enum.
//!     Just a []RenderCommand passed to processRenderCommands().
//!   - Evolution path: when a 4th primitive arrives, add a variant.
//!     When dispatch logic grows, promote processRenderCommands to a
//!     match-based dispatcher. No premature architectural abstraction.
//!
//! WHY NOT dvui RenderCommand (23 variants across 7 shape types):
//!   - dvui's RenderCommand has 23+ variants (Circle, Path, Text, Image,
//!     Mesh, Callback, ClipPush, ClipPop, PushStack, PopStack, etc.)
//!     spread across dvui/renderer.zig and dvui/Backend.zig.
//!   - nogui renders ONE primitive (SceneRect) with material-index dispatch.
//!     dvui's 23-way dispatch would be 23x dead code paths.
//!   - When a 2nd primitive class arrives, promote to tagged union —
//!     the simplest thing that could possibly work.
//!
//! WHY NOT egui tessellator (Shape → Tessellator → ClippedPrimitive):
//!   - egui splits rendering into Shape emission → tessellation (CPU) →
//!     mesh submission. This made sense for backend agnosticism (any
//!     triangle renderer). nogui has one Vulkan backend with BDA and
//!     shader objects — tessellation happens in the shader (curve
//!     rendering via the scanline sweeper).
//!   - egui's Tessellator is 2000+ LOC handling 15 Shape variants with
//!     clip stack, path tessellation, circle LOD tables. nogui doesn't
//!     need any of that — 9-slice expansion is 238 LOC.
//!
//! PROTOTYPE — but the enum contract is final.

const std = @import("std");
const SceneRect = @import("render_9slice.zig").SceneRect;
const Widget = @import("widget.zig").Widget;
const Rect = @import("widget.zig").Rect;

// ─── RenderCommand enum ───────────────────────────────────────

/// One draw command. Lives in a flat []RenderCommand per frame.
/// No hierarchy, no Scene wrapper, no batch iterator.
/// Just a type tag + payload → processRenderCommands.
pub const RenderCommand = union(enum) {
    /// Opaque colored rectangle (no texture, no material).
    /// Per-vertex color is written directly; no GPU material slot consumed.
    /// Border > 0 emits two SceneRects: border background + inset fill.
    solid_rect: struct {
        rect: Rect,
        color: [4]f32,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
        corner_l: f32 = 0,
        corner_r: f32 = 0,
        corner_t: f32 = 0,
        corner_b: f32 = 0,
    },

    /// Textured 9-slice from the GPU material buffer (glyph or rounded rect).
    /// material_index selects the GlyphMaterial in the GPU buffer.
    nine_slice: struct {
        rect: Rect,
        color: [4]f32,
        material_index: u32,
        /// UV rect in the source texture (normalized 0..1).
        src_u: f32 = 0,
        src_v: f32 = 0,
        src_w: f32 = 1,
        src_h: f32 = 1,
        corner_l: f32 = 0,
        corner_r: f32 = 0,
        corner_t: f32 = 0,
        corner_b: f32 = 0,
    },

    /// Glyph draw — references a sweeper's curve data via material_index.
    /// UV is curve-space, not texture-space; shader reads curve_buf from material.
    glyph: struct {
        rect: Rect,
        color: [4]f32,
        material_index: u32,
        curve_left: f32,
        curve_bottom: f32,
        curve_w: f32,
        curve_h: f32,
    },

    /// Fullscreen blit: Oklab→sRGB conversion pass.
    /// Always emitted once per frame; processed by the blit pass.
    /// Not batched through Batch9Slice — uses fullscreen triangle + dedicated shader.
    blit_oklab: void,
};

// ─── RenderCommand arena ──────────────────────────────────────

/// Growable arena for RenderCommand collection.
/// Allocated from the frame arena; reset every frame.
pub const RenderCommandList = struct {
    items: []RenderCommand,
    len: u32,

    pub fn init(buf: []RenderCommand) RenderCommandList {
        return .{ .items = buf, .len = 0 };
    }

    pub fn push(self: *RenderCommandList, cmd: RenderCommand) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = cmd;
        self.len += 1;
    }

    pub fn slice(self: *const RenderCommandList) []const RenderCommand {
        return self.items[0..self.len];
    }
};

// ─── MaterialRef (shared between windowed and headless) ──────

/// Reference to a GPU material, resolved to named reference for JSON.
/// Used by headless serialization; windowed mode writes GPU directly.
pub const MaterialRef = struct {
    mat_type: []const u8, // "solid" | "glyph" | "rounded_rect"
    slot: u32,
    curve_ref: ?[]const u8 = null,
};

// ─── RectCollectCtx ──────────────────────────────────────────

/// Parameterizes collectWidgetRects for windowed vs headless mode.
/// No code duplication: the same DFS walks the widget tree and
/// dispatches to ctx.emitRect() / ctx.emitGlyph() for the final output.
///
/// Windowed mode: writes GPU material buffer + pushes RenderCommand.
/// Headless mode: records material metadata + pushes RenderCommand.
/// Both write to the same RenderCommandList — the renderer doesn't
/// know (or care) which context produced the commands.
///
/// IMPORTANT: No import of window.zig or headless.zig types here.
/// RectCollectCtx uses only primitive/stdlib types to avoid circular
/// dependencies. The leaf callers (window.zig's emitGlyphCommands,
/// headless.zig's emitGlyphRectsHeadless) know which ctx variant
/// to expect and cast/write accordingly.
pub const RectCollectCtx = union(enum) {
    /// Live GPU rendering. Writes materials to GPU buffer as glyph
    /// sweeper data is encountered. Requires Window ref for glyph atlas
    /// and material buffer access.
    windowed: struct {
        /// Opaque pointer — cast to *Window in the collector.
        window_ptr: *anyopaque,
        /// GPU buffer base address for GlyphSweeper.writeMaterial.
        material_buf_cpu: [*]u8,
    },

    /// Headless / test capture. Records material slot → glyph mapping
    /// for JSON serialization. No GPU access required.
    headless: struct {
        /// Append-only list of (material_slot → char) mappings.
        material_refs: *std.ArrayListUnmanaged(MaterialRef),
        /// Allocator for material_refs appends.
        gpa: std.mem.Allocator,
    },
};

// ─── Conversion: RenderCommand → SceneRect ───────────────────

/// Convert one RenderCommand to a SceneRect for the Batch9Slice pipeline.
/// Called by processRenderCommands() for each non-blit command.
pub fn commandToSliceRect(cmd: *const RenderCommand) SceneRect {
    return switch (cmd.*) {
        .solid_rect => |s| {
            const b = s.border;
            return SceneRect{
                .dst = .{ s.rect.x + b, s.rect.y + b, s.rect.w - 2 * b, s.rect.h - 2 * b },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ s.corner_l, s.corner_r, s.corner_t, s.corner_b },
                .color = s.color,
                .curve = .{ 0, 0, 0, 0 },
                .material_index = 0, // solid: per-vertex color
                // Old SliceRect glyph_pen was always null here, so the
                // emitter fell back to the rect top-left.
                .origin = .{ s.rect.x + b, s.rect.y + b },
            };
        },
        .nine_slice => |n| SceneRect{
            .dst = .{ n.rect.x, n.rect.y, n.rect.w, n.rect.h },
            .src = .{ n.src_u, n.src_v, n.src_w, n.src_h },
            .corners = .{ n.corner_l, n.corner_r, n.corner_t, n.corner_b },
            .color = n.color,
            .curve = .{ 0, 0, 0, 0 },
            .material_index = n.material_index,
            // Old SliceRect glyph_pen was always null here, so the
            // emitter fell back to the rect top-left.
            .origin = .{ n.rect.x, n.rect.y },
        },
        .glyph => |g| {
            // Glyph draws use curve-space UV encoding.
            // The SceneRect carries curve metadata so emitSceneRect
            // can compute per-vertex curve UVs instead of texture UVs.
            return SceneRect{
                .dst = .{ g.rect.x, g.rect.y, g.rect.w, g.rect.h },
                .src = .{ 0, 0, 1, 1 },
                .corners = .{ 0, 0, 0, 0 },
                .color = g.color,
                .curve = .{ g.curve_left, g.curve_bottom, g.curve_w, g.curve_h },
                .material_index = g.material_index,
                // This proto path never set glyph_pen: the emitter's old
                // fallback anchored the origin at the rect top-left.
                .origin = .{ g.rect.x, g.rect.y },
            };
        },
        .blit_oklab => unreachable, // handled separately, never converted
    };
}

/// Convert a border+fill RenderCommand pair into two SceneRects.
/// Widgets with border > 0 emit two solid_rect commands: border first, fill second.
pub fn borderCommandToSliceRects(cmd: *const RenderCommand, buf: *[2]SceneRect) u32 {
    const s = cmd.solid_rect;
    if (s.border <= 0) {
        buf[0] = commandToSliceRect(cmd);
        return 1;
    }
    // Border rect (full extents, border color)
    buf[0] = SceneRect{
        .dst = .{ s.rect.x, s.rect.y, s.rect.w, s.rect.h },
        .src = .{ 0, 0, 1, 1 },
        .corners = .{ 0, 0, 0, 0 },
        .color = s.border_color, // border uses a separate color field
        .curve = .{ 0, 0, 0, 0 },
        .material_index = 0,
        .origin = .{ s.rect.x, s.rect.y },
    };
    // Fill rect (inset by border)
    buf[1] = SceneRect{
        .dst = .{ s.rect.x + s.border, s.rect.y + s.border, s.rect.w - 2 * s.border, s.rect.h - 2 * s.border },
        .src = .{ 0, 0, 1, 1 },
        .corners = .{ 0, 0, 0, 0 },
        .color = s.color,
        .curve = .{ 0, 0, 0, 0 },
        .material_index = 0,
        .origin = .{ s.rect.x + s.border, s.rect.y + s.border },
    };
    return 2;
}

// ─── Process pipeline ───────────────────────────────────────

/// Process a RenderCommand array into the output buffers Batch9Slice needs.
/// Returns the count of SceneRects written to slice_rects_out.
///
/// This is the ONLY place dispatch logic lives. Adding a new primitive
/// means adding a variant to RenderCommand + a case here — no other
/// code changes (unless the primitive needs a new shader/pipeline state).
pub fn processRenderCommands(
    cmds: []const RenderCommand,
    slice_rects_out: []SceneRect,
    material_buf_bda: u64,
    material_cpu: ?[]u8,
    next_material_slot: *u32,
    window: anytype,
) u32 {
    _ = material_buf_bda;
    _ = material_cpu;
    _ = next_material_slot;
    _ = window;
    var ri: u32 = 0;

    for (cmds) |cmd| {
        switch (cmd) {
            .blit_oklab => {
                // blit is handled at the render-pass level by Window.endFrame().
                // The RenderCommand records that a blit is needed (always yes).
                // No SceneRect emitted.
            },
            .solid_rect => {
                if (ri + 2 > slice_rects_out.len) break;
                var pair: [2]SceneRect = undefined;
                const n = borderCommandToSliceRects(&cmd, &pair);
                for (pair[0..n]) |sr| {
                    slice_rects_out[ri] = sr;
                    ri += 1;
                }
            },
            .nine_slice => {
                if (ri >= slice_rects_out.len) break;
                slice_rects_out[ri] = commandToSliceRect(&cmd);
                ri += 1;
            },
            .glyph => {
                if (ri >= slice_rects_out.len) break;
                // Material write happens during tree walk in windowed mode,
                // or via material_refs recording in headless mode.
                slice_rects_out[ri] = commandToSliceRect(&cmd);
                ri += 1;
            },
        }
    }

    return ri;
}
