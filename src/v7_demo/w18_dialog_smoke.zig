//! W18 dialog smoke — the halves that need no person, the half that needs
//! approval, and the half that only reads.
//!
//! The clipboard branch mutates the user's own clipboard, so it is off by
//! default and runs only under an explicit flag. Even then it takes the whole
//! item first and puts it back, and it refuses to touch anything it cannot
//! restore.
//!
//! The file-dialog branch runs in a child process of this same binary whose
//! environment names no session bus, so the real portal adapter refuses
//! before it reaches the bus. That child needs no display and no clipboard:
//! it runs SDL on the dummy video driver.
//!
//! `--native-observations` adds the observation arm. It reads the compositor,
//! theme, titlebar-button layout, scrollbar, thermal, folder, base-path and
//! auxiliary-executable answers of the display server this run is actually
//! attached to, and it exercises launch buffering and the menu bridge on this
//! process's own synthetic data. That arm opens NO window, because nothing in
//! it paints and no GPU surface is therefore claimed. It reads and writes NO
//! clipboard, asks for no dialog, registers no scheme with the desktop,
//! launches no URL and approves nothing.
//!
//! The menu half of that arm formats its titles, labels and payloads from its
//! own model state into one buffer, releases that buffer before its first
//! click, and routes every click from a row a snapshot kept. So the words and
//! the marks it reports are read after the storage that produced them is gone.
//!
//! A preference this platform cannot observe is printed as its own absence,
//! never as a default. Linux has no native global menu, so that answer stays
//! unsupported and is not replaced by the bridge the same run exercises.
//!
//! The dialog half opens a real chooser on a person's screen, so it is off by
//! default too, and it refuses to start without BOTH its flag and an exact
//! copy of its scope text. It presents one noapi buffer in its owned parent,
//! parents the chooser to that window's native handle, and proves one of
//! three typed outcomes: `selected`, `cancelled` or `parent_closed`. Nobody
//! answers a chooser from inside this binary. For `parent_closed`, the
//! controller observes the live chooser, then requests a native window-manager
//! close of this process's own parent.
//!
//! Deliberately not run, because each needs an operator's approval: an external
//! URL launch, and the Secret Service credential store.
//!
//! Run it: `zig build w18-dialog-smoke` (add `-- --authorize-clipboard-mutation`
//! to include the clipboard half, `-- --native-observations` to read the desktop
//! this run is attached to, and
//! `-- --authorize-dialog-round-trip --dialog-scope "<exact text>" --dialog-case
//! selected|cancelled|parent-closed [--dialog-mode open|save]
//! [--dialog-target <absolute path>] [--dialog-wait-ms N]` for the chooser).
//!
//! `--dialog-mode save` asks the portal for its save chooser. The target then
//! names a file that must not exist: its folder has to exist to be offered, and
//! a destination this run created nothing at is the only one whose absence
//! after a cancelled save proves nothing was written.
//!
//! The clipboard half opens one owned window and takes through it. A take with
//! no window reports an empty clipboard whatever the session holds, and an arm
//! that trusts that answer writes over data it can never put back.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const c = sdl3.c;

const nogui = @import("nogui");
const host = @import("nogui_host");
const action = nogui.action;

const clipboard_host = host.clipboard;
const dialogs = host.dialogs;
const menus = host.menus;
const open_url = host.open_url;
const preferences = host.preferences;

/// The flag the parent passes to its own executable. The child runs with an
/// environment that names no session bus, which is the condition the
/// provider-unavailable path exists for.
const no_session_bus_flag = "--no-session-bus-probe";

/// The clipboard half overwrites a resource the user owns, so it never runs
/// without this flag.
const authorize_clipboard_flag = "--authorize-clipboard-mutation";

/// The observation half reads the display server this run is attached to, so
/// it never runs without this flag. Without it the run stays on the dummy
/// driver and reports the provider refusal alone.
const native_observations_flag = "--native-observations";

/// The dialog half opens a real chooser on the person's screen, so it never
/// runs without this flag.
const authorize_dialog_flag = "--authorize-dialog-round-trip";

/// Which dialog outcome this run proves. All three are answered from outside
/// this binary: `selected` and `cancelled` by a person in front of the real
/// chooser, and `parent_closed` by whoever closes this run's own parent
/// window while the chooser is live. Nothing here answers a chooser itself, so
/// every case needs an actor and no case runs unattended.
const DialogCase = enum { selected, cancelled, parent_closed };

/// Which chooser this run asks the portal for. Both go down the same request
/// path, so a mode the provider cannot serve has to report `unsupported` here
/// rather than silently answering as an open.
const DialogMode = enum { open, save };

const dialog_scope_flag = "--dialog-scope";
const dialog_case_flag = "--dialog-case";
const dialog_mode_flag = "--dialog-mode";
const dialog_target_flag = "--dialog-target";
const dialog_wait_flag = "--dialog-wait-ms";

/// The point-of-risk scope of the dialog half, byte for byte. An operator
/// approves this text; the arm refuses anything else, including a prefix.
const dialog_scope_text =
    "open one real file chooser on this desktop and answer it, so a selection, " ++
    "a cancellation and a parent close are each observed against a live owned window";

const min_dialog_wait_ms: u64 = 2_000;
const max_dialog_wait_ms: u64 = 600_000;
const default_dialog_wait_ms: u64 = 120_000;

/// The title of the window this run owns for the chooser to be parented to.
/// Its noapi-presented buffer maps the owned Wayland toplevel.
const dialog_parent_title = "w18 dialog smoke parent";

/// The title of the window this run owns for the clipboard take. It is opened
/// and closed inside the clipboard half, and it paints nothing.
const clipboard_parent_title = "w18 clipboard smoke parent";

const DialogOptions = struct {
    authorize: bool = false,
    scope: ?[]const u8 = null,
    case: DialogCase = .selected,
    mode: DialogMode = .open,
    target: ?[]const u8 = null,
    wait_ms: u64 = default_dialog_wait_ms,
};

/// The refusal path answers without a person, so a fixed number of short
/// pumps is enough: the answer is a bus lookup, not a dialog.
const probe_pump_limit: u32 = 200;

/// One text this run writes, so every value it reports back is its own bytes.
const clipboard_probe_text = "w18-clipboard-text";
const primary_probe_text = "w18-primary-text";
/// The JSON that travels with the text and the image, so a run that restores a
/// user clipboard restores all three formats as one item rather than as text.
const clipboard_probe_metadata = "{\"probe\":\"w18-clipboard\",\"version\":1}";

/// A 1x1 PNG this run owns end to end. The bytes are a constant in this file
/// and the round trip below compares against these same bytes, so nothing here
/// depends on a decoder: what is proven is that the display server carried the
/// image/png target through and handed the identical bytes back.
const synthetic_png = "\x89PNG\r\n\x1a\n" ++
    "\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0aIDATx\x9c\x63\x00\x01\x00\x00\x05\x00\x01\x0d\x0a\x2d\xb4" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

/// The one launch URL this process owns. Nothing registers its scheme with the
/// desktop and nothing opens it: the payload is ingress this run generated for
/// its own queue and its own dispatcher.
const synthetic_launch_url = "w18synthetic://observe?token=single";

/// The scheme this process registers in its own dispatcher. It is a private
/// name: no OS handler, no portal registration, no MIME type.
const synthetic_scheme = "w18synthetic";

/// The actions the menu phase runs. They exist only in this process's own
/// registry, and each reported outcome is the model's own counter rather than
/// the type name a call returned. The Quit row is a native system action, and
/// it reaches this model because it registered the name that action derives.
const ObserveAction = action.Action(u32, "w18.synthetic.observe");
const DisabledAction = action.Action(void, "w18.synthetic.disabled");
const QuitAction = action.Action(void, menus.SystemAction.quit.actionName());

/// The owner the synthetic menu tree is assembled under. It is this run's own
/// number, not an identity any real App minted.
const synthetic_owner: u64 = 0x5718;

/// The payload the observed action decodes to. The JSON text handed to the
/// menu item is formatted from this number, so the two cannot disagree.
const observed_value: u32 = 41;

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = [_]u8{0} ** 4096,

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// An error union reports its error; a delivered success reports as itself.
fn outcomeText(comptime T: type, result: anyerror!T) []const u8 {
    if (result) |_| return "<accepted>" else |err| return @errorName(err);
}

fn outcomeTag(outcome: ?dialogs.FileOutcome) []const u8 {
    const value = outcome orelse return "<none>";
    return switch (value) {
        .selected => "selected",
        .cancelled => "cancelled",
        .aborted => "aborted",
        .empty_selection => "empty_selection",
        .parent_closed => "parent_closed",
        .unsupported => "unsupported",
        .failed => |failure| @tagName(failure),
    };
}

/// Receives the one outcome the manager delivers and owns it afterwards.
const Receiver = struct {
    calls: usize = 0,
    outcome: ?dialogs.FileOutcome = null,

    fn onResult(ctx: ?*anyopaque, outcome: dialogs.FileOutcome) void {
        const self: *Receiver = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.outcome) |*previous| dialogs.deinitFileOutcome(previous);
        self.outcome = outcome;
    }

    fn deinit(self: *Receiver) void {
        if (self.outcome) |*outcome| dialogs.deinitFileOutcome(outcome);
        self.* = undefined;
    }
};

/// This fixture owns one worker and drains its SDL completion before releasing
/// the callback receiver, SDL or the allocator.
const ThreadWorker = struct {
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),

    fn run(
        context: *anyopaque,
        work: *const fn (*anyopaque) void,
        payload: *anyopaque,
    ) anyerror!void {
        const self: *ThreadWorker = @ptrCast(@alignCast(context));
        if (self.thread != null) return error.WorkerBusy;
        self.finished.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, trampoline, .{ self, work, payload });
    }

    fn trampoline(
        self: *ThreadWorker,
        work: *const fn (*anyopaque) void,
        payload: *anyopaque,
    ) void {
        work(payload);
        self.finished.store(true, .release);
    }

    fn finish(self: *ThreadWorker, io: Io) !void {
        const thread = self.thread orelse return;
        const deadline = nowNs(io) + 10 * std.time.ns_per_s;
        while (!self.finished.load(.acquire)) {
            // Application.step stops polling after the last window closes.
            // SDL must still dispatch the canceled worker's main-thread post.
            sdl3.events.pump();
            if (nowNs(io) >= deadline) return error.DialogWorkerTeardownTimeout;
            try Io.sleep(io, Io.Duration.fromMilliseconds(8), .real);
        }
        thread.join();
        self.thread = null;
        sdl3.events.pump();
    }

    fn worker(self: *ThreadWorker) dialogs.Worker {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: dialogs.Worker.VTable = .{ .run = run };
};

