//! Contract and behavior tests for W14 assets, image decoding, SVG rasterization,
//! and external frame lifecycle management.
const std = @import("std");

const image = @import("image.zig");
const svg = @import("svg.zig");
const frame_source = @import("frame_source.zig");
const nogui = @import("nogui");

const image_types = nogui.image_types;
const ImageView = nogui.image_view.ImageView;
const FrameDemand = nogui.frame_demand.FrameDemand;
const WidgetId = nogui.WidgetId;
const ImageSource = nogui.image_view.Source;

const Alignment = image.Alignment;
const Size = image.Size;
const Rect = image.Rect;
const fitRect = image.fitRect;
const FrameDescriptor = image.FrameDescriptor;

test {
    _ = @import("w14_assets_test.zig");
}

// ── Object Fit Layout Tests ───────────────────────────

test "api-w14 object fit and alignment math" {
    const container: Rect = .{ .x = 10, .y = 20, .w = 100, .h = 50 };
    const intrinsic_wide: Size = .{ .width = 200, .height = 50 }; // Aspect ratio 4:1
    const intrinsic_tall: Size = .{ .width = 50, .height = 100 }; // Aspect ratio 1:2

    // 1. Fill: always matches container rect exactly
    const fill_res = fitRect(.fill, intrinsic_wide, container, Alignment.center);
    try std.testing.expectEqual(container.x, fill_res.x);
    try std.testing.expectEqual(container.y, fill_res.y);
    try std.testing.expectEqual(container.w, fill_res.w);
    try std.testing.expectEqual(container.h, fill_res.h);

    // 2. Contain (wide into 100x50): scale is min(100/200, 50/50) = 0.5 -> 100x25
    const contain_res = fitRect(.contain, intrinsic_wide, container, Alignment.center);
    try std.testing.expectEqual(@as(f32, 100.0), contain_res.w);
    try std.testing.expectEqual(@as(f32, 25.0), contain_res.h);
    try std.testing.expectEqual(@as(f32, 10.0), contain_res.x);
    // Vertical centering: 20 + (50 - 25) * 0.5 = 32.5
    try std.testing.expectEqual(@as(f32, 32.5), contain_res.y);

    // 3. Cover (tall 50x100 into 100x50): scale is max(100/50, 50/100) = 2.0 -> 100x200
    const cover_res = fitRect(.cover, intrinsic_tall, container, Alignment.top_left);
    try std.testing.expectEqual(@as(f32, 100.0), cover_res.w);
    try std.testing.expectEqual(@as(f32, 200.0), cover_res.h);
    try std.testing.expectEqual(@as(f32, 10.0), cover_res.x);
    try std.testing.expectEqual(@as(f32, 20.0), cover_res.y);

    // 4. None: intrinsic dimensions unchanged
    const none_res = fitRect(.none, intrinsic_tall, container, Alignment.center);
    try std.testing.expectEqual(@as(f32, 50.0), none_res.w);
    try std.testing.expectEqual(@as(f32, 100.0), none_res.h);

    // 5. Scale down: smaller intrinsic is treated as None; larger intrinsic is treated as Contain
    const small: Size = .{ .width = 40, .height = 20 };
    const scaledown_small = fitRect(.scale_down, small, container, Alignment.center);
    try std.testing.expectEqual(@as(f32, 40.0), scaledown_small.w);
    try std.testing.expectEqual(@as(f32, 20.0), scaledown_small.h);

    const scaledown_large = fitRect(.scale_down, intrinsic_wide, container, Alignment.center);
    try std.testing.expectEqual(contain_res.w, scaledown_large.w);
    try std.testing.expectEqual(contain_res.h, scaledown_large.h);
}

// ── Generational Texture Retirement Tests ───────────────────────

test "api-w14 two frames keep an evicted texture alive until retirement" {
    var registry = image.TextureRegistry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();

    const pixels = try std.testing.allocator.alloc(u8, 16);
    @memset(pixels, 0xFF);

    const img: image.DecodedImage = .{
        .width = 2,
        .height = 2,
        .stride = 8,
        .pixels = pixels,
        .allocator = std.testing.allocator,
    };

    // Frame 0: texture inserted and active
    const handle = try registry.insert(img);
    registry.unpin(handle); // unpin creator pin so eviction can proceed
    try std.testing.expect(registry.get(handle) != null);

    // Frame 0: texture is evicted
    registry.evict(handle);

    // Frame 0 present: texture is in retiring state, MUST NOT be destroyed
    registry.onFramePresented(0);
    try std.testing.expect(registry.get(handle) != null);

    // Frame 1 present: 1 frame elapsed, STILL MUST BE ALIVE
    registry.onFramePresented(1);
    try std.testing.expect(registry.get(handle) != null);

    // Frame 2 present: 2 full frames elapsed, texture retired and destroyed!
    registry.onFramePresented(2);
    try std.testing.expect(registry.get(handle) == null);

    // Reusing the slot with a new image gets an incremented generation
    const pixels2 = try std.testing.allocator.alloc(u8, 16);
    @memset(pixels2, 0xAA);
    const img2: image.DecodedImage = .{
        .width = 2,
        .height = 2,
        .stride = 8,
        .pixels = pixels2,
        .allocator = std.testing.allocator,
    };

    const handle2 = try registry.insert(img2);
    defer registry.unpin(handle2);

    try std.testing.expectEqual(handle.index, handle2.index);
    try std.testing.expect(handle2.generation > handle.generation);
    // Old handle cannot access new slot content!
    try std.testing.expect(registry.get(handle) == null);
}

// ── Decoders Tests ──────────────────────────────

test "api-w14 pure-Zig BMP decoder" {
    // 2x2 24-bit uncompressed BMP:
    // Header 54 bytes + 2 rows * 8 bytes (padded from 6) = 70 bytes
    var bmp_data: [70]u8 = undefined;
    @memset(&bmp_data, 0);

    // 'BM' magic
    bmp_data[0] = 0x42;
    bmp_data[1] = 0x4D;
    // File size 70
    std.mem.writeInt(u32, bmp_data[2..6], 70, .little);
    // Pixel offset 54
    std.mem.writeInt(u32, bmp_data[10..14], 54, .little);
    // DIB header size 40
    std.mem.writeInt(u32, bmp_data[14..18], 40, .little);
    // Width 2
    std.mem.writeInt(i32, bmp_data[18..22], 2, .little);
    // Height 2 (bottom-up)
    std.mem.writeInt(i32, bmp_data[22..26], 2, .little);
    // Planes 1
    std.mem.writeInt(u16, bmp_data[26..28], 1, .little);
    // Bpp 24
    std.mem.writeInt(u16, bmp_data[28..30], 24, .little);
    // Compression 0 (BI_RGB)
    std.mem.writeInt(u32, bmp_data[30..34], 0, .little);

    // Row 0 (bottom): Blue, Green
    bmp_data[54] = 0xFF; // B
    bmp_data[55] = 0x00; // G
    bmp_data[56] = 0x00; // R
    bmp_data[57] = 0x00; // B
    bmp_data[58] = 0xFF; // G
    bmp_data[59] = 0x00; // R
    // bytes 60, 61: padding

    // Row 1 (top): Red, White
    bmp_data[62] = 0x00; // B
    bmp_data[63] = 0x00; // G
    bmp_data[64] = 0xFF; // R
    bmp_data[65] = 0xFF; // B
    bmp_data[66] = 0xFF; // G
    bmp_data[67] = 0xFF; // R
    // bytes 68, 69: padding

    var decoded = try image.decodeBmp(std.testing.allocator, &bmp_data);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);

    // Row 0 in output is top row: Red (255, 0, 0, 255)
    try std.testing.expectEqual(@as(u8, 255), decoded.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), decoded.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), decoded.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), decoded.pixels[3]);

    // Convert to grayscale
    var gray = try decoded.toGrayscale(std.testing.allocator);
    defer gray.deinit();

    try std.testing.expectEqual(decoded.width, gray.width);
    try std.testing.expectEqual(decoded.height, gray.height);
    // Red (255, 0, 0) luminance: 0.2126 * 255 = 54
    try std.testing.expectEqual(@as(u8, 54), gray.pixels[0]);
}

test "api-w14 pure-Zig QOI decoder" {
    // 1x1 solid red QOI image
    const qoi_test_data = [_]u8{
        'q', 'o', 'i', 'f', // magic
        0x00, 0x00, 0x00, 0x01, // width = 1
        0x00, 0x00, 0x00, 0x01, // height = 1
        0x04, // channels = 4 (RGBA)
        0x00, // sRGB
        // Pixel data: QOI_OP_RGBA (0b11111111), R=255, G=0, B=0, A=255
        0xFF,
        0xFF,
        0x00,
        0x00,
        0xFF,
        // End marker (7 zeroes + 1)
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
    };

    var decoded = try image.decodeQoi(std.testing.allocator, &qoi_test_data);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 1), decoded.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.height);
    try std.testing.expectEqual(@as(u8, 255), decoded.pixels[0]); // R
    try std.testing.expectEqual(@as(u8, 0), decoded.pixels[1]); // G
    try std.testing.expectEqual(@as(u8, 0), decoded.pixels[2]); // B
    try std.testing.expectEqual(@as(u8, 255), decoded.pixels[3]); // A
}

