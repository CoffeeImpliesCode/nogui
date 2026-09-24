//! XDG Desktop Portal `ScreenCast` client.
//!
//! Owns the permission handshake only: `CreateSession`, `SelectSources`,
//! `Start` and `OpenPipeWireRemote`. Frame delivery lives in
//! `capture_pipewire.zig`.
//!
//! All message reads go through `recvmsg` with a control buffer, because the
//! `OpenPipeWireRemote` reply carries a PipeWire connection file descriptor in
//! an `SCM_RIGHTS` control message. A plain `read` would discard the control
//! message and close the descriptor with it.
const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus.zig");

pub const Error = error{
    NoSessionBus,
    PortalUnavailable,
    PortalCallFailed,
    InvalidReply,
    /// The portal answered a `Start` call with no usable stream.
    NoStream,
    /// `OpenPipeWireRemote` answered without a file descriptor.
    NoFileDescriptor,
    /// The session bus went away mid-handshake.
    StreamDisconnected,
} || std.mem.Allocator.Error;

const portal_destination = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const request_prefix = "/org/freedesktop/portal/desktop/request/";

/// Largest message accepted from the bus. A portal reply is a few kilobytes;
/// the limit only exists so a corrupt header cannot request a huge allocation.
const max_message_bytes = 4 * 1024 * 1024;
const max_fds_per_message = 16;

/// Portal request results, as defined by `org.freedesktop.portal.Request`.
pub const ResponseCode = enum(u32) {
    success = 0,
    /// The user dismissed the chooser without choosing anything.
    canceled = 1,
    /// Anything else, including a refusal.
    other = 2,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

/// Extent of a stream as the compositor lays it out. The portal reports this
/// in the coordinate space of the compositor, which is not a pixel count, so
/// it need not match the frames the stream delivers.
pub const Size = struct {
    width: i32,
    height: i32,
};

/// `SelectSources` `cursor_mode`, in the values the portal accepts: one bit of
/// `AvailableCursorModes`. The portal refuses a value that is not a single
/// advertised bit, so these are the only values that reach it.
pub const CursorMode = enum(u32) {
    /// The cursor is not part of the stream.
    hidden = 1,
    /// The cursor is drawn into the delivered frames.
    embedded = 2,
    /// The cursor is left out of the frames and reported as stream metadata.
    metadata = 4,
};

/// One stream from a `Start` reply, taken from the `streams` array.
pub const StreamEntry = struct {
    node_id: u32 = 0,
    /// Portal-side identifier of the chosen source. An owned copy of what the
    /// reply carried, empty when the portal named the stream by no identifier.
    id: []u8 = "",
    /// Extent of the stream in compositor units, when the portal reports it.
    size: ?Size = null,
    /// `(x, y)` of the source origin, when the portal reports it.
    position: ?Point = null,
    /// Portal `SourceType` bit for this stream.
    source_type: u32 = 0,
};

/// Parsed `Response` signal.
///
/// Every string here is an owned copy. The message frame the values were read
/// from is released before the outcome is returned, so a result that pointed
/// into it would name memory that is gone.
pub const Outcome = struct {
    gpa: std.mem.Allocator,
    code: ResponseCode = .other,
    session_handle: ?[]u8 = null,
    streams: std.ArrayListUnmanaged(StreamEntry) = .empty,

    pub fn deinit(self: *Outcome) void {
        for (self.streams.items) |stream| {
            if (stream.id.len != 0) self.gpa.free(stream.id);
        }
        self.streams.deinit(self.gpa);
        self.streams = .empty;
        if (self.session_handle) |handle| self.gpa.free(handle);
        self.* = undefined;
    }

    pub fn isSuccess(self: *const Outcome) bool {
        return self.code == .success;
    }
};

/// Result of the `Start` handshake.
pub const StartResult = struct {
    outcome: Outcome,

    pub fn deinit(self: *StartResult) void {
        self.outcome.deinit();
        self.* = undefined;
    }

    /// The first stream the portal handed back. The portal always puts the
    /// chosen source first.
    pub fn primary(self: *const StartResult) ?StreamEntry {
        if (self.outcome.streams.items.len == 0) return null;
        return self.outcome.streams.items[0];
    }
};

/// One message read from the bus, together with the descriptors the kernel
/// attached to it.
///
/// The reply owns those descriptors. A caller can hold one reply while the
/// next message is read, so they cannot be a view of a frame that is gone by
/// then. The kernel attaches at most `max_fds_per_message` of them to one
/// message, so the set is fixed storage and no read allocates for it.
const Reply = struct {
    bytes: []u8,
    /// The descriptors this message carried, in the order the kernel attached
    /// them. `receive` is the only construction and it hands over the array it
    /// collected into, so there is no default here. `fd_count` is how much of
    /// it the kernel filled, and nothing reads past that.
    fds: [max_fds_per_message]std.posix.fd_t,
    fd_count: usize = 0,
    message: dbus.Message,

    pub fn fdCount(self: *const Reply) usize {
        return self.fd_count;
    }

    pub fn fd(self: *const Reply, index: usize) std.posix.fd_t {
        return self.fds[index];
    }

    /// Everything this message carried, for a caller that closes the set.
    pub fn descriptors(self: *const Reply) []const std.posix.fd_t {
        return self.fds[0..self.fd_count];
    }
};

/// A live portal ScreenCast conversation on its own bus connection.
///
/// The connection is private to the session, so a `Response` signal is never
/// confused with traffic from another feature.
pub const ScreenCast = struct {
    gpa: std.mem.Allocator,
    conn: dbus.Connection,
    open: bool = true,
    token_counter: u32 = 0,
    /// Connects to the session bus and says hello. The portal service is not
    /// contacted yet, so this never prompts anything.
    pub fn init(gpa: std.mem.Allocator) !ScreenCast {
        var env_buf: [4096]u8 = undefined;
        const addr = dbus.getEnvFromProc("DBUS_SESSION_BUS_ADDRESS", &env_buf) orelse {
            return error.NoSessionBus;
        };
        if (addr.len == 0) return error.NoSessionBus;

        const conn = dbus.Connection.connectSessionBus(gpa) catch {
            return error.PortalUnavailable;
        };
        return .{ .gpa = gpa, .conn = conn };
    }

    pub fn deinit(self: *ScreenCast) void {
        if (self.open) {
            self.open = false;
            self.conn.deinit();
        }
        self.* = undefined;
    }

    /// Asks the portal for a capture session handle.
    ///
    /// The interface documents two options here, the request token and the
    /// token the session handle is built from. It documents no application id:
    /// the portal takes the identity of the caller from the bus, so nothing
    /// this client can put in the body would change which application the
    /// permission is recorded against.
    pub fn createSession(self: *ScreenCast) !Outcome {
        var request_token_buf: [24]u8 = undefined;
        var session_token_buf: [24]u8 = undefined;
        const token = self.nextToken(&request_token_buf);
        const session_token = self.nextToken(&session_token_buf);
        var b = dbus.MessageBuilder.init(self.gpa, .method_call, self.conn.nextSerial());
        defer b.deinit();

        b.destination = portal_destination;
        b.path = portal_path;
        b.interface = "org.freedesktop.portal.ScreenCast";
        b.member = "CreateSession";
        b.signature = "a{sv}";

        const dict = try b.startArray(8);
        try writeDictString(&b, "handle_token", token);
        try writeDictString(&b, "session_handle_token", session_token);
        b.finishArray(dict);

        return self.call(token, &b);
    }

    /// Offers the source classes the user may pick from. The portal owns the
    /// concrete list, so nothing here names individual monitors or windows.
    ///
    /// A restore token belongs here and nowhere else: it is the token of an
    /// earlier session of this application, and `SelectSources` is the call
    /// that consumes it. `persist_mode` is the option that decides whether the
    /// portal hands one back.
    pub fn selectSources(
        self: *ScreenCast,
        session_handle: []const u8,
        sources: u32,
        multiple: bool,
        cursor_mode: CursorMode,
        persistence: u32,
        restore_token: ?[]const u8,
    ) !Outcome {
        var token_buf: [24]u8 = undefined;
        const token = self.nextToken(&token_buf);
        var b = dbus.MessageBuilder.init(self.gpa, .method_call, self.conn.nextSerial());
        defer b.deinit();

        b.destination = portal_destination;
        b.path = portal_path;
        b.interface = "org.freedesktop.portal.ScreenCast";
        b.member = "SelectSources";
        b.signature = "oa{sv}";

        try b.writeObjectPath(session_handle);
        const dict = try b.startArray(8);
        try writeDictString(&b, "handle_token", token);
        try writeDictUint32(&b, "types", sources);
        try writeDictBool(&b, "multiple", multiple);
        try writeDictUint32(&b, "cursor_mode", @intFromEnum(cursor_mode));
        if (restore_token) |t| try writeDictString(&b, "restore_token", t);
        try writeDictUint32(&b, "persist_mode", persistence);
        b.finishArray(dict);

        return self.call(token, &b);
    }

    /// Confirms the selection and receives the PipeWire node identifiers.
    ///
    /// The session and the window the chooser belongs to are arguments, and
    /// the options carry the request token and nothing else.
    pub fn start(
        self: *ScreenCast,
        session_handle: []const u8,
        parent_window: []const u8,
    ) !StartResult {
        var token_buf: [24]u8 = undefined;
        const token = self.nextToken(&token_buf);
        var b = dbus.MessageBuilder.init(self.gpa, .method_call, self.conn.nextSerial());
        defer b.deinit();

        b.destination = portal_destination;
        b.path = portal_path;
        b.interface = "org.freedesktop.portal.ScreenCast";
        b.member = "Start";
        b.signature = "osa{sv}";

        try b.writeObjectPath(session_handle);
        try b.writeString(parent_window);
        const dict = try b.startArray(8);
        try writeDictString(&b, "handle_token", token);
        b.finishArray(dict);

        return .{ .outcome = try self.call(token, &b) };
    }

    /// Asks for a connected PipeWire socket for the session. The caller owns
    /// the returned descriptor and must close it.
    ///
    /// The answer names which of the descriptors it carried is the socket, so
    /// a frame that brought others leaves them closed here.
    pub fn openPipeWireRemote(self: *ScreenCast, session_handle: []const u8) !std.posix.fd_t {
        const serial = self.conn.nextSerial();
        var b = dbus.MessageBuilder.init(self.gpa, .method_call, serial);
        defer b.deinit();

        b.destination = portal_destination;
        b.path = portal_path;
        b.interface = "org.freedesktop.portal.ScreenCast";
        b.member = "OpenPipeWireRemote";
        b.signature = "oa{sv}";

        try b.writeObjectPath(session_handle);
        // The interface documents no option for this call, and the descriptor
        // comes back on the reply rather than on a request object.
        const options = try b.startArray(8);
        b.finishArray(options);

        const wire = try b.build();
        defer self.gpa.free(wire);

        try self.send(wire);

        while (true) {
            const reply = try self.receive();
            defer self.gpa.free(reply.bytes);
            // The descriptor is handed to the caller, so it has to outlive this
            // function. Everything else is closed here, and the whole set is
            // closed whenever the answer is refused before ownership moves.
            var fds_owned = true;
            defer if (fds_owned) closeAll(reply.descriptors());

            if (reply.message.msg_type == .error_reply and
                reply.message.reply_serial == serial) return error.PortalCallFailed;
            if (reply.message.msg_type != .method_return) continue;
            // A return that answers another call is traffic this client did not
            // ask for, whatever it carried.
            if (reply.message.reply_serial != serial) continue;

            // An answer that named no descriptor is a refusal, not a handoff,
            // and a body that is not a handle index is a reply this client
            // cannot read.
            if (reply.message.body.len == 0) return error.NoFileDescriptor;
            var body = dbus.BodyReader.init(reply.message.body);
            const index = body.readU32() catch return error.InvalidReply;

            const handed = takeFd(reply.descriptors(), index) orelse return error.NoFileDescriptor;
            fds_owned = false;
            return handed;
        }
    }

    /// Sends one request and waits for the matching `Response` signal.
    fn call(self: *ScreenCast, token: []const u8, b: *dbus.MessageBuilder) !Outcome {
        const serial = b.serial;
        const wire = try b.build();
        defer self.gpa.free(wire);

        try self.send(wire);

        // The request path is derived from the token, so the signal is
        // recognised even if it arrives before the method return does.
        var sender_buf: [64]u8 = undefined;
        var path_buf: [192]u8 = undefined;
        const request_path = try std.fmt.bufPrint(
            &path_buf,
            "{s}{s}/{s}",
            .{ request_prefix, try self.senderName(&sender_buf), token },
        );

        while (true) {
            const reply = try self.receive();
            defer self.gpa.free(reply.bytes);
            defer closeAll(reply.descriptors());

            const msg = reply.message;
            if (msg.msg_type == .signal) {
                const member = msg.member orelse continue;
                if (!std.mem.eql(u8, member, "Response")) continue;
                const path = msg.path orelse continue;
                if (!std.mem.eql(u8, path, request_path)) continue;
                return parseResponse(self.gpa, msg.body);
            }
            // A method-level error answers the call it names, so an error for
            // another serial is traffic this client did not ask for.
            if (msg.msg_type == .error_reply and msg.reply_serial == serial) {
                return error.PortalCallFailed;
            }
        }
    }

    /// The next handle token, printed into a buffer the caller owns.
    ///
    /// A call holds its token until the request path derived from it is done,
    /// and one call can carry two of them, so no token is stored where a later
    /// one would overwrite it.
    fn nextToken(self: *ScreenCast, out: *[24]u8) []const u8 {
        self.token_counter +%= 1;
        // The prefix is five bytes and a `u32` prints at most ten digits, so
        // the token always fits. A fallback name here would put a request path
        // in front of the portal that it was never asked about.
        return std.fmt.bufPrint(out, "nogui{d}", .{self.token_counter}) catch
            @panic("portal handle token does not fit its buffer");
    }

    fn send(self: *ScreenCast, wire: []const u8) !void {
        if (!self.open) return error.StreamDisconnected;
        self.conn.sendRaw(wire) catch |err| switch (err) {
            error.ConnectionClosed => return error.StreamDisconnected,
            else => return err,
        };
    }

    /// Reads one whole D-Bus message, keeping any descriptors the kernel
    /// attached to it.
    ///
    /// The kernel installs a descriptor the moment it hands it over, so the
    /// set is cleaned up from the first byte: the guard below is armed before
    /// anything is read, which is what makes a frame refused on its marker or
    /// on its declared length close the descriptors it carried. What survives
    /// is moved into the reply, which owns it from then on.
    fn receive(self: *ScreenCast) !Reply {
        if (!self.open) return error.StreamDisconnected;
        const fd = self.conn.fd orelse return error.StreamDisconnected;

        var fds: [max_fds_per_message]std.posix.fd_t = undefined;
        var fd_count: usize = 0;
        errdefer closeAll(fds[0..fd_count]);

        var header: [16]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < header.len) {
            header_len += try recvChunk(fd, header[header_len..], &fds, &fd_count);
        }
        if (header[0] != 'l') return error.InvalidReply;

        // The two lengths are widened before they are added, because a peer
        // chooses them. Added in the width they arrive in, `16 + fields_len`
        // wraps for a header near the top of that range: a safe build traps
        // there, and a fast build wraps to a total small enough to pass the
        // limit below and then writes a full header into a buffer sized for
        // it. Neither outcome is a refusal, so the descriptors that arrived
        // beside that header are never released.
        const body_len: usize = std.mem.readInt(u32, header[4..8], .little);
        const fields_len: usize = std.mem.readInt(u32, header[12..16], .little);
        const fields_end = 16 + fields_len;
        const total = fields_end + dbus.padLen(fields_end, 8) + body_len;
        if (total > max_message_bytes) return error.InvalidReply;

        const full = try self.gpa.alloc(u8, total);
        errdefer self.gpa.free(full);
        @memcpy(full[0..16], &header);

        var filled: usize = 16;
        while (filled < total) {
            filled += try recvChunk(fd, full[filled..], &fds, &fd_count);
        }

        return .{
            .bytes = full,
            .fds = fds,
            .fd_count = fd_count,
            .message = dbus.MessageParser.parse(full) catch return error.InvalidReply,
        };
    }

    /// The bus unique name as it appears inside a portal request path.
    ///
    /// The Request spec drops the leading colon and replaces every dot with an
    /// underscore, because a request path is an object path and a dot is not a
    /// legal element of one. A connection with no unique name is not on the
    /// bus, so nothing it asked could be answered.
    fn senderName(self: *ScreenCast, out: []u8) ![]const u8 {
        const unique = self.conn.unique_name orelse return error.NoSessionBus;
        if (unique.len < 2 or unique[0] != ':' or unique.len - 1 > out.len) {
            return error.NoSessionBus;
        }
        for (unique[1..], 0..) |c, i| out[i] = if (c == '.') '_' else c;
        return out[0 .. unique.len - 1];
    }
};

