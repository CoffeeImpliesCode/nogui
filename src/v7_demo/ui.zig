//! v7 demo UI — one interactive TodoApp component with several parts.
//!
//! Demo-side code imports the canonical `nogui` module.
//! Demo state lives in struct fields; every frame re-draws everything (no
//! dirty tracking). The frame tick comes from DrawCtx.frame_info. Widgets
//! have semantic labels for input injection; scan by kind, never by position
//! (node order is post-order, ids are not array indices).

const std = @import("std");
const noapi = @import("noapi");

const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const Style = nogui.Style;
const PaintStyle = nogui.PaintStyle;
const ComponentKey = nogui.ComponentKey;
const debug_mod = @import("debug_state.zig");
const WidgetTree = nogui.WidgetTree;
const WidgetNode = nogui.WidgetNode;
const App = nogui.App;
const FrameNodeId = nogui.FrameNodeId;
const Event = nogui.Event;
const MandelbrotComponent = @import("mandelbrot_component.zig").MandelbrotComponent;

/// The demo texture's bindless heap index, set by the window backend after
/// it creates + registers the procedural texture (the demo UI cannot touch
/// the GPU). Null = not registered (headless/sim runs) — the textured card
/// then renders as a plain fill. Same driver→UI channel as debug_mod.
pub var texture_idx: ?u32 = null;

/// The SVG showcase box's node id: the window rasterizes its document
/// through librsvg for this box's device-pixel size and samples the result
/// over the box each frame.
pub var svg_box_id: ?u32 = null;

/// The showcase raster the window produced this frame: viewport width and
/// height in device pixels, plus the display scale it was rasterized for.
/// {0, 0} until the first raster lands (headless/sim runs never get one).
pub var svg_raster: [2]u32 = .{ 0, 0 };
pub var svg_raster_scale: f32 = 1;
/// Tier-2 frame pacing toggle: the FIFO swapchain + the slop-driven sleep
/// before the input poll. OFF by default — the pacing's cadence must be
/// verified on a quiet machine (the double-framing regression under load
/// is why it's off). Flip to true once the measurements are trustworthy.
pub var frame_pacing: bool = false;
/// The tiger reference render's bindless heap index (the window uploads
/// the pinned rsvg-rendered tiger as a texture; the tiger showcase samples
/// it beside the live host rasterizer output for comparison).
pub var tiger_ref_idx: ?u32 = null;
/// Enables the bounded GPU lifecycle smoke path. The window driver sets this
/// only for `--gpu-remount-smoke`; normal windowed and headless paths leave it
/// false, so Mandelbrot remains mounted as usual.
pub var gpu_remount_smoke: bool = false;

/// Opt-in native custom-element smoke; normal Todo layout stays unchanged.
pub var custom_ruler_smoke: bool = false;
/// Opt-in W13 noapi pixel specimen; normal Todo frames remain unchanged.
pub var custom_paint_smoke: bool = false;

/// Frames per second (a rolling average), set by the window driver each frame.
pub var fps: f32 = 0;

/// A pill-click toggle request, applied by the window driver before the
/// next frame (the window owns the batch state the pills mirror; the UI
/// cannot reach the batch, so the click sets a request the window honors).
/// The showcase boxes' declared edge in logical window units. The window
/// reports the raster it rasterized from this size before the first
/// measured one exists, so the stroke scene's panel is right on the very
/// first frame.
pub const tiger_scene_box_size: f32 = 480;
pub const stroke_scene_box_size: f32 = 620;

/// The tiger showcase root: the minimal UI (title + the two large
/// cards). The window rasterizes tiger.svg for the reserved box named by
/// svg_box_id and samples the pinned reference through tiger_ref_idx.
pub const TigerApp = struct {
    pub fn draw(self: *TigerApp, ctx: *DrawCtx) !void {
        _ = self;
        _ = try ctx.column(.{ .gap = 12, .grow = 1, .padding = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 } });
        defer ctx.pop();

        {
            _ = try ctx.column(.{ .gap = 6 });
            defer ctx.pop();
            _ = try labelColorSized(
                ctx,
                "TIGER SHOWCASE — HOST RASTERIZER VS PINNED REFERENCE",
                c_text,
                18,
                .{ .static = "tiger-title" },
            );
            _ = try caption(
                ctx,
                "Left: tiger.svg rasterized live by librsvg/Cairo   |   Right: the pinned rsvg render",
                0,
                .{ .static = "tiger-header-caption" },
            );
        }

        {
            _ = try ctx.row(.{ .gap = 16 });
            defer ctx.pop();
            {
                _ = try card(false, ctx, false);
                defer ctx.pop();
                _ = try caption(ctx, "HOST — LIVE LIBRSVG", 0, .{ .static = "tiger-gpu-caption" });
                {
                    _ = try ctx.row(.{});
                    defer ctx.pop();
                    svg_box_id = @backingInt(try ctx.column(.{
                        .flex_basis = tiger_scene_box_size,
                        .box_sizing = .border_box,
                        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                        .border_color = c_border,
                        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                    }));
                    defer ctx.pop();
                    _ = try ctx.spacer(.{ .size = tiger_scene_box_size });
                }
            }
            {
                _ = try card(false, ctx, false);
                defer ctx.pop();
                _ = try caption(ctx, "REFERENCE — PINNED RSVG", 0, .{ .static = "tiger-reference-caption" });
                {
                    _ = try ctx.row(.{});
                    defer ctx.pop();
                    const reference: nogui.image_view.Source = if (tiger_ref_idx) |index|
                        .{ .ready = .{ .index = index, .generation = 1 } }
                    else
                        .pending;
                    _ = try ctx.elementLeaf(nogui.image_view.ImageView, .{
                        .intrinsic = .{ .width = 512, .height = 512 },
                        .source = reference,
                        .generation = 1,
                        .fit = .contain,
                        .label = "Pinned SVG tiger reference",
                    }, .{
                        .key = @as(ComponentKey, .{ .static = "tiger-reference-image" }),
                        .width = tiger_scene_box_size,
                        .height = tiger_scene_box_size,
                        .box_sizing = .border_box,
                        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                        .border_color = c_border,
                        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                        .clip = true,
                    });
                    _ = try ctx.spacer(.{ .size = tiger_scene_box_size });
                }
            }
        }
    }
};

/// The stroke scene's document viewBox in user units, reported by the
/// scene's panel. The window rasterizes the very same document string.
pub const stroke_scene_viewbox: [2]f32 = .{ 420, 620 };

/// The stroke test scene: curved thin strokes at increasing widths,
/// rasterized by librsvg through the host's SVG adapter. The window
/// re-rasterizes the document whenever the box's device-pixel size or the
/// display scale changes; the panel reports the raster it produced.
pub const TestStrokesApp = struct {
    pub fn draw(self: *TestStrokesApp, ctx: *DrawCtx) !void {
        _ = self;
        _ = try ctx.column(.{ .gap = 12, .grow = 1, .padding = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 } });
        defer ctx.pop();

        {
            _ = try ctx.column(.{ .gap = 6 });
            defer ctx.pop();
            _ = try labelColorSized(ctx, "STROKE TEST SCENE", c_text, 18, .{ .static = "strokes-title" });
            _ = try caption(
                ctx,
                "Curved thin strokes at widths 0.1 - 4.0   |   rasterized by librsvg/Cairo",
                0,
                .{ .static = "strokes-header-caption" },
            );
        }

        {
            // The scene (left) + the controls (right).
            _ = try ctx.row(.{ .gap = 16 });
            defer ctx.pop();
            {
                _ = try card(false, ctx, false);
                defer ctx.pop();
                _ = try caption(ctx, "STROKES", 0, .{ .static = "strokes-scene-caption" });
                {
                    _ = try ctx.row(.{});
                    defer ctx.pop();
                    svg_box_id = @backingInt(try ctx.column(.{
                        .flex_basis = stroke_scene_box_size,
                        .box_sizing = .border_box,
                        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                        .border_color = c_border,
                        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                    }));
                    defer ctx.pop();
                    _ = try ctx.spacer(.{ .size = stroke_scene_box_size });
                }
            }
            {
                _ = try card(false, ctx, false);
                defer ctx.pop();
                _ = try caption(ctx, "RASTER", 0, .{ .static = "strokes-controls-caption" });
                const viewport_text = try std.fmt.allocPrint(
                    ctx.arena,
                    "viewport  {d} x {d} px",
                    .{ svg_raster[0], svg_raster[1] },
                );
                _ = try labelColor(ctx, viewport_text, c_accent, .{ .static = "strokes-raster-viewport" });
                const scale_text = try std.fmt.allocPrint(
                    ctx.arena,
                    "scale     {d:.2}x",
                    .{svg_raster_scale},
                );
                _ = try labelColor(ctx, scale_text, c_text_sec, .{ .static = "strokes-raster-scale" });
                const viewbox_text = try std.fmt.allocPrint(
                    ctx.arena,
                    "viewBox   {d:.0} x {d:.0}",
                    .{ stroke_scene_viewbox[0], stroke_scene_viewbox[1] },
                );
                _ = try labelColor(ctx, viewbox_text, c_text_sec, .{ .static = "strokes-raster-viewbox" });
                _ = try labelColor(
                    ctx,
                    "engine    librsvg + Cairo",
                    c_text_sec,
                    .{ .static = "strokes-raster-engine" },
                );
            }
        }
    }
};