test "api-w14 pure-Zig PNG decoder" {
    // 2x2 RGBA PNG generated from known pixel data
    // Row 0: Red (255,0,0,255), Green (0,255,0,255)
    // Row 1: Blue (0,0,255,255), White (255,255,255,255)
    const png_test_data = [_]u8{
        0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, // Signature
        // IHDR chunk (13 bytes data)
        0x00, 0x00, 0x00, 0x0D, // length = 13
        'I', 'H', 'D', 'R', // type
        0x00, 0x00, 0x00, 0x02, // width = 2
        0x00, 0x00, 0x00, 0x02, // height = 2
        0x08, // bit depth = 8
        0x06, // color type = 6 (RGBA)
        0x00, // compression = 0
        0x00, // filter = 0
        0x00, // interlace = 0
        0x72, 0xB6, 0x0D, 0x24, // CRC
        // IDAT chunk (zlib compressed scanlines)
        0x00, 0x00, 0x00, 0x12, // length = 18
        'I',  'D',  'A',  'T', // type
        // zlib data for:
        //   filter=0, 255,0,0,255, 0,255,0,255
        //   filter=0, 0,0,255,255, 255,255,255,255
        0x78, 0x9C, 0x63, 0xF8,
        0xCF, 0xC0, 0xF0, 0x1F,
        0x0C, 0x81, 0x34, 0x18,
        0x00, 0x00, 0x49, 0xC8,
        0x09, 0xF7,
        0xF9, 0xAB, 0xB6, 0x0D, // CRC
        // IEND chunk
        0x00, 0x00, 0x00, 0x00, // length = 0
        'I', 'E', 'N', 'D', // type
        0xAE, 0x42, 0x60, 0x82, // CRC
    };

    var decoded = try image.decodePng(std.testing.allocator, &png_test_data);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqual(image.PixelFormat.rgba8, decoded.format);

    // Row 0, pixel 0: Red
    try std.testing.expectEqual(@as(u8, 255), decoded.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), decoded.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), decoded.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), decoded.pixels[3]);

    // Row 0, pixel 1: Green
    try std.testing.expectEqual(@as(u8, 0), decoded.pixels[4]);
    try std.testing.expectEqual(@as(u8, 255), decoded.pixels[5]);
    try std.testing.expectEqual(@as(u8, 0), decoded.pixels[6]);
    try std.testing.expectEqual(@as(u8, 255), decoded.pixels[7]);
}

test "api-w14 padded RGB8 grayscale conversion uses stride not flat index" {
    // 2x2 RGB8 image with stride=8 (2 bytes padding per row)
    // Row 0: R(255,0,0), G(0,255,0), pad, pad
    // Row 1: B(0,0,255), W(255,255,255), pad, pad
    const stride: u32 = 8;
    var pixels = [_]u8{
        255, 0, 0, 0, 255, 0, 0, 0, // row 0 (6 bytes pixel + 2 pad)
        0, 0, 255, 255, 255, 255, 0, 0, // row 1 (6 bytes pixel + 2 pad)
    };

    var img: image.DecodedImage = .{
        .width = 2,
        .height = 2,
        .format = .rgb8,
        .color_space = .srgb,
        .alpha_type = .fully_opaque,
        .stride = stride,
        .pixels = &pixels,
        .duration_ns = null,
        .allocator = std.testing.allocator,
    };

    var gray = try img.toGrayscale(std.testing.allocator);
    defer gray.deinit();

    try std.testing.expectEqual(@as(u32, 2), gray.width);
    try std.testing.expectEqual(@as(u32, 2), gray.height);
    try std.testing.expectEqual(@as(u32, 8), gray.stride); // output stride = 2 * 4 = 8

    // Row 0, pixel 0: Red (255,0,0) -> Y = 0.2126*255 = 54
    try std.testing.expectEqual(@as(u8, 54), gray.pixels[0]);
    try std.testing.expectEqual(@as(u8, 54), gray.pixels[1]);
    try std.testing.expectEqual(@as(u8, 54), gray.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), gray.pixels[3]); // alpha

    // Row 0, pixel 1: Green (0,255,0) -> Y = 0.7152*255 = 182
    try std.testing.expectEqual(@as(u8, 182), gray.pixels[4]);

    // Row 1, pixel 0: Blue (0,0,255) -> Y = 0.0722*255 = 18
    try std.testing.expectEqual(@as(u8, 18), gray.pixels[8]);

    // Row 1, pixel 1: White (255,255,255) -> Y = 255
    try std.testing.expectEqual(@as(u8, 255), gray.pixels[12]);
}

// ── External Frame Source & Backpressure Tests ─────────────────────

const MockFrameContext = struct {
    released: bool = false,

    pub fn releaseCallback(ctx: ?*anyopaque) void {
        const self: *MockFrameContext = @ptrCast(@alignCast(ctx.?));
        self.released = true;
    }
};

test "api-w14 external frame source replacement releases old frame only after use" {
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 2);
    defer source.deinit() catch unreachable;

    var mock1: MockFrameContext = .{};
    const frame1: FrameDescriptor = .{
        .width = 640,
        .height = 480,
        .format = .rgba8,
        .stride = 640 * 4,
        .presentation_timestamp_ns = 1000,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock1,
    };

    var mock2: MockFrameContext = .{};
    const frame2: FrameDescriptor = .{
        .width = 640,
        .height = 480,
        .format = .rgba8,
        .stride = 640 * 4,
        .presentation_timestamp_ns = 2000,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock2,
    };

    try source.pushFrame(frame1);

    // Consumer acquires frame1
    const acquired = source.acquireLatest().?;
    try std.testing.expect(!mock1.released);

    // Consumer presents frame1
    source.presentFrame(acquired);
    try std.testing.expect(!mock1.released);

    // Producer pushes frame2
    try source.pushFrame(frame2);

    // Consumer acquires and presents frame2
    const acquired2 = source.acquireLatest().?;
    source.presentFrame(acquired2);

    // frame1 is now replaced and MUST be released!
    try std.testing.expect(mock1.released);
    // frame2 is actively presented and MUST NOT be released!
    try std.testing.expect(!mock2.released);
}

test "api-w14 backpressure drops oldest frame and releases buffer immediately" {
    // Capacity 1 queue: second push forces eviction of first
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 1);
    defer source.deinit() catch unreachable;

    var mock1: MockFrameContext = .{};
    const frame1: FrameDescriptor = .{
        .width = 100,
        .height = 100,
        .format = .rgba8,
        .stride = 400,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock1,
    };

    var mock2: MockFrameContext = .{};
    const frame2: FrameDescriptor = .{
        .width = 100,
        .height = 100,
        .format = .rgba8,
        .stride = 400,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock2,
    };

    try source.pushFrame(frame1);
    try std.testing.expect(!mock1.released);

    // Pushing frame2 drops frame1 due to backpressure queue capacity
    try source.pushFrame(frame2);

    // Dropped frame1 buffer released immediately without leaking!
    try std.testing.expect(mock1.released);
    try std.testing.expect(!mock2.released);
}

test "api-w14 a zero queue capacity still keeps the newest frame" {
    // A capacity of zero would make the trim loop release the frame that was
    // just appended, handing a still-pending buffer to its release callback.
    // The floor belongs to the type, so it holds for init and for the setter.
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 0);
    defer source.deinit() catch unreachable;

    var mock1: MockFrameContext = .{};
    var mock2: MockFrameContext = .{};
    const frame1: FrameDescriptor = .{
        .width = 10,
        .height = 10,
        .format = .rgba8,
        .stride = 40,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock1,
    };
    const frame2: FrameDescriptor = .{
        .width = 10,
        .height = 10,
        .format = .rgba8,
        .stride = 40,
        .presentation_timestamp_ns = 2000,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock2,
    };

    try source.pushFrame(frame1);
    try source.pushFrame(frame2);

    // frame1 is dropped to keep room; frame2 stays pending for a consumer.
    try std.testing.expect(mock1.released);
    try std.testing.expect(!mock2.released);
    const acquired = source.acquireLatest().?;
    try std.testing.expectEqual(@as(i64, 2000), acquired.presentation_timestamp_ns);
    source.presentFrame(acquired);

    source.setMaxQueueCapacity(0);
    var mock3: MockFrameContext = .{};
    const frame3: FrameDescriptor = .{
        .width = 10,
        .height = 10,
        .format = .rgba8,
        .stride = 40,
        .presentation_timestamp_ns = 3000,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock3,
    };
    try source.pushFrame(frame3);

    // The setter cannot lower the floor either, so frame3 is still pending.
    try std.testing.expect(!mock3.released);
    const acquired3 = source.acquireLatest().?;
    try std.testing.expectEqual(@as(i64, 3000), acquired3.presentation_timestamp_ns);
    source.presentFrame(acquired3);
}

test "api-w14 stop reports a frame a consumer still holds" {
    // A consumer-held frame outlives stop(), so its release callback can run
    // after the provider that owns the buffer is gone. stop() must make that
    // visible instead of silently forgetting the frame.
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 2);

    var mock: MockFrameContext = .{};
    const frame: FrameDescriptor = .{
        .width = 8,
        .height = 8,
        .format = .rgba8,
        .stride = 32,
        .presentation_timestamp_ns = 7000,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock,
    };
    try source.pushFrame(frame);

    var acquired = source.acquireLatest().?;
    try std.testing.expectEqual(@as(u32, 1), source.outstandingFrames());

    // stop() releases what it owns and reports what it does not.
    try std.testing.expectEqual(@as(u32, 1), source.stop());
    try std.testing.expect(!mock.released);
    try std.testing.expectEqual(@as(u32, 1), source.outstandingFrames());

    // Handing the frame back accounts it and releases its buffer.
    source.releaseFrame(&acquired);
    try std.testing.expect(mock.released);
    try std.testing.expectEqual(@as(u32, 0), source.outstandingFrames());
    try std.testing.expectEqual(@as(u32, 0), source.stop());

    try source.deinit();
}

test "api-w14 a presented frame is no longer outstanding at stop" {
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 2);
    defer source.deinit() catch unreachable;

    var mock: MockFrameContext = .{};
    const frame: FrameDescriptor = .{
        .width = 8,
        .height = 8,
        .format = .rgba8,
        .stride = 32,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock,
    };
    try source.pushFrame(frame);

    const acquired = source.acquireLatest().?;
    source.presentFrame(acquired);
    try std.testing.expectEqual(@as(u32, 0), source.outstandingFrames());
    try std.testing.expectEqual(@as(u32, 0), source.stop());
}

test "api-w14 stop releases every retained and queued frame" {
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 5);
    defer source.deinit() catch unreachable;

    var mock_queued: MockFrameContext = .{};
    const frame_queued: FrameDescriptor = .{
        .width = 10,
        .height = 10,
        .format = .rgba8,
        .stride = 40,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock_queued,
    };

    var mock_active: MockFrameContext = .{};
    const frame_active: FrameDescriptor = .{
        .width = 10,
        .height = 10,
        .format = .rgba8,
        .stride = 40,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock_active,
    };

    source.presentFrame(frame_active);
    try source.pushFrame(frame_queued);

    try std.testing.expect(!mock_queued.released);
    try std.testing.expect(!mock_active.released);

    // Sudden stop / owner loss
    _ = source.stop();

    // All buffers released without leak
    try std.testing.expect(mock_queued.released);
    try std.testing.expect(mock_active.released);
}

