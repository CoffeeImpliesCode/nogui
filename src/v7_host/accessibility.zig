//! Native accessibility adapter: nogui semantic snapshots to AccessKit Unix.
//!
//! The adapter owns every conversion the platform needs and nothing else:
//!
//!   * Coordinates cross the boundary as PHYSICAL pixels with a top-left
//!     origin. The core publishes logical bounds; the scale factor is applied
//!     here, at the native edge, and nowhere else.
//!   * Text offsets cross the boundary as CHARACTER indices. The core
//!     addresses text in UTF-8 bytes, AccessKit and AT-SPI address it in
//!     characters, and `character_lengths` is the one conversion table both
//!     sides agree on. It is applied in both directions, so a multi-byte field
//!     is neither published nor edited at the wrong offsets.
//!   * Modality is AUTHORED. The core's `states.modal` is the only source, and
//!     no widget kind produces it on its own, so the platform MODAL state is
//!     set exactly where the app said its subtree owns input. The bit layout
//!     is the bridge's and lives in `flagsOf`, not in the core.
//!   * AccessKit calls its handlers from its own threads. A request is copied
//!     into a bounded, lock-protected ring and replayed on the application
//!     main thread, so one model is mutated from one thread.
//!   * The adapter reports its state explicitly. `unavailable` means the host
//!     was built without the bridge, `inactive` that the bridge exists but no
//!     screen reader has attached, `active` that one has. It never pretends
//!     to be connected.
//!   * The first publication and each screen-reader activation declare the
//!     whole tree. Later updates publish changed nodes and their ancestors,
//!     so unchanged controls do not need to be recreated.
//!   * Every published fact can be read BACK out of the adapter's own buffers
//!     (`lastRect`, `lastFlags`, `lastActions`, `lastRole`, `lastLabel`,
//!     `lastSetPosition`, `lastMemberOf`, `lastCharacterLengths`,
//!     `lastTextSelection`). That is the near side of the bridge and the only
//!     side a host can observe without a screen reader: it says what
//!     AccessKit received, never what the platform echoed back.
//!
//! The accessibility bridge has no bell entry point and AT-SPI defines no
//! portable one, so the bell here is a WINDOW call rather than a tree one: an
//! adapter bound to a real window reports what the platform bell did, and one
//! with no window behind it reports `unsupported`. A virtualized list
//! publishes the container and the app's current selection, so the platform
//! list relationship and its selection are addressable; the rows nobody
//! selected are still only reachable by the app, and the adapter does not
//! invent nodes for them.
const std = @import("std");
const nogui = @import("nogui");
const bridge_options = @import("accesskit_bridge");
const application = @import("application.zig");
const system_bell = @import("system_bell.zig");

pub const semantics = nogui.semantics;
const contract = nogui.window_contract;
pub const c = @cImport({
    @cInclude("nogui_accesskit_bridge.h");
});

pub const NodeId = semantics.NodeId;
/// Borrowed C-ABI tree used by native target adapters.
pub const native_tree = c.nogui_accesskit_tree_update;

/// The owned static library is an OPTIONAL host dependency. A build without it
/// compiles the same API and reports `State.unavailable`.
pub const linked: bool = bridge_options.linked;

/// What the platform actually offers. Every field is a fact observed at
/// runtime, never an assumption.
pub const Capability = struct {
    /// The OS exposes an accessibility bus this adapter can attach to.
    adapter: bool,
    /// A screen reader has asked the adapter for the tree.
    screen_reader: bool,
    /// The bound window's platform bell is available to this adapter. False
    /// with no window bound, after that window closed, and where the backend
    /// found no bell at all: a bind that succeeded says nothing about this.
    bell: bool,
};

pub const State = enum {
    /// Built without the AccessKit bridge. Every call is a no-op.
    unavailable,
    /// The bridge exists; no screen reader has requested the tree yet.
    inactive,
    /// A screen reader is attached and the tree is being served.
    active,
};

/// What one bell request did. The window's backend answers `rung`,
/// `unsupported` or `provider_failed`; `window_closed` and `wrong_thread` are
/// the host's own refusals and come from the same enum, so one caller reads
/// every outcome the same way.
pub const Bell = system_bell.Result;

pub const Error = error{
    /// A tree update exceeded the adapter's per-frame node budget.
    TreeCapacityExceeded,
    /// The platform refused the adapter.
    AdapterUnavailable,
} || std.mem.Allocator.Error;

/// Bound on one published tree. A frame beyond it is a bug, not a truncated
/// screen-reader tree.
pub const max_nodes: usize = 32768;
/// Native requests buffered between the adapter thread and the main thread.
pub const max_queue: usize = 64;
/// Total bytes of action payload the ring can own at once.
pub const max_payload_bytes: usize = 8192;

/// The payload kind of a native request.
pub const NativeData = enum(u8) {
    none = 0,
    custom_action = 1,
    value = 2,
    numeric_value = 3,
    scroll_to_point = 6,
    set_scroll_offset = 7,
    text_selection = 8,
    /// A positioned replacement inside one text: `value` carries the UTF-8
    /// bytes to put there, and `anchor_index`/`focus_index` are the LIVE
    /// Unicode-scalar start and end it replaces.
    ///
    /// The indices are never resolved against the published character
    /// table. A screen reader may send a second edit before the app
    /// republishes, and the range it addresses is a position in what the
    /// model holds now, not in the frozen frame the reader saw.
    text_range = 9,
};

/// One native request in neutral terms.
///
/// The C callback translates the platform request into this and copies it
/// into the ring. No C type and no platform pointer escapes the callback.
pub const NativeRequest = struct {
    id: NodeId,
    /// The AccessKit action discriminant.
    action: u8,
    data: NativeData = .none,
    number: f64 = 0,
    /// Borrowed for the duration of `enqueueRequest`; the ring copies it.
    value: []const u8 = "",
    custom_action: i32 = 0,
    /// Platform offsets, in CHARACTERS. The core's byte offsets are
    /// converted on the way out, not here: the ring copies the request
    /// unchanged and `drain` converts it against the published run.
    ///
    /// A `text_range` is the one kind that is NOT characters. Its two
    /// indices are LIVE Unicode-scalar positions in the model's own value,
    /// because they address text that may have moved since the frame the
    /// reader saw. `drain` passes them through untouched.
    anchor_index: usize = 0,
    focus_index: usize = 0,
    /// The published nodes each index is a position in. `no_node` on both
    /// means the request addresses its own target's text, which is what a
    /// platform without per-node text addresses; naming them is what a
    /// platform that reports the text a screen reader actually clicked
    /// inside sends, and `drain` resolves the owner from them rather than
    /// assuming the target owns whatever text the indices fall in.
    ///
    /// A `text_range` names no text of its own: it edits the target, so both
    /// endpoints must be that target. `no_node` is the absence sentinel, not
    /// an owner, and a range that named no text at all is refused before the
    /// request reaches the ring rather than aimed at the target on a guess.
    anchor_node: NodeId = semantics.no_node,
    focus_node: NodeId = semantics.no_node,
};

/// One native request owned by the adapter. No pointer into the platform's
/// memory survives the callback.
const Pending = struct {
    id: NodeId,
    action: u8,
    data: NativeData,
    number: f64,
    custom_action: i32,
    anchor_index: usize,
    focus_index: usize,
    anchor_node: NodeId,
    focus_node: NodeId,
    payload_offset: u32,
    payload_len: u32,
};

/// A selection already expressed in the platform's units.
const Selection = struct {
    anchor: usize = 0,
    focus: usize = 0,

    fn of(text: semantics.Text) Selection {
        const selection = text.selection orelse return .{};
        return .{
            .anchor = characterIndexOf(text, selection.anchor),
            .focus = characterIndexOf(text, selection.focus),
        };
    }
};

/// The platform's CHARACTER index for a core UTF-8 byte offset.
///
/// A byte offset inside a character has no platform representation, so it
/// resolves to the start of the character that contains it: the caret is
/// snapped to a position the screen reader can address instead of being
/// announced at an offset that does not exist. An offset past the end of the
/// run resolves to the end.
pub fn characterIndexOf(text: semantics.Text, byte_offset: usize) usize {
    if (text.character_lengths.len == 0) return 0;
    var at: usize = 0;
    for (text.character_lengths, 0..) |length, character| {
        if (byte_offset <= at) return character;
        if (byte_offset < at + length) return character;
        at += length;
    }
    return text.character_lengths.len;
}

/// The core's UTF-8 byte offset for a platform CHARACTER index, or null when
/// this run cannot be addressed that way.
///
/// Null means "refuse, never guess": a run that publishes no character table
/// has no defined character geometry, and an index past the end of the table
/// names a position the run does not have. Both are handed back to the core as
/// an invalid request instead of being clamped into a wrong offset.
pub fn byteOffsetOf(text: semantics.Text, character_index: usize) ?usize {
    if (!text.addressable()) return null;
    if (character_index == 0) return 0;
    if (character_index > text.character_lengths.len) return null;
    var at: usize = 0;
    for (text.character_lengths[0..character_index]) |length| at += length;
    return at;
}

/// One selection endpoint, resolved into the core's own units.
///
/// The offset always lands on a character boundary or the endpoint is
/// refused: a platform index is a position between characters, and
/// `byteOffsetOf` is the only thing that turns it into a byte.
fn endpointOf(
    snapshot: *const semantics.Snapshot,
    id: NodeId,
    character_index: usize,
) ?semantics.TextEndpoint {
    const entry = snapshot.node(id) orelse return null;
    const text = entry.text orelse return null;
    const offset = byteOffsetOf(text, character_index) orelse return null;
    return .{ .node = entry.id, .offset = offset };
}

/// The selection a platform that NAMES its endpoints asked for.
///
/// The owner is not decided here. Both endpoints are resolved against the
/// nodes the platform named, and the core compares them with the request
/// target, which is the only place that knows which live text a node stands
/// for. Either endpoint naming something this snapshot does not publish
/// yields no selection at all, so the request is refused rather than applied
/// against whichever text happened to be first.
fn selectionEndpoints(
    snapshot: *const semantics.Snapshot,
    request: Pending,
) ?semantics.SelectionEndpoints {
    const anchor = endpointOf(snapshot, request.anchor_node, request.anchor_index) orelse
        return null;
    const focus = endpointOf(snapshot, request.focus_node, request.focus_index) orelse
        return null;
    return .{ .anchor = anchor, .focus = focus };
}

/// The selection a platform that names NO endpoints asked for: both ends are
/// positions in the target's own text.
fn ownSelection(
    snapshot: *const semantics.Snapshot,
    id: NodeId,
    anchor_index: usize,
    focus_index: usize,
) ?semantics.TextSelection {
    const anchor = endpointOf(snapshot, id, anchor_index) orelse return null;
    const focus = endpointOf(snapshot, id, focus_index) orelse return null;
    return .{ .anchor = anchor.offset, .focus = focus.offset };
}

/// Whether a positioned edit names the ONE text it edits.
///
/// A `text_range` carries no owner of its own: it edits its TARGET, and the
/// shared contract anchors both endpoints at exactly that owner. Anything
/// else is a splice between two different texts — refused at the ring rather
/// than resolved against whichever text happened to be published first.
///
/// There is deliberately no `no_node` fallback. NodeId 0 is the absence
/// sentinel, not an addressable owner, and treating "silent" as "the target"
/// would let a request that named no text at all edit the target on a guess.
fn textRangeAddresses(target: NodeId, request: NativeRequest) bool {
    return request.anchor_node == target and request.focus_node == target;
}

