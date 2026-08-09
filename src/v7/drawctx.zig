//! DrawCtx — the per-frame UI surface.
//!
//! DrawCtx owns the cursor into a `WidgetTree` and the `component_id` that
//! binds event handlers to their owning component. State lives in
//! components; the UI is rebuilt every frame: a fresh tree + DrawCtx, a
//! draw pass, then flex.layout().
//!
//! Node order in the flat array is **post-order**: a container node is
//! appended after all of its descendants. flex.layout() is a single
//! bottom-up pass over the array and sizes children before their parent, so
//! this order is load-bearing. DrawCtx keeps it by appending children as
//! they are created and, on `pop()`, moving the just-closed container to the
//! end of the array — everything after it is one of its descendants, by the
//! cursor invariant.
//!
//! Per-frame storage: every node is allocated from `arena` (the frame
//! arena). The tree must be re-created per frame — never reuse a
//! `WidgetTree` across an arena reset: `reset(.retain_capacity)` frees any
//! ArrayList buffer that grew past its first arena chunk (Zig 0.16
//! footgun), which would leave a reused tree pointing at freed memory.
//!
//! Per the prototype spec (notes/v7-prototype-spec.md §4).
const std = @import("std");

const Id = @import("id.zig").Id;
const Box = @import("widget.zig").Box;
const Sides = @import("widget.zig").Sides;
const BoxSizing = @import("widget.zig").BoxSizing;
const Justify = @import("flex.zig").Justify;
const Align = @import("flex.zig").Align;
const StateKey = @import("state.zig").Key;
const stateHash = @import("state.zig").hashName;
const StateDir = @import("state.zig").StateDir;
/// The App's persistent component registry (see DrawCtx.registry).
pub const ComponentRegistry = struct {
    map: *std.AutoHashMapUnmanaged(Id, Component),
    gpa: std.mem.Allocator,
};
const WidgetKind = @import("widget.zig").WidgetKind;
const WidgetTree = @import("widget.zig").WidgetTree;
const callback = @import("callback.zig");
const Component = @import("component.zig").Component;

/// Assemble a CSS `Box` from a DrawCtx opts struct. Each box field is read
/// only when present in the opts; absent fields keep the `Box` defaults.
/// `opts` is `anytype` so widgets can pass exactly the fields they carry.
/// `anytype` opts freeze struct literals into distinct anonymous types,
/// and anonymous struct VALUES never coerce (only literals do) — copy the
/// fields explicitly instead of casting.
/// Read optional `justify` / `align` from container opts into the node's
/// FlexStyle (enum literals coerce via @as).
fn applyFlexStyle(self: *DrawCtx, id: Id, opts: anytype) void {
    const T = @TypeOf(opts);
    if (@hasField(T, "justify")) self.tree.node(id).?.style.justify = @as(Justify, opts.justify);
    if (@hasField(T, "align")) self.tree.node(id).?.style.@"align" = @as(Align, opts.@"align");
}

fn asSides(x: anytype) Sides {
    const T = @TypeOf(x);
    // Partial Sides literals are allowed: absent sides stay 0.
    return .{
        .top = if (@hasField(T, "top")) x.top else 0,
        .right = if (@hasField(T, "right")) x.right else 0,
        .bottom = if (@hasField(T, "bottom")) x.bottom else 0,
        .left = if (@hasField(T, "left")) x.left else 0,
    };
}

fn asColor(x: anytype) [4]f32 {
    return .{ x[0], x[1], x[2], x[3] };
}

