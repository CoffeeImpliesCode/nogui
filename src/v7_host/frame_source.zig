//! External frame streaming, format negotiation, backpressure management,
//! and consumer lifetime contracts for video and capture frame sources.
const std = @import("std");
const image_mod = @import("image.zig");

pub const PixelFormat = image_mod.PixelFormat;
pub const ColorSpace = image_mod.ColorSpace;
pub const AlphaType = image_mod.AlphaType;
pub const FrameDescriptor = image_mod.FrameDescriptor;
const PlaneDescriptor = image_mod.PlaneDescriptor;
pub const DecodedImage = image_mod.DecodedImage;
pub const ImageFrame = image_mod.ImageFrame;
pub const ImageSequence = image_mod.ImageSequence;
pub const TextureHandle = image_mod.TextureHandle;
const image_types = image_mod.image_types;
pub const TextureRegistry = image_mod.TextureRegistry;

/// Format negotiation helper matching producer capabilities against consumer support.
pub const FormatNegotiator = struct {
    supported_formats: []const PixelFormat,

    pub fn isSupported(self: FormatNegotiator, format: PixelFormat) bool {
        for (self.supported_formats) |f| {
            if (f == format) return true;
        }
        return false;
    }

    pub fn negotiate(self: FormatNegotiator, requested: PixelFormat) !PixelFormat {
        if (self.isSupported(requested)) return requested;

        // Fallback to first supported format
        if (self.supported_formats.len > 0) {
            return self.supported_formats[0];
        }
        return error.UnsupportedFormat;
    }
};

