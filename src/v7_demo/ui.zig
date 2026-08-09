//! v7 demo UI — one interactive TodoApp component with several parts.
//!
//! Demo-side code: imports std plus the pure v7 module via relative paths.
//! All state lives in struct fields; every frame re-draws everything (no
//! dirty tracking). The App loop (or a test) sets `frame_count` before each
//! draw. Buttons carry distinct labels so click injection can target them
//! by scanning the tree — scan by kind, never by position (node order is
//! post-order, ids are not array indices).
//!
//! Import note: Zig 0.16 roots a single-file `zig test <file>` module at
//! the file's directory and rejects imports outside it, so `../v7/...`
//! cannot be imported from here. `src/v7_demo/v7` is therefore a symlink
//! to `../v7`, keeping this file standalone-compilable and testable with
//! `zig test src/v7_demo/ui.zig`.

const std = @import("std");

const DrawCtx = @import("v7/drawctx.zig").DrawCtx;
const srgbToOklab = @import("text.zig").srgbToOklab;
const text_mod = @import("text.zig");
const WidgetTree = @import("v7/widget.zig").WidgetTree;
const App = @import("v7/app.zig").App;
const Id = @import("v7/id.zig").Id;

/// Label with the demo's baked 6px side padding, now carried by the widget
/// box instead of hard-coded text offsets.
fn label(ctx: *DrawCtx, text: []const u8) !Id {
    return ctx.label(.{ .text = text, .padding = .{ .left = 6, .right = 6 } });
}

/// Demo button: rounded corners + the standard padding (the old baked
/// +16/+8), so every button exercises radius + padding + the ring-free
/// fill path.
fn btn(ctx: *DrawCtx, text: []const u8, on_click: anytype) !Id {
    return ctx.button(.{
        .label = text,
        .on_click = on_click,
        .padding = .{ .left = 6, .right = 10, .top = 4, .bottom = 4 },
        .radius = .{ .top = 6, .right = 6, .bottom = 6, .left = 6 },
        // Gradient bottom: a lighter steel blue in sRGB, converted to Oklab
        // (the pipeline's color space) like every other color.
        .gradient = srgbToOklab(.{ 0.44, 0.56, 0.76, 1 }),
    });
}

/// Inline sub-component for the volume block: slider + mute button + value
/// label. Nested into the TodoApp tree via ctx.component, so its buttons
/// bind to their own component id.
const VolumeSlider = struct {
    volume: f32 = 0.5,

    pub fn draw(self: *VolumeSlider, ctx: *DrawCtx) !void {
        const text = try std.fmt.allocPrint(ctx.arena, "Volume: {d:.1}", .{self.volume});
        _ = try ctx.column(.{ .gap = 6, .border = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 }, .border_color = .{ 0.42, 0.42, 0.48, 1 }, .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 }, .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 }, .shadow = 3 });
        defer ctx.pop();
        _ = try ctx.slider(.{ .label = "volume-slider", .value = &self.volume, .min = 0, .max = 1, .padding = .{ .left = 6, .right = 10 } });
        _ = try btn(ctx, "mute", VolumeSlider.mute);
        _ = try label(ctx, text);
    }

    pub fn mute(self: *VolumeSlider) void {
        self.volume = 0;
    }
};

/// Second slider component: exercises a NON-ZERO [min, max] range and a
/// per-component reset handler (its own component id).
const GainSlider = struct {
    gain: f32 = 0.5,

    pub fn draw(self: *GainSlider, ctx: *DrawCtx) !void {
        const text = try std.fmt.allocPrint(ctx.arena, "Gain: {d:.1}", .{self.gain});
        _ = try ctx.column(.{ .gap = 6, .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 }, .border_color = .{ 0.35, 0.45, 0.55, 1 }, .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 }, .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 }, .shadow = 3 });
        defer ctx.pop();
        _ = try ctx.slider(.{ .label = "gain-slider", .value = &self.gain, .min = 0, .max = 10, .padding = .{ .left = 6, .right = 10 } });
        _ = try btn(ctx, "reset-gain", GainSlider.reset);
        _ = try label(ctx, text);
    }

    pub fn reset(self: *GainSlider) void {
        self.gain = 0;
    }
};

