//! W13 paint specimen — one real noapi frame whose pixels are probed in Oklab,
//! plus a PPM the parent can read, through either of two surfaces.
//!
//! The W13 CPU tests lower paint to scene records and compare no pixels. This
//! runs the whole remaining chain — `PaintWriter` → `drawcmd` → `PaintList` →
//! `lowerPaint` → `recordFrameScene` → the quad and sort shaders → an
//! rgba32_float Oklab readback — and holds the result to hard Oklab values and
//! to spatial differences measured on the image itself: the first and last
//! inked column of a corner, an inked hole, a dash gap, a vacated transform
//! box, a clip boundary, a shadow penumbra.
//!
//! TWO SURFACES, ONE SPECIMEN. `Specimen` below is the authored paint every
//! claim in `check` reads; the two modes publish that same element with the
//! same shaders and differ only in where the Oklab target lives:
//!
//!   * the default — `v7_frame.Offscreen`. No window, no SDL, no raw Vulkan
//!     handle, no surface at all.
//!   * `--native` — a real `nogui_host.Application` window and its swapchain
//!     image through `v7_frame.NativeFrame`, which adds the Oklab→sRGB blit.
//!     The readback still leaves the Oklab target those same passes wrote, so
//!     every probe below means the same thing on either surface.
//!
//! `--native` additionally makes the claim the default cannot: it publishes a
//! SECOND frame with one authored panel re-authored, and proves the first
//! frame's paint records — and the path-command, shadow and dash slices those
//! records borrow out of its frame arena — are still readable, and still carry
//! the first frame's authored values, once the second frame has committed.
//! The current records carry the authored change instead. See
//! `check.lifetime`.
//!
//! `--exercise-capacity` publishes ONE more frame first, on whichever surface
//! the run is already using: four ordinary public canvas siblings, each under
//! the 256 records ONE element may hold, whose 800 round-cornered rects are
//! more rich primitives than the frame's own 768-slot material partition. That
//! frame is built and lowered for real and refused for real —
//! `error.MaterialCapacity` out of the lowering, then the recording cancelled
//! rather than submitted — and the ordinary specimen is then published through
//! the SAME target and the SAME material-ring slot, with every pixel claim
//! below made unchanged. See `exerciseMaterialCapacity`.
//!
//! The canvas element's box (620x540) is deliberately SMALLER than the render
//! target (640x560), so the element's own clip rect is observable in target
//! pixels the clip still owns. Shapes are laid out on a 3x4 panel grid in
//! canvas-local units, with a few more panels in the free bands beside it;
//! every probe is offset by the element's real prepaint content origin.
//!
//! Run it: `zig build w13-canvas-smoke -- [ppm-path]` (add
//! `--exercise-capacity` to run the capacity frame first), or
//! `zig build w13-canvas-smoke -- --native [ppm-path] [--hold-ms N]`.
const std = @import("std");
const Io = std.Io;

const noapi = @import("noapi");
const nogui = @import("nogui");
const render = @import("v7_render");
const frame = @import("v7_frame");

/// Reachable only from `--native`. The default path never initializes SDL and
/// never names either of these, so a windowless run still touches no display
/// server and asks for no platform surface.
const sdl3 = @import("sdl3");
const host = @import("nogui_host");

const paint = nogui.paint;
const path = nogui.path;
const Rect = paint.Rect;

/// Logical window units. The device extent is identical, so one logical unit is
/// exactly one device pixel and `fwidth` is 1.0 everywhere in the shader.
const window_w: f32 = 640;
const window_h: f32 = 560;
const device_extent: noapi.Extent2D = .{ .width = 640, .height = 560 };

/// The canvas element's own box. It clips its paint records, and the 20-unit
/// margin against the target is what makes the clip probes readable.
const canvas_w: f32 = 620;
const canvas_h: f32 = 540;

const default_ppm = "zig-out/w13-canvas-smoke.ppm";

// -- Presented surface (--native only) --
// Everything in this section is unreachable from the default path, which
// opens no window, asks for no surface and initializes no SDL subsystem.

/// SDL metadata. Process-wide, and set before the video subsystem comes up.
const app_id: [:0]const u8 = "dev.nogui.w13canvassmoke";
const window_title = "w13-canvas-smoke";

/// The two blit modules `NativeFrame` records the Oklab target with. The
/// windowless path presents nothing and never opens either one.
const default_fullscreen_shader = "shaders/fullscreen_vert.spv";
const default_oklab_shader = "shaders/blit_oklab.spv";

/// Compositor round trips and swapchain acquires. Both are bounds, never
/// timeouts a run may quietly grow past.
const window_polls: u32 = 32;
const acquire_polls: u32 = 8;

/// The longest a `--native` run will hold its window up. The hold exists so a
/// screenshot taken from another process still finds the specimen presented;
/// the bound is what keeps that a run rather than a wait.
const max_hold_ms: u32 = 10_000;
/// One host pump's slice of the hold.
const hold_slice_ms: u32 = 20;
/// The clock step between the presented run's two frames — the spacing the
/// demo window loop itself passes to `App.animationDemand`.
const frame_step_ms: u64 = 16;

// ── authored colours (sRGB: the authored side of the authored/scene split) ──

const white: paint.Color = .{ .srgb = .{ .r = 1, .g = 1, .b = 1 } };
const red: paint.Color = .{ .srgb = .{ .r = 1, .g = 0, .b = 0 } };
const green: paint.Color = .{ .srgb = .{ .r = 0, .g = 1, .b = 0 } };
const blue: paint.Color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } };
/// The same gray expressed in sRGB, for a fill that has to sit under a shadow.
const gray_90: paint.Color = .{ .srgb = .{ .r = 0.9, .g = 0.9, .b = 0.9 } };
/// The border panel's field: dark enough that every border colour reads.
const gray_15: paint.Color = .{ .srgb = .{ .r = 0.15, .g = 0.15, .b = 0.15 } };
/// Authored directly in scene space. It reproduces the Oklab clear EXACTLY, so
/// the whole frame's background is one known value instead of an assumption.
const clear_fill: paint.Fill = .{ .solid = .{ .oklab = .{
    .l = frame.scene.oklab_clear[0],
    .a = frame.scene.oklab_clear[1],
    .b = frame.scene.oklab_clear[2],
    .alpha = frame.scene.oklab_clear[3],
} } };

/// The scene-space colour the background is authored with, extracted at
/// comptime. A background authored in sRGB would compile to a different Oklab
/// value and every "nothing is painted here" probe would lose its reference,
/// so this is a compile-time failure rather than a runtime check.
const authored_clear: paint.Oklab = switch (clear_fill) {
    .solid => |color| switch (color) {
        .oklab => |lab| lab,
        else => @compileError("the specimen's background must be authored in scene space"),
    },
    else => @compileError("the specimen's background must be a solid fill"),
};

/// The resolution table for this specimen's authored `.palette = n` colours.
/// Caller-owned application data, passed to the public lowering by pointer and
/// read only for the frame's duration — the seam `SceneOptions.palette` exists
/// for. Index 0 is the pure red this file already carries a PUBLISHED Oklab
/// landmark for, so a palette-authored pixel is held to a hard number instead
/// of to a value the converter produced for it; index 1 is a colour no
/// landmark exists for, and the panel beside it is authored as the same sRGB
/// triple, so the two agree only if the index resolved to that triple.
const specimen_palette = [_]paint.Srgb{
    .{ .r = 1, .g = 0, .b = 0 },
    .{ .r = 0.20, .g = 0.60, .b = 0.35 },
};

/// A palette entry as the one published converter takes it: the same
/// `srgbToOklab` every other probe in this file is derived through, which
/// `check.converters` holds to hardcoded landmarks before any GPU work.
fn paletteRgb(color: paint.Srgb) [4]f32 {
    return .{ color.r, color.g, color.b, color.a };
}

/// The scene inputs every frame of this run is lowered with. The palette is
/// the only one: an overlay or an icon source here would descend into the same
/// 768 slots the capacity arm measures, and this run authors neither.
fn specimenSceneOptions() frame.scene.SceneOptions {
    return .{ .palette = &specimen_palette };
}

// ── Oklab landmarks ──
// The published sRGB→Oklab landmarks, evaluated in double precision from the
// canonical sRGB cone-response matrix (the exact row-primary values, not the
// rounded 0.4124/0.3576/0.1805 form). Hardcoded so no probe is ever compared
// against a value produced by the same code it is testing; `check.converters`
// cross-checks the public converter against them before any GPU work happens.
// The GPU readback agrees with this table to about 5e-6 — that residue is the
// rgba32_float round trip, not a disagreement about colour.

const lab_white = [3]f32{ 1.0, 0.0, 0.0 };
const lab_red = [3]f32{ 0.627955, 0.224863, 0.125846 };
const lab_green = [3]f32{ 0.866440, -0.233888, 0.179498 };
const lab_blue = [3]f32{ 0.452014, -0.032457, -0.311528 };
const lab_gray_90 = [3]f32{ 0.923423, 0.0, 0.0 };
const lab_gray_15 = [3]f32{ 0.269650, 0.0, 0.0 };

const clear_lab = [3]f32{
    frame.scene.oklab_clear[0],
    frame.scene.oklab_clear[1],
    frame.scene.oklab_clear[2],
};

/// Enough for a hard-edged axis-aligned rect over the clear: coverage there is
/// exactly 0 or 1 and the blend is one f32 multiply-add.
const tight: f32 = 0.004;
/// For a feature whose distance field is exact but whose coverage crosses a
/// device pixel (radii corners, curve boundaries, stroke bands).
const loose: f32 = 0.05;

// ── reporting ──

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// A printed value that is not checked is not evidence, so every claim is
/// counted and a single failure ends the run.
const Checks = struct {
    report: *Reporter,
    passed: u32 = 0,
    failed: u32 = 0,

    fn claim(self: *Checks, label: []const u8, holds: bool) !void {
        if (holds) self.passed += 1 else self.failed += 1;
        try self.report.emit("{s} {s}\n", .{
            if (holds) "  ok  " else "  FAIL",
            label,
        });
    }

    fn near(
        self: *Checks,
        label: []const u8,
        channel: []const u8,
        expected: f32,
        observed: f32,
        tol: f32,
    ) !void {
        const holds = std.math.isFinite(observed) and @abs(expected - observed) <= tol;
        try self.report.emit("{s} {s} {s}: {d:.5} (want {d:.5} +-{d:.5})\n", .{
            if (holds) "  ok  " else "  FAIL",
            label,
            channel,
            observed,
            expected,
            tol,
        });
        if (holds) self.passed += 1 else self.failed += 1;
    }

    /// A count read off the image, held to a window. Printed so a reader can
    /// see how far off a spatial measurement landed.
    fn count(
        self: *Checks,
        label: []const u8,
        observed: i32,
        low: i32,
        high: i32,
    ) !void {
        const holds = observed >= low and observed <= high;
        try self.report.emit("{s} {s}: {d} px (want {d}..{d})\n", .{
            if (holds) "  ok  " else "  FAIL",
            label,
            observed,
            low,
            high,
        });
        if (holds) self.passed += 1 else self.failed += 1;
    }

    /// One claim per Oklab channel. The channel is a separate argument rather
    /// than a `label ++ " L"` concatenation, because the labels reach this
    /// function as runtime slices.
    fn claimLab(
        self: *Checks,
        label: []const u8,
        expected: [3]f32,
        observed: [3]f32,
        tol: f32,
    ) !void {
        try self.near(label, "L", expected[0], observed[0], tol);
        try self.near(label, "a", expected[1], observed[1], tol);
        try self.near(label, "b", expected[2], observed[2], tol);
    }
};

/// One straight-alpha blend, which is the single blend state `recordFrameScene`
/// installs for every drawable, so this is the exact expected value.
fn blend(under: [3]f32, over: [3]f32, alpha: f32) [3]f32 {
    return .{
        under[0] * (1 - alpha) + over[0] * alpha,
        under[1] * (1 - alpha) + over[1] * alpha,
        under[2] * (1 - alpha) + over[2] * alpha,
    };
}

fn lerpLab(from: [3]f32, to: [3]f32, t: f32) [3]f32 {
    return .{
        from[0] + (to[0] - from[0]) * t,
        from[1] + (to[1] - from[1]) * t,
        from[2] + (to[2] - from[2]) * t,
    };
}

/// Euclidean distance in Oklab. Lightness alone cannot separate a colour from a
/// gray field it is close to: sRGB blue sits 0.18 in L from the border panel's
/// gray, which reads as "the same surface", while as colours the pair is 0.36
/// apart — most of the difference is in b. Every "these two pixels are
/// different colours" claim is therefore a distance, never an L comparison.
fn labDistance(a: [3]f32, b: [3]f32) f32 {
    const dl = a[0] - b[0];
    const da = a[1] - b[1];
    const db = a[2] - b[2];
    return @sqrt(dl * dl + da * da + db * db);
}

/// The public converter answers with a straight-alpha Oklab quad, while every
/// probe here reads the L, a, b triple out of the rgba32_float readback. The
/// channel count is a shape difference, not a measurement, so it is dropped
/// here instead of being padded with the alpha the probes never carry.
fn labTriplet(rgb: [4]f32) [3]f32 {
    return .{ rgb[0], rgb[1], rgb[2] };
}

// ── paint authoring helpers ──

const Writer = nogui.element.PaintWriter;

fn r(x: f32, y: f32, w: f32, h: f32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

fn solidRect(
    writer: *Writer,
    bounds: Rect,
    color: paint.Color,
    radii: paint.Radii,
) nogui.element.Error!void {
    try writer.addRect(.{ .bounds = bounds, .fill = .{ .solid = color }, .radii = radii });
}

fn opacityRect(
    writer: *Writer,
    bounds: Rect,
    color: paint.Color,
    opacity: f32,
) nogui.element.Error!void {
    try writer.addRect(.{
        .bounds = bounds,
        .fill = .{ .solid = color },
        .opacity = opacity,
    });
}

fn gradientRect(
    writer: *Writer,
    bounds: Rect,
    first: paint.Color,
    second: paint.Color,
    angle: f32,
) nogui.element.Error!void {
    try writer.addRect(.{
        .bounds = bounds,
        .fill = .{ .gradient = .{
            .first = .{ .color = first, .position = 0 },
            .second = .{ .color = second, .position = 1 },
            .angle = angle,
        } },
    });
}

fn patternRect(
    writer: *Writer,
    bounds: Rect,
    first: paint.Color,
    second: paint.Color,
    cell: paint.Point,
    kind: paint.PatternKind,
) nogui.element.Error!void {
    try writer.addRect(.{
        .bounds = bounds,
        .fill = .{ .pattern = .{ .first = first, .second = second, .cell = cell, .kind = kind } },
    });
}

fn shadowRect(
    writer: *Writer,
    bounds: Rect,
    color: paint.Color,
    radii: paint.Radii,
    shadows: []const paint.Shadow,
) nogui.element.Error!void {
    try writer.addRect(.{
        .bounds = bounds,
        .fill = .{ .solid = color },
        .radii = radii,
        .shadows = shadows,
    });
}

fn fillPath(
    writer: *Writer,
    bounds: Rect,
    shape: path.Path,
    color: paint.Color,
    rule: paint.FillRule,
) nogui.element.Error!void {
    try writer.addPath(.{
        .bounds = bounds,
        .path = shape,
        .fill = .{ .solid = color },
        .fill_rule = rule,
    });
}

fn strokePath(
    writer: *Writer,
    bounds: Rect,
    shape: path.Path,
    color: paint.Color,
    width: f32,
    dash: []const f32,
    phase: f32,
) nogui.element.Error!void {
    try writer.addPath(.{
        .bounds = bounds,
        .path = shape,
        .stroke = .{ .color = color, .width = width, .dash = dash, .phase = phase },
    });
}

/// Nested square contours, identical apart from their bounds, so the two fill
/// rules can be compared on exactly the same geometry.
const ring_commands = [_]path.Command{
    .{ .move = .{ .x = 0, .y = 0 } },
    .{ .line = .{ .x = 80, .y = 0 } },
    .{ .line = .{ .x = 80, .y = 80 } },
    .{ .line = .{ .x = 0, .y = 80 } },
    .{ .close = {} },
    .{ .move = .{ .x = 15, .y = 15 } },
    .{ .line = .{ .x = 65, .y = 15 } },
    .{ .line = .{ .x = 65, .y = 65 } },
    .{ .line = .{ .x = 15, .y = 65 } },
    .{ .close = {} },
};

/// A horizontal run in bounds-local units, used for the solid/dashed/phase
/// comparison. Bounds y=167/212/252 place the run's centre on y=170/215/255.
const run_commands = [_]path.Command{
    .{ .move = .{ .x = 0, .y = 3 } },
    .{ .line = .{ .x = 160, .y = 3 } },
};

/// The curve panel's four outlines, one command list each.
///
/// They MUST NOT share a `path.Builder`. A builder is an append-only command
/// log with no reset: `moveTo` starts a new contour inside the SAME list, and
/// `path()` hands the whole log to the renderer. Every paint record carries its
/// own bounds, so a shared list replays each earlier outline under every later
/// shape's own box — the quadratic, re-tessellated into the arc's frame, runs
/// straight through the middle of the arc ring and inks the hole the ring probe
/// reads. One list per outline is what makes each draw its own geometry.
const quadratic_commands = [_]path.Command{
    .{ .move = .{ .x = 0, .y = 40 } },
    .{ .quadratic = .{ .control = .{ .x = 55, .y = 0 }, .end = .{ .x = 110, .y = 40 } } },
};

const cubic_commands = [_]path.Command{
    .{ .move = .{ .x = 0, .y = 0 } },
    .{ .cubic = .{
        .first = .{ .x = 25, .y = 40 },
        .second = .{ .x = 75, .y = 40 },
        .end = .{ .x = 100, .y = 0 },
    } },
};

/// A 25-unit arc from due left through due top. It stops 3.0 radians in, which
/// leaves the bottom of its own circle unwritten.
const arc_ring_commands = [_]path.Command{
    .{ .move = .{ .x = 0, .y = 25 } },
    .{ .arc = .{
        .center = .{ .x = 25, .y = 25 },
        .radii = .{ .x = 25, .y = 25 },
        .start = std.math.pi,
        .sweep = 3.0,
    } },
};

/// The filled disc: one 6.0-radian arc from due right, closed by its chord. The
/// sweep stops 0.28 radians short of the full turn, so the chord clips a small
/// notch at the right — the outline is the disc, not a closed circle.
const disc_commands = [_]path.Command{
    .{ .move = .{ .x = 20, .y = 10 } },
    .{ .arc = .{
        .center = .{ .x = 10, .y = 10 },
        .radii = .{ .x = 10, .y = 10 },
        .start = 0,
        .sweep = 6.0,
    } },
    .{ .close = {} },
};

const dash_20 = [_]f32{ 20, 20 };

/// Which authored revision of the specimen a frame paints. An enum, not a
/// counter: an unauthored revision is then unrepresentable, so `authoredCorner`
/// below cannot fall back and make the second frame's claims true for a panel
/// nobody drew. The default run only ever paints `.first`, so it sees exactly
/// the frame its 386 claims describe.
const Revision = enum(u32) { first = 0, changed = 1 };

/// The one authored panel the two-frame proof makes its claims about, in the
/// shape each revision paints it. Both the paint hook and the claims read
/// THESE values: a probe carrying its own copy of this geometry could agree
/// with a specimen that was never painted.
const Panel = struct {
    bounds: Rect,
    color: paint.Color,
    radii: paint.Radii,
};

/// `.first`: the wide, white, hard-cornered box every radius probe in `check`
/// reads. Its right end is well inside it, which is where `.changed`'s vacated
/// probe looks.
const corner_first: Panel = .{
    .bounds = r(30, 30, 160, 90),
    .color = white,
    .radii = .{ 48, 6, 48, 6 },
};

/// `.changed`: the SAME panel, re-authored smaller, in red, with corner radii
/// small enough not to clamp against its own shorter edge. The two revisions
/// differ in three authored facts at once — bounds, fill colour and radii — so
/// "the second frame painted something else" cannot be satisfied by a frame
/// that merely moved. It shares the panel's top-left corner with `.first`, so
/// the vacated region below is real vacated geometry and not a new panel
/// somewhere else.
const corner_changed: Panel = .{
    .bounds = r(30, 30, 80, 45),
    .color = red,
    .radii = .{ 12, 3, 12, 3 },
};

/// The corner panel a revision paints.
fn authoredCorner(revision: Revision) Panel {
    return switch (revision) {
        .first => corner_first,
        .changed => corner_changed,
    };
}

/// Inside the authored bounds of BOTH corner panels, and clear of both their
/// corner arcs, so it reads the authored fill rather than an edge.
const corner_interior_x: i32 = 70;
const corner_interior_y: i32 = 52;
/// Inside `.first`'s panel and outside `.changed`'s. Its lightness is the
/// change itself: white under `.first`, the bare clear under `.changed`.
const corner_vacated_x: i32 = 150;
const corner_vacated_y: i32 = 80;

/// The outline `check.fillRules` fills with `.even_odd`. Its commands are a
/// file-level constant and the record that carries them owns a copy allocated
/// out of the frame arena, so comparing the live record against the authored
/// list after the NEXT commit is a claim about borrowed data and not about a
/// length.
const ring_bounds: Rect = .{ .x = 30, .y = 160, .w = 80, .h = 80 };

/// P(1,2)-gap: the non-trivial-stop gradient. Its stops sit at 0.25 and 0.75 of
/// the box's own projection, so the left quarter and the right quarter are each
/// a FLAT stop colour and only the middle half ramps — a picture a pair of 0/1
/// stops cannot produce at any sample point.
const stop_bounds: Rect = r(420, 280, 170, 30);
/// P(0,3): a palette index, its sRGB twin, and a second index, side by side.
const palette_index_bounds: Rect = r(375, 505, 18, 18);
const palette_twin_bounds: Rect = r(397, 505, 18, 18);
const palette_srgb_bounds: Rect = r(419, 505, 18, 18);

/// P(0,3): ONE rect carrying TWO outset shadows, aimed at opposite corners so
/// each lobe falls outside the fill and outside the other shadow's own shape.
const two_shadow_bounds: Rect = r(310, 508, 40, 24);
const two_shadow_warm: paint.Color = .{ .srgb = .{ .r = 1, .g = 0, .b = 0, .a = 0.6 } };
const two_shadow_cool: paint.Color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1, .a = 0.6 } };
/// The two authored shadows themselves. A file-level value, because the paint
/// hook copies it into the frame arena and the lifetime proof compares the
/// copy the record owns against it after the next commit.
const two_shadows = [_]paint.Shadow{
    .{ .color = two_shadow_warm, .offset = .{ .x = 14, .y = 10 }, .blur = 4, .spread = 2 },
    .{ .color = two_shadow_cool, .offset = .{ .x = -14, .y = -10 }, .blur = 4, .spread = 2 },
};

