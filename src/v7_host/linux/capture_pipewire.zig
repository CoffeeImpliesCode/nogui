//! PipeWire video stream client for a portal ScreenCast session.
//!
//! PipeWire is resolved at runtime through `std.DynLib`, like the SVG backend,
//! so a build without the library still compiles and reports the capability as
//! unavailable. Nothing here talks to a display server on its own: the socket
//! comes from the portal.
//!
//! Frames are published as `image.FrameDescriptor` values. A descriptor points
//! at mapped memory that stays valid until the frame is released; releasing a
//! frame returns the `pw_buffer` to the stream, which is the only way the
//! allocator reclaims it.
const std = @import("std");
const linux = std.os.linux;
const capture = @import("../capture.zig");

pub const FrameDescriptor = capture.FrameDescriptor;
pub const PixelFormat = capture.PixelFormat;
pub const StreamInfo = capture.StreamInfo;
pub const ColorRange = capture.ColorRange;

pub const Error = error{
    PipeWireMissing,
    PipeWireIncomplete,
    StreamConnectFailed,
    /// The portal answered with a session but named no node inside it, so there
    /// is nothing to bind to and no surface the operator chose to report.
    TargetNodeNotNamed,
    /// The negotiated layout cannot be described as a frame descriptor.
    FormatUnsupported,
} || std.mem.Allocator.Error;

// -- Simple Plugin API wire constants ----------------------------------------
// Only the identifiers this client actually reads or writes are named. The
// numeric values come from spa/utils/type.h, spa/param/format.h,
// spa/param/video/raw.h and spa/param/video/color.h.

pub const spa_type_none: u32 = 0x00000;
pub const spa_type_id: u32 = 0x00003;
pub const spa_type_rectangle: u32 = 0x0000a;
pub const spa_type_fraction: u32 = 0x0000b;
pub const spa_type_object: u32 = 0x00010;
pub const spa_type_choice: u32 = 0x00012;
pub const spa_type_object_format: u32 = 0x40003;

pub const spa_param_enum_format: u32 = 0x00001;

pub const spa_format_media_type: u32 = 0x10001;
pub const spa_format_media_subtype: u32 = 0x10002;
pub const spa_format_start_video: u32 = 0x20000;
pub const spa_format_video_format: u32 = spa_format_start_video + 1;
pub const spa_format_video_size: u32 = spa_format_start_video + 3;
pub const spa_format_video_framerate: u32 = spa_format_start_video + 4;
pub const spa_format_video_color_range: u32 = spa_format_start_video + 11;
pub const spa_format_video_color_matrix: u32 = spa_format_start_video + 12;
pub const spa_format_video_transfer_function: u32 = spa_format_start_video + 13;
pub const spa_format_video_color_primaries: u32 = spa_format_start_video + 14;

pub const spa_media_type_video: u32 = 2;
pub const spa_media_subtype_raw: u32 = 1;

pub const spa_video_format_unknown: u32 = 0;
pub const spa_video_format_bgra: u32 = 12;
pub const spa_video_format_rgbx: u32 = 7;
pub const spa_video_format_xrgb: u32 = 8;
pub const spa_video_format_bgrx: u32 = 6;
pub const spa_video_format_xbgr: u32 = 9;
pub const spa_video_format_rgba: u32 = 11;
pub const spa_video_format_argb: u32 = 13;
pub const spa_video_format_abgr: u32 = 14;
pub const spa_video_format_rgb: u32 = 15;
pub const spa_video_format_bgr: u32 = 16;
pub const spa_video_format_i420: u32 = 3;
pub const spa_video_format_nv12: u32 = 32;

pub const spa_video_color_range_unknown: u32 = 0;
pub const spa_video_color_range_0_255: u32 = 1;
pub const spa_video_color_range_16_235: u32 = 2;

pub const spa_video_transfer_srgb: u32 = 7;
pub const spa_video_color_primaries_srgb: u32 = 3;

pub const spa_choice_enum: u32 = 3;
pub const spa_pod_prop_flag_dont_fixate: u32 = 1 << 4;

pub const pw_id_any: u32 = 0xffffffff;
pub const pw_direction_input: u32 = 0;
pub const pw_stream_flag_map_buffers: u32 = 1 << 2;
pub const pw_stream_flag_autoconnect: u32 = 1 << 0;
pub const pw_stream_flag_dont_reconnect: u32 = 1 << 7;
pub const pw_version_stream_events: u32 = 2;

pub const pw_stream_state_error: c_int = -1;
pub const pw_stream_state_unconnected: c_int = 0;
pub const pw_stream_state_connecting: c_int = 1;
pub const pw_stream_state_paused: c_int = 2;
pub const pw_stream_state_streaming: c_int = 3;

// -- Simple Plugin API structures --------------------------------------------

/// C layout of `struct spa_pod`: the size of the body, then the type.
pub const Pod = extern struct {
    size: u32,
    type: u32,
};

/// C layout of `struct spa_pod_prop`: a key, flags, and a nested pod whose
/// body is the value.
pub const PodProp = extern struct {
    key: u32,
    flags: u32,
    value: Pod,
};

pub const pod_header_bytes = @sizeOf(Pod);
pub const object_header_bytes = @sizeOf(Pod) + 2 * @sizeOf(u32);
pub const prop_header_bytes = @sizeOf(PodProp);
pub const pod_align = 8;
/// `SPA_POD_MAX_SIZE`; a body larger than this is corruption, not a format.
pub const max_pod_body_bytes = 1 << 20;

/// C layout of `struct spa_chunk`.
pub const Chunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

/// C layout of `struct spa_data`. Only the fields needed to read a mapped
/// buffer are named; the rest of the struct is never touched.
pub const Data = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?[*]u8,
    chunk: ?*Chunk,
};

/// C layout of `struct spa_buffer`. C declares `metas` as
/// `struct spa_meta **`, and a many pointer is not a storable type in Zig, so
/// the single pointer spelling is used instead. The field is never read and
/// both spellings have the same size and alignment.
pub const Buffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?*anyopaque,
    datas: ?[*]Data,
};

/// The prefix of `struct pw_buffer` that this client reads. The structure is
/// documented to grow, and the fields after `time` are not needed.
pub const PwBuffer = extern struct {
    buffer: ?*Buffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
    time: u64,
};

/// C layout of `struct spa_hook`, needed to attach the event listener.
pub const Hook = extern struct {
    link_next: ?*anyopaque,
    link_prev: ?*anyopaque,
    funcs: ?*const anyopaque,
    data: ?*anyopaque,
    removed: ?*const fn (?*anyopaque) callconv(.c) void,
    priv: ?*anyopaque,
};

pub const StreamEvents = extern struct {
    version: u32,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
    state_changed: ?*const fn (?*anyopaque, c_int, c_int, ?[*:0]const u8) callconv(.c) void,
    control_info: ?*const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    io_changed: ?*const fn (?*anyopaque, u32, ?*anyopaque, u32) callconv(.c) void,
    param_changed: ?*const fn (?*anyopaque, u32, ?*const Pod) callconv(.c) void,
    add_buffer: ?*const fn (?*anyopaque, ?*PwBuffer) callconv(.c) void,
    remove_buffer: ?*const fn (?*anyopaque, ?*PwBuffer) callconv(.c) void,
    process: ?*const fn (?*anyopaque) callconv(.c) void,
    drained: ?*const fn (?*anyopaque) callconv(.c) void,
    command: ?*const fn (?*anyopaque, ?*const anyopaque) callconv(.c) void,
    trigger_done: ?*const fn (?*anyopaque) callconv(.c) void,
};

// -- Format metadata ----------------------------------------------------------

/// What a negotiated `Format` pod said about the stream.
pub const NegotiatedFormat = struct {
    format: u32 = spa_video_format_unknown,
    width: u32 = 0,
    height: u32 = 0,
    framerate_num: u32 = 0,
    framerate_denom: u32 = 0,
    color_range: u32 = spa_video_color_range_unknown,
    color_matrix: u32 = 0,
    transfer_function: u32 = 0,
    color_primaries: u32 = 0,

    /// Nanoseconds between frames, or zero when the rate is unknown.
    pub fn frameIntervalNs(self: NegotiatedFormat) u64 {
        if (self.framerate_num == 0 or self.framerate_denom == 0) return 0;
        return @as(u64, self.framerate_denom) * std.time.ns_per_s / self.framerate_num;
    }
};

/// The source the portal chose, as its `Start` reply named it.
///
/// PipeWire negotiates the pixel layout and nothing else: the source class and
/// the position on the desktop come from the portal and never appear in a
/// format pod. The stream therefore keeps the selection, so every report it
/// makes describes the whole stream instead of the half PipeWire can see.
pub const SourceSelection = struct {
    /// Chosen source classes, as the portal's `SourceType` bit mask.
    sources: capture.SourceType = .none,
    /// False when the portal named no class, which is not a source of no
    /// class.
    known: bool = false,
    position_x: i32 = 0,
    position_y: i32 = 0,
};

/// One property of a POD object.
pub const Prop = struct {
    type: u32,
    data: []const u8,

    pub fn asId(self: Prop) ?u32 {
        if (self.type != spa_type_id or self.data.len < 4) return null;
        return std.mem.readInt(u32, self.data[0..4], .little);
    }

    pub fn width(self: Prop) ?u32 {
        if (self.type != spa_type_rectangle or self.data.len < 8) return null;
        return std.mem.readInt(u32, self.data[0..4], .little);
    }

    pub fn height(self: Prop) ?u32 {
        if (self.type != spa_type_rectangle or self.data.len < 8) return null;
        return std.mem.readInt(u32, self.data[4..8], .little);
    }

    pub fn fractionNum(self: Prop) ?u32 {
        if (self.type != spa_type_fraction or self.data.len < 8) return null;
        return std.mem.readInt(u32, self.data[0..4], .little);
    }

    pub fn fractionDenom(self: Prop) ?u32 {
        if (self.type != spa_type_fraction or self.data.len < 8) return null;
        return std.mem.readInt(u32, self.data[4..8], .little);
    }
};

/// Walks the properties of a POD object, mirroring `spa_pod_object_find_prop`.
///
/// The bytes come from a peer, so nothing about them is trusted: they are read
/// field by field instead of through a pointer into the range, because a
/// caller handing over a `[]const u8` has promised nothing about how that
/// range is aligned.
pub const ObjectProperties = struct {
    bytes: []const u8,

    pub fn find(self: ObjectProperties, key: u32) ?Prop {
        if (self.bytes.len <= object_header_bytes) return null;
        const body = self.bytes[object_header_bytes..];
        var offset: usize = 0;
        while (offset + prop_header_bytes <= body.len) {
            const header = body[offset..][0..prop_header_bytes];
            // `PodProp` is key, flags, then a `Pod`, and a `Pod` declares its
            // body size before its type, so the size sits two words in and the
            // type in the last word of the header. Read the other way round,
            // the size is taken for the type, every property misses the type
            // its value claims, and the walk steps over what is behind it.
            const value_size = std.mem.readInt(u32, header[@sizeOf(u32) * 2 ..][0..4], .little);
            const total = prop_header_bytes + @as(usize, value_size);
            if (offset + total > body.len) return null;
            if (std.mem.readInt(u32, header[0..4], .little) == key) {
                return .{
                    .type = std.mem.readInt(u32, header[prop_header_bytes - @sizeOf(u32) ..][0..4], .little),
                    .data = body[offset + prop_header_bytes ..][0..value_size],
                };
            }
            offset = std.mem.alignForward(usize, offset + total, pod_align);
        }
        return null;
    }
};

/// True when the bytes hold a `Format` object of the given object id.
pub fn isFormatObject(bytes: []const u8, id: u32) bool {
    if (bytes.len < object_header_bytes) return false;
    if (std.mem.readInt(u32, bytes[@sizeOf(u32)..][0..4], .little) != spa_type_object) return false;
    const object_type = std.mem.readInt(u32, bytes[@sizeOf(Pod)..][0..4], .little);
    const object_id = std.mem.readInt(u32, bytes[@sizeOf(Pod) + 4 ..][0..4], .little);
    return object_type == spa_type_object_format and object_id == id;
}

