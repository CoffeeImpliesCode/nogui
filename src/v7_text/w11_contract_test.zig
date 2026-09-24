const std = @import("std");
const text = @import("nogui").text;
const cpu = @import("measure.zig");

const inter = @embedFile("InterVariable.ttf");
const fira = @embedFile("FiraCodeNerdFont-Regular.ttf");

fn fonts(service: *cpu.TextService) !struct { inter: text.FontHandle, fira: text.FontHandle } {
    return .{
        .inter = try service.addFont(.{ .family = "Inter", .bytes = inter, .weight = 400 }),
        .fira = try service.addFont(.{ .family = "Fira Code", .bytes = fira, .weight = 400 }),
    };
}

test "api-w11 validates font handles, requests, metrics and explicit missing glyphs" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    try std.testing.expectEqual(@as(usize, 2), service.listFonts().len);
    try std.testing.expectEqualSlices(u8, inter, (try service.fontSource(installed.inter)).bytes);
    try std.testing.expectError(
        error.UnknownFont,
        service.fontSource(.{ .index = installed.inter.index, .generation = 2 }),
    );
    try std.testing.expectError(error.UnknownFont, service.metrics(.{ .index = 99, .generation = 1 }, 18));
    try std.testing.expectError(error.InvalidFontSize, service.metrics(installed.inter, 0));
    try std.testing.expectError(error.InvalidWeight, service.resolve(.{ .family = "Inter", .weight = 0 }));
    try std.testing.expectError(error.FontUnavailable, service.resolve(.{ .family = "uninstalled" }));
    try std.testing.expectEqual(installed.fira, try service.resolve(.{ .family = "Fira Code" }));
    const metrics = try service.metrics(installed.inter, 18);
    try std.testing.expect(metrics.ascent > 0 and metrics.descent < 0 and metrics.line_height > 0);
    // U+E0BE is a Nerd Font powerline glyph. Face selection follows the real
    // cmap: Inter ships U+E0B0..U+E0B3 but not U+E0BE, so this codepoint is the
    // one that actually forces a fallback.
    try std.testing.expect(!(try service.hasGlyph(installed.inter, 0xe0be)));
    try std.testing.expect(try service.hasGlyph(installed.fira, 0xe0be));

    const request: text.LayoutRequest = .{
        .content = "a\xee\x82\xbe",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18, .fallback = &.{installed.fira} } },
    };
    var layout = try service.layout(std.testing.allocator, request);
    defer layout.deinit();
    try std.testing.expect(layout.runs.len >= 2);
    try std.testing.expectEqual(installed.fira, layout.runs[layout.runs.len - 1].font);
    try std.testing.expect(!layout.runs[layout.runs.len - 1].missing_glyph);
    try std.testing.expectError(error.MissingGlyph, service.layout(std.testing.allocator, .{
        .content = "\xee\x82\xbe",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
        .missing_glyph = .error_if_missing,
    }));
    try std.testing.expectError(error.UnknownFont, service.layout(std.testing.allocator, .{
        .content = "",
        .style = .{ .font = .{ .handle = installed.inter, .fallback = &.{.{ .index = 99, .generation = 1 }} } },
    }));
}

