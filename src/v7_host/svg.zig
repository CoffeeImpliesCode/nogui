//! Real SVG rasterization backed by librsvg and Cairo.
//! Supports groups, transforms, basic shapes, curves/arcs, fill/stroke, and viewBox.
//! Renders to CPU RGBA8 surfaces with explicit viewport, DPI, and monochrome tinting.
//! Enforces an isolated external resource policy (no ambient network/file loading).
const std = @import("std");
const image_mod = @import("image.zig");

pub const DecodedImage = image_mod.DecodedImage;
pub const Size = image_mod.Size;
pub const Rect = image_mod.Rect;
pub const PixelFormat = image_mod.PixelFormat;

// ── Librsvg and Cairo C ABI types ──────────────────────

pub const RsvgHandle = anyopaque;
pub const cairo_t = anyopaque;
pub const cairo_surface_t = anyopaque;

pub const GError = extern struct {
    domain: u32,
    code: i32,
    message: [*:0]const u8,
};

pub const RsvgRectangle = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const cairo_format_argb32: c_int = 0;

pub const cairo_status_success: c_int = 0;

// ── Native C ABI Function Table ───────────────────────

pub const LibRsvgApi = struct {
    rsvg_handle_new_from_data: *const fn (
        data: [*]const u8,
        data_len: usize,
        err: ?*?*GError,
    ) callconv(.c) ?*RsvgHandle,

    rsvg_handle_get_intrinsic_size_in_pixels: *const fn (
        handle: *RsvgHandle,
        out_width: *f64,
        out_height: *f64,
    ) callconv(.c) c_int,

    rsvg_handle_render_document: *const fn (
        handle: *RsvgHandle,
        cr: *cairo_t,
        viewport: *const RsvgRectangle,
        err: ?*?*GError,
    ) callconv(.c) c_int,

    rsvg_handle_set_dpi: *const fn (
        handle: *RsvgHandle,
        dpi: f64,
    ) callconv(.c) void,

    g_object_unref: *const fn (
        object: *anyopaque,
    ) callconv(.c) void,

    g_error_free: *const fn (
        err: *GError,
    ) callconv(.c) void,

    cairo_image_surface_create: *const fn (
        format: c_int,
        width: c_int,
        height: c_int,
    ) callconv(.c) ?*cairo_surface_t,

    cairo_create: *const fn (
        target: *cairo_surface_t,
    ) callconv(.c) ?*cairo_t,

    cairo_destroy: *const fn (
        cr: *cairo_t,
    ) callconv(.c) void,

    cairo_surface_destroy: *const fn (
        surface: *cairo_surface_t,
    ) callconv(.c) void,

    cairo_surface_flush: *const fn (
        surface: *cairo_surface_t,
    ) callconv(.c) void,

    cairo_image_surface_get_data: *const fn (
        surface: *cairo_surface_t,
    ) callconv(.c) ?[*]u8,

    cairo_image_surface_get_stride: *const fn (
        surface: *cairo_surface_t,
    ) callconv(.c) c_int,

    cairo_surface_status: *const fn (
        surface: *cairo_surface_t,
    ) callconv(.c) c_int,

    cairo_status: *const fn (
        cr: *cairo_t,
    ) callconv(.c) c_int,
};

/// Why a runtime codec engine cannot decode.
pub const Unavailable = enum {
    none,
    /// A shared library was not found on the loader search path.
    library_missing,
    /// A library loaded but a used symbol was absent.
    symbol_missing,
};

