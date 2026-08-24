const std = @import("std");

/// Inline text direction.
pub const Direction = enum {
    ltr,
    rtl,
};

/// Side to which an in-flow box floats.
pub const Float = enum {
    none,
    left,
    right,
    inline_start,
    inline_end,
};

/// Sides on which a box must clear earlier floats.
pub const Clear = enum {
    none,
    left,
    right,
    both,
    inline_start,
    inline_end,
};

/// Canonical alignment keywords. Safe and unsafe center are distinct values.
pub const Alignment = enum {
    normal,
    stretch,
    start,
    center,
    end,
    safe_center,
    unsafe_center,
};

pub const CalcError = error{
    IndefinitePercentage,
    InvalidStyle,
};

/// A bounded affine calculation: `length + percent * containing_size`.
///
/// The representation is a value type. It does not allocate and does not
/// depend on a renderer or on the no-api compatibility layer.
pub const Calc = struct {
    length_sum: f32 = 0,
    percent_sum: f32 = 0,
    has_percentage: bool = false,

    pub fn length(value: f32) Calc {
        return .{ .length_sum = value };
    }

    pub fn percent(fraction: f32) Calc {
        return .{ .percent_sum = fraction, .has_percentage = true };
    }

    pub fn add(left: Calc, right: Calc) Calc {
        return .{
            .length_sum = left.length_sum + right.length_sum,
            .percent_sum = left.percent_sum + right.percent_sum,
            .has_percentage = left.hasPercentage() or right.hasPercentage(),
        };
    }

    fn hasPercentage(self: Calc) bool {
        // Keep legacy zero-percent constructors indefinite while also
        // recognizing direct public literals that omit the historical flag.
        return self.has_percentage or self.percent_sum != 0;
    }

    pub fn resolve(self: Calc, containing_size: ?f32) CalcError!f32 {
        if (!std.math.isFinite(self.length_sum) or
            !std.math.isFinite(self.percent_sum))
        {
            return error.InvalidStyle;
        }

        const size = containing_size orelse {
            if (self.hasPercentage()) return error.IndefinitePercentage;
            return self.length_sum;
        };
        if (!std.math.isFinite(size)) return error.InvalidStyle;

        const resolved = self.length_sum + self.percent_sum * size;
        if (!std.math.isFinite(resolved)) return error.InvalidStyle;
        return resolved;
    }
};

/// Constructor facade for typed CSS-style calculations.
pub fn calc(value: Calc) Calc {
    return value;
}
