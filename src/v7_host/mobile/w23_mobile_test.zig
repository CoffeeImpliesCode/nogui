//! W23 mobile accessibility contracts: the two identities and what each one is
//! for, a publication the platform refuses, the byte/character conversion in
//! both directions, the bounded request ring, and the single seam every
//! platform action travels.
//!
//! Everything here is a real `semantics.Snapshot` of real `semantics.Node`
//! values, built by hand so the node order, the relations and the text runs
//! are exact. The snapshots are the type the whole host publishes, so nothing
//! in these tests stands in for the model: the conversions, the refusals and
//! the offsets are the ones a phone would get.
const std = @import("std");
const accessibility = @import("accessibility.zig");
const nogui = @import("nogui");
const sdl_mobile = @import("sdl_mobile.zig");
const lifecycle = @import("lifecycle.zig");
const application = @import("../application.zig");
const sdl_session = @import("../sdl_session.zig");
const sdl3 = @import("sdl3");

const Adapter = accessibility.Adapter;
const NodeId = accessibility.NodeId;
const Snapshot = accessibility.Snapshot;
const Dispatcher = accessibility.Dispatcher;
const Scratch = accessibility.Scratch;
const TextSelection = accessibility.TextSelection;
const semantics = accessibility.semantics;
const native = @import("native.zig");
/// The mobile shim's own constants, so a state the wire publishes is named
/// rather than counted out in the test.
const c = native.c;

const WidgetId = nogui.WidgetId;
const Action = semantics.Action;
const Node = semantics.Node;
const NativeData = accessibility.NativeData;

/// The window root every snapshot publishes first.
const root_id: NodeId = semantics.window_node;

fn owner(tag: u64, slot: u32) WidgetId {
    return .{ .owner = tag, .slot = slot, .generation = 1 };
}

/// A semantic identity, exactly as the core mints one from a live owner.
fn identityOf(widget: WidgetId) NodeId {
    return semantics.nodeId(widget, .self_node);
}

const w_save = owner(0x5100, 1);
const w_field = owner(0x5200, 1);
const w_extra = owner(0x5300, 1);
const w_replace = owner(0x5400, 1);
const w_list = owner(0x5500, 1);
const w_row = owner(0x5600, 1);
const w_menu = owner(0x5700, 1);
const w_slider = owner(0x5800, 1);
const w_absent = owner(0x9900, 1);
/// A read-only control and a disabled one, for the refusal contracts.
const w_locked = owner(0x5A00, 1);
const w_off = owner(0x5B00, 1);
const w_locked_field = owner(0x5C00, 1);

const n_save = identityOf(w_save);
const n_field = identityOf(w_field);
const n_extra = identityOf(w_extra);
const n_replace = identityOf(w_replace);
const n_list = identityOf(w_list);
const n_row = identityOf(w_row);
const n_menu = identityOf(w_menu);
const n_slider = identityOf(w_slider);
/// An identity no snapshot in this file publishes.
const n_absent = identityOf(w_absent);
const n_locked = identityOf(w_locked);
const n_off = identityOf(w_off);
const n_locked_field = identityOf(w_locked_field);

/// "Grüße ✓" is seven Unicode code points and eleven UTF-8 bytes, so a byte
/// offset that lands inside "ü" has no character position of its own on the
/// platform side.
const multibyte_text: []const u8 = "Grüße ✓";
const multibyte_bytes: usize = 11;
const multibyte_lengths: [7]u8 = .{ 1, 1, 2, 2, 1, 1, 3 };
const multibyte_positions: [7]f32 = .{ 0, 10, 20, 30, 40, 50, 60 };
const multibyte_widths: [7]f32 = .{ 10, 10, 10, 10, 10, 10, 10 };
/// The published selection starts inside "ü" (byte 3) and ends past the last
/// character (byte 11), which is the caret position after the whole run.
const multibyte_anchor_byte: usize = 3;
const multibyte_focus_byte: usize = multibyte_bytes;

const replace_text: []const u8 = "hello world";
const replace_lengths: [11]u8 = @splat(1);
const replace_positions: [11]f32 = .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80 };
const replace_widths: [11]f32 = @splat(8);

const kids_save_field = [_]NodeId{ n_save, n_field };
const kids_field_extra = [_]NodeId{ n_field, n_extra };
const kids_replace = [_]NodeId{n_replace};
const kids_relations = [_]NodeId{ n_list, n_row, n_menu, n_slider };
const kids_list = [_]NodeId{n_row};
const kids_save = [_]NodeId{n_save};
const kids_absent = [_]NodeId{n_absent};

const tree_save_field = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_save_field,
    },
    .{
        .id = n_save,
        .parent = root_id,
        .role = .button,
        .owner = w_save,
        .name = "Save",
        .bounds = .{ .x = 10, .y = 20, .w = 80, .h = 30 },
        .actions = .{ .click = true, .focus = true },
    },
    .{
        .id = n_field,
        .parent = root_id,
        .role = .text_input,
        .owner = w_field,
        .name = "Field",
        .bounds = .{ .x = 10, .y = 60, .w = 200, .h = 24 },
        .actions = .{ .replace_selected_text = true, .set_text_selection = true },
        .text = .{
            .value = multibyte_text,
            .character_lengths = &multibyte_lengths,
            .character_positions = &multibyte_positions,
            .character_widths = &multibyte_widths,
            .selection = .{
                .anchor = multibyte_anchor_byte,
                .focus = multibyte_focus_byte,
            },
        },
    },
};

/// The same window with the field kept, the button removed and a control the
/// application had not published before taking its place, in a different order.
const tree_reorder = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_field_extra,
    },
    .{
        .id = n_field,
        .parent = root_id,
        .role = .text_input,
        .owner = w_field,
        .name = "Field",
        .bounds = .{ .x = 10, .y = 60, .w = 200, .h = 24 },
        .actions = .{ .replace_selected_text = true, .set_text_selection = true },
        .text = .{
            .value = multibyte_text,
            .character_lengths = &multibyte_lengths,
            .character_positions = &multibyte_positions,
            .character_widths = &multibyte_widths,
            .selection = .{
                .anchor = multibyte_anchor_byte,
                .focus = multibyte_focus_byte,
            },
        },
    },
    .{
        .id = n_extra,
        .parent = root_id,
        .role = .button,
        .owner = w_extra,
        .name = "Extra",
        .bounds = .{ .x = 10, .y = 20, .w = 80, .h = 30 },
        .actions = .{ .click = true },
    },
};

const named_actions = [_]semantics.CustomAction{
    .{ .id = 7, .name = "Archive" },
    .{ .id = 9, .name = "Pin" },
};

const tree_relations = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_relations,
    },
    .{
        .id = n_list,
        .parent = root_id,
        .role = .list,
        .owner = w_list,
        .name = "Rows",
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 100 },
        .relations = .{ .row_count = 3 },
        .actions = .{ .custom_action = true },
        .children = &kids_list,
    },
    .{
        .id = n_row,
        .parent = n_list,
        .role = .list_item,
        .owner = w_row,
        .name = "Row one",
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 24 },
        .relations = .{ .member_of = n_list, .row_index = 1, .row_count = 3 },
        .actions = .{ .click = true },
    },
    .{
        .id = n_menu,
        .parent = root_id,
        .role = .button,
        .owner = w_menu,
        .name = "More",
        .bounds = .{ .x = 0, .y = 104, .w = 80, .h = 30 },
        .actions = .{ .custom_action = true },
        .custom_actions = &named_actions,
    },
    .{
        .id = n_slider,
        .parent = root_id,
        .role = .slider,
        .owner = w_slider,
        .name = "Volume",
        .bounds = .{ .x = 0, .y = 140, .w = 200, .h = 24 },
        .value = .{ .number = 0.5 },
        .range = .{ .min = 0, .max = 1, .step = 0.25 },
        .actions = .{ .set_value = true, .increment = true, .decrement = true },
    },
};

/// A control the core refuses to act on, in both of the ways it refuses.
/// `n_locked` is READ-ONLY: it publishes its value and its range so a screen
/// reader announces them, and it offers no action that would change either.
/// `n_off` is DISABLED: it is published so the state is announced, and it
/// carries named actions the model would refuse — the shared encoder's gate is
/// the one that withholds them, and the mobile wire has to agree with it.
const kids_locked = [_]NodeId{ n_locked, n_off };

const tree_locked = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_locked,
    },
    .{
        .id = n_locked,
        .parent = root_id,
        .role = .slider,
        .owner = w_locked,
        .name = "Volume",
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 24 },
        .states = .{ .read_only = true },
        .value = .{ .number = 0.5 },
        .range = .{ .min = 0, .max = 1, .step = 0.25 },
        .actions = .{ .click = true, .set_value = true, .increment = true, .decrement = true },
    },
    .{
        .id = n_off,
        .parent = root_id,
        .role = .button,
        .owner = w_off,
        .name = "More",
        .bounds = .{ .x = 0, .y = 40, .w = 80, .h = 30 },
        .states = .{ .disabled = true },
        .actions = .{ .custom_action = true },
        .custom_actions = &named_actions,
    },
};

