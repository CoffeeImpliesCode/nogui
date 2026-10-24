//! W21 host contracts: explicit adapter state and capabilities, native-edge
//! coordinate conversion, character-indexed text offsets, the authored modal
//! and list relationships, incremental publishing, main-thread marshaling of
//! native requests, and the window-bound system bell lifetime.
const std = @import("std");
const accessibility = @import("accessibility.zig");
const Application = @import("application.zig").Application;
const sdl_session = @import("sdl_session.zig");
const nogui = @import("nogui");
const semantics = accessibility.semantics;
const contract = nogui.window_contract;

const App = nogui.App;
const Session = nogui.Session;
const DrawCtx = nogui.DrawCtx;
const WidgetId = nogui.WidgetId;
const ComponentKey = nogui.ComponentKey;
const ComponentId = nogui.ComponentId;
const NodeId = semantics.NodeId;
const surface: semantics.Size = .{ .width = 400, .height = 300 };

const Fixture = struct {
    session: Session,
    app: App,
    publisher: semantics.Publisher,
    adapter: accessibility.Adapter,
    io: std.Io,
    threaded: std.Io.Threaded,
    // Scratch handed to `semantics.Scratch`: every byte is written before the
    // string that uses it is read, and a zeroed tail is a valid empty string.
    buffer: [semantics.Scratch.default_capacity]u8 = @splat(0),
    clicks: u32 = 0,
    focus_set: u32 = 0,
    number_writes: u32 = 0,
    text_writes: u32 = 0,
    /// The live text this fixture's model holds, and where its caret or
    /// selection sits. Both the setter and the getter read and write THIS,
    /// which is the whole point: a getter that answered from the published
    /// snapshot would let two edits compose against the same stale bytes.
    model: Model = .{},
    row_selections: u32 = 0,
    last_row_index: usize = 0,
    last_row_key: u64 = 0,

    /// The editable value a reader acts on.
    ///
    /// Fixed capacity on purpose: a model that could grow would accept
    /// every composed value, and the refusal path — the one that must never
    /// clip — would never be reachable. The capacity is the buffer's own
    /// length, never the room left in it.
    const Model = struct {
        bytes: [64]u8 = @splat(0),
        len: usize = 0,
        selection: semantics.TextSelection = semantics.TextSelection.caret(0),

        const capacity: usize = 64;

        /// Whole new contents and the caret that addresses them.
        ///
        /// Overflow refuses BEFORE anything changes: the bytes, the length
        /// and the selection all stay exactly as the last accepted write
        /// left them. Nothing is ever truncated.
        fn write(self: *Model, whole: []const u8, selection: semantics.TextSelection) bool {
            if (whole.len > capacity) return false;
            @memcpy(self.bytes[0..whole.len], whole);
            self.len = whole.len;
            self.selection = selection;
            return true;
        }

        fn value(self: *const Model) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Load the model from outside, the way an app's own text field
        /// starts out.
        fn load(self: *Model, whole: []const u8, selection: semantics.TextSelection) void {
            std.debug.assert(whole.len <= capacity);
            @memcpy(self.bytes[0..whole.len], whole);
            self.len = whole.len;
            self.selection = selection;
        }
    };

    /// Fills every field, so a test only ever reaches a usable `Fixture`
    /// through this; `deinit` tears the whole thing down again. The counters
    /// and scratch buffers are zeroed here rather than relied on from the
    /// struct defaults, because `= undefined` storage is not zeroed.
    fn init(self: *Fixture) !void {
        // SAFETY: every field is assigned below, before this function returns
        // and before any test body reads the fixture.
        self.* = undefined;
        self.buffer = @splat(0);
        self.clicks = 0;
        self.focus_set = 0;
        self.number_writes = 0;
        self.text_writes = 0;
        self.row_selections = 0;
        self.last_row_index = 0;
        self.last_row_key = 0;
        self.model = .{};
        self.session = try Session.init(std.testing.allocator);
        self.app = try App.init(std.testing.allocator, &self.session);
        self.publisher = semantics.Publisher.init(std.testing.allocator);
        self.threaded = .init(std.testing.allocator, .{});
        self.io = self.threaded.io();
        self.adapter.init(std.testing.allocator, self.io);
    }

    fn deinit(self: *Fixture) void {
        self.adapter.deinit();
        self.threaded.deinit();
        self.publisher.deinit();
        self.app.deinit();
        self.session.deinit() catch |err| std.debug.panic(
            "session teardown failed: {s}",
            .{@errorName(err)},
        );
        self.* = undefined;
    }

    fn activate(context: *anyopaque, id: WidgetId) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.app.activate(self.app.tree_ptr.?, id);
        self.clicks += 1;
    }

    fn focusWidget(context: *anyopaque, id: ?WidgetId) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const tree = self.app.tree_ptr orelse return;
        if (id) |target| {
            if (self.app.focus_manager.set(tree, target, self.app.focusObserver())) self.focus_set += 1;
        } else {
            self.app.focus_manager.blur(self.app.focusObserver());
        }
    }

    fn setNumber(context: *anyopaque, id: WidgetId, value: f64) bool {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const tree = self.app.tree_ptr orelse return false;
        const dense = tree.frameNode(id) orelse return false;
        const node = tree.nodeConst(dense) orelse return false;
        switch (node.kind) {
            .slider => |slider| {
                slider.value.* = @floatCast(value);
                self.number_writes += 1;
                return true;
            },
            else => return false,
        }
    }

    fn setText(
        context: *anyopaque,
        _: WidgetId,
        value: ?[]const u8,
        selection: semantics.TextSelection,
    ) bool {
        const self: *Fixture = @ptrCast(@alignCast(context));
        // A null value is a selection-only request: it moves no character
        // byte, so the contents the model last held stay exactly as they
        // were. A non-null value is the field's WHOLE new contents and is
        // written as it is: an empty string clears the model, and bytes
        // that alias the model's own buffer are no exception.
        //
        // A value this fixed model cannot hold is REFUSED with the bytes,
        // the length and the selection all untouched, and leaves no write
        // counted. Clipping it would answer an edit with a different one.
        if (value) |bytes| {
            if (!self.model.write(bytes, selection)) return false;
        } else {
            self.model.selection = selection;
        }
        self.text_writes += 1;
        return true;
    }

    /// The LIVE value, borrowed for the length of one dispatch.
    ///
    /// This is the getter every composition splices into, and it reads the
    /// same buffer the setter writes. It knows nothing about the published
    /// snapshot: a reader's second edit addresses what the first one left,
    /// not the frozen frame the reader was served.
    fn readText(context: *anyopaque, _: WidgetId) ?semantics.TextEditState {
        const self: *Fixture = @ptrCast(@alignCast(context));
        return .{
            .value = self.model.value(),
            .selection = self.model.selection,
            .capacity = Model.capacity,
        };
    }

    fn selectRow(context: *anyopaque, _: WidgetId, index: usize, key: u64) bool {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.row_selections += 1;
        self.last_row_index = index;
        self.last_row_key = key;
        return true;
    }

    fn dispatcher(self: *Fixture) semantics.Dispatcher {
        return .{
            .context = self,
            .activate = activate,
            .focus = focusWidget,
            .set_number = setNumber,
            .set_text = setText,
            .read_text = readText,
            .select_row = selectRow,
        };
    }

    fn scratch(self: *Fixture) semantics.Scratch {
        return .{ .row_name = &self.buffer, .text_value = &self.buffer };
    }
};

/// What the rows container publishes as an action of its own.
const RowAction = enum {
    /// The container names no action of its own.
    none,
    /// The container declares a named action and serves it.
    offered,
    /// The container declares a named action and then states an action set
    /// without the bit that serves one, so the model refuses it.
    refused,
};

