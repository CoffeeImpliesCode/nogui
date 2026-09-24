//! Canonical v7 renderer module.

pub const sweeper = @import("sweeper.zig");
const facade = @import("renderer.zig");

pub const Renderer = facade.Renderer;
pub const Scene = facade.Scene;
pub const Options = facade.Options;

pub const ClipRect = facade.ClipRect;
pub const max_clip_rects = facade.max_clip_rects;
pub const SceneRect = facade.SceneRect;

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
