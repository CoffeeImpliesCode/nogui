//! FFmpeg decoder and metadata probe for local FLAC playback.

const std = @import("std");
const spotify_data = @import("spotify_data.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/dict.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavutil/samplefmt.h");
    @cInclude("libswresample/swresample.h");
    @cInclude("libswscale/swscale.h");
});

pub const output_sample_rate_hz: u32 = 48_000;
pub const output_channel_count: u8 = 2;
pub const pcm_frame_capacity: u32 = 4_096;
pub const pcm_sample_capacity: usize =
    @as(usize, pcm_frame_capacity) * @as(usize, output_channel_count);

comptime {
    std.debug.assert(output_channel_count > 0);
    std.debug.assert(pcm_frame_capacity > 0);
    std.debug.assert(pcm_sample_capacity == 8_192);
}

pub const SourceFormat = struct {
    sample_rate_hz: i32,
    channel_count: i32,
};

pub const OutputFormat = struct {
    sample_rate_hz: u32,
    channel_count: u8,
};

pub const NegotiationError = error{
    InvalidSampleRate,
    InvalidChannelCount,
    OutputCapacityExceeded,
};

pub const InitError = error{
    PacketAllocationFailed,
    FrameAllocationFailed,
};

pub const OpenError = NegotiationError || std.mem.Allocator.Error || error{
    OpenInputFailed,
    StreamInfoFailed,
    AudioStreamNotFound,
    DecoderNotFound,
    CodecAllocationFailed,
    CodecParametersFailed,
    CodecOpenFailed,
    ResamplerAllocationFailed,
    ResamplerInitFailed,
};

pub const DecodeError = error{
    NotOpen,
    DemuxReadFailed,
    PacketSendFailed,
    FrameReceiveFailed,
    DecoderProtocolFailed,
    InvalidFrame,
    ResampleFailed,
    OutputCapacityExceeded,
};

pub const SeekError = error{
    NotOpen,
    InvalidSeekPosition,
    SeekFailed,
    ResamplerResetFailed,
};

/// A probe fails only when the file cannot be read. A file with no usable
/// audio stream still yields fallback metadata, so one unplayable entry can
/// not fail a whole library scan; playback reports the missing stream when
/// the decoder opens the file.
pub const ProbeError = std.mem.Allocator.Error || error{
    OpenInputFailed,
    StreamInfoFailed,
};

/// Hard limits keep untrusted attached-picture metadata from consuming
/// unbounded memory or overflowing pixel-count calculations.
pub const max_artwork_bytes: usize = 16 * 1024 * 1024;
/// Base64 text can expand a bounded image by at most four bytes per three bytes.
pub const max_artwork_base64_bytes: usize = ((max_artwork_bytes + 2) / 3) * 4;
pub const max_artwork_width: u32 = 4096;
pub const max_artwork_height: u32 = 4096;
pub const max_artwork_pixels: usize = 16 * 1024 * 1024;

pub const Artwork = spotify_data.Artwork;

pub const ArtworkDecodeError = std.mem.Allocator.Error || error{
    InvalidArtwork,
    DecoderNotFound,
    CodecAllocationFailed,
    CodecOpenFailed,
    PacketAllocationFailed,
    FrameAllocationFailed,
    PacketUploadFailed,
    FrameDecodeFailed,
    ImageAllocationFailed,
    ImageConversionFailed,
};

/// Allocator-owned RGBA8 pixels produced from an embedded image packet.
pub const DecodedArtwork = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *DecodedArtwork, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};
/// Allocator-owned metadata copied out of FFmpeg's format context.
pub const Metadata = struct {
    title: []u8,
    artist: []u8,
    album: []u8,
    duration_str: []u8,
    duration_sec: u32,
    artwork: ?Artwork = null,

    pub fn deinit(self: *Metadata, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.artist);
        gpa.free(self.album);
        gpa.free(self.duration_str);
        if (self.artwork) |*artwork| artwork.deinit(gpa);
        self.* = undefined;
    }
};

/// The final output format is fixed so playback does not renegotiate mid-stream.
pub fn negotiateOutputFormat(source: SourceFormat) NegotiationError!OutputFormat {
    if (source.sample_rate_hz <= 0) return error.InvalidSampleRate;
    if (source.channel_count <= 0) return error.InvalidChannelCount;

    return .{
        .sample_rate_hz = output_sample_rate_hz,
        .channel_count = output_channel_count,
    };
}

/// Return the interleaved sample count for a bounded number of PCM frames.
pub fn interleavedSampleCount(
    frame_count: u32,
    format: OutputFormat,
) NegotiationError!usize {
    if (format.sample_rate_hz == 0) return error.InvalidSampleRate;
    if (format.channel_count == 0) return error.InvalidChannelCount;
    if (format.channel_count > output_channel_count) return error.InvalidChannelCount;

    const sample_count = std.math.mul(
        usize,
        @as(usize, frame_count),
        @as(usize, format.channel_count),
    ) catch return error.OutputCapacityExceeded;
    if (sample_count > pcm_sample_capacity) return error.OutputCapacityExceeded;
    return sample_count;
}

/// A borrowed interleaved f32 PCM view.
///
/// `samples_interleaved` points into its `Decoder`. It remains valid only until
/// the next call to `read`, `open`, `seek`, `close`, or `deinit` on that decoder.
pub const PcmChunk = struct {
    samples_interleaved: []const f32,
    frame_count: u32,
    format: OutputFormat,
};

