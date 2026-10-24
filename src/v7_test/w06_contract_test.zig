const std = @import("std");
const testing = std.testing;
const Context = @import("context.zig").Context;
const nogui = @import("nogui");
const DrawCtx = nogui.DrawCtx;
const Session = nogui.Session;
const event = nogui.event;

const Note = struct {
    bytes: [32]u8 = @splat(0),
    len: usize = 0,
    completed: u32 = 0,
    order: [4]u32 = @splat(0),
    order_len: usize = 0,
};

const View = struct {
    session: *Session,
    note: nogui.WeakModel(Note),
    checked: bool = false,
    selected: ?u32 = null,

    pub fn draw(self: *View, ctx: *DrawCtx) !void {
        _ = try ctx.column(.{});
        defer ctx.pop();
        _ = try ctx.checkbox(.{
            .key = .{ .static = "check" },
            .label = "Save note",
            .value = &self.checked,
            .width = 180,
            .height = 36,
        });
        _ = try ctx.radio(.{
            .key = .{ .static = "choice" },
            .label = "Second",
            .selected = &self.selected,
            .option = 2,
            .width = 180,
            .height = 36,
        });
    }

    pub fn onRoutedEvent(self: *View, context: *event.DispatchContext) void {
        if (context.phase != .target) return;
        const text = switch (context.event.*) {
            .text_input => |input| input.text,
            else => return,
        };
        self.session.update(Note, self.note, text, struct {
            fn copy(note: *Note, value: []const u8) !void {
                if (value.len > note.bytes.len) return error.NoteTooLong;
                @memcpy(note.bytes[0..value.len], value);
                note.len = value.len;
            }
        }.copy) catch @panic("test text update failed");
    }
};

const Observation = struct {
    checked: bool,
    selected: bool,
    focus_check: bool,
    focus_choice: bool,
    note: [32]u8,
    len: usize,
};

const Driver = enum { direct, json };
fn send(ctx: *Context, driver: Driver, input: event.Event, json: []const u8) !void {
    const result = switch (driver) {
        .direct => try ctx.dispatch(input),
        .json => try ctx.dispatchJson(json),
    };
    if (result) |frame| {
        if (frame.json) |bytes| ctx.gpa.free(bytes);
    }
}

fn click(ctx: *Context, driver: Driver, key: []const u8) !void {
    const snapshot = try ctx.queryKey(.root, .{ .static = key });
    const x = snapshot.visual_rect.x + snapshot.visual_rect.w / 2;
    const y = snapshot.visual_rect.y + snapshot.visual_rect.h / 2;
    var line_buf: [192]u8 = undefined;
    const down = try std.fmt.bufPrint(&line_buf, "{{\"type\":\"mouse_down\",\"button\":\"left\",\"x\":{d},\"y\":{d}}}", .{ x, y });
    try send(ctx, driver, .{ .mouse_down = .{ .button = .left, .x = x, .y = y } }, down);
    const up = try std.fmt.bufPrint(&line_buf, "{{\"type\":\"mouse_up\",\"button\":\"left\",\"x\":{d},\"y\":{d}}}", .{ x, y });
    try send(ctx, driver, .{ .mouse_up = .{ .button = .left, .x = x, .y = y } }, up);
}