// The registry is the host's decision, so a service handed no face at all
// must refuse every request for one instead of substituting a default. A
// family it does not know, a handle it never issued and a request that names
// no face are three distinct refusals, and none of them may measure, shape
// or cache anything on the way out.
test "api-w11 a service with no configured font refuses every face request and recovers" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();

    // A real family name, and a handle a fresh registry has never issued.
    try std.testing.expectError(error.FontUnavailable, service.resolve(.{ .family = "Inter" }));
    try std.testing.expectError(error.FontUnavailable, service.resolve(.{}));
    try std.testing.expectError(error.UnknownFont, service.resolve(.{ .handle = .{ .index = 0, .generation = 1 } }));
    try std.testing.expectError(error.UnknownFont, service.metrics(.{ .index = 0, .generation = 1 }, 18));
    try std.testing.expectError(error.UnknownFont, service.hasGlyph(.{ .index = 0, .generation = 1 }, 'a'));
    try std.testing.expectError(error.UnknownFont, service.fontSource(.{ .index = 0, .generation = 1 }));
    try std.testing.expectError(error.FontUnavailable, service.layout(std.testing.allocator, .{
        .content = "alpha",
        .style = .{ .font = .{ .family = "Inter", .size = 18 } },
    }));
    // A request that names no face has nothing to fall back on either.
    try std.testing.expectError(error.FontUnavailable, service.layout(std.testing.allocator, .{
        .content = "alpha",
        .style = .{ .font = .{ .size = 18 } },
    }));
    var scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectError(error.FontUnavailable, service.nodeLayoutIn(
        scratch.allocator(),
        "alpha",
        .{},
        .{},
        16,
    ));
    // Not one refusal shaped, cached or answered with an estimate.
    try std.testing.expectEqual(@as(u64, 0), service.shapeCount());

    // The same service and the same requests, one real face later.
    const installed = try service.addFont(.{ .family = "Inter", .bytes = inter });
    try std.testing.expectEqual(installed, try service.resolve(.{ .family = "Inter" }));
    var recovered = try service.layout(std.testing.allocator, .{
        .content = "alpha",
        .style = .{ .font = .{ .family = "Inter", .size = 18 } },
    });
    defer recovered.deinit();
    if (recovered.runs.len == 0) return error.NoRuns;
    try std.testing.expectEqual(installed, recovered.runs[0].font);
    // Glyph ids come from the face's own cmap, so none of them is notdef.
    for (recovered.runs[0].glyphs) |glyph| try std.testing.expect(glyph.gid != 0);
    // The width tracks the pixel size, so it came from the registered face's
    // advances rather than from a constant per-character estimate.
    var larger = try service.layout(std.testing.allocator, .{
        .content = "alpha",
        .style = .{ .font = .{ .family = "Inter", .size = 36 } },
    });
    defer larger.deinit();
    try std.testing.expect(larger.width > recovered.width * 1.5);
    // The node seam a host measures and paints through reaches that same face
    // and agrees with the direct request on the ink it produces.
    var node = try service.nodeLayoutIn(scratch.allocator(), "alpha", .{
        .style = .{ .font = .{ .family = "Inter", .size = 18 } },
    }, .{}, 16);
    defer node.release();
    if (node.runs.len == 0) return error.NoRuns;
    try std.testing.expectEqual(installed, node.runs[0].font);
    try std.testing.expectEqual(recovered.width, node.width);
}

// Slant is a registered style, not something the service synthesises. Both
// pinned faces are upright, so an italic or oblique request must be refused
// rather than quietly answered with the upright face the registry does have.
test "api-w11 an unavailable slant is refused instead of painting the upright face" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try service.addFont(.{ .family = "Inter", .bytes = inter });

    for ([_]text.FontStyle{ .italic, .oblique }) |slant| {
        try std.testing.expectError(
            error.FontUnavailable,
            service.resolve(.{ .family = "Inter", .style = slant }),
        );
        try std.testing.expectError(
            error.FontUnavailable,
            service.resolve(.{ .handle = installed, .style = slant }),
        );
        try std.testing.expectError(error.FontUnavailable, service.layout(std.testing.allocator, .{
            .content = "alpha",
            .style = .{ .font = .{ .handle = installed, .size = 18, .style = slant } },
        }));
    }
    // A refused slant measured nothing, so the upright face it would have
    // borrowed was never shaped and nothing was painted in its place.
    try std.testing.expectEqual(@as(u64, 0), service.shapeCount());

    // The refusal is about the requested style alone: the same handle still
    // resolves upright and lays out from that one registered face.
    try std.testing.expectEqual(installed, try service.resolve(.{ .handle = installed, .style = .normal }));
    var upright = try service.layout(std.testing.allocator, .{
        .content = "alpha",
        .style = .{ .font = .{ .handle = installed, .size = 18 } },
    });
    defer upright.deinit();
    if (upright.runs.len == 0) return error.NoRuns;
    try std.testing.expectEqual(installed, upright.runs[0].font);
    for (upright.runs[0].glyphs) |glyph| try std.testing.expect(glyph.gid != 0);
}

