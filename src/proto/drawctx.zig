//! Per-frame drawing context. Allocates the widget tree into
//! the frame arena and runs layout.
//!
//! Two constructor APIs coexist during the prototype:
//!
//!   FINAL API (deterministic IDs via @src()):
//!     dc.button(@src(), "Click", .{});
//!     dc.label(@src(), "Hello", .{});
//!     dc.beginColumn(@src(), .{ ... }) / dc.endColumn()
//!
//!   PROTOTYPE API (sequential temp IDs, no persistence):
//!     dc.tempButton("Click", .{});
//!     dc.tempLabel("Hello", .{});
//!     dc.tempColumn(children, .{});
//!
//! The final API uses Id.widgetId(@src(), parentId(), extra) for
//! deterministic cross-frame identity.  The prototype API uses
//! a sequential counter — fine for layout-only testing.
//!
//! PROTOTYPE — throwaway design exploration. Will be replaced by
//! the final API when event handling is wired.

const std = @import("std");
const Widget = @import("widget.zig").Widget;
const Sizing = @import("widget.zig").Sizing;
const Size = @import("widget.zig").Size;
const Id = @import("widget.zig").Id;
const Context = @import("context.zig").Context;
const WidgetState = @import("context.zig").WidgetState;
const layout = @import("layout.zig");
const event = @import("event.zig");

// ─── Temporary ID counter (prototype fallback) ────────

var next_temp_id: u64 = 1;
fn tempId() u64 {
    const id = next_temp_id;
    next_temp_id += 1;
    return id;
}

pub fn resetTempId() void {
    next_temp_id = 1;
}