/// Reads once from the bus, appending any `SCM_RIGHTS` descriptors to the set
/// being read. Descriptors the kernel attached but that do not fit are closed
/// right away so nothing leaks.
fn recvChunk(
    sock: std.posix.fd_t,
    buffer: []u8,
    fds: *[max_fds_per_message]std.posix.fd_t,
    fd_count: *usize,
) !usize {
    var control: [
        @sizeOf(linux.cmsghdr) + max_fds_per_message * @sizeOf(std.posix.fd_t)
    ]u8 align(@alignOf(linux.cmsghdr)) = undefined;

    var iov = [_]std.posix.iovec{.{ .base = buffer.ptr, .len = buffer.len }};
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };

    const rc = linux.recvmsg(sock, &msg, linux.MSG.CMSG_CLOEXEC);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR => return 0,
        .AGAIN => return waitReadable(sock),
        .CONNRESET, .PIPE, .BADF, .NOTCONN => return error.StreamDisconnected,
        else => return error.PortalCallFailed,
    }

    collectFds(control[0..msg.controllen], fds, fd_count);
    if (rc == 0) return error.StreamDisconnected;
    return rc;
}

fn collectFds(
    control: []align(@alignOf(linux.cmsghdr)) u8,
    out: *[max_fds_per_message]std.posix.fd_t,
    out_count: *usize,
) void {
    var offset: usize = 0;
    while (offset + @sizeOf(linux.cmsghdr) <= control.len) {
        const header: *const linux.cmsghdr = @ptrCast(@alignCast(control[offset..].ptr));
        if (header.len < @sizeOf(linux.cmsghdr)) break;
        const payload_end = @min(offset + header.len, control.len);

        if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.RIGHTS) {
            var payload = offset + @sizeOf(linux.cmsghdr);
            while (payload + @sizeOf(std.posix.fd_t) <= payload_end) {
                const received: std.posix.fd_t = @bitCast(
                    std.mem.readInt(u32, control[payload..][0..4], .little),
                );
                if (out_count.* < out.len) {
                    out[out_count.*] = received;
                    out_count.* += 1;
                } else {
                    _ = linux.close(received);
                }
                payload += @sizeOf(std.posix.fd_t);
            }
        }
        // Control messages are padded up to an eight byte boundary.
        offset = (offset + header.len + 7) & ~@as(usize, 7);
    }
}

fn closeAll(fds: []const std.posix.fd_t) void {
    for (fds) |fd| _ = linux.close(fd);
}

/// Moves the descriptor the answer named to the caller and closes the rest. An
/// answer that names a descriptor it did not carry names none this client can
/// use, and the caller still owns the whole set it refused.
fn takeFd(fds: []const std.posix.fd_t, index: usize) ?std.posix.fd_t {
    if (index >= fds.len) return null;
    const fd = fds[index];
    for (fds, 0..) |other, at| {
        if (at != index) _ = linux.close(other);
    }
    return fd;
}

fn waitReadable(sock: std.posix.fd_t) !usize {
    var pfd = [_]linux.pollfd{.{ .fd = sock, .events = linux.POLL.IN, .revents = 0 }};
    return switch (linux.errno(linux.poll(&pfd, 1, -1))) {
        .SUCCESS, .INTR => 0,
        else => error.PortalCallFailed,
    };
}

/// Writes one `a{sv}` entry. The entry is a struct, so it starts on an eight
/// byte boundary, and the key is a plain string.
fn beginDictEntry(b: *dbus.MessageBuilder, key: []const u8) !void {
    try b.padBody(8);
    try b.writeString(key);
}

