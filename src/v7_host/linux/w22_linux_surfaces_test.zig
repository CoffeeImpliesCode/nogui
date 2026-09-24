//! Pure unit tests for Linux popup, layer-shell, and window decoration adapters.
//! Tests adhere to W22 parity criteria without running mid-flight build/test suites.
const std = @import("std");
const testing = std.testing;

const popup = @import("popup.zig");
const layer_shell = @import("layer_shell.zig");
const decorations = @import("decorations.zig");

// ============================================================================
// W22 Popup Tests
// ============================================================================

test "api-w22 popup default positioning placed below anchor rect" {
    const parent_bounds: popup.Rect = .{ .x = 100, .y = 100, .width = 800, .height = 600 };
    const work_area: popup.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    const positioner: popup.Positioner = .{
        .anchor_rect = .{ .x = 50, .y = 50, .width = 100, .height = 30 },
        .anchor = .bottom,
        .gravity = .bottom,
        .constraint_adjustment = popup.ConstraintAdjustment.all,
        .offset = .{ .x = 0, .y = 0 },
        .size = .{ .width = 120, .height = 200 },
    };

    const placement = popup.resolvePlacement(positioner, parent_bounds, work_area);

    // Anchor bottom center is at (100, 80).
    // Gravity bottom places popup top edge at 80, centered horizontally at 100 (x = 100 - 60 = 40).
    try testing.expectEqual(@as(i32, 40), placement.rect.x);
    try testing.expectEqual(@as(i32, 80), placement.rect.y);
    try testing.expectEqual(@as(u32, 120), placement.rect.width);
    try testing.expectEqual(@as(u32, 200), placement.rect.height);
    try testing.expect(!placement.flipped_x);
    try testing.expect(!placement.flipped_y);
    try testing.expect(!placement.slid_x);
    try testing.expect(!placement.slid_y);
}

test "api-w22 popup flip_y when overflowing work area bottom" {
    // Parent is near bottom edge of monitor
    const parent_bounds: popup.Rect = .{ .x = 100, .y = 900, .width = 800, .height = 600 };
    const work_area: popup.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    const positioner: popup.Positioner = .{
        .anchor_rect = .{ .x = 50, .y = 50, .width = 100, .height = 30 },
        .anchor = .bottom,
        .gravity = .bottom,
        .constraint_adjustment = popup.ConstraintAdjustment.all,
        .offset = .{ .x = 0, .y = 0 },
        .size = .{ .width = 120, .height = 200 }, // 900 + 80 + 200 = 1180 > 1080
    };

    const placement = popup.resolvePlacement(positioner, parent_bounds, work_area);

    // Should flip vertically to above anchor rect
    try testing.expect(placement.flipped_y);
    // Anchor top is at 50; popup height 200 placed above top gives y = 50 - 200 = -150.
    // 900 - 150 = 750 global, which fits in 0..1080.
    try testing.expectEqual(@as(i32, -150), placement.rect.y);
}

test "api-w22 popup slide_x when overflowing work area right without flip" {
    // Parent is near right edge of monitor
    const parent_bounds: popup.Rect = .{ .x = 1800, .y = 200, .width = 400, .height = 400 };
    const work_area: popup.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    const positioner: popup.Positioner = .{
        .anchor_rect = .{ .x = 50, .y = 50, .width = 100, .height = 30 },
        .anchor = .bottom,
        .gravity = .bottom,
        .constraint_adjustment = .{ .slide_x = true, .slide_y = true }, // No flip allowed
        .offset = .{ .x = 0, .y = 0 },
        .size = .{ .width = 200, .height = 100 },
    };

    const placement = popup.resolvePlacement(positioner, parent_bounds, work_area);

    try testing.expect(!placement.flipped_x);
    try testing.expect(placement.slid_x);
    const right_extent = parent_bounds.x + placement.rect.x +
        @as(i32, @intCast(placement.rect.width));
    try testing.expect(right_extent <= work_area.right());
}

