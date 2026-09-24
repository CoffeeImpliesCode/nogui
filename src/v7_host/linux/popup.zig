//! Native Linux popup role, positioner constraints, grab, and dismissal.
//! Keeps in-app overlays distinct from OS popup surfaces.
//! Follows xdg-shell popup specification and SDL3 native window properties.
const std = @import("std");
const assert = std.debug.assert;

pub const Anchor = enum(u8) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,
};

pub const Gravity = enum(u8) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,
};

pub const ConstraintAdjustment = packed struct(u32) {
    slide_x: bool = false,
    slide_y: bool = false,
    flip_x: bool = false,
    flip_y: bool = false,
    resize_x: bool = false,
    resize_y: bool = false,
    _reserved: u26 = 0,

    pub const none: ConstraintAdjustment = .{};
    pub const all: ConstraintAdjustment = .{
        .slide_x = true,
        .slide_y = true,
        .flip_x = true,
        .flip_y = true,
        .resize_x = true,
        .resize_y = true,
    };
    pub const slide: ConstraintAdjustment = .{ .slide_x = true, .slide_y = true };
    pub const flip: ConstraintAdjustment = .{ .flip_x = true, .flip_y = true };
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn right(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.width));
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.height));
    }

    pub fn contains(self: Rect, pt: Point) bool {
        const in_x = pt.x >= self.x and pt.x < self.right();
        const in_y = pt.y >= self.y and pt.y < self.bottom();
        return in_x and in_y;
    }
};

pub const Positioner = struct {
    anchor_rect: Rect,
    anchor: Anchor = .bottom,
    gravity: Gravity = .bottom,
    constraint_adjustment: ConstraintAdjustment = ConstraintAdjustment.all,
    offset: Point = .{ .x = 0, .y = 0 },
    size: Size,
    /// Ask the compositor to place the popup again whenever the conditions it
    /// was placed against change, which is what makes a popup follow a parent
    /// that moves or scrolls. The xdg-shell path sends
    /// `xdg_positioner.set_reactive`; a display server with no positioner at
    /// all, and an `xdg_positioner` binding older than version 3, cannot
    /// express it and refuse it by name rather than placing a popup that will
    /// not follow its anchor.
    reactive: bool = false,
};

pub const ResolvedPlacement = struct {
    rect: Rect,
    flipped_x: bool = false,
    flipped_y: bool = false,
    slid_x: bool = false,
    slid_y: bool = false,
    resized_x: bool = false,
    resized_y: bool = false,
};

/// Keep in-app overlays distinct from OS-level native popup surfaces.
pub const PopupKind = enum(u8) {
    os_surface = 0,
    in_app_overlay = 1,
};

/// The popup's protocol lifecycle, in the order the protocol reaches it.
pub const PopupState = enum(u8) {
    /// No role exists yet.
    uninitialized = 0,
    /// The role and its positioner exist and nothing has been committed. A grab
    /// may still be taken: `xdg_popup.grab` is refused after the popup maps.
    positioned = 1,
    /// The compositor delivered a configure serial that is not acknowledged
    /// yet. No buffer may be attached.
    configured = 2,
    /// A buffer was committed after the configure was acknowledged, so the
    /// compositor maps the popup.
    mapped = 3,
    /// A dismissal was claimed and the single teardown is pending.
    dismissed = 4,
    closed = 5,
};

/// How the surface carrying this popup reaches the screen.
pub const Mapping = enum(u8) {
    /// The compositor answers the initial commit with `xdg_surface.configure`
    /// and maps the popup only once a buffer is committed after that serial is
    /// acknowledged. This is the xdg-shell path and the reason the popup's grab
    /// has to be taken before the first commit.
    compositor_configure = 0,
    /// The display server maps the popup when its window is shown. The X11
    /// override-redirect popup has no configure handshake, so a configure that
    /// never arrives is not a failure on this path.
    window_manager_direct = 1,
};

pub const DismissReason = enum(u8) {
    client_dismiss = 0,
    compositor_dismiss = 1,
    parent_closed = 2,
    error_teardown = 3,
};

