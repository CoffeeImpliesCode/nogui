//! Decoded image structures, real image decoders (BMP, QOI, PPM),
//! grayscale transformation, animated image deadlines, and generational
//! texture retirement keeping evicted textures alive for two frames.
const std = @import("std");
const nogui = @import("nogui");

pub const image_types = nogui.image_types;
pub const ObjectFit = image_types.ObjectFit;
pub const Alignment = image_types.Alignment;
pub const Point = image_types.Point;
pub const Size = image_types.Size;
pub const Rect = image_types.Rect;
pub const fitRect = image_types.fitRect;
pub const PixelFormat = image_types.PixelFormat;
pub const ColorSpace = image_types.ColorSpace;
pub const AlphaType = image_types.AlphaType;
pub const PlaneDescriptor = image_types.PlaneDescriptor;
pub const FrameDescriptor = image_types.FrameDescriptor;
pub const TextureSlot = image_types.TextureSlot;
pub const Grayscale = image_types.Grayscale;
pub const ImageFrame = image_types.ImageFrame;
pub const ImageSequence = image_types.ImageSequence;

/// An owned decoded CPU pixel buffer with format and layout metadata.
pub const DecodedImage = struct {
    width: u32,
    height: u32,
    format: PixelFormat = .rgba8,
    color_space: ColorSpace = .srgb,
    alpha_type: AlphaType = .premultiplied,
    stride: u32,
    pixels: []u8,
    duration_ns: ?u64 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.pixels);
        self.pixels = &.{};
        self.width = 0;
        self.height = 0;
        self.* = undefined;
    }

    /// Converts this image into a FrameDescriptor borrowing its pixel memory.
    pub fn asFrameDescriptor(self: *DecodedImage) FrameDescriptor {
        return .{
            .width = self.width,
            .height = self.height,
            .format = self.format,
            .color_space = self.color_space,
            .alpha_type = self.alpha_type,
            .stride = self.stride,
            .duration_ns = self.duration_ns,
            .planes = [_]PlaneDescriptor{.{
                .offset = 0,
                .stride = self.stride,
                .width = self.width,
                .height = self.height,
                .size = self.pixels.len,
            }} ++ @as([3]PlaneDescriptor, @splat(.{})),
            .plane_count = 1,
            .pixels = self.pixels.ptr,
            .release_fn = null,
            .release_ctx = null,
        };
    }

    /// Converts any RGB/RGBA/BGR/R8 image to luminance grayscale.
    /// Rec. 709 weights: Y = 0.2126 R + 0.7152 G + 0.0722 B.
    /// Source rows are read through `stride`, so padded rows decode correctly.
    /// The result is a tightly packed RGBA8 image with no row padding.
    ///
    /// This is a byte-space conversion of a decoded document, and it is not
    /// what `image_types.Grayscale` does. An element's `grayscale` amount
    /// removes Oklab chroma in the renderer, on the sampled image, and leaves
    /// the perceptual lightness alone. Use this when the pixels themselves
    /// must change; use the element option when a view asks for a grayscale
    /// rendering of a frame it did not decode.
    pub fn toGrayscale(self: *const DecodedImage, allocator: std.mem.Allocator) !DecodedImage {
        if (self.width == 0 or self.height == 0) return error.InvalidDimensions;

        const bytes_per_pixel = self.format.bytesPerPixel() orelse return error.UnsupportedFormat;
        const src_row_bytes = std.math.mul(usize, self.width, bytes_per_pixel) catch return error.ImageTooLarge;
        const src_stride = std.math.cast(usize, self.stride) orelse return error.ImageTooLarge;
        if (src_stride < src_row_bytes) return error.InvalidStride;
        const src_span = std.math.add(
            usize,
            src_stride,
            std.math.mul(usize, self.height - 1, src_stride) catch return error.ImageTooLarge,
        ) catch return error.ImageTooLarge;
        if (self.pixels.len < src_span) return error.BufferUnderflow;

        const out_stride = std.math.mul(u32, self.width, 4) catch return error.ImageTooLarge;
        const total_out_bytes = std.math.mul(usize, out_stride, self.height) catch return error.ImageTooLarge;
        const gray_pixels = try allocator.alloc(u8, total_out_bytes);
        errdefer allocator.free(gray_pixels);

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const src_row_start = @as(usize, y) * src_stride;
            const dst_row_start = @as(usize, y) * out_stride;

            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const src_idx = src_row_start + @as(usize, x) * bytes_per_pixel;
                const dst_idx = dst_row_start + @as(usize, x) * 4;
                var r: f32 = 0;
                var g: f32 = 0;
                var b: f32 = 0;
                var a: u8 = 255;

                switch (self.format) {
                    .rgba8 => {
                        r = @floatFromInt(self.pixels[src_idx]);
                        g = @floatFromInt(self.pixels[src_idx + 1]);
                        b = @floatFromInt(self.pixels[src_idx + 2]);
                        a = self.pixels[src_idx + 3];
                    },
                    .bgra8 => {
                        b = @floatFromInt(self.pixels[src_idx]);
                        g = @floatFromInt(self.pixels[src_idx + 1]);
                        r = @floatFromInt(self.pixels[src_idx + 2]);
                        a = self.pixels[src_idx + 3];
                    },
                    .rgb8 => {
                        r = @floatFromInt(self.pixels[src_idx]);
                        g = @floatFromInt(self.pixels[src_idx + 1]);
                        b = @floatFromInt(self.pixels[src_idx + 2]);
                    },
                    .r8 => {
                        const lum = self.pixels[src_idx];
                        r = @floatFromInt(lum);
                        g = r;
                        b = r;
                    },
                    else => unreachable,
                }

                const y_lum: u8 = @intFromFloat(std.math.clamp(0.2126 * r + 0.7152 * g + 0.0722 * b, 0.0, 255.0));
                gray_pixels[dst_idx] = y_lum;
                gray_pixels[dst_idx + 1] = y_lum;
                gray_pixels[dst_idx + 2] = y_lum;
                gray_pixels[dst_idx + 3] = a;
            }
        }

        return .{
            .width = self.width,
            .height = self.height,
            .format = .rgba8,
            .color_space = self.color_space,
            .alpha_type = self.alpha_type,
            .stride = out_stride,
            .pixels = gray_pixels,
            .duration_ns = self.duration_ns,
            .allocator = allocator,
        };
    }
};