pub const ToggleKind = enum { subpixel, bgr, damp, debug };
pub var toggle_request: ?ToggleKind = null;

/// The card elevation the retired numeric `shadow` field expressed: a
/// soft, downward black blur. Typed so the paint pass can composite it.
const card_shadow = [_]nogui.paint.Shadow{.{
    .color = .{ .srgb = .{ .r = 0, .g = 0, .b = 0, .a = 0.35 } },
    .offset = .{ .x = 0, .y = 2 },
    .blur = 4,
}};

/// ── Modern dark palette (sRGB-authored; the pipeline converts to Oklab) ──
/// Surfaces: canvas → card → raised. One violet-indigo accent owns the
/// interactive bits (primary buttons, slider, numerals, active pills).
// raised chip surface (buttons/pills — LIGHTER than the card so they read
// as controls, not shadows)
const c_card_deep: [4]f32 = .{ 0.16, 0.17, 0.22, 1 };
const c_border: [4]f32 = .{ 0.24, 0.25, 0.33, 0.55 }; // soft card border
const c_border_strong: [4]f32 = .{ 0.34, 0.35, 0.46, 0.75 };
const c_text: [4]f32 = .{ 0.87, 0.87, 0.92, 1 }; // primary text
const c_text_sec: [4]f32 = .{ 0.60, 0.61, 0.70, 1 }; // secondary text
const c_text_muted: [4]f32 = .{ 0.46, 0.47, 0.56, 1 }; // captions/stats
// violet-indigo (dark enough to match the neutral buttons' visual weight)
const c_accent: [4]f32 = .{ 0.40, 0.34, 0.78, 1 };
const c_accent_dim: [4]f32 = .{ 0.24, 0.21, 0.47, 1 }; // accent-tinted surface
const c_on_accent: [4]f32 = .{ 0.95, 0.94, 1, 1 }; // text on the accent
fn solidFill(c: [4]f32) nogui.paint.Fill {
    return .{ .solid = .{ .srgb = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] } } };
}

/// A non-interactive label scope. Its defaults replace any surrounding
/// component defaults, so labels keep their original column/box behavior
/// when they are drawn inside a row, card, or other styled component.
const PaddedLabel = struct {
    const Self = PaddedLabel;

    text: []const u8,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    font_size: f32 = 0,
    layer: u32 = 0,
    label_id: FrameNodeId = .root,

    pub const default_style: Style = .{
        .direction = .column,
        .gap = .{ .length = 0 },
        .justify = .start,
        .@"align" = .stretch,
        .padding_inset = .{
            .top = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 6 },
            .right = .{ .length = 6 },
        },
    };

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        self.label_id = try ctx.label(.{
            .text = self.text,
            .color = self.color,
            .font_size = self.font_size,
            .layer = self.layer,
        });
    }
};

/// Showcase labels use a separate scope because their surrounding row has
/// intentional spacing and alignment defaults that must not leak into leaves.
const ShowcaseLabel = struct {
    const Self = ShowcaseLabel;

    text: []const u8,
    variant: Variant,
    label_id: FrameNodeId = .root,

    const Variant = enum { pad, ring, margin };

    pub const default_style: Style = .{
        .direction = .column,
        .gap = .{ .length = 0 },
        .justify = .start,
        .@"align" = .stretch,
        .padding_inset = .{
            .top = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 6 },
            .right = .{ .length = 6 },
        },
    };

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        self.label_id = switch (self.variant) {
            .pad => try ctx.label(.{
                .text = self.text,
                .padding = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
            }),
            .ring => try ctx.label(.{
                .text = self.text,
                .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                .border = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 },
                .border_color = .{ 0.8, 0.5, 0.3, 1 },
                .radius = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
            }),
            .margin => try ctx.label(.{
                .text = self.text,
                .margin = .{ .left = 10 },
                .padding = .{ .top = 10, .right = 10, .bottom = 10, .left = 10 },
            }),
        };
    }
};

/// Shared card layout and paint. The card helper applies these values to
/// the container it creates, so buttons inside the card retain TodoApp's
/// component identity and event ownership.
const Card = struct {
    pub const default_style: Style = .{
        .direction = .column,
        .gap = .{ .length = 8 },
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 1 },
            .left = .{ .length = 1 },
        },
        .padding_inset = .{
            .top = .{ .length = 12 },
            .right = .{ .length = 12 },
            .bottom = .{ .length = 12 },
            .left = .{ .length = 12 },
        },
    };
    pub const default_paint: PaintStyle = .{
        .border_color = c_border,
        .radius = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
        .shadows = &card_shadow,
    };
};

const GhostButton = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = .{ .length = 0 },
        .justify = .center,
        .@"align" = .center,
        .padding_inset = .{
            .left = .{ .length = 12 },
            .right = .{ .length = 12 },
            .top = .{ .length = 5 },
            .bottom = .{ .length = 5 },
        },
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 1 },
            .left = .{ .length = 1 },
        },
    };
    pub const default_paint: PaintStyle = .{
        .border_color = c_border_strong,
        .radius = .{ .top = 7, .right = 7, .bottom = 7, .left = 7 },
        .fill = c_card_deep,
        .paint_fill = solidFill(c_card_deep),
    };
};

const PrimaryButton = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = .{ .length = 0 },
        .justify = .center,
        .@"align" = .center,
        .padding_inset = .{
            .left = .{ .length = 12 },
            .right = .{ .length = 12 },
            .top = .{ .length = 5 },
            .bottom = .{ .length = 5 },
        },
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 1 },
            .left = .{ .length = 1 },
        },
    };
    pub const default_paint: PaintStyle = .{
        .border_color = c_accent,
        .radius = .{ .top = 7, .right = 7, .bottom = 7, .left = 7 },
        .fill = c_accent,
        .paint_fill = solidFill(c_accent),
    };
};

const ActivePill = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = .{ .length = 0 },
        .justify = .center,
        .@"align" = .center,
        .padding_inset = .{
            .top = .{ .length = 3 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 3 },
            .left = .{ .length = 10 },
        },
    };
    pub const default_paint: PaintStyle = .{
        .radius = .{ .top = 9, .right = 9, .bottom = 9, .left = 9 },
        .fill = c_accent_dim,
        .paint_fill = solidFill(c_accent_dim),
    };
};

const InactivePill = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = .{ .length = 0 },
        .justify = .center,
        .@"align" = .center,
        .padding_inset = .{
            .top = .{ .length = 3 },
            .right = .{ .length = 10 },
            .bottom = .{ .length = 3 },
            .left = .{ .length = 10 },
        },
        .border_inset = .{
            .top = .{ .length = 1 },
            .right = .{ .length = 1 },
            .bottom = .{ .length = 1 },
            .left = .{ .length = 1 },
        },
    };
    pub const default_paint: PaintStyle = .{
        .border_color = c_border,
        .radius = .{ .top = 9, .right = 9, .bottom = 9, .left = 9 },
        .fill = c_card_deep,
        .paint_fill = solidFill(c_card_deep),
    };
};