const Root = struct {
    fixture: *Fixture,
    lead_label: bool = false,
    checked: bool = false,
    value: f32 = 0.5,
    /// Renders the two text runs: one with a character table, one without.
    show_field: bool = false,
    /// Renders the virtualized list container.
    show_rows: bool = false,
    /// What the rows container publishes as an action of its own.
    row_action: RowAction = .none,
    row_count: usize = 12,
    selected_row: ?usize = 3,
    first_visible: usize = 0,
    /// Text the annotation borrows and the test keeps writing, or null to
    /// publish the fixture's own constant run.
    text: ?*OwnedText = null,

    fn onClick(payload: *anyopaque) void {
        const self: *Root = @ptrCast(@alignCast(payload));
        _ = self;
    }

    pub fn draw(self: *Root, ctx: *DrawCtx) !void {
        _ = try ctx.column(.{ .key = ComponentKey{ .static = "list" }, .gap = 4 });
        defer ctx.pop();
        if (self.lead_label) _ = try ctx.label(.{ .text = "lead" });
        _ = try ctx.button(.{
            .key = ComponentKey{ .static = "save" },
            .label = "Save",
            .on_click = onClick,
        });
        _ = try ctx.checkbox(.{
            .key = ComponentKey{ .static = "wrap" },
            .label = "Wrap",
            .value = &self.checked,
        });
        _ = try ctx.slider(.{
            .key = ComponentKey{ .static = "volume" },
            .label = "Volume",
            .value = &self.value,
            .min = 0,
            .max = 1,
        });
        if (self.show_field) {
            _ = try ctx.column(.{ .key = ComponentKey{ .static = "field" }, .gap = 4 });
            ctx.pop();
            _ = try ctx.column(.{ .key = ComponentKey{ .static = "notes" }, .gap = 4 });
            ctx.pop();
        }
        if (self.show_rows) {
            _ = try ctx.column(.{ .key = ComponentKey{ .static = "rows" }, .gap = 4 });
            ctx.pop();
        }
    }
};

/// "Grüße ✓" is seven characters and eleven UTF-8 bytes. The published
/// byte selection starts INSIDE "ü", which has no character position of its
/// own on the platform side, and ends past the last character, which is the
/// caret position after the whole run.
const multibyte_text: []const u8 = "Grüße ✓";
const multibyte_bytes: usize = 11;
const multibyte_lengths: [7]u8 = .{ 1, 1, 2, 2, 1, 1, 3 };
const multibyte_positions: [7]f32 = .{ 0, 10, 20, 30, 40, 50, 60 };
const multibyte_widths: [7]f32 = .{ 10, 10, 10, 10, 10, 10, 10 };

/// The string a real client typed: twenty-one characters in thirty-five
/// bytes, including two- and three-byte UTF-8 characters.
const wide_text: []const u8 = "W21 Ω αβγ 日本語 ✓ Grüße";

/// The signed descriptor the rows container publishes. The ID crosses the
/// platform edge exactly as the app declared it, and the reader sends that
/// same number back.
const action_add_row: i32 = 1;
/// A descriptor the rows container never declares.
const action_remove_row: i32 = 2;
const row_named_actions = [_]semantics.CustomAction{
    .{ .id = action_add_row, .name = "Add row" },
};

/// Text the annotation borrows and the test keeps writing.
///
/// A host does not hand its annotator a frozen string. A run borrows the
/// model's own bytes, and a native edit rewrites them between the frame that
/// staged the tree and the publish that reads them. Owning those bytes here
/// is what makes that shape reproducible without a window.
const OwnedText = struct {
    bytes: [64]u8 = @splat(0),
    len: usize = 0,
    lengths: [64]u8 = @splat(0),
    characters: usize = 0,
    positions: [64]f32 = @splat(0),
    widths: [64]f32 = @splat(0),
    anchor: usize = 0,
    focus: usize = 0,

    /// The whole new value and the caret the request named.
    ///
    /// The table is measured from the bytes, the way a host measures it, so a
    /// test cannot hand the adapter a table that agrees by accident.
    fn set(self: *OwnedText, contents: []const u8, selection: semantics.TextSelection) void {
        const taken = @min(contents.len, self.bytes.len);
        @memcpy(self.bytes[0..taken], contents[0..taken]);
        self.len = taken;
        self.characters = 0;
        var at: usize = 0;
        while (at < taken) {
            const width = std.unicode.utf8ByteSequenceLength(self.bytes[at]) catch 1;
            const size: usize = @min(@as(usize, width), taken - at);
            self.lengths[self.characters] = @intCast(size);
            self.characters += 1;
            at += size;
        }
        // The zero one past the end is what a host writes, and it is what a
        // stale table can offer the platform as a character of no bytes.
        if (self.characters < self.lengths.len) self.lengths[self.characters] = 0;
        var advance: f32 = 0;
        for (self.positions[0..self.characters], self.widths[0..self.characters]) |*x, *w| {
            x.* = advance;
            w.* = 10;
            advance += 10;
        }
        self.anchor = selection.anchor;
        self.focus = selection.focus;
    }

    fn value(self: *const OwnedText) []const u8 {
        return self.bytes[0..self.len];
    }

    fn table(self: *const OwnedText) []const u8 {
        return self.lengths[0..self.characters];
    }
};

/// Keys of the annotated containers. Annotation is addressed by stable
/// owner, so a subtree that moved still finds its own annotation.
const key_document = "list";
const key_field = "field";
const key_notes = "notes";
const key_rows = "rows";

fn rowKey(_: *anyopaque, index: usize) u64 {
    return @as(u64, @intCast(index)) + 5000;
}

fn rowName(_: *anyopaque, key: u64, index: usize, buf: []u8) usize {
    const written = std.fmt.bufPrint(buf, "row {d} #{d}", .{ index, key }) catch return 0;
    return written.len;
}

const Annotations = struct {
    root: *Root,

    fn annotate(context: *anyopaque, node: *const nogui.WidgetNode, draft: *semantics.Draft) anyerror!void {
        const self: *Annotations = @ptrCast(@alignCast(context));
        // Only a keyed column is a stable semantic owner.
        if (node.kind != .column) return;
        if (self.owns(node, key_document)) return annotateDocument(draft);
        if (self.owns(node, key_field)) return annotateField(self, draft);
        if (self.owns(node, key_notes)) return annotateNotes(draft);
        if (self.owns(node, key_rows)) return self.annotateRows(draft);
    }

    /// True when `node` is the keyed container `key` of the current frame.
    fn owns(self: *Annotations, node: *const nogui.WidgetNode, key: []const u8) bool {
        const id = node.widget_id orelse return false;
        const wanted = self.root.fixture.app.widgetIdForKey(
            ComponentId.root,
            .{ .static = key },
        ) orelse return false;
        return id.eql(wanted);
    }

    /// A virtualized list: the container plus the one row the app has
    /// selected, whatever the row count is.
    fn annotateRows(self: *Annotations, draft: *semantics.Draft) void {
        draft.publish = true;
        draft.name = "Rows";
        draft.list = .{
            .keys = .{ .context = self, .at = rowKey },
            .row_count = self.root.row_count,
            .row_height = 24,
            .selected_index = self.root.selected_row,
            .first_visible = self.root.first_visible,
            .name = rowName,
            .context = self,
        };
        // The container's own named action. A platform sends one descriptor
        // ID back, so the request names an action and not a row. The app
        // states its policy through `Draft.actions`, which REPLACES the set
        // the core built, so an app that means to serve what it declared
        // names the bit again.
        switch (self.root.row_action) {
            .none => {},
            .offered => draft.custom_actions = &row_named_actions,
            .refused => {
                draft.custom_actions = &row_named_actions;
                draft.actions = .{ .focus = true };
            },
        }
    }
};

fn annotateDocument(draft: *semantics.Draft) void {
    draft.publish = true;
    draft.name = "Document";
    draft.text = .{
        .value = "body",
        .selection = .{ .anchor = 0, .focus = 4 },
        .character_lengths = &.{ 1, 1, 1, 1 },
        .character_positions = &.{ 0, 10, 20, 30 },
        .character_widths = &.{ 10, 10, 10, 10 },
    };
}

/// A multi-byte run with a character table, so both directions of the
/// byte/character conversion have something to convert.
///
/// With `Root.text` set the run borrows the bytes that own it instead of a
/// constant, which is what a host whose model keeps being edited hands its
/// annotator.
fn annotateField(self: *Annotations, draft: *semantics.Draft) void {
    draft.publish = true;
    draft.name = "Field";
    const owned = self.root.text orelse {
        draft.text = .{
            .value = multibyte_text,
            .selection = .{ .anchor = 3, .focus = multibyte_bytes },
            .character_lengths = &multibyte_lengths,
            .character_positions = &multibyte_positions,
            .character_widths = &multibyte_widths,
        };
        return;
    };
    draft.text = .{
        .value = owned.value(),
        .selection = .{ .anchor = owned.anchor, .focus = owned.focus },
        .character_lengths = owned.table(),
        .character_positions = owned.positions[0..owned.characters],
        .character_widths = owned.widths[0..owned.characters],
    };
}

