//! Focused editable text: one committed focused element, weak model ownership.
//!
//! The `Manager` never owns a text buffer. Every byte of text, every selection
//! and every preedit range lives in the model behind a registered `Endpoint`;
//! reads and writes cross the protocol as UTF-16 ranges and are resolved by
//! the owning model through a `Session` borrow. A released model fails that
//! borrow, so a stale endpoint can never edit a retired buffer.
//!
//! Rules the core owns:
//!   * Platform text arrives as UTF-16 code units (macOS, Windows) or UTF-8
//!     bytes (SDL). `utf8ToUtf16`/`utf16ToUtf8` convert and validate both.
//!   * Physical keys never insert. Only `Event.text_input` and a composition
//!     commit insert, so one printable key press plus its commit inserts the
//!     character exactly once.
//!   * A preedit commit replaces the marked range, never appends after it.
//!   * Grapheme snapping belongs to the endpoint: it owns the text and the W11
//!     layout, so `Move` and `Erase` resolve there. The core validates the
//!     UTF-8/UTF-16 range invariants of everything crossing the protocol.
//!
//! The native IME and clipboard are ports, not dependencies: the host binds
//! them once and the core never learns which platform it runs on.
const std = @import("std");

const Session = @import("session.zig").Session;
const model_type = @import("model.zig");
const WidgetId = @import("id.zig").WidgetId;
const geometry = @import("geometry.zig");
const event = @import("event.zig");

/// A range in UTF-16 code units, the unit every native text API speaks.
pub const Utf16Range = struct {
    start: usize = 0,
    end: usize = 0,

    pub fn isEmpty(self: Utf16Range) bool {
        return self.start == self.end;
    }

    pub fn ordered(self: Utf16Range) Utf16Range {
        if (self.start <= self.end) return self;
        return .{ .start = self.end, .end = self.start };
    }
};

/// A selection keeps its direction: `reversed` means the anchor sits at `end`.
pub const Selection = struct {
    range: Utf16Range = .{},
    reversed: bool = false,

    /// The moving end of the selection, following its direction.
    pub fn cursor(self: Selection) usize {
        return if (self.reversed) self.range.start else self.range.end;
    }

    /// The fixed end a shift-extended selection moves away from.
    pub fn anchor(self: Selection) usize {
        return if (self.reversed) self.range.end else self.range.start;
    }
};

/// Motion the endpoint resolves against its own text and layout.
pub const Move = struct {
    pub const Unit = enum { grapheme, word, line, document };
    pub const Direction = enum { backward, forward };

    unit: Unit = .grapheme,
    direction: Direction = .forward,
    /// Shift keeps the existing anchor and moves only the cursor.
    extend: bool = false,
    /// Place the cursor at this UTF-16 offset instead of moving it. A
    /// cancelled composition uses it to put the caret back.
    offset: ?usize = null,
};

/// A deletion the endpoint resolves. `extend` selects instead of deleting.
pub const Erase = struct {
    unit: Move.Unit = .grapheme,
    backward: bool = true,
    extend: bool = false,
};

/// Per-consumer policy. A read-only field still takes focus, copies and shows
/// a caret, but refuses every replacement.
pub const Policy = struct {
    /// A single-line field folds newlines to spaces and never grows a line.
    multiline: bool = false,
    read_only: bool = false,
    /// Set by a consumer that wants printable keys routed to the IME before
    /// keybindings, as an editor does in insert mode. The key inserts nothing.
    ime_printable_keys: bool = false,
};

/// The erased model plus consumer payload borrowed for one synchronous call.
pub const Call = struct {
    session: *Session,
    /// Weak: a released, reserved or wrong-typed model fails the borrow.
    owner: model_type.ErasedWeakModel,
    /// Consumer view state, valid only for the duration of the call.
    user: *anyopaque,
    allocator: std.mem.Allocator,

    /// The part a typed handler needs; the model and session stay hidden.
    pub fn borrow(self: Call) Borrow {
        return .{ .user = self.user, .allocator = self.allocator };
    }
};

/// What a typed handler receives besides the resolved model: the endpoint
/// payload it was registered with, and the allocator for owned results.
pub const Borrow = struct {
    user: *anyopaque,
    allocator: std.mem.Allocator,
};

/// Window geometry for one caret: the line box a candidate window is placed
/// under, and the caret's x offset inside it.
pub const Caret = struct {
    area: geometry.WindowRect,
    cursor: f32 = 0,
};

/// Type-erased protocol implemented by the owning model through `Adapter`.
pub const Ops = struct {
    /// Owned UTF-8 bytes for a UTF-16 range, or null when the range is not
    /// available. The caller frees the result with `Call.allocator`. `served`
    /// receives the range actually read after the endpoint snapped it.
    text: *const fn (Call, Utf16Range, *Utf16Range) anyerror!?[]u8,
    selection: *const fn (Call) anyerror!Selection,
    marked: *const fn (Call) anyerror!?Utf16Range,
    move: *const fn (Call, Move) anyerror!Selection,
    erase: *const fn (Call, Erase) anyerror!void,
    /// Replace and commit. A null range means "the marked range, else the
    /// selection" — the single rule that stops a preedit commit from
    /// duplicating its own text.
    replace: *const fn (Call, ?Utf16Range, []const u8) anyerror!void,
    /// Replace and mark as preedit. The last argument is the selection inside
    /// the new marked text in UTF-16 CODE UNITS, not a document range. Its
    /// `start` and `end` are that selection's own offsets, so a reversed
    /// selection keeps its direction and the caret belongs at `end`. Null
    /// means "the caret sits at the end of the new preedit".
    replace_and_mark: *const fn (Call, ?Utf16Range, []const u8, ?Utf16Range) anyerror!void,
    /// Drop the preedit mark and keep its text.
    unmark: *const fn (Call) anyerror!void,
    /// Caret geometry for the end of a UTF-16 range, in window coordinates.
    caret: *const fn (Call, Utf16Range) anyerror!?Caret,
    /// UTF-16 caret offset nearest a window point, for pointer placement.
    index_at: *const fn (Call, geometry.WindowPoint) anyerror!?usize,
};

