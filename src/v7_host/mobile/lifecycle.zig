//! Mobile window and input lifecycle: the E04 state machine, with no platform
//! in it.
//!
//! Everything here is a value and a transition. A target adapter observes the
//! platform and calls `Machine.observe`; the machine decides what changed and
//! what the app has to do about it, and the adapter acts on the change through
//! the shared services. That split is what keeps native policy out of the core:
//! the core never learns that a phone has a home indicator, and this file never
//! calls into a platform.
//!
//! The facts it holds are all measurements, and each is reported as the platform
//! stated it:
//!
//!   * `Insets` is the safe area, in logical points, measured inward from the
//!     window. Four zeroes is a real reading on a device with no cutout and no
//!     system bar; it is never a stand-in for "unknown".
//!   * `Keyboard.support` and `Keyboard.visible` are separate. A window with
//!     nothing focused has no keyboard on screen, which is a different fact
//!     from a platform that cannot raise one, and a layout needs the
//!     difference. Both are also kept apart from "the platform has not
//!     answered", because an unmeasured keyboard is not a missing one.
//!   * `MemoryPressure` is the platform's own signal, mapped rather than
//!     invented: a lifecycle trim level is not pressure and maps to `none`.
//!
//! One reading is dropped rather than carried, and it is dropped on a fact of
//! the same kind rather than on a guess: a window the platform has taken off
//! the screen cannot have a keyboard on it, and the IME that owned a
//! composition was torn down with it. Entering the background therefore
//! clears both, because the alternative is a reading that no poll will ever
//! correct — nothing is measured while the app is not scheduled.
//!
//! Decisions that belong to the application are named, not made. `BackRequest`
//! carries the measured facts and a `BackDecider` returns the answer; this file
//! never guesses that a back gesture means "close the window", because on one
//! platform it does and on the other there is no such gesture at all.
const std = @import("std");

/// Logical-point insets, measured inward from the window's own bounds.
pub const Insets = struct {
    top: f32 = 0,
    left: f32 = 0,
    bottom: f32 = 0,
    right: f32 = 0,

    /// True when nothing is inset. A device with no cutout, no status bar and
    /// no home indicator reports exactly this, and it is a real answer.
    pub fn isEmpty(self: Insets) bool {
        return self.top == 0 and self.left == 0 and
            self.bottom == 0 and self.right == 0;
    }

    /// The same insets with non-finite fields treated as absent.
    ///
    /// A platform that cannot describe its safe area reports nothing rather
    /// than a half-filled rectangle, and a non-finite field is a corrupted
    /// reading rather than an inset. Zeroing it here means a layout downstream
    /// sees "no inset" and says so, instead of propagating a NaN into layout
    /// arithmetic where it would silently poison every bound.
    pub fn sanitized(self: Insets) Insets {
        return .{
            .top = finiteOrZero(self.top),
            .left = finiteOrZero(self.left),
            .bottom = finiteOrZero(self.bottom),
            .right = finiteOrZero(self.right),
        };
    }
};

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value) and value > 0) value else 0;
}

/// The rectangle left for interactive content once the safe area is removed.
pub fn contentRect(window: [2]f32, insets: Insets) [4]f32 {
    const safe = insets.sanitized();
    const left = @min(safe.left, window[0]);
    const top = @min(safe.top, window[1]);
    const right = @max(left, window[0] - @min(safe.right, window[0] - left));
    const bottom = @max(top, window[1] - @min(safe.bottom, window[1] - top));
    return .{ left, top, right, bottom };
}

/// What the platform said when it was asked whether this window has a screen
/// keyboard at all.
///
/// The three answers are kept apart because a layout treats them differently:
/// a window that answered "no" can never be occluded by a keyboard, while a
/// platform that has not answered yet may raise one on the next poll.
pub const KeyboardSupport = enum {
    /// Nobody has asked, or the platform refused the question. A keyboard may
    /// still appear, so this is never read as "there is none".
    unknown,
    /// The platform answered: this window has no screen keyboard.
    absent,
    /// The platform answered: this window has one and it can be raised.
    present,

    /// True only for an answer that was actually given.
    pub fn isKnown(self: KeyboardSupport) bool {
        return self != .unknown;
    }
};

/// The soft keyboard, as the platform describes it.
pub const Keyboard = struct {
    /// Whether this window has a screen keyboard at all. Unknown is a real
    /// state and is never written as `absent`.
    support: KeyboardSupport = .unknown,
    /// It is on screen right now. A platform that has not answered, or that
    /// answered "no", cannot be reporting a visible keyboard, and the
    /// constructor below is what makes that unrepresentable.
    visible: bool = false,
    /// The keyboard's own occlusion, in window points, or null when the
    /// platform could not measure it. Null and a zeroed rectangle are different
    /// answers and a layout must be able to tell them apart.
    occlusion: ?[4]f32 = null,

    /// True when a keyboard is up and covering part of the window.
    pub fn isOccluding(self: Keyboard) bool {
        if (!self.visible) return false;
        const rect = self.occlusion orelse return false;
        return rect[3] > rect[1];
    }

    /// One platform reading, with the two facts kept consistent with each
    /// other. A window the platform says has no keyboard is not occluded by
    /// one, and an unmeasured window is not either, so neither can arrive
    /// carrying the other's evidence.
    pub fn reading(
        support: KeyboardSupport,
        visible: bool,
        occlusion: ?[4]f32,
    ) Keyboard {
        return .{
            .support = support,
            .visible = support == .present and visible,
            .occlusion = if (support == .present) occlusion else null,
        };
    }
};