/// A streaming frame source managing frame delivery, bounded backpressure,
/// consumer retention, and timely buffer releases.
pub const FrameSource = struct {
    pub const WakeCallback = *const fn (ctx: ?*anyopaque) void;

    gpa: std.mem.Allocator,
    io: std.Io,
    queue: std.ArrayListUnmanaged(FrameDescriptor) = .empty,
    queue_capacity: usize = 1,
    active_frame: ?FrameDescriptor = null,
    outstanding_frames: u32 = 0,
    mutex: std.Io.Mutex = .init,
    stopped: bool = false,
    wake_fn: ?WakeCallback = null,
    wake_ctx: ?*anyopaque = null,
    total_pushed: u64 = 0,
    total_dropped: u64 = 0,
    total_presented: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, max_capacity: usize) FrameSource {
        return .{
            .gpa = gpa,
            .io = io,
            .queue_capacity = @max(1, max_capacity),
        };
    }

    pub fn setWake(self: *FrameSource, ctx: ?*anyopaque, callback: ?WakeCallback) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.wake_ctx = ctx;
        self.wake_fn = callback;
    }

    /// Changes how many frames may wait for a consumer. A capacity below one
    /// is raised to one, because trimming to zero would release a frame the
    /// producer still considers pending.
    pub fn setMaxQueueCapacity(self: *FrameSource, max_capacity: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue_capacity = @max(1, max_capacity);
    }

    /// Takes ownership of a frame and offers it to consumers.
    /// The source releases the frame exactly once on every path: it is queued
    /// on success, dropped by backpressure, or released when the source is
    /// stopped or the queue could not grow. The caller must not release it.
    /// Under backpressure the oldest unconsumed frames are dropped so the
    /// newest frame stays available. A failed push leaves the queue untouched.
    /// Appending before trimming is what keeps that promise: the capacity is
    /// never below one, so trimming always stops before the frame this call
    /// just appended.
    pub fn pushFrame(self: *FrameSource, frame: FrameDescriptor) !void {
        var wake: ?WakeCallback = null;
        var wake_ctx: ?*anyopaque = null;

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var mut_frame = frame;
            errdefer mut_frame.release();

            if (self.stopped) return error.SourceStopped;

            // Queue before dropping, so an allocation failure cannot discard
            // frames that the producer still believes are pending.
            try self.queue.append(self.gpa, mut_frame);
            self.total_pushed += 1;

            while (self.queue.items.len > self.queue_capacity) {
                var oldest = self.queue.orderedRemove(0);
                oldest.release(); // Free external buffer immediately!
                self.total_dropped += 1;
            }

            // The wake runs after the lock is released so a consumer may
            // re-enter the source from its callback.
            wake = self.wake_fn;
            wake_ctx = self.wake_ctx;
        }

        if (wake) |notify| notify(wake_ctx);
    }

    /// Acquires the newest available frame for consumption.
    /// Ownership of the frame passes to the caller.
    /// Skips and immediately releases any older unconsumed intermediate frames.
    /// The caller MUST return the frame through `releaseFrame` or
    /// `presentFrame`, never through `FrameDescriptor.release` on the copy it
    /// holds: only those two paths account the return, and `deinit` refuses
    /// while a frame is still outstanding.
    pub fn acquireLatest(self: *FrameSource) ?FrameDescriptor {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.queue.items.len == 0) return null;

        // Skip older queued frames
        while (self.queue.items.len > 1) {
            var skipped = self.queue.orderedRemove(0);
            skipped.release();
            self.total_dropped += 1;
        }

        self.outstanding_frames += 1;
        return self.queue.orderedRemove(0);
    }

    /// Acquires the oldest queued frame without dropping the newer ones, so a
    /// consumer that assembles a sequence reads the producer's frames in the
    /// order they were pushed. The ownership and return rules are
    /// `acquireLatest`'s: the caller holds one reference and MUST return the
    /// frame through `releaseFrame` or `presentFrame`.
    pub fn acquireOldest(self: *FrameSource) ?FrameDescriptor {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.queue.items.len == 0) return null;

        self.outstanding_frames += 1;
        return self.queue.orderedRemove(0);
    }

    /// Returns an acquired frame to the source without presenting it and
    /// releases its buffer immediately. This is the companion of
    /// `acquireLatest` for a consumer that is done with a frame.
    pub fn releaseFrame(self: *FrameSource, frame: *FrameDescriptor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.outstanding_frames > 0) self.outstanding_frames -= 1;
        frame.release();
    }

    /// Frames a consumer acquired and has not returned yet.
    pub fn outstandingFrames(self: *FrameSource) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.outstanding_frames;
    }

    /// Presents a newly acquired frame, replacing the previously active frame.
    /// Takes ownership of the new frame.
    /// Returns a frame obtained from `acquireLatest` to the source's account,
    /// so `stop` reports only frames a consumer has not handed back.
    /// Releases the old frame's external buffer ONLY AFTER the new frame is installed.
    pub fn presentFrame(self: *FrameSource, new_frame: FrameDescriptor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var old = self.active_frame;
        self.active_frame = new_frame;
        self.total_presented += 1;
        // Presenting returns a frame acquired from this source. A frame the
        // source never handed out leaves the count at zero, never below.
        if (self.outstanding_frames > 0) self.outstanding_frames -= 1;

        // Release old frame buffer only after new frame is safely active
        if (old) |*o| {
            o.release();
        }
    }

    /// Retrieves the currently presented active frame without releasing it.
    pub fn getActiveFrame(self: *FrameSource) ?FrameDescriptor {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.active_frame;
    }

    /// Stops the frame source and releases every queued and retained frame.
    /// Returns the number of frames a consumer still holds from
    /// `acquireLatest`. A nonzero count means a release callback can still run
    /// after this source and its provider are gone, so a provider MUST release
    /// every acquired frame, then call `stop`, and only then tear the provider
    /// down. `deinit` refuses while that count is nonzero.
    pub fn stop(self: *FrameSource) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.stopped = true;

        // Release all queued frames
        for (self.queue.items) |*f| {
            f.release();
        }
        self.queue.clearRetainingCapacity();

        // Release currently retained frame
        if (self.active_frame) |*f| {
            f.release();
            self.active_frame = null;
        }

        return self.outstanding_frames;
    }

    pub const Error = error{
        /// `acquireLatest` or `acquireOldest` handed a frame out and the
        /// consumer has not returned it. The queue and the source itself are
        /// what such a frame's return path walks, so nothing is freed and the
        /// source stays usable: return the frame through `releaseFrame` or
        /// `presentFrame`, then call `deinit` again.
        FramesStillBorrowed,
    };

    /// Releases the queue and poisons the source.
    ///
    /// The refusal is a returned error rather than an assert because an assert
    /// is compiled out of a ReleaseFast build, and there the borrowed frame
    /// would be released into a freed source instead of naming the mistake.
    pub fn deinit(self: *FrameSource) Error!void {
        const borrowed = self.stop();
        if (borrowed != 0) {
            // A borrowed frame returns through this source's queue, so a
            // refusal leaves the source intact for the second call.
            return error.FramesStillBorrowed;
        }
        // The poison is registered once the refusal is behind the call, so
        // every path that reaches the release leaves the source dead behind it.
        defer self.* = undefined;
        self.queue.deinit(self.gpa);
    }
};

