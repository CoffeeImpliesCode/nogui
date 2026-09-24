//! W23 E01/E02/E05 macOS consumer — two real windows, one shared model, and
//! every macOS adapter this tree ships reached through the same public seams
//! the rest of the host uses.
//!
//! WHAT THIS FILE IS. The W23 audit found `src/v7_host/macos/` source-complete
//! and consumer-unreached: the tab registry, the application delegate, the
//! text responder, the find pasteboard, the Services path, the AppKit menu
//! bar, the Dock menu, the recent-documents store, the keychain,
//! UserNotifications, the CVPixelBuffer descriptor and the macOS
//! accessibility attach all existed, and nothing outside their own module
//! called them. This file is the consumer that makes them reachable: one
//! Session, one shared `Document` model, TWO owned `ManagedWindow`s, and every
//! phase below driving an adapter the way a product would.
//!
//! MODES, which do not claim each other's results:
//!
//!   * DEFAULT (no flag). No SDL video, no window, no provider, no permission.
//!     It reports what this BUILD of the target offers — compile-time
//!     availability, whether the AccessKit bridge is linked, the frameworks the
//!     shim needs, the pixel-format table — and prints the exact CLI form of
//!     every gated phase. Safe on a machine with no desktop session.
//!   * `--native`. Opt-in, because it is the only mode that reaches a display
//!     server: two real windows on this session's own driver, real frames
//!     published through the App, and every ungated phase driven for real.
//!     Every platform surface that shows up on somebody's screen or in
//!     somebody else's store is behind its own exact approval flag and value,
//!     named in the usage text and refused BY NAME when absent.
//!
//! WITNESSES, not prints. Every phase reports a READBACK: what the platform
//! returned, compared against what this run asked for. A typed refusal is
//! reported with its own name and is never counted as a pass. The two that
//! carry the most weight:
//!
//!   * TAB READBACK. `merge`, `selectNext`, `selectPrevious` and `detach` all
//!     return the tab GROUP AS APPKIT NOW REPORTS IT, not the call's own
//!     success, and this run prints the group's tab count, whether the window
//!     it asked about is in it, and which window AppKit calls selected.
//!   * INSERTION READBACK. Palette insertions arrive in UTF-16 offsets. They
//!     are applied to the SAME owning `Document` through `Session.update`, the
//!     model is read back out of the Session, the mirror the responder was last
//!     given is read back out of the responder, and the two are compared byte
//!     for byte.
//!   * FRAME READBACK. A real CoreVideo pixel buffer is FILLED through the
//!     write lock the producer owns, described into the shared frame
//!     descriptor, queued in the host's own frame source, uploaded into a
//!     real noapi texture, sampled as one presented quad in the primary
//!     window's own swapchain, and read back out of the Oklab target those
//!     passes wrote. The bytes that come back are compared against the pixels
//!     CoreVideo was filled with, the native release is witnessed exactly
//!     once, and `stop` must report 0 borrowed.
//!
//! WHAT THIS RUN DOES NOT CLAIM, and says so in its own output:
//!   * It never calls `accessibility.requestTrust`. macOS only lets a TRUSTED
//!     process answer accessibility requests, and a process cannot grant
//!     itself that; it stays with a person in System Settings. `isTrusted` is
//!     READ and reported, and a false answer is a fact about this machine.
//!   * It never starts a screen reader. Until one asks for the tree, `stateOf`
//!     says `inactive`, and that is what is printed.
//!   * A Services menu item only exists when the bundle declares an
//!     `NSServices` array. An unbundled executable has none, so `services.menu()`
//!     reports zero and the phase says which prerequisite is missing instead of
//!     pretending a service was sent.
//!   * The data-protection keychain needs a matching keychain-access-group
//!     entitlement. Without one the provider reports `denied`, which is a real
//!     platform answer and is reported by name.
//!   * UserNotifications needs a bundle identifier. Without one the provider
//!     reports `unsupported`, and the phase reports that prerequisite.
//!   * The GPU path needs a Vulkan loader, which on macOS is MoltenVK and is
//!     not part of the system. A run that cannot bind one names the refusal
//!     and records the mandatory frame-adapter proof as UNOBSERVED, which
//!     fails the run rather than reporting a pass it never made.
//!
//! Run it:
//!   default   `zig build w23-macos-smoke`
//!   usage     `zig build w23-macos-smoke -- --help`
//!   native    `zig build w23-macos-smoke -- --native`
//!   hold      `zig build w23-macos-smoke -- --native --hold-ms 4000`
//!
//! Gated phases, each with its own approval and, where the approval is about a
//! value, that value:
//!   --authorize-character-palette              show the system palette panel
//!   --authorize-find-pasteboard <text>         overwrite the Find pasteboard, restore it
//!   --authorize-services-provider <send>,<return>
//!   --authorize-services-invoke <index>        send one Services menu item
//!   --authorize-recent-document <path>         note ONE path, clear an initially empty store
//!   --authorize-keychain <service> <account> <access-group>
//!   --authorize-notification <title>          post one synthetic notification
//!   --authorize-application-visibility         this application's own hide/unhide
//!   --authorize-other-application-visibility   hide/unhide OTHER applications
//!   --authorize-dock-badge <label>            set the Dock badge, then clear it
//!   --authorize-activation-policy <regular|accessory|prohibited>
//!
//! OFF THIS TARGET `--native` is an honest typed refusal: it names every phase
//! it could not drive and exits with `error.MacosTargetRequired`. A
//! non-macOS `Unsupported` is not a macOS result and is never reported as one.

const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const nogui = @import("nogui");
const host = @import("nogui_host");

const Session = nogui.Session;
const App = nogui.App;
const Model = nogui.Model;
const text_input = nogui.text_input;
const action = nogui.action;
const geometry = nogui.geometry;
const Utf16Range = text_input.Utf16Range;
const Selection = text_input.Selection;
const FrameDemand = nogui.frame_demand.FrameDemand;

const Application = host.Application;
const ManagedWindow = host.ManagedWindow;
const contract = host.window_contract;

/// The presented-frame half, reached through the same public seams every
/// other painting run in this tree uses: a `noapi` device and surface the
/// host's window already owns, and `v7_frame.NativeFrame` over them.
const noapi = @import("noapi");
const frame_api = @import("v7_frame");
const NativeFrame = frame_api.NativeFrame;
const SceneRect = frame_api.native.SceneRect;
const no_clip = frame_api.native.no_clip;
/// The SAME conversion the renderer samples in, so the expected readback is
/// computed by the pipeline's own function rather than by a second one.
const srgbToOklab = frame_api.srgbToOklab;

/// The target adapters, reached through the host root exactly as a product
/// binary reaches them.
const macos = host.macos;
const mac_window = host.macos.window;
const mac_application = host.macos.application;
const mac_text = host.macos.text;
const mac_services = host.macos.services;
const mac_menus = host.macos.menus;
const mac_keychain = host.macos.keychain;
const mac_notifications = host.macos.notifications;
const mac_pixels = host.macos.pixel_buffer;
const mac_dialogs = host.macos.dialogs;
const mac_accessibility = host.macos.accessibility;
const frame_source = host.frame_source;
const host_menus = host.menus;
const host_credentials = host.credentials;
const host_notifications = host.notifications;
const host_accessibility = host.accessibility;
const host_dialogs = host.dialogs;

const window_width: u32 = 480;
const window_height: u32 = 320;
const window_width_b: u32 = 420;
const window_height_b: u32 = 260;

/// Synthetic payloads carry no user data. Keyed targets come from approved options.
const keychain_secret = "w23-macos-smoke-synthetic-secret";
const synthetic_path = "/tmp/w23-macos-smoke-synthetic-document.txt";
const notification_body =
    "Synthetic notification posted by the nogui W23 macOS smoke. It carries no user data.";

/// The identifier both windows share, which is what AppKit requires before two
/// windows may tab together at all.
const tab_grouping = "dev.nogui.w23macossmoke.documents";

/// The W10 action the AppKit menu bar dispatches into. It is a real action
/// bound to the SHARED model, so a menu click is proven by the model and not by
/// a counter this file kept.
const BumpAction = action.Action(void, "w23.bump");

/// The Hide row of the application menu. It carries the native ordinal, and
/// it reaches this model because the model registered the name that ordinal
/// derives, so a click on it is proven by the model like every other row.
const HideAction = action.Action(void, host_menus.SystemAction.hide.actionName());

/// The key the focused edit's widget is published under. The text endpoint is
/// registered against the WidgetId the App hands back for this key, so it is
/// an ordinary committed-tree widget and not a private id invented here.
const field_key = "w23-field";

const hold_floor_ms: u64 = 250;
const hold_ceiling_ms: u64 = 60_000;

/// The fixture the CVPixelBuffer phase allocates. Small on purpose: it proves
/// the descriptor, the upload and the presented readback, and every one of its
/// bytes is compared against what CoreVideo was filled with.
const fixture_width: u32 = 64;
const fixture_height: u32 = 32;

/// The colour the fixture is FILLED with, in BGRA memory order, and what makes
/// the readback an equality instead of a tolerance: the WHOLE fixture carries
/// this one colour, so where inside the texture the presented quad samples
/// cannot change the answer. The channels are distinct, so a frame that
/// swapped red and blue on the way through fails.
const probe_pixel: [4]u8 = .{ 0x11, 0x22, 0x33, 0xff };

/// The logical box the probe quad covers in the primary window. It sits at the
/// window's own top-left corner, so the pane's own paint is still visible
/// beside it instead of being covered by the probe.
const probe_box: geometry.WindowRect = .{ .x = 16, .y = 16, .w = 160, .h = 80 };

/// The probe quad's layer. It is above every layer the tree itself emits, so
/// the probe is the last thing painted and nothing can cover the pixels the
/// readback names.
const probe_layer: u32 = 1_000_000;

/// How many acquires one presented frame may spend before the run gives up.
/// A swapchain that never settles is a refusal, not a spin.
const max_frame_attempts: u32 = 8;

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = [_]u8{0} ** 4096,
    checks: u32 = 0,
    failures: u32 = 0,

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }

    /// One hard check against something this run OBSERVED. A refusal is
    /// reported with its own name and is never a pass.
    fn expect(self: *Reporter, label: []const u8, ok: bool) !void {
        self.checks += 1;
        if (!ok) self.failures += 1;
        try self.emit("check {s}: {s}\n", .{ label, if (ok) "pass" else "FAIL" });
    }

    fn expectText(self: *Reporter, label: []const u8, expected: []const u8, actual: []const u8) !void {
        try self.expect(label, std.mem.eql(u8, expected, actual));
        try self.emit("  readback expected=\"{s}\" observed=\"{s}\"\n", .{ expected, actual });
    }
};

// Shared model.

