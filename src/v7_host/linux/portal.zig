//! Linux Desktop Portal and FreeDesktop D-Bus client service adapter.
//! Provides native file manager reveal, URI opening, and appearance queries
//! over D-Bus. SDL supplies the process environment and working directory.
const std = @import("std");
const dbus = @import("dbus.zig");
const linux = std.os.linux;
const sdl3 = @import("sdl3");

/// Errors a portal request reports itself. Transport and parse failures from
/// the D-Bus client propagate unchanged.
pub const PortalError = error{
    NoSessionBus,
    PortalUnavailable,
    MethodCallFailed,
    InvalidReply,
} || std.mem.Allocator.Error;

/// Check if a D-Bus session bus is available in this process environment.
pub fn isSessionBusAvailable() bool {
    const process = sdl3.getEnvironment() catch return false;
    const addr = process.getVariable("DBUS_SESSION_BUS_ADDRESS") orelse return false;
    return addr.len > 0;
}

/// Convert a filesystem path to a `file://` URI. Caller frees the result.
/// Relative paths resolve against the process working directory.
fn fileUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "file://")) return allocator.dupe(u8, path);
    if (std.fs.path.isAbsolute(path)) {
        return allocator.print("file://{s}", .{path});
    }
    // SDL allocates the working directory. `join` copies it into `allocator`.
    const cwd_z = try sdl3.filesystem.getCurrentDirectory();
    defer sdl3.free(cwd_z);
    const absolute = try std.fs.path.join(allocator, &.{ cwd_z, path });
    defer allocator.free(absolute);
    return allocator.print("file://{s}", .{absolute});
}

/// Why a `file://` URI does not name a local path.
pub const FileUriError = error{
    /// Another scheme, or no path at all. A portal must not send one, and a
    /// string that is not a URI is not a path.
    NotAFileUri,
    /// A `file://host/path` URI names another machine.
    RemoteHost,
    /// A `%` that is not followed by two hex digits.
    InvalidEscape,
} || std.mem.Allocator.Error;

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// Convert one `file://` URI into the filesystem path it names, decoding the
/// percent escapes the portal encodes. Caller frees the result.
pub fn fileUriToPath(allocator: std.mem.Allocator, uri: []const u8) FileUriError![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return error.NotAFileUri;
    const rest = uri["file://".len..];
    if (rest.len == 0) return error.NotAFileUri;
    // `file:///path` leaves the authority empty; `file://host/path` does not.
    if (rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NotAFileUri;
        if (!std.mem.eql(u8, rest[0..slash], "localhost")) return error.RemoteHost;
        return decodePercent(allocator, rest[slash..]);
    }
    return decodePercent(allocator, rest);
}

fn decodePercent(allocator: std.mem.Allocator, text: []const u8) FileUriError![]u8 {
    const out = try allocator.alloc(u8, text.len);
    errdefer allocator.free(out);
    var index: usize = 0;
    var written: usize = 0;
    while (index < text.len) : (written += 1) {
        const byte = text[index];
        if (byte != '%') {
            out[written] = byte;
            index += 1;
            continue;
        }
        if (index + 2 >= text.len) return error.InvalidEscape;
        const high = hexDigit(text[index + 1]) orelse return error.InvalidEscape;
        const low = hexDigit(text[index + 2]) orelse return error.InvalidEscape;
        out[written] = high << 4 | low;
        index += 3;
    }
    // The decode writes in place and then shrinks: reallocating would let a
    // shrink failure report a size error this function never classifies, so
    // the shorter result is copied and the original is released here.
    const shorter = try allocator.dupe(u8, out[0..written]);
    allocator.free(out);
    return shorter;
}

/// Reveal one or more file or directory paths in the system file manager.
/// Uses org.freedesktop.FileManager1.ShowItems.
pub fn showItems(allocator: std.mem.Allocator, paths: []const []const u8) !void {
    if (paths.len == 0) return;
    if (!isSessionBusAvailable()) return error.NoSessionBus;

    var conn = dbus.Connection.connectSessionBus(allocator) catch {
        return error.PortalUnavailable;
    };
    defer conn.deinit();

    return showItemsOn(allocator, &conn, paths);
}

/// `showItems` over a connection the caller already holds, so a private portal
/// at the other end of a socket can be driven without a session bus.
fn showItemsOn(allocator: std.mem.Allocator, conn: *dbus.Connection, paths: []const []const u8) !void {
    var builder = dbus.MessageBuilder.init(allocator, .method_call, conn.nextSerial());
    defer builder.deinit();

    builder.destination = "org.freedesktop.FileManager1";
    builder.path = "/org/freedesktop/FileManager1";
    builder.interface = "org.freedesktop.FileManager1";
    builder.member = "ShowItems";
    builder.signature = "ass";

    // First argument: as (array of file:// URIs)
    const array_offset = try builder.startArray(4);
    for (paths) |path| {
        const uri = try fileUri(allocator, path);
        defer allocator.free(uri);
        try builder.writeString(uri);
    }
    builder.finishArray(array_offset);

    // Second argument: s (startup_id, empty string)
    try builder.writeString("");

    // `call` waits for the frame carrying this call's serial, so a signal or
    // another call's answer on this connection cannot be read as this one.
    const reply_bytes = conn.call(&builder) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A connection that broke, or a stream this transport cannot
        // resynchronize on, revealed nothing: the file manager was never
        // reached with this call.
        else => return error.MethodCallFailed,
    };
    defer allocator.free(reply_bytes);

    const reply = dbus.MessageParser.parse(reply_bytes) catch return error.InvalidReply;
    if (reply.msg_type == .error_reply) return error.MethodCallFailed;
    // A file manager that answered with anything else did not answer.
    if (reply.msg_type != .method_return) return error.InvalidReply;
}

/// What a portal reported for a request this host asked it to make.
///
/// An OpenURI or OpenDirectory method call answers with the object the portal
/// created for the request, not with an outcome. The decision arrives on that
/// object afterwards, so it is the only thing that can say a URI was opened,
/// and it keeps the three ways a request can end apart: a user dismissing it
/// is not a provider refusing it.
pub const OpenDecision = enum {
    /// The portal reports the request succeeded.
    opened,
    /// The user dismissed the request. Nobody refused a launch, so this is
    /// neither a success nor a failure.
    cancelled,
    /// The portal ended the request some other way, refused the call, or the
    /// connection broke before a decision arrived.
    failed,
};

/// Request opening a directory with the desktop file manager. Blocks until the
/// portal reports what happened. Uses org.freedesktop.portal.OpenURI.OpenDirectory.
pub fn openDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    parent_window: []const u8,
) !OpenDecision {
    if (!isSessionBusAvailable()) return error.NoSessionBus;

    var conn = dbus.Connection.connectSessionBus(allocator) catch {
        return error.PortalUnavailable;
    };
    defer conn.deinit();

    return openDirectoryOver(allocator, &conn, dir_path, parent_window);
}

/// Request opening a URI via XDG Desktop Portal. Blocks until the portal
/// reports what happened. Uses org.freedesktop.portal.OpenURI.OpenURI.
///
/// A `file://` URI is opened through `OpenFile`, which is the method the
/// OpenURI spec names for a local file: `OpenURI` states a local file is
/// explicitly not supported on it. Both the parsing and the descriptor are
/// this call's own: a `file://` URI that names another host, or that carries
/// an escape this adapter cannot read, is refused rather than pointed at
/// something local.
pub fn openUri(
    allocator: std.mem.Allocator,
    uri: []const u8,
    parent_window: []const u8,
) !OpenDecision {
    if (!isSessionBusAvailable()) return error.NoSessionBus;

    var conn = dbus.Connection.connectSessionBus(allocator) catch {
        return error.PortalUnavailable;
    };
    defer conn.deinit();

    return openUriOver(allocator, &conn, uri, parent_window);
}

/// True when `uri` names `scheme`, without regard to the case a scheme is
/// written in. A scheme is only a scheme once its colon follows it.
fn uriSchemeIs(uri: []const u8, scheme: []const u8) bool {
    if (uri.len <= scheme.len) return false;
    if (!std.ascii.startsWithIgnoreCase(uri, scheme)) return false;
    return uri[scheme.len] == ':';
}

/// Open a local path to hand to a portal call, close-on-exec set so a
/// descriptor being passed cannot outlive the call in a child process. A
/// directory is opened as a directory, so a path naming something else is
/// refused instead of opened as one. The descriptor belongs to the caller.
fn openPortalTarget(allocator: std.mem.Allocator, path: []const u8, directory: bool) !std.posix.fd_t {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    const rc = linux.open(path_z.ptr, if (directory) .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    } else .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    switch (linux.errno(rc)) {
        // A raw linux call reports a descriptor or a bit-cast errno, so the
        // errno is decoded with the linux decoder rather than the libc one.
        .SUCCESS => return @intCast(rc),
        else => return error.LocalFileUnavailable,
    }
}

/// `openUri` over a connection the caller already holds, so a private portal
/// at the other end of a socket can be driven without a session bus.
fn openUriOver(
    allocator: std.mem.Allocator,
    conn: *dbus.Connection,
    uri: []const u8,
    parent_window: []const u8,
) !OpenDecision {
    if (uriSchemeIs(uri, "file")) {
        const path = fileUriToPath(allocator, uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A URI this adapter cannot turn into a local path names no local
            // file, whatever its scheme claims.
            error.NotAFileUri, error.RemoteHost, error.InvalidEscape => return error.InvalidReply,
        };
        defer allocator.free(path);
        const descriptor = try openPortalTarget(allocator, path, false);
        defer _ = std.os.linux.close(descriptor);
        return openUriRequest(allocator, conn, "OpenFile", .{ .descriptor = descriptor }, parent_window);
    }
    return openUriRequest(allocator, conn, "OpenURI", .{ .uri = uri }, parent_window);
}

/// `openDirectory` over a connection the caller already holds, so a private
/// portal at the other end of a socket can be driven without a session bus.
fn openDirectoryOver(
    allocator: std.mem.Allocator,
    conn: *dbus.Connection,
    dir_path: []const u8,
    parent_window: []const u8,
) !OpenDecision {
    const descriptor = try openPortalTarget(allocator, dir_path, true);
    defer _ = std.os.linux.close(descriptor);
    return openUriRequest(allocator, conn, "OpenDirectory", .{ .descriptor = descriptor }, parent_window);
}

