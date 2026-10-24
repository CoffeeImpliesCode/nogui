//! W21 core contracts: stable semantic identity, atomic publishing, the
//! hidden/disabled/focus policy, authored modality, the virtualized list
//! relationship, and native actions that travel the ordinary
//! activation/edit/focus path exactly once — including ordinary and
//! positioned text edits, which are composed against the live model and
//! never against a published run.
const std = @import("std");
const semantics = @import("semantics.zig");
const App = @import("app.zig").App;
const Session = @import("session.zig").Session;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const WidgetId = @import("id.zig").WidgetId;
const widget = @import("widget.zig");
const WidgetNode = widget.WidgetNode;
const ComponentKey = @import("key.zig").ComponentKey;
const ComponentId = @import("key.zig").ComponentId;
const style = @import("style.zig");
const visualBorderRect = widget.visualBorderRect;
const element = @import("element.zig");

const NodeId = semantics.NodeId;
const surface: semantics.Size = .{ .width = 320, .height = 480 };

/// The live characters a text request reads and writes.
///
/// The whole value lives in ONE fixed buffer, which is what makes the bound
/// real: a write that does not fit is refused whole. The field never clips
/// what it was handed and never cuts a character in half to make room,
/// because a client that typed forty characters and read back thirty-nine
/// has been lied to about the app's own model.
const TextModel = struct {
    /// Whole-value bytes the field accepts. `readText` states this same
    /// number to the core, so the bound the core checks and the bound this
    /// buffer enforces can never drift apart.
    const capacity: usize = 64;

    // SAFETY: only the first `len` bytes were ever written.
    bytes: [capacity]u8 = undefined,
    len: usize = 0,
    selection: semantics.TextSelection = semantics.TextSelection.caret(0),
    /// Whole writes the field itself refused, so a test can tell a refusal
    /// that reached the model from one the core answered on its own.
    refusals: u32 = 0,

    fn value(self: *const TextModel) []const u8 {
        return self.bytes[0..self.len];
    }

    /// The live state a test states for the field before it dispatches
    /// anything. The characters and the caret are the ones the field
    /// PUBLISHES, so the first edit is proved against the model rather than
    /// against a frozen frame that happens to agree with it.
    fn seed(self: *TextModel, initial: []const u8, selection: semantics.TextSelection) !void {
        if (initial.len > capacity) return error.FieldTooNarrow;
        @memcpy(self.bytes[0..initial.len], initial);
        self.len = initial.len;
        self.selection = selection;
        self.refusals = 0;
    }

    /// The whole-value write the ordinary text path performs.
    ///
    /// A value the field cannot hold is refused BEFORE anything changes, so
    /// the composition that was cancelled and the caret that was about to
    /// move are both left exactly where the client found them.
    fn write(self: *TextModel, next: []const u8, selection: semantics.TextSelection) bool {
        if (next.len > capacity) {
            self.refusals += 1;
            return false;
        }
        @memcpy(self.bytes[0..next.len], next);
        self.len = next.len;
        self.selection = selection;
        return true;
    }

    /// The selection-only write, which moves no character byte.
    fn moveCaret(self: *TextModel, selection: semantics.TextSelection) void {
        self.selection = selection;
    }
};

/// One App plus the semantics publisher and the seams a native action uses.
/// The App keeps a `*Session`, so the fixture is initialized in place.
const Fixture = struct {
    // SAFETY: init assigns every handle before any read.
    session: Session = undefined,
    // SAFETY: init assigns every handle before any read.
    app: App = undefined,
    // SAFETY: init assigns every handle before any read.
    publisher: semantics.Publisher = undefined,
    // SAFETY: the publisher writes the prefix it later reads through scratch().
    buffer: [semantics.Scratch.default_capacity]u8 = undefined,
    /// The live field a text request reads and writes.
    text: TextModel = .{},
    /// The widget `readText` answers for, or null when no field is bound.
    text_owner: ?WidgetId = null,
    /// Seam call counters. The model lives in the Root view.
    activations: u32 = 0,
    focus_set: u32 = 0,
    focus_cleared: u32 = 0,
    number_writes: u32 = 0,
    /// Every delivery the text path makes, whole contents or selection only.
    text_writes: u32 = 0,
    /// The deliveries that actually changed the characters: one applied edit
    /// is one of these, and a refused request is none of them.
    whole_writes: u32 = 0,
    row_selections: u32 = 0,
    last_number: f64 = 0,
    last_row_index: usize = 0,
    last_row_key: u64 = 0,
    // SAFETY: written by a row selection; read only after one was recorded.
    last_row_owner: WidgetId = undefined,

    fn init(self: *Fixture) !void {
        // Reset every counter to its declared default; the handles keep their
        // `undefined` defaults and are rebuilt below. The caller declares the
        // fixture uninitialized so the App keeps a stable `*Session`.
        self.* = .{};
        self.session = try Session.init(std.testing.allocator);
        self.app = try App.init(std.testing.allocator, &self.session);
        self.publisher = semantics.Publisher.init(std.testing.allocator);
    }

    fn deinit(self: *Fixture) void {
        self.publisher.deinit();
        self.app.deinit();
        self.session.deinit() catch |err|
            std.debug.panic("fixture session deinit: {s}", .{@errorName(err)});
        self.* = undefined;
    }

    fn activate(context: *anyopaque, id: WidgetId) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        // The ordinary activation path: the same call pointer release makes.
        self.app.activate(self.app.tree_ptr.?, id);
        self.activations += 1;
    }

    fn focusWidget(context: *anyopaque, id: ?WidgetId) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const tree = self.app.tree_ptr orelse return;
        if (id) |target| {
            if (self.app.focus_manager.set(tree, target, self.app.focusObserver())) self.focus_set += 1;
        } else {
            self.app.focus_manager.blur(self.app.focusObserver());
            self.focus_cleared += 1;
        }
    }

    fn setNumber(context: *anyopaque, id: WidgetId, value: f64) bool {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const tree = self.app.tree_ptr orelse return false;
        const dense = tree.frameNode(id) orelse return false;
        const node = tree.nodeConst(dense) orelse return false;
        switch (node.kind) {
            .slider => |slider| {
                const bounded = std.math.clamp(
                    value,
                    @as(f64, @floatCast(slider.min)),
                    @as(f64, @floatCast(slider.max)),
                );
                slider.value.* = @floatCast(bounded);
                self.number_writes += 1;
                self.last_number = bounded;
                return true;
            },
            else => return false,
        }
    }

    fn readNumber(context: *anyopaque, id: WidgetId) ?f64 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const tree = self.app.tree_ptr orelse return null;
        const dense = tree.frameNode(id) orelse return null;
        const node = tree.nodeConst(dense) orelse return null;
        return switch (node.kind) {
            .slider => |slider| @floatCast(slider.value.*),
            else => null,
        };
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
        // written as it is: an empty string clears the model, and bytes that
        // alias the model's own buffer are no exception. A value the fixed
        // buffer cannot hold is refused BEFORE any byte moves, so the
        // cancellation and the caret that were on their way are both left
        // untouched.
        if (value) |bytes| {
            if (!self.text.write(bytes, selection)) return false;
            self.whole_writes += 1;
        } else {
            self.text.moveCaret(selection);
        }
        self.text_writes += 1;
        return true;
    }

    fn readText(context: *anyopaque, id: WidgetId) ?semantics.TextEditState {
        const self: *Fixture = @ptrCast(@alignCast(context));
        // One widget owns the field, so the getter answers for that widget
        // and for nothing else. A request against a control that owns no
        // field is told so, rather than handed another control's bytes.
        const owner = self.text_owner orelse return null;
        if (!owner.eql(id)) return null;
        return .{
            .value = self.text.value(),
            .selection = self.text.selection,
            .capacity = TextModel.capacity,
        };
    }

    fn selectRow(context: *anyopaque, id: WidgetId, index: usize, key: u64) bool {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.row_selections += 1;
        // The list's own live owner, so a test can tell a resolved row from
        // a remembered one.
        self.last_row_owner = id;
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
            .read_number = readNumber,
            .set_text = setText,
            .read_text = readText,
            .select_row = selectRow,
        };
    }

    fn scratch(self: *Fixture) semantics.Scratch {
        return .{ .row_name = &self.buffer, .text_value = &self.buffer };
    }

    /// A scratch whose composition room is `bytes`, so a test can reach the
    /// caller's own buffer limit without writing four kilobytes of text.
    fn boundedScratch(self: *Fixture, bytes: usize) semantics.Scratch {
        return .{ .row_name = &self.buffer, .text_value = self.buffer[0..bytes] };
    }
};

const Root = struct {
    fixture: *Fixture,
    /// A node inserted before the controls shifts every dense frame id.
    lead_label: bool = false,
    /// Removes the second button, so its identity must stop resolving.
    show_second: bool = true,
    /// Hides the second button through an ancestor, not through `disabled`.
    hide_second: bool = false,
    /// Publishes the first button as AUTHORED hidden. It is the only annotated
    /// node the built-in policy calls focusable, so it is the one that carries
    /// the hidden contract and a focusable state at the same time.
    hide_first: bool = false,
    disable_first: bool = false,
    checked: bool = false,
    value: f32 = 0.25,
    row_count: usize = 1_000_000,
    selected_row: ?usize = 7,
    /// Attaches the text and virtualized list annotations to the container.
    annotate_container: bool = true,
    clicks: u32 = 0,
    /// Publishes the list as visually hidden: announced, but unreachable.
    hide_list: bool = false,
    /// Renders the two authored dialog columns.
    show_dialogs: bool = false,
    /// The authored modality of the `modal` dialog column. Nothing infers
    /// it, so dropping the flag is the only way back to an ordinary dialog.
    modal_dialog: bool = true,
    /// Hides the modal dialog through the widget tree.
    hide_modal: bool = false,
    /// Renders the custom panel whose keyed column hosts a second, smaller
    /// list. The panel is the only fixture container that can be disabled.
    show_panel: bool = false,
    /// Disables the panel itself, so its whole subtree is disabled too.
    disable_panel: bool = false,
    tray_row_count: usize = 5,
    /// Renders a second, independent text field, so a selection can name an
    /// endpoint that belongs to another control.
    show_notes: bool = false,
    /// Renders a text field the app reads but never edits, so the platform
    /// is told the truth about a field that refuses every contents change.
    show_readonly: bool = false,
    /// Publishes that field with an authored action set that forces the
    /// contents actions back on, so the core's own refusal is what stops a
    /// write rather than the missing bit.
    force_readonly_actions: bool = false,
    /// Publishes the ordinary slider as READ ONLY. A read-only control is
    /// announced with its value and range and refuses every change to them,
    /// so a screen reader can read it and cannot write it.
    readonly_slider: bool = false,
    /// Publishes that slider with an authored action set that forces the
    /// numeric contents actions back on, so the core's own refusal is what
    /// stops a write rather than the missing bit.
    force_readonly_slider_actions: bool = false,
    /// Publishes the annotated text field with an authored action set of its
    /// own, so the core's own additions cannot be observed on it.
    author_text_actions: bool = false,
    /// Scrolls the annotated list, so the rows its viewport shows are not
    /// the rows the app selects.
    list_first_visible: usize = 0,
    tray_selected: ?usize = 2,

    fn onClick(payload: *anyopaque) void {
        const self: *Root = @ptrCast(@alignCast(payload));
        self.clicks += 1;
    }

    pub fn draw(self: *Root, ctx: *DrawCtx) !void {
        _ = try ctx.column(.{ .key = ComponentKey{ .static = "list" }, .gap = 4 });
        defer ctx.pop();
        if (self.lead_label) _ = try ctx.label(.{ .text = "lead" });
        _ = try ctx.button(.{
            .key = ComponentKey{ .static = "first" },
            .label = "First",
            .disabled = self.disable_first,
            .on_click = onClick,
        });
        if (self.show_second) {
            // `defer ctx.pop()` would close the container before the button
            // is built, so the hidden wrapper is popped explicitly.
            if (self.hide_second) {
                _ = try ctx.column(.{ .visibility = style.Visibility.hidden });
            }
            _ = try ctx.button(.{
                .key = ComponentKey{ .static = "second" },
                .label = "Second",
                .on_click = onClick,
            });
            if (self.hide_second) ctx.pop();
        }
        _ = try ctx.checkbox(.{
            .key = ComponentKey{ .static = "check" },
            .label = "Check",
            .value = &self.checked,
        });
        _ = try ctx.slider(.{
            .key = ComponentKey{ .static = "volume" },
            .label = "Volume",
            .value = &self.value,
            .min = 0,
            .max = 1,
        });
        if (self.show_notes) {
            _ = try ctx.column(.{ .key = ComponentKey{ .static = "notes" }, .gap = 4 });
            ctx.pop();
        }
        if (self.show_readonly) {
            _ = try ctx.column(.{ .key = ComponentKey{ .static = "readonly" }, .gap = 4 });
            ctx.pop();
        }
        if (self.show_dialogs) {
            // Two dialogs of the same shape: only the annotation differs.
            _ = try ctx.column(.{
                .key = ComponentKey{ .static = "modal" },
                .gap = 4,
                .visibility = if (self.hide_modal)
                    style.Visibility.hidden
                else
                    style.Visibility.visible,
            });
            _ = try ctx.button(.{
                .key = ComponentKey{ .static = "confirm" },
                .label = "Confirm",
                .on_click = onClick,
            });
            ctx.pop();
            _ = try ctx.column(.{ .key = ComponentKey{ .static = "plain" }, .gap = 4 });
            ctx.pop();
        }
        if (self.show_panel) {
            // The panel is the fixture's disabled ANCESTOR. Only a container
            // that accepts `.disabled` can be one, and the list lives on a
            // real keyed column inside it, not on the panel.
            _ = try ctx.elementContainer(Panel, .{}, .{
                .key = ComponentKey{ .static = "panel" },
                .disabled = self.disable_panel,
                .width = 200,
                .height = 80,
            });
            _ = try ctx.column(.{ .key = ComponentKey{ .static = "tray" }, .gap = 4 });
            _ = try ctx.button(.{
                .key = ComponentKey{ .static = "panel_button" },
                .label = "Panel",
                .on_click = onClick,
            });
            ctx.pop();
            ctx.pop();
        }
    }
};

