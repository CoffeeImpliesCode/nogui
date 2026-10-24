//! W23 E03/E05 Windows native consumer smoke.
//!
//! One binary that drives the Windows adapters in `src/v7_host/windows/` from
//! the OUTSIDE, the way a Windows product would: through the public
//! `windows.Host` factory, through real `Application`/`ManagedWindow`
//! instances, and through the shared notification, credential and capture
//! services the host hands over. Nothing here reaches into an adapter's
//! internals, and nothing here substitutes a second implementation for one.
//!
//! WHAT EACH COMMAND CLAIMS, and nothing more:
//!
//!   help          Print the commands, the flags and every scope text. No SDL,
//!                 no provider, no Windows API, no approval.
//!   probe         Print the build facts this binary can establish without
//!                 asking a platform anything. It reports what the BUILD is and
//!                 never what a platform would support: a target that supports
//!                 an adapter is not an installed adapter.
//!   identity      Claim the process `AppUserModelID` and read it back from the
//!                 shell through `GetCurrentProcessExplicitAppUserModelID`.
//!   window        Open one real `ManagedWindow` and drive its native title,
//!                 resize grip and dark title bar, reading each back through
//!                 `window_interop`.
//!   menu          Attach a real `HMENU` built from a real `MenuBar` and the
//!                 real evaluated bar, install this directory's own window
//!                 procedure on the window, and let the PLATFORM deliver a real
//!                 `WM_COMMAND` to it. The identifier travels from the adapter's
//!                 own route table, through the platform and the procedure, into
//!                 `MenuActionBridge` and the live model. A person may choose a
//!                 row in the attached bar while the run holds, and that choice
//!                 arrives through the same door.
//!   jumplist      Publish a real jump list through COM, carrying one synthetic
//!                 task and one synthetic recent-document FILE this run owns in
//!                 this user's own data root, and report the exact argument the
//!                 shell will start this binary with for each of the two. A
//!                 selection this run builds for itself is replay, and is
//!                 labelled as such.
//!   activation    The run the SHELL started. This binary takes its command from
//!                 its own command line: the shell writes the entry and nothing
//!                 else, so the arm opens the window the launch is for, mounts
//!                 its model, registers its live claim and routes the argument
//!                 the platform actually reported -- once, to the right window,
//!                 or refused by name. It publishes nothing, registers nothing
//!                 and replays nothing, because the shell asked for none of it.
//!   notify        Post, replace, dismiss and expire synthetic toasts through
//!                 the shared `NotificationsService`.
//!   credential    Create, read back and delete one synthetic secret, then name
//!                 the live answer to a locked, a denied and a disconnected
//!                 call.
//!   capture       Open the real Windows Graphics Capture picker and report the
//!                 real frame, format, ownership and teardown.
//!   accessibility Attach, publish through and detach the UI Automation adapter
//!                 around a real presented frame. The window's field is a real
//!                 focused text ENDPOINT there: it takes keyboard focus through
//!                 the App's own focus manager, the App binds the model's own
//!                 text protocol to that identity, and a committed-text event
//!                 routed through the App's own event path edits the same model
//!                 a UI Automation `SetValue` edits. The published node carries
//!                 the model's live bytes, its directional selection in the
//!                 core's byte offsets, and the per-character geometry of the
//!                 one text service that rasterizes the same frame.
//!   lifecycle     Two real windows, a native menu and a real delivered
//!                 `WM_COMMAND`, real presented frames, a bounded event pump, a
//!                 full retirement and the resource counters.
//!   cleanup       Delete the synthetic records THIS binary created and
//!                 withdraw the native registrations it made.
//!
//! APPROVAL. Every native command needs BOTH an authorization flag and an exact
//! copy of its point-of-risk scope text, and the process identity — app
//! registration, and the ordering constraint every other adapter depends on —
//! is a precondition of all of them. A command line is not an approval: the
//! person who owns the desktop has to approve the exact scope in the session
//! that runs the arm. A scope text with no flag behind it is refused before the
//! arm opens anything, and each arm's own scope names every effect it performs
//! — the lifecycle arm's names its menu attach and its command dispatch, so
//! approving the identity alone does not buy either, and the jump list's file
//! association is a SEPARATE flag from publishing the list. `--help`, `probe`
//! and `activation` need no approval: the first two touch nothing, and the
//! third is the run the shell itself started, which writes no flags and must
//! not be given one.
//!
//! WHAT THIS RUN DOES NOT DO, in its own words rather than in a footnote:
//!   * It does not launch Narrator, start a UI Automation client, or change any
//!     trust or accessibility system setting. `screenReaderAsked` is a LATCHED
//!     observation that some client asked for the tree; this run causes no such
//!     client to exist, so the honest answer is usually "no".
//!   * It does not manufacture a capture frame. The picker is the OS's and the
//!     frames are the OS's, and a run in which the operator dismisses it
//!     reports `canceled` rather than a frame.
//!   * It does not answer a credential prompt, a toast or a picker from inside
//!     this process. A refusal is reported as the refusal the platform gave.
//!   * It does not fabricate a provider answer. Every notification response
//!     comes from `NotificationsService.pump` routing a real shell answer, and
//!     every credential outcome is the tag `advapi32` actually produced.
//!   * It does not present a cross-compile, a `zig build check`, or the Linux
//!     `Unsupported` answers these adapters give off Windows as runtime proof
//!     for E03 or E05. The plan says so; this file does not pretend otherwise.
//!
//! EVIDENCE LIMITS, because a Windows run is a narrow thing:
//!   * A toast with an action needs a COM activator registered against a Start
//!     menu entry. That is a packaging fact, so the activator class id arrives
//!     on the command line (`--toast-activator-clsid`) and an empty one is
//!     reported as `capabilities.actions=false`: the target's support, not this
//!     app's installation.
//!   * `locked` and `denied` credential answers are what a particular logon
//!     session and a particular store policy produce. This run reaches the real
//!     call, reports the exact tag, and checks only that a CONNECTED provider
//!     answered. It does not assert a tag the operator's machine may never
//!     produce. `disconnected` is produced here and is asserted exactly.
//!   * A jump list entry is delivered by the SHELL, as this executable's own
//!     single argument, and the shell writes no approval flags. That is why
//!     `activation` exists as its own command: the shell's line is `exe <entry>`
//!     and nothing else, so it is read before any command word and it never
//!     travels with an approval. The arm it selects opens a window, mounts a
//!     model and routes that one argument once. It publishes no list, records
//!     no recent document, installs no association and claims no identity,
//!     because the shell asked for a window and not for any of those.
//!   * A menu row chosen by a person is reported as chosen or reported as not
//!     chosen. When nobody chooses one in the holding window, the run says so
//!     and claims no choice; the posted rows in the same phase are what prove
//!     the window procedure is installed and dispatching, and a person clicking
//!     one is what proves the shell's own menu drives it.
//!
//! Run it: `zig build w23-windows-smoke`. `--help` needs nothing and `probe`
//! needs nothing. Every other command needs a Windows session, its scopes, and
//! a GPU for the ones that present frames.
const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const noapi = @import("noapi");

const nogui = @import("nogui");
const host = @import("nogui_host");
const frame_api = @import("v7_frame");

/// The CPU text service the field shapes through, and the harness the tests
/// below build a real font context with. One import each, shared by the
/// library types and by every test that needs them.
const Cpu = @import("nogui_text");
const Test = @import("nogui_test");

const App = nogui.App;
const FrameNodeId = nogui.FrameNodeId;
const Session = nogui.Session;
const action = nogui.action;
const contract = nogui.window_contract;
const geometry = nogui.geometry;
const semantics = nogui.semantics;
const text_input = nogui.text_input;
const widget = nogui.widget;
const WidgetId = nogui.WidgetId;
const WidgetTree = nogui.WidgetTree;
/// The shaped run the field's per-character geometry is measured from. It is
/// the layout type the frame's own text engine hands back, so the platform
/// and the rasterizer read one measurement.
const TextLayout = frame_api.native.TextLayout;

const Application = host.Application;
const ManagedWindow = host.ManagedWindow;
const capture = host.capture;
const credentials = host.credentials;
const menus = host.menus;
const notifications = host.notifications;
const weak_owner = host.weak_owner;
const windows = host.windows;
const winapi = windows.win32;

// ── the command line ───────────────────────────────

const authorize_identity_flag = "--authorize-identity-claim";
const identity_scope_flag = "--identity-scope";
const app_id_flag = "--app-id";
const authorize_window_flag = "--authorize-window-native-state";
const window_scope_flag = "--window-scope";
const authorize_menu_flag = "--authorize-native-menu-attach";
const menu_scope_flag = "--menu-scope";
const authorize_jump_flag = "--authorize-jump-list-publish";
const jump_scope_flag = "--jump-list-scope";
const authorize_association_flag = "--authorize-document-association";
const association_scope_flag = "--document-association-scope";
const authorize_notify_flag = "--authorize-synthetic-toast-post";
const notify_scope_flag = "--notification-scope";
const authorize_credential_flag = "--authorize-secret-store-round-trip";
const credential_scope_flag = "--credential-scope";
const service_flag = "--service";
const account_flag = "--account";
const authorize_capture_flag = "--authorize-screen-capture-picker";
const capture_scope_flag = "--capture-scope";
const capture_source_flag = "--capture-source";
const authorize_accessibility_flag = "--authorize-accessibility-tree-publish";
const accessibility_scope_flag = "--accessibility-scope";
const authorize_lifecycle_flag = "--authorize-window-lifecycle";
const lifecycle_scope_flag = "--lifecycle-scope";
const authorize_cleanup_flag = "--authorize-owned-record-cleanup";
const cleanup_scope_flag = "--cleanup-scope";
const toast_id_flag = "--toast-id";
const toast_activator_flag = "--toast-activator-clsid";
const toast_group_flag = "--toast-group";
const frames_flag = "--frames";
const hold_flag = "--hold-ms";
const wait_flag = "--wait-ms";
const expiry_flag = "--expiry-ms";
const capture_wait_flag = "--capture-wait-ms";

/// The identity scope, byte for byte, with the exact app id the operator is
/// approving spliced between its two halves. The operator reads the id they
/// typed on the same line they are about to run.
const identity_scope_prefix = "claim this process's AppUserModelID as \"";
const identity_scope_suffix = "\" for this desktop, and read it back from the shell";

const window_scope_text =
    "set the title, the resize grip and the dark title bar on the one w23 window this run opens, " ++
    "and read each of the three back from the window itself";
const menu_scope_text =
    "attach a native menu bar to the one w23 window this run opens, and route one real " ++
    "WM_COMMAND identifier through the action registry into that window's live model";
const jump_scope_text =
    "publish one jump list for the identity this process holds, carrying one synthetic " ++
    "task and one synthetic recent-document FILE this run owns in this user's local " ++
    "application data, and route a shell-launched entry to the live window that owns it";
const association_scope_text =
    "install one per-user file association for the extension .w23smoke under this user's " ++
    "HKCU\\Software\\Classes, pointing at this executable with %1 as its only argument, " ++
    "so a click on the recent document starts this binary with that path";
const notify_scope_text =
    "post one synthetic w23 toast on this desktop, replace it, dismiss it, and wait for the shell's own expiry answer";
const credential_scope_prefix = "create, read back and delete one synthetic secret under service \"";
const credential_scope_middle = "\" account \"";
const credential_scope_suffix = "\" in the credential store of this machine";
const capture_scope_text =
    "open the Windows Graphics Capture picker on this desktop and capture whichever " ++
    "source the operator selects, for as long as this run holds";
const accessibility_scope_text =
    "attach the UI Automation adapter to the one w23 window this run opens, publish the " ++
    "semantic tree of that window's real presented frames through it, and detach before " ++
    "the window closes";
const lifecycle_scope_text =
    "open two w23 windows on this desktop, attach the native menu bar to the first and " ++
    "route one real WM_COMMAND into its live model, present bounded frames through a " ++
    "real surface, close one window and read the resource counters";
const cleanup_scope_text =
    "delete the synthetic credential entry, dismiss the synthetic toast, delete the " ++
    "synthetic document file this run wrote under this user's local application data, " ++
    "remove the per-user .w23smoke file association this run installed, and withdraw " ++
    "the jump list and the COM activator registration that this run created";

/// What the shell writes for a jump list entry, and the whole of it: this
/// executable's own path and ONE argument. A jump list entry is not an
/// in-process event, so this run has a command for the launch itself and the
/// argument arrives from the platform, never typed onto an approval.
const launch_argument_hint =
    "the shell launches this binary as \"<this executable> <the published action name>\" " ++
    "for a task and \"<this executable> <the published path>\" for a document, with " ++
    "nothing else on the line";
/// The only service this run may ever write under. A real namespace is refused
/// before a provider exists, so no existing credential is even searched for.
const smoke_service: []const u8 = "nogui-w23-smoke";
/// Every account is this prefix plus a nonce the operator invents and never
/// reuses, so two runs can never address the same entry.
const account_prefix: []const u8 = "w23-smoke-";
const min_nonce_len: usize = 8;
const max_nonce_len: usize = 32;
/// The toast group this run files its synthetic toasts under.
const default_toast_group: []const u8 = "nogui-w23-smoke";
/// The synthetic document this run owns. It is a real FILE in this user's own
/// writable data root, because the shell launches a recent document through
/// the file type registered for its extension and can neither record nor open
/// a URI that names no file. The path is derived from the user's data root
/// and this fixed name, so the run that publishes it and the separate run the
/// shell launches to open it compute the same string without being told it.
const document_file_name: []const u8 = "w23-windows-smoke.w23smoke";
/// What that file contains. It exists to be a file the shell can name; its
/// bytes say who wrote it and that nobody should edit it.
const document_body: []const u8 =
    "w23-windows-smoke synthetic recent document\nwritten by the W23 smoke run; not a real document\n";
/// The extension this document carries, and the one this run may register a
/// handler for. Nothing else on a real desktop uses it.
const document_extension: []const u8 = ".w23smoke";
/// The friendly name the file type shows, and the suffix the ProgID takes so
/// two app identities on one desktop never share a registration.
const document_type_suffix: []const u8 = "Document";
const max_document_len: usize = 320;

const min_frames: u32 = 1;
const max_frames: u32 = 64;
const default_frames: u32 = 4;
const min_hold_ms: u64 = 200;
const max_hold_ms: u64 = 120_000;
const default_hold_ms: u64 = 4_000;
const min_wait_ms: u64 = 200;
const max_wait_ms: u64 = 120_000;
const default_wait_ms: u64 = 20_000;
const min_expiry_ms: i32 = 200;
const max_expiry_ms: i32 = 60_000;
const default_expiry_ms: i32 = 4_000;
/// One `pump` slice. Short enough that a wait ends close to its deadline.
const pump_slice_ms: i32 = 200;
/// How much wait the notify arm needs past the expiry it is there to observe:
/// two whole pump slices, because the shell answers at or just after the
/// timeout it was given.
const min_pump_slack_ms: i64 = 2 * @as(i64, pump_slice_ms);
/// Bounded pump rounds for the notification wait.
const max_pump_rounds: u32 = 4_000;
/// Bounded capture wait. The picker is a person's dialog, so the bound is
/// generous but finite: a picker nobody answers must end the run, not hang it.
const min_capture_wait_ms: u64 = 1_000;
const max_capture_wait_ms: u64 = 300_000;
const default_capture_wait_ms: u64 = 60_000;
/// The unconsumed frames a capture session keeps. Video is only worth the
/// newest frame, so this is deliberately small.
const capture_queue_depth: usize = 3;
/// Bounded acquire rounds. Each round drives the poll-driven Windows backend
/// once, so a frame pool that never fills fails the run instead of spinning.
const max_capture_rounds: u32 = 4_000;
/// Bounded event-pump iterations for the lifecycle phase.
const max_pump_iterations: u32 = 4_000;
const pump_idle_ms: u64 = 4;
/// How long one posted `WM_COMMAND` may take to reach the window procedure.
/// Generous for a message that is already in the queue, and finite so a
/// procedure that is not installed fails the run instead of hanging it.
const command_budget_ms: u64 = 2_000;
/// Swapchain acquires per presented frame. A surface that never settles is a
/// failure rather than a spin.
const max_frame_attempts: u32 = 8;
/// The window this run opens. Bounded and small, because nothing here needs a
/// large surface and a window that covers the operator's desktop is a side
/// effect nobody approved.
const window_width: u32 = 520;
const window_height: u32 = 480;
const second_window_width: u32 = 380;
const second_window_height: u32 = 260;
const window_title: [:0]const u8 = "w23-windows-smoke";
const second_window_title: [:0]const u8 = "w23-windows-smoke peer";

const Command = enum {
    help,
    probe,
    identity,
    window,
    menu,
    jumplist,
    /// The run the SHELL started, chosen from the process's own command line
    /// before any command word is looked for. The shell writes the entry and
    /// nothing else, so a parser that wanted a command word first would
    /// refuse the shell's own line and no launch would ever arrive.
    activation,
    notify,
    credential,
    capture,
    accessibility,
    lifecycle,
    cleanup,
};

const Options = struct {
    gpa: std.mem.Allocator,
    command: Command = .probe,
    authorize_identity: bool = false,
    authorize_window: bool = false,
    authorize_menu: bool = false,
    authorize_jump: bool = false,
    authorize_association: bool = false,
    authorize_notify: bool = false,
    authorize_credential: bool = false,
    authorize_capture: bool = false,
    authorize_accessibility: bool = false,
    authorize_cleanup: bool = false,
    authorize_lifecycle: bool = false,
    identity_scope: ?[]const u8 = null,
    window_scope: ?[]const u8 = null,
    menu_scope: ?[]const u8 = null,
    jump_scope: ?[]const u8 = null,
    association_scope: ?[]const u8 = null,
    notify_scope: ?[]const u8 = null,
    credential_scope: ?[]const u8 = null,
    capture_scope: ?[]const u8 = null,
    accessibility_scope: ?[]const u8 = null,
    cleanup_scope: ?[]const u8 = null,
    lifecycle_scope: ?[]const u8 = null,
    /// The one argument the SHELL wrote on this process's command line, read
    /// from the platform itself and never from a flag. It is set only on the
    /// activation command, which no person types and which carries no approval
    /// flags, because the shell writes none.
    activation_argument: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    service: ?[]const u8 = null,
    account: ?[]const u8 = null,
    capture_source: ?capture.SourceType = null,
    toast_id: ?u32 = null,
    toast_activator: ?[]const u8 = null,
    toast_group: []const u8 = default_toast_group,
    frames: u32 = default_frames,
    hold_ms: u64 = default_hold_ms,
    wait_ms: u64 = default_wait_ms,
    expiry_ms: i32 = default_expiry_ms,
    capture_wait_ms: u64 = default_capture_wait_ms,
};

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),
    checks: u32 = 0,
    failures: u32 = 0,

    /// A smoke whose whole product is its report cannot continue once stdout
    /// is gone: there is no evidence left to fail against. So a report that
    /// cannot be FORMATTED is a bug in this file and panics here, and a report
    /// that cannot be WRITTEN ends the run with that error rather than
    /// continuing to make claims nobody can see.
    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = std.fmt.bufPrint(&self.buffer, fmt, args) catch
            @panic("W23 Windows smoke could not format its own report");
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }

    /// One hard check. A failing check is printed with its observed values and
    /// counted; the run stops at the end rather than at the first failure, so
    /// one report names everything that broke. A check that cannot be printed
    /// is the case above: there is no evidence left, so the run stops here.
    fn expect(self: *Reporter, label: []const u8, ok: bool) void {
        self.checks += 1;
        if (!ok) self.failures += 1;
        self.emit("check {s}: {s}\n", .{ label, if (ok) "pass" else "FAIL" }) catch
            @panic("W23 Windows smoke could not report a check");
    }

    fn expectCount(self: *Reporter, label: []const u8, expected: anytype, actual: anytype) void {
        self.expectFmt(label, expected, actual, expected == actual);
    }

    fn expectText(self: *Reporter, label: []const u8, expected: []const u8, actual: []const u8) void {
        self.expectFmt(label, expected, actual, std.mem.eql(u8, expected, actual));
    }

    fn expectFmt(
        self: *Reporter,
        label: []const u8,
        expected: anytype,
        actual: anytype,
        ok: bool,
    ) void {
        self.checks += 1;
        if (!ok) self.failures += 1;
        const fmt = if (@TypeOf(expected) == []const u8)
            "check {s}: expected={s} observed={s} {s}\n"
        else
            "check {s}: expected={d} observed={d} {s}\n";
        self.emit(fmt, .{
            label,
            expected,
            actual,
            if (ok) "pass" else "FAIL",
        }) catch @panic("W23 Windows smoke could not report a check");
    }
};

fn submitTag(outcome: notifications.SubmitOutcome) []const u8 {
    return switch (outcome) {
        .accepted => "accepted",
        .unsupported => "unsupported",
        .denied => "denied",
        .provider_failed => "provider_failed",
    };
}

fn dismissTag(outcome: notifications.DismissOutcome) []const u8 {
    return switch (outcome) {
        .closed => "closed",
        .unsupported => "unsupported",
        .refused => "refused",
        .provider_failed => "provider_failed",
    };
}

/// A provider-failure tag, so a typed refusal prints WHICH failure it was
/// rather than only that one happened.
fn providerErrorTag(failure: anytype) []const u8 {
    return @tagName(failure);
}

fn readTag(result: credentials.ReadResult) []const u8 {
    return switch (result) {
        .found => "found",
        .not_found => "not_found",
        .locked => "locked",
        .prompt_dismissed => "prompt_dismissed",
        .denied => "denied",
        .canceled => "canceled",
        .unsupported => "unsupported",
        .provider_failed => "provider_failed",
    };
}

fn writeTag(result: credentials.WriteResult) []const u8 {
    return switch (result) {
        .success => "success",
        .locked => "locked",
        .prompt_dismissed => "prompt_dismissed",
        .denied => "denied",
        .canceled => "canceled",
        .unsupported => "unsupported",
        .provider_failed => "provider_failed",
    };
}

fn deleteTag(result: credentials.DeleteResult) []const u8 {
    return switch (result) {
        .success => "success",
        .not_found => "not_found",
        .locked => "locked",
        .prompt_dismissed => "prompt_dismissed",
        .denied => "denied",
        .canceled => "canceled",
        .unsupported => "unsupported",
        .provider_failed => "provider_failed",
    };
}

/// One refusal, named. Printed rather than swallowed: the refusal IS the
/// observation for a path whose whole point is to be refused.
fn refusalTag(err: anyerror) []const u8 {
    return @errorName(err);
}

fn booleanText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// An optional string, printed. Generic so a sentinel-terminated slice and a
/// plain one both print the same way.
fn optionalText(value: anytype) []const u8 {
    const maybe: ?[]const u8 = value;
    return maybe orelse "<null>";
}

// ── the model behind every window ──────────────────────────

/// Bytes the field can hold. The model is retained by the App and outlives
/// every frame arena, so its storage is a fixed buffer rather than a slice
/// it would have to free. One byte is the most a character can need in this
/// field's own table, so the table is the same width.
const field_capacity: usize = 192;
/// The font the field's run is shaped with: the same family and size the
/// frame's text engine rasterizes with, so a measured advance is a painted
/// advance.
const field_family: []const u8 = "InterVariable";
const field_font_size: f32 = 15;
/// Horizontal inset of the field's own run inside its carrier's border box.
/// The published per-character offsets are measured in the carrier's own
/// coordinate space, so this number is part of the geometry rather than
/// decoration.
const field_inset: f32 = 10;
/// Width of the caret this run draws inside its own line box.
const field_caret_width: f32 = 2;
/// What an empty field announces. A screen reader is told the placeholder
/// because the run it was handed is the empty string.
const field_placeholder: []const u8 = "type a w23 value";
/// The one committed-text event the accessibility arm routes through the App
/// to reach the field the ordinary way. It ends in a character that is TWO
/// BYTES and ONE UTF-16 UNIT, so the run that reaches the platform proves the
/// conversion rather than assuming ASCII made it trivial.
const ordinary_commit: []const u8 = " é";
/// The two action bits a text node must carry for the native seam to be
/// reachable at all: the core refuses any action whose bit is clear.
const text_action_mask: u32 =
    (@as(u32, 1) << @backingInt(semantics.Action.replace_selected_text)) |
    (@as(u32, 1) << @backingInt(semantics.Action.set_text_selection));

/// The longest prefix of `value` that fits in `room` and ends on a codepoint
/// boundary. A field never stores half a character, so a value too long for
/// the buffer loses whole codepoints from its end rather than ending in a
/// lead byte nobody can decode.
fn utf8PrefixLen(value: []const u8, room: usize) usize {
    var at: usize = 0;
    while (at < value.len and at < room) {
        at += codepointSize(value, at);
    }
    if (at > room) at = room;
    // A codepoint that begins before the room and ends past it is dropped
    // whole, so the walk lands back on the last boundary that fits.
    while (at > 0 and at < value.len and (value[at] & 0xc0) == 0x80) at -= 1;
    return at;
}

/// The byte length of the codepoint at `at`, or one for a byte that starts
/// none. A field whose own bytes are whole codepoints never takes the second
/// answer, and an answer of one keeps every walk total on a buffer a
/// platform is midway through filling.
fn codepointSize(bytes: []const u8, at: usize) usize {
    if (at >= bytes.len) return 1;
    return std.unicode.utf8ByteSequenceLength(bytes[at]) catch 1;
}

fn codepointAt(bytes: []const u8, at: usize) u21 {
    if (at >= bytes.len) return 0;
    const end = @min(at + codepointSize(bytes, at), bytes.len);
    return std.unicode.utf8Decode(bytes[at..end]) catch 0;
}

fn isSpaceByte(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\n' or value == '\r';
}

/// The next word boundary: past the run of non-whitespace, then past the
/// whitespace that follows it. This is the field's own rule, asked for only
/// by the protocol's word motion; it is not a language tokenizer.
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

/// The UTF-16 unit of a byte offset that already names a codepoint start, and
/// the unit count of a whole value. Both are TOTAL on the field's own bytes:
/// the model never stores half a character, so the conversions the protocol
/// spells as failures have no failure to report here.
fn unitsAt(value: []const u8, byte: usize) usize {
    const at = @min(byte, value.len);
    var units: usize = 0;
    var index: usize = 0;
    while (index < at) {
        units += if (codepointAt(value, index) > 0xffff) 2 else 1;
        index += codepointSize(value, index);
    }
    return units;
}

fn totalUnits(value: []const u8) usize {
    return unitsAt(value, value.len);
}

/// The byte offset inside `value` that a caller asked for, snapped to a
/// codepoint boundary of THAT value. An offset at or past the end is the end;
/// one that names a continuation byte is the character that byte belongs to,
/// because a selection may never land inside a character.
fn snapToCodepoint(value: []const u8, asked: usize) usize {
    if (asked >= value.len) return value.len;
    var at = asked;
    while (at > 0 and (value[at] & 0xc0) == 0x80) at -= 1;
    return at;
}

/// One line of text this run's field really holds, behind the shared
/// text-input protocol.
///
/// A fixed buffer rather than a heap slice, because the model is retained by
/// the App and outlives any frame arena, and storage with static lifetime
/// cannot be freed by accident. The selection and the preedit are in UTF-16
/// CODE UNITS, because that is the unit the protocol and every native text
/// API speak; the published tree and the annotator convert them to the core's
/// byte offsets in one place each, so the two never drift.
const Field = struct {
    buffer: [field_capacity]u8 = @splat(0),
    len: usize = 0,
    selection: text_input.Selection = .{},
    /// The preedit a composition is holding. Null means no composition is
    /// open, and the next commit replaces the selection instead.
    marked: ?text_input.Utf16Range = null,
    /// One UTF-8 byte length per character of the live value, so the platform
    /// can address the run in the characters it counts.
    lengths: [field_capacity]u8 = @splat(0),
    characters: usize = 0,
    /// Committed replacements, from any door. One edit moves this once, so a
    /// screen-reader edit and a keystroke are the same number rather than two
    /// counters that have to be added up.
    edits: u32 = 0,
    /// Compositions this field has held, erases it has applied and caret
    /// motions it has resolved. A preedit is not a committed edit, so it is
    /// counted on its own.
    marks: u32 = 0,
    erases: u32 = 0,
    moves: u32 = 0,

    pub fn text(self: *const Field) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Re-measure the character table from the bytes the field actually
    /// holds. A table derived from a value the field no longer has would make
    /// every platform offset wrong, and the platform cannot check it.
    fn measureCharacters(self: *Field) void {
        const value = self.text();
        var characters: usize = 0;
        var at: usize = 0;
        while (at < value.len and characters < self.lengths.len) {
            const step = codepointSize(value, at);
            self.lengths[characters] = @intCast(step);
            characters += 1;
            at += step;
        }
        self.characters = characters;
    }

    /// Remove `start..end` and put `bytes` there, truncating the insertion to
    /// what the fixed buffer can hold at a codepoint boundary. The number of
    /// bytes actually stored is returned, because the caller places its caret
    /// against THAT and not against what it asked for.
    fn splice(self: *Field, start: usize, end: usize, bytes: []const u8) usize {
        const value = self.text();
        const tail = value[end..self.len];
        const room = self.buffer.len - (self.len - (end - start));
        const taken = utf8PrefixLen(bytes, room);
        // The two slices are different storage, so a truncating insert that
        // shifts the tail cannot overwrite the bytes it is copying from.
        var next: [field_capacity]u8 = undefined;
        @memcpy(next[0..start], value[0..start]);
        @memcpy(next[start..][0..taken], bytes[0..taken]);
        @memcpy(next[start + taken ..][0..tail.len], tail);
        self.len = start + taken + tail.len;
        @memcpy(self.buffer[0..self.len], next[0..self.len]);
        return taken;
    }

    /// The whole NEW value with a selection expressed in its OWN units.
    ///
    /// This is the native door's write shape: the core composes the entire
    /// value and hands it over, rather than naming a range to edit. The value
    /// is stored first and the selection is converted against the bytes that
    /// survived it, so the stored selection can never name a character the
    /// field does not hold, and the caller's direction is kept. Replacing
    /// every character retires any preedit, because none of the marked text
    /// is in the value any more.
    pub fn assign(self: *Field, value: []const u8, anchor: usize, focus: usize) void {
        self.len = utf8PrefixLen(value, self.buffer.len);
        if (value.ptr != self.buffer[0..].ptr) {
            @memmove(self.buffer[0..self.len], value[0..self.len]);
        }
        self.marked = null;
        self.select(anchor, focus);
        self.measureCharacters();
        self.edits += 1;
    }

    /// Move the two endpoints of the selection in the value this field ALREADY
    /// holds, and change nothing else.
    ///
    /// This is the selection-only half of the native door: the core hands over
    /// no contents at all for a request that only moves the caret, so there
    /// are no bytes here to write and none are written. Both endpoints are
    /// clamped against the bytes that are here NOW, because the core bounded
    /// them against the run it published and this model may have moved on
    /// since, and the caller's direction is kept. An open composition keeps
    /// its marked range: a preedit is not a character, and moving the caret
    /// neither commits it nor cancels it.
    pub fn select(self: *Field, anchor: usize, focus: usize) void {
        const total = totalUnits(self.text());
        const fixed = @min(anchor, total);
        const moving = @min(focus, total);
        self.selection = .{
            .range = .{ .start = @min(fixed, moving), .end = @max(fixed, moving) },
            .reversed = fixed > moving,
        };
    }

    /// A range in the protocol's units, as bytes of the current value. An
    /// offset that names no character is refused rather than rounded onto a
    /// neighbour, because a rounded edit moves somebody else's character.
    fn byteRange(self: *const Field, range: text_input.Utf16Range) !struct { start: usize, end: usize } {
        const value = self.text();
        return .{
            .start = try text_input.utf16ToUtf8(value, @min(range.start, range.end)),
            .end = try text_input.utf16ToUtf8(value, @max(range.start, range.end)),
        };
    }

    fn unitAt(self: *const Field, byte: usize) !usize {
        return text_input.utf8ToUtf16(self.text(), byte);
    }

    /// The protocol target: an explicit range, else the marked range, else the
    /// selection. This order is the rule that stops a platform commit from
    /// duplicating the preedit it is committing.
    fn target(self: *const Field, range: ?text_input.Utf16Range) text_input.Utf16Range {
        return range orelse self.marked orelse self.selection.range;
    }

    /// Commit a replacement over `range`, or over the marked range, or over
    /// the selection. The caret lands at the end of what was inserted, and
    /// the preedit is gone because its text is now ordinary text.
    pub fn replaceRegion(
        self: *Field,
        range: ?text_input.Utf16Range,
        bytes: []const u8,
    ) !void {
        const region = try self.byteRange(self.target(range));
        const taken = self.splice(region.start, region.end, bytes);
        const caret = unitsAt(self.text(), region.start + taken);
        self.marked = null;
        self.selection = .{ .range = .{ .start = caret, .end = caret } };
        self.measureCharacters();
        self.edits += 1;
    }

    /// Replace and mark as a preedit. The last argument is a selection INSIDE
    /// the new marked text, in the same units, so a reversed composition
    /// keeps its direction and the caret belongs at its end.
    pub fn replaceAndMark(
        self: *Field,
        range: ?text_input.Utf16Range,
        bytes: []const u8,
        inside: ?text_input.Utf16Range,
    ) !void {
        const region = try self.byteRange(self.target(range));
        const taken = self.splice(region.start, region.end, bytes);
        const kept = self.text()[region.start .. region.start + taken];
        const base = try self.unitAt(region.start);
        const length = totalUnits(kept);
        self.marked = if (kept.len == 0)
            null
        else
            text_input.Utf16Range{ .start = base, .end = base + length };
        const caret = if (inside) |value| base + @min(value.end, length) else base + length;
        self.selection = .{ .range = .{ .start = caret, .end = caret } };
        self.measureCharacters();
        self.marks += 1;
    }

    /// Put the caret at `byte`. A shift-extension keeps the fixed end and
    /// moves only the moving one, so a selection the user dragged backwards
    /// is still backwards afterwards.
    fn setCaret(self: *Field, byte: usize, extend: bool) void {
        const next = unitsAt(self.text(), byte);
        if (!extend) {
            self.selection = .{ .range = .{ .start = next, .end = next } };
            return;
        }
        const anchor = self.selection.anchor();
        self.selection = .{
            .range = .{ .start = @min(anchor, next), .end = @max(anchor, next) },
            .reversed = anchor > next,
        };
    }

    /// Resolve one caret motion against the field's own bytes.
    ///
    /// A single-line field's line IS its document, so line motion and
    /// document motion answer the same place; the two arms stay apart so the
    /// rule is stated once here rather than spread over the handlers.
    fn resolveMotion(self: *const Field, at: usize, request: text_input.Move, layout: *const TextLayout) !usize {
        const value = self.text();
        const forward = request.direction == .forward;
        return switch (request.unit) {
            .grapheme => if (forward)
                (try layout.nextGrapheme(at)) orelse value.len
            else
                (try layout.previousGrapheme(at)) orelse 0,
            .word => if (forward) wordEnd(value, at) else wordStart(value, at),
            .line, .document => if (forward) value.len else 0,
        };
    }

    /// Move the caret, or the selection's moving end, and report where it
    /// ended up. A cancelled composition names the offset it wants back.
    pub fn moveCaret(self: *Field, request: text_input.Move, layout: *const TextLayout) !text_input.Selection {
        const value = self.text();
        const total = totalUnits(value);
        if (request.offset) |named| {
            const byte = try text_input.utf16ToUtf8(value, @min(named, total));
            self.setCaret(byte, request.extend);
            return self.selection;
        }
        const cursor = @min(self.selection.cursor(), total);
        const at = try text_input.utf16ToUtf8(value, cursor);
        self.setCaret(try self.resolveMotion(at, request, layout), request.extend);
        self.moves += 1;
        return self.selection;
    }

    /// Apply one erase. An extended erase selects instead of deleting, which
    /// is the whole difference between the two: the motion runs, and the NEXT
    /// erase removes what is now selected.
    pub fn eraseRegion(self: *Field, request: text_input.Erase, layout: *const TextLayout) !void {
        const range: text_input.Utf16Range = if (request.extend)
            (try self.moveCaret(.{
                .unit = request.unit,
                .direction = if (request.backward) .backward else .forward,
                .extend = true,
            }, layout)).range
        else if (!self.selection.range.isEmpty())
            self.selection.range
        else blk: {
            const value = self.text();
            const cursor = @min(self.selection.cursor(), totalUnits(value));
            const at = try text_input.utf16ToUtf8(value, cursor);
            const edge = try self.resolveMotion(at, .{
                .unit = request.unit,
                .direction = if (request.backward) .backward else .forward,
            }, layout);
            break :blk text_input.Utf16Range{
                .start = cursor,
                .end = unitsAt(value, edge),
            };
        };
        const region = try self.byteRange(range);
        _ = self.splice(region.start, region.end, "");
        const caret = try self.unitAt(region.start);
        self.marked = null;
        self.selection = .{ .range = .{ .start = caret, .end = caret } };
        self.measureCharacters();
        self.erases += 1;
        self.edits += 1;
    }
};