pub const DecodeResult = union(enum) {
    pcm: PcmChunk,
    end_of_stream,
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    path: ?[:0]u8,
    format_context: ?*c.AVFormatContext,
    codec_context: ?*c.AVCodecContext,
    packet: *c.AVPacket,
    frame: *c.AVFrame,
    resampler_context: ?*c.SwrContext,
    audio_stream_index: ?c_int,
    output_format: ?OutputFormat,
    duration_us: i64,
    pcm: [pcm_sample_capacity]f32,
    pcm_sample_count: usize,
    packet_pending: bool,
    demux_eof: bool,
    flush_sent: bool,
    codec_eof: bool,
    resampler_buffered: bool,
    resampler_eof: bool,

    const OpenResources = struct {
        format_context: *c.AVFormatContext,
        codec_context: *c.AVCodecContext,
        resampler_context: *c.SwrContext,
        audio_stream_index: c_int,
        output_format: OutputFormat,
    };

    /// Allocate packet and frame storage reused by every opened stream.
    pub fn init(gpa: std.mem.Allocator) InitError!Decoder {
        const packet = c.av_packet_alloc() orelse return error.PacketAllocationFailed;
        errdefer freePacket(packet);

        const frame = c.av_frame_alloc() orelse return error.FrameAllocationFailed;

        return .{
            .gpa = gpa,
            .path = null,
            .format_context = null,
            .codec_context = null,
            .packet = packet,
            .frame = frame,
            .resampler_context = null,
            .audio_stream_index = null,
            .output_format = null,
            .duration_us = 0,
            // SAFETY: swr_convert fills pcm before pcmChunk exposes any samples;
            // pcm_sample_count bounds every subsequent read.
            .pcm = undefined,
            .pcm_sample_count = 0,
            .packet_pending = false,
            .demux_eof = false,
            .flush_sent = false,
            .codec_eof = false,
            .resampler_buffered = false,
            .resampler_eof = false,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.close();
        freeFrame(self.frame);
        freePacket(self.packet);
        self.* = undefined;
    }

    /// Open `path` transactionally and retain an owned copy until `close`.
    pub fn open(self: *Decoder, path: []const u8) OpenError!void {
        const next_path = try self.gpa.dupeZ(u8, path);
        errdefer self.gpa.free(next_path);

        var next_format_context: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&next_format_context, next_path.ptr, null, null) < 0) {
            return error.OpenInputFailed;
        }
        errdefer closeFormat(next_format_context);

        const format_context = next_format_context orelse return error.OpenInputFailed;
        if (c.avformat_find_stream_info(format_context, null) < 0) {
            return error.StreamInfoFailed;
        }

        var codec: ?*const c.AVCodec = null;
        const stream_index = c.av_find_best_stream(
            format_context,
            c.AVMEDIA_TYPE_AUDIO,
            -1,
            -1,
            &codec,
            0,
        );
        if (stream_index < 0) return error.AudioStreamNotFound;
        const selected_codec = codec orelse return error.DecoderNotFound;

        const stream = format_context.streams[@intCast(stream_index)];
        const codec_parameters = stream.*.codecpar;

        const codec_context = c.avcodec_alloc_context3(selected_codec) orelse
            return error.CodecAllocationFailed;
        errdefer freeCodec(codec_context);
        if (c.avcodec_parameters_to_context(codec_context, codec_parameters) < 0) {
            return error.CodecParametersFailed;
        }
        if (c.avcodec_open2(codec_context, selected_codec, null) < 0) {
            return error.CodecOpenFailed;
        }

        const output_format = try negotiateOutputFormat(.{
            .sample_rate_hz = codec_context.*.sample_rate,
            .channel_count = codec_context.*.ch_layout.nb_channels,
        });
        // SAFETY: av_channel_layout_default initializes output_layout before any read.
        var output_layout: c.AVChannelLayout = undefined;
        c.av_channel_layout_default(
            &output_layout,
            @as(c_int, @intCast(output_format.channel_count)),
        );
        defer c.av_channel_layout_uninit(&output_layout);

        var next_resampler_context: ?*c.SwrContext = null;
        errdefer freeResampler(next_resampler_context);
        if (c.swr_alloc_set_opts2(
            &next_resampler_context,
            &output_layout,
            c.AV_SAMPLE_FMT_FLT,
            @as(c_int, @intCast(output_format.sample_rate_hz)),
            &codec_context.*.ch_layout,
            codec_context.*.sample_fmt,
            codec_context.*.sample_rate,
            0,
            null,
        ) < 0) {
            return error.ResamplerAllocationFailed;
        }

        const resampler_context = next_resampler_context orelse
            return error.ResamplerAllocationFailed;
        if (c.swr_init(resampler_context) < 0) return error.ResamplerInitFailed;

        // SAFETY: close releases stream resources but keeps Decoder storage live
        // for this prepared stream and future reopen operations.
        self.close();
        self.path = next_path;
        self.format_context = format_context;
        self.codec_context = codec_context;
        self.resampler_context = resampler_context;
        self.audio_stream_index = stream_index;
        self.output_format = output_format;
        self.duration_us = if (format_context.duration > 0) format_context.duration else 0;
        self.resetReadState();
    }

    /// Close the current stream while retaining reusable packet and frame storage.
    pub fn close(self: *Decoder) void {
        c.av_frame_unref(self.frame);
        c.av_packet_unref(self.packet);
        freeResampler(self.resampler_context);
        freeCodec(self.codec_context);
        closeFormat(self.format_context);
        if (self.path) |path| self.gpa.free(path);
        self.path = null;
        self.format_context = null;
        self.codec_context = null;
        self.resampler_context = null;
        self.audio_stream_index = null;
        self.output_format = null;
        self.duration_us = 0;
        self.resetReadState();
    }

    fn openResources(self: *const Decoder) ?OpenResources {
        if (self.path == null) return null;
        const format_context = self.format_context orelse return null;
        const codec_context = self.codec_context orelse return null;
        const resampler_context = self.resampler_context orelse return null;
        const audio_stream_index = self.audio_stream_index orelse return null;
        const output_format = self.output_format orelse return null;
        return .{
            .format_context = format_context,
            .codec_context = codec_context,
            .resampler_context = resampler_context,
            .audio_stream_index = audio_stream_index,
            .output_format = output_format,
        };
    }

    pub fn isOpen(self: *const Decoder) bool {
        return self.openResources() != null;
    }

    /// Seek the demuxer and reset every buffered decode stage.
    pub fn seek(self: *Decoder, position_sec: f32) SeekError!void {
        const resources = self.openResources() orelse return error.NotOpen;
        const target_us = seekTimestampUs(position_sec, self.duration_us) orelse
            return error.InvalidSeekPosition;
        const seek_result = c.avformat_seek_file(
            resources.format_context,
            -1,
            std.math.minInt(i64),
            target_us,
            std.math.maxInt(i64),
            0,
        );
        if (seek_result < 0) return error.SeekFailed;

        c.avcodec_flush_buffers(resources.codec_context);
        c.av_frame_unref(self.frame);
        c.av_packet_unref(self.packet);
        c.swr_close(resources.resampler_context);
        if (c.swr_init(resources.resampler_context) < 0) {
            self.close();
            return error.ResamplerResetFailed;
        }
        self.resetReadState();
    }

    /// Return the next borrowed PCM chunk or an explicit end-of-stream marker.
    pub fn read(self: *Decoder) DecodeError!DecodeResult {
        self.pcm_sample_count = 0;
        const resources = self.openResources() orelse return error.NotOpen;

        while (true) {
            if (self.resampler_buffered) {
                if (try self.drainReadySamples(
                    resources.resampler_context,
                    resources.output_format,
                )) |chunk| return .{ .pcm = chunk };
            }

            if (self.codec_eof) {
                if (try self.flushResampler(
                    resources.resampler_context,
                    resources.output_format,
                )) |chunk| return .{ .pcm = chunk };
                return .end_of_stream;
            }

            const receive_result = c.avcodec_receive_frame(
                resources.codec_context,
                self.frame,
            );
            if (receive_result == 0) {
                if (try self.convertFrame(
                    resources.resampler_context,
                    resources.output_format,
                )) |chunk| return .{ .pcm = chunk };
                continue;
            }
            if (receive_result == c.AVERROR_EOF) {
                self.codec_eof = true;
                continue;
            }
            if (isAgain(receive_result)) {
                if (self.flush_sent) return error.DecoderProtocolFailed;
                try self.sendInput(
                    resources.format_context,
                    resources.codec_context,
                    resources.audio_stream_index,
                );
                continue;
            }
            return error.FrameReceiveFailed;
        }
    }

    fn resetReadState(self: *Decoder) void {
        self.pcm_sample_count = 0;
        self.packet_pending = false;
        self.demux_eof = false;
        self.flush_sent = false;
        self.codec_eof = false;
        self.resampler_buffered = false;
        self.resampler_eof = false;
    }

    fn sendInput(
        self: *Decoder,
        format_context: *c.AVFormatContext,
        codec_context: *c.AVCodecContext,
        audio_stream_index: c_int,
    ) DecodeError!void {
        while (true) {
            if (self.packet_pending) {
                const send_result = c.avcodec_send_packet(
                    codec_context,
                    self.packet,
                );
                if (send_result == 0) {
                    c.av_packet_unref(self.packet);
                    self.packet_pending = false;
                    return;
                }
                if (isAgain(send_result)) return;
                return error.PacketSendFailed;
            }

            if (self.demux_eof) {
                const send_result = c.avcodec_send_packet(
                    codec_context,
                    null,
                );
                if (send_result == 0 or send_result == c.AVERROR_EOF) {
                    self.flush_sent = true;
                    return;
                }
                if (isAgain(send_result)) return;
                return error.PacketSendFailed;
            }

            const read_result = c.av_read_frame(
                format_context,
                self.packet,
            );
            if (read_result == c.AVERROR_EOF) {
                self.demux_eof = true;
                continue;
            }
            if (read_result < 0) return error.DemuxReadFailed;

            if (self.packet.stream_index != audio_stream_index) {
                c.av_packet_unref(self.packet);
                continue;
            }
            self.packet_pending = true;
        }
    }

    fn convertFrame(
        self: *Decoder,
        resampler_context: *c.SwrContext,
        output_format: OutputFormat,
    ) DecodeError!?PcmChunk {
        defer c.av_frame_unref(self.frame);
        if (self.frame.nb_samples <= 0) return error.InvalidFrame;
        if (self.frame.extended_data == null) return error.InvalidFrame;

        var output_planes = [_][*c]u8{
            @ptrCast(self.pcm[0..].ptr),
        };
        const frame_count = c.swr_convert(
            resampler_context,
            @ptrCast(&output_planes),
            @as(c_int, @intCast(pcm_frame_capacity)),
            @ptrCast(self.frame.extended_data),
            self.frame.nb_samples,
        );
        if (frame_count < 0) return error.ResampleFailed;
        self.resampler_buffered =
            frame_count == @as(c_int, @intCast(pcm_frame_capacity));
        if (frame_count == 0) return null;
        const chunk: ?PcmChunk = try self.pcmChunk(frame_count, output_format);
        return chunk;
    }

    /// Retrieve buffered samples without signaling end-of-input to swresample.
    fn drainReadySamples(
        self: *Decoder,
        resampler_context: *c.SwrContext,
        output_format: OutputFormat,
    ) DecodeError!?PcmChunk {
        var unused_byte: u8 = 0;
        var empty_input_planes = [_][*c]const u8{&unused_byte};
        var output_planes = [_][*c]u8{
            @ptrCast(self.pcm[0..].ptr),
        };
        const frame_count = c.swr_convert(
            resampler_context,
            @ptrCast(&output_planes),
            @as(c_int, @intCast(pcm_frame_capacity)),
            @ptrCast(&empty_input_planes),
            0,
        );
        if (frame_count < 0) return error.ResampleFailed;
        self.resampler_buffered =
            frame_count == @as(c_int, @intCast(pcm_frame_capacity));
        if (frame_count == 0) return null;
        const chunk: ?PcmChunk = try self.pcmChunk(frame_count, output_format);
        return chunk;
    }

    fn flushResampler(
        self: *Decoder,
        resampler_context: *c.SwrContext,
        output_format: OutputFormat,
    ) DecodeError!?PcmChunk {
        if (self.resampler_eof) return null;

        var output_planes = [_][*c]u8{
            @ptrCast(self.pcm[0..].ptr),
        };
        const frame_count = c.swr_convert(
            resampler_context,
            @ptrCast(&output_planes),
            @as(c_int, @intCast(pcm_frame_capacity)),
            null,
            0,
        );
        if (frame_count < 0) return error.ResampleFailed;
        if (frame_count == 0) {
            self.resampler_eof = true;
            return null;
        }
        const chunk: ?PcmChunk = try self.pcmChunk(frame_count, output_format);
        return chunk;
    }

    fn pcmChunk(
        self: *Decoder,
        frame_count_c: c_int,
        output_format: OutputFormat,
    ) DecodeError!PcmChunk {
        if (frame_count_c <= 0) return error.InvalidFrame;
        const frame_count: u32 = @intCast(frame_count_c);
        const sample_count = interleavedSampleCount(
            frame_count,
            output_format,
        ) catch return error.OutputCapacityExceeded;
        self.pcm_sample_count = sample_count;
        return .{
            .samples_interleaved = self.pcm[0..sample_count],
            .frame_count = frame_count,
            .format = output_format,
        };
    }
};

