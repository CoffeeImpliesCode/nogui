//! Behavior regressions for the typed measure seam. Every test here fails
//! against a pipeline that shaped its own text, leaked a nested arena, or
//! answered a content probe from a viewport width.

const std = @import("std");
const nogui = @import("nogui");
const text = nogui.text;
const measure = @import("measure.zig");
const measurer = @import("measurer.zig");

const inter = @embedFile("InterVariable.ttf");
const fira = @embedFile("FiraCodeNerdFont-Regular.ttf");

const testing = std.testing;

/// Counts served allocations without changing the allocation itself. The
/// measure seam must not touch the allocator once its scratch is warm.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    allocs: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocs += 1;
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

fn sources() []const measure.FontSource {
    return &.{
        .{ .family = "Inter", .bytes = inter },
        .{ .family = "Fira Code", .bytes = fira },
    };
}

/// The width half of a measure input's available space, taken from the input
/// type itself so an anonymous literal cannot drift from what the seam wants.
const probe_space = @FieldType(@FieldType(measurer.MeasureInput, "available_space"), "width");

fn probe(space: probe_space) measurer.MeasureInput {
    return .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = space, .height = .max_content },
    };
}

/// A node whose primary face is Inter and whose only fallback is Fira. Named
/// apart from core's `text.nodeRequest` so the builder stays unmistakable.
fn fallbackNode(fallback: []const text.FontHandle) text.NodeText {
    return .{
        .style = .{
            .font = .{
                .family = "Inter",
                .size = 20,
                .fallback = fallback,
            },
            .foreground = .{ 0.1, 0.1, 0.1, 1 },
        },
    };
}

fn measurerHandles(host: *measurer.TextMeasurer) struct {
    inter: text.FontHandle,
    fira: text.FontHandle,
} {
    const registered = host.textService().listFonts();
    return .{ .inter = registered[0].handle, .fira = registered[1].handle };
}

/// The two request-level width probes of one phrase, read through the same
/// request a content probe builds. Every number comes from this service, this
/// face and this size, so a comparison below can never drift with the font.
fn phraseProbes(
    service: *measure.TextService,
    scratch: *std.heap.ArenaAllocator,
    style: text.TextStyle,
    content: []const u8,
) !struct { min: f32, max: f32 } {
    var laid = try service.layoutIn(scratch.allocator(), .{
        .content = content,
        .style = style,
        .paragraph = .{ .wrap = .no_wrap },
    });
    defer laid.release();
    return .{ .min = laid.minInkWidth(), .max = laid.inkWidth() };
}

// The truncation suffix is shaped by a NESTED layout that pins its own
// shaped runs. `layoutIn` must carve the whole thing straight into the
// caller's arena: a nested allocator opened here is dropped without a
// destructor, and its blocks end up behind an arena the caller never sees.
// The shape cache asserts on `deinit` that every pinned run was released, so
// a stranded suffix lease fails this test.
test "a truncated layout carved in the caller's arena releases every lease" {
    var service = try measure.TextService.init(testing.allocator);
    defer service.deinit();
    const faces = try service.addFont(.{ .family = "Inter", .bytes = inter });
    var scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    var layout = try service.layoutIn(scratch.allocator(), .{
        .content = "alpha beta gamma delta epsilon",
        .style = .{ .font = .{ .handle = faces, .size = 20 } },
        .paragraph = .{
            .wrap = .no_wrap,
            .wrap_width = 60,
            .truncate = .{ .mode = .end, .suffix = "..." },
        },
    });
    // The nested suffix really shaped and painted: it contributes runs, so
    // its lease was a real pin that only `release` could drop.
    try testing.expect(layout.suffix_layout != null);
    try testing.expect(layout.suffix_layout.?.leases.len > 0);
    var suffix_runs: usize = 0;
    for (layout.runs) |run| {
        if (run.is_suffix) suffix_runs += 1;
    }
    try testing.expect(suffix_runs > 0);
    // The painted width is the truncation result, not the real ink extent.
    try testing.expect(layout.width <= 60);
    try testing.expect(layout.inkWidth() > layout.width);
    // Teardown: `release` drops this layout's leases and the nested suffix's,
    // then the caller's arena frees the bytes. The shape cache asserts on
    // `deinit` that no run is still pinned, so a stranded suffix lease fails
    // this test at the `defer` above.
    layout.release();
    _ = scratch.reset(.retain_capacity);
}

