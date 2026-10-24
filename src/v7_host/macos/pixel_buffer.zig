//! E02: a CoreVideo pixel buffer as an `image.FrameDescriptor`.
//!
//! WHAT CROSSES THE BOUNDARY. A frame leaves here as the shared descriptor:
//! width, height, a `PixelFormat`, a colour space, plane geometry and a
//! `release_fn`. No `CVPixelBuffer`, no `IOSurfaceRef` and no `MTLTexture`
//! reaches a client, so the upload path stays the one the host already has and
//! a GPU-backed surface is never imported behind its back.
//!
//! WHO OWNS THE BYTES, AND WHO MAY STORE INTO THEM.
//!
//!   * `borrowed` locks the buffer for READING and describes it in place.
//!     Nothing is copied; `release_fn` unlocks and drops the reference the
//!     frame took. A consumer that holds the frame past the next producer
//!     frame will be reading memory the producer is about to reuse, so this
//!     mode is for a frame that is uploaded before the next one arrives.
//!   * `owned` copies the pixels into storage this adapter owns, unlocks at
//!     once, and frees the copy on release. The frame then outlives the
//!     producer's buffer, at the cost of one memcpy per frame.
//!   * `writePixels` is the WRITING half and is deliberately not part of
//!     `describe`. A described buffer is locked read-only until its frame is
//!     released, so a producer fills through `writePixels` FIRST and
//!     describes afterwards. There is no path here that stores through a
//!     read-only mapping.
//!
//! REFERENCE COUNTING. `create` returns one reference the caller owns.
//! `describe` takes a SECOND reference of its own for the frame, so a caller
//! that keeps its own releases it with `releaseReference` when it is done.
//!
//! WHAT IS REFUSED. A GPU-backed buffer does not accept a read lock, and this
//! adapter reports `not_cpu_accessible` instead of reaching for the IOSurface
//! behind it. A four-character code with no plane layout the host can describe
//! reports `format_unsupported` with the code, so a caller can see which format
//! it would have to teach the host. A plane that does not live inside the
//! buffer's own allocation reports `out_of_range` instead of an offset that
//! would read outside it.
const std = @import("std");
const native = @import("native.zig");
const image = @import("../image.zig");

/// The adapter's typed answers, named so a producer's own fill callback can
/// return this exact set without restating the platform's error list.
pub const Error = native.Error;
const Status = native.Status;
const shim = native.shim;

pub const FrameDescriptor = image.FrameDescriptor;
pub const PixelFormat = image.PixelFormat;
pub const ColorSpace = image.ColorSpace;
pub const AlphaType = image.AlphaType;
pub const PlaneDescriptor = image.PlaneDescriptor;

/// The four-character codes this adapter understands. Anything else is named
/// by `format_unsupported` with its code, never guessed at.
pub const code_bgra: u32 = fourcc("BGRA");
pub const code_rgba: u32 = fourcc("RGBA");
pub const code_rgb: u32 = fourcc("RGB ");
pub const code_rgba_24: u32 = fourcc("rgBA");
pub const code_gray: u32 = fourcc("GRAY");
pub const code_nv12_full: u32 = fourcc("420f");
pub const code_nv12_video: u32 = fourcc("420v");
pub const code_yuv420p: u32 = fourcc("y420");

/// A big-endian four-character code, which is how CoreVideo writes them.
fn fourcc(comptime text: *const [4]u8) u32 {
    return (@as(u32, text[0]) << 24) | (@as(u32, text[1]) << 16) |
        (@as(u32, text[2]) << 8) | @as(u32, text[3]);
}

/// The format a code names, or null when this adapter has no layout for it.
pub fn formatOf(code: u32) ?PixelFormat {
    return switch (code) {
        code_bgra => .bgra8,
        code_rgba, code_rgba_24 => .rgba8,
        code_rgb => .rgb8,
        code_gray => .r8,
        code_nv12_full, code_nv12_video => .nv12,
        code_yuv420p => .yuv420p,
        else => null,
    };
}