// Family resolution is the whole name in any case, filtered to faces whose
// registered style matches, then nearest by weight. The two registrations
// here are the same pinned variable face declared at two weights, so what is
// under test is only the selection: which registered face a request reaches.
test "api-w11 family selection is an exact name filtered by style and nearest by weight" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const regular = try service.addFont(.{ .family = "Inter", .bytes = inter, .weight = 400 });
    const bold = try service.addFont(.{ .family = "Inter", .bytes = inter, .weight = 700 });

    // The name is the whole name, in any case. A longer name that starts the
    // same is a different family, not this one.
    try std.testing.expectEqual(regular, try service.resolve(.{ .family = "INTER", .weight = 400 }));
    try std.testing.expectError(error.FontUnavailable, service.resolve(.{ .family = "Inter Variable" }));
    // Nearest weight wins from either side. 549 and 551 straddle the midpoint
    // between the two registered weights, so the choice cannot be a threshold.
    try std.testing.expectEqual(regular, try service.resolve(.{ .family = "inter", .weight = 549 }));
    try std.testing.expectEqual(bold, try service.resolve(.{ .family = "Inter", .weight = 551 }));
    // The accepted range is closed at both ends; one step past it is not a
    // weight at all, on the name path and on the handle path alike.
    try std.testing.expectEqual(regular, try service.resolve(.{ .family = "Inter", .weight = 1 }));
    try std.testing.expectEqual(bold, try service.resolve(.{ .family = "Inter", .weight = 1000 }));
    try std.testing.expectError(error.InvalidWeight, service.resolve(.{ .family = "Inter", .weight = 1001 }));
    try std.testing.expectError(error.InvalidWeight, service.resolve(.{ .handle = regular, .weight = 1001 }));

    // The selected face is the one the layout runs on, so a request that
    // resolved to the nearer weight paints through that registration.
    var light_run = try service.layout(std.testing.allocator, .{
        .content = "anonymous",
        .style = .{ .font = .{ .family = "Inter", .size = 20, .weight = 549 } },
    });
    defer light_run.deinit();
    var heavy_run = try service.layout(std.testing.allocator, .{
        .content = "anonymous",
        .style = .{ .font = .{ .family = "Inter", .size = 20, .weight = 551 } },
    });
    defer heavy_run.deinit();
    if (light_run.runs.len == 0 or heavy_run.runs.len == 0) return error.NoRuns;
    try std.testing.expectEqual(regular, light_run.runs[0].font);
    try std.testing.expectEqual(bold, heavy_run.runs[0].font);
}

test "api-w11 fieldwise font overrides inherit family and fallback" {
    const inherited: text.TextStyle = .{
        .font = .{
            .family = "Inter",
            .size = 20,
            .fallback = &.{.{ .index = 3, .generation = 1 }},
        },
    };
    const bold = inherited.resolve(.{ .font_fields = .{ .weight = 700 } });
    try std.testing.expectEqualStrings("Inter", bold.font.family);
    try std.testing.expectEqual(@as(f32, 20), bold.font.size);
    try std.testing.expectEqual(@as(u16, 700), bold.font.weight);
    try std.testing.expectEqual(@as(usize, 1), bold.font.fallback.len);
}

// An owning layout is an immutable snapshot, so it must not read the caller's
// font buffers after `layout` returns. The caller overwrites and frees them
// the moment the call completes; the retained styles, the resolved faces and
// every layout query must still be correct afterwards. This is also the guard
// for the two override shapes an owning copy has to keep distinct: a fieldwise
// override inherits the base family, while a whole request REPLACES it.
test "api-w11 an owning layout outlives the caller's font buffers" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);

    // The caller's own buffers, in an arena the caller owns and can drop.
    var caller: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    const family = try caller.allocator().dupe(u8, "Inter");
    const features = try caller.allocator().dupe(text.Feature, &.{
        .{ .tag = text.tag("liga"), .value = 1 },
    });
    const ranges = try caller.allocator().dupe(text.StyledRange, &.{
        // Fieldwise: the inherited family, size and features must survive.
        .{
            .range = .{ .start = 0, .end = 1 },
            .override = .{ .font_fields = .{ .weight = 700 } },
        },
        // A whole request REPLACES the base one; it does not merge into it.
        .{
            .range = .{ .start = 1, .end = 2 },
            .override = .{ .font = .{ .family = "Fira Code", .size = 20 } },
        },
    });

    var layout = try service.layout(std.testing.allocator, .{
        .content = "ab",
        .style = .{
            .font = .{
                .family = family,
                .size = 20,
                .features = features,
            },
            .foreground = .{ 1, 0, 0, 1 },
        },
        .ranges = ranges,
    });
    defer layout.deinit();
    try std.testing.expect(layout.runs.len >= 2);

    // The caller reclaims its buffers. Overwriting them first makes a layout
    // that still pointed here read known garbage instead of freed memory.
    @memset(family, 'x');
    @memset(std.mem.sliceAsBytes(features), 0xFF);
    caller.deinit();

    var saw_base = false;
    var saw_fieldwise = false;
    var saw_replaced = false;
    for (layout.runs) |run| {
        try std.testing.expect(run.style.font.family.len > 0);
        if (std.mem.eql(u8, run.style.font.family, "Inter")) {
            saw_base = true;
            // The retained feature list is the layout's own copy.
            try std.testing.expectEqual(@as(usize, 1), run.style.font.features.len);
            try std.testing.expectEqual(text.tag("liga"), run.style.font.features[0].tag);
            try std.testing.expectEqual(@as(u32, 1), run.style.font.features[0].value);
            // Fieldwise override: the base request survived, weight did not.
            if (run.style.font.weight == 700) saw_fieldwise = true;
        }
        if (std.mem.eql(u8, run.style.font.family, "Fira Code")) {
            saw_replaced = true;
            // The replaced request resolved to its own face and shaped from it.
            try std.testing.expectEqual(installed.fira, run.font);
            try std.testing.expect(run.glyphs.len > 0);
        }
    }
    try std.testing.expect(saw_base);
    try std.testing.expect(saw_fieldwise);
    try std.testing.expect(saw_replaced);

    // Layout queries still answer from the layout's own graphemes.
    try std.testing.expectEqual(@as(usize, 0), (try layout.byteToPosition(0, .downstream)).line);
    try std.testing.expect(layout.lines.len >= 1);
    try std.testing.expect(layout.inkWidth() > 0);
    const bounds = try layout.rangeBounds(std.testing.allocator, .{ .start = 0, .end = 2 });
    defer std.testing.allocator.free(bounds);
    try std.testing.expect(bounds.len >= 1);
}

