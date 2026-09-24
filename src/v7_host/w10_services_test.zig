const std = @import("std");
const sdl3 = @import("sdl3");
const Keyboard = @import("keyboard.zig").Keyboard;
const Cursor = @import("cursor.zig").Cursor;

const sdl_session = @import("sdl_session.zig");

/// One SDL driver for the whole test binary, held until the process exits.
/// A per-test init and quit would repeat the device probe for every test and
/// can hang in teardown while an event thread is still running.
fn startDummy() !void {
    try sdl_session.acquireForTest("dummy");
}

const LayoutObserver = struct {
    calls: usize = 0,
    generation: u64 = 0,
    fn changed(raw: *anyopaque, change: Keyboard.LayoutChange) void {
        const self: *LayoutObserver = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.generation = change.generation;
        std.debug.assert(change.layout.status == .unsupported_by_sdl);
    }
};

test "api-w10 SDL reports layout change but not native layout name or identifier" {
    try startDummy();
    // SDL stays up for the rest of the binary; see startDummy.
    var service = Keyboard.init();
    var observer: LayoutObserver = .{};
    service.setOnLayoutChanged(.{ .context = &observer, .callback = LayoutObserver.changed });
    const layout = service.layout();
    try std.testing.expectEqual(Keyboard.LayoutStatus.unsupported_by_sdl, layout.status);
    try std.testing.expect(layout.name == null);
    try std.testing.expect(layout.identifier == null);

    const unrelated: sdl3.events.Event = .{ .window_mouse_enter = .{
        .common = .{ .timestamp = 0 },
        .id = 1,
    } };
    try std.testing.expect(!service.handleEvent(&unrelated));
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    const change: sdl3.events.Event = .{ .keymap_changed = .{ .timestamp = 1 } };
    try std.testing.expect(service.handleEvent(&change));
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    try std.testing.expectEqual(service.layout().generation, observer.generation);
    try std.testing.expect(service.handleEvent(&change));
    try std.testing.expectEqual(@as(usize, 2), observer.calls);
    try std.testing.expectEqual(@as(u64, 2), observer.generation);
}

test "api-w10 physical shortcut label reads active SDL layout without a US key table" {
    try startDummy();
    // SDL stays up for the rest of the binary; see startDummy.
    const service = Keyboard.init();
    const code = sdl3.Scancode.a;
    const logical = sdl3.keyboard.getKeyFromScancode(code, .none, false) orelse
        return error.MissingKeymap;
    const expected = sdl3.keyboard.getKeyName(logical) orelse return error.MissingKeyName;
    const owned_expected = try std.testing.allocator.dupe(u8, expected);
    defer std.testing.allocator.free(owned_expected);
    const label = service.shortcutLabel(@intFromEnum(code), .none) orelse
        return error.MissingShortcutLabel;
    try std.testing.expectEqualStrings(owned_expected, label);
    const shifted: sdl3.keycode.KeyModifier = .{ .left_shift = true };
    const shifted_key = sdl3.keyboard.getKeyFromScancode(.one, shifted, false) orelse
        return error.MissingShiftedKey;
    const shifted_name = sdl3.keyboard.getKeyName(shifted_key) orelse
        return error.MissingShiftedName;
    const shifted_copy = try std.testing.allocator.dupe(u8, shifted_name);
    defer std.testing.allocator.free(shifted_copy);
    try std.testing.expectEqualStrings(
        shifted_copy,
        service.shortcutLabel(@intFromEnum(sdl3.Scancode.one), shifted) orelse
            return error.MissingShiftedLabel,
    );
    try std.testing.expect(service.shortcutLabel(std.math.maxInt(u32), .none) == null);
    // SDL's dummy driver has no API for changing the native keyboard layout.
    // Alternate-layout validation requires a live OS layout switch (parent gate).
}