/// Reads the format, size, rate and colour metadata out of `Format` object
/// bytes. A pod that does not describe raw video is rejected outright rather
/// than read field by field, and so is one whose properties are present but
/// malformed or absent where a frame descriptor needs them: a size pod that
/// is not a rectangle reads as no size at all, and a stream that accepted that
/// would go on describing frames in a layout the peer never agreed to.
pub fn parseFormatBytes(bytes: []const u8) ?NegotiatedFormat {
    if (bytes.len < object_header_bytes) return null;
    if (!isFormatObject(bytes, spa_param_enum_format)) return null;

    const properties: ObjectProperties = .{ .bytes = bytes };
    const media_type = (properties.find(spa_format_media_type) orelse return null).asId() orelse
        return null;
    if (media_type != spa_media_type_video) return null;
    const media_subtype = (properties.find(spa_format_media_subtype) orelse return null).asId() orelse
        return null;
    if (media_subtype != spa_media_subtype_raw) return null;

    // A property that is present is read as what it claims to be or refused
    // whole. Coercing a malformed one to its zero value is what turns corrupt
    // bytes into a plausible looking negotiation.
    var out: NegotiatedFormat = .{};
    if (properties.find(spa_format_video_format)) |p| out.format = p.asId() orelse return null;
    // The size is what every frame is measured against, so a negotiation that
    // does not name one is refused rather than reported with nothing in it.
    const size = properties.find(spa_format_video_size) orelse return null;
    out.width = size.width() orelse return null;
    out.height = size.height() orelse return null;
    // Zero is not a picture, and a descriptor built from it would name a
    // stride and a size no frame can satisfy.
    if (out.width == 0 or out.height == 0) return null;
    if (properties.find(spa_format_video_framerate)) |p| {
        out.framerate_num = p.fractionNum() orelse return null;
        out.framerate_denom = p.fractionDenom() orelse return null;
    }
    if (properties.find(spa_format_video_color_range)) |p| out.color_range = p.asId() orelse return null;
    if (properties.find(spa_format_video_color_matrix)) |p| out.color_matrix = p.asId() orelse return null;
    if (properties.find(spa_format_video_transfer_function)) |p| out.transfer_function = p.asId() orelse return null;
    if (properties.find(spa_format_video_color_primaries)) |p| out.color_primaries = p.asId() orelse return null;
    return out;
}

/// The live entry point. PipeWire hands over a pod with no length, so the body
/// size in the header is the only bound available; a size past the protocol
/// limit is treated as corruption rather than trusted.
pub fn parseFormat(pod: *const Pod) ?NegotiatedFormat {
    if (pod.size >= max_pod_body_bytes) return null;
    const raw: [*]const u8 = @ptrCast(pod);
    return parseFormatBytes(raw[0 .. pod_header_bytes + @as(usize, pod.size)]);
}

/// The frame format this build can describe, or null when the negotiated layout
/// would need a conversion this client does not claim to do.
pub fn pixelFormatOf(spa_format: u32) ?PixelFormat {
    return switch (spa_format) {
        spa_video_format_bgra => .bgra8,
        spa_video_format_rgba, spa_video_format_rgbx => .rgba8,
        spa_video_format_bgrx, spa_video_format_argb => .bgra8,
        spa_video_format_xrgb, spa_video_format_xbgr => .bgra8,
        spa_video_format_abgr => .rgba8,
        spa_video_format_rgb, spa_video_format_bgr => .rgb8,
        else => null,
    };
}

pub fn colorRangeOf(spa_range: u32) ColorRange {
    return switch (spa_range) {
        spa_video_color_range_0_255 => .full,
        spa_video_color_range_16_235 => .limited,
        else => .unknown,
    };
}

pub fn colorSpaceOf(negotiated: NegotiatedFormat) capture.ColorSpace {
    // Every raw video format this client accepts is defined in terms of
    // non-linear values. A stream tagged with a linear transfer function is
    // the only case that differs, and the renderer converts to sRGB itself.
    return switch (negotiated.transfer_function) {
        spa_video_transfer_srgb, 0 => .srgb,
        else => .linear,
    };
}

/// The packed formats requested from the session, best first. Planar formats
/// are left out on purpose: a single mapped buffer does not carry the plane
/// offsets, so accepting one would mean inventing a layout.
pub const requested_formats = [_]u32{
    spa_video_format_bgra,
    spa_video_format_rgbx,
    spa_video_format_bgrx,
    spa_video_format_xrgb,
    spa_video_format_rgba,
    spa_video_format_argb,
    spa_video_format_abgr,
};

/// The `Format` pod handed to `pw_stream_connect`. It is built into a fixed
/// buffer because its size is known at comptime, so no allocation is needed on
/// the path that opens a stream.
pub const FormatParam = struct {
    // `put` writes every byte that `len` covers before `slice` hands them to
    // the wire, so the zeroed tail beyond `len` is never sent.
    bytes: [format_param_bytes]u8 align(pod_align) = @splat(0),
    len: usize = 0,

    fn align8(n: usize) usize {
        return std.mem.alignForward(usize, n, pod_align);
    }

    const choice_body_bytes = 16 + 4 * requested_formats.len;
    const id_prop_bytes = align8(prop_header_bytes + 4);
    const choice_prop_bytes = align8(prop_header_bytes + choice_body_bytes);
    // The object body is the object header plus every padded property. That
    // padding is part of the body, so the declared size must include it or the
    // peer reads past the end of the pod.
    const body_bytes = 2 * @sizeOf(u32) + 2 * id_prop_bytes + choice_prop_bytes;
    const format_param_bytes = pod_header_bytes + body_bytes;

    pub fn slice(self: *const FormatParam) []const u8 {
        return self.bytes[0..self.len];
    }

    /// The pod itself. PipeWire reads the declared body length from this
    /// address, so the pointer has to name this buffer and not a copy of only
    /// its eight-byte header.
    pub fn pod(self: *const FormatParam) *const Pod {
        return @ptrCast(@alignCast(self.bytes[0..pod_header_bytes].ptr));
    }

    fn put(self: *FormatParam, value: u32) void {
        std.mem.writeInt(u32, self.bytes[self.len..][0..4], value, .little);
        self.len += 4;
    }

    fn pad(self: *FormatParam) void {
        const remainder = self.len % pod_align;
        if (remainder != 0) self.len += pod_align - remainder;
    }

    fn putIdProp(self: *FormatParam, key: u32, value: u32) void {
        self.put(key);
        self.put(0); // property flags
        self.put(4); // value body size
        self.put(spa_type_id);
        self.put(value);
        self.pad();
    }

    fn putFormatChoiceProp(self: *FormatParam, key: u32) void {
        self.put(key);
        self.put(spa_pod_prop_flag_dont_fixate);
        self.put(@intCast(choice_body_bytes));
        self.put(spa_type_choice);
        self.put(spa_choice_enum);
        self.put(0); // choice flags
        self.put(4); // child pod body size
        self.put(spa_type_id);
        for (requested_formats) |format| self.put(format);
        self.pad();
    }
};

/// Builds the format offered to the session. The alternative list is left
/// unfixated so the session may pick any format this client can describe, and
/// the size and rate are omitted so the source decides both.
pub fn buildFormatParam() FormatParam {
    var param: FormatParam = .{};

    param.put(@intCast(FormatParam.body_bytes));
    param.put(spa_type_object);
    param.put(spa_type_object_format);
    param.put(spa_param_enum_format);

    param.putIdProp(spa_format_media_type, spa_media_type_video);
    param.putIdProp(spa_format_media_subtype, spa_media_subtype_raw);
    param.putFormatChoiceProp(spa_format_video_format);

    return param;
}

// -- Runtime library binding --------------------------------------------------

pub const PwProperties = opaque {};
pub const PwContext = opaque {};
pub const PwCore = opaque {};
pub const PwStream = opaque {};
pub const PwThreadLoop = opaque {};

/// `pw_context_new` takes the event loop that a thread loop runs. It is a
/// different object from the thread loop that wraps it. `struct pw_thread_loop`
/// is a concrete structure whose first member is the loop pointer and whose
/// second is the listener list, and `struct pw_loop` expects its `utils` method
/// table exactly where that listener list sits, so the two pointers are read
/// as each other and the library calls through a method table made of a hook
/// list.
pub const PwLoop = opaque {};