/// A registered focused text element: stable identity plus weak model.
pub const Endpoint = struct {
    id: WidgetId,
    owner: model_type.ErasedWeakModel,
    policy: Policy = .{},
    ops: Ops,
    user: *anyopaque,
};

/// Native text-input control the host applies on focus change. The
/// implementation reports what it achieved: a driver with no text-input
/// service answers `error.UnsupportedCapability` from `start`, and the
/// manager keeps editing through committed text either way.
pub const Native = struct {
    user: *anyopaque,
    /// Begin receiving committed text and preedit for the focused window.
    start: *const fn (*anyopaque) anyerror!void,
    /// Stop receiving text.
    stop: *const fn (*anyopaque) anyerror!void,
    /// Publish window-logical geometry. Refusal leaves the previous native area
    /// intact and propagates through `caretGeometry`.
    set_area: ?*const fn (*anyopaque, geometry.WindowRect, f32) anyerror!void = null,
    /// Dismiss an open composition without disabling the subsystem.
    clear_composition: ?*const fn (*anyopaque) void = null,
};

/// What the host last managed to do with native text input.
pub const NativeStatus = enum {
    /// No native binding, or the focused element needs no text input.
    stopped,
    /// Native text input is running.
    running,
    /// The platform reported no usable text-input service.
    unsupported,
    /// A native call failed; committed text still edits the field.
    failed,
};

/// One clipboard read. `unavailable`, `empty` and `failed` stay distinct: a
/// failure must not be retried as if the copy were merely missing.
pub const ClipboardRead = union(enum) {
    /// No clipboard service on this platform or window.
    unavailable,
    /// The service answered with no text payload.
    empty,
    /// Owned bytes from the call allocator; may be zero length.
    text: []u8,
    /// The service failed; the field is unchanged.
    failed,
};

/// The one clipboard service every text consumer shares. A write reports
/// failure instead of throwing it away: a cut that lost its copy must not
/// delete the selection.
pub const Clipboard = struct {
    user: *anyopaque,
    read: ?*const fn (std.mem.Allocator, *anyopaque) ClipboardRead = null,
    write: ?*const fn (*anyopaque, []const u8) ClipboardWrite = null,
};

pub const ClipboardWrite = enum { written, failed };

/// Result of one edit action.
pub const EditOutcome = union(enum) {
    /// No focused text endpoint.
    ignored,
    /// The endpoint is read-only; nothing changed.
    read_only,
    /// Copy or cut with an empty selection; the clipboard is untouched.
    no_selection,
    /// Bytes handed to the clipboard service.
    copied: usize,
    /// Bytes copied and removed from the field.
    cut: usize,
    /// Bytes inserted from the clipboard.
    pasted: usize,
    /// The clipboard service is absent.
    unavailable,
    /// The clipboard holds no text.
    empty,
    /// The clipboard or the model failed; the field is unchanged.
    failed,
};

/// Whether a focused text consumer owns an event's default action.
pub const Outcome = enum {
    /// Nothing to route; the default action runs.
    ignored,
    /// The endpoint handled the event; suppress the default action.
    handled,
    /// The endpoint consumed the event and refused to change; suppress the
    /// default action so no other consumer edits the same range.
    rejected,
};

/// A cancelable composition record. The bytes the first preedit replaced are
/// kept so a cancel restores them instead of leaving a hole; a commit or a
/// focus loss drops the record.
const Preedit = struct {
    active: bool = false,
    /// The bytes the first preedit replaced, so a cancel puts them back at
    /// the current marked range instead of leaving a hole.
    restore_text: []u8 = &.{},
    /// The selection the preedit replaced, restored on cancel.
    restore_selection: Selection = .{},

    /// A preedit over a huge range falls back to dropping its own text on
    /// cancel: a bounded record beats an unbounded allocation per keystroke.
    pub const max_bytes = 64 * 1024;
};

