//! Width-dependent children over `nogui.container_query`.
//!
//! A responsive layout is the case this widget exists for: the box is laid out
//! first, and only then does the application learn how wide it actually got and
//! pick its children. A container query is that decision point. It is not a
//! breakpoint helper bolted on top of a finished tree — the children are built
//! AFTER the parent's layout, and what they build cannot resize what is
//! already laid out.
//!
//! What this example mounts, and then checks at five window widths:
//!
//!   1. An OUTER query on a declared width boundary. It picks one of two
//!      labels from the width layout gave it, and that label is the only
//!      thing the committed tree contains.
//!   2. A NESTED query inside the outer's branch, on its own boundary, sized
//!      as a percentage of the outer's CONTENT box. Its width is a function of
//!      the outer's measured width, not of the window.
//!   3. That a late-built child far taller than its query changes neither the
//!      query's laid-out size, nor the position of the sibling laid out after
//!      it, nor the root's height. The child is really built: it is really
//!      900px tall, inside a 30px query.
//!
//! Every check is against the COMMITTED tree, read back after the frame, not
//! against what the payload believes it built.
//!
//! Run it: `zig build run-parity-query-consumer`. Headless, no window.
const std = @import("std");

const nogui = @import("nogui");
const container_query = nogui.container_query;
const App = nogui.App;
const DrawCtx = nogui.DrawCtx;
const Session = nogui.Session;
const FrameNodeId = nogui.FrameNodeId;
const Size = nogui.Size;

/// The width at which the outer query switches branch.
const outer_threshold: f32 = 100;
/// The width at which the nested query switches branch.
const inner_threshold: f32 = 50;
/// The height the outer query is declared with. The late child asks for more.
const outer_height: f32 = 30;
/// The height the late child asks for, and must not get to keep.
const tall_child_height: f32 = 900;
/// The height the root column is declared with.
const root_height: f32 = 40;

/// What one frame observed, written by the payloads and read back by `main`.
/// The App keeps the frame alive while the scenario reads it, so the frame node
/// ids in here address the committed tree and nothing else.
pub const Observation = struct {
    root_node: FrameNodeId = .root,
    outer_node: FrameNodeId = .root,
    outer_label: FrameNodeId = .root,
    tall_child: FrameNodeId = .root,
    inner_node: FrameNodeId = .root,
    inner_label: FrameNodeId = .root,
    sibling: FrameNodeId = .root,

    outer_builds: usize = 0,
    inner_builds: usize = 0,
    /// The laid-out size the outer query was handed by the parent.
    outer_seen: Size = .{ .width = 0, .height = 0 },
    /// The laid-out size the nested query was handed by the outer query.
    inner_seen: Size = .{ .width = 0, .height = 0 },
    outer_branch: []const u8 = "",
    inner_branch: []const u8 = "",
};

/// The outer query's payload: branch on the measured width, build exactly one
/// label for it, add an oversized late child, and nest a second query.
const Outer = struct {
    report: *Observation,
    /// The window width the consumer declared, carried in so the payload can
    /// check that what it was handed is what it asked for.
    declared_width: f32,

    pub fn build(self: *const Outer, size: Size, ctx: *DrawCtx) !void {
        self.report.outer_builds += 1;
        self.report.outer_seen = size;
        self.report.outer_branch = if (size.width >= outer_threshold) "outer-wide" else "outer-narrow";
        if (size.width != self.declared_width) return error.OuterQueryWidthIsNotDeclared;
        self.report.outer_label = try ctx.label(.{ .text = self.report.outer_branch, .height = 8 });
        // Built after the query's own layout. It must not resize anything.
        self.report.tall_child = try ctx.label(.{
            .text = "tall",
            .height = tall_child_height,
            // Shrink is off so the child KEEPS its declared height inside a
            // 30px query. With the default shrink it would be compressed to
            // fit, which would test the flex rule rather than the claim this
            // example makes: a late child overflows instead of resizing the
            // query it was built into.
            .shrink = 0,
        });
        self.report.inner_node = try container_query.query(Inner, ctx, .{ .report = self.report }, .{
            .width = .{ .percent = 0.5 },
            .height = .{ .length = 12 },
        });
    }
};

/// The nested query's payload: the same decision one level down, on a width
/// that is a percentage of the outer's measured content box.
const Inner = struct {
    report: *Observation,

    pub fn build(self: *const Inner, size: Size, ctx: *DrawCtx) !void {
        self.report.inner_builds += 1;
        self.report.inner_seen = size;
        self.report.inner_branch = if (size.width >= inner_threshold) "inner-wide" else "inner-narrow";
        self.report.inner_label = try ctx.label(.{ .text = self.report.inner_branch, .height = 8 });
    }
};

/// The root component. It declares the widths; the queries decide.
pub const QueryView = struct {
    const Self = @This();
    report: *Observation,
    width: f32 = 100,

    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        self.report.root_node = try ctx.column(.{
            .width = .{ .length = self.width },
            .height = .{ .length = root_height },
        });
        self.report.outer_node = try container_query.query(Outer, ctx, .{
            .report = self.report,
            .declared_width = self.width,
        }, .{
            .width = .{ .length = self.width },
            .height = .{ .length = outer_height },
        });
        // Laid out after the query. The 900px child inside the query must not
        // move it.
        self.report.sibling = try ctx.label(.{ .text = "after", .height = 10 });
        ctx.pop();
    }
};