/// What the spec's own argument names for a member: OpenURI names a URI,
/// OpenFile and OpenDirectory name a descriptor.
const OpenTarget = union(enum) {
    uri: []const u8,
    descriptor: std.posix.fd_t,
};

/// One `org.freedesktop.portal.OpenURI` call over a connection the caller
/// already holds.
///
/// The method call answers with the request object the portal created, and the
/// decision arrives on that object afterwards. The reply is therefore not an
/// answer to report: something is opened when the Response on the request says
/// so, which is what makes a request the user dismissed distinguishable from
/// one that was refused and from one that never came back.
fn openUriRequest(
    allocator: std.mem.Allocator,
    conn: *dbus.Connection,
    member: []const u8,
    target: OpenTarget,
    parent_window: []const u8,
) !OpenDecision {
    var predicted = predictRequest(allocator, conn) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotABusName => return error.InvalidReply,
    };
    defer predicted.deinit(allocator);

    var builder = dbus.MessageBuilder.init(allocator, .method_call, conn.nextSerial());
    defer builder.deinit();

    builder.destination = "org.freedesktop.portal.Desktop";
    builder.path = "/org/freedesktop/portal/desktop";
    builder.interface = "org.freedesktop.portal.OpenURI";
    builder.member = member;

    // Arg 1: parent_window (s)
    try builder.writeString(parent_window);

    switch (target) {
        // Arg 2: uri (s)
        .uri => |uri| {
            builder.signature = "ssa{sv}";
            try builder.writeString(uri);
        },
        // Arg 2: fd (h). The body names the descriptor by its index among the
        // ones this call carries, and the header's count is what says an index
        // is there at all. The transport writes that count as it sends, so it
        // is set by the call that carries the descriptor rather than here.
        .descriptor => {
            builder.signature = "sha{sv}";
            try builder.writeU32(0);
        },
    }

    // Arg 3: options (a{sv}). The request token is what makes the portal put
    // its answer on the object this connection predicted, so the decision can
    // be told apart from another request's on the same connection.
    const dict_offset = try builder.startArray(8);
    try writeOptionKey(&builder, "handle_token", "s");
    try builder.writeString(predicted.token());
    builder.finishArray(dict_offset);

    const response = try requestPortal(
        allocator,
        conn,
        &builder,
        predicted.path,
        null,
        switch (target) {
            .uri => null,
            .descriptor => |descriptor| descriptor,
        },
    );
    defer allocator.free(response.frame);
    return openDecision(response.body);
}

/// What a Request::Response says about a request this adapter asked the portal
/// to make. The Request spec types the body `(u a{sv})` and its table is 0
/// success, 1 the user cancelled the interaction, 2 it ended some other way,
/// so a code outside that table is not folded into one of the three.
fn openDecision(body: []const u8) OpenDecision {
    var reader = dbus.BodyReader.init(body);
    const code = reader.readU32() catch return .failed;
    return switch (code) {
        0 => .opened,
        1 => .cancelled,
        else => .failed,
    };
}

/// ── File chooser ───────────────────────────────
/// A portal dialog is answered in two messages. The method call replies with
/// a Request object path, and the portal later emits
/// `org.freedesktop.portal.Request::Response` on that object with the user's
/// decision. Every outcome that signal can express is a separate case here,
/// because a dismissal is not an empty list and an absent portal is not a
/// dismissal.
/// The portal splits the request by direction: a selection is an `OpenFile`
/// call, a destination is a `SaveFile` call.
pub const FileChooserMode = enum {
    open_file,
    save_file,
};

/// One filter the dialog offers. Every pattern is sent as a glob, which the
/// spec types as `(0, pattern)`; a MIME type would be `(1, type)` and has no
/// source in this tree.
pub const FileChooserFilter = struct {
    name: []const u8,
    /// Whole-name globs, exactly as a chooser matches them: `*.txt` selects
    /// every name ending in `.txt`, and a bare extension selects a file named
    /// after it, which is not what a caller who wrote one meant. An empty
    /// list is the every-file filter, which is how a chooser builds its own,
    /// and it is a different request from a list holding `*`.
    patterns: []const []const u8,
};

/// Only the keys org.freedesktop.portal.FileChooser documents as supported
/// for both of its methods appear here. A request that needs a key the spec
/// does not define is refused by the caller instead of being sent with a
/// value the portal would silently drop.
pub const FileChooserOptions = struct {
    mode: FileChooserMode = .open_file,
    /// A window identifier as
    /// https://flatpak.github.io/xdg-desktop-portal/docs/window-identifiers.html
    /// defines it: `x11:<XID in hex>`, `wayland:<xdg_foreign handle>`, or
    /// the empty string when no such handle is available.
    parent_window: []const u8 = "",
    title: []const u8 = "",
    accept_label: ?[]const u8 = null,
    /// The dialog may return more than one path.
    multiple: bool = false,
    /// The dialog selects a directory instead of a file.
    directory: bool = false,
    /// The dialog is modal for its parent window. The spec defaults this to
    /// true, so it is sent only when the caller asked for a parent.
    modal: bool = false,
    /// A folder path in the encoding of the file system, sent raw and NUL
    /// terminated. It is a path, not a `file://` URI.
    current_folder: ?[]const u8 = null,
    filters: []const FileChooserFilter = &.{},
};

/// Why a request produced no selection. These are the four portal and
/// transport refusals, kept apart so an absent capability never reports as a
/// failed request.
pub const FileChooserFailure = enum {
    /// The process environment names no session bus.
    no_session_bus,
    /// The bus answered, but no FileChooser portal does.
    portal_unavailable,
    /// The portal answered with an error, or the connection broke while the
    /// dialog was open.
    method_failed,
    /// A reply arrived in a shape this adapter does not read.
    invalid_reply,
};

pub const FileChooserSelection = struct {
    /// Owned `file://` URI copies. Release them with `freeUris`.
    uris: []const []const u8,
    /// Index into `FileChooserOptions.filters`, when the portal named a
    /// filter this request offered. A name that matches no offered filter
    /// stays unknown rather than becoming a guess.
    filter_index: ?usize = null,
};

pub const FileChooserResult = union(enum) {
    selected: FileChooserSelection,
    /// The user dismissed the dialog.
    cancelled,
    /// Another action took the request over, so no one chose.
    aborted,
    /// The portal reported success and named no path. Kept apart from
    /// `cancelled` because the user did accept the dialog here.
    empty_selection,
    failed: FileChooserFailure,
};

/// Release the URI copies a `selected` result owns.
pub fn freeUris(allocator: std.mem.Allocator, uris: []const []const u8) void {
    for (uris) |uri| allocator.free(uri);
    allocator.free(uris);
}

/// Request tokens must match `[A-Za-z0-9_]`, and the Request spec asks for a
/// per-library prefix. The request object path is
/// `/org/freedesktop/portal/desktop/request/<sender>/<token>`, and the sender
/// is this connection's unique bus name. No two requests of this process
/// share a connection, so a counter behind a library prefix cannot collide
/// with another request's path.
var request_token: std.atomic.Value(u64) = .init(0);

/// The `handle_token` one request carries, printed into a buffer the caller
/// holds. The prefix is five bytes and the counter has a fixed width, so this
/// cannot run out of room.
fn nextRequestToken(buffer: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "nogui{d}", .{request_token.fetchAdd(1, .monotonic)}) catch
        @panic("portal request token does not fit its buffer");
}