/// A custom element used ONLY as a disabled ancestor. `DrawCtx.column` has
/// no `.disabled` option, so an element container is the one container kind
/// that can disable a subtree; nothing is annotated on it.
const Panel = struct {
    pub const PhaseState = struct {};

    pub fn measure(_: *const Panel, input: element.MeasureInput) element.Error!widget.Size {
        return .{
            .width = input.known_dimensions.width orelse 200,
            .height = input.known_dimensions.height orelse 80,
        };
    }

    pub fn semantics(
        _: *const Panel,
        _: *PhaseState,
        _: element.Geometry,
    ) element.Error!?element.Semantic {
        return .{ .role = .group, .label = "Panel" };
    }
};

/// Stable key of the list's row at `index`.
///
/// `swap_keys` exchanges the keys of two adjacent rows, so the selected
/// key RELOCATES while every other row keeps the identity it had.
fn rowKey(context: *anyopaque, index: usize) u64 {
    const self: *Annotations = @ptrCast(@alignCast(context));
    if (!self.swap_keys) return @as(u64, @intCast(index)) + 1000;
    if (index == self.swap_at) return @as(u64, @intCast(index + 1)) + 1000;
    if (index == self.swap_at + 1) return @as(u64, @intCast(index - 1)) + 1000;
    return @as(u64, @intCast(index)) + 1000;
}

/// The tray's rows live in their own key space, so a change to one list
/// never moves a row of the other.
fn trayKey(_: *anyopaque, index: usize) u64 {
    return @as(u64, @intCast(index)) + 5000;
}

fn rowName(_: *anyopaque, key: u64, index: usize, buf: []u8) usize {
    const written = std.fmt.bufPrint(buf, "row {d} #{d}", .{ index, key }) catch return 0;
    return written.len;
}

/// Keys of the annotated nodes. Annotation is addressed by stable owner, so a
/// subtree that moved still finds its own annotation.
const key_list = "list";
const key_modal = "modal";
const key_plain = "plain";
const key_tray = "tray";
const key_notes = "notes";
const key_readonly = "readonly";
const key_volume = "volume";
/// The one FOCUSABLE annotated node: a real button.
const key_first = "first";

const Annotations = struct {
    root: *Root,
    text_value: []const u8 = "hello world",
    /// Fails the frame once the Nth annotated node is reached.
    fail_after: ?usize = null,
    seen: usize = 0,
    /// Relocates one key of the list's key space by one position.
    swap_keys: bool = false,
    /// Row whose key is exchanged with its successor.
    swap_at: usize = 0,

    fn annotate(context: *anyopaque, node: *const WidgetNode, draft: *semantics.Draft) anyerror!void {
        const self: *Annotations = @ptrCast(@alignCast(context));
        if (self.owns(node, key_list)) {
            if (self.fail_after) |limit| {
                if (self.seen >= limit) return error.IntentionalSemanticFailure;
                self.seen += 1;
            }
            return self.annotateList(draft);
        }
        if (self.owns(node, key_tray)) return self.annotateTray(draft);
        if (self.owns(node, key_modal)) return annotateDialog(draft, self.root.modal_dialog);
        if (self.owns(node, key_plain)) return annotateDialog(draft, false);
        if (self.owns(node, key_notes)) return annotateNotes(draft);
        if (self.owns(node, key_readonly)) return annotateReadOnly(self.root, draft);
        if (self.owns(node, key_volume)) return annotateReadOnlySlider(self.root, draft);
        // Gated: every other case keeps the built-in action set of this button.
        if (self.root.hide_first and self.owns(node, key_first)) return annotateHiddenButton(draft);
    }

    /// True when `node` is the keyed container `key` of the current frame.
    fn owns(self: *Annotations, node: *const WidgetNode, key: []const u8) bool {
        const id = node.widget_id orelse return false;
        const app = &self.root.fixture.app;
        const wanted = app.widgetIdForKey(ComponentId.root, .{ .static = key }) orelse
            return false;
        return id.eql(wanted);
    }

    fn annotateList(self: *Annotations, draft: *semantics.Draft) void {
        if (!self.root.annotate_container) return;
        draft.publish = true;
        draft.name = "Library";
        draft.description = "A virtualized list";
        draft.shortcut = "Ctrl+L";
        draft.text = .{
            .value = self.text_value,
            .selection = .{ .anchor = 0, .focus = 5 },
            .character_lengths = &.{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
            .character_positions = &.{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80 },
            .character_widths = &.{ 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8 },
        };
        draft.list = .{
            .keys = .{ .context = self, .at = rowKey },
            .row_count = self.root.row_count,
            .row_height = 24,
            .selected_index = self.root.selected_row,
            .first_visible = self.root.list_first_visible,
            .name = rowName,
            .context = self,
        };
        // The only way to publish a node nobody can act on: it is announced
        // as hidden, so it carries no action and no selection.
        if (self.root.hide_list) draft.hidden = true;
        // An authored set REPLACES what the core added, so this field keeps
        // exactly the actions the app stated, whole-value `set_value`
        // included.
        if (self.root.author_text_actions) {
            var actions: semantics.ActionSet = .{};
            actions.enable(.custom_action);
            actions.enable(.set_text_selection);
            actions.enable(.replace_selected_text);
            draft.actions = actions;
        }
    }

    /// A real keyed column publishes the second, smaller list, so a forced
    /// container under a disabled ancestor is compared with the same
    /// container when nothing disables it.
    fn annotateTray(self: *Annotations, draft: *semantics.Draft) void {
        draft.publish = true;
        draft.name = "Tray";
        draft.list = .{
            .keys = .{ .context = self, .at = trayKey },
            .row_count = self.root.tray_row_count,
            .row_height = 24,
            .selected_index = self.root.tray_selected,
            .name = rowName,
            .context = self,
        };
    }
};

/// A second, independent field. A selection is an edit to ONE text, so a
/// test can only prove an endpoint is checked against its owner when there is
/// another text to name.
fn annotateNotes(draft: *semantics.Draft) void {
    draft.publish = true;
    draft.name = "Notes";
    draft.role = .text_input;
    draft.text = .{
        .value = "second field",
        .selection = .{ .anchor = 6, .focus = 6 },
        .character_lengths = &@as([12]u8, @splat(1)),
        .character_positions = &@as([12]f32, @splat(0)),
        .character_widths = &@as([12]f32, @splat(7)),
    };
}

/// A field whose app reads the characters and refuses every edit to them.
///
/// The platform is told so: a screen reader offered an EditableText the app
/// will refuse is a client that types into a field and watches the characters
/// come back. `force_readonly_actions` puts the contents actions back into
/// the authored set, so the refusal has to come from the core and not from
/// the bit being absent.
fn annotateReadOnly(root: *Root, draft: *semantics.Draft) void {
    draft.publish = true;
    draft.name = "Reference";
    draft.role = .text_input;
    draft.read_only = true;
    draft.text = .{
        .value = "fixed value",
        .selection = .{ .anchor = 2, .focus = 2 },
        .character_lengths = &@as([11]u8, @splat(1)),
        .character_positions = &@as([11]f32, @splat(0)),
        .character_widths = &@as([11]f32, @splat(6)),
    };
    if (!root.force_readonly_actions) return;
    var actions: semantics.ActionSet = .{};
    actions.enable(.set_text_selection);
    actions.enable(.replace_selected_text);
    actions.enable(.set_value);
    draft.actions = actions;
}

/// An ordinary slider the app reads but never writes, published as READ ONLY.
///
/// The built-in numeric policy is left exactly as it is: a slider is still a
/// focusable control that advertises `set_value`, `increment` and
/// `decrement`, because `read_only` is additive and takes nothing away. So
/// the refusal has to come from the core and not from a missing bit, which is
/// what makes this the numeric twin of `annotateReadOnly`.
/// `force_readonly_slider_actions` states the contents bits as the app's own
/// set, so they are advertised whatever the built-in policy decided.
fn annotateReadOnlySlider(root: *Root, draft: *semantics.Draft) void {
    if (!root.readonly_slider) return;
    draft.read_only = true;
    if (!root.force_readonly_slider_actions) return;
    var actions: semantics.ActionSet = .{};
    actions.enable(.set_value);
    actions.enable(.increment);
    actions.enable(.decrement);
    draft.actions = actions;
}

/// Modality is authored: `Draft.modal` is the only source of it, so a
/// dialog whose flag the app did not set is an ordinary one.
fn annotateDialog(draft: *semantics.Draft, modal: bool) void {
    draft.publish = true;
    draft.role = .dialog;
    if (modal) draft.modal = true;
}

/// The one authored annotation that lands on a node the built-in policy calls
/// FOCUSABLE: a button. It is what makes the hidden contract observable, since
/// every other annotated node in the fixture is a plain container.
fn annotateHiddenButton(draft: *semantics.Draft) void {
    draft.hidden = true;
}

fn stageFrame(fixture: *Fixture, annotations: *Annotations) !void {
    annotations.seen = 0;
    try stage(fixture, annotations);
    fixture.publisher.commit();
}

fn stage(fixture: *Fixture, annotations: *Annotations) !void {
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
}

fn identityOf(fixture: *Fixture, key: ComponentKey) !struct { id: NodeId, owner: WidgetId } {
    const owner = fixture.app.widgetIdForKey(ComponentId.root, key) orelse
        return error.MissingWidgetIdentity;
    const snapshot = fixture.publisher.snapshot() orelse return error.MissingSnapshot;
    const identity = semantics.nodeId(owner, .self_node);
    if (snapshot.node(identity) == null) return error.MissingSemanticNode;
    return .{ .id = identity, .owner = owner };
}

/// The identity a live widget WOULD publish, whether or not the current
/// snapshot contains it. A hidden subtree still has live widgets, so a
/// request computed against an earlier frame names a resolvable owner that
/// no published node stands for.
fn identityOfWidget(fixture: *Fixture, key: ComponentKey) !struct { id: NodeId, owner: WidgetId } {
    const owner = fixture.app.widgetIdForKey(ComponentId.root, key) orelse
        return error.MissingWidgetIdentity;
    return .{ .id = semantics.nodeId(owner, .self_node), .owner = owner };
}

/// Give the fixture a live field: the characters and the caret the field
/// PUBLISHES, bound to the widget that owns them.
///
/// A text edit is composed against the model's own bytes, so a test states
/// that state here instead of trusting a frozen frame to stand in for a
/// model that never existed.
fn seedField(
    fixture: *Fixture,
    key: ComponentKey,
    initial: []const u8,
    selection: semantics.TextSelection,
) !void {
    const owner = fixture.app.widgetIdForKey(ComponentId.root, key) orelse
        return error.MissingWidgetIdentity;
    fixture.text_owner = owner;
    try fixture.text.seed(initial, selection);
}

fn findByName(snapshot: *const semantics.Snapshot, name: []const u8) !*const semantics.Node {
    for (snapshot.nodes) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return error.MissingSemanticNode;
}

/// The row node a list published as its current selection, or null when the
/// list published none. A list publishes its whole visible window, so the
/// marked row is what identifies the selection, not the first row found.
fn selectedRow(snapshot: *const semantics.Snapshot, list: NodeId) ?*const semantics.Node {
    for (snapshot.nodes) |*entry| {
        const row = entry.row orelse continue;
        if (row.list != list or !entry.states.selected) continue;
        return entry;
    }
    return null;
}

/// How many row nodes `list` published in all, visible or not.
fn publishedRows(snapshot: *const semantics.Snapshot, list: NodeId) usize {
    var rows: usize = 0;
    for (snapshot.nodes) |entry| {
        const row = entry.row orelse continue;
        if (row.list != list) continue;
        rows += 1;
    }
    return rows;
}

/// True when any published row node belongs to `list`.
fn hasRow(snapshot: *const semantics.Snapshot, list: NodeId) bool {
    for (snapshot.nodes) |entry| {
        const row = entry.row orelse continue;
        if (row.list == list) return true;
    }
    return false;
}

/// The row a request resolved to, failing the test on any other target.
fn expectRow(outcome: semantics.Outcome) !semantics.VirtualRow {
    return switch (outcome) {
        .applied => |target| switch (target) {
            .row => |row| row,
            .widget => return error.NativeActionHitWidget,
        },
        .ignored => return error.NativeActionWasIgnored,
    };
}

fn expectIgnored(outcome: semantics.Outcome, expected: semantics.Failure) !void {
    try std.testing.expectEqual(expected, switch (outcome) {
        .ignored => |reason| reason,
        .applied => return error.NativeActionWasApplied,
    });
}

fn expectWidget(outcome: semantics.Outcome, expected: WidgetId) !void {
    try std.testing.expect(expected.eql(switch (outcome) {
        .applied => |target| switch (target) {
            .widget => |id| id,
            .row => return error.NativeActionHitVirtualRow,
        },
        .ignored => return error.NativeActionWasIgnored,
    }));
}

test "api-w21 reordering unrelated nodes keeps their semantic identity" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const first = try identityOf(&fixture, .{ .static = "first" });
    const second = try identityOf(&fixture, .{ .static = "second" });
    try std.testing.expect(first.id != second.id);

    // A node inserted before the controls shifts every dense frame id.
    root.lead_label = true;
    try stageFrame(&fixture, &annotations);

    const after_first = try identityOf(&fixture, .{ .static = "first" });
    const after_second = try identityOf(&fixture, .{ .static = "second" });
    try std.testing.expectEqual(first.id, after_first.id);
    try std.testing.expectEqual(second.id, after_second.id);
    try std.testing.expectEqual(first.owner, after_first.owner);
    try std.testing.expectEqual(second.owner, after_second.owner);
}