/// A run with no character table. The platform has no offsets it could
/// address there, so it must be offered no selection.
fn annotateNotes(draft: *semantics.Draft) void {
    draft.publish = true;
    draft.name = "Notes";
    draft.text = .{ .value = "plain" };
}

fn frame(fixture: *Fixture, annotations: *Annotations) !semantics.NodeId {
    const output = (try fixture.app.handle(.{
        .frame = .{ .tick = @intCast(fixture.app.frame_generation + 1), .time_ms = 0 },
    })) orelse return error.MissingFrameOutput;
    try fixture.publisher.stage(.{
        .tree = output.tree,
        .focus = output.focus,
        .generation = fixture.app.frame_generation,
        .surface = surface,
        .window_name = "Fixture",
        .annotator = .{ .context = annotations, .annotate = Annotations.annotate },
    });
    fixture.publisher.commit();
    return identityOf(fixture, .{ .static = "save" });
}

fn identityOf(fixture: *Fixture, key: ComponentKey) !semantics.NodeId {
    const owner = fixture.app.widgetIdForKey(ComponentId.root, key) orelse
        return error.MissingWidgetIdentity;
    return semantics.nodeId(owner, .self_node);
}

fn sentIds(adapter: *accessibility.Adapter, out: []NodeId) []const NodeId {
    return adapter.lastNodes(out);
}

fn contains(ids: []const NodeId, id: NodeId) bool {
    for (ids) |entry| {
        if (entry == id) return true;
    }
    return false;
}

/// The one row node a list published for its current selection, or null
/// when the list published none.
fn selectedRow(snapshot: *const semantics.Snapshot, list: NodeId) ?*const semantics.Node {
    for (snapshot.nodes) |*entry| {
        const row = entry.row orelse continue;
        if (row.list == list and entry.states.selected == true) return entry;
    }
    return null;
}

test "api-w21 a host without the bridge reports unavailable, not fake support" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const capability = fixture.adapter.capability();
    if (accessibility.linked) {
        // With the bridge the adapter exists but no screen reader has asked
        // for the tree yet, and the bell is still unavailable.
        try std.testing.expect(capability.adapter);
        try std.testing.expect(!capability.screen_reader);
        try std.testing.expect(!capability.bell);
        try std.testing.expect(fixture.adapter.stateOf() == .inactive);
    } else {
        try std.testing.expect(!capability.adapter);
        try std.testing.expect(!capability.screen_reader);
        try std.testing.expect(!capability.bell);
        try std.testing.expect(fixture.adapter.stateOf() == .unavailable);
    }
    try std.testing.expectEqual(accessibility.Bell.unsupported, fixture.adapter.bell());
    try std.testing.expectEqual(@as(u32, 0), fixture.adapter.droppedRequests());
    try std.testing.expect(!fixture.adapter.hasPending());
}

test "api-w21 logical bounds cross the native edge as physical pixels" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const save = try frame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    const logical = snapshot.node(save).?.bounds;
    _ = try fixture.adapter.publish(snapshot, .{});
    const unscaled = fixture.adapter.lastRect(save).?;
    try std.testing.expectApproxEqAbs(@as(f64, @floatCast(logical.x)), unscaled[0], 1e-4);
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatCast(logical.y + logical.h)),
        unscaled[3],
        1e-4,
    );

    fixture.adapter.setScale(2, 3);
    try std.testing.expectEqual(@as(f32, 2), fixture.adapter.scale_x);
    // The scale change is a new coordinate space, so the next publish carries
    // every node again at the new scale.
    const full = try fixture.adapter.publish(snapshot, .{});
    try std.testing.expect(full > 0);
    const scaled = fixture.adapter.lastRect(save).?;
    try std.testing.expectApproxEqAbs(@as(f64, @floatCast(logical.x)) * 2, scaled[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, @floatCast(logical.y)) * 3, scaled[1], 1e-4);
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatCast(logical.x + logical.w)) * 2,
        scaled[2],
        1e-4,
    );

    // A non-positive or non-finite scale is refused, never published.
    fixture.adapter.setScale(0, 1);
    try std.testing.expectEqual(@as(f32, 2), fixture.adapter.scale_x);
    fixture.adapter.setScale(2, 3);
}

test "api-w21 an unchanged tree is not resent and a reorder stays silent" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const save = try frame(&fixture, &annotations);

    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});
    try std.testing.expect(fixture.adapter.lastWasFullTree());

    // An unchanged control is absent from the next delta; its live identity
    // remains in the platform's previously committed tree.
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});
    try std.testing.expect(fixture.adapter.lastRole(save) == null);

    // A node inserted before the controls shifts every rect below it, so the
    // controls are re-sent once, and the inserted label never reaches the
    // platform because it is not a stable owner.
    root.lead_label = true;
    _ = try frame(&fixture, &annotations);
    const wrap = try identityOf(&fixture, .{ .static = "wrap" });
    var ids: [64]NodeId = undefined;
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});
    const after = sentIds(&fixture.adapter, &ids);
    // The inserted label is not a stable owner, so it never reaches the
    // platform. Only the shifted controls are re-sent.
    try std.testing.expect(contains(after, save));
    try std.testing.expect(contains(after, wrap));
}

test "api-w21 a changed control reaches the platform with its ancestors" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});

    // The checkbox state changes, and only the changed control and the
    // hierarchy above it have to be re-sent for a reader to see it.
    root.checked = true;
    _ = try frame(&fixture, &annotations);
    const wrap = try identityOf(&fixture, .{ .static = "wrap" });
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});
    var ids: [64]NodeId = undefined;
    const sent = sentIds(&fixture.adapter, &ids);
    try std.testing.expect(contains(sent, wrap));
    // The changed control reaches the platform carrying its REAL new value,
    // not merely its identity: the reader must be told it is now checked.
    const flags = fixture.adapter.lastFlags(wrap) orelse
        return error.MissingPublishedFlags;
    try std.testing.expect(flags & (@as(u32, 1) << 13) != 0);
    try std.testing.expect(flags & (@as(u32, 1) << 14) == 0);
    // Its required ancestor hierarchy reached the platform too, or a reader
    // could not place the changed control in a tree at all.
    try std.testing.expect(contains(sent, semantics.window_node));
    try std.testing.expect(contains(sent, try identityOf(&fixture, .{ .static = "list" })));
}

test "api-w21 a native request is replayed on the calling thread, not the callback" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const check = try frame(&fixture, &annotations);
    // The platform thread copies the request; the model is untouched.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = check,
        .action = 0, // Click
    }));
    try std.testing.expect(fixture.adapter.hasPending());
    try std.testing.expectEqual(@as(u32, 0), fixture.clicks);
    try std.testing.expect(!root.checked);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    const applied = fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch);
    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);
    try std.testing.expect(!fixture.adapter.hasPending());
    // The ring is drained exactly once.
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch),
    );
}

test "api-w21 a request arriving during replay is retained for the next drain" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .lead_label = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const check = try frame(&fixture, &annotations);
    const document = try findByName(fixture.publisher.snapshot().?, "Document");
    const DuringReplay = struct {
        const Self = @This();

        fixture: *Fixture,
        document: NodeId,
        /// Requests the ring took while a drain was replaying.
        accepted: u32 = 0,

        fn activate(context: *anyopaque, id: WidgetId) void {
            const self: *Self = @ptrCast(@alignCast(context));
            Fixture.activate(self.fixture, id);
            // Queued from INSIDE a drain, on the thread that owns the
            // model. Acceptance is recorded rather than discarded: it is
            // the fact the test reads afterwards to know the ring took it
            // and the next drain has something to replay.
            if (self.fixture.adapter.enqueueRequest(.{
                .id = self.document,
                .action = @backingInt(semantics.Action.replace_selected_text),
                .data = .value,
                .value = "late",
            })) self.accepted += 1;
        }

        fn setText(
            context: *anyopaque,
            id: WidgetId,
            value: ?[]const u8,
            selection: semantics.TextSelection,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return Fixture.setText(self.fixture, id, value, selection);
        }

        fn readText(context: *anyopaque, id: WidgetId) ?semantics.TextEditState {
            const self: *Self = @ptrCast(@alignCast(context));
            return Fixture.readText(self.fixture, id);
        }

        fn focus(context: *anyopaque, id: ?WidgetId) void {
            const self: *Self = @ptrCast(@alignCast(context));
            Fixture.focusWidget(self.fixture, id);
        }
    };
    var replay: DuringReplay = .{ .fixture = &fixture, .document = document.id };
    const dispatcher: semantics.Dispatcher = .{
        .context = &replay,
        .activate = DuringReplay.activate,
        .focus = DuringReplay.focus,
        .set_text = DuringReplay.setText,
        .read_text = DuringReplay.readText,
    };
    try std.testing.expect(fixture.adapter.enqueueRequest(.{ .id = check, .action = 0 }));
    const snapshot = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(@as(usize, 1), fixture.adapter.drain(
        snapshot,
        &dispatcher,
        fixture.scratch(),
    ));
    try std.testing.expect(fixture.adapter.hasPending());
    try std.testing.expectEqual(@as(u32, 1), replay.accepted);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
    try std.testing.expectEqual(@as(usize, 1), fixture.adapter.drain(
        snapshot,
        &dispatcher,
        fixture.scratch(),
    ));
    try std.testing.expectEqualStrings("late", fixture.model.value());
    try std.testing.expect(!fixture.adapter.hasPending());
    try std.testing.expectEqual(@as(u32, 0), fixture.adapter.droppedRequests());
}

