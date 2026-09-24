const std = @import("std");
const hb = @import("harfbuzz");
const nogui = @import("nogui");
const shaping = @import("shape_cache.zig");

const c = hb.c;
const inter_data = @embedFile("InterVariable.ttf");
const fira_data = @embedFile("FiraCodeNerdFont-Regular.ttf");
const zero_width_space = "\xE2\x80\x8B";

const FontFixture = struct {
    library: c.FT_Library,
    face: c.FT_Face,
    font: hb.Font,

    fn init(font_data: []const u8, size: u32) !FontFixture {
        // SAFETY: FT_Init_FreeType writes the handle; failure returns before use.
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        errdefer std.debug.assert(c.FT_Done_FreeType(library) == 0);

        // SAFETY: FT_New_Memory_Face writes the handle; failure returns before use.
        var face: c.FT_Face = undefined;
        std.debug.assert(font_data.len <= std.math.maxInt(u32));
        if (c.FT_New_Memory_Face(
            library,
            font_data.ptr,
            @as(c.FT_Long, @intCast(font_data.len)),
            0,
            &face,
        ) != 0) return error.FreeTypeFaceFailed;
        errdefer std.debug.assert(c.FT_Done_Face(face) == 0);

        if (c.FT_Set_Pixel_Sizes(face, 0, size) != 0) {
            return error.FreeTypeSetPixelSizesFailed;
        }
        const handle = c.hb_ft_font_create_referenced(face) orelse {
            return error.HarfbuzzFailed;
        };
        var font: hb.Font = .{ .handle = handle };
        errdefer font.destroy();
        c.hb_ft_font_set_funcs(handle);
        _ = c.hb_ft_font_set_load_flags(
            handle,
            c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_HINTING,
        );

        return .{
            .library = library,
            .face = face,
            .font = font,
        };
    }

    fn deinit(self: *FontFixture) void {
        self.font.destroy();
        std.debug.assert(c.FT_Done_Face(self.face) == 0);
        std.debug.assert(c.FT_Done_FreeType(self.library) == 0);
        self.* = undefined;
    }
};

const OwnedRun = struct {
    glyphs: []shaping.Glyph,
    width: f32,

    fn deinit(self: *OwnedRun, gpa: std.mem.Allocator) void {
        gpa.free(self.glyphs);
        self.* = undefined;
    }
};

fn shapeUncached(
    gpa: std.mem.Allocator,
    font: hb.Font,
    text: []const u8,
) !OwnedRun {
    var buffer = try hb.Buffer.create();
    defer buffer.destroy();
    buffer.addUTF8(text);
    buffer.setDirection(.ltr);
    buffer.setScript(.latin);
    hb.shape(font, buffer, null);

    const infos = buffer.getGlyphInfos();
    const positions = buffer.getGlyphPositions() orelse return error.NoGlyphPositions;
    if (infos.len != positions.len) return error.GlyphPositionCountMismatch;

    const glyphs = try gpa.alloc(shaping.Glyph, infos.len);
    errdefer gpa.free(glyphs);
    var width: f32 = 0;
    for (infos, positions, glyphs) |info, position, *glyph| {
        if (textClusterIsControl(text, info.cluster)) {
            glyph.* = .{
                .gid = 0,
                .cluster = info.cluster,
                .x_advance = 0,
                .y_advance = 0,
                .x_offset = 0,
                .y_offset = 0,
            };
        } else {
            glyph.* = .{
                .gid = info.codepoint,
                .cluster = info.cluster,
                .x_advance = fixedToFloat(position.x_advance),
                .y_advance = fixedToFloat(position.y_advance),
                .x_offset = fixedToFloat(position.x_offset),
                .y_offset = fixedToFloat(position.y_offset),
            };
        }
        width += glyph.x_advance;
    }
    return .{ .glyphs = glyphs, .width = width };
}

fn fixedToFloat(value: i32) f32 {
    return @floatCast(@as(f64, @floatFromInt(value)) / 64.0);
}