test "api-w21 a removed control stops resolving for a request on a live tree" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const second = try identityOf(&fixture, .{ .static = "second" });
    const first = try identityOf(&fixture, .{ .static = "first" });

    root.show_second = false;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    try std.testing.expect(snapshot.node(second.id) == null);
    try std.testing.expect(snapshot.node(first.id) != null);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = second.id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unknown_node);
    try std.testing.expectEqual(@as(u32, 0), fixture.activations);
}

test "api-w21 a request computed against an older generation is stale" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const first = try identityOf(&fixture, .{ .static = "first" });
    const stale_generation = fixture.publisher.snapshot().?.generation;

    root.lead_label = true;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    try std.testing.expect(snapshot.generation > stale_generation);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = first.id,
        .action = .click,
        .generation = stale_generation,
    }, &dispatcher, scratch), .stale_generation);
    try std.testing.expectEqual(@as(u32, 0), fixture.activations);
}

test "api-w21 a control hidden through an ancestor is not published at all" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const second = try identityOf(&fixture, .{ .static = "second" });
    const first = try identityOf(&fixture, .{ .static = "first" });

    root.hide_second = true;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    try std.testing.expect(snapshot.node(second.id) == null);

    // The published control that remains still reaches the model.
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectWidget(snapshot.dispatch(.{
        .id = first.id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), first.owner);
    try std.testing.expectEqual(@as(u32, 1), fixture.activations);
    try std.testing.expectEqual(@as(u32, 1), root.clicks);
}

test "api-w21 a disabled control announces disabled and refuses every action" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const first = try identityOf(&fixture, .{ .static = "first" });

    root.disable_first = true;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const entry = snapshot.node(first.id).?;
    try std.testing.expect(entry.states.disabled);
    try std.testing.expect(!entry.states.focusable);
    try std.testing.expect(!entry.isInteractive());

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = first.id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .disabled);
    try std.testing.expectEqual(@as(u32, 0), fixture.activations);
    try std.testing.expectEqual(@as(u32, 0), root.clicks);
}

test "api-w21 native activation edits the bound model exactly once" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const check = try identityOf(&fixture, .{ .static = "check" });
    try std.testing.expectEqual(
        semantics.Checked.off,
        fixture.publisher.snapshot().?.node(check.id).?.states.checked,
    );

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    const snapshot = fixture.publisher.snapshot().?;
    try expectWidget(snapshot.dispatch(.{
        .id = check.id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), check.owner);
    try std.testing.expect(root.checked);
    try std.testing.expectEqual(@as(u32, 1), fixture.activations);
}

test "api-w21 slider set-value and increment stay inside the published range" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const volume = try identityOf(&fixture, .{ .static = "volume" });
    const snapshot = fixture.publisher.snapshot().?;
    const entry = snapshot.node(volume.id).?;
    try std.testing.expectEqual(semantics.Role.slider, entry.role);
    try std.testing.expectEqual(@as(f64, 0), entry.range.?.min);
    try std.testing.expectEqual(@as(f64, 1), entry.range.?.max);
    try std.testing.expect(entry.actions.has(.set_value));
    try std.testing.expect(entry.actions.has(.increment));
    try std.testing.expect(!entry.actions.has(.expand));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectWidget(snapshot.dispatch(.{
        .id = volume.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .number = 0.75,
    }, &dispatcher, scratch), volume.owner);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), fixture.last_number, 1e-5);

    try expectIgnored(snapshot.dispatch(.{
        .id = volume.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .number = 4,
    }, &dispatcher, scratch), .invalid_argument);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), fixture.last_number, 1e-5);

    const step = entry.range.?.step.?;
    try expectWidget(snapshot.dispatch(.{
        .id = volume.id,
        .action = .increment,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), volume.owner);
    try std.testing.expectApproxEqAbs(0.75 + step, fixture.last_number, 1e-5);
}

test "api-w21 the published slider is a typed node, not serialized metadata" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const volume = try identityOf(&fixture, .{ .static = "volume" });
    const entry = fixture.publisher.snapshot().?.node(volume.id).?;
    try std.testing.expectEqual(@as(f64, @floatCast(root.value)), entry.value.number);
    try std.testing.expectEqualStrings("Volume", entry.name);

    const dense = fixture.app.tree_ptr.?.frameNode(volume.owner).?;
    try std.testing.expectEqual(
        visualBorderRect(fixture.app.tree_ptr.?, dense),
        entry.bounds,
    );
}

test "api-w21 text selection geometry and endpoints route to the text path" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const container = try findByName(snapshot, "Library");
    const text = container.text.?;
    try std.testing.expectEqualStrings("hello world", text.value);
    try std.testing.expectEqualStrings("A virtualized list", container.description);
    try std.testing.expectEqualStrings("Ctrl+L", container.shortcut);
    try std.testing.expectEqual(@as(usize, 5), text.selection.?.focus);
    try std.testing.expectEqual(@as(usize, 11), text.character_lengths.len);
    try std.testing.expectEqual(@as(usize, 11), text.character_positions.len);
    try std.testing.expectEqual(@as(f32, 24), text.character_positions[3]);
    try std.testing.expectEqual(@as(f32, 8), text.character_widths[3]);
    try std.testing.expect(container.actions.has(.set_text_selection));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectWidget(snapshot.dispatch(.{
        .id = container.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection = .{ .anchor = 2, .focus = 7 },
    }, &dispatcher, scratch), container.owner.?);
    try std.testing.expectEqual(@as(usize, 2), fixture.text.selection.anchor);
    try std.testing.expectEqual(@as(usize, 7), fixture.text.selection.focus);
    // Moving a caret changes no contents, so not one character byte moved
    // and no whole write was delivered.
    try std.testing.expectEqualStrings("hello world", fixture.text.value());
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);

    // An endpoint past the last character has no position in this text, and
    // the refusal leaves the caret where the client last put it.
    try expectIgnored(snapshot.dispatch(.{
        .id = container.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection = .{ .anchor = 2, .focus = 999 },
    }, &dispatcher, scratch), .invalid_argument);
    try std.testing.expectEqual(@as(usize, 7), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
}

test "api-w21 a string set-value replaces the whole field and ends the caret on its last byte" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    // The platform sends the field's new characters as ONE string, which
    // rides the same wire action a numeric value rides.
    try std.testing.expect(field.actions.has(.set_value));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = "käse",
    }, &dispatcher, scratch), field.owner.?);
    // ONE ordinary write, and none of the previous contents survives: the
    // live 0..5 selection is not spliced into the new characters.
    try std.testing.expectEqual(@as(u32, 1), fixture.whole_writes);
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
    try std.testing.expectEqualStrings("käse", fixture.text.value());
    try std.testing.expectEqual(@as(u32, 0), fixture.number_writes);
    // The bytes are the model's own, so the caret lands after the last one
    // and is collapsed: a screen reader typing a value ends up reading it.
    const bytes: usize = "käse".len;
    try std.testing.expectEqual(bytes, fixture.text.len);
    try std.testing.expectEqual(bytes, fixture.text.selection.anchor);
    try std.testing.expectEqual(bytes, fixture.text.selection.focus);
    try std.testing.expect(fixture.text.selection.isEmpty());
}

test "api-w21 an empty string set-value clears the field and the caret with it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = "",
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqual(@as(u32, 1), fixture.whole_writes);
    try std.testing.expectEqual(@as(usize, 0), fixture.text.len);
    try std.testing.expectEqualStrings("", fixture.text.value());
    try std.testing.expectEqual(@as(usize, 0), fixture.text.selection.anchor);
    try std.testing.expectEqual(@as(usize, 0), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 0), fixture.number_writes);
}

test "api-w21 a set-value payload reaches only the seam its node owns" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const volume = try identityOf(&fixture, .{ .static = "volume" });
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // The action is supported and the request carries nothing to set.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .invalid_argument);
    // A number is a value for a RANGE, and a field publishes none.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .number = 3,
    }, &dispatcher, scratch), .invalid_argument);
    // A slider owns a range and no characters, so a string is not a value
    // for it either.
    try expectIgnored(snapshot.dispatch(.{
        .id = volume.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = "loud",
    }, &dispatcher, scratch), .invalid_argument);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.number_writes);

    // The number still reaches the one control that owns a range, and the
    // ordinary value path writes it into the model.
    try expectWidget(snapshot.dispatch(.{
        .id = volume.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .number = 0.5,
    }, &dispatcher, scratch), volume.owner);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), fixture.last_number, 1e-5);
    try std.testing.expectEqual(@as(f32, 0.5), root.value);

    // An app that wired no text seam is told so instead of being reported
    // as a change it never made.
    var limited = fixture.dispatcher();
    limited.set_text = null;
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = "typed",
    }, &limited, scratch), .no_handler);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
}

test "api-w21 an authored action set still decides what a text field accepts" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .author_text_actions = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    // The app stated the whole set, so the core adds nothing to it.
    try std.testing.expect(!field.actions.has(.set_value));
    try std.testing.expect(field.actions.has(.replace_selected_text));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = "typed",
    }, &dispatcher, scratch), .unsupported_action);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);

    // The actions it DID state still reach the same text path, and reach it
    // with the live selection the app is showing: the 0..5 the field
    // published is the 0..5 the model holds.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "goodbye",
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqualStrings("goodbye world", fixture.text.value());
    try std.testing.expectEqual(@as(usize, 7), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 1), fixture.whole_writes);
}

test "api-w21 an ordinary replacement splices the live selection, not the published one" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // A queued selection moves the model's caret and republishes nothing, so
    // the frame still describes 0..5 while the model is already at 2..7.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection = .{ .anchor = 2, .focus = 7 },
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqual(@as(usize, 5), field.text.?.selection.?.focus);

    // The replacement therefore splices the LIVE 2..7 span, which is "llo w"
    // and not the "hello" the frame froze.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "goodbye",
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqualStrings("hegoodbyeorld", fixture.text.value());
    try std.testing.expectEqual(@as(usize, 9), fixture.text.selection.anchor);
    try std.testing.expectEqual(@as(usize, 9), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 1), fixture.whole_writes);

    // A second edit against the SAME unchanged snapshot accumulates on the
    // bytes the first one produced, and lands the caret after what it typed.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "!",
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqualStrings("hegoodbye!orld", fixture.text.value());
    try std.testing.expectEqual(@as(usize, 10), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 2), fixture.whole_writes);
    // Exactly one delivery per applied edit, and none for the caret move.
    try std.testing.expectEqual(@as(u32, 3), fixture.text_writes);
    // The frame never caught up: it still describes what the model said
    // before the first edit.
    try std.testing.expectEqualStrings("hello world", field.value.text);
}

test "api-w21 a positioned edit inserts and deletes at live character positions" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "héllo", semantics.TextSelection.caret(5));

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // Character one is the two-byte "é". The platform counts characters, the
    // model counts bytes, and the position is resolved against the bytes the
    // model holds now rather than against the published character table.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.text_run.?, .start = 1, .end = 1, .bytes = "ü" },
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqualStrings("hüéllo", fixture.text.value());
    try std.testing.expect(std.unicode.utf8ValidateSlice(fixture.text.value()));
    try std.testing.expectEqual(@as(usize, 3), fixture.text.selection.focus);

    // Deleting characters one through two removes the two-byte "ü" that was
    // just inserted, and the caret lands back where it began.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 1, .end = 2, .bytes = "" },
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqualStrings("héllo", fixture.text.value());
    try std.testing.expectEqual(@as(usize, 1), fixture.text.selection.focus);

    // The whole of the live value is a range too, and emptying a field is a
    // value the field still publishes.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 0, .end = 5, .bytes = "" },
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqualStrings("", fixture.text.value());
    try std.testing.expectEqual(@as(usize, 0), fixture.text.selection.focus);
    // Three applied edits, three whole writes and nothing else.
    try std.testing.expectEqual(@as(u32, 3), fixture.whole_writes);
    try std.testing.expectEqual(@as(u32, 3), fixture.text_writes);
}

test "api-w21 a positioned edit names only the target's own text" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_notes = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const notes = try findByName(snapshot, "Notes");
    const button = (try identityOf(&fixture, .{ .static = "first" })).id;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // The target does not own the text the range names.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = notes.text_run.?, .start = 0, .end = 1, .bytes = "x" },
    }, &dispatcher, scratch), .foreign_text_selection);
    // Nor does it own the field the range names.
    try expectIgnored(snapshot.dispatch(.{
        .id = notes.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 0, .end = 1, .bytes = "x" },
    }, &dispatcher, scratch), .foreign_text_selection);
    // A node that publishes no characters at all is an offset into nothing.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = button, .start = 0, .end = 1, .bytes = "x" },
    }, &dispatcher, scratch), .foreign_text_selection);
    // A node this frame never published is not a position in anything.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = semantics.no_node, .start = 0, .end = 1, .bytes = "x" },
    }, &dispatcher, scratch), .unknown_node);

    // Not one of those reached the model.
    try std.testing.expectEqualStrings("hello world", fixture.text.value());
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
}