/// One model both windows read and every native action writes back into.
///
/// It is the model the text endpoint is registered against, the model the
/// palette's insertions are applied to, the model the menu action bumps and the
/// model the service route counts. Nothing here holds a second copy of the
/// text: the macOS mirror is published FROM this model and compared back
/// against it.
const Document = struct {
    gpa: std.mem.Allocator,
    /// The focused edit as UTF-8 bytes. The core addresses it in UTF-16 code
    /// units, and both conversions are the core's own helpers.
    text: std.ArrayList(u8) = .empty,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    /// Menu actions the AppKit bridge dispatched into this model.
    bump_count: u32 = 0,
    /// System-action rows the AppKit bridge dispatched into this model.
    hide_count: u32 = 0,
    /// Palette insertions applied to this model.
    insertions_applied: u32 = 0,

    pub fn deinit(self: *Document, _: *Session) void {
        self.text.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn slice(self: *const Document) []const u8 {
        return self.text.items;
    }

    /// The byte range a UTF-16 selection addresses. Both ends go through the
    /// core's own conversion, so an offset naming no character is refused
    /// rather than rounded onto a neighbour.
    fn region(self: *const Document, range: Utf16Range) !struct { start: usize, end: usize } {
        const value = self.slice();
        return .{
            .start = try text_input.utf16ToUtf8(value, @min(range.start, range.end)),
            .end = try text_input.utf16ToUtf8(value, @max(range.start, range.end)),
        };
    }

    /// The UTF-16 unit a byte offset sits at.
    fn unit(self: *const Document, byte: usize) !usize {
        return text_input.utf8ToUtf16(self.slice(), byte);
    }

    fn splice(self: *Document, start: usize, end: usize, bytes: []const u8) !void {
        const value = self.slice();
        if (start > end or end > value.len) return error.SpliceOutOfRange;
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(self.gpa);
        try next.appendSlice(self.gpa, value[0..start]);
        try next.appendSlice(self.gpa, bytes);
        try next.appendSlice(self.gpa, value[end..]);
        self.text.deinit(self.gpa);
        self.text = next;
    }

    fn caretByte(self: *const Document) !usize {
        return (try self.region(.{
            .start = self.selection.cursor(),
            .end = self.selection.cursor(),
        })).start;
    }

    /// A null range means the marked range, else the selection: the single
    /// rule that stops a commit from duplicating its own preedit.
    fn target(self: *const Document, range: ?Utf16Range) Utf16Range {
        return range orelse self.marked orelse self.selection.range;
    }
};

/// The palette payload applied to the owning model. Its offsets are BYTE
/// offsets: the responder converted AppKit's UTF-16 offsets through
/// `mac_text.byteOffsetOfUtf16` before this ever saw them.
const Insertion = struct {
    start: usize,
    length: usize,
    text: []const u8,
};

/// One bounded copy of the model's state, so a readback compares VALUES
/// instead of holding a Session borrow across a native call.
const Snapshot = struct {
    buffer: [512]u8 = [_]u8{0} ** 512,
    len: usize = 0,
    selection: Selection = .{},
    marked: ?Utf16Range = null,
    insertions_applied: u32 = 0,
    bump_count: u32 = 0,
    hide_count: u32 = 0,

    fn slice(self: *const Snapshot) []const u8 {
        return self.buffer[0..self.len];
    }

    fn read(doc: *const Document, out: *Snapshot) void {
        const len = @min(doc.text.items.len, out.buffer.len);
        @memcpy(out.buffer[0..len], doc.text.items[0..len]);
        out.len = len;
        out.selection = doc.selection;
        out.marked = doc.marked;
        out.insertions_applied = doc.insertions_applied;
        out.bump_count = doc.bump_count;
        out.hide_count = doc.hide_count;
    }

    /// The text in UTF-16 code units, for the mirror publication.
    fn units(self: *const Snapshot) !usize {
        return text_input.utf16Length(self.slice());
    }
};

// W12 text endpoint over the shared model.
//
// Ten protocol operations against the SAME `Document` the two windows draw
// and the macOS responder mirrors. Without a registered endpoint the App has no
// focused edit and the responder's mirror would have nothing authoritative to
// hold.

/// The caret grid this consumer publishes. A production field reads its
/// advances from its laid-out text; this run measures no glyphs, and the grid
/// is stated here rather than presented as a measurement.
const advance: f32 = 9;
const line_height: f32 = 20;
const field_origin: geometry.WindowRect = .{ .x = 16, .y = 16, .w = 440, .h = line_height };

/// The start of the code point before `at`.
fn codepointStartBefore(value: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var index = at - 1;
    while (index > 0 and value[index] & 0xc0 == 0x80) index -= 1;
    return index;
}

/// The end of the code point at `at`, clamped to the text.
fn codepointEndAt(value: []const u8, at: usize) usize {
    if (at >= value.len) return value.len;
    return @min(at + (std.unicode.utf8ByteSequenceLength(value[at]) catch 1), value.len);
}

fn documentText(
    gpa: std.mem.Allocator,
    doc: *const Document,
    _: *anyopaque,
    range: Utf16Range,
    served: *Utf16Range,
) anyerror!?[]u8 {
    const region = try doc.region(range);
    served.* = .{ .start = try doc.unit(region.start), .end = try doc.unit(region.end) };
    const copy = try gpa.dupe(u8, doc.slice()[region.start..region.end]);
    return copy;
}

fn documentSelection(doc: *const Document, _: *anyopaque) anyerror!Selection {
    return doc.selection;
}

fn documentMarked(doc: *const Document, _: *anyopaque) anyerror!?Utf16Range {
    return doc.marked;
}

fn documentMove(doc: *Document, _: *anyopaque, request: text_input.Move) anyerror!Selection {
    if (request.offset) |offset| {
        doc.selection = .{ .range = .{ .start = offset, .end = offset } };
        return doc.selection;
    }
    const forward = request.direction == .forward;
    const at = try doc.caretByte();
    const value = doc.slice();
    // One code point per character here. A field that shapes clusters asks its
    // text engine for real grapheme boundaries; this run measures no glyphs and
    // says so rather than claiming a cluster rule it does not have.
    const target: usize = switch (request.unit) {
        .grapheme, .word, .line => if (forward) codepointEndAt(value, at) else codepointStartBefore(value, at),
        .document => if (forward) value.len else 0,
    };
    const next = try doc.unit(target);
    const anchor = doc.selection.anchor();
    doc.selection = if (request.extend)
        .{
            .range = .{ .start = @min(anchor, next), .end = @max(anchor, next) },
            .reversed = next < anchor,
        }
    else
        .{ .range = .{ .start = next, .end = next } };
    return doc.selection;
}

fn documentErase(doc: *Document, _: *anyopaque, request: text_input.Erase) anyerror!void {
    const value = doc.slice();
    const cursor = doc.selection.cursor();
    const at = try doc.caretByte();
    const range = if (request.extend or !doc.selection.range.isEmpty())
        doc.selection.range
    else if (request.backward)
        Utf16Range{ .start = try doc.unit(codepointStartBefore(value, at)), .end = cursor }
    else
        Utf16Range{ .start = cursor, .end = try doc.unit(codepointEndAt(value, at)) };
    const region = try doc.region(range);
    try doc.splice(region.start, region.end, "");
    const caret = try doc.unit(region.start);
    doc.marked = null;
    doc.selection = .{ .range = .{ .start = caret, .end = caret } };
}

fn documentReplace(doc: *Document, _: *anyopaque, range: ?Utf16Range, bytes: []const u8) anyerror!void {
    const region = try doc.region(doc.target(range));
    try doc.splice(region.start, region.end, bytes);
    const caret = try doc.unit(region.start + bytes.len);
    doc.marked = null;
    doc.selection = .{ .range = .{ .start = caret, .end = caret } };
}

fn documentReplaceAndMark(
    doc: *Document,
    _: *anyopaque,
    range: ?Utf16Range,
    bytes: []const u8,
    inside: ?Utf16Range,
) anyerror!void {
    const region = try doc.region(doc.target(range));
    try doc.splice(region.start, region.end, bytes);
    const base = try doc.unit(region.start);
    const length = try text_input.utf16Length(bytes);
    doc.marked = if (bytes.len == 0) null else Utf16Range{ .start = base, .end = base + length };
    const caret = if (inside) |value| base + @min(value.end, length) else base + length;
    doc.selection = .{ .range = .{ .start = caret, .end = caret } };
}

fn documentUnmark(doc: *Document, _: *anyopaque) anyerror!void {
    doc.marked = null;
}

fn documentCaret(_: *Document, _: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
    return .{
        .area = .{
            .x = field_origin.x + advance * @as(f32, @floatFromInt(range.end)),
            .y = field_origin.y,
            .w = 0,
            .h = line_height,
        },
        .cursor = 0,
    };
}

fn documentIndexAt(_: *Document, _: *anyopaque, point: geometry.WindowPoint) anyerror!?usize {
    if (point.y < field_origin.y or point.y > field_origin.y + line_height) return null;
    const column: f32 = @floor((point.x - field_origin.x) / advance + 0.5);
    return @intFromFloat(@max(column, 0));
}

fn documentOps() text_input.Ops {
    return text_input.Adapter(Document).ops(.{
        .text = documentText,
        .selection = documentSelection,
        .marked = documentMarked,
        .move = documentMove,
        .erase = documentErase,
        .replace = documentReplace,
        .replace_and_mark = documentReplaceAndMark,
        .unmark = documentUnmark,
        .caret = documentCaret,
        .index_at = documentIndexAt,
    });
}

/// The W10 action the AppKit menu bar reaches. It bumps the SHARED model, so a
/// menu click shows up in both windows' next published frame.
fn documentBump(doc: *Document, _: *const void, _: *Session) anyerror!void {
    doc.bump_count += 1;
}

fn documentBumpAvailable(doc: *const Document, _: *Session) action.Availability {
    return if (doc.bump_count < 8) .available else .disabled;
}

fn documentHide(doc: *Document, _: *const void, _: *Session) anyerror!void {
    doc.hide_count += 1;
}

/// One window's view. `observed` is the model value its OWN last committed
/// frame was built from, which is what makes "both windows read one model" an
/// observation rather than an intention.
const Pane = struct {
    name: []const u8,
    background: nogui.Color,
    observed: u32 = 0,
    committed: u32 = 0,
    field: nogui.FrameNodeId = .root,

    pub fn draw(self: *Pane, doc: *const Document, ctx: *nogui.DrawCtx) !void {
        self.observed = doc.bump_count;
        self.committed += 1;
        _ = try ctx.column(.{ .grow = 1, .fill = self.background });
        defer ctx.pop();
        const heading = try std.fmt.allocPrint(ctx.arena, "{s} bump={d} inserts={d}", .{
            self.name,
            doc.bump_count,
            doc.insertions_applied,
        });
        _ = try ctx.label(.{ .text = heading, .color = pane_text });
        const live = try std.fmt.allocPrint(ctx.arena, "{}", .{doc.slice()});
        self.field = try ctx.label(.{ .text = live, .color = pane_text });
        _ = try ctx.button(.{
            .key = @as(nogui.ComponentKey, .{ .static = field_key }),
            .label = "w23 field",
        });
    }
};

const pane_background: nogui.Color = .{ 0.10, 0.12, 0.16, 1 };
const pane_text: nogui.Color = .{ 0.94, 0.95, 0.98, 1 };

// Options.

const Options = struct {
    help: bool = false,
    /// Opt in to a real window on this session's own driver.
    native: bool = false,
    hold_ms: u64 = 1_500,

    // Every gated phase names its own approval, and a value where the approval
    // is about one specific value.
    character_palette: bool = false,
    find_pasteboard: ?[]const u8 = null,
    services_provider: ?[]const u8 = null,
    services_invoke: ?usize = null,
    recent_document: ?[]const u8 = null,
    keychain: ?struct { service: []const u8, account: []const u8, group: []const u8 } = null,
    notification: ?[]const u8 = null,
    /// This application's own visibility only. Hiding OTHER applications is a
    /// separate scope below, because it reaches every other app on the
    /// desktop and not just this one.
    application_visibility: bool = false,
    /// `NSApp.hideOtherApplications` / `unhideAllApplications`. Its own
    /// approval, because what it changes belongs to other applications.
    other_application_visibility: bool = false,
    dock_badge: ?[]const u8 = null,
    activation_policy: ?mac_application.ActivationPolicy = null,
};

const usage_text =
    \\usage: w23-macos-smoke [--help]
    \\
    \\  default (no flag): report what this build of the target offers.
    \\    No SDL video, no window, no provider, no permission request.
    \\
    \\  native: --native
    \\    opens two real windows on this session's own driver and drives
    \\    every ungated phase through the shared host seams.
    \\    [--hold-ms <250..60000>]        bounded hold for the window phases
    \\
    \\  gated phases, each needing its own approval and value:
    \\    --authorize-character-palette   show the system character palette
    \\    --authorize-find-pasteboard <text>
    \\        overwrite the Find pasteboard, then restore what was there
    \\    --authorize-services-provider <send-type>,<return-type>
    \\    --authorize-services-invoke <index>
    \\    --authorize-recent-document <path>
    \\        note ONE path, read it back, then clear the whole recent list.
    \\        Refuse before mutation unless that list was initially empty.
    \\    --authorize-keychain <service> <account> <access-group>
    \\    --authorize-notification <title>
    \\    --authorize-application-visibility
    \\        this application's own hide/unhide only
    \\    --authorize-other-application-visibility
    \\        hide/unhide OTHER applications on this desktop
    \\    --authorize-dock-badge <label>
    \\    --authorize-activation-policy <regular|accessory|prohibited>
    \\
    \\  a gated phase without its approval is refused by name, before the
    \\  first native action it would have taken.
;

fn parseOptions(args: *std.process.Args.Iterator, report: *Reporter) !Options {
    var options: Options = .{};
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
            return options;
        } else if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--hold-ms")) {
            const value = args.next() orelse return error.MissingHoldMs;
            options.hold_ms = try std.fmt.parseInt(u64, value, 10);
            if (options.hold_ms < hold_floor_ms or options.hold_ms > hold_ceiling_ms) {
                try report.emit(
                    "--hold-ms {d} is outside {d}..{d}: a shorter hold cannot reach a\n" ++
                        "  person and a longer one owns the desktop\n",
                    .{ options.hold_ms, hold_floor_ms, hold_ceiling_ms },
                );
                return error.HoldOutOfRange;
            }
        } else if (std.mem.eql(u8, arg, "--authorize-character-palette")) {
            options.character_palette = true;
        } else if (std.mem.eql(u8, arg, "--authorize-find-pasteboard")) {
            const value = args.next() orelse return error.MissingFindPasteboardText;
            if (value.len == 0) return error.EmptyFindPasteboardText;
            try report.emit("approval: find pasteboard text=\"{s}\"\n", .{value});
            options.find_pasteboard = value;
        } else if (std.mem.eql(u8, arg, "--authorize-services-provider")) {
            const value = args.next() orelse return error.MissingServiceProviderTypes;
            var parts = std.mem.splitScalar(u8, value, ',');
            const send = parts.next() orelse return error.MissingServiceProviderTypes;
            const back = parts.next() orelse return error.MissingServiceProviderTypes;
            if (send.len == 0 or back.len == 0) return error.EmptyServiceProviderType;
            if (parts.next() != null) return error.InvalidServiceProviderTypes;
            try report.emit(
                "approval: service provider send=\"{s}\" return=\"{s}\"\n",
                .{ send, back },
            );
            options.services_provider = value;
        } else if (std.mem.eql(u8, arg, "--authorize-services-invoke")) {
            const value = args.next() orelse return error.MissingServiceIndex;
            const index = try std.fmt.parseInt(usize, value, 10);
            options.services_invoke = index;
            try report.emit("approval: services invoke index={d}\n", .{index});
        } else if (std.mem.eql(u8, arg, "--authorize-recent-document")) {
            const value = args.next() orelse return error.MissingRecentDocumentPath;
            if (value.len == 0) return error.EmptyRecentDocumentPath;
            try report.emit("approval: recent document path=\"{s}\"\n", .{value});
            options.recent_document = value;
        } else if (std.mem.eql(u8, arg, "--authorize-keychain")) {
            const service = args.next() orelse return error.MissingKeychainService;
            const account = args.next() orelse return error.MissingKeychainAccount;
            const group = args.next() orelse return error.MissingKeychainGroup;
            if (service.len == 0 or account.len == 0 or group.len == 0) {
                return error.EmptyKeychainName;
            }
            try report.emit(
                "approval: keychain service=\"{s}\" account=\"{s}\" access-group=\"{s}\"\n",
                .{ service, account, group },
            );
            options.keychain = .{ .service = service, .account = account, .group = group };
        } else if (std.mem.eql(u8, arg, "--authorize-notification")) {
            const value = args.next() orelse return error.MissingNotificationTitle;
            if (value.len == 0) return error.EmptyNotificationTitle;
            try report.emit("approval: notification title=\"{s}\"\n", .{value});
            options.notification = value;
        } else if (std.mem.eql(u8, arg, "--authorize-application-visibility")) {
            options.application_visibility = true;
        } else if (std.mem.eql(u8, arg, "--authorize-other-application-visibility")) {
            options.other_application_visibility = true;
            try report.emit(
                "approval: other applications' visibility (this reaches every app\n" ++
                    "  on this desktop except this one)\n",
                .{},
            );
        } else if (std.mem.eql(u8, arg, "--authorize-dock-badge")) {
            const value = args.next() orelse return error.MissingDockBadge;
            if (value.len == 0) return error.EmptyDockBadge;
            try report.emit("approval: dock badge=\"{s}\"\n", .{value});
            options.dock_badge = value;
        } else if (std.mem.eql(u8, arg, "--authorize-activation-policy")) {
            const value = args.next() orelse return error.MissingActivationPolicy;
            const policy: mac_application.ActivationPolicy = if (std.mem.eql(u8, value, "regular"))
                .regular
            else if (std.mem.eql(u8, value, "accessory"))
                .accessory
            else if (std.mem.eql(u8, value, "prohibited"))
                .prohibited
            else
                return error.UnknownActivationPolicy;
            try report.emit("approval: activation policy=\"{s}\"\n", .{value});
            options.activation_policy = policy;
        } else {
            try report.emit("unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return options;
}

/// One gated phase's approval state. Absent, the phase is refused BY NAME
/// before any native action it would have taken.
const Approval = struct {
    present: bool,
    flag: []const u8,

    fn require(self: Approval, report: *Reporter, phase: []const u8) !bool {
        if (self.present) return true;
        try report.emit(
            "phase {s}: refused by name; it needs {s}. No native action was taken for it.\n",
            .{ phase, self.flag },
        );
        return false;
    }
};

/// A gated option without `--native` approves a phase that could never run, so
/// it is refused here rather than quietly ignored later.
fn requireNativeForApprovals(options: Options, report: *Reporter) !void {
    if (options.native) return;
    const approvals = [_]struct { flag: []const u8, present: bool }{
        .{ .flag = "--authorize-character-palette", .present = options.character_palette },
        .{ .flag = "--authorize-find-pasteboard", .present = options.find_pasteboard != null },
        .{ .flag = "--authorize-services-provider", .present = options.services_provider != null },
        .{ .flag = "--authorize-services-invoke", .present = options.services_invoke != null },
        .{ .flag = "--authorize-recent-document", .present = options.recent_document != null },
        .{ .flag = "--authorize-keychain", .present = options.keychain != null },
        .{ .flag = "--authorize-notification", .present = options.notification != null },
        .{ .flag = "--authorize-application-visibility", .present = options.application_visibility },
        .{ .flag = "--authorize-other-application-visibility", .present = options.other_application_visibility },
        .{ .flag = "--authorize-dock-badge", .present = options.dock_badge != null },
        .{ .flag = "--authorize-activation-policy", .present = options.activation_policy != null },
    };
    for (approvals) |entry| {
        if (!entry.present) continue;
        try report.emit(
            "{s} needs --native: without it this run opens no window and reaches no AppKit,\n" ++
                "  so the phase it approves could not run at all\n",
            .{entry.flag},
        );
        return error.ApprovalNeedsNative;
    }
}

// Capability report: no SDL, window or provider.

fn reportCapabilities(gpa: std.mem.Allocator, report: *Reporter) !void {
    try report.emit(
        "target: macos available={} accesskit_bridge_linked={}\n",
        .{ macos.available, host_accessibility.linked },
    );
    try report.emit("shim: include=\"{s}\" source=\"{s}\"\n", .{ macos.shim_include, macos.shim_source });
    // `frameworks` is an ARRAY of slices, so it is joined into one slice the
    // `{s}` specifier can actually print rather than formatted as if it were
    // one string.
    const frameworks = try std.mem.join(gpa, ", ", &macos.frameworks);
    defer gpa.free(frameworks);
    try report.emit("frameworks: {s}\n", .{frameworks});

    // `capabilities()` returns the all-false struct without touching the
    // platform when the target is absent, so it is safe here. On a macOS build
    // the live reading asks AppKit about the video driver, the trust fact and
    // the user preferences, all of which need SDL up; that reading belongs to
    // `--native` and is printed there.
    if (!macos.available) {
        const reading = macos.capabilities();
        try report.emit(
            "capabilities: window_tabs={} application_lifecycle={} services={} text_services={}\n" ++
                "  native_menus={} keychain={} user_notifications={} native_dialogs={}\n" ++
                "  pixel_buffer_frames={} native_preferences={} accessibility={} trusted={}\n" ++
                "  dialog_coverage={s}\n",
            .{
                reading.window_tabs,
                reading.application_lifecycle,
                reading.services,
                reading.text_services,
                reading.native_menus,
                reading.keychain,
                reading.user_notifications,
                reading.native_dialogs,
                reading.pixel_buffer_frames,
                reading.native_preferences,
                reading.accessibility,
                reading.accessibility_trusted,
                if (reading.dialog_coverage == null) "absent" else "present",
            },
        );
        try report.emit(
            "off this target every adapter reports a typed unavailability, which is a\n" ++
                "  refusal and not a macOS result. No window and no provider was opened.\n",
            .{},
        );
    } else {
        try report.emit(
            "capabilities: read at run time under --native. This default run initializes no\n" ++
                "  SDL video, so the driver name, the trust fact and the preference reads are\n" ++
                "  deliberately not taken here.\n",
            .{},
        );
    }

    // The per-option coverage beside `native_dialogs`, read through the same
    // public seam a product reaches it by. `coverage` is a PURE function over
    // the shared `FileOptions`: no SDL, no AppKit and no shim, so the answer
    // below is this target's real answer and not a missing-SDK refusal.
    try reportDialogCoverage(report);

    // The pixel-format table is arithmetic over the adapter's own codes, so it
    // is reported wherever this binary builds.
    try report.emit("pixel formats:", .{});
    for ([_]frame_source.PixelFormat{ .bgra8, .rgba8, .rgb8, .r8, .nv12, .yuv420p }) |format| {
        const code = mac_pixels.codeOf(format) orelse continue;
        try report.emit(" {s}=0x{X:0>8}", .{ @tagName(format), code });
    }
    try report.emit("\n", .{});
    try report.emit(
        "not proven here: no window, no provider, no permission, no frame, no native call.\n",
        .{},
    );
}

/// ONE function, TWO halves of the same coverage surface: the file panel and
/// the message box, both answered by the real functions and both reported in
/// the same place, because a host asks about both before it opens either.
///
/// FILE HALF. The request carries a `cancel_label` beside the parts SDL's
/// cocoa backend does read, so a drop is not confused with a request that
/// asked for nothing, and `cancel_label` is the option that backend never
/// reads at all. Every check below reads what `coverage` RETURNED — its
/// counters and the option table it filled — and never restates the request
/// it was handed.
///
/// MESSAGE HALF. `messageCoverage` is asked the same way, but the result is
/// the opposite shape, and the contrast is the point: `MessageOptions`
/// carries no option AppKit cannot express, so a message request with every
/// part filled in names no drop. The differential that proves coverage is
/// still READING the request is the served count, which must follow what was
/// asked rather than stay put.
fn reportDialogCoverage(report: *Reporter) !void {
    const filters = [_]host_dialogs.Filter{.{ .name = "Text", .pattern = "txt" }};
    const asked: host_dialogs.FileOptions = .{
        .mode = .open_file,
        .title = "Open something",
        .accept_label = "Take it",
        .filters = &filters,
        .cancel_label = "Not this one",
    };
    const reading = mac_dialogs.coverage(asked);
    try report.emit("dialogs: the request served={d} dropped={d} full={}\n", .{
        reading.supported,
        reading.unsupported,
        reading.isFull(),
    });
    const dropped = reading.droppedOptions();
    try report.emit("  the platform cannot express:", .{});
    for (dropped) |option| {
        try report.emit(" {s}", .{@tagName(option)});
    }
    try report.emit("\n", .{});

    // The option table coverage FILLED IN is the claim under test, so it is
    // what is compared: one drop, and it is the cancel label.
    try report.expect(
        "dialogs.cancel_label_is_reported_dropped",
        dropped.len == 1 and dropped[0] == .cancel_label and !reading.isFull(),
    );
    // Every drop is named, so a counter can never outrun the table a host
    // reads before it opens the panel.
    try report.expect(
        "dialogs.every_dropped_option_is_named",
        reading.unsupported == dropped.len,
    );

    // The SAME request without the option the backend never reads. A reading
    // that always dropped something fails here, and one that dropped nothing
    // failed above: the two together tie the drop to this option alone.
    const whole: host_dialogs.FileOptions = .{
        .mode = .open_file,
        .title = "Open something",
        .accept_label = "Take it",
        .filters = &filters,
    };
    const without_cancel = mac_dialogs.coverage(whole);
    try report.emit("dialogs: the same request without that label: served={d} dropped={d}\n", .{
        without_cancel.supported,
        without_cancel.unsupported,
    });
    try report.expect(
        "dialogs.that_request_is_whole_and_the_drop_is_the_only_difference",
        without_cancel.isFull() and
            without_cancel.droppedOptions().len == 0 and
            reading.supported == without_cancel.supported and
            reading.supported != 0,
    );
    try report.emit(
        "  a cancel label is DROPPED by the panel, not refused: the request above was\n" ++
            "  accepted and the label never reached a person.\n",
        .{},
    );

    // The message half, asked the same way and answered by the same table.
    // Every part of `MessageOptions` is set here, INCLUDING the per-button
    // default and escape keys, because those are the two the button list
    // carries that a message box has to place on a real key rather than only
    // draw. The window id is a plain number: `messageCoverage` is a pure
    // function of the request, so naming a parent window here opens no
    // window, starts no provider and makes no native call.
    const message_buttons = [_]host_dialogs.MessageButton{
        .{ .id = 1, .text = "Keep", .is_default = true },
        .{ .id = 2, .text = "Discard", .is_escape = true },
    };
    const asked_message: host_dialogs.MessageOptions = .{
        .title = "Discard the change?",
        .message = "The document has edits nobody has saved.",
        .severity = .warning,
        .buttons = &message_buttons,
        .parent_window = 1,
    };
    const message_reading = mac_dialogs.messageCoverage(asked_message);
    const message_dropped = message_reading.droppedOptions();
    try report.emit("messages: the request served={d} dropped={d} full={}\n", .{
        message_reading.supported,
        message_reading.unsupported,
        message_reading.isFull(),
    });
    try report.emit("  the platform cannot express:", .{});
    if (message_dropped.len == 0) try report.emit(" nothing", .{});
    for (message_dropped) |option| {
        try report.emit(" {s}", .{@tagName(option)});
    }
    try report.emit("\n", .{});

    // The claim under test is that a message box has no unservable option, so
    // the table it filled is empty AND its counter agrees with that table. A
    // coverage that dropped something here, or dropped without naming it,
    // fails this.
    try report.expect(
        "messages.every_part_of_the_request_is_served",
        message_reading.isFull() and
            message_dropped.len == 0 and
            message_reading.unsupported == message_dropped.len,
    );

    // The SAME shape with nothing asked for. Severity always counts, so this
    // request is still whole rather than empty, and it is whole for the same
    // reason: there is no option left to lose.
    const bare_reading = mac_dialogs.messageCoverage(.{
        .title = "",
        .message = "",
    });
    try report.emit("messages: the same shape asking for nothing: served={d} dropped={d}\n", .{
        bare_reading.supported,
        bare_reading.unsupported,
    });
    try report.expect(
        "messages.the_bare_request_is_whole_for_the_same_reason",
        bare_reading.isFull() and bare_reading.droppedOptions().len == 0,
    );

    // The differential that keeps this from being a constant function: the
    // two requests differ ONLY in what they asked for, and both are whole, so
    // the served count must move with the request while the dropped count does
    // not. A coverage that stopped reading the request reports one number
    // twice and fails here.
    try report.expect(
        "messages.the_served_count_follows_the_request_and_the_dropped_count_does_not",
        message_reading.supported != bare_reading.supported and
            message_reading.supported > bare_reading.supported and
            bare_reading.supported != 0 and
            message_reading.unsupported == bare_reading.unsupported,
    );

    // Both halves, read in the same run: this request DID ask for a cancel
    // label and the panel could not express it, while the message request
    // asked for everything and nothing was lost. One of these without the
    // other would be a capability claim about half a surface.
    try report.expect(
        "messages.this_run_drops_on_the_file_half_and_not_on_the_message_half",
        message_reading.isFull() and
            message_reading.unsupported == 0 and
            !reading.isFull() and
            reading.unsupported != 0,
    );
    try report.emit(
        "  a file panel and a message box do not fail the same way: only the panel\n" ++
            "  lost an option, and it was still accepted rather than refused.\n",
        .{},
    );
}

// Run.

/// Events the application delegate ring delivered, in drain order. The
/// delegate calls its handler on the host's own thread, so this is a record of
/// what AppKit actually sent.
const DelegateLog = struct {
    seen: [mac_application.queue_limit]mac_application.Event,
    count: usize = 0,

    fn onEvent(context: ?*anyopaque, event: mac_application.Event) void {
        const raw = context orelse return;
        const self: *DelegateLog = @ptrCast(@alignCast(raw));
        if (self.count >= self.seen.len) return;
        self.seen[self.count] = event;
        self.count += 1;
    }
};

/// The owner a notification is bound to. It lives as long as the run, so a
/// late answer is delivered rather than dropped as a dead owner.
const NotificationRecorder = struct {
    received: u32 = 0,

    /// The owner is this record, and the record lives as long as the run, so
    /// an answer arriving at any point in it has a live owner to reach.
    fn alive(_: *const anyopaque) bool {
        return true;
    }

    fn onResponse(
        context: ?*anyopaque,
        id: host_notifications.NotificationId,
        response: host_notifications.Response,
    ) void {
        const raw = context orelse return;
        const self: *NotificationRecorder = @ptrCast(@alignCast(raw));
        self.received += 1;
        switch (response) {
            .action => |activation| std.log.info(
                "w23 notification {d} action {s}",
                .{ id, activation.key },
            ),
            .closed => |closed| std.log.info(
                "w23 notification {d} closed {s}",
                .{ id, @tagName(closed.reason) },
            ),
            .provider_lost => std.log.info("w23 notification {d} provider lost", .{id}),
        }
    }
};

/// Everything one native run owns. Held in ONE heap record, because the shim,
/// the action bridge and the frame hook all keep pointers into it and a run
/// that spread those across two structs would be one refactor away from
/// handing the platform a freed address.
const Run = struct {
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    options: Options,

    session: *Session,
    application: *Application,
    /// The caller's ticket for the shared model. Copied into the Apps' retains
    /// by `mountModelRoot`; released once at teardown.
    owner: Model(Document),

    app_primary: *App,
    app_secondary: *App,
    handle_primary: contract.WindowHandle,
    handle_secondary: contract.WindowHandle,
    pane_primary: *Pane,
    pane_secondary: *Pane,

    registry: mac_window.Registry,
    delegate: *mac_application.Delegate,
    delegate_log: DelegateLog,
    responder: *mac_text.Responder,
    accessibility: *host_accessibility.Adapter,
    menus: *mac_menus.Adapter,
    actions: action.Registry,
    bridge: host_menus.MenuActionBridge,
    recent: host_menus.RecentDocumentsManager,
    keychain: mac_keychain.Provider,
    notifications: *mac_notifications.Provider,
    recorder: *NotificationRecorder,
    /// The SDL window ids this run's two windows carry, read back through the
    /// host. The tab group names windows by these ids, so a readback that
    /// compares against anything else would be comparing two different things.
    window_id_primary: sdl3.video.WindowId = 0,
    window_id_secondary: sdl3.video.WindowId = 0,

    /// Which providers a shared service already owns. A service releases the
    /// provider it was handed, so a second release here would reach a record
    /// that service already retired.
    credentials_provider_retired: bool = false,
    notifications_provider_retired: bool = false,

    frames_primary: u32 = 0,
    frames_secondary: u32 = 0,
    /// Frames the primary window actually PRESENTED through the noapi surface.
    /// A published tree is not a presented pixel, so the two are separate
    /// numbers and neither is read as the other.
    frames_presented: u32 = 0,

    /// The presented-frame half, created by the frames phase. Heap allocated
    /// and never moved, because a live recording is cancelled through its
    /// address. Null until the frames phase builds it, and again after
    /// teardown, which is what routes the frame hook back to the App's own
    /// publication path.
    gpu: ?*GpuHalf = null,
    /// The uploaded CoreVideo probe, present for as long as the presented
    /// frames that sample it are wanted.
    probe: ?Probe = null,

    /// A menu click the shim delivered. It is RECORDED on the AppKit thread and
    /// dispatched by this run's own pump, so the Session is never entered from
    /// inside a platform callback.
    pending_menu_item: ?host_menus.MenuItem = null,
    menu_dispatched: u32 = 0,

    /// Service requests answered by the responder's route, counted atomically
    /// because the platform calls it on AppKit's thread.
    service_answers: std.atomic.Value(u32) = .init(0),

    ax_attached: bool = false,
    ax_refusal: ?anyerror = null,
    /// Whether the window the adapter is attached to has published a frame. The
    /// attach is only meaningful once it has.
    ax_frame_published: bool = false,
    /// Whether the accessibility ADAPTER record has been released. The
    /// adapter is deinited exactly once across both call sites that can reach
    /// it: this file's teardown and `onBeforeClose` when a person closes the
    /// primary window from the titlebar.
    ax_released: bool = false,

    /// Read the shared model out of the Session. Every readback below goes
    /// through this rather than a field this file kept.
    fn snapshot(self: *Run) !Snapshot {
        var out: Snapshot = .{};
        try self.session.read(Document, self.owner, &out, Snapshot.read);
        return out;
    }

    /// Publish the shared model's edit and selection into the responder's
    /// mirror, converting the core's UTF-16 selection into the byte offsets the
    /// adapter takes. This is the ONE place the mirror is written.
    fn publishMirror(self: *Run) !void {
        const current = try self.snapshot();
        const start = try text_input.utf16ToUtf8(current.slice(), current.selection.range.start);
        const end = try text_input.utf16ToUtf8(current.slice(), current.selection.range.end);
        try self.responder.setMirror(current.slice(), .{
            .start = start,
            .length = end - start,
        });
    }
};

// Presented frame.

/// A SPIR-V module read from the build's `shaders/` directory, the same source
/// every other painting run reads. The bytes stay owned for as long as
/// `NativeFrame.init` needs them.
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

/// The Vulkan instance extensions SDL asked for. The loader reads this through
/// the function pointer below while `Gpu.init` builds the instance and not
/// after, so the storage is released as soon as it returns.
var vulkan_extensions: [][*:0]const u8 = &.{};

fn instanceExtensions() []const [*:0]const u8 {
    return vulkan_extensions;
}

/// The device, the surface that presents into the primary window's own
/// swapchain, and the public frame adapter that owns the text engine the App
/// paints with.
///
/// Created in place and never moved: a cancelled recording reaches it by
/// address. noapi creates and owns the platform surface from the SDL window
/// SDL already made, so this file holds no Vulkan handle of its own.
const GpuHalf = struct {
    gpu: noapi.Gpu,
    surface: noapi.Surface,
    adapter: NativeFrame,
    quad_vert: Spv,
    quad_frag: Spv,
    sort_comp: Spv,
    fullscreen_vert: Spv,
    blit_oklab: Spv,

    fn init(self: *GpuHalf, gpa: std.mem.Allocator, io: Io, managed: *ManagedWindow) !void {
        // SAFETY: each field is assigned before use. Error defers are installed
        // only after that field is initialized; failed init never calls deinit.
        self.* = undefined;
        try sdl3.vulkan.loadLibrary(null);
        const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
        const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
        const exts = try gpa.dupe([*:0]const u8, sdl_exts);
        vulkan_extensions = exts;
        defer {
            gpa.free(exts);
            vulkan_extensions = &.{};
        }
        self.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers
            // over three slots, one per in-flight frame.
            .frames_in_flight = frame_api.scene.frames_in_flight,
            .app_name = "w23-macos-smoke",
            .validation = false,
            .loader = .{
                .get_instance_proc_addr = @ptrCast(get_proc_addr),
                .get_instance_extensions = &instanceExtensions,
            },
            .io = io,
            .allocator = gpa,
        });
        errdefer self.gpu.deinit();
        // A platform call, so it can fail; the surface is refused rather than
        // built on an unmeasured size.
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
            .fonts = &.{.{
                .family = "InterVariable",
                .bytes = @embedFile("InterVariable.ttf"),
            }},
            .shaders = .{
                .quad_vert = self.quad_vert.words,
                .quad_frag = self.quad_frag.words,
                .sort_comp = self.sort_comp.words,
                .fullscreen_vert = self.fullscreen_vert.words,
                .blit_oklab = self.blit_oklab.words,
            },
            .name = "w23_macos_smoke_blit_oklab",
        });
    }

    /// TEARDOWN ORDER, the reverse of construction: the frame module retires
    /// its textures and shaders, then the swapchain, then the device the
    /// swapchain lives on. The window is still open throughout — the run
    /// closes it only after this returns.
    fn deinit(self: *GpuHalf, gpa: std.mem.Allocator) void {
        self.adapter.deinit();
        self.surface.deinit();
        self.gpu.deinit();
        self.blit_oklab.deinit(gpa);
        self.fullscreen_vert.deinit(gpa);
        self.sort_comp.deinit(gpa);
        self.quad_frag.deinit(gpa);
        self.quad_vert.deinit(gpa);
        self.* = undefined;
    }
};