/// One request's token, and the object the Request spec says the portal will
/// answer on. The token is what the call carries as `handle_token`; the path
/// is what the Response signal is emitted on.
const PredictedRequest = struct {
    /// Released with `deinit`.
    path: []u8,
    /// Held here rather than on a caller's stack: the call that carries the
    /// token is built after this prediction is made. Only the bytes
    /// `nextRequestToken` wrote are ever read back, through `token()`.
    token_buffer: [32]u8,
    token_len: usize = 0,

    fn token(self: *const PredictedRequest) []const u8 {
        return self.token_buffer[0..self.token_len];
    }

    fn deinit(self: *PredictedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// The token for the next request on this connection, and the object it
/// predicts. A connection that has not said `Hello` has no unique name to
/// derive one from, and a request object this adapter cannot name is one whose
/// decision it would have nowhere to read.
fn predictRequest(allocator: std.mem.Allocator, conn: *dbus.Connection) !PredictedRequest {
    const unique_name = conn.unique_name orelse return error.NotABusName;
    // The token is printed into a buffer this call owns and the path copies
    // those bytes out of it, so nothing here borrows from a frame that could
    // go out of scope before the call that carries the token is built.
    // SAFETY: `nextRequestToken` writes the token before it returns, and the
    // only read of this buffer is the `token_len` prefix that write filled.
    var token_buffer: [32]u8 = undefined;
    const token = nextRequestToken(&token_buffer);
    const path = try requestPath(allocator, unique_name, token);
    return .{ .path = path, .token_buffer = token_buffer, .token_len = token.len };
}

const request_path_prefix = "/org/freedesktop/portal/desktop/request/";

/// The longest a parked worker waits before it looks at the cancel flag
/// again. This is the bound on how long a dismissed request keeps a worker.
const cancel_poll_ms: i32 = 250;

/// The object path the Request spec predicts for a token: the caller's unique
/// name with its leading `:` removed and every `.` replaced by `_`, then the
/// token. Caller frees the result.
fn requestPath(allocator: std.mem.Allocator, unique_name: []const u8, token: []const u8) ![]u8 {
    if (unique_name.len < 2 or unique_name[0] != ':') return error.NotABusName;
    const sender = unique_name[1..];
    const out = try allocator.alloc(u8, request_path_prefix.len + sender.len + 1 + token.len);
    errdefer allocator.free(out);
    @memcpy(out[0..request_path_prefix.len], request_path_prefix);
    var written: usize = request_path_prefix.len;
    for (sender) |byte| {
        out[written] = if (byte == '.') '_' else byte;
        written += 1;
    }
    out[written] = '/';
    written += 1;
    @memcpy(out[written..][0..token.len], token);
    return out;
}

/// Route the decision signal to this connection. The subscription is
/// installed before the method call, because the portal can answer before
/// this process has read the reply.
fn addResponseMatch(conn: *dbus.Connection, request_path: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const rule = try std.fmt.bufPrint(
        &buffer,
        "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'",
        .{request_path},
    );
    try conn.addMatch(rule);
}

/// Start one `a{sv}` entry: the key, then the variant signature. The value
/// follows and pads itself to the alignment its own type needs.
fn writeOptionKey(
    builder: *dbus.MessageBuilder,
    key: []const u8,
    variant_signature: []const u8,
) !void {
    try builder.startStruct();
    try builder.writeString(key);
    try builder.writeSignature(variant_signature);
}

/// Write an `ay` bytestring: the bytes followed by the NUL a path carries,
/// inside one array of bytes. The FileChooser spec types `current_folder`
/// this way and expects a raw path, not a URI.
fn writeByteString(builder: *dbus.MessageBuilder, text: []const u8) !void {
    const offset = try builder.startArray(1);
    for (text) |byte| try builder.writeByte(byte);
    try builder.writeByte(0);
    builder.finishArray(offset);
}

/// Write `a(sa(us))`: one entry per filter, each a display name and a list of
/// `(kind, pattern)` pairs, where the spec numbers a glob 0 and a MIME type
/// 1. Only globs have a source in this tree.
///
/// A pattern goes on the wire as it stands. The chooser matches it against the
/// whole name, so re-reading an extension as a name is what emptied a real
/// view, and a filter with no patterns is written as an empty array, which is
/// how a chooser spells "every file".
fn writeFilters(builder: *dbus.MessageBuilder, filters: []const FileChooserFilter) !void {
    const outer = try builder.startArray(8);
    for (filters) |filter| {
        try builder.startStruct();
        try builder.writeString(filter.name);
        const types = try builder.startArray(8);
        for (filter.patterns) |pattern| {
            try builder.startStruct();
            try builder.writeU32(0);
            try builder.writeString(pattern);
        }
        builder.finishArray(types);
    }
    builder.finishArray(outer);
}

/// Fill `builder` with one FileChooser method call. The token is a parameter
/// so the path the Request spec predicts from it can be pinned by a test.
fn buildFileChooserRequest(
    builder: *dbus.MessageBuilder,
    options: FileChooserOptions,
    token: []const u8,
) !void {
    builder.destination = "org.freedesktop.portal.Desktop";
    builder.path = "/org/freedesktop/portal/desktop";
    builder.interface = "org.freedesktop.portal.FileChooser";
    builder.member = switch (options.mode) {
        .open_file => "OpenFile",
        .save_file => "SaveFile",
    };
    builder.signature = "ssa{sv}";

    // Arg 1: parent_window (s)
    try builder.writeString(options.parent_window);
    // Arg 2: title (s)
    try builder.writeString(options.title);

    // Arg 3: options (a{sv})
    const options_offset = try builder.startArray(8);
    try writeOptionKey(builder, "handle_token", "s");
    try builder.writeString(token);
    if (options.multiple) {
        try writeOptionKey(builder, "multiple", "b");
        try builder.writeBool(true);
    }
    if (options.directory) {
        try writeOptionKey(builder, "directory", "b");
        try builder.writeBool(true);
    }
    if (options.modal) {
        try writeOptionKey(builder, "modal", "b");
        try builder.writeBool(true);
    }
    if (options.accept_label) |label| {
        try writeOptionKey(builder, "accept_label", "s");
        try builder.writeString(label);
    }
    if (options.current_folder) |folder| {
        try writeOptionKey(builder, "current_folder", "ay");
        try writeByteString(builder, folder);
    }
    if (options.filters.len != 0) {
        try writeOptionKey(builder, "filters", "a(sa(us))");
        try writeFilters(builder, options.filters);
    }
    builder.finishArray(options_offset);
}

/// Dismiss a request the caller no longer waits for. The Request spec states
/// that no Response follows a Close, so the worker stops waiting at once.
fn closeRequest(conn: *dbus.Connection, request_path: []const u8) void {
    var builder = dbus.MessageBuilder.init(conn.allocator, .method_call, conn.nextSerial());
    defer builder.deinit();
    builder.destination = "org.freedesktop.portal.Desktop";
    builder.path = request_path;
    builder.interface = "org.freedesktop.portal.Request";
    builder.member = "Close";
    const wire = builder.build() catch return;
    defer conn.allocator.free(wire);
    // The reply is left unread on purpose: the connection closes with this
    // request, and no Response can follow a Close.
    conn.sendRaw(wire) catch return;
}

/// The alignment a D-Bus type starts on, from its first character.
fn typeAlignment(signature: []const u8) usize {
    if (signature.len == 0) return 1;
    return switch (signature[0]) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(' => 8,
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

/// Step over one value of a complete D-Bus type. A shape this adapter cannot
/// read stops the walk rather than guessing at the bytes that follow, so a
/// portal that adds a result key never yields a partial selection.
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
        '(' => blk: {
            if (signature[signature.len - 1] != ')') return false;
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

/// The index of the offered filter the portal named, or null when the name
/// matches none of them.
fn indexOfFilter(filters: []const FileChooserFilter, name: []const u8) ?usize {
    for (filters, 0..) |filter, index| {
        if (std.mem.eql(u8, filter.name, name)) return index;
    }
    return null;
}

fn countStrings(payload: []const u8) usize {
    var count: usize = 0;
    var reader = dbus.BodyReader.init(payload);
    while (reader.cursor < reader.bytes.len) {
        _ = reader.readString() catch break;
        count += 1;
    }
    return count;
}

/// Walk the `a{sv}` results of a Response signal. The URIs are copied out
/// because the reply buffer dies with this call.
fn decodeResults(
    allocator: std.mem.Allocator,
    results: []const u8,
    filters: []const FileChooserFilter,
) std.mem.Allocator.Error!FileChooserResult {
    var reader = dbus.BodyReader.init(results);
    var uris: []const []const u8 = &.{};
    defer freeUris(allocator, uris);
    var filter_index: ?usize = null;

    while (reader.cursor < reader.bytes.len) {
        // Every entry of an `a{sv}` is a struct, so each one begins on an
        // 8-byte boundary. Without this the reader would take the NEXT entry's
        // key from wherever the previous value happened to end, and a real
        // portal reply with more than one entry would decode as garbage.
        reader.alignStruct();
        if (reader.cursor >= reader.bytes.len) break;
        const key = reader.readString() catch return .{ .failed = .invalid_reply };
        const signature = reader.readSignature() catch return .{ .failed = .invalid_reply };
        if (std.mem.eql(u8, key, "uris") and std.mem.eql(u8, signature, "as")) {
            const payload = reader.readArray(4) catch return .{ .failed = .invalid_reply };
            const count = countStrings(payload);
            const owned = try allocator.alloc([]const u8, count);
            var filled: usize = 0;
            var transferred = false;
            defer if (!transferred) {
                for (owned[0..filled]) |uri| allocator.free(uri);
                allocator.free(owned);
            };
            var list = dbus.BodyReader.init(payload);
            while (list.cursor < list.bytes.len) {
                const uri = list.readString() catch return .{ .failed = .invalid_reply };
                owned[filled] = try allocator.dupe(u8, uri);
                filled += 1;
            }
            freeUris(allocator, uris);
            uris = owned;
            transferred = true;
        } else if (std.mem.eql(u8, key, "current_filter") and
            std.mem.eql(u8, signature, "(sa(us))"))
        {
            reader.alignStruct();
            const name = reader.readString() catch return .{ .failed = .invalid_reply };
            _ = reader.readArray(8) catch return .{ .failed = .invalid_reply };
            filter_index = indexOfFilter(filters, name);
        } else if (!skipTypedValue(&reader, signature)) {
            return .{ .failed = .invalid_reply };
        }
    }

    // Only a selection passes ownership of the copies to the caller; the
    // success code with no path is an accepted dialog that named nothing.
    if (uris.len == 0) return .empty_selection;
    const selection = uris;
    uris = &.{};
    return .{ .selected = .{ .uris = selection, .filter_index = filter_index } };
}

/// Read the `(u a{sv})` body of a Response signal. The Request spec's table
/// is 0 success, 1 the user cancelled the interaction, 2 ended in some other
/// way. A code outside that table is a shape this adapter does not read and
/// is never folded into "some other way".
fn decodeResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    filters: []const FileChooserFilter,
) std.mem.Allocator.Error!FileChooserResult {
    var reader = dbus.BodyReader.init(body);
    const code = reader.readU32() catch return .{ .failed = .invalid_reply };
    if (code == 1) return .cancelled;
    if (code == 2) return .aborted;
    if (code != 0) return .{ .failed = .invalid_reply };
    const results = reader.readArray(8) catch return .{ .failed = .invalid_reply };
    return decodeResults(allocator, results, filters);
}

/// True when `message` is a Request::Response signal at all. The request it
/// belongs to is identified afterwards by the object it is emitted on.
fn isResponseSignal(message: dbus.Message) bool {
    if (message.msg_type != .signal) return false;
    const interface = message.interface orelse return false;
    if (!std.mem.eql(u8, interface, "org.freedesktop.portal.Request")) return false;
    const member = message.member orelse return false;
    return std.mem.eql(u8, member, "Response");
}

/// The Response for `handle` in `bytes`, or null when the frame belongs to
/// somebody else on this connection. The frame is released here unless the
/// caller is handed it, so a decision for another request does not outlive the
/// wait for this one.
fn takeResponse(
    allocator: std.mem.Allocator,
    bytes: []u8,
    handle: []const u8,
) ?RequestResponse {
    const message = dbus.MessageParser.parse(bytes) catch {
        allocator.free(bytes);
        return null;
    };
    if (!isResponseSignal(message)) {
        allocator.free(bytes);
        return null;
    }
    // The request identity is the object the signal is emitted on, not a field
    // of its body. A Response naming no object cannot be placed on any
    // request, so the decoder is handed no body and reports the reply it
    // cannot read rather than somebody else's answer.
    const path = message.path orelse return .{ .frame = bytes, .body = &.{} };
    if (!std.mem.eql(u8, path, handle)) {
        allocator.free(bytes);
        return null;
    }
    return .{ .frame = bytes, .body = message.body };
}

/// The Response signal for one request, and the frame it arrived in. The body
/// points into that frame, so the two cannot be separated.
const RequestResponse = struct {
    frame: []u8,
    body: []const u8,
};

/// A portal that does not implement the interface rejects the method itself.
/// That is an absent capability, not a failed request, so it never shares an
/// answer with a portal that answered and refused.
fn methodError(reply: dbus.Message) error{ PortalUnavailable, MethodCallFailed }!void {
    const name = reply.error_name orelse return error.MethodCallFailed;
    if (std.mem.indexOf(u8, name, "UnknownMethod") != null) return error.PortalUnavailable;
    if (std.mem.indexOf(u8, name, "UnknownInterface") != null) return error.PortalUnavailable;
    if (std.mem.indexOf(u8, name, "UnknownObject") != null) return error.PortalUnavailable;
    if (std.mem.indexOf(u8, name, "ServiceUnknown") != null) return error.PortalUnavailable;
    if (std.mem.indexOf(u8, name, "NotSupported") != null) return error.PortalUnavailable;
    return error.MethodCallFailed;
}

/// Call one portal method and wait for the Response signal on the request
/// object it created.
///
/// Two things are correlated here, and neither is the frame that happens to
/// arrive first. The reply is the frame naming `builder.serial`, because a
/// connection carries the signals and the answers of every other call made on
/// it. The decision is the Response signal naming the request object, because
/// a portal can also answer a request made earlier on the same connection. The
/// subscription for `predicted` goes in before the call: the portal may answer
/// before this process has read the reply, and a Response the bus was not asked
/// to forward is never delivered at all.
///
/// `descriptor` is the local file a call names, when the method takes one. The
/// descriptor is borrowed: it travels with this one call and is not closed
/// here, because the caller that opened it owns it for the whole request.
///
/// `cancel` is checked between waits. Raising it closes the request, and the
/// Request spec says no Response follows a Close.
fn requestPortal(
    allocator: std.mem.Allocator,
    conn: *dbus.Connection,
    builder: *dbus.MessageBuilder,
    predicted: []const u8,
    cancel: ?*const std.atomic.Value(bool),
    descriptor: ?std.posix.fd_t,
) (error{Cancelled} || PortalError)!RequestResponse {
    addResponseMatch(conn, predicted) catch return error.MethodCallFailed;

    // Both waits end at the frame carrying this serial and leave every other
    // frame staged, in arrival order, for the wait below. The one that passes a
    // descriptor is the same wait with the descriptor attached to this frame
    // alone.
    const reply_bytes = (if (descriptor) |fd|
        conn.callWithFd(builder, fd)
    else
        conn.call(builder)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A bus that never negotiated descriptor passing cannot run a call
        // that needs one at all. That is an absent capability, not a launch
        // that was attempted and refused.
        error.UnixFdUnsupported => return error.PortalUnavailable,
        // A connection that broke, or a stream this transport cannot
        // resynchronize on, is a request that did not take. It is not an
        // answer to read.
        else => return error.MethodCallFailed,
    };
    defer allocator.free(reply_bytes);

    const reply = dbus.MessageParser.parse(reply_bytes) catch return error.InvalidReply;
    if (reply.msg_type == .error_reply) try methodError(reply);
    if (reply.msg_type != .method_return) return error.InvalidReply;

    var reader = dbus.BodyReader.init(reply.body);
    const handle = try allocator.dupe(u8, reader.readObjectPath() catch return error.InvalidReply);
    defer allocator.free(handle);

    if (!std.mem.eql(u8, handle, predicted)) {
        // A portal older than 0.9 chooses the request object itself. The spec
        // asks for exactly this: verify the handle, then widen the match.
        addResponseMatch(conn, handle) catch return error.MethodCallFailed;
    }

    while (true) {
        if (cancel) |flag| {
            if (flag.load(.acquire)) {
                closeRequest(conn, handle);
                return error.Cancelled;
            }
        }
        // A frame already in the inbound buffer needs no socket poll, or a
        // decision that arrived with the method reply would wait for traffic
        // that may never come.
        if (conn.nextBuffered() catch return error.MethodCallFailed) |bytes| {
            if (takeResponse(allocator, bytes, handle)) |response| return response;
            continue;
        }
        if (!(conn.pollReadable(cancel_poll_ms) catch return error.MethodCallFailed)) continue;
        const bytes = conn.readMessageBytes() catch return error.MethodCallFailed;
        if (takeResponse(allocator, bytes, handle)) |response| return response;
    }
}

/// Open a file or save dialog through org.freedesktop.portal.FileChooser and
/// block until the portal reports the user's decision or `cancel` is raised.
///
/// The call must not run on a thread the host UI needs: the dialog stays open
/// until a person answers it. `cancel` is polled at `cancel_poll_ms`, and a
/// raised flag closes the portal request instead of leaving the dialog on
/// screen for a person the caller has already left.
pub fn openFileChooser(
    allocator: std.mem.Allocator,
    options: FileChooserOptions,
    cancel: ?*const std.atomic.Value(bool),
) (error{RequestTooLarge} || std.mem.Allocator.Error)!FileChooserResult {
    if (!isSessionBusAvailable()) return .{ .failed = .no_session_bus };

    var conn = dbus.Connection.connectSessionBus(allocator) catch {
        return .{ .failed = .portal_unavailable };
    };
    defer conn.deinit();

    var predicted = predictRequest(allocator, &conn) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotABusName => return .{ .failed = .invalid_reply },
    };
    defer predicted.deinit(allocator);

    var builder = dbus.MessageBuilder.init(allocator, .method_call, conn.nextSerial());
    defer builder.deinit();
    buildFileChooserRequest(&builder, options, predicted.token()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A title, filter name or pattern the wire cannot carry.
        else => return error.RequestTooLarge,
    };

    // A file chooser names no local file, so its call carries no descriptor.
    const response = requestPortal(allocator, &conn, &builder, predicted.path, cancel, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Nothing on this connection can raise this: the bus was reachable a
        // moment ago, or there would be no connection to fail a call on.
        error.NoSessionBus => return .{ .failed = .no_session_bus },
        error.PortalUnavailable => return .{ .failed = .portal_unavailable },
        error.MethodCallFailed => return .{ .failed = .method_failed },
        error.InvalidReply => return .{ .failed = .invalid_reply },
        // The caller stopped waiting and the request was closed, so no one
        // chose: the same answer a portal gives when it takes a request over.
        error.Cancelled => return .aborted,
    };
    defer allocator.free(response.frame);
    return decodeResponse(allocator, response.body, options.filters);
}

pub const PortalTheme = enum {
    light,
    dark,
};

/// Query color scheme preference via XDG Desktop Portal Settings.
/// Reads namespace "org.freedesktop.appearance", key "color-scheme".
/// Value 1 = prefer-dark, 2 = prefer-light, other, or no answer at all (null).
pub fn readAppearanceTheme(allocator: std.mem.Allocator) !?PortalTheme {
    if (!isSessionBusAvailable()) return null;

    var conn = dbus.Connection.connectSessionBus(allocator) catch {
        return null;
    };
    defer conn.deinit();

    return readAppearanceThemeOn(allocator, &conn);
}

/// `readAppearanceTheme` over a connection the caller already holds, so a
/// private portal at the other end of a socket can be driven without a session
/// bus.
fn readAppearanceThemeOn(allocator: std.mem.Allocator, conn: *dbus.Connection) !?PortalTheme {
    var builder = dbus.MessageBuilder.init(allocator, .method_call, conn.nextSerial());
    defer builder.deinit();

    builder.destination = "org.freedesktop.portal.Desktop";
    builder.path = "/org/freedesktop/portal/desktop";
    builder.interface = "org.freedesktop.portal.Settings";
    builder.member = "Read";
    builder.signature = "ss";

    try builder.writeString("org.freedesktop.appearance");
    try builder.writeString("color-scheme");

    // `call` waits for the frame carrying this call's serial. A preference in a
    // frame that names another call is not this host's preference, and no
    // answer at all is no preference rather than a guess.
    const reply_bytes = conn.call(&builder) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(reply_bytes);

    const reply = dbus.MessageParser.parse(reply_bytes) catch return null;
    if (reply.msg_type == .error_reply or reply.msg_type != .method_return) {
        return null;
    }

    // Portal Settings.Read returns a variant (v) containing a variant (v) of uint32:
    // Format: variant sig 'v', inside which is variant sig 'u', inside which is uint32.
    if (reply.body.len < 4) return null;
    var reader = dbus.BodyReader.init(reply.body);
    // Outer variant signature
    const outer_sig = reader.readSignature() catch return null;
    if (std.mem.eql(u8, outer_sig, "v")) {
        const inner_sig = reader.readSignature() catch return null;
        if (std.mem.eql(u8, inner_sig, "u")) {
            const val = reader.readU32() catch return null;
            if (val == 1) return .dark;
            if (val == 2) return .light;
            return null;
        }
    } else if (std.mem.eql(u8, outer_sig, "u")) {
        const val = reader.readU32() catch return null;
        if (val == 1) return .dark;
        if (val == 2) return .light;
        return null;
    }

    return null;
}

/// ── A private portal on a socket ────────────
/// Every frame the stand-in below sends is assembled here, and nothing here
/// reaches a real portal: what a test observes is the client reading a
/// conversation, not a reply handed to it.
/// The unique name a private bus hands out. The Request spec drops the leading
/// colon and turns dots into underscores when it builds a request path from it.
const test_bus_name = ":1.7";

/// A request object a stand-in names for itself, for the portals that choose
/// the object instead of deriving it from a token the caller sent.
const stand_in_object = "/org/freedesktop/portal/desktop/request/1_7/stand_in";

/// A request object belonging to some other request on the same connection. A
/// decision emitted on it answers that request, never this one.
const other_request_object = "/org/freedesktop/portal/desktop/request/1_7/other";

/// How long a stand-in waits for the client to hang up before it stops
/// listening. It bounds a client that is waiting for something no plan sends:
/// the socket closes under it and it reports that, instead of the run
/// stalling on a conversation that has ended.
const linger_ms: i32 = 500;

fn socketPair() ![2]i32 {
    var ends: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &ends);
    // `socketpair` is a raw linux call: its result is a length or a
    // bit-cast errno, so it is decoded with the linux decoder rather than the
    // libc one, which reads every result other than -1 as success.
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    return ends;
}

/// Reads once from the bus, appending any descriptors the kernel attached to
/// the set being read. A descriptor that arrives but does not fit is closed
/// right away, so nothing is left installed in this process for no owner.
fn recvChunk(
    sock: std.posix.fd_t,
    buffer: []u8,
    fds: *[FakePortal.max_fds_per_message]std.posix.fd_t,
    fd_count: *usize,
) !usize {
    var control: [
        @sizeOf(linux.cmsghdr) + FakePortal.max_fds_per_message * @sizeOf(std.posix.fd_t)
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
        .AGAIN => return error.PeerWentQuiet,
        .CONNRESET, .PIPE, .BADF, .NOTCONN => return error.PeerClosed,
        else => return error.ReadFailed,
    }

    collectFds(control[0..msg.controllen], fds, fd_count);
    if (rc == 0) return error.PeerClosed;
    return rc;
}

fn collectFds(
    control: []align(@alignOf(linux.cmsghdr)) u8,
    out: *[FakePortal.max_fds_per_message]std.posix.fd_t,
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

/// A private portal at the far end of a socket pair. It speaks what a session
/// bus would: it hands out a unique name, confirms every match rule, and
/// answers the request it is sent with the frames its plan names.
const FakePortal = struct {
    /// The frames the stand-in sends when the request call arrives.
    const Plan = enum {
        /// Traffic nobody asked for, the answer naming the call's own serial,
        /// and a decision on the object this stand-in names.
        answered,
        /// As `answered`, with a decision whose code is the one the Request
        /// spec gives a cancelled interaction.
        withdrawn,
        /// As `answered`, with a decision that ended some other way.
        ended_another_way,
        /// As `answered`, with a code the Request spec does not define.
        undefined_code,
        /// The answer naming this call's serial, and no decision at all.
        never_decides,
        /// The answer naming this call's serial, and a decision on an object
        /// this call did not create.
        other_request_decides,
        /// The predicted object's cancellation arrives before the method reply.
        early_withdrawn,
        /// Traffic nobody asked for, and no answer to this call at all.
        no_answer,
        /// An error reply: this portal does not have the call.
        unknown_method,
        /// A preference in a frame naming another call, then this call's own
        /// answer carrying a different one.
        stray_answer,
    };

    /// The decision code each plan reports, or null for a plan that reports
    /// none. The Request spec's table is 0 success, 1 the user cancelled the
    /// interaction, 2 it ended some other way.
    fn decisionCode(plan: Plan) ?u32 {
        return switch (plan) {
            .answered, .other_request_decides => 0,
            .withdrawn, .early_withdrawn => 1,
            .ended_another_way => 2,
            .undefined_code => 7,
            .never_decides, .no_answer, .unknown_method, .stray_answer => null,
        };
    }

    /// One request here is a handful of bytes. A frame larger than this is one
    /// the stand-in cannot read rather than one it should guess at.
    const max_request_bytes = 2048;
    /// More descriptors than any call here carries, so one that arrives beyond
    /// this is closed rather than dropped on the floor.
    const max_fds_per_message = 4;

    fd: i32,
    plan: Plan,
    /// The request the client sent, kept so a test can read what was asked for
    /// once this thread is done. `request_len` is what makes a byte of this
    /// buffer readable, and it starts at zero.
    request: [max_request_bytes]u8,
    request_len: usize = 0,
    /// The descriptors the kernel attached to the request, which the stand-in
    /// owns from the moment they arrive. A call that names a local file is only
    /// proven to have named one if the stand-in received a descriptor it can
    /// resolve back to that path. `received_count` counts the descriptors that
    /// arrived, so none of the rest of this table is read.
    received: [max_fds_per_message]std.posix.fd_t,
    received_count: usize = 0,
    /// What the stand-in could not do. A stand-in that fails where a portal
    /// would answer leaves the client waiting, so this has to be reported
    /// rather than pass for an answer from the client.
    failure: ?anyerror = null,

    /// Read one whole frame from the bus, keeping any descriptors the kernel
    /// attached to it.
    ///
    /// A plain read discards the control message and closes the descriptors
    /// with it, so a stand-in that read this way could never see the file a
    /// call claimed to open. The descriptors are collected from the first
    /// chunk on, which is the moment the kernel installs them.
    fn readFrame(self: *FakePortal, buffer: []u8) ![]u8 {
        if (buffer.len < 16) return error.FrameTooLarge;
        var filled: usize = 0;
        while (filled < 16) {
            filled += try recvChunk(self.fd, buffer[filled..16], &self.received, &self.received_count);
        }
        if (buffer[0] != 'l') return error.NotAFrame;

        const body_len = std.mem.readInt(u32, buffer[4..8], .little);
        const fields_len = std.mem.readInt(u32, buffer[12..16], .little);
        const total = 16 + fields_len + dbus.padLen(16 + fields_len, 8) + body_len;
        if (total > buffer.len) return error.FrameTooLarge;
        while (filled < total) {
            filled += try recvChunk(self.fd, buffer[filled..total], &self.received, &self.received_count);
        }
        return buffer[0..total];
    }

    /// The descriptors this conversation received, or null when none did.
    fn descriptors(self: *const FakePortal) ?[]const std.posix.fd_t {
        if (self.received_count == 0) return null;
        return self.received[0..self.received_count];
    }

    fn closeReceived(self: *FakePortal) void {
        for (self.received[0..self.received_count]) |received| _ = linux.close(received);
        self.received_count = 0;
    }

    fn run(self: *FakePortal) void {
        var conn = dbus.Connection.initCustom(std.testing.allocator, self.fd);
        defer conn.deinit();
        self.converse(&conn) catch |err| {
            self.failure = err;
        };
    }

    /// Answer the client until it has asked its question, then until it hangs
    /// up or stops talking.
    ///
    /// The request is read through `recvChunk` rather than the connection's
    /// own read, because that is the only way a descriptor sent with the call
    /// survives to be looked at here.
    fn converse(self: *FakePortal, conn: *dbus.Connection) !void {
        var scratch: [max_request_bytes]u8 = undefined;
        while (true) {
            const frame = self.readFrame(&self.request) catch return;

            const message = try dbus.MessageParser.parse(frame);
            if (try self.answerBusCall(conn, message)) continue;
            self.request_len = frame.len;
            try self.answerRequest(conn, message);
            break;
        }
        while (conn.pollReadable(linger_ms) catch return) {
            const frame = self.readFrame(&scratch) catch return;
            const message = dbus.MessageParser.parse(frame) catch continue;
            if (!try self.answerBusCall(conn, message)) continue;
        }
    }

    /// The calls a bus makes of every connection. Answering them is what lets
    /// the client read its own reply instead of waiting on a portal.
    fn answerBusCall(self: *FakePortal, conn: *dbus.Connection, message: dbus.Message) !bool {
        const member = message.member orelse return false;
        if (std.mem.eql(u8, member, "Hello")) {
            var b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, conn.nextSerial());
            defer b.deinit();
            b.reply_serial = message.serial;
            b.signature = "s";
            try b.writeString(test_bus_name);
            try self.send(conn, &b);
            return true;
        }
        if (std.mem.eql(u8, member, "AddMatch") or std.mem.eql(u8, member, "Close")) {
            try self.sendReturn(conn, message);
            return true;
        }
        return false;
    }

    /// Send the frames the plan names.
    fn answerRequest(self: *FakePortal, conn: *dbus.Connection, request: dbus.Message) !void {
        switch (self.plan) {
            .unknown_method => return self.sendError(
                conn,
                request,
                "org.freedesktop.DBus.Error.UnknownMethod",
            ),
            .no_answer => {
                // A signal, and an answer to a call nobody made here. A
                // connection carries the traffic of every call made on it, and
                // neither frame names this call's serial.
                try self.sendUnrelatedSignal(conn);
                try self.sendStrayReply(conn, request.serial + 1000);
            },
            .answered, .withdrawn, .ended_another_way, .undefined_code, .never_decides => {
                try self.sendUnrelatedSignal(conn);
                try self.sendStrayReply(conn, request.serial + 1000);
                if (std.mem.eql(u8, request.interface orelse "", "org.freedesktop.FileManager1")) {
                    return self.sendReturn(conn, request);
                }
                // The request object this portal created. A portal that names
                // the object itself is one older than the Request spec's token
                // rule, and the client has to widen its subscription to it.
                try self.sendHandle(conn, request, stand_in_object);
                if (decisionCode(self.plan)) |code| {
                    try self.sendDecision(conn, stand_in_object, code);
                }
            },
            .early_withdrawn => {
                var reader = dbus.BodyReader.init(request.body);
                _ = try reader.readString();
                _ = try reader.readString();
                var options = dbus.BodyReader.init(try reader.readArray(8));
                options.alignStruct();
                if (!std.mem.eql(u8, try options.readString(), "handle_token")) return error.MissingToken;
                if (!std.mem.eql(u8, try options.readSignature(), "s")) return error.InvalidTokenType;
                const path = try requestPath(std.testing.allocator, test_bus_name, try options.readString());
                defer std.testing.allocator.free(path);
                try self.sendDecision(conn, path, 1);
                try self.sendHandle(conn, request, path);
            },
            .other_request_decides => {
                // The answer to this call, then a decision on an object this
                // call never created. A decision for another request is not an
                // answer to this one, however well formed it is.
                try self.sendHandle(conn, request, stand_in_object);
                try self.sendDecision(conn, other_request_object, 0);
            },
            .stray_answer => {
                // A preference the host never asked this call for, then the
                // answer to the call it did make. A reader that takes the
                // first frame reports the other call's theme as this host's.
                try self.sendThemeReply(conn, request.serial + 1000, 1);
                try self.sendThemeReply(conn, request.serial, 2);
            },
        }
    }

    fn send(_: *FakePortal, conn: *dbus.Connection, builder: *dbus.MessageBuilder) !void {
        const wire = try builder.build();
        defer std.testing.allocator.free(wire);
        try conn.sendRaw(wire);
    }

    fn sendReturn(self: *FakePortal, conn: *dbus.Connection, request: dbus.Message) !void {
        var b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, conn.nextSerial());
        defer b.deinit();
        b.reply_serial = request.serial;
        try self.send(conn, &b);
    }

    /// The request object a portal method hands back.
    fn sendHandle(self: *FakePortal, conn: *dbus.Connection, request: dbus.Message, path: []const u8) !void {
        var b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, conn.nextSerial());
        defer b.deinit();
        b.reply_serial = request.serial;
        b.signature = "o";
        try b.writeObjectPath(path);
        try self.send(conn, &b);
    }

    /// An answer to a call this conversation never made.
    fn sendStrayReply(self: *FakePortal, conn: *dbus.Connection, reply_serial: u32) !void {
        var b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, conn.nextSerial());
        defer b.deinit();
        b.reply_serial = reply_serial;
        b.signature = "u";
        try b.writeU32(4711);
        try self.send(conn, &b);
    }

    /// An answer carrying one appearance preference, in the shape the
    /// Settings interface answers `Read` with: a variant wrapping a variant of
    /// uint32.
    fn sendThemeReply(self: *FakePortal, conn: *dbus.Connection, reply_serial: u32, value: u32) !void {
        var b = dbus.MessageBuilder.init(std.testing.allocator, .method_return, conn.nextSerial());
        defer b.deinit();
        b.reply_serial = reply_serial;
        b.signature = "v";
        try b.writeSignature("v");
        try b.writeSignature("u");
        try b.writeU32(value);
        try self.send(conn, &b);
    }

    fn sendError(self: *FakePortal, conn: *dbus.Connection, request: dbus.Message, name: []const u8) !void {
        var b = dbus.MessageBuilder.init(std.testing.allocator, .error_reply, conn.nextSerial());
        defer b.deinit();
        b.reply_serial = request.serial;
        b.error_name = name;
        try self.send(conn, &b);
    }

    /// The `org.freedesktop.portal.Request::Response` signal a portal emits
    /// once on the object of a request it has answered.
    fn sendDecision(self: *FakePortal, conn: *dbus.Connection, path: []const u8, code: u32) !void {
        var b = dbus.MessageBuilder.init(std.testing.allocator, .signal, conn.nextSerial());
        defer b.deinit();
        b.path = path;
        b.interface = "org.freedesktop.portal.Request";
        b.member = "Response";
        b.signature = "ua{sv}";
        try b.writeU32(code);
        const results = try b.startArray(8);
        b.finishArray(results);
        try self.send(conn, &b);
    }

    /// A signal from another feature on the same connection.
    fn sendUnrelatedSignal(self: *FakePortal, conn: *dbus.Connection) !void {
        var b = dbus.MessageBuilder.init(std.testing.allocator, .signal, conn.nextSerial());
        defer b.deinit();
        b.path = "/org/freedesktop/Notifications";
        b.interface = "org.freedesktop.Notifications";
        b.member = "NotificationClosed";
        b.signature = "uu";
        try b.writeU32(7);
        try b.writeU32(2);
        try self.send(conn, &b);
    }
};

