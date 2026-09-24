const std = @import("std");
const sdl3 = @import("sdl3");
const nogui = @import("nogui");
const Application = @import("application.zig").Application;
const ManagedWindow = @import("application.zig").ManagedWindow;
const ScaleNotice = @import("application.zig").ScaleNotice;
const ScaleReading = @import("application.zig").ScaleReading;
const display = @import("display.zig");
const contracts = nogui.window_contract;
const sdl_session = @import("sdl_session.zig");
const dialogs = @import("dialogs.zig");
const open_url = @import("open_url.zig");

/// One SDL driver for the whole test binary, held until the process exits;
/// see sdl_session.zig. Without it each `host.deinit` would quit SDL and the
/// next test would pay another device probe.
fn holdSdl() !void {
    try sdl_session.acquireForTest("dummy");
}

const Count = struct { value: u32 };
const CountView = struct {
    prefix: []const u8,

    pub fn draw(self: *CountView, count: *const Count, ctx: *nogui.DrawCtx) !void {
        const text = try std.fmt.allocPrint(ctx.arena, "{s}: {d}", .{ self.prefix, count.value });
        _ = try ctx.label(.{ .text = text });
    }
};

fn addCount(count: *Count, delta: u32) !void {
    count.value += delta;
}

/// Consume whatever a window is demanding, the way the host's own frame loop
/// does, so a test can observe what a LATER event re-arms.
fn settle(window: *ManagedWindow) void {
    const now = sdl3.timer.getMillisecondsSinceInit();
    while (window.demand.take(now) != null) window.demand.finish(true);
}

fn startHost(session: *nogui.Session) !Application {
    try holdSdl();
    return Application.init(std.testing.allocator, session, .{ .video_driver = "dummy" });
}

test "api-w07 one model renders through two isolated native windows and independent App frames" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var count: Count = .{ .value = 4 };
    var model = try session.create(Count, &count);
    defer session.release(Count, &model) catch unreachable;
    const left_id = try host.openWindow(.{ .title = "left", .width = 320, .height = 180 });
    const right_id = try host.openWindow(.{ .title = "right", .width = 480, .height = 240 });
    var left_view: CountView = .{ .prefix = "L" };
    var right_view: CountView = .{ .prefix = "R" };
    const left = try host.getWindow(left_id);
    const right = try host.getWindow(right_id);
    try left.app.mountModelRoot(Count, CountView, model, &left_view);
    try right.app.mountModelRoot(Count, CountView, model, &right_view);
    const first_left = try left.app.frame(1, .{ .width = 320, .height = 180 });
    const first_right = try right.app.frame(1, .{ .width = 480, .height = 240 });
    try std.testing.expectEqualStrings("L: 4", first_left.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqualStrings("R: 4", first_right.tree.nodes.items[0].kind.label.text);
    try std.testing.expect(first_left.tree != first_right.tree);
    const raw: sdl3.events.Event = .{ .mouse_motion = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window_id = left.native.id,
        .state = .{ .left = false, .middle = false, .right = false, .side1 = false, .side2 = false },
        .x = 17,
        .y = 29,
        .x_rel = 0,
        .y_rel = 0,
    } };
    const routed = (try host.dispatch(&raw)).?.window;
    try std.testing.expectEqual(left_id, routed.handle);
    _ = try left.app.handle(routed.translated.?.input);
    try std.testing.expect(right.app.mouse_pos == null);
    try session.update(Count, model, @as(u32, 3), addCount);
    const next_left = try left.app.frame(2, .{ .width = 320, .height = 180 });
    const next_right = try right.app.frame(2, .{ .width = 480, .height = 240 });
    try std.testing.expectEqualStrings("L: 7", next_left.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqualStrings("R: 7", next_right.tree.nodes.items[0].kind.label.text);
    try std.testing.expect(try host.closeWindow(left_id));
    try std.testing.expect(session.hasWindow(right.app.window));
    try std.testing.expectEqualStrings("R: 7", right.app.tree_ptr.?.nodes.items[0].kind.label.text);
}

const ClosePolicy = struct {
    allow: bool = false,
    attempts: u32 = 0,
    closed: u32 = 0,
    bells: u32 = 0,
    fn request(raw: *anyopaque, _: contracts.WindowHandle) bool {
        const self: *ClosePolicy = @ptrCast(@alignCast(raw));
        self.attempts += 1;
        return self.allow;
    }
    fn completed(raw: *anyopaque, _: contracts.WindowHandle) void {
        const self: *ClosePolicy = @ptrCast(@alignCast(raw));
        self.closed += 1;
    }
    fn bellClosed(raw: *anyopaque) void {
        const self: *ClosePolicy = @ptrCast(@alignCast(raw));
        self.bells += 1;
    }
};

test "api-w07 close veto retains mounts; reused slot rejects old handle and queued native events" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var policy: ClosePolicy = .{};
    host.setHooks(.{ .context = &policy, .on_close_request = ClosePolicy.request, .on_closed = ClosePolicy.completed });
    const old = try host.openWindow(.{ .title = "old", .width = 250, .height = 170 });
    const first = try host.getWindow(old);
    var count: Count = .{ .value = 12 };
    var model = try session.create(Count, &count);
    defer session.release(Count, &model) catch unreachable;
    var view: CountView = .{ .prefix = "vetoed" };
    try first.app.mountModelRoot(Count, CountView, model, &view);
    const original_sdl_id = first.native.id;
    const original_app_id = first.app.window;
    try std.testing.expect(!(try host.closeWindow(old)));
    try std.testing.expect(session.hasWindow(original_app_id));
    const frame = try first.app.frame(1, .{ .width = 250, .height = 170 });
    try std.testing.expectEqualStrings("vetoed: 12", frame.tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqual(@as(u32, 0), policy.closed);
    policy.allow = true;
    try std.testing.expect(try host.closeWindow(old));
    try std.testing.expect(!session.hasWindow(original_app_id));
    const replacement = try host.openWindow(.{ .title = "new", .width = 300, .height = 200 });
    try std.testing.expectEqual(old.slot, replacement.slot);
    try std.testing.expect(old.generation != replacement.generation);
    try std.testing.expect(replacement.session_window != original_app_id);
    try std.testing.expectError(error.StaleWindow, host.getWindow(old));
    try std.testing.expectError(error.StaleWindow, host.closeWindow(old));
    const stale_event: sdl3.events.Event = .{ .window_close_requested = .{
        .common = .{ .timestamp = 0 },
        .id = original_sdl_id,
    } };
    _ = try host.dispatch(&stale_event);
    try std.testing.expect(session.hasWindow(replacement.session_window));
    try std.testing.expectEqual(@as(u32, 2), policy.attempts);
    try std.testing.expectEqual(@as(u32, 1), policy.closed);
}

test "api-w07 failed second creation keeps the first App and window usable" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const first = try host.openWindow(.{ .title = "first", .width = 320, .height = 200 });
    const first_app_id = (try host.getWindow(first)).app.window;
    try std.testing.expectError(error.MissingParent, host.openWindow(.{
        .title = "invalid popup",
        .width = 200,
        .height = 100,
        .kind = .tooltip,
    }));
    try std.testing.expectError(error.InvalidWindowSize, host.openWindow(.{
        .title = "invalid size",
        .width = 0,
        .height = 100,
    }));
    // A refused open must leave nothing behind: no window, no slot consumed
    // and no title copy. The first window is not merely still registered, it
    // is still the only one and still drives a full frame.
    try std.testing.expectEqual(@as(u32, 1), host.window_count);
    try std.testing.expect(session.hasWindow(first_app_id));
    const original = try host.getWindow(first);
    try std.testing.expectEqual(@as(u32, 320), original.requested.size.width);
    try original.requestSize(.{ .width = 350, .height = 210 });
    try std.testing.expectEqual(contracts.Size{ .width = 350, .height = 210 }, original.requested.size);
    try original.refresh();
    // The client size in use is the platform's own reading, and this host
    // never overwrites it with the request it made.
    const native_size = try original.native.sdl.getSize();
    try std.testing.expectEqual(@as(u32, @intCast(native_size[0])), original.observed.size.width);
    try std.testing.expectEqual(@as(u32, @intCast(native_size[1])), original.observed.size.height);
    // Divergence is null exactly when the requested size is the size in use,
    // whichever way this backend resolved the request.
    const honoured = original.observed.size.width == 350 and original.observed.size.height == 210;
    try std.testing.expectEqual(honoured, original.divergence() == null);
    var count: Count = .{ .value = 9 };
    var model = try session.create(Count, &count);
    defer session.release(Count, &model) catch unreachable;
    var view: CountView = .{ .prefix = "first" };
    try original.app.mountModelRoot(Count, CountView, model, &view);
    const frame = try original.app.frame(1, .{ .width = 350, .height = 210 });
    try std.testing.expectEqualStrings("first: 9", frame.tree.nodes.items[0].kind.label.text);
    // The peer that never opened has a slot of its own, so the next window
    // cannot inherit the surviving one's identity.
    const second = try host.openWindow(.{ .title = "second", .width = 200, .height = 120 });
    try std.testing.expect(second.slot != first.slot);
    try std.testing.expectEqual(@as(u32, 2), host.window_count);
    try std.testing.expect(try host.closeWindow(second));
    try std.testing.expect(try host.closeWindow(first));
}