/// Run the host loop for a bounded number of rounds. A clipboard read taken
/// under a running loop is not the same observation as one taken right after
/// the write.
fn pump(io: Io, application: *host.Application, rounds: u32) !void {
    var settled: u32 = 0;
    while (settled < rounds) : (settled += 1) {
        _ = try application.step();
        try Io.sleep(io, Io.Duration.fromMilliseconds(8), .real);
    }
}

/// Report what the display server actually returned, and refuse to call the
/// round trip proven when it returned something else.
fn expectText(
    gpa: std.mem.Allocator,
    report: *Reporter,
    label: []const u8,
    observed: ?[]u8,
    expected: []const u8,
) !void {
    defer if (observed) |bytes| gpa.free(bytes);
    // The reported type is named here, so the absent case needs no peer type
    // resolution at a call site.
    const text: []const u8 = observed orelse "<absent>";
    const matches = if (observed) |bytes| std.mem.eql(u8, bytes, expected) else false;
    try report.emit(
        "{s}: observed=\"{s}\" expected=\"{s}\" match={}\n",
        .{ label, text, expected, matches },
    );
    if (!matches) return error.ClipboardRoundTripMismatch;
}

/// The same comparison for a format whose payload is bytes rather than text:
/// lengths on both sides and one equality result, so a truncated or re-encoded
/// payload cannot be reported as a match. The slice is borrowed, so the caller
/// owns whatever it passes and keeps that lifetime correct.
fn expectBytes(
    report: *Reporter,
    label: []const u8,
    observed: []const u8,
    expected: []const u8,
) !void {
    const matches = std.mem.eql(u8, observed, expected);
    try report.emit(
        "{s}: observed_len={d} expected_len={d} match={}\n",
        .{ label, observed.len, expected.len, matches },
    );
    if (!matches) return error.ClipboardRoundTripMismatch;
}

/// The clipboard half, authorized by the caller's flag, against this
/// session's real display server.
///
/// The whole item is taken before anything is written, because a clipboard
/// this build cannot represent cannot be put back. A clipboard that reports
/// text it will not hand over is refused, not overwritten, and so is one this
/// build has no type for or cannot read whole: each is reported by name.
fn clipboardRoundTrip(
    gpa: std.mem.Allocator,
    io: Io,
    application: *host.Application,
    report: *Reporter,
) !void {
    const clipboard = &application.clipboard;
    const driver = sdl3.video.getCurrentDriverName() orelse "<null>";
    try report.emit("video driver: {s}\n", .{driver});
    try report.emit("clipboard mutation: authorized by {s}\n", .{authorize_clipboard_flag});

    // The take below only means something through a window this process owns.
    // SDL reads a platform selection through a window's own connection: X11
    // answers a TARGETS request only for a client with a window, and Wayland
    // answers a data offer only for a surface. With no window the take reports
    // an empty clipboard whatever the session holds, so the write that follows
    // is unrecoverable and the restore below has nothing to put back. This run
    // therefore opens one owned window, takes through it, and closes it again.
    const handle = try application.openWindow(.{
        .title = clipboard_parent_title,
        .width = 160,
        .height = 90,
        .resizable = false,
        .visible = true,
    });
    var window_live = true;
    defer if (window_live) {
        _ = application.closeWindow(handle) catch |err| {
            report.emit("clipboard: teardown close of the owned window: {s}\n", .{
                @errorName(err),
            }) catch @panic("W18 dialog smoke could not report the teardown close failure");
        };
    };
    try pump(io, application, 2);
    try report.emit("clipboard: an owned window is open, so the take below is a real read\n", .{});
    // A Wayland selection is delivered only to a focused surface, so the take
    // is made under the focus this window asks for rather than under whatever
    // focus it happened to inherit. A compositor that ignores the request still
    // gives an honest answer below, and this run reports what it got.
    const owned_window = application.getWindow(handle) catch |err| {
        try report.emit("clipboard: the owned window went stale before the take: {s}\n", .{
            @errorName(err),
        });
        return err;
    };
    owned_window.requestFocus() catch |err| {
        try report.emit("clipboard: the owned window could not ask for focus: {s}\n", .{
            @errorName(err),
        });
    };
    try pump(io, application, 8);

    // A clipboard holding a format this build cannot represent, or nothing it
    // recognizes at all, is refused here rather than taken as a shortened
    // item. The two refusals are reported by name because they are two facts:
    // one is a clipboard this run cannot carry whole, the other is a clipboard
    // it has no type for. Neither may be overwritten and restored as
    // something else.
    var saved: ?clipboard_host.Item = clipboard.readItem(gpa) catch |err| switch (err) {
        error.UnreadableClipboardFormat, error.UnrecognizedClipboardContent => {
            try report.emit(
                "clipboard mutation: refused, the current clipboard is {s}\n",
                .{@errorName(err)},
            );
            return error.ClipboardNotRestorable;
        },
        else => return err,
    };
    // The taken item is released on every path, so an error between the take
    // and the restore cannot leak it.
    defer if (saved) |*item| item.deinit();
    // Nothing SDL lists is a type this build knows, and it still reports text.
    // A clipboard whose text cannot be taken cannot be put back, so it stays
    // untouched.
    if (saved == null and clipboard.hasText()) {
        try report.emit("clipboard mutation: refused, the current clipboard cannot be read back\n", .{});
        return error.ClipboardNotRestorable;
    }
    const saved_primary = try clipboard.getPrimary(gpa);
    defer if (saved_primary) |bytes| gpa.free(bytes);
    try report.emit(
        "clipboard before: item={s} primary_len={d}\n",
        .{ if (saved != null) "<owned>" else "<absent>", if (saved_primary) |text| text.len else 0 },
    );

    // From here on the run owns the clipboard and must put it back.
    var restored = false;
    defer if (!restored) {
        report.emit("clipboard restore: skipped after an error\n", .{}) catch
            @panic("W18 dialog smoke could not report the skipped restore");
    };

    try clipboard.setText(clipboard_probe_text);
    try pump(io, application, 2);
    try report.emit("setText: hasText={}\n", .{clipboard.hasText()});
    try expectText(gpa, report, "readText", try clipboard.read(gpa, .text_utf8), clipboard_probe_text);

    // One item carrying all three typed formats, so the image and the metadata
    // travel through the same server and the same offer as the text rather than
    // beside it. Each format is read back on its own and again as one item, so
    // a provider that carried the bytes but dropped a target is visible.
    var item = try clipboard_host.Item.init(gpa, &.{
        .{ .format = .text_utf8, .bytes = clipboard_probe_text },
        .{ .format = .image_png, .bytes = synthetic_png },
        .{ .format = .metadata_json, .bytes = clipboard_probe_metadata },
    });
    defer item.deinit();
    try clipboard.set(&item);
    try pump(io, application, 2);
    try report.emit(
        "typed item: offered formats={d} text={} image_png={} metadata_json={}\n",
        .{
            item.count(),
            item.has(.text_utf8),
            item.has(.image_png),
            item.has(.metadata_json),
        },
    );

    const png_bytes = (try clipboard.read(gpa, .image_png)) orelse
        return error.ImageTargetAbsentAfterWrite;
    defer gpa.free(png_bytes);
    try expectBytes(report, "image_png", png_bytes, synthetic_png);

    const json_bytes = (try clipboard.read(gpa, .metadata_json)) orelse
        return error.MetadataTargetAbsentAfterWrite;
    defer gpa.free(json_bytes);
    try expectBytes(report, "metadata_json", json_bytes, clipboard_probe_metadata);

    // Every target above was served, so this answers the whole item. A
    // provider that dropped one refuses here by name now, instead of answering
    // an item quietly missing a target, and the checks below name a target that
    // is still absent.
    const read_back = (try clipboard.readItem(gpa)) orelse
        return error.TypedItemAbsentAfterWrite;
    var read_item = read_back;
    defer read_item.deinit();
    try report.emit(
        "readItem: formats={d} text={} image_png={} metadata_json={}\n",
        .{
            read_item.count(),
            read_item.has(.text_utf8),
            read_item.has(.image_png),
            read_item.has(.metadata_json),
        },
    );
    if (!read_item.has(.image_png)) return error.ImageFormatMissingFromTheItem;
    if (!read_item.has(.metadata_json)) return error.MetadataFormatMissingFromTheItem;
    try expectBytes(report, "readItem image_png", read_item.imagePng().?, synthetic_png);
    try expectBytes(
        report,
        "readItem metadata_json",
        read_item.metadataJson().?,
        clipboard_probe_metadata,
    );

    try report.emit("primary selection supported: {}\n", .{clipboard.supportsPrimary()});
    if (clipboard.supportsPrimary()) {
        try clipboard.setPrimary(primary_probe_text);
        try pump(io, application, 2);
        try expectText(gpa, report, "getPrimary", try clipboard.getPrimary(gpa), primary_probe_text);

        // This clear proves the clear path, and it also drops the session's own
        // primary for as long as this run holds the selection. It therefore
        // runs only when this run took that primary and can put it back. A
        // clear of a primary this run never took was measured here destroying
        // the selection its owner still held, so it is not run blind.
        if (saved_primary != null) {
            try clipboard.clearPrimarySelection();
            try pump(io, application, 2);
            try report.emit("after clear: hasPrimaryText={}\n", .{clipboard_host.hasPrimaryText()});
            const after = try clipboard.getPrimary(gpa);
            defer if (after) |bytes| gpa.free(bytes);
            const cleared: []const u8 = after orelse "<absent>";
            try report.emit("after clear: observed=\"{s}\"\n", .{cleared});
            if (after) |bytes| {
                if (bytes.len != 0) return error.PrimarySelectionNotCleared;
            }
        } else {
            try report.emit(
                "after clear: skipped, this run took no primary to put back, and clearing" ++
                    " one it never took destroys the session's own\n",
                .{},
            );
        }
    } else {
        try report.emit("primary selection: skipped, this driver has none\n", .{});
    }

    // Put the user's own clipboard back, as the whole item it was taken as.
    //
    // Nothing this run did not take is ever cleared. A clear here looks
    // harmless and is not: writing already gave this run clipboard ownership,
    // so on X11 a clear drops the last owner and the session's previous owner
    // never gets its selection back. That was measured here rather than
    // assumed, so the branch that finds nothing to put back leaves the probe in
    // place, says exactly what it left, and fails the run rather than reporting
    // a restore it did not perform.
    var put_item_back = false;
    if (saved) |*saved_item| {
        try clipboard.set(saved_item);
        saved_item.deinit();
        saved = null;
        put_item_back = true;
    }
    var put_primary_back = false;
    if (saved_primary) |text| {
        try clipboard.setPrimary(text);
        put_primary_back = true;
    }
    try pump(io, application, 2);
    restored = true;
    try report.emit("clipboard restore: item={s}\n", .{
        if (put_item_back)
            "the whole item this run took was put back"
        else
            "nothing was taken, so nothing was put back and nothing was cleared",
    });
    try report.emit("clipboard restore: primary={s}\n", .{
        if (put_primary_back)
            "the primary text this run took was put back"
        else
            "nothing was taken, so nothing was put back and nothing was cleared",
    });
    var left_behind = false;
    if (!put_item_back) {
        left_behind = true;
        try report.emit(
            "clipboard restore: WARNING this run's own text \"{s}\" is on the clipboard" ++
                " now, and this run leaves it there on purpose: a clear would destroy" ++
                " whatever the session held and this run never took that\n",
            .{clipboard_probe_text},
        );
    }
    if (!put_primary_back and clipboard.supportsPrimary()) {
        left_behind = true;
        try report.emit(
            "clipboard restore: WARNING this run's own text \"{s}\" is on the primary" ++
                " selection now, left there for the same reason\n",
            .{primary_probe_text},
        );
    }
    if (application.closeWindow(handle)) |_| {
        window_live = false;
    } else |err| {
        report.emit("clipboard: close of the owned window: {s}\n", .{@errorName(err)}) catch
            @panic("W18 dialog smoke could not report the owned window close failure");
    }
    if (left_behind) return error.ClipboardWasNotTakenBeforeMutation;
}