fn scopedLabel(
    ctx: *DrawCtx,
    text: []const u8,
    key: ComponentKey,
    color: [4]f32,
    font_size: f32,
    layer: u32,
) !FrameNodeId {
    var component: PaddedLabel = .{
        .text = text,
        .color = color,
        .font_size = font_size,
        .layer = layer,
    };
    try ctx.component(PaddedLabel, .{ .key = key }, &component);
    return component.label_id;
}

fn labelSized(
    ctx: *DrawCtx,
    text: []const u8,
    font_size: f32,
    key: ComponentKey,
) !FrameNodeId {
    return scopedLabel(ctx, text, key, .{ 1, 1, 1, 1 }, font_size, 0);
}

fn labelColorSized(
    ctx: *DrawCtx,
    text: []const u8,
    color: [4]f32,
    font_size: f32,
    key: ComponentKey,
) !FrameNodeId {
    return scopedLabel(ctx, text, key, color, font_size, 0);
}

/// A colored label (text color, not the box).
fn labelColor(
    ctx: *DrawCtx,
    text: []const u8,
    color: [4]f32,
    key: ComponentKey,
) !FrameNodeId {
    return scopedLabel(ctx, text, key, color, 0, 0);
}

/// A muted caption (section headers, stat lines). `layer` (default 0)
/// stamps the caption's own layer key — a caption inside a layered
/// container must ride that layer or its glyphs sort below the container's
/// z>0 fill and vanish behind it.
fn caption(ctx: *DrawCtx, text: []const u8, layer: u32, key: ComponentKey) !FrameNodeId {
    return scopedLabel(ctx, text, key, c_text_muted, 11, layer);
}

/// Apply the shared card defaults to one container without introducing a
/// component boundary around its interactive children.
fn card(comptime grow: bool, ctx: *DrawCtx, clip: bool) !FrameNodeId {
    const style = Card.default_style;
    const paint = Card.default_paint;
    return ctx.column(.{
        .direction = style.direction,
        .gap = style.gap,
        .grow = if (grow) 1 else 0,
        .clip = clip,
        .border = style.border_inset,
        .border_color = paint.border_color,
        .radius = paint.radius,
        .padding = style.padding_inset,
        .shadows = paint.shadows,
    });
}

/// Secondary (ghost) button: a flat card-deep fill + a soft border (the
/// fill = the box's flat color, the gradient = the same → no two-tone).
/// The text inherits the node's color (default near-white).
fn btn(ctx: *DrawCtx, key: ComponentKey, text: []const u8, on_click: anytype) !FrameNodeId {
    const style = GhostButton.default_style;
    const paint = GhostButton.default_paint;
    return ctx.button(.{
        .key = key,
        .label = text,
        .on_click = on_click,
        .color = c_text,
        .direction = style.direction,
        .gap = style.gap,
        .justify = style.justify,
        .@"align" = style.@"align",
        .padding = style.padding_inset,
        .border = style.border_inset,
        .border_color = paint.border_color,
        .radius = paint.radius,
        .fill = paint.fill,
        .paint_fill = paint.paint_fill,
    });
}

/// Primary button: a flat accent fill + the light text (the demo's "go"
/// verbs: inc, add). Same padding as the ghost button — and a 1px border
/// in the accent color, so its fill insets exactly like the ghost's (the
/// ghost's border insets its fill; a borderless accent fill reads 2px
/// taller than its siblings).
fn btnPrimary(
    ctx: *DrawCtx,
    key: ComponentKey,
    text: []const u8,
    on_click: anytype,
) !FrameNodeId {
    const style = PrimaryButton.default_style;
    const paint = PrimaryButton.default_paint;
    return ctx.button(.{
        .key = key,
        .label = text,
        .on_click = on_click,
        .color = c_on_accent,
        .direction = style.direction,
        .gap = style.gap,
        .justify = style.justify,
        .@"align" = style.@"align",
        .padding = style.padding_inset,
        .border = style.border_inset,
        .border_color = paint.border_color,
        .radius = paint.radius,
        .fill = paint.fill,
        .paint_fill = paint.paint_fill,
    });
}

/// Toggle pills use the same scoped defaults as the original on/off
/// variants; only their semantic state and text color remain local.
fn pill(
    ctx: *DrawCtx,
    key: ComponentKey,
    text: []const u8,
    on: bool,
    on_click: anytype,
) !FrameNodeId {
    if (on) {
        const style = ActivePill.default_style;
        const paint = ActivePill.default_paint;
        return ctx.button(.{
            .key = key,
            .label = text,
            .on_click = on_click,
            .color = c_accent,
            .direction = style.direction,
            .gap = style.gap,
            .justify = style.justify,
            .@"align" = style.@"align",
            .padding = style.padding_inset,
            .radius = paint.radius,
            .fill = paint.fill,
            .paint_fill = paint.paint_fill,
        });
    }
    const style = InactivePill.default_style;
    const paint = InactivePill.default_paint;
    return ctx.button(.{
        .key = key,
        .label = text,
        .on_click = on_click,
        .color = c_text_muted,
        .direction = style.direction,
        .gap = style.gap,
        .justify = style.justify,
        .@"align" = style.@"align",
        .padding = style.padding_inset,
        .border = style.border_inset,
        .border_color = paint.border_color,
        .radius = paint.radius,
        .fill = paint.fill,
        .paint_fill = paint.paint_fill,
    });
}

/// Inline sub-component for the volume block: slider + mute button + value
/// label. Nested into the TodoApp tree via ctx.component, so its buttons
/// bind to their own component id.
const VolumeSlider = struct {
    const Self = VolumeSlider;

    volume: f32 = 0.5,

    pub const default_style: Style = .{
        .direction = .column,
        .gap = .{ .length = 8 },
    };

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        const text = try std.fmt.allocPrint(ctx.arena, "Volume: {d:.1}", .{self.volume});
        _ = try card(true, ctx, false);
        defer ctx.pop();
        _ = try caption(ctx, "VOLUME", 0, .{ .static = "volume-caption" });
        _ = try ctx.slider(.{
            .key = .{ .static = "volume-level" },
            .label = "volume-slider",
            .value = &self.volume,
            .min = 0,
            .max = 1,
            .color = c_accent,
            .padding = .{ .left = 6, .right = 10 },
        });
        {
            _ = try ctx.row(.{ .direction = .row, .@"align" = .center });
            defer ctx.pop();
            _ = try btn(ctx, .{ .static = "volume-mute" }, "mute", VolumeSlider.mute);
            _ = try labelColor(ctx, text, c_text_sec, .{ .static = "volume-value" });
        }
    }

    pub fn mute(self: *Self) void {
        self.volume = 0;
    }
};
fn showcaseLabel(
    ctx: *DrawCtx,
    text: []const u8,
    variant: ShowcaseLabel.Variant,
    key: ComponentKey,
) !FrameNodeId {
    var component: ShowcaseLabel = .{ .text = text, .variant = variant };
    try ctx.component(ShowcaseLabel, .{ .key = key }, &component);
    return component.label_id;
}

