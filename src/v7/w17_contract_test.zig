const std = @import("std");
const animation = @import("animation.zig");
const WidgetId = @import("id.zig").WidgetId;
const IdentityRegistry = @import("identity.zig").IdentityRegistry;

const Registry = animation.Registry;
const Key = animation.Key;
const Step = animation.Step;
const Spec = animation.Spec;

fn expectNear(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "api-w17 sequence eases at boundaries, repeats twice, then presents its endpoint once" {
    const id: WidgetId = .{ .owner = 18, .slot = 1, .generation = 1 };
    const key: Key = .{ .owner = id };
    var animations = Registry.init(std.testing.allocator, id.owner);
    defer animations.deinit();

    var steps = [_]Step{
        .{ .to = 10, .duration_ms = 100, .easing = .linear },
        .{ .to = 20, .duration_ms = 200, .easing = .ease_in },
    };
    try animations.start(key, .{ .from = 0, .steps = &steps, .repeat = .{ .count = 2 } }, 1000);
    steps[1].to = -100;
    try std.testing.expectEqual(@as(?f32, 0), animations.sample(key, 1000));
    try std.testing.expectEqual(@as(?u64, 1000), animations.demand(1000, 16).deadline_ms);
    animations.framePresented(1000);
    try expectNear(5, animations.sample(key, 1050).?);
    try expectNear(10, animations.sample(key, 1100).?);
    try expectNear(10.625, animations.sample(key, 1150).?);
    try expectNear(0, animations.sample(key, 1300).?);
    try expectNear(12.5, animations.sample(key, 1500).?);
    try expectNear(20, animations.sample(key, 1600).?);

    // The final value still needs one successful presentation after a late wake.
    const terminal = animations.demand(1601, 16);
    try std.testing.expect(!terminal.active);
    try std.testing.expectEqual(@as(?u64, 1601), terminal.deadline_ms);
    animations.framePresented(1601);
    const idle = animations.demand(1601, 16);
    try std.testing.expect(!idle.active);
    try std.testing.expectEqual(@as(?u64, null), idle.deadline_ms);
    try expectNear(20, animations.sample(key, 5000).?);
}

test "api-w17 interruption starts at the sampled value and explicit restart uses authored start" {
    const id: WidgetId = .{ .owner = 19, .slot = 3, .generation = 1 };
    const key: Key = .{ .owner = id, .lane = 8 };
    var animations = Registry.init(std.testing.allocator, id.owner);
    defer animations.deinit();

    try animations.start(key, .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 1000, .easing = .linear },
    } }, 0);
    animations.framePresented(0);
    try expectNear(0.25, animations.sample(key, 250).?);
    try animations.interrupt(key, .{ .from = 999, .steps = &.{
        .{ .to = 0, .duration_ms = 500, .easing = .ease_out },
    } }, 250);
    try expectNear(0.25, animations.sample(key, 250).?);
    try expectNear(0.0625, animations.sample(key, 500).?);
    try expectNear(0, animations.sample(key, 750).?);

    try animations.start(key, .{ .from = 2, .steps = &.{
        .{ .to = 4, .duration_ms = 100, .easing = .linear },
    } }, 760);
    try expectNear(2, animations.sample(key, 760).?);
    try animations.transition(key, .{
        .from_if_absent = -9,
        .to = 4,
        .duration_ms = 100,
        .easing = .linear,
        .now_ms = 810,
    });
    try expectNear(3, animations.sample(key, 810).?);
    try animations.transition(key, .{
        .from_if_absent = -9,
        .to = 0,
        .duration_ms = 100,
        .easing = .linear,
        .now_ms = 810,
    });
    try expectNear(3, animations.sample(key, 810).?);
    try expectNear(1.5, animations.sample(key, 860).?);

    try animations.start(key, .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 100, .easing = .ease_in_out },
    } }, 900);
    try expectNear(0.125, animations.sample(key, 925).?);
    try expectNear(0.875, animations.sample(key, 975).?);
}

