//! Core value types for image representation, object-fit layout calculations,
//! and frame descriptors. Independent of host graphics APIs and window systems.
const std = @import("std");
const WidgetId = @import("id.zig").WidgetId;

/// Sizing and positioning mode for fitting an image into a destination rectangle.
pub const ObjectFit = enum {
    /// Stretch image to fill destination box, ignoring aspect ratio.
    fill,
    /// Scale image uniformly to maintain aspect ratio while fitting inside destination box.
    contain,
    /// Scale image uniformly to maintain aspect ratio while filling destination box; may crop.
    cover,
    /// Keep intrinsic image size without scaling.
    none,
    /// Behave as either `none` or `contain`, whichever produces smaller dimensions.
    scale_down,
};

/// Fractional alignment within a bounding box. 0.0 is top/left, 0.5 is center, 1.0 is bottom/right.
pub const Alignment = struct {
    x: f32 = 0.5,
    y: f32 = 0.5,

    pub const center: Alignment = .{ .x = 0.5, .y = 0.5 };
    pub const top_left: Alignment = .{ .x = 0.0, .y = 0.0 };
    pub const top_right: Alignment = .{ .x = 1.0, .y = 0.0 };
    pub const bottom_left: Alignment = .{ .x = 0.0, .y = 1.0 };
    pub const bottom_right: Alignment = .{ .x = 1.0, .y = 1.0 };

    pub fn isValid(self: Alignment) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y);
    }
};

/// 2D float point.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// 2D float dimensions.
pub const Size = struct {
    width: f32,
    height: f32,

    pub fn isPositive(self: Size) bool {
        return std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            self.width > 0.0 and self.height > 0.0;
    }
};

/// 2D float rectangle.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn isFinite(self: Rect) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and
            std.math.isFinite(self.w) and std.math.isFinite(self.h);
    }
};

/// Computes the destination rectangle for an image with the given intrinsic size
/// inside a container bounds using the specified ObjectFit and Alignment.
pub fn fitRect(
    fit: ObjectFit,
    intrinsic: Size,
    destination: Rect,
    alignment: Alignment,
) Rect {
    if (!intrinsic.isPositive() or destination.w <= 0.0 or destination.h <= 0.0) {
        return .{ .x = destination.x, .y = destination.y, .w = 0.0, .h = 0.0 };
    }

    const align_x = if (alignment.isValid()) alignment.x else 0.5;
    const align_y = if (alignment.isValid()) alignment.y else 0.5;

    var target_w: f32 = destination.w;
    var target_h: f32 = destination.h;

    switch (fit) {
        .fill => {
            target_w = destination.w;
            target_h = destination.h;
        },
        .contain => {
            const rx = destination.w / intrinsic.width;
            const ry = destination.h / intrinsic.height;
            const scale = @min(rx, ry);
            target_w = intrinsic.width * scale;
            target_h = intrinsic.height * scale;
        },
        .cover => {
            const rx = destination.w / intrinsic.width;
            const ry = destination.h / intrinsic.height;
            const scale = @max(rx, ry);
            target_w = intrinsic.width * scale;
            target_h = intrinsic.height * scale;
        },
        .none => {
            target_w = intrinsic.width;
            target_h = intrinsic.height;
        },
        .scale_down => {
            if (intrinsic.width <= destination.w and intrinsic.height <= destination.h) {
                target_w = intrinsic.width;
                target_h = intrinsic.height;
            } else {
                const rx = destination.w / intrinsic.width;
                const ry = destination.h / intrinsic.height;
                const scale = @min(rx, ry);
                target_w = intrinsic.width * scale;
                target_h = intrinsic.height * scale;
            }
        },
    }

    const pos_x = destination.x + (destination.w - target_w) * align_x;
    const pos_y = destination.y + (destination.h - target_h) * align_y;

    return .{
        .x = pos_x,
        .y = pos_y,
        .w = target_w,
        .h = target_h,
    };
}

/// Pixel storage format for raw, decoded or streaming buffers.
pub const PixelFormat = enum {
    rgba8,
    bgra8,
    rgb8,
    r8,
    yuv420p,
    nv12,

    pub fn bytesPerPixel(self: PixelFormat) ?usize {
        return switch (self) {
            .rgba8, .bgra8 => 4,
            .rgb8 => 3,
            .r8 => 1,
            .yuv420p, .nv12 => null,
        };
    }

    pub fn isPlanar(self: PixelFormat) bool {
        return switch (self) {
            .yuv420p, .nv12 => true,
            else => false,
        };
    }

    pub fn channelCount(self: PixelFormat) u8 {
        return switch (self) {
            .rgba8, .bgra8 => 4,
            .rgb8 => 3,
            .r8 => 1,
            .yuv420p, .nv12 => 3,
        };
    }
};

