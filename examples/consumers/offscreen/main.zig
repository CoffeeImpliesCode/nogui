//! One actual App tree → shared scene → shaped text → GPU text → Oklab
//! readback, presented into a real window or into none. No demo module.
//!
//! Both pinned repo faces are registered once in the same `TextService` the
//! App's measure source and the scene text pass use, so the specimen shapes a
//! string once and paints exactly the runs the layout produced. Inter draws
//! the Latin and the composed accent; DejaVu is the per-grapheme fallback that
//! draws the Hebrew, so the right-to-left run is real ink. Every rect the
//! engine submits is checked against the measured run geometry, and the
//! read-back pixels are checked against the boxes those rects claimed. Nothing
//! here compares pixels against a stored image: the proof is spatial.
//!
//! The tree also declares its paragraph POLICY on ordinary labels: an exact
//! two-line clamp, a centred alignment, and start / middle / end truncation
//! under one explicit suffix. A second frame then commits different bytes
//! under a different clamp, and the first frame's published record and layout
//! are read back afterwards through the pointers that frame published.
//!
//! ONE specimen, TWO targets, and every audit between them is shared code —
//! plus ONE target-free arm that answers before any target exists:
//!
//!   * DEFAULT: `v7_frame.Offscreen`, a windowless GPU frame. No window, no
//!     surface, no swapchain, no present, and no host or SDL module linked at
//!     all — the build requests the `frame` product, so SDL is never fetched.
//!   * `--native`, on a `-Dnative=true` build: a REAL owned SDL window through
//!     the public `nogui_host.Application`, and `v7_frame.NativeFrame`
//!     presenting the SAME lowering, the SAME text engine, the SAME pinned
//!     faces and the SAME scene rects into that window's swapchain image — one
//!     Oklab pass, the Oklab→sRGB blit that pass is sampled by, then the
//!     present. The read-back comes out of the Oklab target those passes
//!     wrote, so every pixel the audits below measure is one the PRESENTED
//!     frame drew.
//!
//!   * `--empty-font-registry`: the CPU-only THIRD arm. The REAL App and the
//!     REAL tree are measured through a public `TextMeasurer` handed no face
//!     at all, and the first frame refuses by name instead of publishing a
//!     tree whose labels measured as nothing. The same App then takes the two
//!     pinned faces through `TextService.addFont` and publishes the ordinary
//!     caption with the geometry those faces really produce. It refuses to
//!     combine with `--native`, because it has no presented path to take.
//!
//! The presented path lays its frame out in the geometry the WINDOW reports.
//! Every oracle in this file indexes the read-back by the authored 640×640, so
//! a window that answers with another logical size, another device pixel size
//! or another pixel scale is REPORTED and refused rather than measured against
//! a target this run did not author.
const std = @import("std");
const nogui = @import("nogui");
const render = @import("v7_render");
const frame = @import("v7_frame");
const noapi = frame.noapi;
const fonts = @import("font_bytes");
/// This consumer's own build options. `-Dnative=true` compiles the presented
/// arm; the default build does not name a host type anywhere, so it links no
/// host module and no SDL.
const build_options = @import("consumer_options");
/// The public SDL platform host, and the SDL package itself for the one call
/// that makes a Vulkan surface. Both are `struct {}` without `-Dnative`, and
/// then nothing below is ever resolved against them.
const host = if (build_options.native) @import("nogui_host") else struct {};
const sdl3 = if (build_options.native) @import("sdl3") else struct {};

const text_api = nogui.text;
const SceneRect = render.SceneRect;
const scene = frame.scene;

/// The CPU measure seam the zero-face arm binds. `TextMeasurer` is the
/// canonical owner of a `TextService` and its scratch arena for a host with
/// no GPU, and it is the ONLY public way to hand an App a measured label
/// without a device: `v7_frame` exports the service types but not this
/// binder, so this consumer's build has to carry the `nogui_text` module.
const nogui_text = @import("nogui_text");

/// The offscreen target. It carries the App tree, the two shaped specimens
/// below it and the paragraph-policy labels the tree now declares, with the
/// clear band the tail check needs to the bottom.
const extent: noapi.Extent2D = .{ .width = 640, .height = 640 };
/// The engine's glyph raster margin at 1x (see TextEngine.setPixelScale).
const raster_margin: f32 = 2.0;
/// Half a device pixel: a run origin is snapped by `@round`.
const snap_slack: f32 = 0.51;
/// Two raster margins and one pixel of blend tolerance.
const bleed: f32 = 2 * raster_margin + 1;

const hebrew = "\xD7\xA9\xD7\x9C\xD7\x95\xD7\x9D"; // U+05E9 U+05DC U+05D5 U+05DD
const hebrew_first: u21 = 0x05d9; // U+05E9 SHIN, the run's first scalar
const combining = "e\xCC\x81"; // e + U+0301 COMBINING ACUTE ACCENT
const zwj_emoji = "\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA9"; // U+1F44D ZWJ U+1F44D
const wave: u21 = 0x1f44d; // U+1F44D WAVING SIGN, no pinned face carries it
/// Latin, right-to-left Hebrew, a combining mark and an emoji ZWJ sequence in
/// one paragraph. The emoji stays a visible notdef: no pinned face covers it,
/// and the policy must say so instead of dropping the cluster.
const mixed = "A " ++ hebrew ++ " " ++ combining ++ " " ++ zwj_emoji;

const paragraph = "nogui shapes text and paints it";
const styled_word = "paints";
const paragraph_line_height: f32 = 30;
const paragraph_wrap: f32 = 150;
const paragraph_size: f32 = 18;
const paragraph_bold: u16 = 700;

/// The size a node gets when it authors none. This consumer is the GPU host,
/// so its default is 14.
const host_default_size: f32 = 14;

/// The ORDINARY App-tree caption. One plain `ctx.label`, authored with a font
/// family, the fallback face the primary lacks, one inline styled range and an
/// explicit no-wrap policy: Latin for the primary face, Hebrew for the
/// fallback, a combining cluster, and a ZWJ emoji no face covers. The App
/// measures it through the canonical source and the scene paints it through
/// the canonical path, so what is checked below is the ORDINARY label
/// pipeline and not a specimen-only arm.
const caption_word = "nogui";
const caption = caption_word ++ " " ++ hebrew ++ " " ++ combining ++ " " ++ zwj_emoji;
const caption_size: f32 = 22;
const caption_bold: u16 = 700;

/// The caption's inline range: a bold, underlined, tinted first word. Every
/// other part of the caption is the plain label default. The pinned specimen
/// and the zero-face arm name this one array, so the frame the arm recovers
/// into publishes the SAME caption the default run measures.
const caption_range = [_]text_api.StyledRange{.{
    .range = .{ .start = 0, .end = caption_word.len },
    .override = .{
        .font_fields = .{ .weight = caption_bold },
        .background = .{ .color = .{ 0.16, 0.22, 0.34, 1 } },
        .underline = true,
        .foreground = .{ 0.96, 0.86, 0.42, 1 },
    },
}};

/// The plate the sliders below paint under their own captions. Every one of
/// them authors this solid as its OWN background, so the colour a slider
/// caption's glyphs sit on is one the App named rather than the render pass's
/// clear colour. `.fill` is PAINT: it is not the `.color` text authorship the
/// ordinary slider below must NOT carry, and it never reaches `TextInput`, so
/// it cannot stand in for the widget kind's own default foreground.
const slider_plate: [4]f32 = .{ 0.16, 0.17, 0.21, 1 };
/// What the sliders that DO author a foreground paint their captions in.
const slider_ink_color: [4]f32 = .{ 1, 1, 1, 1 };

/// The ORDINARY slider's caption. The slider carrying it authors a key, this
/// text, a live value, a valid range and a background, and NOTHING else: no
/// `.color`, no text option, and no `default_text` anywhere on its path. The
/// widget KIND's own default foreground is then the only layer that can give
/// this caption a request, which is exactly the layer every other text-bearing
/// kind already declares.
const slider_default_label = "Speaker output volume";
/// The bytes BOTH truncation sliders declare, so the bounded caption has an
/// uncapped twin of the same text to be read against. Deliberately free of
/// punctuation, so the only dots that can ever appear on that line are the
/// truncation suffix.
const slider_long_label = "Normalization output gain level";
/// The cap the bounded slider declares: wider than the suffix it has to end
/// with, and far narrower than the caption's natural width, so honouring the
/// declaration truncates and dropping it does not.
const slider_cap: f32 = 118;
/// The gap between the control's thumb and the column the caption's ink is
/// read from, and the slack a painted span is allowed against a measured edge.
const slider_slack: f32 = 3;
/// The bounded slider's own height. Its caption is far wider than the cap it
/// declares, so a flow that honours neither the cap nor the ellipsis policy
/// needs TWO lines to hold those bytes. The box is given room for both, so
/// that wrap stays inside the node instead of spilling into the gap below the
/// tree: what the scenario reports is the caption, not a misplaced row.
const slider_bounded_height: f32 = 48;

// ── Paragraph policy, authored through the same ordinary label seam ──
/// The family every policy label below names. The pinned registry resolves it
/// to the one Inter face the App, the scene and these audits all hold.
const policy_face: []const u8 = "InterVariable";

/// The bytes the TWO-LINE clamp label declares in the FIRST frame: three hard
/// lines, the middle one much the widest. A clamp that keeps two of them
/// really drops a painted line, and the two it keeps cannot share a width —
/// which is what makes the centring below a statement about the alignment
/// rather than about two boxes of equal size.
const clamp_text: []const u8 = "nogui clamps\nthis paragraph to exactly two lines\nand drops the rest";
/// The one line that lives only where the clamp throws the text away.
const clamp_dropped_line: []const u8 = "and drops the rest";
/// The bytes the SAME label declares one frame later, under a DIFFERENT
/// clamp, so the next frame's published record cannot be this frame's record.
const clamp_text_next: []const u8 = "nogui clamps\nthis paragraph to exactly three lines\nand drops the rest";
/// The width the clamp label wraps and centres in, in both frames.
const clamp_wrap: f32 = 320;
/// The exact clamp the label authors: two visible lines, never three.
const clamp_lines: usize = 2;
/// The exact clamp the SAME label authors one frame later.
const clamp_lines_next: usize = 3;
const clamp_line_height: f32 = 22;
const clamp_size: f32 = 16;

/// The bytes all THREE truncation labels declare, on purpose: only the policy
/// each one authors tells them apart, so a mode that painted the wrong end of
/// these bytes cannot pass as another mode's twin.
const truncation_text: []const u8 =
    "Pinned faces Inter and DejaVuSans shape every byte a paragraph names";
/// The EXPLICIT suffix every truncation label declares. These bytes are what
/// has to appear at the cut; nothing below is an implicit ellipsis.
const truncation_suffix: []const u8 = "~~";
/// The bound every truncation label declares: far narrower than these bytes
/// need at this size, so honouring it truncates and dropping it does not.
const truncation_width: f32 = 150;
const truncation_size: f32 = 16;
/// The three modes, in the order the tree declares them.
const truncation_modes = [_]text_api.TruncateMode{ .start, .middle, .end };

const Root = struct {
    /// The caption's own request. Both slices are copied into the frame arena
    /// when the label is authored, so they only have to outlive this call.
    fallback: []const text_api.FontHandle = &.{},
    ranges: []const text_api.StyledRange = &.{},

    /// The three sliders' live values. A slider node RETAINS this pointer
    /// across the current AND the previous frame tree, so the storage lives
    /// in the mounted root rather than in a frame scratch buffer. Every one
    /// sits at its own range minimum: the progress fill only paints left of
    /// the value's fraction, so at the minimum the control's chrome is the
    /// thumb alone and the column to the thumb's right carries nothing but
    /// the caption's glyphs.
    volume: f32 = 0,
    capped: f32 = 0,
    plain: f32 = 0,

    /// Which authored variant the clamp label publishes. The FIRST frame
    /// authors `clamp_text` under `clamp_lines`; a later frame authors
    /// different bytes under a different clamp, so the two frames' published
    /// paragraph records cannot be the same record and the previous frame's
    /// own record has something to stay unchanged against.
    clamp_frame: u8 = 0,

    pub fn draw(self: *Root, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.column(.{ .gap = 8 });
        defer ctx.pop();
        _ = try ctx.label(.{ .text = "External text: ffi 123" });
        _ = try ctx.label(.{
            .text = caption,
            .font_size = caption_size,
            .font_family = "InterVariable",
            .font_fallback = self.fallback,
            .text_ranges = self.ranges,
            .missing_glyph = .notdef,
            .paragraph = .{ .wrap = .no_wrap },
        });
        _ = try ctx.button(.{
            .key = .{ .static = "accept" },
            .label = "Windowless render",
            .on_click = clicked,
        });

        // ── Slider captions, through the same canonical text path ──
        // One row, so the three controls cost a single line of the target.
        // Each declares a DISTINCT range, which is what lets the audit name
        // a slider by its caption bytes plus its range: the bounded and the
        // uncapped slider declare the same text on purpose.
        {
            _ = try ctx.row(.{ .gap = 8 });
            defer ctx.pop();
            // ORDINARY. No `.color`, no text option, and no `default_text` above
            // it, so the widget kind's own default foreground is the only layer
            // that can give this caption a request.
            _ = try ctx.slider(.{
                .key = .{ .static = "volume" },
                .label = slider_default_label,
                .value = &self.volume,
                .min = 0,
                .max = 100,
                .fill = slider_plate,
            });
            // BOUNDED. The same long bytes at the same size, declared with a
            // truncation policy and a cap narrower than those bytes. It DOES
            // author `.color`, so its record is published either way: what the
            // declared `text_overflow` and `max_width` buy is the thing under
            // test, not the record.
            _ = try ctx.slider(.{
                .key = .{ .static = "gain-capped" },
                .label = slider_long_label,
                .value = &self.capped,
                .min = 0,
                .max = 100,
                .fill = slider_plate,
                .color = slider_ink_color,
                .text_overflow = .ellipsis,
                .max_width = slider_cap,
                .height = .{ .length = slider_bounded_height },
            });
            // PLAIN. The same bytes with no cap and no policy, so the bounded
            // caption has an uncapped twin of its own text to be read against.
            // Its box is given more width than those bytes need, so the twin
            // stays on one line with room to spare and the only thing that can
            // ever break it onto a second one is the layout itself.
            _ = try ctx.slider(.{
                .key = .{ .static = "gain-plain" },
                .label = slider_long_label,
                .value = &self.plain,
                .min = 0,
                .max = 200,
                .fill = slider_plate,
                .width = .{ .length = 240 },
                .color = slider_ink_color,
            });
        }

        // ── Paragraph policy, on the same ordinary label seam ──
        // Plain `ctx.label` calls: the same create path, the same canonical
        // measure, the same scene text pass and the same pinned faces every
        // caption above went through. Nothing here is a specimen-only arm.
        const first_frame = self.clamp_frame == 0;
        // The TWO-LINE clamp. A wrap width, a line height, a centred alignment
        // and an exact clamp of two lines over bytes that need three of them.
        _ = try ctx.label(.{
            .text = if (first_frame) clamp_text else clamp_text_next,
            .font_size = clamp_size,
            .font_family = policy_face,
            .paragraph = .{
                .wrap_width = clamp_wrap,
                .line_height = clamp_line_height,
                .alignment = .center,
                .max_lines = if (first_frame) clamp_lines else clamp_lines_next,
            },
        });
        // START, MIDDLE and END truncation. One set of bytes, one size and one
        // explicit suffix, three policies: only the mode tells them apart.
        for (truncation_modes) |mode| {
            _ = try ctx.label(.{
                .text = truncation_text,
                .font_size = truncation_size,
                .font_family = policy_face,
                .paragraph = .{
                    .wrap = .no_wrap,
                    .wrap_width = truncation_width,
                    .alignment = .start,
                    .truncate = .{ .mode = mode, .suffix = truncation_suffix },
                },
            });
        }
    }

    fn clicked(_: *Root) void {}
};

// ── The zero-face arm: a registry with no configured face ─────────────────

/// The widget's text box: its visual content rect minus
/// the SAME inset table the measure decoration applies, so the box and the ink
/// it holds cannot disagree about where the text starts.
fn textBox(
    tree: *const nogui.widget.WidgetTree,
    node: *const nogui.widget.WidgetNode,
) Area {
    const visual = nogui.visualContentRect(tree, node.id);
    const insets = nogui.widget.textInsets(node.kind);
    return .{
        .x = visual.x + insets.leading,
        .y = visual.y + insets.top,
        .w = @max(0, visual.w - insets.leading - insets.trailing),
        .h = @max(0, visual.h - insets.top - insets.bottom),
    };
}

fn findCaption(tree: *const nogui.widget.WidgetTree) ?*const nogui.widget.WidgetNode {
    for (tree.nodes.items) |*node| {
        switch (node.kind) {
            .label => |label| {
                if (std.mem.eql(u8, label.text, caption)) return node;
            },
            else => {},
        }
    }
    return null;
}

/// One frame refusal, checked by name. The `MeasureSource` callback carries no
/// sideband of its own — it answers with the provider's own error — so a
/// missing face is visible as exactly three things: that error, the tree the
/// App did NOT commit, and the shape cache the refusal left empty.
fn refuseFrame(probe: *Probe, name: []const u8, result: anyerror!nogui.FrameOutput) void {
    probe.checks += 1;
    if (result) |value| {
        if (value.json) |json| probe.gpa.free(json);
        probe.fail(name, "the App published a frame with no configured face");
    } else |actual| {
        if (actual == error.FontUnavailable) return;
        const detail = std.fmt.allocPrint(
            probe.gpa,
            "refused with {s}, not the refusal the registry names",
            .{@errorName(actual)},
        ) catch {
            probe.fail(name, "refused for a reason the registry does not name");
            return;
        };
        defer probe.gpa.free(detail);
        probe.fail(name, detail);
    }
}

/// What the recovered frame's own caption proved.
const RecoveredCaption = struct {
    /// The shape cache after the recovered frame shaped real runs.
    shapes: u64 = 0,
    /// The ink the caption's own runs need at the size the tree asked for.
    ink: f32 = 0,
    /// The box the App laid that caption out in.
    box: Area = .{},
};