/// Starts the variant of one entry: a length byte, the signature and a NUL. The
/// value follows and pads itself to the alignment its own type needs, which is
/// the only padding a reader of this message accounts for.
fn beginVariant(b: *dbus.MessageBuilder, sig: []const u8) !void {
    try b.writeSignature(sig);
}

fn writeDictString(b: *dbus.MessageBuilder, key: []const u8, value: []const u8) !void {
    try beginDictEntry(b, key);
    try beginVariant(b, "s");
    try b.writeString(value);
}

fn writeDictUint32(b: *dbus.MessageBuilder, key: []const u8, value: u32) !void {
    try beginDictEntry(b, key);
    try beginVariant(b, "u");
    try b.writeU32(value);
}

fn writeDictBool(b: *dbus.MessageBuilder, key: []const u8, value: bool) !void {
    try beginDictEntry(b, key);
    try beginVariant(b, "b");
    try b.writeBool(value);
}

/// An owned copy of a string a reply carried, or null when it carried none.
/// Nothing empty is copied, so every owned string has a length and a free that
/// matches the copy that made it.
fn ownString(gpa: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    if (bytes.len == 0) return null;
    const owned = try gpa.dupe(u8, bytes);
    return owned;
}

/// Allocate first so failure leaves the previous value available to cleanup.
fn replaceOwnedString(gpa: std.mem.Allocator, previous: ?[]u8, bytes: []const u8) !?[]u8 {
    const replacement = try ownString(gpa, bytes);
    if (previous) |owned| gpa.free(owned);
    return replacement;
}

fn parseResponse(gpa: std.mem.Allocator, body: []const u8) !Outcome {
    var out: Outcome = .{ .gpa = gpa };
    errdefer out.deinit();

    var r = dbus.BodyReader.init(body);
    out.code = switch (try r.readU32()) {
        0 => .success,
        1 => .canceled,
        else => .other,
    };

    const results = try r.readArray(8);
    var dr = dbus.BodyReader.init(results);
    while (dr.cursor < dr.bytes.len) {
        dr.alignStruct();
        if (dr.cursor >= dr.bytes.len) break;
        // A key is a string, and the value behind it is a variant.
        const key = try dr.readString();
        const variant = try dr.readSignature();

        if (std.mem.eql(u8, key, "session_handle")) {
            if (!std.mem.eql(u8, variant, "s")) return error.InvalidReply;
            out.session_handle = try replaceOwnedString(gpa, out.session_handle, try dr.readString());
        } else if (std.mem.eql(u8, key, "streams")) {
            if (!std.mem.eql(u8, variant, "a(ua{sv})")) return error.InvalidReply;
            try parseStreams(gpa, &out, &dr);
        } else if (!skipTypedValue(&dr, variant)) {
            // A result this build does not read is stepped over by its own
            // type, so a portal that adds one cannot hide the results behind
            // it. A value whose type cannot be walked at all is a reply this
            // build refuses rather than guesses at.
            return error.InvalidReply;
        }
    }
    return out;
}

fn parseStreams(gpa: std.mem.Allocator, out: *Outcome, r: *dbus.BodyReader) !void {
    const array = try r.readArray(8);
    var ar = dbus.BodyReader.init(array);
    while (ar.cursor < ar.bytes.len) {
        ar.alignStruct();
        if (ar.cursor >= ar.bytes.len) break;
        const stream = try parseStream(gpa, &ar);
        // A stream this build has taken and cannot keep is released here, so a
        // list that grew out of memory leaves nothing behind.
        errdefer if (stream.id.len != 0) gpa.free(stream.id);
        try out.streams.append(gpa, stream);
    }
}

/// One stream, with its identifier copied out and every property this build
/// reads taken at the type the specification gives it. A property it does not
/// read is stepped over by its own type, so one this build has never heard of
/// cannot hide the properties behind it.
fn parseStream(gpa: std.mem.Allocator, ar: *dbus.BodyReader) !StreamEntry {
    var entry: StreamEntry = .{ .node_id = try ar.readU32() };
    errdefer if (entry.id.len != 0) gpa.free(entry.id);

    const properties = try ar.readArray(8);
    var dr = dbus.BodyReader.init(properties);
    while (dr.cursor < dr.bytes.len) {
        dr.alignStruct();
        if (dr.cursor >= dr.bytes.len) break;
        const key = try dr.readString();
        const variant = try dr.readSignature();

        if (std.mem.eql(u8, key, "id")) {
            if (!std.mem.eql(u8, variant, "s")) return error.InvalidReply;
            entry.id = (try replaceOwnedString(
                gpa,
                if (entry.id.len == 0) null else entry.id,
                try dr.readString(),
            )) orelse "";
        } else if (std.mem.eql(u8, key, "size")) {
            // The extent of the stream in the coordinate space of the
            // compositor, which is not a pixel count of the frames.
            if (!std.mem.eql(u8, variant, "(ii)")) return error.InvalidReply;
            dr.alignStruct();
            entry.size = .{
                .width = try dr.readI32(),
                .height = try dr.readI32(),
            };
        } else if (std.mem.eql(u8, key, "position")) {
            if (!std.mem.eql(u8, variant, "(ii)")) return error.InvalidReply;
            dr.alignStruct();
            entry.position = .{
                .x = try dr.readI32(),
                .y = try dr.readI32(),
            };
        } else if (std.mem.eql(u8, key, "source_type")) {
            if (!std.mem.eql(u8, variant, "u")) return error.InvalidReply;
            entry.source_type = try dr.readU32();
        } else if (!skipTypedValue(&dr, variant)) {
            return error.InvalidReply;
        }
    }
    return entry;
}

/// The alignment a D-Bus type starts on, from its first character.
fn typeAlignment(signature: []const u8) usize {
    if (signature.len == 0) return 1;
    return switch (signature[0]) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

/// The length of the one complete type at the front of `signature`.
fn completeTypeLen(signature: []const u8) ?usize {
    if (signature.len == 0) return null;
    return switch (signature[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'v', 'h' => 1,
        'a' => 1 + (completeTypeLen(signature[1..]) orelse return null),
        '(', '{' => blk: {
            const close: u8 = if (signature[0] == '(') ')' else '}';
            var index: usize = 1;
            while (index < signature.len and signature[index] != close) {
                index += completeTypeLen(signature[index..]) orelse return null;
            }
            if (index >= signature.len) return null;
            break :blk index + 1;
        },
        else => null,
    };
}

/// Step over one value of a complete D-Bus type. A shape this walk cannot read
/// stops it rather than guessing at the bytes that follow, so a value neither
/// the results nor the parser understands is refused instead of hiding the
/// entries behind it.
fn skipTypedValue(reader: *dbus.BodyReader, signature: []const u8) bool {
    if (signature.len == 0) return false;
    return switch (signature[0]) {
        'y' => blk: {
            _ = reader.readByte() catch return false;
            break :blk true;
        },
        'n', 'q' => blk: {
            _ = reader.readU16() catch return false;
            break :blk true;
        },
        'b', 'i', 'u' => blk: {
            _ = reader.readU32() catch return false;
            break :blk true;
        },
        'x', 't', 'd' => blk: {
            _ = reader.readU64() catch return false;
            break :blk true;
        },
        's', 'o' => blk: {
            _ = reader.readString() catch return false;
            break :blk true;
        },
        'g' => blk: {
            _ = reader.readSignature() catch return false;
            break :blk true;
        },
        'v' => blk: {
            const nested = reader.readSignature() catch return false;
            break :blk skipTypedValue(reader, nested);
        },
        'a' => blk: {
            if (signature.len < 2) return false;
            const payload = reader.readArray(typeAlignment(signature[1..])) catch return false;
            var inner = dbus.BodyReader.init(payload);
            while (inner.cursor < inner.bytes.len) {
                if (!skipTypedValue(&inner, signature[1..])) return false;
            }
            break :blk true;
        },
        '(', '{' => blk: {
            const close: u8 = if (signature[0] == '(') ')' else '}';
            if (signature[signature.len - 1] != close) return false;
            reader.alignStruct();
            break :blk skipTypes(reader, signature[1 .. signature.len - 1]);
        },
        else => false,
    };
}

fn skipTypes(reader: *dbus.BodyReader, signatures: []const u8) bool {
    var rest = signatures;
    while (rest.len != 0) {
        const len = completeTypeLen(rest) orelse return false;
        if (!skipTypedValue(reader, rest[0..len])) return false;
        rest = rest[len..];
    }
    return true;
}

// -- Behavioural tests -------------------------------------------------------
// These drive the descriptor paths with real descriptors. The control buffer
// tests build one by hand, the rest cross a real socket. Nothing here opens a
// bus connection, so no portal is ever contacted and no chooser can appear.

const testing = std.testing;

fn openPipe() !std.posix.fd_t {
    var ends: [2]i32 = undefined;
    if (linux.errno(linux.pipe(&ends)) != .SUCCESS) return error.PipeFailed;
    _ = linux.close(ends[1]);
    return ends[0];
}

/// Closes the descriptor and reports whether it was open to begin with. Every
/// call site wants the descriptor gone afterwards, so a test that asks about
/// it twice cannot.
fn takeOpen(fd: std.posix.fd_t) bool {
    return linux.errno(linux.close(fd)) == .SUCCESS;
}

test "api-w20 the portal hands over the descriptor it names instead of closing it" {
    var opened = [_]std.posix.fd_t{ try openPipe(), try openPipe(), try openPipe() };
    const fds: []const std.posix.fd_t = &opened;

    // The answer names the second of the three, so the first and the third are
    // not the handoff and must not be left behind.
    const handed_over = takeFd(fds, 1).?;
    try testing.expect(takeOpen(handed_over));
    try testing.expectEqual(opened[1], handed_over);
    try testing.expect(!takeOpen(opened[0]));
    try testing.expect(!takeOpen(opened[2]));
    // An answer that names a descriptor it did not carry names none this
    // client can use, and the caller still owns the set it refused.
    try testing.expect(takeFd(&.{}, 0) == null);
    try testing.expect(takeFd(fds, fds.len) == null);
}

test "api-w20 a descriptor that does not fit the control buffer is closed" {
    var opened: [max_fds_per_message + 1]std.posix.fd_t = undefined;
    for (&opened) |*fd| fd.* = try openPipe();

    // The wire layout the kernel writes for `SCM_RIGHTS`, so the parser reads
    // the same bytes it would read off a real socket.
    const control_bytes = @sizeOf(linux.cmsghdr) + opened.len * @sizeOf(std.posix.fd_t);
    var control: [control_bytes]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const header: *linux.cmsghdr = @ptrCast(&control);
    header.* = .{
        .len = control_bytes,
        .level = linux.SOL.SOCKET,
        .type = linux.SCM.RIGHTS,
    };
    for (opened, 0..) |fd, index| {
        const at = @sizeOf(linux.cmsghdr) + index * @sizeOf(std.posix.fd_t);
        std.mem.writeInt(u32, control[at..][0..4], @bitCast(fd), .little);
    }

    var kept: [max_fds_per_message]std.posix.fd_t = undefined;
    var count: usize = 0;
    collectFds(&control, &kept, &count);

    try testing.expectEqual(max_fds_per_message, count);
    for (kept) |fd| try testing.expect(takeOpen(fd));
    try testing.expect(!takeOpen(opened[opened.len - 1]));
}

// -- Descriptor lifetime regressions ---------------------------------------
// A socket pair is the whole portal stand-in: real D-Bus frames and real
// `SCM_RIGHTS` descriptors cross a real Unix socket, and the kernel installs
// each one into the lowest free descriptor number, so what a frame brings and
// what a refused frame leaves behind can both be named exactly.

/// One bus pair with a conversation on the near end. Every case takes its own
/// pair: a frame the reader refuses is never drained, and the bytes left on
/// that socket would be read back as the header of the next case.
const Conversation = struct {
    screen: ScreenCast,
    portal_end: std.posix.fd_t,

    fn init() !Conversation {
        return conversationOn(testing.allocator);
    }

    fn deinit(self: *Conversation) void {
        self.screen.deinit();
        _ = linux.close(self.portal_end);
        // Both ends of the pair are closed and the connection is gone, so
        // nothing here names a live descriptor; the value is poisoned rather
        // than left looking like a conversation that could still be read.
        self.* = undefined;
    }
};

/// One bus pair whose client runs on `gpa`, for a case that has to see what the
/// client does with memory it releases.
fn conversationOn(gpa: std.mem.Allocator) !Conversation {
    var ends: [2]i32 = undefined;
    const rc = linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &ends);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    return .{
        .screen = .{
            .gpa = gpa,
            .conn = dbus.Connection.initCustom(gpa, ends[0]),
        },
        .portal_end = ends[1],
    };
}

/// One frame as the portal puts it on the bus: the same builder the real
/// handshake uses, answering the request of that serial.
fn busReply(msg_type: dbus.MessageType, serial: u32) ![]u8 {
    var b = dbus.MessageBuilder.init(testing.allocator, msg_type, serial);
    defer b.deinit();
    b.reply_serial = serial;
    return b.build();
}

/// Sends one frame, with the descriptors the kernel has to copy to the reader
/// attached to its first bytes. A control message belongs to the bytes it was
/// sent beside, so a partial write must not carry a second copy of them.
fn sendFrame(sock: std.posix.fd_t, frame: []const u8, fds: []const std.posix.fd_t) !void {
    var control: [
        @sizeOf(linux.cmsghdr) + max_fds_per_message * @sizeOf(std.posix.fd_t)
    ]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    @memset(&control, 0);

    var sent: usize = 0;
    while (sent < frame.len) {
        var iov = [_]std.posix.iovec_const{.{ .base = frame[sent..].ptr, .len = frame.len - sent }};
        var msg: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = 0,
            .flags = 0,
        };
        if (sent == 0 and fds.len != 0) {
            const cmsg_len = @sizeOf(linux.cmsghdr) + fds.len * @sizeOf(std.posix.fd_t);
            const header: *linux.cmsghdr = @ptrCast(&control);
            header.* = .{
                .len = cmsg_len,
                .level = linux.SOL.SOCKET,
                .type = linux.SCM.RIGHTS,
            };
            for (fds, 0..) |fd, index| {
                const at = @sizeOf(linux.cmsghdr) + index * @sizeOf(std.posix.fd_t);
                std.mem.writeInt(u32, control[at..][0..4], @bitCast(fd), .little);
            }
            msg.controllen = cmsg_len;
        }

        const rc = linux.sendmsg(sock, &msg, 0);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return error.SendFailed;
        sent += rc;
    }
}