fn textClusterIsControl(text: []const u8, cluster: u32) bool {
    const index: usize = @intCast(cluster);
    if (index >= text.len) return false;
    if (text[index] == '\n' or text[index] == '\r') return true;
    return std.mem.startsWith(u8, text[index..], zero_width_space);
}

fn expectRunEqual(
    expected_text: []const u8,
    expected: *const OwnedRun,
    actual: shaping.Run,
) !void {
    try std.testing.expectEqualStrings(expected_text, actual.text);
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.glyphs.len, actual.glyphs.len);
    for (expected.glyphs, actual.glyphs) |expected_glyph, actual_glyph| {
        try std.testing.expectEqual(expected_glyph.gid, actual_glyph.gid);
        try std.testing.expectEqual(expected_glyph.cluster, actual_glyph.cluster);
        try std.testing.expectEqual(expected_glyph.x_advance, actual_glyph.x_advance);
        try std.testing.expectEqual(expected_glyph.y_advance, actual_glyph.y_advance);
        try std.testing.expectEqual(expected_glyph.x_offset, actual_glyph.x_offset);
        try std.testing.expectEqual(expected_glyph.y_offset, actual_glyph.y_offset);
    }
}

fn glyphEqual(a: shaping.Glyph, b: shaping.Glyph) bool {
    return a.gid == b.gid and
        a.cluster == b.cluster and
        a.x_advance == b.x_advance and
        a.y_advance == b.y_advance and
        a.x_offset == b.x_offset and
        a.y_offset == b.y_offset;
}

fn glyphRunsEqual(a: *const OwnedRun, b: *const OwnedRun) bool {
    if (a.width != b.width) return false;
    if (a.glyphs.len != b.glyphs.len) return false;
    for (a.glyphs, b.glyphs) |a_glyph, b_glyph| {
        if (!glyphEqual(a_glyph, b_glyph)) return false;
    }
    return true;
}

fn expectControlGlyphsZero(text: []const u8, glyphs: []const shaping.Glyph) !void {
    var control_count: usize = 0;
    for (glyphs) |glyph| {
        if (!textClusterIsControl(text, glyph.cluster)) continue;
        control_count += 1;
        try std.testing.expectEqual(@as(u32, 0), glyph.gid);
        try std.testing.expectEqual(@as(f32, 0), glyph.x_advance);
        try std.testing.expectEqual(@as(f32, 0), glyph.y_advance);
        try std.testing.expectEqual(@as(f32, 0), glyph.x_offset);
        try std.testing.expectEqual(@as(f32, 0), glyph.y_offset);
    }
    try std.testing.expect(control_count > 0);
}

fn shapeCount(counters: *const nogui.Counters) !u64 {
    const snapshot = try counters.snapshot();
    return snapshot.value(.harfbuzz_shapes);
}