/// The Session model behind one window.
///
/// Every route into this run — a pointer click on the App's own button, a
/// `WM_COMMAND` through the native menu bridge, a jump-list selection through
/// the router, an activation the accessibility drain replays — reaches one of
/// the methods below through the same `Registry` and the same `Session`. There
/// is no second record and no private path.
const Panel = struct {
    title: []const u8,
    /// Rows the registered actions have added or removed.
    rows: usize = 3,
    checked: bool = false,
    /// The synthetic document this window owns. Fixed storage, because the
    /// model outlives every frame arena.
    document: [max_document_len]u8 = @splat(0),
    document_len: usize = 0,
    field: Field = .{},
    /// How the last routed action arrived. The effect is the same method
    /// whichever door it came through; this is what lets the report name the
    /// door without giving the model a second effect.
    last_route: []const u8 = route_none,
    route_hits: u32 = 0,
    /// Text edits the NATIVE door applied, counted on its own. The field's
    /// own `edits` counts every committed edit from any door exactly once, so
    /// this is the part of that number the screen reader is responsible for
    /// and not a second tally of the same edit.
    native_edits: u32 = 0,
    /// System-action rows the native menu dispatched into this model, and the
    /// name of the last one. It is model state like `last_route`, because the
    /// bridge owns no handler of its own to record it in.
    system_actions: u32 = 0,
    last_system_action: []const u8 = route_none,

    pub fn setDocument(self: *Panel, path: []const u8) void {
        const taken = @min(path.len, self.document.len);
        @memcpy(self.document[0..taken], path[0..taken]);
        self.document_len = taken;
    }

    pub fn documentPath(self: *const Panel) []const u8 {
        return self.document[0..self.document_len];
    }

    pub fn addRow(self: *Panel, route: []const u8) void {
        if (self.rows < 12) self.rows += 1;
        self.note(route);
    }

    pub fn removeRow(self: *Panel, route: []const u8) void {
        if (self.rows == 0) return;
        self.rows -= 1;
        self.note(route);
    }

    pub fn toggleFlag(self: *Panel, route: []const u8) void {
        self.checked = !self.checked;
        self.note(route);
    }

    pub fn openDocument(self: *Panel, path: []const u8, route: []const u8) void {
        self.setDocument(path);
        self.note(route);
    }

    fn note(self: *Panel, route: []const u8) void {
        self.last_route = route;
        self.route_hits += 1;
    }

    /// `Remove row` is disabled exactly when there is no row left, so a native
    /// menu built from the evaluated bar greys that row for the reason the
    /// registry gave rather than because this file guessed.
    pub fn removeAvailability(self: *const Panel, _: *Session) action.Availability {
        return if (self.rows == 0) .disabled else .available;
    }
};

const AddRow = action.Action(void, "w23.add_row");
const RemoveRow = action.Action(void, "w23.remove_row");
const ToggleFlag = action.Action(void, "w23.toggle_flag");
const OpenDocument = action.Action(struct { path: []const u8 }, "w23.open_document");
const QuitAction = action.Action(void, menus.SystemAction.quit.actionName());

// Route labels. Borrowed string literals, so naming a route costs no storage
// and a label cannot be freed while a model still reports it. There are three
// because there are three DOORS and one effect: a registered action handler
// ran, the accessibility drain ran one, or the focused text endpoint took an
// ordinary edit. Which door a command came through is a fact the report owns,
// because the model deliberately does not learn it.
const route_action = "registered_action";
const route_accessibility = "accessibility_drain";
const route_text_input = "text_input_endpoint";
const route_none = "none";

/// The window's view. These are the App's own nodes: the layout measures them,
/// the hit test routes to them, the menu evaluates against them and the
/// accessibility adapter publishes them.
const PanelView = struct {
    /// The App whose activation runs this view's button callbacks, and the
    /// registry those callbacks dispatch through. Both live in a heap value
    /// that is never moved, which is what makes the pointers below safe.
    app: *App,
    registry: *action.Registry,
    title: []const u8,
    /// The Session this window's model lives in, and the ticket that names
    /// it. `Session.create` MOVES the value it is given, so nothing this run
    /// keeps may point at the value it handed over: the annotator reads the
    /// model through this pair, which is the only way to see it.
    session: *Session,
    panel: nogui.Model(Panel),
    /// The model read back for the publication that borrows it. The snapshot
    /// keeps whatever the annotator hands it for as long as that snapshot
    /// lives, so these bytes must outlive the hook; they are rewritten from
    /// the model again on the next publish.
    annotated: PanelCopy = .{},
    /// The status line, copied out of the frame arena because the arena dies
    /// with the frame.
    note: [192]u8 = @splat(0),
    note_len: usize = 0,
    /// In-app dispatches that ran, counted by action name. A click and a menu
    /// command both land on `add_row`; only this counter says a WIDGET was
    /// involved, which is what makes "one action, two doors" observable rather
    /// than asserted.
    add_hits: u32 = 0,
    remove_hits: u32 = 0,
    toggle_hits: u32 = 0,
    /// Dispatches the registry refused, by its own answer.
    refused_dispatches: u32 = 0,
    field_id: ?WidgetId = null,
    field_owner: ?nogui.ErasedWeakModel = null,
    /// Borrowed only while the phase's text service is alive.
    field_shape: ?*FieldShape = null,
    /// The carrier's node in the frame being committed, so the shaped run and
    /// the published bounds are measured from the box the LAYOUT gave this
    /// node rather than from a box this file declared.
    field_node: FrameNodeId = .root,
    add_id: ?WidgetId = null,
    remove_id: ?WidgetId = null,

    pub fn noteText(self: *const PanelView) []const u8 {
        return self.note[0..self.note_len];
    }

    fn setNote(self: *PanelView, text: []const u8) void {
        const taken = @min(text.len, self.note.len - 1);
        @memcpy(self.note[0..taken], text[0..taken]);
        self.note[taken] = 0;
        self.note_len = taken;
    }

    /// A pointer press on the carrier takes keyboard focus through the App's
    /// own focus manager. It is the ordinary way a person reaches this field,
    /// and it is the same call the native focus seam makes, so both doors
    /// agree about which widget owns the keyboard.
    fn onFieldTap(self: *PanelView, _: usize) void {
        self.bindFieldEndpoint() catch |err| self.setNote(@errorName(err));
    }

    /// Pointer activation and native focus bind the same weak-owned endpoint.
    fn bindFieldEndpoint(self: *PanelView) !void {
        const tree = self.app.tree_ptr orelse return error.NoCommittedTree;
        const id = self.field_id orelse return error.NoFieldIdentity;
        const owner = self.field_owner orelse return error.FieldHasNoOwner;
        const shape = self.field_shape orelse return error.FieldHasNoTextLayout;
        if (!self.app.focus_manager.set(tree, id, self.app.focusObserver()))
            return error.FieldRefusedFocus;
        self.app.registerTextEndpoint(.{
            .id = id,
            .owner = owner,
            .ops = fieldOps(),
            .user = @ptrCast(shape),
        });
    }

    /// Read the model out of the Session, so every observation in the report
    /// comes from the model the actions mutated rather than from a counter
    /// this file kept beside it.
    fn readPanel(self: *const PanelView, out: anytype) !void {
        try self.session.read(Panel, self.panel, out, struct {
            fn run(value: *const Panel, target: anytype) void {
                target.copyFrom(value);
            }
        }.run);
    }

    /// Shape the bytes this publication is about to carry, in the box the
    /// layout gave the carrier in the frame being published, through the same
    /// text service the frame rasterizes with.
    ///
    /// It runs from the annotation hook, which the App calls with the tree it
    /// is building still alive, so the box, the bytes and the per-character
    /// advances that go into ONE snapshot are one measurement rather than two
    /// that happen to agree today. Measuring after the frame instead would
    /// publish the advances of the previous text beside the lengths of this
    /// one.
    fn shapeField(self: *const PanelView, node: FrameNodeId, model: *const PanelCopy) !void {
        const shape = self.field_shape orelse return;
        // The App holds the tree it is publishing for the whole annotation
        // hook, so this is the box the pixels of THIS frame are lowered into.
        const semantic = self.app.semantic_tree orelse return;
        const box = widget.visualBorderRect(semantic, node);
        try shape.measure(
            model.fieldText(),
            model.lengths[0..model.characters],
            .{ .x = box.x, .y = box.y, .w = box.w, .h = box.h },
        );
    }

    /// An ordinary pointer press, through the App's own activation path, into
    /// the ordinary action registry. This is the in-app half of "one action,
    /// many doors": the button does not reach the model directly, it names the
    /// registered action and the registry resolves it against the live tree.
    fn onAddRow(self: *PanelView, _: usize) void {
        self.dispatch(AddRow.name);
    }

    fn onRemoveRow(self: *PanelView, _: usize) void {
        self.dispatch(RemoveRow.name);
    }

    fn onToggleFlag(self: *PanelView, _: usize) void {
        self.dispatch(ToggleFlag.name);
    }

    /// Dispatch one registered action from inside a widget callback.
    ///
    /// The tree is the App's current committed tree, the focus is the App's own
    /// focus, and the registry is the same one the native menu and the jump
    /// list use. A dispatch that fails or that the registry refuses is counted,
    /// not swallowed.
    fn dispatch(self: *PanelView, name: []const u8) void {
        const tree = self.app.tree_ptr orelse return;
        const result = self.registry.dispatch(tree, self.app.focus_manager.current, name, null) catch {
            self.refused_dispatches += 1;
            self.setNote("the registry dispatch itself failed");
            return;
        };
        switch (result) {
            .handled => self.noteHandled(name),
            .disabled, .unavailable => self.refused_dispatches += 1,
        }
    }

    fn noteHandled(self: *PanelView, name: []const u8) void {
        if (std.mem.eql(u8, name, AddRow.name)) {
            self.add_hits += 1;
        } else if (std.mem.eql(u8, name, RemoveRow.name)) {
            self.remove_hits += 1;
        } else if (std.mem.eql(u8, name, ToggleFlag.name)) {
            self.toggle_hits += 1;
        }
    }

    pub fn draw(self: *PanelView, panel: *const Panel, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.column(.{ .gap = 8, .padding = 12, .fill = c_background });
        defer ctx.pop();

        _ = try ctx.label(.{ .text = self.title, .color = c_text });
        self.setNote(try std.fmt.allocPrint(
            ctx.arena,
            "rows={d} flag={} edits={d} route={s}",
            .{ panel.rows, panel.checked, panel.field.edits, panel.last_route },
        ));
        _ = try ctx.label(.{ .text = self.noteText(), .color = c_text });

        // The field carrier. The core has no text-input widget kind, so the
        // node is a real keyed button whose label is the field's own bytes and
        // whose accessible name is fixed. A press takes focus, and the node
        // is kept because the shaped run, the caret box and the published
        // bounds all read the box the layout gave THIS node.
        self.field_node = try ctx.button(.{
            .key = @as(nogui.ComponentKey, .{ .static = key_field }),
            .label = panel.field.text(),
            .visual_label = panel.field.text(),
            .accessible_label = "w23 field",
            .on_click_with_data = nogui.bind(PanelView.onFieldTap, 0),
            .height = 36,
            .fill = c_field,
            .color = c_text,
            .font_family = field_family,
            .font_size = field_font_size,
            .paragraph = .{ .wrap = .no_wrap, .max_lines = 1 },
            .justify = .start,
            .@"align" = .center,
            .padding = .{ .left = field_inset, .right = field_inset },
            .min_width = 0,
            .text_overflow = .clip,
            .clip = true,
        });
        self.field_id = ctx.widgetIdOf(self.field_node);

        self.add_id = ctx.widgetIdOf(try ctx.button(.{
            .key = @as(nogui.ComponentKey, .{ .static = key_add_row }),
            .label = "Add row",
            .on_click_with_data = nogui.bind(PanelView.onAddRow, 0),
            .height = 32,
        }));
        self.remove_id = ctx.widgetIdOf(try ctx.button(.{
            .key = @as(nogui.ComponentKey, .{ .static = key_remove_row }),
            .label = "Remove row",
            .on_click_with_data = nogui.bind(PanelView.onRemoveRow, 0),
            .height = 32,
            // The widget's OWN disabled state, from the model's own rule, so a
            // pointer press and a menu command agree about what is available.
            .disabled = panel.rows == 0,
        }));
        _ = try ctx.button(.{
            .key = @as(nogui.ComponentKey, .{ .static = key_flag }),
            .label = "Toggle flag",
            .on_click_with_data = nogui.bind(PanelView.onToggleFlag, 0),
            .height = 32,
        });
        // The rows readout is a plain label, not a control: it shows the
        // model's own count and has no action of its own, so giving it one
        // would be a second thing that looks clickable and is not.
        _ = try ctx.label(.{ .text = "rows", .color = c_text });
    }
};

const key_field = "w23-field";
const key_add_row = "w23-add-row";
const key_remove_row = "w23-remove-row";
const key_flag = "w23-flag";

const c_background: nogui.Color = .{ 0.05, 0.06, 0.08, 1.0 };
const c_field: nogui.Color = .{ 0.12, 0.13, 0.16, 1.0 };
const c_text: nogui.Color = .{ 0.93, 0.94, 0.96, 1.0 };

/// The colour the field's own run is shaped with. A glyph is the colour its
/// runs were shaped with, so the shaping request names the same one the
/// carrier paints.
const c_field_text: [4]f32 = .{ 0.93, 0.94, 0.96, 1.0 };

// ── the field's shaped measurement and its text protocol ──

/// The per-character geometry a `semantics.Text` borrows: one x and one
/// advance per character, in the carrier node's own coordinate space and in
/// the model's byte-length order. One named type so the shape that measures
/// it and the annotator that publishes it cannot drift apart.
const PublishedGeometry = struct {
    positions: []const f32 = &.{},
    widths: []const f32 = &.{},
};

/// The field's ONE shaped measurement.
///
/// It holds the frame adapter's text service, which is the service the engine
/// rasterizes with, and at most one layout of the field's current bytes. The
/// per-character advances the platform is handed, the caret rectangle a
/// candidate window hangs off, and the offset a pointer press lands on all
/// read that one layout, so none of them can describe text the model no
/// longer holds. A box with no extent shapes nothing, and every reader of
/// this value then says "not measured" rather than falling back to a fixed
/// grid this file invented.
const FieldShape = struct {
    gpa: std.mem.Allocator,
    service: *Cpu.TextService,
    layout: ?TextLayout = null,
    /// The carrier's own border box in window-logical units, and the line box
    /// the run sits in inside it.
    box: geometry.WindowRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    line_height: f32 = 0,
    positions: [field_capacity]f32 = @splat(0),
    widths: [field_capacity]f32 = @splat(0),
    /// The byte offset each character starts at, in the model's own bytes.
    /// The platform addresses the run in characters, so a caret index has to
    /// become a byte offset somewhere, and this is that one place.
    offsets: [field_capacity]usize = @splat(0),
    characters: usize = 0,
    /// The byte the run ends at. It is the one boundary `offsets` cannot
    /// name, because a full table has no slot past its last character.
    end_byte: usize = 0,
    /// Characters the layout has no position of its own for. A combining
    /// sequence is ONE grapheme and several characters, and the extra
    /// characters share that grapheme's x with no advance. Counted and
    /// reported, never guessed away.
    shared: u32 = 0,

    fn init(gpa: std.mem.Allocator, service: *Cpu.TextService) FieldShape {
        return .{ .gpa = gpa, .service = service };
    }

    fn deinit(self: *FieldShape) void {
        self.drop();
        self.* = undefined;
    }

    fn drop(self: *FieldShape) void {
        if (self.layout) |*live| {
            live.deinit();
            self.layout = null;
        }
    }

    /// Shape `value` in the carrier's box: one x and one advance per
    /// character, in the order the model's own table names them. A run longer
    /// than the box is truncated INSIDE it with a real ellipsis, so no glyph
    /// can escape the node the platform was told about.
    fn measure(
        self: *FieldShape,
        value: []const u8,
        table: []const u8,
        box: geometry.WindowRect,
    ) !void {
        if (!std.math.isFinite(box.w) or !std.math.isFinite(box.h) or
            box.w <= 0 or box.h <= 0)
        {
            // A carrier the layout gave no extent has no line to sit in. The
            // previous run is released rather than left describing a box the
            // node no longer has.
            self.drop();
            self.box = box;
            self.end_byte = 0;
            self.characters = 0;
            self.line_height = 0;
            return;
        }
        if (self.layout) |live| {
            if (std.meta.eql(self.box, box) and std.mem.eql(u8, live.content, value)) return;
        }
        const fresh = try self.service.layout(self.gpa, .{
            .content = value,
            .style = .{
                .font = .{ .family = field_family, .size = field_font_size },
                .foreground = c_field_text,
            },
            .paragraph = .{
                .wrap = .no_wrap,
                .max_lines = 1,
            },
        });
        // The fresh run replaced the old one, so the old one goes now rather
        // than on the next frame that happens to need the room.
        self.drop();
        self.layout = fresh;
        self.box = box;
        self.end_byte = value.len;
        const line = if (fresh.lines.len == 0) null else fresh.lines[0];
        self.line_height = if (line) |item| item.height else 0;
        self.characters = @min(table.len, self.positions.len);
        self.shared = 0;
        var byte_at: usize = 0;
        for (0..self.characters) |index| {
            self.offsets[index] = byte_at;
            if (fresh.byteToPosition(byte_at, .downstream)) |position| {
                // The node's own coordinate space, which is what a platform
                // asks for; the layout's x starts at the run's own origin.
                self.positions[index] = position.x + field_inset;
            } else |_| {
                // One grapheme, several characters: the extra characters sit
                // on the grapheme's own x and advance nothing.
                self.positions[index] = if (index == 0)
                    field_inset
                else
                    self.positions[index - 1];
                self.shared += 1;
            }
            byte_at += table[index];
        }
        if (self.characters != 0) {
            const last = self.characters - 1;
            const tail = fresh.byteToPosition(value.len, .downstream) catch null;
            const end = if (tail) |item| item.x else fresh.width;
            const last_x = self.positions[last] - field_inset;
            self.widths[last] = @max(end - last_x, 0);
            for (0..last) |index| {
                self.widths[index] = @max(self.positions[index + 1] - self.positions[index], 0);
            }
        }
    }

    fn forField(self: *FieldShape, field: *const Field) !*const TextLayout {
        try self.measure(field.text(), field.lengths[0..field.characters], self.box);
        if (self.layout) |*live| return live;
        return error.FieldHasNoTextLayout;
    }

    /// The per-character geometry in the node's own coordinate space, ready
    /// for a `semantics.Text` to borrow.
    fn published(self: *const FieldShape) PublishedGeometry {
        return .{
            .positions = self.positions[0..self.characters],
            .widths = self.widths[0..self.characters],
        };
    }

    /// Where the run ends in the node's own space. The caret behind the last
    /// character sits here, and so does a press to the right of the run.
    fn endX(self: *const FieldShape) f32 {
        if (self.characters == 0) return field_inset;
        const last = self.characters - 1;
        return self.positions[last] + self.widths[last];
    }

    /// The candidate rectangle for the caret at `byte`, in window-logical
    /// coordinates. Null when nothing has been shaped, or when the caret's
    /// byte names no position in the run: a window hung off a caret nobody can
    /// see is worse than no rectangle at all.
    fn caret(self: *const FieldShape, byte: usize) ?text_input.Caret {
        const live = self.layout orelse return null;
        if (live.lines.len == 0) return null;
        const at = @min(byte, live.content.len);
        const position = live.byteToPosition(at, .downstream) catch return null;
        const line = live.lines[@min(position.line, live.lines.len - 1)];
        const x = self.box.x + field_inset + position.x;
        const y = self.box.y + (self.box.h - self.line_height) / 2 + line.y;
        const height = @max(line.height, self.line_height);
        if (x < self.box.x or x + field_caret_width > self.box.x + self.box.w or
            y < self.box.y or y + height > self.box.y + self.box.h) return null;
        return .{
            .area = .{
                .x = x,
                .y = y,
                .w = field_caret_width,
                .h = height,
            },
            .cursor = field_caret_width,
        };
    }

    /// The byte offset a window point lands on, from the same advances the
    /// platform was handed. Null for a point outside the carrier's own box and
    /// for a run with no layout: a press elsewhere is not this field's caret.
    fn byteNearest(self: *const FieldShape, point: geometry.WindowPoint) ?usize {
        if (self.layout == null) return null;
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return null;
        if (point.x < self.box.x or point.x > self.box.x + self.box.w) return null;
        if (point.y < self.box.y or point.y > self.box.y + self.box.h) return null;
        if (self.characters == 0) return 0;
        const local = point.x - self.box.x;
        var best: usize = 0;
        var delta = @abs(local - self.positions[0]);
        for (1..self.characters) |index| {
            const own = @abs(local - self.positions[index]);
            if (own < delta) {
                delta = own;
                best = index;
            }
        }
        if (@abs(local - self.endX()) < delta) return self.end_byte;
        return self.offsets[best];
    }
};

/// The field's text protocol, bound to the `Panel` model the App registered.
///
/// Every handler receives the resolved model for the duration of the call
/// only. The endpoint payload is the `Stage`, which is where the shaped
/// measurement lives; nothing else in this file keeps a second copy of the
/// field's value.
fn readFieldText(
    gpa: std.mem.Allocator,
    panel: *const Panel,
    _: *anyopaque,
    range: text_input.Utf16Range,
    served: *text_input.Utf16Range,
) anyerror!?[]u8 {
    const field = &panel.field;
    const region = try field.byteRange(range);
    served.* = .{
        .start = try field.unitAt(region.start),
        .end = try field.unitAt(region.end),
    };
    const value = try gpa.dupe(u8, field.text()[region.start..region.end]);
    return value;
}

fn readFieldSelection(panel: *const Panel, _: *anyopaque) anyerror!text_input.Selection {
    return panel.field.selection;
}

fn readFieldMarked(panel: *const Panel, _: *anyopaque) anyerror!?text_input.Utf16Range {
    return panel.field.marked;
}

fn moveFieldCaret(
    panel: *Panel,
    user: *anyopaque,
    request: text_input.Move,
) anyerror!text_input.Selection {
    const shape: *FieldShape = @ptrCast(@alignCast(user));
    return panel.field.moveCaret(request, try shape.forField(&panel.field));
}

fn eraseFieldText(panel: *Panel, user: *anyopaque, request: text_input.Erase) anyerror!void {
    const shape: *FieldShape = @ptrCast(@alignCast(user));
    try panel.field.eraseRegion(request, try shape.forField(&panel.field));
    panel.note(route_text_input);
}

fn replaceFieldText(
    panel: *Panel,
    _: *anyopaque,
    range: ?text_input.Utf16Range,
    bytes: []const u8,
) anyerror!void {
    try panel.field.replaceRegion(range, bytes);
    panel.note(route_text_input);
}

fn markFieldText(
    panel: *Panel,
    _: *anyopaque,
    range: ?text_input.Utf16Range,
    bytes: []const u8,
    inside: ?text_input.Utf16Range,
) anyerror!void {
    try panel.field.replaceAndMark(range, bytes, inside);
    panel.note(route_text_input);
}

fn unmarkFieldText(panel: *Panel, _: *anyopaque) anyerror!void {
    panel.field.marked = null;
}

/// The candidate rectangle for one caret, from the ONE layout that also
/// produced the published per-character advances. A field that has never been
/// shaped answers "not measured" and the host places nothing.
fn fieldCaret(
    panel: *Panel,
    user: *anyopaque,
    range: text_input.Utf16Range,
) anyerror!?text_input.Caret {
    const shape: *FieldShape = @ptrCast(@alignCast(user));
    const byte = text_input.utf16ToUtf8(panel.field.text(), range.end) catch return null;
    try shape.measure(panel.field.text(), panel.field.lengths[0..panel.field.characters], shape.box);
    return shape.caret(byte);
}

/// The caret offset a window point lands on, from those same advances, in the
/// protocol's own units.
fn fieldIndexAt(
    panel: *Panel,
    user: *anyopaque,
    point: geometry.WindowPoint,
) anyerror!?usize {
    const shape: *FieldShape = @ptrCast(@alignCast(user));
    try shape.measure(panel.field.text(), panel.field.lengths[0..panel.field.characters], shape.box);
    const byte = shape.byteNearest(point) orelse return null;
    return text_input.utf8ToUtf16(panel.field.text(), byte) catch null;
}

fn fieldOps() text_input.Ops {
    return text_input.Adapter(Panel).ops(.{
        .text = readFieldText,
        .selection = readFieldSelection,
        .marked = readFieldMarked,
        .move = moveFieldCaret,
        .erase = eraseFieldText,
        .replace = replaceFieldText,
        .replace_and_mark = markFieldText,
        .unmark = unmarkFieldText,
        .caret = fieldCaret,
        .index_at = fieldIndexAt,
    });
}