// A content probe must read the itemized graphemes, so a max-content probe
// reports the widest hard-broken line and a min-content probe the widest
// unbreakable segment. A viewport width would answer neither.
test "content probes read measured ink, never a viewport width" {
    var service = try measure.TextService.init(testing.allocator);
    defer service.deinit();
    const faces = try service.addFont(.{ .family = "Inter", .bytes = inter });
    var scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const content = "alpha beta gamma\ndelta epsilon";

    var probe_layout = try service.layoutIn(scratch.allocator(), .{
        .content = content,
        .style = .{ .font = .{ .handle = faces, .size = 20 } },
        .paragraph = .{ .wrap = .no_wrap },
    });
    defer probe_layout.release();
    try testing.expectEqual(@as(usize, 2), probe_layout.lines.len);
    try testing.expect(probe_layout.minInkWidth() < probe_layout.inkWidth());
    try testing.expectEqual(probe_layout.inkWidth(), probe_layout.width);

    // The widest hard-broken line IS the max-content probe.
    try testing.expectApproxEqAbs(probe_layout.lines[0].width, probe_layout.inkWidth(), 0.01);
    try testing.expect(probe_layout.lines[1].width < probe_layout.inkWidth());

    // The min-content probe is the narrowest box that still paints a whole
    // word, so it equals the widest single word measured on its own.
    var widest_word: f32 = 0;
    for ([_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" }) |word| {
        var alone = try service.layoutIn(scratch.allocator(), .{
            .content = word,
            .style = .{ .font = .{ .handle = faces, .size = 20 } },
            .paragraph = .{ .wrap = .no_wrap },
        });
        defer alone.release();
        widest_word = @max(widest_word, alone.inkWidth());
    }
    try testing.expect(widest_word > 0);
    try testing.expectApproxEqAbs(probe_layout.minInkWidth(), widest_word, 0.01);

    // A viewport width is a different question and must not be reported as
    // the ink extent.
    var wrapped = try service.layoutIn(scratch.allocator(), .{
        .content = content,
        .style = .{ .font = .{ .handle = faces, .size = 20 } },
        .paragraph = .{ .wrap = .flow, .wrap_width = 80 },
    });
    defer wrapped.release();
    try testing.expect(wrapped.lines.len > probe_layout.lines.len);
    try testing.expect(wrapped.width <= 80);
    try testing.expect(wrapped.inkWidth() > wrapped.width);
}

// A break opportunity is a boundary, not a segment of its own. The separator
// trails the line it ends, where it is painted, but it never joins the word
// that follows: the minimum stays the widest word a box must show whole.
test "a break separator trails its line and never widens the minimum" {
    var service = try measure.TextService.init(testing.allocator);
    defer service.deinit();
    const faces = try service.addFont(.{ .family = "Inter", .bytes = inter });
    var scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const style: text.TextStyle = .{ .font = .{ .handle = faces, .size = 20 } };

    const letter = try phraseProbes(&service, &scratch, style, "a");
    const word = try phraseProbes(&service, &scratch, style, "bb");
    const space = try phraseProbes(&service, &scratch, style, " ");
    // A space is a real advance and the word outgrows it, so every
    // comparison below fails if a separator is charged to a segment.
    try testing.expect(space.max > 0);
    try testing.expect(word.max > space.max);
    try testing.expect(word.max > letter.max);
    // A separator alone is no content at all: it is a break, so it has no
    // unbreakable minimum of its own.
    try testing.expectEqual(@as(f32, 0), space.min);

    // A separator between two segments, at the start of the content, doubled
    // between two segments, and trailing the last one.
    const middle = try phraseProbes(&service, &scratch, style, "a bb");
    try testing.expectApproxEqAbs(word.max, middle.min, 0.01);
    try testing.expectApproxEqAbs(letter.max + space.max + word.max, middle.max, 0.01);

    const leading = try phraseProbes(&service, &scratch, style, " bb");
    try testing.expectApproxEqAbs(word.max, leading.min, 0.01);
    try testing.expectApproxEqAbs(space.max + word.max, leading.max, 0.01);

    const doubled = try phraseProbes(&service, &scratch, style, "a  bb");
    try testing.expectApproxEqAbs(word.max, doubled.min, 0.01);
    try testing.expectApproxEqAbs(letter.max + 2 * space.max + word.max, doubled.max, 0.01);

    const trailing = try phraseProbes(&service, &scratch, style, "a ");
    try testing.expectApproxEqAbs(letter.max, trailing.min, 0.01);
    try testing.expectApproxEqAbs(letter.max + space.max, trailing.max, 0.01);

    // A separator in front of a hard break is the same break: the painted
    // first line still carries the space, and the second line's word is still
    // a segment measured on its own.
    var split = try service.layoutIn(scratch.allocator(), .{
        .content = "a \nbb",
        .style = style,
        .paragraph = .{ .wrap = .no_wrap },
    });
    defer split.release();
    try testing.expectEqual(@as(usize, 2), split.lines.len);
    try testing.expectApproxEqAbs(word.max, split.minInkWidth(), 0.01);
    try testing.expectApproxEqAbs(@max(letter.max + space.max, word.max), split.inkWidth(), 0.01);
    try testing.expectApproxEqAbs(letter.max + space.max, split.lines[0].width, 0.01);
    try testing.expectApproxEqAbs(word.max, split.lines[1].width, 0.01);
}

// The same rule through the seam core actually calls: the minimum a box needs
// for "a wider" is the word, never the word plus the space that separates it
// from the letter.
test "the min-content probe over the public seam excludes the break separator" {
    var host: measurer.TextMeasurer = undefined;
    try host.init(testing.allocator, sources(), 20);
    defer host.deinit();

    const word = try host.measure("wider", probe(.min_content));
    const phrase = try host.measure("a wider", probe(.min_content));
    // The separator really is an advance, so a seam that charged it to the
    // following word would answer measurably wider than the word alone.
    const separator = try host.measure(" ", probe(.max_content));
    try testing.expect(separator.width > 0);
    try testing.expect(word.width > 0);
    try testing.expectApproxEqAbs(word.width, phrase.width, 0.001);

    // A leading separator, a doubled one and one in front of a hard break are
    // the same break opportunity.
    for ([_][]const u8{ " wider", "a  wider", "a \nwider" }) |content| {
        const measured = try host.measure(content, probe(.min_content));
        try testing.expectApproxEqAbs(word.width, measured.width, 0.001);
    }

    // The line probe is the other question and still counts the separator.
    const ink = try host.measure("a wider", probe(.max_content));
    try testing.expect(ink.width > phrase.width);
}

// The owning measurer answers core's callback with the same layout the paint
// path builds, so a box cannot measure one way and paint another.
test "the owning measurer and the layout the paint path builds agree" {
    var host: measurer.TextMeasurer = undefined;
    try host.init(testing.allocator, sources(), 16);
    defer host.deinit();
    const handles = measurerHandles(&host);
    const node = fallbackNode(&.{handles.fira});
    const content = "alpha beta gamma delta";

    // Every probe is asked through the public measure entry point, which is
    // exactly what core's bound source calls.
    var input = probe(.max_content);
    input.text = &node;
    const max_content = try host.measure(content, input);
    // The paint path's own layout: same content, same style, no width bound.
    var painted = try host.textService().layout(testing.allocator, .{
        .content = content,
        .style = node.style,
    });
    defer painted.release();
    try testing.expectApproxEqAbs(painted.inkWidth(), max_content.width, 0.001);
    try testing.expectApproxEqAbs(painted.height, max_content.height, 0.001);
    // The baseline is the first shaped line's own, not a derived fraction.
    try testing.expectApproxEqAbs(
        painted.runs[0].baseline,
        max_content.first_baseline orelse 0,
        0.001,
    );

    // A definite box reports the width it was offered, because the text needs
    // more than that, and takes more lines than the single-line probe.
    input.available_space.width = .{ .definite = 70 };
    const definite = try host.measure(content, input);
    try testing.expectApproxEqAbs(definite.width, 70, 0.001);
    try testing.expect(definite.height > max_content.height);
    // The wider box reports the text's real ink, never a stretch to fill it.
    input.available_space.width = .{ .definite = 900 };
    const wide = try host.measure(content, input);
    try testing.expectApproxEqAbs(wide.width, max_content.width, 0.001);
    try testing.expectApproxEqAbs(wide.height, max_content.height, 0.001);
    // A min-content probe is the narrowest box that still paints a whole
    // word, so it is strictly narrower than the ink extent.
    input.available_space.width = .min_content;
    const min_content = try host.measure(content, input);
    try testing.expect(min_content.width > 0);
    try testing.expect(min_content.width < max_content.width);
    try testing.expectApproxEqAbs(min_content.height, max_content.height, 0.001);
}

// A node that clamps itself is measured at the width its box offers and
// painted at the width the measure reported. The clamp and its ellipsis must
// not make those two layouts disagree about the block they describe.
test "a clamped node measures the block the paint path draws" {
    var host: measurer.TextMeasurer = undefined;
    try host.init(testing.allocator, sources(), 20);
    defer host.deinit();
    const handles = measurerHandles(&host);
    var scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const content = "alpha beta gamma delta epsilon";
    // The node clamps itself to one line and marks the cut, so the box width
    // is the only thing measure and paint may legitimately differ on.
    const node: text.NodeText = .{
        .style = .{ .font = .{ .handle = handles.inter, .size = 20 } },
        .extra = &.{
            .paragraph = .{ .max_lines = 1, .truncate = .{ .mode = .end, .suffix = "..." } },
        },
    };
    const measured = try host.measure(content, .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .{ .definite = 90 }, .height = .max_content },
        .text = &node,
    });
    // The paint path's own layout of that measured box, with the overflow a
    // host resolves for the box.
    var painted = try host.textService().nodeLayoutIn(scratch.allocator(), content, node, .{
        .width = measured.width,
        .overflow = .ellipsis,
    }, 20);
    defer painted.release();

    // The node clamps itself, so both paths hold one line and the measured
    // height is the height of the block that is painted.
    try testing.expectEqual(@as(usize, 1), painted.lines.len);
    try testing.expectApproxEqAbs(painted.height, measured.height, 0.001);
    // The box the measure reported holds every line the paint draws, and the
    // cut is real: the content's own ink is wider than the painted block.
    try testing.expect(measured.width > 0);
    for (painted.lines) |line| {
        try testing.expect(line.width <= measured.width + 0.01);
    }
    try testing.expect(painted.inkWidth() > painted.width);
    var saw_suffix = false;
    for (painted.runs) |run| {
        if (run.is_suffix) saw_suffix = true;
    }
    try testing.expect(saw_suffix);

    // A content probe of the same node answers the content, never the clamp.
    const max_content = try host.measure(content, .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .text = &node,
    });
    try testing.expectApproxEqAbs(max_content.width, painted.inkWidth(), 0.001);
}

