//! The one place the macOS adapters reach the platform.
//!
//! Everything native lives in `shim/nogui_macos.m`, and this file is its only
//! caller. That split is deliberate:
//!
//!   * The shim declares no SDK type, so its header translates on any target
//!     and the adapters above it are ordinary Zig with ordinary typed results.
//!   * The shim owns every Objective-C object, every CoreFoundation retain
//!     and every framework error code. A Zig value never holds one.
//!   * `Status` is the one place a platform refusal becomes a typed Zig
//!     result, so no adapter has to match raw integers.
//!
//! Two invariants hold for every native call made through here:
//!
//!   * MAIN THREAD. AppKit, Security and CoreVideo are all main-thread
//!     objects. `Status.thread` is what a caller off the main thread gets,
//!     and `onMain` is how a worker reaches the thread these need. That thread
//!     is SDL's main thread, which is the one the host already pumps.
//!   * BORROWED WINDOWS. A `NativeWindow` is the `NSWindow` SDL publishes as
//!     `SDL_PROP_WINDOW_COCOA_WINDOW`. The `sdl3.video.Window` that owns it
//!     keeps owning it; these adapters only borrow, and they never hand the
//!     pointer to a client that might render with it.
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("sdl3");

const c = @cImport({
    @cInclude("nogui_macos.h");
});

/// The shim's declarations, re-exported so the adapters above call them
/// through one import instead of each opening its own `@cImport`.
pub const shim = c;

/// True on the target these adapters are written for. The module still
/// compiles elsewhere so a host can decide at run time instead of failing to
/// build, but every entry point below reports a typed unavailability there.
///
/// That run-time refusal is not enough on its own. The shim is Objective-C a
/// macOS build compiles and nothing else does, so a call the guard skips is
/// still emitted, and every other target then fails to link on a symbol
/// nothing defines. A private callback retained by a vtable is enough to
/// trigger that, because `onMain` is what brings the callback into the build.
/// Every reference to a shim entry point therefore opens with
/// `if (comptime !available) return ...;`, which is what keeps the call out
/// of the object file rather than only out of the run.
pub const available = builtin.os.tag == .macos;

/// The typed answer every shim call produces.
///
/// `unavailable` is not a failure: it is how the platform says "this
/// capability does not exist here", which is a different fact from "you asked
/// wrongly" and from "I refused".
pub const Status = enum {
    ok,
    /// The call was made off the macOS main thread.
    thread,
    /// A handle or an argument was missing or out of range.
    argument,
    /// A string argument was not valid UTF-8.
    encoding,
    /// The platform refused: a locked store, a denied item, the wrong tab.
    refused,
    /// The platform does not offer this on this system.
    unavailable,
    /// A caller buffer was too small; the required length was reported.
    buffer,
    /// The framework raised an exception the shim caught.
    fault,
    /// An allocation failed.
    memory,

    pub fn of(code: c_int) Status {
        return switch (code) {
            0 => .ok,
            -1 => .thread,
            -2 => .argument,
            -3 => .encoding,
            -4 => .refused,
            -5 => .unavailable,
            -6 => .buffer,
            -7 => .fault,
            -8 => .memory,
            else => .fault,
        };
    }

    /// True when the call did what it was asked. Every other value is a
    /// refusal a caller has to handle, and none of them is treated as a
    /// success anywhere in this directory.
    pub fn isOk(self: Status) bool {
        return self == .ok;
    }
};

/// A failure with its reason attached. Adapters return one of these rather
/// than a bare error, because "the platform has no such capability" and "the
/// caller passed nonsense" are not the same defect.
pub const Error = error{
    /// The adapter needs the macOS main thread and did not get it.
    NotOnMainThread,
    /// The platform does not provide this capability.
    Unsupported,
    /// The platform refused the request. An adapter's own bound refusing a
    /// request before the platform was asked is the same answer, and says the
    /// same thing: nothing was changed.
    Refused,
    /// A string or handle was not usable.
    BadArgument,
    /// The framework failed.
    PlatformFault,
    /// The host was built without the shim, or the shim refused to attach.
    ShimUnavailable,
    /// The caller has to try again with a larger buffer.
    BufferTooSmall,
    /// A caller's bytes could not be copied, or a string could not be read
    /// back, because memory ran out. Every entry point here copies or
    /// allocates on the caller's behalf, so this is a reachable outcome and
    /// not an internal detail a caller cannot act on.
    OutOfMemory,
};

