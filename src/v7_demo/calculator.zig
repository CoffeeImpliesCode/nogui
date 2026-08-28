//! Small calculator demo showing v7 containers, labels, styled buttons,
//! typed callbacks, component-scoped defaults, and immediate-mode redraws.
//!
//!   zig build calculator
//!   zig build v7 -- --calculator --sim script.json
//!
//! Arithmetic is immediate-execution; all state persists in CalculatorApp.

const std = @import("std");

const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const Style = nogui.Style;
const PaintStyle = nogui.PaintStyle;
const WidgetTree = nogui.WidgetTree;
const WidgetNode = nogui.WidgetNode;
const App = nogui.App;

const srgbToOklab = @import("text.zig").srgbToOklab;

// ── Palette (same dark theme as the TodoApp demo; sRGB in, Oklab render) ──
const c_card: [4]f32 = .{ 0.13, 0.14, 0.19, 1 };
const c_border: [4]f32 = .{ 0.24, 0.25, 0.33, 0.55 };
const c_border_strong: [4]f32 = .{ 0.34, 0.35, 0.46, 0.75 };
const c_key: [4]f32 = .{ 0.19, 0.20, 0.26, 1 };
const c_text: [4]f32 = .{ 0.87, 0.87, 0.92, 1 };
const c_text_muted: [4]f32 = .{ 0.46, 0.47, 0.56, 1 };
const c_accent: [4]f32 = .{ 0.40, 0.34, 0.78, 1 };
const c_on_accent: [4]f32 = .{ 0.95, 0.94, 1, 1 };
const c_error: [4]f32 = .{ 0.85, 0.36, 0.39, 1 };

const entry_capacity = 32;