/// A read-only TEXT control, which is the case a numeric read-only control
/// cannot show. It publishes the two text actions a caret needs — moving a
/// caret changes no contents, so the core accepts them on a read-only node —
/// alongside the ones that would write, so the published mask can be told
/// apart from one a bound control merely withholds for want of a keyboard.
const kids_bound_locked = [_]NodeId{n_locked_field};

const tree_bound_locked = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_bound_locked,
    },
    .{
        .id = n_locked_field,
        .parent = root_id,
        .role = .text_input,
        .owner = w_locked_field,
        .name = "Report",
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 24 },
        .states = .{ .read_only = true },
        .actions = .{
            .replace_selected_text = true,
            .set_text_selection = true,
            .set_value = true,
        },
        .text = .{
            .value = replace_text,
            .character_lengths = &replace_lengths,
            .character_positions = &replace_positions,
            .character_widths = &replace_widths,
            .selection = .{ .anchor = 0, .focus = 5 },
        },
    },
};

const tree_replace = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_replace,
    },
    .{
        .id = n_replace,
        .parent = root_id,
        .role = .text_input,
        .owner = w_replace,
        .name = "Note",
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 24 },
        .actions = .{
            .replace_selected_text = true,
            .set_text_selection = true,
            // The whole-value door a provider's SetTextContents arrives on:
            // the payload IS the field's entire new contents, so it composes
            // against nothing and stays valid however the model has moved
            // since the publication it was aimed at.
            .set_value = true,
        },
        .text = .{
            .value = replace_text,
            .character_lengths = &replace_lengths,
            .character_positions = &replace_positions,
            .character_widths = &replace_widths,
            .selection = .{ .anchor = 0, .focus = 5 },
        },
    },
};

const tree_orphan_parent = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_save,
    },
    .{
        .id = n_save,
        .parent = n_absent,
        .role = .button,
        .owner = w_save,
        .name = "Save",
        .actions = .{ .click = true },
    },
};

const tree_orphan_child = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_absent,
    },
    .{
        .id = n_save,
        .parent = root_id,
        .role = .button,
        .owner = w_save,
        .name = "Save",
        .actions = .{ .click = true },
    },
};

const tree_orphan_member = [_]Node{
    .{
        .id = root_id,
        .parent = semantics.no_node,
        .role = .window,
        .name = "Fixture",
        .children = &kids_save,
    },
    .{
        .id = n_save,
        .parent = root_id,
        .role = .list_item,
        .owner = w_save,
        .name = "Orphan row",
        .relations = .{ .member_of = n_absent, .row_index = 0, .row_count = 1 },
        .actions = .{ .click = true },
    },
};

/// One committed snapshot, built by hand so node order and relations are
/// exact. It is the type the whole host publishes, so the adapter under test
/// performs the conversions a phone would get.
const Snap = struct {
    arena: std.heap.ArenaAllocator,
    index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty,
    nodes: []Node = &.{},
    view: Snapshot,

    fn init(self: *Snap, spec: []const Node) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const gpa = self.arena.allocator();
        self.nodes = try gpa.dupe(Node, spec);
        self.index = .empty;
        for (self.nodes, 0..) |node, at| try self.index.put(gpa, node.id, @intCast(at));
        self.view = .{
            .generation = 1,
            .root = root_id,
            .focus = semantics.no_node,
            .nodes = self.nodes,
            .index = &self.index,
        };
    }

    fn focusOn(self: *Snap, id: NodeId) void {
        self.view.focus = id;
    }

    fn get(self: *const Snap) *const Snapshot {
        return &self.view;
    }

    fn deinit(self: *Snap) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// 4096 bytes of a two-byte character repeated, so a payload the ring has to
/// copy is real UTF-8 and the assertion afterwards is on real bytes.
const big_payload: [4096]u8 = @bitCast(@as([2048][2]u8, @splat("ü".*)));

/// The model's own value buffer. Its real length IS the capacity the model
/// reports, so a test states one number where it used to state a length and a
/// bound that could drift apart.
const model_capacity: usize = 8192;

const Fixture = struct {
    adapter: Adapter,
    threaded: std.Io.Threaded,
    /// Scratch handed to `Scratch`: every byte is written before the string
    /// that uses it is read, and a zeroed tail is a valid empty string. It is
    /// large enough for a 4096-byte platform edit to be composed in full.
    buffer: [16384]u8 = @splat(0),
    /// The model's LIVE value. Only `last_text[0..last_text_len]` is live, and
    /// `last_selection` is a position in exactly those bytes.
    last_text: [model_capacity]u8 = @splat(0),
    last_text_len: usize = 0,
    last_selection: TextSelection = TextSelection.caret(0),
    text_writes: u32 = 0,
    // Every delivery the text path makes, whole contents or selection only.
    clicks: u32 = 0,
    focus_calls: u32 = 0,
    number_writes: u32 = 0,
    last_number: f64 = 0,
    /// Whether the model has been bound to the run a publication carried.
    /// Binding happens once, so publishing again cannot undo an edit.
    bound: bool = false,

    /// Fills every field, so a test only ever reaches a usable `Fixture`
    /// through this. `undefined` storage is not zeroed, so the counters and
    /// the two scratch buffers are assigned here rather than inherited.
    fn init(self: *Fixture) !void {
        // SAFETY: every field is assigned below, before this function returns
        // and before any test body reads the fixture.
        self.* = undefined;
        self.buffer = @splat(0);
        self.last_text = @splat(0);
        self.last_text_len = 0;
        self.last_selection = TextSelection.caret(0);
        self.text_writes = 0;
        self.clicks = 0;
        self.focus_calls = 0;
        self.number_writes = 0;
        self.last_number = 0;
        self.bound = false;
        self.threaded = .init(std.testing.allocator, .{});
        try self.adapter.init(std.testing.allocator, self.threaded.io());
    }

    fn deinit(self: *Fixture) void {
        self.adapter.deinit();
        self.threaded.deinit();
        self.* = undefined;
    }

    fn activate(context: *anyopaque, _: WidgetId) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.clicks += 1;
    }

    fn focusWidget(context: *anyopaque, _: ?WidgetId) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.focus_calls += 1;
    }

    fn setNumber(context: *anyopaque, _: WidgetId, value: f64) bool {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.number_writes += 1;
        self.last_number = value;
        return true;
    }

    fn setText(
        context: *anyopaque,
        _: WidgetId,
        value: ?[]const u8,
        selection: TextSelection,
    ) bool {
        const self: *Fixture = @ptrCast(@alignCast(context));
        // A null value is a selection-only request: it moves no character
        // byte, so the contents the model last held stay exactly as they
        // were. A non-null value is the field's WHOLE new contents and is
        // written as it is: an empty string clears the model, and bytes
        // that alias the model's own buffer are no exception.
        if (value) |bytes| {
            // A whole value the model cannot store is REFUSED, and it is
            // refused before anything moves: the bytes stay, the selection
            // stays where it was and no write is counted. Storing the part
            // that fits would leave a value no screen reader sent, reported
            // as the one it did.
            if (bytes.len > self.last_text.len) return false;
            @memcpy(self.last_text[0..bytes.len], bytes);
            self.last_text_len = bytes.len;
        }
        self.last_selection = selection;
        self.text_writes += 1;
        return true;
    }

    /// The model's LIVE value, selection and whole-value capacity.
    ///
    /// These bytes are the whole model: what the text door last wrote IS what
    /// it now holds, so there is no published copy for a request to be
    /// composed against and none to fall back on. The selection addresses
    /// those same bytes, direction included. `capacity` is the buffer's real
    /// length — the largest whole value this model can keep, not the room
    /// left in it.
    fn readText(context: *anyopaque, _: WidgetId) ?semantics.TextEditState {
        const self: *Fixture = @ptrCast(@alignCast(context));
        return .{
            .value = self.text(),
            .selection = self.last_selection,
            .capacity = self.last_text.len,
        };
    }

    /// Publish one snapshot and bind this fixture's model to the run it says.
    ///
    /// The fixture stands in for the application that published the tree, so
    /// the value and the selection that tree carries ARE the model's own
    /// content rather than a copy kept beside it. That is what makes the live
    /// getter honest here: a model left empty beside a published run would
    /// answer every request from bytes nobody ever published, which is a
    /// second model and not a test of this one.
    ///
    /// Binding happens once, at the first publish that carries a text run,
    /// and never again: a later publication is the app catching up with edits
    /// the model has already taken, so reading it again would undo them. A run
    /// longer than this model's buffer is not bound at all rather than bound
    /// to its first bytes.
    fn publish(self: *Fixture, snap: *const Snapshot, bridge: anytype) !void {
        try self.adapter.commit(try self.adapter.stage(snap, .{}), bridge);
        if (self.bound) return;
        for (snap.nodes) |node| {
            if (node.role != .text_input) continue;
            const run = node.text orelse continue;
            if (run.value.len > self.last_text.len) continue;
            @memcpy(self.last_text[0..run.value.len], run.value);
            self.last_text_len = run.value.len;
            self.last_selection = run.selection orelse TextSelection.caret(run.value.len);
            self.bound = true;
            return;
        }
    }

    fn dispatcher(self: *Fixture) Dispatcher {
        return .{
            .context = self,
            .activate = activate,
            .focus = focusWidget,
            .set_number = setNumber,
            .set_text = setText,
            .read_text = readText,
        };
    }

    fn scratch(self: *Fixture) Scratch {
        return .{ .row_name = &self.buffer, .text_value = &self.buffer };
    }

    fn text(self: *const Fixture) []const u8 {
        return self.last_text[0..self.last_text_len];
    }
};