/// The field's semantic node.
///
/// The core's built-in policy knows a button is a button, so this hook is what
/// publishes the model as TEXT: the live bytes, the model's own selection in
/// the core's byte offsets with its direction intact, and the per-character
/// geometry of the one layout that rasterizes the same frame. It is keyed on
/// the carrier's LIVE widget identity rather than on its label, because the
/// label IS the value: a field the user typed into is still recognised.
///
/// The context is the VIEW, because the view owns the model's ticket, its
/// shaped box and the readback the snapshot borrows. The model itself belongs
/// to the Session, so a hook reachable from anywhere but this view would have
/// to be a second one.
fn annotateField(
    context: *anyopaque,
    node: *const widget.WidgetNode,
    draft: *semantics.Draft,
) !void {
    const self: *PanelView = @ptrCast(@alignCast(context));
    const identity = node.widget_id orelse return;
    const field_id = self.field_id orelse return;
    if (!identity.eql(field_id)) return;

    // The snapshot borrows what the annotator hands it, and the model's own
    // borrow ends here, so the bytes are copied into a readback this view
    // owns and rewritten on the next publish.
    try self.readPanel(&self.annotated);
    const model = &self.annotated;
    // The advances are shaped HERE, while the tree this snapshot is built
    // from still exists: the App publishes inside the frame it is building,
    // so a shape taken after that frame would belong to the frame before it.
    try self.shapeField(node.id, model);
    const selection = try model.byteSelection();
    var shaped: PublishedGeometry = .{};
    if (self.field_shape) |shape| shaped = shape.published();
    draft.role = .text_input;
    draft.text = .{
        .value = model.fieldText(),
        .placeholder = field_placeholder,
        .selection = .{ .anchor = selection.anchor, .focus = selection.focus },
        .character_lengths = model.lengths[0..model.characters],
        .character_positions = shaped.positions,
        .character_widths = shaped.widths,
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

// ── the menu and jump-list models ──────────────────────────

const menu_bar: menus.MenuBar = .{ .menus = &.{
    .{ .title = "File", .items = &.{
        .{ .id = 1, .label = "Add row", .kind = .action, .action_name = AddRow.name },
        .{ .kind = .separator },
        .{ .id = 2, .label = "Remove row", .kind = .action, .action_name = RemoveRow.name },
        .{ .kind = .separator },
        .{ .id = 3, .label = "Open document", .kind = .action, .action_name = OpenDocument.name },
        .{ .kind = .separator },
        .{ .id = 4, .label = "Quit", .kind = .system_action, .system_action = .quit },
    } },
    .{ .title = "Edit", .items = &.{
        .{ .id = 5, .label = "Toggle flag", .kind = .action, .action_name = ToggleFlag.name },
    } },
} };

/// The task the jump list publishes for this window's live action. A list may
/// hold one entry per window for the same action, so the title is what makes
/// this entry address THIS window in a list.
///
/// A shell launch has no title: the shim puts the ACTION NAME in the link's
/// argument list, and the shell starts the executable with it. So the title
/// above is what a list selection carries and the action name below is what a
/// launch carries, and both have to reach this window.
const jump_task: menus.JumpListTask = .{
    .title = window_title,
    .action_name = AddRow.name,
    .description = "add a row through the registered action",
};

// ── the shader modules ──────────────────────────────

/// A SPIR-V module read from the build's `shaders/` directory, the same source
/// every other painting run reads. The bytes stay owned for as long as
/// `NativeFrame.init` and the scene renderer need them.
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

/// The Vulkan instance extensions the platform asked for. The loader reads
/// this through the function pointer below while `Gpu.init` builds the
/// instance and not after, so the storage is released as soon as it returns.
var vulkan_extensions: [][*:0]const u8 = &.{};

fn instanceExtensions() []const [*:0]const u8 {
    return vulkan_extensions;
}

// ── the stage: one window and everything behind it ─────────

const WindowSpec = struct {
    title: [:0]const u8,
    width: u32,
    height: u32,
    /// Whether the window is a Vulkan-compatible one. Only a phase that
    /// presents frames asks for it, and a phase that claims no surface says so
    /// here rather than hiding it behind a swapchain it never used.
    gpu_surface: bool,
    /// Whether the window is shown at open. The accessibility phase needs it
    /// hidden, because the bridge refuses a window that is already visible.
    visible: bool,
};

/// One window, its App, its model, its action registry, and the bridge every
/// native route goes through.
///
/// Heap allocated, because the App holds a borrowed pointer to the view inside
/// this value for as long as the window is open. Nothing here may be moved
/// after `create` returns.
const Stage = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The stable address every App, registry and model ticket in this stage
    /// points at. It is initialized in place before anything else exists.
    session: Session,
    application: *Application,
    app: *App,
    panel: nogui.Model(Panel),
    registry: action.Registry,
    bridge: menus.MenuActionBridge,
    view: PanelView,
    handle: contract.WindowHandle,
    managed: *ManagedWindow,
    /// The weak probe every native route re-checks. Flipped off to observe the
    /// closed-owner refusal, and back on to observe the live route.
    alive: bool = true,
    tick: u32 = 0,
    /// Frames this stage committed, and frames that were presented. The
    /// headless phases commit without presenting, so the two are separate
    /// numbers rather than one.
    frames_committed: u32 = 0,
    frames_presented: u32 = 0,

    fn create(gpa: std.mem.Allocator, io: Io, spec: WindowSpec) !*Stage {
        const stage = try gpa.create(Stage);
        errdefer gpa.destroy(stage);
        stage.* = .{
            .gpa = gpa,
            .io = io,
            .session = try Session.init(gpa),
            // SAFETY: `gpa.create` writes this pointer on the next statement,
            // and the guard that destroys it is registered after that.
            .application = undefined,
            // SAFETY: `gpa.create` writes this pointer too, before the guard
            // that destroys it and before the App borrows the Session.
            .app = undefined,
            // SAFETY: `session.create` fills the ticket before anything
            // releases it, and no guard above it reads this field.
            .panel = undefined,
            // SAFETY: `Registry.init` fills it before `registry.deinit` runs,
            // and the guard below is the one that releases it.
            .registry = undefined,
            // SAFETY: `MenuActionBridge.init` fills it before any menu route
            // borrows it; nothing in the unwind chain touches it.
            .bridge = undefined,
            // SAFETY: the view literal below fills it before the App mounts it
            // and before any callback can reach it.
            .view = undefined,
            // SAFETY: `openWindowWithApp` stamps it before the next statement
            // passes it to `getWindow`.
            .handle = undefined,
            // SAFETY: `getWindow` fills it from the window just opened, before
            // the resize below reads through it.
            .managed = undefined,
        };
        // Every guard below is registered immediately AFTER the value it
        // releases exists. `errdefer` runs in reverse registration order, so a
        // guard written above its assignment would unwind through an
        // `undefined` field on the very failure it exists to clean up, and the
        // Session is registered first so it is torn down last, which is the
        // only order here that matters: everything above it borrows from it.
        //
        // `Application.init` acquires the process-wide SDL session, so it runs
        // after the Session exists and before the App is registered with it.
        //
        // A Session that cannot be shut down is a fault in the model this run
        // built rather than a fact about this run, so the rollback NAMES it
        // instead of swallowing it. That panic replaces the construction
        // error already on its way out, which is the honest trade for not
        // hiding leaked work behind a tidy return.
        errdefer stage.session.deinit() catch
            @panic("W23 stage could not shut its session down");
        stage.application = try gpa.create(Application);
        errdefer gpa.destroy(stage.application);
        stage.application.* = try Application.init(gpa, &stage.session, .{});
        errdefer stage.application.deinit();

        stage.app = try gpa.create(App);
        errdefer gpa.destroy(stage.app);
        stage.app.* = try App.init(gpa, &stage.session);
        errdefer stage.app.deinit();

        var panel = initPanel(spec.title);
        stage.panel = try stage.session.create(Panel, &panel);
        errdefer stage.session.release(Panel, &stage.panel) catch
            @panic("W23 stage could not release its panel");

        stage.registry = try action.Registry.init(gpa, &stage.session);
        errdefer stage.registry.deinit();
        try stage.registerActions();

        // The bridge borrows the registry, and both live in this heap value,
        // so this is the first moment at which either can take the other's
        // address.
        stage.bridge = menus.MenuActionBridge.init(&stage.registry);
        stage.view = .{
            .app = stage.app,
            .registry = &stage.registry,
            .title = spec.title,
            .session = &stage.session,
            .panel = stage.panel,
            .field_owner = stage.panel.weak().erase(),
        };
        try stage.app.mountModelRoot(Panel, PanelView, stage.panel, &stage.view);
        stage.handle = try stage.application.openWindowWithApp(stage.app, .{
            .title = spec.title,
            .width = spec.width,
            .height = spec.height,
            .resizable = true,
            .visible = spec.visible,
            .gpu_surface = spec.gpu_surface,
        });
        stage.managed = try stage.application.getWindow(stage.handle);
        // The driver tells the App its own size, exactly as the host's routing
        // would; nothing here assumes the size that was requested.
        if (try stage.app.handle(.{
            .resize = .{
                .width = @floatFromInt(stage.managed.observed.size.width),
                .height = @floatFromInt(stage.managed.observed.size.height),
            },
        })) |output| {
            if (output.json) |json| stage.gpa.free(json);
        }
        return stage;
    }

    /// The full retirement, in the only order the contracts allow.
    ///
    /// Only a `Stage` that `create` RETURNED reaches this, so every field read
    /// below is live. A failure inside `create` unwinds through that function's
    /// own `errdefer` chain and never through the poison written here, so a
    /// partially built value can never be retired as though it were whole.
    fn deinit(self: *Stage) void {
        const gpa = self.gpa;
        defer gpa.destroy(self);
        self.application.deinit();
        gpa.destroy(self.application);
        self.session.release(Panel, &self.panel) catch
            @panic("W23 stage could not release its panel model");
        self.registry.deinit();
        self.app.deinit();
        gpa.destroy(self.app);
        self.session.deinit() catch @panic("W23 stage could not shut its session down");
        // The entry defer frees storage only after this poison.
        self.* = undefined;
    }

    /// Register every action and bind it to this window's model. The owner is
    /// the WEAK model, so a released model answers `unavailable` instead of
    /// resurrecting it.
    fn registerActions(self: *Stage) !void {
        try self.registry.register(AddRow);
        try self.registry.register(RemoveRow);
        try self.registry.register(ToggleFlag);
        try self.registry.register(OpenDocument);
        try self.registry.register(QuitAction);
        const weak = self.panel.weak();
        _ = try self.registry.bind(AddRow, Panel, onAddRow, null, .app, weak);
        _ = try self.registry.bind(RemoveRow, Panel, onRemoveRow, Panel.removeAvailability, .app, weak);
        _ = try self.registry.bind(ToggleFlag, Panel, onToggleFlag, null, .app, weak);
        _ = try self.registry.bind(OpenDocument, Panel, onOpenDocument, null, .app, weak);
        _ = try self.registry.bind(QuitAction, Panel, onSystemAction, null, .app, weak);
    }

    /// The committed tree every native adapter is handed. It is the App's own
    /// current tree, not a copy and not a synthetic stand-in.
    fn tree(self: *Stage) !*const WidgetTree {
        return self.app.tree_ptr orelse error.NoCommittedTree;
    }

    fn focus(self: *Stage) ?WidgetId {
        return self.app.focus_manager.current;
    }

    /// One headless frame: the tree the menu evaluates, the router dispatches
    /// against and the semantic publisher stages. No device is created, so a
    /// phase that needs no pixels claims no surface and says so.
    fn headlessFrame(self: *Stage) !void {
        self.tick += 1;
        if (try self.app.handle(.{ .frame = .{
            .tick = self.tick,
            .time_ms = @as(u64, self.tick) * 16,
        } })) |output| {
            if (output.json) |json| self.gpa.free(json);
        }
        self.frames_committed += 1;
    }

    /// Read the model out of the Session, so every observation in the report
    /// comes from the model the actions mutated rather than from a counter
    /// this file kept beside it.
    fn readPanel(self: *Stage, out: anytype) !void {
        try self.view.readPanel(out);
    }

    fn weakOwner(self: *Stage) weak_owner.WeakOwner {
        return .{ .context = self, .is_alive_fn = stageAlive };
    }

    fn show(self: *Stage) !void {
        try self.managed.requestVisibility(true);
        try self.managed.refresh();
    }
};

/// A readback of the whole model into a caller-owned copy, so a report can
/// name any field without re-borrowing the model for each one, and so the
/// annotator has bytes that outlive the borrow it read them in.
const PanelCopy = struct {
    rows: usize = 0,
    checked: bool = false,
    route_hits: u32 = 0,
    /// Text edits the NATIVE door applied. Zero in a run with no client
    /// attached, which is the honest value rather than a missing one.
    native_edits: u32 = 0,
    /// Committed edits the field itself recorded, from any door. One edit
    /// moves this once, so it is the number that says how much text changed
    /// rather than how many times it was asked to.
    field_edits: u32 = 0,
    /// Compositions, erases and caret motions the field resolved, so a report
    /// can name which protocol call moved it.
    field_marks: u32 = 0,
    field_erases: u32 = 0,
    field_moves: u32 = 0,
    last_route: []const u8 = route_none,
    /// System-action rows the native menu dispatched into this model, and the
    /// name of the last one, carried across with the rest of the model.
    system_actions: u32 = 0,
    last_system_action: []const u8 = route_none,
    document: [max_document_len]u8 = @splat(0),
    document_len: usize = 0,
    /// The field's live bytes, and the selection the model holds in the
    /// protocol's own UTF-16 units with its direction.
    field: [field_capacity]u8 = @splat(0),
    field_len: usize = 0,
    anchor_unit: usize = 0,
    cursor_unit: usize = 0,
    reversed: bool = false,
    /// The character table measured from those same bytes.
    lengths: [field_capacity]u8 = @splat(0),
    characters: usize = 0,

    fn copyFrom(self: *PanelCopy, value: *const Panel) void {
        self.rows = value.rows;
        self.checked = value.checked;
        self.route_hits = value.route_hits;
        self.native_edits = value.native_edits;
        self.field_edits = value.field.edits;
        self.field_marks = value.field.marks;
        self.field_erases = value.field.erases;
        self.field_moves = value.field.moves;
        self.last_route = value.last_route;
        self.system_actions = value.system_actions;
        self.last_system_action = value.last_system_action;
        self.document_len = value.documentPath().len;
        @memcpy(self.document[0..self.document_len], value.documentPath());
        const field = &value.field;
        self.field_len = field.len;
        @memcpy(self.field[0..field.len], field.text());
        self.anchor_unit = field.selection.anchor();
        self.cursor_unit = field.selection.cursor();
        self.reversed = field.selection.reversed;
        @memcpy(self.lengths[0..field.characters], field.lengths[0..field.characters]);
        self.characters = field.characters;
    }

    pub fn documentPath(self: *const PanelCopy) []const u8 {
        return self.document[0..self.document_len];
    }

    pub fn fieldText(self: *const PanelCopy) []const u8 {
        return self.field[0..self.field_len];
    }

    /// The model's selection in the core's byte offsets, direction intact:
    /// a selection the user drew backwards is still backwards here.
    pub fn byteSelection(self: *const PanelCopy) !struct { anchor: usize, focus: usize } {
        const value = self.fieldText();
        return .{
            .anchor = try text_input.utf16ToUtf8(value, self.anchor_unit),
            .focus = try text_input.utf16ToUtf8(value, self.cursor_unit),
        };
    }
};

/// Mutate the model through the Session, the only way this file writes it.
/// `mutate` is a comptime function value, so the Session's own handler can be
/// instantiated against the concrete user type instead of going through
/// `anyerror` erasure at every borrow.
fn updatePanel(stage: *Stage, user: anytype, comptime mutate: anytype) !void {
    try stage.session.update(Panel, stage.panel, user, struct {
        fn run(value: *Panel, payload: anytype) void {
            @call(.auto, mutate, .{ value, payload });
        }
    }.run);
}

fn stageAlive(context: *const anyopaque) bool {
    const stage: *const Stage = @ptrCast(@alignCast(context));
    return stage.alive;
}

/// The Quit row's handler. The bridge resolves the row through the registry,
/// so this is the model's own record of what a native click reached.
fn onSystemAction(panel: *Panel, _: *const void, _: *Session) anyerror!void {
    panel.system_actions += 1;
    panel.last_system_action = QuitAction.name;
}

fn onAddRow(panel: *Panel, _: *const AddRow.Payload, _: *Session) anyerror!void {
    panel.addRow(route_action);
}

fn onRemoveRow(panel: *Panel, _: *const RemoveRow.Payload, _: *Session) anyerror!void {
    panel.removeRow(route_action);
}

fn onToggleFlag(panel: *Panel, _: *const ToggleFlag.Payload, _: *Session) anyerror!void {
    panel.toggleFlag(route_action);
}

fn onOpenDocument(panel: *Panel, payload: *const OpenDocument.Payload, _: *Session) anyerror!void {
    panel.openDocument(payload.path, route_action);
}

fn initPanel(title: []const u8) Panel {
    var panel: Panel = .{ .title = title };
    // A real committed value with the caret behind its last character, so the
    // field publishes text rather than an empty string and the first read back
    // is of something. The two endpoints are UTF-16 units, and this value is
    // ASCII, so the byte offsets and the units are the same numbers here.
    const value = "w23 field";
    panel.field.assign(value, value.len, value.len);
    // The document this window owns starts EMPTY, not at a placeholder URI.
    // A model that begins holding "w23://unset" reports a document it never
    // opened, and every later check against it would pass for the wrong
    // reason.
    return panel;
}

// ── the graphical half ──────────────────────────────

/// The device, the surface that presents into a real window, and the public
/// frame adapter that owns the text engine the App measures through.
///
/// Created in place and never moved: the cancellation callback reaches it by
/// address while a recording is open.
const GpuHalf = struct {
    gpu: noapi.Gpu,
    surface: noapi.Surface,
    adapter: frame_api.NativeFrame,
    quad_vert: Spv,
    quad_frag: Spv,
    sort_comp: Spv,
    fullscreen_vert: Spv,
    blit_oklab: Spv,

    fn init(self: *GpuHalf, gpa: std.mem.Allocator, io: Io, managed: *ManagedWindow) !void {
        // Every field left `undefined` below is written by a later statement of
        // this function before anything reads it, and each errdefer below
        // unwinds only the fields already assigned.
        self.* = .{
            // SAFETY: `noapi.Gpu.init` assigns it below, before its first use.
            .gpu = undefined,
            // SAFETY: `noapi.Surface.initSdl` assigns it below, before its use.
            .surface = undefined,
            // SAFETY: the adapter init at the end of this function fills it.
            .adapter = undefined,
            // SAFETY: `Spv.load` assigns it below, before the adapter uses it.
            .quad_vert = undefined,
            // SAFETY: `Spv.load` assigns it below, before the adapter uses it.
            .quad_frag = undefined,
            // SAFETY: `Spv.load` assigns it below, before the adapter uses it.
            .sort_comp = undefined,
            // SAFETY: `Spv.load` assigns it below, before the adapter uses it.
            .fullscreen_vert = undefined,
            // SAFETY: `Spv.load` assigns it below, before the adapter uses it.
            .blit_oklab = undefined,
        };
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
            .app_name = "w23-windows-smoke",
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
        // built on an unmeasured size. noapi creates and owns the platform
        // surface, so this file never holds an SDL wrapper to destroy and
        // never sees a Vulkan handle.
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
            .name = "w23_windows_smoke_blit_oklab",
        });
    }

    /// The App must already have detached from `gpuEndpoint`.
    fn deinit(self: *GpuHalf, gpa: std.mem.Allocator) void {
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

/// The window's own pixel size, measured by the platform rather than inferred
/// from the size that was requested. The render area is the acquired image,
/// never the window.
fn deviceExtent(managed: *ManagedWindow) !noapi.Extent2D {
    const pixels = try managed.native.sdl.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

/// One PRESENTED frame: the App's committed tree lowered into the Oklab
/// target, blitted into the acquired swapchain image, and presented.
///
/// The semantic snapshot the App committed with THIS frame comes back with
/// it, and is null in a run that configured no publication.
///
/// A swapchain that is out of date is not a failure: the adapter asks for the
/// window's real pixel size and the frame is retried, bounded, so a driver
/// that never settles fails the run instead of spinning.
fn presentFrame(stage: *Stage, gpu: *GpuHalf) !?*const semantics.Snapshot {
    const managed = stage.managed;
    const logical: nogui.geometry.WindowSize = .{
        .width = @floatFromInt(managed.observed.size.width),
        .height = @floatFromInt(managed.observed.size.height),
    };
    const viewport: frame_api.NativeFrame.Viewport = .{
        .logical = logical,
        .device = try deviceExtent(managed),
        .scale = try managed.observed.pixelScale(),
    };
    var attempts: u32 = 0;
    while (attempts < max_frame_attempts) : (attempts += 1) {
        // SAFETY: `beginFrame` fills the frame before any recording or
        // cancellation touches it.
        var surface_frame: frame_api.NativeFrame.Frame = undefined;
        if (!try gpu.adapter.beginFrame(&gpu.surface, viewport, &surface_frame)) continue;
        var recording = true;
        errdefer if (recording) gpu.adapter.cancelFrame(&surface_frame) catch
            @panic("surface recording cancellation failed");
        stage.tick += 1;
        const time_ms = sdl3.timer.getMillisecondsSinceInit();
        stage.app.dispatchRootFrame(time_ms);
        const out = try stage.app.frameWithGpuAtTime(
            stage.tick,
            time_ms,
            .{ .width = logical.width, .height = logical.height },
            &surface_frame.gpu_frame,
        );
        defer if (out.json) |json| stage.gpa.free(json);
        var frame_paint = try gpu.adapter.buildScene(.{}, &out);
        defer frame_paint.deinit();
        try gpu.adapter.recordScene(&gpu.surface, &surface_frame, &out, &frame_paint);
        // `present` closes the recording itself, so the guard drops BEFORE the
        // call: a present that fails must propagate its own error rather than
        // reach a cancellation of a recording that is gone.
        recording = false;
        try gpu.adapter.present(&gpu.surface, &surface_frame);
        managed.markPresented();
        managed.requestPresentation();
        stage.frames_committed += 1;
        stage.frames_presented += 1;
        return out.semantic_snapshot;
    }
    return error.SwapchainNeverSettled;
}

// ── the accessibility dispatcher ───────────────────────────

/// What every seam the accessibility drain replays needs: the App that owns
/// the committed tree and the focus manager, the Session and ticket this
/// window's model lives in, and the view that owns the field's live identity
/// and the bytes its last publication carried.
///
/// It stands apart from the Stage on purpose. A seam has no business reaching
/// a window, a surface or a device, and a value of this type can be built by
/// anything that owns a real App, a real model and a real committed tree —
/// which is what lets the dispatcher under test be the dispatcher that ships.
const NativeSeams = struct {
    app: *App,
    session: *Session,
    panel: nogui.Model(Panel),
    view: *PanelView,

    /// Mutate the model through the Session, which is the only way this file
    /// writes it. `mutate` is a comptime function value, so the Session's own
    /// handler is instantiated against the concrete user type instead of
    /// going through `anyerror` erasure at every borrow.
    fn update(self: *const NativeSeams, user: anytype, comptime mutate: anytype) !void {
        try self.session.update(Panel, self.panel, user, struct {
            fn run(value: *Panel, payload: anytype) void {
                @call(.auto, mutate, .{ value, payload });
            }
        }.run);
    }
};

/// The answer a live-text read carries out of its Session borrow.
///
/// The borrow handler writes through a pointer because the conversion can
/// fail, and a selection the live value cannot address is a refusal rather
/// than a snapped guess: a null state is what the seam reports as "this
/// control has no text answer", never a state with a made-up offset in it.
const LiveText = struct {
    state: ?semantics.TextEditState = null,
};

/// The seams the accessibility drain replays native requests through. Every
/// entry is an ordinary App seam, so a request a real screen reader would send
/// changes the same model a click changes and through the same `Session`.
const NativeDispatcher = struct {
    fn build(seams: *NativeSeams) semantics.Dispatcher {
        return .{
            .context = seams,
            .activate = onNativeActivate,
            .focus = onNativeFocus,
            .set_text = onNativeSetText,
            .read_text = onNativeReadText,
        };
    }

    fn onNativeActivate(context: *anyopaque, id: WidgetId) void {
        const seams: *NativeSeams = @ptrCast(@alignCast(context));
        const tree = seams.app.tree_ptr orelse return;
        seams.app.activate(tree, id);
    }

    fn onNativeFocus(context: *anyopaque, id: ?WidgetId) void {
        const seams: *NativeSeams = @ptrCast(@alignCast(context));
        const tree = seams.app.tree_ptr orelse return;
        if (id) |target| {
            _ = seams.app.focus_manager.set(tree, target, seams.app.focusObserver());
            return;
        }
        seams.app.focus_manager.blur(seams.app.focusObserver());
    }

    /// A screen-reader text edit, applied to the model's OWN field through the
    /// Session borrow every other route uses.
    ///
    /// Two guards stand in front of the model. The first is the identity: the
    /// core resolved this `id` from the published tree before it called, and a
    /// request naming any other node is refused rather than edited into this
    /// window's field. The second is the value, and only where there is one:
    /// a platform string is not validated UTF-8 by the time it arrives here,
    /// and a field that stored one would publish a run no character index can
    /// address. A selection-only request carries no bytes, so it has nothing
    /// to validate and nothing to refuse.
    fn onNativeSetText(
        context: *anyopaque,
        id: WidgetId,
        value: ?[]const u8,
        selection: semantics.TextSelection,
    ) bool {
        const seams: *NativeSeams = @ptrCast(@alignCast(context));
        const owner = seams.view.field_id orelse return false;
        if (!owner.eql(id)) return false;
        if (value) |bytes| {
            if (!std.unicode.utf8ValidateSlice(bytes)) return false;
            // A bounded field refuses a whole value it cannot store, and it
            // refuses BEFORE the model is updated: no composition is
            // cancelled, no selection moves and no partial value is kept,
            // because a value clipped to what fits is a different value from
            // the one a screen reader asked to put in the field. The room is
            // read from the model rather than from the published run, so it
            // is the capacity the field really has.
            var room: usize = 0;
            seams.session.read(Panel, seams.panel, &room, struct {
                fn run(panel: *const Panel, out: *usize) void {
                    out.* = panel.field.buffer.len;
                }
            }.run) catch return false;
            if (bytes.len > room) return false;
        }
        const request: SetText = .{ .value = value, .selection = selection };
        seams.update(&request, applySetText) catch return false;
        return true;
    }

    /// The field's LIVE value, selection and whole-value capacity, borrowed
    /// from the model through the Session every other route uses.
    ///
    /// Nothing here is read from the published run. A screen reader may send
    /// two edits before the app republishes, so a request composed against
    /// the bytes the last publication carried would edit where the text USED
    /// to be; these are the bytes the field holds now.
    ///
    /// The model's own selection is UTF-16 CODE UNITS, so it comes back
    /// through the protocol's one conversion, and an endpoint the live value
    /// cannot address is a refusal rather than a snapped guess. The two ends
    /// stay apart: `reversed` is what tells the fixed end from the moving
    /// one, and ordering both into a span would answer a backwards selection
    /// with a caret that was never drawn.
    fn onNativeReadText(context: *anyopaque, id: WidgetId) ?semantics.TextEditState {
        const seams: *NativeSeams = @ptrCast(@alignCast(context));
        const owner = seams.view.field_id orelse return null;
        if (!owner.eql(id)) return null;
        var live: LiveText = .{};
        seams.session.read(Panel, seams.panel, &live, struct {
            fn run(panel: *const Panel, out: *LiveText) !void {
                const value = panel.field.text();
                const anchor = text_input.utf16ToUtf8(value, panel.field.selection.anchor()) catch
                    return;
                const focus = text_input.utf16ToUtf8(value, panel.field.selection.cursor()) catch
                    return;
                out.state = .{
                    .value = value,
                    .selection = .{ .anchor = anchor, .focus = focus },
                    // The buffer this field actually stores into, which is the
                    // largest whole value a write can keep.
                    .capacity = panel.field.buffer.len,
                };
            }
        }.run) catch return null;
        return live.state;
    }

    fn applySetText(panel: *Panel, user: anytype) void {
        const payload: @TypeOf(user) = user;
        // A null value is the core saying this request carries a selection and
        // no contents. There are no bytes to write, so none are written: no
        // character byte, no character table and no marked composition moves,
        // and the edit counters do not move either. The endpoints are snapped
        // and converted against the bytes the model holds NOW, because the
        // core bounded them against the run it published and this model may
        // have moved on since. A selection the platform drew backwards stays
        // backwards: the anchor is kept apart from the moving end instead of
        // being ordered into a span and thrown away. A payload with no
        // selection either names nothing to move and is not credited as one.
        const value = payload.value orelse {
            const selection = payload.selection orelse return;
            const live = panel.field.text();
            panel.field.select(
                unitsAt(live, snapToCodepoint(live, selection.anchor)),
                unitsAt(live, snapToCodepoint(live, selection.focus)),
            );
            panel.note(route_accessibility);
            return;
        };
        // A value is the field's ENTIRE new contents, empty bytes included,
        // and it is written exactly once. Its selection addresses THAT value,
        // so both endpoints are snapped to codepoint boundaries of the new
        // bytes and converted once. A whole write that names no selection
        // collapses the caret after the last byte, which is where the core
        // puts it for a provider that sends whole new contents.
        const wanted = payload.selection orelse
            semantics.TextSelection.caret(value.len);
        panel.field.assign(
            value,
            unitsAt(value, snapToCodepoint(value, wanted.anchor)),
            unitsAt(value, snapToCodepoint(value, wanted.focus)),
        );
        panel.native_edits += 1;
        panel.note(route_accessibility);
    }
};

/// One native text request, in the core's own byte offsets.
///
/// This is not an insertion over a range of the OLD field. The core composes
/// the entire new value first — a `replace_selected_text` splices the
/// replacement into the published run and a string `set_value` hands over the
/// field's whole new contents — and hands THAT to the seam together with a
/// selection inside it, or hands over the selection alone.
///
/// A `value` is therefore the whole-value path whenever it is present: empty
/// bytes, bytes that borrow the run the snapshot published and bytes that
/// borrow the model's own buffer are all whole writes, and no pointer, length,
/// equality or buffer owner is asked which one it is. A null `value` is the
/// selection-only path, and it moves the caret and nothing else.
///
/// `selection` is present on every request the core sends and required beside
/// a null `value`. A whole write may leave it out, and the caret then collapses
/// after the last byte, which is what the hand-built case below relies on.
const SetText = struct {
    value: ?[]const u8,
    selection: ?semantics.TextSelection,
};

test "api-w23 Windows field assigns native whole values and preserves directional Unicode selection" {
    var panel: Panel = .{ .title = "field" };
    panel.field.assign("old value", 1, 4);
    panel.field.marked = .{ .start = 1, .end = 3 };
    NativeDispatcher.applySetText(&panel, &SetText{
        .value = "é😀z",
        .selection = .{ .anchor = 6, .focus = 2 },
    });
    try std.testing.expectEqualStrings("é😀z", panel.field.text());
    try std.testing.expectEqual(@as(usize, 1), panel.field.selection.range.start);
    try std.testing.expectEqual(@as(usize, 3), panel.field.selection.range.end);
    try std.testing.expect(panel.field.selection.reversed);
    try std.testing.expectEqual(@as(?text_input.Utf16Range, null), panel.field.marked);
    try std.testing.expectEqualSlices(u8, &.{ 2, 4, 1 }, panel.field.lengths[0..panel.field.characters]);
    NativeDispatcher.applySetText(&panel, &SetText{ .value = "a", .selection = null });
    try std.testing.expectEqualStrings("a", panel.field.text());
    try std.testing.expectEqual(@as(usize, 1), panel.field.selection.range.start);
    try std.testing.expectEqual(@as(usize, 1), panel.field.selection.range.end);
    try std.testing.expect(!panel.field.selection.reversed);
    try std.testing.expectEqual(@as(u32, 2), panel.native_edits);
}

test "api-w23 Windows field real-font hit-testing accepts empty and full-capacity values" {
    const gpa = std.testing.allocator;
    var service = try Cpu.TextService.init(gpa);
    defer service.deinit();
    _ = try service.addFont(.{ .family = field_family, .bytes = @embedFile("InterVariable.ttf") });
    var shape = FieldShape.init(gpa, &service);
    defer shape.deinit();
    const box: geometry.WindowRect = .{ .x = 10, .y = 20, .w = 2000, .h = 60 };
    try shape.measure("", &.{}, box);
    try std.testing.expectEqual(@as(?usize, 0), shape.byteNearest(.{ .x = 18, .y = 50 }));
    try std.testing.expectEqual(@as(?usize, null), shape.byteNearest(.{ .x = 9, .y = 50 }));
    const empty = shape.caret(0) orelse return error.NoEmptyFieldCaret;
    try std.testing.expectEqual(box.x + field_inset, empty.area.x);
    try std.testing.expectEqual(field_caret_width, empty.area.w);
    try std.testing.expect(std.math.isFinite(empty.area.h) and empty.area.h > 0 and empty.area.h <= box.h);
    const value: [field_capacity]u8 = @splat('a');
    const lengths: [field_capacity]u8 = @splat(1);
    try shape.measure(&value, &lengths, box);
    try std.testing.expectEqual(
        @as(?usize, field_capacity),
        shape.byteNearest(.{ .x = box.x + shape.endX() + 1, .y = 50 }),
    );
    try shape.measure(&value, &lengths, .{ .x = box.x, .y = box.y, .w = 40, .h = box.h });
    try std.testing.expect(shape.caret(field_capacity) == null);
}

test "api-w23 Windows field shift movement and erase preserve whole Unicode characters" {
    const gpa = std.testing.allocator;
    var service = try Cpu.TextService.init(gpa);
    defer service.deinit();
    _ = try service.addFont(.{ .family = field_family, .bytes = @embedFile("InterVariable.ttf") });
    var shape = FieldShape.init(gpa, &service);
    defer shape.deinit();
    var field: Field = .{};
    try field.replaceRegion(null, "é😀z");
    try shape.measure(field.text(), field.lengths[0..field.characters], .{ .x = 0, .y = 0, .w = 2000, .h = 36 });
    const layout = &shape.layout.?;
    const first = try field.moveCaret(.{ .unit = .grapheme, .direction = .backward, .extend = true }, layout);
    try std.testing.expectEqual(@as(usize, 3), first.range.start);
    try std.testing.expectEqual(@as(usize, 4), first.range.end);
    try std.testing.expect(first.reversed);
    const second = try field.moveCaret(.{ .unit = .grapheme, .direction = .backward, .extend = true }, layout);
    try std.testing.expectEqual(@as(usize, 1), second.range.start);
    try std.testing.expectEqual(@as(usize, 4), second.range.end);
    try std.testing.expect(second.reversed);
    try field.eraseRegion(.{ .unit = .grapheme, .backward = true }, layout);
    try std.testing.expectEqualStrings("é", field.text());
    try std.testing.expectEqual(@as(usize, 1), field.selection.range.start);
    try std.testing.expectEqual(@as(usize, 1), field.selection.range.end);

    for ([_]struct { value: []const u8, before_last: usize }{
        .{ .value = "ae\u{301}b", .before_last = 3 },
        .{ .value = "a👩‍👩‍👧‍👦b", .before_last = 12 },
    }) |example| {
        field.assign(example.value, totalUnits(example.value), totalUnits(example.value));
        const run = try shape.forField(&field);
        const tail = try field.moveCaret(.{ .unit = .grapheme, .direction = .backward, .extend = true }, run);
        try std.testing.expectEqual(example.before_last, tail.range.start);
        const cluster = try field.moveCaret(.{ .unit = .grapheme, .direction = .backward, .extend = true }, run);
        try std.testing.expectEqual(@as(usize, 1), cluster.range.start);
        try field.eraseRegion(.{ .unit = .grapheme, .backward = true }, run);
        try std.testing.expectEqualStrings("a", field.text());
    }
    field.assign("a bcd", 5, 5);
    try field.eraseRegion(.{ .unit = .word, .backward = true }, try shape.forField(&field));
    try std.testing.expectEqualStrings("a ", field.text());
}

test "api-w23 Windows field native caret geometry matches the production caption layout" {
    const gpa = std.testing.allocator;
    const context = try Test.TextContext(Cpu).create(gpa, .{
        .fonts = &.{.{ .family = field_family, .bytes = @embedFile("InterVariable.ttf") }},
    });
    var registry = action.Registry.init(gpa, &context.base.session) catch |err| {
        try context.deinit();
        return err;
    };
    defer registry.deinit();
    defer context.deinit() catch unreachable;
    var panel: Panel = .{ .title = "field" };
    panel.field.assign("iii WWW", 7, 7);
    var owner = try context.base.session.create(Panel, &panel);
    defer context.base.session.release(Panel, &owner) catch unreachable;
    var view: PanelView = .{
        .app = &context.base.app,
        .registry = &registry,
        .title = "field",
        .session = &context.base.session,
        .panel = owner,
    };
    try context.base.app.mountModelRoot(Panel, PanelView, owner, &view);
    const frame = try context.base.flushFrame();
    defer if (frame.json) |json| gpa.free(json);
    const tree = context.base.app.tree_ptr.?;
    const carrier = tree.node(view.field_node).?;
    var caption: ?*const widget.WidgetNode = null;
    for (carrier.children.items) |id| {
        const child = tree.node(id).?;
        if (child.kind == .label) {
            caption = child;
            break;
        }
    }
    const label = caption orelse return error.NoFieldCaption;
    const label_box = nogui.visualContentRect(tree, label.id);
    const insets = widget.textInsets(label.kind);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var painted = try context.text.textService().nodeLayoutIn(
        scratch.allocator(),
        label.kind.label.text,
        label.text_request.?.*,
        .{
            .width = label_box.w - insets.leading - insets.trailing,
            .overflow = label.text_overflow,
            .box_height = label_box.h - insets.top - insets.bottom,
        },
        @floatFromInt(Cpu.font_size_px),
    );
    defer painted.release();
    var shape = FieldShape.init(gpa, context.text.textService());
    defer shape.deinit();
    const border = widget.visualBorderRect(tree, view.field_node);
    const Measure = struct {
        shape: *FieldShape,
        box: geometry.WindowRect,
        const Self = @This();

        fn run(value: *const Panel, input: *Self) !void {
            try input.shape.measure(value.field.text(), value.field.lengths[0..value.field.characters], input.box);
        }
    };
    var input: Measure = .{
        .shape = &shape,
        .box = .{ .x = border.x, .y = border.y, .w = border.w, .h = border.h },
    };
    try context.base.session.read(Panel, owner, &input, Measure.run);
    const caret = shape.caret(0) orelse return error.NoVisibleFieldCaret;
    try std.testing.expectApproxEqAbs(label_box.x + insets.leading, caret.area.x, 0.001);
    const paint_y = label_box.y + insets.top +
        @max(0, (label_box.h - insets.top - insets.bottom - painted.height) / 2);
    try std.testing.expectApproxEqAbs(paint_y + painted.lines[0].y, caret.area.y, 0.001);
    const end = shape.caret(painted.content.len) orelse return error.NoVisibleFieldEndCaret;
    const position = try painted.byteToPosition(painted.content.len, .downstream);
    try std.testing.expectApproxEqAbs(label_box.x + insets.leading + position.x, end.area.x, 0.001);

    view.field_owner = owner.weak().erase();
    view.field_shape = &shape;
    defer context.base.app.textInputManager().clear();
    try view.bindFieldEndpoint();
    if (try context.base.dispatch(.{ .text_input = .{ .text = "W" } })) |output| {
        if (output.json) |json| gpa.free(json);
    }
    // Native candidate placement is queried before a new frame is painted.
    const edited_caret = (try context.base.app.textInputManager().caretGeometry()) orelse
        return error.NoEditedFieldCaret;
    const next_frame = try context.base.flushFrame();
    defer if (next_frame.json) |json| gpa.free(json);
    const next_tree = context.base.app.tree_ptr.?;
    const next_carrier = next_tree.node(view.field_node).?;
    var next_caption: ?*const widget.WidgetNode = null;
    for (next_carrier.children.items) |id| {
        const child = next_tree.node(id).?;
        if (child.kind == .label) {
            next_caption = child;
            break;
        }
    }
    const next_label = next_caption orelse return error.NoEditedFieldCaption;
    const next_box = nogui.visualContentRect(next_tree, next_label.id);
    var next_painted = try context.text.textService().nodeLayoutIn(
        scratch.allocator(),
        next_label.kind.label.text,
        next_label.text_request.?.*,
        .{
            .width = next_box.w - insets.leading - insets.trailing,
            .overflow = next_label.text_overflow,
            .box_height = next_box.h - insets.top - insets.bottom,
        },
        @floatFromInt(Cpu.font_size_px),
    );
    defer next_painted.release();
    const next_position = try next_painted.byteToPosition(next_painted.content.len, .downstream);
    try std.testing.expectApproxEqAbs(
        next_box.x + insets.leading + next_position.x,
        edited_caret.area.x,
        0.001,
    );
}

test "api-w23 Windows field pointer refocus resumes committed Unicode input" {
    const gpa = std.testing.allocator;
    const context = try Test.TextContext(Cpu).create(gpa, .{
        .fonts = &.{.{ .family = field_family, .bytes = @embedFile("InterVariable.ttf") }},
    });
    var registry = action.Registry.init(gpa, &context.base.session) catch |err| {
        try context.deinit();
        return err;
    };
    defer registry.deinit();
    defer context.deinit() catch unreachable;
    var initial: Panel = .{ .title = "field" };
    var owner = try context.base.session.create(Panel, &initial);
    defer context.base.session.release(Panel, &owner) catch unreachable;
    var shape = FieldShape.init(gpa, context.text.textService());
    defer {
        context.base.app.textInputManager().clear();
        shape.deinit();
    }
    var view: PanelView = .{
        .app = &context.base.app,
        .registry = &registry,
        .title = "field",
        .session = &context.base.session,
        .panel = owner,
        .field_owner = owner.weak().erase(),
        .field_shape = &shape,
    };
    try context.base.app.mountModelRoot(Panel, PanelView, owner, &view);
    const frame = try context.base.flushFrame();
    defer if (frame.json) |json| gpa.free(json);
    const Script = struct {
        fn send(ctx: *Test.Context, input: nogui.event.Event) !void {
            if (try ctx.dispatch(input)) |output| {
                if (output.json) |json| ctx.gpa.free(json);
            }
        }
        fn click(ctx: *Test.Context, field_node: FrameNodeId) !void {
            const rect = widget.visualBorderRect(ctx.app.tree_ptr.?, field_node);
            const x = rect.x + rect.w / 2;
            const y = rect.y + rect.h / 2;
            try send(ctx, .{ .mouse_down = .{ .button = .left, .x = x, .y = y } });
            try send(ctx, .{ .mouse_up = .{ .button = .left, .x = x, .y = y } });
        }
        fn text(panel: *const Panel, expected: []const u8) !void {
            try std.testing.expectEqualStrings(expected, panel.field.text());
        }
    };
    try Script.click(context.base, view.field_node);
    try Script.send(context.base, .{ .text_input = .{ .text = "é" } });
    try context.base.session.read(Panel, owner, @as([]const u8, "é"), Script.text);
    try Script.send(context.base, .window_focus_lost);
    try Script.send(context.base, .{ .text_input = .{ .text = "discarded" } });
    try context.base.session.read(Panel, owner, @as([]const u8, "é"), Script.text);
    try Script.click(context.base, view.field_node);
    try Script.send(context.base, .{ .text_input = .{ .text = "😀" } });
    try context.base.session.read(Panel, owner, @as([]const u8, "é😀"), Script.text);
}

/// Everything a whole-value write has to produce, read back through the
/// Session in ONE borrow: the bytes, the caret collapsed behind their last
/// one, and the character table measured from those same bytes.
const FieldReading = struct {
    text: []const u8,
    start: usize,
    end: usize,
    characters: usize,
    lengths: []const u8,
    edits: u32,
    native_edits: u32,
    route: []const u8,
};

/// Assert one field reading against the model's own Session borrow.
///
/// Every number below comes from the model the seam mutated, so a test can
/// never pass on a value the test itself kept.
fn expectField(
    session: *Session,
    owner: nogui.Model(Panel),
    want: FieldReading,
) !void {
    try session.read(Panel, owner, want, struct {
        fn run(panel: *const Panel, expected: FieldReading) !void {
            try std.testing.expectEqualStrings(expected.text, panel.field.text());
            try std.testing.expectEqual(expected.start, panel.field.selection.range.start);
            try std.testing.expectEqual(expected.end, panel.field.selection.range.end);
            try std.testing.expect(!panel.field.selection.reversed);
            try std.testing.expectEqual(expected.characters, panel.field.characters);
            try std.testing.expectEqualSlices(
                u8,
                expected.lengths,
                panel.field.lengths[0..panel.field.characters],
            );
            try std.testing.expectEqual(expected.edits, panel.field.edits);
            try std.testing.expectEqual(expected.native_edits, panel.native_edits);
            try std.testing.expectEqualStrings(expected.route, panel.last_route);
        }
    }.run);
}

/// Why a request was refused, or null when the model actually changed.
///
/// A refused write and an applied one must never read the same in a test, so
/// every dispatch below is checked against this rather than against an
/// inspection of the published action set.
fn refusal(outcome: semantics.Outcome) ?semantics.Failure {
    return switch (outcome) {
        .applied => null,
        .ignored => |why| why,
    };
}

test "api-w23 Windows field applies the whole-value SetValue a screen reader drives" {
    const gpa = std.testing.allocator;
    const context = try Test.TextContext(Cpu).create(gpa, .{
        .fonts = &.{.{ .family = field_family, .bytes = @embedFile("InterVariable.ttf") }},
    });
    var registry = action.Registry.init(gpa, &context.base.session) catch |err| {
        try context.deinit();
        return err;
    };
    defer registry.deinit();
    defer context.deinit() catch unreachable;
    var initial: Panel = initPanel(window_title);
    var owner = try context.base.session.create(Panel, &initial);
    defer context.base.session.release(Panel, &owner) catch unreachable;
    var shape = FieldShape.init(gpa, context.text.textService());
    defer shape.deinit();
    var view: PanelView = .{
        .app = &context.base.app,
        .registry = &registry,
        .title = window_title,
        .session = &context.base.session,
        .panel = owner,
        .field_owner = owner.weak().erase(),
        .field_shape = &shape,
    };
    const app = &context.base.app;
    try app.mountModelRoot(Panel, PanelView, owner, &view);
    // The carrier's live identity is stamped by the frame that commits it, and
    // the annotator keys on that identity rather than on a label, so the field
    // is published from the frame after that one.
    const identity = try context.base.flushFrame();
    defer if (identity.json) |json| gpa.free(json);

    var publisher_storage = semantics.Publisher.init(gpa);
    defer publisher_storage.deinit();
    app.semantic_publication = .{
        .publisher = &publisher_storage,
        .window_name = view.title,
        .annotator = .{ .context = &view, .annotate = annotateField },
    };
    defer app.semantic_publication = null;
    const frame = try context.base.flushFrame();
    defer if (frame.json) |json| gpa.free(json);
    const snapshot = frame.semantic_snapshot orelse return error.MissingSemanticSnapshot;
    // The field is found by the ROLE its own annotator gave it, because that is
    // what a client resolves a write against.
    var published: ?*const semantics.Node = null;
    for (snapshot.nodes) |*node| {
        if (node.role == .text_input) {
            published = node;
            break;
        }
    }
    const entry = published orelse return error.NoPublishedTextField;

    var seams: NativeSeams = .{
        .app = app,
        .session = &context.base.session,
        .panel = owner,
        .view = &view,
    };
    const dispatcher = NativeDispatcher.build(&seams);
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
    try expectField(&context.base.session, owner, .{
        .text = whole,
        .start = 8,
        .end = 8,
        .characters = 8,
        .lengths = &.{ 1, 1, 2, 2, 1, 1, 3, 3 },
        .edits = 2,
        .native_edits = 1,
        .route = route_accessibility,
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
    try expectField(&context.base.session, owner, .{
        .text = "",
        .start = 0,
        .end = 0,
        .characters = 0,
        .lengths = &.{},
        .edits = 3,
        .native_edits = 2,
        .route = route_accessibility,
    });

    // A selection-only request carries NO contents, so the run the snapshot
    // published never travels back into the model and there is nothing here
    // that could undo the write above. The field keeps its bytes, its
    // character table and both edit counters, and only the caret moves.
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = whole,
        }, &dispatcher, scratch)),
    );
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_text_selection,
            .selection = .{ .anchor = 2, .focus = 2 },
        }, &dispatcher, scratch)),
    );
    try expectField(&context.base.session, owner, .{
        .text = whole,
        .start = 2,
        .end = 2,
        .characters = 8,
        .lengths = &.{ 1, 1, 2, 2, 1, 1, 3, 3 },
        .edits = 4,
        .native_edits = 3,
        .route = route_accessibility,
    });

    // The ORDINARY half is untouched by any of it: a committed keystroke
    // through the App's own event path edits the same model, at the caret the
    // selection request just placed.
    try view.bindFieldEndpoint();
    if (try context.base.dispatch(.{ .text_input = .{ .text = "é" } })) |output| {
        if (output.json) |json| gpa.free(json);
    }
    try expectField(&context.base.session, owner, .{
        .text = "Gréüße ✓€",
        .start = 3,
        .end = 3,
        .characters = 9,
        .lengths = &.{ 1, 1, 2, 2, 2, 1, 1, 3, 3 },
        .edits = 5,
        .native_edits = 3,
        .route = route_text_input,
    });
    // A whole value the platform sends AGAIN, after the model has moved on.
    // The snapshot still carries "w23 field", and this payload spells those
    // same bytes in the PLATFORM's own buffer. It is a fresh write because the
    // request carried contents at all: no pointer, length, equality or buffer
    // owner decides it, so a consumer that looked for one would have to call
    // this byte-identical case something the contract has no word for.
    var again: [9]u8 = "w23 field".*;
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = "é",
        }, &dispatcher, scratch)),
    );
    try expectField(&context.base.session, owner, .{
        .text = "é",
        .start = 1,
        .end = 1,
        .characters = 1,
        .lengths = &.{2},
        .edits = 6,
        .native_edits = 4,
        .route = route_accessibility,
    });
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = again[0..],
        }, &dispatcher, scratch)),
    );
    try expectField(&context.base.session, owner, .{
        .text = "w23 field",
        .start = 9,
        .end = 9,
        .characters = 9,
        .lengths = &.{ 1, 1, 1, 1, 1, 1, 1, 1, 1 },
        .edits = 7,
        .native_edits = 5,
        .route = route_accessibility,
    });
    // A BACKWARDS selection is a real selection: its anchor sits after its
    // focus. The model keeps the two ends apart, and the live-text answer
    // carries both through the Session borrow instead of collapsing them into
    // the span's start, which would answer a drag the user made backwards
    // with a caret they never drew.
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_text_selection,
            .selection = .{ .anchor = 6, .focus = 1 },
        }, &dispatcher, scratch)),
    );
    const field_id = view.field_id orelse return error.NoFieldIdentity;
    const live = dispatcher.read_text.?(dispatcher.context, field_id) orelse
        return error.NoLiveTextAnswer;
    try std.testing.expectEqualStrings("w23 field", live.value);
    try std.testing.expectEqual(@as(usize, 6), live.selection.anchor);
    try std.testing.expectEqual(@as(usize, 1), live.selection.focus);
    // The capacity is the buffer the field really stores into, so it is the
    // size of the answer a whole write can keep.
    try std.testing.expectEqual(@as(usize, field_capacity), live.capacity);

    // The next ORDINARY replacement resolves against that live selection, not
    // against the run this snapshot published: bytes 1..6 are "23 fi", they
    // go, and "X" lands where they were.
    try std.testing.expectEqual(
        @as(?semantics.Failure, null),
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .replace_selected_text,
            .text = "X",
        }, &dispatcher, scratch)),
    );
    try expectField(&context.base.session, owner, .{
        .text = "wXeld",
        .start = 2,
        .end = 2,
        .characters = 5,
        .lengths = &.{ 1, 1, 1, 1, 1 },
        .edits = 8,
        .native_edits = 6,
        .route = route_accessibility,
    });

    // A whole value the fixed buffer cannot store is refused, and refusing it
    // changes nothing: the model keeps its bytes, its caret and its counters.
    // Storing the 192 bytes that fit would leave a value a screen reader never
    // sent, presented as the one it did.
    const oversized: [field_capacity + 1]u8 = @splat('x');
    try std.testing.expect(
        refusal(snapshot.dispatch(.{
            .id = entry.id,
            .action = .set_value,
            .text = &oversized,
        }, &dispatcher, scratch)) != null,
    );
    try expectField(&context.base.session, owner, .{
        .text = "wXeld",
        .start = 2,
        .end = 2,
        .characters = 5,
        .lengths = &.{ 1, 1, 1, 1, 1 },
        .edits = 8,
        .native_edits = 6,
        .route = route_accessibility,
    });
}