pub const Manager = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    focused: ?Endpoint = null,
    /// Bumped by `invalidateGeometry`. Candidate geometry read at an older
    /// value is stale and is read again from the endpoint.
    geometry: u64 = 0,
    cached: ?struct { caret: Caret, generation: u64 } = null,
    preedit: Preedit = .{},
    native: ?Native = null,
    native_status: NativeStatus = .stopped,
    clipboard: ?Clipboard = null,

    pub fn init(gpa: std.mem.Allocator, session: *Session) Manager {
        return .{ .gpa = gpa, .session = session };
    }

    /// Focus a text element. Re-registering the same identity refreshes the
    /// endpoint without restarting an open preedit or native input.
    pub fn register(self: *Manager, endpoint: Endpoint) void {
        if (self.focused) |current| {
            if (current.id.eql(endpoint.id) and sameOwner(current.owner, endpoint.owner)) {
                self.focused = endpoint;
                return;
            }
        }
        self.release();
        self.focused = endpoint;
        self.cached = null;
        self.startNative();
    }

    /// The endpoint whose identity currently owns the keyboard.
    pub fn focusedId(self: *const Manager) ?WidgetId {
        return if (self.focused) |endpoint| endpoint.id else null;
    }

    /// The policy of the focused endpoint, if any.
    pub fn focusedPolicy(self: *const Manager) ?Policy {
        return if (self.focused) |endpoint| endpoint.policy else null;
    }

    /// Drop focus, cancel an open preedit and stop native text input.
    pub fn clear(self: *Manager) void {
        if (self.focused == null) return;
        self.release();
        self.focused = null;
    }

    /// Reconcile a registration with the committed focus. An endpoint whose
    /// element is no longer focused loses its preedit and native input.
    pub fn reconcile(self: *Manager, focus: ?WidgetId) void {
        const current = self.focused orelse return;
        if (focus) |id| {
            if (id.eql(current.id)) return;
        }
        self.clear();
    }

    /// Cancel an open composition and restore what it replaced. Focus loss
    /// calls this through `clear`; a host that receives an IME cancel calls it
    /// directly. A preedit with no snapshot (an oversized range) drops only
    /// its own text.
    pub fn cancelComposition(self: *Manager) anyerror!void {
        const endpoint = self.focused orelse return;
        if (!self.preedit.active) return;
        const restore = self.preedit.restore_text;
        const selection = self.preedit.restore_selection;
        self.preedit.restore_text = &.{};
        defer self.gpa.free(restore);
        if (!endpoint.policy.read_only) {
            if (try self.readMarked(endpoint)) |marked| {
                try self.writeReplace(endpoint, marked, restore);
            }
            _ = try self.writeMove(endpoint, .{ .offset = selection.anchor() });
        }
        try self.writeUnmark(endpoint);
        self.preedit = .{};
        self.invalidateGeometry();
    }

    /// Record what the first preedit is about to replace: the bytes of the
    /// target range and the selection that will be gone.
    ///
    /// The selection is recorded before anything can return, because an empty
    /// range is the collapsed-caret case: there are no bytes to roll back, and
    /// the caret still has to come back to where the composition began. A
    /// cancel that restored the default selection instead would park the
    /// caret at the start of the document and send the next commit there.
    fn snapshotReplaced(self: *Manager, endpoint: Endpoint) anyerror!void {
        const selection = try self.readSelection(endpoint);
        self.preedit.restore_selection = selection;
        const range = (try self.readMarked(endpoint)) orelse selection.range;
        if (range.isEmpty()) return;
        var served: Utf16Range = range;
        const bytes = (try self.readText(endpoint, range, &served)) orelse return;
        defer self.gpa.free(bytes);
        if (bytes.len > Preedit.max_bytes) return;
        const kept = try self.gpa.dupe(u8, bytes);
        self.gpa.free(self.preedit.restore_text);
        self.preedit.restore_text = kept;
    }

    /// Invalidate cached candidate geometry after layout, scroll or a scale
    /// change; the next `caretGeometry` reads the endpoint again.
    pub fn invalidateGeometry(self: *Manager) void {
        self.geometry +%= 1;
        self.cached = null;
    }

    /// Candidate geometry for the composing caret while a preedit is open,
    /// else for the selection. Null when no endpoint is focused or the
    /// endpoint has not measured a caret yet.
    pub fn caretGeometry(self: *Manager) anyerror!?Caret {
        const endpoint = self.focused orelse return null;
        if (self.cached) |entry| {
            if (entry.generation == self.geometry) return entry.caret;
        }
        // A candidate window hangs off the CARET, not off the selection. The
        // caret is the selection's moving end — which for a reversed selection
        // is its start — and while a preedit is open it is where the composing
        // focus sits inside the marked text. Passing the whole range made the
        // window follow the fixed end instead.
        const selection = try self.readSelection(endpoint);
        const cursor = selection.cursor();
        const range: Utf16Range = .{ .start = cursor, .end = cursor };
        const caret = (try self.callCaret(endpoint, range)) orelse return null;
        try self.publishArea(caret);
        self.cached = .{ .caret = caret, .generation = self.geometry };
        return caret;
    }

    /// Route one event. `handled` means the focused endpoint owns the default
    /// action; `rejected` means it consumed the event and refused to change.
    pub fn handle(self: *Manager, ev: *const event.Event) anyerror!Outcome {
        const endpoint = self.focused orelse return .ignored;
        switch (ev.*) {
            .key_down => |key| return self.handleKey(endpoint, key),
            .text_input => |commit| return self.insertCommitted(endpoint, commit.text),
            .composition => |composition| return self.handleComposition(endpoint, composition),
            else => return .ignored,
        }
    }

    /// Copy the selection. A read-only field copies like any other.
    pub fn copy(self: *Manager) anyerror!EditOutcome {
        const endpoint = self.focused orelse return .ignored;
        const service = self.clipboard orelse return .unavailable;
        const write = service.write orelse return .unavailable;
        const range = (try self.readSelection(endpoint)).range;
        if (range.isEmpty()) return .no_selection;
        var served: Utf16Range = range;
        const bytes = (try self.readText(endpoint, range, &served)) orelse return .no_selection;
        defer self.gpa.free(bytes);
        if (bytes.len == 0) return .no_selection;
        if (write(service.user, bytes) == .failed) return .failed;
        return .{ .copied = bytes.len };
    }

    pub fn cut(self: *Manager) anyerror!EditOutcome {
        const endpoint = self.focused orelse return .ignored;
        if (endpoint.policy.read_only) return .read_only;
        const service = self.clipboard orelse return .unavailable;
        const write = service.write orelse return .unavailable;
        const range = (try self.readSelection(endpoint)).range;
        if (range.isEmpty()) return .no_selection;
        var served: Utf16Range = range;
        const bytes = (try self.readText(endpoint, range, &served)) orelse return .no_selection;
        defer self.gpa.free(bytes);
        if (bytes.len == 0) return .no_selection;
        if (write(service.user, bytes) == .failed) return .failed;
        try self.writeReplace(endpoint, null, "");
        return .{ .cut = bytes.len };
    }

    pub fn paste(self: *Manager) anyerror!EditOutcome {
        const endpoint = self.focused orelse return .ignored;
        if (endpoint.policy.read_only) return .read_only;
        const service = self.clipboard orelse return .unavailable;
        const read = service.read orelse return .unavailable;
        switch (read(self.gpa, service.user)) {
            .unavailable => return .unavailable,
            .empty => return .empty,
            .failed => return .failed,
            .text => |bytes| {
                defer self.gpa.free(bytes);
                if (bytes.len == 0) return .empty;
                if (!std.unicode.utf8ValidateSlice(bytes)) return .failed;
                const normalized = try self.normalize(bytes, endpoint.policy);
                defer self.gpa.free(normalized);
                if (normalized.len == 0) return .empty;
                try self.writeReplace(endpoint, null, normalized);
                return .{ .pasted = normalized.len };
            },
        }
    }

    fn handleKey(self: *Manager, endpoint: Endpoint, key: event.KeyEvent) anyerror!Outcome {
        switch (key.key) {
            .left, .right, .up, .down => {
                const vertical = key.key == .up or key.key == .down;
                const backward = key.key == .left or key.key == .up;
                _ = try self.writeMove(endpoint, .{
                    .unit = if (vertical) .line else .grapheme,
                    .direction = if (backward) .backward else .forward,
                    .extend = key.shifted(),
                });
                return .handled;
            },
            .home, .end => {
                _ = try self.writeMove(endpoint, .{
                    .unit = .line,
                    .direction = if (key.key == .home) .backward else .forward,
                    .extend = key.shifted(),
                });
                return .handled;
            },
            .enter => {
                // A single-line field consumes Enter without editing; the
                // application decides whether it submits.
                if (!endpoint.policy.multiline) return .handled;
                if (endpoint.policy.read_only) return .rejected;
                try self.writeReplace(endpoint, null, "\n");
                return .handled;
            },
            .unidentified => {
                if (isErase(key, .backward)) return self.erase(endpoint, key, .backward);
                if (isErase(key, .forward)) return self.erase(endpoint, key, .forward);

                if (endpoint.policy.ime_printable_keys and isPrintableKey(key)) {
                    // The IME consumes the stroke; its commit inserts it once.
                    return .handled;
                }
                return .ignored;
            },
            // Tab, space and escape keep their App-level defaults: a printable
            // space arrives as committed text, never as a key insert.
            .tab, .space, .escape => return .ignored,
        }
    }

    fn erase(
        self: *Manager,
        endpoint: Endpoint,
        key: event.KeyEvent,
        direction: Move.Direction,
    ) anyerror!Outcome {
        if (endpoint.policy.read_only) return .rejected;
        try self.writeErase(endpoint, .{
            .backward = direction == .backward,
            .extend = key.shifted(),
        });
        return .handled;
    }

    /// A platform commit is the only printable insertion path.
    fn insertCommitted(
        self: *Manager,
        endpoint: Endpoint,
        raw: []const u8,
    ) anyerror!Outcome {
        if (endpoint.policy.read_only) return .rejected;
        if (raw.len == 0) return .rejected;
        if (!std.unicode.utf8ValidateSlice(raw)) return .rejected;
        const normalized = try self.normalize(raw, endpoint.policy);
        defer self.gpa.free(normalized);
        if (normalized.len == 0) return .rejected;
        try self.writeReplace(endpoint, null, normalized);
        return .handled;
    }

    fn handleComposition(
        self: *Manager,
        endpoint: Endpoint,
        composition: event.CompositionEvent,
    ) anyerror!Outcome {
        switch (composition.phase) {
            .start, .update => {
                if (endpoint.policy.read_only) return .rejected;
                if (!std.unicode.utf8ValidateSlice(composition.text)) return .rejected;
                if (composition.selection_start > composition.text.len or
                    composition.selection_end > composition.text.len or
                    !isUtf8Boundary(composition.text, composition.selection_start) or
                    !isUtf8Boundary(composition.text, composition.selection_end))
                {
                    return .rejected;
                }
                // The event counts BYTES into the preedit; the protocol speaks
                // UTF-16 code units. Converting here is what keeps a partial
                // multibyte selection from landing past the end of the preedit,
                // and a supplementary character is two units, not four bytes.
                const from = utf8ToUtf16(composition.text, composition.selection_start) catch
                    return .rejected;
                const to = utf8ToUtf16(composition.text, composition.selection_end) catch
                    return .rejected;
                const inside: ?Utf16Range = if (from == to) null else .{ .start = from, .end = to };
                if (!self.preedit.active) try self.snapshotReplaced(endpoint);
                try self.writeReplaceAndMark(endpoint, null, composition.text, inside);
                self.preedit.active = true;
                self.invalidateGeometry();
                return .handled;
            },
            .end => {
                // The marked range survives until the commit replaces it.
                self.invalidateGeometry();
                return .handled;
            },
        }
    }

    fn dropPreedit(self: *Manager) void {
        self.gpa.free(self.preedit.restore_text);
        self.preedit = .{};
    }

    /// Focus loss, endpoint replacement and window teardown share one path:
    /// cancel the preedit, drop the cache and stop native text input. A
    /// cancelled preedit never leaves partial text behind, and a failing
    /// endpoint cannot keep the host in text-input mode.
    fn release(self: *Manager) void {
        self.cancelComposition() catch self.dropPreedit();
        self.dropPreedit();
        self.cached = null;
        self.stopNative();
    }

    fn startNative(self: *Manager) void {
        const native = self.native orelse return;
        if (self.native_status == .running) return;
        native.start(native.user) catch |err| {
            self.native_status = switch (err) {
                error.UnsupportedCapability => .unsupported,
                else => .failed,
            };
            return;
        };
        self.native_status = .running;
    }

    fn stopNative(self: *Manager) void {
        const native = self.native orelse return;
        if (self.native_status == .stopped) return;
        if (self.native_status == .running) {
            if (native.clear_composition) |dismiss| dismiss(native.user);
        }
        native.stop(native.user) catch {
            self.native_status = .failed;
            return;
        };
        self.native_status = .stopped;
    }

    fn publishArea(self: *Manager, caret: Caret) anyerror!void {
        const native = self.native orelse return;
        if (self.native_status != .running) return;
        const set_area = native.set_area orelse return;
        try set_area(native.user, caret.area, caret.cursor);
    }

    /// Fold what a single-line field may not hold and drop what no field can
    /// store. Codepoints are copied whole, so a dropped one takes its
    /// continuation bytes with it.
    fn normalize(self: *Manager, raw: []const u8, policy: Policy) ![]u8 {
        const length = try scan(raw, policy, null);
        const out = try self.gpa.alloc(u8, length);
        errdefer self.gpa.free(out);
        _ = try scan(raw, policy, out);
        return out;
    }

    // --- endpoint borrows; a lost model drops the registration ---

    fn call(self: *Manager, endpoint: Endpoint) Call {
        return .{
            .session = self.session,
            .owner = endpoint.owner,
            .user = endpoint.user,
            .allocator = self.gpa,
        };
    }

    fn lost(self: *Manager) void {
        self.focused = null;
        self.dropPreedit();
        self.cached = null;
        self.stopNative();
    }

    fn readSelection(self: *Manager, endpoint: Endpoint) anyerror!Selection {
        return endpoint.ops.selection(self.call(endpoint)) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
    }

    fn readMarked(self: *Manager, endpoint: Endpoint) anyerror!?Utf16Range {
        return endpoint.ops.marked(self.call(endpoint)) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
    }

    fn readText(
        self: *Manager,
        endpoint: Endpoint,
        range: Utf16Range,
        served: *Utf16Range,
    ) anyerror!?[]u8 {
        return endpoint.ops.text(self.call(endpoint), range, served) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
    }

    fn callCaret(self: *Manager, endpoint: Endpoint, range: Utf16Range) anyerror!?Caret {
        return endpoint.ops.caret(self.call(endpoint), range) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
    }

    fn writeMove(self: *Manager, endpoint: Endpoint, request: Move) anyerror!Selection {
        const selection = endpoint.ops.move(self.call(endpoint), request) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
        // A moved caret is a different candidate rectangle. Without this the
        // cache answers with the rectangle of the caret that just moved, and
        // the platform keeps showing a candidate window in the old place.
        self.invalidateGeometry();
        return selection;
    }

    fn writeErase(self: *Manager, endpoint: Endpoint, request: Erase) anyerror!void {
        endpoint.ops.erase(self.call(endpoint), request) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
        self.invalidateGeometry();
    }

    fn writeReplace(
        self: *Manager,
        endpoint: Endpoint,
        range: ?Utf16Range,
        text: []const u8,
    ) anyerror!void {
        endpoint.ops.replace(self.call(endpoint), range, text) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
        self.dropPreedit();
        self.invalidateGeometry();
    }

    fn writeReplaceAndMark(
        self: *Manager,
        endpoint: Endpoint,
        range: ?Utf16Range,
        text: []const u8,
        inside: ?Utf16Range,
    ) anyerror!void {
        endpoint.ops.replace_and_mark(self.call(endpoint), range, text, inside) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
        self.invalidateGeometry();
    }

    fn writeUnmark(self: *Manager, endpoint: Endpoint) anyerror!void {
        endpoint.ops.unmark(self.call(endpoint)) catch |err| {
            if (isLostModel(err)) {
                self.lost();
                return error.EndpointReleased;
            }
            return err;
        };
        self.invalidateGeometry();
    }
};