/// Box-model showcase: a row exercising justify (space_between), align
/// (center), margins, padding-only boxes, and a rounded border ring on a
/// plain label.
const Showcase = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = .{ .length = 10 },
        .justify = .space_between,
        .@"align" = .center,
        .padding_inset = .{
            .top = .{ .length = 0 },
            .bottom = .{ .length = 0 },
            .left = .{ .length = 12 },
            .right = .{ .length = 12 },
        },
    };

    pub fn draw(self: *Showcase, ctx: *DrawCtx) !void {
        _ = self;
        // Root-level row: spans the window, so it needs its OWN side
        // padding (the root column's padding does not apply here) and
        // justify has main-axis free space to spread the children.
        _ = try ctx.row(.{});
        defer ctx.pop();
        // All three boxes share the same vertical padding (44px tall), so
        // the text baselines line up despite the box-model differences.
        // Padding-only: the text sits 10px inside the invisible box.
        _ = try showcaseLabel(ctx, "pad", .pad, .{ .static = "showcase-pad" });
        // Ring: 2px rounded border around the text (no fill); border 2 +
        // padding 8 = the same 10px content inset as "pad".
        _ = try showcaseLabel(ctx, "ring", .ring, .{ .static = "showcase-ring" });
        // Margin: pushed 10px right of its spread slot (horizontal only —
        // a vertical offset reads as misalignment).
        _ = try showcaseLabel(ctx, "margin", .margin, .{ .static = "showcase-margin" });
    }
};

const CustomRuler = struct {
    pub const PhaseState = struct {};

    pub fn measure(_: *const CustomRuler, input: nogui.element.MeasureInput) nogui.element.Error!nogui.Size {
        return .{
            .width = input.known_dimensions.width orelse 240,
            .height = input.known_dimensions.height orelse 18,
        };
    }

    pub fn paint(
        _: *const CustomRuler,
        _: *PhaseState,
        geometry: nogui.element.Geometry,
        writer: *nogui.element.PaintWriter,
    ) nogui.element.Error!void {
        try writer.rect(.{
            .x = 0,
            .y = 0,
            .w = geometry.content.w,
            .h = 1,
        }, .{ 0.8, 0.3, 0.1, 1 });
        var x: f32 = 0;
        while (x < geometry.content.w) : (x += 10) {
            try writer.rect(.{
                .x = x,
                .y = 1,
                .w = 1,
                .h = 5,
            }, .{ 0.8, 0.3, 0.1, 1 });
        }
    }

    pub fn semantics(
        _: *const CustomRuler,
        _: *PhaseState,
        _: nogui.element.Geometry,
    ) nogui.element.Error!?nogui.element.Semantic {
        return .{ .role = .image, .label = "measurement ruler" };
    }
};

const PaintSpecimen = struct {
    pub const PhaseState = struct {};
    pub fn measure(_: *const PaintSpecimen, input: nogui.element.MeasureInput) nogui.element.Error!nogui.Size {
        return .{
            .width = input.known_dimensions.width orelse 240,
            .height = input.known_dimensions.height orelse 72,
        };
    }

    pub fn paint(
        _: *const PaintSpecimen,
        _: *PhaseState,
        geometry: nogui.element.Geometry,
        writer: *nogui.element.PaintWriter,
    ) nogui.element.Error!void {
        const red: nogui.paint.Color = .{ .srgb = .{ .r = 1, .g = 0, .b = 0 } };
        const blue: nogui.paint.Color = .{ .srgb = .{ .r = 0, .g = 0, .b = 1 } };
        const green: nogui.paint.Color = .{ .srgb = .{ .r = 0, .g = 1, .b = 0 } };
        try writer.addRect(.{
            .bounds = .{ .x = 0, .y = 0, .w = geometry.content.w, .h = geometry.content.h },
            .fill = .{ .gradient = .{
                .first = .{ .color = red, .position = 0 },
                .second = .{ .color = blue, .position = 1 },
                .angle = 0,
            } },
            .radii = .{ 4, 12, 8, 2 },
            .borders = .{ .{ .width = 2, .color = green }, .{}, .{}, .{} },
        });
        try writer.addRect(.{
            .bounds = .{ .x = 96, .y = 8, .w = 48, .h = 48 },
            .fill = .{ .pattern = .{
                .first = red,
                .second = blue,
                .cell = .{ .x = 8, .y = 8 },
            } },
            .shadows = &.{.{
                .color = blue,
                .offset = .{ .x = 4, .y = 2 },
                .blur = 3,
            }},
        });
        const commands = [_]nogui.path.Command{
            .{ .move = .{ .x = 0, .y = 0 } },
            .{ .line = .{ .x = 40, .y = 0 } },
            .{ .line = .{ .x = 20, .y = 40 } },
            .{ .close = {} },
        };
        try writer.addPath(.{
            .bounds = .{ .x = 12, .y = 12, .w = 40, .h = 40 },
            .path = .{ .commands = &commands },
            .fill = .{ .solid = green },
            .stroke = .{ .color = blue, .width = 2, .dash = &.{ 4, 3 } },
        });
    }
};

