//! Pure Zig D-Bus wire protocol codec and Unix socket client.
//! Implements D-Bus Specification version 0.38+ with zero external C dependencies.
const std = @import("std");

pub const MessageType = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
};

pub const HeaderField = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
};

pub const Flags = struct {
    pub const no_reply_expected: u8 = 0x01;
    pub const no_auto_start: u8 = 0x02;
    pub const allow_interactive_authorization: u8 = 0x04;
};

pub const Message = struct {
    msg_type: MessageType = .invalid,
    flags: u8 = 0,
    serial: u32 = 0,
    reply_serial: ?u32 = null,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    body: []const u8 = &.{},
    unix_fds: u32 = 0,
};

/// Pad a buffer to the given byte alignment.
pub fn padLen(len: usize, alignment: usize) usize {
    const rem = len % alignment;
    if (rem == 0) return 0;
    return alignment - rem;
}

pub const MessageBuilder = struct {
    allocator: std.mem.Allocator,
    msg_type: MessageType,
    flags: u8,
    serial: u32,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    unix_fds: u32 = 0,
    body: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, msg_type: MessageType, serial: u32) MessageBuilder {
        return .{
            .allocator = allocator,
            .msg_type = msg_type,
            .flags = 0,
            .serial = serial,
            .body = .empty,
        };
    }

    pub fn deinit(self: *MessageBuilder) void {
        self.body.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn padBody(self: *MessageBuilder, alignment: usize) !void {
        const pad = padLen(self.body.items.len, alignment);
        try self.body.appendNTimes(self.allocator, 0, pad);
    }

    pub fn writeByte(self: *MessageBuilder, val: u8) !void {
        try self.body.append(self.allocator, val);
    }

    pub fn writeBool(self: *MessageBuilder, val: bool) !void {
        try self.writeU32(if (val) 1 else 0);
    }

    pub fn writeI16(self: *MessageBuilder, val: i16) !void {
        try self.padBody(2);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, val, .little);
        try self.body.appendSlice(self.allocator, &bytes);
    }

    pub fn writeU16(self: *MessageBuilder, val: u16) !void {
        try self.padBody(2);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, val, .little);
        try self.body.appendSlice(self.allocator, &bytes);
    }

    pub fn writeI32(self: *MessageBuilder, val: i32) !void {
        try self.padBody(4);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, val, .little);
        try self.body.appendSlice(self.allocator, &bytes);
    }

    pub fn writeU32(self: *MessageBuilder, val: u32) !void {
        try self.padBody(4);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, val, .little);
        try self.body.appendSlice(self.allocator, &bytes);
    }

    pub fn writeI64(self: *MessageBuilder, val: i64) !void {
        try self.padBody(8);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, val, .little);
        try self.body.appendSlice(self.allocator, &bytes);
    }

    pub fn writeU64(self: *MessageBuilder, val: u64) !void {
        try self.padBody(8);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, val, .little);
        try self.body.appendSlice(self.allocator, &bytes);
    }

    pub fn writeString(self: *MessageBuilder, str: []const u8) !void {
        try self.padBody(4);
        const len_u32 = std.math.cast(u32, str.len) orelse return error.StringTooLong;
        try self.writeU32(len_u32);
        try self.body.appendSlice(self.allocator, str);
        try self.body.append(self.allocator, 0);
    }

    pub fn writeObjectPath(self: *MessageBuilder, path: []const u8) !void {
        try self.writeString(path);
    }

    pub fn writeSignature(self: *MessageBuilder, sig: []const u8) !void {
        const len_u8 = std.math.cast(u8, sig.len) orelse return error.SignatureTooLong;
        try self.writeByte(len_u8);
        try self.body.appendSlice(self.allocator, sig);
        try self.body.append(self.allocator, 0);
    }

    /// An open array: where its length field is, and where its first element
    /// starts. The D-Bus marshalling rules count the array's byte length from
    /// the FIRST ELEMENT, not from the end of the length field, so the padding
    /// that aligns the first element is outside the length. Carrying both
    /// offsets is what keeps `finishArray` from folding that padding in.
    pub const ArrayFrame = struct {
        len_offset: usize,
        payload_start: usize,
    };

    pub fn startArray(self: *MessageBuilder, elem_align: usize) !ArrayFrame {
        try self.padBody(4);
        const len_offset = self.body.items.len;
        try self.writeU32(0); // placeholder
        try self.padBody(elem_align);
        return .{ .len_offset = len_offset, .payload_start = self.body.items.len };
    }

    pub fn finishArray(self: *MessageBuilder, frame: ArrayFrame) void {
        const array_payload_len = self.body.items.len - frame.payload_start;
        const len_u32: u32 = @intCast(array_payload_len);
        std.mem.writeInt(u32, self.body.items[frame.len_offset..][0..4], len_u32, .little);
    }

    pub fn startStruct(self: *MessageBuilder) !void {
        try self.padBody(8);
    }

    pub fn build(self: *MessageBuilder) ![]u8 {
        var fields: std.ArrayList(u8) = .empty;
        defer fields.deinit(self.allocator);

        try appendField(self.allocator, &fields, .path, "o", self.path);
        try appendField(self.allocator, &fields, .interface, "s", self.interface);
        try appendField(self.allocator, &fields, .member, "s", self.member);
        try appendField(self.allocator, &fields, .error_name, "s", self.error_name);
        try appendField(self.allocator, &fields, .destination, "s", self.destination);
        if (self.reply_serial) |rs| {
            try appendFieldU32(self.allocator, &fields, .reply_serial, rs);
        }
        try appendField(self.allocator, &fields, .signature, "g", self.signature);
        if (self.unix_fds != 0) {
            try appendFieldU32(self.allocator, &fields, .unix_fds, self.unix_fds);
        }

        // Every length below is known before a byte is written: the 16-byte
        // fixed header, the fields it carries, the 8-byte header pad and the
        // body. The wire is therefore built in one exact-size allocation
        // rather than grown and copied, so no over-allocated intermediate
        // holding the serialized body is ever released beside it.
        const fields_bytes = fields.items.len;
        const body_bytes = self.body.items.len;
        const header_pad = padLen(16 + fields_bytes, 8);
        const wire_len = 16 + fields_bytes + header_pad + body_bytes;

        const wire = try self.allocator.alloc(u8, wire_len);
        errdefer self.allocator.free(wire);

        // 16-byte fixed header
        wire[0] = 'l'; // little-endian
        wire[1] = @intFromEnum(self.msg_type);
        wire[2] = self.flags;
        wire[3] = 1; // protocol version
        std.mem.writeInt(u32, wire[4..8], @intCast(body_bytes), .little);
        std.mem.writeInt(u32, wire[8..12], self.serial, .little);
        std.mem.writeInt(u32, wire[12..16], @intCast(fields_bytes), .little);

        @memcpy(wire[16..][0..fields_bytes], fields.items);
        @memset(wire[16 + fields_bytes ..][0..header_pad], 0);
        @memcpy(wire[16 + fields_bytes + header_pad ..][0..body_bytes], self.body.items);

        return wire;
    }

    fn appendField(
        alloc: std.mem.Allocator,
        buf: *std.ArrayList(u8),
        code: HeaderField,
        sig: []const u8,
        val: ?[]const u8,
    ) !void {
        const v = val orelse return;
        const pad = padLen(buf.items.len, 8);
        try buf.appendNTimes(alloc, 0, pad);

        try buf.append(alloc, @intFromEnum(code));
        try buf.append(alloc, @intCast(sig.len));
        try buf.appendSlice(alloc, sig);
        try buf.append(alloc, 0);

        if (std.mem.eql(u8, sig, "s") or std.mem.eql(u8, sig, "o")) {
            const str_pad = padLen(buf.items.len, 4);
            try buf.appendNTimes(alloc, 0, str_pad);
            var len_b: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_b, @intCast(v.len), .little);
            try buf.appendSlice(alloc, &len_b);
            try buf.appendSlice(alloc, v);
            try buf.append(alloc, 0);
        } else if (std.mem.eql(u8, sig, "g")) {
            try buf.append(alloc, @intCast(v.len));
            try buf.appendSlice(alloc, v);
            try buf.append(alloc, 0);
        }
    }

    fn appendFieldU32(
        alloc: std.mem.Allocator,
        buf: *std.ArrayList(u8),
        code: HeaderField,
        val: u32,
    ) !void {
        const pad = padLen(buf.items.len, 8);
        try buf.appendNTimes(alloc, 0, pad);

        try buf.append(alloc, @intFromEnum(code));
        try buf.append(alloc, 1); // signature length
        try buf.append(alloc, 'u');
        try buf.append(alloc, 0);

        const val_pad = padLen(buf.items.len, 4);
        try buf.appendNTimes(alloc, 0, val_pad);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, val, .little);
        try buf.appendSlice(alloc, &b);
    }
};