test "api-w21 a native value edit is owned by the ring, not by the platform" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    // The annotator publishes the keyed top column as a virtualized list; the
    // second frame is the one that carries the text run.
    root.lead_label = true;
    _ = try frame(&fixture, &annotations);
    const container = try findByName(fixture.publisher.snapshot().?, "Document");
    const container_id = container.id;
    const volume = try identityOf(&fixture, .{ .static = "volume" });

    // The string payload is copied: the caller's buffer dies immediately.
    var scratch_text: [16]u8 = undefined;
    @memcpy(scratch_text[0..7], "replace");
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = container_id,
        .action = 10, // ReplaceSelectedText
        .data = .value,
        .value = scratch_text[0..7],
    }));
    scratch_text = @splat(0);
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = volume,
        .action = 20, // SetValue
        .data = .numeric_value,
        .number = 0.25,
    }));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 2),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch),
    );
    try std.testing.expectEqualStrings("replace", fixture.model.value());
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
    try std.testing.expectEqual(@as(u32, 1), fixture.number_writes);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), root.value, 1e-5);
}

test "api-w21 two positioned edits in one stale frame both land, in order" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var published: OwnedText = .{};
    published.set(multibyte_text, semantics.TextSelection.caret(0));
    var root: Root = .{ .fixture = &fixture, .show_field = true, .text = &published };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const field = try identityOf(&fixture, .{ .static = "field" });

    // The model has moved on since the frame the reader was served: one
    // more character, and no republish. The snapshot still holds seven
    // characters and a seven-entry table.
    const grown = "Grüße ✓✓";
    fixture.model.load(grown, semantics.TextSelection.caret(0));
    try std.testing.expectEqual(@as(usize, 8), try std.unicode.utf8CountCodepoints(grown));
    const published_field = try findByName(fixture.publisher.snapshot().?, "Field");
    try std.testing.expectEqual(@as(usize, 7), published_field.text.?.character_lengths.len);

    // Both endpoints name the node whose text they are positions in, which
    // is the field itself.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .anchor_index = 0,
        .focus_index = 0,
        .anchor_node = field,
        .focus_node = field,
        .value = "日",
    }));
    // The second range is only a position in what the FIRST edit leaves,
    // and index 9 names nothing at all in the seven-character run the
    // reader was served. Resolving against that published table would
    // refuse this edit outright.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .anchor_index = 6,
        .focus_index = 9,
        .anchor_node = field,
        .focus_node = field,
        .value = "",
    }));

    const dispatcher = fixture.dispatcher();
    // ONE drain, and no selection request before it: a positioned edit
    // carries its own range, so nothing has to re-anchor the second one.
    try std.testing.expectEqual(
        @as(usize, 2),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, fixture.scratch()),
    );
    // "Grüße ✓✓" gains a leading "日", then loses the space and both check
    // marks that followed it.
    try std.testing.expectEqualStrings("日Grüße", fixture.model.value());
    try std.testing.expectEqual(@as(u32, 2), fixture.text_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.adapter.droppedRequests());
    // The caret sits where the deleted span began, which is the end of the
    // value that is left.
    try std.testing.expectEqual(@as(usize, 10), fixture.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 10), fixture.model.selection.focus);
}

test "api-w21 a queued positioned edit survives the caller's buffer dying" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var published: OwnedText = .{};
    published.set(multibyte_text, semantics.TextSelection.caret(0));
    var root: Root = .{ .fixture = &fixture, .show_field = true, .text = &published };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const field = try identityOf(&fixture, .{ .static = "field" });
    fixture.model.load(multibyte_text, semantics.TextSelection.caret(0));

    // The replacement bytes are the ring's copy, not the platform's: the
    // caller's buffer is destroyed before the drain ever reads the request.
    // Three Japanese characters are NINE bytes, so the buffer and the slice
    // both carry the whole string; a count written by hand here is what
    // silently truncated this once.
    const insert = "日本語";
    var caller: [16]u8 = undefined;
    @memcpy(caller[0..insert.len], insert);
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .anchor_index = 0,
        .focus_index = 0,
        .anchor_node = field,
        .focus_node = field,
        .value = caller[0..insert.len],
    }));
    // Every byte the platform lent is gone before the drain runs.
    caller = @splat(0);

    const dispatcher = fixture.dispatcher();
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, fixture.scratch()),
    );
    try std.testing.expectEqualStrings("日本語Grüße ✓", fixture.model.value());
    try std.testing.expectEqual(@as(usize, 9), fixture.model.selection.anchor);
}

test "api-w21 an ordinary replacement follows the live edit, not the published frame" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var published: OwnedText = .{};
    published.set(multibyte_text, semantics.TextSelection.caret(0));
    var root: Root = .{ .fixture = &fixture, .show_field = true, .text = &published };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const field = try identityOf(&fixture, .{ .static = "field" });
    // The model is somewhere the published run never described.
    fixture.model.load("live text", .{ .anchor = 5, .focus = 9 });

    const dispatcher = fixture.dispatcher();
    // An ordinary replacement: no range of its own, so it composes into
    // the LIVE value at the LIVE selection — "live " plus the replacement.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .value,
        .value = "LIVE",
    }));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, fixture.scratch()),
    );
    try std.testing.expectEqualStrings("live LIVE", fixture.model.value());
    try std.testing.expectEqual(@as(usize, 9), fixture.model.selection.anchor);
    // Had it composed against the published run it would have replaced
    // bytes 3..11 of "Grüße ✓" and produced something else entirely. It
    // wrote exactly once, into the model it was handed.
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
}

test "api-w21 a positioned edit past the model's capacity is refused, never clipped" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var published: OwnedText = .{};
    published.set(multibyte_text, semantics.TextSelection.caret(0));
    var root: Root = .{ .fixture = &fixture, .show_field = true, .text = &published };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const field = try identityOf(&fixture, .{ .static = "field" });
    fixture.model.load(multibyte_text, semantics.TextSelection.caret(0));

    // The replacement alone exceeds what this fixed model can hold, so the
    // composed value cannot fit either.
    var filler: [Fixture.Model.capacity + 1]u8 = @splat('x');
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .anchor_index = 0,
        .focus_index = 0,
        .anchor_node = field,
        .focus_node = field,
        .value = filler[0..],
    }));
    filler[0] = 'z';

    const dispatcher = fixture.dispatcher();
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, fixture.scratch()),
    );
    // The core sized the composition against the model's real capacity and
    // refused it there, so the setter was never reached at all.
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
    // The value is the whole one it was, not a clipped prefix of a longer
    // one, and the caret never moved.
    try std.testing.expectEqualStrings(multibyte_text, fixture.model.value());
    try std.testing.expectEqual(@as(usize, 0), fixture.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 0), fixture.model.selection.focus);
}