/// The file-dialog half, run in a child process of this same binary whose
/// environment names no session bus. The real adapter refuses before it
/// reaches the bus, so the run proves that an absent portal reports
/// `unsupported` and not a cancellation or an empty list.
fn noSessionBusProbe(gpa: std.mem.Allocator, io: Io, report: *Reporter) !void {
    const bus = host.portal.isSessionBusAvailable();
    try report.emit("no-session-bus probe: session_bus_available={}\n", .{bus});
    if (bus) {
        // A bus means a real file chooser would open. This probe holds no
        // approval for a person-facing dialog, so it refuses instead.
        try report.emit("no-session-bus probe: skipped, a session bus is present\n", .{});
        return error.SessionBusPresent;
    }

    // The provider posts its outcome through the SDL main-thread queue, so
    // the event subsystem has to be up and pumping for it to arrive. The
    // dummy video driver needs no display server and touches no clipboard.
    try sdl3.init(.{ .video = true });
    defer sdl3.quit(.{});
    try report.emit("no-session-bus probe: video driver {s}\n", .{
        sdl3.video.getCurrentDriverName() orelse "<null>",
    });

    var worker: ThreadWorker = .{};
    defer worker.finish(io) catch @panic("W18 unavailable probe left its worker live");
    var manager = dialogs.DialogManager.init(gpa);
    defer manager.deinit();
    manager.setProvider(dialogs.portalFileProvider());
    manager.setWorker(worker.worker());

    var receiver: Receiver = .{};
    defer receiver.deinit();

    // The approval covers a request that provably cannot open a dialog: the
    // process environment names no session bus, which was just reported.
    try manager.showFile(
        .{ .mode = .open_file, .title = "w18 dialog smoke" },
        .{ .confirmed = true },
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    try report.emit("no-session-bus probe: launched pending={d}\n", .{manager.pendingCount()});

    var rounds: u32 = 0;
    while (receiver.calls == 0 and rounds < probe_pump_limit) : (rounds += 1) {
        sdl3.events.pump();
        try Io.sleep(io, Io.Duration.fromMilliseconds(5), .real);
    }

    const tag = outcomeTag(receiver.outcome);
    try report.emit(
        "no-session-bus probe: outcome={s} pending={d} rounds={d}\n",
        .{ tag, manager.pendingCount(), rounds },
    );
    if (!std.mem.eql(u8, tag, "unsupported")) return error.ProviderUnavailableNotObserved;
    try report.emit(
        "no-session-bus probe: verdict: an absent portal reports unsupported\n",
        .{},
    );
}

/// Start this binary again with an environment that names no session bus and
/// no display server.
fn noSessionBusChild(gpa: std.mem.Allocator, io: Io, report: *Reporter) !void {
    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    // The binary carries its own RUNPATH, so the child needs no inherited
    // environment: it loads its libraries without any variable set here. The
    // dummy driver is what keeps the child off any display server.
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put("SDL_VIDEODRIVER", "dummy");

    // The argv element type is named, so the sentinel and the literal both
    // coerce where the spawn call reads them.
    const argv: [2][]const u8 = .{ executable, no_session_bus_flag };
    try report.emit("no-session-bus child: begin\n", .{});
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = &environ,
        .stdin = .ignore,
    });
    const term = try child.wait(io);
    try report.emit("no-session-bus child: end {any}\n", .{term});
    switch (term) {
        .exited => |code| if (code != 0) return error.ProviderUnavailableProbeFailed,
        else => return error.ProviderUnavailableProbeFailed,
    }
}

/// A preference this platform cannot observe is reported as its own absence.
/// A null is a limit of this platform, not a default value.
fn optionalBool(value: ?bool) []const u8 {
    const present = value orelse return "<null>";
    return if (present) "true" else "false";
}

fn optionalEnum(comptime T: type, value: ?T) []const u8 {
    const present = value orelse return "<null>";
    return @tagName(present);
}

/// One word for what a target can and cannot do, so a reader is never handed
/// a boolean and left to translate it.
fn supportText(supported: bool) []const u8 {
    return if (supported) "available" else "unsupported on this target";
}

/// The layout names its own buttons; an empty side says so instead of
/// printing nothing between two brackets.
fn buttonList(scratch: []u8, buttons: []const preferences.TitlebarButton) []const u8 {
    if (buttons.len == 0) return "<empty>";
    var written: usize = 0;
    for (buttons, 0..) |button, index| {
        const separator: []const u8 = if (index == 0) "" else ",";
        const tail = std.fmt.bufPrint(scratch[written..], "{s}{s}", .{
            separator,
            @tagName(button),
        }) catch return "<too long>";
        written += tail.len;
    }
    return scratch[0..written];
}

/// The type the module derives from the driver SDL names. It is computed here
/// from SDL's own answer, so the two can disagree instead of echoing.
fn driverCompositor(driver: []const u8) ?preferences.CompositorType {
    if (std.mem.eql(u8, driver, "x11")) return .x11;
    if (std.mem.eql(u8, driver, "wayland")) return .wayland;
    if (std.mem.eql(u8, driver, "dummy")) return .dummy;
    return null;
}

/// A user folder is checked against the file system, not against the
/// environment variable the lookup itself read.
fn folderProbe(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    label: []const u8,
    folder: preferences.SystemFolder,
) !void {
    const path = try preferences.getUserFolder(gpa, folder) orelse {
        try report.emit("native: folder {s}: <null>\n", .{label});
        return;
    };
    defer gpa.free(path);
    const kind: []const u8 = if (std.Io.Dir.cwd().statFile(io, path, .{})) |status|
        @tagName(status.kind)
    else |_|
        "<unstatable>";
    try report.emit("native: folder {s}: \"{s}\" absolute={} is_{s}\n", .{
        label,
        path,
        std.fs.path.isAbsolute(path),
        kind,
    });
}

/// The P10 half. Every preference this run can reach is read and printed as
/// its own answer, and each answer a platform can disagree with is compared
/// against an independent source instead of being printed beside one.
fn preferencesPhase(gpa: std.mem.Allocator, io: Io, report: *Reporter) !void {
    const driver_name = sdl3.video.getCurrentDriverName() orelse "<null>";
    try report.emit("native: video driver: {s}\n", .{driver_name});

    const compositor = preferences.getCompositorInfo();
    try report.emit(
        "native: compositor: type={s} name={s} vrr_supported={s} direct_scanout={s}\n",
        .{
            @tagName(compositor.compositor_type),
            compositor.name orelse "<null>",
            optionalBool(compositor.vrr_supported),
            optionalBool(compositor.direct_scanout),
        },
    );
    if (driverCompositor(driver_name)) |expected| {
        if (compositor.compositor_type != expected) return error.CompositorTypeDisagreesWithDriver;
        try report.emit("native: compositor: the type agrees with the driver SDL reports\n", .{});
    }

    // SDL answers the theme for itself, so the wrapper is checked against the
    // raw value rather than only reported next to it.
    const raw_theme = c.SDL_GetSystemTheme();
    const raw_name: []const u8 = switch (raw_theme) {
        c.SDL_SYSTEM_THEME_LIGHT => "light",
        c.SDL_SYSTEM_THEME_DARK => "dark",
        else => "unknown",
    };
    const theme = preferences.getSystemTheme();
    try report.emit("native: system theme: {s} (SDL raw theme: {s})\n", .{
        optionalEnum(preferences.SystemTheme, theme),
        raw_name,
    });
    switch (raw_theme) {
        c.SDL_SYSTEM_THEME_LIGHT => if (theme != .light) return error.ThemeDisagreesWithSdl,
        c.SDL_SYSTEM_THEME_DARK => if (theme != .dark) return error.ThemeDisagreesWithSdl,
        else => {},
    }

    if (preferences.getTitlebarButtonLayout(gpa)) |layout| {
        // The layout owns its arena, so the copy this capture holds is the one
        // that has to be released.
        var owned = layout;
        defer owned.deinit();
        var left: [128]u8 = undefined;
        var right: [128]u8 = undefined;
        try report.emit("native: titlebar buttons: left=[{s}] right=[{s}]\n", .{
            buttonList(&left, owned.left),
            buttonList(&right, owned.right),
        });
    } else {
        try report.emit("native: titlebar buttons: <null, this platform observes none>\n", .{});
    }

    const scrollbar = preferences.getScrollbarPreferences();
    try report.emit("native: scrollbar: jump_to_click={s} auto_hide={s}\n", .{
        optionalBool(scrollbar.jump_to_click),
        optionalBool(scrollbar.auto_hide),
    });
    try report.emit("native: thermal: {s}\n", .{
        optionalEnum(preferences.ThermalState, preferences.getThermalState()),
    });
    // This one is this process's own configuration. It is not a desktop signal
    // and is not reported as one.
    try report.emit("native: reduced motion override: {s} (application state, not an OS signal)\n", .{
        optionalEnum(preferences.MotionPreference, preferences.getReducedMotion()),
    });

    try folderProbe(gpa, io, report, "config", .config);
    try folderProbe(gpa, io, report, "data", .data);
    try folderProbe(gpa, io, report, "cache", .cache);
    try folderProbe(gpa, io, report, "temp", .temp);

    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);
    const exe_dir = std.fs.path.dirname(executable) orelse "";
    if (try preferences.getBasePath(gpa)) |base| {
        defer gpa.free(base);
        // SDL answers from the running image and the kernel answers from
        // /proc/self/exe, so the two directories are compared rather than
        // printed side by side. Linux is the one target with a single answer
        // to compare, so only there a disagreement fails the run.
        const agrees = std.mem.eql(u8, std.mem.trimEnd(u8, base, "/"), exe_dir);
        try report.emit("native: base path: \"{s}\" agrees_with_executable_directory={}\n", .{
            base,
            agrees,
        });
        if (!agrees and builtin.os.tag == .linux) return error.BasePathDisagreesWithExecutable;
    } else {
        try report.emit("native: base path: <null>\n", .{});
    }

    // The running binary's own name is the one auxiliary that must resolve
    // beside the base path, so the lookup is compared with the directory the
    // kernel just named.
    const exe_name = std.fs.path.basename(executable);
    if (try preferences.findAuxiliaryExecutable(gpa, io, exe_name)) |found| {
        defer gpa.free(found);
        const expected = try std.fs.path.join(gpa, &[_][]const u8{ exe_dir, exe_name });
        defer gpa.free(expected);
        const adjacent = std.mem.eql(u8, found, expected);
        const is_file = if (std.Io.Dir.cwd().statFile(io, found, .{})) |status|
            status.kind == .file
        else |_|
            false;
        try report.emit("native: auxiliary \"{s}\": \"{s}\" adjacent_to_binary={} is_file={}\n", .{
            exe_name,
            found,
            adjacent,
            is_file,
        });
        if (!adjacent or !is_file) return error.AuxiliaryLookupDisagreesWithExecutable;
    } else {
        try report.emit("native: auxiliary \"{s}\": <null, beside no base path and on no PATH>\n", .{exe_name});
    }

    const absent = "w18-auxiliary-absent-probe";
    if (try preferences.findAuxiliaryExecutable(gpa, io, absent)) |found| {
        defer gpa.free(found);
        try report.emit("native: auxiliary probe \"{s}\": found \"{s}\"\n", .{ absent, found });
    } else {
        try report.emit("native: auxiliary probe \"{s}\": <null>\n", .{absent});
    }

    // A native gesture provider is an open half of P15 and has no host service
    // on any desktop target, so the gap is named instead of filled with a
    // second opinion.
    try report.emit("native: gesture provider: no public host service exists, so nothing was read\n", .{});
    try report.emit("native: preferences: every answer above is this session's own reading\n", .{});
}