test "api-w11 inherited multistyle wraps preserve font and decoration" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const base: text.TextStyle = .{ .font = .{ .handle = installed.inter, .size = 18 } };
    const tinted = base.resolve(.{ .background = .{ .color = .{ 0.1, 0.2, 0.3, 1 } }, .underline = true });
    try std.testing.expect(tinted.underline);
    const runs = [_]text.StyledRange{
        .{ .range = .{ .start = 6, .end = 14 }, .override = .{
            .font = .{ .handle = installed.fira, .size = 18 },
            .background = .{ .color = .{ 0.4, 0.2, 0.1, 1 } },
            .underline = true,
            .strike = true,
        } },
    };
    // The styled word must keep its background and font after wrapping.
    const content = "hello colored words here";
    var layout = try service.layout(std.testing.allocator, .{
        .content = content,
        .style = base,
        .ranges = &runs,
        .paragraph = .{ .wrap_width = 120, .line_height = 27, .alignment = .center },
    });
    defer layout.deinit();
    try std.testing.expect(layout.lines.len >= 2);
    try std.testing.expectEqual(@as(f32, 27) * @as(f32, @floatFromInt(layout.lines.len)), layout.height);
    var found = false;
    for (layout.runs) |run| {
        if (run.start >= 6 and run.start < 14) {
            found = true;
            try std.testing.expect(run.style.underline and run.style.strike);
            try std.testing.expectEqual(installed.fira, run.font);
            try std.testing.expect(run.style.background != null);
            const metrics = try service.metrics(run.font, run.style.font.size);
            try std.testing.expectApproxEqAbs(
                run.y + (27 - metrics.line_height) / 2 + metrics.ascent,
                run.baseline,
                0.01,
            );
            const background = run.backgroundRect(27) orelse return error.MissingBackground;
            try std.testing.expectEqual(run.x, background.x);
            try std.testing.expectEqual(run.width, background.width);
            const underline = run.underlineRect() orelse return error.MissingUnderline;
            const strike = run.strikeRect() orelse return error.MissingStrike;
            try std.testing.expect(underline.y > strike.y);
        }
    }
    try std.testing.expect(found);
    for (layout.lines) |line| try std.testing.expectApproxEqAbs(
        (120 - line.width) / 2,
        line.x,
        0.01,
    );
}

test "api-w11 bidi and extended graphemes keep byte and UTF-16 caret boundaries" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const content = "A \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d e\xcc\x81 \xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa9";
    var layout = try service.layout(std.testing.allocator, .{
        .content = content,
        .style = .{ .font = .{ .handle = installed.inter, .size = 20 } },
        .paragraph = .{ .wrap_width = 110 },
    });
    defer layout.deinit();
    try std.testing.expectEqualStrings(content, layout.content);
    try std.testing.expectError(error.InvalidUtf8Boundary, layout.byteToPosition(3, .downstream));
    try std.testing.expectError(error.InvalidGraphemeBoundary, layout.byteToPosition(12, .downstream));
    try std.testing.expectError(error.InvalidRange, layout.utf16ToByte(11));
    const first_hebrew = try layout.byteToPosition(2, .downstream);
    const next_hebrew = try layout.byteToPosition(4, .downstream);
    try std.testing.expect(first_hebrew.x > next_hebrew.x);
    const emoji = try layout.byteToPosition(15, .downstream);
    try std.testing.expectEqual(@as(usize, 26), (try layout.nextGrapheme(15)).?);
    try std.testing.expectEqual(@as(usize, 15), (try layout.previousGrapheme(26)).?);
    try std.testing.expectEqual(@as(usize, 15), try layout.utf16ToByte(try layout.byteToUtf16(15)));
    try std.testing.expectEqual(@as(usize, 15), (try layout.positionToByte(emoji.line, emoji.x)).byte);
    try std.testing.expectError(error.InvalidUtf8, service.layout(std.testing.allocator, .{
        .content = "a\xff",
        .style = .{ .font = .{ .handle = installed.inter } },
    }));
}