pub const CalculatorApp = struct {
    /// Accumulated left-hand side of the pending operation.
    acc: f64 = 0,
    pending: ?Op = null,
    /// Digits typed since the last operator/`=` (ASCII, no terminator).
    // SAFETY: only the first entry_len bytes are ever read; digit/dot
    // write before any read and clear() resets entry_len.
    entry: [entry_capacity]u8 = undefined,
    entry_len: usize = 0,
    entering: bool = false,
    /// Sticky error (division by zero); any key except `C` is ignored.
    error_state: bool = false,
    keypad: Keypad = .{},

    pub const Op = enum { add, sub, mul, div };

    pub const Keypad = struct {
        // SAFETY: CalculatorApp.draw sets owner before ctx.component draws
        // or registers this persistent Keypad.
        owner: *CalculatorApp = undefined,

        const Action = union(enum) {
            clear,
            negate,
            percent,
            double_zero,
            dot,
            equals,
            digit: u8,
            op: CalculatorApp.Op,
        };

        const KeySpec = struct {
            label: []const u8,
            action: Action,
            accent: bool = false,
        };

        const key_specs: [20]KeySpec = .{
            .{ .label = "C", .action = .clear },
            .{ .label = "±", .action = .negate },
            .{ .label = "%", .action = .percent },
            .{ .label = "÷", .action = .{ .op = .div }, .accent = true },
            .{ .label = "7", .action = .{ .digit = 7 } },
            .{ .label = "8", .action = .{ .digit = 8 } },
            .{ .label = "9", .action = .{ .digit = 9 } },
            .{ .label = "×", .action = .{ .op = .mul }, .accent = true },
            .{ .label = "4", .action = .{ .digit = 4 } },
            .{ .label = "5", .action = .{ .digit = 5 } },
            .{ .label = "6", .action = .{ .digit = 6 } },
            .{ .label = "−", .action = .{ .op = .sub }, .accent = true },
            .{ .label = "1", .action = .{ .digit = 1 } },
            .{ .label = "2", .action = .{ .digit = 2 } },
            .{ .label = "3", .action = .{ .digit = 3 } },
            .{ .label = "+", .action = .{ .op = .add }, .accent = true },
            .{ .label = "0", .action = .{ .digit = 0 } },
            .{ .label = "00", .action = .double_zero },
            .{ .label = ".", .action = .dot },
            .{ .label = "=", .action = .equals, .accent = true },
        };

        pub const default_style: Style = .{
            .direction = .row,
            .gap = .{ .length = 8 },
            .justify = .center,
            .@"align" = .center,
        };
        pub const default_paint: PaintStyle = .{
            .border_color = c_border_strong,
            .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
            .fill = c_key,
            .gradient = srgbToOklab(c_key),
        };

        pub fn draw(self: *Keypad, ctx: *DrawCtx) !void {
            _ = self;
            for (0..5) |row_index| {
                const key_index_start = row_index * 4;
                _ = try ctx.row(.{
                    .border_color = .{ 0, 0, 0, 1 },
                    .radius = .{},
                    .fill = .{ 0, 0, 0, 0 },
                    .gradient = .{ 0, 0, 0, 0 },
                });
                defer ctx.pop();

                for (
                    key_specs[key_index_start .. key_index_start + 4],
                    key_index_start..,
                ) |key, key_index| {
                    const fill = if (key.accent) c_accent else default_paint.fill;
                    _ = try ctx.button(.{
                        .label = key.label,
                        .on_click_with_data = nogui.bind(Keypad.onKey, key_index),
                        .color = if (key.accent) c_on_accent else c_text,
                        .font_size = 18,
                        .grow = 1,
                        .basis = 44,
                        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                        .border_color = if (key.accent) c_accent else default_paint.border_color,
                        .fill = fill,
                        .gradient = if (key.accent) srgbToOklab(c_accent) else default_paint.gradient,
                    });
                }
            }
        }

        fn onKey(self: *Keypad, index: usize) void {
            std.debug.assert(index < key_specs.len);
            switch (key_specs[index].action) {
                .clear => self.owner.clear(),
                .negate => self.owner.negate(),
                .percent => self.owner.percent(),
                .double_zero => self.owner.doubleZero(),
                .dot => self.owner.dot(),
                .equals => self.owner.equals(),
                .digit => |digit_value| self.owner.digit(digit_value),
                .op => |op| self.owner.setOp(op),
            }
        }
    };
    pub const default_style: Style = .{ .direction = .column, .gap = .{ .length = 12 } };

    // ── Interaction (also the unit-test surface) ──
    pub fn digit(self: *CalculatorApp, d: u8) void {
        if (self.error_state) return;
        if (!self.entering) {
            self.entry_len = 0;
            self.entering = true;
        }
        if (self.entry_len >= entry_capacity) return;
        // Skip a redundant leading zero ("0" + "5" -> "5").
        if (self.entry_len == 1 and self.entry[0] == '0') self.entry_len = 0;
        self.entry[self.entry_len] = '0' + d;
        self.entry_len += 1;
    }

    pub fn dot(self: *CalculatorApp) void {
        if (self.error_state) return;
        if (!self.entering) {
            self.entry_len = 0;
            self.entry[0] = '0';
            self.entry_len = 1;
            self.entering = true;
        }
        for (self.entry[0..self.entry_len]) |ch| {
            if (ch == '.') return;
        }
        if (self.entry_len >= entry_capacity) return;
        self.entry[self.entry_len] = '.';
        self.entry_len += 1;
    }

    pub fn setOp(self: *CalculatorApp, op: Op) void {
        if (self.error_state) return;
        const current = self.currentValue();
        if (self.pending != null and self.entering) {
            self.acc = apply(self.acc, current, self.pending.?);
        } else if (self.pending == null) {
            self.acc = current;
        }
        self.pending = op;
        self.entering = false;
        if (std.math.isInf(self.acc) or std.math.isNan(self.acc)) self.error_state = true;
    }

    pub fn equals(self: *CalculatorApp) void {
        if (self.error_state) return;
        const pending_op = self.pending orelse return;
        const current = if (self.entering) self.currentValue() else self.acc;
        self.acc = apply(self.acc, current, pending_op);
        self.pending = null;
        self.entering = false;
        if (std.math.isInf(self.acc) or std.math.isNan(self.acc)) self.error_state = true;
    }

    pub fn clear(self: *CalculatorApp) void {
        // Keep persistent subcomponents registered; only calculator state
        // resets. Clearing self wholesale would invalidate keypad.owner
        // until the next frame.
        self.acc = 0;
        self.pending = null;
        self.entry_len = 0;
        self.entering = false;
        self.error_state = false;
    }

    pub fn doubleZero(self: *CalculatorApp) void {
        self.digit(0);
        self.digit(0);
    }

    pub fn negate(self: *CalculatorApp) void {
        if (self.error_state) return;
        if (self.entering) {
            self.replaceEntry(-self.currentValue());
        } else {
            self.acc = -self.acc;
        }
    }

    pub fn percent(self: *CalculatorApp) void {
        if (self.error_state) return;
        if (self.entering) {
            self.replaceEntry(self.currentValue() / 100);
        } else {
            self.acc /= 100;
        }
    }

    fn replaceEntry(self: *CalculatorApp, value: f64) void {
        const text = std.fmt.bufPrint(&self.entry, "{d}", .{value}) catch {
            self.error_state = true;
            return;
        };
        self.entry_len = text.len;
        self.entering = true;
    }

    fn currentValue(self: *const CalculatorApp) f64 {
        if (!self.entering) return self.acc;
        const text = self.entry[0..self.entry_len];
        if (text.len == 0) return 0;
        return std.fmt.parseFloat(f64, text) catch 0;
    }

    fn apply(a: f64, b: f64, op: Op) f64 {
        return switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => if (b == 0) std.math.nan(f64) else a / b,
        };
    }

    /// The display line: the live entry while typing, otherwise the
    /// accumulator (or the error marker).
    fn displayText(self: *const CalculatorApp, arena: std.mem.Allocator) ![]const u8 {
        if (self.error_state) return arena.dupe(u8, "Error");
        if (self.entering and self.entry_len > 0) return arena.dupe(u8, self.entry[0..self.entry_len]);
        return std.fmt.allocPrint(arena, "{d}", .{self.acc});
    }

    // ── Draw ──

    pub fn draw(self: *CalculatorApp, ctx: *DrawCtx) !void {
        self.keypad.owner = self;

        // Root column: centers the calculator card in the window.
        _ = try ctx.column(.{
            .grow = 1,
            .justify = .center,
            .@"align" = .center,
            .padding = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 },
        });
        defer ctx.pop();

        // The calculator card.
        _ = try ctx.column(.{
            .direction = .column,
            .gap = 10,
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_color = c_border,
            .radius = .{ .top = 14, .right = 14, .bottom = 14, .left = 14 },
            .padding = .{ .top = 14, .right = 14, .bottom = 14, .left = 14 },
            .fill = c_card,
            .gradient = srgbToOklab(c_card),
            .shadow = 6,
        });
        defer ctx.pop();

        _ = try ctx.label(.{
            .text = "CALCULATOR",
            .color = c_text_muted,
            .font_size = 11,
        });

        {
            _ = try ctx.row(.{
                .direction = .row,
                .gap = 0,
                .justify = .end,
                .@"align" = .center,
                .padding = .{ .top = 10, .right = 12, .bottom = 10, .left = 12 },
                .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                .border_color = c_border_strong,
                .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                .fill = c_key,
                .gradient = srgbToOklab(c_key),
            });
            defer ctx.pop();

            _ = try ctx.label(.{
                .text = try self.displayText(ctx.arena),
                .color = if (self.error_state) c_error else c_text,
                .font_size = 28,
            });
        }
        try ctx.component(Keypad, .{ .key = .{ .static = "keypad" } }, &self.keypad);
    }
};