fn boxFromOpts(opts: anytype) Box {
    var box = Box{};
    const T = @TypeOf(opts);
    if (@hasField(T, "margin")) box.margin = asSides(opts.margin);
    if (@hasField(T, "padding")) box.padding = asSides(opts.padding);
    if (@hasField(T, "border")) box.border = asSides(opts.border);
    if (@hasField(T, "border_color")) box.border_color = asColor(opts.border_color);
    if (@hasField(T, "radius")) box.radius = asSides(opts.radius);
    if (@hasField(T, "box_sizing")) box.box_sizing = @as(BoxSizing, opts.box_sizing);
    // Paint-only fields (absent keeps the Box defaults).
    if (@hasField(T, "shadow")) box.shadow = opts.shadow;
    if (@hasField(T, "clip")) box.clip = opts.clip;
    // texture is an optional u32 — copy the optional directly.
    if (@hasField(T, "texture")) box.texture = opts.texture;
    // gradient is a [4]f32 like a color — copy element-wise via indexing.
    if (@hasField(T, "gradient")) box.gradient = asColor(opts.gradient);
    // fill = the flat fill color (the gradient's top vertex color; pair
    // with the same gradient for a flat fill).
    if (@hasField(T, "fill")) box.color = asColor(opts.fill);
    return box;
}