test "api-w11 RTL paragraph start aligns even when first run is Latin" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    var layout = try service.layout(std.testing.allocator, .{
        .content = "ABC \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
        .paragraph = .{ .wrap_width = 300, .direction = .rtl, .alignment = .start },
    });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 1), layout.lines.len);
    try std.testing.expectApproxEqAbs(
        300 - layout.lines[0].width,
        layout.lines[0].x,
        0.01,
    );
    var left = try service.layout(std.testing.allocator, .{
        .content = "ABC \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
        .paragraph = .{ .wrap_width = 300, .direction = .rtl, .alignment = .left },
    });
    defer left.deinit();
    var right = try service.layout(std.testing.allocator, .{
        .content = "ABC \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
        .paragraph = .{ .wrap_width = 300, .direction = .rtl, .alignment = .right },
    });
    defer right.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 0), left.lines[0].x, 0.01);
    try std.testing.expectApproxEqAbs(layout.lines[0].x, right.lines[0].x, 0.01);
}

test "api-w11 selection covers wrapped lines and upstream affinity" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    var layout = try service.layout(std.testing.allocator, .{
        .content = "first second third fourth",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
        .paragraph = .{ .wrap_width = 105 },
    });
    defer layout.deinit();
    try std.testing.expect(layout.lines.len >= 2);
    const selection = try layout.rangeBounds(std.testing.allocator, .{ .start = 6, .end = 24 });
    defer std.testing.allocator.free(selection);
    try std.testing.expect(selection.len >= 2);
    try std.testing.expect(selection[0].y < selection[1].y);
    const end = layout.lines[0].end;
    const upstream = try layout.byteToPosition(end, .upstream);
    const downstream = try layout.byteToPosition(end, .downstream);
    try std.testing.expectEqual(@as(usize, 0), upstream.line);
    try std.testing.expectEqual(@as(usize, 1), downstream.line);
}

test "api-w11 RTL soft wrap keeps visual caret affinity" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    var layout = try service.layout(std.testing.allocator, .{
        .content = "\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d \xd7\xa2\xd7\x95\xd7\x9c\xd7\x9d",
        .style = .{ .font = .{ .handle = installed.inter, .size = 20 } },
        .paragraph = .{ .direction = .rtl, .wrap_width = 65 },
    });
    defer layout.deinit();
    try std.testing.expect(layout.lines.len >= 2);
    const end = layout.lines[0].end;
    const upstream = try layout.byteToPosition(end, .upstream);
    const downstream = try layout.byteToPosition(end, .downstream);
    try std.testing.expectEqual(@as(usize, 0), upstream.line);
    try std.testing.expectEqual(@as(usize, 1), downstream.line);
    try std.testing.expectApproxEqAbs(layout.lines[0].x, upstream.x, 0.01);
    try std.testing.expectApproxEqAbs(layout.lines[1].x + layout.lines[1].width, downstream.x, 0.01);
}

test "api-w11 clamp and start middle end suffix truncation match measured lines" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const original = "alpha beta gamma delta epsilon";
    for ([_]text.TruncateMode{ .start, .middle, .end }) |mode| {
        var layout = try service.layout(std.testing.allocator, .{
            .content = original,
            .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
            .paragraph = .{ .wrap_width = 100, .max_lines = 2, .truncate = .{ .mode = mode, .suffix = ".." } },
        });
        defer layout.deinit();
        try std.testing.expectEqual(@as(usize, 2), layout.lines.len);
        // The clamp dropped the rest of the paragraph, so the painted block
        // is the bound while the real ink extent is wider than it.
        try std.testing.expect(layout.inkWidth() > 100);
        try std.testing.expect(layout.lines[1].width <= 100);
        try std.testing.expectEqual(layout.height, layout.lines[1].y + layout.lines[1].height);
        const final_runs = layout.runs[layout.lines[1].first_run..layout.lines[1].end_run];
        var suffix_index: ?usize = null;
        for (final_runs, 0..) |run, i| {
            if (run.is_suffix) {
                suffix_index = i;
                try std.testing.expectEqualStrings("..", run.text);
            }
        }
        const index = suffix_index orelse return error.MissingSuffix;
        switch (mode) {
            .start => try std.testing.expectEqual(@as(usize, 0), index),
            .middle => try std.testing.expect(index > 0 and index + 1 < final_runs.len),
            .end => try std.testing.expectEqual(final_runs.len - 1, index),
        }
    }
    var no_wrap = try service.layout(std.testing.allocator, .{
        .content = original,
        .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
        .paragraph = .{ .wrap = .no_wrap, .wrap_width = 30 },
    });
    defer no_wrap.deinit();
    try std.testing.expectEqual(@as(usize, 1), no_wrap.lines.len);
    try std.testing.expect(no_wrap.width > 30);
}