test "api-w17 exponential hover and press preserve prior one-pole response until finite endpoint" {
    const id: WidgetId = .{ .owner = 20, .slot = 3, .generation = 1 };
    const press: Key = .{ .owner = id, .lane = 1 };
    const hover: Key = .{ .owner = id, .lane = 2 };
    var animations = Registry.init(std.testing.allocator, id.owner);
    defer animations.deinit();

    try animations.transition(press, .{
        .from_if_absent = 0,
        .to = 0,
        .duration_ms = 800,
        .easing = .{ .exponential = 8 },
        .now_ms = 0,
    });
    try std.testing.expectEqual(@as(?u64, null), animations.demand(0, 16).deadline_ms);

    try animations.transition(press, .{
        .from_if_absent = 0,
        .to = 1,
        .duration_ms = 800,
        .easing = .{ .exponential = 8 },
        .now_ms = 0,
    });
    try animations.transition(hover, .{
        .from_if_absent = 0,
        .to = 1,
        .duration_ms = 1440,
        .easing = .{ .exponential = 8 },
        .now_ms = 0,
    });
    try expectNear(0.63212055, animations.sample(press, 100).?);
    try expectNear(0.8646647, animations.sample(press, 200).?);
    try expectNear(0.42624658, animations.sample(hover, 100).?);
    try animations.transition(press, .{
        .from_if_absent = 0,
        .to = 0,
        .duration_ms = 800,
        .easing = .{ .exponential = 8 },
        .now_ms = 200,
    });
    try expectNear(0.31809238, animations.sample(press, 300).?);
    try expectNear(0, animations.sample(press, 1000).?);
    animations.framePresented(1000);
    try std.testing.expect(!animations.demand(1500, 16).active);
}

test "api-w17 owner retirement and frame reorder retain only live widget generations" {
    var identities = IdentityRegistry.init(std.testing.allocator);
    defer identities.deinit();
    var animations = Registry.init(std.testing.allocator, identities.owner);
    defer animations.deinit();

    try identities.beginFrame();
    const first = try identities.widget(.root, .{ .static = "first" });
    _ = try identities.widget(.root, .{ .static = "second" });
    identities.commitFrame();
    const key: Key = .{ .owner = first };
    try animations.start(key, .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 100, .easing = .linear },
    } }, 0);
    animations.framePresented(0);

    try identities.beginFrame();
    _ = try identities.widget(.root, .{ .static = "second" });
    const reordered = try identities.widget(.root, .{ .static = "first" });
    identities.commitFrame();
    animations.pruneDead(&identities);
    try std.testing.expect(first.eql(reordered));
    try expectNear(0.5, animations.sample(key, 50).?);

    try identities.beginFrame();
    _ = try identities.widget(.root, .{ .static = "second" });
    identities.commitFrame();
    animations.pruneDead(&identities);
    try std.testing.expectEqual(@as(?f32, null), animations.sample(key, 75));
    try std.testing.expectEqual(@as(?u64, null), animations.demand(75, 16).deadline_ms);

    try identities.beginFrame();
    const remounted = try identities.widget(.root, .{ .static = "first" });
    identities.commitFrame();
    try std.testing.expect(!first.eql(remounted));
    try std.testing.expectEqual(@as(?f32, null), animations.sample(.{ .owner = remounted }, 90));
}

