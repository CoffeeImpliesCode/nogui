const std = @import("std");
const style = @import("../style.zig");

pub const Error = error{
    InvalidStyle,
    IndefinitePercentage,
};
pub const SizingError = Error;

pub const AvailableSpace = union(enum) {
    definite: f32,
    min_content,
    max_content,
};

pub const AvailableSize = style.Size(AvailableSpace);
pub const ResolvedSize = style.Size(f32);
pub const OptionalSize = style.Size(?f32);

pub const SizingContext = struct {
    available: AvailableSize,
    percentage_basis: OptionalSize,
};

pub const BoxModelResult = struct {
    content_box: OptionalSize,
    border_box: OptionalSize,
};

const ResolvedRect = style.Rect(f32);

pub fn resolveDimension(
    dimension: style.Dimension,
    available_space: AvailableSpace,
    percentage_basis: ?f32,
) Error!?f32 {
    try validateAvailableSpace(available_space);
    const validated_percentage_basis = try validateOptionalFinite(percentage_basis);

    return switch (dimension) {
        .auto, .min_content, .max_content => null,
        .length => |value| try validateFinite(value),
        .percent => |value| try resolvePercentage(value, validated_percentage_basis),
    };
}

pub fn resolveBoxModel(
    input_style: style.Style,
    context: SizingContext,
) Error!BoxModelResult {
    try validateSizingContext(context);

    const percentage_width = context.percentage_basis.width;
    const percentage_height = context.percentage_basis.height;
    const padding_border = try resolvePaddingBorder(input_style, percentage_width);
    const adjustment = boxAdjustment(input_style.box_sizing, padding_border);
    const preferred = try applyAspectRatio(input_style, .{
        .width = try resolveDimension(
            input_style.size.width,
            context.available.width,
            percentage_width,
        ),
        .height = try resolveDimension(
            input_style.size.height,
            context.available.height,
            percentage_height,
        ),
    });
    const adjusted = try addOptionalSize(preferred, adjustment);
    const border_box = try floorOptionalSize(adjusted, padding_border);

    return .{
        .content_box = try subtractOptionalSize(border_box, padding_border),
        .border_box = border_box,
    };
}

pub fn clampSize(
    input_style: style.Style,
    candidate: ResolvedSize,
    context: SizingContext,
) Error!ResolvedSize {
    try validateSizingContext(context);

    const percentage_width = context.percentage_basis.width;
    const percentage_height = context.percentage_basis.height;
    const padding_border = try resolvePaddingBorder(input_style, percentage_width);
    const adjustment = boxAdjustment(input_style.box_sizing, padding_border);
    const candidate_border_box: ResolvedSize = .{
        .width = try addFinite(candidate.width, adjustment.width),
        .height = try addFinite(candidate.height, adjustment.height),
    };
    const minimum = try addOptionalSize(
        try applyAspectRatio(input_style, .{
            .width = try resolveDimension(
                input_style.min_size.width,
                context.available.width,
                percentage_width,
            ),
            .height = try resolveDimension(
                input_style.min_size.height,
                context.available.height,
                percentage_height,
            ),
        }),
        adjustment,
    );
    const maximum = try addOptionalSize(
        try applyAspectRatio(input_style, .{
            .width = try resolveDimension(
                input_style.max_size.width,
                context.available.width,
                percentage_width,
            ),
            .height = try resolveDimension(
                input_style.max_size.height,
                context.available.height,
                percentage_height,
            ),
        }),
        adjustment,
    );

    return .{
        .width = @max(
            try clampAxis(candidate_border_box.width, minimum.width, maximum.width),
            padding_border.width,
        ),
        .height = @max(
            try clampAxis(candidate_border_box.height, minimum.height, maximum.height),
            padding_border.height,
        ),
    };
}

pub fn applyAspectRatio(
    input_style: style.Style,
    size: OptionalSize,
) Error!OptionalSize {
    const width = try validateOptionalFinite(size.width);
    const height = try validateOptionalFinite(size.height);
    const ratio = input_style.aspect_ratio orelse return .{
        .width = width,
        .height = height,
    };

    if (!std.math.isFinite(ratio) or ratio <= 0) return error.InvalidStyle;

    if (width != null and height == null) {
        return .{
            .width = width,
            .height = try validateFinite(width.? / ratio),
        };
    }
    if (width == null and height != null) {
        return .{
            .width = try validateFinite(height.? * ratio),
            .height = height,
        };
    }

    return .{
        .width = width,
        .height = height,
    };
}