pub fn fail(status: Status) Error {
    return switch (status) {
        .ok => error.BadArgument,
        .thread => error.NotOnMainThread,
        .argument, .encoding => error.BadArgument,
        .refused => error.Refused,
        .unavailable => error.Unsupported,
        .buffer => error.BufferTooSmall,
        .fault, .memory => error.PlatformFault,
    };
}

/// Turn a shim result into a typed answer. This is for the entry points whose
/// only answer is success or a refusal. A call that reports a fact reads it
/// with `fact` or a wire switch instead, because `Status` maps only zero to
/// `.ok` and would call the platform's own answer a fault.
pub fn check(status: Status) Error!void {
    if (!status.isOk()) return fail(status);
}

/// Read a shim return that carries a fact rather than a status.
///
/// Rule 4 of the shim's ABI is that a non-negative return is a value and a
/// negative one is a NOGUI_MACOS_ERR_* refusal. `Status` maps only zero to
/// `.ok`, so a value has to be split on its sign before it is mapped: handing
/// a whole answer to `Status.of` would report the platform's own `1` as a
/// fault for a call that did exactly what it was asked.
pub fn fact(raw: c_int) Error!bool {
    if (raw < 0) return fail(Status.of(raw));
    return raw != 0;
}

/// True when this process is the thread AppKit accepts.
pub fn isMainThread() bool {
    if (!available) return false;
    return sdl3.isMainThread();
}

/// Run `work` on the macOS main thread and wait for it.
///
/// Waiting here is safe precisely because the caller is never already on that
/// thread: a caller that is runs the work inline instead of deadlocking.
///
/// The refusal is `comptime` because this function is the only thing that
/// brings `work` into the build: a callback it declines to call is still
/// compiled, and every shim entry point such a callback names is undefined
/// off macOS. A build without the shim must not analyse it at all.
pub fn onMain(comptime T: type, comptime work: *const fn (*T) void, context: *T) Error!void {
    if (comptime !available) return error.ShimUnavailable;
    if (sdl3.isMainThread()) {
        work(context);
        return;
    }
    sdl3.runOnMainThread(T, work, context, true) catch return error.NotOnMainThread;
}

/// Post `work` to the main thread without waiting for it, for a callback that
/// must not block its own thread and reports through a typed drain. Returns
/// false when SDL stopped before dispatching, so a caller can complete its own
/// request instead of leaving it unanswered.
pub fn postMain(comptime T: type, comptime work: *const fn (*T) void, context: *T) bool {
    if (comptime !available) return false;
    if (sdl3.isMainThread()) {
        work(context);
        return true;
    }
    sdl3.runOnMainThread(T, work, context, false) catch return false;
}

/// Which of the platform's strings a caller wants to read. One entry point
/// serves them all, so there is a single buffer contract instead of one per
/// source.
pub const StringSource = enum {
    window_title,
    window_represented_path,
    services_label,
    recent_list,
    find_text,
    find_options,
    bundle_id,

    fn wire(self: StringSource) c_int {
        return switch (self) {
            .window_title => 0,
            .window_represented_path => 1,
            .services_label => 2,
            .recent_list => 3,
            .find_text => 4,
            .find_options => 5,
            .bundle_id => 6,
        };
    }
};