/// One sample inside each swatch, and one in the gutter between the first two.
const palette_probe_index0_x: i32 = 384;
const palette_probe_index0_y: i32 = 514;
const palette_probe_index1_x: i32 = 406;
const palette_probe_srgb_x: i32 = 428;
const palette_probe_gutter_x: i32 = 394;

/// The stop ramp's sample columns and rows. `first` is below the first stop,
/// `mid` sits between the two, and `beyond` is past the second one — where `t`
/// is clamped to 1 across a flat quarter of the box, and far enough from the
/// box's own end that a pair of 0/1 stops would be measurably the wrong colour
/// there. Row 295 is the middle of the 30-unit box.
const stop_probe_first_x: i32 = 440;
const stop_probe_mid_x: i32 = 505;
const stop_probe_beyond_x: i32 = 560;
const stop_probe_top_y: i32 = 285;
const stop_probe_mid_y: i32 = 295;
const stop_probe_bottom_y: i32 = 305;

/// Where the lowering will put one outset shadow's own quad: the box grown by
/// its spread and blur and moved by its offset. Derived from the authored
/// shadow, so the probe points below cannot drift away from the geometry when
/// an offset or a blur is retuned.
fn outsetLobe(bounds: Rect, shadow: paint.Shadow) Rect {
    const pad = shadow.blur + @max(shadow.spread, 0);
    return r(
        bounds.x + shadow.offset.x - pad,
        bounds.y + shadow.offset.y - pad,
        bounds.w + 2 * pad,
        bounds.h + 2 * pad,
    );
}

const two_shadow_warm_lobe: Rect = outsetLobe(two_shadow_bounds, two_shadows[0]);
const two_shadow_cool_lobe: Rect = outsetLobe(two_shadow_bounds, two_shadows[1]);

/// One sample inside the warm lobe, outside the fill and outside the cool
/// shadow's own quad; one inside the cool lobe, likewise; and one beyond both.
const two_shadow_fill_x: i32 = 330;
const two_shadow_fill_y: i32 = 520;
const two_shadow_warm_x: i32 = 356;
const two_shadow_warm_y: i32 = 534;
const two_shadow_cool_x: i32 = 304;
const two_shadow_cool_y: i32 = 516;
const two_shadow_bare_x: i32 = 390;
const two_shadow_bare_y: i32 = 500;

// ── the transform target, laid out in the strip below the specimen ──

/// Its authored box. The specimen's clip owns everything above y=540, so this
/// element sits in the one strip of the window the specimen cannot paint, and
/// the column parks it at x=0 there — which makes its own canvas-local units
/// and the window's the same units for every probe below.
const transform_box: Rect = r(0, 0, 60, 20);
/// The translation its single record is authored with. It is at least the box's
/// own WIDTH, so the painted quad lands entirely OUTSIDE the element — only
/// reachable because the element does not clip its own canvas — and the
/// element's hit box therefore cannot follow the ink.
const transform_offset_x: f32 = 120;

// ── the capacity arm's four flood canvases ──

/// How many ordinary public canvas siblings `--exercise-capacity` publishes,
/// and how many records each one holds. Per ELEMENT the count stays under the
/// `PaintWriter`'s own 256-record limit, so the only boundary in reach is the
/// frame's material partition, which is the one this arm is about.
const flood_canvas_count: usize = 4;
const flood_records_per_canvas: usize = 200;
const flood_columns: usize = 20;
const flood_cell_w: f32 = 3;
const flood_cell_h: f32 = 2;
const flood_rows: usize = flood_records_per_canvas / flood_columns;
const flood_w: f32 = @as(f32, @floatFromInt(flood_columns)) * flood_cell_w;
const flood_h: f32 = @as(f32, @floatFromInt(flood_rows)) * flood_cell_h;

/// Whether this run publishes the ordinary specimen or the frame that
/// deliberately outgrows the material partition. An enum, not a counter: an
/// unauthored value is then unrepresentable, so `Root.draw` cannot fall back
/// to the specimen for a frame nobody over-authored.
const Pressure = enum { ordinary, overloaded };

// ── the specimen element ──

const Specimen = struct {
    /// Which authored revision this element paints. The App copies the run's
    /// value into the frame arena, so the revision a frame commits is the
    /// revision its records were built from — and the presented run can change
    /// it between two frames without either frame seeing the other's arena.
    ///
    /// Not named `revision`: `element.make` reads a field of that name into
    /// its own `u64` frame counter, so a `Revision` enum under that name would
    /// be a type error at the one place the element is created.
    authored_revision: Revision = .first,

    pub const PhaseState = struct {
        content: nogui.widget.Rect = .{},
        prepainted: bool = false,
    };

    pub fn measure(
        _: *const Specimen,
        input: nogui.element.MeasureInput,
    ) nogui.element.Error!nogui.widget.Size {
        return .{
            .width = input.known_dimensions.width orelse canvas_w,
            .height = input.known_dimensions.height orelse canvas_h,
        };
    }

    pub fn prepaint(
        _: *const Specimen,
        state: *PhaseState,
        geometry: nogui.element.Geometry,
    ) nogui.element.Error!void {
        state.content = geometry.content;
        state.prepainted = true;
    }

    pub fn paint(
        payload: *const Specimen,
        state: *PhaseState,
        geometry: nogui.element.Geometry,
        canvas: *Writer,
    ) nogui.element.Error!void {
        // A canvas paints against the FINAL prepaint box, not the size it asked
        // for. A mismatch here would silently move every probe in this file.
        if (!state.prepainted or !std.meta.eql(state.content, geometry.content)) {
            return error.PhaseReentry;
        }
        const content = geometry.content;

        // ── P(0,0): independent corner radii ───────────────────────
        // The one panel the revision selects. Both revisions paint it here, at
        // the same point in the paint order and against the same slot, so the
        // record the lifetime proof follows exists in both frames.
        const corner = authoredCorner(payload.authored_revision);
        try solidRect(canvas, corner.bounds, corner.color, corner.radii);

        // ── P(1,0): two-stop gradient along +x ──────────────────────
        try gradientRect(canvas, r(240, 30, 160, 70), red, blue, 0);
        try solidRect(canvas, r(240, 108, 60, 16), white, .{ 0, 0, 0, 0 });

        // ── P(2,0): two-stop gradient along +y ──────────────────────
        try gradientRect(canvas, r(450, 30, 160, 70), green, red, std.math.pi / 2.0);
        try solidRect(canvas, r(450, 110, 60, 16), white, .{ 0, 0, 0, 0 });

        // ── P(0,1): even-odd versus nonzero on the same outlines ──────
        // The even-odd panel's box is a named constant because the lifetime
        // proof looks the record up by exactly these bounds.
        try fillPath(
            canvas,
            ring_bounds,
            .{ .commands = &ring_commands },
            white,
            .even_odd,
        );
        try fillPath(
            canvas,
            r(125, 160, 80, 80),
            .{ .commands = &ring_commands },
            white,
            .nonzero,
        );

        // ── P(1,1): dashes, and dash phase ───────────────────────
        try strokePath(canvas, r(240, 167, 160, 6), .{ .commands = &run_commands }, white, 6, &.{}, 0);
        try strokePath(canvas, r(240, 212, 160, 6), .{ .commands = &run_commands }, white, 6, &dash_20, 0);
        try strokePath(canvas, r(240, 252, 160, 6), .{ .commands = &run_commands }, white, 6, &dash_20, 10);

        // ── P(2,1): quadratic, cubic and arc geometry, and a curve fill ─
        // Four outlines, four command lists. A `path.Builder` is an append-only
        // log with no reset, so one shared list would re-tessellate the
        // quadratic and the cubic into the arc's and the disc's own bounds;
        // see `quadratic_commands` for what that did to the frame.
        const quad: path.Path = .{ .commands = &quadratic_commands };
        const cubic: path.Path = .{ .commands = &cubic_commands };
        const arc_ring: path.Path = .{ .commands = &arc_ring_commands };
        const disc: path.Path = .{ .commands = &disc_commands };
        try strokePath(canvas, r(450, 140, 110, 40), quad, white, 5, &.{}, 0);
        try strokePath(canvas, r(450, 235, 100, 40), cubic, white, 5, &.{}, 0);
        try strokePath(canvas, r(565, 175, 50, 50), arc_ring, white, 5, &.{}, 0);
        // The disc's outline is one 6-radian arc plus its closing chord.
        try fillPath(canvas, r(575, 235, 20, 20), disc, white, .nonzero);

        // ── P(0,2): primitive opacity ─────────────────────────
        try opacityRect(canvas, r(20, 290, 34, 100), white, 0.25);
        try opacityRect(canvas, r(60, 290, 34, 100), white, 0.50);
        try opacityRect(canvas, r(100, 290, 34, 100), white, 0.75);
        try opacityRect(canvas, r(140, 290, 34, 100), white, 1.00);

        // ── P(1,2): render transforms ─────────────────────────
        // A: a plain box, far from everything below.
        try solidRect(canvas, r(230, 278, 90, 26), white, .{ 0, 0, 0, 0 });
        // B: the same box translated by (90, 40). Record bounds are already
        // window coordinates by the time a transform applies, so a plain
        // window-space offset is the whole transform. Its original box is
        // left empty, which is what makes the move observable.
        try canvas.addRect(.{
            .bounds = r(230, 316, 90, 26),
            .fill = .{ .solid = white },
            .transform = .{ .tx = 90, .ty = 40 },
        });
        // C: a quarter turn about the box's own top-left corner. The affine
        // (x,y) -> (tx - y, ty + x) pins (ox,oy) to itself when
        // tx = ox + oy and ty = oy - ox, which maps a 26x26 box onto
        // [ox-26, ox] x [oy, oy+26] — a different window box entirely.
        const ox = content.x + 360;
        const oy = content.y + 316;
        try canvas.addRect(.{
            .bounds = r(360, 316, 26, 26),
            .fill = .{ .solid = white },
            .transform = .{ .a = 0, .b = 1, .c = -1, .d = 0, .tx = ox + oy, .ty = oy - ox },
        });

        // ── P(2,2): the canvas clip cuts the right edge ──────────────
        try solidRect(canvas, r(600, 290, 100, 60), white, .{ 0, 0, 0, 0 });

        // ── P(0,3): an outset shadow over asymmetric radii, and the
        //    bottom clip edge. Radii read {top-left, top-right, bottom-right,
        //    bottom-left}, so this box is square at top-left and bottom-right
        //    and cut to a 30-unit radius at top-right and bottom-left: the
        //    shadow panel's two corner claims sit on the two different kinds.
        try shadowRect(canvas, r(30, 420, 100, 60), gray_90, .{ 0, 30, 0, 30 }, &.{
            .{
                .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 0, .a = 0.85 } },
                .offset = .{ .x = 8, .y = 8 },
                .blur = 12,
                .spread = 2,
            },
        });
        try solidRect(canvas, r(160, 495, 110, 90), white, .{ 0, 0, 0, 0 });

        // ── P(1,3): an inset shadow ──────────────────────────
        try shadowRect(canvas, r(240, 420, 120, 70), white, .{ 24, 24, 24, 24 }, &.{
            .{
                .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 0, .a = 0.9 } },
                .blur = 14,
                .inset = true,
            },
        });

        // ── P(2,3): pattern fills and per-side border styles ─────────
        try patternRect(canvas, r(440, 415, 80, 45), white, red, .{ .x = 10, .y = 10 }, .checker);
        try patternRect(canvas, r(530, 415, 80, 45), white, green, .{ .x = 10, .y = 10 }, .stripes);
        try canvas.addRect(.{
            .bounds = r(440, 475, 170, 35),
            .fill = .{ .solid = gray_15 },
            .borders = .{
                .{ .width = 4, .color = white, .style = .solid },
                .{ .width = 4, .color = red, .style = .dashed },
                .{ .width = 4, .color = green, .style = .dotted },
                .{ .width = 4, .color = blue, .style = .solid },
            },
        });

        // ── P(1,2)-gap: gradient stops that are NOT the box's own ends ──
        // 0.25 and 0.75 of the box's projection, along +x.
        try canvas.addRect(.{
            .bounds = stop_bounds,
            .fill = .{ .gradient = .{
                .first = .{ .color = red, .position = 0.25 },
                .second = .{ .color = blue, .position = 0.75 },
                .angle = 0,
            } },
        });

        // ── P(0,3): palette-indexed fills, and their sRGB twin ────────
        // Index 0 is the published red; index 1 is a colour no landmark
        // exists for, and the third panel is that same triple authored
        // directly, so the middle and the right panel may only agree if the
        // index resolved to it.
        try solidRect(canvas, palette_index_bounds, .{ .palette = 0 }, .{ 0, 0, 0, 0 });
        try solidRect(canvas, palette_twin_bounds, .{ .palette = 1 }, .{ 0, 0, 0, 0 });
        try solidRect(canvas, palette_srgb_bounds, .{ .srgb = specimen_palette[1] }, .{ 0, 0, 0, 0 });

        // ── P(0,3): a SHADOW ARRAY of two on one rect ────────────────
        // Opposite offsets, so the warm lobe is only reachable from the first
        // shadow and the cool lobe only from the second.
        try shadowRect(canvas, two_shadow_bounds, gray_90, .{ 0, 0, 0, 0 }, &two_shadows);
    }
};