/// The demo root component: title row, counter block, volume block, todo
/// list block and a done-count footer, stacked in a root column (gap 12,
/// blocks use gap 6).
pub const TodoApp = struct {
    // --- state (mutated by the demo loop and the interaction methods) ---
    counter: u32 = 0, // 0..99
    volume: VolumeSlider = .{},
    showcase: Showcase = .{},
    mandelbrot: MandelbrotComponent = .{},
    /// The window driver toggles this only during the opt-in GPU remount
    /// smoke path. It remains true for normal demo frames.
    mandelbrot_visible: bool = true,

    done: [4]bool = .{ false, false, false, false },
    /// Each value is an index into items/done and stays fixed as rows move.
    item_order: [4]u8 = .{ 0, 1, 2, 3 },
    visible_count: u8 = 2, // how many of the 4 pool items are shown (1..4)
    demo_switch: bool = false,
    demo_radio_choice: ?u32 = 0,

    /// The fixed pool of candidate todo items.
    pub const items = [4][]const u8{ "buy milk", "water plants", "write docs", "exercise" };
    pub const default_style: Style = .{
        .direction = .column,
        .gap = .{ .length = 12 },
    };

    pub fn draw(self: *TodoApp, ctx: *DrawCtx) !void {
        const frame_text = try std.fmt.allocPrint(
            ctx.arena,
            "Frame: {d}   FPS: {d:.0}",
            .{ ctx.frame_info.?.tick, fps },
        );
        const counter_text = try std.fmt.allocPrint(ctx.arena, "Counter: {d}", .{self.counter});

        var done_count: u32 = 0;
        for (self.item_order[0..self.visible_count]) |item_index| {
            if (self.done[item_index]) done_count += 1;
        }
        const footer_text = try std.fmt.allocPrint(ctx.arena, "{d} of {d} done", .{ done_count, self.visible_count });
        const badge_style = Card.default_style;
        const badge_paint = Card.default_paint;

        // V1c — the layer demo: a "layer 1" badge submitted with z = 1 at
        // the BAG'S FRONT (the tree's FIRST node — its cmds emit before
        // the Showcase row and the root column, so it lands at the very
        // front of the unordered bag). The CS1 sort lifts it above every
        // z=0 drawable regardless of the bag position, so the badge paints
        // over the title/header below it (the layout overlap is real: the
        // badge's rect covers the showcase's pad label and the header's
        // title). Layout sleight: flex basis 44 pins the badge's height and the
        // negative bottom margin cancels it exactly (the next root node
        // advances by zero), so the tree below lays out byte-identically
        // to the pre-layer shot and ONLY the badge region differs.
        _ = try ctx.column(.{
            .gap = 0,
            .layer = 1,
            .flex_basis = 44,
            .box_sizing = .border_box,
            // shrink 0: the demo tree overflows the 1160px surface, so the
            // overflow shrink pass would otherwise crush the 44px flex basis and
            // break the -44 bottom-margin cancellation below.
            .shrink = 0,
            .margin = .{ .left = 20, .bottom = -44, .right = 880 }, // 200px chip, top-left of the 1100px surface
            .border = badge_style.border_inset,
            .border_color = badge_paint.border_color,
            .radius = badge_paint.radius,
            .padding = badge_style.padding_inset,
            .fill = c_accent_dim,
            .paint_fill = solidFill(c_accent_dim),
            .shadows = badge_paint.shadows,
        });
        _ = try caption(ctx, "LAYER 1", 1, .{ .static = "todo-layer-caption" });
        // The badge — explicit, NOT deferred (a deferred pop fires at the end
        // of draw() and collects every following block into the badge).
        ctx.pop();

        // Box-model showcase FIRST, at ROOT level: a root-level row spans
        // the full window width, so justify = space_between has main-axis
        // free space to distribute (a nested row would hug its content).
        try ctx.component(Showcase, .{ .key = .{ .static = "showcase" } }, &self.showcase);

        // Root column: every block stacked with a 16px gap; the root's own
        // padding insets the whole UI from the window edges.
        _ = try ctx.column(.{ .gap = 12, .grow = 1, .padding = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 } });
        defer ctx.pop();

        {
            // App header: the title, the live stat line, and the toggle
            // state as accent pills.
            _ = try ctx.column(.{ .gap = 6 });
            defer ctx.pop();
            _ = try labelSized(ctx, "nogui v7 demo", 20, .{ .static = "todo-title" });
            _ = try labelColor(ctx, frame_text, c_text_sec, .{ .static = "todo-frame" });
            {
                _ = try ctx.row(.{ .direction = .row, .gap = 6 });
                defer ctx.pop();
                const st = debug_mod.debug_state;
                _ = try pill(
                    ctx,
                    .{ .static = "toggle-bgr" },
                    if (st.bgr) "BGR" else "RGB",
                    st.bgr,
                    TodoApp.toggleBgr,
                );
                _ = try pill(ctx, .{ .static = "toggle-damp" }, "damp", st.damp, TodoApp.toggleDamp);
                _ = try pill(ctx, .{ .static = "toggle-debug" }, "debug", st.quad_debug, TodoApp.toggleDebug);
            }
        }

        if (custom_ruler_smoke) {
            _ = try ctx.elementLeaf(CustomRuler, .{}, .{});
        }
        if (custom_paint_smoke) {
            _ = try ctx.elementLeaf(PaintSpecimen, .{}, .{ .width = 240, .height = 72 });
        }

        {
            // Font-sizes showcase: labels at 13/16/20/24/32 px. Each label's
            // authored size resolves into its own text request, so the host
            // measures and paints that size; S toggles the subpixel AA for
            // comparison at every size.
            _ = try card(false, ctx, false);
            defer ctx.pop();
            _ = try caption(ctx, "FONT SIZES — S TOGGLES SUBPIXEL AA", 0, .{ .static = "todo-font-caption" });
            _ = try labelSized(
                ctx,
                "13px: The quick brown fox jumps over the lazy dog",
                13,
                .{ .static = "todo-font-13" },
            );
            _ = try labelSized(
                ctx,
                "16px: The quick brown fox jumps over the lazy dog",
                16,
                .{ .static = "todo-font-16" },
            );
            _ = try labelSized(
                ctx,
                "24px: The quick brown fox jumps over the lazy dog",
                24,
                .{ .static = "todo-font-24" },
            );
        }

        // Counter + volume side by side in a horizontal flex box. The row's
        // pop MUST be explicit (not deferred) — a deferred pop fires at the
        // end of the whole draw and collects every following block into the
        // row. The two cards' own pops are deferred; the row pops here.
        _ = try ctx.row(.{ .direction = .row, .gap = 12 });
        {
            // Counter block: a card holding the value as a big accent
            // numeral + dec/reset/inc row (inc = the primary action).
            _ = try card(true, ctx, false);
            defer ctx.pop();
            _ = try caption(ctx, "COUNTER", 0, .{ .static = "todo-counter-caption" });
            _ = try labelColorSized(ctx, counter_text, c_accent, 28, .{ .static = "todo-counter-value" });
            {
                _ = try ctx.row(.{ .direction = .row, .gap = 6 });
                defer ctx.pop();
                _ = try btn(ctx, .{ .static = "counter-dec" }, "dec", TodoApp.dec);
                _ = try btn(ctx, .{ .static = "counter-reset" }, "reset", TodoApp.reset);
                _ = try btnPrimary(ctx, .{ .static = "counter-inc" }, "inc", TodoApp.inc);
            }
        }

        // Volume block: nested sub-component (its own card + slider), beside
        // the counter in the same row.
        try ctx.component(VolumeSlider, .{ .key = .{ .static = "volume" } }, &self.volume);
        ctx.pop(); // the horizontal row — explicit, NOT deferred

        // Spacer: reserves 8px of empty main-axis space (paints nothing).
        _ = try ctx.spacer(.{ .size = 8 });

        {
            // Todo block: the done-count header, add/remove buttons, and
            // one bound checkbox row per visible item.
            _ = try card(false, ctx, false);
            defer ctx.pop();
            {
                _ = try ctx.row(.{ .direction = .row, .gap = 8, .@"align" = .center });
                defer ctx.pop();
                _ = try caption(ctx, "TODOS", 0, .{ .static = "todo-list-caption" });
                _ = try labelColor(ctx, footer_text, c_text_muted, .{ .static = "todo-list-footer" });
            }
            {
                _ = try ctx.row(.{ .direction = .row, .gap = 6 });
                defer ctx.pop();
                _ = try btn(ctx, .{ .static = "todo-remove" }, "remove", TodoApp.remove);
                _ = try btnPrimary(ctx, .{ .static = "todo-add" }, "add", TodoApp.add);
            }
            for (self.item_order[0..self.visible_count]) |item_index| {
                _ = try ctx.checkbox(.{
                    .key = .{ .u64 = item_index },
                    .label = items[item_index],
                    .value = &self.done[item_index],
                    .color = if (self.done[item_index]) c_text_muted else c_accent,
                });
            }
            _ = try ctx.separator(.{ .axis = .horizontal, .color = c_border_strong });
            _ = try caption(ctx, "NATIVE CONTROLS", 0, .{ .static = "todo-controls-caption" });
            {
                _ = try ctx.row(.{ .direction = .row, .gap = 12, .@"align" = .center });
                defer ctx.pop();
                _ = try ctx.switchControl(.{
                    .key = .{ .static = "demo-switch" },
                    .label = "Demo switch",
                    .value = &self.demo_switch,
                    .color = c_accent,
                });
                _ = try ctx.radio(.{
                    .key = .{ .static = "demo-radio-a" },
                    .label = "Choice A",
                    .selected = &self.demo_radio_choice,
                    .option = 0,
                    .color = c_accent,
                });
                _ = try ctx.radio(.{
                    .key = .{ .static = "demo-radio-b" },
                    .label = "Choice B",
                    .selected = &self.demo_radio_choice,
                    .option = 1,
                    .color = c_accent,
                });
            }
            const completion = @as(f32, @floatFromInt(done_count)) /
                @as(f32, @floatFromInt(self.visible_count));
            _ = try ctx.progress(.{
                .key = .{ .static = "demo-progress" },
                .label = "Completion",
                .value = completion,
                .min = 0,
                .max = 1,
                .color = c_accent,
            });
        }

        {
            // The showcase row: the mandelbrot + the tiger side by side
            // (the tiger's card to the RIGHT, same height — never below,
            // where it would overflow the window).
            _ = try ctx.row(.{ .direction = .row, .gap = 12 });
            defer ctx.pop();
            {
                // The component owns its texture, GPU lifecycle, and view
                // interaction. Its stable key keeps GPU state attached to
                // this showcase slot across rebuilt widget trees.
                _ = try card(false, ctx, false);
                defer ctx.pop();
                if (self.mandelbrot_visible) {
                    try ctx.component(
                        MandelbrotComponent,
                        .{ .key = .{ .static = "mandelbrot" } },
                        &self.mandelbrot,
                    );
                }
            }

            {
                // SVG showcase: the tiger (the classic SVG reference) —
                // parsed + converted by the window's SvgView (the path
                // curves + the glyph materials); this box reserves the
                // drawing rect (the window injects the tiger's scene rects
                // at it each frame).
                _ = try card(false, ctx, false);
                defer ctx.pop();
                {
                    _ = try ctx.row(.{ .direction = .row, .gap = 8, .@"align" = .center });
                    defer ctx.pop();
                    _ = try caption(ctx, "TIGER", 0, .{ .static = "todo-tiger-caption" });
                }
                {
                    _ = try ctx.row(.{ .direction = .row });
                    defer ctx.pop();
                    svg_box_id = @backingInt(try ctx.column(.{
                        .flex_basis = 190, // fixed width — the same height as the mandelbrot's box
                        .gap = 0,
                        .box_sizing = .border_box,
                        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                        .border_color = c_border,
                        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                    }));
                    defer ctx.pop();
                    _ = try ctx.spacer(.{ .size = 190 }); // the square content height
                }
            }
        }
    }
    pub fn setGpuDescriptorHeap(self: *TodoApp, heap: noapi.DescriptorHeap) void {
        self.mandelbrot.setDescriptorHeap(heap);
    }

    pub fn onFrame(self: *TodoApp, time_ms: u64) void {
        self.mandelbrot.onFrame(time_ms);
    }

    /// The showcase slot mounts or unmounts the Mandelbrot component. Hiding
    /// it retires its pointer surface at once, so no routed event can reach
    /// a viewport the next frame is about to remove.
    pub fn setMandelbrotVisible(self: *TodoApp, visible: bool) void {
        if (!visible) self.mandelbrot.clearInputTarget();
        self.mandelbrot_visible = visible;
    }

    pub fn onPrecisionKey(self: *TodoApp) void {
        self.mandelbrot.cyclePrecision();
    }

    // Header pill clicks — the window applies the request before the next
    // frame (it owns the batch the pills mirror).
    pub fn toggleSubpixel(self: *TodoApp) void {
        _ = self;
        toggle_request = .subpixel;
    }
    pub fn toggleBgr(self: *TodoApp) void {
        _ = self;
        toggle_request = .bgr;
    }
    pub fn toggleDamp(self: *TodoApp) void {
        _ = self;
        toggle_request = .damp;
    }
    pub fn toggleDebug(self: *TodoApp) void {
        _ = self;
        toggle_request = .debug;
    }

    pub fn inc(self: *TodoApp) void {
        if (self.counter < 99) self.counter += 1;
    }

    pub fn dec(self: *TodoApp) void {
        if (self.counter > 0) self.counter -= 1;
    }

    pub fn reset(self: *TodoApp) void {
        self.counter = 0;
    }

    pub fn mute(self: *TodoApp) void {
        self.volume.mute();
    }

    pub fn add(self: *TodoApp) void {
        if (self.visible_count < 4) self.visible_count += 1;
    }

    pub fn remove(self: *TodoApp) void {
        if (self.visible_count > 1) self.visible_count -= 1;
    }
};