/// What this process's own model counts when an action reaches it, and what
/// the menu reads back for a tick mark. Only the model decides the mark; the
/// bridge has no field of its own to answer from.
const MenuModel = struct {
    invoked: u32 = 0,
    last_value: u32 = 0,
    tick: bool = false,
    /// Where a released model's handler would write, so this run can still
    /// read the counter after the model that owned it is gone.
    sink: ?*u32 = null,

    fn observe(self: *MenuModel, value: *const u32, _: *nogui.Session) anyerror!void {
        self.count(1);
        self.last_value = value.*;
    }

    fn never(self: *MenuModel, _: *const void, _: *nogui.Session) anyerror!void {
        self.count(1);
    }

    fn quit(self: *MenuModel, _: *const void, _: *nogui.Session) anyerror!void {
        self.count(1);
    }

    fn count(self: *MenuModel, times: u32) void {
        self.invoked += times;
        if (self.sink) |target| target.* += times;
    }

    fn available(_: *const MenuModel, _: *nogui.Session) action.Availability {
        return .available;
    }

    fn disabled(_: *const MenuModel, _: *nogui.Session) action.Availability {
        return .disabled;
    }

    fn marked(self: *const MenuModel, _: *nogui.Session) bool {
        return self.tick;
    }

    fn capture(self: *const MenuModel, out: *MenuModel) !void {
        out.* = self.*;
    }
};

/// One frame's menu text, formatted from this process's own model state into a
/// single buffer this run owns.
///
/// A host that rebuilds its bar every frame writes its titles, labels and
/// payloads into scratch storage exactly like this, and a snapshot that
/// borrowed them would report the next frame's words — or freed bytes — for
/// this frame's rows.
const MenuText = struct {
    buffer: []u8,
    title: []const u8,
    observe_label: []const u8,
    disabled_label: []const u8,
    quit_label: []const u8,
    shortcut: []const u8,
    payload: []const u8,

    fn format(gpa: std.mem.Allocator, model: *const MenuModel) !MenuText {
        // The model's own mark is the state these words report, so a bar built
        // from them cannot claim a state the model does not hold.
        const marked: u1 = @intFromBool(model.tick);
        const buffer = try gpa.alloc(u8, 192);
        errdefer gpa.free(buffer);
        return .{
            .buffer = buffer,
            .title = try std.fmt.bufPrint(buffer[0..24], "W18 state {d}", .{marked}),
            .observe_label = try std.fmt.bufPrint(buffer[24..64], "Observe mark={d}", .{marked}),
            .disabled_label = try std.fmt.bufPrint(buffer[64..104], "Not now mark={d}", .{marked}),
            .quit_label = try std.fmt.bufPrint(buffer[104..144], "Quit mark={d}", .{marked}),
            .shortcut = try std.fmt.bufPrint(buffer[144..176], "Ctrl+Alt+{c}", .{@as(u8, 'O')}),
            .payload = try std.fmt.bufPrint(buffer[176..192], "{d}", .{observed_value}),
        };
    }

    fn deinit(self: *MenuText, gpa: std.mem.Allocator) void {
        gpa.free(self.buffer);
        self.* = undefined;
    }
};

/// The model row a snapshot row carries, rebuilt from that row alone.
///
/// What this run dispatches from the snapshots it still holds. Both of them
/// stay alive for the rest of the phase and the buffer the bar was formatted in
/// is released first, so every click below is routed from bytes the snapshot
/// owns rather than from the bar this run assembled. Only a command row is
/// rebuilt this way; a submenu header's children belong to the snapshot and do
/// not come back as model rows.
fn retainedRow(item: menus.EvaluatedItem) menus.MenuItem {
    return .{
        .id = item.id,
        .label = item.label,
        .kind = item.kind,
        .action_name = item.action_name,
        .action_payload_json = item.action_payload_json,
        .system_action = item.system_action,
        .shortcut_label = item.shortcut_label,
    };
}