/// What the platform says about the text being edited.
///
/// The EDITING itself belongs to the shared text-input manager: this is the
/// adapter's read of the same events, kept so a back request can tell an open
/// composition from a committed field, and never a second way to change a
/// document.
pub const TextState = struct {
    /// Native text input is running for this window.
    pub const max_preedit: usize = 256;

    active: bool = false,
    /// An IME composition is open. This is what a back request dismisses first.
    composing: bool = false,
    /// A bounded copy of the composition, so a caller can read what the IME is
    /// showing without the platform's borrowed buffer.
    preedit: [max_preedit]u8 = [_]u8{0} ** max_preedit,
    preedit_len: usize = 0,
    /// The composition was longer than the bound. A truncated composition is
    /// reported as truncated rather than as a shorter composition, because the
    /// two mean different things to a caller.
    preedit_truncated: bool = false,
    /// Bumped on every committed-text event, so a caller can see that the
    /// document changed without holding the text itself.
    committed_generation: u64 = 0,

    /// The composition as a slice of this struct's own storage.
    pub fn preeditSlice(self: *const TextState) []const u8 {
        return self.preedit[0..self.preedit_len];
    }

    fn setPreedit(self: *TextState, text: []const u8) void {
        const bounded = utf8Boundary(text, max_preedit);
        @memcpy(self.preedit[0..bounded], text[0..bounded]);
        self.preedit_len = bounded;
        self.preedit_truncated = text.len > max_preedit;
        self.composing = true;
    }

    fn clearPreedit(self: *TextState) void {
        self.preedit_len = 0;
        self.preedit_truncated = false;
        self.composing = false;
    }
};

/// The longest prefix of `text` that is at most `limit` bytes AND ends on a
/// whole UTF-8 codepoint.
///
/// Cutting a composition at a raw byte bound is how a bounded buffer hands a
/// reader three stray continuation bytes as if they were a character: the
/// copy is then neither the composition nor a prefix of it. UTF-8
/// self-synchronises, so the start of a codepoint is exactly a byte that is
/// not a continuation byte, and walking back to one is enough.
pub fn utf8Boundary(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return end;
}

/// The platform's own lifecycle phase.
pub const Phase = enum {
    /// Interactive.
    foreground,
    /// The platform announced it is about to stop scheduling this app. Work
    /// that must finish before suspension belongs here and nowhere else.
    will_suspend,
    /// The app is not being scheduled and its window is off the screen.
    /// Nothing here should claim CPU, and nothing on screen belongs to it.
    background,
    /// The app is interactive again and the window is on screen.
    resumed,

    /// True while the app is not being scheduled, which is what decides whether
    /// a frame is worth producing.
    pub fn isScheduled(self: Phase) bool {
        return self == .foreground or self == .resumed;
    }
};

/// The platform's own memory signal, mapped rather than invented.
pub const MemoryPressure = enum {
    none,
    /// The platform asked for memory back. Caches may be dropped and images may
    /// be evicted; the model may not.
    warning,
    /// The platform said memory is critically short. A background-only app
    /// never gets here, and claiming it on a platform that publishes one level
    /// would be a stronger claim than the evidence supports.
    critical,
};

/// Where a back request came from, and whether this platform has one at all.
pub const BackSource = enum {
    /// No system back affordance exists on this target. iOS has no hardware or
    /// system back button, and SDL surfaces no substitute, so this is the
    /// honest answer rather than a synthesised gesture.
    unavailable,
    /// The Android system's back control, which SDL reports as the
    /// `SDL_SCANCODE_AC_BACK` key the platform's own key map defines.
    android_system_back,
};

/// What the platform measured when it raised a back request.
pub const BackRequest = struct {
    source: BackSource,
    /// What the platform said about this window's keyboard. An `unknown`
    /// support next to a false `keyboard_visible` is the honest answer before
    /// anything was measured; it is not the same as a keyboard that is
    /// measurably down, and a policy that only dismisses a keyboard it can see
    /// needs the difference.
    keyboard_support: KeyboardSupport,
    /// A keyboard is on screen covering the window.
    keyboard_visible: bool,
    /// An IME composition is open on the focused field.
    composing: bool,
    /// The app is not being scheduled. A back request while backgrounded is a
    /// different situation from one while interactive, and the app is told which.
    phase: Phase,
};

/// What the application decided to do about a back request.
pub const BackDecision = enum {
    /// The app consumed it. Nothing further happens.
    handled,
    /// Dismiss the on-screen keyboard and stop.
    dismiss_keyboard,
    /// Leave the app to the platform, which is what Android does with a back
    /// request no app consumed: it moves the task to the background.
    defer_to_platform,
    /// The app asked for a frame of its own; the adapter has nothing to do.
    ignored,
};

/// The application's answer. It is a callback because the policy is the app's:
/// the adapter reports the measured facts and never decides what back means.
pub const BackDecider = struct {
    context: ?*anyopaque = null,
    decide: *const fn (?*anyopaque, BackRequest) BackDecision,
};

/// The platform's display orientation, as it names it.
pub const Orientation = enum {
    unknown,
    landscape,
    landscape_flipped,
    portrait,
    portrait_flipped,

    /// True when the orientation puts the long edge vertical. A layout that
    /// only distinguishes portrait from landscape needs this and nothing else.
    pub fn isPortrait(self: Orientation) bool {
        return self == .portrait or self == .portrait_flipped;
    }
};