/// Adapter for uploading and converting FrameDescriptors into CPU/GPU-ready RGBA8 pixel buffers.
pub const CpuUploadAdapter = struct {
    pub const Options = struct {
        target_color_space: ColorSpace = .srgb,
        target_alpha_type: AlphaType = .premultiplied,
    };

    pub fn uploadToRgba(
        allocator: std.mem.Allocator,
        frame: FrameDescriptor,
        source_buffer: []const u8,
        options: Options,
    ) !DecodedImage {
        if (frame.width == 0 or frame.height == 0) return error.InvalidDimensions;

        const out_stride = std.math.mul(u32, frame.width, 4) catch return error.ImageTooLarge;
        const total_out_bytes = std.math.mul(usize, @as(usize, out_stride), @as(usize, frame.height)) catch
            return error.ImageTooLarge;
        const out_pixels = try allocator.alloc(u8, total_out_bytes);
        errdefer allocator.free(out_pixels);

        const src_stride = std.math.cast(usize, frame.stride) orelse return error.ImageTooLarge;

        switch (frame.format) {
            .rgba8, .bgra8, .rgb8, .r8 => {
                const bytes_per_pixel = frame.format.bytesPerPixel().?;
                const row_bytes = std.math.mul(usize, @as(usize, frame.width), bytes_per_pixel) catch
                    return error.ImageTooLarge;
                if (src_stride < row_bytes) return error.InvalidStride;
                const span = std.math.add(
                    usize,
                    src_stride,
                    std.math.mul(usize, @as(usize, frame.height) - 1, src_stride) catch
                        return error.ImageTooLarge,
                ) catch return error.ImageTooLarge;
                if (source_buffer.len < span) return error.BufferUnderflow;

                var y: u32 = 0;
                while (y < frame.height) : (y += 1) {
                    const src_offset = @as(usize, y) * src_stride;
                    const dst_offset = @as(usize, y) * @as(usize, out_stride);
                    const src_row = source_buffer[src_offset..][0..row_bytes];
                    const dst_row = out_pixels[dst_offset..][0..row_bytes];

                    var x: u32 = 0;
                    while (x < frame.width) : (x += 1) {
                        const s = @as(usize, x) * bytes_per_pixel;
                        const d = @as(usize, x) * 4;
                        switch (frame.format) {
                            .rgba8 => @memcpy(dst_row[d..][0..4], src_row[s..][0..4]),
                            .bgra8 => {
                                dst_row[d] = src_row[s + 2]; // R
                                dst_row[d + 1] = src_row[s + 1]; // G
                                dst_row[d + 2] = src_row[s]; // B
                                dst_row[d + 3] = src_row[s + 3]; // A
                            },
                            .rgb8 => {
                                dst_row[d] = src_row[s];
                                dst_row[d + 1] = src_row[s + 1];
                                dst_row[d + 2] = src_row[s + 2];
                                dst_row[d + 3] = 255;
                            },
                            .r8 => {
                                dst_row[d] = src_row[s];
                                dst_row[d + 1] = src_row[s];
                                dst_row[d + 2] = src_row[s];
                                dst_row[d + 3] = 255;
                            },
                            else => unreachable,
                        }
                    }
                }
            },
            .yuv420p => {
                // Planar YUV 4:2:0 -> RGBA conversion
                // Plane 0: Y (w x h), Plane 1: U (w/2 x h/2), Plane 2: V (w/2 x h/2)
                if (frame.plane_count < 3) return error.InvalidPlanarFormat;

                const chroma_width = (frame.width + 1) / 2;
                const chroma_height = (frame.height + 1) / 2;
                try requirePlane(source_buffer, frame.planes[0], frame.width, frame.height);
                try requirePlane(source_buffer, frame.planes[1], chroma_width, chroma_height);
                try requirePlane(source_buffer, frame.planes[2], chroma_width, chroma_height);

                const y_plane = frame.planes[0];
                const u_plane = frame.planes[1];
                const v_plane = frame.planes[2];

                var y: u32 = 0;
                while (y < frame.height) : (y += 1) {
                    const uv_y = y / 2;
                    const y_row = y_plane.offset + (@as(usize, y) * @as(usize, y_plane.stride));
                    const u_row = u_plane.offset + (@as(usize, uv_y) * @as(usize, u_plane.stride));
                    const v_row = v_plane.offset + (@as(usize, uv_y) * @as(usize, v_plane.stride));
                    const dst_row = @as(usize, y) * @as(usize, out_stride);

                    var x: u32 = 0;
                    while (x < frame.width) : (x += 1) {
                        const uv_x = x / 2;
                        const y_val: f32 = @floatFromInt(source_buffer[y_row + x]);
                        const u_val: f32 = @as(f32, @floatFromInt(source_buffer[u_row + uv_x])) - 128.0;
                        const v_val: f32 = @as(f32, @floatFromInt(source_buffer[v_row + uv_x])) - 128.0;

                        // Standard BT.601 conversion
                        const r_f = y_val + 1.402 * v_val;
                        const g_f = y_val - 0.344136 * u_val - 0.714136 * v_val;
                        const b_f = y_val + 1.772 * u_val;

                        const dst_idx = dst_row + (@as(usize, x) * 4);
                        out_pixels[dst_idx] = @intFromFloat(std.math.clamp(r_f, 0.0, 255.0));
                        out_pixels[dst_idx + 1] = @intFromFloat(std.math.clamp(g_f, 0.0, 255.0));
                        out_pixels[dst_idx + 2] = @intFromFloat(std.math.clamp(b_f, 0.0, 255.0));
                        out_pixels[dst_idx + 3] = 255;
                    }
                }
            },
            else => return error.UnsupportedFormat,
        }

        return .{
            .width = frame.width,
            .height = frame.height,
            .format = .rgba8,
            .color_space = options.target_color_space,
            .alpha_type = options.target_alpha_type,
            .stride = out_stride,
            .pixels = out_pixels,
            .duration_ns = frame.duration_ns,
            .allocator = allocator,
        };
    }

    /// Rejects a plane that does not cover its rows inside the source buffer.
    fn requirePlane(
        source_buffer: []const u8,
        plane: PlaneDescriptor,
        width: u32,
        height: u32,
    ) !void {
        const stride = std.math.cast(usize, plane.stride) orelse return error.ImageTooLarge;
        if (stride < @as(usize, width)) return error.InvalidStride;
        const rows = std.math.mul(usize, @as(usize, height) - 1, stride) catch return error.ImageTooLarge;
        const span = std.math.add(usize, plane.offset, rows) catch return error.ImageTooLarge;
        const end = std.math.add(usize, span, @as(usize, width)) catch return error.ImageTooLarge;
        if (end > source_buffer.len) return error.BufferUnderflow;
    }
};