// This test models two frames with independent mutable input storage. The
// allocator gate proves that the second acquisition needs no cache allocation.
test "identical mutable text storage reuses owned shaping for any layout width" {
    var fixture = try FontFixture.init(inter_data, 18);
    defer fixture.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    var cache = shaping.Cache.init(failing_allocator.allocator());
    defer cache.deinit();
    var counters: nogui.Counters = .{};
    var sink = nogui.CounterSink.init(&counters);

    const text = "office AV wider text";
    const intrinsic_metrics: shaping.IntrinsicMetrics = .{
        .min_width = 37.5,
        .max_width = 142.25,
    };
    const flow_metrics: shaping.FlowMetrics = .{
        .width = 96.5,
        .line_count = 3,
    };
    var first_storage: [text.len]u8 = undefined;
    var second_storage: [text.len]u8 = undefined;
    @memcpy(first_storage[0..], text);
    @memcpy(second_storage[0..], text);
    try std.testing.expectEqualStrings(text, first_storage[0..]);

    var first_width: f32 = 0;
    var first_glyph_count: usize = 0;
    {
        var first = try cache.acquire(
            .{ .font_id = 0, .size = 18 },
            fixture.font,
            first_storage[0..],
            &sink,
        );
        defer first.release();
        try std.testing.expectEqualStrings(text, first.run.text);
        first_storage[0] = 'X';
        try std.testing.expectEqualStrings(text, first.run.text);
        first_width = first.run.width;
        first_glyph_count = first.run.glyphs.len;
        first.storeIntrinsicMetrics(intrinsic_metrics);
        first.storeFlowMetrics(.{
            .line_policy = .flow,
            .normalized_width = flow_metrics.width,
        }, flow_metrics);
    }

    const alloc_index = failing_allocator.alloc_index;
    const resize_index = failing_allocator.resize_index;
    failing_allocator.fail_index = alloc_index;
    failing_allocator.resize_fail_index = resize_index;

    var second = try cache.acquire(
        .{ .font_id = 0, .size = 18 },
        fixture.font,
        second_storage[0..],
        &sink,
    );
    defer second.release();
    try std.testing.expectEqualStrings(text, second.run.text);
    try std.testing.expectEqual(first_width, second.run.width);
    try std.testing.expectEqual(first_glyph_count, second.run.glyphs.len);
    try std.testing.expectEqualDeep(
        intrinsic_metrics,
        second.loadIntrinsicMetrics() orelse return error.MissingIntrinsicMetrics,
    );
    try std.testing.expectEqualDeep(
        flow_metrics,
        second.loadFlowMetrics(.{
            .line_policy = .flow,
            .normalized_width = flow_metrics.width,
        }) orelse return error.MissingFlowMetrics,
    );
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(alloc_index, failing_allocator.alloc_index);
    try std.testing.expectEqual(resize_index, failing_allocator.resize_index);
    if (comptime nogui.options.perf_counters) {
        try std.testing.expectEqual(@as(u64, 1), try shapeCount(&counters));
    }
}

// The oracle uses a fresh real HarfBuzz buffer for every case. Exact field
// comparison detects changes to direction, script, clusters, features, or units.
test "cached glyphs match HarfBuzz for ligatures controls and invalid UTF-8" {
    var fixture = try FontFixture.init(inter_data, 20);
    defer fixture.deinit();
    var cache = shaping.Cache.init(std.testing.allocator);
    defer cache.deinit();
    var sink = nogui.CounterSink.init(null);

    const cases = [_]struct {
        text: []const u8,
        has_control: bool,
    }{
        .{ .text = "AV office ffi", .has_control = false },
        .{ .text = "a\r\nb\n", .has_control = true },
        .{ .text = "a" ++ zero_width_space ++ "b", .has_control = true },
        .{ .text = "a\xFF\xFEb", .has_control = false },
    };
    for (cases) |case| {
        var expected = try shapeUncached(
            std.testing.allocator,
            fixture.font,
            case.text,
        );
        defer expected.deinit(std.testing.allocator);
        var lease = try cache.acquire(
            .{ .font_id = 0, .size = 20 },
            fixture.font,
            case.text,
            &sink,
        );
        defer lease.release();
        try expectRunEqual(case.text, &expected, lease.run);
        if (case.has_control) {
            try expectControlGlyphsZero(case.text, lease.run.glyphs);
        }
    }
}