/// Reusable storage for the C view of one tree. Capacity is kept across
/// frames, so a steady UI never allocates on the publish path.
const TreeBuffer = struct {
    nodes: std.ArrayListUnmanaged(c.nogui_accesskit_node) = .empty,
    children: std.ArrayListUnmanaged(u64) = .empty,
    controls: std.ArrayListUnmanaged(u64) = .empty,
    described_by: std.ArrayListUnmanaged(u64) = .empty,
    labelled_by: std.ArrayListUnmanaged(u64) = .empty,
    flow_to: std.ArrayListUnmanaged(u64) = .empty,
    lengths: std.ArrayListUnmanaged(u8) = .empty,
    positions: std.ArrayListUnmanaged(f32) = .empty,
    widths: std.ArrayListUnmanaged(f32) = .empty,
    /// Named actions of every node in this update, in published order. One
    /// list for the whole tree, the same way children and relations are, so a
    /// node points at a span of it rather than owning storage.
    customs: std.ArrayListUnmanaged(c.nogui_accesskit_custom_action) = .empty,
    /// Whether a node is (re)sent in the current update. A parent is marked
    /// when any of its descendants is, so a new control reaches the platform.
    send: []bool = &.{},
    /// Content hash of every published node, for the next frame's diff.
    previous: std.AutoHashMapUnmanaged(NodeId, u64) = .empty,
    current: std.AutoHashMapUnmanaged(NodeId, u64) = .empty,
    /// The tree was published at least once, so an update is incremental.
    published: bool = false,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator) TreeBuffer {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *TreeBuffer) void {
        if (self.send.len != 0) self.gpa.free(self.send);
        self.nodes.deinit(self.gpa);
        self.children.deinit(self.gpa);
        self.controls.deinit(self.gpa);
        self.described_by.deinit(self.gpa);
        self.labelled_by.deinit(self.gpa);
        self.flow_to.deinit(self.gpa);
        self.lengths.deinit(self.gpa);
        self.customs.deinit(self.gpa);
        self.positions.deinit(self.gpa);
        self.widths.deinit(self.gpa);
        self.previous.deinit(self.gpa);
        self.current.deinit(self.gpa);
        self.* = undefined;
    }

    fn resetNodes(self: *TreeBuffer) void {
        self.nodes.clearRetainingCapacity();
        self.children.clearRetainingCapacity();
        self.controls.clearRetainingCapacity();
        self.described_by.clearRetainingCapacity();
        self.labelled_by.clearRetainingCapacity();
        self.flow_to.clearRetainingCapacity();
        self.lengths.clearRetainingCapacity();
        self.positions.clearRetainingCapacity();
        self.widths.clearRetainingCapacity();
        self.customs.clearRetainingCapacity();
    }

    fn reset(self: *TreeBuffer) void {
        self.resetNodes();
        self.current.clearRetainingCapacity();
    }
};

/// Options for one publish.
pub const Publish = struct {
    /// The window's own keyboard focus state. The platform needs it even when
    /// no node inside the tree holds focus.
    focused: bool = false,
};