/// The menu half. Nothing here is a native global menu: on this target that
/// does not exist, and an in-app bar is not a substitute for it. What runs is
/// the public bridge over a tree and a registry this process owns, and every
/// reported outcome is a model counter the bridge cannot write itself.
/// Its bar text is formatted from that same model, so the titles and labels
/// move with the state, and the buffer holding them is released before the
/// first click: every row below is read from a snapshot that owns its bytes.
fn menuPhase(gpa: std.mem.Allocator, session: *nogui.Session, report: *Reporter) !void {
    try report.emit("native: menu: native_global_menu={s} dock_menu={s}\n", .{
        supportText(menus.hasNativeGlobalMenu()),
        supportText(menus.hasDockMenuSupport()),
    });
    try report.emit(
        "native: menu: the items below ran through the public bridge on this" ++
            " process's own tree; their titles and labels are this run's own" ++
            " model state, formatted into one buffer that is released again" ++
            " before the first click. No native menu was shown\n",
        .{},
    );

    var retired_calls: u32 = 0;
    var observed_initial: MenuModel = .{};
    var observed_handle = try session.create(MenuModel, &observed_initial);
    defer session.release(MenuModel, &observed_handle) catch
        @panic("W18 menu phase left the observed model live");
    // The disabled row claims a mark while it refuses to run: a greyed-out
    // row keeps the state its model reports.
    var disabled_initial: MenuModel = .{ .tick = true };
    var disabled_handle = try session.create(MenuModel, &disabled_initial);
    defer session.release(MenuModel, &disabled_handle) catch
        @panic("W18 menu phase left the disabled model live");
    // This model claims a mark too, and is released before the bar is read.
    var retired_initial: MenuModel = .{ .tick = true, .sink = &retired_calls };
    var retired_handle = try session.create(MenuModel, &retired_initial);

    // The Quit row dispatches under the name the host derives from the
    // ordinal, so this run owns a model behind that row instead of a handler
    // the bridge called on its own.
    var quit_initial: MenuModel = .{};
    var quit_handle = try session.create(MenuModel, &quit_initial);
    defer session.release(MenuModel, &quit_handle) catch
        @panic("W18 menu phase left the quit model live");

    var registry = try action.Registry.init(gpa, session);
    defer registry.deinit();
    try registry.register(ObserveAction);
    try registry.register(DisabledAction);
    try registry.register(QuitAction);

    // Two identities in one tree. The bindings live on the first one, so the
    // focused context decides whether an item is enabled.
    const focus_id: nogui.WidgetId = .{ .owner = synthetic_owner, .slot = 1, .generation = 1 };
    const other_id: nogui.WidgetId = .{ .owner = synthetic_owner, .slot = 2, .generation = 1 };
    var tree = nogui.WidgetTree.init(gpa);
    defer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = focus_id,
        .parent = .root,
        .kind = .{ .label = .{ .text = "focus" } },
    });
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(2),
        .widget_id = other_id,
        .parent = .root,
        .kind = .{ .label = .{ .text = "other" } },
    });

    const observe_token = try registry.bind(
        ObserveAction,
        MenuModel,
        MenuModel.observe,
        MenuModel.available,
        .{ .widget = focus_id },
        observed_handle.weak(),
    );
    try registry.bindCheck(MenuModel, MenuModel.marked, observe_token);
    const disabled_token = try registry.bind(
        DisabledAction,
        MenuModel,
        MenuModel.never,
        MenuModel.disabled,
        .{ .widget = focus_id },
        disabled_handle.weak(),
    );
    try registry.bindCheck(MenuModel, MenuModel.marked, disabled_token);
    const quit_token = try registry.bind(
        QuitAction,
        MenuModel,
        MenuModel.quit,
        MenuModel.available,
        .{ .widget = focus_id },
        quit_handle.weak(),
    );
    try registry.bindCheck(MenuModel, MenuModel.marked, quit_token);
    // The same action one scope over, owned by a model this run releases now.
    const retired_token = try registry.bind(
        ObserveAction,
        MenuModel,
        MenuModel.observe,
        MenuModel.available,
        .{ .widget = other_id },
        retired_handle.weak(),
    );
    try registry.bindCheck(MenuModel, MenuModel.marked, retired_token);
    try session.release(MenuModel, &retired_handle);

    // The bar's words come from this run's own model, formatted into a single
    // buffer that is released again further down.
    // SAFETY: the first read of this comes from the `session.read` that
    // follows, whose `capture` callback assigns every field.
    var frame_one_model: MenuModel = undefined;
    try session.read(MenuModel, observed_handle, &frame_one_model, MenuModel.capture);
    var frame_one = try MenuText.format(gpa, &frame_one_model);
    const items = [_]menus.MenuItem{
        .{
            .id = 1,
            .label = frame_one.observe_label,
            .kind = .action,
            .action_name = ObserveAction.name,
            .action_payload_json = frame_one.payload,
            .shortcut_label = frame_one.shortcut,
        },
        .{
            .id = 2,
            .label = frame_one.disabled_label,
            .kind = .action,
            .action_name = DisabledAction.name,
        },
        .{
            .id = 3,
            .label = frame_one.quit_label,
            .kind = .system_action,
            .system_action = .quit,
        },
    };
    const declared = [_]menus.Menu{.{ .title = frame_one.title, .items = &items }};
    const menu_bar: menus.MenuBar = .{ .menus = &declared };

    var bridge = menus.MenuActionBridge.init(&registry);
    var focused = try bridge.evaluate(gpa, menu_bar, &tree, focus_id);
    defer focused.deinit();
    var unfocused = try bridge.evaluate(gpa, menu_bar, &tree, other_id);
    defer unfocused.deinit();
    try report.emit(
        "native: menu: each pair below is enabled/checked, read through the" ++
            " registry from the focused context\n" ++
            "native: menu: focused=[observe={}/{} not_now={}/{} quit={}/{}]" ++
            " other=[observe={}/{} not_now={}/{} quit={}/{}]\n",
        .{
            focused.menus[0].items[0].enabled,
            focused.menus[0].items[0].checked,
            focused.menus[0].items[1].enabled,
            focused.menus[0].items[1].checked,
            focused.menus[0].items[2].enabled,
            focused.menus[0].items[2].checked,
            unfocused.menus[0].items[0].enabled,
            unfocused.menus[0].items[0].checked,
            unfocused.menus[0].items[1].enabled,
            unfocused.menus[0].items[1].checked,
            unfocused.menus[0].items[2].enabled,
            unfocused.menus[0].items[2].checked,
        },
    );
    if (!focused.menus[0].items[0].enabled) return error.FocusedItemNotEnabled;
    if (focused.menus[0].items[0].checked) return error.UnmarkedItemWasMarked;
    if (focused.menus[0].items[1].enabled) return error.DisabledItemEnabled;
    if (!focused.menus[0].items[1].checked) return error.DisabledItemLostItsMark;
    if (focused.menus[0].items[2].checked) return error.SystemActionWasMarked;
    if (unfocused.menus[0].items[0].enabled) return error.UnfocusedItemEnabled;
    // The other context's owner was released, so the mark it claimed went with
    // it rather than lingering in the bar.
    if (unfocused.menus[0].items[0].checked) return error.RetiredOwnerKeptItsMark;
    if (unfocused.menus[0].items[1].checked) return error.UnfocusedItemWasMarked;

    // The words are read back here too, not only the states. A snapshot that
    // borrowed them would show whatever the next frame wrote into that same
    // buffer; one that owns them shows the frame it was evaluated for.
    try report.emit(
        "native: menu: the words of that bar, every one of them formatted from" ++
            " this run's own model: title=\"{s}\" observe=\"{s}\"" ++
            " not_now=\"{s}\" quit=\"{s}\" shortcut=\"{s}\"\n",
        .{
            focused.menus[0].title,
            focused.menus[0].items[0].label,
            focused.menus[0].items[1].label,
            focused.menus[0].items[2].label,
            focused.menus[0].items[0].shortcut_label.?,
        },
    );
    if (!std.mem.eql(u8, focused.menus[0].title, "W18 state 0")) {
        return error.MenuTitleWasNotStateDerived;
    }
    if (!std.mem.eql(u8, focused.menus[0].items[0].label, "Observe mark=0")) {
        return error.MenuLabelWasNotStateDerived;
    }

    // The mark is model state. Changing the model, with no dispatch at all,
    // is what the next snapshot reads.
    const Mark = struct {
        fn run(model: *MenuModel, _: void) anyerror!void {
            model.tick = true;
        }
    };
    // SAFETY: the first read of this comes from the `session.read` that
    // follows, whose `capture` callback assigns every field.
    var observed_model: MenuModel = undefined;
    try session.update(MenuModel, observed_handle, {}, Mark.run);
    try session.read(MenuModel, observed_handle, &observed_model, MenuModel.capture);

    // The same bar again, with its words formatted from the model that just
    // changed. Both snapshots are alive here: `focused` is what the bar said
    // before the change and `remarked` is what it says now.
    var frame_two = try MenuText.format(gpa, &observed_model);
    defer frame_two.deinit(gpa);
    const next_items = [_]menus.MenuItem{
        .{
            .id = 1,
            .label = frame_two.observe_label,
            .kind = .action,
            .action_name = ObserveAction.name,
            .action_payload_json = frame_two.payload,
            .shortcut_label = frame_two.shortcut,
        },
        .{
            .id = 2,
            .label = frame_two.disabled_label,
            .kind = .action,
            .action_name = DisabledAction.name,
        },
        .{
            .id = 3,
            .label = frame_two.quit_label,
            .kind = .system_action,
            .system_action = .quit,
        },
    };
    const next_declared = [_]menus.Menu{.{ .title = frame_two.title, .items = &next_items }};
    const next_bar: menus.MenuBar = .{ .menus = &next_declared };

    var remarked = try bridge.evaluate(gpa, next_bar, &tree, focus_id);
    defer remarked.deinit();
    try report.emit(
        "native: menu: after a model change and no dispatch:" ++
            " observe_enabled={} observe_checked={} not_now_checked={}" ++
            " model_invocations={d}\n",
        .{
            remarked.menus[0].items[0].enabled,
            remarked.menus[0].items[0].checked,
            remarked.menus[0].items[1].checked,
            observed_model.invoked,
        },
    );
    if (!remarked.menus[0].items[0].checked) return error.ModelChangeDidNotReachTheMenu;
    if (observed_model.invoked != 0) return error.EvaluationRanAHandler;

    // The current bar reads the state that is current, in its title and its
    // labels as well as in its marks. The snapshot taken before the change
    // still reads its own, which is what owning the text buys.
    try report.emit(
        "native: menu: state_derived_text now=[title=\"{s}\" observe=\"{s}\"" ++
            " not_now=\"{s}\"] earlier=[title=\"{s}\" observe=\"{s}\"" ++
            " shortcut=\"{s}\"]\n",
        .{
            remarked.menus[0].title,
            remarked.menus[0].items[0].label,
            remarked.menus[0].items[1].label,
            focused.menus[0].title,
            focused.menus[0].items[0].label,
            focused.menus[0].items[0].shortcut_label.?,
        },
    );
    if (!std.mem.eql(u8, remarked.menus[0].title, "W18 state 1")) {
        return error.CurrentTitleWasNotStateDerived;
    }
    if (!std.mem.eql(u8, remarked.menus[0].items[0].label, "Observe mark=1")) {
        return error.CurrentLabelWasNotStateDerived;
    }
    if (!std.mem.eql(u8, focused.menus[0].title, "W18 state 0")) {
        return error.EarlierSnapshotLostItsTitle;
    }
    if (!std.mem.eql(u8, focused.menus[0].items[0].label, "Observe mark=0")) {
        return error.EarlierSnapshotLostItsLabel;
    }
    if (!std.mem.eql(u8, focused.menus[0].items[0].shortcut_label.?, "Ctrl+Alt+O")) {
        return error.EarlierSnapshotLostItsShortcut;
    }

    // The buffer that first bar was formatted in is released here. Every click
    // below is therefore routed from a row a snapshot kept, not from the bar
    // this run assembled.
    frame_one.deinit(gpa);
    try report.emit(
        "native: menu: the buffer that first bar was formatted in is released" ++
            " now. Every mark above is this process's own model state read back" ++
            " through the public registry, and every click below is routed from a" ++
            " row a snapshot kept. This target still has no native menu, so no" ++
            " desktop menu was observed and none is claimed\n",
        .{},
    );

    const observed = try bridge.dispatchItem(
        retainedRow(focused.menus[0].items[0]),
        &tree,
        focus_id,
    );
    try session.read(MenuModel, observed_handle, &observed_model, MenuModel.capture);
    try report.emit("native: menu: observe dispatch={s} model_invocations={d} model_value={d}\n", .{
        @tagName(observed),
        observed_model.invoked,
        observed_model.last_value,
    });
    if (observed != .handled) return error.ObserveDispatchNotHandled;
    if (observed_model.invoked != 1 or observed_model.last_value != observed_value) {
        return error.ObserveDidNotReachTheModel;
    }

    const refused = try bridge.dispatchItem(
        retainedRow(unfocused.menus[0].items[0]),
        &tree,
        other_id,
    );
    try session.read(MenuModel, observed_handle, &observed_model, MenuModel.capture);
    try report.emit(
        "native: menu: observe from the other context dispatch={s}" ++
            " model_invocations={d} released_owner_calls={d}\n",
        .{ @tagName(refused), observed_model.invoked, retired_calls },
    );
    if (refused != .unavailable) return error.UnfocusedDispatchNotUnavailable;
    if (observed_model.invoked != 1) return error.UnfocusedDispatchReachedTheModel;
    if (retired_calls != 0) return error.ReleasedOwnerRanItsHandler;

    const disabled = try bridge.dispatchItem(
        retainedRow(focused.menus[0].items[1]),
        &tree,
        focus_id,
    );
    // SAFETY: the first read of this comes from the `session.read` that
    // follows, whose `capture` callback assigns every field.
    var disabled_model: MenuModel = undefined;
    try session.read(MenuModel, disabled_handle, &disabled_model, MenuModel.capture);
    try report.emit("native: menu: not_now dispatch={s} model_invocations={d}\n", .{
        @tagName(disabled),
        disabled_model.invoked,
    });
    if (disabled != .disabled) return error.DisabledDispatchNotDisabled;
    if (disabled_model.invoked != 0) return error.DisabledModelWasInvoked;

    const system_result = try bridge.dispatchItem(
        retainedRow(focused.menus[0].items[2]),
        &tree,
        focus_id,
    );
    // SAFETY: the first read of this comes from the `session.read` that
    // follows, whose `capture` callback assigns every field.
    var quit_model: MenuModel = undefined;
    try session.read(MenuModel, quit_handle, &quit_model, MenuModel.capture);
    try report.emit("native: menu: quit dispatch={s} model_invocations={d}\n", .{
        @tagName(system_result),
        quit_model.invoked,
    });
    if (system_result != .handled) return error.SystemDispatchNotHandled;
    if (quit_model.invoked != 1) return error.SystemActionNotRecorded;
}