pub const DrawCtx = struct {
    tree: *WidgetTree,
    /// The current frame arena's allocator. Components build per-frame
    /// strings here (std.fmt.allocPrint(ctx.arena, ...)) instead of keeping
    /// scratch buffers: the allocation lives as long as the arena, and the
    /// double-buffered arenas keep the previous frame's text readable.
    arena: std.mem.Allocator,
    /// The App's component registry + its gpa: component() registers nested
    /// components here so their buttons dispatch (dispatchClick looks the
    /// owner up in this map). Null in single-frame tests — components still
    /// draw, their buttons just never dispatch.
    registry: ?ComponentRegistry = null,
    /// Last frame's state directory (pointers into the OTHER arena, still
    /// alive while this frame builds) — the "stored version" for state().
    state_prev: ?*const StateDir = null,
    /// This frame's state directory (arena-allocated by App); state()
    /// appends every live value here. Null = no state (single-frame tests):
    /// state() then returns a plain init copy.
    state_cur: ?*StateDir = null,
    parent_stack: [64]Id = .{.root} ** 64,
    depth: u32 = 0,
    component_id: Id = .root,
    /// Nesting depth of pushClip()/popClip() calls. The clip rects
    /// themselves live in the tree's per-frame list (WidgetTree.
    /// clip_rects); this only balances the stack.
    clip_depth: u32 = 0,

    /// Create a node under the cursor. Container kinds do NOT descend here.
    /// The node's `.box` (CSS box model: margin/border/padding/radius) is
    /// set from the opts at creation; its `.rect` is the RELATIVE border
    /// box, filled later by flex.layout().
    /// Font size from a widget's opts (0 = the host default).
    fn optsFontSize(opts: anytype) f32 {
        if (@hasField(@TypeOf(opts), "font_size")) return opts.font_size;
        return 0;
    }

    fn optsFontId(opts: anytype) u8 {
        if (@hasField(@TypeOf(opts), "font_id")) return opts.font_id;
        return 0;
    }

    pub fn create(self: *DrawCtx, kind: WidgetKind, box: Box, font_size: f32, font_id: u8) !Id {
        const id: Id = @enumFromInt(self.tree.next_id);
        self.tree.next_id += 1;

        const parent = self.parent_stack[self.depth];
        try self.tree.nodes.append(self.arena, .{
            .id = id,
            .kind = kind,
            .parent = parent,
            .box = box,
            .font_size = font_size,
            .font_id = font_id,
        });

        // Wire into the parent's children array via a linear scan (the
        // parent was created earlier, so it is already in the array).
        if (parent != .root) {
            const p = self.tree.node(parent).?;
            if (p.children.len < p.children.items.len) {
                p.children.items[p.children.len] = id;
                p.children.len += 1;
            }
        }
        return id;
    }

    /// Container: create + descend. The cursor becomes the new container.
    /// `gap` comes from `opts.gap` when present, else 0; `justify` and
    /// `align` set the FlexStyle distribution/alignment (start / stretch). The box model
    /// (padding/border/radius/margin) comes from the opts and lands on the
    /// node's `.box` — padding/border define where flex places children.
    pub fn column(self: *DrawCtx, opts: anytype) !Id {
        var gap: f32 = 0;
        if (@hasField(@TypeOf(opts), "gap")) gap = opts.gap;
        const id = try self.create(.{ .column = .{ .gap = gap } }, boxFromOpts(opts), optsFontSize(opts), optsFontId(opts));
        var grow: f32 = 0;
        if (@hasField(@TypeOf(opts), "grow")) grow = opts.grow;
        if (grow > 0) self.tree.node(id).?.flex.grow = grow;
        var basis: f32 = 0;
        if (@hasField(@TypeOf(opts), "basis")) basis = opts.basis;
        if (basis > 0) self.tree.node(id).?.flex.basis = basis;
        applyFlexStyle(self, id, opts);
        self.descend(id);
        return id;
    }

    /// Container: create + descend (row variant). See `column`.
    pub fn row(self: *DrawCtx, opts: anytype) !Id {
        var gap: f32 = 0;
        if (@hasField(@TypeOf(opts), "gap")) gap = opts.gap;
        const id = try self.create(.{ .row = .{ .gap = gap } }, boxFromOpts(opts), optsFontSize(opts), optsFontId(opts));
        var grow: f32 = 0;
        if (@hasField(@TypeOf(opts), "grow")) grow = opts.grow;
        if (grow > 0) self.tree.node(id).?.flex.grow = grow;
        var basis: f32 = 0;
        if (@hasField(@TypeOf(opts), "basis")) basis = opts.basis;
        if (basis > 0) self.tree.node(id).?.flex.basis = basis;
        applyFlexStyle(self, id, opts);
        self.descend(id);
        return id;
    }

    /// Leave the current container, restoring the cursor to the enclosing
    /// parent. Also restores the post-order invariant: the container was
    /// appended before its children, so move it past them, to the end.
    pub fn pop(self: *DrawCtx) void {
        std.debug.assert(self.depth > 0);
        const id = self.parent_stack[self.depth];
        self.depth -= 1;

        // Everything after the container in the array is one of its
        // descendants (nodes are only created while the cursor is inside
        // it), so moving it to the end puts children before their container.
        var idx: usize = 0;
        var found = false;
        for (self.tree.nodes.items, 0..) |*n, i| {
            if (n.id == id) {
                idx = i;
                found = true;
                break;
            }
        }
        std.debug.assert(found); // created by column()/row()
        const node = self.tree.nodes.orderedRemove(idx);
        self.tree.nodes.appendAssumeCapacity(node); // no growth: len just shrank
    }

    /// A static text leaf. The text is DUPLICATED into the frame arena:
    /// components may hand over scratch buffers that get rewritten next
    /// frame (e.g. bufPrint results) — the tree must own a stable copy so
    /// the double-buffered previous frame keeps its original text for
    /// id-keyed dirty diffing.
    pub fn label(self: *DrawCtx, opts: anytype) !Id {
        const text = try self.arena.dupe(u8, opts.text);
        var kind: WidgetKind = .{ .label = .{ .text = text } };
        if (@hasField(@TypeOf(opts), "color")) kind.label.color = asColor(opts.color);
        return self.create(kind, boxFromOpts(opts), optsFontSize(opts), optsFontId(opts));
    }

    /// A clickable button. `owner` binds the click to the component that
    /// created it (`component_id`); `on_click` is wrapped into a type-erased
    /// callback when `opts.on_click` is present. Label text is duplicated
    /// into the frame arena (see label()).
    ///
    /// The label is a CHILD label node, centered by the button's flex style
    /// — the text pipeline (measure + emission + color) is shared with
    /// plain labels, one path instead of a second kind arm in the
    /// renderer. The kind's `label` field still carries the text (the
    /// click-injection + hit-testing scan it).
    pub fn button(self: *DrawCtx, opts: anytype) !Id {
        var on_click: ?*const fn (*anyopaque) void = null;
        if (@hasField(@TypeOf(opts), "on_click")) on_click = callback.wrap(opts.on_click);
        const label_copy = try self.arena.dupe(u8, opts.label);
        var kind: WidgetKind = .{ .button = .{
            .label = label_copy,
            .on_click = on_click,
            .owner = self.component_id,
        } };
        if (@hasField(@TypeOf(opts), "color")) kind.button.color = asColor(opts.color);
        const font_size = optsFontSize(opts);
        const font_id = optsFontId(opts);
        const id = try self.create(kind, boxFromOpts(opts), font_size, font_id);
        const node = self.tree.node(id).?;
        node.style.justify = .center;
        node.style.@"align" = .center;
        self.descend(id);
        _ = try self.label(.{
            .text = label_copy,
            .color = kind.button.color,
            .font_size = font_size,
            .font_id = font_id,
        });
        self.pop();
        return id;
    }

    /// A slider bound to a live f32. Label text is duplicated into the
    /// frame arena (see label()).
    pub fn slider(self: *DrawCtx, opts: anytype) !Id {
        const label_copy = try self.arena.dupe(u8, opts.label);
        var kind: WidgetKind = .{ .slider = .{
            .label = label_copy,
            .value = opts.value,
            .min = opts.min,
            .max = opts.max,
        } };
        if (@hasField(@TypeOf(opts), "color")) kind.slider.color = asColor(opts.color);
        return self.create(kind, boxFromOpts(opts), optsFontSize(opts), optsFontId(opts));
    }

    /// An empty spacer of the given size (`opts.size`, default 0). Box
    /// fields are allowed but inert: the size still rules the node.
    pub fn spacer(self: *DrawCtx, opts: anytype) !Id {
        var size: f32 = 0;
        if (@hasField(@TypeOf(opts), "size")) size = opts.size;
        return self.create(.{ .spacer = .{ .size = size } }, boxFromOpts(opts), optsFontSize(opts), optsFontId(opts));
    }

    /// Push a clip rect onto the frame's clip-rect list, returning its
    /// clip id (or 0xFFFFFFFF when the list is full — the clip is then
    /// skipped). The id stamps onto the clip-marked container's draw
    /// commands: the `.clip` box option wires this automatically (the
    /// declarative path the demo uses); pushClip is the programmatic API
    /// for widgets that know their rect at draw time (scroll containers).
    /// popClip() balances the push. The list is append-only — ids stay
    /// valid for the frame.
    pub fn pushClip(self: *DrawCtx, x: f32, y: f32, w: f32, h: f32) u32 {
        const id = self.tree.pushClipRect(.{ .x = x, .y = y, .w = w, .h = h }) orelse return 0xFFFFFFFF;
        self.clip_depth += 1;
        return id;
    }

    /// Balance a pushClip(): restores the clip nesting depth. Rects are
    /// never removed from the list (ids must stay stable), so pop only
    /// tracks the stack.
    pub fn popClip(self: *DrawCtx) void {
        std.debug.assert(self.clip_depth > 0);
        self.clip_depth -= 1;
    }

    /// Nest a sub-component: its draw() runs with `component_id` set to a
    /// fresh id reserved from the tree's id space, so its buttons bind to
    /// it; the parent's `component_id` is restored afterwards. The child
    /// draws into the current cursor like any widget. The child is also
    /// REGISTERED in the App's component map (gpa-backed, persistent) —
    /// without that, dispatchClick cannot resolve its owner and its buttons
    /// would silently do nothing.
    pub fn component(self: *DrawCtx, comptime T: type, ptr: *T) !void {
        const saved = self.component_id;
        defer self.component_id = saved;
        self.component_id = @enumFromInt(self.tree.next_id);
        self.tree.next_id += 1;
        if (self.registry) |reg| {
            try reg.map.put(reg.gpa, self.component_id, Component.make(T, ptr));
        }
        try Component.make(T, ptr).vtable.draw(ptr, self);
    }

    /// useState-like inter-frame transient state, node-local: `name` is
    /// scoped to the node about to be created (the current id), so two
    /// nodes may use the same name without colliding. Returns a pointer to
    /// a FRESH T in the frame arena, valid until the arena resets:
    ///   - the node was live last frame -> seeded from its previous value;
    ///   - otherwise -> `init` (new node, or unmounted since — hidden
    ///     nodes drop their state automatically, no pruning needed);
    ///   - called twice for the same node+name in one frame -> the SAME
    ///     copy (the first call's mutations survive).
    /// The returned T lives in the frame arena: no gpa allocations, no
    /// flush — the double-buffered arenas ARE the store. A frame-arena OOM
    /// propagates as error.OutOfMemory.
    pub fn state(self: *DrawCtx, name: []const u8, comptime T: type, init: T) !*T {
        const key = StateKey{ .node = @enumFromInt(self.tree.next_id), .name_hash = stateHash(name) };
        const cur = self.state_cur orelse {
            // No state mode (single-frame tests): a plain init copy.
            const p = try self.arena.create(T);
            p.* = init;
            return p;
        };
        for (cur.items) |sr| {
            // Provenance: every ptr was arena.create(T) (properly aligned)
            // before being stored as *anyopaque — the alignCast can never
            // fail; zbc flags it because it cannot track the provenance
            // through the type erasure.
            if (sr.key.eql(key)) return @ptrCast(@alignCast(sr.ptr));
        }
        const p = try self.arena.create(T);
        var seeded = false;
        if (self.state_prev) |prev| {
            for (prev.items) |sr| {
                if (sr.key.eql(key)) {
                    @memcpy(
                        @as([*]u8, @ptrCast(p))[0..@sizeOf(T)],
                        @as([*]const u8, @ptrCast(sr.ptr))[0..@sizeOf(T)],
                    );
                    seeded = true;
                    break;
                }
            }
        }
        if (!seeded) p.* = init;
        try cur.append(self.arena, .{ .key = key, .ptr = p });
        return p;
    }

    /// Cursor descends into a container: it becomes the parent for nodes
    /// created until the matching `pop()`.
    fn descend(self: *DrawCtx, id: Id) void {
        self.depth += 1;
        self.parent_stack[self.depth] = id;
    }
};