/// The endpoint's model is gone: released, reserved, or from another store.
/// The registration was dropped and the caller sees this instead of a stale
/// buffer being edited.
pub const Error = error{EndpointReleased};

/// Decode the codepoint that starts at `bytes[0]`, whose lead byte already
/// yielded `size`. The variable-length `std.unicode.utf8Decode` is deprecated
/// because a wrong `size` is silent corruption, so dispatch on it explicitly.
fn decodeCodepoint(bytes: []const u8, size: u3) !u21 {
    return switch (size) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    };
}

/// One pass over committed or pasted text. With `out` null it measures the
/// result; with `out` present it writes exactly that many bytes.
fn scan(raw: []const u8, policy: Policy, out: ?[]u8) !usize {
    var count: usize = 0;
    var index: usize = 0;
    var after_cr: bool = false;
    while (index < raw.len) {
        const size = std.unicode.utf8ByteSequenceLength(raw[index]) catch
            return error.InvalidUtf8;
        const value = decodeCodepoint(raw[index..], size) catch
            return error.InvalidUtf8;
        var buffer: [4]u8 = undefined;
        var written: usize = 0;
        if (value == '\r' or value == '\n' or value == 0x0b or value == 0x0c) {
            // Only CRLF is one line break rather than two.
            if (after_cr and value == '\n') {
                after_cr = false;
                index += size;
                continue;
            }
            after_cr = value == '\r';
            buffer[0] = if (policy.multiline) '\n' else ' ';
            written = 1;
        } else if (value < 0x20 or value == 0x7f) {
            after_cr = false;
            if (value == '\t') {
                buffer[0] = '\t';
                written = 1;
            }
        } else {
            after_cr = false;
            written = std.unicode.utf8Encode(value, &buffer) catch
                return error.InvalidUtf8;
        }
        if (out) |target| @memcpy(target[count..][0..written], buffer[0..written]);
        count += written;
        index += size;
    }
    return count;
}