// ── SVG Specimen & Intrinsic Size Tests ───────────────────────

test "api-w14 svg intrinsic size and viewport rendering" {
    const engine = svg.SvgEngine.getGlobal(std.testing.io);
    if (!engine.isAvailable()) {
        // Name the reason so a mislinked test target is not a silent skip.
        std.debug.print("svg engine unavailable: {t}\n", .{engine.unavailableReason()});
        return error.SkipZigTest;
    }

    const svg_doc_fixed =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32">
        \\  <rect x="0" y="0" width="64" height="32" fill="#ff0000"/>
        \\</svg>
    ;

    const size = try svg.queryIntrinsicSize(std.testing.io, svg_doc_fixed);
    try std.testing.expect(size != null);
    try std.testing.expectEqual(@as(f32, 64.0), size.?.width);
    try std.testing.expectEqual(@as(f32, 32.0), size.?.height);

    // Specimen 2: viewBox only without width/height -> intrinsic size unavailable
    const svg_doc_viewbox =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 200">
        \\  <circle cx="50" cy="100" r="40" fill="#00ff00"/>
        \\</svg>
    ;

    const size_viewbox = try svg.queryIntrinsicSize(std.testing.io, svg_doc_viewbox);
    try std.testing.expect(size_viewbox == null); // Unresolved percentages/viewBox returns null

    // Render to explicit viewport with monochrome tint
    var rendered = try svg.renderSvg(std.testing.allocator, std.testing.io, svg_doc_fixed, .{
        .viewport_width = 32,
        .viewport_height = 16,
        .dpi_scale = 1.0,
        .tint = [4]u8{ 0, 0, 255, 255 }, // Tint to blue
    });
    defer rendered.deinit();

    try std.testing.expectEqual(@as(u32, 32), rendered.width);
    try std.testing.expectEqual(@as(u32, 16), rendered.height);
}

// ── Real Image Fixtures ─────────────────────────────

const png_filters_rgb8 = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x05,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x02, 0x0d, 0xb1, 0xb2, 0x00, 0x00, 0x00,
    0x36, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0xf8, 0xcf, 0xa0,
    0xf1, 0x9f, 0x2b, 0xe0, 0xbf, 0x48, 0xc5, 0x7f, 0xb9, 0x05, 0xff, 0x35,
    0x18, 0x19, 0xce, 0x8a, 0x68, 0x30, 0x70, 0xc1, 0x11, 0x13, 0xc3, 0x39,
    0x11, 0x64, 0xc4, 0xcc, 0x20, 0xa3, 0x21, 0xf2, 0x9c, 0x1f, 0x8e, 0x58,
    0x40, 0xc2, 0x0c, 0x5c, 0x70, 0x04, 0x00, 0x74, 0x73, 0x12, 0x83, 0x51,
    0xa5, 0x28, 0x88, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
};

const png_palette_trns = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02,
    0x04, 0x03, 0x00, 0x00, 0x00, 0x8d, 0x86, 0x60, 0x50, 0x00, 0x00, 0x00,
    0x0c, 0x50, 0x4c, 0x54, 0x45, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00,
    0x00, 0xff, 0xff, 0xff, 0xff, 0xfb, 0x00, 0x60, 0xf6, 0x00, 0x00, 0x00,
    0x03, 0x74, 0x52, 0x4e, 0x53, 0x00, 0x80, 0xff, 0xec, 0xf7, 0xb3, 0x18,
    0x00, 0x00, 0x00, 0x0e, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60,
    0x54, 0x66, 0x30, 0x12, 0x00, 0x00, 0x01, 0x0b, 0x00, 0x67, 0x47, 0x8c,
    0x8e, 0xcb, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};

const png_gray16 = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x07, 0x4d, 0x8e, 0xbb, 0x00, 0x00, 0x00,
    0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x60, 0xf8, 0xff,
    0x9f, 0xa1, 0x81, 0x81, 0xf9, 0x05, 0x00, 0x0f, 0xeb, 0x03, 0x6a, 0x41,
    0xb6, 0xed, 0x7b, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
};

const png_bad_adler = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x05,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x02, 0x0d, 0xb1, 0xb2, 0x00, 0x00, 0x00,
    0x36, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0xf8, 0xcf, 0xa0,
    0xf1, 0x9f, 0x2b, 0xe0, 0xbf, 0x48, 0xc5, 0x7f, 0xb9, 0x05, 0xff, 0x35,
    0x18, 0x19, 0xce, 0x8a, 0x68, 0x30, 0x70, 0xc1, 0x11, 0x13, 0xc3, 0x39,
    0x11, 0x64, 0xc4, 0xcc, 0x20, 0xa3, 0x21, 0xf2, 0x9c, 0x1f, 0x8e, 0x58,
    0x40, 0xc2, 0x0c, 0x5c, 0x70, 0x04, 0x00, 0x8b, 0x73, 0x12, 0x83, 0x51,
    0xa5, 0x28, 0x88, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x7d,
};

const png_interlaced = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x02, 0x00, 0x00, 0x01, 0x87, 0xcd, 0xda, 0xa2, 0x00, 0x00, 0x00,
    0x20, 0x63, 0x48, 0x52, 0x4d, 0x00, 0x00, 0x7a, 0x26, 0x00, 0x00, 0x80,
    0x84, 0x00, 0x00, 0xfa, 0x00, 0x00, 0x00, 0x80, 0xe8, 0x00, 0x00, 0x75,
    0x30, 0x00, 0x00, 0xea, 0x60, 0x00, 0x00, 0x3a, 0x98, 0x00, 0x00, 0x17,
    0x70, 0x9c, 0xba, 0x51, 0x3c, 0x00, 0x00, 0x00, 0x06, 0x74, 0x52, 0x4e,
    0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6e, 0xa6, 0x07, 0x91, 0x00,
    0x00, 0x00, 0x06, 0x62, 0x4b, 0x47, 0x44, 0x00, 0xff, 0x00, 0xff, 0x00,
    0xff, 0xa0, 0xbd, 0xa7, 0x93, 0x00, 0x00, 0x00, 0x0e, 0x49, 0x44, 0x41,
    0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0x80, 0x0b, 0xfc, 0x07, 0x00, 0x1c,
    0x00, 0x01, 0xff, 0x26, 0xa8, 0x2e, 0xd3, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

const jpeg_two_tone = [_]u8{
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
    0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
    0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03,
    0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xc4, 0x00,
    0x1f, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
    0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0xff, 0xc4, 0x00, 0xb5, 0x10, 0x00,
    0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00,
    0x00, 0x01, 0x7d, 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21,
    0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81,
    0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24,
    0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25,
    0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a,
    0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56,
    0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a,
    0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86,
    0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99,
    0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3,
    0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6,
    0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9,
    0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1,
    0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xff, 0xc4, 0x00,
    0x1f, 0x01, 0x00, 0x03, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
    0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0xff, 0xc4, 0x00, 0xb5, 0x11, 0x00,
    0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00,
    0x01, 0x02, 0x77, 0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31,
    0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08,
    0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15,
    0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18,
    0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55,
    0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84,
    0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
    0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa,
    0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4,
    0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7,
    0xd8, 0xd9, 0xda, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
    0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xff, 0xda, 0x00,
    0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00, 0xfc,
    0x7f, 0xaf, 0xf3, 0xbc, 0xff, 0x00, 0xb2, 0x03, 0xf3, 0x5e, 0xbf, 0xf4,
    0x30, 0x3f, 0xe1, 0x7c, 0xfd, 0x28, 0xaf, 0xfc, 0xf3, 0xcf, 0xfb, 0xa0,
    0x3f, 0x35, 0xeb, 0xff, 0x00, 0x43, 0x03, 0xfe, 0x17, 0xcf, 0xff, 0xd9,
};

test "api-w14 png decodes every row filter of a real file" {
    // 5x5 RGB8 written with row filters 0, 1, 2, 3 and 4 in that order, so one
    // decode exercises all five reconstruction paths.
    var decoded = try image.decodePng(std.testing.allocator, &png_filters_rgb8);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 5), decoded.width);
    try std.testing.expectEqual(@as(u32, 5), decoded.height);
    try std.testing.expectEqual(image.PixelFormat.rgba8, decoded.format);
    try std.testing.expectEqual(image.ColorSpace.srgb, decoded.color_space);
    try std.testing.expectEqual(image.AlphaType.fully_opaque, decoded.alpha_type);
    try std.testing.expectEqual(@as(u32, 20), decoded.stride);
    try std.testing.expectEqual(@as(usize, 100), decoded.pixels.len);

    const expected: [25][3]u8 = .{
        .{ 0, 255, 0 },  .{ 40, 255, 10 }, .{ 80, 255, 20 }, .{ 120, 255, 30 }, .{ 160, 255, 40 },
        .{ 0, 205, 20 }, .{ 40, 205, 30 }, .{ 80, 205, 40 }, .{ 120, 205, 50 }, .{ 160, 205, 60 },
        .{ 0, 155, 40 }, .{ 40, 155, 50 }, .{ 80, 155, 60 }, .{ 120, 155, 70 }, .{ 160, 155, 80 },
        .{ 0, 105, 60 }, .{ 40, 105, 70 }, .{ 80, 105, 80 }, .{ 120, 105, 90 }, .{ 160, 105, 100 },
        .{ 0, 55, 80 },  .{ 40, 55, 90 },  .{ 80, 55, 100 }, .{ 120, 55, 110 }, .{ 160, 55, 120 },
    };
    for (expected, 0..) |pixel, index| {
        const base = index * 4;
        try std.testing.expectEqual(pixel[0], decoded.pixels[base]);
        try std.testing.expectEqual(pixel[1], decoded.pixels[base + 1]);
        try std.testing.expectEqual(pixel[2], decoded.pixels[base + 2]);
        try std.testing.expectEqual(@as(u8, 255), decoded.pixels[base + 3]);
    }
}

