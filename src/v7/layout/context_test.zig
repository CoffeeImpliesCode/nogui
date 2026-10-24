//! Specifies the natural-measure request validation contract.

const std = @import("std");
const FrameNodeId = @import("../id.zig").FrameNodeId;
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const context = @import("context.zig");

const Style = style.Style;
const WidgetTree = widget.WidgetTree;

test "MeasurementCache distinguishes absent and zero optional constraints" {
    var cache: context.MeasurementCache = .{};
    defer cache.deinit(std.testing.allocator);

    const requests = [_]context.Request{
        .{
            .available = .{ .width = 100, .height = 80 },
            .percentage_basis = .{ .width = null, .height = null },
        },
        .{
            .available = .{ .width = 100, .height = 80 },
            .percentage_basis = .{ .width = 0, .height = null },
        },
        .{
            .available = .{ .width = 100, .height = 80 },
            .percentage_basis = .{ .width = -0.0, .height = null },
        },
        .{
            .available = .{ .width = 100, .height = 80 },
            .percentage_basis = .{ .width = null, .height = 0 },
        },
        .{
            .available = .{ .width = 100, .height = 80 },
            .percentage_basis = .{ .width = null, .height = null },
            .known_border = .{ .width = 0, .height = null },
        },
        .{
            .available = .{ .width = 100, .height = 80 },
            .percentage_basis = .{ .width = null, .height = null },
            .known_border = .{ .width = null, .height = 0 },
        },
    };

    for (requests, 0..) |request, index| {
        const value: f32 = @floatFromInt(index + 1);
        try cache.insert(
            std.testing.allocator,
            context.MeasurementCache.key(7, request, null),
            .{
                .content = .{ .width = value, .height = value + 10 },
                .border = .{ .width = value + 20, .height = value + 30 },
            },
        );
    }

    for (requests, 0..) |request, index| {
        const value: f32 = @floatFromInt(index + 1);
        try std.testing.expectEqual(
            @as(?context.Measured, .{
                .content = .{ .width = value, .height = value + 10 },
                .border = .{ .width = value + 20, .height = value + 30 },
            }),
            cache.lookup(context.MeasurementCache.key(7, request, null)),
        );
    }
}

test "MeasurementCache distinguishes sizing constraints and parent display" {
    var cache: context.MeasurementCache = .{};
    defer cache.deinit(std.testing.allocator);

    const CacheCase = struct {
        node_index: usize = 7,
        request: context.Request,
        parent_display: ?style.Display = null,
    };
    const cases = [_]CacheCase{
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
            },
        },
        .{
            .node_index = 8,
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
            },
        },
        .{
            .request = .{
                .available = .{ .width = 101, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 81 },
                .percentage_basis = .{ .width = 50, .height = 40 },
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 51, .height = 40 },
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 41 },
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
                .width_mode = .min_content,
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
                .width_mode = .max_content,
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
                .height_mode = .min_content,
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
                .height_mode = .max_content,
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
                .sizing_mode = .content,
            },
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
            },
            .parent_display = .block,
        },
        .{
            .request = .{
                .available = .{ .width = 100, .height = 80 },
                .percentage_basis = .{ .width = 50, .height = 40 },
            },
            .parent_display = .flex,
        },
    };

    for (cases, 0..) |case, index| {
        const value: f32 = @floatFromInt(index + 1);
        try cache.insert(
            std.testing.allocator,
            context.MeasurementCache.key(
                case.node_index,
                case.request,
                case.parent_display,
            ),
            .{
                .content = .{ .width = value, .height = value + 20 },
                .border = .{ .width = value + 40, .height = value + 60 },
            },
        );
    }

    for (cases, 0..) |case, index| {
        const value: f32 = @floatFromInt(index + 1);
        try std.testing.expectEqual(
            @as(?context.Measured, .{
                .content = .{ .width = value, .height = value + 20 },
                .border = .{ .width = value + 40, .height = value + 60 },
            }),
            cache.lookup(context.MeasurementCache.key(
                case.node_index,
                case.request,
                case.parent_display,
            )),
        );
    }
}

fn appendRoot(tree: *WidgetTree, node_style: Style) !*const widget.WidgetNode {
    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = node_style,
    });
    return tree.nodeConst(root_id) orelse error.TestUnexpectedResult;
}

