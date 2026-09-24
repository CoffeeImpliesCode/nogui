//! SDL window ownership and logical input translation with physical surface extents.
const std = @import("std");
const sdl3 = @import("sdl3");
const nogui = @import("nogui");
const geometry = nogui.geometry;
const sdl_session = @import("sdl_session.zig");

pub const Window = struct {
    /// Borrow for platform-surface adapters; this Window retains ownership.
    sdl: sdl3.video.Window,
    id: sdl3.video.WindowId,

    /// Every field defaulted: a window that published nothing reads as
    /// generation zero, which is the answer an observer with nothing adopted
    /// already holds. The defaults are what makes "never published" and
    /// "published the origin" different values.
    candidate_publication: CandidatePublication = .{},
    /// The candidate rectangle the last SUCCESSFUL handover to the platform
    /// published, plus the counter that says which handover it was.
    ///
    /// A broken layout is refused before SDL is called, so a publication here
    /// always names bytes the platform actually holds. That is what makes this
    /// record — and never the platform's own answer — the thing an observer
    /// reads: SDL publishes a default rectangle before anything sets one, and
    /// that default is not a layout any endpoint produced.
    ///
    /// `generation` counts successful publications and wraps rather than
    /// saturating, and it is a counter instead of a rectangle comparison
    /// because a republication of the SAME geometry is still a new
    /// publication: the application, not the geometry, decided the input
    /// method belongs there.
    pub const CandidatePublication = struct {
        area: geometry.WindowRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        cursor: f32 = 0,
        generation: u64 = 0,
    };

    pub const Extent = geometry.DeviceSize;

    /// The client area in both spaces, read together.
    ///
    /// `logical` is the space every input event is reported in and layout runs
    /// in; `pixels` is the space a present uses. They are ONE reading because a
    /// caller that takes them separately can be handed two different answers for
    /// one event: a resize or a display-scale change lands between the two
    /// queries, and the routed event then describes a window the observed state
    /// never saw. Pointer, IME and render coordinates are three views of this
    /// one value, so the host measures once and hands the same one to all three.
    pub const ClientExtent = struct {
        logical: geometry.WindowSize,
        pixels: geometry.DeviceSize,
    };

    pub const Options = struct {
        title: [:0]const u8,
        width: u32,
        height: u32,
        resizable: bool = false,
        hidden: bool = false,
        vulkan: bool = false,
    };

    /// The client-size limits the platform holds. One named type, so a
    /// caller reading the platform's answer and one reading this host's
    /// request do not each invent an anonymous struct with its own error set.
    pub const SizeLimits = struct {
        minimum: nogui.window_contract.Size,
        maximum: nogui.window_contract.Size,
    };

    /// Native keys remain available for demo shortcuts after routed input.
    pub const Event = union(enum) {
        close,
        resize: struct { pixels: Extent, core: nogui.Event },
        input: nogui.Event,
        key_down: struct {
            native: sdl3.keycode.Keycode,
            core: nogui.Event,
            repeat: bool,
        },
    };

    /// The caller must keep its Application alive until this Window is destroyed.
    pub fn init(options: Options) !Window {
        const sdl = try sdl3.video.Window.init(options.title, options.width, options.height, .{
            .resizable = options.resizable,
            .hidden = options.hidden,
            .vulkan = options.vulkan,
        });
        errdefer sdl.deinit();
        return .{ .sdl = sdl, .id = try sdl.getId() };
    }

    pub fn show(self: *Window) !void {
        try self.sdl.show();
    }

    /// The native surface's physical extent. This is the size a present uses,
    /// and on a scaled display it is a different value from `logicalSize()`; a
    /// renderer that presents the logical size clears outside its own image.
    pub fn pixelExtent(self: *const Window) !Extent {
        const pixels = try self.sdl.getSizeInPixels();
        return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
    }

    /// The client area in window-logical coordinates, which is also the space
    /// every input event is reported in.
    pub fn logicalSize(self: *const Window) !geometry.WindowSize {
        const logical = try self.sdl.getSize();
        return .{
            .width = @floatFromInt(logical[0]),
            .height = @floatFromInt(logical[1]),
        };
    }

    /// One measurement of the client area in both spaces.
    pub fn clientExtent(self: *const Window) !ClientExtent {
        const logical = try self.sdl.getSize();
        const pixels = try self.sdl.getSizeInPixels();
        return .{
            .logical = .{
                .width = @floatFromInt(logical[0]),
                .height = @floatFromInt(logical[1]),
            },
            .pixels = .{
                .width = @intCast(pixels[0]),
                .height = @intCast(pixels[1]),
            },
        };
    }

    /// The platform frame around the client area, or null where the backend has
    /// no border information to report. Four zeroes are a borderless window,
    /// not a missing measurement.
    pub fn borders(self: *const Window) ?nogui.window_contract.Borders {
        const frame = self.sdl.getBordersSize() catch return null;
        return .{
            .top = @intCast(frame.top),
            .left = @intCast(frame.left),
            .bottom = @intCast(frame.bottom),
            .right = @intCast(frame.right),
        };
    }

    /// The native id SDL reports for this window's parent, or null when it has
    /// none. Measured rather than copied from the creation options, so a
    /// backend that drops the parent property is visible instead of assumed.
    pub fn nativeParent(self: *const Window) ?sdl3.video.WindowId {
        const parent = self.sdl.getParent() orelse return null;
        return parent.getId() catch null;
    }

    /// The client-size limits the platform currently holds. A zero maximum is
    /// the platform's own way of saying it has no upper bound, which is the
    /// same answer a caller gets back when it asked for none.
    pub fn sizeLimits(self: *const Window) !SizeLimits {
        const minimum = try self.sdl.getMinimumSize();
        const maximum = try self.sdl.getMaximumSize();
        return .{
            .minimum = .{ .width = @intCast(minimum[0]), .height = @intCast(minimum[1]) },
            .maximum = .{ .width = @intCast(maximum[0]), .height = @intCast(maximum[1]) },
        };
    }

    pub fn setSize(self: *Window, extent: nogui.window_contract.Size) !void {
        try self.sdl.setSize(extent.width, extent.height);
    }

    pub fn setMinimumSize(self: *Window, extent: nogui.window_contract.Size) !void {
        try self.sdl.setMinimumSize(extent.width, extent.height);
    }

    pub fn setMaximumSize(self: *Window, extent: nogui.window_contract.Size) !void {
        try self.sdl.setMaximumSize(extent.width, extent.height);
    }

    /// Ask the window manager for its own menu at a client point. This is a
    /// request with no observed counterpart: a platform that has no such menu
    /// accepts it and shows nothing, so a caller must not read the absence of
    /// a change as a refusal.
    pub fn systemMenu(self: *const Window, x: i32, y: i32) !void {
        try self.sdl.showSystemMenu(x, y);
    }

    /// Ask the window manager to place this window at a desktop position. The
    /// request is asynchronous on every backend: the position this host
    /// observes afterwards is the compositor's answer, not the request.
    pub fn setPosition(self: *Window, point: nogui.window_contract.Point) !void {
        try self.sdl.setPosition(.{ .absolute = point.x }, .{ .absolute = point.y });
    }

    pub fn deinit(self: *Window) void {
        self.sdl.deinit();
        self.* = undefined;
    }

    /// Native text input for one focused text element. The core drives this
    /// through `nogui.text_input.Native`; the SDL calls themselves never
    /// reach the App.
    pub fn nativeTextInput(self: *Window) nogui.text_input.Native {
        return .{
            .user = self,
            .start = nativeStart,
            .stop = nativeStop,
            .set_area = nativeSetArea,
            .clear_composition = nativeClearComposition,
        };
    }

    /// True while SDL delivers committed text and preedit for this window.
    pub fn textInputActive(self: *const Window) bool {
        return sdl3.keyboard.textInputActive(self.sdl);
    }

    /// Publish the candidate rectangle in window coordinates, plus the caret's
    /// x offset inside it. SDL takes whole window pixels for both and places
    /// the candidate window at the rectangle origin plus that offset, so an
    /// endpoint that anchors its rectangle at the caret publishes zero and one
    /// that publishes a line box publishes the caret's place inside it.
    ///
    /// A rectangle or an offset that is not finite is refused BEFORE SDL is
    /// called, so the platform keeps exactly the bytes the last successful
    /// publication gave it. Coercing a broken layout to a zero rectangle would
    /// anchor every input method at the window origin and report success while
    /// doing it, and the record would then name a publication that never
    /// happened.
    pub fn setTextInputArea(self: *Window, area: geometry.WindowRect, cursor: f32) !void {
        if (!isFiniteArea(area)) return error.InvalidCandidateArea;
        if (!std.math.isFinite(cursor)) return error.InvalidCandidateCursor;
        try sdl3.keyboard.setTextInputArea(self.sdl, candidateArea(area), candidateCursor(cursor));
        self.candidate_publication = .{
            .area = area,
            .cursor = cursor,
            .generation = self.candidate_publication.generation +% 1,
        };
    }

    pub fn startTextInput(self: *Window) !void {
        try sdl3.keyboard.startTextInput(self.sdl);
    }

    pub fn stopTextInput(self: *Window) !void {
        try sdl3.keyboard.stopTextInput(self.sdl);
    }

    pub fn clearComposition(self: *Window) !void {
        try sdl3.keyboard.clearComposition(self.sdl);
    }

    /// Translate a polled event against the client measurement its caller
    /// already took. The caller owns the reading, so this conversion is total
    /// and never asks the platform a second question about a size the event it
    /// is translating has already been given: a routed resize reports the
    /// extents the host published in the same event, and a routed finger
    /// reports the logical box that extents named.
    ///
    /// The extents are supplied even for an event that needs neither, so the
    /// argument is never optional and there is no path where a resize event
    /// has to invent its own extents.
    pub fn translate(
        self: *const Window,
        raw: *const sdl3.events.Event,
        extents: ClientExtent,
    ) ?Event {
        switch (raw.*) {
            inline .finger_down, .finger_motion, .finger_up, .finger_canceled => {
                return translateTouch(self.id, raw, extents.logical);
            },
            else => {},
        }
        return translateEvent(self.id, raw, extents, sdl3.keyboard.getModState());
    }

    /// SDL takes whole window pixels. A degenerate candidate area still gets one
    /// pixel, so the IME always has a place to anchor.
    ///
    /// A rectangle that is not finite has no pixel and no anchor, so it
    /// converts to zeroes — which is exactly why `setTextInputArea` refuses it
    /// before this converter runs. The conversion stays total so a caller
    /// reading it as a pure function cannot trap on a broken layout.
    pub fn candidateArea(area: geometry.WindowRect) sdl3.rect.IRect {
        if (!isFiniteArea(area)) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{
            .x = roundPixel(area.x),
            .y = roundPixel(area.y),
            .w = @max(roundPixel(area.w), 1),
            .h = @max(roundPixel(area.h), 1),
        };
    }

    /// The caret offset inside the candidate rectangle, in whole window pixels.
    pub fn candidateCursor(cursor: f32) i32 {
        if (!std.math.isFinite(cursor)) return 0;
        return roundPixel(cursor);
    }
};