/// Dynamic loader and singleton holder for librsvg and Cairo libraries.
/// Process-wide handle on the librsvg, Cairo and GLib entry points. The
/// libraries are loaded once; a missing library leaves the engine
/// unavailable, which callers report instead of crashing.
pub const SvgEngine = struct {
    api: ?LibRsvgApi = null,
    rsvg_lib: ?std.DynLib = null,
    cairo_lib: ?std.DynLib = null,
    glib_lib: ?std.DynLib = null,
    unavailable: Unavailable = .none,
    initialized: bool = false,

    var global_instance: SvgEngine = .{};
    var init_lock: std.atomic.Mutex = .unlocked;

    /// The library handles stay open for the process lifetime, so this is
    /// idempotent and safe to call from any thread.
    pub fn getGlobal(maybe_io: ?std.Io) *SvgEngine {
        _ = maybe_io;
        if (!@atomicLoad(bool, &global_instance.initialized, .acquire)) {
            while (!init_lock.tryLock()) std.atomic.spinLoopHint();
            defer init_lock.unlock();
            if (!global_instance.initialized) {
                global_instance.initDynamic() catch |err| {
                    global_instance.unavailable = switch (err) {
                        error.LibraryUnavailable => .library_missing,
                        else => .symbol_missing,
                    };
                };
                @atomicStore(bool, &global_instance.initialized, true, .release);
            }
        }
        return &global_instance;
    }

    /// True when librsvg, Cairo and GLib were all found and bound.
    pub fn isAvailable(self: *SvgEngine) bool {
        return self.api != null;
    }

    /// `.none` when the engine can rasterize, otherwise why it cannot.
    pub fn unavailableReason(self: *SvgEngine) Unavailable {
        return self.unavailable;
    }

    fn initDynamic(self: *SvgEngine) !void {
        // Portable sonames only. The libraries come from the declared
        // dependencies and are found through the loader's normal search.
        var rsvg = try openFirst(&.{
            "librsvg-2.so.2",
            "librsvg-2.so",
        });
        errdefer rsvg.close();
        var cairo = try openFirst(&.{
            "libcairo.so.2",
            "libcairo.so",
        });
        errdefer cairo.close();
        // GObject/GLib supply the reference and error-release calls. They are
        // dependencies of librsvg, so a dlsym on either handle resolves them.
        var glib = openFirst(&.{
            "libgobject-2.0.so.0",
            "libgobject-2.0.so",
            "libglib-2.0.so.0",
            "libglib-2.0.so",
        }) catch null;
        if (glib) |*handle| {
            errdefer handle.close();
        }

        const fn_rsvg_new = rsvg.lookup(
            *const fn ([*]const u8, usize, ?*?*GError) callconv(.c) ?*RsvgHandle,
            "rsvg_handle_new_from_data",
        ) orelse return error.SymbolNotFound;
        const fn_rsvg_intrinsic = rsvg.lookup(
            *const fn (*RsvgHandle, *f64, *f64) callconv(.c) c_int,
            "rsvg_handle_get_intrinsic_size_in_pixels",
        ) orelse return error.SymbolNotFound;
        const fn_rsvg_render = rsvg.lookup(
            *const fn (*RsvgHandle, *cairo_t, *const RsvgRectangle, ?*?*GError) callconv(.c) c_int,
            "rsvg_handle_render_document",
        ) orelse return error.SymbolNotFound;
        const fn_rsvg_set_dpi = rsvg.lookup(
            *const fn (*RsvgHandle, f64) callconv(.c) void,
            "rsvg_handle_set_dpi",
        ) orelse return error.SymbolNotFound;

        const fn_cairo_surf_create = cairo.lookup(
            *const fn (c_int, c_int, c_int) callconv(.c) ?*cairo_surface_t,
            "cairo_image_surface_create",
        ) orelse return error.SymbolNotFound;
        const fn_cairo_create = cairo.lookup(
            *const fn (*cairo_surface_t) callconv(.c) ?*cairo_t,
            "cairo_create",
        ) orelse return error.SymbolNotFound;
        const fn_cairo_destroy = cairo.lookup(
            *const fn (*cairo_t) callconv(.c) void,
            "cairo_destroy",
        ) orelse return error.SymbolNotFound;
        const fn_cairo_surf_destroy = cairo.lookup(
            *const fn (*cairo_surface_t) callconv(.c) void,
            "cairo_surface_destroy",
        ) orelse return error.SymbolNotFound;
        const fn_cairo_surf_flush = cairo.lookup(
            *const fn (*cairo_surface_t) callconv(.c) void,
            "cairo_surface_flush",
        ) orelse return error.SymbolNotFound;
        const fn_cairo_surf_data = cairo.lookup(
            *const fn (*cairo_surface_t) callconv(.c) ?[*]u8,
            "cairo_image_surface_get_data",
        ) orelse return error.SymbolNotFound;
        const fn_cairo_surf_stride = cairo.lookup(
            *const fn (*cairo_surface_t) callconv(.c) c_int,
            "cairo_image_surface_get_stride",
        ) orelse return error.SymbolNotFound;
        const fn_cairo_surf_status = cairo.lookup(
            *const fn (*cairo_surface_t) callconv(.c) c_int,
            "cairo_surface_status",
        ) orelse return error.SymbolNotFound;
        const fn_cairo_status = cairo.lookup(
            *const fn (*cairo_t) callconv(.c) c_int,
            "cairo_status",
        ) orelse return error.SymbolNotFound;

        const fn_g_object_unref = lookupIn(
            *const fn (*anyopaque) callconv(.c) void,
            "g_object_unref",
            &glib,
            &rsvg,
        ) orelse return error.SymbolNotFound;
        const fn_g_error_free = lookupIn(
            *const fn (*GError) callconv(.c) void,
            "g_error_free",
            &glib,
            &rsvg,
        ) orelse return error.SymbolNotFound;

        self.rsvg_lib = rsvg;
        self.cairo_lib = cairo;
        self.glib_lib = glib;

        self.api = .{
            .rsvg_handle_new_from_data = fn_rsvg_new,
            .rsvg_handle_get_intrinsic_size_in_pixels = fn_rsvg_intrinsic,
            .rsvg_handle_render_document = fn_rsvg_render,
            .rsvg_handle_set_dpi = fn_rsvg_set_dpi,
            .g_object_unref = fn_g_object_unref,
            .g_error_free = fn_g_error_free,
            .cairo_image_surface_create = fn_cairo_surf_create,
            .cairo_create = fn_cairo_create,
            .cairo_destroy = fn_cairo_destroy,
            .cairo_surface_destroy = fn_cairo_surf_destroy,
            .cairo_surface_flush = fn_cairo_surf_flush,
            .cairo_image_surface_get_data = fn_cairo_surf_data,
            .cairo_image_surface_get_stride = fn_cairo_surf_stride,
            .cairo_surface_status = fn_cairo_surf_status,
            .cairo_status = fn_cairo_status,
        };
    }

    fn openFirst(names: []const []const u8) !std.DynLib {
        for (names) |name| {
            if (std.DynLib.open(name)) |lib| return lib else |_| {}
        }
        return error.LibraryUnavailable;
    }

    fn lookupIn(
        comptime T: type,
        comptime symbol: [:0]const u8,
        first: *?std.DynLib,
        second: *std.DynLib,
    ) ?T {
        if (first.*) |*lib| {
            if (lib.lookup(T, symbol)) |found| return found;
        }
        return second.lookup(T, symbol);
    }
};