test "api-w21 an oversize positioned payload and a full ring both refuse" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var published: OwnedText = .{};
    published.set(multibyte_text, semantics.TextSelection.caret(0));
    var root: Root = .{ .fixture = &fixture, .show_field = true, .text = &published };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const field = try identityOf(&fixture, .{ .static = "field" });
    const save = try identityOf(&fixture, .{ .static = "save" });
    fixture.model.load(multibyte_text, semantics.TextSelection.caret(0));

    // A payload the ring cannot own at all is refused, and the ring lends
    // its neighbour nothing: the request queued before it still holds its
    // own bytes, not a prefix of this one.
    var oversize: [accessibility.max_payload_bytes + 1]u8 =
        @splat('q');
    try std.testing.expect(!fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .anchor_index = 0,
        .focus_index = 0,
        .anchor_node = field,
        .focus_node = field,
        .value = oversize[0..],
    }));
    oversize[0] = 'r';
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .anchor_index = 0,
        .focus_index = 0,
        .anchor_node = field,
        .focus_node = field,
        .value = "kept",
    }));

    const dispatcher = fixture.dispatcher();
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, fixture.scratch()),
    );
    try std.testing.expectEqualStrings("keptGrüße ✓", fixture.model.value());
    try std.testing.expectEqual(@as(u32, 1), fixture.adapter.droppedRequests());

    // A full ring refuses too, and refuses without counting as applied.
    var accepted: usize = 0;
    for (0..accessibility.max_queue + 4) |_| {
        if (fixture.adapter.enqueueRequest(.{ .id = save, .action = 0 })) accepted += 1;
    }
    try std.testing.expectEqual(accessibility.max_queue, accepted);
    try std.testing.expectEqual(
        @as(usize, accessibility.max_queue),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, fixture.scratch()),
    );
    try std.testing.expectEqual(@as(u32, 5), fixture.adapter.droppedRequests());
}

test "api-w21 a positioned edit whose endpoints name another text is refused" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var published: OwnedText = .{};
    published.set(multibyte_text, semantics.TextSelection.caret(0));
    var root: Root = .{ .fixture = &fixture, .show_field = true, .text = &published };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const field = try identityOf(&fixture, .{ .static = "field" });
    const document = (try findByName(snapshot, "Document")).id;
    fixture.model.load(multibyte_text, semantics.TextSelection.caret(0));

    // Both endpoints naming another text is a splice between two values.
    try std.testing.expect(!fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .anchor_index = 0,
        .focus_index = 0,
        .anchor_node = document,
        .focus_node = document,
        .value = "x",
    }));
    // One endpoint naming another text is the same contradiction.
    try std.testing.expect(!fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.replace_selected_text),
        .data = .text_range,
        .anchor_index = 0,
        .focus_index = 0,
        .anchor_node = field,
        .focus_node = document,
        .value = "x",
    }));
    // A range on an action that is not a replacement is not an edit at all.
    try std.testing.expect(!fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_range,
        .anchor_index = 0,
        .focus_index = 0,
        .anchor_node = field,
        .focus_node = field,
        .value = "x",
    }));

    const dispatcher = fixture.dispatcher();
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snapshot, &dispatcher, fixture.scratch()),
    );
    try std.testing.expectEqual(@as(u32, 3), fixture.adapter.droppedRequests());
    try std.testing.expectEqualStrings(multibyte_text, fixture.model.value());
    try std.testing.expect(!fixture.adapter.hasPending());
}

test "api-w21 a request whose node survived a reorder still reaches the model" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const save = try frame(&fixture, &annotations);

    try std.testing.expect(fixture.adapter.enqueueRequest(.{ .id = save, .action = 0 }));
    // The app commits a new frame before the ring is drained, so the request
    // resolves against a newer generation and its target generation check
    // fails only if the identity is gone.
    root.lead_label = true;
    _ = try frame(&fixture, &annotations);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    _ = fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch);
    // The identity survived the reorder, so the action still applied once.
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);
}

test "api-w21 the ring refuses overflow instead of growing without bound" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const save = try frame(&fixture, &annotations);

    // The first `max_queue` requests are taken and every later one is
    // refused: acceptance is what the platform is told, and it stops being
    // true exactly when the ring is full.
    var accepted: usize = 0;
    for (0..accessibility.max_queue + 8) |_| {
        if (fixture.adapter.enqueueRequest(.{ .id = save, .action = 0 })) accepted += 1;
    }
    try std.testing.expectEqual(accessibility.max_queue, accepted);
    try std.testing.expectEqual(@as(u32, 8), fixture.adapter.droppedRequests());

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, accessibility.max_queue),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, @intCast(accessibility.max_queue)), fixture.clicks);
    // Draining clears the ring, so a later burst is served again.
    try std.testing.expectEqual(@as(u32, 8), fixture.adapter.droppedRequests());
}

test "api-w21 an unmodelled native action is dropped rather than guessed" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const save = try frame(&fixture, &annotations);

    try std.testing.expect(fixture.adapter.enqueueRequest(.{ .id = save, .action = 200 }));
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.clicks);
}

fn findByName(snapshot: *const semantics.Snapshot, name: []const u8) !*const semantics.Node {
    for (snapshot.nodes) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return error.MissingSemanticNode;
}

test "api-w21 text crosses the edge in characters and refuses a selection it cannot address" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_field = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const field = try identityOf(&fixture, .{ .static = "field" });
    const notes = try identityOf(&fixture, .{ .static = "notes" });
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});

    // The published byte selection starts inside a character and ends past
    // the last one. On the platform both name character positions: the
    // caret at the end of the run is the character AFTER the run.
    const selection = fixture.adapter.lastTextSelection(field).?;
    try std.testing.expectEqual(@as(usize, 2), selection.anchor);
    try std.testing.expectEqual(@as(usize, 7), selection.focus);
    try std.testing.expectEqual(@as(usize, 7), selection.cursor);
    // A run with no character table has no offsets the platform could
    // address, so the bridge publishes no selection for it at all.
    try std.testing.expect(fixture.adapter.lastTextSelection(notes) == null);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // The platform counts characters and the model counts bytes. A reversed
    // selection keeps its direction on the way in.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 6,
        .focus_index = 1,
    }));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(usize, 8), fixture.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 1), fixture.model.selection.focus);

    // A character index past the end of the table is refused, not clamped:
    // the model is never edited at a guessed offset.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 8,
        .focus_index = 1,
    }));
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
    try std.testing.expectEqual(@as(usize, 8), fixture.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 1), fixture.model.selection.focus);
}

test "api-w21 a request for a row the current tree dropped changes nothing" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_rows = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const list = (try findByName(fixture.publisher.snapshot().?, "Rows")).id;
    const published = selectedRow(fixture.publisher.snapshot().?, list) orelse
        return error.MissingSelectedRow;
    const gone = published.id;

    root.selected_row = 7;
    root.first_visible = 7;
    _ = try frame(&fixture, &annotations);
    const live = selectedRow(fixture.publisher.snapshot().?, list) orelse
        return error.MissingSelectedRow;
    try std.testing.expect(live.id != gone);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // The platform thread still holds the row it was given. Replaying it on
    // the main thread reaches no seam at all.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = gone,
        .action = @backingInt(semantics.Action.click),
    }));
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.row_selections);

    // The row the tree does publish still selects through the list owner.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = live.id,
        .action = @backingInt(semantics.Action.click),
    }));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(fixture.publisher.snapshot().?, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.row_selections);
    try std.testing.expectEqual(@as(usize, 7), fixture.last_row_index);
    try std.testing.expectEqual(@as(u64, 5007), fixture.last_row_key);
}

test "api-w21 a named action on the list owner activates it, a row request does not" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_rows = true, .row_action = .offered };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const owner = try findByName(snapshot, "Rows");
    try std.testing.expectEqual(@as(usize, 1), owner.custom_actions.len);
    try std.testing.expectEqual(action_add_row, owner.custom_actions[0].id);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // A named action carries the descriptor the reader picked, not a row
    // position, so it activates the container that owns the rows. One
    // activation reaches the model, and no row moves.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = owner.id,
        .action = @backingInt(semantics.Action.custom_action),
        .data = .custom_action,
        .custom_action = action_add_row,
    }));
    const named = fixture.adapter.drain(snapshot, &dispatcher, scratch);
    try std.testing.expectEqual(@as(usize, 1), named);
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);
    try std.testing.expectEqual(@as(u32, 0), fixture.row_selections);

    // A descriptor the container never declared reaches no model. The owner
    // is not activated in its place.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = owner.id,
        .action = @backingInt(semantics.Action.custom_action),
        .data = .custom_action,
        .custom_action = action_remove_row,
    }));
    const unknown = fixture.adapter.drain(snapshot, &dispatcher, scratch);
    try std.testing.expectEqual(@as(usize, 0), unknown);
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);
    try std.testing.expectEqual(@as(u32, 0), fixture.row_selections);

    // A request that names a row is that row, and it selects the logical
    // position it addressed through the same owner. The container itself
    // takes no activation.
    switch (snapshot.dispatch(.{
        .id = owner.id,
        .action = .custom_action,
        .generation = snapshot.generation,
        .row_index = 7,
    }, &dispatcher, scratch)) {
        .applied => |target| switch (target) {
            .row => |row| try std.testing.expectEqual(@as(usize, 7), row.index),
            .widget => return error.NativeActionHitWidget,
        },
        .ignored => return error.NativeActionWasIgnored,
    }
    try std.testing.expectEqual(@as(u32, 1), fixture.row_selections);
    try std.testing.expectEqual(@as(usize, 7), fixture.last_row_index);
    try std.testing.expectEqual(@as(u64, 5007), fixture.last_row_key);
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);
}