// The HOST's default size applies where a node leaves it unset. A null
// request and an explicit node at that size must be one measurement; a
// request that quietly took `FontRequest`'s own 16 would differ from both.
// The host default here is deliberately NOT 16, so the two policies cannot
// produce the same numbers.
test "a null request and an explicit node both take the host's default size" {
    var host: measurer.TextMeasurer = undefined;
    try host.init(testing.allocator, sources(), 14);
    defer host.deinit();

    const content = "alpha";
    const defaulted = try host.measure(content, .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
    });
    const at_host_default: text.NodeText = .{ .style = .{ .font = .{ .size = 14 } } };
    const explicit_default = try host.measure(content, .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .text = &at_host_default,
    });
    try testing.expectApproxEqAbs(defaulted.width, explicit_default.width, 0.001);
    try testing.expectApproxEqAbs(defaulted.height, explicit_default.height, 0.001);
    try testing.expect(defaulted.height > 0);

    // `FontRequest`'s ordinary 16 is NOT the host's default here, so a seam
    // that substituted it would measure measurably larger.
    const ordinary: text.NodeText = .{ .style = .{ .font = .{ .size = 16 } } };
    const at_16 = try host.measure(content, .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .text = &ordinary,
    });
    try testing.expect(at_16.height > defaulted.height);
    try testing.expect(at_16.width > defaulted.width);

    // The borrowed half binds the same policy to the same service, so a node
    // the engine measures through its own source takes the same 14.
    var scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var borrowed: measurer.NodeMeasurer = undefined;
    borrowed.init(host.textService(), &scratch, 14);
    const source = borrowed.source();
    const borrowed_default = try source.callback(source.context, content, .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
    });
    try testing.expectApproxEqAbs(borrowed_default.width, defaulted.width, 0.001);
    try testing.expectApproxEqAbs(borrowed_default.height, defaulted.height, 0.001);
    try testing.expect(borrowed_default.height < at_16.height);
}

