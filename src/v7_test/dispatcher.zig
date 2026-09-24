//! One input path for direct events and JSON-lines replay.
const std = @import("std");
const nogui = @import("nogui");
const App = nogui.App;
const Event = nogui.Event;
const headless = nogui.headless;
const VirtualClock = @import("clock.zig").VirtualClock;

/// JSON event strings belong to ParsedEvent and remain alive until App.handle
/// finishes. The caller frees FrameOutput.json with App's allocator, if set.
pub fn dispatch(app: *App, clock: ?*VirtualClock, input: Event) !?headless.FrameOutput {
    if (clock) |virtual| switch (input) {
        .frame => |frame| try virtual.advanceToMs(frame.time_ms),
        else => {},
    };
    return app.handle(input);
}

pub fn dispatchJson(
    app: *App,
    clock: ?*VirtualClock,
    allocator: std.mem.Allocator,
    line: []const u8,
) !?headless.FrameOutput {
    var parsed = try headless.parseEvent(allocator, line);
    defer parsed.deinit();
    return dispatch(app, clock, parsed.event);
}
