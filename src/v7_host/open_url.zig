//! URL ingress, launch queue dispatch-once, scheme registration, and file-drop phases.
//! Integrates directly with Application host launch hooks without duplicating queues.
//! External URL launches require explicit point-of-risk confirmation.
const std = @import("std");
const sdl3 = @import("sdl3");
const builtin = @import("builtin");
const c = sdl3.c;
const portal = @import("linux/portal.zig");

/// Mirrored from application.zig for independent consumption.
pub const IncomingLaunch = struct {
    kind: enum { file, text },
    value: []const u8,
};

/// Explicit point-of-risk gate for launching external URLs or system applications.
pub const PointOfRiskApproval = struct {
    confirmed: bool = false,
};

pub const OpenOutcome = enum {
    opened,
    rejected,
    unsupported,
    failed,
};

/// Pluggable provider for launching external URLs.
/// Default implementation uses actual SDL3 / Linux portal.
pub const OpenUrlProvider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        openUrl: *const fn (ctx: *anyopaque, url: []const u8) anyerror!OpenOutcome,
    };

    pub fn openUrl(self: OpenUrlProvider, url: []const u8) !OpenOutcome {
        return self.vtable.openUrl(self.context, url);
    }
};

/// What a portal request reported, in the outcomes a caller of `openExternal`
/// already has. A user who dismissed the request refused a launch, which is
/// neither a launch that happened nor a provider that failed, and a host with
/// no portal at all is not a refusal.
fn portalOutcome(decision: portal.OpenDecision) OpenOutcome {
    return switch (decision) {
        .opened => .opened,
        .cancelled => .rejected,
        .failed => .failed,
    };
}

/// Validates whether a string constitutes a syntactic URL with a scheme.
/// RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
pub fn isValidUrl(raw: []const u8) bool {
    const colon_idx = std.mem.indexOfScalar(u8, raw, ':') orelse return false;
    if (colon_idx == 0) return false;
    const scheme = raw[0..colon_idx];
    if (!std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '+' or char == '-' or char == '.') continue;
        return false;
    }
    // Must have content after the scheme
    const rest = raw[colon_idx + 1 ..];
    return rest.len > 0;
}

/// Extract the scheme portion from a URL (e.g. "https" from "https://example.com").
pub fn extractScheme(raw: []const u8) ?[]const u8 {
    const colon_idx = std.mem.indexOfScalar(u8, raw, ':') orelse return null;
    if (colon_idx == 0) return null;
    const scheme = raw[0..colon_idx];
    if (!std.ascii.isAlphabetic(scheme[0])) return null;
    for (scheme[1..]) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '+' or char == '-' or char == '.') continue;
        return null;
    }
    return scheme;
}

/// Registry of known URL schemes handled by this application.
pub const SchemeRegistry = struct {
    allocator: std.mem.Allocator,
    schemes: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !SchemeRegistry {
        var self: SchemeRegistry = .{ .allocator = allocator };
        errdefer self.deinit();
        // Pre-register standard URL schemes.
        try self.register("http");
        try self.register("https");
        try self.register("file");
        try self.register("mailto");
        return self;
    }

    pub fn deinit(self: *SchemeRegistry) void {
        for (self.schemes.items) |s| {
            self.allocator.free(s);
        }
        self.schemes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *SchemeRegistry, scheme: []const u8) !void {
        if (self.isRegistered(scheme)) return;
        const copy = try self.allocator.dupe(u8, scheme);
        errdefer self.allocator.free(copy);
        try self.schemes.append(self.allocator, copy);
    }

    pub fn isRegistered(self: *const SchemeRegistry, scheme: []const u8) bool {
        for (self.schemes.items) |s| {
            if (std.ascii.eqlIgnoreCase(s, scheme)) return true;
        }
        return false;
    }
};

pub const UrlHandler = struct {
    context: ?*anyopaque = null,
    handler: *const fn (?*anyopaque, []const u8) void,
};

