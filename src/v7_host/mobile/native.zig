//! Native mobile calls. SDL owns the window; this module owns no application
//! model. Android facts/bounds use physical window pixels, UIKit uses points.
//! JNI local references never escape a call; the native bridge owns globals.
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("sdl3");

pub const c = @cImport({
    @cInclude("nogui_mobile.h");
});

pub const Platform = enum { ios, android, unavailable };
pub const platform: Platform = if (builtin.os.tag == .ios)
    .ios
else if (builtin.os.tag == .linux and
    (std.mem.eql(u8, @tagName(builtin.abi), "android") or
        std.mem.eql(u8, @tagName(builtin.abi), "androideabi")))
    .android
else
    .unavailable;
pub const available = platform != .unavailable;
pub const platform_bridge = c.nogui_mobile_bridge;
pub const wire_tree = c.nogui_mobile_tree;
pub const wire_node = c.nogui_mobile_node;
pub const platform_request = c.nogui_mobile_request;
pub const ActionCallback = *const fn (?*anyopaque, [*c]const platform_request) callconv(.c) void;
pub const DirtyCallback = *const fn (?*anyopaque) callconv(.c) void;
pub const max_native_id: u64 = std.math.maxInt(i32);
pub const no_index: u64 = std.math.maxInt(u64);

pub const Error = error{
    Unsupported,
    WindowUnavailable,
    NativeThread,
    InvalidNativeArgument,
    NativeRefused,
    NativeFault,
    NativeOutOfMemory,
    NativeBufferTooSmall,
    BridgeCreationFailed,
};

pub fn check(code: c_int) Error!void {
    return switch (code) {
        c.NOGUI_MOBILE_OK => {},
        c.NOGUI_MOBILE_ERR_THREAD => error.NativeThread,
        c.NOGUI_MOBILE_ERR_ARGUMENT => error.InvalidNativeArgument,
        c.NOGUI_MOBILE_ERR_UNAVAILABLE => error.Unsupported,
        c.NOGUI_MOBILE_ERR_REFUSED => error.NativeRefused,
        c.NOGUI_MOBILE_ERR_FAULT => error.NativeFault,
        c.NOGUI_MOBILE_ERR_MEMORY => error.NativeOutOfMemory,
        c.NOGUI_MOBILE_ERR_BUFFER => error.NativeBufferTooSmall,
        else => error.NativeFault,
    };
}

fn iosWindow(window: sdl3.video.Window) Error!*anyopaque {
    if (comptime platform != .ios) return error.Unsupported;
    const properties = sdl3.c.SDL_GetWindowProperties(window.value);
    if (properties == 0) return error.WindowUnavailable;
    return sdl3.c.SDL_GetPointerProperty(
        properties,
        sdl3.c.SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER,
        null,
    ) orelse error.WindowUnavailable;
}

const AndroidLocal = struct {
    env: *anyopaque,
    activity: *anyopaque,

    fn init() Error!AndroidLocal {
        if (comptime platform != .android) return error.Unsupported;
        const env = sdl3.c.SDL_GetAndroidJNIEnv() orelse return error.WindowUnavailable;
        const activity = sdl3.c.SDL_GetAndroidActivity() orelse return error.WindowUnavailable;
        return .{ .env = env, .activity = activity };
    }

    fn deinit(self: AndroidLocal) void {
        if (comptime platform != .android) unreachable;
        c.nogui_android_release_local(self.env, self.activity);
    }
};

pub const WindowFacts = struct {
    insets: ?c.nogui_mobile_insets = null,
    keyboard: ?c.nogui_mobile_keyboard = null,
};

/// Unknown measurements stay null. Wrong thread, faults and corrupt arguments
/// remain errors; they are not rewritten as a hidden keyboard or zero insets.
pub fn pollWindow(window: sdl3.video.Window) Error!WindowFacts {
    // SAFETY: a shim writes its out-parameter only on NOGUI_MOBILE_OK, and each
    // result below is assigned by the same call that writes its out-parameter.
    // A target with no shim returned above and any other code returns through
    // `check`, so neither struct is read before the shim filled it.
    var insets: c.nogui_mobile_insets = undefined;
    // SAFETY: the keyboard shim writes this record and every read below sits
    // behind `try check(keyboard_result)`, which returns on any status but
    // NOGUI_MOBILE_OK.
    var keyboard: c.nogui_mobile_keyboard = undefined;
    // SAFETY: each of the two arms assigns it from the call that also writes
    // `insets`, and the third returns, so the `if` below never reads it
    // unassigned.
    var inset_result: c_int = undefined;
    // SAFETY: each of the two arms assigns it from the call that also writes
    // `keyboard`, and the third returns, so the `if` below never reads it
    // unassigned.
    var keyboard_result: c_int = undefined;
    switch (comptime platform) {
        .ios => {
            const handle = try iosWindow(window);
            inset_result = c.nogui_ios_window_safe_area(handle, &insets);
            keyboard_result = c.nogui_ios_window_keyboard(handle, &keyboard);
        },
        .android => {
            const local = try AndroidLocal.init();
            defer local.deinit();
            inset_result = c.nogui_android_window_insets(local.env, local.activity, &insets);
            keyboard_result = c.nogui_android_window_keyboard(local.env, local.activity, &keyboard);
        },
        .unavailable => return error.Unsupported,
    }
    var facts: WindowFacts = .{};
    if (inset_result != c.NOGUI_MOBILE_ERR_UNAVAILABLE) {
        try check(inset_result);
        facts.insets = insets;
    }
    if (keyboard_result != c.NOGUI_MOBILE_ERR_UNAVAILABLE) {
        try check(keyboard_result);
        if (keyboard.status != c.NOGUI_MOBILE_ERR_UNAVAILABLE) {
            try check(keyboard.status);
            facts.keyboard = keyboard;
        }
    }
    return facts;
}