test "DrawCtx: two-level cursor nesting wires parents and children" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    const col = try ctx.column(.{});
    const inner_label = try ctx.label(.{ .text = "a" });
    const inner_button = try ctx.button(.{ .label = "B" });
    ctx.pop();
    const outer_label = try ctx.label(.{ .text = "b" });

    // Parents: the column's children point at it; the label after pop() is
    // back at the root.
    try std.testing.expectEqual(col, tree.node(inner_label).?.parent);
    try std.testing.expectEqual(col, tree.node(inner_button).?.parent);
    try std.testing.expectEqual(Id.root, tree.node(outer_label).?.parent);

    // Children adjacency, in creation order. The button's label is the
    // BUTTON's child, not the column's.
    const col_node = tree.node(col).?;
    try std.testing.expectEqual(@as(u8, 2), col_node.children.len);
    try std.testing.expectEqual(inner_label, col_node.children.items[0]);
    try std.testing.expectEqual(inner_button, col_node.children.items[1]);

    // The button's child is its label (a label node with the button's text).
    const btn_node = tree.node(inner_button).?;
    try std.testing.expectEqual(@as(u8, 1), btn_node.children.len);
    const btn_label_id = btn_node.children.items[0];
    const btn_label = tree.node(btn_label_id).?;
    try std.testing.expectEqual(inner_button, btn_label.parent);
    try std.testing.expectEqualStrings("B", btn_label.kind.label.text);

    // Post-order: children first, then their container, then the root label.
    // The button's pop moved it past its child label, so the child precedes
    // it.
    try std.testing.expectEqual(inner_label, tree.nodes.items[0].id);
    try std.testing.expectEqual(btn_label_id, tree.nodes.items[1].id);
    try std.testing.expectEqual(inner_button, tree.nodes.items[2].id);
    try std.testing.expectEqual(col, tree.nodes.items[3].id);
    try std.testing.expectEqual(outer_label, tree.nodes.items[4].id);
}

