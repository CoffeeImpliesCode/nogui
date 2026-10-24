//! Committed typed semantic snapshot for assistive technologies.
//!
//! A snapshot is built from ONE successfully prepared widget tree. It is a
//! typed value graph, not JSON: roles, names, descriptions, shortcuts, states,
//! values, ranges, relations, text-selection geometry and the virtualized
//! list relationship are first-class fields that a native adapter consumes
//! directly.
//!
//! Invariants:
//!   * A node's identity is a pure function of the live stable owner
//!     (registry owner + slot + generation) and a structural scope. Translated
//!     names, labels, indices and message keys are never identity, so
//!     reordering the tree never recreates an unrelated node.
//!   * A node hidden through itself or an ancestor is not published at all, so
//!     no native action can reach it. An annotated `Draft.hidden` node is
//!     published but carries no action, no focusable state and no focused
//!     state, so a node nobody can act on is never published as the one
//!     holding the caret.
//!   * A disabled node is published so a screen reader announces the state,
//!     and it publishes no action and no focusable state.
//!   * Modality is AUTHORED. `Draft.modal` is its only source, so no control
//!     becomes modal by accident and a screen reader is told the truth about
//!     which subtree owns input.
//!   * A node that owns characters publishes them as ONE text-run child, so
//!     the platform reads the field's text through the run rather than
//!     through geometry the field happens to carry. The run's identity is a
//!     pure function of the field's owner, so an edit republishes the same
//!     run and never a second one.
//!   * A committed frame OWNS the characters it publishes: the value, the
//!     placeholder and all three character tables are frozen into the slot at
//!     staging, and a field and its run are given the SAME copy. A model edit
//!     that lands after the frame was staged cannot rewrite what an already
//!     committed frame describes, so a published value and the table that
//!     describes it always come from one moment.
//!   * A node that owns characters accepts the WHOLE value a provider sends on
//!     `set_value` and writes it through the ordinary text path with the caret
//!     collapsed after its last byte. A read-only node accepts no contents
//!     action at all, even one an app forced into its action set, while a
//!     selection still moves there: moving a caret changes no contents.
//!   * A value the model cannot hold is refused, never clipped. A bounded
//!     whole-text setter states how many bytes it accepts, and a value past
//!     that bound changes nothing at all: no composition is cancelled, no
//!     caret moves, and no character is cut in half to make room. A client
//!     that typed forty characters and read back thirty-nine has been lied to
//!     about the app's own model.
//!   * An edit is composed against the LIVE model, never against a published
//!     run. A screen reader may send two edits before the app republishes, so
//!     the second one has to splice into the bytes the first edit produced.
//!     The frozen frame is what the platform READS; it is not what the model
//!     HOLDS. A model that states no live text cannot be composed against at
//!     all, so it is refused rather than served published bytes a queued edit
//!     has already replaced.
//!   * An ordinary replacement takes the live selection's span and a
//!     positioned edit takes the scalar range the request names. Both resolve
//!     against the same live bytes, compose once, and call the ordinary text
//!     path exactly once, so a native edit and a typed one change the same
//!     model the same way.
//!   * `read_only` means NO CONTENTS MUTATION, and a numeric value is contents
//!     exactly as characters are. A read-only control publishes its value and
//!     range so a screen reader announces them, and refuses every write to
//!     them: `set_value` with a number, `increment` and `decrement` are all
//!     ignored with `Failure.unsupported_action`, whether the refusal comes
//!     from the node's own policy or from a bit the app forced into its
//!     action set. The flag is additive, so it never takes a built-in action
//!     away and never clears a read-only the built-in policy already set.
//!   * A virtualized list publishes the rows its viewport shows, each as a
//!     real child node: those rows are addressable and selectable, and a
//!     row's extent is where the viewport draws it. The app's current
//!     selection is published even when the viewport does not show it, so a
//!     selection stays addressable; rows nobody sees keep their index
//!     relationship and are reached by index, so a million-row list costs
//!     one container plus the rows on screen.
//!   * A row's identity is the stable key, so a reorder moves its position
//!     without recreating it, and a screen reader can address and select it.
//!   * Every published node except the window root is a child of another
//!     published node, and every relation target exists in the same snapshot.
//!   * Building is staged. `Publisher.commit` swaps the whole snapshot or
//!     nothing, so a failed frame never publishes half a tree.
//!   * Bounds are LOGICAL window coordinates. Physical-pixel and platform
//!     origin conversion belongs to the native edge adapter.
const std = @import("std");
const widget = @import("widget.zig");
const element = @import("element.zig");
const focus = @import("focus.zig");
const input = @import("input.zig");
const uniform_list = @import("uniform_list.zig");

const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const WidgetNode = widget.WidgetNode;
const WidgetTree = widget.WidgetTree;
const Rect = widget.Rect;
pub const Size = widget.Size;

pub const Error = error{
    /// Two published nodes derived the same identity. Never resolved by
    /// renumbering: a duplicate identity silently merges two controls.
    SemanticIdentityCollision,
    /// A published node or relation targets an identity outside the snapshot.
    DanglingSemanticRelation,
    /// The published node count exceeded the per-frame bound.
    SemanticCapacityExceeded,
    /// A virtualized row index is outside the reported row count.
    InvalidSemanticRow,
    /// A row action targeted a node that publishes no list.
    NotAList,
    /// A node was forced published without a stable owner.
    UnstableSemanticNode,
    /// The window root is missing from the tree.
    InvalidSemanticRoot,
    /// The per-node annotator failed. The staged frame is discarded whole.
    AnnotationFailed,
} || std.mem.Allocator.Error;

/// A node identifier inside one published snapshot.
pub const NodeId = u64;

/// Reserved: "no node". Requests and relations use it for absence.
pub const no_node: NodeId = 0;
/// The window root of every snapshot. Fixed so an adapter can attach the
/// tree to its window without discovering the root.
pub const window_node: NodeId = 1;

/// Structural scope of a node inside its owner. A widget publishes one
/// structural node; an authored text run and a virtualized row publish their
/// own scope so they never collide with the owner.
pub const Scope = enum(u8) {
    self_node = 0,
    text_run = 1,
    list_row = 2,
};

fn awayFromReserved(mixed: u64) NodeId {
    // 0 and 1 are reserved. Fold a hash that lands there into the reserved
    // range rather than letting it alias the window root or the absence marker.
    return if (mixed < window_node + 1) mixed + window_node + 1 else mixed;
}

/// Mix a stable owner and a structural scope into a node identity.
pub fn nodeId(owner: WidgetId, scope: Scope) NodeId {
    var bytes: [17]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], owner.owner, .little);
    std.mem.writeInt(u32, bytes[8..12], owner.slot, .little);
    std.mem.writeInt(u32, bytes[12..16], owner.generation, .little);
    bytes[16] = @backingInt(scope);
    return awayFromReserved(std.hash.Wyhash.hash(0x5E4D_0000, &bytes));
}

/// Deterministic identity for a virtualized row this frame did not build.
pub fn rowNodeId(list: NodeId, key: u64) NodeId {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], list, .little);
    std.mem.writeInt(u64, bytes[8..16], key, .little);
    return awayFromReserved(std.hash.Wyhash.hash(0x5E4D_5257, &bytes));
}

/// Platform-neutral role. Values are the AccessKit role wire values, so the
/// Unix bridge forwards them without a second translation table and a later
/// macOS or Windows adapter maps the same neutral value.
pub const Role = enum(u8) {
    unknown = 0,
    text_run = 1,
    label = 3,
    image = 4,
    list_item = 7,
    generic_container = 14,
    check_box = 15,
    radio_button = 16,
    text_input = 17,
    button = 18,
    list = 24,
    switch_control = 29,
    multiline_text_input = 31,
    search_input = 32,
    dialog = 66,
    group = 78,
    list_box = 87,
    progress_indicator = 101,
    radio_group = 102,
    scroll_view = 108,
    slider = 113,
    spin_button = 114,
    tab = 120,
    tab_list = 121,
    tab_panel = 122,
    toolbar = 127,
    tooltip = 128,
    window = 133,

    /// Map the coarse element semantic hook onto the neutral role set.
    pub fn fromElement(role: element.Role) Role {
        return switch (role) {
            .image => .image,
            .group => .group,
            .text => .text_run,
            .control => .button,
        };
    }
};

/// One native action. Values are the AccessKit action wire values.
pub const Action = enum(u8) {
    click = 0,
    focus = 1,
    blur = 2,
    collapse = 3,
    expand = 4,
    custom_action = 5,
    decrement = 6,
    increment = 7,
    replace_selected_text = 10,
    scroll_down = 11,
    scroll_up = 14,
    scroll_into_view = 15,
    set_text_selection = 18,
    set_value = 20,
};

/// The actions a node accepts. An absent bit means "not supported", which an
/// adapter reports as absence rather than as a rejected request.
pub const ActionSet = packed struct(u16) {
    click: bool = false,
    focus: bool = false,
    blur: bool = false,
    collapse: bool = false,
    expand: bool = false,
    custom_action: bool = false,
    decrement: bool = false,
    increment: bool = false,
    replace_selected_text: bool = false,
    scroll_down: bool = false,
    scroll_up: bool = false,
    scroll_into_view: bool = false,
    set_text_selection: bool = false,
    set_value: bool = false,
    _reserved: u2 = 0,

    pub fn has(self: ActionSet, action: Action) bool {
        return switch (action) {
            .click => self.click,
            .focus => self.focus,
            .blur => self.blur,
            .collapse => self.collapse,
            .expand => self.expand,
            .custom_action => self.custom_action,
            .decrement => self.decrement,
            .increment => self.increment,
            .replace_selected_text => self.replace_selected_text,
            .scroll_down => self.scroll_down,
            .scroll_up => self.scroll_up,
            .scroll_into_view => self.scroll_into_view,
            .set_text_selection => self.set_text_selection,
            .set_value => self.set_value,
        };
    }

    pub fn enable(self: *ActionSet, action: Action) void {
        switch (action) {
            .click => self.click = true,
            .focus => self.focus = true,
            .blur => self.blur = true,
            .collapse => self.collapse = true,
            .expand => self.expand = true,
            .custom_action => self.custom_action = true,
            .decrement => self.decrement = true,
            .increment => self.increment = true,
            .replace_selected_text => self.replace_selected_text = true,
            .scroll_down => self.scroll_down = true,
            .scroll_up => self.scroll_up = true,
            .scroll_into_view => self.scroll_into_view = true,
            .set_text_selection => self.set_text_selection = true,
            .set_value => self.set_value = true,
        }
    }

    /// True when no action at all is offered.
    pub fn isEmpty(self: ActionSet) bool {
        return @as(u16, @bitCast(self)) == 0;
    }
};

pub const Checked = enum { not_toggleable, off, on, mixed };

