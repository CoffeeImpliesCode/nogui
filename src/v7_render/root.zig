//! Canonical v7 renderer module.

pub const render_9slice = @import("render_9slice.zig");
pub const sweeper = @import("sweeper.zig");

pub const ClipRect = render_9slice.ClipRect;
pub const max_clip_rects = render_9slice.max_clip_rects;
pub const SceneRect = render_9slice.SceneRect;
pub const SortParams = render_9slice.SortParams;
pub const sort_passes = render_9slice.sort_passes;
pub const sort_dispatches = render_9slice.sort_dispatches;
pub const Batch9Slice = render_9slice.Batch9Slice;

pub const Curve = sweeper.Curve;
pub const StrokeEdge = sweeper.StrokeEdge;
pub const GlyphMaterial = sweeper.GlyphMaterial;
pub const material_size = sweeper.material_size;
pub const type_solid = sweeper.type_solid;
pub const type_glyph = sweeper.type_glyph;
pub const type_rounded_rect = sweeper.type_rounded_rect;
pub const type_shadow = sweeper.type_shadow;
pub const type_stroke = sweeper.type_stroke;
pub const type_sweep = sweeper.type_sweep;
pub const glyphExtent = sweeper.glyphExtent;
pub const GlyphSweeper = sweeper.GlyphSweeper;
pub const FillBands = sweeper.FillBands;
pub const buildFillBands = sweeper.buildFillBands;
pub const StrokeBands = sweeper.StrokeBands;
pub const buildStrokeBands = sweeper.buildStrokeBands;