/// Box-model showcase: a row exercising justify (space_between), align
/// (center), margins, padding-only boxes, and a rounded border ring on a
/// plain label.
const Showcase = struct {
    pub fn draw(self: *Showcase, ctx: *DrawCtx) !void {
        _ = self;
        // Root-level row: spans the window, so it needs its OWN side
        // padding (the root column's padding does not apply here) and
        // justify has main-axis free space to spread the children.
        _ = try ctx.row(.{ .gap = 10, .justify = .space_between, .@"align" = .center, .padding = .{ .left = 12, .right = 12 } });
        defer ctx.pop();
        // All three boxes share the same vertical padding (44px tall), so
        // the text baselines line up despite the box-model differences.
        // Padding-only: the text sits 10px inside the invisible box.
        _ = try ctx.label(.{ .text = "pad", .padding = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 } });
        // Ring: 2px rounded border around the text (no fill); border 2 +
        // padding 8 = the same 10px content inset as "pad".
        _ = try ctx.label(.{ .text = "ring", .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 }, .border = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 }, .border_color = .{ 0.8, 0.5, 0.3, 1 }, .radius = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 } });
        // Margin: pushed 10px right of its spread slot (horizontal only —
        // a vertical offset reads as misalignment).
        _ = try ctx.label(.{ .text = "margin", .margin = .{ .left = 10 }, .padding = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 } });
    }
};

