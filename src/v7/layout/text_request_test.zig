//! Behavior regressions for the canonical typography seam.
//!
//! Every test here fails against a pipeline that resolved inheritance at draw
//! time, mutated a shared resolved record, or re-shaped text to answer a
//! baseline question.

const std = @import("std");

const FrameNodeId = @import("../id.zig").FrameNodeId;
const text = @import("../text.zig");
const widget = @import("../widget.zig");
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");
const DrawCtx = @import("../drawctx.zig").DrawCtx;

const WidgetTree = widget.WidgetTree;

/// One leaf per reported request, so a test can see exactly what the provider
/// was asked for without depending on a real font stack.
const RecordingProvider = struct {
    calls: usize = 0,
    /// Every `text` pointer the provider saw, in order.
    requests: [64]?*const text.NodeText = @splat(null),
    sizes: [64]f32 = @splat(0),

    fn source(self: *RecordingProvider) context.MeasureSource {
        return .{ .context = @ptrCast(self), .callback = callback };
    }

    fn callback(
        context_ptr: ?*anyopaque,
        content: []const u8,
        input: context.MeasureInput,
    ) context.LayoutError!context.TextMeasurement {
        const self: *RecordingProvider = @ptrCast(@alignCast(context_ptr.?));
        if (self.calls < self.requests.len) {
            self.requests[self.calls] = input.text;
            // A size the caller can key on: 10px per byte at the requested
            // size, so a node with a different authored size is visible.
            const size = if (input.text) |request| request.fontSize() else 0;
            self.sizes[self.calls] = if (size > 0) size else 16;
        }
        self.calls += 1;
        const scale = if (input.text) |request|
            (if (request.fontSize() > 0) request.fontSize() else 16) / 16
        else
            1;
        return .{
            .width = @as(f32, @floatFromInt(content.len)) * 10 * scale,
            .height = 20 * scale,
            .first_baseline = 14 * scale,
        };
    }
};

/// A provider that refuses, the way a real one does for an uninstalled face.
fn refusingProvider(
    _: ?*anyopaque,
    _: []const u8,
    _: context.MeasureInput,
) context.LayoutError!context.TextMeasurement {
    return error.FontUnavailable;
}

/// A tree assembled by hand, exactly the shape a fixture or a test builds: no
/// `DrawCtx`, nodes appended in post-order, text inputs set directly.
fn directTree(
    tree: *WidgetTree,
    parent: *const text.TextInput,
    child: ?*const text.TextInput,
) !struct { parent: FrameNodeId, child: FrameNodeId } {
    const parent_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const child_id: FrameNodeId = @fromBackingInt(@intCast(2));
    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = parent_id,
        .style = .{ .display = .flex },
        .text_input = child,
    });
    try tree.appendNode(.{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .display = .flex },
        .text_input = parent,
    });
    try tree.appendChild(parent_id, child_id);
    return .{ .parent = parent_id, .child = child_id };
}

fn layoutOnce(allocator: std.mem.Allocator, tree: *WidgetTree, measure: ?context.MeasureSource) !void {
    try dispatch.layoutTree(tree, .{
        .allocator = allocator,
        .available = .{ .width = 200, .height = 100 },
        .measure = measure,
    });
}

// A directly assembled tree inherits its parent's authored text exactly like a
// `DrawCtx` tree. Before the cutover a hand-built node had no font selector at
// all, so a parent's `.font_size` reached its children only through the draw
// cursor — a direct tree silently painted at the host default.
test "a directly assembled tree inherits its parent's authored text request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var provider: RecordingProvider = .{};
    const ids = try directTree(
        &tree,
        &.{ .style = .{ .font_fields = .{ .size = 32 } } },
        null,
    );

    try layoutOnce(arena.allocator(), &tree, provider.source());

    const child = tree.node(ids.child).?;
    const request = child.text_request orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 32), request.fontSize());
    // The parent's own record is the base, not a copy the child may write to.
    try std.testing.expectEqual(
        tree.node(ids.parent).?.text_request.?.fontSize(),
        request.fontSize(),
    );
    try std.testing.expect(provider.calls > 0);
}

