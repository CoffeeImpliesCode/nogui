//! Text-only external consumer of the `nogui` package.
//!
//! Registers a font, reads its metrics, and lays out a shaped string through
//! `nogui_text`. A second identical layout must reuse the shape cache: same
//! width, and no new shape entry. Around that proof it establishes the font
//! registry's refusals by name — a missing face and a missing slant are typed
//! answers, not substituted faces — and that one real face turns both into
//! measured ink. No window, no GPU, no SDL, no demo file.
const std = @import("std");
const nogui_text = @import("nogui_text");
const nogui = @import("nogui");
const nogui_test = @import("nogui_test");
const font_bytes = @import("font_bytes").bytes;

const TextLayout = nogui_text.TextLayout;
const text = nogui_text.text;

const sample = "Consumer layout";

const ContextProbe = struct {
    pub fn draw(_: *ContextProbe, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.row(.{});
        defer ctx.pop();
        _ = try ctx.label(.{ .text = "iii", .key = @as(nogui.ComponentKey, .{ .static = "narrow" }) });
        _ = try ctx.label(.{ .text = "WWW", .key = @as(nogui.ComponentKey, .{ .static = "wide" }) });
    }
};

/// One refusal, checked by name. A consumer that only learns "it failed" has
/// not learned which font question the service answered, so the arm reports
/// the answer it required next to the answer it got.
fn refuses(comptime Payload: type, result: anyerror!Payload, expected: anyerror) !void {
    if (result) |value| {
        _ = value;
        std.debug.print("text_only: {s} was accepted\n", .{@errorName(expected)});
        return error.RefusedRequestAccepted;
    } else |actual| {
        if (actual != expected) {
            std.debug.print("text_only: expected {s}, got {s}\n", .{
                @errorName(expected),
                @errorName(actual),
            });
            return error.UnexpectedRefusal;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const context = try nogui_test.TextContext(nogui_text).create(gpa, .{
        .fonts = &.{},
        .default_size = 17,
    });
    defer context.deinit() catch @panic("text-only consumer retained context ownership");
    const service = context.text.textService();

    // Absent-font arm: nothing is installed yet. A named family and a handle
    // this registry never issued are both refused by name, and neither
    // measures anything, so no substitute metrics or layout can come back.
    try refuses(text.FontHandle, service.resolve(.{ .family = "Inter" }), error.FontUnavailable);
    try refuses(TextLayout, service.layout(gpa, .{
        .content = sample,
        .style = .{ .font = .{ .family = "Inter", .size = 17 } },
    }), error.FontUnavailable);
    try refuses(text.FontMetrics, service.metrics(.{ .index = 0, .generation = 1 }, 17), error.UnknownFont);
    if (service.shapeCount() != 0) return error.RefusedRequestShaped;

    const handle = try service.addFont(.{ .family = "Inter", .bytes = font_bytes });
    if (service.listFonts().len != 1) return error.UnexpectedFontCount;
    if (!(try service.hasGlyph(handle, 'C'))) return error.MissingGlyph;
    // A family request resolves to the registered face, weight nearest first.
    const resolved = try service.resolve(.{ .family = "inter", .weight = 700 });
    if (resolved.index != handle.index or resolved.generation != handle.generation)
        return error.ResolveIgnoredFamily;

    // Refused-slant arm: the pinned face is upright, so an italic request is
    // refused rather than answered with the upright face that does exist.
    try refuses(text.FontHandle, service.resolve(.{ .family = "Inter", .style = .italic }), error.FontUnavailable);
    try refuses(TextLayout, service.layout(gpa, .{
        .content = sample,
        .style = .{ .font = .{ .handle = handle, .size = 17, .style = .italic } },
    }), error.FontUnavailable);

    const size_px = try service.fontPixelSize(17);
    if (size_px != 17) return error.UnexpectedPixelSize;

    const metrics = try service.metrics(handle, 17);
    if (!(metrics.ascent > 0 and metrics.line_height > metrics.ascent)) {
        std.debug.print("metrics ascent {d} line_height {d}\n", .{ metrics.ascent, metrics.line_height });
        return error.ImpossibleMetrics;
    }

    if (service.shapeCount() != 0) return error.ShapeCacheNotEmptyAtStart;

    var first = try service.layout(gpa, .{
        .content = sample,
        .style = .{ .font = .{ .handle = handle, .family = "Inter", .size = 17 } },
    });
    defer first.deinit();
    if (!(first.width > 0)) {
        std.debug.print("layout width {d}\n", .{first.width});
        return error.NonPositiveWidth;
    }
    if (first.lines.len != 1) return error.UnexpectedLineCount;
    if (first.graphemes.len == 0) return error.NoGraphemes;

    const shapes_after_first = service.shapeCount();
    if (shapes_after_first == 0) return error.ShapeCacheDidNotFill;

    var second = try service.layout(gpa, .{
        .content = sample,
        .style = .{ .font = .{ .handle = handle, .family = "Inter", .size = 17 } },
    });
    defer second.deinit();

    if (second.width != first.width) {
        std.debug.print("layout width drifted {d} -> {d}\n", .{ first.width, second.width });
        return error.UnstableWidth;
    }
    if (second.lines.len != first.lines.len or second.runs.len != first.runs.len) {
        return error.UnstableLayoutShape;
    }
    if (service.shapeCount() != shapes_after_first) {
        std.debug.print("shape cache grew on a repeat layout {d} -> {d}\n", .{
            shapes_after_first,
            service.shapeCount(),
        });
        return error.ShapeCacheMiss;
    }

    // Recovery arm: the family request the empty registry refused now lays out
    // from the registered face, at the same ink the handle request measured.
    // Both name one face, so recovery reuses the shaped run rather than
    // shaping the same content a second time.
    var recovered = try service.layout(gpa, .{
        .content = sample,
        .style = .{ .font = .{ .family = "Inter", .size = 17 } },
    });
    defer recovered.deinit();
    if (recovered.width != first.width) {
        std.debug.print("recovered width {d} != {d}\n", .{ recovered.width, first.width });
        return error.RecoveryWidthMismatch;
    }
    if (recovered.runs.len == 0) return error.NoRuns;
    if (recovered.runs[0].font.index != handle.index or
        recovered.runs[0].font.generation != handle.generation)
        return error.RecoveryIgnoredFace;
    if (service.shapeCount() != shapes_after_first) return error.RecoveryReshaped;

    // The optional context must carry those real metrics through App layout,
    // not substitute a fixed grid when the caller commits a frame.
    var view: ContextProbe = .{};
    try context.base.app.mountRoot(ContextProbe, &view);
    const output = try context.base.flushFrame();
    defer if (output.json) |json| gpa.free(json);
    const narrow = try context.base.queryKey(.root, .{ .static = "narrow" });
    const wide = try context.base.queryKey(.root, .{ .static = "wide" });
    if (wide.visual_rect.w <= narrow.visual_rect.w * 2) return error.ContextUsedFixedTextMetrics;
    const context_line = try std.fmt.allocPrint(gpa, "text_only: real-font context narrow={d:.2} wide={d:.2}\n", .{
        narrow.visual_rect.w, wide.visual_rect.w,
    });
    defer gpa.free(context_line);
    try std.Io.File.stdout().writeStreamingAll(init.io, context_line);

    const faces = service.listFonts();
    const report = try std.fmt.allocPrint(gpa,
        \\text_only: absent_font={s} unissued_handle={s} refused_slant={s} recovered_face={s}@{d} ink={d:.2}
        \\
    , .{
        @errorName(error.FontUnavailable),
        @errorName(error.UnknownFont),
        @errorName(error.FontUnavailable),
        faces[0].family,
        faces[0].weight,
        recovered.width,
    });
    defer gpa.free(report);
    try std.Io.File.stdout().writeStreamingAll(init.io, report);

    const line = try std.fmt.allocPrint(gpa, "text_only: OK width={d:.2}\n", .{first.width});
    defer gpa.free(line);
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