/// The window adapter. One instance per toplevel window.
///
/// The bridge keeps a raw pointer to the adapter for its callbacks, so the
/// adapter must live at a stable address for as long as it is initialized.
/// `init` is therefore SELF-initializing: it binds the bridge to `self`, not
/// to a local of its own, and returns nothing to copy. A constructor that
/// returned the adapter BY VALUE could only ever hand the bridge the address
/// of its own stack frame, and the first real AT-SPI action would then
/// dereference memory that no longer belongs to the adapter.
///
/// Allocate one, then initialize it in place:
///     const adapter = try gpa.create(Adapter);
///     adapter.init(gpa, io);
pub const Adapter = struct {
    gpa: std.mem.Allocator,
    /// The Io the ring's mutex waits on. AccessKit's threads block on it, so
    /// the window must keep the Io alive for the adapter's whole lifetime.
    io: std.Io,
    /// Null when the host was built without the bridge.
    bridge: ?*c.nogui_accesskit_bridge = null,
    state: State = .inactive,
    tree: TreeBuffer,
    /// Physical pixels per logical pixel, applied at the native edge only.
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    /// Toolkit identity published with the tree.
    toolkit: []const u8 = "nogui",
    version: []const u8 = "0.0.0",

    mutex: std.Io.Mutex = .init,
    /// Ring of native requests waiting to be replayed. Only the first
    /// `queue_len` slots are live, and `init` starts the ring empty.
    queue: [max_queue]Pending,
    queue_len: u32 = 0,
    queue_head: u32 = 0,
    /// Scratch bytes for the payload of the request being published. Only the
    /// first `payload_used` bytes are live.
    payload: [max_payload_bytes]u8,
    payload_used: u32 = 0,
    /// Requests the ring refused because it was full. Surfaced, never hidden.
    dropped: u32 = 0,
    /// A native request arrived since the last drain.
    pending: bool = false,
    /// The platform asked for this window's tree, or reported that it let the
    /// last one go, and no update has declared the whole hierarchy since.
    ///
    /// This is the host's only record of a tree the platform dropped, because
    /// the bridge's active flag cannot tell two activation cycles apart: a
    /// reader that attaches, goes away and attaches again between two
    /// publishes leaves that flag true the whole time, while the platform
    /// holds nothing and builds the tree it serves out of the first update it
    /// is given. Written on the platform's own thread, read on the frame
    /// thread, both under `mutex`.
    tree_requested: bool = false,
    /// Whether the last update re-declared the whole tree.
    last_full: bool = false,
    /// The host this window's bell is borrowed from. The host clears it when
    /// the window closes, so an adapter that outlives its application never
    /// reaches a host that is already gone.
    bell_application: ?*application.Application = null,
    /// The window the bell belongs to, in the host's generational handle.
    bell_handle: ?contract.WindowHandle = null,
    /// The window closed while this binding was live. It outlives the host
    /// borrow on purpose: "the window I was bound to is gone" is the only
    /// honest answer an adapter has left.
    bell_closed: bool = false,
    /// The thread that made the binding. A bell request from any other thread
    /// is refused before the host is read at all.
    bell_thread: ?std.Thread.Id = null,

    pub fn init(self: *Adapter, gpa: std.mem.Allocator, io: std.Io) void {
        self.initWithoutBridge(gpa, io);
        self.state = .inactive;
        if (!linked) {
            self.state = .unavailable;
            return;
        }
        // `self`, not a local: this is the address the bridge keeps.
        const bridge = c.nogui_accesskit_bridge_new(
            @ptrCast(self),
            AdapterCallbacks.onAction,
            AdapterCallbacks.onActivate,
            AdapterCallbacks.onDeactivate,
        );
        if (bridge == null) {
            self.state = .unavailable;
            return;
        }
        self.bridge = bridge;
    }

    /// Initialize shared serialization and action queues without AccessKit.
    /// Native mobile adapters own their platform bridge separately.
    pub fn initWithoutBridge(self: *Adapter, gpa: std.mem.Allocator, io: std.Io) void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .tree = TreeBuffer.init(gpa),
            // SAFETY: `queue` is a scratch ring whose live prefix is tracked by
            // `queue_len`, which this initializer leaves at 0, so no slot is
            // read before it is written.
            .queue = undefined,
            // SAFETY: `payload` is scratch bytes whose live prefix is tracked
            // by `payload_used`, which this initializer leaves at 0, so no byte
            // is read before it is written.
            .payload = undefined,
            .state = .unavailable,
        };
    }

    /// Borrowed C-ABI handle for the target adapter that attaches a native view.
    /// Valid until deinit; null when the native bridge is unavailable.
    pub fn bridgeHandle(self: *const Adapter) ?*anyopaque {
        if (comptime !linked) return null;
        const bridge = self.bridge orelse return null;
        return @ptrCast(bridge);
    }

    /// Bind this adapter's bell to one window of one host.
    ///
    /// The host keeps the reverse link, so the binding ends when either side
    /// says so: `unbindSystemBell` here, or the host destroying the window,
    /// which notifies this adapter instead of leaving it pointing at a host
    /// that is being torn down. A live binding is never replaced: a second
    /// bind is refused, and a window another observer already owns is refused
    /// without displacing it.
    pub fn bindSystemBell(
        self: *Adapter,
        host: *application.Application,
        window: contract.WindowHandle,
    ) !void {
        // A closed binding already dropped the host, so only a LIVE one blocks
        // a rebind.
        if (self.bell_application != null) return error.BellAlreadyBound;
        // The host owns the outcome, so a refused bind changes nothing here:
        // a dead binding stays dead rather than turning into "unbound".
        try host.bindSystemBell(window, self.bellObserver());
        self.bell_application = host;
        self.bell_handle = window;
        self.bell_closed = false;
        self.bell_thread = std.Thread.getCurrentId();
    }

    /// Release this adapter's bell binding, if it still holds one.
    ///
    /// The release belongs to the thread that made the binding, so another
    /// thread is refused with `error.WrongThread` and the WHOLE binding stays:
    /// an adapter that dropped its own record while the window still named it
    /// would leave that window holding a callback into storage this adapter is
    /// still using.
    ///
    /// Unbound and already-closed are both idempotent successes, so an adapter
    /// that outlived its application has nothing left to release and nothing to
    /// fail on.
    pub fn unbindSystemBell(self: *Adapter) !void {
        const host = self.bell_application orelse return;
        // A live binding always names its window: the three fields are set and
        // cleared together, so a missing handle here is a broken invariant and
        // stops the release rather than dropping the binding silently.
        const handle = self.bell_handle.?;
        try host.unbindSystemBell(handle, self.bellObserver());
        self.bell_application = null;
        self.bell_handle = null;
        self.bell_thread = null;
    }

    /// The observer this adapter presents to the host. Derived from the
    /// adapter's own stable address, so it is never stored twice and never
    /// out of date.
    fn bellObserver(self: *Adapter) system_bell.Owner {
        return .{ .context = self, .on_closed = bellWindowClosed };
    }

    /// The window closed while this binding was live. The host tells us before
    /// it releases the backend, so the borrow of the host is dropped here and
    /// the only thing that survives is the fact that the window is gone.
    fn bellWindowClosed(context: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.bell_application = null;
        self.bell_handle = null;
        self.bell_thread = null;
        self.bell_closed = true;
    }

    pub fn deinit(self: *Adapter) void {
        // Teardown is a main-thread operation, and it is the last chance to
        // hand this window's observer back. A teardown from any other thread
        // stops HERE, before one byte is freed: the host would keep a callback
        // pointing into storage this call is about to release, and the crash
        // would land a long way from the mistake that made it.
        if (self.bell_application != null and self.bell_thread.? != std.Thread.getCurrentId()) {
            @panic("accessibility.Adapter.deinit called off the thread that bound its bell");
        }
        // The thread is right or nothing is bound, so this release cannot be
        // refused; a refusal here would mean the check above lied.
        self.unbindSystemBell() catch @panic("bell release refused on the thread that owns it");
        if (comptime linked) {
            if (self.bridge) |bridge| c.nogui_accesskit_bridge_free(bridge);
        }
        self.bridge = null;
        self.tree.deinit();
        self.state = .unavailable;
        self.* = undefined;
    }

    /// The current adapter state, refreshed from the bridge.
    pub fn stateOf(self: *Adapter) State {
        // A build without the bridge must not even reference the extern, or the
        // link fails on an absent archive. `linked` is comptime-known, so this
        // drops the symbol reference instead of branching at run time.
        if (comptime !linked) return .unavailable;
        const bridge = self.bridge orelse return .unavailable;
        self.state = if (c.nogui_accesskit_bridge_is_active(bridge)) .active else .inactive;
        return self.state;
    }

    /// Explicit native capability report. Never inferred from a build flag.
    ///
    /// The bridge fields describe the accessibility bus and the bell field
    /// describes the window's platform bell. They are separate facts measured
    /// separately: a linked bridge says nothing about the bell, and a live
    /// binding says nothing about a screen reader.
    pub fn capability(self: *Adapter) Capability {
        const state = self.stateOf();
        return .{
            .adapter = state != .unavailable,
            .screen_reader = state == .active,
            .bell = self.systemBellAvailable(),
        };
    }

    /// Whether this adapter's bound window can actually ring, measured now.
    /// False with no binding, after the window closed, and on a platform whose
    /// backend failed to initialize: a failed backend is not a missing one,
    /// and neither is reported as a bell that works.
    pub fn systemBellAvailable(self: *Adapter) bool {
        if (self.bell_closed) return false;
        const host = self.bell_application orelse return false;
        return host.systemBellAvailable(self.bell_handle.?);
    }

    /// Tell the platform whether the window itself has keyboard focus.
    pub fn setWindowFocused(self: *Adapter, focused: bool) void {
        if (comptime !linked) return;
        const bridge = self.bridge orelse return;
        c.nogui_accesskit_bridge_set_window_focused(bridge, focused);
    }

    /// X11 only: a Wayland client cannot learn its toplevel position, so the
    /// caller passes physical screen coordinates it already owns.
    pub fn setWindowBounds(self: *Adapter, outer: [4]f64, inner: [4]f64) void {
        if (comptime !linked) return;
        const bridge = self.bridge orelse return;
        c.nogui_accesskit_bridge_set_window_bounds(bridge, rect(outer), rect(inner));
    }

    /// The logical-to-physical scale used for every published coordinate.
    pub fn setScale(self: *Adapter, x: f32, y: f32) void {
        if (!(x > 0) or !std.math.isFinite(x)) return;
        if (!(y > 0) or !std.math.isFinite(y)) return;
        self.scale_x = x;
        self.scale_y = y;
    }

    /// The platform is asking for this window's tree, so the next update the
    /// platform ACCEPTS has to declare the whole hierarchy. Set from the
    /// activation and deactivation callbacks, on whatever thread the platform
    /// runs them.
    fn noteTreeRequest(self: *Adapter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pending = true;
        self.tree_requested = true;
    }

    /// Read and clear the standing request in one step, so a request that
    /// arrives while the update it belongs to is on its way is never retired
    /// by an update the platform refused or never saw.
    fn takeTreeRequest(self: *Adapter) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const requested = self.tree_requested;
        self.tree_requested = false;
        return requested;
    }

    /// Hand the request back after an update that never reached the platform.
    /// It holds no tree of ours either way, so the next one must declare one.
    fn restoreTreeRequest(self: *Adapter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.tree_requested = true;
    }

    /// Convert one committed snapshot and hand it to the platform.
    ///
    /// Returns the number of nodes the update carried. The update is atomic:
    /// if any conversion fails, nothing is sent and the previously published
    /// tree stays live. A host built without the bridge still performs the
    /// conversion, so the same code path is exercised and observable.
    ///
    /// A platform that asks for this window's tree twice gets the whole
    /// hierarchy twice, so the request is retired only by an update the
    /// platform accepted, and both failures below hand it back.
    pub fn publish(
        self: *Adapter,
        snapshot: *const semantics.Snapshot,
        options: Publish,
    ) Error!usize {
        var update = self.build(snapshot, options, false) catch |err| {
            self.restoreTreeRequest();
            return err;
        };
        var submission: Submission = .{
            .adapter = self,
            .snapshot = snapshot,
            .update = &update,
        };
        // See `stateOf`: the extern must be dropped at compile time, not just
        // skipped at run time, or an unlinked build fails to link.
        if (comptime linked) {
            if (self.bridge) |bridge| {
                if (!c.nogui_accesskit_bridge_update(
                    bridge,
                    &update,
                    &submission,
                    Submission.fullTree,
                )) {
                    // The platform never took this update, so the tree it is
                    // missing is still missing and the request stands.
                    self.restoreTreeRequest();
                    return error.AdapterUnavailable;
                }
            }
        }
        std.mem.swap(
            std.AutoHashMapUnmanaged(NodeId, u64),
            &self.tree.previous,
            &self.tree.current,
        );
        self.tree.published = true;
        self.last_full = update.has_tree_init;
        return update.nodes_len;
    }

    /// Encode a full snapshot for a non-AccessKit native bridge.
    /// Borrowed until the next encode/publish or deinit; no native calls.
    pub fn encodeFullSnapshot(
        self: *Adapter,
        snapshot: *const semantics.Snapshot,
        options: Publish,
    ) Error!native_tree {
        return self.build(snapshot, options, true);
    }

    /// Replay every buffered native request on the calling (main) thread.
    ///
    /// Each request resolves a stable live owner and travels the ordinary
    /// activation, edit and focus seam, so a screen-reader edit and a pointer
    /// edit change the same model exactly once. Text offsets are converted
    /// from the platform's characters into the core's bytes on the way in,
    /// which is the same conversion the publish path applies in reverse.
    ///
    /// Requests drain in the order they were queued, and each one reads the
    /// model as the previous one left it. Two edits a reader sent against one
    /// frame therefore both land, in order, without a selection between them
    /// to re-anchor the second: a positioned edit carries its own range, so
    /// it needs no pre-step to say where it applies.
    ///
    /// No generation is stamped on the way in, because the platform carries
    /// none: an accessibility bus reports which control an action names and
    /// nothing about the frame that published it. Stamping the adapter's own
    /// frame counter would reject every valid action that survived one
    /// repaint, which is most of them. What makes such a request stale is
    /// identity — a node identity embeds its owner's generation — and, for a
    /// selection, the character table, which refuses an index the republish
    /// no longer has. A positioned edit is deliberately NOT gated on that
    /// table: its indices are positions in the LIVE value, which the
    /// character table cannot describe.
    ///
    /// The queue is sampled under the mutex and dispatched without it, so a
    /// request that arrives during replay is retained for the next drain
    /// rather than replayed on the platform's thread.
    pub fn drain(
        self: *Adapter,
        snapshot: *const semantics.Snapshot,
        dispatcher: *const semantics.Dispatcher,
        scratch: semantics.Scratch,
    ) usize {
        self.mutex.lockUncancelable(self.io);
        const total = self.queue_len;
        self.pending = false;
        self.mutex.unlock(self.io);
        var applied: usize = 0;
        var replayed: u32 = 0;
        while (replayed < total) : (replayed += 1) {
            self.mutex.lockUncancelable(self.io);
            const request = self.queue[(self.queue_head + replayed) % max_queue];
            const payload = self.payload[request.payload_offset..][0..request.payload_len];
            self.mutex.unlock(self.io);
            // An action this bridge does not model is dropped, never guessed.
            const action = std.enums.fromInt(semantics.Action, request.action) orelse continue;
            // A platform that names the node each endpoint is a position in
            // gets its endpoints resolved against THOSE nodes; one that
            // names none addresses the target's own text. Either way the
            // platform counts characters and the core counts bytes, and a
            // run that cannot be converted yields no selection at all, so
            // the core refuses the request rather than editing the model at
            // a guessed offset.
            const named = request.data == .text_selection and
                (request.anchor_node != semantics.no_node or
                    request.focus_node != semantics.no_node);
            const endpoints = if (named)
                selectionEndpoints(snapshot, request)
            else
                null;
            const own = if (request.data == .text_selection and !named)
                ownSelection(snapshot, request.id, request.anchor_index, request.focus_index)
            else
                null;
            const outcome = snapshot.dispatch(.{
                .id = request.id,
                .action = action,
                // No generation: see the note on this function.
                .number = switch (request.data) {
                    .numeric_value => request.number,
                    else => null,
                },
                // Exactly one payload crosses: a `text_range` is the
                // positioned edit and carries no whole-value `text`, so
                // the core never has to choose between two edits or
                // refuse a combination the wire could not produce.
                .text = switch (request.data) {
                    .value => payload,
                    else => null,
                },
                // LIVE scalar positions, passed through untouched. They
                // are never resolved against the published character
                // table: that table belongs to the frame the reader saw,
                // and a second edit may already have moved the text this
                // one addresses.
                .edit = switch (request.data) {
                    .text_range => .{
                        .node = request.id,
                        .start = request.anchor_index,
                        .end = request.focus_index,
                        .bytes = payload,
                    },
                    else => null,
                },
                .selection = own,
                .selection_endpoints = endpoints,
                .custom_action = switch (request.data) {
                    .custom_action => request.custom_action,
                    else => null,
                },
            }, dispatcher, scratch);
            if (outcome == .applied) applied += 1;
        }
        self.mutex.lockUncancelable(self.io);
        self.queue_head = @intCast((self.queue_head + total) % max_queue);
        self.queue_len -= total;
        if (self.queue_len == 0) {
            self.queue_head = 0;
            self.payload_used = 0;
        } else {
            self.pending = true;
        }
        self.mutex.unlock(self.io);
        return applied;
    }

    /// True when the adapter thread delivered a request since the last drain.
    /// The window driver uses it to request a redraw.
    pub fn hasPending(self: *Adapter) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pending;
    }

    /// Native requests the ring refused, for every reason it refuses: a full
    /// ring, a payload larger than the ring can own, and a request whose
    /// payload kind and action, or whose endpoint nodes, contradict each
    /// other. Surfaced, never hidden, so a refusal the platform chose to
    /// ignore is still visible to the host.
    pub fn droppedRequests(self: *Adapter) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.dropped;
    }

    /// Ring the platform bell for the window this adapter is bound to.
    ///
    /// The refusals are ordered so the cheapest fact wins: with no binding
    /// there is nothing to ring, a call from a thread the binding does not
    /// belong to is turned away before the host is read at all, and a window
    /// that closed is named as closed rather than as a missing capability.
    ///
    /// `rung` means the platform accepted the request. It is never a claim
    /// that a sound was produced, because nothing here can observe one.
    pub fn bell(self: *Adapter) Bell {
        // A closed binding is named as closed even though the host it named is
        // already gone: "that window no longer exists" is the one true thing
        // left to say, and `unsupported` would blame the platform instead.
        if (self.bell_closed) return .window_closed;
        if (self.bell_application == null) return .unsupported;
        if (self.bell_thread.? != std.Thread.getCurrentId()) return .wrong_thread;
        return self.bell_application.?.ringSystemBell(self.bell_handle.?);
    }

    /// Copy one native request into the ring.
    ///
    /// Returns whether the ring took it. A full ring, a payload the ring
    /// cannot own, and a request this edge refuses to interpret are all
    /// refusals: they write no payload byte, so a queued neighbour keeps
    /// exactly the bytes it was lent, and they count in `droppedRequests`.
    /// Acceptance is QUEUE acceptance — asynchronous, and nothing more. It
    /// is never a claim that the model changed, which only a later readback
    /// of the model can say.
    ///
    /// Two combinations are refused here rather than downstream, because a
    /// ring slot is worth more than a request that could only ever be
    /// dropped: a `text_range` on an action that is not
    /// `replace_selected_text`, and a `text_range` whose endpoints name one
    /// text while its target owns another.
    ///
    /// The indices need no representability check of their own. The wire
    /// declares them `size_t`, which the C translation maps onto `usize`,
    /// so there is no narrowing step here to truncate. What is NOT
    /// representable is a length with no buffer behind it, and that refuses
    /// below.
    ///
    /// Safe to call from the platform thread: it only copies into fixed
    /// storage and never touches the application. `value` is copied, so the
    /// caller may free it as soon as this returns.
    pub fn enqueueRequest(self: *Adapter, request: NativeRequest) bool {
        if (request.data == .text_range and
            (request.action != @intFromEnum(semantics.Action.replace_selected_text) or
                !textRangeAddresses(request.id, request)))
        {
            return self.refuse();
        }
        // Both kinds that carry bytes get the same copy: a positioned edit's
        // bytes are its replacement, not a value the ring may drop.
        const payload_len: usize = switch (request.data) {
            .value, .text_range => request.value.len,
            else => 0,
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Compared by subtraction: a length no `usize` can hold would wrap
        // an addition into a small one that fits. `payload_used` only ever
        // advances past a length that left room for it, so the remainder
        // below is never negative.
        const used: usize = self.payload_used;
        if (self.queue_len == max_queue or payload_len > max_payload_bytes - used) {
            self.dropped += 1;
            return false;
        }
        const offset = used;
        if (payload_len > 0) {
            @memcpy(self.payload[offset..][0..payload_len], request.value);
            self.payload_used = @intCast(offset + payload_len);
        }
        self.queue[(self.queue_head + self.queue_len) % max_queue] = .{
            .id = request.id,
            .action = request.action,
            .data = request.data,
            .number = request.number,
            .custom_action = request.custom_action,
            .anchor_index = request.anchor_index,
            .focus_index = request.focus_index,
            .anchor_node = request.anchor_node,
            .focus_node = request.focus_node,
            .payload_offset = @intCast(offset),
            .payload_len = @intCast(payload_len),
        };
        self.queue_len += 1;
        self.pending = true;
        return true;
    }

    /// Translate one platform request and hand it to the ring.
    ///
    /// A payload length with no buffer behind it is refused rather than
    /// answered with an empty string: a range that claims bytes it does not
    /// carry is a deletion, and silently substituting one would edit the
    /// model as though the reader had asked for it.
    fn enqueue(self: *Adapter, request: *const c.nogui_accesskit_request) bool {
        if (request.value == null and request.value_len != 0) return self.refuse();
        return self.enqueueRequest(.{
            .id = request.target,
            .action = request.action,
            .data = std.enums.fromInt(NativeData, request.data) orelse NativeData.none,
            .number = request.numeric_value,
            .value = if (request.value == null)
                ""
            else
                request.value[0..request.value_len],
            .custom_action = request.custom_action,
            .anchor_index = request.anchor_index,
            .focus_index = request.focus_index,
            .anchor_node = request.anchor_node,
            .focus_node = request.focus_node,
        });
    }

    /// Count one refusal and report it to the platform.
    ///
    /// No payload byte and no queue slot moves, so the requests already
    /// waiting keep the storage they were lent.
    fn refuse(self: *Adapter) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dropped += 1;
        return false;
    }

    /// The node identities the last update carried, in publish order.
    /// Caller-owned output: no allocation on the inspect path.
    pub fn lastNodes(self: *const Adapter, out: []NodeId) []const NodeId {
        const count = @min(out.len, self.tree.nodes.items.len);
        for (self.tree.nodes.items[0..count], 0..) |node, index| out[index] = node.id;
        return out[0..count];
    }

    /// The physical-pixel rectangle the last update published for `id`.
    ///
    /// Logical bounds are converted here, at the native edge; this is the
    /// value the platform received.
    /// Returns null when this incremental update omitted the unchanged node.
    pub fn lastRect(self: *const Adapter, id: NodeId) ?[4]f64 {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            return .{
                node.bounds.x0,
                node.bounds.y0,
                node.bounds.x1,
                node.bounds.y1,
            };
        }
        return null;
    }

    /// The state bitmask the last update published for `id`, exactly as the
    /// bridge received it. Lets a host assert what the platform was told
    /// without an AT-SPI session.
    pub fn lastFlags(self: *const Adapter, id: NodeId) ?u32 {
        for (self.tree.nodes.items) |node| {
            if (node.id == id) return node.flags;
        }
        return null;
    }

    /// The text selection the last update published for `id`, in the
    /// platform's own CHARACTER indices, or null when the run published no
    /// character table and is therefore not addressable there.
    pub fn lastTextSelection(
        self: *const Adapter,
        id: NodeId,
    ) ?struct { anchor: usize, focus: usize, cursor: usize } {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            if (!node.has_text_selection) return null;
            return .{
                .anchor = node.text_selection_anchor,
                .focus = node.text_selection_focus,
                .cursor = node.text_cursor,
            };
        }
        return null;
    }

    /// The node the last update published `id`'s selection against, or null
    /// when that node published no selection at all.
    ///
    /// A text field's selection belongs to the run it published, so this is
    /// how a host checks that the caret the platform was handed is a position
    /// in the very characters the platform can read.
    pub fn lastTextSelectionOwner(self: *const Adapter, id: NodeId) ?NodeId {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            if (!node.has_text_selection) return null;
            return @intCast(node.text_selection_owner);
        }
        return null;
    }

    /// The set relationship the last update published for `id`: the node's
    /// position within its set and the size of that set, or null when the
    /// node published none. This is the virtualized list's `position_in_set`
    /// and `row_count` after the native edge chose the platform's own
    /// `position_in_set` / `size_of_set` pair, so a host can check the
    /// relationship without an AT-SPI session.
    pub fn lastSetPosition(
        self: *const Adapter,
        id: NodeId,
    ) ?struct { position: usize, size: usize } {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            if (!node.has_row_index_position) return null;
            return .{
                .position = node.row_index_position,
                .size = @intCast(node.row_count_set_size),
            };
        }
        return null;
    }

    /// The action bitmask the last update published for `id`, exactly as the
    /// bridge received it. A node the core refuses to act on — hidden or
    /// disabled — publishes zero here, so a screen reader is offered nothing
    /// rather than an action that would be rejected.
    pub fn lastActions(self: *const Adapter, id: NodeId) ?u32 {
        for (self.tree.nodes.items) |node| {
            if (node.id == id) return node.actions;
        }
        return null;
    }

    /// The member-of target the last update published for `id`, or null when
    /// the node published no set membership. A published virtualized row
    /// carries the list it belongs to, which is what makes it addressable as
    /// a list item rather than a loose control.
    pub fn lastMemberOf(self: *const Adapter, id: NodeId) ?NodeId {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            if (node.member_of == 0) return null;
            return @intCast(node.member_of);
        }
        return null;
    }

    /// The role byte the last update published for `id`, exactly as the bridge
    /// received it.
    pub fn lastRole(self: *const Adapter, id: NodeId) ?u8 {
        for (self.tree.nodes.items) |node| {
            if (node.id == id) return node.role;
        }
        return null;
    }

    /// The accessible name the last update published for `id`, borrowed from
    /// the snapshot it came from. Valid while that snapshot is the published
    /// one, exactly as `lastValue` is: the node record holds a pointer into the
    /// core's own annotation storage, not into an adapter buffer, so a host
    /// that keeps it past the snapshot that published it reads freed bytes.
    pub fn lastLabel(self: *const Adapter, id: NodeId) ?[]const u8 {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            return node.label[0..node.label_len];
        }
        return null;
    }

    /// The value the last update published for `id`, borrowed from the
    /// snapshot it came from. Valid while that snapshot is the published one.
    ///
    /// A text field's characters reach the platform here and on its run, so
    /// a host can read both without an AT-SPI session and see that the
    /// string the user typed is the string the platform was handed.
    ///
    /// Null for a node that published no value and for one whose value is a
    /// number: the ABI says "absent" with a null pointer, and slicing that
    /// would describe bytes it never published. A cleared field published the
    /// empty string, which is a value and comes back as one.
    pub fn lastValue(self: *const Adapter, id: NodeId) ?[]const u8 {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            if (node.value == null) return null;
            return node.value[0..node.value_len];
        }
        return null;
    }

    /// The numeric ABI value published for `id`, or null for an absent node
    /// or a non-numeric value. Zero is a present value.
    pub fn lastNumericValue(self: *const Adapter, id: NodeId) ?f64 {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            return if (node.has_numeric_value) node.numeric_value else null;
        }
        return null;
    }

    /// The per-character UTF-8 byte lengths the last update published for
    /// `id`. This table IS the byte/character conversion the platform and the
    /// core agree on, so a host can check that the table it sent describes
    /// the run it holds.
    pub fn lastCharacterLengths(self: *const Adapter, id: NodeId) ?[]const u8 {
        for (self.tree.nodes.items) |node| {
            if (node.id != id) continue;
            // A node with no text run published no table at all. Reporting an
            // empty one would be indistinguishable from a run that published
            // an empty table, which is a different and unaddressable thing.
            if (node.character_lengths == null) return null;
            return node.character_lengths[0..node.character_lengths_len];
        }
        return null;
    }

    /// Whether the last update re-declared the whole tree.
    pub fn lastWasFullTree(self: *Adapter) bool {
        return self.last_full;
    }

    /// Reserve the whole snapshot before entering a native adapter's lock.
    /// Besides making a late full declaration infallible, this keeps pointers
    /// into relation and character arrays stable while nodes are appended.
    fn reserveSnapshot(self: *Adapter, snapshot: *const semantics.Snapshot) Error!void {
        const count = snapshot.count();
        if (count > max_nodes) return error.TreeCapacityExceeded;
        var children: usize = 0;
        var controls: usize = 0;
        var described_by: usize = 0;
        var labelled_by: usize = 0;
        var flow_to: usize = 0;
        var lengths: usize = 0;
        var positions: usize = 0;
        var widths: usize = 0;
        var customs: usize = 0;
        for (snapshot.nodes) |node| {
            children += node.children.len;
            controls += node.relations.controls.len;
            described_by += node.relations.described_by.len;
            labelled_by += node.relations.labelled_by.len;
            if (node.relations.flow_to) |flow| flow_to += flow.len;
            if (node.text) |text| {
                lengths += text.character_lengths.len;
                positions += text.character_positions.len;
                widths += text.character_widths.len;
            }
            if (publishesCustomActions(node)) customs += node.custom_actions.len;
        }
        const gpa = self.gpa;
        try self.tree.nodes.ensureTotalCapacity(gpa, count);
        try self.tree.children.ensureTotalCapacity(gpa, children);
        try self.tree.controls.ensureTotalCapacity(gpa, controls);
        try self.tree.described_by.ensureTotalCapacity(gpa, described_by);
        try self.tree.labelled_by.ensureTotalCapacity(gpa, labelled_by);
        try self.tree.flow_to.ensureTotalCapacity(gpa, flow_to);
        try self.tree.lengths.ensureTotalCapacity(gpa, lengths);
        try self.tree.positions.ensureTotalCapacity(gpa, positions);
        try self.tree.widths.ensureTotalCapacity(gpa, widths);
        try self.tree.customs.ensureTotalCapacity(gpa, customs);
        try self.tree.current.ensureTotalCapacity(gpa, @intCast(count));
        if (self.tree.send.len < count) {
            const grown = try gpa.alloc(bool, count);
            if (self.tree.send.len != 0) gpa.free(self.tree.send);
            self.tree.send = grown;
        }
    }

    /// Borrowed only until the synchronous bridge update returns. The SDK
    /// invokes this supplier under the lock that orders initial-tree requests.
    const Submission = struct {
        adapter: *Adapter,
        snapshot: *const semantics.Snapshot,
        update: *native_tree,

        fn fullTree(context: ?*anyopaque) callconv(.c) [*c]const native_tree {
            const self: *Submission = @ptrCast(@alignCast(context.?));
            const adapter = self.adapter;
            // The SDK is now holding its activation lock. Retire the host's
            // request here, not by checking it again before entering the SDK.
            _ = adapter.takeTreeRequest();
            if (!self.update.has_tree_init) {
                // `reserveSnapshot` funded every slot the whole snapshot
                // needs, so this pass cannot allocate and cannot fail. It is
                // deliberately the infallible append: the alternative is an
                // error this frame could only turn into a Zig panic, and a
                // panic raised inside a frame Rust called unwinds through
                // Rust frames that have no landing pad.
                adapter.tree.resetNodes();
                for (self.snapshot.nodes) |node| adapter.appendNodeReserved(node);
                self.update.has_tree_init = true;
                self.update.nodes = adapter.tree.nodes.items.ptr;
                self.update.nodes_len = adapter.tree.nodes.items.len;
            }
            return self.update;
        }
    };

    /// Convert the snapshot into the platform's borrowed tree view.
    fn build(
        self: *Adapter,
        snapshot: *const semantics.Snapshot,
        options: Publish,
        full: bool,
    ) Error!c.nogui_accesskit_tree_update {
        // A declaration replaces the platform's tree: the placeholder a screen
        // reader installs when it first asks for this window, and the whole
        // tree the platform dropped when the last reader went away. Asking is
        // not the same as staying attached, so the request decides, not how
        // long a reader has been there.
        //
        // This host flag prepares a declaration for already-known requests and
        // supports unlinked/native-mobile encoders. It cannot order an attach
        // against the SDK. The bridge's factory-side request is authoritative
        // there: a later attach invokes Submission.fullTree under the SDK lock.
        // A full encode is not a publication and consumes no platform request.
        const requested = if (full) false else self.takeTreeRequest();
        const declare_tree = full or !self.tree.published or requested;
        const gpa = self.gpa;
        const count = snapshot.count();
        try self.reserveSnapshot(snapshot);
        @memset(self.tree.send[0..count], declare_tree);
        self.tree.reset();

        // Full declarations also establish the next incremental diff's hashes.
        for (snapshot.nodes, 0..) |node, index| {
            const hash = self.hashNode(node);
            try self.tree.current.put(gpa, node.id, hash);
            if (!declare_tree and self.tree.previous.get(node.id) != hash) {
                self.tree.send[index] = true;
            }
        }
        if (!declare_tree) {
            // Mark changed nodes and their ancestors.
            var index = count;
            while (index > 0) {
                index -= 1;
                if (!self.tree.send[index]) continue;
                const node = snapshot.nodes[index];
                if (node.parent == semantics.no_node) continue;
                const parent = snapshot.index.get(node.parent) orelse continue;
                self.tree.send[parent] = true;
            }
        }

        // Pass three: emit the marked nodes in published order, so a parent
        // always precedes its children.
        for (snapshot.nodes, 0..) |node, i| {
            if (!self.tree.send[i]) continue;
            try self.appendNode(node);
        }
        const name = sliceOf(self.toolkit);
        const version = sliceOf(self.version);
        const focus = if (snapshot.focus == semantics.no_node)
            snapshot.root
        else
            snapshot.focus;
        if (!full and self.bridge != null) self.setWindowFocused(options.focused);
        return .{
            .root = snapshot.root,
            // A re-activated adapter has dropped the platform tree, so the
            // first update after activation must be a full one.
            .has_tree_init = declare_tree,
            .toolkit_name = name.ptr,
            .toolkit_name_len = name.len,
            .toolkit_version = version.ptr,
            .toolkit_version_len = version.len,
            .focus = focus,
            .nodes = self.tree.nodes.items.ptr,
            .nodes_len = self.tree.nodes.items.len,
        };
    }

    /// Convert one node into the platform's borrowed tree view.
    fn appendNode(self: *Adapter, node: semantics.Node) Error!void {
        return self.appendNodeWith(false, node);
    }

    /// `appendNode` for a caller that already reserved the whole snapshot.
    ///
    /// This form cannot allocate and cannot fail, which is what lets
    /// `Submission.fullTree` declare a tree from inside the SDK's own call
    /// without carrying a recovery path it could only raise across the ABI.
    fn appendNodeReserved(self: *Adapter, node: semantics.Node) void {
        self.appendNodeWith(true, node) catch |err| std.debug.panic(
            "reserved append failed with capacity already funded: {s}",
            .{@errorName(err)},
        );
    }

    /// The one conversion both publish passes share. `reserved` says
    /// `reserveSnapshot` already funded every slot the WHOLE snapshot needs.
    fn appendNodeWith(
        self: *Adapter,
        comptime reserved: bool,
        node: semantics.Node,
    ) Error!void {
        const gpa = self.gpa;
        const children_start = self.tree.children.items.len;
        try pushSlice(u64, reserved, gpa, &self.tree.children, node.children);
        const controls_start = self.tree.controls.items.len;
        try pushSlice(u64, reserved, gpa, &self.tree.controls, node.relations.controls);
        const described_start = self.tree.described_by.items.len;
        try pushSlice(u64, reserved, gpa, &self.tree.described_by, node.relations.described_by);
        const labelled_start = self.tree.labelled_by.items.len;
        try pushSlice(u64, reserved, gpa, &self.tree.labelled_by, node.relations.labelled_by);
        const flow_start = self.tree.flow_to.items.len;
        if (node.relations.flow_to) |flow| try pushSlice(u64, reserved, gpa, &self.tree.flow_to, flow);

        // Named actions cross as borrowed spans of one tree-wide list, the same
        // way children and relations do. The whole snapshot's descriptors were
        // reserved before this pass, so the list cannot grow under a span that
        // was already taken, and the pointer below can be read in place rather
        // than in a second pass over every node.
        const customs_start = self.tree.customs.items.len;
        if (publishesCustomActions(node)) {
            for (node.custom_actions) |action| {
                const wording = sliceOf(action.name);
                try pushOne(c.nogui_accesskit_custom_action, reserved, gpa, &self.tree.customs, .{
                    .id = action.id,
                    .name = wording.ptr,
                    .name_len = wording.len,
                });
            }
        }

        // Character geometry crosses the boundary in physical pixels; the core
        // never sees a scale factor.
        const lengths_start = self.tree.lengths.items.len;
        const positions_start = self.tree.positions.items.len;
        const widths_start = self.tree.widths.items.len;
        if (node.text) |text| {
            try pushSlice(u8, reserved, gpa, &self.tree.lengths, text.character_lengths);
            for (text.character_positions) |x| {
                try pushOne(f32, reserved, gpa, &self.tree.positions, x * self.scale_x);
            }
            for (text.character_widths) |w| {
                try pushOne(f32, reserved, gpa, &self.tree.widths, w * self.scale_x);
            }
        }

        // Character tables convert byte offsets. An empty value also has one
        // valid position: its collapsed caret at zero. Other tableless runs
        // carry no selection.
        const has_selection = if (node.text) |text|
            text.addressable() and text.selection != null
        else
            false;
        const selection = if (has_selection) Selection.of(node.text.?) else Selection{};
        const name = sliceOf(node.name);
        const description = sliceOf(node.description);
        const value = valueSliceOf(node.value);
        const shortcut = sliceOf(node.shortcut);
        const placeholder = sliceOf(if (node.text) |text| text.placeholder else "");
        const children = self.tree.children.items[children_start..];
        const controls = self.tree.controls.items[controls_start..];
        const described_by = self.tree.described_by.items[described_start..];
        const labelled_by = self.tree.labelled_by.items[labelled_start..];
        const flow_to = self.tree.flow_to.items[flow_start..];
        const lengths = self.tree.lengths.items[lengths_start..];
        const positions = self.tree.positions.items[positions_start..];
        const widths = self.tree.widths.items[widths_start..];
        const named = self.tree.customs.items[customs_start..];
        const bounds = node.bounds;
        const numeric = switch (node.value) {
            .number => |number| number,
            else => 0,
        };
        const set_size = node.relations.row_count orelse 0;
        const position = node.relations.row_index orelse node.relations.position_in_set;

        try pushOne(c.nogui_accesskit_node, reserved, gpa, &self.tree.nodes, .{
            .id = node.id,
            .role = @intFromEnum(node.role),
            .flags = flagsOf(node),
            .actions = actionMask(node.actions, node.states.read_only),
            .bounds = .{
                .x0 = @as(f64, @floatCast(bounds.x)) * self.scale_x,
                .y0 = @as(f64, @floatCast(bounds.y)) * self.scale_y,
                .x1 = @as(f64, @floatCast(bounds.x + bounds.w)) * self.scale_x,
                .y1 = @as(f64, @floatCast(bounds.y + bounds.h)) * self.scale_y,
            },
            .label = name.ptr,
            .label_len = name.len,
            .description = description.ptr,
            .description_len = description.len,
            .value = value.ptr,
            .value_len = value.len,
            .shortcut = shortcut.ptr,
            .shortcut_len = shortcut.len,
            .placeholder = placeholder.ptr,
            .placeholder_len = placeholder.len,
            .numeric_value = numeric,
            .has_numeric_value = node.value == .number,
            .min_numeric_value = if (node.range) |range| range.min else 0,
            .has_min_numeric_value = node.range != null,
            .max_numeric_value = if (node.range) |range| range.max else 0,
            .has_max_numeric_value = node.range != null,
            .numeric_step = if (node.range) |range| range.step orelse 0 else 0,
            .has_numeric_step = if (node.range) |range| range.step != null else false,
            .text_cursor = selection.focus,
            .text_selection_anchor = selection.anchor,
            .text_selection_focus = selection.focus,
            .has_text_selection = has_selection,
            // The selection is a position in the run's characters, and the
            // platform reads it back through the node it was published for.
            // Naming the run keeps the caret the app published and the caret
            // the app receives describing the same place.
            .text_selection_owner = if (node.text_run) |run| run else node.id,
            .character_lengths = lengths.ptr,
            .character_lengths_len = lengths.len,
            .character_positions = positions.ptr,
            .character_positions_len = positions.len,
            .character_widths = widths.ptr,
            .character_widths_len = widths.len,
            .children = children.ptr,
            .children_len = children.len,
            .active_descendant = node.relations.active_descendant orelse 0,
            .controls = controls.ptr,
            .controls_len = controls.len,
            .described_by = described_by.ptr,
            .described_by_len = described_by.len,
            .labelled_by = labelled_by.ptr,
            .labelled_by_len = labelled_by.len,
            .flow_to = flow_to.ptr,
            .flow_to_len = flow_to.len,
            .member_of = node.relations.member_of orelse 0,
            .row_count_set_size = @intCast(set_size),
            .row_index_position = position orelse 0,
            .has_row_index_position = position != null,
            // A hidden or disabled node publishes no named action at all, so
            // this span is empty there rather than a list the platform would
            // offer but the model would refuse.
            .custom_actions = named.ptr,
            .custom_actions_len = named.len,
        });
    }

    /// Content hash of one node. Bounds are part of it: a control that moved
    /// must reach the platform even when nothing else changed.
    ///
    /// Fields are hashed one at a time on purpose. Raw struct bytes would
    /// include undefined padding, which would make an unchanged node look
    /// changed and re-announce it for no reason.
    ///
    /// Every field the update PUBLISHES belongs in this hash. A published
    /// field left out here is a field the platform can never learn changed:
    /// the incremental update that would carry it is precisely the update
    /// this hash decides, so an unchanged hash means an unchanged update and
    /// the stale value stays live for as long as the node does.
    fn hashNode(self: *Adapter, node: semantics.Node) u64 {
        var hasher = std.hash.Wyhash.init(0x41_43_43_01);
        hasher.update(std.mem.asBytes(&node.id));
        hasher.update(std.mem.asBytes(&node.role));
        hasher.update(node.name);
        hasher.update(node.description);
        hasher.update(node.shortcut);
        hasher.update(node.value_description);
        hasher.update(std.mem.asBytes(&node.bounds.x));
        hasher.update(std.mem.asBytes(&node.bounds.y));
        hasher.update(std.mem.asBytes(&node.bounds.w));
        hasher.update(std.mem.asBytes(&node.bounds.h));
        const states = node.states;
        for ([_]bool{
            states.hidden,
            states.disabled,
            states.focused,
            states.focusable,
            states.selected,
            states.expanded,
            states.expandable,
            states.required,
            states.invalid,
            states.modal,
            states.multiselectable,
            states.read_only,
            states.busy,
            states.live_region,
        }) |flag| hasher.update(std.mem.asBytes(&@as(u8, @intFromBool(flag))));
        hasher.update(std.mem.asBytes(&@as(u8, @intFromEnum(states.checked))));
        hasher.update(std.mem.asBytes(&@as(u16, @bitCast(node.actions))));
        hashIds(&hasher, node.children);
        hashIds(&hasher, node.relations.controls);
        hashIds(&hasher, node.relations.described_by);
        hashIds(&hasher, node.relations.labelled_by);
        if (node.relations.flow_to) |flow| hashIds(&hasher, flow);
        if (node.relations.active_descendant) |target| hasher.update(std.mem.asBytes(&target));
        if (node.relations.member_of) |target| hasher.update(std.mem.asBytes(&target));
        if (node.relations.row_index) |at| hasher.update(std.mem.asBytes(&at));
        if (node.relations.row_count) |at| hasher.update(std.mem.asBytes(&at));
        if (node.relations.position_in_set) |at| hasher.update(std.mem.asBytes(&at));
        // The run a node's selection is measured in is a PUBLISHED field:
        // `appendNode` sends it as `text_selection_owner`. Without it in the
        // identity a node that re-points at a different run hashes exactly as
        // it did before, the incremental update omits it, and the platform
        // keeps addressing the OLD run's characters. Every selection the
        // reader then sends names a node this update never carried.
        if (node.text_run) |run| hasher.update(std.mem.asBytes(&run));
        // A named action is part of the node's published identity: a renamed,
        // added or removed action has to reach the platform or the reader goes
        // on offering the app's old wording. Each name is hashed with its
        // length, so two different splits of the same characters differ.
        if (publishesCustomActions(node)) {
            for (node.custom_actions) |action| {
                hasher.update(std.mem.asBytes(&action.id));
                hasher.update(std.mem.asBytes(&action.name.len));
                hasher.update(action.name);
            }
        }
        // A published row node's identity is its key, so a selection that
        // moved to another row is a change the platform must learn about.
        if (node.row) |row| {
            hasher.update(std.mem.asBytes(&row.list));
            hasher.update(std.mem.asBytes(&row.index));
            hasher.update(std.mem.asBytes(&row.key));
        }
        if (node.range) |range| {
            hasher.update(std.mem.asBytes(&range.min));
            hasher.update(std.mem.asBytes(&range.max));
            if (range.step) |step| hasher.update(std.mem.asBytes(&step));
            if (range.percent) |percent| hasher.update(std.mem.asBytes(&percent));
        }
        switch (node.value) {
            .none => {},
            .text => |text| hasher.update(text),
            .number => |number| hasher.update(std.mem.asBytes(&number)),
        }
        if (node.text) |text| {
            hasher.update(text.value);
            hasher.update(text.placeholder);
            hasher.update(std.mem.asBytes(&@as(u8, @intFromBool(text.multiline))));
            // PRESENCE is published: `appendNode` sends `has_text_selection`,
            // which is false for a run with no selection and true for one
            // whose caret happens to sit at zero. `Selection.of` maps both to
            // the same two numbers, so hashing only the resolved endpoints
            // would let a caret that APPEARED hash exactly as the run without
            // one, and the platform would never learn it has a selection.
            hasher.update(std.mem.asBytes(&@as(u8, @intFromBool(text.selection != null))));
            // Hashed in the platform's own units: two byte offsets that name
            // the same character positions are the same selection there, and
            // re-sending it would re-announce an unchanged caret.
            const selection = Selection.of(text);
            hasher.update(std.mem.asBytes(&selection.anchor));
            hasher.update(std.mem.asBytes(&selection.focus));
            hasher.update(text.character_lengths);
            // Scaled geometry: one tree at two scales is two trees.
            for (text.character_positions) |x| {
                const scaled: f32 = x * self.scale_x;
                hasher.update(std.mem.asBytes(&scaled));
            }
            for (text.character_widths) |w| {
                const scaled: f32 = w * self.scale_x;
                hasher.update(std.mem.asBytes(&scaled));
            }
        }
        // A scale change re-scales every coordinate, so it is part of the
        // identity of the published tree.
        hasher.update(std.mem.asBytes(&self.scale_x));
        hasher.update(std.mem.asBytes(&self.scale_y));
        return hasher.final();
    }
};