pub const MessageParser = struct {
    pub fn parse(bytes: []const u8) !Message {
        if (bytes.len < 16) return error.MessageTooShort;
        if (bytes[0] != 'l') return error.UnsupportedEndianness;
        const msg_type_raw = bytes[1];
        if (msg_type_raw < 1 or msg_type_raw > 4) return error.InvalidMessageType;
        const msg_type: MessageType = @enumFromInt(msg_type_raw);
        const flags = bytes[2];
        const version = bytes[3];
        if (version != 1) return error.UnsupportedProtocolVersion;

        const body_len = std.mem.readInt(u32, bytes[4..8], .little);
        const serial = std.mem.readInt(u32, bytes[8..12], .little);
        const fields_len = std.mem.readInt(u32, bytes[12..16], .little);

        if (16 + fields_len > bytes.len) return error.FieldsTruncated;
        const fields_slice = bytes[16 .. 16 + fields_len];

        var msg: Message = .{
            .msg_type = msg_type,
            .flags = flags,
            .serial = serial,
        };

        var f_idx: usize = 0;
        while (f_idx < fields_slice.len) {
            const pad = padLen(f_idx, 8);
            f_idx += pad;
            if (f_idx >= fields_slice.len) break;

            const code_raw = fields_slice[f_idx];
            f_idx += 1;
            if (f_idx >= fields_slice.len) break;
            const sig_len = fields_slice[f_idx];
            f_idx += 1;
            if (f_idx + sig_len + 1 > fields_slice.len) break;
            const sig = fields_slice[f_idx .. f_idx + sig_len];
            f_idx += sig_len + 1; // skip null

            const code: ?HeaderField = if (code_raw >= 1 and code_raw <= 9) @enumFromInt(code_raw) else null;

            if (std.mem.eql(u8, sig, "s") or std.mem.eql(u8, sig, "o")) {
                const str_pad = padLen(f_idx, 4);
                f_idx += str_pad;
                if (f_idx + 4 > fields_slice.len) break;
                const str_len = std.mem.readInt(u32, fields_slice[f_idx..][0..4], .little);
                f_idx += 4;
                if (f_idx + str_len + 1 > fields_slice.len) break;
                const str_val = fields_slice[f_idx .. f_idx + str_len];
                f_idx += str_len + 1;

                if (code) |c| {
                    switch (c) {
                        .path => msg.path = str_val,
                        .interface => msg.interface = str_val,
                        .member => msg.member = str_val,
                        .error_name => msg.error_name = str_val,
                        .destination => msg.destination = str_val,
                        .sender => msg.sender = str_val,
                        else => {},
                    }
                }
            } else if (std.mem.eql(u8, sig, "g")) {
                if (f_idx >= fields_slice.len) break;
                const g_len = fields_slice[f_idx];
                f_idx += 1;
                if (f_idx + g_len + 1 > fields_slice.len) break;
                const g_val = fields_slice[f_idx .. f_idx + g_len];
                f_idx += g_len + 1;
                if (code == .signature) {
                    msg.signature = g_val;
                }
            } else if (std.mem.eql(u8, sig, "u")) {
                const u_pad = padLen(f_idx, 4);
                f_idx += u_pad;
                if (f_idx + 4 > fields_slice.len) break;
                const u_val = std.mem.readInt(u32, fields_slice[f_idx..][0..4], .little);
                f_idx += 4;
                if (code == .reply_serial) {
                    msg.reply_serial = u_val;
                } else if (code == .unix_fds) {
                    msg.unix_fds = u_val;
                }
            } else {
                // Unknown signature, advance safely
                break;
            }
        }

        const header_total_raw = 16 + fields_len;
        const header_pad = padLen(header_total_raw, 8);
        const body_start = header_total_raw + header_pad;

        if (body_start + body_len > bytes.len) return error.BodyTruncated;
        msg.body = bytes[body_start .. body_start + body_len];

        return msg;
    }
};