/// Pure translation permits logical-coordinate and window-isolation tests
/// without creating an SDL window or starting a video driver. `mod` is the
/// modifier state read from SDL, passed in rather than read here so a test can
/// feed a modifier set the running platform cannot produce for it.
fn translateEvent(
    window_id: sdl3.video.WindowId,
    raw: *const sdl3.events.Event,
    extents: Window.ClientExtent,
    mod: sdl3.keycode.KeyModifier,
) ?Window.Event {
    switch (raw.*) {
        .quit => return .close,
        .window_close_requested => |we| {
            if (we.id == window_id) return .close;
        },
        inline .window_resized, .window_pixel_size_changed => |we| {
            if (we.id == window_id) {
                return .{ .resize = .{
                    .pixels = extents.pixels,
                    .core = .{ .resize = .{
                        .width = extents.logical.width,
                        .height = extents.logical.height,
                    } },
                } };
            }
        },
        .mouse_motion => |motion| {
            if (!belongsToWindow(motion.window_id, window_id) or isSyntheticTouch(motion.id))
                return null;
            const point: geometry.WindowPoint = .{ .x = motion.x, .y = motion.y };
            return .{ .input = .{ .mouse_move = .{
                .x = point.x,
                .y = point.y,
                .buttons = .{
                    .left = motion.state.left,
                    .right = motion.state.right,
                    .middle = motion.state.middle,
                    .back = motion.state.side1,
                    .forward = motion.state.side2,
                },
                .modifiers = modifiers(mod),
            } } };
        },
        .window_mouse_leave => |we| {
            if (we.id == window_id) return .{ .input = .{ .mouse_leave = {} } };
        },
        .window_focus_lost => |we| {
            if (we.id == window_id) return .{ .input = .{ .window_focus_lost = {} } };
        },
        .mouse_button_down, .mouse_button_up => |button| {
            if (!belongsToWindow(button.window_id, window_id) or isSyntheticTouch(button.id))
                return null;
            const point: geometry.WindowPoint = .{ .x = button.x, .y = button.y };
            const core: nogui.event.PointerEvent = .{
                .button = mouseButton(button.button),
                .x = point.x,
                .y = point.y,
                .click_count = button.clicks,
                .modifiers = modifiers(mod),
            };
            return .{ .input = if (button.down)
                .{ .mouse_down = core }
            else
                .{ .mouse_up = core } };
        },
        .mouse_wheel => |wheel| {
            if (!belongsToWindow(wheel.window_id, window_id) or isSyntheticTouch(wheel.id))
                return null;
            const point: geometry.WindowPoint = .{ .x = wheel.x, .y = wheel.y };
            return .{
                .input = .{
                    .mouse_wheel = .{
                        .x = point.x,
                        .y = point.y,
                        .delta_x = wheel.scroll_x,
                        .delta_y = wheel.scroll_y,
                        .unit = .line,
                        .natural = wheel.direction == .flipped,
                        .modifiers = modifiers(mod),
                        // SDL reports no scroll phase, and this host invents none: a
                        // gesture's begin, momentum and end cannot be told apart here,
                        // so every wheel event is one `.update`. A consumer that needs
                        // those phases must get them from a driver that reports them.
                    },
                },
            };
        },
        .key_down => |key| {
            if (!belongsToWindow(key.window_id, window_id)) return null;
            const core: nogui.Event = .{ .key_down = translateKey(key) };
            if (key.key) |native| {
                return .{ .key_down = .{
                    .native = native,
                    .core = core,
                    .repeat = key.repeat,
                } };
            }
            return .{ .input = core };
        },
        .key_up => |key| {
            if (!belongsToWindow(key.window_id, window_id)) return null;
            return .{ .input = .{ .key_up = translateKey(key) } };
        },
        .text_input => |text| {
            if (!belongsToWindow(text.window_id, window_id)) return null;
            return .{ .input = .{ .text_input = .{ .text = text.text } } };
        },
        .text_editing => |preedit| {
            if (!belongsToWindow(preedit.window_id, window_id)) return null;
            const inside = preeditSelection(preedit.text, preedit.start, preedit.length);
            return .{ .input = .{ .composition = .{
                .phase = if (preedit.text.len == 0) .end else .update,
                .text = preedit.text,
                .selection_start = inside.start,
                .selection_end = inside.end,
            } } };
        },
        else => {},
    }
    return null;
}

