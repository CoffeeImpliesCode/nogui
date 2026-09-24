const std = @import("std");
const clipboard = @import("clipboard.zig");

const png_header = [_]u8{
    0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
    0,    0,   0,   13,  'I',  'H',  'D',  'R',
    0,    0,   0,   1,   0,    0,    0,    1,
};

test "api-w18 clipboard item owns all MIME bytes after the caller changes its buffers" {
    var text = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var png = png_header;
    var json = [_]u8{ '{', '"', 'i', 'd', '"', ':', '1', '}' };
    var item = try clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = &text },
        .{ .format = .image_png, .bytes = &png },
        .{ .format = .metadata_json, .bytes = &json },
    });
    defer item.deinit();

    text[0] = 'X';
    png[0] = 0;
    json[6] = '2';
    try std.testing.expectEqualStrings("hello", item.get(.text_utf8).?);
    try std.testing.expectEqualSlices(u8, &png_header, item.get(.image_png).?);
    try std.testing.expectEqualStrings("{\"id\":1}", item.get(.metadata_json).?);
    try std.testing.expect(item.has(.text_utf8));
    try std.testing.expect(item.has(.image_png));
    try std.testing.expect(item.has(.metadata_json));
}

test "api-w18 replacing an item frees its former formats without changing the new item" {
    var item = try clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "first" },
        .{ .format = .image_png, .bytes = &png_header },
    });
    var replacement = try clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "second" },
        .{ .format = .metadata_json, .bytes = "{\"version\":2}" },
    });
    item.deinit();
    item = replacement;
    defer item.deinit();
    replacement = undefined;

    try std.testing.expectEqualStrings("second", item.get(.text_utf8).?);
    try std.testing.expect(item.get(.image_png) == null);
    try std.testing.expectEqualStrings("{\"version\":2}", item.get(.metadata_json).?);
}

test "api-w18 clipboard item distinguishes absent and empty text" {
    var item = try clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "" },
    });
    defer item.deinit();
    try std.testing.expect(item.has(.text_utf8));
    try std.testing.expectEqual(@as(usize, 0), item.get(.text_utf8).?.len);
    try std.testing.expect(!item.has(.image_png));
    try std.testing.expect(item.get(.image_png) == null);
}

test "api-w18 clipboard item rejects duplicate formats and mislabeled payloads" {
    try std.testing.expectError(error.EmptyItem, clipboard.Item.init(std.testing.allocator, &.{}));
    try std.testing.expectError(error.DuplicateFormat, clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "first" },
        .{ .format = .text_utf8, .bytes = "second" },
    }));
    try std.testing.expectError(error.InvalidText, clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "a\x00b" },
    }));
    try std.testing.expectError(error.InvalidText, clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "\xff" },
    }));
    try std.testing.expectError(error.InvalidPng, clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .image_png, .bytes = "not png" },
    }));
    try std.testing.expectError(error.InvalidMetadata, clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .metadata_json, .bytes = "{invalid" },
    }));
}

test "api-w18 offer data callback serves requested mime types and handles empty vs absent" {
    const item = try clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "hello world" },
        .{ .format = .image_png, .bytes = &png_header },
        .{ .format = .metadata_json, .bytes = "{\"key\":123}" },
    });
    const offer = try clipboard.Offer.init(std.testing.allocator, item);
    defer offer.deinit();

    // Standard UTF-8 text mime query
    var size: usize = 0;
    const text_ptr = clipboard.Offer.dataCallback(offer, "text/plain;charset=utf-8", &size);
    try std.testing.expect(text_ptr != null);
    try std.testing.expectEqual(@as(usize, 11), size);
    const text_slice = @as([*]const u8, @ptrCast(text_ptr.?))[0..size];
    try std.testing.expectEqualStrings("hello world", text_slice);

    // text/plain alias query
    const plain_ptr = clipboard.Offer.dataCallback(offer, "text/plain", &size);
    try std.testing.expect(plain_ptr != null);
    try std.testing.expectEqual(@as(usize, 11), size);
    const plain_slice = @as([*]const u8, @ptrCast(plain_ptr.?))[0..size];
    try std.testing.expectEqualStrings("hello world", plain_slice);

    // PNG query
    const png_ptr = clipboard.Offer.dataCallback(offer, "image/png", &size);
    try std.testing.expect(png_ptr != null);
    try std.testing.expectEqual(png_header.len, size);
    const png_slice = @as([*]const u8, @ptrCast(png_ptr.?))[0..size];
    try std.testing.expectEqualSlices(u8, &png_header, png_slice);

    // JSON metadata query
    const json_ptr = clipboard.Offer.dataCallback(offer, "application/json", &size);
    try std.testing.expect(json_ptr != null);
    // The data callback reports the exact owned payload length in bytes: the
    // item owns the duped "{\"key\":123}" (11 bytes). No terminator, no padding.
    try std.testing.expectEqual(@as(usize, 11), size);
    const json_slice = @as([*]const u8, @ptrCast(json_ptr.?))[0..size];
    try std.testing.expectEqualStrings("{\"key\":123}", json_slice);

    // Unrecognized or unoffered MIME query returns null
    try std.testing.expect(clipboard.Offer.dataCallback(offer, "audio/wav", &size) == null);
    try std.testing.expect(clipboard.Offer.dataCallback(offer, null, &size) == null);

    // Clean up via SDL callback. The deferred deinit releases the handle.
    clipboard.Offer.cleanupCallback(offer);
}