// Every identity dimension uses the matching real font. The oracle makes a
// same-length text mismatch observable without relying on hash or storage details.
test "text font identity and pixel size cannot alias" {
    var inter_18 = try FontFixture.init(inter_data, 18);
    defer inter_18.deinit();
    var inter_29 = try FontFixture.init(inter_data, 29);
    defer inter_29.deinit();
    var fira_18 = try FontFixture.init(fira_data, 18);
    defer fira_18.deinit();
    var cache = shaping.Cache.init(std.testing.allocator);
    defer cache.deinit();
    var sink = nogui.CounterSink.init(null);

    const base_text = "office AVWim";
    const changed_text = "affine ToWay";
    try std.testing.expectEqual(base_text.len, changed_text.len);

    var expected_base = try shapeUncached(
        std.testing.allocator,
        inter_18.font,
        base_text,
    );
    defer expected_base.deinit(std.testing.allocator);
    var expected_text = try shapeUncached(
        std.testing.allocator,
        inter_18.font,
        changed_text,
    );
    defer expected_text.deinit(std.testing.allocator);
    var expected_font = try shapeUncached(
        std.testing.allocator,
        fira_18.font,
        base_text,
    );
    defer expected_font.deinit(std.testing.allocator);
    var expected_size = try shapeUncached(
        std.testing.allocator,
        inter_29.font,
        base_text,
    );
    defer expected_size.deinit(std.testing.allocator);
    try std.testing.expect(!glyphRunsEqual(&expected_base, &expected_text));
    try std.testing.expect(!glyphRunsEqual(&expected_base, &expected_font));
    try std.testing.expect(!glyphRunsEqual(&expected_base, &expected_size));

    const variants = [_]struct {
        key: shaping.FontKey,
        font: hb.Font,
        text: []const u8,
        expected: *const OwnedRun,
    }{
        .{
            .key = .{ .font_id = 0, .size = 18 },
            .font = inter_18.font,
            .text = base_text,
            .expected = &expected_base,
        },
        .{
            .key = .{ .font_id = 0, .size = 18 },
            .font = inter_18.font,
            .text = changed_text,
            .expected = &expected_text,
        },
        .{
            .key = .{ .font_id = 1, .size = 18 },
            .font = fira_18.font,
            .text = base_text,
            .expected = &expected_font,
        },
        .{
            .key = .{ .font_id = 0, .size = 29 },
            .font = inter_29.font,
            .text = base_text,
            .expected = &expected_size,
        },
    };
    for (variants) |variant| {
        var lease = try cache.acquire(
            variant.key,
            variant.font,
            variant.text,
            &sink,
        );
        defer lease.release();
        try expectRunEqual(variant.text, variant.expected, lease.run);
    }
}

// The held lease stays live while the cache evicts more than its public
// capacity of distinct runs.
test "pinned lease survives more than one cache capacity of acquisitions" {
    comptime std.debug.assert(shaping.entry_capacity == 256);

    var fixture = try FontFixture.init(inter_data, 16);
    defer fixture.deinit();
    var cache = shaping.Cache.init(std.testing.allocator);
    defer cache.deinit();
    var sink = nogui.CounterSink.init(null);

    const pinned_text = "persistent AV office";
    var expected = try shapeUncached(
        std.testing.allocator,
        fixture.font,
        pinned_text,
    );
    defer expected.deinit(std.testing.allocator);
    var pinned = try cache.acquire(
        .{ .font_id = 0, .size = 16 },
        fixture.font,
        pinned_text,
        &sink,
    );
    defer pinned.release();
    try std.testing.expectEqualStrings(pinned_text, pinned.run.text);

    const other_acquisition_count: usize = shaping.entry_capacity + 1;
    for (0..other_acquisition_count) |index| {
        var text_buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &text_buffer,
            "eviction candidate {d}",
            .{index},
        );
        var other = try cache.acquire(
            .{ .font_id = 0, .size = 16 },
            fixture.font,
            text,
            &sink,
        );
        other.release();
    }

    try std.testing.expectEqualStrings(pinned_text, pinned.run.text);
    try expectRunEqual(pinned_text, &expected, pinned.run);
}
// All resident entries are pinned here, so admission must return an owned
// transient run without disturbing the retained leases.
test "all pinned entries return a transient owned lease" {
    comptime std.debug.assert(shaping.entry_capacity == 256);

    var fixture = try FontFixture.init(inter_data, 16);
    defer fixture.deinit();
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    var cache = shaping.Cache.init(failing_allocator.allocator());
    defer cache.deinit();
    var sink = nogui.CounterSink.init(null);

    var leases: [shaping.entry_capacity]shaping.Lease = undefined;
    var lease_count: usize = 0;
    defer {
        var index = lease_count;
        while (index > 0) {
            index -= 1;
            leases[index].release();
        }
    }

    for (0..shaping.entry_capacity) |index| {
        var text_buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &text_buffer,
            "all pinned candidate {d}",
            .{index},
        );
        leases[index] = try cache.acquire(
            .{ .font_id = 0, .size = 16 },
            fixture.font,
            text,
            &sink,
        );
        lease_count += 1;
    }

    var retained_text_buffer: [64]u8 = undefined;
    const retained_text = try std.fmt.bufPrint(
        &retained_text_buffer,
        "all pinned candidate {d}",
        .{0},
    );
    var expected_retained = try shapeUncached(
        std.testing.allocator,
        fixture.font,
        retained_text,
    );
    defer expected_retained.deinit(std.testing.allocator);
    try expectRunEqual(
        retained_text,
        &expected_retained,
        leases[0].run,
    );

    const overflow_text = "all pinned overflow";
    var expected_overflow = try shapeUncached(
        std.testing.allocator,
        fixture.font,
        overflow_text,
    );
    defer expected_overflow.deinit(std.testing.allocator);

    var transient = try cache.acquire(
        .{ .font_id = 0, .size = 16 },
        fixture.font,
        overflow_text,
        &sink,
    );
    try expectRunEqual(overflow_text, &expected_overflow, transient.run);
    transient.storeIntrinsicMetrics(.{ .min_width = 1, .max_width = 2 });
    transient.storeFlowMetrics(.{
        .line_policy = .flow,
        .normalized_width = 2,
    }, .{ .width = 2, .line_count = 1 });
    try std.testing.expect(transient.loadIntrinsicMetrics() == null);
    try std.testing.expect(transient.loadFlowMetrics(.{
        .line_policy = .flow,
        .normalized_width = 2,
    }) == null);
    transient.release();

    const alloc_index = failing_allocator.alloc_index;
    const resize_index = failing_allocator.resize_index;
    failing_allocator.fail_index = alloc_index;
    failing_allocator.resize_fail_index = resize_index;
    if (cache.acquire(
        .{ .font_id = 0, .size = 16 },
        fixture.font,
        overflow_text,
        &sink,
    )) |unexpected_value| {
        var unexpected = unexpected_value;
        unexpected.release();
        return error.AllPinnedRunWasRetained;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(failing_allocator.has_induced_failure);
    try expectRunEqual(
        retained_text,
        &expected_retained,
        leases[0].run,
    );
}

