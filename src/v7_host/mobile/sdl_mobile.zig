//! E04: the mobile host adapter — raw SDL3 events and polled platform facts
//! into the shared host, with the `lifecycle.Machine` deciding what they mean.
//!
//! Three rules decide the shape of this file.
//!
//! OBSERVE, DO NOT EDIT. The shared host already delivers keys, committed text
//! and IME composition to the App through `Window.translate` and the session's
//! text-input manager. This adapter watches the same raw events so it can tell a
//! back request from an open composition, and it never applies a document edit.
//! A second path into the model would make every ordinary keystroke ambiguous
//! about which of the two delivered it.
//!
//! MEASURE, DO NOT GUESS. A safe area, a keyboard and a memory level are all
//! POLLS: the platform holds the last value and repeats it. So a reading that
//! has not moved produces no change at all, and a memory level read on sixty
//! consecutive frames is one reading, not sixty pressure events. Only a signal
//! the platform actually raised counts as an event.
//!
//! NO RUNTIME OF ITS OWN. There is no thread, no timer and no queue here. Every
//! observation arrives in the host's own event pump, every effect goes through
//! the host's own methods, and the demand goes through the same `FrameDemand`
//! and `Session.requestRedraw` a resize uses.
//!
//! Coordinates are converted with the window's own measured logical and
//! device-pixel extents, never with a display's DPI. SDL derives its pixel scale
//! from the density, so a density constant applied on top of it would scale
//! every coordinate twice.
//!
//! `Application` has no raw-event callback: `dispatch` routes the event and then
//! reports the translated result, so an observer that needs the untranslated
//! event drives the pump itself. `Observer.pump` is that path — it calls the
//! same public `pollEvent` / `dispatch` pair every host uses, so an event is
//! observed here and routed there exactly once, and nothing in the shared host
//! needs a field for it: `Observer.pump` IS the seam, and a host that wants raw
//! events calls it rather than inventing a callback the application does not
//! have.
const std = @import("std");
const sdl3 = @import("sdl3");
const nogui = @import("nogui");
const application = @import("../application.zig");
const Window = @import("../window.zig").Window;
const lifecycle = @import("lifecycle.zig");
const native = @import("native.zig");
const geometry = nogui.geometry;

const c = native.c;

/// The units a platform's window facts are measured in.
///
/// This is not a guess about density; it is which coordinate space the platform
/// measured in, and it comes from the shim header's own definition.
pub const UnitSpace = enum {
    /// UIKit points. SDL reports an iOS window's size and every one of its
    /// input events in points, so this space is already the logical one.
    logical_points,
    /// Physical device pixels, which is what an Android window fact is measured
    /// in. Dividing by the window's own pixel scale is the only conversion that
    /// lands it in the logical space.
    device_pixels,
};

/// The unit space a target's shim measures its window facts in.
///
/// The platform is a parameter rather than a comptime value so the mapping is a
/// fact that can be checked on any host, not only on the device the code was
/// written for. A target with no shim has no facts to convert, so it reports the
/// space the host already works in rather than a refusal every caller has to
/// catch.
pub fn unitSpace(platform: native.Platform) UnitSpace {
    return switch (platform) {
        .ios => .logical_points,
        .android => .device_pixels,
        .unavailable => .logical_points,
    };
}

/// The measured relationship between the window's logical space — where SDL
/// reports every input event — and its device pixels.
///
/// This is the adapter's own measurement holder, not a second scale: the
/// conversion itself is the core's `geometry.PixelScale`, so a mobile fact and
/// a rendered pixel are converted by the same code.
pub const PixelScale = struct {
    /// The window's logical extent, in the units SDL reports input in.
    logical: [2]f32 = .{ 1, 1 },
    /// The window's device-pixel extent.
    pixels: [2]f32 = .{ 1, 1 },
    /// False until both extents have been read off a live window. A default
    /// constructed scale claims nothing, so a caller that has not measured
    /// cannot accidentally present a 1:1 window as a fact.
    measured: bool = false,

    /// The window's own device-pixel scale, or null when the window has not
    /// been measured or reports an extent that is not one. A zero extent is
    /// neither a scale of zero nor a scale of one, so neither is invented.
    pub fn factor(self: PixelScale) ?geometry.PixelScale {
        if (!self.measured) return null;
        const device: geometry.DeviceSize = .{
            .width = pixelCount(self.pixels[0]) orelse return null,
            .height = pixelCount(self.pixels[1]) orelse return null,
        };
        return geometry.PixelScale.init(
            .{ .width = self.logical[0], .height = self.logical[1] },
            device,
        ) catch null;
    }

    /// One platform reading, in window-logical units.
    pub fn toLogical(self: PixelScale, value: [2]f32, space: UnitSpace) [2]f32 {
        return switch (space) {
            // UIKit points and SDL's iOS window space are the same unit, so the
            // conversion is the identity. The measured pixel scale is
            // deliberately NOT applied here: doing so would shrink every
            // reading by the content scale and put the safe area in the wrong
            // place on every retina device.
            .logical_points => value,
            .device_pixels => blk: {
                const scale = self.factor() orelse break :blk value;
                break :blk .{
                    value[0] / scale.x,
                    value[1] / scale.y,
                };
            },
        };
    }

    /// A platform rectangle, in window-logical units.
    pub fn rectToLogical(self: PixelScale, rect: c.nogui_mobile_rect, space: UnitSpace) [4]f32 {
        const origin = self.toLogical(.{ narrow(rect.x0), narrow(rect.y0) }, space);
        const far = self.toLogical(.{ narrow(rect.x1), narrow(rect.y1) }, space);
        return .{ origin[0], origin[1], far[0], far[1] };
    }
};

/// The shim reports window facts in C doubles and the host works in f32, so
/// every reading is narrowed once, here, rather than at each use.
fn narrow(value: f64) f32 {
    return @floatCast(value);
}

/// A pixel count the host's `u32` surface extent can hold, or null.
///
/// The measurement crossed from the platform through a float, so a truncated or
/// non-finite one is refused rather than wrapped: a wrapped count would put the
/// safe area somewhere no window has an edge. The bound is two to the thirty
/// second, not `maxInt(u32)`, because f32 cannot represent every u32 and a
/// reading that rounds up to that would wrap an unsigned extent to zero.
fn pixelCount(value: f32) ?u32 {
    if (!std.math.isFinite(value) or value < 1) return null;
    if (value >= 4_294_967_296.0) return null;
    return @intFromFloat(value);
}

/// Where a contact is in its own life.
pub const ContactPhase = enum {
    began,
    moved,
    ended,
    /// The platform took the contact away — a system gesture, a palm rejection,
    /// the window leaving the screen. It is not an end the user chose, and a
    /// consumer may need to tell the two apart.
    cancelled,
};

/// Which part of a pinch the platform is reporting.
pub const PinchPhase = enum { began, updated, ended };

/// A pinch the platform itself recognised.
///
/// Forwarded, never derived. SDL delivers a pinch because the platform reported
/// one, and this adapter does not infer one from two contacts: a recogniser
/// would be a second opinion about a gesture the platform already has an answer
/// for, and it would fire on a two-finger scroll and on a two-finger tap.
pub const Pinch = struct {
    phase: PinchPhase,
    /// The platform's own scale change since the last update. Below one zooms
    /// out, above one zooms in.
    scale: f32,
};

/// The part of a pinch one raw event reports.
pub fn pinchPhaseOf(raw: *const sdl3.events.Event) PinchPhase {
    return switch (raw.*) {
        .pinch_begin => .began,
        .pinch_update => .updated,
        else => .ended,
    };
}

/// One contact, exactly as the platform reported it.
///
/// The identity is the device and the finger, not a sequence number: a finger
/// that lifts and lands again is a new contact, and two fingers on the same
/// device are never the same contact. `contact` folds them the way
/// `nogui.event.TouchEvent.id` folds them, so a consumer can match a raw sample
/// with the core event the host routed from the same finger.
pub const Touch = struct {
    contact: u128,
    device: u64,
    finger: u64,
    phase: ContactPhase,
    /// Window-logical position, measured from the window's own logical extent.
    position: [2]f32,
    /// Window-logical movement for this sample, from the platform's normalised
    /// one. It is the delta the platform measured, not a difference taken here.
    movement: [2]f32,
    pressure: f32,
};

