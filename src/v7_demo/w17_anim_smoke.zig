//! W17 authored animation smoke — a real host window, a real Session, the
//! real App frame publication path, and the real pixels that frame produces.
//!
//! Nothing below is proved by reading source. A component authors a real
//! multi-step sequence with a repeat count through `App.startAnimation`, an
//! interruption goes through `App.interruptAnimation`, and the desktop
//! reduced-motion preference reaches the App through the one host bridge.
//! Every number printed is a frame count, a value draw code sampled through
//! `DrawCtx.animationValue`, or an Oklab triple read back out of a GPU
//! target those same frames wrote, and every claim about "no frame loop" is
//! a count that must come out at zero or one.
//!
//! TWO MODES, and only the second one opens a window.
//!
//! DEFAULT: SDL is told to take its windowless `dummy` driver BEFORE video is
//! initialized, the host window is opened hidden, and every frame is lowered
//! and recorded through the public `v7_frame` scene path into a
//! `v7_frame.Offscreen` target built from `v7_frame.SystemVulkanLoader`. No
//! Vulkan surface exists, nothing is presented, `Gpu.numSurfaces()` is zero,
//! and the Oklab pixels come back out of that same submission. A run on a
//! machine with a desktop session therefore never reaches that session.
//!
//! `--native`: the SAME lowering, the SAME text engine and the SAME checks,
//! over `v7_frame.NativeFrame` and a `noapi.Surface` built by
//! `noapi.Surface.initSdl` from the window SDL already made, into a real
//! window's swapchain image. The readback still comes out of the Oklab target
//! the presented passes wrote, so every pixel reported below is one the
//! PRESENTED frame drew. This is the only path that needs a display server.
//!
//! THE ANIMATION IS AN ORACLE, NOT A CLEAR COLOUR. The mounted root's first
//! child paints a bar whose horizontal position AND Oklab lightness are pure
//! functions of the value the component itself sampled from the authored
//! channel, over a track that is painted on every frame. Three things follow,
//! and all three are checked:
//!
//!   1. Per frame, the bar's centre lightness and its measured ink span must
//!      agree with the sampled value. A run that rendered frames and never
//!      compared them would prove nothing, so a disagreement ends it.
//!   2. The bar really moves: where the previous frame's bar was, the pixels
//!      are the track again. A frame that was recorded but not re-recorded
//!      leaves the old bar standing.
//!   3. The reduced-motion endpoint and the motion endpoint are the SAME
//!      pixels, not two values that merely round to the same number.
//!
//! Every landmark is on that authored geometry and colour. Nothing here is
//! read off a glyph, so a text rasterizer change cannot move a probe.
//!
//! The clock is virtual, advanced 16 ms per published frame, so the frame
//! counts are exact rather than wall-clock dependent. Because a GPU frame is
//! built rather than published headlessly, this run calls `App.framePresented`
//! itself once the frame has reached its target — the same call a real host
//! makes after a successful present. The host is still real, and it is pumped
//! on every iteration where this run is idle, which is safe precisely because
//! nothing is pending then.
//!
//! Run it: `zig build w17-anim-smoke [-- --native] [-- --ppm PATH]`.
const std = @import("std");
const Io = std.Io;

const sdl3 = @import("sdl3");
const noapi = @import("noapi");

const nogui = @import("nogui");
const host = @import("nogui_host");
const v7_frame = @import("v7_frame");
const renderer = @import("v7_render");

const animation = nogui.animation;
const preferences = host.preferences;
const diagnostics = host.diagnostics;
const paint = nogui.paint;
const frame_scene = v7_frame.scene;
const NativeFrame = v7_frame.NativeFrame;

const app_id: [:0]const u8 = "dev.nogui.w17animsmoke";
const window_title = "w17-anim-smoke";
const window_width: u32 = 480;
const window_height: u32 = 320;

/// The device image both paths write. The default path is 1:1 by
/// construction, and the presented path is required to observe the window it
/// was asked to open, so both report this extent.
const device_extent: noapi.Extent2D = .{ .width = window_width, .height = window_height };

/// The host's maximum spacing between animation frames. The demo window loop
/// passes the same value to `App.animationDemand`.
const interval_ms: u32 = 16;

/// A decorative sequence of 600 ms cannot finish on a handful of frames, so
/// a live run that reports fewer than this did not run: 600/16 is about 37
/// frames, and half that is still far above any outcome that is not a run.
/// It doubles as the bounded window the two-way gate check measures, where
/// an endless timeline has no idle state to drain to.
const minimum_live_frames: u32 = 20;

/// A runaway loop fails instead of spinning forever.
const frame_budget: u32 = 240;

/// Idle settle windows are counted in driver iterations, not frames: the
/// claim under test is that none of them publishes anything.
const short_settle: u32 = 8;
const long_settle: u32 = 64;

/// Sampled floats are f32 arithmetic on authored round numbers, so this only
/// has to absorb a rounding step, never a real disagreement. An
/// interruption that honoured the authored `spec.from` instead of the
/// sampled value misses it by hundreds.
const value_tolerance: f32 = 0.001;

/// Lane 0 is the authored channel. The App's built-in press and hover easing
/// own lanes 1 and 2, so an authored timeline here can never be confused
/// with the framework's own state.
const lane: u64 = 0;

// Authored animation pixels.

/// Where the authored channel rests. A run that never started anything, and a
/// run that snapped to its endpoint, are both measured against this scale.
const endpoint_value: f32 = 20;

/// The pulse bar rides this lane, in window-logical units, offset from the bar
/// element's own content origin. Every probe is a logical coordinate, so the
/// presented path and the windowless path read the same authored scene at
/// whatever device scale the window observed.
const track_left: f32 = 20;
const track_width: f32 = 440;
const band_top: f32 = 20;
const band_height: f32 = 40;
/// The bar starts strictly inside the track on both sides, so a measured
/// span is never the track's own antialiased edge.
const pulse_start: f32 = 30;
const pulse_width: f32 = 40;
const pulse_travel: f32 = 360;

/// The bar element is the first child of the root column, so its content
/// origin is the surface origin whatever the button and the label below it
/// measure to.
const bar_width: f32 = 480;
const bar_height: f32 = 200;

/// The background is authored in SCENE space, at exactly the value the Oklab
/// pass clears to, so every "nothing is painted here" probe has one known
/// value instead of an assumption.
const clear_fill: paint.Fill = .{ .solid = .{ .oklab = .{
    .l = frame_scene.oklab_clear[0],
    .a = frame_scene.oklab_clear[1],
    .b = frame_scene.oklab_clear[2],
    .alpha = frame_scene.oklab_clear[3],
} } };

/// The track the bar rides on. Painted on every frame from a constant, and
/// BRIGHTER than the clear, so "a column is painted" and "a column is the
/// bar" are two different questions with two different answers.
const track_l: f32 = 0.32;
/// The bar's lightness at the rest point and at the authored endpoint. The
/// bar is brighter than the track at every value it ever takes, including
/// the lowest.
const pulse_base_l: f32 = 0.45;
const pulse_span_l: f32 = 0.50;

/// Hard-edged axis-aligned rects over the clear: coverage there is exactly 0
/// or 1 and the blend is one f32 multiply-add, so this only has to absorb a
/// driver that stores the colour at reduced precision.
const pixel_tight: f32 = 0.01;
/// A measured column clears the track by this much to count as the bar. The
/// narrowest gap in this specimen is `pulse_base_l - track_l` = 0.13, so a
/// measured edge landing on 0.13 or on 0.19 gives the same answer.
const pulse_ink_margin: f32 = 0.06;
/// The device-pixel slack on a measured bar edge. The bar is 40 logical units
/// wide, so this absorbs the antialiased boundary column and nothing else.
/// Unsigned because that is what `@abs` hands back for a signed column
/// difference, and comparing the two has to have a type.
const edge_slack: u32 = 1;

/// How far the bar must travel in one published frame before "where it stood
/// is track again" is a question with an answer. A fifth of the bar's own
/// width leaves the vacated probe six logical units clear of the NEW bar's
/// antialiased boundary column, so the probe can never read the bar that just
/// arrived. Every frame of a live run clears this, so the claim below is made
/// on essentially every frame rather than only on a phase change.
const vacated_min_travel: f32 = 8;

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = [_]u8{0} ** 4096,

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// Print a measured value and hold the run to it. A number that is printed
/// and then not checked is not evidence, so a mismatch ends the process.
fn expectNear(
    report: *Reporter,
    label: []const u8,
    expected: f32,
    observed: f32,
) !void {
    const holds = @abs(expected - observed) <= value_tolerance;
    // The mismatch marker is a string literal passed as an argument, so it needs
    // a specifier: an untyped `""` is a zero-length slice and `{}` refuses to
    // format one.
    try report.emit("{s}: {d:.5} (expected {d:.5}){s}\n", .{
        label,
        observed,
        expected,
        if (holds) "" else "  <-- MISMATCH",
    });
    if (!holds) return error.AnimationSmokeClaimFailed;
}

/// Print a claim and hold the run to it. A pixel claim that is printed and
/// then not checked is a picture, not evidence.
fn expectClaim(report: *Reporter, label: []const u8, holds: bool) !void {
    try report.emit("{s}: {s}{s}\n", .{
        label,
        if (holds) "holds" else "FAILS",
        if (holds) "" else "  <-- MISMATCH",
    });
    if (!holds) return error.AnimationSmokeClaimFailed;
}