pub const BodyReader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn init(bytes: []const u8) BodyReader {
        return .{ .bytes = bytes, .cursor = 0 };
    }

    pub fn pad(self: *BodyReader, alignment: usize) void {
        const p = padLen(self.cursor, alignment);
        self.cursor += p;
    }

    pub fn readByte(self: *BodyReader) !u8 {
        if (self.cursor >= self.bytes.len) return error.EndOfStream;
        const b = self.bytes[self.cursor];
        self.cursor += 1;
        return b;
    }

    pub fn readBool(self: *BodyReader) !bool {
        const val = try self.readU32();
        return val != 0;
    }

    pub fn readI16(self: *BodyReader) !i16 {
        self.pad(2);
        if (self.cursor + 2 > self.bytes.len) return error.EndOfStream;
        const val = std.mem.readInt(i16, self.bytes[self.cursor..][0..2], .little);
        self.cursor += 2;
        return val;
    }

    pub fn readU16(self: *BodyReader) !u16 {
        self.pad(2);
        if (self.cursor + 2 > self.bytes.len) return error.EndOfStream;
        const val = std.mem.readInt(u16, self.bytes[self.cursor..][0..2], .little);
        self.cursor += 2;
        return val;
    }

    pub fn readI32(self: *BodyReader) !i32 {
        self.pad(4);
        if (self.cursor + 4 > self.bytes.len) return error.EndOfStream;
        const val = std.mem.readInt(i32, self.bytes[self.cursor..][0..4], .little);
        self.cursor += 4;
        return val;
    }

    pub fn readU32(self: *BodyReader) !u32 {
        self.pad(4);
        if (self.cursor + 4 > self.bytes.len) return error.EndOfStream;
        const val = std.mem.readInt(u32, self.bytes[self.cursor..][0..4], .little);
        self.cursor += 4;
        return val;
    }

    pub fn readI64(self: *BodyReader) !i64 {
        self.pad(8);
        if (self.cursor + 8 > self.bytes.len) return error.EndOfStream;
        const val = std.mem.readInt(i64, self.bytes[self.cursor..][0..8], .little);
        self.cursor += 8;
        return val;
    }

    pub fn readU64(self: *BodyReader) !u64 {
        self.pad(8);
        if (self.cursor + 8 > self.bytes.len) return error.EndOfStream;
        const val = std.mem.readInt(u64, self.bytes[self.cursor..][0..8], .little);
        self.cursor += 8;
        return val;
    }

    pub fn readString(self: *BodyReader) ![]const u8 {
        const len = try self.readU32();
        if (self.cursor + len + 1 > self.bytes.len) return error.EndOfStream;
        const str = self.bytes[self.cursor .. self.cursor + len];
        self.cursor += len + 1; // include null terminator
        return str;
    }

    pub fn readObjectPath(self: *BodyReader) ![]const u8 {
        return self.readString();
    }

    pub fn readSignature(self: *BodyReader) ![]const u8 {
        const len = try self.readByte();
        if (self.cursor + len + 1 > self.bytes.len) return error.EndOfStream;
        const sig = self.bytes[self.cursor .. self.cursor + len];
        self.cursor += len + 1; // include null terminator
        return sig;
    }

    pub fn readArray(self: *BodyReader, elem_align: usize) ![]const u8 {
        const byte_len = try self.readU32();
        self.pad(elem_align);
        if (self.cursor + byte_len > self.bytes.len) return error.EndOfStream;
        const slice = self.bytes[self.cursor .. self.cursor + byte_len];
        self.cursor += byte_len;
        return slice;
    }

    pub fn alignStruct(self: *BodyReader) void {
        self.pad(8);
    }
};

/// Lookup an environment variable from /proc/self/environ without requiring libc.
///
/// The block is one NUL separated run of records that is usually longer than
/// the caller's buffer, so it is walked in bounded chunks instead of being read
/// once. A variable stored past the end of `buf`, and a record the first read
/// cut in half, are then found like any other, and a record that does not
/// match is skipped without ever being held whole.
///
/// `buf` receives the value, so the returned slice is the caller's to keep for
/// as long as it wants it. A value that does not fit in `buf` is refused rather
/// than cut short: half a bus address is a path that does not exist, and a
/// block that ends inside a value is not a value at all.
pub fn getEnvFromProc(name: []const u8, buf: []u8) ?[]const u8 {
    const fd_res = std.os.linux.open("/proc/self/environ", .{}, 0);
    if (std.os.linux.errno(fd_res) != .SUCCESS) return null;
    const fd: i32 = @intCast(fd_res);
    defer _ = std.os.linux.close(fd);

    // What the scan is doing with the record it is standing in: matching the
    // name, skipping a record it has already decided about, or copying the
    // value of the record it matched.
    const Stage = enum { key, skip, value };
    var stage: Stage = .key;
    // Name bytes matched so far in the record at the head of the scan, and
    // value bytes copied into `buf` so far.
    var matched: usize = 0;
    var value_len: usize = 0;

    var chunk: [512]u8 = undefined;
    while (true) {
        const n_res = std.os.linux.read(fd, &chunk, chunk.len);
        if (std.os.linux.errno(n_res) != .SUCCESS) return null;
        const n: usize = @intCast(n_res);
        if (n == 0) break;
        for (chunk[0..n]) |byte| {
            if (byte == 0) {
                // A NUL ends the record. Only the one this scan matched is a
                // value; any other ends a record that was never the answer.
                if (stage == .value) return buf[0..value_len];
                stage = .key;
                matched = 0;
                continue;
            }
            switch (stage) {
                .key => if (matched < name.len) {
                    if (byte == name[matched]) {
                        matched += 1;
                    } else {
                        stage = .skip;
                    }
                } else if (byte == '=') {
                    // The whole name and the '=' that assigns it, so this
                    // record is the one. A name that only starts the same way
                    // reached this byte without it and is skipped instead.
                    stage = .value;
                    value_len = 0;
                } else {
                    stage = .skip;
                },
                .skip => {},
                .value => {
                    // A value one byte past what `buf` holds can never fit in
                    // it, so the copy stops here instead of truncating.
                    if (value_len == buf.len) return null;
                    buf[value_len] = byte;
                    value_len += 1;
                },
            }
        }
    }
    // The block ended without the NUL that would have closed a value.
    return null;
}

