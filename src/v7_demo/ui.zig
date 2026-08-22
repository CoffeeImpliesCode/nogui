//! v7 demo UI — one interactive TodoApp component with several parts.
//!
//! Demo-side code: imports std plus the pure v7 module via relative paths.
//! All state lives in struct fields; every frame re-draws everything (no
//! dirty tracking). The App loop (or a test) sets `frame_count` before each
//! draw. Buttons carry distinct labels so click injection can target them
//! by scanning the tree — scan by kind, never by position (node order is
//! post-order, ids are not array indices).
//!
//! Import note: Zig 0.16 roots a single-file `zig test <file>` module at
//! the file's directory and rejects imports outside it, so `../v7/...`
//! cannot be imported from here. `src/v7_demo/v7` is therefore a symlink
//! to `../v7`, keeping this file standalone-compilable and testable with
//! `zig test src/v7_demo/ui.zig`.

const std = @import("std");
const noapi = @import("noapi");

const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const Style = nogui.Style;
const PaintStyle = nogui.PaintStyle;
const ComponentKey = nogui.ComponentKey;
const srgbToOklab = @import("text.zig").srgbToOklab;
const text_mod = @import("text.zig");
const WidgetTree = nogui.WidgetTree;
const WidgetNode = nogui.WidgetNode;
const App = nogui.App;
const Id = nogui.Id;
const Event = nogui.Event;
const MandelbrotComponent = @import("mandelbrot_component.zig").MandelbrotComponent;
const layout = nogui.flex;

/// The demo texture's bindless heap index, set by the window backend after
/// it creates + registers the procedural texture (the demo UI cannot touch
/// the GPU). Null = not registered (headless/sim runs) — the textured card
/// then renders as a plain fill. Same driver→UI channel as text_mod.
pub var texture_idx: ?u32 = null;

/// The SVG showcase box's node id (the window injects the tiger's scene
/// rects at this box's absolute rect each frame).
pub var svg_box_id: ?u32 = null;

/// The stroke test scene's tunables (driven by sliders): `stroke_scale`
/// (the whole scene's extra scale), `stroke_algo` (0 = naive SDF, 1 =
/// marching quads, 2 = Cairo running-cover), `stroke_oversize` (the AA
/// band / quad half-extent).
/// The window applies them to the SvgView each frame.
pub var stroke_scale: f32 = 1.0;
pub var stroke_algo: f32 = 2; // 2 = Cairo running-cover (the tiger's current look)
/// Tier-2 frame pacing toggle: the FIFO swapchain + the slop-driven sleep
/// before the input poll. OFF by default — the pacing's cadence must be
/// verified on a quiet machine (the double-framing regression under load
/// is why it's off). Flip to true once the measurements are trustworthy.
pub var frame_pacing: bool = false;
pub var stroke_oversize: f32 = 0.0;
/// The tiger reference render's bindless heap index (the window uploads
/// the rsvg-rendered tiger PNG as a texture; the tiger demo samples it
/// next to our GPU sweep).
pub var tiger_ref_idx: ?u32 = null;
/// Enables the bounded GPU lifecycle smoke path. The window driver sets this
/// only for `--gpu-remount-smoke`; normal windowed and headless paths leave it
/// false, so Mandelbrot remains mounted as usual.
pub var gpu_remount_smoke: bool = false;

/// Frames per second (a rolling average), set by the window driver each frame.
pub var fps: f32 = 0;

