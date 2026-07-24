//! Per-frame drawing context. Allocates the widget tree into
//! the frame arena and runs layout.
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const Widget = @import("widget.zig").Widget;
const Sizing = @import("widget.zig").Sizing;
const Size = @import("widget.zig").Size;
const Rect = @import("widget.zig").Rect;
const Pos = @import("widget.zig").Pos;
const Direction = @import("widget.zig").Direction;
const layout = @import("layout.zig");

/// Temporary ID counter for widgets created without @src().
/// Only used for prototype simplicity; real impl uses @src() hashes.
var next_temp_id: u64 = 1;
fn tempId() u64 {
    const id = next_temp_id;
    next_temp_id += 1;
    return id;
}

/// Shared styling options for all widgets.
pub const StyleOpts = struct {
    sizing: Sizing = .{ .x = .grow, .y = .fit },
    color: [4]f32 = .{ 0, 0, 0, 0 },
    corner_radius: f32 = 0,
    border: f32 = 0,
    border_color: [4]f32 = .{ 0, 0, 0, 1 },
};

fn applyStyle(w: *Widget, opts: StyleOpts) void {
    w.sizing = opts.sizing;
    w.color = opts.color;
    w.corner_radius = opts.corner_radius;
    w.border = opts.border;
    w.border_color = opts.border_color;
}

/// Per-frame drawing context provided to `Gui.draw()`.
/// Widgets are allocated into the frame arena. After draw()
/// returns, the Window runs layout and (in the future) rendering.
pub const DrawCtx = struct {
    /// Frame arena allocator — reset every frame.
    allocator: std.mem.Allocator,

    /// The available area for the root widget.
    surface_size: Size,

    // ─── Widget constructors ─────────────────────────
    // All allocate into the frame arena.

    pub fn column(self: *@This(), children: []const *Widget, opts: struct {
        padding: f32 = 0,
        gap: f32 = 4,
        sizing: Sizing = .{ .x = .grow, .y = .grow },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
    }) !*Widget {
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = tempId(),
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .column = .{
                .children = children,
                .padding = opts.padding,
                .gap = opts.gap,
            } },
        };
        return w;
    }

    pub fn row(self: *@This(), children: []const *Widget, opts: struct {
        padding: f32 = 0,
        gap: f32 = 4,
        sizing: Sizing = .{ .x = .grow, .y = .grow },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
    }) !*Widget {
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = tempId(),
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .row = .{
                .children = children,
                .padding = opts.padding,
                .gap = opts.gap,
            } },
        };
        return w;
    }

    pub fn button(self: *@This(), btn_label: []const u8, opts: struct {
        sizing: Sizing = .{ .x = .fit, .y = .fit },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
    }) !*Widget {
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = tempId(),
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .button = .{ .label = btn_label } },
        };
        return w;
    }

    pub fn slider(self: *@This(), slider_label: []const u8, value: *f32, min: f32, max: f32, opts: struct {
        sizing: Sizing = .{ .x = .grow, .y = .fit },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
    }) !*Widget {
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = tempId(),
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .slider = .{
                .label = slider_label,
                .value = value,
                .min = min,
                .max = max,
            } },
        };
        return w;
    }

    pub fn label(self: *@This(), text: []const u8, opts: struct {
        sizing: Sizing = .{ .x = .fit, .y = .fit },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
    }) !*Widget {
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = tempId(),
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .label = .{ .text = text } },
        };
        return w;
    }

    // ─── Layout runner ──────────────────────────────

    /// Run two-phase layout on the widget tree.
    pub fn layoutAndRender(self: *@This(), root: *Widget) void {
        const result = layout.measure(root, self.surface_size);

        // For grow root, expand to fill surface. Otherwise center.
        const final_w = if (root.sizing.x == .grow) self.surface_size.width else result.size.width;
        const final_h = if (root.sizing.y == .grow) self.surface_size.height else result.size.height;

        layout.layout(root, .{ .x = 0, .y = 0 }, .{ .width = final_w, .height = final_h });
    }
};