const ParsedTrackFilename = struct {
    artist: ?[]const u8,
    title: []const u8,
};

const ParsedParentDirectory = struct {
    album: []const u8,
    artist: ?[]const u8,
};

fn parseTrackFilename(basename: []const u8) ParsedTrackFilename {
    const extension = std.fs.path.extension(basename);
    const title_without_extension = basename[0 .. basename.len - extension.len];
    const stem = stripTrackPrefix(title_without_extension);
    const delimiter = " - ";

    if (std.mem.find(u8, stem, delimiter)) |delimiter_index| {
        return .{
            .artist = if (delimiter_index == 0) null else stem[0..delimiter_index],
            .title = stem[delimiter_index + delimiter.len ..],
        };
    }

    return .{
        .artist = null,
        .title = stem,
    };
}

fn stripTrackPrefix(stem: []const u8) []const u8 {
    var digit_end: usize = 0;
    while (digit_end < stem.len and std.ascii.isDigit(stem[digit_end])) : (digit_end += 1) {}

    if (digit_end == 0 or digit_end >= stem.len or stem[digit_end] != '.') {
        return stem;
    }

    var content_start = digit_end + 1;
    while (content_start < stem.len and std.ascii.isWhitespace(stem[content_start])) : (content_start += 1) {}
    if (content_start == digit_end + 1) return stem;
    return stem[content_start..];
}

fn parseParentDirectory(parent_name: []const u8) ParsedParentDirectory {
    const delimiter = " - ";
    if (std.mem.find(u8, parent_name, delimiter)) |delimiter_index| {
        const artist_start = delimiter_index + delimiter.len;
        return .{
            .album = parent_name[0..delimiter_index],
            .artist = if (artist_start == parent_name.len) null else parent_name[artist_start..],
        };
    }

    return .{
        .album = parent_name,
        .artist = null,
    };
}

fn selectMetadataValue(
    primary: ?[]const u8,
    secondary: ?[]const u8,
    fallback: []const u8,
) []const u8 {
    if (primary) |value| {
        if (value.len > 0) return value;
    }
    if (secondary) |value| {
        if (value.len > 0) return value;
    }
    return fallback;
}

fn artworkPacketIsValid(packet_size: usize, width: u32, height: u32) bool {
    if (packet_size == 0 or packet_size > max_artwork_bytes) return false;
    if (width == 0 or width > max_artwork_width) return false;
    if (height == 0 or height > max_artwork_height) return false;
    const pixel_count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return false;
    return pixel_count <= max_artwork_pixels;
}

fn copyArtworkBytes(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    width: u32,
    height: u32,
    codec_id: c_int,
) std.mem.Allocator.Error!Artwork {
    std.debug.assert(artworkPacketIsValid(bytes.len, width, height));
    return .{
        .bytes = try gpa.dupe(u8, bytes),
        .width = width,
        .height = height,
        .codec_id = codec_id,
    };
}

const ArtworkDimensions = struct {
    width: u32,
    height: u32,
};