/// Dispatches incoming launch URLs once to registered scheme handlers.
/// Interoperates directly with Application's incoming launch mechanism.
pub const UrlDispatcher = struct {
    allocator: std.mem.Allocator,
    registry: SchemeRegistry,
    handlers: std.StringHashMapUnmanaged(UrlHandler) = .empty,
    default_handler: ?UrlHandler = null,
    provider: ?OpenUrlProvider = null,
    dispatched_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !UrlDispatcher {
        return .{
            .allocator = allocator,
            .registry = try SchemeRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *UrlDispatcher) void {
        var iter = self.handlers.keyIterator();
        while (iter.next()) |k| {
            self.allocator.free(k.*);
        }
        self.handlers.deinit(self.allocator);
        self.registry.deinit();
        self.* = undefined;
    }

    pub fn setProvider(self: *UrlDispatcher, provider: ?OpenUrlProvider) void {
        self.provider = provider;
    }

    /// The handler a scheme dispatches to right now, or null when none does.
    /// Schemes are matched the way `SchemeRegistry` matches them, so a name is
    /// one scheme however it was spelled.
    fn activeHandler(self: *const UrlDispatcher, scheme: []const u8) ?*UrlHandler {
        var iter = self.handlers.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, scheme)) return entry.value_ptr;
        }
        return null;
    }

    pub fn registerSchemeHandler(self: *UrlDispatcher, scheme: []const u8, handler: UrlHandler) !void {
        try self.registry.register(scheme);
        // Registering a scheme again replaces the handler that is active. The
        // key already in the table stays: it is the name dispatch finds, and
        // duplicating it would leave the replaced handler's name in the table
        // beside the one that replaced it, with nothing to release it.
        if (self.activeHandler(scheme)) |active| {
            active.* = handler;
            return;
        }
        const copy = try self.allocator.dupe(u8, scheme);
        errdefer self.allocator.free(copy);
        try self.handlers.put(self.allocator, copy, handler);
    }

    pub fn setDefaultHandler(self: *UrlDispatcher, handler: ?UrlHandler) void {
        self.default_handler = handler;
    }

    /// Process an incoming launch payload. Returns true if the payload was recognized
    /// and dispatched as a URL; false if it was ordinary text/file for normal app handling.
    /// Ensures "launch URL delivery occurs once".
    pub fn handleLaunch(self: *UrlDispatcher, launch: IncomingLaunch) bool {
        if (launch.kind != .text) return false;
        if (!isValidUrl(launch.value)) return false;

        const scheme = extractScheme(launch.value) orelse return false;

        // Find registered handler or default handler
        var target_handler: ?UrlHandler = null;
        if (self.activeHandler(scheme)) |active| {
            target_handler = active.*;
        } else {
            target_handler = self.default_handler;
        }

        if (target_handler) |h| {
            self.dispatched_count +%= 1;
            h.handler(h.context, launch.value);
            return true;
        }

        return false;
    }

    /// Open an external URL via the configured provider or default SDL3/portal.
    /// Requires explicit PointOfRiskApproval.
    pub fn openExternal(
        self: *UrlDispatcher,
        url: []const u8,
        approval: PointOfRiskApproval,
    ) !OpenOutcome {
        if (!approval.confirmed) return error.ActionNotApproved;
        if (!isValidUrl(url)) return error.InvalidUrl;

        if (self.provider) |p| {
            return p.openUrl(url);
        }

        // The desktop portal is the sandboxed path; use it when it answers and
        // say so, rather than silently falling through to a second launch.
        if (comptime builtin.os.tag == .linux and !builtin.abi.isAndroid()) {
            if (portal.isSessionBusAvailable()) {
                const decision = portal.openUri(self.allocator, url, "") catch |err| switch (err) {
                    error.NoSessionBus, error.PortalUnavailable => return .unsupported,
                    else => return .failed,
                };
                return portalOutcome(decision);
            }
        }

        const url_z = try self.allocator.dupeZ(u8, url);
        defer self.allocator.free(url_z);
        return if (c.SDL_OpenURL(url_z.ptr)) .opened else .failed;
    }
};