/// One thing the platform told us.
pub const Observation = union(enum) {
    /// The window's safe area changed.
    safe_area: Insets,
    /// The window's soft keyboard came up or went down.
    keyboard: Keyboard,
    /// Native text input started or stopped for this window.
    text_input_active: bool,
    /// The IME composition changed. An empty `text` ends the composition.
    composition: []const u8,
    /// Committed text arrived. The bytes are the platform's; nothing keeps them.
    committed: []const u8,
    will_enter_background,
    did_enter_background,
    will_enter_foreground,
    did_enter_foreground,
    /// The platform RAISED memory pressure at this level. A signal is one thing
    /// that happened; it is what `memory_events` counts.
    memory_signal: MemoryPressure,
    /// A reading of the level the platform currently holds, taken by polling.
    /// A poll repeats the same level every frame, so counting it as a signal
    /// would turn one warning into a frame-rate. It updates the current level
    /// and never the event count.
    memory_level: MemoryPressure,
    /// The area the shared text-input path published for the IME, in window
    /// points. It is an area the app chose, not a platform measurement, and it
    /// goes stale when the safe area or the keyboard moves.
    candidate: [4]f32,
    /// The display rotated.
    orientation: Orientation,
};

/// What the machine changed, and therefore what the app has to do.
///
/// A `null` observation means nothing changed and the caller has no work. A
/// `Change` is a fact about the host, not a command: the adapter routes it into
/// the shared frame demand, the session and the text-input manager, and the
/// core never sees it.
pub const Change = union(enum) {
    /// The safe area moved. Content has to be laid out again inside the new
    /// bounds, and the frame presented again.
    safe_area: Insets,
    /// The keyboard appeared or disappeared. The same layout work as a safe-area
    /// move, and the same consequence for a published candidate rectangle.
    keyboard: Keyboard,
    /// The text state changed: an IME composition opened, changed or closed, or
    /// committed text arrived.
    text_state: struct {
        composing: bool,
        /// Bumped by a commit, unchanged by a composition edit.
        committed_generation: u64,
    },
    /// The lifecycle phase moved. A resume has to re-arm the frame demand and
    /// the session's redraw, because a model update coalesced before the
    /// suspend has already been consumed by the pre-resume pump.
    phase: Phase,
    /// The current memory level moved, whether because the platform raised it
    /// or because a poll read a new value. Only a signal moves
    /// `Machine.memory_events`.
    memory_pressure: MemoryPressure,
    /// The IME candidate rectangle moved, so whatever the platform was told
    /// about it is no longer true and has to be published again.
    candidate: [4]f32,
    /// The display rotated.
    orientation: Orientation,
};

