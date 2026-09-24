//! W23 E04/E05 mobile consumer — one real SDL window on a phone, the mobile
//! lifecycle observer driving it, a model-owned editable field with real focus,
//! and the mobile accessibility bridge attached to that same window.
//!
//! This is the CONSUMER half of the mobile slice. The adapters live in
//! `src/v7_host/mobile/`; nothing here reimplements one, and nothing here owns a
//! runtime, a thread, a timer or a second model. It owns an application, a
//! window, a model and a report.
//!
//! WHAT IT DRIVES, and with what
//!
//!   * Event flow. `mobile.sdl_mobile.Observer.pump` is the only thing that
//!     touches raw SDL input: it polls once, hands each raw event to the
//!     observer AND to `Application.dispatch`, exactly once each, then reads
//!     the platform's polled facts. `Application.step` follows and never polls a
//!     second time over the same event, so a key is delivered once.
//!   * Layout. `lifecycle.contentRect` turns the observed safe area into a
//!     content rectangle in WINDOW-LOGICAL units — the space SDL reports input
//!     in and the space the core lays out in — and the view lays out inside
//!     exactly that rectangle. A keyboard occlusion intersects it. No display
//!     density is applied anywhere: SDL's own logical/pixel pair is the only
//!     conversion, and it is read off the live window.
//!   * Keyboard. The soft keyboard is shown and hidden THROUGH THE FOCUSED
//!     ENDPOINT: `App.registerTextEndpoint` binds the model, and the manager's
//!     own `start`/`stop` reach SDL. The native port is wrapped by a counting
//!     trace so the run can say how many starts and stops actually happened.
//!   * Caret/candidate bounds. A safe-area or keyboard move invalidates the
//!     rectangle the platform was told; the observer says so, and this run
//!     re-measures the caret from the freshly committed layout and republishes
//!     it. Every republication is counted.
//!   * Lifecycle. Background, resume, memory signals, back, touch and pinch are
//!     read from the observer's sink, and each one changes what the application
//!     does: a suspend stops drawing, a resume re-arms the frame demand, a
//!     memory signal is counted apart from a polled level, a back request is
//!     answered by an explicit policy, and a contact is tracked as a contact.
//!   * Back policy. This application's own rule, on measured facts: a keyboard
//!     or an open composition is dismissed and the request is CONSUMED; with
//!     nothing to dismiss the request is HANDED BACK to the platform; a target
//!     with no system back control reports the request as consumed because
//!     there is nothing to hand it to. The run reports which arm ran and
//!     whether the platform refused the hand-back.
//!   * Accessibility. The semantic snapshot the App commits with each frame —
//!     built from that frame's own tree through the ordinary publisher — is
//!     handed to the mobile bridge with the window's measured scale, the bridge
//!     is attached to this window, the focused text node is bound to a real
//!     platform control where the framework needs one, and everything is
//!     detached before SDL destroys the window.
//!   * Rendering. Real noapi on a surface created over the window SDL made. A
//!     target that will not give this process a surface is a typed failure, not
//!     a fallback to fake graphics.
//!
//! WHAT IT DOES NOT CLAIM
//!
//!   * Nothing here is a substitute for running it on a device. The default
//!     mode opens no window, creates no device and asks for no permission; it
//!     prints what the target build would need and what the phases are. A
//!     desktop build refuses `--native` by name rather than emulating a phone.
//!   * A missing target SDK is reported as missing. `--native` needs the Android
//!     NDK or the iOS SDK, a device or simulator, and a Vulkan-capable driver.
//!   * No recognizer is invented. A pinch is reported because the platform
//!     recognised one; a two-finger scroll is not turned into one, and the run
//!     says which of the two it saw.
//!
//! MODES
//!
//!   --help            print this usage and exit. Touches no SDL, no provider
//!                     and no platform. Safe anywhere.
//!   (default)         probe. No window, no device, no SDL video, no permission.
//!   --native          the real run. Explicit opt-in; refuses off-target.
//!   --phase-ms N      bound on each observation phase. Default 4000.
//!   --hold-ms N       final quiet hold after the phases. Default 0.
//!
//! THE PLATFORM TEXT CONTROL, AND WHY NO OPTION NAMES IT
//!
//!   UIKit gives a screen reader no way to type into a synthetic accessibility
//!   element, so on iOS this run OWNS a real `UITextField`. It is created by
//!   src/v7_demo/w23_mobile_probe.m — a consumer-only Objective-C fixture, not
//!   a second host runtime — inside the `UIWindow` SDL already published for
//!   this window, and handed to `Adapter.bindTextInput` as the committed text
//!   node's editor. No command-line value can name it: the control is made
//!   here, owned here and released here, and an address an operator typed would
//!   be a pointer this process never allocated.
//!
//!   The probe installs no delegate and no control-event target. The shim
//!   installs its own forwarding proxy when the binding is made, so every edit
//!   that control produces reaches the model through the bridge's existing
//!   action path and nowhere else: one edit, one model, one SDL commit.
//!
//!   The control's frame follows the COMMITTED text rectangle on every safe
//!   area, keyboard and orientation move. The run reads UIKit's own geometry,
//!   native UTF-16 selection and text back out of the control, so "aligned" and
//!   "in sync" are readings rather than restatements of what was asked for. The
//!   control is released after the unbind and after the detach, and before the
//!   host destroys the window — which means the release happens INSIDE the
//!   teardown, so the ownership witness that brackets one create against one
//!   release is printed after that teardown and not before it.
//!
//!   A bound node is republished the moment the binding is made. The node's two
//!   text actions were masked while it had no editor, and the bridge gates every
//!   inbound request on the mask the last publication carried, so a legitimate
//!   edit to the control would be refused until an unrelated rotation, keyboard
//!   move or relayout happened to commit a frame.
//!
//!   A bind this target cannot make is a FAILED run. It is never downgraded to
//!   a missing option on a run that passes.
//!
//! BUILD AND PACKAGING, per target. The Zig side is one module with two extra
//! imports over the existing w12 consumer set:
//!
//!   android  -Dtarget=aarch64-linux-android  (or armeabi-v7a-linux-androideabi)
//!       target the SDL3 build for the same ABI, and the host module compiles
//!       src/v7_host/mobile/shim/nogui_android.c for it (build.zig already
//!       does this for any Android abi). Link log, android, jnigraphics and
//!       the SDL3 static library. The APK additionally needs the consumer
//!       packaging fixture in src/v7_demo/w23_mobile_packaging/: the
//!       AndroidManifest.xml, the R8 keep rules, and the activity that
//!       forwards onTrimMemory into the provider. Those are sources only; this
//!       repository builds no dex and installs no SDK.
//!   ios      -Dtarget=aarch64-macos-ios
//!       the host module compiles src/v7_host/mobile/shim/nogui_ios.m and links
//!       UIKit and Foundation. This executable compiles its own
//!       src/v7_demo/w23_mobile_probe.m with the same flags — Objective-C with
//!       ARC and blocks, "-fobjc-arc" and "-fblocks" — and links UIKit and
//!       Foundation on its own root module. The probe includes no host header
//!       and declares no host symbol, so it needs no include path and links
//!       nothing from the shim. The app bundle needs an Info.plist and no other
//!       packaging source: the bridge is created from the application's own
//!       window, so no storyboard and no accessibility entitlement is involved.
//!
//! NOT PROVEN BY ANY RUN OF THIS FILE: a screen reader actually reading the
//! tree, an input method actually composing, and a real rotation. Those need the
//! device and a person. This run reports the facts it can see and names the
//! ones it could not.
const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const noapi = @import("noapi");

const nogui = @import("nogui");
const host = @import("nogui_host");
const frame_api = @import("v7_frame");
const NativeFrame = frame_api.NativeFrame;

const Application = host.Application;
const ManagedWindow = host.ManagedWindow;
const contract = host.window_contract;
const App = nogui.App;
const Session = nogui.Session;
const WidgetId = nogui.WidgetId;
const FrameNodeId = nogui.FrameNodeId;
const ComponentKey = nogui.ComponentKey;
const geometry = nogui.geometry;
const text_input = nogui.text_input;
const Selection = text_input.Selection;
const Utf16Range = text_input.Utf16Range;

const mobile = host.mobile;
const lifecycle = mobile.lifecycle;
const sdl_mobile = mobile.sdl_mobile;
const native = mobile.native;
const mobile_a11y = mobile.accessibility;
const semantics = nogui.semantics;

const window_title: [:0]const u8 = "w23-mobile-smoke";
/// A phone-shaped window. The platform may hand back something else — this is
/// what is ASKED for, and the report prints what was observed.
const window_width: u32 = 390;
const window_height: u32 = 844;

/// Bound on one observation phase. Long enough for a person to rotate or press
/// back, short enough that an unattended run ends on time.
const default_phase_ms: u64 = 4_000;
/// The pump period. Long enough to leave the platform room, short enough that a
/// bounded wait ends on time.
const pump_ms: u64 = 8;

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = [_]u8{0} ** 4096,

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        // The buffer is reused for every line, so formatting into it is a
        // WRITE and the result borrows it.
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// The acceptance phases this consumer can observe, in the order it drives
/// them. Named once so the probe prints exactly the list the native run walks.
const phases = [_]struct { name: []const u8, needs: []const u8 }{
    .{ .name = "open", .needs = "a window and a surface this target will create" },
    .{ .name = "safe_area", .needs = "the platform describing its insets" },
    .{ .name = "focus", .needs = "the field taking focus and a keyboard answering" },
    .{ .name = "rotation", .needs = "the display rotating" },
    .{ .name = "keyboard", .needs = "a keyboard appearing and disappearing" },
    .{ .name = "background", .needs = "the app leaving and re-entering the foreground" },
    .{ .name = "back", .needs = "the platform raising a back request" },
    .{ .name = "touch", .needs = "a contact landing on the window" },
    .{ .name = "pinch", .needs = "the platform recognising a pinch" },
    .{ .name = "memory", .needs = "the platform raising a memory signal" },
    .{ .name = "semantics", .needs = "a committed tree the bridge accepts" },
    .{ .name = "teardown", .needs = "the window being closed" },
};

/// What an operator may ask of this binary.
///
/// There is no text control option and no address for one: on the target whose
/// framework cannot edit a synthetic node this run CREATES the control it
/// binds, so nothing here could name a control the process does not own.
const Options = struct {
    /// The real run. Opt-in: everything below the probe reaches a platform.
    native: bool = false,
    phase_ms: u64 = default_phase_ms,
    hold_ms: u64 = 0,

    fn usage() []const u8 {
        return
        \\usage: w23-mobile-smoke [--help] [--native] [--phase-ms N] [--hold-ms N]
        \\  --help             this usage; touches no SDL and no platform
        \\  (default)         probe: no window, no device, no SDL video
        \\  --native           drive the real mobile run on this target
        \\  --phase-ms N       bound on each observation phase (default 4000)
        \\  --hold-ms N        quiet hold after the phases (default 0)
        \\--native needs a mobile target with its SDK, a device or simulator, and
        \\a Vulkan driver. It refuses by name anywhere else.
        \\
        \\There is deliberately no option for the platform text control. This run
        \\owns it: on iOS it creates a real UITextField inside the window SDL
        \\already owns and binds that control to the committed text node, so a
        \\bind it cannot make is a failed run rather than a skipped step.
        \\
        ;
    }
};

fn parseOptions(gpa: std.mem.Allocator, init: std.process.Init, report: *Reporter) !?Options {
    var options: Options = .{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Written before anything else is touched, so `--help` needs no
            // SDL, no session, no device and no provider.
            try report.emit("{s}", .{Options.usage()});
            return null;
        } else if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--phase-ms")) {
            options.phase_ms = try std.fmt.parseInt(
                u64,
                args.next() orelse return error.MissingPhaseMs,
                10,
            );
        } else if (std.mem.eql(u8, arg, "--hold-ms")) {
            options.hold_ms = try std.fmt.parseInt(
                u64,
                args.next() orelse return error.MissingHoldMs,
                10,
            );
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    if (options.phase_ms == 0) return error.ZeroPhaseBound;
    return options;
}

// ── The platform text control ───────────────────────────

/// The consumer's OWN UIKit control, made by the Objective-C fixture in
/// `src/v7_demo/w23_mobile_probe.m`.
///
/// This is the consumer half of the iOS text-input seam and it is deliberately
/// thin: it creates one real `UITextField` inside the `UIWindow` SDL already
/// owns, keeps that control alive for as long as the binding borrows it,
/// follows the committed rectangle with its frame, and reads back what UIKit
/// actually holds. It declares no node, no tree, no request and no bridge, it
/// installs no delegate and no control-event target, and it links nothing from
/// `nogui_ios.m` — the only bridge call in this whole flow is the one
/// `Adapter.bindTextInput` already makes.
///
/// Off iOS the arm below is comptime-eliminated, so no other target references
/// a symbol that was never linked.
const probe = if (native.platform == .ios) struct {
    extern fn nogui_w23_probe_available() callconv(.c) c_int;
    extern fn nogui_w23_probe_create(
        ui_window: ?*anyopaque,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        out_input: *?*anyopaque,
    ) callconv(.c) c_int;
    extern fn nogui_w23_probe_frame(
        input: ?*anyopaque,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    ) callconv(.c) c_int;
    extern fn nogui_w23_probe_read_frame(
        input: ?*anyopaque,
        out_x: *f64,
        out_y: *f64,
        out_w: *f64,
        out_h: *f64,
    ) callconv(.c) c_int;
    extern fn nogui_w23_probe_read_selection(
        input: ?*anyopaque,
        out_start: *i64,
        out_end: *i64,
    ) callconv(.c) c_int;
    extern fn nogui_w23_probe_text_equals(
        input: ?*anyopaque,
        utf8: [*]const u8,
        len: usize,
    ) callconv(.c) c_int;
    extern fn nogui_w23_probe_release(input: ?*anyopaque) callconv(.c) c_int;
} else struct {};

/// A refusal from the probe, kept apart from the bridge's own errors so the
/// report can say which half of the seam said no.
const ProbeError = error{
    ProbeWrongThread,
    ProbeBadArgument,
    ProbeUnavailable,
    ProbeFault,
    ProbeOutOfMemory,
};

/// Turn one probe status into a typed refusal.
///
/// The codes are the ones `w23_mobile_probe.m` declares, restated here so both
/// halves of this seam are readable from one file. This is the table for a
/// CALL RESULT: 0 is success and every other value the fixture declares is a
/// refusal. A code that is not in the table is a fault, never a success: a
/// probe this binary cannot interpret has not reported that anything happened.
/// The presence answer `nogui_w23_probe_available` gives is NOT a call result
/// and does not go through here — see `probePresent`.
fn probeCheck(code: c_int) ProbeError!void {
    return switch (code) {
        0 => {},
        -1 => error.ProbeWrongThread,
        -2 => error.ProbeBadArgument,
        -3 => error.ProbeUnavailable,
        -5 => error.ProbeFault,
        -6 => error.ProbeOutOfMemory,
        else => error.ProbeFault,
    };
}

/// Is the fixture compiled into THIS binary?
///
/// `nogui_w23_probe_available` answers a different question from every other
/// entry point: 1 on a build that carries the fixture, 0 on one that does not.
/// Running it through `probeCheck` would read that 1 as a code off the result
/// table and call it a fault, which turns "the probe is here" into "the probe
/// broke" — so the presence answer has its own table here. Anything that is
/// neither 0 nor 1 is still a fault: an answer this binary cannot read has not
/// said the fixture is present.
fn probePresent(code: c_int) ProbeError!void {
    return switch (code) {
        1 => {},
        0 => error.ProbeUnavailable,
        else => error.ProbeFault,
    };
}

/// The `UIWindow` SDL published for this window — the very window the bridge
/// was attached to, read off the same `SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER`
/// property the host's own `attach` reads.
///
/// The probe parents the control there, so the control can become first
/// responder and so the control and the bridge share one parent instead of
/// living in two windows that would disagree about focus.
fn uiKitWindow(window: sdl3.video.Window) ?*anyopaque {
    if (comptime native.platform != .ios) return null;
    const properties = sdl3.c.SDL_GetWindowProperties(window.value);
    if (properties == 0) return null;
    return sdl3.c.SDL_GetPointerProperty(
        properties,
        sdl3.c.SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER,
        null,
    );
}

/// Whether the rectangle UIKit reports is the rectangle this run asked for.
///
/// The numbers cross as `f32` from the committed layout and as `double` from
/// CoreGraphics, so the tolerance below covers that one conversion and nothing
/// else: a real disagreement between the layout and the control is far larger
/// than a hundredth of a point.
fn probeFrameMatches(rect: geometry.WindowRect, x: f64, y: f64, w: f64, h: f64) bool {
    return near(rect.x, x) and near(rect.y, y) and near(rect.w, w) and near(rect.h, h);
}

fn near(want: f32, got: f64) bool {
    return @abs(@as(f64, want) - got) <= 0.01;
}

// ── The model ───────────────────────────

/// Keys of the controls this view publishes. Every one is stable, so a node
/// keeps its identity across a relayout, a rotation and a keyboard move.
const key_field: ComponentKey = .{ .static = "field" };
const key_send: ComponentKey = .{ .static = "send" };
const key_flag: ComponentKey = .{ .static = "flag" };
const key_level: ComponentKey = .{ .static = "level" };

/// The published accessible names, and the labels the annotator matches on.
/// The annotator matches on the LABEL, never on the key, so a typo in the key
/// cannot silently republish the wrong role.
const label_field = "Message";
const label_send = "Send";
const label_flag = "Urgent";
const label_level = "Volume";
const label_title = "W23 mobile";
const label_placeholder = "type a message";