/// The window's own pixel size, measured by the platform rather than inferred
/// from the size that was requested. The render area is the acquired image,
/// never the window.
fn deviceExtent(managed: *ManagedWindow) !noapi.Extent2D {
    const pixels = try managed.native.sdl.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

/// The uploaded CoreVideo frame, as the presented frames sample it.
const Probe = struct {
    /// The bindless heap slot the presented quad samples. The heap owns the
    /// texture and destroys it with itself, so nothing here frees it.
    slot: u32,
    /// The Oklab the SOURCE bytes convert to, computed by the pipeline's own
    /// `srgbToOklab`. This is what the presented frame must read back.
    expect: [4]f32,
    /// What the Oklab target the presented passes wrote actually held.
    observed: [4]f32 = .{ 0, 0, 0, 0 },
    /// Whether `observed` is `expect`, bit for bit. The comparison is exact
    /// and is meant to be: the target is `rgba32_float`, the tint is the
    /// identity, the whole fixture is one colour so the sample cannot depend
    /// on where inside the texture it lands, and the blend is
    /// `src_alpha = 1`. Nothing rounds between the upload and the read.
    matched: bool = false,
};

/// One PRESENTED frame for the primary window: the App's committed tree
/// lowered into the Oklab target, the probe quad appended when one is armed,
/// blitted into the acquired swapchain image and presented.
///
/// A swapchain that is out of date is not a failure: the adapter asks for the
/// window's real pixel size and the frame is retried, bounded, so a driver
/// that never settles fails the run instead of spinning.
fn presentWindow(run: *Run, gpu: *GpuHalf, window: *ManagedWindow) !bool {
    const logical: nogui.geometry.WindowSize = .{
        .width = @floatFromInt(window.observed.size.width),
        .height = @floatFromInt(window.observed.size.height),
    };
    const viewport: NativeFrame.Viewport = .{
        .logical = logical,
        .device = try deviceExtent(window),
        .scale = try window.observed.pixelScale(),
    };
    var attempts: u32 = 0;
    while (attempts < max_frame_attempts) : (attempts += 1) {
        // SAFETY: `beginFrame` fills the frame before a recording or a
        // cancellation touches it.
        var surface_frame: NativeFrame.Frame = undefined;
        if (!try gpu.adapter.beginFrame(&gpu.surface, viewport, &surface_frame)) continue;
        var recording = true;
        errdefer if (recording) gpu.adapter.cancelFrame(&surface_frame) catch
            @panic("surface recording cancellation failed");
        // The same root hook every presented path in this tree runs before it
        // commits a frame, so a component's own per-frame work is not skipped
        // by taking the GPU route.
        window.app.dispatchRootFrame(sdl3.timer.getMillisecondsSinceInit());
        run.frames_primary += 1;
        const output = try window.app.frame(run.frames_primary, .{
            .width = logical.width,
            .height = logical.height,
        });
        run.ax_frame_published = output.tree.nodes.items.len != 0;
        var frame_paint = try gpu.adapter.buildScene(.{}, &output);
        defer frame_paint.deinit();
        // The adapter's own documented seam: non-tree drawables go into its
        // retained list between the scene build and the record, sharing the
        // tree's paint order. Appending before the build would leave the
        // scene's own order stamping renumber the probe to slot zero.
        if (run.probe) |probe| try appendProbeRect(run, gpu, probe);
        try gpu.adapter.recordScene(&gpu.surface, &surface_frame, &output, &frame_paint);
        // `present` closes the recording itself, so the guard drops BEFORE the
        // call: a present that fails must propagate its own error rather than
        // reach a cancellation of a recording that is gone.
        recording = false;
        try gpu.adapter.present(&gpu.surface, &surface_frame);
        window.markPresented();
        window.requestPresentation();
        run.frames_presented += 1;
        return true;
    }
    return error.SwapchainNeverSettled;
}

/// Append the probe's one quad to this frame's scene list.
///
/// The list is the adapter's own RETAINED scratch and its capacity survives
/// every frame, so a probe frame allocates nothing. `order` is the list's
/// length at the append — exactly where the tree's own rects stop — and `z` is
/// above every layer the tree emits, so the probe is painted last.
fn appendProbeRect(run: *Run, gpu: *GpuHalf, probe: Probe) !void {
    const rects = &gpu.adapter.sceneScratch().rects;
    const rect: SceneRect = .{
        .dst = .{ probe_box.x, probe_box.y, probe_box.w, probe_box.h },
        .src = .{ 0, 0, 1, 1 },
        .corners = .{ 0, 0, 0, 0 },
        // The identity tint. The fragment shader multiplies the sample by
        // `color`, so white leaves the uploaded Oklab exactly as it was.
        .color = .{ 1, 1, 1, 1 },
        .curve = .{ 0, 0, 0, 0 },
        .material_index = 0,
        .clip_id = no_clip,
        .origin = .{ probe_box.x, probe_box.y },
        .tex_idx = probe.slot,
        .z = probe_layer,
        .order = @intCast(rects.items.len),
    };
    try rects.append(run.gpa, rect);
}

/// Read the Oklab target the PRESENTED passes wrote and compare one device
/// pixel of it against the colour the source bytes convert to.
///
/// `readTarget` copies the target out of the device and waits for it, so these
/// are the pixels the presented frame drew rather than a re-render of the same
/// inputs. The device pixel is the CENTRE of the probe's own box, mapped
/// through the same logical→device scale the renderer used.
fn readProbe(
    run: *Run,
    gpu: *GpuHalf,
    probe: *Probe,
    logical: nogui.geometry.WindowSize,
) !void {
    const pixels = try gpu.adapter.readTarget();
    const extent = gpu.adapter.targetExtent();
    if (extent.width == 0 or extent.height == 0) return error.PresentedTargetEmpty;
    const scale_x = @as(f32, @floatFromInt(extent.width)) / logical.width;
    const scale_y = @as(f32, @floatFromInt(extent.height)) / logical.height;
    const highest_x: f32 = @floatFromInt(extent.width - 1);
    const highest_y: f32 = @floatFromInt(extent.height - 1);
    const centre_x = probe_box.x + probe_box.w / 2;
    const centre_y = probe_box.y + probe_box.h / 2;
    const at_x: usize = @intFromFloat(std.math.clamp(centre_x * scale_x, 0, highest_x));
    const at_y: usize = @intFromFloat(std.math.clamp(centre_y * scale_y, 0, highest_y));
    const at = (at_y * @as(usize, extent.width) + at_x) * 4;
    if (at + 4 > pixels.len) return error.PresentedTargetUnderflow;
    probe.observed = .{ pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3] };
    var same = true;
    for (probe.observed, probe.expect) |observed, expected| {
        if (observed != expected) same = false;
    }
    probe.matched = same;
    try run.report.emit(
        "frames: read back device pixel ({d},{d}) L={d:.6} a={d:.6} b={d:.6} alpha={d:.6}\n" ++
            "  expected from the CoreVideo bytes  L={d:.6} a={d:.6} b={d:.6} alpha={d:.6}\n",
        .{
            at_x,
            at_y,
            probe.observed[0],
            probe.observed[1],
            probe.observed[2],
            probe.observed[3],
            probe.expect[0],
            probe.expect[1],
            probe.expect[2],
            probe.expect[3],
        },
    );
}

