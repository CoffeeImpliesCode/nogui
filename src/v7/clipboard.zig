//! Core clipboard data types, MIME validation, item ownership and offer lifetime.
const std = @import("std");

/// Canonical MIME formats supported across all nogui platforms.
pub const Format = enum {
    text_utf8,
    image_png,
    metadata_json,

    pub const count = @typeInfo(Format).@"enum".fields.len;

    /// Primary standard MIME type string with null terminator.
    pub fn mime(self: Format) [:0]const u8 {
        return switch (self) {
            .text_utf8 => "text/plain;charset=utf-8",
            .image_png => "image/png",
            .metadata_json => "application/json",
        };
    }

    /// Match a requested MIME type string, including common platform aliases.
    pub fn fromMime(raw: []const u8) ?Format {
        if (std.ascii.eqlIgnoreCase(raw, "text/plain;charset=utf-8") or
            std.ascii.eqlIgnoreCase(raw, "text/plain") or
            std.ascii.eqlIgnoreCase(raw, "UTF8_STRING") or
            std.ascii.eqlIgnoreCase(raw, "text/plain;charset=UTF-8") or
            std.ascii.eqlIgnoreCase(raw, "text/plain; charset=utf-8") or
            std.ascii.eqlIgnoreCase(raw, "text/plain; charset=UTF-8"))
        {
            return .text_utf8;
        }
        if (std.ascii.eqlIgnoreCase(raw, "image/png")) {
            return .image_png;
        }
        if (std.ascii.eqlIgnoreCase(raw, "application/json")) {
            return .metadata_json;
        }
        return null;
    }
};

/// Separate target selection domains.
pub const Selection = enum {
    clipboard,
    primary,
};

/// Explicit capability reporting for host clipboard services.
pub const Capability = struct {
    primary_selection: bool = false,
};

/// Format-tagged payload entry for initializing a clipboard item.
pub const Entry = struct {
    format: Format,
    bytes: []const u8,
};

/// Validation and allocation errors for clipboard items and offers.
pub const Error = error{
    EmptyItem,
    DuplicateFormat,
    InvalidText,
    InvalidPng,
    InvalidMetadata,
    OutOfMemory,
    UnsupportedCapability,
};

/// An item owns its payload bytes across all contained formats.
/// Mutating the caller's source buffers after `init` does not affect the item.
pub const Item = struct {
    allocator: std.mem.Allocator,
    slots: [Format.count]?[]const u8,

    /// Create an item from a list of format entries.
    /// Deep-copies all MIME bytes and validates payloads.
    pub fn init(allocator: std.mem.Allocator, entries: []const Entry) Error!Item {
        if (entries.len == 0) return error.EmptyItem;

        var seen = [_]bool{false} ** Format.count;
        for (entries) |entry| {
            const idx = @intFromEnum(entry.format);
            if (seen[idx]) return error.DuplicateFormat;
            seen[idx] = true;

            switch (entry.format) {
                .text_utf8 => {
                    if (!std.unicode.utf8ValidateSlice(entry.bytes)) return error.InvalidText;
                    if (std.mem.indexOfScalar(u8, entry.bytes, 0) != null) return error.InvalidText;
                },
                .image_png => {
                    const png_magic = "\x89PNG\r\n\x1a\n";
                    if (entry.bytes.len < png_magic.len or
                        !std.mem.eql(u8, entry.bytes[0..png_magic.len], png_magic))
                    {
                        return error.InvalidPng;
                    }
                },
                .metadata_json => {
                    const is_valid = std.json.validate(allocator, entry.bytes) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    if (!is_valid) return error.InvalidMetadata;
                },
            }
        }

        var slots = [_]?[]const u8{null} ** Format.count;
        errdefer {
            for (&slots) |*slot| {
                if (slot.*) |b| {
                    allocator.free(b);
                    slot.* = null;
                }
            }
        }

        for (entries) |entry| {
            const duped = try allocator.dupe(u8, entry.bytes);
            slots[@intFromEnum(entry.format)] = duped;
        }

        return .{
            .allocator = allocator,
            .slots = slots,
        };
    }

    /// Free all format byte buffers owned by this item.
    /// Afterwards the item rejects access: `get` returns null and `has` false.
    /// Idempotent.
    pub fn deinit(self: *Item) void {
        for (&self.slots) |*slot| {
            if (slot.*) |bytes| {
                self.allocator.free(bytes);
                slot.* = null;
            }
        }
        self.* = undefined;
    }

    /// Retrieve the payload for a format, or null if absent.
    /// Distinguishes an absent format (null) from an empty payload (len == 0).
    pub fn get(self: *const Item, format: Format) ?[]const u8 {
        return self.slots[@intFromEnum(format)];
    }

    /// Query whether this format is present in the item.
    pub fn has(self: *const Item, format: Format) bool {
        return self.slots[@intFromEnum(format)] != null;
    }

    /// Create an independent deep copy of this item.
    pub fn clone(self: *const Item, allocator: std.mem.Allocator) !Item {
        var slots = [_]?[]const u8{null} ** Format.count;
        errdefer {
            for (&slots) |*slot| {
                if (slot.*) |b| {
                    allocator.free(b);
                    slot.* = null;
                }
            }
        }

        for (self.slots, 0..) |maybe_bytes, i| {
            if (maybe_bytes) |bytes| {
                slots[i] = try allocator.dupe(u8, bytes);
            }
        }

        return .{
            .allocator = allocator,
            .slots = slots,
        };
    }

    /// Count how many formats are present in this item.
    pub fn count(self: *const Item) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    /// Convenience constructor for pure text items.
    pub fn fromText(allocator: std.mem.Allocator, str: []const u8) Error!Item {
        return init(allocator, &.{.{ .format = .text_utf8, .bytes = str }});
    }

    /// Convenience getter for UTF-8 text.
    pub fn text(self: *const Item) ?[]const u8 {
        return self.get(.text_utf8);
    }

    /// Convenience getter for PNG image bytes.
    pub fn imagePng(self: *const Item) ?[]const u8 {
        return self.get(.image_png);
    }

    /// Convenience getter for JSON metadata.
    pub fn metadataJson(self: *const Item) ?[]const u8 {
        return self.get(.metadata_json);
    }
};