/// Both ends of a private portal conversation: the connection this process
/// drives, and the stand-in answering it on a thread.
const PortalPeer = struct {
    conn: dbus.Connection,
    stand_in: *FakePortal,
    thread: std.Thread,
    /// What the client sent, kept here so a test reads the request of a
    /// finished conversation rather than one the stand-in may still write to.
    /// `finish` fills the prefix `request_len` names, so nothing else of this
    /// buffer is ever read.
    request: [FakePortal.max_request_bytes]u8,
    request_len: usize = 0,
    /// What the stand-in could not do, reported with the thread that hit it.
    stand_in_failure: ?anyerror = null,
    /// The descriptors the call carried, taken over from the stand-in once its
    /// thread is done. They are open in this process, so a test can resolve one
    /// back to the path it names. `finish` fills the prefix `received_count`
    /// names, so nothing else of this table is ever read.
    received: [FakePortal.max_fds_per_message]std.posix.fd_t,
    received_count: usize = 0,

    /// A connection with a private portal behind it, already introduced: the
    /// unique name the connection answers on comes from the bus it said hello
    /// to, exactly as it does in a real one.
    ///
    /// No `try` runs between `start` and `finish`: the stand-in owns a thread,
    /// and an early return would leave it on a socket nobody answers.
    fn start(plan: FakePortal.Plan) !PortalPeer {
        const ends = try socketPair();
        const stand_in = try std.testing.allocator.create(FakePortal);
        stand_in.* = .{
            .fd = ends[1],
            .plan = plan,
            // SAFETY: frame reads fill request_len before its prefix is read.
            .request = undefined,
            // SAFETY: received_count only advances after a descriptor is stored.
            .received = undefined,
        };

        const thread = std.Thread.spawn(.{}, FakePortal.run, .{stand_in}) catch |err| {
            _ = std.os.linux.close(ends[1]);
            std.testing.allocator.destroy(stand_in);
            return err;
        };
        var self: PortalPeer = .{
            .conn = dbus.Connection.initCustom(std.testing.allocator, ends[0]),
            .stand_in = stand_in,
            .thread = thread,
            // SAFETY: finish copies request bytes before exposing request_len.
            .request = undefined,
            // SAFETY: finish copies descriptors before exposing received_count.
            .received = undefined,
        };
        // A stand-in bus stands in for one that negotiated descriptor passing
        // during SASL, which is what a real session bus does before any portal
        // call. A case that needs the other answer clears this itself.
        self.conn.unix_fd_capable = true;
        errdefer self.finish();
        try self.conn.hello();
        return self;
    }

    /// Close this end, join the stand-in, and keep what it recorded. The
    /// client's hangup is what releases the stand-in, so it comes first.
    fn finish(self: *PortalPeer) void {
        self.conn.deinit();
        self.thread.join();
        self.request_len = self.stand_in.request_len;
        @memcpy(
            self.request[0..self.request_len],
            self.stand_in.request[0..self.request_len],
        );
        self.stand_in_failure = self.stand_in.failure;
        // The descriptors are moved here rather than released: the stand-in is
        // gone, and these are the only proof of what the call actually named.
        @memcpy(
            self.received[0..self.stand_in.received_count],
            self.stand_in.received[0..self.stand_in.received_count],
        );
        self.received_count = self.stand_in.received_count;
        self.stand_in.received_count = 0;
        std.testing.allocator.destroy(self.stand_in);
    }

    /// The descriptors this conversation carried, or null when it carried
    /// none. They belong to the caller, which closes them with `closeReceived`.
    fn descriptors(self: *const PortalPeer) ?[]const std.posix.fd_t {
        if (self.received_count == 0) return null;
        return self.received[0..self.received_count];
    }

    fn closeReceived(self: *PortalPeer) void {
        for (self.received[0..self.received_count]) |received| _ = linux.close(received);
        self.received_count = 0;
    }

    /// The request the client sent, parsed the way a portal parses it.
    fn requestMessage(self: *const PortalPeer) !dbus.Message {
        if (self.request_len == 0) return error.NoRequest;
        return dbus.MessageParser.parse(self.request[0..self.request_len]);
    }
};