// Inheritance follows the CURRENT parent. Re-parenting a node under a node with
// a different authored size must republish its resolved record, while a second
// layout over an unchanged tree keeps the same record address.
test "re-parenting republishes the resolved record and a repeat layout does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = WidgetTree.init(allocator);
    defer tree.deinit();

    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const child_id: FrameNodeId = @fromBackingInt(@intCast(3));
    try tree.appendNode(.{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = first_id,
        .style = .{ .display = .flex },
    });
    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .display = .flex },
        .text_input = &.{ .style = .{ .font_fields = .{ .size = 10 } } },
    });
    try tree.appendNode(.{
        .id = second_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .display = .flex },
        .text_input = &.{ .style = .{ .font_fields = .{ .size = 40 } } },
    });
    try tree.appendChild(first_id, child_id);
    // `second_id` is a second root; both roots are laid out.

    try layoutOnce(allocator, &tree, null);
    const under_first = tree.node(child_id).?.text_request.?;
    try std.testing.expectEqual(@as(f32, 10), under_first.fontSize());

    // A repeated layout over the same tree publishes nothing new.
    try layoutOnce(allocator, &tree, null);
    try std.testing.expect(under_first == tree.node(child_id).?.text_request.?);

    // Re-parenting under the other root resolves against the new base.
    tree.node(child_id).?.parent = second_id;
    tree.node(first_id).?.children.clearRetainingCapacity();
    try tree.appendChild(second_id, child_id);
    try layoutOnce(allocator, &tree, null);
    const under_second = tree.node(child_id).?.text_request.?;
    try std.testing.expectEqual(@as(f32, 40), under_second.fontSize());
    try std.testing.expect(under_first != under_second);
}

// The authored input survives every resolution. `text_input` is never rewritten,
// so different authored sizes must keep producing different measured geometry.
test "authored per-node text input is never rewritten by resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();

    const shared: text.TextInput = .{ .style = .{ .font_fields = .{ .size = 12 } } };
    const other: text.TextInput = .{ .style = .{ .font_fields = .{ .size = 18 } } };
    const first_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const second_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const parent_id: FrameNodeId = @fromBackingInt(@intCast(3));
    try tree.appendNode(.{
        .id = first_id,
        .kind = .{ .label = .{ .text = "one" } },
        .parent = parent_id,
        .style = .{ .display = .flex },
        .text_input = &shared,
    });
    try tree.appendNode(.{
        .id = second_id,
        .kind = .{ .label = .{ .text = "two" } },
        .parent = parent_id,
        .style = .{ .display = .flex },
        .text_input = &other,
    });
    try tree.appendNode(.{
        .id = parent_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .style = .{ .display = .flex },
    });
    try tree.appendChild(parent_id, first_id);
    try tree.appendChild(parent_id, second_id);

    try layoutOnce(arena.allocator(), &tree, null);

    const first = tree.node(first_id).?;
    const second = tree.node(second_id).?;
    try std.testing.expectEqual(@as(f32, 12), first.text_request.?.fontSize());
    try std.testing.expectEqual(@as(f32, 18), second.text_request.?.fontSize());
}

// A real provider's refusal propagates out of layout as a `LayoutError`, before
// the tree is published. The failure must preserve existing geometry.
test "a failed text measurement refuses layout and leaves the tree unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var provider: RecordingProvider = .{};
    const label_id: FrameNodeId = @fromBackingInt(@intCast(1));
    try tree.appendNode(.{
        .id = label_id,
        .kind = .{ .label = .{ .text = "measured" } },
        .parent = .root,
        .style = .{ .display = .flow_root, .box_sizing = .border_box },
    });

    try layoutOnce(arena.allocator(), &tree, provider.source());
    const good = tree.node(label_id).?.rect;
    try std.testing.expect(good.w > 0);

    try std.testing.expectError(
        error.FontUnavailable,
        layoutOnce(arena.allocator(), &tree, .{
            .callback = refusingProvider,
        }),
    );

    // The committed geometry is exactly what the successful pass produced; the
    // failed pass published nothing.
    try std.testing.expectEqual(good, tree.node(label_id).?.rect);
}