/// Bridge adapter between UrlDispatcher and Application's on_incoming_launch hook.
/// Parent can install this in Application.hooks with zero code duplication.
pub const LaunchHookAdapter = struct {
    dispatcher: *UrlDispatcher,
    user_context: ?*anyopaque = null,
    user_launch_fn: ?*const fn (?*anyopaque, IncomingLaunch) void = null,

    pub fn onIncomingLaunch(raw: *anyopaque, app: *anyopaque, launch: IncomingLaunch) void {
        _ = app;
        const self: *LaunchHookAdapter = @ptrCast(@alignCast(raw));
        if (self.dispatcher.handleLaunch(launch)) {
            return; // URL handled and consumed
        }
        // Not a URL, forward to normal user launch handler
        if (self.user_launch_fn) |cb| {
            cb(self.user_context, launch);
        }
    }
};

/// Drag and drop lifecycle phases for native file/text ingress.
pub const DropPhase = enum {
    begin,
    position,
    offer,
    complete,
};

pub const DropOfferKind = enum {
    file,
    text,
    url,
};

pub const DropOffer = struct {
    kind: DropOfferKind,
    value: []const u8,
};

pub const DropPhaseEvent = struct {
    phase: DropPhase,
    window_id: ?sdl3.video.WindowId = null,
    position: ?[2]f32 = null,
    offer: ?DropOffer = null,
};

pub const DropPhaseCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, DropPhaseEvent) void,
};

/// State machine tracking incoming native drag-and-drop phases across SDL events.
pub const DropPhaseTracker = struct {
    active_window: ?sdl3.video.WindowId = null,
    last_position: ?[2]f32 = null,
    in_progress: bool = false,
    callback: ?DropPhaseCallback = null,

    pub fn init() DropPhaseTracker {
        return .{};
    }

    pub fn setCallback(self: *DropPhaseTracker, callback: ?DropPhaseCallback) void {
        self.callback = callback;
    }

    /// Forget the drag in flight. A host calls this when the window a drag
    /// belongs to dies, so no later phase is measured against a window this
    /// host no longer owns.
    pub fn clear(self: *DropPhaseTracker) void {
        self.active_window = null;
        self.last_position = null;
        self.in_progress = false;
    }

    /// The phase one SDL event names, with the tracker state advanced for it.
    /// `null` when the event is not a drop phase at all. State is advanced
    /// before the phase is returned, so a consumer reading this tracker from
    /// a callback already sees the phase it was told about.
    pub fn translate(self: *DropPhaseTracker, raw: *const sdl3.events.Event) ?DropPhaseEvent {
        switch (raw.*) {
            .drop_begin => |val| {
                self.active_window = val.window;
                self.last_position = null;
                self.in_progress = true;
                return .{ .phase = .begin, .window_id = val.window };
            },
            .drop_position => |val| {
                self.last_position = .{ val.x, val.y };
                return .{
                    .phase = .position,
                    .window_id = val.window,
                    .position = .{ val.x, val.y },
                };
            },
            .drop_file => |val| {
                return .{
                    .phase = .offer,
                    .window_id = val.window,
                    .position = .{ val.x, val.y },
                    .offer = .{
                        .kind = if (isValidUrl(val.file_name)) .url else .file,
                        .value = val.file_name,
                    },
                };
            },
            .drop_text => |val| {
                return .{
                    .phase = .offer,
                    .window_id = val.window,
                    .position = .{ val.x, val.y },
                    .offer = .{
                        .kind = if (isValidUrl(val.text)) .url else .text,
                        .value = val.text,
                    },
                };
            },
            .drop_complete => |val| {
                self.in_progress = false;
                self.active_window = null;
                self.last_position = null;
                return .{
                    .phase = .complete,
                    .window_id = val.window,
                    .position = .{ val.x, val.y },
                };
            },
            else => return null,
        }
    }

    /// Process SDL drop events and translate into ordered drag-drop lifecycle phases.
    pub fn handleEvent(self: *DropPhaseTracker, raw: *const sdl3.events.Event) bool {
        const cb = self.callback orelse return false;
        const phase = self.translate(raw) orelse return false;
        cb.callback(cb.context, phase);
        return true;
    }
};

