//! E01: macOS Services.
//!
//! Two directions, both real:
//!
//!   * OUTBOUND. The Services menu belongs to the system: AppKit fills it from
//!     the `NSServices` array in the bundle's Info.plist, and a host cannot
//!     add items to it. What a host can do is read what is there, name the
//!     items, and send one. `invoke` does exactly that, through the same
//!     `sendAction:to:from:` a menu click uses, so the service sees the same
//!     responder chain a person's click would give it.
//!   * INBOUND. When another application sends this one a service, AppKit asks
//!     the first responder to perform it. `registerProvider` tells the system
//!     which uniform types this application accepts and returns, and the
//!     responder the host already keeps (see `text.zig`) receives the request
//!     and routes it into the host's own action path.
//!
//! The Info.plist dependency is a real prerequisite, not a detail: an
//! unbundled process has no `NSServices` array, so its Services menu is empty
//! and `menu` reports zero rather than pretending otherwise.
const std = @import("std");
const native = @import("native.zig");
const text = @import("text.zig");

const Error = native.Error;
const Status = native.Status;
const shim = native.shim;

/// The Services menu has no item at that index. Distinct from a service whose
/// label happens to be empty, and from a process that has no Services menu.
pub const NoSuchService = error{NoSuchService};

/// What a read of the Services menu reports. `NoSuchService` is this module's
/// own answer about the menu's contents; everything else is a shim failure.
pub const MenuError = Error || NoSuchService;

/// What this application offers other applications.
pub const Provider = struct {
    /// Uniform type identifiers this application accepts, such as
    /// `public.utf8-plain-text`. An empty list registers nothing, which is the
    /// platform's own answer for "this application provides no service".
    send_types: []const []const u8 = &.{},
    /// Uniform type identifiers this application can return.
    return_types: []const []const u8 = &.{},
};

/// The Services menu the system published.
pub const Menu = struct {
    count: usize,

    pub fn isEmpty(self: Menu) bool {
        return self.count == 0;
    }
};

/// What happened when a service was sent.
pub const InvokeOutcome = enum {
    /// AppKit accepted the send. The service runs on its own schedule, so this
    /// is "the request was delivered", not "the service finished".
    delivered,
    /// AppKit was asked and declined: the item's target refused the action.
    declined,
    /// The menu item exists but names no action, so there is nothing to send.
    not_invocable,
    /// There is no menu, or no item at that index.
    no_such_service,
    /// This process has no Services menu at all, which is what an application
    /// without an `NSServices` Info.plist entry reports.
    unavailable,
};

/// Read the Services menu the system published for this application.
pub fn menu() Error!Menu {
    if (!native.available) return error.ShimUnavailable;
    // A positive return here is a COUNT, not a status code: `Status.of` maps
    // every non-zero value to a fault, which would turn a Services menu with
    // one item into an error. Only a negative value is a refusal.
    const count = shim.nogui_macos_services_menu_count();
    if (count < 0) return native.fail(Status.of(count));
    return .{ .count = @intCast(count) };
}

/// The label of one service. An out-of-range index is `NoSuchService` rather
/// than an empty label, so a caller cannot mistake "there is no such service"
/// for a service with a blank name.
pub fn menuLabel(gpa: std.mem.Allocator, index: usize) MenuError![]u8 {
    if (index > std.math.maxInt(i32)) return error.NoSuchService;
    const index_value: i32 = @intCast(index);
    return native.readString(gpa, .services_label, index_value, null) catch |err| switch (err) {
        error.BadArgument => error.NoSuchService,
        else => err,
    };
}

/// Send the service at `index` the way a click on it would.
///
/// The service runs against the window's first responder, so a host sends
/// after the window it wants the service to reach is key. The responder in
/// `text.zig` is what receives the result.
pub fn invoke(index: usize) Error!InvokeOutcome {
    if (!native.available) return error.ShimUnavailable;
    if (index > std.math.maxInt(i32)) return .no_such_service;
    const index_value: i32 = @intCast(index);
    // The shim answers 1 only from `sendAction:to:from:` returning yes, so
    // that one value is the whole of what "delivered" means here.
    return outcomeOf(shim.nogui_macos_services_invoke(index_value));
}