/// The code a format is created with. Null for a format no pixel buffer
/// carries, which is every packed format except the ones above.
pub fn codeOf(format: PixelFormat) ?u32 {
    return switch (format) {
        .bgra8 => code_bgra,
        .rgba8 => code_rgba,
        .rgb8 => code_rgb,
        .r8 => code_gray,
        .nv12 => code_nv12_full,
        .yuv420p => code_yuv420p,
    };
}

/// How the descriptor's bytes are owned.
pub const CopyMode = enum {
    /// Describe the buffer in place under a read lock. Cheapest, and the frame
    /// is only valid until the producer reuses the buffer.
    borrowed,
    /// Copy into storage this adapter owns, so the frame outlives the
    /// producer's buffer.
    owned,
};

/// What one describe call produced.
pub const Outcome = union(enum) {
    frame: FrameDescriptor,
    /// No layout this adapter can describe. The code is the four-character
    /// value CoreVideo reported.
    format_unsupported: u32,
    /// The buffer is not CPU addressable. Its IOSurface is deliberately not
    /// imported: a GPU import would bypass the host's upload path.
    not_cpu_addressible,
    /// CoreVideo refused the lock for some other reason.
    lock_failed,
    /// A plane does not live inside the buffer's own allocation, so no offset
    /// could describe it safely.
    out_of_range,
    /// A width, height or stride the descriptor cannot express.
    geometry_invalid,
    /// The copy could not be allocated.
    out_of_memory,
};

/// The heap-stable record a frame releases.
///
/// It has to outlive the descriptor, because the descriptor is a value that
/// may be copied anywhere, and `release_fn` is the only way back to the
/// buffer. `release` is written to be called exactly once, which is what
/// `FrameDescriptor.release` guarantees.
pub const Holder = struct {
    gpa: std.mem.Allocator,
    /// The pixel buffer, borrowed by the host. `adopt` took a reference of its
    /// OWN for this record, so the one `release` drops is exactly that one and
    /// a caller's reference is never spent by a frame.
    buffer: *anyopaque,
    /// The copy, when the mode is `owned`. Null otherwise.
    copy: ?[]u8 = null,
    /// The copy's total length, so the planes can be sliced out of it.
    copy_len: usize = 0,
    locked: bool = false,
    released: bool = false,

    /// The descriptor's release function. Zeroing is unconditional so a
    /// double release cannot unlock a buffer twice.
    pub fn release(context: ?*anyopaque) void {
        const ptr = context orelse return;
        const self: *Holder = @ptrCast(@alignCast(ptr));
        if (self.released) return;
        self.released = true;
        if (self.locked) {
            if (native.available) {
                _ = shim.nogui_macos_frame_unlock(self.buffer);
            }
            self.locked = false;
        }
        if (self.copy) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.gpa.free(bytes);
            self.copy = null;
        }
        if (native.available) shim.nogui_macos_pixel_buffer_release(self.buffer);
        self.gpa.destroy(self);
    }
};

/// Create a CPU-addressable pixel buffer this adapter can describe.
///
/// The shim asks CoreVideo for a plain buffer with no IOSurface attachment,
/// so a buffer made here is never a GPU resource in disguise.
pub fn create(width: u32, height: u32, format: PixelFormat) ?*anyopaque {
    if (!native.available) return null;
    const code = codeOf(format) orelse return null;
    return @ptrCast(shim.nogui_macos_pixel_buffer_create(width, height, code));
}

/// Take one more reference to a buffer, for a producer that hands the same
/// buffer to two consumers in a row.
pub fn retain(buffer: *anyopaque) void {
    if (!native.available) return;
    shim.nogui_macos_pixel_buffer_retain(buffer);
}