test "DrawCtx: pop() restores the cursor" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    const col = try ctx.column(.{});
    const inner = try ctx.label(.{ .text = "inner" });
    ctx.pop();

    // New nodes after pop() land under .root, not under the column.
    const after = try ctx.label(.{ .text = "outer" });
    try std.testing.expectEqual(Id.root, tree.node(after).?.parent);

    // The column's children are unaffected by pop().
    const col_node = tree.node(col).?;
    try std.testing.expectEqual(@as(u8, 1), col_node.children.len);
    try std.testing.expectEqual(inner, col_node.children.items[0]);
}

test "DrawCtx: button owner binds to component_id, incl. inside component()" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    // At the root the owner is .root (the implicit root component).
    const root_button = try ctx.button(.{ .label = "root" });
    try std.testing.expectEqual(Id.root, tree.node(root_button).?.kind.button.owner);

    const Child = struct {
        pub fn draw(self: *@This(), c: *DrawCtx) anyerror!void {
            _ = self;
            _ = try c.button(.{ .label = "child" });
        }
    };
    var child = Child{};
    try ctx.component(Child, &child);

    // The component took the next id (3 — 2 was the root button's child
    // label); the inner button (id 4) is owned by the child component,
    // and component_id was restored afterwards.
    const inner: Id = @enumFromInt(4);
    try std.testing.expectEqual(@as(Id, @enumFromInt(3)), tree.node(inner).?.kind.button.owner);
    try std.testing.expectEqual(Id.root, ctx.component_id);

    // A later button is owned by the root component again.
    const later = try ctx.button(.{ .label = "later" });
    try std.testing.expectEqual(Id.root, tree.node(later).?.kind.button.owner);
}