/// Color representation space.
pub const ColorSpace = enum {
    srgb,
    linear,
    display_p3,
};

/// Alpha channel compositing mode.
pub const AlphaType = enum {
    fully_opaque,
    premultiplied,
    unpremultiplied,
};

/// Buffer plane description for planar video formats.
pub const PlaneDescriptor = struct {
    offset: usize = 0,
    stride: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    size: usize = 0,
};

/// Complete metadata and buffer descriptor for an owned or external video/image frame.
pub const FrameDescriptor = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    color_space: ColorSpace = .srgb,
    alpha_type: AlphaType = .premultiplied,
    stride: u32,
    presentation_timestamp_ns: i96 = 0,
    duration_ns: ?u64 = null,
    planes: [4]PlaneDescriptor = [_]PlaneDescriptor{.{}} ** 4,
    plane_count: u8 = 1,
    /// Base of the packed buffer, or of plane 0 for a planar format.
    /// Null when the payload is reached another way; callers that need the
    /// bytes must not assume it is set.
    pixels: ?[*]const u8 = null,
    user_data: usize = 0,
    release_fn: ?*const fn (ctx: ?*anyopaque) void = null,
    release_ctx: ?*anyopaque = null,

    /// Releases external producer resources associated with this frame exactly once.
    /// A frame obtained from `FrameSource.acquireLatest` must be returned
    /// through `FrameSource.releaseFrame` or `FrameSource.presentFrame` instead
    /// of this call: those paths account the return so the source can tell a
    /// provider that no consumer still holds a buffer. Calling this directly on
    /// an acquired frame releases the buffer but leaves that accounting wrong.
    pub fn release(self: *FrameDescriptor) void {
        if (self.release_fn) |f| {
            self.release_fn = null;
            const ctx = self.release_ctx;
            self.release_ctx = null;
            f(ctx);
        }
    }

    /// Computes the total buffer byte size described by this descriptor.
    pub fn totalBytes(self: FrameDescriptor) usize {
        if (self.format.isPlanar()) {
            var sum: usize = 0;
            var i: usize = 0;
            while (i < self.plane_count and i < self.planes.len) : (i += 1) {
                sum += self.planes[i].size;
            }
            return sum;
        }
        return @as(usize, self.stride) * @as(usize, self.height);
    }
};

