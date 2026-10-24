//! W07 native host smoke — two real windows, one shared model, external loop.
//!
//! The demo's own modes (`--window`, `--spotify`, `--gpu-remount-smoke`, …)
//! are single-window and stay in `Application.run`-shaped loops. This binary
//! exists only to drive the W07 host gate: two simultaneous native windows on
//! the session's real display server, one `Session` model mounted into both
//! Apps, frames committed through the public API, resize/minimize/restore,
//! a close veto, last-window-close kept distinct from application quit, and
//! a clean `Session.deinit()`.
//!
//! It drives the host as an EXTERNAL loop: `Application.step()` plus
//! `Application.nextWaitMilliseconds()` and `Application.pollEvent()` /
//! `Application.dispatch()` are called by this file, never `Application.run()`.
//!
//! Run it: `zig build w07-host-smoke -- [--hold-ms 8000]`.
//!
//! Diagnostic switches:
//!   --windows 1|2        one or two windows, so a two-window fault can be
//!                       separated from a one-window one on the same driver
//!   --present-frames N   present N frames, then take one
//!                       commit-without-present frame per window, so the
//!                       commit path can be separated from the present path
//!   --scale-watch-ms N   arm a REAL display-scale watch for N milliseconds.
//!                       See "the scale watch" below. Zero disables it, and
//!                       the default run keeps it off.
//!   --fail-after-open N  refuse ON PURPOSE once N windows are open and live,
//!                       so the cleanup owner can be run against real,
//!                       mounted windows instead of only against a run that
//!                       happened to fail. Zero disables it. See "the owner"
//!                       below. It touches nothing outside this process.
//!   --pointer-watch    arm the REAL pointer watch, so an operator can
//!                       move a real pointer across the watched window and
//!                       this run reports what SDL's own queue delivered. It
//!                       observes `--scale-watch-ms` as well as `--hold-ms`:
//!                       with a scale watch it counts through BOTH phases of
//!                       the transition and names the phase on every line. It
//!                       is off by default. See "the pointer watch" below.
//!
//! The scale watch, and what it refuses to claim:
//!
//! The watch exists because a display-scale change is the one host event that
//! a smoke cannot stage for itself: it happens when an operator changes the
//! compositor's output scale while this process is running. So the watch
//! never builds a scale event. It arms, prints one machine-readable READY
//! line, and then pumps the PRODUCTION loop (`Application.step()`, plus
//! `pollEvent`/`dispatch` for the tag of each event SDL really delivered)
//! until either the display scale or the window's own pixel ratio has moved
//! away from the reading taken when the watch armed. A watch that was asked
//! for and saw no real event, or saw events and no real change, FAILS the
//! run; a watch that was not asked for reports nothing and proves nothing.
//!
//! Across that same observed transition the run exercises the two geometry
//! paths a scale change breaks first:
//!   * pointer translation — a SYNTHETIC `mouse_motion` (built here, labelled
//!     synthetic on every line it reaches, and never counted as an input
//!     method observation) pushed through `Application.dispatch` and
//!     `Window.translate` into the production App, whose committed tree is
//!     then hit-tested at the translated point;
//!   * the W12 candidate geometry — a keyed probe component whose committed
//!     VISUAL CONTENT BOX is the line box, handed to the production
//!     `host.Window.setTextInputArea` seam and read back from SDL. The native
//!     area, the logical rectangle and the device-space rectangle are printed
//!     in their own units, because SDL's area stays in window pixels while the
//!     device rectangle is what actually doubles.
//!
//! No input method is started and none is claimed: the run never focuses an
//! editable widget, never registers a text endpoint and never calls
//! `startTextInput`, and it reports `textInputActive()` so a reader can see
//! that for itself. The rectangle is a geometry claim about a real committed
//! tree, not an observation of a candidate WINDOW.
//!
//! The pointer watch, and what it is allowed to say:
//!
//! The scale watch above exercises pointer TRANSLATION with an event this file
//! builds, and every line it reaches says `synthetic`. That proves the
//! translation code runs; it says nothing about whether a compositor ever
//! delivered a pointer. So the pointer watch is a second, separate
//! measurement, and its whole design is that it cannot become the first one
//! again:
//!   * its counter is `ingress_motion`, and it advances only for an
//!     `SDL_EVENT_MOUSE_MOTION` that came out of `Application.pollEvent` AND
//!     that the host then routed as pointer input for the watched window. The
//!     synthetic event is handed straight to `Application.dispatch` and never
//!     crosses that boundary, so the two counters are disjoint by construction
//!     rather than by a label on a line;
//!   * it builds nothing, moves nothing and clicks nothing. Nothing outside
//!     this process is touched: the pointer that produces the events is moved
//!     by an operator, on their own display, while this run only holds its
//!     windows up and reports;
//!   * it is opt-in. Off is the default, and with it off not one line of this
//!     binary's output changes.
//!
//! Where it counts, and what names the phase. The watch observes a window this
//! run already holds up, and the run already has two windows of its own: the
//! `--scale-watch-ms` scale watch, with the ONE deadline this run already
//! obeys, and the `--hold-ms` hold. With a scale watch armed, the watch
//! attaches at the committed baseline BEFORE that deadline and its drain runs
//! in front of `Application.step` inside the scale pump, so a pointer an
//! operator moves while the output is still at its baseline scale is
//! counted as REAL ingress instead of being lost between pumps. The observed
//! transition moves the watch into its second phase and says so on one
//! `PTR real phase` line carrying the freshly committed rectangle, the live
//! window logical and pixel extents and the live output scale; the drain then
//! keeps running in the hold, which is where both windows are still up.
//! There is no second clock, no second deadline and no second event route
//! here: both phases are the run's existing timeline, and every sample names
//! the phase it belongs to, so a reader cannot merge them into one number.
//!
//! One drain, not two. The scale accounting and the pointer accounting read the
//! SAME queue, so they used to run as two drains back to back: a pointer drain
//! first and a raw scale-tag loop second. The second then found an empty queue
//! whenever the first had a watch attached, and a run with a pointer watch
//! reported `raw_events=0` and `real_scale_events=0` for a transition the host
//! had already routed — and then failed on `ScaleWatchNoRealEvent` for having
//! seen nothing it had in fact watched end to end. `drainHostEvents` is now the
//! only place SDL's queue is read: it polls each event once, tags it for the
//! scale accounting BEFORE dispatching it, dispatches it, and attributes it as
//! pointer ingress when a watch is set. Every pump in this file runs it in
//! front of `Application.step`, so no pump can leave a motion for the hook to
//! account for alone.
//!
//! Every motion this run drains lands in exactly ONE of three counters, and
//! the split is the point: `ingress_motion` is what reached the watched
//! window, `other_window_motion` is what reached some other live window, and
//! `refused_motion` is what the host delivered to nobody at all — a
//! touch-synthesized pointer, or a motion whose window the host's
//! generational or timestamp check refused. Only the first is ingress, and
//! the third is counted rather than discarded so the three sum to every
//! motion this run saw. The first two are exactly the motions the production
//! hook also saw, which is what makes the summary's `unaccounted_motion` a
//! statement about the drain ordering instead of a fudge: it is the
//! positive-only gap between what the hook saw and what this drain
//! attributed, and refused motions stay out of that comparison rather than
//! being clamped away to keep it tidy.
//!
//! Two spaces are printed for every real event and never collapsed into one.
//! `x`/`y` are the App-LOGICAL point — what `Window.translate` produced and
//! what the committed tree is hit-tested in, which is the space layout runs in.
//! `native_x`/`native_y` are the same event's numbers as they appear in the SDL
//! event, under the unit name `sdl-window-units`. That name deliberately does
//! NOT say "logical" or "device": this host passes pointer coordinates through
//! unconverted, so raw and routed agree here as a MEASURED property of the
//! translation, and which of the two spaces SDL chose to report in is settled
//! by a reader from `window_logical` against `window_pixels`, never asserted
//! here. The committed probe rectangle is printed beside every sample so a
//! reader can aim a real pointer at it and see the hit test for itself.
//!
//! The pixels are real. Both windows are rasterized through the same public
//! pipeline the demo uses — `v7_frame` scene lowering, `v7_render.Renderer`,
//! the `TextEngine` font service, and the Oklab-to-sRGB blit — so every node
//! this file reports a rectangle for is a node whose glyphs reached the
//! swapchain. A clear colour with a committed tree nobody draws is not
//! evidence of anything, and is not what this file does.
//!
//! The owner, and what an unwind has to survive:
//!
//! `Run` owns everything this file allocates, and `Run.unwind` is the only
//! place that releases any of it — the `errdefer` at the top of `main` calls
//! it for every failure, and the last line of a successful run calls it for
//! the shutdown. Its order is the host's lifetime contract and is written out
//! where it is defined, not scattered across a dozen `errdefer`s whose
//! relative order is a guess.
//!
//! The case that decides the order is a window the host has already opened.
//! `openWindowWithApp` hands the host a BORROW of an App this file owns, and
//! the host's own close path dereferences that App, its Pane, its surface and
//! its blit heap. So a failure after an open may not free the App before the
//! host has closed the window, and may not free the surface after the
//! platform window is gone. `--fail-after-open` stages exactly that state
//! deliberately: the run opens N real windows, reports that they are live,
//! and returns an error. The unwind then has to close them, unmount and
//! release each App, and get back to an empty session — and the
//! `SafeAllocator` at the top of `main` is what says whether it did. The run
//! exits non-zero and prints NO leak report exactly when that unwind is
//! correct.
//!
//! Two windows share the text engine, the renderer and the blit shaders, and
//! nothing else that is named by a queued command. The Oklab target and the
//! blit heap that samples it are per WINDOW (`WindowPaint`): both are read by
//! frames that are already submitted, so one window's resize re-pointing a
//! shared pair would change what the other window's queued blit samples. A
//! frame ring bounds how many frames are in flight, not how long a destroyed
//! texture or a rewritten descriptor stays referenced, so a wider ring is not
//! used as if it did.

const std = @import("std");
const Io = std.Io;
const sdl3 = @import("sdl3");
const noapi = @import("noapi");

const nogui = @import("nogui");
const host = @import("nogui_host");
const v7_frame = @import("v7_frame");
const render = @import("v7_render");

const Session = nogui.Session;
const App = nogui.App;
const contract = host.window_contract;
const Application = host.Application;
const frame_scene = v7_frame.scene;
const TextEngine = v7_frame.TextEngine;
const Renderer = render.Renderer;

/// The per-window state the host hands to a frame callback, named through the
/// host's own public export. The earlier reflection through `Hooks.on_frame`
/// recovered this same type by walking a function pointer's parameter list;
/// the export makes the walk unnecessary, and a change to the hook's
/// signature can no longer silently change what this file calls a window.
const ManagedWindow = host.ManagedWindow;

/// One shared model, two readers. Identical in shape to the core-only
/// `examples/parity/shared_model.zig` scenario, driven here by real windows.
pub const Document = struct {
    revision: u32 = 1,
    frames_drawn: u32 = 0,

    pub fn deinit(self: *Document, _: *Session) void {
        self.* = undefined;
    }
};

const Bump = struct {
    fn apply(doc: *Document, _: void) !void {
        doc.revision += 1;
    }
};

const ReadRevision = struct {
    revision: u32 = 0,
    fn read(doc: *const Document, out: *ReadRevision) void {
        out.revision = doc.revision;
    }
};

/// The committed content the scale watch measures its candidate geometry
/// against. One keyed component nested under the pane, so the App's registry
/// keeps this exact pointer across frames and the node identity is stable.
///
/// The draw publishes the node whose VISUAL CONTENT BOX is the line box an
/// input method anchors under. The rectangle itself is resolved AFTER the
/// frame commits, inside the frame callback, where that tree is the one being
/// published — a rectangle taken from a draw call would describe a layout
/// that has not run yet, and one taken from a later frame would describe
/// different content than the pixels the run is comparing.
pub const Probe = struct {
    /// The node whose committed content box is the candidate line box.
    field: nogui.FrameNodeId = .root,
    /// The draw-time frame generation of the frame that published `field`. The
    /// run prints it beside the App's committed generation, so a reader can
    /// see that the rectangle and the pixels came from the same frame.
    generation: u64 = 0,
    /// The model revision this probe's node was drawn from.
    revision: u32 = 0,

    pub fn draw(self: *Probe, ctx: *nogui.DrawCtx) !void {
        const text = try std.fmt.allocPrint(ctx.arena, "probe r{d}", .{self.revision});
        self.field = try ctx.label(.{ .text = text, .color = probe_text_color });
        self.generation = ctx.frame_generation;
    }
};

/// Authored sRGB, the space every node colour is written in. The scene
/// lowering converts each of them to Oklab the way it converts every other
/// authored fill, and the final blit converts the target back to sRGB, so a
/// colour written here reaches the swapchain as the colour that was asked
/// for. The pane background is a painted node, not a load-op clear: the blit
/// pass covers the image, so a clear underneath it would never be seen.
const probe_text_color: nogui.Color = .{ 0.95, 0.93, 0.86, 1.0 };
const pane_text_color: nogui.Color = .{ 0.06, 0.07, 0.09, 1.0 };