/// One Oklab channel, held to the tolerance a hard-edged solid rect over the
/// clear can actually miss by. The label carries the channel name because
/// these labels reach this function as runtime slices.
fn expectChannel(
    report: *Reporter,
    label: []const u8,
    channel: []const u8,
    expected: f32,
    observed: f32,
    tolerance: f32,
) !void {
    const holds = std.math.isFinite(observed) and @abs(expected - observed) <= tolerance;
    try report.emit("{s} {s}: {d:.5} (expected {d:.5} +-{d:.5}){s}\n", .{
        label,
        channel,
        observed,
        expected,
        tolerance,
        if (holds) "" else "  <-- MISMATCH",
    });
    if (!holds) return error.AnimationSmokeClaimFailed;
}

// ── the authored channel, as authored geometry and colour ───────────

/// Where the sampled value sits on the authored scale: 0 at the rest point,
/// 1 at the authored endpoint. The two authored specs below are checked
/// against `endpoint_value` at comptime, so editing one without the other is
/// a compile error rather than a run that quietly measures the wrong scale.
fn timelineFraction(value: f32) f32 {
    return std.math.clamp(value / endpoint_value, 0, 1);
}

/// The bar's left edge, in element-local units. Both the component's paint
/// and every readback probe call THIS, so the pixels are compared against the
/// geometry that was authored rather than against a second copy of it.
fn pulseLeft(value: f32) f32 {
    return pulse_start + timelineFraction(value) * pulse_travel;
}

/// The bar's Oklab lightness, likewise authored in one place.
fn pulseLightness(value: f32) f32 {
    return pulse_base_l + pulse_span_l * timelineFraction(value);
}

fn trackColor() paint.Color {
    return .{ .oklab = .{ .l = track_l, .a = 0, .b = 0, .alpha = 1 } };
}

fn pulseColor(value: f32) paint.Color {
    return .{ .oklab = .{ .l = pulseLightness(value), .a = 0, .b = 0, .alpha = 1 } };
}

/// What draw code observed. The smoke reads this after a frame, so a
/// reported value is one a component really sampled, not one the driver
/// computed for itself.
const Observation = struct {
    owner: ?nogui.WidgetId = null,
    value: ?f32 = null,
    /// The exact value the pulse bar was authored with this frame. It is the
    /// sample, or zero before the owner exists, and it is the number every
    /// pixel probe is predicted from.
    bar_value: f32 = 0,
    drawn: u32 = 0,

    fn sampled(self: *const Observation) !f32 {
        return self.value orelse error.MissingSampledValue;
    }
};

/// The one custom element: a track painted on every frame, and a bar over it
/// whose position and lightness are pure functions of the authored channel's
/// sampled value. It reads only its own payload, so the tree it lands in and
/// the pixels that come out are the same decision.
const PulseBar = struct {
    /// The value the component's draw code sampled this frame.
    value: f32,

    pub const PhaseState = struct {};

    pub fn measure(
        _: *const PulseBar,
        input: nogui.element.MeasureInput,
    ) nogui.element.Error!nogui.Size {
        return .{
            .width = input.known_dimensions.width orelse bar_width,
            .height = input.known_dimensions.height orelse bar_height,
        };
    }

    pub fn paint(
        self: *const PulseBar,
        _: *PhaseState,
        geometry: nogui.element.Geometry,
        writer: *nogui.element.PaintWriter,
    ) nogui.element.Error!void {
        const content = geometry.content;
        try writer.addRect(.{
            .bounds = .{
                .x = content.x + track_left,
                .y = content.y + band_top,
                .w = track_width,
                .h = band_height,
            },
            .fill = .{ .solid = trackColor() },
        });
        try writer.addRect(.{
            .bounds = .{
                .x = content.x + pulseLeft(self.value),
                .y = content.y + band_top,
                .w = pulse_width,
                .h = band_height,
            },
            .fill = .{ .solid = pulseColor(self.value) },
        });
    }
};

const View = struct {
    observation: *Observation,
    /// The pulse bar's node in the committed tree, so the readback can read
    /// the box layout actually gave it rather than the one that was asked for.
    bar: nogui.FrameNodeId = .root,

    pub fn draw(self: *View, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.column(.{
            .key = nogui.ComponentKey{ .static = "stage" },
            .gap = 8,
            .@"align" = .start,
            .width = bar_width,
            .height = @as(f32, @floatFromInt(window_height)),
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
            .fill = clear_fill,
        });
        defer ctx.pop();
        // The sample is taken before anything is authored, so the bar this
        // frame is painted from is the value draw code read, not a second
        // reading of the same registry.
        self.observation.value = if (self.observation.owner) |owner|
            ctx.animationValue(animation.Key{ .owner = owner, .lane = lane })
        else
            null;
        self.observation.bar_value = self.observation.value orelse 0;
        self.observation.drawn += 1;
        // The bar is the FIRST child, so its content box is the column's own
        // content origin whatever the button and the label below it measure
        // to. Every probe below is relative to the box layout gives it.
        self.bar = try ctx.elementLeaf(PulseBar, .{ .value = self.observation.bar_value }, .{
            .@"align" = .start,
            .width = bar_width,
            .height = bar_height,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
            .clip = true,
        });
        // The keyed widget that owns the animation. It is drawn on every
        // frame so its identity stays live for the whole run.
        _ = try ctx.button(.{
            .key = nogui.ComponentKey{ .static = "pulse" },
            .label = "pulse",
        });
        var line: [48]u8 = undefined;
        const text: []const u8 = std.fmt.bufPrint(&line, "pulse={d:.3}", .{
            self.observation.value orelse 0,
        }) catch "pulse=?";
        _ = try ctx.label(.{ .text = text });
    }
};