/// The node state bitmask the bridge understands. The core keeps typed
/// state; the bit layout is the bridge's, and lives only here.
fn flagsOf(node: semantics.Node) u32 {
    var flags: u32 = 0;
    if (node.states.hidden) flags |= 1 << 0;
    if (node.states.disabled) flags |= 1 << 1;
    if (node.states.focused) flags |= 1 << 2;
    if (node.states.selected) flags |= 1 << 3;
    // AccessKit distinguishes selected=false from a missing selection
    // property. A published row's click action is its selection capability.
    if (node.row != null and node.actions.has(.click)) flags |= 1 << 16;
    if (node.states.expanded) flags |= 1 << 4;
    if (node.states.expandable and !node.states.expanded) flags |= 1 << 5;
    if (node.states.required) flags |= 1 << 6;
    if (node.states.invalid) flags |= 1 << 7;
    if (node.states.modal) flags |= 1 << 8;
    if (node.states.multiselectable) flags |= 1 << 9;
    if (node.states.read_only) flags |= 1 << 10;
    if (node.states.busy) flags |= 1 << 11;
    if (node.states.live_region) flags |= 1 << 12;
    switch (node.states.checked) {
        .on => flags |= 1 << 13,
        .off => flags |= 1 << 14,
        .mixed => flags |= 1 << 15,
        .not_toggleable => {},
    }
    return flags;
}

