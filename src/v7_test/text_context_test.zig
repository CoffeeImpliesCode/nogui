const std = @import("std");
const testing = std.testing;
const nogui = @import("nogui");
const Cpu = @import("nogui_text");
const support = @import("nogui_test");
const fonts = @import("context_test_fonts");
const RealContext = support.TextContext(Cpu);

const View = struct {
    pub fn draw(_: *View, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.row(.{});
        defer ctx.pop();
        _ = try ctx.label(.{ .text = "iii", .key = @as(nogui.ComponentKey, .{ .static = "narrow" }) });
        _ = try ctx.label(.{ .text = "WWW", .key = @as(nogui.ComponentKey, .{ .static = "wide" }) });
    }
};

fn create() !*RealContext {
    return RealContext.create(testing.allocator, .{
        .fonts = &.{.{ .family = "Inter", .bytes = fonts.inter }},
        .default_size = 20,
    });
}

test "api-w25 real-font context measures proportional text through the production frame" {
    const ctx = try create();
    defer ctx.deinit() catch unreachable;
    var view: View = .{};
    try ctx.base.app.mountRoot(View, &view);
    const output = try ctx.base.flushFrame();
    defer if (output.json) |json| testing.allocator.free(json);
    const narrow = try ctx.base.queryKey(.root, .{ .static = "narrow" });
    const wide = try ctx.base.queryKey(.root, .{ .static = "wide" });
    // A fixed character grid would give these strings identical widths.
    try testing.expect(wide.visual_rect.w > narrow.visual_rect.w * 2);
    try testing.expectApproxEqAbs(narrow.visual_rect.h, wide.visual_rect.h, 0.001);
}

test "api-w25 refused model teardown leaves real font leases alive for repair and retry" {
    const ctx = try create();
    var context_live = true;
    defer if (context_live) ctx.deinit() catch unreachable;
    var value: u32 = 17;
    var owner = try ctx.base.session.create(u32, &value);
    var owner_live = true;
    defer if (owner_live) ctx.base.session.release(u32, &owner) catch unreachable;
    const service = ctx.text.textService();
    const face = try service.resolve(.{ .family = "Inter" });
    var layout = try service.layout(testing.allocator, .{
        .content = "a\u{0301} W",
        .style = .{ .font = .{ .handle = face, .size = 20 } },
    });
    var layout_live = true;
    defer if (layout_live) layout.deinit();
    const before = try layout.byteToPosition(layout.content.len, .downstream);
    try testing.expectError(error.LiveModels, ctx.deinit());
    const after = try layout.byteToPosition(layout.content.len, .downstream);
    try testing.expectEqual(before.line, after.line);
    try testing.expectApproxEqAbs(before.x, after.x, 0.001);
    // A refused close must preserve both existing leases and new font queries.
    const metrics = try service.metrics(face, 20);
    try testing.expect(metrics.line_height > 0);
    try testing.expectEqual(@as(?usize, 3), try layout.nextGrapheme(0));
    layout.deinit();
    layout_live = false;
    try ctx.base.session.release(u32, &owner);
    owner_live = false;
    try ctx.deinit();
    context_live = false;
}