/// The demo window loop's gate, reduced to the two things that can start a
/// frame. `published` counts the frames this run actually asked the App to
/// build and publish, which is the number every claim below is about — and
/// every one of them is lowered, recorded and read back before the next
/// iteration, so a frame this run counts is a frame that reached the GPU.
const Driver = struct {
    app: *nogui.App,
    view: *View,
    endpoint: *Endpoint,
    report: *Reporter,
    now_ms: u64 = 0,
    tick: u32 = 0,
    published: u32 = 0,
    /// The evidence for the frame just published. The readback slice dies at
    /// the next submission, so it is copied out while it is still alive.
    last: ?Frame = null,
    /// The published frame whose authored position came closest to the middle
    /// of the band since `forgetMid`. A two-frame cut has no middle, which is
    /// why the mid claim is a claim and not a frame index.
    mid: ?Frame = null,
    /// Frames whose readback agreed with the value the component sampled, and
    /// those that did not. Both are counted on EVERY published frame, so a run
    /// that renders and never compares cannot pass.
    agree: u32 = 0,
    disagree: u32 = 0,
    /// Written from the readback of the very next published frame, because that
    /// slice does not survive a second submission.
    ppm: ?[]const u8 = null,

    /// Forget the mid-run sample, so the next phase's middle frame is its own.
    fn forgetMid(self: *Driver) void {
        self.mid = null;
    }

    /// The frame just published, as captured. A run that measured a transition
    /// has to say which frame it measured, so a missing capture is an error
    /// rather than a null the caller is expected to handle.
    fn lastFrame(self: *const Driver) !Frame {
        return self.last orelse error.MissingPublishedFrameEvidence;
    }

    /// One iteration. Returns false when the host has no reason to publish a
    /// frame any more, which is the idle condition under test.
    fn step(self: *Driver, host_app: *host.Application) !bool {
        const redraw = try self.app.session.takeRedraw(self.app.window);
        const demand = self.app.animationDemand(self.now_ms, interval_ms);
        if (!redraw and demand.deadline_ms == null) {
            // Nothing this App can do starts a frame. Pumping the host here
            // is safe exactly because no redraw is pending:
            // `Application.step` consumes the Session redraw itself, so a
            // host pump during a live run would silently eat a frame this
            // run is counting.
            _ = try host_app.step();
            return false;
        }
        self.now_ms = @max(self.now_ms + interval_ms, demand.deadline_ms orelse 0);
        self.tick += 1;
        // The endpoint owns the device and the surface; the App builds the
        // tree that lands in the target the endpoint's passes write. Opening
        // the recording first is what lets `frameWithGpuAtTime` dispatch the
        // component's own GPU hooks against it.
        try self.endpoint.beginFrame();
        errdefer self.endpoint.cancelFrame();
        // The one thing `handle(.frame)` does that the GPU entry point does
        // not, so the frame counts below stay the counts that path produces.
        try self.app.tickShortcuts();
        const out = try self.app.frameWithGpuAtTime(
            self.tick,
            self.now_ms,
            self.endpoint.surface(),
            self.endpoint.gpuFrame(),
        );
        defer if (out.json) |json| self.endpoint.gpa.free(json);
        const pixels = try self.endpoint.render(&out);
        // The frame is on the device, so the animation clock may advance. A
        // GPU host makes this call itself, after a successful present, and a
        // frame that never reached one must not move the clock.
        self.app.framePresented(self.now_ms);
        self.published += 1;
        try self.checkFrame(&out, pixels);
        return true;
    }

    /// The claim made on EVERY published frame: the pixels carry the value the
    /// component sampled, in the geometry and the colour it was authored with,
    /// and where the last frame's bar stood there is track again. A frame that
    /// fails this ends the run rather than waiting to be counted.
    fn checkFrame(self: *Driver, out: *const nogui.FrameOutput, pixels: []const f32) !void {
        const content = nogui.visualContentRect(out.tree, self.view.bar);
        const image: Image = .{
            .pixels = pixels,
            .extent = self.endpoint.extent,
            .scale = self.endpoint.scale,
        };
        const value = self.view.observation.bar_value;
        // Two logical units into the PREVIOUS bar's own body, and only when the
        // bar has travelled far enough that this probe is clear of the new one.
        const vacated_x: ?f32 = if (self.last) |previous|
            if (@abs(pulseLeft(value) - pulseLeft(previous.value)) > vacated_min_travel)
                content.x + pulseLeft(previous.value) + 2
            else
                null
        else
            null;
        const frame = try capture(image, content, value, vacated_x);

        const expected_first = expectedInkFirst(value, image.scale.x);
        const expected_last = expectedInkLast(value, image.scale.x);

        const failure: ?[]const u8 = if (!std.math.isFinite(frame.pulse[0]) or
            @abs(frame.pulse[0] - pulseLightness(value)) > pixel_tight)
            "the bar's centre lightness does not carry the sampled value"
        else if (!spanAgrees(value, image.scale.x, frame.ink_first, frame.ink_last))
            "the measured bar span does not match the authored geometry"
        else if (@abs(frame.track[0] - track_l) > pixel_tight)
            "the track beyond the bar is not the authored track"
        else if (@abs(frame.background[0] - frame_scene.oklab_clear[0]) > pixel_tight)
            "the background is not the value the Oklab pass clears to"
        else if (frame.vacated_x != null and @abs(frame.vacated[0] - track_l) > pixel_tight)
            "the previous frame's bar is still standing"
        else
            null;

        if (failure) |why| {
            self.disagree += 1;
            try self.report.emit(
                "frame {d} (value {d:.5}): {s}\n" ++
                    "  authored L={d:.5} span={d}..{d}; read back L={d:.5}" ++
                    " track={d:.5} vacated={d:.5} background={d:.5}" ++
                    " ink={d}..{d}\n",
                .{
                    self.tick,
                    value,
                    why,
                    pulseLightness(value),
                    expected_first,
                    expected_last,
                    frame.pulse[0],
                    frame.track[0],
                    frame.vacated[0],
                    frame.background[0],
                    frame.ink_first,
                    frame.ink_last,
                },
            );
            return error.PaintedFrameDisagreesWithTheSampledValue;
        }
        self.agree += 1;
        if (self.mid == null or
            @abs(frame.t - 0.5) < @abs(self.mid.?.t - 0.5))
        {
            self.mid = frame;
        }
        self.last = frame;
        if (self.ppm) |path| {
            self.ppm = null;
            try v7_frame.writePpm(
                self.endpoint.gpa,
                self.endpoint.io,
                path,
                pixels,
                self.endpoint.extent,
            );
            try self.report.emit("ppm written to {s} from the last published frame\n", .{path});
        }
    }

    /// Publish frames until the host is idle, and report how many that took.
    fn drain(self: *Driver, host_app: *host.Application) !u32 {
        const before = self.published;
        while (try self.step(host_app)) {
            if (self.published - before > frame_budget) {
                return error.AnimationFrameBudgetExceeded;
            }
        }
        return self.published - before;
    }

    /// Publish exactly `count` frames, for a claim about a value part way
    /// through a run rather than about reaching the end of one.
    fn run(self: *Driver, host_app: *host.Application, count: u32) !u32 {
        var done: u32 = 0;
        while (done < count) : (done += 1) {
            if (!try self.step(host_app)) return error.AnimationEndedEarly;
        }
        return count;
    }

    /// The "no frame loop is left running" claim, measured over a settle
    /// window. Zero published frames, no surviving animation demand, and zero
    /// further GPU submissions are all required. The last one is the
    /// interesting one: a host that asked for no frame and still submitted one
    /// is painting decorations nobody asked for.
    fn settle(
        self: *Driver,
        host_app: *host.Application,
        report: *Reporter,
        label: []const u8,
        iterations: u32,
    ) !void {
        const before = self.published;
        const submissions_before = self.endpoint.submitted;
        var taken: u32 = 0;
        while (taken < iterations) : (taken += 1) {
            if (try self.step(host_app)) break;
        }
        const painted = self.published - before;
        const submitted = self.endpoint.submitted - submissions_before;
        const demand = self.app.animationDemand(self.now_ms, interval_ms);
        try report.emit(
            "settle[{s}]: iterations={d} published_frames={d} gpu_submissions={d}" ++
                " demand_active={} demand_deadline={?d}\n",
            .{ label, iterations, painted, submitted, demand.active, demand.deadline_ms },
        );
        if (painted != 0) return error.AnimationFrameSurvivedIdleWindow;
        if (submitted != 0) return error.DecorativeFrameReachedTheGpu;
        if (demand.active or demand.deadline_ms != null) {
            return error.AnimationDemandSurvivedIdleWindow;
        }
    }
};

/// A two-step sequence repeated twice: the decorative entrance a component
/// authors, which the core contract tests only ever run against a bare
/// registry.
const sequence_spec: animation.Spec = .{
    .from = 0,
    .steps = &.{
        .{ .to = 10, .duration_ms = 100 },
        .{ .to = 20, .duration_ms = 200, .easing = .ease_in },
    },
    .repeat = .{ .count = 2 },
};

/// The same shape with no end. Under motion it never goes idle, which is
/// what makes it the honest subject for the in-flight gate test.
const forever_spec: animation.Spec = .{
    .from = 0,
    .steps = &.{
        .{ .to = 10, .duration_ms = 100 },
        .{ .to = 20, .duration_ms = 100 },
    },
    .repeat = .forever,
};

comptime {
    // The pixels are measured on a scale derived from `endpoint_value`, so an
    // authored endpoint that stops being `endpoint_value` is a compile error
    // here rather than a run that quietly measures a different scale than the
    // one it painted.
    if (sequence_spec.steps[sequence_spec.steps.len - 1].to != endpoint_value) {
        @compileError("sequence_spec's last step must end at endpoint_value");
    }
    if (forever_spec.steps[forever_spec.steps.len - 1].to != endpoint_value) {
        @compileError("forever_spec's last step must end at endpoint_value");
    }
    if (sequence_spec.from != 0 or forever_spec.from != 0) {
        @compileError("both authored specs start from the rest point");
    }
    // The bar has to stay strictly inside the track at both ends of its
    // travel, or a measured span would be measuring the track's own edge.
    if (pulse_start <= track_left) @compileError("the bar must start inside the track");
    if (pulse_start + pulse_travel + pulse_width >= track_left + track_width) {
        @compileError("the bar must finish inside the track");
    }
    // Every bar lightness must clear the track by more than the measured
    // margin, or a span scan could not tell the bar from the track.
    if (pulse_base_l - track_l <= pulse_ink_margin) {
        @compileError("the bar must be separable from the track");
    }
    // The track must be separable from the clear underneath it.
    if (track_l - frame_scene.oklab_clear[0] <= pulse_ink_margin) {
        @compileError("the track must be separable from the clear");
    }
}

// Pixel readback.

/// The Oklab target one submission wrote, addressed in the window-logical
/// coordinates the scene was authored in. Both paths are read the same way,
/// so a probe means the same thing whether or not a window is involved.
const Image = struct {
    pixels: []const f32,
    extent: noapi.Extent2D,
    /// Observed device pixels per logical unit. The windowless path is 1:1 by
    /// construction; a presented window is whatever it reported.
    scale: nogui.geometry.PixelScale,

    /// The L, a, b triple at a logical point, without the alpha the readback
    /// quad carries and no probe here reads.
    fn at(self: Image, logical_x: f32, logical_y: f32) ![3]f32 {
        const px = try probeColumn(logical_x * self.scale.x, self.extent.width);
        const py = try probeColumn(logical_y * self.scale.y, self.extent.height);
        const index = (@as(usize, @intCast(py)) * self.extent.width + @as(usize, @intCast(px))) * 4;
        return .{ self.pixels[index], self.pixels[index + 1], self.pixels[index + 2] };
    }

    /// The first and last device column of a logical row, from `from` to `to`,
    /// whose Oklab lightness clears `threshold`. Null when the row carries no
    /// such column at all, which is a different answer from an empty range.
    fn inkSpan(
        self: Image,
        logical_y: f32,
        from: f32,
        to: f32,
        threshold: f32,
    ) ![2]i32 {
        const first_column = try probeColumn(from * self.scale.x, self.extent.width);
        const last_column = try probeColumn(to * self.scale.x, self.extent.width);
        const row = try probeColumn(logical_y * self.scale.y, self.extent.height);
        var first: ?i32 = null;
        var last: ?i32 = null;
        var x = first_column;
        while (x <= last_column) : (x += 1) {
            const index = (@as(usize, @intCast(row)) * self.extent.width + @as(usize, @intCast(x))) * 4;
            if (self.pixels[index] > threshold) {
                if (first == null) first = x;
                last = x;
            }
        }
        if (first == null or last == null) return error.NoInkedColumnOnTheRow;
        return .{ first.?, last.? };
    }
};

/// One authored-logical coordinate becomes one device column, and a probe
/// outside the image is a mistake in this file rather than a clamped read.
fn probeColumn(logical: f32, extent: u32) !i32 {
    const value: i32 = @intFromFloat(@round(logical));
    if (value < 0 or value >= @as(i32, @intCast(extent))) {
        return error.ProbeOutsideTheTarget;
    }
    return value;
}