test "api-w10 per-window cursor visibility and hide-until-move isolate SDL pointer focus" {
    try startDummy();
    // SDL stays up for the rest of the binary; see startDummy.
    const first_window = try sdl3.video.Window.init("cursor-a", 100, 80, .{ .hidden = true });
    defer first_window.deinit();
    const second_window = try sdl3.video.Window.init("cursor-b", 100, 80, .{ .hidden = true });
    defer second_window.deinit();
    var first = try Cursor.init(first_window);
    defer first.deinit();
    var second = try Cursor.init(second_window);
    defer second.deinit();
    const first_id = try first_window.getId();
    const second_id = try second_window.getId();
    const enter_first: sdl3.events.Event = .{ .window_mouse_enter = .{
        .common = .{ .timestamp = 0 },
        .id = first_id,
    } };
    const enter_second: sdl3.events.Event = .{ .window_mouse_enter = .{
        .common = .{ .timestamp = 0 },
        .id = second_id,
    } };
    try first.handleEvent(&enter_first);
    try first.setVisible(false);
    try std.testing.expect(!sdl3.mouse.visible());
    try second.setVisible(true); // Inactive window must not expose first's cursor.
    try std.testing.expect(!sdl3.mouse.visible());
    try first.hideUntilPointerMove();
    const foreign_motion: sdl3.events.Event = .{ .mouse_motion = .{
        .common = .{ .timestamp = 0 },
        .window_id = second_id,
        .state = .{ .left = false, .middle = false, .right = false, .side1 = false, .side2 = false },
        .x = 10,
        .y = 20,
        .x_rel = 1,
        .y_rel = 1,
    } };
    try first.handleEvent(&foreign_motion);
    try std.testing.expect(!sdl3.mouse.visible());
    const own_motion: sdl3.events.Event = .{ .mouse_motion = .{
        .common = .{ .timestamp = 0 },
        .window_id = first_id,
        .state = .{ .left = false, .middle = false, .right = false, .side1 = false, .side2 = false },
        .x = 11,
        .y = 20,
        .x_rel = 1,
        .y_rel = 0,
    } };
    try first.handleEvent(&own_motion);
    try std.testing.expect(!sdl3.mouse.visible()); // Explicit hidden policy still wins.
    try first.setVisible(true);
    try first.hideUntilPointerMove();
    try std.testing.expect(!sdl3.mouse.visible());
    var synthetic_touch = own_motion;
    synthetic_touch.mouse_motion.id = sdl3.mouse.Id.touch;
    try first.handleEvent(&synthetic_touch);
    try std.testing.expect(!sdl3.mouse.visible());
    try first.handleEvent(&own_motion);
    try std.testing.expect(sdl3.mouse.visible());
    try first.hideUntilPointerMove();
    var unaddressed_motion = own_motion;
    unaddressed_motion.mouse_motion.window_id = null;
    try first.handleEvent(&unaddressed_motion);
    try std.testing.expect(sdl3.mouse.visible());
    try first.hideUntilPointerMove();
    try std.testing.expect(!sdl3.mouse.visible());
    try second.handleEvent(&enter_second);
    try std.testing.expect(sdl3.mouse.visible());
    const stale_leave: sdl3.events.Event = .{ .window_mouse_leave = .{
        .common = .{ .timestamp = 0 },
        .id = first_id,
    } };
    try first.handleEvent(&stale_leave);
    try std.testing.expect(sdl3.mouse.visible());
}

test "api-w10 dummy SDL rejects unsupported native cursor shapes without changing selection" {
    try startDummy();
    // SDL stays up for the rest of the binary; see startDummy.
    const window = try sdl3.video.Window.init("cursor-shape", 100, 80, .{ .hidden = true });
    defer window.deinit();
    var cursor = try Cursor.init(window);
    defer cursor.deinit();
    try std.testing.expectEqual(sdl3.mouse.SystemCursor.default, cursor.shape);
    // Dummy video cannot construct system cursors. Live SDL driver must exercise
    // selection visually; there is no fabricated arrow/hand substitute here.
    try std.testing.expectError(error.SdlError, cursor.select(.pointer));
    try std.testing.expectEqual(sdl3.mouse.SystemCursor.default, cursor.shape);
}