test "api-w17 two window registries reject cross-window starts and remove all owner lanes" {
    var first_ids = IdentityRegistry.init(std.testing.allocator);
    defer first_ids.deinit();
    var second_ids = IdentityRegistry.init(std.testing.allocator);
    defer second_ids.deinit();
    try first_ids.beginFrame();
    const first = try first_ids.widget(.root, .{ .static = "status" });
    const sibling = try first_ids.widget(.root, .{ .static = "other" });
    first_ids.commitFrame();
    try second_ids.beginFrame();
    const second = try second_ids.widget(.root, .{ .static = "status" });
    second_ids.commitFrame();

    var first_window = Registry.init(std.testing.allocator, first_ids.owner);
    defer first_window.deinit();
    var second_window = Registry.init(std.testing.allocator, second_ids.owner);
    defer second_window.deinit();
    const spec: Spec = .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 200, .easing = .linear },
    } };
    try first_window.start(.{ .owner = first, .lane = 1 }, spec, 0);
    try first_window.start(.{ .owner = first, .lane = 2 }, spec, 0);
    try first_window.start(.{ .owner = sibling }, spec, 0);
    try std.testing.expectError(error.WrongOwner, second_window.start(.{ .owner = first }, spec, 0));
    try second_window.start(.{ .owner = second }, spec, 100);
    first_window.removeOwner(first);
    try std.testing.expectEqual(@as(?f32, null), first_window.sample(.{ .owner = first, .lane = 1 }, 150));
    try std.testing.expectEqual(@as(?f32, null), first_window.sample(.{ .owner = first, .lane = 2 }, 150));
    try expectNear(0.75, first_window.sample(.{ .owner = sibling }, 150).?);
    try std.testing.expect(first_window.demand(150, 16).active);
    first_window.removeOwner(sibling);
    try std.testing.expectEqual(@as(?u64, null), first_window.demand(150, 16).deadline_ms);
    try expectNear(0.25, second_window.sample(.{ .owner = second }, 150).?);
    try std.testing.expect(second_window.demand(150, 16).active);
}

test "api-w17 reduced motion snaps repeating animation to final step and never loops" {
    const id: WidgetId = .{ .owner = 21, .slot = 2, .generation = 1 };
    const key: Key = .{ .owner = id };
    var animations = Registry.init(std.testing.allocator, id.owner);
    defer animations.deinit();

    try animations.start(key, .{ .from = 0, .steps = &.{
        .{ .to = 10, .duration_ms = 100, .easing = .linear },
        .{ .to = 20, .duration_ms = 100, .easing = .linear },
    }, .repeat = .forever }, 0);
    animations.framePresented(0);
    try expectNear(5, animations.sample(key, 50).?);
    try expectNear(0.5, animations.sample(key, 205).?);
    try std.testing.expect(animations.demand(50, 16).active);
    animations.setReducedMotion(true, 50);
    try expectNear(20, animations.sample(key, 50).?);
    const static_change = animations.demand(50, 16);
    try std.testing.expect(!static_change.active);
    try std.testing.expectEqual(@as(?u64, 50), static_change.deadline_ms);
    animations.framePresented(50);
    try expectNear(20, animations.sample(key, 100_000).?);
    try std.testing.expectEqual(@as(?u64, null), animations.demand(100_000, 16).deadline_ms);

    // Starting a new decorative timeline while disabled still has one static endpoint frame.
    try animations.start(key, .{ .from = 0, .steps = &.{
        .{ .to = 7, .duration_ms = 100, .easing = .linear },
    }, .repeat = .forever }, 100_000);
    try expectNear(7, animations.sample(key, 100_000).?);
    try std.testing.expectEqual(@as(?u64, 100_000), animations.demand(100_000, 16).deadline_ms);
    animations.framePresented(100_000);
    try std.testing.expectEqual(@as(?u64, null), animations.demand(100_100, 16).deadline_ms);
}