test "api-w14 png palette entries and tRNS transparency" {
    // 4x2, 4-bit palette: indices 0,1,2,3 then 3,2,1,0, with alpha 0, 128, 255
    // for the first three entries and full opacity for the fourth.
    var decoded = try image.decodePng(std.testing.allocator, &png_palette_trns);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 4), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqual(image.AlphaType.unpremultiplied, decoded.alpha_type);

    const expected: [8][4]u8 = .{
        .{ 255, 0, 0, 0 },       .{ 0, 255, 0, 128 }, .{ 0, 0, 255, 255 }, .{ 255, 255, 255, 255 },
        .{ 255, 255, 255, 255 }, .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 128 }, .{ 255, 0, 0, 0 },
    };
    for (expected, 0..) |pixel, index| {
        const base = index * 4;
        try std.testing.expectEqualSlices(u8, &pixel, decoded.pixels[base..][0..4]);
    }
}

test "api-w14 png 16-bit grayscale reduces to 8 bits by the high byte" {
    // 2x2 grayscale samples 0, 65535, 32768, 1000.
    var decoded = try image.decodePng(std.testing.allocator, &png_gray16);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(image.AlphaType.fully_opaque, decoded.alpha_type);

    const expected = [4]u8{ 0, 255, 128, 3 };
    for (expected, 0..) |value, index| {
        const base = index * 4;
        try std.testing.expectEqual(value, decoded.pixels[base]);
        try std.testing.expectEqual(value, decoded.pixels[base + 1]);
        try std.testing.expectEqual(value, decoded.pixels[base + 2]);
        try std.testing.expectEqual(@as(u8, 255), decoded.pixels[base + 3]);
    }
}

test "api-w14 png reports interlaced input instead of guessing" {
    try std.testing.expectError(
        error.UnsupportedFormat,
        image.decodePng(std.testing.allocator, &png_interlaced),
    );
    try std.testing.expectError(
        error.UnsupportedFormat,
        image.decode(std.testing.allocator, std.testing.io, &png_interlaced),
    );
}

test "api-w14 png rejects a corrupt zlib payload" {
    // Same file with one bit flipped in the zlib Adler-32 trailer.
    try std.testing.expectError(
        error.DecodingFailed,
        image.decodePng(std.testing.allocator, &png_bad_adler),
    );
}

test "api-w14 jpeg decodes through libjpeg-turbo" {
    if (!image.isJpegAvailable(std.testing.io)) {
        // Name the reason so a mislinked test target is not a silent skip.
        std.debug.print("jpeg engine unavailable: {t}\n", .{
            image.JpegEngine.getGlobal(std.testing.io).unavailableReason(),
        });
        return error.SkipZigTest;
    }

    // 16x16 JPEG: left half red, right half blue, 4:4:4 quality 100.
    var decoded = try image.decode(std.testing.allocator, std.testing.io, &jpeg_two_tone);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 16), decoded.width);
    try std.testing.expectEqual(@as(u32, 16), decoded.height);
    try std.testing.expectEqual(image.PixelFormat.rgba8, decoded.format);
    try std.testing.expectEqual(image.AlphaType.fully_opaque, decoded.alpha_type);
    try std.testing.expectEqual(@as(u32, 64), decoded.stride);

    for (0..16) |y| {
        for (0..16) |x| {
            const base = (y * 16 + x) * 4;
            const pixel = decoded.pixels[base..][0..4];
            try std.testing.expectEqual(@as(u8, 255), pixel[3]);
            if (x < 8) {
                try std.testing.expect(pixel[0] > 180);
                try std.testing.expect(pixel[1] < 60);
                try std.testing.expect(pixel[2] < 60);
            } else {
                try std.testing.expect(pixel[2] > 180);
                try std.testing.expect(pixel[0] < 60);
                try std.testing.expect(pixel[1] < 60);
            }
        }
    }
}

test "api-w14 ppm header comments are skipped" {
    // P6 with a comment between the magic and the width.
    const ppm = "P6\n# written by a camera\n2 1\n255\n" ++ [_]u8{ 255, 0, 0, 0, 0, 255 };
    var decoded = try image.decodePpm(std.testing.allocator, ppm);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 }, decoded.pixels);
}

test "api-w14 grayscale rejects a stride that cannot hold one row" {
    var pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const image_ref: image.DecodedImage = .{
        .width = 2,
        .height = 2,
        .format = .rgba8,
        .stride = 4, // less than one row of 8 bytes
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(
        error.InvalidStride,
        image_ref.toGrayscale(std.testing.allocator),
    );
}

test "api-w14 grayscale rejects a truncated buffer" {
    var pixels = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const image_ref: image.DecodedImage = .{
        .width = 2,
        .height = 2,
        .format = .r8,
        .stride = 4, // two rows of 4 bytes each need 8 bytes
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(
        error.BufferUnderflow,
        image_ref.toGrayscale(std.testing.allocator),
    );
}

// ── CPU Upload Contract Tests ───────────────────────────

test "api-w14 cpu upload reads padded rows through the frame stride" {
    const padded = [_]u8{
        10, 20, 30, 40, 50, 60, 70, 80, 99, 99, // row 0 plus two pad bytes
        90, 100, 110, 120, 130, 140, 150, 160, 99, 99, // row 1 plus two pad bytes
    };
    const frame: FrameDescriptor = .{
        .width = 2,
        .height = 2,
        .format = .rgba8,
        .stride = 10,
    };
    var uploaded = try frame_source.CpuUploadAdapter.uploadToRgba(
        std.testing.allocator,
        frame,
        &padded,
        .{},
    );
    defer uploaded.deinit();

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            10, 20,  30,  40,  50,  60,  70,  80,
            90, 100, 110, 120, 130, 140, 150, 160,
        },
        uploaded.pixels,
    );
}

test "api-w14 cpu upload rejects a yuv frame whose planes overrun the buffer" {
    // 4x2 YUV 4:2:0 needs 8 Y bytes, 2 U bytes and 2 V bytes; the buffer stops
    // before the V plane is complete.
    const buffer = [_]u8{0} ** 10;
    const frame: FrameDescriptor = .{
        .width = 4,
        .height = 2,
        .format = .yuv420p,
        .stride = 4,
        .plane_count = 3,
        .planes = .{
            .{ .offset = 0, .stride = 4, .width = 4, .height = 2, .size = 8 },
            .{ .offset = 8, .stride = 2, .width = 2, .height = 1, .size = 2 },
            .{ .offset = 10, .stride = 2, .width = 2, .height = 1, .size = 2 },
            .{},
        },
    };
    try std.testing.expectError(
        error.BufferUnderflow,
        frame_source.CpuUploadAdapter.uploadToRgba(std.testing.allocator, frame, &buffer, .{}),
    );
}

// ── Frame Ownership Tests ────────────────────────────

test "api-w14 a frame that cannot be queued is released exactly once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var source = frame_source.FrameSource.init(failing.allocator(), std.testing.io, 2);
    defer source.deinit() catch unreachable;

    var mock: MockFrameContext = .{};
    const frame: FrameDescriptor = .{
        .width = 8,
        .height = 8,
        .format = .rgba8,
        .stride = 32,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock,
    };

    try std.testing.expectError(error.OutOfMemory, source.pushFrame(frame));
    try std.testing.expect(mock.released);
    // The queue must stay empty: a failed push must not consume a slot.
    try std.testing.expect(source.acquireLatest() == null);
    try std.testing.expectEqual(@as(u64, 0), source.total_pushed);
}

test "api-w14 a push after stop releases the frame instead of queueing it" {
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 2);
    defer source.deinit() catch unreachable;
    _ = source.stop();

    var mock: MockFrameContext = .{};
    const frame: FrameDescriptor = .{
        .width = 8,
        .height = 8,
        .format = .rgba8,
        .stride = 32,
        .release_fn = MockFrameContext.releaseCallback,
        .release_ctx = &mock,
    };

    try std.testing.expectError(error.SourceStopped, source.pushFrame(frame));
    try std.testing.expect(mock.released);
    try std.testing.expectEqual(@as(u64, 0), source.total_pushed);
}

// ── Animated Image Timeline Tests ──────────────────────

/// Allocates a 1x1 frame whose pixels are allocated but never read, so the
/// timeline tests exercise frame scheduling only and never decoding.
fn syntheticFrame(allocator: std.mem.Allocator, duration_ns: u64) !image.DecodedImage {
    const pixels = try allocator.alloc(u8, 4);
    @memset(pixels, 0);
    return .{
        .width = 1,
        .height = 1,
        .stride = 4,
        .pixels = pixels,
        .duration_ns = duration_ns,
        .allocator = allocator,
    };
}

/// Allocates a frame slice the caller owns and must hand to exactly one owner.
fn syntheticFrameSlice(allocator: std.mem.Allocator, durations: []const u64) ![]image.DecodedImage {
    const frames = try allocator.alloc(image.DecodedImage, durations.len);
    var built: usize = 0;
    errdefer {
        for (frames[0..built]) |*frame| frame.deinit();
        allocator.free(frames);
    }
    while (built < durations.len) : (built += 1) {
        frames[built] = try syntheticFrame(allocator, durations[built]);
    }
    return frames;
}

fn syntheticSequence(allocator: std.mem.Allocator, durations: []const u64) !image.AnimatedImage {
    return image.AnimatedImage.init(allocator, try syntheticFrameSlice(allocator, durations));
}

/// Allocator that records every live block, so a test can observe that a
/// sequence released each of its frames exactly once. A free of a block that
/// is not live counts as a double free instead of corrupting the buffer, which
/// is what lets a test prove its own assertions have teeth.
const LiveLedger = struct {
    /// A test sequence is a handful of blocks, never a workload.
    const capacity = 32;

    inner: std.mem.Allocator,

    live: [capacity][*]u8,
    live_count: usize = 0,
    frees: usize = 0,
    double_frees: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *LiveLedger) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LiveLedger = @ptrCast(@alignCast(context));
        const memory = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        std.debug.assert(self.live_count < capacity);
        self.live[self.live_count] = memory;
        self.live_count += 1;
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *LiveLedger = @ptrCast(@alignCast(context));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LiveLedger = @ptrCast(@alignCast(context));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *LiveLedger = @ptrCast(@alignCast(context));
        for (self.live[0..self.live_count], 0..) |ptr, i| {
            if (ptr == memory.ptr) {
                self.live[i] = self.live[self.live_count - 1];
                self.live_count -= 1;
                self.frees += 1;
                self.inner.rawFree(memory, alignment, ret_addr);
                return;
            }
        }
        // Not a live block, so this is a second release of the same memory.
        self.double_frees += 1;
    }
};

