//! Wayland layer-shell protocol adapter (zwlr_layer_shell_v1).
//! Provides desktop surface roles: panels, docks, lockscreens, and overlays.
//! Uses SDL3 custom surface role seam. Never fakes an ordinary toplevel as layer surface.

pub const Layer = enum(u32) {
    background = 0,
    bottom = 1,
    top = 2,
    overlay = 3,
};

pub const Anchor = packed struct(u32) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _reserved: u28 = 0,

    pub const none: Anchor = .{};
    pub const all: Anchor = .{ .top = true, .bottom = true, .left = true, .right = true };
    pub const top_dock: Anchor = .{ .top = true, .left = true, .right = true };
    pub const bottom_dock: Anchor = .{ .bottom = true, .left = true, .right = true };
    pub const left_dock: Anchor = .{ .left = true, .top = true, .bottom = true };
    pub const right_dock: Anchor = .{ .right = true, .top = true, .bottom = true };

    /// How many of the four edges are anchored.
    pub fn anchoredEdges(self: Anchor) u32 {
        return @as(u32, @intFromBool(self.top)) +
            @as(u32, @intFromBool(self.bottom)) +
            @as(u32, @intFromBool(self.left)) +
            @as(u32, @intFromBool(self.right));
    }

    /// True when a positive exclusive zone is meaningful for this anchor set.
    ///
    /// `wlr-layer-shell-unstable-v1.xml` line 158: a positive value is only
    /// meaningful if the surface is anchored to one edge, or to an edge and both
    /// perpendicular edges. A surface anchored to no edge, to only two
    /// perpendicular edges, to only two parallel edges, or to all four, has its
    /// positive value treated the same as zero, so a caller reserving space with
    /// such an anchor set asks for a reservation the compositor will not make.
    pub fn reservesExclusiveZone(self: Anchor) bool {
        const count = self.anchoredEdges();
        return count == 1 or count == 3;
    }

    /// The exclusive zone the compositor will actually reserve for this anchor
    /// set. A positive zone these anchors cannot express reads as zero; a
    /// negative zone is a request to ignore other reservations and is passed
    /// through whatever the anchors are.
    pub fn effectiveExclusiveZone(self: Anchor, zone: i32) i32 {
        if (zone > 0 and !self.reservesExclusiveZone()) return 0;
        return zone;
    }
};

pub const Margins = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
};

pub const KeyboardInteractivity = enum(u32) {
    none = 0,
    exclusive = 1,
    on_demand = 2,
};

pub const InputRect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// What part of a surface accepts pointer and touch input.
pub const InputRegionMode = enum(u8) {
    /// No region was ever set, so the compositor's initial value applies: the
    /// whole surface accepts input.
    inherit = 0,
    /// An empty `wl_region`: the surface accepts no input at all, so pointer and
    /// touch events pass through to whatever is below it.
    passthrough = 1,
    /// Only the listed rectangles accept input.
    rects = 2,
};

pub const InputRegion = struct {
    mode: InputRegionMode = .inherit,
    rects: [8]InputRect = [_]InputRect{.{ .x = 0, .y = 0, .width = 0, .height = 0 }} ** 8,
    count: u32 = 0,

    /// Take no input, so the surface is transparent to the pointer.
    pub fn setPassthrough(self: *InputRegion) void {
        self.mode = .passthrough;
        self.count = 0;
    }

    /// Go back to the compositor's default, which accepts input everywhere.
    pub fn inherit(self: *InputRegion) void {
        self.mode = .inherit;
        self.count = 0;
    }

    /// Accept input inside `rect` only. The first rectangle added leaves
    /// passthrough, because a region with rectangles in it is not empty.
    pub fn addRect(self: *InputRegion, rect: InputRect) void {
        if (self.count >= self.rects.len) return;
        self.rects[self.count] = rect;
        self.count += 1;
        self.mode = .rects;
    }

    /// The requests this region turns into.
    ///
    /// The rectangles are a view of this receiver, never a copy of them, so
    /// the receiver has to outlive the plan that reads it. A region built in a
    /// temporary hands its plan a view of that temporary: the region a plan
    /// is read from after the call is the one that stays alive, which for a
    /// surface is the copy it keeps in its own options.
    pub fn plan(self: *const InputRegion) InputRegionPlan {
        return switch (self.mode) {
            // Nothing to send: the compositor's initial value already accepts
            // input over the whole surface.
            .inherit => .{ .send_region = false, .rects = &.{} },
            // A region with no rectangles. This is not the same as sending no
            // region: a null region means "accept input everywhere", so
            // click-through needs an empty one.
            .passthrough => .{ .send_region = true, .rects = &.{} },
            .rects => .{
                .send_region = true,
                .rects = self.rects[0..self.count],
            },
        };
    }
};