/// The same identity the core uses, folded from the two SDL ids.
pub fn contactIdentity(device: u64, finger: u64) u128 {
    return (@as(u128, device) << 64) | @as(u128, finger);
}

/// One contact's measured position, in window-logical units.
pub fn measureTouch(
    finger: sdl3.events.TouchFinger,
    phase: ContactPhase,
    logical: [2]f32,
) Touch {
    return .{
        .contact = contactIdentity(finger.id.value, finger.finger_id.value),
        .device = finger.id.value,
        .finger = finger.finger_id.value,
        .phase = phase,
        .position = .{ finger.x * logical[0], finger.y * logical[1] },
        .movement = .{ finger.dx * logical[0], finger.dy * logical[1] },
        .pressure = finger.pressure,
    };
}

/// Contacts this observer is tracking at once.
///
/// A fixed table is the point: a platform that reports more simultaneous
/// fingers than the table holds must not make a frame allocate, and a refusal
/// has to be visible. Merging two live fingers into one entry would make a
/// gesture recogniser see a contact that never existed.
pub const max_contacts = 16;

pub const Contact = struct {
    contact: u128,
    device: u64,
    finger: u64,
    position: [2]f32,
    pressure: f32,
    /// When this contact landed, on SDL's own clock. A consumer that needs a
    /// velocity or a long-press reads this rather than a frame counter.
    started_ns: u64,
};

pub const Contacts = struct {
    entries: [max_contacts]Contact,
    len: u16 = 0,
    /// Contacts refused because the table was full, and samples for contacts it
    /// never held. Surfaced, never hidden.
    refused: u32 = 0,

    pub fn count(self: *const Contacts) usize {
        return self.len;
    }

    pub fn slice(self: *const Contacts) []const Contact {
        return self.entries[0..self.len];
    }

    pub fn find(self: *Contacts, contact: u128) ?*Contact {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.contact == contact) return entry;
        }
        return null;
    }

    /// The same lookup for a caller that only reads.
    pub fn get(self: *const Contacts, contact: u128) ?Contact {
        for (self.slice()) |entry| {
            if (entry.contact == contact) return entry;
        }
        return null;
    }

    /// A contact already in the table moves rather than being added twice: the
    /// platform sends a down before every stream of motion samples, and a
    /// repeat must not look like a second finger.
    pub fn begin(self: *Contacts, entry: Contact) void {
        if (self.find(entry.contact)) |slot| {
            slot.* = entry;
            return;
        }
        if (self.len == max_contacts) {
            self.refused += 1;
            return;
        }
        self.entries[self.len] = entry;
        self.len += 1;
    }

    /// Update a tracked contact. A sample for a contact the table does not hold
    /// has no beginning — its down was refused, or it already ended — so it is
    /// counted rather than silently starting a contact.
    pub fn move(self: *Contacts, contact: u128, position: [2]f32, pressure: f32) bool {
        const slot = self.find(contact) orelse {
            self.refused += 1;
            return false;
        };
        slot.position = position;
        slot.pressure = pressure;
        return true;
    }

    pub fn end(self: *Contacts, contact: u128) bool {
        for (self.slice(), 0..) |entry, index| {
            if (entry.contact != contact) continue;
            self.entries[index] = self.entries[self.len - 1];
            self.len -= 1;
            return true;
        }
        return false;
    }

    /// Drop every contact. A suspend takes the window out from under every
    /// finger on it, so a resume that kept them would start from contacts the
    /// user has already lifted.
    pub fn clear(self: *Contacts) void {
        self.len = 0;
    }
};

/// The platform's display orientation, mapped onto the machine's names.
pub fn orientationOf(value: sdl3.video.Display.Orientation) lifecycle.Orientation {
    return switch (value) {
        .landscape => .landscape,
        .landscape_flipped => .landscape_flipped,
        .portrait => .portrait,
        .portrait_flipped => .portrait_flipped,
    };
}

/// The phase an observation lands in, which is what the consumer is told.
///
/// "About to enter the foreground" is not yet interactive, so it lands in the
/// not-scheduled phase rather than claiming the app can draw.
pub fn phaseOf(observation: lifecycle.Observation) lifecycle.Phase {
    return switch (observation) {
        .will_enter_background, .will_enter_foreground => .will_suspend,
        .did_enter_background => .background,
        .did_enter_foreground => .resumed,
        else => unreachable,
    };
}

/// The platform's own memory level, mapped onto the levels an app can act on.
///
/// A lifecycle trim level is not pressure: the header names the two running
/// levels as the actionable ones, and the background and UI-hidden levels are
/// the lifecycle phase's business, so they map to `none` instead of to a warning
/// an app would drop caches for.
pub fn pressureOf(platform: native.Platform, code: c_int) lifecycle.MemoryPressure {
    return switch (platform) {
        .ios => switch (code) {
            c.NOGUI_MOBILE_IOS_PRESSURE_WARNING => .warning,
            c.NOGUI_MOBILE_IOS_PRESSURE_CRITICAL => .critical,
            else => .none,
        },
        .android => switch (code) {
            c.NOGUI_MOBILE_ANDROID_TRIM_RUNNING_LOW => .warning,
            c.NOGUI_MOBILE_ANDROID_TRIM_RUNNING_CRITICAL => .critical,
            else => .none,
        },
        .unavailable => .none,
    };
}

/// True for the scancode the Android system's back control is delivered as.
///
/// This is the platform's own key map naming the control, not a gesture this
/// adapter invented, which is why it is one scancode rather than a recogniser.
pub fn isBackScancode(code: ?sdl3.Scancode) bool {
    const scancode = code orelse return false;
    return scancode == .ac_back;
}

/// Where a back request came from on this target.
///
/// iOS has no system back control and SDL surfaces no substitute, so the honest
/// answer there is the absence. Reporting a request on that target would mean a
/// gesture recogniser nobody asked for.
pub fn backSource(platform: native.Platform) lifecycle.BackSource {
    return switch (platform) {
        .android => .android_system_back,
        else => .unavailable,
    };
}

/// One observation, as the consumer sees it.
///
/// Bytes in `composition` and `committed` are the platform's and are valid for
/// this call only; SDL's own buffers do not outlive the next poll. A consumer
/// that needs them longer copies them.
pub const Event = union(enum) {
    /// The safe area moved. Content has to be laid out again inside the new
    /// bounds.
    safe_area: lifecycle.Insets,
    /// The keyboard reading changed.
    keyboard: lifecycle.Keyboard,
    /// The lifecycle phase moved.
    phase: lifecycle.Phase,
    /// The display rotated.
    orientation: lifecycle.Orientation,
    /// The window's logical and device-pixel extents were re-measured. A
    /// rotation and a display-scale change both land here.
    pixel_scale: PixelScale,
    /// The platform RAISED memory pressure. This arrives only in answer to a
    /// real signal, never because a frame read the level again.
    memory_signal: lifecycle.MemoryPressure,
    /// The level the platform currently holds moved. This is a reading, not a
    /// signal: it arrived because a poll saw a new value, and the number of
    /// pressure events is unchanged.
    memory_level: lifecycle.MemoryPressure,
    /// A raw contact, in window-logical units.
    touch: Touch,
    /// A pinch the platform itself recognised, with the platform's own scale.
    pinch: Pinch,
    /// The IME composition changed. Empty text ended the composition.
    composition: []const u8,
    /// Committed text arrived. Nothing edits a document from here.
    committed: []const u8,
    /// Native text input started or stopped, observed by reading the host
    /// rather than by a text event, so there are no bytes to report.
    text_input: bool,
    /// The area the shared text-input path published for the IME moved.
    candidate: [4]f32,
    /// The application's back policy answered a measured request.
    back: struct {
        request: lifecycle.BackRequest,
        decision: lifecycle.BackDecision,
    },
};

