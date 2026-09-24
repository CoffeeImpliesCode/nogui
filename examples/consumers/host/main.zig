//! Host external consumer of the `nogui` package.
//!
//! Uses SDL's dummy driver except on macOS, where attachment needs Cocoa.
//! A real worker updates a model after an idle interval; the externally
//! driven host wakes, redraws once, and shuts down. No GPU is needed.
const std = @import("std");
const nogui = @import("nogui");
const host = @import("nogui_host");

const Document = struct { revision: u32 = 0 };

const Banner = struct {
    label_buf: [32]u8 = @splat(0),
    observed: u32 = 0,

    pub fn draw(self: *Banner, doc: *const Document, ctx: *nogui.DrawCtx) !void {
        self.observed = doc.revision;
        const text = try std.fmt.bufPrint(&self.label_buf, "host up r{d}", .{doc.revision});
        _ = try ctx.label(.{ .text = text });
    }
};

const Worker = struct {
    result: u32 = 0,
    failed: bool = false,

    fn run(self: *Worker, io: std.Io) void {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(25), .real) catch {
            self.failed = true;
            return;
        };
        self.result = 7;
    }

    fn deliver(doc: *Document, self: *Worker, _: *nogui.Session) void {
        if (!self.failed) doc.revision = self.result;
    }
};

/// The target accessibility adapter's attachment, and the lifetime that goes
/// with it.
///
/// On macOS the adapter is built around a real window, so it attaches to the
/// one this host opened and has to be detached before the host destroys it —
/// which is what `on_before_close` is for. On a target that has no such
/// adapter, or a build without the bridge, `attach` answers by name, and
/// that answer is checked too, so the seam is exercised wherever the consumer
/// runs instead of only where a screen reader could see it.
///
/// Whether the window really has a Cocoa window behind it is NOT read here.
/// That fact is SDL's, `sdl3` is not a declared dependency of this consumer,
/// and `attach` already answers the platform question on its own.
const TargetAttach = struct {
    adapter: host.accessibility.Adapter = undefined,
    /// Whether there is a bridge handle to hand AccessKit at all.
    live: bool = false,
    attempted: bool = false,
    attached: bool = false,
    detached: bool = false,
    refusal: ?anyerror = null,

    /// Whether this target and this build have an adapter to attach at all.
    /// Off macOS there is no `NSWindow` behind an SDL window; without the
    /// bridge there is no handle to give AccessKit. Both refuse by name.
    fn applicable() bool {
        return host.macos.available and host.accessibility.linked;
    }

    fn init(gpa: std.mem.Allocator, io: std.Io) TargetAttach {
        var self: TargetAttach = .{};
        if (applicable()) {
            self.adapter.init(gpa, io);
            self.live = true;
        }
        return self;
    }

    /// Attach to the window the host is presenting into. Runs on the host's
    /// main thread from the frame callback, which is where the attach belongs.
    ///
    /// `attach` is called on every path and its answer is recorded, never
    /// assumed. It refuses `ShimUnavailable` off macOS and `Unsupported`
    /// without the bridge, both before it reads the adapter, so an
    /// uninitialised adapter is never touched and the refusal this consumer
    /// reports is the one the package returned rather than a copy of
    /// `attach`'s own order re-derived here.
    fn attachTo(self: *TargetAttach, window: *host.ManagedWindow) void {
        if (self.attempted) return;
        self.attempted = true;
        host.macos.accessibility.attach(&self.adapter, window.native.sdl) catch |err| {
            self.refusal = err;
            return;
        };
        self.attached = true;
    }

    /// Detach while the platform window is still alive. A window destroyed
    /// with the bridge attached would leave its content view subclassed by
    /// freed Rust.
    fn detachFrom(self: *TargetAttach) void {
        if (!self.attached) return;
        host.macos.accessibility.detach(&self.adapter);
        self.live = false;
        self.attached = false;
        self.detached = true;
    }

    fn deinit(self: *TargetAttach) void {
        if (!self.live) return;
        self.adapter.deinit();
        self.live = false;
    }
};