/// The editable text this run owns, behind the shared text-input protocol.
///
/// It is a Session model, so the endpoint the App registers is a WEAK owner:
/// a native callback that arrives after this struct is gone finds a released
/// model and is refused, rather than reaching freed storage.
///
/// Its GEOMETRY is not invented here. `box` is the committed layout box of the
/// carrier node, copied in after every committed frame, and the caret is
/// measured inside that box against a monospace advance. That is why a safe
/// area or a keyboard move moves the published candidate rectangle: the
/// rectangle is a measurement of a real layout, not a constant.
const Field = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    /// The committed box of the carrier, in window-logical units.
    box: geometry.WindowRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// One character advance in window-logical units. A phone keyboard metric
    /// is not available from the core, so the run states the number it used
    /// rather than claiming a measurement.
    advance: f32 = 9,
    line_height: f32 = 22,
    /// Lines this field shows. A caret below them has no place to anchor a
    /// candidate rectangle, and it says so instead of publishing one.
    visible_lines: usize = 2,
    /// Every protocol edit this model accepted, counted. Byte equality alone
    /// cannot tell a commit that replaced its own preedit from a second
    /// insertion that happened to produce the same bytes.
    replacements: u32 = 0,
    marks: u32 = 0,
    erases: u32 = 0,
    moves: u32 = 0,
    /// Times the platform's own caret measurement was asked for.
    caret_reads: u32 = 0,
    /// One UTF-8 byte length per character of the live value, so the published
    /// run is addressable in the platform's character units.
    lengths: [256]u8 = [_]u8{0} ** 256,
    characters: usize = 0,

    pub fn deinit(self: *Field, _: *Session) void {
        self.text.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn slice(self: *const Field) []const u8 {
        return self.text.items;
    }

    fn byteRange(self: *const Field, range: Utf16Range) !struct { start: usize, end: usize } {
        const bytes = self.slice();
        return .{
            .start = try text_input.utf16ToUtf8(bytes, @min(range.start, range.end)),
            .end = try text_input.utf16ToUtf8(bytes, @max(range.start, range.end)),
        };
    }

    fn unitAt(self: *const Field, byte: usize) !usize {
        return text_input.utf8ToUtf16(self.slice(), byte);
    }

    fn caret(self: *const Field) !usize {
        const raw = try text_input.utf16ToUtf8(self.slice(), self.selection.cursor());
        return self.unitAt(clusterStartBefore(self.slice(), raw));
    }

    fn splice(self: *Field, start: usize, end: usize, text: []const u8) !void {
        const bytes = self.slice();
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(self.gpa);
        try next.appendSlice(self.gpa, bytes[0..start]);
        try next.appendSlice(self.gpa, text);
        try next.appendSlice(self.gpa, bytes[end..]);
        self.text.deinit(self.gpa);
        self.text = next;
    }

    /// The protocol target: an explicit range, else the marked range, else the
    /// selection. This order is the rule that stops a platform commit from
    /// duplicating the preedit it is committing.
    fn target(self: *const Field, range: ?Utf16Range) Utf16Range {
        return range orelse self.marked orelse self.selection.range;
    }

    /// One UTF-8 byte length per character of the current value.
    ///
    /// Measured from the bytes rather than assumed: a run that publishes the
    /// wrong table makes every platform offset wrong, and the platform has no
    /// way to check it.
    fn measureCharacters(self: *Field) void {
        const value = self.slice();
        const bounded = @min(value.len, self.lengths.len);
        var characters: usize = 0;
        var at: usize = 0;
        while (at < bounded) {
            const length = std.unicode.utf8ByteSequenceLength(value[at]) catch {
                // A byte that starts no codepoint is its own one-byte unit, so
                // the table still covers the whole run.
                self.lengths[characters] = 1;
                characters += 1;
                at += 1;
                continue;
            };
            const step = @min(length, bounded - at);
            self.lengths[characters] = @intCast(step);
            characters += 1;
            at += step;
        }
        self.characters = characters;
    }

    /// Whole characters that fit across `width` at this advance.
    ///
    /// A box with no width, or an advance that is not a positive number, fits
    /// exactly one: a caret at the left edge is a real place, while a column
    /// count derived from an unmeasurable box would put it anywhere.
    fn columns(self: *const Field) usize {
        if (!(self.advance > 0) or !std.math.isFinite(self.advance)) return 1;
        if (!std.math.isFinite(self.box.w) or self.box.w <= 0) return 1;
        const count = @floor(self.box.w / self.advance);
        if (!(count >= 1)) return 1;
        return @intFromFloat(count);
    }
};

fn codepointSize(bytes: []const u8, at: usize) usize {
    if (at >= bytes.len) return 1;
    return std.unicode.utf8ByteSequenceLength(bytes[at]) catch 1;
}

fn decodeAt(bytes: []const u8, at: usize) u21 {
    if (at >= bytes.len) return 0;
    const end = @min(at + codepointSize(bytes, at), bytes.len);
    return std.unicode.utf8Decode(bytes[at..end]) catch 0;
}

fn extendsCluster(value: u21) bool {
    return (value >= 0x0300 and value <= 0x036f) or value == 0x200d;
}

/// The end of the cluster that starts at `from`.
fn clusterEnd(bytes: []const u8, from: usize) usize {
    var at = from;
    while (at < bytes.len) {
        if (at > from and !extendsCluster(decodeAt(bytes, at))) break;
        at += codepointSize(bytes, at);
    }
    return at;
}

/// The start of the cluster containing byte `at`.
///
/// UTF-8 self-synchronises, so a codepoint starts at any byte that is not a
/// continuation byte; walking back to one is enough to find it. A base that is
/// itself a cluster extender keeps the walk going.
fn clusterStartBefore(bytes: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var start = @min(at, bytes.len);
    while (start > 0 and (bytes[start - 1] & 0xc0) == 0x80) start -= 1;
    while (extendsCluster(decodeAt(bytes, start))) {
        if (start == 0) return 0;
        start -= 1;
        while (start > 0 and (bytes[start - 1] & 0xc0) == 0x80) start -= 1;
    }
    return start;
}

fn isSpaceByte(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\n' or value == '\r';
}

/// The next word boundary: past the run of non-whitespace, then past the
/// whitespace that follows it.
fn wordEnd(bytes: []const u8, at: usize) usize {
    var index = at;
    while (index < bytes.len and !isSpaceByte(bytes[index])) index += codepointSize(bytes, index);
    while (index < bytes.len and isSpaceByte(bytes[index])) index += 1;
    return index;
}

fn wordStart(bytes: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var best: usize = 0;
    var index: usize = 0;
    while (index < at and index < bytes.len) {
        if (index > 0 and isSpaceByte(bytes[index]) != isSpaceByte(bytes[index - 1])) best = index;
        index += codepointSize(bytes, index);
    }
    return best;
}

fn readText(
    allocator: std.mem.Allocator,
    field: *const Field,
    _: *anyopaque,
    range: Utf16Range,
    served: *Utf16Range,
) anyerror!?[]u8 {
    const region = try field.byteRange(range);
    served.* = .{
        .start = try text_input.utf8ToUtf16(field.slice(), region.start),
        .end = try text_input.utf8ToUtf16(field.slice(), region.end),
    };
    const copy = try allocator.dupe(u8, field.slice()[region.start..region.end]);
    return copy;
}

fn readSelection(field: *const Field, _: *anyopaque) anyerror!Selection {
    return field.selection;
}

fn readMarked(field: *const Field, _: *anyopaque) anyerror!?Utf16Range {
    return field.marked;
}

fn moveCaret(field: *Field, _: *anyopaque, request: text_input.Move) anyerror!Selection {
    field.moves += 1;
    if (request.offset) |offset| {
        field.selection = .{ .range = .{ .start = offset, .end = offset } };
        return field.selection;
    }
    const bytes = field.slice();
    const forward = request.direction == .forward;
    const cursor = try field.caret();
    const at = (try field.byteRange(.{ .start = cursor, .end = cursor })).start;
    // Every arm answers in bytes and the conversion to the protocol's own unit
    // happens once, below.
    const target: usize = switch (request.unit) {
        .grapheme => if (forward)
            clusterEnd(bytes, at + codepointSize(bytes, at))
        else
            clusterStartBefore(bytes, at),
        // A word is a run of non-whitespace plus the whitespace after it. This
        // is the field's own rule, asked for only by the protocol's word
        // motion; it is not a language tokenizer.
        .word => if (forward) wordEnd(bytes, at) else wordStart(bytes, at),
        // A line is one visual line of the wrapping field, so line motion and
        // the caret geometry read the same grid.
        .line => blk: {
            const unit = try field.unitAt(at);
            const total = try text_input.utf16Length(bytes);
            const columns = field.columns();
            const line = unit / columns;
            const edge = if (forward)
                @min(total, (line + 1) * columns)
            else
                line * columns;
            break :blk try text_input.utf16ToUtf8(bytes, edge);
        },
        .document => if (forward) bytes.len else 0,
    };
    const next = try field.unitAt(target);
    const anchor = field.selection.anchor();
    field.selection = if (request.extend)
        .{
            .range = .{ .start = @min(anchor, next), .end = @max(anchor, next) },
            .reversed = next < anchor,
        }
    else
        .{ .range = .{ .start = next, .end = next } };
    return field.selection;
}

fn eraseText(field: *Field, _: *anyopaque, request: text_input.Erase) anyerror!void {
    const bytes = field.slice();
    const cursor = try field.caret();
    const at = (try field.byteRange(.{ .start = cursor, .end = cursor })).start;
    const range = if (request.extend or !field.selection.range.isEmpty())
        field.selection.range
    else if (request.backward)
        Utf16Range{ .start = try field.unitAt(clusterStartBefore(bytes, at)), .end = cursor }
    else
        Utf16Range{
            .start = cursor,
            .end = try field.unitAt(clusterEnd(bytes, at + codepointSize(bytes, at))),
        };
    const region = try field.byteRange(range);
    try field.splice(region.start, region.end, "");
    const caret = try field.unitAt(region.start);
    field.marked = null;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
    // The table the platform counts characters by is measured from the bytes
    // the model holds NOW. `SetBox.apply` states the same rule for the box, and
    // a table left over from the pre-edit bytes is a wrong platform offset for
    // every character after the one the edit moved.
    field.measureCharacters();
    field.erases += 1;
}

fn replaceText(field: *Field, _: *anyopaque, range: ?Utf16Range, text: []const u8) anyerror!void {
    const region = try field.byteRange(field.target(range));
    try field.splice(region.start, region.end, text);
    const caret = try field.unitAt(region.start + text.len);
    field.marked = null;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
    field.measureCharacters();
    field.replacements += 1;
}

fn replaceAndMark(
    field: *Field,
    _: *anyopaque,
    range: ?Utf16Range,
    text: []const u8,
    inside: ?Utf16Range,
) anyerror!void {
    const region = try field.byteRange(field.target(range));
    try field.splice(region.start, region.end, text);
    const base = try field.unitAt(region.start);
    const length = try text_input.utf16Length(text);
    field.marked = if (text.len == 0) null else Utf16Range{ .start = base, .end = base + length };
    const caret = if (inside) |value| base + @min(value.end, length) else base + length;
    field.selection = .{ .range = .{ .start = caret, .end = caret } };
    field.measureCharacters();
    field.marks += 1;
}

fn unmarkText(field: *Field, _: *anyopaque) anyerror!void {
    field.marked = null;
}

/// The caret rectangle for the end of `range`, measured inside the committed
/// box the layout gave this field.
///
/// Null above the last visible line, because a candidate rectangle anchored to
/// a caret nobody can see is worse than no rectangle at all.
fn caretGeometry(field: *Field, _: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
    field.caret_reads += 1;
    if (!(field.box.w > 0) or !(field.box.h > 0)) return null;
    const columns = field.columns();
    const line = range.end / columns;
    if (line >= field.visible_lines) return null;
    const column = range.end % columns;
    const height = @min(
        field.box.h,
        field.line_height * @as(f32, @floatFromInt(field.visible_lines)),
    );
    return .{ .area = .{
        .x = field.box.x + field.advance * @as(f32, @floatFromInt(column)),
        .y = field.box.y + field.line_height * @as(f32, @floatFromInt(line)),
        .w = 0,
        .h = height,
    }, .cursor = 0 };
}

/// The caret offset nearest a window point, so a tap places the caret through
/// the same grid the caret geometry reads.
fn indexAtPoint(field: *const Field, _: *anyopaque, point: geometry.WindowPoint) anyerror!?usize {
    if (!(field.box.w > 0)) return null;
    const columns = field.columns();
    const total = try text_input.utf16Length(field.slice());
    const row = @floor((point.y - field.box.y) / field.line_height);
    if (row < 0) return 0;
    const line: usize = @intFromFloat(row);
    const offset: f32 = @floor((point.x - field.box.x) / field.advance + 0.5);
    const column: usize = @intFromFloat(@max(offset, 0));
    return @min(line * columns + column, total);
}

fn fieldOps() text_input.Ops {
    return text_input.Adapter(Field).ops(.{
        .text = readText,
        .selection = readSelection,
        .marked = readMarked,
        .move = moveCaret,
        .erase = eraseText,
        .replace = replaceText,
        .replace_and_mark = replaceAndMark,
        .unmark = unmarkText,
        .caret = caretGeometry,
        .index_at = indexAtPoint,
    });
}

/// Copy the live model out of the Session.
///
/// `Session.create` MOVES the value it is given and leaves the caller's copy
/// undefined, so a pointer kept across the move names nothing at all. The
/// model this run edits therefore lives in the Session and is read back here,
/// into storage the caller owns for as long as it needs to look at it. Every
/// observation of this field goes through this one read, which is why a
/// painted caption, a published run and a closing report cannot describe
/// different bytes.
///
/// The BYTES move only when the model's own text counters say they did. Every
/// path that writes the value bumps one of those three: a protocol replace, a
/// protocol erase, a marked commit, and a whole-value write from a screen
/// reader. Nothing else writes them, so equal counters and an equal length
/// are the model's own answer to "is this the same text?", and a frame whose
/// value did not change copies nothing.
///
/// Every other line runs on every read. A caret that moved, a mark that
/// cleared and a re-measured character table are facts about NOW, and none of
/// them needs the bytes to have moved with them. A destination this rule is
/// applied to must therefore be filled from this one model and from nothing
/// else, or its counters would describe somebody else's edits.
fn readField(
    session: *Session,
    owner: nogui.Model(Field),
    out: *Field,
) !void {
    try session.read(Field, owner, out, struct {
        fn copy(value: *const Field, target: *Field) anyerror!void {
            const same_text = target.replacements == value.replacements and
                target.erases == value.erases and
                target.marks == value.marks and
                target.text.items.len == value.text.items.len;
            if (!same_text) {
                target.text.clearRetainingCapacity();
                try target.text.appendSlice(target.gpa, value.text.items);
            }
            target.selection = value.selection;
            target.marked = value.marked;
            target.box = value.box;
            target.advance = value.advance;
            target.line_height = value.line_height;
            target.visible_lines = value.visible_lines;
            target.lengths = value.lengths;
            target.characters = value.characters;
            target.caret_reads = value.caret_reads;
            target.replacements = value.replacements;
            target.marks = value.marks;
            target.erases = value.erases;
            target.moves = value.moves;
            target.gpa = value.gpa;
        }
    }.copy);
}

// ── The view ───────────────────────────