test "natural request accepts explicit width percentage basis that differs from available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .{ .percent = 0.5 },
            .height = .auto,
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = 200, .height = null },
    });
}

test "natural request defers width percentages when the basis is indefinite" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .{ .percent = 0.5 },
            .height = .auto,
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = null, .height = null },
    });
}

test "natural request accepts explicit height percentage basis that differs from available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .auto,
            .height = .{ .percent = 0.5 },
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = null, .height = 200 },
    });
}

test "natural request defers height percentages when the basis is indefinite" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{
        .display = .block,
        .size = .{
            .width = .auto,
            .height = .{ .percent = 0.5 },
        },
    });

    try context.validateNaturalRequest(&tree, root, .{
        .available = .{ .width = 100, .height = 100 },
        .percentage_basis = .{ .width = null, .height = null },
    });
}

test "natural request rejects non-concrete available space" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try appendRoot(&tree, .{ .display = .block });

    try std.testing.expectError(
        error.InvalidStyle,
        context.validateNaturalRequest(&tree, root, .{
            .available = .{ .width = -1, .height = 100 },
            .percentage_basis = .{ .width = null, .height = null },
        }),
    );
    try std.testing.expectError(
        error.InvalidStyle,
        context.validateNaturalRequest(&tree, root, .{
            .available = .{ .width = 100, .height = std.math.nan(f32) },
            .percentage_basis = .{ .width = null, .height = null },
        }),
    );
}

test "measureText: ellipsis forces single-line policy without a width cap, clip stays flow" {
    const policyMeasure = struct {
        fn measure(
            _: ?*anyopaque,
            _: []const u8,
            input: context.MeasureInput,
        ) context.LayoutError!context.TextMeasurement {
            return .{
                .width = if (input.line_policy == .single_line) 40 else 20,
                .height = if (input.line_policy == .single_line) 10 else 30,
            };
        }
    }.measure;
    const source: context.MeasureSource = .{ .callback = policyMeasure };
    const input: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .{ .definite = 20 }, .height = .max_content },
    };

    const bounded = try context.measureTextSize(source, "a\nb", input, .ellipsis, 20);
    try std.testing.expectEqual(@as(f32, 20), bounded.width);
    try std.testing.expectEqual(@as(f32, 10), bounded.height);
    const unbounded_ellipsis = try context.measureTextSize(source, "a\nb", input, .ellipsis, null);
    try std.testing.expectEqual(@as(f32, 40), unbounded_ellipsis.width);
    try std.testing.expectEqual(@as(f32, 10), unbounded_ellipsis.height);
    const unbounded_clip = try context.measureTextSize(source, "a\nb", input, .clip, null);
    try std.testing.expectEqual(@as(f32, 20), unbounded_clip.width);
    try std.testing.expectEqual(@as(f32, 30), unbounded_clip.height);
}

/// A provider that reports intrinsic content metrics plus a shaped first
/// baseline, the shape every real measurer answers with.
const BaselineMeasureProbe = struct {
    fn measure(_: ?*anyopaque, _: []const u8, _: context.MeasureInput) context.LayoutError!context.TextMeasurement {
        return .{ .width = 40, .height = 12, .first_baseline = 9 };
    }

    const source: context.MeasureSource = .{ .callback = measure };
};

const RefusingMeasureProbe = struct {
    fn measure(_: ?*anyopaque, _: []const u8, _: context.MeasureInput) context.LayoutError!context.TextMeasurement {
        return error.UnknownFont;
    }

    const source: context.MeasureSource = .{ .callback = measure };
};

test "a known box dimension overrides its own axis and leaves the other intrinsic" {
    const measured = try context.measureContent(BaselineMeasureProbe.source, "abcd", .{
        .known_dimensions = .{ .width = 100, .height = null },
        .available_space = .{ .width = .{ .definite = 100 }, .height = .max_content },
    });

    try std.testing.expectEqual(@as(f32, 100), measured.width);
    try std.testing.expectEqual(@as(f32, 12), measured.height);
}

test "a known box keeps the baseline its provider supplied" {
    const measured = try context.measureContent(BaselineMeasureProbe.source, "abcd", .{
        .known_dimensions = .{ .width = 100, .height = 30 },
        .available_space = .{ .width = .{ .definite = 100 }, .height = .max_content },
    });

    try std.testing.expectEqual(@as(f32, 100), measured.width);
    try std.testing.expectEqual(@as(f32, 30), measured.height);
    try std.testing.expectEqual(@as(?f32, 9), measured.first_baseline);
}