/// What an input region puts on the wire.
pub const InputRegionPlan = struct {
    /// Whether a `wl_region` is created and set. When this is false the
    /// compositor's default stands.
    send_region: bool,
    /// The rectangles that region carries. An empty list with `send_region` set
    /// is the click-through case; a false `send_region` means every pixel.
    rects: []const InputRect,
};

pub const LayerShellOptions = struct {
    layer: Layer = .top,
    anchor: Anchor = Anchor.top_dock,
    margins: Margins = .{},
    exclusive_zone: i32 = 0,
    keyboard_interactivity: KeyboardInteractivity = .none,
    input_region: InputRegion = .{},
    namespace: [:0]const u8 = "nogui-layer",
    desired_width: u32 = 0,
    desired_height: u32 = 0,
};

pub const SurfaceState = enum(u8) {
    uninitialized = 0,
    attached = 1,
    configured = 2,
    mapped = 3,
    closed = 4,
    destroyed = 5,
};

pub const CompositorCapability = enum(u8) {
    supported = 0,
    unavailable = 1,
};

pub const LayerShellError = error{
    LayerShellUnsupported,
    InvalidDimensions,
    ProtocolViolation,
    DoubleTeardown,
    AlreadyDestroyed,
    OutputDisconnected,
    UnacknowledgedConfigure,
};