/// A platform request addressed to a semantic identity, translated to the
/// native name the publication issued for it.
fn requestFor(adapter: *const Adapter, id: NodeId) native.platform_request {
    return request(adapter.nativeIdOf(id).?);
}

fn request(target: u64) native.platform_request {
    return .{
        .action = @backingInt(Action.click),
        .target = target,
        .data = @backingInt(NativeData.none),
        .value = "",
        .value_len = 0,
        .numeric_value = 0,
        .custom_action = 0,
        // Both shims leave the indices at -1 for a request that carries none.
        .anchor_index = -1,
        .focus_index = -1,
    };
}

fn textRequest(
    target: u64,
    action: Action,
    data: NativeData,
    value: []const u8,
    anchor: i64,
    focus: i64,
) native.platform_request {
    return .{
        .action = @backingInt(action),
        .target = target,
        .data = @backingInt(data),
        .value = value.ptr,
        .value_len = value.len,
        .numeric_value = 0,
        .custom_action = 0,
        .anchor_index = anchor,
        .focus_index = focus,
    };
}

test "api-w23 a focus request travels the ordinary focus seam" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_save_field);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_save).?;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // A screen reader moving focus to a control reaches the application's own
    // focus manager, the same path a Tab press takes, and not a second focus
    // tree this adapter kept for itself.
    fixture.adapter.deliver(textRequest(target, .focus, .none, "", -1, -1));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.focus_calls);
    try std.testing.expectEqual(@as(u32, 0), fixture.clicks);

    // The same control activated is a click and not a focus change: one
    // request, one model edit.
    fixture.adapter.deliver(request(target));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);
    try std.testing.expectEqual(@as(u32, 1), fixture.focus_calls);
}

test "api-w23 a removed identity keeps its name and resolves to nothing" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var first: Snap = undefined;
    try first.init(&tree_save_field);
    defer first.deinit();
    // No platform bridge is attached on this target, and the conversion is
    // still performed and adoptable: that is what makes the routing observable
    // without a screen reader.
    try fixture.publish(first.get(), null);
    const name_save = fixture.adapter.nativeIdOf(n_save).?;
    const name_field = fixture.adapter.nativeIdOf(n_field).?;
    try std.testing.expectEqual(@as(usize, 3), fixture.adapter.publishedCount());
    try std.testing.expectEqual(n_save, fixture.adapter.resolvePublished(name_save).?);

    var second: Snap = undefined;
    try second.init(&tree_reorder);
    defer second.deinit();
    try fixture.publish(second.get(), null);

    // The control that survived a reorder kept the name the platform was last
    // given, which is the whole point of a name rather than an index.
    try std.testing.expectEqual(name_field, fixture.adapter.nativeIdOf(n_field).?);
    try std.testing.expectEqual(n_field, fixture.adapter.resolvePublished(name_field).?);
    // The removed control still HAS a name, because a name is never recycled.
    try std.testing.expectEqual(name_save, fixture.adapter.nativeIdOf(n_save).?);
    // ...and that name addresses nothing, rather than the control that took
    // the removed one's place.
    try std.testing.expect(fixture.adapter.resolvePublished(name_save) == null);
    // The control that took its place has a name of its own.
    const name_extra = fixture.adapter.nativeIdOf(n_extra).?;
    try std.testing.expect(name_extra != name_save);
    try std.testing.expectEqual(n_extra, fixture.adapter.resolvePublished(name_extra).?);
    try std.testing.expectEqual(@as(usize, 3), fixture.adapter.publishedCount());
}

test "api-w23 a publication the platform refused keeps the routing it already had" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var first: Snap = undefined;
    try first.init(&tree_save_field);
    defer first.deinit();
    try fixture.publish(first.get(), null);
    const name_save = fixture.adapter.nativeIdOf(n_save).?;

    // A bridge-less build refuses the publication AFTER the conversion, which
    // is exactly the case that must not leave a half-adopted map behind: the
    // conversion is a fact and the handover never happened.
    var second: Snap = undefined;
    try second.init(&tree_reorder);
    defer second.deinit();
    try std.testing.expectError(
        error.Unsupported,
        fixture.adapter.publish(second.get(), .{}),
    );
    // The routing the platform was last given is untouched, and the
    // conversion that failed is not adopted either: a control that was never
    // handed over has no name.
    try std.testing.expectEqual(n_save, fixture.adapter.resolvePublished(name_save).?);
    try std.testing.expect(fixture.adapter.nativeIdOf(n_extra) == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.adapter.publishedCount());
}

/// A bridge that takes one tree and then refuses, the way an Android bridge
/// refuses every update between a `detach` and the next `attach`.
///
/// It exists because the refusal is the whole case under test and no build
/// without a platform can produce one: a bridge-less host never reaches
/// `update` at all. The bridge pointer it is handed is never dereferenced —
/// `BridgeOps` replaces both native calls — so a placeholder address is the
/// honest stand-in rather than a fabricated native object.
const ScriptedBridge = struct {
    /// True once the platform has been told to refuse what comes next.
    refuse: bool = false,
    updates: u32 = 0,
    focus_reports: u32 = 0,
    /// The window focus the platform was last told about, and how many times it
    /// was told at all.
    focused: bool = false,
    /// The identity the platform resolves from inside `update`. It is looked up
    /// in the tree the platform was just handed, because that is the only way
    /// a framework has to name it, and because a name reaches the ledger only
    /// when `commit` fills it — before this call, not before the handover.
    asked_about: ?NodeId = null,
    adapter: ?*Adapter = null,

    fn setWindowFocused(self: *ScriptedBridge, focused: bool) void {
        self.focus_reports += 1;
        self.focused = focused;
    }

    fn update(self: *ScriptedBridge, tree: *const native.wire_tree) accessibility.Error!void {
        self.updates += 1;
        // A framework resolves nodes by the names it was just handed, so this
        // reads them the same way. Adopting the routing after this call would
        // resolve the name against the publication being replaced, which for
        // a control this publication ADDS means resolving it against a tree
        // that does not contain it — and refusing the request outright.
        if (self.asked_about) |wanted| {
            const target = self.adapter.?;
            for (tree.nodes[0..tree.nodes_len]) |node| {
                if (node.semantic_id != wanted) continue;
                target.deliver(request(node.native_id));
                break;
            }
        }
        if (self.refuse) return error.NativeRefused;
    }

    fn setWindowFocusedOp(context: ?*anyopaque, _: *native.platform_bridge, focused: bool) accessibility.Error!void {
        const self: *ScriptedBridge = @ptrCast(@alignCast(context.?));
        self.setWindowFocused(focused);
    }

    fn updateOp(
        context: ?*anyopaque,
        _: *native.platform_bridge,
        tree: *const native.wire_tree,
    ) accessibility.Error!void {
        const self: *ScriptedBridge = @ptrCast(@alignCast(context.?));
        try self.update(tree);
    }

    /// The pointer the seam hands to the operations it replaced. Never
    /// dereferenced: neither operation touches the bridge it is given, and the
    /// shim's own bridge type is opaque, so there is nothing here to stand up.
    fn handle() *native.platform_bridge {
        return @ptrFromInt(16);
    }
};