/// Map packed storage bits to the sparse action discriminants in the C ABI.
///
/// One fact narrows the core's own mask, and it narrows it where the tree is
/// built rather than at the request: `read_only` means NO CONTENTS MUTATION,
/// so a read-only node publishes nothing from `mutatingActions`. The core
/// refuses each of those writes with `.ignored = .unsupported_action` even
/// when the app forced the action into its own action set, so the offer must
/// not reach the platform: a reader handed a control the application then
/// refuses cannot be told apart from a broken app. The value and the range
/// still cross, because announcing them is why a read-only control is
/// published at all.
///
/// A caret is not a mutation, so `set_text_selection` stays, and so does
/// `click`. A DISABLED node is not this rule either: the core refuses every
/// action on one with `.ignored = .disabled`, a different refusal with a
/// wider scope, and the state bit is what announces the control as out of
/// reach. Withholding its actions as well would publish a node the core would
/// never have driven.
fn actionMask(actions: semantics.ActionSet, read_only: bool) u32 {
    var mask: u32 = 0;
    inline for (std.meta.tags(semantics.Action)) |action| {
        if (actions.has(action)) mask |= @as(u32, 1) << @intCast(@intFromEnum(action));
    }
    if (read_only) mask &= ~mutatingActions();
    return mask;
}