/// The one mounted root. It keeps no model of its own: the field it paints and
/// publishes is the Session model the text endpoint edits, read back through
/// the Session every time it is needed, so a painted caption and a published
/// run can never describe different bytes.
///
/// The content rectangle this run measured arrives here as four window-logical
/// numbers and becomes PADDING, so the layout the safe area asks for is the
/// layout the core actually produces.
const View = struct {
    app: *App,
    /// The Session the field model lives in, and the ticket that names it.
    /// `Session.create` moves the value it is given, so this pair is the only
    /// way back to the model this view draws and publishes.
    session: *Session,
    owner: nogui.Model(Field),
    /// The model as this view last read it, in TWO readbacks rather than one.
    ///
    /// The publisher copies every run it is given, so a committed snapshot
    /// reads the publisher's own bytes and never borrows these. Two slots
    /// still matter for this view: the frame being built writes the OTHER
    /// slot, so painting and annotating never move the bytes the committed
    /// frame painted from, and a frame that fails leaves both the committed
    /// publication and the readback it was drawn from exactly as the last
    /// publication left them.
    slots: [2]Field,
    /// The rectangle left for content, in window-logical units. The safe area,
    /// then intersected with any keyboard occlusion.
    content: [4]f32 = .{ 0, 0, 0, 0 },
    /// The window's own logical extent, so the insets become padding against a
    /// real window rather than against absolute numbers.
    window: [2]f32 = .{ 0, 0 },
    /// A live button, so activation has somewhere real to land.
    presses: u32 = 0,
    /// A live checkbox.
    flag: bool = false,
    /// A live slider.
    level: f32 = 40,
    /// The field carrier's node this frame, so the run can read the box the
    /// layout gave it and hand that box to the model's caret geometry.
    field_node: FrameNodeId = .root,
    // SAFETY: draw reads only status[0..status_len], which bufPrint below fills.
    status: [192]u8 = undefined,
    status_len: usize = 0,

    fn onFieldTap(self: *View, _: usize) void {
        const tree = self.app.tree_ptr orelse return;
        const id = self.app.widgetIdForKey(.root, key_field) orelse return;
        _ = self.app.focus_manager.set(tree, id, self.app.focusObserver());
    }

    fn onSend(self: *View, _: usize) void {
        self.presses += 1;
    }

    /// The model's selection in UTF-8 bytes, which is the unit the core's
    /// published run and the protocol's UTF-16 units are converted between.
    fn byteSelection(field: *const Field) ![2]usize {
        return .{
            try text_input.utf16ToUtf8(field.slice(), field.selection.anchor()),
            try text_input.utf16ToUtf8(field.slice(), field.selection.cursor()),
        };
    }

    /// Which readback the committed frame painted from, by the App's own frame
    /// counter. The counter advances only when a frame publishes, so a frame
    /// that failed left the committed publication and this slot alone.
    fn committedSlot(self: *const View) usize {
        return @intCast(self.app.frame_generation & 1);
    }

    /// The readback the last committed frame painted and published from,
    /// resolved on every use rather than captured once.
    fn committedField(self: *View) *Field {
        return &self.slots[self.committedSlot()];
    }

    /// The readback the frame being built paints and publishes from. It is the
    /// other slot, so a frame that fails after staging its draft has still
    /// never touched the readback the committed frame drew from.
    fn candidateField(self: *View) *Field {
        return &self.slots[self.committedSlot() ^ 1];
    }

    /// Refresh the readback this view paints and publishes from, so both
    /// describe the model as it stands NOW rather than as it stood when the
    /// last platform request was drained. The readback is the frame's
    /// candidate, so this never reaches into the committed frame's own slot.
    fn read(self: *View) !void {
        try readField(self.session, self.owner, self.candidateField());
    }

    /// The readbacks' own bytes. The model belongs to the Session, so only
    /// these copies are released here, and each slot's storage is given back
    /// exactly once whether or not that slot ever held a byte.
    pub fn releaseReadback(self: *View) void {
        for (&self.slots) |*slot| {
            slot.text.deinit(slot.gpa);
            slot.text = .empty;
        }
    }

    pub fn draw(self: *View, ctx: *nogui.DrawCtx) !void {
        // The caption below and the published run both read this readback, so
        // it is refreshed from the Session before either of them does.
        try self.read();
        // The safe area becomes padding against the window's own logical
        // extent. A far edge past the window is a platform defect or a stale
        // reading, and a negative padding is not a layout, so both are floored
        // at zero rather than handed to the solver.
        const left = @max(self.content[0], 0);
        const top = @max(self.content[1], 0);
        const right = @max(self.window[0] - self.content[2], 0);
        const bottom = @max(self.window[1] - self.content[3], 0);
        _ = try ctx.column(.{
            .padding = .{ .left = left, .top = top, .right = right, .bottom = bottom },
            .gap = 12,
        });
        defer ctx.pop();

        _ = try ctx.label(.{ .text = label_title });
        self.status_len = (std.fmt.bufPrint(self.status[0..], "text=\"{s}\"", .{
            self.candidateField().slice(),
        }) catch @as([]u8, self.status[0..])).len;
        _ = try ctx.label(.{ .text = self.status[0..self.status_len] });

        // The core has no text-input widget kind, so the carrier is a real
        // keyed button whose published ROLE and TEXT come from the annotator.
        // The widget is real and focusable; only its semantic role is remapped,
        // and the box the layout gives THIS node is the box the caret geometry
        // and the published bounds both use.
        self.field_node = try ctx.button(.{
            .key = key_field,
            .label = label_field,
            .on_click_with_data = nogui.bind(View.onFieldTap, 0),
            .height = 56,
        });
        _ = try ctx.button(.{
            .key = key_send,
            .label = label_send,
            .on_click_with_data = nogui.bind(View.onSend, 0),
            .height = 44,
        });
        _ = try ctx.checkbox(.{
            .key = key_flag,
            .label = label_flag,
            .value = &self.flag,
            .height = 36,
        });
        _ = try ctx.slider(.{
            .key = key_level,
            .label = label_level,
            .value = &self.level,
            .min = 0,
            .max = 100,
            .height = 32,
        });
    }
};

/// Turns the field carrier's real node into an editable text node.
///
/// It remaps a role and fills in payloads the core's built-in policy does not
/// carry for a button. It invents nothing: the bytes are the model's, the
/// character table is measured from those bytes, and the selection is the
/// model's own, converted from the protocol's UTF-16 units into the core's
/// byte offsets.
fn annotate(
    context: *anyopaque,
    node: *const nogui.widget.WidgetNode,
    draft: *semantics.Draft,
) !void {
    const self: *View = @ptrCast(@alignCast(context));
    const button = switch (node.kind) {
        .button => |value| value,
        else => return,
    };
    if (!std.mem.eql(u8, button.label, label_field)) return;
    // The bytes handed over here are read out of the Session into the readback
    // the frame BEING BUILT owns, and the publisher copies them into its own
    // storage as it stages. The committed snapshot holds the publisher's copy
    // of the other slot, and a frame that is refused after this returns
    // publishes nothing at all — so a refused frame must never have touched
    // the readback the committed frame drew from.
    try self.read();
    const field = self.candidateField();
    const selection = try View.byteSelection(field);
    draft.role = .text_input;
    draft.text = .{
        .value = field.slice(),
        .placeholder = label_placeholder,
        .selection = .{ .anchor = selection[0], .focus = selection[1] },
        .character_lengths = field.lengths[0..field.characters],
    };
    var actions: semantics.ActionSet = .{};
    actions.enable(.focus);
    actions.enable(.blur);
    actions.enable(.replace_selected_text);
    actions.enable(.set_text_selection);
    // A screen reader writes into a field with `set_value`, which carries the
    // WHOLE new contents. This hook REPLACES the core's additive policy, so the
    // bit has to be stated here or the core's own addition never reaches this
    // node and the platform's contents request is refused as unsupported.
    actions.enable(.set_value);
    draft.actions = actions;
}

// ── The native action seams ─────────────────────
//
// Every platform action leaves through one of these, which is the ordinary
// input path: a screen-reader edit and a person's keystroke reach the same
// model through the same door. There is no second route, and the edits go
// through the Session's own borrow so the model rules apply to them exactly as
// they apply to a keystroke.

/// What every native seam needs: the App for activation, focus and the numeric
/// controls, and the Session plus ticket for the text route.
///
/// It stands apart from the run on purpose. A seam reaches no window, no
/// surface and no observer, and a value of this type can be built by anything
/// that owns a real App, a real model and a real committed tree — which is
/// what lets the dispatcher under test be the dispatcher that ships.
const Seams = struct {
    app: *App,
    session: *Session,
    owner: nogui.Model(Field),
};

/// Activate through the ordinary activation path.
fn onActivate(context: *anyopaque, id: WidgetId) void {
    const self: *Seams = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return;
    self.app.activate(tree, id);
}

/// Move the committed focus through the ordinary focus manager.
fn onFocus(context: *anyopaque, id: ?WidgetId) void {
    const self: *Seams = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return;
    if (id) |target| {
        _ = self.app.focus_manager.set(tree, target, self.app.focusObserver());
    } else {
        self.app.focus_manager.blur(self.app.focusObserver());
    }
}

fn onSetNumber(context: *anyopaque, id: WidgetId, value: f64) bool {
    const self: *Seams = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return false;
    const dense = tree.frameNode(id) orelse return false;
    const node = tree.nodeConst(dense) orelse return false;
    switch (node.kind) {
        .slider => |slider| {
            slider.value.* = @floatCast(value);
            return true;
        },
        else => return false,
    }
}

/// Read the LIVE value, not the published one: a screen reader may send two
/// steps before the app republishes, and a step computed from the published
/// value would collapse them.
fn onReadNumber(context: *anyopaque, id: WidgetId) ?f64 {
    const self: *Seams = @ptrCast(@alignCast(context));
    const tree = self.app.tree_ptr orelse return null;
    const dense = tree.frameNode(id) orelse return null;
    const node = tree.nodeConst(dense) orelse return null;
    return switch (node.kind) {
        .slider => |slider| @floatCast(slider.value.*),
        else => null,
    };
}

/// A platform text edit, in UTF-8 bytes with the core's own byte offsets.
///
/// The payload states which request this is and nothing else decides it: a
/// value is the field's ENTIRE new contents even when it is empty and even
/// when its bytes borrow the run the last publication handed out, and no value
/// is a request that moves the caret and nothing else. So this seam holds no
/// readback and names no published run: the model answers every request from
/// the bytes it holds now.
fn onSetText(
    context: *anyopaque,
    id: WidgetId,
    value: ?[]const u8,
    selection: semantics.TextSelection,
) bool {
    _ = id;
    const self: *Seams = @ptrCast(@alignCast(context));
    var request: WriteText = .{
        .value = value,
        .selection = selection,
    };
    self.session.update(Field, self.owner, &request, WriteText.apply) catch return false;
    return true;
}

/// Read the model's LIVE value, selection and whole-value capacity.
///
/// The core composes an edit against this and nothing else, so a request that
/// arrives before the app republishes edits the bytes the model holds NOW
/// rather than the run the last publication handed out. The model's selection
/// is the protocol's UTF-16 units, so it comes back through the same
/// `utf16ToUtf8` conversion every other offset in this file uses, and an
/// endpoint the live value cannot address is a refusal rather than a snapped
/// guess.
///
/// Both ends keep their own meaning: `anchor()` and `cursor()` are DIFFERENT
/// offsets for a selection the user dragged backwards, and reporting the span
/// for both would answer that drag with a caret at the end they started from.
///
/// This field grows with its input, so its capacity is the one no value can
/// exceed. Nothing here has a bound to clip at, and reporting an invented one
/// would make the core refuse writes this model can store.
fn onReadText(context: *anyopaque, _: WidgetId) ?semantics.TextEditState {
    const self: *Seams = @ptrCast(@alignCast(context));
    var live: LiveText = .{};
    self.session.read(Field, self.owner, &live, struct {
        fn run(field: *const Field, out: *LiveText) !void {
            const value = field.slice();
            const anchor = text_input.utf16ToUtf8(value, field.selection.anchor()) catch
                return;
            const focus = text_input.utf16ToUtf8(value, field.selection.cursor()) catch
                return;
            out.state = .{
                .value = value,
                .selection = .{ .anchor = anchor, .focus = focus },
                .capacity = std.math.maxInt(usize),
            };
        }
    }.run) catch return null;
    return live.state;
}

/// Bind the stable run address before the dispatcher can receive any action.
fn makeDispatcher(context: *anyopaque) semantics.Dispatcher {
    return .{
        .context = context,
        .activate = onActivate,
        .focus = onFocus,
        .set_number = onSetNumber,
        .read_number = onReadNumber,
        .set_text = onSetText,
        .read_text = onReadText,
    };
}

/// The answer a live-text read carries out of its Session borrow.
///
/// The handler writes through a pointer because the conversion can fail, and a
/// selection the live value cannot address is a refusal: a null state is what
/// the seam reports as "no text answer", never a state with a made-up offset.
const LiveText = struct {
    state: ?semantics.TextEditState = null,
};

/// One platform text edit, applied to the model through a Session borrow.
///
/// The payload carries the request itself, so the model never has to guess
/// what it was asked to do. A value is the field's whole new contents — empty
/// bytes, and bytes that borrow the run the last publication handed out or the
/// model's own buffer, are whole writes too — and it is written exactly once.
/// No value at all is a selection: it moves the caret against the bytes the
/// model holds now and changes no character byte, no character table and no
/// marked composition.
const WriteText = struct {
    /// The field's entire new contents, or null for a selection-only request.
    value: ?[]const u8,
    /// UTF-8 byte offsets the core already bounded against the run it
    /// published, so they can only be out of date, never out of range.
    selection: semantics.TextSelection,

    fn apply(field: *Field, context: *anyopaque) anyerror!void {
        const request: *const WriteText = @ptrCast(@alignCast(context));
        if (request.value) |bytes| {
            // The payload may BE the live value, which the last publication
            // handed out as a slice of this very list. A grow therefore has
            // to leave the bytes alone: a payload that borrows these bytes is
            // no longer than the list already is, so the reservation below
            // is already satisfied and the buffer is not reallocated under a
            // pointer the copy is about to read.
            try field.text.ensureTotalCapacity(field.gpa, bytes.len);
            @memmove(field.text.items.ptr[0..bytes.len], bytes);
            field.text.items.len = bytes.len;
            field.replacements += 1;
            field.marked = null;
            field.measureCharacters();
        }
        // Both kinds of request answer with the same conversion, because both
        // address the bytes the model holds once this has run: the whole value
        // it was just given, or the live value a selection moves through. The
        // offsets arrive as UTF-8 bytes and the model speaks the protocol's
        // UTF-16 units, so it happens here exactly once, and against the
        // model's own storage rather than a borrowed one. A byte offset that
        // is not a codepoint boundary is a platform defect, and it is refused
        // rather than snapped.
        const value = field.slice();
        const anchor = @min(request.selection.anchor, value.len);
        const focus = @min(request.selection.focus, value.len);
        const from = try text_input.utf8ToUtf16(value, anchor);
        const to = try text_input.utf8ToUtf16(value, focus);
        // The DIRECTION is part of the request. A selection whose anchor sits
        // after its focus is one the user dragged backwards, and the model
        // keeps which end is which: ordering the two into a span without
        // saying so would leave the reader a caret at the end the drag
        // started from.
        field.selection = .{
            .range = .{ .start = @min(from, to), .end = @max(from, to) },
            .reversed = from > to,
        };
    }
};

/// Everything a whole-value write has to produce, read back through the
/// Session in ONE borrow: the bytes, the caret collapsed behind their last
/// one, and the character table measured from those same bytes.
const FieldReading = struct {
    text: []const u8,
    start: usize,
    end: usize,
    characters: usize,
    lengths: []const u8,
    replacements: u32,
    /// Whether the anchor sits at the END of the span. Absent means a forward
    /// selection, which is what every reading before a backwards drag wrote.
    reversed: bool = false,
};

/// Assert one field reading against the model's own Session borrow.
///
/// Every number below comes from the model the seam mutated, so a check can
/// never pass on a value this file kept beside it.
fn expectField(
    session: *Session,
    owner: nogui.Model(Field),
    want: FieldReading,
) !void {
    try session.read(Field, owner, want, struct {
        fn run(field: *const Field, expected: FieldReading) !void {
            try std.testing.expectEqualStrings(expected.text, field.slice());
            try std.testing.expectEqual(expected.start, field.selection.range.start);
            try std.testing.expectEqual(expected.end, field.selection.range.end);
            try std.testing.expectEqual(expected.reversed, field.selection.reversed);
            try std.testing.expectEqual(@as(?Utf16Range, null), field.marked);
            try std.testing.expectEqual(expected.characters, field.characters);
            try std.testing.expectEqualSlices(
                u8,
                expected.lengths,
                field.lengths[0..field.characters],
            );
            try std.testing.expectEqual(expected.replacements, field.replacements);
        }
    }.run);
}

/// Why a request was refused, or null when the model actually changed.
///
/// A refused write and an applied one must never read the same in a check, so
/// every dispatch below is compared against this rather than against an
/// inspection of the published action set.
fn refusal(outcome: semantics.Outcome) ?semantics.Failure {
    return switch (outcome) {
        .applied => null,
        .ignored => |why| why,
    };
}

test "api-w23 mobile field applies the whole-value SetValue a screen reader drives" {
    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch
        @panic("W23 mobile field check left the Session live");
    var app = try App.init(gpa, &session);
    defer app.deinit();
    var view: View = undefined;
    var owner = try mountField(gpa, &session, &app, &view);
    defer session.release(Field, &owner) catch unreachable;
    defer view.releaseReadback();

    var publisher = semantics.Publisher.init(gpa);
    defer publisher.deinit();
    app.semantic_publication = .{
        .publisher = &publisher,
        .window_name = window_title,
        .annotator = .{ .context = &view, .annotate = annotate },
    };
    defer app.semantic_publication = null;
    const output = try app.frame(0, .{
        .width = @floatFromInt(window_width),
        .height = @floatFromInt(window_height),
    });
    defer if (output.json) |json| gpa.free(json);
    const snapshot = output.semantic_snapshot orelse return error.MissingSemanticSnapshot;
    // The field is found by the ROLE its own annotator gave it, because that is
    // what a client resolves a write against. The published value is the
    // MODEL's: the view reads it through the Session rather than from the value
    // the Session took ownership of.
    var published: ?*const semantics.Node = null;
    for (snapshot.nodes) |*node| {
        if (node.role == .text_input) {
            published = node;
            break;
        }
    }
    const entry = published orelse return error.NoPublishedTextField;
    try std.testing.expectEqualStrings(initial_field_text, entry.text.?.value);

    var seams: Seams = .{
        .app = &app,
        .session = &session,
        .owner = owner,
    };
    const dispatcher = makeDispatcher(@ptrCast(&seams));
    // SAFETY: only the two slices named below are ever read, and the core
    // fills what it writes into them before it reads them back.
    var scratch_storage: [semantics.Scratch.default_capacity]u8 = undefined;
    const scratch: semantics.Scratch = .{
        .row_name = scratch_storage[0..1024],
        .text_value = scratch_storage[1024..],
    };

    // A provider hands the field its WHOLE new contents and the core collapses
    // the caret after the last byte. Eight characters over fourteen bytes, so
    // the core's byte offsets and the protocol's own units are different
    // numbers here and a route that conflated them would land the caret inside
    // a character.
    const whole = "Grüße ✓€";
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = whole,
        }, &dispatcher, scratch)),
    );
    try expectField(&session, owner, .{
        .text = whole,
        .start = 8,
        .end = 8,
        .characters = 8,
        .lengths = &.{ 1, 1, 2, 2, 1, 1, 3, 3 },
        .replacements = 1,
    });

    // An empty value is a real value, not a missing one: it clears the field
    // and the caret collapses at zero instead of staying where it was.
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = "",
        }, &dispatcher, scratch)),
    );
    try expectField(&session, owner, .{
        .text = "",
        .start = 0,
        .end = 0,
        .characters = 0,
        .lengths = &.{},
        .replacements = 2,
    });

    // The same whole value sent again is a second WRITE, whatever the bytes
    // it happens to spell: it carries contents, so it replaces.
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = whole,
        }, &dispatcher, scratch)),
    );

    // A selection carries no contents at all. It moves the caret and leaves
    // the value the dispatch above wrote standing, which is exactly what the
    // counts below say: same bytes, same character table, one more write.
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_text_selection,
            .selection = .{ .anchor = 2, .focus = 2 },
        }, &dispatcher, scratch)),
    );
    try expectField(&session, owner, .{
        .text = whole,
        .start = 2,
        .end = 2,
        .characters = 8,
        .lengths = &.{ 1, 1, 2, 2, 1, 1, 3, 3 },
        .replacements = 3,
    });

    // The ORDINARY half is untouched by any of it: a committed keystroke
    // through the App's own text endpoint edits the same model, at the caret
    // the selection request just placed.
    const tree = app.tree_ptr orelse return error.NoCommittedTree;
    const id = app.widgetIdForKey(.root, key_field) orelse return error.NoFieldIdentity;
    if (!app.focus_manager.set(tree, id, app.focusObserver())) return error.FieldRefusedFocus;
    app.registerTextEndpoint(.{
        .id = id,
        .owner = owner.weak().erase(),
        .ops = fieldOps(),
        // These ops take the `Field` this names and ignore the opaque user, so
        // the pointer is inert today. It names the readback the committed
        // frame drew from, so it stays true if an op ever reads it, and it
        // stays a live address for as long as this view does.
        .user = view.committedField(),
    });
    if (try app.handle(.{ .text_input = .{ .text = "é" } })) |committed| {
        if (committed.json) |json| gpa.free(json);
    }
    try expectField(&session, owner, .{
        .text = "Gréüße ✓€",
        .start = 3,
        .end = 3,
        .characters = 9,
        .lengths = &.{ 1, 1, 2, 2, 2, 1, 1, 3, 3 },
        .replacements = 4,
    });

    // A whole value the platform sends AGAIN, after the model has moved on.
    // The snapshot still carries "mobile" and this payload spells those same
    // bytes out of the PLATFORM's own buffer, and it is still a write: what
    // separates the two is the contents the payload carries, never an equality
    // between bytes and never which buffer owns them.
    var again: [6]u8 = "mobile".*;
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = "é",
        }, &dispatcher, scratch)),
    );
    try expectField(&session, owner, .{
        .text = "é",
        .start = 1,
        .end = 1,
        .characters = 1,
        .lengths = &.{2},
        .replacements = 5,
    });
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = again[0..],
        }, &dispatcher, scratch)),
    );
    try expectField(&session, owner, .{
        .text = "mobile",
        .start = 6,
        .end = 6,
        .characters = 6,
        .lengths = &.{ 1, 1, 1, 1, 1, 1 },
        .replacements = 6,
    });
}