/// A pipe whose writer stays open holding `tag`, so a descriptor that kept
/// its identity still reads back the byte only that pipe ever carried.
fn openTaggedPipe(tag: u8) ![2]std.posix.fd_t {
    var ends: [2]i32 = undefined;
    if (linux.errno(linux.pipe(&ends)) != .SUCCESS) return error.PipeFailed;
    const one = [_]u8{tag};
    const written = linux.write(ends[1], &one, 1);
    if (linux.errno(written) != .SUCCESS or written != 1) return error.PipeWriteFailed;
    return ends;
}

fn readTag(fd: std.posix.fd_t) !u8 {
    var one: [1]u8 = undefined;
    const read = linux.read(fd, &one, 1);
    if (linux.errno(read) != .SUCCESS or read != 1) return error.PipeReadFailed;
    return one[0];
}

/// One reply, taken through a single call site. Two replies read that way
/// land in the same frame, so a reply that only pointed into one could not
/// still own its descriptors after the next read.
fn readReply(screen: *ScreenCast) !Reply {
    return screen.receive();
}

/// The descriptor numbers the kernel hands out next, which are the lowest
/// free ones. `fcntl` reports a free number without claiming it, so probing
/// cannot change what the read after it receives.
fn nextFreeFds(comptime count: usize, out: *[count]std.posix.fd_t) void {
    var found: usize = 0;
    var candidate: std.posix.fd_t = 0;
    while (found < count) : (candidate += 1) {
        if (linux.errno(linux.fcntl(candidate, linux.F.GETFD, 0)) == .BADF) {
            out[found] = candidate;
            found += 1;
        }
    }
}

const portal_session = "/org/freedesktop/portal/desktop/session/nogui1";

test "api-w20 two retained replies keep their own descriptors" {
    var bus = try Conversation.init();
    defer bus.deinit();

    const first_pipe = try openTaggedPipe('1');
    const second_pipe = try openTaggedPipe('2');
    defer {
        _ = linux.close(first_pipe[1]);
        _ = linux.close(second_pipe[1]);
    }

    const first_frame = try busReply(.method_return, 11);
    defer testing.allocator.free(first_frame);
    try sendFrame(bus.portal_end, first_frame, first_pipe[0..1]);

    const second_frame = try busReply(.method_return, 12);
    defer testing.allocator.free(second_frame);
    try sendFrame(bus.portal_end, second_frame, second_pipe[0..1]);

    // The portal side is done with both descriptors once they are on the wire.
    _ = linux.close(first_pipe[0]);
    _ = linux.close(second_pipe[0]);

    const first = try readReply(&bus.screen);
    defer {
        testing.allocator.free(first.bytes);
        closeAll(first.descriptors());
    }
    const second = try readReply(&bus.screen);
    defer {
        testing.allocator.free(second.bytes);
        closeAll(second.descriptors());
    }

    try testing.expectEqual(@as(usize, 1), first.fdCount());
    try testing.expectEqual(@as(usize, 1), second.fdCount());
    try testing.expect(first.fd(0) != second.fd(0));

    // The later read must not have retargeted the earlier reply: each
    // descriptor still reads the byte only its own pipe ever carried.
    try testing.expectEqual(@as(u8, '2'), try readTag(second.fd(0)));
    try testing.expectEqual(@as(u8, '1'), try readTag(first.fd(0)));
}

test "api-w20 a frame with no D-Bus marker closes every descriptor it carried" {
    var bus = try Conversation.init();
    defer bus.deinit();

    const carried = try openTaggedPipe('1');
    const spare = try openTaggedPipe('2');
    defer {
        _ = linux.close(carried[0]);
        _ = linux.close(spare[0]);
        _ = linux.close(carried[1]);
        _ = linux.close(spare[1]);
    }

    // Real bytes the reader has to refuse: the endianness marker is not one a
    // D-Bus frame ever carries, and both descriptors are already attached to
    // those bytes by the time the reader looks at them.
    const frame = try busReply(.method_return, 21);
    defer testing.allocator.free(frame);
    frame[0] = 'X';
    try sendFrame(bus.portal_end, frame, &.{ carried[0], spare[0] });

    // The kernel installs each descriptor of the frame into the lowest free
    // numbers, so the two it brings are named before the read happens.
    var arriving: [2]std.posix.fd_t = undefined;
    nextFreeFds(2, &arriving);
    try testing.expectError(error.InvalidReply, bus.screen.receive());
    // A frame the reader refuses owns nothing, so both of them are gone again.
    for (arriving) |fd| try testing.expect(!takeOpen(fd));
}

test "api-w20 an oversized frame closes every descriptor it carried" {
    var bus = try Conversation.init();
    defer bus.deinit();

    const carried = try openTaggedPipe('1');
    const spare = try openTaggedPipe('2');
    defer {
        _ = linux.close(carried[0]);
        _ = linux.close(spare[0]);
        _ = linux.close(carried[1]);
        _ = linux.close(spare[1]);
    }

    // A frame that declares more than any reply could carry is refused on its
    // declared length, before its body is read, and the descriptors that came
    // in beside its header have to go with it.
    const frame = try busReply(.method_return, 22);
    defer testing.allocator.free(frame);
    std.mem.writeInt(u32, frame[4..8], max_message_bytes, .little);
    try sendFrame(bus.portal_end, frame, &.{ carried[0], spare[0] });

    var arriving: [2]std.posix.fd_t = undefined;
    nextFreeFds(2, &arriving);
    try testing.expectError(error.InvalidReply, bus.screen.receive());
    // A frame refused on its declared length owns nothing either.
    for (arriving) |fd| try testing.expect(!takeOpen(fd));
}