/// The state machine. Main thread only: every observation comes from the host's
/// own event pump, so a lock here would protect nothing and cost a frame.
pub const Machine = struct {
    insets: Insets = .{},
    /// Whether the platform has ever described its safe area. False means "not
    /// asked yet", which is different from "asked and answered with zeroes".
    insets_observed: bool = false,
    keyboard: Keyboard = .{},
    /// The IME candidate rectangle the shared text-input path last published,
    /// in window points. Null until one was published, because "no candidate"
    /// and "a candidate of zeroes" are different answers.
    candidate: ?[4]f32 = null,
    text: TextState = .{},
    phase: Phase = .resumed,
    /// The level the platform currently holds, whether it arrived as a signal
    /// or as a polled reading.
    memory: MemoryPressure = .none,
    /// How many times the platform RAISED pressure. A counter rather than a
    /// level, because the level can go back down and the app needs to know it
    /// was asked at all. Polled readings never land here.
    memory_events: u64 = 0,
    /// How many times a level was read by polling. Kept next to the signal
    /// count so a caller can see the two are different things: frames of
    /// polling that changed nothing are the whole reason the two exist.
    memory_reads: u64 = 0,
    orientation: Orientation = .unknown,
    /// Bumped on every change, so a caller can notice a change it did not
    /// inspect in detail.
    generation: u64 = 0,

    /// Record one platform fact. Returns what changed, or null when the fact
    /// matched what the machine already held.
    ///
    /// Reporting no change for an identical reading is the point: the platform
    /// re-announces its safe area on a rotation the layout already absorbed, and
    /// a caller that re-laid-out on every announcement would pay for a duplicate.
    pub fn observe(self: *Machine, event: Observation) ?Change {
        const change: ?Change = switch (event) {
            .safe_area => |value| blk: {
                const next = value.sanitized();
                if (self.insets_observed and std.meta.eql(next, self.insets)) break :blk null;
                self.insets = next;
                self.insets_observed = true;
                break :blk .{ .safe_area = next };
            },
            .keyboard => |value| blk: {
                if (std.meta.eql(self.keyboard, value)) break :blk null;
                self.keyboard = value;
                break :blk .{ .keyboard = value };
            },
            .candidate => |rect| blk: {
                if (self.candidate) |current| {
                    if (std.meta.eql(current, rect)) break :blk null;
                }
                self.candidate = rect;
                break :blk .{ .candidate = rect };
            },
            .text_input_active => |active| blk: {
                if (self.text.active == active) break :blk null;
                self.text.active = active;
                // Native text input stopping ends any open composition: the IME
                // is gone, so a composition it owned cannot still be open.
                if (!active) self.text.clearPreedit();
                break :blk .{ .text_state = .{
                    .composing = self.text.composing,
                    .committed_generation = self.text.committed_generation,
                } };
            },
            .composition => |text| blk: {
                // Nothing is measured while the app is not scheduled, and a
                // composition event the platform queued BEFORE it suspended is
                // exactly that: the window is off the screen, the IME that
                // owned the composition was torn down with it, and SDL will
                // still hand over its own buffer when the event is dequeued.
                //
                // Accepting it here would re-open the composition
                // `enterBackground` closed, and a back request raised while
                // backgrounded would be made against it — telling the app's
                // policy to dismiss a composition the IME shut down with the
                // window. The refusal is on the phase rather than on the
                // bytes, so it holds whatever the composition says and
                // whichever order the two events arrive in.
                //
                // A COMMIT is deliberately not refused for the same reason. It
                // cannot gain state: the preedit is already empty, and the
                // only thing it moves is a monotone counter that the shared
                // text-input path has already applied to the document.
                // Dropping it would hide a change the app really made.
                if (!self.phase.isScheduled()) break :blk null;
                const before_generation = self.text.committed_generation;
                if (text.len == 0) {
                    if (!self.text.composing) break :blk null;
                    self.text.clearPreedit();
                } else {
                    self.text.setPreedit(text);
                }
                break :blk .{ .text_state = .{
                    .composing = self.text.composing,
                    .committed_generation = before_generation,
                } };
            },
            .committed => |bytes| blk: {
                _ = bytes;
                self.text.committed_generation +%= 1;
                self.text.clearPreedit();
                break :blk .{ .text_state = .{
                    .composing = false,
                    .committed_generation = self.text.committed_generation,
                } };
            },
            .will_enter_background => self.setPhase(.will_suspend),
            .did_enter_background => self.enterBackground(),
            .will_enter_foreground => self.setPhase(.will_suspend),
            .did_enter_foreground => self.setPhase(.resumed),
            .memory_signal => |level| blk: {
                if (self.memory == level) break :blk null;
                self.memory = level;
                self.memory_events +%= 1;
                break :blk .{ .memory_pressure = level };
            },
            .memory_level => |level| blk: {
                self.memory_reads +%= 1;
                if (self.memory == level) break :blk null;
                self.memory = level;
                break :blk .{ .memory_pressure = level };
            },
            .orientation => |value| blk: {
                if (self.orientation == value) break :blk null;
                self.orientation = value;
                break :blk .{ .orientation = value };
            },
        };
        if (change != null) self.generation +%= 1;
        return change;
    }

    fn setPhase(self: *Machine, next: Phase) ?Change {
        if (self.phase == next) return null;
        self.phase = next;
        return .{ .phase = next };
    }

    /// The app left the screen. The phase moved, and what can only be true
    /// while it is there went with it.
    ///
    /// A keyboard is on screen over a window the platform has taken away, and
    /// an IME composition belongs to a keyboard that is gone, so neither
    /// survives the suspension. Keeping either is not a cautious default:
    /// nothing is polled while the app is unscheduled, so the reading would
    /// still be there when the platform raised a back request, and the
    /// application's policy would be told to dismiss a keyboard that is not
    /// up and a composition the IME closed.
    ///
    /// Clearing them is a one-way door within the suspension, and the
    /// `composition` arm of `observe` is what holds it shut: a composition
    /// event the platform had already queued cannot re-open one here.
    ///
    /// Support is not dropped with them. Whether this platform has a screen
    /// keyboard at all is a property of the platform rather than of this
    /// moment, and it is answered again by the next poll after a resume.
    fn enterBackground(self: *Machine) ?Change {
        self.keyboard.visible = false;
        self.keyboard.occlusion = null;
        self.text.clearPreedit();
        return self.setPhase(.background);
    }

    /// The measured facts a back request is made against.
    pub fn backRequest(self: *const Machine, source: BackSource) BackRequest {
        return .{
            .source = source,
            .keyboard_support = self.keyboard.support,
            .keyboard_visible = self.keyboard.visible,
            .composing = self.text.composing,
            .phase = self.phase,
        };
    }

    /// The current safe area. Null before the platform has described one, which
    /// is a different answer from a device that described a zero one.
    pub fn safeArea(self: *const Machine) ?Insets {
        return if (self.insets_observed) self.insets else null;
    }

    /// A snapshot of everything, for a caller that wants to read the state
    /// without a sequence of accessors that could each see a different frame.
    pub fn snapshot(self: *const Machine) Snapshot {
        return .{
            .insets = self.insets,
            .insets_observed = self.insets_observed,
            .keyboard = self.keyboard,
            .candidate = self.candidate,
            .text = .{
                .active = self.text.active,
                .composing = self.text.composing,
                .preedit_len = self.text.preedit_len,
                .preedit_truncated = self.text.preedit_truncated,
                .committed_generation = self.text.committed_generation,
            },
            .phase = self.phase,
            .memory = self.memory,
            .memory_events = self.memory_events,
            .memory_reads = self.memory_reads,
            .orientation = self.orientation,
            .generation = self.generation,
        };
    }
};

/// Every variant of a `Change` is a value too, so a change cannot outlive the
/// observation that produced it either: nothing on the way out of this machine
/// is a pointer into a buffer the platform is free to overwrite.
/// A copy of the machine's state with no borrowed storage. A caller can hold one
/// across a frame boundary, which the machine itself cannot promise because the
/// composition buffer is overwritten by the next composition.
pub const Snapshot = struct {
    insets: Insets,
    insets_observed: bool,
    keyboard: Keyboard,
    candidate: ?[4]f32,
    text: struct {
        active: bool,
        composing: bool,
        preedit_len: usize,
        preedit_truncated: bool,
        committed_generation: u64,
    },
    phase: Phase,
    memory: MemoryPressure,
    /// Signals the platform raised, never a polled reading.
    memory_events: u64,
    /// Level readings taken by polling, never a signal.
    memory_reads: u64,
    orientation: Orientation,
    generation: u64,
};