// The ordinary half of the same model: a selection the user dragged
// BACKWARDS is a real selection, the next replacement resolves against the
// selection the model holds NOW rather than against the run this frame
// published, and a whole value longer than the one it replaces is stored
// whole. Every number below is read back through the model's own borrow.
test "api-w23 mobile a live selection answers the next platform edit" {
    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch
        @panic("W23 mobile live selection check left the Session live");
    var app = try App.init(gpa, &session);
    defer app.deinit();
    var view: View = undefined;
    var owner = try mountField(gpa, &session, &app, &view);
    defer session.release(Field, &owner) catch unreachable;
    defer view.releaseReadback();

    var publisher = semantics.Publisher.init(gpa);
    defer publisher.deinit();
    app.semantic_publication = .{
        .publisher = &publisher,
        .window_name = window_title,
        .annotator = .{ .context = &view, .annotate = annotate },
    };
    defer app.semantic_publication = null;
    const output = try app.frame(0, .{
        .width = @floatFromInt(window_width),
        .height = @floatFromInt(window_height),
    });
    defer if (output.json) |json| gpa.free(json);
    const snapshot = output.semantic_snapshot orelse return error.MissingSemanticSnapshot;
    var published: ?*const semantics.Node = null;
    for (snapshot.nodes) |*node| {
        if (node.role == .text_input) {
            published = node;
            break;
        }
    }
    const entry = published orelse return error.NoPublishedTextField;

    var seams: Seams = .{
        .app = &app,
        .session = &session,
        .owner = owner,
    };
    const dispatcher = makeDispatcher(@ptrCast(&seams));
    // SAFETY: only the two slices named below are ever read, and the core
    // fills what it writes into them before it reads them back.
    var scratch_storage: [semantics.Scratch.default_capacity]u8 = undefined;
    const scratch: semantics.Scratch = .{
        .row_name = scratch_storage[0..1024],
        .text_value = scratch_storage[1024..],
    };

    // A selection dragged from byte 4 back to byte 1. The model keeps which
    // end is the anchor, and the live answer carries both offsets out in
    // that order: a reader that collapsed them into the span's start would
    // report a caret at byte 1 for a selection that ends there.
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_text_selection,
            .selection = .{ .anchor = 4, .focus = 1 },
        }, &dispatcher, scratch)),
    );
    try expectField(&session, owner, .{
        .text = initial_field_text,
        .start = 1,
        .end = 4,
        .characters = 6,
        .lengths = &.{ 1, 1, 1, 1, 1, 1 },
        .replacements = 0,
        .reversed = true,
    });
    const id = app.widgetIdForKey(.root, key_field) orelse return error.NoFieldIdentity;
    const live = dispatcher.read_text.?(dispatcher.context, id) orelse
        return error.NoLiveTextAnswer;
    try std.testing.expectEqualStrings(initial_field_text, live.value);
    try std.testing.expectEqual(@as(usize, 4), live.selection.anchor);
    try std.testing.expectEqual(@as(usize, 1), live.selection.focus);
    // The value grows with what it is given, so nothing here has a bound to
    // clip at and the capacity is the one no payload can pass.
    try std.testing.expectEqual(std.math.maxInt(usize), live.capacity);

    // The replacement below names no selection at all, so it resolves against
    // the LIVE one: bytes 1..4 go and "X" lands where they were. The snapshot
    // still publishes the run this frame built — "mobile", caret at its end —
    // so an edit composed from the published selection would have appended at
    // the end instead.
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .replace_selected_text,
            .text = "X",
        }, &dispatcher, scratch)),
    );
    try expectField(&session, owner, .{
        .text = "mXle",
        .start = 2,
        .end = 2,
        .characters = 4,
        .lengths = &.{ 1, 1, 1, 1 },
        .replacements = 1,
    });

    // A whole value LONGER than the one it replaces is stored whole: nine
    // characters over seventeen bytes, and the caret lands after the last
    // one. A model that clipped to what it had would keep four of them.
    const whole = "Grüße ✓€€";
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = whole,
        }, &dispatcher, scratch)),
    );
    try expectField(&session, owner, .{
        .text = whole,
        .start = 9,
        .end = 9,
        .characters = 9,
        .lengths = &.{ 1, 1, 2, 2, 1, 1, 3, 3, 3 },
        .replacements = 2,
    });
}

// An ordinary empty replacement must clear a nonempty field: it carries
// contents, so it is a whole write, and nothing else has to authorize it.
test "api-w23 mobile an empty whole value clears the field" {
    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch
        @panic("W23 mobile empty value check left the Session live");
    var app = try App.init(gpa, &session);
    defer app.deinit();
    var view: View = undefined;
    var owner = try mountField(gpa, &session, &app, &view);
    defer session.release(Field, &owner) catch unreachable;
    defer view.releaseReadback();

    // The model starts full, so a write that never happened cannot be read
    // back as one that did.
    try expectField(&session, owner, .{
        .text = initial_field_text,
        .start = 6,
        .end = 6,
        .characters = 6,
        .lengths = &.{ 1, 1, 1, 1, 1, 1 },
        .replacements = 0,
    });

    // One ordinary platform edit through the real Session borrow. Empty bytes
    // are a value like any other: they write the field empty and collapse the
    // caret at zero.
    var whole: WriteText = .{
        .value = "",
        .selection = semantics.TextSelection.caret(0),
    };
    try session.update(Field, owner, &whole, WriteText.apply);
    try expectField(&session, owner, .{
        .text = "",
        .start = 0,
        .end = 0,
        .characters = 0,
        .lengths = &.{},
        .replacements = 1,
    });
}

test "api-w23 mobile whole value may overlap its own model storage" {
    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var app = try App.init(gpa, &session);
    defer app.deinit();
    var view: View = undefined;
    var owner = try mountField(gpa, &session, &app, &view);
    defer session.release(Field, &owner) catch unreachable;
    defer view.releaseReadback();

    var context: u8 = 0;
    try session.update(Field, owner, &context, struct {
        fn apply(field: *Field, _: *anyopaque) !void {
            const value = field.slice()[1..];
            var whole: WriteText = .{
                .value = value,
                .selection = semantics.TextSelection.caret(value.len),
            };
            try WriteText.apply(field, &whole);
        }
    }.apply);
    try expectField(&session, owner, .{
        .text = "obile",
        .start = 5,
        .end = 5,
        .characters = 5,
        .lengths = &.{ 1, 1, 1, 1, 1 },
        .replacements = 1,
    });
}

// ── A refused publication ───────────

/// What the field holds after the whole-value write this check drives.
///
/// It is longer than the value the first publication carried, so a republish
/// that still showed the old bytes would be a change the platform never
/// learned about, and it is short enough that the field's own character table
/// still covers every one of its characters, so the run it publishes stays
/// addressable in the platform's own units end to end.
const grown_field_text: []const u8 =
    "a value this run has never published before, and one long enough that " ++
    "the second publication cannot be mistaken for the first one it replaces";

/// The published editable node, found by the ROLE this file's own annotator
/// gave it, because that is what a client resolves a write against.
fn publishedField(snapshot: *const semantics.Snapshot) ?*const semantics.Node {
    for (snapshot.nodes) |*node| {
        if (node.role == .text_input and node.text != null) return node;
    }
    return null;
}

/// One committed field run exactly as a platform reads it: the whole value,
/// the caret collapsed behind its last byte, and a character table covering
/// every character of those same bytes. Nothing here is compared against a
/// pointer or an allocator: a consumer sees bytes and a caret, so a check that
/// asked where the bytes came from would be testing the producer's storage
/// rather than what a platform actually reads.
fn expectPublishedRun(entry: *const semantics.Node, value: []const u8) !void {
    const text = entry.text.?;
    try std.testing.expectEqualStrings(value, text.value);
    try std.testing.expectEqual(value.len, text.character_lengths.len);
    const selection = text.selection orelse return error.NoPublishedSelection;
    try std.testing.expectEqual(value.len, selection.anchor);
    try std.testing.expectEqual(value.len, selection.focus);
}

/// The production annotation hook with one refusal switch on top.
///
/// The switch is the whole seam. It asks the real hook for the real draft and
/// then refuses the publication on the field's own annotation, which is the
/// one refusal the App documents for a frame that began a publication and did
/// not finish it: the publisher discards the staged snapshot whole and the
/// committed one stands. Nothing about the draft is invented, so the refused
/// frame is the frame this run would really have published.
const RefusingAnnotator = struct {
    view: *View,
    refuse: bool = false,

    fn annotateThenRefuse(
        context: *anyopaque,
        node: *const nogui.widget.WidgetNode,
        draft: *semantics.Draft,
    ) !void {
        const self: *RefusingAnnotator = @ptrCast(@alignCast(context));
        try annotate(self.view, node, draft);
        if (self.refuse and draft.text != null) return error.RefusedByTheRun;
    }
};

test "api-w23 mobile a refused publication leaves the committed snapshot whole" {
    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch
        @panic("W23 mobile refusal check left the Session live");
    var app = try App.init(gpa, &session);
    defer app.deinit();
    var view: View = undefined;
    var owner = try mountField(gpa, &session, &app, &view);
    defer session.release(Field, &owner) catch unreachable;
    defer view.releaseReadback();

    var publisher = semantics.Publisher.init(gpa);
    defer publisher.deinit();
    var annotator: RefusingAnnotator = .{ .view = &view };
    app.semantic_publication = .{
        .publisher = &publisher,
        .window_name = window_title,
        .annotator = .{ .context = &annotator, .annotate = RefusingAnnotator.annotateThenRefuse },
    };
    defer app.semantic_publication = null;
    const surface: nogui.Size = .{
        .width = @floatFromInt(window_width),
        .height = @floatFromInt(window_height),
    };

    // The first committed snapshot is a COMPLETE field: the whole value, the
    // caret behind its last byte, and a character table that covers it.
    const first = try app.frame(0, surface);
    defer if (first.json) |json| gpa.free(json);
    try expectPublishedRun(
        publishedField(first.semantic_snapshot orelse
            return error.MissingSemanticSnapshot) orelse return error.NoPublishedTextField,
        initial_field_text,
    );

    // A whole-value write through the Session, on the same door a screen
    // reader drives, so the model really has moved on before anything is
    // refused: an unchanged publication below is then a statement about the
    // publication and not about a model that never changed.
    var whole: WriteText = .{
        .value = grown_field_text,
        .selection = semantics.TextSelection.caret(grown_field_text.len),
    };
    try session.update(Field, owner, &whole, WriteText.apply);
    try session.read(Field, owner, &grown_field_text, struct {
        fn run(field: *const Field, want: *const []const u8) !void {
            try std.testing.expectEqualStrings(want.*, field.slice());
            try std.testing.expectEqual(want.len, field.characters);
            try std.testing.expectEqual(@as(u32, 1), field.replacements);
        }
    }.run);

    // The next frame draws, reads the model again, and is then refused at the
    // publication. The App commits its publisher only after every fallible
    // step, so a refused frame publishes nothing at all.
    annotator.refuse = true;
    try std.testing.expectError(error.AnnotationFailed, app.frame(1, surface));
    try std.testing.expectEqual(@as(u64, 1), app.frame_generation);

    // What the platform still reads is the frame before that one, whole: the
    // same generation, the same complete value and the same caret, with the
    // model one whole value ahead of it.
    const committed = publisher.snapshot() orelse return error.MissingSemanticSnapshot;
    try std.testing.expectEqual(@as(u64, 1), committed.generation);
    try expectPublishedRun(
        publishedField(committed) orelse return error.NoPublishedTextField,
        initial_field_text,
    );

    // A retry publishes the grown value complete, under the next generation.
    annotator.refuse = false;
    const recovered = try app.frame(1, surface);
    defer if (recovered.json) |json| gpa.free(json);
    const republished = recovered.semantic_snapshot orelse
        return error.MissingSemanticSnapshot;
    try std.testing.expectEqual(@as(u64, 2), republished.generation);
    try expectPublishedRun(
        publishedField(republished) orelse return error.NoPublishedTextField,
        grown_field_text,
    );
}

// ── The native text port ─────────────────────

/// The host's own native text-input port, wrapped so every call the core makes
/// is counted and still reaches SDL.
///
/// This is how the run can say the soft keyboard was shown and hidden THROUGH
/// THE FOCUSED ENDPOINT rather than by a call of its own: the starts and stops
/// counted here are the ones the text-input manager made because the model's
/// endpoint took and lost focus.
const NativeTrace = struct {
    // SAFETY: the run assigns the host port before installing this trace.
    inner: text_input.Native = undefined,
    starts: u32 = 0,
    stops: u32 = 0,
    areas: u32 = 0,
    area_refused: u32 = 0,
    clears: u32 = 0,

    fn start(user: *anyopaque) anyerror!void {
        const self: *NativeTrace = @ptrCast(@alignCast(user));
        self.starts += 1;
        try self.inner.start(self.inner.user);
    }

    fn stop(user: *anyopaque) anyerror!void {
        const self: *NativeTrace = @ptrCast(@alignCast(user));
        self.stops += 1;
        try self.inner.stop(self.inner.user);
    }

    fn setArea(user: *anyopaque, area: geometry.WindowRect, cursor: f32) anyerror!void {
        const self: *NativeTrace = @ptrCast(@alignCast(user));
        const inner = self.inner.set_area orelse return;
        // A refusal is counted AND propagated: the manager documents that a
        // refused area leaves the previous one in place and surfaces through
        // `caretGeometry`, and swallowing it here would hide exactly the fact
        // this run exists to report.
        inner(inner.user, area, cursor) catch |err| {
            self.area_refused += 1;
            return err;
        };
        self.areas += 1;
    }

    fn clearComposition(user: *anyopaque) void {
        const self: *NativeTrace = @ptrCast(@alignCast(user));
        self.clears += 1;
        if (self.inner.clear_composition) |inner| inner.clear_composition(inner.user);
    }

    fn port(self: *NativeTrace) text_input.Native {
        return .{
            .user = self,
            .start = start,
            .stop = stop,
            .set_area = setArea,
            .clear_composition = clearComposition,
        };
    }
};

// ── The device, the surface and the frame adapter ──────────

/// A SPIR-V module read from the build's `shaders/` directory, the same five
/// the other painted smokes read. The bytes stay owned for as long as the
/// adapter needs them; `shaderCreate` copies the module.
const Spv = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Spv {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) {
            gpa.free(bytes);
            return error.ShaderModuleMalformed;
        }
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *Spv, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// The instance extensions this build asked for. `noapi.Gpu.init` takes a
/// plain function, so the storage it reads must outlive the call; the copy is
/// released as soon as `init` returns and this is emptied.
var instance_extensions: [][*:0]const u8 = &.{};

fn currentInstanceExtensions() []const [*:0]const u8 {
    return instance_extensions;
}

fn deviceExtent(managed: *ManagedWindow) !noapi.Extent2D {
    const pixels = try managed.native.pixelExtent();
    return .{ .width = pixels.width, .height = pixels.height };
}