/// The demo root component: title row, counter block, volume block, todo
/// list block and a done-count footer, stacked in a root column (gap 12,
/// blocks use gap 6).
pub const TodoApp = struct {
    // --- state (set/mutated by the demo loop and the interaction methods) ---
    frame_count: u32 = 0, // the App loop sets this before each frame
    counter: u32 = 0, // 0..99
    volume: VolumeSlider = .{},
    gain_slider: GainSlider = .{},
    showcase: Showcase = .{},
    done: [4]bool = .{ false, false, false, false },
    visible_count: u8 = 2, // how many of the 4 pool items are shown (1..4)

    /// The fixed pool of candidate todo items.
    pub const ITEMS = [4][]const u8{ "buy milk", "water plants", "write docs", "exercise" };

    pub fn draw(self: *TodoApp, ctx: *DrawCtx) !void {
        const frame_text = try std.fmt.allocPrint(ctx.arena, "Frame: {d}", .{self.frame_count});
        const counter_text = try std.fmt.allocPrint(ctx.arena, "Counter: {d}", .{self.counter});

        var done_count: u32 = 0;
        for (0..self.visible_count) |i| {
            if (self.done[i]) done_count += 1;
        }
        const footer_text = try std.fmt.allocPrint(ctx.arena, "{d} of {d} done", .{ done_count, self.visible_count });

        // Box-model showcase FIRST, at ROOT level: a root-level row spans
        // the full window width, so justify = space_between has main-axis
        // free space to distribute (a nested row would hug its content).
        try ctx.component(Showcase, &self.showcase);

        // Root column: every block stacked with a 12px gap; the root's own
        // padding insets the whole UI from the window edges.
        _ = try ctx.column(.{ .gap = 12, .grow = 1, .padding = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 } });
        defer ctx.pop();

        {
            // Title + live frame counter + the toggle-state line, stacked.
            _ = try ctx.column(.{ .gap = 6 });
            defer ctx.pop();
            _ = try label(ctx, "nogui v7 demo");
            _ = try label(ctx, frame_text);
            const st = text_mod.debug_state;
            const state_text = try std.fmt.allocPrint(ctx.arena, "subpixel:{s} order:{s} damp:{s} debug:{s}", .{
                if (st.subpixel) "on" else "off",
                if (st.bgr) "BGR" else "RGB",
                if (st.damp) "on" else "off",
                if (st.quad_debug) "on" else "off",
            });
            _ = try label(ctx, state_text);
        }

        {
            // Font-sizes showcase: labels at 10/13/16/20/24/32 px. The
            // per-node font_size selects the matching font state; S toggles
            // the subpixel AA for comparison at every size.
            _ = try ctx.column(.{ .gap = 6, .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 }, .border_color = .{ 0.4, 0.4, 0.46, 1 }, .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 }, .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 } });
            defer ctx.pop();
            _ = try label(ctx, "Font sizes (S toggles subpixel AA):");
            _ = try ctx.label(.{ .text = "10px: The quick brown fox jumps over the lazy dog", .font_size = 10, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "13px: The quick brown fox jumps over the lazy dog", .font_size = 13, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "16px: The quick brown fox jumps over the lazy dog", .font_size = 16, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "20px: The quick brown fox jumps over the lazy dog", .font_size = 20, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "24px: The quick brown fox jumps over the lazy dog", .font_size = 24, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "32px: The quick brown fox jumps over the lazy dog", .font_size = 32, .padding = .{ .left = 6, .right = 6 } });
        }

        {
            // The ghostty font (Fira Code Nerd Font) at the same sizes.
            _ = try ctx.column(.{ .gap = 6, .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 }, .border_color = .{ 0.4, 0.4, 0.46, 1 }, .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 }, .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 } });
            defer ctx.pop();
            _ = try label(ctx, "Fira Code Nerd Font (ghostty):");
            _ = try ctx.label(.{ .text = "10px: The quick brown fox jumps over the lazy dog", .font_size = 10, .font_id = 1, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "13px: The quick brown fox jumps over the lazy dog", .font_size = 13, .font_id = 1, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "16px: The quick brown fox jumps over the lazy dog", .font_size = 16, .font_id = 1, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "20px: The quick brown fox jumps over the lazy dog", .font_size = 20, .font_id = 1, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "24px: The quick brown fox jumps over the lazy dog", .font_size = 24, .font_id = 1, .padding = .{ .left = 6, .right = 6 } });
            _ = try ctx.label(.{ .text = "32px: The quick brown fox jumps over the lazy dog", .font_size = 32, .font_id = 1, .padding = .{ .left = 6, .right = 6 } });
        }

        {
            // Counter block: a bordered card (radius 8, padding 8) holding
            // the value label + dec/reset/inc row.
            _ = try ctx.column(.{ .gap = 6, .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 }, .border_color = .{ 0.4, 0.4, 0.46, 1 }, .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 }, .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 }, .shadow = 3 });
            defer ctx.pop();
            _ = try label(ctx, counter_text);
            {
                _ = try ctx.row(.{ .gap = 6 });
                defer ctx.pop();
                _ = try btn(ctx, "dec", TodoApp.dec);
                _ = try btn(ctx, "reset", TodoApp.reset);
                _ = try btn(ctx, "inc", TodoApp.inc);
            }
        }

        // Volume block: nested sub-component (its own card + slider).
        try ctx.component(VolumeSlider, &self.volume);

        // Spacer: reserves 8px of empty main-axis space (paints nothing).
        _ = try ctx.spacer(.{ .size = 8 });

        // Gain block: nested sub-component with a non-zero slider range.
        try ctx.component(GainSlider, &self.gain_slider);

        {
            // Todo block: bordered card with the add/remove header + one
            // toggle row per visible item.
            _ = try ctx.column(.{ .gap = 6, .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 }, .border_color = .{ 0.38, 0.38, 0.44, 1 }, .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 }, .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 }, .shadow = 3 });
            defer ctx.pop();
            {
                _ = try ctx.row(.{ .gap = 6 });
                defer ctx.pop();
                _ = try btn(ctx, "remove", TodoApp.remove);
                _ = try btn(ctx, "add", TodoApp.add);
            }
            // Unrolled so each toggle button can bind its own comptime
            // handler; the runtime check hides rows beyond visible_count.
            // Toggle button label doubles as the state indicator:
            // "toggle{i}: [ ]" undone, "toggle{i}: [x]" done.
            inline for (0..4) |i| {
                if (i < self.visible_count) {
                    // Per-node transient: how many frames this toggle row
                    // has been drawn. Node-local (each row has its own),
                    // reset to 0 when the row is hidden by "remove" (its
                    // state directory entry dies with the frame).
                    const frames = try ctx.state("toggle-frames", u32, 0);
                    frames.* += 1;
                    const toggle_text = try std.fmt.allocPrint(ctx.arena, "toggle{d}: [{s}] n={d}", .{ i, if (self.done[i]) "x" else " ", frames.* });
                    const item_text = if (self.done[i])
                        (try std.fmt.allocPrint(ctx.arena, "DONE: {s}", .{ITEMS[i]}))
                    else
                        ITEMS[i];
                    _ = try ctx.row(.{ .gap = 6 });
                    defer ctx.pop();
                    _ = try btn(ctx, toggle_text, comptime switch (i) {
                        0 => TodoApp.onToggle0,
                        1 => TodoApp.onToggle1,
                        2 => TodoApp.onToggle2,
                        else => TodoApp.onToggle3,
                    });
                    _ = try label(ctx, item_text);
                }
            }
        }

        // Footer: done count over the visible items.
        _ = try label(ctx, footer_text);
    }

    // --- interactions (click-injection targets; all pub) ---

    pub fn inc(self: *TodoApp) void {
        if (self.counter < 99) self.counter += 1;
    }

    pub fn dec(self: *TodoApp) void {
        if (self.counter > 0) self.counter -= 1;
    }

    pub fn reset(self: *TodoApp) void {
        self.counter = 0;
    }

    pub fn mute(self: *TodoApp) void {
        self.volume.mute();
    }

    pub fn toggle(self: *TodoApp, i: usize) void {
        if (i < self.done.len) self.done[i] = !self.done[i];
    }

    pub fn add(self: *TodoApp) void {
        if (self.visible_count < 4) self.visible_count += 1;
    }

    pub fn remove(self: *TodoApp) void {
        if (self.visible_count > 1) self.visible_count -= 1;
    }

    // Per-index adapters so each toggle button binds a type-erased
    // `fn (*TodoApp) void` handler.
    pub fn onToggle0(self: *TodoApp) void {
        self.toggle(0);
    }
    pub fn onToggle1(self: *TodoApp) void {
        self.toggle(1);
    }
    pub fn onToggle2(self: *TodoApp) void {
        self.toggle(2);
    }
    pub fn onToggle3(self: *TodoApp) void {
        self.toggle(3);
    }
};