/// Per-node state. `hidden` is only ever set by an explicit annotation; a
/// hidden subtree is omitted from the snapshot instead.
pub const States = struct {
    hidden: bool = false,
    disabled: bool = false,
    focused: bool = false,
    focusable: bool = false,
    selected: bool = false,
    expanded: bool = false,
    expandable: bool = false,
    checked: Checked = .not_toggleable,
    required: bool = false,
    invalid: bool = false,
    modal: bool = false,
    multiselectable: bool = false,
    read_only: bool = false,
    busy: bool = false,
    live_region: bool = false,
    /// True when no native action can reach this node at all.
    ///
    /// A hidden node is announced but not seen and a disabled node is
    /// announced as out of reach, so neither can be a focus target: a reader
    /// pointed at a node it may never act on has been lied to about where the
    /// caret is. This is the ONE definition of that answer, so a node cannot
    /// be unreachable through its actions and reachable through its focus.
    pub fn outOfReach(self: States) bool {
        return self.hidden or self.disabled;
    }
};

pub const Value = union(enum) {
    none,
    text: []const u8,
    number: f64,
};

/// A numeric range. `step` is absent when the control has no meaningful
/// increment; `percent` is the normalized progress of a bounded indicator.
pub const Range = struct {
    min: f64,
    max: f64,
    step: ?f64 = null,
    percent: ?f64 = null,
};

/// A selection in UTF-8 byte offsets into `Text.value`.
pub const TextSelection = struct {
    anchor: usize,
    focus: usize,

    pub fn caret(at: usize) TextSelection {
        return .{ .anchor = at, .focus = at };
    }

    pub fn isEmpty(self: TextSelection) bool {
        return self.anchor == self.focus;
    }

    /// Order-independent span.
    pub fn span(self: TextSelection) struct { start: usize, end: usize } {
        return if (self.anchor <= self.focus)
            .{ .start = self.anchor, .end = self.focus }
        else
            .{ .start = self.focus, .end = self.anchor };
    }
};

/// A text run with optional per-character geometry.
///
/// `character_lengths` holds one UTF-8 byte length per character index.
/// `character_positions` and `character_widths` hold one x advance per
/// character index in the node's LOGICAL coordinate space; an adapter scales
/// the coordinates when they cross the platform edge.
///
/// Annotation slices must remain valid until `Publisher.stage` returns.
/// Staging copies the value, placeholder and three tables into the publishing
/// slot. Published slices follow the snapshot's lifetime; later model writes
/// cannot change them.
pub const Text = struct {
    value: []const u8,
    placeholder: []const u8 = "",
    selection: ?TextSelection = null,
    multiline: bool = false,
    character_lengths: []const u8 = &.{},
    character_positions: []const f32 = &.{},
    character_widths: []const f32 = &.{},

    /// A tableless run can address only an empty value's collapsed caret.
    pub fn addressable(self: Text) bool {
        const selection = self.selection orelse return false;
        if (self.character_lengths.len > 0) return true;
        return self.value.len == 0 and selection.isEmpty() and selection.anchor == 0;
    }
};

/// Typed relations to other nodes in the same snapshot.
pub const Relations = struct {
    controls: []const NodeId = &.{},
    active_descendant: ?NodeId = null,
    described_by: []const NodeId = &.{},
    labelled_by: []const NodeId = &.{},
    flow_to: ?[]const NodeId = null,
    details: ?[]const NodeId = null,
    owns: ?[]const NodeId = null,
    member_of: ?NodeId = null,
    radio_group: ?NodeId = null,
    error_message: ?NodeId = null,
    /// Position within the owning set.
    position_in_set: ?usize = null,
    /// Row position inside a list, when the node is a list row.
    row_index: ?usize = null,
    row_count: ?usize = null,
};

/// A named native action addressed by `Request.custom_action`.
pub const CustomAction = struct {
    id: i32,
    name: []const u8,
};

/// A virtualized list published without materializing its rows.
///
/// The container reports the full row count and publishes the rows its
/// viewport actually shows, each as a real child node: those rows are
/// addressable and selectable, which is what the platform list relationship
/// needs, and they are the only rows a screen reader can see a position for.
/// Every other row stays reachable through `Snapshot.virtualRow` and
/// `Action.custom_action` by index, so a million-row list costs one
/// container plus the rows on screen.
///
/// The app's current selection is published whether or not the viewport
/// shows it, because a selection nobody can address is a selection nobody
/// can hear about. A row outside the viewport publishes NO extent, which is
/// the truth: it is not drawn anywhere.
///
/// `selected_index` is a POSITION; the row's identity is derived from
/// `keys.keyAt(selected_index)`, never from the position. A reorder therefore
/// moves the published row's `row_index` and leaves its node identity alone.
///
/// Most rows one list publishes as real nodes in one frame, whatever the
/// container's own height says. This is a publish budget: past it the
/// remaining rows keep their index-addressed path and no screen reader is
/// shown a position the frame cannot afford to publish.
pub const max_visible_rows: usize = 256;

/// The half-open window of rows a list viewport shows.
pub const VisibleRows = struct {
    start: usize,
    len: usize,

    pub fn end(self: VisibleRows) usize {
        return self.start + self.len;
    }
};

pub const VirtualList = struct {
    /// Stable per-row key accessor. Row identity is the key, never the index,
    /// so a reorder keeps a row's identity.
    keys: uniform_list.Keys,
    /// Total logical rows, including rows this frame never built.
    row_count: usize,
    /// Uniform row height in LOGICAL pixels.
    row_height: f32,
    /// Position the app currently considers selected, or null. The core
    /// rejects a position outside `row_count` rather than publishing a
    /// selection no row can have.
    selected_index: ?usize = null,
    /// Whether a screen reader may move the selection between rows.
    selectable: bool = true,
    /// Position of the row drawn at the top of the container's box. The core
    /// places later rows below it, so a list that scrolled publishes rows
    /// where they are on screen rather than where they were before.
    first_visible: usize = 0,
    /// How many rows the container's box shows. Null derives the count from
    /// that box and `row_height`, which is what an app that never scrolls
    /// wants; an authored count wins, because only the app knows where its
    /// rows start inside a container it also padded or clipped.
    visible_rows: ?usize = null,
    /// Copies a row's accessible name into `buf` and returns the byte count.
    /// Returning 0, or more than `buf.len`, publishes an unnamed row rather
    /// than a wrong one: the published row's name is truncated to nothing,
    /// never cut in half.
    name: *const fn (context: *anyopaque, key: u64, index: usize, buf: []u8) usize,
    context: *anyopaque,

    /// The rows this container shows, from its own box and row height.
    ///
    /// The floor of two is what makes a collapsed or short list still
    /// addressable: a screen reader can select a row of a list that is
    /// scrolled out of its own viewport, and both such rows publish no
    /// extent rather than a false one.
    pub fn visible(self: VirtualList, bounds: Rect) VisibleRows {
        const start = @min(self.first_visible, self.row_count);
        const authored = self.visible_rows orelse derivedRowCount(bounds.h, self.row_height);
        const room = self.row_count - start;
        return .{
            .start = start,
            // The publish budget, not a silent cutoff: a container taller
            // than it publishes its first rows, and every other row is still
            // reachable by index through `Snapshot.virtualRow`.
            .len = @min(authored, @min(room, max_visible_rows)),
        };
    }
};

/// Rows a viewport of `height` shows at `row_height`.
///
/// The ceiling includes a row partly visible at the bottom edge; adding a
/// further row would publish an empty extent as visible. A non-positive
/// height, or a height no row fits in, still yields two addressable rows:
/// the list has a position, and a screen reader must be able to move the
/// selection in a list that has not been scrolled yet.
fn derivedRowCount(height: f32, row_height: f32) usize {
    const shown: usize = if (row_height > 0 and std.math.isFinite(row_height) and
        height > 0 and std.math.isFinite(height))
        @as(usize, @intFromFloat(@ceil(@as(f64, @floatCast(height)) /
            @as(f64, @floatCast(row_height)))))
    else
        2;
    return @max(shown, 2);
}

/// Longest accessible name the core copies for a published row. A longer
/// name is published unnamed rather than truncated, so the bound is a
/// published-row budget and not a silent cutoff.
pub const max_row_name_bytes: usize = 512;

/// A published node that stands for ONE row of a virtualized list.
///
/// The row has no widget of its own, so every action on it resolves through
/// the owning list's live owner: one activation path, one model, one edit.
pub const RowRef = struct {
    /// The list node that published the row.
    list: NodeId,
    /// Position inside the list this frame.
    index: usize,
    /// Stable row key. This is the row's identity.
    key: u64,
};

/// A virtualized row this frame did not build as a widget.
pub const VirtualRow = struct {
    id: NodeId,
    list: NodeId,
    index: usize,
    key: u64,
    selected: bool,
    /// Borrowed from the caller's buffer; valid while that buffer is.
    name: []const u8,
};

/// One published node.
pub const Node = struct {
    id: NodeId,
    parent: NodeId,
    role: Role,
    /// The live stable owner. Null only for the window root.
    owner: ?WidgetId = null,
    /// LOGICAL window-space border box. Never physical pixels.
    bounds: Rect = .{},
    name: []const u8 = "",
    description: []const u8 = "",
    /// Keyboard shortcut text, e.g. "Ctrl+S". Documentation only.
    shortcut: []const u8 = "",
    /// Announced in place of the raw value when the value is not speakable.
    value_description: []const u8 = "",
    states: States = .{},
    value: Value = .none,
    range: ?Range = null,
    relations: Relations = .{},
    text: ?Text = null,
    /// The published run that carries this node's characters, when the node
    /// owns any. A screen reader addresses a text field's characters through
    /// that run and through no other node, so the run's identity is named
    /// here rather than left for an adapter to rediscover. Null on a node
    /// that carries no text of its own.
    text_run: ?NodeId = null,
    actions: ActionSet = .{},
    custom_actions: []const CustomAction = &.{},
    /// Present only on a node that publishes a virtualized row set.
    list: ?VirtualList = null,
    /// Present only on a node that stands for one row of a virtualized list.
    /// The row has no widget, so its actions resolve through the list owner.
    row: ?RowRef = null,
    /// Direct children, in published order. Virtual rows can share the
    /// container with authored controls and its own text run.
    children: []const NodeId = &.{},

    /// A node is actionable only when it is visible, enabled and carries at
    /// least one action. A screen reader must never be offered an action the
    /// app would refuse.
    pub fn isInteractive(self: Node) bool {
        if (self.states.outOfReach()) return false;
        return !self.actions.isEmpty() or self.custom_actions.len != 0;
    }
};