test "api-w23 Windows whole value may overlap its own model storage" {
    var panel = initPanel(window_title);
    panel.field.assign("A😀Ωtail", 8, 8);
    const before = panel.field.edits;
    const value = panel.field.text()[1..];
    const end = totalUnits(value);
    panel.field.assign(value, end, end);
    try std.testing.expectEqualStrings("😀Ωtail", panel.field.text());
    try std.testing.expectEqual(@as(usize, 7), panel.field.selection.anchor());
    try std.testing.expectEqual(@as(usize, 7), panel.field.selection.cursor());
    try std.testing.expectEqual(@as(usize, 6), panel.field.characters);
    try std.testing.expectEqualSlices(u8, &.{ 4, 2, 1, 1, 1, 1 }, panel.field.lengths[0..panel.field.characters]);
    try std.testing.expectEqual(before + 1, panel.field.edits);
    try std.testing.expect(panel.field.marked == null);
}

// ── the notification trace ─────────────────────────

/// What one notification response carried. The response's own key is borrowed
/// from the provider's message buffer, so the key is copied into a buffer this
/// run owns.
const ResponseTrace = struct {
    responses: u32 = 0,
    actions: u32 = 0,
    closings: u32 = 0,
    last_id: notifications.NotificationId = 0,
    last_key: [64]u8 = @splat(0),
    last_key_len: usize = 0,
    last_reason: []const u8 = route_none,
    provider_lost: u32 = 0,

    fn lastKey(self: *const ResponseTrace) []const u8 {
        return self.last_key[0..self.last_key_len];
    }

    fn onResponse(
        context: ?*anyopaque,
        id: notifications.NotificationId,
        response: notifications.Response,
    ) void {
        const self: *ResponseTrace = @ptrCast(@alignCast(context orelse return));
        self.responses += 1;
        self.last_id = id;
        switch (response) {
            .action => |answer| {
                self.actions += 1;
                const taken = @min(answer.key.len, self.last_key.len);
                @memcpy(self.last_key[0..taken], answer.key[0..taken]);
                self.last_key_len = taken;
            },
            .closed => |closed| {
                self.closings += 1;
                self.last_reason = @tagName(closed.reason);
            },
            .provider_lost => {
                self.provider_lost += 1;
                self.last_reason = "provider_lost";
            },
        }
    }

    fn handler(self: *ResponseTrace) notifications.ActionHandler {
        return .{ .context = self, .callback = ResponseTrace.onResponse };
    }
};

/// A weak owner whose liveness is a real flag on a real object, because the
/// notification and capture owner-loss paths both have to be observable.
const FlagOwner = struct {
    alive: bool = true,

    fn probe(context: *const anyopaque) bool {
        const self: *const FlagOwner = @ptrCast(@alignCast(context));
        return self.alive;
    }

    fn weak(self: *FlagOwner) weak_owner.WeakOwner {
        return .{ .context = self, .is_alive_fn = FlagOwner.probe };
    }
};

/// The same flag seen through the capture facade's own owner type, which is the
/// shared one and so the same function serves both.
fn captureOwnerOf(owner: *FlagOwner) capture.WeakOwner {
    return .{ .context = owner, .is_alive_fn = FlagOwner.probe };
}

// ── argument parsing and the approval gates ────────────────

/// An authorization that has to be typed exactly. A near miss is a refusal,
/// because a scope nobody approved is not a shorter version of one that was.
fn requireScope(given: ?[]const u8, expected: []const u8, flag: []const u8) !void {
    const text = given orelse {
        std.log.err("missing {s}", .{flag});
        return error.MissingAuthorizationScope;
    };
    if (!std.mem.eql(u8, text, expected)) {
        std.log.err("{s} does not match the authorized scope", .{flag});
        std.log.err("expected exactly: {s}", .{expected});
        return error.AuthorizationScopeMismatch;
    }
}

fn identityScopeText(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        identity_scope_prefix ++ "{s}" ++ identity_scope_suffix,
        .{app_id},
    );
}

fn credentialScopeText(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        credential_scope_prefix ++ "{s}" ++ credential_scope_middle ++ "{s}" ++ credential_scope_suffix,
        .{ service, account },
    );
}

fn requireIdentityAuthorization(options: Options) ![]const u8 {
    if (!options.authorize_identity) {
        std.log.err("every native command claims the process identity first, so {s} is required", .{
            authorize_identity_flag,
        });
        return error.MissingIdentityAuthorization;
    }
    const app_id = options.app_id orelse {
        std.log.err("missing {s}", .{app_id_flag});
        return error.MissingAppId;
    };
    if (!windows.app_identity.isWellFormed(app_id)) {
        std.log.err(
            "{s} must be dot-separated groups of ASCII alphanumerics and dashes, at most {d} characters",
            .{ app_id_flag, windows.app_identity.max_app_id },
        );
        return error.MalformedAppId;
    }
    const expected = try identityScopeText(options.gpa, app_id);
    defer options.gpa.free(expected);
    try requireScope(options.identity_scope, expected, identity_scope_flag);
    return app_id;
}

/// The namespace refusal boundary. The credential arm runs one namespace shape
/// and nothing else: the fixed smoke service and an account that is this run's
/// own prefix plus a nonce. A real service or account never reaches a provider,
/// so no existing credential is even searched for.
fn checkNamespaceForm(options: Options) ![]const u8 {
    const service = options.service orelse {
        std.log.err("missing {s}", .{service_flag});
        return error.MissingServiceNamespace;
    };
    if (!std.mem.eql(u8, service, smoke_service)) {
        std.log.err("{s} must be exactly \"{s}\"", .{ service_flag, smoke_service });
        return error.ServiceIsNotTheSmokeService;
    }
    const account = options.account orelse {
        std.log.err("missing {s}", .{account_flag});
        return error.MissingAccountNamespace;
    };
    if (!std.mem.startsWith(u8, account, account_prefix)) {
        std.log.err("{s} must start with \"{s}\"", .{ account_flag, account_prefix });
        return error.AccountIsNotSynthetic;
    }
    const nonce = account[account_prefix.len..];
    if (nonce.len < min_nonce_len or nonce.len > max_nonce_len) {
        std.log.err(
            "{s} must be \"{s}<nonce>\" with a nonce of {d}-{d} characters of a-z and 0-9 that is never reused",
            .{ account_flag, account_prefix, min_nonce_len, max_nonce_len },
        );
        return error.AccountNonceHasBadLength;
    }
    for (nonce) |byte| {
        const digit = byte >= '0' and byte <= '9';
        const lower = byte >= 'a' and byte <= 'z';
        if (!digit and !lower) {
            std.log.err("{s} must use only a-z and 0-9 in the nonce", .{account_flag});
            return error.AccountNonceIsNotLowerAlnum;
        }
    }
    return account;
}

fn parseCaptureSource(text: []const u8) !capture.SourceType {
    if (std.mem.eql(u8, text, "monitor")) return .monitor;
    if (std.mem.eql(u8, text, "window")) return .window;
    if (std.mem.eql(u8, text, "virtual")) return .virtual;
    std.log.err("{s} must be exactly monitor, window or virtual", .{capture_source_flag});
    return error.UnknownCaptureSource;
}

/// `shell_argument` is the single argument the SHELL wrote on this process's
/// own command line, as the platform reported it, or null when there is none.
///
/// The shell's line is taken FIRST and on its own: `exe <entry>` carries no
/// command word and no approvals, because the shell writes none. A command
/// word still wins where there is one, because `probe` typed by a person is a
/// person's line and the shell never types a command word. So the two
/// invocation forms are told apart by the shape the shell writes, not by a
/// flag this binary invented for the purpose.
fn parseArgs(
    gpa: std.mem.Allocator,
    init: std.process.Init,
    shell_argument: ?[]const u8,
) !Options {
    var options: Options = .{ .gpa = gpa };
    if (shell_argument) |argument| {
        if (std.meta.stringToEnum(Command, argument) == null) {
            options.command = .activation;
            options.activation_argument = argument;
            return options;
        }
    }
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    var saw_command = false;
    while (args.next()) |arg| {
        if (!saw_command and !std.mem.startsWith(u8, arg, "--")) {
            options.command = std.meta.stringToEnum(Command, arg) orelse {
                std.log.err("unknown command: {s}", .{arg});
                return error.UnknownCommand;
            };
            saw_command = true;
        } else if (std.mem.eql(u8, arg, authorize_identity_flag)) {
            options.authorize_identity = true;
        } else if (std.mem.eql(u8, arg, identity_scope_flag)) {
            options.identity_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, app_id_flag)) {
            options.app_id = args.next() orelse return error.MissingAppId;
        } else if (std.mem.eql(u8, arg, authorize_window_flag)) {
            options.authorize_window = true;
        } else if (std.mem.eql(u8, arg, window_scope_flag)) {
            options.window_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, authorize_menu_flag)) {
            options.authorize_menu = true;
        } else if (std.mem.eql(u8, arg, menu_scope_flag)) {
            options.menu_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, authorize_jump_flag)) {
            options.authorize_jump = true;
        } else if (std.mem.eql(u8, arg, jump_scope_flag)) {
            options.jump_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, authorize_association_flag)) {
            options.authorize_association = true;
        } else if (std.mem.eql(u8, arg, association_scope_flag)) {
            options.association_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, authorize_notify_flag)) {
            options.authorize_notify = true;
        } else if (std.mem.eql(u8, arg, notify_scope_flag)) {
            options.notify_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, authorize_credential_flag)) {
            options.authorize_credential = true;
        } else if (std.mem.eql(u8, arg, credential_scope_flag)) {
            options.credential_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, service_flag)) {
            options.service = args.next() orelse return error.MissingServiceNamespace;
        } else if (std.mem.eql(u8, arg, account_flag)) {
            options.account = args.next() orelse return error.MissingAccountNamespace;
        } else if (std.mem.eql(u8, arg, authorize_capture_flag)) {
            options.authorize_capture = true;
        } else if (std.mem.eql(u8, arg, capture_scope_flag)) {
            options.capture_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, capture_source_flag)) {
            options.capture_source = try parseCaptureSource(
                args.next() orelse return error.MissingCaptureSource,
            );
        } else if (std.mem.eql(u8, arg, authorize_accessibility_flag)) {
            options.authorize_accessibility = true;
        } else if (std.mem.eql(u8, arg, accessibility_scope_flag)) {
            options.accessibility_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, authorize_cleanup_flag)) {
            options.authorize_cleanup = true;
        } else if (std.mem.eql(u8, arg, cleanup_scope_flag)) {
            options.cleanup_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, toast_id_flag)) {
            options.toast_id = std.fmt.parseInt(u32, args.next() orelse
                return error.MissingToastId, 10) catch return error.BadToastId;
        } else if (std.mem.eql(u8, arg, toast_activator_flag)) {
            options.toast_activator = args.next() orelse return error.MissingActivatorClassId;
        } else if (std.mem.eql(u8, arg, toast_group_flag)) {
            options.toast_group = args.next() orelse return error.MissingToastGroup;
        } else if (std.mem.eql(u8, arg, frames_flag)) {
            options.frames = std.fmt.parseInt(u32, args.next() orelse
                return error.MissingFrames, 10) catch return error.BadFrames;
            options.frames = std.math.clamp(options.frames, min_frames, max_frames);
        } else if (std.mem.eql(u8, arg, hold_flag)) {
            options.hold_ms = std.fmt.parseInt(u64, args.next() orelse
                return error.MissingHoldMs, 10) catch return error.BadHoldMs;
            options.hold_ms = std.math.clamp(options.hold_ms, min_hold_ms, max_hold_ms);
        } else if (std.mem.eql(u8, arg, wait_flag)) {
            options.wait_ms = std.fmt.parseInt(u64, args.next() orelse
                return error.MissingWaitMs, 10) catch return error.BadWaitMs;
            options.wait_ms = std.math.clamp(options.wait_ms, min_wait_ms, max_wait_ms);
        } else if (std.mem.eql(u8, arg, expiry_flag)) {
            options.expiry_ms = std.fmt.parseInt(i32, args.next() orelse
                return error.MissingExpiryMs, 10) catch return error.BadExpiryMs;
            options.expiry_ms = std.math.clamp(options.expiry_ms, min_expiry_ms, max_expiry_ms);
        } else if (std.mem.eql(u8, arg, capture_wait_flag)) {
            options.capture_wait_ms = std.fmt.parseInt(u64, args.next() orelse
                return error.MissingCaptureWaitMs, 10) catch return error.BadCaptureWaitMs;
            options.capture_wait_ms = std.math.clamp(
                options.capture_wait_ms,
                min_capture_wait_ms,
                max_capture_wait_ms,
            );
        } else if (std.mem.eql(u8, arg, authorize_lifecycle_flag)) {
            options.authorize_lifecycle = true;
        } else if (std.mem.eql(u8, arg, lifecycle_scope_flag)) {
            options.lifecycle_scope = args.next() orelse return error.MissingAuthorizationScope;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            // A bare word here is NOT a launch argument this run may adopt. The
            // shell writes a jump list entry as this executable's ONLY argument,
            // which the parser above has already taken as the activation
            // command; a bare word travelling alongside a command word and its
            // approvals is a person typing, and adopting it would let an
            // approved command line carry an activation nobody approved.
            std.log.err(
                "a bare argument is what the SHELL writes for a jump list entry, and the\n" ++
                    "  shell writes it as this executable's only argument. It cannot travel on\n" ++
                    "  a line that also carries a command and its approvals.",
                .{},
            );
            return error.LaunchArgumentWithoutItsCommand;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    return options;
}

/// An authorization flag is not an approval on its own, so a flag that names an
/// arm nobody asked for is refused rather than ignored.
fn checkFlagPlacement(options: Options) !void {
    const Gate = struct {
        flag: []const u8,
        armed: bool,
        scope: ?[]const u8,
        command: Command,
    };
    const gates = [_]Gate{
        .{
            .flag = authorize_window_flag,
            .armed = options.authorize_window,
            .scope = options.window_scope,
            .command = .window,
        },
        .{
            .flag = authorize_menu_flag,
            .armed = options.authorize_menu,
            .scope = options.menu_scope,
            .command = .menu,
        },
        .{
            .flag = authorize_jump_flag,
            .armed = options.authorize_jump,
            .scope = options.jump_scope,
            .command = .jumplist,
        },
        .{
            .flag = authorize_association_flag,
            .armed = options.authorize_association,
            .scope = options.association_scope,
            .command = .jumplist,
        },
        .{
            .flag = authorize_notify_flag,
            .armed = options.authorize_notify,
            .scope = options.notify_scope,
            .command = .notify,
        },
        .{
            .flag = authorize_credential_flag,
            .armed = options.authorize_credential,
            .scope = options.credential_scope,
            .command = .credential,
        },
        .{
            .flag = authorize_capture_flag,
            .armed = options.authorize_capture,
            .scope = options.capture_scope,
            .command = .capture,
        },
        .{
            .flag = authorize_accessibility_flag,
            .armed = options.authorize_accessibility,
            .scope = options.accessibility_scope,
            .command = .accessibility,
        },
        .{
            .flag = authorize_cleanup_flag,
            .armed = options.authorize_cleanup,
            .scope = options.cleanup_scope,
            .command = .cleanup,
        },
        .{
            .flag = authorize_lifecycle_flag,
            .armed = options.authorize_lifecycle,
            .scope = options.lifecycle_scope,
            .command = .lifecycle,
        },
    };
    for (gates) |gate| {
        if (gate.armed and options.command != gate.command) {
            std.log.err("{s} belongs to the {s} command only", .{ gate.flag, @tagName(gate.command) });
            return error.AuthorizationFlagWithoutItsCommand;
        }
        if (gate.scope != null and options.command != gate.command) {
            std.log.err("the scope flag that pairs with {s} belongs to the {s} command only", .{
                gate.flag,
                @tagName(gate.command),
            });
            return error.AuthorizationScopeWithoutItsCommand;
        }
    }
    if (options.command != .credential and options.command != .cleanup and
        (options.service != null or options.account != null))
    {
        std.log.err("{s} and {s} belong to the credential and cleanup commands only", .{
            service_flag,
            account_flag,
        });
        return error.NamespaceFlagWithoutItsCommand;
    }
    // The activation command is the run the SHELL started. It carries the one
    // argument the shell wrote and nothing else, because the shell writes no
    // approvals and no identity. A flag reaching it means the parser adopted
    // something the shell would never have written, and that is refused rather
    // than ignored, because an arm that ran with an approval the shell never
    // gave would be claiming a consent nobody typed.
    if (options.command == .activation) {
        if (options.activation_argument == null) return error.ShellLaunchWithoutItsArgument;
        if (options.authorize_identity or options.app_id != null or
            options.service != null or options.account != null or
            options.capture_source != null or options.toast_id != null or
            options.toast_activator != null)
        {
            std.log.err(
                "the {s} command is started by the shell, which writes one argument and no\n" ++
                    "  approvals, so no flag on this line came from the shell",
                .{@tagName(Command.activation)},
            );
            return error.ApprovalFlagOnAShellLaunch;
        }
        return;
    }
    if (options.command != .capture and options.capture_source != null) {
        std.log.err("{s} belongs to the capture command only", .{capture_source_flag});
        return error.CaptureSourceWithoutItsCommand;
    }
    if (options.command != .notify and options.command != .cleanup and
        (options.toast_id != null or options.toast_activator != null or
            !std.mem.eql(u8, options.toast_group, default_toast_group)))
    {
        std.log.err("{s}, {s} and {s} belong to the notify and cleanup commands only", .{
            toast_id_flag,
            toast_activator_flag,
            toast_group_flag,
        });
        return error.ToastFlagWithoutItsCommand;
    }
    if (options.command == .help or options.command == .probe) {
        if (options.authorize_identity or options.identity_scope != null or
            options.app_id != null)
        {
            std.log.err(
                "help and probe need no approval and open nothing, so {s}, {s} and {s} do not belong to them",
                .{
                    authorize_identity_flag,
                    identity_scope_flag,
                    app_id_flag,
                },
            );
            return error.ApprovalFlagOnASafeCommand;
        }
        return;
    }
    // The identity approval belongs to every native command, so it is the one
    // pair that is never "without its command"; the two have to travel
    // together or not at all.
    if (options.authorize_identity != (options.identity_scope != null)) {
        std.log.err("{s} and {s} have to travel together", .{
            authorize_identity_flag,
            identity_scope_flag,
        });
        return error.IdentityFlagWithoutItsScope;
    }
    if (options.app_id == null) {
        std.log.err("every native command names the identity it claims, so {s} is required", .{
            app_id_flag,
        });
        return error.MissingAppId;
    }
}