/// The native half of the run: the device, the platform surface created over
/// the window SDL really made, and the public frame adapter that owns the text
/// engine, the scene lowering and the Oklab-to-sRGB blit.
///
/// TEARDOWN ORDER is owned by the host's `on_before_close` hook, because the
/// surface references the native window and the window is destroyed after the
/// hook runs: the App leaves the endpoint, then the adapter, then the surface,
/// then the device its swapchain lived on.
const NativeHalf = struct {
    gpu: noapi.Gpu,
    surface: noapi.Surface,
    adapter: NativeFrame,
    quad_vert: Spv,
    quad_frag: Spv,
    sort_comp: Spv,
    fullscreen_vert: Spv,
    blit_oklab: Spv,

    fn init(
        self: *NativeHalf,
        gpa: std.mem.Allocator,
        io: Io,
        managed: *ManagedWindow,
    ) !void {
        // SAFETY: each field is initialized before use. Unwind guards are
        // installed only after assignment; failed init never reaches deinit.
        self.* = undefined;
        try sdl3.vulkan.loadLibrary(null);
        const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
        const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
        const exts = try gpa.dupe([*:0]const u8, sdl_exts);
        instance_extensions = exts;
        defer {
            gpa.free(exts);
            instance_extensions = &.{};
        }
        self.gpu = try noapi.Gpu.init(.{
            .frames_in_flight = frame_api.scene.frames_in_flight,
            .app_name = "w23-mobile-smoke",
            .validation = false,
            .loader = .{
                .get_instance_proc_addr = @ptrCast(get_proc_addr),
                .get_instance_extensions = &currentInstanceExtensions,
            },
            .io = io,
            .allocator = gpa,
        });
        errdefer self.gpu.deinit();
        // A platform call, so it can fail. A target that will not create a
        // surface for this window is a typed failure here, never a fallback to
        // software graphics: this process holds no raw graphics handle and no
        // SDL renderer, so there is nothing else it could draw through.
        self.surface = try noapi.Surface.initSdl(
            &self.gpu,
            @ptrCast(managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = try deviceExtent(managed) },
        );
        errdefer self.surface.deinit();
        self.quad_vert = try Spv.load(gpa, io, "shaders/quad_vert.spv");
        errdefer self.quad_vert.deinit(gpa);
        self.quad_frag = try Spv.load(gpa, io, "shaders/quad_frag.spv");
        errdefer self.quad_frag.deinit(gpa);
        self.sort_comp = try Spv.load(gpa, io, "shaders/sort_comp.spv");
        errdefer self.sort_comp.deinit(gpa);
        self.fullscreen_vert = try Spv.load(gpa, io, "shaders/fullscreen_vert.spv");
        errdefer self.fullscreen_vert.deinit(gpa);
        self.blit_oklab = try Spv.load(gpa, io, "shaders/blit_oklab.spv");
        errdefer self.blit_oklab.deinit(gpa);
        try self.adapter.init(.{
            .allocator = gpa,
            .gpu = &self.gpu,
            // The face every label is shaped with. It carries Latin; a
            // composition it cannot shape is painted as the layout's own
            // missing-glyph boxes, and the run says so rather than calling it
            // text.
            .fonts = &.{.{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") }},
            .shaders = .{
                .quad_vert = self.quad_vert.words,
                .quad_frag = self.quad_frag.words,
                .sort_comp = self.sort_comp.words,
                .fullscreen_vert = self.fullscreen_vert.words,
                .blit_oklab = self.blit_oklab.words,
            },
            .name = "w23_mobile_blit_oklab",
        });
    }

    /// The App must already have detached from `adapter.gpuEndpoint()`, and the
    /// SDL window must still exist: the surface belongs to it.
    fn deinit(self: *NativeHalf, gpa: std.mem.Allocator) void {
        self.adapter.deinit();
        self.surface.deinit();
        // After the surface: the swapchain lives on this device.
        self.gpu.deinit();
        self.blit_oklab.deinit(gpa);
        self.fullscreen_vert.deinit(gpa);
        self.sort_comp.deinit(gpa);
        self.quad_frag.deinit(gpa);
        self.quad_vert.deinit(gpa);
        self.* = undefined;
    }
};

// ── What the sink saw ─────────────────────

/// Everything the observer reported, counted. A poll that repeats a reading and
/// a signal the platform raised are counted apart, because one warning read on
/// sixty frames is one warning and not sixty.
const Observed = struct {
    events: u32 = 0,
    safe_area: u32 = 0,
    keyboard: u32 = 0,
    text_input: u32 = 0,
    orientation: u32 = 0,
    pixel_scale: u32 = 0,
    memory_signal: u32 = 0,
    memory_level: u32 = 0,
    compositions: u32 = 0,
    commits: u32 = 0,
    candidates: u32 = 0,
    touch_began: u32 = 0,
    touch_moved: u32 = 0,
    touch_ended: u32 = 0,
    touch_cancelled: u32 = 0,
    pinch_began: u32 = 0,
    pinch_updated: u32 = 0,
    pinch_ended: u32 = 0,
    back_requests: u32 = 0,
    back_consumed: u32 = 0,
    back_dismissed: u32 = 0,
    back_deferred: u32 = 0,
    back_handled: u32 = 0,
    last_decision: lifecycle.BackDecision = .ignored,
    last_source: lifecycle.BackSource = .unavailable,
    /// Observations made in the CURRENT batch. Reset before every pump, so a
    /// count that does not move across a back request is a batch that ended
    /// there rather than a quiet frame.
    batch: u32 = 0,
    /// Observations made in the batch that carried the back request, and in the
    /// same batch after it. A batch that ended at the back would show no growth.
    batch_at_back: u32 = 0,
    batch_after_back: u32 = 0,
    /// This run's own work: layouts applied, candidate republications, semantic
    /// publications and frames presented.
    layouts: u32 = 0,
    candidate_republishes: u32 = 0,
    publications: u32 = 0,
    drains_applied: u32 = 0,
    frames: u32 = 0,
    /// The field box the last committed layout produced.
    field_box: geometry.WindowRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The owned platform control's own account: how many were made, how many
    /// times its frame followed a committed rectangle, and how many were given
    /// back.
    probe_creates: u32 = 0,
    probe_geometry_syncs: u32 = 0,
    probe_releases: u32 = 0,
    /// Whether UIKit's own geometry matched the rectangle this run asked for.
    probe_frame_aligned: bool = false,
    /// Whether the control's text is the model's text, and its native UTF-16
    /// selection the model's UTF-16 selection. Both are READ BACK from the
    /// control, so agreement is a measurement across two representations rather
    /// than a restatement of what was written.
    probe_text_in_sync: bool = false,
    probe_selection_in_sync: bool = false,
};

// ── The run ───────────────────────────

/// One formatted detail string for a phase line, held by the run so a phase
/// can report its own numbers without a second allocation. `line` is the only
/// way to read it: the bytes borrow this buffer, so handing them out as a bare
/// `[]const u8` would let a caller format a second line over the first.
const Detail = struct {
    buffer: [256]u8 = [_]u8{0} ** 256,

    fn text(self: *Detail, comptime fmt: []const u8, args: anytype) []const u8 {
        // A line that does not fit says so rather than half-claiming one.
        return std.fmt.bufPrint(&self.buffer, fmt, args) catch "detail=unformattable";
    }

    /// Print `<name>: <detail>`. The detail is formatted HERE, into the buffer
    /// above, so every phase prints exactly the numbers it measured and none of
    /// them can leave a formatted string behind unused.
    fn line(
        self: *Detail,
        comptime fmt: []const u8,
        report: *Reporter,
        name: []const u8,
        args: anytype,
    ) !void {
        try report.emit("{s}: {s}\n", .{ name, self.text(fmt, args) });
    }
};

/// Everything this consumer owns for the length of the real run.
///
/// The observer borrows the window, the window borrows the App, the endpoint
/// borrows the model through the Session's weak owner, and every native
/// callback this run installs is gated on `owner` — so nothing that arrives
/// after the shutdown reaches storage that has gone.
const Run = struct {
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    session: *Session,
    app: *App,
    view: *View,
    /// The model as this run last read it. The model itself belongs to the
    /// Session, and the Session moves the value it is given, so every
    /// observation of the field goes through `readField` into this copy.
    field: Field,
    field_owner: *nogui.Model(Field),
    /// The ONE dispatcher context, reached by every native seam.
    seams: Seams,
    trace: *NativeTrace,
    application: *Application,
    handle: contract.WindowHandle,
    managed: *ManagedWindow,
    native: *NativeHalf,
    adapter: *mobile_a11y.Adapter,
    observer: sdl_mobile.Observer,
    publisher: semantics.Publisher,
    dispatcher: semantics.Dispatcher,
    scratch_bytes: [scratch_size]u8 = [_]u8{0} ** scratch_size,
    /// The liveness probe every native callback in this run is gated on.
    owner: host.weak_owner.WeakOwner,
    alive: bool = true,
    observed: Observed = .{},
    tick: u32 = 0,
    /// The semantic snapshot the App committed with the last frame, borrowed
    /// from the publisher and replaced by every frame that commits after it.
    snapshot: ?*const semantics.Snapshot = null,
    published_generation: u64 = 0,
    /// The content rectangle this run applied, in window-logical units.
    content: [4]f32 = .{ 0, 0, 0, 0 },
    window_logical: [2]f32 = .{ 0, 0 },
    window_live: bool = true,
    host_running: bool = true,
    frames_withheld: u32 = 0,
    retries: u32 = 0,
    /// The frame adapter's accounting, copied out before it goes, so the closing
    /// report outlives it.
    stats: NativeFrame.Stats = .{},
    target: noapi.Extent2D = .{ .width = 0, .height = 0 },
    retirements: u32 = 0,
    /// The last candidate rectangle this run published, from the manager.
    last_caret: ?geometry.WindowRect = null,
    /// The real platform control this run owns on the target whose framework
    /// cannot edit a synthetic node. Null on every other target, and on iOS
    /// until the semantics phase has a committed rectangle to place it in.
    probe_input: ?*anyopaque = null,
    /// The rectangle the control was last given, kept so the report can compare
    /// it with what UIKit says the control's geometry is.
    probe_frame: geometry.WindowRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// A probe or bridge refusal that makes this run a failure.
    ///
    /// Recorded rather than thrown so the closing report still says what the
    /// run DID observe, and returned once it has.
    probe_failure: ?anyerror = null,
    bound_native: u64 = mobile_a11y.no_node,
    /// The buffer every phase line formats into. One per run, borrowed by each
    /// `Detail.line` for the length of that one call.
    detail: Detail = .{},

    fn scratch(self: *Run) semantics.Scratch {
        return .{
            .row_name = self.scratch_bytes[0 .. scratch_size / 2],
            .text_value = self.scratch_bytes[scratch_size / 2 ..],
        };
    }

    /// Refresh this run's copy of the field model.
    ///
    /// Every report, phase line and probe reading of the field calls this
    /// first, so a number printed by the run is a number the model holds now
    /// rather than one this file kept beside it.
    fn refreshField(self: *Run) !void {
        try readField(self.session, self.field_owner.*, &self.field);
    }

    /// Release this run's copy. The model itself is the Session's, and it is
    /// released by the caller that created it.
    fn releaseReadback(self: *Run) void {
        self.field.text.deinit(self.field.gpa);
        self.field.text = .empty;
    }

    fn frameStats(self: *const Run) NativeFrame.Stats {
        return if (self.window_live) self.native.adapter.stats else self.stats;
    }

    // ── Native callbacks, all behind the liveness probe ─────────────

    fn sinkProbe(context: *const anyopaque) bool {
        const self: *const Run = @ptrCast(@alignCast(context));
        return self.alive and self.window_live;
    }

    /// Where every observation lands. The observer holds this as a borrowed
    /// context, so the probe above is what makes a late arrival harmless.
    fn onObservation(context: ?*anyopaque, event: sdl_mobile.Event) void {
        const raw = context orelse return;
        const self: *Run = @ptrCast(@alignCast(raw));
        if (!self.owner.isAlive()) return;
        self.record(event);
    }

    fn record(self: *Run, event: sdl_mobile.Event) void {
        const seen = &self.observed;
        seen.events += 1;
        seen.batch += 1;
        switch (event) {
            .safe_area => seen.safe_area += 1,
            .keyboard => seen.keyboard += 1,
            .text_input => seen.text_input += 1,
            .orientation => seen.orientation += 1,
            .pixel_scale => seen.pixel_scale += 1,
            .memory_signal => seen.memory_signal += 1,
            .memory_level => seen.memory_level += 1,
            .composition => seen.compositions += 1,
            .committed => seen.commits += 1,
            .candidate => seen.candidates += 1,
            .touch => |touch| switch (touch.phase) {
                .began => seen.touch_began += 1,
                .moved => seen.touch_moved += 1,
                .ended => seen.touch_ended += 1,
                .cancelled => seen.touch_cancelled += 1,
            },
            .pinch => |pinch| switch (pinch.phase) {
                .began => seen.pinch_began += 1,
                .updated => seen.pinch_updated += 1,
                .ended => seen.pinch_ended += 1,
            },
            .back => |back| {
                seen.back_requests += 1;
                seen.last_decision = back.decision;
                seen.last_source = back.request.source;
                switch (back.decision) {
                    // A request the application ANSWERED is consumed: the
                    // platform was not asked to do anything with it. A deferral
                    // is the opposite — it was handed back — so the two are
                    // counted apart rather than lumped as "handled".
                    .handled, .dismiss_keyboard => {
                        seen.back_consumed += 1;
                        if (back.decision == .handled) {
                            seen.back_handled += 1;
                        } else {
                            seen.back_dismissed += 1;
                        }
                    },
                    .defer_to_platform => seen.back_deferred += 1,
                    .ignored => {},
                }
                // The batch reading at the moment the back arrived, and again
                // when the batch ends. A batch abandoned at the back would show
                // no growth, and every event already queued behind it would be
                // lost with it.
                seen.batch_at_back = seen.batch;
            },
        }
    }

    /// This application's own back policy, on the facts the machine measured.
    ///
    /// The adapter never guesses that a back means closing a window; the answer
    /// belongs to the application, so it is decided here and nowhere else.
    fn onBack(context: ?*anyopaque, request: lifecycle.BackRequest) lifecycle.BackDecision {
        const raw = context orelse return .handled;
        const self: *Run = @ptrCast(@alignCast(raw));
        if (!self.owner.isAlive()) return .handled;
        // A target with no system back control has nothing to hand a request
        // back to, so it is consumed and REPORTED rather than pretended into a
        // deferral the platform could not honour.
        if (request.source == .unavailable) return .handled;
        // A keyboard or an open composition is this application's own to
        // dismiss, and dismissing it through the endpoint is one teardown the
        // platform sees rather than a dismissal the app then has to reconcile.
        if (request.keyboard_visible or request.composing) return .dismiss_keyboard;
        // Nothing of ours is open, so the request belongs to the platform,
        // which on Android moves the task to the background.
        return .defer_to_platform;
    }

    // ── Layout, caret and publication ─────────────

    /// Apply the observed safe area, and any keyboard occlusion, to the layout.
    ///
    /// `contentRect` works in window points because that is the space SDL
    /// reports input in AND the space the core lays out in, so the result is
    /// applied as padding with no scale applied anywhere. The keyboard's own
    /// rectangle is already in that same space, because it came through the
    /// adapter's conversion.
    fn applyLayout(self: *Run) void {
        const state = self.observer.state();
        const window = self.observer.pixelScale().logical;
        const insets = if (state.insets_observed) state.insets else lifecycle.Insets{};
        var rect = lifecycle.contentRect(window, insets);
        // A keyboard that is measurably on screen covers the bottom of the
        // window, so the content rectangle stops at its top edge.
        if (state.keyboard.isOccluding()) {
            const occlusion = state.keyboard.occlusion.?;
            rect[3] = @min(rect[3], occlusion[1]);
            if (rect[3] < rect[1]) rect[3] = rect[1];
        }
        if (std.meta.eql(self.content, rect) and std.meta.eql(self.window_logical, window)) return;
        self.content = rect;
        self.window_logical = window;
        self.view.content = rect;
        self.view.window = window;
        self.observed.layouts += 1;
        // The rectangle the core laid out against moved, so the frame and the
        // published geometry both have to be recomputed.
        self.managed.demand.invalidateLayout();
        self.managed.requestPresentation();
    }

    /// Copy the committed carrier box into the model, so the caret is measured
    /// inside a real layout and the published run and the painted box are one
    /// geometry rather than two that happen to agree today.
    fn syncField(self: *Run) void {
        const tree = self.app.tree_ptr orelse return;
        const view = self.view;
        if (view.field_node == .root) return;
        const rect = nogui.widget.visualBorderRect(tree, view.field_node);
        // The box the model holds is read back through the Session, because
        // the model lives there and this run keeps no copy of it.
        self.refreshField() catch return;
        if (std.meta.eql(self.field.box, rect)) return;
        var request: SetBox = .{ .rect = rect };
        self.session.update(Field, self.field_owner.*, &request, SetBox.apply) catch return;
        self.observed.field_box = rect;
        // The platform control the bridge bound follows the same committed box,
        // so a safe-area move, a keyboard or a rotation takes the real control
        // with the layout it belongs to.
        self.syncProbeGeometry(rect);
        // The caret was measured against the old box, so the cached geometry is
        // stale and the next read must measure again.
        self.app.textInputManager().invalidateGeometry();
    }

    /// Move the owned platform control onto the rectangle the core committed.
    ///
    /// UIKit's own unit is the point the core already publishes in, so the
    /// rectangle crosses unchanged: this is the same conversion `publishScale`
    /// makes for every published bound, and no display scale is invented.
    fn syncProbeGeometry(self: *Run, rect: geometry.WindowRect) void {
        if (comptime native.platform != .ios) return;
        const input = self.probe_input orelse return;
        probeCheck(probe.nogui_w23_probe_frame(
            input,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
        )) catch |err| {
            // The control exists here, so a refusal leaves it sitting over the
            // wrong rectangle with a live binding behind it. That is remembered
            // and fails the run rather than being retried behind the report.
            self.failProbe(err);
            return;
        };
        self.probe_frame = rect;
        self.observed.probe_geometry_syncs += 1;
        self.readProbeState();
    }

    /// Remember a refusal that makes this run a failure.
    ///
    /// The bind is MANDATORY on the target that needs a real control: a run
    /// that could not make one has not exercised the thing it claims to, so it
    /// is reported here and returned once the closing report has been written.
    fn failProbe(self: *Run, err: anyerror) void {
        self.probe_failure = self.probe_failure or err;
    }

    /// Re-measure and re-publish the candidate rectangle when the platform's
    /// copy has been invalidated by a safe-area, keyboard or orientation move.
    fn republishCaret(self: *Run) void {
        if (!self.observer.candidateStale()) return;
        const manager = self.app.textInputManager();
        if (manager.focusedId() == null) return;
        // The layout that just committed is what measures it again, and this is
        // what retires the observer's stale flag: replaying the geometry the
        // platform already holds would clear it without a layout ever running.
        manager.invalidateGeometry();
        const caret = manager.caretGeometry() catch null;
        self.observed.candidate_republishes += 1;
        self.last_caret = if (caret) |box| box.area else null;
    }

    /// Hand the platform the snapshot the App committed with the last frame,
    /// and replay whatever the bridge buffered.
    ///
    /// The App publishes inside the frame it builds, so this builds no tree of
    /// its own: the platform is handed the frame's own publication, and the
    /// generation stamped on that snapshot is the App's own account of which
    /// frame it is. That stamp is what says whether a frame has committed since
    /// the last publication, so no generation is cached here to go stale.
    ///
    /// Order matters: the drain runs FIRST, so a request that changed the model
    /// is in the same publication the next reader sees.
    fn publishSemantics(self: *Run, report: *Reporter) !void {
        const managed = self.managed;
        const snapshot = self.snapshot orelse return;
        // The scale is applied at the native edge and nowhere else. UIKit's own
        // unit is the point the core already publishes in, so its factor is one;
        // Android's node bounds are physical window pixels, so the factor is the
        // window's own measured logical-to-pixel ratio. A display density is a
        // different number and is never used here.
        const scale = managed.observed.pixelScale() catch return;
        self.adapter.setPixelScale(publishScale(scale.x));
        const committed_now = snapshot.generation != self.published_generation;
        const applied = self.adapter.drain(snapshot, &self.dispatcher, self.scratch());
        self.observed.drains_applied += @intCast(applied);
        if (self.adapter.takeDirty()) try self.adapter.layoutChanged();
        if (!committed_now and applied == 0) return;
        self.adapter.publish(snapshot, .{ .focused = managed.observed.focused }) catch |err| {
            try report.emit("semantics: publish refused: {s}\n", .{@errorName(err)});
            return;
        };
        self.observed.publications += 1;
        self.published_generation = snapshot.generation;
        if (applied != 0) {
            // A request that reached the model changed the tree. Ask for the
            // frame that republishes it, rather than leaving the platform on the
            // pre-request snapshot.
            managed.demand.invalidateLayout();
        }
    }

    // ── Frames ─────────────

    fn onFrame(
        context: *anyopaque,
        _: *Application,
        managed: *ManagedWindow,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *Run = @ptrCast(@alignCast(context));
        return self.render(managed);
    }

    /// One committed frame, presented through noapi on this window's own
    /// surface.
    ///
    /// A swapchain that is out of date is not a failure: the frame is retried,
    /// bounded, so a driver that never settles fails the run instead of
    /// spinning. A SUSPENDED app presents nothing: the demand is finished
    /// without a swapchain acquire, because nothing on screen belongs to an app
    /// the platform has taken off the screen, and the resume path re-requests
    /// the frame that does.
    fn render(self: *Run, managed: *ManagedWindow) !bool {
        if (!self.window_live) return true;
        if (!self.observer.scheduled()) {
            self.frames_withheld += 1;
            return true;
        }
        const logical: geometry.WindowSize = .{
            .width = @floatFromInt(managed.observed.size.width),
            .height = @floatFromInt(managed.observed.size.height),
        };
        if (!(logical.width > 0) or !(logical.height > 0)) return true;
        // The window's OWN observed scale, so a glyph, a caret and a published
        // rectangle are one measurement at any device pixel ratio.
        const viewport: NativeFrame.Viewport = .{
            .logical = logical,
            .device = try deviceExtent(managed),
            .scale = try managed.observed.pixelScale(),
        };
        var attempts: u32 = 0;
        while (attempts < 8) : (attempts += 1) {
            // SAFETY: `beginFrame` fills it before this iteration reads it, and a
            // refused begin continues without ever reading it.
            var frame: NativeFrame.Frame = undefined;
            if (!try self.native.adapter.beginFrame(&self.native.surface, viewport, &frame)) {
                self.retries += 1;
                continue;
            }
            var recording = true;
            errdefer if (recording) self.native.adapter.cancelFrame(&frame) catch
                @panic("W23 mobile smoke surface recording cancellation failed");
            const time_ms = sdl3.timer.getMillisecondsSinceInit();
            self.app.dispatchRootFrame(time_ms);
            const out = try self.app.frameWithGpuAtTime(
                self.tick + 1,
                time_ms,
                .{ .width = logical.width, .height = logical.height },
                &frame.gpu_frame,
            );
            // The App publishes this frame's semantics inside the frame, so the
            // snapshot to hand the platform comes back with the frame that
            // produced it. Nothing else in this run commits a tree, so this is
            // the one place the borrowed pointer is set.
            self.snapshot = out.semantic_snapshot;
            defer if (out.json) |json| self.gpa.free(json);
            self.tick += 1;
            var frame_paint = try self.native.adapter.buildScene(.{}, &out);
            defer frame_paint.deinit();
            try self.native.adapter.recordScene(&self.native.surface, &frame, &out, &frame_paint);
            // `present` closes the recording itself, so the guard is dropped
            // BEFORE the call: a present that fails must propagate its own error
            // rather than reach a cancellation of a recording that is gone.
            recording = false;
            try self.native.adapter.present(&self.native.surface, &frame);
            managed.markPresented();
            self.observed.frames += 1;
            return true;
        }
        return error.SwapchainNeverSettled;
    }

    /// The host is about to destroy this window. Everything that presents INTO
    /// it, and everything that borrows it, is retired here, while it still
    /// exists: a surface that outlives its window is exactly what this hook
    /// prevents.
    fn onBeforeClose(context: *anyopaque, _: *ManagedWindow) void {
        const self: *Run = @ptrCast(@alignCast(context));
        self.releaseWindow();
    }

    fn onQuitRequest(_: *anyopaque, _: *Application, _: Application.QuitToken) Application.QuitDecision {
        return .approve;
    }

    /// The one place this window's resources go, in the order the platform
    /// requires. Idempotent, because a platform can retire the window at any
    /// moment and the caller releases again on the way out.
    fn releaseWindow(self: *Run) void {
        if (!self.window_live) return;
        self.window_live = false;
        // The observer borrows the window and must stop consuming before the
        // host destroys it. This is what the host's own hook is for, and the
        // shutdown is what drops the sink and the back policy.
        self.observer.shutdown();
        // The text input is unbound BEFORE the bridge is detached, so a screen
        // reader cannot address a node whose editor has gone, and the window
        // still exists for both calls.
        self.adapter.unbindTextInput();
        self.adapter.detach();
        // The control this run owns is given back AFTER the unbind and AFTER
        // the detach, and BEFORE the host destroys the window. The shim
        // restores the delegate and removes its own control-event target by
        // touching that control, so releasing it first would leave a live proxy
        // pointed at a view that is gone; releasing it last would leave it
        // parented to a window the platform has already torn down.
        self.releaseProbeInput();
        // The closing report outlives the frame adapter, so its numbers are
        // copied out while it is still whole.
        self.stats = self.native.adapter.stats;
        self.target = self.native.adapter.targetExtent();
        self.app.detachGpu();
        self.native.deinit(self.gpa);
        self.retirements += 1;
    }

    // ── The loop ─────────────

    /// One turn of the host loop.
    ///
    /// The observer is the ONLY thing that touches raw SDL input here: it polls
    /// once, observes each event and routes it through the host's own dispatch,
    /// exactly once each, and then reads the platform's polled facts.
    /// `Application.step` follows for task delivery and the ready frames; by
    /// then the queue is empty, so nothing is polled twice over the same event
    /// and no key reaches the model twice.
    fn pumpOnce(self: *Run) !bool {
        const report = self.report;
        self.observed.batch = 0;
        _ = try self.observer.pump(self.application);
        if (self.observed.batch_at_back != 0) {
            self.observed.batch_after_back = self.observed.batch;
        }
        if (!try self.application.step()) {
            self.host_running = false;
            return false;
        }
        // Until the first frame commits there is no tree to focus or to publish,
        // and a closed loop would wait on a demand nobody has made. The
        // presentation is asked for again instead.
        if (self.app.tree_ptr == null and self.observer.scheduled()) {
            self.managed.requestPresentation();
        }
        // A platform can close this window from inside that step, and the host
        // hook retires everything presenting into it. Nothing below this point
        // may touch what was just released.
        if (!self.window_live) return false;
        self.applyLayout();
        self.syncField();
        self.republishCaret();
        try self.publishSemantics(report);
        return true;
    }

    /// One turn plus the platform's own pause between turns.
    fn turn(self: *Run) !bool {
        if (!try self.pumpOnce()) return false;
        try Io.sleep(self.io, Io.Duration.fromMilliseconds(pump_ms), .real);
        return true;
    }

    /// Run one bounded observation phase: pump until `done` says so or the
    /// bound expires, and report honestly which of the two happened.
    ///
    /// `done` is called with the run, so it reads the live machine rather than a
    /// copy this loop could let go stale.
    fn awaitPhase(
        self: *Run,
        comptime done: fn (*Run) bool,
        name: []const u8,
        ms: u64,
    ) !void {
        const started = sdl3.timer.getMillisecondsSinceInit();
        const deadline = started + ms;
        var pumps: u32 = 0;
        var arrived = done(self);
        while (!arrived and sdl3.timer.getMillisecondsSinceInit() < deadline) {
            if (!try self.turn()) break;
            pumps += 1;
            arrived = done(self);
        }
        const waited = sdl3.timer.getMillisecondsSinceInit() - started;
        try self.report.emit(
            "phase={s} outcome={s} waited_ms={d} pumps={d}\n",
            .{ name, if (arrived) "observed" else "not_observed", waited, pumps },
        );
    }

    /// Report a phase whose outcome is already decided, with no wait.
    fn reportNow(self: *Run, name: []const u8, arrived: bool) !void {
        try self.report.emit(
            "phase={s} outcome={s} waited_ms=0 pumps=0\n",
            .{ name, if (arrived) "observed" else "not_observed" },
        );
    }

    // ── The phases ─────────────

    /// Focus the model's field and bind its endpoint, which is the only thing
    /// that starts native text input on this path.
    fn focusField(self: *Run) bool {
        const tree = self.app.tree_ptr orelse return false;
        const id = self.app.widgetIdForKey(.root, key_field) orelse return false;
        if (self.app.focus_manager.current) |current| {
            if (!current.eql(id)) _ = self.app.focus_manager.set(tree, id, self.app.focusObserver());
        } else {
            _ = self.app.focus_manager.set(tree, id, self.app.focusObserver());
        }
        // `registerTextEndpoint` only binds when the identity is the focused
        // one, so it is called after the focus above and after every frame that
        // round-tripped focus away and back.
        if (self.app.textInputManager().focusedId()) |held| {
            if (held.eql(id)) return true;
        }
        self.app.registerTextEndpoint(.{
            .id = id,
            .owner = self.field_owner.weak().erase(),
            .ops = fieldOps(),
            // Inert today — these ops take the `Field` the registration names
            // and ignore the opaque user — and named for the run the platform
            // is holding rather than for this run's own report copy, which a
            // phase refresh rewrites whenever it reads the model.
            .user = self.view.committedField(),
        });
        return self.app.textInputManager().focusedId() != null;
    }

    fn driveOpen(self: *Run) !void {
        const report = self.report;
        const managed = self.managed;
        const driver = sdl3.video.getCurrentDriverName() orelse "<null>";
        const scale = managed.observed.pixelScale() catch
            return error.NoWindowScale;
        try report.emit(
            "window: title=\"{s}\" requested={d}x{d} observed={d}x{d} pixels={d}x{d}" ++
                " scale={d:.3}x{d:.3} video_driver={s}\n",
            .{
                window_title,
                managed.requested.size.width,
                managed.requested.size.height,
                managed.observed.size.width,
                managed.observed.size.height,
                managed.observed.pixels.width,
                managed.observed.pixels.height,
                scale.x,
                scale.y,
                driver,
            },
        );
        try report.emit(
            "target: platform={s} shim={} unit_space={s} publish_scale={s}\n",
            .{
                @tagName(native.platform),
                native.available,
                @tagName(sdl_mobile.unitSpace(native.platform)),
                if (sdl_mobile.unitSpace(native.platform) == .device_pixels)
                    "window pixels"
                else
                    "points (identity)",
            },
        );
        try report.emit(
            "recognizers: touch=platform pinch=platform derived=none" ++
                " (no two-contact gesture is inferred here)\n",
            .{},
        );
        try self.reportNow(
            "open",
            managed.observed.size.width != 0 and managed.observed.size.height != 0,
        );
        try self.detail.line(
            "observed={d}x{d} pixels={d}x{d} surfaces_opened={d}",
            report,
            "open",
            .{
                managed.observed.size.width,
                managed.observed.size.height,
                managed.observed.pixels.width,
                managed.observed.pixels.height,
                self.native.gpu.numSurfaces(),
            },
        );
    }

    fn driveSafeArea(self: *Run, ms: u64) !void {
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observer.state().insets_observed;
            }
        }.done, "safe_area", ms);
        const state = self.observer.state();
        try self.detail.line(
            "observed={} insets=t{:.1},l{:.1},r{:.1},b{:.1} content_rect={:.1},{:.1}..{:.1},{:.1} " ++
                "layouts_applied={d} unanswered_polls={d}",
            self.report,
            "safe_area",
            .{
                state.insets_observed,
                state.insets.top,
                state.insets.left,
                state.insets.right,
                state.insets.bottom,
                self.content[0],
                self.content[1],
                self.content[2],
                self.content[3],
                self.observed.layouts,
                self.observer.unanswered_polls,
            },
        );
    }

    fn driveFocus(self: *Run, ms: u64) !void {
        const report = self.report;
        var occlusion_buffer: [96]u8 = [_]u8{0} ** 96;
        // Focus has to WAIT for a committed tree: an endpoint binds only to an
        // identity the current frame published, and a request for focus on a
        // tree that does not exist yet resolves to nothing. So the binding is
        // retried across turns until the frame lands or the bound expires.
        const started = sdl3.timer.getMillisecondsSinceInit();
        var bound = false;
        while (!bound and sdl3.timer.getMillisecondsSinceInit() - started < ms) {
            bound = self.focusField();
            if (bound) break;
            if (!try self.turn()) break;
        }
        const waited = sdl3.timer.getMillisecondsSinceInit() - started;
        try report.emit(
            "phase=focus outcome={s} waited_ms={d} pumps=0\n",
            .{ if (bound) "observed" else "not_observed", waited },
        );
        try self.detail.line(
            "endpoint_bound={} native_text_input={} native_starts={d} native_stops={d}",
            report,
            "focus",
            .{
                bound,
                self.managed.native.textInputActive(),
                self.trace.starts,
                self.trace.stops,
            },
        );
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observer.state().keyboard.support.isKnown();
            }
        }.done, "keyboard_support", ms);
        const state = self.observer.state();
        try self.detail.line(
            "keyboard_support={s} visible={} occlusion={s} text_input_active={}",
            report,
            "focus",
            .{
                @tagName(state.keyboard.support),
                state.keyboard.visible,
                occlusionText(state.keyboard, &occlusion_buffer),
                self.managed.native.textInputActive(),
            },
        );
    }

    fn driveRotation(self: *Run, ms: u64) !void {
        // The first pixel-scale reading is the window's own initial measurement,
        // not a rotation, so a rotation is a SECOND reading or an orientation
        // event. Neither arriving is a reported fact, not a pass.
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                const seen = &run.observed;
                return seen.pixel_scale >= 2 or seen.orientation != 0;
            }
        }.done, "rotation", ms);
        const state = self.observer.state();
        const scale = self.observer.pixelScale();
        try self.detail.line(
            "orientation={s} pixel_scale_readings={d} logical={:.1}x{:.1} pixels={:.1}x{:.1}" ++
                " candidate_republishes={d}",
            self.report,
            "rotation",
            .{
                @tagName(state.orientation),
                self.observed.pixel_scale,
                scale.logical[0],
                scale.logical[1],
                scale.pixels[0],
                scale.pixels[1],
                self.observed.candidate_republishes,
            },
        );
    }

    fn driveKeyboard(self: *Run, ms: u64) !void {
        var occlusion_buffer: [96]u8 = [_]u8{0} ** 96;
        var scratch_caret: [96]u8 = [_]u8{0} ** 96;
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observer.state().keyboard.occlusion != null;
            }
        }.done, "keyboard", ms);
        const state = self.observer.state();
        try self.detail.line(
            "visible={} occluding={} occlusion={s} keyboard_events={d} layouts={d} " ++
                "candidate_republishes={d} last_caret={s}",
            self.report,
            "keyboard",
            .{
                state.keyboard.visible,
                state.keyboard.isOccluding(),
                occlusionText(state.keyboard, &occlusion_buffer),
                self.observed.keyboard,
                self.observed.layouts,
                self.observed.candidate_republishes,
                caretText(self.last_caret, &scratch_caret),
            },
        );
    }

    fn driveBackground(self: *Run, ms: u64) !void {
        const report = self.report;
        try self.refreshField();
        const text_before = self.field.slice().len;
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observer.state().phase == .background;
            }
        }.done, "background", ms);
        const away = self.observer.state().phase == .background;
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observer.state().phase.isScheduled();
            }
        }.done, "resume", ms);
        try self.refreshField();
        const state = self.observer.state();
        // The acceptance question is whether the DOCUMENT and the FOCUS survived
        // the cycle, so both are read after the resume rather than assumed.
        try self.detail.line(
            "went_background={} scheduled={} phase={s} text_bytes_before={d} after={d} " ++
                "focus_held={} frames_withheld={d}",
            report,
            "background",
            .{
                away,
                state.phase.isScheduled(),
                @tagName(state.phase),
                text_before,
                self.field.slice().len,
                self.app.textInputManager().focusedId() != null,
                self.frames_withheld,
            },
        );
    }

    fn driveBack(self: *Run, ms: u64) !void {
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observed.back_requests != 0;
            }
        }.done, "back", ms);
        const seen = self.observed;
        try self.detail.line(
            "requests={d} source={s} decision={s} consumed={d} dismissed_keyboard={d} " ++
                "deferred={d} handled={d} platform_refused_defers={d}" ++
                " batch_at_back={d} batch_after_back={d} text_input_active={}",
            self.report,
            "back",
            .{
                seen.back_requests,
                @tagName(seen.last_source),
                @tagName(seen.last_decision),
                seen.back_consumed,
                seen.back_dismissed,
                seen.back_deferred,
                seen.back_handled,
                self.observer.refused_defers,
                seen.batch_at_back,
                seen.batch_after_back,
                self.managed.native.textInputActive(),
            },
        );
    }

    fn driveTouch(self: *Run, ms: u64) !void {
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observed.touch_began != 0;
            }
        }.done, "touch", ms);
        const seen = self.observed;
        try self.detail.line(
            "began={d} moved={d} ended={d} cancelled={d} live_contacts={d} refused={d}",
            self.report,
            "touch",
            .{
                seen.touch_began,
                seen.touch_moved,
                seen.touch_ended,
                seen.touch_cancelled,
                self.observer.liveContacts().len,
                self.observer.contacts.refused,
            },
        );
    }

    fn drivePinch(self: *Run, ms: u64) !void {
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observed.pinch_began != 0;
            }
        }.done, "pinch", ms);
        const seen = self.observed;
        try self.detail.line(
            "began={d} updated={d} ended={d} (platform-recognised only; a two-contact " ++
                "scroll is NOT one of these)",
            self.report,
            "pinch",
            .{ seen.pinch_began, seen.pinch_updated, seen.pinch_ended },
        );
    }

    fn driveMemory(self: *Run, ms: u64) !void {
        try self.awaitPhase(struct {
            fn done(run: *Run) bool {
                return run.observed.memory_signal != 0;
            }
        }.done, "memory", ms);
        const state = self.observer.state();
        try self.detail.line(
            "signals={d} polled_level_readings={d} machine_signals={d} machine_reads={d} " ++
                "level={s}",
            self.report,
            "memory",
            .{
                self.observed.memory_signal,
                self.observed.memory_level,
                state.memory_events,
                state.memory_reads,
                @tagName(state.memory),
            },
        );
    }

    fn driveSemantics(self: *Run, report: *Reporter) !void {
        // The iOS framework gives a screen reader no way to type into a synthetic
        // element, so that target needs a real control bound to the published
        // node. Android applies ACTION_SET_TEXT to a virtual node, so a bind is
        // not what makes the field editable there. Which one this build is comes
        // from the target, not from a preference.
        //
        // On iOS the control is not optional and nothing supplies it from
        // outside: this run creates it inside the window SDL owns, owns it, and
        // binds it. A refusal is this run's failure — reported here, and
        // returned once the closing report has said what the run did observe.
        if (native.platform == .ios) {
            self.bindOwnedInput(report) catch |err| {
                self.failProbe(err);
                try report.emit(
                    "semantics: text_input_bind refused: {s}\n",
                    .{@errorName(err)},
                );
            };
        }
        // The snapshot is the one the last committed frame published, and that
        // publication is the one the platform is holding: the bind above moved
        // no tree, so there is no newer snapshot to wait for.
        const snapshot = self.snapshot;
        try self.reportNow(
            "semantics",
            snapshot != null and
                self.observed.publications != 0 and
                self.probe_failure == null,
        );
        try self.detail.line(
            "nodes={d} carried={d} publications={d} generation={d} attached={} state={s} " ++
                "bound_native={d} dropped={d} refused={d} pending={} pixel_scale={d:.3}",
            report,
            "semantics",
            .{
                if (snapshot) |value| value.count() else 0,
                self.adapter.publishedCount(),
                self.observed.publications,
                self.published_generation,
                self.adapter.isAttached(),
                @tagName(self.adapter.stateOf()),
                self.bound_native,
                self.adapter.droppedRequests(),
                self.adapter.refusedRequests(),
                self.adapter.hasPending(),
                self.adapter.scale(),
            },
        );
    }

    /// Make the real platform control this run owns and bind it to the committed
    /// text node.
    ///
    /// Idempotent across the hold: the second `driveSemantics` finds the control
    /// and the binding already made, because the probe refuses a second create
    /// and the adapter refuses a second bind.
    fn bindOwnedInput(self: *Run, report: *Reporter) !void {
        if (self.bound_native != mobile_a11y.no_node) return;
        if (self.probe_input == null) try self.openProbeInput(report);
        try self.bindPlatformInput(report);
    }

    /// Create the real control, inside the window SDL owns, over the rectangle
    /// the core actually committed.
    ///
    /// The window is the one the bridge was attached to, not a window invented
    /// here: a control parented anywhere else is a control the platform can
    /// neither focus nor edit.
    fn openProbeInput(self: *Run, report: *Reporter) !void {
        if (comptime native.platform != .ios) return;
        // A build that carries no fixture says so here rather than by a missing
        // symbol at the first real call. This is a PRESENCE answer, so it is
        // read by `probePresent`: running it through the call-result table would
        // call a fixture that is present a fault and fail every --native run.
        try probePresent(probe.nogui_w23_probe_available());
        const window = uiKitWindow(self.managed.native.sdl) orelse
            return error.NoUiKitWindow;
        const rect = self.committedFieldRect() orelse return error.NoCommittedFieldBox;
        var input: ?*anyopaque = null;
        try probeCheck(probe.nogui_w23_probe_create(
            window,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            &input,
        ));
        const control = input orelse return error.ProbeMadeNoControl;
        self.probe_input = control;
        self.probe_frame = rect;
        self.observed.probe_creates += 1;
        self.readProbeState();
        try report.emit(
            "text_control: owned control created in the SDL window at {d:.1},{d:.1}" ++
                " {d:.1}x{d:.1} points\n",
            .{ rect.x, rect.y, rect.w, rect.h },
        );
    }

    /// Bind the control this run owns to the committed semantic text node.
    ///
    /// The bridge is the only route for that control's edits, so this run does
    /// NOT also forward them through SDL: one edit, one model.
    fn bindPlatformInput(self: *Run, report: *Reporter) !void {
        _ = self.app.tree_ptr orelse return error.NoCommittedTree;
        const control = self.probe_input orelse return error.NoPlatformControl;
        const id = self.app.widgetIdForKey(.root, key_field) orelse return error.MissingFieldIdentity;
        // The semantic identity the CORE mints from this widget, which is what
        // the adapter resolves back to a platform name.
        const semantic = semantics.nodeId(id, .self_node);
        try self.adapter.bindTextInput(control, semantic);
        self.bound_native = self.adapter.boundTextInput();
        // The bind cannot move the tree: it names the node the last committed
        // frame published, and it succeeds at all only because that publication
        // already showed this carrier as an editable text run — the bridge
        // refuses to bind a node it is not showing as one. So there is nothing
        // here to rebuild. This run's annotator publishes the carrier's text
        // run and its text actions — focus, blur, replace, selection and the
        // whole-value `set_value` a screen reader writes with — on every frame,
        // so the node the platform is holding is the node that was just bound,
        // and the frame after the bind publishes that same node again.
        self.readProbeState();
        try report.emit(
            "text_control: bound node={d} frame_aligned={} text_in_sync={}" ++
                " selection_in_sync={}\n",
            .{
                self.bound_native,
                self.observed.probe_frame_aligned,
                self.observed.probe_text_in_sync,
                self.observed.probe_selection_in_sync,
            },
        );
    }

    /// The rectangle the COMMITTED tree gave the field carrier, in window-logical
    /// units.
    ///
    /// This is the same box the model's caret geometry and the published bounds
    /// are measured against, so the platform control, the painted frame and the
    /// published node are one geometry rather than three that happen to agree
    /// today.
    fn committedFieldRect(self: *Run) ?geometry.WindowRect {
        const tree = self.app.tree_ptr orelse return null;
        if (self.view.field_node == .root) return null;
        const rect = nogui.widget.visualBorderRect(tree, self.view.field_node);
        // A rectangle with no area is not somewhere a control could be put.
        if (!(rect.w > 0) or !(rect.h > 0)) return null;
        return rect;
    }

    /// Read back what UIKit actually holds.
    ///
    /// The model's value is UTF-8 and its selection is the protocol's UTF-16;
    /// the control's text is an NSString and its selection is UIKit's own UTF-16
    /// offset. Comparing them HERE is the cross-representation check: the shared
    /// owning UTF-8 model and the native UTF-16 control are one document, or
    /// this records where they parted. A refusal is never read as agreement.
    fn readProbeState(self: *Run) void {
        if (comptime native.platform != .ios) return;
        const input = self.probe_input orelse return;
        // What UIKit holds is compared against the model the Session holds,
        // read back here. A model this run cannot read is a failed run, and it
        // is recorded the way a probe refusal is rather than thrown.
        self.refreshField() catch |err| {
            self.failProbe(err);
            return;
        };
        var x: f64 = 0;
        var y: f64 = 0;
        var w: f64 = 0;
        var h: f64 = 0;
        const frame_result = probeCheck(probe.nogui_w23_probe_read_frame(input, &x, &y, &w, &h));
        const framed = if (frame_result) |_| true else |_| false;
        self.observed.probe_frame_aligned =
            framed and probeFrameMatches(self.probe_frame, x, y, w, h);
        const bytes = self.field.slice();
        self.observed.probe_text_in_sync =
            probe.nogui_w23_probe_text_equals(input, bytes.ptr, bytes.len) == 1;
        var start: i64 = 0;
        var end: i64 = 0;
        const selection_result = probeCheck(probe.nogui_w23_probe_read_selection(input, &start, &end));
        const selected = if (selection_result) |_| true else |_| false;
        self.observed.probe_selection_in_sync =
            selected and start == @as(i64, @intCast(self.field.selection.anchor())) and
            end == @as(i64, @intCast(self.field.selection.cursor()));
    }

    /// Give the owned control back.
    ///
    /// Called after the unbind and after the detach, and before the host destroys
    /// the window: the shim restores the delegate and removes its target by
    /// touching this control, so releasing first would leave a live proxy on a
    /// view that is gone.
    fn releaseProbeInput(self: *Run) void {
        if (comptime native.platform != .ios) return;
        const input = self.probe_input orelse return;
        self.probe_input = null;
        probeCheck(probe.nogui_w23_probe_release(input)) catch |err| {
            self.failProbe(err);
            return;
        };
        self.observed.probe_releases += 1;
    }

    fn driveTeardown(self: *Run, report: *Reporter) !void {
        // The explicit close goes through the host, so the hook retires the
        // observer, the bridge and the surface while the window is still alive.
        if (self.window_live) {
            const released = try self.application.closeWindow(self.handle);
            _ = try self.application.step();
            try report.emit(
                "close: released={} window_count={d} host_running={}\n",
                .{ released, self.application.window_count, self.application.isRunning() },
            );
        } else {
            try report.emit("close: the platform retired this window during the run\n", .{});
        }
        const seen = self.observed;
        try self.reportNow("teardown", self.retirements == 1);
        try self.detail.line(
            "retirements={d} frames={d} withheld={d} retries={d} observer_shutdown={}" ++
                " attached_after={} window_live={} host_running={}",
            report,
            "teardown",
            .{
                self.retirements,
                seen.frames,
                self.frames_withheld,
                self.retries,
                self.observer.closed,
                self.adapter.isAttached(),
                self.window_live,
                self.host_running,
            },
        );
    }
};