test "api-w14 an uneven frame timeline switches at every boundary and wraps" {
    const ms = std.time.ns_per_ms;
    // Deliberately uneven: 10, 25, 5, 60 ms. An accumulator off by one frame,
    // or by a single nanosecond, lands on the wrong index at a boundary.
    var anim = try syntheticSequence(std.testing.allocator, &.{ 10 * ms, 25 * ms, 5 * ms, 60 * ms });
    defer anim.deinit();
    try std.testing.expectEqual(@as(u64, 100 * ms), anim.total_duration_ns);

    // Frame 0 holds up to but not including the first boundary.
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(0));
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(10 * ms - 1));

    // The boundary instant already belongs to the frame that starts there.
    try std.testing.expectEqual(@as(usize, 1), anim.activeFrameAt(10 * ms));
    try std.testing.expectEqual(@as(usize, 1), anim.activeFrameAt(10 * ms + 1));
    try std.testing.expectEqual(@as(usize, 1), anim.activeFrameAt(35 * ms - 1));
    try std.testing.expectEqual(@as(usize, 2), anim.activeFrameAt(35 * ms));
    try std.testing.expectEqual(@as(usize, 2), anim.activeFrameAt(35 * ms + 1));
    try std.testing.expectEqual(@as(usize, 2), anim.activeFrameAt(40 * ms - 1));
    try std.testing.expectEqual(@as(usize, 3), anim.activeFrameAt(40 * ms));
    try std.testing.expectEqual(@as(usize, 3), anim.activeFrameAt(100 * ms - 1));

    // One full period later the timeline wraps from the last frame to frame 0.
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(100 * ms));
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(100 * ms + 1));
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(200 * ms));
    try std.testing.expectEqual(@as(usize, 2), anim.activeFrameAt(235 * ms));
}

test "api-w14 a single frame sequence holds frame 0 past its own period" {
    const ms = std.time.ns_per_ms;
    var anim = try syntheticSequence(std.testing.allocator, &.{50 * ms});
    defer anim.deinit();

    // One frame has no transition to make, so the selection stays at frame 0
    // inside the period, exactly on it, and arbitrarily far beyond it.
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(0));
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(50 * ms - 1));
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(50 * ms));
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(50 * ms + 1));
    try std.testing.expectEqual(@as(usize, 0), anim.activeFrameAt(50_000 * ms));

    // With no transition to report the deadline still has to sit ahead of now,
    // because a deadline at or before the current instant spins the render loop.
    const deadline = anim.nextDeadline(50 * ms);
    try std.testing.expect(deadline > @as(i96, 50 * ms));
    try std.testing.expectEqual(deadline, anim.nextDeadline(50 * ms));
}

test "api-w14 the next deadline is the next transition and never the current instant" {
    const ms = std.time.ns_per_ms;
    var anim = try syntheticSequence(std.testing.allocator, &.{ 10 * ms, 25 * ms, 5 * ms, 60 * ms });
    defer anim.deinit();

    // Every deadline is a boundary of the uneven timeline: 10, 35, 40, 100 ms.
    try std.testing.expectEqual(@as(i96, 10 * ms), anim.nextDeadline(0));
    try std.testing.expectEqual(@as(i96, 10 * ms), anim.nextDeadline(10 * ms - 1));
    // Standing exactly on a boundary must report the following one, never the
    // instant the caller has already reached.
    try std.testing.expectEqual(@as(i96, 35 * ms), anim.nextDeadline(10 * ms));
    try std.testing.expectEqual(@as(i96, 40 * ms), anim.nextDeadline(35 * ms));
    try std.testing.expectEqual(@as(i96, 100 * ms), anim.nextDeadline(40 * ms));
    try std.testing.expectEqual(@as(i96, 100 * ms), anim.nextDeadline(100 * ms - 1));
    // Past the period the deadline follows the wrap instead of stalling.
    try std.testing.expectEqual(@as(i96, 110 * ms), anim.nextDeadline(100 * ms));
    try std.testing.expectEqual(@as(i96, 135 * ms), anim.nextDeadline(110 * ms));

    // Repeated calls at one instant agree, the deadline is always ahead, and the
    // frame on screen actually changes at it, so it is the transition itself.
    for ([_]i96{ 0, 1, 10 * ms, 10 * ms + 1, 35 * ms, 40 * ms, 99 * ms, 100 * ms, 137 * ms, 235 * ms }) |t| {
        const deadline = anim.nextDeadline(t);
        try std.testing.expectEqual(deadline, anim.nextDeadline(t));
        try std.testing.expectEqual(deadline, anim.nextDeadline(t));
        try std.testing.expect(deadline > t);
        try std.testing.expect(anim.activeFrameAt(deadline) != anim.activeFrameAt(t));
    }
}

test "api-w14 a zero total duration falls back to the default period" {
    const ms = std.time.ns_per_ms;
    const allocator = std.testing.allocator;

    // `total_duration_ns` declares a default of 0, so a struct literal built
    // without `init` reaches the timeline arithmetic with a zero period. The
    // frame durations sum to exactly 100 ms, the default `init` substitutes, so
    // a working fallback has to make both construction paths agree.
    const frames = try syntheticFrameSlice(allocator, &.{ 40 * ms, 60 * ms });
    var literal: image.AnimatedImage = .{ .frames = frames, .allocator = allocator };
    defer literal.deinit();
    try std.testing.expectEqual(@as(u64, 0), literal.total_duration_ns);

    // A zero period used to divide by zero at the modulo and panic here.
    try std.testing.expectEqual(@as(usize, 0), literal.activeFrameAt(0));
    try std.testing.expectEqual(@as(usize, 0), literal.activeFrameAt(40 * ms - 1));
    try std.testing.expectEqual(@as(usize, 1), literal.activeFrameAt(40 * ms));
    try std.testing.expectEqual(@as(usize, 1), literal.activeFrameAt(100 * ms - 1));
    // The default period is what wraps, rather than an unbounded timeline.
    try std.testing.expectEqual(@as(usize, 0), literal.activeFrameAt(100 * ms));
    try std.testing.expectEqual(@as(usize, 0), literal.activeFrameAt(200 * ms));

    // Deadlines follow the default period and never land at or before now.
    try std.testing.expectEqual(@as(i96, 40 * ms), literal.nextDeadline(0));
    try std.testing.expectEqual(@as(i96, 100 * ms), literal.nextDeadline(40 * ms));
    try std.testing.expectEqual(@as(i96, 140 * ms), literal.nextDeadline(100 * ms));
    try std.testing.expectEqual(@as(i96, 140 * ms), literal.nextDeadline(120 * ms));

    // The same frames through `init` reach an identical timeline, so the
    // fallback is the documented default and not a period of its own.
    var initialized = try syntheticSequence(allocator, &.{ 40 * ms, 60 * ms });
    defer initialized.deinit();
    try std.testing.expectEqual(@as(u64, 100 * ms), initialized.total_duration_ns);
    for ([_]i96{ 0, 40 * ms - 1, 40 * ms, 60 * ms, 100 * ms, 120 * ms, 200 * ms }) |t| {
        try std.testing.expectEqual(initialized.activeFrameAt(t), literal.activeFrameAt(t));
        try std.testing.expectEqual(initialized.nextDeadline(t), literal.nextDeadline(t));
    }
}

test "api-w14 deinit releases every frame exactly once" {
    // A fixed buffer keeps the accounting local to the test, so the release
    // count below observes the sequence and nothing else in the process.
    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var ledger: LiveLedger = .{ .inner = fixed.allocator(), .live = @splat(undefined) };
    const allocator = ledger.allocator();

    var anim = try syntheticSequence(allocator, &.{ 10, 20, 30, 40 });
    // Four pixel buffers plus the frame slice.
    try std.testing.expectEqual(@as(usize, 5), ledger.live_count);

    anim.deinit();

    // Nothing outstanding and no second release of the same block, so every
    // frame went back exactly once.
    try std.testing.expectEqual(@as(usize, 0), ledger.live_count);
    try std.testing.expectEqual(@as(usize, 5), ledger.frees);
    try std.testing.expectEqual(@as(usize, 0), ledger.double_frees);

    // Teeth for the live count: skipping one frame must leave a block behind,
    // so a zero above is a real observation and not an unmeasured path.
    var partial = try syntheticSequence(allocator, &.{ 10, 20, 30, 40 });
    for (partial.frames[0..3]) |*frame| frame.deinit();
    try std.testing.expectEqual(@as(usize, 2), ledger.live_count);
    partial.frames[3].deinit();
    allocator.free(partial.frames);
    try std.testing.expectEqual(@as(usize, 0), ledger.live_count);

    // Teeth for the double-free count: releasing one frame twice must be seen.
    var twice = try syntheticSequence(allocator, &.{ 10, 20 });
    const survivor = twice.frames[0].pixels;
    twice.deinit();
    try std.testing.expectEqual(@as(usize, 0), ledger.double_frees);
    allocator.free(survivor);
    try std.testing.expectEqual(@as(usize, 1), ledger.double_frees);
    try std.testing.expectEqual(@as(usize, 0), ledger.live_count);
}

// ── W05 Frame Demand ───────────────────────────────

const ms_ns = std.time.ns_per_ms;

/// Four uneven frames, 10 + 25 + 5 + 60 ms, each in its own heap slot. The
/// uneven durations are the teeth: an accumulator off by one frame, or by one
/// millisecond, lands on the wrong boundary.
const uneven_frames = [_]image_types.ImageFrame{
    .{ .slot = .{ .index = 0, .generation = 3 }, .duration_ns = 10 * ms_ns },
    .{ .slot = .{ .index = 1, .generation = 3 }, .duration_ns = 25 * ms_ns },
    .{ .slot = .{ .index = 2, .generation = 3 }, .duration_ns = 5 * ms_ns },
    .{ .slot = .{ .index = 3, .generation = 3 }, .duration_ns = 60 * ms_ns },
};