/// A provider that shapes exactly the content it is handed, so a caller can
/// tell which string the layout asked for and where that line sits.
const ShapedContentProbe = struct {
    fn measure(
        _: ?*anyopaque,
        content: []const u8,
        _: context.MeasureInput,
    ) context.LayoutError!context.TextMeasurement {
        const units: f32 = @floatFromInt(content.len);
        return .{ .width = units * 10, .height = 12, .first_baseline = units };
    }

    const source: context.MeasureSource = .{ .callback = measure };
};

test "cached visible text shapes a label and keeps a control's caption insets" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const root_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = root_id,
        .kind = .{ .column = .{} },
        .parent = .root,
    });
    const label_id: FrameNodeId = @fromBackingInt(@intCast(2));
    try tree.appendNode(.{
        .id = label_id,
        .kind = .{ .label = .{ .text = "abcd" } },
        .parent = root_id,
    });
    const progress_id: FrameNodeId = @fromBackingInt(@intCast(3));
    try tree.appendNode(.{
        .id = progress_id,
        .kind = .{ .progress = .{ .label = "OK", .value = 0, .min = 0, .max = 1 } },
        .parent = root_id,
    });

    const label = tree.nodeConst(label_id) orelse return error.TestUnexpectedResult;
    const progress = tree.nodeConst(progress_id) orelse return error.TestUnexpectedResult;

    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = ShapedContentProbe.source,
        .measure_node = testMeasureNode,
        .layout_node = testLayoutNode,
    };
    defer layout_context.deinit();

    const input: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
    };

    const label_measured = try layout_context.measureVisibleNodeTextCached(1, label, input);
    try std.testing.expectEqual(@as(f32, 40), label_measured.width);
    try std.testing.expectEqual(@as(?f32, 4), label_measured.first_baseline);
    // The shaped line answers the baseline, not the synthetic 0.8-of-size
    // fallback that an unmeasured caption would leave behind.
    try std.testing.expectEqual(
        @as(?f32, 7),
        try context.textNodeBaseline(label, 3, label_measured),
    );

    // The progress caption keeps its own 100px floor and its bottom inset, so
    // the shaped line lands above the box bottom rather than on it.
    const progress_measured = try layout_context.measureVisibleNodeTextCached(2, progress, input);
    try std.testing.expectEqual(@as(f32, 100), progress_measured.width);
    try std.testing.expectEqual(@as(f32, 26), progress_measured.height);
    try std.testing.expectEqual(@as(?f32, 16), progress_measured.first_baseline);
    try std.testing.expectEqual(
        @as(?f32, 19),
        try context.textNodeBaseline(progress, 3, progress_measured),
    );
}

test "a provider refusal reaches the caller instead of an estimate" {
    try std.testing.expectError(
        error.UnknownFont,
        context.measureContent(RefusingMeasureProbe.source, "abcd", .{
            .known_dimensions = .{ .width = null, .height = null },
            .available_space = .{ .width = .max_content, .height = .max_content },
        }),
    );
}

test "the layout-only fallback measures content when no host supplies a font" {
    const measured = try context.measureContent(null, "abc", .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
    });

    try std.testing.expectEqual(@as(f32, 30), measured.width);
    try std.testing.expectEqual(@as(f32, 20), measured.height);
}

const TextMeasureProbe = struct {
    fn measure(
        _: ?*anyopaque,
        content: []const u8,
        input: context.MeasureInput,
    ) context.LayoutError!context.TextMeasurement {
        return .{
            .width = @floatFromInt(content.len * 10),
            .height = if (input.line_policy == .single_line) 7 else 13,
        };
    }

    const source: context.MeasureSource = .{ .callback = measure };
};

test "TextMeasurementCache reuses normalized text input without sharing width caps" {
    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = TextMeasureProbe.source,
        .measure_node = testMeasureNode,
        .layout_node = testLayoutNode,
    };
    defer layout_context.deinit();

    const input: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{
            .width = .{ .definite = 20 },
            .height = .{ .definite = 40 },
        },
    };
    const bounded = try layout_context.measureTextCached(
        7,
        "abcd",
        input,
        .ellipsis,
        20,
    );
    const more_bounded = try layout_context.measureTextCached(
        7,
        "abcd",
        input,
        .ellipsis,
        10,
    );

    try std.testing.expectEqual(@as(f32, 20), bounded.width);
    try std.testing.expectEqual(@as(f32, 10), more_bounded.width);
    try std.testing.expectEqual(@as(f32, 7), bounded.height);
}