/// BMP (Windows Bitmap) image decoder supporting 24-bit BGR and 32-bit BGRA uncompressed.
pub fn decodeBmp(allocator: std.mem.Allocator, data: []const u8) !DecodedImage {
    if (data.len < 54) return error.InvalidData;

    // Check 'BM' signature
    if (data[0] != 0x42 or data[1] != 0x4D) return error.InvalidData;

    const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
    const dib_header_size = std.mem.readInt(u32, data[14..18], .little);
    if (dib_header_size < 40) return error.UnsupportedFormat;

    const raw_w = std.mem.readInt(i32, data[18..22], .little);
    const raw_h = std.mem.readInt(i32, data[22..26], .little);
    if (raw_w <= 0 or raw_h == 0) return error.InvalidData;

    const width: u32 = @intCast(raw_w);
    const is_top_down = (raw_h < 0);
    const height: u32 = @intCast(if (is_top_down) -raw_h else raw_h);

    const planes = std.mem.readInt(u16, data[26..28], .little);
    if (planes != 1) return error.UnsupportedFormat;

    const bpp = std.mem.readInt(u16, data[28..30], .little);
    if (bpp != 24 and bpp != 32) return error.UnsupportedFormat;

    const compression = std.mem.readInt(u32, data[30..34], .little);
    // 0 = BI_RGB, 3 = BI_BITFIELDS
    if (compression != 0 and compression != 3) return error.UnsupportedFormat;

    if (pixel_offset >= data.len) return error.InvalidData;

    const bytes_per_pixel = bpp / 8;
    // Row stride is padded to a 4-byte boundary in BMP files
    const row_bytes = std.math.mul(usize, @as(usize, width), @as(usize, bytes_per_pixel)) catch
        return error.ImageTooLarge;
    const padded_row_bytes = std.math.add(usize, row_bytes, 3) catch return error.ImageTooLarge;
    const row_stride = padded_row_bytes & ~@as(usize, 3);
    const needed_bytes = std.math.mul(usize, row_stride, @as(usize, height)) catch return error.ImageTooLarge;
    const pixel_end = std.math.add(usize, @as(usize, pixel_offset), needed_bytes) catch return error.ImageTooLarge;
    if (pixel_end > data.len) return error.InvalidData;

    const out_stride = std.math.mul(u32, width, 4) catch return error.ImageTooLarge;
    const out_pixels = try allocator.alloc(
        u8,
        std.math.mul(usize, @as(usize, out_stride), @as(usize, height)) catch
            return error.ImageTooLarge,
    );
    errdefer allocator.free(out_pixels);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (is_top_down) y else (height - 1 - y);
        const src_row_offset = @as(usize, pixel_offset) + (@as(usize, src_y) * row_stride);
        const dst_row_offset = @as(usize, y) * @as(usize, out_stride);

        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src_px = src_row_offset + @as(usize, x) * @as(usize, bytes_per_pixel);
            const dst_px = dst_row_offset + @as(usize, x) * 4;

            const b = data[src_px];
            const g = data[src_px + 1];
            const r = data[src_px + 2];
            const a = if (bpp == 32) data[src_px + 3] else 255;

            out_pixels[dst_px] = r;
            out_pixels[dst_px + 1] = g;
            out_pixels[dst_px + 2] = b;
            out_pixels[dst_px + 3] = a;
        }
    }

    return .{
        .width = width,
        .height = height,
        .format = .rgba8,
        .color_space = .srgb,
        .alpha_type = if (bpp == 32) .unpremultiplied else .fully_opaque,
        .stride = out_stride,
        .pixels = out_pixels,
        .duration_ns = null,
        .allocator = allocator,
    };
}