/// The one element whose ink leaves its own box. Its single record fills the
/// element's content box and is authored with a translation at least as wide
/// as that box, so the painted quad sits clear of the element — and the
/// element's hit box stays exactly where layout put it. Nothing else in this
/// file transforms an element's OWN paint: the specimen's transform panel
/// moves a record inside a much larger clipped canvas, where the two boxes
/// cannot be told apart by an input probe.
const TransformTarget = struct {
    pub const PhaseState = struct {
        content: nogui.widget.Rect = .{},
        prepainted: bool = false,
    };

    pub fn measure(
        _: *const TransformTarget,
        input: nogui.element.MeasureInput,
    ) nogui.element.Error!nogui.widget.Size {
        return .{
            .width = input.known_dimensions.width orelse transform_box.w,
            .height = input.known_dimensions.height orelse transform_box.h,
        };
    }

    pub fn prepaint(
        _: *const TransformTarget,
        state: *PhaseState,
        geometry: nogui.element.Geometry,
    ) nogui.element.Error!void {
        state.content = geometry.content;
        state.prepainted = true;
    }

    pub fn paint(
        _: *const TransformTarget,
        state: *PhaseState,
        geometry: nogui.element.Geometry,
        canvas: *Writer,
    ) nogui.element.Error!void {
        // The same prepaint-agreement contract the specimen holds itself to.
        if (!state.prepainted or !std.meta.eql(state.content, geometry.content)) {
            return error.PhaseReentry;
        }
        const content = geometry.content;
        try canvas.addRect(.{
            .bounds = r(0, 0, content.w, content.h),
            .fill = .{ .solid = white },
            .transform = .{ .tx = transform_offset_x, .ty = 0 },
        });
    }
};

/// One of the capacity arm's four flood canvases. An ordinary public canvas
/// element like `Specimen`: it paints round-cornered rects from its own
/// prepaint content origin, and the round corners are what make each of them a
/// RICH primitive — a plain solid rides the flat vertex-colour path and costs
/// no material slot at all, so a flood of flat rects would never reach the
/// partition this arm measures.
const Flood = struct {
    pub const PhaseState = struct {
        content: nogui.widget.Rect = .{},
        prepainted: bool = false,
    };

    pub fn measure(
        _: *const Flood,
        input: nogui.element.MeasureInput,
    ) nogui.element.Error!nogui.widget.Size {
        return .{
            .width = input.known_dimensions.width orelse flood_w,
            .height = input.known_dimensions.height orelse flood_h,
        };
    }

    pub fn prepaint(
        _: *const Flood,
        state: *PhaseState,
        geometry: nogui.element.Geometry,
    ) nogui.element.Error!void {
        state.content = geometry.content;
        state.prepainted = true;
    }

    pub fn paint(
        _: *const Flood,
        state: *PhaseState,
        geometry: nogui.element.Geometry,
        canvas: *Writer,
    ) nogui.element.Error!void {
        if (!state.prepainted or !std.meta.eql(state.content, geometry.content)) {
            return error.PhaseReentry;
        }
        var index: usize = 0;
        while (index < flood_records_per_canvas) : (index += 1) {
            const column = index % flood_columns;
            const line = index / flood_columns;
            try solidRect(
                canvas,
                r(
                    @as(f32, @floatFromInt(column)) * flood_cell_w,
                    @as(f32, @floatFromInt(line)) * flood_cell_h,
                    flood_cell_w,
                    flood_cell_h,
                ),
                white,
                .{ 1, 1, 1, 1 },
            );
        }
    }
};

const Root = struct {
    specimen: nogui.FrameNodeId = .root,
    /// The element `check.transformHit` probes the input routing against. Read
    /// back out of the committed frame, so the claims name the node layout
    /// actually produced rather than an id this file carried across.
    transform_target: nogui.FrameNodeId = .root,
    /// The four flood canvases the capacity arm publishes, each named by the
    /// node the frame committed it as.
    floods: [flood_canvas_count]nogui.FrameNodeId = .{ .root, .root, .root, .root },
    /// Which authored revision the specimen paints this frame. The run owns
    /// this value and changes it between the two frames the presented path
    /// publishes; the App copies it into each frame's arena, so neither frame
    /// can observe the other's revision.
    revision: Revision = .first,
    /// Whether this frame also publishes the flood canvases. Only the capacity
    /// arm sets it, and it clears it again before the specimen frame, so the
    /// 386/430 picture is the one every probe above was authored against.
    pressure: Pressure = .ordinary,

    pub fn draw(self: *Root, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.column(.{
            .gap = 0,
            .@"align" = .start,
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .grow = 0,
            .shrink = 0,
            // The background is authored in scene space, so the frame is
            // exactly `oklab_clear` and every "nothing here" probe has one
            // known value.
            .fill = clear_fill,
        });
        defer ctx.pop();
        self.specimen = try ctx.elementLeaf(Specimen, .{ .authored_revision = self.revision }, .{
            .@"align" = .start,
            .width = canvas_w,
            .height = canvas_h,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
            .clip = true,
        });

        // The strip below the specimen's own clip rect. It holds the transform
        // target in EVERY frame and the capacity arm's flood canvases in the
        // overloaded one, so both sit at the same coordinates in both.
        _ = try ctx.row(.{
            .gap = 0,
            .@"align" = .start,
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .grow = 0,
            .shrink = 0,
            .fill = clear_fill,
        });
        defer ctx.pop();
        self.transform_target = try ctx.elementLeaf(TransformTarget, .{}, .{
            .@"align" = .start,
            .width = transform_box.w,
            .height = transform_box.h,
            .box_sizing = .border_box,
            .grow = 0,
            .shrink = 0,
            // Deliberately unclipped: the transform is only observable leaving
            // its own box if the element's content clip is not in the way.
            .clip = false,
        });
        if (self.pressure == .overloaded) {
            for (&self.floods) |*slot| {
                slot.* = try ctx.elementLeaf(Flood, .{}, .{
                    .@"align" = .start,
                    .width = flood_w,
                    .height = flood_h,
                    .box_sizing = .border_box,
                    .grow = 0,
                    .shrink = 0,
                    .clip = false,
                });
            }
        } else {
            self.floods = .{ .root, .root, .root, .root };
        }
    }
};

// ── pixel access ──

const Image = struct {
    pixels: []const f32,
    extent: noapi.Extent2D,
    /// The canvas element's prepaint content origin in device pixels. Probes
    /// are authored in canvas-local units and offset by it, so the clip probes
    /// stay correct wherever layout parks the element.
    origin_x: i32,
    origin_y: i32,

    /// Oklab at the canvas-local pixel `(x, y)`.
    fn at(self: Image, x: i32, y: i32) [3]f32 {
        const px = self.origin_x + x;
        const py = self.origin_y + y;
        std.debug.assert(px >= 0);
        std.debug.assert(py >= 0);
        std.debug.assert(px < @as(i32, @intCast(self.extent.width)));
        std.debug.assert(py < @as(i32, @intCast(self.extent.height)));
        const index = (@as(usize, @intCast(py)) * self.extent.width + @as(usize, @intCast(px))) * 4;
        return .{ self.pixels[index], self.pixels[index + 1], self.pixels[index + 2] };
    }

    /// The first and last canvas-local column on row `y` whose Oklab lightness
    /// clears `threshold`. Null when the row carries no ink at all.
    fn inkSpan(
        self: Image,
        y: i32,
        from: i32,
        to: i32,
        threshold: f32,
    ) ?struct { first: i32, last: i32 } {
        var first: ?i32 = null;
        var last: ?i32 = null;
        var x = from;
        while (x <= to) : (x += 1) {
            if (self.at(x, y)[0] > threshold) {
                if (first == null) first = x;
                last = x;
            }
        }
        if (first == null) return null;
        return .{ .first = first.?, .last = last.? };
    }

    /// How many columns of a row clear `threshold`.
    fn inkCount(self: Image, y: i32, from: i32, to: i32, threshold: f32) i32 {
        var total: i32 = 0;
        var x = from;
        while (x <= to) : (x += 1) {
            if (self.at(x, y)[0] > threshold) total += 1;
        }
        return total;
    }
};

/// Coverage above this counts as inked for a span scan. It sits above the
/// half-ink value of every edge in this specimen, so a measured cut is the same
/// whether a boundary pixel lands on 0.6 or 0.7.
const ink_threshold: f32 = 0.65;

// ── shader file ──

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

// ── the run ──

/// Which surface this run paints through. `--native` picks `presented`; the
/// default is `windowless`, which opens no visible window and makes no surface.
const Mode = enum { windowless, presented };

const Options = struct {
    native: bool = false,
    /// The PPM path, positional exactly as the default has always read it. A
    /// presented run writes the same file from the last frame it presented.
    ppm: ?[]u8 = null,
    /// How long the presented window is held up after the last frame.
    hold_ms: u32 = 0,
    /// Publish the frame that outgrows the frame's material partition BEFORE
    /// the ordinary one, on whichever surface this run already uses. Every
    /// pixel claim is then made against the specimen published afterwards
    /// through the SAME target and the SAME material-ring slot.
    exercise_capacity: bool = false,

    fn mode(self: Options) Mode {
        return if (self.native) .presented else .windowless;
    }

    fn ppmPath(self: Options) []const u8 {
        return self.ppm orelse default_ppm;
    }

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        if (self.ppm) |owned| gpa.free(owned);
        self.* = undefined;
    }
};

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    var options: Options = .{};
    errdefer options.deinit(gpa);
    var hold_seen = false;
    var capacity_seen = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            // Opt-in because it is the only path that opens a window and
            // attaches a swapchain to it on the session's display server.
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--hold-ms")) {
            if (hold_seen) return error.RepeatedHold;
            hold_seen = true;
            const text = args.next() orelse return error.MissingHold;
            options.hold_ms = std.fmt.parseUnsigned(u32, text, 10) catch
                return error.InvalidHold;
            if (options.hold_ms > max_hold_ms) return error.HoldExceedsTheBound;
        } else if (std.mem.eql(u8, arg, "--exercise-capacity")) {
            // A frame, not a mode: it adds one refused publication to whichever
            // surface the run already publishes through, and every claim after
            // it is the ordinary specimen's.
            if (capacity_seen) return error.RepeatedCapacityArm;
            capacity_seen = true;
            options.exercise_capacity = true;
        } else if (options.ppm != null) {
            return error.UnexpectedArgument;
        } else {
            options.ppm = try gpa.dupe(u8, arg);
        }
    }
    // The hold exists to leave something presented to photograph. There is
    // nothing to photograph on the windowless path, so asking for it there is
    // a refusal rather than a silently ignored option.
    if (options.hold_ms != 0 and !options.native) return error.HoldNeedsTheNativePath;
    return options;
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var options = try parseArgs(gpa, init);
    defer options.deinit(gpa);

    switch (options.mode()) {
        .windowless => try runWindowless(gpa, io, options),
        .presented => try runPresented(gpa, io, options),
    }
}

/// The default surface: one real frame into a `v7_frame.Offscreen` target built
/// from the public loader seam. No window, no SDL, no surface, no raw Vulkan
/// handle. Every pixel claim below is made against that frame's readback.
fn runWindowless(gpa: std.mem.Allocator, io: Io, options: Options) !void {
    var report: Reporter = .{ .io = io };
    var checks: Checks = .{ .report = &report };
    try report.emit("W13 offscreen paint specimen: {d}x{d} window, {d}x{d} canvas\n", .{
        @as(u32, @intFromFloat(window_w)),
        @as(u32, @intFromFloat(window_h)),
        @as(u32, @intFromFloat(canvas_w)),
        @as(u32, @intFromFloat(canvas_h)),
    });

    // If the Oklab landmarks move, every probe below measures the wrong thing,
    // so the run stops here rather than reporting a confusing pixel mismatch.
    try check.converters(&checks);

    var vert = try ShaderFile.load(gpa, io, "shaders/quad_vert.spv");
    defer vert.deinit(gpa);
    var frag = try ShaderFile.load(gpa, io, "shaders/quad_frag.spv");
    defer frag.deinit(gpa);
    var sort = try ShaderFile.load(gpa, io, "shaders/sort_comp.spv");
    defer sort.deinit(gpa);

    var system_loader = try frame.SystemVulkanLoader.open();
    defer system_loader.close();
    var offscreen = try frame.Offscreen.init(.{
        .allocator = gpa,
        .io = io,
        .loader = system_loader.options(),
        .extent = device_extent,
        .app_name = "w13-canvas-smoke",
    });
    defer offscreen.deinit();
    const gpu = offscreen.gpu();

    var text = try frame.TextEngine.init(gpa, gpu, &.{
        .{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") },
    });
    defer text.deinit();
    try text.setGlyphSlotLimit(frame.scene.glyph_material_ceiling);

    var gui_renderer = try render.Renderer.init(gpu, vert.words, frag.words, sort.words);
    defer gui_renderer.deinit();
    gui_renderer.configure(.{ .material_bda = text.materialBda() });
    var scratch = frame.scene.SceneScratch.init(gpa, &gui_renderer);
    defer scratch.deinit();

    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch @panic("w13 canvas smoke left a live window");
    var root: Root = .{};
    var app = try nogui.App.init(gpa, &session);
    defer app.deinit();
    try app.mountRoot(Root, &root);
    app.measure = text.measurer();
    try app.attachGpu(offscreen.endpoint());
    defer app.detachGpu();

    // SAFETY: `beginFrame` assigns `cmd` and then `gpu_frame` before it
    // returns; a refusal returns through the `try` on the next line with
    // neither value read, and every read below sits after that call succeeded.
    var cmd: noapi.CommandBuffer = undefined;
    // SAFETY: the second out-parameter of that same `beginFrame` call, filled
    // immediately after `cmd` and read by the same later statements.
    var gpu_frame: nogui.GpuFrame = undefined;

    // `--exercise-capacity` publishes its refused frame through THIS SAME
    // offscreen target first, and hands back the material-ring slot the
    // refusal left alone so the specimen frame below can be shown to reuse it.
    var refused_slot: ?u32 = null;
    if (options.exercise_capacity) {
        refused_slot = try exerciseMaterialCapacity(
            &checks,
            gpa,
            &app,
            &root,
            &scratch,
            &text,
            &gui_renderer,
            &offscreen,
            &cmd,
            &gpu_frame,
        );
    }
    try offscreen.beginFrame(0, &cmd, &gpu_frame);
    errdefer if (gpu_frame.recording == .active) {
        gpu_frame.cancelRecording() catch @panic("offscreen recording cancellation failed");
    };
    var out = try app.frameWithGpuAtTime(
        1,
        0,
        .{ .width = window_w, .height = window_h },
        &gpu_frame,
    );
    defer if (out.json) |json| gpa.free(json);

    scratch.beginFrame();
    if (refused_slot) |slot| {
        try checks.claim(
            "the recovered specimen lowers into the SAME material-ring slot the refusal left alone",
            scratch.nextFrameSlot() == slot,
        );
    }
    var painted = try frame.scene.buildFrameScene(&scratch, &text, specimenSceneOptions(), &out, false);
    defer painted.deinit();
    const record: frame.scene.RecordContext = .{
        .arena = out.tree.allocator,
        .renderer = &gui_renderer,
        .text = &text,
        .logical = .{ .width = window_w, .height = window_h },
        .device = device_extent,
        .texture_heap = offscreen.heap().handle,
        .clips = out.tree.clip_rects[0..out.tree.clip_count],
    };
    _ = try frame.scene.recordFrameScene(
        &record,
        &cmd,
        &scratch,
        scratch.rects.items,
        &painted,
        offscreen.target(),
    );
    const pixels = try offscreen.submitRead(&gpu_frame);

    try probeSpecimen(&checks, nogui.visualContentRect(out.tree, root.specimen), pixels, device_extent);
    try check.transformHit(
        &checks,
        out.tree,
        root.transform_target,
        canvasImage(pixels, device_extent),
    );
    try finish(&checks, gpa, io, options.ppmPath(), pixels, device_extent);
}

/// The claims every mode makes on its own frame, in the same order: the box the
/// specimen element actually occupies, and then every pixel claim in `check`
/// against the image that box addresses. Both modes call THIS, so the presented
/// surface is measured by the same oracles and in the same order as the
/// windowless one instead of by a second copy of them.
fn probeSpecimen(
    checks: *Checks,
    content: nogui.Rect,
    pixels: []const f32,
    extent: noapi.Extent2D,
) !void {
    try checks.report.emit("canvas content box: ({d:.1},{d:.1}) {d:.1}x{d:.1}\n", .{
        content.x,
        content.y,
        content.w,
        content.h,
    });
    const origin_ok = content.x == 0 and content.y == 0 and
        content.w == canvas_w and content.h == canvas_h;
    try checks.claim(
        "canvas element occupies exactly the authored 620x540 box at the origin",
        origin_ok,
    );
    if (origin_ok) {
        const image: Image = .{
            .pixels = pixels,
            .extent = extent,
            .origin_x = 0,
            .origin_y = 0,
        };
        try check.clear(checks, image);
        try check.radii(checks, image);
        try check.gradients(checks, image);
        try check.fillRules(checks, image);
        try check.dashes(checks, image);
        try check.curves(checks, image);
        try check.opacity(checks, image);
        try check.transforms(checks, image);
        try check.clip(checks, image);
        try check.shadows(checks, image);
        try check.patterns(checks, image);
        try check.borders(checks, image);
        try check.stopPositions(checks, image);
        try check.shadowArrays(checks, image);
        try check.paletteSwatches(checks, image);
    }
}

/// One borrowed path's commands, compared against an authored command list
/// element by element. `std.meta.eql` on a slice compares its POINTER and its
/// length, and the record's commands are a fresh copy allocated out of the
/// frame arena — so a pointer comparison here would be a comparison of two
/// different allocations and would prove nothing at all.
fn commandsAgree(borrowed: []const path.Command, authored: []const path.Command) bool {
    if (borrowed.len != authored.len) return false;
    for (borrowed, authored) |observed, expected| {
        if (!std.meta.eql(observed, expected)) return false;
    }
    return true;
}

/// The same, for a stroke's dash array.
fn dashesAgree(borrowed: []const f32, authored: []const f32) bool {
    if (borrowed.len != authored.len) return false;
    for (borrowed, authored) |observed, expected| {
        if (observed != expected) return false;
    }
    return true;
}

/// Whether two optional strokes carry the same authored value, the dash array
/// included.
fn strokeAgrees(a: ?paint.SceneStroke, b: ?paint.SceneStroke) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    if (!std.meta.eql(left.color, right.color)) return false;
    if (left.width != right.width or left.phase != right.phase) return false;
    return dashesAgree(left.dash, right.dash);
}