// A baseline is answered from the cached measurement, under the SAME
// constraints that produced it. A different constraint must not reuse it.
test "a baseline is reused only under the constraints that produced it" {
    var layout_context: context.LayoutContext = .{
        .allocator = std.testing.allocator,
        .measure = .{
            .callback = struct {
                fn callback(
                    _: ?*anyopaque,
                    content: []const u8,
                    input: context.MeasureInput,
                ) context.LayoutError!context.TextMeasurement {
                    return .{
                        .width = @floatFromInt(content.len * 10),
                        // A wrapped line's baseline is lower; the constraints are
                        // what tell the two apart.
                        .height = 20,
                        .first_baseline = if (input.available_space.width == .max_content)
                            14
                        else
                            32,
                    };
                }
            }.callback,
        },
        .measure_node = unreachableMeasureNode,
        .layout_node = unreachableLayoutNode,
    };
    defer layout_context.deinit();

    const unconstrained: context.MeasureInput = .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
    };
    const first = try layout_context.measureTextCached(3, "abc", unconstrained, .visible, null);
    try std.testing.expectEqual(@as(?f32, 14), first.first_baseline);

    // The same constraints answer from the cache without a second call.
    const again = try layout_context.measureTextCached(3, "abc", unconstrained, .visible, null);
    try std.testing.expectEqual(first.first_baseline, again.first_baseline);

    // A constrained request wraps, so its baseline is the wrapped one.
    var constrained = unconstrained;
    constrained.available_space.width = .{ .definite = 10 };
    const wrapped = try layout_context.measureTextCached(3, "abc", constrained, .visible, null);
    try std.testing.expectEqual(@as(?f32, 32), wrapped.first_baseline);

    // A different node never shares another node's entry.
    const other_node = try layout_context.measureTextCached(4, "abc", unconstrained, .visible, null);
    try std.testing.expectEqual(@as(?f32, 14), other_node.first_baseline);
}

fn unreachableMeasureNode(
    _: *context.LayoutContext,
    _: *WidgetTree,
    _: *const widget.WidgetNode,
    _: context.Request,
) context.LayoutError!context.Measured {
    unreachable;
}

fn unreachableLayoutNode(
    _: *context.LayoutContext,
    _: *WidgetTree,
    _: *widget.WidgetNode,
    _: context.LayoutRequest,
) context.LayoutError!void {
    unreachable;
}

test "authored text input owns nested slices and keeps explicit foreground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    var family = "Primary".*;
    var range_family = "Fallback".*;
    var features = [_]text.Feature{.{ .tag = text.tag("liga"), .value = 1 }};
    var fallback = [_]text.FontHandle{.{ .index = 2, .generation = 1 }};
    var suffix = "...".*;
    const ranges = [_]text.StyledRange{.{
        .range = .{ .start = 0, .end = 3 },
        .override = .{ .font_fields = .{
            .family = &range_family,
            .features = &features,
            .fallback = &fallback,
        } },
    }};
    const id = try ctx.label(.{
        .text = "abc",
        .text_style = @as(text.TextStyleOverride, .{
            .font = .{ .family = &family, .features = &features, .fallback = &fallback },
            .foreground = .{ 0.2, 0.3, 0.4, 1 },
        }),
        .text_ranges = &ranges,
        .paragraph = @as(text.ParagraphOverride, .{
            .truncate = .{ .suffix = &suffix },
        }),
    });
    family[0] = 'X';
    range_family[0] = 'X';
    features[0].value = 0;
    fallback[0].index = 9;
    suffix[0] = '?';

    try layoutOnce(arena.allocator(), &tree, null);
    const request = tree.node(id).?.text_request.?;
    try std.testing.expectEqualStrings("Primary", request.style.font.family);
    try std.testing.expectEqual(@as(u32, 1), request.style.font.features[0].value);
    try std.testing.expectEqual(@as(u32, 2), request.style.font.fallback[0].index);
    try std.testing.expectEqualSlices(f32, &.{ 0.2, 0.3, 0.4, 1 }, &request.style.foreground);
    const extra = request.extra.?;
    const run = extra.ranges[0].override.font_fields;
    try std.testing.expectEqualStrings("Fallback", run.family.?);
    try std.testing.expectEqual(@as(u32, 1), run.features.?[0].value);
    try std.testing.expectEqual(@as(u32, 2), run.fallback.?[0].index);
    try std.testing.expectEqualStrings("...", extra.paragraph.truncate.?.suffix);
}

