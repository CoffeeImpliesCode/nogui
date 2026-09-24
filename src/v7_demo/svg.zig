//! Demo SVG rasterization: renders a document through the reusable host's
//! librsvg/Cairo adapter (`nogui_host.svg`) into an owned RGBA8 surface,
//! then writes that surface into the pipeline's float upload buffer.
//!
//! The demo owns NO SVG parser. Groups, transforms, curves and arcs, basic
//! shapes, gradients, fill/stroke and viewBox all come from the real
//! renderer; the demo only chooses a viewport and a color mapping.
//!
//! VIEWPORT: the destination is expressed in DEVICE pixels. The caller
//! measures the destination box in logical window units and multiplies by
//! the display scale, so the fitted document lands on the framebuffer 1:1
//! (the sampler's linear filter then never has to rescale). rsvg applies
//! the document's preserveAspectRatio fit and clips to the viewport, which
//! is what makes an overflowing document crop instead of stretching.
//!
//! COLOR: the offscreen target is Oklab and the blit pass converts to sRGB,
//! so a full-color surface is converted per pixel on upload. A monochrome
//! surface uploads as a premultiplied WHITE coverage mask instead: the scene
//! rect's Oklab tint supplies the color, so one raster serves every tint.

const std = @import("std");
const host = @import("nogui_host");
const host_svg = host.svg;

pub const DecodedImage = host_svg.DecodedImage;
pub const SvgEngine = host_svg.SvgEngine;

/// Largest viewport edge accepted for a demo raster. A 4K card at 3x is
/// far below this; the cap only bounds a pathological layout from asking
/// librsvg for an unbounded surface.
pub const max_viewport_edge = 8192;

/// True when librsvg and Cairo load in this process.
pub fn isAvailable() bool {
    return host_svg.SvgEngine.getGlobal(null).isAvailable();
}

/// Rasterize `document` into an owned RGBA8 surface for an exact
/// device-pixel viewport. The caller owns the result and calls `deinit`.
///
/// Errors: `InvalidViewport` for a zero or oversized viewport and
/// `InvalidScale` for a non-positive display scale — both are checked before
/// librsvg is touched — plus the host adapter's parse and render errors.
pub fn rasterize(
    gpa: std.mem.Allocator,
    document: []const u8,
    viewport_width: u32,
    viewport_height: u32,
    scale: f32,
) !DecodedImage {
    if (viewport_width == 0 or viewport_height == 0) return error.InvalidViewport;
    if (viewport_width > max_viewport_edge or viewport_height > max_viewport_edge) {
        return error.InvalidViewport;
    }
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
    return host_svg.renderSvg(gpa, null, document, .{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .dpi_scale = scale,
    });
}

/// The surface's own pixel count.
pub fn pixelCount(image: *const DecodedImage) !usize {
    return std.math.mul(usize, image.width, image.height);
}

/// Errors from the surface-to-float upload path.
pub const WriteError = error{
    /// The row stride is too narrow to hold one row of `width` RGBA pixels,
    /// or the layout arithmetic overflowed `usize`.
    InvalidStride,
    /// The pixel buffer is shorter than the last row the surface describes,
    /// so a row-by-row read would run past its end.
    BufferUnderflow,
    /// The pixel count does not fit in a `usize`.
    ImageTooLarge,
};

/// Check that reading `image` row by row stays inside `image.pixels`.
///
/// The last byte the upload touches is the final pixel of the last row, so
/// the span a surface must cover is `(height - 1) * stride + width * 4` and
/// NOT `height * stride`: a surface whose final row carries no trailing
/// padding is still fully readable, and demanding the padded size would
/// reject it. Surfaces produced by `rasterize` are allocated as
/// `height * stride`, so both bounds agree there.
fn checkSurface(image: *const DecodedImage) WriteError!void {
    const width: usize = image.width;
    const height: usize = image.height;
    if (width == 0 or height == 0) return;
    const stride: usize = image.stride;
    const row_bytes = std.math.mul(usize, width, 4) catch return error.InvalidStride;
    if (stride < row_bytes) return error.InvalidStride;
    const rows = std.math.mul(usize, height - 1, stride) catch return error.InvalidStride;
    const span = std.math.add(usize, rows, row_bytes) catch return error.InvalidStride;
    if (image.pixels.len < span) return error.BufferUnderflow;
}