/// QOI (Quite OK Image format) pure-Zig decoder.
pub fn decodeQoi(allocator: std.mem.Allocator, data: []const u8) !DecodedImage {
    // 14 byte header + 8 byte end marker
    if (data.len < 22) return error.InvalidData;

    if (!std.mem.eql(u8, data[0..4], "qoif")) return error.InvalidData;
    if (!std.mem.eql(u8, data[data.len - 8 ..], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 })) {
        return error.InvalidData;
    }

    const width = std.mem.readInt(u32, data[4..8], .big);
    const height = std.mem.readInt(u32, data[8..12], .big);
    const channels = data[12];
    const colorspace = data[13];

    if (width == 0 or height == 0) return error.InvalidData;
    if (channels != 3 and channels != 4) return error.UnsupportedFormat;
    _ = colorspace;

    const total_pixels = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch
        return error.ImageTooLarge;
    const out_stride = std.math.mul(u32, width, 4) catch return error.ImageTooLarge;
    const out_pixels = try allocator.alloc(
        u8,
        std.math.mul(usize, total_pixels, 4) catch return error.ImageTooLarge,
    );
    errdefer allocator.free(out_pixels);

    var index: [64][4]u8 = @splat(@splat(0));
    var px = [4]u8{ 0, 0, 0, 255 };

    var in_pos: usize = 14;
    var out_pos: usize = 0;
    const end_pos = data.len - 8;

    while (out_pos < out_pixels.len and in_pos < end_pos) {
        const b1 = data[in_pos];
        in_pos += 1;

        if (b1 == 0b11111110) { // QOI_OP_RGB
            if (in_pos + 3 > end_pos) return error.InvalidData;
            px[0] = data[in_pos];
            px[1] = data[in_pos + 1];
            px[2] = data[in_pos + 2];
            in_pos += 3;
        } else if (b1 == 0b11111111) { // QOI_OP_RGBA
            if (in_pos + 4 > end_pos) return error.InvalidData;
            px[0] = data[in_pos];
            px[1] = data[in_pos + 1];
            px[2] = data[in_pos + 2];
            px[3] = data[in_pos + 3];
            in_pos += 4;
        } else switch (b1 & 0b11000000) {
            0b00000000 => { // QOI_OP_INDEX
                px = index[b1 & 0b00111111];
            },
            0b01000000 => { // QOI_OP_DIFF
                const dr = @as(i32, (b1 >> 4) & 0x03) - 2;
                const dg = @as(i32, (b1 >> 2) & 0x03) - 2;
                const db = @as(i32, b1 & 0x03) - 2;
                px[0] = @truncate(@as(u32, @bitCast(@as(i32, px[0]) +% dr)));
                px[1] = @truncate(@as(u32, @bitCast(@as(i32, px[1]) +% dg)));
                px[2] = @truncate(@as(u32, @bitCast(@as(i32, px[2]) +% db)));
            },
            0b10000000 => { // QOI_OP_LUMA
                if (in_pos >= end_pos) return error.InvalidData;
                const b2 = data[in_pos];
                in_pos += 1;
                const dg = @as(i32, b1 & 0x3f) - 32;
                const dr = dg + @as(i32, (b2 >> 4) & 0x0f) - 8;
                const db = dg + @as(i32, b2 & 0x0f) - 8;
                px[0] = @truncate(@as(u32, @bitCast(@as(i32, px[0]) +% dr)));
                px[1] = @truncate(@as(u32, @bitCast(@as(i32, px[1]) +% dg)));
                px[2] = @truncate(@as(u32, @bitCast(@as(i32, px[2]) +% db)));
            },
            0b11000000 => { // QOI_OP_RUN
                const run_count = (b1 & 0b00111111) + 1;
                var r: usize = 0;
                while (r < run_count and out_pos < out_pixels.len) : (r += 1) {
                    @memcpy(out_pixels[out_pos .. out_pos + 4], &px);
                    out_pos += 4;
                }
                continue;
            },
            else => unreachable,
        }

        const idx = (@as(usize, px[0]) * 3 + @as(usize, px[1]) * 5 +
            @as(usize, px[2]) * 7 + @as(usize, px[3]) * 11) % 64;
        index[idx] = px;

        @memcpy(out_pixels[out_pos .. out_pos + 4], &px);
        out_pos += 4;
    }

    // A truncated stream would leave the tail of the buffer uninitialized.
    if (out_pos != out_pixels.len) return error.InvalidData;

    return .{
        .width = width,
        .height = height,
        .format = .rgba8,
        .color_space = .srgb,
        .alpha_type = if (channels == 4) .unpremultiplied else .fully_opaque,
        .stride = out_stride,
        .pixels = out_pixels,
        .duration_ns = null,
        .allocator = allocator,
    };
}

/// Netpbm P6 (binary PPM) image decoder.
pub fn decodePpm(allocator: std.mem.Allocator, data: []const u8) !DecodedImage {
    if (data.len < 10) return error.InvalidData;
    if (data[0] != 'P' or data[1] != '6') return error.InvalidData;

    var pos: usize = 2;
    pos = try skipPpmHeaderSpace(data, pos);

    const width = try readPpmNumber(data, &pos);
    pos = try skipPpmHeaderSpace(data, pos);
    const height = try readPpmNumber(data, &pos);
    pos = try skipPpmHeaderSpace(data, pos);
    const maxval = try readPpmNumber(data, &pos);
    if (maxval != 255) return error.UnsupportedFormat;

    // Exactly one whitespace byte separates the header from the payload.
    if (pos >= data.len or !std.ascii.isWhitespace(data[pos])) return error.InvalidData;
    pos += 1;

    const pixel_bytes = data[pos..];
    const total_pixels = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch
        return error.ImageTooLarge;
    const src_bytes = std.math.mul(usize, total_pixels, 3) catch return error.ImageTooLarge;
    if (pixel_bytes.len < src_bytes) return error.InvalidData;

    const out_stride = std.math.mul(u32, width, 4) catch return error.ImageTooLarge;
    const out_pixels = try allocator.alloc(
        u8,
        std.math.mul(usize, total_pixels, 4) catch return error.ImageTooLarge,
    );
    errdefer allocator.free(out_pixels);

    var i: usize = 0;
    while (i < total_pixels) : (i += 1) {
        const src_i = i * 3;
        const dst_i = i * 4;
        out_pixels[dst_i] = pixel_bytes[src_i];
        out_pixels[dst_i + 1] = pixel_bytes[src_i + 1];
        out_pixels[dst_i + 2] = pixel_bytes[src_i + 2];
        out_pixels[dst_i + 3] = 255;
    }

    return .{
        .width = width,
        .height = height,
        .format = .rgba8,
        .color_space = .srgb,
        .alpha_type = .fully_opaque,
        .stride = out_stride,
        .pixels = out_pixels,
        .duration_ns = null,
        .allocator = allocator,
    };
}

/// Skips whitespace and `#` comments that may separate PPM header fields.
fn skipPpmHeaderSpace(data: []const u8, start: usize) !usize {
    var pos = start;
    while (pos < data.len) {
        if (std.ascii.isWhitespace(data[pos])) {
            pos += 1;
        } else if (data[pos] == '#') {
            while (pos < data.len and data[pos] != '\n') pos += 1;
        } else {
            break;
        }
    }
    return pos;
}