/// A pill-click toggle request, applied by the window driver before the
/// next frame (the window owns the batch state the pills mirror; the UI
/// cannot reach the batch, so the click sets a request the window honors).
/// The tiger showcase root: the minimal UI (title + the two large
/// cards). The window drives the SvgView injection via svg_box_id and
/// the reference texture via tiger_ref_idx.
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
                "TIGER SHOWCASE — GPU SWEEP VS REFERENCE",
                c_text,
                18,
                .{ .static = "tiger-title" },
            );
            _ = try caption(
                ctx,
                "Left: our SvgView sweep of tiger.svg   |   Right: librsvg reference",
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
                _ = try caption(ctx, "GPU — OUR SWEEP", 0, .{ .static = "tiger-gpu-caption" });
                {
                    _ = try ctx.row(.{});
                    defer ctx.pop();
                    svg_box_id = @intFromEnum(try ctx.column(.{
                        .basis = 480,
                        .box_sizing = .border_box,
                        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                        .border_color = c_border,
                        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                    }));
                    defer ctx.pop();
                    _ = try ctx.spacer(.{ .size = 480 });
                }
            }
            {
                _ = try card(false, ctx, false);
                defer ctx.pop();
                _ = try caption(ctx, "REFERENCE — LIBRSVG", 0, .{ .static = "tiger-reference-caption" });
                {
                    _ = try ctx.row(.{});
                    defer ctx.pop();
                    _ = try ctx.column(.{
                        .texture = tiger_ref_idx,
                        .basis = 480,
                        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                        .border_color = c_border,
                        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                    });
                    defer ctx.pop();
                    _ = try ctx.spacer(.{ .size = 480 });
                }
            }
        }
    }
};

/// The stroke test scene: a set of curved thin strokes at increasing
/// widths, with sliders for the scene scale, the stroke algorithm
/// (naive SDF vs marching quads) and the pixel oversizing. The window
/// drives the SvgView injection + the per-frame setStrokeStyle.
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
                "Curved thin strokes at widths 0.1 - 4.0   |   A cycles the stroke algo",
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
                    svg_box_id = @intFromEnum(try ctx.column(.{
                        .basis = 620,
                        .box_sizing = .border_box,
                        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                        .border_color = c_border,
                        .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
                    }));
                    defer ctx.pop();
                    _ = try ctx.spacer(.{ .size = 620 });
                }
            }
            {
                _ = try card(false, ctx, false);
                defer ctx.pop();
                _ = try caption(ctx, "CONTROLS", 0, .{ .static = "strokes-controls-caption" });
                const algo_idx: u32 = @intFromFloat(@min(@max(stroke_algo, 0), 2));
                const algo_name = switch (algo_idx) {
                    0 => "naive SDF",
                    1 => "marching quads",
                    else => "Cairo running-cover",
                };
                const algo_text = try std.fmt.allocPrint(
                    ctx.arena,
                    "MODE {d}: {s}   (A cycles)",
                    .{ algo_idx, algo_name },
                );
                _ = try labelColor(ctx, algo_text, c_accent, .{ .static = "strokes-algo-mode" });
                const scale_text = try std.fmt.allocPrint(ctx.arena, "scale: {d:.2}", .{stroke_scale});
                _ = try labelColor(ctx, scale_text, c_text_sec, .{ .static = "strokes-scale-value" });
                _ = try ctx.slider(.{
                    .label = "stroke-scale",
                    .value = &stroke_scale,
                    .min = 0.25,
                    .max = 4,
                    .color = c_accent,
                    .padding = .{ .left = 6, .right = 10 },
                });
                const oversize_text = try std.fmt.allocPrint(ctx.arena, "pixel oversizing: {d:.2}", .{stroke_oversize});
                _ = try labelColor(ctx, oversize_text, c_text_sec, .{ .static = "strokes-oversize-value" });
                _ = try ctx.slider(.{
                    .label = "stroke-oversize",
                    .value = &stroke_oversize,
                    .min = 0,
                    .max = 4,
                    .color = c_accent,
                    .padding = .{ .left = 6, .right = 10 },
                });
            }
        }
    }
};

pub const ToggleKind = enum { subpixel, bgr, damp, debug };
pub var toggle_request: ?ToggleKind = null;

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