// A widget kind's own color is a DEFAULT, not authorship. It must reach a node
// that inherits nothing and authors nothing, and it must stay out of the way of
// a container that authored a foreground, of an option color, and of
// `text_style.foreground`. The unstyled case keeps its historical resolution:
// the kind color, and size zero meaning the host's own default.
test "a container foreground outranks the kind default of a bare label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const container_foreground = [4]f32{ 0.1, 0.2, 0.3, 1 };
    const own_foreground = [4]f32{ 0.4, 0.5, 0.6, 1 };
    const kind_foreground: [4]f32 = .{ 1, 1, 1, 1 };

    _ = try ctx.column(.{ .text_style = .{ .foreground = container_foreground } });
    const inherited = try ctx.label(.{ .text = "inherited" });
    const option_color = try ctx.label(.{ .text = "option", .color = own_foreground });
    const typed_color = try ctx.label(.{
        .text = "typed",
        .color = container_foreground,
        .text_style = .{ .foreground = own_foreground },
    });
    ctx.pop();
    const bare = try ctx.label(.{ .text = "bare" });

    try layoutOnce(arena.allocator(), &tree, null);

    const inherited_request = tree.node(inherited).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(
        f32,
        &container_foreground,
        &inherited_request.style.foreground,
    );
    try std.testing.expectEqual(@as(f32, 0), inherited_request.fontSize());
    try std.testing.expectEqualSlices(
        f32,
        &own_foreground,
        &tree.node(option_color).?.text_request.?.style.foreground,
    );
    // `text_style` is layered over the option color, not under it.
    try std.testing.expectEqualSlices(
        f32,
        &own_foreground,
        &tree.node(typed_color).?.text_request.?.style.foreground,
    );

    const bare_request = tree.node(bare).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &kind_foreground, &bare_request.style.foreground);
    try std.testing.expectEqual(@as(f32, 0), bare_request.fontSize());
}

// Component defaults sit below the inherited container style and below the
// widget's own options. A default that filled an undecided field is still a
// default: a node nested inside a component that declares none keeps the value
// the tree already decided.
test "a component text default fills only what the container left undecided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const container_foreground = [4]f32{ 0.1, 0.2, 0.3, 1 };
    const own_foreground = [4]f32{ 0.4, 0.5, 0.6, 1 };
    const default_foreground = [4]f32{ 0.7, 0.8, 0.9, 1 };
    const default_size: f32 = 20;
    const declared: text.TextStyleOverride = .{
        .foreground = default_foreground,
        .font_fields = .{ .size = default_size },
    };

    _ = try ctx.column(.{ .text_style = .{ .foreground = container_foreground } });
    ctx.component_defaults = .{ .text = declared };
    const inherited = try ctx.label(.{ .text = "inherited" });
    const own = try ctx.label(.{ .text = "own", .color = own_foreground });
    ctx.component_defaults = .{};
    ctx.pop();

    // Outside a container the same default still reaches a node that authors
    // nothing: a weak layer, not an absent one.
    _ = try ctx.column(.{});
    ctx.component_defaults = .{ .text = declared };
    const scoped = try ctx.label(.{ .text = "scoped" });
    ctx.component_defaults = .{};
    ctx.pop();

    try layoutOnce(arena.allocator(), &tree, null);

    const inherited_request = tree.node(inherited).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(
        f32,
        &container_foreground,
        &inherited_request.style.foreground,
    );
    // The container decided only its foreground, so the declared size still
    // fills the field nothing above authored.
    try std.testing.expectEqual(default_size, inherited_request.fontSize());
    try std.testing.expectEqualSlices(
        f32,
        &own_foreground,
        &tree.node(own).?.text_request.?.style.foreground,
    );

    const scoped_request = tree.node(scoped).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &default_foreground, &scoped_request.style.foreground);
    try std.testing.expectEqual(default_size, scoped_request.fontSize());
}