/// The notify arm's two budgets have to be coherent, or the run fails by
/// construction instead of by observation. The only delivery this run can
/// observe is the shell's own expiry of the toast, which lands at `expiry_ms`,
/// so a wait that ends inside the first pump slice after the expiry would be
/// racing the answer it exists to observe.
fn checkNotificationBudget(options: Options) !void {
    if (options.command != .notify) return;
    // Signed on both sides, so a budget this check has not seen before is
    // judged by its slack rather than by a cast that could trap.
    const slack_ms: i64 = @as(i64, @intCast(options.wait_ms)) - @as(i64, options.expiry_ms);
    if (slack_ms >= min_pump_slack_ms) return;
    return error.NotificationWaitCannotObserveTheExpiry;
}

fn printUsage(report: *Reporter, options: Options) !void {
    try report.emit("w23-windows-smoke <command> [flags]\n", .{});
    try report.emit(
        \\
        \\commands:
        \\  help            this text; no SDL, no provider, no Windows API, no approval
        \\  probe           build facts only; asks no platform anything
        \\  identity        claim the AppUserModelID and read it back from the shell
        \\  window          native title, resize grip and dark title bar, read back
        \\  menu            a real HMENU on a real window, a real delivered WM_COMMAND
        \\  jumplist        publish a real jump list and print the two shell launches
        \\  activation      the run the SHELL started; routes its one argument, once
        \\  notify          post, replace, dismiss and expire synthetic toasts
        \\  credential      create, read and delete one synthetic secret, then the refusals
        \\  capture         the real Windows Graphics Capture picker, frames and teardown
        \\  accessibility   UI Automation attach, publish and detach around real frames
        \\  lifecycle       two real windows, real frames, bounded pump, full retirement
        \\  cleanup         delete the synthetic records this binary created
        \\
    , .{});
    try report.emit(
        "\nevery native command needs these two, and the identity first:\n",
        .{},
    );
    try report.emit("  {s} \"<exact text>\" {s} <AppUserModelID>\n", .{
        authorize_identity_flag,
        app_id_flag,
    });
    try report.emit(
        \\
        \\then its own:
        \\  window         {s} {s}
        \\  menu           {s} {s} [--hold-ms N]
        \\  jumplist       {s} {s} [{s} {s}]
        \\  notify         {s} {s} [--wait-ms N] [--expiry-ms N]
        \\  credential     {s} {s} {s} <service> {s} <account>
        \\  capture        {s} {s} {s} monitor|window|virtual [--capture-wait-ms N]
        \\  accessibility  {s} {s}
        \\  cleanup        {s} {s} {s} <service> {s} <account> [--toast-id N]
        \\  lifecycle      {s} {s} [--frames N] [--hold-ms N]
        \\
    , .{
        authorize_window_flag,      window_scope_flag,
        authorize_menu_flag,        menu_scope_flag,
        authorize_jump_flag,        jump_scope_flag,
        authorize_association_flag, association_scope_flag,
        authorize_notify_flag,      notify_scope_flag,
        authorize_credential_flag,  credential_scope_flag,
        service_flag,               account_flag,
        authorize_capture_flag,     capture_scope_flag,
        capture_source_flag,        authorize_accessibility_flag,
        accessibility_scope_flag,   authorize_cleanup_flag,
        cleanup_scope_flag,         service_flag,
        account_flag,               authorize_lifecycle_flag,
        lifecycle_scope_flag,
    });
    try report.emit(
        \\
        \\both halves are required: the flag is what the operator armed and the
        \\scope is what they read, so a scope text on its own is not an approval
        \\and the run is refused before the arm opens anything.
        \\
    , .{});
    try report.emit(
        \\
        \\optional, and every arm reports plainly what it did without them:
        \\  jumplist   {s} {s}
        \\             installs the per-user {s} file association that is what makes a
        \\             recent-document click start this binary with that path as its
        \\             only argument; without it the list still publishes and the
        \\             document entry cannot be opened
        \\  notify     {s} <CLSID>   the COM activator a packaged Start menu entry registers
        \\  notify     {s} <name>    the toast group this run files its toasts under
        \\  cleanup    {s} <N>       the id the shell assigned a synthetic toast
        \\
    , .{
        authorize_association_flag,
        association_scope_flag,
        document_extension,
        toast_activator_flag,
        toast_group_flag,
        toast_id_flag,
    });
    try report.emit("\nlifecycle scope, exactly:\n  {s}\n", .{lifecycle_scope_text});
    try report.emit(
        \\
        \\the shell's own door, and the whole of it:
        \\  {s}
        \\A jump list entry is not an in-process event, so this binary has a command
        \\for the launch itself. It is chosen BEFORE any command word is looked for,
        \\because the shell's line carries neither one nor an approval, and it
        \\reaches the run that opens the window, mounts the model and routes the
        \\argument once. A bare argument typed onto another command is refused.
        \\
    , .{launch_argument_hint});
    try report.emit("\nthe identity scope, exactly, with your id spliced in:\n  {s}<your id>{s}\n", .{
        identity_scope_prefix,
        identity_scope_suffix,
    });
    try report.emit("\nwindow scope, exactly:\n  {s}\n", .{window_scope_text});
    try report.emit("\nmenu scope, exactly:\n  {s}\n", .{menu_scope_text});
    try report.emit("\njump-list scope, exactly:\n  {s}\n", .{jump_scope_text});
    try report.emit(
        "\ndocument-association scope, exactly, and only for jumplist:\n  {s}\n",
        .{association_scope_text},
    );
    try report.emit("\nnotification scope, exactly:\n  {s}\n", .{notify_scope_text});
    try report.emit(
        "\ncredential scope, exactly, with your namespace spliced in:\n  {s}<service>{s}<account>{s}\n",
        .{ credential_scope_prefix, credential_scope_middle, credential_scope_suffix },
    );
    try report.emit("\ncapture scope, exactly:\n  {s}\n", .{capture_scope_text});
    try report.emit("\naccessibility scope, exactly:\n  {s}\n", .{accessibility_scope_text});
    try report.emit("\ncleanup scope, exactly:\n  {s}\n", .{cleanup_scope_text});
    try report.emit(
        \\
        \\the only service this binary may ever write under is "{s}", and every
        \\account is "{s}<nonce>" with a nonce of {d}-{d} characters of a-z and 0-9
        \\that is never reused, so two runs can never address the same entry.
        \\
        \\a command line is not an approval: the person who owns the desktop has to
        \\approve the exact scope in the session that runs the arm.
        \\
    , .{ smoke_service, account_prefix, min_nonce_len, max_nonce_len });
    try report.emit("\nthis run: command={s} frames={d} hold={d} ms wait={d} ms expiry={d} ms\n", .{
        @tagName(options.command),
        options.frames,
        options.hold_ms,
        options.wait_ms,
        options.expiry_ms,
    });
}

// ── the commands ───────────────────────────────

/// Everything the run needs, resolved once. Every approval was checked before
/// any of this runs.
const Plan = struct {
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    options: Options,
    /// The identity this run claimed. Empty on the activation command, which
    /// the shell starts without one and which therefore claims none.
    app_id: []const u8,
    account: ?[]const u8 = null,
    /// The one argument the SHELL wrote, as the platform reported it. It is
    /// null on every command line a person typed, and that null is the run's
    /// own answer that no shell launched this process.
    shell_argument: ?[]const u8 = null,
    /// The whole argument vector the platform reported, borrowed from the
    /// reader that owns it. A report names its length because "this
    /// executable alone" and "this executable plus one argument" are the two
    /// invocations this binary tells apart.
    shell_argv: []const []const u8 = &.{},
    document: [max_document_len]u8 = @splat(0),
    document_len: usize = 0,

    /// The synthetic document's path, inside this user's own data root.
    ///
    /// It is DERIVED and not chosen per run, because the run that publishes the
    /// entry and the separate run the shell starts to open it must arrive at
    /// the same string without being told it: the shell writes the path as the
    /// launch argument and nothing else. The answer is borrowed from this
    /// value's own buffer and stays valid for as long as the plan does.
    fn makeDocument(self: *Plan) ![]const u8 {
        const root = try winapi.localAppData(self.gpa);
        defer self.gpa.free(root);
        // A trailing separator would double itself, and Windows accepts both
        // spellings, so the joined path carries exactly one rather than
        // leaving two ways to name the same file for the shell to disagree
        // with.
        const trimmed = std.mem.trimEnd(u8, root, "\\/");
        if (trimmed.len == 0) return error.KnownFolderUnavailable;
        const text = try std.fmt.bufPrint(&self.document, "{s}\\{s}", .{
            trimmed,
            document_file_name,
        });
        self.document_len = text.len;
        return text;
    }

    /// Write that file, so the shell has a real file to record and to open.
    fn writeDocument(self: *Plan, path: []const u8) !void {
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = document_body });
    }

    /// Remove that file, and report whether this run found one to remove.
    fn removeDocument(self: *Plan, path: []const u8) bool {
        Io.Dir.cwd().deleteFile(self.io, path) catch return false;
        return true;
    }
};

fn runProbe(report: *Reporter) !void {
    try report.emit("build: target_is_windows={} adapter_directory_applicable={}\n", .{
        winapi.is_windows,
        windows.isApplicable(),
    });
    try report.emit(
        \\
        \\accessibility: bridge_linked={} directory_reports_available={}
        \\  (linked is a fact about THIS build; available is a fact about this
        \\   build's target. Neither is a fact about whether a screen reader is
        \\   running, which this run does not ask and will not change.)
        \\
    , .{ windows.Accessibility.linked, windows.accessibilityAvailable() });
    try report.emit("\nthis build's target-SUPPORTED adapters (not installed state):\n", .{});
    try report.emit("  app_identity     {s}\n", .{booleanText(windows.app_identity.isApplicable())});
    try report.emit("  window_interop   {s}\n", .{booleanText(windows.window_interop.isApplicable())});
    try report.emit("  native menus     {s}\n", .{booleanText(windows.Menus.hasNativeGlobalMenu())});
    try report.emit("  jump list        {s}\n", .{booleanText(windows.isApplicable())});
    try report.emit("  notifications    {s}\n", .{booleanText(windows.Notifications.isApplicable())});
    try report.emit("  credentials      {s}\n", .{booleanText(windows.Credentials.isApplicable())});
    try report.emit("  capture          {s}\n", .{booleanText(windows.Capture.isApplicable())});
    try report.emit("\nno provider was built, no identity was claimed, no window was opened.\n", .{});
    try report.emit(
        \\target-SUPPORTED capability is not INSTALLED capability: nothing above
        \\answers whether a packaged Start menu entry, a registered COM
        \\activator or a configured policy allows a real service call on this
        \\machine. Only a native run with the exact scopes answers that.
        \\
    , .{});
}

/// One arm's approval: its flag AND its exact scope text, both checked here,
/// before the arm builds a provider, opens a window or claims anything.
///
/// The flag is what the operator armed and the scope is what they read, so a
/// command line carrying only the scope text is not an approval: it is a
/// sentence with nothing behind it. Both halves are refused by name, and this
/// runs before the arm starts, so an effect nobody approved does not happen and
/// then get reported afterwards.
fn requirePhaseAuthorization(options: Options) !void {
    const Phase = struct {
        command: Command,
        armed: bool,
        flag: []const u8,
        given: ?[]const u8,
        scope_flag: []const u8,
        expected: []const u8,
    };
    // The credential scope is the one whose text depends on what the operator
    // typed, so it is compared separately below rather than through the table.
    const phases = [_]Phase{
        .{
            .command = .window,
            .armed = options.authorize_window,
            .flag = authorize_window_flag,
            .given = options.window_scope,
            .scope_flag = window_scope_flag,
            .expected = window_scope_text,
        },
        .{
            .command = .menu,
            .armed = options.authorize_menu,
            .flag = authorize_menu_flag,
            .given = options.menu_scope,
            .scope_flag = menu_scope_flag,
            .expected = menu_scope_text,
        },
        .{
            .command = .jumplist,
            .armed = options.authorize_jump,
            .flag = authorize_jump_flag,
            .given = options.jump_scope,
            .scope_flag = jump_scope_flag,
            .expected = jump_scope_text,
        },
        .{
            .command = .notify,
            .armed = options.authorize_notify,
            .flag = authorize_notify_flag,
            .given = options.notify_scope,
            .scope_flag = notify_scope_flag,
            .expected = notify_scope_text,
        },
        .{
            .command = .capture,
            .armed = options.authorize_capture,
            .flag = authorize_capture_flag,
            .given = options.capture_scope,
            .scope_flag = capture_scope_flag,
            .expected = capture_scope_text,
        },
        .{
            .command = .accessibility,
            .armed = options.authorize_accessibility,
            .flag = authorize_accessibility_flag,
            .given = options.accessibility_scope,
            .scope_flag = accessibility_scope_flag,
            .expected = accessibility_scope_text,
        },
        .{
            .command = .cleanup,
            .armed = options.authorize_cleanup,
            .flag = authorize_cleanup_flag,
            .given = options.cleanup_scope,
            .scope_flag = cleanup_scope_flag,
            .expected = cleanup_scope_text,
        },
        .{
            .command = .lifecycle,
            .armed = options.authorize_lifecycle,
            .flag = authorize_lifecycle_flag,
            .given = options.lifecycle_scope,
            .scope_flag = lifecycle_scope_flag,
            .expected = lifecycle_scope_text,
        },
    };
    for (phases) |phase| {
        if (options.command != phase.command) continue;
        if (!phase.armed) {
            std.log.err(
                "{s} is required: the scope text on its own is not an approval for the {s} arm",
                .{ phase.flag, @tagName(phase.command) },
            );
            return error.MissingPhaseAuthorization;
        }
        try requireScope(phase.given, phase.expected, phase.scope_flag);
    }

    // The file association is the one approval here that gates something an
    // arm may SKIP, so it is not in the table: publishing a list does not
    // need a handler, and a run without one still publishes. Armed means both
    // halves, and a scope with no flag behind it was already refused by the
    // placement gate, so what remains here is the text itself.
    if (options.command == .jumplist and options.authorize_association) {
        try requireScope(options.association_scope, association_scope_text, association_scope_flag);
    }
    if (options.command != .credential) return;
    if (!options.authorize_credential) {
        std.log.err(
            "{s} is required: the scope text on its own is not an approval for the credential arm",
            .{authorize_credential_flag},
        );
        return error.MissingPhaseAuthorization;
    }
    const service = options.service orelse return error.MissingServiceNamespace;
    const account = options.account orelse return error.MissingAccountNamespace;
    const expected = try credentialScopeText(options.gpa, service, account);
    defer options.gpa.free(expected);
    try requireScope(options.credential_scope, expected, credential_scope_flag);
}

// ── the identity phase ──────────────────────────────

fn runIdentityPhase(plan: *Plan, host_state: *windows.Host) !void {
    const report = plan.report;
    const gpa = plan.gpa;

    // `Host.init` already claimed the identity and read it back, and refused
    // rather than stored a value the shell did not take. The readback is
    // repeated here through the public read path so the report names a value
    // the shell itself produced.
    var held = try windows.app_identity.currentProcessIdentity(gpa);
    if (held) |*value| {
        defer value.deinit();
        try report.emit("identity: claimed app_id=\"{s}\" shell_readback=\"{s}\"\n", .{
            host_state.identity.app_id,
            value.app_id,
        });
        report.expectText("identity.readback_matches_the_claim", plan.app_id, value.app_id);
        // The jump list's own gate, applied to the identity the process
        // actually holds. It is the gate the adapter itself runs before any
        // COM call, so running it here proves the precondition rather than the
        // outcome.
        windows.jump_list.identityAdmits(plan.app_id, value.app_id) catch |err| {
            report.expect("identity.admits_a_jump_list", false);
            return err;
        };
        report.expect("identity.admits_a_jump_list", true);
    } else {
        try report.emit("identity: the shell holds no explicit identity\n", .{});
        report.expect("identity.the_shell_held_an_explicit_identity", false);
        return error.IdentityReadbackAbsent;
    }
    // The grammar, exercised on the value the run actually used.
    report.expect(
        "identity.matches_the_documented_shell_grammar",
        windows.app_identity.isWellFormed(plan.app_id),
    );
    report.expect(
        "identity.an_empty_claim_is_refused_by_the_same_grammar",
        !windows.app_identity.isWellFormed(""),
    );
    report.expect(
        "identity.a_dotted_id_is_accepted_by_the_same_grammar",
        windows.app_identity.isWellFormed("com.7Games.nogui"),
    );
}

// ── the window phase ───────────────────────────────

fn runWindowPhase(plan: *Plan) !void {
    const report = plan.report;
    const gpa = plan.gpa;
    const stage = try Stage.create(gpa, plan.io, .{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .gpu_surface = false,
        .visible = true,
    });
    defer stage.deinit();
    try stage.headlessFrame();

    const handles = windows.window_interop.readHandles(stage.managed.native.sdl);
    try report.emit("window: driver={s} uses_win32={} can_drive={}\n", .{
        handles.driver_name orelse "<null>",
        handles.usesWin32(),
        handles.canDrive(),
    });
    const hwnd = try handles.require();
    report.expect("window.published_a_live_native_handle", windows.window_interop.isWindow(hwnd));

    // The title. The request goes through the adapter and the readback comes
    // from the window procedure, not from SDL's copy, so a window manager that
    // stored something else is visible as a difference.
    const wanted_title = "w23 native window";
    try windows.window_interop.setWindowTitle(gpa, hwnd, wanted_title);
    const read_title = try windows.window_interop.windowTitle(gpa, hwnd);
    defer gpa.free(read_title);
    report.expectText("window.native_title_readback", wanted_title, read_title);

    // The resize grip, requested and then read back from the window's own
    // style bits.
    const was_resizable = windows.window_interop.hasResizableFrame(hwnd);
    const now_resizable = try windows.window_interop.setResizableFrame(hwnd, false);
    try report.emit("window: resizable before={} request_off={} read_back={}\n", .{
        booleanText(was_resizable),
        booleanText(now_resizable),
        booleanText(windows.window_interop.hasResizableFrame(hwnd)),
    });
    report.expect(
        "window.resizable_grip_read_back_false",
        !windows.window_interop.hasResizableFrame(hwnd),
    );
    const back_on = try windows.window_interop.setResizableFrame(hwnd, true);
    try report.emit("window: request_on={} read_back={}\n", .{
        booleanText(back_on),
        booleanText(windows.window_interop.hasResizableFrame(hwnd)),
    });
    report.expect(
        "window.resizable_grip_read_back_true",
        windows.window_interop.hasResizableFrame(hwnd),
    );
    report.expect(
        "window.caption_stays_with_the_frame",
        windows.window_interop.styleOf(hwnd) & winapi.ws_caption != 0,
    );

    // The dark title bar. The setter's answer is the window manager's answer
    // to the REQUEST; the reader's is its answer to the STATE, and only the
    // second one distinguishes an accepted request from a dark caption.
    windows.window_interop.setDarkTitleBar(hwnd, true) catch |err| {
        try report.emit("window: dark_title_bar request={s}\n", .{refusalTag(err)});
        report.expect("window.a_refused_dark_request_is_named", err == error.DarkModeUnsupported);
        try report.emit(
            "window: this build of Windows has neither dark attribute, so there is no\n" ++
                "  state to read back and none is invented\n",
            .{},
        );
        // The refusal is this machine's answer; the rest of the window state
        // was still observed, so the phase finishes reporting it.
        try report.emit("window: sdl_title=\"{s}\" logical={d}x{d} dpi_scale={d:.3}\n", .{
            optionalText(stage.managed.observedTitle()),
            stage.managed.observed.size.width,
            stage.managed.observed.size.height,
            windows.window_interop.dpiScaleOf(hwnd),
        });
        return;
    };
    const dark = try windows.window_interop.darkTitleBar(hwnd);
    try report.emit("window: dark_title_bar requested=true read_back={s}\n", .{booleanText(dark)});
    report.expect("window.dark_title_bar_read_back_true", dark);
    // A handle that names nothing is refused by name, not answered with a
    // value, and that is the refusal a live window's answer has to be
    // distinguishable from.
    const dead: winapi.Hwnd = @ptrFromInt(0x2000);
    if (windows.window_interop.darkTitleBar(dead)) |value| {
        try report.emit("window: a dead handle reported dark_title_bar={s}\n", .{booleanText(value)});
        report.expect("window.a_dead_handle_is_refused_by_name", false);
    } else |err| {
        try report.emit("window: a dead handle answered={s}\n", .{refusalTag(err)});
        report.expect("window.a_dead_handle_is_refused_by_name", err == error.NotAWindow);
    }

    // The window the host actually owns, read back through the host's own
    // observation, so the native facts and the host's facts are both printed.
    try report.emit("window: sdl_title=\"{s}\" logical={d}x{d} dpi_scale={d:.3}\n", .{
        optionalText(stage.managed.observedTitle()),
        stage.managed.observed.size.width,
        stage.managed.observed.size.height,
        windows.window_interop.dpiScaleOf(hwnd),
    });
    report.expect(
        "window.host_reports_the_window_live",
        (stage.application.getWindow(stage.handle) catch null) == stage.managed,
    );
    report.expect(
        "window.the_session_still_holds_this_app",
        stage.session.hasWindow(stage.app.window),
    );
}

// ── the menu phase ───────────────────────────────

/// The command identifier the adapter gave one model row, read back out of the
/// adapter's own route table rather than assumed. `WM_COMMAND` carries the
/// identifier in a `WPARAM`, and a run that hard-coded it would be testing a
/// number it chose rather than a number the adapter assigned.
fn commandForAction(
    native: *const windows.Menus.NativeMenu,
    action_name: []const u8,
) ?winapi.Dword {
    for (native.routes[1..], 1..) |route, command| {
        const named = route.item.action_name orelse continue;
        if (std.mem.eql(u8, named, action_name)) return @intCast(command);
    }
    return null;
}

/// The command identifier the adapter gave the system-action row. A system
/// action carries no action name, so it is found by its kind.
fn commandForSystemAction(native: *const windows.Menus.NativeMenu) ?winapi.Dword {
    for (native.routes[1..], 1..) |route, command| {
        if (route.item.kind != .system_action) continue;
        return @intCast(command);
    }
    return null;
}

fn countCommandRows(bar: menus.MenuBar) usize {
    var total: usize = 0;
    for (bar.menus) |menu| {
        for (menu.items) |item| {
            switch (item.kind) {
                .action, .system_action => total += 1,
                .submenu, .separator => {},
            }
        }
    }
    return total;
}

/// The enablement one evaluated row carries, read out of the adapter's own
/// retained evaluation. Null when the row is not in this bar.
fn findRowState(native: *const windows.Menus.NativeMenu, action_name: []const u8) ?bool {
    const bar = native.evaluated orelse return null;
    for (bar.menus) |menu| {
        for (menu.items) |item| {
            const named = item.action_name orelse continue;
            if (std.mem.eql(u8, named, action_name)) return item.enabled;
        }
    }
    return null;
}

/// The attachment's view of one window: what the platform delivered to the
/// window procedure, and the live tree and focus each command is resolved
/// against.
///
/// It is a stack value in the phase that owns the window and the window
/// procedure borrows it for as long as it is installed. The attachment is
/// detached before the phase returns, so the pointer never outlives the frame
/// it lives in.
const MenuDoor = struct {
    stage: *Stage,
    menu: *windows.Menus.WindowMenu,
    gpa: std.mem.Allocator,
    /// Commands the platform delivered to the procedure, and the last one with
    /// what it produced. A run that posted messages and saw none of them
    /// arrive has a procedure that is not being called, which is a different
    /// failure from a menu nobody clicked.
    commands: u32 = 0,
    last_command: winapi.Dword = 0,
    last_outcome: windows.Menus.CommandOutcome = .unrouted,
    /// Popups the shell opened, the refreshes those popups caused, and the
    /// ones that could not be evaluated at all.
    popups: u32 = 0,
    refreshes: u32 = 0,
    refresh_failed: u32 = 0,

    fn of(context: ?*anyopaque) *MenuDoor {
        return @ptrCast(@alignCast(context orelse
            @panic("W23 menu door reached with no context")));
    }

    /// The App's CURRENT committed tree, read on the message's own thread.
    fn tree(context: ?*anyopaque) *const WidgetTree {
        const self = MenuDoor.of(context);
        // A command that arrived before the first committed frame would have
        // nothing to resolve against, and dispatching it against an empty tree
        // would report the registry as refusing an action it never saw. Every
        // phase commits a frame before it installs this procedure, so reaching
        // here means the host broke its own ordering.
        return self.stage.app.tree_ptr orelse
            @panic("W23 menu command arrived with no committed tree");
    }

    /// The CURRENT focus, read at the same moment as the tree.
    fn focus(context: ?*anyopaque) ?WidgetId {
        return MenuDoor.of(context).stage.focus();
    }

    fn onResult(
        context: ?*anyopaque,
        command: winapi.Dword,
        outcome: windows.Menus.CommandOutcome,
    ) void {
        const self = MenuDoor.of(context);
        self.commands += 1;
        self.last_command = command;
        self.last_outcome = outcome;
    }

    /// Re-evaluate the bar at the last moment a native menu's enablement can
    /// be correct, and write the fresh states into the rows the command table
    /// already points at.
    fn onPopup(context: ?*anyopaque, popup: winapi.Hmenu) void {
        _ = popup;
        const self = MenuDoor.of(context);
        self.popups += 1;
        const evaluated = self.stage.bridge.evaluate(
            self.gpa,
            menu_bar,
            MenuDoor.tree(context),
            MenuDoor.focus(context),
        ) catch {
            self.refresh_failed += 1;
            return;
        };
        self.menu.refresh(evaluated);
        self.refreshes += 1;
    }
};

/// One round of the host's own event pump.
///
/// `pollEvent` is `SDL_PollEvent`, and SDL's Windows backend drains the
/// platform message queue inside that call, so one round is what it takes for
/// a posted `WM_COMMAND` to reach the window procedure. Whatever SDL reports
/// alongside it is dispatched to the App, so an event that arrived in the same
/// window is handled rather than dropped.
fn pumpOnce(stage: *Stage, io: Io) !void {
    if (stage.application.pollEvent()) |raw| {
        _ = try stage.application.dispatch(&raw);
        return;
    }
    // `Io.sleep` answers `error.Canceled`, so it is awaited rather than
    // discarded: a pump that ignored its own cancellation would be a spin
    // wearing a sleep's name. `pump_idle_ms` is a `u64` because it is
    // compared against a millisecond budget, and the duration wants an `i64`.
    try Io.sleep(io, .fromMilliseconds(@intCast(pump_idle_ms)), .real);
}

/// Deliver one `WM_COMMAND` to the window and wait, bounded, for the platform
/// to run the window procedure on it.
///
/// `PostMessageW` is how a row's command reaches a window in the first place:
/// the shell posts it when a menu row is chosen or an accelerator fires, and
/// the window procedure sees it on the thread that owns the window. So the
/// identifier travels from this file to the live model through the platform
/// and the procedure, and not through a method this file calls on the adapter.
///
/// The answer is whether the procedure saw it. A message the platform never
/// delivered is reported as not delivered, because a run that reported a
/// dispatch it never made would be the fabrication this replaces.
fn deliverCommand(
    stage: *Stage,
    io: Io,
    door: *MenuDoor,
    wparam: winapi.Wparam,
    budget_ms: u64,
) !bool {
    const hwnd = windows.window_interop.getHwnd(stage.managed.native.sdl) orelse
        return error.NoNativeWindow;
    const before = door.commands;
    if (winapi.PostMessageW(hwnd, winapi.wm_command, wparam, 0) == 0) {
        return error.CommandPostRefused;
    }
    const deadline = sdl3.timer.getMillisecondsSinceInit() + budget_ms;
    while (door.commands == before) {
        if (sdl3.timer.getMillisecondsSinceInit() >= deadline) return false;
        try pumpOnce(stage, io);
    }
    return true;
}

/// What one delivered command produced, printed. The three cases stay apart: a
/// row the bridge ran, a message that named no row, and a handler that failed
/// are three different facts about the same window.
fn outcomeTag(outcome: windows.Menus.CommandOutcome) []const u8 {
    return switch (outcome) {
        .answered => |result| @tagName(result),
        .unrouted => "unrouted",
        .handler_failed => |err| @errorName(err),
    };
}

/// The registry's answer, when the delivered command produced one.
fn answeredResult(outcome: windows.Menus.CommandOutcome) ?action.Result {
    return switch (outcome) {
        .answered => |result| result,
        .unrouted, .handler_failed => null,
    };
}