test "api-w23 mobile safe area of zeroes is a reading, not an absence" {
    var machine: Machine = .{};
    // Before the platform has said anything, there is no answer to give.
    try std.testing.expect(machine.safeArea() == null);

    const empty: Insets = .{};
    const change = machine.observe(.{ .safe_area = empty }).?;
    try std.testing.expectEqual(Change{ .safe_area = empty }, change);
    // A device with no cutout and no system bar answers with zeroes, and that
    // answer is now distinguishable from having never been asked.
    try std.testing.expectEqual(empty, machine.safeArea().?);
    try std.testing.expect(machine.insets.isEmpty());

    // The platform re-announcing the same answer changes nothing, so a
    // duplicate rotation event does not re-lay-out the window.
    try std.testing.expect(machine.observe(.{ .safe_area = empty }) == null);
    try std.testing.expectEqual(@as(u64, 1), machine.generation);
}

test "api-w23 mobile safe area drops a non-finite reading instead of poisoning layout" {
    var machine: Machine = .{};
    const change = machine.observe(.{ .safe_area = .{
        .top = std.math.nan(f32),
        .left = 44,
        .bottom = 34,
        .right = -1,
    } }).?;
    // A NaN inset would silently poison every bound derived from it, and a
    // negative inset is not an inset. Both are absent, not clamped guesses.
    try std.testing.expectEqual(Insets{ .left = 44, .bottom = 34 }, change.safe_area);
    try std.testing.expectEqual(Insets{ .left = 44, .bottom = 34 }, machine.insets);
}

test "api-w23 mobile content rect never inverts when insets exceed the window" {
    // A cutout wider than the window is a platform defect, and a layout that
    // inverted here would paint outside the surface.
    const rect = contentRect(.{ 100, 80 }, .{ .top = 200, .left = 200, .bottom = 200, .right = 200 });
    try std.testing.expectEqual([4]f32{ 100, 80, 100, 80 }, rect);

    const sane = contentRect(.{ 400, 800 }, .{ .top = 47, .left = 0, .bottom = 34, .right = 0 });
    try std.testing.expectEqual([4]f32{ 0, 47, 400, 766 }, sane);
}

test "api-w23 mobile keyboard support and visibility are different facts" {
    var machine: Machine = .{};
    // A platform that can raise a keyboard, with nothing focused: present and
    // not visible. That is not the same as a platform with no keyboard.
    const shown = machine.observe(.{ .keyboard = .reading(.present, true, null) }).?;
    try std.testing.expectEqual(KeyboardSupport.present, shown.keyboard.support);
    try std.testing.expect(shown.keyboard.isOccluding() == false);
    // Visible with no measured occlusion is "a keyboard is up, its extent is
    // unknown", which a layout must be able to see.
    try std.testing.expect(machine.keyboard.occlusion == null);

    const hidden = machine.observe(.{ .keyboard = .reading(.present, false, null) }).?;
    try std.testing.expectEqual(false, hidden.keyboard.visible);
    // A keyboard that is down occludes nothing, whatever its frame said.
    try std.testing.expect(!machine.keyboard.isOccluding());
}

test "api-w23 mobile an unmeasured keyboard is not a missing one" {
    var machine: Machine = .{};
    // Nothing has been asked yet, so the honest answer is "unknown". Reading it
    // as "absent" would let a layout decide the keyboard will never appear.
    try std.testing.expectEqual(KeyboardSupport.unknown, machine.keyboard.support);
    try std.testing.expect(!machine.keyboard.support.isKnown());
    // A platform that answers "no" is a different answer from one that has not
    // answered, and the two have to survive a round trip through the machine.
    _ = machine.observe(.{ .keyboard = .reading(.absent, false, null) });
    try std.testing.expectEqual(KeyboardSupport.absent, machine.keyboard.support);
    try std.testing.expect(machine.keyboard.support.isKnown());

    // A window with no keyboard cannot be occluded by one even when the
    // platform handed over a frame for it, and the constructor is what keeps
    // that claim from being constructible.
    const refused = Keyboard.reading(.absent, true, .{ 0, 0, 0, 400 });
    try std.testing.expect(!refused.visible);
    try std.testing.expect(refused.occlusion == null);
    try std.testing.expect(!refused.isOccluding());
}

test "api-w23 mobile composition is bounded and reports its own truncation" {
    var machine: Machine = .{};
    const long = "x" ** (TextState.max_preedit + 10);
    const change = machine.observe(.{ .composition = long }).?;
    try std.testing.expect(change.text_state.composing);
    try std.testing.expectEqual(TextState.max_preedit, machine.text.preedit_len);
    // A composition longer than the bound is reported as truncated rather than
    // as a shorter composition, because the two mean different things.
    try std.testing.expect(machine.text.preedit_truncated);

    const short = "abc";
    _ = machine.observe(.{ .composition = short });
    try std.testing.expectEqualStrings(short, machine.text.preeditSlice());
    try std.testing.expect(!machine.text.preedit_truncated);
}