/// Resolved libpipewire-0.3 entry points. Every field is set only after
/// `Api.load` succeeded, so a partial table can never be used.
pub const Api = struct {
    pw_init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    pw_deinit: *const fn () callconv(.c) void,
    pw_properties_new: *const fn (?[*:0]const u8, ...) callconv(.c) ?*PwProperties,
    pw_properties_set: *const fn (*PwProperties, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    pw_properties_free: *const fn (*PwProperties) callconv(.c) void,
    pw_thread_loop_new: *const fn (?[*:0]const u8, ?*const anyopaque) callconv(.c) ?*PwThreadLoop,
    pw_thread_loop_get_loop: *const fn (*PwThreadLoop) callconv(.c) ?*PwLoop,
    pw_thread_loop_start: *const fn (*PwThreadLoop) callconv(.c) c_int,
    pw_thread_loop_stop: *const fn (*PwThreadLoop) callconv(.c) void,
    pw_thread_loop_lock: *const fn (*PwThreadLoop) callconv(.c) void,
    pw_thread_loop_unlock: *const fn (*PwThreadLoop) callconv(.c) void,
    pw_thread_loop_destroy: *const fn (*PwThreadLoop) callconv(.c) void,
    pw_context_new: *const fn (
        ?*PwLoop,
        ?*PwProperties,
        usize,
    ) callconv(.c) ?*PwContext,
    pw_context_destroy: *const fn (*PwContext) callconv(.c) void,
    pw_context_connect_fd: *const fn (
        *PwContext,
        c_int,
        ?*PwProperties,
        usize,
    ) callconv(.c) ?*PwCore,
    pw_core_disconnect: *const fn (*PwCore) callconv(.c) c_int,
    pw_stream_new: *const fn (*PwCore, [*:0]const u8, ?*PwProperties) callconv(.c) ?*PwStream,
    pw_stream_add_listener: *const fn (
        *PwStream,
        *Hook,
        *const StreamEvents,
        ?*anyopaque,
    ) callconv(.c) void,
    pw_stream_connect: *const fn (
        *PwStream,
        u32,
        u32,
        u32,
        ?[*]const ?*const Pod,
        u32,
    ) callconv(.c) c_int,
    pw_stream_disconnect: *const fn (*PwStream) callconv(.c) c_int,
    pw_stream_destroy: *const fn (*PwStream) callconv(.c) void,
    pw_stream_dequeue_buffer: *const fn (*PwStream) callconv(.c) ?*PwBuffer,
    pw_stream_queue_buffer: *const fn (*PwStream, *PwBuffer) callconv(.c) c_int,

    pub const candidate_sonames = [_][]const u8{
        "libpipewire-0.3.so.0",
        "libpipewire-0.3.so",
    };

    /// The symbol every declared field resolves from, in field order.
    ///
    /// `load` walks this list together with the field list, so a field added
    /// without a symbol is a compile error rather than a null function pointer
    /// in a table that otherwise looks whole. A list that drifts out of field
    /// order is the same kind of error.
    pub const symbols = [_][:0]const u8{
        "pw_init",
        "pw_deinit",
        "pw_properties_new",
        "pw_properties_set",
        "pw_properties_free",
        "pw_thread_loop_new",
        "pw_thread_loop_get_loop",
        "pw_thread_loop_start",
        "pw_thread_loop_stop",
        "pw_thread_loop_lock",
        "pw_thread_loop_unlock",
        "pw_thread_loop_destroy",
        "pw_context_new",
        "pw_context_destroy",
        "pw_context_connect_fd",
        "pw_core_disconnect",
        "pw_stream_new",
        "pw_stream_add_listener",
        "pw_stream_connect",
        "pw_stream_disconnect",
        "pw_stream_destroy",
        "pw_stream_dequeue_buffer",
        "pw_stream_queue_buffer",
    };

    fn symbol(comptime T: type, object: std.DynLib, name: [:0]const u8) !T {
        var lib = object;
        return lib.lookup(T, name) orelse Error.PipeWireIncomplete;
    }

    /// Opens the library and resolves every entry point. The library stays
    /// open for the lifetime of the process once loaded.
    pub fn load() !Api {
        var object: ?std.DynLib = null;
        for (candidate_sonames) |soname| {
            if (std.DynLib.open(soname)) |loaded| {
                object = loaded;
                break;
            } else |_| {}
        }
        const lib = object orelse return Error.PipeWireMissing;

        // Filled field by field and handed back only once every field holds a
        // resolved entry point. A symbol that is missing aborts the load, so
        // there is no point at which a half filled table exists to be used,
        // and the field's own type is the one the lookup is asked for, so the
        // table and its declaration cannot drift apart.
        // SAFETY: every field of `Api` is written by the inline loop below, and
        // a symbol that cannot be resolved returns before the loop starts, so
        // no field is ever read while it still holds `undefined`.
        var api: Api = undefined;
        const api_info = @typeInfo(Api).@"struct";
        inline for (api_info.field_names, api_info.field_types, 0..) |field_name, field_type, index| {
            @field(api, field_name) = try symbol(field_type, lib, symbols[index]);
        }

        api.pw_init(null, null);
        return api;
    }
};

// The table is only ever as whole as its declaration says it is. A field with
// no symbol beside it, or a symbol list that no longer follows the fields, is
// a build error here rather than a null entry point in a table that still
// looks complete to every caller.
comptime {
    const api_info = @typeInfo(Api).@"struct";
    if (Api.symbols.len != api_info.field_names.len)
        @compileError("every Api entry point resolves from its own symbol");
    for (api_info.field_names, api_info.field_attrs, Api.symbols) |field_name, field_attrs, name| {
        if (!std.mem.eql(u8, field_name, name))
            @compileError("Api symbols must name the fields in field order");
        if (field_attrs.default_value_ptr != null)
            @compileError("an Api field with a default would let a partial table be built by omission");
    }
}

/// Shared lifetime for a producer and the frames it handed out.
///
/// A stream cannot be destroyed while a consumer still holds one of its
/// frames, because releasing that frame returns a buffer into the producer.
/// `drop` keeps the last reference alive until the last outstanding frame is
/// back, then runs `destroy` exactly once.
pub const SharedLifetime = struct {
    /// Frames a consumer still holds. The producer's own request to stop is
    /// separate, in `teardown`, so this count is purely outstanding work.
    remaining: usize = 0,
    /// Set once the producer asked to go away. The destroy hook still waits
    /// for every outstanding frame.
    teardown: bool = false,
    /// Set once `destroy` ran.
    destroyed: bool = false,
    destroy_hook: ?*const fn (?*anyopaque) void = null,
    hook_ctx: ?*anyopaque = null,

    pub const init: SharedLifetime = .{};

    /// Called when the producer starts handing frames out.
    pub fn begin(self: *SharedLifetime) void {
        self.remaining = 0;
        self.teardown = false;
        self.destroyed = false;
    }

    /// Called for every frame handed to a consumer.
    pub fn hold(self: *SharedLifetime) void {
        self.remaining += 1;
    }

    /// The producer lets go. Returns true when nothing is outstanding and the
    /// destroy hook is free to run now.
    pub fn requestTeardown(self: *SharedLifetime) bool {
        self.teardown = true;
        return self.remaining == 0;
    }

    /// Called when a frame comes back. Returns true when this was the last
    /// thing the lifetime was waiting for and the destroy hook is free to run.
    ///
    /// False when this producer is not holding the frame, and the count is
    /// left alone. That is a refused release rather than a fault to assert on:
    /// an assert is compiled out of a ReleaseFast build, and there a count
    /// taken below zero wraps to the largest `usize` there is. The transport
    /// would then never be destroyed, and every later count taken against that
    /// number is wrong. A caller that gets false has nothing of this producer's
    /// to give back.
    pub fn drop(self: *SharedLifetime) bool {
        if (self.remaining == 0) return false;
        self.remaining -= 1;
        return self.teardown and self.remaining == 0;
    }

    /// How many frames a consumer is still holding.
    pub fn outstanding(self: *SharedLifetime) usize {
        return self.remaining;
    }

    /// True when every frame is back and the producer asked to go away.
    pub fn mayDestroy(self: *SharedLifetime) bool {
        return self.teardown and self.remaining == 0 and !self.destroyed;
    }

    /// Takes the teardown. True for the one caller that won it, which then
    /// owes the destroy hook; every later caller gets false. Separate from the
    /// hook because the winner tears its transport down under a lock and the
    /// hook may call back into what is being torn down.
    pub fn claimDestroy(self: *SharedLifetime) bool {
        if (!self.mayDestroy()) return false;
        self.destroyed = true;
        return true;
    }

    /// Runs the destroy hook the winning `claimDestroy` caller owes.
    pub fn runDestroyHook(self: *SharedLifetime) void {
        if (self.destroy_hook) |hook| hook(self.hook_ctx);
    }

    /// Claims the teardown and runs the hook, at most once even if called again
    /// by accident.
    pub fn destroyOnce(self: *SharedLifetime) void {
        if (!self.claimDestroy()) return;
        self.runDestroyHook();
    }
};

/// The producer state behind one frame. One of these lives exactly as long as
/// the frame does, and handing the buffer back to the stream together with the
/// frame is the release callback's whole job. The pixel memory itself is named
/// by the descriptor's `pixels` field, so it is not duplicated here.
const BufferRef = struct {
    stream: *Stream,
    buffer: *PwBuffer,

    fn release(ctx: ?*anyopaque) void {
        const self: *BufferRef = @ptrCast(@alignCast(ctx.?));
        const stream = self.stream;
        stream.returnFrame(self.buffer);
        stream.gpa.destroy(self);
    }
};

/// A live PipeWire capture stream publishing into a `capture.Sink`.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    api: *const Api,
    sink: capture.Sink,
    node_id: u32 = 0,
    negotiated: NegotiatedFormat = .{},
    /// What the portal named about the source. Reported with every negotiated
    /// format, because a format report is the whole stream description.
    source: SourceSelection = .{},
    format_epoch: u32 = 0,
    /// Whether the consumer has already been told this stream is streaming. A
    /// pause clears it, because a resume nobody hears about is a stream that
    /// stays silent for the rest of its life.
    published_streaming: bool = false,
    thread_loop: ?*PwThreadLoop = null,
    context: ?*PwContext = null,
    core: ?*PwCore = null,
    stream: ?*PwStream = null,
    hook: Hook = std.mem.zeroes(Hook),
    events: StreamEvents = std.mem.zeroes(StreamEvents),
    /// Guards the fields a PipeWire thread and the app thread both touch.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Keeps the producer alive until every frame it handed out is back.
    lifetime: SharedLifetime = .init,
    stopped: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, api: *const Api, sink: capture.Sink) Stream {
        return .{ .gpa = gpa, .io = io, .api = api, .sink = sink };
    }

    /// True while the transport may still talk to the consumer. Once the owner
    /// asked to stop, a PipeWire callback that arrives late stays silent
    /// instead of reporting into a session that is already gone.
    fn delivering(self: *Stream) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.stopped;
    }

    /// A frame the producer handed out came back. This runs on whichever
    /// thread released the frame, which may be a PipeWire callback thread, so
    /// it only accounts. Destroying the transport belongs to the owner
    /// thread, which calls `stop` or `destroyIfReady`.
    ///
    /// True is what tells the caller the frame was this producer's to give
    /// back. It does not say the transport may go away: that is the lifetime's
    /// own question, asked by `stop` and `destroyIfReady` on the owner thread.
    pub fn dropFrame(self: *Stream) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.lifetime.outstanding() == 0) return false;
        _ = self.lifetime.drop();
        return true;
    }

    /// Attaches to the portal socket and starts delivering frames for
    /// `source`. Takes ownership of `fd`, which is closed on every path out.
    pub fn start(self: *Stream, fd: std.posix.fd_t, node_id: u32, source: SourceSelection) !void {
        // A portal that names no node leaves this nothing to bind to, and a
        // target of zero resolves to no node at all. A stream whose target
        // resolves to nothing is linked to the default video source the graph
        // happens to have, so every frame it delivered would come from a
        // surface nobody chose. The descriptor is closed here because nothing
        // was taken from it.
        if (node_id == 0) {
            _ = linux.close(fd);
            return error.TargetNodeNotNamed;
        }
        self.node_id = node_id;
        self.mutex.lockUncancelable(self.io);
        self.lifetime.begin();
        self.stopped = false;
        self.source = source;
        self.mutex.unlock(self.io);

        // `pw_context_connect_fd` closes the descriptor it is handed, so the
        // caller's socket is duplicated first and closed here immediately.
        // Both copies then belong to PipeWire alone.
        const duplicated = linux.dup(fd);
        if (linux.errno(duplicated) != .SUCCESS) {
            _ = linux.close(fd);
            return error.StreamConnectFailed;
        }
        const pipe_fd: std.posix.fd_t = @intCast(duplicated);
        _ = linux.close(fd);
        // Until the connect call below takes this copy it is still owned here,
        // so every step that can fail in between hands it back instead of
        // dropping it on the floor.
        var pipe_fd_owned = true;
        defer if (pipe_fd_owned) {
            _ = linux.close(pipe_fd);
        };

        self.thread_loop = self.api.pw_thread_loop_new("nogui-capture", null) orelse
            return error.StreamConnectFailed;
        if (self.api.pw_thread_loop_start(self.thread_loop.?) != 0) {
            // A loop that never ran has nothing to stop, so destroying it is
            // the whole teardown. Every path below releases the fields it
            // built, because `stop` and `destroyIfReady` are documented as
            // safe after a failed `start` and must not reach an object that
            // this failure path already destroyed.
            self.api.pw_thread_loop_destroy(self.thread_loop.?);
            self.thread_loop = null;
            return error.StreamConnectFailed;
        }
        // Registered before anything else is built, so it runs last.
        errdefer self.destroyTransport();
        self.api.pw_thread_loop_lock(self.thread_loop.?);
        defer self.api.pw_thread_loop_unlock(self.thread_loop.?);
        // Prevent callbacks between unlocking a refused connection and its
        // teardown. The cleanup must join the loop without its lock held.
        errdefer {
            self.mutex.lockUncancelable(self.io);
            self.stopped = true;
            _ = self.lifetime.requestTeardown();
            self.mutex.unlock(self.io);
        }

        // `pw_context_new` takes the loop the thread loop runs. The thread
        // loop only hands that object out through `pw_thread_loop_get_loop`,
        // and the two are not interchangeable.
        const main_loop = self.api.pw_thread_loop_get_loop(self.thread_loop.?) orelse
            return error.StreamConnectFailed;
        self.context = self.api.pw_context_new(main_loop, null, 0) orelse
            return error.StreamConnectFailed;

        // core.h transfers ownership on disconnect OR error. Do not close a
        // descriptor number that the library may already have released/reused.
        pipe_fd_owned = false;
        self.core = self.api.pw_context_connect_fd(self.context.?, pipe_fd, null, 0) orelse
            return error.StreamConnectFailed;

        // `pw_stream_new` takes the properties over and frees them itself when
        // it fails, so this function never releases them.
        const properties = self.api.pw_properties_new(null) orelse
            return error.StreamConnectFailed;

        // The portal hands this client a PipeWire node id in its Start reply and
        // nothing else that names the node: no object serial, no node name. A
        // node id is what `node.target` resolves, so that key carries it and is
        // the only one this reply can fill correctly.
        var node_text: [32]u8 = undefined;
        const target = std.fmt.bufPrintSentinel(&node_text, "{d}", .{node_id}, 0) catch
            return error.StreamConnectFailed;

        _ = self.api.pw_properties_set(properties, "media.type", "Video");
        _ = self.api.pw_properties_set(properties, "media.category", "Capture");
        _ = self.api.pw_properties_set(properties, "media.role", "Screen");
        _ = self.api.pw_properties_set(properties, "node.name", "Screen");
        _ = self.api.pw_properties_set(properties, "node.description", "nogui screen capture");
        // `target.object` is deliberately absent. PipeWire 1.6.8 reads it as the
        // target's object serial or its node name (stream.h: "To select a
        // specific target node, specify the PW_KEY_OBJECT_SERIAL or the
        // PW_KEY_NODE_NAME value of the target node in the PW_KEY_TARGET_OBJECT
        // property"), and targeting by id is the deprecated form it replaced. A
        // value that is neither a serial nor a name resolves to no node, and a
        // node with no resolved target is linked to the graph's default video
        // source instead of failing. Writing a JSON object under that key is
        // what put this client on a webcam: the key was present and
        // unresolvable, so the id below was never read and the stream landed on
        // an MJPEG source no raw-only consumer can use.
        //
        // The key below is deprecated and stays because it is the one spelling
        // the value the portal sends actually fits.
        _ = self.api.pw_properties_set(properties, "node.target", target);

        self.stream = self.api.pw_stream_new(self.core.?, "Screen", properties) orelse
            return error.StreamConnectFailed;

        // The listener struct is a fixed C layout that grows with every
        // release, so it starts zeroed and only the three slots this client
        // answers are filled in.
        self.events = std.mem.zeroes(StreamEvents);
        self.events.version = pw_version_stream_events;
        self.events.state_changed = onStateChanged;
        self.events.param_changed = onParamChanged;
        self.events.process = onProcess;
        self.api.pw_stream_add_listener(self.stream.?, &self.hook, &self.events, self);

        const param = buildFormatParam();
        // The wire type is a pointer to an array of pointers, not a pointer to
        // a fixed-size array, so the many pointer is what crosses over.
        const param_list = [_]?*const Pod{param.pod()};
        const params: [*]const ?*const Pod = &param_list;

        const flags = pw_stream_flag_autoconnect |
            pw_stream_flag_map_buffers |
            pw_stream_flag_dont_reconnect;
        if (self.api.pw_stream_connect(self.stream.?, pw_direction_input, pw_id_any, flags, params, 1) != 0) {
            return error.StreamConnectFailed;
        }
    }

    /// Disconnects the stream and asks for the transport to be released. Safe
    /// to call twice and safe to call when `start` never ran. The PipeWire
    /// objects are destroyed here when no frame is outstanding, otherwise the
    /// last `destroyIfReady` on the owner thread does it. Only the owner
    /// thread may run this: it disconnects and stops the thread loop.
    ///
    /// Every frame must already be released by the time the transport is
    /// destroyed, because a released frame returns a buffer into a stream
    /// that no longer exists. `outstandingFrames` reports that count.
    pub fn stop(self: *Stream) void {
        const ready = blk: {
            const loop = self.thread_loop;
            if (loop) |live| self.api.pw_thread_loop_lock(live);
            defer if (loop) |live| self.api.pw_thread_loop_unlock(live);

            self.mutex.lockUncancelable(self.io);
            const was_stopped = self.stopped;
            self.stopped = true;
            const ready = if (was_stopped)
                self.lifetime.mayDestroy()
            else
                self.lifetime.requestTeardown();
            self.mutex.unlock(self.io);

            // Disconnect can call state_changed synchronously. The loop lock
            // excludes processing, but the producer lock must be free for
            // that callback. Retained frames still pin the stream.
            if (!was_stopped) {
                if (self.stream) |stream| _ = self.api.pw_stream_disconnect(stream);
            }
            break :blk ready;
        };
        if (ready) self.finishTeardown();
    }

    /// Destroys the transport once a frame that was still out has come back.
    /// The owner thread calls this; a release thread must not, because
    /// stopping a thread loop from a callback thread deadlocks.
    pub fn destroyIfReady(self: *Stream) void {
        self.mutex.lockUncancelable(self.io);
        const ready = self.lifetime.mayDestroy();
        self.mutex.unlock(self.io);
        if (ready) self.finishTeardown();
    }

    /// Frames a consumer acquired from this producer and has not returned.
    pub fn outstandingFrames(self: *Stream) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return @intCast(self.lifetime.outstanding());
    }

    /// Destroys the PipeWire objects. Runs exactly once, when no frame is
    /// outstanding and the producer has been asked to stop. Only the owner
    /// thread reaches this: `pw_thread_loop_stop` belongs to the thread that
    /// started the loop.
    ///
    /// Claim under the producer lock, then release it before native teardown:
    /// stream destruction can call listeners synchronously. The stopped flag
    /// prevents new frames; outstanding frames prevent this claim.
    fn finishTeardown(self: *Stream) void {
        self.mutex.lockUncancelable(self.io);
        if (!self.lifetime.claimDestroy()) {
            self.mutex.unlock(self.io);
            return;
        }
        self.mutex.unlock(self.io);

        self.destroyTransport();
        self.lifetime.runDestroyHook();
    }

    /// Releases the PipeWire objects in the order they depend on each other.
    /// The stream goes first because it is the one the callbacks can still
    /// reach, then the core, then the loop thread is joined before the context
    /// that registered sources on that loop is freed, and the loop outlives all
    /// of them. A context destroys what it registered on its loop, so freeing
    /// it while that thread is still walking the loop reads freed sources.
    ///
    /// Every field it touches is optional, so a transport that failed halfway
    /// tears down the same way a complete one does. It runs with the producer
    /// lock released, which is what lets it join the loop thread without
    /// deadlocking against a thread that is parked on that lock.
    fn destroyTransport(self: *Stream) void {
        if (self.thread_loop) |live| self.api.pw_thread_loop_lock(live);
        if (self.stream) |live| {
            self.stream = null;
            self.api.pw_stream_destroy(live);
        }
        if (self.core) |live| {
            self.core = null;
            _ = self.api.pw_core_disconnect(live);
        }
        if (self.thread_loop) |live| self.api.pw_thread_loop_unlock(live);
        if (self.thread_loop) |live| self.api.pw_thread_loop_stop(live);
        if (self.context) |live| {
            self.context = null;
            self.api.pw_context_destroy(live);
        }
        if (self.thread_loop) |live| {
            self.thread_loop = null;
            self.api.pw_thread_loop_destroy(live);
        }
    }

    /// Hands a frame's buffer back and takes the frame off the books, in one
    /// critical section, so nothing can slip between the two.
    ///
    /// A frame this producer is not holding is refused whole: returning its
    /// buffer would hand the pool a `pw_buffer` the pool already owns, and
    /// taking the count down would corrupt every count after it. Both are what
    /// a second release of one descriptor does, so neither happens.
    ///
    /// Otherwise the buffer goes back before the count falls, because the pool
    /// is freed by the teardown the count gates and a buffer still outside it
    /// at that point would be freed with a consumer still reading it. Once
    /// teardown has started the pool is going away, so the buffer is dropped
    /// with it rather than queued into an object that no longer exists. The
    /// loop lock is taken before the producer lock, as everywhere else, so a
    /// teardown cannot destroy the stream between reading its pointer and
    /// using it.
    fn returnFrame(self: *Stream, buffer: *PwBuffer) void {
        const loop = self.thread_loop;
        if (loop) |live| self.api.pw_thread_loop_lock(live);
        defer if (loop) |live| self.api.pw_thread_loop_unlock(live);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.lifetime.outstanding() == 0) return;

        if (self.stream != null and !self.lifetime.teardown) {
            _ = self.api.pw_stream_queue_buffer(self.stream.?, buffer);
        }
        _ = self.lifetime.drop();
    }

    /// Turns a dequeued buffer into a descriptor. Returns null when the buffer
    /// holds nothing usable, in which case the caller must return it. The
    /// producer lock is held across this call.
    fn describeLocked(self: *Stream, buffer: *PwBuffer) ?FrameDescriptor {
        const spa = buffer.buffer orelse return null;
        if (spa.n_datas == 0) return null;
        const datas = spa.datas orelse return null;

        const format = pixelFormatOf(self.negotiated.format) orelse return null;
        if (self.negotiated.width == 0 or self.negotiated.height == 0) return null;
        if (spa.n_datas != 1) return null;

        const first = &datas[0];
        const chunk = first.chunk orelse return null;
        const pixels = first.data orelse return null;
        // FrameDescriptor exposes forward, unsigned packed rows.
        if (chunk.stride <= 0) return null;
        const stride: u32 = @intCast(chunk.stride);
        const bytes_per_pixel = format.bytesPerPixel() orelse return null;
        const row_bytes = std.math.mul(usize, self.negotiated.width, bytes_per_pixel) catch return null;
        if (stride < row_bytes) return null;
        const row_offset = std.math.mul(usize, stride, self.negotiated.height - 1) catch return null;
        const required = std.math.add(usize, row_offset, row_bytes) catch return null;
        if (chunk.offset > first.maxsize) return null;
        if (chunk.size > first.maxsize - chunk.offset or chunk.size < required) return null;

        const ref = self.gpa.create(BufferRef) catch return null;
        ref.* = .{
            .stream = self,
            .buffer = buffer,
        };
        // Refusing the frame and accounting for it are one critical section,
        // so a teardown can never be told nothing is outstanding while a frame
        // is on its way to a consumer.
        if (self.stopped) {
            self.gpa.destroy(ref);
            return null;
        }
        self.lifetime.hold();

        var frame: FrameDescriptor = .{
            .width = self.negotiated.width,
            .height = self.negotiated.height,
            .format = format,
            .color_space = colorSpaceOf(self.negotiated),
            .alpha_type = capture.AlphaType.fully_opaque,
            .stride = stride,
            .presentation_timestamp_ns = @intCast(buffer.time),
            // The mapped memory stays valid until the frame is released, so
            // the descriptor names it directly instead of hiding a pointer in
            // a private field.
            .pixels = pixels + chunk.offset,
            .release_fn = BufferRef.release,
            .release_ctx = ref,
        };
        frame.planes[0] = .{
            .offset = 0,
            .stride = stride,
            .width = self.negotiated.width,
            .height = self.negotiated.height,
            .size = chunk.size,
        };
        return frame;
    }

    fn onProcess(data: ?*anyopaque) callconv(.c) void {
        const self: *Stream = @ptrCast(@alignCast(data orelse return));
        // Each frame is handed over with the lock released, because a consumer
        // is free to release the frame it is handed and that release takes the
        // same lock.
        while (true) {
            const frame = self.nextFrame() orelse break;
            self.sink.frame(self.sink.ctx, frame);
        }
    }

    /// Dequeues one buffer and describes it, or null when the producer may not
    /// hand out another frame. A buffer that cannot be described goes back to
    /// the pool without ending the callback, so the rest of the queue drains.
    fn nextFrame(self: *Stream) ?FrameDescriptor {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const stream = self.stream orelse return null;
        if (self.stopped) return null;
        while (self.api.pw_stream_dequeue_buffer(stream)) |buffer| {
            if (self.describeLocked(buffer)) |frame| return frame;
            if (!self.lifetime.teardown) _ = self.api.pw_stream_queue_buffer(stream, buffer);
        }
        return null;
    }

    fn onStateChanged(data: ?*anyopaque, _: c_int, state: c_int, message: ?[*:0]const u8) callconv(.c) void {
        const self: *Stream = @ptrCast(@alignCast(data orelse return));
        _ = message;
        if (!self.delivering()) return;
        switch (state) {
            pw_stream_state_error => {
                self.sink.state(self.sink.ctx, .failed, .provider_failed);
            },
            pw_stream_state_paused => self.publishPaused(),
            pw_stream_state_streaming => self.publishStreaming(),
            else => {},
        }
    }

    fn onParamChanged(data: ?*anyopaque, id: u32, pod: ?*const Pod) callconv(.c) void {
        const self: *Stream = @ptrCast(@alignCast(data orelse return));
        if (id != spa_param_enum_format) return;
        if (!self.delivering()) return;
        // A pod that is not a raw video format, or that carries a size this
        // client cannot measure a frame against, is refused by the parser and
        // leaves the previous negotiation in place.
        const parsed = parseFormat(pod orelse return) orelse return;
        if (pixelFormatOf(parsed.format) == null) {
            self.sink.state(self.sink.ctx, .failed, .format_unsupported);
            return;
        }

        self.mutex.lockUncancelable(self.io);
        const changed = parsed.format != self.negotiated.format or
            parsed.width != self.negotiated.width or
            parsed.height != self.negotiated.height;
        self.negotiated = parsed;
        if (changed) self.format_epoch += 1;
        const epoch = self.format_epoch;
        const source = self.source;
        const node_id = self.node_id;
        self.mutex.unlock(self.io);

        // The whole negotiated stream, not just the layout. A report is
        // replaced whole, so a source the portal named and this stream keeps
        // has to travel with every one of them.
        self.sink.format(self.sink.ctx, .{
            .node_id = node_id,
            .sources = source.sources,
            .source_class_known = source.known,
            .position_x = source.position_x,
            .position_y = source.position_y,
            .width = parsed.width,
            .height = parsed.height,
            .format = pixelFormatOf(parsed.format).?,
            .color_space = colorSpaceOf(parsed),
            .color_range = colorRangeOf(parsed.color_range),
            .format_epoch = epoch,
            .frame_interval_ns = parsed.frameIntervalNs(),
        });
    }

    /// PipeWire paused the stream. The session behind it is still live and the
    /// transport comes back, so the consumer is told the stream is building
    /// again and the streaming latch is dropped on the way. A latch that is
    /// only ever set is how a resumed stream stops reporting itself and never
    /// delivers another frame.
    fn publishPaused(self: *Stream) void {
        if (!self.delivering()) return;
        self.mutex.lockUncancelable(self.io);
        self.published_streaming = false;
        self.mutex.unlock(self.io);
        self.sink.state(self.sink.ctx, .starting, .none);
    }

    /// Reports the stream as streaming, once per spell of streaming: a repeat
    /// of the same state inside one spell is not a second report, and the pause
    /// above is what begins the next spell. The negotiated format is not
    /// touched here — a resume republishes the state the consumer already holds
    /// a format for, and a real renegotiation arrives on its own as a
    /// parameter change carrying the next epoch.
    fn publishStreaming(self: *Stream) void {
        if (!self.delivering()) return;
        self.mutex.lockUncancelable(self.io);
        const already = self.published_streaming;
        self.published_streaming = true;
        self.mutex.unlock(self.io);
        if (already) return;
        self.sink.state(self.sink.ctx, .streaming, .none);
    }
};