test "api-w20 a frame whose lengths wrap their own arithmetic releases every descriptor it carried" {
    var bus = try Conversation.init();
    defer bus.deinit();

    const carried = try openTaggedPipe('1');
    const spare = try openTaggedPipe('2');
    defer {
        _ = linux.close(carried[0]);
        _ = linux.close(spare[0]);
        _ = linux.close(carried[1]);
        _ = linux.close(spare[1]);
    }

    // Both lengths are near the top of the range they arrive in, so the frame
    // size has to be computed where that addition cannot wrap. Added in the
    // width the wire carries, the sum of a sixteen byte header and this field
    // length is zero, which passes the size limit and then has the reader write
    // a whole header into a buffer sized for nothing. Either outcome leaves
    // the descriptors that arrived beside that header behind, so what this
    // proves is the release, not only that the frame was refused.
    const frame = try busReply(.method_return, 23);
    defer testing.allocator.free(frame);
    std.mem.writeInt(u32, frame[4..8], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, frame[12..16], std.math.maxInt(u32) - 8, .little);
    try sendFrame(bus.portal_end, frame, &.{ carried[0], spare[0] });

    var arriving: [2]std.posix.fd_t = undefined;
    nextFreeFds(2, &arriving);
    try testing.expectError(error.InvalidReply, bus.screen.receive());
    // The refusal happened on the declared lengths, before a byte of body was
    // read, so the two descriptors the kernel installed are gone again.
    for (arriving) |fd| try testing.expect(!takeOpen(fd));
}

/// The answer a portal sends for `OpenPipeWireRemote`: a method return whose
/// body names which of the descriptors it carried is the PipeWire socket.
fn fdAnswer(serial: u32, index: u32) ![]u8 {
    var b = dbus.MessageBuilder.init(testing.allocator, .method_return, serial);
    defer b.deinit();
    b.reply_serial = serial;
    b.signature = "h";
    try b.writeU32(index);
    return b.build();
}

test "api-w20 an error answer hands back no descriptor and keeps none" {
    var bus = try Conversation.init();
    defer bus.deinit();

    const kept = try openTaggedPipe('1');
    const spare = try openTaggedPipe('2');
    defer {
        _ = linux.close(kept[0]);
        _ = linux.close(spare[0]);
        _ = linux.close(kept[1]);
        _ = linux.close(spare[1]);
    }

    // An error answer that still arrived with descriptors: neither of them
    // belongs to a caller that was handed a PipeWire socket.
    const serial = bus.screen.conn.serial;
    const failure = try busReply(.error_reply, serial);
    defer testing.allocator.free(failure);
    try sendFrame(bus.portal_end, failure, &.{ kept[0], spare[0] });

    var arriving: [2]std.posix.fd_t = undefined;
    nextFreeFds(2, &arriving);
    try testing.expectError(
        error.PortalCallFailed,
        bus.screen.openPipeWireRemote(portal_session),
    );
    for (arriving) |fd| try testing.expect(!takeOpen(fd));
}

test "api-w20 traffic that answers no call is stepped over and releases its descriptors" {
    var bus = try Conversation.init();
    defer bus.deinit();

    const kept = try openTaggedPipe('1');
    const spare = try openTaggedPipe('2');
    defer {
        _ = linux.close(kept[0]);
        _ = linux.close(spare[0]);
        _ = linux.close(kept[1]);
        _ = linux.close(spare[1]);
    }

    // A signal is not an answer to a method call, so the client reads past it
    // and releases what it carried. The error that follows answers the call the
    // client actually made.
    const serial = bus.screen.conn.serial;
    const signal = try busReply(.signal, serial);
    defer testing.allocator.free(signal);
    try sendFrame(bus.portal_end, signal, &.{ kept[0], spare[0] });

    const refusal = try busReply(.error_reply, serial);
    defer testing.allocator.free(refusal);
    try sendFrame(bus.portal_end, refusal, &.{});

    var arriving: [2]std.posix.fd_t = undefined;
    nextFreeFds(2, &arriving);
    try testing.expectError(
        error.PortalCallFailed,
        bus.screen.openPipeWireRemote(portal_session),
    );
    for (arriving) |fd| try testing.expect(!takeOpen(fd));
}

test "api-w20 an answer that names no descriptor is a refusal" {
    var bus = try Conversation.init();
    defer bus.deinit();

    // An answer with neither a body nor a descriptor names no handoff.
    const bare = try busReply(.method_return, bus.screen.conn.serial);
    defer testing.allocator.free(bare);
    try sendFrame(bus.portal_end, bare, &.{});

    try testing.expectError(
        error.NoFileDescriptor,
        bus.screen.openPipeWireRemote(portal_session),
    );

    // A body naming a descriptor the answer did not carry names none this
    // client can use either.
    const beyond = try fdAnswer(bus.screen.conn.serial, 3);
    defer testing.allocator.free(beyond);
    try sendFrame(bus.portal_end, beyond, &.{});

    try testing.expectError(
        error.NoFileDescriptor,
        bus.screen.openPipeWireRemote(portal_session),
    );
}

test "api-w20 the pipewire answer hands over the descriptor it names and closes the rest" {
    var bus = try Conversation.init();
    defer bus.deinit();

    const foreign = try openTaggedPipe('x');
    const kept = try openTaggedPipe('1');
    const spare = try openTaggedPipe('2');
    defer {
        _ = linux.close(foreign[1]);
        _ = linux.close(kept[1]);
        _ = linux.close(spare[1]);
    }

    // A return that answers another call arrives first and brings a descriptor
    // of its own, which is not this client's to keep.
    const serial = bus.screen.conn.serial;
    const elsewhere = try fdAnswer(serial +% 100, 0);
    defer testing.allocator.free(elsewhere);
    try sendFrame(bus.portal_end, elsewhere, &.{foreign[0]});

    // The answer to this call names the second of the two it carried.
    const answer = try fdAnswer(serial, 1);
    defer testing.allocator.free(answer);
    try sendFrame(bus.portal_end, answer, &.{ kept[0], spare[0] });
    _ = linux.close(foreign[0]);
    _ = linux.close(kept[0]);
    _ = linux.close(spare[0]);

    const handed = try bus.screen.openPipeWireRemote(portal_session);
    defer _ = linux.close(handed);
    try testing.expectEqual(@as(u8, '2'), try readTag(handed));

    // Received descriptor numbers can be reused between replies. The original
    // write endpoints instead prove which underlying pipes still have readers.
    for ([_]std.posix.fd_t{ foreign[1], kept[1], spare[1] }, 0..) |writer, index| {
        var probe = [_]linux.pollfd{.{ .fd = writer, .events = linux.POLL.OUT, .revents = 0 }};
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.poll(&probe, 1, 0)));
        try testing.expectEqual(index != 2, probe[0].revents & linux.POLL.ERR != 0);
    }
}

test "api-w20 a refused pipewire handoff releases the descriptors the refusal carried and nothing else" {
    // The whole sequence the provider runs, over one socket pair: a session is
    // created and named, and only then is the descriptor handoff refused. The
    // refusal is the last thing that happens, so everything the earlier calls
    // took must still be intact afterwards and everything the refusal took must
    // be gone. A client that conflated the two would release the handle of a
    // live session here, or hand back a descriptor it never owned.
    var gate: PoisonAllocator = .{ .back = testing.allocator };
    defer gate.release();
    var bus = try conversationOn(gate.allocator());
    defer bus.deinit();
    try nameAs(&bus);

    var handle: []const u8 = "/org/freedesktop/portal/desktop/session/nogui_w20_seq";
    var portal: Portal = .{
        .sock = bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .write = writeSessionHandle, .context = @ptrCast(&handle) } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };

    // The session is created first, so its handle is an owned copy by the time
    // the refusal below arrives. It is read after the refusal to prove the
    // refusal released only what it had received itself.
    var exchange = try converse(&bus, &portal, createCall, null);
    defer exchange.deinit();
    if (portal.failure) |err| return err;
    try testing.expect(exchange.refused == null);
    const created = exchange.started.?;
    try testing.expectEqualStrings(handle, created.outcome.session_handle.?);

    const kept = try openTaggedPipe('1');
    const spare = try openTaggedPipe('2');
    defer {
        _ = linux.close(kept[0]);
        _ = linux.close(spare[0]);
        _ = linux.close(kept[1]);
        _ = linux.close(spare[1]);
    }

    // The refusal carries two descriptors. It is the last frame the client
    // reads, so nothing after it in the loop can release them either.
    const serial = bus.screen.conn.serial;
    const refusal = try busReply(.error_reply, serial);
    defer testing.allocator.free(refusal);
    try sendFrame(bus.portal_end, refusal, &.{ kept[0], spare[0] });

    var arriving: [2]std.posix.fd_t = undefined;
    nextFreeFds(2, &arriving);
    try testing.expectError(
        error.PortalCallFailed,
        bus.screen.openPipeWireRemote(created.outcome.session_handle.?),
    );

    // Exactly what the refusal received is released: both descriptors the
    // kernel installed beside that frame, named by the numbers it would have
    // handed out.
    for (arriving) |fd| try testing.expect(!takeOpen(fd));

    // And nothing else: the session the earlier call created is still named by
    // an owned copy, still readable, and still the caller's to release. A
    // refusal that released the whole connection instead would have taken the
    // handle with it, and this read would be reading released memory.
    try testing.expect(bus.screen.conn.fd != null);
    try testing.expectEqualStrings(handle, created.outcome.session_handle.?);
    try testing.expect(bus.screen.open);
}

// -- Portal stand-in ---------------------------------------------------------
// A real portal answers the request it is given, on the request path its
// handle token names. The stand-in does the same over a socket pair: it reads
// the frame the client built, answers it the way the specification describes,
// and keeps the request bytes so a test reads the same frame that went on the
// wire.
//
// Every conversation ends with an error on the request's own serial. A client
// that recognized the answer never reaches it, and a client that did not is
// refused instead of waiting for a frame that will not come, so no case in
// this file can block on a socket.

/// Largest request frame a stand-in keeps. A ScreenCast request is a path, a
/// window id and a handful of options.
const max_request_bytes = 4096;

/// Options one ScreenCast request carries, which bounds what a test reads
/// back.
const max_request_options = 12;

/// The unique bus name every case answers as. It carries a dot, because the
/// request path the Request spec predicts replaces dots with underscores and
/// a case that cannot tell the two apart proves nothing.
const bus_unique_name = ":1.42";

/// Writes the body of a frame the stand-in sends: the results dictionary of a
/// `Response`, or the body of a method return.
const BodyWriter = *const fn (context: *anyopaque, builder: *dbus.MessageBuilder) anyerror!void;