/// Per-node annotations supplied by the application.
///
/// Every field is optional: with no annotator the built-in policy publishes a
/// complete control tree. Every slice but `text` is BORROWED and must outlive
/// the snapshot. A text run is COPIED into the slot that publishes it, because
/// its bytes are the model's own and a native edit rewrites them after the
/// frame that staged them. The App wires the same frame arena, so the rest of
/// a draft still costs nothing to publish.
pub const Draft = struct {
    /// Force publication of a node the built-in policy omits, or suppress an
    /// otherwise published node. Null keeps the built-in decision. Forcing
    /// publication requires a stable owner, so an unkeyed decorative node
    /// cannot become an unaddressable screen-reader stop.
    publish: ?bool = null,
    /// Replaces the built-in accessible name. Never an identity input.
    name: ?[]const u8 = null,
    description: []const u8 = "",
    shortcut: []const u8 = "",
    value_description: []const u8 = "",
    text: ?Text = null,
    /// Publishes this node as a virtualized list container.
    list: ?VirtualList = null,
    /// Replaces the built-in role.
    role: ?Role = null,
    active_descendant: ?NodeId = null,
    controls: []const NodeId = &.{},
    labelled_by: []const NodeId = &.{},
    described_by: []const NodeId = &.{},
    flow_to: ?[]const NodeId = null,
    details: ?[]const NodeId = null,
    owns: ?[]const NodeId = null,
    radio_group: ?NodeId = null,
    error_message: ?NodeId = null,
    row_index: ?usize = null,
    row_count: ?usize = null,
    custom_actions: []const CustomAction = &.{},
    /// Replaces the supported action set. Null keeps the built-in set.
    actions: ?ActionSet = null,
    /// Publishes the node as visually hidden: announced but not seen, and
    /// carrying no action, no focusable state and no focused state.
    hidden: bool = false,
    /// Overrides the focused state the built-in policy computed.
    focused: ?bool = null,
    /// Publishes the node as modal: a screen reader treats its subtree as the
    /// only place input belongs. Null leaves the built-in state, which is
    /// never modal, so modality is always an explicit authoring decision.
    modal: ?bool = null,
    /// Publishes this node's CONTENTS as uneditable: announced, read and
    /// selectable, but carrying no action that would change what it shows.
    /// Characters and a numeric value are both contents, so this refuses a
    /// string or number on `set_value` and refuses `increment` and
    /// `decrement` as well, whatever an authored `actions` set stated. It is
    /// additive: it never removes a built-in action, and it never takes
    /// `read_only` off a node the built-in policy already published as
    /// read-only.
    read_only: bool = false,
};

/// Annotator hook. Leaving fields unset keeps their built-in value. The hook
/// must not retain the node pointer.
pub const Annotator = struct {
    context: ?*anyopaque = null,
    annotate: ?*const fn (*anyopaque, *const WidgetNode, *Draft) anyerror!void = null,
};

/// One committed semantic snapshot.
///
/// The snapshot borrows its staging storage. Two snapshots are never live at
/// once: the Publisher alternates slots exactly like `App.arenas`, so the
/// published snapshot stays readable while the next frame builds.
pub const Snapshot = struct {
    /// The App frame generation that produced this snapshot. A native request
    /// computed against an older generation is stale by construction.
    generation: u64,
    root: NodeId,
    /// The node holding keyboard focus, or `no_node`.
    focus: NodeId,
    nodes: []const Node,
    index: *const std.AutoHashMapUnmanaged(NodeId, u32),

    pub fn node(self: *const Snapshot, id: NodeId) ?*const Node {
        const slot = self.index.get(id) orelse return null;
        return &self.nodes[slot];
    }

    pub fn count(self: *const Snapshot) usize {
        return self.nodes.len;
    }

    /// The virtualized list published by `id`, or null.
    pub fn list(self: *const Snapshot, id: NodeId) ?VirtualList {
        const entry = self.node(id) orelse return null;
        return entry.list;
    }

    /// Build the semantic node for a row this frame did not materialize.
    ///
    /// The caller owns `name_buf`; the returned name borrows it. Nothing is
    /// allocated, so a screen reader can walk a million-row list.
    pub fn virtualRow(
        self: *const Snapshot,
        list_id: NodeId,
        index: usize,
        name_buf: []u8,
    ) Error!VirtualRow {
        const entry = self.node(list_id) orelse return error.NotAList;
        const published = entry.list orelse return error.NotAList;
        if (index >= published.row_count) return error.InvalidSemanticRow;
        return describeRow(published, entry.id, index, name_buf);
    }

    /// Run a native request through the application seams.
    ///
    /// The request resolves a stable live owner and reuses the ordinary
    /// activation, edit and focus path, so a native edit and a pointer edit
    /// change the same model exactly once. Every rejection is explicit: a
    /// native client is never told a change happened when the model did not
    /// change.
    pub fn dispatch(
        self: *const Snapshot,
        request: Request,
        dispatcher: *const Dispatcher,
        scratch: Scratch,
    ) Outcome {
        return dispatchImpl(self, request, dispatcher, scratch);
    }
};

/// The bytes of a row name that may be published, from what its accessor
/// reported and the buffer it was handed.
///
/// A name that does not fit is dropped WHOLE. A name cut in half announces a
/// control that does not exist, and an unnamed row still speaks. One rule, so
/// a row published as a node and the same row reached by index cannot drift
/// into announcing it differently.
fn rowNameLength(written: usize, capacity: usize) usize {
    return if (written <= capacity) written else 0;
}

fn describeRow(
    published: VirtualList,
    list: NodeId,
    index: usize,
    name_buf: []u8,
) VirtualRow {
    const key = published.keys.keyAt(index);
    const written = published.name(published.context, key, index, name_buf);
    // A row reached by index and a row published as a node answer to ONE
    // rule, or the same control would be announced under two names depending
    // on which path reached it.
    const name_len = rowNameLength(written, name_buf.len);
    return .{
        .id = rowNodeId(list, key),
        .list = list,
        .index = index,
        .key = key,
        .selected = published.selected_index == @as(?usize, index),
        .name = name_buf[0..name_len],
    };
}

/// What a native adapter asks the snapshot to do.
pub const Request = struct {
    id: NodeId,
    action: Action,
    /// The published generation the request was computed against. Null skips
    /// the check, and it is what a NATIVE request carries: no accessibility
    /// bus reports which frame a client's tree came from, so a stamped
    /// generation would be the adapter's own frame counter and would reject
    /// every valid action that outlived one harmless repaint. What actually
    /// makes such a request stale is identity, which embeds the owner's
    /// generation: a control that was replaced or removed stops resolving,
    /// and a character index the republish no longer has is refused. Set it
    /// only when the caller really holds a generation to compare against.
    generation: ?u64 = null,
    /// Payload for `set_value`, `increment` and `decrement`.
    number: ?f64 = null,
    /// Payload for `replace_selected_text`, and for `set_value` when the
    /// provider sent the field's whole new value. Null on a numeric
    /// `set_value`, which carries `number` instead.
    text: ?[]const u8 = null,
    /// Positional payload for `replace_selected_text`, legal on no other
    /// action and never alongside `text` or any other payload: it names one
    /// edit, and two answers are not one request.
    edit: ?TextRangeEdit = null,
    /// Payload for `set_text_selection` when both endpoints sit in the
    /// target's own text. Use `selection_endpoints` when the platform names
    /// the text each endpoint is into.
    selection: ?TextSelection = null,
    /// Payload for `set_text_selection` from a platform that addresses each
    /// endpoint by the node its characters live in, which is what AT-SPI
    /// does: it reports the offsets inside the text run a screen reader
    /// actually addressed, and the request target is the field around it.
    /// The owner is resolved from the endpoints, so a selection can never be
    /// applied to a text the endpoints do not belong to.
    selection_endpoints: ?SelectionEndpoints = null,
    /// Payload for a `custom_action`, e.g. a virtualized row selection.
    custom_action: ?i32 = null,
    /// Row index for a virtualized list `custom_action`.
    row_index: ?usize = null,
};

/// One endpoint of a text selection, resolved into the core's own units.
pub const TextEndpoint = struct {
    /// The published node whose characters `offset` is a position in. That
    /// is the field itself or the run it published.
    node: NodeId,
    /// UTF-8 byte offset into that node's `text.value`. The adapter converts
    /// the platform's characters into this, so the offset always lands on a
    /// character boundary or is refused.
    offset: usize,
};

/// Both endpoints of a selection, with their directions intact. Anchor and
/// focus are NOT ordered here: a backwards selection is a real selection,
/// and the ordinary text path is told which end the user dragged.
pub const SelectionEndpoints = struct {
    anchor: TextEndpoint,
    focus: TextEndpoint,
};

/// One positioned replacement inside the target's OWN live characters.
///
/// The platform counts characters where the model counts bytes, so `start`
/// and `end` are Unicode-scalar indices into the LIVE value, not byte
/// offsets and not positions in a published character table: a republish
/// that has not happened yet says nothing about where a client may type.
/// The span is half-open, so `start == end` is a pure insertion. A reversed
/// span names no range at all and is refused.
///
/// `node` names the text the positions are in: the field itself or the run
/// it published. Either resolves to the same owner, so a client that
/// addressed the run edits the field, and text another control published is
/// refused rather than edited.
pub const TextRangeEdit = struct {
    node: NodeId,
    start: usize,
    end: usize,
    bytes: []const u8,
};

pub const Failure = enum {
    /// The identity is absent from this snapshot: removed, replaced by a new
    /// generation, or never published.
    unknown_node,
    /// The request was computed against a different published generation.
    stale_generation,
    /// The node is published as visually hidden.
    hidden,
    /// The node is published as disabled.
    disabled,
    /// The node does not offer this action, or the node is read-only and this
    /// action would change what it shows.
    unsupported_action,
    /// The app wired no handler for this action, or wired no getter for the
    /// LIVE text a composition has to splice into.
    no_handler,
    /// The action payload is missing, reversed, out of range, not UTF-8, or
    /// too large for the model that would have had to hold it.
    invalid_argument,
    /// A row action targeted a node that publishes no list.
    not_a_list,
    /// The request named text this node does not own, or text two different
    /// owners each published.
    foreign_text_selection,
};

/// The stable target a request resolved to.
pub const Target = union(enum) {
    /// A live committed widget. The identity is the same one the ordinary
    /// pointer, keyboard and focus paths use.
    widget: WidgetId,
    /// A virtualized row this frame did not build.
    row: VirtualRow,
};

pub const Outcome = union(enum) {
    applied: Target,
    ignored: Failure,
};

/// The model's own characters, borrowed for one synchronous dispatch.
///
/// A composition has to splice into what the model holds NOW: a client may
/// send a second edit before the app republishes, and a span computed from
/// the published frame would land inside bytes the first edit already
/// replaced. Nothing here is a fallback and nothing here is cached.
pub const TextEditState = struct {
    /// The whole live value, in UTF-8. Borrowed until the dispatch returns.
    value: []const u8,
    /// Where the caret or selection sits in `value`, as UTF-8 byte offsets.
    selection: TextSelection,
    /// The most whole-value bytes this model accepts, which is its buffer
    /// length rather than the room left in it. A model that grows on demand
    /// states `std.math.maxInt(usize)`. A capacity smaller than `value.len`
    /// is invalid state: the core refuses such an edit instead of reading it
    /// as an instruction to truncate.
    capacity: usize,
};

/// Caller-owned buffers for payloads the core composes instead of allocating.
pub const Scratch = struct {
    /// Holds a virtualized row name.
    row_name: []u8,
    /// Holds a composed text value for `replace_selected_text`. A request
    /// whose result does not fit is refused, never truncated, and the bound
    /// is the smaller of this buffer and the model's own capacity. It must
    /// not overlap the live value `read_text` lends, because the core
    /// composes into it while holding that borrow.
    text_value: []u8 = &.{},

    /// Room for one row name and one composed text edit.
    pub const default_capacity: usize = 4096;
};