test "api-w21 a positioned edit refuses a reversed, out-of-range or non-UTF-8 range" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "héllo", semantics.TextSelection.caret(5));

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // A backwards range names no range at all.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 3, .end = 1, .bytes = "x" },
    }, &dispatcher, scratch), .invalid_argument);
    // The live value holds five characters, so neither the end nor the start
    // of the sixth is a position in it.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 0, .end = 6, .bytes = "x" },
    }, &dispatcher, scratch), .invalid_argument);
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 99, .end = 99, .bytes = "x" },
    }, &dispatcher, scratch), .invalid_argument);
    // Bytes that are not UTF-8 cannot be spliced into a value the model can
    // ever publish again, so they are refused whole in both shapes.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 0, .end = 0, .bytes = "\xff" },
    }, &dispatcher, scratch), .invalid_argument);
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "\xff",
    }, &dispatcher, scratch), .invalid_argument);
    // A caret that lands inside a character is no position a model can act
    // on, so the live selection is refused rather than split mid-scalar.
    // Byte two of "héllo" is the tail of the two-byte character.
    try fixture.text.seed("héllo", semantics.TextSelection.caret(2));
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "x",
    }, &dispatcher, scratch), .invalid_argument);

    // None of those changed a byte or delivered a write, and the last
    // refusal left the caret the model was already showing.
    try std.testing.expectEqualStrings("héllo", fixture.text.value());
    try std.testing.expectEqual(@as(usize, 2), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
}

test "api-w21 a positioned edit is one payload of one action" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // Two answers to one request are not one request, even when both of them
    // would have been legal on their own.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "a",
        .edit = .{ .node = field.id, .start = 0, .end = 1, .bytes = "b" },
    }, &dispatcher, scratch), .invalid_argument);
    // The payload belongs to the one action that takes it.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 0, .end = 1, .bytes = "b" },
    }, &dispatcher, scratch), .invalid_argument);
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 0, .end = 1, .bytes = "b" },
    }, &dispatcher, scratch), .invalid_argument);
    // And neither shape is an edit on its own.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .invalid_argument);

    try std.testing.expectEqualStrings("hello world", fixture.text.value());
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
}

test "api-w21 a model that states no live text is never composed against" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_notes = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // An app that wires no getter has no live characters to splice into, so
    // both shapes are refused instead of being served the published run.
    var blind = fixture.dispatcher();
    blind.read_text = null;
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "goodbye",
    }, &blind, scratch), .no_handler);
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 0, .end = 1, .bytes = "x" },
    }, &blind, scratch), .no_handler);
    try std.testing.expectEqualStrings("hello world", fixture.text.value());
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);

    // A getter that answers for another widget has not answered here.
    try seedField(&fixture, .{ .static = key_notes }, "hello world", .{ .anchor = 0, .focus = 5 });
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "goodbye",
    }, &dispatcher, scratch), .no_handler);
    try std.testing.expectEqualStrings("hello world", fixture.text.value());
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);

    // A whole value needs no live characters, so it still travels the one
    // ordinary door a provider has always used.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = "typed",
    }, &blind, scratch), field.owner.?);
    try std.testing.expectEqualStrings("typed", fixture.text.value());
    try std.testing.expectEqual(@as(u32, 1), fixture.whole_writes);
}

test "api-w21 an edit too large for its bound leaves the model exactly as it was" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "", semantics.TextSelection.caret(0));

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    // Enough to take the field from eight bytes to exactly its own bound.
    const filler: []const u8 = &@as([56]u8, @splat('a'));
    const full: []const u8 = &@as([64]u8, @splat('a'));

    // The caller's own composition buffer is the tighter of the two bounds:
    // eight bytes fit it exactly and nine do not fit at all.
    const tight = fixture.boundedScratch(8);
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "aaaaaaaa",
    }, &dispatcher, tight), field.owner.?);
    try std.testing.expectEqual(@as(usize, 8), fixture.text.len);
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "a",
    }, &dispatcher, tight), .invalid_argument);
    try std.testing.expectEqual(@as(usize, 8), fixture.text.len);
    try std.testing.expectEqual(@as(usize, 8), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 1), fixture.whole_writes);

    // With the caller's buffer out of the way the model's own 64 bytes are
    // the bound, and the value reaches it exactly before it stops.
    const roomy = fixture.scratch();
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = filler,
    }, &dispatcher, roomy), field.owner.?);
    try std.testing.expectEqual(@as(usize, 64), fixture.text.len);
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "a",
    }, &dispatcher, roomy), .invalid_argument);
    try std.testing.expectEqual(@as(usize, 64), fixture.text.len);
    try std.testing.expectEqual(@as(u32, 2), fixture.whole_writes);
    // Nothing was clipped into a value the client never typed.
    try std.testing.expectEqualStrings(full, fixture.text.value());
}

test "api-w21 a whole value the model cannot hold is refused before the setter" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_list }, "hello world", .{ .anchor = 0, .focus = 5 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    // The field's own bound, and one byte past it.
    const full: []const u8 = &@as([64]u8, @splat('a'));
    const over: []const u8 = &@as([65]u8, @splat('a'));

    // Exactly the model's own bound is a value it takes.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = full,
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqual(@as(usize, 64), fixture.text.len);

    // One byte more is refused against the stated capacity, so the setter
    // never saw it and nothing was cancelled or clipped on the way there.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = over,
    }, &dispatcher, scratch), .invalid_argument);
    try std.testing.expectEqual(@as(u32, 0), fixture.text.refusals);
    try std.testing.expectEqual(@as(u32, 1), fixture.whole_writes);

    // Without the getter the core has no bound to check, so the oversized
    // value reaches the model, and the MODEL refuses it whole.
    var blind = fixture.dispatcher();
    blind.read_text = null;
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = over,
    }, &blind, scratch), .no_handler);
    try std.testing.expectEqual(@as(u32, 1), fixture.text.refusals);
    // The field kept every character it ever accepted: no tail silently
    // dropped, and no character cut in half to make the value fit.
    try std.testing.expectEqualStrings(full, fixture.text.value());
    try std.testing.expectEqual(@as(usize, 64), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 1), fixture.whole_writes);
}

test "api-w21 a read-only field refuses every contents action and still takes a selection" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_readonly = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_readonly }, "fixed value", .{ .anchor = 2, .focus = 2 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Reference");
    try std.testing.expect(field.states.read_only);
    // Its characters are published, so a screen reader can read them.
    try std.testing.expectEqualStrings("fixed value", field.value.text);
    // A client is offered no edit the app refuses, and is still offered the
    // selection: moving a caret changes no contents.
    try std.testing.expect(!field.actions.has(.set_value));
    try std.testing.expect(!field.actions.has(.replace_selected_text));
    try std.testing.expect(field.actions.has(.set_text_selection));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = "typed",
    }, &dispatcher, scratch), .unsupported_action);
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "typed",
    }, &dispatcher, scratch), .unsupported_action);
    // The positioned shape is refused by the same policy, whatever it names.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .edit = .{ .node = field.id, .start = 0, .end = 2, .bytes = "xy" },
    }, &dispatcher, scratch), .unsupported_action);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);
    try std.testing.expectEqualStrings("fixed value", fixture.text.value());

    // The selection is still the ordinary path into the same model.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection = semantics.TextSelection.caret(6),
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqual(@as(usize, 6), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
    // The caret moved on a read-only field and the characters did not.
    try std.testing.expectEqualStrings("fixed value", fixture.text.value());
}

test "api-w21 an authored contents action cannot make a read-only field editable" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{
        .fixture = &fixture,
        .show_readonly = true,
        .force_readonly_actions = true,
    };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    try seedField(&fixture, .{ .static = key_readonly }, "fixed value", .{ .anchor = 2, .focus = 2 });

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Reference");
    try std.testing.expect(field.states.read_only);
    // The app stated the set itself, so both contents bits ARE advertised:
    // only the core's own refusal can stop the write now.
    try std.testing.expect(field.actions.has(.set_value));
    try std.testing.expect(field.actions.has(.replace_selected_text));
    try std.testing.expect(field.actions.has(.set_text_selection));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .text = "typed",
    }, &dispatcher, scratch), .unsupported_action);
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .replace_selected_text,
        .generation = snapshot.generation,
        .text = "typed",
    }, &dispatcher, scratch), .unsupported_action);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.whole_writes);
    try std.testing.expectEqualStrings("fixed value", fixture.text.value());

    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection = semantics.TextSelection.caret(6),
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
}

test "api-w21 a read-only numeric control refuses set-value, increment and decrement" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .readonly_slider = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const volume = try identityOf(&fixture, .{ .static = "volume" });
    const snapshot = fixture.publisher.snapshot().?;
    const entry = snapshot.node(volume.id).?;
    try std.testing.expectEqual(semantics.Role.slider, entry.role);
    try std.testing.expect(entry.states.read_only);
    // Read-only is not invisible: the value, the range and the step are what
    // the control announces.
    try std.testing.expectEqual(@as(f64, 0.25), entry.value.number);
    try std.testing.expectEqual(@as(f64, 0), entry.range.?.min);
    try std.testing.expectEqual(@as(f64, 1), entry.range.?.max);
    try std.testing.expectEqual(@as(?f64, 0.01), entry.range.?.step);
    // `read_only` is additive and never takes a built-in action away, so the
    // numeric bits stay advertised and the core's own refusal is the only
    // thing that can stop a write.
    try std.testing.expect(entry.actions.has(.set_value));
    try std.testing.expect(entry.actions.has(.increment));
    try std.testing.expect(entry.actions.has(.decrement));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = volume.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .number = 0.75,
    }, &dispatcher, scratch), .unsupported_action);
    try expectIgnored(snapshot.dispatch(.{
        .id = volume.id,
        .action = .increment,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unsupported_action);
    try expectIgnored(snapshot.dispatch(.{
        .id = volume.id,
        .action = .decrement,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unsupported_action);
    // Not one write reached the ordinary value path, so the bound model is
    // exactly what the app last drew.
    try std.testing.expectEqual(@as(u32, 0), fixture.number_writes);
    try std.testing.expectEqual(@as(f32, 0.25), root.value);

    // Reading and focusing change no value, so both still travel the ordinary
    // paths: a read-only control stays reachable, it just cannot be written.
    try expectWidget(snapshot.dispatch(.{
        .id = volume.id,
        .action = .focus,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), volume.owner);
    try std.testing.expectEqual(@as(u32, 1), fixture.focus_set);
    try std.testing.expectEqual(@as(u32, 0), fixture.number_writes);
    try std.testing.expectEqual(@as(f32, 0.25), root.value);
}

test "api-w21 an authored numeric action set cannot make a read-only control editable" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{
        .fixture = &fixture,
        .readonly_slider = true,
        .force_readonly_slider_actions = true,
    };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const volume = try identityOf(&fixture, .{ .static = "volume" });
    const snapshot = fixture.publisher.snapshot().?;
    const entry = snapshot.node(volume.id).?;
    try std.testing.expect(entry.states.read_only);
    // The app stated the set itself, so every numeric contents bit IS
    // advertised: only the core's own refusal can stop the write now.
    try std.testing.expect(entry.actions.has(.set_value));
    try std.testing.expect(entry.actions.has(.increment));
    try std.testing.expect(entry.actions.has(.decrement));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = volume.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .number = 0.75,
    }, &dispatcher, scratch), .unsupported_action);
    try expectIgnored(snapshot.dispatch(.{
        .id = volume.id,
        .action = .increment,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unsupported_action);
    try expectIgnored(snapshot.dispatch(.{
        .id = volume.id,
        .action = .decrement,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unsupported_action);
    try std.testing.expectEqual(@as(u32, 0), fixture.number_writes);
    try std.testing.expectEqual(@as(f32, 0.25), root.value);
}

test "api-w21 a virtualized list publishes one node for a million rows" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    const container = try findByName(snapshot, "Library");
    const list = container.list orelse return error.MissingVirtualList;
    try std.testing.expectEqual(@as(usize, 1_000_000), list.row_count);
    try std.testing.expectEqual(@as(usize, 1_000_000), container.relations.row_count.?);
    try std.testing.expectEqual(@as(usize, 7), container.relations.position_in_set.?);
    // A selection-capable container, so the platform offers a Selection
    // interface at all: `Role.list` is not one of the containers whose
    // children a platform will let a client select.
    try std.testing.expectEqual(semantics.Role.list_box, container.role);
    try std.testing.expect(container.actions.has(.custom_action));

    // No widget was built for these rows, and none is needed to name them.
    var name: [64]u8 = undefined;
    const offscreen = try snapshot.virtualRow(container.id, 999_999, &name);
    try std.testing.expectEqual(@as(usize, 999_999), offscreen.index);
    try std.testing.expectEqual(@as(u64, 1_000_999), offscreen.key);
    try std.testing.expectEqualStrings("row 999999 #1000999", offscreen.name);
    try std.testing.expect(!offscreen.selected);
    try std.testing.expect(offscreen.id != container.id);

    try std.testing.expect((try snapshot.virtualRow(container.id, 7, &name)).selected);
    try std.testing.expectError(
        error.InvalidSemanticRow,
        snapshot.virtualRow(container.id, 1_000_000, &name),
    );
    try std.testing.expectError(
        error.NotAList,
        snapshot.virtualRow((try identityOf(&fixture, .{ .static = "first" })).id, 0, &name),
    );
}

test "api-w21 a native row selection reaches the model through the list owner" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    const container = try findByName(snapshot, "Library");
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    const outcome = snapshot.dispatch(.{
        .id = container.id,
        .action = .custom_action,
        .generation = snapshot.generation,
        .row_index = 999_999,
    }, &dispatcher, scratch);
    try std.testing.expectEqual(@as(usize, 999_999), fixture.last_row_index);
    try std.testing.expectEqual(@as(u64, 1_000_999), fixture.last_row_key);
    try std.testing.expectEqual(@as(u32, 1), fixture.row_selections);
    switch (outcome) {
        .applied => |target| switch (target) {
            .row => |row| {
                try std.testing.expectEqual(container.id, row.list);
                try std.testing.expectEqualStrings("row 999999 #1000999", row.name);
            },
            .widget => return error.NativeActionHitWidget,
        },
        .ignored => return error.NativeActionWasIgnored,
    }

    try expectIgnored(snapshot.dispatch(.{
        .id = container.id,
        .action = .custom_action,
        .generation = snapshot.generation,
        .row_index = 1_000_000,
    }, &dispatcher, scratch), .invalid_argument);
    try expectIgnored(snapshot.dispatch(.{
        .id = container.id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unsupported_action);
    try std.testing.expectEqual(@as(u32, 1), fixture.row_selections);
}

test "api-w21 a row identity survives a later frame" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const container = try findByName(fixture.publisher.snapshot().?, "Library");
    var name: [64]u8 = undefined;
    const before = try fixture.publisher.snapshot().?.virtualRow(container.id, 4, &name);

    root.selected_row = 9;
    try stageFrame(&fixture, &annotations);
    const rebuilt = try findByName(fixture.publisher.snapshot().?, "Library");
    const after = try fixture.publisher.snapshot().?.virtualRow(rebuilt.id, 4, &name);
    try std.testing.expectEqual(container.id, rebuilt.id);
    try std.testing.expectEqual(before.id, after.id);
    try std.testing.expectEqual(@as(u64, 1004), after.key);
}

test "api-w21 a failed stage never publishes half a tree" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const before = fixture.publisher.snapshot().?;
    const before_count = before.count();
    const before_generation = before.generation;
    const first = try identityOf(&fixture, .{ .static = "first" });

    // The App frame still commits; the semantic stage then fails partway.
    annotations.fail_after = 0;
    try std.testing.expectError(error.AnnotationFailed, stage(&fixture, &annotations));
    fixture.publisher.abort();

    const after = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(before_count, after.count());
    try std.testing.expectEqual(before_generation, after.generation);
    try std.testing.expectEqual(first.id, after.node(first.id).?.id);
    try std.testing.expect((try findByName(after, "Library")).list != null);
}

test "api-w21 a staged snapshot stays private until commit" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const published_count = fixture.publisher.snapshot().?.count();

    root.lead_label = true;
    try stage(&fixture, &annotations);
    // Staging is invisible: the previous snapshot still serves every reader.
    try std.testing.expectEqual(published_count, fixture.publisher.snapshot().?.count());
    fixture.publisher.commit();
    try std.testing.expect(fixture.publisher.snapshot().?.generation > 0);
}

test "api-w21 App publishes tree and annotated semantics as one transaction" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    fixture.app.semantic_publication = .{
        .publisher = &fixture.publisher,
        .annotator = .{ .context = &annotations, .annotate = Annotations.annotate },
        .window_name = "Frame transaction",
    };

    const first = try fixture.app.frame(0, surface);
    const committed = first.semantic_snapshot orelse return error.MissingSemanticSnapshot;
    try std.testing.expectEqual(fixture.app.frame_generation, committed.generation);
    const before_list = try findByName(committed, "Library");
    try std.testing.expect(before_list.list != null);
    try std.testing.expectEqualStrings("hello world", before_list.text.?.value);
    const before_generation = committed.generation;

    root.lead_label = true;
    annotations.text_value = "replacement";
    annotations.fail_after = 0;
    try std.testing.expectError(error.AnnotationFailed, fixture.app.frame(1, surface));
    try std.testing.expect(fixture.app.tree_ptr == first.tree);
    try std.testing.expectEqual(before_generation, fixture.app.frame_generation);
    const after_failure = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(before_generation, after_failure.generation);
    try std.testing.expectEqualStrings("hello world", (try findByName(after_failure, "Library")).text.?.value);

    annotations.fail_after = null;
    const recovered = try fixture.app.frame(1, surface);
    const snapshot = recovered.semantic_snapshot orelse return error.MissingSemanticSnapshot;
    try std.testing.expectEqual(before_generation + 1, snapshot.generation);
    try std.testing.expectEqual(fixture.app.frame_generation, snapshot.generation);
    const recovered_list = try findByName(snapshot, "Library");
    try std.testing.expectEqualStrings("replacement", recovered_list.text.?.value);
    try std.testing.expectEqual(before_list.id, recovered_list.id);
}