/// Where observations go.
///
/// The context must outlive the observer, and `shutdown` drops the
/// registration, so an event that arrives after teardown finds no callback to
/// enter rather than a freed one.
pub const Sink = struct {
    context: ?*anyopaque = null,
    observe: *const fn (?*anyopaque, Event) void,
};

/// The host effects this observer is allowed to perform.
///
/// Both pointers are borrowed from the host and must outlive the observer. They
/// are supplied together because every effect needs both: the frame demand
/// belongs to the window and the redraw belongs to the session.
pub const Effects = struct {
    managed: *application.ManagedWindow,
    session: *nogui.Session,
};

/// The platform effects this observer performs on the application's behalf.
///
/// There is exactly one today, and it is named rather than called inline for
/// the same reason the accessibility side names its bridge calls: the case
/// that matters is the one no desktop build can produce. Handing a back
/// request to the platform is a real operation — on Android it moves the task
/// to the background — and it is a ROUTINE one to be refused, on an activity
/// that is not its task root, or when the Java UI thread misses its two
/// second bound. A seam is what lets that outcome be produced where the
/// platform exists only in a phone.
pub const PlatformEffect = struct {
    context: ?*anyopaque = null,
    /// Hand one back request to the platform. The default succeeds without
    /// doing anything on a build with no shim: there is nothing to defer to,
    /// which is not a refusal. Every other target's refusal is an error, and
    /// the observer counts it rather than propagating it.
    defer_back: *const fn (?*anyopaque) native.Error!void = deferBackToPlatform,
};

fn deferBackToPlatform(_: ?*anyopaque) native.Error!void {
    if (!native.available) return;
    try native.deferBack();
}