test "unconstrained text entry distinguishes line policy as well as ink width" {
    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = TextMeasureProbe.source,
        .measure_node = testMeasureNode,
        .layout_node = testLayoutNode,
    };
    defer layout_context.deinit();

    const single_line: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
    };
    // An ellipsis request forces the single-line policy, so the measurement
    // the provider answers with is recorded under that policy.
    const single = try layout_context.measureTextCached(
        7,
        "abcd",
        single_line,
        .ellipsis,
        null,
    );
    try std.testing.expectEqual(@as(f32, 40), single.width);
    try std.testing.expectEqual(@as(f32, 7), single.height);

    // The same node measured as flowing text is a different request even at
    // a width that fits the recorded ink: the single-line extent must not
    // answer it.
    var flowed = single_line;
    flowed.available_space.width = .{ .definite = 100 };
    const flow = try layout_context.measureTextCached(
        7,
        "abcd",
        flowed,
        .visible,
        null,
    );
    try std.testing.expectEqual(@as(f32, 40), flow.width);
    try std.testing.expectEqual(@as(f32, 13), flow.height);

    // The single-line request still answers from its own entry.
    const single_again = try layout_context.measureTextCached(
        7,
        "abcd",
        single_line,
        .ellipsis,
        null,
    );
    try std.testing.expectEqual(@as(f32, 7), single_again.height);
}

fn wrappingMeasure(
    _: ?*anyopaque,
    _: []const u8,
    input: context.MeasureInput,
) context.LayoutError!context.TextMeasurement {
    return switch (input.available_space.width) {
        .definite => |width| if (width < 50)
            .{ .width = 20, .height = 20 }
        else
            .{ .width = 50, .height = 10 },
        .max_content => .{ .width = 50, .height = 10 },
        .min_content => .{ .width = 20, .height = 20 },
    };
}

const wrapping_measure_source: context.MeasureSource = .{ .callback = wrappingMeasure };

test "text measurement does not reuse wrapped content at a wider width" {
    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = wrapping_measure_source,
        .measure_node = testMeasureNode,
        .layout_node = testLayoutNode,
    };
    defer layout_context.deinit();

    var input: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{
            .width = .{ .definite = 30 },
            .height = .max_content,
        },
    };
    const narrow = try layout_context.measureTextCached(5, "ab cd", input, .visible, null);
    try std.testing.expectEqual(@as(f32, 20), narrow.width);
    try std.testing.expectEqual(@as(f32, 20), narrow.height);
    input.available_space.width = .{ .definite = 60 };
    const wrapped = try layout_context.measureTextCached(5, "ab cd", input, .visible, null);
    try std.testing.expectEqual(@as(f32, 50), wrapped.width);
    try std.testing.expectEqual(@as(f32, 10), wrapped.height);
    input.available_space.width = .max_content;
    const flowed = try layout_context.measureTextCached(5, "ab cd", input, .visible, null);
    try std.testing.expectEqual(@as(f32, 50), flowed.width);
    try std.testing.expectEqual(@as(f32, 10), flowed.height);
}