/// The mapped pixel memory a frame names. The memory stays valid until the
/// frame is released, and the length comes from the plane the descriptor
/// describes, so a consumer never has to guess either.
pub fn payloadOf(frame: FrameDescriptor) ?struct { base: [*]const u8, len: usize } {
    const base = frame.pixels orelse return null;
    if (frame.plane_count == 0) return null;
    return .{ .base = base, .len = frame.planes[0].size };
}

// -- Behavioural tests -------------------------------------------------------
// A stand-in transport drives `Stream` through the lifetime paths PipeWire
// would drive. Nothing here loads the library, opens a socket or starts a
// thread, so the tests run headless and cannot capture anything.

const testing = std.testing;

fn openPipe() !std.posix.fd_t {
    var ends: [2]i32 = undefined;
    if (linux.errno(linux.pipe(&ends)) != .SUCCESS) return error.PipeFailed;
    _ = linux.close(ends[1]);
    return ends[0];
}

/// Closes the descriptor and reports whether it was open to begin with. Every
/// call site wants the descriptor gone afterwards, so asking about one twice
/// is not possible.
fn takeOpen(fd: std.posix.fd_t) bool {
    return linux.errno(linux.close(fd)) == .SUCCESS;
}

/// How many descriptors the process holds, read straight out of
/// `/proc/self/fd`. The directory handle this opens counts as one entry, and
/// it is the same one on every call, so two counts are comparable.
fn openFdCount() !usize {
    const rc = linux.open("/proc/self/fd", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.FdCountFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    // `struct linux_dirent64` is a fixed header followed by a name: eight
    // bytes of inode, eight of offset, two of record length, one of type, and
    // the name at nineteen.
    const name_offset = 19;
    var buffer: [4096]u8 align(8) = undefined;
    var count: usize = 0;
    while (true) {
        const filled = linux.getdents64(fd, &buffer, buffer.len);
        if (linux.errno(filled) != .SUCCESS) return error.FdCountFailed;
        if (filled == 0) break;

        var offset: usize = 0;
        while (offset + name_offset <= filled) {
            const reclen = std.mem.readInt(u16, buffer[offset + 16 ..][0..2], .little);
            if (reclen <= name_offset or offset + reclen > filled) break;
            const name = buffer[offset + name_offset ..][0 .. reclen - name_offset];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) count += 1;
            offset += reclen;
        }
    }
    return count;
}