// The engine's default size applies only where a node leaves it unset, and a
// real missing font refuses instead of quietly substituting a substitute.
test "node defaults resolve once and a missing face still refuses" {
    var host: measurer.TextMeasurer = undefined;
    try host.init(testing.allocator, sources(), 16);
    defer host.deinit();

    const uninstalled: text.NodeText = .{
        .style = .{ .font = .{ .family = "No Such Family", .size = 20 } },
    };
    try testing.expectError(error.FontUnavailable, host.measure("alpha", .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .text = &uninstalled,
    }));

    // A stale generation is a missing face too, not a silent default.
    const stale: text.NodeText = .{
        .style = .{ .font = .{ .handle = .{ .index = 99, .generation = 1 }, .size = 20 } },
    };
    try testing.expectError(error.UnknownFont, host.measure("alpha", .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .text = &stale,
    }));
}

// Inline ranges, fallback faces and the notdef policy all reach the same
// layout through the node seam, so an ordinary caption paints what it
// measured: styled runs, a fallback run, and a visible tofu box.
test "styled, fallback and notdef runs survive the node seam" {
    var host: measurer.TextMeasurer = undefined;
    try host.init(testing.allocator, sources(), 20);
    defer host.deinit();
    const handles = measurerHandles(&host);

    // "a" + U+E0BE (Fira only) + U+FFFD (neither face).
    const content = "a\xee\x82\xbe\xf4\x8f\xbf\xbd";
    const node: text.NodeText = .{
        .style = .{
            .font = .{
                .family = "Inter",
                .size = 20,
                .fallback = &.{handles.fira},
            },
            .foreground = .{ 1, 0, 0, 1 },
        },
        .extra = &.{
            .ranges = &.{
                .{
                    // The Fira-only codepoint, bytes 1..4, asked for by weight
                    // alone: the family and the fallback list still inherit.
                    .range = .{ .start = 1, .end = 4 },
                    .override = .{ .font_fields = .{ .weight = 700 } },
                },
            },
        },
    };
    const input: measurer.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .text = &node,
    };
    const measured = try host.measure(content, input);
    try testing.expect(measured.width > 0);
    try testing.expect(measured.first_baseline != null);

    // The paint path lays that same request out for real.
    var layout = try host.textService().layout(testing.allocator, .{
        .content = content,
        .style = node.style,
        .ranges = node.extra.?.ranges,
    });
    defer layout.release();
    try testing.expect(layout.runs.len >= 2);
    var saw_fallback = false;
    var saw_notdef = false;
    var saw_heavy = false;
    for (layout.runs) |run| {
        if (run.font.index == handles.fira.index) saw_fallback = true;
        if (run.missing_glyph) saw_notdef = true;
        if (run.style.font.weight == 700) saw_heavy = true;
    }
    try testing.expect(saw_fallback);
    try testing.expect(saw_notdef);
    try testing.expect(saw_heavy);
    // The measure width is this layout's real ink, so the two paths agree.
    try testing.expectApproxEqAbs(layout.inkWidth(), measured.width, 0.001);
}