/// One published frame's pixel evidence, copied out before the readback slice
/// it came from dies. Every field is measured, none is predicted.
const Frame = struct {
    /// The exact value the component handed the bar element this frame.
    value: f32,
    /// Where that value sits on the authored scale, 0 at rest and 1 at the
    /// authored endpoint.
    t: f32,
    /// The bar element's own content box, as layout resolved it in
    /// window-logical units. Every probe below is relative to it, so this is
    /// the geometry the pixels were predicted against.
    box: nogui.Rect,
    /// The bar's centre and the track the bar rides on.
    pulse: [3]f32,
    track: [3]f32,
    /// Where the PREVIOUS frame's bar stood, and the background above the
    /// band where only the pass clear is.
    vacated: [3]f32,
    /// Set only when a vacated point was actually probed, so the claim below
    /// never compares a probe that was never taken.
    vacated_x: ?f32 = null,
    background: [3]f32,
    /// The measured device columns of the bar on the band's mid row. A row
    /// with no ink at all is `error.NoInkedColumnOnTheRow` rather than an
    /// empty pair, because "the bar is missing" and "the bar is narrower than
    /// the probe" are different questions and only one of them has no answer.
    ink_first: i32,
    ink_last: i32,
};

/// Read one frame's evidence out of its readback, relative to the bar element
/// box layout actually gave it. `vacated_x` is the previous bar's own body;
/// null means the bar did not travel far enough for the question to have an
/// answer.
fn capture(image: Image, content: nogui.Rect, value: f32, vacated_x: ?f32) !Frame {
    const mid_y = content.y + band_top + band_height / 2;
    const span = try image.inkSpan(
        mid_y,
        content.x + track_left + 4,
        content.x + track_left + track_width - 4,
        track_l + pulse_ink_margin,
    );
    return .{
        .value = value,
        .t = timelineFraction(value),
        .box = content,
        .pulse = try image.at(content.x + pulseLeft(value) + pulse_width / 2, mid_y),
        // Far to the right of where the bar ever reaches, and clear of the
        // track's own antialiased right edge.
        .track = try image.at(content.x + track_left + track_width - 6, mid_y),
        .vacated = if (vacated_x) |x| try image.at(x, mid_y) else [3]f32{ 0, 0, 0 },
        .vacated_x = vacated_x,
        .background = try image.at(content.x + bar_width / 2, content.y + 5),
        .ink_first = span[0],
        .ink_last = span[1],
    };
}

/// Print one frame's evidence, so a reader can see the two sides of the
/// agreement rather than only its verdict.
fn printFrame(report: *Reporter, label: []const u8, frame: Frame) !void {
    // A frame whose bar did not travel has no vacated point to report, and
    // printing the sentinel for one would read as a measured zero.
    var vacated_line: [24]u8 = undefined;
    const vacated_text: []const u8 = if (frame.vacated_x != null)
        std.fmt.bufPrint(&vacated_line, "{d:.5}", .{frame.vacated[0]}) catch "<unreadable>"
    else
        "not-probed";
    try report.emit(
        "{s}: value={d:.5} t={d:.4} bar_centre_L={d:.5} (authored {d:.5})" ++
            " track_L={d:.5} vacated_L={s} background_L={d:.5} ink={d}..{d}\n",
        .{
            label,
            frame.value,
            frame.t,
            frame.pulse[0],
            pulseLightness(frame.value),
            frame.track[0],
            vacated_text,
            frame.background[0],
            frame.ink_first,
            frame.ink_last,
        },
    );
}

/// The device column the bar's left edge should land on for a value at an
/// observed scale. Authored once, used by the per-frame check and by the named
/// phase claims, so the two cannot disagree.
fn expectedInkFirst(value: f32, scale: f32) i32 {
    return @intFromFloat(@round(pulseLeft(value) * scale));
}

fn expectedInkLast(value: f32, scale: f32) i32 {
    return expectedInkFirst(value, scale) +
        @as(i32, @intFromFloat(@round(pulse_width * scale))) - 1;
}

/// Whether a measured bar span is where the authored geometry puts it, with
/// the same slack the per-frame check uses. Authored once, so a named phase
/// claim can never be stricter or looser than the per-frame one.
fn spanAgrees(value: f32, scale: f32, first: i32, last: i32) bool {
    return @abs(first - expectedInkFirst(value, scale)) <= edge_slack and
        @abs(last - expectedInkLast(value, scale)) <= edge_slack;
}

/// Two frames that claim the same authored value must claim the same pixels.
/// Comparing the values alone would pass a run whose second rendering drew
/// something else, and this is the claim that says it did not.
fn expectSameBar(report: *Reporter, label: []const u8, first: Frame, second: Frame) !void {
    const holds = @abs(first.pulse[0] - second.pulse[0]) <= pixel_tight and
        @abs(first.track[0] - second.track[0]) <= pixel_tight and
        @abs(first.background[0] - second.background[0]) <= pixel_tight and
        first.ink_first == second.ink_first and
        first.ink_last == second.ink_last and
        first.box.w == second.box.w and first.box.h == second.box.h;
    try report.emit(
        "{s}: bar_centre_L {d:.5} vs {d:.5}, ink {d}..{d} vs {d}..{d}, track_L {d:.5} vs {d:.5}: {s}{s}\n",
        .{
            label,
            first.pulse[0],
            second.pulse[0],
            first.ink_first,
            first.ink_last,
            second.ink_first,
            second.ink_last,
            first.track[0],
            second.track[0],
            if (holds) "identical" else "DIFFERENT",
            if (holds) "" else "  <-- MISMATCH",
        },
    );
    if (!holds) return error.AnimationSmokeClaimFailed;
}

/// What the run actually reached: the mode, the backend the public loader
/// resolved, and the scope every pixel below is measured over. Printed after
/// SDL is up and the device exists, because a scope printed before that says
/// what was asked for rather than what happened.
fn printScope(
    report: *Reporter,
    endpoint: *Endpoint,
    managed: *host.ManagedWindow,
) !void {
    const gpu = endpoint.gpu();
    const info = diagnostics.queryGpu(gpu);
    const observed = managed.observed;
    try report.emit(
        "mode: {s}\n" ++
            "device: name={s} driver={s} software_emulation={}\n" ++
            "surfaces: {d} (window: visible={} logical={d}x{d} device={d}x{d})\n" ++
            "scope: target={d}x{d} scale={d}x{d} source={s} present={}\n",
        .{
            @tagName(endpoint.mode),
            orUnreported(info.device.name),
            orUnreported(info.device.driver),
            info.device.software_emulation,
            gpu.numSurfaces(),
            observed.visible,
            observed.size.width,
            observed.size.height,
            observed.pixels.width,
            observed.pixels.height,
            endpoint.extent.width,
            endpoint.extent.height,
            endpoint.scale.x,
            endpoint.scale.y,
            if (endpoint.mode == .presented) "swapchain image" else "offscreen Oklab target",
            endpoint.mode == .presented,
        },
    );
    // The surface count is the observation, not an intention: a non-zero value
    // in the windowless run would mean a surface exists that nothing here
    // described, and a zero value in the presented run would mean the window
    // has no image to present into.
    const windowless = endpoint.mode == .windowless;
    if (windowless != (gpu.numSurfaces() == 0)) {
        return error.SurfaceCountDoesNotMatchTheMode;
    }
    if (windowless) {
        // Nothing was shown, and every pixel below came out of a target this
        // run sized itself.
        if (observed.visible) return error.WindowVisibleInTheWindowlessRun;
        if (endpoint.extent.width != window_width or endpoint.extent.height != window_height) {
            return error.OffscreenTargetIsNotTheAuthoredExtent;
        }
        if (endpoint.scale.x != 1 or endpoint.scale.y != 1) {
            return error.OffscreenTargetIsNotOneToOne;
        }
    } else {
        if (!observed.visible) return error.NativeWindowIsNotVisible;
        if (observed.size.width != window_width or observed.size.height != window_height) {
            return error.NativeWindowIsNotTheAuthoredSize;
        }
    }
}

/// Compositor round trips spent waiting for the window to take the size and
/// the visibility this run asked for. A bound, not a timeout the run may
/// quietly grow past.
const window_polls: u32 = 32;

/// Let the compositor answer before any frame is published. Every window event
/// the pump delivers refreshes the host's own observation, so what comes back
/// afterwards is what the window really became and not what was requested.
/// A window that never settles ends the run here, before any pixel claim.
fn settleWindow(
    io: Io,
    application: *host.Application,
    managed: *host.ManagedWindow,
    report: *Reporter,
) !void {
    var polls: u32 = 0;
    while (polls < window_polls) : (polls += 1) {
        const observed = managed.observed;
        if (observed.visible and observed.size.width == window_width and
            observed.size.height == window_height)
        {
            try report.emit("window settled after {d} host polls\n", .{polls});
            return;
        }
        _ = try application.step();
        try Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real);
    }
    const observed = managed.observed;
    try report.emit(
        "window never took the requested size: visible={} logical={d}x{d} device={d}x{d}\n",
        .{
            observed.visible,
            observed.size.width,
            observed.size.height,
            observed.pixels.width,
            observed.pixels.height,
        },
    );
    return error.NativeWindowNeverSettled;
}

/// A backend that reports no name for its device describes nothing this run
/// measured, so the empty string is printed as a gap rather than as a name.
fn orUnreported(value: []const u8) []const u8 {
    return if (value.len == 0) "<unreported>" else value;
}

// Render endpoint.