/// The application seams a native action must travel through.
///
/// Every entry is the ordinary input path. A native adapter must not have a
/// second way to mutate a control: one model, one edit.
pub const Dispatcher = struct {
    context: *anyopaque,
    /// The same path as pointer release and keyboard Enter/Space.
    activate: *const fn (*anyopaque, WidgetId) void,
    /// Focus or blur through the ordinary focus manager.
    focus: *const fn (*anyopaque, ?WidgetId) void,
    /// Apply a numeric value through the ordinary control value path.
    set_number: ?*const fn (*anyopaque, WidgetId, f64) bool = null,
    /// Read the live numeric value. A screen reader may send two steps before
    /// the app republishes, and a step computed from the published value would
    /// collapse them. Null falls back to the published value.
    read_number: ?*const fn (*anyopaque, WidgetId) ?f64 = null,
    /// Apply a text edit and selection through the ordinary text path.
    ///
    /// A non-null `value` is the field's ENTIRE new contents: empty bytes
    /// and bytes that borrow the published run or the model's own buffer
    /// are whole writes too. Intent is never read from a pointer, a length,
    /// an equality or which buffer owns them. A null `value` is a
    /// selection-only request, which moves no character byte, no character
    /// table and no marked composition.
    ///
    /// `selection` is always present and always UTF-8 byte offsets. On a
    /// whole write it addresses the supplied value. On a selection-only it
    /// addresses the model's LIVE value: the core has bounded it to the
    /// published run, and the callback applies or clamps it against the
    /// bytes the model holds now. A selection still moves on a read-only
    /// model; no contents do.
    ///
    /// The call is synchronous, on the caller's thread, during
    /// `Snapshot.dispatch`. `value` is borrowed until the callback returns:
    /// keep no reference to it, and do not mutate the active snapshot or its
    /// publisher while it runs. A null handler or false return produces
    /// `Failure.no_handler`.
    set_text: ?*const fn (*anyopaque, WidgetId, ?[]const u8, TextSelection) bool = null,
    /// Read the model's LIVE characters, selection and whole-value bound.
    ///
    /// A `replace_selected_text` is composed against what this returns and
    /// against nothing else: the published run is a frozen frame, and a
    /// queued edit has already moved the bytes that frame describes. A null
    /// seam, or a null result from a wired one, is a model that states no
    /// live text, so the composition is refused instead of being served
    /// published bytes.
    ///
    /// A whole `set_value` needs no live characters and is never gated on
    /// this seam; where the seam IS wired, its capacity still bounds the
    /// value before the setter is asked to take it.
    ///
    /// The borrow lasts through the current dispatch only. It must not
    /// overlap the replacement bytes or `Scratch.text_value`: the core
    /// composes into scratch while holding it, and the setter may invalidate
    /// it the moment the composition is handed over.
    read_text: ?*const fn (*anyopaque, WidgetId) ?TextEditState = null,
    /// Reveal and select a virtualized row this frame did not build.
    select_row: ?*const fn (*anyopaque, WidgetId, usize, u64) bool = null,
    /// Scroll the owning container so the node becomes visible.
    scroll_into_view: ?*const fn (*anyopaque, WidgetId) bool = null,
};

fn dispatchImpl(
    self: *const Snapshot,
    request: Request,
    dispatcher: *const Dispatcher,
    scratch: Scratch,
) Outcome {
    if (request.generation) |generation| {
        if (generation != self.generation) return .{ .ignored = .stale_generation };
    }
    const entry = self.node(request.id) orelse return .{ .ignored = .unknown_node };
    if (entry.states.hidden) return .{ .ignored = .hidden };
    if (entry.states.disabled) return .{ .ignored = .disabled };
    if (!entry.actions.has(request.action)) return .{ .ignored = .unsupported_action };

    // A positioned edit is one payload of one action, so on anything else it
    // is refused rather than quietly ignored: a client that built the wrong
    // request is told so instead of watching nothing happen.
    if (request.edit != null and request.action != .replace_selected_text) {
        return .{ .ignored = .invalid_argument };
    }

    // A virtualized list container answers two shapes of `custom_action`, and
    // the request says which one it is. A logical row names the position it
    // wants, and the app's own named action names the descriptor the platform
    // clicked. The row shape stays the row path: a row has no widget of its
    // own, so the container is the only node that can act on it. The named
    // shape falls through to the branch below, which resolves the declared ID
    // and activates this container's live owner once, through the same door a
    // click uses. Its own text, value and focus actions use that door too.
    if (entry.list != null and request.action == .custom_action and request.row_index != null) {
        return dispatchRow(entry, entry.list.?, request, dispatcher, scratch);
    }

    // A published row node is a relationship, not a widget: it carries the
    // row's key space identity, so its action resolves through the list that
    // published it. This is the platform's list-selection call.
    if (entry.row) |row| {
        return dispatchPublishedRow(self, entry, row, request, dispatcher);
    }

    const owner = entry.owner orelse return .{ .ignored = .unknown_node };
    switch (request.action) {
        .click => {
            dispatcher.activate(dispatcher.context, owner);
            return .{ .applied = .{ .widget = owner } };
        },
        .focus => {
            dispatcher.focus(dispatcher.context, owner);
            return .{ .applied = .{ .widget = owner } };
        },
        .blur => {
            dispatcher.focus(dispatcher.context, null);
            return .{ .applied = .{ .widget = owner } };
        },
        .set_value => {
            // One wire action, two payload shapes: a number for a control
            // that publishes a range, and the field's whole new characters
            // for a control that owns text. Which one arrived is decided by
            // the payload, because that is what the provider sent.
            if (request.text != null) {
                return dispatchSetValueText(entry, owner, request, dispatcher);
            }
            // Policy before plumbing, exactly as the string route does it: a
            // read-only control refuses a number even when the app forced
            // this action into its own action set. Its value and range stay
            // published, so a screen reader announces them and cannot write
            // them.
            if (entry.states.read_only) return .{ .ignored = .unsupported_action };
            const set = dispatcher.set_number orelse return .{ .ignored = .no_handler };
            const number = request.number orelse return .{ .ignored = .invalid_argument };
            const bounds = entry.range orelse return .{ .ignored = .invalid_argument };
            if (!std.math.isFinite(number)) return .{ .ignored = .invalid_argument };
            if (number < bounds.min or number > bounds.max) {
                return .{ .ignored = .invalid_argument };
            }
            if (!set(dispatcher.context, owner, number)) return .{ .ignored = .no_handler };
            return .{ .applied = .{ .widget = owner } };
        },
        .increment, .decrement => {
            // A read-only control is announced, not driven: no step reaches
            // the model, whatever the app stated about its action set.
            if (entry.states.read_only) return .{ .ignored = .unsupported_action };
            const set = dispatcher.set_number orelse return .{ .ignored = .no_handler };
            const bounds = entry.range orelse return .{ .ignored = .invalid_argument };
            const step = bounds.step orelse return .{ .ignored = .unsupported_action };
            if (!std.math.isFinite(step) or step == 0) {
                return .{ .ignored = .unsupported_action };
            }
            const current = if (dispatcher.read_number) |read|
                read(dispatcher.context, owner) orelse
                    return .{ .ignored = .no_handler }
            else switch (entry.value) {
                .number => |number| number,
                else => return .{ .ignored = .invalid_argument },
            };
            const delta = if (request.action == .increment) step else -step;
            const next = std.math.clamp(current + delta, bounds.min, bounds.max);
            if (!set(dispatcher.context, owner, next)) return .{ .ignored = .no_handler };
            return .{ .applied = .{ .widget = owner } };
        },
        .set_text_selection => {
            if (request.selection_endpoints) |endpoints| {
                return dispatchSelection(self, entry, endpoints, dispatcher);
            }
            const set = dispatcher.set_text orelse return .{ .ignored = .no_handler };
            const text = entry.text orelse return .{ .ignored = .unsupported_action };
            const selection = request.selection orelse return .{ .ignored = .invalid_argument };
            if (selection.anchor > text.value.len or selection.focus > text.value.len) {
                return .{ .ignored = .invalid_argument };
            }
            // A selection carries no contents, so the model is handed none:
            // a null value cannot be mistaken for bytes to write, and the
            // published run never travels back into the model as an edit.
            if (!set(dispatcher.context, owner, null, selection)) {
                return .{ .ignored = .no_handler };
            }
            return .{ .applied = .{ .widget = owner } };
        },
        .replace_selected_text => {
            return dispatchReplaceText(self, entry, owner, request, dispatcher, scratch);
        },
        .scroll_into_view => {
            const reveal = dispatcher.scroll_into_view orelse return .{ .ignored = .no_handler };
            if (!reveal(dispatcher.context, owner)) return .{ .ignored = .no_handler };
            return .{ .applied = .{ .widget = owner } };
        },
        .custom_action => {
            if (entry.custom_actions.len == 0) return .{ .ignored = .unsupported_action };
            const wanted = request.custom_action orelse return .{ .ignored = .invalid_argument };
            for (entry.custom_actions) |action| {
                if (action.id == wanted) {
                    dispatcher.activate(dispatcher.context, owner);
                    return .{ .applied = .{ .widget = owner } };
                }
            }
            return .{ .ignored = .unsupported_action };
        },
        .expand, .collapse, .scroll_up, .scroll_down => {
            return .{ .ignored = .unsupported_action };
        },
    }
}

/// Apply the whole value a platform sent on `set_value`.
///
/// A provider does not compose an edit the way a keyboard does: it hands
/// over the field's ENTIRE new contents, so there is no span to splice and
/// nothing to compose into scratch. The bytes travel straight to the
/// ordinary text path with the caret collapsed after the last one, which is
/// where the caret lands when the same value is typed by hand. A node that
/// publishes no characters cannot take a string value, and a read-only node
/// takes no contents at all.
///
/// A whole write needs no live characters, so it is not gated on the getter:
/// an app that never states a bound still takes the value its model always
/// took. Where the getter IS wired, its capacity is the model's own answer
/// to "can you hold this", and it is checked HERE, before the setter is
/// asked to take it, so an oversized value never cancels a composition or
/// moves a caret on the way to being refused.
fn dispatchSetValueText(
    entry: *const Node,
    owner: WidgetId,
    request: Request,
    dispatcher: *const Dispatcher,
) Outcome {
    if (entry.text == null) return .{ .ignored = .invalid_argument };
    // Policy before plumbing: a read-only node refuses even when the app
    // forced this action into its own action set.
    if (entry.states.read_only) return .{ .ignored = .unsupported_action };
    const set = dispatcher.set_text orelse return .{ .ignored = .no_handler };
    const value = request.text orelse return .{ .ignored = .invalid_argument };
    if (dispatcher.read_text) |read| {
        // A getter that states nothing about this widget is no answer at
        // all, so the write goes through exactly as it always did.
        if (read(dispatcher.context, owner)) |live| {
            if (live.capacity < live.value.len) return .{ .ignored = .invalid_argument };
            if (value.len > live.capacity) return .{ .ignored = .invalid_argument };
        }
    }
    if (!set(dispatcher.context, owner, value, TextSelection.caret(value.len))) {
        return .{ .ignored = .no_handler };
    }
    return .{ .applied = .{ .widget = owner } };
}