test "api-w07 a partial creation releases that window and leaves the survivor usable" {
    // The refusal paths `open` checks BEFORE it allocates anything are one
    // story; this one is the other half. An open that fails AFTER it has taken
    // the title copy and created the native window must unwind everything IT
    // acquired — exactly once — while any window that was already open keeps
    // its own App, its own session registration and its own frames.
    //
    // The failing index is walked across every allocation the scenario makes,
    // so the App, the title copy, the ManagedWindow, both map capacities, the
    // model retain and each frame's own tree are each failed in turn. After
    // every run the allocator's own counters must balance — allocations
    // against deallocations and bytes against bytes — so a leak AND a double
    // release both fail here instead of being assumed away, and the counts
    // are read from the failing allocator rather than from anything this host
    // chose to record.
    // What one run of the scenario published.
    const Run = struct { opened: u32 = 0 };
    const Impl = struct {
        fn run(gpa: std.mem.Allocator, out: *Run) !void {
            try holdSdl();
            var session = nogui.Session.init(gpa) catch |err| return fail(@TypeOf(err), err);
            defer session.deinit() catch unreachable;
            var host = Application.init(gpa, &session, .{ .video_driver = "dummy" }) catch |err|
                return fail(@TypeOf(err), err);
            defer host.deinit();
            // A frame presents what is MOUNTED, so "the survivor is usable"
            // is only observable with a mount on it. The model and both views
            // are declared out here and stay alive past every close, so no
            // App is ever left holding a view that has already died.
            //
            // `session.create` MOVES its source: it copies the value into
            // session-owned storage and then sets the caller's local to
            // `undefined`. Reading `count` back afterwards would format
            // undefined memory — 0xAAAAAAAA prints as 2863311530 — so the
            // expected number is the seed literal the live model was seeded
            // with. This is the same move tests 1 and 3 above make, which is
            // why they compare against a literal rather than a moved-from
            // local.
            const seeded_count: u32 = 6;
            var count: Count = .{ .value = seeded_count };
            var model = session.create(Count, &count) catch |err| return fail(@TypeOf(err), err);
            defer session.release(Count, &model) catch unreachable;
            var views: [2]CountView = .{ .{ .prefix = "first" }, .{ .prefix = "second" } };
            // Two independent opens: whichever one the failing index lands in
            // is the partial one, and the other is the survivor.
            var live: [2]?contracts.WindowHandle = .{ null, null };
            for (&live, 0..) |*slot, index| {
                slot.* = host.openWindow(.{
                    .title = if (index == 0) "first" else "second",
                    .width = if (index == 0) 320 else 200,
                    .height = if (index == 0) 200 else 120,
                }) catch |err| return fail(@TypeOf(err), err);
                // The open either returned a handle or returned early above,
                // so the slot can never still be null here.
                const handle = slot.*.?;
                // A window that DID open is registered, addressable, holds a
                // live session window and drives a frame. That is the whole
                // survivor contract, and it is checked after every refusal.
                const window = try host.getWindow(handle);
                try std.testing.expectEqual(@as(u32, @intCast(index + 1)), host.window_count);
                window.app.mountModelRoot(Count, CountView, model, &views[index]) catch |err|
                    return fail(@TypeOf(err), err);
                const frame = window.app.frame(1, .{
                    .width = if (index == 0) 320 else 200,
                    .height = if (index == 0) 200 else 120,
                }) catch |err| return fail(@TypeOf(err), err);
                // The frame is not merely returned: it carries the mounted
                // view's own output, which is what "still usable" means.
                var label: [32]u8 = undefined;
                try std.testing.expectEqualStrings(
                    try std.fmt.bufPrint(&label, "{s}: {d}", .{ views[index].prefix, seeded_count }),
                    frame.tree.nodes.items[0].kind.label.text,
                );
                out.opened += 1;
            }
            // A refused open consumed no slot: the table holds exactly the
            // windows that opened and the count agrees with it.
            try std.testing.expectEqual(host.window_count, host.slots.items.len);
            try std.testing.expectEqual(host.window_count, out.opened);
            for (live) |maybe| {
                const handle = maybe orelse continue;
                try std.testing.expect(try host.closeWindow(handle));
            }
            try std.testing.expectEqual(@as(u32, 0), host.window_count);
        }

        /// Name the refusal so the sweep can tell a real OOM from a scenario
        /// that ran to completion. Anything that is not an OOM is the host
        /// misbehaving and is passed straight through, so this carries the
        /// CALLER's own error set instead of collapsing it to `anyerror`. The
        /// refusal is matched by name because not every call this wraps can
        /// report an OOM in its own set.
        fn fail(comptime E: type, err: E) (E || error{ReportedOutOfMemory})!void {
            if (std.mem.eql(u8, @errorName(err), "OutOfMemory")) return error.ReportedOutOfMemory;
            return err;
        }
    };
    // One unlimited run first, so the sweep knows how many allocations there
    // are to fail and so the scenario is known to work with memory.
    var baseline = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var warm: Run = .{};
    try Impl.run(baseline.allocator(), &warm);
    try std.testing.expectEqual(@as(u32, 2), warm.opened);
    const total = baseline.alloc_index;
    try std.testing.expect(total > 0);
    var induced: u32 = 0;
    for (0..total) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var run: Run = .{};
        Impl.run(failing.allocator(), &run) catch |err| {
            try std.testing.expectEqual(error.ReportedOutOfMemory, err);
            induced += 1;
        };
        // Exactly-once is read off the allocator: every byte this run took is
        // back, and every block is freed as many times as it was allocated.
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
        // A refusal of the SECOND open must leave the first one intact, and
        // `run` already asserted exactly that while it held it. A refusal of
        // the first open leaves no survivor, so for that one the allocator
        // counters are the whole of the evidence.
    }
    // The sweep must actually have induced failures, or it proved nothing
    // about unwinding.
    try std.testing.expect(induced > 0);
}

test "api-w07 a vetoed close changes nothing observable" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var policy: ClosePolicy = .{};
    host.setHooks(.{ .context = &policy, .on_close_request = ClosePolicy.request, .on_closed = ClosePolicy.completed });
    const handle = try host.openWindow(.{ .title = "held", .width = 300, .height = 200 });
    var window = try host.getWindow(handle);
    var count: Count = .{ .value = 5 };
    var model = try session.create(Count, &count);
    defer session.release(Count, &model) catch unreachable;
    var view: CountView = .{ .prefix = "held" };
    try window.app.mountModelRoot(Count, CountView, model, &view);
    _ = try window.app.frame(1, .{ .width = 300, .height = 200 });
    try host.bindSystemBell(handle, .{ .context = &policy, .on_closed = ClosePolicy.bellClosed });
    settle(window);

    // Every observable the host publishes about this window, read before the
    // veto and compared after it.
    const native_id = window.native.id;
    const app_window = window.app.window;
    const observed = window.observed;
    const baseline = window.scale_notice.reported;
    const demand = window.demand;
    const slots = host.slots.items.len;
    const free_slot = host.free_slot;
    const generation = host.slots.items[handle.slot].generation;
    const native_entries = host.native_windows.count();

    try std.testing.expect(!(try host.closeWindow(handle)));

    // The window is still the same window: same native window, same App, same
    // registration, same slot and generation, same native-id table, same
    // observed reading and scale baseline, same frame demand, same mount.
    try std.testing.expectEqual(@as(u32, 1), host.window_count);
    try std.testing.expectEqual(slots, host.slots.items.len);
    try std.testing.expectEqual(free_slot, host.free_slot);
    try std.testing.expectEqual(generation, host.slots.items[handle.slot].generation);
    try std.testing.expectEqual(native_entries, host.native_windows.count());
    // The table still answers for this native id, and it still answers with
    // the SAME window. An SDL window id and a Session registration are two
    // independent id spaces, so the identity to compare is the handle the
    // entry carries, not the key that looked it up. A veto returns from
    // `closeWindow` before `destroyWindow`, which is the only place the host
    // removes an entry, so the lookup cannot come back empty.
    try std.testing.expectEqual(handle, host.native_windows.get(native_id).?);
    try std.testing.expect(session.hasWindow(app_window));
    var after = try host.getWindow(handle);
    try std.testing.expectEqual(native_id, after.native.id);
    try std.testing.expectEqual(observed, after.observed);
    try std.testing.expectEqual(baseline, after.scale_notice.reported);
    try std.testing.expectEqual(demand.layout_dirty, after.demand.layout_dirty);
    try std.testing.expectEqual(demand.paint_dirty, after.demand.paint_dirty);
    try std.testing.expectEqual(demand.present_dirty, after.demand.present_dirty);
    // The bell binding survives a veto too: the same observer still owns this
    // window, so a veto cannot quietly transfer or drop the ring target.
    try std.testing.expect(after.bell_owner != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&policy)), after.bell_owner.?.context);
    try std.testing.expectEqual(@as(u32, 0), policy.closed);
    try std.testing.expectEqual(@as(u32, 1), policy.attempts);
    try std.testing.expectEqual(@as(u32, 0), policy.bells);
    // And the window still drives a full frame with its mount intact.
    const frame = try after.app.frame(2, .{ .width = 300, .height = 200 });
    try std.testing.expectEqualStrings("held: 5", frame.tree.nodes.items[0].kind.label.text);
    // Releasing afterwards still closes it, and closes it exactly once.
    policy.allow = true;
    try std.testing.expect(try host.closeWindow(handle));
    try std.testing.expectEqual(@as(u32, 2), policy.attempts);
    try std.testing.expectEqual(@as(u32, 1), policy.closed);
    try std.testing.expectEqual(@as(u32, 1), policy.bells);
    try std.testing.expect(!session.hasWindow(app_window));
}

test "api-w07 a reused slot and native id misdeliver nothing to the new occupant" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const original = try host.openWindow(.{ .title = "original", .width = 260, .height = 180 });
    const original_window = try host.getWindow(original);
    const original_native = original_window.native.id;
    const original_created_ns = original_window.created_ns;
    const original_app = original_window.app.window;
    var count: Count = .{ .value = 1 };
    var model = try session.create(Count, &count);
    defer session.release(Count, &model) catch unreachable;
    var view: CountView = .{ .prefix = "original" };
    try original_window.app.mountModelRoot(Count, CountView, model, &view);
    _ = try original_window.app.frame(1, .{ .width = 260, .height = 180 });
    try std.testing.expect(try host.closeWindow(original));

    // The replacement takes the freed slot. Its generation is what makes the
    // old handle stop naming it.
    const replacement = try host.openWindow(.{ .title = "replacement", .width = 320, .height = 220 });
    try std.testing.expectEqual(original.slot, replacement.slot);
    try std.testing.expect(original.generation != replacement.generation);
    const occupant = try host.getWindow(replacement);
    try std.testing.expect(replacement.session_window != original_app);
    var occupant_view: CountView = .{ .prefix = "replacement" };
    try occupant.app.mountModelRoot(Count, CountView, model, &occupant_view);
    const before = try occupant.app.frame(1, .{ .width = 320, .height = 220 });
    try std.testing.expectEqualStrings("replacement: 1", before.tree.nodes.items[0].kind.label.text);
    const occupant_generation = occupant.app.frame_generation;

    // Every event class SDL can still have queued for the window that died,
    // carrying the native id that window had. A platform that reuses the id
    // would otherwise route all of them to whoever sits in the slot now.
    const stale_ns = original_created_ns -| 1;
    const stale: []const sdl3.events.Event = &.{
        .{ .mouse_motion = .{
            .common = .{ .timestamp = stale_ns },
            .window_id = original_native,
            .state = .{ .left = false, .middle = false, .right = false, .side1 = false, .side2 = false },
            .x = 11,
            .y = 13,
            .x_rel = 0,
            .y_rel = 0,
        } },
        .{ .mouse_button_down = .{
            .common = .{ .timestamp = stale_ns },
            .window_id = original_native,
            .button = .left,
            .down = true,
            .clicks = 1,
            .x = 11,
            .y = 13,
        } },
        .{ .key_down = .{
            .common = .{ .timestamp = stale_ns },
            .window_id = original_native,
            .id = null,
            .scancode = .escape,
            .key = .escape,
            .mod = .none,
            .raw = 0,
            .down = true,
            .repeat = false,
        } },
        .{ .window_resized = .{
            .common = .{ .timestamp = stale_ns },
            .id = original_native,
            .width = 1,
            .height = 1,
        } },
        .{ .window_display_scale_changed = .{
            .common = .{ .timestamp = stale_ns },
            .id = original_native,
        } },
        .{ .window_focus_lost = .{
            .common = .{ .timestamp = stale_ns },
            .id = original_native,
        } },
        .{ .window_close_requested = .{
            .common = .{ .timestamp = stale_ns },
            .id = original_native,
        } },
        .{ .finger_down = .{
            .common = .{ .timestamp = stale_ns },
            .window_id = original_native,
            .id = .{ .value = 3 },
            .finger_id = .{ .value = 9 },
            .x = 0.5,
            .y = 0.5,
            .dx = 0,
            .dy = 0,
            .pressure = 1,
        } },
    };
    for (stale) |*raw| {
        try std.testing.expect((try host.dispatch(raw)) == null);
    }
    // Nothing reached the new occupant: no pointer, no key, no resize, no
    // focus loss, no contact, and the window the person is now looking at is
    // still open and still on its own committed tree.
    try std.testing.expect(occupant.app.mouse_pos == null);
    try std.testing.expectEqual(occupant_generation, occupant.app.frame_generation);
    try std.testing.expectEqual(@as(u32, 1), host.window_count);
    try std.testing.expect(session.hasWindow(replacement.session_window));
    const after = try occupant.app.frame(2, .{ .width = 320, .height = 220 });
    try std.testing.expectEqualStrings("replacement: 1", after.tree.nodes.items[0].kind.label.text);
    // A current event for the same native id still routes, so the guard is a
    // timestamp comparison and not a blanket refusal.
    const live: sdl3.events.Event = .{ .window_focus_lost = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .id = occupant.native.id,
    } };
    const routed = (try host.dispatch(&live)).?.window;
    try std.testing.expectEqual(replacement, routed.handle);
    switch (routed.translated.?.input) {
        .window_focus_lost => {},
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(try host.closeWindow(replacement));
}