test "api-w17 deadlines include a terminal frame and reject invalid plans without replacing state" {
    const id: WidgetId = .{ .owner = 22, .slot = 1, .generation = 1 };
    const key: Key = .{ .owner = id };
    var animations = Registry.init(std.testing.allocator, id.owner);
    defer animations.deinit();

    const valid: Spec = .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 100, .easing = .linear },
    } };
    try animations.start(key, valid, 500);
    animations.framePresented(500);
    try std.testing.expectEqual(@as(?u64, 600), animations.demand(600, 20).deadline_ms);
    try std.testing.expectError(error.InvalidDuration, animations.start(key, .{
        .from = 10,
        .steps = &.{.{ .to = 5, .duration_ms = 0 }},
    }, 550));
    try std.testing.expectError(error.InvalidRepeat, animations.start(key, .{
        .from = 10,
        .steps = valid.steps,
        .repeat = .{ .count = 0 },
    }, 550));
    try std.testing.expectError(error.DurationOverflow, animations.start(key, valid, std.math.maxInt(u64)));
    try expectNear(0.5, animations.sample(key, 550).?);
    // Enabling reduced motion at an already elapsed endpoint still paints it once.
    animations.setReducedMotion(true, 600);
    try std.testing.expectEqual(@as(?u64, 600), animations.demand(600, 20).deadline_ms);
    // A failed presentation cannot consume this terminal frame.
    try std.testing.expectEqual(@as(?u64, 601), animations.demand(601, 20).deadline_ms);
    animations.framePresented(601);
    try std.testing.expectEqual(@as(?u64, null), animations.demand(602, 20).deadline_ms);
}

test "api-w17 an unpresented frame deadline does not retreat on repeated clock reads" {
    const id: WidgetId = .{ .owner = 24, .slot = 1, .generation = 1 };
    const key: Key = .{ .owner = id };
    var animations = Registry.init(std.testing.allocator, id.owner);
    defer animations.deinit();
    try animations.start(key, .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 1000, .easing = .linear },
    } }, 0);
    animations.framePresented(0);
    // Reading the clock cannot postpone a scheduled frame indefinitely.
    try std.testing.expectEqual(@as(?u64, 16), animations.demand(12, 16).deadline_ms);
    try std.testing.expectEqual(@as(?u64, 16), animations.demand(20, 16).deadline_ms);
    animations.framePresented(20);
    try std.testing.expectEqual(@as(?u64, 36), animations.demand(30, 16).deadline_ms);
    animations.removeOwner(id);
    try std.testing.expectEqual(@as(?u64, null), animations.demand(40, 16).deadline_ms);
}

test "api-w17 earliest deadline belongs to the first unfinished channel" {
    const id: WidgetId = .{ .owner = 23, .slot = 1, .generation = 1 };
    var animations = Registry.init(std.testing.allocator, id.owner);
    defer animations.deinit();
    try animations.start(.{ .owner = id, .lane = 1 }, .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 30 },
    } }, 0);
    try animations.start(.{ .owner = id, .lane = 2 }, .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 100 },
    } }, 0);
    animations.framePresented(0);
    try std.testing.expectEqual(@as(?u64, 30), animations.demand(20, 50).deadline_ms);
    animations.framePresented(30);
    try std.testing.expectEqual(@as(?u64, 80), animations.demand(30, 50).deadline_ms);
    animations.framePresented(100);
    try std.testing.expectEqual(@as(?u64, null), animations.demand(101, 50).deadline_ms);
}