/// A half-open span of one value: `start` is inclusive, `end` exclusive.
const ByteSpan = struct {
    start: usize,
    end: usize,
};

/// Apply one text replacement to the LIVE model.
///
/// Two shapes share this door because they are one edit. An ORDINARY
/// replacement takes the span the live selection covers, which is what a
/// keystroke or a paste over a marked range does. A POSITIONED one takes the
/// scalar range the request names, which is what AT-SPI InsertText and
/// DeleteText ask for when the client never had a selection at all. Both
/// resolve against the same live bytes, compose once into the caller's
/// scratch, and call the ordinary text path exactly once.
///
/// Everything is decided BEFORE that one call: policy, payload exclusivity,
/// ownership of the named text, UTF-8, live boundaries and the model's
/// bound. A request that fails any of them leaves the model, its caret and
/// its marked composition exactly as they were, because nothing was
/// cancelled and nothing was half-written on the way to the refusal.
fn dispatchReplaceText(
    self: *const Snapshot,
    entry: *const Node,
    owner: WidgetId,
    request: Request,
    dispatcher: *const Dispatcher,
    scratch: Scratch,
) Outcome {
    // A read-only field is read and its caret moves, but nothing that would
    // change what it shows reaches the model, even when the app forced this
    // action into its own action set.
    if (entry.states.read_only) return .{ .ignored = .unsupported_action };
    const set = dispatcher.set_text orelse return .{ .ignored = .no_handler };
    // The node has to publish characters to be a text at all. Which bytes
    // they are is not asked here: the published run is a frozen frame and
    // the model may already have moved past it.
    if (entry.text == null) return .{ .ignored = .unsupported_action };

    const edit = request.edit;
    // A named range and an ordinary payload are two answers to one request.
    if (edit != null and request.text != null) {
        return .{ .ignored = .invalid_argument };
    }

    // A range names the text its positions are in, and that text has to be
    // THIS owner's. A run is published by the control that owns the
    // characters, so either name resolves to the same owner, while text
    // another control published is refused instead of being edited through
    // whichever owner happened to answer first.
    if (edit) |range| {
        const named = self.node(range.node) orelse return .{ .ignored = .unknown_node };
        const named_owner = named.owner orelse return .{ .ignored = .unknown_node };
        if (!named_owner.eql(owner)) return .{ .ignored = .foreign_text_selection };
        if (named.text == null) return .{ .ignored = .foreign_text_selection };
        // A reversed range names no range at all.
        if (range.start > range.end) return .{ .ignored = .invalid_argument };
    }

    const replacement = if (edit) |range|
        range.bytes
    else
        request.text orelse return .{ .ignored = .invalid_argument };
    // Bytes that are not UTF-8 would be spliced into a value the app can
    // never publish and the model can never read back, so they are refused
    // before a single byte moves.
    if (!std.unicode.utf8ValidateSlice(replacement)) {
        return .{ .ignored = .invalid_argument };
    }

    const live = readLiveText(dispatcher, owner) orelse
        return .{ .ignored = .no_handler };
    // A model that cannot hold what it already holds is in no state to be
    // edited, and its capacity is never read as an instruction to shorten
    // the value into the room that is left.
    if (live.capacity < live.value.len) return .{ .ignored = .invalid_argument };

    // A positioned range is resolved against the bytes the model holds NOW:
    // the platform counts characters, the model counts bytes, and a
    // republish that has not happened yet is no evidence that a position is
    // still there. An ordinary replacement takes the live selection's own
    // span instead, because that is what a caret and a marked range are.
    const span = if (edit) |range|
        scalarSpan(live.value, range.start, range.end)
    else
        liveSelectionSpan(live);
    const resolved = span orelse return .{ .ignored = .invalid_argument };

    // The bound is checked BEFORE the two lengths are added, so a request
    // that cannot fit is refused instead of wrapping into a short
    // composition that would corrupt the value around it.
    const limit = @min(live.capacity, scratch.text_value.len);
    const kept = live.value.len - (resolved.end - resolved.start);
    if (replacement.len > limit) return .{ .ignored = .invalid_argument };
    if (kept > limit - replacement.len) return .{ .ignored = .invalid_argument };
    const composed = kept + replacement.len;
    const out = scratch.text_value[0..composed];
    @memcpy(out[0..resolved.start], live.value[0..resolved.start]);
    @memcpy(out[resolved.start..][0..replacement.len], replacement);
    @memcpy(out[resolved.start + replacement.len ..], live.value[resolved.end..]);

    // The caret is computed while the composition is still whole, because
    // the setter is free to invalidate the live bytes the moment it takes
    // what it was handed.
    const caret = TextSelection.caret(resolved.start + replacement.len);
    if (!set(dispatcher.context, owner, out, caret)) return .{ .ignored = .no_handler };
    return .{ .applied = .{ .widget = owner } };
}

/// The model's own characters, borrowed for this dispatch only.
///
/// A model that wires no getter cannot be composed against at all, and one
/// that wires a getter which states nothing about this widget has not
/// answered either. Both are refused here rather than served the published
/// frame, because that frame describes a moment the model has already left.
fn readLiveText(dispatcher: *const Dispatcher, owner: WidgetId) ?TextEditState {
    const read = dispatcher.read_text orelse return null;
    return read(dispatcher.context, owner);
}

/// The span an ordinary replacement covers: the live selection's own
/// normal span, direction and all.
///
/// Both endpoints must sit inside the live value AND on a character
/// boundary, because a caret that splits a scalar is not a position any
/// model can act on. An empty selection is a pure insertion at the caret.
fn liveSelectionSpan(live: TextEditState) ?ByteSpan {
    const span = live.selection.span();
    if (span.end > live.value.len) return null;
    if (!atScalarBoundary(live.value, span.start)) return null;
    if (!atScalarBoundary(live.value, span.end)) return null;
    return .{ .start = span.start, .end = span.end };
}

/// Resolve two Unicode-scalar indices into byte offsets in ONE forward walk.
///
/// The value is decoded as it is walked, so an index that lands inside a
/// character, or a value that is not UTF-8 at all, resolves to nothing
/// instead of to an offset that would split a scalar. The walk advances at
/// least one byte per step or gives up, so a hostile index cannot keep it
/// running: `nextScalar` fails the moment the offset leaves the value.
fn scalarSpan(value: []const u8, first: usize, second: usize) ?ByteSpan {
    var at: usize = 0;
    var index: usize = 0;
    while (index < first) {
        at = nextScalar(value, at) orelse return null;
        index += 1;
    }
    const start = at;
    while (index < second) {
        at = nextScalar(value, at) orelse return null;
        index += 1;
    }
    return .{ .start = start, .end = at };
}