test "api-w23 a refused publication hands its own tables back and takes none of the live ones" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var bridge: ScriptedBridge = .{ .adapter = &fixture.adapter };
    fixture.adapter.setBridgeOps(.{
        .context = &bridge,
        .set_window_focused = ScriptedBridge.setWindowFocusedOp,
        .update = ScriptedBridge.updateOp,
    });

    var first: Snap = undefined;
    try first.init(&tree_save_field);
    defer first.deinit();
    try fixture.publish(first.get(), ScriptedBridge.handle());
    const name_save = fixture.adapter.nativeIdOf(n_save).?;
    const name_field = fixture.adapter.nativeIdOf(n_field).?;
    try std.testing.expectEqual(@as(u32, 1), bridge.updates);
    // The focus report went through the seam too, and the platform is told
    // once: the window has not changed focus since.
    try std.testing.expectEqual(@as(u32, 1), bridge.focus_reports);
    try std.testing.expectEqual(@as(usize, 3), fixture.adapter.publishedCount());

    // The platform asks about the tree from INSIDE the handover, for a control
    // that only the incoming publication contains. Resolving it against the
    // table the adapter is replacing would aim the action at a control the
    // platform was never told about, and adopting the routing after the call
    // would refuse the request outright.
    var second: Snap = undefined;
    try second.init(&tree_reorder);
    defer second.deinit();
    bridge.asked_about = n_extra;
    try fixture.publish(second.get(), ScriptedBridge.handle());
    const dispatcher = fixture.dispatcher();
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(second.get(), &dispatcher, fixture.scratch()),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);
    // The control that left the tree has a name — a name is issued before the
    // handover and is never recycled — but it addresses nothing, because the
    // platform received a publication that does not contain it.
    try std.testing.expect(fixture.adapter.resolvePublished(name_save) == null);

    // Now the platform refuses a DIFFERENT tree. On Android this is the normal
    // state between a detach and the next attach, so it is the case that has
    // to be right, and the live table here has to survive it untouched.
    var third: Snap = undefined;
    try third.init(&tree_save_field);
    defer third.deinit();
    bridge.asked_about = null;
    bridge.refuse = true;
    // The window takes keyboard focus in the same publication the platform is
    // about to refuse. The focus report is a fact about the WINDOW, not about
    // the tree, so it is sent before the handover and it stands: undoing it
    // because the tree was refused would tell the platform the window lost
    // focus it still has, and the next publication would not send it again.
    try std.testing.expectError(
        error.NativeRefused,
        fixture.adapter.commit(
            try fixture.adapter.stage(third.get(), .{ .focused = true }),
            ScriptedBridge.handle(),
        ),
    );
    try std.testing.expectEqual(@as(u32, 2), bridge.focus_reports);
    try std.testing.expect(bridge.focused);

    // Everything the platform was last told it has still resolves. The live
    // tree is still the one before the refusal: the button that tree dropped
    // is still gone, and the control it added still answers. The button the
    // REFUSED tree declares kept the name the staging pass gave it, and that
    // name addresses nothing, because the platform never received the
    // publication that declared it.
    const name_extra = fixture.adapter.nativeIdOf(n_extra).?;
    try std.testing.expectEqual(@as(usize, 3), fixture.adapter.publishedCount());
    try std.testing.expectEqual(n_field, fixture.adapter.resolvePublished(name_field).?);
    try std.testing.expectEqual(n_extra, fixture.adapter.resolvePublished(name_extra).?);
    try std.testing.expect(fixture.adapter.resolvePublished(name_save) == null);

    // The next publication takes the reclaimed tables and owns its own
    // routing. Had the refusal left two map values over one allocation,
    // `stage` would clear the table the live one reads and publish into half
    // of the previous publication's storage.
    var fourth: Snap = undefined;
    try fourth.init(&tree_save_field);
    defer fourth.deinit();
    bridge.refuse = false;
    try fixture.adapter.commit(
        try fixture.adapter.stage(fourth.get(), .{ .focused = true }),
        ScriptedBridge.handle(),
    );
    try std.testing.expectEqual(@as(u32, 4), bridge.updates);
    // The focus the refused publication reported is still what the platform
    // holds, so a publication that agrees with it sends nothing: reporting it
    // twice would be a claim the adapter cannot check.
    try std.testing.expectEqual(@as(u32, 2), bridge.focus_reports);
    try std.testing.expectEqual(@as(usize, 3), fixture.adapter.publishedCount());
    try std.testing.expectEqual(n_save, fixture.adapter.resolvePublished(name_save).?);
    try std.testing.expectEqual(n_field, fixture.adapter.resolvePublished(name_field).?);
    // The name the refused tree issued is the SAME name this publication
    // declares the control under, so a screen reader that kept it addresses
    // the control rather than nothing.
    try std.testing.expectEqual(name_extra, fixture.adapter.nativeIdOf(n_extra).?);
    try std.testing.expect(fixture.adapter.resolvePublished(name_extra) == null);
    // `fixture.deinit` frees both routing tables and both staged ones under
    // the leak-checking allocator. An alias frees one buffer twice; a table
    // thrown away instead of handed back leaks. Reaching the end of this test
    // is the assertion for both.
}

/// A platform that refuses every back request, the way Android does on an
/// activity that is not its task root and on a UI thread that missed its two
/// second bound. Both are routine outcomes, and neither is a build that has no
/// platform at all, which is the only case a desktop test can otherwise reach.
const RefusingPlatform = struct {
    deferrals: u32 = 0,

    fn refuse(context: ?*anyopaque) native.Error!void {
        const self: *RefusingPlatform = @ptrCast(@alignCast(context.?));
        self.deferrals += 1;
        return error.NativeRefused;
    }
};

/// What the observer reported, in order. The back and the committed text are
/// the two the pump test asserts on; everything else it ignores.
const Recorder = struct {
    backs: u32 = 0,
    committed: u32 = 0,
    decision: ?lifecycle.BackDecision = null,
    buffer: [64]u8 = @splat(0),
    length: usize = 0,

    fn observe(context: ?*anyopaque, event: sdl_mobile.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        switch (event) {
            .back => |back| {
                self.backs += 1;
                self.decision = back.decision;
            },
            .committed => |value| {
                self.committed += 1;
                const bounded = @min(value.len, self.buffer.len);
                @memcpy(self.buffer[0..bounded], value[0..bounded]);
                self.length = bounded;
            },
            else => {},
        }
    }

    /// The application's answer: leave it to the platform, which is the
    /// decision that reaches the refusal.
    fn decide(_: ?*anyopaque, _: lifecycle.BackRequest) lifecycle.BackDecision {
        return .defer_to_platform;
    }

    fn text(self: *const Recorder) []const u8 {
        return self.buffer[0..self.length];
    }
};

/// A system back press, which is a key on Android and only a key.
fn backEvent(window: sdl3.video.WindowId, timestamp: u64) sdl3.events.Event {
    return .{ .key_down = .{
        .common = .{ .timestamp = timestamp },
        .window_id = window,
        .id = null,
        .scancode = .ac_back,
        .key = null,
        .mod = .{},
        .raw = 0,
        .down = true,
        .repeat = false,
    } };
}

/// Text committed behind the back press, so the pump has a second event whose
/// arrival is only observable if the batch survived the first one.
fn textEvent(window: sdl3.video.WindowId, timestamp: u64, text: [:0]const u8) sdl3.events.Event {
    return .{ .text_input = .{
        .common = .{ .timestamp = timestamp },
        .window_id = window,
        .text = text,
    } };
}

test "api-w23 a back the platform refuses is counted and the events behind it still arrive" {
    try sdl_session.acquireForTest("dummy");
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try application.Application.init(
        std.testing.allocator,
        &session,
        .{ .video_driver = "dummy" },
    );
    defer host.deinit();
    const handle = try host.openWindow(.{ .title = "mobile", .width = 120, .height = 160 });
    const managed = try host.getWindow(handle);

    var observer = sdl_mobile.Observer.init(
        &managed.native,
        .{ .managed = managed, .session = &session },
    );
    defer observer.shutdown();
    var platform: RefusingPlatform = .{};
    var recorder: Recorder = .{};
    observer.setPlatformEffect(.{
        .context = &platform,
        .defer_back = RefusingPlatform.refuse,
    });
    observer.setSink(.{ .context = &recorder, .observe = Recorder.observe });
    observer.setBackPolicy(.{ .context = &recorder, .decide = Recorder.decide });

    // Both events are queued BEFORE the pump runs, because that is the case
    // that matters: SDL has already removed them, so anything that ends the
    // batch early loses them and not only the back press.
    const now = sdl3.timer.getNanosecondsSinceInit();
    try sdl3.events.push(backEvent(managed.native.id, now));
    try sdl3.events.push(textEvent(managed.native.id, now + 1, "ok"));

    try std.testing.expect(try observer.pump(&host));

    // The refusal is a number, not an error. The pump returned, the back was
    // still reported with the decision the application made, and the platform
    // was asked exactly once — a host whose back presses do nothing can read
    // `refused_defers` and know why.
    try std.testing.expectEqual(@as(u32, 1), platform.deferrals);
    try std.testing.expectEqual(@as(u32, 1), observer.refused_defers);
    try std.testing.expectEqual(@as(u32, 1), recorder.backs);
    try std.testing.expectEqual(lifecycle.BackDecision.defer_to_platform, recorder.decision.?);
    // The refusal did not raise `refused_polls`: nothing here is a poll.
    try std.testing.expectEqual(@as(u32, 0), observer.refused_polls);

    // ...and the event queued behind the back press was observed rather than
    // dropped with it. Before the refusal was contained inside the back
    // handler, this text never reached the model at all.
    try std.testing.expectEqual(@as(u32, 1), recorder.committed);
    try std.testing.expectEqualStrings("ok", recorder.text());

    // The queue is drained, so a second batch observes nothing rather than
    // replaying what the first one already took.
    const drained = try observer.pump(&host);
    try std.testing.expect(!drained);
    try std.testing.expectEqual(@as(u32, 1), recorder.committed);
    try std.testing.expectEqual(@as(u32, 1), observer.refused_defers);
}