/// The `Response` signal a portal sends once for a request.
const ResponseAnswer = struct {
    code: u32 = 0,
    write: BodyWriter,
    context: *anyopaque,
};

/// What a stand-in answers with. Every call a portal takes as a request ends in
/// a `Response` signal on the request path, and the answers to plain method
/// calls are written straight onto the bus by the cases that drive them.
const Answer = struct {
    response: ?ResponseAnswer = null,
};

const Portal = struct {
    sock: std.posix.fd_t,
    /// The unique bus name the request path is built from, leading colon and
    /// all: the Request spec drops the colon and turns dots into underscores.
    sender: []const u8,
    answer: Answer,
    /// The frame the client sent, filled in by `answerRequest` before any of
    /// it is read: `request_len` is the only thing that makes a byte of this
    /// buffer readable, so it stays at zero until the read moves it.
    request: [max_request_bytes]u8,
    request_len: usize = 0,
    /// What the stand-in could not do. A portal that cannot answer fails the
    /// call rather than leaving the client waiting for it.
    failure: ?anyerror = null,

    fn run(self: *Portal) void {
        self.answerRequest() catch |err| {
            self.failure = err;
        };
    }

    /// The request the client sent, parsed the way a portal parses it.
    fn requestMessage(self: *const Portal) !dbus.Message {
        if (self.request_len == 0) return error.NoRequest;
        return dbus.MessageParser.parse(self.request[0..self.request_len]);
    }

    fn answerRequest(self: *Portal) !void {
        const frame = try readBusFrame(self.sock, &self.request);
        self.request_len = frame.len;
        const message = try dbus.MessageParser.parse(frame);
        defer self.closeWithError(message.serial) catch |err| {
            self.failure = err;
        };

        if (self.answer.response) |response| {
            var path_buf: [192]u8 = undefined;
            const path = try self.requestPath(try handleTokenOf(message), &path_buf);
            try self.sendResponse(path, response);
        }
    }

    fn sendResponse(self: *Portal, path: []const u8, response: ResponseAnswer) !void {
        var b = dbus.MessageBuilder.init(testing.allocator, .signal, 0);
        defer b.deinit();
        b.path = path;
        b.interface = "org.freedesktop.portal.Request";
        b.member = "Response";
        b.signature = "ua{sv}";
        try b.writeU32(response.code);
        const results = try b.startArray(8);
        try response.write(response.context, &b);
        b.finishArray(results);
        try self.send(&b, &.{});
    }

    /// The last frame of every conversation, for the reason in the section
    /// note above.
    fn closeWithError(self: *Portal, serial: u32) !void {
        var b = dbus.MessageBuilder.init(testing.allocator, .error_reply, 0);
        defer b.deinit();
        b.error_name = "org.freedesktop.portal.Error.Failed";
        b.reply_serial = serial;
        try self.send(&b, &.{});
    }

    fn send(self: *Portal, b: *dbus.MessageBuilder, fds: []const std.posix.fd_t) !void {
        const wire = try b.build();
        defer testing.allocator.free(wire);
        try sendFrame(self.sock, wire, fds);
    }

    /// The request path the Request spec predicts: the caller's unique name
    /// with the leading colon dropped and every dot an underscore, because a
    /// request path is an object path and a dot is not a legal element of one.
    fn requestPath(self: *const Portal, token: []const u8, out: *[192]u8) ![]const u8 {
        var sender: [64]u8 = undefined;
        const name = self.sender;
        if (name.len < 2 or name[0] != ':' or name.len - 1 > sender.len) return error.NotABusName;
        for (name[1..], 0..) |c, i| sender[i] = if (c == '.') '_' else c;
        return std.fmt.bufPrint(out, "{s}{s}/{s}", .{ request_prefix, sender[0 .. name.len - 1], token });
    }
};

/// Reads one whole frame off the socket into `buffer`, the way the client
/// reads one: the header first, then the length that header declares.
fn readBusFrame(sock: std.posix.fd_t, buffer: []u8) ![]u8 {
    if (buffer.len < 16) return error.FrameTooBig;
    var filled: usize = 0;
    while (filled < 16) filled += try readChunk(sock, buffer[filled..16]);
    if (buffer[0] != 'l') return error.NotAFrame;

    const body_len = std.mem.readInt(u32, buffer[4..8], .little);
    const fields_len = std.mem.readInt(u32, buffer[12..16], .little);
    const total = 16 + fields_len + dbus.padLen(16 + fields_len, 8) + body_len;
    if (total > buffer.len) return error.FrameTooBig;
    while (filled < total) filled += try readChunk(sock, buffer[filled..total]);
    return buffer[0..total];
}

fn readChunk(sock: std.posix.fd_t, into: []u8) !usize {
    const rc = linux.read(sock, into.ptr, into.len);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR => return 0,
        else => return error.ReadFailed,
    }
    if (rc == 0) return error.PeerClosed;
    return rc;
}

/// One `a{sv}` entry of a request, read the way a portal reads one: the key is
/// a string, and the value is a variant.
const RequestOption = struct {
    key: []const u8,
    signature: []const u8,
    /// The reader sitting on the value, so a test reads it as its own type.
    value: dbus.BodyReader,
};

/// Every option of a request, in the order the client wrote them.
fn requestOptions(message: dbus.Message, out: *[max_request_options]RequestOption) !usize {
    const signature = message.signature orelse return error.NoSignature;
    var reader = dbus.BodyReader.init(message.body);
    var count: usize = 0;
    var rest = signature;
    while (rest.len != 0) {
        const len = completeTypeLen(rest) orelse return error.BadSignature;
        if (std.mem.eql(u8, rest[0..len], "a{sv}")) {
            const dict = try reader.readArray(8);
            var entries = dbus.BodyReader.init(dict);
            while (entries.cursor < dict.len) {
                entries.alignStruct();
                if (entries.cursor >= dict.len) break;
                if (count == out.len) return error.TooManyOptions;
                out[count] = .{
                    .key = try entries.readString(),
                    .signature = try entries.readSignature(),
                    .value = entries,
                };
                count += 1;
                if (!skipTypedValue(&entries, out[count - 1].signature)) return error.BadValue;
            }
        } else if (!skipTypedValue(&reader, rest[0..len])) {
            return error.BadValue;
        }
        rest = rest[len..];
    }
    return count;
}

/// The `handle_token` the request carried, or null when the body spells none
/// out. A portal builds the request path it answers on from this value.
fn handleTokenOf(message: dbus.Message) ![]const u8 {
    var options: [max_request_options]RequestOption = undefined;
    const count = try requestOptions(message, &options);
    for (options[0..count]) |*option| {
        if (!std.mem.eql(u8, option.key, "handle_token")) continue;
        if (!std.mem.eql(u8, option.signature, "s")) return error.BadHandleToken;
        return option.value.readString();
    }
    return error.NoHandleToken;
}

/// Starts one `a{sv}` entry: an entry is a struct, so it starts 8-aligned,
/// then the key, then the variant signature. The value that follows pads
/// itself to the alignment its own type needs.
fn putOptionKey(b: *dbus.MessageBuilder, key: []const u8, signature: []const u8) !void {
    try b.startStruct();
    try b.writeString(key);
    try b.writeSignature(signature);
}

/// One stream as a `Start` reply spells it.
const StreamPlan = struct {
    node_id: u32,
    id: []const u8,
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    source_type: u32,
};

fn writeStream(b: *dbus.MessageBuilder, plan: StreamPlan) !void {
    try b.startStruct();
    try b.writeU32(plan.node_id);
    const properties = try b.startArray(8);
    // The two properties a v6 portal added come first and in an order no
    // reader may assume, so a build that only knows the older ones still has
    // to reach the values behind them.
    try putOptionKey(b, "pipewire-serial", "t");
    try b.writeU64(0x0102_0304_0506_0708);
    try putOptionKey(b, "mapping_id", "s");
    try b.writeString("mapping");
    try putOptionKey(b, "id", "s");
    try b.writeString(plan.id);
    // Size is the extent of the stream in the coordinate space of the
    // compositor, which is not a pixel count.
    try putOptionKey(b, "size", "(ii)");
    try b.startStruct();
    try b.writeI32(plan.width);
    try b.writeI32(plan.height);
    try putOptionKey(b, "position", "(ii)");
    try b.startStruct();
    try b.writeI32(plan.x);
    try b.writeI32(plan.y);
    try putOptionKey(b, "source_type", "u");
    try b.writeU32(plan.source_type);
    b.finishArray(properties);
}

/// The `streams` of a `Start` reply: every source a chooser that allows
/// multiple selection hands back.
fn writeStreams(context: *anyopaque, b: *dbus.MessageBuilder) anyerror!void {
    const plans = @as(*const []const StreamPlan, @ptrCast(@alignCast(context))).*;
    try putOptionKey(b, "streams", "a(ua{sv})");
    const list = try b.startArray(8);
    for (plans) |plan| try writeStream(b, plan);
    b.finishArray(list);
}

/// The `streams` of a reply that types a documented property wrongly: the
/// first stream is complete, and the second spells `size` as a four-tuple the
/// specification does not give it.
fn writeMalformedStreams(context: *anyopaque, b: *dbus.MessageBuilder) anyerror!void {
    const plans = @as(*const []const StreamPlan, @ptrCast(@alignCast(context))).*;
    try putOptionKey(b, "streams", "a(ua{sv})");
    const list = try b.startArray(8);
    try writeStream(b, plans[0]);
    try b.startStruct();
    try b.writeU32(plans[1].node_id);
    const properties = try b.startArray(8);
    try putOptionKey(b, "id", "s");
    try b.writeString(plans[1].id);
    try putOptionKey(b, "size", "(iiii)");
    try b.startStruct();
    try b.writeI32(plans[1].x);
    try b.writeI32(plans[1].y);
    try b.writeI32(plans[1].width);
    try b.writeI32(plans[1].height);
    b.finishArray(properties);
    b.finishArray(list);
}

/// No results at all, which is what every request but `Start` answers with.
fn writeNoResults(_: *anyopaque, _: *dbus.MessageBuilder) anyerror!void {}