fn artworkCodecIdForMime(mime: []const u8) ?c_int {
    if (std.ascii.eqlIgnoreCase(mime, "image/png")) {
        return @intCast(c.AV_CODEC_ID_PNG);
    }
    if (std.ascii.eqlIgnoreCase(mime, "image/jpeg")) {
        return @intCast(c.AV_CODEC_ID_MJPEG);
    }
    if (std.ascii.eqlIgnoreCase(mime, "image/jpg")) {
        return @intCast(c.AV_CODEC_ID_MJPEG);
    }
    if (std.ascii.eqlIgnoreCase(mime, "image/gif")) {
        return @intCast(c.AV_CODEC_ID_GIF);
    }
    if (std.ascii.eqlIgnoreCase(mime, "image/webp")) {
        return @intCast(c.AV_CODEC_ID_WEBP);
    }
    return null;
}

fn artworkDimensionsAreValid(width: u32, height: u32) bool {
    if (width == 0 or width > max_artwork_width) return false;
    if (height == 0 or height > max_artwork_height) return false;
    const pixel_count = std.math.mul(
        usize,
        @as(usize, width),
        @as(usize, height),
    ) catch return false;
    return pixel_count <= max_artwork_pixels;
}

fn readBigEndianU16(bytes: []const u8, offset: *usize) ?u16 {
    if (offset.* > bytes.len or bytes.len - offset.* < 2) return null;
    const value = (@as(u16, bytes[offset.*]) << 8) | @as(u16, bytes[offset.* + 1]);
    offset.* += 2;
    return value;
}

fn readBigEndianU32(bytes: []const u8, offset: *usize) ?u32 {
    if (offset.* > bytes.len or bytes.len - offset.* < 4) return null;
    const value = (@as(u32, bytes[offset.*]) << 24) |
        (@as(u32, bytes[offset.* + 1]) << 16) |
        (@as(u32, bytes[offset.* + 2]) << 8) |
        @as(u32, bytes[offset.* + 3]);
    offset.* += 4;
    return value;
}

fn readLittleEndianU16(bytes: []const u8, offset: *usize) ?u16 {
    if (offset.* > bytes.len or bytes.len - offset.* < 2) return null;
    const value = @as(u16, bytes[offset.*]) | (@as(u16, bytes[offset.* + 1]) << 8);
    offset.* += 2;
    return value;
}

fn readPictureBlockField(
    bytes: []const u8,
    offset: *usize,
    field_length: u32,
) ?[]const u8 {
    const length: usize = @intCast(field_length);
    if (offset.* > bytes.len or length > bytes.len - offset.*) return null;
    const field = bytes[offset.*..][0..length];
    offset.* += length;
    return field;
}

fn parsePngDimensions(bytes: []const u8) ?ArtworkDimensions {
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a })) {
        return null;
    }
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;

    var offset: usize = 8;
    const ihdr_length = readBigEndianU32(bytes, &offset) orelse return null;
    if (ihdr_length < 13 or ihdr_length > bytes.len - 16) return null;
    offset = 16;
    const width = readBigEndianU32(bytes, &offset) orelse return null;
    const height = readBigEndianU32(bytes, &offset) orelse return null;
    if (!artworkDimensionsAreValid(width, height)) return null;
    return .{ .width = width, .height = height };
}

fn jpegMarkerIsStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xc0...0xc3,
        0xc5...0xc7,
        0xc9...0xcb,
        0xcd...0xcf,
        => true,
        else => false,
    };
}

fn parseJpegDimensions(bytes: []const u8) ?ArtworkDimensions {
    if (bytes.len < 4 or bytes[0] != 0xff or bytes[1] != 0xd8) return null;

    var offset: usize = 2;
    while (offset < bytes.len) {
        if (bytes[offset] != 0xff) return null;
        while (offset < bytes.len and bytes[offset] == 0xff) : (offset += 1) {}
        if (offset >= bytes.len) return null;
        const marker = bytes[offset];
        offset += 1;

        if (marker == 0xd9 or marker == 0xda) return null;
        if (marker == 0xd8 or marker == 0x01 or marker >= 0xd0 and marker <= 0xd7) {
            continue;
        }

        const segment_length = readBigEndianU16(bytes, &offset) orelse return null;
        if (segment_length < 2 or segment_length - 2 > bytes.len - offset) return null;
        if (jpegMarkerIsStartOfFrame(marker)) {
            if (segment_length < 7) return null;
            const precision_offset = offset;
            _ = bytes[precision_offset];
            var dimension_offset = precision_offset + 1;
            const height = readBigEndianU16(bytes, &dimension_offset) orelse return null;
            const width = readBigEndianU16(bytes, &dimension_offset) orelse return null;
            if (!artworkDimensionsAreValid(width, height)) return null;
            return .{ .width = width, .height = height };
        }
        offset += segment_length - 2;
    }
    return null;
}

fn parseGifDimensions(bytes: []const u8) ?ArtworkDimensions {
    if (bytes.len < 10) return null;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and
        !std.mem.eql(u8, bytes[0..6], "GIF89a"))
    {
        return null;
    }
    var offset: usize = 6;
    const width = readLittleEndianU16(bytes, &offset) orelse return null;
    const height = readLittleEndianU16(bytes, &offset) orelse return null;
    if (!artworkDimensionsAreValid(width, height)) return null;
    return .{ .width = width, .height = height };
}

fn parseWebpDimensions(bytes: []const u8) ?ArtworkDimensions {
    if (bytes.len < 30) return null;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, bytes[8..12], "WEBP")) return null;
    if (!std.mem.eql(u8, bytes[12..16], "VP8X")) return null;
    if (bytes[16] != 10 or bytes[17] != 0 or bytes[18] != 0 or bytes[19] != 0) {
        return null;
    }

    const width = 1 + (@as(u32, bytes[24]) |
        (@as(u32, bytes[25]) << 8) |
        (@as(u32, bytes[26]) << 16));
    const height = 1 + (@as(u32, bytes[27]) |
        (@as(u32, bytes[28]) << 8) |
        (@as(u32, bytes[29]) << 16));
    if (!artworkDimensionsAreValid(width, height)) return null;
    return .{ .width = width, .height = height };
}

fn artworkDimensionsForMime(
    bytes: []const u8,
    mime: []const u8,
) ?ArtworkDimensions {
    if (std.ascii.eqlIgnoreCase(mime, "image/png")) return parsePngDimensions(bytes);
    if (std.ascii.eqlIgnoreCase(mime, "image/jpeg")) return parseJpegDimensions(bytes);
    if (std.ascii.eqlIgnoreCase(mime, "image/jpg")) return parseJpegDimensions(bytes);
    if (std.ascii.eqlIgnoreCase(mime, "image/gif")) return parseGifDimensions(bytes);
    if (std.ascii.eqlIgnoreCase(mime, "image/webp")) return parseWebpDimensions(bytes);
    return null;
}

fn compactArtworkBytes(
    gpa: std.mem.Allocator,
    decoded: []u8,
    image_start: usize,
    image_length: usize,
) std.mem.Allocator.Error![]u8 {
    if (image_start > 0) {
        @memmove(
            decoded[0..image_length],
            decoded[image_start..][0..image_length],
        );
    }
    if (image_length == decoded.len) return decoded;
    if (gpa.resize(decoded, image_length)) return decoded[0..image_length];
    return gpa.realloc(decoded, image_length);
}

fn decodeMetadataBase64(
    gpa: std.mem.Allocator,
    encoded: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    if (encoded.len == 0 or encoded.len > max_artwork_base64_bytes) return null;
    const decoded_length = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
    if (decoded_length == 0 or decoded_length > max_artwork_bytes) return null;

    const decoded = try gpa.alloc(u8, decoded_length);
    errdefer gpa.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return null;
    return decoded;
}