// Repeated ASCII guarantees one cheap glyph per byte. The calculated payload
// crosses the byte budget without exercising expensive complex-script shaping.
test "oversized run is correct transient data and is not retained" {
    const glyph_bytes_per_input = @sizeOf(shaping.Glyph);
    const text_len = shaping.byte_capacity / (glyph_bytes_per_input + 1) + 1;
    comptime std.debug.assert(text_len * (glyph_bytes_per_input + 1) > shaping.byte_capacity);

    var fixture = try FontFixture.init(inter_data, 14);
    defer fixture.deinit();
    const text = try std.testing.allocator.alloc(u8, text_len);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');

    var expected = try shapeUncached(std.testing.allocator, fixture.font, text);
    defer expected.deinit(std.testing.allocator);
    try std.testing.expectEqual(text.len, expected.glyphs.len);

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    var cache = shaping.Cache.init(failing_allocator.allocator());
    defer cache.deinit();
    var sink = nogui.CounterSink.init(null);

    var first = try cache.acquire(
        .{ .font_id = 0, .size = 14 },
        fixture.font,
        text,
        &sink,
    );
    try expectRunEqual(text, &expected, first.run);
    first.storeIntrinsicMetrics(.{ .min_width = 1, .max_width = 2 });
    first.storeFlowMetrics(.{
        .line_policy = .flow,
        .normalized_width = 2,
    }, .{ .width = 2, .line_count = 1 });
    try std.testing.expect(first.loadIntrinsicMetrics() == null);
    try std.testing.expect(first.loadFlowMetrics(.{
        .line_policy = .flow,
        .normalized_width = 2,
    }) == null);
    first.release();

    failing_allocator.fail_index = failing_allocator.alloc_index;
    failing_allocator.resize_fail_index = failing_allocator.resize_index;
    if (cache.acquire(
        .{ .font_id = 0, .size = 14 },
        fixture.font,
        text,
        &sink,
    )) |second_value| {
        var second = second_value;
        second.release();
        return error.OversizedRunWasRetained;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(failing_allocator.has_induced_failure);
}

fn allocationFailureCase(gpa: std.mem.Allocator, font: hb.Font) !void {
    var cache = shaping.Cache.init(gpa);
    defer cache.deinit();
    var sink = nogui.CounterSink.init(null);

    var first = try cache.acquire(
        .{ .font_id = 0, .size = 17 },
        font,
        "allocation cleanup office AV",
        &sink,
    );
    defer first.release();
    try std.testing.expectEqualStrings("allocation cleanup office AV", first.run.text);

    var hit = try cache.acquire(
        .{ .font_id = 0, .size = 17 },
        font,
        "allocation cleanup office AV",
        &sink,
    );
    defer hit.release();
    try std.testing.expectEqual(first.run.width, hit.run.width);
}

// Exhaustive allocator injection covers every retained-run construction edge.
test "allocation failures release partial cache ownership" {
    var fixture = try FontFixture.init(inter_data, 17);
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureCase,
        .{fixture.font},
    );
}