test "api-w14 the next image deadline is the next boundary and wraps with the timeline" {
    const sequence: image_types.ImageSequence = .{ .frames = &uneven_frames, .loop = true };

    // 10, 35, 40 and 100 ms are the four boundaries of this timeline.
    try std.testing.expectEqual(@as(?u64, 10 * ms_ns), sequence.nextDeadlineNs(0));
    try std.testing.expectEqual(@as(?u64, 10 * ms_ns), sequence.nextDeadlineNs(10 * ms_ns - 1));
    // Standing exactly on a boundary reports the one after it, never the
    // instant the caller has already reached.
    try std.testing.expectEqual(@as(?u64, 35 * ms_ns), sequence.nextDeadlineNs(10 * ms_ns));
    try std.testing.expectEqual(@as(?u64, 40 * ms_ns), sequence.nextDeadlineNs(35 * ms_ns));
    try std.testing.expectEqual(@as(?u64, 100 * ms_ns), sequence.nextDeadlineNs(40 * ms_ns));
    try std.testing.expectEqual(@as(?u64, 100 * ms_ns), sequence.nextDeadlineNs(100 * ms_ns - 1));
    // Past the period the deadline follows the wrap instead of stalling.
    try std.testing.expectEqual(@as(?u64, 110 * ms_ns), sequence.nextDeadlineNs(100 * ms_ns));
    try std.testing.expectEqual(@as(?u64, 240 * ms_ns), sequence.nextDeadlineNs(235 * ms_ns));

    // Every deadline is a transition: strictly ahead, and a different frame is
    // on screen when it arrives.
    const readings = [_]u64{
        0,          1,          10 * ms_ns,  10 * ms_ns + 1, 35 * ms_ns,
        40 * ms_ns, 99 * ms_ns, 100 * ms_ns, 137 * ms_ns,    235 * ms_ns,
    };
    for (readings) |elapsed| {
        const deadline = sequence.nextDeadlineNs(elapsed).?;
        try std.testing.expect(deadline > elapsed);
        try std.testing.expect(!sequence.frameAt(elapsed).?.slot.eql(sequence.frameAt(deadline).?.slot));
    }

    // A single frame has no transition to report, and an empty timeline has no
    // frame to owe anything for.
    const single = [_]image_types.ImageFrame{
        .{ .slot = .{ .index = 0, .generation = 1 }, .duration_ns = 50 * ms_ns },
    };
    try std.testing.expectEqual(
        @as(?u64, null),
        (image_types.ImageSequence{ .frames = &single }).nextDeadlineNs(0),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        (image_types.ImageSequence{ .frames = &.{} }).nextDeadlineNs(0),
    );

    // The last boundary of a non-looping image is its end: the deadline stops
    // there and the sequence reports itself complete.
    const once: image_types.ImageSequence = .{ .frames = &uneven_frames, .loop = false };
    try std.testing.expectEqual(@as(?u64, 100 * ms_ns), once.nextDeadlineNs(100 * ms_ns - 1));
    try std.testing.expectEqual(@as(?u64, null), once.nextDeadlineNs(100 * ms_ns));
    try std.testing.expect(once.isComplete(100 * ms_ns));
    try std.testing.expect(!once.isComplete(100 * ms_ns - 1));
}

test "api-w14 the published timelines owe one deadline and a finished image owes none" {
    const owner: WidgetId = .{ .owner = 7, .slot = 1, .generation = 2 };
    var requests = image_types.FrameRequests.init(std.testing.allocator, 7);
    defer requests.deinit();

    const once: image_types.ImageSequence = .{ .frames = &uneven_frames, .loop = false };
    try requests.publish(owner, once, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), requests.count());

    const first = requests.demand(0);
    try std.testing.expect(first.active);
    try std.testing.expectEqual(@as(?u64, 10), first.deadline_ms);
    try std.testing.expectEqual(@as(?u64, 35), requests.demand(10 * ms_ns).deadline_ms);
    try std.testing.expectEqual(@as(?u64, 40), requests.demand(35 * ms_ns).deadline_ms);
    try std.testing.expectEqual(@as(?u64, 100), requests.demand(40 * ms_ns).deadline_ms);

    // After the end of a non-looping image nothing is owed, at that instant or
    // arbitrarily later, so the window it lived in can go back to sleep.
    const ended = requests.demand(100 * ms_ns);
    try std.testing.expectEqual(@as(?u64, null), ended.deadline_ms);
    try std.testing.expect(!ended.active);
    try std.testing.expectEqual(@as(?u64, null), requests.demand(10_000 * ms_ns).deadline_ms);

    // Retiring the owner is the other way the loop stops: a looping image whose
    // source is gone owes nothing either.
    try requests.publish(owner, .{ .frames = &uneven_frames, .loop = true }, 0, 0);
    try std.testing.expectEqual(@as(?u64, 10), requests.demand(0).deadline_ms);
    requests.retire(owner);
    try std.testing.expectEqual(@as(usize, 0), requests.count());
    try std.testing.expectEqual(@as(?u64, null), requests.demand(0).deadline_ms);
}

test "api-w14 the earliest image wins the wake and a foreign owner is refused" {
    const early: WidgetId = .{ .owner = 5, .slot = 1, .generation = 1 };
    const later: WidgetId = .{ .owner = 5, .slot = 2, .generation = 1 };
    var requests = image_types.FrameRequests.init(std.testing.allocator, 5);
    defer requests.deinit();

    const quick = [_]image_types.ImageFrame{
        .{ .slot = .{ .index = 0, .generation = 1 }, .duration_ns = 10 * ms_ns },
        .{ .slot = .{ .index = 1, .generation = 1 }, .duration_ns = 90 * ms_ns },
    };
    const patient = [_]image_types.ImageFrame{
        .{ .slot = .{ .index = 2, .generation = 1 }, .duration_ns = 60 * ms_ns },
        .{ .slot = .{ .index = 3, .generation = 1 }, .duration_ns = 60 * ms_ns },
    };
    try requests.publish(later, .{ .frames = &patient }, 0, 0);
    try requests.publish(early, .{ .frames = &quick }, 0, 0);
    try std.testing.expectEqual(@as(?u64, 10), requests.demand(0).deadline_ms);

    // With the early image gone, the later one is what the host waits for.
    requests.retire(early);
    try std.testing.expectEqual(@as(usize, 1), requests.count());
    try std.testing.expectEqual(@as(?u64, 60), requests.demand(0).deadline_ms);

    // A handle from another window can neither add a wake nor silence a live
    // image, because an entry only ever belongs to its own owner.
    const foreign: WidgetId = .{ .owner = 6, .slot = 1, .generation = 1 };
    try std.testing.expectError(
        error.WrongOwner,
        requests.publish(foreign, .{ .frames = &quick }, 0, 0),
    );
    requests.retire(foreign);
    try std.testing.expectEqual(@as(usize, 1), requests.count());
    try std.testing.expectEqual(@as(?u64, 60), requests.demand(0).deadline_ms);
}

test "api-w14 an idle frame demand sleeps to the image deadline and stops at the end" {
    const owner: WidgetId = .{ .owner = 9, .slot = 4, .generation = 1 };
    var requests = image_types.FrameRequests.init(std.testing.allocator, 9);
    defer requests.deinit();

    var demand: FrameDemand = .{};
    // Consume the one frame an idle window starts dirty with, so everything
    // below is an idle host: no layout, paint, presentation or continuous flag.
    _ = demand.take(0).?;
    demand.finish(true);

    const once: image_types.ImageSequence = .{ .frames = &uneven_frames, .loop = false };
    var view: ImageView = .{
        .intrinsic = .{ .width = 8, .height = 8 },
        .source = .{ .animating = once },
        .generation = 3,
        .elapsed_ns = 0,
    };
    try view.requestFrameAt(owner, &requests, &demand, 0);
    try std.testing.expectEqual(@as(?u64, 10), demand.deadline_ms);

    // Walk every boundary of the timeline: sleep exactly that long, paint
    // there and never between.
    const boundaries = [_]u64{ 10, 35, 40, 100 };
    var now_ns: u64 = 0;
    for (boundaries, 0..) |deadline_ms, position| {
        const now_ms = now_ns / ms_ns;
        try std.testing.expectEqual(
            @as(?u31, @intCast(deadline_ms - now_ms)),
            demand.waitMilliseconds(now_ms),
        );
        try std.testing.expect(demand.take(deadline_ms - 1) == null);
        const work = demand.take(deadline_ms).?;
        try std.testing.expect(work.animation);
        try std.testing.expect(work.paint and work.present);
        try std.testing.expect(!work.layout);
        demand.finish(true);

        now_ns = deadline_ms * ms_ns;
        view.elapsed_ns = now_ns;
        try view.requestFrameAt(owner, &requests, &demand, now_ns);
        // The frame that reaches the screen is the one the deadline named, one
        // nanosecond before it was still the old one. The LAST deadline of a
        // non-looping image is its end rather than a change of frame, so there
        // the final frame stays instead of wrapping.
        const before = once.frameAt(now_ns - 1).?;
        const after = once.frameAt(now_ns).?;
        if (position + 1 == boundaries.len) {
            try std.testing.expect(before.slot.eql(after.slot));
        } else {
            try std.testing.expect(!before.slot.eql(after.slot));
        }
    }

    // The image is over: the entry is still published and its last frame is
    // still the one the element paints, but it owes no wake, so the host that
    // was sleeping on it stays asleep.
    try std.testing.expectEqual(@as(usize, 1), requests.count());
    try std.testing.expectEqual(@as(?u64, null), demand.deadline_ms);
    try std.testing.expectEqual(@as(?u31, null), demand.waitMilliseconds(100));
    try std.testing.expect(demand.take(100) == null);
    try std.testing.expect(once.isComplete(view.elapsed_ns));
}