// The line clamp and the truncation suffix change what is PAINTED, and they
// do not change what the content is. The probes answer the content, so a
// clamped layout reports the same extents as the same text laid out
// unclamped: the widest line it has, and the widest unbreakable segment in
// it. This is the width-independence the max-content probe exists for, and
// a consumer reads it back to learn that a node was cut.
test "api-w11 a line clamp keeps the content extent the probes report" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const style: text.TextStyle = .{ .font = .{ .handle = installed.inter, .size = 18 } };
    // Three hard-broken lines, so the clamp really drops a painted line.
    const content = "alpha beta\ngamma delta\nzeta epsilon";

    var clamped = try service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .paragraph = .{
            .wrap = .flow,
            .wrap_width = 70,
            .max_lines = 2,
            .truncate = .{ .mode = .end, .suffix = ".." },
        },
    });
    defer clamped.deinit();
    try std.testing.expectEqual(@as(usize, 2), clamped.lines.len);

    var plain = try service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .paragraph = .{ .wrap = .no_wrap },
    });
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 3), plain.lines.len);

    // The clamp is not part of the content-extent question.
    try std.testing.expectApproxEqAbs(plain.inkWidth(), clamped.inkWidth(), 0.01);
    try std.testing.expectApproxEqAbs(plain.minInkWidth(), clamped.minInkWidth(), 0.01);
    // The painted block is the bound; the content's own ink is wider than it,
    // and that difference is how a host learns the text was cut.
    try std.testing.expect(clamped.inkWidth() > clamped.width);
    // The reported extent is a measured line of the same content, not the
    // wrap width and not a hidden line's guess.
    var widest: f32 = 0;
    for (plain.lines) |line| widest = @max(widest, line.width);
    try std.testing.expectApproxEqAbs(widest, clamped.inkWidth(), 0.01);
    var widest_segment: f32 = 0;
    for ([_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta" }) |segment| {
        var alone = try service.layout(std.testing.allocator, .{
            .content = segment,
            .style = style,
            .paragraph = .{ .wrap = .no_wrap },
        });
        defer alone.deinit();
        widest_segment = @max(widest_segment, alone.inkWidth());
    }
    try std.testing.expect(widest_segment > 0);
    try std.testing.expectApproxEqAbs(widest_segment, clamped.minInkWidth(), 0.01);
}

test "api-w11 explicit suffix uses per-run font fallback" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    var layout = try service.layout(std.testing.allocator, .{
        .content = "abcdefghijklmno",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18, .fallback = &.{installed.fira} } },
        .paragraph = .{ .wrap_width = 70, .max_lines = 1, .truncate = .{ .suffix = "A\xee\x82\xbe" } },
    });
    defer layout.deinit();
    var saw_inter = false;
    var saw_fira = false;
    for (layout.runs) |run| {
        if (!run.is_suffix) continue;
        try std.testing.expect(!run.missing_glyph);
        if (run.font.index == installed.inter.index) saw_inter = true;
        if (run.font.index == installed.fira.index) saw_fira = true;
    }
    try std.testing.expect(saw_inter and saw_fira);
}

test "api-w11 cache reuses unchanged Latin and separates generation weight features direction" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const request: text.LayoutRequest = .{
        .content = "AV office",
        .content_generation = 1,
        .style = .{ .font = .{ .handle = installed.inter, .size = 20 } },
    };
    var one = try service.layout(std.testing.allocator, request);
    defer one.deinit();
    const used = service.shapeCount();
    var same = try service.layout(std.testing.allocator, request);
    defer same.deinit();
    try std.testing.expectEqual(used, service.shapeCount());
    const changes = [_]text.LayoutRequest{
        .{
            .content = request.content,
            .content_generation = 2,
            .style = request.style,
        },
        .{
            .content = request.content,
            .content_generation = 1,
            .style = .{ .font = .{ .handle = installed.inter, .size = 20, .weight = 700 } },
        },
        .{
            .content = request.content,
            .content_generation = 1,
            .style = .{ .font = .{
                .handle = installed.inter,
                .size = 20,
                .features = &.{.{ .tag = text.tag("kern"), .value = 0 }},
            } },
        },
        .{
            .content = request.content,
            .content_generation = 1,
            .style = request.style,
            .paragraph = .{ .direction = .rtl },
        },
    };
    for (changes) |variant| {
        const previous = service.shapeCount();
        var shaped = try service.layout(std.testing.allocator, variant);
        defer shaped.deinit();
        try std.testing.expect(service.shapeCount() > previous);
    }
}