test "api-w18 a file manager reveal accepts only the answer to its own call" {
    // A session bus connection carries the traffic of every other call made on
    // it: signals, and answers to calls nobody made here. ShowItems is a plain
    // method with no request object, so the frame naming its own serial is the
    // whole answer, and a file manager that refuses the call revealed nothing.
    {
        var peer = try PortalPeer.start(.no_answer);
        const revealed = showItemsOn(std.testing.allocator, &peer.conn, &.{"/tmp/revealed.txt"});
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectError(error.MethodCallFailed, revealed);
    }
    {
        var peer = try PortalPeer.start(.answered);
        const revealed = showItemsOn(std.testing.allocator, &peer.conn, &.{"/tmp/revealed.txt"});
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try revealed;
        // The paths leave as the `file://` URIs the interface asks for, in one
        // array, with an empty startup id behind them.
        const request = try peer.requestMessage();
        try std.testing.expectEqualStrings("ShowItems", request.member.?);
        try std.testing.expectEqualStrings("ass", request.signature.?);
        var reader = dbus.BodyReader.init(request.body);
        var list = dbus.BodyReader.init(try reader.readArray(4));
        try std.testing.expectEqualStrings("file:///tmp/revealed.txt", try list.readString());
        try std.testing.expectEqualStrings("", try reader.readString());
    }
    {
        var peer = try PortalPeer.start(.unknown_method);
        const revealed = showItemsOn(std.testing.allocator, &peer.conn, &.{"/tmp/revealed.txt"});
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectError(error.MethodCallFailed, revealed);
    }
}