fn sameBox(a: Rect, b: Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

/// A scene colour as the probes read it: the L, a, b triple out of the quad,
/// without the alpha the readback probes never carry.
fn oklabTriplet(lab: paint.Oklab) [3]f32 {
    return .{ lab.l, lab.a, lab.b };
}

/// The Oklab a revision's corner panel was authored in. The published landmark,
/// not the converter's own answer, so a drifted conversion cannot agree with a
/// drifted record.
fn cornerLandmark(revision: Revision) [3]f32 {
    return switch (revision) {
        .first => lab_white,
        .changed => lab_red,
    };
}

fn finish(
    checks: *Checks,
    gpa: std.mem.Allocator,
    io: Io,
    ppm_path: []const u8,
    pixels: []const f32,
    extent: noapi.Extent2D,
) !void {
    try frame.writePpm(gpa, io, ppm_path, pixels, extent);
    try checks.report.emit(
        "\n{d} passed, {d} failed; ppm written to {s}\n",
        .{ checks.passed, checks.failed, ppm_path },
    );
    if (checks.failed != 0) return error.CanvasSmokeClaimFailed;
}

/// The closing line for a run that cannot write a PPM. The claims made so far
/// are reported and the run ends here, because a probe read at a scale it was
/// not authored for is not a failed claim — it is a claim about a different
/// picture, and this run refuses to make it.
fn conclude(checks: *Checks, note: []const u8) !void {
    try checks.report.emit("\n{d} passed, {d} failed; {s}\n", .{
        checks.passed,
        checks.failed,
        note,
    });
    return error.CanvasSmokeClaimFailed;
}

// -- Presented surface --

/// The window's own pixel extent, read from the platform rather than assumed.
/// The driver may clamp the image it hands back, and both passes size
/// themselves to that image instead.
fn deviceExtent(managed: *host.ManagedWindow) !noapi.Extent2D {
    const pixels = try managed.native.pixelExtent();
    return .{ .width = pixels.width, .height = pixels.height };
}

/// Compositor round trips spent waiting for the window to take the size and
/// the visibility this run asked for. A bound, not a timeout the run may
/// quietly grow past.
fn settleWindow(
    io: Io,
    application: *host.Application,
    managed: *host.ManagedWindow,
    report: *Reporter,
) !void {
    var polls: u32 = 0;
    while (polls < window_polls) : (polls += 1) {
        const observed = managed.observed;
        if (observed.visible and observed.size.width == @as(u32, @intFromFloat(window_w)) and
            observed.size.height == @as(u32, @intFromFloat(window_h)))
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

/// Keep the presented window up, pumping REAL host events, for at most the
/// requested span. The hold exists so a screenshot taken from another process
/// still finds the frame the claims above were made on; the bound is what
/// keeps that a run rather than a wait. Nothing is published while it runs, so
/// the frame on screen is still the frame that was checked.
fn holdWindow(
    io: Io,
    application: *host.Application,
    report: *Reporter,
    hold_ms: u32,
) !void {
    if (hold_ms == 0) return;
    var waited_ms: u32 = 0;
    var pumps: u32 = 0;
    while (waited_ms < hold_ms) : (waited_ms += hold_slice_ms) {
        _ = try application.step();
        pumps += 1;
        try Io.sleep(io, std.Io.Duration.fromMilliseconds(hold_slice_ms), .real);
    }
    try report.emit("hold: {d}ms in {d} host pumps\n", .{ waited_ms, pumps });
}

/// The presented pipeline: `v7_frame.NativeFrame` over the frame module's own
/// loader and a `noapi.Surface` adopted from the SDL window, into that
/// window's swapchain image. The readback still leaves the Oklab target those
/// same presented passes wrote, so every pixel this file reports is one a
/// PRESENTED frame drew.
///
/// TEARDOWN ORDER, which this value owns: the App detaches from
/// `adapter.gpuEndpoint()` first (the caller does that), then the adapter —
/// which retires its own submitted work with a device wait before it destroys
/// a shader or a descriptor — then the surface, then the device, then this
/// path's loader, and only then the window and SDL. The swapchain and the
/// platform surface live on the device AND reference the native window, so
/// nothing device-side may outlive the window it presents to.
const Presented = struct {
    const Shaders = struct {
        quad_vert: []const u32,
        quad_frag: []const u32,
        sort_comp: []const u32,
        fullscreen_vert: []const u32,
        blit_oklab: []const u32,
    };

    report: *Reporter,
    /// The frame module's own loader — the one the windowless path builds its
    /// device from, so both halves of this file resolve entry points the same
    /// way.
    loader: frame.SystemVulkanLoader,
    gpu: noapi.Gpu,
    /// The platform surface `noapi.Surface.initSdl` created from the SDL window
    /// and adopted. It owns the `VkSurfaceKHR` on the way out, so no SDL
    /// wrapper is kept beside it: there is exactly one owner of that handle.
    surface: noapi.Surface,
    adapter: frame.NativeFrame,
    // SAFETY: NativeFrame.beginFrame fills this before record or cancellation.
    surface_frame: frame.NativeFrame.Frame = undefined,
    /// The size the App lays this frame out in, taken from what the window
    /// observed rather than from what was requested.
    logical: nogui.geometry.WindowSize = .{ .width = 0, .height = 0 },
    /// The image the last acquire handed out. Both passes size themselves to
    /// it, so it — not the requested window size — is what the readback below
    /// is measured against.
    extent: noapi.Extent2D = .{ .width = 0, .height = 0 },
    /// Acquires the swapchain refused. Reported, because a run that retried its
    /// way to an image would be a run whose early attempts were never presented.
    acquire_retries: u32 = 0,
    /// Set when a submission failed. `present` poisons the frame's `GpuFrame`
    /// before it returns, so there is no recording left to cancel and no
    /// resource left that may safely be released.
    poisoned: bool = false,

    /// `self` must be storage the caller keeps in place for this adapter's whole
    /// life: the scene scratch borrows the renderer, the renderer borrows the
    /// device, and a moved copy would leave every one of them naming the
    /// address of the original. Each `errdefer` below is registered AFTER the
    /// resource it releases exists, so a refusal releases exactly what was
    /// built and never touches a field still undefined.
    fn init(
        self: *Presented,
        gpa: std.mem.Allocator,
        io: Io,
        report: *Reporter,
        managed: *host.ManagedWindow,
        shaders: Shaders,
    ) !void {
        self.* = .{
            .report = report,
            // SAFETY: assigned below before use; each cleanup follows its initialization.
            .loader = undefined,
            // SAFETY: assigned below before registering GPU cleanup.
            .gpu = undefined,
            // SAFETY: assigned below before registering surface cleanup.
            .surface = undefined,
            // SAFETY: initialized in place below before returning this owner.
            .adapter = undefined,
        };
        // The loader stays open until every GPU made from its options is gone.
        self.loader = try frame.SystemVulkanLoader.open();
        errdefer self.loader.close();
        self.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers
            // over three slots, one per in-flight frame.
            .frames_in_flight = frame.scene.frames_in_flight,
            .app_name = "w13-canvas-smoke",
            .validation = false,
            .loader = self.loader.options(),
            .io = io,
            .allocator = gpa,
        });
        errdefer self.gpu.deinit();
        // SDL's own Vulkan subsystem, for the platform surface call and nothing
        // else: on Wayland `SDL_Vulkan_CreateSurface` refuses with "Vulkan is
        // not loaded" unless this has run. The device above is built from the
        // frame module's loader, not from this one.
        try sdl3.vulkan.loadLibrary(null);
        // One call hands the window to the platform and takes the surface
        // back: the instance and the platform handle never leave noapi, and a
        // failed call destroys what the platform made.
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
            .name = "w13_canvas_smoke_blit_oklab",
        });
    }

    /// The App must already have detached from `endpoint`.
    fn deinit(self: *Presented) void {
        if (self.poisoned) {
            // A failed submission left a recording that cannot be closed, and
            // the resources that recording may reference may not be released
            // under it. The adapter's own `deinit` asserts against exactly this
            // state, so it is not called. The device is retired with its
            // window still alive, which is the most this path can honestly do
            // once a present has failed.
            self.gpu.waitIdle() catch |err| {
                std.debug.panic("canvas GPU retirement failed: {s}", .{@errorName(err)});
            };
            self.gpu.deinit();
            self.loader.close();
            self.* = undefined;
            return;
        }
        self.adapter.deinit();
        // Before the device: the swapchain and the platform surface live on
        // it, and the platform surface references the native window.
        self.surface.deinit();
        // The count is read while the device is still alive: releasing the
        // surface is what has to take the device's surface count back down, and
        // a device that still holds one outlived the window it presents to.
        if (self.gpu.numSurfaces() != 0) {
            @panic("w13 canvas smoke left a surface on the device after the window went");
        }
        self.gpu.deinit();
        // The loader outlives every device made from it, so it closes last.
        self.loader.close();
        // SAFETY: every owned resource is released before invalidation.
        self.* = undefined;
    }

    fn endpoint(self: *Presented) *nogui.GpuEndpoint {
        return self.adapter.gpuEndpoint();
    }

    /// Ask the window what it is showing, take the viewport that answers, and
    /// acquire the next image. A swapchain that is out of date is not a
    /// failure: the adapter is asked again, bounded, so a driver that never
    /// settles fails the run instead of spinning.
    fn beginFrame(self: *Presented, managed: *host.ManagedWindow) !void {
        const observed = managed.observed;
        self.logical = .{
            .width = @floatFromInt(observed.size.width),
            .height = @floatFromInt(observed.size.height),
        };
        var attempts: u32 = 0;
        while (attempts < acquire_polls) : (attempts += 1) {
            const viewport: frame.NativeFrame.Viewport = .{
                .logical = self.logical,
                .device = try deviceExtent(managed),
                .scale = try observed.pixelScale(),
            };
            if (try self.adapter.beginFrame(&self.surface, viewport, &self.surface_frame)) {
                self.extent = self.surface_frame.image;
                return;
            }
            self.acquire_retries += 1;
        }
        return error.SwapchainNeverSettled;
    }

    /// Discard a recording whose frame failed before its submission. Cheap and
    /// terminal either way, so it is also safe from an `errdefer`.
    fn cancelFrame(self: *Presented) void {
        if (self.poisoned) return;
        self.adapter.cancelFrame(&self.surface_frame) catch |err| switch (err) {
            // The surface treats an idle frame as an already-discarded one and
            // reports success; this layer names the case itself.
            error.FrameNotRecording => {},
            else => @panic("w13 canvas smoke presented cancellation failed"),
        };
    }

    /// Lower the committed tree, record the Oklab pass and the blit, and
    /// present. The converted paint is returned so the caller can hold it
    /// across the NEXT commit — which is what the lifetime proof below does.
    fn record(
        self: *Presented,
        out: *const nogui.FrameOutput,
        managed: *host.ManagedWindow,
    ) !frame.scene.FramePaint {
        var painted = try self.adapter.buildScene(specimenSceneOptions(), out);
        // Both defers unwind on every failure below and on no success path: the
        // paint leaves this function by value, and whichever recording is still
        // open when it returns is the one that has to be closed.
        var handed_off = false;
        defer if (!handed_off) painted.deinit();
        var cancel = true;
        defer if (cancel) self.cancelFrame();
        try self.adapter.recordScene(&self.surface, &self.surface_frame, out, &painted);
        // `present` closes the recording itself. A submission that fails has
        // already poisoned the frame's `GpuFrame`, so there is nothing left to
        // cancel and nothing left that may safely be released: the run says so
        // here, and `deinit` stops short of the adapter on that account.
        self.adapter.present(&self.surface, &self.surface_frame) catch |err| {
            self.poisoned = true;
            self.report.emit(
                "present refused: {s}; this frame's GPU resources are left to the device\n",
                .{@errorName(err)},
            ) catch @panic("w13 canvas smoke could not report the present failure");
            return err;
        };
        cancel = false;
        handed_off = true;
        managed.markPresented();
        return painted;
    }

    /// The Oklab pixels the last PRESENTED passes wrote, waited for and copied
    /// out of the target. Real readback of that frame, not a re-render. The
    /// slice dies at the next `readTarget`, at a target resize and at `deinit`,
    /// which is why every claim made from it is made before the next one.
    fn readTarget(self: *Presented) ![]const f32 {
        return self.adapter.readTarget();
    }
};

/// What one published frame left behind: the paint its tree produced and the
/// box the specimen element actually occupied inside that same tree. Both are
/// allocated out of that frame's arena, which is what makes holding them across
/// the next commit a claim about the App's arena policy rather than about this
/// file.
const Published = struct {
    paint: frame.scene.FramePaint,
    content: nogui.Rect,
    /// The committed tree this frame built, borrowed from the App's arena. It
    /// stays readable until a frame two commits later, which is the same window
    /// `paint` is already held across, so the input claims read the same real
    /// tree the pixels were rendered from.
    tree: *const nogui.widget.WidgetTree,
    /// The transform target this frame laid out, taken back out of the run's
    /// own root after the commit so the hit claims name the node layout
    /// produced rather than an id this file carried across.
    transform_target: nogui.FrameNodeId,
};

/// One frame, end to end: acquire the swapchain image, publish the App's tree
/// into it, lower and record the Oklab pass and the blit, and present. The
/// frame's own paint is handed back because the second frame's claims are made
/// against the first frame's.
fn publishFrame(
    gpa: std.mem.Allocator,
    presented: *Presented,
    app: *nogui.App,
    root: *const Root,
    managed: *host.ManagedWindow,
    tick: u32,
    now_ms: u64,
) !Published {
    try presented.beginFrame(managed);
    errdefer presented.cancelFrame();
    const out = try app.frameWithGpuAtTime(
        tick,
        now_ms,
        .{ .width = presented.logical.width, .height = presented.logical.height },
        &presented.surface_frame.gpu_frame,
    );
    defer if (out.json) |json| gpa.free(json);
    const painted = try presented.record(&out, managed);
    // The frame is on the device, so the App's clock may advance. A host makes
    // this call itself after a successful present; a frame that never reached
    // one returns through the `try` above and never gets here.
    app.framePresented(now_ms);
    return .{
        .paint = painted,
        .content = nogui.visualContentRect(out.tree, root.specimen),
        .tree = out.tree,
        .transform_target = root.transform_target,
    };
}