test "api-w21 App semantic focus follows committed focus fallback" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    fixture.app.semantic_publication = .{
        .publisher = &fixture.publisher,
        .annotator = .{ .context = &annotations, .annotate = Annotations.annotate },
    };

    const first = try fixture.app.frame(0, surface);
    const removed = (try findByName(first.semantic_snapshot.?, "Second")).owner orelse
        return error.MissingSemanticOwner;
    try std.testing.expect(fixture.app.focus_manager.set(first.tree, removed, null));
    const focused = try fixture.app.frame(1, surface);
    const focused_snapshot = focused.semantic_snapshot.?;
    try std.testing.expectEqual(semantics.nodeId(removed, .self_node), focused_snapshot.focus);
    try std.testing.expect(focused_snapshot.node(focused_snapshot.focus).?.states.focused);

    root.show_second = false;
    const next = try fixture.app.frame(2, surface);
    const fallback = next.focus orelse return error.MissingFocusFallback;
    try std.testing.expect(!fallback.eql(removed));
    const next_snapshot = next.semantic_snapshot.?;
    try std.testing.expectEqual(semantics.nodeId(fallback, .self_node), next_snapshot.focus);
    try std.testing.expect(next_snapshot.node(next_snapshot.focus).?.states.focused);
    try std.testing.expectError(error.MissingSemanticNode, findByName(next_snapshot, "Second"));
}

test "api-w21 a failed stage after a pending one keeps the last published tree" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const before_count = fixture.publisher.snapshot().?.count();
    const before_generation = fixture.publisher.snapshot().?.generation;

    // A successful stage is left PENDING: the publisher now holds a private
    // snapshot, and the published one is still the only thing readers see.
    root.lead_label = true;
    try stage(&fixture, &annotations);
    try std.testing.expectEqual(before_generation, fixture.publisher.snapshot().?.generation);

    // The next stage fails partway through. A build that never finished is not
    // a staged snapshot, so neither reader may be handed it.
    annotations.fail_after = 0;
    try std.testing.expectError(error.AnnotationFailed, stage(&fixture, &annotations));

    // A reader asking for the newest snapshot gets the last COMPLETE tree.
    const staged = fixture.publisher.stagedSnapshot().?;
    try std.testing.expectEqual(before_generation, staged.generation);
    try std.testing.expectEqual(before_count, staged.count());
    const published = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(before_generation, published.generation);
    try std.testing.expectEqual(before_count, published.count());

    // A commit publishes the staged snapshot as a whole or nothing, and there
    // is nothing complete staged, so the published tree stands unchanged.
    fixture.publisher.commit();
    const after = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(before_generation, after.generation);
    try std.testing.expectEqual(before_count, after.count());
    try std.testing.expect((try findByName(after, "Library")).list != null);

    // The failure is not sticky: the next frame that does build publishes.
    annotations.fail_after = null;
    try stageFrame(&fixture, &annotations);
    const recovered = fixture.publisher.snapshot().?;
    try std.testing.expect(recovered.generation > before_generation);
    try std.testing.expect((try findByName(recovered, "Library")).list != null);
}

test "api-w21 a dangling relation is refused instead of silently dropped" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    const Dangling = struct {
        fn annotate(_: *anyopaque, node: *const WidgetNode, draft: *semantics.Draft) anyerror!void {
            if (node.kind != .column) return;
            draft.publish = true;
            draft.active_descendant = 0xDEAD_BEEF;
        }
    };
    const output = (try fixture.app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    try std.testing.expectError(error.DanglingSemanticRelation, fixture.publisher.stage(.{
        .tree = output.tree,
        .generation = fixture.app.frame_generation,
        .surface = surface,
        .annotator = .{ .context = &annotations, .annotate = Dangling.annotate },
    }));
    fixture.publisher.abort();
    try std.testing.expect(fixture.publisher.snapshot() == null);
}

test "api-w21 focus and blur use the ordinary focus path" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const first = try identityOf(&fixture, .{ .static = "first" });

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    const snapshot = fixture.publisher.snapshot().?;
    try expectWidget(snapshot.dispatch(.{
        .id = first.id,
        .action = .focus,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), first.owner);
    try std.testing.expectEqual(@as(u32, 1), fixture.focus_set);
    try std.testing.expect(fixture.app.focus_manager.current.?.eql(first.owner));

    // The next committed snapshot publishes the new focus.
    try stageFrame(&fixture, &annotations);
    const focused = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(first.id, focused.focus);
    try std.testing.expect(focused.node(first.id).?.states.focused);

    try expectWidget(focused.dispatch(.{
        .id = first.id,
        .action = .blur,
        .generation = focused.generation,
    }, &dispatcher, scratch), first.owner);
    try std.testing.expectEqual(@as(u32, 1), fixture.focus_cleared);
    try std.testing.expect(fixture.app.focus_manager.current == null);
}

test "api-w21 an unsupported action never reaches the model" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const check = try identityOf(&fixture, .{ .static = "check" });

    const snapshot = fixture.publisher.snapshot().?;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectIgnored(snapshot.dispatch(.{
        .id = check.id,
        .action = .set_value,
        .generation = snapshot.generation,
        .number = 1,
    }, &dispatcher, scratch), .unsupported_action);
    try expectIgnored(snapshot.dispatch(.{
        .id = check.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection = semantics.TextSelection.caret(0),
    }, &dispatcher, scratch), .unsupported_action);
    try std.testing.expectEqual(@as(u32, 0), fixture.activations);
    try std.testing.expectEqual(@as(u32, 0), fixture.number_writes);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);
}