/// Reads one decimal header field and leaves `pos` on the byte that ended it.
fn readPpmNumber(data: []const u8, pos: *usize) !u32 {
    const start = pos.*;
    while (pos.* < data.len and !std.ascii.isWhitespace(data[pos.*])) : (pos.* += 1) {}
    if (pos.* == start) return error.InvalidData;
    return std.fmt.parseInt(u32, data[start..pos.*], 10);
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// The sRGB gAMA value 1/2.2 in the PNG fixed-point encoding.
const png_srgb_gamma: u32 = 45455;

/// Samples per pixel of a PNG color type, or null when the type is unknown.
fn pngChannelCount(color_type: u8) ?u8 {
    return switch (color_type) {
        0 => 1, // grayscale
        2 => 3, // truecolor
        3 => 1, // palette index
        4 => 2, // grayscale + alpha
        6 => 4, // truecolor + alpha
        else => null,
    };
}

/// Reports whether a bit depth is legal for a color type.
fn pngBitDepthAllowed(color_type: u8, bit_depth: u8) bool {
    return switch (color_type) {
        0 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        3 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        2, 4, 6 => bit_depth == 8 or bit_depth == 16,
        else => false,
    };
}

/// Reads sample `index` of a reconstructed scanline in raw units, 0 .. 2^bit_depth - 1.
fn pngSample(row: []const u8, bit_depth: u8, index: usize) u16 {
    return switch (bit_depth) {
        16 => (@as(u16, row[index * 2]) << 8) | row[index * 2 + 1],
        8 => row[index],
        1, 2, 4 => blk: {
            const bit_index = index * bit_depth;
            const shift: u3 = @intCast(8 - bit_depth - @as(u8, @intCast(bit_index & 7)));
            const mask: u8 = @truncate((@as(u16, 1) << @as(u4, @intCast(bit_depth))) - 1);
            break :blk (row[bit_index >> 3] >> shift) & mask;
        },
        else => unreachable,
    };
}

/// Scales a raw sample to 8 bits over the full range of its bit depth.
fn pngSampleTo8(raw: u16, bit_depth: u8) u8 {
    return switch (bit_depth) {
        16 => @truncate(raw >> 8),
        8 => @truncate(raw),
        1, 2, 4 => blk: {
            const max_raw: u16 = (@as(u16, 1) << @as(u4, @intCast(bit_depth))) - 1;
            break :blk @truncate((@as(u16, raw) * 255) / max_raw);
        },
        else => unreachable,
    };
}

/// Pure-Zig standard PNG decoder.
/// Decodes non-interlaced color types 0, 2, 3, 4 and 6 at bit depths 1, 2, 4,
/// 8 and 16, including palettes, tRNS transparency and the sRGB/gAMA color
/// hints. Adam7-interlaced images are reported as unsupported.
/// The zlib datastream carried by the IDAT chunks is checked against its
/// Adler-32 trailer, so a corrupt payload is rejected instead of decoded.
pub fn decodePng(allocator: std.mem.Allocator, data: []const u8) !DecodedImage {
    if (data.len < png_signature.len or
        !std.mem.eql(u8, data[0..png_signature.len], &png_signature))
    {
        return error.InvalidData;
    }

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var seen_ihdr = false;
    var seen_idat = false;

    var palette: [256 * 3]u8 = undefined;
    var palette_len: u16 = 0;
    var trns_palette: [256]u8 = undefined;
    var trns_palette_len: u16 = 0;
    var trns_gray: u16 = 0;
    var trns_gray_seen = false;
    var trns_rgb: [3]u16 = .{ 0, 0, 0 };
    var trns_rgb_seen = false;

    var srgb_chunk_seen = false;
    var gamma: u32 = 0;
    var gamma_seen = false;

    var idat_start: usize = 0;
    var idat_end: usize = 0;

    var pos: usize = png_signature.len;
    while (pos + 12 <= data.len) {
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 ..][0..4];
        const body_start = pos + 8;
        const body_end = std.math.add(usize, body_start, chunk_len) catch
            return error.InvalidData;
        if (body_end + 4 > data.len) return error.InvalidData;
        const body = data[body_start..body_end];

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (seen_ihdr or body.len != 13) return error.InvalidData;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            bit_depth = body[8];
            color_type = body[9];
            if (body[10] != 0 or body[11] != 0) return error.UnsupportedFormat;
            if (body[12] != 0) return error.UnsupportedFormat; // Adam7 interlacing
            if (pngChannelCount(color_type) == null) return error.UnsupportedFormat;
            if (!pngBitDepthAllowed(color_type, bit_depth)) return error.UnsupportedFormat;
            if (width == 0 or height == 0) return error.InvalidData;
            seen_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (!seen_ihdr or seen_idat) return error.InvalidData;
            if (color_type == 4 or color_type == 6) return error.InvalidData;
            if (body.len == 0 or body.len % 3 != 0 or body.len > palette.len) return error.InvalidData;
            @memcpy(palette[0..body.len], body);
            palette_len = @intCast(body.len / 3);
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            if (!seen_ihdr) return error.InvalidData;
            switch (color_type) {
                0 => {
                    if (body.len != 2) return error.InvalidData;
                    trns_gray = std.mem.readInt(u16, body[0..2], .big);
                    trns_gray_seen = true;
                },
                2 => {
                    if (body.len != 6) return error.InvalidData;
                    trns_rgb = .{
                        std.mem.readInt(u16, body[0..2], .big),
                        std.mem.readInt(u16, body[2..4], .big),
                        std.mem.readInt(u16, body[4..6], .big),
                    };
                    trns_rgb_seen = true;
                },
                3 => {
                    if (seen_idat or body.len > trns_palette.len) return error.InvalidData;
                    @memcpy(trns_palette[0..body.len], body);
                    trns_palette_len = @intCast(body.len);
                },
                else => return error.InvalidData,
            }
        } else if (std.mem.eql(u8, chunk_type, "sRGB")) {
            if (!seen_ihdr or body.len != 1) return error.InvalidData;
            srgb_chunk_seen = true;
        } else if (std.mem.eql(u8, chunk_type, "gAMA")) {
            if (!seen_ihdr or body.len != 4) return error.InvalidData;
            gamma = std.mem.readInt(u32, body[0..4], .big);
            gamma_seen = gamma != 0;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (!seen_ihdr) return error.InvalidData;
            // IDAT chunks must be consecutive, so the payload stays contiguous.
            if (seen_idat and body_start != idat_end) return error.InvalidData;
            if (!seen_idat) idat_start = body_start;
            idat_end = body_end;
            seen_idat = true;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        pos = body_end + 4;
    }

    if (!seen_ihdr or !seen_idat) return error.InvalidData;

    const channels = pngChannelCount(color_type).?;
    if (color_type == 3 and palette_len == 0) return error.InvalidData;
    if (trns_palette_len > palette_len) return error.InvalidData;

    const has_alpha_channel = color_type == 4 or color_type == 6;
    const has_transparency = trns_gray_seen or trns_rgb_seen or trns_palette_len > 0;
    // Only sRGB and linear are representable. A gAMA other than the sRGB value
    // reports the closest representable tag; the sample bytes stay untransformed.
    const color_space: ColorSpace = if (srgb_chunk_seen or !gamma_seen)
        .srgb
    else if (gamma == png_srgb_gamma)
        .srgb
    else
        .linear;

    const row_samples = std.math.mul(usize, @as(usize, width), @as(usize, channels)) catch
        return error.ImageTooLarge;
    const row_bits = std.math.mul(usize, row_samples, @as(usize, bit_depth)) catch
        return error.ImageTooLarge;
    const scanline_bytes = (row_bits + 7) / 8;
    // Filtering works on whole pixels: 3 bytes for 8-bit RGB, 6 for 16-bit
    // RGB, and 1 byte for every sub-byte depth.
    const bytes_per_sample = (bit_depth + 7) / 8;
    const filter_bpp: usize = @max(1, @as(usize, channels) * @as(usize, bytes_per_sample));
    const raw_row_len = std.math.add(usize, scanline_bytes, 1) catch return error.ImageTooLarge;
    const total_uncompressed = std.math.mul(usize, raw_row_len, height) catch
        return error.ImageTooLarge;

    const compressed = data[idat_start..idat_end];
    if (compressed.len < 6) return error.InvalidData; // header, deflate, Adler-32

    const uncompressed = try allocator.alloc(u8, total_uncompressed);
    defer allocator.free(uncompressed);

    var flate_r: std.Io.Reader = .fixed(compressed);
    var deflate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var deflate = std.compress.flate.Decompress.init(&flate_r, .zlib, &deflate_buf);

    var decomp_len: usize = 0;
    while (deflate.reader.peekGreedy(1)) |chunk| {
        if (decomp_len + chunk.len > uncompressed.len) return error.InvalidData;
        @memcpy(uncompressed[decomp_len .. decomp_len + chunk.len], chunk);
        decomp_len += chunk.len;
        deflate.reader.toss(chunk.len);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.DecodingFailed,
    }
    if (decomp_len != total_uncompressed) return error.InvalidData;

    var adler: std.hash.Adler32 = .{};
    adler.update(uncompressed);
    if (adler.adler != std.mem.readInt(u32, compressed[compressed.len - 4 ..][0..4], .big)) {
        return error.DecodingFailed;
    }

    // Unfilter in place: a row only ever reads bytes already reconstructed.
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_start = @as(usize, y) * raw_row_len;
        const row = uncompressed[row_start + 1 ..][0..scanline_bytes];
        const prev: []const u8 = if (y == 0)
            &.{}
        else
            uncompressed[row_start - raw_row_len + 1 ..][0..scanline_bytes];
        const filter_type = uncompressed[row_start];
        if (filter_type > 4) return error.InvalidData;

        var i: usize = 0;
        while (i < scanline_bytes) : (i += 1) {
            const x_val = row[i];
            const a_val: u8 = if (i >= filter_bpp) row[i - filter_bpp] else 0;
            const b_val: u8 = if (i < prev.len) prev[i] else 0;
            const c_val: u8 = if (i >= filter_bpp and i < prev.len) prev[i - filter_bpp] else 0;

            row[i] = switch (filter_type) {
                0 => x_val,
                1 => x_val +% a_val,
                2 => x_val +% b_val,
                3 => x_val +% @as(u8, @truncate((@as(u16, a_val) + @as(u16, b_val)) / 2)),
                4 => x_val +% paethPredictor(a_val, b_val, c_val),
                else => unreachable,
            };
        }
    }

    const out_stride = std.math.mul(u32, width, 4) catch return error.ImageTooLarge;
    const out_pixels = try allocator.alloc(
        u8,
        std.math.mul(usize, out_stride, height) catch return error.ImageTooLarge,
    );
    errdefer allocator.free(out_pixels);

    y = 0;
    while (y < height) : (y += 1) {
        const row = uncompressed[@as(usize, y) * raw_row_len + 1 ..][0..scanline_bytes];
        const dst = out_pixels[@as(usize, y) * out_stride ..][0..out_stride];

        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const base: usize = @intCast(x);
            const d = base * 4;
            switch (color_type) {
                0 => {
                    const raw = pngSample(row, bit_depth, base);
                    const value = pngSampleTo8(raw, bit_depth);
                    dst[d] = value;
                    dst[d + 1] = value;
                    dst[d + 2] = value;
                    dst[d + 3] = if (trns_gray_seen and raw == trns_gray) 0 else 255;
                },
                2 => {
                    const r_raw = pngSample(row, bit_depth, base * 3);
                    const g_raw = pngSample(row, bit_depth, base * 3 + 1);
                    const b_raw = pngSample(row, bit_depth, base * 3 + 2);
                    const transparent = trns_rgb_seen and
                        r_raw == trns_rgb[0] and
                        g_raw == trns_rgb[1] and
                        b_raw == trns_rgb[2];
                    dst[d] = pngSampleTo8(r_raw, bit_depth);
                    dst[d + 1] = pngSampleTo8(g_raw, bit_depth);
                    dst[d + 2] = pngSampleTo8(b_raw, bit_depth);
                    dst[d + 3] = if (transparent) 0 else 255;
                },
                3 => {
                    const index = pngSample(row, bit_depth, base);
                    if (index >= palette_len) return error.InvalidData;
                    const entry = @as(usize, index) * 3;
                    dst[d] = palette[entry];
                    dst[d + 1] = palette[entry + 1];
                    dst[d + 2] = palette[entry + 2];
                    dst[d + 3] = if (index < trns_palette_len) trns_palette[index] else 255;
                },
                4 => {
                    const value = pngSampleTo8(pngSample(row, bit_depth, base * 2), bit_depth);
                    dst[d] = value;
                    dst[d + 1] = value;
                    dst[d + 2] = value;
                    dst[d + 3] = pngSampleTo8(pngSample(row, bit_depth, base * 2 + 1), bit_depth);
                },
                6 => {
                    dst[d] = pngSampleTo8(pngSample(row, bit_depth, base * 4), bit_depth);
                    dst[d + 1] = pngSampleTo8(pngSample(row, bit_depth, base * 4 + 1), bit_depth);
                    dst[d + 2] = pngSampleTo8(pngSample(row, bit_depth, base * 4 + 2), bit_depth);
                    dst[d + 3] = pngSampleTo8(pngSample(row, bit_depth, base * 4 + 3), bit_depth);
                },
                else => unreachable,
            }
        }
    }

    return .{
        .width = width,
        .height = height,
        .format = .rgba8,
        .color_space = color_space,
        .alpha_type = if (has_alpha_channel or has_transparency) .unpremultiplied else .fully_opaque,
        .stride = out_stride,
        .pixels = out_pixels,
        .duration_ns = null,
        .allocator = allocator,
    };
}