/// Release a reference the caller owns. A descriptor takes a reference of its
/// own through `describe`, so this releases the CALLER's, which is the only
/// one left after `create`.
pub fn releaseReference(buffer: *anyopaque) void {
    if (!native.available) return;
    shim.nogui_macos_pixel_buffer_release(buffer);
}

/// One plane of a buffer under a WRITE lock, handed to a producer's own fill.
pub const PlaneWrite = struct {
    /// The mapped bytes. CoreVideo was asked for NO permission flag, so this
    /// is the producer's own storage and storing through it is what the lock
    /// is for. It is writable only until `writePixels` returns.
    base: [*]u8,
    /// Distance in bytes from one row's first byte to the next.
    stride: u32,
    width: u32,
    height: u32,
    /// Which plane of a multi-plane buffer this is, and how many there are.
    index: u32,
    plane_count: u32,
};

/// Store a producer's bytes into its own pixel buffer.
///
/// This is the WRITING half of the lock, and it is deliberately separate from
/// `describe`: a described buffer is locked read-only for the whole lifetime of
/// the frame, so filling a described buffer would store into memory the lock
/// forbids. A producer fills first, and describes afterwards.
///
/// Every path out unlocks. A refusal is an error rather than a value, so an
/// `errdefer` would not run for one either; `held` is what stops the buffer
/// staying locked for the next frame.
pub fn writePixels(
    buffer: *anyopaque,
    context: *anyopaque,
    write: *const fn (context: *anyopaque, plane: PlaneWrite) Error!void,
) Error!void {
    // `comptime` keeps the shim call out of the object file entirely on a
    // target that has no shim, which is what this module's own rule demands.
    if (comptime !native.available) return error.ShimUnavailable;
    // SAFETY: `nogui_macos_frame_lock_write` fills this record and every field
    // below is read only after a `.ok` lock status.
    var layout: shim.nogui_macos_frame_layout = undefined;
    const locked = Status.of(shim.nogui_macos_frame_lock_write(buffer, &layout));
    switch (locked) {
        .ok => {},
        // A GPU-backed buffer refuses the lock, and reaching for the IOSurface
        // behind it would be the one thing this adapter must not do.
        .unavailable => return error.Unsupported,
        else => |status| return native.fail(status),
    }
    var held = true;
    defer if (held) {
        _ = shim.nogui_macos_frame_unlock_write(buffer);
    };

    const plane_count: usize = @intCast(layout.plane_count);
    if (plane_count == 0 or plane_count > layout.planes.len or layout.base == null) {
        return error.BadArgument;
    }
    for (0..plane_count) |index| {
        const plane = layout.planes[index];
        if (plane.data == null or plane.stride == 0 or plane.width == 0 or plane.height == 0) {
            return error.BadArgument;
        }
        try write(context, .{
            .base = @constCast(plane.data.?),
            .stride = plane.stride,
            .width = plane.width,
            .height = plane.height,
            .index = @intCast(index),
            .plane_count = @intCast(plane_count),
        });
    }
    _ = shim.nogui_macos_frame_unlock_write(buffer);
    held = false;
}