test "api-w22 popup resize_x when constrained to fit work area" {
    // Parent at origin, work area is narrow (400px).
    const parent_bounds: popup.Rect = .{
        .x = 0,
        .y = 0,
        .width = 800,
        .height = 600,
    };
    const work_area: popup.Rect = .{
        .x = 0,
        .y = 0,
        .width = 400,
        .height = 400,
    };

    const positioner: popup.Positioner = .{
        .anchor_rect = .{
            .x = 50,
            .y = 50,
            .width = 50,
            .height = 30,
        },
        .anchor = .bottom_right,
        .gravity = .bottom_right,
        .constraint_adjustment = .{
            .resize_x = true,
            .resize_y = true,
        },
        .offset = .{ .x = 0, .y = 0 },
        .size = .{ .width = 500, .height = 500 },
    };

    const placement = popup.resolvePlacement(
        positioner,
        parent_bounds,
        work_area,
    );
    // Popup starts at global x = 100 and overflows the work area on both axes.
    try testing.expect(placement.resized_x);
    try testing.expect(placement.rect.width <= work_area.width);
    try testing.expect(placement.resized_y);
    try testing.expect(placement.rect.height <= work_area.height);
}

test "api-w22 popup distinguishes in-app overlay from native OS surface" {
    const parent_bounds: popup.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const work_area: popup.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const positioner: popup.Positioner = .{
        .anchor_rect = .{ .x = 10, .y = 10, .width = 40, .height = 20 },
        .size = .{ .width = 80, .height = 80 },
    };

    const overlay = try popup.NativePopup.init(
        .in_app_overlay,
        .compositor_configure,
        positioner,
        parent_bounds,
        work_area,
    );
    try testing.expectEqual(popup.PopupKind.in_app_overlay, overlay.kind);

    const os_surface = try popup.NativePopup.init(
        .os_surface,
        .compositor_configure,
        positioner,
        parent_bounds,
        work_area,
    );
    try testing.expectEqual(popup.PopupKind.os_surface, os_surface.kind);
}

test "api-w22 popup grab needs approval, a real serial, and an unmapped popup" {
    const parent_bounds: popup.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const work_area: popup.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const positioner: popup.Positioner = .{
        .anchor_rect = .{ .x = 10, .y = 10, .width = 40, .height = 20 },
        .size = .{ .width = 80, .height = 80 },
    };

    var pop = try popup.NativePopup.init(.os_surface, .compositor_configure, positioner, parent_bounds, work_area);

    // An unapproved grab never becomes a pending one, so nothing can later
    // report it as a protocol fact.
    try testing.expectError(
        error.RiskConfirmationRequired,
        pop.requestGrab(1234, .{ .confirmed = false }),
    );
    try testing.expectEqual(@as(?u32, null), pop.pending_grab_serial);
    try testing.expect(!pop.has_grab);

    // `xdg_popup.grab` carries the serial of a real user event, so a missing
    // or zero serial is refused instead of being sent as zero.
    try testing.expectError(error.MissingSeatSerial, pop.requestGrab(null, .{ .confirmed = true }));
    try testing.expectError(error.MissingSeatSerial, pop.requestGrab(0, .{ .confirmed = true }));
    try testing.expect(!pop.has_grab);

    // Requested is not issued: the grab is a protocol fact only once the
    // adapter reports that the request reached the compositor.
    try pop.requestGrab(1234, .{ .confirmed = true });
    try testing.expectEqual(@as(?u32, 1234), pop.pending_grab_serial);
    try testing.expect(!pop.has_grab);
    try pop.onGrabIssued();
    try testing.expect(pop.has_grab);
    try testing.expectEqual(@as(?u32, 1234), pop.seat_serial);
    try testing.expectEqual(@as(?u32, null), pop.pending_grab_serial);

    // A second grab is not a second request on the same popup.
    try testing.expectError(error.AlreadyActive, pop.requestGrab(1235, .{ .confirmed = true }));

    // After the compositor answers a configure and a buffer is committed the
    // popup is mapped, and a grab is `xdg_popup.invalid_grab` from then on.
    try pop.handleConfigure(7, 10, 10, 80, 80);
    const size = try pop.ackConfigure(7);
    try pop.commit(size);
    try testing.expectEqual(popup.PopupState.mapped, pop.state);
    try testing.expectError(
        error.GrabAfterCommit,
        pop.requestGrab(1236, .{ .confirmed = true }),
    );
}

test "api-w22 popup configure acknowledgement is once per delivered configure" {
    const bounds: popup.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const positioner: popup.Positioner = .{
        .anchor_rect = .{ .x = 10, .y = 10, .width = 40, .height = 20 },
        .size = .{ .width = 80, .height = 80 },
    };
    var pop = try popup.NativePopup.init(.os_surface, .compositor_configure, positioner, bounds, bounds);
    try pop.handleConfigure(7, 10, 10, 80, 80);
    const first = try pop.ackConfigure(7);
    try testing.expectError(error.InvalidConfigureSerial, pop.ackConfigure(7));
    try pop.commit(first);

    // A delivered configure is a new generation even if the serial wraps.
    try pop.handleConfigure(7, 20, 30, 100, 72);
    const next = try pop.ackConfigure(7);
    try testing.expectEqual(popup.Size{ .width = 100, .height = 72 }, next);
    try pop.commit(next);
    try testing.expectEqual(next, pop.mapped_size);
    try testing.expectError(error.InvalidConfigureSerial, pop.ackConfigure(7));
}