pub const Observer = struct {
    /// The host's window. Borrowed: the host destroys it only after `shutdown`,
    /// which is exactly what the host's `on_before_close` hook is for.
    window: *Window,
    window_id: sdl3.video.WindowId = 0,
    /// SDL can reuse a window id while old events still wait in the queue, so
    /// an event older than the window's creation belongs to a window that is
    /// gone. Same rule and same source as the host's own stale filter.
    created_ns: u64 = 0,
    effects: ?Effects = null,
    /// The platform effects. Replaced by a host that owns its own, and by a
    /// test that needs the platform to refuse where it does not exist.
    platform: PlatformEffect = .{},
    sink: ?Sink = null,
    /// The application's back policy. Without one a back request is measured
    /// and reported and then left alone, because the adapter never invents a
    /// window close the app did not ask for.
    back: ?lifecycle.BackDecider = null,
    /// Set by `shutdown`. A closed observer consumes nothing and calls nobody.
    closed: bool = false,
    machine: lifecycle.Machine = .{},
    scale: PixelScale = .{},
    /// Set when an event may have moved the window between extents, so the next
    /// touch sample is measured against the new size rather than the one the
    /// batch started with.
    scale_dirty: bool = true,
    // SAFETY: `len` is what gates every read of `entries`, and it starts at
    // zero, so a table nothing has been added to reads no slot at all.
    contacts: Contacts = .{ .entries = undefined },
    /// The candidate rectangle last handed to the platform, and whether a later
    /// safe-area or keyboard move has made the platform's copy wrong.
    published: ?[4]f32 = null,
    published_cursor: f32 = 0,
    candidate_invalidated: bool = false,
    /// The `Window` publication this observer has already adopted. It is
    /// compared against the window's own counter rather than against the
    /// rectangle, because a fresh layout may publish the geometry the platform
    /// already holds and that publication is still the one saying the input
    /// method belongs there. Zero is where a window starts, so an observer
    /// beside a window that never published adopts nothing.
    adopted_generation: u64 = 0,
    /// Polls the platform refused, and polls it answered with no reading. They
    /// are separate because a refusal is a fault and an absent reading is the
    /// platform saying it does not know.
    refused_polls: u32 = 0,
    unanswered_polls: u32 = 0,
    /// Back requests the platform REFUSED. Separate from the poll counters
    /// because a refusal here is not a measurement this observer chose to
    /// make: the application asked for the platform's own handling and the
    /// platform declined. It is counted and the event continues — a back on an
    /// activity that is not its task root is a routine outcome, and aborting
    /// the pump over it would drop every event already queued behind it — but
    /// it is never hidden either, so a host that sees back do nothing can read
    /// why.
    refused_defers: u32 = 0,

    pub fn init(window: *Window, effects: ?Effects) Observer {
        return .{
            .window = window,
            .window_id = window.id,
            .created_ns = if (effects) |target| target.managed.created_ns else 0,
            .effects = effects,
        };
    }

    /// Drop every registration. Idempotent, and a closed observer consumes
    /// nothing: `handleEvent` and `poll` return before touching the window, the
    /// host window or the session, which is what makes shutting one down from
    /// `on_before_close` safe while a batch is still in flight.
    ///
    /// The rule that makes that safe is not "each entry point checks it once".
    /// It is that EVERY function which reads a dropped field checks it itself.
    /// A batch runs several steps, and `emit` hands control to the application
    /// between them, so a host that closes the observer from its own close hook
    /// closes it in the MIDDLE of a poll: `shutdown` is re-entered from inside
    /// the sink callback, `window` becomes undefined under a batch that is still
    /// running, and the next step of that batch would read it. The platform
    /// context is dropped alongside the sink and the back policy because it is
    /// borrowed the same way: the host frees whatever it lent in the teardown
    /// that destroys the window.
    pub fn shutdown(self: *Observer) void {
        if (self.closed) return;
        self.closed = true;
        self.sink = null;
        self.back = null;
        self.effects = null;
        self.platform.context = null;
        self.contacts.clear();
        self.published = null;
        self.published_cursor = 0;
        self.candidate_invalidated = false;
        self.adopted_generation = 0;
        // SAFETY: `closed` was set above, and every function that reads a field
        // this drops — `window`, `window_id`, `effects`, `sink`, `back` and
        // `platform` — returns on it before the read. That is a per-function
        // obligation, not a property of the four public entry points, because
        // a sink callback can shut the observer down between any two of them.
        self.window = undefined;
        self.window_id = 0;
    }

    pub fn setSink(self: *Observer, sink: ?Sink) void {
        if (self.closed) return;
        self.sink = sink;
    }

    pub fn setBackPolicy(self: *Observer, policy: ?lifecycle.BackDecider) void {
        if (self.closed) return;
        self.back = policy;
    }

    pub fn state(self: *const Observer) lifecycle.Snapshot {
        return self.machine.snapshot();
    }

    pub fn liveContacts(self: *const Observer) []const Contact {
        return self.contacts.slice();
    }

    pub fn pixelScale(self: *const Observer) PixelScale {
        return self.scale;
    }

    /// True while the platform says the app is being scheduled. A frame is only
    /// worth producing then, and a poll made outside it asks a window the
    /// platform has already taken away.
    pub fn scheduled(self: *const Observer) bool {
        return self.machine.phase.isScheduled();
    }

    /// True when the platform holds a candidate rectangle that a safe-area or
    /// keyboard move has made stale.
    pub fn candidateStale(self: *const Observer) bool {
        return self.published != null and self.candidate_invalidated;
    }

    /// One batch of the host's own event pump, then one read of the platform's
    /// polled facts. Returns whether any event produced an observation.
    ///
    /// This is the integration path rather than a helper: it drives the same
    /// public `pollEvent` / `dispatch` pair every host uses, so each raw event
    /// is observed here and routed there exactly once. The host still owns the
    /// App, the session and the frame callback, and this never calls into the
    /// App.
    ///
    /// Nothing the platform declines ends the batch. The poll half of every
    /// reading folds a refusal into `refused_polls` and `unanswered_polls`,
    /// and a back the platform will not take folds one into
    /// `refused_defers`, because an error here would leave the event that
    /// raised it undispatched and drop every event already removed from SDL's
    /// queue behind it — a queued tap, a scroll and a keystroke lost to a back
    /// press on an activity that is not its task root. The events are still
    /// the host's: `handleEvent` observes and never consumes, so a back the
    /// application decided about goes on to `dispatch` like every other key.
    pub fn pump(self: *Observer, host_application: *application.Application) !bool {
        if (self.closed) return false;
        var observed = false;
        while (host_application.pollEvent()) |raw| {
            if (try self.handleEvent(&raw)) observed = true;
            _ = try host_application.dispatch(&raw);
        }
        try self.poll();
        return observed;
    }

    /// Consume one raw SDL event, exactly once. Returns whether it produced an
    /// observation for the consumer.
    ///
    /// The event is still the host's afterwards: this observes and never
    /// consumes, so a host that calls both gets the key, the text and the
    /// composition through its own path exactly once.
    pub fn handleEvent(self: *Observer, raw: *const sdl3.events.Event) !bool {
        if (self.closed) return false;
        if (self.scale_dirty) _ = self.measureScale();
        switch (raw.*) {
            inline .finger_down, .finger_motion, .finger_up, .finger_canceled => |finger| {
                if (!self.accepts(finger.common.timestamp, finger.window_id)) return false;
                const phase: ContactPhase = switch (raw.*) {
                    .finger_down => .began,
                    .finger_motion => .moved,
                    .finger_up => .ended,
                    .finger_canceled => .cancelled,
                    else => unreachable,
                };
                return self.observeTouch(finger, phase);
            },
            inline .pinch_begin, .pinch_update, .pinch_end => |pinch| {
                if (!self.accepts(pinch.common.timestamp, pinch.window_id)) return false;
                // The platform's own scale, forwarded. Nothing here decides that
                // two contacts are a pinch, because the platform already did.
                self.emit(.{ .pinch = .{
                    .phase = pinchPhaseOf(raw),
                    .scale = pinch.scale,
                } });
                return true;
            },
            .key_down => |key| {
                if (!self.accepts(key.common.timestamp, key.window_id)) return false;
                if (!isBackScancode(key.scancode)) return false;
                return self.handleBack(key.repeat);
            },
            .text_input => |text| {
                if (!self.accepts(text.common.timestamp, text.window_id)) return false;
                return self.observe(
                    .{ .committed = text.text },
                    .{ .committed = text.text },
                );
            },
            .text_editing => |edit| {
                if (!self.accepts(edit.common.timestamp, edit.window_id)) return false;
                return self.observe(
                    .{ .composition = edit.text },
                    .{ .composition = edit.text },
                );
            },
            .display_orientation => |orientation| {
                const value = orientationOf(orientation.orientation);
                return self.observe(.{ .orientation = value }, .{ .orientation = value });
            },
            .will_enter_background, .did_enter_background, .will_enter_foreground, .did_enter_foreground => {
                const observation: lifecycle.Observation = switch (raw.*) {
                    .will_enter_background => .will_enter_background,
                    .did_enter_background => .did_enter_background,
                    .will_enter_foreground => .will_enter_foreground,
                    else => .did_enter_foreground,
                };
                return self.observe(observation, .{ .phase = phaseOf(observation) });
            },
            .low_memory => {
                // A real signal. The level it raised to is read once, here, and
                // what it reads is a SIGNAL, not a poll, so it is counted once
                // however many frames go on to read the same level.
                const level = (try self.readPressure()) orelse return false;
                return self.observe(
                    .{ .memory_signal = level },
                    .{ .memory_signal = level },
                );
            },
            inline .window_resized, .window_pixel_size_changed, .window_display_scale_changed => |window_event| {
                if (!self.accepts(window_event.common.timestamp, window_event.id)) return false;
                // The window may be a different size now. The host owns the
                // geometry change; this only has to stop measuring against the
                // extents the batch started with.
                self.scale_dirty = true;
                return false;
            },
            inline .window_display_changed, .window_occluded => |window_event| {
                // An occlusion is not a size and a display change is not a
                // window fact, but either can leave this window reading against
                // extents that have moved.
                if (!self.accepts(window_event.common.timestamp, window_event.id)) return false;
                self.scale_dirty = true;
                return false;
            },
            .display_content_scale_changed, .display_current_mode_changed => {
                // A display change names no window but can still move the scale
                // this window is drawn at.
                self.scale_dirty = true;
                return false;
            },
            .window_safe_area_changed => {
                // The platform names its own safe-area signal but publishes no
                // numbers with it: only a poll reads the rectangle, and the
                // read at the end of this batch is after this event. There is
                // nothing to invalidate and no flag to set.
                return false;
            },
            else => return false,
        }
    }

    /// Re-read everything the platform answers on request, exactly once.
    ///
    /// Nothing is polled while the app is not scheduled: a suspended app is not
    /// asking the window anything, and the answer would be the value it already
    /// had.
    ///
    /// The order below is the contract, not an accident:
    ///
    ///   * The SCALE first, because every window fact is converted through it.
    ///     A safe area read against the extents the batch started with is a
    ///     safe area in the wrong units, and on Android those units are device
    ///     pixels, so the error is a silent one that no later check catches.
    ///   * Then the TEXT STATE, because a candidate rectangle is only adopted
    ///     when something is anchored to publish it.
    ///   * Then the CANDIDATE, BEFORE the safe area and the keyboard. This is
    ///     the order that makes the staleness flag honest: a rectangle adopted
    ///     here can be invalidated by the two facts read next, whereas adopting
    ///     after them would clear a flag those very facts had just set.
    ///   * Then the WINDOW FACTS, in the order safe area before keyboard, and
    ///     last the memory level, which nothing above depends on.
    ///
    /// A resume re-measures the scale on its own, so the first poll after one
    /// converts a safe area against the window the rotation produced rather
    /// than the one it replaced.
    ///
    /// Every step below re-checks `closed`: `emit` hands control to the
    /// application between them, and an application that closes its window
    /// from its own close hook closes this observer in the middle of the batch.
    pub fn poll(self: *Observer) !void {
        if (self.closed) return;
        if (!self.scheduled()) return;
        if (self.measureScale()) self.emit(.{ .pixel_scale = self.scale });
        try self.readTextInput();
        try self.adoptCandidate();
        try self.readWindowFacts();
        _ = try self.readPressureLevel();
    }

    /// Adopt the candidate rectangle the shared text-input path last handed to
    /// SDL — but only when that handover was a NEW one.
    ///
    /// The platform's own answer is deliberately not read here. SDL publishes a
    /// default rectangle before anything sets one, and a rectangle this host
    /// never published is not a layout any endpoint produced: adopting it would
    /// put an input method at a place nobody named. So the source of truth is
    /// the window's publication record, and only a successful handover writes
    /// that record.
    ///
    /// A poll that saw no new publication changes nothing at all, which is what
    /// keeps a stale rectangle stale. Correcting it by replaying the geometry
    /// the platform already holds would clear the flag without a layout ever
    /// running, and the flag is the only thing saying the platform's copy is
    /// wrong. The layout a safe-area or keyboard move demands is what
    /// republishes, and that republication is what retires the flag.
    fn adoptCandidate(self: *Observer) !void {
        if (self.closed) return;
        const publication = self.window.candidate_publication;
        if (publication.generation == self.adopted_generation) return;
        // Nothing is anchored while text input is down, so the publication is
        // left unadopted rather than recorded: the rectangle is still owed the
        // moment input starts again.
        if (!self.machine.text.active) return;
        self.adopted_generation = publication.generation;
        const area = publication.area;
        const rect = [4]f32{ area.x, area.y, area.x + area.w, area.y + area.h };
        self.published = rect;
        // The caret offset travels with the rectangle, so it is adopted whole:
        // dropping it here would anchor the input method to the left edge of
        // the line box.
        self.published_cursor = publication.cursor;
        self.candidate_invalidated = false;
        _ = try self.observe(.{ .candidate = rect }, .{ .candidate = rect });
    }

    /// Re-read the window's logical and device-pixel extents. Returns whether
    /// they changed.
    ///
    /// Both come from the window itself. A display's DPI is never consulted: SDL
    /// derives its pixel scale from the density, so applying density again here
    /// would scale every coordinate twice.
    fn measureScale(self: *Observer) bool {
        if (self.closed) return false;
        self.scale_dirty = false;
        const logical = self.window.logicalSize() catch return false;
        const pixels = self.window.pixelExtent() catch return false;
        const next: PixelScale = .{
            .logical = .{ logical.width, logical.height },
            .pixels = .{ @floatFromInt(pixels.width), @floatFromInt(pixels.height) },
            .measured = true,
        };
        if (std.meta.eql(self.scale, next)) return false;
        self.scale = next;
        return true;
    }

    /// The window's logical size in the units SDL reports input in. A window
    /// that will not answer falls back to the last size measured off it, and a
    /// window that never measured one reports zeroes — which is why `measured`
    /// exists on `PixelScale` rather than being left implicit in a 1:1 default.
    fn logicalSize(self: *Observer) [2]f32 {
        if (self.closed) return .{ 0, 0 };
        const size = self.window.logicalSize() catch {
            if (self.scale.measured) return self.scale.logical;
            return .{ 0, 0 };
        };
        return .{ size.width, size.height };
    }

    fn observeTouch(self: *Observer, finger: sdl3.events.TouchFinger, phase: ContactPhase) !bool {
        if (self.closed) return false;
        const touch = measureTouch(finger, phase, self.logicalSize());
        switch (phase) {
            .began => self.contacts.begin(.{
                .contact = touch.contact,
                .device = touch.device,
                .finger = touch.finger,
                .position = touch.position,
                .pressure = touch.pressure,
                .started_ns = finger.common.timestamp,
            }),
            .moved => _ = self.contacts.move(touch.contact, touch.position, touch.pressure),
            .ended, .cancelled => _ = self.contacts.end(touch.contact),
        }
        self.emit(.{ .touch = touch });
        return true;
    }

    /// Android's back control, handled as a request and not as an event.
    ///
    /// A key repeat is the user holding the control down, not a second request,
    /// so it is dropped rather than answered twice. The decision is the app's:
    /// the adapter reports the measured facts and applies only the effects the
    /// app asked for.
    fn handleBack(self: *Observer, repeat: bool) !bool {
        if (self.closed) return false;
        if (repeat) return false;
        const request = self.machine.backRequest(backSource(native.platform));
        const policy = self.back orelse {
            // No policy is not a decision. The request is still measured and
            // reported, and the platform is left with the key it owns, because
            // the adapter never guesses that a back means closing a window.
            self.emit(.{ .back = .{ .request = request, .decision = .defer_to_platform } });
            self.deferToPlatform();
            return true;
        };
        const decision = policy.decide(policy.context, request);
        self.emit(.{ .back = .{ .request = request, .decision = decision } });
        switch (decision) {
            // `.handled` and `.defer_to_platform` do NOT consume the raw event
            // out of the shared dispatch that follows, and that is a policy
            // rather than an oversight. This observer observes: the same key
            // reaches the host's own input path exactly once either way, and a
            // second path that swallowed it would leave an application unable
            // to bind the system back control at all. What the decision DOES
            // decide is what the PLATFORM is asked to do about it, which is
            // why only these two arms reach `deferToPlatform` and `.handled`
            // reaches none of it. Closing a window is never one of them: on
            // the other platform there is no such gesture at all.
            .handled => {},
            .dismiss_keyboard => try self.dismissKeyboard(),
            .defer_to_platform => self.deferToPlatform(),
            .ignored => if (self.effects) |target| target.managed.requestPresentation(),
        }
        return true;
    }

    /// Take the keyboard down through the host's own text-input call. It is the
    /// same call the shared text-input path makes when focus leaves a field, so
    /// the platform sees one teardown rather than a dismissal the app would then
    /// have to reconcile.
    fn dismissKeyboard(self: *Observer) !void {
        if (self.closed) return;
        const target = self.effects orelse return;
        try target.managed.native.stopTextInput();
    }

    /// Hand a back request to the platform the way the platform would have
    /// handled it itself. A build with no platform to ask has nothing to defer
    /// to and says so by doing nothing, which is not a refusal and is not
    /// counted.
    ///
    /// A platform that REFUSES is counted and the event ends anyway. It has
    /// to be: the refusal is routine — Android declines `moveTaskToBack(true)`
    /// on any activity that is not its task root, and times out on a busy UI
    /// thread — and this call sits inside the pump's event loop, where an
    /// error would abandon the current event's dispatch and every event still
    /// queued behind it. That is the module's existing convention for a
    /// platform that will not answer (`readWindowFacts`, `readPressure`), and
    /// `refused_defers` is its observable: a host whose back presses do
    /// nothing can read how many the platform declined.
    fn deferToPlatform(self: *Observer) void {
        if (self.closed) return;
        self.platform.defer_back(self.platform.context) catch {
            self.refused_defers += 1;
            return;
        };
    }

    /// Install the platform effects. A host with no shim of its own keeps the
    /// default; a host that drives a real platform, or a test that needs the
    /// platform to refuse, replaces it.
    pub fn setPlatformEffect(self: *Observer, effect: PlatformEffect) void {
        if (self.closed) return;
        self.platform = effect;
    }

    fn readTextInput(self: *Observer) !void {
        if (self.closed) return;
        const active = self.window.textInputActive();
        if (active == self.machine.text.active) return;
        _ = try self.observe(
            .{ .text_input_active = active },
            .{ .text_input = active },
        );
    }

    /// Read the safe area and the keyboard the platform measured.
    fn readWindowFacts(self: *Observer) !void {
        if (self.closed) return;
        if (!native.available) return;
        const facts = native.pollWindow(self.window.sdl) catch {
            // A wrong thread, a fault or a window that is already gone is not a
            // measurement. Nothing is recorded, the last real reading stands,
            // and the next poll asks again.
            self.refused_polls += 1;
            return;
        };
        const space = unitSpace(native.platform);
        if (facts.insets) |insets| {
            const near = self.scale.toLogical(
                .{ narrow(insets.left), narrow(insets.top) },
                space,
            );
            const far = self.scale.toLogical(
                .{ narrow(insets.right), narrow(insets.bottom) },
                space,
            );
            const safe_area: lifecycle.Insets = .{
                .top = near[1],
                .left = near[0],
                .bottom = far[1],
                .right = far[0],
            };
            _ = try self.observe(
                .{ .safe_area = safe_area },
                .{ .safe_area = safe_area },
            );
        } else {
            // Four zeroes are a measured answer and a reading the platform
            // refused is not, so an unreadable poll must never become one.
            self.unanswered_polls += 1;
        }
        // An unanswerable keyboard question is itself an observation. Without
        // it the machine would keep the last real reading, and a back request
        // would then report a measurably-down keyboard where nobody looked.
        const unmeasured = lifecycle.Keyboard.reading(.unknown, false, null);
        const keyboard = facts.keyboard orelse {
            self.unanswered_polls += 1;
            _ = try self.observe(
                .{ .keyboard = unmeasured },
                .{ .keyboard = unmeasured },
            );
            return;
        };
        const support: lifecycle.KeyboardSupport = if (keyboard.supported != 0)
            .present
        else
            .absent;
        const visible = keyboard.visible != 0;
        const reading = lifecycle.Keyboard.reading(
            support,
            visible,
            if (visible) self.scale.rectToLogical(keyboard.frame, space) else null,
        );
        _ = try self.observe(.{ .keyboard = reading }, .{ .keyboard = reading });
    }

    /// The level the platform currently holds, read without counting an event.
    ///
    /// A poll is a reading, not a thing that happened. Counting it would make
    /// the number of pressure events a function of the frame rate.
    fn readPressureLevel(self: *Observer) !bool {
        const level = (try self.readPressure()) orelse return false;
        return self.observe(.{ .memory_level = level }, .{ .memory_level = level });
    }

    /// The platform's last level code, or null when this target has no shim.
    fn readPressure(self: *Observer) !?lifecycle.MemoryPressure {
        if (!native.available) return null;
        const code: ?c_int = native.memoryPressureCode() catch blk: {
            self.refused_polls += 1;
            break :blk null;
        };
        const measured = code orelse return null;
        return pressureOf(native.platform, measured);
    }

    /// Record one platform fact and report it. Returns whether anything
    /// changed: a reading identical to the one already held is not an event, and
    /// reporting it again would make a poll of a steady platform look like
    /// activity.
    fn observe(self: *Observer, observation: lifecycle.Observation, event: Event) !bool {
        if (self.closed) return false;
        const change = self.machine.observe(observation) orelse return false;
        try self.publish(change, event);
        return true;
    }

    /// Route one machine change into the host, then report it. The host effects
    /// are keyed off the change and the report is the caller's, because the two
    /// are not always the same fact: a polled level and a raised signal are one
    /// change each, and a consumer has to be able to tell them apart.
    ///
    /// A suspend is a keyboard move too, and it takes the composition with it.
    /// The machine has already cleared both by the time this runs, so the
    /// rectangle the platform was told about describes an input method on a
    /// window that is not on the screen: the next layout owes a new
    /// publication, and without this the flag would keep saying the platform's
    /// copy is right.
    ///
    /// `.will_suspend` deliberately does NOT invalidate. The window is still
    /// on the screen with the keyboard still up, so the rectangle is still the
    /// right one and a republication would be pure cost.
    fn publish(self: *Observer, change: lifecycle.Change, event: Event) !void {
        if (self.closed) return;
        switch (change) {
            .safe_area => {
                self.invalidateCandidate();
                try self.relayout();
            },
            .keyboard => {
                self.invalidateCandidate();
                try self.relayout();
            },
            .phase => |phase| {
                // Contacts belong to the interaction that is happening now. A
                // suspend takes the window out from under every finger on it.
                if (!phase.isScheduled()) self.contacts.clear();

                // The window is off the screen now, so the rectangle the
                // platform holds names a place that no longer exists. This is
                // the same fact `.safe_area` and `.keyboard` record, reached by
                // the phase instead of by a measurement, because nothing is
                // measured while the app is unscheduled.
                if (phase == .background) self.invalidateCandidate();

                if (phase == .resumed) {
                    // A resume re-reads the compositor and re-arms the session
                    // redraw through the host's own path, because a model update
                    // coalesced before the suspend has already been consumed by
                    // the pre-resume pump.
                    if (self.effects) |target| {
                        try target.managed.resumeDemand(target.session);
                    }
                    self.scale_dirty = true;
                }
            },
            else => {},
        }
        self.emit(event);
    }

    /// The safe area and the keyboard both move what the platform was told, and
    /// the platform keeps the old rectangle until somebody publishes a new one.
    fn invalidateCandidate(self: *Observer) void {
        if (self.published == null) return;
        self.candidate_invalidated = true;
    }

    /// A mobile safe area or keyboard move is a layout change like any other, so
    /// it goes through the same demand and the same session redraw a resize uses
    /// rather than through a path of its own.
    fn relayout(self: *Observer) !void {
        if (self.closed) return;
        const target = self.effects orelse return;
        target.managed.demand.invalidateLayout();
        target.session.requestRedraw(target.managed.app.window) catch |err| switch (err) {
            // A window the session has already retired refuses a redraw. The
            // demand above still stands and the window is on its way out, so
            // this is the one refusal that is not a failure to report. The
            // switch names it exhaustively on purpose: a refusal this host
            // cannot explain has to be a deliberate addition here, not an
            // `else` that carries every future error out of the pump.
            error.UnknownWindow => {},
        };
    }

    fn emit(self: *Observer, event: Event) void {
        if (self.closed) return;
        const sink = self.sink orelse return;
        sink.observe(sink.context, event);
    }

    /// True when this event is this observer's and still current. The rules are
    /// the host's own: SDL reports a null input window for a device with no
    /// single focus and the host resolves that the same way, and an event older
    /// than the window's creation belongs to a window SDL has since replaced.
    fn accepts(self: *const Observer, timestamp: u64, id: ?sdl3.video.WindowId) bool {
        if (self.closed) return false;
        if (id) |target| {
            if (target != self.window_id) return false;
        }
        return timestamp >= self.created_ns;
    }
};