fn runMenuPhase(plan: *Plan) !void {
    const report = plan.report;
    const gpa = plan.gpa;
    const io = plan.io;
    const stage = try Stage.create(gpa, io, .{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .gpu_surface = false,
        .visible = true,
    });
    defer stage.deinit();
    try stage.headlessFrame();

    // The bar, evaluated against the live focused context by the shared
    // bridge. The evaluation is an arena handed over by value, and the menu
    // owns it from this point.
    const evaluated = try stage.bridge.evaluate(gpa, menu_bar, try stage.tree(), stage.focus());
    const native = try windows.Menus.build(gpa, menu_bar, evaluated);
    try report.emit(
        "menu: model_command_rows={d} adapter_command_routes={d}\n",
        .{ countCommandRows(menu_bar), native.routes.len - 1 },
    );
    report.expectCount(
        "menu.the_adapter_numbers_every_command_row",
        countCommandRows(menu_bar),
        native.routes.len - 1,
    );

    var attached = try windows.Menus.WindowMenu.init(stage.managed.native.sdl, native);
    // The menu retires the attachments that route for it, so this release is
    // correct whether it runs before or after the procedure comes off. The
    // flag is what keeps the explicit release at the foot of this phase from
    // releasing the same menu twice.
    var menu_live = true;
    defer if (menu_live) attached.deinit();

    // THE DOOR. The adapter's own window procedure goes onto the window, so a
    // `WM_COMMAND` is RECEIVED by the window rather than handed to a method by
    // this file. One window carries one record, and this is that window's: a
    // second attachment is refused by name at the foot of this phase, and the
    // refusal leaves this record the only route in.
    var door: MenuDoor = .{ .stage = stage, .menu = &attached, .gpa = gpa };
    // SAFETY: `Subclass.attach` fills this before it returns its hook, and
    // every read of it goes through that hook after the call succeeded.
    var attachment: windows.Menus.Subclass = undefined;
    const hook = try windows.Menus.Subclass.attach(&attachment, &attached, .{
        .context = &door,
        .bridge = &stage.bridge,
        .tree = MenuDoor.tree,
        .focus = MenuDoor.focus,
        .on_result = MenuDoor.onResult,
        .on_init_menu_popup = MenuDoor.onPopup,
    });
    defer hook.detach();
    report.expect(
        "menu.the_window_manager_holds_this_directories_procedure",
        hook.installed(),
    );

    const add_command = commandForAction(&attached.menu, AddRow.name) orelse
        return error.MissingMenuCommand;
    const remove_command = commandForAction(&attached.menu, RemoveRow.name) orelse
        return error.MissingMenuCommand;
    const toggle_command = commandForAction(&attached.menu, ToggleFlag.name) orelse
        return error.MissingMenuCommand;
    const system_command = commandForSystemAction(&attached.menu) orelse
        return error.MissingSystemCommand;
    try report.emit(
        "menu: commands add={d} remove={d} toggle={d} system={d}\n",
        .{ add_command, remove_command, toggle_command, system_command },
    );
    // Separators and a submenu header consume no identifier, so the first real
    // row is the first identifier.
    report.expect("menu.the_separator_rows_took_no_identifier", add_command == 1);

    // The menu's OWN handle, attached and read back through the window.
    const hwnd = windows.window_interop.getHwnd(stage.managed.native.sdl) orelse
        return error.NoNativeWindow;
    report.expect("menu.the_window_manager_holds_the_menu", winapi.GetMenu(hwnd) != null);

    // A real `WM_COMMAND` for a real row: the low word is the identifier the
    // adapter assigned and the high word is zero, which is what a chosen row
    // sends. The platform delivers it to the procedure above.
    var before: PanelCopy = .{};
    try stage.readPanel(&before);
    const add_delivered = try deliverCommand(
        stage,
        io,
        &door,
        @as(winapi.Wparam, add_command),
        command_budget_ms,
    );
    var after: PanelCopy = .{};
    try stage.readPanel(&after);
    try report.emit("menu: add_row delivered={s} result={s} rows {d} -> {d}\n", .{
        booleanText(add_delivered),
        outcomeTag(door.last_outcome),
        before.rows,
        after.rows,
    });
    report.expect("menu.the_platform_delivered_the_command", add_delivered);
    report.expect(
        "menu.the_native_command_reached_the_live_model",
        answeredResult(door.last_outcome) == .handled,
    );
    report.expectCount("menu.the_model_actually_moved", before.rows + 1, after.rows);
    // The native door did NOT go through the widget: the view's own in-app
    // counter is still zero. That is what makes the next observation the
    // interesting one rather than the same one twice.
    report.expectCount("menu.the_native_command_bypassed_the_widget", 0, stage.view.add_hits);

    // The in-app door: the App's own activation on the widget that carries the
    // SAME registered action. This is an ordinary `App.activate` on an ordinary
    // keyed button, and it reaches the same registry and the same model the
    // `WM_COMMAND` above reached.
    const add_id = stage.view.add_id orelse return error.NoButtonIdentity;
    const rows_before_click = after.rows;
    stage.app.activate(try stage.tree(), add_id);
    var after_click: PanelCopy = .{};
    try stage.readPanel(&after_click);
    try report.emit("menu: in-app activation of the add-row widget rows {d} -> {d} view_add_hits={d}\n", .{
        rows_before_click,
        after_click.rows,
        stage.view.add_hits,
    });
    report.expect("menu.the_in_app_activation_reached_the_same_model", after_click.rows == rows_before_click + 1);
    report.expectCount("menu.the_in_app_door_ran_the_same_handler", 1, stage.view.add_hits);
    report.expectCount("menu.no_in_app_dispatch_was_refused", 0, stage.view.refused_dispatches);

    // The same model, through a different action and a different command.
    const toggle_delivered = try deliverCommand(
        stage,
        io,
        &door,
        @as(winapi.Wparam, toggle_command),
        command_budget_ms,
    );
    var after_toggle: PanelCopy = .{};
    try stage.readPanel(&after_toggle);
    try report.emit("menu: toggle_flag delivered={s} result={s} flag={s}\n", .{
        booleanText(toggle_delivered),
        outcomeTag(door.last_outcome),
        booleanText(after_toggle.checked),
    });
    report.expect(
        "menu.the_second_command_reached_the_live_model",
        answeredResult(door.last_outcome) == .handled,
    );
    report.expect("menu.the_flag_actually_moved", after_toggle.checked != after.checked);

    // A notification code in the high word is not a menu row. It is refused
    // rather than resolved to whichever row shares the low word.
    const notified = try deliverCommand(
        stage,
        io,
        &door,
        @as(winapi.Wparam, 1) << 16 | remove_command,
        command_budget_ms,
    );
    try report.emit("menu: a command carrying a notification code delivered={s} answered={s}\n", .{
        booleanText(notified),
        outcomeTag(door.last_outcome),
    });
    report.expect("menu.the_notification_code_was_delivered", notified);
    report.expect("menu.a_notification_code_is_not_a_menu_row", door.last_outcome == .unrouted);

    // An identifier this menu never assigned is refused by name.
    const foreign = try deliverCommand(
        stage,
        io,
        &door,
        0x7FFE,
        command_budget_ms,
    );
    try report.emit("menu: a foreign identifier delivered={s} answered={s}\n", .{
        booleanText(foreign),
        outcomeTag(door.last_outcome),
    });
    report.expect("menu.a_foreign_identifier_is_refused", door.last_outcome == .unrouted);

    // The system action reaches the registry like every other row, so the
    // model behind it is what records the arrival.
    var before_system: PanelCopy = .{};
    try stage.readPanel(&before_system);
    const system_delivered = try deliverCommand(
        stage,
        io,
        &door,
        @as(winapi.Wparam, system_command),
        command_budget_ms,
    );
    var after_system: PanelCopy = .{};
    try stage.readPanel(&after_system);
    try report.emit("menu: system delivered={s} result={s} model_calls={d} last={s}\n", .{
        booleanText(system_delivered),
        outcomeTag(door.last_outcome),
        after_system.system_actions,
        after_system.last_system_action,
    });
    report.expect(
        "menu.the_system_action_reached_the_registered_binding",
        answeredResult(door.last_outcome) == .handled,
    );
    report.expectCount(
        "menu.the_binding_saw_exactly_one_more",
        before_system.system_actions + 1,
        after_system.system_actions,
    );

    // The disabled refusal. The model is drained to zero through the same
    // registry the commands use, and the bar is re-evaluated, which is the
    // only way a real menu greys a real row.
    try updatePanel(stage, DrainRows{}, drainRows);
    const reevaluated = try stage.bridge.evaluate(gpa, menu_bar, try stage.tree(), stage.focus());
    attached.refresh(reevaluated);
    const remove_enabled = findRowState(&attached.menu, RemoveRow.name);
    try report.emit("menu: remove_row evaluated_enabled={s}\n", .{
        optionalBool(remove_enabled),
    });
    report.expect(
        "menu.a_disabled_row_is_greyed_by_the_registry",
        remove_enabled == false,
    );
    var drained: PanelCopy = .{};
    try stage.readPanel(&drained);
    const refused_delivered = try deliverCommand(
        stage,
        io,
        &door,
        @as(winapi.Wparam, remove_command),
        command_budget_ms,
    );
    try report.emit("menu: remove_row on a disabled row delivered={s} answered={s}\n", .{
        booleanText(refused_delivered),
        outcomeTag(door.last_outcome),
    });
    report.expect(
        "menu.a_disabled_row_refuses_the_command",
        answeredResult(door.last_outcome) == .disabled,
    );
    var after_refused: PanelCopy = .{};
    try stage.readPanel(&after_refused);
    report.expectCount("menu.the_refused_command_did_not_move_the_model", drained.rows, after_refused.rows);

    // A closed owner refuses. The weak probe is off, so every binding answers
    // unavailable and the registry has nothing to run.
    stage.alive = false;
    const closed_delivered = try deliverCommand(
        stage,
        io,
        &door,
        @as(winapi.Wparam, add_command),
        command_budget_ms,
    );
    try report.emit("menu: add_row with a closed owner delivered={s} answered={s}\n", .{
        booleanText(closed_delivered),
        outcomeTag(door.last_outcome),
    });
    report.expect(
        "menu.a_closed_owner_refuses_the_command",
        answeredResult(door.last_outcome) == .unavailable,
    );
    var after_closed: PanelCopy = .{};
    try stage.readPanel(&after_closed);
    report.expectCount("menu.the_closed_owner_left_the_model_alone", drained.rows, after_closed.rows);
    stage.alive = true;

    // The real menu, for a person. The window is on screen with its bar
    // attached, so a row can be chosen the way a user chooses one, and every
    // such choice arrives as the same `WM_COMMAND` the posted ones did, through
    // the same procedure. Bounded, and honest about an empty window: a run
    // nobody chose from reports no choices rather than a dispatch that did not
    // happen, and the posted rows above are what proves the door.
    const chosen_before = door.commands;
    try report.emit(
        "menu: the w23 window's menu bar is real and attached; choose a row in it now.\n" ++
            "  holding for {d} ms. a chosen row and a posted row are the same door.\n",
        .{plan.options.hold_ms},
    );
    _ = try pumpEvents(stage, io, plan.options.hold_ms);
    const chosen = door.commands - chosen_before;
    try report.emit(
        "menu: rows chosen by a person={d} popups_opened={d} popup_refreshes={d} refresh_failures={d}\n",
        .{ chosen, door.popups, door.refreshes, door.refresh_failed },
    );
    // Every popup the shell opened was either re-evaluated or reported as a
    // failure to evaluate. A popup drawn from stale state would be neither.
    report.expectCount(
        "menu.every_popup_was_re_evaluated_or_named_as_a_failure",
        door.popups,
        door.refreshes + door.refresh_failed,
    );
    if (chosen != 0) {
        var after_chosen: PanelCopy = .{};
        try stage.readPanel(&after_chosen);
        report.expect(
            "menu.a_row_chosen_by_a_person_reached_the_live_model",
            after_chosen.rows != after_refused.rows or
                after_chosen.checked != after_refused.checked,
        );
    } else {
        try report.emit(
            "menu: no row was chosen in that window, so no choice is claimed\n",
            .{},
        );
    }

    // THE SECOND ADOPTION, refused by name. One window carries one record,
    // because the window procedure is one address: a second record could only
    // shadow this one, and detaching this one would put the procedure from
    // before adoption back over the newer hook. The refusal comes before any
    // native call, so the window is left exactly as it was.
    // SAFETY: `Subclass.attach` refuses a second record for this window before
    // touching storage, so `second` is never read; it exists only to name the
    // refusal path the caller must not take.
    var second: windows.Menus.Subclass = undefined;
    const refused = windows.Menus.Subclass.attach(&second, &attached, .{
        .context = &door,
        .bridge = &stage.bridge,
        .tree = MenuDoor.tree,
        .focus = MenuDoor.focus,
        .on_result = MenuDoor.onResult,
        .on_init_menu_popup = MenuDoor.onPopup,
    });
    const duplicate_refused = switch (refused) {
        error.SubclassAlreadyAttached => true,
        else => false,
    };
    try report.emit("menu: a second attachment to the same window refused={s}\n", .{
        booleanText(duplicate_refused),
    });
    report.expect("menu.one_window_carries_one_attachment", duplicate_refused);
    report.expect("menu.the_refused_attachment_left_the_window_alone", hook.installed());

    // A REAL command after the refusal, delivered by the platform to whichever
    // record still answers for this window. The counter that moves is the one
    // on the record that was attached first: a second record shadowing this one
    // would answer the message instead, and the surviving record would sit at
    // zero.
    const routed_before = hook.commands;
    var before_second: PanelCopy = .{};
    try stage.readPanel(&before_second);
    const survived = try deliverCommand(
        stage,
        io,
        &door,
        @as(winapi.Wparam, add_command),
        command_budget_ms,
    );
    var after_second: PanelCopy = .{};
    try stage.readPanel(&after_second);
    try report.emit("menu: add_row after the refused attach delivered={s} result={s} rows {d} -> {d}\n", .{
        booleanText(survived),
        outcomeTag(door.last_outcome),
        before_second.rows,
        after_second.rows,
    });
    report.expect("menu.a_command_still_reaches_the_model_after_a_refused_attach", survived);
    report.expectCount(
        "menu.the_first_record_is_the_one_the_platform_delivered_to",
        routed_before + 1,
        hook.commands,
    );
    report.expect(
        "menu.the_surviving_attachment_still_dispatched",
        answeredResult(door.last_outcome) == .handled,
    );
    report.expectCount(
        "menu.the_model_moved_once_more_through_the_surviving_attachment",
        before_second.rows + 1,
        after_second.rows,
    );

    // THE ORDER THAT MUST NOT MATTER. The menu is released HERE, while this
    // directory's procedure is still installed on the window and still names
    // this menu: the order a host gets when it registers the menu's own `defer`
    // first. The release has to retire the attachment itself, because a
    // procedure still installed would resolve a command out of a route table
    // that is already gone.
    attached.deinit();
    menu_live = false;
    report.expect(
        "menu.releasing_the_menu_took_the_procedure_off_the_window",
        !hook.installed(),
    );
    // The caller's own detach is still owed a call, and it must find nothing
    // left to do rather than write a second procedure onto this window.
    hook.detach();
    report.expect("menu.the_callers_detach_after_the_release_is_a_no_op", !hook.installed());

    // A command posted after the release must reach nothing. The retired
    // record's own counter is the evidence: a hook left installed would have
    // entered it and dispatched out of the released route table.
    const retired_before = hook.commands;
    const after_release = try deliverCommand(
        stage,
        io,
        &door,
        @as(winapi.Wparam, add_command),
        command_budget_ms,
    );
    var released: PanelCopy = .{};
    try stage.readPanel(&released);
    try report.emit("menu: add_row after the menu was released delivered={s} rows={d}\n", .{
        booleanText(after_release),
        released.rows,
    });
    report.expect("menu.no_command_reached_the_released_menu", !after_release);
    report.expectCount(
        "menu.the_retired_record_was_not_called_again",
        retired_before,
        hook.commands,
    );
    report.expectCount(
        "menu.the_released_menu_left_the_model_alone",
        after_second.rows,
        released.rows,
    );
}

fn optionalBool(value: ?bool) []const u8 {
    return switch (value) {
        null => "not_found",
        true => "true",
        false => "false",
    };
}

const DrainRows = struct {};

fn drainRows(panel: *Panel, _: DrainRows) void {
    panel.rows = 0;
}

// ── the one file type this run may register ───────────────────────
//
// A recent document is launched the way every recent document is launched: the
// shell finds the file type registered for the extension, runs its `open`
// verb and passes the path. Without a handler for that extension the entry
// appears in the list and nothing happens when it is chosen, so PUBLISHING a
// document and being able to OPEN it are two different claims, and this run
// makes them under two different approvals.
//
// The registration is per user, under this user's own classes root, and it
// names THIS executable with `%1` as its only argument -- which is exactly the
// line the shell then starts. No machine-wide key is written, no existing file
// type is changed, and the removal names exactly the keys the install created.

const classes_root: []const u8 = "Software\\Classes";
/// The ProgID subkeys this run writes, and nothing else.
const icon_subkey: []const u8 = "DefaultIcon";
const shell_subkey: []const u8 = "shell";
const open_verb: []const u8 = "open";
const command_subkey: []const u8 = "command";
/// What the shell shows for the file type in its own chooser.
const document_friendly_name: []const u8 = "nogui w23 smoke document";

/// The ProgID this run registers the document type under.
///
/// The app identity is operator-chosen and this suffix is fixed, so two runs
/// with different identities never share a registration and one run always
/// finds the registration it wrote. The result is checked against the same
/// grammar the identity itself is, because the shell ignores a name that
/// breaks it and a registration under a name the shell ignores is not one.
fn documentProgId(gpa: std.mem.Allocator, app_id: []const u8) ![]u8 {
    const prog_id = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ app_id, document_type_suffix });
    errdefer gpa.free(prog_id);
    if (!windows.app_identity.isWellFormed(prog_id)) return error.DocumentTypeNameMalformed;
    return prog_id;
}

/// One key path under the classes root, owned.
fn joinKey(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.join(gpa, "\\", parts);
}

/// Write one `REG_SZ` default value under the per-user classes root.
///
/// The default value is where Windows reads a file type's ProgID, a ProgID's
/// name, its icon and the command line it runs, so every value this run writes
/// is a default value and none of them is a named one.
fn setClassString(
    gpa: std.mem.Allocator,
    subkey: []const u8,
    value: []const u8,
) !void {
    const path = try joinKey(gpa, &.{ classes_root, subkey });
    defer gpa.free(path);
    const wide_path = try winapi.wide(gpa, path);
    defer gpa.free(wide_path);
    const wide_value = try winapi.wide(gpa, value);
    defer gpa.free(wide_value);

    // SAFETY: `RegCreateKeyExW` writes the handle when it reports success, and
    // every refusal returns this run before the close below could read it.
    var handle: winapi.Hkey = undefined;
    // A zero status is `ERROR_SUCCESS` and every refusal is a number, so the
    // answer is compared against the one success value rather than against a
    // truthiness that would also swallow a negative status.
    if (winapi.RegCreateKeyExW(
        winapi.hkey_current_user,
        wide_path.ptr,
        0,
        null,
        0,
        winapi.key_write,
        null,
        &handle,
    ) != 0) return error.RegistryWriteRefused;
    defer _ = winapi.RegCloseKey(handle);
    // `REG_SZ` counts BYTES, this is a wide string, and `winapi.wide` already
    // wrote the terminator: two bytes per unit plus two more. Counting the
    // units instead would write a value the shell reads as half as long and
    // stops in the middle of.
    const bytes: winapi.Dword = @intCast(2 * (wide_value.len + 1));
    if (winapi.RegSetValueExW(
        handle,
        null,
        0,
        winapi.reg_sz,
        @ptrCast(wide_value.ptr),
        bytes,
    ) != 0) return error.RegistryWriteRefused;
}

/// Read one default `REG_SZ` value back, or null when there is none to read.
///
/// This exists so "the registration was written" is an observation rather
/// than a claim: the registry answering with the exact string this run wrote
/// is the only fact that says the shell will run what this run intended.
fn readClassString(gpa: std.mem.Allocator, subkey: []const u8) !?[]u8 {
    const path = try joinKey(gpa, &.{ classes_root, subkey });
    defer gpa.free(path);
    const wide_path = try winapi.wide(gpa, path);
    defer gpa.free(wide_path);

    // SAFETY: `RegOpenKeyExW` writes the handle when it reports success, and a
    // non-zero status returns before the close below could read it.
    var handle: winapi.Hkey = undefined;
    // Zero rights is the documented existence query: it grants nothing and
    // answers whether the key is there at all.
    if (winapi.RegOpenKeyExW(
        winapi.hkey_current_user,
        wide_path.ptr,
        0,
        0,
        &handle,
    ) != 0) return null;
    defer _ = winapi.RegCloseKey(handle);

    var bytes: winapi.Dword = 0;
    if (winapi.RegQueryValueExW(handle, null, null, null, null, &bytes) != 0) return null;
    if (bytes < 2) return null;
    const buffer = try gpa.alloc(u16, @as(usize, bytes / 2) + 1);
    defer gpa.free(buffer);
    var readable: winapi.Dword = @intCast(bytes + 2);
    if (winapi.RegQueryValueExW(
        handle,
        null,
        null,
        null,
        @ptrCast(buffer.ptr),
        &readable,
    ) != 0) return null;
    const units = buffer[0..@as(usize, readable / 2)];
    // The terminator is part of what the registry counted and is not part of
    // the value, so it is trimmed rather than narrowed into the string.
    const trimmed = if (units.len != 0 and units[units.len - 1] == 0)
        units[0 .. units.len - 1]
    else
        units;
    const value = try winapi.narrow(gpa, trimmed);
    return value;
}

/// Remove one key from the per-user classes root, and report the raw status.
///
/// `RegDeleteKeyW` checks `DELETE` on the PARENT handle rather than on the
/// key it removes, so the parent is opened with that right and every leaf is
/// named relative to it. `ERROR_FILE_NOT_FOUND` is a real answer -- the key
/// was already gone -- so it comes back as the number it is rather than as a
/// failure of this run.
fn deleteClassKey(gpa: std.mem.Allocator, subkey: []const u8) winapi.Dword {
    const wide_root = winapi.wide(gpa, classes_root) catch
        return winapi.error_file_not_found;
    defer gpa.free(wide_root);
    const wide_sub = winapi.wide(gpa, subkey) catch
        return winapi.error_file_not_found;
    defer gpa.free(wide_sub);
    // SAFETY: `RegOpenKeyExW` writes the handle when it reports success, and a
    // non-zero status returns before the close below could read it.
    var root: winapi.Hkey = undefined;
    if (winapi.RegOpenKeyExW(
        winapi.hkey_current_user,
        wide_root.ptr,
        0,
        winapi.registry_delete,
        &root,
    ) != 0) return winapi.error_file_not_found;
    defer _ = winapi.RegCloseKey(root);
    const status = winapi.RegDeleteKeyW(root, wide_sub.ptr);
    // An `LSTATUS` that came back negative is not a documented answer, so it is
    // reported as absence rather than narrowed into a code the caller would
    // print as one Windows never produced.
    if (status < 0) return winapi.error_file_not_found;
    return @intCast(status);
}

/// Every key the install owns, LEAVES FIRST. A key that still has subkeys
/// cannot be deleted, so the command goes before its verb, the verb before the
/// `shell` key, the ProgID's own subkeys before the ProgID, and the ProgID
/// before the extension that names it.
fn ownedKeys(gpa: std.mem.Allocator, prog_id: []const u8) ![]const []const u8 {
    const order = [_][]const []const u8{
        &.{ prog_id, shell_subkey, open_verb, command_subkey },
        &.{ prog_id, shell_subkey, open_verb },
        &.{ prog_id, shell_subkey },
        &.{ prog_id, icon_subkey },
        &.{prog_id},
        &.{document_extension},
    };
    const keys = try gpa.alloc([]const u8, order.len);
    var filled: usize = 0;
    errdefer {
        for (keys[0..filled]) |key| gpa.free(key);
        gpa.free(keys);
    }
    while (filled < order.len) : (filled += 1) {
        keys[filled] = try joinKey(gpa, order[filled]);
    }
    return keys;
}

/// The one file type this run may register, and its exact undo.
const DocumentAssociation = struct {
    gpa: std.mem.Allocator,
    prog_id: []const u8,
    /// This process's own image path, as the loader named it.
    exe: []const u8,
    /// Every key the install owns, leaves first.
    keys: []const []const u8,

    fn init(gpa: std.mem.Allocator, app_id: []const u8) !DocumentAssociation {
        const prog_id = try documentProgId(gpa, app_id);
        errdefer gpa.free(prog_id);
        const exe = try winapi.moduleFileName(gpa);
        errdefer gpa.free(exe);
        const keys = try ownedKeys(gpa, prog_id);
        errdefer {
            for (keys) |key| gpa.free(key);
            gpa.free(keys);
        }
        return .{ .gpa = gpa, .prog_id = prog_id, .exe = exe, .keys = keys };
    }

    fn deinit(self: *DocumentAssociation) void {
        for (self.keys) |key| self.gpa.free(key);
        self.gpa.free(self.keys);
        self.gpa.free(self.exe);
        self.gpa.free(self.prog_id);
        self.* = undefined;
    }

    /// The command line Windows runs for this type: this executable and the
    /// path as its ONLY argument. That is the whole of what a shell-launched
    /// document arrives as, which is why `%1` is quoted and nothing is
    /// appended after it.
    fn commandLine(self: DocumentAssociation) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "\"{s}\" \"%1\"", .{self.exe});
    }

    /// The key holding that command line.
    fn commandKey(self: DocumentAssociation) ![]u8 {
        return joinKey(self.gpa, &.{ self.prog_id, shell_subkey, open_verb, command_subkey });
    }

    /// Install it. Four writes, in the order Windows reads them: the
    /// extension's ProgID, the ProgID's name, its icon, then its command.
    fn install(self: DocumentAssociation) !void {
        const command = try self.commandLine();
        defer self.gpa.free(command);
        const icon = try std.fmt.allocPrint(self.gpa, "{s},0", .{self.exe});
        defer self.gpa.free(icon);
        const icon_key = try joinKey(self.gpa, &.{ self.prog_id, icon_subkey });
        defer self.gpa.free(icon_key);
        const command_key = try self.commandKey();
        defer self.gpa.free(command_key);

        try setClassString(self.gpa, document_extension, self.prog_id);
        try setClassString(self.gpa, self.prog_id, document_friendly_name);
        try setClassString(self.gpa, icon_key, icon);
        try setClassString(self.gpa, command_key, command);
    }

    /// Remove exactly what `install` created, leaves first, and report how
    /// many of those keys the registry actually took out.
    fn remove(self: DocumentAssociation, report: *Reporter) !usize {
        var removed: usize = 0;
        for (self.keys) |key| {
            const status = deleteClassKey(self.gpa, key);
            try report.emit("  association key \"{s}\": win32 status {d}\n", .{ key, status });
            if (status == 0) removed += 1;
        }
        return removed;
    }
};

// ── the jump list phase ──────────────────────────────

fn runJumpListPhase(plan: *Plan) !void {
    const report = plan.report;
    const gpa = plan.gpa;
    const stage = try Stage.create(gpa, plan.io, .{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .gpu_surface = false,
        .visible = true,
    });
    defer stage.deinit();
    try stage.headlessFrame();

    // The identity the PROCESS holds, read back rather than copied from the
    // option, so a list filed under a string nobody claimed is impossible.
    var held = try windows.app_identity.currentProcessIdentity(gpa);
    if (held == null) {
        try report.emit("jump list: the process holds no explicit identity\n", .{});
        report.expect("jump_list.the_process_held_an_explicit_identity", false);
        return error.IdentityReadbackAbsent;
    }

    // The synthetic document is a real FILE in this user's own data root. The
    // shell records a recent document by path and launches it through the file
    // type registered for its extension, so a URI, or a path this run never
    // wrote, is an entry the shell can record and nobody can open. The path is
    // DERIVED rather than chosen, because the separate process the shell
    // starts to open it has to arrive at the same string on its own.
    const document = try plan.makeDocument();
    try plan.writeDocument(document);
    const written = Io.Dir.cwd().readFileAlloc(plan.io, document, gpa, .unlimited) catch |err| {
        try report.emit("jump list: the synthetic document could not be read back: {s}\n", .{
            @errorName(err),
        });
        report.expect("jump_list.the_synthetic_document_is_a_real_file", false);
        return err;
    };
    defer gpa.free(written);
    try report.emit("jump list: synthetic document \"{s}\", {d} bytes on disk\n", .{
        document,
        written.len,
    });
    report.expect(
        "jump_list.the_synthetic_document_is_a_real_file",
        std.mem.eql(u8, written, document_body),
    );

    var list = windows.jump_list.JumpList.init(gpa);
    defer list.deinit();
    // The list takes ownership of the identity, so the local readback is
    // cleared in the same breath: a second release is impossible rather than
    // merely unlikely.
    list.setIdentity(held.?);
    held = null;
    const recent: windows.jump_list.RecentDocument = .{
        .path = document,
        .display_name = document_friendly_name,
    };
    list.setJumpListTasks(&.{jump_task});
    list.setRecentDocuments(&.{recent});
    try report.emit("jump list: identity=\"{s}\" tasks=1 documents=1\n", .{
        optionalText(list.identityName()),
    });

    // The file type, under its OWN approval, and before the publish: an entry
    // the shell shows should be one it can already open by the time anybody
    // sees it.
    if (plan.options.authorize_association) {
        var association = try DocumentAssociation.init(gpa, plan.app_id);
        defer association.deinit();
        association.install() catch |err| {
            try report.emit("jump list: file association install={s}\n", .{refusalTag(err)});
            report.expect("jump_list.the_registered_command_names_this_executable", false);
            return err;
        };
        winapi.SHChangeNotify(winapi.shcne_assocchanged, winapi.shcnf_idlist, null, null);
        try report.emit(
            "jump list: file association installed under HKCU\\{s}\n" ++
                "  {s} -> {s}\n" ++
                "  {s}\\{s}\\{s}\\{s} runs \"{s}\" \"%1\"\n",
            .{
                classes_root,
                document_extension,
                association.prog_id,
                association.prog_id,
                shell_subkey,
                open_verb,
                command_subkey,
                association.exe,
            },
        );
        // Read the two values back out of the registry: the shell runs what is
        // THERE, and only the registry answering with this run's own strings
        // proves the launch will be the one that was intended.
        const command_key = try association.commandKey();
        defer gpa.free(command_key);
        const wanted = try association.commandLine();
        defer gpa.free(wanted);
        const readback = try readClassString(gpa, command_key);
        defer if (readback) |text| gpa.free(text);
        report.expect(
            "jump_list.the_registered_command_names_this_executable",
            readback != null and std.mem.eql(u8, readback.?, wanted),
        );
        const registered = try readClassString(gpa, document_extension);
        defer if (registered) |text| gpa.free(text);
        report.expect(
            "jump_list.the_extension_points_at_this_runs_file_type",
            registered != null and std.mem.eql(u8, registered.?, association.prog_id),
        );
    } else {
        try report.emit(
            "jump list: no {s} was armed, so NO file type was registered. The list\n" ++
                "  below still publishes and the document entry still appears in the\n" ++
                "  shell, but this run installed no handler for {s}, so choosing that\n" ++
                "  entry opens nothing. The {s} command is what installs one.\n",
            .{ authorize_association_flag, document_extension, @tagName(Command.activation) },
        );
    }

    // The real COM publish. A refusal here is a real answer about this
    // machine, and it is reported by name rather than swallowed.
    const published = list.publish();
    if (published) |_| {
        try report.emit("jump list: publish=accepted\n", .{});
        report.expect("jump_list.publish_reached_com", true);
    } else |err| {
        try report.emit("jump list: publish={s}\n", .{refusalTag(err)});
        report.expect("jump_list.publish_reached_com", false);
        return err;
    }

    // The router, against the live window and the live model. ONE route for
    // this window: the task runs `AddRow` and the document runs
    // `OpenDocument`, because those are two entries of one window rather than
    // two windows.
    var router = windows.jump_list.Router.init(gpa, &stage.bridge);
    defer router.deinit();
    try router.addWindow(.{
        .key = stage.handle,
        .title = window_title,
        .action_name = AddRow.name,
        .document_action_name = OpenDocument.name,
        .document_path = document,
        .owner = stage.weakOwner(),
        .tree = try stage.tree(),
        .focus = stage.focus(),
    });
    report.expectCount("jump_list.the_window_is_registered", 1, router.routes.items.len);

    // WHAT THE SHELL WILL WRITE. Printed from the values the shim was handed:
    // a task's argument list IS its action name, and a document launch IS the
    // handler followed by the path.
    try report.emit(
        \\jump list: the two lines the SHELL writes for these entries, and all of each:
        \\  task:     "<this executable>" "{s}"
        \\  document: "<this executable>" "{s}"
        \\
        \\Choose either in the taskbar's jump list and this binary starts with that line
        \\and NOTHING else: no command word, no {s}, no {s}. The run that receives it
        \\is the {s} command, chosen before any command word is looked for, and it
        \\routes that one argument into this window's live model once.
        \\
    , .{
        jump_task.action_name,
        recent.path,
        authorize_identity_flag,
        authorize_jump_flag,
        @tagName(Command.activation),
    });
    try report.emit(
        "jump list: this process's own command line, as the platform reported it:\n" ++
            "  {d} arguments, and the launch argument is {s}\n",
        .{ plan.shell_argv.len, plan.shell_argument orelse "<none>" },
    );

    // THE SHELL'S OWN DOOR, on the rare run that was in fact started by it. A
    // run a person started carries no launch argument at all, and saying so is
    // a report line and not a check: there is nothing on that line to observe.
    if (plan.shell_argument) |argument| {
        const entry = windows.jump_list.decodeLaunchArgument(
            argument,
            &.{jump_task},
            &.{recent},
        ) catch |err| {
            try report.emit("jump list: shell launch argument \"{s}\"={s}\n", .{
                argument,
                refusalTag(err),
            });
            report.expect("jump_list.the_shell_launch_decoded_to_a_published_entry", false);
            return err;
        };
        report.expect("jump_list.the_shell_launch_decoded_to_a_published_entry", true);

        var before_launch: PanelCopy = .{};
        try stage.readPanel(&before_launch);
        const launched = try router.activate(entry);
        var after_launch: PanelCopy = .{};
        try stage.readPanel(&after_launch);
        try report.emit(
            "jump list: shell launch -> {s} \"{s}\" slot={d} result={s} rows {d} -> {d}\n",
            .{
                @tagName(entry),
                switch (entry) {
                    .task => |name| name,
                    .document => |path| path,
                },
                launched.window.slot,
                @tagName(launched.result),
                before_launch.rows,
                after_launch.rows,
            },
        );
        report.expect("jump_list.the_shell_launch_reached_the_live_window", launched.result == .handled);
        report.expect("jump_list.the_shell_launch_reached_this_window", launched.window.eql(stage.handle));
    } else {
        try report.emit(
            "jump list: this process was NOT started by the shell, so no shell launch is\n" ++
                "  claimed here. Choose either line printed above in the taskbar's jump\n" ++
                "  list and the {s} command runs instead, with nothing on that line but\n" ++
                "  the argument.\n",
            .{@tagName(Command.activation)},
        );
    }

    // REPLAY, and only replay. Everything from here is a selection THIS run
    // constructed from the values it published and handed to the router
    // directly. That proves the router's identity, liveness and payload rules
    // against a live window and a live model. It does NOT prove the shell can
    // reach this window -- only the launch above can, and only when the shell
    // wrote that command line. Every line below is labelled replay so the two
    // can never be read as the same evidence.
    try report.emit(
        "jump list: replay follows. these are selections this run built for itself and\n" ++
            "  handed to the router; they are not the shell's door.\n",
        .{},
    );

    // A selection that names the live window's task reaches that window's
    // model through the same registry the menu uses.
    var before: PanelCopy = .{};
    try stage.readPanel(&before);
    const routed = try router.dispatch(.{ .task = jump_task });
    var after: PanelCopy = .{};
    try stage.readPanel(&after);
    try report.emit(
        "jump list replay: task selection -> slot={d} result={s} rows {d} -> {d} hits={d}\n",
        .{ routed.window.slot, @tagName(routed.result), before.rows, after.rows, after.route_hits },
    );
    report.expect("jump_list.replay_a_task_selection_reached_the_live_window", routed.result == .handled);
    report.expectCount("jump_list.replay_the_live_model_actually_moved", before.rows + 1, after.rows);
    report.expect("jump_list.replay_the_route_counter_moved", after.route_hits > before.route_hits);

    // The document route, which carries its own path as the payload of the
    // action the window declared for its document.
    const document_routed = try router.dispatch(.{ .document = recent });
    var after_document: PanelCopy = .{};
    try stage.readPanel(&after_document);
    try report.emit("jump list replay: document selection -> result={s} document=\"{s}\"\n", .{
        @tagName(document_routed.result),
        after_document.documentPath(),
    });
    report.expect(
        "jump_list.replay_the_document_payload_reached_the_model",
        std.mem.eql(u8, after_document.documentPath(), document),
    );
    report.expect(
        "jump_list.replay_the_document_ran_the_documents_own_action",
        after_document.last_route == route_action,
    );

    // A selection no window claims is unrouted, and the name is the refusal.
    const unrouted = router.dispatch(.{
        .task = .{ .title = "no such window", .action_name = "w23.no_such_action" },
    });
    if (unrouted) |_| {
        try report.emit("jump list replay: an unknown selection was accepted\n", .{});
        report.expect("jump_list.replay_an_unclaimed_selection_is_refused", false);
    } else |err| {
        try report.emit("jump list replay: an unknown selection={s}\n", .{refusalTag(err)});
        report.expect("jump_list.replay_an_unclaimed_selection_is_refused", err == error.Unrouted);
    }

    // The closed-owner refusal: the route is still registered, the weak owner
    // is dead, and the router drops the route rather than running its action.
    stage.alive = false;
    const gone = router.dispatch(.{ .task = jump_task });
    if (gone) |_| {
        try report.emit("jump list replay: a selection for a closed owner was accepted\n", .{});
        report.expect("jump_list.replay_a_closed_owner_is_dropped_not_served", false);
    } else |err| {
        try report.emit("jump list replay: a selection for a closed owner={s}\n", .{refusalTag(err)});
        report.expect("jump_list.replay_a_closed_owner_is_dropped_not_served", err == error.WindowGone);
    }
    report.expectCount(
        "jump_list.replay_the_dead_route_was_forgotten",
        0,
        router.routes.items.len,
    );
    // And a second attempt names no window at all, rather than a replacement.
    const again = router.dispatch(.{ .task = jump_task });
    if (again) |_| {
        try report.emit("jump list replay: a second attempt at the same selection was accepted\n", .{});
        report.expect("jump_list.replay_a_forgotten_route_stays_forgotten", false);
    } else |err| {
        try report.emit("jump list replay: a second attempt at the same selection={s}\n", .{refusalTag(err)});
        report.expect("jump_list.replay_a_forgotten_route_stays_forgotten", err == error.Unrouted);
    }
    stage.alive = true;
}