test "api-w22 a denied grab dismisses the popup and releases the seat serial" {
    const parent_bounds: popup.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const work_area: popup.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const positioner: popup.Positioner = .{
        .anchor_rect = .{ .x = 10, .y = 10, .width = 40, .height = 20 },
        .size = .{ .width = 80, .height = 80 },
    };
    var pop = try popup.NativePopup.init(.os_surface, .compositor_configure, positioner, parent_bounds, work_area);
    try pop.requestGrab(77, .{ .confirmed = true });
    try pop.onGrabIssued();
    try testing.expect(pop.has_grab);

    pop.onGrabDenied();
    try testing.expect(!pop.has_grab);
    try testing.expectEqual(@as(?u32, null), pop.seat_serial);
    try testing.expectEqual(popup.PopupState.dismissed, pop.state);
    try testing.expectEqual(popup.DismissReason.compositor_dismiss, pop.dismiss_reason.?);
}

test "api-w22 popup dismissal paths and double teardown safety" {
    const parent_bounds: popup.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const work_area: popup.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const positioner: popup.Positioner = .{
        .anchor_rect = .{ .x = 10, .y = 10, .width = 40, .height = 20 },
        .size = .{ .width = 80, .height = 80 },
    };

    // Client dismissal
    var client_pop = try popup.NativePopup.init(
        .os_surface,
        .compositor_configure,
        positioner,
        parent_bounds,
        work_area,
    );
    try client_pop.dismiss();
    try testing.expectEqual(popup.PopupState.dismissed, client_pop.state);
    try testing.expectEqual(popup.DismissReason.client_dismiss, client_pop.dismiss_reason.?);
    try testing.expectError(error.AlreadyClosed, client_pop.dismiss());
    try testing.expectError(error.DoubleTeardown, client_pop.teardown());

    // Compositor dismissal (e.g. popup_done on click outside)
    var comp_pop = try popup.NativePopup.init(.os_surface, .compositor_configure, positioner, parent_bounds, work_area);
    comp_pop.onCompositorDismiss();
    try testing.expectEqual(popup.PopupState.dismissed, comp_pop.state);
    try testing.expectEqual(popup.DismissReason.compositor_dismiss, comp_pop.dismiss_reason.?);

    // Parent closed
    var parent_pop = try popup.NativePopup.init(
        .os_surface,
        .compositor_configure,
        positioner,
        parent_bounds,
        work_area,
    );
    parent_pop.onParentClose();
    try testing.expectEqual(popup.PopupState.dismissed, parent_pop.state);
    try testing.expectEqual(popup.DismissReason.parent_closed, parent_pop.dismiss_reason.?);
}

// ============================================================================
// W22 Layer Shell Tests
// ============================================================================

test "api-w22 layer shell returns explicit LayerShellUnsupported when capability unavailable" {
    const options: layer_shell.LayerShellOptions = .{
        .layer = .top,
        .anchor = layer_shell.Anchor.top_dock,
        .desired_width = 1920,
        .desired_height = 32,
    };

    // Unavailable capability must immediately return error; NEVER fake an ordinary toplevel.
    try testing.expectError(
        error.LayerShellUnsupported,
        layer_shell.LayerSurface.init(options, .unavailable),
    );
}

test "api-w22 layer shell configure, ack, and commit lifecycle" {
    const options: layer_shell.LayerShellOptions = .{
        .layer = .top,
        .anchor = layer_shell.Anchor.top_dock,
        .exclusive_zone = 32,
        .desired_width = 1920,
        .desired_height = 32,
    };

    var surface = try layer_shell.LayerSurface.init(options, .supported);
    try testing.expectEqual(layer_shell.SurfaceState.attached, surface.state);
    try testing.expectEqual(@as(u32, 1920), surface.current_width);
    try testing.expectEqual(@as(u32, 32), surface.current_height);

    // Compositor sends configure event with serial
    try surface.handleConfigure(101, 1920, 32);
    try testing.expectEqual(layer_shell.SurfaceState.configured, surface.state);
    try testing.expectEqual(@as(?u32, 101), surface.last_configured_serial);
    try testing.expectEqual(@as(u32, 1), surface.configured_count);

    // Client acknowledges configure
    try surface.ackConfigure();
    try testing.expectEqual(layer_shell.SurfaceState.mapped, surface.state);
    try testing.expectEqual(@as(?u32, 101), surface.last_acked_serial);
    try testing.expectEqual(@as(u32, 1), surface.acked_count);

    // Commit frame
    try surface.commit();
    try testing.expectEqual(@as(u32, 1), surface.committed_count);
}

