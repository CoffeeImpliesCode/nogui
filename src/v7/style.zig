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
/// A CSS-like dimension. Percentages are fractions in the range 0..1.
/// `auto` and an unresolved percentage return null during resolution.
pub const Dimension = union(enum) {
    auto,
    length: f32,
    percent: f32,
    min_content,
    max_content,

    pub fn resolve(self: Dimension, containing: ?f32, intrinsic: f32) ?f32 {
        return switch (self) {
            .auto => null,
            .length => |value| value,
            .percent => |fraction| if (containing) |size| size * fraction else null,
            .min_content, .max_content => intrinsic,
        };
    }

    pub fn fixed(value: f32) Dimension {
        return .{ .length = value };
    }

    pub fn percentage(fraction: f32) Dimension {
        return .{ .percent = fraction };
    }
};

/// A length or percentage. Unlike Dimension, this type has no auto state.
pub const LengthPercentage = union(enum) {
    length: f32,
    percent: f32,

    pub fn resolve(self: LengthPercentage, containing: ?f32) ?f32 {
        return switch (self) {
            .length => |value| value,
            .percent => |fraction| if (containing) |size| size * fraction else null,
        };
    }
    pub fn fixed(value: f32) LengthPercentage {
        return .{ .length = value };
    }

    pub fn percentage(fraction: f32) LengthPercentage {
        return .{ .percent = fraction };
    }
};

/// A length, percentage, or auto inset/constraint value.
pub const LengthPercentageAuto = union(enum) {
    auto,
    length: f32,
    percent: f32,

    pub fn resolve(self: LengthPercentageAuto, containing: ?f32) ?f32 {
        return switch (self) {
            .auto => null,
            .length => |value| value,
            .percent => |fraction| if (containing) |size| size * fraction else null,
        };
    }
    pub fn fixed(value: f32) LengthPercentageAuto {
        return .{ .length = value };
    }

    pub fn percentage(fraction: f32) LengthPercentageAuto {
        return .{ .percent = fraction };
    }
};

/// Generic width/height pair used by typed Taffy-like style fields.
pub fn Size(comptime T: type) type {
    return struct {
        width: T,
        height: T,
    };
}

/// Generic top/right/bottom/left rectangle used for insets and box sides.
pub fn Rect(comptime T: type) type {
    return struct {
        top: T,
        right: T,
        bottom: T,
        left: T,
    };
}

pub const DimensionSize = Size(Dimension);
pub const LengthPercentageSize = Size(LengthPercentage);
pub const LengthPercentageAutoSize = Size(LengthPercentageAuto);
pub const Insets = Rect(LengthPercentageAuto);
pub const LengthPercentageRect = Rect(LengthPercentage);
pub const ResolvedSize = Size(?f32);
pub const ResolvedInsets = Rect(?f32);

/// Overflow behavior for one axis.
pub const Overflow = enum { visible, clip, scroll };
pub const OverflowAxes = Size(Overflow);

/// Distinguishes no override, a replacement value, and an explicit clear.
pub fn ExplicitOverride(comptime T: type) type {
    return union(enum) {
        unspecified,
        value: T,
        clear,
    };
}

pub fn Override(comptime T: type) type {
    return ExplicitOverride(T);
}

/// Dimension overrides also accept direct dimension tags, so anonymous option
/// literals can use `.length`, `.percent`, or `.auto` without a wrapper.
pub const DimensionOverride = union(enum) {
    unspecified,
    value: Dimension,
    clear,
    auto,
    length: f32,
    percent: f32,
    min_content,
    max_content,
};

/// Length-percentage-auto overrides mirror the direct value tags.
pub const LengthPercentageAutoOverride = union(enum) {
    unspecified,
    value: LengthPercentageAuto,
    clear,
    auto,
    length: f32,
    percent: f32,
};