// --- tests -----------------------------------------------------------------

/// Build a WidgetTree with fixed frame metadata and an arena-backed DrawCtx.
/// Keep the arena alive while inspecting the tree; call freeTree() afterward.
/// A new buildTree() releases the prior arena.
var test_arena: ?std.heap.ArenaAllocator = null;

fn buildTree(app: *TodoApp) !WidgetTree {
    freeTree();
    test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer freeTree();
    const arena = if (test_arena) |*a| a else unreachable;
    const alloc = arena.allocator();
    var tree = WidgetTree.init(alloc); // mutable: DrawCtx takes *WidgetTree
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = alloc,
        .frame_info = .{
            .tick = 1,
            .time_ms = 0,
            .generation = 1,
            .surface = .{ .width = 1100, .height = 1160 },
        },
    };
    try app.draw(&ctx);
    return tree;
}

fn freeTree() void {
    if (test_arena) |*a| a.deinit();
    test_arena = null;
}

// The badge's exact-cancellation invariant: flex basis 44 + the -44 bottom
// margin pin the badge to y=0..44 AND advance the next root node by zero,
// so the tree below lays out byte-identically to a shot without the badge
// (the runShot's diff is confined to the badge region).
test "layer badge: first root, layer 1, its height cancels exactly" {
    var app: TodoApp = .{};
    var tree = try buildTree(&app);
    defer freeTree();

    // The badge column is the tree's FIRST root-level node (append order)
    // and carries the layer key; its caption rides the same layer.
    var roots_buf: [64]*WidgetNode = undefined;
    const n_roots = tree.roots(&roots_buf);
    try std.testing.expect(n_roots >= 3);
    const badge_col = roots_buf[0];
    try std.testing.expectEqual(FrameNodeId.root, badge_col.parent);
    try std.testing.expectEqual(@as(u32, 1), badge_col.paint.layer);
    var caption_has_layer = false;
    for (tree.nodes.items) |n| {
        if (n.kind == .label and n.parent == badge_col.id and n.paint.layer == 1) caption_has_layer = true;
    }
    try std.testing.expect(caption_has_layer);

    // Layout: the badge is a 44px (flex basis) x 200px (20 + 880 margins on the
    // 1100px surface) chip at y=0; its -44 bottom margin cancels the
    // advance exactly, so the Showcase row starts at y=0 and the root
    // column follows it directly — no badge-induced offset anywhere.
    const Rect = nogui.Rect;
    const Ruler = struct {
        fn f(
            _: ?*anyopaque,
            _: []const u8,
            _: nogui.layout.MeasureInput,
        ) nogui.layout.LayoutError!nogui.layout.TextMeasurement {
            return .{ .width = 40, .height = 24 };
        }
    };
    try nogui.layout.layoutTree(&tree, .{
        .allocator = std.testing.allocator,
        .available = .{ .width = 1100, .height = 1160 },
        .measure = .{ .callback = Ruler.f },
    });

    try std.testing.expectEqual(Rect{ .x = 20, .y = 0, .w = 200, .h = 44 }, badge_col.rect);
    try std.testing.expectEqual(@as(f32, 0), roots_buf[1].rect.y); // Showcase row, unchanged
    try std.testing.expectEqual(
        roots_buf[1].rect.y + roots_buf[1].rect.h,
        roots_buf[2].rect.y,
    ); // root column, unchanged
}

fn clickAt(app: *App, rect: nogui.Rect) !void {
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;
    _ = try app.handle(.{
        .mouse_down = .{ .button = .left, .x = x, .y = y },
    });
    _ = try app.handle(.{
        .mouse_up = .{ .button = .left, .x = x, .y = y },
    });
}

/// Scan by kind (never by position): node order is post-order and ids are
/// not array positions. Passes if a label node with exactly `text` exists.
fn expectLabel(tree: *const WidgetTree, text: []const u8) !void {
    for (tree.nodes.items) |n| {
        switch (n.kind) {
            .label => |l| {
                if (std.mem.eql(u8, l.text, text)) return;
            },
            else => {},
        }
    }
    return error.LabelNotFound;
}

/// Count the currently visible TodoApp checkbox rows.
fn countTodoCheckboxes(tree: *const WidgetTree) usize {
    var count: usize = 0;
    for (tree.nodes.items) |node| {
        if (node.kind == .checkbox) count += 1;
    }
    return count;
}

/// True when a node authors a fill of its own — the `explicit_fill` test the
/// paint pass applies before it falls back to a kind's default surface
/// (`src/v7/drawcmd.zig:271`).
fn authorsFill(node: *const WidgetNode) bool {
    return node.paint.fill[3] > 0 or
        node.paint.paint_fill != null or node.paint.texture != null;
}

/// Whether `node` sits anywhere under `ancestor`.
fn descendsFrom(tree: *const WidgetTree, node: *const WidgetNode, ancestor: FrameNodeId) bool {
    var cursor = node.parent;
    while (cursor != .root) {
        if (cursor == ancestor) return true;
        const parent = tree.nodeConst(cursor) orelse return false;
        cursor = parent.parent;
    }
    return false;
}

/// Build a tree from one draw callback, so a test can state a paint shape
/// directly instead of reaching it through TodoApp. Same arena lifetime rules
/// as `buildTree`.
fn buildScene(draw: anytype) !WidgetTree {
    freeTree();
    test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer freeTree();
    const alloc = if (test_arena) |*a| a else unreachable;
    const alloc_ctx = alloc.allocator();
    var tree = WidgetTree.init(alloc_ctx);
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = alloc_ctx,
        .frame_info = .{
            .tick = 1,
            .time_ms = 0,
            .generation = 1,
            .surface = .{ .width = 1100, .height = 1160 },
        },
    };
    try draw(&ctx);
    return tree;
}