test "api-w23 a back the platform accepts is not counted as refused" {
    try sdl_session.acquireForTest("dummy");
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try application.Application.init(
        std.testing.allocator,
        &session,
        .{ .video_driver = "dummy" },
    );
    defer host.deinit();
    const handle = try host.openWindow(.{ .title = "handled", .width = 120, .height = 160 });
    const managed = try host.getWindow(handle);

    var observer = sdl_mobile.Observer.init(
        &managed.native,
        .{ .managed = managed, .session = &session },
    );
    defer observer.shutdown();
    var recorder: Recorder = .{};
    observer.setSink(.{ .context = &recorder, .observe = Recorder.observe });
    // `.handled` reaches no platform effect at all, so the counter stays at
    // zero whatever the platform would have said.
    observer.setBackPolicy(.{
        .context = &recorder,
        .decide = struct {
            fn decide(_: ?*anyopaque, _: lifecycle.BackRequest) lifecycle.BackDecision {
                return .handled;
            }
        }.decide,
    });

    const now = sdl3.timer.getNanosecondsSinceInit();
    try sdl3.events.push(backEvent(managed.native.id, now));
    try sdl3.events.push(textEvent(managed.native.id, now + 1, "ok"));
    try std.testing.expect(try observer.pump(&host));

    try std.testing.expectEqual(@as(u32, 1), recorder.backs);
    try std.testing.expectEqual(lifecycle.BackDecision.handled, recorder.decision.?);
    try std.testing.expectEqual(@as(u32, 0), observer.refused_defers);
    // The key is the host's as well: `handleEvent` observes and never consumes,
    // so the event behind it still arrives and the back itself still went to
    // `dispatch` rather than being swallowed by a decision the application
    // made about the platform, not about the queue.
    try std.testing.expectEqual(@as(u32, 1), recorder.committed);
    try std.testing.expectEqualStrings("ok", recorder.text());
}

test "api-w23 a tree staged twice cannot be committed out of order" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_save_field);
    defer snap.deinit();
    const first = try fixture.adapter.stage(snap.get(), .{});
    _ = try fixture.adapter.stage(snap.get(), .{});
    try std.testing.expectError(error.StaleStage, fixture.adapter.commit(first, null));
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.publishedCount());
}

test "api-w23 the first publication declares the tree and a later one does not" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_save_field);
    defer snap.deinit();

    const first = try fixture.adapter.stage(snap.get(), .{});
    // A platform that has nothing published of ours has to be told the whole
    // tree, not handed a patch against a tree it never had.
    try std.testing.expect(first.has_tree_init);
    try fixture.adapter.commit(first, null);

    const second = try fixture.adapter.stage(snap.get(), .{});
    try std.testing.expect(!second.has_tree_init);
    try fixture.adapter.commit(second, null);

    // A screen reader that went away and came back has the same problem, and
    // neither mobile platform reports it, so the host says so.
    fixture.adapter.noteNativeReset();
    const third = try fixture.adapter.stage(snap.get(), .{});
    try std.testing.expect(third.has_tree_init);
    try fixture.adapter.commit(third, null);
    try std.testing.expect(!(try fixture.adapter.stage(snap.get(), .{})).has_tree_init);
}

test "api-w23 a relation the snapshot does not publish is refused, not guessed" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var live: Snap = undefined;
    try live.init(&tree_save_field);
    defer live.deinit();
    try fixture.publish(live.get(), null);
    const name_save = fixture.adapter.nativeIdOf(n_save).?;
    try std.testing.expectEqual(@as(usize, 3), fixture.adapter.publishedCount());

    // A parent, a child and a set owner that the snapshot does not publish all
    // have no dense index. Guessing one would be a node the application never
    // described, so each is refused and the live routing survives.
    var parented: Snap = undefined;
    try parented.init(&tree_orphan_parent);
    defer parented.deinit();
    try std.testing.expectError(
        error.DanglingRelation,
        fixture.adapter.stage(parented.get(), .{}),
    );

    var childed: Snap = undefined;
    try childed.init(&tree_orphan_child);
    defer childed.deinit();
    try std.testing.expectError(
        error.DanglingRelation,
        fixture.adapter.stage(childed.get(), .{}),
    );

    var membered: Snap = undefined;
    try membered.init(&tree_orphan_member);
    defer membered.deinit();
    try std.testing.expectError(
        error.DanglingRelation,
        fixture.adapter.stage(membered.get(), .{}),
    );

    try std.testing.expectEqual(n_save, fixture.adapter.resolvePublished(name_save).?);
    try std.testing.expectEqual(@as(usize, 3), fixture.adapter.publishedCount());
}

test "api-w23 the wire carries the snapshot's dense indices and native root and focus" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_relations);
    defer snap.deinit();
    snap.focusOn(n_row);
    try fixture.publish(snap.get(), null);

    const tree = fixture.adapter.stagedTree();
    try std.testing.expectEqual(@as(usize, tree_relations.len), tree.nodes_len);
    // The platform looks the root and the focus up BY NAME, so both are native
    // ids rather than positions in an array a reorder would move. The list row
    // holds focus in this snapshot, so both names name a published node.
    try std.testing.expectEqual(fixture.adapter.nativeIdOf(root_id).?, tree.root);
    try std.testing.expectEqual(fixture.adapter.nativeIdOf(n_row).?, tree.focus);
    try std.testing.expect(tree.root != 0);
    try std.testing.expect(tree.focus != 0);

    const nodes = tree.nodes[0..tree.nodes_len];
    for (nodes, 0..) |node, at| {
        try std.testing.expectEqual(snap.nodes[at].id, node.semantic_id);
        try std.testing.expect(node.native_id != 0);
    }

    // `parent`, `children` and `member_of` are dense indices into this same
    // array, and index zero is a real index — the window root lives there — so
    // absence cannot be zero. The snapshot's own order is 0 window, 1 list,
    // 2 row, 3 menu, 4 slider, and every one of those references names that.
    try std.testing.expectEqual(accessibility.no_index, nodes[0].parent);
    try std.testing.expectEqual(@as(u64, 0), nodes[1].parent);
    try std.testing.expectEqual(@as(u64, 1), nodes[2].parent);
    try std.testing.expectEqual(@as(u64, 0), nodes[3].parent);
    try std.testing.expectEqual(@as(u64, 0), nodes[4].parent);
    try std.testing.expectEqual(accessibility.no_index, nodes[0].member_of);
    // The list's own child edge names the row's slot, and the row's set owner
    // names the list's.
    try std.testing.expectEqual(@as(usize, 1), nodes[1].children_len);
    try std.testing.expectEqual(@as(u64, 2), nodes[1].children[0]);
    try std.testing.expectEqual(@as(usize, 4), nodes[0].children_len);
    try std.testing.expectEqual(@as(u64, 1), nodes[0].children[0]);
    try std.testing.expectEqual(@as(u64, 4), nodes[0].children[3]);
    try std.testing.expectEqual(@as(u64, 1), nodes[2].member_of);
    // The row publishes a position in a set; the list publishes a size and no
    // position, so it is not a set member of anything.
    try std.testing.expectEqual(@as(i32, 1), nodes[2].has_set);
    try std.testing.expectEqual(@as(u32, 1), nodes[2].set_position);
    try std.testing.expectEqual(@as(u32, 3), nodes[2].set_size);
    try std.testing.expectEqual(@as(i32, 0), nodes[1].has_set);

    // A named action the application attached travels by its own id and name.
    try std.testing.expectEqual(@as(usize, 2), nodes[3].custom_actions_len);
    try std.testing.expectEqual(@as(i32, 7), nodes[3].custom_actions[0].id);
    try std.testing.expectEqualStrings(
        "Archive",
        nodes[3].custom_actions[0].name[0..nodes[3].custom_actions[0].name_len],
    );
    try std.testing.expectEqual(@as(usize, 0), nodes[1].custom_actions_len);
}

test "api-w23 a run with multi-byte characters publishes character offsets" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_save_field);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);

    const field = fixture.adapter.stagedTree().nodes[2];
    // The run crosses the boundary as its own bytes, not a NUL-terminated copy.
    try std.testing.expectEqual(multibyte_bytes, field.text_len);
    try std.testing.expectEqualStrings(
        multibyte_text,
        field.text[0..field.text_len],
    );
    // Byte 3 is INSIDE "ü" and byte 11 is past the last character, so the
    // offsets the platform is given are the characters those bytes name: 2 and
    // 7, not 3 and 11. A platform that addressed byte 3 would have no
    // character there to put a caret at.
    try std.testing.expectEqual(@as(i64, 2), @as(i64, field.text_selection_anchor));
    try std.testing.expectEqual(@as(i64, 7), @as(i64, field.text_selection_focus));
}

test "api-w23 a run with no character table is not addressable on the platform" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_relations);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);

    // A node with no text run has no offsets at all, and -1 says so. A
    // collapsed caret at zero would be a selection the run does not have.
    const tree = fixture.adapter.stagedTree();
    for (tree.nodes[0..tree.nodes_len]) |node| {
        try std.testing.expectEqual(@as(i64, -1), @as(i64, node.text_selection_anchor));
        try std.testing.expectEqual(@as(i64, -1), @as(i64, node.text_selection_focus));
    }
}