/// The offset of the character after the one starting at `at`, or null when
/// `at` is out of range, is not a sequence start, or runs past the end.
fn nextScalar(value: []const u8, at: usize) ?usize {
    if (at >= value.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(value[at]) catch return null;
    if (length > value.len - at) return null;
    return at + length;
}

/// True when `offset` is a position between two whole characters.
fn atScalarBoundary(value: []const u8, offset: usize) bool {
    if (offset == 0) return true;
    if (offset == value.len) return true;
    // A continuation byte is the tail of a sequence, so the offset in front
    // of it is the middle of a character and names no position.
    return (value[offset] & 0b1100_0000) != 0b1000_0000;
}

/// Apply a selection whose endpoints named the text they sit in.
///
/// The platform names the node each endpoint is a position in, and the two
/// names are checked against the request target BEFORE the offsets are
/// used: a selection is an edit to one text, so endpoints from two fields,
/// or from a field the target is not, are refused rather than applied to
/// whichever text happened to be first in the snapshot.
fn dispatchSelection(
    self: *const Snapshot,
    entry: *const Node,
    endpoints: SelectionEndpoints,
    dispatcher: *const Dispatcher,
) Outcome {
    const set = dispatcher.set_text orelse return .{ .ignored = .no_handler };
    const text = entry.text orelse return .{ .ignored = .unsupported_action };
    const owner = entry.owner orelse return .{ .ignored = .unknown_node };
    for ([_]TextEndpoint{ endpoints.anchor, endpoints.focus }) |endpoint| {
        const source = self.node(endpoint.node) orelse
            return .{ .ignored = .unknown_node };
        // The endpoint must be a position in text THIS node published. A run
        // is published by the control that owns the characters, so the two
        // carry the same owner and either name resolves here.
        const source_owner = source.owner orelse return .{ .ignored = .unknown_node };
        if (!source_owner.eql(owner)) return .{ .ignored = .foreign_text_selection };
        if (source.text == null) return .{ .ignored = .foreign_text_selection };
    }

    if (endpoints.anchor.offset > text.value.len or
        endpoints.focus.offset > text.value.len)
    {
        return .{ .ignored = .invalid_argument };
    }

    // The selection reaches the model with NO contents: the core bounded both
    // endpoints against the published run above, and the callback clamps them
    // against the value the model holds at that moment.
    if (!set(dispatcher.context, owner, null, .{
        .anchor = endpoints.anchor.offset,
        .focus = endpoints.focus.offset,
    })) {
        return .{ .ignored = .no_handler };
    }
    return .{ .applied = .{ .widget = owner } };
}

fn dispatchRow(
    entry: *const Node,
    published: VirtualList,
    request: Request,
    dispatcher: *const Dispatcher,
    scratch: Scratch,
) Outcome {
    if (request.action != .custom_action) return .{ .ignored = .unsupported_action };
    if (!published.selectable) return .{ .ignored = .unsupported_action };
    const select = dispatcher.select_row orelse return .{ .ignored = .no_handler };
    const owner = entry.owner orelse return .{ .ignored = .unknown_node };
    const index = request.row_index orelse return .{ .ignored = .invalid_argument };
    if (index >= published.row_count) return .{ .ignored = .invalid_argument };
    const key = published.keys.keyAt(index);
    if (!select(dispatcher.context, owner, index, key)) return .{ .ignored = .no_handler };
    return .{ .applied = .{ .row = describeRow(published, entry.id, index, scratch.row_name) } };
}

/// Resolve an action on a published row node through its list.
///
/// The row's own identity already names the key and the position, so the
/// request needs no payload: a screen reader clicking the selected list item
/// selects it, exactly as clicking it in the window would.
fn dispatchPublishedRow(
    self: *const Snapshot,
    entry: *const Node,
    row: RowRef,
    request: Request,
    dispatcher: *const Dispatcher,
) Outcome {
    switch (request.action) {
        .click, .custom_action => {},
        else => return .{ .ignored = .unsupported_action },
    }
    const list_node = self.node(row.list) orelse return .{ .ignored = .unknown_node };
    const published = list_node.list orelse return .{ .ignored = .not_a_list };
    if (!published.selectable) return .{ .ignored = .unsupported_action };
    const select = dispatcher.select_row orelse return .{ .ignored = .no_handler };
    const owner = list_node.owner orelse return .{ .ignored = .unknown_node };
    if (!select(dispatcher.context, owner, row.index, row.key)) {
        return .{ .ignored = .no_handler };
    }
    return .{ .applied = .{ .row = .{
        .id = entry.id,
        .list = row.list,
        .index = row.index,
        .key = row.key,
        .selected = true,
        .name = entry.name,
    } } };
}

/// The per-frame build inputs.
pub const Build = struct {
    tree: *const WidgetTree,
    /// The committed keyboard focus, or null.
    focus: ?WidgetId = null,
    /// The App frame generation. Published so a request computed against an
    /// older tree can be rejected.
    generation: u64 = 0,
    /// The surface the tree was laid out against.
    surface: Size = .{ .width = 0, .height = 0 },
    /// Accessible name of the window root.
    window_name: []const u8 = "",
    /// Optional per-node annotation hook.
    annotator: Annotator = .{},
};

/// One published row's name, located in the slot's own name arena. The slice
/// is bound after the arena stops growing, so no name can point into a
/// reallocated buffer.
const RowName = struct {
    node: NodeId,
    offset: u32,
    len: u32,
};

/// One frozen range inside a slot arena.
const Span = struct {
    offset: u32,
    len: u32,
};

/// The span that starts at `offset` and runs `len` elements.
fn spanAt(offset: usize, len: usize) Span {
    return .{ .offset = @intCast(offset), .len = @intCast(len) };
}

/// One published text node's frozen characters, located in the slot's own
/// arenas. The by-value parts ride along so the frozen `Text` is rebuilt whole
/// after the walk, when the arenas are final and no published character can
/// point into a reallocated buffer.
const FrozenText = struct {
    node: NodeId,
    selection: ?TextSelection,
    multiline: bool,
    value: Span,
    placeholder: Span,
    lengths: Span,
    positions: Span,
    widths: Span,
};

/// The recorded range inside a final arena.
fn inArena(comptime T: type, arena: []const T, span: Span) []const T {
    return arena[span.offset..][0..span.len];
}

/// Staged semantic storage. One slot holds one snapshot.
const Slot = struct {
    /// Bound on published nodes. A frame that exceeds it is a bug, not a
    /// reason to publish a truncated tree.
    const max_nodes: usize = 65536;

    nodes: std.ArrayListUnmanaged(Node) = .empty,
    index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty,
    /// Direct children per published node, parallel to `nodes`.
    child_counts: std.ArrayListUnmanaged(u32) = .empty,
    /// Start of each published node's block inside `child_ids`.
    child_base: std.ArrayListUnmanaged(u32) = .empty,
    /// Write position inside each published node's block.
    child_cursor: std.ArrayListUnmanaged(u32) = .empty,
    child_ids: std.ArrayListUnmanaged(NodeId) = .empty,
    /// Dense frame node id to published node id, or `no_node`.
    published: std.ArrayListUnmanaged(NodeId) = .empty,
    /// Accessible-name bytes for every published row, concatenated. A row
    /// name is copied here because the app's own accessor writes into a
    /// caller-owned buffer, and a published name must outlive that call.
    row_names: std.ArrayListUnmanaged(u8) = .empty,
    /// Where each published row's name lives inside `row_names`.
    row_name_records: std.ArrayListUnmanaged(RowName) = .empty,
    /// Value and placeholder bytes of every published text node, concatenated.
    /// A run is copied here because an annotator hands over the model's own
    /// live buffer, and a native edit rewrites it between the frame that
    /// staged the tree and the publish that reads it.
    text_values: std.ArrayListUnmanaged(u8) = .empty,
    text_placeholders: std.ArrayListUnmanaged(u8) = .empty,
    /// Frozen character tables, one arena each. A table describes the value
    /// next to it in bytes and in characters, so both come from the same
    /// moment of the same model.
    text_lengths: std.ArrayListUnmanaged(u8) = .empty,
    text_positions: std.ArrayListUnmanaged(f32) = .empty,
    text_widths: std.ArrayListUnmanaged(f32) = .empty,
    /// Where each published text node's frozen strings live.
    text_records: std.ArrayListUnmanaged(FrozenText) = .empty,
    // SAFETY: every init() sets it before the slot is published.
    allocator: std.mem.Allocator = undefined,
    generation: u64 = 0,
    focus_node: NodeId = no_node,
    /// Last authored focus and the one ordinary focus flag added by Build.
    authored_focus_node: NodeId = no_node,
    core_focus_node: NodeId = no_node,
    core_focus_was_focused: bool = false,
    /// The snapshot handed to callers. Valid only while this slot is live or
    /// staged, exactly like a committed frame tree.
    // SAFETY: written by publish() before any reader sees the live slot.
    snapshot: Snapshot = undefined,

    fn init(gpa: std.mem.Allocator) Slot {
        return .{ .allocator = gpa };
    }

    fn deinit(self: *Slot) void {
        self.nodes.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.child_counts.deinit(self.allocator);
        self.child_base.deinit(self.allocator);
        self.child_cursor.deinit(self.allocator);
        self.child_ids.deinit(self.allocator);
        self.published.deinit(self.allocator);
        self.row_names.deinit(self.allocator);
        self.row_name_records.deinit(self.allocator);
        self.text_values.deinit(self.allocator);
        self.text_placeholders.deinit(self.allocator);
        self.text_lengths.deinit(self.allocator);
        self.text_positions.deinit(self.allocator);
        self.text_widths.deinit(self.allocator);
        self.text_records.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *Slot) void {
        self.nodes.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        self.child_counts.clearRetainingCapacity();
        self.child_base.clearRetainingCapacity();
        self.child_cursor.clearRetainingCapacity();
        self.child_ids.clearRetainingCapacity();
        self.published.clearRetainingCapacity();
        self.row_names.clearRetainingCapacity();
        self.row_name_records.clearRetainingCapacity();
        self.text_values.clearRetainingCapacity();
        self.text_placeholders.clearRetainingCapacity();
        self.text_lengths.clearRetainingCapacity();
        self.text_positions.clearRetainingCapacity();
        self.text_widths.clearRetainingCapacity();
        self.text_records.clearRetainingCapacity();
        self.focus_node = no_node;
        self.authored_focus_node = no_node;
        self.core_focus_node = no_node;
        self.core_focus_was_focused = false;
    }

    fn push(self: *Slot, entry: Node) Error!void {
        if (self.nodes.items.len >= max_nodes) return error.SemanticCapacityExceeded;
        // The window root owns the fixed identity, so only the absence marker
        // is rejected here. A widget that hashes onto the root is caught by
        // the duplicate check below.
        if (entry.id == no_node) return error.SemanticIdentityCollision;
        if (self.index.contains(entry.id)) return error.SemanticIdentityCollision;
        const slot: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, entry);
        try self.index.put(self.allocator, entry.id, slot);
        try self.child_counts.append(self.allocator, 0);
        if (entry.parent != no_node) {
            const parent_slot = self.index.get(entry.parent) orelse
                return error.DanglingSemanticRelation;
            self.child_counts.items[parent_slot] += 1;
        }
    }
};

/// Borrowed configuration for publication inside an App frame transaction.
/// Keep the publisher and annotation context alive for every configured frame.
pub const Publication = struct {
    publisher: *Publisher,
    window_name: []const u8 = "",
    annotator: Annotator = .{},
};

/// Owns the published snapshot and its staging slot.
///
/// Two slots alternate exactly like `App.arenas`: the published snapshot stays
/// readable while the next frame builds, and `abort` leaves it untouched, so a
/// failed frame cannot publish half a tree.
pub const Publisher = struct {
    allocator: std.mem.Allocator,
    slots: [2]Slot,
    live: u8 = 0,
    staged: bool = false,

    pub fn init(gpa: std.mem.Allocator) Publisher {
        return .{ .allocator = gpa, .slots = .{ Slot.init(gpa), Slot.init(gpa) } };
    }

    pub fn deinit(self: *Publisher) void {
        self.slots[0].deinit();
        self.slots[1].deinit();
        self.* = undefined;
    }

    /// The published snapshot, or null before the first commit.
    pub fn snapshot(self: *const Publisher) ?*const Snapshot {
        const slot = &self.slots[self.live];
        if (slot.nodes.items.len == 0) return null;
        return &slot.snapshot;
    }

    /// The most recently staged snapshot, falling back to the published one.
    /// Valid only until the next `stage`.
    pub fn stagedSnapshot(self: *const Publisher) ?*const Snapshot {
        if (!self.staged) return self.snapshot();
        return &self.slots[1 - self.live].snapshot;
    }

    /// Discard the staged attempt. The published snapshot is unchanged.
    pub fn abort(self: *Publisher) void {
        self.staged = false;
    }

    /// Stage one snapshot without publishing it.
    pub fn stage(self: *Publisher, request: Build) Error!void {
        self.staged = false;
        const slot = &self.slots[1 - self.live];
        slot.reset();
        slot.snapshot = try build(slot, request);
        self.staged = true;
    }

    /// Publish the staged snapshot as a whole, or nothing.
    pub fn commit(self: *Publisher) void {
        if (!self.staged) return;
        self.live = 1 - self.live;
        self.staged = false;
    }

    /// Commit with the focus actually reconciled by the successful App frame.
    /// This only changes flags and the focus identity; it never allocates.
    pub fn commitFocused(self: *Publisher, focused: ?WidgetId) void {
        if (!self.staged) return;
        const slot = &self.slots[1 - self.live];
        if (slot.core_focus_node != no_node) {
            const previous = slot.index.get(slot.core_focus_node).?;
            slot.nodes.items[previous].states.focused = slot.core_focus_was_focused;
        }
        slot.core_focus_node = no_node;
        slot.focus_node = slot.authored_focus_node;
        if (focused) |owner| {
            const identity = nodeId(owner, .self_node);
            if (slot.index.get(identity)) |index| {
                const entry = &slot.nodes.items[index];
                if (!entry.states.outOfReach()) {
                    slot.core_focus_node = identity;
                    slot.core_focus_was_focused = entry.states.focused;
                    entry.states.focused = true;
                    if (slot.focus_node == no_node or index > slot.index.get(slot.focus_node).?)
                        slot.focus_node = identity;
                }
            }
        }
        slot.snapshot.focus = slot.focus_node;
        self.commit();
    }
};

