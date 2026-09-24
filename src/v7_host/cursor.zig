//! Per-window cursor policy over SDL's process-wide cursor and visibility.
const std = @import("std");
const sdl3 = @import("sdl3");

// SDL's active cursor is global. Only the window receiving pointer events may
// apply its state. The SDL event thread owns this state and every Cursor.
var active_window: ?sdl3.video.WindowId = null;

pub const Cursor = struct {
    window: sdl3.video.Window,
    id: sdl3.video.WindowId,
    shape: sdl3.mouse.SystemCursor = .default,
    owned: ?sdl3.mouse.Cursor = null,
    visible: bool = true,
    hidden_until_move: bool = false,

    /// Borrow window until deinit; call deinit before destroying it or SDL video.
    /// A Cursor must not be copied after selecting a non-default shape.
    pub fn init(window: sdl3.video.Window) !Cursor {
        return .{ .window = window, .id = try window.getId() };
    }

    /// Release the SDL cursor we created and restore visible default state if
    /// this window owns pointer focus. Must run on the SDL event thread.
    pub fn deinit(self: *Cursor) void {
        if (active_window == self.id) {
            // SDL_DestroyCursor itself resets an active owned cursor to default.
            if (self.owned) |cursor| {
                cursor.deinit();
                self.owned = null;
            }
            if (sdl3.mouse.getDefault()) |default| {
                sdl3.mouse.set(default) catch |err| {
                    std.log.warn("cannot restore default SDL cursor: {s}", .{@errorName(err)});
                };
            } else |err| {
                std.log.warn("no default SDL cursor to restore: {s}", .{@errorName(err)});
            }
            sdl3.mouse.show() catch |err| {
                std.log.warn("cannot restore SDL cursor visibility: {s}", .{@errorName(err)});
            };
            active_window = null;
        }
        if (self.owned) |cursor| cursor.deinit();
        self.* = undefined;
    }

    /// Creates a real native system cursor. If the SDL driver cannot create
    /// it (notably the dummy video driver), propagate SDL's error unchanged.
    /// Failed selection leaves the old shape and owned cursor intact.
    pub fn select(self: *Cursor, shape: sdl3.mouse.SystemCursor) !void {
        if (self.shape == shape) return;
        const next: ?sdl3.mouse.Cursor = if (shape == .default)
            null
        else
            try sdl3.mouse.Cursor.initSystem(shape);
        errdefer if (next) |cursor| cursor.deinit();
        if (active_window == self.id) try setNative(next);
        if (self.owned) |cursor| cursor.deinit();
        self.owned = next;
        self.shape = shape;
    }

    /// Visibility is stored per window; SDL's global state is changed only
    /// while this window owns pointer focus. Explicit hiding takes precedence
    /// over hide-until-move when the pointer next moves.
    pub fn setVisible(self: *Cursor, visible: bool) !void {
        if (active_window == self.id) {
            if (visible and !self.hidden_until_move) {
                try sdl3.mouse.show();
            } else {
                try sdl3.mouse.hide();
            }
        }
        self.visible = visible;
    }

    /// Hide now, then restore this window's explicit visibility on its next
    /// physical mouse motion. A synthetic touch-to-mouse event is not motion.
    pub fn hideUntilPointerMove(self: *Cursor) !void {
        if (active_window == self.id) try sdl3.mouse.hide();
        self.hidden_until_move = true;
    }

    /// Feed SDL mouse enter/leave/motion in dispatch order. Each window's
    /// controller may see every event: foreign-window events are ignored.
    /// SDL's cursor is global, so a stale leave never resets a newer owner.
    pub fn handleEvent(self: *Cursor, raw: *const sdl3.events.Event) !void {
        switch (raw.*) {
            .window_mouse_enter => |event| {
                if (event.id != self.id) return;
                active_window = self.id;
                try self.apply();
            },
            .window_mouse_leave => |event| {
                if (event.id != self.id or active_window != self.id) return;
                try setNative(null);
                try sdl3.mouse.show();
                active_window = null;
            },
            .mouse_motion => |event| {
                if ((event.window_id != null and event.window_id.? != self.id) or
                    (event.window_id == null and active_window != self.id) or
                    (event.id != null and event.id.?.value == sdl3.mouse.Id.touch.value)) return;
                // Mouse focus can be established before the queued enter event.
                if (active_window != self.id) {
                    const focused = sdl3.mouse.getFocus() orelse return;
                    if (focused.value != self.window.value) return;
                    active_window = self.id;
                    try self.apply();
                }
                if (self.hidden_until_move) {
                    if (self.visible) {
                        try sdl3.mouse.show();
                    } else {
                        try sdl3.mouse.hide();
                    }
                    self.hidden_until_move = false;
                }
            },
            else => {},
        }
    }

    fn apply(self: *const Cursor) !void {
        try setNative(self.owned);
        if (self.visible and !self.hidden_until_move) {
            try sdl3.mouse.show();
        } else {
            try sdl3.mouse.hide();
        }
    }

    fn setNative(cursor: ?sdl3.mouse.Cursor) !void {
        if (cursor) |owned| {
            try sdl3.mouse.set(owned);
        } else {
            try sdl3.mouse.set(try sdl3.mouse.getDefault());
        }
    }
};