/// Read one of the platform's strings into memory the caller owns.
///
/// The shim reports the length it needs whenever the buffer is too small, so
/// a caller never guesses a size and a refusal is never mistaken for an empty
/// string.
pub fn readString(
    gpa: std.mem.Allocator,
    source: StringSource,
    index: i32,
    handle: ?*anyopaque,
) Error![]u8 {
    if (comptime !available) return error.ShimUnavailable;
    const wire = source.wire();
    var first: [256]u8 = undefined;
    var needed: usize = 0;
    var status = Status.of(c.nogui_macos_read_string(
        wire,
        index,
        handle,
        &first,
        first.len,
        &needed,
    ));
    if (status == .buffer) {
        if (needed == 0) return gpa.alloc(u8, 0);
        const grown = try gpa.alloc(u8, needed + 1);
        defer gpa.free(grown);
        status = Status.of(c.nogui_macos_read_string(
            wire,
            index,
            handle,
            grown.ptr,
            grown.len,
            &needed,
        ));
        if (status == .buffer) return error.BufferTooSmall;
        if (!status.isOk()) return fail(status);
        @memset(grown[needed..], 0);
        return gpa.dupe(u8, grown[0..needed]);
    }
    if (!status.isOk()) return fail(status);
    return gpa.dupe(u8, first[0..needed]);
}

/// The width of the buffer a caller hands in to read a class name.
///
/// An Objective-C class name is an identifier, so this is generous; a longer
/// one is refused rather than truncated into the name of a different class.
/// The width is the buffer, not the name: the buffer holds the name AND the
/// terminator the C ABI reads, so a name of this many bytes leaves no room for
/// that terminator, is reported as `error.BufferTooSmall`, and the longest name
/// that comes back is one byte shorter.
pub const class_name_limit = 128;

/// The longest string the shim will copy into an SDK object, matching
/// `NOGUI_MACOS_MAX_TEXT` in the shim header.
///
/// This is a Zig constant rather than a reference to the header's `#define`
/// so the limit has one name the Zig side can rely on. `translate-c` exposes a
/// macro as a named Zig constant only incidentally, and a limit that silently
/// fails to resolve would turn a "too long" refusal into an unchecked copy.
pub const max_text: usize = 65536;

/// NUL-terminated scratch for the strings one shim call needs. The shim copies
/// what it keeps, so the buffer only has to outlive the call.
pub const Scratch = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Scratch {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Scratch) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// A NUL-terminated copy of `text`, or null for a null slice.
    pub fn nul(self: *Scratch, text: []const u8) Error!?[*:0]const u8 {
        if (text.len > max_text) return error.BadArgument;
        return (try self.arena.allocator().dupeZ(u8, text)).ptr;
    }
};

/// A view over a C string a callback owns. Empty for a null pointer, because
/// "the platform had no such string" is a value the caller has to see.
pub fn view(bytes: [*c]const u8) []const u8 {
    if (bytes == null) return "";
    return std.mem.span(bytes);
}