/// Build `Ops` from typed handlers over one `Session` model. Every handler
/// receives the resolved model for the duration of the call only; a handler
/// must not retain the pointer or a borrowed slice. `*anyopaque` in a handler
/// signature is the endpoint payload, not the model.
pub fn Adapter(comptime Model: type) type {
    return struct {
        pub const Handlers = struct {
            text: *const fn (std.mem.Allocator, *const Model, *anyopaque, Utf16Range, *Utf16Range) anyerror!?[]u8,
            selection: *const fn (*const Model, *anyopaque) anyerror!Selection,
            marked: *const fn (*const Model, *anyopaque) anyerror!?Utf16Range,
            move: *const fn (*Model, *anyopaque, Move) anyerror!Selection,
            erase: *const fn (*Model, *anyopaque, Erase) anyerror!void,
            replace: *const fn (*Model, *anyopaque, ?Utf16Range, []const u8) anyerror!void,
            replace_and_mark: *const fn (*Model, *anyopaque, ?Utf16Range, []const u8, ?Utf16Range) anyerror!void,
            unmark: *const fn (*Model, *anyopaque) anyerror!void,
            caret: *const fn (*Model, *anyopaque, Utf16Range) anyerror!?Caret,
            index_at: *const fn (*Model, *anyopaque, geometry.WindowPoint) anyerror!?usize,
        };

        /// `handlers` is comptime so each op can close over it: the returned
        /// vtable is a comptime value, exactly like a component vtable. A
        /// consumer that builds handler tables at runtime constructs `Ops`
        /// directly instead.
        pub fn ops(comptime handlers: Handlers) Ops {
            return .{
                .text = struct {
                    fn call(req: Call, range: Utf16Range, served: *Utf16Range) anyerror!?[]u8 {
                        const Box = struct {
                            borrow: Borrow,
                            handlers: Handlers,
                            range: Utf16Range,
                            served: *Utf16Range,
                            out: ?[]u8 = null,
                        };
                        var exchange: Box = .{
                            .borrow = req.borrow(),
                            .handlers = handlers,
                            .range = range,
                            .served = served,
                        };
                        try borrowRead(Model, Box, struct {
                            fn run(value: *const Model, box: *Box) anyerror!void {
                                box.served.* = box.range;
                                box.out = try box.handlers.text(
                                    box.borrow.allocator,
                                    value,
                                    box.borrow.user,
                                    box.range,
                                    box.served,
                                );
                            }
                        }.run, req, &exchange);
                        return exchange.out;
                    }
                }.call,
                .selection = struct {
                    fn call(req: Call) anyerror!Selection {
                        const Box = struct { borrow: Borrow, handlers: Handlers, out: Selection = .{} };
                        var exchange: Box = .{ .borrow = req.borrow(), .handlers = handlers };
                        try borrowRead(Model, Box, struct {
                            fn run(value: *const Model, box: *Box) anyerror!void {
                                box.out = try box.handlers.selection(value, box.borrow.user);
                            }
                        }.run, req, &exchange);
                        return exchange.out;
                    }
                }.call,
                .marked = struct {
                    fn call(req: Call) anyerror!?Utf16Range {
                        const Box = struct { borrow: Borrow, handlers: Handlers, out: ?Utf16Range = null };
                        var exchange: Box = .{ .borrow = req.borrow(), .handlers = handlers };
                        try borrowRead(Model, Box, struct {
                            fn run(value: *const Model, box: *Box) anyerror!void {
                                box.out = try box.handlers.marked(value, box.borrow.user);
                            }
                        }.run, req, &exchange);
                        return exchange.out;
                    }
                }.call,
                .move = struct {
                    fn call(req: Call, move: Move) anyerror!Selection {
                        const Box = struct { borrow: Borrow, handlers: Handlers, move: Move, out: Selection = .{} };
                        var exchange: Box = .{ .borrow = req.borrow(), .handlers = handlers, .move = move };
                        try borrowUpdate(Model, Box, struct {
                            fn run(value: *Model, box: *Box) anyerror!void {
                                box.out = try box.handlers.move(value, box.borrow.user, box.move);
                            }
                        }.run, req, &exchange);
                        return exchange.out;
                    }
                }.call,
                .erase = struct {
                    fn call(req: Call, erase: Erase) anyerror!void {
                        const Box = struct { borrow: Borrow, handlers: Handlers, erase: Erase };
                        var exchange: Box = .{ .borrow = req.borrow(), .handlers = handlers, .erase = erase };
                        try borrowUpdate(Model, Box, struct {
                            fn run(value: *Model, box: *Box) anyerror!void {
                                try box.handlers.erase(value, box.borrow.user, box.erase);
                            }
                        }.run, req, &exchange);
                    }
                }.call,
                .replace = struct {
                    fn call(req: Call, range: ?Utf16Range, text: []const u8) anyerror!void {
                        const Box = struct {
                            borrow: Borrow,
                            handlers: Handlers,
                            range: ?Utf16Range,
                            text: []const u8,
                        };
                        var exchange: Box = .{
                            .borrow = req.borrow(),
                            .handlers = handlers,
                            .range = range,
                            .text = text,
                        };
                        try borrowUpdate(Model, Box, struct {
                            fn run(value: *Model, box: *Box) anyerror!void {
                                try box.handlers.replace(value, box.borrow.user, box.range, box.text);
                            }
                        }.run, req, &exchange);
                    }
                }.call,
                .replace_and_mark = struct {
                    fn call(
                        req: Call,
                        range: ?Utf16Range,
                        text: []const u8,
                        inside: ?Utf16Range,
                    ) anyerror!void {
                        const Box = struct {
                            borrow: Borrow,
                            handlers: Handlers,
                            range: ?Utf16Range,
                            text: []const u8,
                            inside: ?Utf16Range,
                        };
                        var exchange: Box = .{
                            .borrow = req.borrow(),
                            .handlers = handlers,
                            .range = range,
                            .text = text,
                            .inside = inside,
                        };
                        try borrowUpdate(Model, Box, struct {
                            fn run(value: *Model, box: *Box) anyerror!void {
                                try box.handlers.replace_and_mark(
                                    value,
                                    box.borrow.user,
                                    box.range,
                                    box.text,
                                    box.inside,
                                );
                            }
                        }.run, req, &exchange);
                    }
                }.call,
                .unmark = struct {
                    fn call(req: Call) anyerror!void {
                        const Box = struct { borrow: Borrow, handlers: Handlers };
                        var exchange: Box = .{ .borrow = req.borrow(), .handlers = handlers };
                        try borrowUpdate(Model, Box, struct {
                            fn run(value: *Model, box: *Box) anyerror!void {
                                try box.handlers.unmark(value, box.borrow.user);
                            }
                        }.run, req, &exchange);
                    }
                }.call,
                .caret = struct {
                    fn call(req: Call, range: Utf16Range) anyerror!?Caret {
                        const Box = struct {
                            borrow: Borrow,
                            handlers: Handlers,
                            range: Utf16Range,
                            out: ?Caret = null,
                        };
                        var exchange: Box = .{ .borrow = req.borrow(), .handlers = handlers, .range = range };
                        try borrowUpdate(Model, Box, struct {
                            fn run(value: *Model, box: *Box) anyerror!void {
                                box.out = try box.handlers.caret(value, box.borrow.user, box.range);
                            }
                        }.run, req, &exchange);
                        return exchange.out;
                    }
                }.call,
                .index_at = struct {
                    fn call(req: Call, point: geometry.WindowPoint) anyerror!?usize {
                        const Box = struct {
                            borrow: Borrow,
                            handlers: Handlers,
                            point: geometry.WindowPoint,
                            out: ?usize = null,
                        };
                        var exchange: Box = .{ .borrow = req.borrow(), .handlers = handlers, .point = point };
                        try borrowUpdate(Model, Box, struct {
                            fn run(value: *Model, box: *Box) anyerror!void {
                                box.out = try box.handlers.index_at(value, box.borrow.user, box.point);
                            }
                        }.run, req, &exchange);
                        return exchange.out;
                    }
                }.call,
            };
        }
    };
}