// Frame and close hooks.

/// One presented frame for the primary window through the GPU half, and one
/// App-published frame for every other window.
///
/// The published tree is what makes the accessibility attach meaningful, and
/// it is committed either way: the presented path publishes the SAME tree
/// through `App.frame` and then presents the scene that tree lowered into. A
/// frame the run merely published is never reported as a presented pixel.
fn onFrame(
    context: *anyopaque,
    _: *Application,
    window: *ManagedWindow,
    _: FrameDemand.Work,
) anyerror!bool {
    const run: *Run = @ptrCast(@alignCast(context));
    const primary = window.app == run.app_primary;
    if (run.gpu) |gpu| {
        if (primary) return presentWindow(run, gpu, window);
    }
    const output = try window.app.frame(if (primary)
        run.frames_primary + 1
    else
        run.frames_secondary + 1, .{
        .width = @floatFromInt(window.observed.size.width),
        .height = @floatFromInt(window.observed.size.height),
    });
    if (primary) {
        run.frames_primary = output.frame_number;
        run.ax_frame_published = output.tree.nodes.items.len != 0;
    } else {
        run.frames_secondary = output.frame_number;
    }
    window.markPresented();
    return true;
}

/// Detach the accessibility adapter while the platform window is still alive.
/// A window destroyed with the bridge attached would leave its content view
/// subclassed by freed Rust, which is what this hook exists to prevent.
fn onBeforeClose(context: *anyopaque, window: *ManagedWindow) void {
    const run: *Run = @ptrCast(@alignCast(context));
    // The flag is what makes the release EXACTLY ONCE: a person pressing
    // Cmd-W reaches this first and the run's own teardown later sees
    // `ax_released` and leaves the poisoned record alone.
    if (run.ax_attached and window.app == run.app_primary) {
        mac_accessibility.detach(run.accessibility);
        run.ax_attached = false;
        run.ax_released = true;
    }
    // The registry BORROWS the window SDL owns. A window the host is about to
    // destroy must stop being named here, or a later platform callback would
    // resolve to a destroyed NSWindow.
    run.registry.detach(window.native.id);
}

fn onMenuItem(context: ?*anyopaque, item: host_menus.MenuItem) void {
    const raw = context orelse return;
    const run: *Run = @ptrCast(@alignCast(raw));
    run.pending_menu_item = item;
}

// Phases.

/// E01: the tab registry, driven on the two real windows this run owns.
fn phaseTabs(run: *Run) !void {
    const report = run.report;
    const managed_a = try run.application.getWindow(run.handle_primary);
    const managed_b = try run.application.getWindow(run.handle_secondary);
    try run.registry.attach(managed_a.native.sdl);
    try run.registry.attach(managed_b.native.sdl);
    try report.expect("tabs.registry_holds_both_windows", run.registry.count() == 2);

    // A registry entry is a pairing, and an absent one is a real answer rather
    // than a fatal one: it means the host does not own that window.
    const host_window = run.registry.find(managed_a.native.id) orelse
        return error.RegistryLostThePrimaryWindow;
    const guest_window = run.registry.find(managed_b.native.id) orelse
        return error.RegistryLostTheSecondaryWindow;

    // Automatic grouping is an APPLICATION setting and the grouping identifier
    // is a PER-WINDOW one. AppKit refuses a merge when the two disagree, so
    // both are set and the policy is read back rather than assumed.
    try mac_window.setAllowsAutomaticGrouping(true);
    try mac_window.setGroupingIdentifier(host_window, tab_grouping);
    try mac_window.setGroupingIdentifier(guest_window, tab_grouping);
    try mac_window.setTabbingMode(host_window, .preferred);
    try mac_window.setTabbingMode(guest_window, .preferred);

    const mode_read = try mac_window.tabbingMode(host_window);
    const preference = try mac_window.userTabbingPreference();
    try report.expect("tabs.tabbing_mode_readback", mode_read == .preferred);
    try report.emit("tabs: mode_readback={s} user_preference={s} grouping=\"{s}\"\n", .{
        @tagName(mode_read),
        @tagName(preference),
        tab_grouping,
    });

    const merged = try mac_window.merge(
        &run.registry,
        run.gpa,
        managed_a.native.id,
        managed_b.native.id,
        .above,
    );
    try reportTabOutcome(run, "merge", merged);
    try report.expect("tabs.merge_reported_applied", merged == .applied);

    const next = try mac_window.selectNext(&run.registry, run.gpa, managed_a.native.id);
    try reportTabOutcome(run, "select-next", next);
    const previous = try mac_window.selectPrevious(&run.registry, run.gpa, managed_a.native.id);
    try reportTabOutcome(run, "select-previous", previous);

    const detached = try mac_window.detach(&run.registry, run.gpa, managed_b.native.id);
    try reportTabOutcome(run, "detach-guest", detached);
}