test "api-w21 every published node hangs off a published parent" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(semantics.window_node, snapshot.root);
    const window = snapshot.node(semantics.window_node).?;
    try std.testing.expectEqual(semantics.Role.window, window.role);
    try std.testing.expectEqualStrings("Fixture", window.name);
    try std.testing.expect(window.children.len > 0);
    try std.testing.expectEqual(surface.width, window.bounds.w);
    try std.testing.expectEqual(surface.height, window.bounds.h);

    // The unkeyed lead label stays out of the tree; the buttons do not.
    for (snapshot.nodes) |entry| {
        try std.testing.expect(entry.owner != null);
        if (entry.id == semantics.window_node) continue;
        const parent = snapshot.node(entry.parent) orelse return error.DanglingSemanticRelation;
        var found = false;
        for (parent.children) |child| {
            if (child == entry.id) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "api-w21 modality is authored: two dialogs differ only by the authored flag" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_dialogs = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const modal = try identityOf(&fixture, .{ .static = "modal" });
    const plain = try identityOf(&fixture, .{ .static = "plain" });
    const confirm = try identityOf(&fixture, .{ .static = "confirm" });
    const first = try identityOf(&fixture, .{ .static = "first" });
    const before = fixture.publisher.snapshot().?;

    // Same role, same shape, one authored difference.
    try std.testing.expectEqual(semantics.Role.dialog, before.node(modal.id).?.role);
    try std.testing.expectEqual(semantics.Role.dialog, before.node(plain.id).?.role);
    try std.testing.expect(before.node(modal.id).?.states.modal);
    try std.testing.expect(!before.node(plain.id).?.states.modal);
    // Nothing in the tree infers modality, so an ordinary control never
    // claims to own input.
    try std.testing.expect(!before.node(first.id).?.states.modal);
    // Modality is a state, not a lock: the subtree stays reachable.
    const confirm_node = before.node(confirm.id).?;
    try std.testing.expect(!confirm_node.states.modal);
    try std.testing.expect(confirm_node.actions.has(.click));

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectWidget(before.dispatch(.{
        .id = confirm.id,
        .action = .click,
        .generation = before.generation,
    }, &dispatcher, scratch), confirm.owner);
    try std.testing.expectEqual(@as(u32, 1), root.clicks);

    // Dropping the flag is a model change, not a new subtree: the identities
    // stay and the same dialog is now an ordinary one.
    root.modal_dialog = false;
    try stageFrame(&fixture, &annotations);
    const after = fixture.publisher.snapshot().?;
    try std.testing.expect(after.generation > before.generation);
    try std.testing.expectEqual(modal.id, (try identityOf(&fixture, .{ .static = "modal" })).id);
    try std.testing.expectEqual(plain.id, (try identityOf(&fixture, .{ .static = "plain" })).id);
    try std.testing.expect(!after.node(modal.id).?.states.modal);
    try std.testing.expectEqual(semantics.Role.dialog, after.node(modal.id).?.role);
}

test "api-w21 a hidden subtree publishes nothing, forced annotation or not" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_dialogs = true, .hide_modal = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    // Both widgets are live, so both identities resolve in the app. What the
    // tree refuses is the published node, not the identity.
    const modal = try identityOfWidget(&fixture, .{ .static = "modal" });
    const confirm = try identityOfWidget(&fixture, .{ .static = "confirm" });
    const snapshot = fixture.publisher.snapshot().?;
    try std.testing.expect(snapshot.node(modal.id) == null);
    try std.testing.expect(snapshot.node(confirm.id) == null);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    // The dialog would have been annotated and its control activated, yet
    // neither request resolves: a hidden subtree is not a reader stop.
    try expectIgnored(snapshot.dispatch(.{
        .id = modal.id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unknown_node);
    try expectIgnored(snapshot.dispatch(.{
        .id = confirm.id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unknown_node);
    try std.testing.expectEqual(@as(u32, 0), fixture.activations);
    try std.testing.expectEqual(@as(u32, 0), root.clicks);

    // Showing it again republishes the same identities, authored modality
    // included, and the control is reachable once more.
    root.hide_modal = false;
    try stageFrame(&fixture, &annotations);
    const after = fixture.publisher.snapshot().?;
    try std.testing.expect(after.node(modal.id).?.states.modal);
    try std.testing.expect(after.node(confirm.id).?.actions.has(.click));
    try expectWidget(after.dispatch(.{
        .id = confirm.id,
        .action = .click,
        .generation = after.generation,
    }, &dispatcher, scratch), confirm.owner);
    try std.testing.expectEqual(@as(u32, 1), root.clicks);
}

test "api-w21 an authored hidden list is announced, unreachable, and publishes no row" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const list = (try findByName(fixture.publisher.snapshot().?, "Library")).id;
    const row_id = (selectedRow(fixture.publisher.snapshot().?, list) orelse
        return error.MissingSelectedRow).id;

    root.hide_list = true;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const hidden = snapshot.node(list).?;
    try std.testing.expectEqual(semantics.Role.list_box, hidden.role);
    try std.testing.expect(hidden.states.hidden);
    try std.testing.expect(hidden.actions.isEmpty());
    try std.testing.expect(!hidden.isInteractive());
    // The app still has a selection. A selection nobody can reach is not
    // published, so no row node stands for it.
    try std.testing.expect(!hasRow(snapshot, list));
    try std.testing.expect(snapshot.node(row_id) == null);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    for ([_]semantics.Action{
        .click,
        .custom_action,
        .focus,
        .blur,
        .set_text_selection,
        .replace_selected_text,
    }) |action| {
        try expectIgnored(snapshot.dispatch(.{
            .id = list,
            .action = action,
            .generation = snapshot.generation,
        }, &dispatcher, scratch), .hidden);
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.activations);
    try std.testing.expectEqual(@as(u32, 0), fixture.row_selections);
    try std.testing.expectEqual(@as(u32, 0), fixture.text_writes);

    // Unhiding restores the very same row identity: a row is named by its
    // key, never by the frame it was first seen in.
    root.hide_list = false;
    try stageFrame(&fixture, &annotations);
    const restored = selectedRow(fixture.publisher.snapshot().?, list) orelse
        return error.MissingSelectedRow;
    try std.testing.expectEqual(row_id, restored.id);
    try std.testing.expect(restored.states.selected);
}

test "api-w21 a hidden authored focusable control publishes no action at all" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    // The first button is a real FOCUSABLE widget, so this node carries the
    // whole built-in action set at once. It is what makes the hidden contract
    // observable: every other annotated node in this fixture is a plain
    // container the built-in policy does not call focusable.
    const button = try identityOf(&fixture, .{ .static = "first" });
    const live = fixture.publisher.snapshot().?.node(button.id).?;
    try std.testing.expectEqual(semantics.Role.button, live.role);
    try std.testing.expect(live.states.focusable);
    try std.testing.expect(live.actions.has(.click));
    try std.testing.expect(live.actions.has(.focus));

    root.hide_first = true;
    try stageFrame(&fixture, &annotations);
    const hidden = fixture.publisher.snapshot().?.node(button.id).?;
    try std.testing.expect(hidden.states.hidden);
    // Announced as hidden means offered nothing. A reader must never be
    // handed an action the tree would refuse, and focus is an action.
    try std.testing.expect(!hidden.actions.has(.focus));
    try std.testing.expect(!hidden.actions.has(.blur));
    try std.testing.expect(hidden.actions.isEmpty());
    try std.testing.expect(!hidden.isInteractive());

    // Nothing reaches the model through it, and it keeps its own identity.
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    const snapshot = fixture.publisher.snapshot().?;
    for ([_]semantics.Action{ .focus, .blur, .click }) |action| {
        try expectIgnored(snapshot.dispatch(.{
            .id = button.id,
            .action = action,
            .generation = snapshot.generation,
        }, &dispatcher, scratch), .hidden);
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.activations);
    try std.testing.expectEqual(@as(u32, 0), fixture.focus_set);
    try std.testing.expectEqual(@as(u32, 0), root.clicks);

    // Unhiding restores the built-in set on the very same node.
    root.hide_first = false;
    try stageFrame(&fixture, &annotations);
    const restored = fixture.publisher.snapshot().?.node(button.id).?;
    try std.testing.expect(!restored.states.hidden);
    try std.testing.expect(restored.states.focusable);
    try std.testing.expect(restored.actions.has(.click));
    try std.testing.expect(restored.actions.has(.focus));
    try std.testing.expect(restored.actions.has(.blur));
}

test "api-w21 a list container under a disabled ancestor publishes no action and no row" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_panel = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    // A real keyed column carries the list. It is forced into the tree, so
    // nothing but the tree itself can tell a reader it is unreachable.
    const tray = try identityOf(&fixture, .{ .static = "tray" });
    const child = try identityOf(&fixture, .{ .static = "panel_button" });
    const live = fixture.publisher.snapshot().?;
    const row = selectedRow(live, tray.id) orelse return error.MissingSelectedRow;
    const row_id = row.id;
    try std.testing.expectEqual(semantics.Role.list_box, live.node(tray.id).?.role);
    try std.testing.expectEqualStrings("row 2 #5002", row.name);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    const resolved = try expectRow(live.dispatch(.{
        .id = row_id,
        .action = .click,
        .generation = live.generation,
    }, &dispatcher, scratch));
    try std.testing.expectEqual(@as(usize, 2), resolved.index);
    try std.testing.expectEqual(@as(u64, 5002), resolved.key);
    try std.testing.expectEqual(@as(u32, 1), fixture.row_selections);
    try std.testing.expect(fixture.last_row_owner.eql(tray.owner));

    // Disabling the ANCESTOR takes the whole subtree out of reach. The tray
    // is a forced node, so the tree is the only source of that state.
    root.disable_panel = true;
    try stageFrame(&fixture, &annotations);
    const off = fixture.publisher.snapshot().?;
    const disabled = off.node(tray.id).?;
    try std.testing.expect(disabled.states.disabled);
    try std.testing.expect(!disabled.states.focusable);
    try std.testing.expect(disabled.actions.isEmpty());
    try std.testing.expect(!disabled.isInteractive());
    // The app still holds a selection, and a selection nobody can reach is
    // not published: the row node is gone, not merely unclickable.
    try std.testing.expect(!hasRow(off, tray.id));
    try std.testing.expect(off.node(row_id) == null);
    // The control inside the same subtree is disabled through the ancestor.
    const inherited = off.node(child.id).?;
    try std.testing.expect(inherited.states.disabled);
    try std.testing.expect(!inherited.states.focusable);
    try std.testing.expect(inherited.actions.isEmpty());

    // Nothing reaches the model: not the row the reader still holds, not the
    // container it would select through, not the control in the subtree.
    try expectIgnored(off.dispatch(.{
        .id = row_id,
        .action = .click,
        .generation = off.generation,
    }, &dispatcher, scratch), .unknown_node);
    try expectIgnored(off.dispatch(.{
        .id = tray.id,
        .action = .custom_action,
        .generation = off.generation,
        .row_index = 4,
    }, &dispatcher, scratch), .disabled);
    try expectIgnored(off.dispatch(.{
        .id = child.id,
        .action = .click,
        .generation = off.generation,
    }, &dispatcher, scratch), .disabled);
    try std.testing.expectEqual(@as(u32, 1), fixture.row_selections);
    try std.testing.expectEqual(@as(u32, 0), root.clicks);

    // Enabling the ancestor republishes the very same row identity, and the
    // row resolves through the tray's own CURRENT live owner again.
    root.disable_panel = false;
    try stageFrame(&fixture, &annotations);
    const back = fixture.publisher.snapshot().?;
    const restored = selectedRow(back, tray.id) orelse return error.MissingSelectedRow;
    try std.testing.expectEqual(row_id, restored.id);
    try std.testing.expectEqualStrings("row 2 #5002", restored.name);
    try std.testing.expectEqual(tray.id, restored.relations.member_of.?);
    try std.testing.expectEqual(@as(usize, 2), restored.relations.row_index.?);
    try std.testing.expect(!back.node(tray.id).?.states.disabled);
    const again = try expectRow(back.dispatch(.{
        .id = row_id,
        .action = .click,
        .generation = back.generation,
    }, &dispatcher, scratch));
    try std.testing.expectEqual(@as(usize, 2), again.index);
    try std.testing.expectEqual(@as(u32, 2), fixture.row_selections);
    try std.testing.expect(fixture.last_row_owner.eql(tray.owner));
}

test "api-w21 a selected row keeps its identity when a reorder moves its key" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .selected_row = 4 };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root, .swap_at = 4 };
    try stageFrame(&fixture, &annotations);

    const list = (try findByName(fixture.publisher.snapshot().?, "Library")).id;
    const before = selectedRow(fixture.publisher.snapshot().?, list) orelse
        return error.MissingSelectedRow;
    // The next frame rewrites this slot, so the observation is copied out
    // before anything is published again.
    const before_id = before.id;
    try std.testing.expectEqual(@as(u64, 1004), before.row.?.key);
    try std.testing.expectEqual(@as(usize, 4), before.relations.row_index.?);
    try std.testing.expectEqualStrings("row 4 #1004", before.name);

    // The key at row 4 now sits at row 5 and the app selects it there. A
    // reorder moves a position; it never creates a row.
    annotations.swap_keys = true;
    root.selected_row = 5;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const after = selectedRow(snapshot, list) orelse return error.MissingSelectedRow;
    try std.testing.expectEqual(before_id, after.id);
    try std.testing.expectEqual(@as(u64, 1004), after.row.?.key);
    try std.testing.expectEqual(@as(usize, 5), after.row.?.index);
    try std.testing.expectEqual(@as(usize, 5), after.relations.row_index.?);
    try std.testing.expectEqualStrings("row 5 #1004", after.name);
    try std.testing.expect(after.states.selected);
    try std.testing.expectEqual(list, after.relations.member_of.?);

    var name: [64]u8 = undefined;
    try std.testing.expect((try snapshot.virtualRow(list, 5, &name)).selected);
    // Row 4 is a different row now, so it is no longer the selection.
    try std.testing.expectEqual(@as(u64, 1005), (try snapshot.virtualRow(list, 4, &name)).key);
    try std.testing.expect(!(try snapshot.virtualRow(list, 4, &name)).selected);

    // Activating the row delivers the CURRENT position of that key through
    // the list's live owner, not the position it was first published at.
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    const resolved = try expectRow(snapshot.dispatch(.{
        .id = after.id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch));
    try std.testing.expectEqual(after.id, resolved.id);
    try std.testing.expectEqual(@as(usize, 5), resolved.index);
    try std.testing.expectEqual(@as(u64, 1004), resolved.key);
    try std.testing.expectEqual(@as(u32, 1), fixture.row_selections);
    try std.testing.expectEqual(@as(usize, 5), fixture.last_row_index);
    try std.testing.expectEqual(@as(u64, 1004), fixture.last_row_key);
    const owner = (try identityOf(&fixture, .{ .static = "list" })).owner;
    try std.testing.expect(fixture.last_row_owner.eql(owner));
}

test "api-w21 a removed selection and a stale row request reach nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // The viewport shows rows nowhere near row 4, so the selection is
    // published on its own and dropping it removes that node with it.
    var root: Root = .{ .fixture = &fixture, .selected_row = 4, .list_first_visible = 900 };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const list = (try findByName(fixture.publisher.snapshot().?, "Library")).id;
    const row_id = (selectedRow(fixture.publisher.snapshot().?, list) orelse
        return error.MissingSelectedRow).id;
    const stale_generation = fixture.publisher.snapshot().?.generation;

    // The app drops the selection, so the row node is no longer published.
    root.selected_row = null;
    root.lead_label = true;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    // The visible window is still published: those rows are on screen and a
    // screen reader can select any of them. What is gone is the row nobody
    // can see and nobody has selected.
    try std.testing.expect(publishedRows(snapshot, list) > 0);
    try std.testing.expect(selectedRow(snapshot, list) == null);
    try std.testing.expect(snapshot.node(row_id) == null);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    // A screen reader still holds the row it was handed. Neither the current
    // generation nor an older one may reach the model.
    try expectIgnored(snapshot.dispatch(.{
        .id = row_id,
        .action = .click,
        .generation = snapshot.generation,
    }, &dispatcher, scratch), .unknown_node);
    try expectIgnored(snapshot.dispatch(.{
        .id = row_id,
        .action = .custom_action,
        .generation = stale_generation,
    }, &dispatcher, scratch), .stale_generation);
    try std.testing.expectEqual(@as(u32, 0), fixture.row_selections);

    // Selecting that key again republishes the same identity, and only then
    // does an activation reach the model.
    root.selected_row = 4;
    try stageFrame(&fixture, &annotations);
    const restored = selectedRow(fixture.publisher.snapshot().?, list) orelse
        return error.MissingSelectedRow;
    try std.testing.expectEqual(row_id, restored.id);
    const resolved = try expectRow(fixture.publisher.snapshot().?.dispatch(.{
        .id = row_id,
        .action = .custom_action,
        .generation = fixture.publisher.snapshot().?.generation,
    }, &dispatcher, scratch));
    try std.testing.expectEqual(@as(usize, 4), resolved.index);
    try std.testing.expectEqual(@as(u32, 1), fixture.row_selections);
    try std.testing.expectEqual(@as(usize, 4), fixture.last_row_index);
}