test "api-w22 layer shell unacknowledged configure error" {
    const options: layer_shell.LayerShellOptions = .{};
    var surface = try layer_shell.LayerSurface.init(options, .supported);

    // Acknowledging before receiving configure must fail
    try testing.expectError(error.UnacknowledgedConfigure, surface.ackConfigure());
}
test "api-w22 layer shell rejects commit before configure ack and repeated ack" {
    var surface = try layer_shell.LayerSurface.init(.{}, .supported);
    try testing.expectError(error.ProtocolViolation, surface.commit());
    try surface.handleConfigure(17, 100, 32);
    try testing.expectError(error.UnacknowledgedConfigure, surface.commit());
    try surface.ackConfigure();
    try surface.commit();
    try testing.expectError(error.UnacknowledgedConfigure, surface.ackConfigure());
    try surface.handleConfigure(18, 120, 32);
    try testing.expectError(error.UnacknowledgedConfigure, surface.commit());
    try surface.ackConfigure();
    try surface.commit();
    try testing.expectEqual(@as(u32, 2), surface.committed_count);
}

test "api-w22 layer shell exclusive zone and input region manipulation" {
    var surface = try layer_shell.LayerSurface.init(.{}, .supported);

    // Set exclusive zone to 48px
    surface.setExclusiveZone(48);
    try testing.expectEqual(@as(i32, 48), surface.options.exclusive_zone);

    // Input region: passthrough means an EMPTY wl_region, which is not the
    // same as sending no region at all.
    var region: layer_shell.InputRegion = .{};
    region.setPassthrough();
    surface.setInputRegion(region);
    try testing.expectEqual(layer_shell.InputRegionMode.passthrough, surface.options.input_region.mode);
    try testing.expectEqual(@as(u32, 0), surface.options.input_region.count);
    try testing.expect(surface.options.input_region.plan().send_region);

    // A region never set leaves the compositor's initial value, which accepts
    // input everywhere and sends no request.
    region.inherit();
    surface.setInputRegion(region);
    try testing.expectEqual(layer_shell.InputRegionMode.inherit, surface.options.input_region.mode);
    try testing.expect(!surface.options.input_region.plan().send_region);

    // Input region: specific rect
    region.addRect(.{ .x = 10, .y = 0, .width = 100, .height = 32 });
    surface.setInputRegion(region);
    try testing.expectEqual(layer_shell.InputRegionMode.rects, surface.options.input_region.mode);
    try testing.expectEqual(@as(u32, 1), surface.options.input_region.count);
}

test "api-w22 layer shell handles compositor closed and output disconnect safely" {
    // Closed by compositor
    var comp_closed = try layer_shell.LayerSurface.init(.{}, .supported);
    comp_closed.handleClosed();
    try testing.expectEqual(layer_shell.SurfaceState.destroyed, comp_closed.state);
    try testing.expectError(error.DoubleTeardown, comp_closed.teardown());
    // Removing an output after it closed the role still updates attachment.
    comp_closed.handleOutputDisconnected();
    try testing.expect(!comp_closed.output_attached);
    try testing.expectEqual(layer_shell.SurfaceState.destroyed, comp_closed.state);
    try testing.expectError(error.DoubleTeardown, comp_closed.teardown());

    // Output disconnected
    var out_disc = try layer_shell.LayerSurface.init(.{}, .supported);
    out_disc.handleOutputDisconnected();
    try testing.expect(!out_disc.output_attached);
    try testing.expectEqual(layer_shell.SurfaceState.destroyed, out_disc.state);
}

// ============================================================================
// W22 Window Decorations Tests
// ============================================================================