/// The recovered frame's caption, read off the tree the App published and laid
/// out through the SAME service and the SAME node request the paint path uses.
///
/// Nothing here retypes the caption: the request is the one the TREE resolved,
/// and the expectations are the faces, the shaped glyph ids, the advances and
/// the styles that request produced, plus the box the App laid them in.
fn auditRecoveredCaption(
    probe: *Probe,
    gpa: std.mem.Allocator,
    service: *frame.native.TextService,
    tree: *const nogui.widget.WidgetTree,
    inter: text_api.FontHandle,
    dejavu: text_api.FontHandle,
) !RecoveredCaption {
    var report: RecoveredCaption = .{};
    const node = findCaption(tree) orelse {
        probe.fail(
            "the recovered tree carries the ordinary caption",
            "no label node holds the caption bytes",
        );
        return report;
    };
    const request = node.text_request orelse {
        probe.fail(
            "the recovered caption resolved a text request",
            "the label node resolved no text request",
        );
        return report;
    };

    // The tree's OWN request: the family it names, the size it asked for and
    // the two policies it declared. The fallback face it carries is proved
    // below by the RUN that face actually shaped, which is the claim that
    // matters and the one a request field cannot stand in for.
    const wrap = request.paragraph().wrap;
    probe.ok(
        "the caption asks for the pinned family",
        std.mem.eql(u8, request.style.font.family, policy_face),
    );
    probe.near("the caption asks for its authored size", request.style.font.size, caption_size, 0.001);
    probe.ok("the caption keeps its no-wrap policy", wrap != null and wrap.? == .no_wrap);
    probe.ok("the caption keeps its notdef policy", request.missingGlyph() == .notdef);

    report.box = textBox(tree, node);
    probe.ok("the App laid the caption out in a real box", report.box.w > 0 and report.box.h > 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var layout = try service.nodeLayoutIn(arena.allocator(), caption, request.*, .{
        .width = report.box.w,
    }, host_default_size);
    defer layout.deinit();

    probe.eq("the recovered caption lays out on one line", layout.lines.len, 1);
    probe.ok("the recovered caption has real ink", layout.width > 0);
    probe.ok(
        "the App's box holds the ink those runs need",
        report.box.w >= layout.width and report.box.h >= layout.height,
    );
    report.ink = layout.width;

    const emoji_at = std.mem.indexOf(u8, caption, zwj_emoji).?;
    const heb_at = std.mem.indexOf(u8, caption, hebrew).?;
    var latin_run = false;
    var latin_notdef = false;
    var hebrew_run = false;
    var emoji_run = false;
    for (layout.runs) |run| {
        if (run.start == 0) {
            latin_run = true;
            probe.eq("the caption's first run is the pinned face", run.font, inter);
            probe.eq("the caption's inline run is bold", run.style.font.weight, caption_bold);
            probe.ok("the caption's inline run keeps its underline", run.style.underline);
            probe.ok("the caption's inline run keeps its background", run.style.background != null);
            // Glyph ids come from the face's own cmap, so none of the Latin
            // run is notdef.
            for (run.glyphs) |glyph| {
                if (glyph.gid == 0) latin_notdef = true;
            }
        }
        if (run.start <= heb_at and heb_at < run.end and run.script == .hebrew) {
            hebrew_run = true;
            probe.eq("the caption's hebrew run is the registered fallback", run.font, dejavu);
            probe.ok("the caption's hebrew run paints real glyphs", !run.missing_glyph);
        }
        if (run.start == emoji_at) {
            emoji_run = true;
            probe.ok("the caption's uncovered cluster is a visible notdef", run.missing_glyph);
        }
    }
    probe.ok("the caption's inline run exists", latin_run);
    probe.ok("the caption's latin glyphs come from the face's own cmap", latin_run and !latin_notdef);
    probe.ok("the caption's hebrew run exists", hebrew_run);
    probe.ok("the caption's uncovered cluster exists", emoji_run);

    // The same request at twice the size. An engine that measured a byte count
    // or a constant per character answers the same width twice, so this is
    // where the tree's own size field has to reach real advances.
    var scaled_node = request.*;
    scaled_node.style.font.size = caption_size * 2;
    var scaled = try service.nodeLayoutIn(arena.allocator(), caption, scaled_node, .{
        .width = null,
    }, host_default_size);
    defer scaled.deinit();
    probe.ok(
        "the caption's ink grows with the size the tree asked for",
        scaled.width > layout.width * 1.5,
    );

    // The refusal left this cache empty, so a repeat of the frame's own
    // request has to come back out of the runs it shaped rather than reshape
    // the caption a second time.
    const shapes_before = service.shapeCount();
    var repeat = try service.nodeLayoutIn(arena.allocator(), caption, request.*, .{
        .width = report.box.w,
    }, host_default_size);
    repeat.deinit();
    probe.eq("the recovered caption's shapes are reused", service.shapeCount(), shapes_before);
    report.shapes = service.shapeCount();
    return report;
}

/// The zero-face arm: the REAL App, the REAL `Root` and the ordinary
/// `ctx.label` path, measured through a public CPU `TextMeasurer` that was
/// handed no face at all.
///
/// NOTHING here touches a GPU. No loader, no `Offscreen`, no adapter, no
/// window, no surface, no present: a host that registered no font has to be
/// told so BY NAME instead of quietly publishing a tree whose labels measured
/// as nothing.
///
/// The recovery is the other half. The same App, the same root and the same
/// `TextService` take the two pinned faces through `TextService.addFont`, and
/// the next frame publishes the ordinary caption with the geometry those faces
/// really produce.
fn auditEmptyFontRegistry(gpa: std.mem.Allocator, io: std.Io, probe: *Probe) !void {
    probe.emit(
        "offscreen_consumer: mode=empty_font_registry faces=0 device=none window=none surface=none present=none\n",
        .{},
    );

    // The measurer is built FIRST and torn down LAST: `app.measure` is a
    // pointer into this value, so the App has to stop answering before the
    // service it measures through goes away. The default size is this
    // consumer's own 14, the value the GPU engine binds, so the frames this
    // arm measures are the frames the specimen measures.
    // SAFETY: `init` fills the measurer before `source()` borrows it.
    var measurer: nogui_text.TextMeasurer = undefined;
    try measurer.init(gpa, &.{}, host_default_size);
    defer measurer.deinit();
    const service = measurer.textService();

    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch @panic("zero-face arm left a live window");
    var app = try nogui.App.init(gpa, &session);
    defer app.deinit();

    var root: Root = .{};
    try app.mountRoot(Root, &root);
    app.measure = measurer.source();

    probe.eq("the arm booted with no configured face", service.listFonts().len, 0);
    probe.eq("no frame has been published before the first one", app.frame_generation, 0);
    probe.ok("the App holds no committed tree before the first frame", app.tree_ptr == null);

    // ── The refusal ──
    refuseFrame(
        probe,
        "the first frame refuses a registry with no face",
        app.frame(1, .{ .width = extent.width, .height = extent.height }),
    );
    probe.ok("the refused frame committed no tree", app.tree_ptr == null);
    probe.eq("the refused frame published no generation", app.frame_generation, 0);
    probe.eq("the refusal shaped nothing", service.shapeCount(), 0);

    // ── The recovery, through the registry API this file already uses ──
    const inter = try service.addFont(.{ .family = policy_face, .bytes = fonts.bytes });
    const dejavu = try service.addFont(.{ .family = "DejaVuSans", .bytes = fonts.rtl_bytes });
    probe.eq("both pinned faces are registered after the recovery", service.listFonts().len, 2);
    probe.eq(
        "the registry resolves the family the tree asks for",
        try service.resolve(.{ .family = policy_face }),
        inter,
    );

    const fallback = [_]text_api.FontHandle{dejavu};
    root.fallback = &fallback;
    root.ranges = &caption_range;

    var report: RecoveredCaption = .{};
    if (app.frame(2, .{ .width = extent.width, .height = extent.height })) |published| {
        defer if (published.json) |json| gpa.free(json);
        report = try auditRecoveredCaption(probe, gpa, service, published.tree, inter, dejavu);
    } else |err| {
        probe.checks += 1;
        probe.fail("the recovered frame publishes the ordinary caption", @errorName(err));
    }
    probe.ok("the recovered frame committed a tree", app.tree_ptr != null);
    probe.eq("the recovered frame is the first published generation", app.frame_generation, 1);

    if (probe.failures != 0) {
        probe.emit(
            "offscreen_consumer: FAILED checks={d} failures={d} stage=empty_font_registry\n",
            .{ probe.checks, probe.failures },
        );
        return error.SpecimenAssertionFailed;
    }
    const line = try std.fmt.allocPrint(
        gpa,
        "offscreen_consumer: OK checks={d} stage=empty_font_registry refused={s} shapes={d} caption_ink={d:.2} caption_box={d:.2}x{d:.2}\n",
        .{
            probe.checks,
            @errorName(error.FontUnavailable),
            report.shapes,
            report.ink,
            report.box.w,
            report.box.h,
        },
    );
    defer gpa.free(line);
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

const ShaderFile = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ShaderFile {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

// ── The one frame target ──────────────────────────────────────────────────

/// The three SPIR-V modules the batched quad pipeline draws with. The caller
/// owns the bytes for as long as the target recording with them lives.
const Shaders = struct {
    vert: []const u32,
    frag: []const u32,
    sort: []const u32,
};

/// The presented arm's blit pair: the fullscreen vertex stage and the
/// Oklab→sRGB fragment stage the second pass is recorded with.
const BlitShaders = struct {
    fullscreen: []const u32,
    oklab: []const u32,
};

/// The windowless arm: the shared `v7_frame` scene lowering and text engine
/// over a `v7_frame.Offscreen` target. No window, no surface, no swapchain
/// and no present. It names no host type, so it compiles identically with or
/// without `-Dnative`.
const Windowless = struct {
    loader: frame.SystemVulkanLoader,
    offscreen: frame.Offscreen,
    text: frame.TextEngine,
    gui: render.Renderer,
    scratch: scene.SceneScratch,
    cmd: noapi.CommandBuffer,
    gpu_frame: nogui.GpuFrame,

    fn init(self: *Windowless, gpa: std.mem.Allocator, io: std.Io, shaders: Shaders) !void {
        // The loader stays open until every GPU made from its options is gone.
        self.loader = try frame.SystemVulkanLoader.open();
        errdefer self.loader.close();
        self.offscreen = try frame.Offscreen.init(.{
            .allocator = gpa,
            .io = io,
            .loader = self.loader.options(),
            .extent = extent,
        });
        errdefer self.offscreen.deinit();
        self.text = try frame.TextEngine.init(gpa, self.offscreen.gpu(), &.{
            .{ .family = "InterVariable", .bytes = fonts.bytes },
            .{ .family = "DejaVuSans", .bytes = fonts.rtl_bytes },
        });
        errdefer self.text.deinit();
        try self.text.setGlyphSlotLimit(scene.glyph_material_ceiling);
        self.gui = try render.Renderer.init(
            self.offscreen.gpu(),
            shaders.vert,
            shaders.frag,
            shaders.sort,
        );
        errdefer self.gui.deinit();
        self.gui.configure(.{ .material_bda = self.text.materialBda() });
        self.scratch = scene.SceneScratch.init(gpa, &self.gui);
        self.cmd = undefined;
        self.gpu_frame = undefined;
    }

    fn deinit(self: *Windowless) void {
        self.scratch.deinit();
        self.gui.deinit();
        self.text.deinit();
        self.offscreen.deinit();
        self.loader.close();
    }

    fn beginFrame(self: *Windowless) !void {
        try self.offscreen.beginFrame(0, &self.cmd, &self.gpu_frame);
        self.scratch.beginFrame();
    }

    fn submit(self: *Windowless, output: *const nogui.FrameOutput, painted: *const scene.FramePaint) ![]const f32 {
        const record: scene.RecordContext = .{
            .arena = output.tree.allocator,
            .renderer = &self.gui,
            .text = &self.text,
            .logical = .{ .width = extent.width, .height = extent.height },
            .device = extent,
            .texture_heap = self.offscreen.heap().handle,
            .clips = output.tree.clip_rects[0..output.tree.clip_count],
        };
        _ = try scene.recordFrameScene(
            &record,
            &self.cmd,
            &self.scratch,
            self.scratch.rects.items,
            painted,
            self.offscreen.target(),
        );
        return self.offscreen.submitRead(&self.gpu_frame);
    }

    fn cancelFrame(self: *Windowless) void {
        if (self.gpu_frame.recording != .active) return;
        self.gpu_frame.cancelRecording() catch
            @panic("offscreen consumer recording cancellation failed");
    }
};

/// The presented arm: the SAME scene lowering and the SAME text engine, over
/// `v7_frame.NativeFrame`, into a real window's swapchain image. One Oklab
/// pass, the Oklab→sRGB blit that pass is sampled by, then the present; the
/// read-back the audits below measure comes out of the Oklab target those
/// passes wrote.
///
/// TEARDOWN ORDER, which this value owns: the App detaches from the endpoint
/// first (the caller does that), then the adapter, then the surface, then the
/// device, then this arm's loader, and only then the window and SDL. The
/// swapchain and the platform surface live on the device AND reference the
/// native window, so nothing device-side may outlive the window it presents
/// to.
///
/// An EMPTY value without `-Dnative`: the arm is then never compiled, never
/// stored into and never read, so the default proof links no host module and
/// no SDL. That is an absent value, not a stub — nothing in it can be reached.
const Presented = if (build_options.native) struct {
    /// SDL metadata is process-wide and set before video is initialized.
    const app_id: [:0]const u8 = "dev.nogui.examples.consumers.offscreen";
    const window_title = "nogui paragraph specimen";

    /// Host event batches spent waiting for the window to take the authored
    /// geometry, and then holding the presented frame. Both are bounds, not
    /// timeouts a run may quietly grow past.
    const readiness_polls: u32 = 32;
    const hold_polls: u32 = 8;
    const poll_delay_ms: i64 = 20;
    /// Acquires spent waiting for a swapchain that was out of date.
    const acquire_polls: u32 = 8;

    /// What the window answers with, as opposed to what it was asked for.
    const Observed = struct {
        logical: nogui.window_contract.Size,
        scale: nogui.geometry.PixelScale,
    };

    /// The video driver SDL picked, read once it is up. Reported so a run can
    /// say which platform it actually presented on.
    driver: [:0]const u8,
    application: *host.Application,
    handle: nogui.window_contract.WindowHandle,
    managed: *host.ManagedWindow,
    io: std.Io,
    /// The frame module's own loader, the same one the windowless arm builds
    /// its device from. It stays open until the device made from it is gone,
    /// so it closes after the surface and the device and before the window.
    loader: frame.SystemVulkanLoader,
    gpu: noapi.Gpu,
    /// The platform surface `noapi.Surface.initSdl` created from the SDL
    /// window and adopted. It owns the `VkSurfaceKHR` on the way out, so no
    /// SDL wrapper is kept beside it: there is no second owner of one handle.
    surface: noapi.Surface,
    adapter: frame.NativeFrame,
    recording: frame.NativeFrame.Frame,
    /// The observed device pixels per logical unit, read once the window took
    /// the authored geometry and handed to every `beginFrame` after it.
    scale: nogui.geometry.PixelScale,
    acquire_retries: u32 = 0,
    polls: u32 = 0,

    fn init(self: *Presented, gpa: std.mem.Allocator, io: std.Io, options: Target.Options) !void {
        self.* = .{
            .driver = "",
            .application = undefined,
            .handle = undefined,
            .managed = undefined,
            .io = io,
            .loader = undefined,
            .gpu = undefined,
            .surface = undefined,
            .adapter = undefined,
            .recording = undefined,
            .scale = .{ .x = 1, .y = 1 },
        };
        self.application = try gpa.create(host.Application);
        errdefer gpa.destroy(self.application);
        self.application.* = try host.Application.init(gpa, options.session, .{ .app_id = app_id });
        errdefer self.application.deinit();
        self.driver = sdl3.video.getCurrentDriverName() orelse "<null>";
        // The proof window is OURS for the length of the run. A platform close
        // request is vetoed and losing the last window does not ask the
        // process to quit, so nothing can retire the window this surface
        // presents to while the oracles are still reading it. Nothing else is
        // registered: no input, no clipboard, no frame callback. This
        // consumer drives its own frames and needs none of them.
        self.application.setHooks(.{
            .context = self,
            .on_close_request = vetoClose,
            .on_last_window_closed = keepRunning,
        });
        self.handle = try self.application.openWindowWithApp(options.app, .{
            .title = window_title,
            .width = extent.width,
            .height = extent.height,
            .resizable = false,
            .visible = true,
            .gpu_surface = true,
        });
        self.managed = try self.application.getWindow(self.handle);
        // The authored target or no run at all. Every oracle in this file
        // indexes the read-back by the global `extent` and assumes a 1:1
        // device scale, so a window that answered with anything else is
        // reported here and the run stops before a single pixel is measured.
        try self.awaitAuthoredTarget();
        // The device comes from the frame module's own loader, the same one
        // the windowless arm builds its device from, so both halves of this
        // run resolve their entry points the same way. The backend enables
        // the platform surface extensions the instance needs, so there is no
        // extension list to borrow from the window system here.
        self.loader = try frame.SystemVulkanLoader.open();
        errdefer self.loader.close();
        self.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers
            // over three slots, one per in-flight frame.
            .frames_in_flight = scene.frames_in_flight,
            .app_name = "nogui_offscreen_consumer",
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
        // back: the instance and the platform handle never leave noapi, and a
        // failed call destroys what the platform made. The surface is not
        // built on an unmeasured size.
        self.surface = try noapi.Surface.initSdl(
            &self.gpu,
            @ptrCast(self.managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = try self.deviceExtent() },
        );
        errdefer self.surface.deinit();
        // `NativeFrame` owns the one text service, the one renderer, the one
        // endpoint and the one scene scratch this arm records through, from
        // the SAME two pinned faces the windowless arm registers.
        try self.adapter.init(.{
            .allocator = gpa,
            .gpu = &self.gpu,
            .fonts = &.{
                .{ .family = "InterVariable", .bytes = fonts.bytes },
                .{ .family = "DejaVuSans", .bytes = fonts.rtl_bytes },
            },
            .shaders = .{
                .quad_vert = options.shaders.vert,
                .quad_frag = options.shaders.frag,
                .sort_comp = options.shaders.sort,
                .fullscreen_vert = options.blit.fullscreen,
                .blit_oklab = options.blit.oklab,
            },
            .name = "nogui_offscreen_consumer_blit_oklab",
        });
    }

    /// The App must already have detached from `adapter.gpuEndpoint()`.
    fn deinit(self: *Presented, gpa: std.mem.Allocator) void {
        self.adapter.deinit();
        // Before the device: the swapchain and the platform surface live on
        // it, and the platform surface references the native window.
        self.surface.deinit();
        self.gpu.deinit();
        // The loader outlives every device made from it, so it closes last.
        self.loader.close();
        // A refused close is a veto this run never raises; it is reported
        // rather than swallowed, and the window is gone either way.
        if (self.application.closeWindow(self.handle)) |_| {} else |err| {
            std.debug.print(
                "  the host refused to close the window: {s}\n",
                .{@errorName(err)},
            );
        }
        self.application.deinit();
        gpa.destroy(self.application);
    }

    /// The window's own pixel extent, read from the platform rather than
    /// assumed. Both passes size themselves to the image the driver handed
    /// out, and the readiness check above already proved it is the authored
    /// one.
    fn deviceExtent(self: *Presented) !noapi.Extent2D {
        const pixels = try self.managed.native.pixelExtent();
        return .{ .width = pixels.width, .height = pixels.height };
    }

    fn observed(self: *Presented) !Observed {
        const state = self.managed.observed;
        return .{
            .logical = state.size,
            .scale = try state.pixelScale(),
        };
    }

    /// True when the window IS the authored target: the same logical size, the
    /// same device pixel size, and therefore a 1:1 scale. A compositor that
    /// decorates, clamps or scales the client area answers false here, and the
    /// run is refused rather than measured against geometry it did not author.
    fn isAuthoredTarget(self: *Presented, state: Observed) bool {
        return state.logical.width == extent.width and state.logical.height == extent.height and
            self.managed.observed.pixels.width == extent.width and
            self.managed.observed.pixels.height == extent.height;
    }

    /// Pump the host until the window has MAPPED at the authored geometry,
    /// bounded, and report what it actually answered if it never does. A
    /// geometry that is already wrong is not waited on: no later poll can
    /// make the report any more true, so that case leaves immediately, and a
    /// geometry that is exact but never shown is a different refusal with a
    /// different name.
    fn awaitAuthoredTarget(self: *Presented) !void {
        var polls: u32 = 0;
        while (polls < readiness_polls) : (polls += 1) {
            self.polls += 1;
            _ = try self.application.step();
            try self.managed.refresh();
            const state = try self.observed();
            if (!self.isAuthoredTarget(state)) {
                self.reportGeometry();
                return error.NativeGeometryIsNotTheAuthoredTarget;
            }
            if (self.managed.observed.visible) {
                self.scale = state.scale;
                return;
            }
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
        }
        self.reportGeometry();
        return error.NativeWindowNeverBecameVisible;
    }

    /// The geometry the window ANSWERED, next to the geometry this consumer
    /// authored. A run that stops here reports both, so a refusal is never
    /// just a name.
    fn reportGeometry(self: *const Presented) void {
        const state = self.managed.observed;
        std.debug.print(
            "offscreen_consumer: authored {d}x{d}, window logical {d}x{d}, device {d}x{d}," ++
                " visible={}, occluded={}, host_polls={d}\n",
            .{
                extent.width,
                extent.height,
                state.size.width,
                state.size.height,
                state.pixels.width,
                state.pixels.height,
                state.visible,
                state.occluded,
                self.polls,
            },
        );
    }

    /// Acquire the next image, retarget the Oklab pass to it and open the
    /// recording. A swapchain that is out of date is not a failure: the
    /// acquire is retried inside a bound, so a driver that never settles
    /// fails the run instead of spinning.
    fn beginFrame(self: *Presented) !void {
        var attempts: u32 = 0;
        while (attempts < acquire_polls) : (attempts += 1) {
            const viewport: frame.NativeFrame.Viewport = .{
                .logical = .{
                    .width = @floatFromInt(extent.width),
                    .height = @floatFromInt(extent.height),
                },
                .device = try self.deviceExtent(),
                .scale = self.scale,
            };
            if (try self.adapter.beginFrame(&self.surface, viewport, &self.recording)) return;
            self.acquire_retries += 1;
            _ = try self.application.step();
        }
        return error.SwapchainNeverSettled;
    }

    /// The App's tree, the Oklab pass, the blit and the present are ONE event:
    /// a frame this run calls rendered is a frame whose pixels reached the
    /// swapchain image. The readback that follows is out of the Oklab target
    /// those same passes wrote.
    fn submit(self: *Presented, output: *const nogui.FrameOutput, painted: *const scene.FramePaint) ![]const f32 {
        try self.adapter.recordScene(&self.surface, &self.recording, output, painted);
        // `present` closes the recording itself, so a present that fails must
        // propagate its own error rather than reach a cancellation of a
        // recording that is gone.
        try self.adapter.present(&self.surface, &self.recording);
        self.managed.markPresented();
        return self.adapter.readTarget();
    }

    fn cancelFrame(self: *Presented) void {
        self.adapter.cancelFrame(&self.recording) catch |err| switch (err) {
            error.FrameNotRecording => {},
            else => @panic("offscreen consumer presented recording cancellation failed"),
        };
    }

    /// Hold the presented frame for a BOUNDED number of host steps, so the
    /// platform has processed the present and anything it asked for, and
    /// report what the surface then says it did with it.
    fn hold(self: *Presented) !void {
        var polls: u32 = 0;
        while (polls < hold_polls) : (polls += 1) {
            self.polls += 1;
            _ = try self.application.step();
            try self.managed.refresh();
        }
        try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
    }

    fn vetoClose(_: *anyopaque, _: nogui.window_contract.WindowHandle) bool {
        return false;
    }

    fn keepRunning(_: *anyopaque, _: *host.Application) host.Application.LastWindowDecision {
        return .keep_running;
    }
} else struct {};

/// Which GPU frame this run paints into. The windowless arm is the default
/// and the presented arm is the opt-in; they are the SAME consumer over the
/// SAME specimen, and the App mounts exactly one endpoint: the one this target
/// owns.
const Target = struct {
    const Mode = enum { windowless, presented };

    const Options = struct {
        mode: Mode,
        /// The three modules the batched quad pipeline draws with. Both arms
        /// record with them.
        shaders: Shaders,
        /// The presented arm's blit pair. `NativeFrame.init` copies the words
        /// into shader objects, so they need not outlive it.
        blit: BlitShaders,
        /// The App the window belongs to. A host window owns exactly one App,
        /// so the presented arm opens its window against this one and the
        /// windowless arm ignores both.
        app: *nogui.App,
        session: *nogui.Session,
    };

    /// What the real window reports about itself, or null in the windowless
    /// arm: there is no window there, and saying so is the honest report.
    const WindowState = struct {
        driver: [:0]const u8,
        logical: nogui.window_contract.Size,
        device: noapi.Extent2D,
        scale: nogui.geometry.PixelScale,
        visible: bool,
        occluded: bool,
        /// Host event batches spent waiting for the authored geometry, then
        /// holding the presented frame.
        polls: u32,
        /// Acquires the swapchain refused before one settled.
        acquire_retries: u32,
        stats: frame.NativeFrame.Stats,
    };

    gpa: std.mem.Allocator,
    mode: Mode,
    windowless: Windowless,
    presented: Presented,

    /// Both arms initialise IN PLACE: the scene scratch, the endpoint and the
    /// noapi state all hold addresses into this value, and a moved copy would
    /// leave every one of them pointing at the original. That is why it lives
    /// behind a pointer.
    fn init(gpa: std.mem.Allocator, io: std.Io, options: Target.Options) !*Target {
        const self = try gpa.create(Target);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .mode = options.mode,
            .windowless = undefined,
            .presented = undefined,
        };
        if (comptime build_options.native) {
            switch (options.mode) {
                .windowless => try self.windowless.init(gpa, io, options.shaders),
                .presented => try self.presented.init(gpa, io, options),
            }
        } else {
            try self.windowless.init(gpa, io, options.shaders);
        }
        return self;
    }

    /// The App must already have detached from `endpoint()`.
    fn deinit(self: *Target) void {
        if (comptime !build_options.native) {
            self.windowless.deinit();
        } else {
            switch (self.mode) {
                .windowless => self.windowless.deinit(),
                .presented => self.presented.deinit(self.gpa),
            }
        }
        self.gpa.destroy(self);
    }

    /// The ONE endpoint the App mounts: this target's own.
    fn endpoint(self: *Target) *nogui.GpuEndpoint {
        if (comptime !build_options.native) return self.windowless.offscreen.endpoint();
        return switch (self.mode) {
            .windowless => self.windowless.offscreen.endpoint(),
            .presented => self.presented.adapter.gpuEndpoint(),
        };
    }

    /// The measure source this target's OWN text engine provides, on either
    /// arm. The App holds the value; there is no scope to enter and no ambient
    /// engine, so a measured label and a painted glyph are one measurement
    /// whichever arm this run took.
    fn measurer(self: *Target) nogui.layout.MeasureSource {
        if (comptime !build_options.native) return self.windowless.text.measurer();
        return switch (self.mode) {
            .windowless => self.windowless.text.measurer(),
            .presented => self.presented.adapter.measurer(),
        };
    }

    /// The ONE service. Shape here, paint with `textEngine()`.
    fn service(self: *Target) *frame.native.TextService {
        if (comptime !build_options.native) return &self.windowless.text.service;
        return switch (self.mode) {
            .windowless => &self.windowless.text.service,
            .presented => self.presented.adapter.textService(),
        };
    }

    /// The rasterizer these frames submit glyphs through, and the source of
    /// every glyph-slot count this run reports.
    fn textEngine(self: *Target) *frame.TextEngine {
        if (comptime !build_options.native) return &self.windowless.text;
        return switch (self.mode) {
            .windowless => &self.windowless.text,
            .presented => self.presented.adapter.textEngine(),
        };
    }

    /// The retained per-frame scene lists. This run's OWN specimen rects are
    /// appended here, after `beginFrame` and before `submit`.
    fn scratch(self: *Target) *scene.SceneScratch {
        if (comptime !build_options.native) return &self.windowless.scratch;
        return switch (self.mode) {
            .windowless => &self.windowless.scratch,
            .presented => self.presented.adapter.sceneScratch(),
        };
    }

    /// The recording this frame is built in. `App` refuses a GPU frame that is
    /// not the active recording of the endpoint it was handed.
    fn gpuFrame(self: *Target) *nogui.GpuFrame {
        if (comptime !build_options.native) return &self.windowless.gpu_frame;
        return switch (self.mode) {
            .windowless => &self.windowless.gpu_frame,
            .presented => &self.presented.recording.gpu_frame,
        };
    }

    /// Open the recording and reset the scene lists this frame builds into.
    fn beginFrame(self: *Target) !void {
        if (comptime !build_options.native) return self.windowless.beginFrame();
        return switch (self.mode) {
            .windowless => self.windowless.beginFrame(),
            .presented => self.presented.beginFrame(),
        };
    }

    /// Lower the committed tree into this frame's paint list. THE ONE
    /// lowering call in this file: both arms hand it the same scratch, the same
    /// text engine and the same frame, so the specimen this run appends after
    /// it is the specimen the audits below read back.
    fn buildScene(self: *Target, output: *const nogui.FrameOutput) !scene.FramePaint {
        return scene.buildFrameScene(self.scratch(), self.textEngine(), .{}, output, false);
    }

    /// Record, submit and read the Oklab pixels back out of the target this
    /// arm's passes wrote.
    fn submit(self: *Target, output: *const nogui.FrameOutput, painted: *const scene.FramePaint) ![]const f32 {
        if (comptime !build_options.native) return self.windowless.submit(output, painted);
        return switch (self.mode) {
            .windowless => self.windowless.submit(output, painted),
            .presented => self.presented.submit(output, painted),
        };
    }

    /// Discard a recording whose frame failed before the submission. Cheap and
    /// terminal either way, and a no-op once the frame was presented.
    fn cancelFrame(self: *Target) void {
        if (comptime !build_options.native) {
            self.windowless.cancelFrame();
            return;
        }
        switch (self.mode) {
            .windowless => self.windowless.cancelFrame(),
            .presented => self.presented.cancelFrame(),
        }
    }

    fn windowState(self: *Target) ?WindowState {
        if (comptime !build_options.native) return null;
        return switch (self.mode) {
            .windowless => null,
            .presented => .{
                .driver = self.presented.driver,
                .logical = self.presented.managed.observed.size,
                .device = .{
                    .width = self.presented.managed.observed.pixels.width,
                    .height = self.presented.managed.observed.pixels.height,
                },
                .scale = self.presented.scale,
                .visible = self.presented.managed.observed.visible,
                .occluded = self.presented.managed.observed.occluded,
                .polls = self.presented.polls,
                .acquire_retries = self.presented.acquire_retries,
                .stats = self.presented.adapter.stats,
            },
        };
    }

    /// Let the platform finish processing the presented frame. Meaningful
    /// only on the presented arm, and named rather than hidden so the
    /// default build never calls a no-op that would look like a wait.
    fn hold(self: *Target) !void {
        if (comptime !build_options.native) return;
        switch (self.mode) {
            .windowless => {},
            .presented => try self.presented.hold(),
        }
    }
};

/// The command line. The three quad-pipeline shader modules are positional
/// and always required; the PPM path stays the optional fourth POSITIONAL,
/// exactly as the windowless proof has always taken it, so every existing
/// invocation is unchanged. `--native` is the mode switch, and the two blit
/// modules ONLY the presented arm records with come from flags.
/// `--empty-font-registry` is the third mode: it never opens a target at all,
/// so the shader positionals stay required by this one parser and go unread.
const Options = struct {
    vert: []const u8,
    frag: []const u8,
    sort: []const u8,
    ppm: ?[]const u8 = null,
    fullscreen: ?[]const u8 = null,
    oklab: ?[]const u8 = null,
    native: bool = false,

    /// Boot the REAL App with a font registry that holds no face at all and
    /// prove its first frame refuses. That arm answers on the CPU alone, so it
    /// opens no target: no loader, no device, no surface, no window.
    empty_font_registry: bool = false,

    /// Where the blit modules come from when the command line does not name
    /// them. Relative to the working directory, exactly as the in-tree
    /// presented parity examples already require; the `run-native` step passes
    /// them explicitly so the consumer needs no particular directory.
    fn fullscreenPath(self: Options) []const u8 {
        return self.fullscreen orelse "shaders/fullscreen_vert.spv";
    }

    fn oklabPath(self: Options) []const u8 {
        return self.oklab orelse "shaders/blit_oklab.spv";
    }
};

/// One observable fact per check. A mismatch is named on stdout and counted;
/// the process then exits non-zero instead of reporting success.
const Probe = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    checks: usize = 0,
    failures: usize = 0,

    fn emit(self: *Probe, comptime format: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.gpa, format, args) catch return;
        defer self.gpa.free(line);
        std.Io.File.stdout().writeStreamingAll(self.io, line) catch {};
    }

    fn fail(self: *Probe, name: []const u8, detail: []const u8) void {
        self.failures += 1;
        self.emit("FAIL {s}: {s}\n", .{ name, detail });
    }

    fn ok(self: *Probe, name: []const u8, value: bool) void {
        self.checks += 1;
        if (!value) self.fail(name, "expected a true fact");
    }

    fn eq(self: *Probe, name: []const u8, got: anytype, want: anytype) void {
        self.checks += 1;
        if (std.meta.eql(got, want)) return;
        const detail = std.fmt.allocPrint(self.gpa, "got {any}, want {any}", .{ got, want }) catch {
            self.fail(name, "values differ");
            return;
        };
        defer self.gpa.free(detail);
        self.fail(name, detail);
    }

    fn near(self: *Probe, name: []const u8, got: f32, want: f32, tolerance: f32) void {
        self.checks += 1;
        if (std.math.isFinite(got) and @abs(got - want) <= tolerance) return;
        const detail = std.fmt.allocPrint(
            self.gpa,
            "got {d:.4}, want {d:.4} +-{d:.4}",
            .{ got, want, tolerance },
        ) catch {
            self.fail(name, "values differ");
            return;
        };
        defer self.gpa.free(detail);
        self.fail(name, detail);
    }
};