/// A shader module read from disk, in the SPIR-V words the renderer and the
/// blit pair are created from.
const ShaderFile = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, file_path: []const u8) !ShaderFile {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Where the presented path's two blit modules come from when the command
/// line does not name them. Relative to the working directory, so a `--native`
/// run executes with the repo root as its cwd, as `w12_ime_smoke` already
/// requires. The windowless path presents nothing and never opens them.
const default_fullscreen_shader = "shaders/fullscreen_vert.spv";
const default_oklab_shader = "shaders/blit_oklab.spv";

const Shaders = struct {
    quad_vert: []const u32,
    quad_frag: []const u32,
    sort_comp: []const u32,
    fullscreen_vert: []const u32,
    blit_oklab: []const u32,
};

/// The ONE pipeline this run paints through, and the ONE endpoint the App
/// mounts. Whichever mode was chosen owns it, so the model below has no way
/// to render through anything else.
const Endpoint = struct {
    const Path = union(enum) {
        windowless: Windowless,
        presented: Presented,
    };

    gpa: std.mem.Allocator,
    io: Io,
    mode: Mode,
    path: Path,
    /// The host window this endpoint's presented path presents to. The
    /// windowless path never reads it: the dummy driver's window has no
    /// meaningful pixel extent, and borrowing one would be a lie.
    managed: *host.ManagedWindow,
    /// What the App lays the next frame out in, in window-logical units.
    logical: nogui.Size = .{ .width = @floatFromInt(window_width), .height = @floatFromInt(window_height) },
    /// Observed device pixels per logical unit.
    scale: nogui.geometry.PixelScale = .{ .x = 1, .y = 1 },
    /// The device image the last submission wrote.
    extent: noapi.Extent2D = .{ .width = 0, .height = 0 },
    /// Submissions, which is the count every idle claim is measured against.
    submitted: u32 = 0,
    /// Acquires the presented path's swapchain refused, or zero in the
    /// windowless path, which acquires nothing.
    acquire_retries: u32 = 0,

    fn init(
        gpa: std.mem.Allocator,
        io: Io,
        mode: Mode,
        managed: *host.ManagedWindow,
        shaders: Shaders,
    ) !*Endpoint {
        const self = try gpa.create(Endpoint);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .mode = mode,
            // SAFETY: the selected path initializes in place before any read.
            .path = undefined,
            .managed = managed,
        };
        // Both paths initialise IN PLACE: the scene scratch borrows the
        // renderer, the renderer borrows the device, and a moved copy would
        // leave every one of them holding the address of the original.
        switch (mode) {
            .windowless => {
                // SAFETY: Windowless.init initializes this branch before use.
                self.path = .{ .windowless = undefined };
                try Windowless.init(gpa, io, &self.path.windowless, shaders);
                // From here this endpoint OWNS the windowless device. Every
                // refusal, failure or unexpected success below releases it
                // through this one errdefer, so no path leaks a VkDevice and
                // no path tears the device down twice.
                errdefer self.path.windowless.deinit();
                self.extent = self.path.windowless.offscreen.extent();
                // The windowless path's OWN refusal, on this run's real device
                // and this run's real SDL window. The dummy driver has no
                // presentation to hand out, so SDL refuses to make the
                // platform surface and `initSdl` refuses with it: the
                // production error, through the production entry point, with
                // no stub standing in for the platform call. A surface that
                // DID appear would mean the device is holding one this run
                // never asked to keep.
                // SDL's dynamic Vulkan loader is the PRESENTED path's, and it
                // is deliberately not loaded here. Under `dummy` the loader
                // refuses with its own SDL error before any platform call is
                // made, which would replace the refusal this branch exists to
                // observe with a different one. The call below is SDL's real
                // platform entry point either way, and it is what answers.
                var windowless_surface: ?noapi.Surface = noapi.Surface.initSdl(
                    self.path.windowless.offscreen.gpu(),
                    @ptrCast(managed.native.sdl.value),
                    @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
                    .{ .extent = try deviceExtent(managed) },
                ) catch |err| switch (err) {
                    error.PlatformSurfaceCreationFailed => null,
                    else => |other| return other,
                };
                if (windowless_surface) |*created| {
                    created.deinit();
                    return error.WindowlessSurfaceUnexpectedlyCreated;
                }
                if (self.path.windowless.offscreen.gpu().numSurfaces() != 0) {
                    return error.RefusedSurfaceStillOnTheDevice;
                }
            },
            .presented => {
                // SAFETY: Presented.init initializes this branch before use.
                self.path = .{ .presented = undefined };
                try Presented.init(gpa, io, &self.path.presented, managed, shaders);
                self.extent = self.path.presented.adapter.targetExtent();
            },
        }
        return self;
    }

    /// The App must already have detached from `attach`.
    fn deinit(self: *Endpoint) void {
        const gpa = self.gpa;
        // The allocation goes back last, so the poisoning store at the end of
        // this function still lands in live memory.
        defer gpa.destroy(self);
        switch (self.path) {
            .windowless => |*w| w.deinit(),
            .presented => |*p| p.deinit(),
        }
        // SAFETY: resources are released and no caller may read the endpoint.
        self.* = undefined;
    }

    fn attach(self: *Endpoint) *nogui.GpuEndpoint {
        return switch (self.path) {
            .windowless => |*w| w.offscreen.endpoint(),
            .presented => |*p| p.adapter.gpuEndpoint(),
        };
    }

    /// The measure source this endpoint's OWN text engine provides, on
    /// either path. The App holds the returned value: there is no scope to
    /// enter and no ambient engine, so a measured label and the glyphs this
    /// endpoint rasterizes are one measurement on both paths.
    fn measurer(self: *Endpoint) nogui.layout.MeasureSource {
        return switch (self.path) {
            .windowless => |*w| w.text.measurer(),
            .presented => |*p| p.adapter.measurer(),
        };
    }

    fn gpu(self: *Endpoint) *noapi.Gpu {
        return switch (self.path) {
            .windowless => |*w| w.offscreen.gpu(),
            .presented => |*p| p.adapter.device(),
        };
    }

    fn surface(self: *const Endpoint) nogui.Size {
        return self.logical;
    }

    fn gpuFrame(self: *Endpoint) *nogui.GpuFrame {
        return switch (self.path) {
            .windowless => |*w| &w.gpu_frame,
            .presented => |*p| &p.frame.gpu_frame,
        };
    }

    /// Open this frame's recording. The presented path first asks the window
    /// what it is actually showing, so the frame is laid out in the observed
    /// geometry rather than the requested one.
    fn beginFrame(self: *Endpoint) !void {
        switch (self.path) {
            .windowless => |*w| try w.beginFrame(self.extent),
            .presented => |*p| try p.beginFrame(self, self.managed),
        }
    }

    /// Lower the committed tree, record it, submit it, and read the Oklab
    /// pixels back out of the target those passes wrote. The returned slice
    /// dies at the next submission.
    fn render(self: *Endpoint, out: *const nogui.FrameOutput) ![]const f32 {
        self.submitted += 1;
        return switch (self.path) {
            .windowless => |*w| try w.render(out),
            .presented => |*p| try p.render(out, self.managed),
        };
    }

    /// Discard a recording whose frame failed before the submission. Cheap and
    /// terminal either way, so it is also safe from an `errdefer`.
    fn cancelFrame(self: *Endpoint) void {
        switch (self.path) {
            .windowless => |*w| w.cancelFrame(),
            .presented => |*p| p.cancelFrame(),
        }
    }

    fn presentation(self: *const Endpoint) ?NativeFrame.Stats {
        return switch (self.path) {
            .windowless => null,
            .presented => |*p| p.adapter.stats,
        };
    }

    /// The windowless pipeline: the shared `v7_frame` scene lowering and text
    /// engine over a `v7_frame.Offscreen` target built from the public loader
    /// seam. No window surface, no swapchain, no present.
    const Windowless = struct {
        loader: v7_frame.SystemVulkanLoader,
        offscreen: v7_frame.Offscreen,
        text: v7_frame.TextEngine,
        gui: renderer.Renderer,
        scratch: frame_scene.SceneScratch,
        // SAFETY: Offscreen.beginFrame fills cmd before render or cancellation.
        cmd: noapi.CommandBuffer = undefined,
        // SAFETY: Offscreen.beginFrame fills gpu_frame before render.
        gpu_frame: nogui.GpuFrame = undefined,
        frame_index: u32 = 0,

        fn init(gpa: std.mem.Allocator, io: Io, self: *Windowless, shaders: Shaders) !void {
            // The loader stays open until every GPU made from its options is
            // gone, so it is closed after the offscreen target.
            self.loader = try v7_frame.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.offscreen = try v7_frame.Offscreen.init(.{
                .allocator = gpa,
                .io = io,
                .loader = self.loader.options(),
                .extent = device_extent,
                .app_name = "w17-anim-smoke",
            });
            errdefer self.offscreen.deinit();
            self.text = try v7_frame.TextEngine.init(gpa, self.offscreen.gpu(), &.{
                .{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") },
            });
            errdefer self.text.deinit();
            try self.text.setGlyphSlotLimit(frame_scene.glyph_material_ceiling);
            self.gui = try renderer.Renderer.init(
                self.offscreen.gpu(),
                shaders.quad_vert,
                shaders.quad_frag,
                shaders.sort_comp,
            );
            errdefer self.gui.deinit();
            // The same configuration the presented path's adapter uses, so a
            // pixel measured here is the same pixel there.
            self.gui.configure(.{
                .material_bda = self.text.materialBda(),
                .damp_chroma = true,
            });
            self.scratch = frame_scene.SceneScratch.init(gpa, &self.gui);
            self.frame_index = 0;
        }

        fn deinit(self: *Windowless) void {
            self.scratch.deinit();
            self.gui.deinit();
            self.text.deinit();
            self.offscreen.deinit();
            self.loader.close();
            // SAFETY: every owned resource is released before invalidation.
            self.* = undefined;
        }

        fn beginFrame(self: *Windowless, extent: noapi.Extent2D) !void {
            try self.offscreen.resize(extent);
            try self.offscreen.beginFrame(self.frame_index, &self.cmd, &self.gpu_frame);
            self.frame_index = (self.frame_index + 1) %
                @as(u32, self.offscreen.gpu().frames_in_flight);
        }

        /// The whole submission stage: the same lowering and the same record
        /// the presented path uses, with no window in sight.
        fn render(self: *Windowless, out: *const nogui.FrameOutput) ![]const f32 {
            errdefer self.cancelFrame();
            self.scratch.beginFrame();
            var painted = try frame_scene.buildFrameScene(&self.scratch, &self.text, .{}, out, false);
            defer painted.deinit();
            const device = self.offscreen.extent();
            const record: frame_scene.RecordContext = .{
                .arena = out.tree.allocator,
                .renderer = &self.gui,
                .text = &self.text,
                .logical = .{
                    .width = @floatFromInt(device.width),
                    .height = @floatFromInt(device.height),
                },
                .device = device,
                .texture_heap = self.offscreen.heap().handle,
                .clips = out.tree.clip_rects[0..out.tree.clip_count],
            };
            _ = try frame_scene.recordFrameScene(
                &record,
                &self.cmd,
                &self.scratch,
                self.scratch.rects.items,
                &painted,
                self.offscreen.target(),
            );
            return self.offscreen.submitRead(&self.gpu_frame);
        }

        fn cancelFrame(self: *Windowless) void {
            if (self.gpu_frame.recording != .active) return;
            self.gpu_frame.cancelRecording() catch
                @panic("w17 animation smoke recording cancellation failed");
        }
    };

    /// The presented pipeline: the SAME scene lowering and the SAME text
    /// engine, over `v7_frame.NativeFrame`, into a real window's swapchain
    /// image. The readback still comes out of the Oklab target those same
    /// passes wrote, so every pixel reported is one the PRESENTED frame drew.
    ///
    /// TEARDOWN ORDER, which this value owns: the App detaches from the
    /// endpoint first (the caller does that), then the adapter, then the
    /// surface, then the device, then this path's loader, and only then the
    /// window and SDL. The swapchain and the platform surface live on the
    /// device AND reference the native window, so nothing device-side may
    /// outlive the window it presents to.
    const Presented = struct {
        /// The frame module's own loader, the same one the windowless path
        /// builds its device from, so both halves of this run resolve their
        /// entry points the same way.
        loader: v7_frame.SystemVulkanLoader,
        gpu: noapi.Gpu,
        /// The platform surface `noapi.Surface.initSdl` created from the SDL
        /// window and adopted. It owns the `VkSurfaceKHR` on the way out, so
        /// no SDL wrapper is kept beside it: there is no second owner of one
        /// handle.
        surface: noapi.Surface,
        adapter: NativeFrame,
        // SAFETY: NativeFrame.beginFrame fills this before render or cancellation.
        frame: NativeFrame.Frame = undefined,

        fn init(
            gpa: std.mem.Allocator,
            io: Io,
            self: *Presented,
            managed: *host.ManagedWindow,
            shaders: Shaders,
        ) !void {
            // The endpoint does NOT own the window. The host does, and the
            // caller closes that window only after this endpoint has released
            // the device its swapchain and platform surface live on.
            // The loader stays open until every GPU made from its options is
            // gone, so it closes after the surface and the device.
            self.loader = try v7_frame.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.gpu = try noapi.Gpu.init(.{
                // Three, not two: the renderer rings its per-frame paint
                // buffers over three slots, one per in-flight frame.
                .frames_in_flight = frame_scene.frames_in_flight,
                .app_name = "w17-anim-smoke",
                .validation = false,
                .loader = self.loader.options(),
                .io = io,
                .allocator = gpa,
            });
            errdefer self.gpu.deinit();
            // SDL's own Vulkan subsystem, for the platform surface call and
            // nothing else: on Wayland `SDL_Vulkan_CreateSurface` refuses with
            // "Vulkan is not loaded" unless this has run. The device above is
            // built from the frame module's loader, not from this one.
            try sdl3.vulkan.loadLibrary(null);
            // One call hands the window to the platform and takes the surface
            // back: the instance and the platform handle never leave noapi,
            // and a failed call destroys what the platform made.
            self.surface = try noapi.Surface.initSdl(
                &self.gpu,
                @ptrCast(managed.native.sdl.value),
                @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
                .{ .extent = try deviceExtent(managed) },
            );
            errdefer self.surface.deinit();
            try self.adapter.init(.{
                .allocator = gpa,
                .gpu = &self.gpu,
                .fonts = &.{.{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") }},
                .shaders = .{
                    .quad_vert = shaders.quad_vert,
                    .quad_frag = shaders.quad_frag,
                    .sort_comp = shaders.sort_comp,
                    .fullscreen_vert = shaders.fullscreen_vert,
                    .blit_oklab = shaders.blit_oklab,
                },
                .name = "w17_anim_smoke_blit_oklab",
            });
        }

        /// The App must already have detached from `adapter.gpuEndpoint()`.
        fn deinit(self: *Presented) void {
            self.adapter.deinit();
            // Before the device: the swapchain and the platform surface live
            // on it, and the platform surface references the native window.
            self.surface.deinit();
            // The count is read while the device is still alive: releasing
            // the surface is what has to take the device's surface back off,
            // and a device that still holds one outlived its own window.
            if (self.gpu.numSurfaces() != 0) {
                @panic("w17 animation smoke left a surface on the device after the window went");
            }
            self.gpu.deinit();
            // The loader outlives every device made from it, so it closes last.
            self.loader.close();
            // SAFETY: every owned resource is released before invalidation.
            self.* = undefined;
        }

        fn cancelFrame(self: *Presented) void {
            self.adapter.cancelFrame(&self.frame) catch |err| switch (err) {
                error.FrameNotRecording => {},
                else => @panic("w17 animation smoke presented cancellation failed"),
            };
        }

        /// Ask the window what it is showing and take the viewport that
        /// answers, then acquire the next image. A swapchain that is out of
        /// date is not a failure: the adapter is asked again, bounded, so a
        /// driver that never settles fails the run instead of spinning.
        fn beginFrame(self: *Presented, owner: *Endpoint, managed: *host.ManagedWindow) !void {
            const observed = managed.observed;
            owner.logical = .{
                .width = @floatFromInt(observed.size.width),
                .height = @floatFromInt(observed.size.height),
            };
            owner.scale = try observed.pixelScale();
            var attempts: u32 = 0;
            while (attempts < acquire_polls) : (attempts += 1) {
                const viewport: NativeFrame.Viewport = .{
                    .logical = .{ .width = owner.logical.width, .height = owner.logical.height },
                    .device = try deviceExtent(managed),
                    .scale = owner.scale,
                };
                if (try self.adapter.beginFrame(&self.surface, viewport, &self.frame)) {
                    // Both passes size themselves to the image the driver
                    // handed out, so that image — not the requested window
                    // pixel size — is what the readback is measured against.
                    owner.extent = self.frame.image;
                    return;
                }
                owner.acquire_retries += 1;
            }
            return error.SwapchainNeverSettled;
        }

        /// The App's tree, the Oklab pass, the blit and the present are ONE
        /// event: a frame this run counts is a frame whose pixels reached the
        /// swapchain image. The readback that follows is out of the Oklab
        /// target those same passes wrote.
        fn render(
            self: *Presented,
            out: *const nogui.FrameOutput,
            managed: *host.ManagedWindow,
        ) ![]const f32 {
            errdefer self.cancelFrame();
            var painted = try self.adapter.buildScene(.{}, out);
            defer painted.deinit();
            try self.adapter.recordScene(&self.surface, &self.frame, out, &painted);
            // `present` closes the recording itself, so a present that fails
            // must propagate its own error rather than reach a cancellation of
            // a recording that is gone.
            try self.adapter.present(&self.surface, &self.frame);
            managed.markPresented();
            return self.adapter.readTarget();
        }
    };
};

/// Compositor round trips and acquires, both bounds rather than timeouts a run
/// may quietly grow past.
const acquire_polls: u32 = 8;

/// The window's own pixel extent, read from the platform rather than assumed.
/// The driver may clamp the image it hands back, and both passes size
/// themselves to that image instead.
fn deviceExtent(managed: *host.ManagedWindow) !noapi.Extent2D {
    const pixels = try managed.native.pixelExtent();
    return .{ .width = pixels.width, .height = pixels.height };
}

/// Which pipeline this run paints through. `--native` picks `presented`; the
/// default is `windowless`, which opens no visible window and makes no
/// surface.
const Mode = enum { windowless, presented };

const Options = struct {
    native: bool = false,
    fullscreen: ?[]const u8 = null,
    oklab: ?[]const u8 = null,
    ppm: ?[]const u8 = null,

    fn fullscreenPath(self: Options) []const u8 {
        return self.fullscreen orelse default_fullscreen_shader;
    }

    fn oklabPath(self: Options) []const u8 {
        return self.oklab orelse default_oklab_shader;
    }

    fn mode(self: Options) Mode {
        return if (self.native) .presented else .windowless;
    }

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        if (self.fullscreen) |path| gpa.free(path);
        if (self.oklab) |path| gpa.free(path);
        if (self.ppm) |path| gpa.free(path);
        self.* = undefined;
    }
};

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    var options: Options = .{};
    errdefer options.deinit(gpa);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            // Opt-in because it is the only path that opens a window and
            // attaches a buffer to it on the session's display server.
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            if (options.ppm != null) return error.RepeatedOutputPath;
            options.ppm = try gpa.dupe(u8, args.next() orelse return error.MissingOutputPath);
        } else if (std.mem.eql(u8, arg, "--fullscreen-vert")) {
            if (options.fullscreen != null) return error.RepeatedShaderPath;
            options.fullscreen = try gpa.dupe(u8, args.next() orelse return error.MissingShaderPath);
        } else if (std.mem.eql(u8, arg, "--blit-oklab")) {
            if (options.oklab != null) return error.RepeatedShaderPath;
            options.oklab = try gpa.dupe(u8, args.next() orelse return error.MissingShaderPath);
        } else return error.UnknownArgument;
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var options = try parseArgs(gpa, init);
    defer options.deinit(gpa);

    var report: Reporter = .{ .io = io };
    try report.emit("W17 authored animation smoke\n", .{});

    var vert = try ShaderFile.load(gpa, io, "shaders/quad_vert.spv");
    defer vert.deinit(gpa);
    var frag = try ShaderFile.load(gpa, io, "shaders/quad_frag.spv");
    defer frag.deinit(gpa);
    var sort = try ShaderFile.load(gpa, io, "shaders/sort_comp.spv");
    defer sort.deinit(gpa);
    // Only the presented path records a blit, so only it opens the two
    // modules that blit is drawn with. Both owners are released by ONE defer
    // registered HERE, at function scope, because `Endpoint.init` below reads
    // their SPIR-V: a `defer` inside the `if` below would free both at the
    // closing brace, which is fifty lines before the reader runs. This defer
    // is registered before the endpoint's, so it unwinds after it — the
    // adapter that reads these words is always released first.
    // SAFETY: only the native branch writes these two, and only that branch
    // reads or frees them, so no path reads either before it is written.
    var fullscreen: ShaderFile = undefined;
    // SAFETY: as fullscreen, above.
    var oklab: ShaderFile = undefined;
    if (options.native) {
        fullscreen = try ShaderFile.load(gpa, io, options.fullscreenPath());
        // A second load that fails still releases the owner it already has.
        errdefer fullscreen.deinit(gpa);
        oklab = try ShaderFile.load(gpa, io, options.oklabPath());
        errdefer oklab.deinit(gpa);
    }
    // Reached only after both loads above returned, and only on the branch
    // that wrote both owners.
    defer if (options.native) {
        fullscreen.deinit(gpa);
        oklab.deinit(gpa);
    };

    // The host owns SDL, so the window, the Session and the App are the same
    // objects a shipping binary uses. The video driver is chosen BEFORE SDL
    // video is initialized, and that is what makes the default safe: without
    // `--native` the host is told to take SDL's windowless driver, so a run on
    // a machine with a desktop session never reaches that session. With
    // `--native` the hint is left alone and the session decides.
    var session = try nogui.Session.init(gpa);
    var session_live = true;
    defer if (session_live) session.deinit() catch
        @panic("W17 animation smoke error path left the Session live");
    var application = try host.Application.init(gpa, &session, .{
        .app_id = app_id,
        .restart = .never,
        .video_driver = if (options.native) null else "dummy",
    });
    var application_live = true;
    defer if (application_live) application.deinit();

    // The default opens its window HIDDEN and asks for no GPU surface, so
    // there is nothing on screen and nothing for a platform to composite: the
    // pixels below come out of a windowless target. `--native` is the only
    // path that asks for a visible window and a Vulkan surface.
    const handle = try application.openWindow(.{
        .title = window_title,
        .width = window_width,
        .height = window_height,
        .visible = options.native,
        .gpu_surface = options.native,
    });
    var window_open = true;
    defer if (window_open) {
        _ = application.closeWindow(handle) catch |err| {
            report.emit("teardown close: {s}\n", .{@errorName(err)}) catch
                @panic("W17 animation smoke could not report the teardown close failure");
        };
    };

    const managed = try application.getWindow(handle);
    const app = managed.app;

    var observation: Observation = .{};
    var view: View = .{ .observation = &observation };
    try app.mountRoot(View, &view);
    // The measure source is bound AFTER the endpoint exists, because the
    // source is the endpoint's own text engine bound to that engine's stable
    // address. A measured label and a painted glyph are one measurement on
    // either path, and the App holds the value instead of naming a hook that
    // some scope has to remember.

    const endpoint = try Endpoint.init(gpa, io, options.mode(), managed, .{
        .quad_vert = vert.words,
        .quad_frag = frag.words,
        .sort_comp = sort.words,
        .fullscreen_vert = if (options.native) fullscreen.words else &[_]u32{},
        .blit_oklab = if (options.native) oklab.words else &[_]u32{},
    });
    // ORDERED TEARDOWN, and it is the only order in which nothing device-side
    // outlives the window it presents to: the App's GPU mounts, then the
    // endpoint, then its surface, its device and its loader, and only then the
    // window and SDL. This runs on the error path; the shutdown at the end of
    // the run does the same work in the same order and clears the flag.
    var endpoint_live = true;
    defer if (endpoint_live) {
        app.detachGpu();
        endpoint.deinit();
    };
    try app.attachGpu(endpoint.attach());
    app.measure = endpoint.measurer();

    // Everything above is a decision. What follows is a measurement, and the
    // mode, the backend the public loader actually resolved and the scope that
    // measurement covers are reported only after SDL is up, the device exists
    // and one real frame has been presented — a scope printed before that says
    // what was asked for rather than what happened.
    try report.emit("video driver: {s}\n", .{
        sdl3.video.getCurrentDriverName() orelse "<null>",
    });
    // The presented path has to let the compositor answer before it asks for
    // a frame, and the host pump consumes the Session redraw — which is
    // exactly why the driver never pumps while a run is live. The default
    // path has no compositor to wait for and is never asked.
    if (options.native) try settleWindow(io, &application, managed, &report);

    var driver: Driver = .{
        .app = app,
        .view = &view,
        .endpoint = endpoint,
        .report = &report,
    };
    // The first frame is what mints the keyed identity the animation is
    // owned by, so it is asked for the way a host asks for its first paint
    // instead of waited for.
    try app.session.requestRedraw(app.window);
    const first_frames = try driver.drain(&application);
    const rest = try driver.lastFrame();
    // The device, the surface count and the window's own geometry are all
    // observations now, so they are reported here rather than earlier.
    try printScope(&report, endpoint, managed);
    // The PPM is armed only now, so it is written from the LAST published
    // frame rather than from this one.
    driver.ppm = options.ppm;
    try report.emit("first frame: published={d} drawn={d}\n", .{
        first_frames,
        observation.drawn,
    });
    if (first_frames != 1) return error.MissingFirstFrame;
    if (observation.drawn != 1) return error.RootNotDrawn;
    observation.owner = app.widgetIdForKey(.root, .{ .static = "pulse" }) orelse
        return error.MissingAnimationOwner;
    const key: animation.Key = .{ .owner = observation.owner.?, .lane = lane };
    try report.emit("animation owner: {any} lane={d}\n", .{ observation.owner.?, lane });

    // Nothing is authored yet, so this frame is the REST point: the bar sits
    // at the start of its travel, at the lightness that start implies, on a
    // track that is brighter than the background under it. The bar element is
    // checked to occupy exactly the box it asked for at the surface origin,
    // because every probe below is relative to that box.
    try printFrame(&report, "rest", rest);
    try expectClaim(
        &report,
        "the bar element owns exactly its authored box at the surface origin",
        rest.box.x == 0 and rest.box.y == 0 and
            rest.box.w == bar_width and rest.box.h == bar_height,
    );
    try expectChannel(&report, "rest bar centre", "L", pulseLightness(0), rest.pulse[0], pixel_tight);
    try expectChannel(&report, "rest track", "L", track_l, rest.track[0], pixel_tight);
    try expectChannel(
        &report,
        "rest background is the Oklab clear",
        "L",
        frame_scene.oklab_clear[0],
        rest.background[0],
        pixel_tight,
    );
    try expectChannel(
        &report,
        "rest background is the Oklab clear",
        "b",
        frame_scene.oklab_clear[2],
        rest.background[2],
        pixel_tight,
    );
    try expectClaim(
        &report,
        "the rest bar is where the authored geometry puts it",
        spanAgrees(0, endpoint.scale.x, rest.ink_first, rest.ink_last),
    );

    // ── A: motion allowed ────────────────────────────
    // No preference is observed, so the gate must be open before anything
    // below means anything.
    preferences.setApplicationReducedMotion(null);
    try preferences.applyReducedMotion(app, driver.now_ms);
    try report.emit("phase A gate: reduced_motion={} preference={?s}\n", .{
        app.reducedMotion(),
        if (preferences.getReducedMotion()) |observed| @tagName(observed) else null,
    });
    if (app.reducedMotion()) return error.GateStuckOnWithoutPreference;

    // A1: a two-step sequence repeated twice runs to its endpoint and then
    // the host is idle. A gate that suppressed this would report a frame
    // count of one; a gate that let it loop would never return.
    //
    // The first published frame is taken on its own, because it is the
    // transition: the bar is already off the rest point. It is the SAME
    // sequence of driver steps a single `drain` would take, so the frame
    // count below is unchanged by looking at it.
    driver.forgetMid();
    const a1_before = driver.published;
    const a1_start = driver.now_ms;
    try app.startAnimation(key, sequence_spec, a1_start);
    _ = try driver.run(&application, 1);
    const a1_first = try driver.lastFrame();
    _ = try driver.drain(&application);
    const a1_frames = driver.published - a1_before;
    const a1_mid = driver.mid orelse return error.NoMidRunFrame;
    const a1_end = try driver.lastFrame();
    try report.emit("A1 sequence x2: frames={d} span_ms={d} value={d:.5}\n", .{
        a1_frames,
        driver.now_ms - a1_start,
        try observation.sampled(),
    });
    if (a1_frames < minimum_live_frames) return error.AnimationRanTooFewFrames;
    try expectNear(&report, "A1 endpoint", endpoint_value, try observation.sampled());
    // The transition, read off the three published frames rather than off the
    // model: the bar left the rest point, passed through the middle of its
    // travel, and arrived at the end — moving right and brightening, in the
    // same direction, on the same run.
    try printFrame(&report, "A1 first", a1_first);
    try printFrame(&report, "A1 mid", a1_mid);
    try printFrame(&report, "A1 endpoint", a1_end);
    try expectClaim(
        &report,
        "A1 first frame has left the rest point but not the start of its travel",
        a1_first.t > 0 and a1_first.t <= 0.1,
    );
    try expectClaim(
        &report,
        "A1 has a genuine middle frame",
        @abs(a1_mid.t - 0.5) <= 0.05,
    );
    try expectClaim(
        &report,
        "A1 moved the bar right through the run, monotonically",
        a1_first.ink_first < a1_mid.ink_first and
            a1_mid.ink_first < a1_end.ink_first,
    );
    try expectClaim(
        &report,
        "A1 brightened the bar through the run, monotonically",
        a1_first.pulse[0] < a1_mid.pulse[0] and a1_mid.pulse[0] < a1_end.pulse[0],
    );
    try expectChannel(
        &report,
        "A1 endpoint bar centre is the lightness the endpoint implies",
        "L",
        pulseLightness(endpoint_value),
        a1_end.pulse[0],
        pixel_tight,
    );
    try expectClaim(
        &report,
        "A1 endpoint bar is where the authored geometry puts it",
        spanAgrees(endpoint_value, endpoint.scale.x, a1_end.ink_first, a1_end.ink_last),
    );
    try driver.settle(&application, &report, "A1", short_settle);

    // A2: an interruption continues from the value the user could see. The
    // authored `from` is deliberately absurd, so a plan that honoured it
    // instead of the sample would land near -947 rather than near 0.08.
    try app.startAnimation(key, .{
        .from = 0,
        .steps = &.{.{ .to = 1, .duration_ms = 1000 }},
    }, driver.now_ms);
    _ = try driver.run(&application, 5);
    const before_interrupt = try observation.sampled();
    try app.interruptAnimation(key, .{
        .from = -1000,
        .steps = &.{.{ .to = 0, .duration_ms = 300 }},
    }, driver.now_ms);
    _ = try driver.run(&application, 1);
    try expectNear(
        &report,
        "A2 interruption continues from the sampled value",
        before_interrupt * @as(f32, @floatFromInt(300 - interval_ms)) / 300,
        try observation.sampled(),
    );
    const a2_frames = try driver.drain(&application);
    try report.emit("A2 interrupted run: frames_to_idle={d} value={d:.5}\n", .{
        a2_frames,
        try observation.sampled(),
    });
    if (a2_frames < 2) return error.InterruptedRunEndedEarly;
    try expectNear(&report, "A2 interruption endpoint", 0, try observation.sampled());
    try driver.settle(&application, &report, "A2", short_settle);

    // A3: the desktop turns reduced motion on while a forever repeat is in
    // flight. Nothing tells the component to stop; the bridge does. The run
    // must end on exactly one terminal frame, painted at the authored
    // endpoint.
    try app.startAnimation(key, forever_spec, driver.now_ms);
    const a3_live = try driver.run(&application, 6);
    const a3_live_value = try observation.sampled();
    preferences.setApplicationReducedMotion(.reduce);
    try preferences.applyReducedMotion(app, driver.now_ms);
    if (!app.reducedMotion()) return error.PreferenceDidNotReachApp;
    const a3_after = try driver.drain(&application);
    const a3_end = try driver.lastFrame();
    try report.emit(
        "A3 forever repeat, gate raised in flight: live_frames={d} live_value={d:.5}" ++
            " frames_after_gate={d} value_after_gate={d:.5}\n",
        .{ a3_live, a3_live_value, a3_after, try observation.sampled() },
    );
    if (a3_after != 1) return error.InFlightGateFrameCountWrong;
    try expectNear(&report, "A3 snapped to the authored endpoint", endpoint_value, try observation.sampled());
    try printFrame(&report, "A3 endpoint", a3_end);
    try expectChannel(
        &report,
        "A3 endpoint bar centre is the lightness the endpoint implies",
        "L",
        pulseLightness(endpoint_value),
        a3_end.pulse[0],
        pixel_tight,
    );
    // The one terminal frame is the frame that painted the endpoint, and it
    // painted the same pixels the animated run ended on.
    try expectSameBar(&report, "A3 endpoint against the motion endpoint", a1_end, a3_end);
    try driver.settle(&application, &report, "A3", long_settle);

    // ── B: the gate is already on when the animation is authored ───────
    // This is the claim a source read cannot make for itself: a decorative
    // animation started under reduced motion costs one frame, the frame
    // that paints its endpoint, and never another.
    try report.emit("phase B gate: reduced_motion={} preference={s}\n", .{
        app.reducedMotion(),
        @tagName(preferences.getReducedMotion() orelse return error.PreferenceLost),
    });
    try app.startAnimation(key, forever_spec, driver.now_ms);
    const b_frames = try driver.drain(&application);
    const b_end = try driver.lastFrame();
    try report.emit("B decorative forever repeat under the gate: frames={d} value={d:.5}\n", .{
        b_frames,
        try observation.sampled(),
    });
    if (b_frames != 1) return error.GatedAnimationFrameCountWrong;
    try expectNear(&report, "B endpoint painted once", endpoint_value, try observation.sampled());
    try printFrame(&report, "B endpoint", b_end);
    try expectChannel(
        &report,
        "B endpoint bar centre is the lightness the endpoint implies",
        "L",
        pulseLightness(endpoint_value),
        b_end.pulse[0],
        pixel_tight,
    );
    // A gate that snapped the value to the endpoint but painted something
    // else would still pass every count above, and this is where it fails.
    try expectSameBar(&report, "B endpoint against the motion endpoint", a1_end, b_end);
    try driver.settle(&application, &report, "B", long_settle);

    // ── C: the gate is a two-way switch, not a latch ───────────────────
    // Phase B proved the gate stops a loop. This proves the same App can
    // start one again, so phase B was a gate and not a dead window.
    preferences.setApplicationReducedMotion(null);
    try preferences.applyReducedMotion(app, driver.now_ms);
    if (app.reducedMotion()) return error.GateStuckOnAfterPreferenceCleared;
    // The parked timeline is a forever repeat, so with the gate open it has
    // no end to drain to. This measures a bounded window instead, and `run`
    // fails if the host stopped asking for frames early.
    const c_frames = try driver.run(&application, minimum_live_frames);
    try report.emit("C gate lowered on a parked forever repeat: frames={d} value={d:.5}\n", .{
        c_frames,
        try observation.sampled(),
    });

    // The run must finish parked, so the last thing it does is raise the
    // gate again and prove the host settles for good.
    preferences.setApplicationReducedMotion(.reduce);
    try preferences.applyReducedMotion(app, driver.now_ms);
    if (!app.reducedMotion()) return error.PreferenceDidNotReachApp;
    const c_park = try driver.drain(&application);
    try report.emit("C gate raised again: park_frames={d}\n", .{c_park});
    try driver.settle(&application, &report, "C", long_settle);

    try report.emit(
        "totals: published_frames={d} gpu_submissions={d} clock_ms={d} reduced_motion={}\n" ++
            "pixels: frames_compared={d} agreed={d} disagreed={d}\n",
        .{
            driver.published,
            endpoint.submitted,
            driver.now_ms,
            app.reducedMotion(),
            driver.agree + driver.disagree,
            driver.agree,
            driver.disagree,
        },
    );
    // Every published frame reached the GPU and every one of them was read
    // back and compared, and a single disagreement has already ended the run.
    if (endpoint.submitted != driver.published) {
        return error.PublishedFramesDidNotReachTheGpu;
    }
    if (driver.agree != driver.published) return error.AFrameWasNeverCompared;
    if (endpoint.presentation()) |stats| {
        try report.emit(
            "present: {d} committed, {d} presented, {d} acquire retries," ++
                " {d} swapchains rebuilt, {d} extent mismatches, {d} out of date\n",
            .{
                stats.frames_committed,
                stats.frames_presented,
                endpoint.acquire_retries,
                stats.swapchains_recreated,
                stats.extent_mismatches,
                stats.present_out_of_date,
            },
        );
        if (stats.frames_presented != driver.published) {
            return error.PresentDidNotFollowEveryFrame;
        }
    }

    // The same order, taken explicitly so the endpoint is released while the
    // window it presents to is still alive.
    app.detachGpu();
    endpoint.deinit();
    endpoint_live = false;
    const closed = try application.closeWindow(handle);
    _ = try application.step();
    window_open = false;
    application.deinit();
    application_live = false;
    const released = session.deinit();
    session_live = false;
    try report.emit(
        "shutdown: endpoint released, closeWindow={} Application.deinit ok," ++
            " Session.deinit={s}\n",
        .{
            closed,
            if (released) |_| "<accepted>" else |err| @errorName(err),
        },
    );
    try report.emit("W17 authored animation smoke done\n", .{});
}