test "api-w23 mobile a bounded composition copy never splits a codepoint" {
    // 255 ASCII bytes, then a three-byte codepoint: the byte bound of 256 lands
    // in the middle of it. Copying 256 raw bytes would hand the caller the
    // first two bytes of a character as if they were text.
    const prefix = "a" ** (TextState.max_preedit - 1);
    var machine: Machine = .{};
    _ = machine.observe(.{ .composition = prefix ++ "\u{20ac}tail" });
    try std.testing.expectEqual(TextState.max_preedit - 1, machine.text.preedit_len);
    try std.testing.expect(machine.text.preedit_truncated);
    // Every byte held is a whole codepoint, which is what a reader of the
    // composition is entitled to assume.
    try std.testing.expect(std.unicode.utf8ValidateSlice(machine.text.preeditSlice()));

    // A composition that ends exactly on the bound is not truncated and is not
    // shortened either, so the bound itself is not what a caller reads.
    _ = machine.observe(.{ .composition = "b" ** TextState.max_preedit });
    try std.testing.expectEqual(TextState.max_preedit, machine.text.preedit_len);
    try std.testing.expect(!machine.text.preedit_truncated);

    // A bound that falls on a codepoint start keeps every byte up to it.
    try std.testing.expectEqual(4, utf8Boundary("a\u{20ac}b", 4));
    try std.testing.expectEqual(1, utf8Boundary("a\u{20ac}b", 3));
    try std.testing.expectEqual(5, utf8Boundary("a\u{20ac}b", 6));
}

test "api-w23 mobile a commit ends the composition and bumps its own generation" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .composition = "ni" });
    const before = machine.text.committed_generation;
    const change = machine.observe(.{ .committed = "nǐ" }).?;
    try std.testing.expect(!change.text_state.composing);
    // A commit is what moves the document, so it is what bumps the generation.
    // A composition edit is not.
    try std.testing.expectEqual(before + 1, change.text_state.committed_generation);
    try std.testing.expectEqual(@as(usize, 0), machine.text.preedit_len);
}

test "api-w23 mobile stopping native text input ends an open composition" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .text_input_active = true });
    _ = machine.observe(.{ .composition = "ka" });
    try std.testing.expect(machine.text.composing);
    // The IME owned the composition, and the IME is gone, so a composition it
    // owned cannot still be open. Leaving it set would make a back request
    // dismiss a composition that no longer exists.
    const change = machine.observe(.{ .text_input_active = false }).?;
    try std.testing.expect(!change.text_state.composing);
    try std.testing.expect(!machine.text.composing);
}

test "api-w23 mobile leaving the screen takes the keyboard and the composition with it" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .keyboard = .reading(.present, true, .{ 0, 300, 400, 800 }) });
    _ = machine.observe(.{ .text_input_active = true });
    _ = machine.observe(.{ .composition = "hou" });
    try std.testing.expect(machine.keyboard.isOccluding());

    // The window is still on screen, so everything on it is still true and the
    // app has its last chance to commit.
    _ = machine.observe(.will_enter_background);
    try std.testing.expect(machine.keyboard.visible);
    try std.testing.expect(machine.text.composing);

    // It is not. The keyboard was on screen over a window the platform has
    // taken away, and the composition belonged to that keyboard, so neither is
    // a reading any more. Nothing polls while the app is unscheduled, so a
    // reading kept here would be the one the next back request is made from.
    _ = machine.observe(.did_enter_background);
    try std.testing.expect(!machine.keyboard.visible);
    try std.testing.expect(!machine.keyboard.isOccluding());
    try std.testing.expect(machine.keyboard.occlusion == null);
    try std.testing.expect(!machine.text.composing);
    try std.testing.expectEqual(@as(usize, 0), machine.text.preedit_len);
    try std.testing.expect(!machine.text.preedit_truncated);

    // Whether this platform HAS a keyboard is a fact about the platform rather
    // than about this moment, and it is not withdrawn with the reading.
    try std.testing.expectEqual(KeyboardSupport.present, machine.keyboard.support);
    try std.testing.expect(machine.keyboard.support.isKnown());
}

test "api-w23 mobile suspend and resume are four distinct phases" {
    var machine: Machine = .{};
    try std.testing.expectEqual(Change{ .phase = .will_suspend }, machine.observe(.will_enter_background).?);
    try std.testing.expectEqual(Change{ .phase = .background }, machine.observe(.did_enter_background).?);
    // "About to enter the foreground" is still not interactive, so it maps to
    // the same not-scheduled phase rather than claiming the app can draw.
    try std.testing.expectEqual(Change{ .phase = .will_suspend }, machine.observe(.will_enter_foreground).?);
    try std.testing.expectEqual(Change{ .phase = .resumed }, machine.observe(.did_enter_foreground).?);
    try std.testing.expect(machine.phase.isScheduled());
    try std.testing.expectEqual(Change{ .phase = .will_suspend }, machine.observe(.will_enter_background).?);
    try std.testing.expect(!machine.phase.isScheduled());
}

test "api-w23 mobile a pressure signal is counted and a repeat is not a new one" {
    var machine: Machine = .{};
    try std.testing.expectEqual(
        Change{ .memory_pressure = .warning },
        machine.observe(.{ .memory_signal = .warning }).?,
    );
    try std.testing.expectEqual(@as(u64, 1), machine.memory_events);
    // The platform asking twice at the same level is one thing that happened,
    // and a caller that dropped caches per event would do it twice.
    try std.testing.expect(machine.observe(.{ .memory_signal = .warning }) == null);
    try std.testing.expectEqual(@as(u64, 1), machine.memory_events);
    _ = machine.observe(.{ .memory_signal = .critical });
    try std.testing.expectEqual(@as(u64, 2), machine.memory_events);
    try std.testing.expectEqual(MemoryPressure.critical, machine.memory);
}

