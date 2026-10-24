//! E05: the mobile accessibility adapter.
//!
//! The semantic tree, the action queue, the character/byte offset conversion
//! and the diffing are the SHARED adapter's, in `../accessibility.zig`, and
//! this module reuses them rather than reimplementing them: a phone is not a
//! second runtime, it is a second consumer of the same snapshot. What lives
//! here is the part that is genuinely mobile:
//!
//!   * THE BRIDGE IS OURS. AccessKit's Unix adapter builds itself around a
//!     D-Bus connection and macOS borrows a view from a bridge the shared
//!     adapter owns. Neither describes a phone: UIKit and Android both want a
//!     bridge constructed with the host's callbacks, attached to the
//!     application's own window afterwards, and freed before the window goes
//!     away. So this module calls `Adapter.initWithoutBridge` on the shared
//!     adapter — its serializer, its bounded request ring, its dispatch — and
//!     owns the platform bridge itself.
//!
//!   * TWO IDENTITIES, AND THE DIFFERENCE IS THE POINT. The core's `NodeId` is
//!     a hash of a live owner, and it is stable across a reorder. A platform
//!     cannot be given that: UIKit and Android both hand a bridge an opaque
//!     integer and hand it back on every later call, so the integer has to be
//!     a NAME. This adapter issues a `native_id` per semantic identity, keeps
//!     it for the life of the bridge, and never reuses it for a different
//!     identity. An id a screen reader kept from an earlier tree therefore
//!     resolves to the node it was issued for, or to nothing once that node is
//!     gone — never to whatever moved into its place.
//!
//!   * DENSE INTERNAL REFERENCES. `parent`, `children` and `member_of` are
//!     dense indices into the same update and stay that way: they are internal
//!     to the shim, the platform never sees them, and a reorder among them
//!     costs nothing because the identities the platform holds are elsewhere.
//!     `root` and `focus` ARE native ids, because those two are what a
//!     re-attached platform looks up by name.
//!
//!   * COORDINATES. The core publishes logical bounds and this is the native
//!     edge, so the scale is applied here and nowhere else. UIKit's own unit
//!     is the point, which is the core's unit, so iOS publishes at 1. Android's
//!     node bounds are physical SDL-window pixels, so the host sets the
//!     measured window scale through `setPixelScale` — the same factor the
//!     E04 lifecycle uses, and never a display-density figure.
//!
//!   * WHAT THE PLATFORM CAN ACTUALLY DO. A synthetic UIKit element cannot be
//!     edited: UIKit gives a screen reader no way to type into one. A text node
//!     the app did not bind a real `UITextField`/`UITextView` to therefore
//!     must not publish the two text actions, or the platform is offered
//!     something it cannot keep. Android's framework applies `ACTION_SET_TEXT`
//!     to a virtual node, so there both actions stay.
//!
//!   * WHAT THE MODEL WILL REFUSE. A screen reader cannot tell an action that
//!     was offered from one that worked, so a request the model refuses is
//!     never offered in the first place. That is two facts the wire states and
//!     this adapter applies. A read-only node keeps its value, its range and
//!     its caret — it is announced, not driven — so nothing that would change
//!     what it shows is published, a bound control included. And a named
//!     action is published exactly where the shared encoder published it,
//!     which is nowhere on a node the core refuses to act on. Both live here
//!     rather than in `dispatch`, because the platform has already left by the
//!     time a refusal comes back.
//!
//! All of that is built through the ordinary semantic seam. There is no second
//! action path here: a screen-reader click, a text edit, a focus change and a
//! named action all leave through `semantics.Dispatcher`, so one request
//! changes the model exactly once, on the thread that owns it.
//!
//! THREADS. The platform calls `deliver` and `wake` from its own
//! accessibility thread. Both only copy into fixed storage under this
//! adapter's mutex and then return: no model is touched, nothing is freed and
//! no lock is held while the host is called. Everything else — `stage`,
//! `commit`, `publish`, `drain` and every reader below — belongs to the
//! thread that owns the application, which is the thread that owns the window.
//!
//! ALLOCATION. The wire arrays, the per-node offset table and the identity
//! maps are all retained across frames. A steady application publishes
//! without allocating at all: capacity only ever grows, and it grows to the
//! high-water mark of the tree that was actually published. The one thing
//! that is never reused is a native id, because a name that could be handed
//! out twice is the bug this file exists to prevent.
//!
//! FAILURE. A publication is two phases on purpose. `stage` converts and
//! allocates but touches no platform, and `commit` hands the result over and
//! only then adopts the routing. A bridge that refuses the update, a snapshot
//! that names a relation it does not publish, a tree the encoder truncated and
//! an id counter that has run out all leave the PREVIOUS publication exactly
//! as the platform was last told it is: no partial routing, no half-adopted
//! map, and a typed error rather than a truncated tree.
const std = @import("std");
const sdl3 = @import("sdl3");
const native = @import("native.zig");
const shared = @import("../accessibility.zig");

/// The core's own semantic vocabulary. This adapter adds no node type, no
/// action and no text model of its own.
pub const semantics = shared.semantics;
pub const NodeId = shared.NodeId;
pub const Snapshot = semantics.Snapshot;
pub const Dispatcher = semantics.Dispatcher;
pub const Scratch = semantics.Scratch;
pub const TextSelection = semantics.TextSelection;

/// The shared publication options, re-exported so a host needs one import.
pub const Publish = shared.Publish;
/// Adapter state, reported from what the platform said rather than assumed.
pub const State = shared.State;
/// What the platform actually offers, as observed at run time.
pub const Capability = shared.Capability;
/// The result of asking for the platform accessibility bell.
pub const Bell = shared.Bell;
/// The neutral request the shared ring carries.
pub const NativeRequest = shared.NativeRequest;
/// The neutral payload discriminator the shared ring carries.
pub const NativeData = shared.NativeData;
/// The shared tree-publication errors, so a host can tell a capacity failure
/// from a platform refusal.
pub const TreeError = shared.Error;

pub const max_nodes = shared.max_nodes;
pub const max_queue = shared.max_queue;
pub const max_payload_bytes = shared.max_payload_bytes;
/// The platform's CHARACTER index for a core UTF-8 byte offset.
pub const characterIndexOf = shared.characterIndexOf;
/// The core's UTF-8 byte offset for a platform CHARACTER index.
pub const byteOffsetOf = shared.byteOffsetOf;