// The ordinary consumer spells nested typed text options as anonymous
// literals. They must name the same policy as the exact records, including the
// truncation suffix that the input then owns.
test "anonymous nested text options convert to the typed records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const id = try ctx.label(.{
        .text = "abc",
        .text_style = .{
            .font = .{ .family = "Inter", .size = 18 },
            .foreground = .{ 0.2, 0.3, 0.4, 1 },
        },
        .paragraph = .{ .wrap = .no_wrap, .truncate = .{ .suffix = ".." } },
        .missing_glyph = .error_if_missing,
    });

    try layoutOnce(arena.allocator(), &tree, null);

    const request = tree.node(id).?.text_request orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Inter", request.style.font.family);
    try std.testing.expectEqual(@as(f32, 18), request.fontSize());
    try std.testing.expectEqualSlices(f32, &.{ 0.2, 0.3, 0.4, 1 }, &request.style.foreground);
    const extra = request.extra orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?text.Wrap, .no_wrap), extra.paragraph.wrap);
    try std.testing.expectEqualStrings("..", extra.paragraph.truncate.?.suffix);
    try std.testing.expectEqual(text.MissingGlyph.error_if_missing, extra.missing_glyph);
    // A field the literal left out stays NULL. An unauthored width must never
    // become a number here, because the request builder layers the box's own
    // width over a null one and would silently keep a poisoned value.
    try std.testing.expectEqual(@as(?f32, null), extra.paragraph.wrap_width);
}

// A component default font is a whole `FontRequest`, so it names every font
// field at once. The default layer is still weaker than the chain: it fills the
// family and the size nobody authored and leaves the weight an ancestor did.
// The scope opens after the ancestor exists, so the ancestor itself never
// carries the default and an inherited family cannot stand in for the case.
test "a component default font fills the font fields no ancestor authored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const ancestor = try ctx.column(.{ .font_weight = 700 });
    const declared: text.TextStyleOverride = .{ .font = .{ .family = "Inter", .size = 18 } };
    ctx.component_defaults = .{ .text = declared };
    const defaulted = try ctx.label(.{ .text = "child" });
    ctx.component_defaults = .{};
    const inherited = try ctx.label(.{ .text = "child" });
    ctx.pop();

    try layoutOnce(arena.allocator(), &tree, null);

    // The ancestor decided the weight and nothing else. The default never
    // reached it, which is what keeps this a test of the default layer.
    const ancestor_request = tree.node(ancestor).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 700), ancestor_request.style.font.weight);
    try std.testing.expectEqualStrings("", ancestor_request.style.font.family);
    try std.testing.expectEqual(@as(f32, 0), ancestor_request.fontSize());

    // Family and size were undecided, so the default filled them. Its own
    // weight of 400 never reaches the node: that field the chain authored.
    const defaulted_request = tree.node(defaulted).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Inter", defaulted_request.style.font.family);
    try std.testing.expectEqual(@as(f32, 18), defaulted_request.fontSize());
    try std.testing.expectEqual(@as(u16, 700), defaulted_request.style.font.weight);

    // The same inheritance with no default in scope: weight alone.
    const inherited_request = tree.node(inherited).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 700), inherited_request.style.font.weight);
    try std.testing.expectEqualStrings("", inherited_request.style.font.family);
    try std.testing.expectEqual(@as(f32, 0), inherited_request.fontSize());
}