test "api-w23 mobile polling a level frame after frame is never pressure" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .memory_signal = .warning });
    try std.testing.expectEqual(@as(u64, 1), machine.memory_events);

    // Every frame asks what level the platform holds. Only the first of those
    // reads is even a change, and none of them is a thing that happened, so a
    // cache-dropping policy keyed on events runs once and not once per frame.
    for (0..60) |_| {
        try std.testing.expect(machine.observe(.{ .memory_level = .warning }) == null);
    }
    try std.testing.expectEqual(@as(u64, 1), machine.memory_events);
    try std.testing.expectEqual(@as(u64, 60), machine.memory_reads);

    // A level that really did move is a change the app has to act on, and it
    // still is not a signal: no platform raised anything this frame.
    try std.testing.expectEqual(
        Change{ .memory_pressure = .critical },
        machine.observe(.{ .memory_level = .critical }).?,
    );
    try std.testing.expectEqual(MemoryPressure.critical, machine.memory);
    try std.testing.expectEqual(@as(u64, 1), machine.memory_events);
    try std.testing.expectEqual(@as(u64, 61), machine.memory_reads);
}

test "api-w23 mobile back request reports what was measured and decides nothing" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .keyboard = .reading(.present, true, null) });
    _ = machine.observe(.{ .text_input_active = true });
    _ = machine.observe(.{ .composition = "hou" });

    const Request = struct {
        fn decide(_: ?*anyopaque, request: BackRequest) BackDecision {
            // The policy is the application's, and the facts it needs are all
            // here: a keyboard is up, a composition is open, and the app is
            // interactive.
            if (request.composing) return .dismiss_keyboard;
            if (request.keyboard_visible) return .dismiss_keyboard;
            if (request.phase == .background) return .defer_to_platform;
            return .handled;
        }
    };
    const decider: BackDecider = .{ .decide = Request.decide };
    const request = machine.backRequest(.android_system_back);
    try std.testing.expectEqual(BackDecision.dismiss_keyboard, decider.decide(null, request));

    _ = machine.observe(.did_enter_background);
    const while_away = machine.backRequest(.android_system_back);
    try std.testing.expectEqual(BackDecision.defer_to_platform, decider.decide(null, while_away));
    try std.testing.expectEqual(BackSource.android_system_back, while_away.source);
}

test "api-w23 mobile a target with no back affordance says so instead of inventing one" {
    var machine: Machine = .{};
    // iOS has no system back control and SDL surfaces no substitute. Reporting
    // the request as available there would mean a gesture recogniser nobody
    // asked for, so the source is the absence itself.
    const request = machine.backRequest(.unavailable);
    try std.testing.expectEqual(BackSource.unavailable, request.source);
    // The request carries the facts as measured, and an unmeasured keyboard is
    // reported as unmeasured rather than as one that is demonstrably down: a
    // policy must be able to tell "nothing is up" from "nobody has looked".
    try std.testing.expectEqual(KeyboardSupport.unknown, request.keyboard_support);
}

test "api-w23 mobile orientation is a fact and repeats are not changes" {
    var machine: Machine = .{};
    try std.testing.expectEqual(Orientation.unknown, machine.orientation);
    try std.testing.expectEqual(
        Change{ .orientation = .portrait_flipped },
        machine.observe(.{ .orientation = .portrait_flipped }).?,
    );
    try std.testing.expect(machine.orientation.isPortrait());
    try std.testing.expect(machine.observe(.{ .orientation = .portrait_flipped }) == null);
    _ = machine.observe(.{ .orientation = .landscape });
    try std.testing.expect(!machine.orientation.isPortrait());
}

test "api-w23 mobile snapshot outlives the machine's composition buffer" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .safe_area = .{ .top = 44, .bottom = 34 } });
    _ = machine.observe(.{ .text_input_active = true });
    _ = machine.observe(.{ .composition = "abc" });
    const held = machine.snapshot();
    // The next composition overwrites the machine's own buffer. A snapshot is
    // the copy a caller keeps, and it reports the length it held rather than a
    // pointer into storage that has moved on.
    _ = machine.observe(.{ .composition = "zzzzz" });
    try std.testing.expectEqual(@as(usize, 3), held.text.preedit_len);
    try std.testing.expectEqual(@as(usize, 5), machine.text.preedit_len);
    try std.testing.expectEqual(Insets{ .top = 44, .bottom = 34 }, held.insets);
    // The generation a caller sees is the one it took, not one the machine
    // grows behind it, so a held snapshot is a reading of one instant.
    const held_generation = held.generation;
    _ = machine.observe(.{ .composition = "y" });
    try std.testing.expect(held_generation < machine.generation);
}

test "api-w23 mobile the published candidate rectangle is a fact, not a default" {
    var machine: Machine = .{};
    // Nothing published a candidate yet. A rectangle of zeroes would be a claim
    // that the IME was told to sit in the top-left corner, which is not the
    // same answer as "the app has not asked".
    try std.testing.expect(machine.candidate == null);
    try std.testing.expect(machine.snapshot().candidate == null);

    const caret = [4]f32{ 12, 700, 12, 736 };
    try std.testing.expectEqual(
        Change{ .candidate = caret },
        machine.observe(.{ .candidate = caret }).?,
    );
    try std.testing.expectEqual(caret, machine.candidate.?);
    // Re-publishing the same area is not a change: a frame that repaints does
    // not invalidate the candidate, only a moved caret or a moved keyboard does.
    try std.testing.expect(machine.observe(.{ .candidate = caret }) == null);
}