/// The path a received descriptor names, read back through procfs. A call that
/// claims to pass a file is only proven to have passed one when the descriptor
/// it delivered resolves to the path the caller named.
fn resolveDescriptor(
    descriptor: std.posix.fd_t,
    link_buffer: []u8,
    target_buffer: []u8,
) ![]const u8 {
    const link = try std.fmt.bufPrint(link_buffer, "/proc/self/fd/{d}", .{descriptor});
    const length = try std.Io.Dir.readLinkAbsolute(std.testing.io, link, target_buffer);
    return target_buffer[0..length];
}

test "api-w18 opening a directory hands the portal a descriptor for it" {
    // The OpenURI spec types OpenDirectory as (s parent_window, h fd, a{sv}),
    // not as a URI: the directory travels as an open descriptor, so the call
    // can only name the directory the caller opened. The stand-in resolves the
    // descriptor it received back through procfs, which is the only proof that
    // the descriptor names this directory rather than a copy of its path.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "revealed");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "revealed", &path_buffer);
    const real_path = path_buffer[0..path_len];

    var peer = try PortalPeer.start(.answered);
    const decision = openDirectoryOver(std.testing.allocator, &peer.conn, real_path, "");
    peer.finish();
    defer peer.closeReceived();
    try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
    try std.testing.expectEqual(OpenDecision.opened, try decision);

    // The member and its signature are the spec's, and the body names the
    // descriptor by index rather than naming a path.
    const request = try peer.requestMessage();
    try std.testing.expectEqualStrings("org.freedesktop.portal.OpenURI", request.interface.?);
    try std.testing.expectEqualStrings("OpenDirectory", request.member.?);
    try std.testing.expectEqualStrings("sha{sv}", request.signature.?);
    try std.testing.expectEqual(@as(u32, 1), request.unix_fds);
    var reader = dbus.BodyReader.init(request.body);
    try std.testing.expectEqualStrings("", try reader.readString());
    try std.testing.expectEqual(@as(u32, 0), try reader.readU32());

    // Exactly the descriptor the call said it carried, and it resolves to the
    // directory that was opened.
    const carried = peer.descriptors() orelse return error.NoDescriptor;
    try std.testing.expectEqual(@as(usize, 1), carried.len);
    var link_buffer: [64]u8 = undefined;
    var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        real_path,
        try resolveDescriptor(carried[0], &link_buffer, &target_buffer),
    );
}

