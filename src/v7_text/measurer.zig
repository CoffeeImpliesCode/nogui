//! The one measure seam. Both halves run the same node layout the paint path
//! runs, through the same request builder, and differ only in who owns the
//! font registry and the scratch arena.
//!
//! Neither half keeps global state. Core holds a `MeasureSource` whose
//! context is one of these values, so a measure always reaches the service it
//! was bound to and never a thread-local engine.

const std = @import("std");
const nogui = @import("nogui");
const measure = @import("measure.zig");

const FontSource = measure.FontSource;
const NodeLayoutOptions = measure.NodeLayoutOptions;
const TextLayout = measure.TextLayout;
const TextService = measure.TextService;
const TextLayoutError = measure.TextLayoutError;
const WidthMode = measure.WidthMode;

pub const MeasureInput = nogui.layout.MeasureInput;
pub const MeasureSource = nogui.layout.MeasureSource;
pub const TextMeasurement = nogui.layout.TextMeasurement;

/// Which content width one measure call answers. A single-line policy is the
/// max-content probe: it asks what the text wants, never how it would break.
fn probeFor(input: MeasureInput) WidthMode {
    if (input.line_policy == .single_line) return .max_content;
    return measure.widthMode(input);
}

/// The request options for one measure call. A definite width wraps at that
/// width; a content probe leaves the paragraph unconstrained, which is what
/// lets the layout report its own ink extent instead of a viewport's.
fn probeOptions(input: MeasureInput) NodeLayoutOptions {
    return .{
        .width = switch (probeFor(input)) {
            .definite => |width| width,
            .min_content, .max_content => null,
        },
    };
}

/// The content metrics of one laid-out request, plus the FIRST shaped line's
/// baseline. A wrapped box reports the width it was offered, clamped to what
/// the text really needs: a content probe swaps that viewport width for the
/// measured ink, and a definite probe reads the same normalized width the
/// paint path breaks its lines at.
fn measureLayout(
    layout: *const TextLayout,
    probe: WidthMode,
    input: MeasureInput,
) TextMeasurement {
    var result: TextMeasurement = .{
        .width = switch (probe) {
            .min_content => layout.minInkWidth(),
            .max_content => layout.inkWidth(),
            .definite => |offered| normalizedWidth(layout, offered),
        },
        .height = layout.height,
        .first_baseline = layout.firstBaseline(),
    };
    if (input.known_dimensions.width) |known| result.width = known;
    if (input.known_dimensions.height) |known| result.height = known;
    return result;
}

/// The width a box of `offered` px actually occupies: never less than the
/// widest unbreakable segment, and never more than the text's own ink. A
/// shorter text does not stretch to fill its box, and a longer one does not
/// report more than it was given.
fn normalizedWidth(layout: *const TextLayout, offered: f32) f32 {
    const bounded = if (std.math.isFinite(offered)) @max(0, offered) else layout.inkWidth();
    return @max(layout.minInkWidth(), @min(bounded, layout.inkWidth()));
}

/// Lay out one node's content in the shared scratch, answer from it, release
/// it. Every shaped run's lease is dropped and the arena is reset before this
/// returns, so the next call reuses the same blocks and a warm frame
/// allocates nothing.
fn measureInto(
    service: *TextService,
    scratch: *std.heap.ArenaAllocator,
    default_size: f32,
    content: []const u8,
    input: MeasureInput,
) TextLayoutError!TextMeasurement {
    service.sink.add(.measure_requests, 1);
    defer _ = scratch.reset(.retain_capacity);
    var layout = try service.nodeLayoutIn(
        scratch.allocator(),
        content,
        // A node that asks for no text still resolves through the ROOT node
        // record, whose size is ZERO, so the host's own default applies here.
        // A bare `NodeText{}` would carry `FontRequest`'s 16 and silently
        // override a host whose default is any other size.
        (input.text orelse &nogui.text.default_node_text).*,
        probeOptions(input),
        default_size,
    );
    defer layout.release();
    return measureLayout(&layout, probeFor(input), input);
}

