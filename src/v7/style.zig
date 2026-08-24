//! Typed, fieldwise-resolved layout and paint values.
const std = @import("std");
const values = @import("layout/values.zig");

pub const Direction = values.Direction;
pub const Float = values.Float;
pub const Clear = values.Clear;
pub const Alignment = values.Alignment;
pub const Calc = values.Calc;
pub const CalcError = values.CalcError;
pub const calc = values.calc;

pub const Color = [4]f32;
pub const TextureId = u32;
pub const Layer = u32;

/// Layout modes supported by the v7 dispatcher.
pub const Display = enum { block, flex, grid, flow_root, none };

/// Whether a node participates in normal flow or is removed from it.
pub const Position = enum { relative, absolute };

pub const FlexDirection = enum { column, row, column_reverse, row_reverse };
pub const FlexWrap = enum { nowrap, wrap, wrap_reverse };
pub const Justify = enum { start, center, end, space_between, space_around, space_evenly };
pub const Align = enum {
    stretch,
    start,
    center,
    end,

    pub const safe_center: Alignment = .safe_center;
    pub const unsafe_center: Alignment = .unsafe_center;
};
pub const AlignContent = enum { stretch, start, center, end, space_between, space_around };
pub const AlignSelf = enum { auto, stretch, start, center, end };
pub const BoxSizing = enum { content_box, border_box };

/// One non-recursive grid track bound. Percentages are fractions in 0..1.
pub const GridTrackBreadth = union(enum) {
    fixed: f32,
    percent: f32,
    auto,
    min_content,
    max_content,
    fr: f32,
};

pub const GridMinMax = struct {
    min: GridTrackBreadth,
    max: GridTrackBreadth,
};

/// A CSS-grid track sizing function.
pub const GridTrack = union(enum) {
    fixed: f32,
    percent: f32,
    auto,
    min_content,
    max_content,
    fr: f32,
    minmax: GridMinMax,

    pub fn fraction(weight: f32) GridTrack {
        return .{ .fr = weight };
    }
};

/// One grid line value. Positive lines are one-based; spans are track counts.
pub const GridPlacement = union(enum) {
    auto,
    line: i16,
    span: u8,
};

pub const GridLine = struct {
    start: GridPlacement = .auto,
    end: GridPlacement = .auto,
};

pub const GridAutoFlow = enum {
    row,
    column,
    row_dense,
    column_dense,
};

pub fn directionIsColumn(direction: FlexDirection) bool {
    return direction == .column or direction == .column_reverse;
}

pub fn directionIsReverse(direction: FlexDirection) bool {
    return direction == .column_reverse or direction == .row_reverse;
}

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
pub const Overflow = enum { visible, clip, scroll, auto };
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

fn defaultMarginInsets() Insets {
    return .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };
}

fn defaultLengthPercentageRect() LengthPercentageRect {
    return .{
        .top = .{ .length = 0 },
        .right = .{ .length = 0 },
        .bottom = .{ .length = 0 },
        .left = .{ .length = 0 },
    };
}

fn numericF32(value: anytype) f32 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("dimension payload must be numeric"),
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
        .int, .float, .comptime_int, .comptime_float => .{ .length = numericF32(value) },
        .enum_literal => switch (value) {
            .auto => .auto,
            .min_content => .min_content,
            .max_content => .max_content,
            else => .auto,
        },
        .@"struct" => blk: {
            if (@hasField(T, "length")) break :blk .{ .length = numericF32(value.length) };
            if (@hasField(T, "percent")) break :blk .{ .percent = numericF32(value.percent) };
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
        .int, .float, .comptime_int, .comptime_float => .{ .length = numericF32(value) },
        .enum_literal => .{ .length = 0 },
        .@"struct" => blk: {
            if (@hasField(T, "length")) break :blk .{ .length = numericF32(value.length) };
            if (@hasField(T, "percent")) break :blk .{ .percent = numericF32(value.percent) };
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
        .int, .float, .comptime_int, .comptime_float => .{ .length = numericF32(value) },
        .enum_literal => switch (value) {
            .auto => .auto,
            else => .auto,
        },
        .@"struct" => blk: {
            if (@hasField(T, "length")) break :blk .{ .length = numericF32(value.length) };
            if (@hasField(T, "percent")) break :blk .{ .percent = numericF32(value.percent) };
            if (@hasField(T, "auto")) break :blk .auto;
            @compileError("length-percentage-auto value must contain length, percent, or auto");
        },
        else => @compileError("unsupported length-percentage-auto value"),
    };
}