test "api-w11 hard breaks own one line each and no run paints the break" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const style: text.TextStyle = .{ .font = .{ .handle = installed.inter, .size = 18 } };
    const metrics = try service.metrics(installed.inter, 18);

    var layout = try service.layout(std.testing.allocator, .{
        .content = "ab\ncd",
        .style = style,
    });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 2), layout.lines.len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[0].end);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].start);
    try std.testing.expectEqual(@as(usize, 5), layout.lines[1].end);
    try std.testing.expectEqual(metrics.line_height, layout.lines[0].height);
    try std.testing.expectEqual(layout.lines[0].height, layout.lines[1].y);
    try std.testing.expectEqual(2 * metrics.line_height, layout.height);
    // The break is a line boundary, never painted glyph ink.
    for (layout.runs) |run| {
        try std.testing.expect(!(run.start <= 2 and run.end > 2));
    }

    var crlf = try service.layout(std.testing.allocator, .{
        .content = "a\r\nb",
        .style = style,
    });
    defer crlf.deinit();
    try std.testing.expectEqual(@as(usize, 2), crlf.lines.len);
    try std.testing.expectEqual(@as(usize, 0), crlf.lines[0].start);
    try std.testing.expectEqual(@as(usize, 3), crlf.lines[0].end);
    try std.testing.expectEqual(@as(usize, 3), crlf.lines[1].start);
    try std.testing.expectEqual(@as(usize, 4), crlf.lines[1].end);
}

test "api-w11 empty content keeps one empty line and valid zero offsets" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const metrics = try service.metrics(installed.inter, 18);
    var layout = try service.layout(std.testing.allocator, .{
        .content = "",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
    });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 1), layout.lines.len);
    try std.testing.expectEqual(@as(usize, 0), layout.runs.len);
    try std.testing.expectEqual(@as(f32, 0), layout.width);
    try std.testing.expectEqual(metrics.line_height, layout.height);
    const position = try layout.byteToPosition(0, .downstream);
    try std.testing.expectEqual(@as(usize, 0), position.line);
    try std.testing.expectEqual(@as(f32, 0), position.x);
    try std.testing.expectEqual(@as(usize, 0), try layout.byteToUtf16(0));
    try std.testing.expectEqual(@as(usize, 0), try layout.utf16ToByte(0));
    try std.testing.expectEqual(@as(?usize, null), try layout.nextGrapheme(0));
    try std.testing.expectEqual(@as(?usize, null), try layout.previousGrapheme(0));
}

test "api-w11 rejects invalid wrap clamp height suffix and styled range policy" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const style: text.TextStyle = .{ .font = .{ .handle = installed.inter, .size = 18 } };
    const content = "alpha beta";
    try std.testing.expectError(error.InvalidLineClamp, service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .paragraph = .{ .max_lines = 0 },
    }));
    try std.testing.expectError(error.InvalidWrapWidth, service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .paragraph = .{ .wrap_width = -1 },
    }));
    try std.testing.expectError(error.InvalidWrapWidth, service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .paragraph = .{ .wrap_width = std.math.nan(f32) },
    }));
    try std.testing.expectError(error.InvalidLineHeight, service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .paragraph = .{ .line_height = 0 },
    }));
    try std.testing.expectError(error.InvalidSuffix, service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .paragraph = .{ .truncate = .{ .suffix = "a\nb" } },
    }));
    try std.testing.expectError(error.InvalidUtf8, service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .paragraph = .{ .truncate = .{ .suffix = "\xff" } },
    }));
    try std.testing.expectError(error.InvalidRange, service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .ranges = &.{.{ .range = .{ .start = 0, .end = 99 } }},
    }));
    try std.testing.expectError(error.InvalidRange, service.layout(std.testing.allocator, .{
        .content = content,
        .style = style,
        .ranges = &.{.{ .range = .{ .start = 6, .end = 2 } }},
    }));
    // A styled range may not begin on a UTF-8 continuation byte: offset 2 is
    // the trailing byte of the two-byte U+0301 that follows "a". That is a
    // decoding error, reported before any grapheme rule applies.
    try std.testing.expectError(error.InvalidUtf8Boundary, service.layout(std.testing.allocator, .{
        .content = "a\xcc\x81b",
        .style = style,
        .ranges = &.{.{ .range = .{ .start = 2, .end = 3 } }},
    }));
    // Offset 1 is a well-formed scalar boundary that is not a grapheme start:
    // "a" and U+0301 form one cluster. That is a segmentation error.
    try std.testing.expectError(error.InvalidGraphemeBoundary, service.layout(std.testing.allocator, .{
        .content = "a\xcc\x81b",
        .style = style,
        .ranges = &.{.{ .range = .{ .start = 1, .end = 3 } }},
    }));
    // The same rule holds inside a ZWJ sequence, where the offset is again a
    // valid scalar boundary but not a cluster boundary.
    try std.testing.expectError(error.InvalidGraphemeBoundary, service.layout(std.testing.allocator, .{
        .content = "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa9",
        .style = style,
        .ranges = &.{.{ .range = .{ .start = 4, .end = 11 } }},
    }));
}