/// Run a read handler against the endpoint's model. `Box` carries the request
/// and the result across the borrow; the model pointer never escapes it.
fn borrowRead(
    comptime Model: type,
    comptime Box: type,
    comptime handler: *const fn (*const Model, *Box) anyerror!void,
    req: Call,
    box: *Box,
) anyerror!void {
    try req.session.read(
        Model,
        model_type.WeakModel(Model){ .key = req.owner.key },
        box,
        struct {
            fn call(value: *const Model, user: *Box) anyerror!void {
                return handler(value, user);
            }
        }.call,
    );
}

/// Run an update handler against the endpoint's model.
fn borrowUpdate(
    comptime Model: type,
    comptime Box: type,
    comptime handler: *const fn (*Model, *Box) anyerror!void,
    req: Call,
    box: *Box,
) anyerror!void {
    try req.session.update(
        Model,
        model_type.WeakModel(Model){ .key = req.owner.key },
        box,
        struct {
            fn call(value: *Model, user: *Box) anyerror!void {
                return handler(value, user);
            }
        }.call,
    );
}

fn sameOwner(a: model_type.ErasedWeakModel, b: model_type.ErasedWeakModel) bool {
    return a.type_marker == b.type_marker and
        a.key.store == b.key.store and
        a.key.slot == b.key.slot and
        a.key.generation == b.key.generation;
}