/// The `NSWindow` behind an SDL window, borrowed.
///
/// SDL publishes it as `SDL_PROP_WINDOW_COCOA_WINDOW`, an
/// `__unsafe_unretained NSWindow *`. Borrowed means exactly that: the window
/// SDL created outlives this value, no adapter here ever releases it, and it
/// is null on any other video driver.
pub const NativeWindow = struct {
    /// The opaque `NSWindow *`. Never handed to a client for rendering, and
    /// never stored past the lifetime of the SDL window it came from.
    handle: *anyopaque,
    /// The SDL id, so a platform callback can name the window it came from.
    id: sdl3.video.WindowId,
    /// The SDL window that owns `handle`. Holding it is what keeps the
    /// borrowed handle valid.
    window: sdl3.video.Window,

    /// Borrow the NSWindow SDL is already using for this window.
    ///
    /// Null when this build is off macOS or the window has no Cocoa window,
    /// which is every other video driver. A window SDL cannot name is a
    /// handle problem, and a property read it refuses is reported the same way
    /// a missing Cocoa window is: there is no platform window behind it.
    pub fn borrow(window: sdl3.video.Window) Error!?NativeWindow {
        if (!available) return null;
        const id = window.getId() catch return error.BadArgument;
        const properties = window.getProperties() catch return null;
        const cocoa = properties.cocoa_window orelse return null;
        const handle = cocoa.value orelse return null;
        return .{
            .handle = handle,
            .id = id,
            .window = window,
        };
    }

    /// The window's content view, retained for as long as the caller holds
    /// the result. The accessibility adapter is the only user: it hands the
    /// pointer straight to AccessKit, which takes its own reference.
    pub fn contentView(self: NativeWindow) Error!*anyopaque {
        if (comptime !available) return error.ShimUnavailable;
        const content = c.nogui_macos_window_content_view(self.handle) orelse return error.Unsupported;
        return @ptrCast(content);
    }

    /// Release a content view from `contentView`. The view itself stays owned
    /// by its window; this drops the retain this module took.
    pub fn releaseContentView(content: *anyopaque) void {
        if (comptime !available) return;
        c.nogui_macos_content_view_release(@ptrCast(content));
    }

    /// The backing scale factor of the screen this window is on. This is the
    /// factor physical pixels are counted in, and the one the shared
    /// accessibility adapter needs to publish.
    pub fn backingScale(self: NativeWindow) f32 {
        if (comptime !available) return 1;
        const scale = c.nogui_macos_window_backing_scale(self.handle);
        if (scale <= 0) return 1;
        return @floatCast(scale);
    }

    pub fn isKey(self: NativeWindow) bool {
        if (comptime !available) return false;
        return c.nogui_macos_window_is_key(self.handle) == 1;
    }

    pub fn isMain(self: NativeWindow) bool {
        if (comptime !available) return false;
        return c.nogui_macos_window_is_main(self.handle) == 1;
    }

    /// Show this window and make it key. Reports what AppKit answered, because
    /// asking a window to appear and a window being visible are two facts.
    pub fn makeKeyAndOrderFront(self: NativeWindow) Error!bool {
        if (comptime !available) return error.ShimUnavailable;
        return fact(c.nogui_macos_window_make_key_and_order_front(self.handle));
    }

    pub fn orderOut(self: NativeWindow) Error!void {
        if (comptime !available) return error.ShimUnavailable;
        try check(Status.of(c.nogui_macos_window_order_out(self.handle)));
    }

    /// The window's Objective-C class name, NUL-terminated into `buffer`.
    ///
    /// AccessKit's focus forwarder is added to a window CLASS, so this is a
    /// fact to read rather than a name to assume. SDL declares `SDL3Window`,
    /// but a host whose window is a different class would get a forwarder on a
    /// class it does not have, and VoiceOver would still not find the focused
    /// element. The result is NUL-terminated because the C ABI reads it as a C
    /// string, and a name that does not fit is refused rather than truncated
    /// into a different class.
    ///
    /// The shim refuses a name that leaves no room for that terminator, so the
    /// sentinel slice below is always in bounds and `needed` is always shorter
    /// than the buffer.
    pub fn className(self: NativeWindow, buffer: *[class_name_limit]u8) Error![:0]const u8 {
        if (comptime !available) return error.ShimUnavailable;
        var needed: usize = 0;
        const status = Status.of(c.nogui_macos_window_class_name(
            self.handle,
            buffer,
            buffer.len,
            &needed,
        ));
        // A buffer the shim reports as too small is the CALLER's buffer being
        // small, which `check` names `BufferTooSmall` rather than a fault.
        try check(status);
        return buffer[0..needed :0];
    }
};

test "api-w23 macos a fact the platform returned is not a fault" {
    // The shim answers a fact-bearing entry point with zero or one and a
    // refusal with a negative NOGUI_MACOS_ERR_* code. `Status.of` maps only
    // zero to ok, so an answer of 1 read as a status would be reported as a
    // framework fault for a call that did exactly what it was asked.
    try std.testing.expect(try fact(1));
    try std.testing.expect(!(try fact(0)));
    try std.testing.expectError(Error.NotOnMainThread, fact(-1));
    try std.testing.expectError(Error.Unsupported, fact(-5));
}

test "api-w23 a macos window class name is a typed refusal off macos" {
    // The class is an AppKit fact about a real NSWindow. Off macOS there is no
    // such object behind an SDL window, so the read is a typed unavailability
    // rather than a framework fault for a window that never existed.
    if (comptime available) return error.SkipZigTest;
    const window: NativeWindow = .{
        .handle = @ptrFromInt(0x1234),
        .id = 1,
        .window = .{ .value = @ptrFromInt(0x1234) },
    };
    var buffer: [class_name_limit]u8 = @splat(0);
    try std.testing.expectError(error.ShimUnavailable, window.className(&buffer));
}