/// One window's view. `observed` records the model revision this window's own
/// last committed frame was built from.
pub const Pane = struct {
    name: []const u8,
    observed: u32 = 0,
    committed: u32 = 0,
    label_buf: [48]u8 = @splat(0),
    label_len: usize = 0,
    /// This window's background, painted as a node so the per-window colour
    /// identity survives into real pixels.
    background: nogui.Color,
    /// The scale probe nested under a stable key, or null when this run did
    /// not ask for a scale watch. The run owns the value; the view only
    /// nests it, so the key alone decides its identity.
    probe: ?*Probe = null,

    pub fn draw(self: *Pane, doc: *const Document, ctx: *nogui.DrawCtx) !void {
        self.observed = doc.revision;
        self.committed += 1;
        _ = try ctx.column(.{ .grow = 1, .fill = self.background });
        defer ctx.pop();
        const text = try std.fmt.allocPrint(ctx.arena, "{s} r{d}", .{ self.name, doc.revision });
        _ = try ctx.label(.{ .text = text, .color = pane_text_color });
        // Copy out of this App's frame arena: the arena dies with the frame.
        const len = @min(text.len, self.label_buf.len - 1);
        @memcpy(self.label_buf[0..len], text[0..len]);
        self.label_buf[len] = 0;
        self.label_len = len;
        if (self.probe) |probe| {
            probe.revision = doc.revision;
            try ctx.component(Probe, .{ .key = .{ .static = "w07-scale-probe" } }, probe);
        }
    }

    pub fn label(self: *const Pane) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

/// One candidate line box, in window-logical units, copied out of a frame that
/// has already been committed. `present` is false until a frame containing the
/// probe has committed, so "the run never published a rectangle" and "the
/// rectangle is empty" cannot be confused.
const CandidateGeometry = struct {
    present: bool = false,
    /// The App frame generation this rectangle was read from.
    generation: u64 = 0,
    /// The line box, window-logical units — the space layout runs in and the
    /// space every pointer event arrives in.
    area: nogui.geometry.WindowRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The caret's x inside `area`. It is the committed run's own width: the
    /// offset the next committed character would occupy, which is exactly the
    /// anchor an input method is asked for.
    cursor: f32 = 0,
};

const WindowSlot = struct {
    /// The title this slot was opened with, exactly as the host was given it.
    /// The report prints it beside `name` because the two answer different
    /// questions and an operator has to be able to tie this run's window
    /// to a surface the COMPOSITOR lists — and the compositor lists titles,
    /// not slot names. A borrowed slice with static lifetime: it comes from
    /// the `specs` literal and outlives every slot.
    title: []const u8,
    name: []const u8,
    handle: contract.WindowHandle,
    app: *App,
    pane: *Pane,
    /// noapi created the platform surface and owns it from that point: its
    /// `destroyWindow` releases it with the swapchain, so no SDL surface
    /// bookkeeping and no second destroy belong here.
    surface: noapi.Surface,
    /// This window's pane background, in sRGB; the scene lowering converts it
    /// to Oklab the way every other authored fill is converted.
    background: nogui.Color,
    frames_committed: u32 = 0,
    frames_presented: u32 = 0,
    /// Set when the host releases this window. The slot stays in place so a
    /// pointer held across the close still names it; callers of `live()` skip
    /// closed slots explicitly.
    closed: bool = false,
    /// Set once this slot's App, its Pane and the storage for both have been
    /// handed back. Only `Run` clears it, and only after the host has closed
    /// the window, so a window the SCENARIO closed and released and a window
    /// the CLEANUP closed and released are the same state and neither can be
    /// released twice.
    released: bool = false,
    /// Present-path accounting. Every number here is a measurement, so a run
    /// that fails can be compared against one that did not.
    resizes_requested: u32 = 0,
    swapchain_recreated: u32 = 0,
    /// Frames whose swapchain image was not the window's pixel size AFTER this
    /// frame had already asked for those pixels. The request is made before
    /// the acquire, so what is left is the driver clamping the image to the
    /// surface capabilities — legitimate, and where composite scaling shows
    /// up. A stale chain is not counted here because it cannot happen on this
    /// path; the draw is sized to the image, never to the window, so a render
    /// area taken from the window would be the fault this counter is near.
    extent_mismatches: u32 = 0,
    present_out_of_date: u32 = 0,
    last_slop_ns: u64 = 0,
    present_timing: bool = false,
    last_image: noapi.Extent2D = .{ .width = 0, .height = 0 },
    last_window_pixels: noapi.Extent2D = .{ .width = 0, .height = 0 },
    /// Frames submitted with no `vkQueuePresentKHR`, taken by
    /// `--present-frames`. See `Smoke.renderSlot`.
    frames_without_present: u32 = 0,
    /// The commit-without-present frame has been taken. The image it acquired
    /// is never returned to the presentation engine, because only a present
    /// hands an image back, so this window's surface cannot acquire again and
    /// its present path is closed for the rest of the run.
    present_held: bool = false,
    /// The noapi surface is already gone, released while the platform window
    /// was still alive. A second release must not reach the backend.
    surface_released: bool = false,
    /// The candidate line box copied out of the last committed frame. The
    /// tree is owned by the App's double-buffered arena, so the rectangle is
    /// a VALUE: nothing here keeps a pointer into a frame that a later frame
    /// may reset.
    candidate: CandidateGeometry = .{},
    /// This window's OWN Oklab target and blit heap. Not shared with the peer:
    /// see `WindowPaint`. Released with the surface, inside
    /// `releaseSurface`, while the device is still alive.
    paint: WindowPaint,
};

fn cancelSurfaceRecording(context: *anyopaque, _: *noapi.CommandBuffer) !void {
    const surface: *noapi.Surface = @ptrCast(@alignCast(context));
    try surface.abortFrame();
}

var exts_storage: [][*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_storage;
}

/// A SPIR-V module read from the build's `shaders/` directory. The bytes stay
/// owned for as long as `shaderCreate` and `Renderer.init` need them.
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

/// What both windows share: the text engine and its caches, the renderer's own
/// three-slot ring, the GUI bindless heap, and the two blit shaders. None of
/// these is re-pointed or destroyed during a run — the shaders are created
/// once and only read, the GUI heap's texture descriptors are written once at
/// init because this run registers no textures, and the renderer ring is
/// indexed by the frame slot rather than owned by a window. Everything that
/// IS re-pointed while a frame is still queued lives in `WindowPaint`, one set
/// per window.
///
/// These resources live for the whole run and are destroyed EXPLICITLY,
/// before `noapi.Gpu.deinit()`: every one of them calls into the device, and
/// the device is gone by the time a `defer` at function scope would run.
/// Nothing here points at itself, so the value returns from `init` by copy
/// safely; the scene scratch that DOES hold a pointer into the renderer lives
/// in `Smoke`, which is created in place.
const Paint = struct {
    gpa: std.mem.Allocator,
    gpu: *noapi.Gpu,
    text: TextEngine,
    renderer: Renderer,
    /// The bindless GUI texture heap. The renderer samples it every frame
    /// even for solid quads, so it is bound exactly as the demo binds it.
    textures: v7_frame.BindlessHeap,
    blit_vert: noapi.Shader,
    blit_frag: noapi.Shader,
    /// The logical/device pair the text engine was last told about. Null
    /// until the first frame. A changed pair re-rasterizes the glyphs at the
    /// new device scale instead of reusing the previous scale's atlas, and
    /// that re-rasterization is the point of the scale watch.
    scale: ?nogui.geometry.PixelScale = null,

    fn init(
        gpa: std.mem.Allocator,
        gpu: *noapi.Gpu,
        quad_vert: *Spv,
        quad_frag: *Spv,
        sort_comp: *Spv,
        fullscreen_vert: *Spv,
        blit_oklab: *Spv,
    ) !Paint {
        var paint: Paint = .{
            .gpa = gpa,
            .gpu = gpu,
            .text = try TextEngine.init(gpa, gpu, &.{
                .{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") },
            }),
            // SAFETY: `Renderer.init` assigns it below, before the first read.
            .renderer = undefined,
            // SAFETY: `BindlessHeap.init` assigns it before `init` returns.
            .textures = undefined,
            // SAFETY: `shaderCreate` assigns it before any frame records.
            .blit_vert = undefined,
            // SAFETY: the fragment `shaderCreate` assigns it the same way.
            .blit_frag = undefined,
        };
        errdefer paint.text.deinit();
        paint.renderer = try Renderer.init(gpu, quad_vert.words, quad_frag.words, sort_comp.words);
        errdefer paint.renderer.deinit();
        paint.blit_vert = try gpu.shaderCreate(
            fullscreen_vert.words,
            .vertex,
            "main",
            "w07_fullscreen",
        );
        errdefer gpu.shaderDestroy(paint.blit_vert);
        paint.blit_frag = try gpu.shaderCreate(blit_oklab.words, .fragment, "main", "w07_blit_oklab");
        errdefer gpu.shaderDestroy(paint.blit_frag);
        paint.textures = try v7_frame.BindlessHeap.init(gpa, gpu);
        try paint.text.setGlyphSlotLimit(frame_scene.glyph_material_ceiling);
        paint.renderer.configure(.{
            .material_bda = paint.text.materialBda(),
            .damp_chroma = true,
        });
        return paint;
    }

    fn deinit(self: *Paint) void {
        self.textures.deinit(self.gpa);
        self.gpu.shaderDestroy(self.blit_frag);
        self.gpu.shaderDestroy(self.blit_vert);
        self.renderer.deinit();
        self.text.deinit();
        self.* = undefined;
    }

    fn syncScale(self: *Paint, scale: nogui.geometry.PixelScale) void {
        if (self.scale) |previous| {
            if (previous.x == scale.x and previous.y == scale.y) return;
        }
        self.text.setPixelScale(scale);
        self.scale = scale;
    }
};

/// The per-window half of the pipeline: the Oklab target THIS window's scene
/// is rendered into, and the blit heap that samples it.
///
/// Both are per window, and neither is shared, because both are things
/// already-recorded commands POINT AT: a queued frame renders INTO the target
/// and SAMPLES it through the blit heap's texture descriptor. Sharing either
/// across two windows means the second window's `ensureTarget` destroys a
/// texture the first window's queued commands still reference, or re-points a
/// descriptor those commands are still going to read at execution time. A
/// frame ring bounds how many frames are in flight; it does not bound how long
/// a destroyed texture or a rewritten descriptor stays referenced, so a wider
/// ring does not make a shared target safe.
const WindowPaint = struct {
    gpu: *noapi.Gpu,
    /// False until `init` has installed a blit heap. `WindowSlot` holds one of
    /// these from the moment the slot is written, and a run that aborts
    /// mid-open must still be able to release every slot it reached without
    /// destroying a heap that was never created. A paint that WAS live is
    /// invalidated by `deinit`, so this flag only ever answers for a paint
    /// that never became one.
    live: bool = false,
    /// The Oklab target for this window, at `target_extent`. `{}` until the
    /// first frame installs one.
    target: noapi.TextureHandle = .{},
    target_extent: noapi.Extent2D = .{ .width = 0, .height = 0 },
    /// The heap the blit pass binds to sample `target`. One per window, for
    /// the reason above. `.{}` is not a valid heap, which is what `live` is
    /// for.
    blit_heap: noapi.DescriptorHeap = .{},
    /// How many targets this window replaced. Only a resize or a display-scale
    /// change makes it move, so a run that changed scale can be compared
    /// against one that did not.
    recreations: u32 = 0,

    fn init(gpu: *noapi.Gpu) !WindowPaint {
        var self: WindowPaint = .{ .gpu = gpu };
        errdefer if (self.live) self.deinit();
        self.blit_heap = try gpu.descHeapCreate(8, 0, 1);
        self.live = true;
        const sampler = gpu.samplerDescriptor(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mip_filter = .nearest,
        });
        gpu.descHeapSetSamplers(self.blit_heap, 0, &.{sampler});
        return self;
    }

    /// Releases this window's target and blit heap and leaves the storage
    /// undefined behind them. A paint that never became live releases
    /// nothing, and a paint that was already released never gets here:
    /// `releaseSurface` owns the flag that outlives this invalidation.
    ///
    /// The device is idled FIRST: the queued frames this window's last target
    /// was named by may still be reading it, and the swapchain teardown that
    /// preceded this call retires the swapchain, not this texture.
    fn deinit(self: *WindowPaint) void {
        if (self.live) {
            self.live = false;
            self.gpu.waitIdle() catch
                @panic("device wait failed while releasing a window's paint resources");
            if (self.target.texture.id != 0) self.gpu.textureDestroy(self.target);
            self.gpu.descHeapDestroy(self.blit_heap);
            self.target = .{};
            self.blit_heap = .{};
        }
        self.* = undefined;
    }

    /// Point this window's blit heap at an Oklab target of `extent`.
    ///
    /// Order matters twice. The device is idled FIRST, while the old target is
    /// still installed: every frame this window has already recorded names
    /// that texture and that heap descriptor, and re-pointing a descriptor
    /// while its old value is still queued would make those frames sample the
    /// NEW target. This runs before the frame's command buffer is opened, so
    /// the wait is never taken while a recording is active. The replacement
    /// is created only after the wait, and a creation failure leaves the old
    /// target installed and still valid — the other order turns a failed
    /// resize into a blit that samples a destroyed texture.
    fn ensureTarget(self: *WindowPaint, extent: noapi.Extent2D) !void {
        if (self.target.texture.id != 0 and
            self.target_extent.width == extent.width and
            self.target_extent.height == extent.height) return;
        try self.gpu.waitIdle();
        const created = try self.gpu.textureCreate(.{
            .dimensions = .{ extent.width, extent.height, 1 },
            .format = frame_scene.render_target_format,
            .usage = .{ .color_attachment = true, .sampled = true, .transfer_src = true },
        });
        errdefer self.gpu.textureDestroy(created);
        const view = self.gpu.textureViewDescriptor(created, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.blit_heap, 0, &.{view});
        const previous = self.target;
        self.target = created;
        self.target_extent = extent;
        self.recreations += 1;
        if (previous.texture.id != 0) self.gpu.textureDestroy(previous);
    }
};

const Smoke = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The host this run drives. Borrowed; it outlives every hook call.
    application: *Application,
    /// The window slots, and the endpoint every window shares. Both are
    /// borrowed from the enclosing `main`, which outlives this struct.
    /// `windows` is the WHOLE array; `live()` is the part of it this run
    /// opened.
    windows: []WindowSlot,
    /// The owner of those slots. `live()` reads the count from it instead of
    /// keeping a second copy here, so the number of windows this file walks
    /// and the number the cleanup releases can never disagree.
    run: *Run,
    endpoint: *nogui.GpuEndpoint,
    /// The real rendering pipeline, borrowed from the enclosing `main`. It
    /// outlives every frame callback and is destroyed only after the last
    /// App has detached from the endpoint.
    paint: *Paint,
    /// The retained per-frame scene scratch. Both lists keep their capacity
    /// across frames, so lowering a frame appends without allocating. It
    /// holds a pointer into `paint.renderer`, which is why it lives here,
    /// next to the `Paint` it borrows, instead of inside it.
    scene: frame_scene.SceneScratch,
    /// Events SDL REALLY delivered, counted from the raw queue before
    /// `Application.dispatch` routes them. The scale watch is allowed to
    /// count only these: nothing in this file builds one of these events to
    /// make a gate pass.
    raw_events: u32 = 0,
    /// `raw_events` as it stood when the pointer watch armed, so
    /// `raw_events_in_watch` can be a real delta. The counter above is
    /// whole-run, because ONE drain now runs in front of every pump; the
    /// pointer watch is a window inside the run and the figure the watch line
    /// names has to be the events that landed inside it. Zero in a run that
    /// never armed a watch, where the whole run IS the scale watch.
    watch_arm_raw_events: u32 = 0,
    display_scale_events: u32 = 0,
    display_geometry_events: u32 = 0,
    window_scale_events: u32 = 0,
    window_pixel_size_events: u32 = 0,
    /// Scale changes the HOST itself routed, counted from the production
    /// `on_event` hook, so the routing is measured and not assumed from the
    /// raw tag alone. A compositor can deliver a scale transition through
    /// either route — a display content-scale event, or a per-window scale or
    /// pixel-size event — and which one it uses is its business, not this
    /// run's. The two routes are counted apart and summed, so a reader sees
    /// which one the platform took instead of one number that hides it.
    routed_display_scale_events: u32 = 0,
    routed_window_scale_events: u32 = 0,
    routed_window_state_events: u32 = 0,
    /// Pointer events this run BUILT. Every one is labelled synthetic in the
    /// report and none of them is counted as an observed input event; the
    /// count exists so a reader can never mistake one for the other.
    synthetic_pointer_events: u32 = 0,
    /// The last pointer position the production App stored from a routed
    /// event, in window-logical units.
    pointer_logical: [2]f32 = .{ 0, 0 },
    /// Whether that routed point landed on the probe's committed box.
    pointer_hits_probe: bool = false,
    /// REAL pointer ingress, counted at the POLLING BOUNDARY and only there.
    /// `ingress_motion` advances for one `SDL_EVENT_MOUSE_MOTION` this run
    /// polled out of SDL's queue and the host then routed as pointer motion
    /// for the watched window. The synthetic probe above hands a BUILT event
    /// straight to `Application.dispatch`, so it never crosses this boundary
    /// and the two counters are disjoint by construction rather than by a
    /// label.
    ingress_motion: u32 = 0,
    ingress_enter: u32 = 0,
    ingress_leave: u32 = 0,
    /// Motion the host ROUTED as pointer input for another live window. Counted
    /// so a two-window run cannot hide pointer traffic behind the watched one,
    /// and kept apart from `ingress_refused_motion` because the two answer
    /// different questions: this one reached a client, that one reached none.
    ingress_other_motion: u32 = 0,
    /// Motion SDL delivered that the host did not route as pointer input at
    /// all — a touch-synthesized pointer, a motion for a native window this
    /// host does not own, or one its generational or timestamp check refused.
    /// These are real deliveries and NOT ingress, and they are counted rather
    /// than discarded, so `ingress_motion + ingress_other_motion +
    /// ingress_refused_motion` is every mouse_motion this run drained.
    ingress_refused_motion: u32 = 0,
    /// Pointer motion the host ROUTED, counted from the production `on_event`
    /// hook with the one synthetic dispatch excluded. This is the cross-check
    /// on `ingress_motion`: it also covers what the host's own
    /// `Application.step` consumed from the same queue, so a difference is
    /// printed as the number of events this drain did not see rather than
    /// quietly folded into one counter.
    routed_pointer_motion: u32 = 0,
    /// The first and last App-logical point REAL ingress produced. Values, so
    /// the summary can name the travel without keeping a frame pointer.
    ingress_first: ?[2]f32 = null,
    ingress_last: ?[2]f32 = null,
    /// Set only around the ONE manual `Application.dispatch` in this file, so
    /// the routed-motion counter above cannot count the event this run built.
    synthetic_dispatch: bool = false,
    /// The phase every real ingress sample is stamped with, and the two
    /// counters that split the run's ingress by it. `phase_motion` counts the
    /// phase the watch is in now and `earlier_phase_motion` the ones it left,
    /// so a two-phase watch reports both from ONE pair of counters and a
    /// one-phase watch reports `earlier_phase_motion=0` instead of a missing
    /// half. Set only where the watch arms or where it changes phase.
    pointer_phase: []const u8 = "unarmed",
    phase_motion: u32 = 0,
    earlier_phase_motion: u32 = 0,
    /// The committed-frame count the watch armed at. A predicate is a bare
    /// function pointer and cannot close over a runtime value, so this is
    /// where the "settle on frames from the NEW scale" check reads it from.
    watch_baseline_committed: u32 = 0,
    /// Present at most this many frames per window, then submit one frame
    /// without presenting and stop acquiring from that surface. Zero disables
    /// the discriminator.
    present_limit: u32 = 0,
    tick: u32 = 1,
    /// Flipped to true to prove `on_close_request` vetoes a close.
    close_veto: bool = false,
    close_hook_calls: u32 = 0,
    /// Windows whose noapi surface was released from `on_before_close`, while
    /// the platform window was still alive. Reported at shutdown so the
    /// teardown order is a measurement rather than an assumption.
    before_close_calls: u32 = 0,
    closed_hook_calls: u32 = 0,
    last_window_closed_calls: u32 = 0,
    last_window_decision: ?Application.LastWindowDecision = null,
    quit_hook_calls: u32 = 0,
    quit_decision: ?Application.QuitDecision = null,
    /// False once `Application.step()` reported the host stopped.
    host_running: bool = true,
    /// Proof that the owned loop was never entered. `Application.run` is not
    /// called anywhere in this file.
    owned_loop_calls: u32 = 0,
    steps: u32 = 0,
    polls: u32 = 0,

    /// Every slot this run opened, closed ones INCLUDED. Nothing is ever
    /// moved, so a pointer held across a close keeps naming the same window;
    /// a caller that wants the open windows only tests `slot.closed`, and
    /// `slotFor` finds nothing for a window the host has released because its
    /// handle no longer resolves.
    fn live(self: *Smoke) []WindowSlot {
        return self.windows[0..self.run.opened];
    }

    fn slotFor(self: *Smoke, managed: *ManagedWindow) ?*WindowSlot {
        for (self.live()) |*slot| {
            if (self.application.getWindow(slot.handle) catch null) |found| {
                if (found == managed) return slot;
            }
        }
        return null;
    }

    /// One committed frame for one window. Normally it is also presented;
    /// after the requested present limit, one more is submitted without
    /// presentation and this surface stops acquiring images. Returns false
    /// when the frame must be retried because the surface went out of date.
    ///
    /// The render area is the swapchain image, never the window. The driver
    /// clamps the image to the surface capabilities' minimum and maximum, so a
    /// window's pixel size can exceed the image it presents into; drawing the
    /// window's size there would address past the end of the image. Both
    /// passes size themselves to the image, the App lays out in the window's
    /// LOGICAL size, and the two spaces are converted through the observed
    /// pixel scale — which is also the scale the text engine is told about.
    fn renderSlot(self: *Smoke, slot: *WindowSlot, managed: *ManagedWindow) !bool {
        if (slot.present_held) {
            // The commit-without-present frame consumed one swapchain image
            // that is never returned, so acquiring again would eventually
            // block forever in `vkAcquireNextImageKHR`. This window stops
            // rendering and the rest of the run still drives the host. The
            // frame is reported as successful so the demand is not restored
            // into the same frame forever.
            return true;
        }
        const window_pixels = try managed.native.pixelExtent();
        // Ask for the window's pixel size BEFORE the acquire, so the schedule
        // rebuilds the chain inside this `beginFrame` and the image handed
        // back already matches. Notifying after the acquire is one frame
        // late: this frame would draw into an image sized for the previous
        // extent and present it, which is the stale presentation the
        // `extent_mismatches` counter exists to name.
        if (window_pixels.width > 0 and window_pixels.height > 0) {
            slot.surface.notifyResize(.{ .width = window_pixels.width, .height = window_pixels.height });
        }
        const schedule = slot.surface.beginFrame() catch |err| {
            if (err == error.OutOfDateKHR) {
                slot.resizes_requested += 1;
                return false;
            }
            return err;
        };
        if (schedule.swapchain_recreated) slot.swapchain_recreated += 1;
        const image = slot.surface.surfaceSize();
        slot.last_image = image;
        slot.last_window_pixels = .{ .width = window_pixels.width, .height = window_pixels.height };
        // The size was requested before this acquire, so a difference here is
        // the driver clamping the image to the surface capabilities and not a
        // stale chain. The image is the render target either way: the scene
        // pass and the blit both size themselves to it.
        if (image.width != window_pixels.width or image.height != window_pixels.height) {
            slot.extent_mismatches += 1;
        }
        if (image.width == 0 or image.height == 0) return error.SwapchainImageEmpty;
        // This window's OWN target, before this frame's command buffer is
        // opened. A size change — a resize or a display-scale change — idles
        // the device here, where no recording is active, because the frames
        // this target replaces are still queued and still name it.
        try slot.paint.ensureTarget(image);
        var cmd = slot.surface.commandsBegin();
        var gpu_frame: nogui.GpuFrame = .{
            .endpoint = self.endpoint,
            .command_buffer = &cmd,
            .extent = image,
            .frame_index = slot.frames_committed,
            .recording = .{ .active = .{
                .context = &slot.surface,
                .abort = cancelSurfaceRecording,
            } },
        };
        var recording_active = true;
        errdefer if (recording_active) gpu_frame.cancelRecording() catch
            @panic("surface recording cancellation failed");

        // The scene is rendered into an Oklab target and blitted into the
        // swapchain image, so nothing is drawn straight into the image at
        // first: pass one owns the Oklab target, pass two writes the image.
        // The text engine is told the observed scale BEFORE the frame is
        // built, because a scale change is exactly when the glyph rasters
        // have to be redone.
        const logical = managed.observed.size;
        const window_size: nogui.geometry.WindowSize = .{
            .width = @floatFromInt(logical.width),
            .height = @floatFromInt(logical.height),
        };
        self.paint.syncScale(try managed.observed.pixelScale());
        const time_ms = sdl3.timer.getMillisecondsSinceInit();
        slot.app.dispatchRootFrame(time_ms);
        const out = try slot.app.frameWithGpuAtTime(
            self.tick,
            time_ms,
            .{ .width = window_size.width, .height = window_size.height },
            &gpu_frame,
        );
        defer if (out.json) |json| self.gpa.free(json);
        // Resolved here and not in the draw: this tree is the one the
        // candidate rectangle has to describe, and it is about to become the
        // committed one. Copying it out keeps no pointer into a frame arena.
        resolveCandidate(slot, &out);

        // Pass one: the committed tree, lowered and rasterized into Oklab.
        self.scene.beginFrame();
        var frame_paint = try frame_scene.buildFrameScene(
            &self.scene,
            &self.paint.text,
            .{},
            &out,
            false,
        );
        defer frame_paint.deinit();
        _ = try frame_scene.recordFrameScene(&.{
            .arena = out.tree.allocator,
            .renderer = &self.paint.renderer,
            .text = &self.paint.text,
            .logical = window_size,
            .device = image,
            .texture_heap = self.paint.textures.handle,
            .clips = out.tree.clip_rects[0..out.tree.clip_count],
        }, &cmd, &self.scene, self.scene.rects.items, &frame_paint, slot.paint.target);
        // The blit pass samples the target while writing the swapchain image,
        // so pass one's colour output has to be readable by a fragment shader
        // first. Both passes live in this one command buffer.
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});
        // Pass two: Oklab to sRGB, into the swapchain image. This is the draw
        // that covers the image, which is why the image — not the window — is
        // the render area.
        frame_scene.recordBlit(
            &cmd,
            slot.surface.currentImage(),
            image,
            self.paint.blit_vert,
            self.paint.blit_frag,
            slot.paint.blit_heap,
        );
        gpu_frame.finishRecording();
        recording_active = false;
        if (self.present_limit != 0 and
            slot.frames_presented >= self.present_limit and
            !slot.present_held)
        {
            // `endFrame(null)` SUBMITS the recording and issues no
            // `vkQueuePresentKHR`, so both passes run on the GPU and the
            // commit path is really exercised while the present path stays
            // still. Abandoning the frame instead left the backend's surface
            // frame open: the next `beginFrame` failed with
            // `FrameAlreadyActive`, and the recorded work was never submitted
            // at all.
            _ = try slot.surface.endFrame(null);
            slot.present_held = true;
            slot.frames_committed += 1;
            slot.frames_without_present += 1;
            self.tick += 1;
            return true;
        }
        const result = try slot.surface.endFrame(.{});
        if (result.present_out_of_date) slot.present_out_of_date += 1;
        slot.last_slop_ns = slot.surface.slopNs();
        slot.frames_committed += 1;
        slot.frames_presented += 1;
        self.tick += 1;
        // Re-arm so the next host step claims another frame for this window.
        managed.requestPresentation();
        return true;
    }

    /// The production host's own event hook.
    ///
    /// Every event that reaches it came through `Application.dispatch`, and
    /// every one of those but the single synthetic probe came out of SDL's
    /// queue first. `routeSyntheticPointer` raises `synthetic_dispatch` around
    /// its own dispatch, so this hook can tell the two apart by construction
    /// instead of by convention, and the display and window-state counters
    /// keep counting both exactly as they did before.
    fn onEvent(context: *anyopaque, _: *Application, event: Application.Event) anyerror!void {
        const self: *Smoke = @ptrCast(@alignCast(context));
        switch (event) {
            .display => |change| {
                // The host's MEASURED delta, not the SDL tag. A compositor
                // can carry a scale change in on a display event SDL
                // classified as geometry, and `displayChanged` re-queries the
                // display and diffs it whichever tag delivered it. Counting
                // `kind` here reported zero for a transition this process
                // observed, which said something about the tag and nothing
                // about the routing.
                if (change.delta.scale_changed) self.routed_display_scale_events += 1;
            },
            .window => |value| {
                if (value.state_changed) self.routed_window_state_events += 1;
                // A scale change the HOST measured and routed on the window
                // route. This is the route niri takes, and it is a real
                // measurement: the host diffed the reading it held before the
                // event against the one it took after, so this counts a scale
                // that MOVED rather than an event of a given tag.
                if (value.scale_changed) self.routed_window_scale_events += 1;
                // Pointer motion the HOST routed, from the production hook and
                // for every window it owns. The one manual dispatch in this
                // file raises `synthetic_dispatch` around itself, so the event
                // this run BUILT is excluded here and only here; what reaches
                // this counter came out of SDL's queue.
                if (self.synthetic_dispatch) return;
                const translated = value.translated orelse return;
                const core = switch (translated) {
                    .input => |core_event| core_event,
                    .close, .resize, .key_down => return,
                };
                switch (core) {
                    .mouse_move => self.routed_pointer_motion += 1,
                    else => {},
                }
            },
            .drop => {},
            .system_wake => {},
        }
    }

    fn onFrame(
        context: *anyopaque,
        _: *Application,
        managed: *ManagedWindow,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *Smoke = @ptrCast(@alignCast(context));
        const slot = self.slotFor(managed) orelse return false;
        return self.renderSlot(slot, managed);
    }

    fn onCloseRequest(context: *anyopaque, _: contract.WindowHandle) bool {
        const self: *Smoke = @ptrCast(@alignCast(context));
        self.close_hook_calls += 1;
        return !self.close_veto;
    }

    /// The host destroys the SDL window itself. The noapi surface presents
    /// INTO that window, so it is released here, while the window is still
    /// alive: SDL documents the Vulkan surface destroy as belonging before
    /// `video.Window.deinit`, and on X11 the swapchain and its `VkSurfaceKHR`
    /// reference the X11 `Window` that `SDL_DestroyWindow` frees.
    fn onBeforeClose(context: *anyopaque, managed: *ManagedWindow) void {
        const self: *Smoke = @ptrCast(@alignCast(context));
        const slot = self.slotFor(managed) orelse return;
        self.before_close_calls += 1;
        releaseSurface(slot);
    }

    fn onClosed(context: *anyopaque, handle: contract.WindowHandle) void {
        const self: *Smoke = @ptrCast(@alignCast(context));
        self.closed_hook_calls += 1;
        // The slot is MARKED, not moved. A caller can be holding a pointer to
        // a window slot across this call, and shifting the array would leave
        // that pointer naming a different window. `live()` returns the marked
        // ones too, so a caller iterating the open windows tests `slot.closed`.
        for (self.live()) |*slot| {
            if (slot.handle.eql(handle)) slot.closed = true;
        }
    }

    fn onLastWindowClosed(context: *anyopaque, _: *Application) Application.LastWindowDecision {
        const self: *Smoke = @ptrCast(@alignCast(context));
        self.last_window_closed_calls += 1;
        // Keep the process alive: last-window-close and application quit are
        // two separate decisions and this run proves both.
        self.last_window_decision = .keep_running;
        return .keep_running;
    }

    fn onQuitRequest(context: *anyopaque, _: *Application, _: Application.QuitToken) Application.QuitDecision {
        const self: *Smoke = @ptrCast(@alignCast(context));
        self.quit_hook_calls += 1;
        self.quit_decision = .approve;
        return .approve;
    }
};