test "api-w23 a selection comes back as the core's byte offsets" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_save_field);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);

    // The publication's selection started at byte 3, which is INSIDE "ü" and
    // so has no character position of its own; it went to the platform as
    // character 2, the start of "ü". The platform addressed characters 2..7,
    // and the same table read in the other direction gives byte 2 — a
    // character boundary — and byte 11, the end of the run. The position
    // inside the character is gone, and the caret is somewhere the platform
    // can actually put one.
    fixture.adapter.deliver(textRequest(
        fixture.adapter.nativeIdOf(n_field).?,
        .set_text_selection,
        .text_selection,
        "",
        2,
        7,
    ));
    try std.testing.expect(fixture.adapter.hasPending());
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
    try std.testing.expectEqual(@as(usize, 2), fixture.last_selection.anchor);
    try std.testing.expectEqual(multibyte_bytes, fixture.last_selection.focus);
    try std.testing.expect(!fixture.adapter.hasPending());
}

test "api-w23 a selection the run cannot address changes nothing" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_save_field);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_field).?;

    // Character 8 is past the end of a seven-character run. There is no
    // position there, so the request is handed to the model with no selection
    // at all and the model refuses it — it is never clamped into a caret the
    // user did not ask for.
    fixture.adapter.deliver(textRequest(
        target,
        .set_text_selection,
        .text_selection,
        "",
        2,
        8,
    ));
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);

    // A request whose range the shim left at -1 names no position in any run,
    // so it is refused where it arrives rather than entering the ring.
    fixture.adapter.deliver(textRequest(
        target,
        .set_text_selection,
        .text_selection,
        "",
        -1,
        -1,
    ));
    try std.testing.expectEqual(@as(u32, 1), fixture.adapter.refusedRequests());
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
}

test "api-w23 a request for an identity the publication dropped changes nothing" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var first: Snap = undefined;
    try first.init(&tree_save_field);
    defer first.deinit();
    try fixture.publish(first.get(), null);
    const name_save = fixture.adapter.nativeIdOf(n_save).?;

    var second: Snap = undefined;
    try second.init(&tree_reorder);
    defer second.deinit();
    try fixture.publish(second.get(), null);

    // A screen reader that kept the button's name and presses it now must not
    // activate whatever the application published in its place. The name
    // resolves to nothing, so no request is produced at all.
    try std.testing.expect(fixture.adapter.resolvePublished(name_save) == null);
    fixture.adapter.deliver(request(name_save));
    try std.testing.expectEqual(@as(u32, 1), fixture.adapter.refusedRequests());
    try std.testing.expect(!fixture.adapter.hasPending());
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(second.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.clicks);
}

test "api-w23 a platform edit is carried whole and applied once" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_replace);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_replace).?;

    // The publication held bytes 0..5, and the platform reported that same
    // range, so 4096 bytes of real UTF-8 replace exactly those five bytes:
    // the payload is not truncated, not re-encoded and not dropped at a
    // character boundary.
    fixture.adapter.deliver(textRequest(
        target,
        .replace_selected_text,
        .value,
        &big_payload,
        0,
        5,
    ));
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    // One request, one write through the one text seam.
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
    try std.testing.expectEqual(@as(usize, big_payload.len + 6), fixture.last_text_len);
    try std.testing.expectEqualSlices(
        u8,
        &big_payload,
        fixture.last_text[0..big_payload.len],
    );
    try std.testing.expectEqualStrings(" world", fixture.text()[big_payload.len..]);
    // The caret ends after the replacement, which is where the text now is.
    try std.testing.expectEqual(@as(usize, big_payload.len), fixture.last_selection.anchor);
    try std.testing.expectEqual(@as(usize, big_payload.len), fixture.last_selection.focus);

    // A second drain with nothing new replays nothing: a redraw must not be
    // able to apply the same edit a second time.
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
}

test "api-w23 a replacement changes the range the publication held" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_replace);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_replace).?;

    // The publication selected bytes 0..5, which is "hello", and the platform
    // reported that same range. The model is edited there and nowhere else.
    fixture.adapter.deliver(textRequest(
        target,
        .replace_selected_text,
        .value,
        "bye",
        0,
        5,
    ));
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqualStrings("bye world", fixture.text());
    try std.testing.expectEqual(@as(usize, 3), fixture.last_selection.anchor);
    try std.testing.expectEqual(@as(usize, 3), fixture.last_selection.focus);
}

test "api-w23 a replacement resolves against the model's live selection" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_replace);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_replace).?;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // The publication selected bytes 0..5. This request moves the selection
    // somewhere else, and it changes the MODEL: what the model holds now is
    // what the next request is composed against.
    fixture.adapter.deliver(textRequest(
        target,
        .set_text_selection,
        .text_selection,
        "",
        1,
        3,
    ));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(usize, 1), fixture.last_selection.anchor);
    try std.testing.expectEqual(@as(usize, 3), fixture.last_selection.focus);

    // This one carries contents and NO selection, so the span it replaces is
    // the live one: "hXlo world". A composition made from the published
    // selection instead would have written "X world", which is a different
    // model entirely.
    fixture.adapter.deliver(textRequest(
        target,
        .replace_selected_text,
        .value,
        "X",
        0,
        0,
    ));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqualStrings("hXlo world", fixture.text());
    try std.testing.expectEqual(@as(usize, 2), fixture.last_selection.anchor);
    try std.testing.expectEqual(@as(usize, 2), fixture.last_selection.focus);
    try std.testing.expectEqual(@as(u32, 2), fixture.text_writes);
}

test "api-w23 a whole value the model cannot store leaves it untouched" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_replace);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_replace).?;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // The whole run the model holds selected, and then a short whole value
    // over it: the model is left with five bytes and the caret behind them.
    fixture.adapter.deliver(textRequest(
        target,
        .set_text_selection,
        .text_selection,
        "",
        0,
        11,
    ));
    fixture.adapter.deliver(textRequest(
        target,
        .replace_selected_text,
        .value,
        "hello",
        0,
        0,
    ));
    try std.testing.expectEqual(
        @as(usize, 2),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqualStrings("hello", fixture.text());
    try std.testing.expectEqual(@as(u32, 2), fixture.text_writes);

    // The payload fits the ring and still composes a whole value the model
    // cannot hold: five live bytes plus 8190 is 8195 against a capacity of
    // 8192. The request is refused and the model keeps what it had, because
    // a value clipped to what fits is a value no screen reader sent.
    const ring_payload = &@as([model_capacity - 2]u8, @splat('x'));
    fixture.adapter.deliver(textRequest(
        target,
        .replace_selected_text,
        .value,
        ring_payload,
        0,
        0,
    ));
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqualStrings("hello", fixture.text());
    try std.testing.expectEqual(@as(usize, 5), fixture.last_selection.anchor);
    try std.testing.expectEqual(@as(usize, 5), fixture.last_selection.focus);
    try std.testing.expectEqual(@as(u32, 2), fixture.text_writes);

    // And the model's own door refuses it too, with the bytes in hand rather
    // than with a payload the ring would never have carried: the value, the
    // selection and the write count are all exactly what they were.
    const oversized = &@as([model_capacity + 1]u8, @splat('x'));
    try std.testing.expect(!dispatcher.set_text.?(
        dispatcher.context,
        w_replace,
        oversized,
        TextSelection.caret(0),
    ));
    try std.testing.expectEqualStrings("hello", fixture.text());
    try std.testing.expectEqual(@as(usize, 5), fixture.last_selection.anchor);
    try std.testing.expectEqual(@as(usize, 5), fixture.last_selection.focus);
    try std.testing.expectEqual(@as(u32, 2), fixture.text_writes);
}

test "api-w23 a value the shared ring cannot hold is dropped and counted" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_replace);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_replace).?;

    // Two 4096-byte edits fit the ring's 8192-byte payload exactly; a third
    // does not. It is dropped and counted rather than truncated into a text
    // edit the user never made.
    //
    // Each accepted request carries the field's WHOLE new contents, so it is a
    // complete value against whatever the request before it left: the second
    // is exactly as valid as the first, and neither depends on a span the
    // previous insertion already moved. What the third cannot be is a fourth
    // byte the ring has no room for, which is a refusal of the DELIVERY and
    // not an edit the model is asked to make sense of.
    for (0..2) |_| {
        fixture.adapter.deliver(textRequest(
            target,
            .set_value,
            .value,
            &big_payload,
            0,
            0,
        ));
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.adapter.droppedRequests());
    fixture.adapter.deliver(textRequest(
        target,
        .set_value,
        .value,
        &big_payload,
        0,
        0,
    ));
    try std.testing.expectEqual(@as(u32, 1), fixture.adapter.droppedRequests());

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 2),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    // The model holds the payload and nothing else: no half of a third edit
    // behind the ring's refusal, no bytes clipped to make room for one, and
    // the caret where the whole value that is actually there ends.
    try std.testing.expectEqual(@as(u32, 2), fixture.text_writes);
    try std.testing.expectEqual(@as(usize, big_payload.len), fixture.last_text_len);
    try std.testing.expectEqualSlices(u8, &big_payload, fixture.text());
    try std.testing.expectEqual(@as(usize, big_payload.len), fixture.last_selection.anchor);
    try std.testing.expectEqual(@as(usize, big_payload.len), fixture.last_selection.focus);
}