/// What the compositor answered when it configured the popup. The position is
/// the compositor's own answer to the positioner rules, not this tree's
/// prediction, so the two can be compared.
pub const PopupConfigure = struct {
    serial: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Explicit point-of-risk gate for external grabs and system actions.
pub const PointOfRiskApproval = struct {
    confirmed: bool = false,
};

pub const PopupError = error{
    MissingParent,
    /// A parent `xdg_surface` is required to give a popup its role.
    MissingParentSurface,
    /// The compositor does not advertise `xdg_wm_base`, so no popup role can be
    /// created. Never answered with a toplevel or an in-app overlay instead.
    WaylandShellUnsupported,
    InvalidSize,
    /// An `xdg_positioner` with a zero size or a zero anchor rectangle is
    /// incomplete and the compositor answers `invalid_positioner`.
    PositionerIncomplete,
    RiskConfirmationRequired,
    GrabFailed,
    /// A display-server grab asked for before the popup is on screen. The X11
    /// pointer grab is taken on the popup's own window, and a window that is
    /// not viewable cannot be one, so this is refused before the request is
    /// sent rather than sent and reported as a grab nobody holds.
    GrabBeforeMap,
    MissingSeatSerial,
    /// A grab asked for after the popup was mapped is a protocol error
    /// (`xdg_popup.invalid_grab`), so it is refused before any request is sent.
    GrabAfterCommit,
    /// A configure serial that was delivered has to be acknowledged before a
    /// buffer is committed.
    UnacknowledgedConfigure,
    /// An acknowledgement naming a serial the compositor never sent.
    InvalidConfigureSerial,
    ProtocolViolation,
    NativeRoleUnavailable,
    AlreadyActive,
    AlreadyClosed,
    DoubleTeardown,
    /// An in-app overlay never allocates a compositor surface.
    InAppOverlayHasNoNativeSurface,
};

/// The wire values the positioner enums take in `xdg-shell.xml`: the `anchor`
/// enum at line 188 and the `gravity` enum at line 213, which are the same nine
/// members in the same order.
pub fn anchorBits(anchor: Anchor) u32 {
    return @intFromEnum(anchor);
}

pub fn gravityBits(gravity: Gravity) u32 {
    return @intFromEnum(gravity);
}

/// The `constraint_adjustment` bitfield, `xdg-shell.xml` line 239: `slide_x` is
/// bit 0, `slide_y` bit 1, `flip_x` bit 2, `flip_y` bit 3, `resize_x` bit 4 and
/// `resize_y` bit 5. Written out rather than bit-cast from the packed struct so
/// a field reorder cannot silently renumber a flag the compositor reads.
pub fn constraintAdjustmentBits(adjustment: ConstraintAdjustment) u32 {
    var bits: u32 = 0;
    if (adjustment.slide_x) bits |= 1 << 0;
    if (adjustment.slide_y) bits |= 1 << 1;
    if (adjustment.flip_x) bits |= 1 << 2;
    if (adjustment.flip_y) bits |= 1 << 3;
    if (adjustment.resize_x) bits |= 1 << 4;
    if (adjustment.resize_y) bits |= 1 << 5;
    return bits;
}

/// Calculate anchor point on the parent anchor rectangle.
fn calculateAnchorPoint(rect: Rect, anchor: Anchor) Point {
    const half_w: i32 = @intCast(rect.width / 2);
    const half_h: i32 = @intCast(rect.height / 2);

    return switch (anchor) {
        .none => .{ .x = rect.x + half_w, .y = rect.y + half_h },
        .top => .{ .x = rect.x + half_w, .y = rect.y },
        .bottom => .{ .x = rect.x + half_w, .y = rect.bottom() },
        .left => .{ .x = rect.x, .y = rect.y + half_h },
        .right => .{ .x = rect.right(), .y = rect.y + half_h },
        .top_left => .{ .x = rect.x, .y = rect.y },
        .top_right => .{ .x = rect.right(), .y = rect.y },
        .bottom_left => .{ .x = rect.x, .y = rect.bottom() },
        .bottom_right => .{ .x = rect.right(), .y = rect.bottom() },
    };
}

/// Calculate top-left point of popup from anchor point and gravity.
fn calculateGravityPoint(anchor_point: Point, size: Size, gravity: Gravity) Point {
    const w: i32 = @intCast(size.width);
    const h: i32 = @intCast(size.height);
    const half_w: i32 = @intCast(size.width / 2);
    const half_h: i32 = @intCast(size.height / 2);

    return switch (gravity) {
        .none => .{ .x = anchor_point.x - half_w, .y = anchor_point.y - half_h },
        .top => .{ .x = anchor_point.x - half_w, .y = anchor_point.y - h },
        .bottom => .{ .x = anchor_point.x - half_w, .y = anchor_point.y },
        .left => .{ .x = anchor_point.x - w, .y = anchor_point.y - half_h },
        .right => .{ .x = anchor_point.x, .y = anchor_point.y - half_h },
        .top_left => .{ .x = anchor_point.x - w, .y = anchor_point.y - h },
        .top_right => .{ .x = anchor_point.x, .y = anchor_point.y - h },
        .bottom_left => .{ .x = anchor_point.x - w, .y = anchor_point.y },
        .bottom_right => .{ .x = anchor_point.x, .y = anchor_point.y },
    };
}

fn flipAnchorHorizontal(anchor: Anchor) Anchor {
    return switch (anchor) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => anchor,
    };
}