test "api-w07 one routed event carries one client measurement to state, scale and input" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const handle = try host.openWindow(.{ .title = "atomic", .width = 400, .height = 300 });
    const window = try host.getWindow(handle);
    var count: Count = .{ .value = 3 };
    var model = try session.create(Count, &count);
    defer session.release(Count, &model) catch unreachable;
    var view: CountView = .{ .prefix = "atomic" };
    try window.app.mountModelRoot(Count, CountView, model, &view);
    _ = try window.app.frame(1, .{ .width = 400, .height = 300 });
    settle(window);

    // Move the window to a client box the platform really holds, then let the
    // resize event arrive. The three places a client box is consumed — the
    // observed state the consumer renders at, the scale baseline it is
    // measured against, and the extents the event itself carries — must all
    // name the SAME reading, so a consumer can convert pointer, IME and render
    // coordinates against one box instead of three that may disagree.
    try window.requestSize(.{ .width = 500, .height = 350 });
    const resized: sdl3.events.Event = .{ .window_resized = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .id = window.native.id,
        .width = 500,
        .height = 350,
    } };
    const routed = (try host.dispatch(&resized)).?.window;
    try std.testing.expect(routed.state_changed);
    const live = try host.getWindow(handle);
    const published = ScaleReading.capture(live.observed);
    // The state, the baseline and the event payload are one measurement.
    try std.testing.expectEqual(published, live.scale_notice.reported);
    const payload = switch (routed.translated.?) {
        .resize => |result| result,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(live.observed.pixels.width, payload.pixels.width);
    try std.testing.expectEqual(live.observed.pixels.height, payload.pixels.height);
    try std.testing.expectEqual(@as(f32, @floatFromInt(live.observed.size.width)), payload.core.resize.width);
    try std.testing.expectEqual(@as(f32, @floatFromInt(live.observed.size.height)), payload.core.resize.height);
    // Pointer coordinates are in the same logical box the render target and
    // the IME candidate share, so a scale built from that one reading maps
    // window points onto the exact device extent the event reported.
    const scale = try live.observed.pixelScale();
    const device = scale.windowToDevice(.{ .x = 7, .y = 9 });
    try std.testing.expect(device.x >= 0 and device.y >= 0);
    try std.testing.expect(device.x < @as(f32, @floatFromInt(live.observed.pixels.width)));
    try std.testing.expect(device.y < @as(f32, @floatFromInt(live.observed.pixels.height)));
    // A re-read arms layout whatever tag carried it: a fullscreen transition
    // and a move both change the pixel box, and both are reported as state
    // changes, so both must be followed by a frame.
    var layout_events: [3]sdl3.events.Event = .{
        .{ .window_enter_fullscreen = .{
            .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
            .id = window.native.id,
        } },
        .{ .window_display_changed = .{
            .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
            .id = window.native.id,
            .display = display.toNative(live.observed.display),
        } },
        .{ .window_moved = .{
            .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
            .id = window.native.id,
            .x = 12,
            .y = 34,
        } },
    };
    for (&layout_events) |*raw| {
        settle(try host.getWindow(handle));
        try std.testing.expect(!(try host.getWindow(handle)).demand.pending(sdl3.timer.getMillisecondsSinceInit()));
        const event = (try host.dispatch(raw)).?.window;
        try std.testing.expect(event.state_changed);
        try std.testing.expect((try host.getWindow(handle)).demand.pending(sdl3.timer.getMillisecondsSinceInit()));
    }
    try std.testing.expect(try host.closeWindow(handle));
}

const Work = struct {
    complete: *std.atomic.Value(bool),
    increment: u32,

    fn run(self: *Work, _: std.Io) void {
        self.complete.store(true, .release);
    }

    fn delivered(count: *Count, self: *Work, _: *nogui.Session) void {
        count.value += self.increment;
    }
};

fn readCount(count: *const Count, output: *u32) !void {
    output.* = count.value;
}

test "api-w07 queued worker completion never reaches a replacement window or shared model" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    try session.startTasksOwned();
    var host = try startHost(&session);
    defer host.deinit();
    try host.start();
    var count: Count = .{ .value = 2 };
    var model = try session.create(Count, &count);
    defer session.release(Count, &model) catch unreachable;
    const first = try host.openWindow(.{ .title = "worker", .width = 320, .height = 200 });
    var finished: std.atomic.Value(bool) = .init(false);
    var payload: Work = .{ .complete = &finished, .increment = 17 };
    const sequence = try session.taskWakeSnapshot();
    _ = try session.spawnWorker(
        Work,
        Count,
        Work.run,
        Work.delivered,
        model.weak(),
        &payload,
        .{ .window = first.session_window },
    );
    try std.testing.expect(try host.closeWindow(first));
    const second = try host.openWindow(.{ .title = "reuse", .width = 320, .height = 200 });
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.session_window != second.session_window);
    var completed = false;
    for (0..100) |_| {
        const snapshot = try session.taskWakeSnapshot();
        if (snapshot -% sequence >= 2) {
            completed = true;
            break;
        }
        _ = try session.waitForTaskWake(snapshot, 10 * std.time.ns_per_ms);
    }
    try std.testing.expect(completed);
    try std.testing.expect(finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), try session.drainTasks());
    var observed: u32 = 0;
    try session.read(Count, model, &observed, readCount);
    try std.testing.expectEqual(@as(u32, 2), observed);
    try std.testing.expectError(error.UnknownWindow, session.spawnWorker(
        Work,
        Count,
        Work.run,
        Work.delivered,
        model.weak(),
        &payload,
        .{ .window = first.session_window },
    ));
}

test "api-w07 borrowed App stays caller-owned yet retires window-bound task delivery on close" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var external = try nogui.App.init(std.testing.allocator, &session);
    defer external.deinit();
    var host = try startHost(&session);
    defer host.deinit();
    const window = try host.openWindowWithApp(&external, .{
        .title = "embedded",
        .width = 320,
        .height = 200,
    });
    try std.testing.expect((try host.getWindow(window)).app == &external);
    try std.testing.expectError(error.AppAlreadyMounted, host.openWindowWithApp(&external, .{
        .title = "duplicate",
        .width = 320,
        .height = 200,
    }));
    try std.testing.expect(try host.closeWindow(window));
    try std.testing.expect(!session.hasWindow(external.window));
    try std.testing.expectError(error.UnknownWindow, session.requestRedraw(external.window));
}

test "api-w07 real SDL display query and resized window preserve logical vs pixel extents" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const primary = try display.primary();
    const info = try display.query(primary);
    try std.testing.expect(info.full_bounds.size.width > 0);
    try std.testing.expect(info.full_bounds.size.height > 0);
    try std.testing.expect(info.content_scale > 0);
    const window = try host.openWindow(.{
        .title = "display",
        .width = 300,
        .height = 190,
        .display = primary,
        .minimum_size = .{ .width = 120, .height = 100 },
    });
    const managed = try host.getWindow(window);
    try managed.requestSize(.{ .width = 360, .height = 240 });
    try managed.refresh();
    const size = try managed.native.sdl.getSize();
    try std.testing.expectEqual(@as(u32, @intCast(size[0])), managed.observed.size.width);
    try std.testing.expectEqual(@as(u32, @intCast(size[1])), managed.observed.size.height);
    const pixels = try managed.native.sdl.getSizeInPixels();
    try std.testing.expectEqual(@as(u32, @intCast(pixels[0])), managed.observed.pixels.width);
    try std.testing.expectEqual(@as(u32, @intCast(pixels[1])), managed.observed.pixels.height);
    const scale = try managed.observed.pixelScale();
    const point = scale.windowToDevice(.{ .x = 1.5, .y = 2.5 });
    try std.testing.expect(point.x > 0 and point.y > 0);
    const raw: sdl3.events.Event = .{ .window_display_scale_changed = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .id = managed.native.id,
    } };
    const routed = (try host.dispatch(&raw)).?;
    try std.testing.expectEqual(window, routed.window.handle);
    try std.testing.expect(managed.demand.pending(sdl3.timer.getMillisecondsSinceInit()));
}

const Lifecycle = struct {
    launches: u32 = 0,
    reopenings: u32 = 0,
    quit_token: ?Application.QuitToken = null,
    fn launch(raw: *anyopaque, _: *Application) void {
        const self: *Lifecycle = @ptrCast(@alignCast(raw));
        self.launches += 1;
    }
    fn reopen(raw: *anyopaque, _: *Application) void {
        const self: *Lifecycle = @ptrCast(@alignCast(raw));
        self.reopenings += 1;
    }
    fn quit(raw: *anyopaque, _: *Application, token: Application.QuitToken) Application.QuitDecision {
        const self: *Lifecycle = @ptrCast(@alignCast(raw));
        self.quit_token = token;
        return .defer_decision;
    }
};