// ── JPEG (libjpeg-turbo) ───────────────────

/// The TurboJPEG C ABI subset used to decode JPEG bytes.
pub const TurboJpegApi = struct {
    tjInitDecompress: *const fn () callconv(.c) ?*anyopaque,
    tjDecompressHeader3: *const fn (
        handle: *anyopaque,
        jpeg_buf: [*]const u8,
        jpeg_size: c_ulong,
        width: *c_int,
        height: *c_int,
        jpeg_subsamp: *c_int,
        jpeg_colorspace: *c_int,
    ) callconv(.c) c_int,
    tjDecompress2: *const fn (
        handle: *anyopaque,
        jpeg_buf: [*]const u8,
        jpeg_size: c_ulong,
        dst_buf: [*]u8,
        width: c_int,
        pitch: c_int,
        height: c_int,
        pixel_format: c_int,
        flags: c_int,
    ) callconv(.c) c_int,
    tjDestroy: *const fn (handle: *anyopaque) callconv(.c) c_int,
};

/// TJPF_RGBX: packed R, G, B and an ignored fourth byte. The decoder fills
/// the fourth byte with 255 because JPEG has no alpha channel.
const turbojpeg_pixel_rgbx: c_int = 2;

/// Why a runtime codec engine cannot decode.
pub const Unavailable = enum {
    none,
    /// The shared library was not found on the loader search path.
    library_missing,
    /// The library loaded but a used symbol was absent.
    symbol_missing,
};