/// A `Format` pod shaped like the one a session sends, so negotiation runs for
/// real. The declared body size is written once the pod is complete.
fn negotiatedPod(width: u32, height: u32, format: u32) FormatParam {
    var p: FormatParam = .{};
    p.put(0);
    p.put(spa_type_object);
    p.put(spa_type_object_format);
    p.put(spa_param_enum_format);
    p.putIdProp(spa_format_media_type, spa_media_type_video);
    p.putIdProp(spa_format_media_subtype, spa_media_subtype_raw);

    p.put(spa_format_video_size);
    p.put(0); // property flags
    p.put(8); // value body size
    p.put(spa_type_rectangle);
    p.put(width);
    p.put(height);
    p.pad();

    p.putIdProp(spa_format_video_format, format);
    std.mem.writeInt(u32, p.bytes[0..4], @intCast(p.len - pod_header_bytes), .little);
    return p;
}

/// Fires the parameter callback the transport would, with a negotiated layout
/// a test names. The callback reads the whole pod, so the pointer has to name
/// the full byte range and not an eight byte header copy.
fn dispatchFormat(fake: *Fake, width: u32, height: u32, format: u32) void {
    const events = fake.events orelse unreachable;
    const data = fake.listener_data orelse unreachable;
    const built = negotiatedPod(width, height, format);
    const pod: *const Pod = @ptrCast(@alignCast(&built.bytes[0]));
    events.param_changed.?(data, spa_param_enum_format, pod);
}

/// Counts what a producer reports, so a test can prove nothing reached the
/// consumer after the owner asked to stop.
const Counter = struct {
    frames: usize = 0,
    formats: usize = 0,
    states: usize = 0,
    /// The last state the consumer was told about, so a test can see which
    /// report came last rather than only how many arrived.
    last_state: ?capture.SessionState = null,
    /// The generation of the last format report.
    last_epoch: ?u32 = null,
    /// The frame the consumer is holding, if any.
    held: ?FrameDescriptor = null,

    fn sink(self: *Counter) capture.Sink {
        return .{ .ctx = self, .frame = onFrame, .format = onFormat, .state = onState };
    }

    fn onFrame(ctx: *anyopaque, frame: FrameDescriptor) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.frames += 1;
        self.held = frame;
    }

    fn onFormat(ctx: *anyopaque, info: capture.StreamInfo) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.formats += 1;
        self.last_epoch = info.format_epoch;
    }

    fn onState(ctx: *anyopaque, next: capture.SessionState, _: capture.FailureReason) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.states += 1;
        self.last_state = next;
    }

    fn release(self: *Counter) void {
        const held = self.held orelse return;
        self.held = null;
        held.release_fn.?(held.release_ctx);
    }
};

/// The step the stand-in transport should refuse, so a failure path can be
/// taken without a broken library.
const Failure = enum { none, loop_start, get_loop, connect, stream_new, stream_connect };