/// A reading for a translation test whose event names no size. The production
/// caller always measures; a test that translates a close, a key or a text
/// commit needs a value only because the parameter is not optional.
fn testExtents() Window.ClientExtent {
    return .{
        .logical = .{ .width = 800, .height = 600 },
        .pixels = .{ .width = 1600, .height = 1200 },
    };
}

/// SDL reports the preedit selection in codepoints of the preedit text. The
/// core protocol works in UTF-8 byte offsets into that same text, so a
/// multibyte preedit keeps its own selection.
pub fn preeditSelection(text: []const u8, start: ?usize, length: ?usize) struct { start: usize, end: usize } {
    const first = start orelse 0;
    const count = length orelse 0;
    const begin = byteOffsetForCodepoint(text, first);
    const end = byteOffsetForCodepoint(text, first +| count);
    return .{ .start = begin, .end = @max(begin, end) };
}

/// The byte offset of a codepoint index, clamped to the text end. An index
/// inside a multibyte codepoint lands on its start, so a range can never
/// split one character.
fn byteOffsetForCodepoint(text: []const u8, count: usize) usize {
    var index: usize = 0;
    var seen: usize = 0;
    while (index < text.len and seen < count) : (seen += 1) {
        index += std.unicode.utf8ByteSequenceLength(text[index]) catch text.len - index;
    }
    return @min(index, text.len);
}