/// Everything the run counted, so a reader can see what it did and what it
/// never got. Zeroes here are facts about the run, not missing values.
fn reportCounters(self: *Run, report: *Reporter) !void {
    // The field's own counters are read from the model the Session holds, so
    // the line below describes the model and not a copy this run kept.
    try self.refreshField();
    // The owned control is read ONE LAST TIME here, while it is still alive, so
    // the witnesses below describe the run's final state and not the state at
    // bind time. This runs before the copy below for exactly that reason.
    self.readProbeState();
    const seen = self.observed;
    const stats = self.frameStats();
    const state = self.observer.state();
    // The live adapter's own target while it is live, and the copy taken at
    // retirement once it is gone.
    const target = if (self.window_live) self.native.adapter.targetExtent() else self.target;
    try report.emit(
        "counters: observations={d} safe_area={d} keyboard={d} text_input={d}" ++
            " orientation={d} pixel_scale={d} memory_signal={d} memory_level={d}\n",
        .{
            seen.events,
            seen.safe_area,
            seen.keyboard,
            seen.text_input,
            seen.orientation,
            seen.pixel_scale,
            seen.memory_signal,
            seen.memory_level,
        },
    );
    try report.emit(
        "counters: compositions={d} commits={d} candidates={d} candidate_republishes={d}" ++
            " layouts={d} publications={d} drains_applied={d} frames={d} withheld={d}\n",
        .{
            seen.compositions,
            seen.commits,
            seen.candidates,
            seen.candidate_republishes,
            seen.layouts,
            seen.publications,
            seen.drains_applied,
            seen.frames,
            self.frames_withheld,
        },
    );
    try report.emit(
        "counters: touch(b/m/e/c)={d}/{d}/{d}/{d} pinch(b/u/e)={d}/{d}/{d}" ++
            " back(requests/consumed/dismissed/deferred/handled)={d}/{d}/{d}/{d}/{d}\n",
        .{
            seen.touch_began,
            seen.touch_moved,
            seen.touch_ended,
            seen.touch_cancelled,
            seen.pinch_began,
            seen.pinch_updated,
            seen.pinch_ended,
            seen.back_requests,
            seen.back_consumed,
            seen.back_dismissed,
            seen.back_deferred,
            seen.back_handled,
        },
    );
    try report.emit(
        "observer: generation={d} phase={s} insets_observed={} memory={s}" ++
            " memory_events={d} memory_reads={d} refused_polls={d} unanswered_polls={d}" ++
            " refused_defers={d} live_contacts={d} contacts_refused={d}\n",
        .{
            state.generation,
            @tagName(state.phase),
            state.insets_observed,
            @tagName(state.memory),
            state.memory_events,
            state.memory_reads,
            self.observer.refused_polls,
            self.observer.unanswered_polls,
            self.observer.refused_defers,
            self.observer.liveContacts().len,
            self.observer.contacts.refused,
        },
    );
    try report.emit(
        "native: starts={d} stops={d} areas_published={d} areas_refused={d} clears={d}" ++
            " text_input_active={}\n",
        .{
            self.trace.starts,
            self.trace.stops,
            self.trace.areas,
            self.trace.area_refused,
            self.trace.clears,
            self.managed.native.textInputActive(),
        },
    );
    try report.emit(
        "model: bytes={d} characters={d} caret_reads={d} replacements={d} marks={d}" ++
            " erases={d} moves={d} field_box={s}\n",
        .{
            self.field.slice().len,
            self.field.characters,
            self.field.caret_reads,
            self.field.replacements,
            self.field.marks,
            self.field.erases,
            self.field.moves,
            caretText(seen.field_box, &detail_buffer),
        },
    );
    try report.emit(
        "frame: committed={d} presented={d} resizes={d} swapchains_recreated={d}" ++
            " extent_mismatches={d} present_out_of_date={d} scale_changes={d} target={d}x{d}\n",
        .{
            stats.frames_committed,
            stats.frames_presented,
            stats.resizes_requested,
            stats.swapchains_recreated,
            stats.extent_mismatches,
            stats.present_out_of_date,
            stats.scale_changes,
            target.width,
            target.height,
        },
    );
    try report.emit(
        "accessibility: state={s} attached={} nodes={d} dropped={d} refused={d}" ++
            " pending={} bound_native={d} scale={d:.3}\n",
        .{
            @tagName(self.adapter.stateOf()),
            self.adapter.isAttached(),
            self.adapter.publishedCount(),
            self.adapter.droppedRequests(),
            self.adapter.refusedRequests(),
            self.adapter.hasPending(),
            self.bound_native,
            self.adapter.scale(),
        },
    );
    // What the OWNED control holds RIGHT NOW, read back from UIKit rather than
    // restated from what this run asked for. This line is printed while the
    // control is still parented in SDL's window and still bound to its node, so
    // `releases` is legitimately zero here and nothing here claims otherwise:
    // the release happens inside the host's close hook, during the teardown that
    // runs AFTER this. The ownership witness that brackets one create against
    // one release is printed by `reportOwnership`, once that has happened.
    try report.emit(
        "text_control: live={} creates={d} geometry_syncs={d} releases={d}" ++
            " frame_aligned={} text_in_sync={} selection_in_sync={}" ++
            " model_edits={d} failed={s}\n",
        .{
            self.probe_input != null,
            self.observed.probe_creates,
            self.observed.probe_geometry_syncs,
            self.observed.probe_releases,
            self.observed.probe_frame_aligned,
            self.observed.probe_text_in_sync,
            self.observed.probe_selection_in_sync,
            // Every edit the model accepted, whatever route it took. On iOS
            // that route is the bridge's action path and nothing else.
            self.field.replacements,
            if (self.probe_failure) |err| @errorName(err) else "<none>",
        },
    );
    try report.emit(
        "model_controls: presses={d} flag={} level={d:.1} focus_held={}\n",
        .{
            self.view.presses,
            self.view.flag,
            self.view.level,
            self.app.textInputManager().focusedId() != null,
        },
    );
    try report.emit(
        "not proven by this run: a screen reader actually reading the tree, an input" ++
            " method actually composing, and a real rotation all need the device" ++
            " and a person. A phase reported not_observed is a missing fact, not a pass.\n",
        .{},
    );
}