/// Copy the probe's committed line box out of the frame being published. The
/// tree belongs to the App's double-buffered arena, so the rectangle is a
/// value: nothing here outlives the frame it was read from.
///
/// A run without a scale watch mounts no probe, and a run whose probe has not
/// drawn yet leaves `present` false, so "this run published no rectangle" and
/// "the rectangle is empty" cannot be confused.
fn resolveCandidate(slot: *WindowSlot, out: *const nogui.FrameOutput) void {
    const probe = slot.pane.probe orelse return;
    if (probe.generation == 0) return;
    const content = nogui.visualContentRect(out.tree, probe.field);
    if (!std.math.isFinite(content.x) or !std.math.isFinite(content.y) or
        !std.math.isFinite(content.w) or !std.math.isFinite(content.h)) return;
    slot.candidate = .{
        .present = true,
        .generation = probe.generation,
        .area = .{
            .x = content.x,
            .y = content.y,
            .w = content.w,
            .h = content.h,
        },
        // The caret sits at the end of the run this frame rasterized: the
        // offset the next committed character would occupy.
        .cursor = content.w,
    };
}

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),
    /// A second, much smaller buffer for the optional values a line formats
    /// inline (`<err>`, a scale, a position). It is separate from `buffer`
    /// so an argument that borrows it can still be passed to `emit`.
    scratch: [64]u8 = @splat(0),
    /// A third buffer, for the rare line that formats TWO optional values
    /// inline at once — the pointer summary names a first and a last point.
    /// Separate from `scratch` for the same reason `scratch` is separate from
    /// `buffer`: an argument that borrows one of them cannot be passed while
    /// the other is being written.
    tail: [64]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        // The buffer is reused for every line, so formatting into it is a
        // WRITE and the result borrows it.
        const text = try std.fmt.bufPrint(self.buffer[0..], fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// The window's physical size, which is what the compositor will scale the
/// swapchain image to. The render area is the image, not this.
fn deviceExtent(managed: *ManagedWindow) !noapi.Extent2D {
    const pixels = try managed.native.sdl.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

/// Everything about one window's present path that a reader needs to settle
/// whether a fault was this repository's. The render area is reported next to
/// both the swapchain image and the window's pixel size, so "the draw was out
/// of range" is a claim this output can settle either way.
fn reportPresent(smoke: *Smoke, report: *Reporter, slot: *WindowSlot) !void {
    // A window the host has already released is not reported on: its handle
    // resolves to nothing and reading its present accounting would describe a
    // surface that no longer exists.
    if (slot.closed) return;
    const managed = try smoke.application.getWindow(slot.handle);
    const window_pixels = try managed.native.pixelExtent();
    const image = slot.surface.surfaceSize();
    const in_range = image.width != 0 and image.height != 0;
    const scaled = image.width != window_pixels.width or image.height != window_pixels.height;
    const limits = managed.observedSizeLimits() catch null;
    try report.emit(
        "present {s}: image={d}x{d} window_pixels={d}x{d} observed_pixels={d}x{d}" ++
            " render_area={d}x{d} render_area_in_image={} composite_scaled={}" ++
            " committed={d} presented={d} without_present={d} resizes_requested={d}" ++
            " swapchain_recreated={d} extent_mismatches={d} out_of_date={d}" ++
            " oklab_target={d}x{d} oklab_target_recreated={d}" ++
            " present_timing={} slop_ns={d} present_path={s}\n",
        .{
            slot.name,
            image.width,
            image.height,
            window_pixels.width,
            window_pixels.height,
            managed.observed.pixels.width,
            managed.observed.pixels.height,
            image.width,
            image.height,
            in_range,
            scaled,
            slot.frames_committed,
            slot.frames_presented,
            slot.frames_without_present,
            slot.resizes_requested,
            slot.swapchain_recreated,
            slot.extent_mismatches,
            slot.present_out_of_date,
            slot.paint.target_extent.width,
            slot.paint.target_extent.height,
            slot.paint.recreations,
            slot.present_timing,
            slot.last_slop_ns,
            if (slot.present_held) "held-after-commit" else "live",
        },
    );
    if (limits) |value| {
        try report.emit(
            "  platform size limits {s}: minimum={d}x{d} maximum={d}x{d}\n",
            .{ slot.name, value.minimum.width, value.minimum.height, value.maximum.width, value.maximum.height },
        );
    } else {
        try report.emit("  platform size limits {s}: unreadable on this backend\n", .{slot.name});
    }
}

// ── the real scale watch ────────────────
//
// Everything below reads the platform back. None of it builds the event it
// waits for, and every gate below is a comparison between two readings taken
// from the same window, in the same process, on the same driver.

/// One reading of everything a display-scale transition has to move together.
/// Every field is read from SDL or from the host's own observation at the
/// moment the reading is taken; none of it is carried over.
const ScaleReading = struct {
    display: contract.DisplayId,
    /// `SDL_GetWindowDisplayScale` for the window.
    display_scale: f32,
    /// The content scale the host's display snapshot holds for this display.
    /// Null where the host could not read the display at all, which is a
    /// different answer from "the scale did not change".
    snapshot_scale: ?f32,
    /// The window client size in logical units and the render surface in
    /// whole device pixels. They are different spaces, so they are different
    /// types: the pair is only meaningful through the ratio below.
    logical: contract.Size,
    pixels: nogui.geometry.DeviceSize,
    /// Device pixels per logical unit, from the observed pair.
    ratio: [2]f32,
    /// The caret anchor, in logical units and in device pixels. The SAME
    /// point through both conversions is what makes the two spaces
    /// comparable, so it is the anchor and not an arbitrary corner.
    anchor_logical: nogui.geometry.WindowPoint,
    anchor_device: nogui.geometry.DevicePoint,
    /// The swapchain image the run is really drawing into.
    image: noapi.Extent2D,
    committed: u32,
    presented: u32,
};

fn readScale(
    smoke: *Smoke,
    slot: *WindowSlot,
    anchor: nogui.geometry.WindowPoint,
) !ScaleReading {
    const managed = try smoke.application.getWindow(slot.handle);
    // A reading with no usable geometry is not a reading: a zero-size or
    // zero-pixel window would make the ratio meaningless, and printing a
    // meaningless ratio as if it were measured is the failure this gate
    // exists to catch.
    const ratio = try managed.observed.pixelScale();
    var snapshot_scale: ?f32 = null;
    for (smoke.application.displayList()) |info| {
        if (info.id == managed.observed.display) snapshot_scale = info.content_scale;
    }
    return .{
        .display = managed.observed.display,
        .display_scale = managed.observed.display_scale,
        .snapshot_scale = snapshot_scale,
        .logical = managed.observed.size,
        .pixels = managed.observed.pixels,
        .ratio = .{ ratio.x, ratio.y },
        .anchor_logical = anchor,
        .anchor_device = ratio.windowToDevice(anchor),
        .image = slot.surface.surfaceSize(),
        .committed = slot.frames_committed,
        .presented = slot.frames_presented,
    };
}

fn emitScale(report: *Reporter, label: []const u8, value: ScaleReading) !void {
    try report.emit(
        "{s}: display={d} display_scale={d:.3} snapshot_scale={s}" ++
            " logical={d}x{d} pixels={d}x{d} pixel_ratio={d:.3}x{d:.3} image={d}x{d}" ++
            " anchor_logical=({d:.2},{d:.2}) anchor_device=({d:.2},{d:.2})" ++
            " committed={d} presented={d}\n",
        .{
            label,
            @backingInt(value.display),
            value.display_scale,
            if (value.snapshot_scale) |scale|
                std.fmt.bufPrint(&report.scratch, "{d:.3}", .{scale}) catch "<err>"
            else
                "<unreadable>",
            value.logical.width,
            value.logical.height,
            value.pixels.width,
            value.pixels.height,
            value.ratio[0],
            value.ratio[1],
            value.image.width,
            value.image.height,
            value.anchor_logical.x,
            value.anchor_logical.y,
            value.anchor_device.x,
            value.anchor_device.y,
            value.committed,
            value.presented,
        },
    );
}

/// True when the two readings disagree about the scale in any way the host
/// can observe: the display's own content scale, the per-window display
/// scale, or the window's pixel ratio. A geometry change alone — a different
/// pixel size at an unchanged ratio — is a resize, not a scale transition,
/// and is reported as such rather than counted as one.
fn scaleMoved(before: ScaleReading, after: ScaleReading) bool {
    if (before.display != after.display) return true;
    if (before.display_scale != after.display_scale) return true;
    if (before.ratio[0] != after.ratio[0] or before.ratio[1] != after.ratio[1]) return true;
    if (before.snapshot_scale) |was| {
        if (after.snapshot_scale) |now| {
            if (was != now) return true;
        }
    }
    return false;
}

/// The candidate geometry in three SEPARATE spaces, plus SDL's own answer.
/// They are printed apart on purpose: SDL's area stays in window pixels across
/// a scale change, the device rectangle is what doubles, and the logical
/// rectangle is what layout keeps fixed. Collapsing them into one number is
/// exactly the bug this readback exists to make impossible.
const CandidateReading = struct {
    present: bool,
    /// The App frame generation the committed rectangle came from.
    generation: u64,
    /// Window-logical units: the space layout runs in, and the space SDL's
    /// area is expressed in.
    area: nogui.geometry.WindowRect,
    /// The caret's x inside `area`, window-logical units.
    cursor: f32,
    /// The same rectangle in device pixels.
    device: nogui.geometry.DeviceRect,
    /// What SDL reports it was given, in whole window pixels, and the cursor
    /// offset it stored next to it. Read back from SDL, not recomputed here.
    native: sdl3.rect.IRect,
    native_cursor: i32,
    /// Whether the platform accepted the area this run published just before
    /// reading it back. A refusal is reported, not thrown away: a readback of
    /// an area the platform refused is not evidence of anything, and the run
    /// says so instead of comparing two stale rectangles.
    published: bool,
    /// A point INSIDE the committed line box, in window-logical units. The
    /// caret itself sits on the run's trailing edge, which is a half-open
    /// boundary, so the pointer probe is placed inside rather than on it.
    anchor: nogui.geometry.WindowPoint,
    /// Whether the platform is delivering text for this window. This run
    /// never starts an input method, so a reader can see for itself that
    /// everything above is a geometry claim and not an IME claim.
    text_input_active: bool,
};

fn readCandidate(smoke: *Smoke, slot: *WindowSlot, published: bool) !CandidateReading {
    const managed = try smoke.application.getWindow(slot.handle);
    const ratio = try managed.observed.pixelScale();
    const committed = slot.candidate;
    const answer = try sdl3.keyboard.getTextInputArea(managed.native.sdl);
    return .{
        .present = committed.present,
        .generation = committed.generation,
        .area = committed.area,
        .cursor = committed.cursor,
        .device = ratio.windowRectToDevice(committed.area),
        .native = answer[0],
        .native_cursor = answer[1],
        .anchor = .{
            .x = committed.area.x + @min(1, committed.area.w / 2),
            .y = committed.area.y + committed.area.h / 2,
        },
        .published = published,
        .text_input_active = managed.native.textInputActive(),
    };
}

fn emitCandidate(report: *Reporter, label: []const u8, value: CandidateReading) !void {
    try report.emit(
        "{s}: committed={} area_published={} frame_generation={d}" ++
            " logical=({d:.2},{d:.2} {d:.2}x{d:.2}) cursor={d:.2}" ++
            " device=({d:.2},{d:.2} {d:.2}x{d:.2})" ++
            " native_sdl_px=({d},{d} {d}x{d}) native_cursor={d}" ++
            " anchor=({d:.2},{d:.2}) text_input_active={}\n",
        .{
            label,
            value.present,
            value.published,
            value.generation,
            value.area.x,
            value.area.y,
            value.area.w,
            value.area.h,
            value.cursor,
            value.device.x,
            value.device.y,
            value.device.w,
            value.device.h,
            value.native.x,
            value.native.y,
            value.native.w,
            value.native.h,
            value.native_cursor,
            value.anchor.x,
            value.anchor.y,
            value.text_input_active,
        },
    );
}

/// Hand the committed line box to the host's own candidate-area seam. That
/// seam is the whole translation this repository owns — a logical rectangle
/// in, whole window pixels out — and it is the same conversion the text-input
/// manager performs. Nothing here re-implements that rounding, and no input
/// method is started: `SDL_SetTextInputArea` is a platform call on a window
/// this process owns, and the readback that follows is what the platform
/// stored.
///
/// Returns whether the platform ACCEPTED it. The production native hook logs
/// a refusal and carries on, because it has no error channel; a gate does, so
/// the refusal is carried out to the report and fails the run rather than
/// leaving two stale rectangles to be compared as if they were fresh.
fn publishCandidate(smoke: *Smoke, slot: *WindowSlot) !bool {
    if (!slot.candidate.present) return false;
    const managed = try smoke.application.getWindow(slot.handle);
    managed.native.setTextInputArea(slot.candidate.area, slot.candidate.cursor) catch return false;
    return true;
}

/// Push ONE synthetic pointer event through the production path: SDL's own
/// event shape, `Application.dispatch`, `Window.translate` and the App's own
/// routed input. The event is BUILT here, so it is not an
/// observation of anything a person or a compositor did; it is counted in
/// `synthetic_pointer_events` and labelled on every line it reaches.
fn routeSyntheticPointer(
    smoke: *Smoke,
    slot: *WindowSlot,
    at: nogui.geometry.WindowPoint,
) !void {
    const managed = try smoke.application.getWindow(slot.handle);
    smoke.synthetic_pointer_events += 1;
    const raw: sdl3.events.Event = .{ .mouse_motion = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window_id = managed.native.id,
        .state = .{
            .left = false,
            .middle = false,
            .right = false,
            .side1 = false,
            .side2 = false,
        },
        .x = at.x,
        .y = at.y,
        .x_rel = 0,
        .y_rel = 0,
    } };
    // Scoped to this ONE dispatch and nothing else. The flag is what keeps the
    // event this run built out of the production hook's real-ingress counter,
    // so the two never share a number even for the duration of one call.
    smoke.synthetic_dispatch = true;
    defer smoke.synthetic_dispatch = false;
    const routed = try smoke.application.dispatch(&raw) orelse
        return error.SyntheticPointerNotRouted;
    const window_event = switch (routed) {
        .window => |value| value,
        .display, .system_wake, .drop => return error.SyntheticPointerNotRouted,
    };
    if (!std.meta.eql(window_event.handle, slot.handle)) {
        return error.SyntheticPointerWrongWindow;
    }
    const translated = switch (window_event.translated orelse {
        return error.SyntheticPointerNotTranslated;
    }) {
        .input => |value| value,
        .close, .resize, .key_down => return error.SyntheticPointerNotTranslated,
    };
    const move = switch (translated) {
        .mouse_move => |value| value,
        else => return error.SyntheticPointerNotTranslated,
    };
    // The App resolves the committed tree, the phase and the owning component
    // for this event; nothing else forwards it.
    _ = try slot.app.handle(translated);
    smoke.pointer_logical = slot.app.mouse_pos orelse return error.SyntheticPointerNotApplied;
    // The COMMITTED tree decides what is under the point, not the event. The
    // translation is only interesting because it lands where the drawn
    // content is.
    const tree = slot.app.tree_ptr orelse return error.NoCommittedTree;
    const probe = slot.pane.probe orelse return error.ScaleWatchProbeMissing;
    const area = slot.candidate.area;
    const hit = nogui.hitTest(tree, .{ move.x, move.y });
    smoke.pointer_hits_probe = slot.candidate.present and
        area.w > 0 and area.h > 0 and
        move.x >= area.x and move.x < area.x + area.w and
        move.y >= area.y and move.y < area.y + area.h and
        hit != null and hit.? == probe.field;
}

// ── real pointer ingress ────────────────
//
// Everything below counts only what SDL's own queue produced. There is no path
// here that builds a pointer event: the synthetic probe above hands its own
// event straight to `Application.dispatch` and never touches this boundary, so
// `ingress_motion` and `synthetic_pointer_events` cannot overlap.
//
// The drain runs IN FRONT of `Application.step`, in every pump. That ordering
// is the whole measurement: `step` polls the same queue and would consume a
// motion undifferentiated, and the event's identity is the only difference
// between "the compositor said so" and "the run moved a pointer". Anything
// `step` did consume first is still counted, by the production hook, and the
// difference is printed as `unaccounted_motion` rather than folded into one
// number.

/// The window the pointer watch watches, resolved once so the drain never has
/// to search for it per event. Its native id, slot and generation are printed
/// on every ingress line, so a driver can tell which window answered.
const IngressWatch = struct {
    slot: *WindowSlot,
    managed: *ManagedWindow,
    native_id: sdl3.video.WindowId,
};

/// One drained batch, snapshotted by VALUE. Nothing here points into a frame
/// arena or into the App's double-buffered tree: the report is written before
/// the next frame can reset either, and no snapshot survives the line.
const IngressBatch = struct {
    /// The last routed point, window-logical: what `Window.translate` produced
    /// and what the committed tree is hit-tested in. This is the driver's
    /// affine-fit input.
    logical: [2]f32 = .{ 0, 0 },
    /// The same event's coordinates as they appear in the SDL `mouse_motion`,
    /// plus the raw relative motion. Reported so nothing converted is ever
    /// called raw and nothing raw is ever called converted.
    native: [2]f32 = .{ 0, 0 },
    delta: [2]f32 = .{ 0, 0 },
    /// Whether the raw numbers and the routed numbers are equal. A measured
    /// property of this host's translation, never an assertion about which
    /// space SDL chose to report in.
    matches_native: bool = true,
    /// Whether this batch carried a watched `mouse_motion` and therefore a
    /// POINT. A batch that carries only an enter or a leave has none: the
    /// window learned that the pointer arrived or left without being told
    /// where to, so every coordinate above is left at its default and this
    /// flag is what tells a reader not to read them. Without it a driver
    /// pairing a commanded aim with a sample can pair it with the origin and
    /// fit its mapping to a point the compositor never reported.
    motion: bool = false,
    /// Whether this batch carried watched ingress worth a line. Only the
    /// watched window raises it, so a peer's motion never produces a sample
    /// carrying the peer's coordinates under the watched window's identity.
    seen: bool = false,
};

/// Whether a routed event names the window this watch is watching. The slot's
/// generational handle is the whole test: an event for a peer, for a window
/// this run never opened, or for one the host has already retired, does not
/// match, and reading the peer's slot would describe a surface the report is
/// not about.
fn isWatched(watch: IngressWatch, handle: contract.WindowHandle) bool {
    return watch.slot.handle.eql(handle);
}

/// THE drain: poll every event SDL really delivered, count it, tag it for the
/// scale accounting, dispatch it, and — when a watch is set — attribute it as
/// pointer ingress. One pass, one poll per event, in that order.
///
/// It used to be two drains run back to back: a pointer drain first and a raw
/// tag loop second. The second therefore found an EMPTY queue whenever the
/// first had a watch attached, so a run with a pointer watch reported
/// `raw_events=0` and `real_scale_events=0` for a transition the host had
/// already routed — the two drains competed for one queue instead of
/// describing it, and `ScaleWatchNoRealEvent` then failed a run that had seen
/// the change end to end. They cannot compete here, because there is only one
/// of them.
///
/// Ordering inside the loop is the whole claim: the tag is read BEFORE the
/// dispatch, so `display_scale_events` describes what the platform said and
/// `routed_*_scale_events` describes what this repository did with it, and the
/// two can be read against each other. Dispatching every drained event and not
/// only the pointer ones is deliberate: `step` would have routed all of them,
/// and skipping any would change the host's own state instead of only
/// observing it.
///
/// The attribution is the host's answer and not this file's. A motion SDL
/// delivered and the host routed to nobody reached no client; one it routed for
/// a peer is that peer's; only one it translated into a `mouse_move` for the
/// watched window is watched ingress, and only that motion gives the batch a
/// point.
fn drainHostEvents(
    smoke: *Smoke,
    report: *Reporter,
    watch: ?IngressWatch,
) !void {
    var batch: IngressBatch = .{};
    var drained: u16 = 0;
    poll: while (drained < 256) : (drained += 1) {
        const raw = smoke.application.pollEvent() orelse break;
        smoke.raw_events += 1;
        switch (raw) {
            .display_content_scale_changed => smoke.display_scale_events += 1,
            .display_moved,
            .display_desktop_mode_changed,
            .display_current_mode_changed,
            .display_usable_bounds_changed,
            => smoke.display_geometry_events += 1,
            .window_display_scale_changed => smoke.window_scale_events += 1,
            .window_pixel_size_changed => smoke.window_pixel_size_events += 1,
            else => {},
        }
        const routed = try smoke.application.dispatch(&raw);
        const view = watch orelse continue :poll;
        const window_event = switch (routed orelse {
            // A motion SDL delivered and the host routed to NOTHING reached no
            // client at all: an unknown native window, or one whose
            // generational or timestamp check refused it. A real delivery, and
            // not ingress, so it is counted as refused and never as watched.
            if (raw == .mouse_motion) smoke.ingress_refused_motion += 1;
            continue :poll;
        }) {
            .window => |value| value,
            .display, .drop, .system_wake => continue :poll,
        };
        switch (raw) {
            .mouse_motion => |motion| {
                // The host's own answer decides whether this was pointer input
                // at all, and its two ways of saying no are counted apart. A
                // motion it translated into nothing was not delivered to a
                // client, so it is REFUSED; a motion it did route, for a
                // different window, is that window's, so it is OTHER. Neither
                // is watched ingress, and only the last case below is.
                const move = switch (window_event.translated orelse {
                    smoke.ingress_refused_motion += 1;
                    continue :poll;
                }) {
                    .input => |event| switch (event) {
                        .mouse_move => |value| value,
                        else => {
                            smoke.ingress_refused_motion += 1;
                            continue :poll;
                        },
                    },
                    .close, .resize, .key_down => {
                        smoke.ingress_refused_motion += 1;
                        continue :poll;
                    },
                };
                if (!isWatched(view, window_event.handle)) {
                    smoke.ingress_other_motion += 1;
                    continue :poll;
                }
                batch.native = .{ motion.x, motion.y };
                batch.delta = .{ motion.x_rel, motion.y_rel };
                batch.logical = .{ move.x, move.y };
                batch.matches_native = motion.x == move.x and motion.y == move.y;
                batch.motion = true;
                batch.seen = true;
                smoke.ingress_motion += 1;
                smoke.phase_motion += 1;
                if (smoke.ingress_first == null) smoke.ingress_first = batch.logical;
                smoke.ingress_last = batch.logical;
            },
            .window_mouse_enter => {
                if (!isWatched(view, window_event.handle)) continue :poll;
                batch.seen = true;
                smoke.ingress_enter += 1;
            },
            .window_mouse_leave => {
                if (!isWatched(view, window_event.handle)) continue :poll;
                batch.seen = true;
                smoke.ingress_leave += 1;
            },
            else => {},
        }
    }
    const active = watch orelse return;
    if (!batch.seen) return;
    try emitIngress(smoke, report, active, batch);
}

/// Everything an operator needs to AIM a real pointer at the committed
/// probe, read live rather than from the last observed snapshot: the output
/// scale the platform reports right now, the window's logical and pixel
/// extents right now, and the committed rectangle right now. A sweep that
/// moved the scale between two samples must not be readable as if one value
/// held throughout, so every reader of these facts goes through here.
///
/// The rectangle borrows `report.scratch`, which is why it is a value a caller
/// prints before formatting anything else into that buffer.
const PointerAim = struct {
    output_scale: f32,
    logical_width: u32,
    logical_height: u32,
    pixel_width: u32,
    pixel_height: u32,
    rect: []const u8,
    generation: u64,
};

fn readPointerAim(report: *Reporter, watch: IngressWatch) !PointerAim {
    const slot = watch.slot;
    const logical = try watch.managed.native.logicalSize();
    const pixels = try watch.managed.native.pixelExtent();
    const candidate = slot.candidate;
    return .{
        .output_scale = try watch.managed.native.sdl.getDisplayScale(),
        .logical_width = @intFromFloat(logical.width),
        .logical_height = @intFromFloat(logical.height),
        .pixel_width = pixels.width,
        .pixel_height = pixels.height,
        .rect = if (candidate.present)
            std.fmt.bufPrint(
                &report.scratch,
                "({d:.2},{d:.2} {d:.2}x{d:.2})",
                .{ candidate.area.x, candidate.area.y, candidate.area.w, candidate.area.h },
            ) catch "<err>"
        else
            "none",
        .generation = candidate.generation,
    };
}

/// One `PTR real` line: what the compositor delivered, in the space the client
/// works in, beside the space it came from.
///
/// Everything is read AFTER the batch was dispatched — the counters, the routed
/// point, the committed tree hit test, the live window geometry and the live
/// display scale — so no field describes a moment before the event it reports.
///
/// `motion_in_batch` says whether this line's `x`, `y`, `dx`, `dy`,
/// `native_x`, `native_y` and `inside_committed_probe` describe a POINT the
/// compositor reported. A batch that carried only an enter or a leave reported
/// none, so those fields are their defaults and the flag is false. Without it
/// a driver that pairs a commanded aim with a sample could pair the aim with an
/// origin and fit its mapping to a point the compositor never sent.
///
/// `window_title` is the title the host was given at the open, so an operator can
/// tie this line to a surface the COMPOSITOR lists. The compositor lists
/// titles; `window_name` is this run's own slot name and nothing outside this
/// file has ever heard of it.
fn emitIngress(
    smoke: *Smoke,
    report: *Reporter,
    watch: IngressWatch,
    batch: IngressBatch,
) !void {
    const slot = watch.slot;
    // Live platform reads, not the last observed snapshot: the report says
    // what the window is NOW, so a sweep that moved the scale mid-hold cannot
    // be read as if one value held throughout.
    const aim = try readPointerAim(report, watch);
    const inside = ingressInsideProbe(slot, batch.logical);
    try report.emit(
        "PTR real ingress_motion={d} motion_in_batch={} x={d:.2} y={d:.2}" ++
            " dx={d:.2} dy={d:.2}" ++
            " enter={d} leave={d} inside_committed_probe={}" ++
            " window_logical={d}x{d} window_pixels={d}x{d} output_scale={d:.3}" ++
            " source=compositor-ingress native_x={d:.2} native_y={d:.2}" ++
            " native_units=sdl-window-units logical_matches_native={}" ++
            " window_id={d} window_slot={d} window_generation={d} window_name={s}" ++
            " window_title={s}" ++
            " probe_rect={s} probe_frame_generation={d} phase={s}" ++
            " other_window_motion={d} refused_motion={d} routed_pointer_motion={d}\n",
        .{
            smoke.ingress_motion,
            batch.motion,
            batch.logical[0],
            batch.logical[1],
            batch.delta[0],
            batch.delta[1],
            smoke.ingress_enter,
            smoke.ingress_leave,
            inside,
            aim.logical_width,
            aim.logical_height,
            aim.pixel_width,
            aim.pixel_height,
            aim.output_scale,
            batch.native[0],
            batch.native[1],
            batch.matches_native,
            watch.native_id,
            slot.handle.slot,
            slot.handle.generation,
            slot.name,
            slot.title,
            aim.rect,
            aim.generation,
            smoke.pointer_phase,
            smoke.ingress_other_motion,
            smoke.ingress_refused_motion,
            smoke.routed_pointer_motion,
        },
    );
}

/// Print the one `PTR real armed` line, over the phase the caller has already
/// set in `Smoke.pointer_phase`.
///
/// It is the line an operator waits for before they move any pointer: the
/// watch exists but nothing has been counted yet, so every later sample is
/// attributable to a motion that came after this point. Its head is
/// `PTR real armed`, not `PTR real`, so a driver keyed on the sample head
/// cannot read it as a sample, and the window name uses the SAME
/// `window_name` key the samples and the summary use — one spelling, so a
/// reader never has to know which line it is looking at to find the name.
///
/// It also carries `window_title`, the title the host was given at the open,
/// under the SAME spelling the samples use. It is there for the one thing
/// `window_name` cannot do: name this window to a COMPOSITOR, which lists
/// titles and has never heard of this run's slot names. Without it an operator
/// cannot say which of the client's two windows it is aiming at.
///
/// Both arming sites go through here, so a hold-only run and a scale-watch run
/// cannot drift apart in what they promise a driver before the first motion.
fn emitPointerArmed(smoke: *Smoke, report: *Reporter, watch: IngressWatch) !void {
    const slot = watch.slot;
    const aim = try readPointerAim(report, watch);
    try report.emit(
        "PTR real armed window_name={s} window_title={s} window_id={d}" ++
            " window_slot={d}" ++
            " window_generation={d} probe={} window_logical={d}x{d}" ++
            " window_pixels={d}x{d} output_scale={d:.3} probe_rect={s}" ++
            " probe_frame_generation={d} ingress_motion={d} phase={s}" ++
            " source=compositor-ingress\n",
        .{
            slot.name,
            slot.title,
            watch.native_id,
            slot.handle.slot,
            slot.handle.generation,
            slot.candidate.present,
            aim.logical_width,
            aim.logical_height,
            aim.pixel_width,
            aim.pixel_height,
            aim.output_scale,
            aim.rect,
            aim.generation,
            smoke.ingress_motion,
            smoke.pointer_phase,
        },
    );
}

/// Move the watch into its next phase, bank the phase it is leaving, and
/// print the one `PTR real phase` line that names the change.
///
/// The counters move first so the line reports ingress the switch itself can
/// see rather than the total a reader has to subtract: `earlier_phase_motion`
/// is the finished phase and `ingress_motion` the whole run. The line carries
/// the fresh committed rectangle and the live window and output extents,
/// because an operator that is about to aim a pointer needs the numbers
/// the NEW scale produced, and it cannot derive them from the baseline it was
/// handed earlier.
fn enterPointerPhase(
    smoke: *Smoke,
    report: *Reporter,
    watch: IngressWatch,
    previous: []const u8,
    phase: []const u8,
    scale_transition_observed: bool,
) !void {
    smoke.earlier_phase_motion += smoke.phase_motion;
    smoke.phase_motion = 0;
    smoke.pointer_phase = phase;
    const slot = watch.slot;
    const aim = try readPointerAim(report, watch);
    try report.emit(
        "PTR real phase label={s} previous_phase={s}" ++
            " scale_transition_observed={} ingress_motion={d} phase_motion={d}" ++
            " earlier_phase_motion={d} window_name={s} window_title={s}" ++
            " window_id={d}" ++
            " window_logical={d}x{d} window_pixels={d}x{d} output_scale={d:.3}" ++
            " probe_rect={s} probe_frame_generation={d} source=compositor-ingress\n",
        .{
            phase,
            previous,
            scale_transition_observed,
            smoke.ingress_motion,
            smoke.phase_motion,
            smoke.earlier_phase_motion,
            slot.name,
            slot.title,
            watch.native_id,
            aim.logical_width,
            aim.logical_height,
            aim.pixel_width,
            aim.pixel_height,
            aim.output_scale,
            aim.rect,
            aim.generation,
        },
    );
}

/// The committed-tree hit test the synthetic probe uses, evaluated at a REAL
/// pointer position. Identical geometry rules, so the two answers are
/// comparable: the COMMITTED tree decides what is under the point, not the
/// event that carried it.
fn ingressInsideProbe(slot: *WindowSlot, at: [2]f32) bool {
    const probe = slot.pane.probe orelse return false;
    const area = slot.candidate.area;
    if (!slot.candidate.present or area.w <= 0 or area.h <= 0) return false;
    const tree = slot.app.tree_ptr orelse return false;
    const hit = nogui.hitTest(tree, at);
    return at[0] >= area.x and at[0] < area.x + area.w and
        at[1] >= area.y and at[1] < area.y + area.h and
        hit != null and hit.? == probe.field;
}

/// The closing `PTR real summary` line.
///
/// The three ingress counters are a partition, not a ranking: every
/// `mouse_motion` this run drained is in exactly one of them. `motion` and
/// `other_window_motion` are the two the host ROUTED as pointer input, so their
/// sum is what the production hook must also have seen; `refused_motion` is the
/// deliveries it routed to nobody and therefore never reached the hook at all.
///
/// That partition is what makes `unaccounted_motion` well-founded. It is the
/// positive-only gap between what the hook saw and what this drain attributed.
/// The drain now runs in front of `Application.step()` in EVERY pump, so the
/// ordering gap that used to leave motions here for the hook alone is closed;
/// what is left is the run's own teardown sections, which call `step`
/// directly after the pointer is no longer being driven. Refused motions are
/// excluded from the comparison instead of being clamped away, because
/// counting one on the drain side and not on the hook side would make the gap
/// negative for a run whose ingress is sound.
fn emitIngressSummary(smoke: *Smoke, report: *Reporter, watch: IngressWatch) !void {
    const routed_by_this_drain = smoke.ingress_motion + smoke.ingress_other_motion;
    const unaccounted = smoke.routed_pointer_motion -| routed_by_this_drain;
    const first = pointText(&report.scratch, smoke.ingress_first);
    const last = pointText(&report.tail, smoke.ingress_last);
    try report.emit(
        "PTR real summary motion={d} enter={d} leave={d} first={s} last={s}" ++
            " window_id={d} window_slot={d} window_title={s}" ++
            " other_window_motion={d}" ++
            " refused_motion={d} routed_pointer_motion={d} unaccounted_motion={d}" ++
            " synthetic_pointer_events={d} phase={s} phase_motion={d}" ++
            " earlier_phase_motion={d} source=compositor-ingress\n",
        .{
            smoke.ingress_motion,
            smoke.ingress_enter,
            smoke.ingress_leave,
            first,
            last,
            watch.native_id,
            watch.slot.handle.slot,
            watch.slot.title,
            smoke.ingress_other_motion,
            smoke.ingress_refused_motion,
            smoke.routed_pointer_motion,
            unaccounted,
            smoke.synthetic_pointer_events,
            smoke.pointer_phase,
            smoke.phase_motion,
            smoke.earlier_phase_motion,
        },
    );
}

/// A point formatted for the summary, or `<none>` when real ingress never
/// produced one. "No real pointer arrived" and "the pointer arrived at the
/// origin" must not print the same.
fn pointText(buffer: []u8, point: ?[2]f32) []const u8 {
    const value = point orelse return "<none>";
    return std.fmt.bufPrint(buffer, "({d:.2},{d:.2})", .{ value[0], value[1] }) catch "<err>";
}

/// Pump the production loop until the observed scale has moved off the
/// baseline, the deadline passes, or the host stops.
///
/// `drainHostEvents` runs HERE, in front of `Application.step()`, because
/// `step` polls the same queue and would consume every event undifferentiated:
/// the tag is the whole difference between "the platform said so" and
/// "something changed", and the pointer identity is the whole difference
/// between compositor ingress and nothing at all. ONE drain does both, so a
/// run that also armed a pointer watch still measures the scale transition it
/// was asked to watch.
fn pumpScaleWatch(
    smoke: *Smoke,
    report: *Reporter,
    deadline_ms: u64,
    baseline: ScaleReading,
    watch: ?IngressWatch,
) !bool {
    while (sdl3.timer.getMillisecondsSinceInit() < deadline_ms) {
        smoke.steps += 1;
        try drainHostEvents(smoke, report, watch);
        if (!try smoke.application.step()) {
            smoke.host_running = false;
            return false;
        }
        const now = try readScale(
            smoke,
            &smoke.windows[0],
            baseline.anchor_logical,
        );
        if (scaleMoved(baseline, now)) return true;
        if (try smoke.application.nextWaitMilliseconds()) |delay| {
            if (delay > 4) _ = sdl3.events.waitAndPopTimeout(@min(delay, 16));
        }
        try Io.sleep(smoke.io, Io.Duration.fromMilliseconds(4), .real);
    }
    return false;
}

/// Pump the external loop until `predicate` holds, the host stops, or the
/// deadline passes. Returns whether the predicate settled; `smoke.host_running`
/// records whether `Application.step()` ever reported the host stopped.
///
/// It drains through `drainHostEvents` for the same reason `pumpScaleWatch`
/// does, and `watch` is null wherever ingress is not being counted. The drain
/// runs either way: an event the queue produced is tagged and dispatched here
/// exactly as `step` would have, so no pump in this file can become the one
/// place the host's own accounting is taken apart behind the run's back. With
/// a watch set, the motion that arrives between the scale pump and the hold
/// lands here instead of being swallowed by `step` and left to the hook alone.
fn pumpUntil(
    smoke: *Smoke,
    report: *Reporter,
    watch: ?IngressWatch,
    deadline_ms: u64,
    context: *const fn (*Smoke) bool,
) !bool {
    // Counted here so the run can report that it drove the host itself.
    while (sdl3.timer.getMillisecondsSinceInit() < deadline_ms) {
        smoke.steps += 1;
        try drainHostEvents(smoke, report, watch);
        if (!try smoke.application.step()) {
            smoke.host_running = false;
            break;
        }
        if (context(smoke)) return true;
        if (try smoke.application.nextWaitMilliseconds()) |delay| {
            if (delay > 4) _ = sdl3.events.waitAndPopTimeout(@min(delay, 16));
        }
        try Io.sleep(smoke.io, Io.Duration.fromMilliseconds(4), .real);
    }
    return context(smoke);
}

/// True once every live window has committed the frames this run asks for. A
/// window whose present path is held still can commit exactly one more, the
/// one submitted without a present, so waiting for three of them would only
/// burn the pump deadline.
fn firstFramesDone(smoke: *Smoke) bool {
    for (smoke.live()) |slot| {
        const needed: u32 = if (slot.present_held) 1 else 3;
        if (slot.frames_committed < needed) return false;
    }
    return smoke.live().len > 0;
}

/// True once the FIRST window has committed a frame carrying the probe, so
/// the committed content box both watches measure against exists. A window
/// that has only been opened has published nothing, and a baseline taken over
/// a tree that never held the probe would compare a rectangle against
/// nothing — so both watches wait for this instead of assuming it.
fn probeCommitted(smoke: *Smoke) bool {
    return smoke.windows[0].candidate.present;
}

/// True once every live window has taken its one commit-without-present
/// frame. Used by `--present-frames` to stop the present path after the
/// commit path has still run on the GPU.
fn commitOnlyFrameTaken(smoke: *Smoke) bool {
    for (smoke.live()) |slot| {
        if (slot.frames_without_present < 1) return false;
    }
    return smoke.live().len > 0;
}

fn resized(smoke: *Smoke) bool {
    const managed = smoke.application.getWindow(smoke.windows[0].handle) catch return false;
    return managed.observed.size.width == 900 and managed.observed.size.height == 620;
}

/// True only when the platform reports the window minimized. A backend that
/// cannot observe minimization never reports it, so this stays false there and
/// the run says so through the capability line instead of asserting a value.
fn minimized(smoke: *Smoke) bool {
    const managed = smoke.application.getWindow(smoke.windows[0].handle) catch return false;
    return managed.observed.minimized orelse false;
}

/// True once the window is not minimized. Where the platform cannot observe
/// minimization there is no such observation to clear, so the check rests on
/// what SDL does report: the window is visible again.
fn restored(smoke: *Smoke) bool {
    const managed = smoke.application.getWindow(smoke.windows[0].handle) catch return false;
    const state = managed.observed.minimized orelse return managed.observed.visible;
    return !state;
}

/// An observation the platform never made must not print as a flat `false`.
fn minimizedText(state: ?bool) []const u8 {
    const value = state orelse return "unobservable";
    return if (value) "minimized" else "not-minimized";
}

/// Keep pumping the external loop for `millis`, reporting every window's
/// observed state at the end. An external compositor capture is taken during
/// this window; the capture is evidence, not the measurement.
///
/// `watch` is the pointer watch, and it is null in the default run and in the
/// minimized hold: ingress is only counted while BOTH windows are up, because
/// a minimized window has no client pointer to receive one. When it is set,
/// `drainHostEvents` runs IN FRONT of `Application.step` — the same ordering
/// and the same reason as everywhere else: `step` polls the same queue and
/// would consume a motion undifferentiated, and that identity is the whole
/// difference between compositor ingress and nothing at all.
fn holdForCapture(
    smoke: *Smoke,
    report: *Reporter,
    millis: u64,
    label: []const u8,
    watch: ?IngressWatch,
) !void {
    const application = smoke.application;
    try report.emit("HOLD-BEGIN {s} {d}ms\n", .{ label, millis });
    const until = sdl3.timer.getMillisecondsSinceInit() + millis;
    while (sdl3.timer.getMillisecondsSinceInit() < until) {
        try drainHostEvents(smoke, report, watch);
        _ = try application.step();
        try Io.sleep(smoke.io, Io.Duration.fromMilliseconds(8), .real);
    }
    try drainHostEvents(smoke, report, watch);
    for (smoke.live()) |*slot| {
        const managed = try application.getWindow(slot.handle);
        try report.emit(
            "hold {s} [{s}]: size={d}x{d} visible={} occluded={} minimized={s} focused={}\n",
            .{
                label,
                slot.name,
                managed.observed.size.width,
                managed.observed.size.height,
                managed.observed.visible,
                managed.observed.occluded,
                minimizedText(managed.observed.minimized),
                managed.observed.focused,
            },
        );
        try reportPresent(smoke, report, slot);
    }
    try report.emit("HOLD-END {s}\n", .{label});
}

/// Render an optional window bound into `buffer`. Absent is "<none>", which is
/// different from a zero bound the platform would report for "no limit".
fn sizeText(buffer: []u8, size: ?contract.Size) []const u8 {
    const value = size orelse return "<none>";
    return std.fmt.bufPrint(buffer, "{d}x{d}", .{ value.width, value.height }) catch "<err>";
}

/// One worker whose completion is counted per window, so a close during queued
/// work can be told apart from a close that also swallowed a peer.
const QueuedWork = struct {
    release_gate: *std.atomic.Value(bool),
    ran: *std.atomic.Value(bool),
    delivered: *std.atomic.Value(u32),

    fn run(self: *QueuedWork, _: std.Io) void {
        // Both completions stay behind closeWindow. Without this gate the
        // worker can deliver before retirement and the check proves nothing.
        while (!self.release_gate.load(.acquire)) std.Thread.yield() catch return;
        self.ran.store(true, .release);
    }

    fn applied(_: *Document, self: *QueuedWork, _: *Session) void {
        _ = self.delivered.fetchAdd(1, .acq_rel);
    }
};

/// Release the noapi surface that presents into one platform window, and the
/// paint resources that window owns. This is the first thing a window's
/// teardown must do and it must happen while the platform window is still
/// alive, which is why the host's own `on_before_close` hook calls it from
/// inside that close, and why the cleanup owner calls it before it hands the
/// window back.
///
/// The surface goes first because it presents INTO the platform window. This
/// window's Oklab target and blit heap go next, and `WindowPaint.deinit`
/// idles the device before destroying either, because the frames still queued
/// for this window name both. All of it is gone before `Gpu.deinit`.
///
/// The flag is what makes this idempotent, and it has to stay that way: a
/// window the SCENARIO closed has already been through here once, and a
/// second release must not reach the backend.
fn releaseSurface(slot: *WindowSlot) void {
    if (slot.surface_released) return;
    slot.surface_released = true;
    slot.surface.deinit();
    slot.paint.deinit();
}

/// A lifetime violation inside this run's own cleanup.
///
/// It is a panic and not an error return because every caller of `Run.unwind`
/// is already leaving: the last line of the run, or the `errdefer` of an
/// error that is already on its way out. There is nowhere left to report a
/// failure to, and the alternative — carrying on — is a window the host can
/// still reach through an App this run is about to free.
///
/// The reason is formatted into a stack buffer, so a caller can name the
/// error it actually saw without allocating on a path that is unwinding.
fn refuse(reason: []const u8) noreturn {
    var buffer: [192]u8 = undefined;
    // The result is pinned to `[]const u8` on purpose: `bufPrint` hands back a
    // mutable `[]u8`, and a bare string literal on the right of a `catch`
    // cannot become one, so leaving the type to inference would not compile.
    const line: []const u8 = std.fmt.bufPrint(
        &buffer,
        "W07 cleanup refused: {s}",
        .{reason},
    ) catch "W07 cleanup refused";
    @panic(line);
}

/// The window the host has opened but whose slot has not been written.
///
/// Every field carries its own flag, because the failure this record exists
/// for can land between any two of them. The host BORROWS the App from the
/// moment `openWindowWithApp` returns and dereferences it in its own close
/// path, so from that moment the App may not be destroyed before the host has
/// closed the window, and the noapi surface may not outlive the platform
/// window it presents into.
const PendingWindow = struct {
    app: ?*App = null,
    pane: ?*Pane = null,
    /// Set the moment the host accepted `app`. Null means no window was ever
    /// opened for this record, so the App was only ever this run's.
    handle: ?contract.WindowHandle = null,
    /// The noapi surface once `initSdl` returned one, and this window's Oklab
    /// target and blit heap with it. All three are released while the
    /// platform window is still alive.
    surface: ?noapi.Surface = null,
    paint: ?WindowPaint = null,
    /// Set once the host has retired the window. `Run` reads this and not
    /// `slot.closed`, because the hooks are installed after the open loop and
    /// an unwind inside that loop has no hook to tell it anything.
    closed: bool = false,

    fn releaseSurface(self: *PendingWindow) void {
        if (self.surface) |*surface| {
            surface.deinit();
            self.surface = null;
        }
        if (self.paint) |*paint| {
            paint.deinit();
            self.paint = null;
        }
    }
};

/// Everything this binary owns, and the ONE order it may be released in.
///
/// Both exits go through `unwind`: the error path its `errdefer` takes, and
/// the last line of a successful run. Nothing else in this file destroys an
/// App, a Pane, a surface, a device or the Session, so "which of these is
/// still live" is answered in one place and not in a dozen `errdefer`s whose
/// relative order is a guess.
///
/// The order is the host's lifetime contract, not a preference:
///   1. every window this run opened goes back to the HOST, while the
///      caller-owned App and Pane, the device, that window's surface and blit
///      heap, and the endpoint both Apps mounted are still whole — the host's
///      own close path dereferences `window.app` on each of them;
///   2. each App unmounts its keyed components and detaches its GPU mounts,
///      and only then is the storage those mounts named released: the Pane
///      first, then the App;
///   3. the scale probe, which a mounted component can still name, after the
///      last App that could have named it;
///   4. the scene scratch, then the shared pipeline: both borrow
///      `Paint.renderer` and both release through the device, so the device
///      outlives them;
///   5. the device, before `Application.deinit` quits SDL and unloads the
///      Vulkan loader a live `VkDevice` would dispatch through;
///   6. the host, which closes whatever the run itself left open — every one
///      of those an App the host owns itself, never a borrowed one — and
///      quits SDL, which is the last Vulkan loader holder;
///   7. the model, then the Session that owns the model store and the task
///      service the host has already unregistered its wake from.
const Run = struct {
    gpa: std.mem.Allocator,

    /// Heap storage for the Session and the Application. Null means this run
    /// never created it, which is what lets the unwind skip it instead of
    /// destroying a pointer it never had.
    session: ?*Session = null,
    application: ?*Application = null,
    /// The one model both windows read. It is released before the Session
    /// that owns the store, and exactly once.
    model: ?nogui.Model(Document) = null,

    /// The per-window storage, one slot per window this run may open. A slot
    /// is written only after every fallible step that follows its open has
    /// succeeded, so `opened` counts complete slots and nothing reads past it.
    slots: [2]WindowSlot,
    opened: usize = 0,
    /// The window in flight, for a run that failed between its open and its
    /// slot write. Empty whenever no window is halfway through.
    pending: PendingWindow = .{},
    /// The scale probe, when this run armed a watch. An App's component
    /// registry holds the pointer for as long as the keyed component is
    /// mounted, so it outlives every frame that can name it.
    probe: ?*Probe = null,

    /// The shared pipeline, the scene scratch that borrows its renderer, and
    /// the device. All three are borrowed from the enclosing `main`, which
    /// outlives this struct; each is null exactly once it has been released.
    paint: ?*Paint = null,
    scene: ?*frame_scene.SceneScratch = null,
    gpu: ?*noapi.Gpu = null,

    /// Why the Session refused to shut down, when it did. A Session that
    /// still owns live models or unfinished work is a FAILED run: its storage
    /// is deliberately left alone rather than destroyed over what it owns, so
    /// the reason is kept for the report instead of dropped.
    session_error: ?anyerror = null,

    /// Release one window's App and its view.
    ///
    /// The noapi surface is NOT released here: `closeWindows` released it
    /// while the platform window was still alive, and the host destroys that
    /// window inside `closeWindow`. The App first, because its component
    /// registry still holds this Pane and its keyed components can still hold
    /// the probe; then the Pane, because the App is what names it; then the
    /// App's own storage.
    fn releaseSlot(self: *Run, slot: *WindowSlot) void {
        if (slot.released) return;
        slot.released = true;
        std.debug.assert(slot.surface_released);
        std.debug.assert(slot.closed);
        slot.app.deinit();
        self.gpa.destroy(slot.pane);
        self.gpa.destroy(slot.app);
    }

    /// Hand every window this run opened back to the host, in the only order
    /// the host can accept it. The surface presents INTO the platform window
    /// and its swapchain names the X11 `Window` that `SDL_DestroyWindow`
    /// frees, so the surface and this window's blit heap go first, while that
    /// window is still alive. `on_before_close` releases the same pair and
    /// `releaseSurface` is idempotent, so this is the one order whether or
    /// not the hooks were installed yet.
    fn closeWindows(self: *Run) void {
        const application = self.application orelse return;
        for (self.slots[0..self.opened]) |*slot| {
            releaseSurface(slot);
            if (slot.closed) continue;
            closeOne(application, slot.handle);
            slot.closed = true;
        }
        self.pending.releaseSurface();
        if (self.pending.handle) |handle| {
            if (!self.pending.closed) {
                closeOne(application, handle);
                self.pending.closed = true;
            }
        }
    }

    /// The Apps, then the storage they named. Every window above is retired
    /// first: an App destroyed while the host still holds its window is the
    /// use-after-free this owner exists to make impossible.
    fn releaseWindows(self: *Run) void {
        for (self.slots[0..self.opened]) |*slot| self.releaseSlot(slot);
        // A window in flight is the same story: the host borrowed its App, so
        // it unmounts and is released only after the close above retired the
        // window. A window that was never opened never needed one.
        if (self.pending.app) |app| {
            if (self.pending.handle != null and !self.pending.closed)
                refuse("a window's App was released while the host still held it");
            const pane = self.pending.pane orelse
                refuse("a window's Pane was never allocated but its App was");
            app.deinit();
            self.gpa.destroy(pane);
            self.gpa.destroy(app);
            self.pending.app = null;
        }
        self.opened = 0;
    }

    fn releaseProbe(self: *Run) void {
        const probe = self.probe orelse return;
        self.gpa.destroy(probe);
        self.probe = null;
    }

    fn releasePipeline(self: *Run) void {
        if (self.scene) |scene| {
            self.scene = null;
            scene.deinit();
        }
        if (self.paint) |paint| {
            self.paint = null;
            paint.deinit();
        }
    }

    fn releaseDevice(self: *Run) void {
        const gpu = self.gpu orelse return;
        self.gpu = null;
        gpu.deinit();
    }

    fn releaseHost(self: *Run) void {
        const application = self.application orelse return;
        self.application = null;
        // Whatever the run itself left open belongs to the host, so this
        // closes it without reaching for a borrowed App this run has already
        // released, and then quits SDL.
        application.deinit();
        self.gpa.destroy(application);
    }

    fn releaseModel(self: *Run) void {
        const session = self.session orelse return;
        if (self.model) |*model| {
            session.release(Document, model) catch
                @panic("W07 smoke could not release the model it owns");
            self.model = null;
        }
    }

    fn releaseSession(self: *Run) !void {
        // A Session that already refused is left exactly as it is: it still
        // owns live work, and destroying its storage over that would turn a
        // reported leak into a use-after-free.
        if (self.session_error != null) return;
        const session = self.session orelse return;
        try session.deinit();
        self.gpa.destroy(session);
        self.session = null;
    }

    /// The one cleanup owner. Every step is guarded by the flag that says its
    /// resource exists, so this is safe to call twice: a successful run calls
    /// it at its last line, and an error anywhere above calls it from the
    /// `errdefer` that has been live since before anything was created.
    fn unwind(self: *Run) void {
        self.closeWindows();
        self.releaseWindows();
        self.releaseProbe();
        self.releasePipeline();
        self.releaseDevice();
        self.releaseHost();
        self.releaseModel();
        self.releaseSession() catch |err| {
            self.session_error = err;
        };
    }
};

/// One close, or a refusal that names itself. An already-retired handle is
/// the state `closeWindows` exists to reach, so it is not a failure. A window
/// the host will not close is the opposite: the App behind it is about to be
/// released, and a window the host still holds would reach it.
fn closeOne(application: *Application, handle: contract.WindowHandle) void {
    // The invariant this exists to keep: by the time it returns, the host no
    // longer holds a window that reaches an App `Run` is about to release. A
    // handle the host has already retired IS that state, so it is not a
    // failure — anything else is, and a veto is one: `closeWindow` answers
    // false without touching the window.
    if (application.closeWindow(handle)) |closed| {
        if (!closed) refuse("the host refused to close a window this run must retire");
    } else |err| {
        if (err != error.StaleWindow) refuse(@errorName(err));
    }
}

/// How far the task service got before the storage it was aimed at died.
const TaskSettle = struct {
    /// Completions delivered, over every poll below.
    drained: usize,
    /// True when nothing was queued, running, ready, on a UI timer or
    /// cancelled. False means a worker is still reading or writing the
    /// storage it was given.
    settled: bool,
};

/// Open the gate and drive the task service to quiescence, over at most
/// `rounds` polls of `waitForTaskWake`.
///
/// This is the only thing that makes `QueuedWork`'s block-local storage safe
/// to leave. The worker spins on the gate and then writes through pointers
/// into the block that declared it, so the gate is what lets it finish and
/// the drain is what waits until it has. A wake counter is not a substitute:
/// wakes also come from close and event activity, so only the pending count
/// answers whether a worker is done.
fn settleTasks(
    session: *Session,
    gate: *std.atomic.Value(bool),
    rounds: usize,
) !TaskSettle {
    gate.store(true, .release);
    var drained: usize = 0;
    for (0..rounds) |_| {
        drained += try session.drainTasks();
        const pending = try session.taskPending();
        if (pending.queued + pending.running + pending.ready +
            pending.ui_timers + pending.cancelled == 0)
        {
            return .{ .drained = drained, .settled = true };
        }
        const snapshot = try session.taskWakeSnapshot();
        _ = try session.waitForTaskWake(snapshot, 5 * std.time.ns_per_ms);
    }
    return .{ .drained = drained, .settled = false };
}

/// `settleTasks` on the error path, where there is no report left to write
/// into. The result is discarded explicitly so the `errdefer` that calls this
/// is unambiguously a void statement, not one whose value only happens to be
/// unreachable.
fn settleTasksOrDie(session: *Session, gate: *std.atomic.Value(bool), rounds: usize) void {
    _ = settleTasks(session, gate, rounds) catch
        @panic("W07 error path could not settle the queued work before its storage died");
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    // The SafeAllocator is this run's leak oracle. A leak in the cleanup
    // owner below is printed AND fails the run, so an unwind that forgot
    // something cannot pass silently.
    defer std.debug.assert(gpa_state.deinit() == 0);
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // The owner of everything this run allocates, and the single `errdefer`
    // that releases it. It is declared before the first allocation so every
    // exit below — a refused argument, a missing shader, a failed open, a
    // failed report write, and the successful shutdown at the end — leaves
    // through the same order.
    var run: Run = .{
        .gpa = gpa,
        // SAFETY: `opened` counts only complete slots, so none is read unwritten.
        .slots = undefined,
    };
    errdefer run.unwind();

    var hold_ms: u64 = 0;
    var minimized_hold_ms: u64 = 0;
    // The one-versus-two window option isolates window-count effects on the
    // same driver and desktop; keep both paths in the same binary.
    var window_count: usize = 2;
    var present_frames: u32 = 0;
    // Zero keeps the scale watch off, so the default run is unchanged and a
    // run that cannot observe a real scale transition is not asked to.
    var scale_watch_ms: u64 = 0;
    // The REAL pointer watch. Off by default and independent of the scale
    // watch: it counts what SDL's queue delivered during `--hold-ms` and
    // reports it, and it builds no pointer event of its own. See "real
    // pointer ingress" above.
    var pointer_watch = false;
    // The refusal this binary can be asked to make ON PURPOSE, so the unwind
    // can be exercised against windows that are real, mounted and live. Zero
    // keeps it off and the default run unchanged. It touches nothing outside
    // this process: no file, no socket, no permission, no second display.
    var fail_after_open: usize = 0;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--hold-ms")) {
            const value = args_it.next() orelse return error.MissingHoldMs;
            hold_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--minimized-hold-ms")) {
            const value = args_it.next() orelse return error.MissingMinimizedHoldMs;
            minimized_hold_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--windows")) {
            const value = args_it.next() orelse return error.MissingWindows;
            window_count = try std.fmt.parseInt(usize, value, 10);
            if (window_count == 0 or window_count > 2) return error.InvalidWindowCount;
        } else if (std.mem.eql(u8, arg, "--present-frames")) {
            const value = args_it.next() orelse return error.MissingPresentFrames;
            present_frames = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--scale-watch-ms")) {
            const value = args_it.next() orelse return error.MissingScaleWatchMs;
            scale_watch_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--pointer-watch")) {
            // A boolean, deliberately without a value: the watch lives exactly
            // as long as the windows this run already holds up do, and a
            // duration here would be a second clock nothing else in the run
            // obeys. It observes `--hold-ms` and `--scale-watch-ms` alike.
            pointer_watch = true;
        } else if (std.mem.eql(u8, arg, "--fail-after-open")) {
            const value = args_it.next() orelse return error.MissingFailAfterOpen;
            fail_after_open = try std.fmt.parseInt(usize, value, 10);
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    // The refusal can only fire once that many windows are open, so an ask
    // that cannot fire is an argument error rather than a silent pass.
    if (fail_after_open > window_count) return error.FailAfterOpenExceedsWindows;

    // The pointer watch has exactly one window to observe in, and this run
    // already owns exactly two windows of its own: the `--scale-watch-ms`
    // scale watch and the `--hold-ms` hold. Either one is a real window for an
    // operator to move a pointer across while both windows are up, and
    // with a scale watch the watch counts through BOTH phases of the
    // transition. Asked for with neither, the watch would arm, sit through
    // the rest of the scenario with both windows closing, and report a count
    // of nothing — which is an argument error here rather than a misleading
    // line in the transcript.
    if (pointer_watch and hold_ms == 0 and scale_watch_ms == 0) {
        return error.PointerWatchWithoutWindow;
    }

    var report: Reporter = .{ .io = io };
    try report.emit("W07 native host smoke\n", .{});
    try report.emit("windows_requested: {d} present_frames_limit: {d} scale_watch_ms: {d}" ++
        " pointer_watch={} hold_ms: {d}\n", .{
        window_count,
        present_frames,
        scale_watch_ms,
        pointer_watch,
        hold_ms,
    });

    // SPIR-V for the real pipeline: the quad pair and the sort compute for
    // `v7_render.Renderer`, plus the fullscreen Oklab-to-sRGB blit. The
    // build's `shaders/` directory is the same source the demo and the
    // inspector smoke read, so the modules are not forked per binary.
    var quad_vert = try Spv.load(gpa, io, "shaders/quad_vert.spv");
    defer quad_vert.deinit(gpa);
    var quad_frag = try Spv.load(gpa, io, "shaders/quad_frag.spv");
    defer quad_frag.deinit(gpa);
    var sort_comp = try Spv.load(gpa, io, "shaders/sort_comp.spv");
    defer sort_comp.deinit(gpa);
    var fullscreen_vert = try Spv.load(gpa, io, "shaders/fullscreen_vert.spv");
    defer fullscreen_vert.deinit(gpa);
    var blit_oklab = try Spv.load(gpa, io, "shaders/blit_oklab.spv");
    defer blit_oklab.deinit(gpa);

    // The Session and the one model both windows read, recorded in the owner
    // the moment each exists so the unwind can tell a resource this run
    // created from one it never got to.
    run.session = blk: {
        const fresh = try gpa.create(Session);
        errdefer gpa.destroy(fresh);
        fresh.* = try Session.init(gpa);
        break :blk fresh;
    };
    const session = run.session.?;

    var initial: Document = .{};
    run.model = try session.create(Document, &initial);
    const owner = run.model.?;

    // The host is created with no video_driver hint so SDL picks the driver
    // for this session; the smoke reports which one it actually selected.
    run.application = blk: {
        const fresh = try gpa.create(Application);
        errdefer gpa.destroy(fresh);
        fresh.* = try Application.init(gpa, session, .{
            .app_id = "dev.nogui.w07smoke",
            .restart = .never,
        });
        break :blk fresh;
    };
    const application = run.application.?;

    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    exts_storage = try gpa.dupe([*:0]const u8, sdl_exts);
    // The loader reads this copy through `getExts` while the device is being
    // created, and holds what it needs from it. The errdefer is scoped to the
    // block below on purpose: armed in `main`'s own scope it would outlive the
    // free at the end of it and free the empty slice that replaced it.
    var gpu: noapi.Gpu = blk: {
        errdefer gpa.free(exts_storage);
        break :blk try noapi.Gpu.init(.{
            // Three, not two: `v7_render.Renderer` rings its per-frame paint
            // buffers over three slots, one per in-flight frame, and a two-slot
            // device would let a later frame overwrite buffers an earlier one
            // can still be reading.
            .frames_in_flight = 3,
            .app_name = "w07-host-smoke",
            .validation = false,
            .loader = .{
                .get_instance_proc_addr = @ptrCast(get_proc_addr),
                .get_instance_extensions = &getExts,
            },
            .io = io,
        });
    };
    // From here the device is the owner's, and the owner releases it after
    // every surface, blit heap, App GPU mount and pipeline resource is gone,
    // and before `Application.deinit` quits SDL.
    run.gpu = &gpu;
    // That copy has done its job, so it goes here and `getExts` names the
    // empty slice for the rest of the run. The device itself is torn down by
    // the owner above: after every noapi Surface, blit heap and App GPU mount
    // is gone, and BEFORE `Application.deinit()` quits SDL — quitting SDL
    // unloads the Vulkan loader, and a live VkDevice would then dispatch
    // through an unmapped page.
    gpa.free(exts_storage);
    exts_storage = &.{};

    var endpoint: nogui.GpuEndpoint = .{ .gpu = &gpu };

    // The pipeline itself. Its teardown is EXPLICIT, right before
    // `gpu.deinit()`: every resource in it calls into the device, and the
    // device is gone by the time a function-scope `defer` would run.
    var paint = try Paint.init(
        gpa,
        &gpu,
        &quad_vert,
        &quad_frag,
        &sort_comp,
        &fullscreen_vert,
        &blit_oklab,
    );
    run.paint = &paint;

    // The endpoint borrows the window-owned GPU and the bindless GUI heap for
    // the graphical lifetime. The Apps detach inside `App.deinit`, which runs
    // while this heap is still alive.
    var gpu_texture_runtime = paint.textures.runtimeRegistry();
    endpoint.textures = &gpu_texture_runtime;

    // Text measurement for the canonical layout dispatcher comes from the
    // engine this run presents with, bound per App below as a value it
    // holds. There is no scope to leave: nothing in the layout path reads
    // ambient state, so nothing can outlive the engine it names.

    const specs = [_]struct {
        name: [:0]const u8,
        title: [:0]const u8,
        width: u32,
        height: u32,
        color: nogui.Color,
    }{
        .{
            .name = "left",
            .title = "w07-smoke-left",
            .width = 480,
            .height = 360,
            .color = .{ 0.10, 0.45, 0.75, 1.0 },
        },
        .{
            .name = "right",
            .title = "w07-smoke-right",
            .width = 520,
            .height = 380,
            .color = .{ 0.80, 0.35, 0.12, 1.0 },
        },
    };

    // Scratch for the report's optional values; the run formats into these
    // rather than allocating one line at a time.
    var bounds_buf: [64]u8 = undefined;
    var limit_buf: [64]u8 = undefined;
    var label_buf: [64]u8 = undefined;
    const driver_name = sdl3.video.getCurrentDriverName() orelse "<null>";
    try report.emit("video driver: {s}\n", .{driver_name});
    const capabilities = application.capabilities();
    try report.emit("global position capability: {}\n", .{capabilities.global_position});
    try report.emit("minimized observation capability: {}\n", .{capabilities.minimized});
    try report.emit("window hierarchy capability: {}\n", .{capabilities.hierarchy});
    // The desktop as this host read it at startup, and again from SDL, so a
    // scale or bounds change later in the run has something to be compared to.
    for (application.displayList()) |info| {
        try report.emit(
            "display {d}: primary={} full={d}x{d} work={d}x{d} scale={d:.3} position={s}\n",
            .{
                @backingInt(info.id),
                info.primary,
                info.full_bounds.size.width,
                info.full_bounds.size.height,
                info.work_bounds.size.width,
                info.work_bounds.size.height,
                info.content_scale,
                if (info.full_bounds.position) |point|
                    std.fmt.bufPrint(&bounds_buf, "{d},{d}", .{ point.x, point.y }) catch "<err>"
                else
                    "unobservable",
            },
        );
    }

    // One probe, on one window. A stable-key component is a per-window thing,
    // and both watches need a single committed line box to measure against —
    // the scale watch compares it before and after a transition, the pointer
    // watch hit-tests a REAL position against it — so the FIRST window carries
    // it and the peer is left exactly as it was. A run with neither watch
    // allocates none.
    //
    // EITHER watch mounts the SAME caller-owned probe: one allocation, one
    // owner, one release, and no second keyed component competing for the
    // same node identity.
    //
    // The Apps are destroyed by the owner, and an App's component registry
    // holds this pointer for as long as the keyed component is mounted, so
    // the owner releases it after the last App that could name it — not from
    // here, where a `defer` would end it before the first frame.
    if (scale_watch_ms != 0 or pointer_watch) {
        const probe = try gpa.create(Probe);
        probe.* = .{};
        run.probe = probe;
    }

    for (specs[0..window_count], 0..) |spec, index| {
        // The App belongs to this run only once it is fully built: an
        // allocation that succeeds and an `init` that fails leaves
        // uninitialised storage, which `Run` must not call `deinit` on. It is
        // recorded the moment it exists and stays recorded until the slot
        // below takes it over.
        const app = blk: {
            const fresh = try gpa.create(App);
            errdefer gpa.destroy(fresh);
            fresh.* = try App.init(gpa, session);
            break :blk fresh;
        };
        run.pending.app = app;
        // Every App measures text through the same engine this run presents
        // with, so the layout the candidate rectangle is read from and the
        // glyphs that were rasterized are one measurement, not two.
        app.measure = paint.text.measurer();
        // Nothing between this allocation and the record can fail, so the
        // Pane is the owner's from the moment it exists.
        const pane = try gpa.create(Pane);
        pane.* = .{ .name = spec.name, .background = spec.color };
        run.pending.pane = pane;
        if (index == 0) pane.probe = run.probe;
        try app.mountModelRoot(Document, Pane, owner, pane);
        try app.attachGpu(&endpoint);

        // The host BORROWS the App from the moment this returns and
        // dereferences it in its own close path, so this is the point where
        // the borrow starts. Recording it immediately is what makes the
        // cleanup owner close this window before the App dies, instead of
        // destroying the App while the host can still reach it.

        const handle = try application.openWindowWithApp(app, .{
            .title = spec.title,
            .width = spec.width,
            .height = spec.height,
            .resizable = true,
            .visible = true,
            .gpu_surface = true,
        });
        run.pending.handle = handle;
        const managed = try application.getWindow(handle);
        // noapi creates and owns the platform surface; this run never sees a
        // Vulkan instance or surface handle.
        // A platform call, so it can fail; the open is refused rather than
        // reported at a size nobody measured.
        const surface_extent = try deviceExtent(managed);
        // This window's blit heap and its platform surface are recorded
        // before the slot that owns them is written, so a failure at any
        // later point still finds something that knows how to release them.
        const window_paint = try WindowPaint.init(&gpu);
        run.pending.paint = window_paint;
        const surface = try noapi.Surface.initSdl(
            &gpu,
            @ptrCast(managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = surface_extent },
        );
        run.pending.surface = surface;
        // Everything this window owns now exists and the literal below cannot
        // fail, so `opened` only ever counts windows the owner can hand back.
        run.slots[index] = .{
            .title = spec.title,
            .name = spec.name,
            .handle = handle,
            .app = app,
            .pane = pane,
            .surface = surface,
            .background = spec.color,
            .paint = window_paint,
            .present_timing = false,
        };
        run.slots[index].present_timing = surface.supportsPresentTiming();
        run.pending = .{};
        run.opened += 1;
        try report.emit(
            "opened {s}: handle slot={d} session_window={d} title=\"{s}\"" ++
                " requested={d}x{d} observed_at_open={d}x{d} pixels_at_open={d}x{d}" ++
                " surface_extent={d}x{d} swapchain={d}x{d} present_timing={}\n",
            // The argument order follows the PLACEHOLDER order in the format
            // string above, which reports the pixel size before the surface
            // extent; the two were transposed, so the line reported the
            // surface size as if it were the pixel size.
            .{
                spec.name,
                handle.slot,
                handle.session_window,
                spec.title,
                spec.width,
                spec.height,
                managed.observed.size.width,
                managed.observed.size.height,
                managed.observed.pixels.width,
                managed.observed.pixels.height,
                surface_extent.width,
                surface_extent.height,
                surface.surfaceSize().width,
                surface.surfaceSize().height,
                run.slots[index].present_timing,
            },
        );
        try report.emit(
            "  requested state {s}: kind={s} decorated={} focusable={} resizable={}" ++
                " minimum={s} maximum={s} divergence={s} borders={s}\n",
            .{
                spec.name,
                @tagName(managed.requested.kind),
                managed.requested.decorated,
                managed.requested.focusable,
                managed.requested.resizable,
                sizeText(&bounds_buf, managed.requested.minimum_size),
                sizeText(&limit_buf, managed.requested.maximum_size),
                if (managed.divergence()) |kind| @tagName(kind) else "none",
                if (managed.observed.borders) |frame|
                    std.fmt.bufPrint(&label_buf, "{d},{d},{d},{d}", .{
                        frame.top,
                        frame.left,
                        frame.bottom,
                        frame.right,
                    }) catch "<err>"
                else
                    "unobservable",
            },
        );

        // The refusal this binary can be asked to make ON PURPOSE. It lands
        // with this window fully allocated, mounted and LIVE, and with every
        // window opened before it still open — exactly the state a real
        // failure inside this loop leaves behind, and the one the cleanup
        // owner above has to survive. Nothing outside this process is
        // touched: no file, no socket, no permission, no second display. The
        // run then leaves through that one owner, and the SafeAllocator at
        // the top of `main` is what says whether it released everything.
        if (run.opened == fail_after_open) {
            try report.emit(
                "injected refusal: {d} window(s) open and live, host_window_count={d}" ++
                    " (the cleanup owner unwinds from here)\n",
                .{ run.opened, application.window_count },
            );
            return error.InjectedConstructionRefusal;
        }
    }

    // The scene scratch is assigned in place right after this literal: it
    // borrows `paint.renderer`, and a struct-literal default would have to be
    // written before `paint` had its final address.
    var smoke: Smoke = .{
        .gpa = gpa,
        .io = io,
        .application = application,
        .windows = run.slots[0..],
        .run = &run,
        .endpoint = &endpoint,
        .paint = &paint,
        // SAFETY: the scratch is filled on the next line, once `paint` has its
        // final address: it borrows the renderer, and a literal default would
        // have to take that address before this struct exists.
        .scene = undefined,
        .present_limit = present_frames,
    };
    smoke.scene = frame_scene.SceneScratch.init(gpa, &paint.renderer);
    // The scratch borrows `paint.renderer`, so the owner releases it with the
    // pipeline it belongs to.
    run.scene = &smoke.scene;
    application.setHooks(.{
        .context = &smoke,
        .on_frame = Smoke.onFrame,
        .on_event = Smoke.onEvent,
        .on_close_request = Smoke.onCloseRequest,
        .on_before_close = Smoke.onBeforeClose,
        .on_closed = Smoke.onClosed,
        .on_last_window_closed = Smoke.onLastWindowClosed,
        .on_quit_request = Smoke.onQuitRequest,
    });

    try application.start();
    try report.emit("session task service started: {}\n", .{session.tasksStarted()});

    // ── 1. at least three committed frames in every live window ──
    try report.emit("external loop: Application.run is never called; " ++
        "this binary drives step/pollEvent/dispatch/nextWaitMilliseconds itself\n", .{});
    const frames_settled = try pumpUntil(
        &smoke,
        &report,
        null,
        sdl3.timer.getMillisecondsSinceInit() + 10_000,
        firstFramesDone,
    );
    try report.emit("{d} window(s) each with three committed frames: settled={} host_running={}\n", .{
        window_count,
        frames_settled,
        smoke.host_running,
    });
    for (smoke.live()) |*slot| {
        const managed = try application.getWindow(slot.handle);
        try report.emit(
            "frames {s}: committed={d} presented={d} frame_generation={d} tree={s} label=\"{s}\"\n",
            .{
                slot.name,
                slot.frames_committed,
                slot.frames_presented,
                slot.app.frame_generation,
                if (slot.app.tree_ptr == null) "<none>" else "<live>",
                slot.pane.label(),
            },
        );
        try report.emit(
            "  observed {s}: size={d}x{d} pixels={d}x{d} visible={} occluded={} minimized={s} focused={}\n",
            .{
                slot.name,
                managed.observed.size.width,
                managed.observed.size.height,
                managed.observed.pixels.width,
                managed.observed.pixels.height,
                managed.observed.visible,
                managed.observed.occluded,
                minimizedText(managed.observed.minimized),
                managed.observed.focused,
            },
        );
        try reportPresent(&smoke, &report, slot);
    }
    // With `--present-frames` the present path is now held still. Each window
    // takes exactly ONE commit-without-present frame: it is submitted, so the
    // GPU still clears the image, and it is the last frame the surface can
    // take, because an image submitted and never presented is never returned
    // to the presentation engine.
    if (present_frames != 0) {
        const held = try pumpUntil(
            &smoke,
            &report,
            null,
            sdl3.timer.getMillisecondsSinceInit() + 5_000,
            commitOnlyFrameTaken,
        );
        try report.emit("present limit {d}: commit-without-present frame taken={}\n", .{
            present_frames,
            held,
        });
        for (smoke.live()) |*slot| try reportPresent(&smoke, &report, slot);
    }

    // ── 2. one Session.update observed by every live window ──
    try session.update(Document, owner, {}, Bump.apply);
    var seen: ReadRevision = .{};
    try session.read(Document, owner, &seen, ReadRevision.read);
    try report.emit("after Session.update: model revision={d}\n", .{seen.revision});
    for (smoke.live()) |slot| {
        try report.emit("  session redraw pending {s}: {}\n", .{
            slot.name,
            try session.takeRedraw(slot.app.window),
        });
    }
    const revision_seen_at = smoke.windows[0].pane.observed;
    // One further frame per window is enough to observe the new revision.
    const revision_settled = try pumpUntil(
        &smoke,
        &report,
        null,
        sdl3.timer.getMillisecondsSinceInit() + 5_000,
        struct {
            fn everyWindowAtTwo(s: *Smoke) bool {
                for (s.live()) |slot| {
                    if (slot.pane.observed != 2) return false;
                }
                return s.live().len > 0;
            }
        }.everyWindowAtTwo,
    );
    try report.emit("shared model revision: session={d} settled={}\n", .{
        seen.revision,
        revision_settled,
    });
    for (smoke.live()) |slot| {
        try report.emit("  revision {s}: saw={d} (was {d} before the update)\n", .{
            slot.name,
            slot.pane.observed,
            revision_seen_at,
        });
    }

    // ── 3. resize the first window; every peer must not move ──
    {
        var peer_storage: []contract.Size = &.{};
        defer if (peer_storage.len != 0) gpa.free(peer_storage);
        var peer_before: []const contract.Size = &.{};
        if (window_count > 1) {
            peer_storage = try gpa.alloc(contract.Size, window_count - 1);
            // The snapshot is a const VIEW of the storage the defer releases;
            // the array itself is what is written through below.
            peer_before = peer_storage;
            for (smoke.live()[1..], peer_storage) |slot, *size| {
                size.* = (try application.getWindow(slot.handle)).observed.size;
            }
        }
        const target = try application.getWindow(smoke.windows[0].handle);
        try target.requestSize(.{ .width = 900, .height = 620 });
        try target.refresh();
        const settled = try pumpUntil(
            &smoke,
            &report,
            null,
            sdl3.timer.getMillisecondsSinceInit() + 3_000,
            resized,
        );
        try target.refresh();
        try report.emit(
            "resize {s}: requested=900x620 observed={d}x{d} pixels={d}x{d}" ++
                " settled_within_timeout={} divergence={s}\n",
            .{
                smoke.windows[0].name,
                target.observed.size.width,
                target.observed.size.height,
                target.observed.pixels.width,
                target.observed.pixels.height,
                settled,
                if (target.divergence()) |kind| @tagName(kind) else "none",
            },
        );
        var peers_moved = false;
        for (smoke.live()[1..], peer_before) |slot, before| {
            const after = (try application.getWindow(slot.handle)).observed.size;
            if (after.width != before.width or after.height != before.height) peers_moved = true;
            try report.emit(
                "  peer {s}: before={d}x{d} after={d}x{d} moved={}\n",
                .{ slot.name, before.width, before.height, after.width, after.height, peers_moved },
            );
        }
        // `peer_storage` is released by the defer above; freeing the view here
        // as well would release the same allocation twice.
        try reportPresent(&smoke, &report, &smoke.windows[0]);
    }

    // ── 3b. an OBSERVED display-scale transition, or the run fails ──
    // The earlier version of this section queried the ratio once and then
    // pushed a `display_content_scale_changed` of its own through the host,
    // which reported the delta the host computed against the reading it
    // held. That is the dispatch code exercised on an event nothing
    // produced: it cannot fail, so a run of it proves nothing about a scale
    // change. The section below waits for the platform instead, and FAILS
    // when the platform says nothing.
    // The REAL pointer watch, when this run asked for one. Section 3b arms it
    // on the committed scale baseline and section 5 arms it in the hold; only
    // the first of those two can happen in a given run, and the drain runs
    // wherever the watch is set. One value for both sections, so a run can
    // never hold two watches or report the second one's ingress.
    var pointer_view: ?IngressWatch = null;

    if (scale_watch_ms != 0) {
        const watched = &smoke.windows[0];
        // Wait for the probe to reach a committed frame before arming: a
        // baseline taken over a tree that never held the probe would compare
        // a rectangle against nothing. The pointer watch arms on the same
        // predicate, so both watches agree on what "the probe exists" means.
        const probe_ready = try pumpUntil(
            &smoke,
            &report,
            null,
            sdl3.timer.getMillisecondsSinceInit() + 5_000,
            probeCommitted,
        );
        if (!probe_ready) return error.ScaleWatchProbeNeverCommitted;
        const before = try readCandidate(&smoke, watched, try publishCandidate(&smoke, watched));
        try reportPresent(&smoke, &report, watched);
        const baseline = try readScale(&smoke, watched, before.anchor);
        try emitScale(&report, "scale baseline", baseline);
        try emitCandidate(&report, "candidate baseline", before);
        // The REAL pointer watch attaches HERE, on the committed baseline and
        // BEFORE the one deadline below, so a pointer an operator moves
        // while the output is still at its baseline scale is already counted
        // when the scale pump takes over. Section 5 arms it instead when this
        // run asked for no scale watch, and does nothing at all when a scale
        // watch already owns it.
        if (pointer_watch) {
            const managed = try application.getWindow(watched.handle);
            pointer_view = .{
                .slot = watched,
                .managed = managed,
                .native_id = managed.native.id,
            };
            smoke.pointer_phase = "before-scale";
            smoke.watch_arm_raw_events = smoke.raw_events;
            try emitPointerArmed(&smoke, &report, pointer_view.?);
        }
        // One machine-readable line naming the window, the display and the
        // exact baseline an operator has to change now, and one deadline:
        // the line the operator reads and the pump that obeys it have to be
        // the same number. A driver that cannot produce this transition fails
        // the run rather than reporting a quiet pass.
        const deadline = sdl3.timer.getMillisecondsSinceInit() + scale_watch_ms;
        try report.emit(
            "READY scale_watch window={s} display={d} watch_ms={d}" ++
                " baseline_display_scale={d:.3} baseline_pixel_ratio={d:.3}x{d:.3}" ++
                " baseline_logical={d}x{d} baseline_pixels={d}x{d}" ++
                " baseline_image={d}x{d} deadline_ms={d}\n",
            .{
                watched.name,
                @backingInt(baseline.display),
                scale_watch_ms,
                baseline.display_scale,
                baseline.ratio[0],
                baseline.ratio[1],
                baseline.logical.width,
                baseline.logical.height,
                baseline.pixels.width,
                baseline.pixels.height,
                baseline.image.width,
                baseline.image.height,
                deadline,
            },
        );
        const moved = try pumpScaleWatch(&smoke, &report, deadline, baseline, pointer_view);
        // Frames after the change, so the "after" rectangle and the pixels it
        // describes come from the new scale rather than the frame the event
        // interrupted. The baseline count travels through `Smoke` because a
        // predicate is a bare function pointer and cannot close over a value.
        smoke.watch_baseline_committed = baseline.committed;
        _ = try pumpUntil(
            &smoke,
            &report,
            // The watch IS set here: this pump runs between the scale pump and
            // the hold, and a motion that lands in it belongs to the phase the
            // transition left the watch in. `step` polling first would take it
            // undifferentiated and leave it to the hook alone.
            pointer_view,
            sdl3.timer.getMillisecondsSinceInit() + 3_000,
            struct {
                fn afterTransition(s: *Smoke) bool {
                    const slot = &s.windows[0];
                    return slot.candidate.present and
                        slot.frames_committed > s.watch_baseline_committed + 1;
                }
            }.afterTransition,
        );
        const after = try readCandidate(&smoke, watched, try publishCandidate(&smoke, watched));
        const settled = try readScale(&smoke, watched, after.anchor);
        try emitScale(&report, "scale settled", settled);
        try emitCandidate(&report, "candidate settled", after);
        try reportPresent(&smoke, &report, watched);
        // The observed transition is the phase boundary for the REAL pointer
        // watch, and the only place in this file where the phase changes. The
        // line carries the freshly committed rectangle and the live window and
        // output extents an operator needs in order to aim at the NEW
        // scale, and the drain keeps running for the rest of the run, so the
        // second phase is counted against this boundary rather than against a
        // second clock. The phase argument is read before the call sets it.
        if (pointer_view) |active| {
            try enterPointerPhase(
                &smoke,
                &report,
                active,
                smoke.pointer_phase,
                "after-scale",
                moved,
            );
        }
        const real_events = smoke.display_scale_events + smoke.window_scale_events +
            smoke.window_pixel_size_events;
        const changed = scaleMoved(baseline, settled);
        try report.emit(
            "RESULT scale_watch requested={} observed_change={} within_deadline={}" ++
                " real_scale_events={d} (display={d} window={d} window_pixels={d})" ++
                " host_routed_scale_events={d} (display={d} window={d})" ++
                " host_routed_window_state_events={d}" ++
                " display_geometry_events={d} raw_events_in_watch={d} host_running={}" ++
                " candidate_generation={d} app_generation={d}" ++
                " candidate_generation_matches={}\n",
            .{
                true,
                changed,
                moved,
                real_events,
                smoke.display_scale_events,
                smoke.window_scale_events,
                smoke.window_pixel_size_events,
                // Both routes, because both are the host routing a real
                // measured scale change. Counting only the display route
                // reported zero for a transition this process observed
                // end to end, and the number said so about the tag rather
                // than about the routing.
                smoke.routed_display_scale_events + smoke.routed_window_scale_events,
                smoke.routed_display_scale_events,
                smoke.routed_window_scale_events,
                smoke.routed_window_state_events,
                smoke.display_geometry_events,
                // The events that landed inside the watch, not the whole run:
                // ONE drain now runs in front of every pump, so the raw
                // counter is run-wide and the watch figure is its delta.
                smoke.raw_events - smoke.watch_arm_raw_events,
                smoke.host_running,
                // The CURRENT candidate against the CURRENT App generation.
                // The baseline candidate was read before the watch armed, so
                // comparing it to a generation the transition has since
                // advanced past could only ever report a mismatch.
                after.generation,
                watched.app.frame_generation,
                after.generation == watched.app.frame_generation,
            },
        );
        // The pointer probe runs on BOTH sides of the same observed
        // transition through the same production path, so two translations
        // can be compared against two committed rectangles.
        try routeSyntheticPointer(&smoke, watched, before.anchor);
        try report.emit(
            "pointer baseline: source=synthetic(built-by-this-binary)" ++
                " requested=({d:.2},{d:.2}) app_logical=({d:.2},{d:.2})" ++
                " inside_committed_probe={} synthetic_events={d}\n",
            .{
                before.anchor.x,
                before.anchor.y,
                smoke.pointer_logical[0],
                smoke.pointer_logical[1],
                smoke.pointer_hits_probe,
                smoke.synthetic_pointer_events,
            },
        );
        try routeSyntheticPointer(&smoke, watched, after.anchor);
        try report.emit(
            "pointer settled: source=synthetic(built-by-this-binary)" ++
                " requested=({d:.2},{d:.2}) app_logical=({d:.2},{d:.2})" ++
                " inside_committed_probe={} synthetic_events={d}\n",
            .{
                after.anchor.x,
                after.anchor.y,
                smoke.pointer_logical[0],
                smoke.pointer_logical[1],
                smoke.pointer_hits_probe,
                smoke.synthetic_pointer_events,
            },
        );
        // The geometry consistency claim, in full: the logical rectangle is
        // the same committed content in both spaces, the device rectangle is
        // that same rectangle at the new scale, and SDL's area is in window
        // pixels, so it does not move. Printing all three is the point.
        try report.emit(
            "geometry consistency: logical_same={} device_ratio={d:.3}" ++
                " native_in_window_px_same={} candidate_frame_generations={d}->{d}" ++
                " text_input_active={} (no input method was started and no" ++
                " candidate window is claimed)\n",
            .{
                before.area.x == after.area.x and before.area.y == after.area.y and
                    before.area.w == after.area.w and before.area.h == after.area.h,
                if (before.device.w != 0) after.device.w / before.device.w else 0,
                before.native.x == after.native.x and before.native.y == after.native.y and
                    before.native.w == after.native.w and before.native.h == after.native.h,
                before.generation,
                after.generation,
                after.text_input_active,
            },
        );
        // A watch that was asked for and saw no real event proves nothing,
        // and a watch that saw events but no change proves the change never
        // reached the readings. Both are failures, not notes.
        if (!changed) return error.ScaleWatchNoObservedChange;
        if (real_events == 0) return error.ScaleWatchNoRealEvent;
        if (!before.present or !after.present) return error.ScaleWatchNoCommittedCandidate;
        if (!smoke.pointer_hits_probe) return error.ScaleWatchPointerMissedProbe;
        // A readback of an area the platform refused describes whatever was
        // there before this run touched it, so it is not evidence of this
        // run's geometry and the two rectangles must not be compared as if it
        // were.
        if (!before.published or !after.published) {
            return error.ScaleWatchCandidateAreaRefused;
        }
    } else {
        try report.emit("scale watch: not requested (--scale-watch-ms 0); " ++
            "no scale transition was observed and none is claimed\n", .{});
    }

    // ── 4. hold every window up for an external compositor capture ──
    // The pointer watch arms HERE when no scale watch already owns it: both
    // windows are up, the production loop is pumping, and an operator can
    // move a real pointer across them for the whole hold. A run with a scale
    // watch attached it in section 3b instead, and this section then only
    // carries that same watch into the hold, where its drain keeps counting
    // the phase the transition left it in.
    if (pointer_watch and pointer_view == null) {
        const watched = &smoke.windows[0];
        // The committed probe is what `inside_committed_probe` and
        // `probe_rect` are measured against, so a run that armed the watch and
        // never published one says so here instead of reporting
        // `probe_rect=none` for a whole hold.
        const probe_ready = try pumpUntil(
            &smoke,
            &report,
            null,
            sdl3.timer.getMillisecondsSinceInit() + 5_000,
            probeCommitted,
        );
        if (!probe_ready) return error.PointerWatchProbeNeverCommitted;
        const managed = try application.getWindow(watched.handle);
        pointer_view = .{
            .slot = watched,
            .managed = managed,
            .native_id = managed.native.id,
        };
        // The arming line, before the hold a driver is waiting for: it names
        // the window the ingress lines will answer for, the phase the samples
        // will be stamped with, and the committed rectangle they are
        // hit-tested against. `emitPointerArmed` owns the spelling, so the
        // hold arming and the scale-watch arming cannot drift apart.
        smoke.pointer_phase = "hold";
        smoke.watch_arm_raw_events = smoke.raw_events;
        try emitPointerArmed(&smoke, &report, pointer_view.?);
    }
    if (hold_ms > 0) {
        try holdForCapture(&smoke, &report, hold_ms, "both-up", pointer_view);
    }
    // No summary here on purpose. The drain runs inside the hold above and in
    // every pump since the watch armed, so the numbers are already final by the
    // time the hold ends, and the closing line belongs with the other shutdown
    // reporting where a reader looks for the run's totals.

    // ── 5. minimize then restore window "left" ──
    // Do this after pointer observation: Wayland may hide the surface without
    // an observable minimized state or a usable client restore operation.
    {
        const left = try application.getWindow(smoke.windows[0].handle);
        const can_observe_minimized = application.capabilities().minimized;
        // Where the platform cannot report minimization, the request is the only
        // confirmed part of the round trip; the run must say so, not assert a
        // value it never observed.
        const unconfirmed: []const u8 = if (can_observe_minimized)
            ""
        else
            " (unconfirmed: this platform cannot observe minimization)";
        try left.requestMinimize();
        try left.refresh();
        const did_minimize = try pumpUntil(
            &smoke,
            &report,
            // No watch: this is the minimize round trip, and a minimized
            // window has no client pointer to receive ingress. The drain still
            // runs; it just attributes nothing.
            null,
            sdl3.timer.getMillisecondsSinceInit() + 3_000,
            minimized,
        );
        try left.refresh();
        try report.emit(
            "minimize left: requested.minimized={} observed.minimized={s}" ++
                " observed.visible={} observed.size={d}x{d} observed_within_timeout={}{s}\n",
            .{
                left.requested.minimized,
                minimizedText(left.observed.minimized),
                left.observed.visible,
                left.observed.size.width,
                left.observed.size.height,
                did_minimize,
                unconfirmed,
            },
        );
        // No pointer watch here on purpose: a minimized window is not a place
        // a client pointer can arrive, so ingress counted in this window would
        // be a claim about nothing.
        if (minimized_hold_ms > 0) {
            try holdForCapture(&smoke, &report, minimized_hold_ms, "minimized", null);
        }
        try left.requestRestore();
        try left.refresh();
        const did_restore = try pumpUntil(
            &smoke,
            &report,
            null,
            sdl3.timer.getMillisecondsSinceInit() + 3_000,
            restored,
        );
        try left.refresh();
        try report.emit(
            "restore left: requested.minimized={} observed.minimized={s}" ++
                " observed.visible={} observed.size={d}x{d} observed_within_timeout={}{s}\n",
            .{
                left.requested.minimized,
                minimizedText(left.observed.minimized),
                left.observed.visible,
                left.observed.size.width,
                left.observed.size.height,
                did_restore,

                unconfirmed,
            },
        );
    }

    // ── 6. a refused open leaves the live windows alone ──
    {
        const before = application.window_count;
        const survivor = try application.getWindow(smoke.windows[0].handle);
        // Four refusals with four different reasons. Each is checked against
        // the live host, not against a mock: the point is that the survivor is
        // still the one window, still registered, and still drives frames.
        // An explicit array TYPE: a bare `.{}` literal is an anonymous struct,
        // and iterating one of those is not a thing a `for` can do.
        const Refusal = struct {
            options: contract.WindowOptions,
            want: anyerror,
        };
        const refusals = [_]Refusal{
            .{
                .options = contract.WindowOptions{
                    .title = "orphan menu",
                    .width = 120,
                    .height = 80,
                    .kind = .menu,
                },
                .want = error.MissingParent,
            },
            .{
                .options = contract.WindowOptions{
                    .title = "zero size",
                    .width = 0,
                    .height = 80,
                },
                .want = error.InvalidWindowSize,
            },
            .{
                .options = contract.WindowOptions{
                    .title = "zero maximum",
                    .width = 200,
                    .height = 140,
                    .maximum_size = .{ .width = 0, .height = 0 },
                },
                .want = error.InvalidMaximumSize,
            },
            .{
                .options = contract.WindowOptions{
                    .title = "unsupported placement",
                    .width = 200,
                    .height = 140,
                    .position = .{ .x = 40, .y = 40 },
                },
                .want = error.UnsupportedGlobalPosition,
            },
        };
        for (refusals) |attempt| {
            if (attempt.want == error.UnsupportedGlobalPosition and
                capabilities.global_position) continue;
            const refused = application.openWindow(attempt.options);
            try report.emit(
                "refused open \"{s}\": err={s} wanted={s} matched={} window_count={d} (was {d})\n",
                .{
                    attempt.options.title,
                    if (refused) |handle| blk: {
                        // Every case here should have been refused, so an
                        // open is the anomaly: the window goes back down
                        // before the line is written, and what the host did
                        // with it is the label. A window left live is the one
                        // thing the count on this line cannot explain.
                        const closed = application.closeWindow(handle);
                        break :blk if (closed) |_| "<opened, then closed" else |_| "<opened, still live>";
                    } else |err| @errorName(err),
                    @errorName(attempt.want),
                    if (refused) |_| false else |err| err == attempt.want,
                    application.window_count,
                    before,
                },
            );
            if (refused) |_| {
                return error.ExpectedWindowRefusal;
            } else |err| {
                if (err != attempt.want) return err;
            }
            if (application.window_count != before) return error.RefusalLeakedWindow;
        }
        const still_there = application.getWindow(smoke.windows[0].handle) catch null;
        try report.emit(
            "after refusals: window_count={d} survivor_live={} session.hasWindow={} frame_generation={d}\n",
            .{
                application.window_count,
                still_there != null,
                session.hasWindow(smoke.windows[0].app.window),
                survivor.app.frame_generation,
            },
        );
    }

    // ── 7. close the first window with a work item queued for it ──
    {
        const leaving = &smoke.windows[0];
        const handle = leaving.handle;
        const session_window = leaving.app.window;
        var release_gate: std.atomic.Value(bool) = .init(false);
        // The worker spins on this gate and then writes through pointers into
        // THIS block, so the storage outlives its user only if the gate opens
        // and the service reaches quiescence before the block returns. The
        // path below does that and reports it; this one has no report left to
        // print into, so a service that will not settle is a panic naming it
        // and not a warning.
        errdefer settleTasksOrDie(session, &release_gate, 400);
        var leaving_ran: std.atomic.Value(bool) = .init(false);
        var leaving_delivered: std.atomic.Value(u32) = .init(0);
        var leaving_work: QueuedWork = .{
            .release_gate = &release_gate,
            .ran = &leaving_ran,
            .delivered = &leaving_delivered,
        };
        var peer_ran: std.atomic.Value(bool) = .init(false);
        var peer_delivered: std.atomic.Value(u32) = .init(0);
        var peer_work: QueuedWork = .{ .release_gate = &release_gate, .ran = &peer_ran, .delivered = &peer_delivered };
        _ = try session.spawnWorker(
            QueuedWork,
            Document,
            QueuedWork.run,
            QueuedWork.applied,
            owner.weak(),
            &leaving_work,
            .{ .window = session_window },
        );
        if (smoke.live().len > 1) {
            _ = try session.spawnWorker(
                QueuedWork,
                Document,
                QueuedWork.run,
                QueuedWork.applied,
                owner.weak(),
                &peer_work,
                .{ .window = smoke.windows[1].app.window },
            );
        }
        // The present accounting is read while the surface still exists: the
        // close releases it inside `on_before_close`, so a report written
        // after `closeWindow` returned would describe a surface already gone.
        try reportPresent(&smoke, &report, leaving);
        // A veto must not consume the queued work or half-close the window.
        // It is scoped to the attempt: it is scenario state, and a cleanup
        // path that found it still raised could not close this window at all.
        const vetoed = blk: {
            smoke.close_veto = true;
            defer smoke.close_veto = false;
            break :blk try application.closeWindow(handle);
        };
        _ = try application.step();
        try report.emit(
            "close {s} (vetoed): closeWindow={} getWindow_ok={} session.hasWindow={} hook_calls={d}\n",
            .{
                leaving.name,
                vetoed,
                (application.getWindow(handle) catch null) != null,
                session.hasWindow(session_window),
                smoke.close_hook_calls,
            },
        );
        const closed = try application.closeWindow(handle);
        // Drained only after retirement, and only until nothing is left:
        // wakes can also come from close and event activity, so a wake counter
        // would not prove either worker finished. Both tasks must leave the
        // service and only the surviving window may receive a delivery.
        const settle = try settleTasks(session, &release_gate, 400);
        const stale = application.getWindow(handle);
        try report.emit(
            "close {s} (released): closeWindow={} getWindow_err={s} session.hasWindow={}" ++
                " on_closed_calls={d} tasks_settled={} drained={d}\n",
            .{
                leaving.name,
                closed,
                if (stale) |_| "<none>" else |err| @errorName(err),
                session.hasWindow(session_window),
                smoke.closed_hook_calls,
                settle.settled,
                settle.drained,
            },
        );
        try report.emit(
            "  queued work for the closed window: ran={} delivered={d}" ++
                " (a delivery aimed at a retired window must not land)\n",
            .{ leaving_ran.load(.acquire), leaving_delivered.load(.acquire) },
        );
        if (smoke.live().len > 1) {
            try report.emit(
                "  queued work for the surviving window: ran={} delivered={d}\n",
                .{ peer_ran.load(.acquire), peer_delivered.load(.acquire) },
            );
        }
        if (!closed or !settle.settled or leaving_delivered.load(.acquire) != 0 or
            (smoke.live().len > 1 and peer_delivered.load(.acquire) != 1))
        {
            return error.WindowScopedTaskDeliveryFailed;
        }
        try report.emit(
            "last-window-close hook fired {d} time(s); Application.isRunning={} (quit not requested)\n",
            .{ smoke.last_window_closed_calls, application.isRunning() },
        );
        // A borrowed App is retired by the close, not destroyed: the caller
        // still owns it. Its noapi surface is already gone, released by
        // `on_before_close` while the platform window was still alive.
        run.releaseSlot(leaving);
    }

    // Reuse the host's freed native-window slot while the peer is live. This
    // replacement has no GPU surface; it checks the generational host handle
    // and Session registration, not a second swapchain lifetime. A queued
    // completion for the retired window was already refused above.
    {
        const old = smoke.windows[0].handle;
        const replacement = try application.openWindow(.{
            .title = "w07-smoke-reused-slot",
            .width = 240,
            .height = 160,
            .visible = false,
        });
        if (replacement.slot != old.slot or replacement.generation == old.generation or
            replacement.session_window == old.session_window or
            !session.hasWindow(replacement.session_window))
        {
            return error.ReusedWindowSlotIdentity;
        }
        if (application.getWindow(old)) |_| {
            return error.StaleWindowHandleAccepted;
        } else |err| if (err != error.StaleWindow) return err;
        if (!try application.closeWindow(replacement)) return error.ReplacementCloseRejected;
        if (session.hasWindow(replacement.session_window)) return error.ReplacementWindowStillLive;
        try report.emit(
            "reused native slot={d} stale generation={d} replacement generation={d} " ++
                "old handle rejected=true replacement retired=true\n",
            .{
                old.slot,
                old.generation,
                replacement.generation,
            },
        );
    }

    // ── 8. close the rest: last-window-close, kept distinct from quit ──
    // The LIVE slice, not an index derived from the count this run STARTED
    // with: the closed window has already been dropped from it, so starting
    // at 1 would skip the survivor entirely and no last-window close would
    // ever happen.
    for (smoke.live()) |*slot| {
        // A slot the host already released is not closed again: the App behind
        // it is gone, and closing it a second time is what the veto/refusal
        // steps above deliberately avoid.
        if (slot.closed) continue;
        const handle = slot.handle;
        const session_window = slot.app.window;
        // Read before the close: the close releases the noapi surface.
        try reportPresent(&smoke, &report, slot);
        const closed = try application.closeWindow(handle);
        _ = try application.step();
        const stale = application.getWindow(handle);
        try report.emit(
            "close {s}: closeWindow={} getWindow_err={s} session.hasWindow={}\n",
            .{
                slot.name,
                closed,
                if (stale) |_| "<none>" else |err| @errorName(err),
                session.hasWindow(session_window),
            },
        );
        run.releaseSlot(slot);
    }
    try report.emit(
        "last-window-close: calls={d} decision={s} Application.isRunning={} quit_hook_calls={d}\n",
        .{
            smoke.last_window_closed_calls,
            @tagName(smoke.last_window_decision orelse .keep_running),
            application.isRunning(),
            smoke.quit_hook_calls,
        },
    );

    // ── 9. application quit is its own decision ──
    try application.requestQuit();
    try report.emit(
        "requestQuit: decision={s} Application.isRunning={} pending={s}\n",
        .{
            @tagName(smoke.quit_decision orelse .approve),
            application.isRunning(),
            if (application.pendingQuit()) |pending|
                std.fmt.bufPrint(&bounds_buf, "token={d} remaining_ms={d}", .{
                    pending.token.sequence,
                    pending.remaining_ms,
                }) catch "<err>"
            else
                "none",
        },
    );
    try report.emit("external loop totals: steps={d} owned_loop_calls={d} host_running={}\n", .{
        smoke.steps,
        smoke.owned_loop_calls,
        application.isRunning(),
    });

    // One `on_before_close` per destroyed window, with the slot's release
    // asserted before its App is destroyed. A lower count means teardown did
    // not run for every platform window.
    try report.emit("surface teardown: released_before_window={d} slots={d}\n", .{
        smoke.before_close_calls,
        window_count,
    });

    // ── 10. shutdown: no owned model, task, GPU or window may survive ──
    // The order is the host's lifetime contract and it now lives in ONE
    // place. `Run.unwind` is what the `errdefer` at the top of `main` calls
    // for every failure above as well, so this run's shutdown and an aborted
    // one release the same things in the same order: the windows first, while
    // the borrowed Apps, the device, the surfaces and the endpoint are whole;
    // then each App, which unmounts before the Pane and the probe go; then the
    // pipeline through a live device; then the device, before `Application`
    // quits SDL and unloads the loader it dispatches through; then the host;
    // and the model and its Session last.
    try report.emit("pre-shutdown: window_count={d} host_running={}\n", .{
        application.window_count,
        application.isRunning(),
    });
    // The closing pointer line, while this run's own slots still exist. It is
    // written from values only — counters the drain took and the handle fields
    // copied into the watch — so it reads nothing that the unwind below is
    // about to destroy, and it can be printed before that unwind rather than
    // after it. A run that armed no pointer watch prints nothing at all.
    if (pointer_view) |active| try emitIngressSummary(&smoke, &report, active);
    // The scenario already closed and released both windows above, so this
    // pass finds every per-window flag already set and releases the rest.
    run.unwind();
    // The per-window Oklab targets and blit heaps went with their surfaces,
    // inside the close; the shared bindless heap, the renderer and the text
    // engine went with the pipeline, through a device that was still alive.
    try report.emit("render pipeline: per-window Oklab targets and blit heaps were" ++
        " released with their surfaces; the shared bindless heap, renderer and" ++
        " text engine are released here, before the device\n", .{});
    try report.emit("noapi Gpu.deinit: ok\n", .{});
    // A Session that still owns live models or unfinished work is a FAILED
    // run, not a warning line: its storage was deliberately left alone rather
    // than destroyed over what it owns, and the reason is named.
    if (run.session_error) |err| {
        try report.emit("Session.deinit: {s}\n", .{@errorName(err)});
        try report.emit("W07 native host smoke FAILED: the Session still owns live work\n", .{});
        return err;
    }
    try report.emit("Session.deinit: ok\n", .{});
    try report.emit("W07 native host smoke done\n", .{});
}