/// Queries the intrinsic size of an SVG document using librsvg.
/// Returns null if intrinsic size is unavailable (e.g. document specifies
/// percentages or only a viewBox without absolute width/height).
pub fn queryIntrinsicSize(io: ?std.Io, svg_bytes: []const u8) !?Size {
    _ = io;
    const engine = SvgEngine.getGlobal(null);
    const api = engine.api orelse return error.LibrsvgUnavailable;

    var gerr: ?*GError = null;
    const handle = api.rsvg_handle_new_from_data(svg_bytes.ptr, svg_bytes.len, &gerr) orelse {
        if (gerr) |e| {
            api.g_error_free(e);
        }
        return error.InvalidSvg;
    };
    defer api.g_object_unref(handle);

    var out_w: f64 = 0;
    var out_h: f64 = 0;
    const has_size = api.rsvg_handle_get_intrinsic_size_in_pixels(handle, &out_w, &out_h);
    if (has_size != 0 and out_w > 0.0 and out_h > 0.0) {
        return .{
            .width = @floatCast(out_w),
            .height = @floatCast(out_h),
        };
    }

    return null;
}

/// Rendering options for SVG document rasterization.
pub const SvgRenderOptions = struct {
    viewport_width: u32,
    viewport_height: u32,
    dpi_scale: f32 = 1.0,
    /// Optional monochrome tint color [R, G, B, A] in sRGB 0..255.
    tint: ?[4]u8 = null,
};