fn build(slot: *Slot, request: Build) Error!Snapshot {
    const tree = request.tree;
    if (tree.nodes.items.len == 0) return error.InvalidSemanticRoot;
    const gpa = slot.allocator;
    slot.generation = request.generation;

    // FrameNodeId.root marks top-level siblings, not an actual node. The
    // window inherits owner metadata from the first top-level node.
    var top_index: ?usize = null;
    for (tree.nodes.items, 0..) |node, index| {
        if (node.parent == .root) {
            top_index = index;
            break;
        }
    }
    const root_index = top_index orelse return error.InvalidSemanticRoot;

    try slot.published.resize(gpa, tree.nodes.items.len);
    @memset(slot.published.items, no_node);

    try slot.push(.{
        .id = window_node,
        .parent = no_node,
        .role = .window,
        .owner = tree.nodes.items[root_index].widget_id,
        .bounds = .{ .x = 0, .y = 0, .w = request.surface.width, .h = request.surface.height },
        .name = request.window_name,
    });

    // `tree.nodes` is post-order, so walking it backwards visits every parent
    // before its children: a published node can always resolve its parent.
    var index = tree.nodes.items.len;
    while (index > 0) {
        index -= 1;
        const node = &tree.nodes.items[index];
        if (node.paint_hidden or node.overlay_dormant or !widget.isVisible(tree, node.id)) {
            // Hidden or dormant content publishes no node or action target.
            // This includes content whose overlay anchor no longer exists.
            slot.published.items[index] = no_node;
            continue;
        }
        // A placed nested record remains visible when its outer record is
        // dormant. Reparent only across dormant shells; authored hidden
        // parents still suppress their children.
        const parent_published = parent: {
            var parent_id = node.parent;
            var remaining = tree.nodes.items.len;
            while (parent_id != .root) : (remaining -= 1) {
                if (remaining == 0) return error.InvalidSemanticRoot;
                const parent_index = tree.nodeIndex(parent_id) orelse
                    return error.InvalidSemanticRoot;
                const ancestor = &tree.nodes.items[parent_index];
                if (!ancestor.overlay_dormant) break :parent slot.published.items[parent_index];
                parent_id = ancestor.parent;
            }
            break :parent window_node;
        };
        if (parent_published == no_node) {
            // The parent was hidden; the subtree is unpublished with it.
            slot.published.items[index] = no_node;
            continue;
        }
        var draft: Draft = .{};
        if (request.annotator.annotate) |annotate| {
            // SAFETY: only read when request.annotator.context is non-null.
            const context = request.annotator.context orelse @as(*anyopaque, undefined);
            annotate(context, node, &draft) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.AnnotationFailed,
            };
        }
        if (try stageNode(
            slot,
            tree,
            node,
            parent_published,
            request.focus,
            &draft,
        )) |identity| {
            slot.published.items[index] = identity;
        } else {
            // Unpublished descendants keep the nearest published parent.
            slot.published.items[index] = parent_published;
        }
    }
    try linkRowNames(slot);
    try linkFrozenText(slot);
    try linkChildren(slot);
    return .{
        .generation = slot.generation,
        .root = window_node,
        .focus = slot.focus_node,
        .nodes = slot.nodes.items,
        .index = &slot.index,
    };
}

fn stageNode(
    slot: *Slot,
    tree: *const WidgetTree,
    node: *const WidgetNode,
    parent_published: NodeId,
    focused: ?WidgetId,
    draft: *Draft,
) Error!?NodeId {
    const policy = builtIn(tree, node.id, node);
    const publish: bool = if (draft.publish) |forced| forced else policy != null;
    if (!publish) return null;
    // An unaddressable node would be a screen-reader stop the app can never
    // act on, so it is a build error rather than a silent orphan.
    const owner = node.widget_id orelse return error.UnstableSemanticNode;
    const identity = nodeId(owner, .self_node);

    // A forced node is published where the tree puts it, so its enabled
    // state comes from the same ancestor walk the built-in policy uses. A
    // disabled subtree must never be announced as reachable, and a
    // selection inside one is not published at all.
    var entry = policy orelse Node{
        .id = identity,
        .parent = parent_published,
        .role = draft.role orelse .generic_container,
        .owner = owner,
        .bounds = widget.visualBorderRect(tree, node.id),
        .states = .{ .disabled = !input.isEnabled(tree, node.id) },
    };
    entry.id = identity;
    entry.parent = parent_published;
    if (draft.name) |name| entry.name = name;
    if (draft.role) |role| entry.role = role;
    if (draft.focused) |is_focused| entry.states.focused = is_focused;
    if (draft.modal) |is_modal| entry.states.modal = is_modal;
    // Additive only: an annotation can put read_only on a node, never take it
    // off the node the built-in policy decided was read-only.
    if (draft.read_only) entry.states.read_only = true;
    if (draft.list) |list| {
        entry.list = list;
        // A selection-capable container, not a plain list. The platform
        // offers its Selection interface only on the containers whose
        // children are selectable, and a list whose own selection a screen
        // reader cannot move is a list it can only read. `Role.list` stays
        // reachable through `Draft.role` for an app that wants the plain
        // container and no selection relationship.
        entry.role = draft.role orelse .list_box;
        entry.relations.row_count = list.row_count;
        if (list.selected_index) |at| entry.relations.position_in_set = at;
        entry.actions.enable(.custom_action);
    }
    if (draft.text) |text| {
        // Frozen before the node is published, not at the edge: the
        // annotator handed over the model's own live buffer, and a native
        // edit rewrites those bytes before the frame that staged this tree
        // is read. `linkFrozenText` rebinds the node and its run to the copy
        // once the arenas have stopped growing.
        try freezeText(slot, identity, text);
        entry.text = text;
        // The string is the node's value, not only its geometry. A consumer
        // that reads the field without composing a text range still gets the
        // characters the user typed.
        entry.value = .{ .text = text.value };
        if (text.addressable()) entry.actions.enable(.set_text_selection);
        // A provider hands over the field's WHOLE new contents on `set_value`,
        // which is the action a screen reader drives when it writes into a
        // field. A read-only field offers no contents action at all; it still
        // takes a selection, because moving a caret changes no contents. Both
        // are added BEFORE an authored `Draft.actions` replaces the set, so
        // an app that states its own policy stays decisive.
        if (!entry.states.read_only) {
            entry.actions.enable(.replace_selected_text);
            entry.actions.enable(.set_value);
        }
    }
    if (draft.description.len > 0) entry.description = draft.description;
    if (draft.shortcut.len > 0) entry.shortcut = draft.shortcut;
    if (draft.value_description.len > 0) entry.value_description = draft.value_description;
    if (draft.active_descendant) |target| entry.relations.active_descendant = target;
    if (draft.controls.len > 0) entry.relations.controls = draft.controls;
    if (draft.labelled_by.len > 0) entry.relations.labelled_by = draft.labelled_by;
    if (draft.described_by.len > 0) entry.relations.described_by = draft.described_by;
    if (draft.flow_to) |flow| entry.relations.flow_to = flow;
    if (draft.details) |details| entry.relations.details = details;
    if (draft.owns) |owns| entry.relations.owns = owns;
    if (draft.radio_group) |group| entry.relations.radio_group = group;
    if (draft.error_message) |message| entry.relations.error_message = message;
    if (draft.row_index) |row| entry.relations.row_index = row;
    if (draft.row_count) |rows| entry.relations.row_count = rows;
    if (draft.custom_actions.len > 0) {
        entry.custom_actions = draft.custom_actions;
        entry.actions.enable(.custom_action);
    }
    if (draft.actions) |actions| entry.actions = actions;
    if (entry.states.focusable) {
        entry.actions.enable(.focus);
        entry.actions.enable(.blur);
    }
    if (draft.hidden) {
        entry.states.hidden = true;
        entry.actions = .{};
        // A node nobody can see is nobody's caret. Hidden therefore refuses
        // EXACTLY what disabled refuses, so the published tree cannot hold a
        // node that offers nothing yet is announced as focusable or as the
        // one holding focus.
        entry.states.focusable = false;
        entry.states.focused = false;
    }
    if (entry.states.disabled) {
        entry.actions = .{};
        entry.states.focusable = false;
        entry.states.focused = false;
    }
    if (entry.states.focused) slot.authored_focus_node = identity;
    if (focused) |current| {
        if (owner.eql(current) and !entry.states.outOfReach()) {
            slot.core_focus_node = identity;
            slot.core_focus_was_focused = entry.states.focused;
            entry.states.focused = true;
        }
    }
    try slot.push(entry);
    if (entry.states.focused) slot.focus_node = identity;
    if (entry.list) |published| {
        try stageListRows(slot, identity, owner, published, entry);
    }
    if (entry.text) |text| {
        try stageTextRun(slot, identity, owner, text, entry);
    }
    return identity;
}

/// Publish this node's characters as one text-run child of `node_id`.
///
/// A screen reader does not read a text field's characters from the field:
/// it reads the run inside it. Without this node the platform has no text to
/// offer at all, so the field would announce as an empty box however much
/// the app typed into it. The run is published even for an empty string, so
/// a field that is cleared keeps the same native identity instead of
/// becoming a different node.
///
/// The run carries no action of its own. Its owner is the field's live owner,
/// so a request that reaches the run resolves to the same widget and the
/// same model as one addressed to the field itself.
fn stageTextRun(
    slot: *Slot,
    node_id: NodeId,
    owner: WidgetId,
    text: Text,
    entry: Node,
) Error!void {
    const identity = nodeId(owner, .text_run);
    var run: Node = .{
        .id = identity,
        .parent = node_id,
        .role = .text_run,
        .owner = owner,
        // The run is drawn inside its field, so it claims the field's box
        // rather than one of its own that nobody measured.
        .bounds = entry.bounds,
        .states = .{ .disabled = entry.states.disabled },
        .value = .{ .text = text.value },
        .text = text,
    };
    if (entry.states.hidden) run.states.hidden = true;
    try slot.push(run);
    const own = slot.index.get(node_id) orelse return error.DanglingSemanticRelation;
    slot.nodes.items[own].text_run = identity;
}

/// Publish the rows a list viewport shows, and the app's selection with it.
///
/// Identity is the row's stable key, so a reorder changes the published
/// `row_index` and leaves the node identity alone. A row's extent is where
/// the viewport actually draws it, clipped to the container, and an empty
/// box when the viewport shows it nowhere. A hidden or disabled list
/// publishes none: a selection nobody can see or reach is not announced.
fn stageListRows(
    slot: *Slot,
    list_id: NodeId,
    list_owner: WidgetId,
    published: VirtualList,
    container: Node,
) Error!void {
    if (container.states.hidden or container.states.disabled) return;
    if (published.selected_index) |index| {
        if (index >= published.row_count) return error.InvalidSemanticRow;
    }
    const window = published.visible(container.bounds);
    var index = window.start;
    while (index < window.end()) : (index += 1) {
        try stageRow(slot, list_id, list_owner, published, &container, index);
    }
    // The selection is addressable whether or not the viewport shows it, so
    // it is published once more when the window above did not include it.
    if (published.selected_index) |selected| {
        if (selected < window.start or selected >= window.end()) {
            try stageRow(slot, list_id, list_owner, published, &container, selected);
        }
    }
}

fn stageRow(
    slot: *Slot,
    list_id: NodeId,
    list_owner: WidgetId,
    published: VirtualList,
    container: *const Node,
    index: usize,
) Error!void {
    const key = published.keys.keyAt(index);
    const identity = rowNodeId(list_id, key);
    const gpa = slot.allocator;

    var buffer: [max_row_name_bytes]u8 = undefined;
    const written = published.name(published.context, key, index, &buffer);
    const name_len = rowNameLength(written, buffer.len);
    const offset: u32 = @intCast(slot.row_names.items.len);
    try slot.row_names.appendSlice(gpa, buffer[0..name_len]);
    try slot.row_name_records.append(gpa, .{ .node = identity, .offset = offset, .len = @intCast(name_len) });

    var actions: ActionSet = .{};
    if (published.selectable) {
        // The platform's list relationship is "activate this item", so a
        // click and a custom action both mean "select this row".
        actions.enable(.click);
        actions.enable(.custom_action);
    }
    try slot.push(.{
        .id = identity,
        .parent = list_id,
        .role = .list_item,
        // The row is not a widget. Its owner is the list's, so an action on
        // the row reaches the same live control a click on the list does.
        .owner = list_owner,
        .bounds = rowBounds(container.bounds, published, index),
        .states = .{ .selected = published.selected_index == @as(?usize, index) },
        .relations = .{
            .member_of = list_id,
            .row_index = index,
            .row_count = published.row_count,
        },
        .row = .{ .list = list_id, .index = index, .key = key },
        .actions = actions,
    });
}