test "api-w11 truncation keeps the line inside its bound and reports an oversized suffix" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const style: text.TextStyle = .{ .font = .{ .handle = installed.inter, .size = 18 } };

    // No room for a letter: the explicit suffix is the whole line.
    var layout = try service.layout(std.testing.allocator, .{
        .content = "alpha beta gamma",
        .style = style,
        .paragraph = .{
            .wrap = .no_wrap,
            .wrap_width = 14,
            .max_lines = 1,
            .truncate = .{ .suffix = ".." },
        },
    });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 1), layout.lines.len);
    // The suffix is all that fits, so the painted line is the bound while the
    // real ink extent is wider than it.
    try std.testing.expect(layout.inkWidth() > 14);
    try std.testing.expect(layout.lines[0].width <= 14);
    var suffix_runs: usize = 0;
    var painted: usize = 0;
    for (layout.runs) |run| {
        if (run.is_suffix) suffix_runs += 1;
        painted += run.glyphs.len;
    }
    try std.testing.expectEqual(@as(usize, 1), suffix_runs);
    try std.testing.expect(painted > 0);

    // A suffix that cannot fit the bound is reported, never silently clipped.
    try std.testing.expectError(error.SuffixTooWide, service.layout(std.testing.allocator, .{
        .content = "alpha beta gamma",
        .style = style,
        .paragraph = .{
            .wrap = .no_wrap,
            .wrap_width = 10,
            .max_lines = 1,
            .truncate = .{ .suffix = "MMMMMMMMMMMMMMMMMMMM" },
        },
    }));
}

test "api-w11 clamped bytes are hidden and one line selection is one rect" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    var layout = try service.layout(std.testing.allocator, .{
        .content = "first second third fourth",
        .style = .{ .font = .{ .handle = installed.inter, .size = 18 } },
        .paragraph = .{ .wrap_width = 105, .max_lines = 1, .truncate = .{ .suffix = ".." } },
    });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 1), layout.lines.len);
    // A grapheme start past the clamp has no position; it is not folded onto line 0.
    try std.testing.expectError(error.HiddenText, layout.byteToPosition(13, .downstream));
    const selection = try layout.rangeBounds(std.testing.allocator, .{ .start = 0, .end = 5 });
    defer std.testing.allocator.free(selection);
    try std.testing.expectEqual(@as(usize, 1), selection.len);
    try std.testing.expectEqual(layout.lines[0].height, selection[0].height);
    try std.testing.expectEqual(layout.lines[0].y, selection[0].y);
}

test "api-w11 a disabled font feature widens the shaped run" {
    var service = try cpu.TextService.init(std.testing.allocator);
    defer service.deinit();
    const installed = try fonts(&service);
    const style: text.TextStyle = .{ .font = .{ .handle = installed.inter, .size = 20 } };
    var kerned = try service.layout(std.testing.allocator, .{ .content = "AV", .style = style });
    defer kerned.deinit();
    var unkerned = try service.layout(std.testing.allocator, .{
        .content = "AV",
        .style = style.resolve(.{ .font_fields = .{
            .features = &.{.{ .tag = text.tag("kern"), .value = 0 }},
        } }),
    });
    defer unkerned.deinit();
    try std.testing.expectEqual(@as(usize, 1), kerned.runs.len);
    try std.testing.expectEqual(@as(usize, 1), unkerned.runs.len);
    // The same content, one feature off: the pair is measurably wider.
    try std.testing.expect(kerned.width < unkerned.width);
    // A feature change reshapes the same run; it does not re-segment it.
    try std.testing.expectEqual(
        kerned.runs[0].glyphs.len,
        unkerned.runs[0].glyphs.len,
    );
}