// ── the shell's own launch ─────────────────────────

/// The run the SHELL started.
///
/// This is a launch and not an approval. The shell writes `exe <entry>` and
/// nothing else, so there is no flag to check and no scope text to compare:
/// what arrives is the one argument the platform reported. The arm's whole job
/// is to open the window the launch is for, mount its model, register its live
/// claim, and route that argument into it ONCE.
///
/// It publishes no list, records no recent document, installs no file type,
/// claims no identity and replays nothing. Each of those is an effect that
/// outlives this process, and the shell asked for a window. An arm that
/// re-published the list on every launch would duplicate every registration the
/// publishing run made, once per click.
fn runActivationPhase(plan: *Plan) !void {
    const report = plan.report;
    const gpa = plan.gpa;
    const argument = plan.shell_argument orelse return error.ShellLaunchWithoutItsArgument;

    // The document this build publishes is DERIVED, not remembered, so the
    // separate process the shell starts for a document arrives at the same
    // path on its own. It is computed here and never written: the file belongs
    // to the run that published the entry, and writing one from a launch would
    // be an effect the launch never asked for.
    const document = try plan.makeDocument();
    const recent: windows.jump_list.RecentDocument = .{
        .path = document,
        .display_name = document_friendly_name,
    };

    try report.emit(
        "activation: this process was started by the SHELL with {d} arguments.\n" ++
            "  the argument it was given: \"{s}\"\n" ++
            "  the document it publishes: \"{s}\"\n",
        .{ plan.shell_argv.len, argument, document },
    );

    const stage = try Stage.create(gpa, plan.io, .{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .gpu_surface = false,
        .visible = true,
    });
    defer stage.deinit();
    try stage.headlessFrame();

    var router = windows.jump_list.Router.init(gpa, &stage.bridge);
    defer router.deinit();
    try router.addWindow(.{
        .key = stage.handle,
        .title = window_title,
        .action_name = AddRow.name,
        .document_action_name = OpenDocument.name,
        .document_path = document,
        .owner = stage.weakOwner(),
        .tree = try stage.tree(),
        .focus = stage.focus(),
    });
    report.expectCount("activation.the_window_is_registered", 1, router.routes.items.len);

    const entry = windows.jump_list.decodeLaunchArgument(
        argument,
        &.{jump_task},
        &.{recent},
    ) catch |err| {
        try report.emit("activation: argument \"{s}\"={s}\n", .{ argument, refusalTag(err) });
        report.expect("activation.the_launch_argument_named_a_published_entry", false);
        return err;
    };
    report.expect("activation.the_launch_argument_named_a_published_entry", true);

    var before: PanelCopy = .{};
    try stage.readPanel(&before);
    const launched = router.activate(entry) catch |err| {
        try report.emit("activation: {s} \"{s}\"={s}\n", .{
            @tagName(entry),
            switch (entry) {
                .task => |name| name,
                .document => |path| path,
            },
            refusalTag(err),
        });
        report.expect("activation.the_launch_reached_the_live_window", false);
        return err;
    };
    // One more frame, so what the launch changed is in this window's own
    // committed tree and not only in the model this file read back.
    try stage.headlessFrame();
    var after: PanelCopy = .{};
    try stage.readPanel(&after);
    try report.emit(
        "activation: {s} \"{s}\" -> slot={d} result={s} rows {d} -> {d} document=\"{s}\"\n",
        .{
            @tagName(entry),
            switch (entry) {
                .task => |name| name,
                .document => |path| path,
            },
            launched.window.slot,
            @tagName(launched.result),
            before.rows,
            after.rows,
            after.documentPath(),
        },
    );
    report.expect("activation.the_launch_reached_the_live_window", launched.result == .handled);
    report.expect("activation.the_launch_reached_this_window", launched.window.eql(stage.handle));
    report.expectCount(
        "activation.the_live_model_moved_exactly_once",
        before.route_hits + 1,
        after.route_hits,
    );
    switch (entry) {
        .task => report.expect(
            "activation.the_task_ran_on_the_window_that_published_it",
            after.rows == before.rows + 1,
        ),
        .document => report.expect(
            "activation.the_document_payload_reached_the_model",
            std.mem.eql(u8, after.documentPath(), document),
        ),
    }

    try report.emit(
        \\activation: what this run did NOT do, and why that is the whole point:
        \\  no jump list published, no recent document recorded, no file type
        \\  registered, no identity claimed, no toast, no credential, no picker.
        \\  Every one of those is an effect that outlives this process and none of
        \\  them is in a launch. The shell asked for a window and one argument.
        \\
        \\the line a person reproduces is one of these two, and nothing else:
        \\  task:     "<this executable>" "{s}"
        \\  document: "<this executable>" "{s}"
        \\
        \\they are published by the {s} command, whose exact approvals are:
        \\  {s} "<exact identity scope>" {s} <AppUserModelID>
        \\  {s} {s} "<exact jump-list scope>"
        \\  {s} {s} "<exact document-association scope>"   (document only)
        \\
        \\the only credential namespace this run may touch is the service "{s}" with
        \\an account "{s}<nonce>", both on the credential and cleanup commands only.
        \\
        \\the native calls on the launch path are GetCommandLineW and LocalFree from
        \\kernel32 and CommandLineToArgvW from shell32. Publishing the entries this
        \\launch routes is ICustomDestinationList, IShellLinkW, IPropertyStore and
        \\SHAddToRecentDocs through the COM shim, and the document's open verb is the
        \\per-user classes root HKCU\{s}. The SDK runtime prerequisites are therefore
        \\a shell that implements ICustomDestinationList, a per-user writable
        \\classes root, and this user's data root to hold the file the recent entry
        \\names.
        \\
    , .{
        jump_task.action_name,
        document,
        @tagName(Command.jumplist),
        authorize_identity_flag,
        app_id_flag,
        authorize_jump_flag,
        jump_scope_flag,
        authorize_association_flag,
        association_scope_flag,
        smoke_service,
        account_prefix,
        classes_root,
    });
}

// ── the notification phase ─────────────────────────

fn runNotificationPhase(plan: *Plan, host_state: *windows.Host) !void {
    const report = plan.report;
    // The service takes ownership of the provider, so nothing here holds one.
    var service = try host_state.notificationService();
    defer service.deinit();

    const capabilities = service.getCapabilities();
    try report.emit(
        "notify: capabilities body={} body_images={} actions={} persistence={} sound={}\n",
        .{
            booleanText(capabilities.body),
            booleanText(capabilities.body_images),
            booleanText(capabilities.actions),
            booleanText(capabilities.persistence),
            booleanText(capabilities.sound),
        },
    );
    if (plan.options.toast_activator == null or plan.options.toast_activator.?.len == 0) {
        try report.emit(
            "notify: no COM activator class id was supplied, so action delivery is not wired\n" ++
                "  to this app's installation (target-SUPPORTED is not installed)\n",
            .{},
        );
    }

    var trace: ResponseTrace = .{};
    var owner: FlagOwner = .{};
    const weak = owner.weak();
    const actions = [_]notifications.Action{.{
        .key = "w23.acknowledge",
        .label = "Acknowledge (w23)",
    }};

    // One toast, replaced, then dismissed. Every answer is the shell's.
    const first = service.submit(.{
        .summary = "w23 synthetic toast",
        .body = "first revision",
        .timeout_ms = 0,
        .actions = &actions,
    }, weak, trace.handler());
    try report.emit("notify: submit={s}\n", .{submitTag(first)});
    // A refused submit is a real answer about this desktop, not a failure of
    // the run, and the run says which answer it got. The switch narrows the
    // union rather than a comparison, so the accepted id is read from the
    // payload that carried it.
    const first_id = switch (first) {
        .accepted => |id| id,
        else => {
            report.expect("notify.a_refused_submit_is_named_not_hidden", true);
            service.shutdown();
            return;
        },
    };
    report.expect("notify.the_shell_accepted_the_first_toast", true);

    // The replace, through the service's own `replace`, which reuses the
    // original owner and handler rather than inventing a second record.
    const replaced = service.replace(first_id, .{
        .summary = "w23 synthetic toast",
        .body = "second revision",
        .timeout_ms = 0,
        .actions = &actions,
    });
    try report.emit("notify: replace({d})={s}\n", .{ first_id, submitTag(replaced) });
    report.expect("notify.the_shell_accepted_the_replacement", replaced == .accepted);

    // The dismiss, through the service's own `dismiss`.
    const dismissed = service.dismiss(first_id);
    try report.emit("notify: dismiss({d})={s}\n", .{ first_id, dismissTag(dismissed) });
    report.expect("notify.the_shell_closed_the_toast", dismissed == .closed);

    // The expiry. This is the one delivery a run with no person can observe,
    // and the budget check already refused a wait that could not reach it.
    const second = service.submit(.{
        .summary = "w23 expiry toast",
        .body = "left to the shell's own timeout",
        .timeout_ms = plan.options.expiry_ms,
    }, weak, trace.handler());
    try report.emit("notify: expiry submit={s} timeout_ms={d}\n", .{
        submitTag(second),
        plan.options.expiry_ms,
    });
    const second_id = switch (second) {
        .accepted => |id| id,
        else => {
            report.expect("notify.a_refused_expiry_submit_is_named", true);
            service.shutdown();
            return;
        },
    };
    const deadline = sdl3.timer.getMillisecondsSinceInit() + plan.options.wait_ms;
    var rounds: u32 = 0;
    while (rounds < max_pump_rounds) : (rounds += 1) {
        if (sdl3.timer.getMillisecondsSinceInit() >= deadline) break;
        _ = try service.pump(pump_slice_ms);
        if (trace.responses > 0) break;
    }
    try report.emit(
        "notify: pump rounds={d} responses={d} actions={d} closings={d} reason={s} key=\"{s}\"\n",
        .{ rounds, trace.responses, trace.actions, trace.closings, trace.last_reason, trace.lastKey() },
    );
    if (trace.responses == 0) {
        // Nothing answered inside the budget. The run says so, and it does not
        // call that a failure of its own: the shell owns this delivery and this
        // process does not.
        report.expect("notify.the_shell_answered_inside_the_budget", false);
        try report.emit(
            "notify: the shell delivered no answer inside the budget; that is the shell's\n" ++
                "  delivery, not this run's, and no answer is invented for it\n",
            .{},
        );
    } else {
        report.expect("notify.the_shell_answered_inside_the_budget", true);
        report.expect("notify.the_answer_named_a_close", trace.closings > 0);
        if (trace.closings > 0) {
            report.expectText("notify.the_close_was_the_expiry", "expired", trace.last_reason);
        }
    }
    const leftover = service.dismiss(second_id);
    try report.emit("notify: dismiss({d})={s}\n", .{ second_id, dismissTag(leftover) });

    // The owner-loss refusal. The service re-checks liveness before a delivery,
    // so a response for a dead owner is completed by the service rather than
    // handed to an owner that can no longer act on it.
    owner.alive = false;
    const before_dead = trace.responses;
    service.handleResponse(second_id, .{ .closed = .{ .reason = .dismissed_by_user } });
    try report.emit("notify: responses before the owner went away={d} after={d}\n", .{
        before_dead,
        trace.responses,
    });
    report.expect(
        "notify.a_response_for_a_dead_owner_never_reaches_its_handler",
        trace.responses == before_dead,
    );

    // The provider going away completes what is left, and that is the service's
    // own terminal path rather than an invented answer.
    service.handleProviderDisconnect();
    try report.emit("notify: provider_lost responses={d} provider_lost_handled={d}\n", .{
        trace.responses,
        trace.provider_lost,
    });
}

// ── the credential phase ──────────────────────────

/// The synthetic secret. It is a constant, it is never printed, and only its
/// length and a comparison result are ever reported, so no secret can reach the
/// report even by accident.
const synthetic_secret = "w23-synthetic-secret-do-not-use";

fn runCredentialPhase(plan: *Plan, host_state: *windows.Host) !void {
    const report = plan.report;
    const gpa = plan.gpa;
    const account = plan.account orelse return error.MissingAccountNamespace;
    const query: credentials.CredentialQuery = .{ .service = smoke_service, .account = account };

    var service = try host_state.credentialService();
    defer service.deinit();

    // The target name the adapter will actually use, printed because it is the
    // string the store is asked about and a reader cannot derive it.
    const template = "{service}/{account}";
    const target = try windows.Credentials.targetNameFor(gpa, template, query);
    defer gpa.free(target);
    try report.emit("credential: target=\"{s}\" service=\"{s}\" account=\"{s}\"\n", .{
        target,
        smoke_service,
        account,
    });
    report.expect(
        "credential.the_target_name_names_this_run's_own_namespace",
        std.mem.indexOf(u8, target, account) != null,
    );

    // CREATE. An occupied namespace is refused rather than replaced, so an
    // existing credential is never overwritten.
    const wrote = service.write(query, synthetic_secret, null);
    try report.emit("credential: write={s}\n", .{writeTag(wrote)});
    if (wrote != .success) {
        report.expect("credential.a_refused_write_is_named_not_hidden", true);
        service.shutdown();
        return;
    }
    report.expect("credential.the_store_accepted_the_synthetic_secret", true);

    // READ. The bytes come back through the provider's own allocation, and
    // only the length and the comparison result are printed.
    const read = service.read(gpa, query, null);
    switch (read) {
        .found => |owned| {
            // The payload is a slice plus the allocator that made it, so it is
            // copied into a mutable local that owns the release.
            var value = owned;
            defer value.deinit();

            try report.emit("credential: read=found bytes={d} matches={s}\n", .{
                value.secret.len,
                booleanText(std.mem.eql(u8, value.secret, synthetic_secret)),
            });
            report.expect(
                "credential.the_read_matches_the_written_bytes",
                std.mem.eql(u8, value.secret, synthetic_secret),
            );
        },
        else => {
            try report.emit("credential: read={s}\n", .{readTag(read)});
            report.expect("credential.the_read_returned_the_stored_bytes", false);
        },
    }

    // DELETE, and then a read that must find nothing.
    const deleted = service.delete(query, null);
    try report.emit("credential: delete={s}\n", .{deleteTag(deleted)});
    report.expect("credential.the_store_deleted_the_synthetic_entry", deleted == .success);
    const after = service.read(gpa, query, null);
    if (after == .found) {
        var leftover = after.found;
        leftover.deinit();
    }
    try report.emit("credential: read after delete={s}\n", .{readTag(after)});
    report.expect("credential.the_deleted_entry_is_gone", after == .not_found);

    // The LOCKED and DENIED shapes. What a particular logon session and store
    // policy produce is this machine's answer, so the run reaches the real
    // call, prints the exact tag, and checks only that a CONNECTED provider
    // answered. A `.unsupported` or a `.disconnected` here would mean the call
    // never reached the store at all, which IS a failure.
    const locked = service.read(gpa, query, null);
    if (locked == .found) {
        var leftover = locked.found;
        leftover.deinit();
    }
    const denied = service.write(query, synthetic_secret, null);
    try report.emit(
        "credential: locked-shape read={s}{s} denied-shape write={s}{s}\n",
        .{
            readTag(locked),
            readFailureSuffix(locked),
            writeTag(denied),
            writeFailureSuffix(denied),
        },
    );
    if (denied == .success) {
        // The store accepted the write, so the entry this run just created has
        // to go before the run ends. Only this run's own entry is touched.
        const rollback = service.delete(query, null);
        try report.emit("credential: rollback delete={s}\n", .{deleteTag(rollback)});
    }
    const locked_connected = switch (locked) {
        .unsupported, .provider_failed => false,
        else => true,
    };
    const denied_connected = switch (denied) {
        .unsupported, .provider_failed => false,
        else => true,
    };
    report.expect("credential.the_locked_shape_reached_a_connected_provider", locked_connected);
    report.expect("credential.the_denied_shape_reached_a_connected_provider", denied_connected);

    // DISCONNECT. The service is shut down, so every later call has to answer
    // with the disconnected tag and nothing else here can produce it.
    service.shutdown();
    const after_shutdown = service.read(gpa, query, null);
    try report.emit("credential: read after shutdown={s}\n", .{readTag(after_shutdown)});
    const read_disconnected = switch (after_shutdown) {
        .provider_failed => |failure| failure == .disconnected,
        else => false,
    };
    report.expect("credential.a_shut_down_service_answers_disconnected", read_disconnected);
    const write_after_shutdown = service.write(query, synthetic_secret, null);
    try report.emit("credential: write after shutdown={s}\n", .{writeTag(write_after_shutdown)});
    const write_disconnected = switch (write_after_shutdown) {
        .provider_failed => |failure| failure == .disconnected,
        else => false,
    };
    report.expect("credential.a_shut_down_service_refuses_a_write", write_disconnected);
}

/// The provider failure behind a credential refusal, or an empty string for a
/// refusal the platform named in its own terms. `advapi32` reports several
/// different codes that all surface as "the store said no", and collapsing
/// them into one tag would hide which one this machine produced.
fn readFailureSuffix(result: credentials.ReadResult) []const u8 {
    return switch (result) {
        .provider_failed => |failure| tagSuffix(providerErrorTag(failure)),
        else => "",
    };
}

fn writeFailureSuffix(result: credentials.WriteResult) []const u8 {
    return switch (result) {
        .provider_failed => |failure| tagSuffix(providerErrorTag(failure)),
        else => "",
    };
}

fn tagSuffix(tag: []const u8) []const u8 {
    return std.fmt.comptimePrint(" ({s})", .{tag});
}

// ── the capture phase ──────────────────────────────

fn runCapturePhase(plan: *Plan, host_state: *windows.Host) !void {
    const report = plan.report;
    const gpa = plan.gpa;
    const source = plan.options.capture_source orelse return error.MissingCaptureSource;

    // The target's SUPPORTED set, read before anything is opened. This is not
    // installed capability and the report says so.
    const caps = windows.Capture.capabilities();
    try report.emit(
        "capture: target-supported available={} platform={s} backend={s} user_approval={}\n" ++
            "  (target-SUPPORTED capability is not installed capability)\n",
        .{
            caps.available,
            @tagName(caps.platform),
            @tagName(caps.backend),
            booleanText(caps.requires_user_approval),
        },
    );
    if (!caps.available) {
        try report.emit("capture: unavailable_reason=\"{s}\"\n", .{caps.unavailable_reason});
        report.expect("capture.the_target_supports_capture", false);
        return error.CaptureUnsupported;
    }
    // The request is validated by the adapter itself, so an incoherent source
    // is refused before a picker is shown.
    const request: capture.Request = .{
        .sources = source,
        .cursor_mode = .embedded,
        .persistence = .transient,
        .app_id = plan.app_id,
    };
    try windows.Capture.validate(request);
    report.expect("capture.the_request_is_accepted_by_the_adapter", true);

    // The session and the provider, at stable addresses, because the sink's
    // context is the session and the backend's pointer is the provider.
    var owner: FlagOwner = .{};
    var session = capture.Session.init(gpa, plan.io, captureOwnerOf(&owner), capture_queue_depth);
    defer session.deinit() catch @panic("W23 capture session could not be released");
    var provider = host_state.captureProvider(session.sink(), captureOwnerOf(&owner));
    session.attach(provider.backend());

    // The picker. This blocks while the OS dialog is open, which is why the
    // owner and the session are already fully built.
    const begun = session.begin(request);
    if (begun) |_| {
        try report.emit("capture: begin=accepted state={s}\n", .{@tagName(session.state())});
    } else |err| {
        try report.emit("capture: begin={s} state={s} failure={s}\n", .{
            refusalTag(err),
            @tagName(session.state()),
            @tagName(session.failure()),
        });
        if (capture.isTerminal(session.state())) {
            report.expect("capture.a_terminal_picker_answer_is_named", true);
            _ = session.stop();
            try provider.deinit();
            return;
        }
        return err;
    }

    // The real frames, driven by the real poll-driven backend. Each acquire
    // drives the transport once, so a frame pool that never fills ends the run
    // instead of spinning.
    const deadline = sdl3.timer.getMillisecondsSinceInit() + plan.options.capture_wait_ms;
    var rounds: u32 = 0;
    var acquired: ?capture.FrameDescriptor = null;
    while (rounds < max_capture_rounds) : (rounds += 1) {
        session.enforceOwnerLifetime();
        if (capture.isTerminal(session.state())) break;
        if (session.acquireLatest()) |frame| {
            acquired = frame;
            break;
        }
        if (sdl3.timer.getMillisecondsSinceInit() >= deadline) break;
        try Io.sleep(plan.io, .fromMilliseconds(@intCast(pump_idle_ms)), .real);
    }
    if (acquired) |frame| {
        var owned = frame;
        const info = session.streamInfo();
        try report.emit(
            "capture: frame {d}x{d} format={s} stride={d} bytes={d} epoch={d} source_class_known={}\n",
            .{
                owned.width,
                owned.height,
                @tagName(owned.format),
                owned.stride,
                owned.totalBytes(),
                info.format_epoch,
                booleanText(info.source_class_known),
            },
        );
        report.expect("capture.the_os_handed_over_a_real_frame", owned.width > 0 and owned.height > 0);
        report.expect(
            "capture.the_negotiated_stream_matches_the_frame",
            info.isConfigured() and info.width == owned.width and info.height == owned.height,
        );
        // The frame's own return path. `presentFrame` hands the newest frame to
        // the renderer and releases the previous one, which is how the source
        // keeps an honest count of what a consumer still holds.
        try report.emit("capture: outstanding before the hand back={d}\n", .{
            session.outstandingFrames(),
        });
        session.presentFrame(owned);
        report.expectCount("capture.the_hand_back_left_no_borrowed_frame", 0, session.outstandingFrames());
    } else {
        report.expect("capture.the_os_handed_over_a_real_frame", false);
        try report.emit("capture: no frame arrived; state={s} failure={s}\n", .{
            @tagName(session.state()),
            @tagName(session.failure()),
        });
    }

    // The provider's own record, read before the teardown, because the provider
    // is what owns the platform objects.
    try report.emit(
        "capture: provider driver={s} outstanding={d} session_outstanding={d}\n",
        .{ @tagName(provider.driver()), provider.outstandingFrames(), session.outstandingFrames() },
    );

    // OWNER LOSS. A dead owner stops a live session, and a request from a dead
    // owner gets no picker at all: a consent dialog for a model that cannot
    // act on the answer would strand the operator.
    if (session.isStreaming()) {
        owner.alive = false;
        session.enforceOwnerLifetime();
        try report.emit("capture: after the owner went away state={s}\n", .{@tagName(session.state())});
        report.expect(
            "capture.a_dead_owner_stops_a_live_session",
            session.state() == .stopped or capture.isTerminal(session.state()),
        );
    }
    const outstanding_after_stop = session.stop();
    try report.emit("capture: stop() returned {d} borrowed frame(s)\n", .{outstanding_after_stop});
    report.expectCount("capture.no_frame_was_left_borrowed", 0, outstanding_after_stop);
    report.expectCount("capture.the_provider_owns_no_borrowed_frame", 0, provider.outstandingFrames());
    try provider.deinit();

    // A begin from a dead owner, on a fresh provider, is refused by name. A
    // picker for a model that cannot act on the answer is not shown.
    var second_owner: FlagOwner = .{ .alive = false };
    var second_session = capture.Session.init(
        gpa,
        plan.io,
        captureOwnerOf(&second_owner),
        capture_queue_depth,
    );
    defer second_session.deinit() catch @panic("W23 capture session two could not be released");
    var second_provider = host_state.captureProvider(
        second_session.sink(),
        captureOwnerOf(&second_owner),
    );
    second_session.attach(second_provider.backend());
    const refused = second_session.begin(request);
    if (refused) |_| {
        try report.emit("capture: a begin from a dead owner was accepted\n", .{});
        report.expect("capture.a_dead_owner_gets_no_picker", false);
    } else |err| {
        try report.emit("capture: begin from a dead owner={s} state={s} failure={s}\n", .{
            refusalTag(err),
            @tagName(second_session.state()),
            @tagName(second_session.failure()),
        });
        report.expect("capture.a_dead_owner_gets_no_picker", err == error.OwnerLost);
    }
    _ = second_session.stop();
    try second_provider.deinit();
}

// ── the accessibility phase ───────────────────────

/// One real presented frame, and the tree the adapter was handed for it.
///
/// The App publishes the semantics of the frame it builds, so the snapshot
/// that came back with the frame IS what the platform is given. There is no
/// second build here, and therefore no way for the published tree to describe
/// a frame other than the one the pixels were lowered from.
///
/// The first frame is also where the field takes focus and binds its text
/// endpoint, because a committed frame is the first moment the carrier has the
/// live identity the App binds an endpoint to. The bind therefore lands after
/// the frame that committed that identity, and the snapshot names the field as
/// the focused node from the frame after it.
fn publishPresented(
    stage: *Stage,
    gpu: *GpuHalf,
    adapter: *windows.Accessibility.Adapter,
    dispatcher: *const semantics.Dispatcher,
    scratch: semantics.Scratch,
    bind: bool,
) !struct { published: usize, applied: usize } {
    const snapshot = try presentFrame(stage, gpu) orelse return error.NoSemanticSnapshot;
    if (bind) try stage.view.bindFieldEndpoint();
    // The WINDOW's own keyboard focus, read from the platform's window flags.
    // The App's focus names a widget inside the window and is a different fact,
    // so the two are not folded together here.
    const window_focused = stage.managed.observed.focused;
    const published = try adapter.publish(snapshot, .{ .focused = window_focused });
    adapter.setWindowFocused(window_focused);
    return .{
        .published = published,
        .applied = adapter.drain(snapshot, dispatcher, scratch),
    };
}

/// The character index of a byte offset in the model's own table, by the
/// platform's own rule. The core publishes and receives BYTE offsets while
/// every accessibility platform counts CHARACTERS, and this is the one place
/// the two are made to agree.
fn characterIndexOf(lengths: []const u8, byte_offset: usize) usize {
    if (lengths.len == 0) return 0;
    var at: usize = 0;
    for (lengths, 0..) |length, character| {
        if (byte_offset <= at) return character;
        if (byte_offset < at + length) return character;
        at += length;
    }
    return lengths.len;
}