pub const DimensionSizeOverride = ExplicitOverride(DimensionSize);
pub const InsetsOverride = ExplicitOverride(Insets);
fn dimensionOverrideValue(value: DimensionOverride) ?Dimension {
    return switch (value) {
        .unspecified => null,
        .value => |dimension| dimension,
        .clear, .auto => .auto,
        .length => |length| .{ .length = length },
        .percent => |percent| .{ .percent = percent },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

fn lengthPercentageAutoOverrideValue(value: LengthPercentageAutoOverride) ?LengthPercentageAuto {
    return switch (value) {
        .unspecified => null,
        .value => |dimension| dimension,
        .clear, .auto => .auto,
        .length => |length| .{ .length = length },
        .percent => |percent| .{ .percent = percent },
    };
}
pub const OverflowAxesOverride = ExplicitOverride(OverflowAxes);

/// The result of resolving all typed dimensions against one containing block.
pub const ResolvedDimensions = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    flex_basis: ?f32 = null,
};

/// Resolved min/max constraints. A null side means that no constraint applies.
pub const ResolvedConstraints = struct {
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,

    pub fn clampWidth(self: ResolvedConstraints, value: f32) f32 {
        return clamp(value, self.min_width, self.max_width);
    }

    pub fn clampHeight(self: ResolvedConstraints, value: f32) f32 {
        return clamp(value, self.min_height, self.max_height);
    }
};

fn clamp(value: f32, minimum: ?f32, maximum: ?f32) f32 {
    var result = value;
    if (minimum) |min_value| result = @max(result, min_value);
    if (maximum) |max_value| {
        // A conflicting minimum wins. This is the same precedence used by
        // CSS used-value resolution when min is larger than max.
        if (minimum) |min_value| {
            if (max_value >= min_value) result = @min(result, max_value);
        } else {
            result = @min(result, max_value);
        }
    }
    return result;
}

/// Total resolved typed style. Legacy flex and box fields remain on Style.
pub const ResolvedStyle = struct {
    dimensions: ResolvedDimensions = .{},
    constraints: ResolvedConstraints = .{},
    insets: ResolvedInsets = .{
        .top = null,
        .right = null,
        .bottom = null,
        .left = null,
    },
    aspect_ratio: ?f32 = null,
    overflow: OverflowAxes = .{ .width = .visible, .height = .visible },

    pub fn clampWidth(self: ResolvedStyle, value: f32) f32 {
        return self.constraints.clampWidth(value);
    }

    pub fn clampHeight(self: ResolvedStyle, value: f32) f32 {
        return self.constraints.clampHeight(value);
    }
};
fn defaultDimensionSize() DimensionSize {
    return .{ .width = .auto, .height = .auto };
}

fn defaultLengthPercentageAutoSize() LengthPercentageAutoSize {
    return .{ .width = .auto, .height = .auto };
}

fn defaultInsets() Insets {
    return .{ .top = .auto, .right = .auto, .bottom = .auto, .left = .auto };
}

fn defaultLengthPercentageRect() LengthPercentageRect {
    return .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };
}

pub fn dimensionFrom(value: anytype) Dimension {
    const T = @TypeOf(value);
    if (T == Dimension) return value;
    if (T == LengthPercentage) {
        return switch (value) {
            .length => |length| .{ .length = length },
            .percent => |percent| .{ .percent = percent },
        };
    }
    if (T == LengthPercentageAuto) {
        return switch (value) {
            .auto => .auto,
            .length => |length| .{ .length = length },
            .percent => |percent| .{ .percent = percent },
        };
    }
    if (T == DimensionOverride) return dimensionOverrideValue(value) orelse .auto;
    if (T == LengthPercentageAutoOverride) {
        return dimensionFrom(lengthPercentageAutoOverrideValue(value) orelse .auto);
    }
    if (T == std.meta.Tag(Dimension)) {
        return switch (value) {
            .auto => .auto,
            .min_content => .min_content,
            .max_content => .max_content,
            .length, .percent => .auto,
        };
    }
    return switch (@typeInfo(T)) {
        .optional => if (value) |inner| dimensionFrom(inner) else .auto,
        .int, .float, .comptime_int, .comptime_float => .{ .length = @floatCast(value) },
        .enum_literal => switch (value) {
            .auto => .auto,
            .min_content => .min_content,
            .max_content => .max_content,
            else => .auto,
        },
        .@"struct" => blk: {
            if (@hasField(T, "length")) break :blk .{ .length = @floatCast(value.length) };
            if (@hasField(T, "percent")) break :blk .{ .percent = @floatCast(value.percent) };
            if (@hasField(T, "auto")) break :blk .auto;
            if (@hasField(T, "min_content")) break :blk .min_content;
            if (@hasField(T, "max_content")) break :blk .max_content;
            @compileError("dimension value must contain length, percent, or intrinsic tag");
        },
        else => @compileError("unsupported dimension value"),
    };
}