/// A non-interactive label scope. Its defaults replace any surrounding
/// component defaults, so labels keep their original column/box behavior
/// when they are drawn inside a row, card, or other styled component.
const PaddedLabel = struct {
    const Self = PaddedLabel;

    text: []const u8,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    font_size: f32 = 0,
    layer: u32 = 0,
    label_id: Id = .root,

    pub const default_style: Style = .{
        .direction = .column,
        .gap = 0,
        .justify = .start,
        .@"align" = .stretch,
        .padding = .{ .left = 6, .right = 6 },
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
    label_id: Id = .root,

    const Variant = enum { pad, ring, margin };

    pub const default_style: Style = .{
        .direction = .column,
        .gap = 0,
        .justify = .start,
        .@"align" = .stretch,
        .padding = .{ .left = 6, .right = 6 },
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
        .gap = 8,
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .padding = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
    };
    pub const default_paint: PaintStyle = .{
        .border_color = c_border,
        .radius = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 },
        .shadow = 4,
    };
};

const GhostButton = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = 0,
        .justify = .center,
        .@"align" = .center,
        .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 5 },
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
    };
    pub const default_paint: PaintStyle = .{
        .border_color = c_border_strong,
        .radius = .{ .top = 7, .right = 7, .bottom = 7, .left = 7 },
        .fill = c_card_deep,
        .gradient = srgbToOklab(c_card_deep),
    };
};

const PrimaryButton = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = 0,
        .justify = .center,
        .@"align" = .center,
        .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 5 },
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
    };
    pub const default_paint: PaintStyle = .{
        .border_color = c_accent,
        .radius = .{ .top = 7, .right = 7, .bottom = 7, .left = 7 },
        .fill = c_accent,
        .gradient = srgbToOklab(c_accent),
    };
};

const ActivePill = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = 0,
        .justify = .center,
        .@"align" = .center,
        .padding = .{ .top = 3, .right = 10, .bottom = 3, .left = 10 },
    };
    pub const default_paint: PaintStyle = .{
        .radius = .{ .top = 9, .right = 9, .bottom = 9, .left = 9 },
        .fill = c_accent_dim,
        .gradient = srgbToOklab(c_accent_dim),
    };
};

const InactivePill = struct {
    pub const default_style: Style = .{
        .direction = .row,
        .gap = 0,
        .justify = .center,
        .@"align" = .center,
        .padding = .{ .top = 3, .right = 10, .bottom = 3, .left = 10 },
        .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
    };
    pub const default_paint: PaintStyle = .{
        .border_color = c_border,
        .radius = .{ .top = 9, .right = 9, .bottom = 9, .left = 9 },
        .fill = c_card_deep,
        .gradient = srgbToOklab(c_card_deep),
    };
};

fn scopedLabel(
    ctx: *DrawCtx,
    text: []const u8,
    key: ComponentKey,
    color: [4]f32,
    font_size: f32,
    layer: u32,
) !Id {
    var component: PaddedLabel = .{
        .text = text,
        .color = color,
        .font_size = font_size,
        .layer = layer,
    };
    try ctx.component(PaddedLabel, .{ .key = key }, &component);
    return component.label_id;
}

fn label(ctx: *DrawCtx, text: []const u8, key: ComponentKey) !Id {
    return scopedLabel(ctx, text, key, .{ 1, 1, 1, 1 }, 0, 0);
}

fn labelSized(ctx: *DrawCtx, text: []const u8, font_size: f32, key: ComponentKey) !Id {
    return scopedLabel(ctx, text, key, .{ 1, 1, 1, 1 }, font_size, 0);
}

fn labelColorSized(
    ctx: *DrawCtx,
    text: []const u8,
    color: [4]f32,
    font_size: f32,
    key: ComponentKey,
) !Id {
    return scopedLabel(ctx, text, key, color, font_size, 0);
}

/// A colored label (text color, not the box).
fn labelColor(ctx: *DrawCtx, text: []const u8, color: [4]f32, key: ComponentKey) !Id {
    return scopedLabel(ctx, text, key, color, 0, 0);
}

/// A muted caption (section headers, stat lines). `layer` (default 0)
/// stamps the caption's own layer key — a caption inside a layered
/// container must ride that layer or its glyphs sort below the container's
/// z>0 fill and vanish behind it.
fn caption(ctx: *DrawCtx, text: []const u8, layer: u32, key: ComponentKey) !Id {
    return scopedLabel(ctx, text, key, c_text_muted, 11, layer);
}