fn roundPixel(value: f32) i32 {
    const limit: f32 = @floatFromInt(std.math.maxInt(i32) - 1024);
    return @intFromFloat(@round(std.math.clamp(value, -limit, limit)));
}

/// True when every component of a candidate rectangle is a real number.
fn isFiniteArea(area: geometry.WindowRect) bool {
    return std.math.isFinite(area.x) and std.math.isFinite(area.y) and
        std.math.isFinite(area.w) and std.math.isFinite(area.h);
}

fn nativeStart(user: *anyopaque) anyerror!void {
    const self: *Window = @ptrCast(@alignCast(user));
    try self.startTextInput();
}

fn nativeStop(user: *anyopaque) anyerror!void {
    const self: *Window = @ptrCast(@alignCast(user));
    try self.stopTextInput();
}

fn nativeSetArea(user: *anyopaque, area: geometry.WindowRect, cursor: f32) anyerror!void {
    const self: *Window = @ptrCast(@alignCast(user));
    // The caret offset travels with the rectangle: SDL places the candidate
    // window at the origin plus this offset, so dropping it would anchor every
    // input method to the left edge of the line box.
    //
    // A failure is propagated instead of logged away. The rectangle the
    // platform still holds is the last one that was actually published, and
    // only the core knows whether the layout that produced this one is worth
    // another frame — a caller that swallowed the refusal would report a
    // caret it never placed.
    try self.setTextInputArea(area, cursor);
}

fn nativeClearComposition(user: *anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(user));
    // A stale IME composition is dropped by the platform on the next focus
    // change; the native hook has no error channel, so log and continue.
    self.clearComposition() catch |err| {
        std.log.debug("clear text composition failed: {t}", .{err});
    };
}

/// SDL finger coordinates are normalized, unlike every mouse event.
fn translateTouch(
    window_id: sdl3.video.WindowId,
    raw: *const sdl3.events.Event,
    size: geometry.WindowSize,
) ?Window.Event {
    switch (raw.*) {
        .finger_down, .finger_motion, .finger_up, .finger_canceled => |finger| {
            if (!belongsToWindow(finger.window_id, window_id)) return null;
            const contact: nogui.event.TouchEvent = .{
                .id = (@as(u128, finger.id.value) << 64) |
                    @as(u128, finger.finger_id.value),
                .x = finger.x * size.width,
                .y = finger.y * size.height,
                .pressure = finger.pressure,
            };
            const core: nogui.Event = switch (raw.*) {
                .finger_down => .{ .touch_start = contact },
                .finger_motion => .{ .touch_move = contact },
                .finger_up => .{ .touch_end = contact },
                .finger_canceled => .{ .touch_cancel = contact },
                else => unreachable,
            };
            return .{ .input = core };
        },
        else => return null,
    }
}

fn mouseButton(native: sdl3.mouse.Button) nogui.event.MouseButton {
    return switch (native) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        .x1 => .back,
        .x2 => .forward,
        else => @enumFromInt(@intFromEnum(native)),
    };
}

fn belongsToWindow(id: ?sdl3.video.WindowId, window_id: sdl3.video.WindowId) bool {
    return id == null or id.? == window_id;
}

fn isSyntheticTouch(id: ?sdl3.mouse.Id) bool {
    return if (id) |mouse_id| mouse_id.value == sdl3.mouse.Id.touch.value else false;
}

/// The one conversion from SDL's modifier set to the protocol's. A key event
/// carries its own set; pointer and wheel events carry none, so they read the
/// state SDL keeps for the keyboard and answer through this same conversion.
fn modifiers(mod: sdl3.keycode.KeyModifier) nogui.event.Modifiers {
    return .{
        .shift = mod.left_shift or mod.right_shift,
        .control = mod.left_control or mod.right_control,
        .alt = mod.left_alt or mod.right_alt,
        .super = mod.left_gui or mod.right_gui,
        .caps_lock = mod.caps_lock,
        .num_lock = mod.num_lock,
        .left_shift = mod.left_shift,
        .right_shift = mod.right_shift,
        .left_control = mod.left_control,
        .right_control = mod.right_control,
    };
}