/// The first filled container in `tree` that has an unfilled row/column
/// child, or null when the scene has no patchwork. Null is the assertion the
/// Todo scene passes; the control below shows the finder reports a real one.
fn findPatchwork(tree: *const WidgetTree) ?FrameNodeId {
    for (tree.nodes.items) |node| {
        if (node.kind != .column and node.kind != .row) continue;
        if (!authorsFill(&node)) continue;
        for (tree.nodes.items) |child| {
            if (child.id == node.id) continue;
            if (child.kind != .column and child.kind != .row) continue;
            if (!descendsFrom(tree, &child, node.id)) continue;
            if (authorsFill(&child)) continue;
            if (!child.paint.transparent) return node.id;
        }
    }
    return null;
}

// The Todo scene itself: no container's fill is covered by a child that
// paints the default surface over it.
//
// A row or column that authors NO fill is painted `palette.container`
// (`src/v7/drawcmd.zig:273-277`). Nested inside a container that DID author
// a surface, such a child covers that surface with the fallback colour and
// leaves the parent's fill showing only in the gaps between children — the
// patchwork the Spotify track rows had, where the active row's highlight
// survived around its eight children instead of under them.
//
// Every filled container is swept, so authoring a card fill cannot
// reintroduce the split unnoticed. The Todo scene passes for a structural
// reason, not by luck: `card()` authors no fill either, so a card and its
// child rows resolve to the SAME `palette.container` and the split has
// nothing to show. Adding a fill to `Card.default_paint` is exactly the
// change that would turn those children into visible offenders.
test "todo scene: no unfilled row or column covers a filled container" {
    var app: TodoApp = .{};
    var tree = try buildTree(&app);
    defer freeTree();
    try std.testing.expectEqual(@as(?FrameNodeId, null), findPatchwork(&tree));
}

// Positive control for `findPatchwork`, and the exact Spotify shape: a row
// that paints a highlight with a plain unfilled row inside it. The inner
// row covers the highlight, which then survives only in the gaps between
// children. If this ever reports null the finder is broken and the Todo
// scene's passing result would mean nothing.
test "patchwork finder reports a filled row covered by an unfilled child row" {
    var tree = try buildScene(struct {
        fn draw(ctx: *DrawCtx) !void {
            _ = try ctx.row(.{
                .fill = c_accent_dim,
                .paint_fill = solidFill(c_accent_dim),
            });
            defer ctx.pop();
            // The defect: no fill, so the paint pass gives this child the
            // `palette.container` fallback instead of letting the row's own
            // highlight show through.
            _ = try ctx.row(.{ .gap = 0 });
            ctx.pop();
        }
    }.draw);
    defer freeTree();

    const offender = findPatchwork(&tree) orelse return error.PatchworkNotDetected;
    const owner = tree.nodeConst(offender) orelse return error.MissingNode;
    try std.testing.expect(authorsFill(owner));

    // Marking the child transparent is the repair, and it must clear the
    // report — that is what makes `.transparent` the fix rather than a
    // cosmetic annotation.
    for (tree.nodes.items) |*node| {
        if (node.kind == .row and !authorsFill(node)) {
            node.paint.transparent = true;
            break;
        }
    }
    try std.testing.expectEqual(@as(?FrameNodeId, null), findPatchwork(&tree));
}

test "todo checkbox mouse and keyboard input update the next frame" {
    var todo: TodoApp = .{};
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    try app.mountRoot(TodoApp, &todo);
    _ = try app.handle(.{ .resize = .{ .width = 1400, .height = 1600 } });
    const first = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (first.json) |json| std.testing.allocator.free(json);

    var checkbox_id: ?FrameNodeId = null;
    var switch_id: ?FrameNodeId = null;
    var second_radio_id: ?FrameNodeId = null;
    for (first.tree.nodes.items) |node| {
        switch (node.kind) {
            .checkbox => |checkbox| {
                if (std.mem.eql(u8, checkbox.label, "buy milk")) checkbox_id = node.id;
            },
            .switch_control => |control| {
                if (std.mem.eql(u8, control.label, "Demo switch")) switch_id = node.id;
            },
            .radio => |radio| {
                if (std.mem.eql(u8, radio.label, "Choice B")) second_radio_id = node.id;
            },
            else => {},
        }
    }
    const id = checkbox_id orelse return error.MissingTodoCheckbox;
    const switch_control_id = switch_id orelse return error.MissingDemoSwitch;
    const radio_id = second_radio_id orelse return error.MissingDemoRadio;
    const checkbox_rect = nogui.widget.absoluteRect(first.tree, id);
    const switch_rect = nogui.widget.absoluteRect(first.tree, switch_control_id);
    const radio_rect = nogui.widget.absoluteRect(first.tree, radio_id);
    try clickAt(&app, switch_rect);
    try clickAt(&app, radio_rect);
    try clickAt(&app, checkbox_rect);
    try std.testing.expect(todo.demo_switch);
    try std.testing.expectEqual(@as(?u32, 1), todo.demo_radio_choice);
    try std.testing.expect(todo.done[0]);

    const second = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (second.json) |json| std.testing.allocator.free(json);
    var done_checkbox = false;
    var done_footer = false;
    for (second.tree.nodes.items) |node| {
        switch (node.kind) {
            .checkbox => |checkbox| {
                if (std.mem.eql(u8, checkbox.label, "buy milk")) {
                    done_checkbox = checkbox.value.*;
                }
            },
            .label => |label| {
                if (std.mem.eql(u8, label.text, "1 of 2 done")) done_footer = true;
            },
            else => {},
        }
    }
    try std.testing.expect(done_checkbox);
    try std.testing.expect(done_footer);

    _ = try app.handle(.{ .key_down = .{ .key = .space, .shift = false } });
    try std.testing.expect(!todo.done[0]);
    const third = (try app.handle(.{ .frame = .{ .tick = 3, .time_ms = 32 } })) orelse
        return error.MissingFrameOutput;
    defer if (third.json) |json| std.testing.allocator.free(json);
    var undone_checkbox = false;
    var undone_footer = false;
    for (third.tree.nodes.items) |node| {
        switch (node.kind) {
            .checkbox => |checkbox| {
                if (std.mem.eql(u8, checkbox.label, "buy milk")) {
                    undone_checkbox = !checkbox.value.*;
                }
            },
            .label => |label| {
                if (std.mem.eql(u8, label.text, "0 of 2 done")) undone_footer = true;
            },
            else => {},
        }
    }
    try std.testing.expect(undone_checkbox);
    try std.testing.expect(undone_footer);
}
test "todo checkbox keeps keyboard focus when items change order" {
    var todo: TodoApp = .{};
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    try app.mountRoot(TodoApp, &todo);
    const first = try app.frame(1, .{ .width = 1400, .height = 1600 });
    defer if (first.json) |json| std.testing.allocator.free(json);

    var target: ?FrameNodeId = null;
    for (first.tree.nodes.items) |node| {
        if (node.kind == .checkbox and node.kind.checkbox.value == &todo.done[1]) {
            target = node.id;
            break;
        }
    }
    const rect = nogui.widget.absoluteRect(first.tree, target orelse return error.MissingTodoCheckbox);
    try clickAt(&app, rect);
    try std.testing.expect(todo.done[1]);

    todo.item_order[0] = 1;
    todo.item_order[1] = 0;
    const second = try app.frame(2, .{ .width = 1400, .height = 1600 });
    defer if (second.json) |json| std.testing.allocator.free(json);
    var first_checkbox: ?*bool = null;
    for (second.tree.nodes.items) |node| {
        if (node.kind == .checkbox) {
            first_checkbox = node.kind.checkbox.value;
            break;
        }
    }
    try std.testing.expectEqual(&todo.done[1], first_checkbox orelse return error.MissingTodoCheckbox);

    _ = try app.handle(.{ .key_down = .{ .key = .space, .shift = false } });
    try std.testing.expect(!todo.done[1]);
    try std.testing.expect(!todo.done[0]);
}