/// A slot in the host's bindless texture heap. The generation changes when
/// the host reuses the slot, so a reference to a retired slot is detectable
/// instead of silently sampling whatever its next owner uploaded.
pub const TextureSlot = struct {
    index: u32,
    generation: u64,

    /// What a host reports when nothing is bound. A paint consumer must
    /// refuse it instead of sampling heap index 0xFFFFFFFF.
    pub const invalid: TextureSlot = .{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn isValid(self: TextureSlot) bool {
        return self.index != std.math.maxInt(u32);
    }

    /// True when both fields match, so a stale reference never passes for a
    /// live one whose raw index has been handed out again.
    pub fn eql(a: TextureSlot, b: TextureSlot) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// Desaturation of a sampled image. The frame is sampled in Oklab, so the
/// amount is the fraction of CHROMA removed: the renderer scales the Oklab a
/// and b channels by `1 - amount`, which leaves the perceptual lightness of
/// the source untouched. This is not the gamma-coded Rec. 709 luminance a CPU
/// byte conversion computes, and the two are deliberately not interchangeable.
pub const Grayscale = struct {
    /// Fraction of chroma removed, 0 through 1.
    amount: f32 = 0.0,

    /// The authored default: the frame keeps its color.
    pub const none: Grayscale = .{};
    /// Every pixel becomes the neutral of its own lightness.
    pub const full: Grayscale = .{ .amount = 1.0 };

    /// True for an amount the renderer can scale chroma by. A value outside
    /// the range is refused at the element rather than clamped silently, so an
    /// authored mistake cannot read as a weaker filter than it asked for.
    pub fn isValid(self: Grayscale) bool {
        return std.math.isFinite(self.amount) and self.amount >= 0.0 and self.amount <= 1.0;
    }
};

/// One decoded frame of an animated image: the host slot its uploaded pixels
/// live in, and how long the frame stays on screen. A frame borrows its slot.
/// The owner keeps that slot pinned for as long as any live frame reads it,
/// so raw slot reuse cannot change an image a view is still showing.
pub const ImageFrame = struct {
    /// The heap slot this frame was uploaded to.
    slot: TextureSlot,
    /// How long the frame stays on screen. Null takes the sequence default.
    duration_ns: ?u64 = null,
};

/// A borrowed multi-frame timeline. It owns no pixels and no slots: it maps a
/// clock reading onto the frame an element must sample. This is the image
/// frame sequence an element plays, not the scalar property timeline in
/// `animation.zig`, and it counts in the nanoseconds `FrameDescriptor` uses.
///
/// The wrap period is always DERIVED from the frames, never stored beside
/// them. A caller-supplied total could disagree with the durations the walk
/// actually uses, and a sequence whose cached total disagreed with its frames
/// would select the wrong frame with no way to notice. Every sum here
/// saturates, so a caller that supplies absurd durations gets a refused
/// sequence from `isValid` and a defined frame from `frameAt`, never an
/// overflow panic and never a division by zero.
pub const ImageSequence = struct {
    /// The duration a frame contributes when it declares none, and the period
    /// a sequence wraps over when its frames declare none either. One value
    /// for both, so the two call sites cannot drift apart.
    pub const default_duration_ns: u64 = 100 * std.time.ns_per_ms;

    frames: []const ImageFrame,
    /// A non-looping sequence reports its end through `isComplete`; the
    /// element keeps sampling the last frame until the caller retires it.
    loop: bool = true,

    pub fn init(frames: []const ImageFrame, loop: bool) ImageSequence {
        return .{ .frames = frames, .loop = loop };
    }

    pub fn frameCount(self: ImageSequence) usize {
        return self.frames.len;
    }

    /// The frame's own duration, or the sequence default.
    pub fn durationOf(_: ImageSequence, frame: ImageFrame) u64 {
        return frame.duration_ns orelse default_duration_ns;
    }

    /// The wrap period, never zero: an empty sequence and a sum that
    /// overflows both report the default rather than a value a caller could
    /// divide by.
    pub fn totalDurationNs(self: ImageSequence) u64 {
        var total: u64 = 0;
        for (self.frames) |frame| {
            total = std.math.add(u64, total, self.durationOf(frame)) catch
                return default_duration_ns;
        }
        return if (total == 0) default_duration_ns else total;
    }

    /// A timeline an element can sample: at least one frame, every slot
    /// bound, every frame lasting at least one nanosecond, and a total the
    /// sum of those durations can actually represent.
    pub fn isValid(self: ImageSequence) bool {
        if (self.frames.len == 0) return false;
        var total: u64 = 0;
        for (self.frames) |frame| {
            if (!frame.slot.isValid()) return false;
            const duration = self.durationOf(frame);
            if (duration == 0) return false;
            total = std.math.add(u64, total, duration) catch return false;
        }
        return total != 0;
    }

    /// The frame on screen `elapsed_ns` after the sequence started, or null
    /// only when the sequence carries no frames. A non-looping sequence past
    /// its end keeps returning its last frame, so an element that retires the
    /// source is what ends the image, not a clock reading.
    pub fn frameAt(self: ImageSequence, elapsed_ns: u64) ?ImageFrame {
        if (self.frames.len == 0) return null;
        if (self.frames.len == 1) return self.frames[0];

        const period = self.totalDurationNs();
        const elapsed = if (self.loop) elapsed_ns % period else @min(elapsed_ns, period);
        var accum: u64 = 0;
        for (self.frames) |frame| {
            accum = std.math.add(u64, accum, self.durationOf(frame)) catch period;
            if (elapsed < accum) return frame;
        }
        return self.frames[self.frames.len - 1];
    }

    /// True once a non-looping sequence has shown its last frame. A looping
    /// sequence is never complete.
    pub fn isComplete(self: ImageSequence, elapsed_ns: u64) bool {
        return !self.loop and elapsed_ns >= self.totalDurationNs();
    }

    /// When the next frame starts, or null once a non-looping sequence has
    /// ended and a single-frame sequence has nothing to switch to.
    pub fn nextDeadlineNs(self: ImageSequence, elapsed_ns: u64) ?u64 {
        if (self.frames.len <= 1) return null;
        const period = self.totalDurationNs();
        if (!self.loop and elapsed_ns >= period) return null;

        const base = (elapsed_ns / period) * period;
        const elapsed = elapsed_ns - base;
        var accum: u64 = 0;
        for (self.frames) |frame| {
            accum = std.math.add(u64, accum, self.durationOf(frame)) catch period;
            if (accum > elapsed) return std.math.add(u64, base, accum) catch base + period;
        }
        return std.math.add(u64, base, period) catch period;
    }
};

/// Whole milliseconds elapsed at `deadline_ns`, rounded UP.
///
/// W05 frame demand counts in absolute milliseconds while this timeline counts
/// in nanoseconds, so a frame boundary has to round up: rounding down would
/// wake the host before the transition and repaint the frame that is already
/// on screen. Division keeps the increment in range for every `u64`, so a
/// saturating deadline stays a finite millisecond value instead of wrapping
/// to zero and firing immediately.
pub fn ceilMilliseconds(deadline_ns: u64) u64 {
    return deadline_ns / std.time.ns_per_ms +
        @intFromBool(deadline_ns % std.time.ns_per_ms != 0);
}

/// What the animated images of one window owe the W05 frame demand.
pub const ImageDemand = struct {
    /// True while at least one published timeline can still change. A
    /// timeline that has run out reports no deadline at all, which is what
    /// lets an idle window sleep instead of spinning on a finished image.
    active: bool = false,
    /// Absolute monotonic milliseconds, the unit `FrameDemand` speaks. Null
    /// when nothing is owed.
    deadline_ms: ?u64 = null,
};

/// The animated timelines one window has published, and the earliest wake they
/// owe. This is the W05 seam for images: it records what a frame is owed and
/// converts it to the millisecond deadline `FrameDemand.setDeadline` takes,
/// so an animated image rides the existing frame loop instead of running a
/// scheduler, a timer thread or a continuous draw of its own.
///
/// Entries are keyed by the widget that shows the image, and every entry is
/// scoped to one identity owner, so a handle from another window cannot arm a
/// wake here. Publishing borrows the timeline: the borrowed frames have to
/// outlive the entry, so a caller retires the owner or republishes before the
/// sequence that owns them is released.
pub const FrameRequests = struct {
    pub const Error = std.mem.Allocator.Error || error{
        WrongOwner,
        InvalidSequence,
    };

    pub const Entry = struct {
        owner: WidgetId,
        sequence: ImageSequence,
        /// Absolute monotonic nanoseconds at which this timeline started. The
        /// deadline is derived from this anchor and the sequence's own
        /// durations, never from a total a caller could contradict.
        start_ns: u64,
    };

    gpa: std.mem.Allocator,
    widget_owner: u64,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator, widget_owner: u64) FrameRequests {
        std.debug.assert(widget_owner != 0);
        return .{ .gpa = gpa, .widget_owner = widget_owner };
    }

    pub fn deinit(self: *FrameRequests) void {
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Publishes or replaces the timeline one owner shows. `elapsed_ns` is the
    /// reading the owner already stamped its element with, and `now_ns` is
    /// that same clock instant, so the frame it paints and the frame this
    /// registry wakes for cannot come from two different anchors.
    pub fn publish(
        self: *FrameRequests,
        owner: WidgetId,
        sequence: ImageSequence,
        elapsed_ns: u64,
        now_ns: u64,
    ) Error!void {
        if (owner.owner != self.widget_owner) return error.WrongOwner;
        if (!sequence.isValid()) return error.InvalidSequence;
        const entry: Entry = .{
            .owner = owner,
            .sequence = sequence,
            .start_ns = now_ns -| elapsed_ns,
        };
        for (self.entries.items) |*published| {
            if (published.owner.eql(owner)) {
                published.* = entry;
                return;
            }
        }
        try self.entries.append(self.gpa, entry);
    }

    /// The earliest wake every published timeline still owes at `now_ns`.
    /// A looping timeline always owes one, a finished non-looping timeline and
    /// a single-frame image owe nothing, and a retired owner contributes
    /// nothing at all: an image the window can no longer paint must not keep
    /// the host awake.
    pub fn demand(self: *const FrameRequests, now_ns: u64) ImageDemand {
        var result: ImageDemand = .{};
        for (self.entries.items) |*entry| {
            const elapsed = now_ns -| entry.start_ns;
            const deadline_ns = entry.sequence.nextDeadlineNs(elapsed) orelse continue;
            const absolute_ns = std.math.add(u64, entry.start_ns, deadline_ns) catch std.math.maxInt(u64);
            const deadline_ms = ceilMilliseconds(absolute_ns);
            result.active = true;
            result.deadline_ms = if (result.deadline_ms) |earlier_ms|
                @min(earlier_ms, deadline_ms)
            else
                deadline_ms;
        }
        return result;
    }

    /// Drops one owner's timeline: its source was released, or the widget that
    /// showed it left the tree. A handle from another window retires nothing,
    /// so a foreign call cannot silence a live image.
    pub fn retire(self: *FrameRequests, owner: WidgetId) void {
        if (owner.owner != self.widget_owner) return;
        for (self.entries.items, 0..) |entry, index| {
            if (!entry.owner.eql(owner)) continue;
            _ = self.entries.swapRemove(index);
            return;
        }
    }

    /// Drops every published timeline, for a window that is tearing down.
    pub fn clear(self: *FrameRequests) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn count(self: *const FrameRequests) usize {
        return self.entries.items.len;
    }
};