/// Apply the shared card defaults to one container without introducing a
/// component boundary around its interactive children.
fn card(comptime grow: bool, ctx: *DrawCtx, clip: bool) !Id {
    const style = Card.default_style;
    const paint = Card.default_paint;
    return ctx.column(.{
        .direction = style.direction,
        .gap = style.gap,
        .grow = if (grow) 1 else 0,
        .clip = clip,
        .border = style.border,
        .border_color = paint.border_color,
        .radius = paint.radius,
        .padding = style.padding,
        .shadow = paint.shadow,
    });
}

/// Secondary (ghost) button: a flat card-deep fill + a soft border (the
/// fill = the box's flat color, the gradient = the same → no two-tone).
/// The text inherits the node's color (default near-white).
fn btn(ctx: *DrawCtx, text: []const u8, on_click: anytype) !Id {
    const style = GhostButton.default_style;
    const paint = GhostButton.default_paint;
    return ctx.button(.{
        .label = text,
        .on_click = on_click,
        .color = c_text,
        .direction = style.direction,
        .gap = style.gap,
        .justify = style.justify,
        .@"align" = style.@"align",
        .padding = style.padding,
        .border = style.border,
        .border_color = paint.border_color,
        .radius = paint.radius,
        .fill = paint.fill,
        .gradient = paint.gradient,
    });
}

/// Primary button: a flat accent fill + the light text (the demo's "go"
/// verbs: inc, add). Same padding as the ghost button — and a 1px border
/// in the accent color, so its fill insets exactly like the ghost's (the
/// ghost's border insets its fill; a borderless accent fill reads 2px
/// taller than its siblings).
fn btnPrimary(ctx: *DrawCtx, text: []const u8, on_click: anytype) !Id {
    const style = PrimaryButton.default_style;
    const paint = PrimaryButton.default_paint;
    return ctx.button(.{
        .label = text,
        .on_click = on_click,
        .color = c_on_accent,
        .direction = style.direction,
        .gap = style.gap,
        .justify = style.justify,
        .@"align" = style.@"align",
        .padding = style.padding,
        .border = style.border,
        .border_color = paint.border_color,
        .radius = paint.radius,
        .fill = paint.fill,
        .gradient = paint.gradient,
    });
}