test "api-w23 a named action reaches the model by its own id and no other" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_relations);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_menu).?;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // "Archive" is the action the application gave id 7. The model reaches the
    // same activation path a pointer press takes, once.
    var asked = textRequest(target, .custom_action, .custom_action, "", -1, -1);
    asked.custom_action = 7;
    fixture.adapter.deliver(asked);
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);

    // An id the application never attached is not the closest named action
    // either: it is refused.
    asked.custom_action = 8;
    fixture.adapter.deliver(asked);
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);

    // A node that carries no named action of its own answers none: the action
    // the menu was given is not offered because a sibling elsewhere has it.
    var on_row = textRequest(
        fixture.adapter.nativeIdOf(n_row).?,
        .custom_action,
        .custom_action,
        "",
        -1,
        -1,
    );
    on_row.custom_action = 7;
    fixture.adapter.deliver(on_row);
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);

    // A click on it is the ordinary activation path, and changes the model
    // once through the one seam.
    fixture.adapter.deliver(requestFor(&fixture.adapter, n_row));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 2), fixture.clicks);
}

test "api-w23 a numeric value outside the control's range is refused" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_relations);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const target = fixture.adapter.nativeIdOf(n_slider).?;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    var asked = textRequest(target, .set_value, .numeric_value, "", -1, -1);
    asked.numeric_value = 0.75;
    fixture.adapter.deliver(asked);
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.number_writes);
    try std.testing.expectEqual(@as(f64, 0.75), fixture.last_number);

    // The slider's own range is 0..1. A step past it changes nothing rather
    // than being clamped into a value the model never had.
    asked.numeric_value = 2.0;
    fixture.adapter.deliver(asked);
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.number_writes);
    try std.testing.expectEqual(@as(f64, 0.75), fixture.last_number);
}

test "api-w23 a native id is refused rather than wrapped when the counter runs out" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var first: Snap = undefined;
    try first.init(&tree_save_field);
    defer first.deinit();
    var second: Snap = undefined;
    try second.init(&tree_reorder);
    defer second.deinit();

    // The platform's id space is finite. The counter is set so the tree below
    // takes exactly the last names that fit — starting one lower and the very
    // first publication would run out, which would prove nothing about where
    // the boundary is.
    fixture.adapter.next_native = accessibility.max_native_id - first.get().count() + 1;
    try fixture.publish(first.get(), null);
    const name_field = fixture.adapter.nativeIdOf(n_field).?;
    try std.testing.expect(name_field <= accessibility.max_native_id);
    try std.testing.expectEqual(first.get().count(), fixture.adapter.publishedCount());
    // The names that tree took were the last ones the platform has, so the
    // counter now sits past the end of the space. That is what makes the next
    // name a refusal rather than a name something else is already holding.
    try std.testing.expect(fixture.adapter.next_native > accessibility.max_native_id);

    // ...and the publication that needs a name beyond it is refused, so no id
    // is ever handed out twice. The live routing is untouched.
    try std.testing.expectError(
        error.NativeIdsExhausted,
        fixture.adapter.stage(second.get(), .{}),
    );
    try std.testing.expectEqual(first.get().count(), fixture.adapter.publishedCount());
    try std.testing.expectEqual(n_field, fixture.adapter.resolvePublished(name_field).?);
    try std.testing.expect(fixture.adapter.nativeIdOf(n_extra) == null);
}

test "api-w23 a text node the platform cannot type into offers no text action" {
    const click: u32 = 1 << @backingInt(Action.click);
    const edits: u32 = (1 << @backingInt(Action.replace_selected_text)) |
        (1 << @backingInt(Action.set_text_selection));
    const all = click | edits;

    // Android's framework applies a text edit to a virtual node for real, so
    // the core's own mask goes out unchanged.
    try std.testing.expectEqual(all, accessibility.mobileActionMask(all, false, true, false));
    // A bound control really is typeable, so its node keeps both.
    try std.testing.expectEqual(all, accessibility.mobileActionMask(all, true, false, false));
    // UIKit cannot type into a synthetic element: both text actions are
    // withheld and the action that needs no keyboard stays.
    try std.testing.expectEqual(click, accessibility.mobileActionMask(all, false, false, false));

    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_save_field);
    defer snap.deinit();
    // A build whose platform cannot edit a virtual node.
    fixture.adapter.virtual_text_edits = false;
    try fixture.publish(snap.get(), null);
    const nodes = fixture.adapter.stagedTree().nodes;
    const button = nodes[1];
    const field = nodes[2];
    try std.testing.expect((button.actions & click) != 0);
    try std.testing.expect((field.actions & edits) == 0);
    try std.testing.expect((field.actions & click) == 0);
}

test "api-w23 a read-only node publishes no action that would change its value" {
    const click: u32 = 1 << @backingInt(Action.click);
    const caret: u32 = 1 << @backingInt(Action.set_text_selection);
    const set_value: u32 = 1 << @backingInt(Action.set_value);
    const replace: u32 = 1 << @backingInt(Action.replace_selected_text);
    const edits: u32 = replace | set_value;
    const steps: u32 = (1 << @backingInt(Action.increment)) |
        (1 << @backingInt(Action.decrement));
    const everything = click | caret | edits | steps;

    // The four writes go, whichever platform this is and whether or not a real
    // control is bound: a bound control on a read-only field would type into
    // it and the model would refuse, so the offer is withheld at the edge.
    //
    // Unbound AND on a platform that cannot edit a virtual node, two rules
    // apply at once, so the click is all that is left and the caret above it
    // in `everything` went to CAPABILITY rather than to the strip. The pair
    // below is what still proves the strip took the WRITES in this very shape:
    // the same call with `read_only` clear differs in nothing else.
    try std.testing.expectEqual(
        click,
        accessibility.mobileActionMask(everything, false, false, true),
    );
    try std.testing.expectEqual(
        click | steps | set_value,
        accessibility.mobileActionMask(everything, false, false, false),
    );
    // A bound control, and a platform whose framework edits a virtual node,
    // each keep the caret, so only the four writes go there.
    try std.testing.expectEqual(
        click | caret,
        accessibility.mobileActionMask(everything, true, false, true),
    );
    try std.testing.expectEqual(
        click | caret,
        accessibility.mobileActionMask(everything, false, true, true),
    );
    // A node that is not read-only keeps every action it published, so this
    // is the read-only state and not the platform deciding.
    try std.testing.expectEqual(
        everything,
        accessibility.mobileActionMask(everything, true, true, false),
    );

    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_locked);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const nodes = fixture.adapter.stagedTree().nodes;
    const locked = nodes[1];

    // The state that makes it read-only crosses, so a screen reader announces
    // the control as one it cannot write…
    try std.testing.expect(
        (locked.states & c.NOGUI_MOBILE_STATE_READ_ONLY) != 0,
    );
    // …and its value and range cross too, because announcing them is the point
    // of publishing a read-only control at all.
    try std.testing.expectEqual(@as(i32, 1), locked.has_numeric_value);
    try std.testing.expectEqual(@as(i32, 1), locked.has_numeric_range);
    // Nothing that would change either of them is offered.
    try std.testing.expectEqual(@as(u32, 0), locked.actions & (edits | steps));
    // A click is not a mutation and stays.
    try std.testing.expect((locked.actions & click) != 0);

    // The text case the numeric one cannot show: a caret moves without
    // changing a byte, so the core accepts it on a read-only node and the
    // adapter publishes it. A platform that can put a caret in a synthetic
    // element is stated, so what the mask withholds here is the read-only
    // state and not the platform's typing ability.
    fixture.adapter.virtual_text_edits = true;
    var text_snap: Snap = undefined;
    try text_snap.init(&tree_bound_locked);
    defer text_snap.deinit();
    try fixture.publish(text_snap.get(), null);
    const field = fixture.adapter.stagedTree().nodes[1];
    try std.testing.expect((field.states & c.NOGUI_MOBILE_STATE_READ_ONLY) != 0);
    try std.testing.expect((field.actions & caret) != 0);
    try std.testing.expectEqual(@as(u32, 0), field.actions & edits);
    // The run itself still crosses: a read-only field is read, not driven.
    try std.testing.expectEqual(replace_text.len, field.text_len);
}