fn flipGravityHorizontal(gravity: Gravity) Gravity {
    return switch (gravity) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => gravity,
    };
}

fn flipAnchorVertical(anchor: Anchor) Anchor {
    return switch (anchor) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => anchor,
    };
}

fn flipGravityVertical(gravity: Gravity) Gravity {
    return switch (gravity) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => gravity,
    };
}

/// Pure geometric constraint solver following xdg-shell positioner logic.
/// Resolves popup rectangle relative to parent surface window coordinates.
pub fn resolvePlacement(
    positioner: Positioner,
    parent_bounds: Rect,
    work_area: Rect,
) ResolvedPlacement {
    assert(positioner.size.width > 0);
    assert(positioner.size.height > 0);

    var cur_anchor = positioner.anchor;
    var cur_gravity = positioner.gravity;
    var cur_width = positioner.size.width;
    var cur_height = positioner.size.height;

    var flipped_x = false;
    var flipped_y = false;
    var slid_x = false;
    var slid_y = false;
    var resized_x = false;
    var resized_y = false;

    // 1. Calculate initial relative position.
    var anchor_pt = calculateAnchorPoint(positioner.anchor_rect, cur_anchor);
    const gravity_pt = calculateGravityPoint(anchor_pt, .{
        .width = cur_width,
        .height = cur_height,
    }, cur_gravity);
    var rel_x = gravity_pt.x + positioner.offset.x;
    var rel_y = gravity_pt.y + positioner.offset.y;

    // Global position in monitor work area space.
    var glob_x = parent_bounds.x + rel_x;
    var glob_y = parent_bounds.y + rel_y;

    // 2. Horizontal constraint handling.
    const glob_w: i32 = @intCast(cur_width);
    const overflow_right = (glob_x + glob_w) > work_area.right();
    const overflow_left = glob_x < work_area.x;

    if (overflow_right or overflow_left) {
        if (positioner.constraint_adjustment.flip_x) {
            const candidate_anchor = flipAnchorHorizontal(cur_anchor);
            const candidate_gravity = flipGravityHorizontal(cur_gravity);
            const cand_anchor_pt = calculateAnchorPoint(
                positioner.anchor_rect,
                candidate_anchor,
            );
            const cand_gravity_pt = calculateGravityPoint(cand_anchor_pt, .{
                .width = cur_width,
                .height = cur_height,
            }, candidate_gravity);
            const cand_glob_x = parent_bounds.x + cand_gravity_pt.x - positioner.offset.x;

            const cand_fits = cand_glob_x >= work_area.x and
                (cand_glob_x + glob_w) <= work_area.right();
            if (cand_fits) {
                cur_anchor = candidate_anchor;
                cur_gravity = candidate_gravity;
                anchor_pt = cand_anchor_pt;
                rel_x = cand_gravity_pt.x - positioner.offset.x;
                glob_x = cand_glob_x;
                flipped_x = true;
            }
        }

        // Re-check after flip attempt.
        const still_overflow_right = (glob_x + glob_w) > work_area.right();
        const still_overflow_left = glob_x < work_area.x;

        if (still_overflow_right or still_overflow_left) {
            if (positioner.constraint_adjustment.slide_x) {
                if (still_overflow_right) {
                    const shift = (glob_x + glob_w) - work_area.right();
                    glob_x -= shift;
                    rel_x -= shift;
                    slid_x = true;
                }
                if (glob_x < work_area.x) {
                    const shift = work_area.x - glob_x;
                    glob_x += shift;
                    rel_x += shift;
                    slid_x = true;
                }
            } else if (positioner.constraint_adjustment.resize_x) {
                if (still_overflow_right) {
                    const max_w: i32 = work_area.right() - glob_x;
                    if (max_w > 0) {
                        cur_width = @intCast(max_w);
                        resized_x = true;
                    }
                }
            }
        }
    }

    // 3. Vertical constraint handling.
    const glob_h: i32 = @intCast(cur_height);
    const overflow_bottom = (glob_y + glob_h) > work_area.bottom();
    const overflow_top = glob_y < work_area.y;

    if (overflow_bottom or overflow_top) {
        if (positioner.constraint_adjustment.flip_y) {
            const candidate_anchor = flipAnchorVertical(cur_anchor);
            const candidate_gravity = flipGravityVertical(cur_gravity);
            const cand_anchor_pt = calculateAnchorPoint(
                positioner.anchor_rect,
                candidate_anchor,
            );
            const cand_gravity_pt = calculateGravityPoint(cand_anchor_pt, .{
                .width = cur_width,
                .height = cur_height,
            }, candidate_gravity);
            const cand_glob_y = parent_bounds.y + cand_gravity_pt.y - positioner.offset.y;

            const cand_fits = cand_glob_y >= work_area.y and
                (cand_glob_y + glob_h) <= work_area.bottom();
            if (cand_fits) {
                cur_anchor = candidate_anchor;
                cur_gravity = candidate_gravity;
                anchor_pt = cand_anchor_pt;
                rel_y = cand_gravity_pt.y - positioner.offset.y;
                glob_y = cand_glob_y;
                flipped_y = true;
            }
        }

        // Re-check after vertical flip attempt.
        const still_overflow_bottom = (glob_y + glob_h) > work_area.bottom();
        const still_overflow_top = glob_y < work_area.y;

        if (still_overflow_bottom or still_overflow_top) {
            if (positioner.constraint_adjustment.slide_y) {
                if (still_overflow_bottom) {
                    const shift = (glob_y + glob_h) - work_area.bottom();
                    glob_y -= shift;
                    rel_y -= shift;
                    slid_y = true;
                }
                if (glob_y < work_area.y) {
                    const shift = work_area.y - glob_y;
                    glob_y += shift;
                    rel_y += shift;
                    slid_y = true;
                }
            } else if (positioner.constraint_adjustment.resize_y) {
                if (still_overflow_bottom) {
                    const max_h: i32 = work_area.bottom() - glob_y;
                    if (max_h > 0) {
                        cur_height = @intCast(max_h);
                        resized_y = true;
                    }
                }
            }
        }
    }

    return .{
        .rect = .{
            .x = rel_x,
            .y = rel_y,
            .width = cur_width,
            .height = cur_height,
        },
        .flipped_x = flipped_x,
        .flipped_y = flipped_y,
        .slid_x = slid_x,
        .slid_y = slid_y,
        .resized_x = resized_x,
        .resized_y = resized_y,
    };
}

