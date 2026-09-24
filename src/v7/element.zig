//! Arena-owned custom elements. Hooks see frame values, not Session or GPU state.
const std = @import("std");
const widget = @import("widget.zig");
const DrawCtx = @import("drawctx.zig").DrawCtx;
const layout = @import("layout/root.zig");
const sizing = @import("layout/sizing.zig");
const paint = @import("paint.zig");
const path = paint.path;
const FrameNodeId = @import("id.zig").FrameNodeId;
const ComponentId = @import("key.zig").ComponentId;
const ComponentDefaults = @import("style.zig").ComponentDefaults;

pub const MeasureInput = layout.MeasureInput;
pub const Error = sizing.Error;
pub const LateScope = enum { none, query, list };
pub const Role = enum { image, group, text, control };

pub const Semantic = struct {
    role: Role,
    label: []const u8,
};

pub const max_semantic_bytes: usize = 4096;

/// Visual border and content boxes in logical window coordinates.
pub const Geometry = struct {
    border: widget.Rect,
    content: widget.Rect,
};

/// Authored content-local canvas records. Borrowed variable-size inputs are
/// copied into the frame arena before a paint hook returns.
pub const PaintRecord = union(enum) {
    rect: paint.RectPaint,
    path: paint.PathPaint,
    image: paint.ImagePaint,
};

/// The only mutable output available during an element's paint phase.
/// Bounds are relative to the final prepaint content origin; path commands
/// are relative to their own bounds origin.
pub const PaintWriter = struct {
    allocator: std.mem.Allocator,
    records: *std.ArrayListUnmanaged(PaintRecord),
    pub const max_records: usize = 256;
    pub const max_path_commands: usize = 4096;
    pub const max_dashes: usize = 256;
    pub const max_shadows: usize = 64;

    pub fn addRect(self: *PaintWriter, spec: paint.RectPaint) Error!void {
        try self.checkCapacity();
        try checkHeader(spec.bounds, spec.opacity, spec.transform);
        if (spec.shadows.len > max_shadows) return error.PaintCapacityExceeded;
        if (spec.fill) |fill| try checkFill(fill);
        for (spec.radii) |radius| {
            if (!std.math.isFinite(radius) or radius < 0) return error.InvalidPaint;
        }
        for (spec.borders) |border| {
            if (!std.math.isFinite(border.width) or border.width < 0) return error.InvalidPaint;
            try checkColor(border.color);
        }
        for (spec.shadows) |shadow| {
            try checkColor(shadow.color);
            if (!validPoint(shadow.offset) or !std.math.isFinite(shadow.blur) or
                !std.math.isFinite(shadow.spread) or shadow.blur < 0) return error.InvalidPaint;
            const pad = shadow.blur + @max(shadow.spread, 0);
            if (!std.math.isFinite(pad) or
                !std.math.isFinite(spec.bounds.x + shadow.offset.x - pad) or
                !std.math.isFinite(spec.bounds.y + shadow.offset.y - pad) or
                !std.math.isFinite(spec.bounds.w + 2 * pad) or
                !std.math.isFinite(spec.bounds.h + 2 * pad)) return error.InvalidPaint;
        }
        const owned = if (spec.shadows.len == 0)
            &.{}
        else
            try self.allocator.dupe(paint.Shadow, spec.shadows);
        errdefer if (owned.len > 0) self.allocator.free(owned);
        var record = spec;
        record.shadows = owned;
        try self.records.append(self.allocator, .{ .rect = record });
    }

    pub fn addPath(self: *PaintWriter, spec: paint.PathPaint) Error!void {
        try self.checkCapacity();
        try checkHeader(spec.bounds, spec.opacity, spec.transform);
        if (spec.path.commands.len > max_path_commands) return error.PathCapacity;
        if (spec.path.commands.len == 0) return error.InvalidPath;
        if (spec.fill) |fill| try checkFill(fill);
        if (spec.stroke) |stroke| {
            if (!std.math.isFinite(stroke.width) or stroke.width <= 0 or
                !std.math.isFinite(stroke.phase) or stroke.phase < 0 or
                !std.math.isFinite(spec.bounds.w + stroke.width) or
                !std.math.isFinite(spec.bounds.h + stroke.width)) return error.InvalidPaint;
            if (stroke.dash.len > max_dashes) return error.PathCapacity;
            try checkColor(stroke.color);
            for (stroke.dash) |dash| {
                if (!std.math.isFinite(dash) or dash <= 0) return error.InvalidPaint;
            }
        }
        try checkPath(spec.path);
        const commands = try self.allocator.dupe(path.Command, spec.path.commands);
        errdefer self.allocator.free(commands);
        const owned_dash: []const f32 = if (spec.stroke) |stroke| blk: {
            if (stroke.dash.len == 0) break :blk &.{};
            break :blk try self.allocator.dupe(f32, stroke.dash);
        } else &.{};
        errdefer if (owned_dash.len > 0) self.allocator.free(owned_dash);

        var record = spec;
        record.path.commands = commands;
        if (record.stroke) |*stroke| {
            stroke.dash = owned_dash;
        }
        try self.records.append(self.allocator, .{ .path = record });
    }

    /// A borrowed, already-uploaded Oklab image; no pixel bytes are copied.
    pub fn addImage(self: *PaintWriter, spec: paint.ImagePaint) Error!void {
        try self.checkCapacity();
        try checkHeader(spec.bounds, spec.opacity, .{});
        if (!paint.validImage(spec)) return error.InvalidPaint;
        try self.records.append(self.allocator, .{ .image = spec });
    }

    /// Existing solid-rect callers use the same typed authored rectangle path.
    pub fn rect(self: *PaintWriter, bounds: widget.Rect, color: [4]f32) Error!void {
        try self.checkCapacity();
        checkHeader(.{
            .x = bounds.x,
            .y = bounds.y,
            .w = bounds.w,
            .h = bounds.h,
        }, 1, .{}) catch return error.InvalidStyle;
        for (color) |channel| {
            if (!std.math.isFinite(channel) or channel < 0 or channel > 1) {
                return error.InvalidStyle;
            }
        }
        try self.addRect(.{
            .bounds = .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h },
            .fill = .{ .solid = .{ .srgb = .{
                .r = color[0],
                .g = color[1],
                .b = color[2],
                .a = color[3],
            } } },
        });
    }

    fn checkCapacity(self: *const PaintWriter) Error!void {
        if (self.records.items.len >= max_records) return error.PaintCapacityExceeded;
    }
};