test "api-w21 an app that states its own action set refuses the action it named" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_rows = true, .row_action = .refused };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const owner = try findByName(snapshot, "Rows");
    // The app named an action and then stated an action set without the bit
    // that serves one. `Draft.actions` replaces the set rather than adding to
    // it, so the node keeps a descriptor and loses the way to act on it.
    try std.testing.expectEqual(@as(usize, 1), owner.custom_actions.len);
    try std.testing.expect(!owner.actions.has(.custom_action));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    // The model refuses the wording the node still carries, so a request
    // made from it changes nothing at all.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = owner.id,
        .action = @backingInt(semantics.Action.custom_action),
        .data = .custom_action,
        .custom_action = action_add_row,
    }));
    const applied = fixture.adapter.drain(snapshot, &dispatcher, scratch);
    try std.testing.expectEqual(@as(usize, 0), applied);
    try std.testing.expectEqual(@as(u32, 0), fixture.clicks);
    try std.testing.expectEqual(@as(u32, 0), fixture.row_selections);
}

test "api-w21 the bridge is handed the field's characters as a child run" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_field = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Field");
    const run = field.text_run orelse return error.MissingTextRun;
    _ = try fixture.adapter.publish(snapshot, .{});

    var sent: [128]NodeId = undefined;
    try std.testing.expect(contains(sentIds(&fixture.adapter, &sent), run));
    // The run is what a platform offers text through: without it a screen
    // reader is handed an empty box however much the app typed into it.
    try std.testing.expectEqual(
        @as(u8, @backingInt(semantics.Role.text_run)),
        fixture.adapter.lastRole(run).?,
    );
    try std.testing.expectEqualStrings(multibyte_text, fixture.adapter.lastValue(run).?);
    try std.testing.expectEqualStrings(multibyte_text, fixture.adapter.lastValue(field.id).?);
    try std.testing.expectEqualSlices(
        u8,
        &multibyte_lengths,
        fixture.adapter.lastCharacterLengths(run).?,
    );
    // The published caret is a position in the run's characters, so the
    // platform reads it back through the node it can actually address. The
    // run's own copy names the run, which keeps the two the same position
    // instead of two nodes' worth of geometry.
    try std.testing.expectEqual(run, fixture.adapter.lastTextSelectionOwner(field.id).?);
    try std.testing.expectEqual(run, fixture.adapter.lastTextSelectionOwner(run).?);
    try std.testing.expectEqual(@as(usize, 2), fixture.adapter.lastTextSelection(run).?.anchor);
    try std.testing.expectEqual(@as(usize, 7), fixture.adapter.lastTextSelection(run).?.focus);
    // The run carries no action of its own: the field is what a client acts
    // on, and the run is only where it reads the characters.
    try std.testing.expectEqual(@as(u32, 0), fixture.adapter.lastActions(run).?);
}

/// What `accesskit_consumer` needs from a published text node.
///
/// The consumer walks a run's character table once for every character of the
/// run's value and unwraps the value of every run its ranges cross, so a
/// value the table cannot address, a table that does not add up to the value,
/// and an entry that advances no byte all end the adapter's event loop rather
/// than answering the reader.
fn expectAddressableText(value: []const u8, lengths: []const u8) !void {
    try std.testing.expect(std.unicode.utf8ValidateSlice(value));
    try std.testing.expectEqual(try std.unicode.utf8CountCodepoints(value), lengths.len);
    var total: usize = 0;
    for (lengths) |length| {
        try std.testing.expect(length >= 1);
        total += length;
    }
    try std.testing.expectEqual(value.len, total);
}

/// One published text node, checked as the platform will read it.
fn expectAddressable(adapter: *accessibility.Adapter, id: NodeId) !void {
    const value = adapter.lastValue(id) orelse return error.MissingPublishedValue;
    const lengths = adapter.lastCharacterLengths(id) orelse return error.MissingPublishedTable;
    try expectAddressableText(value, lengths);
    const selection = adapter.lastTextSelection(id) orelse return error.MissingPublishedSelection;
    try std.testing.expect(selection.anchor <= lengths.len);
    try std.testing.expect(selection.focus <= lengths.len);
}

// A native action can change the model before an already committed snapshot
// crosses the platform edge. The snapshot must retain the complete value and
// metadata from its own frame, including an explicitly empty value.
test "api-w21 every publish pairs a value with the table that describes it" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var text: OwnedText = .{};
    text.set(multibyte_text, .{ .anchor = 4, .focus = 4 });
    var root: Root = .{ .fixture = &fixture, .show_field = true, .text = &text };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const staged = fixture.publisher.snapshot().?;
    const field = try findByName(staged, "Field");
    const run = field.text_run orelse return error.MissingTextRun;

    // A model edit cannot rewrite the already committed frame's text.
    // Both the field and its run must still publish the complete old value.
    text.set(wide_text, .{ .anchor = wide_text.len, .focus = wide_text.len });
    _ = try fixture.adapter.publish(staged, .{});
    try expectAddressable(&fixture.adapter, run);
    try expectAddressable(&fixture.adapter, field.id);
    try std.testing.expectEqualStrings(multibyte_text, fixture.adapter.lastValue(run).?);
    try std.testing.expectEqualStrings(multibyte_text, fixture.adapter.lastValue(field.id).?);
    try std.testing.expectEqualSlices(u8, &multibyte_lengths, fixture.adapter.lastCharacterLengths(run).?);

    // The next committed frame owns the complete Unicode value. Clearing the
    // model does not change that frame; only a new frame publishes the clear.
    _ = try frame(&fixture, &annotations);
    text.set("", .{ .anchor = 0, .focus = 0 });
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});
    try expectAddressable(&fixture.adapter, run);
    try expectAddressable(&fixture.adapter, field.id);
    try std.testing.expectEqualStrings(wide_text, fixture.adapter.lastValue(run).?);
    try std.testing.expectEqualStrings(wide_text, fixture.adapter.lastValue(field.id).?);
    _ = try frame(&fixture, &annotations);
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});
    try expectAddressable(&fixture.adapter, run);
    try expectAddressable(&fixture.adapter, field.id);
    try std.testing.expectEqualStrings("", fixture.adapter.lastValue(run).?);
    try std.testing.expectEqualStrings("", fixture.adapter.lastValue(field.id).?);

    // The restore is staged like any other frame, so this publish carries a
    // value and a table that were measured from the same bytes and is not
    // shortened by the publish at all.
    _ = try frame(&fixture, &annotations);
    text.set(multibyte_text, .{ .anchor = multibyte_bytes, .focus = multibyte_bytes });
    _ = try frame(&fixture, &annotations);
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});
    try expectAddressable(&fixture.adapter, run);
    try expectAddressable(&fixture.adapter, field.id);
    try std.testing.expectEqualStrings(multibyte_text, fixture.adapter.lastValue(run).?);
    try std.testing.expectEqualSlices(
        u8,
        &multibyte_lengths,
        fixture.adapter.lastCharacterLengths(run).?,
    );
    try std.testing.expectEqual(
        @as(u8, @backingInt(semantics.Role.text_run)),
        fixture.adapter.lastRole(run).?,
    );
}