/// A decoded frame sequence uploaded from a `FrameSource` into a texture
/// registry and published to an element as an `ImageSequence`.
///
/// Ownership: `TextureRegistry.insert` pins each slot once and the registry
/// owns the uploaded copy of the pixels. This type keeps that pin for as long
/// as it lives, so the raw slot index cannot be retired and handed to another
/// image while a live frame of this sequence still names it. `deinit` evicts
/// and unpins every slot; the registry then keeps the pixels for two
/// presented frames and bumps the generation before the index comes back, so
/// a timeline that outlives this call fails the element's generation check
/// instead of sampling a stranger's pixels.
///
/// The producer's own buffer is not retained: the upload copies it, so the
/// descriptor goes back through `FrameSource.releaseFrame` on every path.
/// That is the only call that settles the source's accounting, which is why
/// the return is a `defer` on the local copy and not a stored field.
pub const AnimatedSequence = struct {
    /// Frames one sequence may carry. Fixed, so appending a frame allocates
    /// nothing: a sequence is assembled before the window starts drawing.
    pub const max_frames: usize = 8;

    /// Resolves a registry handle to the bindless heap index an element may
    /// sample. The registry owns decoded CPU images and has no GPU texture
    /// behind it, so only the owner can know where those pixels were
    /// uploaded. A mapper that refuses leaves the frame uninstalled rather
    /// than publishing an index the shader would read as somebody else's
    /// texture.
    pub const SlotMapper = *const fn (
        context: ?*anyopaque,
        handle: TextureHandle,
    ) anyerror!image_types.TextureSlot;

    /// One installed frame: the registry handle this sequence owns, and the
    /// heap slot the element samples. They are different index spaces and are
    /// never interchangeable.
    pub const Installed = struct {
        handle: TextureHandle,
        slot: image_types.TextureSlot,
        duration_ns: ?u64,
    };

    pub const Options = struct {
        loop: bool = true,
        /// Required. Without it a sequence cannot publish a timeline.
        slot_mapper: SlotMapper,
        mapper_context: ?*anyopaque = null,
    };

    source: *FrameSource,
    textures: *TextureRegistry,
    /// Append-only, so the borrowed timeline `timeline` hands out stays valid
    /// for the rest of the run.
    // SAFETY: only `installed[0..count]` is read, and `count` counts up only
    // as `submitNext` writes each entry.
    installed: [max_frames]Installed = undefined,
    count: usize = 0,
    loop: bool,
    mapper: SlotMapper,
    /// Scratch for the published view. Fixed, so `timeline` allocates
    /// nothing and the caller can hold the borrowed slice for the run.
    // SAFETY: `frames` rewrites the prefix it returns before handing it out.
    frame_scratch: [max_frames]ImageFrame = undefined,
    mapper_context: ?*anyopaque,

    pub fn init(
        source: *FrameSource,
        textures: *TextureRegistry,
        options: Options,
    ) AnimatedSequence {
        return .{
            .source = source,
            .textures = textures,
            .loop = options.loop,
            .mapper = options.slot_mapper,
            .mapper_context = options.mapper_context,
        };
    }

    /// Installs the next frame the producer has queued, in push order. False
    /// means the source has nothing left to give. The acquired descriptor is
    /// returned on every path, so a refused upload still settles the
    /// producer's accounting. A refused slot mapper retires the registry slot
    /// and leaves its pixels to the registry's own retirement rule: the
    /// registry owned them from `insert` onwards, and freeing them here as
    /// well would hand it a buffer it frees again two frames later.
    pub fn submitNext(self: *AnimatedSequence) !bool {
        if (self.count == max_frames) return error.SequenceFull;
        var frame = self.source.acquireOldest() orelse return false;
        defer self.source.releaseFrame(&frame);

        const base = frame.pixels orelse return error.MissingPixels;
        var decoded = try CpuUploadAdapter.uploadToRgba(
            self.textures.allocator,
            frame,
            base[0..frame.totalBytes()],
            .{},
        );
        // The pixels keep their color. A view that wants a grayscale
        // rendering sets `ImageView.grayscale`; the renderer applies that
        // amount in Oklab on the sample, so there is deliberately no CPU
        // conversion on this path.
        // The registry takes the image when `insert` returns, pins the slot
        // once for the caller, and keeps the pixels until it retires that
        // slot. The errdefer is therefore armed only while they are still
        // this frame's to release, and disarmed the moment they are not.
        var registry_owns = false;
        errdefer if (!registry_owns) decoded.deinit();

        const handle = try self.textures.insert(decoded);
        registry_owns = true;

        // The owner uploads the decoded image and says where it landed. A
        // refusal here retires the registry slot again, so a frame that was
        // never publishable does not stay pinned forever.
        const slot = self.mapper(self.mapper_context, handle) catch |err| {
            self.textures.evict(handle);
            self.textures.unpin(handle);
            return err;
        };

        self.installed[self.count] = .{
            .handle = handle,
            .slot = slot,
            .duration_ns = frame.duration_ns,
        };
        self.count += 1;
        return true;
    }

    /// The borrowed timeline an element samples through `ImageView.source`.
    pub fn timeline(self: *AnimatedSequence) ImageSequence {
        return ImageSequence.init(self.frames(), self.loop);
    }

    /// The published heap slots, in install order. Rebuilt per call from the
    /// append-only install log, which is what keeps a borrowed timeline free
    /// of a second cache that could disagree with it.
    fn frames(self: *AnimatedSequence) []const ImageFrame {
        // Only the prefix this call fills is read back, so wiping the whole
        // scratch is not required; the assignment below covers what is used.
        // SAFETY: the prefix this call writes is the only prefix read back.
        self.frame_scratch = undefined;
        for (self.installed[0..self.count], 0..) |entry, position| {
            self.frame_scratch[position] = .{
                .slot = entry.slot,
                .duration_ns = entry.duration_ns,
            };
        }
        return self.frame_scratch[0..self.count];
    }

    /// The registry handle for an installed frame, which is what the
    /// registry's own pin, eviction and generation rules speak in.
    pub fn registryHandle(self: *const AnimatedSequence, position: usize) TextureHandle {
        if (position >= self.count) return .invalid;
        return self.installed[position].handle;
    }

    /// Retires every registry slot this sequence installed, then poisons the
    /// sequence itself. The install log stays readable through the retirement:
    /// a timeline an element already holds borrows the published slots, and
    /// that element's generation check is what refuses a retired one. Past
    /// this call the sequence is gone, so that check is the only thing between
    /// a stale sample and undefined memory.
    pub fn deinit(self: *AnimatedSequence) void {
        for (self.installed[0..self.count]) |entry| {
            self.textures.evict(entry.handle);
            self.textures.unpin(entry.handle);
        }
        self.count = 0;
        self.* = undefined;
    }
};