test "payload pressure evicts the older unpinned run before entry capacity" {
    var fixture = try FontFixture.init(inter_data, 14);
    defer fixture.deinit();
    const text_len = shaping.byte_capacity / (2 * (@sizeOf(shaping.Glyph) + 1)) + 1;
    const text_a = try std.testing.allocator.alloc(u8, text_len);
    defer std.testing.allocator.free(text_a);
    const text_b = try std.testing.allocator.alloc(u8, text_len);
    defer std.testing.allocator.free(text_b);
    @memset(text_a, 'x');
    @memset(text_b, 'y');

    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var cache = shaping.Cache.init(allocator.allocator());
    defer cache.deinit();
    const sink = nogui.CounterSink.init(null);
    const key: shaping.FontKey = .{ .font_id = 0, .size = 14 };
    var first = try cache.acquire(key, fixture.font, text_a, &sink);
    first.release();
    var second = try cache.acquire(key, fixture.font, text_b, &sink);
    second.release();

    allocator.fail_index = allocator.alloc_index;
    allocator.resize_fail_index = allocator.resize_index;
    var retained = try cache.acquire(key, fixture.font, text_b, &sink);
    defer retained.release();
    try std.testing.expectEqualStrings(text_b, retained.run.text);
    if (cache.acquire(key, fixture.font, text_a, &sink)) |value| {
        var unexpected = value;
        unexpected.release();
        return error.PayloadBudgetWasExceeded;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

// Filling the fixed entry table reuses the victim's slot. The replacement
// entry must not observe measurement results owned by the evicted text.
test "eviction resets retained measurement metadata" {
    var fixture = try FontFixture.init(inter_data, 18);
    defer fixture.deinit();
    var cache = shaping.Cache.init(std.testing.allocator);
    defer cache.deinit();
    const sink = nogui.CounterSink.init(null);
    const font_key: shaping.FontKey = .{ .font_id = 0, .size = 18 };
    const flow_key: shaping.FlowKey = .{
        .line_policy = .single_line,
        .normalized_width = 73.25,
    };

    var victim = try cache.acquire(font_key, fixture.font, "measurement victim", &sink);
    victim.storeIntrinsicMetrics(.{ .min_width = 31.5, .max_width = 73.25 });
    victim.storeFlowMetrics(flow_key, .{ .width = 73.25, .line_count = 1 });
    victim.release();

    for (0..shaping.entry_capacity) |index| {
        var text_buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &text_buffer,
            "measurement replacement {d}",
            .{index},
        );
        var replacement = try cache.acquire(font_key, fixture.font, text, &sink);
        if (index + 1 == shaping.entry_capacity) {
            try std.testing.expect(replacement.loadIntrinsicMetrics() == null);
            try std.testing.expect(replacement.loadFlowMetrics(flow_key) == null);
        }
        replacement.release();
    }
}