/// Write the surface into a float4-per-pixel buffer (`pixelCount(image)`
/// entries). `color` maps the normalized premultiplied RGBA of one pixel to
/// the pipeline's float4 — Oklab for the offscreen target, a white coverage
/// mask for tinted monochrome art.
///
/// Errors: `BufferUnderflow` when the pixel buffer does not reach the last
/// row, and `InvalidStride` when the stride cannot hold one row. Both are
/// checked before the first read, so a malformed surface never indexes past
/// the end of the buffer and never writes a partial result.
pub fn writeFloats(
    comptime color: fn (rgba: [4]f32) [4]f32,
    out: [*]f32,
    image: *const DecodedImage,
) WriteError!void {
    try checkSurface(image);
    const count = pixelCount(image) catch return error.ImageTooLarge;
    const width: usize = image.width;
    const stride: usize = image.stride;
    const scale: f32 = 1.0 / 255.0;
    for (0..count) |index| {
        const source = stride * (index / width) + (index % width) * 4;
        const converted = color(.{
            @as(f32, @floatFromInt(image.pixels[source + 0])) * scale,
            @as(f32, @floatFromInt(image.pixels[source + 1])) * scale,
            @as(f32, @floatFromInt(image.pixels[source + 2])) * scale,
            @as(f32, @floatFromInt(image.pixels[source + 3])) * scale,
        });
        const destination = index * 4;
        out[destination + 0] = converted[0];
        out[destination + 1] = converted[1];
        out[destination + 2] = converted[2];
        out[destination + 3] = converted[3];
    }
}

/// A monochrome surface's color mapping: keep the coverage, drop the hue.
pub fn coverageMask(rgba: [4]f32) [4]f32 {
    return .{ 1.0, 1.0, 1.0, rgba[3] };
}

const testing = std.testing;

fn testImage(pixels: []u8, width: u32, height: u32, stride: u32) DecodedImage {
    return .{
        .width = width,
        .height = height,
        .format = .rgba8,
        .color_space = .srgb,
        .alpha_type = .premultiplied,
        .stride = stride,
        .pixels = pixels,
        .allocator = testing.allocator,
    };
}

fn expectNear(actual: f32, expected: f32) !void {
    try testing.expect(@abs(actual - expected) <= 1e-6);
}

test "rasterize rejects a zero and an oversized viewport before librsvg" {
    const document =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4"><rect width="4" height="4"/></svg>
    ;
    try testing.expectError(
        error.InvalidViewport,
        rasterize(testing.allocator, document, 0, 8, 1.0),
    );
    try testing.expectError(
        error.InvalidViewport,
        rasterize(testing.allocator, document, 8, 0, 1.0),
    );
    try testing.expectError(
        error.InvalidViewport,
        rasterize(testing.allocator, document, max_viewport_edge + 1, 8, 1.0),
    );
    try testing.expectError(
        error.InvalidScale,
        rasterize(testing.allocator, document, 8, 8, 0),
    );
}

test "rasterize returns the requested viewport, honors the group transform and blends the gradient" {
    if (!isAvailable()) return error.SkipZigTest;
    // A translated group plus a linear gradient: the two features the
    // retired demo path parser could not represent at all.
    const document =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
        \\  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
        \\    <stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/>
        \\  </linearGradient></defs>
        \\  <g transform="translate(4 4)"><rect width="12" height="12" fill="url(#g)"/></g>
        \\</svg>
    ;
    var image = try rasterize(testing.allocator, document, 40, 24, 2.0);
    defer image.deinit();

    try testing.expectEqual(@as(u32, 40), image.width);
    try testing.expectEqual(@as(u32, 24), image.height);
    try testing.expectEqual(@as(u32, 40 * 4), image.stride);
    try testing.expectEqual(@as(usize, 40 * 24 * 4), image.pixels.len);

    // The 20x20 document is fitted into 40x24, so it is letterboxed to a
    // 24x24 band 8px from the left. The translate(4 4) group leaves that
    // band's top-left corner EMPTY; a parser that dropped the transform
    // would paint the rect over it.
    try testing.expectEqual(@as(u8, 0), image.pixels[0 * 4 + 3]);

    // Across the inked band a gradient varies its color. A solid fill — or a
    // flat tint standing in for the gradient — yields one distinct color.
    const first = firstOpaqueColor(&image);
    try testing.expect(first != null);
    var distinct = false;
    for (0..image.height) |y| {
        for (0..image.width) |x| {
            const offset = (y * @as(usize, image.stride)) + x * 4;
            if (image.pixels[offset + 3] < 200) continue;
            if (image.pixels[offset + 0] != first.?[0] or
                image.pixels[offset + 2] != first.?[1]) distinct = true;
        }
    }
    try testing.expect(distinct);
}

test "rasterize reports a document librsvg cannot parse" {
    if (!isAvailable()) return error.SkipZigTest;
    try testing.expectError(
        error.InvalidSvg,
        rasterize(testing.allocator, "<svg><unclosed", 8, 8, 1.0),
    );
}

fn firstOpaqueColor(image: *const DecodedImage) ?[2]u8 {
    for (0..image.height) |y| {
        for (0..image.width) |x| {
            const offset = (y * @as(usize, image.stride)) + x * 4;
            if (image.pixels[offset + 3] < 200) continue;
            return .{ image.pixels[offset + 0], image.pixels[offset + 2] };
        }
    }
    return null;
}