fn translateKey(key: sdl3.events.Keyboard) nogui.event.KeyEvent {
    const named = if (key.key) |value| mapKey(value) else null;
    var logical: nogui.event.LogicalKey = .unidentified;
    if (named) |value| {
        logical = .{ .named = value };
    } else if (key.key) |value| {
        const raw: u32 = @intFromEnum(value);
        if (raw >= 0x20 and raw <= 0x10ffff and
            !(raw >= 0xd800 and raw <= 0xdfff))
        {
            logical = .{ .codepoint = @intCast(raw) };
        }
    }
    const held = modifiers(key.mod);
    return .{
        .key = named orelse .unidentified,
        .shift = held.shift,
        .modifiers = held,
        .physical = if (key.scancode) |scan|
            .{ .code = @intCast(@intFromEnum(scan)) }
        else
            null,
        .logical = logical,
        .repeat = key.repeat,
    };
}

fn mapKey(native: sdl3.keycode.Keycode) ?nogui.event.Key {
    return switch (native) {
        .tab => .tab,
        .return_key, .return_key2 => .enter,
        .space => .space,
        .escape => .escape,
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        else => null,
    };
}

test "api-w02 mouse motion retains fractional window points at 1x 1.25x and 2x" {
    const move: sdl3.events.Event = .{ .mouse_motion = .{
        .common = .{ .timestamp = 0 },
        .state = .{ .left = false, .middle = false, .right = false, .side1 = false, .side2 = false },
        .x = 125.25,
        .y = 50.75,
        .x_rel = 0,
        .y_rel = 0,
    } };
    const pixel_sizes = [_]Window.Extent{
        .{ .width = 500, .height = 300 },
        .{ .width = 625, .height = 375 },
        .{ .width = 1000, .height = 600 },
    };
    // An SDL motion event carries no modifier of its own, so the live keyboard
    // state is what the core is told. A consumer that reads `.modifiers` to
    // tell a click from a drag must not have to ask the keyboard twice.
    const held: sdl3.keycode.KeyModifier = .{ .right_shift = true, .caps_lock = true };
    for (pixel_sizes) |pixels| {
        const translated = translateEvent(1, &move, .{
            .logical = .{ .width = 500, .height = 300 },
            .pixels = pixels,
        }, held).?;
        switch (translated) {
            .input => |event| switch (event) {
                .mouse_move => |point| {
                    try std.testing.expectEqual(@as(f32, 125.25), point.x);
                    try std.testing.expectEqual(@as(f32, 50.75), point.y);
                    try std.testing.expect(point.modifiers.shift);
                    try std.testing.expect(point.modifiers.right_shift);
                    try std.testing.expect(!point.modifiers.left_shift);
                    try std.testing.expect(point.modifiers.caps_lock);
                },
                else => return error.UnexpectedEvent,
            },
            else => return error.UnexpectedEvent,
        }
    }
}

test "api-w02 resize isolates windows and keeps logical core and physical pixel extents" {
    const close: sdl3.events.Event = .{ .window_close_requested = .{
        .common = .{ .timestamp = 0 },
        .id = 2,
    } };
    try std.testing.expect(translateEvent(1, &close, testExtents(), .none) == null);
    var own_close = close;
    own_close.window_close_requested.id = 1;
    const close_result = translateEvent(1, &own_close, testExtents(), .none).?;
    switch (close_result) {
        .close => {},
        else => return error.UnexpectedEvent,
    }
    const foreign_resize: sdl3.events.Event = .{ .window_pixel_size_changed = .{
        .common = .{ .timestamp = 0 },
        .id = 2,
        .width = 1000,
        .height = 600,
    } };
    const sizes: Window.ClientExtent = .{
        .logical = .{ .width = 500.5, .height = 300.25 },
        .pixels = .{ .width = 1001, .height = 601 },
    };
    try std.testing.expect(translateEvent(1, &foreign_resize, sizes, .none) == null);
    const resize: sdl3.events.Event = .{ .window_resized = .{
        .common = .{ .timestamp = 0 },
        .id = 1,
        .width = 500,
        .height = 300,
    } };
    const translated = translateEvent(1, &resize, sizes, .none).?;
    switch (translated) {
        .resize => |result| {
            try std.testing.expectEqual(@as(u32, 1001), result.pixels.width);
            try std.testing.expectEqual(@as(u32, 601), result.pixels.height);
            try std.testing.expectEqual(@as(f32, 500.5), result.core.resize.width);
            try std.testing.expectEqual(@as(f32, 300.25), result.core.resize.height);
        },
        else => return error.UnexpectedEvent,
    }
    var pixel_resize = foreign_resize;
    pixel_resize.window_pixel_size_changed.id = 1;
    const pixel_translated = translateEvent(1, &pixel_resize, sizes, .none).?;
    switch (pixel_translated) {
        .resize => |result| {
            try std.testing.expectEqual(sizes.pixels.width, result.pixels.width);
            try std.testing.expectEqual(sizes.pixels.height, result.pixels.height);
            try std.testing.expectEqual(sizes.logical.width, result.core.resize.width);
            try std.testing.expectEqual(sizes.logical.height, result.core.resize.height);
        },
        else => return error.UnexpectedEvent,
    }
}