/// A released, reserved, foreign-store or wrong-typed model is gone, not
/// broken; the registration is dropped instead of forwarding the error.
fn isLostModel(err: anyerror) bool {
    return switch (err) {
        error.StaleModel, error.UninitializedModel, error.WrongType, error.WrongStore => true,
        else => false,
    };
}

fn codepoint(key: event.KeyEvent) ?u21 {
    return switch (key.logical) {
        .codepoint => |value| value,
        .character => |text| blk: {
            if (!std.unicode.utf8ValidateSlice(text)) break :blk null;
            const size = std.unicode.utf8ByteSequenceLength(text[0]) catch break :blk null;
            break :blk std.unicode.utf8Decode(text[0..size]) catch null;
        },
        else => null,
    };
}

fn isErase(key: event.KeyEvent, direction: Move.Direction) bool {
    const value = codepoint(key) orelse return false;
    return switch (direction) {
        .backward => value == 0x08,
        .forward => value == 0x7f,
    };
}

fn isPrintableKey(key: event.KeyEvent) bool {
    if (key.modifiers.control or key.modifiers.alt or key.modifiers.super) return false;
    const value = codepoint(key) orelse return false;
    return value >= 0x20 and value != 0x7f;
}

/// UTF-16 code units before a UTF-8 byte offset. The offset must be a
/// codepoint boundary, and the whole text must be valid UTF-8: a native
/// adapter must never translate a range out of a corrupt document.
pub fn utf8ToUtf16(text: []const u8, byte: usize) error{
    InvalidUtf8,
    InvalidUtf8Boundary,
}!usize {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (byte > text.len) return error.InvalidUtf8Boundary;
    var units: usize = 0;
    var index: usize = 0;
    while (index < byte) {
        const size = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8;
        if (index + size > byte) return error.InvalidUtf8Boundary;
        const value = decodeCodepoint(text[index..], size) catch
            return error.InvalidUtf8;
        units += if (value > 0xffff) 2 else 1;
        index += size;
    }
    return units;
}