// A cleared field is a PRESENT EMPTY text value with a collapsed caret, not an
// absent value and not a run the platform cannot address. The consumer pinned
// to this contract answers a text selection with -1 when a node published
// none, so a field the user just emptied still has to carry the one position
// it has: character 0.
test "api-w21 a cleared field is published empty with a collapsed caret" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var text: OwnedText = .{};
    text.set(multibyte_text, .{ .anchor = multibyte_bytes, .focus = multibyte_bytes });
    var root: Root = .{ .fixture = &fixture, .show_field = true, .text = &text };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const before = try identityOf(&fixture, .{ .static = "field" });

    // The clear and the frame that publishes it are two moments, and only the
    // second one changes what the platform is told.
    text.set("", .{ .anchor = 0, .focus = 0 });
    _ = try frame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Field");
    const run = field.text_run orelse return error.MissingTextRun;

    // Clearing changes the value, never the node: a screen reader keeps
    // addressing the same field and the same run.
    try std.testing.expectEqual(before, field.id);
    _ = try fixture.adapter.publish(snapshot, .{});
    for ([_]NodeId{ field.id, run }) |id| {
        // The empty string is published as the value, and the table that
        // describes it is empty rather than absent: this field HAS text.
        try std.testing.expectEqualStrings("", fixture.adapter.lastValue(id).?);
        const lengths = fixture.adapter.lastCharacterLengths(id) orelse
            return error.MissingPublishedTable;
        try std.testing.expectEqual(@as(usize, 0), lengths.len);
        // The caret after a clear sits at character 0, and a platform that
        // asks where it is has to be told.
        const selection = fixture.adapter.lastTextSelection(id) orelse
            return error.MissingPublishedSelection;
        try std.testing.expectEqual(@as(usize, 0), selection.anchor);
        try std.testing.expectEqual(@as(usize, 0), selection.focus);
        try std.testing.expectEqual(@as(usize, 0), selection.cursor);
        try std.testing.expectEqual(run, fixture.adapter.lastTextSelectionOwner(id).?);
    }
    try std.testing.expectEqual(
        @as(u8, @backingInt(semantics.Role.text_run)),
        fixture.adapter.lastRole(run).?,
    );
}

// Presence is the pointer, not the length: a node that carries no value
// publishes none at all, a node that carries a NUMBER publishes no string,
// and a numeric zero is still a value the reader is told about. Without
// this, an absent value and the empty string of a cleared field read the
// same at the platform edge.
test "api-w21 a node publishes a value only where it carries one" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .value = 0 };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    _ = try fixture.adapter.publish(fixture.publisher.snapshot().?, .{});

    const save = try identityOf(&fixture, .{ .static = "save" });
    const volume = try identityOf(&fixture, .{ .static = "volume" });

    // A button carries nothing, so it publishes nothing at all.
    try std.testing.expect(fixture.adapter.lastValue(save) == null);
    try std.testing.expect(fixture.adapter.lastNumericValue(save) == null);
    // A slider publishes a number and no string, and its zero is the number
    // the app holds rather than the absence of one.
    try std.testing.expect(fixture.adapter.lastValue(volume) == null);
    const numeric = fixture.adapter.lastNumericValue(volume) orelse
        return error.MissingNumericValue;
    try std.testing.expectEqual(@as(f64, 0), numeric);
}

test "api-w21 a native selection names the run it came from and reaches the model" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_field = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    _ = try frame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Field");
    const run = field.text_run.?;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // What a platform really sends: the TARGET is the field the client used
    // and each endpoint names the text its offset is a position in. The
    // offset stays a character index and is converted on the way in.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field.id,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 6,
        .focus_index = 1,
        .anchor_node = run,
        .focus_node = run,
    }));
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snapshot, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(usize, 8), fixture.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 1), fixture.model.selection.focus);
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);

    // The other field's own run, on a request aimed at this one. A selection
    // is an edit to ONE text, so this is refused rather than applied to
    // whichever text happened to resolve first.
    const document = try findByName(snapshot, "Document");
    const document_run = document.text_run orelse return error.MissingTextRun;
    try std.testing.expect(document_run != run);
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field.id,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 2,
        .focus_index = 2,
        .anchor_node = document_run,
        .focus_node = document_run,
    }));
    // One endpoint in each field is the same refusal: no text owns both.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field.id,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 2,
        .focus_index = 2,
        .anchor_node = run,
        .focus_node = document_run,
    }));
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snapshot, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);

    // An endpoint naming a node this tree dropped resolves to nothing, so
    // the request is refused instead of applied at a guessed offset.
    try std.testing.expect(fixture.adapter.enqueueRequest(.{
        .id = field.id,
        .action = @backingInt(semantics.Action.set_text_selection),
        .data = .text_selection,
        .anchor_index = 1,
        .focus_index = 2,
        .anchor_node = semantics.no_node + 12345,
        .focus_node = run,
    }));
    try std.testing.expectEqual(
        @as(usize, 0),
        fixture.adapter.drain(snapshot, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
}

test "api-w21 a native request outlives a frame that changed nothing it named" {
    // SAFETY: `Fixture.init` assigns every field before any test reads it,
    // and zeroes the counters and scratch buffers itself.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const save = try frame(&fixture, &annotations);
    const first = fixture.publisher.snapshot().?.generation;

    // No accessibility bus reports which frame a client's tree came from,
    // so a request that arrives after an unrelated repaint must still reach
    // the model. A control that really went away stops resolving instead.
    root.checked = true;
    _ = try frame(&fixture, &annotations);
    try std.testing.expect(fixture.publisher.snapshot().?.generation > first);

    try std.testing.expect(fixture.adapter.enqueueRequest(.{ .id = save, .action = 0 }));
    root.checked = false;
    _ = try frame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    try std.testing.expect(snapshot.node(save) != null);
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try std.testing.expectEqual(
        @as(usize, 1),
        fixture.adapter.drain(snapshot, &dispatcher, scratch),
    );
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);
}

test "api-w21 native action masks preserve sparse action codes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var adapter: accessibility.Adapter = undefined;
    adapter.initWithoutBridge(std.testing.allocator, threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    try index.put(std.testing.allocator, semantics.window_node, 0);
    var nodes = [_]semantics.Node{.{
        .id = semantics.window_node,
        .parent = semantics.no_node,
        .role = .window,
    }};
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = semantics.no_node,
        .nodes = &nodes,
        .index = &index,
    };
    inline for (std.meta.tags(semantics.Action)) |action| {
        nodes[0].actions = .{};
        nodes[0].actions.enable(action);
        const wire = try adapter.encodeFullSnapshot(&snapshot, .{});
        try std.testing.expectEqual(
            @as(u32, 1) << @intCast(@backingInt(action)),
            wire.nodes[0].actions,
        );
    }
}

// ── The bell boundary ───────────────────────

/// One real Application with one real SDL window and one real adapter.
///
/// A bell binding is a lifetime claim about a window, so every answer that
/// matters here — a reused slot, an adapter that outlives the host, an
/// observer released early, a call from another thread — exists only in the
/// real lifetime. A stand-in window answers none of them.
const BellHost = struct {
    session: nogui.Session,
    host: Application,
    adapter: accessibility.Adapter,
    io_impl: std.Io.Threaded,
    io: std.Io,
    /// False once a test destroyed the host itself, so `deinit` releases only
    /// what is still whole.
    host_live: bool,

    fn init(self: *BellHost) !void {
        // SAFETY: every field is assigned below, before this function returns
        // and before any test body reads the fixture.
        self.* = undefined;
        // One SDL driver for the whole test binary, held until the process
        // exits; see sdl_session.zig.
        try sdl_session.acquireForTest("dummy");
        self.io_impl = .init(std.testing.allocator, .{});
        // If anything below fails, the Io this fixture handed out is released
        // on the way out rather than left running with nothing owning it.
        errdefer self.io_impl.deinit();
        self.io = self.io_impl.io();
        self.session = try nogui.Session.init(std.testing.allocator);
        errdefer self.session.deinit() catch |err| {
            std.debug.panic("bell fixture initialization cleanup failed: {s}", .{@errorName(err)});
        };
        self.adapter.init(std.testing.allocator, self.io);
        errdefer self.adapter.deinit();
        self.host = try Application.init(std.testing.allocator, &self.session, .{
            .video_driver = "dummy",
        });
        self.host_live = true;
    }

    /// The adapter goes FIRST. It may still be bound to a window this host
    /// owns, and that binding has to be released while the host is whole.
    fn deinit(self: *BellHost) void {
        self.adapter.deinit();
        if (self.host_live) self.host.deinit();
        self.io_impl.deinit();
        self.session.deinit() catch |err| {
            std.debug.panic("bell fixture Session retirement failed: {s}", .{@errorName(err)});
        };
        self.* = undefined;
    }

    fn open(self: *BellHost, title: [:0]const u8) !contract.WindowHandle {
        return self.host.openWindow(.{ .title = title, .width = 120, .height = 96 });
    }
};