/// What this run's own handler saw. The host lends a payload for the length of
/// the callback, so the bytes are copied into storage owned here.
const LaunchRecord = struct {
    const capacity = 128;

    host_deliveries: u32 = 0,
    scheme_deliveries: u32 = 0,
    host_bytes: [capacity]u8 = [_]u8{0} ** capacity,
    host_len: usize = 0,
    scheme_bytes: [capacity]u8 = [_]u8{0} ** capacity,
    scheme_len: usize = 0,
};

fn copyBounded(target: []u8, length: *usize, value: []const u8) void {
    const taken = @min(value.len, target.len);
    @memcpy(target[0..taken], value[0..taken]);
    length.* = taken;
}

/// The scheme handler this process installs for its own synthetic scheme. It
/// records and returns; nothing is opened.
fn onSyntheticScheme(ctx: ?*anyopaque, url: []const u8) void {
    const record: *LaunchRecord = @ptrCast(@alignCast(ctx.?));
    record.scheme_deliveries += 1;
    copyBounded(&record.scheme_bytes, &record.scheme_len, url);
}

/// The host's own launch callback. It converts the host's mirrored payload
/// into the ingress type the shared adapter consumes, which is the one place
/// the two mirrors meet.
const LaunchHook = struct {
    record: *LaunchRecord,
    adapter: *open_url.LaunchHookAdapter,

    fn onIncomingLaunch(
        ctx: *anyopaque,
        application: *host.Application,
        launch: host.Application.IncomingLaunch,
    ) void {
        const self: *LaunchHook = @ptrCast(@alignCast(ctx));
        self.record.host_deliveries += 1;
        copyBounded(&self.record.host_bytes, &self.record.host_len, launch.value);
        open_url.LaunchHookAdapter.onIncomingLaunch(self.adapter, application, .{
            .kind = switch (launch.kind) {
                .file => .file,
                .text => .text,
            },
            .value = launch.value,
        });
    }
};

fn openOutcomeText(result: anyerror!open_url.OpenOutcome) []const u8 {
    if (result) |value| return @tagName(value) else |err| return @errorName(err);
}

/// The launch half. A synthetic URL this process generated is queued before
/// any handler exists, so the host has to own it, and it is delivered exactly
/// once after a handler is installed. No provider is installed, so the one
/// call that would open anything is made without approval and has to refuse.
fn launchPhase(
    gpa: std.mem.Allocator,
    io: Io,
    application: *host.Application,
    report: *Reporter,
) !void {
    var dispatcher = try open_url.UrlDispatcher.init(gpa);
    defer dispatcher.deinit();
    try report.emit(
        "native: launch: scheme {s} registered in this process only; no desktop" ++
            " registration and no provider\n",
        .{synthetic_scheme},
    );

    var record: LaunchRecord = .{};
    try dispatcher.registerSchemeHandler(synthetic_scheme, .{
        .context = &record,
        .handler = onSyntheticScheme,
    });
    var adapter: open_url.LaunchHookAdapter = .{ .dispatcher = &dispatcher };
    var hook: LaunchHook = .{ .record = &record, .adapter = &adapter };

    // The host has launched and no handler is installed, so this payload can
    // only be buffered by the host that owns it.
    try application.start();
    var staged: [synthetic_launch_url.len]u8 = undefined;
    @memcpy(staged[0..], synthetic_launch_url);
    try application.incomingLaunch(.{ .kind = .text, .value = staged[0..] });
    // The caller's own bytes are erased here. What the handler reads later is
    // the host's buffered copy, so a payload the host had merely borrowed
    // would arrive as this filler instead of as the URL.
    @memset(staged[0..], 'x');
    try pump(io, application, 2);
    try report.emit(
        "native: launch: queued with no handler installed, host_deliveries={d}" ++
            " scheme_deliveries={d}\n",
        .{ record.host_deliveries, record.scheme_deliveries },
    );
    if (record.host_deliveries != 0 or record.scheme_deliveries != 0) {
        return error.LaunchDeliveredWithoutHandler;
    }

    application.setHooks(.{
        .context = &hook,
        .on_incoming_launch = LaunchHook.onIncomingLaunch,
    });
    try pump(io, application, 2);
    try report.emit(
        "native: launch: after the handler was installed host_deliveries={d}" ++
            " scheme_deliveries={d} dispatcher_dispatches={d}\n",
        .{ record.host_deliveries, record.scheme_deliveries, dispatcher.dispatched_count },
    );
    if (record.host_deliveries != 1) return error.LaunchHostDeliveryCount;
    if (record.scheme_deliveries != 1) return error.LaunchSchemeDeliveryCount;
    if (dispatcher.dispatched_count != 1) return error.LaunchDispatcherCount;
    // Compared against the constant this run wrote, not against the staging
    // buffer it erased.
    if (!std.mem.eql(u8, record.host_bytes[0..record.host_len], synthetic_launch_url)) {
        return error.LaunchHostPayloadMismatch;
    }
    if (!std.mem.eql(u8, record.scheme_bytes[0..record.scheme_len], synthetic_launch_url)) {
        return error.LaunchSchemePayloadMismatch;
    }
    try report.emit("native: launch: delivered payload \"{s}\"\n", .{record.scheme_bytes[0..record.scheme_len]});

    // One delivery is the contract, so further pumping must not produce another.
    try pump(io, application, 4);
    if (record.host_deliveries != 1 or record.scheme_deliveries != 1 or
        dispatcher.dispatched_count != 1)
    {
        return error.LaunchDeliveredMoreThanOnce;
    }
    try report.emit("native: launch: the buffered payload stayed at one delivery through four more pumps\n", .{});

    // An unapproved external launch never reaches a provider, and this run
    // approves nothing.
    const unapproved: anyerror!open_url.OpenOutcome =
        dispatcher.openExternal(synthetic_launch_url, .{});
    try report.emit("native: launch: unapproved external launch reported {s}\n", .{
        openOutcomeText(unapproved),
    });
    if (unapproved) |_| return error.UnapprovedExternalLaunchAccepted else |_| {}
    try report.emit(
        "native: launch: verdict: queued until a handler existed, delivered once, nothing opened\n",
        .{},
    );
}

/// The observation arm. It opens no window, because nothing in it paints, so
/// no GPU surface is claimed; it reads and writes no clipboard, asks for no
/// dialog, registers nothing with the desktop, launches nothing and approves
/// nothing.
fn nativeObservations(
    gpa: std.mem.Allocator,
    io: Io,
    application: *host.Application,
    report: *Reporter,
) !void {
    try report.emit("native observations: begin, selected by {s}\n", .{native_observations_flag});
    try report.emit("native observations: no window opened; this arm reads and paints nothing\n", .{});
    try preferencesPhase(gpa, io, report);
    try menuPhase(gpa, application.session, report);
    try launchPhase(gpa, io, application, report);
    try report.emit("native observations: end\n", .{});
}

/// Nanoseconds on the awake clock, so a bounded wait is measured against one
/// clock instead of against a round count.
fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

/// Run the host loop until the chooser is answered or the budget runs out.
/// Nothing in here completes an outcome: the only two things that can end this
/// wait are the portal's own answer and the deadline.
fn pumpUntilAnswered(
    io: Io,
    application: *host.Application,
    receiver: *const Receiver,
    budget_ms: u64,
) !u64 {
    const deadline = nowNs(io) + @as(i96, budget_ms) * std.time.ns_per_ms;
    var rounds: u64 = 0;
    while (receiver.calls == 0) {
        if (nowNs(io) >= deadline) break;
        _ = try application.step();
        rounds += 1;
        try Io.sleep(io, Io.Duration.fromMilliseconds(8), .real);
    }
    return rounds;
}

fn parseDialogCase(text: []const u8) !DialogCase {
    if (std.mem.eql(u8, text, "selected")) return .selected;
    if (std.mem.eql(u8, text, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, text, "parent-closed")) return .parent_closed;
    std.log.err(
        "{s} must be exactly selected, cancelled or parent-closed",
        .{dialog_case_flag},
    );
    return error.UnknownDialogCase;
}

fn parseDialogMode(text: []const u8) !DialogMode {
    if (std.mem.eql(u8, text, "open")) return .open;
    if (std.mem.eql(u8, text, "save")) return .save;
    std.log.err("{s} must be exactly open or save", .{dialog_mode_flag});
    return error.UnknownDialogMode;
}

/// No chooser opens without the flag AND an exact copy of the scope text, so a
/// command line that names a chooser cannot stop short of what was approved.
fn requireDialogAuthorization(options: DialogOptions) !void {
    if (!options.authorize) {
        std.log.err(
            "the dialog arm opens a real chooser on a person's screen and needs {s}",
            .{authorize_dialog_flag},
        );
        return error.MissingDialogAuthorization;
    }
    const given = options.scope orelse {
        std.log.err("{s} needs the exact {s} text beside it", .{
            authorize_dialog_flag,
            dialog_scope_flag,
        });
        return error.MissingAuthorizationScope;
    };
    if (!std.mem.eql(u8, given, dialog_scope_text)) {
        std.log.err("{s} does not match the authorized scope", .{dialog_scope_flag});
        std.log.err("expected exactly: {s}", .{dialog_scope_text});
        return error.AuthorizationScopeMismatch;
    }
}

/// What the display server will actually be told the parent is. The portal
/// adapter builds this token from the window's own properties, so the run
/// reads those same two fields and reports the same answer rather than a name
/// it made up here.
fn reportPortalParent(report: *Reporter, managed: *host.ManagedWindow) !void {
    const properties = managed.native.sdl.getProperties() catch {
        try report.emit(
            "dialog: the platform published no window properties; the chooser opens unparented\n",
            .{},
        );
        return;
    };
    if (properties.x11_window) |xid| {
        try report.emit("dialog: portal parent token x11:{x}\n", .{@as(u64, @intCast(xid))});
    } else if (properties.wayland_xdg_toplevel_export_handle) |export_handle| {
        if (export_handle.len != 0) {
            try report.emit("dialog: portal parent token wayland:{s}\n", .{export_handle});
        } else {
            try report.emit(
                "dialog: the platform exported no xdg_foreign handle; the chooser opens unparented\n",
                .{},
            );
        }
    } else {
        try report.emit(
            "dialog: the platform named no window identifier; the chooser opens unparented\n",
            .{},
        );
    }
}