/// Borrows a `TextService` a host already owns — the GPU engine binds its own —
/// and answers core's measure callback with real node layouts. The scratch
/// arena is the caller's, so the measure seam and the emit path share it.
pub const NodeMeasurer = struct {
    service: *TextService,
    /// The caller's arena. Every layout carved here is released, leases
    /// included, before the next frame reuses the blocks.
    scratch: *std.heap.ArenaAllocator,
    /// The host's default px size, used only where a node leaves it unset.
    default_size: f32,

    /// `service` must be storage the caller keeps in place: the source this
    /// measurer hands out points at it.
    pub fn init(
        self: *NodeMeasurer,
        service: *TextService,
        scratch: *std.heap.ArenaAllocator,
        default_size: f32,
    ) void {
        self.* = .{
            .service = service,
            .scratch = scratch,
            .default_size = default_size,
        };
    }

    /// The core measure hook. The context is this value, so it must outlive
    /// every layout pass it answers.
    pub fn source(self: *NodeMeasurer) MeasureSource {
        return .{ .context = @ptrCast(self), .callback = nodeCallback };
    }

    /// One content measurement. The caller never sees the layout.
    pub fn measure(
        self: *NodeMeasurer,
        content: []const u8,
        input: MeasureInput,
    ) TextLayoutError!TextMeasurement {
        return measureInto(self.service, self.scratch, self.default_size, content, input);
    }
};

/// The owning CPU half: one `TextService` over caller-supplied font bytes and
/// one retained scratch arena. A host with no GPU binds `source()` and never
/// builds a font registry of its own.
pub const TextMeasurer = struct {
    service: TextService,
    scratch: std.heap.ArenaAllocator,
    /// The host's default px size, used only where a node leaves it unset.
    default_size: f32,

    /// `self` must be storage the caller keeps in place for the measurer's
    /// whole life (see the header). The service copies the font bytes, so
    /// `fonts` need not outlive this call.
    pub fn init(
        self: *TextMeasurer,
        gpa: std.mem.Allocator,
        fonts: []const FontSource,
        default_size: f32,
    ) !void {
        var service = try TextService.init(gpa);
        errdefer service.deinit();
        for (fonts) |font| _ = try service.addFont(font);
        self.* = .{
            .service = service,
            .scratch = std.heap.ArenaAllocator.init(gpa),
            .default_size = default_size,
        };
    }

    /// The core measure hook for a host with no GPU.
    pub fn source(self: *TextMeasurer) MeasureSource {
        return .{ .context = @ptrCast(self), .callback = ownerCallback };
    }

    /// The font registry and shape cache, for a consumer that shapes its own
    /// runs against the same faces measure and paint already use. Named for
    /// what it hands back: the field already owns the name `service`, and a
    /// struct's fields and declarations share one namespace.
    pub fn textService(self: *TextMeasurer) *TextService {
        return &self.service;
    }

    /// Release the scratch and the service. The service must outlive every
    /// layout a caller made from it, including layouts held by the caller.
    pub fn deinit(self: *TextMeasurer) void {
        self.scratch.deinit();
        self.service.deinit();
        self.* = undefined;
    }

    /// One content measurement against the owned service.
    pub fn measure(
        self: *TextMeasurer,
        content: []const u8,
        input: MeasureInput,
    ) TextLayoutError!TextMeasurement {
        return measureInto(&self.service, &self.scratch, self.default_size, content, input);
    }
};

/// Core passes back the context it was handed; a host that drops it is a bug
/// the same way the old thread-local engine was.
fn nodeCallback(
    context: ?*anyopaque,
    content: []const u8,
    input: MeasureInput,
) TextLayoutError!TextMeasurement {
    const self: *NodeMeasurer = @ptrCast(@alignCast(context.?));
    return self.measure(content, input);
}

fn ownerCallback(
    context: ?*anyopaque,
    content: []const u8,
    input: MeasureInput,
) TextLayoutError!TextMeasurement {
    const self: *TextMeasurer = @ptrCast(@alignCast(context.?));
    return self.measure(content, input);
}

test {
    _ = @import("measurer_test.zig");
}