test "api-w14 a removed or stale image source stops the frame request" {
    const owner: WidgetId = .{ .owner = 11, .slot = 1, .generation = 1 };
    var requests = image_types.FrameRequests.init(std.testing.allocator, 11);
    defer requests.deinit();
    var demand: FrameDemand = .{};
    _ = demand.take(0).?;
    demand.finish(true);

    var view: ImageView = .{
        .intrinsic = .{ .width = 8, .height = 8 },
        .source = .{ .animating = .{ .frames = &uneven_frames } },
        .generation = 3,
        .elapsed_ns = 0,
    };
    // The host loop replaces its own deadline first and lets each element
    // merge into it, which is the order the window driver uses for the scalar
    // animation registry. A source that owes nothing therefore leaves the host
    // idle instead of leaving a wake from an earlier frame behind.
    demand.setDeadline(null);
    try view.requestFrameAt(owner, &requests, &demand, 0);
    try std.testing.expectEqual(@as(usize, 1), requests.count());
    try std.testing.expectEqual(@as(?u64, 10), demand.deadline_ms);

    // Slots from another generation paint the pending fill, so their timeline
    // must not keep the host awake.
    view.generation = 4;
    demand.setDeadline(null);
    try view.requestFrameAt(owner, &requests, &demand, 0);
    try std.testing.expectEqual(@as(usize, 0), requests.count());
    try std.testing.expectEqual(@as(?u64, null), demand.deadline_ms);

    // A released, failed or still-loading source is the same case.
    for ([_]ImageSource{ .pending, .failed, .{ .ready = .{ .index = 0, .generation = 3 } } }) |source| {
        view.generation = 3;
        view.source = source;
        demand.setDeadline(null);
        try view.requestFrameAt(owner, &requests, &demand, 0);
        try std.testing.expectEqual(@as(usize, 0), requests.count());
        try std.testing.expectEqual(@as(?u64, null), demand.deadline_ms);
    }

    // A timeline the element would refuse to paint is refused as a wake too.
    view.source = .{ .animating = .{ .frames = &.{} } };
    demand.setDeadline(null);
    try view.requestFrameAt(owner, &requests, &demand, 0);
    try std.testing.expectEqual(@as(usize, 0), requests.count());
    try std.testing.expectEqual(@as(?u64, null), demand.deadline_ms);
}

test "api-w14 a sub-millisecond boundary wakes the host late, not early" {
    const owner: WidgetId = .{ .owner = 13, .slot = 1, .generation = 1 };
    var requests = image_types.FrameRequests.init(std.testing.allocator, 13);
    defer requests.deinit();
    var demand: FrameDemand = .{};
    _ = demand.take(0).?;
    demand.finish(true);

    // 1.5 ms then 2.5 ms: the first boundary falls between two millisecond
    // readings, so a deadline rounded down would repaint the frame that is
    // still on screen.
    const frames = [_]image_types.ImageFrame{
        .{ .slot = .{ .index = 0, .generation = 6 }, .duration_ns = 1_500_000 },
        .{ .slot = .{ .index = 1, .generation = 6 }, .duration_ns = 2_500_000 },
    };
    const sequence: image_types.ImageSequence = .{ .frames = &frames };
    var view: ImageView = .{
        .intrinsic = .{ .width = 4, .height = 4 },
        .source = .{ .animating = sequence },
        .generation = 6,
    };
    try view.requestFrameAt(owner, &requests, &demand, 0);
    try std.testing.expectEqual(@as(?u64, 2), demand.deadline_ms);
    try std.testing.expect(demand.take(1) == null);
    const work = demand.take(2).?;
    try std.testing.expect(work.animation);
    demand.finish(true);
    try std.testing.expect(!sequence.frameAt(1 * ms_ns).?.slot.eql(sequence.frameAt(2 * ms_ns).?.slot));

    // The conversion rounds a whole millisecond to itself and saturates
    // instead of wrapping an absurd deadline to zero, which would fire at once.
    try std.testing.expectEqual(@as(u64, 0), image_types.ceilMilliseconds(0));
    try std.testing.expectEqual(@as(u64, 1), image_types.ceilMilliseconds(ms_ns));
    try std.testing.expectEqual(@as(u64, 2), image_types.ceilMilliseconds(ms_ns + 1));
    const saturated = image_types.ceilMilliseconds(std.math.maxInt(u64));
    try std.testing.expect(saturated > std.math.maxInt(u64) / ms_ns);
    var far: FrameDemand = .{};
    _ = far.take(0).?;
    far.finish(true);
    far.setDeadline(saturated);
    try std.testing.expectEqual(std.math.maxInt(u31), far.waitMilliseconds(0).?);
    try std.testing.expect(far.take(1) == null);
}

// ── Registry and Raster Cache Ownership Tests ─────────────────────

/// Counts how often a producer's buffer went back to it, so a test can see a
/// descriptor that was returned twice or not at all.
const CountingFrameContext = struct {
    releases: u32 = 0,

    pub fn releaseCallback(ctx: ?*anyopaque) void {
        const self: *CountingFrameContext = @ptrCast(@alignCast(ctx.?));
        self.releases += 1;
    }
};

/// The owner a sequence asks where an uploaded frame landed. It records the
/// handle it was handed and can refuse it, which is the path that must give the
/// frame back and leave the pixels to the registry.
const SlotOwner = struct {
    refuse: bool = true,
    last_handle: frame_source.TextureHandle = .invalid,

    pub fn map(
        context: ?*anyopaque,
        handle: frame_source.TextureHandle,
    ) anyerror!image_types.TextureSlot {
        const self: *SlotOwner = @ptrCast(@alignCast(context.?));
        self.last_handle = handle;
        if (self.refuse) return error.SlotUnavailable;
        return handle;
    }
};

/// Offers one caller-owned frame of `pixels` to the source.
fn pushTestFrame(
    source: *frame_source.FrameSource,
    producer: *CountingFrameContext,
    pixels: []const u8,
) !void {
    const frame: FrameDescriptor = .{
        .width = @intCast(pixels.len / 4),
        .height = 1,
        .format = .rgba8,
        .stride = @intCast(pixels.len),
        .pixels = pixels.ptr,
        .release_fn = CountingFrameContext.releaseCallback,
        .release_ctx = producer,
    };
    try source.pushFrame(frame);
}

/// A one-row RGBA surface filled with `fill`, owned by the caller until a
/// cache takes it.
fn testRaster(len: usize, fill: u8) !svg.DecodedImage {
    const pixels = try std.testing.allocator.alloc(u8, len);
    @memset(pixels, fill);
    return .{
        .width = @intCast(len / 4),
        .height = 1,
        .stride = @intCast(len),
        .pixels = pixels,
        .allocator = std.testing.allocator,
    };
}

test "api-w14 sequence ownership: a refused slot mapper returns the frame once and leaves the pixels to the registry" {
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 4);
    defer source.deinit() catch unreachable;

    var registry = image.TextureRegistry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();

    var producer: CountingFrameContext = .{};
    const pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    try pushTestFrame(&source, &producer, &pixels);

    var owner: SlotOwner = .{};
    var sequence = frame_source.AnimatedSequence.init(&source, &registry, .{
        .slot_mapper = SlotOwner.map,
        .mapper_context = &owner,
    });
    defer sequence.deinit();

    try std.testing.expectError(error.SlotUnavailable, sequence.submitNext());

    // The refused frame went back to its producer exactly once, which is what
    // lets the source be torn down instead of waiting for a return.
    try std.testing.expectEqual(@as(u32, 1), producer.releases);
    try std.testing.expectEqual(@as(u32, 0), source.outstandingFrames());

    // From `insert` onwards the registry owns the pixels. A refusal retires
    // the slot; it does not free what the registry still holds.
    const stored = registry.get(owner.last_handle) orelse return error.RetiredTooEarly;
    try std.testing.expectEqualSlices(u8, &pixels, stored.pixels);

    // Freeing them is the registry's own retirement rule: two presented
    // frames, and then once, here rather than in the refused submit.
    registry.onFramePresented(0);
    try std.testing.expect(registry.get(owner.last_handle) != null);
    registry.onFramePresented(1);
    try std.testing.expect(registry.get(owner.last_handle) != null);
    registry.onFramePresented(2);
    try std.testing.expect(registry.get(owner.last_handle) == null);

    // A refused submit installed nothing, so tearing the sequence down retires
    // nothing and returns no frame a second time.
    try std.testing.expectEqual(@as(u32, 1), producer.releases);
}

test "api-w14 sequence ownership: an installed sequence keeps its registry slots until it is torn down" {
    var source = frame_source.FrameSource.init(std.testing.allocator, std.testing.io, 4);
    defer source.deinit() catch unreachable;

    var registry = image.TextureRegistry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();

    var producer: CountingFrameContext = .{};
    const first_pixels = [_]u8{ 1, 2, 3, 4 };
    const second_pixels = [_]u8{ 5, 6, 7, 8 };
    try pushTestFrame(&source, &producer, &first_pixels);
    try pushTestFrame(&source, &producer, &second_pixels);

    var owner: SlotOwner = .{ .refuse = false };
    var sequence = frame_source.AnimatedSequence.init(&source, &registry, .{
        .slot_mapper = SlotOwner.map,
        .mapper_context = &owner,
    });

    try std.testing.expect(try sequence.submitNext());
    try std.testing.expect(try sequence.submitNext());
    // The producer has nothing left, so the third call installs no frame.
    try std.testing.expect(!try sequence.submitNext());

    // Both acquired frames came back through the source, so nothing is left
    // outstanding for the provider to account for.
    try std.testing.expectEqual(@as(u32, 2), producer.releases);
    try std.testing.expectEqual(@as(u32, 0), source.outstandingFrames());

    const first = sequence.registryHandle(0);
    const second = sequence.registryHandle(1);
    const timeline = sequence.timeline();
    try std.testing.expect(timeline.isValid());
    try std.testing.expectEqual(@as(usize, 2), timeline.frames.len);
    // Two installed frames are two registry slots, never one slot twice.
    try std.testing.expect(!first.eql(second));

    sequence.deinit();

    // Retirement is what frees an installed slot, and it takes two presented
    // frames; a borrowed timeline samples the real pixels until then.
    registry.onFramePresented(0);
    try std.testing.expect(registry.get(first) != null);
    registry.onFramePresented(1);
    try std.testing.expect(registry.get(first) != null);
    registry.onFramePresented(2);
    try std.testing.expect(registry.get(first) == null);
    try std.testing.expect(registry.get(second) == null);
}