/// Low-level D-Bus transport over a Unix domain socket.
pub const Connection = struct {
    /// Reject any frame larger than this before growing the inbound buffer.
    pub const max_message_bytes = 8 * 1024 * 1024;

    allocator: std.mem.Allocator,
    fd: ?i32 = null,
    serial: u32 = 1,
    unique_name: ?[]u8 = null,
    inbound: std.ArrayList(u8) = .empty,
    inbound_pos: usize = 0,
    /// Set only when the authenticated peer accepts descriptor passing.
    unix_fd_capable: bool = false,

    pub fn initCustom(allocator: std.mem.Allocator, fd: i32) Connection {
        return .{
            .allocator = allocator,
            .fd = fd,
            .serial = 1,
            .unique_name = null,
            .inbound = .empty,
            .inbound_pos = 0,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.unique_name) |un| {
            self.allocator.free(un);
            self.unique_name = null;
        }
        self.wipeInbound();
        self.inbound.deinit(self.allocator);
        self.inbound = .empty;
        self.inbound_pos = 0;
        if (self.fd) |f| {
            _ = std.os.linux.close(f);
            self.fd = null;
        }
        self.* = undefined;
    }

    /// Wipe every staged byte and forget them. A credential reply passes
    /// through this buffer with the plaintext in it, so the buffer does not
    /// keep a copy for as long as the connection lives.
    fn wipeInbound(self: *Connection) void {
        if (self.inbound.items.len != 0) {
            std.crypto.secureZero(u8, self.inbound.items);
        }
        self.inbound.clearRetainingCapacity();
        self.inbound_pos = 0;
    }

    /// Forget the socket without closing it. The provider keeps the fd.
    pub fn detachFd(self: *Connection) void {
        self.fd = null;
    }

    pub fn nextSerial(self: *Connection) u32 {
        const s = self.serial;
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        return s;
    }

    pub fn sendRaw(self: *Connection, bytes: []const u8) !void {
        const f = self.fd orelse return error.NotConnected;
        var written: usize = 0;
        while (written < bytes.len) {
            const n_res = std.os.linux.write(f, bytes[written..].ptr, bytes.len - written);
            if (std.os.linux.errno(n_res) != .SUCCESS) return error.WriteFailed;
            const n: usize = @intCast(n_res);
            if (n == 0) return error.ConnectionClosed;
            written += n;
        }
    }

    /// Borrow one descriptor and attach it only to the first bytes sent.
    /// The caller retains ownership; the receiving kernel creates its copy.
    fn sendRawWithFd(self: *Connection, bytes: []const u8, descriptor: std.posix.fd_t) !void {
        const fd = self.fd orelse return error.NotConnected;
        const linux = std.os.linux;
        const message_length = @sizeOf(linux.cmsghdr) + @sizeOf(std.posix.fd_t);
        const control_align = @alignOf(linux.cmsghdr);
        const control_size = comptime std.mem.alignForward(usize, message_length, control_align);
        var control: [control_size]u8 align(control_align) = @splat(0);
        const header: *linux.cmsghdr = @ptrCast(&control);
        header.* = .{ .len = message_length, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
        const carried: *std.posix.fd_t = @ptrCast(@alignCast(control[@sizeOf(linux.cmsghdr)..].ptr));
        carried.* = descriptor;
        const iov = [_]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
        const message: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        while (true) {
            const sent = linux.sendmsg(fd, &message, linux.MSG.NOSIGNAL);
            switch (linux.errno(sent)) {
                .SUCCESS => {
                    if (sent == 0) return error.ConnectionClosed;
                    // The descriptor has crossed once. Any remaining bytes
                    // use ordinary writes rather than resending the control.
                    return self.sendRaw(bytes[sent..]);
                },
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }

    pub fn readExact(self: *Connection, buffer: []u8) !void {
        const f = self.fd orelse return error.NotConnected;
        var total: usize = 0;
        while (total < buffer.len) {
            const n_res = std.os.linux.read(f, buffer[total..].ptr, buffer.len - total);
            if (std.os.linux.errno(n_res) != .SUCCESS) return error.ReadFailed;
            const n: usize = @intCast(n_res);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }
    }

    /// Read one socket chunk into the inbound buffer. `false` is end of
    /// stream. Blocking: call only once `pollReadable` reports input.
    fn fill(self: *Connection) !bool {
        const f = self.fd orelse return error.NotConnected;
        if (self.inbound.capacity - self.inbound.items.len < 512) {
            self.compactInbound();
            if (self.inbound.capacity - self.inbound.items.len < 512) {
                try self.growInbound(self.inbound.items.len + 512);
            }
        }
        var chunk: [4096]u8 = undefined;
        const want = @min(chunk.len, self.inbound.capacity - self.inbound.items.len);
        const n_res = std.os.linux.read(f, &chunk, want);
        if (std.os.linux.errno(n_res) != .SUCCESS) return error.ReadFailed;
        const n: usize = @intCast(n_res);
        if (n == 0) return false;
        // The stack chunk is as much a copy of the frame as the buffer is,
        // and the stack outlives the call that asked for the message.
        self.inbound.appendSlice(self.allocator, chunk[0..n]) catch |err| {
            std.crypto.secureZero(u8, chunk[0..n]);
            return err;
        };
        std.crypto.secureZero(u8, chunk[0..n]);
        return true;
    }

    /// Make room until the buffer holds at least `needed` bytes in total.
    ///
    /// Growing the buffer in the middle of a frame releases the block that
    /// already holds part of it, and a credential reply carries a
    /// plaintext secret, so the old block is wiped here rather than left
    /// to the allocator to reuse.
    fn growInbound(self: *Connection, needed: usize) !void {
        // Saturating arithmetic: a wrapped capacity would allocate less than
        // the bytes already buffered.
        const grown_len = @max(needed, self.inbound.capacity +| (self.inbound.capacity >> 1) +| 8);
        const capacity = @max(grown_len, 4096);
        const len = self.inbound.items.len;
        const grown = try self.allocator.alloc(u8, capacity);
        @memcpy(grown[0..len], self.inbound.items);
        const old = self.inbound.allocatedSlice();
        self.inbound.items = grown.ptr[0..len];
        self.inbound.capacity = capacity;
        if (old.len != 0) {
            std.crypto.secureZero(u8, old);
            self.allocator.free(old);
        }
    }

    /// Drop the frames already handed out and anything left over.
    fn compactInbound(self: *Connection) void {
        if (self.inbound_pos == 0) return;
        const remaining = self.inbound.items.len - self.inbound_pos;
        @memmove(self.inbound.items[0..remaining], self.inbound.items[self.inbound_pos..]);
        // Only the tail this compaction drops needs wiping. The bytes before
        // `inbound_pos` were already wiped by the `nextBuffered` call that
        // handed them out, and after the move the region below `remaining`
        // holds the frame that is still arriving, so wiping the prefix would
        // destroy it.
        std.crypto.secureZero(u8, self.inbound.items[remaining..]);
        self.inbound.shrinkRetainingCapacity(remaining);
        self.inbound_pos = 0;
    }

    fn pending(self: *const Connection) []const u8 {
        return self.inbound.items[self.inbound_pos..];
    }

    /// True when a complete frame is already staged. Reads the header only, so
    /// it neither allocates nor touches the socket.
    fn hasStagedFrame(self: *const Connection) bool {
        // Bytes that are not a frame at all cannot be drained. They surface
        // as the transport fault they are where the frame is copied, so this
        // answer is only about whether one whole frame is here to collect.
        return (frameLength(self.pending()) catch null) != null;
    }

    /// Total wire length of the message at the head of `bytes`, or null when
    /// the buffer does not hold one complete frame yet.
    pub fn frameLength(bytes: []const u8) !?usize {
        if (bytes.len < 16) return null;
        if (bytes[0] != 'l') return error.UnsupportedEndianness;
        const msg_type = bytes[1];
        if (msg_type < 1 or msg_type > 4) return error.InvalidMessageType;
        if (bytes[3] != 1) return error.UnsupportedProtocolVersion;
        const body_len = std.mem.readInt(u32, bytes[4..8], .little);
        const fields_len = std.mem.readInt(u32, bytes[12..16], .little);
        const header_pad = padLen(16 + @as(usize, fields_len), 8);
        const total = 16 + @as(usize, fields_len) + header_pad + @as(usize, body_len);
        if (total > max_message_bytes) return error.MessageTooLarge;
        if (bytes.len < total) return null;
        return total;
    }

    /// Copy the next complete buffered message. Null when no full frame is
    /// buffered. Never touches the socket.
    pub fn nextBuffered(self: *Connection) !?[]u8 {
        const total = (try frameLength(self.pending())) orelse return null;
        const start = self.inbound_pos;
        const frame = self.inbound.items[start .. start + total];
        // Wipe the staged frame only once the copy exists, so a failed
        // copy leaves the message buffered for the next attempt. The copy
        // is the caller's to wipe, and this is the staging copy that would
        // otherwise keep a secret for the life of the connection.
        const copy = try self.allocator.dupe(u8, frame);
        std.crypto.secureZero(u8, frame);
        self.inbound_pos = start + total;
        if (self.inbound_pos == self.inbound.items.len) {
            self.inbound.clearRetainingCapacity();
            self.inbound_pos = 0;
        }
        return copy;
    }

    /// True when the socket has bytes ready. `timeout_ms` of 0 never blocks.
    pub fn pollReadable(self: *Connection, timeout_ms: i32) !bool {
        const f = self.fd orelse return error.NotConnected;
        var fds = [_]std.os.linux.pollfd{.{ .fd = f, .events = std.os.linux.POLL.IN, .revents = 0 }};
        const res = std.os.linux.poll(&fds, fds.len, timeout_ms);
        if (std.os.linux.errno(res) != .SUCCESS) return error.PollFailed;
        const ready: usize = @intCast(res);
        if (ready == 0) return false;
        const interesting = std.os.linux.POLL.IN | std.os.linux.POLL.HUP | std.os.linux.POLL.ERR;
        return fds[0].revents & interesting != 0;
    }

    /// Collect every message that is already available without blocking.
    /// Each entry is an owned copy the caller must free.
    ///
    /// A frame this transport staged while it answered a call is available
    /// even when the socket has had nothing to say since, so the staged frames
    /// are collected either way. Returning early on a quiet socket would
    /// leave them waiting for traffic a daemon that already sent them may never
    /// send again, and waiting out `timeout_ms` for a frame that is already
    /// here would delay an answer the host is waiting for. With nothing staged
    /// the timeout still governs how long this waits for input.
    ///
    /// A frame the staging buffer cannot parse is a transport fault like any
    /// other and is returned as one, so a caller retires the connection
    /// instead of draining a stream it can no longer resynchronize.
    pub fn drainAvailable(self: *Connection, timeout_ms: i32, out: *std.ArrayList([]u8)) !usize {
        // Only a drain with nothing staged waits on the socket: with a whole
        // frame in hand the socket is read without blocking, and with nothing
        // in hand `timeout_ms` still governs how long this waits for input.
        const wait_ms: i32 = if (self.hasStagedFrame()) 0 else timeout_ms;
        if (try self.pollReadable(wait_ms)) {
            while (try self.pollReadable(0)) {
                if (!try self.fill()) return error.ConnectionClosed;
            }
        }

        var count: usize = 0;
        while (try self.nextBuffered()) |message| {
            // The copy is the caller's. A failed append hands the message back
            // to this scope, and without that the copy of every frame the
            // transport had already drained is lost on the way out.
            errdefer self.allocator.free(message);
            try out.append(self.allocator, message);
            count += 1;
        }
        return count;
    }

    /// Blocking read of the next message, whatever it is. Used by peers that
    /// read a call, and by a caller that correlates replies itself; a call
    /// waiting for its own answer wants `call`, not this.
    pub fn readMessageBytes(self: *Connection) ![]u8 {
        while (true) {
            if (try self.nextBuffered()) |message| return message;
            if (!try self.fill()) return error.ConnectionClosed;
        }
    }

    /// Send `builder` and return the frame that answers it.
    ///
    /// The wire belongs to the builder that made it, so it is sent and
    /// released with the builder's allocator. The reply is duplicated with
    /// this connection's allocator, so the caller releases it with `c.allocator`.
    ///
    /// The wire is wiped before it is released. It can carry a secret - a
    /// credential write puts plaintext in the body - and nothing else owns
    /// that block: the builder cannot reach it once `build` has returned, and
    /// a caller that never sees the wire cannot wipe it either.
    pub fn call(self: *Connection, builder: *MessageBuilder) ![]u8 {
        const wire = try builder.build();
        defer {
            std.crypto.secureZero(u8, wire);
            builder.allocator.free(wire);
        }
        try self.sendRaw(wire);
        return self.readReply(builder.serial);
    }

    /// Call with one borrowed descriptor after SASL negotiated UNIX_FD.
    /// The builder carries count 1; its body names descriptor index 0.
    pub fn callWithFd(self: *Connection, builder: *MessageBuilder, descriptor: std.posix.fd_t) ![]u8 {
        if (!self.unix_fd_capable) return error.UnixFdUnsupported;
        builder.unix_fds = 1;
        const wire = try builder.build();
        defer {
            std.crypto.secureZero(u8, wire);
            builder.allocator.free(wire);
        }
        try self.sendRawWithFd(wire, descriptor);
        return self.readReply(builder.serial);
    }

    /// Wait for the answer to `serial` and return it, blocking until it comes.
    ///
    /// Every other frame stays in the staging buffer, in the order it arrived,
    /// for the next `drainAvailable`. Retained traffic is bounded by
    /// `max_message_bytes`, just as an individual frame is.
    fn readReply(self: *Connection, serial: u32) ![]u8 {
        // How far into the pending region this wait has already looked, so the
        // frames it has rejected are not walked again after every read. The
        // offset is relative to `inbound_pos`, which is what keeps it valid
        // when a fill moves the pending bytes down to the front of the buffer.
        var looked: usize = 0;
        while (true) {
            if (try self.takeReply(serial, &looked)) |reply| return reply;
            if (self.inbound.items.len - self.inbound_pos > max_message_bytes) {
                return error.MessageTooLarge;
            }
            if (!try self.fill()) return error.ConnectionClosed;
        }
    }

    /// Take the answer to `serial` out of the staging buffer, or null when no
    /// complete frame answers it yet. `looked` is carried across calls so the
    /// rejected frames are inspected once.
    ///
    /// The copy is made before the answer is removed, following the rule
    /// `nextBuffered` states: a failed copy leaves the staged frame where it
    /// is for the next attempt.
    fn takeReply(self: *Connection, serial: u32, looked: *usize) !?[]u8 {
        var start = self.inbound_pos + looked.*;
        while (start < self.inbound.items.len) {
            // A head that is not a frame at all fails the same way at the same
            // offset forever, so it is reported here instead of being read
            // past until the bound trips.
            const total = (try frameLength(self.inbound.items[start..])) orelse {
                looked.* = start - self.inbound_pos;
                return null;
            };
            const frame = self.inbound.items[start .. start + total];
            if (try answersSerial(frame, serial)) {
                const copy = try self.allocator.dupe(u8, frame);
                self.dropStaged(start, total);
                return copy;
            }
            start += total;
        }
        looked.* = start - self.inbound_pos;
        return null;
    }

    /// True when `frame` is the answer to a call with this serial: a method
    /// return or an error reply naming it. A signal, and another call's
    /// answer, are both false.
    fn answersSerial(frame: []const u8, serial: u32) !bool {
        const message = try MessageParser.parse(frame);
        return switch (message.msg_type) {
            .method_return, .error_reply => if (message.reply_serial) |rs| rs == serial else false,
            else => false,
        };
    }

    /// Remove `total` bytes at `start` from the staging buffer and keep every
    /// other frame, in the order it arrived.
    fn dropStaged(self: *Connection, start: usize, total: usize) void {
        const remaining = self.inbound.items.len - total;
        @memmove(self.inbound.items[start..remaining], self.inbound.items[start + total ..]);
        // The frame that goes and the bytes the move vacates are dropped, not
        // just unlinked: the staging buffer carries a credential reply in
        // plaintext, and `compactInbound` wipes for the same reason.
        std.crypto.secureZero(u8, self.inbound.items[remaining..]);
        self.inbound.shrinkRetainingCapacity(remaining);
        // Nothing pending is left, so the buffer goes back to the empty state
        // an emptied `nextBuffered` leaves it in.
        if (self.inbound_pos == self.inbound.items.len) {
            self.inbound.clearRetainingCapacity();
            self.inbound_pos = 0;
        }
    }

    /// Install a match rule so the bus forwards matching signals.
    pub fn addMatch(self: *Connection, rule: []const u8) !void {
        var b = MessageBuilder.init(self.allocator, .method_call, self.nextSerial());
        defer b.deinit();
        b.destination = "org.freedesktop.DBus";
        b.path = "/org/freedesktop/DBus";
        b.interface = "org.freedesktop.DBus";
        b.member = "AddMatch";
        b.signature = "s";
        try b.writeString(rule);

        const reply = try self.call(&b);
        defer self.allocator.free(reply);
        const message = try MessageParser.parse(reply);
        if (message.msg_type == .error_reply) return error.AddMatchFailed;
        // The call waits for the frame that names it, so a reply that is not a
        // method return is a daemon that did not answer this call: a match
        // rule nobody installed must not look installed.
        if (message.msg_type != .method_return) return error.AddMatchFailed;
    }

    /// True when `name` currently has an owner on the bus.
    pub fn nameHasOwner(self: *Connection, name: []const u8) !bool {
        var b = MessageBuilder.init(self.allocator, .method_call, self.nextSerial());
        defer b.deinit();
        b.destination = "org.freedesktop.DBus";
        b.path = "/org/freedesktop/DBus";
        b.interface = "org.freedesktop.DBus";
        b.member = "NameHasOwner";
        b.signature = "s";
        try b.writeString(name);

        const reply = try self.call(&b);
        defer self.allocator.free(reply);
        const message = try MessageParser.parse(reply);
        if (message.msg_type == .error_reply) return error.NameHasOwnerFailed;
        var reader = BodyReader.init(message.body);
        return reader.readBool();
    }

    /// Call `Hello` and remember the unique bus name.
    pub fn hello(self: *Connection) !void {
        var b = MessageBuilder.init(self.allocator, .method_call, self.nextSerial());
        defer b.deinit();
        b.destination = "org.freedesktop.DBus";
        b.path = "/org/freedesktop/DBus";
        b.interface = "org.freedesktop.DBus";
        b.member = "Hello";

        const reply_bytes = try self.call(&b);
        defer self.allocator.free(reply_bytes);

        const reply = try MessageParser.parse(reply_bytes);
        if (reply.msg_type == .error_reply) return error.DBusHelloFailed;
        if (reply.msg_type != .method_return) return error.InvalidReply;

        var reader = BodyReader.init(reply.body);
        self.unique_name = try self.allocator.dupe(u8, try reader.readString());
    }

    /// Connect to the system session bus via $DBUS_SESSION_BUS_ADDRESS.
    pub fn connectSessionBus(allocator: std.mem.Allocator) !Connection {
        var env_buf: [4096]u8 = undefined;
        const bus_addr = getEnvFromProc("DBUS_SESSION_BUS_ADDRESS", &env_buf) orelse {
            return error.NoSessionBusAddress;
        };

        const path_prefix = "unix:path=";
        if (!std.mem.startsWith(u8, bus_addr, path_prefix)) {
            return error.UnsupportedBusAddress;
        }

        const socket_path = bus_addr[path_prefix.len..];
        const clean_path = if (std.mem.findScalar(u8, socket_path, ',')) |idx|
            socket_path[0..idx]
        else
            socket_path;

        const sock_res = std.os.linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        if (std.os.linux.errno(sock_res) != .SUCCESS) return error.SocketCreationFailed;
        const sock: i32 = @intCast(sock_res);
        var conn = Connection.initCustom(allocator, sock);
        errdefer conn.deinit();

        var addr: std.posix.sockaddr.un = .{
            .family = std.posix.AF.UNIX,
            .path = @splat(0),
        };
        if (clean_path.len >= addr.path.len) return error.SocketPathTooLong;
        @memcpy(addr.path[0..clean_path.len], clean_path);

        const conn_res = std.os.linux.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        if (std.os.linux.errno(conn_res) != .SUCCESS) return error.ConnectFailed;

        try conn.authenticateSasl();
        try conn.hello();

        return conn;
    }

    fn authenticateSasl(self: *Connection) !void {
        const uid = std.os.linux.getuid();
        var uid_buf: [32]u8 = undefined;
        const uid_str = try std.fmt.bufPrint(&uid_buf, "{d}", .{uid});

        var hex_uid_buf: [64]u8 = undefined;
        var hex_idx: usize = 0;
        for (uid_str) |ch| {
            const hex_digits = "0123456789abcdef";
            hex_uid_buf[hex_idx] = hex_digits[ch >> 4];
            hex_uid_buf[hex_idx + 1] = hex_digits[ch & 0x0F];
            hex_idx += 2;
        }
        const hex_uid = hex_uid_buf[0..hex_idx];

        var auth_cmd_buf: [128]u8 = undefined;
        const auth_cmd = try std.fmt.bufPrint(&auth_cmd_buf, "\x00AUTH EXTERNAL {s}\r\n", .{hex_uid});
        try self.sendRaw(auth_cmd);

        var line_buf: [128]u8 = undefined;
        const line = try self.readSaslLine(&line_buf);
        if (!std.mem.startsWith(u8, line, "OK")) {
            return error.SaslAuthFailed;
        }
        try self.sendRaw("NEGOTIATE_UNIX_FD\r\n");
        const negotiation = try self.readSaslLine(&line_buf);
        if (std.mem.eql(u8, negotiation, "AGREE_UNIX_FD\r\n")) {
            self.unix_fd_capable = true;
        } else if (std.mem.startsWith(u8, negotiation, "ERROR")) {
            self.unix_fd_capable = false;
        } else {
            return error.SaslAuthFailed;
        }

        try self.sendRaw("BEGIN\r\n");
    }

    fn readSaslLine(self: *Connection, buffer: []u8) ![]const u8 {
        var length: usize = 0;
        while (length < buffer.len) {
            try self.readExact(buffer[length..][0..1]);
            length += 1;
            if (length >= 2 and std.mem.endsWith(u8, buffer[0..length], "\r\n")) {
                return buffer[0..length];
            }
        }
        return error.SaslAuthFailed;
    }
};

test "linux dbus message round-trip encoding and decoding" {
    var builder = MessageBuilder.init(std.testing.allocator, .method_call, 42);
    defer builder.deinit();

    builder.destination = "org.freedesktop.Notifications";
    builder.path = "/org/freedesktop/Notifications";
    builder.interface = "org.freedesktop.Notifications";
    builder.member = "Notify";
    builder.signature = "sus";

    try builder.writeString("test_app");
    try builder.writeU32(100);
    try builder.writeString("icon_name");

    const wire = try builder.build();
    defer std.testing.allocator.free(wire);

    const parsed = try MessageParser.parse(wire);
    try std.testing.expectEqual(MessageType.method_call, parsed.msg_type);
    try std.testing.expectEqual(@as(u32, 42), parsed.serial);
    try std.testing.expectEqualStrings("org.freedesktop.Notifications", parsed.destination.?);
    try std.testing.expectEqualStrings("/org/freedesktop/Notifications", parsed.path.?);
    try std.testing.expectEqualStrings("org.freedesktop.Notifications", parsed.interface.?);
    try std.testing.expectEqualStrings("Notify", parsed.member.?);
    try std.testing.expectEqualStrings("sus", parsed.signature.?);

    var reader = BodyReader.init(parsed.body);
    const app = try reader.readString();
    const rep_id = try reader.readU32();
    const icon = try reader.readString();

    try std.testing.expectEqualStrings("test_app", app);
    try std.testing.expectEqual(@as(u32, 100), rep_id);
    try std.testing.expectEqualStrings("icon_name", icon);
}

test "linux dbus drain releases the frame copy when the output list cannot grow" {
    // A drain copies every frame the daemon sent into a list it does not own.
    // When that list cannot grow, the copy is the drain's last owner: the
    // caller gets the failure and nothing else, so no frame is left behind
    // for an owner that does not exist.
    var builder = MessageBuilder.init(std.testing.allocator, .signal, 1);
    defer builder.deinit();
    builder.path = "/org/freedesktop/Notifications";
    builder.interface = "org.freedesktop.Notifications";
    builder.member = "NotificationClosed";
    builder.signature = "uu";
    try builder.writeU32(7);
    try builder.writeU32(2);
    const wire = try builder.build();
    defer std.testing.allocator.free(wire);

    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    defer _ = std.os.linux.close(fds[1]);
    const written = std.os.linux.write(fds[1], wire.ptr, wire.len);
    if (std.os.linux.errno(written) != .SUCCESS) return error.FrameWriteFailed;
    try std.testing.expectEqual(wire.len, written);

    // The transport copies each frame out of its staging buffer with
    // `dupe(u8, frame)`: exactly the frame's own length, at one-byte
    // alignment. The list the copy is handed to allocates its storage at the
    // element's own alignment instead, so alignment is what separates the two.
    // That matters because the list's first storage request happens to be as
    // many bytes as the frame: length alone would recognise the list as the
    // frame copy and let the append through, which is exactly the drain this
    // test is about failing.
    //
    // Everything the drain allocates before that copy is staging it cannot
    // refuse without failing the read itself, and everything it allocates
    // after it is the caller's list. So the refusal is positional - after the
    // copy exists - rather than an allocation index or a byte count that any
    // change in the transport, the element size or the standard library's
    // capacity growth would move.
    const FrameCopyGate = struct {
        back: std.mem.Allocator,
        frame_bytes: usize,
        copies: usize = 0,
        refusals: usize = 0,

        // A local declaration cannot name itself, so the methods say `Self`.
        const Self = @This();

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.copies > 0) {
                // The frame the drain still owns is the caller's list's to
                // refuse now, whatever size that list asks for.
                self.refusals += 1;
                return null;
            }
            if (alignment == .@"1" and len == self.frame_bytes) {
                // The copy out of staging has just been made, which is the
                // window this test is about: the frame exists and the drain
                // has not handed it over yet.
                self.copies += 1;
            }
            return self.back.rawAlloc(len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.copies > 0) return false;
            return self.back.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remapFn(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.copies > 0) return null;
            return self.back.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.back.rawFree(memory, alignment, ret_addr);
        }
    };
    var gate: FrameCopyGate = .{ .back = std.testing.allocator, .frame_bytes = wire.len };

    var connection = Connection.initCustom(gate.allocator(), fds[0]);
    defer connection.deinit();
    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |message| gate.allocator().free(message);
        messages.deinit(gate.allocator());
    }

    try std.testing.expectError(error.OutOfMemory, connection.drainAvailable(0, &messages));

    // The frame was really copied before the list refused it, so this is the
    // ownership boundary and not a drain that never worked. One allocation
    // failed: the growth of the caller's list.
    try std.testing.expectEqual(@as(usize, 1), gate.copies);
    try std.testing.expectEqual(@as(usize, 1), gate.refusals);

    // Nothing half-owned reaches the caller, and the copy the drain could not
    // hand over is released with it: the testing allocator reports a leak at
    // the end of this scope.
    try std.testing.expectEqual(@as(usize, 0), messages.items.len);
}