test "api-w07 external SDL pump launches once and resolves bounded asynchronous quit" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var lifecycle: Lifecycle = .{};
    host.setHooks(.{
        .context = &lifecycle,
        .on_launch = Lifecycle.launch,
        .on_reopen = Lifecycle.reopen,
        .on_quit_request = Lifecycle.quit,
    });
    const handle = try host.openWindow(.{ .title = "pump", .width = 240, .height = 160 });
    _ = try host.step();
    _ = try host.step();
    try std.testing.expectEqual(@as(u32, 1), lifecycle.launches);
    try host.reopen();
    try std.testing.expectEqual(@as(u32, 1), lifecycle.reopenings);
    const raw: sdl3.events.Event = .{ .window_close_requested = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .id = (try host.getWindow(handle)).native.id,
    } };
    try sdl3.events.push(raw);
    while (host.pollEvent()) |queued| {
        _ = try host.dispatch(&queued);
    }
    try std.testing.expectError(error.StaleWindow, host.getWindow(handle));
    try host.requestQuit();
    try std.testing.expect(host.isRunning());
    try host.resolveQuit(lifecycle.quit_token.?, true);
    try std.testing.expect(!host.isRunning());
}

const SelectiveClose = struct {
    blocked: ?contracts.WindowHandle = null,
    fn request(raw: *anyopaque, handle: contracts.WindowHandle) bool {
        const self: *SelectiveClose = @ptrCast(@alignCast(raw));
        return self.blocked == null or !std.meta.eql(handle, self.blocked.?);
    }
};

test "api-w07 global quit preflights all close vetoes before tearing down either window" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var policy: SelectiveClose = .{};
    host.setHooks(.{ .context = &policy, .on_close_request = SelectiveClose.request });
    const left = try host.openWindow(.{ .title = "left", .width = 220, .height = 140 });
    const right = try host.openWindow(.{ .title = "right", .width = 220, .height = 140 });
    policy.blocked = right;
    try std.testing.expectError(error.CloseVetoed, host.requestQuit());
    try std.testing.expect(host.isRunning());
    try std.testing.expect(session.hasWindow(left.session_window));
    try std.testing.expect(session.hasWindow(right.session_window));
    _ = try host.getWindow(left);
    _ = try host.getWindow(right);
    policy.blocked = null;
    try host.requestQuit();
    try std.testing.expect(!host.isRunning());
    try std.testing.expect(!session.hasWindow(left.session_window));
    try std.testing.expect(!session.hasWindow(right.session_window));
}

test "api-w07 bounded quit veto and explicit restart do not repeat process launch" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    try holdSdl();
    var host = try Application.init(std.testing.allocator, &session, .{
        .video_driver = "dummy",
        .restart = .explicit,
        .quit_timeout_ms = 0,
    });
    defer host.deinit();
    var lifecycle: Lifecycle = .{};
    host.setHooks(.{ .context = &lifecycle, .on_launch = Lifecycle.launch, .on_quit_request = Lifecycle.quit });
    const first = try host.openWindow(.{ .title = "first", .width = 200, .height = 150 });
    try host.start();
    try host.requestQuit();
    try std.testing.expectError(error.QuitRequestExpired, host.resolveQuit(lifecycle.quit_token.?, true));
    try std.testing.expect(host.isRunning());
    _ = try host.getWindow(first);
    host.setHooks(.{ .context = &lifecycle, .on_launch = Lifecycle.launch });
    try host.requestQuit();
    try host.restart();
    try host.start();
    try std.testing.expectEqual(@as(u32, 1), lifecycle.launches);
    const reopened = try host.openWindow(.{ .title = "restart", .width = 200, .height = 150 });
    try std.testing.expect(first.session_window != reopened.session_window);
}

const Launches = struct {
    files: u32 = 0,
    matched_path: bool = false,
    fn incoming(raw: *anyopaque, _: *Application, launch: Application.IncomingLaunch) void {
        const self: *Launches = @ptrCast(@alignCast(raw));
        if (launch.kind == .file) {
            self.files += 1;
            self.matched_path = std.mem.eql(u8, launch.value, "/tmp/incoming.txt");
        }
    }
};

test "api-w07 incoming SDL launch waits for handler and is delivered once" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const raw: sdl3.events.Event = .{ .drop_file = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window = null,
        .x = 0,
        .y = 0,
        .source = null,
        .file_name = "/tmp/incoming.txt",
    } };
    _ = try host.dispatch(&raw);
    var launches: Launches = .{};
    host.setHooks(.{ .context = &launches, .on_incoming_launch = Launches.incoming });
    try std.testing.expectEqual(@as(u32, 1), launches.files);
    try std.testing.expect(launches.matched_path);
    _ = try host.step();
    try std.testing.expectEqual(@as(u32, 1), launches.files);
}

test "api-w07 minimized stays null where the platform cannot report it" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    // Both capabilities come from the platform SDL actually brought up, not
    // from a build flag, so the flags and the value shapes cannot drift apart.
    const capabilities = host.capabilities();
    try std.testing.expectEqual(display.hasGlobalPosition(), capabilities.global_position);
    try std.testing.expectEqual(display.hasWindowMinimized(), capabilities.minimized);
    // The dummy driver installs no minimize path, so this host cannot observe
    // the state and must not pass a `false` it never measured off as one.
    try std.testing.expect(!capabilities.minimized);
    try std.testing.expect(!capabilities.global_position);
    const handle = try host.openWindow(.{ .title = "minimized", .width = 320, .height = 200 });
    const managed = try host.getWindow(handle);
    try std.testing.expect(managed.observed.minimized == null);
    // A platform with no minimize path must refuse the request, and refusing
    // it must not record an intent the platform never accepted. A hard
    // `false` observation would be the one thing this contract must never
    // produce here.
    try std.testing.expectError(error.SdlError, managed.requestMinimize());
    try std.testing.expect(!managed.requested.minimized);
    try managed.refresh();
    try std.testing.expect(managed.observed.minimized == null);
    // Restore is refused the same way, and a refusal leaves the intent alone.
    try std.testing.expectError(error.SdlError, managed.requestRestore());
    try std.testing.expect(!managed.requested.minimized);
    try managed.refresh();
    try std.testing.expect(managed.observed.minimized == null);
    // The capability and the value shape are one contract: a platform that
    // reports the state must never yield null for it.
    try std.testing.expect(capabilities.minimized == (managed.observed.minimized != null));
    try std.testing.expect(try host.closeWindow(handle));
}

test "api-w07 hide is lifted by activate and reopen, and only visible windows come back" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const shown = try host.openWindow(.{ .title = "shown", .width = 240, .height = 160 });
    const parked = try host.openWindow(.{
        .title = "parked",
        .width = 240,
        .height = 160,
        .visible = false,
    });
    const shown_window = try host.getWindow(shown);
    const parked_window = try host.getWindow(parked);
    try std.testing.expect(!host.isHidden());
    try std.testing.expectEqual(@as(u32, 2), host.window_count);
    try host.hide();
    try std.testing.expect(host.isHidden());
    // An application-level hide changes what is on screen and nothing else: the
    // per-window intent is what reopen restores, so it must survive the hide.
    try std.testing.expect(shown_window.requested.visible);
    try std.testing.expect(!parked_window.requested.visible);
    try shown_window.refresh();
    try parked_window.refresh();
    try std.testing.expect(!shown_window.observed.visible);
    // A hidden window asks for no frames and waits for nothing.
    try std.testing.expect(!shown_window.demand.pending(sdl3.timer.getMillisecondsSinceInit()));
    try std.testing.expectEqual(@as(?u31, null), shown_window.demand.waitMilliseconds(
        sdl3.timer.getMillisecondsSinceInit(),
    ));
    try host.activate();
    try std.testing.expect(!host.isHidden());
    try shown_window.refresh();
    try parked_window.refresh();
    try std.testing.expect(shown_window.observed.visible);
    try std.testing.expect(!parked_window.observed.visible);
    // A window that was never asked to be visible is not brought up by a
    // reopen either; that is the caller's own request, not the hide's.
    try host.hide();
    try host.reopen();
    try std.testing.expect(!host.isHidden());
    try shown_window.refresh();
    try parked_window.refresh();
    try std.testing.expect(shown_window.observed.visible);
    try std.testing.expect(!parked_window.observed.visible);
    try std.testing.expect(try host.closeWindow(shown));
    try std.testing.expect(try host.closeWindow(parked));
}

const WakeLog = struct {
    wakes: u32 = 0,
    activates: u32 = 0,
    hides: u32 = 0,
    fn wake(raw: *anyopaque, _: *Application) void {
        const self: *WakeLog = @ptrCast(@alignCast(raw));
        self.wakes += 1;
    }
    fn activate(raw: *anyopaque, _: *Application) void {
        const self: *WakeLog = @ptrCast(@alignCast(raw));
        self.activates += 1;
    }
    fn hide(raw: *anyopaque, _: *Application) void {
        const self: *WakeLog = @ptrCast(@alignCast(raw));
        self.hides += 1;
    }
};

test "api-w07 system wake rearms layout, presentation and the session redraw of every window" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var log: WakeLog = .{};
    host.setHooks(.{
        .context = &log,
        .on_system_wake = WakeLog.wake,
        .on_activate = WakeLog.activate,
        .on_hide = WakeLog.hide,
    });
    const left = try host.openWindow(.{ .title = "left", .width = 220, .height = 150 });
    const right = try host.openWindow(.{ .title = "right", .width = 220, .height = 150 });
    const left_window = try host.getWindow(left);
    const right_window = try host.getWindow(right);
    // Settle both windows first: consume the demand a fresh window starts
    // with, and consume the session-side redraw, so what the wake re-arms is
    // visible as new work rather than as work already outstanding.
    _ = try session.takeRedraw(left_window.app.window);
    _ = try session.takeRedraw(right_window.app.window);
    // Settling goes through the real path rather than by assigning the struct:
    // a fresh `FrameDemand` is dirty by default, so a plain reset would leave
    // the very work this test is trying to observe still outstanding.
    settle(left_window);
    settle(right_window);
    try std.testing.expect(!left_window.demand.pending(sdl3.timer.getMillisecondsSinceInit()));
    try std.testing.expect(!right_window.demand.pending(sdl3.timer.getMillisecondsSinceInit()));
    try host.notifySystemWake();
    try std.testing.expectEqual(@as(u32, 1), log.wakes);
    for ([_]*ManagedWindow{ left_window, right_window }) |window| {
        try std.testing.expect(window.demand.pending(sdl3.timer.getMillisecondsSinceInit()));
        // The session redraw is a separate bit from the host demand, and a
        // wake that re-armed only the host would leave a resumed window
        // showing the frame it had when the system went away.
        try std.testing.expect(try session.takeRedraw(window.app.window));
    }
    // A platform transition reports the application as active, and it must
    // clear the hidden flag so the next activate does not raise an unmapped
    // window.
    const background: sdl3.events.Event = .{ .did_enter_background = .{
        .timestamp = sdl3.timer.getNanosecondsSinceInit(),
    } };
    _ = try host.dispatch(&background);
    try std.testing.expect(host.isHidden());
    try std.testing.expectEqual(@as(u32, 1), log.hides);
    const foreground: sdl3.events.Event = .{ .did_enter_foreground = .{
        .timestamp = sdl3.timer.getNanosecondsSinceInit(),
    } };
    _ = try host.dispatch(&foreground);
    try std.testing.expect(!host.isHidden());
    try std.testing.expectEqual(@as(u32, 1), log.activates);
    try std.testing.expectEqual(@as(u32, 2), log.wakes);
    // A foreground event is also the application's own activation, which is a
    // separate decision from the window being visible.
    _ = try session.takeRedraw(left_window.app.window);
    _ = try session.takeRedraw(right_window.app.window);
    try std.testing.expect(try host.closeWindow(left));
    try std.testing.expect(try host.closeWindow(right));
}