const Fake = struct {
    /// Slots that stand in for the opaque objects the API hands back. Each one
    /// holds the recorder, so an entry point finds its way home from any
    /// object pointer the client kept.
    loop_slot: ?*Fake = null,

    /// The thread loop owns a distinct event loop.
    loop_event_slot: ?*Fake = null,
    context_slot: ?*Fake = null,
    core_slot: ?*Fake = null,
    stream_slot: ?*Fake = null,

    /// What `pw_stream_add_listener` was given, so a test can fire the very
    /// callbacks a transport would.
    events: ?*const StreamEvents = null,
    listener_data: ?*anyopaque = null,

    pixels: [128]u8 = @splat(0x5a),
    chunk: Chunk = .{ .offset = 0, .size = 128, .stride = 16, .flags = 0 },
    /// The one descriptor the stand-in buffer points at. `init` fills it with
    /// this fake's own pixel bytes, so the buffer names real memory.
    datas: [1]Data,
    // `spa_buffer` and `buffer` name opaque pointer fields, so they cannot
    // live inside another struct by value and are allocated instead. Both
    // exist before `init` returns, or `init` fails and frees what it took.
    spa_buffer: *Buffer,
    buffer: *PwBuffer,

    /// The descriptor the transport was handed. The disconnect below closes
    /// it, which is where the real library ends it too.
    connect_fd: ?std.posix.fd_t = null,
    /// An unrelated descriptor reused after the library rejects a connection.
    replacement_fd: ?std.posix.fd_t = null,

    new_loops: usize = 0,
    started_loops: usize = 0,
    stopped_loops: usize = 0,
    destroyed_loops: usize = 0,
    new_contexts: usize = 0,
    destroyed_contexts: usize = 0,
    connects: usize = 0,
    disconnects: usize = 0,
    new_streams: usize = 0,
    destroyed_streams: usize = 0,
    queued: usize = 0,
    dequeues: usize = 0,

    /// Calls that obtain the event loop before context creation.
    get_loop_calls: usize = 0,

    /// The format pod the connect call carried, recorded as the bytes a reader
    /// at that address would see. The alignment is the one the object walk
    /// inside the pod needs, not the alignment of a byte array.
    connect_param: [512]u8 align(@alignOf(u64)) = @splat(0),
    connect_param_len: usize = 0,

    /// Stand-ins for the properties the real library hands out. The stream
    /// takes them over at `pw_stream_new` and frees them with the stream, and
    /// frees them itself when that call fails, so the counters below separate
    /// a release that belongs to the library from one that frees it twice.
    property_bytes: [property_slot_count]u8 = @splat(0),

    /// The binding keys the client wrote, kept as the bytes a reader at these
    /// addresses would see. A daemon resolves a stream to a node from these two
    /// keys and from nothing else, so a test that cannot read them back cannot
    /// say which node the stream asked for. An empty slot means the key was
    /// never written, which is a different answer from a wrong value.
    node_target: [64]u8 = @splat(0),
    node_target_len: usize = 0,
    target_object: [128]u8 = @splat(0),
    target_object_len: usize = 0,
    property_live: [property_slot_count]bool = @splat(false),
    property_owned: [property_slot_count]bool = @splat(false),
    properties_allocated: usize = 0,
    freed_by_client: usize = 0,
    freed_by_library: usize = 0,
    double_frees: usize = 0,
    /// The properties the stream took over.
    stream_properties: ?*PwProperties = null,

    fail: Failure = .none,
    /// Buffers the stand-in queue hands out before it reports itself empty.
    pending: usize = 0,

    /// How many stand-in property objects the recorder hands out.
    const property_slot_count = 4;

    /// The recorder `loopNew` reaches, since that one entry point has no
    /// handle to recover from. A test runs one harness at a time.
    var active_fake: ?*Fake = null;

    fn init(self: *Fake) std.mem.Allocator.Error!void {
        // SAFETY: the three fields that carry no default are filled before
        // this call returns. `datas` is written just below and the two
        // allocations land after that, so nothing reads them in between.
        self.* = .{ .datas = undefined, .spa_buffer = undefined, .buffer = undefined };
        self.loop_slot = self;
        self.loop_event_slot = self;
        self.context_slot = self;
        self.core_slot = self;
        self.stream_slot = self;
        self.datas[0] = .{
            .type = 0,
            .flags = 0,
            .fd = -1,
            .mapoffset = 0,
            .maxsize = self.pixels.len,
            .data = &self.pixels,
            .chunk = &self.chunk,
        };
        // The two PipeWire structures are laid out by the library, so the test
        // hands out pointers into its own memory rather than embedding them.
        self.spa_buffer = try testing.allocator.create(Buffer);
        errdefer testing.allocator.destroy(self.spa_buffer);
        self.spa_buffer.* = .{ .n_metas = 0, .n_datas = 1, .metas = null, .datas = &self.datas };
        self.buffer = try testing.allocator.create(PwBuffer);
        self.buffer.* = .{
            .buffer = self.spa_buffer,
            .user_data = null,
            .size = 0,
            .requested = 0,
            .time = 42,
        };
        // Published last, so a callback that arrives through `active_fake`
        // only ever finds a fake whose two buffers exist.
        active_fake = self;
    }

    fn deinit(self: *Fake) void {
        if (active_fake == self) active_fake = null;
        testing.allocator.destroy(self.buffer);
        testing.allocator.destroy(self.spa_buffer);
        self.* = undefined;
    }

    /// Recovers the recorder from any handle the client kept.
    fn of(handle: anytype) *Fake {
        const slot: *?*Fake = @ptrCast(@alignCast(handle));
        return slot.* orelse unreachable;
    }

    fn loopHandle(self: *Fake) *PwThreadLoop {
        return @ptrCast(&self.loop_slot);
    }

    /// The thread loop's event loop. A test compares this handle against the
    /// thread loop handle to prove which one reached the context.
    fn loopEventHandle(self: *Fake) *PwLoop {
        return @ptrCast(&self.loop_event_slot);
    }

    fn contextHandle(self: *Fake) *PwContext {
        return @ptrCast(&self.context_slot);
    }

    fn coreHandle(self: *Fake) *PwCore {
        return @ptrCast(&self.core_slot);
    }

    fn streamHandle(self: *Fake) *PwStream {
        return @ptrCast(&self.stream_slot);
    }

    /// `pw_properties_new` carries no handle to find the recorder through, so
    /// it reaches the same slot `pw_thread_loop_new` uses. A test runs one
    /// harness at a time, so the slot has a single owner.
    fn propertiesNew(_: ?[*:0]const u8, ...) callconv(.c) ?*PwProperties {
        const self = active_fake orelse return null;
        for (0..property_slot_count) |index| {
            if (self.property_live[index]) continue;
            self.property_live[index] = true;
            self.property_owned[index] = false;
            self.properties_allocated += 1;
            return @ptrCast(&self.property_bytes[index]);
        }
        return null;
    }

    /// Records the two keys that decide the binding and ignores the rest: the
    /// media keys are fixed text that says nothing about the target.
    fn propertiesSet(_: *PwProperties, key: [*:0]const u8, value: [*:0]const u8) callconv(.c) c_int {
        const self = active_fake orelse return 0;
        if (std.mem.eql(u8, std.mem.span(key), "node.target")) {
            self.node_target_len = copyInto(&self.node_target, std.mem.span(value));
        } else if (std.mem.eql(u8, std.mem.span(key), "target.object")) {
            self.target_object_len = copyInto(&self.target_object, std.mem.span(value));
        }
        return 0;
    }

    /// Writes as much of `text` as the buffer holds and returns how much of it
    /// was kept, so a value too long for its slot reads as a short one instead
    /// of a plausible id a test would accept.
    fn copyInto(buffer: []u8, text: []const u8) usize {
        const kept = @min(buffer.len, text.len);
        @memcpy(buffer[0..kept], text[0..kept]);
        return kept;
    }

    /// The only properties release the client can make. Once the stream owns an
    /// object a release from here is the free the stream repeats, and a
    /// release of a slot that is already gone is the second half of it.
    fn propertiesFree(properties: *PwProperties) callconv(.c) void {
        const self = active_fake orelse return;
        const index = self.propertyIndex(properties) orelse return;
        self.releaseProperty(index, .client);
    }

    fn propertyIndex(self: *Fake, properties: *PwProperties) ?usize {
        const base = @intFromPtr(&self.property_bytes[0]);
        const value = @intFromPtr(properties);
        if (value < base) return null;
        const offset = value - base;
        if (offset >= property_slot_count) return null;
        return @intCast(offset);
    }

    fn releaseProperty(self: *Fake, index: usize, by: enum { client, library }) void {
        if (!self.property_live[index]) {
            self.double_frees += 1;
            return;
        }
        switch (by) {
            .client => {
                if (self.property_owned[index]) self.freed_by_client += 1;
            },
            .library => self.freed_by_library += 1,
        }
        self.property_live[index] = false;
        self.property_owned[index] = false;
    }

    fn libraryInit(_: ?*c_int, _: ?*anyopaque) callconv(.c) void {}
    fn libraryDeinit() callconv(.c) void {}

    // `pw_thread_loop_new` carries no user data the client fills in, and it
    // is the one entry point that has no handle to recover from, so the
    // recorder of the harness under test is reached through this slot. A test
    // runs one harness at a time, so the slot has a single owner.
    fn loopNew(_: ?[*:0]const u8, _: ?*const anyopaque) callconv(.c) ?*PwThreadLoop {
        const self = active_fake orelse return null;
        self.new_loops += 1;
        return self.loopHandle();
    }

    fn loopStart(handle: *PwThreadLoop) callconv(.c) c_int {
        const self = of(handle);
        self.started_loops += 1;
        return if (self.fail == .loop_start) -1 else 0;
    }

    // This recorder has no loop thread; callbacks run synchronously.
    fn loopLock(_: *PwThreadLoop) callconv(.c) void {}

    fn loopUnlock(_: *PwThreadLoop) callconv(.c) void {}

    fn loopStop(handle: *PwThreadLoop) callconv(.c) void {
        const self = of(handle);
        self.stopped_loops += 1;
    }

    fn loopDestroy(handle: *PwThreadLoop) callconv(.c) void {
        const self = of(handle);
        self.destroyed_loops += 1;
    }

    /// The loop the thread loop runs is a second object, so the stand-in hands
    /// out a second handle and never the thread loop itself. That a client
    /// must use this one and not the other is proved against the real library,
    /// where the other one faults.
    fn loopGetLoop(handle: *PwThreadLoop) callconv(.c) ?*PwLoop {
        const self = of(handle);
        self.get_loop_calls += 1;
        if (self.fail == .get_loop) return null;
        return self.loopEventHandle();
    }

    fn contextNew(_: ?*PwLoop, _: ?*PwProperties, _: usize) callconv(.c) ?*PwContext {
        const self = active_fake orelse return null;
        self.new_contexts += 1;
        return self.contextHandle();
    }

    fn contextConnect(context: *PwContext, fd: c_int, _: ?*PwProperties, _: usize) callconv(.c) ?*PwCore {
        const self = of(context);
        self.connects += 1;
        if (self.fail == .connect) {
            // The API takes the socket even on error. A concurrent client
            // can reuse that number before the failed call returns.
            _ = linux.close(fd);
            // A descriptor this harness cannot open leaves the recorded one
            // unset, and a refused connect is the only answer a C entry point
            // can give. The test that reads `replacement_fd` turns the unset
            // value into a failure, which is where a failed open belongs.
            const replacement = openPipe() catch {
                self.replacement_fd = null;
                return null;
            };
            if (replacement != fd) {
                const duplicated = linux.dup3(replacement, fd, 0);
                _ = linux.close(replacement);
                std.debug.assert(linux.errno(duplicated) == .SUCCESS);
            }
            self.replacement_fd = fd;
            return null;
        }
        self.connect_fd = fd;
        return self.coreHandle();
    }

    fn contextDestroy(context: *PwContext) callconv(.c) void {
        const self = of(context);
        self.destroyed_contexts += 1;
    }

    fn coreDisconnect(core: *PwCore) callconv(.c) c_int {
        const self = of(core);
        self.disconnects += 1;
        if (self.connect_fd) |fd| {
            _ = linux.close(fd);
            self.connect_fd = null;
        }
        return 0;
    }

    /// The stream takes the properties over at this call, and a failed call
    /// frees them, which is why the client must not free them either way.
    fn streamNew(core: *PwCore, _: [*:0]const u8, props: ?*PwProperties) callconv(.c) ?*PwStream {
        const self = of(core);
        if (self.fail == .stream_new) {
            if (props) |given| {
                if (self.propertyIndex(given)) |index| self.releaseProperty(index, .library);
            }
            return null;
        }
        self.new_streams += 1;
        if (props) |given| {
            if (self.propertyIndex(given)) |index| self.property_owned[index] = true;
            self.stream_properties = given;
        }
        return self.streamHandle();
    }

    fn streamAddListener(
        stream: *PwStream,
        _: *Hook,
        events: *const StreamEvents,
        data: ?*anyopaque,
    ) callconv(.c) void {
        const self = of(stream);
        self.events = events;
        self.listener_data = data;
    }

    /// Reads the connect pod the way the library does: the declared body
    /// length is the only bound it has, and it follows that pointer into the
    /// body. A pod that names a header without its body offers nothing.
    fn streamConnect(
        stream: *PwStream,
        _: u32,
        _: u32,
        _: u32,
        params: ?[*]const ?*const Pod,
        _: u32,
    ) callconv(.c) c_int {
        const self = of(stream);
        if (self.fail == .stream_connect) return -1;
        const list = params orelse return 0;
        const pod = list[0] orelse return 0;
        const bytes: [*]const u8 = @ptrCast(pod);
        const bounded = @min(pod_header_bytes + @as(usize, pod.size), self.connect_param.len);
        @memcpy(self.connect_param[0..bounded], bytes[0..bounded]);
        self.connect_param_len = bounded;
        return 0;
    }

    fn streamDisconnect(stream: *PwStream) callconv(.c) c_int {
        const self = of(stream);
        if (self.events) |events| {
            if (events.state_changed) |changed| {
                changed(self.listener_data, pw_stream_state_paused, pw_stream_state_unconnected, null);
            }
        }
        return 0;
    }

    fn streamDestroy(stream: *PwStream) callconv(.c) void {
        const self = of(stream);
        self.destroyed_streams += 1;
        // The stream frees the properties it took over.
        if (self.stream_properties) |owned| {
            self.stream_properties = null;
            if (self.propertyIndex(owned)) |index| self.releaseProperty(index, .library);
        }
    }

    fn streamDequeue(stream: *PwStream) callconv(.c) ?*PwBuffer {
        const self = of(stream);
        self.dequeues += 1;
        if (self.pending == 0) return null;
        self.pending -= 1;
        return self.buffer;
    }

    fn streamQueue(stream: *PwStream, _: *PwBuffer) callconv(.c) c_int {
        const self = of(stream);
        self.queued += 1;
        return 0;
    }

    fn api() Api {
        return .{
            .pw_init = libraryInit,
            .pw_deinit = libraryDeinit,
            .pw_properties_new = propertiesNew,
            .pw_properties_set = propertiesSet,
            .pw_properties_free = propertiesFree,
            .pw_thread_loop_new = loopNew,
            .pw_thread_loop_get_loop = loopGetLoop,
            .pw_thread_loop_start = loopStart,
            .pw_thread_loop_stop = loopStop,
            .pw_thread_loop_lock = loopLock,
            .pw_thread_loop_unlock = loopUnlock,
            .pw_thread_loop_destroy = loopDestroy,
            .pw_context_new = contextNew,
            .pw_context_destroy = contextDestroy,
            .pw_context_connect_fd = contextConnect,
            .pw_core_disconnect = coreDisconnect,
            .pw_stream_new = streamNew,
            .pw_stream_add_listener = streamAddListener,
            .pw_stream_connect = streamConnect,
            .pw_stream_disconnect = streamDisconnect,
            .pw_stream_destroy = streamDestroy,
            .pw_stream_dequeue_buffer = streamDequeue,
            .pw_stream_queue_buffer = streamQueue,
        };
    }
};

/// One producer wired to a stand-in transport and a counting sink. The
/// transport table is addressed by `Stream`, so the harness is only ever built
/// in place and never copied.
const Harness = struct {
    threaded: std.Io.Threaded,
    api: Api,
    fake: Fake,
    counter: Counter,
    stream: Stream,

    fn init(self: *Harness) std.mem.Allocator.Error!void {
        self.threaded = .init(testing.allocator, .{});
        errdefer self.threaded.deinit();
        self.api = Fake.api();
        self.counter = .{};
        try self.fake.init();
        self.stream = Stream.init(testing.allocator, self.threaded.io(), &self.api, self.counter.sink());
    }

    fn deinit(self: *Harness) void {
        self.fake.deinit();
        self.threaded.deinit();
        self.* = undefined;
    }

    /// The descriptor count, so a test can prove it left nothing behind.
    fn openCount(self: *const Harness) !usize {
        _ = self;
        return openFdCount();
    }

    /// Fires a callback the way the transport would, through the listener the
    /// stream installed on itself.
    fn dispatch(self: *Harness, comptime call: enum { state, paused, streaming, format, process }) void {
        const events = self.fake.events orelse unreachable;
        const data = self.fake.listener_data orelse unreachable;
        switch (call) {
            .state => events.state_changed.?(data, pw_stream_state_error, pw_stream_state_error, "gone"),
            .paused => events.state_changed.?(data, pw_stream_state_connecting, pw_stream_state_paused, null),
            .streaming => events.state_changed.?(data, pw_stream_state_paused, pw_stream_state_streaming, null),
            .format => dispatchFormat(&self.fake, 4, 8, spa_video_format_bgra),
            .process => events.process.?(data),
        }
    }
};