test "api-w14 raster cache ownership: a pinned raster keeps its address while the cache grows" {
    var cache = svg.SvgRasterCache.init(std.testing.allocator, std.testing.io, 1 << 16);
    defer cache.deinit();

    const key: svg.SvgCacheKey = .{ .svg_hash = 0x1111, .viewport_width = 16, .viewport_height = 16 };
    try cache.put(key, try testRaster(4, 0xAB), 0);
    const held = cache.pin(key, 1) orelse return error.PinFailed;

    // Unrelated keys rehash the cache several times over. The pinned surface
    // has to stay the same storage, not a pointer into a moved or freed table.
    var index: u64 = 0;
    while (index < 256) : (index += 1) {
        const other: svg.SvgCacheKey = .{
            .svg_hash = 0x2222 + index,
            .viewport_width = 16,
            .viewport_height = 16,
        };
        try cache.put(other, try testRaster(4, @truncate(index)), @intCast(2 + index));
    }

    try std.testing.expect(held == cache.pin(key, 300).?);
    try std.testing.expectEqual(@as(u8, 0xAB), held.pixels[0]);
    try std.testing.expectEqual(@as(usize, 4 * 257), cache.used());
    cache.unpin(key);
    cache.unpin(key);
}

test "api-w14 raster cache ownership: a pinned raster refuses a same-key replacement" {
    var cache = svg.SvgRasterCache.init(std.testing.allocator, std.testing.io, 64);
    defer cache.deinit();

    const key: svg.SvgCacheKey = .{ .svg_hash = 0x3333, .viewport_width = 8, .viewport_height = 8 };
    try cache.put(key, try testRaster(4, 0x11), 0);
    const held = cache.pin(key, 1) orelse return error.PinFailed;

    var refused = try testRaster(4, 0x22);
    try std.testing.expectError(error.EntryPinned, cache.put(key, refused, 2));

    // Both sides of that refusal are intact: the pinned surface still reads as
    // the original, and the refused surface is still the caller's to free.
    try std.testing.expectEqual(@as(usize, 4), cache.used());
    try std.testing.expectEqual(@as(u8, 0x11), held.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0x22), refused.pixels[0]);
    refused.deinit();

    // With the pin gone the swap goes through, and what the cache serves after
    // it is the surface the caller handed over.
    cache.unpin(key);
    try cache.put(key, try testRaster(4, 0x33), 3);
    const replaced = cache.pin(key, 4) orelse return error.PinFailed;
    try std.testing.expectEqual(@as(u8, 0x33), replaced.pixels[0]);
    try std.testing.expectEqual(@as(usize, 4), cache.used());
    cache.unpin(key);
}

/// One put under an allocation failure: a put either takes the surface or hands
/// it straight back, and an entry that was already cached survives both
/// outcomes with its own pin and bytes intact.
fn putTransactionCase(gpa: std.mem.Allocator) !void {
    var cache = svg.SvgRasterCache.init(gpa, std.testing.io, 64);
    defer cache.deinit();

    const live_key: svg.SvgCacheKey = .{ .svg_hash = 0x4444, .viewport_width = 8, .viewport_height = 8 };
    var live = try testRaster(4, 0x44);
    cache.put(live_key, live, 0) catch |err| {
        live.deinit();
        return err;
    };
    const held = cache.pin(live_key, 1) orelse return error.PinFailed;

    const incoming_key: svg.SvgCacheKey = .{ .svg_hash = 0x5555, .viewport_width = 8, .viewport_height = 8 };
    var incoming = try testRaster(4, 0x55);
    var cached = false;
    var refusal: ?anyerror = null;
    if (cache.put(incoming_key, incoming, 2)) |_| {
        // The cache owns the surface now, so the caller must not free it.
        cached = true;
        const stored = cache.pin(incoming_key, 3) orelse return error.NotCached;
        try std.testing.expectEqual(@as(u8, 0x55), stored.pixels[0]);
        cache.unpin(incoming_key);
    } else |err| {
        // Nothing was cached, so the refused surface is still the caller's.
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(cache.pin(incoming_key, 3) == null);
        try std.testing.expectEqual(@as(u8, 0x55), incoming.pixels[0]);
        incoming.deinit();
        refusal = err;
    }

    // Whatever the second put did, the first entry is still cached under its
    // own pin with the same bytes, and the budget accounts for both sides.
    try std.testing.expectEqual(@as(u8, 0x44), held.pixels[0]);
    try std.testing.expectEqual((if (cached) @as(usize, 8) else 4), cache.used());
    cache.unpin(live_key);

    // The refusal is handed back after it has been checked. Swallowing it
    // would report a successful allocation-failure case, which is the one thing
    // this helper exists to rule out.
    if (refusal) |err| return err;
}

test "api-w14 raster cache ownership: every failed put hands the surface back to the caller" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, putTransactionCase, .{});
}

test "api-w14 raster cache ownership: the byte budget evicts the least recently used raster" {
    var cache = svg.SvgRasterCache.init(std.testing.allocator, std.testing.io, 8);
    defer cache.deinit();

    const oldest: svg.SvgCacheKey = .{ .svg_hash = 0x6666, .viewport_width = 8, .viewport_height = 8 };
    const newer: svg.SvgCacheKey = .{ .svg_hash = 0x7777, .viewport_width = 8, .viewport_height = 8 };
    const newest: svg.SvgCacheKey = .{ .svg_hash = 0x8888, .viewport_width = 8, .viewport_height = 8 };
    try cache.put(oldest, try testRaster(4, 0x01), 10);
    try cache.put(newer, try testRaster(4, 0x02), 20);
    try std.testing.expectEqual(@as(usize, 8), cache.used());

    try cache.put(newest, try testRaster(4, 0x03), 30);

    // The least recently used raster made way for the new one, the budget
    // still holds, and the freed surface is not served again.
    try std.testing.expectEqual(@as(usize, 8), cache.used());
    try std.testing.expect(cache.pin(oldest, 31) == null);
    const kept_newer = cache.pin(newer, 31);
    const kept_newest = cache.pin(newest, 31);
    try std.testing.expect(kept_newer != null);
    try std.testing.expect(kept_newest != null);
    cache.unpin(newer);
    cache.unpin(newest);
}

test "api-w14 raster cache budget: a growing same-key replacement evicts another document" {
    var cache = svg.SvgRasterCache.init(std.testing.allocator, std.testing.io, 8);
    defer cache.deinit();

    const replaced: svg.SvgCacheKey = .{ .svg_hash = 0x9999, .viewport_width = 8, .viewport_height = 8 };
    const other: svg.SvgCacheKey = .{ .svg_hash = 0xAAAA, .viewport_width = 8, .viewport_height = 8 };
    try cache.put(replaced, try testRaster(4, 0x10), 10);
    try cache.put(other, try testRaster(4, 0x20), 20);
    try std.testing.expectEqual(@as(usize, 8), cache.used());

    // The document being replaced is both the oldest entry and the storage this
    // put is about to write into, so the eviction sweep has to pass over it and
    // spend some other document instead.
    try cache.put(replaced, try testRaster(8, 0x30), 30);

    try std.testing.expectEqual(@as(usize, 8), cache.used());
    const grown = cache.pin(replaced, 31) orelse return error.ReplacedWasEvicted;
    try std.testing.expectEqual(@as(usize, 8), grown.pixels.len);
    try std.testing.expectEqual(@as(u8, 0x30), grown.pixels[0]);
    cache.unpin(replaced);
    try std.testing.expect(cache.pin(other, 31) == null);
}

test "api-w14 raster cache budget: a refused put under pressure frees nothing" {
    var cache = svg.SvgRasterCache.init(std.testing.allocator, std.testing.io, 12);
    defer cache.deinit();

    const pinned_key: svg.SvgCacheKey = .{ .svg_hash = 0xBBBB, .viewport_width = 8, .viewport_height = 8 };
    const free_key: svg.SvgCacheKey = .{ .svg_hash = 0xCCCC, .viewport_width = 8, .viewport_height = 8 };
    const incoming_key: svg.SvgCacheKey = .{ .svg_hash = 0xDDDD, .viewport_width = 8, .viewport_height = 8 };
    try cache.put(pinned_key, try testRaster(4, 0x40), 10);
    const held = cache.pin(pinned_key, 11) orelse return error.PinFailed;
    try cache.put(free_key, try testRaster(4, 0x50), 20);
    try std.testing.expectEqual(@as(usize, 8), cache.used());

    // Eight bytes held plus a twelve-byte raster do not fit, and the only entry
    // the cache may free is the four bytes it already holds unpinned. Spending
    // them would make the refusal change the cache instead of only the caller's
    // mind.
    var refused = try testRaster(12, 0x60);
    try std.testing.expectError(error.BudgetExceeded, cache.put(incoming_key, refused, 30));

    try std.testing.expectEqual(@as(usize, 8), cache.used());
    const kept_free = cache.pin(free_key, 31);
    try std.testing.expect(kept_free != null);
    if (kept_free) |surface| try std.testing.expectEqual(@as(u8, 0x50), surface.pixels[0]);
    cache.unpin(free_key);
    try std.testing.expectEqual(@as(u8, 0x40), held.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0x60), refused.pixels[0]);
    refused.deinit();
    cache.unpin(pinned_key);
}

// Kept last on purpose: this one reaches an integer underflow in the current
// accounting, and a panic would hide any test after it.
test "api-w14 raster cache budget: a shrinking same-key replacement releases the difference" {
    var cache = svg.SvgRasterCache.init(std.testing.allocator, std.testing.io, 16);
    defer cache.deinit();

    const key: svg.SvgCacheKey = .{ .svg_hash = 0xEEEE, .viewport_width = 16, .viewport_height = 8 };
    try cache.put(key, try testRaster(8, 0x70), 10);
    try cache.put(key, try testRaster(4, 0x80), 20);

    // The freed surface hands four bytes back, and the account says so rather
    // than counting a shrinking swap as if it had grown.
    try std.testing.expectEqual(@as(usize, 4), cache.used());
    const smaller = cache.pin(key, 21) orelse return error.NotCached;
    try std.testing.expectEqual(@as(usize, 4), smaller.pixels.len);
    try std.testing.expectEqual(@as(u8, 0x80), smaller.pixels[0]);
    cache.unpin(key);

    // The budget really is free again: another eight bytes still fit beside it.
    const later: svg.SvgCacheKey = .{ .svg_hash = 0xFFFF, .viewport_width = 16, .viewport_height = 8 };
    try cache.put(later, try testRaster(8, 0x90), 30);
    try std.testing.expectEqual(@as(usize, 12), cache.used());
}