test "DrawCtx: component() draws into the current cursor" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    const Child = struct {
        pub fn draw(self: *@This(), c: *DrawCtx) anyerror!void {
            _ = self;
            _ = try c.label(.{ .text = "in-child" });
        }
    };
    var child = Child{};

    // Drawn at root level: the child's node is root-level.
    // component() reserves id 1 for the child component, so its label is 2.
    try ctx.component(Child, &child);
    const root_label: Id = @enumFromInt(2);
    try std.testing.expectEqual(Id.root, tree.node(root_label).?.parent);

    // Drawn inside a column: the child's node lands under the column.
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    var tree2 = WidgetTree.init(arena2.allocator());
    defer tree2.nodes.deinit(arena2.allocator());
    var ctx2 = DrawCtx{ .tree = &tree2, .arena = arena2.allocator() };

    const col = try ctx2.column(.{});
    try ctx2.component(Child, &child);
    ctx2.pop();

    // ids: column = 1, component = 2, child label = 3.
    const nested: Id = @enumFromInt(3);
    try std.testing.expectEqual(col, tree2.node(nested).?.parent);
    const col_node = tree2.node(col).?;
    try std.testing.expectEqual(@as(u8, 1), col_node.children.len);
    try std.testing.expectEqual(nested, col_node.children.items[0]);
}

test "DrawCtx: justify and align flow into the node's FlexStyle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    const jcol = try ctx.column(.{ .justify = .space_between });
    ctx.pop();
    const acol = try ctx.column(.{ .@"align" = .center });
    ctx.pop();
    const plain = try ctx.column(.{});
    ctx.pop();

    try std.testing.expectEqual(Justify.space_between, tree.node(jcol).?.style.justify);
    try std.testing.expectEqual(Align.center, tree.node(acol).?.style.@"align");
    // Defaults stay when the opts omit the fields.
    try std.testing.expectEqual(Justify.start, tree.node(plain).?.style.justify);
    try std.testing.expectEqual(Align.stretch, tree.node(plain).?.style.@"align");
}

test "DrawCtx: container gap comes from opts, defaults to 0" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    const gapped_col = try ctx.column(.{ .gap = 4 });
    ctx.pop();
    const plain_col = try ctx.column(.{});
    ctx.pop();
    const gapped_row = try ctx.row(.{ .gap = 7 });
    ctx.pop();
    const plain_row = try ctx.row(.{});
    ctx.pop();

    try std.testing.expectEqual(@as(f32, 4), tree.node(gapped_col).?.kind.column.gap);
    try std.testing.expectEqual(@as(f32, 0), tree.node(plain_col).?.kind.column.gap);
    try std.testing.expectEqual(@as(f32, 7), tree.node(gapped_row).?.kind.row.gap);
    try std.testing.expectEqual(@as(f32, 0), tree.node(plain_row).?.kind.row.gap);
}