/// Renders an SVG document into a CPU RGBA8 DecodedImage using librsvg and Cairo.
/// Enforces an isolated external resource policy (no ambient network/file loading).
pub fn renderSvg(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    svg_bytes: []const u8,
    options: SvgRenderOptions,
) !DecodedImage {
    _ = io;
    if (options.viewport_width == 0 or options.viewport_height == 0) {
        return error.InvalidViewport;
    }
    // Cairo takes signed 32-bit extents, so an oversized viewport is rejected
    // instead of being truncated into a different surface size.
    if (options.viewport_width > std.math.maxInt(c_int) or
        options.viewport_height > std.math.maxInt(c_int))
    {
        return error.InvalidViewport;
    }

    const engine = SvgEngine.getGlobal(null);
    const api = engine.api orelse return error.LibrsvgUnavailable;
    var gerr: ?*GError = null;
    // Uses rsvg_handle_new_from_data: creates handle without base URL or ambient network flags.
    const handle = api.rsvg_handle_new_from_data(svg_bytes.ptr, svg_bytes.len, &gerr) orelse {
        if (gerr) |e| {
            api.g_error_free(e);
        }
        return error.InvalidSvg;
    };
    defer api.g_object_unref(handle);

    const base_dpi: f64 = 96.0;
    const dpi = base_dpi * @as(f64, options.dpi_scale);
    api.rsvg_handle_set_dpi(handle, dpi);

    const surf_w: c_int = @intCast(options.viewport_width);
    const surf_h: c_int = @intCast(options.viewport_height);

    const surface = api.cairo_image_surface_create(cairo_format_argb32, surf_w, surf_h) orelse {
        return error.OutOfMemory;
    };
    defer api.cairo_surface_destroy(surface);

    if (api.cairo_surface_status(surface) != cairo_status_success) {
        return error.CairoError;
    }

    const cr = api.cairo_create(surface) orelse return error.OutOfMemory;
    defer api.cairo_destroy(cr);

    if (api.cairo_status(cr) != cairo_status_success) {
        return error.CairoError;
    }

    const viewport: RsvgRectangle = .{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(options.viewport_width),
        .height = @floatFromInt(options.viewport_height),
    };

    var render_err: ?*GError = null;
    const success = api.rsvg_handle_render_document(handle, cr, &viewport, &render_err);
    if (success == 0) {
        if (render_err) |e| {
            api.g_error_free(e);
        }
        return error.RenderFailed;
    }

    api.cairo_surface_flush(surface);

    const raw_data = api.cairo_image_surface_get_data(surface) orelse return error.RenderFailed;
    const surface_stride = api.cairo_image_surface_get_stride(surface);
    if (surface_stride <= 0) return error.CairoError;
    const stride: u32 = @intCast(surface_stride);

    // Allocate owned RGBA8 buffer
    const out_stride = std.math.mul(u32, options.viewport_width, 4) catch
        return error.ImageTooLarge;
    const out_pixels = try allocator.alloc(
        u8,
        std.math.mul(usize, @as(usize, out_stride), @as(usize, options.viewport_height)) catch
            return error.ImageTooLarge,
    );
    errdefer allocator.free(out_pixels);

    // Cairo ARGB32 native endian is premultiplied BGRA on little-endian x86_64
    var y: u32 = 0;
    while (y < options.viewport_height) : (y += 1) {
        const src_row = raw_data + (@as(usize, y) * @as(usize, stride));
        const dst_row = out_pixels.ptr + (@as(usize, y) * @as(usize, out_stride));

        var x: u32 = 0;
        while (x < options.viewport_width) : (x += 1) {
            const src_px = src_row + (x * 4);
            const dst_px = dst_row + (x * 4);

            const b = src_px[0];
            const g = src_px[1];
            const r = src_px[2];
            const a = src_px[3];

            if (options.tint) |tint| {
                // Monochrome tint modulation: Cout = (Ctint * Asrc) / 255
                // Modulate RGB with tint color and source alpha.
                const alpha_factor: u32 = a;
                const tint_r: u32 = tint[0];
                const tint_g: u32 = tint[1];
                const tint_b: u32 = tint[2];
                const tint_a: u32 = tint[3];

                dst_px[0] = @truncate((tint_r * alpha_factor) / 255);
                dst_px[1] = @truncate((tint_g * alpha_factor) / 255);
                dst_px[2] = @truncate((tint_b * alpha_factor) / 255);
                dst_px[3] = @truncate((tint_a * alpha_factor) / 255);
            } else {
                dst_px[0] = r;
                dst_px[1] = g;
                dst_px[2] = b;
                dst_px[3] = a;
            }
        }
    }

    return .{
        .width = options.viewport_width,
        .height = options.viewport_height,
        .format = .rgba8,
        .color_space = .srgb,
        .alpha_type = .premultiplied,
        .stride = out_stride,
        .pixels = out_pixels,
        .duration_ns = null,
        .allocator = allocator,
    };
}