/// Where row `index` is drawn inside `container`, clipped to it.
///
/// Rows are placed from the row the container says it starts at, so a list
/// that scrolled publishes its rows where they are NOW rather than where
/// they were before. A row the viewport scrolled off publishes an empty box:
/// it is not drawn anywhere, and handing the platform the container's own
/// rectangle would stack every offscreen row on top of the visible ones.
fn rowBounds(container: Rect, published: VirtualList, index: usize) Rect {
    const height = published.row_height;
    if (!(height > 0) or !std.math.isFinite(height)) return .{};
    // Signed on purpose: a row above the window is negative here and lands
    // above the container, instead of being clamped back onto its first row.
    const from_first = @as(i64, @intCast(index)) -
        @as(i64, @intCast(published.first_visible));
    const top = container.y + @as(f32, @floatFromInt(from_first)) * height;
    const limit = container.y + container.h;
    const bottom = top + height;
    if (bottom <= container.y or top >= limit) return .{};
    return .{
        .x = container.x,
        .y = @max(top, container.y),
        .w = container.w,
        .h = @min(bottom, limit) - @max(top, container.y),
    };
}

/// Bind every published row node to its copied name. This runs after the walk,
/// so the arena is final and no name points into a reallocated buffer.
fn linkRowNames(slot: *Slot) Error!void {
    for (slot.row_name_records.items) |record| {
        const at = slot.index.get(record.node) orelse
            return error.DanglingSemanticRelation;
        slot.nodes.items[at].name = slot.row_names.items[record.offset..][0..record.len];
    }
}

/// Copy one text run into the slot's own storage.
///
/// An annotator borrows the model's live buffer, and a native edit rewrites
/// those bytes after the frame that staged the tree and before the publish
/// that reads them: a committed snapshot would then publish one frame's
/// character table beside another's bytes, and a screen reader would read a
/// value no edit ever produced. Copying at staging keeps every published
/// frame whole. The copies are bound to the node in `linkFrozenText`, once
/// the arenas have stopped growing.
fn freezeText(slot: *Slot, node_id: NodeId, text: Text) Error!void {
    const gpa = slot.allocator;
    const record: FrozenText = .{
        .node = node_id,
        .selection = text.selection,
        .multiline = text.multiline,
        .value = spanAt(slot.text_values.items.len, text.value.len),
        .placeholder = spanAt(slot.text_placeholders.items.len, text.placeholder.len),
        .lengths = spanAt(slot.text_lengths.items.len, text.character_lengths.len),
        .positions = spanAt(slot.text_positions.items.len, text.character_positions.len),
        .widths = spanAt(slot.text_widths.items.len, text.character_widths.len),
    };
    try slot.text_values.appendSlice(gpa, text.value);
    try slot.text_placeholders.appendSlice(gpa, text.placeholder);
    try slot.text_lengths.appendSlice(gpa, text.character_lengths);
    try slot.text_positions.appendSlice(gpa, text.character_positions);
    try slot.text_widths.appendSlice(gpa, text.character_widths);
    try slot.text_records.append(gpa, record);
}

/// Bind every published text node to its frozen characters.
///
/// This runs after the walk, so the arenas are final and no published
/// character points into a reallocated buffer. A field and its run are given
/// the SAME copy: they are one model moment read through two nodes, and two
/// slices taken at two instants could describe two different fields.
fn linkFrozenText(slot: *Slot) Error!void {
    for (slot.text_records.items) |record| {
        const text: Text = .{
            .value = inArena(u8, slot.text_values.items, record.value),
            .placeholder = inArena(u8, slot.text_placeholders.items, record.placeholder),
            .selection = record.selection,
            .multiline = record.multiline,
            .character_lengths = inArena(u8, slot.text_lengths.items, record.lengths),
            .character_positions = inArena(f32, slot.text_positions.items, record.positions),
            .character_widths = inArena(f32, slot.text_widths.items, record.widths),
        };
        const at = slot.index.get(record.node) orelse
            return error.DanglingSemanticRelation;
        const entry = &slot.nodes.items[at];
        entry.text = text;
        entry.value = .{ .text = text.value };
        // The run is what a screen reader actually reads, and it publishes
        // the field's own characters under the field's own identity.
        const run = entry.text_run orelse continue;
        const run_at = slot.index.get(run) orelse return error.DanglingSemanticRelation;
        slot.nodes.items[run_at].text = text;
        slot.nodes.items[run_at].value = .{ .text = text.value };
    }
}

/// Give every published node its real child slice from one shared block.
fn linkChildren(slot: *Slot) Error!void {
    const gpa = slot.allocator;
    var total: u32 = 0;
    slot.child_base.clearRetainingCapacity();
    for (slot.child_counts.items) |count| {
        try slot.child_base.append(gpa, total);
        total += count;
    }
    slot.child_ids.clearRetainingCapacity();
    try slot.child_ids.resize(gpa, total);
    // Cursors start at zero; `child_base` is only the block start.
    slot.child_cursor.clearRetainingCapacity();
    try slot.child_cursor.resize(gpa, slot.child_base.items.len);
    @memset(slot.child_cursor.items, 0);
    // Fill in published order so every parent's block stays contiguous.
    for (slot.nodes.items) |entry| {
        if (entry.parent == no_node) continue;
        const parent = slot.index.get(entry.parent) orelse
            return error.DanglingSemanticRelation;
        const at = slot.child_cursor.items[parent];
        if (at >= slot.child_counts.items[parent]) return error.DanglingSemanticRelation;
        slot.child_ids.items[slot.child_base.items[parent] + at] = entry.id;
        slot.child_cursor.items[parent] = at + 1;
    }
    for (slot.nodes.items) |*entry| {
        const own = slot.index.get(entry.id) orelse return error.DanglingSemanticRelation;
        const count = slot.child_counts.items[own];
        entry.children = if (count == 0)
            &.{}
        else
            slot.child_ids.items[slot.child_base.items[own]..][0..count];
    }
    try validateRelations(slot);
}

/// Every relation must resolve inside this snapshot. AccessKit cannot follow
/// an identity that is not in the tree, and a dangling relation would make a
/// screen reader silently drop a control.
fn validateRelations(slot: *const Slot) Error!void {
    for (slot.nodes.items) |entry| {
        const relations = entry.relations;
        if (relations.active_descendant) |target| try require(slot, target);
        if (relations.member_of) |target| try require(slot, target);
        if (relations.radio_group) |target| try require(slot, target);
        if (relations.error_message) |target| try require(slot, target);
        for (relations.controls) |target| try require(slot, target);
        for (relations.described_by) |target| try require(slot, target);
        for (relations.labelled_by) |target| try require(slot, target);
        if (relations.flow_to) |targets| for (targets) |target| try require(slot, target);
        if (relations.details) |targets| for (targets) |target| try require(slot, target);
        if (relations.owns) |targets| for (targets) |target| try require(slot, target);
    }
}

fn require(slot: *const Slot, target: NodeId) Error!void {
    if (!slot.index.contains(target)) return error.DanglingSemanticRelation;
}

/// The built-in per-kind node policy.
///
/// A null result means the built-in policy omits this node; the annotator can
/// still force publication. Static labels are omitted on purpose: the control
/// publishes the same string as its accessible name, and a second node would
/// only be announced twice.
fn builtIn(tree: *const WidgetTree, dense: FrameNodeId, node: *const WidgetNode) ?Node {
    const enabled = input.isEnabled(tree, dense);
    const base: Node = .{
        .id = no_node,
        .parent = no_node,
        .role = .generic_container,
        .owner = node.widget_id,
        .bounds = widget.visualBorderRect(tree, dense),
        .states = .{
            .disabled = !enabled,
            .focusable = focus.defaultDescribe(tree, node) != null and enabled,
        },
    };
    return switch (node.kind) {
        .label, .separator, .spacer, .column, .row => null,
        .button => |button| blk: {
            var entry = base;
            entry.role = .button;
            entry.name = button.accessible_label orelse button.label;
            entry.actions.enable(.click);
            break :blk entry;
        },
        .checkbox => |checkbox| blk: {
            var entry = base;
            entry.role = .check_box;
            entry.name = checkbox.label;
            entry.states.checked = if (checkbox.value.*) .on else .off;
            entry.actions.enable(.click);
            break :blk entry;
        },
        .switch_control => |control| blk: {
            var entry = base;
            entry.role = .switch_control;
            entry.name = control.label;
            entry.states.checked = if (control.value.*) .on else .off;
            entry.actions.enable(.click);
            break :blk entry;
        },
        .radio => |radio| blk: {
            var entry = base;
            entry.role = .radio_button;
            entry.name = radio.label;
            entry.states.selected = radio.selected.* == @as(?u32, radio.option);
            entry.states.checked = if (entry.states.selected) .on else .off;
            entry.actions.enable(.click);
            break :blk entry;
        },
        .slider => |slider| blk: {
            var entry = base;
            entry.role = .slider;
            entry.name = slider.label;
            entry.value = .{ .number = @floatCast(slider.value.*) };
            entry.range = .{
                .min = @floatCast(slider.min),
                .max = @floatCast(slider.max),
                .step = sliderStep(slider.min, slider.max),
            };
            entry.actions.enable(.click);
            entry.actions.enable(.set_value);
            entry.actions.enable(.increment);
            entry.actions.enable(.decrement);
            break :blk entry;
        },
        .progress => |progress| blk: {
            var entry = base;
            entry.role = .progress_indicator;
            entry.name = progress.label;
            entry.states.read_only = true;
            entry.value = .{ .number = @floatCast(progress.value) };
            const span = progress.max - progress.min;
            entry.range = .{
                .min = @floatCast(progress.min),
                .max = @floatCast(progress.max),
                .percent = if (span > 0)
                    @as(f64, @floatCast((progress.value - progress.min) / span))
                else
                    0,
            };
            break :blk entry;
        },
        .element => |frame| blk: {
            const semantic = frame.semantic orelse return null;
            var entry = base;
            entry.role = Role.fromElement(semantic.role);
            entry.name = semantic.label;
            break :blk entry;
        },
    };
}

/// One hundredth of the range: fine enough for a pointer, coarse enough that
/// a screen reader's increment is audible instead of instantaneous.
fn sliderStep(min: f32, max: f32) ?f64 {
    const span: f64 = @floatCast(max - min);
    if (!std.math.isFinite(span) or span <= 0) return null;
    return span / 100;
}

test {
    _ = @import("w21_semantics_test.zig");
}