fn parseMetadataPictureBlock(
    gpa: std.mem.Allocator,
    decoded: []u8,
) std.mem.Allocator.Error!?Artwork {
    var offset: usize = 0;
    const picture_type = readBigEndianU32(decoded, &offset) orelse return null;
    if (picture_type != 3) return null;

    const mime_length = readBigEndianU32(decoded, &offset) orelse return null;
    const mime = readPictureBlockField(decoded, &offset, mime_length) orelse return null;
    const codec_id = artworkCodecIdForMime(mime) orelse return null;

    const description_length = readBigEndianU32(decoded, &offset) orelse return null;
    _ = readPictureBlockField(decoded, &offset, description_length) orelse return null;

    const width = readBigEndianU32(decoded, &offset) orelse return null;
    const height = readBigEndianU32(decoded, &offset) orelse return null;
    _ = readBigEndianU32(decoded, &offset) orelse return null;
    _ = readBigEndianU32(decoded, &offset) orelse return null;
    const image_length_u32 = readBigEndianU32(decoded, &offset) orelse return null;
    const image_length: usize = @intCast(image_length_u32);
    if (!artworkPacketIsValid(image_length, width, height)) return null;
    const image_start = offset;
    _ = readPictureBlockField(decoded, &offset, image_length_u32) orelse return null;
    if (offset != decoded.len) return null;

    const image_bytes = try compactArtworkBytes(gpa, decoded, image_start, image_length);
    return .{
        .bytes = image_bytes,
        .width = width,
        .height = height,
        .codec_id = codec_id,
    };
}

fn extractMetadataPictureValue(
    gpa: std.mem.Allocator,
    encoded: []const u8,
) std.mem.Allocator.Error!?Artwork {
    const decoded = (try decodeMetadataBase64(gpa, encoded)) orelse return null;
    const artwork = parseMetadataPictureBlock(gpa, decoded) catch |err| {
        gpa.free(decoded);
        return err;
    };
    if (artwork) |value| return value;
    gpa.free(decoded);
    return null;
}

fn extractConventionalCoverArt(
    gpa: std.mem.Allocator,
    encoded: []const u8,
    mime: []const u8,
) std.mem.Allocator.Error!?Artwork {
    const codec_id = artworkCodecIdForMime(mime) orelse return null;
    const decoded = (try decodeMetadataBase64(gpa, encoded)) orelse return null;
    const dimensions = artworkDimensionsForMime(decoded, mime) orelse {
        gpa.free(decoded);
        return null;
    };
    if (!artworkPacketIsValid(decoded.len, dimensions.width, dimensions.height)) {
        gpa.free(decoded);
        return null;
    }
    const image_bytes = compactArtworkBytes(gpa, decoded, 0, decoded.len) catch |err| {
        gpa.free(decoded);
        return err;
    };
    return .{
        .bytes = image_bytes,
        .width = dimensions.width,
        .height = dimensions.height,
        .codec_id = codec_id,
    };
}

fn extractAttachedArtwork(
    gpa: std.mem.Allocator,
    format_context: *c.AVFormatContext,
) std.mem.Allocator.Error!?Artwork {
    const stream_count: usize = @intCast(format_context.nb_streams);
    for (0..stream_count) |stream_index| {
        const stream = format_context.streams[stream_index];
        if ((stream.*.disposition & c.AV_DISPOSITION_ATTACHED_PIC) == 0) continue;
        const codec_parameters = stream.*.codecpar orelse continue;
        const packet = &stream.*.attached_pic;
        if (packet.*.data == null or packet.*.size <= 0) continue;

        const packet_size: usize = @intCast(packet.*.size);
        const width: u32 = if (codec_parameters.*.width > 0)
            @intCast(codec_parameters.*.width)
        else
            0;
        const height: u32 = if (codec_parameters.*.height > 0)
            @intCast(codec_parameters.*.height)
        else
            0;
        if (!artworkPacketIsValid(packet_size, width, height)) continue;

        const bytes: []const u8 =
            @as([*]const u8, @ptrCast(packet.*.data))[0..packet_size];
        const codec_id: c_int = @intCast(codec_parameters.*.codec_id);
        const copied_artwork = try copyArtworkBytes(gpa, bytes, width, height, codec_id);
        return copied_artwork;
    }
    return null;
}
/// Decode one bounded attached-picture packet into allocator-owned RGBA8
/// pixels. The caller owns the returned pixels and may upload them once.
pub fn decodeArtwork(
    gpa: std.mem.Allocator,
    artwork: Artwork,
) ArtworkDecodeError!DecodedArtwork {
    if (!artworkPacketIsValid(artwork.bytes.len, artwork.width, artwork.height)) {
        return error.InvalidArtwork;
    }
    if (artwork.codec_id < 0) return error.InvalidArtwork;

    const codec = c.avcodec_find_decoder(@intCast(artwork.codec_id)) orelse
        return error.DecoderNotFound;
    const codec_context = c.avcodec_alloc_context3(codec) orelse
        return error.CodecAllocationFailed;
    defer freeCodec(codec_context);
    if (c.avcodec_open2(codec_context, codec, null) < 0) return error.CodecOpenFailed;

    const packet = c.av_packet_alloc() orelse return error.PacketAllocationFailed;
    defer freePacket(packet);
    if (c.av_new_packet(packet, @intCast(artwork.bytes.len)) < 0) {
        return error.PacketUploadFailed;
    }
    @memcpy(
        @as([*]u8, @ptrCast(packet.*.data))[0..artwork.bytes.len],
        artwork.bytes,
    );

    const frame = c.av_frame_alloc() orelse return error.FrameAllocationFailed;
    defer freeFrame(frame);
    if (c.avcodec_send_packet(codec_context, packet) < 0) {
        return error.FrameDecodeFailed;
    }

    var receive_result = c.avcodec_receive_frame(codec_context, frame);
    if (isAgain(receive_result)) {
        if (c.avcodec_send_packet(codec_context, null) < 0) {
            return error.FrameDecodeFailed;
        }
        receive_result = c.avcodec_receive_frame(codec_context, frame);
    }
    if (receive_result < 0) return error.FrameDecodeFailed;

    if (frame.*.width <= 0 or frame.*.height <= 0) return error.InvalidArtwork;
    const width: u32 = @intCast(frame.*.width);
    const height: u32 = @intCast(frame.*.height);
    if (!artworkPacketIsValid(artwork.bytes.len, width, height)) {
        return error.InvalidArtwork;
    }
    const pixel_count = std.math.mul(
        usize,
        @as(usize, width),
        @as(usize, height),
    ) catch return error.ImageAllocationFailed;
    const pixel_bytes = std.math.mul(usize, pixel_count, 4) catch
        return error.ImageAllocationFailed;
    const pixels = try gpa.alloc(u8, pixel_bytes);
    errdefer gpa.free(pixels);

    const scaler = c.sws_getContext(
        frame.*.width,
        frame.*.height,
        frame.*.format,
        frame.*.width,
        frame.*.height,
        c.AV_PIX_FMT_RGBA,
        c.SWS_BILINEAR,
        null,
        null,
        null,
    ) orelse return error.ImageConversionFailed;
    defer c.sws_freeContext(scaler);

    var destination_data = [_][*c]u8{
        @ptrCast(pixels.ptr),
        null,
        null,
        null,
    };
    var destination_linesize = [_]c_int{
        @intCast(@as(usize, width) * 4),
        0,
        0,
        0,
    };
    const source_data: [*c]const [*c]const u8 = @ptrCast(&frame.*.data);
    const source_linesize: [*c]const c_int = @ptrCast(&frame.*.linesize);
    const destination: [*c]const [*c]u8 = @ptrCast(&destination_data);
    const destination_stride: [*c]const c_int = @ptrCast(&destination_linesize);
    const scaled_height = c.sws_scale(
        scaler,
        source_data,
        source_linesize,
        0,
        frame.*.height,
        destination,
        destination_stride,
    );
    if (scaled_height != frame.*.height) return error.ImageConversionFailed;

    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
    };
}