const FrameProbe = struct {
    frames: u32 = 0,
    target: *TargetAttach,

    fn onFrame(raw: *anyopaque, _: *host.Application, window: *host.ManagedWindow, _: nogui.frame_demand.FrameDemand.Work) !bool {
        const self: *FrameProbe = @ptrCast(@alignCast(raw));
        const output = try window.app.frame(self.frames + 1, .{
            .width = @floatFromInt(window.observed.size.width),
            .height = @floatFromInt(window.observed.size.height),
        });
        if (output.tree.nodes.items.len != 1) return error.UnexpectedNodeCount;
        self.frames += 1;
        // The window is live and this is the main thread, which is what the
        // target adapter needs to bind to it.
        self.target.attachTo(window);
        return true;
    }

    fn onBeforeClose(raw: *anyopaque, _: *host.ManagedWindow) void {
        const self: *FrameProbe = @ptrCast(@alignCast(raw));
        self.target.detachFrom();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;

    var document: Document = .{};
    var owner = try session.create(Document, &document);
    defer session.release(Document, &owner) catch unreachable;
    var app = try nogui.App.init(gpa, &session);
    defer app.deinit();
    var banner: Banner = .{};
    try app.mountModelRoot(Document, Banner, owner, &banner);

    var application = try host.Application.init(gpa, &session, .{
        .video_driver = if (host.macos.available) null else "dummy",
        .app_id = "dev.nogui.examples.consumers.host",
    });
    var application_live = true;
    defer if (application_live) application.deinit();
    var target = TargetAttach.init(gpa, init.io);
    defer target.deinit();
    var probe: FrameProbe = .{ .target = &target };
    application.setHooks(.{
        .context = &probe,
        .on_frame = FrameProbe.onFrame,
        .on_before_close = FrameProbe.onBeforeClose,
    });
    const handle = try application.openWindowWithApp(&app, .{
        .title = "nogui host consumer",
        .width = 320,
        .height = 200,
        .visible = true,
    });
    if (!session.hasWindow(handle.session_window)) return error.HandleNotLiveAfterOpen;

    // Drain initial SDL events before measuring an actual idle interval.
    for (0..16) |_| {
        if (!try application.step()) return error.HostStoppedEarly;
    }
    if (probe.frames == 0 or banner.observed != 0) return error.MissingInitialFrame;
    const before_idle = probe.frames;
    for (0..20) |_| {
        try std.Io.sleep(init.io, std.Io.Duration.fromMilliseconds(5), .real);
        if (!try application.step()) return error.HostStoppedEarly;
    }
    if (probe.frames != before_idle or (try application.nextWaitMilliseconds()) != null)
        return error.IdleHostRendered;

    var work: Worker = .{};
    _ = try session.spawnWorker(
        Worker,
        Document,
        Worker.run,
        Worker.deliver,
        owner.weak(),
        &work,
        .{ .window = app.window },
    );
    var wakes: u32 = 0;
    for (0..200) |_| {
        const snapshot = try session.taskWakeSnapshot();
        if (try session.waitForTaskWake(snapshot, 10 * std.time.ns_per_ms)) wakes += 1;
        if (!try application.step()) return error.HostStoppedEarly;
        if (banner.observed == 7) break;
    }
    if (banner.observed != 7 or probe.frames != before_idle + 1 or wakes == 0)
        return error.WorkerDidNotWakeHost;
    const after_completion = probe.frames;
    for (0..10) |_| {
        try std.Io.sleep(init.io, std.Io.Duration.fromMilliseconds(5), .real);
        if (!try application.step()) return error.HostStoppedEarly;
    }
    if (probe.frames != after_completion or (try application.nextWaitMilliseconds()) != null)
        return error.CompletedWorkerKeptRendering;

    if (!session.hasWindow(handle.session_window)) return error.HandleNotLiveAfterFrame;
    // Where this target and build really have an adapter, the attach must
    // have bound; a refusal here is a failure, not an answer to accept.
    if (TargetAttach.applicable()) {
        if (target.refusal) |err| return err;
        if (!target.attached) return error.TargetAdapterNeverAttached;
    }
    if (!try application.closeWindow(handle)) return error.CloseRejected;
    if (session.hasWindow(handle.session_window)) return error.HandleStillLiveAfterClose;

    // The attachment is a seam this consumer can check wherever it runs: where
    // an adapter exists the attach must have bound and must have been detached
    // before the host destroyed that window. Everywhere else the answer has to
    // name why it did not, rather than leaving the seam unexercised.
    if (TargetAttach.applicable()) {
        if (!target.detached) return error.TargetAdapterOutlivedItsWindow;
    } else switch (target.refusal orelse return error.TargetAttachReportedNoRefusal) {
        error.Unsupported, error.ShimUnavailable => {},
        else => return error.TargetRefusalNotNamed,
    }
    // Unregister the host's task wake callback before stopping its service.
    application.deinit();
    application_live = false;
    try session.shutdownTasks(2_000 * std.time.ns_per_ms);
    const line = try std.fmt.allocPrint(
        gpa,
        "host: OK session_window={d} idle_frames={d} worker_frames={d} wakes={d} " ++
            "target_adapter={s}\n",
        .{
            handle.session_window,
            before_idle,
            after_completion,
            wakes,
            if (target.detached) "attached" else if (target.refusal) |err| @errorName(err) else "none",
        },
    );
    defer gpa.free(line);
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