fn runScript(driver: Driver) ![5]Observation {
    const ctx = try Context.create(testing.allocator, 0x1234);
    var context_live = true;
    defer if (context_live) ctx.deinit() catch unreachable;
    var note_value: Note = .{};
    var note = try ctx.session.create(Note, &note_value);
    var note_live = true;
    defer if (note_live) ctx.session.release(Note, &note) catch unreachable;
    var view: View = .{ .session = &ctx.session, .note = note.weak() };
    try ctx.app.mountRoot(View, &view);

    try send(ctx, driver, .{ .frame = .{ .tick = 1, .time_ms = 0 } }, "{\"type\":\"frame\",\"tick\":1,\"time_ms\":0}");
    var result: [5]Observation = undefined;
    result[0] = try observationFor(ctx, note);
    try click(ctx, driver, "check");
    result[1] = try observationFor(ctx, note);
    var line = "{\"type\":\"text_input\",\"text\":\"alpha\"}".*;
    try send(ctx, driver, .{ .text_input = .{ .text = "alpha" } }, &line);
    @memset(line[0..], 0);
    result[2] = try observationFor(ctx, note);
    try send(ctx, driver, .{ .key_down = .{ .key = .space } }, "{\"type\":\"key_down\",\"key\":\"space\"}");
    result[3] = try observationFor(ctx, note);
    try click(ctx, driver, "choice");
    const handle = try ctx.handleForKey(.root, .{ .static = "check" });
    try send(ctx, driver, .{ .frame = .{ .tick = 2, .time_ms = 25 } }, "{\"type\":\"frame\",\"tick\":2,\"time_ms\":25}");
    try testing.expectError(error.StaleFrame, ctx.query(handle));
    try testing.expect((try ctx.handleForKey(.root, .{ .static = "check" })).widget.eql(handle.widget));
    result[4] = try observationFor(ctx, note);
    try ctx.clock.advanceToMs(35);
    try testing.expectEqual(@as(u64, 2), ctx.app.frame_generation);
    const flushed = try ctx.flushFrame();
    try testing.expectEqual(@as(u32, 3), flushed.frame_number);
    try testing.expectEqual(@as(u64, 35), flushed.time_ms);
    try testing.expectError(error.TimeWentBackwards, ctx.dispatch(.{
        .frame = .{ .tick = 4, .time_ms = 34 },
    }));
    try ctx.clock.advanceBy(1);
    const submillisecond_now = ctx.clock.now();
    const fractional = try ctx.flushFrame();
    try testing.expectEqual(@as(u32, 4), fractional.frame_number);
    try testing.expectEqual(@as(u64, 35), fractional.time_ms);
    try testing.expectEqual(submillisecond_now, ctx.clock.now());
    try ctx.session.release(Note, &note);
    note_live = false;
    try ctx.deinit();
    context_live = false;
    return result;
}

fn observationFor(ctx: *Context, note: nogui.Model(Note)) !Observation {
    var value: Note = .{};
    try ctx.session.read(Note, note, &value, struct {
        fn copy(source: *const Note, output: *Note) !void {
            output.* = source.*;
        }
    }.copy);
    const check = try ctx.queryKey(.root, .{ .static = "check" });
    const choice = try ctx.queryKey(.root, .{ .static = "choice" });
    return .{
        .checked = check.checked orelse return error.MissingCheckboxState,
        .selected = choice.selected orelse return error.MissingRadioState,
        .focus_check = try ctx.focusesKey(.root, .{ .static = "check" }),
        .focus_choice = try ctx.focusesKey(.root, .{ .static = "choice" }),
        .note = value.bytes,
        .len = value.len,
    };
}

test "api-w06 direct and JSON replay have the same model, focus, and selection transitions" {
    const direct = try runScript(.direct);
    const json = try runScript(.json);
    try testing.expectEqualDeep(direct, json);
    try testing.expect(!direct[0].checked);
    try testing.expect(direct[1].checked and direct[1].focus_check);
    try testing.expectEqualStrings("alpha", direct[2].note[0..direct[2].len]);
    try testing.expect(!direct[3].checked and direct[3].focus_check);
    try testing.expect(direct[4].selected and direct[4].focus_choice);
}

const Job = struct {
    value: u32,
    dropped: *u32,
    fn work(self: *Job, _: std.Io) void {
        self.value *= 2;
    }
    fn completed(note: *Note, self: *Job, _: *Session) void {
        note.completed += self.value;
        note.order[note.order_len] = self.value;
        note.order_len += 1;
    }
    pub fn deinit(self: *Job, _: *Session) void {
        self.dropped.* += 1;
    }
};

fn readNote(ctx: *Context, note: nogui.Model(Note)) !Note {
    var result: Note = .{};
    try ctx.session.read(Note, note, &result, struct {
        fn copy(source: *const Note, destination: *Note) !void {
            destination.* = source.*;
        }
    }.copy);
    return result;
}

fn completedCount(ctx: *Context, note: nogui.Model(Note)) !u32 {
    return (try readNote(ctx, note)).completed;
}