/// Every action that changes WHAT a node shows, and so every action a
/// read-only node must not publish.
///
/// These four are exactly the writes `semantics.Snapshot.dispatch` refuses for
/// a read-only node: a whole value in either payload shape, a number, a step
/// and a replacement inside the field's own text. Nothing else in the mask is
/// a mutation — a caret, a click, a focus, a named action and a scroll change
/// what the reader is looking at, not what the control holds.
///
/// The bits are named by `semantics.Action` rather than by a hand-written set,
/// and this is the SAME four the mobile adapter's `mutatingActions` names,
/// because both adapters gate on the one identity: each shim refuses a
/// request whose `1u << action` bit the node does not carry, so what this
/// function withholds is exactly what the platform can never be asked for.
pub fn mutatingActions() u32 {
    return (1 << @intFromEnum(semantics.Action.set_value)) |
        (1 << @intFromEnum(semantics.Action.increment)) |
        (1 << @intFromEnum(semantics.Action.decrement)) |
        (1 << @intFromEnum(semantics.Action.replace_selected_text));
}

/// Whether this node's named actions reach the platform.
///
/// A hidden or disabled node publishes none, which is the same rule the core
/// applies to every other action: `Node.isInteractive` counts a node's own
/// custom actions but refuses a hidden or disabled one, and `dispatch` refuses
/// the request. Advertising a name the model would then refuse is the one
/// outcome a screen reader cannot be told apart from a broken app, so the gate
/// sits where the tree is built rather than at the request.
///
/// The core's own action bit decides, not the presence of a descriptor.
/// `Draft.actions` REPLACES the action set rather than adding to it, so an app
/// that states its own policy drops the bit its descriptors arrived with. The
/// model refuses that node's `custom_action`, and the platform must not be
/// handed a wording the model would refuse. One predicate answers for the
/// reservation, the append and the hash, so all three agree on one node.
///
/// Nothing here touches the descriptors themselves. An ID stays the signed
/// value the app declared, a name stays the bytes the app wrote, and a name
/// that is empty stays an empty name.
fn publishesCustomActions(node: semantics.Node) bool {
    if (node.states.hidden or node.states.disabled) return false;
    return node.actions.has(.custom_action);
}

/// Append `items` into a list whose capacity is already funded when
/// `reserved` is set.
///
/// The reserved form cannot fail, which is what lets the one append that
/// happens inside a Rust-invoked callback hold no error path at all: a Zig
/// panic raised in a `callconv(.c)` frame the bridge called unwinds through
/// Rust frames that have no landing pad, which is undefined behaviour rather
/// than a contained failure.
fn pushSlice(
    comptime T: type,
    comptime reserved: bool,
    gpa: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(T),
    items: []const T,
) Error!void {
    if (reserved) {
        list.appendSliceAssumeCapacity(items);
    } else {
        try list.appendSlice(gpa, items);
    }
}

/// One element of a list whose capacity is already funded when `reserved` is
/// set. See `pushSlice`.
fn pushOne(
    comptime T: type,
    comptime reserved: bool,
    gpa: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(T),
    item: T,
) Error!void {
    if (reserved) {
        list.appendAssumeCapacity(item);
    } else {
        try list.append(gpa, item);
    }
}

/// Feed node identities into the content hash as raw little-endian bytes.
fn hashIds(hasher: *std.hash.Wyhash, ids: []const NodeId) void {
    for (ids) |id| hasher.update(std.mem.asBytes(&id));
}

fn rect(values: [4]f64) c.nogui_accesskit_rect {
    return .{ .x0 = values[0], .y0 = values[1], .x1 = values[2], .y1 = values[3] };
}