/// The message a portal names when it ends an interaction another way.
fn writeErrorMessage(context: *anyopaque, b: *dbus.MessageBuilder) anyerror!void {
    const reason = @as(*const []const u8, @ptrCast(@alignCast(context))).*;
    try putOptionKey(b, "error", "s");
    try b.writeString(reason);
}

/// The session handle a portal answers `CreateSession` with.
fn writeSessionHandle(context: *anyopaque, b: *dbus.MessageBuilder) anyerror!void {
    const handle = @as(*const []const u8, @ptrCast(@alignCast(context))).*;
    try putOptionKey(b, "session_handle", "s");
    try b.writeString(handle);
}

/// The option a request carried under `key`, or null when it carried none.
fn findOption(options: []const RequestOption, key: []const u8) ?RequestOption {
    for (options) |option| {
        if (std.mem.eql(u8, option.key, key)) return option;
    }
    return null;
}

/// Names the connection the way a bus does, so the request path a portal
/// predicts from that name is one a case can answer on.
fn nameAs(bus: *Conversation) !void {
    bus.screen.conn.unique_name = try testing.allocator.dupe(u8, bus_unique_name);
}

/// The byte a release fills, so a result that only borrowed the reply frame
/// reads back as something no portal said.
const poison_byte: u8 = 0xdb;

/// Released blocks one case can leave behind, which is every allocation the
/// handshake makes and every growth of them.
const max_held_blocks = 64;

/// Fills every block the client releases with a poison byte and keeps it, so a
/// result that only borrowed the reply frame reads back as poison instead of
/// as whatever the allocator did with that memory, and the bytes a case reads
/// are still mapped when it reads them. The blocks go back to the parent
/// allocator when the gate is released, so a leak is still a leak.
const PoisonAllocator = struct {
    back: std.mem.Allocator,
    held: [max_held_blocks]?Held = @splat(null),
    released: usize = 0,

    const Held = struct {
        memory: []u8,
        alignment: std.mem.Alignment,
    };

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Hands the kept blocks back, which a case does once it has read what it
    /// came for.
    fn release(self: *PoisonAllocator) void {
        for (&self.held) |*slot| {
            const block = slot.* orelse continue;
            slot.* = null;
            self.back.rawFree(block.memory, block.alignment, @returnAddress());
        }
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.back.rawAlloc(len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.back.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.back.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        self.released += 1;
        @memset(memory, poison_byte);
        for (&self.held) |*slot| {
            if (slot.* != null) continue;
            slot.* = .{ .memory = memory, .alignment = alignment };
            return;
        }
        // More released blocks than the table holds would be a case bug, and
        // handing the last one back is the only way to keep the memory honest.
        self.back.rawFree(memory, alignment, ret_addr);
    }
};

/// The window handle every case names as the owning toplevel.
const case_parent_window = "x11:1a";

/// What one call made of itself: the result it produced, and why it produced
/// none. A case reads the request the client built either way, so a body a
/// portal cannot parse is a failure this file shows rather than one it hides
/// behind a refusal.
const Exchange = struct {
    started: ?StartResult = null,
    refused: ?anyerror = null,

    /// Release the result this call produced, if it produced one.
    ///
    /// The value is poisoned rather than emptied, because a case reads both
    /// fields before its `defer` reaches this, and a second release would be a
    /// read of what this one retired.
    fn deinit(self: *Exchange) void {
        if (self.started) |*result| result.deinit();
        self.* = undefined;
    }
};

/// What one case offers the chooser, which is the part of `SelectSources` the
/// caller decides.
const Selection = struct {
    /// The portal's own type mask: monitor and window.
    sources: u32 = 1,
    multiple: bool = false,
    cursor_mode: CursorMode = .embedded,
    /// The portal's persistence level for a session that persists until it is
    /// revoked.
    persistence: u32 = 2,
    restore: ?[]const u8 = null,
};

/// One portal call, made the way a case under test makes it.
const Call = *const fn (context: ?*anyopaque, screen: *ScreenCast) anyerror!StartResult;

fn createCall(_: ?*anyopaque, screen: *ScreenCast) anyerror!StartResult {
    return .{ .outcome = try screen.createSession() };
}

fn selectCall(context: ?*anyopaque, screen: *ScreenCast) anyerror!StartResult {
    const selection: *const Selection = @ptrCast(@alignCast(context orelse return error.MissingTestContext));
    return .{ .outcome = try screen.selectSources(
        portal_session,
        selection.sources,
        selection.multiple,
        selection.cursor_mode,
        selection.persistence,
        selection.restore,
    ) };
}

fn startCall(_: ?*anyopaque, screen: *ScreenCast) anyerror!StartResult {
    const started = try screen.start(portal_session, case_parent_window);
    return started;
}

/// Runs one call against the stand-in, and joins that stand-in before it
/// returns, so a case reads what the stand-in recorded with its thread done.
fn converse(bus: *Conversation, portal: *Portal, call: Call, context: ?*anyopaque) !Exchange {
    var thread = try std.Thread.spawn(.{}, Portal.run, .{portal});
    var joined = false;
    defer if (!joined) thread.join();

    var exchange: Exchange = .{};
    if (call(context, &bus.screen)) |ok| {
        exchange.started = ok;
    } else |err| {
        exchange.refused = err;
    }
    thread.join();
    joined = true;
    return exchange;
}

test "api-w20 the create session request carries the two tokens the interface documents" {
    var bus = try Conversation.init();
    defer bus.deinit();
    try nameAs(&bus);

    var handle: []const u8 = "/org/freedesktop/portal/desktop/session/nogui2_9f2b";
    var portal: Portal = .{
        .sock = bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .write = writeSessionHandle, .context = @ptrCast(&handle) } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };
    var exchange = try converse(&bus, &portal, createCall, null);
    defer exchange.deinit();
    if (portal.failure) |err| return err;
    try testing.expect(exchange.refused == null);

    const request = try portal.requestMessage();
    try testing.expectEqualStrings("CreateSession", request.member.?);
    try testing.expectEqualStrings("org.freedesktop.portal.ScreenCast", request.interface.?);
    try testing.expectEqualStrings("a{sv}", request.signature.?);

    // The interface documents the request token and the token the session
    // handle is built from. An application id is not one of them: the portal
    // takes the identity of the caller from the bus, and a restore token
    // belongs to the call that consumes it.
    var options: [max_request_options]RequestOption = undefined;
    try testing.expectEqual(@as(usize, 2), try requestOptions(request, &options));
    var request_token = findOption(options[0..2], "handle_token").?;
    try testing.expectEqualStrings("s", request_token.signature);
    try testing.expect((try request_token.value.readString()).len != 0);
    var session_token = findOption(options[0..2], "session_handle_token").?;
    try testing.expectEqualStrings("s", session_token.signature);
    try testing.expect((try session_token.value.readString()).len != 0);

    // The handle is a string on this interface, and it survives the message
    // the client read it from.
    try testing.expectEqualStrings(handle, exchange.started.?.outcome.session_handle.?);
}

test "api-w20 the select sources request carries the documented options with the portal's own types" {
    var bus = try Conversation.init();
    defer bus.deinit();
    try nameAs(&bus);

    var selection: Selection = .{
        .sources = 3,
        .multiple = true,
        .cursor_mode = .metadata,
        .persistence = 2,
        .restore = "restore-token",
    };
    var portal: Portal = .{
        .sock = bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .write = writeNoResults, .context = undefined } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };
    var exchange = try converse(&bus, &portal, selectCall, &selection);
    defer exchange.deinit();
    if (portal.failure) |err| return err;
    try testing.expect(exchange.refused == null);

    const request = try portal.requestMessage();
    try testing.expectEqualStrings("SelectSources", request.member.?);
    try testing.expectEqualStrings("oa{sv}", request.signature.?);

    var body = dbus.BodyReader.init(request.body);
    try testing.expectEqualStrings(portal_session, try body.readObjectPath());

    var options: [max_request_options]RequestOption = undefined;
    const count = try requestOptions(request, &options);
    const offered = options[0..count];
    try testing.expectEqual(@as(usize, 6), count);

    var handle_token = findOption(offered, "handle_token").?;
    try testing.expectEqualStrings("s", handle_token.signature);
    try testing.expect((try handle_token.value.readString()).len != 0);

    var types = findOption(offered, "types").?;
    try testing.expectEqualStrings("u", types.signature);
    try testing.expectEqual(@as(u32, 3), try types.value.readU32());

    // Multiple is a boolean, so offering more than one source is a `true` and
    // not the number one.
    var multiple = findOption(offered, "multiple").?;
    try testing.expectEqualStrings("b", multiple.signature);
    try testing.expect(try multiple.value.readBool());

    // The cursor mode is one bit of the modes the portal advertises, and
    // metadata is the fourth of them.
    var cursor = findOption(offered, "cursor_mode").?;
    try testing.expectEqualStrings("u", cursor.signature);
    try testing.expectEqual(@as(u32, 4), try cursor.value.readU32());

    // A restore token is an option of this call, and the level the session
    // persists at is `persist_mode` under that exact name.
    var restore = findOption(offered, "restore_token").?;
    try testing.expectEqualStrings("s", restore.signature);
    try testing.expectEqualStrings("restore-token", try restore.value.readString());

    var persist = findOption(offered, "persist_mode").?;
    try testing.expectEqualStrings("u", persist.signature);
    try testing.expectEqual(@as(u32, 2), try persist.value.readU32());

    try testing.expect(findOption(offered, "persistence_mode") == null);
    try testing.expect(findOption(offered, "app_id") == null);
}

test "api-w20 the start request names the session and window outside its options" {
    var bus = try Conversation.init();
    defer bus.deinit();
    try nameAs(&bus);

    var portal: Portal = .{
        .sock = bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .write = writeNoResults, .context = undefined } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };
    var exchange = try converse(&bus, &portal, startCall, null);
    defer exchange.deinit();
    if (portal.failure) |err| return err;

    // The frame the client put on the wire, as a portal parses it: the session
    // and the parent window are arguments of their own, so the signature is
    // the object path, the window, and the options dictionary.
    const request = try portal.requestMessage();
    try testing.expectEqualStrings("Start", request.member.?);
    try testing.expectEqualStrings("org.freedesktop.portal.ScreenCast", request.interface.?);
    try testing.expectEqualStrings(portal_destination, request.destination.?);
    try testing.expectEqualStrings(portal_path, request.path.?);
    try testing.expectEqualStrings("osa{sv}", request.signature.?);

    var body = dbus.BodyReader.init(request.body);
    try testing.expectEqualStrings(portal_session, try body.readObjectPath());
    try testing.expectEqualStrings(case_parent_window, try body.readString());

    // `Start` documents the handle token and nothing else, so neither the
    // session nor a window the portal cannot use is one of the options.
    var options: [max_request_options]RequestOption = undefined;
    try testing.expectEqual(@as(usize, 1), try requestOptions(request, &options));
    try testing.expectEqualStrings("handle_token", options[0].key);
    try testing.expectEqualStrings("s", options[0].signature);
    try testing.expect((try options[0].value.readString()).len != 0);

    try testing.expect(exchange.refused == null);
    try testing.expect(exchange.started.?.outcome.isSuccess());
}