fn resolvePaddingBorder(
    input_style: style.Style,
    percentage_basis: ?f32,
) Error!ResolvedSize {
    // Taffy resolves every padding and border percentage against the
    // containing block's inline (width) basis.
    const padding = try resolveRect(input_style.padding_inset, percentage_basis);
    const border = try resolveRect(input_style.border_inset, percentage_basis);
    return .{
        .width = try addFinite(
            try addFinite(padding.left, padding.right),
            try addFinite(border.left, border.right),
        ),
        .height = try addFinite(
            try addFinite(padding.top, padding.bottom),
            try addFinite(border.top, border.bottom),
        ),
    };
}

fn boxAdjustment(
    box_sizing: style.BoxSizing,
    padding_border: ResolvedSize,
) ResolvedSize {
    return switch (box_sizing) {
        .content_box => padding_border,
        .border_box => .{ .width = 0, .height = 0 },
    };
}

fn addOptionalSize(size: OptionalSize, adjustment: ResolvedSize) Error!OptionalSize {
    return .{
        .width = try addOptional(size.width, adjustment.width),
        .height = try addOptional(size.height, adjustment.height),
    };
}

fn addOptional(value: ?f32, adjustment: f32) Error!?f32 {
    if (value) |resolved| {
        const adjusted: f32 = try addFinite(resolved, adjustment);
        return adjusted;
    }
    return null;
}

fn floorOptionalSize(size: OptionalSize, floor: ResolvedSize) Error!OptionalSize {
    return .{
        .width = try floorOptional(size.width, floor.width),
        .height = try floorOptional(size.height, floor.height),
    };
}

fn floorOptional(value: ?f32, floor: f32) Error!?f32 {
    if (value) |resolved| {
        const floored: f32 = try validateFinite(@max(resolved, floor));
        return floored;
    }
    return null;
}

fn subtractOptionalSize(size: OptionalSize, subtrahend: ResolvedSize) Error!OptionalSize {
    return .{
        .width = try subtractOptional(size.width, subtrahend.width),
        .height = try subtractOptional(size.height, subtrahend.height),
    };
}

fn subtractOptional(value: ?f32, subtrahend: f32) Error!?f32 {
    if (value) |resolved| {
        const difference: f32 = try subtractFinite(resolved, subtrahend);
        return difference;
    }
    return null;
}

fn resolveRect(
    rect: style.LengthPercentageRect,
    percentage_basis: ?f32,
) Error!ResolvedRect {
    return .{
        .top = try resolveLengthPercentage(rect.top, percentage_basis),
        .right = try resolveLengthPercentage(rect.right, percentage_basis),
        .bottom = try resolveLengthPercentage(rect.bottom, percentage_basis),
        .left = try resolveLengthPercentage(rect.left, percentage_basis),
    };
}

fn resolveLengthPercentage(
    dimension: style.LengthPercentage,
    percentage_basis: ?f32,
) Error!f32 {
    return switch (dimension) {
        .length => |value| try validateFinite(value),
        .percent => |value| (try resolvePercentage(value, percentage_basis)) orelse 0,
    };
}

fn resolvePercentage(value: f32, percentage_basis: ?f32) Error!?f32 {
    const fraction = try validateFinite(value);
    const basis = try validateOptionalFinite(percentage_basis) orelse return null;
    const resolved = try validateFinite(fraction * basis);
    return resolved;
}

fn clampAxis(base: f32, minimum: ?f32, maximum: ?f32) Error!f32 {
    var result = try validateFinite(base);
    if (maximum) |value| result = @min(result, try validateFinite(value));
    if (minimum) |value| result = @max(result, try validateFinite(value));
    return validateFinite(result);
}

fn validateSizingContext(context: SizingContext) Error!void {
    try validateAvailableSize(context.available);
    _ = try validateOptionalFinite(context.percentage_basis.width);
    _ = try validateOptionalFinite(context.percentage_basis.height);
}

fn validateAvailableSize(available_size: AvailableSize) Error!void {
    try validateAvailableSpace(available_size.width);
    try validateAvailableSpace(available_size.height);
}

fn validateAvailableSpace(available_space: AvailableSpace) Error!void {
    switch (available_space) {
        .definite => |value| _ = try validateFinite(value),
        .min_content, .max_content => {},
    }
}

fn validateOptionalFinite(value: ?f32) Error!?f32 {
    if (value) |resolved| {
        const finite = try validateFinite(resolved);
        return finite;
    }
    return null;
}

fn addFinite(lhs: f32, rhs: f32) Error!f32 {
    return validateFinite(lhs + rhs);
}

fn subtractFinite(lhs: f32, rhs: f32) Error!f32 {
    return validateFinite(lhs - rhs);
}

fn validateFinite(value: f32) Error!f32 {
    if (!std.math.isFinite(value)) return error.InvalidStyle;
    return value;
}