/// A weak owner that never dies, so a session under test keeps accepting what a
/// producer hands it.
const LiveOwner = struct {
    fn isAlive(_: *const anyopaque) bool {
        return true;
    }
};

test "api-w20 a negotiated format keeps the source the portal chose" {
    // The portal names the chosen source and PipeWire negotiates only the
    // pixel layout, so a format report that leaves the source out erases the
    // user's choice from everything downstream of it.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var api = Fake.api();
    var fake: Fake = undefined;
    try fake.init();
    defer fake.deinit();

    var owner: LiveOwner = .{};
    var session = capture.Session.init(testing.allocator, threaded.io(), .{
        .context = &owner,
        .is_alive_fn = LiveOwner.isAlive,
    }, 2);
    defer session.deinit() catch unreachable;

    var stream = Stream.init(testing.allocator, threaded.io(), &api, session.sink());
    const sock = try openPipe();
    try stream.start(sock, 42, .{
        .sources = .{ .bits = 1 },
        .known = true,
        .position_x = 1920,
        .position_y = 64,
    });

    dispatchFormat(&fake, 8, 4, spa_video_format_bgra);
    const reported = session.streamInfo();
    try testing.expectEqual(@as(u32, 42), reported.node_id);
    try testing.expect(reported.source_class_known);
    try testing.expect(reported.sources.has(.monitor));
    try testing.expectEqual(@as(i32, 1920), reported.position_x);
    try testing.expectEqual(@as(i32, 64), reported.position_y);
    try testing.expectEqual(@as(u32, 8), reported.width);
    try testing.expectEqual(@as(u32, 4), reported.height);
    try testing.expectEqual(@as(u32, 1), reported.format_epoch);

    // A new resolution is a new layout, and the source is still the one the
    // portal reported rather than the one a partial report would have left.
    dispatchFormat(&fake, 16, 4, spa_video_format_bgra);
    const resized = session.streamInfo();
    try testing.expectEqual(@as(u32, 2), resized.format_epoch);
    try testing.expectEqual(@as(u32, 16), resized.width);
    try testing.expectEqual(@as(u32, 42), resized.node_id);
    try testing.expect(resized.sources.has(.monitor));
    try testing.expectEqual(@as(i32, 1920), resized.position_x);
    try testing.expectEqual(@as(i32, 64), resized.position_y);

    stream.stop();
    stream.destroyIfReady();
}

test "api-w20 a portal that names no class reports an unknown one" {
    // An unnamed class is not the empty class: a consumer that cannot tell
    // them apart will claim a source belongs to no class, which is a claim the
    // platform never made.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var api = Fake.api();
    var fake: Fake = undefined;
    try fake.init();
    defer fake.deinit();

    var owner: LiveOwner = .{};
    var session = capture.Session.init(testing.allocator, threaded.io(), .{
        .context = &owner,
        .is_alive_fn = LiveOwner.isAlive,
    }, 2);
    defer session.deinit() catch unreachable;

    var stream = Stream.init(testing.allocator, threaded.io(), &api, session.sink());
    const sock = try openPipe();
    try stream.start(sock, 9, .{});

    dispatchFormat(&fake, 8, 4, spa_video_format_bgra);
    const reported = session.streamInfo();
    try testing.expect(!reported.source_class_known);
    try testing.expect(reported.sources.isEmpty());

    stream.stop();
    stream.destroyIfReady();
}

test "api-w20 a connected stream hands its own socket copy to the transport" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const open_before = try h.openCount();
    const sock = try openPipe();
    try h.stream.start(sock, 7, .{});

    // The caller's descriptor is closed and the transport holds a live one.
    try testing.expect(!takeOpen(sock));
    try testing.expect(h.fake.connect_fd != null);
    try testing.expect(h.fake.connect_fd.? != sock);

    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.connects);
    try testing.expectEqual(@as(usize, 1), h.fake.disconnects);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_contexts);
    try testing.expectEqual(@as(usize, 1), h.fake.stopped_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    // The transport closed the descriptor it was handed.
    try testing.expect(h.fake.connect_fd == null);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 the connect pod names a header and the body behind it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const sock = try openPipe();
    try h.stream.start(sock, 7, .{});

    // The library reads the declared body length from the address it is handed
    // and follows it into the body. A pointer at a copy of the eight-byte
    // header alone therefore offers a pod whose body is whatever the next
    // stack bytes hold, and those bytes parse as no format at all.
    const offered: []const u8 = h.fake.connect_param[0..h.fake.connect_param_len];
    try testing.expect(isFormatObject(offered, spa_param_enum_format));
    // The two media keys are the first properties of the object body, so
    // walking to them proves the reader was handed the whole pod and not a
    // header whose body is the next stack bytes.
    const properties: ObjectProperties = .{ .bytes = offered };
    const media_type = properties.find(spa_format_media_type) orelse return error.MissingMediaType;
    try testing.expectEqual(spa_media_type_video, media_type.asId() orelse return error.BadMediaType);
    const media_subtype = properties.find(spa_format_media_subtype) orelse
        return error.MissingMediaSubtype;
    try testing.expectEqual(spa_media_subtype_raw, media_subtype.asId() orelse return error.BadMediaSubtype);
    // The size and the rate are the source's to decide, so this offer names no
    // picture at all. A negotiation with no size is not a picture the frame
    // path can measure a frame against, so the parser refuses this pod whole
    // rather than report 0x0 as a layout that was agreed on.
    try testing.expect(parseFormatBytes(offered) == null);
    const choice = properties.find(spa_format_video_format) orelse
        return error.MissingOfferedFormats;
    try testing.expectEqual(spa_type_choice, choice.type);
    try testing.expectEqual(spa_choice_enum, std.mem.readInt(u32, choice.data[0..4], .little));
    try testing.expectEqual(spa_type_id, std.mem.readInt(u32, choice.data[12..16], .little));
    // The source can choose either RGBA or BGRA. Size remains source-owned.
    var rgba = false;
    var bgra = false;
    var offset: usize = 16;
    while (offset + 4 <= choice.data.len) : (offset += 4) {
        const value = std.mem.readInt(u32, choice.data[offset..][0..4], .little);
        rgba = rgba or value == spa_video_format_rgba;
        bgra = bgra or value == spa_video_format_bgra;
    }
    try testing.expect(rgba and bgra);

    h.stream.stop();
    h.stream.destroyIfReady();
}

test "api-w20 the stream frees the properties it took over and the client frees none" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const sock = try openPipe();
    try h.stream.start(sock, 7, .{});
    try testing.expectEqual(@as(usize, 1), h.fake.properties_allocated);

    // The stream keeps the properties from `pw_stream_new` and frees them with
    // itself. A client that releases them as well frees the same object twice,
    // which is the abort the real allocator answers with.
    try testing.expectEqual(@as(usize, 0), h.fake.freed_by_client);
    try testing.expectEqual(@as(usize, 0), h.fake.double_frees);

    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.freed_by_library);
    try testing.expectEqual(@as(usize, 0), h.fake.freed_by_client);
    try testing.expectEqual(@as(usize, 0), h.fake.double_frees);
}

test "api-w20 a refused connect closes both socket copies and the thread loop" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fake.fail = .connect;

    const open_before = try h.openCount();
    const sock = try openPipe();
    try testing.expectError(Error.StreamConnectFailed, h.stream.start(sock, 7, .{}));
    const replacement = h.fake.replacement_fd orelse return error.NoReplacementDescriptor;
    h.fake.replacement_fd = null;
    try testing.expect(takeOpen(replacement));

    try testing.expect(!takeOpen(sock));
    try testing.expect(h.fake.connect_fd == null);
    try testing.expectEqual(@as(usize, 1), h.fake.new_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.started_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.stopped_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.new_contexts);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_contexts);
    try testing.expectEqual(@as(usize, 0), h.fake.disconnects);
    try testing.expectEqual(open_before, try h.openCount());

    // Nothing is left to tear down, and asking again destroys nothing twice.
    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 the stream binds the node the portal named and names no other" {
    // The daemon resolves a stream to a node from the binding keys alone, and a
    // key whose value it cannot resolve does not fail: the stream is linked to
    // whatever video source the graph offers by default. So the binding has to
    // carry exactly the node id the portal handed over, under the one key that
    // value fits.
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const sock = try openPipe();
    try h.stream.start(sock, 127, .{});
    h.stream.stop();
    h.stream.destroyIfReady();

    try testing.expectEqualStrings("127", h.fake.node_target[0..h.fake.node_target_len]);
    // A second, unresolvable key is worse than none at all: its presence keeps
    // the id above from ever being read, which is how a capture meant for the
    // monitor ended up on an MJPEG webcam.
    try testing.expectEqual(@as(usize, 0), h.fake.target_object_len);
}

test "api-w20 a portal that named no node is refused before a node is created" {
    // A target of zero resolves to no node, so the stream would be linked to a
    // default video source and every frame it delivered would come from a
    // surface nobody chose. The refusal names that, and it lands before any
    // PipeWire object exists and without leaking the caller's descriptor.
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const open_before = try h.openCount();
    const sock = try openPipe();
    try testing.expectError(Error.TargetNodeNotNamed, h.stream.start(sock, 0, .{}));

    try testing.expect(!takeOpen(sock));
    try testing.expectEqual(@as(usize, 0), h.fake.new_loops);
    try testing.expectEqual(@as(usize, 0), h.fake.new_contexts);
    try testing.expectEqual(@as(usize, 0), h.fake.connects);
    try testing.expectEqual(@as(usize, 0), h.fake.new_streams);
    try testing.expectEqual(@as(usize, 0), h.fake.node_target_len);
    try testing.expectEqual(open_before, try h.openCount());

    // A stream that never started still tears down cleanly.
    h.stream.stop();
    h.stream.destroyIfReady();
}