/// The outcome a shim answer names.
///
/// Split out from `invoke` because the mapping is the guarantee: exactly one
/// wire value means a send happened, and everything else is a decline, a
/// refusal to name an item, or a failure. Reading it in one place is what
/// keeps a value nobody defined from being reported as a delivery.
fn outcomeOf(raw: c_int) Error!InvokeOutcome {
    if (raw < 0) {
        return switch (Status.of(raw)) {
            .argument => .no_such_service,
            .refused => .not_invocable,
            .unavailable => .unavailable,
            else => |status| native.fail(status),
        };
    }
    return if (raw == 1) .delivered else .declined;
}

/// Tell the system which uniform types this application accepts and returns,
/// so another application can send it a service.
///
/// The request arrives on the responder's route, which the host installs with
/// `text.Responder.setServiceRoute`. Without a route every request is
/// declined, so registering a provider without a route is a configuration a
/// host can see rather than a silent black hole.
///
/// A responder that was never attached is refused before the platform is
/// asked. The name the system would register would belong to no view, and a
/// host that registered one anyway would have no way to tell that apart from
/// a registration the platform refused.
pub fn registerProvider(responder: *text.Responder, provider: Provider) Error!void {
    if (responder.handle == null) return error.Unsupported;
    if (comptime !native.available) return error.ShimUnavailable;
    var scratch = native.Scratch.init(std.heap.page_allocator);
    defer scratch.deinit();
    const alloc = scratch.arena.allocator();

    const sends = alloc.alloc([*:0]const u8, provider.send_types.len) catch return error.OutOfMemory;
    for (provider.send_types, 0..) |value, index| {
        sends[index] = (try scratch.nul(value)) orelse return error.BadArgument;
    }
    const returns = alloc.alloc([*:0]const u8, provider.return_types.len) catch return error.OutOfMemory;
    for (provider.return_types, 0..) |value, index| {
        returns[index] = (try scratch.nul(value)) orelse return error.BadArgument;
    }
    try native.check(Status.of(shim.nogui_macos_services_register(
        responder.handle,
        sends.ptr,
        sends.len,
        returns.ptr,
        returns.len,
    )));
}

test "api-w23 macos only the shim's own send is reported delivered" {
    // `sendAction:to:from:` answered yes, which is the one thing that means
    // the service was actually sent.
    try std.testing.expectEqual(InvokeOutcome.delivered, try outcomeOf(1));
    // The item's target refused the action.
    try std.testing.expectEqual(InvokeOutcome.declined, try outcomeOf(0));
    // A value the shim does not define is not a delivery. Reporting it as one
    // would tell a host a service ran when nothing was sent.
    try std.testing.expectEqual(InvokeOutcome.declined, try outcomeOf(2));
    try std.testing.expectEqual(InvokeOutcome.declined, try outcomeOf(99));
}

test "api-w23 macos a refusal to name a service is not a delivery" {
    // No item at that index.
    try std.testing.expectEqual(InvokeOutcome.no_such_service, try outcomeOf(-2));
    // The item exists but names no action.
    try std.testing.expectEqual(InvokeOutcome.not_invocable, try outcomeOf(-4));
    // This process has no Services menu at all.
    try std.testing.expectEqual(InvokeOutcome.unavailable, try outcomeOf(-5));
    // Every other failure stays a failure rather than being softened into an
    // outcome a caller would read as "the send happened".
    try std.testing.expectError(error.NotOnMainThread, outcomeOf(-1));
    try std.testing.expectError(error.BadArgument, outcomeOf(-3));
    try std.testing.expectError(error.PlatformFault, outcomeOf(-7));
    try std.testing.expectError(error.PlatformFault, outcomeOf(-1234));
}

test "api-w23 macos a provider cannot be registered against an unattached responder" {
    var responder = text.Responder.init(std.testing.allocator, std.testing.io);
    defer responder.deinit();
    // The refusal names the host's own mistake, so it is visible on a build
    // that has no shim at all rather than hidden behind one refusal for every
    // reason at once.
    try std.testing.expectError(
        error.Unsupported,
        registerProvider(&responder, .{ .send_types = &.{"public.utf8-plain-text"} }),
    );
}