/// The platform shim exists on this target.
pub const available = native.available;
/// Which platform this build is for. UIKit publishes points; Android publishes
/// physical window pixels.
pub const platform = native.platform;

/// A native id that names nothing. Native ids are positive, so zero is free to
/// mean absence without aliasing a real id.
pub const no_node: u64 = 0;
/// A dense index that does not exist. Dense index ZERO is a real index — the
/// root is usually at zero — so absence cannot be zero.
pub const no_index: u64 = native.no_index;
/// The largest native id that may ever be issued. Android narrows the
/// platform's own id to a signed 32-bit value, and a bridge that published a
/// larger one would be refused for a reason the application cannot see.
pub const max_native_id: u64 = native.max_native_id;

pub const Error = shared.Error || native.Error || error{
    /// More distinct identities were published than native ids can name. The
    /// platform's id space is finite and this is where it ends, so the
    /// publication is refused rather than an id wrapped onto a name that is
    /// already in use.
    NativeIdsExhausted,
    /// The snapshot named a parent, a child or a set owner that the snapshot
    /// does not itself publish, so no dense index for it exists. Refused: a
    /// guessed index would be a node the application never described.
    DanglingRelation,
    /// The shared encoder did not carry every node the snapshot published. A
    /// mobile update is always the whole tree, so a partial one is a defect in
    /// the encoder rather than a smaller publication.
    EncoderTruncatedTree,
    /// The tree handed to `commit` is not the one the last `stage` built.
    StaleStage,
    /// The named semantic node is not in the publication the platform holds.
    UnknownNode,
    /// The node publishes no editable text run, so there is nothing to bind a
    /// real platform input to. A read-only run is exactly that: it publishes
    /// no contents action at all, so a control bound to it would offer typing
    /// the model refuses.
    NotTextInput,
    /// A real platform input is already bound. UIKit's shim binds exactly one,
    /// and binding a second would leave the first silently detached.
    TextInputAlreadyBound,
    /// A set position or set size does not fit the platform's own 32-bit
    /// relation. Refused rather than truncated: a row published in a set of a
    /// different size is a row the screen reader would navigate wrongly.
    SetRelationOutOfRange,
    /// A text selection index does not fit the platform's own signed index.
    SelectionOutOfRange,
};

const c = native.c;

/// A stable address for the zero-length node array an empty publication
/// carries. An empty `ArrayListUnmanaged` has an undefined slice pointer, and
/// a C tree is handed a real pointer whether or not it has nodes, so this is
/// what an empty update points at. Nothing dereferences it: every shim reads
/// the length first.
// SAFETY: the shim reads `nodes_len` before the array, and this address is only
// ever published beside a length of zero, so not one byte of it is ever read.
const empty_nodes: native.wire_node = undefined;
/// A stable address for the wire's "no string" and "no named action" cases.
///
/// Both shims normalise a ZERO LENGTH to the C null in their own copy, so an
/// empty borrowed slice is published as a valid pointer with a length of zero
/// and reaches the platform as the absence the header describes. That is why
/// this file never hands the wire a C null: the length is the fact, and it is
/// the one the shims read.
const no_bytes: [0]u8 = .{};
const no_actions: [0]c.nogui_mobile_custom_action = .{};

/// One semantic identity the platform may address, and the name issued for it.
/// `semantic` is the core's stable identity; `native` is the name.
const Issued = struct { semantic: NodeId, native: u64 };

/// Where one node's child edges and named actions sit in the shared wire
/// buffers. Recorded while those buffers are still growing and read back once
/// they have stopped, because a pointer into a buffer that later grew is a
/// pointer to nothing.
const Spans = struct { children: u32, customs: u32 };

/// One staging pass, handed to `commit`.
///
/// The epoch is what makes the two phases safe to use separately: a tree
/// staged and then re-staged is refused rather than committed, so a caller
/// cannot hand the platform a tree that is not the one the adapter would
/// produce right now.
pub const Staged = struct {
    epoch: u64,
    nodes_len: usize,
    root: u64,
    focus: u64,
    has_tree_init: bool,
};

/// The routing tables a publication replaces, kept so a platform that refuses
/// the tree can have the previous ones put back.
///
/// A `Routing` MOVES table ownership; it never shares it. Once `adoptStaged
/// Routing` has swapped, `previous` is the only name its two allocations have
/// while `self.staged_live` and `self.editable_staged` hold none, and the
/// value returned on the accepting path is dropped without being freed for
/// exactly that reason: freeing it would free the buffers the adapter is now
/// using as its staging scratch. Every table therefore has exactly one owner
/// at every point in the cycle, which is what `deinit` counts on.
const Routing = struct {
    live: std.AutoHashMapUnmanaged(u64, NodeId),
    editable: std.AutoHashMapUnmanaged(NodeId, void),
};