fn tabOutcomeName(outcome: mac_window.TabOutcome) []const u8 {
    return switch (outcome) {
        .applied => "applied",
        .not_tabbed => "not_tabbed",
        .not_selected => "not_selected",
        .single_tab => "single_tab",
        .refused => "refused",
        .unsupported => "unsupported",
        .unknown_window => "unknown_window",
    };
}

/// Print a tab operation's outcome AND the group AppKit now reports. The group
/// is the readback: a call reporting `applied` beside a group that does not
/// hold the window it merged are two different facts, and both are printed.
fn reportTabOutcome(run: *Run, label: []const u8, outcome: mac_window.TabOutcome) !void {
    if (outcome != .applied) {
        try run.report.emit("tabs {s}: outcome={s}\n", .{ label, tabOutcomeName(outcome) });
        return;
    }
    const group = outcome.applied;
    defer mac_window.Registry.releaseGroup(&run.registry, run.gpa, group);
    try run.report.emit(
        "tabs {s}: outcome=applied tabs={d} contains_primary={} contains_secondary={}" ++
            " selected={s} truncated={} unmapped={d}\n",
        .{
            label,
            group.count(),
            group.indexOf(run.window_id_primary) != null,
            group.indexOf(run.window_id_secondary) != null,
            if (group.selected) |sel|
                // Anything the run does not own is `other`, never the other
                // owned window. `TabGroup.unmapped` exists precisely because
                // AppKit can select a tab the registry could not name, and
                // calling that `secondary` would be a wrong observation in the
                // one readback the tab acceptance depends on.
                (if (sel == run.window_id_primary)
                    "primary"
                else if (sel == run.window_id_secondary)
                    "secondary"
                else
                    "other")
            else
                "<none>",
            group.truncated,
            group.unmapped,
        },
    );
}

/// E01: the titlebar's own controls and the document metadata, every one read
/// back out of AppKit rather than echoed from what was written.
fn phaseTitlebar(run: *Run) !void {
    const report = run.report;
    const managed = try run.application.getWindow(run.handle_primary);
    const window = run.registry.find(managed.native.id) orelse
        return error.RegistryLostItsWindow;

    const titlebar: mac_window.Titlebar = .{ .window = window };
    try titlebar.setTitle("w23-macos-smoke primary");
    const title = try titlebar.title(run.gpa);
    defer run.gpa.free(title);
    try report.expectText("titlebar.title_readback", "w23-macos-smoke primary", title);

    const wrote_visibility = try titlebar.setVisibility(.visible);
    const read_visibility = try titlebar.visibility();
    try report.expect("titlebar.visibility_readback", wrote_visibility == read_visibility);
    try report.emit("titlebar: visibility={s}\n", .{@tagName(read_visibility)});

    const wrote_transparent = try titlebar.setTransparent(true);
    const read_transparent = try titlebar.transparent();
    try report.expect("titlebar.transparent_readback", wrote_transparent == read_transparent);
    const separator = try titlebar.setSeparator(.line);
    try report.expect("titlebar.separator_readback", separator == .line);
    try report.emit("titlebar: transparent={} separator={s}\n", .{ read_transparent, @tagName(separator) });

    for ([_]mac_window.Button{ .close, .miniaturize, .zoom, .full_screen }) |button| {
        // A button the window's style mask does not have answers
        // `error.Unsupported`, which is a real platform answer and not a
        // reason to abandon the remaining buttons and the nine phases after
        // this one. It is reported by name and skipped.
        const wrote = titlebar.setButtonVisible(button, true) catch |err| {
            try report.emit("titlebar.button {s}: refused {s}; the window's style mask has no such button\n", .{
                @tagName(button),
                @errorName(err),
            });
            continue;
        };
        const read = titlebar.buttonVisible(button) catch |err| {
            try report.emit("titlebar.button {s}: readback refused {s}\n", .{
                @tagName(button),
                @errorName(err),
            });
            continue;
        };
        try report.emit("titlebar.button {s}: wrote={} readback={}\n", .{ @tagName(button), wrote, read });
        try report.expect("titlebar.button_readback", wrote and read);
    }

    const document: mac_window.Document = .{ .window = window };
    _ = try document.setEdited(true);
    const edited = try document.isEdited();
    try report.expect("document.edited_readback", edited);
    // The path is read back out of the window rather than remembered, because
    // a person can change it from the titlebar's proxy icon.
    try document.setPath(synthetic_path);
    const path = try document.path(run.gpa);
    defer run.gpa.free(path);
    try report.expectText("document.path_readback", synthetic_path, path);
}

fn checkActivationPolicy(run: *Run, policy: mac_application.ActivationPolicy) !void {
    const accepted = try mac_application.setActivationPolicy(policy);
    try run.report.expect("application.activation_policy_accepted", accepted);
    const observed = try mac_application.activationPolicy();
    try run.report.expect("application.activation_policy_readback", observed == policy);
    try run.report.emit("application: {s} policy accepted={}\n", .{ @tagName(policy), accepted });
}

fn checkFindText(run: *Run, value: []const u8) !void {
    try mac_text.writeFindText(value);
    const read = try mac_text.readFindText(run.gpa);
    defer run.gpa.free(read);
    try run.report.expectText("text.find_pasteboard_readback", value, read);
}

/// E01: the application delegate, its events drained on this run's own thread,
/// and the lifecycle actions AppKit answers.
fn phaseApplication(run: *Run) !void {
    const report = run.report;
    try run.delegate.attach();

    // Activation is a request; the answer is what AppKit reports afterwards.
    const activated = try mac_application.activate();
    try report.emit("application: activate -> active={}\n", .{activated});

    // Reopen is the action the Quit Applications shortcut uses. AppKit answers
    // it by asking the delegate, which is where the reopen event comes from.
    try mac_application.reopen();
    const delivered = run.delegate.drain(@ptrCast(&run.delegate_log), DelegateLog.onEvent);
    try report.emit(
        "application: delegate installed, drained={d} dropped={d}\n",
        .{ delivered, run.delegate.droppedCount() },
    );
    for (run.delegate_log.seen[0..run.delegate_log.count]) |event| {
        try report.emit("application: event {s}\n", .{event.name()});
    }
    try report.expect("application.delegate_delivered_an_event", delivered != 0);

    const state = try mac_application.state(run.gpa);
    defer run.gpa.free(state.bundle_id);
    try report.emit(
        "application: state active={} hidden={} bundle_id=\"{s}\"\n",
        .{ state.active, state.hidden, state.bundle_id },
    );
    if (state.bundle_id.len == 0) {
        try report.emit(
            "application: no bundle identifier, which is what an unbundled executable has;\n" ++
                "  UserNotifications and the recent-documents store both need one\n",
            .{},
        );
    }

    if (try (Approval{
        .present = run.options.application_visibility,
        .flag = "--authorize-application-visibility",
    }).require(report, "application.visibility")) {
        const hid = try mac_application.hide();
        try report.expect("application.hide_observed", hid and mac_application.isHidden());
        const unhid = try mac_application.unhide();
        try report.expect("application.unhide_observed", unhid and !mac_application.isHidden());
        try report.emit(
            "application: this application's own hide={} unhide={}\n",
            .{ hid, unhid },
        );
    }

    // `hideOthers` / `showAll` reach every OTHER application on this desktop.
    // That is not this run's own window state, so it is not covered by
    // `--authorize-application-visibility`; it carries its own exact approval.
    if (try (Approval{
        .present = run.options.other_application_visibility,
        .flag = "--authorize-other-application-visibility",
    }).require(report, "application.other-application-visibility")) {
        try mac_application.hideOthers();
        try mac_application.showAll();
        try report.emit(
            "application: every OTHER application was hidden and then unhidden, and every\n" ++
                "  one is visible again because `showAll` ran before this returned\n",
            .{},
        );
    }

    if (try (Approval{
        .present = run.options.dock_badge != null,
        .flag = "--authorize-dock-badge",
    }).require(report, "application.dock-badge")) {
        const dock_badge = run.options.dock_badge.?;
        try mac_application.setDockBadge(dock_badge);
        try report.emit("application: dock badge set to \"{s}\"\n", .{dock_badge});
        // A null label clears it, so the run leaves no badge behind.
        try mac_application.setDockBadge(null);
        try report.emit("application: dock badge cleared\n", .{});
    }

    if (try (Approval{
        .present = run.options.activation_policy != null,
        .flag = "--authorize-activation-policy",
    }).require(report, "application.activation-policy")) {
        const policy = run.options.activation_policy.?;
        const baseline = try mac_application.activationPolicy();
        const outcome: ?anyerror = if (checkActivationPolicy(run, policy)) |_| null else |err| err;
        const restored = try mac_application.setActivationPolicy(baseline);
        const observed = try mac_application.activationPolicy();
        try report.expect("application.activation_policy_restored", restored and observed == baseline);
        if (outcome) |err| return err;
    }

    try run.delegate.detach();
    try report.emit("application: delegate detached, SDL's own delegate restored\n", .{});
}

/// E02: the responder, the mirror published from the shared model, and the
/// palette's insertions applied back into that SAME model.
fn phaseText(run: *Run) !void {
    const report = run.report;
    const managed = try run.application.getWindow(run.handle_primary);
    try run.responder.attach(managed.native.sdl);

    // Register the endpoint on this window's own App, so the focused edit is an
    // ordinary core text element rather than a private mirror this file kept.
    const tree = run.app_primary.tree_ptr orelse return error.MissingCommittedTree;
    const field_id = run.app_primary.widgetIdForKey(.root, .{ .static = field_key }) orelse
        return error.FieldWidgetNotPublished;
    _ = run.app_primary.focus_manager.set(tree, field_id, run.app_primary.focusObserver());
    run.app_primary.registerTextEndpoint(.{
        .id = field_id,
        .owner = run.owner.weak().erase(),
        .ops = documentOps(),
        .user = @ptrCast(run),
    });
    try report.expect(
        "text.endpoint_registered_on_focused_widget",
        run.app_primary.textInputManager().focusedId() != null,
    );

    // Publish the model into the mirror, then read the mirror back.
    try run.publishMirror();
    const mirror = run.responder.mirrored();
    const current = try run.snapshot();
    try report.expectText("text.mirror_readback", current.slice(), mirror);

    const units = try current.units();
    try report.emit(
        "text: bytes={d} utf16_units={d} selection={d}..{d}\n",
        .{ current.len, units, current.selection.range.start, current.selection.range.end },
    );

    // The adapter's own UTF-16 -> byte conversion on this model's real text, in
    // both directions, so the mirror's offsets and the model's are demonstrably
    // the same characters.
    const start_byte = mac_text.byteOffsetOfUtf16(current.slice(), 0) orelse
        return error.ZeroUnitHasNoByte;
    try report.expect("text.utf16_zero_maps_to_byte_zero", start_byte == 0);
    const end_byte = mac_text.byteOffsetOfUtf16(current.slice(), units) orelse
        return error.EndUnitHasNoByte;
    try report.expect("text.utf16_end_maps_to_text_end", end_byte == current.len);
    const core_byte = try text_input.utf16ToUtf8(current.slice(), current.selection.range.start);
    try report.expect("text.core_and_adapter_agree_on_selection_start", core_byte == 0);
    // The selection's END is the interesting one: the model addresses it in
    // UTF-16 and the adapter has to land on the same byte. A REFUSED walk is
    // never a pass: it is exactly the case where the two disagree, and this
    // file's own rule is that a typed refusal is reported by name.
    const core_end = try text_input.utf16ToUtf8(current.slice(), current.selection.range.end);
    const adapter_end = mac_text.byteOffsetOfUtf16(current.slice(), current.selection.range.end) orelse {
        try report.emit(
            "text: mac_text.byteOffsetOfUtf16 refused unit {d} of \"{s}\", so the run ends\n" ++
                "  here rather than reporting agreement it never observed\n",
            .{ current.selection.range.end, current.slice() },
        );
        return error.AdapterRefusedSelectionEnd;
    };
    try report.expect("text.core_and_adapter_agree_on_selection_end", adapter_end == core_end);

    // The insertion ring, drained and applied to the owning model. The drain
    // returns at most the ring's own capacity, so "drained <= capacity" is true
    // by construction and proves nothing. What CAN fail is the ring having
    // dropped an insertion: the adapter increments `dropped` instead of growing
    // when it is full, so a non-zero count means a character a person picked
    // was lost, and that is a failure.
    var pending: [mac_text.insert_limit]mac_text.Insertion = undefined;
    const drained = run.responder.drainInsertions(&pending);
    const dropped = run.responder.droppedInsertions();
    try report.emit(
        "text: ring capacity={d} drained={d} dropped={d}\n",
        .{ pending.len, drained, dropped },
    );
    try report.expect("text.no_insertion_was_dropped_by_the_ring", dropped == 0);
    // An insertion only exists if a person picked a character in the palette
    // while this run held. Zero drained is the honest result of a run nobody
    // touched, and it is reported as a count rather than rounded into a pass.
    for (pending[0..drained], 0..) |insertion, index| {
        const payload: Insertion = .{
            .start = insertion.byte_start,
            .length = insertion.byte_length,
            .text = insertion.text,
        };
        try run.session.update(Document, run.owner, &payload, struct {
            fn apply(doc: *Document, user: *const Insertion) anyerror!void {
                try doc.splice(user.start, user.start + user.length, user.text);
                const caret = try doc.unit(user.start + user.text.len);
                doc.selection = .{ .range = .{ .start = caret, .end = caret } };
                doc.insertions_applied += 1;
            }
        }.apply);
        try report.emit(
            "text: applied insertion {d} bytes[{d}..{d})=\"{s}\"\n",
            .{ index, payload.start, payload.start + payload.length, payload.text },
        );
    }

    // After applying anything the mirror is republished from the SAME model and
    // read back, which is the round trip this phase exists for.
    try run.publishMirror();
    const after_model = try run.snapshot();
    const after_mirror = run.responder.mirrored();
    try report.expectText("text.model_and_mirror_agree_after_insertions", after_model.slice(), after_mirror);

    if (try (Approval{
        .present = run.options.character_palette,
        .flag = "--authorize-character-palette",
    }).require(report, "text.character-palette")) {
        // The palette is a system panel shown to a person, and an insertion
        // only arrives if a person picks a character while this run holds; this
        // run never fabricates one. `openCharacterPalette` takes no self and
        // lives inside `Responder`, so it is reached through that type rather
        // than as a module-level function.
        try mac_text.Responder.openCharacterPalette();
        try report.emit(
            "text: character palette shown. Only a person picking a character can produce\n" ++
                "  an insertion, and nothing here invents one.\n",
            .{},
        );
    }

    if (try (Approval{
        .present = run.options.find_pasteboard != null,
        .flag = "--authorize-find-pasteboard",
    }).require(report, "text.find-pasteboard")) {
        const find_text = run.options.find_pasteboard.?;
        const baseline_content = try mac_text.findContent();
        if (baseline_content == .other) {
            try report.emit(
                "text.find-pasteboard: refused before mutation; other flavors must remain untouched\n",
                .{},
            );
            return error.FindPasteboardHasOtherFlavors;
        }
        // Preserve an empty board separately from a declared, empty string.
        // Other flavors, including finder options, are refused above.
        const baseline = try mac_text.readFindText(run.gpa);
        defer run.gpa.free(baseline);
        try report.emit(
            "text: find pasteboard baseline is {d} byte(s)\n",
            .{baseline.len},
        );
        // Restore after either a successful probe or a reported probe failure.
        const outcome: ?anyerror = if (checkFindText(run, find_text)) |_| null else |err| err;
        if (baseline_content == .empty) {
            try mac_text.clearFindText();
            try report.emit("text: find pasteboard restored: it was empty, so it is empty\n", .{});
        } else {
            try mac_text.writeFindText(baseline);
            try report.emit("text: find pasteboard restored to the {d} bytes it held\n", .{baseline.len});
        }
        const restored_content = try mac_text.findContent();
        try report.expect("text.find_pasteboard_flavors_restored", restored_content == baseline_content);
        const restored_text = try mac_text.readFindText(run.gpa);
        defer run.gpa.free(restored_text);
        try report.expectText("text.find_pasteboard_baseline_restored", baseline, restored_text);
        if (outcome) |err| return err;
    }

    // The selection this process offers when it SENDS a service.
    try run.responder.setSelection(after_model.slice());
    const counts = run.responder.serviceCounts();
    try report.emit(
        "text: service route performed={d} answered={d}\n",
        .{ counts.performed, counts.answered },
    );
}