test "api-w07 a deferred quit is observable, bounded, and costs a stale token nothing" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    try holdSdl();
    var host = try Application.init(std.testing.allocator, &session, .{
        .video_driver = "dummy",
        .restart = .explicit,
        .quit_timeout_ms = 2_000,
    });
    defer host.deinit();
    var lifecycle: Lifecycle = .{};
    host.setHooks(.{ .context = &lifecycle, .on_quit_request = Lifecycle.quit });
    const handle = try host.openWindow(.{ .title = "quit", .width = 200, .height = 140 });
    try std.testing.expect(host.pendingQuit() == null);
    try host.requestQuit();
    // The hook deferred, so the host is still running and reports the bound it
    // is actually holding itself to.
    try std.testing.expect(host.isRunning());
    const pending = host.pendingQuit().?;
    try std.testing.expectEqual(lifecycle.quit_token.?, pending.token);
    try std.testing.expect(pending.remaining_ms <= host.quit_timeout_ms);
    try std.testing.expect(pending.remaining_ms > 0);
    _ = try host.getWindow(handle);
    // A second request while one is open is not a second token and does not
    // restart the clock on the request already waiting for an answer.
    const first_remaining = pending.remaining_ms;
    try host.requestQuit();
    try std.testing.expectEqual(lifecycle.quit_token.?, host.pendingQuit().?.token);
    try std.testing.expect(host.pendingQuit().?.remaining_ms <= first_remaining);
    // The host never sleeps past the deadline it published.
    const second = host.pendingQuit().?;
    try std.testing.expect((try host.nextWaitMilliseconds()).? <= second.remaining_ms);
    try host.resolveQuit(lifecycle.quit_token.?, true);
    try std.testing.expect(!host.isRunning());
    try std.testing.expect(host.pendingQuit() == null);
    try std.testing.expect(!session.hasWindow(handle.session_window));
    // Restarting drops the token: a resolution for the shutdown that just
    // happened cannot approve a request the restarted host is not holding.
    try host.restart();
    try std.testing.expect(host.isRunning());
    try std.testing.expectError(error.NoPendingQuit, host.resolveQuit(lifecycle.quit_token.?, true));
    const again = try host.openWindow(.{ .title = "again", .width = 200, .height = 140 });
    try std.testing.expect(again.session_window != handle.session_window);
    try std.testing.expect(try host.closeWindow(again));
}

test "api-w07 an unresolved deferred quit expires as a veto and leaves the windows up" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    try holdSdl();
    var host = try Application.init(std.testing.allocator, &session, .{
        .video_driver = "dummy",
        .restart = .explicit,
        .quit_timeout_ms = 0,
    });
    defer host.deinit();
    var lifecycle: Lifecycle = .{};
    host.setHooks(.{ .context = &lifecycle, .on_quit_request = Lifecycle.quit });
    const handle = try host.openWindow(.{ .title = "expiring", .width = 200, .height = 140 });
    try host.requestQuit();
    try std.testing.expect(host.pendingQuit() != null);
    // One step runs the expiry, and an expired request is dropped rather than
    // resolved: the token is spent and the window survives.
    _ = try host.step();
    try std.testing.expect(host.pendingQuit() == null);
    try std.testing.expect(host.isRunning());
    _ = try host.getWindow(handle);
    try std.testing.expectError(error.NoPendingQuit, host.resolveQuit(lifecycle.quit_token.?, true));
    // A fresh request is allowed after an expiry; what is bounded is an
    // unresolved request, not the ability to ask again.
    try host.requestQuit();
    try std.testing.expect(host.pendingQuit() != null);
    _ = try host.step();
    try std.testing.expect(host.isRunning());
    try std.testing.expect(try host.closeWindow(handle));
    const reopened = try host.openWindow(.{ .title = "post", .width = 200, .height = 140 });
    try std.testing.expect(!reopened.eql(handle));
}

test "api-w07 closing one window drops only its own queued work and leaves the peer's" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    try session.startTasksOwned();
    var host = try startHost(&session);
    defer host.deinit();
    try host.start();
    var count: Count = .{ .value = 5 };
    var model = try session.create(Count, &count);
    defer session.release(Count, &model) catch unreachable;
    const leaving = try host.openWindow(.{ .title = "leaving", .width = 240, .height = 160 });
    const staying = try host.openWindow(.{ .title = "staying", .width = 260, .height = 170 });
    const staying_window = try host.getWindow(staying);
    var view: CountView = .{ .prefix = "staying" };
    try staying_window.app.mountModelRoot(Count, CountView, model, &view);
    const frame = try staying_window.app.frame(1, .{ .width = 260, .height = 170 });
    try std.testing.expectEqualStrings("staying: 5", frame.tree.nodes.items[0].kind.label.text);
    var closed_done: std.atomic.Value(bool) = .init(false);
    var staying_done: std.atomic.Value(bool) = .init(false);
    var closed_work: Work = .{ .complete = &closed_done, .increment = 100 };
    var staying_work: Work = .{ .complete = &staying_done, .increment = 3 };
    _ = try session.spawnWorker(
        Work,
        Count,
        Work.run,
        Work.delivered,
        model.weak(),
        &closed_work,
        .{ .window = leaving.session_window },
    );
    _ = try session.spawnWorker(
        Work,
        Count,
        Work.run,
        Work.delivered,
        model.weak(),
        &staying_work,
        .{ .window = staying.session_window },
    );
    try std.testing.expect(try host.closeWindow(leaving));
    // Both workers still ran on the service thread; only the delivery aimed at
    // the closed window is refused. The wait is on the two workers' OWN
    // completion flags, not on a wake count: one job can publish more than
    // once, so a fixed count would declare victory before the second worker
    // had run.
    var completed = false;
    for (0..400) |_| {
        if (closed_done.load(.acquire) and staying_done.load(.acquire)) {
            completed = true;
            break;
        }
        const snapshot = try session.taskWakeSnapshot();
        _ = try session.waitForTaskWake(snapshot, 5 * std.time.ns_per_ms);
    }
    try std.testing.expect(completed);
    try std.testing.expect(closed_done.load(.acquire));
    try std.testing.expect(staying_done.load(.acquire));
    // Exactly ONE delivery survives: the peer's. The closed window's job ran on
    // the service thread and its result was discarded, so the count is one
    // rather than two, and a second drain finds nothing left to deliver.
    try std.testing.expectEqual(@as(usize, 1), try session.drainTasks());
    try std.testing.expectEqual(@as(usize, 0), try session.drainTasks());
    var observed: u32 = 0;
    try session.read(Count, model, &observed, readCount);
    // 5 plus the surviving window's increment, and not the closed window's.
    try std.testing.expectEqual(@as(u32, 8), observed);
    // The surviving window still holds the model it mounted, and its COMMITTED
    // tree still reads what that frame rendered: the delivery that followed the
    // close did not reach into a committed tree. Only the next frame, driven by
    // this test, reads the new value.
    try std.testing.expectEqualStrings(
        "staying: 5",
        staying_window.app.tree_ptr.?.nodes.items[0].kind.label.text,
    );
    const next = try staying_window.app.frame(2, .{ .width = 260, .height = 170 });
    try std.testing.expectEqualStrings("staying: 8", next.tree.nodes.items[0].kind.label.text);
    try std.testing.expect(try host.closeWindow(staying));
}

test "api-w07 a popup needs a parent, blocks its parent's close, and reports the native parent" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    // A menu or tooltip popup is a popup of a parent; an orphan one has no
    // meaning on any platform, so it is refused rather than created.
    try std.testing.expectError(error.MissingParent, host.openWindow(.{
        .title = "orphan menu",
        .width = 120,
        .height = 80,
        .kind = .menu,
    }));
    const parent = try host.openWindow(.{ .title = "parent", .width = 300, .height = 200 });
    // A popup cannot be maximized or fullscreen: those are toplevel states and
    // SDL has no way to honour both.
    try std.testing.expectError(error.InvalidPopupState, host.openWindow(.{
        .title = "maximized menu",
        .width = 120,
        .height = 80,
        .kind = .menu,
        .parent = parent,
        .maximized = true,
    }));
    // The two refusals above happen before any native call, so they hold on
    // every driver. Creating the popup itself is a platform question: SDL's
    // dummy driver has no window hierarchy and cannot create a popup at all,
    // so that refusal is a DIFFERENT outcome and is checked as one.
    const menu = host.openWindow(.{
        .title = "menu",
        .width = 120,
        .height = 80,
        .kind = .menu,
        .parent = parent,
    }) catch {
        // The refusal is the platform's, and it is not the same outcome as a
        // missing parent or an impossible popup state: those two are this
        // host's rules, checked above before any native call.
        try std.testing.expect(!host.capabilities().hierarchy);
        _ = try host.closeWindow(parent);
        return;
    };
    const parent_window = try host.getWindow(parent);
    const menu_window = try host.getWindow(menu);
    // The accepted configuration is recorded, so a caller can read back what
    // this window was opened as rather than what it hoped to be.
    try std.testing.expectEqual(contracts.Kind.menu, menu_window.requested.kind);
    try std.testing.expectEqual(parent, menu_window.requested.parent.?);
    try std.testing.expectEqual(contracts.Kind.normal, parent_window.requested.kind);
    try std.testing.expectEqual(@as(?contracts.WindowHandle, null), parent_window.requested.parent);
    // The recorded native parent is the platform's own reading, not a copy of
    // the options that produced it.
    const platform_parent = menu_window.native.sdl.getParent();
    const platform_id: ?sdl3.video.WindowId = if (platform_parent) |native| native.getId() catch null else null;
    try std.testing.expectEqual(platform_id, menu_window.observedParent());
    if (platform_id) |id| {
        try std.testing.expectEqual(parent_window.native.id, id);
        // A platform that keeps the relationship is one this host can offer
        // popups on, and a platform that drops it says so up front.
        try std.testing.expect(host.capabilities().hierarchy);
    } else {
        try std.testing.expect(!host.capabilities().hierarchy);
    }
    try std.testing.expectEqual(@as(?sdl3.video.WindowId, null), parent_window.observedParent());
    // A parent cannot be closed out from under a live popup: that is what
    // would leave a half-destroyed window behind.
    try std.testing.expectError(error.ChildWindowsOpen, host.closeWindow(parent));
    _ = try host.getWindow(parent);
    try std.testing.expect(try host.closeWindow(menu));
    try std.testing.expect(try host.closeWindow(parent));
}