/// A half-open box in device pixels; the logical and device sizes are 1:1.
/// Zero defaults, so an unfound box is the empty one rather than a compile
/// error at every field.
const Area = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

const Pixel = struct {
    x: usize,
    y: usize,
};

/// What counts as ink in one part of the target: a pixel is ink when it
/// differs from the SURFACE that part was painted on. Outside the App tree
/// that surface is the render pass's own clear colour; inside a widget it is
/// whatever the App painted underneath, which is a real colour the consumer
/// reads off the frame. Assuming the clear colour inside the tree would
/// count the App's own background and its neighbouring rows as this
/// widget's ink.
const Ink = struct {
    pixels: []const f32,
    plate: [4]f32,

    fn at(self: Ink, x: usize, y: usize) bool {
        const index = (y * @as(usize, extent.width) + x) * 4;
        const pixel = self.pixels[index..][0..4];
        return pixel[0] != self.plate[0] or
            pixel[1] != self.plate[1] or
            pixel[2] != self.plate[2];
    }
};

/// The classifier for the part of the target the App tree never covers.
fn clearInk(pixels: []const f32) Ink {
    return .{ .pixels = pixels, .plate = scene.oklab_clear };
}

/// The pixel rectangle a box names, clamped to the target.
const Bounds = struct { x0: usize, y0: usize, x1: usize, y1: usize };

fn pixelBounds(area: Area) Bounds {
    return .{
        .x0 = clampPixel(area.x, extent.width),
        .y0 = clampPixel(area.y, extent.height),
        .x1 = clampEdge(area.x + area.w, extent.width),
        .y1 = clampEdge(area.y + area.h, extent.height),
    };
}

/// True when one of these scene rectangles covers the pixel.
fn ownsPixel(rects: []const SceneRect, x: usize, y: usize) bool {
    const px: f32 = @floatFromInt(x);
    const py: f32 = @floatFromInt(y);
    for (rects) |rect| {
        if (px >= rect.dst[0] and px < rect.dst[0] + rect.dst[2] and
            py >= rect.dst[1] and py < rect.dst[1] + rect.dst[3]) return true;
    }
    return false;
}

/// The surface inside `area` that none of `own` paints: the colour shared by
/// the pixels no rectangle in `own` covers. Every other pixel there is what
/// this widget itself painted, so reading the surface off the frame is what
/// keeps the App's own background out of the caption's ink. The surface is a
/// solid fill, so the first uncovered pixel names it and the rest confirm it;
/// a minority match means something else painted inside this box, and
/// guessing which of those colours is the surface would be fiction. Null
/// when the widget's own rectangles leave no surface to read at all.
fn plateUnder(pixels: []const f32, area: Area, own: []const SceneRect) ?[4]f32 {
    const bounds = pixelBounds(area);
    var plate: [4]f32 = .{ 0, 0, 0, 1 };
    var named = false;
    var matching: usize = 0;
    var uncovered: usize = 0;
    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            if (ownsPixel(own, x, y)) continue;
            uncovered += 1;
            const pixel = pixels[(y * @as(usize, extent.width) + x) * 4 ..][0..4];
            if (!named) {
                plate = .{ pixel[0], pixel[1], pixel[2], pixel[3] };
                named = true;
            }
            if (pixel[0] == plate[0] and pixel[1] == plate[1] and
                pixel[2] == plate[2]) matching += 1;
        }
    }
    if (!named) return null;
    if (matching * 2 <= uncovered) return null;
    return plate;
}

fn clampPixel(value: f32, limit: u32) usize {
    return @intFromFloat(@floor(std.math.clamp(value, 0, @as(f32, @floatFromInt(limit)))));
}

fn clampEdge(value: f32, limit: u32) usize {
    return @intFromFloat(@ceil(std.math.clamp(value, 0, @as(f32, @floatFromInt(limit)))));
}

/// Count the pixels inside `area` that changed from its surface.
fn inkIn(ink: anytype, area: Area) usize {
    const bounds = pixelBounds(area);
    var count: usize = 0;
    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            if (ink.at(x, y)) count += 1;
        }
    }
    return count;
}

/// The pixel a solid fill must have covered, or null for a box too thin to
/// name one.
fn solidCentre(area: Area) ?Pixel {
    if (area.w < 4 or area.h < 4) return null;
    const x = clampPixel(area.x + area.w / 2, extent.width);
    const y = clampPixel(area.y + area.h / 2, extent.height);
    if (x == 0 or y == 0) return null;
    return .{ .x = x, .y = y };
}

/// The bounding box of the ink inside `area`, or null when there is none.
fn inkBox(ink: anytype, area: Area) ?Area {
    const bounds = pixelBounds(area);
    var min_x: f32 = @floatFromInt(extent.width);
    var min_y: f32 = @floatFromInt(extent.height);
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    var found = false;
    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            if (!ink.at(x, y)) continue;
            const px: f32 = @floatFromInt(x);
            const py: f32 = @floatFromInt(y);
            min_x = @min(min_x, px);
            min_y = @min(min_y, py);
            max_x = @max(max_x, px);
            max_y = @max(max_y, py);
            found = true;
        }
    }
    if (!found) return null;
    return .{
        .x = min_x,
        .y = min_y,
        .w = @max(0, max_x - min_x + 1),
        .h = @max(0, max_y - min_y + 1),
    };
}

const LayoutReport = struct {
    name: []const u8 = "",
    /// The box the layout measured for itself.
    area: Area = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The union of every run's ascent-to-descent band around its baseline.
    ink_band: Area = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    lines: usize = 0,
    runs: usize = 0,
    rects: usize = 0,
    glyph_rects: usize = 0,
    notdef_boxes: usize = 0,
    solid_rects: usize = 0,
    ink: usize = 0,
};

fn rectAt(probe: *Probe, rects: []const SceneRect, index: usize, name: []const u8) ?SceneRect {
    if (index < rects.len) return rects[index];
    probe.fail(name, "the engine submitted fewer rects than the layout promised");
    return null;
}

/// The four solid strokes the engine paints for one glyph id zero, derived
/// from the shaped advance the layout measured for that glyph.
fn notdefStrokes(item: anytype) [4][4]f32 {
    const width = @max(4, @min(@max(item.glyph.x_advance, 0), item.size * 0.7));
    const height = @max(6, item.size * 0.75);
    const stroke = @max(1, @min(width, height) / 8);
    const box_x = item.run_x + item.pen + item.glyph.x_offset + (item.glyph.x_advance - width) / 2;
    const box_y = item.baseline - height;
    return .{
        .{ box_x, box_y, width, stroke },
        .{ box_x, box_y + height - stroke, width, stroke },
        .{ box_x, box_y + stroke, stroke, height - 2 * stroke },
        .{ box_x + width - stroke, box_y + stroke, stroke, height - 2 * stroke },
    };
}

/// Emit one shaped layout and check every rectangle the engine submitted for
/// it against that layout's measured geometry.
fn submitLayout(
    probe: *Probe,
    engine: *frame.TextEngine,
    layout: anytype,
    name: []const u8,
    origin: [2]f32,
    centered_in: ?f32,
    z: u32,
    emitted: *std.ArrayList(SceneRect),
    report: *LayoutReport,
) !void {
    const base = emitted.items.len;
    try engine.emitLayout(&engine.service, layout, origin[0], origin[1], scene.no_clip, z, emitted);
    try matchLayout(probe, layout, name, origin, centered_in, scene.no_clip, z, emitted.items[base..], report);
}