test "api-w20 a thread loop that never started is destroyed without a stop" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fake.fail = .loop_start;

    const open_before = try h.openCount();
    const sock = try openPipe();
    try testing.expectError(Error.StreamConnectFailed, h.stream.start(sock, 7, .{}));

    try testing.expect(!takeOpen(sock));
    try testing.expectEqual(@as(usize, 1), h.fake.new_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.started_loops);
    try testing.expectEqual(@as(usize, 0), h.fake.stopped_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expectEqual(@as(usize, 0), h.fake.new_contexts);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 a thread loop that cannot hand out its loop is stopped and destroyed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fake.fail = .get_loop;

    const open_before = try h.openCount();
    const sock = try openPipe();
    try testing.expectError(Error.StreamConnectFailed, h.stream.start(sock, 7, .{}));

    // The loop is running, so it is stopped before it is destroyed, and no
    // context was ever created on a loop that could not be named.
    try testing.expect(!takeOpen(sock));
    try testing.expectEqual(@as(usize, 1), h.fake.get_loop_calls);
    try testing.expectEqual(@as(usize, 1), h.fake.stopped_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expectEqual(@as(usize, 0), h.fake.new_contexts);
    try testing.expectEqual(@as(usize, 0), h.fake.destroyed_contexts);
    try testing.expectEqual(open_before, try h.openCount());

    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 a stream that cannot be created is torn down from the inside out" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fake.fail = .stream_new;

    const open_before = try h.openCount();
    const sock = try openPipe();
    try testing.expectError(Error.StreamConnectFailed, h.stream.start(sock, 7, .{}));

    try testing.expect(!takeOpen(sock));
    try testing.expectEqual(@as(usize, 0), h.fake.new_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.disconnects);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_contexts);
    try testing.expectEqual(@as(usize, 1), h.fake.stopped_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expect(h.fake.connect_fd == null);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 a refused stream frees its properties once and only once" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fake.fail = .stream_new;

    const sock = try openPipe();
    try testing.expectError(Error.StreamConnectFailed, h.stream.start(sock, 7, .{}));

    // A failed `pw_stream_new` frees the properties it was handed, because
    // ownership passed at that call. A client that also releases them frees
    // the same object twice, and the second free of a live heap block is what
    // the allocator aborts on.
    try testing.expectEqual(@as(usize, 1), h.fake.properties_allocated);
    try testing.expectEqual(@as(usize, 1), h.fake.freed_by_library);
    try testing.expectEqual(@as(usize, 0), h.fake.freed_by_client);
    try testing.expectEqual(@as(usize, 0), h.fake.double_frees);
}

test "api-w20 a stream whose connect is refused is torn down completely" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fake.fail = .stream_connect;

    const open_before = try h.openCount();
    const sock = try openPipe();
    try testing.expectError(Error.StreamConnectFailed, h.stream.start(sock, 7, .{}));

    try testing.expect(!takeOpen(sock));
    try testing.expectEqual(@as(usize, 1), h.fake.new_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.disconnects);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_contexts);
    try testing.expectEqual(@as(usize, 1), h.fake.stopped_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expect(h.fake.connect_fd == null);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 a frame the consumer still holds keeps the transport alive" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const open_before = try h.openCount();
    const sock = try openPipe();
    try h.stream.start(sock, 7, .{});
    h.dispatch(.format);
    h.fake.pending = 1;
    h.dispatch(.process);
    try testing.expectEqual(@as(usize, 1), h.counter.frames);
    try testing.expectEqual(@as(u32, 1), h.stream.outstandingFrames());

    h.stream.stop();
    h.stream.destroyIfReady();
    h.stream.stop();
    // The frame is still out, so nothing may be destroyed yet.
    try testing.expectEqual(@as(usize, 0), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 0), h.fake.disconnects);
    try testing.expectEqual(@as(usize, 0), h.fake.stopped_loops);
    try testing.expectEqual(@as(u32, 1), h.stream.outstandingFrames());

    // The frame goes back, and only now may the transport go away.
    h.counter.release();
    try testing.expectEqual(@as(u32, 0), h.stream.outstandingFrames());
    // The pool is being freed, so the buffer is not queued into it again.
    try testing.expectEqual(@as(usize, 0), h.fake.queued);

    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.disconnects);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_contexts);
    try testing.expectEqual(@as(usize, 1), h.fake.stopped_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);

    // Asking again destroys nothing a second time.
    h.stream.destroyIfReady();
    h.stream.stop();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.stopped_loops);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 a frame released while the stream runs goes back to the pool" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const open_before = try h.openCount();
    const sock = try openPipe();
    try h.stream.start(sock, 7, .{});
    h.dispatch(.format);
    h.fake.pending = 1;
    h.dispatch(.process);
    try testing.expectEqual(@as(u32, 1), h.stream.outstandingFrames());

    h.counter.release();
    try testing.expectEqual(@as(usize, 1), h.fake.queued);
    try testing.expectEqual(@as(u32, 0), h.stream.outstandingFrames());

    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 nothing reaches the consumer after the owner stopped" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const open_before = try h.openCount();
    const sock = try openPipe();
    try h.stream.start(sock, 7, .{});

    // A running producer does report.
    h.dispatch(.state);
    h.dispatch(.format);
    h.fake.pending = 1;
    h.dispatch(.process);
    try testing.expectEqual(@as(usize, 1), h.counter.states);
    try testing.expectEqual(@as(usize, 1), h.counter.formats);
    try testing.expectEqual(@as(usize, 1), h.counter.frames);
    try testing.expectEqual(@as(usize, 0), h.fake.queued);

    // A frame is still out, so the transport is not released yet.
    h.stream.stop();
    try testing.expectEqual(@as(usize, 0), h.fake.destroyed_contexts);
    try testing.expectEqual(@as(usize, 0), h.fake.destroyed_loops);
    try testing.expectEqual(@as(u32, 1), h.stream.outstandingFrames());

    // A transport that keeps talking after that reaches nobody.
    h.dispatch(.state);
    h.dispatch(.format);
    h.fake.pending = 1;
    h.dispatch(.process);
    try testing.expectEqual(@as(usize, 1), h.counter.states);
    try testing.expectEqual(@as(usize, 1), h.counter.formats);
    try testing.expectEqual(@as(usize, 1), h.counter.frames);
    try testing.expectEqual(@as(usize, 0), h.fake.queued);

    h.counter.release();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_contexts);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 a stream that pauses comes back as a stream and frames again" {
    // A transport that pauses and comes back is one stream, not two. The
    // consumer has to hear about the resume: a producer that reports its first
    // streaming state once and then latches the report stays silent after the
    // pause, and a session waiting on a frame waits for the rest of its life.
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const open_before = try h.openCount();
    const sock = try openPipe();
    try h.stream.start(sock, 7, .{});
    h.dispatch(.format);
    const epoch = h.counter.last_epoch.?;

    h.dispatch(.streaming);
    try testing.expectEqual(@as(usize, 1), h.counter.states);
    try testing.expectEqual(capture.SessionState.streaming, h.counter.last_state.?);

    // A pause is a live stream that has nothing to deliver, not an ending.
    h.dispatch(.paused);
    try testing.expectEqual(@as(usize, 2), h.counter.states);
    try testing.expectEqual(capture.SessionState.starting, h.counter.last_state.?);

    h.dispatch(.streaming);
    try testing.expectEqual(@as(usize, 3), h.counter.states);
    try testing.expectEqual(capture.SessionState.streaming, h.counter.last_state.?);

    // Coming back is not a renegotiation: the generation the negotiation
    // produced is the one the stream keeps, and it is not reported twice.
    try testing.expectEqual(@as(usize, 1), h.counter.formats);
    try testing.expectEqual(epoch, h.counter.last_epoch.?);

    // The resumed stream frames, and the frame still goes back through the
    // producer's own release path.
    h.fake.pending = 1;
    h.dispatch(.process);
    try testing.expectEqual(@as(usize, 1), h.counter.frames);
    h.counter.release();
    try testing.expectEqual(@as(u32, 0), h.stream.outstandingFrames());

    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 a release after the transport is gone touches no PipeWire object" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const open_before = try h.openCount();
    const sock = try openPipe();
    try h.stream.start(sock, 7, .{});
    h.dispatch(.format);
    h.fake.pending = 1;
    h.dispatch(.process);
    // Proving a frame came out is what makes the late callback meaningful.
    try testing.expect(h.counter.held != null);
    try testing.expectEqual(@as(u32, 1), h.stream.outstandingFrames());

    // The frame is released while the transport is still up, so this teardown
    // is immediate rather than deferred.
    h.counter.release();
    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    const dequeues_before = h.fake.dequeues;
    const queued_before = h.fake.queued;
    const frames_before = h.counter.frames;

    // A transport that kept talking would have to go through the stream that
    // no longer exists. Nothing may be dequeued or queued after the teardown.
    h.fake.pending = 1;
    h.dispatch(.process);
    try testing.expectEqual(dequeues_before, h.fake.dequeues);
    try testing.expectEqual(queued_before, h.fake.queued);
    try testing.expectEqual(frames_before, h.counter.frames);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 a producer that never started is safe to stop twice" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    h.stream.stop();
    h.stream.destroyIfReady();
    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 0), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 0), h.fake.destroyed_loops);
    try testing.expectEqual(@as(usize, 0), h.counter.states);
}

test "api-w20 PipeWire frame pixels start at the mapped chunk offset" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    defer {
        h.counter.release();
        h.stream.stop();
        h.stream.destroyIfReady();
    }
    try h.stream.start(try openPipe(), 7, .{});
    dispatchFormat(&h.fake, 4, 2, spa_video_format_bgra);
    h.fake.chunk = .{ .offset = 16, .size = 32, .stride = 16, .flags = 0 };
    h.fake.pixels[16] = 0xc3;
    h.fake.pending = 1;
    h.dispatch(.process);

    const held = h.counter.held orelse return error.NoFrame;
    try testing.expectEqual(@intFromPtr(h.fake.pixels[16..].ptr), @intFromPtr(held.pixels.?));
    try testing.expectEqual(@as(u8, 0xc3), held.pixels.?[0]);
    try testing.expectEqual(@as(usize, 32), held.planes[0].size);
}

test "api-w20 PipeWire refuses chunks outside the mapped packed frame" {
    const malformed = [_]Chunk{
        .{ .offset = 65, .size = 32, .stride = 16, .flags = 0 },
        .{ .offset = 48, .size = 32, .stride = 16, .flags = 0 },
        .{ .offset = 0, .size = 16, .stride = 16, .flags = 0 },
        .{ .offset = 0, .size = 32, .stride = 8, .flags = 0 },
        .{ .offset = 0, .size = 32, .stride = -16, .flags = 0 },
    };
    for (malformed) |chunk| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        defer {
            h.counter.release();
            h.stream.stop();
            h.stream.destroyIfReady();
        }
        try h.stream.start(try openPipe(), 7, .{});
        dispatchFormat(&h.fake, 4, 2, spa_video_format_bgra);
        h.fake.datas[0].maxsize = 64;
        h.fake.chunk = chunk;
        h.fake.pending = 1;
        h.dispatch(.process);

        try testing.expectEqual(@as(usize, 0), h.counter.frames);
        try testing.expectEqual(@as(u32, 0), h.stream.outstandingFrames());
        try testing.expectEqual(@as(usize, 1), h.fake.queued);
    }
}

test "api-w20 a buffer the producer no longer holds goes back nowhere" {
    // The producer's count is the only authority on which frames are still
    // its own. A release that arrives after the frame was already accounted
    // for returns nothing: queueing its buffer would hand PipeWire's pool a
    // `pw_buffer` the pool already owns, and taking the count down again
    // would leave the transport waiting on a frame nobody will ever bring
    // back, so neither the loop nor the context is ever freed.
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const open_before = try h.openCount();
    try h.stream.start(try openPipe(), 7, .{});
    h.dispatch(.format);
    h.fake.pending = 1;
    h.dispatch(.process);
    try testing.expectEqual(@as(u32, 1), h.stream.outstandingFrames());

    // The frame is taken back on the accounting path, which is what a
    // consumer that returned it through its own session does. The descriptor
    // still names a buffer, and its release callback still runs.
    try testing.expect(h.stream.dropFrame());
    const late = h.counter.held orelse return error.NoFrame;
    h.counter.held = null;
    late.release_fn.?(late.release_ctx);

    // Nothing was queued a second time and the count did not move.
    try testing.expectEqual(@as(usize, 0), h.fake.queued);
    try testing.expectEqual(@as(u32, 0), h.stream.outstandingFrames());

    // And the refusal costs the producer nothing: it still tears down.
    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_loops);
    try testing.expectEqual(open_before, try h.openCount());
}

test "api-w20 every frame that comes back is queued exactly once" {
    // Several frames in flight at once is the only case where two releases
    // could be confused for one another, and it is where a count taken twice
    // would go unnoticed until the transport refused to go away.
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    defer {
        h.stream.stop();
        h.stream.destroyIfReady();
    }

    try h.stream.start(try openPipe(), 7, .{});
    h.dispatch(.format);

    var frames: [3]FrameDescriptor = undefined;
    for (&frames) |*frame| {
        h.fake.pending = 1;
        h.dispatch(.process);
        frame.* = h.counter.held orelse return error.NoFrame;
        h.counter.held = null;
    }
    try testing.expectEqual(@as(u32, 3), h.stream.outstandingFrames());

    const dequeues_before = h.fake.dequeues;
    for (frames) |frame| frame.release_fn.?(frame.release_ctx);
    // One queue call per frame, and the release path itself dequeues nothing.
    try testing.expectEqual(@as(usize, 3), h.fake.queued);
    try testing.expectEqual(dequeues_before, h.fake.dequeues);
    try testing.expectEqual(@as(u32, 0), h.stream.outstandingFrames());

    h.stream.stop();
    h.stream.destroyIfReady();
    try testing.expectEqual(@as(usize, 1), h.fake.destroyed_streams);
}