/// The UTF-8 byte offset of a UTF-16 code unit offset. An offset inside a
/// surrogate pair has no UTF-8 byte and is rejected.
pub fn utf16ToUtf8(text: []const u8, unit: usize) error{
    InvalidUtf8,
    InvalidUtf16Offset,
}!usize {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var seen: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (seen == unit) return index;
        const size = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8;
        const value = decodeCodepoint(text[index..], size) catch
            return error.InvalidUtf8;
        const width: usize = if (value > 0xffff) 2 else 1;
        if (seen + width > unit) return error.InvalidUtf16Offset;
        seen += width;
        index += size;
    }
    if (seen == unit) return index;
    return error.InvalidUtf16Offset;
}

/// Total UTF-16 length of valid UTF-8 text. Counts surrogate pairs twice, as
/// every native text API does.
pub fn utf16Length(text: []const u8) error{InvalidUtf8}!usize {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var units: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8;
        const value = decodeCodepoint(text[index..], size) catch
            return error.InvalidUtf8;
        units += if (value > 0xffff) 2 else 1;
        index += size;
    }
    return units;
}

/// True when `byte` starts a codepoint or ends the text.
pub fn isUtf8Boundary(text: []const u8, byte: usize) bool {
    if (byte == text.len) return true;
    if (byte > text.len) return false;
    return text[byte] & 0xc0 != 0x80;
}

test "unit conversion round-trips ASCII two-byte three-byte and surrogate-pair text" {
    // "a", "é", "だ", "👩", ZWJ, "👩": 17 bytes, 8 UTF-16 code units.
    const text = "a\xC3\xA9\xE3\x81\xA9\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA9";
    try std.testing.expectEqual(@as(usize, 17), text.len);
    try std.testing.expectEqual(@as(usize, 8), try utf16Length(text));
    const bytes = [_]usize{ 0, 1, 3, 6, 10, 13, 17 };
    const units = [_]usize{ 0, 1, 2, 3, 5, 6, 8 };
    for (bytes, units) |byte, unit| {
        try std.testing.expectEqual(unit, try utf8ToUtf16(text, byte));
        try std.testing.expectEqual(byte, try utf16ToUtf8(text, unit));
    }
    // A low surrogate half has no UTF-8 offset, and a byte inside a
    // multibyte sequence is not a codepoint boundary.
    try std.testing.expectError(error.InvalidUtf16Offset, utf16ToUtf8(text, 7));
    try std.testing.expectError(error.InvalidUtf16Offset, utf16ToUtf8(text, 9));
    try std.testing.expectError(error.InvalidUtf8Boundary, utf8ToUtf16(text, 2));
    try std.testing.expect(!isUtf8Boundary(text, 2));
    try std.testing.expect(isUtf8Boundary(text, 3));
    try std.testing.expect(isUtf8Boundary(text, text.len));
    try std.testing.expect(!isUtf8Boundary(text, text.len + 1));
}

test "invalid UTF-8 is rejected before any unit conversion" {
    try std.testing.expectError(error.InvalidUtf8, utf8ToUtf16("a\xff", 2));
    try std.testing.expectError(error.InvalidUtf8, utf16ToUtf8("a\xff", 1));
}