/// Per-frame drawing context provided to `Gui.draw()`.
/// Widgets are allocated into the frame arena. After draw()
/// returns, the Window runs layout and (in the future) rendering.
pub const DrawCtx = struct {
    /// Frame arena allocator — reset every frame.
    allocator: std.mem.Allocator,

    /// The available area for the root widget.
    surface_size: Size,

    // ── Parent ID stack ───────────────────────────────
    // Used by the final API (@src() constructors) for
    // deterministic hierarchical ID generation.
    // Begin at root: top-level widgets get parent = Id.root.
    parent_stack: [64]Id = .{Id.root} ** 64,
    parent_depth: u32 = 0,

    /// Current parent ID from the top of the parent stack.
    pub fn parentId(self: *@This()) Id {
        return self.parent_stack[self.parent_depth];
    }

    /// Push a new parent onto the stack (called by begin containers).
    pub fn pushParent(self: *@This(), id: Id) void {
        std.debug.assert(self.parent_depth < self.parent_stack.len - 1);
        self.parent_depth += 1;
        self.parent_stack[self.parent_depth] = id;
    }

    /// Pop back to the previous parent (called by end containers).
    pub fn popParent(self: *@This()) void {
        std.debug.assert(self.parent_depth > 0);
        self.parent_depth -= 1;
    }

    // ─── Event query helpers ─────────────────────────
    // Call these during draw() after layout has run, or next frame.

    /// Get the persistent WidgetState for a given widget ID.
    /// Returns null if the widget has never been registered.
    pub fn widgetState(_: *@This(), ctx: *Context, id: Id) ?*WidgetState {
        return ctx.state_map.getPtr(id) orelse null;
    }

    /// True if the widget was clicked this frame (down→up on same widget).
    pub fn wasClicked(_: *@This(), state: *WidgetState) bool {
        return event.wasClicked(state);
    }

    /// True if the widget is hovered (mouse over).
    pub fn isHot(_: *@This(), state: *const WidgetState) bool {
        return event.isHot(state);
    }

    /// True if the widget is currently pressed.
    pub fn isActive(_: *@This(), state: *const WidgetState) bool {
        return event.isActive(state);
    }

    /// True if the widget has keyboard focus.
    pub fn isFocused(_: *@This(), state: *const WidgetState) bool {
        return event.isFocused(state);
    }

    /// Read and clear the last key pressed on a focused widget.
    pub fn keyPressed(_: *@This(), state: *WidgetState) ?@import("widget.zig").Key {
        const k = state.key_pressed;
        state.key_pressed = null;
        return k;
    }

    /// Read and clear the last text codepoint input on a focused widget.
    pub fn textInput(_: *@This(), state: *WidgetState) ?u21 {
        const cp = state.text_codepoint;
        state.text_codepoint = null;
        return cp;
    }

    // ─────────────────────────────────────────────────────
    // FINAL API — deterministic IDs via @src()
    // ─────────────────────────────────────────────────────

    // ── Leaf widgets ─────────────────────────────────

    /// Options shared by all final-API widget constructors.
    pub const WidgetOpts = struct {
        sizing: Sizing = .{ .x = .fit, .y = .fit },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
        /// Extra discriminator for dynamic lists (loop index).
        /// Pass 0 (or omit) for widgets outside loops.
        id_extra: usize = 0,
    };

    pub fn label(self: *@This(), src: std.builtin.SourceLocation, text: []const u8, opts: WidgetOpts) !*Widget {
        const id = Id.widgetId(src, self.parentId(), opts.id_extra);
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = id,
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .label = .{ .text = text } },
        };
        return w;
    }

    pub fn button(self: *@This(), src: std.builtin.SourceLocation, btn_label: []const u8, opts: WidgetOpts) !*Widget {
        const id = Id.widgetId(src, self.parentId(), opts.id_extra);
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = id,
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .button = .{ .label = btn_label } },
        };
        return w;
    }

    pub fn slider(self: *@This(), src: std.builtin.SourceLocation, slider_label: []const u8, value: *f32, min: f32, max: f32, opts: WidgetOpts) !*Widget {
        const id = Id.widgetId(src, self.parentId(), opts.id_extra);
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = id,
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

    // ── Containers (begin/end pattern) ───────────────

    pub const ContainerOpts = struct {
        padding: f32 = 0,
        gap: f32 = 4,
        sizing: Sizing = .{ .x = .grow, .y = .grow },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
        id_extra: usize = 0,
    };

    /// Begin a column container.  The column's ID is pushed as the
    /// current parent so all widgets created before `endColumn()`
    /// inherit it as their parent ID for deterministic scoping.
    ///
    /// Returns the column widget with no children yet.
    /// Call `endColumn()` to finalise (pops parent, does nothing else).
    pub fn beginColumn(self: *@This(), src: std.builtin.SourceLocation, opts: ContainerOpts) !*Widget {
        const id = Id.widgetId(src, self.parentId(), opts.id_extra);
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = id,
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .column = .{
                .children = &.{}, // populated by caller
                .padding = opts.padding,
                .gap = opts.gap,
            } },
        };
        self.pushParent(id);
        return w;
    }

    /// Finalise a column begun with `beginColumn()`.
    /// Pops the parent stack.  (Children are set externally by the caller
    /// before `endColumn()` via `w.kind.column.children = ...`.)
    pub fn endColumn(self: *@This()) void {
        self.popParent();
    }

    /// Begin a row container.  Pushes the row's ID as current parent.
    pub fn beginRow(self: *@This(), src: std.builtin.SourceLocation, opts: ContainerOpts) !*Widget {
        const id = Id.widgetId(src, self.parentId(), opts.id_extra);
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = id,
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .row = .{
                .children = &.{},
                .padding = opts.padding,
                .gap = opts.gap,
            } },
        };
        self.pushParent(id);
        return w;
    }

    /// Finalise a row begun with `beginRow()`.
    pub fn endRow(self: *@This()) void {
        self.popParent();
    }

    // ─────────────────────────────────────────────────────
    // PROTOTYPE API — temporary sequential IDs (backward compat)
    // ─────────────────────────────────────────────────────

    pub fn tempLabel(self: *@This(), text: []const u8, opts: struct {
        sizing: Sizing = .{ .x = .fit, .y = .fit },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
    }) !*Widget {
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = @enumFromInt(tempId()),
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .label = .{ .text = text } },
        };
        return w;
    }

    pub fn tempButton(self: *@This(), btn_label: []const u8, opts: struct {
        sizing: Sizing = .{ .x = .fit, .y = .fit },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
    }) !*Widget {
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = @enumFromInt(tempId()),
            .sizing = opts.sizing,
            .color = opts.color,
            .corner_radius = opts.corner_radius,
            .border = opts.border,
            .border_color = opts.border_color,
            .kind = .{ .button = .{ .label = btn_label } },
        };
        return w;
    }

    pub fn tempSlider(self: *@This(), slider_label: []const u8, value: *f32, min: f32, max: f32, opts: struct {
        sizing: Sizing = .{ .x = .grow, .y = .fit },
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 1 },
    }) !*Widget {
        const w = try self.allocator.create(Widget);
        w.* = .{
            .id = @enumFromInt(tempId()),
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

    pub fn tempColumn(self: *@This(), children: []const *Widget, opts: struct {
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
            .id = @enumFromInt(tempId()),
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

    pub fn tempRow(self: *@This(), children: []const *Widget, opts: struct {
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
            .id = @enumFromInt(tempId()),
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