pub fn lengthPercentageFrom(value: anytype) LengthPercentage {
    const T = @TypeOf(value);
    if (T == LengthPercentage) return value;
    if (T == LengthPercentageAuto) {
        return switch (value) {
            .length => |length| .{ .length = length },
            .percent => |percent| .{ .percent = percent },
            .auto => .{ .length = 0 },
        };
    }
    if (T == std.meta.Tag(Dimension)) return lengthPercentageFrom(dimensionFrom(value));
    if (T == std.meta.Tag(LengthPercentage)) return .{ .length = 0 };
    if (T == std.meta.Tag(LengthPercentageAuto)) return .{ .length = 0 };
    if (T == Dimension) {
        return switch (value) {
            .length => |length| .{ .length = length },
            .percent => |percent| .{ .percent = percent },
            else => .{ .length = 0 },
        };
    }
    if (T == DimensionOverride) return lengthPercentageFrom(dimensionFrom(value));
    if (T == LengthPercentageAutoOverride) {
        return lengthPercentageFrom(lengthPercentageAutoFrom(value));
    }
    return switch (@typeInfo(T)) {
        .optional => if (value) |inner| lengthPercentageFrom(inner) else .{ .length = 0 },
        .int, .float, .comptime_int, .comptime_float => .{ .length = @floatCast(value) },
        .enum_literal => .{ .length = 0 },
        .@"struct" => blk: {
            if (@hasField(T, "length")) break :blk .{ .length = @floatCast(value.length) };
            if (@hasField(T, "percent")) break :blk .{ .percent = @floatCast(value.percent) };
            @compileError("length-percentage value must contain length or percent");
        },
        else => @compileError("unsupported length-percentage value"),
    };
}

pub fn lengthPercentageAutoFrom(value: anytype) LengthPercentageAuto {
    const T = @TypeOf(value);
    if (T == LengthPercentageAuto) return value;
    if (T == LengthPercentage) {
        return switch (value) {
            .length => |length| .{ .length = length },
            .percent => |percent| .{ .percent = percent },
        };
    }
    if (T == std.meta.Tag(Dimension)) return lengthPercentageAutoFrom(dimensionFrom(value));
    if (T == std.meta.Tag(LengthPercentage)) return .auto;
    if (T == std.meta.Tag(LengthPercentageAuto)) return .auto;
    if (T == DimensionOverride) {
        return lengthPercentageAutoFrom(dimensionFrom(value));
    }
    if (T == LengthPercentageAutoOverride) {
        return lengthPercentageAutoOverrideValue(value) orelse .auto;
    }
    if (T == Dimension) {
        return switch (value) {
            .length => |length| .{ .length = length },
            .percent => |percent| .{ .percent = percent },
            .auto, .min_content, .max_content => .auto,
        };
    }
    return switch (@typeInfo(T)) {
        .optional => if (value) |inner| lengthPercentageAutoFrom(inner) else .auto,
        .int, .float, .comptime_int, .comptime_float => .{ .length = @floatCast(value) },
        .enum_literal => switch (value) {
            .auto => .auto,
            else => .auto,
        },
        .@"struct" => blk: {
            if (@hasField(T, "length")) break :blk .{ .length = @floatCast(value.length) };
            if (@hasField(T, "percent")) break :blk .{ .percent = @floatCast(value.percent) };
            if (@hasField(T, "auto")) break :blk .auto;
            @compileError("length-percentage-auto value must contain length, percent, or auto");
        },
        else => @compileError("unsupported length-percentage-auto value"),
    };
}

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