test "api-w06 canceled jobs drain, worker deadlines wait, and cleanup checks retained owners" {
    const ctx = try Context.create(testing.allocator, 41);
    var note_value: Note = .{};
    var note = try ctx.session.create(Note, &note_value);
    var drops: u32 = 0;
    var cancelled: Job = .{ .value = 10, .dropped = &drops };
    var handle = try ctx.session.spawnWorker(Job, Note, Job.work, Job.completed, note.weak(), &cancelled, .{});
    try testing.expect(ctx.session.cancelTask(&handle));
    _ = try ctx.runUntilIdle(16);
    try testing.expectEqual(@as(u32, 1), drops);
    const empty = try ctx.session.taskPending();
    try testing.expectEqual(@as(usize, 0), empty.queued + empty.running + empty.ready + empty.ui_timers + empty.cancelled);

    var work: Job = .{ .value = 3, .dropped = &drops };
    _ = try ctx.session.spawnWorker(Job, Note, Job.work, Job.completed, note.weak(), &work, .{ .not_before_ns = 100 });
    _ = try ctx.runUntilIdle(16);
    try testing.expectEqual(@as(u32, 0), try completedCount(ctx, note));
    try testing.expectEqual(@as(?i96, 100), try ctx.session.nextTaskDeadline());
    try ctx.clock.advanceTo(99);
    _ = try ctx.runUntilIdle(16);
    try testing.expectEqual(@as(u32, 0), try completedCount(ctx, note));
    try testing.expectError(error.PendingTasks, ctx.deinit());
    try ctx.clock.advanceTo(100);
    _ = try ctx.runUntilIdle(16);
    const actual = try readNote(ctx, note);
    try testing.expectEqual(@as(u32, 6), actual.completed);
    try testing.expectEqual(@as(u32, 2), drops);
    try testing.expectError(error.LiveModels, ctx.deinit());
    try ctx.session.release(Note, &note);
    try ctx.deinit();
}

test "api-w06 bounded seeded replay reports progress and resumes without losing work" {
    const ctx = try Context.create(testing.allocator, 73);
    var note_value: Note = .{};
    var note = try ctx.session.create(Note, &note_value);
    var drops: u32 = 0;
    var a: Job = .{ .value = 1, .dropped = &drops };
    var b: Job = .{ .value = 2, .dropped = &drops };
    _ = try ctx.session.spawnWorker(Job, Note, Job.work, Job.completed, note.weak(), &a, .{});
    _ = try ctx.session.spawnWorker(Job, Note, Job.work, Job.completed, note.weak(), &b, .{});
    try testing.expectError(error.StepLimitExceeded, ctx.runUntilIdle(1));
    try testing.expectEqual(@as(usize, 1), ctx.last_run.?.steps);
    _ = try ctx.runUntilIdle(16);
    const actual = try readNote(ctx, note);
    try testing.expectEqual(@as(u32, 6), actual.completed);
    try testing.expectEqual(@as(u32, 2), drops);
    try ctx.session.release(Note, &note);
    try ctx.deinit();
}

const SeededOrder = struct { order: [3]u32, first_worker: bool };
fn seededOrder(seed: u64) !SeededOrder {
    const ctx = try Context.create(testing.allocator, seed);
    var note_value: Note = .{};
    var note = try ctx.session.create(Note, &note_value);
    var drops: u32 = 0;
    var first: Job = .{ .value = 1, .dropped = &drops };
    var timer: Job = .{ .value = 7, .dropped = &drops };
    var second: Job = .{ .value = 2, .dropped = &drops };
    _ = try ctx.session.spawnWorker(Job, Note, Job.work, Job.completed, note.weak(), &first, .{});
    _ = try ctx.session.scheduleUi(Job, Note, Job.completed, note.weak(), &timer, 0);
    _ = try ctx.session.spawnWorker(Job, Note, Job.work, Job.completed, note.weak(), &second, .{});
    try testing.expectError(error.StepLimitExceeded, ctx.runUntilIdle(1));
    const first_worker = ctx.last_run.?.worker_steps == 1;
    _ = try ctx.runUntilIdle(16);
    const result = try readNote(ctx, note);
    try testing.expectEqual(@as(usize, 3), result.order_len);
    try testing.expectEqual(@as(u32, 3), drops);
    try ctx.session.release(Note, &note);
    try ctx.deinit();
    return .{
        .order = .{ result.order[0], result.order[1], result.order[2] },
        .first_worker = first_worker,
    };
}

test "api-w06 seed reproduces real worker and UI completion ordering" {
    const first = try seededOrder(0x1234);
    const again = try seededOrder(0x1234);
    try testing.expectEqualDeep(first, again);
    try testing.expectEqual(@as(u32, 2), first.order[if (first.order[0] == 7) 1 else 0]);
    try testing.expectEqual(@as(u32, 4), first.order[if (first.order[2] == 7) 1 else 2]);
    const timer_first = try seededOrder(0);
    const worker_first = try seededOrder(2);
    try testing.expect(!timer_first.first_worker);
    try testing.expect(worker_first.first_worker);
    // A scheduled UI timer may complete before a worker's published result
    // even when the worker executes first; seed controls the work step.
    try testing.expectEqual(@as(u32, 7), timer_first.order[0]);
    try testing.expectEqual(@as(u32, 7), worker_first.order[0]);
}