/// Identity of one rasterized surface. Viewport, DPI and tint all change the
/// pixels, so each of them is part of the key.
pub const SvgCacheKey = struct {
    svg_hash: u64,
    viewport_width: u32,
    viewport_height: u32,
    dpi_scale: f32 = 1.0,
    tint: ?[4]u8 = null,

    pub fn hash(self: SvgCacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0x5566_7788_99aa_bbcc);
        hasher.update(std.mem.asBytes(&self.svg_hash));
        hasher.update(std.mem.asBytes(&self.viewport_width));
        hasher.update(std.mem.asBytes(&self.viewport_height));
        const scale_bits: u32 = @bitCast(self.dpi_scale);
        hasher.update(std.mem.asBytes(&scale_bits));
        if (self.tint) |tint| {
            hasher.update(&.{@as(u8, 1)});
            hasher.update(&tint);
        } else {
            hasher.update(&.{@as(u8, 0)});
        }
        return hasher.final();
    }
};

/// Byte-budgeted LRU cache of rasterized surfaces. A caller that keeps a
/// surface across a frame must `pin` it; pinned surfaces are never evicted, so
/// a later `put` cannot change or free a live image, and the pointer a pin
/// returns stays valid for the whole pin.
pub const SvgRasterCache = struct {
    const Entry = struct {
        image: DecodedImage,
        byte_size: usize,
        last_access_ns: i196,
        pins: u32 = 0,
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    max_bytes: usize,
    used_bytes: usize = 0,
    /// The table reaches its surfaces by pointer. Re-hashing therefore moves
    /// no surface and no pixel buffer, which is what a borrowed image needs:
    /// growing the cache for other documents cannot disturb one already handed
    /// out. Each entry costs one small allocation, made on a `put` and never on
    /// a `pin`.
    entries: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, max_bytes: usize) SvgRasterCache {
        return .{ .gpa = gpa, .io = io, .max_bytes = max_bytes };
    }

    pub fn deinit(self: *SvgRasterCache) void {
        self.mutex.lockUncancelable(self.io);
        var surfaces = self.entries.valueIterator();
        while (surfaces.next()) |entry| {
            self.dropEntryLocked(entry.*);
        }
        self.entries.deinit(self.gpa);
        self.used_bytes = 0;
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    /// Pins a cached surface and returns it. The caller must `unpin`.
    pub fn pin(self: *SvgRasterCache, key: SvgCacheKey, now_ns: i196) ?*const DecodedImage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.entries.get(key.hash()) orelse return null;
        entry.pins += 1;
        entry.last_access_ns = now_ns;
        return &entry.image;
    }

    pub fn unpin(self: *SvgRasterCache, key: SvgCacheKey) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.entries.get(key.hash()) orelse return;
        if (entry.pins > 0) entry.pins -= 1;
    }

    /// Stores a rasterized surface, evicting unpinned entries by recency.
    /// Ownership passes to the cache only on success; every refusal below hands
    /// the image back to the caller and leaves the cache exactly as it was.
    /// Fails when a pin blocks the byte budget, and refuses a same-key
    /// replacement that would take pixels a live pin is still holding.
    pub fn put(self: *SvgRasterCache, key: SvgCacheKey, image: DecodedImage, now_ns: i196) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const byte_size = image.pixels.len;
        if (byte_size > self.max_bytes) return error.BudgetExceeded;

        const hash = key.hash();
        if (self.entries.get(hash)) |entry| {
            if (entry.pins > 0) return error.EntryPinned;

            // The surface about to be freed pays for its replacement, so only
            // the difference has to fit the budget. Swapping in place keeps the
            // entry, the map and any address already handed out untouched, and
            // the swap cannot fail because it allocates nothing.
            const previous = entry.byte_size;
            if (byte_size > previous and !self.makeRoomLocked(hash, byte_size - previous)) {
                return error.BudgetExceeded;
            }

            var replaced = entry.image;
            replaced.deinit();
            entry.* = .{
                .image = image,
                .byte_size = byte_size,
                .last_access_ns = now_ns,
            };
            self.used_bytes = self.used_bytes - previous + byte_size;
            return;
        }

        // Reserved before anything is freed, so an allocation failure costs no
        // cached surface and never costs the caller its pixels.
        const entry = try self.gpa.create(Entry);
        entry.* = .{
            .image = image,
            .byte_size = byte_size,
            .last_access_ns = now_ns,
        };
        errdefer self.gpa.destroy(entry);

        // The table grows before the eviction too, so the insert itself cannot
        // fail once surfaces have been freed.
        try self.entries.ensureUnusedCapacity(self.gpa, 1);

        if (!self.makeRoomLocked(hash, byte_size)) return error.BudgetExceeded;
        self.entries.putAssumeCapacity(hash, entry);
        self.used_bytes += byte_size;
    }

    /// Frees unpinned entries by recency until `needed` extra bytes fit. The
    /// entry stored under `keep` is never a victim: a put that is about to
    /// overwrite it must not free the storage it writes into.
    ///
    /// Returns false having freed nothing when the budget cannot be met from
    /// unpinned entries alone. A refusal must leave the cache as it was, so the
    /// whole decision is made before the first eviction.
    fn makeRoomLocked(self: *SvgRasterCache, keep: u64, needed: usize) bool {
        // The budget already has room: nothing is scanned and nothing is freed,
        // so a put that is not competing for bytes pays for no eviction walk.
        if (needed <= self.max_bytes - self.used_bytes) return true;

        var evictable: usize = 0;
        var scan = self.entries.iterator();
        while (scan.next()) |item| {
            if (item.key_ptr.* != keep and item.value_ptr.*.pins == 0) {
                evictable += item.value_ptr.*.byte_size;
            }
        }
        if (needed > self.max_bytes - (self.used_bytes -| evictable)) return false;

        while (needed > self.max_bytes - self.used_bytes) {
            // The bytes counted above are exactly what this loop can still
            // release, so a victim exists whenever the budget is still short.
            const hash = self.oldestUnpinnedLocked(keep) orelse return false;
            const removed = self.entries.fetchRemove(hash).?;
            self.used_bytes -= removed.value.byte_size;
            self.dropEntryLocked(removed.value);
        }
        return true;
    }

    /// The unpinned entry under another key that has gone untouched the
    /// longest, which is the one a recency cache gives up first.
    fn oldestUnpinnedLocked(self: *SvgRasterCache, keep: u64) ?u64 {
        var victim: ?u64 = null;
        var oldest: i196 = std.math.maxInt(i196);
        var it = self.entries.iterator();
        while (it.next()) |item| {
            if (item.key_ptr.* == keep) continue;
            if (item.value_ptr.*.pins == 0 and item.value_ptr.*.last_access_ns < oldest) {
                oldest = item.value_ptr.*.last_access_ns;
                victim = item.key_ptr.*;
            }
        }
        return victim;
    }

    /// Releases a surface the cache owns together with the entry holding it.
    /// The entry must already be out of the table.
    fn dropEntryLocked(self: *SvgRasterCache, entry: *Entry) void {
        var image = entry.image;
        image.deinit();
        self.gpa.destroy(entry);
    }

    pub fn used(self: *SvgRasterCache) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.used_bytes;
    }
};