fn runAccessibilityPhase(plan: *Plan) !void {
    const report = plan.report;
    const gpa = plan.gpa;

    // A hidden window, because the bridge refuses a window that is already
    // visible. The attach happens first, and the window is shown afterwards.
    const stage = try Stage.create(gpa, plan.io, .{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .gpu_surface = true,
        .visible = false,
    });
    defer stage.deinit();

    // The adapter is heap allocated and self-initializing: the bridge keeps a
    // raw pointer to it for its callbacks, so it has to live at a stable
    // address for as long as it is initialized.
    const adapter = try gpa.create(windows.Accessibility.Adapter);
    var adapter_live = false;
    defer {
        if (adapter_live) {
            adapter.deinit();
            gpa.destroy(adapter);
        }
    }
    adapter.init(gpa, plan.io);
    adapter_live = true;
    try report.emit("accessibility: build_linked={} state_before_attach={s}\n", .{
        windows.Accessibility.linked,
        @tagName(adapter.stateOf()),
    });

    const attached = windows.Accessibility.attach(adapter, stage.managed.native.sdl);
    if (attached) |_| {
        try report.emit("accessibility: attach=accepted\n", .{});
        report.expect("accessibility.the_adapter_attached_to_the_window", true);
    } else |err| {
        try report.emit("accessibility: attach={s}\n", .{refusalTag(err)});
        if (err == error.Unsupported) {
            report.expect("accessibility.this_build_links_no_bridge", true);
            return;
        }
        return err;
    }

    const hwnd = windows.window_interop.getHwnd(stage.managed.native.sdl) orelse
        return error.NoNativeWindow;
    try report.emit("accessibility: dpi_scale={d:.3}\n", .{
        windows.window_interop.dpiScaleOf(hwnd),
    });

    // SAFETY: `GpuHalf.init` fills every field before it returns, and the
    // release below runs only when `gpu_live` says that call returned.
    var gpu: GpuHalf = undefined;
    var gpu_live = false;
    defer if (gpu_live) gpu.deinit(gpa);
    try gpu.init(gpa, plan.io, stage.managed);
    gpu_live = true;
    // The App measures through the same engine that rasterizes, so a measured
    // label and a painted glyph are one measurement.
    stage.app.measure = gpu.adapter.measurer();
    try stage.app.attachGpu(gpu.adapter.gpuEndpoint());
    var gpu_attached = true;
    defer if (gpu_attached) stage.app.detachGpu();

    // The field's ONE shaped measurement, built from the frame's own text
    // service and released BEFORE the device: a layout pins cache leases in
    // that service, and the engine that owns it is retired by the guard
    // above. Registering the shape's address is what lets the annotator
    // publish per-character geometry and the caret op answer from the same
    // layout; nothing else in this run shapes the field.
    // SAFETY: `FieldShape.init` fills every field before it returns, and the
    // release below runs only when `shape_live` says that call returned.
    var shape: FieldShape = undefined;
    var shape_live = false;
    defer if (shape_live) {
        stage.app.textInputManager().clear();
        stage.view.field_shape = null;
        shape.deinit();
    };
    shape = FieldShape.init(gpa, &gpu.adapter.textEngine().service);
    shape_live = true;
    stage.view.field_shape = &shape;

    const publisher = try gpa.create(semantics.Publisher);
    // The App borrows the publisher for as long as the publication is
    // configured, so the configuration is dropped BEFORE the publisher's memory
    // goes rather than after it.
    defer {
        stage.app.semantic_publication = null;
        publisher.deinit();
        gpa.destroy(publisher);
    }
    publisher.* = semantics.Publisher.init(gpa);
    // The App publishes inside the frame it builds, so this is configured ONCE,
    // before the first frame of this phase, and the publisher, the window name
    // and the annotator's context then stay alive for every frame it presents.
    // The publisher is heap allocated and never moved, which is what lets the
    // App borrow it by pointer.
    stage.app.semantic_publication = .{
        .publisher = publisher,
        .window_name = stage.view.title,
        .annotator = .{ .context = &stage.view, .annotate = annotateField },
    };
    // The seams borrow the stage's own App, Session, ticket and view, and this
    // value outlives every frame the drain below replays a request against.
    var seams: NativeSeams = .{
        .app = stage.app,
        .session = &stage.session,
        .panel = stage.panel,
        .view = &stage.view,
    };
    const dispatcher = NativeDispatcher.build(&seams);
    // SAFETY: only the two slices named below are ever read, and the publisher
    // fills what it writes into them before it reads them back.
    var scratch_storage: [semantics.Scratch.default_capacity]u8 = undefined;
    const scratch: semantics.Scratch = .{
        .row_name = scratch_storage[0..1024],
        .text_value = scratch_storage[1024..],
    };

    // The window is shown AFTER the attach, and the frames that follow are
    // real presented frames, so the published tree describes a window a screen
    // reader could actually reach.
    try stage.show();
    var published_nodes: usize = 0;
    // The APPLIED count, and only that. `Adapter.drain` tallies the requests
    // the core applied and exposes no counter for one it dequeued and then
    // refused, so a client that sent an action this tree does not offer would
    // read zero here with a real request behind it. Nothing below treats this
    // number as "nothing arrived".
    var applied_requests: usize = 0;
    var frame_index: u32 = 0;
    while (frame_index < plan.options.frames) : (frame_index += 1) {
        const step = try publishPresented(
            stage,
            &gpu,
            adapter,
            &dispatcher,
            scratch,
            frame_index == 0,
        );
        published_nodes = step.published;
        applied_requests += step.applied;
    }

    const field_id = stage.view.field_id orelse return error.NoFieldIdentity;
    // The keyboard belongs to this field or to nobody. The App binds an
    // endpoint only to the focused widget, so this is also the fact that makes
    // the endpoint bound above reachable at all.
    const focused = stage.app.textInputManager().focusedId();
    report.expect(
        "accessibility.the_focused_text_endpoint_is_this_field",
        if (focused) |held| held.eql(field_id) else false,
    );

    // The ORDINARY half of the same field. A committed-text event travels the
    // App's own event path, which is where a person's keystroke and an IME
    // commit both arrive, and it edits the same model a UI Automation
    // `SetValue` edits. One event, one committed edit: the model's own counter
    // moves by exactly one and the native counter does not move at all.
    var before: PanelCopy = .{};
    try stage.readPanel(&before);
    if (try stage.app.handle(.{ .text_input = .{ .text = ordinary_commit } })) |output| {
        if (output.json) |json| stage.gpa.free(json);
    }
    // One shift-Left through the same door, so the published selection is a
    // REVERSED one over a MULTI-BYTE character. A direction that only survives
    // if the two endpoints were kept apart all the way to the snapshot, in
    // units the platform does not count the way the core does.
    if (try stage.app.handle(.{ .key_down = .{ .key = .left, .shift = true } })) |output| {
        if (output.json) |json| stage.gpa.free(json);
    }
    // One more real presented frame, so the tree the platform is handed
    // describes the edit rather than the state before it. `frames_presented`
    // below counts this frame too, so the extra one is visible rather than
    // hidden in the loop.
    const step = try publishPresented(stage, &gpu, adapter, &dispatcher, scratch, false);
    published_nodes = step.published;
    applied_requests += step.applied;

    const capability = adapter.capability();
    const asked = windows.Accessibility.screenReaderAsked(adapter);
    try report.emit(
        "accessibility: state={s} adapter={} screen_reader_asked={} published_nodes={d} full_tree={}\n",
        .{
            @tagName(adapter.stateOf()),
            booleanText(capability.adapter),
            booleanText(asked),
            published_nodes,
            booleanText(adapter.lastWasFullTree()),
        },
    );
    report.expect("accessibility.the_adapter_is_active", adapter.stateOf() == .active);
    report.expect("accessibility.a_real_tree_was_published", published_nodes > 0);

    // The field node, read back out of what the bridge was handed. This is the
    // published state, not a model read.
    const node_id = semantics.nodeId(field_id, .self_node);
    const role = adapter.lastRole(node_id);
    const label = adapter.lastLabel(node_id);
    const actions_bits = adapter.lastActions(node_id);
    const rect = adapter.lastRect(node_id);
    const published_value = adapter.lastValue(node_id);
    const published_lengths = adapter.lastCharacterLengths(node_id);
    const published_selection = adapter.lastTextSelection(node_id);
    const run_owner = adapter.lastTextSelectionOwner(node_id);

    var final_model: PanelCopy = .{};
    try stage.readPanel(&final_model);
    const model_selection = try final_model.byteSelection();
    const table = final_model.lengths[0..final_model.characters];

    // SAFETY: `bufPrint` below writes the bytes and returns the prefix length,
    // so only what it returned is ever read back out of this buffer.
    var rect_text: [64]u8 = undefined;
    const rect_written = if (rect) |value| std.fmt.bufPrint(
        &rect_text,
        "[{d:.1},{d:.1} {d:.1}x{d:.1}]",
        .{ value[0], value[1], value[2], value[3] },
    ) catch "unformattable" else "unpublished";
    try report.emit(
        "accessibility: field role={s} actions=0x{x} label=\"{s}\" rect={s}\n",
        .{ roleName(role), actions_bits orelse 0, optionalText(label), rect_written },
    );
    try report.emit(
        "accessibility: field value=\"{s}\" bytes={d} characters={d} published_table={d}\n",
        .{
            optionalText(published_value),
            if (published_value) |value| value.len else 0,
            final_model.characters,
            if (published_lengths) |lengths| lengths.len else 0,
        },
    );
    try report.emit(
        "accessibility: field selection anchor={d} focus={d} reversed={} " ++
            "model_bytes={d}..{d} model_units={d}..{d} run={s}\n",
        .{
            if (published_selection) |sel| sel.anchor else 0,
            if (published_selection) |sel| sel.focus else 0,
            booleanText(final_model.reversed),
            model_selection.anchor,
            model_selection.focus,
            final_model.anchor_unit,
            final_model.cursor_unit,
            if (run_owner != null and
                run_owner.? == semantics.nodeId(field_id, .text_run))
                "this_field"
            else
                "absent",
        },
    );
    report.expect("accessibility.the_field_node_was_published", role != null);
    report.expect("accessibility.the_field_published_a_label", label != null);
    report.expect("accessibility.the_field_published_its_box", rect != null);
    report.expect(
        "accessibility.the_field_is_published_as_a_text_node",
        role != null and role.? == @backingInt(semantics.Role.text_input),
    );
    // The native seam is reachable only when the node really offers the two
    // actions that carry it: the core refuses any action whose bit is clear,
    // so a node published without them could never be edited from a screen
    // reader however willing this seam was.
    report.expect(
        "accessibility.the_field_offers_both_text_actions",
        actions_bits != null and
            actions_bits.? & text_action_mask == text_action_mask,
    );
    report.expect(
        "accessibility.the_published_value_is_the_models_own_bytes",
        if (published_value) |value|
            std.mem.eql(u8, value, final_model.fieldText())
        else
            false,
    );
    report.expectCount(
        "accessibility.the_published_table_covers_every_character",
        final_model.characters,
        if (published_lengths) |lengths| lengths.len else 0,
    );
    // The platform reads CHARACTERS and the core counts BYTES, so the
    // published endpoints are compared through the model's own table. That a
    // selection survived the round trip at all, and that its anchor sits PAST
    // its focus, is what says the direction did too.
    report.expect(
        "accessibility.the_published_selection_is_the_models_own_and_directional",
        if (published_selection) |sel|
            sel.anchor == characterIndexOf(table, model_selection.anchor) and
                sel.focus == characterIndexOf(table, model_selection.focus) and
                sel.anchor > sel.focus
        else
            false,
    );
    report.expect(
        "accessibility.the_published_selection_names_this_field_run",
        run_owner != null and run_owner.? == semantics.nodeId(field_id, .text_run),
    );

    // The candidate rectangle, asked of the endpoint the App bound. It comes
    // from the same layout the published advances came from, so a candidate
    // window and a screen-reader caret name one place rather than two that
    // happen to agree today.
    const caret = try stage.app.textInputManager().caretGeometry();
    // SAFETY: `bufPrint` below writes the bytes and returns the prefix length,
    // so only what it returned is ever read back out of this buffer.
    var caret_text: [96]u8 = undefined;
    const caret_written = if (caret) |value| std.fmt.bufPrint(
        &caret_text,
        "[{d:.1},{d:.1} {d:.1}x{d:.1}] cursor={d:.1}",
        .{ value.area.x, value.area.y, value.area.w, value.area.h, value.cursor },
    ) catch "unformattable" else "unmeasured";
    try report.emit(
        "accessibility: field caret={s} shaped_characters={d} shared_advance_characters={d} " ++
            "carrier=[{d:.1},{d:.1} {d:.1}x{d:.1}]\n",
        .{
            caret_written,
            shape.characters,
            shape.shared,
            shape.box.x,
            shape.box.y,
            shape.box.w,
            shape.box.h,
        },
    );
    report.expect(
        "accessibility.the_caret_geometry_is_measured_inside_the_carrier",
        if (caret) |value|
            value.area.x >= shape.box.x and
                value.area.y >= shape.box.y and
                value.area.x + value.area.w <= shape.box.x + shape.box.w and
                value.area.y + value.area.h <= shape.box.y + shape.box.h
        else
            false,
    );
    // The shape was measured from the value the model holds NOW, so its
    // character count and the model's are one number. A shape left over from
    // before the edit would be two characters short.
    report.expectCount(
        "accessibility.the_published_geometry_covers_every_character",
        final_model.characters,
        shape.published().positions.len,
    );

    report.expect(
        "accessibility.one_committed_text_event_is_one_committed_edit",
        final_model.field_edits == before.field_edits + 1,
    );
    report.expect(
        "accessibility.the_ordinary_edit_edited_the_model_this_field_publishes",
        final_model.fieldText().len == before.fieldText().len + ordinary_commit.len and
            std.mem.startsWith(u8, final_model.fieldText(), before.fieldText()) and
            std.mem.endsWith(u8, final_model.fieldText(), ordinary_commit),
    );
    report.expectCount(
        "accessibility.the_ordinary_door_edited_nothing_through_the_native_seam",
        before.native_edits,
        final_model.native_edits,
    );
    report.expectText(
        "accessibility.the_caret_motion_reached_the_model_through_the_endpoint",
        route_text_input,
        final_model.last_route,
    );
    report.expectCount(
        "accessibility.one_caret_motion_is_one_resolved_motion",
        1,
        final_model.field_moves,
    );

    try report.emit(
        "accessibility: pending_requests={} applied_requests={d} dropped_requests={d} frames_presented={d}\n",
        .{
            booleanText(adapter.hasPending()),
            applied_requests,
            adapter.droppedRequests(),
            stage.frames_presented,
        },
    );
    try report.emit(
        "accessibility: applied_requests is what the CORE APPLIED, not the number of\n" ++
            "  requests that arrived. `Adapter.drain` returns its applied tally and\n" ++
            "  exposes no counter for a request it dequeued and then refused, so a\n" ++
            "  client that sent an action this tree does not offer would read zero\n" ++
            "  here with a real request behind it. What this run can observe about\n" ++
            "  arrivals is the bridge's own latch and the ring's own overflow count,\n" ++
            "  and both are printed above; the model read back below is the only\n" ++
            "  thing here that says what reached the field.\n",
        .{},
    );
    try report.emit(
        "accessibility: model field_edits={d} native_edits={d} marks={d} erases={d} moves={d} route={s}\n",
        .{
            final_model.field_edits,
            final_model.native_edits,
            final_model.field_marks,
            final_model.field_erases,
            final_model.field_moves,
            final_model.last_route,
        },
    );
    report.expectCount("accessibility.no_request_was_dropped", 0, adapter.droppedRequests());
    report.expect(
        "accessibility.no_request_the_core_applied",
        applied_requests == 0,
    );
    report.expectCount("accessibility.no_native_edit_was_replayed", 0, final_model.native_edits);
    try report.emit(
        "accessibility: no screen reader was launched and no trust or system setting was\n" ++
            "  changed by this run; `screen_reader_asked` above is the bridge's own\n" ++
            "  latched observation, and a false there means nothing asked, not that\n" ++
            "  the adapter refused anybody.\n",
        .{},
    );

    // The detach, BEFORE the window is destroyed: the bridge owns the
    // subclassed window procedure, and a window destroyed with the bridge still
    // attached keeps a procedure pointing at freed memory.
    const was_asked = windows.Accessibility.screenReaderAsked(adapter);
    gpu_attached = false;
    stage.app.detachGpu();
    windows.Accessibility.detach(adapter);
    adapter_live = false;
    gpa.destroy(adapter);
    try report.emit("accessibility: detached screen_reader_asked_before_detach={}\n", .{
        booleanText(was_asked),
    });
}

/// A published role's name, or `unknown` for a value no client asked about and
/// a node that carries none.
fn roleName(role: ?u8) []const u8 {
    const value = role orelse return "unpublished";
    return @tagName(std.enums.fromInt(semantics.Role, value) orelse .unknown);
}

// ── the lifecycle phase ────────────────────────────

/// One bounded pump over the host's own event pair. `Application.run` is never
/// called here: the loop is external, so this file owns it.
fn pumpEvents(stage: *Stage, io: Io, budget_ms: u64) !u32 {
    const deadline = sdl3.timer.getMillisecondsSinceInit() + budget_ms;
    var iterations: u32 = 0;
    var dispatched: u32 = 0;
    while (iterations < max_pump_iterations) : (iterations += 1) {
        const raw = stage.application.pollEvent() orelse {
            if (sdl3.timer.getMillisecondsSinceInit() >= deadline) break;
            try Io.sleep(io, .fromMilliseconds(@intCast(pump_idle_ms)), .real);
            continue;
        };
        if (try stage.application.dispatch(&raw) != null) dispatched += 1;
        if (!stage.application.isRunning()) break;
    }
    return dispatched;
}

fn runLifecyclePhase(plan: *Plan) !void {
    const report = plan.report;
    const gpa = plan.gpa;
    const io = plan.io;

    const first = try Stage.create(gpa, io, .{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .gpu_surface = true,
        .visible = true,
    });
    var first_live = true;
    defer if (first_live) first.deinit();

    // One device, created over the first window's surface.
    // SAFETY: `GpuHalf.init` fills every field before it returns, and the
    // release below runs only when `gpu_live` says that call returned.
    var gpu: GpuHalf = undefined;
    var gpu_live = false;
    defer if (gpu_live) gpu.deinit(gpa);
    try gpu.init(gpa, io, first.managed);
    gpu_live = true;
    first.app.measure = gpu.adapter.measurer();
    try first.app.attachGpu(gpu.adapter.gpuEndpoint());
    var first_attached = true;
    defer if (first_attached) first.app.detachGpu();

    try report.emit("lifecycle: after one window surfaces={d} window_count={d}\n", .{
        gpu.gpu.numSurfaces(),
        first.application.window_count,
    });

    const peer = try Stage.create(gpa, io, .{
        .title = second_window_title,
        .width = second_window_width,
        .height = second_window_height,
        .gpu_surface = true,
        .visible = true,
    });
    var peer_live = true;
    defer if (peer_live) peer.deinit();
    var peer_attached = false;

    // The peer's own surface, on the shared device. The first window's surface
    // is fully released before the peer's is built, so this run presents
    // through ONE surface at a time and says so rather than claiming two. The
    // half is torn down completely — adapter, surface, device, shader bytes —
    // so the second build starts from nothing rather than over a live device.
    first_attached = false;
    first.app.detachGpu();
    gpu_live = false;
    gpu.deinit(gpa);
    try gpu.init(gpa, io, peer.managed);
    gpu_live = true;
    peer.app.measure = gpu.adapter.measurer();
    try peer.app.attachGpu(gpu.adapter.gpuEndpoint());
    peer_attached = true;
    try report.emit("lifecycle: two windows, one shared device, one surface at a time\n", .{});

    // The native menu on the first window, and this directory's own window
    // procedure on that window, so the lifecycle phase drives a real DELIVERED
    // `WM_COMMAND` as well as real frames.
    //
    // OWNERSHIP ORDER, declared here and enforced at the foot of this arm. The
    // attachment is retired, then the menu is released, and only then is the
    // window destroyed. The first two steps are no longer load-bearing: the
    // menu release retires the attachment naming it, so this order is one that
    // works rather than one that has to be discovered. The window still goes
    // LAST, because `Stage.deinit` releases every window the application owns,
    // and a procedure and an `HMENU` still attached when it runs would both be
    // pointing into a window that no longer exists.
    try first.headlessFrame();
    const evaluated = try first.bridge.evaluate(gpa, menu_bar, try first.tree(), first.focus());
    const native = try windows.Menus.build(gpa, menu_bar, evaluated);
    var attached_menu = try windows.Menus.WindowMenu.init(first.managed.native.sdl, native);
    var menu_live = true;
    defer if (menu_live) attached_menu.deinit();
    var door: MenuDoor = .{ .stage = first, .menu = &attached_menu, .gpa = gpa };
    // SAFETY: `Subclass.attach` fills this before it returns its hook, and
    // every read of it goes through that hook after the call succeeded.
    var attachment: windows.Menus.Subclass = undefined;
    const hook = try windows.Menus.Subclass.attach(&attachment, &attached_menu, .{
        .context = &door,
        .bridge = &first.bridge,
        .tree = MenuDoor.tree,
        .focus = MenuDoor.focus,
        .on_result = MenuDoor.onResult,
        .on_init_menu_popup = MenuDoor.onPopup,
    });
    // Registered after the menu's own defer, so on an error path the procedure
    // still comes off first. `detach` is idempotent, and the menu release below
    // retires the record on its own, so the explicit call at the foot of this
    // arm and this one cannot both do work.
    defer hook.detach();
    const add_command = commandForAction(&attached_menu.menu, AddRow.name) orelse
        return error.MissingMenuCommand;
    var before: PanelCopy = .{};
    try first.readPanel(&before);
    const menu_delivered = try deliverCommand(
        first,
        io,
        &door,
        @as(winapi.Wparam, add_command),
        command_budget_ms,
    );
    var after: PanelCopy = .{};
    try first.readPanel(&after);
    try report.emit("lifecycle: native menu delivered={s} result={s} rows {d} -> {d}\n", .{
        booleanText(menu_delivered),
        outcomeTag(door.last_outcome),
        before.rows,
        after.rows,
    });
    report.expect("lifecycle.the_platform_delivered_the_command", menu_delivered);
    report.expect(
        "lifecycle.a_native_command_reached_the_live_model",
        answeredResult(door.last_outcome) == .handled,
    );
    report.expectCount("lifecycle.the_model_actually_moved", before.rows + 1, after.rows);

    // Bounded real frames on the peer, then the half moves back to the first
    // window for its own frames, then a bounded event pump. Presenting through
    // one surface at a time is the honest shape here: two surfaces on one
    // device would mean holding two swapchains across a window close, and this
    // phase exists to observe a close, not to maximize concurrency.
    var frame_index: u32 = 0;
    while (frame_index < plan.options.frames) : (frame_index += 1) {
        _ = try presentFrame(peer, &gpu);
    }
    peer_attached = false;
    peer.app.detachGpu();
    gpu_live = false;
    gpu.deinit(gpa);
    try gpu.init(gpa, io, first.managed);
    gpu_live = true;
    first.app.measure = gpu.adapter.measurer();
    try first.app.attachGpu(gpu.adapter.gpuEndpoint());
    first_attached = true;
    _ = try presentFrame(first, &gpu);
    try first.headlessFrame();
    const dispatched = try pumpEvents(first, io, plan.options.hold_ms);
    try report.emit(
        "lifecycle: first committed={d} presented={d} peer committed={d} presented={d} routed_events={d}\n",
        .{
            first.frames_committed,
            first.frames_presented,
            peer.frames_committed,
            peer.frames_presented,
            dispatched,
        },
    );
    report.expect(
        "lifecycle.frames_were_presented_through_a_real_surface",
        gpu.adapter.stats.frames_presented > 0,
    );
    // Each `Stage` owns its own `Application` and each `openWindowWithApp`
    // stamps the handle with that Application's id, so the count of windows
    // this arm opened is the sum over both, and closing the peer has to go
    // through the host that minted its handle.
    report.expectCount(
        "lifecycle.the_host_reports_both_windows",
        2,
        first.application.window_count + peer.application.window_count,
    );

    // The counters, BEFORE the retirement, so a later value cannot explain an
    // earlier one.
    try report.emit(
        "lifecycle: before teardown window_count={d} surfaces={d} frames_committed={d} frames_presented={d}\n",
        .{
            first.application.window_count + peer.application.window_count,
            gpu.gpu.numSurfaces(),
            gpu.adapter.stats.frames_committed,
            gpu.adapter.stats.frames_presented,
        },
    );
    report.expect("lifecycle.the_device_reported_a_surface_for_a_live_window", gpu.gpu.numSurfaces() >= 1);

    // The retirement, in the one order the contracts allow: the App detaches
    // from the endpoint, then the adapter, then the surface, then the device.
    peer_attached = false;
    peer.app.detachGpu();
    const closed = peer.application.closeWindow(peer.handle);
    if (closed) |_| {
        try report.emit("lifecycle: close peer=accepted window_count={d}\n", .{
            peer.application.window_count,
        });
    } else |err| {
        try report.emit("lifecycle: close peer={s} window_count={d}\n", .{
            refusalTag(err),
            peer.application.window_count,
        });
    }
    report.expectCount("lifecycle.closing_one_window_left_the_other", 0, peer.application.window_count);
    report.expect(
        "lifecycle.the_closed_session_window_is_retired",
        !peer.session.hasWindow(peer.app.window),
    );
    peer_live = false;
    peer.deinit();

    // The surviving window presents once more, on the same device, so the
    // report shows a live surface after a window went away. The half is
    // released and rebuilt so the new surface is created over the window that
    // is actually alive, and nothing of the peer's survives the move.
    first_attached = false;
    first.app.detachGpu();
    gpu_live = false;
    gpu.deinit(gpa);
    try gpu.init(gpa, io, first.managed);
    gpu_live = true;
    first.app.measure = gpu.adapter.measurer();
    try first.app.attachGpu(gpu.adapter.gpuEndpoint());
    first_attached = true;
    _ = try presentFrame(first, &gpu);
    try report.emit("lifecycle: after the peer closed surfaces={d} first_presented={d}\n", .{
        gpu.gpu.numSurfaces(),
        first.frames_presented,
    });
    report.expect("lifecycle.exactly_one_surface_is_live_after_the_peer_closed", gpu.gpu.numSurfaces() == 1);

    // The final counters, read while both are still alive: the device's own
    // surface count and the host's own window count.
    try report.emit("lifecycle: final windows={d} surfaces={d} first_frames_presented={d}\n", .{
        first.application.window_count,
        gpu.gpu.numSurfaces(),
        first.frames_presented,
    });
    report.expectCount("lifecycle.one_window_is_left_before_the_retirement", 1, first.application.window_count);

    first_attached = false;
    first.app.detachGpu();
    // THE ORDER, explicitly. The attachment is retired, then the menu is
    // released -- and the window is destroyed HERE, by this arm, rather than by
    // a defer that would have run after these two. The window must go last: a
    // `defer` registered where the procedure was installed would have taken
    // the window out from under both of them. The read below is the window's
    // own answer about which procedure it is running, which is the only
    // evidence that this directory's is off it.
    hook.detach();
    attached_menu.deinit();
    menu_live = false;
    report.expect("lifecycle.the_procedure_came_off_before_the_window_did", !hook.installed());
    first_live = false;
    first.deinit();
    gpu_live = false;
}

// ── the cleanup phase ──────────────────────────────

fn runCleanupPhase(plan: *Plan, host_state: *windows.Host) !void {
    const report = plan.report;
    const gpa = plan.gpa;
    const account = plan.account orelse return error.MissingAccountNamespace;
    const query: credentials.CredentialQuery = .{ .service = smoke_service, .account = account };

    // The credential entry. Only the exact namespace the operator named is
    // touched, and a namespace that is already empty is reported rather than
    // treated as a failure.
    {
        var service = try host_state.credentialService();
        defer service.deinit();
        const deleted = service.delete(query, null);
        try report.emit("cleanup: credential delete={s} service=\"{s}\" account=\"{s}\"\n", .{
            deleteTag(deleted),
            smoke_service,
            account,
        });
        const after = service.read(gpa, query, null);
        if (after == .found) {
            var leftover = after.found;
            leftover.deinit();
        }
        try report.emit("cleanup: credential read after delete={s}\n", .{readTag(after)});
        report.expect("cleanup.the_named_namespace_is_empty", after != .found);
    }

    // The synthetic toast. A toast id is a NUMBER the shell assigned, and a run
    // cannot invent one, so the cleanup names the id or says it has none. The
    // service's own teardown then runs the runtime and activator
    // unregistration the provider registered, so the COM activator this run
    // registered is withdrawn here.
    {
        var service = try host_state.notificationService();
        defer service.deinit();
        if (plan.options.toast_id) |id| {
            const dismissed = service.dismiss(id);
            try report.emit("cleanup: toast dismiss({d})={s}\n", .{ id, dismissTag(dismissed) });
            report.expect(
                "cleanup.the_named_toast_is_gone_or_refused_by_name",
                dismissed == .closed or dismissed == .refused or dismissed == .unsupported,
            );
        } else {
            try report.emit(
                "cleanup: no {s} was named, so no toast was dismissed; a toast id is a number\n" ++
                    "  the shell assigned and this run does not guess one\n",
                .{toast_id_flag},
            );
            report.expect("cleanup.no_toast_id_was_invented", true);
        }
        try report.emit(
            "cleanup: the notification service is now being retired, which unregisters the\n" ++
                "  COM activator this run registered\n",
            .{},
        );
    }

    // The jump list. Publishing an empty list for the identity this process
    // holds is the shell's own way to withdraw what was published, and it is
    // scoped to THIS identity because the gate refuses any other.
    {
        var held = try windows.app_identity.currentProcessIdentity(gpa);
        if (held == null) {
            try report.emit("cleanup: the process holds no explicit identity\n", .{});
            report.expect("cleanup.the_process_held_an_explicit_identity", false);
            return error.IdentityReadbackAbsent;
        }
        var list = windows.jump_list.JumpList.init(gpa);
        defer list.deinit();
        // The list owns the identity from this line, so the local readback is
        // cleared rather than released twice.
        list.setIdentity(held.?);
        held = null;
        // No tasks and no documents: the models were never set, so the publish
        // is a withdrawal rather than a new list.
        const withdrawn = list.publish();
        if (withdrawn) |_| {
            try report.emit("cleanup: jump list withdraw=accepted\n", .{});
            report.expect("cleanup.the_empty_jump_list_was_published", true);
        } else |err| {
            try report.emit("cleanup: jump list withdraw={s}\n", .{refusalTag(err)});
            report.expect("cleanup.the_empty_jump_list_was_published", false);
        }
    }

    // The per-user file association, and the synthetic file it opened. Both
    // are named by the same derived strings the installing run used, so the
    // removal reaches this app's own registration and no other. A key the
    // registry reports as already absent is reported by its own number, which
    // is `ERROR_FILE_NOT_FOUND`, and is not a failure of this run.
    {
        const document = try plan.makeDocument();
        const said_removed = plan.removeDocument(document);
        // The filesystem is asked, not the return value: a delete that reported
        // success and left the file behind is a claim this run would repeat.
        const still_there = blk: {
            const status = Io.Dir.cwd().statFile(plan.io, document, .{}) catch break :blk false;
            break :blk status.kind == .file;
        };
        try report.emit("cleanup: synthetic document \"{s}\" delete said removed={}\n", .{
            document,
            said_removed,
        });
        report.expect("cleanup.the_synthetic_document_is_gone_from_disk", !still_there);

        var association = try DocumentAssociation.init(gpa, plan.app_id);
        defer association.deinit();
        const removed = try association.remove(report);
        winapi.SHChangeNotify(winapi.shcne_assocchanged, winapi.shcnf_idlist, null, null);
        try report.emit(
            "cleanup: file association for {s} under HKCU\\{s}: {d} of {d} keys removed\n",
            .{ document_extension, classes_root, removed, association.keys.len },
        );
        report.expectCount(
            "cleanup.the_association_this_run_installed_is_gone",
            association.keys.len,
            removed,
        );
    }

    try report.emit(
        "cleanup: only records this run created were touched; nothing else on this\n" ++
            "  desktop was read, rewritten or removed\n",
        .{},
    );
}

// ── main ─────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // THE SHELL'S OWN DOOR, read BEFORE any command word is looked for. The
    // shell writes a jump list entry as this executable's only argument, and a
    // parser that demanded a command word first would refuse that very line.
    // The reading is the platform's own, through `GetCommandLineW` and the
    // shell's own splitter, so nothing this binary invented decides it.
    var launch: ?windows.jump_list.ProcessCommandLine = if (comptime winapi.is_windows)
        try windows.jump_list.processCommandLine(gpa)
    else
        null;
    defer if (launch) |*line| {
        line.deinit();
    };
    const shell_argv: []const []const u8 = if (launch) |line| line.argv else &.{};
    const shell_argument: ?[]const u8 = if (launch) |line| line.argument else null;

    const options = try parseArgs(gpa, init, shell_argument);
    try checkFlagPlacement(options);
    checkNotificationBudget(options) catch |err| {
        std.log.err(
            "{s} must exceed {s} by at least {d} ms; received wait={d} ms, expiry={d} ms",
            .{ wait_flag, expiry_flag, min_pump_slack_ms, options.wait_ms, options.expiry_ms },
        );
        return err;
    };

    var report: Reporter = .{ .io = io };
    try report.emit("W23 E03/E05 Windows native consumer smoke\n", .{});
    try report.emit("command: {s}\n", .{@tagName(options.command)});

    // The two commands that touch nothing. They run, report, and the run ends:
    // no provider, no SDL, no window and no approval are involved in either.
    switch (options.command) {
        .help => {
            try printUsage(&report, options);
        },
        .probe => try runProbe(&report),
        else => {},
    }
    if (options.command != .help and options.command != .probe) {
        try report.emit(
            "target: this binary claims runtime evidence for E03 and E05 only on Windows;\n" ++
                "  every other target's result here is a refusal, not parity.\n",
            .{},
        );

        if (options.command == .activation) {
            // The run the SHELL started. It claims no identity, builds no Host
            // and approves nothing, because the shell writes no flags and a
            // window is what a launch asks for. Its one argument came from the
            // platform reading above and from nowhere else.
            var plan: Plan = .{
                .gpa = gpa,
                .io = io,
                .report = &report,
                .options = options,
                .app_id = "",
                .shell_argument = shell_argument,
                .shell_argv = shell_argv,
            };
            try runActivationPhase(&plan);
        } else {
            // The namespace is checked BEFORE anything is built and before the
            // scope text that names it is compared, so a command line naming a
            // real account is refused here rather than after a provider exists.
            const account = if (options.command == .credential or options.command == .cleanup)
                try checkNamespaceForm(options)
            else
                null;
            // The FIRST thing built is the process identity, because every
            // other adapter in this directory depends on it, so its approval
            // is checked before any of them.
            const app_id = try requireIdentityAuthorization(options);
            try requirePhaseAuthorization(options);

            if (comptime !winapi.is_windows) {
                try report.emit(
                    "refused: this build has no Windows platform, so there is no shell to claim an\n" ++
                        "  identity in, no credential store, no toast host and no capture picker.\n" ++
                        "  (windows.isApplicable()={})\n",
                    .{windows.isApplicable()},
                );
                report.expect("native.this_build_has_a_windows_platform", false);
                return error.NotWindowsTarget;
            }

            var host_state = try windows.Host.init(gpa, io, .{
                .app_id = app_id,
                .toast_group = options.toast_group,
                .toast_activator_cls_id = options.toast_activator orelse "",
            });
            defer host_state.deinit();

            var plan: Plan = .{
                .gpa = gpa,
                .io = io,
                .report = &report,
                .options = options,
                .app_id = app_id,
                .account = account,
                .shell_argument = shell_argument,
                .shell_argv = shell_argv,
            };
            switch (options.command) {
                .help, .probe, .activation => unreachable,
                .identity => try runIdentityPhase(&plan, &host_state),
                .window => try runWindowPhase(&plan),
                .menu => try runMenuPhase(&plan),
                .jumplist => try runJumpListPhase(&plan),
                .notify => try runNotificationPhase(&plan, &host_state),
                .credential => try runCredentialPhase(&plan, &host_state),
                .capture => try runCapturePhase(&plan, &host_state),
                .accessibility => try runAccessibilityPhase(&plan),
                .lifecycle => try runLifecyclePhase(&plan),
                .cleanup => try runCleanupPhase(&plan, &host_state),
            }
        }
    }

    try report.emit("checks: {d} passed, {d} failed\n", .{ report.checks, report.failures });
    if (report.failures != 0) return error.CheckFailed;
}