fn testFinger(id: u32, finger_id: u32) sdl3.events.TouchFinger {
    return .{
        .common = .{ .timestamp = 0 },
        .id = .{ .value = id },
        .finger_id = .{ .value = finger_id },
        .x = 0.25,
        .y = 0.75,
        .dx = 0.1,
        .dy = -0.2,
        .pressure = 0.5,
        .window_id = 1,
    };
}

test "api-w23 mobile points need no pixel scale and pixels need the measured one" {
    // A retina iOS window: the logical space SDL reports input in is points,
    // and the device pixels are twice them.
    const points: PixelScale = .{
        .logical = .{ 390, 844 },
        .pixels = .{ 780, 1688 },
        .measured = true,
    };
    const scale = points.factor().?;
    try std.testing.expectEqual(@as(f32, 2), scale.x);
    try std.testing.expectEqual(@as(f32, 2), scale.y);

    // A point reading is already in the logical space. Dividing it by the pixel
    // scale would move the safe area of a 390-point phone to 195 points.
    try std.testing.expectEqual([2]f32{ 47, 0 }, points.toLogical(.{ 47, 0 }, .logical_points));
    try std.testing.expectEqual([2]f32{ 780, 1688 }, points.toLogical(.{ 780, 1688 }, .logical_points));

    // The same window reporting in device pixels divides by the same measured
    // scale and lands on the same logical rectangle the point reading does.
    const converted = points.rectToLogical(
        .{ .x0 = 94, .y0 = 0, .x1 = 780, .y1 = 1688 },
        .device_pixels,
    );
    try std.testing.expectEqual([4]f32{ 47, 0, 390, 844 }, converted);
    try std.testing.expectEqual(converted, points.rectToLogical(
        .{ .x0 = 47, .y0 = 0, .x1 = 390, .y1 = 844 },
        .logical_points,
    ));
}