/// Describe a pixel buffer as a frame the host can upload.
///
/// The returned descriptor owns ONE reference to `buffer` through its
/// `release_fn`, whether the mode borrowed or copied: `describe` retains
/// before it hands the frame back, and `Holder.release` drops exactly that
/// one. A caller that keeps its own reference releases that one itself with
/// `releaseReference`; a caller that handed its reference to the frame must
/// not.
pub fn describe(gpa: std.mem.Allocator, buffer: *anyopaque, mode: CopyMode) Error!Outcome {
    if (!native.available) return error.ShimUnavailable;
    // SAFETY: `nogui_macos_frame_lock` writes the locked layout into this
    // record, and every field below is read only after a `.ok` lock status.
    var layout: shim.nogui_macos_frame_layout = undefined;
    const locked = Status.of(shim.nogui_macos_frame_lock(buffer, &layout));
    switch (locked) {
        .ok => {},
        // The lock is what refuses on a GPU-backed buffer, and that is the one
        // answer this adapter must not work around.
        .unavailable => return .not_cpu_addressible,
        else => |status| return native.fail(status),
    }

    // From here the buffer is locked, so every path out has to unlock it. The
    // refusals below are VALUES, not errors, so `errdefer` would not run for
    // any of them and the buffer would stay locked for a producer that wants
    // to reuse it. `held` is cleared only where the lock is genuinely given
    // up, which also stops the owned path from unlocking twice.
    var held = true;
    defer if (held) {
        _ = shim.nogui_macos_frame_unlock(buffer);
    };

    const format = formatOf(layout.pixel_format) orelse return .format_unsupported;
    if (layout.width == 0 or layout.height == 0) return .geometry_invalid;
    const plane_count: usize = @intCast(layout.plane_count);
    if (plane_count == 0 or plane_count > layout.planes.len) return .geometry_invalid;

    var planes: [4]PlaneDescriptor = @splat(.{});
    for (0..plane_count) |index| {
        const plane = layout.planes[index];
        if (plane.data == null or plane.stride == 0 or plane.width == 0) return .geometry_invalid;
        const length: usize = @intCast(plane.len);
        if (length == 0) return .geometry_invalid;
        planes[index] = .{
            .offset = 0,
            .stride = plane.stride,
            .width = plane.width,
            .height = plane.height,
            .size = length,
        };
    }

    if (mode == .borrowed) {
        const base = layout.base orelse return .geometry_invalid;
        // A plane outside the base allocation cannot be given an offset, and
        // inventing one would read memory the descriptor does not own.
        for (0..plane_count) |index| {
            const plane = layout.planes[index];
            const start = @intFromPtr(plane.data.?);
            const base_start = @intFromPtr(base);
            const end = base_start + layout.base_len;
            if (start < base_start or start + plane.len > end) return .out_of_range;
            planes[index].offset = start - base_start;
        }
        const holder = try adopt(gpa, buffer, null, 0);
        holder.locked = true;
        // The holder owns the lock now and unlocks it when the frame is
        // released, so this function must not unlock it as well.
        held = false;
        return .{ .frame = .{
            .width = layout.width,
            .height = layout.height,
            .format = format,
            .color_space = colorSpaceOf(layout.color_space),
            .alpha_type = alphaTypeOf(format, layout.unpremultiplied != 0),
            .stride = layout.bytes_per_row,
            .planes = planes,
            .plane_count = @intCast(plane_count),
            .pixels = base,
            .release_fn = Holder.release,
            .release_ctx = @ptrCast(holder),
        } };
    }

    // The owned path copies plane by plane, so a planar buffer keeps its plane
    // geometry instead of being flattened into something the host misreads.
    var total: usize = 0;
    for (0..plane_count) |index| {
        const plane = layout.planes[index];
        total = std.math.add(usize, total, @intCast(plane.len)) catch return .out_of_memory;
    }
    if (total == 0) return .geometry_invalid;
    const copy = gpa.alloc(u8, total) catch return .out_of_memory;
    errdefer gpa.free(copy);

    var written: usize = 0;
    for (0..plane_count) |index| {
        const plane = layout.planes[index];
        const length: usize = @intCast(plane.len);
        const source = plane.data.?[0..length];
        @memcpy(copy[written..][0..length], source);
        planes[index].offset = written;
        planes[index].size = length;
        written += length;
    }
    // The copy is the frame's memory now, so the buffer is unlocked at once
    // and the frame no longer depends on the producer's buffer.
    _ = shim.nogui_macos_frame_unlock(buffer);
    held = false;
    const holder = try adopt(gpa, buffer, copy, total);
    holder.locked = false;
    return .{ .frame = .{
        .width = layout.width,
        .height = layout.height,
        .format = format,
        .color_space = colorSpaceOf(layout.color_space),
        .alpha_type = alphaTypeOf(format, layout.unpremultiplied != 0),
        .stride = layout.bytes_per_row,
        .planes = planes,
        .plane_count = @intCast(plane_count),
        .pixels = copy.ptr,
        .release_fn = Holder.release,
        .release_ctx = @ptrCast(holder),
    } };
}