/// Toggle pills use the same scoped defaults as the original on/off
/// variants; only their semantic state and text color remain local.
fn pill(ctx: *DrawCtx, text: []const u8, on: bool, on_click: anytype) !Id {
    if (on) {
        const style = ActivePill.default_style;
        const paint = ActivePill.default_paint;
        return ctx.button(.{
            .label = text,
            .on_click = on_click,
            .color = c_accent,
            .direction = style.direction,
            .gap = style.gap,
            .justify = style.justify,
            .@"align" = style.@"align",
            .padding = style.padding,
            .radius = paint.radius,
            .fill = paint.fill,
            .gradient = paint.gradient,
        });
    }
    const style = InactivePill.default_style;
    const paint = InactivePill.default_paint;
    return ctx.button(.{
        .label = text,
        .on_click = on_click,
        .color = c_text_muted,
        .direction = style.direction,
        .gap = style.gap,
        .justify = style.justify,
        .@"align" = style.@"align",
        .padding = style.padding,
        .border = style.border,
        .border_color = paint.border_color,
        .radius = paint.radius,
        .fill = paint.fill,
        .gradient = paint.gradient,
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
        .gap = 8,
    };

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        const text = try std.fmt.allocPrint(ctx.arena, "Volume: {d:.1}", .{self.volume});
        _ = try card(true, ctx, false);
        defer ctx.pop();
        _ = try caption(ctx, "VOLUME", 0, .{ .static = "volume-caption" });
        _ = try ctx.slider(.{
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
            _ = try btn(ctx, "mute", VolumeSlider.mute);
            _ = try labelColor(ctx, text, c_text_sec, .{ .static = "volume-value" });
        }
    }

    pub fn mute(self: *Self) void {
        self.volume = 0;
    }
};
fn showcaseLabel(ctx: *DrawCtx, text: []const u8, variant: ShowcaseLabel.Variant, key: ComponentKey) !Id {
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
        .gap = 10,
        .justify = .space_between,
        .@"align" = .center,
        .padding = .{ .left = 12, .right = 12 },
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

/// The demo root component: title row, counter block, volume block, todo
/// list block and a done-count footer, stacked in a root column (gap 12,
/// blocks use gap 6).
pub const TodoApp = struct {
    // --- state (set/mutated by the demo loop and the interaction methods) ---
    frame_count: u32 = 0, // the App loop sets this before each frame
    counter: u32 = 0, // 0..99
    volume: VolumeSlider = .{},
    showcase: Showcase = .{},
    mandelbrot: MandelbrotComponent = .{},
    /// The window driver toggles this only during the opt-in GPU remount
    /// smoke path. It remains true for normal demo frames.
    mandelbrot_visible: bool = true,

    done: [4]bool = .{ false, false, false, false },
    visible_count: u8 = 2, // how many of the 4 pool items are shown (1..4)

    /// The fixed pool of candidate todo items.
    pub const items = [4][]const u8{ "buy milk", "water plants", "write docs", "exercise" };
    pub const default_style: Style = .{
        .direction = .column,
        .gap = 12,
    };

    pub fn draw(self: *TodoApp, ctx: *DrawCtx) !void {
        const frame_text = try std.fmt.allocPrint(ctx.arena, "Frame: {d}   FPS: {d:.0}", .{ self.frame_count, fps });
        const counter_text = try std.fmt.allocPrint(ctx.arena, "Counter: {d}", .{self.counter});

        var done_count: u32 = 0;
        for (0..self.visible_count) |i| {
            if (self.done[i]) done_count += 1;
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
        // title). Layout sleight: basis 44 pins the badge's height and the
        // negative bottom margin cancels it exactly (the next root node
        // advances by zero), so the tree below lays out byte-identically
        // to the pre-layer shot and ONLY the badge region differs.
        _ = try ctx.column(.{
            .gap = 0,
            .layer = 1,
            .basis = 44,
            .box_sizing = .border_box,
            // shrink 0: the demo tree overflows the 1160px surface, so the
            // overflow shrink pass would otherwise crush the 44px basis and
            // break the -44 bottom-margin cancellation below.
            .shrink = 0,
            .margin = .{ .left = 20, .bottom = -44, .right = 880 }, // 200px chip, top-left of the 1100px surface
            .border = badge_style.border,
            .border_color = badge_paint.border_color,
            .radius = badge_paint.radius,
            .padding = badge_style.padding,
            .fill = c_accent_dim,
            .gradient = srgbToOklab(c_accent_dim),
            .shadow = badge_paint.shadow,
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
                const st = text_mod.debug_state;
                _ = try pill(ctx, if (st.bgr) "BGR" else "RGB", st.bgr, TodoApp.toggleBgr);
                _ = try pill(ctx, "damp", st.damp, TodoApp.toggleDamp);
                _ = try pill(ctx, "debug", st.quad_debug, TodoApp.toggleDebug);
            }
        }

        {
            // Font-sizes showcase: labels at 13/16/20/24/32 px. The
            // per-node font_size selects the matching font state; S toggles
            // the subpixel AA for comparison at every size.
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

        // The ghostty font (Fira Code Nerd Font) at the same sizes — commented
        // out for now (the multi-font showcase is redundant; keep it for later).
        // _ = try ctx.column(.{
        //     .gap = 6,
        //     .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        //     .border_color = .{ 0.4, 0.4, 0.46, 1 },
        //     .radius = .{ .top = 4, .right = 4, .bottom = 4, .left = 4 },
        //     .padding = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
        // });
        // defer ctx.pop();
        // _ = try label(ctx, "Fira Code Nerd Font (ghostty):");
        // _ = try ctx.label(.{
        //     .text = "10px: The quick brown fox jumps over the lazy dog",
        //     .font_size = 10,
        //     .font_id = 1,
        //     .padding = .{ .left = 6, .right = 6 },
        // });
        // _ = try ctx.label(.{
        //     .text = "13px: The quick brown fox jumps over the lazy dog",
        //     .font_size = 13,
        //     .font_id = 1,
        //     .padding = .{ .left = 6, .right = 6 },
        // });
        // _ = try ctx.label(.{
        //     .text = "16px: The quick brown fox jumps over the lazy dog",
        //     .font_size = 16,
        //     .font_id = 1,
        //     .padding = .{ .left = 6, .right = 6 },
        // });
        // _ = try ctx.label(.{
        //     .text = "20px: The quick brown fox jumps over the lazy dog",
        //     .font_size = 20,
        //     .font_id = 1,
        //     .padding = .{ .left = 6, .right = 6 },
        // });
        // _ = try ctx.label(.{
        //     .text = "24px: The quick brown fox jumps over the lazy dog",
        //     .font_size = 24,
        //     .font_id = 1,
        //     .padding = .{ .left = 6, .right = 6 },
        // });
        // }

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
                _ = try btn(ctx, "dec", TodoApp.dec);
                _ = try btn(ctx, "reset", TodoApp.reset);
                _ = try btnPrimary(ctx, "inc", TodoApp.inc);
            }
        }

        // Volume block: nested sub-component (its own card + slider), beside
        // the counter in the same row.
        try ctx.component(VolumeSlider, .{ .key = .{ .static = "volume" } }, &self.volume);
        ctx.pop(); // the horizontal row — explicit, NOT deferred

        // Spacer: reserves 8px of empty main-axis space (paints nothing).
        _ = try ctx.spacer(.{ .size = 8 });

        {
            // Todo block: a card with the done-count header + the
            // add/remove buttons + one toggle row per visible item.
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
                _ = try btn(ctx, "remove", TodoApp.remove);
                _ = try btnPrimary(ctx, "add", TodoApp.add);
            }
            // Unrolled so each toggle button can bind its own comptime
            // handler; the runtime check hides rows beyond visible_count.
            // Toggle button label doubles as the state indicator:
            // "toggle{i}: [ ]" undone, "toggle{i}: [x]" done.
            inline for (0..4) |i| {
                if (i < self.visible_count) {
                    // Per-node transient: how many frames this toggle row
                    // has been drawn. Node-local (each row has its own),
                    // reset to 0 when the row is hidden by "remove" (its
                    // state directory entry dies with the frame).
                    const frames = try ctx.state(u32, "toggle-frames", 0);
                    frames.* += 1;
                    const toggle_text = try std.fmt.allocPrint(
                        ctx.arena,
                        "toggle{d}: [{s}] n={d}",
                        .{ i, if (self.done[i]) "x" else " ", frames.* },
                    );
                    const item_text = if (self.done[i])
                        (try std.fmt.allocPrint(ctx.arena, "DONE: {s}", .{items[i]}))
                    else
                        items[i];
                    _ = try ctx.row(.{ .direction = .row, .gap = 8, .@"align" = .center });
                    defer ctx.pop();
                    _ = try btn(ctx, toggle_text, comptime switch (i) {
                        0 => TodoApp.onToggle0,
                        1 => TodoApp.onToggle1,
                        2 => TodoApp.onToggle2,
                        else => TodoApp.onToggle3,
                    });
                    _ = try labelColor(ctx, item_text, if (self.done[i]) c_text_muted else c_text, .{ .u64 = 700 + i });
                }
            }
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
                    svg_box_id = @intFromEnum(try ctx.column(.{
                        .basis = 190, // fixed width — the same height as the mandelbrot's box
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

    pub fn setMandelbrotVisible(self: *TodoApp, visible: bool) void {
        self.mandelbrot_visible = visible;
    }

    pub fn onEvent(self: *TodoApp, event: *const Event) void {
        self.mandelbrot.onEvent(event);
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

    pub fn toggle(self: *TodoApp, i: usize) void {
        if (i < self.done.len) self.done[i] = !self.done[i];
    }

    pub fn add(self: *TodoApp) void {
        if (self.visible_count < 4) self.visible_count += 1;
    }

    pub fn remove(self: *TodoApp) void {
        if (self.visible_count > 1) self.visible_count -= 1;
    }

    // Per-index adapters so each toggle button binds a type-erased
    // `fn (*TodoApp) void` handler.
    pub fn onToggle0(self: *TodoApp) void {
        self.toggle(0);
    }
    pub fn onToggle1(self: *TodoApp) void {
        self.toggle(1);
    }
    pub fn onToggle2(self: *TodoApp) void {
        self.toggle(2);
    }
    pub fn onToggle3(self: *TodoApp) void {
        self.toggle(3);
    }
};

// --- tests -----------------------------------------------------------------

/// Fresh WidgetTree + DrawCtx over a per-tree arena, run `app.draw`,
/// return the tree for inspection. DrawCtx duplicates label strings into
/// the arena, so the arena must outlive the tree: call freeTree().
/// (Tests run sequentially; a new buildTree() releases the previous arena,
/// so one test may build several trees.)
var test_arena: ?std.heap.ArenaAllocator = null;

fn buildTree(app: *TodoApp) !WidgetTree {
    if (test_arena) |*a| a.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var tree = WidgetTree.init(alloc); // mutable: DrawCtx takes *WidgetTree
    var ctx: DrawCtx = .{ .tree = &tree, .arena = alloc };
    try app.draw(&ctx);
    test_arena = arena;
    return tree;
}

fn freeTree() void {
    if (test_arena) |*a| a.deinit();
    test_arena = null;
}

// The badge's exact-cancellation invariant: basis 44 + the -44 bottom
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
    try std.testing.expectEqual(Id.root, badge_col.parent);
    try std.testing.expectEqual(@as(u32, 1), badge_col.paint.layer);
    var caption_has_layer = false;
    for (tree.nodes.items) |n| {
        if (n.kind == .label and n.parent == badge_col.id and n.paint.layer == 1) caption_has_layer = true;
    }
    try std.testing.expect(caption_has_layer);

    // Layout: the badge is a 44px (basis) x 200px (20 + 880 margins on the
    // 1100px surface) chip at y=0; its -44 bottom margin cancels the
    // advance exactly, so the Showcase row starts at y=0 and the root
    // column follows it directly — no badge-induced offset anywhere.
    const Rect = nogui.Rect;
    const Size = nogui.Size;
    const fakeMeasure = struct {
        fn f(_: []const u8, _: f32, _: u8) Size {
            return .{ .width = 40, .height = 24 };
        }
    }.f;
    layout.layoutWith(&tree, .{ .width = 1100, .height = 1160 }, fakeMeasure);

    try std.testing.expectEqual(Rect{ .x = 20, .y = 0, .w = 200, .h = 44 }, badge_col.rect);
    try std.testing.expectEqual(@as(f32, 0), roots_buf[1].rect.y); // Showcase row, unchanged
    try std.testing.expectEqual(
        roots_buf[1].rect.y + roots_buf[1].rect.h,
        roots_buf[2].rect.y,
    ); // root column, unchanged
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

/// Count button nodes whose label starts with `prefix`.
fn countButtonLabelsWithPrefix(tree: *const WidgetTree, prefix: []const u8) usize {
    var count: usize = 0;
    for (tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.startsWith(u8, b.label, prefix)) count += 1;
            },
            else => {},
        }
    }
    return count;
}

test "draw: tree contains the expected button labels and title" {
    var app: TodoApp = .{ .frame_count = 7 };
    const tree = try buildTree(&app);
    defer freeTree();

    var found_inc = false;
    var found_dec = false;
    var found_reset = false;
    var found_mute = false;
    var found_add = false;
    var found_remove = false;
    for (tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.eql(u8, b.label, "inc")) found_inc = true;
                if (std.mem.eql(u8, b.label, "dec")) found_dec = true;
                if (std.mem.eql(u8, b.label, "reset")) found_reset = true;
                if (std.mem.eql(u8, b.label, "mute")) found_mute = true;
                if (std.mem.eql(u8, b.label, "add")) found_add = true;
                if (std.mem.eql(u8, b.label, "remove")) found_remove = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_inc and found_dec and found_reset and found_mute and found_add and found_remove);

    // Default visible_count of 2 -> exactly two toggle rows, all undone.
    try std.testing.expectEqual(@as(usize, 2), countButtonLabelsWithPrefix(&tree, "toggle"));

    try expectLabel(&tree, "nogui v7 demo");
    try expectLabel(&tree, "Frame: 7   FPS: 0");
}

test "toggle(0) marks the item done in the next draw" {
    var app: TodoApp = .{};
    app.toggle(0);
    const tree = try buildTree(&app);
    defer freeTree();

    // The toggle0 button label now shows "[x]"; toggle1 stays "[ ]".
    var toggle0_shows_done = false;
    var toggle1_shows_undone = false;
    var done_item: ?[]const u8 = null;
    var footer: ?[]const u8 = null;
    for (tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.startsWith(u8, b.label, "toggle0")) {
                    toggle0_shows_done = std.mem.indexOf(u8, b.label, "[x]") != null;
                }
                if (std.mem.startsWith(u8, b.label, "toggle1")) {
                    toggle1_shows_undone = std.mem.indexOf(u8, b.label, "[ ]") != null;
                }
            },
            .label => |l| {
                if (std.mem.startsWith(u8, l.text, "DONE: ")) done_item = l.text;
                if (std.mem.endsWith(u8, l.text, "done") and std.mem.startsWith(u8, l.text, "1 of ")) footer = l.text;
            },
            else => {},
        }
    }
    try std.testing.expect(toggle0_shows_done);
    try std.testing.expect(toggle1_shows_undone);
    try std.testing.expect(done_item != null);
    try std.testing.expectEqualStrings("DONE: buy milk", done_item.?);
    try std.testing.expect(footer != null);
    // 1 of 2 done with the default visible_count of 2.
    try std.testing.expectEqualStrings("1 of 2 done", footer.?);
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
    try std.testing.expectEqual(@as(usize, 2), countButtonLabelsWithPrefix(&tree, "toggle"));

    app.add();
    var tree2 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 3), countButtonLabelsWithPrefix(&tree2, "toggle"));

    app.add();
    app.add(); // clamped at 4
    var tree3 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 4), countButtonLabelsWithPrefix(&tree3, "toggle"));

    app.remove();
    app.remove();
    app.remove();
    app.remove(); // clamped at 1
    var tree4 = try buildTree(&app);
    try std.testing.expectEqual(@as(usize, 1), countButtonLabelsWithPrefix(&tree4, "toggle"));
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
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.serialize_json = true;

    var todo: TodoApp = .{};
    _ = try app.register(TodoApp, &todo);

    const out1 = try app.frame(TodoApp, &todo, 1, .{ .width = 800, .height = 600 });
    defer if (out1.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(std.mem.indexOf(u8, out1.json.?, "Counter: 0") != null);

    // Find the "inc" button by scanning by kind — ids are not positions.
    var inc_id: ?Id = null;
    for (out1.tree.nodes.items) |n| {
        switch (n.kind) {
            .button => |b| {
                if (std.mem.eql(u8, b.label, "inc")) inc_id = n.id;
            },
            else => {},
        }
    }
    try std.testing.expect(inc_id != null);

    // Click while the frame tree is still valid (dies at the next arena reset).
    app.click(out1.tree, inc_id.?);

    const out2 = try app.frame(TodoApp, &todo, 2, .{ .width = 800, .height = 600 });
    defer if (out2.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(std.mem.indexOf(u8, out2.json.?, "Counter: 1") != null);
}