var instance_extensions: [][*:0]const u8 = &.{};

fn currentInstanceExtensions() []const [*:0]const u8 {
    return instance_extensions;
}

fn openDevice(gpa: std.mem.Allocator, io: Io) !noapi.Gpu {
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    instance_extensions = try gpa.dupe([*:0]const u8, try sdl3.vulkan.getInstanceExtensions());
    defer {
        gpa.free(instance_extensions);
        instance_extensions = &.{};
    }
    return noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "w18-dialog-smoke",
        .validation = false,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &currentInstanceExtensions,
        },
        .io = io,
        .allocator = gpa,
    });
}

/// Wayland maps a toplevel only after it receives a real buffer. Keep that
/// buffer's surface alive until the host's pre-close hook, not until after SDL
/// has destroyed the parent. Black is zero in both Oklab and sRGB.
const ParentContent = struct {
    surface: ?noapi.Surface = null,

    fn release(self: *ParentContent) void {
        if (self.surface) |*surface| surface.deinit();
        self.surface = null;
    }

    fn onBeforeClose(context: *anyopaque, _: *host.ManagedWindow) void {
        const self: *ParentContent = @ptrCast(@alignCast(context));
        self.release();
    }

    fn present(self: *ParentContent, report: *Reporter) !void {
        const surface = if (self.surface) |*live| live else return error.ParentSurfaceMissing;
        _ = try surface.beginFrame();
        const image = surface.surfaceSize();
        if (image.width == 0 or image.height == 0) return error.ParentSurfaceEmpty;
        var cmd = surface.commandsBegin();
        cmd.beginRendering(.{
            .render_area_size = .{ image.width, image.height },
            .color_attachments = &.{.{
                .texture = surface.currentImage(),
                .load_op = .clear,
                .store_op = .store,
                .clear_color = .{ 0, 0, 0, 1 },
            }},
        });
        cmd.endRendering();
        const result = try surface.endFrame(.{});
        if (result.present_out_of_date) return error.ParentPresentationOutOfDate;
        try report.emit("dialog: parent buffer presented via noapi size={d}x{d}\n", .{ image.width, image.height });
    }
};

/// The dialog half, authorized by the caller's flag and an exact scope text,
/// against this session's real file chooser.
///
/// One visible window is opened first, because a chooser parented to nothing is
/// not the case this run exists for: the parent has to be a live owned window
/// whose own native properties name it. A noapi frame maps the parent on
/// Wayland, so the compositor can issue a real native close request.
///
/// All cases wait for native input. For `parent_closed`, the controller first
/// observes the live chooser, then asks the window manager to close this
/// process's own parent. This binary never answers the chooser itself.
fn dialogRoundTrip(
    gpa: std.mem.Allocator,
    io: Io,
    application: *host.Application,
    report: *Reporter,
    options: DialogOptions,
) !void {
    try report.emit(
        "dialog round trip: case={s} mode={s}\n",
        .{ @tagName(options.case), @tagName(options.mode) },
    );
    try report.emit("dialog round trip: authorized by {s} and an exact {s}\n  {s}\n", .{
        authorize_dialog_flag,
        dialog_scope_flag,
        dialog_scope_text,
    });
    if (!host.portal.isSessionBusAvailable()) {
        // A chooser without a bus would be refused by the provider anyway. The
        // refusal is reported here so it is never mistaken for an answer.
        try report.emit(
            "dialog round trip: refused, this process names no session bus, so no chooser opened\n",
            .{},
        );
        return error.ProviderUnavailableNotObserved;
    }

    var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var folder_len: usize = 0;
    var target_copy: [std.fs.max_path_bytes]u8 = undefined;
    // A target is required for `selected`, because that case compares what came
    // back against something. A cancelled or parent-closed save accepts one
    // too, and then it names the file that must still be absent afterwards, so
    // a save that wrote something anyway is visible rather than assumed away.
    if (options.case == .selected or options.target != null) {
        const given = options.target orelse {
            std.log.err(
                "{s} selected needs {s} naming the one file the chooser may return",
                .{ dialog_case_flag, dialog_target_flag },
            );
            return error.MissingDialogTarget;
        };
        if (!std.fs.path.isAbsolute(given)) {
            std.log.err("{s} must be an absolute path", .{dialog_target_flag});
            return error.DialogTargetIsNotAbsolute;
        }
        if (given.len >= target_copy.len) return error.DialogTargetPathIsTooLong;
        @memcpy(target_copy[0..given.len], given);
        const target: []const u8 = target_copy[0..given.len];
        const basename = std.fs.path.basename(target);
        const folder = std.fs.path.dirname(target) orelse "/";
        if (folder.len >= folder_buffer.len) return error.DialogTargetPathIsTooLong;
        @memcpy(folder_buffer[0..folder.len], folder);
        folder_len = folder.len;
        // What has to be true of the target depends on the mode. An open names
        // a file that has to be there, because the chooser cannot otherwise be
        // answered and the run would be waiting on nothing. A save names a file
        // that must NOT be there: the folder has to exist to be offered, and a
        // destination this run did not create is the only one whose creation
        // afterwards is this run's own evidence that a save really happened.
        if (options.mode == .save) {
            const folder_status = std.Io.Dir.cwd().statFile(io, folder, .{}) catch {
                try report.emit("dialog: save folder \"{s}\" cannot be read\n", .{folder});
                return error.DialogTargetIsUnreadable;
            };
            if (folder_status.kind != .directory) {
                try report.emit("dialog: save folder \"{s}\" is not a directory\n", .{folder});
                return error.DialogTargetIsNotADirectory;
            }
            if (std.Io.Dir.cwd().statFile(io, target, .{})) |_| {
                try report.emit(
                    "dialog: save target \"{s}\" already exists; this run only" ++
                        " saves to a path it created nothing at\n",
                    .{target},
                );
                return error.DialogSaveTargetAlreadyExists;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    try report.emit("dialog: save target \"{s}\" cannot be read\n", .{target});
                    return error.DialogTargetIsUnreadable;
                },
            }
            try report.emit(
                "dialog: save target \"{s}\" folder \"{s}\" is_directory=true absent=true\n",
                .{ target, folder },
            );
        } else {
            const status = std.Io.Dir.cwd().statFile(io, target, .{}) catch {
                try report.emit("dialog: target \"{s}\" cannot be read\n", .{target});
                return error.DialogTargetIsUnreadable;
            };
            if (status.kind != .file) {
                try report.emit("dialog: target \"{s}\" is not a file\n", .{target});
                return error.DialogTargetIsNotAFile;
            }
            try report.emit("dialog: target \"{s}\" folder \"{s}\" bytes={d}\n", .{
                target,
                folder,
                status.size,
            });
            // No filter is attached, and that is a measured decision rather than a
            // preference. `Filter.pattern` is a semicolon separated list that the
            // portal takes as glob patterns, and this build can express no pattern
            // a real chooser answers. Measured against the GNOME/Nautilus portal
            // on this session: a whole file name ("w18-target.txt") and a bare
            // extension ("txt") each matched nothing and produced "Folder is
            // Empty", and so did the bare wildcard "*". The chooser listed only the
            // filter the request declared, so there was no second filter to switch
            // to and the one file this run asks for could not be selected at all.
            // An unfiltered chooser lists it, so none is sent and what this arm
            // proves is the round trip. `Filter` is a W18 host type and this is the
            // defect it carries; it is reported, not worked around in the host.
            try report.emit(
                "dialog: no filter is attached for target \"{s}\"; no pattern this" ++
                    " build can send was answered by the real chooser\n",
                .{basename},
            );
        }
    }

    var receiver: Receiver = .{};
    defer receiver.deinit();
    var worker: ThreadWorker = .{};
    defer {
        worker.finish(io) catch @panic("W18 dialog smoke left its worker live");
        application.dialogs.setWorker(null);
    }

    // Parent teardown can deliver parent_closed on an error path. Keep the
    // callback receiver alive until the parent's close defer has finished.
    var gpu = try openDevice(gpa, io);
    defer gpu.deinit();
    var content: ParentContent = .{};
    defer content.release();
    application.setHooks(.{ .context = &content, .on_before_close = ParentContent.onBeforeClose });
    defer application.setHooks(.{});
    const handle = try application.openWindow(.{
        .title = dialog_parent_title,
        .width = 320,
        .height = 180,
        .resizable = false,
        .visible = true,
        .gpu_surface = true,
    });
    var window_live = true;
    // A close that fails here leaves the parent window alive, so the failure is
    // reported instead of dropped: a run that swallowed it would go on to end
    // on a clean teardown it never had. A `defer` cannot propagate an error,
    // and a print that failed would leave this process no way to report at
    // all, so that case panics rather than passing unnoticed. The owner close
    // further down is untouched: this only decides what a failed teardown
    // close says, never whether it runs.
    defer if (window_live) {
        _ = application.closeWindow(handle) catch |err| {
            report.emit("dialog: teardown close of the parent window: {s}\n", .{
                @errorName(err),
            }) catch @panic("W18 dialog smoke could not report the teardown close failure");
        };
    };

    const managed = try application.getWindow(handle);
    const extent = try managed.native.pixelExtent();
    content.surface = try noapi.Surface.initSdl(
        &gpu,
        @ptrCast(managed.native.sdl.value),
        @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
        .{ .extent = .{ .width = extent.width, .height = extent.height } },
    );
    try content.present(report);
    managed.markPresented();
    const native_id = try managed.native.sdl.getId();
    try report.emit("dialog: parent window sdl_id={d} observed_parent={s}\n", .{
        native_id,
        if (managed.observedParent()) |_| "kept" else "<none requested>",
    });
    try report.emit("dialog: parent window gpu_surface=true; real noapi buffer committed\n", .{});
    try report.emit("dialog: video driver {s}\n", .{sdl3.video.getCurrentDriverName() orelse "<null>"});
    try report.emit("dialog: session bus {s}\n", .{
        if (host.portal.isSessionBusAvailable()) "present" else "<absent>",
    });
    try reportPortalParent(report, managed);

    application.dialogs.setProvider(dialogs.portalFileProvider());
    application.dialogs.setWorker(worker.worker());

    var request_options: dialogs.FileOptions = .{
        .mode = switch (options.mode) {
            .open => .open_file,
            .save => .save_file,
        },
        .title = if (options.mode == .save) "w18 dialog smoke save" else "w18 dialog smoke",
        .parent_window = native_id,
    };
    // A validated target names a folder the chooser should start in, for every
    // case, not only for the one that compares the answer. A zero length means
    // no target was validated, and an empty string is not a folder.
    if (folder_len != 0) {
        request_options.default_location = folder_buffer[0..folder_len];
    }
    const approval: dialogs.PointOfRiskApproval = .{ .confirmed = true };
    try report.emit(
        "dialog: requested mode={s} approval_confirmed={} title=\"{s}\"\n",
        .{
            @tagName(request_options.mode),
            approval.confirmed,
            request_options.title.?,
        },
    );

    try application.dialogs.showFile(
        request_options,
        approval,
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    try report.emit("dialog: request pending={d}\n", .{application.dialogs.pendingCount()});
    if (application.dialogs.pendingCount() == 0) return error.DialogRequestDidNotStayPending;

    var rounds: u64 = 0;
    switch (options.case) {
        .parent_closed => {
            try report.emit(
                "dialog: waiting up to {d} ms for the owned parent to close while the chooser is live\n",
                .{options.wait_ms},
            );
            rounds = try pumpUntilAnswered(io, application, &receiver, options.wait_ms);
            if (application.getWindow(handle)) |_| {
                return error.ParentWasNotClosed;
            } else |err| switch (err) {
                error.StaleWindow => window_live = false,
                else => return err,
            }
            try report.emit("dialog: native parent close observed\n", .{});
            try report.emit("dialog: parent-closed rounds={d} deliveries={d}\n", .{
                rounds,
                receiver.calls,
            });
            // A later answer from the chooser must not land on a request that
            // is already over, so the run keeps pumping for a bounded spell.
            try pump(io, application, 40);
            try report.emit("dialog: after settling, deliveries={d} pending={d}\n", .{
                receiver.calls,
                application.dialogs.pendingCount(),
            });
        },
        .selected, .cancelled => {
            try report.emit(
                "dialog: waiting up to {d} ms for the chooser to be answered\n",
                .{options.wait_ms},
            );
            rounds = try pumpUntilAnswered(io, application, &receiver, options.wait_ms);
            try report.emit("dialog: rounds={d} deliveries={d}\n", .{ rounds, receiver.calls });
        },
    }

    const tag = outcomeTag(receiver.outcome);
    try report.emit("dialog: outcome={s}\n", .{tag});
    if (receiver.calls != 1) return error.DialogWasAnsweredMoreThanOnce;

    switch (options.case) {
        .selected => {
            const outcome = receiver.outcome orelse return error.NoDialogOutcome;
            switch (outcome) {
                .selected => |selection| {
                    if (selection.paths.len != 1) return error.SelectionWasNotASinglePath;
                    const copy = gpa.dupe(u8, selection.paths[0]) catch
                        return error.OutOfMemory;
                    if (options.mode == .open) {
                        try expectText(gpa, report, "selected path", copy, options.target.?);
                    } else {
                        defer gpa.free(copy);
                        // A save chooser was started in the folder the target
                        // names, and the folder it answered from is the one the
                        // person chose, so only the file name is compared here.
                        // That name is what this run asked the chooser for.
                        const wanted = std.fs.path.basename(options.target.?);
                        const got = std.fs.path.basename(copy);
                        try report.emit(
                            "save selected: observed=\"{s}\" folder=\"{s}\"" ++
                                " wanted_name=\"{s}\" name_match={} absolute={}\n",
                            .{
                                copy,
                                std.fs.path.dirname(copy) orelse "",
                                wanted,
                                std.mem.eql(u8, got, wanted),
                                std.fs.path.isAbsolute(copy),
                            },
                        );
                        if (!std.fs.path.isAbsolute(copy)) {
                            return error.SaveSelectionWasNotAbsolute;
                        }
                        if (!std.mem.eql(u8, got, wanted)) return error.SaveSelectionNameMismatch;
                        // A save chooser that answered with a name has created
                        // that file, so its presence is this run's own evidence
                        // that the write went through the portal and not only
                        // through the host.
                        const written = std.Io.Dir.cwd().statFile(io, copy, .{}) catch {
                            try report.emit("save selected: \"{s}\" was not created\n", .{copy});
                            return error.SaveSelectionWasNotCreated;
                        };
                        try report.emit(
                            "save selected: the portal created \"{s}\" bytes={d}\n",
                            .{ copy, written.size },
                        );
                    }
                },
                else => return error.SelectionWasNotObserved,
            }
        },
        .cancelled => switch (receiver.outcome.?) {
            .cancelled => try reportAbsentSaveTarget(io, report, options),
            else => return error.CancellationWasNotObserved,
        },
        .parent_closed => switch (receiver.outcome.?) {
            .parent_closed => try reportAbsentSaveTarget(io, report, options),
            else => return error.ParentCloseWasNotObserved,
        },
    }

    try report.emit("dialog: verdict case={s} mode={s} observed against the real chooser\n", .{
        @tagName(options.case),
        @tagName(options.mode),
    });
}