// A default loses to anything the chain authored, the face included. A
// defaulted family fills the family field the chain left empty; it must not
// clear the handle an ancestor selected, or the resolved request stops naming
// the face the chain decided on. The face is a plain handle here, so the
// identity is observed without a font service or an installed face.
test "a component default family never displaces an authored font handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const face: text.FontHandle = .{ .index = 4, .generation = 1 };
    const ancestor = try ctx.column(.{ .text_style = .{ .font_fields = .{ .handle = face } } });
    const declared: text.TextStyleOverride = .{ .font_fields = .{ .family = "Inter" } };
    ctx.component_defaults = .{ .text = declared };
    const defaulted = try ctx.label(.{ .text = "child" });
    ctx.component_defaults = .{};
    ctx.pop();

    try layoutOnce(arena.allocator(), &tree, null);

    const ancestor_request = tree.node(ancestor).?.text_request orelse
        return error.TestUnexpectedResult;
    const inherited = ancestor_request.style.font.handle orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 4), inherited.index);
    try std.testing.expectEqual(@as(u32, 1), inherited.generation);

    const request = tree.node(defaulted).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Inter", request.style.font.family);
    const resolved = request.style.font.handle orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 4), resolved.index);
    try std.testing.expectEqual(@as(u32, 1), resolved.generation);
}

// Selecting a family without naming a face clears the inherited one, and that
// clear is authorship: the family a node selected is the only thing that
// decides its face. A chain here really does hold a face, so a component
// default that supplies one must not resurrect the handle the family dropped.
test "a component default handle never revives the face an authored family cleared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    const face: text.FontHandle = .{ .index = 4, .generation = 1 };
    const default_face: text.FontHandle = .{ .index = 7, .generation = 2 };
    ctx.component_defaults = .{ .text = .{ .font_fields = .{ .handle = face } } };
    const outer = try ctx.column(.{});
    ctx.component_defaults = .{};
    const middle = try ctx.column(.{ .font_family = "Georgia" });
    const declared: text.TextStyleOverride = .{ .font_fields = .{ .handle = default_face } };
    ctx.component_defaults = .{ .text = declared };
    const defaulted = try ctx.label(.{ .text = "child" });
    ctx.component_defaults = .{};
    ctx.pop();
    ctx.pop();

    try layoutOnce(arena.allocator(), &tree, null);

    // The chain really holds a face, so a null handle below is a decision.
    const outer_request = tree.node(outer).?.text_request orelse
        return error.TestUnexpectedResult;
    const chain_face = outer_request.style.font.handle orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 4), chain_face.index);
    try std.testing.expectEqual(@as(u32, 1), chain_face.generation);

    // Naming a family alone drops the inherited face.
    const middle_request = tree.node(middle).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Georgia", middle_request.style.font.family);
    try std.testing.expectEqual(@as(?text.FontHandle, null), middle_request.style.font.handle);

    // The default handle fills nothing the family already decided.
    const request = tree.node(defaulted).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Georgia", request.style.font.family);
    try std.testing.expectEqual(@as(?text.FontHandle, null), request.style.font.handle);
}

/// The provider the real seam is: it rebuilds the request through the ONE
/// builder the paint path uses, so a test observes the exact `Paragraph` a real
/// `TextService.layout` would validate.
const RequestObserver = struct {
    seen: [8]text.LayoutRequest,
    calls: usize = 0,

    /// The log starts empty; the callback fills a slot before it counts it.
    fn init() RequestObserver {
        return .{
            // SAFETY: only `seen[0..calls]` is ever read, so an unfilled slot
            // is never observed.
            .seen = undefined,
        };
    }

    fn source(self: *RequestObserver) context.MeasureSource {
        return .{ .context = @ptrCast(self), .callback = callback };
    }

    fn callback(
        context_ptr: ?*anyopaque,
        content: []const u8,
        input: context.MeasureInput,
    ) context.LayoutError!context.TextMeasurement {
        const self: *RequestObserver = @ptrCast(@alignCast(context_ptr.?));
        // A definite width is what the real measurer folds into
        // `NodeRequestOptions.width`; a content probe leaves it null.
        const width: ?f32 = input.known_dimensions.width orelse switch (input.available_space.width) {
            .definite => |number| number,
            .min_content, .max_content => null,
        };
        if (self.calls < self.seen.len) {
            self.seen[self.calls] = text.nodeRequest(
                content,
                input.text orelse &text.default_node_text,
                .{ .width = width },
            );
        }
        self.calls += 1;
        return .{ .width = 120, .height = 24, .first_baseline = 18 };
    }
};