/// Every rectangle one shaped layout produced, checked against the geometry
/// that layout measured. The submission order is the engine's: backgrounds
/// line by line, then every run's glyphs, then the decorations. The caller
/// supplies the rectangles, so the same check covers a layout the engine
/// emitted here and a layout an ORDINARY App caption painted.
fn matchLayout(
    probe: *Probe,
    layout: anytype,
    name: []const u8,
    origin: [2]f32,
    centered_in: ?f32,
    clip_id: u32,
    z: u32,
    rects: []const SceneRect,
    report: *LayoutReport,
) !void {
    var band: Area = .{
        .x = origin[0],
        .y = @floatFromInt(extent.height),
        .w = layout.width,
        .h = 0,
    };
    for (layout.runs) |run| {
        band.y = @min(band.y, origin[1] + run.baseline - run.font_metrics.ascent);
        band.h = @max(
            band.h,
            origin[1] + run.baseline - run.font_metrics.descent - band.y,
        );
    }
    report.* = .{
        .name = name,
        .area = .{ .x = origin[0], .y = origin[1], .w = layout.width, .h = layout.height },
        .ink_band = band,
        .lines = layout.lines.len,
        .runs = layout.runs.len,
        .rects = rects.len,
    };

    var cursor: usize = 0;
    for (layout.lines) |line| {
        var runs_width: f32 = 0;
        var cursor_x = line.x;
        if (centered_in) |limit| {
            probe.near("a centered line", line.x, (limit - line.width) / 2, 0.01);
        }
        for (layout.runs[line.first_run..line.end_run]) |run| {
            probe.near("run x", run.x, cursor_x, 0.01);
            probe.near("run y", run.y, line.y, 0.01);
            probe.near(
                "run baseline",
                run.baseline,
                line.y + (line.height - run.font_metrics.line_height) / 2 + run.font_metrics.ascent,
                0.01,
            );
            probe.ok("a line holds its runs", run.x >= line.x - 0.01 and
                run.x + run.width <= line.x + line.width + 0.01);
            cursor_x += run.width;
            runs_width += run.width;
        }
        probe.near("line width from its runs", runs_width, line.width, 0.1);
        probe.near("line right edge", cursor_x, line.x + line.width, 0.1);
        probe.ok("a line fits the layout width", line.x >= -0.01 and
            line.x + line.width <= layout.width + 0.01);
        for (layout.runs[line.first_run..line.end_run]) |run| {
            const background = run.backgroundRect(line.height) orelse continue;
            if (background.width <= 0 or background.height <= 0) continue;
            const rect = rectAt(probe, rects, cursor, "background") orelse return;
            probe.eq("a background is a solid", rect.material_index, 0);
            probe.near("background x", rect.dst[0], origin[0] + background.x, 0.01);
            probe.near("background y", rect.dst[1], origin[1] + background.y, 0.01);
            probe.near("background width", rect.dst[2], background.width, 0.01);
            probe.near("background height", rect.dst[3], background.height, 0.01);
            probe.eq("background clip", rect.clip_id, clip_id);
            probe.eq("background z", rect.z, z);
            report.solid_rects += 1;
            cursor += 1;
        }
    }

    // The engine walks every run's glyphs in one submission order. Flatten
    // that order so a submitted rect is matched to the shaped glyph that owns
    // it: a glyph with no outline (a space) submits nothing, so the match may
    // skip ahead.
    const GlyphPos = @typeInfo(@TypeOf(layout.runs[0].glyphs)).pointer.child;
    const Expected = struct {
        run_x: f32,
        run_width: f32,
        baseline: f32,
        pen: f32,
        size: f32,
        glyph: GlyphPos,
    };
    var expected: std.ArrayList(Expected) = .empty;
    defer expected.deinit(probe.gpa);
    for (layout.lines) |line| {
        for (layout.runs[line.first_run..line.end_run]) |run| {
            // A 1x device grid snaps the run origin and the baseline.
            const run_x = @round(origin[0] + run.x);
            const baseline = @round(origin[1] + run.baseline);
            var pen: f32 = 0;
            for (run.glyphs) |glyph| {
                try expected.append(probe.gpa, .{
                    .run_x = run_x,
                    .run_width = run.width,
                    .baseline = baseline,
                    .pen = pen,
                    .size = run.style.font.size,
                    .glyph = glyph,
                });
                pen += glyph.x_advance;
            }
            // The measured run width and the shaped advances are one sum.
            probe.near("the run advance sum", pen, run.width, 0.5);
        }
    }

    var next: usize = 0;
    while (cursor < rects.len and next < expected.items.len) {
        const rect = rects[cursor];
        if (rect.material_index != 0) {
            var scan = next;
            var found: ?usize = null;
            while (scan < expected.items.len) : (scan += 1) {
                const item = expected.items[scan];
                if (item.glyph.gid == 0) continue;
                if (@abs(item.run_x + item.pen + item.glyph.x_offset - rect.origin[0]) <= 0.001 and
                    @abs(item.baseline - item.glyph.y_offset - rect.origin[1]) <= 0.001)
                {
                    found = scan;
                    break;
                }
            }
            const item = expected.items[
                found orelse {
                    probe.fail("glyph pen x", "a submitted quad matches no shaped glyph");
                    return;
                }
            ];
            probe.near("glyph pen x", rect.origin[0], item.run_x + item.pen + item.glyph.x_offset, 0.001);
            probe.near("glyph pen y", rect.origin[1], item.baseline - item.glyph.y_offset, 0.001);
            probe.ok("a glyph uses a glyph material slot", rect.material_index < scene.glyph_material_ceiling);
            probe.ok("a glyph quad carries the raster margin", rect.dst[2] >=
                2 * raster_margin and rect.dst[3] >= 2 * raster_margin);
            probe.ok("a glyph quad stays inside the target", rect.dst[0] >= -8 and
                rect.dst[0] + rect.dst[2] <= @as(f32, @floatFromInt(extent.width)) + 8);
            probe.ok("a glyph pen is inside its measured run", rect.origin[0] >=
                item.run_x - snap_slack and rect.origin[0] <= item.run_x + item.run_width + snap_slack);
            probe.eq("glyph clip", rect.clip_id, clip_id);
            probe.eq("glyph z", rect.z, z);
            report.glyph_rects += 1;
            cursor += 1;
            next = scan + 1;
        } else {
            var scan = next;
            var found: ?usize = null;
            while (scan < expected.items.len) : (scan += 1) {
                if (expected.items[scan].glyph.gid == 0) {
                    found = scan;
                    break;
                }
            }
            const item = expected.items[
                found orelse {
                    probe.fail("notdef stroke", "a submitted solid matches no missing glyph");
                    return;
                }
            ];
            const strokes = notdefStrokes(item);
            for (strokes, 0..) |want, index| {
                const stroke_rect = rectAt(probe, rects, cursor + index, "notdef stroke") orelse return;
                probe.eq("a notdef stroke is a solid", stroke_rect.material_index, 0);
                probe.near("notdef x", stroke_rect.dst[0], want[0], 0.01);
                probe.near("notdef y", stroke_rect.dst[1], want[1], 0.01);
                probe.near("notdef width", stroke_rect.dst[2], want[2], 0.01);
                probe.near("notdef height", stroke_rect.dst[3], want[3], 0.01);
            }
            cursor += strokes.len;
            report.notdef_boxes += 1;
            next = scan + 1;
        }
    }

    for (layout.runs) |run| {
        const decorations = [2]struct { what: []const u8, box: ?text_api.Rect }{
            .{ .what = "underline", .box = run.underlineRect() },
            .{ .what = "strike", .box = run.strikeRect() },
        };
        for (decorations) |decoration| {
            const box = decoration.box orelse continue;
            if (box.width <= 0 or box.height <= 0) continue;
            const rect = rectAt(probe, rects, cursor, decoration.what) orelse return;
            probe.eq("a decoration is a solid", rect.material_index, 0);
            probe.near("decoration x", rect.dst[0], origin[0] + box.x, 0.01);
            probe.near("decoration y", rect.dst[1], origin[1] + box.y, 0.01);
            probe.near("decoration width", rect.dst[2], box.width, 0.01);
            probe.near("decoration height", rect.dst[3], box.height, 0.01);
            probe.eq("decoration clip", rect.clip_id, clip_id);
            report.solid_rects += 1;
            cursor += 1;
        }
    }

    probe.eq("the submitted rect count", rects.len, cursor);
    probe.ok("the layout produced glyphs", report.glyph_rects + report.notdef_boxes > 0);
    probe.ok("the run ink band is above the layout box", band.y >= origin[1] - bleed and
        band.y + band.h <= origin[1] + layout.height + bleed);
}

/// What one ORDINARY App caption proved through the canonical path.
const CaptionReport = struct {
    /// The box the tree laid the caption out in.
    box: Area = .{},
    /// The box the caption's own text covers inside it.
    text: Area = .{},
    /// The notdef outline the engine drew for the uncovered cluster.
    tofu: Area = .{},
    /// The run the fallback face painted: real glyphs, not notdef.
    hebrew: Area = .{},
    /// The inline styled run's own run box.
    styled: Area = .{},
    notdef_boxes: usize = 0,
    solids: usize = 0,
    glyph_quads: usize = 0,
};

/// Lay the App tree's OWN caption request out through the same builder the
/// paint path uses, and hold every rectangle the ordinary scene pass produced
/// for that caption against it.
///
/// Nothing here expects the caption's source bytes. The expectations are the
/// shaped glyph ids, the advances, the faces, the scripts and the styles the
/// TREE resolved, and the fact that those rectangles reached the target.
fn auditCaption(
    probe: *Probe,
    tree: *const nogui.widget.WidgetTree,
    service: anytype,
    arena: *std.heap.ArenaAllocator,
    scene_rects: []const SceneRect,
    /// Filled with the caption's own rectangles, in submission order.
    own_rects: *std.ArrayList(SceneRect),
    dejavu: text_api.FontHandle,
    inter: text_api.FontHandle,
) !CaptionReport {
    var report: CaptionReport = .{};

    // Named, never positional: the node is the label that holds these bytes.
    const node = findCaption(tree) orelse {
        probe.fail("the app tree carries the caption", "no label node holds the caption bytes");
        return report;
    };
    const request = node.text_request orelse {
        probe.fail("the caption resolved a request", "the label node resolved no text request");
        return report;
    };

    const border = nogui.visualBorderRect(tree, node.id);
    report.box = .{ .x = border.x, .y = border.y, .w = border.w, .h = border.h };

    const content = textBox(tree, node);

    var layout = try service.nodeLayoutIn(arena.allocator(), caption, request.*, .{
        .width = content.w,
    }, host_default_size);
    defer {
        layout.deinit();
        _ = arena.reset(.retain_capacity);
    }

    // The text origin the scene paints from: the node's own content box,
    // vertically centred. That is the shared text content rect the ordinary
    // caption loop and the measure decoration both use, so laying out at the
    // tree's own width here reproduces the layout the paint came from.
    const origin = [2]f32{
        content.x,
        content.y + @max(0, (content.h - layout.height) / 2),
    };
    report.text = .{ .x = origin[0], .y = origin[1], .w = layout.width, .h = layout.height };
    probe.ok("the caption laid out on one line", layout.lines.len == 1);

    // Every rectangle the scene submitted inside the caption's band, in the
    // engine's own submission order. A node's rectangles are appended
    // together, so the filtered list is the caption's own run of rects. It is
    // the CALLER's list: the pixel audit needs these exact rectangles to tell
    // the caption's own ink from the surface it was painted on.
    for (scene_rects) |rect| {
        const box: Area = .{ .x = rect.dst[0], .y = rect.dst[1], .w = rect.dst[2], .h = rect.dst[3] };
        if (box.x + box.w < report.box.x - bleed or box.x > report.box.x + report.box.w + bleed) continue;
        if (box.y + box.h < report.box.y - bleed or box.y > report.box.y + report.box.h + bleed) continue;
        try own_rects.append(probe.gpa, rect);
    }
    const band = own_rects.items;
    probe.ok("the caption submitted rectangles", band.len > 0);

    var layout_report: LayoutReport = .{};
    // The node's own layer key and clip id are what the caption's rects carry;
    // taking them from the first of them checks that every rectangle of the
    // caption rides the same layer and the same clip as its first.
    const caption_z: u32 = if (band.len == 0) 0 else band[0].z;
    const caption_clip: u32 = if (band.len == 0) scene.no_clip else band[0].clip_id;
    try matchLayout(probe, &layout, "caption", origin, null, caption_clip, caption_z, band, &layout_report);
    report.notdef_boxes = layout_report.notdef_boxes;
    report.solids = layout_report.solid_rects;
    report.glyph_quads = layout_report.glyph_rects;

    // The three claims an ordinary caption has to make, read off the request
    // the TREE resolved rather than off what was typed.
    const emoji_at = std.mem.indexOf(u8, caption, zwj_emoji).?;
    const heb_at = std.mem.indexOf(u8, caption, hebrew).?;
    var tofu_found = false;
    var hebrew_found = false;
    var styled_found = false;
    for (layout.runs) |run| {
        const band_box: Area = .{
            .x = origin[0] + run.x,
            .y = origin[1] + run.baseline - run.font_metrics.ascent,
            .w = run.width,
            .h = run.font_metrics.ascent - run.font_metrics.descent,
        };
        if (run.start == emoji_at and run.missing_glyph) {
            tofu_found = true;
            // The notdef outline for that cluster, from the same shaped
            // advance the layout measured for it.
            var pen: f32 = 0;
            for (run.glyphs) |glyph| {
                if (glyph.gid == 0) {
                    const strokes = notdefStrokes(.{
                        .run_x = @round(origin[0] + run.x),
                        .run_width = run.width,
                        .baseline = @round(origin[1] + run.baseline),
                        .pen = pen,
                        .size = run.style.font.size,
                        .glyph = glyph,
                    });
                    report.tofu = .{
                        .x = strokes[0][0],
                        .y = strokes[0][1],
                        .w = strokes[0][2],
                        .h = strokes[0][3],
                    };
                    break;
                }
                pen += glyph.x_advance;
            }
        }
        if (run.start <= heb_at and heb_at < run.end and run.script == .hebrew) {
            hebrew_found = true;
            probe.eq("the caption's hebrew run is the fallback face", run.font, dejavu);
            probe.ok("the caption's hebrew run paints real glyphs", !run.missing_glyph);
            report.hebrew = band_box;
        }
        if (run.start == 0) {
            styled_found = true;
            probe.eq("the caption's inline run is the primary face", run.font, inter);
            probe.eq("the caption's inline run is bold", run.style.font.weight, caption_bold);
            probe.ok("the caption's inline run keeps its underline", run.style.underline);
            probe.ok("the caption's inline run keeps its background", run.style.background != null);
            report.styled = band_box;
        }
    }
    probe.ok("the caption's uncovered cluster is a visible notdef", tofu_found);
    probe.ok("the caption's hebrew run exists", hebrew_found);
    probe.ok("the caption's inline run exists", styled_found);
    probe.ok("the caption's uncovered cluster reached the notdef policy", report.notdef_boxes > 0);

    // The App already shaped this caption when it measured and painted it, so
    // asking for the same request again costs no shaping at all.
    const shapes_before = service.shapeCount();
    var repeat = try service.nodeLayoutIn(arena.allocator(), caption, request.*, .{
        .width = content.w,
    }, host_default_size);
    // The arena is reset by the function's own defer, once the first layout
    // has been released: resetting here would free bytes `layout` still owns.
    repeat.deinit();
    probe.eq("the caption's shapes are reused", service.shapeCount(), shapes_before);
    return report;
}

/// The pixels those caption rectangles claimed. A tofu outline, a fallback
/// run and an inline style are only real if the target changed where they
/// said it would.
///
/// The caption rides the App tree's own surface, not the render pass's clear
/// colour: the tree paints a full-width background above it and a full-width
/// button fill below it, and a clear-colour classifier calls both of those
/// this caption's ink. So the surface is read off the frame first — the
/// colour of the pixels inside the caption's own box that NO caption
/// rectangle covers — and only what differs from THAT is the caption's ink.
fn auditCaptionPixels(
    probe: *Probe,
    pixels: []const f32,
    own_rects: []const SceneRect,
    report: CaptionReport,
) void {
    const plate = plateUnder(pixels, report.box, own_rects) orelse {
        probe.fail(
            "the caption's box has one plain surface",
            "no colour covers the pixels its own rectangles leave free",
        );
        return;
    };
    const ink: Ink = .{ .pixels = pixels, .plate = plate };
    const caption_ink = inkIn(ink, report.text);
    probe.emit("offscreen_consumer: caption ink={d} solids={d} glyph_quads={d} notdef={d}\n", .{
        caption_ink,
        report.solids,
        report.glyph_quads,
        report.notdef_boxes,
    });
    probe.ok("the caption's own text box holds ink", caption_ink > 0);
    probe.ok("the caption's notdef outline painted pixels", inkIn(ink, report.tofu) > 0);
    probe.ok("the caption's hebrew run painted pixels", inkIn(ink, report.hebrew) > 0);
    probe.ok("the caption's inline run painted pixels", inkIn(ink, report.styled) > 0);
    // The scan window is the measured text box grown by the raster bleed and
    // clipped to the caption's own box: a band reaching past that box would
    // read the neighbouring rows' fills as this caption's ink. The bounds are
    // still the MEASURED text box, so a caption that painted outside what it
    // measured still fails here.
    const left = @max(report.text.x - bleed, report.box.x);
    const top = @max(report.text.y - bleed, report.box.y);
    const right = @min(report.text.x + report.text.w + bleed, report.box.x + report.box.w);
    const bottom = @min(report.text.y + report.text.h + bleed, report.box.y + report.box.h);
    const box = inkBox(ink, .{
        .x = left,
        .y = top,
        .w = @max(0, right - left),
        .h = @max(0, bottom - top),
    }) orelse {
        probe.fail("the caption's text box holds ink", "no pixel changed inside it");
        return;
    };
    probe.ok("the caption's ink starts at its measured left edge", box.x >= report.text.x - bleed);
    probe.ok("the caption's ink ends at its measured right edge", box.x + box.w <= report.text.x + report.text.w + bleed);
}

// ── Paragraph policy on ordinary labels ───────────────────────────────────

/// Everything the policy-label audits read: the tree the App built, the
/// rectangles the scene submitted for it, the read-back pixels and the pinned
/// face those labels are shaped with. One object owns one scratch arena,
/// reset once per label so the shaped leases are released before the bytes go.
const LabelScene = struct {
    probe: *Probe,
    tree: *const nogui.widget.WidgetTree,
    service: *frame.native.TextService,
    arena: *std.heap.ArenaAllocator,
    inter: text_api.FontHandle,
    rects: []const SceneRect,
    pixels: []const f32,
};

/// One ordinary label as this consumer rebuilt it from the tree, beside the
/// scene rectangles that landed on the pens that rebuild put down. The same
/// shape the slider audits build, for a node that publishes its own caption.
const LabelRebuild = struct {
    layout: ?frame.native.TextLayout = null,
    origin: [2]f32 = .{ 0, 0 },
    box: Area = .{},
    pens: std.ArrayList(GlyphPen) = .empty,
    matched: std.ArrayList(GlyphPen) = .empty,
    own: std.ArrayList(SceneRect) = .empty,

    fn deinit(self: *LabelRebuild, gpa: std.mem.Allocator) void {
        if (self.layout) |*layout| layout.deinit();
        self.pens.deinit(gpa);
        self.matched.deinit(gpa);
        self.own.deinit(gpa);
    }
};

/// The one label node that publishes these bytes under this authored policy.
/// The three truncation labels share their bytes on purpose, so the mode they
/// declared is what tells them apart, and the clamp label is named by the
/// clamp it declared.
fn findLabel(
    tree: *const nogui.widget.WidgetTree,
    bytes: []const u8,
    mode: ?text_api.TruncateMode,
    max_lines: ?usize,
) ?*const nogui.widget.WidgetNode {
    for (tree.nodes.items) |*node| {
        if (node.paint_hidden) continue;
        const label = switch (node.kind) {
            .label => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, label.text, bytes)) continue;
        const request = node.text_request orelse continue;
        const authored = request.paragraph();
        if (!std.meta.eql(authored.max_lines, max_lines)) continue;
        if (mode) |wanted| {
            const declared = authored.truncate orelse continue;
            if (declared.mode != wanted) continue;
        }
        return node;
    }
    return null;
}