/// The presented surface: the SAME specimen, the SAME shaders and the SAME
/// claims as the default, over `v7_frame.NativeFrame` into a real window's
/// swapchain image — plus the two-frame paint lifetime proof the windowless
/// default cannot make, because it publishes one frame and stops.
fn runPresented(gpa: std.mem.Allocator, io: Io, options: Options) !void {
    var report: Reporter = .{ .io = io };
    var checks: Checks = .{ .report = &report };
    try report.emit("W13 presented paint specimen: {d}x{d} window, {d}x{d} canvas\n", .{
        @as(u32, @intFromFloat(window_w)),
        @as(u32, @intFromFloat(window_h)),
        @as(u32, @intFromFloat(canvas_w)),
        @as(u32, @intFromFloat(canvas_h)),
    });
    try check.converters(&checks);

    var vert = try ShaderFile.load(gpa, io, "shaders/quad_vert.spv");
    defer vert.deinit(gpa);
    var frag = try ShaderFile.load(gpa, io, "shaders/quad_frag.spv");
    defer frag.deinit(gpa);
    var sort = try ShaderFile.load(gpa, io, "shaders/sort_comp.spv");
    defer sort.deinit(gpa);
    // Only the presented path records a blit, so only it opens the two modules
    // that blit is drawn with. Both owners are released by ONE defer registered
    // HERE, at function scope, because `Presented.init` below reads their
    // SPIR-V: a defer registered inside a narrower scope would free them
    // before the adapter that reads those words was released.
    var fullscreen = try ShaderFile.load(gpa, io, default_fullscreen_shader);
    defer fullscreen.deinit(gpa);
    var oklab_blit = try ShaderFile.load(gpa, io, default_oklab_shader);
    defer oklab_blit.deinit(gpa);

    var session = try nogui.Session.init(gpa);
    // Both the success path and every failure below reach this, so the Session
    // and the host it was handed to are always released in that order: the
    // window close registered below unwinds first.
    defer session.deinit() catch @panic("w13 canvas smoke left a live Session");
    // The host owns SDL. No video driver is forced: `--native` is already an
    // explicit request to use the display session this process finds, and a
    // forced driver would replace that decision with one made here.
    var application = try host.Application.init(gpa, &session, .{
        .app_id = app_id,
        .restart = .never,
    });
    defer application.deinit();

    const handle = try application.openWindow(.{
        .title = window_title,
        .width = @as(u32, @intFromFloat(window_w)),
        .height = @as(u32, @intFromFloat(window_h)),
        // The probes below are authored one logical unit per device pixel, so
        // the window is opened unresizable: a user resize would move every one
        // of them, and this run has nothing to say about a picture it did not
        // author.
        .resizable = false,
        .visible = true,
        .gpu_surface = true,
    });
    // Registered before every device-side owner below, so it unwinds AFTER all
    // of them: the platform surface and its swapchain reference the X11 window
    // this destroys, and nothing device-side may outlive it.
    defer {
        _ = application.closeWindow(handle) catch |err| {
            report.emit("teardown close: {s}\n", .{@errorName(err)}) catch
                @panic("w13 canvas smoke could not report the teardown close failure");
        };
    }
    const managed = try application.getWindow(handle);
    const app = managed.app;

    var root: Root = .{};
    try app.mountRoot(Root, &root);

    // Created IN PLACE and never moved: the adapter's scene scratch borrows its
    // renderer and the renderer borrows the device.
    // SAFETY: init assigns every field before use and unwinds acquired resources on failure.
    var presented: Presented = undefined;
    try Presented.init(&presented, gpa, io, &report, managed, .{
        .quad_vert = vert.words,
        .quad_frag = frag.words,
        .sort_comp = sort.words,
        .fullscreen_vert = fullscreen.words,
        .blit_oklab = oklab_blit.words,
    });
    // ORDERED TEARDOWN, and it is the only order in which nothing device-side
    // outlives the window it presents to. Registered last, so it unwinds
    // first: the App's GPU mounts detach, then the adapter retires its work
    // and releases its shaders, then the surface, then the device, then the
    // loader, and only then the window and SDL. This runs on the error path;
    // the shutdown at the end of the run does the same work in the same order.
    defer presented.deinit();
    defer app.detachGpu();
    try app.attachGpu(presented.endpoint());
    app.measure = presented.adapter.measurer();

    try settleWindow(io, &application, managed, &report);
    const window_ok = try check.observedWindow(&checks, managed);
    if (!window_ok) return conclude(&checks, "the window is not the geometry these probes were authored for");

    // ── frame 0 (only with `--exercise-capacity`): the frame the material
    //    partition refuses. It is published through `publishFrame`, so it is
    //    acquired, lowered and recorded exactly as the two specimen frames
    //    below are, and its `errdefer` is the seam that closes its recording.
    var refused_slot: ?u32 = null;
    if (options.exercise_capacity) {
        refused_slot = try exerciseMaterialCapacityPresented(
            &checks,
            gpa,
            &presented,
            app,
            &root,
            managed,
        );
    }

    // ── frame 1: revision `.first`, the specimen every check describes ──
    var first = try publishFrame(gpa, &presented, app, &root, managed, 1, 0);
    if (refused_slot) |slot| {
        try checks.claim(
            "the recovered specimen presents from the SAME material-ring slot the refusal left alone",
            presented.adapter.sceneScratch().nextFrameSlot() == slot,
        );
    }
    if (!try check.presentedExtent(&checks, presented.extent)) {
        return conclude(&checks, "the acquired image is not the geometry these probes were authored for");
    }
    try report.emit("acquired image: {d}x{d}, acquire retries: {d}\n", .{
        presented.extent.width,
        presented.extent.height,
        presented.acquire_retries,
    });
    // The witness. Taken now, while frame 1 is the committed tree: it is the
    // only thing this run holds that cannot be reset by a later commit, so
    // comparing the frame's own records against it afterwards is a statement
    // about those records.
    var first_copy = try PaintCopy.capture(gpa, first.paint.records());
    defer first_copy.deinit();
    const first_pixels = try presented.readTarget();
    try probeSpecimen(&checks, first.content, first_pixels, presented.extent);
    try check.transformHit(
        &checks,
        first.tree,
        first.transform_target,
        canvasImage(first_pixels, presented.extent),
    );
    // The proof's handles into frame 1, each located by the bounds its panel
    // was AUTHORED with, so none of them is a claim about the lowering's order.
    const first_slots = try locateAuthoredRecords(first.paint.records(), .first);
    try check.authoredRecords(&checks, .first, first.paint.records(), first_slots);
    try check.cornerPixels(&checks, canvasImage(first_pixels, presented.extent), .first);

    // ── frame 2: revision `.changed`, the SAME specimen re-authored ──
    root.revision = .changed;
    var second = try publishFrame(gpa, &presented, app, &root, managed, 2, frame_step_ms);
    const second_pixels = try presented.readTarget();
    const second_slots = try locateAuthoredRecords(second.paint.records(), .changed);
    try check.authoredRecords(&checks, .changed, second.paint.records(), second_slots);
    try check.cornerPixels(&checks, canvasImage(second_pixels, presented.extent), .changed);
    try check.lifetime(&checks, .{
        .copy = first_copy,
        .old = first.paint.records(),
        .new = second.paint.records(),
        .old_slots = first_slots,
        .new_slots = second_slots,
    });
    defer second.paint.deinit();
    defer first.paint.deinit();

    // The hold is the last thing the run does, so a screenshot taken from
    // another process finds the frame the claims above were made on. Nothing is
    // published while it runs, so what is on screen is still what was checked.
    try holdWindow(io, &application, &report, options.hold_ms);

    try finish(&checks, gpa, io, options.ppmPath(), second_pixels, presented.extent);
}

/// The specimen's own pixel space. Both frames of the presented path are read
/// through this, because the claims were authored in canvas-local units and
/// the canvas is asserted to sit at the origin before any of them is made.
fn canvasImage(pixels: []const f32, extent: noapi.Extent2D) Image {
    return .{ .pixels = pixels, .extent = extent, .origin_x = 0, .origin_y = 0 };
}

/// Whether the committed tree routes `point` to `target`. This is the public
/// hit test the App's own pointer routing calls, read on the tree the frame
/// just committed — not a stand-in for it.
fn hitIs(tree: *const nogui.widget.WidgetTree, point: [2]f32, target: nogui.FrameNodeId) bool {
    const hit = nogui.hitTest(tree, point) orelse return false;
    return hit == target;
}

/// The gradient position the shader reads at a device column of `stop_bounds`.
/// The sample is the pixel CENTRE, so the authored column and the drawn column
/// differ by half a unit — the value a probe really reads is derived here,
/// never guessed at the call site.
fn stopPosition(device_x: i32) f32 {
    return (@as(f32, @floatFromInt(device_x)) - stop_bounds.x + 0.5) / stop_bounds.w;
}

// -- The material-partition capacity arm --

/// What one publication attempt did: it either recorded, or it was refused and
/// by which typed error. The error VALUE is carried, not its name, so the
/// claim below is about the refinement itself rather than about a string.
const Publication = union(enum) {
    recorded,
    refused: anyerror,

    fn refusalName(self: Publication) ?[]const u8 {
        return switch (self) {
            .recorded => null,
            .refused => |err| @errorName(err),
        };
    }

    /// Whether the frame was refused by the material partition's own typed
    /// error. A switch, so the union is narrowed before its payload is named.
    fn isMaterialCapacity(self: Publication) bool {
        return switch (self) {
            .recorded => false,
            .refused => |err| err == error.MaterialCapacity,
        };
    }
};

/// `--exercise-capacity` on the windowless surface: one real frame that
/// publishes MORE rich canvas records than the frame's own material partition
/// holds, on the SAME `Offscreen` target the ordinary specimen is then
/// published through.
///
/// The pressure is four ordinary public canvas siblings — the same
/// `elementLeaf` shape as the specimen — each painting
/// `flood_records_per_canvas` round-cornered rects, which is under the 256
/// records ONE element may hold. Nothing here is a private hook, a hand-built
/// `PaintList` or a scratch-only unit double: the App lays the frame out, the
/// paint hooks run, `buildFrameScene` converts every record, and
/// `recordFrameScene` is the call that refuses.
///
/// Returns the material-ring slot the refusal left behind, so the caller can
/// show the recovered specimen reusing it.
fn exerciseMaterialCapacity(
    checks: *Checks,
    gpa: std.mem.Allocator,
    app: *nogui.App,
    root: *Root,
    scratch: *frame.scene.SceneScratch,
    text: *frame.TextEngine,
    gui_renderer: *render.Renderer,
    offscreen: *frame.Offscreen,
    cmd: *noapi.CommandBuffer,
    gpu_frame: *nogui.GpuFrame,
) !u32 {
    root.pressure = .overloaded;
    try offscreen.beginFrame(0, cmd, gpu_frame);
    errdefer if (gpu_frame.recording == .active) {
        gpu_frame.cancelRecording() catch @panic("offscreen recording cancellation failed");
    };
    const out = try app.frameWithGpuAtTime(
        0,
        0,
        .{ .width = window_w, .height = window_h },
        gpu_frame,
    );
    defer if (out.json) |json| gpa.free(json);

    scratch.beginFrame();
    // The ring slot the refusal has to leave behind. `scratch` captured it from
    // the renderer a moment ago, and the renderer only hands out the NEXT one
    // once a sort has run — so a refusal that happened before the sort must
    // leave this value untouched for the recovered specimen to reuse.
    const refused_ring = gui_renderer.nextFrameSlot();
    var painted = try frame.scene.buildFrameScene(scratch, text, specimenSceneOptions(), &out, false);
    defer painted.deinit();

    // Four DISTINCT public canvas siblings each contributed, each located by
    // the box the frame committed it as, so "enough records" is a fact about
    // four real laid-out elements rather than about one loop counter.
    for (root.floods) |flood| {
        const content = nogui.visualContentRect(out.tree, flood);
        const found = findRecord(.rect, painted.records(), .{
            .x = content.x,
            .y = content.y,
            .w = flood_cell_w,
            .h = flood_cell_h,
        });
        try checks.claim(
            "each of the four flood canvases published its own authored record at its own box",
            found != null,
        );
    }
    try checks.count(
        "the overloaded frame's authored paint records against its 768-slot material partition",
        @intCast(painted.records().len),
        @intCast(frame.scene.frame_material_slots + 1),
        @intCast(flood_canvas_count * flood_records_per_canvas + 64),
    );

    const record: frame.scene.RecordContext = .{
        .arena = out.tree.allocator,
        .renderer = gui_renderer,
        .text = text,
        .logical = .{ .width = window_w, .height = window_h },
        .device = device_extent,
        .texture_heap = offscreen.heap().handle,
        .clips = out.tree.clip_rects[0..out.tree.clip_count],
    };
    const publication: Publication = if (frame.scene.recordFrameScene(
        &record,
        cmd,
        scratch,
        scratch.rects.items,
        &painted,
        offscreen.target(),
    )) |_| .recorded else |err| .{ .refused = err };
    try checks.report.emit(
        "overloaded frame: {d} authored records, ring slot {d}, target {d}x{d}, refused with: {s}\n",
        .{
            painted.records().len,
            refused_ring,
            offscreen.extent().width,
            offscreen.extent().height,
            publication.refusalName() orelse "nothing: the frame recorded",
        },
    );
    try checks.claim(
        "the overloaded frame is refused by the typed material-partition error, not a panic or a later failure",
        publication.isMaterialCapacity(),
    );

    // Nothing reached the GPU: the lowering refuses BEFORE the sort, so the
    // recording holds no commands. It is discarded rather than submitted —
    // the same close the ordinary frame's own `errdefer` would have done.
    try gpu_frame.cancelRecording();
    try checks.claim(
        "the refused frame's recording is cancelled, never submitted",
        gpu_frame.recording == .cancelled,
    );
    try checks.claim(
        "the refusal left the material ring exactly where that frame found it: the sort never ran",
        gui_renderer.nextFrameSlot() == refused_ring,
    );
    // The refusal cost the run one RECORDING, not its target: the offscreen
    // still owns the same render target and readback the recovered specimen is
    // about to be submitted into, at the extent it was built with.
    try checks.claim(
        "the refusal left the offscreen target and its readback intact for the recovered frame",
        std.meta.eql(offscreen.extent(), device_extent),
    );
    root.pressure = .ordinary;
    return refused_ring;
}

/// The same arm on the presented surface, through the ONE publication seam the
/// rest of this file uses: `publishFrame` acquires the image, lowers the
/// committed tree and records it, and its own `errdefer` cancels the recording
/// when the record step refuses. The specimen frames after it are published
/// through the same function, on the same adapter and the same swapchain.
fn exerciseMaterialCapacityPresented(
    checks: *Checks,
    gpa: std.mem.Allocator,
    presented: *Presented,
    app: *nogui.App,
    root: *Root,
    managed: *host.ManagedWindow,
) !u32 {
    // The ring slot before the frame, and the recording state the adapter is
    // left in: a frame that never reaches a submission must cost neither.
    const ring_before = presented.adapter.sceneRenderer().nextFrameSlot();
    root.pressure = .overloaded;
    const publication: Publication = if (publishFrame(
        gpa,
        presented,
        app,
        root,
        managed,
        0,
        0,
    )) |_| .recorded else |err| .{ .refused = err };
    const refused_ring = presented.adapter.sceneRenderer().nextFrameSlot();
    try checks.report.emit(
        "overloaded presented frame: ring slot {d}, refused with: {s}\n",
        .{ refused_ring, publication.refusalName() orelse "nothing: the frame presented" },
    );
    try checks.claim(
        "the overloaded presented frame is refused by the typed material-partition error",
        publication.isMaterialCapacity(),
    );
    try checks.claim(
        "the refused presented frame's recording is cancelled, never submitted",
        presented.surface_frame.gpu_frame.recording == .cancelled,
    );
    try checks.claim(
        "the presented refusal left the material ring exactly where that frame found it: the sort never ran",
        refused_ring == ring_before,
    );
    try checks.claim(
        "the refusal did not poison the presented adapter: the next frame may still record",
        !presented.poisoned,
    );
    root.pressure = .ordinary;
    return refused_ring;
}

// -- Frame paint lifetime proof --

/// A run-owned DEEP copy of one frame's converted paint.
///
/// The records `buildFrameScene` returns live in that frame tree's arena, and
/// the App keeps two arenas and resets the one two commits back. Holding the
/// frame's own records across the next commit therefore rests on that policy;
/// holding a COPY rests on nothing, and is what lets the comparison below say
/// what frame 1 contained rather than restate what frame 1 said about itself.
///
/// Every slice a copied record borrows — a path's commands, a rect's shadows, a
/// stroke's dash array — is duplicated too, so the comparison is about the
/// frame's DATA and not about a pointer that happened to survive.
const PaintCopy = struct {
    gpa: std.mem.Allocator,
    /// The copied records. Every slice they borrow points into `owned`.
    records: std.ArrayList(paint.PaintRecord),
    /// The copied slices, tagged with the type each was allocated as.
    owned: std.ArrayList(Owned),

    fn capture(gpa: std.mem.Allocator, records: []const paint.PaintRecord) !PaintCopy {
        var owned: std.ArrayList(Owned) = .empty;
        errdefer {
            for (owned.items) |entry| freeOwned(gpa, entry);
            owned.deinit(gpa);
        }
        var copied: std.ArrayList(paint.PaintRecord) = .empty;
        errdefer copied.deinit(gpa);
        for (records) |record| {
            var next = record;
            switch (next.shape) {
                .rect => |*shape| {
                    if (shape.shadows.len > 0) {
                        const shadows = try copySlice(paint.SceneShadow, gpa, shape.shadows);
                        try keepOwned(gpa, &owned, .{ .shadows = shadows });
                        shape.shadows = shadows;
                    }
                },
                .path => |*shape| {
                    const commands = try copySlice(path.Command, gpa, shape.path.commands);
                    try keepOwned(gpa, &owned, .{ .commands = commands });
                    shape.path.commands = commands;
                    if (shape.stroke) |*stroke| {
                        if (stroke.dash.len > 0) {
                            const dash = try copySlice(f32, gpa, stroke.dash);
                            try keepOwned(gpa, &owned, .{ .dashes = dash });
                            stroke.dash = dash;
                        }
                    }
                },
                .image => {},
            }
            try copied.append(gpa, next);
        }
        return .{ .gpa = gpa, .records = copied, .owned = owned };
    }

    fn deinit(self: *PaintCopy) void {
        const gpa = self.gpa;
        for (self.owned.items) |entry| freeOwned(gpa, entry);
        self.records.deinit(gpa);
        self.owned.deinit(gpa);
        self.* = undefined;
    }

    /// Whether `live` still reads exactly as this copy was taken. Every scalar,
    /// and every borrowed slice element by element.
    fn matches(self: PaintCopy, live: []const paint.PaintRecord) bool {
        if (self.records.items.len != live.len) return false;
        for (self.records.items, live) |a, b| {
            if (!recordAgrees(a, b)) return false;
        }
        return true;
    }

    /// How many records of `live` disagree with the capture. A revision that
    /// changed one panel and nothing else answers exactly one; a frame that
    /// repainted the specimen answers every one of them.
    fn disagreements(self: PaintCopy, live: []const paint.PaintRecord) usize {
        if (self.records.items.len != live.len) return live.len + self.records.items.len;
        var differing: usize = 0;
        for (self.records.items, live) |a, b| {
            if (!recordAgrees(a, b)) differing += 1;
        }
        return differing;
    }
};

/// One variable-size allocation `PaintList` made for a frame's records, tagged
/// with the type it was allocated as. The tag is the whole point: handing an
/// allocation back through a differently-aligned view of it is undefined —
/// these three slice types do not all have the same alignment — so the view a
/// copy was taken through is the view it is released through.
const Owned = union(enum) {
    shadows: []paint.SceneShadow,
    commands: []path.Command,
    dashes: []f32,
};

fn freeOwned(gpa: std.mem.Allocator, entry: Owned) void {
    switch (entry) {
        .shadows => |slice| gpa.free(slice),
        .commands => |slice| gpa.free(slice),
        .dashes => |slice| gpa.free(slice),
    }
}

/// Take ownership of one copy, or release it and report the refusal. A copy
/// that never made it into this list is owned by nobody, so the append itself
/// has to be the thing that can free it.
fn keepOwned(gpa: std.mem.Allocator, owned: *std.ArrayList(Owned), entry: Owned) !void {
    owned.append(gpa, entry) catch |err| {
        freeOwned(gpa, entry);
        return err;
    };
}

/// One copied slice. The caller tags it with the type it was allocated as, so
/// `PaintCopy.deinit` hands back exactly what `capture` asked for.
fn copySlice(comptime T: type, gpa: std.mem.Allocator, source: []const T) ![]T {
    const copy = try gpa.alloc(T, source.len);
    errdefer gpa.free(copy);
    @memcpy(copy, source);
    return copy;
}