// --- tests -----------------------------------------------------------------

/// Fresh WidgetTree + DrawCtx over a per-tree arena, run `app.draw`,
/// return the tree for inspection. DrawCtx duplicates label strings into
/// the arena, so the arena must outlive the tree: call freeTree().
/// (Tests run sequentially; a new buildTree() releases the previous arena,
/// so one test may build several trees.)
var test_arena: ?std.heap.ArenaAllocator = null;

fn buildTree(app: *TodoApp) !WidgetTree {
    if (test_arena) |*a| a.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var tree = WidgetTree.init(alloc); // mutable: DrawCtx takes *WidgetTree
    var ctx = DrawCtx{ .tree = &tree, .arena = alloc };
    try app.draw(&ctx);
    test_arena = arena;
    return tree;
}

fn freeTree() void {
    if (test_arena) |*a| a.deinit();
    test_arena = null;
}

/// Scan by kind (never by position): node order is post-order and ids are
/// not array positions. Passes if a label node with exactly `text` exists.
fn expectLabel(tree: *const WidgetTree, text: []const u8) !void {
    for (tree.nodes.items) |n| {
        switch (n.kind) {
            .label => |l| {
                if (std.mem.eql(u8, l.text, text)) return;
            },
            else => {},
        }
    }
    return error.LabelNotFound;
}

/// Count button nodes whose label starts with `prefix`.
fn countButtonLabelsWithPrefix(tree: *const WidgetTree, prefix: []const u8) usize {
    var count: usize = 0;
    for (tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.startsWith(u8, b.label, prefix)) count += 1;
            },
            else => {},
        }
    }
    return count;
}

test "draw: tree contains the expected button labels and title" {
    var app = TodoApp{ .frame_count = 7 };
    const tree = try buildTree(&app);
    defer freeTree();

    var found_inc = false;
    var found_dec = false;
    var found_reset = false;
    var found_mute = false;
    var found_add = false;
    var found_remove = false;
    for (tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.eql(u8, b.label, "inc")) found_inc = true;
                if (std.mem.eql(u8, b.label, "dec")) found_dec = true;
                if (std.mem.eql(u8, b.label, "reset")) found_reset = true;
                if (std.mem.eql(u8, b.label, "mute")) found_mute = true;
                if (std.mem.eql(u8, b.label, "add")) found_add = true;
                if (std.mem.eql(u8, b.label, "remove")) found_remove = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_inc and found_dec and found_reset and found_mute and found_add and found_remove);

    // Default visible_count of 2 -> exactly two toggle rows, all undone.
    try std.testing.expectEqual(@as(usize, 2), countButtonLabelsWithPrefix(&tree, "toggle"));

    try expectLabel(&tree, "nogui v7 demo");
    try expectLabel(&tree, "Frame: 7");
}

