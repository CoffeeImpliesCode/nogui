//! Test-support external consumer of the `nogui` package.
//!
//! Drives a deterministic App through `nogui_test`: a virtual clock, a fixed
//! seed, and a scripted JSON input path. The same script always produces the
//! same frame, and a stale query handle is refused after a new frame commits.
const std = @import("std");
const nogui = @import("nogui");
const nogui_test = @import("nogui_test");

const Context = nogui_test.Context;
const DrawCtx = nogui.DrawCtx;

const seed: u64 = 0x5eed_1234;

const Note = struct {
    checked: bool = false,
    label_buf: [32]u8 = @splat(0),

    pub fn draw(self: *Note, ctx: *DrawCtx) anyerror!void {
        const text = try std.fmt.bufPrint(&self.label_buf, "Save: {s}", .{
            if (self.checked) "on" else "off",
        });
        _ = try ctx.label(.{ .text = text });
        _ = try ctx.checkbox(.{
            .key = .{ .static = "save" },
            .label = "Save note",
            .value = &self.checked,
            .width = 160,
            .height = 32,
        });
    }
};

/// Drive one full script and return what the consumer can observe afterwards.
fn runScript(ctx: *Context, note: *Note) !struct { checked: bool, generation: u64 } {
    try ctx.app.mountRoot(Note, note);

    const opened = try ctx.dispatchJson("{\"type\":\"resize\",\"width\":320,\"height\":200}");
    _ = opened;
    const first = try ctx.flushFrame();
    if (first.frame_number != 1) return error.UnexpectedFirstFrameNumber;

    const snapshot = try ctx.queryKey(.root, .{ .static = "save" });
    if (snapshot.kind != .checkbox) return error.SaveTargetIsNotACheckbox;
    if (snapshot.checked orelse return error.CheckboxStateNotObserved)
        return error.CheckboxStartedChecked;

    // A handle taken now must be refused once a newer frame commits.
    const stale = try ctx.handleForKey(.root, .{ .static = "save" });

    const x = snapshot.visual_rect.x + snapshot.visual_rect.w / 2;
    const y = snapshot.visual_rect.y + snapshot.visual_rect.h / 2;
    var line_buf: [192]u8 = undefined;
    const down = try std.fmt.bufPrint(&line_buf, "{{\"type\":\"mouse_down\",\"button\":\"left\",\"x\":{d},\"y\":{d}}}", .{ x, y });
    _ = try ctx.dispatchJson(down);
    const up = try std.fmt.bufPrint(&line_buf, "{{\"type\":\"mouse_up\",\"button\":\"left\",\"x\":{d},\"y\":{d}}}", .{ x, y });
    _ = try ctx.dispatchJson(up);
    if (!note.checked) return error.ClickDidNotToggle;

    try ctx.clock.advanceBy(std.time.ns_per_ms * 5);
    const second = try ctx.flushFrame();
    if (second.time_ms != 5) return error.VirtualClockDidNotAdvance;

    if (ctx.query(stale)) |_| {
        return error.StaleHandleAccepted;
    } else |err| switch (err) {
        error.StaleFrame, error.StaleWidget => {},
        else => return err,
    }
    const fresh = try ctx.queryKey(.root, .{ .static = "save" });
    if (!(fresh.checked orelse return error.QueryLostCheckboxState)) return error.QueryDidNotObserveToggle;

    return .{ .checked = note.checked, .generation = ctx.app.frame_generation };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const ctx = try Context.create(gpa, seed);
    defer ctx.deinit() catch unreachable;

    var note: Note = .{};
    const first = try runScript(ctx, &note);
    try ctx.requireClean();

    // The same script against a fresh context must reach the same state.
    const replay = try Context.create(gpa, seed);
    defer replay.deinit() catch unreachable;
    var replay_note: Note = .{};
    const second = try runScript(replay, &replay_note);
    try replay.requireClean();

    if (first.checked != second.checked or first.generation != second.generation) {
        std.debug.print("script is not deterministic: checked={} gen={d} vs checked={} gen={d}\n", .{
            first.checked,
            first.generation,
            second.checked,
            second.generation,
        });
        return error.NondeterministicScript;
    }

    const line = try std.fmt.allocPrint(gpa, "test_support: OK checked={} generation={d}\n", .{
        first.checked,
        first.generation,
    });
    defer gpa.free(line);
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}

test "api-w26 nogui_test drives a deterministic script twice" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch @panic("leak");
    const gpa = gpa_state.allocator();

    const left = try Context.create(gpa, seed);
    defer left.deinit() catch unreachable;
    var left_note: Note = .{};
    const left_result = try runScript(left, &left_note);
    try left.requireClean();

    const right = try Context.create(gpa, seed);
    defer right.deinit() catch unreachable;
    var right_note: Note = .{};
    const right_result = try runScript(right, &right_note);
    try right.requireClean();

    // The scripted click must reach the model both times, not merely not crash.
    try std.testing.expect(left_result.checked);
    try std.testing.expectEqual(left_result.generation, right_result.generation);
    try std.testing.expectEqual(left_note.checked, right_note.checked);
}