test "linux dbus call does not take a signal that arrived before its reply" {
    // A daemon that sends a signal before it answers has not answered yet.
    // Taking that signal as the reply consumes the one frame the notification
    // service later needs, so the call has to wait for the frame carrying its
    // own serial and leave the signal staged, in arrival order.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const daemon_fd = fds[1];
    defer _ = std.os.linux.close(daemon_fd);

    var signal_b = MessageBuilder.init(std.testing.allocator, .signal, 900);
    defer signal_b.deinit();
    signal_b.path = "/org/freedesktop/Notifications";
    signal_b.interface = "org.freedesktop.Notifications";
    signal_b.member = "NotificationClosed";
    signal_b.signature = "uu";
    try signal_b.writeU32(7);
    try signal_b.writeU32(2);
    const signal_wire = try signal_b.build();
    defer std.testing.allocator.free(signal_wire);

    const Peer = struct {
        fn run(fd: i32, signal: []const u8) !void {
            var s_conn = Connection.initCustom(std.testing.allocator, fd);
            // The client hangs up when it is done, and that hangup is what
            // releases this thread.
            defer {
                s_conn.detachFd();
                s_conn.deinit();
            }

            const req = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req);
            const serial = (try MessageParser.parse(req)).serial;

            // The signal goes out first, so the client really does see it
            // before the frame it asked for.
            try s_conn.sendRaw(signal);

            var reply_b = MessageBuilder.init(std.testing.allocator, .method_return, 901);
            defer reply_b.deinit();
            reply_b.reply_serial = serial;
            const reply_wire = try reply_b.build();
            defer std.testing.allocator.free(reply_wire);
            try s_conn.sendRaw(reply_wire);

            var sink: [1]u8 = undefined;
            _ = std.os.linux.read(fd, &sink, sink.len);
        }
    };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{ daemon_fd, signal_wire });
    // The client is released before the peer is joined: closing the client end
    // is the hangup the peer is waiting for.
    defer thread.join();

    var connection = Connection.initCustom(std.testing.allocator, fds[0]);
    defer connection.deinit();

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |message| std.testing.allocator.free(message);
        messages.deinit(std.testing.allocator);
    }

    try connection.addMatch("type='signal'");

    // The answer to the call is gone and the signal the daemon sent first is
    // still here to be drained.
    try std.testing.expectEqual(@as(usize, 1), try connection.drainAvailable(0, &messages));
    const drained = try MessageParser.parse(messages.items[0]);
    try std.testing.expectEqual(MessageType.signal, drained.msg_type);
    try std.testing.expectEqualStrings("NotificationClosed", drained.member.?);
}

