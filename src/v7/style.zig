//! Typed, fieldwise-resolved layout and paint values.
const std = @import("std");

pub const Color = [4]f32;
pub const TextureId = u32;
pub const Layer = u32;

/// The first layout slice supports the existing flex path only.
pub const Display = enum { flex };

pub const FlexDirection = enum { column, row };
pub const Justify = enum { start, center, end, space_between };
pub const Align = enum { stretch, start, center, end };
pub const BoxSizing = enum { content_box, border_box };

/// Per-side box extents in top, right, bottom, left order.
pub const Sides = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

/// Distinguishes an unspecified override from an explicit nullable value.
pub const OptionalFloatOverride = union(enum) {
    unspecified,
    value: ?f32,
};

/// Distinguishes an unspecified override from an explicit texture removal.
pub const TextureOverride = union(enum) {
    unspecified,
    value: ?TextureId,
};

/// Resolved layout data. Every field has a concrete value after resolution.
pub const Style = struct {
    display: Display = .flex,
    direction: FlexDirection = .column,
    justify: Justify = .start,
    @"align": Align = .stretch,
    gap: f32 = 0,

    grow: f32 = 0,
    shrink: f32 = 1,
    basis: f32 = 0,
    min_main: ?f32 = null,

    margin: Sides = .{},
    border: Sides = .{},
    padding: Sides = .{},
    box_sizing: BoxSizing = .content_box,

    pub fn resolve(defaults: Style, local: StyleOverride) Style {
        var result = defaults;
        if (local.display) |value| result.display = value;
        if (local.direction) |value| result.direction = value;
        if (local.flex_direction) |value| result.direction = value;
        if (local.justify) |value| result.justify = value;
        if (local.@"align") |value| result.@"align" = value;
        if (local.gap) |value| result.gap = value;
        if (local.grow) |value| result.grow = value;
        if (local.shrink) |value| result.shrink = value;
        if (local.basis) |value| result.basis = value;
        switch (local.min_main) {
            .unspecified => {},
            .value => |value| result.min_main = value,
        }
        if (local.margin) |value| result.margin = value;
        if (local.border) |value| result.border = value;
        if (local.padding) |value| result.padding = value;
        if (local.box_sizing) |value| result.box_sizing = value;
        return result;
    }
};

/// Local layout overrides. Null fields do not replace component defaults.
pub const StyleOverride = struct {
    display: ?Display = null,
    direction: ?FlexDirection = null,
    /// Compatibility spelling accepted by option translators.
    flex_direction: ?FlexDirection = null,
    justify: ?Justify = null,
    @"align": ?Align = null,
    gap: ?f32 = null,

    grow: ?f32 = null,
    shrink: ?f32 = null,
    basis: ?f32 = null,
    min_main: OptionalFloatOverride = .unspecified,

    margin: ?Sides = null,
    border: ?Sides = null,
    padding: ?Sides = null,
    box_sizing: ?BoxSizing = null,
};

/// Resolved paint data. Paint values never participate in layout resolution.
pub const PaintStyle = struct {
    fill: Color = .{ 0, 0, 0, 0 },
    border_color: Color = .{ 0, 0, 0, 1 },
    radius: Sides = .{},
    shadow: f32 = 0,
    gradient: Color = .{ 0, 0, 0, 0 },
    transparent: bool = false,
    clip: bool = false,
    texture: ?TextureId = null,
    layer: Layer = 0,

    pub fn resolve(defaults: PaintStyle, local: PaintStyleOverride) PaintStyle {
        var result = defaults;
        if (local.fill) |value| result.fill = value;
        if (local.border_color) |value| result.border_color = value;
        if (local.radius) |value| result.radius = value;
        if (local.shadow) |value| result.shadow = value;
        if (local.gradient) |value| result.gradient = value;
        if (local.transparent) |value| result.transparent = value;
        if (local.clip) |value| result.clip = value;
        switch (local.texture) {
            .unspecified => {},
            .value => |value| result.texture = value,
        }
        if (local.layer) |value| result.layer = value;
        return result;
    }
};

/// Local paint overrides. Null fields do not replace component defaults.
pub const PaintStyleOverride = struct {
    fill: ?Color = null,
    border_color: ?Color = null,
    radius: ?Sides = null,
    shadow: ?f32 = null,
    gradient: ?Color = null,
    transparent: ?bool = null,
    clip: ?bool = null,
    texture: TextureOverride = .unspecified,
    layer: ?Layer = null,
};

test "Style resolution retains component defaults" {
    const defaults: Style = .{
        .direction = .row,
        .gap = 12,
        .grow = 3,
        .padding = .{ .left = 8, .right = 8 },
    };
    const resolved = Style.resolve(defaults, .{ .justify = .center });

    try std.testing.expectEqual(FlexDirection.row, resolved.direction);
    try std.testing.expectEqual(@as(f32, 12), resolved.gap);
    try std.testing.expectEqual(@as(f32, 3), resolved.grow);
    try std.testing.expectEqual(Sides{ .left = 8, .right = 8 }, resolved.padding);
    try std.testing.expectEqual(Justify.center, resolved.justify);
}

test "Style and PaintStyle apply explicit overrides fieldwise" {
    const layout = Style.resolve(.{
        .shrink = 0.5,
        .min_main = 24,
        .box_sizing = .content_box,
    }, .{
        .shrink = 0,
        .min_main = .{ .value = null },
        .box_sizing = .border_box,
    });
    const paint = PaintStyle.resolve(.{
        .fill = .{ 1, 0, 0, 1 },
        .texture = 9,
        .layer = 2,
    }, .{
        .fill = .{ 0, 1, 0, 1 },
        .texture = .{ .value = null },
    });

    try std.testing.expectEqual(@as(f32, 0), layout.shrink);
    try std.testing.expectEqual(@as(?f32, null), layout.min_main);
    try std.testing.expectEqual(BoxSizing.border_box, layout.box_sizing);
    try std.testing.expectEqual(Color{ 0, 1, 0, 1 }, paint.fill);
    try std.testing.expectEqual(@as(?TextureId, null), paint.texture);
    try std.testing.expectEqual(@as(Layer, 2), paint.layer);
}

test "layout values do not inherit from a parent style" {
    const parent = Style.resolve(.{}, .{
        .direction = .row,
        .gap = 20,
        .grow = 4,
        .margin = .{ .left = 7 },
    });
    const child = Style.resolve(.{}, .{ .padding = .{ .top = 3 } });

    try std.testing.expectEqual(FlexDirection.row, parent.direction);
    try std.testing.expectEqual(FlexDirection.column, child.direction);
    try std.testing.expectEqual(@as(f32, 0), child.gap);
    try std.testing.expectEqual(@as(f32, 0), child.grow);
    try std.testing.expectEqual(Sides{}, child.margin);
    try std.testing.expectEqual(Sides{ .top = 3 }, child.padding);
}