/// Typed layout input plus legacy compatibility mirrors.
pub const Style = struct {
    display: Display = .flex,
    direction: FlexDirection = .column,
    justify: Justify = .start,
    @"align": Align = .stretch,
    gap: f32 = 0,

    /// Legacy flex values are consumed by the parent; their axis is not the
    /// node's own `direction`.
    grow: f32 = 0,
    shrink: f32 = 1,
    basis: f32 = 0,
    min_main: ?f32 = null,

    /// Taffy-like typed dimensions and flex basis.
    size: DimensionSize = defaultDimensionSize(),
    min_size: DimensionSize = defaultDimensionSize(),
    max_size: DimensionSize = defaultDimensionSize(),
    flex_basis: Dimension = .auto,
    inset: Insets = defaultInsets(),
    aspect_ratio: ?f32 = null,
    overflow: OverflowAxes = .{ .width = .visible, .height = .visible },

    margin: Sides = .{},
    border: Sides = .{},
    padding: Sides = .{},
    box_sizing: BoxSizing = .content_box,
    /// Typed mirrors of the legacy box fields. Fixed legacy values populate
    /// both representations; percentage values stay available to resolution.
    margin_inset: Insets = defaultInsets(),
    border_inset: LengthPercentageRect = defaultLengthPercentageRect(),
    padding_inset: LengthPercentageRect = defaultLengthPercentageRect(),

    pub fn resolve(defaults: Style, local: StyleOverride) Style {
        var result = defaults;
        if (local.display) |value| result.display = value;
        if (local.direction) |value| result.direction = value;
        if (local.justify) |value| result.justify = value;
        if (local.@"align") |value| result.@"align" = value;
        if (local.gap) |value| result.gap = value;
        if (local.grow) |value| result.grow = value;
        if (local.shrink) |value| result.shrink = value;
        if (local.basis) |value| {
            result.basis = value;
            result.flex_basis = .{ .length = value };
        }
        if (dimensionOverrideValue(local.flex_basis)) |value| result.flex_basis = value;
        switch (local.min_main) {
            .unspecified => {},
            .value => |value| result.min_main = value,
        }
        if (local.margin) |value| {
            result.margin = value;
            result.margin_inset = .{
                .top = .{ .length = value.top },
                .right = .{ .length = value.right },
                .bottom = .{ .length = value.bottom },
                .left = .{ .length = value.left },
            };
        }
        if (local.border) |value| {
            result.border = value;
            result.border_inset = .{
                .top = .{ .length = value.top },
                .right = .{ .length = value.right },
                .bottom = .{ .length = value.bottom },
                .left = .{ .length = value.left },
            };
        }
        if (local.padding) |value| {
            result.padding = value;
            result.padding_inset = .{
                .top = .{ .length = value.top },
                .right = .{ .length = value.right },
                .bottom = .{ .length = value.bottom },
                .left = .{ .length = value.left },
            };
        }
        if (local.box_sizing) |value| result.box_sizing = value;
        switch (local.size) {
            .unspecified => {},
            .value => |value| result.size = value,
            .clear => result.size = defaultDimensionSize(),
        }
        switch (local.min_size) {
            .unspecified => {},
            .value => |value| result.min_size = value,
            .clear => result.min_size = defaultDimensionSize(),
        }
        switch (local.max_size) {
            .unspecified => {},
            .value => |value| result.max_size = value,
            .clear => result.max_size = defaultDimensionSize(),
        }
        switch (local.inset) {
            .unspecified => {},
            .value => |value| result.inset = value,
            .clear => result.inset = defaultInsets(),
        }
        switch (local.overflow) {
            .unspecified => {},
            .value => |value| result.overflow = value,
            .clear => result.overflow = .{ .width = .visible, .height = .visible },
        }
        if (dimensionOverrideValue(local.width)) |value| result.size.width = value;
        if (dimensionOverrideValue(local.height)) |value| result.size.height = value;
        if (dimensionOverrideValue(local.min_width)) |value| result.min_size.width = value;
        if (dimensionOverrideValue(local.min_height)) |value| result.min_size.height = value;
        if (dimensionOverrideValue(local.max_width)) |value| result.max_size.width = value;
        if (dimensionOverrideValue(local.max_height)) |value| result.max_size.height = value;
        if (dimensionOverrideValue(local.width_override)) |value| result.size.width = value;
        if (dimensionOverrideValue(local.height_override)) |value| result.size.height = value;
        if (dimensionOverrideValue(local.min_width_override)) |value| {
            result.min_size.width = value;
        }
        if (dimensionOverrideValue(local.min_height_override)) |value| {
            result.min_size.height = value;
        }
        if (dimensionOverrideValue(local.max_width_override)) |value| {
            result.max_size.width = value;
        }
        if (dimensionOverrideValue(local.max_height_override)) |value| {
            result.max_size.height = value;
        }
        switch (local.aspect_ratio) {
            .unspecified => {},
            .value => |value| result.aspect_ratio = value,
            .clear => result.aspect_ratio = null,
        }
        if (local.margin_inset) |value| result.margin_inset = value;
        if (local.border_inset) |value| result.border_inset = value;
        if (local.padding_inset) |value| result.padding_inset = value;
        if (std.meta.activeTag(result.flex_basis) == .auto and result.basis > 0) {
            result.flex_basis = .{ .length = result.basis };
        }
        return result;
    }

    /// Resolve all typed fields. An indefinite containing axis leaves
    /// percentages as auto (`null`) instead of treating them as zero.
    pub fn resolveTotal(
        self: Style,
        containing: ?Size(f32),
        intrinsic: Size(f32),
    ) ResolvedStyle {
        const width_containing = if (containing) |value| value.width else null;
        const height_containing = if (containing) |value| value.height else null;
        const flex_basis = self.flex_basis.resolve(
            if (self.direction == .column) height_containing else width_containing,
            if (self.direction == .column) intrinsic.height else intrinsic.width,
        ) orelse if (self.basis > 0) self.basis else null;
        // Keep legacy `min_main` out of typed constraints: the parent flex
        // direction is the only axis that can resolve that legacy field.
        const constraints: ResolvedConstraints = .{
            .min_width = self.min_size.width.resolve(width_containing, intrinsic.width),
            .min_height = self.min_size.height.resolve(height_containing, intrinsic.height),
            .max_width = self.max_size.width.resolve(width_containing, intrinsic.width),
            .max_height = self.max_size.height.resolve(height_containing, intrinsic.height),
        };
        return .{
            .dimensions = .{
                .width = self.size.width.resolve(width_containing, intrinsic.width),
                .height = self.size.height.resolve(height_containing, intrinsic.height),
                .flex_basis = flex_basis,
            },
            .constraints = constraints,
            .insets = .{
                .top = self.inset.top.resolve(height_containing),
                .right = self.inset.right.resolve(width_containing),
                .bottom = self.inset.bottom.resolve(height_containing),
                .left = self.inset.left.resolve(width_containing),
            },
            .aspect_ratio = self.aspect_ratio,
            .overflow = self.overflow,
        };
    }

    pub fn resolveFor(self: Style, containing: ?Size(f32), intrinsic: Size(f32)) ResolvedStyle {
        return self.resolveTotal(containing, intrinsic);
    }
};