test "api-w18 opening a file uri hands the portal a descriptor for that file" {
    // The OpenURI spec states a file:// URI is explicitly not supported on the
    // OpenURI method and names OpenFile for a local file. So a file:// URI goes
    // out as OpenFile carrying a descriptor, and the stand-in resolves that
    // descriptor back to the file the URI named.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "opened" });

    var real_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPathFile(std.testing.io, "note.txt", &real_buffer);
    const real_path = real_buffer[0..real_len];

    var uri_buffer: [std.Io.Dir.max_path_bytes * 3]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buffer, "file://{s}", .{real_path});

    var peer = try PortalPeer.start(.answered);
    const decision = openUriOver(std.testing.allocator, &peer.conn, uri, "");
    peer.finish();
    defer peer.closeReceived();
    try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
    try std.testing.expectEqual(OpenDecision.opened, try decision);

    const request = try peer.requestMessage();
    try std.testing.expectEqualStrings("OpenFile", request.member.?);
    try std.testing.expectEqualStrings("sha{sv}", request.signature.?);
    try std.testing.expectEqual(@as(u32, 1), request.unix_fds);

    // The URI was resolved to the file it names and never sent as a string.
    var reader = dbus.BodyReader.init(request.body);
    try std.testing.expectEqualStrings("", try reader.readString());
    try std.testing.expectEqual(@as(u32, 0), try reader.readU32());
    const carried = peer.descriptors() orelse return error.NoDescriptor;
    try std.testing.expectEqual(@as(usize, 1), carried.len);
    var link_buffer: [64]u8 = undefined;
    var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        real_path,
        try resolveDescriptor(carried[0], &link_buffer, &target_buffer),
    );
}

test "api-w18 a uri the portal cannot name is refused before any call" {
    // A file:// URI naming another host, or carrying an escape this adapter
    // cannot read, names no local file. Sending it as OpenFile would hand the
    // portal a descriptor for something the caller never named, so the refusal
    // happens before the call rather than after it.
    var peer = try PortalPeer.start(.answered);
    defer peer.closeReceived();
    try std.testing.expectError(
        error.InvalidReply,
        openUriOver(std.testing.allocator, &peer.conn, "file://otherhost/tmp/x", ""),
    );
    peer.finish();
    try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
    // Nothing was asked: a stand-in that never saw a call recorded no request.
    try std.testing.expectEqual(@as(usize, 0), peer.request_len);
    try std.testing.expectEqual(@as(?[]const std.posix.fd_t, null), peer.descriptors());
}

test "api-w18 a local file the caller cannot open is not passed to the portal" {
    // The descriptor is opened here and owned here. A path that does not exist
    // yields no descriptor, so no call goes out and nothing has to be released.
    var peer = try PortalPeer.start(.answered);
    defer peer.closeReceived();
    try std.testing.expectError(
        error.LocalFileUnavailable,
        openDirectoryOver(std.testing.allocator, &peer.conn, "/nonexistent/nogui", ""),
    );
    peer.finish();
    try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
    try std.testing.expectEqual(@as(usize, 0), peer.request_len);
    try std.testing.expectEqual(@as(?[]const std.posix.fd_t, null), peer.descriptors());
}

test "api-w18 a bus without descriptor passing is an absent portal method" {
    // OpenFile and OpenDirectory carry a file, and a bus that never negotiated
    // descriptor passing cannot carry one at all. That is an absent capability
    // rather than a launch that was attempted and refused, so it must not be
    // reported as a failure of the request. A URI call, which carries no
    // descriptor, still goes out on the same bus.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "revealed");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "revealed", &path_buffer);

    {
        var peer = try PortalPeer.start(.answered);
        peer.conn.unix_fd_capable = false;
        const decision = openDirectoryOver(
            std.testing.allocator,
            &peer.conn,
            path_buffer[0..path_len],
            "",
        );
        peer.finish();
        defer peer.closeReceived();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectError(error.PortalUnavailable, decision);
    }
    {
        var peer = try PortalPeer.start(.answered);
        peer.conn.unix_fd_capable = false;
        const decision = openUriOver(std.testing.allocator, &peer.conn, "https://example.com", "");
        peer.finish();
        defer peer.closeReceived();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectEqual(OpenDecision.opened, try decision);
    }
}

test "api-w18 opening a uri reports the answer to its own call" {
    // The same connection, the same traffic, and the portal that answers an
    // OpenURI call with the object it created: the name of a request is not
    // the decision on it, and neither is anything else on the connection.
    {
        var peer = try PortalPeer.start(.no_answer);
        const decision = openUriOver(std.testing.allocator, &peer.conn, "https://example.com", "");
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectError(error.MethodCallFailed, decision);
    }
    {
        var peer = try PortalPeer.start(.answered);
        const decision = openUriOver(std.testing.allocator, &peer.conn, "https://example.com", "");
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectEqual(OpenDecision.opened, try decision);
        const request = try peer.requestMessage();
        try std.testing.expectEqualStrings("org.freedesktop.portal.OpenURI", request.interface.?);
        try std.testing.expectEqualStrings("OpenURI", request.member.?);
        var reader = dbus.BodyReader.init(request.body);
        try std.testing.expectEqualStrings("", try reader.readString());
        try std.testing.expectEqualStrings("https://example.com", try reader.readString());
    }
}

test "api-w18 a portal decision is the one this request asked for" {
    // The method call answers with the request object, and the decision
    // arrives on that object afterwards. Each way the Request spec can report
    // is its own answer here: a user who dismissed the request is not a
    // provider that refused it, and neither is a decision this request never
    // received.
    const cases = [_]struct { plan: FakePortal.Plan, expected: OpenDecision }{
        .{ .plan = .answered, .expected = .opened },
        .{ .plan = .withdrawn, .expected = .cancelled },
        .{ .plan = .early_withdrawn, .expected = .cancelled },
        .{ .plan = .ended_another_way, .expected = .failed },
        .{ .plan = .undefined_code, .expected = .failed },
    };
    for (cases) |case| {
        var peer = try PortalPeer.start(case.plan);
        const decision = openUriOver(std.testing.allocator, &peer.conn, "https://example.com", "");
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectEqual(case.expected, try decision);
    }
    // The two ways a request gets no decision at all are both failures, and
    // neither is reported as an opened URL: no decision on this request's
    // object, and no decision on any object.
    for ([_]FakePortal.Plan{ .never_decides, .other_request_decides }) |plan| {
        var peer = try PortalPeer.start(plan);
        const decision = openUriOver(std.testing.allocator, &peer.conn, "https://example.com", "");
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectError(error.MethodCallFailed, decision);
    }
}

test "api-w18 the appearance read answers only from the frame naming its own call" {
    // The appearance namespace answers `Read` with one variant, on a
    // connection that carries the traffic of every other call made on it. A
    // preference in a frame naming another call is not this host's
    // preference, and no answer at all is no preference rather than a guess.
    {
        var peer = try PortalPeer.start(.stray_answer);
        const theme = readAppearanceThemeOn(std.testing.allocator, &peer.conn);
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectEqual(@as(?PortalTheme, .light), try theme);

        const request = try peer.requestMessage();
        try std.testing.expectEqualStrings("org.freedesktop.portal.Settings", request.interface.?);
        try std.testing.expectEqualStrings("Read", request.member.?);
        var reader = dbus.BodyReader.init(request.body);
        try std.testing.expectEqualStrings("org.freedesktop.appearance", try reader.readString());
        try std.testing.expectEqualStrings("color-scheme", try reader.readString());
    }
    {
        var peer = try PortalPeer.start(.no_answer);
        const theme = readAppearanceThemeOn(std.testing.allocator, &peer.conn);
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectEqual(@as(?PortalTheme, null), try theme);
    }
    {
        var peer = try PortalPeer.start(.unknown_method);
        const theme = readAppearanceThemeOn(std.testing.allocator, &peer.conn);
        peer.finish();
        try std.testing.expectEqual(@as(?anyerror, null), peer.stand_in_failure);
        try std.testing.expectEqual(@as(?PortalTheme, null), try theme);
    }
}

test "portal builder generates valid D-Bus messages" {
    var builder = dbus.MessageBuilder.init(std.testing.allocator, .method_call, 100);
    defer builder.deinit();

    builder.destination = "org.freedesktop.FileManager1";
    builder.path = "/org/freedesktop/FileManager1";
    builder.interface = "org.freedesktop.FileManager1";
    builder.member = "ShowItems";
    builder.signature = "ass";

    const arr = try builder.startArray(4);
    try builder.writeString("file:///tmp/demo.txt");
    builder.finishArray(arr);
    try builder.writeString("");

    const wire = try builder.build();
    defer std.testing.allocator.free(wire);

    const parsed = try dbus.MessageParser.parse(wire);
    try std.testing.expectEqual(dbus.MessageType.method_call, parsed.msg_type);
    try std.testing.expectEqualStrings("org.freedesktop.FileManager1", parsed.destination.?);
    try std.testing.expectEqualStrings("ShowItems", parsed.member.?);
    try std.testing.expectEqualStrings("ass", parsed.signature.?);
}