/// Process-wide handle on libturbojpeg. The library is loaded once from the
/// loader's normal search path; a missing library leaves the engine
/// unavailable and callers report that instead of crashing.
pub const JpegEngine = struct {
    api: ?TurboJpegApi = null,
    lib: ?std.DynLib = null,
    unavailable: Unavailable = .none,
    initialized: bool = false,

    var global_instance: JpegEngine = .{};
    var init_lock: std.atomic.Mutex = .unlocked;

    /// The library handle stays open for the process lifetime, so this is
    /// idempotent and safe to call from any thread.
    pub fn getGlobal(maybe_io: ?std.Io) *JpegEngine {
        _ = maybe_io;
        if (!@atomicLoad(bool, &global_instance.initialized, .acquire)) {
            while (!init_lock.tryLock()) std.atomic.spinLoopHint();
            defer init_lock.unlock();
            if (!global_instance.initialized) {
                global_instance.initDynamic() catch |err| {
                    global_instance.unavailable = switch (err) {
                        error.LibjpegUnavailable => .library_missing,
                        else => .symbol_missing,
                    };
                };
                @atomicStore(bool, &global_instance.initialized, true, .release);
            }
        }
        return &global_instance;
    }

    /// True when libturbojpeg was found and every used symbol resolved.
    pub fn isAvailable(self: *const JpegEngine) bool {
        return self.api != null;
    }

    /// `.none` when the engine can decode, otherwise why it cannot.
    pub fn unavailableReason(self: *const JpegEngine) Unavailable {
        return self.unavailable;
    }

    fn initDynamic(self: *JpegEngine) !void {
        // Portable soname only; the library comes from the declared
        // dependencies and is found through the loader's normal search.
        const names = [_][]const u8{ "libturbojpeg.so.0", "libturbojpeg.so" };
        var lib: ?std.DynLib = null;
        for (names) |name| {
            if (std.DynLib.open(name)) |opened| {
                lib = opened;
                break;
            } else |_| {}
        }
        var handle = lib orelse return error.LibjpegUnavailable;
        errdefer handle.close();

        self.api = .{
            .tjInitDecompress = handle.lookup(
                *const fn () callconv(.c) ?*anyopaque,
                "tjInitDecompress",
            ) orelse return error.SymbolNotFound,
            .tjDecompressHeader3 = handle.lookup(
                *const fn (*anyopaque, [*]const u8, c_ulong, *c_int, *c_int, *c_int, *c_int) callconv(.c) c_int,
                "tjDecompressHeader3",
            ) orelse return error.SymbolNotFound,
            .tjDecompress2 = handle.lookup(
                *const fn (
                    *anyopaque,
                    [*]const u8,
                    c_ulong,
                    [*]u8,
                    c_int,
                    c_int,
                    c_int,
                    c_int,
                    c_int,
                ) callconv(.c) c_int,
                "tjDecompress2",
            ) orelse return error.SymbolNotFound,
            .tjDestroy = handle.lookup(
                *const fn (*anyopaque) callconv(.c) c_int,
                "tjDestroy",
            ) orelse return error.SymbolNotFound,
        };
        self.lib = handle;
    }
};