/// Local layout overrides. Unspecified fields retain component defaults.
pub const StyleOverride = struct {
    display: ?Display = null,
    direction: ?FlexDirection = null,
    /// Compatibility spelling accepted by option translators.
    justify: ?Justify = null,
    @"align": ?Align = null,
    gap: ?f32 = null,

    grow: ?f32 = null,
    shrink: ?f32 = null,
    basis: ?f32 = null,
    min_main: OptionalFloatOverride = .unspecified,
    flex_basis: DimensionOverride = .unspecified,

    size: DimensionSizeOverride = .unspecified,
    min_size: ExplicitOverride(DimensionSize) = .unspecified,
    max_size: ExplicitOverride(DimensionSize) = .unspecified,
    inset: InsetsOverride = .unspecified,
    overflow: OverflowAxesOverride = .unspecified,
    aspect_ratio: ExplicitOverride(?f32) = .unspecified,

    /// Direct axis fields make partial overrides possible without replacing
    /// the other axis in `size`, `min_size`, or `max_size`.
    width: DimensionOverride = .unspecified,
    height: DimensionOverride = .unspecified,
    min_width: DimensionOverride = .unspecified,
    min_height: DimensionOverride = .unspecified,
    max_width: DimensionOverride = .unspecified,
    max_height: DimensionOverride = .unspecified,
    width_override: DimensionOverride = .unspecified,
    height_override: DimensionOverride = .unspecified,
    min_width_override: DimensionOverride = .unspecified,
    min_height_override: DimensionOverride = .unspecified,
    max_width_override: DimensionOverride = .unspecified,
    max_height_override: DimensionOverride = .unspecified,

    margin: ?Sides = null,
    border: ?Sides = null,
    padding: ?Sides = null,
    box_sizing: ?BoxSizing = null,
    margin_inset: ?Insets = null,
    border_inset: ?LengthPercentageRect = null,
    padding_inset: ?LengthPercentageRect = null,
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
test "typed dimension fixed resolves" {
    try std.testing.expectEqual(@as(?f32, 32), Dimension.fixed(32).resolve(null, 9));
}

test "typed dimension percentage resolves against definite parent" {
    const resolved = (Style{
        .size = .{ .width = .{ .percent = 0.25 }, .height = .auto },
    }).resolveTotal(.{ .width = 200, .height = 100 }, .{ .width = 0, .height = 0 });
    try std.testing.expectEqual(@as(?f32, 50), resolved.dimensions.width);
}

test "typed dimension auto and intrinsic resolve" {
    try std.testing.expectEqual(@as(?f32, null), Dimension.resolve(.auto, null, 40));
    try std.testing.expectEqual(@as(?f32, 12), Dimension.resolve(.min_content, null, 12));
    try std.testing.expectEqual(@as(?f32, 24), Dimension.resolve(.max_content, null, 24));
}

test "typed min max precedence clamps minimum" {
    const resolved = (Style{
        .min_size = .{ .width = .{ .length = 50 }, .height = .auto },
        .max_size = .{ .width = .{ .length = 20 }, .height = .auto },
    }).resolveTotal(null, .{ .width = 10, .height = 10 });
    try std.testing.expectEqual(@as(f32, 50), resolved.clampWidth(10));
}

test "typed style explicit clear override" {
    const resolved = Style.resolve(
        .{ .size = .{ .width = .{ .length = 80 }, .height = .auto } },
        .{ .width_override = .clear },
    );
    try std.testing.expect(std.meta.eql(@as(Dimension, .auto), resolved.size.width));
    const direct = Style.resolve(
        .{ .size = .{ .width = .{ .length = 64 }, .height = .auto } },
        .{ .width = .clear },
    );
    try std.testing.expect(std.meta.eql(@as(Dimension, .auto), direct.size.width));
}

test "typed percentage remains auto for indefinite parent" {
    const resolved = (Style{
        .size = .{ .width = .{ .percent = 0.5 }, .height = .auto },
        .min_size = .{ .width = .{ .percent = 0.25 }, .height = .auto },
        .inset = .{
            .top = .auto,
            .right = .{ .percent = 0.1 },
            .bottom = .auto,
            .left = .auto,
        },
    }).resolveTotal(null, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(?f32, null), resolved.dimensions.width);
    try std.testing.expectEqual(@as(?f32, null), resolved.constraints.min_width);
    try std.testing.expectEqual(@as(?f32, null), resolved.insets.right);
}

test "dimension converters accept anonymous literals typed unions and optionals" {
    try std.testing.expect(std.meta.eql(
        @as(Dimension, .{ .length = 18 }),
        dimensionFrom(.{ .length = 18 }),
    ));
    try std.testing.expect(std.meta.eql(
        @as(Dimension, .{ .percent = 0.25 }),
        dimensionFrom(.{ .percent = 0.25 }),
    ));
    try std.testing.expect(std.meta.eql(@as(Dimension, .auto), dimensionFrom(.auto)));

    const typed_percent: LengthPercentage = .{ .percent = 0.5 };
    try std.testing.expect(std.meta.eql(
        @as(Dimension, .{ .percent = 0.5 }),
        dimensionFrom(typed_percent),
    ));
    try std.testing.expect(std.meta.eql(
        @as(LengthPercentageAuto, .{ .percent = 0.5 }),
        lengthPercentageAutoFrom(typed_percent),
    ));
    const typed_length: LengthPercentage = .{ .length = 11 };
    try std.testing.expect(std.meta.eql(
        @as(LengthPercentage, .{ .length = 11 }),
        lengthPercentageFrom(typed_length),
    ));
    const optional_length: ?LengthPercentage = .{ .length = 13 };
    try std.testing.expect(std.meta.eql(
        @as(LengthPercentage, .{ .length = 13 }),
        lengthPercentageFrom(optional_length),
    ));

    const optional_fixed: ?Dimension = .{ .length = 7 };
    const optional_absent: ?Dimension = null;
    try std.testing.expect(std.meta.eql(
        @as(Dimension, .{ .length = 7 }),
        dimensionFrom(optional_fixed),
    ));
    try std.testing.expect(std.meta.eql(@as(Dimension, .auto), dimensionFrom(optional_absent)));
}