/// The one place a frame takes a reference of its own.
///
/// The retain is the LAST statement and nothing below it can fail, so the pair
/// is balanced by construction: either `gpa.create` refused and no reference
/// was taken, or the holder exists and owns exactly the one reference
/// `Holder.release` drops. A caller that passes a borrowed buffer therefore
/// keeps its own reference for the whole lifetime of the frame.
fn adopt(
    gpa: std.mem.Allocator,
    buffer: *anyopaque,
    copy: ?[]u8,
    copy_len: usize,
) Error!*Holder {
    const holder = gpa.create(Holder) catch return error.OutOfMemory;
    holder.* = .{
        .gpa = gpa,
        .buffer = buffer,
        .copy = copy,
        .copy_len = copy_len,
        .locked = false,
        .released = false,
    };
    retain(buffer);
    return holder;
}

fn colorSpaceOf(value: c_int) ColorSpace {
    return switch (value) {
        0 => .srgb,
        1 => .display_p3,
        2 => .linear,
        // A buffer with no colour-space attachment is described as sRGB,
        // which is what CoreVideo's own default is. It is a stated default,
        // not a measurement.
        else => .srgb,
    };
}

fn alphaTypeOf(format: PixelFormat, unpremultiplied: bool) AlphaType {
    return switch (format) {
        .rgb8, .r8, .yuv420p, .nv12 => .fully_opaque,
        .bgra8, .rgba8 => if (unpremultiplied) .unpremultiplied else .premultiplied,
    };
}

test "api-w23 macos pixel formats round trip through their codes" {
    for ([_]PixelFormat{ .bgra8, .rgba8, .rgb8, .r8, .nv12, .yuv420p }) |format| {
        const code = codeOf(format).?;
        try std.testing.expectEqual(format, formatOf(code).?);
    }
    // A code with no layout is named, never guessed at.
    try std.testing.expect(formatOf(fourcc("YUV2")) == null);
}

test "api-w23 macos planar and packed formats name their own alpha" {
    // A format with no alpha channel cannot claim one, and a 32-bit buffer
    // follows the buffer's own alpha-info attachment.
    try std.testing.expectEqual(AlphaType.fully_opaque, alphaTypeOf(.rgb8, false));
    try std.testing.expectEqual(AlphaType.fully_opaque, alphaTypeOf(.nv12, false));
    try std.testing.expectEqual(AlphaType.fully_opaque, alphaTypeOf(.yuv420p, false));
    try std.testing.expectEqual(AlphaType.premultiplied, alphaTypeOf(.bgra8, false));
    try std.testing.expectEqual(AlphaType.unpremultiplied, alphaTypeOf(.bgra8, true));
    try std.testing.expectEqual(AlphaType.premultiplied, alphaTypeOf(.rgba8, false));
}

test "api-w23 macos frame release is exactly once" {
    // The descriptor's own contract is what makes a double release safe, so
    // the test drives that contract rather than the holder's allocator path.
    var released: usize = 0;
    var frame: FrameDescriptor = .{
        .width = 2,
        .height = 2,
        .format = .bgra8,
        .stride = 8,
        .release_fn = struct {
            fn call(context: ?*anyopaque) void {
                const counter: *usize = @ptrCast(@alignCast(context.?));
                counter.* += 1;
            }
        }.call,
        .release_ctx = @ptrCast(&released),
    };
    frame.release();
    try std.testing.expectEqual(@as(usize, 1), released);
    frame.release();
    try std.testing.expectEqual(@as(usize, 1), released);
}