test "linux dbus call waits for its own serial and keeps an unrelated reply" {
    // Another call's answer can land between this call and its own reply. It is
    // not this call's answer, so it is left staged for the next drain instead
    // of being handed back as this call's result.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const daemon_fd = fds[1];
    defer _ = std.os.linux.close(daemon_fd);

    const Peer = struct {
        fn run(fd: i32) !void {
            var s_conn = Connection.initCustom(std.testing.allocator, fd);
            defer {
                s_conn.detachFd();
                s_conn.deinit();
            }

            const req = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req);
            const serial = (try MessageParser.parse(req)).serial;

            // Somebody else's answer first, then this call's own. The two are
            // told apart by what they carry, not by which one arrived first.
            try sendReturn(&s_conn, serial + 1000, 815);
            try sendReturn(&s_conn, serial, 4711);

            var sink: [1]u8 = undefined;
            _ = std.os.linux.read(fd, &sink, sink.len);
        }

        fn sendReturn(s_conn: *Connection, reply_serial: u32, payload: u32) !void {
            var reply_b = MessageBuilder.init(std.testing.allocator, .method_return, 902);
            defer reply_b.deinit();
            reply_b.reply_serial = reply_serial;
            reply_b.signature = "u";
            try reply_b.writeU32(payload);
            const reply_wire = try reply_b.build();
            defer std.testing.allocator.free(reply_wire);
            try s_conn.sendRaw(reply_wire);
        }
    };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{daemon_fd});
    defer thread.join();

    var connection = Connection.initCustom(std.testing.allocator, fds[0]);
    defer connection.deinit();

    var messages: std.ArrayList([]u8) = .empty;
    defer {
        for (messages.items) |message| std.testing.allocator.free(message);
        messages.deinit(std.testing.allocator);
    }

    try connection.addMatch("type='signal'");

    // What is left is the answer that was not this call's, in arrival order.
    try std.testing.expectEqual(@as(usize, 1), try connection.drainAvailable(0, &messages));
    const drained = try MessageParser.parse(messages.items[0]);
    try std.testing.expectEqual(MessageType.method_return, drained.msg_type);
    var body = BodyReader.init(drained.body);
    try std.testing.expectEqual(@as(u32, 815), try body.readU32());
}