/// Whether two converted paint records carry the same value. Every field, and
/// every borrowed slice element by element: `std.meta.eql` on a slice compares
/// its POINTER and its length, so it is only ever used here on value types.
fn recordAgrees(a: paint.PaintRecord, b: paint.PaintRecord) bool {
    if (!sameBox(a.bounds, b.bounds)) return false;
    if (a.transform.a != b.transform.a or a.transform.b != b.transform.b or
        a.transform.c != b.transform.c or a.transform.d != b.transform.d or
        a.transform.tx != b.transform.tx or a.transform.ty != b.transform.ty) return false;
    if (a.clip_id != b.clip_id or a.layer != b.layer) return false;
    if (a.opacity != b.opacity or a.order != b.order) return false;
    switch (a.shape) {
        .rect => |left| switch (b.shape) {
            .rect => |right| {
                if (!std.meta.eql(left.fill, right.fill)) return false;
                for (left.borders, right.borders) |x, y| {
                    if (!std.meta.eql(x, y)) return false;
                }
                for (left.radii, right.radii) |x, y| {
                    if (x != y) return false;
                }
                if (left.shadows.len != right.shadows.len) return false;
                for (left.shadows, right.shadows) |x, y| {
                    if (!std.meta.eql(x, y)) return false;
                }
            },
            else => return false,
        },
        .path => |left| switch (b.shape) {
            .path => |right| {
                if (!std.meta.eql(left.fill, right.fill)) return false;
                if (left.fill_rule != right.fill_rule) return false;
                if (!commandsAgree(left.path.commands, right.path.commands)) return false;
                if (!strokeAgrees(left.stroke, right.stroke)) return false;
            },
            else => return false,
        },
        .image => |left| switch (b.shape) {
            .image => |right| {
                if (!std.meta.eql(left, right)) return false;
            },
            else => return false,
        },
    }
    return true;
}

/// The three records this file follows: the corner panel the revision selects,
/// the even-odd ring, and the dashed run. Each is found by the bounds it was
/// painted with — a fixed index would be a claim about the lowering's order —
/// and a lookup that cannot say which record it found has found nothing, so
/// zero matches and two matches are both refusals.
const AuthoredRecords = struct {
    corner: usize,
    ring: usize,
    dashed: usize,
};

/// The dashed run's authored box: the middle of the three stroke passes.
const dashed_bounds: Rect = .{ .x = 240, .y = 212, .w = 160, .h = 6 };

fn locateAuthoredRecords(records: []const paint.PaintRecord, revision: Revision) !AuthoredRecords {
    const corner = findRecord(.rect, records, authoredCorner(revision).bounds) orelse
        return error.MissingAuthoredCornerRecord;
    const ring = findRecord(.path, records, ring_bounds) orelse
        return error.MissingAuthoredRingRecord;
    const dashed = findRecord(.path, records, dashed_bounds) orelse
        return error.MissingAuthoredDashRecord;
    return .{ .corner = corner, .ring = ring, .dashed = dashed };
}

/// The one record painted into `bounds` with the shape tag `want`, or null when
/// the frame painted none or more than one.
fn findRecord(
    comptime want: std.meta.Tag(@FieldType(paint.PaintRecord, "shape")),
    records: []const paint.PaintRecord,
    bounds: Rect,
) ?usize {
    var found: ?usize = null;
    for (records, 0..) |record, index| {
        switch (record.shape) {
            want => {},
            else => continue,
        }
        if (!sameBox(record.bounds, bounds)) continue;
        if (found != null) return null;
        found = index;
    }
    return found;
}

// ── the claims ──