/// E01/E02: the Services menu read in full, and — when approved — both the
/// provider registration and one send.
fn phaseServices(run: *Run) !void {
    const report = run.report;
    const menu = try mac_services.menu();
    try report.emit("services: menu items={d}\n", .{menu.count});
    if (menu.isEmpty()) {
        try report.emit(
            "services: the system published no Services menu. That is what an unbundled\n" ++
                "  executable has; a bundle carrying an NSServices array is the prerequisite.\n",
            .{},
        );
    }
    for (0..menu.count) |index| {
        const label = mac_services.menuLabel(run.gpa, index) catch |err| {
            try report.emit("services: label[{d}] refused: {s}\n", .{ index, @errorName(err) });
            continue;
        };
        defer run.gpa.free(label);
        try report.emit("services: item[{d}]=\"{s}\"\n", .{ index, label });
    }

    if (try (Approval{
        .present = run.options.services_provider != null,
        .flag = "--authorize-services-provider",
    }).require(report, "services.provider")) {
        var types = std.mem.splitScalar(u8, run.options.services_provider.?, ',');
        const service_send_type = types.next().?;
        const service_return_type = types.next().?;
        // Registration needs the responder this run owns AND a route that
        // answers; without a route every request would be declined.
        run.responder.setServiceRoute(.{
            .context = @ptrCast(run),
            .perform = onServicePerform,
        });
        try mac_services.registerProvider(run.responder, .{
            .send_types = &.{service_send_type},
            .return_types = &.{service_return_type},
        });
        try report.emit(
            "services: registered provider send=\"{s}\" return=\"{s}\"\n",
            .{ service_send_type, service_return_type },
        );
    }

    if (run.options.services_invoke) |index| {
        const outcome = try mac_services.invoke(index);
        try report.emit("services: invoke[{d}] -> {s}\n", .{ index, @tagName(outcome) });
        try report.expect("services.invoke_reported_delivered", outcome == .delivered);
        const counts = run.responder.serviceCounts();
        try report.emit(
            "services: after invoke performed={d} answered={d}\n",
            .{ counts.performed, counts.answered },
        );
    } else {
        try report.emit(
            "services: no invoke approved, so no service was sent. Pass\n" ++
                "  --authorize-services-invoke <index> to send one.\n",
            .{},
        );
    }
}

/// The answer an INCOMING service request gets. It writes into the scratch the
/// responder owns and returns how many bytes it wrote, or null to DECLINE. A
/// decline is this application saying it will not answer, which is different
/// from answering with an empty string.
fn onServicePerform(context: ?*anyopaque, request: mac_text.ServiceRequest, scratch: []u8) ?usize {
    const raw = context orelse return null;
    const run: *Run = @ptrCast(@alignCast(raw));
    const approved_types = run.options.services_provider orelse return null;
    const separator = std.mem.indexOfScalar(u8, approved_types, ',') orelse return null;
    if (!std.mem.eql(u8, request.send_type, approved_types[0..separator]) or
        !std.mem.eql(u8, request.return_type, approved_types[separator + 1 ..])) return null;
    if (request.text.len > scratch.len) return null;
    @memcpy(scratch[0..request.text.len], request.text);
    _ = run.service_answers.fetchAdd(1, .monotonic);
    return request.text.len;
}

/// How many documents the platform's own recent list names.
///
/// Newlines SEPARATE entries and do not guarantee a trailing one, so counting
/// newlines alone would read a one-entry store as empty — which is exactly the
/// decision the recent-documents phase refuses on. The walk is the same one
/// `syncRecent` uses: an empty segment is not an entry, and a trailing newline
/// ends the last entry instead of starting another.
fn recentEntryCount(list: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < list.len) {
        const end = std.mem.indexOfScalarPos(u8, list, at, '\n') orelse list.len;
        if (end > at) count += 1;
        if (end >= list.len) break;
        at = end + 1;
    }
    return count;
}

/// E02: the AppKit menu bar and the Dock menu, built from the host's own
/// EVALUATED model and dispatching back into the shared action registry.
fn phaseMenus(run: *Run) !void {
    const report = run.report;
    try run.actions.register(BumpAction);
    try run.actions.register(HideAction);
    _ = try run.actions.bind(
        BumpAction,
        Document,
        documentBump,
        documentBumpAvailable,
        .app,
        run.owner.weak(),
    );
    _ = try run.actions.bind(
        HideAction,
        Document,
        documentHide,
        null,
        .app,
        run.owner.weak(),
    );

    const tree = run.app_primary.tree_ptr orelse return error.MissingCommittedTree;
    const focus = run.app_primary.focus_manager.current;
    const bar: host_menus.MenuBar = .{
        .menus = &.{
            // The application menu is the FIRST top-level entry on macOS and
            // nothing else may claim that slot, which is why it is authored first.
            .{ .title = "W23", .items = &.{
                .{ .id = 1, .label = "Bump Shared Model", .kind = .action, .action_name = BumpAction.name },
                .{ .id = 2, .label = "Hide", .kind = .system_action, .system_action = .hide },
            } },
            .{ .title = "Edit", .items = &.{
                .{ .id = 3, .label = "Bump Shared Model", .kind = .action, .action_name = BumpAction.name },
            } },
        },
    };

    // Enablement is resolved against the LIVE focus context, through the same
    // registry the dispatch uses.
    const evaluated = try run.bridge.evaluate(run.gpa, bar, tree, focus);
    defer evaluated.deinit();
    for (evaluated.menus, 0..) |menu, index| {
        for (menu.items, 0..) |item, item_index| {
            try report.emit(
                "menus: evaluated[{d}].items[{d}] \"{s}\" enabled={} checked={}\n",
                .{ index, item_index, item.label, item.enabled, item.checked },
            );
        }
    }
    const availability = try run.actions.inspect(tree, focus, BumpAction.name);
    try report.emit(
        "menus: action {s} availability={s} on the live focus\n",
        .{ BumpAction.name, @tagName(availability) },
    );

    run.menus.setDispatch(.{ .context = @ptrCast(run), .item = onMenuItem });
    try run.menus.install(&run.bridge, tree, focus, bar);
    try report.emit("menus: AppKit main menu installed from the evaluated model\n", .{});

    // The Dock menu is FLAT: the shim builds it from the top level, and Open
    // Recent is the platform's own submenu rather than a mirror of this host's.
    const dock: host_menus.DockMenu = .{ .items = &.{
        .{ .id = 4, .label = "Bump Shared Model", .kind = .action, .action_name = BumpAction.name },
    } };
    try run.menus.setDockMenu(&run.bridge, tree, focus, dock);
    try report.emit(
        "menus: Dock menu installed with {d} item(s) plus the platform's Open Recent\n",
        .{dock.items.len},
    );

    if (try (Approval{
        .present = run.options.recent_document != null,
        .flag = "--authorize-recent-document",
    }).require(report, "menus.recent-documents")) {
        const recent_path = run.options.recent_document.?;
        // The approval names ONE path. The platform's store is the user's, and
        // the adapter reaches it through NSDocumentController's whole-list
        // clear: there is no per-entry removal to restore with. So the BASELINE
        // is read before anything is mutated, and a store that already holds
        // somebody's documents refuses here rather than clearing them behind
        // an approval that never mentioned them.
        const baseline = try mac_menus.recentList(run.gpa);
        defer mac_menus.freeRecentList(run.gpa, baseline);
        const baseline_entries = recentEntryCount(baseline);
        try report.emit("menus: recent baseline holds {d} entr(ies)\n", .{baseline_entries});
        if (baseline_entries != 0) {
            try report.emit(
                "menus.recent-documents: REFUSED before any mutation. The store already holds\n" ++
                    "  {d} document(s) this run did not put there, and the only removal this\n" ++
                    "  adapter exposes is a whole-list clear, which would delete them under an\n" ++
                    "  approval for one path. Nothing was noted and nothing was cleared.\n",
                .{baseline_entries},
            );
            try report.expect("menus.recent_approval_honoured_without_touching_foreign_entries", false);
        } else {
            try mac_menus.noteRecent(recent_path);
            const list = try mac_menus.recentList(run.gpa);
            defer mac_menus.freeRecentList(run.gpa, list);
            try report.expectText(
                "menus.recent_list_readback",
                recent_path,
                std.mem.trim(u8, list, "\n"),
            );
            try mac_menus.syncRecent(run.gpa, &run.recent);
            try report.emit(
                "menus: host recent store now holds {d} document(s)\n",
                .{run.recent.list().len},
            );
            // The store was empty before this run touched it, so the whole-list
            // clear removes exactly the one entry this run added and nothing
            // else. That is the only case in which reaching for it is safe.
            try mac_menus.clearRecent();
            const after = try mac_menus.recentList(run.gpa);
            defer mac_menus.freeRecentList(run.gpa, after);
            try report.expect(
                "menus.recent_store_back_to_its_baseline",
                recentEntryCount(after) == baseline_entries,
            );
            try report.emit("menus: recent store restored to the {d} entries it held\n", .{baseline_entries});
        }
    }

    const counters = run.menus.counters();
    try report.emit(
        "menus: dispatched={d} recent_chosen={d}\n",
        .{ counters.dispatched, counters.recent },
    );
    try report.expect(
        "menus.no_click_before_a_person_made_one",
        counters.dispatched == run.menu_dispatched,
    );
}

/// E02: the keychain as the shared credential service's provider, for one exact
/// synthetic item, removed again at the end.
fn phaseCredentials(run: *Run) !void {
    const report = run.report;
    if (!try (Approval{
        .present = run.options.keychain != null,
        .flag = "--authorize-keychain",
    }).require(report, "credentials.keychain")) return;
    const approved = run.options.keychain.?;
    const query: host_credentials.CredentialQuery = .{
        .service = approved.service,
        .account = approved.account,
        .collection = approved.group,
    };
    // The service owns the provider from here: its `deinit` disconnects and
    // releases it, so nothing else may hold a reference to it.
    var service = host_credentials.CredentialsService.init(run.gpa, run.keychain.provider());
    defer {
        service.deinit();
        run.credentials_provider_retired = true;
    }
    try report.expect("credentials.provider_connected", run.keychain.isConnected());

    const written = service.write(query, keychain_secret, null);
    try report.expect("credentials.write_accepted", written == .success);
    try report.emit("credentials: wrote service=\"{s}\" account=\"{s}\" group=\"{s}\" -> {s}\n", .{
        approved.service,
        approved.account,
        approved.group,
        @tagName(written),
    });

    // The secret is compared, never printed: a credential that reaches a log is
    // a credential that has leaked.
    const read = service.read(run.gpa, query, null);
    if (read == .found) {
        var secret = read.found;
        defer secret.deinit();
        try report.expect(
            "credentials.read_matches_written",
            std.mem.eql(u8, secret.secret, keychain_secret),
        );
    } else {
        try report.emit("credentials: read -> {s}\n", .{@tagName(read)});
    }

    const deleted = service.delete(query, null);
    try report.expect("credentials.delete_accepted", deleted == .success);
    const after = service.read(run.gpa, query, null);
    try report.expect("credentials.item_gone_after_delete", after == .not_found);
    try report.emit(
        "credentials: synthetic item deleted; readback={s}\n" ++
            "  a group without the matching entitlement is reported as denied, which is a\n" ++
            "  platform answer rather than a missing keychain\n",
        .{@tagName(after)},
    );
}

/// E02: UserNotifications as the shared notification service's provider, for one
/// exact synthetic notification this run dismisses again.
fn phaseNotifications(run: *Run) !void {
    const report = run.report;
    if (!try (Approval{
        .present = run.options.notification != null,
        .flag = "--authorize-notification",
    }).require(report, "notifications")) return;

    try run.notifications.attach();
    try run.notifications.queryAuthorization();
    const authorization = run.notifications.authorizationOf();
    try report.emit(
        "notifications: authorization={s} code={d} may_post={}\n",
        .{ @tagName(authorization), run.notifications.authorizationError(), authorization.mayPost() },
    );
    if (authorization != .authorized) {
        // An APPROVED phase that posted nothing is not a quiet success. A
        // missing bundle identifier is an environment prerequisite, not a
        // person's choice, so it cannot be waved through: the approved work
        // did not happen and the run says so as a failure rather than exiting
        // zero with a summary that cannot tell the two apart.
        try report.emit(
            "notifications: authorization is {s}, so NO request was posted. The provider\n" ++
                "  reports acceptance separately from display, and this run assumes neither.\n" ++
                "  An unbundled executable has no bundle identifier, which is what\n" ++
                "  UserNotifications needs; this is a missing prerequisite, not a pass.\n",
            .{@tagName(authorization)},
        );
        try report.expect("notifications.approved_phase_posted_nothing", false);
        return;
    }

    try run.notifications.setCategory("w23.macos.smoke", &.{
        .{ .key = "acknowledge", .label = "Acknowledge" },
    }, false);

    // The service owns the provider from here: its `deinit` disconnects and
    // releases it.
    var service = host_notifications.NotificationsService.init(
        run.gpa,
        run.notifications.provider(),
    );
    defer {
        service.deinit();
        run.notifications_provider_retired = true;
    }
    const recorder = run.recorder;
    const outcome = service.submit(.{
        .summary = run.options.notification.?,
        .body = notification_body,
        .urgency = .normal,
        .category = "w23.macos.smoke",
        .actions = &.{.{ .key = "acknowledge", .label = "Acknowledge" }},
    }, .{
        .context = @ptrCast(recorder),
        .is_alive_fn = NotificationRecorder.alive,
    }, .{
        .context = @ptrCast(recorder),
        .callback = NotificationRecorder.onResponse,
    });
    switch (outcome) {
        .accepted => |id| {
            try report.emit("notifications: submitted id={d}\n", .{id});
            const closed = service.dismiss(id);
            try report.expect("notifications.dismiss_accepted", closed == .closed);
            try report.emit("notifications: dismissed -> {s}\n", .{@tagName(closed)});
        },
        else => try report.emit("notifications: submit -> {s}\n", .{@tagName(outcome)}),
    }
    try report.emit("notifications: recorder received {d} response(s)\n", .{recorder.received});
}

/// Counts the native releases a frame's `release_fn` actually performed, so
/// "exactly once" is a reading of this run and not an assumption about it.
const ReleaseWitness = struct {
    inner: ?*const fn (?*anyopaque) void = null,
    inner_ctx: ?*anyopaque = null,
    count: u32 = 0,

    fn release(context: ?*anyopaque) void {
        const raw = context orelse return;
        const self: *ReleaseWitness = @ptrCast(@alignCast(raw));
        self.count += 1;
        if (self.inner) |inner| inner(self.inner_ctx);
    }
};