/// True when a JPEG decoder is installed.
pub fn isJpegAvailable(io: std.Io) bool {
    return JpegEngine.getGlobal(io).isAvailable();
}

/// Decodes a JPEG document into an owned RGBA8 buffer through libjpeg-turbo.
/// Baseline and progressive images are both supported; the colorspace of the
/// source is converted to sRGB by libjpeg-turbo, so the result is opaque sRGB.
/// Returns error.LibjpegUnavailable when the library is not installed.
pub fn decodeJpeg(allocator: std.mem.Allocator, maybe_io: ?std.Io, data: []const u8) !DecodedImage {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8 or data[2] != 0xFF) {
        return error.InvalidData;
    }
    if (data.len > std.math.maxInt(c_ulong)) return error.ImageTooLarge;

    const api = JpegEngine.getGlobal(maybe_io).api orelse return error.LibjpegUnavailable;

    const instance = api.tjInitDecompress() orelse return error.OutOfMemory;
    defer _ = api.tjDestroy(instance);

    var header_w: c_int = 0;
    var header_h: c_int = 0;
    var subsamp: c_int = 0;
    var colorspace: c_int = 0;
    if (api.tjDecompressHeader3(
        instance,
        data.ptr,
        @intCast(data.len),
        &header_w,
        &header_h,
        &subsamp,
        &colorspace,
    ) != 0) {
        return error.DecodingFailed;
    }
    if (header_w <= 0 or header_h <= 0) return error.DecodingFailed;

    const width: u32 = @intCast(header_w);
    const height: u32 = @intCast(header_h);
    const out_stride = std.math.mul(u32, width, 4) catch return error.ImageTooLarge;
    const out_pixels = try allocator.alloc(
        u8,
        std.math.mul(usize, @as(usize, out_stride), @as(usize, height)) catch
            return error.ImageTooLarge,
    );
    errdefer allocator.free(out_pixels);

    if (api.tjDecompress2(
        instance,
        data.ptr,
        @intCast(data.len),
        out_pixels.ptr,
        header_w,
        0, // tightly packed rows
        header_h,
        turbojpeg_pixel_rgbx,
        0,
    ) != 0) {
        return error.DecodingFailed;
    }

    // The fourth byte is documented as undefined for TJPF_RGBX; JPEG has no
    // alpha, so every decoded pixel is opaque.
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = out_pixels[@as(usize, y) * out_stride ..][0..out_stride];
        var x: u32 = 0;
        while (x < width) : (x += 1) row[@as(usize, x) * 4 + 3] = 255;
    }

    return .{
        .width = width,
        .height = height,
        .format = .rgba8,
        .color_space = .srgb,
        .alpha_type = .fully_opaque,
        .stride = out_stride,
        .pixels = out_pixels,
        .duration_ns = null,
        .allocator = allocator,
    };
}

/// Unified sniffer and decoder dispatching to PNG, JPEG, BMP, QOI, or PPM.
pub fn decode(allocator: std.mem.Allocator, maybe_io: ?std.Io, data: []const u8) !DecodedImage {
    if (data.len >= png_signature.len and
        std.mem.eql(u8, data[0..png_signature.len], &png_signature))
    {
        return decodePng(allocator, data);
    } else if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return decodeJpeg(allocator, maybe_io, data);
    } else if (data.len >= 2 and data[0] == 0x42 and data[1] == 0x4D) {
        return decodeBmp(allocator, data);
    } else if (data.len >= 4 and std.mem.eql(u8, data[0..4], "qoif")) {
        return decodeQoi(allocator, data);
    } else if (data.len >= 2 and data[0] == 'P' and data[1] == '6') {
        return decodePpm(allocator, data);
    }
    return error.FormatUnsupported;
}