test "DrawCtx: button on_click is wrapped via callback.wrap when provided" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    // No on_click in opts -> null callback.
    const plain = try ctx.button(.{ .label = "no handler" });
    try std.testing.expectEqual(@as(?*const fn (*anyopaque) void, null), tree.node(plain).?.kind.button.on_click);

    // With on_click -> a type-erased callback that reaches the receiver.
    const Counter = struct {
        n: u32 = 0,

        fn click(self: *@This()) void {
            self.n += 1;
        }
    };
    var counter = Counter{};
    const wired = try ctx.button(.{ .label = "go", .on_click = Counter.click });
    const cb = tree.node(wired).?.kind.button.on_click.?;
    cb(@ptrCast(&counter));
    try std.testing.expectEqual(@as(u32, 1), counter.n);
}

test "DrawCtx: box fields from opts flow into the node's box" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    const id = try ctx.label(.{
        .text = "boxed",
        .margin = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
        .padding = .{ .top = 5, .right = 6, .bottom = 7, .left = 8 },
        .border = .{ .top = 9, .right = 10, .bottom = 11, .left = 12 },
        .border_color = .{ 0.1, 0.2, 0.3, 0.4 },
        .radius = .{ .top = 13, .right = 14, .bottom = 15, .left = 16 },
        .box_sizing = .border_box,
    });

    try std.testing.expectEqual(Box{
        .margin = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
        .padding = .{ .top = 5, .right = 6, .bottom = 7, .left = 8 },
        .border = .{ .top = 9, .right = 10, .bottom = 11, .left = 12 },
        .border_color = .{ 0.1, 0.2, 0.3, 0.4 },
        .radius = .{ .top = 13, .right = 14, .bottom = 15, .left = 16 },
        .box_sizing = .border_box,
    }, tree.node(id).?.box);

    // The same opts flow into container boxes too (column and row).
    const col = try ctx.column(.{ .padding = .{ .top = 8, .left = 8 } });
    ctx.pop();
    const row = try ctx.row(.{ .border = .{ .top = 2 } });
    ctx.pop();
    try std.testing.expectEqual(Box{ .padding = .{ .top = 8, .left = 8 } }, tree.node(col).?.box);
    try std.testing.expectEqual(Box{ .border = .{ .top = 2 } }, tree.node(row).?.box);
}

test "DrawCtx: absent box fields leave Box defaults" {
    // DrawCtx text is arena-owned (duplicated label strings), so tests use
    // a real arena — the testing allocator would leak every duplicate.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    const plain_label = try ctx.label(.{ .text = "plain" });
    const plain_button = try ctx.button(.{ .label = "B" });
    var slider_value: f32 = 0.5;
    const plain_slider = try ctx.slider(.{ .label = "S", .value = &slider_value, .min = 0, .max = 1 });
    const plain_spacer = try ctx.spacer(.{});
    const plain_col = try ctx.column(.{ .gap = 4 });
    ctx.pop();

    // No box fields in the opts -> the node carries Box{} exactly.
    try std.testing.expectEqual(Box{}, tree.node(plain_label).?.box);
    try std.testing.expectEqual(Box{}, tree.node(plain_button).?.box);
    try std.testing.expectEqual(Box{}, tree.node(plain_slider).?.box);
    try std.testing.expectEqual(Box{}, tree.node(plain_spacer).?.box);
    try std.testing.expectEqual(Box{}, tree.node(plain_col).?.box);
}

test "DrawCtx: the .clip opt lands on the container box; pushClip appends to the tree's clip list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx = DrawCtx{ .tree = &tree, .arena = arena.allocator() };

    const card = try ctx.column(.{ .clip = true });
    ctx.pop();
    try std.testing.expect(tree.node(card).?.box.clip);

    // Programmatic clips append to the SAME list the declarative path
    // uses (collectDrawCmds reads it); ids are stable indices.
    const id0 = ctx.pushClip(10, 20, 30, 40);
    const id1 = ctx.pushClip(50, 60, 70, 80);
    ctx.popClip();
    ctx.popClip();
    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), tree.clip_count);
    try std.testing.expectEqual(@as(f32, 30), tree.clip_rects[0].w);
    try std.testing.expectEqual(@as(f32, 80), tree.clip_rects[1].h);
}