test "api-w09 native keys retain physical identity, logical value, modifiers and repeat" {
    const key: sdl3.events.Event = .{ .key_down = .{
        .common = .{ .timestamp = 0 },
        .id = null,
        .scancode = .a,
        .key = .tab,
        .mod = .{ .right_shift = true },
        .raw = 0,
        .down = true,
        .repeat = false,
    } };
    const translated = translateEvent(1, &key, testExtents(), .none).?;
    switch (translated) {
        .key_down => |result| {
            try std.testing.expectEqual(sdl3.keycode.Keycode.tab, result.native);
            try std.testing.expectEqual(nogui.event.Key.tab, result.core.key_down.key);
            try std.testing.expect(result.core.key_down.modifiers.right_shift);
            try std.testing.expectEqual(
                @as(u32, @intFromEnum(sdl3.Scancode.a)),
                result.core.key_down.physical.?.code,
            );
            try std.testing.expect(!result.repeat);
        },
        else => return error.UnexpectedEvent,
    }
    var repeat = key;
    repeat.key_down.key = .s;
    repeat.key_down.repeat = true;
    const repeated = translateEvent(1, &repeat, testExtents(), .none).?.key_down;
    try std.testing.expect(repeated.repeat);
    try std.testing.expectEqual(
        @as(u21, 's'),
        repeated.core.key_down.logical.codepoint,
    );
    var release: sdl3.events.Event = .{ .key_up = repeat.key_down };
    release.key_up.down = false;
    release.key_up.repeat = false;
    const routed_up = translateEvent(1, &release, testExtents(), .none).?.input;
    try std.testing.expectEqual(
        @as(u21, 's'),
        routed_up.key_up.logical.codepoint,
    );
    try std.testing.expect(!routed_up.key_up.repeat);
}