// ── tests -------------------------------------------------------------------

var test_arena: ?std.heap.ArenaAllocator = null;

fn buildTree(app: *CalculatorApp) !WidgetTree {
    freeTree();
    test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer freeTree();
    const arena = if (test_arena) |*a| a else unreachable;
    const alloc = arena.allocator();
    var tree = WidgetTree.init(alloc);
    var ctx: DrawCtx = .{ .tree = &tree, .arena = alloc };
    try app.draw(&ctx);
    return tree;
}

fn freeTree() void {
    if (test_arena) |*a| a.deinit();
    test_arena = null;
}

fn findButton(tree: *const WidgetTree, label: []const u8) ?*const WidgetNode {
    for (tree.nodes.items) |*node| {
        if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) return node;
    }
    return null;
}

fn displayLabel(
    arena: std.mem.Allocator,
    tree: *const WidgetTree,
    app: *CalculatorApp,
) ![]const u8 {
    const display = try app.displayText(arena);
    for (tree.nodes.items) |*node| {
        if (node.kind == .label and node.kind.label.text.len == display.len and
            std.mem.eql(u8, node.kind.label.text, display) and node.font_size > 20)
        {
            // The label text lives in the tree arena; copy so the caller
            // can free with the testing allocator, and drop the probe
            // string this function allocated itself.
            defer arena.free(display);
            return std.testing.allocator.dupe(u8, node.kind.label.text);
        }
    }
    arena.free(display);
    return error.DisplayLabelMissing;
}