/// The action mask a mobile node publishes.
///
/// Two independent facts narrow the core's own mask, and both narrow it the
/// same way: an action the platform cannot keep, and an action the model would
/// refuse.
///
///   * CAPABILITY. UIKit gives a screen reader no way to type into a synthetic
///     accessibility element, so a text node the application did not bind a
///     real `UITextField`/`UITextView` to must not publish the two text
///     actions: the offer would be one the platform cannot keep. A node that
///     IS bound, and every node on a platform whose framework edits a virtual
///     node for real (Android applies `ACTION_SET_TEXT` to a virtual node),
///     keeps them.
///   * POLICY. `read_only` means no contents mutation, and a numeric value is
///     contents exactly as characters are, so a read-only node publishes
///     nothing from `mutatingActions` — a bound control included, because a
///     real control bound to a read-only field would type into it and be
///     refused afterwards. A caret is not a mutation, so `set_text_selection`
///     stays, and so does `click`.
///
/// The bits are named by `semantics.Action` rather than by a hand-written set,
/// because that is the identity both shims gate on: each of them refuses a
/// request whose `1u << action` bit the node does not carry, so what this
/// function withholds is exactly what the platform can never be asked for.
pub fn mobileActionMask(
    actions: u32,
    bound: bool,
    platform_edits_virtual_text: bool,
    read_only: bool,
) u32 {
    var mask = actions;
    if (read_only) mask &= ~mutatingActions();
    if (!bound and !platform_edits_virtual_text) {
        const edits: u32 = (1 << @backingInt(semantics.Action.replace_selected_text)) |
            (1 << @backingInt(semantics.Action.set_text_selection));
        mask &= ~edits;
    }
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
pub fn mutatingActions() u32 {
    return (1 << @backingInt(semantics.Action.set_value)) |
        (1 << @backingInt(semantics.Action.increment)) |
        (1 << @backingInt(semantics.Action.decrement)) |
        (1 << @backingInt(semantics.Action.replace_selected_text));
}

/// The window adapter. One instance per toplevel window.
///
/// The platform bridge holds a raw pointer to this for its callbacks, so the
/// adapter must live at a stable address for as long as it is initialized.
/// `init` is therefore SELF-INITIALIZING: it binds the bridge to `self`, not
/// to a local of its own, and returns nothing to copy.
///
/// Allocate one, then initialize it in place:
///     const adapter = try gpa.create(Adapter);
///     try adapter.init(gpa, io);
pub const Adapter = struct {
    gpa: std.mem.Allocator,
    /// The Io this adapter's own mutex waits on. The platform thread blocks on
    /// it, so the host must keep the Io alive for the adapter's whole life.
    io: std.Io,

    /// The shared serializer, bounded request ring and dispatch. Built with
    /// `initWithoutBridge`: the mobile bridge is this module's, and asking the
    /// shared adapter for an AccessKit handle would be a claim this target
    /// cannot keep.
    shared: shared.Adapter,

    /// The platform bridge, or null on a build without one.
    bridge: ?*native.platform_bridge = null,
    /// The bridge is attached to a window. The window is borrowed from SDL and
    /// must outlive the attachment.
    attached: bool = false,
    state: State = .unavailable,
    /// The last native screen-reader observation, used to detect activation.
    reader_attached: bool = false,

    /// Physical pixels per logical pixel for everything published. One on
    /// UIKit, whose own unit is the point; the measured window scale on
    /// Android, whose node bounds are physical pixels.
    pixel_scale: f32 = 1,
    /// The window's own keyboard focus, as the host last reported it.
    window_focused: bool = false,
    staged_window_focused: bool = false,
    window_focus_initialized: bool = false,
    /// The platform can apply a text edit to a node the application did not
    /// bind a real input to. `init` fills it in from the target; it is a
    /// statement about the framework, not about this application.
    virtual_text_edits: bool = false,
    /// The native id of the real platform text input the application bound, or
    /// zero when none is bound. UIKit's shim binds exactly one.
    bound_native: u64 = no_node,

    // ── identity tables ────────────────────────
    /// The native thread's lock. It guards the routing table and the wake
    /// flag, and it is NEVER held while the host or the platform is called.
    mutex: std.Io.Mutex = .init,
    /// Semantic identity to native name, for every identity this bridge has
    /// ever been told about. Never shrinks and never loses an entry: that is
    /// what makes a name a name.
    issued: std.AutoHashMapUnmanaged(NodeId, u64) = .empty,
    /// The identities the CURRENT publication committed. A native request is
    /// routed through this and nothing else, so an id whose node is gone
    /// produces no request at all.
    live: std.AutoHashMapUnmanaged(u64, NodeId) = .empty,
    /// The next publication's routing, built by `stage`.
    staged_live: std.AutoHashMapUnmanaged(u64, NodeId) = .empty,
    /// Semantic identities that published an editable text run, for the live
    /// publication and for the staged one. Binding a real input is only
    /// meaningful for a node the platform is currently showing as editable,
    /// and a read-only node is announced rather than driven: it takes a caret
    /// and refuses every write, so a real control bound to it would type into
    /// a field whose contents the model then refuses to change.
    editable: std.AutoHashMapUnmanaged(NodeId, void) = .empty,
    editable_staged: std.AutoHashMapUnmanaged(NodeId, void) = .empty,
    /// Names issued during the current `stage`, adopted by `commit` only if
    /// the platform accepted the tree.
    fresh: std.ArrayListUnmanaged(Issued) = .empty,
    /// The largest name issued so far. Monotone.
    next_native: u64 = 1,
    /// Requests that named no live identity, or that carried an offset no run
    /// can have. Surfaced, never hidden: a screen reader that is refused
    /// deserves to be counted rather than assumed to be working.
    refused: u32 = 0,
    /// The platform asked the host to look at the tree again.
    dirty: bool = false,

    // ── wire staging ───────────────────────────
    /// The tree handed to the shim. Rebuilt at the end of every `stage`, so
    /// every pointer in it addresses a buffer that has stopped growing.
    tree: native.wire_tree,
    nodes: std.ArrayListUnmanaged(native.wire_node) = .empty,
    children: std.ArrayListUnmanaged(u64) = .empty,
    customs: std.ArrayListUnmanaged(c.nogui_mobile_custom_action) = .empty,
    spans: std.ArrayListUnmanaged(Spans) = .empty,
    /// Identifies the current staging. A tree from an older one is refused.
    epoch: u64 = 0,
    /// A tree has been committed, so the next one is an update rather than a
    /// declaration.
    published: bool = false,
    /// The platform dropped the tree — an attach, a detach, a screen reader
    /// that had gone and came back — so the next publication must re-declare
    /// the whole thing instead of patching one the platform no longer has.
    reset_pending: bool = true,

    /// The bridge calls this publication makes. Replace it before the first
    /// `commit`; a publication in flight has already taken the previous pair.
    bridge_ops: BridgeOps = .{},

    /// The two bridge calls a publication makes, and the seam that replaces
    /// them.
    ///
    /// Production reaches the shim through `native`. The pair is named rather
    /// than called inline because the REFUSING case is the one that has to be
    /// exercised and is the one no bridge-less build can produce: on Android
    /// `nogui_android_a11y_update` answers `NOGUI_MOBILE_ERR_UNAVAILABLE`
    /// whenever the bridge is not attached to an activity, which is the normal
    /// state between `detach` and the next `attach`. A host that owns a bridge
    /// of its own installs its own pair; so does a test that needs a platform
    /// to refuse where there is no platform at all.
    ///
    /// The two calls stay separate because they fail differently and are
    /// reported differently: a refused focus report happens BEFORE the routing
    /// is adopted, and a refused tree happens after, which is the only case
    /// that has to put the routing back.
    pub const BridgeOps = struct {
        context: ?*anyopaque = null,
        set_window_focused: *const fn (?*anyopaque, *native.platform_bridge, bool) Error!void =
            setWindowFocusedNative,
        update: *const fn (?*anyopaque, *native.platform_bridge, *const native.wire_tree) Error!void =
            updateNative,
    };

    /// Install the bridge calls. A host whose bridge is not the shim's supplies
    /// its own pair here, and a host that does not touch this one keeps
    /// `native`.
    pub fn setBridgeOps(self: *Adapter, ops: BridgeOps) void {
        self.bridge_ops = ops;
    }

    fn setWindowFocusedNative(_: ?*anyopaque, bridge: *native.platform_bridge, focused: bool) Error!void {
        try native.setWindowFocused(bridge, focused);
    }

    fn updateNative(_: ?*anyopaque, bridge: *native.platform_bridge, tree: *const native.wire_tree) Error!void {
        try native.update(bridge, tree);
    }

    pub fn init(self: *Adapter, gpa: std.mem.Allocator, io: std.Io) Error!void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            // SAFETY: `initWithoutBridge` writes every field of `shared` on the
            // line below, before any other statement reads it.
            .shared = undefined,
            // SAFETY: no `stage` has run yet. Every `stage` writes the whole
            // field before `commit` hands it over, and `stagedTree` is the tree
            // the LAST stage built, so nothing reads it before one has.
            .tree = undefined,
        };
        self.shared.initWithoutBridge(gpa, io);
        // A build without the platform is not a failure, it is a fact: every
        // conversion below still happens and can still be read back, which is
        // the same choice the shared adapter makes when the AccessKit archive
        // is absent.
        if (!available) return;
        self.bridge = try native.createBridge(
            @ptrCast(self),
            Callbacks.onAction,
            Callbacks.onDirty,
        );
        self.state = .inactive;
        // Android's framework edits a virtual node through ACTION_SET_TEXT.
        // UIKit gives a screen reader no way to type into a synthetic element.
        self.virtual_text_edits = platform == .android;
    }

    /// Tear down in the order the platform requires.
    ///
    /// The text input is unbound first, then the window is detached, then the
    /// bridge is freed. Freeing the bridge is a BARRIER: on return no platform
    /// callback is running and none can start, which is what makes it safe to
    /// destroy the memory behind `user` afterwards. It must not be called from
    /// inside a platform callback on this thread — a host that needs to tear
    /// down does it on its own turn of the event loop.
    pub fn deinit(self: *Adapter) void {
        if (self.bridge) |bridge| {
            if (self.bound_native != no_node) {
                if (comptime platform == .ios) native.unbindTextInput(bridge);
                self.bound_native = no_node;
            }
            native.detach(bridge);
            native.freeBridge(bridge);
        }
        self.bridge = null;
        self.shared.deinit();
        self.issued.deinit(self.gpa);
        self.live.deinit(self.gpa);
        self.staged_live.deinit(self.gpa);
        self.editable.deinit(self.gpa);
        self.editable_staged.deinit(self.gpa);
        self.fresh.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.children.deinit(self.gpa);
        self.customs.deinit(self.gpa);
        self.spans.deinit(self.gpa);
        self.* = undefined;
    }

    // ── lifecycle ──────────────────────────────

    /// Hand the platform bridge the application's own window.
    ///
    /// The window is borrowed from SDL, so the attachment disappears with the
    /// window: `detach` before destroying it. Attaching is a native reset, so
    /// the next publication re-declares the whole tree.
    pub fn attach(self: *Adapter, window: sdl3.video.Window) Error!void {
        const bridge = self.bridge orelse return error.Unsupported;
        try native.attach(bridge, window);
        self.attached = true;
        self.noteNativeReset();
    }

    /// Detach before the window goes away.
    ///
    /// The issued names are deliberately KEPT. A platform that has forgotten a
    /// tree has not forgotten that a name meant an identity, and the same
    /// publication after the re-attach has to reach the same names or a screen
    /// reader that kept one would be addressing a different control.
    pub fn detach(self: *Adapter) void {
        const bridge = self.bridge orelse return;
        self.unbindTextInput();
        native.detach(bridge);
        self.attached = false;
        self.noteNativeReset();
    }

    /// The platform dropped the tree; the next publication re-declares it.
    ///
    /// `attach` and `detach` call this, and a host that observes a screen
    /// reader going away calls it too, because neither platform reports it:
    /// without it the next update would patch a tree the platform no longer
    /// has, and the screen reader would see nothing at all.
    pub fn noteNativeReset(self: *Adapter) void {
        self.reset_pending = true;
        self.window_focus_initialized = false;
    }

    /// The current state, read from the platform where it reports it.
    pub fn stateOf(self: *Adapter) State {
        const bridge = self.bridge orelse return .unavailable;
        const active = native.isActive(bridge) catch {
            self.state = .unavailable;
            return self.state;
        };
        if (active and !self.reader_attached) {
            self.reset_pending = true;
        }
        self.reader_attached = active;
        self.state = if (active) .active else .inactive;
        return self.state;
    }

    /// What the platform actually offers. Never inferred from a build flag.
    ///
    /// The bus fields describe this target's accessibility bridge. The bell
    /// field is a separate fact and stays false here: a mobile host owns its
    /// window through the platform framework, not through the desktop
    /// `Application`, so there is no window here for a system bell to belong
    /// to. Reporting that as unsupported is the honest answer, not a gap left
    /// for someone else to discover.
    pub fn capability(self: *Adapter) Capability {
        const state = self.stateOf();
        return .{
            .adapter = state != .unavailable,
            .screen_reader = state == .active,
            .bell = false,
        };
    }

    /// Neither mobile platform defines a portable accessibility bell, so this
    /// reports the absence rather than pretending to ring something. It is an
    /// instance method so one call site compiles on every target.
    pub fn bell(self: *Adapter) Bell {
        _ = self;
        return .unsupported;
    }

    /// Tell the platform whether the window itself has keyboard focus.
    pub fn setWindowFocused(self: *Adapter, focused: bool) Error!void {
        const bridge = self.bridge orelse return error.Unsupported;
        try native.setWindowFocused(bridge, focused);
        self.window_focused = focused;
        self.window_focus_initialized = true;
    }

    /// The window's own keyboard focus, as last reported to the platform.
    pub fn isWindowFocused(self: *const Adapter) bool {
        return self.window_focused;
    }

    /// Whether the bridge is attached to a window.
    pub fn isAttached(self: *const Adapter) bool {
        return self.attached;
    }

    /// Ask the platform to re-read the tree, for a change it cannot see in an
    /// update — a scroll, a selection, a modal that came and went. The system
    /// is allowed to decline, which is a fact rather than a failure of this
    /// adapter, so the platform's own refusal is returned unchanged.
    pub fn layoutChanged(self: *Adapter) Error!void {
        const bridge = self.bridge orelse return error.Unsupported;
        try native.layoutChanged(bridge);
    }

    /// The physical-to-logical factor used for every published coordinate.
    ///
    /// One on UIKit, whose own unit is the point the core already publishes
    /// in. On Android it is the MEASURED window scale — the factor between the
    /// window's logical size and its pixel size, which is the same number the
    /// E04 lifecycle uses. A display density or DPI figure is a different
    /// number and would move every published bound off the control it belongs
    /// to.
    pub fn setPixelScale(self: *Adapter, factor: f32) void {
        if (!(factor > 0) or !std.math.isFinite(factor)) return;
        self.pixel_scale = factor;
    }

    /// The factor every published coordinate is currently scaled by.
    pub fn scale(self: *const Adapter) f32 {
        return self.pixel_scale;
    }

    // ── a real platform text input ─────────────

    /// Bind the application's own text control to a published text node.
    ///
    /// A synthetic accessibility element cannot be typed into, so a host that
    /// wants an editable field hands over the real `UITextField` or
    /// `UITextView` it already has. The shim then copies the core's
    /// authoritative text and selection into that control and reads the
    /// platform's committed edits back out as requests, standing aside while
    /// it does the first of those so a write is not reported as an edit.
    ///
    /// The CONSEQUENCE for the host: those edits reach the model through this
    /// bridge, so the consumer must NOT also forward them through SDL or a
    /// second delegate. One edit, one model.
    pub fn bindTextInput(self: *Adapter, input: *anyopaque, semantic: NodeId) Error!void {
        // Policy before plumbing, and it is answered on every build: a caller
        // asking to bind a node the model refuses to write learns that from
        // this call rather than from a keystroke the shim swallowed later.
        if (self.bound_native != no_node) return error.TextInputAlreadyBound;
        // The node has to be one the platform is showing RIGHT NOW: a name the
        // ledger kept for a node that has since left the tree is not a node a
        // control can be bound to.
        const issued = self.issued.get(semantic) orelse return error.UnknownNode;
        if (self.live.get(issued) != semantic) return error.UnknownNode;
        // A run the publication did not mark bindable publishes no contents
        // action, so there is nothing for a real control to drive.
        if (!self.editable.contains(semantic)) return error.NotTextInput;
        const bridge = self.bridge orelse return error.Unsupported;
        try native.bindTextInput(bridge, input, issued);
        self.bound_native = issued;
    }

    /// Stop treating the bound control as this node's editor.
    pub fn unbindTextInput(self: *Adapter) void {
        if (self.bound_native == no_node) return;
        if (self.bridge) |bridge| {
            if (comptime platform == .ios) native.unbindTextInput(bridge);
        }
        self.bound_native = no_node;
    }

    /// The native name of the bound control's node, or zero when none is bound.
    pub fn boundTextInput(self: *const Adapter) u64 {
        return self.bound_native;
    }

    // ── identity ───────────────────────────────

    /// The native name issued for a semantic identity, or null when this
    /// bridge has never been told about it.
    ///
    /// A name stays issued for as long as the bridge lives even after its node
    /// is gone, so this answers "what was this identity called", which is not
    /// the same question as `resolvePublished`.
    pub fn nativeIdOf(self: *const Adapter, semantic: NodeId) ?u64 {
        return self.issued.get(semantic);
    }

    /// The live identity a native name addresses, or null when the publication
    /// the platform holds does not contain it.
    ///
    /// This is exactly the routing a platform request gets, so an identity that
    /// was removed resolves to nothing rather than to whatever took its place.
    pub fn resolvePublished(self: *const Adapter, native_id: u64) ?NodeId {
        return self.live.get(native_id);
    }

    /// The tree the last `stage` built, borrowed. Valid until the next
    /// `stage`, `publish` or `deinit`.
    ///
    /// The near side of the bridge, and the only side a host can observe
    /// without a screen reader: it says what the shim was handed, never what
    /// the platform echoed back.
    pub fn stagedTree(self: *const Adapter) native.wire_tree {
        return self.tree;
    }

    /// The number of nodes in the live publication.
    pub fn publishedCount(self: *const Adapter) usize {
        return self.live.count();
    }

    // ── publication ────────────────────────────

    /// Convert a committed snapshot into the mobile wire form.
    ///
    /// No platform call happens and no identity is adopted, so a conversion
    /// that fails leaves the previous publication exactly as it was.
    pub fn stage(self: *Adapter, snapshot: *const Snapshot, options: Publish) Error!Staged {
        const gpa = self.gpa;
        // The scale is applied at the native edge and nowhere else. UIKit is
        // already in the core's unit, so its factor is one; Android's is the
        // measured window scale.
        self.shared.setScale(self.pixel_scale, self.pixel_scale);
        const wire = try self.shared.encodeFullSnapshot(snapshot, options);
        const count = wire.nodes_len;
        // A mobile update is always the whole tree: the shims replace their
        // own copy rather than patching it, so a partial array is a defect in
        // the encoder, not a smaller publication.
        if (count != snapshot.count()) return error.EncoderTruncatedTree;

        self.epoch += 1;
        self.staged_live.clearRetainingCapacity();
        self.editable_staged.clearRetainingCapacity();
        self.fresh.clearRetainingCapacity();
        self.children.clearRetainingCapacity();
        self.customs.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();

        // The root and the focused node are the two the platform resolves by
        // name, so both have to be identities this very update publishes.
        const root_at: u64 = if (count == 0) no_index else blk: {
            break :blk denseOf(snapshot, wire.root) orelse return error.DanglingRelation;
        };
        const focus_at: u64 = if (count == 0) no_index else blk: {
            break :blk denseOf(snapshot, wire.focus) orelse return error.DanglingRelation;
        };

        // Pass one: the buffers every pointer will address. They grow here, so
        // nothing that points into them is taken yet.
        //
        // The named actions are read from the SHARED ENCODER's span rather
        // than from the snapshot's descriptor list, because that encoder has
        // already decided which nodes publish a name at all: a hidden or
        // disabled node, and a node whose own action set dropped the bit,
        // publish none. Two predicates for one rule is one too many, and the
        // two adapters would then disagree about which nodes the platform may
        // be offered a name for.
        for (snapshot.nodes[0..count], wire.nodes[0..count]) |node, src| {
            try self.spans.append(gpa, .{
                .children = @intCast(self.children.items.len),
                .customs = @intCast(self.customs.items.len),
            });
            for (node.children) |child| {
                try self.children.append(gpa, denseOf(snapshot, child) orelse
                    return error.DanglingRelation);
            }
            for (src.custom_actions[0..src.custom_actions_len]) |action| {
                try self.customs.append(gpa, .{
                    .id = action.id,
                    .name = action.name,
                    .name_len = action.name_len,
                });
            }
            // A read-only run publishes no contents action, so a control bound
            // to it would offer typing the model refuses. It is not bindable.
            if (node.text != null and !node.states.read_only) {
                try self.editable_staged.put(gpa, node.id, {});
            }
        }

        // Pass two: the nodes themselves.
        try self.nodes.ensureTotalCapacity(gpa, count);
        var root: u64 = no_node;
        var focus: u64 = no_node;
        for (wire.nodes[0..count], snapshot.nodes[0..count], self.spans.items[0..count], 0..) |src, node, span, i| {
            const children_end = if (i + 1 < count)
                self.spans.items[i + 1].children
            else
                @as(u32, @intCast(self.children.items.len));
            const customs_end = if (i + 1 < count)
                self.spans.items[i + 1].customs
            else
                @as(u32, @intCast(self.customs.items.len));
            const named = self.customs.items[span.customs..customs_end];
            const edges = self.children.items[span.children..children_end];
            const issued = try self.issue(src.id);
            // The root is the one node with no parent, and the shim refuses a
            // tree with a second one. Every other node's parent has to be a
            // node this same update publishes.
            const parent: u64 = if (@as(u64, i) == root_at) no_index else blk: {
                break :blk denseOf(snapshot, node.parent) orelse
                    return error.DanglingRelation;
            };
            const member: u64 = if (node.relations.member_of) |target| blk: {
                break :blk denseOf(snapshot, target) orelse
                    return error.DanglingRelation;
            } else no_index;
            // The platform's own relation fields are 32 bits wide. A list large
            // enough to overflow them is refused rather than wrapped: a row
            // published in a set of a different size is a row a screen reader
            // would navigate to the wrong place.
            if (src.row_count_set_size > std.math.maxInt(u32) or
                src.row_index_position > std.math.maxInt(u32))
            {
                return error.SetRelationOutOfRange;
            }
            if (src.text_selection_anchor > std.math.maxInt(i64) or
                src.text_selection_focus > std.math.maxInt(i64))
            {
                return error.SelectionOutOfRange;
            }
            const run = node.text;
            if (@as(u64, i) == root_at) root = issued;
            if (@as(u64, i) == focus_at) focus = issued;
            try self.staged_live.put(gpa, issued, src.id);
            try self.nodes.append(gpa, .{
                .semantic_id = src.id,
                .native_id = issued,
                .parent = parent,
                .role = src.role,
                // The bit layout is the bridge's and the shared encoder already
                // produced it, so the wire value is forwarded rather than
                // recomputed: two tables for one bit layout is one too many.
                .states = src.flags,
                .actions = mobileActionMask(
                    src.actions,
                    issued == self.bound_native,
                    self.virtual_text_edits,
                    node.states.read_only,
                ),
                .bounds = .{
                    .x0 = src.bounds.x0,
                    .y0 = src.bounds.y0,
                    .x1 = src.bounds.x1,
                    .y1 = src.bounds.y1,
                },
                .label = src.label,
                .label_len = src.label_len,
                .value = src.value,
                .value_len = src.value_len,
                .hint = src.description,
                .hint_len = src.description_len,
                .placeholder = src.placeholder,
                .placeholder_len = src.placeholder_len,
                .text = if (run) |value| value.value.ptr else &no_bytes,
                .text_len = if (run) |value| value.value.len else 0,
                // Character offsets, which is what both platforms count, and
                // -1 for a run that published no character table and is
                // therefore not addressable there at all. A collapsed caret at
                // zero would be a selection the run does not have.
                .text_selection_anchor = if (src.has_text_selection)
                    @intCast(src.text_selection_anchor)
                else
                    -1,
                .text_selection_focus = if (src.has_text_selection)
                    @intCast(src.text_selection_focus)
                else
                    -1,
                .multiline = if (run) |value| @intFromBool(value.multiline) else 0,
                .checked = checkedOf(node.states.checked),
                .numeric_value = src.numeric_value,
                .has_numeric_value = @intFromBool(src.has_numeric_value),
                .min_numeric_value = src.min_numeric_value,
                .max_numeric_value = src.max_numeric_value,
                .has_numeric_range = @intFromBool(
                    src.has_min_numeric_value and src.has_max_numeric_value,
                ),
                .children = edges.ptr,
                .children_len = edges.len,
                .member_of = member,
                .set_position = @intCast(src.row_index_position),
                .set_size = @intCast(src.row_count_set_size),
                .has_set = @intFromBool(src.has_row_index_position),
                .custom_actions = if (named.len == 0) &no_actions else named.ptr,
                .custom_actions_len = named.len,
            });
        }

        // Every buffer above has stopped growing, so the tree can point into
        // them. The shim copies before it returns, and nothing here outlives
        // the next `stage`.
        self.tree = .{
            .root = root,
            .has_tree_init = @intFromBool(!self.published or self.reset_pending),
            .toolkit = wire.toolkit_name,
            .toolkit_len = wire.toolkit_name_len,
            .focus = focus,
            .nodes = if (count == 0) @ptrCast(&empty_nodes) else @ptrCast(self.nodes.items.ptr),
            .nodes_len = count,
        };
        self.staged_window_focused = options.focused;
        return .{
            .epoch = self.epoch,
            .nodes_len = count,
            .root = root,
            .focus = focus,
            .has_tree_init = self.tree.has_tree_init != 0,
        };
    }

    /// Hand a staged tree to the platform and adopt its identities.
    ///
    /// `bridge` is null when this build has no platform bridge. That is a real
    /// state and it still adopts: the conversion happened, and a host that has
    /// nowhere to send it must be able to read back what it would have
    /// published. The same choice the shared adapter makes without the
    /// AccessKit archive.
    ///
    /// A bridge that REFUSES the update is a different thing entirely. The
    /// platform's error is returned and the ROUTING is put back, so what the
    /// platform was last given stays live and the next publication starts from
    /// it rather than from a half-applied map. Only the names move, and a name
    /// nothing holds is exactly what a name is for. The tables this
    /// publication built are not thrown away either: they go back to being the
    /// staging scratch, so a refusal costs a publication and not an allocation
    /// the next frame has to make again, and so neither of them is left with
    /// two owners or none.
    pub fn commit(self: *Adapter, staged: Staged, bridge: ?*native.platform_bridge) Error!void {
        if (staged.epoch != self.epoch) return error.StaleStage;
        // The ledger is filled BEFORE the handover, so a failure to grow it
        // cannot leave it half filled and the platform holding a name this
        // adapter would then refuse to resolve. A name issued for a tree the
        // platform then refused is simply a name nothing holds, which is
        // harmless for exactly the reason a name is never recycled.
        for (self.fresh.items) |entry| {
            try self.issued.put(self.gpa, entry.semantic, entry.native);
        }
        self.fresh.clearRetainingCapacity();
        if (bridge) |target| {
            // Report a change before update emits its focus announcement.
            if (!self.window_focus_initialized or
                self.window_focused != self.staged_window_focused)
            {
                try self.bridge_ops.set_window_focused(
                    self.bridge_ops.context,
                    target,
                    self.staged_window_focused,
                );
                // This native fact changes even if the later tree is refused.
                self.window_focused = self.staged_window_focused;
                self.window_focus_initialized = true;
            }
        }
        // The routing is adopted BEFORE the handover, because the framework
        // may ask about the tree the moment the window is given it — the iOS
        // shim publishes outside its own lock for exactly this reason — and
        // every inbound request is resolved through the live table. Adopting
        // after the call drops whatever the platform asks during it, most
        // reliably on the first publication, when the live table is still
        // empty and every request reads as a refusal.
        const previous = self.adoptStagedRouting();
        if (bridge) |target| {
            self.bridge_ops.update(self.bridge_ops.context, target, &self.tree) catch |err| {
                self.restoreRouting(previous);
                return err;
            };
        }
        self.window_focused = self.staged_window_focused;
        self.window_focus_initialized = true;
        self.published = true;
        self.reset_pending = false;
        // A bound control whose node left the tree edits nothing any more, so
        // the binding is dropped rather than left pointing at a name the
        // platform can no longer resolve.
        if (self.bound_native != no_node and self.live.get(self.bound_native) == null) {
            self.unbindTextInput();
        }
    }

    /// Swap the staged routing in and hand back what it replaced.
    ///
    /// After the two swaps the returned value is the only name the previous
    /// buffers have: `live` and `editable` are the tables this publication
    /// built, and `staged_live` and `editable_staged` hold the tables it
    /// replaced. An ACCEPTING caller drops the returned value without freeing
    /// it, because those buffers are exactly what the next `stage` reuses.
    fn adoptStagedRouting(self: *Adapter) Routing {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const previous: Routing = .{ .live = self.live, .editable = self.editable };
        std.mem.swap(
            std.AutoHashMapUnmanaged(u64, NodeId),
            &self.live,
            &self.staged_live,
        );
        std.mem.swap(
            std.AutoHashMapUnmanaged(NodeId, void),
            &self.editable,
            &self.editable_staged,
        );
        return previous;
    }

    /// Put the routing a publication replaced back, so the live tables name
    /// what the platform was last given rather than a tree it refused.
    ///
    /// The two swaps leave `live` and `editable` owning the buffers the
    /// platform was last handed, and they leave `previous` owning the buffers
    /// this publication built — but `staged_live` and `editable_staged` are
    /// STILL pointing at the restored buffers, which is the trap this function
    /// exists to close: two map values over one allocation is a table the next
    /// `stage` clears under the live table's feet, and a table `deinit` frees
    /// twice.
    ///
    /// So the rejected tables are handed BACK to the staged fields, which is
    /// where they belong: `stage` clears them before it writes, so their
    /// capacity is still the capacity a steady application reuses, and exactly
    /// one value names each allocation afterwards. `previous` is taken by
    /// value and never freed, so moving its tables out cannot double-free and
    /// cannot drop the last name of a buffer.
    fn restoreRouting(self: *Adapter, previous: Routing) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var rejected = previous;
        std.mem.swap(std.AutoHashMapUnmanaged(u64, NodeId), &self.live, &rejected.live);
        std.mem.swap(std.AutoHashMapUnmanaged(NodeId, void), &self.editable, &rejected.editable);
        self.staged_live = rejected.live;
        self.editable_staged = rejected.editable;
    }

    /// Convert, hand over and adopt. The whole publication in one call.
    pub fn publish(self: *Adapter, snapshot: *const Snapshot, options: Publish) Error!usize {
        const staged = try self.stage(snapshot, options);
        const bridge = self.bridge orelse return error.Unsupported;
        try self.commit(staged, bridge);
        return staged.nodes_len;
    }

    // ── native requests ────────────────────────

    /// Translate one platform request and hand it to the shared ring.
    ///
    /// This is what the platform callback calls, and it is the whole policy: an
    /// id the current publication does not contain produces NO request rather
    /// than one aimed at whatever took its place, and a payload no run can
    /// address is refused rather than clamped to an offset the user did not
    /// ask for. Everything else is copied into the shared ring, which the
    /// host's own `drain` replays through `semantics.Dispatcher` — so the
    /// model is touched once, on the thread that owns it, and never here.
    ///
    /// Safe to call from the platform's accessibility thread: it holds
    /// `mutex` only to read the routing table, releases it before touching the
    /// shared ring, and frees and mutates nothing.
    pub fn deliver(self: *Adapter, request: native.platform_request) void {
        const data = std.enums.fromInt(NativeData, request.data) orelse NativeData.none;
        const target: NodeId = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk self.live.get(request.target) orelse {
                self.refused += 1;
                return;
            };
        };
        // Both shims leave a request's indices at -1 when it carries none, and
        // a negative character index is not a position in any run. Clamping it
        // to zero would move a caret the platform never asked to move.
        if (data == .text_selection and
            (request.anchor_index < 0 or request.focus_index < 0))
        {
            self.mutex.lockUncancelable(self.io);
            self.refused += 1;
            self.mutex.unlock(self.io);
            return;
        }
        const accepted = self.shared.enqueueRequest(.{
            .id = target,
            .action = request.action,
            .data = data,
            .number = request.numeric_value,
            // The shim has already converted whatever the platform speaks, so
            // this is real UTF-8 and it is NOT NUL-terminated: the length is
            // the length. The ring copies it before this returns.
            .value = if (@as(?[*c]const u8, request.value)) |bytes|
                bytes[0..request.value_len]
            else
                "",
            .custom_action = request.custom_action,
            .anchor_index = if (request.anchor_index > 0)
                @intCast(request.anchor_index)
            else
                0,
            .focus_index = if (request.focus_index > 0)
                @intCast(request.focus_index)
            else
                0,
        });
        if (accepted) {
            self.wake();
        } else {
            self.mutex.lockUncancelable(self.io);
            self.refused += 1;
            self.mutex.unlock(self.io);
        }
    }

    /// Replay every buffered request on the calling (main) thread.
    ///
    /// This is the shared adapter's drain, unchanged: each request resolves a
    /// stable live owner and travels the ordinary activation, edit and focus
    /// seam, and character offsets are converted into the core's bytes on the
    /// way in. A `replace_selected_text` therefore replaces the range the
    /// published selection held, once, through the one text seam — the range
    /// the platform could act on at all is the range the last publication gave
    /// it, so the model is edited where the user was looking and not twice.
    pub fn drain(
        self: *Adapter,
        snapshot: *const Snapshot,
        dispatcher: *const Dispatcher,
        scratch: Scratch,
    ) usize {
        return self.shared.drain(snapshot, dispatcher, scratch);
    }

    /// True when the platform delivered a request since the last drain.
    pub fn hasPending(self: *Adapter) bool {
        return self.shared.hasPending();
    }

    /// Requests the shared ring refused because it was full. Surfaced.
    pub fn droppedRequests(self: *Adapter) u32 {
        return self.shared.droppedRequests();
    }

    /// Requests this adapter refused: an id the publication no longer holds, or
    /// an offset no published run can address. Surfaced, because a screen
    /// reader that is being refused should be countable.
    pub fn refusedRequests(self: *Adapter) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.refused;
    }

    /// Whether the platform asked the host to look at the tree again.
    pub fn hasDirty(self: *Adapter) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.dirty;
    }

    /// Read and clear the wake flag. The window driver uses it to redraw.
    pub fn takeDirty(self: *Adapter) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const was = self.dirty;
        self.dirty = false;
        return was;
    }

    /// Record a wake from the platform thread. No lock is held when this
    /// returns, and nothing is called while one is held.
    fn wake(self: *Adapter) void {
        self.mutex.lockUncancelable(self.io);
        self.dirty = true;
        self.mutex.unlock(self.io);
    }

    /// The native name for a semantic identity, issuing one the first time.
    /// A name is never reused, and running out is a typed refusal rather than
    /// an id that wraps onto a name already in use.
    fn issue(self: *Adapter, semantic: NodeId) Error!u64 {
        // A snapshot publishes each identity once, so within one `stage` a
        // semantic id is new the first time it is asked for and the ledger is
        // the only place a name can already be. That is why there is no second
        // lookup here: a scan would cost a frame O(nodes^2) to answer a
        // question the snapshot has already answered.
        if (self.issued.get(semantic)) |existing| return existing;
        if (self.next_native == 0 or self.next_native > max_native_id) {
            return error.NativeIdsExhausted;
        }
        const name = self.next_native;
        self.next_native += 1;
        try self.fresh.append(self.gpa, .{ .semantic = semantic, .native = name });
        return name;
    }
};