/// Rebuild one ordinary label from what the TREE published, and mark the scene
/// rectangles that put a glyph quad on one of its pens.
///
/// Nothing here asks the scene how it resolved the caption. The bytes are the
/// node's own label, the request is the record the tree published, the width
/// is the column the tree laid this node out in, and the origin is that same
/// column with the text block centred in it — the arithmetic `captionLayout`
/// applies to every text-bearing node. Only the ANSWER comes back out of the
/// scene: the rectangles it submitted. A text pass that laid this label out
/// anywhere else finds no quad on any pen and the audit fails instead of
/// agreeing with itself.
fn buildLabel(
    audit: *LabelScene,
    node: *const nogui.widget.WidgetNode,
    content: []const u8,
    into: *LabelRebuild,
) !bool {
    const request = node.text_request orelse return false;
    if (content.len == 0) return false;
    const border = nogui.visualBorderRect(audit.tree, node.id);
    const column = textBox(audit.tree, node);
    if (column.w == 0 or column.h == 0) return false;
    into.box = .{ .x = border.x, .y = border.y, .w = border.w, .h = border.h };
    const layout = try audit.service.nodeLayoutIn(
        audit.arena.allocator(),
        content,
        request.*,
        .{
            // The column this node was laid out in, bounded by any cap the App
            // declared on it. A node that declared no cap flows in its column.
            .width = if (node.text_max_width) |maximum|
                @min(column.w, maximum)
            else
                column.w,
            .overflow = node.text_overflow,
            .suffix = scene.default_truncation_suffix,
        },
        host_default_size,
    );
    into.layout = layout;
    into.origin = .{
        column.x,
        column.y + @max(0, (column.h - layout.height) / 2),
    };
    try captionPens(audit.probe.gpa, &layout, into.origin, &into.pens);
    try matchCaptionQuads(audit.probe.gpa, audit.rects, node, into.pens.items, &into.matched);
    try collectNodeRects(audit.probe.gpa, audit.rects, into.box, &into.own);
    return true;
}

/// The colour one label's glyphs sit on, read off the frame: the pixels inside
/// its own box that none of its own rectangles cover. A label paints no
/// background of its own, so that is the surface the tree left it on, and only
/// what differs from THAT is this label's ink.
fn labelInk(
    probe: *Probe,
    pixels: []const f32,
    rebuild: LabelRebuild,
) ?Ink {
    const plate = plateUnder(pixels, rebuild.box, rebuild.own.items) orelse {
        probe.fail(
            "the label's box has one plain surface",
            "no colour covers the pixels its own rectangles leave free",
        );
        return null;
    };
    return .{ .pixels = pixels, .plate = plate };
}

/// The TWO-LINE clamp scenario.
///
/// One ordinary `ctx.label` declares a wrap width, a line height, a centred
/// alignment and an exact clamp of two lines over bytes that need three of
/// them. What the label PAINTED must be those two lines and no third, centred
/// in the width it declared, with the dropped line's bytes carrying no caret
/// position at all.
fn auditClampLabel(audit: *LabelScene) !void {
    const probe = audit.probe;
    const node = findLabel(audit.tree, clamp_text, null, clamp_lines) orelse {
        probe.fail(
            "the app tree carries the two-line clamp",
            "no label declares the clamp bytes under a two-line clamp",
        );
        return;
    };
    const request = node.text_request orelse {
        probe.fail(
            "the clamp label resolved a request",
            "the clamp label published no text record at all",
        );
        return;
    };
    // The declaration as the TREE published it, read off the record the paint
    // path was handed rather than off the call site.
    const authored = request.paragraph();
    probe.eq("the clamp label authored the exact clamp", authored.max_lines, @as(?usize, clamp_lines));
    probe.eq("the clamp label authored the exact wrap width", authored.wrap_width, @as(?f32, clamp_wrap));
    probe.eq(
        "the clamp label authored the centred alignment",
        authored.alignment,
        @as(?text_api.Align, .center),
    );
    probe.ok("the clamp label declares no truncation policy", authored.truncate == null);

    var rebuild: LabelRebuild = .{};
    defer {
        rebuild.deinit(probe.gpa);
        _ = audit.arena.reset(.retain_capacity);
    }
    probe.ok(
        "the clamp label reached the scene text pass",
        try buildLabel(audit, node, clamp_text, &rebuild) and rebuild.matched.items.len > 0,
    );
    if (rebuild.layout == null) {
        probe.fail("the clamp label laid out", "the rebuild produced no layout");
        return;
    }
    const layout = &rebuild.layout.?;
    var face_seen = false;
    for (layout.runs) |run| {
        if (std.meta.eql(run.font, audit.inter)) face_seen = true;
    }
    probe.ok("the clamp label shapes with the pinned primary face", face_seen);

    // How many lines these bytes need at the width the label declared. The
    // SAME authored text, the SAME face and the SAME wrap width with NO clamp:
    // whatever the clamp dropped, the content itself still declares it.
    var unclamped = try audit.service.layout(probe.gpa, .{
        .content = clamp_text,
        .style = .{ .font = .{ .handle = audit.inter, .size = clamp_size } },
        .paragraph = .{
            .wrap_width = clamp_wrap,
            .line_height = clamp_line_height,
            .alignment = .center,
        },
    });
    defer unclamped.deinit();
    probe.ok(
        "the clamp dropped real lines of its own content",
        unclamped.lines.len > clamp_lines,
    );
    probe.eq("the clamp shows exactly the lines it declares", layout.lines.len, clamp_lines);
    probe.near(
        "the clamped block is exactly its two visible lines tall",
        layout.height,
        layout.lines[clamp_lines - 1].y + layout.lines[clamp_lines - 1].height,
        0.01,
    );
    // A grapheme that lives only on the line the clamp threw away has no
    // position: the content past the clamp is not folded back onto the last
    // visible line.
    const dropped = std.mem.indexOf(u8, clamp_text, clamp_dropped_line).?;
    expectError(
        probe,
        "a byte on a clamped line",
        error.HiddenText,
        layout.byteToPosition(dropped, .downstream),
    );
    // Every visible line stays inside the width the label declared, and the
    // alignment is measured against THAT width, not against a box this audit
    // chose for itself.
    for (layout.lines) |line| {
        probe.ok("a clamped line fits the authored wrap width", line.width <= clamp_wrap + 0.01);
        probe.near(
            "a clamped line is centred in the authored wrap width",
            line.x,
            (clamp_wrap - line.width) / 2,
            0.01,
        );
        probe.near(
            "a centred line's right edge mirrors its left",
            line.x + line.width,
            clamp_wrap - line.x,
            0.01,
        );
    }

    // The two lines PAINTED, at the boxes their own glyph quads claimed.
    const ink = labelInk(probe, audit.pixels, rebuild) orelse return;
    probe.eq(
        "the clamp label rides exactly the lines it declares",
        captionBaselines(rebuild.matched.items),
        clamp_lines,
    );
    for (layout.lines) |line| {
        const band: Area = .{
            .x = rebuild.origin[0] + line.x,
            .y = rebuild.origin[1] + line.y,
            .w = line.width,
            .h = line.height,
        };
        probe.ok("a clamped line painted pixels inside its own measured box", inkIn(ink, band) > 0);
    }
    const window = captionInk(ink, rebuild.matched.items) orelse {
        probe.fail(
            "the clamp label painted pixels",
            "nothing changed inside the boxes its own glyph quads claimed",
        );
        return;
    };
    probe.emit(
        "offscreen_consumer: clamp quads={d} pens={d} baselines={d} lines={d}/{d} height={d:.2} wrap={d:.1} ink=({d:.1},{d:.1},{d:.1},{d:.1})\n",
        .{
            rebuild.matched.items.len,
            rebuild.pens.items.len,
            captionBaselines(rebuild.matched.items),
            layout.lines.len,
            unclamped.lines.len,
            layout.height,
            clamp_wrap,
            window.x,
            window.y,
            window.w,
            window.h,
        },
    );
    // Centring, read off the TARGET. The painted block's own slack at the left
    // of the authored wrap width and at its right must be the same slack: two
    // lines of very different widths, centred, leave equal margins, and a
    // flow that dropped the alignment leaves one margin at nothing.
    const left = window.x - rebuild.origin[0];
    const right = rebuild.origin[0] + clamp_wrap - (window.x + window.w);
    probe.ok(
        "the painted block is centred in the authored wrap width",
        left >= -bleed and right >= -bleed and @abs(left - right) <= 3 * bleed,
    );
}

/// One of the START / MIDDLE / END truncation scenarios. All three labels
/// declare the same bytes at the same size under the same explicit suffix, so
/// what each one PAINTED has to say which end of those bytes survived and
/// where its suffix landed on the line.
fn auditTruncationLabel(audit: *LabelScene, mode: text_api.TruncateMode) !void {
    const probe = audit.probe;
    const node = findLabel(audit.tree, truncation_text, mode, null) orelse {
        probe.fail(
            "the app tree carries a truncation label",
            "no label declares the truncation bytes under that mode",
        );
        return;
    };
    const request = node.text_request orelse {
        probe.fail(
            "the truncation label resolved a request",
            "the truncation label published no text record at all",
        );
        return;
    };
    const authored = request.paragraph();
    const declared = authored.truncate orelse {
        probe.fail(
            "the truncation label authored a suffix",
            "the published record carries no truncation policy",
        );
        return;
    };
    probe.eq("the label authored the exact mode", declared.mode, mode);
    probe.ok(
        "the label authored the explicit suffix bytes",
        std.mem.eql(u8, declared.suffix, truncation_suffix),
    );
    probe.eq(
        "the label authored the bound it cuts at",
        authored.wrap_width,
        @as(?f32, truncation_width),
    );
    probe.eq(
        "the label authored a no-wrap flow",
        authored.wrap,
        @as(?text_api.Wrap, .no_wrap),
    );

    var rebuild: LabelRebuild = .{};
    defer {
        rebuild.deinit(probe.gpa);
        _ = audit.arena.reset(.retain_capacity);
    }
    probe.ok(
        "the truncation label reached the scene text pass",
        try buildLabel(audit, node, truncation_text, &rebuild) and rebuild.matched.items.len > 0,
    );
    if (rebuild.layout == null) {
        probe.fail("the truncation label laid out", "the rebuild produced no layout");
        return;
    }
    const layout = &rebuild.layout.?;

    probe.eq("a truncated paragraph paints one line", layout.lines.len, 1);
    probe.ok(
        "the painted line fits the bound the label declared",
        layout.lines[0].width <= truncation_width + 0.01,
    );
    probe.ok(
        "the content is wider than the bound it was cut at",
        layout.inkWidth() > truncation_width,
    );
    probe.eq("the truncated label rides one baseline", captionBaselines(rebuild.matched.items), 1);

    // The runs the layout itself marked as the suffix, in the order it put
    // them on the line. WHICH end of the authored bytes survived is a property
    // of the mode, and it is read off the byte ranges the layout reports
    // against the bytes the label itself declared.
    const line = layout.lines[0];
    const line_runs = layout.runs[line.first_run..line.end_run];
    var suffix_index: ?usize = null;
    var keeps_head = false;
    var keeps_tail = false;
    for (line_runs, 0..) |run, index| {
        if (run.is_suffix) {
            if (suffix_index != null) {
                probe.fail("one suffix run", "the painted line carries more than one");
            }
            suffix_index = index;
            probe.ok(
                "the suffix run carries the authored suffix bytes",
                std.mem.eql(u8, run.text, truncation_suffix),
            );
            probe.ok("the suffix run paints real glyphs", !run.missing_glyph);
            continue;
        }
        if (run.start == 0) keeps_head = true;
        if (run.end == truncation_text.len) keeps_tail = true;
    }
    const at = suffix_index orelse {
        probe.fail(
            "the truncated label carries its suffix",
            "no run on the painted line is marked as the suffix",
        );
        return;
    };
    switch (mode) {
        .start => {
            probe.ok("a start-truncated line keeps the tail of its bytes", keeps_tail);
            probe.ok("a start-truncated line drops the head of its bytes", !keeps_head);
            probe.eq("a start-truncated line opens with its suffix", at, 0);
        },
        .middle => {
            probe.ok("a middle-truncated line keeps the head of its bytes", keeps_head);
            probe.ok("a middle-truncated line keeps the tail of its bytes", keeps_tail);
            probe.ok(
                "a middle-truncated line puts its suffix off both ends",
                at > 0 and at + 1 < line_runs.len,
            );
        },
        .end => {
            probe.ok("an end-truncated line keeps the head of its bytes", keeps_head);
            probe.ok("an end-truncated line drops the tail of its bytes", !keeps_tail);
            probe.eq("an end-truncated line closes with its suffix", at, line_runs.len - 1);
        },
    }

    // The suffix and the bytes the mode kept, painted at the boxes their own
    // shaped runs claimed.
    const ink = labelInk(probe, audit.pixels, rebuild) orelse return;
    const suffix = suffixBand(layout, rebuild.origin);
    probe.ok("the truncation suffix painted pixels", inkIn(ink, suffix) > 0);
    var kept_ink = false;
    for (line_runs) |run| {
        if (run.is_suffix) continue;
        const box: Area = .{
            .x = rebuild.origin[0] + run.x,
            .y = rebuild.origin[1] + run.baseline - run.font_metrics.ascent,
            .w = run.width,
            .h = run.font_metrics.ascent - run.font_metrics.descent,
        };
        if (inkIn(ink, box) > 0) kept_ink = true;
    }
    probe.ok("the bytes the mode kept painted pixels", kept_ink);
    const window = captionInk(ink, rebuild.matched.items) orelse {
        probe.fail(
            "the truncation label painted pixels",
            "nothing changed inside the boxes its own glyph quads claimed",
        );
        return;
    };
    const line_left = rebuild.origin[0] + line.x;
    const line_right = line_left + line.width;
    probe.ok(
        "the truncated line stayed inside the bound it declared",
        window.x >= line_left - bleed and window.x + window.w <= line_right + bleed,
    );
    // Where the suffix landed, read off the target: against the line's own
    // measured edges, which is where the layout says the cut was.
    switch (mode) {
        .start => probe.near(
            "the painted suffix opens at the line's left edge",
            suffix.x,
            line_left,
            bleed,
        ),
        .middle => probe.ok(
            "the painted suffix sits between the two pieces the mode kept",
            suffix.x > line_left + bleed and suffix.x + suffix.w < line_right - bleed,
        ),
        .end => probe.near(
            "the painted suffix ends at the line's right edge",
            suffix.x + suffix.w,
            line_right,
            bleed,
        ),
    }
    probe.emit(
        "offscreen_consumer: truncate mode={s} quads={d} pens={d} runs={d} suffix_run={d} width={d:.2}/{d:.1} ink=({d:.1},{d:.1},{d:.1},{d:.1}) suffix=({d:.1},{d:.1})\n",
        .{
            @tagName(mode),
            rebuild.matched.items.len,
            rebuild.pens.items.len,
            line_runs.len,
            at,
            line.width,
            truncation_width,
            window.x,
            window.y,
            window.w,
            window.h,
            suffix.x,
            suffix.x + suffix.w,
        },
    );
}

fn auditTruncationLabels(audit: *LabelScene) !void {
    for (truncation_modes) |mode| try auditTruncationLabel(audit, mode);
}

/// The bytes one label node shows.
fn labelBytes(node: *const nogui.widget.WidgetNode) []const u8 {
    return switch (node.kind) {
        .label => |value| value.text,
        else => "",
    };
}

/// What one frame PUBLISHED about its clamp label: the box the tree laid the
/// label out in and the immutable policy its record carries. Captured while
/// that frame is current and read back after a newer frame commits.
const ClampRecord = struct {
    rect: [4]f32,
    font_size: f32,
    max_lines: ?usize,
    wrap_width: ?f32,
    alignment: text_api.Align,

    fn read(tree: *const nogui.widget.WidgetTree, node: *const nogui.widget.WidgetNode) ClampRecord {
        const request = node.text_request.?;
        const authored = request.paragraph();
        const box = nogui.visualBorderRect(tree, node.id);
        return .{
            .rect = .{ box.x, box.y, box.w, box.h },
            .font_size = request.fontSize(),
            .max_lines = authored.max_lines,
            .wrap_width = authored.wrap_width,
            .alignment = authored.alignment orelse .start,
        };
    }

    fn eql(a: ClampRecord, b: ClampRecord) bool {
        return std.meta.eql(a.rect, b.rect) and a.font_size == b.font_size and
            std.meta.eql(a.max_lines, b.max_lines) and
            std.meta.eql(a.wrap_width, b.wrap_width) and
            a.alignment == b.alignment;
    }
};

/// The shape of one immutable layout, read at two moments around a new frame:
/// how many lines and runs it holds, how wide it measured, and what its first
/// shaped glyph is. Enough to tell a layout that survived intact from one that
/// was rebuilt or released underneath the reader.
const LayoutShape = struct {
    lines: usize,
    width: f32,
    runs: usize,
    glyphs: usize,
    first_gid: u32,
    first_advance: f32,

    fn read(layout: *const frame.native.TextLayout) LayoutShape {
        var glyphs: usize = 0;
        for (layout.runs) |run| glyphs += run.glyphs.len;
        const first = if (layout.runs.len == 0 or layout.runs[0].glyphs.len == 0)
            null
        else
            layout.runs[0].glyphs[0];
        return .{
            .lines = layout.lines.len,
            .width = layout.width,
            .runs = layout.runs.len,
            .glyphs = glyphs,
            .first_gid = if (first) |glyph| glyph.gid else 0,
            .first_advance = if (first) |glyph| glyph.x_advance else 0,
        };
    }

    fn eql(a: LayoutShape, b: LayoutShape) bool {
        return a.lines == b.lines and a.width == b.width and a.runs == b.runs and
            a.glyphs == b.glyphs and a.first_gid == b.first_gid and
            a.first_advance == b.first_advance;
    }
};