test "api-w21 a selection outside the row count fails the frame instead of publishing it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const list = (try findByName(fixture.publisher.snapshot().?, "Library")).id;
    const published = fixture.publisher.snapshot().?;
    const before_generation = published.generation;
    const before_count = published.count();
    const row_id = (selectedRow(published, list) orelse
        return error.MissingSelectedRow).id;

    // The model shrank the list under a selection that no longer names a
    // row, so the whole frame is refused rather than a position announced
    // that no row can have.
    root.row_count = 5;
    try std.testing.expectError(error.InvalidSemanticRow, stage(&fixture, &annotations));
    fixture.publisher.abort();

    const after = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(before_generation, after.generation);
    try std.testing.expectEqual(before_count, after.count());
    try std.testing.expect(after.node(row_id) != null);
    try std.testing.expectEqual(@as(usize, 7), after.node(row_id).?.relations.row_index.?);
    try std.testing.expectEqual(@as(usize, 1_000_000), after.node(row_id).?.relations.row_count.?);

    // A selection inside the new count publishes, and the row count follows
    // the model rather than the other way round.
    root.selected_row = 4;
    try stageFrame(&fixture, &annotations);
    const fixed = fixture.publisher.snapshot().?;
    try std.testing.expect(fixed.generation > before_generation);
    const row = selectedRow(fixed, list) orelse return error.MissingSelectedRow;
    try std.testing.expect(row.id != row_id);
    try std.testing.expect(fixed.node(row_id) == null);
    try std.testing.expectEqual(@as(u64, 1004), row.row.?.key);
    try std.testing.expectEqual(@as(usize, 4), row.relations.row_index.?);
    try std.testing.expectEqual(@as(usize, 5), row.relations.row_count.?);
}

test "api-w21 an aborted stage discards the whole frame it built" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const before = fixture.publisher.snapshot().?;
    const before_generation = before.generation;
    const before_count = before.count();
    const check = try identityOf(&fixture, .{ .static = "check" });
    const second = try identityOf(&fixture, .{ .static = "second" });
    try std.testing.expectEqual(semantics.Checked.off, before.node(check.id).?.states.checked);
    try std.testing.expect(before.node(second.id) != null);

    // A complete frame that changes the model, built but never committed.
    root.checked = true;
    root.show_second = false;
    try stage(&fixture, &annotations);
    const staged = fixture.publisher.stagedSnapshot().?;
    try std.testing.expectEqual(semantics.Checked.on, staged.node(check.id).?.states.checked);
    try std.testing.expect(staged.node(second.id) == null);

    // The discard is total: what stays published is the frame before it.
    fixture.publisher.abort();
    const after = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(before_generation, after.generation);
    try std.testing.expectEqual(before_count, after.count());
    try std.testing.expectEqual(semantics.Checked.off, after.node(check.id).?.states.checked);
    try std.testing.expect(after.node(second.id) != null);
    // The discard is a publication boundary, not a model rollback: the app
    // state the reader has not seen yet is untouched.
    try std.testing.expect(root.checked);
    try std.testing.expect(!root.show_second);

    // The same model change publishes as soon as it is committed.
    try stageFrame(&fixture, &annotations);
    const committed = fixture.publisher.snapshot().?;
    try std.testing.expect(committed.generation > before_generation);
    try std.testing.expectEqual(semantics.Checked.on, committed.node(check.id).?.states.checked);
    try std.testing.expect(committed.node(second.id) == null);
}

test "api-w21 a text field publishes its characters as an addressable child run" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    // The characters are the node's VALUE, not only geometry the platform has
    // to compose out of a character table.
    try std.testing.expectEqualStrings("hello world", field.value.text);

    const run_id = field.text_run orelse return error.MissingTextRun;
    const run = snapshot.node(run_id) orelse return error.MissingTextRun;
    try std.testing.expectEqual(semantics.Role.text_run, run.role);
    try std.testing.expectEqual(field.id, run.parent);
    try std.testing.expectEqualStrings("hello world", run.value.text);
    try std.testing.expectEqual(@as(usize, 11), run.text.?.character_lengths.len);
    // The run is drawn inside its field, so it claims the field's box and
    // never an extent of its own that nobody measured.
    try std.testing.expectEqual(field.bounds.y, run.bounds.y);
    try std.testing.expectEqual(field.bounds.h, run.bounds.h);
    // Every edit on the run resolves through the field's live owner, so the
    // run itself carries no action: one text, one path into the model.
    try std.testing.expect(run.actions.isEmpty());
    try std.testing.expectEqual(field.owner, run.owner);

    // Typing does not create a second run. The identity is the owner's, so a
    // screen reader that is reading the field keeps the same run.
    annotations.text_value = "hello there";
    try stageFrame(&fixture, &annotations);
    const after = fixture.publisher.snapshot().?;
    const field_after = try findByName(after, "Library");
    try std.testing.expectEqual(run_id, field_after.text_run.?);
    try std.testing.expectEqualStrings("hello there", after.node(run_id).?.value.text);
}

test "api-w21 a selection resolves through its published run and keeps its direction" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const run = field.text_run.?;
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // Backwards: the user dragged from the end towards the start, and the
    // direction is what the ordinary text path is told about.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection_endpoints = .{
            .anchor = .{ .node = run, .offset = 7 },
            .focus = .{ .node = run, .offset = 2 },
        },
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqual(@as(usize, 7), fixture.text.selection.anchor);
    try std.testing.expectEqual(@as(usize, 2), fixture.text.selection.focus);
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);

    // The field itself names the same text, so either endpoint form resolves
    // to the same owner and the same model.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection_endpoints = .{
            .anchor = .{ .node = field.id, .offset = 1 },
            .focus = .{ .node = field.id, .offset = 4 },
        },
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.text.selection.anchor);

    // An endpoint past the last character has no position in this text, and
    // the edit is refused instead of clamped to the end.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection_endpoints = .{
            .anchor = .{ .node = run, .offset = 999 },
            .focus = .{ .node = run, .offset = 2 },
        },
    }, &dispatcher, scratch), .invalid_argument);
    try std.testing.expectEqual(@as(u32, 2), fixture.text_writes);
}

test "api-w21 a selection whose endpoints belong to another text is refused" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .show_notes = true };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    const field = try findByName(snapshot, "Library");
    const notes = try findByName(snapshot, "Notes");
    const field_run = field.text_run.?;
    const notes_run = notes.text_run.?;
    try std.testing.expect(field_run != notes_run);
    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();

    // Both endpoints in one field's own run: the ordinary case applies.
    try expectWidget(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection_endpoints = .{
            .anchor = .{ .node = field_run, .offset = 1 },
            .focus = .{ .node = field_run, .offset = 4 },
        },
    }, &dispatcher, scratch), field.owner.?);
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);

    // One endpoint in each field. A selection is an edit to ONE text, so
    // this is refused rather than applied to whichever came first.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection_endpoints = .{
            .anchor = .{ .node = field_run, .offset = 1 },
            .focus = .{ .node = notes_run, .offset = 4 },
        },
    }, &dispatcher, scratch), .foreign_text_selection);

    // The target does not own the text both endpoints name.
    try expectIgnored(snapshot.dispatch(.{
        .id = notes.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection_endpoints = .{
            .anchor = .{ .node = field_run, .offset = 1 },
            .focus = .{ .node = field_run, .offset = 4 },
        },
    }, &dispatcher, scratch), .foreign_text_selection);

    // An endpoint naming a node that publishes no text at all is not an
    // offset into anything.
    try expectIgnored(snapshot.dispatch(.{
        .id = field.id,
        .action = .set_text_selection,
        .generation = snapshot.generation,
        .selection_endpoints = .{
            .anchor = .{ .node = (try identityOf(&fixture, .{ .static = "first" })).id, .offset = 1 },
            .focus = .{ .node = field_run, .offset = 4 },
        },
    }, &dispatcher, scratch), .foreign_text_selection);

    // Nothing above touched the model.
    try std.testing.expectEqual(@as(u32, 1), fixture.text_writes);
}

test "api-w21 a virtualized list publishes selectable visible rows, not one row" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture, .selected_row = null };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    const container = try findByName(snapshot, "Library");
    // A container the platform will let a client select inside. A screen
    // reader offered only `Role.list` can read the list and never change it.
    try std.testing.expectEqual(semantics.Role.list_box, container.role);

    var visible: usize = 0;
    // The shared fixture also publishes controls and a text run here.
    // Query rows without changing their owning container.
    for (container.children) |child| {
        const entry = snapshot.node(child) orelse return error.MissingPublishedRow;
        const row = entry.row orelse continue;
        try std.testing.expectEqual(container.id, entry.parent);
        try std.testing.expectEqual(semantics.Role.list_item, entry.role);
        try std.testing.expectEqual(container.owner, entry.owner);
        try std.testing.expectEqual(visible, row.index);
        try std.testing.expectEqual(container.id, row.list);
        try std.testing.expectEqual(container.id, entry.relations.member_of.?);
        try std.testing.expectEqual(@as(usize, 1_000_000), entry.relations.row_count.?);
        try std.testing.expectEqual(semantics.rowNodeId(container.id, row.key), entry.id);
        // Every row the viewport shows is selectable: that is what makes a
        // list row addressable rather than decorative.
        try std.testing.expect(entry.actions.has(.click));
        try std.testing.expect(entry.actions.has(.custom_action));
        try std.testing.expect(!entry.states.selected);
        // Truthful geometry: the row is drawn where the container draws it,
        // never outside it and never on top of the container itself.
        try std.testing.expect(entry.bounds.h > 0);
        try std.testing.expectEqual(container.bounds.x, entry.bounds.x);
        try std.testing.expectEqual(container.bounds.w, entry.bounds.w);
        try std.testing.expect(entry.bounds.y >= container.bounds.y);
        try std.testing.expect(
            entry.bounds.y + entry.bounds.h <= container.bounds.y + container.bounds.h,
        );
        visible += 1;
    }
    // Two is the floor a collapsed or short list still publishes, and a
    // million-row list never publishes more than its viewport holds.
    try std.testing.expect(visible >= 2);
    try std.testing.expect(visible <= semantics.max_visible_rows);
}

test "api-w21 a row the viewport scrolled past is published without a false position" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // The app scrolled far down and selected a row above the viewport.
    var root: Root = .{ .fixture = &fixture, .selected_row = 2, .list_first_visible = 40 };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const snapshot = fixture.publisher.snapshot().?;
    const container = try findByName(snapshot, "Library");
    const selected = selectedRow(snapshot, container.id) orelse
        return error.MissingSelectedRow;
    // The selection stays addressable even off screen, which is the whole
    // reason it is published at all.
    try std.testing.expectEqual(@as(usize, 2), selected.relations.row_index.?);
    // It is not drawn anywhere, and the published box says exactly that.
    // Claiming the container's own rectangle would put an invisible row on
    // top of every visible one.
    try std.testing.expectEqual(@as(f32, 0), selected.bounds.w);
    try std.testing.expectEqual(@as(f32, 0), selected.bounds.h);
    try std.testing.expect(selected.actions.has(.click));

    // The rows the viewport actually shows start where the app says they do.
    var first: usize = 40;
    var seen: usize = 0;
    for (container.children) |child| {
        const entry = snapshot.node(child) orelse return error.MissingPublishedRow;
        const row = entry.row orelse continue;
        try std.testing.expectEqual(container.id, entry.parent);
        if (row.index < 40) continue;
        try std.testing.expectEqual(first, row.index);
        first += 1;
        seen += 1;
        try std.testing.expect(entry.bounds.h > 0);
    }
    try std.testing.expect(seen >= 2);

    // Selecting a row the viewport shows moves the mark, not the identity.
    root.selected_row = 41;
    try stageFrame(&fixture, &annotations);
    const after = fixture.publisher.snapshot().?;
    const moved = selectedRow(after, container.id) orelse
        return error.MissingSelectedRow;
    try std.testing.expect(moved.id != selected.id);
    try std.testing.expectEqual(@as(usize, 41), moved.relations.row_index.?);
}

test "api-w21 a native request survives an intervening frame" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);

    const first = try identityOf(&fixture, .{ .static = "first" });
    const published = fixture.publisher.snapshot().?.generation;

    // A repaint that changed nothing the request names. No accessibility bus
    // reports which frame a client's tree came from, so a native request
    // carries no generation and must not be refused for outliving one.
    root.checked = true;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    try std.testing.expect(snapshot.generation > published);
    try std.testing.expect(snapshot.node(first.id) != null);

    const dispatcher = fixture.dispatcher();
    const scratch = fixture.scratch();
    try expectWidget(snapshot.dispatch(.{
        .id = first.id,
        .action = .click,
        .generation = null,
    }, &dispatcher, scratch), first.owner);
    try std.testing.expectEqual(@as(u32, 1), fixture.activations);
}