/// Heap-allocated clipboard offer compatible with SDL3 callback lifetime.
///
/// Ownership contract:
/// - `init`/`initClone` return a handle owned by their caller. The caller
///   releases it with `deinit`, which is valid at most once.
/// - SDL never owns the handle. It holds the offer between a successful data
///   registration and the cleanup callback it runs at the next clear, cancel
///   or video quit, so the caller may release the handle only once that
///   callback has run. `deactivate` reports whether it has: it stops the
///   offer, and `active` is false from then on whatever ran the callback.
/// - `cleanupCallback` is that terminal callback, and it only ends the
///   service: every owned byte buffer is released and the handle rejects
///   further data requests, so no request can ever observe released bytes.
///   The handle survives as an inert tombstone until its owner releases it.
pub const Offer = struct {
    allocator: std.mem.Allocator,
    item: Item,
    mime_storage: [][*:0]const u8,
    active: std.atomic.Value(bool),
    /// Create an Offer taking ownership of `item`.
    pub fn init(allocator: std.mem.Allocator, item: Item) !*Offer {
        const self = try allocator.create(Offer);
        errdefer allocator.destroy(self);

        var mime_count: usize = 0;
        for (0..Format.count) |i| {
            const fmt: Format = @enumFromInt(i);
            if (item.has(fmt)) {
                mime_count += 1;
                // Offer text/plain alias for text_utf8
                if (fmt == .text_utf8) mime_count += 1;
            }
        }

        const mimes = try allocator.alloc([*:0]const u8, mime_count);
        errdefer allocator.free(mimes);

        var idx: usize = 0;
        for (0..Format.count) |i| {
            const fmt: Format = @enumFromInt(i);
            if (item.has(fmt)) {
                mimes[idx] = fmt.mime().ptr;
                idx += 1;
                if (fmt == .text_utf8) {
                    mimes[idx] = "text/plain";
                    idx += 1;
                }
            }
        }

        self.* = .{
            .allocator = allocator,
            .item = item,
            .mime_storage = mimes,
            .active = .init(true),
        };
        return self;
    }

    /// Create an Offer by deep-cloning an existing Item.
    pub fn initClone(allocator: std.mem.Allocator, item: *const Item) !*Offer {
        const cloned = try item.clone(allocator);
        errdefer {
            var mut = cloned;
            mut.deinit();
        }
        const value = try init(allocator, cloned);
        return value;
    }

    /// Release every owned byte buffer and reject further data requests.
    /// Idempotent, and the only report that SDL has run its cleanup callback:
    /// while this returns true SDL may still call back into the offer.
    /// The handle itself stays valid until `deinit`.
    pub fn deactivate(self: *Offer) void {
        if (!self.active.swap(false, .acq_rel)) return;
        self.item.deinit();
        self.allocator.free(self.mime_storage);
    }

    /// Release the offer handle itself. Valid at most once, and only once SDL
    /// has ended the offer with `cleanupCallback`.
    pub fn deinit(self: *Offer) void {
        const allocator = self.allocator;
        defer allocator.destroy(self);
        self.deactivate();
        self.* = undefined;
    }

    /// SDL3-compatible data callback.
    /// Returns pointer to format bytes and writes length to `size`.
    /// `size` is the exact owned payload length in bytes: no terminator, no
    /// padding. The bytes stay valid until the offer is deactivated.
    /// For zero-length payloads, writes 0 to size and returns a valid non-null pointer.
    /// If format is unhandled, absent, or offer is inactive, returns null.
    pub fn dataCallback(
        userdata: ?*anyopaque,
        mime_type: [*c]const u8,
        size: [*c]usize,
    ) callconv(.c) ?*const anyopaque {
        const raw = userdata orelse return null;
        const self: *Offer = @ptrCast(@alignCast(raw));

        if (!self.active.load(.acquire)) return null;
        if (mime_type == null) return null;

        const mime_slice = std.mem.span(mime_type);
        const format = Format.fromMime(mime_slice) orelse return null;
        const bytes = self.item.get(format) orelse return null;

        if (!self.active.load(.acquire)) return null;

        size.* = bytes.len;
        if (bytes.len == 0) return "";
        return bytes.ptr;
    }

    /// SDL3-compatible cleanup callback: the terminal event of this offer's
    /// service. It ends the service before returning, so every owned byte
    /// buffer is released and later data requests reject, and no request can
    /// observe released bytes. The handle outlives the callback as an inert
    /// tombstone for its owner to release with `deinit`.
    pub fn cleanupCallback(userdata: ?*anyopaque) callconv(.c) void {
        const raw = userdata orelse return;
        const self: *Offer = @ptrCast(@alignCast(raw));

        self.deactivate();
    }
};