fn displayInfo(id: u32, primary: bool, width: u32, height: u32, scale: f32) display.Info {
    return .{
        .id = @enumFromInt(id),
        .primary = primary,
        .full_bounds = .{
            .position = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        },
        .work_bounds = .{
            .position = .{ .x = 0, .y = 24 },
            .size = .{ .width = width, .height = height - 24 },
        },
        .content_scale = scale,
    };
}

test "api-w07 a display change is measured against the previous reading" {
    // No window and no compositor: this is the classification the host applies
    // to every display event, checked on its own so a scale or bounds change
    // cannot be reported as "something happened".
    const before = displayInfo(1, true, 1920, 1080, 1.0);
    // An unchanged reading is no delta at all, in either direction, and that
    // is the whole point of diffing rather than reporting "something happened".
    try std.testing.expect(display.diff(before, before).none());
    try std.testing.expect(display.diff(null, null).none());
    try std.testing.expect(display.diff(null, before).added);
    try std.testing.expect(display.diff(before, null).removed);
    // A display already known stays known: seeing it again reports the CHANGE,
    // not a second addition, even when nothing about it moved.
    const scaled_later = displayInfo(1, true, 1920, 1080, 2.0);
    const scaled = display.diff(before, scaled_later);
    try std.testing.expect(scaled.scale_changed);
    try std.testing.expect(!scaled.added);
    try std.testing.expect(!scaled.geometry());
    const moved = display.diff(before, displayInfo(1, true, 2560, 1440, 1.0));
    try std.testing.expect(moved.full_bounds_changed and moved.work_bounds_changed);
    try std.testing.expect(moved.geometry());
    try std.testing.expect(!moved.scale_changed);
    const promoted = display.diff(before, displayInfo(1, false, 1920, 1080, 1.0));
    try std.testing.expect(promoted.primary_changed);
    try std.testing.expect(!promoted.geometry());
    // A work-area change alone is a geometry change and does not pretend to be
    // a scale change, because a caller re-arms different work for each.
    const panel = displayInfo(1, true, 1920, 1080, 1.0);
    var docked = panel;
    docked.work_bounds = .{
        .position = .{ .x = 0, .y = 48 },
        .size = .{ .width = 1920, .height = 1032 },
    };
    const panel_delta = display.diff(panel, docked);
    try std.testing.expect(panel_delta.work_bounds_changed);
    try std.testing.expect(!panel_delta.full_bounds_changed);
    try std.testing.expect(panel_delta.geometry());
}

test "api-w07 a live display event carries the measured reading and re-arms layout" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const primary = try display.primary();
    // The host enumerated the desktop at startup, so a caller can read the
    // displays without asking SDL a second time, and the reading it holds is
    // the one SDL reports right now.
    const listed = host.displayList();
    try std.testing.expect(listed.len > 0);
    var found = false;
    for (listed) |info| {
        if (info.id == primary) {
            found = true;
            // The reading the host holds is the one SDL reports now, field by
            // field, so a stale cache would show up as a mismatch.
            const live = try display.query(primary);
            try std.testing.expectEqual(live.primary, info.primary);
            try std.testing.expectEqual(live.content_scale, info.content_scale);
            try std.testing.expectEqual(live.full_bounds.size.width, info.full_bounds.size.width);
            try std.testing.expectEqual(live.full_bounds.size.height, info.full_bounds.size.height);
            try std.testing.expectEqual(live.work_bounds.size.width, info.work_bounds.size.width);
            try std.testing.expectEqual(live.work_bounds.size.height, info.work_bounds.size.height);
        }
    }
    try std.testing.expect(found);
    const held_scale = for (listed) |info| {
        if (info.id == primary) break info.content_scale;
    } else unreachable;
    const handle = try host.openWindow(.{
        .title = "dpi",
        .width = 300,
        .height = 200,
        .display = primary,
    });
    const managed = try host.getWindow(handle);
    try std.testing.expectEqual(primary, managed.observed.display);
    try std.testing.expectEqual(primary, host.displays.primary().?);
    // Settle the window's demand, then let a content-scale event arrive.
    settle(managed);
    try std.testing.expect(!managed.demand.pending(sdl3.timer.getMillisecondsSinceInit()));
    const raw: sdl3.events.Event = .{ .display_content_scale_changed = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .display = display.toNative(primary),
    } };
    const routed = (try host.dispatch(&raw)).?;
    const change = routed.display;
    try std.testing.expectEqual(primary, change.id);
    try std.testing.expectEqual(Application.DisplayChangeKind.scale, change.kind);
    // The event carries a reading, and a delta measured against the reading
    // the host held before it. Nothing moves on a headless display, so the
    // honest answer is an empty scale delta with the reading still published;
    // the delta is what says which of the two it was.
    try std.testing.expect(change.current != null);
    try std.testing.expectEqual(held_scale, change.current.?.content_scale);
    try std.testing.expectEqual(held_scale != change.current.?.content_scale, change.delta.scale_changed);
    try std.testing.expect(!change.delta.removed and !change.delta.added);
    try std.testing.expect(!change.delta.geometry());
    try std.testing.expect(managed.demand.pending(sdl3.timer.getMillisecondsSinceInit()));
    // A per-window scale change keeps pointer and render coordinates aligned:
    // the observed logical size, the observed pixel size and the reported
    // scale are one measurement taken together.
    const scale: nogui.geometry.PixelScale = try managed.observed.pixelScale();
    const point = scale.windowToDevice(.{ .x = 4, .y = 6 });
    try std.testing.expect(point.x >= 0 and point.y >= 0);
    try std.testing.expectEqual(
        managed.observed.display_scale,
        try managed.native.sdl.getDisplayScale(),
    );
    const extent = try managed.native.pixelExtent();
    try std.testing.expectEqual(extent.width, managed.observed.pixels.width);
    try std.testing.expectEqual(extent.height, managed.observed.pixels.height);
    try std.testing.expect(try host.closeWindow(handle));
}

test "api-w07 a routed window event reports a MEASURED scale change, not the event tag" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const handle = try host.openWindow(.{
        .title = "scale-route",
        .width = 300,
        .height = 200,
    });
    const managed = try host.getWindow(handle);
    // Nothing below moves the scale, so every routed event must report that
    // the scale did NOT move. A host that answered this field from the SDL
    // tag instead of from the reading it diffed would report `true` for the
    // second event, and a consumer that re-rasterizes glyphs on this bit
    // would redo the work for a scale that never changed.
    const resized: sdl3.events.Event = .{ .window_resized = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .id = managed.native.id,
        .width = 420,
        .height = 260,
    } };
    // A different client size at an unchanged ratio is a resize, not a
    // scale transition — the same distinction `display.Delta.scale_changed`
    // draws for a display reading.
    const resize_event = (try host.dispatch(&resized)).?.window;
    try std.testing.expect(resize_event.state_changed);
    try std.testing.expect(!resize_event.scale_changed);

    const scale_event: sdl3.events.Event = .{ .window_display_scale_changed = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .id = managed.native.id,
    } };
    const scale_routed = (try host.dispatch(&scale_event)).?.window;
    try std.testing.expect(scale_routed.state_changed);
    try std.testing.expect(!scale_routed.scale_changed);

    // A window this host does not own produces no event at all, so the field
    // is never computed for a window whose readings it never took.
    var foreign: sdl3.events.Event = resized;
    foreign.window_resized.id = managed.native.id +% 977;
    try std.testing.expect((try host.dispatch(&foreign)) == null);
    try std.testing.expect(try host.closeWindow(handle));
}

test "api-w07 a window's scale baseline is the last reading a CONSUMER was given" {
    // The readings one real niri 1 -> 1.25 transition produced, field for
    // field: the window kept its logical box, its pixel box grew with the
    // display scale, and the display's own content scale never moved at all.
    // That last one is why the display route could report no scale delta of
    // its own, and why the window route was the only place left to tell the
    // transition to anybody.
    const output: contracts.DisplayId = @enumFromInt(3);
    const at_one: ScaleReading = .{
        .display = output,
        .display_scale = 1.0,
        .size = .{ .width = 900, .height = 620 },
        .pixels = .{ .width = 900, .height = 620 },
    };
    const at_one_and_a_quarter: ScaleReading = .{
        .display = output,
        .display_scale = 1.25,
        .size = .{ .width = 900, .height = 620 },
        .pixels = .{ .width = 1125, .height = 775 },
    };
    // A display event and a resume both re-read a window without reaching a
    // consumer, so neither one is a `measure` call. The window's own event is
    // the first thing the host hands out after them, and it carries the
    // reading those probes had already taken, so it can only answer "the
    // scale moved" while the baseline is still the reading a consumer was
    // last given.
    var notice: ScaleNotice = .{ .reported = at_one };
    try std.testing.expect(notice.measure(at_one_and_a_quarter));
    // One transition is told once. The compositor's second per-window event
    // for the same change finds the reading this one already published.
    try std.testing.expect(!notice.measure(at_one_and_a_quarter));
    // A different pixel box at the same ratio is a resize, and reporting it
    // would re-rasterize glyphs for a scale that never moved.
    try std.testing.expect(!notice.measure(.{
        .display = output,
        .display_scale = 1.25,
        .size = .{ .width = 1000, .height = 700 },
        .pixels = .{ .width = 1250, .height = 875 },
    }));
    // Back to 1.0 is a transition the other way, and it is measured against
    // what the consumer was last told rather than against the previous
    // event's tag.
    try std.testing.expect(notice.measure(at_one));
    // A window another output draws is a different device scale, whatever the
    // numbers happen to say.
    try std.testing.expect(notice.measure(.{
        .display = @enumFromInt(4),
        .display_scale = 1.0,
        .size = .{ .width = 900, .height = 620 },
        .pixels = .{ .width = 1800, .height = 1240 },
    }));
    // A reading with no client area has no ratio to compare, so it is not a
    // scale change. It is still the reading the next event is measured
    // against, which is what leaves a collapse to `divergence` instead.
    try std.testing.expect(!notice.measure(.{
        .display = @enumFromInt(4),
        .display_scale = 1.0,
        .size = .{ .width = 0, .height = 0 },
        .pixels = .{ .width = 0, .height = 0 },
    }));
    try std.testing.expectEqual(contracts.Size{ .width = 0, .height = 0 }, notice.reported.size);
}