test "api-w20 the start reply keeps every stream the optional properties sit in" {
    var bus = try Conversation.init();
    defer bus.deinit();
    try nameAs(&bus);

    const plans = [_]StreamPlan{
        .{ .node_id = 41, .id = "stream-1", .width = 1920, .height = 1080, .x = -1440, .y = 0, .source_type = 1 },
        .{ .node_id = 42, .id = "stream-2", .width = 1280, .height = 720, .x = 0, .y = 32, .source_type = 2 },
    };
    var answer: []const StreamPlan = &plans;

    var portal: Portal = .{
        .sock = bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .write = writeStreams, .context = @ptrCast(&answer) } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };
    var exchange = try converse(&bus, &portal, startCall, null);
    defer exchange.deinit();
    if (portal.failure) |err| return err;
    try testing.expect(exchange.refused == null);

    const streams = exchange.started.?.outcome.streams.items;
    try testing.expectEqual(@as(usize, 2), streams.len);
    // Each stream opens with two properties this build does not read, so a
    // reader that stopped at the first key it did not know would name no
    // stream at all. Everything behind them is the whole stream.
    try testing.expectEqual(@as(u32, 41), streams[0].node_id);
    try testing.expectEqualStrings("stream-1", streams[0].id);
    try testing.expectEqual(@as(u32, 1), streams[0].source_type);
    try testing.expectEqual(@as(i32, 1920), streams[0].size.?.width);
    try testing.expectEqual(@as(i32, 1080), streams[0].size.?.height);
    try testing.expectEqual(@as(i32, -1440), streams[0].position.?.x);
    try testing.expectEqual(@as(u32, 42), streams[1].node_id);
    try testing.expectEqualStrings("stream-2", streams[1].id);
    try testing.expectEqual(@as(u32, 2), streams[1].source_type);
    try testing.expectEqual(@as(i32, 720), streams[1].size.?.height);
    try testing.expectEqual(@as(i32, 32), streams[1].position.?.y);
}

test "api-w20 a result keeps the strings it read once the reply frame is released" {
    var gate: PoisonAllocator = .{ .back = testing.allocator };
    defer gate.release();
    var bus = try conversationOn(gate.allocator());
    defer bus.deinit();
    try nameAs(&bus);

    const plans = [_]StreamPlan{.{
        .node_id = 41,
        .id = "stream-1",
        .width = 1920,
        .height = 1080,
        .x = 0,
        .y = 0,
        .source_type = 1,
    }};
    var answer: []const StreamPlan = &plans;

    var portal: Portal = .{
        .sock = bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .write = writeStreams, .context = @ptrCast(&answer) } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };
    var exchange = try converse(&bus, &portal, startCall, null);
    defer exchange.deinit();
    if (portal.failure) |err| return err;
    try testing.expect(exchange.refused == null);

    // The client has released what it read the result from, so those bytes
    // hold nothing but the poison a release writes. The strings the result
    // carries are its own and still read as the portal spelled them, and
    // `deinit` returns them, which the leak check at the end of this test
    // would report if it did not.
    try testing.expect(gate.released > 0);
    const streams = exchange.started.?.outcome.streams.items;
    try testing.expectEqual(@as(usize, 1), streams.len);
    try testing.expectEqualStrings("stream-1", streams[0].id);
    try testing.expectEqual(@as(u32, 41), streams[0].node_id);
    try testing.expectEqual(@as(i32, 1920), streams[0].size.?.width);
}

test "api-w20 a reply that types a documented property wrongly is refused whole" {
    var bus = try Conversation.init();
    defer bus.deinit();
    try nameAs(&bus);

    const plans = [_]StreamPlan{
        .{ .node_id = 41, .id = "stream-1", .width = 1920, .height = 1080, .x = 0, .y = 0, .source_type = 1 },
        .{ .node_id = 42, .id = "stream-2", .width = 1280, .height = 720, .x = 0, .y = 0, .source_type = 2 },
    };
    var answer: []const StreamPlan = &plans;

    var portal: Portal = .{
        .sock = bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .write = writeMalformedStreams, .context = @ptrCast(&answer) } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };
    var exchange = try converse(&bus, &portal, startCall, null);
    defer exchange.deinit();
    if (portal.failure) |err| return err;

    // A reply this build cannot read is refused rather than half-read, and
    // refusing it releases the stream it had already taken: the leak check at
    // the end of this test reports a copy that outlived its owner.
    try testing.expectEqual(@as(?anyerror, error.InvalidReply), exchange.refused);
    try testing.expect(exchange.started == null);
}

test "api-w20 a chooser the user closed and a request the portal refused are different answers" {
    var canceled_bus = try Conversation.init();
    defer canceled_bus.deinit();
    try nameAs(&canceled_bus);

    var canceled_portal: Portal = .{
        .sock = canceled_bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .code = 1, .write = writeNoResults, .context = undefined } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };
    var canceled = try converse(&canceled_bus, &canceled_portal, startCall, null);
    defer canceled.deinit();
    if (canceled_portal.failure) |err| return err;
    try testing.expect(canceled.refused == null);

    try testing.expectEqual(ResponseCode.canceled, canceled.started.?.outcome.code);
    try testing.expect(!canceled.started.?.outcome.isSuccess());

    // A second conversation, because a frame the first call did not read is
    // still on its socket and would be read back as the next answer.
    var refused_bus = try Conversation.init();
    defer refused_bus.deinit();
    try nameAs(&refused_bus);
    // The reason a portal names with a refusal is a result this build steps
    // over by its own type. The code carries the refusal, and the facade maps
    // that code onto the typed failure a caller acts on, so the text behind it
    // reaches nothing and is left unread.
    var reason: []const u8 = "no source is available";

    var refused_portal: Portal = .{
        .sock = refused_bus.portal_end,
        .sender = bus_unique_name,
        .answer = .{ .response = .{ .code = 2, .write = writeErrorMessage, .context = @ptrCast(&reason) } },
        // The frame is poison until the stand-in reads one into it, and
        // `request_len` is what makes any of those bytes readable.
        .request = undefined,
    };
    var refused = try converse(&refused_bus, &refused_portal, startCall, null);
    defer refused.deinit();
    if (refused_portal.failure) |err| return err;
    try testing.expect(refused.refused == null);

    try testing.expectEqual(ResponseCode.other, refused.started.?.outcome.code);
    try testing.expect(!refused.started.?.outcome.isSuccess());
}

fn writeRepeatedOwnedResults(b: *dbus.MessageBuilder, clear: bool) !void {
    try b.writeU32(0);
    const results = try b.startArray(8);
    try putOptionKey(b, "session_handle", "s");
    try b.writeString("/session/first");
    try putOptionKey(b, "session_handle", "s");
    try b.writeString(if (clear) "" else "/session/last");
    try putOptionKey(b, "streams", "a(ua{sv})");
    const streams = try b.startArray(8);
    try b.startStruct();
    try b.writeU32(41);
    const properties = try b.startArray(8);
    try putOptionKey(b, "id", "s");
    try b.writeString("source-first");
    try putOptionKey(b, "id", "s");
    try b.writeString(if (clear) "" else "source-last");
    b.finishArray(properties);
    b.finishArray(streams);
    b.finishArray(results);
}

fn checkOwnedResponse(gpa: std.mem.Allocator, body: []const u8, clear: bool) !void {
    var result = try parseResponse(gpa, body);
    defer result.deinit();
    try testing.expectEqual(ResponseCode.success, result.code);
    if (clear) {
        try testing.expect(result.session_handle == null);
    } else {
        try testing.expectEqualStrings("/session/last", result.session_handle.?);
    }
    try testing.expectEqual(@as(usize, 1), result.streams.items.len);
    try testing.expectEqual(@as(u32, 41), result.streams.items[0].node_id);
    try testing.expectEqualStrings(if (clear) "" else "source-last", result.streams.items[0].id);
}

test "api-w20 repeated response strings replace or clear their previous ownership" {
    for ([_]bool{ false, true }) |clear| {
        var builder = dbus.MessageBuilder.init(testing.allocator, .signal, 1);
        defer builder.deinit();
        try writeRepeatedOwnedResults(&builder, clear);
        try checkOwnedResponse(testing.allocator, builder.body.items, clear);
    }
}

test "api-w20 response allocation failure releases every partially owned result" {
    for ([_]bool{ false, true }) |clear| {
        var builder = dbus.MessageBuilder.init(testing.allocator, .signal, 1);
        defer builder.deinit();
        try writeRepeatedOwnedResults(&builder, clear);
        try testing.checkAllAllocationFailures(testing.allocator, checkOwnedResponse, .{ builder.body.items, clear });
    }
}

test "api-w20 unknown dictionary metadata cannot hide the following session result" {
    var builder = dbus.MessageBuilder.init(testing.allocator, .signal, 1);
    defer builder.deinit();
    try builder.writeU32(0);
    const results = try builder.startArray(8);
    try putOptionKey(&builder, "future_map", "a{sv}");
    const metadata = try builder.startArray(8);
    try putOptionKey(&builder, "nested", "s");
    try builder.writeString("opaque metadata");
    builder.finishArray(metadata);
    try putOptionKey(&builder, "session_handle", "s");
    try builder.writeString("/session/after-metadata");
    builder.finishArray(results);

    var result = try parseResponse(testing.allocator, builder.body.items);
    defer result.deinit();
    try testing.expectEqual(ResponseCode.success, result.code);
    try testing.expectEqualStrings("/session/after-metadata", result.session_handle.?);
}