fn validPoint(point: paint.Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn checkHeader(bounds: paint.Rect, opacity: f32, transform: paint.Affine) Error!void {
    if (!validPoint(.{ .x = bounds.x, .y = bounds.y }) or
        !std.math.isFinite(bounds.w) or !std.math.isFinite(bounds.h) or
        bounds.w < 0 or bounds.h < 0 or
        !std.math.isFinite(bounds.x + bounds.w) or
        !std.math.isFinite(bounds.y + bounds.h) or
        !std.math.isFinite(opacity) or opacity < 0 or opacity > 1)
        return error.InvalidPaint;
    for ([_]f32{ transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty }) |component| {
        if (!std.math.isFinite(component)) return error.InvalidPaint;
    }
    for ([_]paint.Point{
        .{ .x = bounds.x, .y = bounds.y },
        .{ .x = bounds.x + bounds.w, .y = bounds.y },
        .{ .x = bounds.x, .y = bounds.y + bounds.h },
        .{ .x = bounds.x + bounds.w, .y = bounds.y + bounds.h },
    }) |corner| {
        if (!validPoint(transform.apply(corner))) return error.InvalidPaint;
    }
}

fn checkColor(color: paint.Color) Error!void {
    switch (color) {
        .palette => {},
        .srgb => |value| for ([_]f32{ value.r, value.g, value.b, value.a }) |channel| {
            if (!std.math.isFinite(channel) or channel < 0 or channel > 1)
                return error.InvalidPaint;
        },
        .oklab => |value| {
            for ([_]f32{ value.l, value.a, value.b, value.alpha }) |component| {
                if (!std.math.isFinite(component)) return error.InvalidPaint;
            }
            if (value.alpha < 0 or value.alpha > 1) return error.InvalidPaint;
        },
    }
}

fn checkFill(fill: paint.Fill) Error!void {
    switch (fill) {
        .solid => |color| try checkColor(color),
        .gradient => |gradient| {
            if (!std.math.isFinite(gradient.angle) or
                !std.math.isFinite(gradient.first.position) or
                !std.math.isFinite(gradient.second.position) or
                gradient.first.position < 0 or gradient.second.position > 1 or
                gradient.first.position >= gradient.second.position)
                return error.InvalidPaint;
            try checkColor(gradient.first.color);
            try checkColor(gradient.second.color);
        },
        .pattern => |pattern| {
            if (!validPoint(pattern.cell) or pattern.cell.x <= 0 or pattern.cell.y <= 0)
                return error.InvalidPaint;
            try checkColor(pattern.first);
            try checkColor(pattern.second);
        },
        .image_pattern => |image| {
            if (!validPoint(image.tile) or image.tile.x <= 0 or image.tile.y <= 0 or
                image.texture_index == 0xFFFFFFFF) return error.InvalidPaint;
        },
    }
}

fn checkPath(shape: path.Path) Error!void {
    var has_current = false;
    for (shape.commands) |command| {
        switch (command) {
            .move => |point| {
                if (!validPoint(point)) return error.InvalidPath;
                has_current = true;
            },
            .line => |point| {
                if (!has_current or !validPoint(point)) return error.InvalidPath;
            },
            .quadratic => |curve| {
                if (!has_current or !validPoint(curve.control) or !validPoint(curve.end))
                    return error.InvalidPath;
            },
            .cubic => |curve| {
                if (!has_current or !validPoint(curve.first) or
                    !validPoint(curve.second) or !validPoint(curve.end))
                    return error.InvalidPath;
            },
            .arc => |arc| {
                if (!has_current or !validPoint(arc.center) or !validPoint(arc.radii) or
                    arc.radii.x <= 0 or arc.radii.y <= 0 or
                    !std.math.isFinite(arc.start) or !std.math.isFinite(arc.sweep) or
                    @abs(arc.sweep) > 2 * std.math.pi or
                    !validPoint(.{
                        .x = arc.center.x + arc.radii.x * @cos(arc.start + arc.sweep),
                        .y = arc.center.y + arc.radii.y * @sin(arc.start + arc.sweep),
                    })) return error.InvalidPath;
            },
            .close => {
                if (!has_current) return error.InvalidPath;
            },
        }
    }
}

pub const Operations = struct {
    measure: *const fn (*const anyopaque, MeasureInput) Error!widget.Size,
    layout: ?*const fn (*const anyopaque, *anyopaque, Geometry) Error!void,
    prepaint: ?*const fn (*const anyopaque, *anyopaque, Geometry) Error!void,
    paint: ?*const fn (*const anyopaque, *anyopaque, Geometry, *PaintWriter) Error!void,
    semantics: ?*const fn (*const anyopaque, *anyopaque, Geometry) Error!?Semantic,
    build_late: ?*const fn (*const anyopaque, widget.Size, *DrawCtx) anyerror!void,
    /// Publish staged persistent state only after the App commits this frame.
    commit: ?*const fn (*const anyopaque, *const anyopaque) void,
};

/// Restore the creating component while a late subroot is built.
pub const ComponentScope = struct {
    owner: FrameNodeId = .root,
    identity: ComponentId = .root,
    defaults: ComponentDefaults = .{},
};

pub const Frame = struct {
    payload: *const anyopaque,
    phase: *anyopaque,
    ops: *const Operations,
    revision: u64,
    late_scope: LateScope,
    component_scope: ComponentScope = .{},
    paint_records: std.ArrayListUnmanaged(PaintRecord) = .empty,
    semantic: ?Semantic = null,

    pub fn phaseState(self: *const Frame, comptime State: type) *const State {
        return @ptrCast(@alignCast(self.phase));
    }
};

/// Store a payload and its phase state in this frame's arena. A payload with
/// borrowed slices must copy those slices into the arena before construction.
pub fn make(comptime T: type, arena: std.mem.Allocator, value: T, late_scope: LateScope) !*Frame {
    if (@typeInfo(T) != .@"struct") @compileError("element payload must be a struct");
    if (!@hasDecl(T, "measure")) @compileError("element payload must declare measure");
    if (late_scope != .none and !@hasDecl(T, "buildLate")) return error.InvalidStyle;
    const State = if (@hasDecl(T, "PhaseState")) T.PhaseState else struct {};
    const Adapter = struct {
        fn measure(payload: *const anyopaque, input: MeasureInput) Error!widget.Size {
            const typed: *const T = @ptrCast(@alignCast(payload));
            return T.measure(typed, input);
        }
        fn layoutHook(payload: *const anyopaque, phase: *anyopaque, geometry: Geometry) Error!void {
            const typed: *const T = @ptrCast(@alignCast(payload));
            const state: *State = @ptrCast(@alignCast(phase));
            return T.layout(typed, state, geometry);
        }
        fn prepaint(payload: *const anyopaque, phase: *anyopaque, geometry: Geometry) Error!void {
            const typed: *const T = @ptrCast(@alignCast(payload));
            const state: *State = @ptrCast(@alignCast(phase));
            return T.prepaint(typed, state, geometry);
        }
        fn paint(payload: *const anyopaque, phase: *anyopaque, geometry: Geometry, writer: *PaintWriter) Error!void {
            const typed: *const T = @ptrCast(@alignCast(payload));
            const state: *State = @ptrCast(@alignCast(phase));
            return T.paint(typed, state, geometry, writer);
        }
        fn semantics(payload: *const anyopaque, phase: *anyopaque, geometry: Geometry) Error!?Semantic {
            const typed: *const T = @ptrCast(@alignCast(payload));
            const state: *State = @ptrCast(@alignCast(phase));
            return T.semantics(typed, state, geometry);
        }
        fn buildLate(payload: *const anyopaque, size: widget.Size, ctx: *DrawCtx) anyerror!void {
            const typed: *const T = @ptrCast(@alignCast(payload));
            return T.buildLate(typed, size, ctx);
        }
        fn commit(payload: *const anyopaque, phase: *const anyopaque) void {
            const typed: *const T = @ptrCast(@alignCast(payload));
            const state: *const State = @ptrCast(@alignCast(phase));
            T.commit(typed, state);
        }
    };
    const ops: Operations = comptime .{
        .measure = Adapter.measure,
        .layout = if (@hasDecl(T, "layout")) Adapter.layoutHook else null,
        .prepaint = if (@hasDecl(T, "prepaint")) Adapter.prepaint else null,
        .paint = if (@hasDecl(T, "paint")) Adapter.paint else null,
        .semantics = if (@hasDecl(T, "semantics")) Adapter.semantics else null,
        .build_late = if (@hasDecl(T, "buildLate")) Adapter.buildLate else null,
        .commit = if (@hasDecl(T, "commit")) Adapter.commit else null,
    };
    const Allocation = struct {
        frame: Frame,
        payload: T,
        state: State,
    };
    const allocation = try arena.create(Allocation);
    allocation.payload = value;
    allocation.state = .{};
    allocation.frame = .{
        .payload = &allocation.payload,
        .phase = &allocation.state,
        .ops = &ops,
        .revision = if (@hasField(T, "revision")) value.revision else 0,
        .late_scope = late_scope,
    };
    return &allocation.frame;
}

/// Run the fallible LAYOUT stages of a frame: measuring, one bounded late
/// subroot build per wave, and the element layout hooks. The paint stages run
/// afterwards through `finishFrame`, so a caller with work of its own between
/// them — resolving overlay placement against the final laid-out geometry —
/// does not see custom hooks run twice or with pre-placement boxes.
///
/// Every bounded late scope builds once after measuring itself; new nested
/// queries wait for the next layout wave. Ends in the `.layout` phase.
pub fn prepareLayout(ctx: *DrawCtx, options: layout.Options) anyerror!void {
    if (ctx.phase != .drawing or ctx.parent_stack.items.len != 0) return error.PhaseReentry;
    ctx.phase = .measuring;
    errdefer ctx.phase = .failed;
    try layout.layoutTree(ctx.tree, options);
    if (ctx.phase != .measuring) return error.PhaseReentry;
    var built_ids: [64]FrameNodeId = undefined;
    var built_count: usize = 0;
    while (true) {
        const wave_count = ctx.tree.nodes.items.len;
        var built_this_wave = false;
        for (0..wave_count) |index| {
            const candidate = &ctx.tree.nodes.items[index];
            if (candidate.kind != .element or candidate.kind.element.late_scope == .none or
                candidate.layout_hidden) continue;
            const id = candidate.id;
            var already_built = false;
            for (built_ids[0..built_count]) |previous| {
                if (previous == id) {
                    already_built = true;
                    break;
                }
            }
            if (already_built) continue;
            if (built_count == built_ids.len) return error.LateSubrootLimit;
            built_ids[built_count] = id;
            built_count += 1;
            built_this_wave = true;
            const frame = candidate.kind.element;
            const builder = frame.ops.build_late orelse return error.InvalidStyle;
            const previous_scope: ComponentScope = .{
                .owner = ctx.component_id,
                .identity = ctx.component_identity,
                .defaults = ctx.component_defaults,
            };
            const creating_scope = frame.component_scope;
            try ctx.parent_stack.ensureUnusedCapacity(ctx.arena, 1);
            ctx.parent_stack.appendAssumeCapacity(.{ .id = id, .index = @intCast(index) });
            ctx.phase = .late_build;
            ctx.late_nodes_remaining = 1024;
            const content = widget.visualContentRect(ctx.tree, id);
            ctx.component_id = creating_scope.owner;
            ctx.component_identity = creating_scope.identity;
            ctx.component_defaults = creating_scope.defaults;
            {
                defer {
                    ctx.component_id = previous_scope.owner;
                    ctx.component_identity = previous_scope.identity;
                    ctx.component_defaults = previous_scope.defaults;
                }
                try builder(frame.payload, .{ .width = content.w, .height = content.h }, ctx);
            }
            if (ctx.phase != .late_build or ctx.parent_stack.items.len != 1 or
                ctx.parent_stack.items[0].id != id or ctx.clip_depth != 0)
                return error.PhaseReentry;
            ctx.parent_stack.clearRetainingCapacity();
            ctx.phase = .measuring;
        }
        if (!built_this_wave) break;
        // Late-built ScrollState values are caller-owned: snapshot before the
        // next layout can update their limits, so failed attempts roll back.
        if (ctx.scroll_before_layout) |ledger| {
            for (ctx.tree.nodes.items[wave_count..]) |new_node| {
                if (new_node.scroll) |scroll| {
                    const entry = try ledger.getOrPut(ctx.arena, scroll.state);
                    if (!entry.found_existing) entry.value_ptr.* = scroll.state.*;
                }
            }
        }
        try ctx.tree.finalizePostorder(options.allocator);
        try layout.layoutTree(ctx.tree, options);
        if (ctx.phase != .measuring) return error.PhaseReentry;
    }
    // The tree now has its final measured geometry. The element layout hooks
    // deliberately do NOT run here: a caller with work between layout and
    // paint — overlay placement — has not run it yet, and a hook that cached
    // the pre-placement flow position would keep drawing at it.
    ctx.phase = .measured;
}

/// Run the element layout hooks against the FINAL window geometry, then the
/// paint stages: prepaint, paint and semantics, in that order, then `.done`.
/// Every hook runs exactly once per frame, whatever a caller did between the
/// two stages.
pub fn finishFrame(ctx: *DrawCtx) anyerror!void {
    if (ctx.phase != .measured or ctx.parent_stack.items.len != 0) return error.PhaseReentry;
    errdefer ctx.phase = .failed;
    ctx.phase = .layout;
    for (ctx.tree.nodes.items) |*node| {
        if (node.kind != .element or node.layout_hidden) continue;
        const frame = node.kind.element;
        if (frame.ops.layout) |hook| try hook(frame.payload, frame.phase, elementGeometry(ctx.tree, node.id));
        if (ctx.phase != .layout) return error.PhaseReentry;
    }

    ctx.phase = .prepaint;
    for (ctx.tree.nodes.items) |*node| {
        if (node.kind != .element or node.paint_hidden) continue;
        const frame = node.kind.element;
        if (frame.ops.prepaint) |hook| try hook(frame.payload, frame.phase, elementGeometry(ctx.tree, node.id));
        if (ctx.phase != .prepaint) return error.PhaseReentry;
    }
    ctx.phase = .paint;
    for (ctx.tree.nodes.items) |*node| {
        if (node.kind != .element or node.paint_hidden) continue;
        const frame = node.kind.element;
        if (frame.ops.paint) |hook| {
            var writer: PaintWriter = .{ .allocator = ctx.arena, .records = &frame.paint_records };
            try hook(frame.payload, frame.phase, elementGeometry(ctx.tree, node.id), &writer);
            if (frame.paint_records.items.len > PaintWriter.max_records)
                return error.PaintCapacityExceeded;
            if (ctx.phase != .paint) return error.PhaseReentry;
        }
    }
    ctx.phase = .semantics;
    for (ctx.tree.nodes.items) |*node| {
        if (node.kind != .element or node.paint_hidden) continue;
        const frame = node.kind.element;
        if (frame.ops.semantics) |hook| {
            if (try hook(frame.payload, frame.phase, elementGeometry(ctx.tree, node.id))) |semantic| {
                if (semantic.label.len > max_semantic_bytes)
                    return error.SemanticCapacityExceeded;
                frame.semantic = .{
                    .role = semantic.role,
                    .label = try ctx.arena.dupe(u8, semantic.label),
                };
            }
            if (ctx.phase != .semantics) return error.PhaseReentry;
        }
    }
    ctx.phase = .done;
}

/// Every stage of a frame in one call, for callers with no work of their own
/// between layout and paint.
pub fn prepareFrame(ctx: *DrawCtx, options: layout.Options) anyerror!void {
    try prepareLayout(ctx, options);
    try finishFrame(ctx);
}

fn elementGeometry(tree: *const widget.WidgetTree, id: FrameNodeId) Geometry {
    return .{
        .border = widget.visualBorderRect(tree, id),
        .content = widget.visualContentRect(tree, id),
    };
}