const check = struct {
    /// The reference values every probe is derived from, cross-checked against
    /// the public converter so a drifted expectation cannot pass silently.
    fn converters(checks: *Checks) !void {
        try checks.claimLab("oklab white", lab_white, labTriplet(frame.srgbToOklab(.{ 1, 1, 1, 1 })), 0.0005);
        try checks.claimLab("oklab red", lab_red, labTriplet(frame.srgbToOklab(.{ 1, 0, 0, 1 })), 0.0005);
        try checks.claimLab("oklab green", lab_green, labTriplet(frame.srgbToOklab(.{ 0, 1, 0, 1 })), 0.0005);
        try checks.claimLab("oklab blue", lab_blue, labTriplet(frame.srgbToOklab(.{ 0, 0, 1, 1 })), 0.0005);
        try checks.claimLab(
            "oklab gray 0.90",
            lab_gray_90,
            labTriplet(frame.srgbToOklab(.{ 0.9, 0.9, 0.9, 1 })),
            0.0005,
        );
        try checks.claimLab(
            "oklab gray 0.15",
            lab_gray_15,
            labTriplet(frame.srgbToOklab(.{ 0.15, 0.15, 0.15, 1 })),
            0.0005,
        );
        try checks.claimLab("authored .oklab colour passes through", clear_lab, .{
            authored_clear.l,
            authored_clear.a,
            authored_clear.b,
        }, tight);
    }

    /// The empty canvas really is the authored scene-space clear, so "nothing
    /// was painted here" is a measurement rather than an assumption, and the
    /// clip already owns the target's outer margin.
    fn clear(checks: *Checks, image: Image) !void {
        try checks.claimLab("frame corner is the Oklab clear", clear_lab, image.at(0, 0), tight);
        try checks.claimLab("the panel gutter is the Oklab clear", clear_lab, image.at(212, 0), tight);
        try checks.claimLab("the bottom margin is the Oklab clear", clear_lab, image.at(0, 533), tight);
        try checks.claimLab("past the right clip edge is the clear", clear_lab, image.at(625, 100), tight);
        try checks.claimLab("past the bottom clip edge is the clear", clear_lab, image.at(100, 545), tight);
    }

    /// P(0,0). `radii = {48, 6, 48, 6}` is scaled by 0.9375 in the shader (the
    /// 48+48 vertical pair is wider than the box's 90 units), giving effective
    /// corners of {45, 5.625, 45, 5.625}. The cuts on one row must therefore
    /// differ by an order of magnitude.
    fn radii(checks: *Checks, image: Image) !void {
        try checks.claimLab("top-left corner (r=45) is inked", lab_white, image.at(70, 70), tight);
        try checks.claimLab("top-right corner (r=5.6) is inked", lab_white, image.at(186, 34), tight);
        try checks.claimLab("bottom-right corner (r=45) is inked", lab_white, image.at(150, 80), tight);
        try checks.claimLab("bottom-left corner (r=5.6) is inked", lab_white, image.at(33, 116), tight);
        try checks.claimLab("outside the top-left arc is clear", clear_lab, image.at(31, 31), tight);
        try checks.claimLab("outside the top-right arc is clear", clear_lab, image.at(189, 31), loose);
        try checks.claimLab("box centre is inked", lab_white, image.at(110, 70), tight);
        try checks.claimLab("left of the box is clear", clear_lab, image.at(28, 70), tight);
        try checks.claimLab("right of the box is clear", clear_lab, image.at(191, 70), tight);
        try checks.claimLab("below the box is clear", clear_lab, image.at(110, 121), tight);

        const left: i32 = 30;
        const right: i32 = 190;
        const top = image.inkSpan(40, left, right, ink_threshold) orelse {
            try checks.claim("the top row carries ink", false);
            return;
        };
        const bottom = image.inkSpan(115, left, right, ink_threshold) orelse {
            try checks.claim("the bottom row carries ink", false);
            return;
        };
        try checks.claim("both scan rows carry ink", true);
        try checks.count("top-left cut", top.first - left, 10, 26);
        try checks.count("top-right cut", right - 1 - top.last, 0, 4);
        try checks.count("bottom-left cut", bottom.first - left, 0, 4);
        try checks.count("bottom-right cut", right - 1 - bottom.last, 16, 32);
        const top_left_cut = top.first - left;
        const top_right_cut = right - 1 - top.last;
        const bottom_left_cut = bottom.first - left;
        const bottom_right_cut = right - 1 - bottom.last;
        try checks.claim(
            "the two top corners differ by more than 4x",
            top_left_cut >= 4 * top_right_cut + 8,
        );
        try checks.claim(
            "the two bottom corners differ by more than 4x",
            bottom_right_cut >= 4 * bottom_left_cut + 12,
        );
        try checks.claim(
            "the two left corners differ (45 top vs 5.6 bottom)",
            top_left_cut >= 8 and bottom_left_cut <= 3,
        );
        try checks.claim(
            "the two right corners differ (5.6 top vs 45 bottom)",
            bottom_right_cut >= 18 and top_right_cut <= 3,
        );
    }

    /// P(1,0) and P(2,0). Both ramps are exact Oklab lerps of the authored
    /// stops; the direction claims are a row/column invariance pair, which a
    /// swapped axis fails immediately.
    fn gradients(checks: *Checks, image: Image) !void {
        // The shader's `position = dot(point - size/2, axis) / span + 0.5`
        // collapses for a cardinal axis to the box-local coordinate over the
        // box's own extent. The sample is the pixel's CENTRE, not its corner:
        // (250,65) is local x = 10.5 of a 160-wide box, so t = 0.065625 — not
        // the 0.0625 a corner read gives, which leaves the `a` channel a third
        // of the tolerance out on its own.
        const left = image.at(250, 65);
        const right = image.at(390, 65);
        try checks.claimLab("gradient +x at 6.5625%", lerpLab(lab_red, lab_blue, 0.065625), left, tight);
        try checks.claimLab("gradient +x at 94.0625%", lerpLab(lab_red, lab_blue, 0.940625), right, tight);
        try checks.claim(
            "gradient +x darkens to the right and swings a->b",
            left[0] - right[0] > 0.10 and left[1] > 0.10 and right[2] < -0.10,
        );
        try checks.claimLab("gradient +x is constant down a column", image.at(250, 35), image.at(250, 95), 0.0001);
        try checks.claimLab("first solid swatch is authored white", lab_white, image.at(270, 116), tight);

        // angle pi/2: the same collapse down y, so (530,40) is local y = 10.5
        // of a 70-tall box and (530,90) is 60.5.
        const top = image.at(530, 40);
        const bottom = image.at(530, 90);
        try checks.claimLab("gradient +y at 15%", lerpLab(lab_green, lab_red, 0.15), top, tight);
        try checks.claimLab("gradient +y at 86.43%", lerpLab(lab_green, lab_red, 0.86428571), bottom, tight);
        try checks.claim(
            "gradient +y darkens downward and swings a->b",
            top[0] - bottom[0] > 0.10 and top[1] < -0.10,
        );
        try checks.claimLab("gradient +y is constant along a row", image.at(460, 40), image.at(590, 40), 0.0001);
        try checks.claimLab("second solid swatch is authored white", lab_white, image.at(480, 118), tight);
        // The two panels must be different fields, not one ramp drawn twice.
        try checks.claim(
            "a vertical ramp is not constant down its own column",
            @abs(image.at(530, 35)[0] - image.at(530, 95)[0]) > 0.10,
        );
        try checks.claim(
            "a horizontal ramp is not constant along its own row",
            @abs(image.at(245, 65)[0] - image.at(395, 65)[0]) > 0.10,
        );
    }

    /// P(0,1). Identical nested outlines under both rules: the ring body is
    /// inked either way, and the hole is the only difference in the frame.
    fn fillRules(checks: *Checks, image: Image) !void {
        try checks.claimLab("even-odd ring body is inked", lab_white, image.at(35, 200), loose);
        try checks.claimLab("even-odd hole is empty", clear_lab, image.at(70, 200), loose);
        try checks.claimLab("nonzero ring body is inked", lab_white, image.at(130, 200), loose);
        try checks.claimLab("nonzero hole is FILLED", lab_white, image.at(165, 200), loose);
        try checks.claimLab("even-odd hole matches the clear exactly", clear_lab, image.at(70, 210), tight);
        try checks.claim(
            "the fill rule changes the hole and only the hole",
            @abs(image.at(35, 200)[0] - image.at(130, 200)[0]) < loose and
                // The even-odd hole is the clear, exactly: nothing under it is
                // inked, so its lightness equals the clear's and no threshold
                // below it can ever hold. The rule's whole effect is that the
                // nonzero twin of that pixel is 0.8 lighter in L.
                @abs(image.at(70, 200)[0] - clear_lab[0]) < loose and
                image.at(165, 200)[0] - image.at(70, 200)[0] > 0.5,
        );
    }

    /// P(1,1). Dash {20,20} over a 160-unit run from x=240 inks [240,260),
    /// [280,300), [320,340), [360,380) and leaves the gaps empty. Phase 10
    /// advances the whole pattern by 10 units, so the on/off answer flips at
    /// every x in (250, 290) — one column, two rows, opposite answers.
    fn dashes(checks: *Checks, image: Image) !void {
        try checks.claimLab("solid run is inked", lab_white, image.at(250, 170), loose);
        try checks.claimLab("solid run is inked at its far end", lab_white, image.at(390, 170), loose);
        try checks.claimLab("four device pixels off a solid run is clear", clear_lab, image.at(250, 176), tight);
        try checks.claimLab("the solid run covers its full 6-unit band", lab_white, image.at(250, 168), loose);

        try checks.claimLab("dash period: first dash inked", lab_white, image.at(250, 215), loose);
        try checks.claimLab("dash period: first gap empty", clear_lab, image.at(270, 215), loose);
        try checks.claimLab("dash period: second dash inked", lab_white, image.at(290, 215), loose);
        try checks.claimLab("dash period: second gap empty", clear_lab, image.at(310, 215), loose);
        try checks.claimLab("dash period: last dash inked", lab_white, image.at(370, 215), loose);
        try checks.claimLab("dash period: tail gap empty", clear_lab, image.at(390, 215), loose);

        // Phase 10 moves every boundary 10 units right: x=275 is inside the
        // second dash at phase 0 and inside the third at phase 10, while x=295
        // is the reverse. One column, two rows, opposite answers.
        try checks.claimLab("phase 10: a gap at phase 0 is now inked", lab_white, image.at(275, 255), loose);
        try checks.claimLab("phase 10: a dash at phase 0 is now empty", clear_lab, image.at(295, 255), loose);
        try checks.claim(
            "dash phase moves the pattern, not the geometry (ink side)",
            @abs(image.at(275, 255)[0] - image.at(275, 215)[0]) > 0.5,
        );
        try checks.claim(
            "dash phase moves the pattern, not the geometry (gap side)",
            @abs(image.at(295, 255)[0] - image.at(295, 215)[0]) > 0.5,
        );

        // Count instead of trusting probes: a 20/20 dash inks about 4x26 of the
        // 160-unit run once each butt cap's antialiasing is counted.
        try checks.count(
            "inked columns on the dashed row",
            image.inkCount(215, 240, 400, ink_threshold),
            96,
            112,
        );
        try checks.count(
            "inked columns on the solid row",
            image.inkCount(170, 240, 400, ink_threshold),
            160,
            170,
        );
    }

    /// P(2,1). Quadratic apex at (505,160), cubic at t=0.5 at (500,265), the arc
    /// ring around (590,200), and the filled disc — probed at its centre, at
    /// both ends of its lowest row, and across its curved apex. Each outline
    /// carries its own command list, so every probe below reads that shape's
    /// geometry and nothing else.
    fn curves(checks: *Checks, image: Image) !void {
        try checks.claimLab("quadratic apex is inked", lab_white, image.at(505, 160), loose);
        try checks.claimLab("quadratic start is inked", lab_white, image.at(450, 180), loose);
        try checks.claimLab("quadratic end is inked", lab_white, image.at(560, 180), loose);
        try checks.claimLab("below the quadratic is clear", clear_lab, image.at(505, 200), loose);
        try checks.claimLab("above the quadratic is clear", clear_lab, image.at(505, 145), loose);

        try checks.claimLab("cubic midpoint is inked", lab_white, image.at(500, 265), loose);
        try checks.claimLab("cubic start is inked", lab_white, image.at(450, 235), loose);
        try checks.claimLab("cubic end is inked", lab_white, image.at(550, 235), loose);
        try checks.claimLab("above the cubic is clear", clear_lab, image.at(500, 240), loose);

        try checks.claimLab("arc ring top is inked", lab_white, image.at(590, 175), loose);
        try checks.claimLab("arc ring left is inked", lab_white, image.at(565, 200), loose);
        try checks.claimLab("arc ring upper right is inked", lab_white, image.at(612, 187), loose);
        try checks.claimLab("the arc ring has a hole", clear_lab, image.at(590, 200), loose);
        try checks.claim(
            "the arc's 3.0-radian sweep leaves its bottom open",
            @abs(image.at(590, 225)[0] - clear_lab[0]) < loose,
        );

        try checks.claimLab("filled curve interior is inked", lab_white, image.at(585, 245), loose);
        // The disc's lowest tessellated vertex sits at local y=19.975, so row
        // 254 is the last solid row and row 255 the first clear one.
        try checks.claimLab("filled curve just inside the arc", lab_white, image.at(585, 253), loose);
        try checks.claimLab("filled curve just past the arc", clear_lab, image.at(585, 255), loose);
        try checks.claimLab("filled curve corner is clear", clear_lab, image.at(576, 236), loose);

        // The disc's apex, where the CURVE itself cuts a pixel. Its topmost
        // tessellated vertex is local y=0.135, so row 235 lies inside the disc
        // across part of its width and outside it across the rest, and the
        // shader's 4x4 winding supersample lands 12 of that pixel's 16 samples
        // inside. The value is the same single straight-alpha blend the opacity
        // panel derives, at 0.75.
        try checks.claimLab(
            "the disc's apex is antialiased, not a hard step",
            blend(clear_lab, lab_white, 0.75),
            image.at(585, 235),
            tight,
        );
        try checks.claimLab("above the disc's apex is clear", clear_lab, image.at(585, 234), tight);
    }

    /// P(0,2). Four identical white rects differing only in primitive opacity.
    /// The blend is one straight-alpha pass over the clear, so each lightness is
    /// `0.2 + 0.8 * opacity` to the last decimal.
    fn opacity(checks: *Checks, image: Image) !void {
        const ladder = [_]struct { x: i32, alpha: f32, label: []const u8 }{
            .{ .x = 37, .alpha = 0.25, .label = "opacity 0.25 blends 25% white" },
            .{ .x = 77, .alpha = 0.50, .label = "opacity 0.50 blends 50% white" },
            .{ .x = 117, .alpha = 0.75, .label = "opacity 0.75 blends 75% white" },
            .{ .x = 157, .alpha = 1.00, .label = "opacity 1.00 is authored white" },
        };
        var previous = clear_lab[0] - 1;
        inline for (ladder) |step| {
            const expected = blend(clear_lab, lab_white, step.alpha);
            try checks.claimLab(step.label, expected, image.at(step.x, 340), tight);
            try checks.claim(
                "the opacity ladder rises monotonically",
                image.at(step.x, 340)[0] > previous,
            );
            previous = image.at(step.x, 340)[0];
        }
        try checks.claimLab(
            "opacity applies to the box's own edge",
            blend(clear_lab, lab_white, 0.5),
            image.at(77, 305),
            tight,
        );
        try checks.claimLab("the gutter between rungs is clear", clear_lab, image.at(57, 340), tight);
        try checks.claimLab("above the ladder is clear", clear_lab, image.at(37, 288), tight);
    }

    /// P(1,2). The vacated box of a translated paint, and a quarter turn whose
    /// image shares no pixel with the box it was authored on.
    fn transforms(checks: *Checks, image: Image) !void {
        try checks.claimLab("untransformed box is inked", lab_white, image.at(275, 291), tight);
        try checks.claimLab("untransformed box reaches its far corner", lab_white, image.at(315, 300), tight);
        try checks.claimLab("the translated box is inked", lab_white, image.at(365, 369), tight);
        try checks.claimLab("the translated box reaches its far corner", lab_white, image.at(405, 378), tight);
        try checks.claimLab("the translated box's original box is empty", clear_lab, image.at(275, 329), tight);
        try checks.claimLab("the vacated box is empty at its edge too", clear_lab, image.at(300, 320), tight);
        try checks.claimLab("the landed box's untransformed y stays empty", clear_lab, image.at(365, 329), tight);
        try checks.claim(
            "the transform moves geometry without resizing it",
            @abs(image.at(275, 291)[0] - image.at(365, 369)[0]) < tight,
        );

        try checks.claimLab("rotated square centre is inked", lab_white, image.at(347, 329), tight);
        try checks.claimLab("rotated square low corner is inked", lab_white, image.at(347, 338), tight);
        try checks.claimLab("above the rotated square is clear", clear_lab, image.at(347, 312), tight);
        try checks.claimLab("the rotated square's original box is empty", clear_lab, image.at(373, 329), tight);
        try checks.claimLab("left of the rotated square is clear", clear_lab, image.at(332, 329), tight);
        try checks.claimLab("below the rotated square is clear", clear_lab, image.at(347, 345), tight);
        try checks.claim(
            "the quarter turn moved the square to a different box",
            @abs(image.at(347, 329)[0] - image.at(373, 329)[0]) > 0.5,
        );
    }

    /// P(2,2) and P(0,3). The canvas clip is 620x540 while the target is
    /// 640x560, so the clip's own boundary is readable in target pixels.
    fn clip(checks: *Checks, image: Image) !void {
        try checks.claimLab("left of the overhanging rect is clear", clear_lab, image.at(595, 320), tight);
        try checks.claimLab("the overhanging rect is inked inside the clip", lab_white, image.at(610, 320), tight);
        try checks.claimLab("the overhanging rect is CUT at the clip", clear_lab, image.at(622, 320), tight);
        try checks.claimLab("the overhanging rect stays cut at the edge", clear_lab, image.at(635, 320), tight);
        try checks.claimLab("above the overhanging rect is clear", clear_lab, image.at(610, 285), tight);

        try checks.claimLab("above the bottom rect is clear", clear_lab, image.at(215, 490), tight);
        try checks.claimLab("the bottom rect is inked inside the clip", lab_white, image.at(215, 530), tight);
        try checks.claimLab("the bottom rect is CUT at the clip", clear_lab, image.at(215, 545), tight);
        try checks.claimLab("the bottom rect stays cut at the edge", clear_lab, image.at(215, 555), tight);
    }

    /// P(0,3) and P(1,3). An outset shadow darkens the clear where nothing is
    /// painted; an inset shadow darkens the box's own interior without reaching
    /// its centre. The outset box's radii read {top-left 0, top-right 30,
    /// bottom-right 0, bottom-left 30}, so its square corner and its cut corner
    /// are opposite ends of the same box — one claim each.
    fn shadows(checks: *Checks, image: Image) !void {
        try checks.claimLab("the shadowed box paints its own fill", lab_gray_90, image.at(40, 425), tight);
        // The top-left corner is square (radius 0) and 12 units clear of the
        // shadow shape's own edge, so what reads here is the authored gray and
        // nothing else. The bottom-left corner is the 30-unit one.
        try checks.claimLab("the square corner keeps its fill", lab_gray_90, image.at(31, 421), tight);
        try checks.claimLab("beyond the shadow is untouched clear", clear_lab, image.at(20, 440), tight);
        try checks.claimLab("above the shadow is untouched clear", clear_lab, image.at(80, 410), tight);

        // The 30-unit bottom-left corner is cut away, so the shadow shows
        // through where the fill would have been: 5 units outside the fill's
        // corner arc and 5 units inside the shadow shape.
        const cut = image.at(51, 479);
        try checks.claim(
            "the 30-unit corner is cut and the shadow shows through",
            cut[0] < 0.12 and cut[0] < lab_gray_90[0] - 0.5,
        );
        // Nine columns further out along the SAME row the feather has faded to
        // a third of its coverage: darker than the clear, nowhere near black.
        const penumbra = image.at(42, 479);
        try checks.claim(
            "the blurred shadow edge is between clear and black",
            penumbra[0] < clear_lab[0] - 0.02 and penumbra[0] > 0.03,
        );
        try checks.claim(
            "the shadow is a gradient, not a hard silhouette",
            penumbra[0] > cut[0] + 0.05,
        );
        // The offset moves the penumbra: 2 units past the bottom-right corner
        // is darkened, the mirrored 2 units before the top-left corner is not.
        try checks.claim(
            "the shadow reaches past the box on the offset side",
            image.at(132, 482)[0] < clear_lab[0] - 0.02,
        );
        try checks.near(
            "the shadow does not reach the un-offset side",
            "L",
            clear_lab[0],
            image.at(28, 418)[0],
            loose,
        );

        // Inset: the box stays white at its centre and darkens at its edge.
        try checks.claimLab("the inset box centre is untouched white", lab_white, image.at(300, 455), tight);
        try checks.claimLab("a third of the way in is untouched white", lab_white, image.at(300, 445), tight);
        const edge = image.at(250, 425);
        try checks.claim(
            "the inset shadow darkens the box's own edge",
            edge[0] < lab_white[0] - 0.25 and edge[0] > 0.30,
        );
        try checks.claim(
            "the inset shadow is darker at the edge than at the centre",
            edge[0] < image.at(300, 455)[0] - 0.25,
        );
        try checks.claimLab("the inset shadow does not leak outside", clear_lab, image.at(370, 425), tight);
    }

    /// P(2,3). Checker parity and stripe phase are pure index arithmetic in the
    /// shader, so the probes are exact cell colours.
    fn patterns(checks: *Checks, image: Image) !void {
        try checks.claimLab("checker cell (4,2) takes the first colour", lab_white, image.at(485, 440), tight);
        try checks.claimLab("checker cell (5,2) takes the second colour", lab_red, image.at(495, 440), tight);
        try checks.claimLab("checker cell (4,3) takes the second colour", lab_red, image.at(485, 450), tight);
        try checks.claimLab("checker cell (5,3) takes the first colour", lab_white, image.at(495, 450), tight);
        try checks.claim(
            "checker parity flips on both axes",
            @abs(image.at(485, 440)[0] - image.at(495, 450)[0]) < tight and
                @abs(image.at(495, 440)[0] - image.at(485, 450)[0]) < tight and
                @abs(image.at(485, 440)[0] - image.at(495, 440)[0]) > 0.10,
        );

        try checks.claimLab("stripe cell.x=4 takes the first colour", lab_white, image.at(575, 440), tight);
        try checks.claimLab("stripe cell.x=5 takes the second colour", lab_green, image.at(585, 440), tight);
        try checks.claimLab("stripes are constant down a column", image.at(575, 440), image.at(575, 450), tight);
        try checks.claim(
            "stripes vary along a row",
            @abs(image.at(575, 440)[0] - image.at(585, 440)[0]) > 0.10,
        );
        try checks.claim(
            "checkers vary down a column, which stripes do not",
            @abs(image.at(485, 440)[0] - image.at(485, 450)[0]) > 0.10 and
                @abs(image.at(575, 440)[0] - image.at(575, 450)[0]) < tight,
        );
        try checks.claimLab("the panel gutter is clear", clear_lab, image.at(525, 440), tight);
    }

    /// P(2,3). Four sides, four colours, three styles, on one box.
    fn borders(checks: *Checks, image: Image) !void {
        try checks.claimLab("solid top border is the top colour", lab_white, image.at(525, 477), tight);
        try checks.claimLab("solid left border is the left colour", lab_blue, image.at(442, 490), tight);
        // Dashed right: `along = point.y`, period 16, on while
        // frac(along/16)*16 < 9.6.
        try checks.claimLab("dashed right border: an ON sample", lab_red, image.at(608, 483), tight);
        // A dash or dot gap leaves the band transparent, and the fill is inset
        // by the border widths, so a gap shows the clear behind the box.
        try checks.claimLab("dashed right border: a GAP sample", clear_lab, image.at(608, 487), tight);
        // Dotted bottom: a dot lands only where |frac(x/16)*16 - width| < radius.
        const dot = image.at(525, 508);
        try checks.claim("dotted bottom border: a DOT sample is green", dot[0] > 0.6 and dot[1] < -0.10);
        try checks.claimLab("dotted bottom border: a GAP sample", clear_lab, image.at(529, 508), tight);
        try checks.claimLab("the border field is the authored fill", lab_gray_15, image.at(525, 493), tight);
        // Every side's colour must read as a different colour from the field it
        // sits on, and the two modulated sides must read as different colours
        // from their own gaps. Measured in Oklab, not in L: sRGB blue is only
        // 0.18 lighter than this field, so an L-only threshold calls the left
        // border the same colour as the panel it is drawn on.
        try checks.claim(
            "the dashed and dotted sides modulate while the solid ones do not",
            labDistance(image.at(525, 477), lab_gray_15) > 0.3 and
                labDistance(image.at(442, 490), lab_gray_15) > 0.3 and
                labDistance(image.at(608, 483), image.at(608, 487)) > 0.3 and
                labDistance(image.at(525, 508), image.at(529, 508)) > 0.3,
        );
    }

    /// P(1,2)-gap. Stops at 0.25 and 0.75 of the box's own projection, along
    /// +x, so the shader's `t = (position - z) / (w - z)` clamps to 0 across
    /// the left quarter and to 1 across the last quarter. A pair of 0/1 stops
    /// ramps at BOTH of the flat samples, so holding each one to its stop
    /// colour at the `tight` tolerance is what makes this a stop-position claim
    /// rather than another ramp claim.
    fn stopPositions(checks: *Checks, image: Image) !void {
        // For a cardinal +x axis the shader collapses to the box-local
        // coordinate over the box's own width. The sample is the pixel CENTRE,
        // so the authored column and the drawn column differ by half a unit —
        // `stopPosition` is what derives the value each probe really reads.
        const first_flat = image.at(stop_probe_first_x, stop_probe_mid_y);
        const mid = image.at(stop_probe_mid_x, stop_probe_mid_y);
        const beyond = image.at(stop_probe_beyond_x, stop_probe_mid_y);
        try checks.claimLab(
            "0.25 stop: the ramp's left quarter is exactly the FIRST stop, not a lerp of it",
            lab_red,
            first_flat,
            tight,
        );
        try checks.claimLab(
            "0.75 stop: past the second stop the ramp is exactly the SECOND stop",
            lab_blue,
            beyond,
            tight,
        );
        try checks.claimLab(
            "0.25/0.75 stops: the ramp's midpoint is the halfway lerp between them",
            lerpLab(lab_red, lab_blue, (stopPosition(stop_probe_mid_x) - 0.25) / 0.5),
            mid,
            tight,
        );
        try checks.claimLab(
            "the stop ramp is constant down its own column",
            image.at(stop_probe_mid_x, stop_probe_top_y),
            image.at(stop_probe_mid_x, stop_probe_bottom_y),
            0.0001,
        );
        // The discriminators, stated against what a pair of 0/1 stops would
        // paint at the very same pixels: 0.065 and 0.093 of Oklab distance,
        // against the `tight` tolerance that admits a plain end-to-end ramp.
        try checks.claim(
            "the flat first quarter is not what a 0/1-stop ramp would paint there",
            labDistance(first_flat, lab_red) < tight and
                labDistance(first_flat, lerpLab(lab_red, lab_blue, stopPosition(stop_probe_first_x))) > 0.05,
        );
        try checks.claim(
            "the flat last quarter is not what a 0/1-stop ramp would paint there",
            labDistance(beyond, lab_blue) < tight and
                labDistance(beyond, lerpLab(lab_red, lab_blue, stopPosition(stop_probe_beyond_x))) > 0.05,
        );
        // And the two stops bracket a ramp: the middle half really moves.
        try checks.claim(
            "the stops bracket a ramp, not a step",
            labDistance(mid, first_flat) > 0.10 and labDistance(mid, beyond) > 0.10,
        );
    }

    /// P(0,3). ONE rect carrying TWO outset shadows with opposite offsets, so
    /// each lobe falls outside the fill and outside the other shadow's own
    /// shape. The lobes are different COLOURS, so a claim about their lightness
    /// alone would be satisfied by one shadow reaching everywhere: they are
    /// separated in Oklab distance instead.
    fn shadowArrays(checks: *Checks, image: Image) !void {
        try checks.claimLab(
            "the two-shadow box paints its own fill",
            lab_gray_90,
            image.at(two_shadow_fill_x, two_shadow_fill_y),
            tight,
        );
        // Each sample is inside its own shadow's quad, outside the fill and
        // outside the other shadow's quad: the comptime block below proves all
        // three, so neither lobe can be reached by the wrong shadow.
        const warm = image.at(two_shadow_warm_x, two_shadow_warm_y);
        const cool = image.at(two_shadow_cool_x, two_shadow_cool_y);
        try checks.claim(
            "the FIRST shadow reaches its own side of the box",
            labDistance(warm, clear_lab) > 0.10,
        );
        try checks.claim(
            "the SECOND shadow reaches its own, opposite side of the box",
            labDistance(cool, clear_lab) > 0.10,
        );
        // 0.32 of Oklab distance apart with both lobes at full coverage, and a
        // warm one on the positive a side and a cool one on the negative b
        // side: one shadow reaching both sides would put BOTH of those on the
        // same pixel.
        try checks.claim(
            "the two lobes are the two authored shadows, not one shadow reaching both sides",
            labDistance(warm, cool) > 0.25 and warm[1] > 0.0 and cool[2] < 0.0,
        );
        try checks.claimLab(
            "beyond both shadows the clear is untouched",
            clear_lab,
            image.at(two_shadow_bare_x, two_shadow_bare_y),
            tight,
        );
    }

    /// P(0,3). A palette INDEX and its sRGB twin, side by side. The twin pair
    /// is the claim that matters: two panels authored from two different
    /// declarations can only agree if the index resolved to the very triple the
    /// other one names. Index 0 is held to the PUBLISHED red landmark, so no
    /// probe here is compared against a value the converter produced for it.
    fn paletteSwatches(checks: *Checks, image: Image) !void {
        const index0 = image.at(palette_probe_index0_x, palette_probe_index0_y);
        const index1 = image.at(palette_probe_index1_x, palette_probe_index0_y);
        const srgb = image.at(palette_probe_srgb_x, palette_probe_index0_y);
        const gutter = image.at(palette_probe_gutter_x, palette_probe_index0_y);
        try checks.claimLab(
            "palette index 0 paints the published red landmark",
            lab_red,
            index0,
            tight,
        );
        const authored = labTriplet(frame.srgbToOklab(paletteRgb(specimen_palette[1])));
        try checks.claimLab(
            "palette index 1 paints the colour the table names",
            authored,
            index1,
            tight,
        );
        try checks.claimLab(
            "the sRGB twin paints the very same colour as palette index 1",
            index1,
            srgb,
            tight,
        );
        try checks.claim(
            "a palette index and its sRGB declaration are distinguishable from an unrelated colour",
            labDistance(index1, lab_red) > 0.30 and labDistance(srgb, lab_blue) > 0.30,
        );
        try checks.claimLab("the gutter between the swatches is the clear", clear_lab, gutter, tight);
    }

    /// P(1,2), the INPUT half. The transform target's single record fills the
    /// element's own content box and is translated clear of it, so the two
    /// boxes cannot be confused: the element's hit box is where layout put it
    /// and the ink is one authored translation away. Both boxes are read out of
    /// the COMMITTED tree rather than out of the authored constants, so these
    /// claims name the geometry this frame actually produced.
    fn transformHit(
        checks: *Checks,
        tree: *const nogui.widget.WidgetTree,
        target: nogui.FrameNodeId,
        image: Image,
    ) !void {
        const box = nogui.visualContentRect(tree, target);
        try checks.report.emit("transform target box: ({d:.1},{d:.1}) {d:.1}x{d:.1}\n", .{
            box.x,
            box.y,
            box.w,
            box.h,
        });
        try checks.claim(
            "the transform target committed a box its own authored translation clears entirely",
            box.w > 0 and box.h > 0 and transform_offset_x >= box.w,
        );
        const authored: [2]f32 = .{ box.x + box.w / 2, box.y + box.h / 2 };
        const moved: [2]f32 = .{ authored[0] + transform_offset_x, authored[1] };
        const authored_x: i32 = @intFromFloat(@floor(authored[0]));
        const row_y: i32 = @intFromFloat(@floor(authored[1]));
        const moved_x: i32 = @intFromFloat(@floor(moved[0]));

        try checks.claim(
            "input at the AUTHORED box routes to the transform target",
            hitIs(tree, authored, target),
        );
        try checks.claim(
            "input at the box the ink moved to does NOT route to the transform target",
            !hitIs(tree, moved, target),
        );
        try checks.claimLab(
            "the AUTHORED box carries no ink: the transform moved the paint out of it",
            clear_lab,
            image.at(authored_x, row_y),
            tight,
        );
        try checks.claimLab(
            "the ink is at the TRANSFORMED box, exactly one authored translation away",
            lab_white,
            image.at(moved_x, row_y),
            tight,
        );
        try checks.claim(
            "the hit box stayed at the authored box while the ink left it",
            hitIs(tree, authored, target) and !hitIs(tree, moved, target) and
                labDistance(image.at(authored_x, row_y), image.at(moved_x, row_y)) > 0.5,
        );
    }

    /// What the native window actually became. Every probe in this file is
    /// authored in the specimen's own units and read in device pixels, so a
    /// window that came up at another logical size or another scale would be
    /// measuring the wrong pixel — and a probe read at a scale it was not
    /// authored for is not a failed claim, it is a claim about a different
    /// picture. Returns whether the run may go on to make any of them.
    fn observedWindow(checks: *Checks, managed: *host.ManagedWindow) !bool {
        const observed = managed.observed;
        try checks.report.emit(
            "window: logical={d}x{d} device={d}x{d} visible={}\n",
            .{
                observed.size.width,
                observed.size.height,
                observed.pixels.width,
                observed.pixels.height,
                observed.visible,
            },
        );
        const logical_ok = observed.size.width == @as(u32, @intFromFloat(window_w)) and
            observed.size.height == @as(u32, @intFromFloat(window_h));
        try checks.claim("the native window took the authored 640x560 logical size", logical_ok);
        const pixels_ok = observed.pixels.width == device_extent.width and
            observed.pixels.height == device_extent.height;
        try checks.claim("its pixel extent is the authored 640x560 device extent", pixels_ok);
        return logical_ok and pixels_ok;
    }

    /// The image the swapchain actually handed out. The device extent the frame
    /// asked for is a REQUEST — the driver clamps the swapchain to the surface
    /// capabilities, and both passes size themselves to the image the acquire
    /// returned rather than to the request — so this is measured, never assumed.
    fn presentedExtent(checks: *Checks, extent: noapi.Extent2D) !bool {
        const holds = extent.width == device_extent.width and extent.height == device_extent.height;
        try checks.claim(
            "the acquired swapchain image is the authored device extent, one device pixel per logical unit",
            holds,
        );
        return holds;
    }

    /// That one frame's records describe the revision they were authored for.
    /// BOTH frames call this with their own revision, so "the second frame
    /// carries the change" is a claim about the CURRENT records read exactly
    /// the way the first frame's were, and not a second set of ad-hoc
    /// assertions that could pass while the records said otherwise.
    ///
    /// Three records and no others: the corner panel the revision selects, the
    /// even-odd ring, and the dashed run. The ring and the run are the two this
    /// specimen borrows arena memory for — a duplicated command list and a
    /// duplicated dash array — so reading them here is what makes "the
    /// referenced path data is intact" a statement about data.
    fn authoredRecords(
        checks: *Checks,
        revision: Revision,
        records: []const paint.PaintRecord,
        slots: AuthoredRecords,
    ) !void {
        const panel = authoredCorner(revision);
        const corner = records[slots.corner];
        const corner_shape = switch (corner.shape) {
            .rect => |shape| shape,
            else => return error.MissingAuthoredCornerRecord,
        };
        try checks.claim(
            "the corner record carries the authored bounds",
            sameBox(corner.bounds, panel.bounds),
        );
        try checks.claim(
            "the corner record carries the authored corner radii",
            std.meta.eql(corner_shape.radii, panel.radii),
        );
        const corner_fill = switch (corner_shape.fill orelse return error.MissingAuthoredCornerFill) {
            .solid => |lab| lab,
            else => return error.MissingAuthoredCornerFill,
        };
        try checks.claimLab(
            "the corner record carries the authored fill",
            cornerLandmark(revision),
            oklabTriplet(corner_fill),
            tight,
        );

        const ring = switch (records[slots.ring].shape) {
            .path => |shape| shape,
            else => return error.MissingAuthoredRingRecord,
        };
        try checks.claim(
            "the even-odd ring record carries the authored outline, command for command",
            commandsAgree(ring.path.commands, &ring_commands),
        );
        try checks.claim("and the authored even-odd rule", ring.fill_rule == .even_odd);

        const dashed = switch (records[slots.dashed].shape) {
            .path => |shape| shape,
            else => return error.MissingAuthoredDashRecord,
        };
        const stroke = dashed.stroke orelse return error.MissingAuthoredDashStroke;
        try checks.claim(
            "the dashed run record carries the authored 20/20 dash array",
            dashesAgree(stroke.dash, &dash_20),
        );
        try checks.claim("and the authored zero dash phase", stroke.phase == 0);
    }

    /// The corner panel as the PRESENTED pixels show it: the authored fill
    /// inside the panel, and the far end of the authored box. Under `.first`
    /// the far end is still filled; under `.changed` the panel is half as wide
    /// and the same authored coordinate reads the bare clear. Both frames are
    /// read at those two coordinates, so the pair is a vacating pair rather
    /// than two unrelated samples.
    fn cornerPixels(checks: *Checks, image: Image, revision: Revision) !void {
        try checks.claimLab(
            "the presented corner interior carries the authored fill",
            cornerLandmark(revision),
            image.at(corner_interior_x, corner_interior_y),
            tight,
        );
        const vacated_label = switch (revision) {
            .first => "the presented corner right end is still the authored fill",
            .changed => "the presented corner right end is the bare clear: the panel no longer covers it",
        };
        const vacated_want = switch (revision) {
            .first => lab_white,
            .changed => clear_lab,
        };
        try checks.claimLab(
            vacated_label,
            vacated_want,
            image.at(corner_vacated_x, corner_vacated_y),
            tight,
        );
    }

    const Lifetime = struct {
        /// Taken from the first frame while the first frame was the committed
        /// tree.
        copy: PaintCopy,
        /// That same frame's own records, read again after the second frame has
        /// committed — out of an arena the App has since built a different
        /// frame beside.
        old: []const paint.PaintRecord,
        new: []const paint.PaintRecord,
        old_slots: AuthoredRecords,
        new_slots: AuthoredRecords,
    };

    /// The old/current frame paint lifetime proof.
    ///
    /// The first claim is NOT "the copy survived": it is that the first
    /// frame's own records — read now, out of the arena this run never owned —
    /// still read element for element as they did when the copy was taken. The
    /// rest is the other half: the current records describe a DIFFERENT
    /// authored frame, they occupy the same slot, and they disagree with the
    /// old ones in that one record only.
    fn lifetime(checks: *Checks, evidence: Lifetime) !void {
        try checks.claim(
            "the first frame's records still read exactly as they were captured: " ++
                "path commands, shadow arrays and dash arrays included",
            evidence.copy.matches(evidence.old),
        );
        try checks.count(
            "records the second frame's revision changed",
            @intCast(evidence.copy.disagreements(evidence.new)),
            1,
            1,
        );
        try checks.claim(
            "the corner panel occupies the same record slot in both frames",
            evidence.old_slots.corner == evidence.new_slots.corner,
        );

        // Read from the frame's own records, not from the copy, so every line
        // below is a statement about the arena this run never owned.
        const old_corner = evidence.old[evidence.old_slots.corner];
        const old_shape = switch (old_corner.shape) {
            .rect => |shape| shape,
            else => return error.MissingAuthoredCornerRecord,
        };
        try checks.claim(
            "the old corner record still carries frame 1's authored bounds",
            sameBox(old_corner.bounds, corner_first.bounds),
        );
        try checks.claim(
            "the old corner record still carries frame 1's authored corner radii",
            std.meta.eql(old_shape.radii, corner_first.radii),
        );
        const old_fill = switch (old_shape.fill orelse return error.MissingAuthoredCornerFill) {
            .solid => |lab| lab,
            else => return error.MissingAuthoredCornerFill,
        };
        try checks.claimLab(
            "the old corner record still carries frame 1's authored white, not the second frame's red",
            lab_white,
            oklabTriplet(old_fill),
            tight,
        );
        const old_ring = switch (evidence.old[evidence.old_slots.ring].shape) {
            .path => |shape| shape,
            else => return error.MissingAuthoredRingRecord,
        };
        try checks.claim(
            "the old ring record still carries the authored outline out of the frame arena",
            commandsAgree(old_ring.path.commands, &ring_commands),
        );
        const old_dashed = switch (evidence.old[evidence.old_slots.dashed].shape) {
            .path => |shape| shape,
            else => return error.MissingAuthoredDashRecord,
        };
        const old_stroke = old_dashed.stroke orelse return error.MissingAuthoredDashStroke;
        try checks.claim(
            "the old dashed run still carries the authored dash array out of the frame arena",
            dashesAgree(old_stroke.dash, &dash_20),
        );

        // And the current records are the second frame, not the first.
        try checks.claim(
            "the current corner record is not the first frame's record",
            !recordAgrees(
                evidence.old[evidence.old_slots.corner],
                evidence.new[evidence.new_slots.corner],
            ),
        );
    }
};