test "toggle(0) marks the item done in the next draw" {
    var app = TodoApp{};
    app.toggle(0);
    const tree = try buildTree(&app);
    defer freeTree();

    // The toggle0 button label now shows "[x]"; toggle1 stays "[ ]".
    var toggle0_shows_done = false;
    var toggle1_shows_undone = false;
    var done_item: ?[]const u8 = null;
    var footer: ?[]const u8 = null;
    for (tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.startsWith(u8, b.label, "toggle0")) {
                    toggle0_shows_done = std.mem.indexOf(u8, b.label, "[x]") != null;
                }
                if (std.mem.startsWith(u8, b.label, "toggle1")) {
                    toggle1_shows_undone = std.mem.indexOf(u8, b.label, "[ ]") != null;
                }
            },
            .label => |l| {
                if (std.mem.startsWith(u8, l.text, "DONE: ")) done_item = l.text;
                if (std.mem.endsWith(u8, l.text, "done") and std.mem.startsWith(u8, l.text, "1 of ")) footer = l.text;
            },
            else => {},
        }
    }
    try std.testing.expect(toggle0_shows_done);
    try std.testing.expect(toggle1_shows_undone);
    try std.testing.expect(done_item != null);
    try std.testing.expectEqualStrings("DONE: buy milk", done_item.?);
    try std.testing.expect(footer != null);
    // 1 of 2 done with the default visible_count of 2.
    try std.testing.expectEqualStrings("1 of 2 done", footer.?);
}

test "counter: inc, dec clamps at 0, reset returns to 0" {
    var app = TodoApp{};
    app.inc();
    const tree = try buildTree(&app);
    defer freeTree();
    try expectLabel(&tree, "Counter: 1");

    app.dec();
    app.dec(); // dec below zero is clamped
    var tree2 = try buildTree(&app);
    try expectLabel(&tree2, "Counter: 0");

    app.counter = 5;
    app.reset();
    var tree3 = try buildTree(&app);
    try expectLabel(&tree3, "Counter: 0");

    // inc above 99 is clamped too.
    app.counter = 99;
    app.inc();
    var tree4 = try buildTree(&app);
    try expectLabel(&tree4, "Counter: 99");
}

test "add grows visible rows, remove shrinks, both clamp" {
    var app = TodoApp{};
    const tree = try buildTree(&app);
    defer freeTree();
    try std.testing.expectEqual(@as(usize, 2), countButtonLabelsWithPrefix(&tree, "toggle"));

    app.add();
    var tree2 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 3), countButtonLabelsWithPrefix(&tree2, "toggle"));

    app.add();
    app.add(); // clamped at 4
    var tree3 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 4), countButtonLabelsWithPrefix(&tree3, "toggle"));

    app.remove();
    app.remove();
    app.remove();
    app.remove(); // clamped at 1
    var tree4 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 1), countButtonLabelsWithPrefix(&tree4, "toggle"));
}

test "mute zeroes the volume label" {
    var app = TodoApp{};
    const tree = try buildTree(&app);
    defer freeTree();
    try expectLabel(&tree, "Volume: 0.5");

    app.mute();
    var tree2 = try buildTree(&app);
    try expectLabel(&tree2, "Volume: 0.0");
}

test "click injection: the inc button click reaches the component" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    var todo = TodoApp{};
    _ = try app.register(TodoApp, &todo);

    const out1 = try app.frame(TodoApp, &todo, 1, .{ .width = 800, .height = 600 });
    defer std.testing.allocator.free(out1.json);
    try std.testing.expect(std.mem.indexOf(u8, out1.json, "Counter: 0") != null);

    // Find the "inc" button by scanning by kind — ids are not positions.
    var inc_id: ?Id = null;
    for (out1.tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.eql(u8, b.label, "inc")) inc_id = n.id;
            },
            else => {},
        }
    }
    try std.testing.expect(inc_id != null);

    // Click while the frame tree is still valid (dies at the next arena reset).
    app.click(out1.tree, inc_id.?);

    const out2 = try app.frame(TodoApp, &todo, 2, .{ .width = 800, .height = 600 });
    defer std.testing.allocator.free(out2.json);
    try std.testing.expect(std.mem.indexOf(u8, out2.json, "Counter: 1") != null);
}