test "linux dbus call releases no block that still carries the body it sent" {
    // The wire a call builds can carry a secret: the credentials provider puts
    // a plaintext secret in the body of CreateItem and needs it gone from
    // released memory. `call` builds that wire and owns it until the end of
    // the call, so the wipe belongs here rather than at each call site, and
    // this fixture is what says it happens.
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    const daemon_fd = fds[1];
    defer _ = std.os.linux.close(daemon_fd);

    const WipeGate = struct {
        back: std.mem.Allocator,
        // Set only around the call, so that only the blocks the call itself
        // releases are judged.
        armed: bool = false,
        leaked: usize = 0,

        // A run of this many equal bytes cannot occur in a D-Bus header, so a
        // match in a released block is the body and nothing else. Searching
        // for the body rather than for zeroed bytes keeps this a statement
        // about the secret instead of about how much the call wipes.
        const marker = [_]u8{0x5a} ** 8;

        // A local declaration cannot name itself, so the methods say `Self`.
        const Self = @This();

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.back.rawAlloc(len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.back.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remapFn(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.back.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.armed and std.mem.indexOf(u8, memory, &marker) != null) {
                self.leaked += 1;
            }
            self.back.rawFree(memory, alignment, ret_addr);
        }
    };
    var gate: WipeGate = .{ .back = std.testing.allocator };

    // Built on the gate, because the wire `call` sends is freed through the
    // builder's allocator and that is the release under test.
    var builder = MessageBuilder.init(gate.allocator(), .method_call, 1);
    defer builder.deinit();
    builder.destination = "org.freedesktop.secrets";
    builder.path = "/org/freedesktop/secrets/collection/login";
    builder.interface = "org.freedesktop.Secret.Service";
    builder.member = "CreateItem";
    builder.signature = "oaysays";
    // Stands in for the plaintext secret: bytes that survive into released
    // memory are bytes a residue scan finds.
    for (0..16) |_| try builder.writeByte(0x5a);

    const Peer = struct {
        fn run(fd: i32) !void {
            var s_conn = Connection.initCustom(std.testing.allocator, fd);
            // The client hangs up when it is done, and that hangup is what
            // releases this thread.
            defer {
                s_conn.detachFd();
                s_conn.deinit();
            }

            const req = try s_conn.readMessageBytes();
            defer std.testing.allocator.free(req);
            const serial = (try MessageParser.parse(req)).serial;

            var reply_b = MessageBuilder.init(std.testing.allocator, .method_return, 903);
            defer reply_b.deinit();
            reply_b.reply_serial = serial;
            const reply_wire = try reply_b.build();
            defer std.testing.allocator.free(reply_wire);
            try s_conn.sendRaw(reply_wire);

            var sink: [1]u8 = undefined;
            _ = std.os.linux.read(fd, &sink, sink.len);
        }
    };

    const thread = try std.Thread.spawn(.{}, Peer.run, .{daemon_fd});
    defer thread.join();

    var connection = Connection.initCustom(gate.allocator(), fds[0]);
    defer connection.deinit();

    gate.armed = true;
    const reply = try connection.call(&builder);
    // The reply is the caller's from here on, so it is no longer part of what
    // the call had to release.
    gate.armed = false;
    defer gate.allocator().free(reply);

    try std.testing.expectEqual(@as(usize, 0), gate.leaked);
}