// The ORDINARY caption shape: an authored no-wrap policy with NO wrap width,
// plus a family, a fallback and an inline styled range. The provider receives
// a real box width, so the ONLY correct `wrap_width` is that box width. A width
// the tree never authored must not survive resolution, publication and request
// construction as anything else — in particular not as uninitialized memory.
test "an unauthored wrap width reaches the request as the box width alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tree = WidgetTree.init(allocator);
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = allocator };

    var family = "InterVariable".*;
    var fallback = [_]text.FontHandle{.{ .index = 2, .generation = 1 }};
    var ranges = [_]text.StyledRange{.{
        .range = .{ .start = 0, .end = 5 },
        .override = .{ .font_fields = .{ .weight = 700 }, .underline = true },
    }};
    _ = try ctx.column(.{});
    const id = try ctx.label(.{
        .text = "abc",
        .font_size = 22,
        .font_family = &family,
        .font_fallback = &fallback,
        .text_ranges = &ranges,
        .missing_glyph = .notdef,
        .paragraph = .{ .wrap = .no_wrap },
    });
    ctx.pop();

    var observer: RequestObserver = .init();
    try dispatch.layoutTree(&tree, .{
        .allocator = allocator,
        .available = .{ .width = 640, .height = 400 },
        .measure = observer.source(),
    });

    // The published record says exactly what the consumer authored: no width.
    const published = tree.node(id).?.text_request orelse return error.TestUnexpectedResult;
    const extra = published.extra orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?f32, null), extra.paragraph.wrap_width);
    try std.testing.expectEqual(@as(?text.Wrap, .no_wrap), extra.paragraph.wrap);
    try std.testing.expectEqual(text.MissingGlyph.notdef, extra.missing_glyph);
    try std.testing.expectEqual(@as(f32, 22), published.fontSize());
    try std.testing.expectEqualStrings("InterVariable", published.style.font.family);
    try std.testing.expect(observer.calls > 0);

    // Every request the provider built names a finite, non-negative width. The
    // consumer's own offer is 640 wide, and uninitialized memory fails here.
    for (observer.seen[0..observer.calls]) |request| {
        const width = request.paragraph.wrap_width orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.math.isFinite(width));
        try std.testing.expect(width >= 0);
        try std.testing.expectEqual(@as(?text.Wrap, .no_wrap), request.paragraph.wrap);
    }
}

// The same invariant through the pure core boundary, with no tree at all:
// `resolveNodeText` must leave an unauthored width null, `publishNodeText` must
// copy that null through unchanged, and `nodeRequest` must then take the width
// from the caller's options alone. This is the narrowest statement of the
// invariant, so a regression names the exact stage that broke.
test "an unauthored width stays null through resolution and publication" {
    const authored: text.TextInput = .{
        .extra = .{ .paragraph = .{ .wrap = .no_wrap } },
    };
    const resolved = text.resolveNodeText(null, &authored, null);
    try std.testing.expectEqual(@as(?f32, null), resolved.extra.?.paragraph.wrap_width);

    const record = try text.publishNodeText(std.testing.allocator, resolved);
    defer {
        // Two separate allocations: one `TextExtra`, one `NodeText`.
        std.testing.allocator.destroy(@constCast(record.extra.?));
        std.testing.allocator.destroy(@constCast(record));
    }
    try std.testing.expectEqual(@as(?f32, null), record.extra.?.paragraph.wrap_width);

    const request = text.nodeRequest("abc", record, .{ .width = 640 });
    try std.testing.expectEqual(@as(?f32, 640), request.paragraph.wrap_width);
    try std.testing.expectEqual(@as(?text.Wrap, .no_wrap), request.paragraph.wrap);

    // A content probe leaves the paragraph unconstrained.
    const probed = text.nodeRequest("abc", record, .{});
    try std.testing.expectEqual(@as(?f32, null), probed.paragraph.wrap_width);
    try std.testing.expectEqual(@as(?text.Wrap, .no_wrap), probed.paragraph.wrap);
}

