//! CPU text measurement and shaping for caller-owned font data.
//!
//! One implementation serves the headless measure hook, the immutable text
//! layout and the graphical host. Hosts alias these declarations instead of
//! keeping a second measurement or shaping pipeline.

const measure = @import("measure.zig");

pub const measurer = @import("measurer.zig");
pub const shaping = @import("shape_cache.zig");
pub const text = @import("nogui").text;
pub const CounterSink = @import("nogui").CounterSink;

// ── Text service and immutable layout ───────────────
pub const TextService = measure.TextService;
pub const TextLayout = measure.TextLayout;
pub const LayoutLine = measure.LayoutLine;
pub const LayoutRun = measure.LayoutRun;
pub const FontInfo = measure.FontInfo;
pub const FontSource = measure.FontSource;

// ── Shared CPU measurement ──────────────────────────
pub const ShapedAdvance = measure.ShapedAdvance;
pub const FallbackAdvance = measure.FallbackAdvance;
pub const LineRange = measure.LineRange;
pub const LineRangeIterator = measure.LineRangeIterator;
pub const PendingSegment = measure.PendingSegment;
pub const TextSegment = measure.TextSegment;
pub const BreakKind = measure.BreakKind;
pub const WidthMode = measure.WidthMode;
pub const IntrinsicMetrics = measure.IntrinsicMetrics;
pub const FlowMetrics = measure.FlowMetrics;
pub const FlowKey = measure.FlowKey;
pub const font_size_px = measure.font_size_px;
pub const fallback_scalar_advance = measure.fallback_scalar_advance;

// ── The node seam and the measure hooks ─────────────
pub const NodeLayoutOptions = measure.NodeLayoutOptions;
pub const TextLayoutError = measure.TextLayoutError;
pub const TextMeasurer = measurer.TextMeasurer;
pub const NodeMeasurer = measurer.NodeMeasurer;
pub const MeasureSource = measurer.MeasureSource;
pub const TextMeasurement = measurer.TextMeasurement;

pub const textClusterIsControl = measure.textClusterIsControl;
pub const measureRange = measure.measureRange;
pub const nextTextSegment = measure.nextTextSegment;
pub const segmentHasContent = measure.segmentHasContent;
pub const intrinsicMetrics = measure.intrinsicMetrics;
pub const intrinsicMetricsUncached = measure.intrinsicMetricsUncached;
pub const normalizedFlowWidth = measure.normalizedFlowWidth;
pub const wrappedLineCount = measure.wrappedLineCount;
pub const measureFlow = measure.measureFlow;
pub const measureByLinePolicy = measure.measureByLinePolicy;
pub const widthMode = measure.widthMode;

test {
    _ = @import("measurer.zig");
    _ = @import("measure.zig");
    _ = @import("w11_contract_test.zig");
    _ = @import("shape_cache_contract_test.zig");
}