test "api-w22 decorations hit test border and corner classification" {
    const metrics: decorations.DecorationMetrics = .{
        .border_thickness = 6,
        .corner_size = 12,
        .titlebar_height = 32,
        .button_width = 40,
        .button_count = 3,
    };

    const width: u32 = 800;
    const height: u32 = 600;

    // Top-left corner
    try testing.expectEqual(
        decorations.SdlHitTestResult.resize_topleft,
        decorations.classifyHitTestPoint(2, 2, width, height, metrics),
    );

    // Top border
    try testing.expectEqual(
        decorations.SdlHitTestResult.resize_top,
        decorations.classifyHitTestPoint(100, 2, width, height, metrics),
    );

    // Top-right corner
    try testing.expectEqual(
        decorations.SdlHitTestResult.resize_topright,
        decorations.classifyHitTestPoint(795, 2, width, height, metrics),
    );

    // Bottom-left corner
    try testing.expectEqual(
        decorations.SdlHitTestResult.resize_bottomleft,
        decorations.classifyHitTestPoint(2, 595, width, height, metrics),
    );

    // Bottom-right corner
    try testing.expectEqual(
        decorations.SdlHitTestResult.resize_bottomright,
        decorations.classifyHitTestPoint(795, 595, width, height, metrics),
    );

    // Left border
    try testing.expectEqual(
        decorations.SdlHitTestResult.resize_left,
        decorations.classifyHitTestPoint(2, 200, width, height, metrics),
    );

    // Right border
    try testing.expectEqual(
        decorations.SdlHitTestResult.resize_right,
        decorations.classifyHitTestPoint(795, 200, width, height, metrics),
    );
}

test "api-w22 decorations hit test titlebar drag vs window buttons" {
    const metrics: decorations.DecorationMetrics = .{
        .border_thickness = 6,
        .corner_size = 12,
        .titlebar_height = 32,
        .button_width = 40,
        .button_count = 3, // Total button area: 120px (from 680 to 800)
    };

    const width: u32 = 800;
    const height: u32 = 600;

    // Draggable titlebar area
    try testing.expectEqual(
        decorations.SdlHitTestResult.draggable,
        decorations.classifyHitTestPoint(200, 15, width, height, metrics),
    );

    // Window control buttons area (must be normal so clicks reach close/minimize buttons)
    try testing.expectEqual(
        decorations.SdlHitTestResult.normal,
        decorations.classifyHitTestPoint(750, 15, width, height, metrics),
    );

    // Client content area
    try testing.expectEqual(
        decorations.SdlHitTestResult.normal,
        decorations.classifyHitTestPoint(200, 200, width, height, metrics),
    );
}

test "api-w22 decorations server-side mode returns normal for all areas" {
    var mgr = try decorations.DecorationsManager.init(.server_side, .{});
    const width: u32 = 800;
    const height: u32 = 600;

    // All coordinates must return normal under server-side decorations
    try testing.expectEqual(
        decorations.SdlHitTestResult.normal,
        mgr.hitTest(2, 2, width, height),
    );
    try testing.expectEqual(
        decorations.SdlHitTestResult.normal,
        mgr.hitTest(200, 15, width, height),
    );
}
test "api-w22 decorations interactive move/resize strictly requires PointOfRiskApproval" {
    var mgr = try decorations.DecorationsManager.init(.client_side, .{});

    // Unconfirmed move must fail
    try testing.expectError(
        error.RiskConfirmationRequired,
        mgr.startMove(.{ .confirmed = false }, null),
    );
    try testing.expect(!mgr.interactive_move_active);

    // Confirmed move succeeds
    try mgr.startMove(.{ .confirmed = true }, 101);
    try testing.expect(mgr.interactive_move_active);

    // Concurrent action must fail
    try testing.expectError(
        error.ActionAlreadyActive,
        mgr.startResize(.{ .confirmed = true }, .top, 102),
    );

    mgr.endInteractiveAction();
    try testing.expect(!mgr.interactive_move_active);

    // Confirmed resize succeeds
    try mgr.startResize(.{ .confirmed = true }, .bottom_right, 103);
    try testing.expect(mgr.interactive_resize_active);
    try testing.expectEqual(decorations.ResizeEdge.bottom_right, mgr.active_resize_edge);
}

test "api-w22 decorations system menu dispatch" {
    var mgr = try decorations.DecorationsManager.init(.client_side, .{});

    try testing.expect(!mgr.system_menu_shown);
    mgr.showSystemMenu(150, 20);
    try testing.expect(mgr.system_menu_shown);
    try testing.expectEqual(@as(i32, 150), mgr.system_menu_pos.?.x);
    try testing.expectEqual(@as(i32, 20), mgr.system_menu_pos.?.y);
}