test "digits build an entry, operators chain, equals resolves" {
    var app: CalculatorApp = .{};
    app.digit(1);
    app.digit(2);
    try std.testing.expectEqual(@as(f64, 12), app.currentValue());
    app.setOp(.add);
    app.digit(3);
    app.digit(0);
    app.equals();
    try std.testing.expectEqual(@as(f64, 42), app.acc);
    try std.testing.expect(app.pending == null);
    try std.testing.expect(!app.entering);
}

test "operator without equals chains immediately" {
    var app: CalculatorApp = .{};
    app.digit(8);
    app.setOp(.mul);
    app.digit(4);
    app.setOp(.sub);
    try std.testing.expectEqual(@as(f64, 32), app.acc);
    app.digit(2);
    app.equals();
    try std.testing.expectEqual(@as(f64, 30), app.acc);
}

test "division by zero raises the sticky error; C recovers" {
    var app: CalculatorApp = .{};
    app.digit(5);
    app.setOp(.div);
    app.digit(0);
    app.equals();
    try std.testing.expect(app.error_state);
    app.digit(7); // ignored while in the error state
    try std.testing.expectEqual(@as(usize, 1), app.entry_len); // unchanged
    app.clear();
    app.digit(7);
    try std.testing.expectEqual(@as(f64, 7), app.currentValue());
    try std.testing.expect(!app.error_state);
}
test "clear keeps the persistent keypad owner valid before the next frame" {
    var app: CalculatorApp = .{};
    app.keypad.owner = &app;
    app.digit(9);
    app.keypad.onKey(0); // C
    app.keypad.onKey(4); // 7
    try std.testing.expectEqual(@as(f64, 7), app.currentValue());
}

test "leading zeros collapse and the dot stays single" {
    var app: CalculatorApp = .{};
    app.digit(0);
    app.digit(0);
    app.digit(5);
    try std.testing.expectEqualStrings("5", app.entry[0..app.entry_len]);
    app.dot();
    app.dot();
    try std.testing.expectEqualStrings("5.", app.entry[0..app.entry_len]);
}

test "unary keys and double zero update the active value" {
    var app: CalculatorApp = .{};
    app.digit(5);
    app.doubleZero();
    try std.testing.expectEqual(@as(f64, 500), app.currentValue());
    app.negate();
    try std.testing.expectEqual(@as(f64, -500), app.currentValue());
    app.percent();
    try std.testing.expectEqual(@as(f64, -5), app.currentValue());
}

test "draw: tree contains every key and the display label" {
    var app: CalculatorApp = .{};
    app.digit(4);
    app.digit(2);
    var tree = try buildTree(&app);
    defer freeTree();

    const all_keys = [_][]const u8{
        "C",
        "±",
        "%",
        "÷",
        "7",
        "8",
        "9",
        "×",
        "4",
        "5",
        "6",
        "−",
        "1",
        "2",
        "3",
        "+",
        "0",
        "00",
        ".",
        "=",
    };
    for (all_keys) |label| {
        try std.testing.expect(findButton(&tree, label) != null);
    }
    const text = try displayLabel(std.testing.allocator, &tree, &app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("42", text);
}

test "clear resets the display in the next frame" {
    var app: CalculatorApp = .{};
    app.digit(9);
    app.clear();
    var tree = try buildTree(&app);
    defer freeTree();
    const text = try displayLabel(std.testing.allocator, &tree, &app);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("0", text);
}

test "app frame: display text survives the JSON dump" {
    var core = App.init(std.testing.allocator);
    defer core.deinit();
    core.serialize_json = true;

    var calc: CalculatorApp = .{};
    _ = try core.register(CalculatorApp, &calc);

    calc.digit(1);
    calc.digit(2);
    calc.setOp(.add);
    const out = try core.frame(CalculatorApp, &calc, 1, .{ .width = 360, .height = 520 });
    defer if (out.json) |j| std.testing.allocator.free(j);
    // The entry ("12") is the live display while an operator is pending.
    try std.testing.expect(std.mem.indexOf(u8, out.json.?, "\"12\"") != null);
}