test "api-w07 a display event re-reads a window and leaves its scale question open" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const primary = try display.primary();
    const handle = try host.openWindow(.{
        .title = "dpi-precedence",
        .width = 300,
        .height = 200,
        .display = primary,
    });
    const managed = try host.getWindow(handle);
    // An open publishes its reading, and that reading is the baseline every
    // later routed window event is measured against.
    const at_open = managed.scale_notice.reported;
    try std.testing.expectEqual(ScaleReading.capture(managed.observed), at_open);
    settle(managed);

    // A display event re-reads every window that display draws, so the window
    // sees the output's new reading before its own event arrives. That
    // re-read reaches no consumer, so it must not answer the window's scale
    // question and must not move its baseline; the window's own event stays
    // the first thing a consumer is told, and has to be able to say the scale
    // moved.
    const display_event: sdl3.events.Event = .{ .display_moved = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .display = display.toNative(primary),
    } };
    const re_read = (try host.dispatch(&display_event)).?.display;
    try std.testing.expectEqual(primary, re_read.id);
    try std.testing.expectEqual(Application.DisplayChangeKind.geometry, re_read.kind);
    try std.testing.expect(!re_read.delta.added and !re_read.delta.removed);
    // The display's own answer is still published, and it still re-arms the
    // window's layout.
    try std.testing.expect(re_read.current != null);
    try std.testing.expect(managed.demand.pending(sdl3.timer.getMillisecondsSinceInit()));
    // The display route re-read the window and published nothing, so the
    // baseline is still the one a consumer was last given.
    try std.testing.expectEqual(at_open, managed.scale_notice.reported);

    // The window's own event is what publishes. No scale can move on a
    // headless display, so the honest answer is still "the scale did not
    // move", and the reading behind that answer is what the next event is
    // measured against.
    const window_event: sdl3.events.Event = .{ .window_display_scale_changed = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .id = managed.native.id,
    } };
    const published = (try host.dispatch(&window_event)).?.window;
    try std.testing.expect(published.state_changed);
    try std.testing.expect(!published.scale_changed);
    // The window event is the thing that publishes, so the baseline now
    // describes the reading this event carried.
    const at_window_event = managed.scale_notice.reported;
    try std.testing.expectEqual(ScaleReading.capture(managed.observed), at_window_event);
    try std.testing.expect(try host.closeWindow(handle));
}

test "api-w07 requested and observed state diverge only where the platform reports" {
    const base: contracts.RequestedState = .{
        .title = "t",
        .size = .{ .width = 400, .height = 300 },
        .position = .{ .x = 10, .y = 20 },
        .visible = true,
        // Focus is a REQUEST, and a request the platform did not grant is the
        // only kind of focus divergence there is. A base that never asked
        // cannot be disagreed with about it.
        .focused = true,
        .maximized = false,
        .fullscreen = false,
    };
    const seen: contracts.ObservedState = .{
        .size = .{ .width = 400, .height = 300 },
        .pixels = .{ .width = 400, .height = 300 },
        .display = @enumFromInt(0),
        .display_scale = 1,
        .position = .{ .x = 10, .y = 20 },
        .visible = true,
        .occluded = false,
        .focused = true,
        .minimized = false,
        .maximized = false,
        .fullscreen = false,
    };
    try std.testing.expect(contracts.divergence(base, seen) == null);
    // Size is always comparable and outranks everything else.
    var wrong_size = seen;
    wrong_size.size = .{ .width = 640, .height = 300 };
    try std.testing.expectEqual(contracts.Divergence.size, contracts.divergence(base, wrong_size).?);
    wrong_size.size = seen.size;
    wrong_size.position = .{ .x = 99, .y = 20 };
    try std.testing.expectEqual(contracts.Divergence.position, contracts.divergence(base, wrong_size).?);
    wrong_size.position = seen.position;
    wrong_size.visible = false;
    try std.testing.expectEqual(contracts.Divergence.visible, contracts.divergence(base, wrong_size).?);
    wrong_size.visible = seen.visible;
    wrong_size.maximized = true;
    try std.testing.expectEqual(contracts.Divergence.maximized, contracts.divergence(base, wrong_size).?);
    wrong_size.maximized = seen.maximized;
    wrong_size.fullscreen = true;
    try std.testing.expectEqual(contracts.Divergence.fullscreen, contracts.divergence(base, wrong_size).?);
    wrong_size.fullscreen = seen.fullscreen;
    wrong_size.focused = false;
    try std.testing.expectEqual(contracts.Divergence.focused, contracts.divergence(base, wrong_size).?);
    // A platform that cannot report a field cannot produce a disagreement in
    // it. This is the shape that made `minimized` optional.
    wrong_size.focused = seen.focused;
    wrong_size.minimized = null;
    try std.testing.expect(contracts.divergence(base, wrong_size) == null);
    wrong_size.minimized = true;
    try std.testing.expectEqual(contracts.Divergence.minimized, contracts.divergence(base, wrong_size).?);
    // An unasked position is not a divergence either: the host only owns the
    // position once a caller asked for one.
    var unasked = base;
    unasked.position = null;
    try std.testing.expect(contracts.divergence(unasked, seen) == null);
}

test "api-w07 a refused size bound leaves the accepted configuration untouched" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    // A zero bound is never a bound: the platform's own "no limit" answer is
    // reported, and a caller that meant it leaves the option absent.
    try std.testing.expectError(error.InvalidMaximumSize, host.openWindow(.{
        .title = "zero maximum",
        .width = 200,
        .height = 140,
        .maximum_size = .{ .width = 0, .height = 0 },
    }));
    try std.testing.expectError(error.InvalidMaximumSize, host.openWindow(.{
        .title = "inverted bounds",
        .width = 200,
        .height = 140,
        .minimum_size = .{ .width = 400, .height = 300 },
        .maximum_size = .{ .width = 200, .height = 140 },
    }));
    try std.testing.expectEqual(@as(u32, 0), host.window_count);
    const handle = try host.openWindow(.{
        .title = "bounded",
        .width = 320,
        .height = 240,
        .minimum_size = .{ .width = 100, .height = 80 },
        .maximum_size = .{ .width = 640, .height = 480 },
    });
    const managed = try host.getWindow(handle);
    try std.testing.expectEqual(contracts.Size{ .width = 100, .height = 80 }, managed.requested.minimum_size.?);
    try std.testing.expectEqual(contracts.Size{ .width = 640, .height = 480 }, managed.requested.maximum_size.?);
    // The platform is asked what it holds, separately from what was requested.
    const limits = try managed.observedSizeLimits();
    try std.testing.expect(limits.maximum.width >= limits.minimum.width);
    // A bound the accepted configuration cannot satisfy is refused before it
    // reaches the platform, so the recorded limits stay true.
    try std.testing.expectError(error.InvalidMaximumSize, managed.requestMaximumSize(.{ .width = 90, .height = 80 }));
    try std.testing.expectEqual(contracts.Size{ .width = 640, .height = 480 }, managed.requested.maximum_size.?);
    try std.testing.expectError(error.InvalidMinimumSize, managed.requestMinimumSize(.{ .width = 700, .height = 80 }));
    try std.testing.expectEqual(contracts.Size{ .width = 100, .height = 80 }, managed.requested.minimum_size.?);
    // A new minimum still above the recorded maximum is refused the same way.
    try managed.requestMaximumSize(.{ .width = 500, .height = 400 });
    try std.testing.expectEqual(contracts.Size{ .width = 500, .height = 400 }, managed.requested.maximum_size.?);
    try std.testing.expectError(error.InvalidMinimumSize, managed.requestMinimumSize(.{ .width = 520, .height = 80 }));
    try std.testing.expectEqual(contracts.Size{ .width = 100, .height = 80 }, managed.requested.minimum_size.?);
    try std.testing.expect(try host.closeWindow(handle));
}

test "api-w07 the external loop consumes each native event once and never runs the owned loop" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    const handle = try host.openWindow(.{ .title = "external", .width = 240, .height = 160 });
    const managed = try host.getWindow(handle);
    // The caller drives pollEvent/dispatch itself. Nothing here calls run(),
    // so every event below is delivered exactly once by this file's own loop.
    const events = [_]sdl3.events.Event{
        .{ .window_exposed = .{
            .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
            .id = managed.native.id,
            .live_resize = false,
        } },
        .{ .window_resized = .{
            .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
            .id = managed.native.id,
            .width = 512,
            .height = 320,
        } },
        .{ .window_display_scale_changed = .{
            .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
            .id = managed.native.id,
        } },
    };
    // The driver can have queued its OWN window events (expose, show) for the
    // window this test just opened, so the queue is drained first: counting
    // from a non-empty queue would measure the driver, not this loop.
    var drained: usize = 0;
    while (host.pollEvent()) |_| drained += 1;
    var routed: usize = 0;
    for (0..events.len) |index| {
        try sdl3.events.push(events[index]);
    }
    while (host.pollEvent()) |queued| {
        const event = try host.dispatch(&queued);
        if (event) |value| {
            switch (value) {
                .window => |window| {
                    try std.testing.expectEqual(handle, window.handle);
                    routed += 1;
                },
                else => {},
            }
        }
    }
    // Three pushed events, three routes: the drain was empty, the three the
    // test pushed are the three that were routed, and a second pass finds
    // nothing, so no event is handled twice by the same loop.
    try std.testing.expectEqual(@as(usize, 3), routed);
    try std.testing.expect(host.pollEvent() == null);
    try std.testing.expect(host.isRunning());
    // The owned loop never ran, and the application is still open.
    _ = try host.getWindow(handle);
    try std.testing.expectEqual(@as(u32, 1), host.window_count);
    try std.testing.expect(try host.closeWindow(handle));
}

/// A dialog provider that holds the request open, so the host's own window
/// lifetime is the only thing that can resolve it.
const HeldDialogProvider = struct {
    pending: ?dialogs.FileCallback = null,

    fn file(
        _: std.mem.Allocator,
        ctx: *anyopaque,
        _: dialogs.FileOptions,
        callback: dialogs.FileCallback,
    ) anyerror!void {
        const self: *HeldDialogProvider = @ptrCast(@alignCast(ctx));
        self.pending = callback;
    }

    fn message(
        _: std.mem.Allocator,
        _: *anyopaque,
        _: dialogs.MessageOptions,
        callback: dialogs.MessageCallback,
    ) anyerror!void {
        callback.callback(callback.context, .cancelled);
    }
};

const held_dialog_vtable: dialogs.DialogProvider.VTable = .{
    .showFileDialog = HeldDialogProvider.file,
    .showMessageDialog = HeldDialogProvider.message,
};