test "TodoApp wheel zoom only over the visible Mandelbrot viewport" {
    var todo: TodoApp = .{};
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    try app.mountRoot(TodoApp, &todo);
    const frame = try app.frame(1, .{ .width = 1100, .height = 1160 });
    defer if (frame.json) |json| std.testing.allocator.free(json);
    const id = todo.mandelbrot.viewport;
    const viewport = nogui.widget.visualBorderRect(frame.tree, id);
    try std.testing.expect(viewport.w > 0 and viewport.h > 0 and viewport.y > 8);
    const initial = todo.mandelbrot.scale;

    const outside: Event = .{ .mouse_wheel = .{
        .x = viewport.x + viewport.w / 2,
        .y = viewport.y - 8,
        .delta_x = 0,
        .delta_y = 1,
    } };
    _ = try app.handle(outside);
    try std.testing.expectEqual(initial, todo.mandelbrot.scale);

    const inside: Event = .{ .mouse_wheel = .{
        .x = viewport.x + viewport.w / 2,
        .y = viewport.y + viewport.h / 2,
        .delta_x = 0,
        .delta_y = 1,
    } };
    _ = try app.handle(inside);
    try std.testing.expect(todo.mandelbrot.scale > initial);
    const zoomed = todo.mandelbrot.scale;

    const right_edge: Event = .{ .mouse_wheel = .{
        .x = viewport.x + viewport.w,
        .y = viewport.y + viewport.h / 2,
        .delta_x = 0,
        .delta_y = 1,
    } };
    _ = try app.handle(right_edge);
    try std.testing.expectEqual(zoomed, todo.mandelbrot.scale);

    todo.setMandelbrotVisible(false);
    _ = try app.handle(inside);
    try std.testing.expectEqual(zoomed, todo.mandelbrot.scale);
}

test "Mandelbrot pan follows the pointer outside the box and stops on cancel" {
    const viewport_scope = nogui.ComponentId.child(.root, .{ .static = "mandelbrot" });
    var todo: TodoApp = .{};
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    try app.mountRoot(TodoApp, &todo);
    const frame = try app.frame(1, .{ .width = 1100, .height = 1160 });
    defer if (frame.json) |json| std.testing.allocator.free(json);
    const viewport = nogui.widget.visualBorderRect(frame.tree, todo.mandelbrot.viewport);
    try std.testing.expect(viewport.w > 0 and viewport.h > 0);
    const inside: [2]f32 = .{ viewport.x + viewport.w / 2, viewport.y + viewport.h / 2 };
    // Left of the box, still inside the surface: the pointer left the
    // viewport, and the capture is what has to carry the input now.
    const outside: [2]f32 = .{ viewport.x - 4, viewport.y + viewport.h / 2 };
    try std.testing.expect(outside[0] > 0);

    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = inside[0], .y = inside[1] } });
    try std.testing.expectEqual(
        app.widgetIdForKey(viewport_scope, .{ .static = "viewport" }) orelse
            return error.MissingMandelbrotViewport,
        app.focus_manager.captured(frame.tree, .{ .mouse = .left }, null) orelse
            return error.MissingMandelbrotCapture,
    );
    const pressed_center = todo.mandelbrot.center;
    try std.testing.expect(todo.mandelbrot.drag != null);

    _ = try app.handle(.{ .mouse_move = .{ .x = outside[0], .y = outside[1] } });
    const panned = todo.mandelbrot.center;
    try std.testing.expect(panned[0] != pressed_center[0] or panned[1] != pressed_center[1]);

    // The release lands outside the box and still belongs to the capture.
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = outside[0], .y = outside[1] } });
    try std.testing.expect(todo.mandelbrot.drag == null);
    try std.testing.expect(app.focus_manager.captured(frame.tree, .{ .mouse = .left }, null) == null);
    _ = try app.handle(.{ .mouse_move = .{ .x = inside[0], .y = inside[1] + 40 } });
    try std.testing.expectEqual(panned[0], todo.mandelbrot.center[0]);
    try std.testing.expectEqual(panned[1], todo.mandelbrot.center[1]);

    // A cancelled press ends the pan, and no later move restarts it.
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = inside[0], .y = inside[1] } });
    _ = try app.handle(.{ .mouse_move = .{ .x = inside[0] + 30, .y = inside[1] } });
    const cancelled = todo.mandelbrot.center;
    try std.testing.expect(cancelled[0] != panned[0]);
    _ = try app.handle(.{ .mouse_cancel = .{ .button = .left, .x = inside[0] + 30, .y = inside[1] } });
    try std.testing.expect(todo.mandelbrot.drag == null);
    _ = try app.handle(.{ .mouse_move = .{ .x = inside[0] + 60, .y = inside[1] } });
    try std.testing.expectEqual(cancelled[0], todo.mandelbrot.center[0]);

    // A window that stopped taking input ends it too.
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = inside[0], .y = inside[1] } });
    _ = try app.handle(.{ .mouse_move = .{ .x = inside[0], .y = inside[1] + 40 } });
    try std.testing.expect(todo.mandelbrot.drag != null);
    _ = try app.handle(.window_focus_lost);
    try std.testing.expect(todo.mandelbrot.drag == null);
    const blurred = todo.mandelbrot.center;
    _ = try app.handle(.{ .mouse_move = .{ .x = inside[0] + 60, .y = inside[1] } });
    try std.testing.expectEqual(blurred[0], todo.mandelbrot.center[0]);
}

test "counter: inc, dec clamps at 0, reset returns to 0" {
    var app: TodoApp = .{};
    app.inc();
    const tree = try buildTree(&app);
    defer freeTree();
    try expectLabel(&tree, "Counter: 1");

    app.dec();
    app.dec(); // dec below zero is clamped
    var tree2 = try buildTree(&app);
    try expectLabel(&tree2, "Counter: 0");

    app.counter = 5;
    app.reset();
    var tree3 = try buildTree(&app);
    try expectLabel(&tree3, "Counter: 0");

    // inc above 99 is clamped too.
    app.counter = 99;
    app.inc();
    var tree4 = try buildTree(&app);
    try expectLabel(&tree4, "Counter: 99");
}

test "add grows visible rows, remove shrinks, both clamp" {
    var app: TodoApp = .{};
    const tree = try buildTree(&app);
    defer freeTree();
    try std.testing.expectEqual(@as(usize, 2), countTodoCheckboxes(&tree));

    app.add();
    var tree2 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 3), countTodoCheckboxes(&tree2));

    app.add();
    app.add(); // clamped at 4
    var tree3 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 4), countTodoCheckboxes(&tree3));

    app.remove();
    app.remove();
    app.remove();
    app.remove(); // clamped at 1
    var tree4 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 1), countTodoCheckboxes(&tree4));
}

test "mute zeroes the volume label" {
    var app: TodoApp = .{};
    const tree = try buildTree(&app);
    defer freeTree();
    try expectLabel(&tree, "Volume: 0.5");

    app.mute();
    var tree2 = try buildTree(&app);
    try expectLabel(&tree2, "Volume: 0.0");
}

test "click injection: the inc button click reaches the component" {
    var todo: TodoApp = .{};
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    app.serialize_json = true;
    try app.mountRoot(TodoApp, &todo);

    const out1 = try app.frame(1, .{ .width = 800, .height = 600 });
    defer if (out1.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(std.mem.indexOf(u8, out1.json.?, "Counter: 0") != null);

    // Find the button by kind, then use its persistent interaction identity.
    var inc_id: ?nogui.WidgetId = null;
    for (out1.tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.eql(u8, b.label, "inc")) inc_id = n.widget_id;
            },
            else => {},
        }
    }
    try std.testing.expect(inc_id != null);

    // Click while the frame tree is still valid (dies at the next arena reset).
    app.activate(out1.tree, inc_id.?);

    const out2 = try app.frame(2, .{ .width = 800, .height = 600 });
    defer if (out2.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(std.mem.indexOf(u8, out2.json.?, "Counter: 1") != null);
}