fn syncLegacyFixedSides(legacy: *Sides, typed: *const LengthPercentageRect) void {
    switch (typed.top) {
        .length => |value| legacy.top = value,
        .percent => {},
    }
    switch (typed.right) {
        .length => |value| legacy.right = value,
        .percent => {},
    }
    switch (typed.bottom) {
        .length => |value| legacy.bottom = value,
        .percent => {},
    }
    switch (typed.left) {
        .length => |value| legacy.left = value,
        .percent => {},
    }
}

/// Distinguishes an unspecified override from an explicit texture removal.
pub const TextureOverride = union(enum) {
    unspecified,
    value: ?TextureId,
};

/// Typed layout input plus legacy compatibility mirrors.
pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative,
    /// Legacy flex main-axis direction. Kept until the typed style cutover.
    direction: FlexDirection = .column,
    /// Canonical inline direction.
    writing_direction: Direction = .ltr,
    float: Float = .none,
    clear: Clear = .none,
    wrap: FlexWrap = .nowrap,
    /// Compatibility spelling for callers that use the CSS property name.
    flex_wrap: FlexWrap = .nowrap,
    justify: Justify = .start,
    @"align": Align = .stretch,
    align_content: AlignContent = .stretch,
    align_self: AlignSelf = .auto,
    gap: f32 = 0,
    column_gap: f32 = 0,
    row_gap: f32 = 0,

    /// Grid container track definitions. Slices must have frame-stable
    /// storage, such as static option data or the frame arena.
    grid_template_columns: []const GridTrack = &.{},
    grid_template_rows: []const GridTrack = &.{},
    grid_auto_columns: GridTrack = .auto,
    grid_auto_rows: GridTrack = .auto,
    grid_auto_flow: GridAutoFlow = .row,
    grid_column_gap: f32 = 0,
    grid_row_gap: f32 = 0,
    grid_justify_content: Justify = .start,
    grid_align_content: AlignContent = .stretch,
    grid_justify_items: Align = .stretch,
    grid_align_items: Align = .stretch,
    grid_justify_self: AlignSelf = .auto,
    grid_column_start: GridPlacement = .auto,
    grid_column_end: GridPlacement = .auto,
    grid_row_start: GridPlacement = .auto,
    grid_row_end: GridPlacement = .auto,
    grid_align_self: AlignSelf = .auto,
    grid_column: GridLine = .{},
    grid_row: GridLine = .{},

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
    margin_inset: Insets = defaultMarginInsets(),
    border_inset: LengthPercentageRect = defaultLengthPercentageRect(),
    padding_inset: LengthPercentageRect = defaultLengthPercentageRect(),

    pub fn resolve(defaults: Style, local: StyleOverride) Style {
        var result = defaults;
        if (local.display) |value| result.display = value;
        if (local.position) |value| result.position = value;
        if (local.writing_direction) |value| result.writing_direction = value;
        if (local.float) |value| result.float = value;
        if (local.clear) |value| result.clear = value;
        if (local.direction) |value| result.direction = value;
        if (local.flex_direction) |value| result.direction = value;
        if (local.wrap) |value| {
            result.wrap = value;
            result.flex_wrap = value;
        }
        if (local.flex_wrap) |value| {
            result.wrap = value;
            result.flex_wrap = value;
        }
        if (local.justify) |value| result.justify = value;
        if (local.@"align") |value| result.@"align" = value;
        if (local.align_content) |value| result.align_content = value;
        if (local.align_self) |value| result.align_self = value;
        if (local.gap) |value| result.gap = value;
        if (local.column_gap) |value| result.column_gap = value;
        if (local.row_gap) |value| result.row_gap = value;
        if (local.grid_template_columns) |value| result.grid_template_columns = value;
        if (local.grid_template_rows) |value| result.grid_template_rows = value;
        if (local.grid_auto_columns) |value| result.grid_auto_columns = value;
        if (local.grid_auto_rows) |value| result.grid_auto_rows = value;
        if (local.grid_auto_flow) |value| result.grid_auto_flow = value;
        if (local.grid_column_gap) |value| result.grid_column_gap = value;
        if (local.grid_row_gap) |value| result.grid_row_gap = value;
        if (local.grid_justify_content) |value| result.grid_justify_content = value;
        if (local.grid_align_content) |value| result.grid_align_content = value;
        if (local.grid_justify_items) |value| result.grid_justify_items = value;
        if (local.grid_align_items) |value| result.grid_align_items = value;
        if (local.grid_justify_self) |value| result.grid_justify_self = value;
        if (local.grid_align_self) |value| result.grid_align_self = value;
        if (local.grid_column) |value| result.grid_column = value;
        if (local.grid_column_start) |value| result.grid_column_start = value;
        if (local.grid_column_end) |value| result.grid_column_end = value;
        if (local.grid_row_start) |value| result.grid_row_start = value;
        if (local.grid_row_end) |value| result.grid_row_end = value;
        if (local.grid_row) |value| result.grid_row = value;
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
        if (local.border_inset) |value| {
            result.border_inset = value;
            syncLegacyFixedSides(&result.border, &value);
        }
        if (local.padding_inset) |value| {
            result.padding_inset = value;
            syncLegacyFixedSides(&result.padding, &value);
        }
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
        return self.resolveTotalAxes(width_containing, height_containing, intrinsic);
    }

    /// Resolve typed fields when the two containing-block axes have
    /// independent definiteness.
    pub fn resolveTotalAxes(
        self: Style,
        width_containing: ?f32,
        height_containing: ?f32,
        intrinsic: Size(f32),
    ) ResolvedStyle {
        const flex_basis = self.flex_basis.resolve(
            if (directionIsColumn(self.direction)) height_containing else width_containing,
            if (directionIsColumn(self.direction)) intrinsic.height else intrinsic.width,
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

/// Distinguishes an unspecified legacy main-axis override from an explicit clear.
pub const OptionalFloatOverride = union(enum) {
    unspecified,
    value: ?f32,
};

/// Local layout overrides. Unspecified fields retain component defaults.
pub const StyleOverride = struct {
    display: ?Display = null,
    position: ?Position = null,
    writing_direction: ?Direction = null,
    float: ?Float = null,
    clear: ?Clear = null,
    direction: ?FlexDirection = null,
    /// Compatibility spelling accepted by option translators.
    flex_direction: ?FlexDirection = null,
    wrap: ?FlexWrap = null,
    flex_wrap: ?FlexWrap = null,
    /// Compatibility spelling accepted by option translators.
    justify: ?Justify = null,
    @"align": ?Align = null,
    align_content: ?AlignContent = null,
    align_self: ?AlignSelf = null,
    gap: ?f32 = null,
    column_gap: ?f32 = null,
    row_gap: ?f32 = null,
    grid_template_columns: ?[]const GridTrack = null,
    grid_template_rows: ?[]const GridTrack = null,
    grid_auto_columns: ?GridTrack = null,
    grid_auto_rows: ?GridTrack = null,
    grid_auto_flow: ?GridAutoFlow = null,
    grid_column_gap: ?f32 = null,
    grid_row_gap: ?f32 = null,
    grid_justify_content: ?Justify = null,
    grid_align_content: ?AlignContent = null,
    grid_justify_items: ?Align = null,
    grid_align_items: ?Align = null,
    grid_justify_self: ?AlignSelf = null,
    grid_align_self: ?AlignSelf = null,
    grid_column: ?GridLine = null,
    grid_row: ?GridLine = null,
    grid_column_start: ?GridPlacement = null,
    grid_column_end: ?GridPlacement = null,
    grid_row_start: ?GridPlacement = null,
    grid_row_end: ?GridPlacement = null,

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

/// Typed defaults scoped to one component draw. A missing half is empty and
/// never inherits layout values from the enclosing component.
pub const ComponentDefaults = struct {
    style: ?Style = null,
    paint: ?PaintStyle = null,
};

test "ComponentDefaults keeps layout and paint scopes independently optional" {
    const defaults: ComponentDefaults = .{
        .style = .{ .gap = 16 },
        .paint = .{ .layer = 3 },
    };
    try std.testing.expectEqual(@as(?f32, 16), defaults.style.?.gap);
    try std.testing.expectEqual(@as(?Layer, 3), defaults.paint.?.layer);
    const empty: ComponentDefaults = .{};
    try std.testing.expectEqual(@as(?Style, null), empty.style);
    try std.testing.expectEqual(@as(?PaintStyle, null), empty.paint);
}

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

test "display and position resolve through typed style overrides" {
    const resolved = Style.resolve(
        .{},
        .{ .display = .block, .position = .absolute },
    );
    try std.testing.expectEqual(Display.block, resolved.display);
    try std.testing.expectEqual(Position.absolute, resolved.position);
}

test "typed axes resolve width while height remains indefinite" {
    const resolved = (Style{
        .size = .{
            .width = .{ .percent = 0.5 },
            .height = .{ .percent = 0.5 },
        },
    }).resolveTotalAxes(200, null, .{ .width = 20, .height = 10 });
    try std.testing.expectEqual(@as(?f32, 100), resolved.dimensions.width);
    try std.testing.expectEqual(@as(?f32, null), resolved.dimensions.height);
}

test "typed wrapped flex options resolve fieldwise" {
    const resolved = Style.resolve(.{}, .{
        .direction = .row_reverse,
        .wrap = .wrap_reverse,
        .align_content = .space_around,
        .align_self = .end,
        .margin_inset = .{
            .top = .auto,
            .right = .{ .percent = 0.1 },
            .bottom = .{ .length = 4 },
            .left = .{ .length = 2 },
        },
    });
    try std.testing.expectEqual(FlexDirection.row_reverse, resolved.direction);
    try std.testing.expectEqual(FlexWrap.wrap_reverse, resolved.wrap);
    try std.testing.expectEqual(FlexWrap.wrap_reverse, resolved.flex_wrap);
    try std.testing.expectEqual(AlignContent.space_around, resolved.align_content);
    try std.testing.expectEqual(AlignSelf.end, resolved.align_self);
    try std.testing.expect(std.meta.eql(
        @as(LengthPercentageAuto, .auto),
        resolved.margin_inset.top,
    ));
}

test "grid style types and overrides retain typed placement" {
    const tracks = [_]GridTrack{
        .{ .fixed = 40 },
        .{ .minmax = .{ .min = .auto, .max = .{ .fr = 1 } } },
    };
    const resolved = Style.resolve(.{}, .{
        .display = .grid,
        .grid_template_columns = tracks[0..],
        .grid_auto_flow = .row_dense,
        .grid_column = .{
            .start = .{ .line = 1 },
            .end = .{ .span = 2 },
        },
        .grid_row_gap = 6,
    });
    try std.testing.expectEqual(Display.grid, resolved.display);
    try std.testing.expectEqual(@as(usize, 2), resolved.grid_template_columns.len);
    try std.testing.expectEqual(GridAutoFlow.row_dense, resolved.grid_auto_flow);
    try std.testing.expectEqual(@as(f32, 6), resolved.grid_row_gap);
    try std.testing.expect(std.meta.eql(
        @as(GridPlacement, .{ .span = 2 }),
        resolved.grid_column.end,
    ));
}

test "canonical display supports none" {
    try std.testing.expectEqual(@as(Display, .none), Display.none);
}

test "canonical direction supports rtl" {
    try std.testing.expectEqual(@as(Direction, .rtl), Direction.rtl);
}

test "canonical overflow supports auto" {
    try std.testing.expectEqual(@as(Overflow, .auto), Overflow.auto);
}

test "canonical float defaults to none" {
    try std.testing.expectEqual(Float.none, (Style{}).float);
}

test "canonical clear defaults to none" {
    try std.testing.expectEqual(Clear.none, (Style{}).clear);
}

test "canonical alignment distinguishes safe and unsafe center" {
    try std.testing.expect(Align.safe_center != Align.unsafe_center);
}

test "calc resolves length plus percentage" {
    const resolved = try calc(.add(.length(20), .percent(0.15))).resolve(100);
    try std.testing.expectEqual(@as(f32, 35), resolved);
}

test "calc reports indefinite percentage" {
    try std.testing.expectError(
        error.IndefinitePercentage,
        calc(.percent(0.15)).resolve(null),
    );
}

test "Style resolve applies canonical flow overrides" {
    const resolved = Style.resolve(.{}, .{
        .writing_direction = .rtl,
        .float = .inline_end,
        .clear = .both,
    });

    try std.testing.expectEqual(Direction.rtl, resolved.writing_direction);
    try std.testing.expectEqual(Float.inline_end, resolved.float);
    try std.testing.expectEqual(Clear.both, resolved.clear);
}

test "calc direct percentage literal reports indefinite percentage" {
    try std.testing.expectError(
        error.IndefinitePercentage,
        (Calc{ .percent_sum = 0.5 }).resolve(null),
    );
}

test "calc preserves percentage presence when direct terms cancel" {
    const positive: Calc = .{ .percent_sum = 0.5 };
    const negative: Calc = .{ .percent_sum = -0.5 };

    try std.testing.expectError(
        error.IndefinitePercentage,
        Calc.add(positive, negative).resolve(null),
    );
}