test "api-w18 portal file chooser request carries only documented options" {
    const filters = [_]FileChooserFilter{
        .{ .name = "Text", .patterns = &.{"*.txt"} },
        .{ .name = "All", .patterns = &.{} },
    };
    var builder = dbus.MessageBuilder.init(std.testing.allocator, .method_call, 42);
    defer builder.deinit();
    try buildFileChooserRequest(&builder, .{
        .mode = .open_file,
        .parent_window = "x11:1a",
        .title = "pick one",
        .accept_label = "Take it",
        .multiple = true,
        .directory = true,
        .modal = true,
        .current_folder = "/home/user",
        .filters = &filters,
    }, "nogui7");

    const wire = try builder.build();
    defer std.testing.allocator.free(wire);
    const parsed = try dbus.MessageParser.parse(wire);
    try std.testing.expectEqualStrings("org.freedesktop.portal.Desktop", parsed.destination.?);
    try std.testing.expectEqualStrings("/org/freedesktop/portal/desktop", parsed.path.?);
    try std.testing.expectEqualStrings("org.freedesktop.portal.FileChooser", parsed.interface.?);
    try std.testing.expectEqualStrings("OpenFile", parsed.member.?);
    try std.testing.expectEqualStrings("ssa{sv}", parsed.signature.?);

    var reader = dbus.BodyReader.init(parsed.body);
    try std.testing.expectEqualStrings("x11:1a", try reader.readString());
    try std.testing.expectEqualStrings("pick one", try reader.readString());

    // Every entry is one key plus a typed variant. A key the FileChooser spec
    // does not document must not appear at all, and each documented key must
    // carry the variant type the spec gives it.
    const options = try reader.readArray(8);
    var options_reader = dbus.BodyReader.init(options);
    var entries: usize = 0;
    while (options_reader.cursor < options_reader.bytes.len) : (entries += 1) {
        // Each dict entry is a struct, so each one starts 8-aligned. The
        // writer pads; a reader that does not would read the second key out
        // of the first value's tail.
        options_reader.alignStruct();
        if (options_reader.cursor >= options_reader.bytes.len) break;
        const key = try options_reader.readString();
        const signature = try options_reader.readSignature();
        if (std.mem.eql(u8, key, "handle_token")) {
            try std.testing.expectEqualStrings("s", signature);
            try std.testing.expectEqualStrings("nogui7", try options_reader.readString());
        } else if (std.mem.eql(u8, key, "accept_label")) {
            try std.testing.expectEqualStrings("s", signature);
            try std.testing.expectEqualStrings("Take it", try options_reader.readString());
        } else if (std.mem.eql(u8, key, "multiple") or
            std.mem.eql(u8, key, "directory") or std.mem.eql(u8, key, "modal"))
        {
            try std.testing.expectEqualStrings("b", signature);
            try std.testing.expect(try options_reader.readBool());
        } else if (std.mem.eql(u8, key, "current_folder")) {
            // The spec types current_folder as an ay holding a raw path and
            // its NUL, not a file:// URI.
            try std.testing.expectEqualStrings("ay", signature);
            const bytes = try options_reader.readArray(1);
            try std.testing.expectEqualStrings("/home/user", bytes[0 .. bytes.len - 1]);
            try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
        } else if (std.mem.eql(u8, key, "filters")) {
            try std.testing.expectEqualStrings("a(sa(us))", signature);
            const list = try options_reader.readArray(8);
            var filters_reader = dbus.BodyReader.init(list);
            filters_reader.alignStruct();
            try std.testing.expectEqualStrings("Text", try filters_reader.readString());
            const types = try filters_reader.readArray(8);
            var types_reader = dbus.BodyReader.init(types);
            types_reader.alignStruct();
            // A glob is (0, pattern); a MIME type would be (1, type).
            try std.testing.expectEqual(@as(u32, 0), try types_reader.readU32());
            try std.testing.expectEqualStrings("*.txt", try types_reader.readString());
            filters_reader.alignStruct();
            try std.testing.expectEqualStrings("All", try filters_reader.readString());
            // Every file is a filter with no patterns, not a list holding `*`:
            // a chooser matches the whole name, so `*` on its own asks for the
            // file called `*` and shows nothing.
            const all_types = try filters_reader.readArray(8);
            try std.testing.expectEqual(@as(usize, 0), all_types.len);
        } else return error.UnexpectedPortalOption;
    }
    try std.testing.expectEqual(@as(usize, 7), entries);
}

test "api-w18 portal request path follows the documented sender and token" {
    const path = try requestPath(std.testing.allocator, ":1.42", "nogui7");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_42/nogui7",
        path,
    );
    try std.testing.expectError(
        error.NotABusName,
        requestPath(std.testing.allocator, "1_42", "nogui7"),
    );
}

test "api-w18 portal response codes decode to distinct outcomes" {
    const filters = [_]FileChooserFilter{.{ .name = "Text", .patterns = &.{"*.txt"} }};

    // The Request spec types the body (u a{sv}): a code, then the results.
    const build = struct {
        fn body(
            allocator: std.mem.Allocator,
            code: u32,
            uris: []const []const u8,
            filter_name: ?[]const u8,
        ) ![]u8 {
            var builder = dbus.MessageBuilder.init(allocator, .signal, 0);
            defer builder.deinit();
            try builder.writeU32(code);
            const dict = try builder.startArray(8);
            if (uris.len != 0) {
                try writeOptionKey(&builder, "uris", "as");
                const list = try builder.startArray(4);
                for (uris) |uri| try builder.writeString(uri);
                builder.finishArray(list);
            }
            if (filter_name) |name| {
                try writeOptionKey(&builder, "current_filter", "(sa(us))");
                try builder.startStruct();
                try builder.writeString(name);
                const types = try builder.startArray(8);
                builder.finishArray(types);
            }
            builder.finishArray(dict);
            return builder.build();
        }
    }.body;

    // A union outcome is checked with a switch, so a case that stops being
    // distinct fails the test instead of silently forwarding.
    const tag = struct {
        fn of(result: FileChooserResult) ?[]const u8 {
            return switch (result) {
                .selected => "selected",
                .cancelled => "cancelled",
                .aborted => "aborted",
                .empty_selection => "empty_selection",
                .failed => "failed",
            };
        }
        fn failure(result: FileChooserResult) ?FileChooserFailure {
            return switch (result) {
                .failed => |reason| reason,
                else => null,
            };
        }
    };

    // A user cancellation is not a failure and not an empty list.
    {
        const bytes = try build(std.testing.allocator, 1, &.{}, null);
        defer std.testing.allocator.free(bytes);
        const message = try dbus.MessageParser.parse(bytes);
        const result = try decodeResponse(std.testing.allocator, message.body, &filters);
        try std.testing.expectEqualStrings("cancelled", tag.of(result).?);
    }
    // An interaction that ended another way is its own outcome.
    {
        const bytes = try build(std.testing.allocator, 2, &.{}, null);
        defer std.testing.allocator.free(bytes);
        const message = try dbus.MessageParser.parse(bytes);
        const result = try decodeResponse(std.testing.allocator, message.body, &filters);
        try std.testing.expectEqualStrings("aborted", tag.of(result).?);
    }
    // Success with no path is an accepted dialog, not a cancellation.
    {
        const bytes = try build(std.testing.allocator, 0, &.{}, null);
        defer std.testing.allocator.free(bytes);
        const message = try dbus.MessageParser.parse(bytes);
        const result = try decodeResponse(std.testing.allocator, message.body, &filters);
        try std.testing.expectEqualStrings("empty_selection", tag.of(result).?);
    }
    // A code outside the documented table is unreadable, never "other".
    {
        const bytes = try build(std.testing.allocator, 7, &.{}, null);
        defer std.testing.allocator.free(bytes);
        const message = try dbus.MessageParser.parse(bytes);
        const result = try decodeResponse(std.testing.allocator, message.body, &filters);
        try std.testing.expectEqualStrings("failed", tag.of(result).?);
        try std.testing.expectEqual(FileChooserFailure.invalid_reply, tag.failure(result).?);
    }
    // A selection carries the URIs and the filter it names.
    {
        const bytes = try build(
            std.testing.allocator,
            0,
            &.{ "file:///tmp/a%20b.txt", "file:///tmp/c.txt" },
            "Text",
        );
        defer std.testing.allocator.free(bytes);
        const message = try dbus.MessageParser.parse(bytes);
        const result = try decodeResponse(std.testing.allocator, message.body, &filters);
        switch (result) {
            .selected => |selection| {
                defer freeUris(std.testing.allocator, selection.uris);
                try std.testing.expectEqual(@as(usize, 2), selection.uris.len);
                try std.testing.expectEqualStrings("file:///tmp/a%20b.txt", selection.uris[0]);
                try std.testing.expectEqual(@as(?usize, 0), selection.filter_index);
            },
            else => return error.ExpectedSelection,
        }
    }
    // A filter the request never offered stays unknown.
    {
        const bytes = try build(
            std.testing.allocator,
            0,
            &.{"file:///tmp/a.txt"},
            "Something Else",
        );
        defer std.testing.allocator.free(bytes);
        const message = try dbus.MessageParser.parse(bytes);
        const result = try decodeResponse(std.testing.allocator, message.body, &filters);
        switch (result) {
            .selected => |selection| {
                defer freeUris(std.testing.allocator, selection.uris);
                try std.testing.expect(selection.filter_index == null);
            },
            else => return error.ExpectedSelection,
        }
    }
}

test "api-w18 malformed late results release already decoded chooser paths" {
    var builder = dbus.MessageBuilder.init(std.testing.allocator, .signal, 0);
    defer builder.deinit();
    try builder.writeU32(0);
    const dict = try builder.startArray(8);
    try writeOptionKey(&builder, "uris", "as");
    const uris = try builder.startArray(4);
    try builder.writeString("file:///tmp/nogui-owned-malformed-response.txt");
    builder.finishArray(uris);
    try writeOptionKey(&builder, "current_filter", "(sa(us))");
    try builder.startStruct();
    try builder.writeString("Text");
    // The required filter-pattern array is absent after the owned URI copies.
    builder.finishArray(dict);
    const wire = try builder.build();
    defer std.testing.allocator.free(wire);
    const message = try dbus.MessageParser.parse(wire);
    const result = try decodeResponse(std.testing.allocator, message.body, &.{});
    try std.testing.expectEqual(FileChooserResult{ .failed = .invalid_reply }, result);
}

test "api-w18 portal uri decoding refuses what a portal must not send" {
    const decoded = try fileUriToPath(std.testing.allocator, "file:///tmp/a%20b.txt");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("/tmp/a b.txt", decoded);

    const local = try fileUriToPath(std.testing.allocator, "file://localhost/tmp/x");
    defer std.testing.allocator.free(local);
    try std.testing.expectEqualStrings("/tmp/x", local);

    try std.testing.expectError(
        error.NotAFileUri,
        fileUriToPath(std.testing.allocator, "https://example.com/x"),
    );
    try std.testing.expectError(
        error.RemoteHost,
        fileUriToPath(std.testing.allocator, "file://otherhost/tmp/x"),
    );
    try std.testing.expectError(
        error.InvalidEscape,
        fileUriToPath(std.testing.allocator, "file:///tmp/a%zz"),
    );
    try std.testing.expectError(
        error.NotAFileUri,
        fileUriToPath(std.testing.allocator, "file://"),
    );
}