/// Multi-frame animated sequence tracking deadlines and current frame selection
/// over decoded CPU frames. It names no texture slot, so it cannot be handed to
/// an element directly: `frame_source.AnimatedSequence` uploads those frames
/// into a registry and publishes the `ImageSequence` an element samples.
pub const AnimatedImage = struct {
    /// The duration a frame contributes when it declares none, and the period
    /// a sequence wraps over when it declares no total. One value for both, so
    /// the two call sites cannot drift apart.
    const default_duration_ns: u64 = 100 * std.time.ns_per_ms;

    frames: []DecodedImage,
    total_duration_ns: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, frames: []DecodedImage) AnimatedImage {
        var total: u64 = 0;
        for (frames) |frame| {
            total += frame.duration_ns orelse default_duration_ns;
        }
        return .{
            .frames = frames,
            .total_duration_ns = if (total == 0) default_duration_ns else total,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnimatedImage) void {
        for (self.frames) |*frame| {
            frame.deinit();
        }
        self.allocator.free(self.frames);
        self.frames = &.{};
        self.* = undefined;
    }

    /// The wrap period, never zero. `total_duration_ns` carries a declared
    /// default of 0, so a struct literal built without `init` reaches the
    /// timeline arithmetic with a zero period. Both call sites read it from
    /// here, so a zero total falls back to the same default `init` substitutes
    /// instead of dividing by zero or returning an instant in the past.
    fn period(self: *const AnimatedImage) u64 {
        return if (self.total_duration_ns == 0) default_duration_ns else self.total_duration_ns;
    }

    /// Selects the active frame index for a given presentation timestamp in nanoseconds.
    pub fn activeFrameAt(self: *const AnimatedImage, timestamp_ns: i96) usize {
        if (self.frames.len <= 1) return 0;

        const effective_time_ns: u64 = @intCast(@mod(timestamp_ns, @as(i96, @intCast(self.period()))));
        var accum: u64 = 0;

        for (self.frames, 0..) |frame, i| {
            const d = frame.duration_ns orelse default_duration_ns;
            accum += d;
            if (effective_time_ns < accum) return i;
        }
        return self.frames.len - 1;
    }

    /// Computes the next frame transition deadline instant in nanoseconds.
    pub fn nextDeadline(self: *const AnimatedImage, current_ns: i96) i96 {
        if (self.frames.len <= 1) return current_ns + (1000 * std.time.ns_per_s);

        const wrap_ns: i96 = @intCast(self.period());
        const cycle_offset = @mod(current_ns, wrap_ns);
        const cycle_start = current_ns - cycle_offset;

        var accum: i96 = 0;
        for (self.frames) |frame| {
            const d: i96 = @intCast(frame.duration_ns orelse default_duration_ns);
            accum += d;
            if (accum > cycle_offset) {
                return cycle_start + accum;
            }
        }
        return cycle_start + wrap_ns;
    }
};

/// Texture handle referencing a generational slot in the texture registry. One
/// definition, shared with the element's `TextureRef`: a handle the element
/// samples and a handle the registry owns are the same slot, not two
/// parallel notions of one.
pub const TextureHandle = image_types.TextureSlot;

/// Generational texture registry ensuring that evicted textures stay alive for
/// at least two full frames, matching App.arenas[2] double-buffered lifetime.
pub const TextureRegistry = struct {
    pub const SlotState = enum {
        free,
        active,
        retiring,
    };

    pub const Slot = struct {
        generation: u64 = 1,
        pin_count: u32 = 0,
        state: SlotState = .free,
        retired_at_frame: u64 = 0,
        image: ?DecodedImage = null,
    };

    slots: std.ArrayListUnmanaged(Slot) = .empty,
    allocator: std.mem.Allocator,
    io: std.Io,
    current_frame: u64 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) TextureRegistry {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *TextureRegistry) void {
        self.mutex.lockUncancelable(self.io);
        for (self.slots.items) |*slot| {
            if (slot.image) |*img| {
                img.deinit();
            }
        }
        self.slots.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    /// Takes ownership of a decoded image and stores it in an active slot,
    /// pinned once for the caller. On failure the caller keeps the image.
    pub fn insert(self: *TextureRegistry, image: DecodedImage) !TextureHandle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 1. Try to find a free slot
        for (self.slots.items, 0..) |*slot, idx| {
            if (slot.state == .free) {
                slot.state = .active;
                slot.pin_count = 1; // Initially pinned by creator
                slot.retired_at_frame = 0;
                slot.image = image;
                return .{ .index = @intCast(idx), .generation = slot.generation };
            }
        }

        // 2. Append new slot
        const new_index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(self.allocator, .{
            .generation = 1,
            .pin_count = 1,
            .state = .active,
            .retired_at_frame = 0,
            .image = image,
        });

        return .{ .index = new_index, .generation = 1 };
    }

    /// Pins a texture handle, preventing its eviction or release while active.
    pub fn pin(self: *TextureRegistry, handle: TextureHandle) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (handle.index >= self.slots.items.len) return false;
        const slot = &self.slots.items[handle.index];
        if (slot.generation != handle.generation or slot.state == .free) return false;

        slot.pin_count += 1;
        return true;
    }

    /// Releases a pin on a texture handle.
    pub fn unpin(self: *TextureRegistry, handle: TextureHandle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (handle.index >= self.slots.items.len) return;
        const slot = &self.slots.items[handle.index];
        if (slot.generation != handle.generation) return;

        if (slot.pin_count > 0) {
            slot.pin_count -= 1;
        }
    }

    /// Evicts a texture. If the texture is live, it moves to `.retiring` and will
    /// remain accessible for at least 2 frames before destruction.
    pub fn evict(self: *TextureRegistry, handle: TextureHandle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (handle.index >= self.slots.items.len) return;
        const slot = &self.slots.items[handle.index];
        if (slot.generation != handle.generation or slot.state != .active) return;

        slot.state = .retiring;
        slot.retired_at_frame = self.current_frame;
    }

    /// Notifies the registry that a new frame has been presented.
    /// Retiring slots are destroyed and recycled ONLY after at least 2 frames have elapsed
    /// (`frame >= retired_at_frame + 2`) AND their pin count is zero.
    pub fn onFramePresented(self: *TextureRegistry, frame: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.current_frame = frame;

        for (self.slots.items) |*slot| {
            if (slot.state == .retiring) {
                // Must be retired for at least 2 frames and unpinned
                if (frame >= slot.retired_at_frame + 2 and slot.pin_count == 0) {
                    if (slot.image) |*img| {
                        img.deinit();
                        slot.image = null;
                    }
                    slot.state = .free;
                    slot.generation +%= 1; // Bump generation so stale handles fail
                }
            }
        }
    }

    /// Retrieves an image pointer if the handle is valid and active/retiring.
    pub fn get(self: *TextureRegistry, handle: TextureHandle) ?*const DecodedImage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (handle.index >= self.slots.items.len) return null;
        const slot = &self.slots.items[handle.index];
        if (slot.generation != handle.generation or slot.state == .free) return null;

        return if (slot.image) |*img| img else null;
    }
};