test "api-w23 mobile an unmeasured window reports no scale rather than a 1:1 one" {
    // Before anything has been read off a live window there is no scale, and the
    // answer has to be that rather than a factor of one: a 1:1 claim would
    // place a safe area at the device-pixel offset the window does not use.
    const unmeasured: PixelScale = .{};
    try std.testing.expect(!unmeasured.measured);
    try std.testing.expect(unmeasured.factor() == null);
    // A device-pixel reading with no scale to divide by is passed through, and
    // the observer counts the poll as unanswered rather than inventing an answer
    // here.
    try std.testing.expectEqual([2]f32{ 94, 68 }, unmeasured.toLogical(.{ 94, 68 }, .device_pixels));

    // A window reporting a zero extent has no scale at all, on either axis. A
    // collapsed window is a platform state, and treating half of it as a real
    // scale would convert one coordinate and not the other.
    const collapsed: PixelScale = .{ .logical = .{ 0, 0 }, .pixels = .{ 0, 0 }, .measured = true };
    try std.testing.expect(collapsed.factor() == null);
    try std.testing.expectEqual([2]f32{ 94, 68 }, collapsed.toLogical(.{ 94, 68 }, .device_pixels));

    // A pixel count that crossed as a float and no longer fits an unsigned
    // extent has no scale either. Truncating it would wrap to zero and report a
    // scale of infinity, which is not a measurement of anything.
    const wrapped: PixelScale = .{ .logical = .{ 400, 800 }, .pixels = .{ 1e30, 1e30 }, .measured = true };
    try std.testing.expect(wrapped.factor() == null);
    const not_finite: PixelScale = .{
        .logical = .{ 400, 800 },
        .pixels = .{ std.math.nan(f32), 800 },
        .measured = true,
    };
    try std.testing.expect(not_finite.factor() == null);
}

test "api-w23 mobile each platform's facts are converted from its own unit" {
    // UIKit measures a window in points and SDL reports iOS geometry in points,
    // so no conversion is the correct conversion there.
    try std.testing.expectEqual(UnitSpace.logical_points, unitSpace(.ios));
    // An Android window fact is a device pixel, and the host divides it by the
    // window's own pixel scale rather than by a display density.
    try std.testing.expectEqual(UnitSpace.device_pixels, unitSpace(.android));
    // A target with no shim has no facts, so it reports the space the host
    // already works in instead of a refusal every caller has to catch.
    try std.testing.expectEqual(UnitSpace.logical_points, unitSpace(.unavailable));
}