/// The producer's own fill. Every byte of the fixture, stored through the
/// WRITE lock — CoreVideo asked for no permission flag at all, so this mapping
/// is the producer's storage and not a promise not to touch it. A described
/// buffer is locked read-only for the whole life of its frame, which is why
/// the fill happens here and the describe below.
fn fillFixture(_: *anyopaque, plane: mac_pixels.PlaneWrite) mac_pixels.Error!void {
    if (plane.index != 0 or plane.plane_count != 1) return error.BadArgument;
    if (plane.width != fixture_width or plane.height != fixture_height) {
        return error.BadArgument;
    }
    const row_bytes: usize = @as(usize, plane.width) * probe_pixel.len;
    if (@as(usize, plane.stride) < row_bytes) return error.BadArgument;
    for (0..@as(usize, plane.height)) |row| {
        const at: usize = row * @as(usize, plane.stride);
        for (0..@as(usize, plane.width)) |column| {
            @memcpy(plane.base[at + column * probe_pixel.len ..][0..probe_pixel.len], probe_pixel[0..]);
        }
    }
}

/// The descriptor's own bytes, uploaded into a REAL noapi texture in the
/// pipeline's Oklab space, and registered in the frame adapter's bindless heap
/// so a presented quad can sample it.
///
/// This is the host's one upload route: a sampled `rgba32_float` texture
/// written through the staging buffer noapi exposes, then a heap registration.
/// No CPU-side RGBA copy is made, no heap pixel is allocated, and no Vulkan or
/// Metal handle is named here.
fn uploadProbe(gpu: *GpuHalf, gpa: std.mem.Allocator, frame: frame_source.FrameDescriptor) !Probe {
    if (frame.format != .bgra8) return error.UploadNeedsBgra;
    if (frame.plane_count == 0 or frame.width == 0 or frame.height == 0) {
        return error.FrameHasNoLayout;
    }
    const base = frame.pixels orelse return error.FrameWithoutPixels;
    const plane = frame.planes[0];
    const width: usize = frame.width;
    const height: usize = frame.height;
    const stride: usize = frame.stride;
    const row_bytes = width * probe_pixel.len;
    if (stride < row_bytes) return error.FrameStrideTooSmall;
    // Both bounds are checked against the descriptor itself before a byte is
    // read: `pixels` is a raw pointer with no length of its own.
    const span = plane.offset + stride * (height - 1) + row_bytes;
    if (span > plane.size or span > frame.totalBytes()) return error.FrameRowsOutsideThePlane;

    const texture = try gpu.gpu.textureCreate(.{
        .dimensions = .{ frame.width, frame.height, 1 },
        .format = .rgba32_float,
        .usage = .{ .sampled = true },
    });
    // Until the heap takes it below, this texture is only this function's.
    errdefer gpu.gpu.textureDestroy(texture);

    const bytes: u64 = @intCast(width * height * 4 * @sizeOf(f32));
    const staging = try gpu.gpu.gpuMalloc(bytes, 64, .default);
    defer gpu.gpu.gpuFree(staging);
    const out: [*]f32 = @ptrCast(@alignCast(staging.cpu));

    // The expected Oklab is taken from the SOURCE BYTES, not from the colour
    // this file asked to be written, so the readback later compares the
    // pipeline against what CoreVideo actually holds.
    var expect: [4]f32 = .{ 0, 0, 0, 0 };
    var source_matches = true;
    for (0..height) |row| {
        const source = base[plane.offset + row * stride ..][0..row_bytes];
        for (0..width) |column| {
            const pixel = source[column * probe_pixel.len ..][0..probe_pixel.len];
            // BGRA in memory order: byte 0 is BLUE.
            const lab = srgbToOklab(.{
                @as(f32, @floatFromInt(pixel[2])) / 255.0,
                @as(f32, @floatFromInt(pixel[1])) / 255.0,
                @as(f32, @floatFromInt(pixel[0])) / 255.0,
                @as(f32, @floatFromInt(pixel[3])) / 255.0,
            });
            const at = (row * width + column) * 4;
            out[at + 0] = lab[0];
            out[at + 1] = lab[1];
            out[at + 2] = lab[2];
            out[at + 3] = lab[3];
            if (row == 0 and column == 0) {
                expect = lab;
                source_matches = std.mem.eql(u8, pixel[0..], probe_pixel[0..]);
            }
        }
    }

    var command = try gpu.gpu.commandsBegin();
    var command_pending = true;
    errdefer if (command_pending) gpu.gpu.commandsCancel(&command) catch
        @panic("probe upload recording cancellation failed");
    command.copyToTexture(.{
        .gpu = &gpu.gpu,
        .handle = texture,
        .dimensions = .{ frame.width, frame.height, 1 },
        .format = .rgba32_float,
    }, staging, .{ .size = .{ frame.width, frame.height, 1 } });
    try gpu.gpu.queueSubmit(&.{command});
    command_pending = false;
    try gpu.gpu.waitIdle();

    if (!source_matches) return error.SourceBytesAreNotTheFixture;
    // The heap now OWNS the texture and destroys it with itself, so nothing
    // here frees it and no errdefer above may fire.
    return .{
        .slot = try gpu.adapter.textureHeap().register(gpa, texture),
        .expect = expect,
    };
}

/// Build the presented half, or report the refusal that makes the mandatory
/// proof unobserved.
///
/// The refusal is recorded as a FAILURE, not as a skip: the frame adapter is
/// part of what this run exists to prove, and a summary that cannot tell a
/// presented upload from a skipped one is worse than a nonzero exit.
fn createGpuHalf(run: *Run, managed: *ManagedWindow) !*GpuHalf {
    const gpu = try run.gpa.create(GpuHalf);
    errdefer run.gpa.destroy(gpu);
    gpu.init(run.gpa, run.io, managed) catch |err| {
        try run.report.emit(
            "frames: the presented half could not be created: {s}\n" ++
                "  A macOS run needs a Vulkan loader — MoltenVK, which is not part of the\n" ++
                "  system — plus the build's compiled shader modules. Neither is gated on a\n" ++
                "  person, so the mandatory frame-adapter proof below is UNOBSERVED.\n",
            .{@errorName(err)},
        );
        try run.report.expect("frames.presented_upload_reached_the_window", false);
        return err;
    };
    return gpu;
}

/// E02: a real CoreVideo pixel buffer filled through the producer's own write
/// lock, described into the shared frame descriptor, queued in the host's own
/// frame source, uploaded into a REAL noapi texture, presented in the primary
/// window's own swapchain and read back out of the Oklab target those passes
/// wrote — with the native release witnessed exactly once.
fn phaseFrames(run: *Run) !void {
    const report = run.report;
    const managed = try run.application.getWindow(run.handle_primary);

    // From here the primary window presents through this half, so the frames
    // the later holds paint are real presented pixels rather than published
    // trees.
    run.gpu = try createGpuHalf(run, managed);

    // The producer's buffer. One reference is the caller's; `describe` takes a
    // second for the frame, which is what `releaseReference` below balances.
    const buffer = mac_pixels.create(fixture_width, fixture_height, .bgra8) orelse {
        try report.emit(
            "frames: CVPixelBufferCreate refused a {d}x{d} BGRA buffer, so nothing below\n" ++
                "  was observed and the frame-adapter proof is UNOBSERVED\n",
            .{ fixture_width, fixture_height },
        );
        try report.expect("frames.corevideo_pixel_buffer_was_created", false);
        return error.PixelBufferNotObtainable;
    };
    defer mac_pixels.releaseReference(buffer);

    try mac_pixels.writePixels(buffer, @ptrCast(run), fillFixture);
    try report.emit(
        "frames: filled {d}x{d} BGRA through the write lock: B=0x{X:0>2} G=0x{X:0>2} R=0x{X:0>2} A=0x{X:0>2}\n",
        .{
            fixture_width,
            fixture_height,
            probe_pixel[0],
            probe_pixel[1],
            probe_pixel[2],
            probe_pixel[3],
        },
    );

    var witness: ReleaseWitness = .{};
    var source = frame_source.FrameSource.init(run.gpa, run.io, 2);
    // Retire on every exit, reporting failures even when another phase failed.
    var source_live = true;
    defer if (source_live) {
        source.deinit() catch |err| {
            report.failures += 1;
            std.log.err("frames: source retirement failed: {s}", .{@errorName(err)});
        };
    };

    const described = try mac_pixels.describe(run.gpa, buffer, .borrowed);
    // The descriptor must be mutable so this run can install its release witness.
    var frame: mac_pixels.FrameDescriptor = switch (described) {
        .frame => |value| value,
        else => |refusal| {
            // Every one of these is the adapter NAMING what CoreVideo or the
            // allocator answered, and every one of them leaves the mandatory
            // frame-adapter proof unobserved.
            switch (refusal) {
                .format_unsupported => |code| try report.emit(
                    "frames: CoreVideo format 0x{X:0>8} has no layout this adapter describes;\n" ++
                        "  the frame-adapter proof is UNOBSERVED\n",
                    .{code},
                ),
                .not_cpu_addressible => try report.emit(
                    "frames: the buffer is GPU-backed, so it is not CPU addressable and no\n" ++
                        "  IOSurface is imported behind the host's back; the proof is UNOBSERVED\n",
                    .{},
                ),
                .lock_failed => try report.emit(
                    "frames: CoreVideo refused the read lock; the proof is UNOBSERVED\n",
                    .{},
                ),
                .out_of_range => try report.emit(
                    "frames: a plane does not live inside the buffer's own allocation; the\n" ++
                        "  proof is UNOBSERVED\n",
                    .{},
                ),
                .geometry_invalid => try report.emit(
                    "frames: the geometry cannot be expressed as one descriptor; the proof is\n" ++
                        "  UNOBSERVED\n",
                    .{},
                ),
                .out_of_memory => try report.emit(
                    "frames: the descriptor's own allocation failed; the proof is UNOBSERVED\n",
                    .{},
                ),
                // The outer prong proved this is not the frame case.
                .frame => unreachable,
            }
            return error.FrameNotDescribable;
        },
    };
    try report.emit(
        "frames: described {d}x{d} format={s} stride={d} colour={s} alpha={s} planes={d}\n",
        .{
            frame.width,
            frame.height,
            @tagName(frame.format),
            frame.stride,
            @tagName(frame.color_space),
            @tagName(frame.alpha_type),
            frame.plane_count,
        },
    );
    try report.expect(
        "frames.geometry_matches_request",
        frame.width == fixture_width and frame.height == fixture_height,
    );
    try report.expect("frames.format_is_bgra8", frame.format == .bgra8);

    // The descriptor's release is wrapped, so the number of native releases is
    // a reading of this run rather than an assumption.
    const inner = frame.release_fn orelse return error.FrameWithoutRelease;
    witness.inner = inner;
    witness.inner_ctx = frame.release_ctx;
    frame.release_fn = ReleaseWitness.release;
    frame.release_ctx = @ptrCast(&witness);

    try source.pushFrame(frame);
    var acquired = source.acquireLatest() orelse return error.SourceDeliveredNothing;
    try report.emit(
        "frames: source queued={d} dropped={d} outstanding={d}\n",
        .{ source.total_pushed, source.total_dropped, source.outstandingFrames() },
    );

    const gpu = run.gpu.?;
    var probe = try uploadProbe(gpu, run.gpa, acquired);
    try report.emit(
        "frames: uploaded {d}x{d} BGRA into a sampled rgba32_float texture and registered it at\n" ++
            "  bindless heap slot {d}; the bytes came from the descriptor, not a copy\n",
        .{ acquired.width, acquired.height, probe.slot },
    );

    // The frame goes back through the source, which settles its accounting and
    // runs the wrapped release exactly once.
    source.releaseFrame(&acquired);
    try report.expect("frames.no_frame_still_outstanding", source.outstandingFrames() == 0);
    try report.expect("frames.native_release_ran_exactly_once", witness.count == 1);
    try report.emit("frames: native release count={d}\n", .{witness.count});

    // A second release through the descriptor's own contract is a no-op, which
    // is what makes "exactly once" true rather than merely observed once.
    acquired.release();
    try report.expect("frames.second_release_is_a_no_op", witness.count == 1);

    const borrowed = source.stop();
    try report.expect("frames.source_reports_no_borrowed_frames", borrowed == 0);
    try source.deinit();
    source_live = false;

    // One PRESENTED frame samples it, and the pixels that frame drew are read
    // back out of the device and compared against the source bytes.
    const logical: nogui.geometry.WindowSize = .{
        .width = @floatFromInt(managed.observed.size.width),
        .height = @floatFromInt(managed.observed.size.height),
    };
    run.probe = probe;
    defer run.probe = null;
    _ = try presentWindow(run, gpu, managed);
    try readProbe(run, gpu, &probe, logical);
    try report.expect("frames.presented_pixels_match_the_source", probe.matched);
    try report.emit(
        "frames: presented={d} committed={d} recreated={d} out_of_date={d} extent_mismatch={d}\n",
        .{
            gpu.adapter.stats.frames_presented,
            gpu.adapter.stats.frames_committed,
            gpu.adapter.stats.swapchains_recreated,
            gpu.adapter.stats.present_out_of_date,
            gpu.adapter.stats.extent_mismatches,
        },
    );
    try report.expect(
        "frames.the_window_really_presented",
        gpu.adapter.stats.frames_presented != 0 and run.frames_presented != 0,
    );
}

/// E05: the macOS accessibility adapter, attached to a REAL managed window and
/// detached before the host destroys it. Trust is READ, never requested.
fn phaseAccessibility(run: *Run) !void {
    const report = run.report;
    // `linked` is a fact about this build, not a request, so a build without
    // the bridge reports by name.
    if (!host_accessibility.linked) {
        run.ax_refusal = error.Unsupported;
        try report.emit(
            "accessibility: this build has no AccessKit bridge, so the attach reports\n" ++
                "  error.Unsupported. No screen reader was started and no trust was requested.\n",
            .{},
        );
        return;
    }
    const managed = try run.application.getWindow(run.handle_primary);
    mac_accessibility.attach(run.accessibility, managed.native.sdl) catch |err| {
        run.ax_refusal = err;
        try report.emit("accessibility: attach refused: {s}\n", .{@errorName(err)});
        return;
    };
    run.ax_attached = true;
    const state = run.accessibility.stateOf();
    const capability = run.accessibility.capability();
    const trusted = mac_accessibility.isTrusted();
    try report.emit(
        "accessibility: attached to the primary managed window, state={s} adapter={} screen_reader={}\n" ++
            "  trusted={} (read from AXIsProcessTrusted, never requested)\n",
        .{ @tagName(state), capability.adapter, capability.screen_reader, trusted },
    );
    if (!trusted) {
        try report.emit(
            "accessibility: this process is not trusted, so VoiceOver cannot read the tree\n" ++
                "  yet. Nothing here requests that; it stays with a person in System Settings.\n",
            .{},
        );
    }
    if (state == .inactive) {
        try report.emit(
            "accessibility: no screen reader has asked for the tree, so the adapter reports\n" ++
                "  inactive. That is the honest answer until one attaches.\n",
            .{},
        );
    }
}