/// Probe and copy tags without retaining any FFmpeg resources.
///
/// Embedded tags win over the filename and parent directory fallbacks. A file
/// with no usable audio stream is not an error: it simply carries no
/// stream-level tags, so the fallbacks fill every field.
pub fn probeMetadata(
    gpa: std.mem.Allocator,
    path: []const u8,
) ProbeError!Metadata {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    var format_context_optional: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(
        &format_context_optional,
        path_z.ptr,
        null,
        null,
    ) < 0) {
        return error.OpenInputFailed;
    }
    defer closeFormat(format_context_optional);

    const format_context = format_context_optional orelse return error.OpenInputFailed;
    if (c.avformat_find_stream_info(format_context, null) < 0) {
        return error.StreamInfoFailed;
    }

    const stream_index = c.av_find_best_stream(
        format_context,
        c.AVMEDIA_TYPE_AUDIO,
        -1,
        -1,
        null,
        0,
    );
    // A file with no usable audio stream has no stream-level tags to read. The
    // probe reports the metadata it can see and lets the filename fallbacks
    // cover the gaps instead of failing the caller.
    const stream_metadata: ?*const c.AVDictionary =
        if (stream_index < 0) null else format_context.streams[@intCast(stream_index)].*.metadata;

    var artwork = try extractAttachedArtwork(gpa, format_context);
    errdefer if (artwork) |*value| value.deinit(gpa);
    if (artwork == null) {
        artwork = try extractMetadataArtwork(
            gpa,
            format_context.metadata,
            stream_metadata,
        );
    }

    const basename = std.fs.path.basename(path);
    const parsed_filename = parseTrackFilename(basename);
    const fallback_title =
        if (parsed_filename.title.len == 0) "Untitled" else parsed_filename.title;

    const parent_path = std.fs.path.dirname(path) orelse "";
    const parent_name = std.fs.path.basename(parent_path);
    const parsed_parent = parseParentDirectory(parent_name);
    const fallback_album =
        if (parsed_parent.album.len == 0) "Unknown Album" else parsed_parent.album;
    const fallback_artist =
        parsed_filename.artist orelse parsed_parent.artist orelse "Unknown Artist";

    const title = try dupeTag(
        gpa,
        format_context.metadata,
        stream_metadata,
        "title",
        fallback_title,
    );
    errdefer gpa.free(title);
    const artist = try dupeArtist(
        gpa,
        format_context.metadata,
        stream_metadata,
        fallback_artist,
    );
    errdefer gpa.free(artist);
    const album = try dupeTag(
        gpa,
        format_context.metadata,
        stream_metadata,
        "album",
        fallback_album,
    );
    errdefer gpa.free(album);

    const duration_sec = durationSeconds(format_context.duration);
    const duration_str = try std.fmt.allocPrint(
        gpa,
        "{d}:{d:0>2}",
        .{ duration_sec / 60, duration_sec % 60 },
    );

    return .{
        .title = title,
        .artist = artist,
        .album = album,
        .duration_str = duration_str,
        .duration_sec = duration_sec,
        .artwork = artwork,
    };
}

fn dupeTag(
    gpa: std.mem.Allocator,
    format_metadata: ?*const c.AVDictionary,
    stream_metadata: ?*const c.AVDictionary,
    key: [*:0]const u8,
    fallback: []const u8,
) std.mem.Allocator.Error![]u8 {
    const value = selectMetadataValue(
        metadataValue(format_metadata, key),
        metadataValue(stream_metadata, key),
        fallback,
    );
    return gpa.dupe(u8, value);
}

fn dupeArtist(
    gpa: std.mem.Allocator,
    format_metadata: ?*const c.AVDictionary,
    stream_metadata: ?*const c.AVDictionary,
    fallback: []const u8,
) std.mem.Allocator.Error![]u8 {
    const artist_keys = [_][*:0]const u8{ "artist", "album_artist", "performer" };
    const value = metadataValueForKeys(
        format_metadata,
        stream_metadata,
        artist_keys[0..],
    ) orelse fallback;
    return gpa.dupe(u8, value);
}

fn metadataValueForKeys(
    format_metadata: ?*const c.AVDictionary,
    stream_metadata: ?*const c.AVDictionary,
    keys: []const [*:0]const u8,
) ?[]const u8 {
    for (keys) |key| {
        if (metadataValue(format_metadata, key)) |value| return value;
        if (metadataValue(stream_metadata, key)) |value| return value;
    }
    return null;
}

fn metadataValue(
    metadata: ?*const c.AVDictionary,
    key: [*:0]const u8,
) ?[]const u8 {
    const entry = c.av_dict_get(metadata, key, null, 0) orelse return null;
    if (entry.*.value == null) return null;
    const value = std.mem.span(@as([*:0]const u8, @ptrCast(entry.*.value)));
    if (value.len == 0) return null;
    return value;
}

fn extractMetadataArtwork(
    gpa: std.mem.Allocator,
    format_metadata: ?*const c.AVDictionary,
    stream_metadata: ?*const c.AVDictionary,
) std.mem.Allocator.Error!?Artwork {
    const dictionaries = [_]?*const c.AVDictionary{
        format_metadata,
        stream_metadata,
    };

    for (dictionaries) |metadata| {
        const encoded = metadataValue(metadata, "METADATA_BLOCK_PICTURE") orelse continue;
        if (try extractMetadataPictureValue(gpa, encoded)) |artwork| return artwork;
    }
    for (dictionaries) |metadata| {
        const encoded = metadataValue(metadata, "COVERART") orelse continue;
        const mime = metadataValue(metadata, "COVERARTMIME") orelse continue;
        if (try extractConventionalCoverArt(gpa, encoded, mime)) |artwork| return artwork;
    }
    return null;
}