test "api-w23 mobile memory levels map only the actionable trim levels" {
    // iOS publishes three levels, and both non-trivial ones are pressure.
    try std.testing.expectEqual(
        lifecycle.MemoryPressure.warning,
        pressureOf(.ios, c.NOGUI_MOBILE_IOS_PRESSURE_WARNING),
    );
    try std.testing.expectEqual(
        lifecycle.MemoryPressure.critical,
        pressureOf(.ios, c.NOGUI_MOBILE_IOS_PRESSURE_CRITICAL),
    );
    try std.testing.expectEqual(
        lifecycle.MemoryPressure.none,
        pressureOf(.ios, c.NOGUI_MOBILE_IOS_PRESSURE_NONE),
    );

    // Android's lifecycle levels are the phase's business, not pressure. An app
    // that dropped caches for a background trim would be dropping them for its
    // own suspension, which is the opposite of what the level means.
    try std.testing.expectEqual(
        lifecycle.MemoryPressure.warning,
        pressureOf(.android, c.NOGUI_MOBILE_ANDROID_TRIM_RUNNING_LOW),
    );
    try std.testing.expectEqual(
        lifecycle.MemoryPressure.critical,
        pressureOf(.android, c.NOGUI_MOBILE_ANDROID_TRIM_RUNNING_CRITICAL),
    );
    for ([_]c_int{
        c.NOGUI_MOBILE_ANDROID_TRIM_NONE,
        c.NOGUI_MOBILE_ANDROID_TRIM_BACKGROUND,
        c.NOGUI_MOBILE_ANDROID_TRIM_UI_HIDDEN,
        c.NOGUI_MOBILE_ANDROID_TRIM_COMPLETE,
    }) |code| {
        try std.testing.expectEqual(lifecycle.MemoryPressure.none, pressureOf(.android, code));
    }

    // A target with no shim has published no level at all, which is not a
    // warning.
    try std.testing.expectEqual(
        lifecycle.MemoryPressure.none,
        pressureOf(.unavailable, c.NOGUI_MOBILE_IOS_PRESSURE_CRITICAL),
    );
}

test "api-w23 mobile a back control is the platform's own key map and nothing else" {
    // Android's system back arrives as the scancode the platform's key map
    // defines. Any other key is an ordinary key the host routes as usual.
    try std.testing.expect(isBackScancode(.ac_back));
    try std.testing.expect(!isBackScancode(.escape));
    try std.testing.expect(!isBackScancode(null));

    // iOS has no system back control and SDL surfaces no substitute, so a
    // request there would be a gesture recogniser nobody asked for.
    try std.testing.expectEqual(
        lifecycle.BackSource.android_system_back,
        backSource(.android),
    );
    try std.testing.expectEqual(lifecycle.BackSource.unavailable, backSource(.ios));
    try std.testing.expectEqual(lifecycle.BackSource.unavailable, backSource(.unavailable));
}

test "api-w23 mobile a raw contact keeps its finger identity and measured position" {
    const logical: [2]f32 = .{ 400, 800 };
    const first = measureTouch(testFinger(7, 42), .began, logical);
    // The device and the finger are separate facts, and folding them the way the
    // core folds them is what lets a consumer match this sample with the core
    // event the host routed from the same finger.
    try std.testing.expectEqual((@as(u128, 7) << 64) | 42, first.contact);
    try std.testing.expectEqual(@as(u64, 7), first.device);
    try std.testing.expectEqual(@as(u64, 42), first.finger);
    // Normalised platform coordinates become window-logical ones, from the
    // window's own extent and not from a display's density.
    try std.testing.expectEqual([2]f32{ 100, 600 }, first.position);
    try std.testing.expectEqual([2]f32{ 40, -160 }, first.movement);
    try std.testing.expectEqual(@as(f32, 0.5), first.pressure);

    // A second finger on the same device is a different contact, and the same
    // finger on another device is a different contact too.
    const second = measureTouch(testFinger(7, 43), .began, logical);
    const other = measureTouch(testFinger(8, 42), .began, logical);
    try std.testing.expect(first.contact != second.contact);
    try std.testing.expect(first.contact != other.contact);

    // The platform taking a contact away is not the user lifting it, and a
    // consumer that cancels a fling on one and not the other would be wrong.
    try std.testing.expectEqual(
        ContactPhase.cancelled,
        measureTouch(testFinger(7, 42), .cancelled, logical).phase,
    );
}

test "api-w23 mobile contacts are bounded, refused visibly, and never merged" {
    // SAFETY: `len` starts at zero, so `begin` writes the slot before any
    // reader can look at one and the rest of the table is never observed.
    var contacts: Contacts = .{ .entries = undefined };
    for (0..max_contacts) |index| {
        contacts.begin(.{
            .contact = @intCast(index + 1),
            .device = 1,
            .finger = @intCast(index + 1),
            .position = .{ @floatFromInt(index), 0 },
            .pressure = 1,
            .started_ns = 0,
        });
    }
    try std.testing.expectEqual(max_contacts, contacts.count());
    try std.testing.expectEqual(@as(u32, 0), contacts.refused);

    // One finger past the table. It is refused and counted rather than merged
    // into a live entry, because a merged entry is a contact that never existed
    // and a gesture recogniser would see it.
    contacts.begin(.{
        .contact = 999,
        .device = 1,
        .finger = 999,
        .position = .{ 0, 0 },
        .pressure = 1,
        .started_ns = 0,
    });
    try std.testing.expectEqual(max_contacts, contacts.count());
    try std.testing.expectEqual(@as(u32, 1), contacts.refused);
    try std.testing.expect(contacts.get(999) == null);

    // A contact that is already tracked moves rather than starting twice: the
    // platform sends a down before every stream of motion samples.
    try std.testing.expect(contacts.move(1, .{ 5, 6 }, 0.25));
    try std.testing.expectEqual([2]f32{ 5, 6 }, contacts.get(1).?.position);
    try std.testing.expectEqual(max_contacts, contacts.count());
    try std.testing.expectEqual(@as(f32, 0.25), contacts.get(1).?.pressure);

    // A sample for a contact nothing is tracking has no beginning, so it is
    // counted and does not create one.
    try std.testing.expect(!contacts.move(4242, .{ 1, 1 }, 1));
    try std.testing.expectEqual(max_contacts, contacts.count());
    try std.testing.expectEqual(@as(u32, 2), contacts.refused);

    // Lifting a contact frees its slot, and a suspend clears the rest.
    try std.testing.expect(contacts.end(1));
    try std.testing.expect(!contacts.end(1));
    try std.testing.expectEqual(max_contacts - 1, contacts.count());
    contacts.clear();
    try std.testing.expectEqual(@as(usize, 0), contacts.count());
}

test "api-w23 mobile every display orientation the platform names is mapped" {
    // All four named orientations are distinct, and a repeat is not a new
    // orientation.
    const mapped = [_]lifecycle.Orientation{
        orientationOf(.landscape),
        orientationOf(.landscape_flipped),
        orientationOf(.portrait),
        orientationOf(.portrait_flipped),
    };
    for (mapped, 0..) |value, index| {
        for (mapped[0..index]) |other| try std.testing.expect(value != other);
    }
    try std.testing.expect(mapped[2].isPortrait());
    try std.testing.expect(mapped[3].isPortrait());
    try std.testing.expect(!mapped[0].isPortrait());
    try std.testing.expect(!mapped[1].isPortrait());
}

test "api-w23 mobile a resume and an about-to-resume are not the same phase" {
    // Four distinct answers, and only the last one claims the app can draw.
    try std.testing.expectEqual(
        lifecycle.Phase.will_suspend,
        phaseOf(.will_enter_foreground),
    );
    try std.testing.expectEqual(lifecycle.Phase.resumed, phaseOf(.did_enter_foreground));
    try std.testing.expectEqual(lifecycle.Phase.will_suspend, phaseOf(.will_enter_background));
    try std.testing.expectEqual(lifecycle.Phase.background, phaseOf(.did_enter_background));
    try std.testing.expect(phaseOf(.did_enter_foreground).isScheduled());
    try std.testing.expect(!phaseOf(.will_enter_foreground).isScheduled());
}