/// The previous frame's OWN record and layout, read back AFTER a frame with
/// DIFFERENT authored data has committed.
///
/// The previous tree is the documented previous-frame snapshot and the record
/// pointer is the very one the previous frame published, so every read below
/// answers what THAT frame authored. A frame that rebuilt its arena underneath
/// that record, reused the record for new bytes, or disturbed the shapes the
/// earlier layout still pins changes what these reads answer — and the new
/// frame's own label has to carry the new bytes and the new clamp, or this
/// compares two identical frames and proves nothing.
fn auditPreviousFrame(
    probe: *Probe,
    service: *frame.native.TextService,
    request: text_api.LayoutRequest,
    first_tree: *const nogui.widget.WidgetTree,
    prev_tree: ?*const nogui.widget.WidgetTree,
    current_tree: *const nogui.widget.WidgetTree,
    first_record: *const text_api.NodeText,
    first_value: ClampRecord,
    first_shape: LayoutShape,
    first_layout: *const frame.native.TextLayout,
) !void {
    const old_tree = prev_tree orelse {
        probe.fail(
            "the second frame kept the first frame's tree",
            "the second frame published no previous snapshot",
        );
        return;
    };
    probe.ok("the second frame kept the first frame's tree readable", old_tree == first_tree);

    // The record pointer the first frame published, read directly. The same
    // address has to answer with the same policy now that a newer frame has
    // committed over it.
    const published = first_record.paragraph();
    probe.ok(
        "the previous frame's record is still readable",
        published.max_lines != null and published.wrap_width != null,
    );
    probe.ok(
        "the previous frame's record is unchanged",
        std.meta.eql(published.max_lines, first_value.max_lines) and
            std.meta.eql(published.wrap_width, first_value.wrap_width) and
            (published.alignment orelse .start) == first_value.alignment and
            first_record.fontSize() == first_value.font_size,
    );
    // And through the previous tree's own label, which still has to point at
    // that record and still have to carry that frame's bytes.
    const old_node = findLabel(old_tree, clamp_text, null, clamp_lines) orelse {
        probe.fail(
            "the previous frame's clamp label is still in its own tree",
            "no label declares the first frame's bytes under the first frame's clamp",
        );
        return;
    };
    const old_record = old_node.text_request orelse {
        probe.fail(
            "the previous frame's clamp label still holds a record",
            "its own tree carries no published text record for it",
        );
        return;
    };
    probe.ok("the previous frame's label still points at the record it published", old_record == first_record);
    probe.ok("the previous frame's label still carries its own bytes", std.mem.eql(u8, labelBytes(old_node), clamp_text));
    probe.ok(
        "the previous frame's label laid out the same box",
        ClampRecord.read(old_tree, old_node).eql(first_value),
    );

    // The new frame's own label: new bytes under a new clamp, published into
    // its own record. Anything else means the change never reached the tree.
    const new_node = findLabel(current_tree, clamp_text_next, null, clamp_lines_next) orelse {
        probe.fail(
            "the new frame published the clamp bytes it authored",
            "no label declares the next frame's bytes under the next frame's clamp",
        );
        return;
    };
    probe.ok("the new frame's clamp label carries new bytes", std.mem.eql(u8, labelBytes(new_node), clamp_text_next));
    probe.ok(
        "the new frame's clamp record differs as authored",
        !ClampRecord.read(current_tree, new_node).eql(first_value),
    );
    const new_record = new_node.text_request orelse {
        probe.fail(
            "the new frame's clamp label published a record",
            "the label carrying the new bytes resolved no text request",
        );
        return;
    };
    probe.ok(
        "the new frame's clamp label publishes a record of its own",
        new_record != first_record,
    );
    const new_value = ClampRecord.read(current_tree, new_node);

    // The layout this consumer built before that frame: its leases pinned its
    // shapes across the commit, so it is still readable, still the same layout,
    // and the same request costs no shaping a second time.
    probe.ok(
        "the previous frame's layout is still readable and unchanged",
        LayoutShape.read(first_layout).eql(first_shape),
    );
    const shapes_before = service.shapeCount();
    var repeat = try service.layout(probe.gpa, request);
    defer repeat.deinit();
    probe.eq("the shapes the previous layout holds are still resident", service.shapeCount(), shapes_before);
    probe.ok(
        "the previous frame's layout still measures the same",
        LayoutShape.read(&repeat).eql(first_shape),
    );
    probe.emit(
        "offscreen_consumer: frame2 clamp={d}->{d} layout=({d},{d},{d},{d}) shapes={d}\n",
        .{
            first_value.max_lines.?,
            new_value.max_lines.?,
            first_shape.lines,
            first_shape.runs,
            first_shape.glyphs,
            first_shape.first_gid,
            shapes_before,
        },
    );
}

// ── Slider captions ─────────────────────────────────────────────────────

/// One slider's boxes: the border box the tree laid it out in, and the text
/// column its caption is measured and painted in. The column is the visual
/// CONTENT rect minus the SAME inset table the scene text pass and the
/// measure decoration apply, so the audit and the paint path cannot disagree
/// about where the text starts.
const SliderBox = struct {
    border: Area,
    column: Area,
};

fn sliderBox(tree: *const nogui.widget.WidgetTree, node: *const nogui.widget.WidgetNode) SliderBox {
    const border_rect = nogui.visualBorderRect(tree, node.id);
    return .{
        .border = .{
            .x = border_rect.x,
            .y = border_rect.y,
            .w = border_rect.w,
            .h = border_rect.h,
        },
        .column = textBox(tree, node),
    };
}

fn sceneArea(rect: SceneRect) Area {
    return .{ .x = rect.dst[0], .y = rect.dst[1], .w = rect.dst[2], .h = rect.dst[3] };
}

/// The one slider node that declares these caption bytes over this range.
/// Named by bytes AND range on purpose: the bounded and the uncapped slider
/// declare the same text, so the range is what tells them apart.
fn findSlider(
    tree: *const nogui.widget.WidgetTree,
    label: []const u8,
    max: f32,
) ?*const nogui.widget.WidgetNode {
    for (tree.nodes.items) |*node| {
        if (node.paint_hidden) continue;
        const s = switch (node.kind) {
            .slider => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, s.label, label)) continue;
        if (s.max != max) continue;
        return node;
    }
    return null;
}

/// Nothing from the root down to this slider publishes a text record. An
/// inherited `default_text` anywhere on this path would publish one and stand
/// in for the widget kind's own default foreground, so the ordinary slider's
/// scenario would pass for the wrong reason.
fn noInheritedText(tree: *const nogui.widget.WidgetTree, node: *const nogui.widget.WidgetNode) bool {
    var cursor = node;
    while (cursor.parent != .root) {
        const parent = tree.nodeConst(cursor.parent) orelse return false;
        if (parent.text_request != null) return false;
        cursor = parent;
    }
    return true;
}

/// Every rectangle one node's OWN submission put inside this node's border
/// box, in the scene's own submission order.
///
/// The scene rect list holds ONLY the control chrome and the glyphs the text
/// pass emitted: a node background is a PaintList record, lowered into the
/// renderer's own buffer and never a scene rect. So nothing here has to be
/// told apart from the plate, and the plate is what the frame itself carries
/// where none of these rectangles reached.
///
/// The filter is a strict overlap with THIS node's box. The row leaves an
/// eight-pixel gap and a glyph quad carries a two-pixel raster margin, so no
/// neighbour's rectangle can reach a pixel inside this box; and a hover or
/// focus ring that happens to sit exactly on the box still counts as this
/// node's own surface rather than as plate. It is the CALLER's list: the pixel
/// audit reads the plate from the pixels these rectangles leave free, so it
/// has to hold every rectangle this node submitted.
fn collectNodeRects(
    gpa: std.mem.Allocator,
    rects: []const SceneRect,
    border: Area,
    into: *std.ArrayList(SceneRect),
) !void {
    into.clearRetainingCapacity();
    for (rects) |rect| {
        const area = sceneArea(rect);
        if (area.x + area.w <= border.x or area.x >= border.x + border.w) continue;
        if (area.y + area.h <= border.y or area.y >= border.y + border.h) continue;
        try into.append(gpa, rect);
    }
}

/// Whether one submitted rectangle samples a glyph's analytic outline. Slot 0
/// is the solid material, every rasterized glyph takes a slot from 1 up to the
/// host's glyph ceiling, and the per-frame decoration ring the control chrome
/// draws from starts AT that ceiling. The material index is therefore the
/// MATERIAL evidence that separates a glyph quad from a solid and from a
/// control rectangle, and it is the engine's own reservation rather than a
/// guess about which widget happened to paint.
fn isGlyphSlot(rect: SceneRect) bool {
    return rect.material_index != 0 and rect.material_index < scene.glyph_material_ceiling;
}

/// Whether one submitted rectangle took a material from this frame's decoration
/// ring: a thumb, a progress fill, a hover or a focus ring. Those are CONTROL
/// rectangles whatever box they cover, and no glyph ever draws there.
fn isDecorationSlot(rect: SceneRect) bool {
    return rect.material_index >= scene.glyph_material_ceiling;
}

/// One shaped glyph of ONE caption: the pen origin the engine stamps on its
/// quad, the baseline that pen rides, and the box that quad claimed. The emit
/// path snaps each run's origin and baseline onto the device grid and
/// accumulates exactly the advances the layout measured, so this is the quad's
/// own `origin` field — geometry derived from the shaped run, not a box that
/// merely overlaps the caption.
const GlyphPen = struct {
    origin: [2]f32,
    baseline: f32,
    /// The box the engine submitted for this glyph: the caption's OWN painted
    /// footprint. It is the window the caption's ink has to be read in, and
    /// not the whole node box, because a node edge that falls inside a pixel
    /// leaves that pixel carrying the PARENT's surface.
    box: Area = .{},
    taken: bool = false,
};

/// Every pen this caption's own layout put on the target. A glyph with no
/// outline (a space, a blank face) submits nothing, so a pen with no quad
/// behind it is a legitimate absence rather than a missing rectangle.
fn captionPens(
    gpa: std.mem.Allocator,
    layout: anytype,
    origin: [2]f32,
    into: *std.ArrayList(GlyphPen),
) !void {
    into.clearRetainingCapacity();
    for (layout.runs) |run| {
        // A 1x device grid snaps the run origin and the baseline.
        const run_x = @round(origin[0] + run.x);
        const baseline = @round(origin[1] + run.baseline);
        var pen: f32 = 0;
        for (run.glyphs) |glyph| {
            // A codepoint no face covers is drawn as four SOLID strokes.
            if (glyph.gid != 0) try into.append(gpa, .{
                .origin = .{ run_x + pen + glyph.x_offset, baseline - glyph.y_offset },
                .baseline = baseline,
            });
            pen += glyph.x_advance;
        }
    }
}

/// The caption's own glyph quads, in the scene's own submission order: the
/// glyph-slot rectangles that ride this node's OWN clip and layer and whose
/// origin is one of THIS caption's pens. A glyph quad that matches no pen
/// belongs to something else — a control rectangle, a neighbouring node's
/// caption, the specimen — and a pen with no quad behind it is a glyph the
/// engine had no outline for. Nothing is selected by a box that happens to
/// overlap the caption.
fn matchCaptionQuads(
    gpa: std.mem.Allocator,
    rects: []const SceneRect,
    node: *const nogui.widget.WidgetNode,
    pens: []GlyphPen,
    matched: *std.ArrayList(GlyphPen),
) !void {
    matched.clearRetainingCapacity();
    for (rects) |rect| {
        // The text pass stamps every rectangle of one node with that node's
        // clip and layer, so a rectangle riding another node's clip or layer
        // is never this caption's whatever origin it carries.
        if (!isGlyphSlot(rect)) continue;
        if (rect.clip_id != node.clip_id or rect.z != node.paint.layer) continue;
        for (pens) |*pen| {
            if (pen.taken) continue;
            if (@abs(rect.origin[0] - pen.origin[0]) > 0.001 or
                @abs(rect.origin[1] - pen.origin[1]) > 0.001) continue;
            pen.taken = true;
            pen.box = sceneArea(rect);
            try matched.append(gpa, pen.*);
            break;
        }
    }
}

/// How many baselines the caption's own glyph quads ride. A truncation policy
/// is a SINGLE truncated line, so a bounded caption must ride exactly one:
/// the bytes it declares are wider than the cap it declares, so a dropped
/// `text_overflow` does not truncate them, it WRAPS them onto a second
/// baseline. Quads arrive in the scene's own submission order, line by line.
fn captionBaselines(matched: []const GlyphPen) usize {
    var count: usize = 0;
    var last: f32 = 0;
    var named = false;
    for (matched) |pen| {
        if (named and pen.baseline == last) continue;
        count += 1;
        last = pen.baseline;
        named = true;
    }
    return count;
}

/// The ink at the boxes THIS caption's own quads claimed.
///
/// A node's own box is not a safe window to read a caption's ink in. Where the
/// node's edge falls inside a pixel, that pixel carries the PARENT's surface
/// — a row or column the node never painted — and it differs from this node's
/// plate, so a column-wide ink box reports the NODE's fractional edges at the
/// top and the bottom instead of the caption. The matched quads are the
/// engine's own answer for this caption, and their union is exactly the
/// window it painted into.
fn captionInk(ink: anytype, pens: []const GlyphPen) ?Area {
    var window: Area = .{};
    var named = false;
    for (pens) |pen| {
        if (pen.box.w <= 0 or pen.box.h <= 0) continue;
        window = if (named) .{
            .x = @min(window.x, pen.box.x),
            .y = @min(window.y, pen.box.y),
            .w = @max(window.x + window.w, pen.box.x + pen.box.w) - @min(window.x, pen.box.x),
            .h = @max(window.y + window.h, pen.box.y + pen.box.h) - @min(window.y, pen.box.y),
        } else pen.box;
        named = true;
    }
    if (!named) return null;
    return inkBox(ink, window);
}

/// The control rectangles this node's own submission put inside its box, read
/// off the material ring they took. They are part of the slider's SURFACE, so a
/// pixel one of them covers is never this caption's ink.
fn collectChromeRects(
    gpa: std.mem.Allocator,
    own: []const SceneRect,
    into: *std.ArrayList(Area),
) !void {
    into.clearRetainingCapacity();
    for (own) |rect| {
        if (!isDecorationSlot(rect)) continue;
        try into.append(gpa, sceneArea(rect));
    }
}

/// What counts as ink inside one slider's own column: a pixel that changed from
/// the plate this node was painted on AND that none of this node's control
/// rectangles covers. The chrome is excluded by GEOMETRY, off the node's own
/// submission, so the WHOLE column can be read — a thumb can no longer count as
/// text, and a caption's painted span can be measured against the cap the App
/// declared instead of against a band this audit chose for itself.
const SliderInk = struct {
    pixels: []const f32,
    plate: [4]f32,
    chrome: []const Area,

    fn at(self: SliderInk, x: usize, y: usize) bool {
        // A pixel is inside a rectangle when its CENTRE is. Testing the
        // pixel's own corner against a half-open box lets every row and column
        // a fractional edge cuts through stay outside the test, so a thumb
        // whose top edge sits at 84.3 would leave its whole first row reading
        // as ink.
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        for (self.chrome) |rect| {
            if (px >= rect.x and px < rect.x + rect.w and
                py >= rect.y and py < rect.y + rect.h) return false;
        }
        const index = (y * @as(usize, extent.width) + x) * 4;
        const pixel = self.pixels[index..][0..4];
        return pixel[0] != self.plate[0] or
            pixel[1] != self.plate[1] or
            pixel[2] != self.plate[2];
    }
};

/// The part of this slider's own text column the control chrome cannot reach:
/// what is left of the column once every chrome rectangle the node actually
/// submitted is taken off its right edge. The progress fill paints nothing at a
/// range minimum, so what is left begins past the thumb.
fn pastChrome(column: Area, chrome: []const Area) Area {
    var left = column.x;
    for (chrome) |rect| left = @max(left, rect.x + rect.w + slider_slack);
    return .{
        .x = left,
        .y = column.y,
        .w = @max(0, column.x + column.w - left),
        .h = column.h,
    };
}

/// The colour this slider's caption glyphs sit on. It is read off the frame —
/// the pixels inside the slider's own box that NONE of its own rectangles
/// cover, which is its own background fill and nothing else — and then held
/// against the fill the App authored. The plate under a caption is therefore
/// a named surface, not an assumption about the clear colour.
fn sliderInk(
    probe: *Probe,
    pixels: []const f32,
    own: []const SceneRect,
    border: Area,
    chrome: []const Area,
) ?SliderInk {
    const plate = plateUnder(pixels, border, own) orelse {
        probe.fail(
            "the slider's box has one plain surface",
            "no colour covers the pixels its own rectangles leave free",
        );
        return null;
    };
    const authored = frame.srgbToOklab(slider_plate);
    probe.near("the slider plate lightness", plate[0], authored[0], 0.01);
    probe.near("the slider plate green axis", plate[1], authored[1], 0.01);
    probe.near("the slider plate blue axis", plate[2], authored[2], 0.01);
    return .{ .pixels = pixels, .plate = plate, .chrome = chrome };
}

/// The span the truncation suffix occupies on the line this layout put it on:
/// the shaped advances of every run the layout itself marked as the suffix,
/// walked in the origin the engine emitted the layout at. A glyph with no
/// advance submits nothing, so it is skipped. The vertical band is those runs'
/// own ascent-to-descent extent: where their ink is, and where nothing else on
/// the line lands. A caption the declaration did not truncate carries no
/// suffix run at all, so the band is the empty one rather than the tail of its
/// last word.
fn suffixBand(layout: anytype, origin: [2]f32) Area {
    var band: Area = .{};
    var named = false;
    for (layout.runs) |run| {
        if (!run.is_suffix) continue;
        var pen: f32 = 0;
        var left: ?f32 = null;
        for (run.glyphs) |glyph| {
            if (glyph.x_advance <= 0) continue;
            if (left == null) left = pen;
            pen += glyph.x_advance;
        }
        const start = left orelse continue;
        const area: Area = .{
            .x = origin[0] + run.x + start,
            .y = origin[1] + run.baseline - run.font_metrics.ascent,
            .w = @max(0, pen - start),
            .h = run.font_metrics.ascent - run.font_metrics.descent,
        };
        band = if (named) .{
            .x = @min(band.x, area.x),
            .y = @min(band.y, area.y),
            .w = @max(band.x + band.w, area.x + area.w) - @min(band.x, area.x),
            .h = @max(band.y + band.h, area.y + area.h) - @min(band.y, area.y),
        } else area;
        named = true;
    }
    return band;
}

/// Everything the slider caption audits read: the tree the App built, the
/// rectangles the scene submitted for it, the read-back pixels and the pinned
/// face those captions are shaped with. One audit object owns one scratch
/// rectangle list, reused by every scenario.
const SliderAudit = struct {
    probe: *Probe,
    tree: *const nogui.widget.WidgetTree,
    service: *frame.native.TextService,
    arena: *std.heap.ArenaAllocator,
    inter: text_api.FontHandle,
    rects: []const SceneRect,
    pixels: []const f32,
    own: *std.ArrayList(SceneRect),
};

/// One slider caption as this consumer rebuilt it from the tree, beside the
/// scene rectangles that landed on the pens that rebuild put down. The layout
/// is the consumer's own measurement through the PUBLIC node seam, so what is
/// held against the frame is the tree's box and the App's declaration rather
/// than the scene's own arithmetic. `matched` is what the scene answered.
const SliderCaption = struct {
    layout: ?frame.native.TextLayout = null,
    origin: [2]f32 = .{ 0, 0 },
    pens: std.ArrayList(GlyphPen) = .empty,
    matched: std.ArrayList(GlyphPen) = .empty,

    fn deinit(self: *SliderCaption, gpa: std.mem.Allocator) void {
        if (self.layout) |*layout| layout.deinit();
        self.pens.deinit(gpa);
        self.matched.deinit(gpa);
    }
};

/// Rebuild this node's caption from what the TREE published and what the APP
/// declared, and mark the scene rectangles that put a glyph quad on one of its
/// pens.
///
/// Nothing here asks the scene how it resolved the caption. The bytes are the
/// node's own visual label, the request is the record the tree published, the
/// width is this node's text column bounded by the cap the App declared on it,
/// and the origin is that same column with the text block centred in it. Only
/// the ANSWER comes back out of the scene — the rectangles it submitted — so a
/// text pass that lays this caption out anywhere else finds no quad on any pen
/// and the scenario fails instead of agreeing with itself. The pinned face is
/// already the one the App and the scene both resolve this node with, so
/// nothing here re-chooses a font, a policy or a width.
fn buildSliderCaption(
    audit: *SliderAudit,
    node: *const nogui.widget.WidgetNode,
    boxes: SliderBox,
    gpa: std.mem.Allocator,
    into: *SliderCaption,
) !bool {
    const request = node.text_request orelse return false;
    const content = nogui.widget.sliderVisualLabel(node.kind);
    if (content.len == 0) return false;
    const layout = try audit.service.nodeLayoutIn(
        audit.arena.allocator(),
        content,
        request.*,
        .{
            // The column this node was laid out in, bounded by the cap the App
            // declared on it. A node that declared no cap flows in its column.
            .width = if (node.text_max_width) |maximum|
                @min(boxes.column.w, maximum)
            else
                boxes.column.w,
            .overflow = node.text_overflow,
            .suffix = scene.default_truncation_suffix,
        },
        host_default_size,
    );
    into.layout = layout;
    // The block is centred in the very box this column names, so the origin the
    // glyphs carry is that column's top-left corner moved down by the offset.
    into.origin = .{
        boxes.column.x,
        boxes.column.y + @max(0, (boxes.column.h - layout.height) / 2),
    };
    try captionPens(gpa, &layout, into.origin, &into.pens);
    try matchCaptionQuads(gpa, audit.rects, node, into.pens.items, &into.matched);
    return true;
}