/// The dense index a semantic identity occupies in the snapshot, or null when
/// the snapshot does not publish it. The index IS the reference the shims walk,
/// so an identity that is not published has no reference at all.
fn denseOf(snapshot: *const Snapshot, semantic: NodeId) ?u64 {
    const slot = snapshot.index.get(semantic) orelse return null;
    return slot;
}

/// The platform's checked value. The state bits are what both shims read; this
/// field carries the same fact for a platform that asks for it directly, and
/// -1 is the header's own "cannot be toggled".
fn checkedOf(state: semantics.Checked) i32 {
    return switch (state) {
        .not_toggleable => c.NOGUI_MOBILE_CHECKED_NOT_TOGGLEABLE,
        .off => 0,
        .on => 1,
        .mixed => 2,
    };
}

/// The callbacks handed to the platform bridge. They run on the platform's
/// accessibility thread and only copy; they never touch the application.
const Callbacks = struct {
    fn onAction(user: ?*anyopaque, request: [*c]const native.platform_request) callconv(.c) void {
        const adapter: *Adapter = @ptrCast(@alignCast(user orelse return));
        adapter.deliver(request.*);
    }

    fn onDirty(user: ?*anyopaque) callconv(.c) void {
        const adapter: *Adapter = @ptrCast(@alignCast(user orelse return));
        adapter.wake();
    }
};

test {
    _ = @import("w23_mobile_test.zig");
}