test "api-w23 mobile a pinch is the platform's own and keeps its own scale" {
    const begin: sdl3.events.Event = .{ .pinch_begin = .{
        .common = .{ .timestamp = 0 },
        .scale = 1.25,
        .window_id = 1,
    } };
    const update: sdl3.events.Event = .{ .pinch_update = begin.pinch_begin };
    const end: sdl3.events.Event = .{ .pinch_end = begin.pinch_begin };

    // Three distinct parts of one gesture. A consumer that treats the end as
    // another update would apply the last scale twice.
    try std.testing.expectEqual(PinchPhase.began, pinchPhaseOf(&begin));
    try std.testing.expectEqual(PinchPhase.updated, pinchPhaseOf(&update));
    try std.testing.expectEqual(PinchPhase.ended, pinchPhaseOf(&end));
    // The scale is the platform's measurement, carried through untouched.
    try std.testing.expectEqual(@as(f32, 1.25), begin.pinch_begin.scale);
}

/// A platform stand-in that counts the calls it was asked to make and then
/// refuses, which is what Android does to a deferral from an activity that is
/// not its task root. Counting is the whole point: a call this test cannot see
/// is a call the real platform would have made.
fn testDeferBack(context: ?*anyopaque) native.Error!void {
    const calls: *u32 = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return error.NativeRefused;
}

/// A sink that counts what the consumer was told.
fn countEvents(context: ?*anyopaque, _: Event) void {
    const calls: *u32 = @ptrCast(@alignCast(context.?));
    calls.* += 1;
}

test "api-w23 mobile a closed observer reaches neither the window nor the platform" {
    // SAFETY: nothing below dereferences the storage. Every call is one a
    // closed observer has to refuse, and the counters are what prove it
    // refused rather than merely having nothing interesting to do.
    var storage: Window = undefined;
    var observer: Observer = .{ .window = &storage };
    var sink_calls: u32 = 0;
    var platform_calls: u32 = 0;
    observer.setSink(.{ .context = &sink_calls, .observe = countEvents });
    observer.setPlatformEffect(.{
        .context = &platform_calls,
        .defer_back = testDeferBack,
    });

    observer.shutdown();
    try std.testing.expect(observer.closed);

    // Teardown drops every registration, the platform's context included. The
    // host lends the observer a window, a session and these two callbacks and
    // frees all of them in the same teardown, so a context left behind is a
    // pointer into freed memory rather than a stale but valid one.
    try std.testing.expect(observer.sink == null);
    try std.testing.expect(observer.back == null);
    try std.testing.expect(observer.effects == null);
    try std.testing.expect(observer.platform.context == null);

    // Everything the pump reaches after the latch. `poll` would ask the window
    // for its size, its text-input state and its safe area; `handleBack` would
    // hand a request to the platform; `relayout` would touch the session.
    const pinch: sdl3.events.Event = .{ .pinch_begin = .{
        .common = .{ .timestamp = 0 },
        .scale = 1,
        .window_id = 1,
    } };
    try observer.poll();
    try std.testing.expect(!try observer.handleEvent(&pinch));
    try std.testing.expect(!try observer.observeTouch(testFinger(1, 1), .began));
    try std.testing.expect(!try observer.handleBack(false));
    try std.testing.expect(!observer.measureScale());
    try std.testing.expectEqual([2]f32{ 0, 0 }, observer.logicalSize());
    try observer.readTextInput();
    try observer.readWindowFacts();
    // `deferToPlatform` returns void on purpose: a refusal is counted in
    // `refused_defers` instead of raised, so it can never abandon the dispatch
    // of the event that asked. Calling it must not be wrapped in `try`.
    observer.deferToPlatform();
    try observer.dismissKeyboard();
    try observer.relayout();

    // Not one of them asked the platform anything, reported anything, or
    // recorded a refusal it did not receive.
    try std.testing.expectEqual(@as(u32, 0), platform_calls);
    try std.testing.expectEqual(@as(u32, 0), sink_calls);
    try std.testing.expectEqual(@as(u32, 0), observer.refused_defers);
    try std.testing.expectEqual(@as(u32, 0), observer.refused_polls);
    try std.testing.expectEqual(@as(u32, 0), observer.unanswered_polls);
    try std.testing.expectEqual(@as(usize, 0), observer.liveContacts().len);
}

test "api-w23 mobile a back request cannot defer to the platform after the sink closed" {
    // SAFETY: `handleBack` measures the machine and calls the policy, the sink
    // and the platform effect. None of them touches the storage.
    var storage: Window = undefined;
    var observer: Observer = .{ .window = &storage };
    var platform_calls: u32 = 0;
    const Hooks = struct {
        observer: *Observer,
        reported: u32 = 0,
        request: ?lifecycle.BackRequest = null,

        fn observe(context: ?*anyopaque, event: Event) void {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.reported += 1;
            switch (event) {
                .back => |back| self.request = back.request,
                else => {},
            }
        }

        /// The application's own answer, which on this target is to leave the
        /// request to the platform — and which closes the window first, exactly
        /// as a close hook reached from inside the event pump does.
        fn decide(context: ?*anyopaque, request: lifecycle.BackRequest) lifecycle.BackDecision {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.request = request;
            self.observer.shutdown();
            return .defer_to_platform;
        }
    };
    var hooks: Hooks = .{ .observer = &observer };
    observer.setSink(.{ .context = &hooks, .observe = Hooks.observe });
    observer.setPlatformEffect(.{
        .context = &platform_calls,
        .defer_back = testDeferBack,
    });
    observer.setBackPolicy(.{ .context = &hooks, .decide = Hooks.decide });

    // The request was measured, and the policy ran. Nothing else follows: the
    // consumer is no longer registered, so it is not told, and the platform is
    // not asked. Handing it a back request after the host tore the window down
    // is a call into a window that is already gone, and on Android it moves a
    // task that no longer exists.
    try std.testing.expect(try observer.handleBack(false));
    try std.testing.expectEqual(backSource(native.platform), hooks.request.?.source);
    try std.testing.expect(observer.closed);
    try std.testing.expectEqual(@as(u32, 0), hooks.reported);
    try std.testing.expectEqual(@as(u32, 0), platform_calls);
    try std.testing.expectEqual(@as(u32, 0), observer.refused_defers);
}

test "api-w23 mobile leaving the screen retires the rectangle it published" {
    // SAFETY: `publish` touches the contacts table, the published rectangle
    // and the effects, all of which are this observer's own or empty.
    var storage: Window = undefined;
    var observer: Observer = .{ .window = &storage };

    const caret = [4]f32{ 12, 700, 12, 736 };
    observer.published = caret;
    observer.contacts.begin(.{
        .contact = 7,
        .device = 1,
        .finger = 7,
        .position = .{ 1, 2 },
        .pressure = 1,
        .started_ns = 0,
    });
    try std.testing.expect(!observer.candidateStale());
    try std.testing.expectEqual(@as(usize, 1), observer.liveContacts().len);

    // "About to suspend" leaves the window on the screen with the keyboard
    // still up, so the rectangle the platform holds is still the right one and
    // no republication is owed. The contacts still go: a finger on the way up
    // is not a finger the next foreground belongs to.
    try observer.publish(.{ .phase = .will_suspend }, .{ .phase = .will_suspend });
    try std.testing.expect(!observer.candidateStale());
    try std.testing.expectEqual(@as(usize, 0), observer.liveContacts().len);

    // It is off the screen now. The machine has already taken the keyboard and
    // the composition with it, so the rectangle names a place on a window the
    // platform took away, and the flag is the only thing saying so.
    try observer.publish(.{ .phase = .background }, .{ .phase = .background });
    try std.testing.expect(observer.candidateStale());

    // Nothing was ever published, so there is nothing to retire. A flag set
    // without a rectangle would send a host looking for a publication that
    // never existed.
    observer.published = null;
    observer.candidate_invalidated = false;
    try observer.publish(.{ .phase = .background }, .{ .phase = .background });
    try std.testing.expect(!observer.candidateStale());
}