/// The ORDINARY slider scenario. Its caption is authored with nothing but a
/// key, its bytes, a live value, a valid range and a background, so the
/// widget kind's own default foreground is the only layer that can give it a
/// record. That record must be published, the caption must reach the scene's
/// text pass, and its glyphs must paint inside its own column.
fn auditDefaultSliderCaption(audit: *SliderAudit) !void {
    const probe = audit.probe;
    const node = findSlider(audit.tree, slider_default_label, 100) orelse {
        probe.fail(
            "the app tree carries the ordinary slider",
            "no slider node declares the ordinary caption bytes over that range",
        );
        return;
    };
    probe.ok("the ordinary slider inherits no text record", noInheritedText(audit.tree, node));
    // The widget kind's own caption colour is the layer that gave this record a
    // foreground at all: nothing on the path above it authors one and this
    // node authors none either, so the resolved request must carry exactly the
    // colour the slider's own kind declares.
    const request = node.text_request orelse {
        probe.fail(
            "the ordinary slider's caption resolved a request",
            "the slider node published no text record at all",
        );
        return;
    };
    probe.eq(
        "the ordinary caption carries the widget kind's own foreground",
        request.style.foreground,
        node.kind.slider.color,
    );

    const boxes = sliderBox(audit.tree, node);
    try collectNodeRects(probe.gpa, audit.rects, boxes.border, audit.own);
    var chrome: std.ArrayList(Area) = .empty;
    defer chrome.deinit(probe.gpa);
    try collectChromeRects(probe.gpa, audit.own.items, &chrome);
    var ordinary: SliderCaption = .{};
    defer {
        ordinary.deinit(probe.gpa);
        _ = audit.arena.reset(.retain_capacity);
    }
    probe.ok(
        "the ordinary slider caption reached the scene text pass",
        try buildSliderCaption(audit, node, boxes, probe.gpa, &ordinary) and
            ordinary.matched.items.len > 0,
    );

    const ink = sliderInk(probe, audit.pixels, audit.own.items, boxes.border, chrome.items) orelse return;
    const band = pastChrome(boxes.column, chrome.items);
    probe.ok(
        "the ordinary slider's caption column lies past its own chrome",
        band.w > 0 and band.h > 0,
    );
    // The whole column is read with the control chrome excluded by the node's
    // own submission, so the horizontal edges below are the caption's own
    // extent and not the extent of a band this audit picked.
    const painted = inkBox(ink, boxes.column) orelse {
        probe.fail(
            "the ordinary slider caption painted pixels",
            "nothing changed in its own column",
        );
        return;
    };
    // The slider lays itself out to the caption it declares — that is what
    // its intrinsic width IS — so the caption's ink has to reach the width
    // this node was laid out to, and it may not spill past its own box. Both
    // edges come from the tree, so neither depends on which face the host
    // resolves the caption with.
    probe.ok(
        "the ordinary slider caption reaches the width measured for it",
        painted.x + painted.w >= boxes.column.x + boxes.column.w - 2 * slider_slack,
    );
    probe.ok(
        "the ordinary slider caption stayed inside its own column",
        painted.x + painted.w <= boxes.column.x + boxes.column.w + bleed,
    );
    const metrics = try audit.service.metrics(audit.inter, host_default_size);
    // One line is one line of glyphs. The quads the caption's own layout put on
    // the target have to ride a single baseline, and the height that says so
    // is the height of the ink at THOSE QUADS — not the height of everything
    // the node's own column carries, which is where a fractional node edge
    // shows the parent instead and inflates the box to the node's own height.
    const caption_ink = captionInk(ink, ordinary.matched.items) orelse {
        probe.fail(
            "the ordinary slider caption painted pixels at its own quads",
            "no pixel changed inside the boxes its own glyph quads claimed",
        );
        return;
    };
    probe.ok(
        "the ordinary slider caption is one line of text",
        captionBaselines(ordinary.matched.items) == 1 and
            caption_ink.h >= 0.5 * (metrics.ascent - metrics.descent) and
            caption_ink.h <= metrics.ascent - metrics.descent + 2 * bleed,
    );
    probe.emit(
        "offscreen_consumer: slider_default pens={d} quads={d} baselines={d} chrome={d} column=({d:.1},{d:.1},{d:.1},{d:.1}) caption=({d:.1},{d:.1},{d:.1},{d:.1}) line=({d:.2},{d:.2}) quad=({d:.1},{d:.1},{d:.1},{d:.1})\n",
        .{
            ordinary.pens.items.len,
            ordinary.matched.items.len,
            captionBaselines(ordinary.matched.items),
            chrome.items.len,
            painted.x,
            painted.y,
            painted.w,
            painted.h,
            caption_ink.x,
            caption_ink.y,
            caption_ink.w,
            caption_ink.h,
            metrics.ascent,
            metrics.descent,
            boxes.column.x,
            boxes.column.y,
            boxes.column.w,
            boxes.column.h,
        },
    );
}

/// The BOUNDED slider scenario. Both sliders declare the same long caption at
/// the same size; one declares a truncation policy and a cap narrower than
/// those bytes, the other declares nothing. The bounded caption must ride a
/// single baseline, its painted span must stay inside the cap it declared,
/// and the truncation suffix it promises must reach the target — checked
/// against the uncapped twin of its own text for what the cap changed.
fn auditBoundedSliderCaption(audit: *SliderAudit) !void {
    const probe = audit.probe;
    const capped = findSlider(audit.tree, slider_long_label, 100) orelse {
        probe.fail(
            "the app tree carries the bounded slider",
            "no slider declares the long caption over the capped range",
        );
        return;
    };
    const plain = findSlider(audit.tree, slider_long_label, 200) orelse {
        probe.fail(
            "the app tree carries the uncapped twin",
            "no slider declares the long caption over the plain range",
        );
        return;
    };

    const capped_box = sliderBox(audit.tree, capped);
    try collectNodeRects(probe.gpa, audit.rects, capped_box.border, audit.own);
    var capped_chrome: std.ArrayList(Area) = .empty;
    defer capped_chrome.deinit(probe.gpa);
    try collectChromeRects(probe.gpa, audit.own.items, &capped_chrome);
    var capped_caption: SliderCaption = .{};
    var plain_caption: SliderCaption = .{};
    defer {
        // Both layouts live in one audit arena, so it is reset only once the
        // SECOND one has released its shaped runs.
        capped_caption.deinit(probe.gpa);
        plain_caption.deinit(probe.gpa);
        _ = audit.arena.reset(.retain_capacity);
    }

    probe.ok("the bounded slider's caption resolved a request", capped.text_request != null);
    probe.ok(
        "the bounded slider's caption reached the scene text pass",
        try buildSliderCaption(audit, capped, capped_box, probe.gpa, &capped_caption) and
            capped_caption.matched.items.len > 0,
    );
    probe.eq(
        "the bounded slider's caption rides one baseline",
        captionBaselines(capped_caption.matched.items),
        1,
    );
    const capped_ink = sliderInk(
        probe,
        audit.pixels,
        audit.own.items,
        capped_box.border,
        capped_chrome.items,
    ) orelse return;

    const plain_box = sliderBox(audit.tree, plain);
    try collectNodeRects(probe.gpa, audit.rects, plain_box.border, audit.own);
    var plain_chrome: std.ArrayList(Area) = .empty;
    defer plain_chrome.deinit(probe.gpa);
    try collectChromeRects(probe.gpa, audit.own.items, &plain_chrome);
    probe.ok(
        "the uncapped twin's caption reached the scene text pass",
        try buildSliderCaption(audit, plain, plain_box, probe.gpa, &plain_caption) and
            plain_caption.matched.items.len > 0,
    );
    probe.eq(
        "the uncapped twin's caption rides one baseline",
        captionBaselines(plain_caption.matched.items),
        1,
    );
    const plain_ink = sliderInk(
        probe,
        audit.pixels,
        audit.own.items,
        plain_box.border,
        plain_chrome.items,
    ) orelse return;
    // Truncation removes glyphs; wrapping only moves them. The declared cap
    // therefore has to leave FEWER glyph quads on the bounded caption than the
    // same bytes keep uncapped beside it.
    probe.ok(
        "the declared cap dropped glyphs instead of wrapping them",
        capped_caption.matched.items.len < plain_caption.matched.items.len,
    );

    // Pixels. Each caption's own span, read across its WHOLE column with the
    // control chrome excluded by the node's own submission, has to stay inside
    // the box that node was laid out to — and the bounded one inside the cap it
    // declared.
    const capped_painted = inkBox(capped_ink, capped_box.column) orelse {
        probe.fail(
            "the bounded slider caption painted pixels",
            "nothing changed in its own column",
        );
        return;
    };
    const plain_painted = inkBox(plain_ink, plain_box.column) orelse {
        probe.fail(
            "the uncapped twin caption painted pixels",
            "nothing changed in its own column",
        );
        return;
    };
    const capped_span = capped_painted.x + capped_painted.w;
    const plain_span = plain_painted.x + plain_painted.w;
    const cap_width = @min(capped_box.column.w, slider_cap);
    const cap_edge = capped_box.column.x + cap_width;
    // The declaration reaches the TREE as well as the paint: a node whose cap
    // never landed is laid out to its caption's own natural width, so the tree
    // itself is what proves the cap was authored. It is also what makes the
    // span check below a statement about the caption, rather than about a box
    // that already reaches past the cap it claims to honour.
    probe.ok(
        "the bounded slider's own box is no wider than the cap it declared",
        capped_box.column.w <= slider_cap + 0.01,
    );
    probe.ok(
        "the bounded caption's painted span stays inside the declared cap",
        capped_span <= cap_edge + bleed,
    );
    probe.ok(
        "the declared cap shortened the caption against its uncapped twin",
        capped_span + 2 * slider_slack < plain_span,
    );

    // The suffix the declaration promises. Its span comes from the layout this
    // consumer measured through the public node seam — this node's own column,
    // its own cap and its own truncation policy — so nothing about what the
    // scene painted is assumed here, and the suffix's span is then read off the
    // frame.
    if (capped_caption.layout == null) {
        probe.fail(
            "the bounded slider caption resolved a request",
            "the bounded slider node resolved no text request to build from",
        );
        return;
    }
    const layout = &capped_caption.layout.?;
    probe.eq("the declared truncation policy lays out one line", layout.lines.len, 1);
    probe.ok(
        "the truncated line fits the declared cap",
        layout.lines[0].width <= cap_width + 0.01,
    );
    probe.ok(
        "the truncation suffix painted pixels",
        inkIn(capped_ink, suffixBand(layout, capped_caption.origin)) > 0,
    );
    probe.emit(
        "offscreen_consumer: slider_bounded quads={d}/{d} pens={d}/{d} baselines={d}/{d} chrome={d}/{d} capped_span={d:.1} plain_span={d:.1} cap={d:.1}\n",
        .{
            capped_caption.matched.items.len,
            plain_caption.matched.items.len,
            capped_caption.pens.items.len,
            plain_caption.pens.items.len,
            captionBaselines(capped_caption.matched.items),
            captionBaselines(plain_caption.matched.items),
            capped_chrome.items.len,
            plain_chrome.items.len,
            capped_span,
            plain_span,
            cap_width,
        },
    );
}

fn expectError(probe: *Probe, name: []const u8, wanted: anyerror, result: anytype) void {
    probe.checks += 1;
    if (result) |value| {
        _ = value;
        probe.fail(name, "a boundary that must be rejected was accepted");
    } else |err| {
        if (err != wanted) probe.fail(name, "rejected with an error the contract does not name");
    }
}

fn startsCluster(layout: anytype, offset: usize) bool {
    for (layout.graphemes) |g| {
        if (g.start == offset) return true;
    }
    return false;
}

fn clusterAt(layout: anytype, offset: usize) ?usize {
    for (layout.graphemes, 0..) |g, index| {
        if (g.start <= offset and offset < g.end) return index;
    }
    return null;
}

fn utf16Offset(probe: *Probe, layout: anytype, offset: usize) ?usize {
    return layout.byteToUtf16(offset) catch |err| {
        probe.fail("a cluster edge is a UTF-8 boundary", @errorName(err));
        return null;
    };
}

fn utf16Span(probe: *Probe, layout: anytype, start: usize, end: usize) ?usize {
    const from = utf16Offset(probe, layout, start) orelse return null;
    const to = utf16Offset(probe, layout, end) orelse return null;
    return to - from;
}

/// Byte, UTF-16 and grapheme offsets must agree on cluster edges, and no
/// cluster may split an encoding.
fn auditBoundaries(probe: *Probe, layout: anytype) void {
    probe.ok("the layout has clusters", layout.graphemes.len > 0);
    var previous_end: usize = 0;
    var total_units: usize = 0;
    for (layout.graphemes, 0..) |g, index| {
        if (index == 0) probe.eq("the first cluster starts at byte 0", g.start, 0);
        probe.eq("clusters are contiguous", g.start, previous_end);
        probe.ok("a cluster ends after it starts", g.end > g.start);
        previous_end = g.end;

        const utf16_start = utf16Offset(probe, layout, g.start) orelse continue;
        const round_trip = layout.utf16ToByte(utf16_start) catch |err| {
            probe.fail("a cluster start is a UTF-16 boundary", @errorName(err));
            continue;
        };
        probe.eq("the utf16 round trip at a cluster start", round_trip, g.start);

        var units: usize = 0;
        for (layout.scalars[g.scalar_start..g.scalar_end]) |scalar| {
            units += if (scalar.codepoint > 0xffff) 2 else 1;
        }
        const utf16_end = utf16Offset(probe, layout, g.end) orelse continue;
        probe.eq("the cluster utf16 span", utf16_end - utf16_start, units);
        total_units += units;
    }
    probe.eq("the last cluster ends the content", previous_end, layout.content.len);
    if (utf16Offset(probe, layout, layout.content.len)) |end| {
        probe.eq("the content utf16 length", end, total_units);
    }

    for (layout.graphemes, 0..) |g, index| {
        const next = layout.nextGrapheme(g.start) catch |err| {
            probe.fail("nextGrapheme", @errorName(err));
            continue;
        };
        probe.eq("nextGrapheme lands on a cluster end", next orelse layout.content.len, g.end);
        const previous = layout.previousGrapheme(g.end) catch |err| {
            probe.fail("previousGrapheme", @errorName(err));
            continue;
        };
        probe.eq("previousGrapheme lands on a cluster start", previous orelse 0, g.start);
        if (index + 1 < layout.graphemes.len) {
            const crossed = layout.nextGrapheme(g.end) catch |err| {
                probe.fail("nextGrapheme from a cluster end", @errorName(err));
                continue;
            };
            probe.eq("nextGrapheme from a cluster end", crossed orelse 0, layout.graphemes[index + 1].end);
        }
    }
}