test "api-w21 one window takes one bell observer and a second bind is refused" {
    var host: BellHost = undefined;
    try host.init();
    defer host.deinit();

    const handle = try host.open("bell-single-owner");
    try host.adapter.bindSystemBell(&host.host, handle);
    // The dummy video driver has no platform bell, so a live binding is still
    // an honest "unsupported" and the capability stays false. A binding that
    // claimed it could ring would be the lie this host exists to avoid.
    try std.testing.expectEqual(accessibility.Bell.unsupported, host.adapter.bell());
    try std.testing.expect(!host.adapter.capability().bell);

    // One adapter holds one live binding as well: a second bind is refused
    // rather than quietly replacing the observer the host already has.
    try std.testing.expectError(
        error.BellAlreadyBound,
        host.adapter.bindSystemBell(&host.host, handle),
    );

    var second: accessibility.Adapter = undefined;
    second.init(std.testing.allocator, host.io);
    defer second.deinit();
    try std.testing.expectError(
        error.BellObserverBound,
        second.bindSystemBell(&host.host, handle),
    );
    // The refusal did not displace the owner: its binding is untouched.
    try std.testing.expectEqual(accessibility.Bell.unsupported, host.adapter.bell());
    // And the refused adapter is still unbound, so it rings nothing.
    try std.testing.expectEqual(accessibility.Bell.unsupported, second.bell());
}

test "api-w21 a closed window reports itself closed and its reused slot is stale" {
    var host: BellHost = undefined;
    try host.init();
    defer host.deinit();

    const first = try host.open("bell-closed");
    try host.adapter.bindSystemBell(&host.host, first);
    try std.testing.expect(try host.host.closeWindow(first));

    // Closing the window notified the observer, so the adapter no longer
    // names a host it has no window into.
    try std.testing.expectEqual(accessibility.Bell.window_closed, host.adapter.bell());
    try std.testing.expect(!host.adapter.capability().bell);

    // The slot went back to the free list, so the next window lands in it.
    const reused = try host.open("bell-reused");
    try std.testing.expectEqual(first.slot, reused.slot);
    try std.testing.expect(reused.generation != first.generation);

    // The retired handle is refused by the host instead of resolving to the
    // window that happens to occupy its slot now.
    try std.testing.expectError(
        error.StaleWindow,
        host.adapter.bindSystemBell(&host.host, first),
    );
    try std.testing.expectEqual(accessibility.Bell.window_closed, host.adapter.bell());

    // The live handle in the reused slot names a different window, which this
    // adapter has no claim on, and the dead binding is not a permanent one:
    // the same adapter may take the new window.
    var next: accessibility.Adapter = undefined;
    next.init(std.testing.allocator, host.io);
    defer next.deinit();
    try next.bindSystemBell(&host.host, reused);
    try std.testing.expectEqual(accessibility.Bell.unsupported, next.bell());
}

test "api-w21 an adapter outliving its application reports the window it lost" {
    var host: BellHost = undefined;
    try host.init();
    defer host.deinit();

    const handle = try host.open("bell-outlives");
    var adapter: accessibility.Adapter = undefined;
    adapter.init(std.testing.allocator, host.io);
    try adapter.bindSystemBell(&host.host, handle);

    // The host goes first. Its teardown destroys every window it manages, and
    // destroying a window notifies the observer while the binding is whole.
    host.host.deinit();
    host.host_live = false;

    // The adapter outlived the host it borrowed, so every answer it still
    // gives is about the window that closed rather than about freed memory.
    try std.testing.expectEqual(accessibility.Bell.window_closed, adapter.bell());
    try std.testing.expect(!adapter.capability().bell);
    // Releasing a binding whose host is gone touches no host.
    try adapter.unbindSystemBell();
    adapter.deinit();
}

test "api-w21 unbind and deinit both hand the window's observer back" {
    var host: BellHost = undefined;
    try host.init();
    defer host.deinit();

    const handle = try host.open("bell-released");
    var first: accessibility.Adapter = undefined;
    first.init(std.testing.allocator, host.io);
    try first.bindSystemBell(&host.host, handle);
    // An explicit release hands the window back while it is still open.
    try first.unbindSystemBell();
    try std.testing.expectEqual(accessibility.Bell.unsupported, first.bell());
    first.deinit();

    var second: accessibility.Adapter = undefined;
    second.init(std.testing.allocator, host.io);
    var second_live = true;
    defer if (second_live) second.deinit();
    try second.bindSystemBell(&host.host, handle);

    // `second` owns the window, so a third adapter is refused until the one
    // that owns it is destroyed.
    var third: accessibility.Adapter = undefined;
    third.init(std.testing.allocator, host.io);
    defer third.deinit();
    try std.testing.expectError(
        error.BellObserverBound,
        third.bindSystemBell(&host.host, handle),
    );
    second.deinit();
    second_live = false;
    try third.bindSystemBell(&host.host, handle);
    try std.testing.expectEqual(accessibility.Bell.unsupported, third.bell());
}

test "api-w21 a ring from another thread is refused before the host is read" {
    var host: BellHost = undefined;
    try host.init();
    defer host.deinit();

    const handle = try host.open("bell-thread");
    try host.adapter.bindSystemBell(&host.host, handle);

    const Ring = struct {
        fn run(answer: *accessibility.Bell, adapter: *accessibility.Adapter) void {
            answer.* = adapter.bell();
        }
    };
    var off_thread: accessibility.Bell = .rung;
    const ring_thread = try std.Thread.spawn(.{}, Ring.run, .{ &off_thread, &host.adapter });
    ring_thread.join();
    // The binding belongs to the thread that made it, so a request from
    // anywhere else is answered without reading the host at all.
    try std.testing.expectEqual(accessibility.Bell.wrong_thread, off_thread);
    // The same call on the owning thread is a real request, answered by the
    // platform rather than refused.
    try std.testing.expectEqual(accessibility.Bell.unsupported, host.adapter.bell());

    // The host refuses a bind from another thread too: the provider it would
    // build is native work, and native work belongs to the window's thread.
    const Attempt = struct {
        // A local declaration cannot name itself, so the method says `Self`.
        const Self = @This();

        adapter: *accessibility.Adapter,
        outcome: ?anyerror = null,

        fn run(self: *Self, application: *Application, window: contract.WindowHandle) void {
            self.adapter.bindSystemBell(application, window) catch |err| {
                self.outcome = err;
            };
        }
    };
    var foreign: accessibility.Adapter = undefined;
    foreign.init(std.testing.allocator, host.io);
    defer foreign.deinit();
    var attempt: Attempt = .{ .adapter = &foreign };
    const bind_thread = try std.Thread.spawn(.{}, Attempt.run, .{
        &attempt,
        &host.host,
        handle,
    });
    bind_thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.WrongThread), attempt.outcome);
    // The refused bind left nothing behind: the window still has one owner.
    try std.testing.expectError(
        error.BellObserverBound,
        foreign.bindSystemBell(&host.host, handle),
    );
}

test "api-w21 a release refused for its thread keeps the binding the window names" {
    var host: BellHost = undefined;
    try host.init();
    defer host.deinit();

    const handle = try host.open("bell-refused-release");
    try host.adapter.bindSystemBell(&host.host, handle);

    // A worker that asks to release is refused. The window still names this
    // adapter as its observer, so a release that quietly succeeded there would
    // leave the host holding a callback into memory nobody owns any more.
    const Release = struct {
        // A local declaration cannot name itself, so the method says `Self`.
        const Self = @This();

        adapter: *accessibility.Adapter,
        outcome: ?anyerror = null,

        fn run(self: *Self) void {
            self.adapter.unbindSystemBell() catch |err| {
                self.outcome = err;
            };
        }
    };
    var release: Release = .{ .adapter = &host.adapter };
    const release_thread = try std.Thread.spawn(.{}, Release.run, .{&release});
    release_thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.WrongThread), release.outcome);

    // The refusal left the observer exactly where it was, so a second adapter
    // is still turned away: this one never let go of the window.
    var contender: accessibility.Adapter = undefined;
    contender.init(std.testing.allocator, host.io);
    defer contender.deinit();
    try std.testing.expectError(
        error.BellObserverBound,
        contender.bindSystemBell(&host.host, handle),
    );

    // The thread that made the binding is the one that may end it, and it
    // really does: the window has no observer left to refuse anybody.
    try host.adapter.unbindSystemBell();
    try contender.bindSystemBell(&host.host, handle);
    try std.testing.expectEqual(accessibility.Bell.unsupported, contender.bell());
}