test "url validation and scheme extraction" {
    try std.testing.expect(isValidUrl("https://example.com/path"));
    try std.testing.expect(isValidUrl("http://localhost:8080"));
    try std.testing.expect(isValidUrl("file:///home/user/test.zig"));
    try std.testing.expect(isValidUrl("mailto:user@example.com"));
    try std.testing.expect(isValidUrl("nogui://action/open?file=foo"));

    try std.testing.expect(!isValidUrl(""));
    try std.testing.expect(!isValidUrl("not a url"));
    try std.testing.expect(!isValidUrl("/local/path/only"));
    try std.testing.expect(!isValidUrl("123badscheme://test"));
    try std.testing.expect(!isValidUrl(":badcolon"));

    try std.testing.expectEqualStrings("https", extractScheme("https://example.com").?);
    try std.testing.expectEqualStrings("nogui", extractScheme("nogui://open").?);
    try std.testing.expect(extractScheme("/no/scheme") == null);
}

test "url dispatcher routes to scheme handler and delivers once" {
    var dispatcher = try UrlDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    const HandlerState = struct {
        const Self = @This();

        calls: usize = 0,
        // Only the first `last_len` bytes are live, so zeroing the tail is
        // enough for a handler that never ran.
        last_url: [64]u8 = [_]u8{0} ** 64,
        last_len: usize = 0,

        fn handle(ctx: ?*anyopaque, url: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.last_len = url.len;
            @memcpy(self.last_url[0..url.len], url);
        }
    };

    var custom_state: HandlerState = .{};
    var default_state: HandlerState = .{};

    try dispatcher.registerSchemeHandler("nogui", .{
        .context = &custom_state,
        .handler = HandlerState.handle,
    });
    dispatcher.setDefaultHandler(.{
        .context = &default_state,
        .handler = HandlerState.handle,
    });

    // 1. Non-URL launch returns false and is not consumed
    const file_launch: IncomingLaunch = .{ .kind = .file, .value = "/tmp/demo.txt" };
    try std.testing.expect(!dispatcher.handleLaunch(file_launch));
    try std.testing.expectEqual(@as(usize, 0), custom_state.calls);
    try std.testing.expectEqual(@as(usize, 0), default_state.calls);

    // 2. Custom scheme launch routes to custom handler
    const custom_url = "nogui://editor/jump?line=42";
    const custom_launch: IncomingLaunch = .{ .kind = .text, .value = custom_url };
    try std.testing.expect(dispatcher.handleLaunch(custom_launch));
    try std.testing.expectEqual(@as(usize, 1), custom_state.calls);
    try std.testing.expectEqualStrings(custom_url, custom_state.last_url[0..custom_state.last_len]);
    try std.testing.expectEqual(@as(usize, 0), default_state.calls);

    // 3. Standard scheme routes to default handler
    const http_url = "https://zed.dev";
    const http_launch: IncomingLaunch = .{ .kind = .text, .value = http_url };
    try std.testing.expect(dispatcher.handleLaunch(http_launch));
    try std.testing.expectEqual(@as(usize, 1), custom_state.calls);
    try std.testing.expectEqual(@as(usize, 1), default_state.calls);
    try std.testing.expectEqualStrings(http_url, default_state.last_url[0..default_state.last_len]);
}