test "TextMeasurementCache keeps exact dimensions and available-space tags distinct" {
    var cache: context.TextMeasurementCache = .{};
    defer cache.deinit(std.testing.allocator);

    const base: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{
            .width = .{ .definite = 10 },
            .height = .{ .definite = 20 },
        },
    };
    const inputs = [_]context.MeasureInput{
        base,
        .{
            .known_dimensions = .{ .width = 0, .height = null },
            .available_space = base.available_space,
        },
        .{
            .known_dimensions = .{ .width = null, .height = 0 },
            .available_space = base.available_space,
        },
        .{
            .known_dimensions = base.known_dimensions,
            .available_space = .{
                .width = .{ .definite = 11 },
                .height = .{ .definite = 20 },
            },
        },
        .{
            .known_dimensions = base.known_dimensions,
            .available_space = .{
                .width = .min_content,
                .height = .{ .definite = 20 },
            },
        },
        .{
            .known_dimensions = base.known_dimensions,
            .available_space = .{
                .width = .{ .definite = 10 },
                .height = .max_content,
            },
        },
    };

    for (inputs, 0..) |input, index| {
        cache.clearRetainingCapacity();
        const expected: context.TextMeasurement = .{
            .width = @floatFromInt(index + 1),
            .height = @floatFromInt(index + 11),
        };
        try cache.insert(
            std.testing.allocator,
            context.TextMeasurementCache.key(4, input),
            expected,
        );
        try std.testing.expectEqual(
            @as(?context.TextMeasurement, expected),
            cache.lookup(context.TextMeasurementCache.key(4, input)),
        );
        for (inputs, 0..) |other_input, other_index| {
            if (other_index == index) continue;
            try std.testing.expectEqual(
                @as(?context.TextMeasurement, null),
                cache.lookup(context.TextMeasurementCache.key(4, other_input)),
            );
        }
    }
}

fn testMeasureNode(
    _: *context.LayoutContext,
    _: *widget.WidgetTree,
    _: *const widget.WidgetNode,
    _: context.Request,
) context.LayoutError!context.Measured {
    return .{
        .content = .{ .width = 0, .height = 0 },
        .border = .{ .width = 0, .height = 0 },
    };
}

fn testLayoutNode(
    _: *context.LayoutContext,
    _: *widget.WidgetTree,
    _: *widget.WidgetNode,
    _: context.LayoutRequest,
) context.LayoutError!void {}

test "nested block scratch uses one tree-sized allocation" {
    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = null,
        .measure_node = testMeasureNode,
        .layout_node = testLayoutNode,
    };
    defer layout_context.deinit();

    const outer = try layout_context.acquireBlockScratch(u64, 8);
    outer[0] = 11;
    try layout_context.setBlockScratchCount(u64, 1);
    try std.testing.expectError(
        error.InvalidStyle,
        layout_context.acquireBlockScratch(u32, 16),
    );
    const inner = try layout_context.acquireBlockScratch(u64, 8);
    try std.testing.expectEqual(@as(usize, 7), inner.len);
    inner[0] = 22;
    try layout_context.setBlockScratchCount(u64, 1);
    layout_context.releaseBlockScratch();
    try std.testing.expectEqual(@as(u64, 11), outer[0]);
    layout_context.releaseBlockScratch();

    try std.testing.expectEqual(
        @divExact(@sizeOf(u64) * 8, @sizeOf(u128)),
        layout_context.block_scratch_words.?.len,
    );
}

const HeightSensitiveTextMeasureProbe = struct {
    fn measure(
        _: ?*anyopaque,
        content: []const u8,
        input: context.MeasureInput,
    ) context.LayoutError!context.TextMeasurement {
        const height = switch (input.available_space.height) {
            .definite => |value| value,
            .min_content => 1,
            .max_content => 2,
        };
        return .{ .width = @floatFromInt(content.len * 10), .height = height };
    }

    const source: context.MeasureSource = .{ .callback = measure };
};

test "text measurement reflects available height for each width" {
    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = HeightSensitiveTextMeasureProbe.source,
        .measure_node = testMeasureNode,
        .layout_node = testLayoutNode,
    };
    defer layout_context.deinit();

    const input: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{
            .width = .{ .definite = 100 },
            .height = .max_content,
        },
    };
    const first = try layout_context.measureTextCached(5, "abcd", input, .visible, null);
    try std.testing.expectEqual(@as(f32, 2), first.height);

    var wider = input;
    wider.available_space.width = .{ .definite = 200 };
    const second = try layout_context.measureTextCached(5, "abcd", wider, .visible, null);
    try std.testing.expectEqual(@as(f32, 2), second.height);

    var different_height = input;
    different_height.available_space.height = .{ .definite = 40 };
    const third = try layout_context.measureTextCached(
        5,
        "abcd",
        different_height,
        .visible,
        null,
    );
    try std.testing.expectEqual(@as(f32, 40), third.height);

    different_height.available_space.width = .{ .definite = 200 };
    const fourth = try layout_context.measureTextCached(
        5,
        "abcd",
        different_height,
        .visible,
        null,
    );
    try std.testing.expectEqual(@as(f32, 40), fourth.height);
}