/// The mixed paragraph's boundary contract: a byte inside a scalar, a byte
/// inside a cluster and a UTF-16 offset inside a surrogate pair are all
/// refused, and the right-to-left run really is laid out right to left.
fn auditMixedBoundaries(probe: *Probe, layout: anytype, content: []const u8) void {
    const heb = std.mem.indexOf(u8, content, hebrew).?;
    const comb = std.mem.indexOf(u8, content, combining).?;
    const emoji = std.mem.indexOf(u8, content, zwj_emoji).?;
    const emoji_end = emoji + zwj_emoji.len;
    const zwj = emoji + 4;
    const emoji_utf16 = utf16Offset(probe, layout, emoji) orelse 0;

    expectError(probe, "a byte inside a scalar", error.InvalidUtf8Boundary, layout.byteToPosition(heb + 1, .downstream));
    expectError(probe, "a byte inside a combining cluster", error.InvalidGraphemeBoundary, layout.byteToPosition(comb + 1, .downstream));
    expectError(probe, "a utf16 offset inside a surrogate pair", error.InvalidRange, layout.utf16ToByte(emoji_utf16 + 1));

    const hebrew_cluster = clusterAt(layout, heb) orelse {
        probe.fail("the hebrew run is clustered", "no cluster covers its first byte");
        return;
    };
    const combining_cluster = clusterAt(layout, comb) orelse {
        probe.fail("the accent is clustered", "no cluster covers the e");
        return;
    };
    const emoji_cluster = clusterAt(layout, emoji) orelse {
        probe.fail("the ZWJ sequence is clustered", "no cluster covers its first scalar");
        return;
    };
    probe.ok("hebrew carries an odd embedding level", (layout.graphemes[hebrew_cluster].level & 1) != 0);
    probe.eq("e plus acute is one cluster", layout.graphemes[combining_cluster].end, comb + combining.len);
    probe.eq("the ZWJ sequence is one cluster", layout.graphemes[emoji_cluster].end, emoji_end);
    probe.ok("the ZWJ is not a cluster of its own", !startsCluster(layout, zwj));
    if (utf16Span(probe, layout, emoji, emoji_end)) |units| {
        // Two astral scalars at two units each plus the one-unit ZWJ, all
        // inside one cluster of eleven UTF-8 bytes.
        probe.eq("the emoji cluster is five utf16 units", units, 5);
    }
    if (utf16Span(probe, layout, comb, comb + combining.len)) |units| {
        probe.eq("the combining cluster is two utf16 units", units, 2);
    }

    const first = layout.byteToPosition(heb, .downstream) catch |err| {
        probe.fail("the hebrew caret", @errorName(err));
        return;
    };
    const second = layout.byteToPosition(heb + 2, .downstream) catch |err| {
        probe.fail("the hebrew caret", @errorName(err));
        return;
    };
    probe.ok("hebrew advances right to left", first.x > second.x);
    probe.eq("hebrew stays on one line", first.line, second.line);

    const emoji_caret = layout.byteToPosition(emoji, .downstream) catch |err| {
        probe.fail("the emoji caret", @errorName(err));
        return;
    };
    const back = layout.positionToByte(emoji_caret.line, emoji_caret.x) catch |err| {
        probe.fail("the emoji caret inverse", @errorName(err));
        return;
    };
    probe.eq("the caret round trip through x", back.byte, emoji);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    var options: Options = .{
        .vert = args.next() orelse return error.MissingVertexShader,
        .frag = args.next() orelse return error.MissingFragmentShader,
        .sort = args.next() orelse return error.MissingSortShader,
    };
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--fullscreen-vert")) {
            if (options.fullscreen != null) return error.RepeatedShaderPath;
            options.fullscreen = args.next() orelse return error.MissingShaderPath;
        } else if (std.mem.eql(u8, arg, "--blit-oklab")) {
            if (options.oklab != null) return error.RepeatedShaderPath;
            options.oklab = args.next() orelse return error.MissingShaderPath;
        } else if (std.mem.eql(u8, arg, "--empty-font-registry")) {
            options.empty_font_registry = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else if (options.ppm == null) {
            options.ppm = arg;
        } else return error.UnexpectedArgument;
    }
    // A `--native` run in a build that never compiled the host arm would be a
    // promise this binary cannot keep, so it is refused by name instead.
    if (options.native and !build_options.native) return error.NativeModeNotBuiltIn;

    // The zero-face arm answers on the CPU and has no presented path, so
    // `--native` beside it is a promise this run cannot keep. It is refused by
    // name, exactly as `--native` in a build without the host arm refuses
    // itself one line above.
    if (options.empty_font_registry and options.native) return error.EmptyFontRegistryHasNoPresentedPath;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var probe: Probe = .{ .gpa = gpa, .io = io };

    // The zero-face arm proves a CPU-side refusal, so it runs before the
    // shader modules are read and long before a loader, a device, a surface or
    // a window exists. Everything below this line needs a target; it does not.
    if (options.empty_font_registry) return auditEmptyFontRegistry(gpa, io, &probe);

    var vert = try ShaderFile.load(gpa, io, options.vert);
    defer vert.deinit(gpa);
    var frag = try ShaderFile.load(gpa, io, options.frag);
    defer frag.deinit(gpa);
    var sort = try ShaderFile.load(gpa, io, options.sort);
    defer sort.deinit(gpa);
    // Only the presented arm records a blit, so only it opens the two modules
    // that blit is drawn with.
    var fullscreen: ShaderFile = if (options.native)
        try ShaderFile.load(gpa, io, options.fullscreenPath())
    else
        undefined;
    defer if (options.native) fullscreen.deinit(gpa);
    var oklab: ShaderFile = if (options.native)
        try ShaderFile.load(gpa, io, options.oklabPath())
    else
        undefined;
    defer if (options.native) oklab.deinit(gpa);

    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch @panic("offscreen consumer left a live window");
    // The App exists BEFORE the target does: a host window owns exactly one
    // App, so the presented arm opens its window against this one.
    var app = try nogui.App.init(gpa, &session);
    defer app.deinit();
    const target = try Target.init(gpa, io, .{
        .mode = if (options.native) .presented else .windowless,
        .session = &session,
        .app = &app,
        .shaders = .{ .vert = vert.words, .frag = frag.words, .sort = sort.words },
        .blit = .{
            .fullscreen = if (options.native) fullscreen.words else &[_]u32{},
            .oklab = if (options.native) oklab.words else &[_]u32{},
        },
    });
    // The target outlives the App: `detachGpu` runs first, and only then do
    // the adapter, the surface, the device, the loader and the window go.
    defer target.deinit();
    if (target.windowState()) |state| {
        probe.emit(
            "offscreen_consumer: mode=native driver={s} target={d}x{d} window={d}x{d} device={d}x{d} scale={d:.3}x{d:.3}\n",
            .{
                state.driver,
                extent.width,
                extent.height,
                state.logical.width,
                state.logical.height,
                state.device.width,
                state.device.height,
                state.scale.x,
                state.scale.y,
            },
        );
    } else {
        probe.emit(
            "offscreen_consumer: mode=windowless target={d}x{d} window=none surface=none present=none\n",
            .{ extent.width, extent.height },
        );
    }

    // ── The pinned faces, read through the service the target owns ──
    const service = target.service();
    const registered = service.listFonts();
    probe.eq("both pinned faces are registered", registered.len, 2);
    const inter = registered[0].handle;
    const dejavu = registered[1].handle;
    const metrics = try service.metrics(inter, 22);
    probe.ok("the latin face has real metrics", metrics.ascent > 0 and metrics.descent < 0 and
        metrics.line_height > 0);
    probe.ok("the latin face covers latin", try service.hasGlyph(inter, 'A'));
    probe.ok("the latin face has no hebrew", !try service.hasGlyph(inter, hebrew_first));
    probe.ok("the fallback face covers hebrew", try service.hasGlyph(dejavu, hebrew_first));
    probe.ok("neither face covers the emoji", !try service.hasGlyph(inter, wave) and
        !try service.hasGlyph(dejavu, wave));

    // The one fallback list both the caption and the specimen ask for.
    const fallback = [_]text_api.FontHandle{dejavu};
    // The caption's own inline range is the file-scope `caption_range`, the
    // same array the zero-face arm recovers into.
    var root: Root = .{ .fallback = &fallback, .ranges = &caption_range };
    try app.mountRoot(Root, &root);
    // The App measures through this target's own `MeasureSource` and mounts
    // the ONE endpoint this target owns. The source is a value the App holds
    // and the engine's service address is final, so there is no scope to enter
    // and nothing ambient to leave behind.
    app.measure = target.measurer();
    try app.attachGpu(target.endpoint());
    defer app.detachGpu();

    // ── Shape once; measure and paint consume the same runs ──
    const styled_start = std.mem.indexOf(u8, paragraph, styled_word).?;
    const styled_range = [_]text_api.StyledRange{.{
        .range = .{ .start = styled_start, .end = styled_start + styled_word.len },
        .override = .{
            .font_fields = .{ .weight = paragraph_bold },
            .background = .{ .color = .{ 0.16, 0.22, 0.34, 1 } },
            .underline = true,
            .foreground = .{ 0.96, 0.86, 0.42, 1 },
        },
    }};

    const mixed_request: text_api.LayoutRequest = .{
        .content = mixed,
        .style = .{
            .font = .{ .handle = inter, .size = 22, .fallback = &fallback },
            .foreground = .{ 0.94, 0.95, 0.97, 1 },
        },
        .paragraph = .{ .wrap = .no_wrap, .direction = .auto },
    };
    const paragraph_request: text_api.LayoutRequest = .{
        .content = paragraph,
        .style = .{ .font = .{ .handle = inter, .size = paragraph_size } },
        .ranges = &styled_range,
        .paragraph = .{
            .wrap_width = paragraph_wrap,
            .line_height = paragraph_line_height,
            .alignment = .center,
        },
    };

    var mixed_layout = try service.layout(gpa, mixed_request);
    defer mixed_layout.deinit();
    var paragraph_layout = try service.layout(gpa, paragraph_request);
    defer paragraph_layout.deinit();

    // A codepoint no face covers is a visible policy, never a silent hole.
    if (service.layout(gpa, .{
        .content = zwj_emoji,
        .style = .{ .font = .{ .handle = inter, .fallback = &fallback } },
        .missing_glyph = .error_if_missing,
    })) |strict_value| {
        var strict = strict_value;
        strict.deinit();
        probe.ok("the strict missing-glyph policy refuses an uncovered codepoint", false);
    } else |err| {
        probe.checks += 1;
        if (err != error.MissingGlyph) {
            probe.fail("the strict missing-glyph policy", "refused with an error the contract does not name");
        }
    }

    // The shape cache must reuse unchanged text across identical requests.
    const shapes_before = service.shapeCount();
    var repeat = try service.layout(gpa, paragraph_request);
    defer repeat.deinit();
    probe.eq("shaping is reused for the same text", service.shapeCount(), shapes_before);
    probe.near("the repeated layout measures the same width", repeat.width, paragraph_layout.width, 0.001);
    probe.eq("the repeated layout has the same line count", repeat.lines.len, paragraph_layout.lines.len);

    auditBoundaries(&probe, &mixed_layout);
    auditBoundaries(&probe, &paragraph_layout);
    auditMixedBoundaries(&probe, &mixed_layout, mixed);
    probe.ok("the paragraph wraps into several lines", paragraph_layout.lines.len >= 2);
    probe.near(
        "the layout height is its line heights",
        paragraph_layout.height,
        paragraph_line_height * @as(f32, @floatFromInt(paragraph_layout.lines.len)),
        0.01,
    );
    var styled_run = false;
    var hebrew_run = false;
    var hebrew_ink_run = false;
    for (paragraph_layout.runs) |run| {
        if (run.start >= styled_start and run.start < styled_start + styled_word.len) {
            styled_run = true;
            probe.eq("the styled run is bold", run.style.font.weight, paragraph_bold);
            probe.ok("the styled run keeps its underline", run.style.underline);
            probe.ok("the styled run keeps its background", run.style.background != null);
        }
    }
    for (mixed_layout.runs) |run| {
        if (!hebrew_run and run.script == .hebrew) {
            hebrew_run = true;
            hebrew_ink_run = !run.missing_glyph;
            probe.eq("the hebrew run is the fallback face", run.font, dejavu);
        }
    }
    probe.ok("the hebrew run exists", hebrew_run);
    probe.ok("the hebrew run paints real glyphs", hebrew_ink_run);
    probe.ok("the emoji cluster is a visible notdef", blk: {
        var found = false;
        for (mixed_layout.runs) |run| {
            if (run.start == std.mem.indexOf(u8, mixed, zwj_emoji).?) found = run.missing_glyph;
        }
        break :blk found;
    });

    // ── One App frame, then the shaped layouts on the same target ──
    // The one recording this frame is built in, opened by the target that
    // owns it and closed by the same target when it submits.
    try target.beginFrame();
    errdefer target.cancelFrame();
    const output = try app.frameWithGpuAtTime(
        1,
        0,
        .{ .width = extent.width, .height = extent.height },
        target.gpuFrame(),
    );
    defer if (output.json) |json| gpa.free(json);
    const scratch = target.scratch();
    var painted = try target.buildScene(&output);
    defer painted.deinit();

    // ── The ORDINARY App caption, checked where it was painted ──
    // The tree's own rects are the only ones in the scratch right now: the
    // specimen is appended after this. Laying the caption's OWN resolved
    // request out through the same builder the paint used, and matching the
    // scene's rects against it, is what proves the ordinary label pipeline
    // carries tofu, an inline style and a bidi fallback.
    var caption_arena = std.heap.ArenaAllocator.init(gpa);
    defer caption_arena.deinit();
    // The caption's own rectangles, kept past the audit: the pixel check reads
    // the surface the caption was painted on by looking at the pixels inside
    // its box that none of THESE rectangles cover.
    var caption_rects: std.ArrayList(SceneRect) = .empty;
    defer caption_rects.deinit(gpa);
    const caption_report = try auditCaption(
        &probe,
        output.tree,
        service,
        &caption_arena,
        scratch.rects.items,
        &caption_rects,
        dejavu,
        inter,
    );

    var tree_bottom: f32 = 0;
    for (output.tree.nodes.items) |node| {
        if (node.paint_hidden) continue;
        const box = nogui.visualBorderRect(output.tree, node.id);
        if (box.w <= 0 or box.h <= 0) continue;
        tree_bottom = @max(tree_bottom, box.y + box.h);
    }
    probe.ok("the app tree laid out", tree_bottom > 0);
    const mixed_origin = [2]f32{ 24, tree_bottom + 16 };
    const paragraph_origin = [2]f32{ 24, mixed_origin[1] + mixed_layout.height + 14 };
    const specimen_bottom = paragraph_origin[1] + paragraph_layout.height;
    probe.ok("the specimen fits the target", specimen_bottom + 8 <= @as(f32, @floatFromInt(extent.height)));
    probe.ok("the specimen clears the tree", mixed_origin[1] >= tree_bottom + 8);

    // The specimen rides one layer above the tree so the sort cannot bury it.
    var top_layer: u32 = 0;
    var next_order: u32 = 0;
    for (scratch.rects.items) |rect| {
        top_layer = @max(top_layer, rect.z);
        next_order = @max(next_order, rect.order);
    }
    const specimen_z = top_layer + 1;

    var emitted: std.ArrayList(SceneRect) = .empty;
    defer emitted.deinit(gpa);
    var mixed_report: LayoutReport = .{};
    var paragraph_report: LayoutReport = .{};
    try submitLayout(
        &probe,
        target.textEngine(),
        &mixed_layout,
        "mixed",
        mixed_origin,
        null,
        specimen_z,
        &emitted,
        &mixed_report,
    );
    try submitLayout(
        &probe,
        target.textEngine(),
        &paragraph_layout,
        "paragraph",
        paragraph_origin,
        paragraph_wrap,
        specimen_z,
        &emitted,
        &paragraph_report,
    );
    probe.emit(
        "offscreen_consumer: stage=submit layouts=2 rects={d} glyph_quads={d} notdef_boxes={d} solids={d}\n",
        .{
            mixed_report.rects + paragraph_report.rects,
            mixed_report.glyph_rects + paragraph_report.glyph_rects,
            mixed_report.notdef_boxes + paragraph_report.notdef_boxes,
            mixed_report.solid_rects + paragraph_report.solid_rects,
        },
    );
    probe.ok("the uncovered emoji reached the notdef policy", mixed_report.notdef_boxes > 0);

    for (emitted.items) |*rect| {
        rect.z = specimen_z;
        rect.order = next_order;
        next_order += 1;
    }
    try scratch.rects.appendSlice(gpa, emitted.items);

    const pixels = try target.submit(&output, &painted);
    if (target.textEngine().glyphSlotCount() <= 1) return error.NoGlyphsRendered;

    // ── The window those pixels reached, when there is one ──
    // Everything below is the same code either way. These are the only facts
    // the window contributes, and each one is a fact the run REFUSES to call
    // proved without: the read-back above came out of the Oklab target the
    // presented passes wrote, so a frame the display never accepted would
    // otherwise pass every oracle below in silence.
    if (comptime build_options.native) {
        if (options.native) {
            try target.hold();
            const state = target.windowState().?;
            probe.emit(
                "offscreen_consumer: mode=native presented={d} committed={d} acquire_retries={d} host_polls={d} swapchain_rebuilds={d} resizes={d} extent_mismatches={d} scale_changes={d}\n",
                .{
                    state.stats.frames_presented,
                    state.stats.frames_committed,
                    state.acquire_retries,
                    state.polls,
                    state.stats.swapchains_recreated,
                    state.stats.resizes_requested,
                    state.stats.extent_mismatches,
                    state.stats.scale_changes,
                },
            );
            probe.ok("the window stayed the authored logical size", state.logical.width == extent.width and
                state.logical.height == extent.height);
            probe.eq("the presented image is the authored width", state.device.width, extent.width);
            probe.eq("the presented image is the authored height", state.device.height, extent.height);
            probe.ok("the glyphs were rasterized at the authored 1:1 scale", state.scale.x == 1 and
                state.scale.y == 1);
            probe.ok("the window was visible for the whole run", state.visible);
            probe.ok("the frame reached the display", state.stats.frames_presented >= 1);
            probe.eq("no present was discarded as out of date", state.stats.present_out_of_date, 0);
        }
    }

    // The caption's own pixels, at the boxes its resolved request claimed.
    auditCaptionPixels(&probe, pixels, caption_rects.items, caption_report);

    // ── Paragraph policy on the same tree, at the same pixels ──
    // Ordinary `ctx.label` calls, the same shared scene, the same pinned faces
    // and the same Oklab read-back: the clamp and the three truncation modes
    // are read off the tree's own published records and checked against the
    // rectangles and the pixels that reached the target for them.
    var label_arena = std.heap.ArenaAllocator.init(gpa);
    defer label_arena.deinit();
    var label_scene: LabelScene = .{
        .probe = &probe,
        .tree = output.tree,
        .service = service,
        .arena = &label_arena,
        .inter = inter,
        .rects = scratch.rects.items,
        .pixels = pixels,
    };
    try auditClampLabel(&label_scene);
    try auditTruncationLabels(&label_scene);

    // ── Slider captions, read where the scene painted them ──
    // The same App tree, the same shared scene, the same pinned faces and the
    // same Oklab read-back as the caption above: each slider names its own
    // background, so the plate its caption's glyphs sit on is read off that
    // node's own box and held to the fill the App authored. The control chrome
    // is read off the node's OWN submission, off the decoration material ring
    // it took, and excluded from the region — so no thumb or track pixel can
    // count as text.
    var slider_arena = std.heap.ArenaAllocator.init(gpa);
    defer slider_arena.deinit();
    var slider_rects: std.ArrayList(SceneRect) = .empty;
    defer slider_rects.deinit(gpa);
    var slider_audit: SliderAudit = .{
        .probe = &probe,
        .tree = output.tree,
        .service = service,
        .arena = &slider_arena,
        .inter = inter,
        .rects = scratch.rects.items,
        .pixels = pixels,
        .own = &slider_rects,
    };
    try auditDefaultSliderCaption(&slider_audit);
    try auditBoundedSliderCaption(&slider_audit);

    // Everything below sits on the render pass's own clear surface: the
    // specimen is appended after the tree and the tree ends above it, so
    // here the clear colour IS the surface to measure against.
    const clear = clearInk(pixels);

    // ── Ink, located by the geometry the layout promised ──
    const target_width: f32 = @floatFromInt(extent.width);
    const target_height: f32 = @floatFromInt(extent.height);
    const tree_ink = inkIn(clear, .{ .x = 0, .y = 0, .w = target_width, .h = tree_bottom });
    const gap = inkIn(clear, .{
        .x = 0,
        .y = tree_bottom + 2,
        .w = target_width,
        .h = mixed_origin[1] - tree_bottom - 4,
    });
    const tail = inkIn(clear, .{
        .x = 0,
        .y = specimen_bottom + 4,
        .w = target_width,
        .h = target_height - specimen_bottom - 4,
    });
    var total_ink: usize = 0;
    for (0..@as(usize, extent.width) * extent.height) |i| {
        if (clear.at(i % extent.width, i / extent.width)) total_ink += 1;
    }
    probe.ok("the app tree painted ink", tree_ink > 0);
    probe.eq("nothing painted between the tree and the specimen", gap, 0);
    probe.eq("nothing painted below the specimen", tail, 0);
    probe.ok("the frame is not blank", total_ink > 0);

    for ([_]*LayoutReport{ &mixed_report, &paragraph_report }) |report| {
        report.ink = inkIn(clear, report.area);
        probe.ok("the layout's own box holds ink", report.ink > 0);
        const box = inkBox(clear, .{
            .x = report.area.x - bleed,
            .y = report.area.y - bleed,
            .w = report.area.w + 2 * bleed,
            .h = report.area.h + 2 * bleed,
        }) orelse {
            probe.fail("the layout's box holds ink", "no pixel changed inside it");
            continue;
        };
        // Horizontal placement is the measured run box; vertical placement is
        // the union of the faces' own ascent-to-descent bands.
        probe.ok("the ink starts at the measured left edge", box.x >= report.area.x - bleed);
        probe.ok("the ink ends at the measured right edge", box.x + box.w <=
            report.area.x + report.area.w + bleed);
        probe.ok("the ink starts above the first baseline", box.y >= report.ink_band.y - bleed);
        probe.ok("the ink ends below the last baseline", box.y + box.h <=
            report.ink_band.y + report.ink_band.h + bleed);
    }

    // A solid fill the engine submitted must actually cover the pixel it names.
    for (emitted.items) |rect| {
        if (rect.material_index != 0) continue;
        const centre = solidCentre(.{
            .x = rect.dst[0],
            .y = rect.dst[1],
            .w = rect.dst[2],
            .h = rect.dst[3],
        }) orelse continue;
        probe.ok("a solid rect covered its own centre", clear.at(centre.x, centre.y));
    }

    if (options.ppm) |path| try frame.writePpm(gpa, io, path, pixels, extent);
    probe.emit(
        "offscreen_consumer: stage=ink tree={d} mixed={d} paragraph={d} gap={d} tail={d}\n",
        .{ tree_ink, mixed_report.ink, paragraph_report.ink, gap, tail },
    );

    // ── A changed next frame, with the first frame's records still live ──
    // Everything the first frame published is captured while it is still
    // current: the record pointer its clamp label holds, what that record
    // says, and the shape of the layout whose leases pin the first frame's
    // shapes. Only then does the authored data change and a second frame
    // commit, so the read-back below can only answer what the FIRST frame
    // published if that frame really kept it.
    if (findLabel(output.tree, clamp_text, null, clamp_lines)) |first_node| {
        if (first_node.text_request) |first_record| {
            const first_value = ClampRecord.read(output.tree, first_node);
            const first_shape = LayoutShape.read(&paragraph_layout);
            root.clamp_frame = 1;
            const next = try app.frame(2, .{ .width = extent.width, .height = extent.height });
            defer if (next.json) |json| gpa.free(json);
            try auditPreviousFrame(
                &probe,
                service,
                paragraph_request,
                output.tree,
                next.prev_tree,
                next.tree,
                first_record,
                first_value,
                first_shape,
                &paragraph_layout,
            );
        } else {
            probe.fail(
                "the first frame's clamp label published a record",
                "the label carrying those bytes resolved no text request",
            );
        }
    } else {
        probe.fail(
            "the first frame published its clamp label",
            "no label declares the clamp bytes under that clamp",
        );
    }

    if (probe.failures != 0) {
        probe.emit("offscreen_consumer: FAILED checks={d} failures={d}\n", .{ probe.checks, probe.failures });
        return error.SpecimenAssertionFailed;
    }
    const report = try std.fmt.allocPrint(
        gpa,
        "offscreen_consumer: OK checks={d} ink_pixels={d} glyph_slots={d} rects={d} runs={d} graphemes={d} shapes={d} caption_quads={d} caption_notdef={d}\n",
        .{
            probe.checks,
            total_ink,
            target.textEngine().glyphSlotCount(),
            mixed_report.rects + paragraph_report.rects,
            mixed_report.runs + paragraph_report.runs,
            mixed_layout.graphemes.len + paragraph_layout.graphemes.len,
            service.shapeCount(),
            caption_report.glyph_quads,
            caption_report.notdef_boxes,
        },
    );
    defer gpa.free(report);
    try std.Io.File.stdout().writeStreamingAll(io, report);
}