test "open external url requires point of risk confirmation" {
    var dispatcher = try UrlDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    const MockLaunchProvider = struct {
        const Self = @This();

        calls: usize = 0,
        fn open(ctx: *anyopaque, _: []const u8) anyerror!OpenOutcome {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return .opened;
        }
    };
    var mock: MockLaunchProvider = .{};
    const vtable: OpenUrlProvider.VTable = .{ .openUrl = MockLaunchProvider.open };
    dispatcher.setProvider(.{ .context = &mock, .vtable = &vtable });

    // Unconfirmed MUST fail
    const unconfirmed: PointOfRiskApproval = .{ .confirmed = false };
    try std.testing.expectError(
        error.ActionNotApproved,
        dispatcher.openExternal("https://example.com", unconfirmed),
    );
    try std.testing.expectEqual(@as(usize, 0), mock.calls);

    // Confirmed succeeds
    const confirmed: PointOfRiskApproval = .{ .confirmed = true };
    const outcome = try dispatcher.openExternal("https://example.com", confirmed);
    try std.testing.expectEqual(OpenOutcome.opened, outcome);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

test "api-w18 a scheme handler registered twice replaces the active one" {
    var dispatcher = try UrlDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    const Seen = struct {
        const Self = @This();

        calls: usize = 0,
        // Only the first `url_len` bytes are live, so zeroing the tail is
        // enough for a handler that never ran.
        url: [64]u8 = [_]u8{0} ** 64,
        url_len: usize = 0,

        fn handle(ctx: ?*anyopaque, url: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.url_len = url.len;
            @memcpy(self.url[0..url.len], url);
        }
    };

    var first: Seen = .{};
    var second: Seen = .{};

    try dispatcher.registerSchemeHandler("nogui", .{
        .context = &first,
        .handler = Seen.handle,
    });
    // A scheme is one name however it is spelled, so registering it again
    // replaces the handler that is active instead of sitting beside it.
    try dispatcher.registerSchemeHandler("NoGui", .{
        .context = &second,
        .handler = Seen.handle,
    });

    const url = "nogui://editor/jump";
    try std.testing.expect(dispatcher.handleLaunch(.{ .kind = .text, .value = url }));
    try std.testing.expectEqual(@as(usize, 0), first.calls);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    try std.testing.expectEqualStrings(url, second.url[0..second.url_len]);
    // One entry for the scheme: a registration that kept a second copy of its
    // own name would leave the replaced one in the table beside it.
    try std.testing.expectEqual(@as(usize, 1), dispatcher.handlers.count());
    // The launch is delivered once, to the handler that is active.
    try std.testing.expectEqual(@as(usize, 1), dispatcher.dispatched_count);
}

test "api-w18 a dismissed portal request is a refusal, not a launch or a failure" {
    // The portal reports three answers a caller has to keep apart: the URI went
    // to an application, the user dismissed the request, or the request failed.
    // Reporting a dismissal as a launch invents one, and reporting it as a
    // failure blames a provider that answered.
    try std.testing.expectEqual(OpenOutcome.opened, portalOutcome(.opened));
    try std.testing.expectEqual(OpenOutcome.rejected, portalOutcome(.cancelled));
    try std.testing.expectEqual(OpenOutcome.failed, portalOutcome(.failed));
}

test "drop phase tracker sequences begin position offer and complete" {
    var tracker = DropPhaseTracker.init();

    const DropRecord = struct {
        const Self = @This();

        events: usize = 0,
        // Only the first `events` slots are live, so `.begin` is just a
        // placeholder for the phases that never arrived.
        phases: [8]DropPhase = [_]DropPhase{.begin} ** 8,

        fn onDrop(ctx: ?*anyopaque, event: DropPhaseEvent) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.events < self.phases.len) {
                self.phases[self.events] = event.phase;
                self.events += 1;
            }
        }
    };
    var rec: DropRecord = .{};
    tracker.setCallback(.{ .context = &rec, .callback = DropRecord.onDrop });

    var begin_ev: sdl3.events.Event = .{ .drop_begin = .{
        .common = .{ .timestamp = 0 },
        .window = 1,
        .source = null,
    } };
    var pos_ev: sdl3.events.Event = .{ .drop_position = .{
        .common = .{ .timestamp = 1 },
        .window = 1,
        .source = null,
        .x = 15,
        .y = 25,
    } };
    var file_ev: sdl3.events.Event = .{ .drop_file = .{
        .common = .{ .timestamp = 2 },
        .window = 1,
        .x = 15,
        .y = 25,
        .source = null,
        .file_name = "/tmp/test.txt",
    } };
    var complete_ev: sdl3.events.Event = .{ .drop_complete = .{
        .common = .{ .timestamp = 3 },
        .window = 1,
        .x = 15,
        .y = 25,
        .source = null,
    } };

    try std.testing.expect(tracker.handleEvent(&begin_ev));
    try std.testing.expect(tracker.handleEvent(&pos_ev));
    try std.testing.expect(tracker.handleEvent(&file_ev));
    try std.testing.expect(tracker.handleEvent(&complete_ev));

    try std.testing.expectEqual(@as(usize, 4), rec.events);
    try std.testing.expectEqual(DropPhase.begin, rec.phases[0]);
    try std.testing.expectEqual(DropPhase.position, rec.phases[1]);
    try std.testing.expectEqual(DropPhase.offer, rec.phases[2]);
    try std.testing.expectEqual(DropPhase.complete, rec.phases[3]);
}