fn durationSeconds(duration_us: i64) u32 {
    if (duration_us <= 0) return 0;
    const seconds = @divTrunc(duration_us, @as(i64, c.AV_TIME_BASE));
    if (seconds >= std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(seconds);
}

fn seekTimestampUs(position_sec: f32, duration_us: i64) ?i64 {
    if (!std.math.isFinite(position_sec)) return null;

    const requested_us = @as(f64, @floatCast(position_sec)) *
        @as(f64, @floatFromInt(c.AV_TIME_BASE));
    const max_safe_us = std.math.maxInt(i64) - 1024;
    const bounded_us = @min(
        @max(requested_us, 0.0),
        @as(f64, @floatFromInt(max_safe_us)),
    );
    var target_us: i64 = @intFromFloat(bounded_us);
    if (duration_us > 0) target_us = @min(target_us, duration_us);
    return target_us;
}

fn isAgain(result: c_int) bool {
    return result == c.AVERROR(c.EAGAIN);
}

fn freeResampler(context: ?*c.SwrContext) void {
    var owned = context;
    if (owned != null) c.swr_free(&owned);
}

fn freeFrame(frame: *c.AVFrame) void {
    var owned: ?*c.AVFrame = frame;
    c.av_frame_free(&owned);
}

fn freePacket(packet: *c.AVPacket) void {
    var owned: ?*c.AVPacket = packet;
    c.av_packet_free(&owned);
}

fn freeCodec(context: ?*c.AVCodecContext) void {
    var owned = context;
    if (owned != null) c.avcodec_free_context(&owned);
}

fn closeFormat(context: ?*c.AVFormatContext) void {
    var owned = context;
    if (owned != null) c.avformat_close_input(&owned);
}

test "track filename fallback strips prefix and preserves title" {
    const parsed = parseTrackFilename("01. System Of A Down - Hypnotize.opus");
    try std.testing.expectEqualStrings("System Of A Down", parsed.artist.?);
    try std.testing.expectEqualStrings("Hypnotize", parsed.title);
}

test "track filename fallback accepts an unnumbered artist title" {
    const parsed = parseTrackFilename("System Of A Down - Hypnotize.opus");
    try std.testing.expectEqualStrings("System Of A Down", parsed.artist.?);
    try std.testing.expectEqualStrings("Hypnotize", parsed.title);
}

test "track filename fallback keeps a filename without delimiter as title" {
    const parsed = parseTrackFilename("Hypnotize.opus");
    try std.testing.expect(parsed.artist == null);
    try std.testing.expectEqualStrings("Hypnotize", parsed.title);
}

test "track filename fallback splits only the first delimiter" {
    const parsed = parseTrackFilename("01. System Of A Down - Hypnotize - Live.opus");
    try std.testing.expectEqualStrings("System Of A Down", parsed.artist.?);
    try std.testing.expectEqualStrings("Hypnotize - Live", parsed.title);
}

test "parent directory fallback splits album and artist suffix" {
    const parsed = parseParentDirectory("Hypnotize - System Of A Down");
    try std.testing.expectEqualStrings("Hypnotize", parsed.album);
    try std.testing.expectEqualStrings("System Of A Down", parsed.artist.?);
}

test "embedded metadata value wins over parsed fallback" {
    try std.testing.expectEqualStrings(
        "Tagged title",
        selectMetadataValue("Tagged title", "Parsed title", "Untitled"),
    );
    try std.testing.expectEqualStrings(
        "Parsed title",
        selectMetadataValue("", "Parsed title", "Untitled"),
    );
}

test "embedded title tag takes precedence over parsed fallback" {
    var metadata: ?*c.AVDictionary = null;
    defer c.av_dict_free(&metadata);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "title", "Tagged title", 0),
    );

    const title = try dupeTag(
        std.testing.allocator,
        metadata,
        null,
        "title",
        "Parsed title",
    );
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Tagged title", title);
}

test "album artist tag supplies missing artist metadata" {
    var metadata: ?*c.AVDictionary = null;
    defer c.av_dict_free(&metadata);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "album_artist", "Tagged Artist", 0),
    );

    const artist = try dupeArtist(
        std.testing.allocator,
        metadata,
        null,
        "Parsed Artist",
    );
    defer std.testing.allocator.free(artist);
    try std.testing.expectEqualStrings("Tagged Artist", artist);
}

test "format negotiation selects fixed playback format" {
    const output = try negotiateOutputFormat(.{
        .sample_rate_hz = 96_000,
        .channel_count = 6,
    });
    try std.testing.expectEqual(output_sample_rate_hz, output.sample_rate_hz);
    try std.testing.expectEqual(output_channel_count, output.channel_count);
}

test "format negotiation rejects missing source dimensions" {
    try std.testing.expectError(
        error.InvalidSampleRate,
        negotiateOutputFormat(.{ .sample_rate_hz = 0, .channel_count = 2 }),
    );
    try std.testing.expectError(
        error.InvalidChannelCount,
        negotiateOutputFormat(.{ .sample_rate_hz = 44_100, .channel_count = 0 }),
    );
}

test "interleaved sample count accepts the fixed boundary" {
    const format: OutputFormat = .{
        .sample_rate_hz = output_sample_rate_hz,
        .channel_count = output_channel_count,
    };
    try std.testing.expectEqual(
        pcm_sample_capacity,
        try interleavedSampleCount(pcm_frame_capacity, format),
    );
}

test "interleaved sample count rejects buffer overflow" {
    const format: OutputFormat = .{
        .sample_rate_hz = output_sample_rate_hz,
        .channel_count = output_channel_count,
    };
    try std.testing.expectError(
        error.OutputCapacityExceeded,
        interleavedSampleCount(pcm_frame_capacity + 1, format),
    );
}

test "seek timestamp clamps to decoder duration" {
    try std.testing.expectEqual(
        @as(?i64, 0),
        seekTimestampUs(-1.0, 120_000_000),
    );
    try std.testing.expectEqual(
        @as(?i64, 37_500_000),
        seekTimestampUs(37.5, 120_000_000),
    );
    try std.testing.expectEqual(
        @as(?i64, 120_000_000),
        seekTimestampUs(121.0, 120_000_000),
    );
}
test "artwork packet bounds accept safe limits" {
    try std.testing.expect(artworkPacketIsValid(
        max_artwork_bytes,
        max_artwork_width,
        max_artwork_height,
    ));
}

test "artwork packet bounds reject malformed and oversized input" {
    try std.testing.expect(!artworkPacketIsValid(0, 64, 64));
    try std.testing.expect(!artworkPacketIsValid(max_artwork_bytes + 1, 64, 64));
    try std.testing.expect(!artworkPacketIsValid(128, 0, 64));
    try std.testing.expect(!artworkPacketIsValid(128, 64, 0));
    try std.testing.expect(!artworkPacketIsValid(128, max_artwork_width + 1, 64));
    try std.testing.expect(!artworkPacketIsValid(128, 64, max_artwork_height + 1));
}

test "artwork bytes are copied into caller-owned storage" {
    const source = [_]u8{ 1, 2, 3, 4 };
    var artwork = try copyArtworkBytes(
        std.testing.allocator,
        source[0..],
        2,
        2,
        17,
    );
    defer artwork.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(&.{ 1, 2, 3, 4 }, artwork.bytes);
    try std.testing.expectEqual(@as(u32, 2), artwork.width);
    try std.testing.expectEqual(@as(u32, 2), artwork.height);
    try std.testing.expectEqual(@as(c_int, 17), artwork.codec_id);
}

test "attached picture metadata is copied from FFmpeg stream storage" {
    const format_context = c.avformat_alloc_context() orelse return error.OutOfMemory;
    defer c.avformat_free_context(format_context);

    const stream = c.avformat_new_stream(format_context, null) orelse return error.OutOfMemory;
    stream.*.disposition = c.AV_DISPOSITION_ATTACHED_PIC;
    stream.*.codecpar.*.width = 2;
    stream.*.codecpar.*.height = 2;
    stream.*.codecpar.*.codec_id = @intCast(c.AV_CODEC_ID_PNG);

    const packet = &stream.*.attached_pic;
    try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(packet, 4));
    defer c.av_packet_unref(packet);
    const source = [_]u8{ 9, 8, 7, 6 };
    @memcpy(@as([*]u8, @ptrCast(packet.*.data))[0..4], source[0..]);

    var artwork = (try extractAttachedArtwork(
        std.testing.allocator,
        format_context,
    )) orelse return error.TestUnexpectedResult;
    defer artwork.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(&.{ 9, 8, 7, 6 }, artwork.bytes);
    try std.testing.expectEqual(@as(u32, 2), artwork.width);
    try std.testing.expectEqual(@as(u32, 2), artwork.height);
}