test "api-w17 sampling and deadline scans perform no allocation after a keyed start" {
    var identities = IdentityRegistry.init(std.testing.allocator);
    defer identities.deinit();
    try identities.beginFrame();
    const id = try identities.widget(.root, .{ .static = "animated" });
    identities.commitFrame();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var animations = Registry.init(failing.allocator(), identities.owner);
    defer animations.deinit();
    const key: Key = .{ .owner = id };
    try animations.start(key, .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 1000 },
    } }, 0);
    const allocations = failing.allocations;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    for (0..100) |index| {
        const now_ms: u64 = @intCast(index * 10);
        _ = animations.sample(key, now_ms);
        _ = animations.demand(now_ms, 16);
        animations.framePresented(now_ms);
    }
    try animations.transition(key, .{
        .from_if_absent = 0,
        .to = 0,
        .duration_ms = 1000,
        .now_ms = 990,
    });
    try expectNear(0.99, animations.sample(key, 990).?);
    try identities.beginFrame();
    identities.commitFrame();
    animations.pruneDead(&identities);
    try std.testing.expectEqual(@as(?u64, null), animations.demand(1000, 16).deadline_ms);
    try std.testing.expectEqual(allocations, failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "api-w17 interpolation of finite opposite endpoints stays finite" {
    const id: WidgetId = .{ .owner = 24, .slot = 1, .generation = 1 };
    const key: Key = .{ .owner = id };
    var animations = Registry.init(std.testing.allocator, id.owner);
    defer animations.deinit();
    try animations.start(key, .{ .from = -2.0e38, .steps = &.{
        .{ .to = 2.0e38, .duration_ms = 100 },
    } }, 0);
    const halfway = animations.sample(key, 50).?;
    try std.testing.expect(std.math.isFinite(halfway));
    try expectNear(0, halfway);
}

test "api-w17 long sequences own their steps and failed replacement preserves old values" {
    const id: WidgetId = .{ .owner = 25, .slot = 1, .generation = 1 };
    const key: Key = .{ .owner = id };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var animations = Registry.init(failing.allocator(), id.owner);
    defer animations.deinit();
    try animations.start(key, .{ .from = 0, .steps = &.{
        .{ .to = 1, .duration_ms = 100 },
    } }, 0);

    var steps: [17]Step = undefined;
    for (&steps, 0..) |*step, index| {
        step.* = .{ .to = @floatFromInt(index + 1), .duration_ms = 10 };
    }
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, animations.start(key, .{ .from = 0, .steps = &steps }, 0));
    try expectNear(0.5, animations.sample(key, 50).?);

    failing.fail_index = std.math.maxInt(usize);
    try animations.start(key, .{ .from = 0, .steps = &steps }, 0);
    steps[16].to = -100;
    try expectNear(16.5, animations.sample(key, 165).?);
    try expectNear(17, animations.sample(key, 170).?);
    animations.removeOwner(id);
    try std.testing.expectEqual(@as(?f32, null), animations.sample(key, 170));
}

test "api-w17 reducing motion snaps a hovered control before its next frame" {
    const App = @import("app.zig").App;
    const Session = @import("session.zig").Session;
    const DrawCtx = @import("drawctx.zig").DrawCtx;
    const widget = @import("widget.zig");
    const Root = struct {
        const Self = @This();

        pub fn draw(_: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.button(.{
                .key = .{ .static = "hover-target" },
                .label = "Hover target",
                .width = 120,
                .height = 40,
            });
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const first = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse return error.MissingFrame;
    const owner = app.widgetIdForKey(.root, .{ .static = "hover-target" }) orelse return error.MissingOwner;
    const node = first.tree.frameNode(owner) orelse return error.MissingNode;
    const rect = widget.absoluteRect(first.tree, node);
    _ = try app.handle(.{ .mouse_move = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 } });
    _ = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 80 } })) orelse return error.MissingFrame;
    try std.testing.expect(app.hover_alpha > 0 and app.hover_alpha < 1);
    try app.setReducedMotion(true, 80);
    try std.testing.expect(app.reducedMotion());
    try std.testing.expectEqual(@as(f32, 1), app.hover_alpha);
    try std.testing.expect(try session.takeRedraw(app.window));
    _ = (try app.handle(.{ .frame = .{ .tick = 3, .time_ms = 80 } })) orelse return error.MissingFrame;
    try std.testing.expect(!app.animationDemand(80, 16).active);
}

test "api-w17 interrupt rejects an uncommitted owner without redraw or mutation" {
    const App = @import("app.zig").App;
    const Session = @import("session.zig").Session;
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    const never_committed: Key = .{ .owner = .{ .owner = app.widget_identities.owner, .slot = 42, .generation = 1 } };
    try std.testing.expectError(error.UnknownWidget, app.interruptAnimation(never_committed, .{
        .from = 0,
        .steps = &.{.{ .to = 1, .duration_ms = 100 }},
    }, 0));
    try std.testing.expect(!(try session.takeRedraw(app.window)));
    try std.testing.expectEqual(@as(?f32, null), app.animations.sample(never_committed, 1));
}