// After the shape cache is warm, a repeated caption must not allocate. The
// scratch is reset with retained capacity, so the same content reuses the
// same blocks and the same resident runs. BOTH request shapes are checked:
// the authored node and the null request that resolves through the root
// record, because each is its own cache identity.
test "a warm caption shapes once and allocates nothing" {
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();
    var host: measurer.TextMeasurer = undefined;
    try host.init(gpa, sources(), 20);
    defer host.deinit();
    const handles = measurerHandles(&host);

    const content = "warm caption text";
    const node = fallbackNode(&.{handles.fira});
    const authored: measurer.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .text = &node,
    };
    const nulled: measurer.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
    };
    // Warm up: faces, cache runs and the scratch high-water mark. The null
    // request resolves at the host's 20, so it is a distinct identity from
    // the fallback-node request and must be warmed before the counters pin.
    const warm = try host.measure(content, authored);
    const warm_null = try host.measure(content, nulled);
    try testing.expect(warm_null.height > 0);
    const shapes_after_warm = host.textService().shapeCount();
    try testing.expect(shapes_after_warm > 0);
    counting.allocs = 0;

    var index: usize = 0;
    while (index < 32) : (index += 1) {
        const again = try host.measure(content, authored);
        try testing.expectApproxEqAbs(warm.width, again.width, 0.0001);
        try testing.expectApproxEqAbs(warm.height, again.height, 0.0001);
        const again_null = try host.measure(content, nulled);
        try testing.expectApproxEqAbs(warm_null.width, again_null.width, 0.0001);
        try testing.expectApproxEqAbs(warm_null.height, again_null.height, 0.0001);
    }
    try testing.expectEqual(shapes_after_warm, host.textService().shapeCount());
    try testing.expectEqual(@as(usize, 0), counting.allocs);
}