/// Native popup controller managing placement, grab, and dismissal lifecycle.
///
/// The machine records protocol state and nothing else: it never issues a
/// compositor request. The order in which a client has to reach those requests
/// is the order this machine accepts them in, so an adapter cannot get ahead of
/// the protocol and still be believed.
pub const NativePopup = struct {
    kind: PopupKind,
    mapping: Mapping,
    state: PopupState = .uninitialized,
    positioner: Positioner,
    /// This tree's own solution of the positioner rules against `work_area`.
    /// On the xdg-shell path the compositor solves them instead, so this value
    /// is a prediction to compare against `configure`, never the placement sent.
    placement: ResolvedPlacement,
    parent_bounds: Rect,
    work_area: Rect,
    has_grab: bool = false,
    /// The serial a grab was issued with. A grab is a real protocol state, so it
    /// is only set once the request went out, and it is only ever a serial the
    /// display server itself gave: a user-event serial on the xdg-shell path,
    /// and null on a path whose grab names no user event at all, which is the
    /// only honest answer there rather than a number this tree made up.
    seat_serial: ?u32 = null,
    /// An approved grab waiting to be issued. A grab is only legal before the
    /// first commit, so this cannot outlive the uncommitted state.
    pending_grab_serial: ?u32 = null,
    /// True between `requestGrab` and the request that settles it. A grab is
    /// optional on a path whose grab names no user-event serial, so the
    /// pending serial alone cannot say whether a grab was asked for: it is
    /// legitimately null on such a path, and this is what says there is one.
    grab_pending: bool = false,
    /// The last configure the compositor sent, with its serial.
    configure: ?PopupConfigure = null,
    acked_serial: ?u32 = null,
    /// The size the popup is mapped at, taken from the compositor's configure
    /// or from the requested size when no configure arrives.
    mapped_size: Size = .{ .width = 0, .height = 0 },
    configure_count: u32 = 0,
    commit_count: u32 = 0,
    /// How many reposition requests this popup asked for. The compositor
    /// answers with its own `repositioned` events, and the two counts are
    /// what say whether an answer arrived.
    reposition_count: u32 = 0,
    /// How many `popup_done` events the compositor delivered. A dismissal the
    /// compositor drove is counted here, not inferred from the state.
    popup_done_count: u32 = 0,
    dismiss_reason: ?DismissReason = null,
    teardown_performed: bool = false,

    pub fn init(
        kind: PopupKind,
        mapping: Mapping,
        positioner: Positioner,
        parent_bounds: Rect,
        work_area: Rect,
    ) PopupError!NativePopup {
        if (positioner.size.width == 0 or positioner.size.height == 0) {
            return error.InvalidSize;
        }

        const placement = resolvePlacement(positioner, parent_bounds, work_area);

        return .{
            .kind = kind,
            .mapping = mapping,
            .state = .positioned,
            .positioner = positioner,
            .placement = placement,
            .parent_bounds = parent_bounds,
            .work_area = work_area,
            .has_grab = false,
            .seat_serial = null,
            .pending_grab_serial = null,
            .configure = null,
            .grab_pending = false,
            .acked_serial = null,
            .mapped_size = .{ .width = 0, .height = 0 },
            .configure_count = 0,
            .commit_count = 0,
            .popup_done_count = 0,
            .dismiss_reason = null,
            .reposition_count = 0,
            .teardown_performed = false,
        };
    }

    /// Update the positioner rules and recalculate the predicted placement.
    ///
    /// This records the request and this tree's answer to it. The placement
    /// itself is the compositor's: a mapped popup is moved with
    /// `xdg_popup.reposition` and a fresh positioner, never by rebuilding the
    /// one it already copied, so the count below is what a caller compares
    /// with the `repositioned` events the compositor sends back.
    pub fn reposition(
        self: *NativePopup,
        new_positioner: Positioner,
        parent_bounds: Rect,
        work_area: Rect,
    ) PopupError!void {
        if (self.state == .closed or self.state == .dismissed) {
            return error.AlreadyClosed;
        }
        if (new_positioner.size.width == 0 or new_positioner.size.height == 0) {
            return error.InvalidSize;
        }

        self.positioner = new_positioner;
        self.parent_bounds = parent_bounds;
        self.work_area = work_area;
        self.reposition_count += 1;
        self.placement = resolvePlacement(new_positioner, parent_bounds, work_area);
    }

    /// Record an approved grab request that the adapter is about to issue.
    ///
    /// The two paths disagree about the serial and about the moment, and both
    /// disagreements come from the display server rather than from this tree:
    ///
    ///  * On xdg-shell, `xdg_popup.grab` carries a serial of the user event
    ///    that asked for the popup, so a missing serial is refused rather than
    ///    sent as zero, and the request is only legal while the popup is
    ///    unmapped, so a grab after the first commit is refused here before
    ///    anything reaches the wire.
    ///  * A display server that maps the popup itself has no such handshake.
    ///    Its pointer grab is taken against the popup's own window, so it needs
    ///    the window to be on screen, and it names an X timestamp rather than a
    ///    Wayland user-event serial, so no serial is required here. What the
    ///    request must not be is a claim that the display server holds a grab:
    ///    that is only recorded by `onGrabIssued`, and only once the display
    ///    server itself has answered.
    pub fn requestGrab(
        self: *NativePopup,
        seat_serial: ?u32,
        approval: PointOfRiskApproval,
    ) PopupError!void {
        if (self.state == .closed or self.state == .dismissed) {
            return error.AlreadyClosed;
        }
        if (self.kind != .os_surface) return error.InAppOverlayHasNoNativeSurface;
        if (!approval.confirmed) return error.RiskConfirmationRequired;
        if (self.mapping == .compositor_configure) {
            if (self.state == .mapped) return error.GrabAfterCommit;
            if (self.commit_count > 0) return error.GrabAfterCommit;
            if (seat_serial == null or seat_serial.? == 0) return error.MissingSeatSerial;
        } else {
            // The grab names the popup's own window, and a window that is not
            // mapped cannot be one. Asking first would send a request the
            // display server can only answer `NotViewable`.
            if (self.state != .mapped or self.commit_count == 0) return error.GrabBeforeMap;
        }
        // A second grab is not a second request on the same popup, and this
        // comes after the state rules above so a popup that already holds one
        // is still told the truth about the state it is in.
        if (self.grab_pending or self.has_grab) return error.AlreadyActive;
        self.pending_grab_serial = seat_serial;
        self.grab_pending = true;
    }

    /// Record that the grab request reached the display server or the
    /// compositor. Only now is the grab a real state rather than an
    /// intention, and `seat_serial` records the serial the request carried,
    /// which is null on a path that carried none.
    pub fn onGrabIssued(self: *NativePopup) PopupError!void {
        if (!self.grab_pending) return error.GrabFailed;
        self.grab_pending = false;
        self.has_grab = true;
        self.seat_serial = self.pending_grab_serial;
        self.pending_grab_serial = null;
    }

    /// Release an approved grab that was never issued.
    ///
    /// A refusal after `requestGrab` would otherwise leave a serial behind
    /// that the initial commit refuses, so a caller that gave up on the grab
    /// would be told one is still pending. This clears the intention and
    /// nothing else: `has_grab` and `seat_serial` are untouched, because no
    /// grab was ever taken and no serial ever reached the wire.
    pub fn clearPendingGrab(self: *NativePopup) void {
        self.pending_grab_serial = null;
        self.grab_pending = false;
    }

    /// Record that the compositor refused or lost the grab, which dismisses the
    /// popup immediately. The protocol says a denied grab dismisses the popup,
    /// so this is a dismissal and not a failed state transition.
    pub fn onGrabDenied(self: *NativePopup) void {
        self.pending_grab_serial = null;
        self.grab_pending = false;
        self.has_grab = false;
        self.seat_serial = null;
        if (self.state == .closed or self.state == .dismissed) return;
        self.dismiss_reason = .compositor_dismiss;
        self.state = .dismissed;
        self.claimTeardown();
    }

    /// Process the configure the compositor sent for the popup. `x` and `y` are
    /// the compositor's own answer to the positioner rules, relative to the
    /// parent's window geometry, so they are the placement evidence and not this
    /// tree's prediction.
    pub fn handleConfigure(
        self: *NativePopup,
        serial: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) PopupError!void {
        if (self.state == .closed or self.state == .dismissed) return error.AlreadyClosed;
        if (self.state != .positioned and self.state != .configured and
            self.state != .mapped)
        {
            return error.ProtocolViolation;
        }
        if (width < 0 or height < 0) return error.InvalidSize;

        // A new configure invalidates the acknowledgement of the previous one
        // until this one is acknowledged in turn.
        self.acked_serial = null;
        self.configure = .{
            .serial = serial,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };
        self.configure_count += 1;
        self.state = .configured;
    }

    /// Acknowledge a configure serial and take the size it names.
    ///
    /// Returns the size a buffer has to match. A configure of zero width or
    /// height means the compositor leaves that axis to the client, so the
    /// requested size stands for it.
    pub fn ackConfigure(self: *NativePopup, serial: u32) PopupError!Size {
        if (self.state == .closed or self.state == .dismissed) return error.AlreadyClosed;
        const configure = self.configure orelse return error.UnacknowledgedConfigure;
        if (configure.serial != serial or self.acked_serial != null) return error.InvalidConfigureSerial;

        const width: u32 = if (configure.width > 0)
            @intCast(configure.width)
        else
            self.positioner.size.width;
        const height: u32 = if (configure.height > 0)
            @intCast(configure.height)
        else
            self.positioner.size.height;
        if (width == 0 or height == 0) return error.InvalidSize;

        self.acked_serial = serial;
        self.mapped_size = .{ .width = width, .height = height };
        return self.mapped_size;
    }

    /// Commit a buffer of `size` and report the popup as mapped.
    ///
    /// A configure that arrived must have been acknowledged first: attaching a
    /// buffer to an unconfigured `xdg_surface` is `xdg_surface.unconfigured_buffer`.
    /// On the xdg-shell path a configure always precedes the first buffer, so a
    /// commit before any configure is refused there and accepted on a driver
    /// that maps the popup without a handshake.
    pub fn commit(self: *NativePopup, size: Size) PopupError!void {
        if (self.state == .closed or self.state == .dismissed) return error.AlreadyClosed;
        if (size.width == 0 or size.height == 0) return error.InvalidSize;
        if (self.state == .configured and self.acked_serial == null) {
            return error.UnacknowledgedConfigure;
        }
        if (self.mapping == .compositor_configure and self.configure == null) {
            return error.UnacknowledgedConfigure;
        }
        if (self.configure != null and self.acked_serial == null) {
            return error.UnacknowledgedConfigure;
        }
        if (self.acked_serial == null and self.mapped_size.width == 0) {
            self.mapped_size = size;
        }
        if (self.mapped_size.width != size.width or
            self.mapped_size.height != size.height)
        {
            return error.InvalidSize;
        }

        self.commit_count += 1;
        self.state = .mapped;
    }

    /// Application-driven dismissal. The role object is destroyed by the
    /// adapter on this path, which is also how a client dismisses its own popup.
    pub fn dismiss(self: *NativePopup) PopupError!void {
        if (self.state == .dismissed or self.state == .closed) {
            return error.AlreadyClosed;
        }
        self.dismiss_reason = .client_dismiss;
        self.has_grab = false;
        self.pending_grab_serial = null;
        self.state = .dismissed;
        // The teardown is claimed directly rather than through `teardown`,
        // which reports the bare `closed` and would discard this reason.
        self.claimTeardown();
    }

    /// Dismissal initiated by the compositor. `xdg_popup.popup_done` is the
    /// event that carries it, and a second one cannot claim a teardown again.
    pub fn onCompositorDismiss(self: *NativePopup) void {
        if (self.state == .dismissed or self.state == .closed) return;
        self.popup_done_count += 1;
        self.dismiss_reason = .compositor_dismiss;
        self.has_grab = false;
        self.pending_grab_serial = null;
        self.state = .dismissed;
        self.claimTeardown();
    }

    /// Dismissal caused by the parent window closing. This is the client's own
    /// knowledge; a compositor that also sends `popup_done` for the same closure
    /// is counted separately in `popup_done_count`.
    pub fn onParentClose(self: *NativePopup) void {
        if (self.state == .dismissed or self.state == .closed) return;
        self.dismiss_reason = .parent_closed;
        self.has_grab = false;
        self.pending_grab_serial = null;
        self.state = .dismissed;
        self.claimTeardown();
    }

    /// Marks the single teardown as claimed. Every caller below has already
    /// established that no teardown happened, so claiming it cannot fail;
    /// `teardown` keeps the `error.DoubleTeardown` report for callers that do
    /// not know that.
    /// This does NOT set `state`: a dismissal has already recorded WHY the
    /// popup ended, and overwriting that with a bare `closed` would discard
    /// the only record of whether the client, the compositor or the parent
    /// closed it.
    fn claimTeardown(self: *NativePopup) void {
        self.teardown_performed = true;
        self.has_grab = false;
        self.pending_grab_serial = null;
        // A dismissal settles an approved grab that never went out as surely as
        // it settles one that did, so no later call can report the popup as
        // still waiting to issue a grab nobody is going to send.
        self.grab_pending = false;
    }

    /// Teardown native surface resources safely. Prevents double teardown.
    /// A teardown with no dismissal behind it is the only path that reports
    /// `closed`.
    pub fn teardown(self: *NativePopup) PopupError!void {
        if (self.teardown_performed) {
            return error.DoubleTeardown;
        }
        self.state = .closed;
        self.claimTeardown();
    }

    pub fn deinit(self: *NativePopup) void {
        if (!self.teardown_performed) {
            self.state = .closed;
            self.claimTeardown();
        }
        self.* = undefined;
    }

    /// True when the compositor's placement differs from this tree's solution.
    /// A divergence is reported, never resolved locally: on the xdg-shell path
    /// the compositor owns the placement.
    pub fn placementDiverges(self: *const NativePopup) bool {
        const configure = self.configure orelse return false;
        if (configure.width <= 0 or configure.height <= 0) return false;
        return configure.width != @as(i32, @intCast(self.mapped_size.width)) or
            configure.height != @as(i32, @intCast(self.mapped_size.height));
    }
};