test "api-w18 offer data callback handles empty text with size 0 and valid pointer" {
    const item = try clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "" },
    });
    const offer = try clipboard.Offer.init(std.testing.allocator, item);
    defer offer.deinit();

    var size: usize = 999;
    const ptr = clipboard.Offer.dataCallback(offer, "text/plain", &size);
    try std.testing.expect(ptr != null);
    try std.testing.expectEqual(@as(usize, 0), size);

    // Absent format returns null
    try std.testing.expect(clipboard.Offer.dataCallback(offer, "image/png", &size) == null);

    clipboard.Offer.cleanupCallback(offer);
}

test "api-w18 offer lifetime survives caller buffer mutation and item deinit" {
    var buffer = [_]u8{ 'a', 'b', 'c', 'd' };
    var item = try clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = &buffer },
    });

    const offer = try clipboard.Offer.initClone(std.testing.allocator, &item);
    defer offer.deinit();

    // Mutate caller buffer and deinit caller item
    buffer[0] = 'z';
    item.deinit();

    var size: usize = 0;
    const ptr = clipboard.Offer.dataCallback(offer, "text/plain", &size);
    try std.testing.expect(ptr != null);
    try std.testing.expectEqual(@as(usize, 4), size);
    const slice = @as([*]const u8, @ptrCast(ptr.?))[0..size];
    try std.testing.expectEqualStrings("abcd", slice);

    clipboard.Offer.cleanupCallback(offer);
}

test "api-w18 offer cleanup deactivates callbacks and prevents exposing freed bytes" {
    const item = try clipboard.Item.init(std.testing.allocator, &.{
        .{ .format = .text_utf8, .bytes = "ephemeral" },
    });
    var offer = try clipboard.Offer.init(std.testing.allocator, item);
    defer offer.deinit();

    try std.testing.expect(offer.active.load(.acquire));
    clipboard.Offer.cleanupCallback(offer);

    // The handle survives cleanup as an inert tombstone: it rejects every data
    // request and writes no size, so no released byte is ever exposed.
    try std.testing.expect(!offer.active.load(.acquire));
    var size: usize = 0;
    try std.testing.expect(clipboard.Offer.dataCallback(offer, "text/plain", &size) == null);
    try std.testing.expectEqual(@as(usize, 0), size);
}

test "api-w18 format mime mapping handles standard aliases and normalization" {
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", clipboard.Format.text_utf8.mime());
    try std.testing.expectEqualStrings("image/png", clipboard.Format.image_png.mime());
    try std.testing.expectEqualStrings("application/json", clipboard.Format.metadata_json.mime());

    try std.testing.expectEqual(clipboard.Format.text_utf8, clipboard.Format.fromMime("text/plain").?);
    try std.testing.expectEqual(clipboard.Format.text_utf8, clipboard.Format.fromMime("text/plain;charset=utf-8").?);
    try std.testing.expectEqual(clipboard.Format.text_utf8, clipboard.Format.fromMime("TEXT/PLAIN").?);
    try std.testing.expectEqual(clipboard.Format.text_utf8, clipboard.Format.fromMime("UTF8_STRING").?);
    try std.testing.expectEqual(clipboard.Format.text_utf8, clipboard.Format.fromMime("text/plain; charset=UTF-8").?);
    try std.testing.expectEqual(clipboard.Format.image_png, clipboard.Format.fromMime("image/png").?);
    try std.testing.expectEqual(clipboard.Format.metadata_json, clipboard.Format.fromMime("application/json").?);
    try std.testing.expect(clipboard.Format.fromMime("unknown/binary") == null);
}

test "api-w18 item clone produces independent copy and helpers work" {
    var item = try clipboard.Item.fromText(std.testing.allocator, "independent text");
    defer item.deinit();

    try std.testing.expectEqualStrings("independent text", item.text().?);
    try std.testing.expect(item.imagePng() == null);
    try std.testing.expect(item.metadataJson() == null);
    try std.testing.expectEqual(@as(usize, 1), item.count());

    var cloned = try item.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expectEqualStrings("independent text", cloned.text().?);
    try std.testing.expectEqual(@as(usize, 1), cloned.count());
}

test "api-w18 selection and capability types are separate contracts" {
    try std.testing.expect(clipboard.Selection.clipboard != clipboard.Selection.primary);
    const cap: clipboard.Capability = .{ .primary_selection = false };
    try std.testing.expect(!cap.primary_selection);
}