// A published record belongs to the tree that published it. Handed the caller's
// allocator it had no owner at all: a tree laid out on the plain allocator kept
// its current and every superseded `NodeText`/`TextExtra` for the life of the
// process. `std.testing.allocator` is the gate — a record outliving its tree
// fails this test as a leak — and the readable superseded record is what keeps
// the fix from becoming an early free.
test "a tree releases every record it published and keeps the superseded ones readable" {
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    const ids = try directTree(
        &tree,
        &.{ .style = .{ .font_fields = .{ .size = 10 } } },
        null,
    );

    try layoutOnce(std.testing.allocator, &tree, null);
    const first = tree.node(ids.child).?.text_request orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 10), first.fontSize());

    // A second pass over an unchanged tree publishes nothing, so the record a
    // consumer is already holding is the record the node still names.
    try layoutOnce(std.testing.allocator, &tree, null);
    try std.testing.expect(first == tree.node(ids.child).?.text_request.?);
    try std.testing.expectEqual(@as(f32, 10), first.fontSize());

    // A new inherited base republishes the child against the parent's new size.
    const larger: text.TextInput = .{ .style = .{ .font_fields = .{ .size = 40 } } };
    tree.node(ids.parent).?.text_input = &larger;
    try layoutOnce(std.testing.allocator, &tree, null);
    const republished = tree.node(ids.child).?.text_request.?;
    try std.testing.expect(republished != first);
    try std.testing.expectEqual(@as(f32, 40), republished.fontSize());

    // The superseded record still answers: a snapshot taken before this change
    // holds it, so its storage is neither reused nor released while the tree
    // lives. A further pass publishes nothing and disturbs neither record.
    try std.testing.expectEqual(@as(f32, 10), first.fontSize());
    try layoutOnce(std.testing.allocator, &tree, null);
    try std.testing.expect(republished == tree.node(ids.child).?.text_request.?);
    try std.testing.expectEqual(@as(f32, 40), republished.fontSize());
    try std.testing.expectEqual(@as(f32, 10), first.fontSize());
}

// The App path: the tree is allocated inside the frame arena and never deinited,
// because the frame boundary recycles that arena. Its records have to be
// frame-owned too, or they outlive the only lifetime they were ever promised.
test "a frame-arena tree publishes into the frame that releases it" {
    var frame = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frame.deinit();

    var first = try frame.allocator().create(WidgetTree);
    first.* = WidgetTree.init(frame.allocator());
    const ids = try directTree(
        first,
        &.{ .style = .{ .font_fields = .{ .size = 12 } } },
        null,
    );
    try layoutOnce(frame.allocator(), first, null);
    const published = first.node(ids.child).?.text_request orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 12), published.fontSize());

    // Frame boundary: the arena is recycled and the tree retires with it. No
    // teardown step may be required, and none may be owed.
    try std.testing.expect(frame.reset(.retain_capacity));

    // The next frame builds a fresh tree in the recycled arena and publishes
    // records of its own; nothing of the retired frame is still owed a free.
    var second = try frame.allocator().create(WidgetTree);
    second.* = WidgetTree.init(frame.allocator());
    const next_ids = try directTree(
        second,
        &.{ .style = .{ .font_fields = .{ .size = 28 } } },
        null,
    );
    try layoutOnce(frame.allocator(), second, null);
    const next_published = second.node(next_ids.child).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 28), next_published.fontSize());
}