/// Whether an authored box lies wholly inside the specimen's own canvas box.
/// A panel outside it would be clipped away before a probe could read it.
fn insideCanvas(box: Rect) bool {
    return box.x >= 0 and box.y >= 0 and
        box.x + box.w <= canvas_w and box.y + box.h <= canvas_h;
}

/// Whether two authored boxes share any area. Touching edges do not count: a
/// probe one pixel inside a panel is not on its neighbour.
fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// Whether a device pixel falls inside an authored box.
fn containsPoint(box: Rect, x: i32, y: i32) bool {
    const px: f32 = @floatFromInt(x);
    const py: f32 = @floatFromInt(y);
    return px >= box.x and px < box.x + box.w and py >= box.y and py < box.y + box.h;
}

comptime {
    // The clip probes read target pixels OUTSIDE the canvas. If the target ever
    // shrank to the canvas size, that whole panel would silently stop proving
    // anything, so the margin is a compile-time invariant.
    std.debug.assert(device_extent.width > @as(u32, @intFromFloat(canvas_w)));
    std.debug.assert(device_extent.height > @as(u32, @intFromFloat(canvas_h)));
    std.debug.assert(window_w == @as(f32, @floatFromInt(device_extent.width)));
    std.debug.assert(window_h == @as(f32, @floatFromInt(device_extent.height)));
    std.debug.assert(@as(f32, authored_clear.l) == clear_lab[0]);
    std.debug.assert(@as(f32, authored_clear.a) == clear_lab[1]);
    std.debug.assert(@as(f32, authored_clear.b) == clear_lab[2]);

    // The two authored corner panels share a top-left corner on purpose: the
    // vacated probe then reads real vacated geometry rather than a panel that
    // moved somewhere else. And the interior probe has to sit inside BOTH of
    // them, while the vacated probe sits inside `.first`'s and outside
    // `.changed`'s. Without these, the two pixel claims about the revision
    // would be measuring an edge or a neighbouring panel.
    const interior = .{
        .x = @as(f32, @floatFromInt(corner_interior_x)),
        .y = @as(f32, @floatFromInt(corner_interior_y)),
    };
    const vacated = .{ .x = @as(f32, @floatFromInt(corner_vacated_x)), .y = @as(f32, @floatFromInt(corner_vacated_y)) };
    std.debug.assert(interior.x > corner_changed.bounds.x);
    std.debug.assert(interior.x < corner_changed.bounds.x + corner_changed.bounds.w);
    std.debug.assert(interior.y > corner_changed.bounds.y);
    std.debug.assert(interior.y < corner_changed.bounds.y + corner_changed.bounds.h);
    std.debug.assert(interior.x < corner_first.bounds.x + corner_first.bounds.w);
    std.debug.assert(interior.y < corner_first.bounds.y + corner_first.bounds.h);
    std.debug.assert(vacated.x > corner_changed.bounds.x + corner_changed.bounds.w);
    std.debug.assert(vacated.x < corner_first.bounds.x + corner_first.bounds.w);
    std.debug.assert(vacated.y > corner_changed.bounds.y + corner_changed.bounds.h);
    std.debug.assert(vacated.y < corner_first.bounds.y + corner_first.bounds.h);
    // `.changed` must not clamp its own corner radii against a shorter edge,
    // or the authored radii and the drawn ones would differ.
    const smallest = @min(corner_changed.bounds.w, corner_changed.bounds.h) / 2;
    for (corner_changed.radii) |radius| std.debug.assert(radius <= smallest);
    // The ring and the dashed run are looked up by the exact boxes the paint
    // hook passes, so those two constants and the authored paint are one value
    // rather than two that can drift.
    std.debug.assert(std.meta.eql(ring_bounds, r(30, 160, 80, 80)));
    std.debug.assert(std.meta.eql(dashed_bounds, r(240, 212, 160, 6)));
    // The two revisions must differ in all three facts the lifetime proof
    // tells them apart by — bounds, radii and colour — or "the second frame
    // painted something else" would be satisfiable by a frame that did not.
    std.debug.assert(!std.meta.eql(corner_first.bounds, corner_changed.bounds));
    std.debug.assert(!std.meta.eql(corner_first.radii, corner_changed.radii));
    std.debug.assert(!std.meta.eql(corner_first.color, corner_changed.color));

    // ── the panels added beside the original grid ──
    // Each lies inside the specimen's own box, none of them touches another,
    // and every probe point sits inside the panel it reads. Without these a
    // later edit that moved a panel would quietly turn a pixel claim into a
    // claim about a neighbour, and every probe would still "pass".
    for ([_]Rect{
        stop_bounds,
        palette_index_bounds,
        palette_twin_bounds,
        palette_srgb_bounds,
        two_shadow_bounds,
    }) |box| std.debug.assert(insideCanvas(box));
    std.debug.assert(!overlaps(stop_bounds, palette_index_bounds));
    std.debug.assert(!overlaps(palette_index_bounds, palette_twin_bounds));
    std.debug.assert(!overlaps(palette_twin_bounds, palette_srgb_bounds));
    std.debug.assert(!overlaps(two_shadow_bounds, palette_index_bounds));
    std.debug.assert(!overlaps(two_shadow_bounds, palette_srgb_bounds));
    std.debug.assert(containsPoint(palette_index_bounds, palette_probe_index0_x, palette_probe_index0_y));
    std.debug.assert(containsPoint(palette_twin_bounds, palette_probe_index1_x, palette_probe_index0_y));
    std.debug.assert(containsPoint(palette_srgb_bounds, palette_probe_srgb_x, palette_probe_index0_y));
    // The gutter sample has to fall BETWEEN the first two swatches, or the
    // "clear between them" claim would be reading a swatch.
    std.debug.assert(palette_probe_gutter_x > palette_index_bounds.x + palette_index_bounds.w);
    std.debug.assert(palette_probe_gutter_x < palette_twin_bounds.x);

    // The stop ramp: three sample columns inside the box, and the two flat ends
    // only exist if the samples really are outside the stops.
    std.debug.assert(containsPoint(stop_bounds, stop_probe_first_x, stop_probe_mid_y));
    std.debug.assert(containsPoint(stop_bounds, stop_probe_mid_x, stop_probe_mid_y));
    std.debug.assert(containsPoint(stop_bounds, stop_probe_beyond_x, stop_probe_mid_y));
    std.debug.assert(containsPoint(stop_bounds, stop_probe_mid_x, stop_probe_top_y));
    std.debug.assert(containsPoint(stop_bounds, stop_probe_mid_x, stop_probe_bottom_y));
    std.debug.assert(stopPosition(stop_probe_first_x) < 0.25);
    std.debug.assert(stopPosition(stop_probe_beyond_x) > 0.75);
    std.debug.assert(stopPosition(stop_probe_mid_x) > 0.25 and stopPosition(stop_probe_mid_x) < 0.75);

    // The two-shadow box: each sample is inside its OWN shadow's quad, outside
    // the fill, and outside the other shadow's quad — so neither lobe can be
    // reached by the wrong shadow and neither is the fill's own edge. Both are
    // inside the specimen's clip, so neither is cut short at y=540.
    std.debug.assert(containsPoint(two_shadow_bounds, two_shadow_fill_x, two_shadow_fill_y));
    std.debug.assert(containsPoint(two_shadow_warm_lobe, two_shadow_warm_x, two_shadow_warm_y));
    std.debug.assert(!containsPoint(two_shadow_bounds, two_shadow_warm_x, two_shadow_warm_y));
    std.debug.assert(!containsPoint(two_shadow_cool_lobe, two_shadow_warm_x, two_shadow_warm_y));
    std.debug.assert(containsPoint(two_shadow_cool_lobe, two_shadow_cool_x, two_shadow_cool_y));
    std.debug.assert(!containsPoint(two_shadow_bounds, two_shadow_cool_x, two_shadow_cool_y));
    std.debug.assert(!containsPoint(two_shadow_warm_lobe, two_shadow_cool_x, two_shadow_cool_y));
    std.debug.assert(two_shadow_warm_y < @as(i32, @intFromFloat(canvas_h)));
    std.debug.assert(two_shadow_cool_y < @as(i32, @intFromFloat(canvas_h)));
    std.debug.assert(!containsPoint(two_shadow_warm_lobe, two_shadow_bare_x, two_shadow_bare_y));
    std.debug.assert(!containsPoint(two_shadow_cool_lobe, two_shadow_bare_x, two_shadow_bare_y));

    // ── the capacity arm ──
    // Per ELEMENT the flood stays inside the `PaintWriter`'s own limit, and the
    // frame total is what outgrows the material partition. Both halves have to
    // hold, or the arm would be measuring a boundary it never reached.
    std.debug.assert(flood_records_per_canvas < nogui.element.PaintWriter.max_records);
    std.debug.assert(flood_canvas_count * flood_records_per_canvas > frame.scene.frame_material_slots);
    std.debug.assert(flood_records_per_canvas == flood_columns * flood_rows);
    std.debug.assert(flood_w == @as(f32, @floatFromInt(flood_columns)) * flood_cell_w);
    std.debug.assert(flood_h == @as(f32, @floatFromInt(flood_rows)) * flood_cell_h);
    // Every flood cell is a real, non-empty rect: an empty one is skipped by
    // the lowering and would cost no material slot at all.
    std.debug.assert(flood_cell_w > 0 and flood_cell_h > 0);

    // ── the transform target ──
    // Its translation must carry the ink wholly out of its own hit box, or
    // "the hit box stayed behind" would be vacuous; the strip it is laid out in
    // must fit under the specimen, and the landed box must stay inside the
    // target, or the ink would be cut at the viewport edge instead.
    std.debug.assert(transform_offset_x >= transform_box.w);
    std.debug.assert(canvas_h + transform_box.h <= window_h);
    std.debug.assert(transform_box.x + transform_offset_x + transform_box.w <= window_w);
    // The hold loop advances by `hold_slice_ms`, so a zero slice would spin
    // forever on a run that asked to be held.
    std.debug.assert(hold_slice_ms > 0 and hold_slice_ms <= max_hold_ms);
}