test "decode artwork converts a bounded PNG packet" {
    const encoded =
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAACXBIWXMAAAABAAAAAQBPJcTWAAAAEElEQVR4nGP8y4AALAxEcQA0" ++
        "BwELeIS5cwAAAABJRU5ErkJggg==";
    const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const encoded_bytes = try std.testing.allocator.alloc(u8, decoded_size);
    defer std.testing.allocator.free(encoded_bytes);
    try std.base64.standard.Decoder.decode(encoded_bytes, encoded);

    var artwork = try copyArtworkBytes(
        std.testing.allocator,
        encoded_bytes,
        4,
        4,
        @intCast(c.AV_CODEC_ID_PNG),
    );
    defer artwork.deinit(std.testing.allocator);

    var decoded = try decodeArtwork(std.testing.allocator, artwork);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), decoded.width);
    try std.testing.expectEqual(@as(u32, 4), decoded.height);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), decoded.pixels.len);
}

test "decode artwork rejects an invalid codec id" {
    var source = [_]u8{1};
    const artwork: Artwork = .{
        .bytes = source[0..],
        .width = 1,
        .height = 1,
        .codec_id = -1,
    };
    try std.testing.expectError(
        error.InvalidArtwork,
        decodeArtwork(std.testing.allocator, artwork),
    );
}
test "metadata block picture dictionary yields front-cover artwork" {
    var picture_block: [45]u8 = undefined;
    writePictureBlockFixture(&picture_block, "image/png", 4, 4, &.{ 9, 8, 7, 6 });
    const encoded_length = std.base64.standard.Encoder.calcSize(picture_block.len);
    var encoded: [61]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(encoded[0..encoded_length], picture_block[0..]);
    encoded[encoded_length] = 0;

    var metadata: ?*c.AVDictionary = null;
    defer c.av_dict_free(&metadata);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "METADATA_BLOCK_PICTURE", @ptrCast(&encoded), 0),
    );

    var artwork = (try extractMetadataArtwork(
        std.testing.allocator,
        metadata,
        null,
    )) orelse return error.TestUnexpectedResult;
    defer artwork.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(&.{ 9, 8, 7, 6 }, artwork.bytes);
    try std.testing.expectEqual(@as(u32, 4), artwork.width);
    try std.testing.expectEqual(@as(u32, 4), artwork.height);
    try std.testing.expectEqual(@as(c_int, c.AV_CODEC_ID_PNG), artwork.codec_id);
}

test "conventional coverart dictionary yields image dimensions" {
    const encoded_image =
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAACXBIWXMAAAABAAAAAQBPJcTWAAAAEElEQVR4nGP8y4AALAxEcQA0" ++
        "BwELeIS5cwAAAABJRU5ErkJggg==";
    var metadata: ?*c.AVDictionary = null;
    defer c.av_dict_free(&metadata);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "COVERART", encoded_image, 0),
    );
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "COVERARTMIME", "image/png", 0),
    );

    var artwork = (try extractMetadataArtwork(
        std.testing.allocator,
        null,
        metadata,
    )) orelse return error.TestUnexpectedResult;
    defer artwork.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), artwork.width);
    try std.testing.expectEqual(@as(u32, 4), artwork.height);
    try std.testing.expectEqual(@as(c_int, c.AV_CODEC_ID_PNG), artwork.codec_id);
    try std.testing.expectEqual(@as(u8, 0x89), artwork.bytes[0]);
    try std.testing.expectEqualStrings("PNG", artwork.bytes[1..4]);
}

test "conventional jpeg coverart dimensions come from the image header" {
    const jpeg = [_]u8{
        0xff, 0xd8,
        0xff, 0xc0,
        0x00, 0x0b,
        0x08, 0x00,
        0x02, 0x00,
        0x03, 0x01,
        0x01, 0x11,
        0x00, 0xff,
        0xd9,
    };
    var encoded: [32]u8 = undefined;
    const encoded_length = std.base64.standard.Encoder.calcSize(jpeg.len);
    _ = std.base64.standard.Encoder.encode(encoded[0..encoded_length], jpeg[0..]);
    encoded[encoded_length] = 0;

    var metadata: ?*c.AVDictionary = null;
    defer c.av_dict_free(&metadata);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "COVERART", @ptrCast(&encoded), 0),
    );
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "COVERARTMIME", "image/jpeg", 0),
    );

    var artwork = (try extractMetadataArtwork(
        std.testing.allocator,
        metadata,
        null,
    )) orelse return error.TestUnexpectedResult;
    defer artwork.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), artwork.width);
    try std.testing.expectEqual(@as(u32, 2), artwork.height);
    try std.testing.expectEqual(@as(c_int, c.AV_CODEC_ID_MJPEG), artwork.codec_id);
}

test "metadata artwork rejects malformed picture blocks and dimensions" {
    var picture_block: [45]u8 = undefined;
    writePictureBlockFixture(&picture_block, "image/png", 4, 4, &.{ 9, 8, 7, 6 });
    picture_block[3] = 4;
    const encoded_length = std.base64.standard.Encoder.calcSize(picture_block.len);
    var encoded: [61]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(encoded[0..encoded_length], picture_block[0..]);
    encoded[encoded_length] = 0;

    var metadata: ?*c.AVDictionary = null;
    defer c.av_dict_free(&metadata);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "METADATA_BLOCK_PICTURE", @ptrCast(&encoded), 0),
    );
    try std.testing.expect((try extractMetadataArtwork(
        std.testing.allocator,
        metadata,
        null,
    )) == null);

    try std.testing.expectEqual(
        @as(c_int, 0),
        c.av_dict_set(&metadata, "METADATA_BLOCK_PICTURE", "not-base64", 0),
    );
    try std.testing.expect((try extractMetadataArtwork(
        std.testing.allocator,
        metadata,
        null,
    )) == null);
}

fn writePictureBlockFixture(
    output: []u8,
    mime: []const u8,
    width: u32,
    height: u32,
    image_bytes: []const u8,
) void {
    var offset: usize = 0;
    writeBigEndianU32(output, &offset, 3);
    writeBigEndianU32(output, &offset, @intCast(mime.len));
    @memcpy(output[offset..][0..mime.len], mime);
    offset += mime.len;
    writeBigEndianU32(output, &offset, 0);
    writeBigEndianU32(output, &offset, width);
    writeBigEndianU32(output, &offset, height);
    writeBigEndianU32(output, &offset, 24);
    writeBigEndianU32(output, &offset, 0);
    writeBigEndianU32(output, &offset, @intCast(image_bytes.len));
    @memcpy(output[offset..][0..image_bytes.len], image_bytes);
}

fn writeBigEndianU32(output: []u8, offset: *usize, value: u32) void {
    output[offset.* + 0] = @intCast((value >> 24) & 0xff);
    output[offset.* + 1] = @intCast((value >> 16) & 0xff);
    output[offset.* + 2] = @intCast((value >> 8) & 0xff);
    output[offset.* + 3] = @intCast(value & 0xff);
    offset.* += 4;
}