/// The ownership witness, printed AFTER the teardown.
///
/// The control is given back inside `releaseWindow`, which the host's own close
/// hook runs between the unbind and the surface teardown, so a witness printed
/// before that can only ever print a zero release and calling it balanced would
/// be claiming a fact the run had not reached yet. This reads only what the run
/// owns in its own storage: the window, the application and the bridge are all
/// gone by now and none of them is touched. `balanced` is the claim itself —
/// every control this run created has been given back — and on a target that
/// needs no platform control it is true because nothing was created.
fn reportOwnership(self: *Run, report: *Reporter) !void {
    try report.emit(
        "text_control: ownership after teardown: created={d} released={d} balanced={}" ++
            " still_owned={} retirements={d} window_live={} failed={s}\n",
        .{
            self.observed.probe_creates,
            self.observed.probe_releases,
            self.observed.probe_creates == self.observed.probe_releases,
            self.probe_input != null,
            self.retirements,
            self.window_live,
            if (self.probe_failure) |err| @errorName(err) else "<none>",
        },
    );
}

/// Where `caretText` and `occlusionText` format, so a report line borrows a
/// buffer this run owns rather than allocating one.
var detail_buffer: [96]u8 = [_]u8{0} ** 96;

/// The buffer the semantic drain composes into. One split in two: a row name
/// and a composed text value never need more than this together.
const scratch_size: usize = semantics.Scratch.default_capacity;