/// Records the order the host answered in. The answer is only correct if it
/// arrived while the window it names was still whole, and only the order
/// shows that.
const DialogOrder = struct {
    /// `d` is the dialog outcome, `c` the window's own closed report. Only
    /// the first `count` marks are live.
    marks: [8]u8 = [_]u8{'.'} ** 8,
    count: usize = 0,
    outcome: ?dialogs.FileOutcome = null,

    fn onDialog(ctx: ?*anyopaque, outcome: dialogs.FileOutcome) void {
        const self: *DialogOrder = @ptrCast(@alignCast(ctx.?));
        self.note('d');
        if (self.outcome) |*previous| dialogs.deinitFileOutcome(previous);
        self.outcome = outcome;
    }

    fn onWindowClosed(ctx: *anyopaque, _: contracts.WindowHandle) void {
        const self: *DialogOrder = @ptrCast(@alignCast(ctx));
        self.note('c');
    }

    fn note(self: *DialogOrder, mark: u8) void {
        if (self.count >= self.marks.len) return;
        self.marks[self.count] = mark;
        self.count += 1;
    }

    fn deinit(self: *DialogOrder) void {
        if (self.outcome) |*outcome| dialogs.deinitFileOutcome(outcome);
        self.* = undefined;
    }
};

test "api-w07 a closing parent answers its own dialog before the window is torn down" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var provider: HeldDialogProvider = .{};
    host.dialogs.setProvider(.{ .context = &provider, .vtable = &held_dialog_vtable });
    var order: DialogOrder = .{};
    defer order.deinit();
    host.setHooks(.{ .context = &order, .on_closed = DialogOrder.onWindowClosed });

    const handle = try host.openWindow(.{ .title = "dialog parent", .width = 260, .height = 180 });
    const parent_id = (try host.getWindow(handle)).native.id;
    try host.dialogs.showFile(
        .{ .mode = .open_file, .parent_window = parent_id },
        .{ .confirmed = true },
        .{ .context = &order, .callback = DialogOrder.onDialog },
    );
    try std.testing.expectEqual(@as(usize, 1), host.dialogs.pendingCount());

    try std.testing.expect(try host.closeWindow(handle));

    // The dialog resolved as parent_closed, and it resolved before this host
    // reported the window closed: an answer given after the teardown would
    // have reached an owner the platform had already destroyed.
    try std.testing.expectEqual(@as(usize, 2), order.count);
    try std.testing.expectEqualStrings("dc", order.marks[0..2]);
    try std.testing.expectEqual(dialogs.FileOutcome.parent_closed, order.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), host.dialogs.pendingCount());
    try std.testing.expectError(error.StaleWindow, host.getWindow(handle));

    // A native dialog cannot be un-answered, so its completion still arrives.
    // It must reach nobody, and the outcome it carries is the bridge's to
    // free: the test allocator reports a leak if it is not.
    const pending = provider.pending.?;
    pending.callback(pending.context, .{
        .selected = try dialogs.FileSelection.init(
            std.testing.allocator,
            &[_][]const u8{"/tmp/late.zig"},
            null,
        ),
    });
    try std.testing.expectEqual(@as(usize, 2), order.count);
    try std.testing.expectEqual(dialogs.FileOutcome.parent_closed, order.outcome.?);
}

/// What a host consumer actually sees: the drop phases the host routed to it
/// and the process launches the host queued. Which of the two a payload
/// becomes is the whole point of the routing, so one record holds both.
const DropRecord = struct {
    /// Only the first `count` phases are live; `begin` stands in for phases
    /// that never arrived.
    phases: [8]open_url.DropPhase = [_]open_url.DropPhase{.begin} ** 8,
    count: usize = 0,
    handle: ?contracts.WindowHandle = null,
    position: ?[2]f32 = null,
    offer: ?open_url.DropOffer = null,
    launches: usize = 0,
    /// Only the first `launch_len` bytes are live.
    launch_value: [64]u8 = [_]u8{0} ** 64,
    launch_len: usize = 0,

    fn onEvent(ctx: *anyopaque, _: *Application, event: Application.Event) anyerror!void {
        const self: *DropRecord = @ptrCast(@alignCast(ctx));
        switch (event) {
            .drop => |phase| {
                if (self.count < self.phases.len) {
                    self.phases[self.count] = phase.phase;
                    self.count += 1;
                }
                self.handle = phase.handle;
                if (phase.position) |position| self.position = position;
                if (phase.offer) |offer| self.offer = offer;
            },
            .window, .display, .system_wake => {},
        }
    }

    fn onLaunch(ctx: *anyopaque, _: *Application, launch: Application.IncomingLaunch) void {
        const self: *DropRecord = @ptrCast(@alignCast(ctx));
        self.launches += 1;
        self.launch_len = @min(launch.value.len, self.launch_value.len);
        @memcpy(self.launch_value[0..self.launch_len], launch.value[0..self.launch_len]);
    }
};

test "api-w07 window drop phases arrive in order and a windowless drop is still a launch" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var record: DropRecord = .{};
    host.setHooks(.{
        .context = &record,
        .on_event = DropRecord.onEvent,
        .on_incoming_launch = DropRecord.onLaunch,
    });

    const handle = try host.openWindow(.{ .title = "drop", .width = 280, .height = 200 });
    const native_id = (try host.getWindow(handle)).native.id;
    const stamp = sdl3.timer.getNanosecondsSinceInit();
    var drag = [_]sdl3.events.Event{
        .{ .drop_begin = .{
            .common = .{ .timestamp = stamp },
            .window = native_id,
            .source = null,
        } },
        .{ .drop_position = .{
            .common = .{ .timestamp = stamp + 1 },
            .window = native_id,
            .x = 12,
            .y = 24,
            .source = null,
        } },
        .{ .drop_file = .{
            .common = .{ .timestamp = stamp + 2 },
            .window = native_id,
            .x = 12,
            .y = 24,
            .source = null,
            .file_name = "https://example.com/drop.txt",
        } },
        .{ .drop_complete = .{
            .common = .{ .timestamp = stamp + 3 },
            .window = native_id,
            .x = 12,
            .y = 24,
            .source = null,
        } },
    };
    for (&drag) |*raw| {
        const routed = (try host.dispatch(raw)) orelse return error.DropPhaseNotRouted;
        switch (routed) {
            .drop => |phase| try std.testing.expectEqual(handle, phase.handle),
            else => return error.DropPhaseNotRouted,
        }
    }
    // The order SDL reported is the order the consumer saw, and each phase
    // named the window that owns the drag rather than the process.
    try std.testing.expectEqual(@as(usize, 4), record.count);
    try std.testing.expectEqual(open_url.DropPhase.begin, record.phases[0]);
    try std.testing.expectEqual(open_url.DropPhase.position, record.phases[1]);
    try std.testing.expectEqual(open_url.DropPhase.offer, record.phases[2]);
    try std.testing.expectEqual(open_url.DropPhase.complete, record.phases[3]);
    try std.testing.expectEqual(handle, record.handle.?);
    try std.testing.expectEqual([2]f32{ 12, 24 }, record.position.?);
    try std.testing.expectEqual(open_url.DropOfferKind.url, record.offer.?.kind);
    try std.testing.expectEqualStrings("https://example.com/drop.txt", record.offer.?.value);
    try std.testing.expect(!host.drop_tracker.in_progress);
    // A file dropped on a window is that window's business: this host opened
    // nothing, sent nothing to the App, and made no launch of its own.
    try std.testing.expectEqual(@as(usize, 0), record.launches);
    try std.testing.expectEqual(@as(u32, 1), host.window_count);

    // A drop the desktop handed the process rather than a window is unchanged:
    // it is still a launch, and it is still delivered once.
    const launch: sdl3.events.Event = .{ .drop_text = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window = null,
        .x = 0,
        .y = 0,
        .source = null,
        .text = "nogui://open?file=a.txt",
    } };
    _ = try host.dispatch(&launch);
    try std.testing.expectEqual(@as(usize, 1), record.launches);
    try std.testing.expectEqualStrings(
        "nogui://open?file=a.txt",
        record.launch_value[0..record.launch_len],
    );
    try std.testing.expectEqual(@as(usize, 4), record.count);
    try std.testing.expectEqual(@as(u32, 1), host.window_count);
}

test "api-w07 a drag over a window that died reaches no new owner" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var host = try startHost(&session);
    defer host.deinit();
    var record: DropRecord = .{};
    host.setHooks(.{
        .context = &record,
        .on_event = DropRecord.onEvent,
        .on_incoming_launch = DropRecord.onLaunch,
    });

    const first = try host.openWindow(.{ .title = "first", .width = 220, .height = 160 });
    const first_native = (try host.getWindow(first)).native.id;
    const begin: sdl3.events.Event = .{ .drop_begin = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window = first_native,
        .source = null,
    } };
    _ = try host.dispatch(&begin);
    try std.testing.expectEqual(@as(usize, 1), record.count);
    try std.testing.expect(host.drop_tracker.in_progress);
    try std.testing.expectEqual(
        @as(?sdl3.video.WindowId, first_native),
        host.drop_tracker.active_window,
    );

    try std.testing.expect(try host.closeWindow(first));
    // The window the drag belonged to is gone, so this host is no longer
    // tracking a drag over a window that cannot be addressed at all.
    try std.testing.expect(!host.drop_tracker.in_progress);
    try std.testing.expectEqual(@as(?sdl3.video.WindowId, null), host.drop_tracker.active_window);

    // The completion of that drag names a native window this host destroyed,
    // so it reaches nobody.
    const complete: sdl3.events.Event = .{ .drop_complete = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window = first_native,
        .x = 5,
        .y = 6,
        .source = null,
    } };
    try std.testing.expect((try host.dispatch(&complete)) == null);
    try std.testing.expectEqual(@as(usize, 1), record.count);

    // The released slot is reused by a new owner, and SDL can hand the new
    // window the native ID the old one had. A phase SDL queued before this
    // window existed belongs to the window that is gone, so it must not be
    // read as this owner's drop.
    const second = try host.openWindow(.{ .title = "second", .width = 230, .height = 170 });
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.generation != second.generation);
    const second_native = (try host.getWindow(second)).native.id;
    const stale: sdl3.events.Event = .{ .drop_file = .{
        .common = .{ .timestamp = 0 },
        .window = second_native,
        .x = 0,
        .y = 0,
        .source = null,
        .file_name = "/tmp/queued-for-the-old-window.zig",
    } };
    try std.testing.expect((try host.dispatch(&stale)) == null);
    try std.testing.expectEqual(@as(usize, 1), record.count);
    try std.testing.expectEqual(@as(usize, 0), record.launches);

    // A phase SDL sends now still reaches the window that holds the ID.
    const live: sdl3.events.Event = .{ .drop_begin = .{
        .common = .{ .timestamp = sdl3.timer.getNanosecondsSinceInit() },
        .window = second_native,
        .source = null,
    } };
    const routed = (try host.dispatch(&live)) orelse return error.DropPhaseNotRouted;
    switch (routed) {
        .drop => |phase| try std.testing.expectEqual(second, phase.handle),
        else => return error.DropPhaseNotRouted,
    }
    try std.testing.expectEqual(@as(usize, 2), record.count);
    try std.testing.expect(try host.closeWindow(second));
}