fn sliceOf(bytes: []const u8) struct { ptr: [*c]const u8, len: usize } {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

/// Non-null storage for a present empty value. The bridge does not read it.
const present_empty_value: [1]u8 = .{0};

/// Text keeps a non-null pointer even when empty. Non-text has no string.
fn valueSliceOf(value: semantics.Value) struct { ptr: [*c]const u8, len: usize } {
    return switch (value) {
        .text => |text| if (text.len == 0)
            .{ .ptr = &present_empty_value, .len = 0 }
        else
            .{ .ptr = text.ptr, .len = text.len },
        .none, .number => .{ .ptr = @as([*c]const u8, @ptrFromInt(0)), .len = 0 },
    };
}

/// The callbacks handed to the bridge. They run on an AccessKit thread and
/// only record what the platform asked for; they never touch the application.
///
/// Activation and deactivation record the SAME fact from opposite ends: either
/// way the platform holds no tree of this window, and AT-SPI builds the tree
/// it serves out of the first update it is handed after the request, so one
/// without a root tree takes the platform down.
const AdapterCallbacks = struct {
    /// Report whether the ring took the request.
    ///
    /// The return is the ACTUAL queue acceptance, including a full ring, an
    /// oversize payload and a payload this edge refuses to interpret. It is
    /// a promise about the ring and nothing else: acceptance is
    /// asynchronous and is never a claim that the model changed, which only
    /// reading the model back can say. A platform whose upstream handler is
    /// void may ignore it; a typed EditableText handler must not, because
    /// refusing here is what stops it announcing an edit that was dropped.
    ///
    /// A null host is a refusal rather than a silent success: there is no
    /// ring to accept anything.
    fn onAction(user: ?*anyopaque, request: [*c]const c.nogui_accesskit_request) callconv(.c) u8 {
        const adapter: *Adapter = @ptrCast(@alignCast(user orelse return 0));
        return @intFromBool(adapter.enqueue(request));
    }

    fn onActivate(user: ?*anyopaque) callconv(.c) void {
        const adapter: *Adapter = @ptrCast(@alignCast(user orelse return));
        adapter.noteTreeRequest();
    }

    fn onDeactivate(user: ?*anyopaque) callconv(.c) void {
        const adapter: *Adapter = @ptrCast(@alignCast(user orelse return));
        adapter.noteTreeRequest();
    }
};

/// The snapshot both tree tests publish: the window root, a container that
/// owns four controls, and a `controls` relation from that container to the
/// check box. It is the shape the core publishes, and it carries children AND
/// a relation, so an update that declares the flag without the nodes behind
/// it is visible in both.
fn fillTreeSnapshot(
    gpa: std.mem.Allocator,
    index: *std.AutoHashMapUnmanaged(NodeId, u32),
    nodes: *[6]semantics.Node,
) !void {
    const window: NodeId = semantics.window_node;
    const container: NodeId = 100;
    const save: NodeId = 101;
    const wrap: NodeId = 102;
    const field: NodeId = 103;
    const volume: NodeId = 104;
    nodes[0] = .{
        .id = window,
        .parent = semantics.no_node,
        .role = .window,
        .bounds = .{ .x = 0, .y = 0, .w = 400, .h = 300 },
    };
    nodes[1] = .{
        .id = container,
        .parent = window,
        .role = .generic_container,
        .name = "Document",
        .bounds = .{ .x = 0, .y = 0, .w = 400, .h = 300 },
        .children = &.{ save, wrap, field, volume },
        .relations = .{ .controls = &.{wrap} },
    };
    nodes[2] = .{
        .id = save,
        .parent = container,
        .role = .button,
        .name = "Save",
        .bounds = .{ .x = 8, .y = 8, .w = 80, .h = 24 },
        .actions = .{ .click = true, .focus = true },
    };
    nodes[3] = .{
        .id = wrap,
        .parent = container,
        .role = .check_box,
        .name = "Wrap",
        .bounds = .{ .x = 8, .y = 40, .w = 80, .h = 24 },
        .actions = .{ .click = true },
        .states = .{ .checked = .off },
    };
    nodes[4] = .{
        .id = field,
        .parent = container,
        .role = .text_input,
        .name = "Field",
        .bounds = .{ .x = 8, .y = 72, .w = 200, .h = 24 },
        .actions = .{ .set_text_selection = true },
        .text = .{
            .value = "body",
            .selection = .{ .anchor = 0, .focus = 4 },
            .character_lengths = &.{ 1, 1, 1, 1 },
        },
    };
    nodes[5] = .{
        .id = volume,
        .parent = container,
        .role = .slider,
        .name = "Volume",
        .bounds = .{ .x = 8, .y = 104, .w = 200, .h = 24 },
        .actions = .{ .set_value = true, .increment = true, .decrement = true },
        .value = .{ .number = 0.5 },
        .range = .{ .min = 0, .max = 1, .step = 0.05 },
    };
    for (nodes, 0..) |node, slot| try index.put(gpa, node.id, @intCast(slot));
}

/// Whether this update carries `id`. A declared tree is one the platform can
/// walk, so a relation naming a node the update does not carry is a broken
/// declaration and not a smaller one.
fn declares(update: native_tree, id: NodeId) bool {
    for (update.nodes[0..update.nodes_len]) |node| {
        if (node.id == id) return true;
    }
    return false;
}

/// The node the platform received for `id`, exactly as the bridge got it. A
/// mask the adapter narrowed is only real once it has crossed, so an assertion
/// about one reads the wire rather than the function that filled it.
fn encodedNode(update: native_tree, id: NodeId) ?c.nogui_accesskit_node {
    for (update.nodes[0..update.nodes_len]) |node| {
        if (node.id == id) return node;
    }
    return null;
}

/// The update carries every node of the snapshot, every child and relation
/// that node names resolves inside that same update, and no node is declared
/// under a parent the update leaves out.
fn expectDeclaredTree(update: native_tree, snapshot: *const semantics.Snapshot) !void {
    try std.testing.expectEqual(snapshot.root, update.root);
    try std.testing.expectEqual(snapshot.count(), update.nodes_len);
    for (snapshot.nodes) |node| {
        try std.testing.expect(declares(update, node.id));
        for (node.children) |child| try std.testing.expect(declares(update, child));
        for (node.relations.controls) |target| try std.testing.expect(declares(update, target));
        if (node.parent != semantics.no_node) {
            try std.testing.expect(declares(update, node.parent));
        }
    }
}

/// The bridge's own activation and deactivation callbacks, invoked the way
/// the platform invokes them, so a test drives the seam a screen reader drives
/// instead of writing the adapter's bookkeeping by hand.
fn activate(adapter: *Adapter) void {
    AdapterCallbacks.onActivate(@ptrCast(adapter));
}

fn deactivate(adapter: *Adapter) void {
    AdapterCallbacks.onDeactivate(@ptrCast(adapter));
}

/// What `publish` records once the platform holds the update: the diff
/// history advances, the tree counts as published, and the platform's request
/// for a tree is retired by an update that declared the whole hierarchy.
///
/// These tests drive `build` directly because a host built without the bridge
/// never reaches a platform at all, and the transition under test is the one a
/// screen reader causes. A conversion that failed never reaches this point,
/// which is what keeps a failed update from being recorded as one the platform
/// holds.
fn acceptUpdate(adapter: *Adapter, update: native_tree) void {
    std.mem.swap(
        std.AutoHashMapUnmanaged(NodeId, u64),
        &adapter.tree.previous,
        &adapter.tree.current,
    );
    adapter.tree.published = true;
    adapter.last_full = update.has_tree_init;
}

test "api-w21 the update a screen reader is served on declares the whole tree" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(std.testing.allocator, threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    var nodes: [6]semantics.Node = undefined;
    try fillTreeSnapshot(std.testing.allocator, &index, &nodes);
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = semantics.no_node,
        .nodes = &nodes,
        .index = &index,
    };
    const save = nodes[2].id;
    const wrap = nodes[3].id;
    const field = nodes[4].id;
    const volume = nodes[5].id;

    // The ordinary first publish, through the entry point a host uses, with
    // no reader attached. This is the state a running app is in when one
    // arrives: it has published, and the platform holds nothing.
    try std.testing.expectEqual(snapshot.count(), try adapter.publish(&snapshot, .{}));
    try std.testing.expect(adapter.lastWasFullTree());

    // The bridge asked the platform for nothing and answered the reader's
    // request for a tree with nothing, so the platform installed a placeholder
    // and waits for one that replaces it. That update carries every node and
    // not only what changed: a reader receiving a declaration holding one
    // control cannot reach the rest of the window at all.
    activate(&adapter);
    const activation = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(activation.has_tree_init);
    try expectDeclaredTree(activation, &snapshot);
    // Declaring the whole tree is not the same as forgetting the frame's
    // history: the next update diffs against a hash per node instead of
    // re-sending every control to a reader that already has them.
    try std.testing.expectEqual(snapshot.count(), adapter.tree.current.count());
    acceptUpdate(&adapter, activation);

    // Ordinary updates on the tree the reader holds stay incremental, so a
    // control the user did not touch is not announced again.
    const quiet = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(!quiet.has_tree_init);
    try std.testing.expect(quiet.nodes_len < snapshot.count());
    try std.testing.expect(!declares(quiet, save));
    try std.testing.expect(!declares(quiet, wrap));
    try std.testing.expect(!declares(quiet, field));
    try std.testing.expect(!declares(quiet, volume));
    acceptUpdate(&adapter, quiet);

    // A control that changed reaches the platform with the ancestors that
    // carry it, and nothing else is dragged along with it.
    nodes[3].states.checked = .on;
    const changed = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(!changed.has_tree_init);
    try std.testing.expect(declares(changed, wrap));
    try std.testing.expect(!declares(changed, save));
    try std.testing.expect(changed.nodes_len < snapshot.count());
    acceptUpdate(&adapter, changed);

    // The reader went away and came back, and the host published nothing in
    // between: both cycles report the platform as attached from the same
    // flag, so nothing but the requests themselves distinguishes them. The
    // platform holds no tree of ours now, so the next update has to declare
    // the hierarchy a second time rather than assume the one the first
    // activation installed is still there.
    deactivate(&adapter);
    activate(&adapter);
    const again = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(again.has_tree_init);
    try expectDeclaredTree(again, &snapshot);
    acceptUpdate(&adapter, again);

    // Which retires the request: the update after it is an ordinary diff again,
    // so a reader that asks once per attach is served one whole declaration
    // each time and nothing more.
    const after = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(!after.has_tree_init);
    try std.testing.expect(!declares(after, save));
    try std.testing.expect(!declares(after, wrap));
}

test "api-w21 a publish that cannot convert leaves the tree the platform holds" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(failing.allocator(), threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    var nodes: [6]semantics.Node = undefined;
    try fillTreeSnapshot(std.testing.allocator, &index, &nodes);
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = semantics.no_node,
        .nodes = &nodes,
        .index = &index,
    };
    const wrap = nodes[3].id;

    try std.testing.expectEqual(snapshot.count(), try adapter.publish(&snapshot, .{}));
    // The platform is serving this tree to a reader, and a reader asks again
    // for every attach, so an update that cannot convert must not retire a
    // request that reached nothing.
    activate(&adapter);

    // The conversion cannot allocate, so the update never leaves the adapter
    // and the check box it would have carried stays uncommitted.
    failing.fail_index = failing.alloc_index;
    nodes[3].states.checked = .on;
    try std.testing.expectError(error.OutOfMemory, adapter.publish(&snapshot, .{}));
    try std.testing.expect(failing.has_induced_failure);

    // Nothing about the failed update was recorded: the frame history is still
    // the one the good publish left, and the request it took is standing
    // again, because the platform never saw the update that would have
    // answered it.
    try std.testing.expectEqual(snapshot.count(), adapter.tree.previous.count());

    // So the retry declares the hierarchy the platform is waiting for rather
    // than a diff against a tree it does not hold, and it carries the check
    // box the failed one would have sent.
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(snapshot.count(), try adapter.publish(&snapshot, .{}));
    try std.testing.expect(adapter.lastWasFullTree());
    var sent: [8]NodeId = undefined;
    const after = adapter.lastNodes(&sent);
    try std.testing.expect(std.mem.indexOfScalar(NodeId, after, wrap) != null);

    // And the frames after it are ordinary diffs again, because the request is
    // retired by exactly the update that answered it.
    try std.testing.expect(try adapter.publish(&snapshot, .{}) < snapshot.count());
    try std.testing.expect(!adapter.lastWasFullTree());
}

test "api-w21 a reader that keeps reattaching is served the whole tree every time" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(std.testing.allocator, threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    var nodes: [6]semantics.Node = undefined;
    try fillTreeSnapshot(std.testing.allocator, &index, &nodes);
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = semantics.no_node,
        .nodes = &nodes,
        .index = &index,
    };

    try std.testing.expectEqual(snapshot.count(), try adapter.publish(&snapshot, .{}));

    // Several attach/detach cycles in a row with NOTHING in the tree changing.
    // This is the case the platform's own report cannot express: it answers
    // "attached" for the first cycle and for the last one, so a host that
    // compares that answer with the previous one sees no transition and
    // assumes the platform still holds what it published for the first attach.
    // The platform dropped it, and an update carrying only a diff against a
    // tree nobody holds leaves it with no root tree at all.
    for (0..4) |_| {
        activate(&adapter);
        const declaration = try adapter.build(&snapshot, .{}, false);
        try std.testing.expect(declaration.has_tree_init);
        try expectDeclaredTree(declaration, &snapshot);
        acceptUpdate(&adapter, declaration);

        // The tree is identical, so an update inside the same attach carries
        // nothing: one declaration per attach, not one per frame.
        const quiet = try adapter.build(&snapshot, .{}, false);
        try std.testing.expect(!quiet.has_tree_init);
        try std.testing.expect(quiet.nodes_len < snapshot.count());
        acceptUpdate(&adapter, quiet);

        // The reader left without the host publishing again, which is exactly
        // what a reader that comes straight back looks like from here.
        deactivate(&adapter);
    }

    // A reader that asks once and stays leaves the frames after its own
    // declaration alone, so a long-lived session is not a full tree per frame.
    activate(&adapter);
    const settled = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(settled.has_tree_init);
    acceptUpdate(&adapter, settled);
    for (0..8) |_| {
        const steady = try adapter.build(&snapshot, .{}, false);
        try std.testing.expect(!steady.has_tree_init);
        acceptUpdate(&adapter, steady);
    }
    try std.testing.expectEqual(snapshot.count(), adapter.tree.previous.count());
}

test "api-w21 a changed branch publishes its ancestors without touching a sibling branch" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(std.testing.allocator, threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    var nodes = [_]semantics.Node{
        .{
            .id = semantics.window_node,
            .parent = semantics.no_node,
            .role = .window,
            .bounds = .{ .x = 0, .y = 0, .w = 400, .h = 300 },
            .children = &.{ 100, 200 },
        },
        .{
            .id = 100,
            .parent = semantics.window_node,
            .role = .generic_container,
            .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
            .children = &.{101},
        },
        .{
            .id = 101,
            .parent = 100,
            .role = .button,
            .name = "Original",
            .bounds = .{ .x = 0, .y = 0, .w = 80, .h = 24 },
        },
        .{
            .id = 200,
            .parent = semantics.window_node,
            .role = .generic_container,
            .bounds = .{ .x = 100, .y = 0, .w = 100, .h = 100 },
            .children = &.{201},
        },
        .{
            .id = 201,
            .parent = 200,
            .role = .button,
            .name = "Unchanged",
            .bounds = .{ .x = 100, .y = 0, .w = 80, .h = 24 },
        },
    };
    for (nodes, 0..) |node, slot| try index.put(std.testing.allocator, node.id, @intCast(slot));
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = 101,
        .nodes = &nodes,
        .index = &index,
    };
    _ = try adapter.publish(&snapshot, .{});
    nodes[2].name = "Changed";
    _ = try adapter.publish(&snapshot, .{});
    try std.testing.expectEqualStrings("Changed", adapter.lastLabel(101).?);
    try std.testing.expect(adapter.lastRole(100) != null);
    try std.testing.expect(adapter.lastRole(semantics.window_node) != null);
    try std.testing.expect(adapter.lastRole(200) == null);
    try std.testing.expect(adapter.lastRole(201) == null);
}