test "writeFloats honors the source stride and the color mapping" {
    // Two rows of two pixels with a padded stride. Row 0 spans bytes 0..15
    // (8 pixel bytes + 8 padding) and row 1 starts at byte 16, not byte 8, so
    // a stride-blind writer would read row 0's padding as row 1. The buffer
    // must cover `height * stride` = 32 bytes: a 20-byte buffer ends inside
    // row 1, which is the bug this fixture used to hide.
    var pixels: [32]u8 = .{
        255, 0, 0, 255, // 0,0 opaque red
        0, 0, 255, 128, // 1,0 half-transparent blue
        9, 9, 9, 9, // row 0 stride padding
        9, 9, 9, 9, //
        0, 255, 0, 0, // 0,1 fully transparent
        255, 255, 255, 64, // 1,1 faint white
        9, 9, 9, 9, // row 1 stride padding
        9, 9, 9, 9, //
    };
    const image = testImage(&pixels, 2, 2, 16);

    var mask: [4 * 4]f32 = undefined;
    try writeFloats(coverageMask, &mask, &image);
    for (mask, 0..) |channel, index| {
        if (index % 4 == 3) continue;
        try testing.expectEqual(@as(f32, 1.0), channel);
    }
    try expectNear(mask[0 * 4 + 3], 1.0);
    try expectNear(mask[1 * 4 + 3], 128.0 / 255.0);
    try expectNear(mask[2 * 4 + 3], 0.0);
    try expectNear(mask[3 * 4 + 3], 64.0 / 255.0);

    // Row 1 came from bytes 16..23, not from row 0 again: the blue pixel
    // keeps its own channels and its premultiplied alpha.
    var identity: [4 * 4]f32 = undefined;
    try writeFloats(struct {
        fn passthrough(rgba: [4]f32) [4]f32 {
            return rgba;
        }
    }.passthrough, &identity, &image);
    try expectNear(identity[0 * 4 + 0], 1.0);
    try expectNear(identity[0 * 4 + 1], 0.0);
    try expectNear(identity[1 * 4 + 1], 0.0);
    try expectNear(identity[1 * 4 + 2], 1.0);
    try expectNear(identity[1 * 4 + 3], 128.0 / 255.0);
    try expectNear(identity[2 * 4 + 3], 0.0);
    try expectNear(identity[3 * 4 + 0], 1.0);
}

test "writeFloats refuses a pixel buffer that ends inside the last row" {
    // The exact shape the old fixture had: stride 16 for two rows, but only
    // 20 bytes handed over, so row 1's last pixel would be read past the end.
    var pixels: [20]u8 = @splat(9);
    const image = testImage(&pixels, 2, 2, 16);
    var out: [4 * 4]f32 = @splat(-1.0);
    try testing.expectError(
        error.BufferUnderflow,
        writeFloats(coverageMask, &out, &image),
    );
    // The guard runs before the first read, so no partial result is written.
    for (out) |value| try testing.expectEqual(@as(f32, -1.0), value);
}

test "writeFloats refuses a stride too narrow to hold one row" {
    // 4 bytes per row cannot hold two RGBA pixels, whatever the buffer size.
    var pixels: [8]u8 = @splat(0);
    const image = testImage(&pixels, 2, 2, 4);
    var out: [4 * 4]f32 = @splat(-1.0);
    try testing.expectError(
        error.InvalidStride,
        writeFloats(coverageMask, &out, &image),
    );
    for (out) |value| try testing.expectEqual(@as(f32, -1.0), value);
}

test "writeFloats accepts a surface whose last row carries no trailing padding" {
    // The readable span is `(height - 1) * stride + width * 4` = 24, not
    // `height * stride` = 32. A guard that demanded the padded size would
    // reject a surface that is complete on disk.
    var pixels: [24]u8 = .{
        255, 0, 0, 255, // row 0, pixel 0
        0, 0, 255, 128, // row 0, pixel 1
        9, 9, 9, 9, // row 0 padding
        9, 9, 9, 9, //
        0, 255, 0, 0, // row 1, pixel 0
        255, 255, 255, 64, // row 1, pixel 1
    };
    const image = testImage(&pixels, 2, 2, 16);
    var out: [4 * 4]f32 = undefined;
    try writeFloats(struct {
        fn passthrough(rgba: [4]f32) [4]f32 {
            return rgba;
        }
    }.passthrough, &out, &image);
    try expectNear(out[0 * 4 + 3], 1.0);
    try expectNear(out[1 * 4 + 3], 128.0 / 255.0);
    try expectNear(out[2 * 4 + 3], 0.0);
    try expectNear(out[3 * 4 + 0], 1.0);
}