test "api-w23 mobile a composition queued before the suspend cannot re-open one" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .text_input_active = true });
    _ = machine.observe(.{ .composition = "hou" });
    try std.testing.expect(machine.text.composing);

    _ = machine.observe(.did_enter_background);
    try std.testing.expect(!machine.text.composing);

    // SDL keeps handing over its own buffer after the window has left the
    // screen, and the event it was already carrying is dequeued after the
    // suspend. Nothing polls while the app is unscheduled, so this is a
    // reading of a moment that has passed, and it is refused.
    const generation = machine.generation;
    try std.testing.expect(machine.observe(.{ .composition = "hou" }) == null);
    try std.testing.expect(!machine.text.composing);
    try std.testing.expectEqual(@as(usize, 0), machine.text.preedit_len);
    try std.testing.expectEqual(generation, machine.generation);

    // A back request raised while backgrounded is therefore made against no
    // composition at all, which is the whole promise `enterBackground` makes.
    try std.testing.expect(!machine.backRequest(.android_system_back).composing);

    // The same bytes once the app is scheduled again are a real composition.
    _ = machine.observe(.did_enter_foreground);
    try std.testing.expect(machine.observe(.{ .composition = "hou" }) != null);
    try std.testing.expect(machine.text.composing);
    try std.testing.expectEqualStrings("hou", machine.text.preeditSlice());
}

test "api-w23 mobile a commit queued before the suspend is not thrown away" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .text_input_active = true });
    _ = machine.observe(.{ .composition = "ni" });
    _ = machine.observe(.did_enter_background);
    const before = machine.text.committed_generation;

    // A commit cannot gain state: the preedit is already empty and the only
    // thing it moves is a monotone counter the shared text-input path has
    // already applied to the document. Refusing it would hide a change the
    // application really made, and the composition refusal above would have
    // been the wrong rule to generalise from.
    const change = machine.observe(.{ .committed = "nǐ" }).?;
    try std.testing.expectEqual(before + 1, change.text_state.committed_generation);
    try std.testing.expect(!change.text_state.composing);
    try std.testing.expectEqual(@as(usize, 0), machine.text.preedit_len);
    try std.testing.expect(machine.text.active);
}

test "api-w23 mobile a suspend and resume cycle keeps focus and the document" {
    var machine: Machine = .{};
    _ = machine.observe(.{ .keyboard = .reading(.present, true, .{ 0, 300, 400, 800 }) });
    _ = machine.observe(.{ .text_input_active = true });
    _ = machine.observe(.{ .committed = "hou" });
    const committed = machine.text.committed_generation;
    _ = machine.observe(.{ .composition = "ho" });
    try std.testing.expectEqual(Phase.resumed, machine.phase);

    // The whole cycle, in the order the platform announces it.
    try std.testing.expectEqual(
        Change{ .phase = .will_suspend },
        machine.observe(.will_enter_background).?,
    );
    // The window is still on the screen, so the keyboard and the composition
    // are still true and the application still has its last chance to commit.
    try std.testing.expect(machine.keyboard.isOccluding());
    try std.testing.expect(machine.text.composing);
    try std.testing.expect(machine.phase.isScheduled() == false);

    try std.testing.expectEqual(
        Change{ .phase = .background },
        machine.observe(.did_enter_background).?,
    );
    // What can only be true while the app is there went with it.
    try std.testing.expect(!machine.keyboard.isOccluding());
    try std.testing.expectEqual(KeyboardSupport.present, machine.keyboard.support);
    try std.testing.expect(!machine.text.composing);

    _ = machine.observe(.will_enter_foreground);
    try std.testing.expectEqual(Phase.will_suspend, machine.phase);
    try std.testing.expect(!machine.phase.isScheduled());

    try std.testing.expectEqual(
        Change{ .phase = .resumed },
        machine.observe(.did_enter_foreground).?,
    );
    // Focus and the document came through the cycle untouched. Only the
    // composition was lost, and it was lost at one named point rather than by
    // the order two queued events happened to be dequeued in.
    try std.testing.expect(machine.text.active);
    try std.testing.expectEqual(committed, machine.text.committed_generation);
    try std.testing.expect(!machine.text.composing);
    try std.testing.expectEqual(Phase.resumed, machine.snapshot().phase);
    try std.testing.expect(machine.snapshot().text.active);
}

test "api-w23 mobile nothing a change carries borrows the platform's buffer" {
    var machine: Machine = .{};
    // The bytes are SDL's and are valid for this call only. The machine copies
    // what it keeps, so a snapshot or a change reported after the fact is a
    // reading of what the platform said, not a view of a buffer the next poll
    // is free to overwrite.
    var bytes = [4]u8{ 'h', 'o', 'u', 'x' };
    _ = machine.observe(.{ .composition = bytes[0..3] });
    bytes = .{ 'z', 'z', 'z', 'z' };
    try std.testing.expectEqualStrings("hou", machine.text.preeditSlice());

    // Committed bytes are not kept at all. The document belongs to the shared
    // text-input manager, and the only thing this adapter records is that it
    // moved — a counter, not a copy of text nobody asked it to keep.
    const before = machine.text.committed_generation;
    _ = machine.observe(.{ .committed = bytes[0..] });
    try std.testing.expectEqual(before + 1, machine.text.committed_generation);
    try std.testing.expectEqual(@as(usize, 0), machine.text.preedit_len);
}