test "api-w23 a node the core refuses to act on publishes no named action" {
    const custom: u32 = 1 << @backingInt(Action.custom_action);

    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_locked);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);
    const nodes = fixture.adapter.stagedTree().nodes;
    const off = nodes[2];

    // The disabled state crosses so the reader announces the control as out of
    // reach…
    try std.testing.expect((off.states & c.NOGUI_MOBILE_STATE_DISABLED) != 0);
    // …and the NAMES do not. A named action is the descriptor the reader would
    // hear, and the descriptors are on the snapshot node; the shared encoder's
    // gate is what withholds them, and reading the snapshot's list instead
    // would hand the platform two actions the model refuses, which a screen
    // reader cannot tell from a working one.
    try std.testing.expectEqual(@as(usize, 0), off.custom_actions_len);
    // What the mask KEEPS here is the bit that says this node supports named
    // actions at all, and that is the shared encoder's decision, forwarded
    // unchanged: a disabled node keeps every action it published — the state
    // bit is what announces it as out of reach — and only the descriptors go.
    // Asserting the agreement is what keeps the two adapters from drifting
    // into two answers about which nodes the platform may be offered a name
    // for, and a bare bit offers nothing on its own: neither shim adds a named
    // action from it, both iterate the descriptor list, which is empty.
    try std.testing.expectEqual(custom, off.actions & custom);
    // So the refusal is the model's, and it is end to end: the very id the
    // application attached travels the ordinary seam and changes nothing.
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    var asked = textRequest(
        fixture.adapter.nativeIdOf(n_off).?,
        .custom_action,
        .custom_action,
        "",
        -1,
        -1,
    );
    asked.custom_action = 7;
    fixture.adapter.deliver(asked);
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snap.get(), &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.clicks);

    // The same node with nothing wrong with it publishes both names, so the
    // empty list above is the refusal and not a lost field.
    var live: Snap = undefined;
    try live.init(&tree_relations);
    defer live.deinit();
    try fixture.publish(live.get(), null);
    const menu = fixture.adapter.stagedTree().nodes[3];
    try std.testing.expectEqual(@as(usize, 2), menu.custom_actions_len);
    try std.testing.expectEqual(@as(i32, 7), menu.custom_actions[0].id);
    try std.testing.expectEqualStrings(
        "Archive",
        menu.custom_actions[0].name[0..menu.custom_actions[0].name_len],
    );
    try std.testing.expect((menu.actions & custom) != 0);
}

test "api-w23 a read-only run is not bindable as a platform text input" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_bound_locked);
    defer snap.deinit();
    try fixture.publish(snap.get(), null);

    // The run is published and addressable — a read-only field still takes a
    // caret — but it publishes no contents action, so there is nothing for a
    // real control to drive and binding one is refused rather than accepted
    // and then silently dropping every keystroke.
    const field = fixture.adapter.stagedTree().nodes[1];
    try std.testing.expectEqual(replace_text.len, field.text_len);
    // The caret crosses in characters, which is what the platform counts.
    try std.testing.expectEqual(@as(i64, 0), field.text_selection_anchor);
    try std.testing.expectEqual(@as(i64, 5), field.text_selection_focus);
    try std.testing.expectError(
        error.NotTextInput,
        fixture.adapter.bindTextInput(@ptrFromInt(0x1234), n_locked_field),
    );
    try std.testing.expectEqual(@as(u64, accessibility.no_node), fixture.adapter.boundTextInput());
}

test "api-w23 logical bounds cross the native edge in the platform's own unit" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var snap: Snap = undefined;
    try snap.init(&tree_save_field);
    defer snap.deinit();

    // UIKit's own unit is the point, which is the unit the core publishes in,
    // so a scale of one changes nothing.
    try std.testing.expectEqual(@as(f32, 1), fixture.adapter.scale());
    try fixture.publish(snap.get(), null);
    const logical = snap.nodes[1].bounds;
    const at_one = fixture.adapter.stagedTree().nodes[1].bounds;
    try std.testing.expectApproxEqAbs(@as(f64, @floatCast(logical.x)), at_one.x0, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, @floatCast(logical.w)), at_one.x1 - at_one.x0, 1e-4);

    // Android's node bounds are physical window pixels, so the measured window
    // scale is applied here and only here.
    fixture.adapter.setPixelScale(3);
    try std.testing.expectEqual(@as(f32, 3), fixture.adapter.scale());
    try fixture.publish(snap.get(), null);
    const at_three = fixture.adapter.stagedTree().nodes[1].bounds;
    try std.testing.expectApproxEqAbs(at_one.x0 * 3, at_three.x0, 1e-4);
    try std.testing.expectApproxEqAbs((at_one.x1 - at_one.x0) * 3, at_three.x1 - at_three.x0, 1e-4);

    // A factor that is not a factor is refused rather than published: bounds
    // scaled by a NaN reach the platform as bounds that address nothing.
    fixture.adapter.setPixelScale(0);
    fixture.adapter.setPixelScale(-2);
    fixture.adapter.setPixelScale(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 3), fixture.adapter.scale());
}

test "api-w23 mobile polling never adopts an unpublished SDL candidate" {
    try sdl_session.acquireForTest("dummy");
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try application.Application.init(
        std.testing.allocator,
        &session,
        .{ .video_driver = "dummy" },
    );
    defer host.deinit();
    const handle = try host.openWindow(.{ .title = "candidate", .width = 160, .height = 120 });
    const managed = try host.getWindow(handle);
    var observer = sdl_mobile.Observer.init(&managed.native, .{
        .managed = managed,
        .session = &session,
    });
    defer observer.shutdown();

    try managed.native.startTextInput();
    try observer.poll();
    try std.testing.expect(observer.machine.candidate == null);
    try managed.native.setTextInputArea(.{ .x = 20, .y = 30, .w = 80, .h = 18 }, 24);
    try observer.poll();
    try std.testing.expectEqual([4]f32{ 20, 30, 100, 48 }, observer.machine.candidate.?);
    try std.testing.expectEqual(@as(f32, 24), observer.published_cursor);
}

test "api-w23 mobile candidate stays stale until fresh layout publishes" {
    try sdl_session.acquireForTest("dummy");
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try application.Application.init(
        std.testing.allocator,
        &session,
        .{ .video_driver = "dummy" },
    );
    defer host.deinit();
    const handle = try host.openWindow(.{ .title = "candidate", .width = 160, .height = 120 });
    const managed = try host.getWindow(handle);
    var observer = sdl_mobile.Observer.init(&managed.native, .{
        .managed = managed,
        .session = &session,
    });
    defer observer.shutdown();

    try managed.native.startTextInput();
    try managed.native.setTextInputArea(.{ .x = 20, .y = 30, .w = 80, .h = 18 }, 24);
    try observer.poll();
    observer.candidate_invalidated = true;
    try observer.poll();
    try std.testing.expect(observer.candidateStale());
    try managed.native.setTextInputArea(.{ .x = 28, .y = 42, .w = 80, .h = 18 }, 32);
    try observer.poll();
    try std.testing.expect(!observer.candidateStale());
    try std.testing.expectEqual([4]f32{ 28, 42, 108, 60 }, observer.machine.candidate.?);
    try std.testing.expectEqual(@as(f32, 32), observer.published_cursor);
}

test "api-w23 a republished rectangle is fresh even when the geometry is identical" {
    try sdl_session.acquireForTest("dummy");
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try application.Application.init(
        std.testing.allocator,
        &session,
        .{ .video_driver = "dummy" },
    );
    defer host.deinit();
    const handle = try host.openWindow(.{ .title = "candidate", .width = 160, .height = 120 });
    const managed = try host.getWindow(handle);
    var observer = sdl_mobile.Observer.init(&managed.native, .{
        .managed = managed,
        .session = &session,
    });
    defer observer.shutdown();

    try managed.native.startTextInput();
    const area: nogui.geometry.WindowRect = .{ .x = 20, .y = 30, .w = 80, .h = 18 };
    try managed.native.setTextInputArea(area, 24);
    try observer.poll();
    try std.testing.expectEqual([4]f32{ 20, 30, 100, 48 }, observer.machine.candidate.?);

    // A keyboard move invalidates it, and the layout that answers lands the
    // field back on the same pixels. Nothing about the rectangle changed, so
    // an observer that compared rectangles instead of counting publications
    // would call this stale forever and ask SDL for nothing it did not already
    // hold.
    observer.candidate_invalidated = true;
    try observer.poll();
    try std.testing.expect(observer.candidateStale());
    try managed.native.setTextInputArea(area, 24);
    try observer.poll();
    try std.testing.expect(!observer.candidateStale());
    try std.testing.expectEqual([4]f32{ 20, 30, 100, 48 }, observer.machine.candidate.?);
    // The caret offset survives the whole round trip; a rectangle-only record
    // would anchor the input method at the line box's left edge.
    try std.testing.expectEqual(@as(f32, 24), observer.published_cursor);
}

test "api-w23 a refused candidate publication never clears a stale area" {
    try sdl_session.acquireForTest("dummy");
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try application.Application.init(
        std.testing.allocator,
        &session,
        .{ .video_driver = "dummy" },
    );
    defer host.deinit();
    const handle = try host.openWindow(.{ .title = "candidate", .width = 160, .height = 120 });
    const managed = try host.getWindow(handle);
    var observer = sdl_mobile.Observer.init(&managed.native, .{
        .managed = managed,
        .session = &session,
    });
    defer observer.shutdown();

    try managed.native.startTextInput();
    try managed.native.setTextInputArea(.{ .x = 20, .y = 30, .w = 80, .h = 18 }, 24);
    try observer.poll();
    observer.candidate_invalidated = true;

    // The layout that answers the keyboard is broken, so no rectangle reached
    // the platform. Counting the attempt as a publication would clear the flag
    // and leave the input method anchored to geometry the window refused.
    try std.testing.expectError(error.InvalidCandidateArea, managed.native.setTextInputArea(
        .{ .x = std.math.nan(f32), .y = 30, .w = 80, .h = 18 },
        24,
    ));
    try observer.poll();
    try std.testing.expect(observer.candidateStale());
    try std.testing.expectEqual([4]f32{ 20, 30, 100, 48 }, observer.machine.candidate.?);
    try std.testing.expectEqual(@as(f32, 24), observer.published_cursor);
}
