//! A reusable image leaf. Its descriptor borrows a host GPU texture slot; it
//! never owns image pixels or a graphics handle. The owner keeps that slot
//! pinned for all in-flight frames and passes the current asset generation.
const std = @import("std");
const element = @import("element.zig");
const widget = @import("widget.zig");
const painting = @import("paint.zig");
const image_types = @import("image_types.zig");
const frame_demand = @import("frame_demand.zig");
const WidgetId = @import("id.zig").WidgetId;

/// A slot from the host's bindless texture heap, not a decoded-image cache ID.
pub const TextureRef = image_types.TextureSlot;

pub const Source = union(enum) {
    pending,
    failed,
    ready: TextureRef,
    /// A multi-frame timeline. The view samples it at `elapsed_ns`; the host
    /// keeps every slot it names pinned for as long as the sequence lives.
    animating: image_types.ImageSequence,
};

pub const ImageView = struct {
    intrinsic: image_types.Size,
    source: Source = .pending,
    /// Current asset generation. A ready slot from another generation is stale.
    generation: u64 = 0,
    /// Set when the payload changes so callers can invalidate cached layout.
    revision: u64 = 0,
    fit: image_types.ObjectFit = .contain,
    alignment: image_types.Alignment = .center,
    /// Desaturation mixed into the sampled image. The amount is carried on the
    /// paint record, so the renderer applies it in Oklab together with the
    /// frame's other color transforms. It is validated here, in the range the
    /// renderer accepts, so an out-of-range value is refused at the element
    /// instead of reaching a shader as a silent no-op.
    grayscale: image_types.Grayscale = .none,
    /// Nanoseconds since the start of the sequence that select the frame an
    /// `animating` source shows. The other source states ignore it. The owner
    /// stamps it from the same clock reading it passes to `requestFrameAt`, so
    /// the painted frame and the requested wake come from one anchor.
    elapsed_ns: u64 = 0,
    label: []const u8 = "",

    /// Distinct visible states; the caller can replace the authored colors.
    pending_fill: painting.Color = .{ .srgb = .{ .r = 0.18, .g = 0.20, .b = 0.23 } },
    failed_fill: painting.Color = .{ .srgb = .{ .r = 0.48, .g = 0.16, .b = 0.19 } },

    pub const PhaseState = struct {};

    /// Publishes what this view owes the W05 frame demand, and folds the
    /// earliest outstanding deadline into `demand`.
    ///
    /// One call per animated view per frame, beside the host's own
    /// `setDeadline(app.animationDemand(now, interval))`: the earlier of the
    /// two deadlines survives, so a scalar timeline and an animated image wake
    /// the same host once instead of each running a loop. Nothing here starts a
    /// timer, a thread or a continuous draw; the registry only records what is
    /// owed and the host decides when to sleep.
    ///
    /// A source that is not animating, a timeline whose slots belong to another
    /// generation and a timeline that cannot be painted at all all retire this
    /// owner instead of arming a wake, which is what stops the frame loop once
    /// the image is over or gone.
    pub fn requestFrameAt(
        self: *const ImageView,
        owner: WidgetId,
        requests: *image_types.FrameRequests,
        demand: *frame_demand.FrameDemand,
        now_ns: u64,
    ) image_types.FrameRequests.Error!void {
        switch (self.source) {
            .animating => |sequence| {
                if (!sequence.isValid() or !self.generationMatches(sequence)) {
                    requests.retire(owner);
                    return;
                }
                try requests.publish(owner, sequence, self.elapsed_ns, now_ns);
            },
            .pending, .failed, .ready => requests.retire(owner),
        }
        // No owed deadline leaves the host's own value alone rather than
        // clearing a wake this view never set.
        const owed = requests.demand(now_ns).deadline_ms orelse return;
        demand.setDeadline(if (demand.deadline_ms) |earlier_ms| @min(earlier_ms, owed) else owed);
    }

    /// True when every frame of the timeline names this view's current
    /// generation. Paint applies the same rule per frame, so a timeline that
    /// fails it draws the pending fill for the stale frames. The frame REQUEST
    /// is stricter on purpose: a timeline that mixes texture generations is
    /// one asset version that cannot be presented consistently, so it is
    /// refused as a whole rather than half-animated.
    fn generationMatches(self: *const ImageView, sequence: image_types.ImageSequence) bool {
        for (sequence.frames) |frame| {
            if (frame.slot.generation != self.generation) return false;
        }
        return true;
    }

    pub fn measure(self: *const ImageView, input: element.MeasureInput) element.Error!widget.Size {
        if (!self.intrinsic.isPositive() or !self.grayscale.isValid()) return error.InvalidStyle;
        const width = input.known_dimensions.width;
        const height = input.known_dimensions.height;
        if (width) |w| {
            if (!std.math.isFinite(w) or w < 0) return error.InvalidStyle;
        }
        if (height) |h| {
            if (!std.math.isFinite(h) or h < 0) return error.InvalidStyle;
        }
        if (width != null and height != null) return .{ .width = width.?, .height = height.? };
        if (width) |w| return .{ .width = w, .height = w * (self.intrinsic.height / self.intrinsic.width) };
        if (height) |h| return .{ .width = h * (self.intrinsic.width / self.intrinsic.height), .height = h };
        return .{ .width = self.intrinsic.width, .height = self.intrinsic.height };
    }

    pub fn paint(
        self: *const ImageView,
        _: *PhaseState,
        geometry: element.Geometry,
        writer: *element.PaintWriter,
    ) element.Error!void {
        const content = geometry.content;
        if (!self.intrinsic.isPositive() or !self.grayscale.isValid() or
            !std.math.isFinite(content.w) or !std.math.isFinite(content.h) or
            content.w < 0 or content.h < 0) return error.InvalidPaint;
        if (content.w == 0 or content.h == 0) return;
        const texture: ?TextureRef = switch (self.source) {
            .ready => |ref| if (ref.isValid() and ref.generation == self.generation) ref else null,
            .animating => |sequence| blk: {
                if (!sequence.isValid()) return error.InvalidPaint;
                const frame = sequence.frameAt(self.elapsed_ns) orelse break :blk null;
                break :blk if (frame.slot.isValid() and frame.slot.generation == self.generation)
                    frame.slot
                else
                    null;
            },
            .pending, .failed => null,
        };
        if (texture) |ref| {
            const fitted = image_types.fitRect(self.fit, self.intrinsic, .{
                .x = 0,
                .y = 0,
                .w = content.w,
                .h = content.h,
            }, self.alignment);
            if (!fitted.isFinite() or !self.alignment.isValid()) return error.InvalidPaint;
            if (fitted.w <= 0 or fitted.h <= 0) return;
            const x = @max(0, fitted.x);
            const y = @max(0, fitted.y);
            const right = @min(content.w, fitted.x + fitted.w);
            const bottom = @min(content.h, fitted.y + fitted.h);
            if (right <= x or bottom <= y) return;
            // Crop destination and UV together, even with no ancestor clip.
            // Clamp rounded right/bottom edges before validating normalized UVs.
            const u_start = std.math.clamp((x - fitted.x) / fitted.w, 0, 1);
            const v0 = std.math.clamp((y - fitted.y) / fitted.h, 0, 1);
            const u_end = std.math.clamp((right - fitted.x) / fitted.w, 0, 1);
            const v1 = std.math.clamp((bottom - fitted.y) / fitted.h, 0, 1);
            if (u_end <= u_start or v1 <= v0) return;
            try writer.addImage(.{
                .bounds = .{ .x = x, .y = y, .w = right - x, .h = bottom - y },
                .src = .{ .x = u_start, .y = v0, .w = u_end - u_start, .h = v1 - v0 },
                .texture_index = ref.index,
                .grayscale = self.grayscale.amount,
            });
        } else {
            try writer.addRect(.{
                .bounds = .{ .x = 0, .y = 0, .w = content.w, .h = content.h },
                .fill = .{ .solid = if (self.source == .failed) self.failed_fill else self.pending_fill },
            });
        }
    }

    pub fn semantics(self: *const ImageView, _: *PhaseState, _: element.Geometry) element.Error!?element.Semantic {
        return .{ .role = .image, .label = self.label };
    }
};