// An authored family IS the face request, not a hint. The node seam fills a
// handle only when the request names no face at all, so a node that names the
// second registered face must shape from it with no fallback list to rescue
// the codepoint.
test "an authored family is honored instead of the default face" {
    var host: measurer.TextMeasurer = undefined;
    try host.init(testing.allocator, sources(), 20);
    defer host.deinit();
    const handles = measurerHandles(&host);
    // The family name really does select the second registered face, so the
    // assertions below are about the seam and not about the registry.
    try testing.expectEqual(
        handles.fira,
        try host.textService().resolve(.{ .family = "Fira Code" }),
    );

    // U+E0BE is a Nerd Font powerline glyph: the second face covers it and the
    // first does not. This request carries no fallback list.
    const content = "\xee\x82\xbe";
    const authored: text.NodeText = .{
        .style = .{ .font = .{ .family = "Fira Code", .size = 20 } },
    };
    const measured = try host.measure(content, .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .text = &authored,
    });
    try testing.expect(measured.width > 0);

    var layout = try host.textService().layout(testing.allocator, .{
        .content = content,
        .style = authored.style,
    });
    defer layout.release();
    try testing.expectEqual(@as(usize, 1), layout.runs.len);
    try testing.expectEqual(handles.fira, layout.runs[0].font);
    // The named face covers the codepoint, so nothing is missing. A seam that
    // replaced the authored family with the default handle would paint tofu.
    try testing.expect(!layout.runs[0].missing_glyph);
    try testing.expect(layout.runs[0].glyphs[0].gid != 0);
    try testing.expectApproxEqAbs(layout.inkWidth(), measured.width, 0.001);

    // The default face really does lack it, so the assertion above has teeth.
    var defaulted = try host.textService().layout(testing.allocator, .{
        .content = content,
        .style = .{ .font = .{ .handle = handles.inter, .size = 20 } },
    });
    defer defaulted.release();
    try testing.expect(defaulted.runs[0].missing_glyph);
}