/// Give a back request back to the platform, which is what a decision to defer
/// turns into.
///
/// The key event cannot be handed back: the pump that observed it already
/// removed it from SDL's queue, so a deferral with no platform action behind it
/// left the key travelling on as an ordinary key press the model would act on.
/// Only Android has a system back control, so the other targets have nothing to
/// defer to and say so rather than pretending a deferral happened.
pub fn deferBack() Error!void {
    switch (comptime platform) {
        .android => {
            const local = try AndroidLocal.init();
            defer local.deinit();
            try check(c.nogui_android_defer_back(local.env, local.activity));
        },
        .ios, .unavailable => return error.Unsupported,
    }
}

/// Last native pressure code, read only in response to an actual host signal.
/// Android values are the named NOGUI_MOBILE_ANDROID_TRIM_* ABI codes.
pub fn memoryPressureCode() Error!c_int {
    const code = switch (comptime platform) {
        .ios => c.nogui_ios_memory_pressure(),
        .android => c.nogui_android_memory_pressure(),
        .unavailable => return error.Unsupported,
    };
    if (code < 0) try check(code);
    return code;
}

pub fn createBridge(user: ?*anyopaque, action: ActionCallback, dirty: DirtyCallback) Error!*platform_bridge {
    const bridge = switch (comptime platform) {
        .ios => c.nogui_ios_a11y_new(user, action, dirty),
        .android => c.nogui_android_a11y_new(user, action, dirty),
        .unavailable => return error.Unsupported,
    };
    return bridge orelse error.BridgeCreationFailed;
}

pub fn freeBridge(bridge: *platform_bridge) void {
    switch (comptime platform) {
        .ios => c.nogui_ios_a11y_free(bridge),
        .android => c.nogui_android_a11y_free(bridge),
        .unavailable => unreachable,
    }
}

pub fn attach(bridge: *platform_bridge, window: sdl3.video.Window) Error!void {
    switch (comptime platform) {
        .ios => try check(c.nogui_ios_a11y_attach(bridge, try iosWindow(window))),
        .android => {
            const local = try AndroidLocal.init();
            defer local.deinit();
            try check(c.nogui_android_a11y_attach(bridge, local.env, local.activity));
        },
        .unavailable => return error.Unsupported,
    }
}

pub fn detach(bridge: *platform_bridge) void {
    switch (comptime platform) {
        .ios => c.nogui_ios_a11y_detach(bridge),
        .android => c.nogui_android_a11y_detach(bridge),
        .unavailable => unreachable,
    }
}

pub fn update(bridge: *platform_bridge, tree: *const wire_tree) Error!void {
    const result = switch (comptime platform) {
        .ios => c.nogui_ios_a11y_update(bridge, tree),
        .android => c.nogui_android_a11y_update(bridge, tree),
        .unavailable => return error.Unsupported,
    };
    try check(result);
}

pub fn isActive(bridge: *const platform_bridge) Error!bool {
    const result = switch (comptime platform) {
        .ios => c.nogui_ios_a11y_is_active(bridge),
        .android => c.nogui_android_a11y_is_active(bridge),
        .unavailable => return error.Unsupported,
    };
    if (result < 0) try check(result);
    return result != 0;
}

pub fn setWindowFocused(bridge: *platform_bridge, focused: bool) Error!void {
    const result = switch (comptime platform) {
        .ios => c.nogui_ios_a11y_set_window_focused(bridge, @intFromBool(focused)),
        .android => c.nogui_android_a11y_set_window_focused(bridge, @intFromBool(focused)),
        .unavailable => return error.Unsupported,
    };
    try check(result);
}

pub fn layoutChanged(bridge: *platform_bridge) Error!void {
    const result = switch (comptime platform) {
        .ios => c.nogui_ios_a11y_layout_changed(bridge),
        .android => c.nogui_android_a11y_layout_changed(bridge),
        .unavailable => return error.Unsupported,
    };
    try check(result);
}

/// The app owns this UIKit input. The shim alone forwards its edits; do not
/// also forward those edits through SDL/a second delegate into the same model.
pub fn bindTextInput(bridge: *platform_bridge, input: *anyopaque, native_id: u64) Error!void {
    if (comptime platform != .ios) return error.Unsupported;
    try check(c.nogui_ios_a11y_bind_text_input(bridge, input, native_id));
}

pub fn unbindTextInput(bridge: *platform_bridge) void {
    if (comptime platform != .ios) unreachable;
    c.nogui_ios_a11y_unbind_text_input(bridge);
}