test "api-w02 wheel keeps fractional window position and unscaled deltas on nonuniform axes" {
    const wheel: sdl3.events.Event = .{ .mouse_wheel = .{
        .common = .{ .timestamp = 0 },
        .scroll_x = 1.5,
        .scroll_y = -2,
        .direction = .normal,
        .x = 40.125,
        .y = 25.375,
    } };
    const translated = translateEvent(1, &wheel, .{
        .logical = .{ .width = 200, .height = 100 },
        .pixels = .{ .width = 250, .height = 200 },
    }, .{ .left_control = true }).?;
    switch (translated) {
        .input => |event| switch (event) {
            .mouse_wheel => |result| {
                try std.testing.expectEqual(@as(f32, 40.125), result.x);
                try std.testing.expectEqual(@as(f32, 25.375), result.y);
                try std.testing.expectEqual(@as(f32, 1.5), result.delta_x);
                try std.testing.expectEqual(@as(f32, -2), result.delta_y);
                // A wheel event carries no modifier of its own, so the live
                // keyboard state answers, and a zoom gesture is the consumer
                // that depends on it.
                try std.testing.expect(result.modifiers.control);
                try std.testing.expect(result.modifiers.left_control);
                try std.testing.expect(!result.modifiers.shift);
                // SDL reports no scroll phase and this host invents none.
                try std.testing.expectEqual(nogui.event.ScrollPhase.update, result.phase);
                try std.testing.expectEqual(nogui.event.ScrollUnit.line, result.unit);
            },
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedEvent,
    }
}

test "api-w02 button press and release keep logical points and hover isolates windows" {
    const down: sdl3.events.Event = .{ .mouse_button_down = .{
        .common = .{ .timestamp = 0 },
        .button = .right,
        .down = true,
        .clicks = 1,
        .x = 20.125,
        .y = 30.75,
    } };
    const sizes: Window.ClientExtent = .{
        .logical = .{ .width = 100, .height = 100 },
        .pixels = .{ .width = 125, .height = 200 },
    };
    // A press carries no modifier of its own; the live keyboard state answers,
    // so a consumer can read shift or alt off the routed pointer event.
    const held: sdl3.keycode.KeyModifier = .{ .left_alt = true, .left_shift = true };
    const translated = translateEvent(1, &down, sizes, held).?;
    switch (translated) {
        .input => |event| switch (event) {
            .mouse_down => |press| {
                try std.testing.expectEqual(nogui.event.MouseButton.right, press.button);
                try std.testing.expectEqual(@as(f32, 20.125), press.x);
                try std.testing.expectEqual(@as(f32, 30.75), press.y);
                try std.testing.expect(press.modifiers.alt);
                try std.testing.expect(press.modifiers.shift);
                try std.testing.expect(!press.modifiers.control);
            },
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedEvent,
    }
    var up: sdl3.events.Event = .{ .mouse_button_up = down.mouse_button_down };
    up.mouse_button_up.button = .left;
    up.mouse_button_up.down = false;
    up.mouse_button_up.x = 21.5;
    up.mouse_button_up.y = 31.25;
    const released = translateEvent(1, &up, sizes, held).?;
    switch (released) {
        .input => |event| switch (event) {
            .mouse_up => |release| {
                try std.testing.expectEqual(nogui.event.MouseButton.left, release.button);
                try std.testing.expectEqual(@as(f32, 21.5), release.x);
                try std.testing.expectEqual(@as(f32, 31.25), release.y);
                try std.testing.expect(release.modifiers.alt);
            },
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedEvent,
    }
    const foreign_leave: sdl3.events.Event = .{ .window_mouse_leave = .{
        .common = .{ .timestamp = 0 },
        .id = 2,
    } };
    try std.testing.expect(translateEvent(1, &foreign_leave, testExtents(), .none) == null);
    const own_leave: sdl3.events.Event = .{ .window_mouse_leave = .{
        .common = .{ .timestamp = 0 },
        .id = 1,
    } };
    const hover = translateEvent(1, &own_leave, testExtents(), .none).?;
    switch (hover) {
        .input => |event| switch (event) {
            .mouse_leave => {},
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedEvent,
    }
}

test "api-w09 native touch IDs and coordinates survive cancel without mouse duplication" {
    const logical: geometry.WindowSize = .{ .width = 240, .height = 120 };
    const finger: sdl3.events.TouchFinger = .{
        .common = .{ .timestamp = 0 },
        .window_id = 1,
        .id = .{ .value = 7 },
        .finger_id = .{ .value = 42 },
        .x = 0.25,
        .y = 0.75,
        .dx = 0,
        .dy = 0,
        .pressure = 0.6,
    };
    const down: sdl3.events.Event = .{ .finger_down = finger };
    const translated = translateTouch(1, &down, logical).?.input.touch_start;
    try std.testing.expectEqual((@as(u128, 7) << 64) | 42, translated.id);
    try std.testing.expectEqual(@as(f32, 60), translated.x);
    try std.testing.expectEqual(@as(f32, 90), translated.y);
    try std.testing.expectEqual(@as(f32, 0.6), translated.pressure);
    try std.testing.expect(translateTouch(2, &down, logical) == null);
    const cancel: sdl3.events.Event = .{ .finger_canceled = finger };
    try std.testing.expectEqual(
        translated.id,
        translateTouch(1, &cancel, logical).?.input.touch_cancel.id,
    );
    const simulated: sdl3.events.Event = .{ .mouse_button_down = .{
        .common = .{ .timestamp = 0 },
        .id = sdl3.mouse.Id.touch,
        .button = .left,
        .down = true,
        .clicks = 1,
        .x = 60,
        .y = 90,
    } };
    try std.testing.expect(translateEvent(1, &simulated, testExtents(), .none) == null);
}

test "api-w09 native text commit preedit and focus loss retain event distinctions" {
    const committed: sdl3.events.Event = .{ .text_input = .{
        .common = .{ .timestamp = 0 },
        .window_id = 1,
        .text = "é",
    } };
    try std.testing.expectEqualStrings(
        "é",
        translateEvent(1, &committed, testExtents(), .none).?.input.text_input.text,
    );
    try std.testing.expect(translateEvent(2, &committed, testExtents(), .none) == null);
    const editing: sdl3.events.Event = .{ .text_editing = .{
        .common = .{ .timestamp = 0 },
        .window_id = 1,
        .text = "abc",
        .start = 1,
        .length = 2,
    } };
    const composition = translateEvent(1, &editing, testExtents(), .none).?.input.composition;
    try std.testing.expectEqual(nogui.event.CompositionPhase.update, composition.phase);
    try std.testing.expectEqual(@as(usize, 1), composition.selection_start);
    try std.testing.expectEqual(@as(usize, 3), composition.selection_end);
    const lost: sdl3.events.Event = .{ .window_focus_lost = .{
        .common = .{ .timestamp = 0 },
        .id = 1,
    } };
    try std.testing.expect(translateEvent(2, &lost, testExtents(), .none) == null);
    switch (translateEvent(1, &lost, testExtents(), .none).?.input) {
        .window_focus_lost => {},
        else => return error.UnexpectedEvent,
    }
}

test "api-w12 preedit selection converts codepoints to byte offsets" {
    // SDL counts codepoints of the preedit; the protocol counts its bytes.
    const ascii = preeditSelection("abc", 1, 2);
    try std.testing.expectEqual(@as(usize, 1), ascii.start);
    try std.testing.expectEqual(@as(usize, 3), ascii.end);
    const wide = preeditSelection("\xe3\x81\x82\xe3\x81\x84", 1, 1);
    try std.testing.expectEqual(@as(usize, 3), wide.start);
    try std.testing.expectEqual(@as(usize, 6), wide.end);
    // A missing value, and an overlong range, stay inside the preedit instead
    // of pointing into the document. SDL reports these as absent or as an
    // unsigned index, so there is no negative case to handle.
    const unset = preeditSelection("\xe3\x81\x82", null, null);
    try std.testing.expectEqual(@as(usize, 0), unset.start);
    try std.testing.expectEqual(@as(usize, 0), unset.end);
    const clamped = preeditSelection("ab", 5, 5);
    try std.testing.expectEqual(@as(usize, 2), clamped.start);
    try std.testing.expectEqual(@as(usize, 2), clamped.end);
    const overlong = preeditSelection("\xe3\x81\x82\xe3\x81\x84", 1, std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 3), overlong.start);
    try std.testing.expectEqual(@as(usize, 6), overlong.end);
    const past_end = preeditSelection("ab", std.math.maxInt(usize), 1);
    try std.testing.expectEqual(@as(usize, 2), past_end.start);
    try std.testing.expectEqual(@as(usize, 2), past_end.end);
}

test "api-w12 a native preedit event keeps its byte offsets through translation" {
    const editing: sdl3.events.Event = .{ .text_editing = .{
        .common = .{ .timestamp = 0 },
        .window_id = 1,
        .text = "\xe3\x81\x82\xe3\x81\x84",
        .start = 1,
        .length = 1,
    } };
    const composition = translateEvent(1, &editing, testExtents(), .none).?.input.composition;
    try std.testing.expectEqual(nogui.event.CompositionPhase.update, composition.phase);
    try std.testing.expectEqual(@as(usize, 3), composition.selection_start);
    try std.testing.expectEqual(@as(usize, 6), composition.selection_end);
    // An empty preedit ends the composition and keeps the commit that follows.
    const ended: sdl3.events.Event = .{ .text_editing = .{
        .common = .{ .timestamp = 0 },
        .window_id = 1,
        .text = "",
        .start = null,
        .length = null,
    } };
    const closed = translateEvent(1, &ended, testExtents(), .none).?.input.composition;
    try std.testing.expectEqual(nogui.event.CompositionPhase.end, closed.phase);
    try std.testing.expectEqual(@as(usize, 0), closed.selection_start);
}

test "api-w12 the candidate area is whole pixels and rejects a broken rectangle" {
    const line = Window.candidateArea(.{ .x = 20.4, .y = 30.6, .w = 0, .h = 16.2 });
    try std.testing.expectEqual(@as(i32, 20), line.x);
    try std.testing.expectEqual(@as(i32, 31), line.y);
    // A zero-width caret box still anchors the candidate window.
    try std.testing.expectEqual(@as(i32, 1), line.w);
    try std.testing.expectEqual(@as(i32, 16), line.h);
    const wrapped = Window.candidateArea(.{ .x = 8, .y = 46, .w = 120, .h = 16 });
    try std.testing.expectEqual(@as(i32, 120), wrapped.w);
    // A non-finite rectangle from a broken layout publishes nothing usable.
    const broken = Window.candidateArea(.{ .x = std.math.nan(f32), .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(i32, 0), broken.x);
    try std.testing.expectEqual(@as(i32, 0), broken.w);
    try std.testing.expectEqual(@as(i32, 0), broken.h);
}

test "api-w12 the caret offset inside the candidate area survives as whole pixels" {
    // SDL places the candidate window at the rectangle origin plus this
    // offset, so the offset an endpoint publishes is the difference between
    // an input method at the caret and one at the line's left edge.
    try std.testing.expectEqual(@as(i32, 0), Window.candidateCursor(0));
    try std.testing.expectEqual(@as(i32, 96), Window.candidateCursor(96));
    try std.testing.expectEqual(@as(i32, 12), Window.candidateCursor(11.6));
    try std.testing.expectEqual(@as(i32, -3), Window.candidateCursor(-3.2));
    // A broken offset has no pixel; it anchors at the origin instead of
    // reaching SDL as a NaN.
    try std.testing.expectEqual(@as(i32, 0), Window.candidateCursor(std.math.nan(f32)));
    try std.testing.expectEqual(@as(i32, 0), Window.candidateCursor(std.math.inf(f32)));
}

test "api-w12 invalid candidate publication preserves the last native area" {
    try sdl_session.acquireForTest("dummy");
    var window = try Window.init(.{ .title = "candidate", .width = 160, .height = 120 });
    defer window.deinit();
    try window.startTextInput();
    try window.setTextInputArea(.{ .x = 20, .y = 30, .w = 80, .h = 18 }, 24);
    const before = try sdl3.keyboard.getTextInputArea(window.sdl);

    try std.testing.expectError(error.InvalidCandidateArea, window.setTextInputArea(
        .{ .x = std.math.nan(f32), .y = 30, .w = 80, .h = 18 },
        24,
    ));
    try std.testing.expectEqualDeep(before, try sdl3.keyboard.getTextInputArea(window.sdl));
    try std.testing.expectError(error.InvalidCandidateCursor, window.setTextInputArea(
        .{ .x = 20, .y = 30, .w = 80, .h = 18 },
        std.math.inf(f32),
    ));
    try std.testing.expectEqualDeep(before, try sdl3.keyboard.getTextInputArea(window.sdl));
}

test "api-w12 a candidate publication is counted only once the platform took it" {
    try sdl_session.acquireForTest("dummy");
    var window = try Window.init(.{ .title = "candidate", .width = 160, .height = 120 });
    defer window.deinit();
    try window.startTextInput();

    // A window that published nothing reads as generation zero, and zero is
    // also what a fresh observer already holds — so "never published" is an
    // answer, not a rectangle at the origin.
    try std.testing.expectEqual(@as(u64, 0), window.candidate_publication.generation);

    const area: geometry.WindowRect = .{ .x = 20, .y = 30, .w = 80, .h = 18 };
    try window.setTextInputArea(area, 24);
    try std.testing.expectEqual(@as(u64, 1), window.candidate_publication.generation);
    try std.testing.expectEqual(area, window.candidate_publication.area);
    try std.testing.expectEqual(@as(f32, 24), window.candidate_publication.cursor);

    // The SAME rectangle again is still a new publication. A layout ran and
    // put the field back on the same pixels, and only a counter says so; a
    // rectangle comparison cannot, which would strand an observer on stale
    // geometry that is in fact current.
    try window.setTextInputArea(area, 24);
    try std.testing.expectEqual(@as(u64, 2), window.candidate_publication.generation);

    // A refused handover is not a publication, so neither the counter nor the
    // bytes the platform holds move. A record that counted the attempt would
    // let an observer adopt a rectangle SDL never received.
    const held = try sdl3.keyboard.getTextInputArea(window.sdl);
    try std.testing.expectError(error.InvalidCandidateArea, window.setTextInputArea(
        .{ .x = std.math.inf(f32), .y = 30, .w = 80, .h = 18 },
        24,
    ));
    try std.testing.expectError(error.InvalidCandidateCursor, window.setTextInputArea(
        area,
        std.math.nan(f32),
    ));
    try std.testing.expectEqual(@as(u64, 2), window.candidate_publication.generation);
    try std.testing.expectEqualDeep(held, try sdl3.keyboard.getTextInputArea(window.sdl));
}