/// Copy the committed carrier box into the model.
const SetBox = struct {
    rect: geometry.WindowRect,

    fn apply(field: *Field, context: *anyopaque) anyerror!void {
        const request: *const SetBox = @ptrCast(@alignCast(context));
        field.box = request.rect;
        // The character table is re-measured here so the run this publishes is
        // addressable against the bytes the model currently holds.
        field.measureCharacters();
    }
};

/// The factor every published coordinate is scaled by at the native edge.
///
/// UIKit's own unit is the point the core already publishes in, so its factor
/// is one. Android's node bounds are physical window pixels, so the factor is
/// the window's own measured logical-to-pixel ratio — the same factor the
/// lifecycle conversion uses, and never a display density, which is a different
/// number and would move every published bound off its control.
fn publishScale(window_scale: f32) f32 {
    if (sdl_mobile.unitSpace(native.platform) == .device_pixels) return window_scale;
    return 1;
}

/// A keyboard rectangle in window-logical units, or the fact that there is
/// none. An unmeasured keyboard is not a missing one, so the two read
/// differently.
fn occlusionText(keyboard: lifecycle.Keyboard, buffer: []u8) []const u8 {
    const rect = keyboard.occlusion orelse return "<unmeasured>";
    return std.fmt.bufPrint(buffer, "{:.1},{:.1}..{:.1},{:.1}", .{
        rect[0],
        rect[1],
        rect[2],
        rect[3],
    }) catch "<unformattable>";
}

/// A published caret rectangle, or the fact that none was published.
fn caretText(rect: ?geometry.WindowRect, buffer: []u8) []const u8 {
    const box = rect orelse return "<none>";
    return std.fmt.bufPrint(buffer, "{:.1},{:.1} {:.1}x{:.1}", .{
        box.x,
        box.y,
        box.w,
        box.h,
    }) catch "<unformattable>";
}

// ── The probe ───────────────────────────

/// What a run without a target can honestly say.
///
/// No window, no device, no SDL video, no permission, no platform callback.
/// Every phase is listed with the fact it needs and reported as not run, because
/// a phase that needs a phone cannot be answered by a build that has none.
fn runProbe(report: *Reporter) !void {
    try report.emit("W23 E04/E05 mobile consumer\n", .{});
    try report.emit("mode: PROBE. no window, no device, no SDL video, no permission\n", .{});
    try report.emit(
        "target: platform={s} shim={} unit_space={s} a11y_bridge={}\n",
        .{
            @tagName(native.platform),
            native.available,
            @tagName(sdl_mobile.unitSpace(native.platform)),
            mobile_a11y.available,
        },
    );
    try report.emit(
        "note: this BUILD's platform half is {s}; this does not prove a device is present.\n",
        .{if (native.available) "present" else "absent"},
    );
    try report.emit("phases this run would drive, with the fact each needs:\n", .{});
    for (phases) |phase| {
        try report.emit("  phase={s:<12} not_run  needs: {s}\n", .{ phase.name, phase.needs });
    }
    try report.emit(
        \\build, android:
        \\  zig build -Dtarget=aarch64-linux-android w23-mobile-smoke
        \\  the host module compiles src/v7_host/mobile/shim/nogui_android.c for an
        \\  Android abi already; the APK additionally needs the consumer packaging
        \\  sources in src/v7_demo/w23_mobile_packaging/ (AndroidManifest.xml,
        \\  proguard-rules.pro, and the activity that forwards onTrimMemory). Those
        \\  are sources only: this repository builds no dex and installs no SDK.
        \\  link: log, android, jnigraphics, and the SDL3 static library for the ABI.
        \\
    , .{});
    try report.emit(
        \\build, ios:
        \\  zig build -Dtarget=aarch64-macos-ios w23-mobile-smoke
        \\  the host module compiles src/v7_host/mobile/shim/nogui_ios.m and links
        \\  UIKit and Foundation. No storyboard and no accessibility entitlement
        \\  is involved: the bridge is created from the application's own window.
        \\  This executable additionally compiles its OWN consumer fixture,
        \\  src/v7_demo/w23_mobile_probe.m, on its own root module with
        \\  addCSourceFiles flags "-fobjc-arc" and "-fblocks" and links UIKit and
        \\  Foundation there. The probe includes no host header and calls no host
        \\  symbol, so it needs no include path and links nothing from the shim.
        \\  ARC and blocks are requirements, not preferences: the fixture holds
        \\  its one control in a strong static and the file uses @try/@catch.
        \\  UIKit cannot type into a synthetic accessibility element, so on this
        \\  target the run creates a real UITextField in the window SDL already
        \\  owns and binds it to the committed text node. There is no option to
        \\  name that control: a bind this target cannot make fails the run.
        \\
    , .{});
    try report.emit(
        \\not proven by any run of this binary: a screen reader actually reading the
        \\published tree, an input method actually composing, and a real rotation.
        \\Those need the device and a person. This run reports what it can see.
        \\
    , .{});
}

/// What this run's one field starts holding. The caret sits behind the last
/// character, so the first publication is of a real value and not of an empty
/// string.
const initial_field_text = "mobile";

/// Wire the one field this run edits: the Session model, the view that paints
/// and publishes it, and the root the App draws.
///
/// `Session.create` MOVES the value it is given and leaves the caller's copy
/// undefined, so nothing outside this function may keep a pointer to a `Field`
/// across it. Everything after this point reaches the model through the
/// Session, and this is the only place one is created. The native run and any
/// check that drives the same routes both mount through here, so neither can
/// wire a field the other does not.
fn mountField(
    gpa: std.mem.Allocator,
    session: *Session,
    app: *App,
    view: *View,
) !nogui.Model(Field) {
    var initial: Field = .{ .gpa = gpa };
    try initial.text.appendSlice(gpa, initial_field_text);
    const units = try text_input.utf16Length(initial_field_text);
    initial.selection = .{ .range = .{ .start = units, .end = units } };
    initial.measureCharacters();
    var owner = try session.create(Field, &initial);
    errdefer session.release(Field, &owner) catch
        @panic("W23 mobile smoke could not release the field model");
    // Both readbacks start empty and keep their own capacity from then on, so
    // alternating between them allocates only while the value is growing.
    view.* = .{
        .app = app,
        .session = session,
        .owner = owner,
        .slots = .{ .{ .gpa = gpa }, .{ .gpa = gpa } },
    };
    try app.mountRoot(View, view);
    return owner;
}

// ── The run ───────────────────────────

fn runNative(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    session: *Session,
    app: *App,
    view: *View,
    field_owner: *nogui.Model(Field),
    trace: *NativeTrace,
    application: *Application,
    options: Options,
) !void {
    // The window is opened before anything presenting into it exists, because
    // the surface is created over the window the platform really gave this
    // process.
    const handle = try application.openWindowWithApp(app, .{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .resizable = false,
        .visible = true,
        // The canonical seam for a window that presents through noapi: the host
        // asks SDL for a Vulkan-capable window, which is what
        // `SDL_Vulkan_CreateSurface` requires below. No SDL renderer is created
        // on this window at any point.
        .gpu_surface = true,
    });
    var window_guard = true;
    errdefer if (window_guard) {
        _ = application.closeWindow(handle) catch |err| {
            report.failures += 1;
            std.log.err("window: construction cleanup failed: {s}", .{@errorName(err)});
        };
    };
    const managed = try application.getWindow(handle);

    // The host bound its own native text-input port when the window opened. It
    // is wrapped here so every call the core makes is observable and still
    // reaches SDL: the starts and stops counted by the trace are the ones the
    // text-input manager made because the model's endpoint took and lost focus.
    trace.inner = managed.native.nativeTextInput();
    app.textInputManager().native = trace.port();

    // SAFETY: initialized below; only native_live permits teardown after success.
    var native_half: NativeHalf = undefined;
    var native_live = false;
    defer if (native_live) native_half.deinit(gpa);
    try native_half.init(gpa, io, managed);
    native_live = true;

    // The App measures its layout through the engine that rasterizes the glyphs,
    // so a measured label and a painted glyph are one measurement.
    app.measure = native_half.adapter.measurer();
    try app.attachGpu(native_half.adapter.gpuEndpoint());
    var gpu_attached = true;
    defer if (gpu_attached) app.detachGpu();

    // The bridge keeps a raw pointer to the adapter for its whole lifetime, so
    // it is heap allocated here and never a stack temporary.
    const adapter = try gpa.create(mobile_a11y.Adapter);
    defer gpa.destroy(adapter);
    try adapter.init(gpa, io);
    var adapter_live = true;
    defer if (adapter_live) adapter.deinit();
    // The bridge is attached to the window this run ACTUALLY opened, and
    // `releaseWindow` detaches it before the host destroys that window.
    try adapter.attach(managed.native.sdl);

    // SAFETY: the full record is assigned next before any callback can read it.
    var run: Run = undefined;
    run = .{
        .gpa = gpa,
        .io = io,
        .report = report,
        .session = session,
        .app = app,
        .view = view,
        // The run's own copy of the model, which it fills through the Session
        // and releases through `releaseReadback`.
        .field = .{ .gpa = gpa },
        .field_owner = field_owner,
        // SAFETY: both are filled on the statements below, before any callback
        // can reach either, and neither is read by the literal above.
        .seams = undefined,
        // SAFETY: written on the statement below, before the first drain.
        .dispatcher = undefined,
        .trace = trace,
        .application = application,
        .handle = handle,
        .managed = managed,
        .native = &native_half,
        .adapter = adapter,
        .observer = sdl_mobile.Observer.init(&managed.native, .{
            .managed = managed,
            .session = session,
        }),
        .publisher = semantics.Publisher.init(gpa),
    };
    // The seams borrow the run's own App, Session and ticket, and nothing
    // else: a platform request is answered from the bytes the model holds, so
    // no seam names a readback and no readback has to outlive a request.
    run.seams = .{
        .app = app,
        .session = session,
        .owner = field_owner.*,
    };
    run.dispatcher = makeDispatcher(@ptrCast(&run.seams));
    // Every native callback this run installs is gated on this probe, so one
    // flag retires the sink, the back policy and the bridge together.
    run.owner = .{ .context = &run, .is_alive_fn = Run.sinkProbe };
    // The App publishes inside the frame it builds, so the publisher, the
    // window name and the annotator's context are configured ONCE and stay
    // alive for every frame this run presents. The run never moves and the view
    // it annotates belongs to the caller, so both addresses the App borrows
    // hold until this function returns.
    app.semantic_publication = .{
        .publisher = &run.publisher,
        .window_name = window_title,
        .annotator = .{ .context = view, .annotate = annotate },
    };
    // The guards above owned the pieces while they were being built. This value
    // is whole now, so it owns them and they hand over: one owner, one release.
    native_live = false;
    gpu_attached = false;
    adapter_live = false;
    run.window_live = true;
    window_guard = false;
    // The readback outlives every drain, because the bridge is unbound and
    // detached inside `releaseWindow` below and a late request still reads it.
    defer run.releaseReadback();
    // Release the run before the adapter allocation's earlier defer frees it.
    defer run.releaseWindow();
    // The run owns the publisher the App borrows and the view it annotates is
    // the caller's, so the borrow is dropped before either goes away.
    defer run.publisher.deinit();
    defer app.semantic_publication = null;

    run.observer.setSink(.{ .context = &run, .observe = Run.onObservation });
    run.observer.setBackPolicy(.{ .context = &run, .decide = Run.onBack });

    application.setHooks(.{
        .context = &run,
        .on_frame = Run.onFrame,
        .on_before_close = Run.onBeforeClose,
        .on_quit_request = Run.onQuitRequest,
    });
    try application.start();

    try run.driveOpen();
    try run.driveSafeArea(options.phase_ms);
    try run.driveFocus(options.phase_ms);
    try run.driveRotation(options.phase_ms);
    try run.driveKeyboard(options.phase_ms);
    try run.driveBackground(options.phase_ms);
    try run.driveBack(options.phase_ms);
    try run.driveTouch(options.phase_ms);
    try run.drivePinch(options.phase_ms);
    try run.driveMemory(options.phase_ms);
    try run.driveSemantics(report);
    if (options.hold_ms != 0) {
        const deadline = sdl3.timer.getMillisecondsSinceInit() + options.hold_ms;
        try report.emit("holding {d} ms\n", .{options.hold_ms});
        while (sdl3.timer.getMillisecondsSinceInit() < deadline) {
            if (!try run.turn()) break;
            // A platform can close the window from inside a turn, and the hook
            // retires everything presenting into it.
            if (!run.window_live) break;
        }
        try run.driveSemantics(report);
    }
    // The counters are read while the window is still alive: several of them
    // come off that window's own state, and the SDL window is gone once
    // `driveTeardown` has closed it.
    try reportCounters(&run, report);
    try run.driveTeardown(report);
    // The ownership witness comes LAST, because the release it reports happens
    // inside the close above: printed before the teardown it could only ever say
    // `released=0`, and printing a zero release as balanced would be the run
    // agreeing with itself.
    try reportOwnership(&run, report);
    // A target that could not make — or bind — the real control it needs has
    // not exercised the thing it claims to, so the failure is returned AFTER
    // the closing report has said what the run did observe. Nothing below this
    // line undoes the ordered teardown above.
    if (run.probe_failure) |err| return err;
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var report: Reporter = .{ .io = io };
    const options = (try parseOptions(gpa, init, &report)) orelse return;

    if (!options.native) {
        try runProbe(&report);
        return;
    }

    // The real run needs a mobile target. Saying so here, BEFORE any SDL call,
    // is the honest answer on a machine that has no phone: the mobile adapters
    // compile everywhere and their shims are absent off-target, so a desktop
    // run could only produce an "unsupported" that proves nothing about a
    // device.
    if (!native.available) {
        std.log.err(
            "--native needs an Android or iOS target: this build has no platform shim," ++
                " so every fact the acceptance table needs is absent rather than wrong",
            .{},
        );
        try report.emit(
            "refused: platform={s} shim=absent. Build for aarch64-linux-android or" ++
                " aarch64-macos-ios.\n",
            .{@tagName(native.platform)},
        );
        return error.MobileTargetRequired;
    }

    try report.emit("W23 E04/E05 mobile consumer\n", .{});
    try report.emit(
        "mode: NATIVE. platform={s} unit_space={s} video_driver=default\n",
        .{ @tagName(native.platform), @tagName(sdl_mobile.unitSpace(native.platform)) },
    );

    // Teardown is the reverse of this order: the window is closed by the run
    // above, then the field model, then the host, then the App, then the
    // Session. A released model is exactly what the weak endpoint is designed
    // to survive, so no step borrows a destroyed buffer.
    var session = try Session.init(gpa);
    defer session.deinit() catch @panic("W23 mobile smoke left the Session live");

    var app = try App.init(gpa, &session);
    defer app.deinit();

    var application = try Application.init(gpa, &session, .{
        .app_id = "dev.nogui.w23mobilesmoke",
        .restart = .never,
    });
    defer application.deinit();

    // The view borrows the model the Session holds, and both readbacks it
    // paints and publishes from are released before the App that borrows the
    // view goes.
    // SAFETY: mountField initializes every field before mounting or reading the view.
    var view: View = undefined;
    var owner = try mountField(gpa, &session, &app, &view);
    defer session.release(Field, &owner) catch
        @panic("W23 mobile smoke could not release the field model");
    defer view.releaseReadback();

    var trace: NativeTrace = .{};
    // The outcome is captured rather than propagated straight away: a run that
    // ends early still has to print what it observed and what it did not prove,
    // and the ordered teardown below has to run either way.
    const outcome: ?anyerror = run_outcome: {
        runNative(
            gpa,
            io,
            &report,
            &session,
            &app,
            &view,
            &owner,
            &trace,
            &application,
            options,
        ) catch |err| break :run_outcome err;
        break :run_outcome null;
    };
    try report.emit("W23 E04/E05 mobile consumer done\n", .{});
    if (outcome) |err| return err;
}