/// Native layer surface managing zwlr_layer_surface_v1 protocol lifecycle.
pub const LayerSurface = struct {
    state: SurfaceState = .uninitialized,
    options: LayerShellOptions,
    current_width: u32 = 0,
    current_height: u32 = 0,
    last_configured_serial: ?u32 = null,
    last_acked_serial: ?u32 = null,
    configured_count: u32 = 0,
    acked_count: u32 = 0,
    committed_count: u32 = 0,
    output_attached: bool = true,
    /// The mode the compositor last reported for the output this surface is on.
    /// A layer surface that spans an edge follows that edge, so an output change
    /// is what decides the width a full-width panel will be given.
    output_width: u32 = 0,
    output_height: u32 = 0,
    /// How many `wl_output.done` batches have been applied.
    output_change_count: u32 = 0,
    teardown_performed: bool = false,

    /// Initialize layer surface. If the compositor does not advertise zwlr_layer_shell_v1,
    /// returns LayerShellUnsupported. Never labels an ordinary toplevel as layer surface.
    pub fn init(
        options: LayerShellOptions,
        capability: CompositorCapability,
    ) LayerShellError!LayerSurface {
        if (capability == .unavailable) {
            return error.LayerShellUnsupported;
        }

        return .{
            .state = .attached,
            .options = options,
            .current_width = options.desired_width,
            .current_height = options.desired_height,
            .last_configured_serial = null,
            .last_acked_serial = null,
            .configured_count = 0,
            .acked_count = 0,
            .committed_count = 0,
            .output_attached = true,
            .output_width = 0,
            .output_height = 0,
            .output_change_count = 0,
            .teardown_performed = false,
        };
    }

    /// The exclusive zone the compositor will actually reserve, which is not
    /// always the one that was asked for: a positive zone the anchor set cannot
    /// express is treated as zero.
    pub fn reservedZone(self: *const LayerSurface) i32 {
        return self.options.anchor.effectiveExclusiveZone(self.options.exclusive_zone);
    }

    /// What the input region puts on the wire for the current options.
    ///
    /// The plan's rectangles are a view of `options.input_region`, so they
    /// stay readable for as long as this surface does, and they are the very
    /// rectangles a request marshalled now would carry.
    pub fn inputRegionPlan(self: *const LayerSurface) InputRegionPlan {
        return self.options.input_region.plan();
    }

    /// Process zwlr_layer_surface_v1.configure event from compositor.
    pub fn handleConfigure(
        self: *LayerSurface,
        serial: u32,
        width: u32,
        height: u32,
    ) LayerShellError!void {
        if (self.state == .destroyed or self.state == .closed) return error.AlreadyDestroyed;
        if (self.state != .attached and self.state != .configured and self.state != .mapped) {
            return error.ProtocolViolation;
        }

        // A new configure invalidates permission to commit until it is acked.
        self.last_acked_serial = null;
        self.last_configured_serial = serial;
        self.configured_count += 1;
        if (width > 0) {
            self.current_width = width;
        } else if (self.current_width == 0) {
            self.current_width = self.options.desired_width;
        }
        if (height > 0) {
            self.current_height = height;
        } else if (self.current_height == 0) {
            self.current_height = self.options.desired_height;
        }
        self.state = .configured;
    }

    /// Acknowledge compositor configure before committing a buffer.
    pub fn ackConfigure(self: *LayerSurface) LayerShellError!void {
        if (self.state == .destroyed or self.state == .closed) {
            return error.AlreadyDestroyed;
        }
        const serial = self.last_configured_serial orelse return error.UnacknowledgedConfigure;
        if (self.last_acked_serial != null) return error.UnacknowledgedConfigure;
        self.last_acked_serial = serial;
        self.acked_count += 1;
        self.state = .mapped;
    }

    /// Commit layer surface after rendering.
    pub fn commit(self: *LayerSurface) LayerShellError!void {
        if (self.state == .destroyed or self.state == .closed) return error.AlreadyDestroyed;
        if (self.last_configured_serial == null) return error.ProtocolViolation;
        if (self.state != .mapped or self.last_acked_serial == null) {
            return error.UnacknowledgedConfigure;
        }
        self.committed_count += 1;
    }

    /// Process zwlr_layer_surface_v1.closed event from compositor.
    pub fn handleClosed(self: *LayerSurface) void {
        if (self.state == .destroyed or self.state == .closed) return;
        self.state = .closed;
        self.claimTeardown();
    }

    /// Apply a `wl_output` geometry batch: the mode the compositor reports for
    /// the output this surface is on.
    ///
    /// A surface anchored to a single edge follows that edge, so a new mode
    /// changes its size. The surface returns to `attached` because the new size
    /// only takes effect at the next commit, and the compositor answers that
    /// commit with a fresh configure to acknowledge.
    pub fn handleOutputChanged(
        self: *LayerSurface,
        new_output_width: u32,
        new_output_height: u32,
    ) LayerShellError!void {
        if (self.state == .destroyed or self.state == .closed) {
            return error.AlreadyDestroyed;
        }
        if (new_output_width == 0 or new_output_height == 0) {
            return error.InvalidDimensions;
        }

        self.output_width = new_output_width;
        self.output_height = new_output_height;
        self.output_change_count += 1;

        // Recompute dimensions when the anchors span the whole axis.
        if (self.options.anchor.left and self.options.anchor.right) {
            self.current_width = new_output_width;
        }
        if (self.options.anchor.top and self.options.anchor.bottom) {
            self.current_height = new_output_height;
        }

        self.state = .attached;
    }

    /// Handle removal of the output displaying this surface.
    pub fn handleOutputDisconnected(self: *LayerSurface) void {
        self.output_attached = false;
        if (self.state == .destroyed or self.state == .closed) return;
        self.state = .closed;
        self.claimTeardown();
    }

    pub fn setExclusiveZone(self: *LayerSurface, zone: i32) void {
        self.options.exclusive_zone = zone;
    }

    pub fn setAnchor(self: *LayerSurface, anchor: Anchor) void {
        self.options.anchor = anchor;
    }

    pub fn setMargins(self: *LayerSurface, margins: Margins) void {
        self.options.margins = margins;
    }

    pub fn setKeyboardInteractivity(
        self: *LayerSurface,
        interactivity: KeyboardInteractivity,
    ) void {
        self.options.keyboard_interactivity = interactivity;
    }

    pub fn setInputRegion(self: *LayerSurface, region: InputRegion) void {
        self.options.input_region = region;
    }

    /// Marks the single teardown as claimed. Every caller below has already
    /// established that no teardown happened, so claiming it cannot fail;
    /// `teardown` keeps the `error.DoubleTeardown` report for callers that do
    /// not know that.
    fn claimTeardown(self: *LayerSurface) void {
        self.teardown_performed = true;
        self.state = .destroyed;
    }

    /// Teardown surface resources safely. Prevents double surface teardown.
    pub fn teardown(self: *LayerSurface) LayerShellError!void {
        if (self.teardown_performed) {
            return error.DoubleTeardown;
        }
        self.claimTeardown();
    }

    pub fn deinit(self: *LayerSurface) void {
        if (!self.teardown_performed) {
            self.claimTeardown();
        }
        self.* = undefined;
    }
};

/// Pure property descriptor for SDL3 custom surface seam.
pub const SdlLayerShellSeam = struct {
    pub const prop_wayland_surface_role_custom = "SDL.window.create.wayland.surface_role_custom";
    pub const prop_wayland_display = "SDL.window.wayland.display";
    pub const prop_wayland_surface = "SDL.window.wayland.surface";
    pub const prop_wayland_viewport = "SDL.window.wayland.viewport";
};