/// One pump of the host, with everything the platform delivered drained on
/// this thread. Returns false once the host has stopped.
fn pump(run: *Run) !bool {
    const running = try run.application.step();
    _ = run.delegate.drain(@ptrCast(&run.delegate_log), DelegateLog.onEvent);
    if (run.pending_menu_item) |item| {
        // The click arrived on the AppKit thread. The dispatch happens HERE, on
        // the host's own thread, against the tree the App last committed, so
        // the Session is never entered from inside a platform callback.
        run.pending_menu_item = null;
        if (run.app_primary.tree_ptr) |tree| {
            const result = run.bridge.dispatchItem(
                item,
                tree,
                run.app_primary.focus_manager.current,
            ) catch |err| {
                try run.report.emit("menus: dispatch refused: {s}\n", .{@errorName(err)});
                return running;
            };
            run.menu_dispatched += 1;
            const after = try run.snapshot();
            try run.report.emit(
                "menus: dispatched \"{s}\" -> {s}; shared model bump_count={d} hide_count={d}\n",
                .{ item.label, @tagName(result), after.bump_count, after.hide_count },
            );
        } else {
            try run.report.emit(
                "menus: the click arrived before this window published a tree, so there is\n" ++
                    "  nothing to dispatch it against and it is reported rather than applied\n",
                .{},
            );
        }
    }
    return running;
}

/// Pump until the deadline, or until the host stops.
fn hold(run: *Run, until_ms: u64) !void {
    while (sdl3.timer.getMillisecondsSinceInit() < until_ms) {
        if (!try pump(run)) return;
    }
}

/// Run the native phases in the order their lifetimes require.
///
/// The ordering is not arbitrary. Tabs and the titlebar name WINDOWS, so they
/// run as soon as the windows exist. The application delegate needs the host
/// pumping before AppKit's answer can arrive. The text endpoint, the menu bar
/// and the Dock menu all need a COMMITTED TREE, so real frames are published
/// before them. The CoreVideo phase then builds the presented half, and every
/// frame after it presents through the primary window's own swapchain. The
/// accessibility attach and the two phases that can prompt a person come
/// last, while the windows are still up for them to be looking at.
fn runNative(run: *Run) !void {
    try phaseTabs(run);
    try phaseTitlebar(run);
    try phaseApplication(run);

    // Real frames on both windows, so the shared model is observed through two
    // independently published trees and the tree-dependent phases below have
    // something to read.
    const frame_deadline = sdl3.timer.getMillisecondsSinceInit() + run.options.hold_ms;
    try hold(run, frame_deadline);
    const shared = try run.snapshot();
    try run.report.emit(
        "windows: published frames primary={d} secondary={d}; presented primary={d}\n" ++
            "  committed draws primary={d} secondary={d}\n" ++
            "  shared model bump={d} inserts={d}; both windows read bump={d}\n",
        .{
            run.frames_primary,
            run.frames_secondary,
            run.frames_presented,
            run.pane_primary.committed,
            run.pane_secondary.committed,
            shared.bump_count,
            shared.insertions_applied,
            run.pane_primary.observed,
        },
    );
    try run.report.expect(
        "windows.both_panes_drew",
        run.pane_primary.committed != 0 and run.pane_secondary.committed != 0,
    );
    try run.report.expect(
        "windows.both_published_frames",
        run.frames_primary != 0 and run.frames_secondary != 0,
    );
    try run.report.expect(
        "windows.one_model_two_readers",
        run.pane_primary.observed == run.pane_secondary.observed,
    );

    try phaseText(run);
    try phaseServices(run);
    try phaseMenus(run);

    // E02: the CoreVideo descriptor through the host's own frame source.
    try phaseFrames(run);

    // E05: the attach is only meaningful once the window it names has published
    // a frame, so it comes after the frames above.
    try phaseAccessibility(run);
    try run.report.expect(
        "accessibility.attached_only_after_a_frame",
        !run.ax_attached or run.ax_frame_published,
    );
    if (!run.ax_attached) {
        try run.report.emit(
            "accessibility: not attached this run ({s}); the adapter's own state and the\n" ++
                "  refusal above are the whole result, and no screen reader was started\n",
            .{if (run.ax_refusal) |err| @errorName(err) else "not attempted"},
        );
    }

    // The remaining approved work happens while the windows are up, so the
    // people those phases can prompt at are actually looking at them.
    if (run.options.notification != null) try phaseNotifications(run);
    if (run.options.keychain != null) try phaseCredentials(run);

    // The final hold is where a person picks a palette character, clicks a menu
    // item and answers a notification. The run reports what arrived and never
    // claims what did not.
    try hold(run, sdl3.timer.getMillisecondsSinceInit() + run.options.hold_ms);
    try run.report.emit(
        "hold: menu clicks dispatched={d} delegate events={d} service answers={d}\n",
        .{
            run.menu_dispatched,
            run.delegate_log.count,
            run.service_answers.load(.monotonic),
        },
    );
}

// Main.

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa_state.deinit() == .leak) @panic("W23 macOS smoke leaked");
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var report: Reporter = .{ .io = io };
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    const options = try parseOptions(&args, &report);
    if (options.help) {
        try report.emit("{s}", .{usage_text});
        return;
    }
    try requireNativeForApprovals(options, &report);

    try report.emit(
        "W23 macOS consumer: E01 windows/application, E02 text/services/media, E05 accessibility\n",
        .{},
    );
    try reportCapabilities(gpa, &report);

    if (!options.native) {
        try report.emit("\n{s}", .{usage_text});
        try report.emit(
            "no window, no provider, no permission and no native call was made by this run.\n" ++
                "  Pass --native to drive the adapters on this session's own driver.\n",
            .{},
        );
        return;
    }

    // Off this target the native half is an honest refusal. Every adapter
    // reports a typed unavailability, and a non-macOS `Unsupported` is not a
    // macOS result, so the run names the phases it could not drive.
    if (!macos.available) {
        try report.emit(
            "\nrefused: --native needs macOS. available={} bridge_linked={}\n" ++
                "  phases not driven: tabs, titlebar, application delegate, text responder,\n" ++
                "  services, menus, recent documents, keychain, notifications, pixel-buffer\n" ++
                "  frames, accessibility. None of them is a result on this target.\n",
            .{ macos.available, host_accessibility.linked },
        );
        return error.MacosTargetRequired;
    }

    var session = try Session.init(gpa);
    var session_live = true;
    defer if (session_live) session.deinit() catch
        @panic("W23 macOS smoke left the Session live");

    var application = try Application.init(gpa, &session, .{
        .app_id = "dev.nogui.w23macossmoke",
        .restart = .never,
        // No driver hint: this run drives the display server it is actually
        // connected to, which on macOS is the Cocoa backend.
        .video_driver = null,
    });
    var application_live = true;
    defer if (application_live) application.deinit();

    // One shared model, created here and retained by each App below.
    var initial: Document = .{ .gpa = gpa };
    try initial.text.appendSlice(gpa, "nogui");
    var owner = try session.create(Document, &initial);
    var owner_live = true;
    defer if (owner_live) session.release(Document, &owner) catch
        @panic("W23 macOS smoke could not release the shared model");

    // Every record the platform keeps a pointer to is heap allocated and
    // initialized in place, because the platform outlives this frame.
    const run = try gpa.create(Run);
    defer gpa.destroy(run);
    const delegate = try gpa.create(mac_application.Delegate);
    const responder = try gpa.create(mac_text.Responder);
    const accessibility = try gpa.create(host_accessibility.Adapter);
    const menus = try gpa.create(mac_menus.Adapter);
    const notifications = try gpa.create(mac_notifications.Provider);
    const recorder = try gpa.create(NotificationRecorder);
    const app_primary = try gpa.create(App);
    const app_secondary = try gpa.create(App);
    const pane_primary = try gpa.create(Pane);
    const pane_secondary = try gpa.create(Pane);

    delegate.* = mac_application.Delegate.init(gpa, io);
    responder.* = mac_text.Responder.init(gpa, io);
    accessibility.init(gpa, io);
    menus.* = mac_menus.Adapter.init(gpa, io);
    notifications.* = mac_notifications.Provider.init(gpa, io);
    recorder.* = .{};
    app_primary.* = try App.init(gpa, &session);
    app_secondary.* = try App.init(gpa, &session);
    pane_primary.* = .{ .name = "primary", .background = pane_background };
    pane_secondary.* = .{ .name = "secondary", .background = pane_background };

    run.* = .{
        .gpa = gpa,
        .io = io,
        .report = &report,
        .options = options,
        .session = &session,
        .application = &application,
        .owner = owner,
        .app_primary = app_primary,
        .app_secondary = app_secondary,
        // SAFETY: assigned by openWindowWithApp before hooks can read it.
        .handle_primary = undefined,
        // SAFETY: assigned by openWindowWithApp before hooks can read it.
        .handle_secondary = undefined,
        .pane_primary = pane_primary,
        .pane_secondary = pane_secondary,
        .registry = mac_window.Registry.init(gpa),
        .delegate = delegate,
        // SAFETY: only seen[0..count] is read; onEvent initializes before increment.
        .delegate_log = .{ .seen = undefined },
        .responder = responder,
        .accessibility = accessibility,
        .menus = menus,
        // SAFETY: initialized immediately below, before any route is registered.
        .actions = undefined,
        // SAFETY: initialized immediately below after its borrowed registry.
        .bridge = undefined,
        .recent = host_menus.RecentDocumentsManager.init(gpa),
        .keychain = mac_keychain.Provider.init(gpa),
        .notifications = notifications,
        .recorder = recorder,
    };
    run.actions = try action.Registry.init(gpa, &session);
    // The bridge borrows the run's own registry, so the two live exactly as
    // long as each other and neither outlives the other.
    run.bridge = host_menus.MenuActionBridge.init(&run.actions);

    // Two OWNED windows over ONE shared model. Each App retains the model
    // through `mountModelRoot`, so it outlives both of them.
    try app_primary.mountModelRoot(Document, Pane, owner, pane_primary);
    try app_secondary.mountModelRoot(Document, Pane, owner, pane_secondary);
    // The primary window is opened Vulkan-compatible because it is the one
    // the presented half acquires an image from. The secondary window is a
    // plain window this run only publishes trees into, so it claims no
    // surface and says so rather than hiding behind a swapchain it never
    // used.
    run.handle_primary = try application.openWindowWithApp(app_primary, .{
        .title = "w23-macos-smoke primary",
        .width = window_width,
        .height = window_height,
        .visible = true,
        .gpu_surface = true,
    });
    run.handle_secondary = try application.openWindowWithApp(app_secondary, .{
        .title = "w23-macos-smoke secondary",
        .width = window_width_b,
        .height = window_height_b,
        .visible = true,
    });
    // The tab group names windows by their SDL ids, so the readbacks compare
    // against the ids the platform actually issued rather than anything this
    // file assumed.
    run.window_id_primary = (try application.getWindow(run.handle_primary)).native.id;
    run.window_id_secondary = (try application.getWindow(run.handle_secondary)).native.id;
    try report.emit(
        "windows: opened two owned windows ({d}x{d} and {d}x{d})\n",
        .{ window_width, window_height, window_width_b, window_height_b },
    );

    application.setHooks(.{
        .context = @ptrCast(run),
        .on_frame = onFrame,
        .on_before_close = onBeforeClose,
    });
    try application.start();

    // The outcome is recorded rather than propagated straight away: a run that
    // ends early still has to print what it observed and tear down in order.
    const outcome: ?anyerror = if (runNative(run)) |_| null else |err| err;

    // ── ordered teardown, reverse of construction ──
    //
    // Three of these resources hang off a WINDOW rather than off this
    // process: the responder's mirror lives inside the primary window's
    // content view, the accessibility bridge subclasses that same view, and
    // the presented half's swapchain is built on the window's own drawable.
    // All three are released while that window is still alive, which is what
    // `on_before_close` guarantees during the closes further down.
    responder.deinit();
    gpa.destroy(responder);
    menus.deinit();
    // The accessibility adapter is released EXACTLY ONCE, whichever of the
    // two call sites gets here first: this teardown, or `onBeforeClose` when
    // a person pressed Cmd-W during a hold. `Adapter.deinit` poisons its
    // record, so a second call would hand a garbage pointer to the bridge.
    if (run.ax_attached) {
        mac_accessibility.detach(run.accessibility);
        run.ax_attached = false;
    } else if (!run.ax_released) {
        // The adapter still owns a bridge handle and its tree buffer even when
        // `attach` was refused, so the record is released here rather than
        // freed with the allocation still holding both.
        run.accessibility.deinit();
    }
    run.ax_released = true;
    // The presented half goes before the window closes, and inside it the
    // frame module retires before the swapchain, which retires before the
    // device the swapchain lives on.
    if (run.gpu) |gpu| {
        run.gpu = null;
        gpu.deinit(gpa);
        gpa.destroy(gpu);
    }
    delegate.deinit();
    gpa.destroy(delegate);
    gpa.destroy(menus);
    gpa.destroy(accessibility);
    // A shared service owns its provider and releases it in `deinit`, so each
    // of these is released here ONLY when no service took it.
    if (!run.notifications_provider_retired) notifications.deinit();
    gpa.destroy(notifications);
    gpa.destroy(recorder);
    if (!run.credentials_provider_retired) run.keychain.deinit();
    run.recent.deinit();
    run.actions.deinit();

    for ([_]contract.WindowHandle{ run.handle_primary, run.handle_secondary }) |handle| {
        const closed = application.closeWindow(handle) catch |err| switch (err) {
            error.StaleWindow => true,
            else => failed: {
                try report.emit("shutdown: window close failed: {s}\n", .{@errorName(err)});
                break :failed false;
            },
        };
        try report.expect("windows.close_accepted_or_already_closed", closed);
    }
    application.deinit();
    application_live = false;
    try report.expect("windows.registry_forgot_both", run.registry.count() == 0);
    try report.emit("windows: both owned windows closed\n", .{});
    run.registry.deinit();

    // The Apps outlive the windows the host BORROWED them for, so they are
    // destroyed after the closes above. Each releases its retain on the model.
    app_primary.deinit();
    app_secondary.deinit();
    gpa.destroy(app_primary);
    gpa.destroy(app_secondary);
    gpa.destroy(pane_primary);
    gpa.destroy(pane_secondary);

    session.release(Document, &owner) catch
        @panic("W23 macOS smoke could not release the shared model");
    owner_live = false;

    try session.deinit();
    session_live = false;

    try report.emit("\nsummary: {d} checks, {d} failed\n", .{ report.checks, report.failures });
    try report.emit(
        \\
        \\not proven by this run:
        \\  - accessibility trust: it was read, never requested, and no screen reader
        \\    was started
        \\  - a Services send: an unbundled process has no Services menu to send from,
        \\    and a send only happens for an approved index
        \\  - a palette insertion: that needs a person to pick a character
        \\  - a keychain or notification answer: both need a person, and a bundle
        \\    identifier and access-group entitlement respectively
        \\  - the secondary window's own pixels: it is published through the App's
        \\    tree path and presents no swapchain image, and this run does not read
        \\    that back
        \\  - a find-pasteboard or recent-documents mutation: both are refused unless
        \\    the store this run would overwrite is empty, and the refusals above are
        \\    the whole result when it is not
        \\
    , .{});
    if (report.failures != 0) return error.SmokeCheckFailed;
    if (outcome) |err| return err;
}