test "api-w21 keyed progress publishes a stable read-only numeric range" {
    const ProgressRoot = struct {
        const Self = @This();

        value: f32 = 60,
        label: []const u8 = "Transfer",

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.progress(.{
                .key = ComponentKey{ .static = "transfer" },
                .label = self.label,
                .value = self.value,
                .min = 10,
                .max = 110,
                .width = 240,
                .height = 12,
            });
        }
    };
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: ProgressRoot = .{};
    try fixture.app.mountRoot(ProgressRoot, &root);
    fixture.app.semantic_publication = .{ .publisher = &fixture.publisher };

    const first = try fixture.app.frame(0, surface);
    const snapshot = first.semantic_snapshot orelse return error.MissingSemanticSnapshot;
    const entry = try findByName(snapshot, "Transfer");
    const id = entry.id;
    try std.testing.expectEqual(semantics.Role.progress_indicator, entry.role);
    try std.testing.expectEqual(@as(f64, 60), entry.value.number);
    try std.testing.expectEqual(@as(f64, 10), entry.range.?.min);
    try std.testing.expectEqual(@as(f64, 110), entry.range.?.max);
    try std.testing.expectEqual(@as(?f64, 0.5), entry.range.?.percent);
    try std.testing.expect(entry.states.read_only);
    try std.testing.expect(!entry.states.focusable);
    const dispatcher = fixture.dispatcher();
    try expectIgnored(snapshot.dispatch(.{
        .id = id,
        .action = .set_value,
        .number = 81,
    }, &dispatcher, fixture.scratch()), .unsupported_action);
    try std.testing.expectEqual(@as(f32, 60), root.value);
    try std.testing.expectEqual(@as(u32, 0), fixture.number_writes);

    root.value = 85;
    root.label = "Updated caption";
    const second = try fixture.app.frame(1, surface);
    const changed = second.semantic_snapshot.?.node(id) orelse return error.LostProgressIdentity;
    try std.testing.expectEqualStrings("Updated caption", changed.name);
    try std.testing.expectEqual(@as(f64, 85), changed.value.number);
    try std.testing.expectEqual(@as(?f64, 0.75), changed.range.?.percent);
}

test "api-w21 radio checked state follows real activation and deselection" {
    const RadioRoot = struct {
        const Self = @This();

        selected: ?u32 = 1,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.row(.{ .width = 240 });
            defer ctx.pop();
            _ = try ctx.radio(.{
                .key = ComponentKey{ .static = "first-radio" },
                .label = "First option",
                .selected = &self.selected,
                .option = 1,
            });
            _ = try ctx.radio(.{
                .key = ComponentKey{ .static = "second-radio" },
                .label = "Second option",
                .selected = &self.selected,
                .option = 2,
            });
        }
    };
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: RadioRoot = .{};
    try fixture.app.mountRoot(RadioRoot, &root);
    fixture.app.semantic_publication = .{ .publisher = &fixture.publisher };
    const first = try fixture.app.frame(0, surface);
    const snapshot = first.semantic_snapshot orelse return error.MissingSemanticSnapshot;
    const one = try findByName(snapshot, "First option");
    const two = try findByName(snapshot, "Second option");
    const one_id = one.id;
    const two_id = two.id;
    try std.testing.expect(one.states.selected);
    try std.testing.expect(!two.states.selected);
    try std.testing.expectEqual(semantics.Checked.on, one.states.checked);
    try std.testing.expectEqual(semantics.Checked.off, two.states.checked);

    const dispatcher = fixture.dispatcher();
    try expectWidget(snapshot.dispatch(.{
        .id = two_id,
        .action = .click,
    }, &dispatcher, fixture.scratch()), two.owner.?);
    try std.testing.expectEqual(@as(?u32, 2), root.selected);
    try std.testing.expectEqual(@as(u32, 1), fixture.activations);
    const second = try fixture.app.frame(1, surface);
    const changed = second.semantic_snapshot.?;
    try std.testing.expectEqual(semantics.Checked.off, changed.node(one_id).?.states.checked);
    try std.testing.expectEqual(semantics.Checked.on, changed.node(two_id).?.states.checked);
    try std.testing.expect(!changed.node(one_id).?.states.selected);
    try std.testing.expect(changed.node(two_id).?.states.selected);

    root.selected = null;
    const third = try fixture.app.frame(2, surface);
    const cleared = third.semantic_snapshot.?;
    try std.testing.expectEqual(semantics.Checked.off, cleared.node(one_id).?.states.checked);
    try std.testing.expectEqual(semantics.Checked.off, cleared.node(two_id).?.states.checked);
    try std.testing.expect(!cleared.node(one_id).?.states.selected);
    try std.testing.expect(!cleared.node(two_id).?.states.selected);
}

// A hidden node is unreachable in EVERY published respect, not merely in its
// action set. It used to keep `focusable` and `focused`, and both focus
// publication paths accepted it, so a snapshot could name a node the core
// refuses every action on as the one holding the caret.
test "api-w21 a hidden node publishes no focusable or focused state and never holds focus" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    try stageFrame(&fixture, &annotations);
    const button = try identityOf(&fixture, .{ .static = "first" });

    // The button is a real focusable control, so it is the one node the
    // ordinary focus path can actually place the caret on.
    {
        const live = fixture.publisher.snapshot().?;
        try std.testing.expect(live.node(button.id).?.states.focusable);
        try expectWidget(live.dispatch(.{
            .id = button.id,
            .action = .focus,
            .generation = live.generation,
        }, &fixture.dispatcher(), fixture.scratch()), button.owner);
        try std.testing.expectEqual(@as(u32, 1), fixture.focus_set);
    }
    try stageFrame(&fixture, &annotations);
    try std.testing.expectEqual(button.id, fixture.publisher.snapshot().?.focus);

    // That same widget still holds the keyboard focus. Publishing it as
    // visually hidden must not move the published caret onto a node no action
    // can reach, and must not leave it announced as focusable either.
    root.hide_first = true;
    try stageFrame(&fixture, &annotations);
    const snapshot = fixture.publisher.snapshot().?;
    const hidden = snapshot.node(button.id).?;
    try std.testing.expect(hidden.states.hidden);
    try std.testing.expect(hidden.states.outOfReach());
    try std.testing.expect(hidden.actions.isEmpty());
    try std.testing.expect(!hidden.actions.has(.focus));
    try std.testing.expect(!hidden.actions.has(.blur));
    try std.testing.expect(!hidden.states.focusable);
    try std.testing.expect(!hidden.states.focused);
    try std.testing.expect(!hidden.isInteractive());
    try std.testing.expectEqual(semantics.no_node, snapshot.focus);
    // The APP still holds focus on it: only the PUBLICATION refuses to claim
    // the caret sits where nothing can reach it.
    try std.testing.expect(fixture.app.focus_manager.current.?.eql(button.owner));

    // Unhiding republishes the focus the app actually holds, on the same node.
    root.hide_first = false;
    try stageFrame(&fixture, &annotations);
    const restored = fixture.publisher.snapshot().?;
    try std.testing.expectEqual(button.id, restored.focus);
    try std.testing.expect(restored.node(button.id).?.states.focused);
    try std.testing.expect(restored.node(button.id).?.states.focusable);
}

// The same contract through the App's own transaction, where the focused
// owner is reconciled by `commitFocused` rather than by the staged frame.
test "api-w21 App focus reconciliation never publishes a hidden node as focused" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var annotations: Annotations = .{ .root = &root };
    fixture.app.semantic_publication = .{
        .publisher = &fixture.publisher,
        .annotator = .{ .context = &annotations, .annotate = Annotations.annotate },
    };

    const first = try fixture.app.frame(0, surface);
    const button = (try findByName(first.semantic_snapshot.?, "First")).owner orelse
        return error.MissingSemanticOwner;
    try std.testing.expect(fixture.app.focus_manager.set(first.tree, button, null));

    root.hide_first = true;
    const hidden_frame = try fixture.app.frame(1, surface);
    const snapshot = hidden_frame.semantic_snapshot.?;
    const hidden = try findByName(snapshot, "First");
    try std.testing.expect(hidden.states.hidden);
    try std.testing.expect(!hidden.states.focusable);
    try std.testing.expect(!hidden.states.focused);
    try std.testing.expectEqual(semantics.no_node, snapshot.focus);
    // The committed focus the App holds is untouched: the publication is what
    // refused to point a reader at an unreachable node.
    try std.testing.expect(hidden_frame.focus.?.eql(button));

    root.hide_first = false;
    const restored = (try fixture.app.frame(2, surface)).semantic_snapshot.?;
    try std.testing.expectEqual(semantics.nodeId(button, .self_node), restored.focus);
    try std.testing.expect(restored.node(restored.focus).?.states.focused);
}

// `VirtualList.name` promises that a name too long for the caller's buffer is
// published UNNAMED rather than cut in half. The materialized row honoured
// that; the row a reader addresses BY INDEX truncated instead, so one row
// could be announced under two different names depending on how it was
// reached.
test "api-w21 a row name too long for the buffer is unnamed, never cut in half" {
    const Overflowing = struct {
        const Self = @This();

        /// The annotated container is published exactly once, so one list
        /// answers every assertion below.
        done: bool = false,
        /// Switches the accessor between the two shapes under test: one that
        /// reports more bytes than it was handed, and one that fits.
        fits: bool = false,
        /// Fills the buffer and then reports far more bytes than it was
        /// handed: the one contract violation a row name can commit.
        const reported: usize = 8192;

        fn name(context: *anyopaque, _: u64, index: usize, buf: []u8) usize {
            const self: *Self = @ptrCast(@alignCast(context));
            if (!self.fits) {
                @memset(buf, 'x');
                return reported;
            }
            const written = std.fmt.bufPrint(buf, "whole row {d}", .{index}) catch return 0;
            return written.len;
        }

        fn key(_: *anyopaque, index: usize) u64 {
            return @as(u64, @intCast(index)) + 9000;
        }

        fn annotate(
            context: *anyopaque,
            node: *const WidgetNode,
            draft: *semantics.Draft,
        ) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.done or node.kind != .column) return;
            self.done = true;
            draft.publish = true;
            draft.name = "Overflowing";
            draft.list = .{
                .keys = .{ .context = self, .at = key },
                .row_count = 8,
                .row_height = 24,
                .name = name,
                .context = self,
            };
        }
    };

    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var root: Root = .{ .fixture = &fixture };
    try fixture.app.mountRoot(Root, &root);
    var overflowing: Overflowing = .{};
    const output = (try fixture.app.handle(.{
        .frame = .{ .tick = @intCast(fixture.app.frame_generation + 1), .time_ms = 0 },
    })) orelse return error.MissingFrameOutput;
    try fixture.publisher.stage(.{
        .tree = output.tree,
        .focus = output.focus,
        .generation = fixture.app.frame_generation,
        .surface = surface,
        .window_name = "Fixture",
        .annotator = .{ .context = &overflowing, .annotate = Overflowing.annotate },
    });
    fixture.publisher.commit();

    const snapshot = fixture.publisher.snapshot().?;
    const list = (try findByName(snapshot, "Overflowing")).id;

    // A MATERIALIZED row publishes the name whole or not at all.
    var materialized: usize = 0;
    for (snapshot.nodes) |entry| {
        const row = entry.row orelse continue;
        if (row.list != list) continue;
        materialized += 1;
        try std.testing.expectEqualStrings("", entry.name);
    }
    try std.testing.expect(materialized > 0);

    // The INDEX-ADDRESSED row speaks the SAME name: unnamed, not half a name.
    // Eight bytes cannot hold what the accessor claims to have written.
    var name_buf: [8]u8 = undefined;
    const described = try snapshot.virtualRow(list, 3, &name_buf);
    try std.testing.expectEqualStrings("", described.name);
    try std.testing.expectEqual(@as(usize, 3), described.index);
    try std.testing.expectEqual(@as(u64, 9003), described.key);

    // And so does the row an applied index-addressed selection reports, whose
    // buffer is the caller's own scratch rather than the core's fixed one.
    const dispatcher = fixture.dispatcher();
    const applied = try expectRow(snapshot.dispatch(.{
        .id = list,
        .action = .custom_action,
        .generation = snapshot.generation,
        .row_index = 3,
    }, &dispatcher, .{ .row_name = &name_buf, .text_value = &fixture.buffer }));
    try std.testing.expectEqualStrings("", applied.name);
    try std.testing.expectEqual(@as(u64, 9003), applied.key);
    try std.testing.expectEqual(@as(usize, 1), fixture.row_selections);

    // The refusal is about the OVERFLOW, not about the accessor: the same
    // shape of list with a name that fits still speaks it, by index and as a
    // materialized row alike.
    overflowing.done = false;
    overflowing.fits = true;
    const next = (try fixture.app.handle(.{
        .frame = .{ .tick = @intCast(fixture.app.frame_generation + 1), .time_ms = 0 },
    })) orelse return error.MissingFrameOutput;
    try fixture.publisher.stage(.{
        .tree = next.tree,
        .focus = next.focus,
        .generation = fixture.app.frame_generation,
        .surface = surface,
        .window_name = "Fixture",
        .annotator = .{ .context = &overflowing, .annotate = Overflowing.annotate },
    });
    fixture.publisher.commit();
    const fitting = fixture.publisher.snapshot().?;
    var roomy: [64]u8 = undefined;
    try std.testing.expectEqualStrings("whole row 4", (try fitting.virtualRow(list, 4, &roomy)).name);
    // And so is every row the container DID materialize. WHICH indices those
    // are belongs to the container's own box, so the expectation follows each
    // row's index instead of naming one: a viewport that shows four rows has
    // no node for the fifth, and that is the window's business, not this
    // rule's.
    var named_rows: usize = 0;
    for (fitting.nodes) |entry| {
        const row = entry.row orelse continue;
        if (row.list != list) continue;
        named_rows += 1;
        var expected: [64]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "whole row {d}", .{row.index}),
            entry.name,
        );
    }
    try std.testing.expect(named_rows > 0);
}