test "api-w21 an activation after delta preparation needs no allocation to declare the tree" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(failing.allocator(), threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    var nodes: [6]semantics.Node = undefined;
    try fillTreeSnapshot(std.testing.allocator, &index, &nodes);
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = nodes[4].id,
        .nodes = &nodes,
        .index = &index,
    };
    _ = try adapter.publish(&snapshot, .{});
    nodes[3].states.checked = .on;
    var delta = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(!delta.has_tree_init);
    try std.testing.expect(!declares(delta, nodes[2].id));
    // The SDK asks only after preparation. Every allocation from this point
    // would fail, so the supplier cannot turn a Pending adapter into an OOM.
    activate(&adapter);
    failing.fail_index = failing.alloc_index;
    var submission: Adapter.Submission = .{
        .adapter = &adapter,
        .snapshot = &snapshot,
        .update = &delta,
    };
    const supplied = Adapter.Submission.fullTree(&submission).*;
    try expectDeclaredTree(supplied, &snapshot);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(!adapter.tree_requested);
    try std.testing.expectEqual(snapshot.count(), adapter.tree.current.count());
    acceptUpdate(&adapter, supplied);
    failing.fail_index = std.math.maxInt(usize);
    const quiet = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(!quiet.has_tree_init);
    try std.testing.expectEqual(@as(usize, 0), quiet.nodes_len);
}

test "api-w21 a node that re-points at another text run reaches the platform" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(std.testing.allocator, threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    const field: NodeId = 100;
    const run: NodeId = 101;
    const lengths = [_]u8{ 1, 1, 1, 1 };
    var nodes = [_]semantics.Node{
        .{
            .id = semantics.window_node,
            .parent = semantics.no_node,
            .role = .window,
            .bounds = .{ .x = 0, .y = 0, .w = 400, .h = 300 },
            .children = &.{ field, run },
        },
        .{
            .id = field,
            .parent = semantics.window_node,
            .role = .text_input,
            .name = "Field",
            .bounds = .{ .x = 8, .y = 8, .w = 200, .h = 24 },
            .actions = .{ .set_text_selection = true },
            .text_run = run,
            .text = .{
                .value = "body",
                .selection = .{ .anchor = 0, .focus = 4 },
                .character_lengths = &lengths,
            },
        },
        .{
            .id = run,
            .parent = field,
            .role = .text_run,
            .bounds = .{ .x = 8, .y = 8, .w = 40, .h = 24 },
            .text = .{
                .value = "body",
                .selection = .{ .anchor = 0, .focus = 4 },
                .character_lengths = &lengths,
            },
        },
    };
    for (nodes, 0..) |node, slot| try index.put(std.testing.allocator, node.id, @intCast(slot));
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = semantics.no_node,
        .nodes = &nodes,
        .index = &index,
    };

    try std.testing.expectEqual(snapshot.count(), try adapter.publish(&snapshot, .{}));
    try std.testing.expectEqual(run, adapter.lastTextSelectionOwner(field).?);

    // Nothing else about the node moved: same value, same character table,
    // same caret, same name. Only the run its characters are addressed in
    // changed, and THAT is a published field (`text_selection_owner`), so the
    // node has to be carried again. Miss it and the platform keeps addressing
    // the old run, and every selection the reader sends from then on names a
    // node this update never declared.
    nodes[1].text_run = null;
    const repointed = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(!repointed.has_tree_init);
    try std.testing.expect(declares(repointed, field));
    acceptUpdate(&adapter, repointed);
    try std.testing.expectEqual(field, adapter.lastTextSelectionOwner(field).?);
}

test "api-w21 a caret that appears on an otherwise unchanged run reaches the platform" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(std.testing.allocator, threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    const run: NodeId = 100;
    const lengths = [_]u8{ 1, 1, 1, 1 };
    var nodes = [_]semantics.Node{
        .{
            .id = semantics.window_node,
            .parent = semantics.no_node,
            .role = .window,
            .bounds = .{ .x = 0, .y = 0, .w = 400, .h = 300 },
            .children = &.{run},
        },
        .{
            .id = run,
            .parent = semantics.window_node,
            .role = .text_run,
            .bounds = .{ .x = 8, .y = 8, .w = 40, .h = 24 },
            .text = .{
                .value = "body",
                .character_lengths = &lengths,
            },
        },
    };
    for (nodes, 0..) |node, slot| try index.put(std.testing.allocator, node.id, @intCast(slot));
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = semantics.no_node,
        .nodes = &nodes,
        .index = &index,
    };

    try std.testing.expectEqual(snapshot.count(), try adapter.publish(&snapshot, .{}));
    try std.testing.expect(adapter.lastTextSelection(run) == null);

    // A caret that simply APPEARED: both endpoints are zero, so the resolved
    // selection is byte-for-byte the one `Selection.of` produces for a run with
    // no selection at all. `has_text_selection` still changed, and that bit is
    // what tells the platform a run now has characters to be read back, so the
    // node has to be carried again.
    nodes[1].text.?.selection = semantics.TextSelection.caret(0);
    const appeared = try adapter.build(&snapshot, .{}, false);
    try std.testing.expect(!appeared.has_tree_init);
    try std.testing.expect(declares(appeared, run));
    acceptUpdate(&adapter, appeared);
    const selection = adapter.lastTextSelection(run).?;
    try std.testing.expectEqual(@as(usize, 0), selection.anchor);
    try std.testing.expectEqual(@as(usize, 0), selection.focus);
}

test "api-w21 a read-only node publishes no action that would change its value" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var adapter: Adapter = undefined;
    adapter.initWithoutBridge(std.testing.allocator, threaded.io());
    defer adapter.deinit();
    var index: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    defer index.deinit(std.testing.allocator);
    const locked: NodeId = 100;
    const field: NodeId = 101;
    const off: NodeId = 102;
    const kids = [_]NodeId{ locked, field, off };
    var nodes = [_]semantics.Node{
        .{
            .id = semantics.window_node,
            .parent = semantics.no_node,
            .role = .window,
            .bounds = .{ .x = 0, .y = 0, .w = 400, .h = 300 },
            .children = &kids,
        },
        // A read-only NUMERIC control. It holds every write the core refuses on
        // it, because `read_only` is additive: an app can put the flag on a
        // node whose own policy kept the bits.
        .{
            .id = locked,
            .parent = semantics.window_node,
            .role = .slider,
            .name = "Volume",
            .bounds = .{ .x = 8, .y = 8, .w = 200, .h = 24 },
            .states = .{ .read_only = true },
            .value = .{ .number = 0.5 },
            .range = .{ .min = 0, .max = 1, .step = 0.25 },
            .actions = .{
                .click = true,
                .set_value = true,
                .increment = true,
                .decrement = true,
            },
        },
        // A read-only TEXT control, the case a numeric one cannot show. A caret
        // moves without changing a byte, so the core accepts a selection on a
        // read-only node and only the two writes that carry contents go.
        .{
            .id = field,
            .parent = semantics.window_node,
            .role = .text_input,
            .name = "Report",
            .bounds = .{ .x = 8, .y = 40, .w = 200, .h = 24 },
            .states = .{ .read_only = true },
            .actions = .{
                .click = true,
                .set_text_selection = true,
                .set_value = true,
                .replace_selected_text = true,
            },
            .text = .{
                .value = "body",
                .character_lengths = &.{ 1, 1, 1, 1 },
            },
        },
        // A DISABLED control on that same shape. The core refuses every action
        // on one with `.ignored = .disabled`, a different refusal with a wider
        // scope than read_only's, and the state bit is what announces it — so
        // the published mask is left alone.
        .{
            .id = off,
            .parent = semantics.window_node,
            .role = .slider,
            .name = "Muted",
            .bounds = .{ .x = 8, .y = 72, .w = 200, .h = 24 },
            .states = .{ .disabled = true },
            .value = .{ .number = 0.5 },
            .range = .{ .min = 0, .max = 1, .step = 0.25 },
            .actions = .{
                .click = true,
                .set_value = true,
                .increment = true,
                .decrement = true,
            },
        },
    };
    for (nodes, 0..) |node, slot| try index.put(std.testing.allocator, node.id, @intCast(slot));
    const snapshot: semantics.Snapshot = .{
        .generation = 1,
        .root = semantics.window_node,
        .focus = semantics.no_node,
        .nodes = &nodes,
        .index = &index,
    };

    const writes: u32 = mutatingActions();
    const click: u32 = 1 << @intFromEnum(semantics.Action.click);
    const caret: u32 = 1 << @intFromEnum(semantics.Action.set_text_selection);
    // The bits each node's OWN action set carries, named apart from the strip.
    // A slider publishes the three numeric writes and no text replacement; a
    // field publishes the whole-value door and a replacement and no step. So
    // `writes` is the strip, not any one node's mask, and an expectation that
    // reads it as the mask asks for a bit the node never published.
    const set_value: u32 = 1 << @intFromEnum(semantics.Action.set_value);
    const replace: u32 = 1 << @intFromEnum(semantics.Action.replace_selected_text);
    const steps: u32 = (1 << @intFromEnum(semantics.Action.increment)) |
        (1 << @intFromEnum(semantics.Action.decrement));
    try std.testing.expectEqual(writes, set_value | steps | replace);

    // The rule in both directions, over an action set that carries everything:
    // the mask a read-only node loses is EXACTLY `mutatingActions`, so a strip
    // that missed a write or took a caret fails here rather than on a platform.
    const every: semantics.ActionSet = .{
        .click = true,
        .focus = true,
        .scroll_into_view = true,
        .custom_action = true,
        .set_text_selection = true,
        .set_value = true,
        .increment = true,
        .decrement = true,
        .replace_selected_text = true,
    };
    try std.testing.expectEqual(actionMask(every, true) | writes, actionMask(every, false));

    const wire = try adapter.encodeFullSnapshot(&snapshot, .{});

    // The read-only slider offers nothing the core refuses. Its click stays,
    // because a click is not a mutation.
    const locked_node = encodedNode(wire, locked).?;
    try std.testing.expectEqual(@as(u32, 0), locked_node.actions & writes);
    try std.testing.expectEqual(click, locked_node.actions);
    // What makes a read-only control worth publishing still crosses: the value
    // and the range a reader announces and cannot write…
    try std.testing.expect(locked_node.has_numeric_value);
    try std.testing.expect(locked_node.has_min_numeric_value);
    try std.testing.expect(locked_node.has_max_numeric_value);
    try std.testing.expect(locked_node.has_numeric_step);
    // …and the state bit that tells it the control is read-only rather than
    // merely quiet, so the withheld actions are an explained absence.
    try std.testing.expect((locked_node.flags & (1 << 10)) != 0);

    // The CARET survives on a read-only field. Moving a caret changes no
    // contents, so the core accepts the selection and the platform must be
    // able to send it back; the two writes that carry contents do not.
    const field_node = encodedNode(wire, field).?;
    try std.testing.expect((field_node.actions & caret) != 0);
    try std.testing.expectEqual(@as(u32, 0), field_node.actions & writes);
    try std.testing.expectEqual(click | caret, field_node.actions);
    // The run crosses whole, because a read-only field is read, not driven.
    try std.testing.expectEqual(@as(usize, 4), field_node.character_lengths_len);

    // A DISABLED node is a different refusal, so it keeps everything it
    // published: read_only and disabled must not narrow one another. The mask
    // is this node's own four bits and no other, so the assertion also pins
    // that the adapter invented nothing here.
    try std.testing.expectEqual(click | set_value | steps, encodedNode(wire, off).?.actions);

    // The SAME node shapes with `read_only` clear publish every write they
    // carried, so what the strip withheld above was the read-only state and
    // not the role, the range, or this adapter's opinion of sliders.
    nodes[1].states.read_only = false;
    nodes[2].states.read_only = false;
    const writable = try adapter.encodeFullSnapshot(&snapshot, .{});
    try std.testing.expectEqual(click | set_value | steps, encodedNode(writable, locked).?.actions);
    try std.testing.expectEqual(
        click | caret | set_value | replace,
        encodedNode(writable, field).?.actions,
    );
}

test {
    _ = @import("w21_accessibility_test.zig");
}