test "api-w18 raw kernel read and write failures stay typed with libc linked" {
    var conn = Connection.initCustom(std.testing.allocator, -1);
    defer conn.deinit();
    try std.testing.expectError(error.ReadFailed, conn.readMessageBytes());
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, conn.readExact(&byte));
    try std.testing.expectError(error.WriteFailed, conn.sendRaw("x"));
}

test "api-w18 SASL negotiates descriptor capability before binary messages" {
    const Peer = struct {
        conn: Connection,
        accepts_fds: bool,
        negotiated: bool = false,
        failure: ?anyerror = null,
        // A struct local to this test has no name its own methods could be
        // written against, so the alias names it once, here.
        const Self = @This();

        fn line(self: *Self, buffer: []u8) ![]const u8 {
            var length: usize = 0;
            while (length < buffer.len) {
                try self.conn.readExact(buffer[length..][0..1]);
                length += 1;
                if (length >= 2 and std.mem.endsWith(u8, buffer[0..length], "\r\n")) {
                    return buffer[0..length];
                }
            }
            return error.AuthLineTooLong;
        }

        fn converse(self: *Self) !void {
            var buffer: [128]u8 = undefined;
            const auth = try self.line(&buffer);
            if (!std.mem.startsWith(u8, auth, "\x00AUTH EXTERNAL ")) return error.InvalidAuth;
            try self.conn.sendRaw("OK 00000000000000000000000000000000\r\n");
            const command = try self.line(&buffer);
            if (std.mem.eql(u8, command, "BEGIN\r\n")) return;
            if (!std.mem.eql(u8, command, "NEGOTIATE_UNIX_FD\r\n")) return error.InvalidNegotiation;
            self.negotiated = true;
            try self.conn.sendRaw(if (self.accepts_fds) "AGREE_UNIX_FD\r\n" else "ERROR unavailable\r\n");
            if (!std.mem.eql(u8, try self.line(&buffer), "BEGIN\r\n")) return error.InvalidBegin;
        }

        fn run(self: *Self) void {
            self.converse() catch |err| {
                self.failure = err;
            };
        }
    };

    for ([_]bool{ true, false }) |accepts_fds| {
        var fds: [2]i32 = undefined;
        const socket = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        if (std.os.linux.errno(socket) != .SUCCESS) {
            return error.SocketPairFailed;
        }
        var client = Connection.initCustom(std.testing.allocator, fds[0]);
        defer client.deinit();
        var peer: Peer = .{ .conn = Connection.initCustom(std.testing.allocator, fds[1]), .accepts_fds = accepts_fds };
        defer peer.conn.deinit();
        const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});
        client.authenticateSasl() catch |err| {
            _ = std.os.linux.shutdown(fds[0], 2);
            thread.join();
            return err;
        };
        thread.join();
        if (peer.failure) |err| return err;
        try std.testing.expect(peer.negotiated);
        try std.testing.expectEqual(accepts_fds, client.unix_fd_capable);
    }
}