/// A save that was cancelled, or whose parent closed, must have written
/// nothing. The target is the one path this run named, so its absence after the
/// chooser answered is the only evidence available that no file was created.
fn reportAbsentSaveTarget(io: Io, report: *Reporter, options: DialogOptions) !void {
    if (options.mode != .save) return;
    const target = options.target orelse {
        try report.emit(
            "save not taken: no {s} was named, so no absence is checked\n",
            .{dialog_target_flag},
        );
        return;
    };
    if (std.Io.Dir.cwd().statFile(io, target, .{})) |status| {
        try report.emit(
            "save not taken: \"{s}\" exists with {d} bytes after a chooser that chose nothing\n",
            .{ target, status.size },
        );
        return error.SaveWroteAfterANonSelection;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try report.emit("save not taken: \"{s}\" is still absent\n", .{target});
}

fn parentRun(
    gpa: std.mem.Allocator,
    io: Io,
    report: *Reporter,
    authorize: bool,
    native_observations: bool,
    dialog: DialogOptions,
) !void {
    if (authorize or native_observations or dialog.authorize) {
        // The host owns SDL, so the clipboard under test is the one this host
        // installs into every window it opens, and this run owns both
        // teardowns. The driver is left alone in both halves: the clipboard
        // half is only authorized on a real session, and the observation half
        // is the one that asked to read it.
        var session = try nogui.Session.init(gpa);
        var session_live = true;
        defer if (session_live) session.deinit() catch
            @panic("W18 dialog smoke error path left the Session live");
        var application = host.Application.init(gpa, &session, .{
            .app_id = "dev.nogui.w18dialogsmoke",
            .restart = .never,
        }) catch |err| {
            // No display server means there is nothing to observe and nothing
            // was opened. The run says which answer it got and stops.
            try report.emit(
                "SDL host: init failed ({s}); no window, clipboard, dialog or" ++
                    " launch was touched\n",
                .{@errorName(err)},
            );
            return err;
        };
        var application_live = true;
        defer if (application_live) application.deinit();

        if (authorize) try clipboardRoundTrip(gpa, io, &application, report);
        if (native_observations) {
            try nativeObservations(gpa, io, &application, report);
        }
        if (dialog.authorize) try dialogRoundTrip(gpa, io, &application, report, dialog);

        application.deinit();
        application_live = false;
        const released = session.deinit();
        session_live = false;
        try report.emit("shutdown: Application.deinit ok, Session.deinit={s}\n", .{
            outcomeText(void, released),
        });
    } else {
        try report.emit(
            "clipboard half: not run, no {s} was given; the default run touches" ++
                " no clipboard and needs no display server\n",
            .{authorize_clipboard_flag},
        );
        try report.emit(
            "native observations: not run, no {s} was given; the default run" ++
                " reads no compositor, theme, menu or launch signal\n",
            .{native_observations_flag},
        );
        try report.emit(
            "dialog half: not run, no {s} was given; the default run opens no" ++
                " window and asks for no chooser\n",
            .{authorize_dialog_flag},
        );
    }

    try noSessionBusChild(gpa, io, report);
    try report.emit(
        "not run: an external URL launch and the Secret Service credential store;" ++
            " each needs an operator's approval\n",
        .{},
    );
    try report.emit("W18 dialog smoke done\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa_state.deinit() == .leak) @panic("W18 dialog smoke leaked owned memory");
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var child_mode = false;
    var authorize = false;
    var native_observations = false;
    var dialog: DialogOptions = .{};
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, no_session_bus_flag)) {
            child_mode = true;
        } else if (std.mem.eql(u8, arg, authorize_clipboard_flag)) {
            authorize = true;
        } else if (std.mem.eql(u8, arg, native_observations_flag)) {
            native_observations = true;
        } else if (std.mem.eql(u8, arg, authorize_dialog_flag)) {
            dialog.authorize = true;
        } else if (std.mem.eql(u8, arg, dialog_scope_flag)) {
            dialog.scope = args_it.next() orelse return error.MissingAuthorizationScope;
        } else if (std.mem.eql(u8, arg, dialog_case_flag)) {
            dialog.case = try parseDialogCase(args_it.next() orelse return error.UnknownDialogCase);
        } else if (std.mem.eql(u8, arg, dialog_mode_flag)) {
            dialog.mode = try parseDialogMode(args_it.next() orelse return error.UnknownDialogMode);
        } else if (std.mem.eql(u8, arg, dialog_target_flag)) {
            dialog.target = args_it.next() orelse return error.MissingDialogTarget;
        } else if (std.mem.eql(u8, arg, dialog_wait_flag)) {
            const value = args_it.next() orelse return error.MissingDialogWaitMs;
            dialog.wait_ms = std.fmt.parseInt(u64, value, 10) catch return error.BadDialogWaitMs;
            dialog.wait_ms = @max(min_dialog_wait_ms, @min(max_dialog_wait_ms, dialog.wait_ms));
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    var report: Reporter = .{ .io = io };
    if (child_mode) {
        // The child inherits nothing, so it never mutates the user's
        // clipboard and never needs a display.
        try report.emit("W18 dialog smoke child: {s}\n", .{no_session_bus_flag});
        return noSessionBusProbe(gpa, io, &report);
    }

    // The dialog arm is refused here, before a Session, a display server or a
    // window exists, so a run that is not authorized opens nothing at all.
    if (dialog.authorize or dialog.scope != null or dialog.target != null) {
        try requireDialogAuthorization(dialog);
    }

    try report.emit("W18 dialog smoke\n", .{});
    try parentRun(gpa, io, &report, authorize, native_observations, dialog);
}