pub const Scenario = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    app: *App,
    view: *QueryView,
    report: *Observation,

    pub fn init(gpa: std.mem.Allocator) !*Scenario {
        const self = try gpa.create(Scenario);
        errdefer gpa.destroy(self);
        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        session.* = try Session.init(gpa);
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = try App.init(gpa, session);
        const report = try gpa.create(Observation);
        errdefer gpa.destroy(report);
        report.* = .{};
        const view = try gpa.create(QueryView);
        errdefer gpa.destroy(view);
        view.* = .{ .report = report };
        self.* = .{
            .gpa = gpa,
            .session = session,
            .app = app,
            .view = view,
            .report = report,
        };
        try app.mountRoot(QueryView, view);
        return self;
    }

    pub fn deinit(self: *Scenario) void {
        const gpa = self.gpa;
        self.app.deinit();
        gpa.destroy(self.view);
        gpa.destroy(self.report);
        self.session.deinit() catch unreachable;
        gpa.destroy(self.session);
        gpa.destroy(self.app);
        gpa.destroy(self);
    }

    /// Resize the window, publish one frame, and return what it observed.
    pub fn observe(self: *Scenario, width: f32, tick: u32) !*Observation {
        self.report.* = .{};
        self.view.width = width;
        _ = try self.app.handle(.{ .resize = .{ .width = width, .height = 160 } });
        const output = (try self.app.handle(.{ .frame = .{ .tick = tick, .time_ms = tick * 16 } })) orelse
            return error.MissingFrameOutput;
        if (output.json) |json| self.session.gpa.free(json);
        return self.report;
    }

    /// The committed tree. The App publishes it and keeps it until the frame
    /// two frames later replaces it, which is longer than this scenario lives.
    fn tree(self: *const Scenario) !*const nogui.WidgetTree {
        return self.app.tree_ptr orelse error.MissingCommittedTree;
    }

    fn rect(self: *const Scenario, id: FrameNodeId) !nogui.Rect {
        const node = (try self.tree()).nodeConst(id) orelse return error.MissingCommittedNode;
        return node.rect;
    }

    /// The text a committed label node actually carries.
    fn labelText(self: *const Scenario, id: FrameNodeId) ![]const u8 {
        const node = (try self.tree()).nodeConst(id) orelse return error.MissingCommittedNode;
        return switch (node.kind) {
            .label => |label| label.text,
            else => error.NotALabelNode,
        };
    }
};

/// Drive the scenario the way a host would, and print the result.
pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const scenario = try Scenario.init(gpa);
    defer scenario.deinit();

    // Even widths only, so half of one is a whole number and the nested
    // query's percentage resolves exactly. 98 and 100 straddle both
    // boundaries: the outer at 100, the nested at 50.
    const widths = [_]f32{ 80, 98, 100, 102, 240 };
    for (widths, 0..) |width, index| {
        const report = try scenario.observe(width, @intCast(index + 1));
        try check(scenario, report, width);
        std.debug.print("window {d:.0}: outer {s} at {d:.0}px, nested {s} at {d:.0}px, query {d:.0}x{d:.0}, tall child {d:.0}px, sibling at y={d:.0}\n", .{
            width,
            report.outer_branch,
            report.outer_seen.width,
            report.inner_branch,
            report.inner_seen.width,
            (try scenario.rect(report.outer_node)).w,
            (try scenario.rect(report.outer_node)).h,
            (try scenario.rect(report.tall_child)).h,
            (try scenario.rect(report.sibling)).y,
        });
    }
}

/// Everything the committed tree must say about one frame.
fn check(scenario: *const Scenario, report: *const Observation, width: f32) !void {
    // Each query ran exactly once. A payload that ran twice would mean the
    // branch decision is not tied to a laid-out box.
    if (report.outer_builds != 1) return error.OuterQueryBuiltMoreThanOnce;
    if (report.inner_builds != 1) return error.NestedQueryBuiltMoreThanOnce;

    const outer = try scenario.rect(report.outer_node);
    const inner = try scenario.rect(report.inner_node);
    const sibling = try scenario.rect(report.sibling);
    const root = try scenario.rect(report.root_node);
    const tall = try scenario.rect(report.tall_child);

    // The width the payload was handed is the width the parent committed.
    if (report.outer_seen.width != outer.w) return error.OuterQuerySawAnotherWidth;
    if (outer.w != width) return error.OuterQueryWidthNotAsDeclared;

    // A late child cannot resize the box it was built into, cannot move what
    // was laid out after it, and cannot resize the root.
    if (outer.h != outer_height) return error.LateChildResizedQuery;
    if (sibling.y != outer_height) return error.LateChildMovedSibling;
    if (root.h != root_height) return error.LateChildResizedRoot;
    // The child is not silently dropped either: it is really 900px tall.
    if (tall.h != tall_child_height) return error.TallChildNotBuilt;

    // The nested query is a percentage of the outer's CONTENT box, not of the
    // window, and the width it was handed is the width that was committed.
    if (inner.w != outer.w * 0.5) return error.NestedQueryWidthNotHalf;
    if (report.inner_seen.width != inner.w) return error.NestedQuerySawAnotherWidth;
    if (report.inner_seen.height != inner.h) return error.NestedQuerySawAnotherHeight;

    // The branch each query took follows from the width that was measured,
    // and the label in the committed tree is the one the branch named.
    const expected_outer = if (outer.w >= outer_threshold) "outer-wide" else "outer-narrow";
    if (!std.mem.eql(u8, report.outer_branch, expected_outer)) return error.OuterBranchWrong;
    if (!std.mem.eql(u8, try scenario.labelText(report.outer_label), expected_outer)) {
        return error.OuterBranchNotCommitted;
    }
    const expected_inner = if (inner.w >= inner_threshold) "inner-wide" else "inner-narrow";
    if (!std.mem.eql(u8, report.inner_branch, expected_inner)) return error.InnerBranchWrong;
    if (!std.mem.eql(u8, try scenario.labelText(report.inner_label), expected_inner)) {
        return error.InnerBranchNotCommitted;
    }
}