/// The SDL3 property names and call names the popup adapter reads and issues.
/// Every one is a documented SDL entry point, so a native handle reaches this
/// tree through a supported integration rather than a raw graphics handle.
pub const SdlPopupSeam = struct {
    pub const prop_parent_pointer = "SDL.window.create.parent";
    pub const prop_tooltip_boolean = "SDL.window.create.tooltip";
    pub const prop_menu_boolean = "SDL.window.create.menu";
    /// `SDL_PROP_WINDOW_CREATE_WAYLAND_SURFACE_ROLE_CUSTOM`: the window keeps a
    /// `wl_surface` with no role, which is the only state a client may assign a
    /// role of its own to.
    pub const prop_wayland_surface_role_custom = "SDL.window.create.wayland.surface_role_custom";
    pub const prop_wayland_display = "SDL.window.wayland.display";
    pub const prop_wayland_surface = "SDL.window.wayland.surface";
    pub const prop_wayland_xdg_surface = "SDL.window.wayland.xdg_surface";
    pub const prop_wayland_xdg_toplevel = "SDL.window.wayland.xdg_toplevel";
    pub const prop_wayland_xdg_popup = "SDL.window.wayland.xdg_popup";
    pub const prop_wayland_xdg_positioner = "SDL.window.wayland.xdg_positioner";
    pub const prop_x11_window = "SDL.window.x11.window";
    pub const prop_x11_display = "SDL.window.x11.display";
    /// `SDL_CreatePopupWindow`, the only SDL call that creates an OS popup.
    pub const fn_create_popup_window = "SDL_CreatePopupWindow";
    /// `SDL_Vulkan_CreateSurface`, the only SDL call that creates a platform
    /// Vulkan surface. It reads the window's own native display and surface
    /// properties, so it attaches to whatever role the surface already carries.
    pub const fn_vulkan_create_surface = "SDL_Vulkan_CreateSurface";
};
