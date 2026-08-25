const std = @import("std");

const Id = @import("../id.zig").Id;
const layout = @import("root.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

const cases_path = "~/.cache/taffy-v0.13.0-normalized/normalized/cases.json";
const manifest_path = "~/.cache/taffy-v0.13.0-normalized/MANIFEST.json";

const pinned_commit = "45a56299d366ddb383e593a1f0372158d00e8530";
const pinned_repository = "https://github.com/DioxusLabs/taffy";
const pinned_tag = "v0.13.0";
const canonical_id = "leaf/leaf_with_content_and_border.html";
const canonical_source = "test_fixtures/" ++ canonical_id;
const canonical_source_sha256 =
    "f4befcf21719a21b30a7afb2d34ff23f208a0051094d610b6011369f9a9adc55";
const source_prefix = "test_fixtures/";
const ahem_glyph_width: f32 = 10.0;
const ahem_line_height: f32 = 10.0;
const comparison_tolerance: f64 = 0.1;

pub const FixtureSummary = struct {
    passed: usize = 0,
    failed: usize = 0,
    unsupported: usize = 0,
};

pub const FixtureError = error{
    FixtureNotFound,
    InvalidFixture,
} || std.mem.Allocator.Error;

pub const CaseError = FixtureError || error{ Unsupported, LayoutFailed };

pub const Corpus = struct {
    schema: u32,
    cases: []const Case,
};

pub const Case = struct {
    id: []const u8,
    source: []const u8,
    source_sha256: []const u8,
    variant: []const u8,
    grid_feature: bool,
    use_rounding: bool,
    viewport: Size,
    nodes: []const Node,
    expected: []const Rect,
};

const Size = struct {
    width: f64,
    height: f64,
};

const Node = struct {
    kind: []const u8,
    text: ?[]const u8 = null,
    writing_mode: ?[]const u8 = null,
    child_count: usize,
    attributes: ?std.json.Value = null,
    style: LegacyStyle,
};

/// Compatibility data retained because it is part of normalized schema 1.
/// Layout input comes only from `attributes`.
const LegacyStyle = struct {
    direction: []const u8,
    border_top: []const u8,
    border_right: []const u8,
    border_bottom: []const u8,
    border_left: []const u8,
};

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    scroll_width: ?f64 = null,
    scroll_height: ?f64 = null,
};

const Manifest = struct {
    schema: u32,
    upstream_repository: []const u8,
    upstream_tag: []const u8,
    upstream_commit: []const u8,
    generator: []const u8,
    generator_version: u32,
    source_count: usize,
    case_count: usize,
    sources: []const ManifestSource,
    selection: ?Selection = null,
};

const Selection = struct {
    source: []const u8,
    variant: []const u8,
};

const ManifestSource = struct {
    path: []const u8,
    sha256: []const u8,
};

pub fn runAll(
    allocator: std.mem.Allocator,
    filter: ?[]const u8,
) FixtureError!FixtureSummary {
    return runFiltered(allocator, filter, null, 0, null);
}

pub fn runVariant(
    allocator: std.mem.Allocator,
    id: []const u8,
    variant: []const u8,
) FixtureError!FixtureSummary {
    return runFiltered(allocator, id, variant, 0, null);
}
pub fn runRange(
    allocator: std.mem.Allocator,
    start: usize,
    count: usize,
) FixtureError!FixtureSummary {
    return runFiltered(allocator, null, null, start, count);
}

fn runFiltered(
    allocator: std.mem.Allocator,
    filter: ?[]const u8,
    variant: ?[]const u8,
    start: usize,
    count: ?usize,
) FixtureError!FixtureSummary {
    var io_impl = std.Io.Threaded.init(allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const cases_json = try readCorpusFile(allocator, io, cases_path);
    defer allocator.free(cases_json);

    const manifest_json = try readCorpusFile(allocator, io, manifest_path);
    defer allocator.free(manifest_json);

    var parsed_corpus = std.json.parseFromSlice(
        Corpus,
        allocator,
        cases_json,
        .{ .ignore_unknown_fields = false },
    ) catch |parse_error| {
        if (parse_error == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidFixture;
    };
    defer parsed_corpus.deinit();

    var parsed_manifest = std.json.parseFromSlice(
        Manifest,
        allocator,
        manifest_json,
        .{ .ignore_unknown_fields = false },
    ) catch |parse_error| {
        if (parse_error == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidFixture;
    };
    defer parsed_manifest.deinit();

    try validateCorpus(parsed_corpus.value, parsed_manifest.value);
    try validateSelection(parsed_corpus.value.cases, parsed_manifest.value.selection);
    if (count) |maximum| {
        if (maximum == 0) return .{};
    }

    var summary: FixtureSummary = .{};
    var found = false;
    var matched: usize = 0;
    for (parsed_corpus.value.cases) |fixture_case| {
        if (!matchesFilter(fixture_case, filter) or
            !matchesVariant(fixture_case, variant))
        {
            continue;
        }
        if (matched < start) {
            matched += 1;
            continue;
        }
        if (count) |maximum| {
            if (summary.passed + summary.failed + summary.unsupported >= maximum) break;
        }
        matched += 1;
        found = true;

        const passed = runCase(allocator, fixture_case) catch |case_error| {
            switch (case_error) {
                error.Unsupported => {
                    summary.unsupported += 1;
                    continue;
                },
                error.LayoutFailed => {
                    summary.failed += 1;
                    continue;
                },
                error.InvalidFixture => return error.InvalidFixture,
                error.OutOfMemory => return error.OutOfMemory,
                error.FixtureNotFound => unreachable,
            }
        };
        if (passed) {
            summary.passed += 1;
        } else {
            summary.failed += 1;
        }
    }

    if (!found) return error.FixtureNotFound;
    return summary;
}
fn readCorpusFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) FixtureError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .unlimited,
    ) catch |read_error| switch (read_error) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidFixture,
    };
}

fn validateCorpus(corpus: Corpus, manifest: Manifest) FixtureError!void {
    if (corpus.schema != 1) return error.InvalidFixture;
    if (manifest.schema != 1) return error.InvalidFixture;
    if (!std.mem.eql(u8, manifest.upstream_repository, pinned_repository)) {
        return error.InvalidFixture;
    }
    if (!std.mem.eql(u8, manifest.upstream_tag, pinned_tag)) return error.InvalidFixture;
    if (!std.mem.eql(u8, manifest.upstream_commit, pinned_commit)) {
        return error.InvalidFixture;
    }
    if (!std.mem.eql(u8, manifest.generator, "tools/import_taffy_v013_fixtures.py")) {
        return error.InvalidFixture;
    }
    if (manifest.generator_version != 1) return error.InvalidFixture;
    if (manifest.source_count != manifest.sources.len) return error.InvalidFixture;
    if (manifest.case_count != corpus.cases.len) return error.InvalidFixture;
    if (corpus.cases.len == 0) return error.InvalidFixture;

    for (manifest.sources, 0..) |source, source_index| {
        if (!validSha256(source.sha256)) return error.InvalidFixture;
        if (!std.mem.startsWith(u8, source.path, source_prefix)) {
            return error.InvalidFixture;
        }
        for (manifest.sources[0..source_index]) |previous| {
            if (std.mem.eql(u8, previous.path, source.path)) return error.InvalidFixture;
        }
    }

    for (corpus.cases, 0..) |fixture_case, case_index| {
        try validateCaseRecord(fixture_case, manifest.sources);
        for (corpus.cases[0..case_index]) |previous| {
            const same_source = std.mem.eql(u8, previous.source, fixture_case.source);
            const same_variant = std.mem.eql(u8, previous.variant, fixture_case.variant);
            if (same_source and same_variant) return error.InvalidFixture;
        }
    }
}

fn validateSelection(cases: []const Case, selection: ?Selection) FixtureError!void {
    const selected = selection orelse return;
    var matches: usize = 0;
    for (cases) |fixture_case| {
        if (!std.mem.eql(u8, fixture_case.source, selected.source)) continue;
        if (!std.mem.eql(u8, fixture_case.variant, selected.variant)) continue;
        matches += 1;
    }
    if (matches != 1) return error.InvalidFixture;
}

fn validateCaseRecord(fixture_case: Case, sources: []const ManifestSource) FixtureError!void {
    if (!std.mem.startsWith(u8, fixture_case.source, source_prefix)) {
        return error.InvalidFixture;
    }
    if (!std.mem.eql(u8, fixture_case.id, fixture_case.source[source_prefix.len..])) {
        return error.InvalidFixture;
    }
    if (!validSha256(fixture_case.source_sha256)) return error.InvalidFixture;
    if (fixture_case.nodes.len != fixture_case.expected.len) return error.InvalidFixture;
    if (fixture_case.nodes.len == 0) return error.InvalidFixture;

    var source_matches: usize = 0;
    for (sources) |source| {
        if (!std.mem.eql(u8, source.path, fixture_case.source)) continue;
        source_matches += 1;
        if (!std.mem.eql(u8, source.sha256, fixture_case.source_sha256)) {
            return error.InvalidFixture;
        }
    }
    if (source_matches != 1) return error.InvalidFixture;

    if (std.mem.eql(u8, fixture_case.source, canonical_source)) {
        if (!std.mem.eql(u8, fixture_case.source_sha256, canonical_source_sha256)) {
            return error.InvalidFixture;
        }
    }
}

const FixtureResources = struct {
    allocator: std.mem.Allocator,
    grid_track_allocations: std.ArrayList([]const style.GridTrack) = .empty,
    scroll_state_allocations: std.ArrayList(*widget.ScrollState) = .empty,
    scroll_states_by_source: []?*widget.ScrollState,

    fn init(allocator: std.mem.Allocator, source_count: usize) FixtureError!FixtureResources {
        const scroll_states_by_source = try allocator.alloc(?*widget.ScrollState, source_count);
        errdefer allocator.free(scroll_states_by_source);
        for (scroll_states_by_source) |*state| state.* = null;
        return .{
            .allocator = allocator,
            .scroll_states_by_source = scroll_states_by_source,
        };
    }

    fn createScrollState(
        self: *FixtureResources,
        source_index: usize,
    ) CaseError!*widget.ScrollState {
        if (source_index >= self.scroll_states_by_source.len) {
            return error.InvalidFixture;
        }
        if (self.scroll_states_by_source[source_index] != null) {
            return error.InvalidFixture;
        }

        const state = try self.allocator.create(widget.ScrollState);
        errdefer self.allocator.destroy(state);
        state.* = .{};
        try self.scroll_state_allocations.append(self.allocator, state);
        self.scroll_states_by_source[source_index] = state;
        return state;
    }

    fn deinit(self: *FixtureResources) void {
        for (self.grid_track_allocations.items) |tracks| {
            self.allocator.free(tracks);
        }
        self.grid_track_allocations.deinit(self.allocator);
        for (self.scroll_state_allocations.items) |state| {
            self.allocator.destroy(state);
        }
        self.scroll_state_allocations.deinit(self.allocator);
        self.allocator.free(self.scroll_states_by_source);
        self.* = undefined;
    }
};

const FixtureTree = struct {
    tree: widget.WidgetTree,
    source_ids: []Id,
    resources: FixtureResources,

    fn init(allocator: std.mem.Allocator, node_count: usize) CaseError!FixtureTree {
        const source_ids = try allocator.alloc(Id, node_count);
        errdefer allocator.free(source_ids);
        for (source_ids) |*id| id.* = .root;
        var resources = try FixtureResources.init(allocator, node_count);
        errdefer resources.deinit();
        return .{
            .tree = widget.WidgetTree.init(allocator),
            .source_ids = source_ids,
            .resources = resources,
        };
    }

    fn deinit(self: *FixtureTree, allocator: std.mem.Allocator) void {
        self.resources.deinit();
        self.tree.deinit();
        allocator.free(self.source_ids);
        self.* = undefined;
    }
};

const TreeBuilder = struct {
    allocator: std.mem.Allocator,
    fixture_case: Case,
    result: *FixtureTree,
    source_index: usize = 0,

    fn buildRoot(self: *TreeBuilder) CaseError!Id {
        const root_id = try self.buildNode(.root);
        if (self.source_index != self.fixture_case.nodes.len) return error.InvalidFixture;
        return root_id;
    }

    fn buildNode(self: *TreeBuilder, parent: Id) CaseError!Id {
        if (self.source_index >= self.fixture_case.nodes.len) return error.InvalidFixture;
        const index = self.source_index;
        self.source_index += 1;
        if (index >= std.math.maxInt(u32)) return error.InvalidFixture;
        if (index >= self.fixture_case.expected.len) return error.InvalidFixture;
        const id: Id = @enumFromInt(@as(u32, @intCast(index + 1)));
        const fixture_node = self.fixture_case.nodes[index];
        const expected = self.fixture_case.expected[index];
        const node_style = try fixtureStyle(
            &self.result.resources,
            fixture_node,
            self.fixture_case.variant,
        );
        const kind = try fixtureKind(fixture_node, node_style);
        const scroll = try fixtureScrollSpec(&self.result.resources, index, expected);

        var children: std.ArrayList(Id) = .empty;
        defer children.deinit(self.allocator);
        for (0..fixture_node.child_count) |_| {
            try children.append(self.allocator, try self.buildNode(id));
        }

        try self.result.tree.appendNode(.{
            .id = id,
            .kind = kind,
            .parent = parent,
            .style = node_style,
            .scroll = scroll,
        });
        for (children.items) |child_id| {
            try self.result.tree.appendChild(id, child_id);
        }
        self.result.source_ids[index] = id;
        return id;
    }
};

fn fixtureScrollSpec(
    resources: *FixtureResources,
    source_index: usize,
    expected: Rect,
) CaseError!?widget.ScrollSpec {
    const axis = expectedScrollAxis(expected) orelse return null;
    const state = try resources.createScrollState(source_index);
    return .{ .state = state, .axis = axis };
}

fn expectedScrollAxis(expected: Rect) ?widget.ScrollAxis {
    const has_width = expected.scroll_width != null;
    const has_height = expected.scroll_height != null;
    if (!has_width and !has_height) return null;
    if (has_width and has_height) return .both;
    if (has_width) return .horizontal;
    return .vertical;
}

test "fixture builder converts preorder nodes to a linked postorder tree" {
    const legacy: LegacyStyle = .{
        .direction = "ltr",
        .border_top = "0px",
        .border_right = "0px",
        .border_bottom = "0px",
        .border_left = "0px",
    };
    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 1, .style = legacy },
        .{ .kind = "text", .text = "H", .child_count = 0, .style = legacy },
    };
    const expected = [_]Rect{
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    const fixture_case: Case = .{
        .id = "test",
        .source = "test_fixtures/test.html",
        .source_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .variant = "border_box_ltr",
        .grid_feature = false,
        .use_rounding = true,
        .viewport = .{ .width = 100, .height = 100 },
        .nodes = &nodes,
        .expected = &expected,
    };
    var fixture_tree = try FixtureTree.init(std.testing.allocator, nodes.len);
    defer fixture_tree.deinit(std.testing.allocator);
    var builder: TreeBuilder = .{
        .allocator = std.testing.allocator,
        .fixture_case = fixture_case,
        .result = &fixture_tree,
    };
    const root_id = try builder.buildRoot();
    const child_id = fixture_tree.source_ids[1];
    try std.testing.expect(fixture_tree.tree.nodeIndex(child_id).? <
        fixture_tree.tree.nodeIndex(root_id).?);
    const root = fixture_tree.tree.nodeConst(root_id).?;
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(child_id, root.children.items[0]);
    try std.testing.expectEqual(root_id, fixture_tree.tree.nodeConst(child_id).?.parent);
}

test "fixture scroll state allocations remain stable independently" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 41);
    defer fixture_tree.deinit(std.testing.allocator);

    const stable_state = try fixture_tree.resources.createScrollState(0);
    stable_state.max_offset = .{ 3, 5 };
    for (1..fixture_tree.resources.scroll_states_by_source.len) |source_index| {
        _ = try fixture_tree.resources.createScrollState(source_index);
    }

    try std.testing.expectEqual(
        fixture_tree.resources.scroll_states_by_source.len,
        fixture_tree.resources.scroll_state_allocations.items.len,
    );
    try std.testing.expectEqual(
        stable_state,
        fixture_tree.resources.scroll_states_by_source[0].?,
    );
    try std.testing.expectEqual(
        stable_state,
        fixture_tree.resources.scroll_state_allocations.items[0],
    );
    try std.testing.expectEqual(@as(f32, 3), stable_state.max_offset[0]);
    try std.testing.expectEqual(@as(f32, 5), stable_state.max_offset[1]);
    for (fixture_tree.resources.scroll_state_allocations.items[1..]) |allocation| {
        try std.testing.expect(allocation != stable_state);
    }
}

test "fixture builder attaches expected scroll axes without incidental state" {
    const legacy: LegacyStyle = .{
        .direction = "ltr",
        .border_top = "0px",
        .border_right = "0px",
        .border_bottom = "0px",
        .border_left = "0px",
    };
    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 3, .style = legacy },
        .{ .kind = "div", .child_count = 0, .style = legacy },
        .{ .kind = "div", .child_count = 0, .style = legacy },
        .{ .kind = "div", .child_count = 0, .style = legacy },
    };
    const expected = [_]Rect{
        .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .scroll_width = 11,
            .scroll_height = 13,
        },
        .{ .x = 0, .y = 0, .width = 0, .height = 0, .scroll_width = 17 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0, .scroll_height = 19 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    const fixture_case: Case = .{
        .id = "test",
        .source = "test_fixtures/test.html",
        .source_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .variant = "border_box_ltr",
        .grid_feature = false,
        .use_rounding = true,
        .viewport = .{ .width = 100, .height = 100 },
        .nodes = &nodes,
        .expected = &expected,
    };
    var fixture_tree = try FixtureTree.init(std.testing.allocator, nodes.len);
    defer fixture_tree.deinit(std.testing.allocator);
    var builder: TreeBuilder = .{
        .allocator = std.testing.allocator,
        .fixture_case = fixture_case,
        .result = &fixture_tree,
    };
    _ = try builder.buildRoot();

    const expected_axes = [_]?widget.ScrollAxis{
        .both,
        .horizontal,
        .vertical,
        null,
    };
    for (expected_axes, 0..) |expected_axis, source_index| {
        const node = fixture_tree.tree.nodeConst(fixture_tree.source_ids[source_index]).?;
        const owned_state = fixture_tree.resources.scroll_states_by_source[source_index];
        if (expected_axis) |axis| {
            const scroll = node.scroll.?;
            try std.testing.expectEqual(axis, scroll.axis);
            try std.testing.expectEqual(owned_state.?, scroll.state);
        } else {
            try std.testing.expect(node.scroll == null);
            try std.testing.expect(owned_state == null);
        }
    }
    try std.testing.expectEqual(
        @as(usize, 3),
        fixture_tree.resources.scroll_state_allocations.items.len,
    );
}

test "fixture expected scroll offsets remain validated inputs" {
    const legacy: LegacyStyle = .{
        .direction = "ltr",
        .border_top = "0px",
        .border_right = "0px",
        .border_bottom = "0px",
        .border_left = "0px",
    };
    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 0, .style = legacy },
    };
    var expected = [_]Rect{
        .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .scroll_width = 0,
            .scroll_height = 0,
        },
    };
    const fixture_case: Case = .{
        .id = "test",
        .source = "test_fixtures/test.html",
        .source_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .variant = "border_box_ltr",
        .grid_feature = false,
        .use_rounding = true,
        .viewport = .{ .width = 100, .height = 100 },
        .nodes = &nodes,
        .expected = &expected,
    };

    try validateFixtureInputs(fixture_case);
    expected[0].scroll_width = -1;
    try std.testing.expectError(error.InvalidFixture, validateFixtureInputs(fixture_case));
    expected[0].scroll_width = 0;
    expected[0].scroll_height = std.math.inf(f64);
    try std.testing.expectError(error.InvalidFixture, validateFixtureInputs(fixture_case));
}

test "fixture comparison requires matching optional scroll max offsets" {
    const legacy: LegacyStyle = .{
        .direction = "ltr",
        .border_top = "0px",
        .border_right = "0px",
        .border_bottom = "0px",
        .border_left = "0px",
    };
    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 0, .style = legacy },
    };
    var expected = [_]Rect{
        .{ .x = 0, .y = 0, .width = 0, .height = 0, .scroll_width = 7 },
    };
    const fixture_case: Case = .{
        .id = "test",
        .source = "test_fixtures/test.html",
        .source_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .variant = "border_box_ltr",
        .grid_feature = false,
        .use_rounding = true,
        .viewport = .{ .width = 100, .height = 100 },
        .nodes = &nodes,
        .expected = &expected,
    };
    var fixture_tree = try FixtureTree.init(std.testing.allocator, nodes.len);
    defer fixture_tree.deinit(std.testing.allocator);
    var builder: TreeBuilder = .{
        .allocator = std.testing.allocator,
        .fixture_case = fixture_case,
        .result = &fixture_tree,
    };
    _ = try builder.buildRoot();

    const state = fixture_tree.resources.scroll_states_by_source[0].?;
    state.max_offset = .{ 7, 99 };
    try std.testing.expect(try compareFixtureTree(fixture_case, &fixture_tree));

    expected[0].scroll_height = 99;
    try std.testing.expect(!try compareFixtureTree(fixture_case, &fixture_tree));
    expected[0].scroll_height = null;
    expected[0].scroll_width = null;
    try std.testing.expect(!try compareFixtureTree(fixture_case, &fixture_tree));
    expected[0].scroll_width = 7;
    state.max_offset[0] = 8;
    try std.testing.expect(!try compareFixtureTree(fixture_case, &fixture_tree));

    state.max_offset[0] = 7;
    fixture_tree.resources.scroll_states_by_source[0] = null;
    fixture_tree.tree.node(fixture_tree.source_ids[0]).?.scroll = null;
    try std.testing.expect(!try compareFixtureTree(fixture_case, &fixture_tree));
}

const Side = enum { top, right, bottom, left };

pub fn runCase(allocator: std.mem.Allocator, fixture_case: Case) CaseError!bool {
    try validateFixtureInputs(fixture_case);
    var fixture_tree = try FixtureTree.init(allocator, fixture_case.nodes.len);
    defer fixture_tree.deinit(allocator);

    var builder: TreeBuilder = .{
        .allocator = allocator,
        .fixture_case = fixture_case,
        .result = &fixture_tree,
    };
    const fixture_root = try builder.buildRoot();

    const available: widget.Size = .{
        .width = try finiteF32(fixture_case.viewport.width),
        .height = try finiteF32(fixture_case.viewport.height),
    };
    try appendFixtureSurface(&fixture_tree.tree, fixture_root, available);
    layout.layoutTree(&fixture_tree.tree, .{
        .allocator = allocator,
        .available = available,
        .measure = ahemMeasure,
    }) catch |layout_error| {
        if (layout_error == error.OutOfMemory) return error.OutOfMemory;
        return error.LayoutFailed;
    };
    return compareFixtureTree(fixture_case, &fixture_tree);
}

fn appendFixtureSurface(
    tree: *widget.WidgetTree,
    fixture_root: Id,
    available: widget.Size,
) CaseError!void {
    if (tree.nodes.items.len >= std.math.maxInt(u32)) return error.InvalidFixture;
    const surface_id: Id = @enumFromInt(@as(u32, @intCast(tree.nodes.items.len + 1)));
    const root = tree.node(fixture_root) orelse return error.InvalidFixture;
    root.parent = surface_id;
    try tree.appendNode(.{
        .id = surface_id,
        .kind = .{ .row = .{} },
        .parent = .root,
        .style = .{
            .display = .flex,
            .direction = .row,
            .@"align" = .start,
            .box_sizing = .border_box,
            .size = .{
                .width = .{ .length = available.width },
                .height = .{ .length = available.height },
            },
        },
    });
    try tree.appendChild(surface_id, fixture_root);
}

fn validateFixtureInputs(fixture_case: Case) CaseError!void {
    _ = try finiteF32(fixture_case.viewport.width);
    _ = try finiteF32(fixture_case.viewport.height);
    for (fixture_case.expected) |expected| {
        try validateExpectedRect(expected);
    }
}

fn compareFixtureTree(fixture_case: Case, fixture_tree: *const FixtureTree) CaseError!bool {
    var source_index: usize = 0;
    return compareFixtureNode(
        fixture_case,
        fixture_tree,
        &source_index,
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    );
}

fn compareFixtureNode(
    fixture_case: Case,
    fixture_tree: *const FixtureTree,
    source_index: *usize,
    expected_parent: Rect,
) CaseError!bool {
    if (source_index.* >= fixture_case.nodes.len) return error.InvalidFixture;
    const index = source_index.*;
    source_index.* += 1;
    if (index >= fixture_case.expected.len) return error.InvalidFixture;
    if (index >= fixture_tree.resources.scroll_states_by_source.len) {
        return error.InvalidFixture;
    }
    const expected = fixture_case.expected[index];
    const expected_absolute: Rect = .{
        .x = expected_parent.x + expected.x,
        .y = expected_parent.y + expected.y,
        .width = expected.width,
        .height = expected.height,
    };
    const node = fixture_tree.tree.nodeConst(fixture_tree.source_ids[index]) orelse {
        return error.InvalidFixture;
    };
    const actual_rect = widget.absoluteRect(
        &fixture_tree.tree,
        fixture_tree.source_ids[index],
    );
    const actual: Rect = .{
        .x = @floatCast(actual_rect.x),
        .y = @floatCast(actual_rect.y),
        .width = @floatCast(actual_rect.w),
        .height = @floatCast(actual_rect.h),
    };
    if (!rectMatchesRounded(actual, expected_absolute, fixture_case.use_rounding)) return false;

    const attached_state: ?*widget.ScrollState = if (node.scroll) |scroll|
        scroll.state
    else
        null;
    if (attached_state != fixture_tree.resources.scroll_states_by_source[index]) {
        return error.InvalidFixture;
    }
    if (!scrollMatchesRounded(
        node.scroll,
        expected,
        fixture_case.use_rounding,
    )) return false;

    for (0..fixture_case.nodes[index].child_count) |_| {
        if (!try compareFixtureNode(
            fixture_case,
            fixture_tree,
            source_index,
            expected_absolute,
        )) return false;
    }
    return true;
}

fn scrollMatchesRounded(
    actual_scroll: ?widget.ScrollSpec,
    expected: Rect,
    use_rounding: bool,
) bool {
    const expected_axis = expectedScrollAxis(expected);
    const scroll = actual_scroll orelse return expected_axis == null;
    const axis = expected_axis orelse return false;
    if (scroll.axis != axis) return false;

    if (expected.scroll_width) |scroll_width| {
        if (!scalarMatchesRounded(
            @floatCast(scroll.state.max_offset[0]),
            scroll_width,
            use_rounding,
        )) return false;
    }
    if (expected.scroll_height) |scroll_height| {
        if (!scalarMatchesRounded(
            @floatCast(scroll.state.max_offset[1]),
            scroll_height,
            use_rounding,
        )) return false;
    }
    return true;
}

fn fixtureKind(fixture_node: Node, node_style: style.Style) CaseError!widget.WidgetKind {
    if (std.mem.eql(u8, fixture_node.kind, "text")) {
        if (fixture_node.child_count != 0) return error.InvalidFixture;
        return .{ .label = .{ .text = fixture_node.text orelse "" } };
    }
    if (!std.mem.eql(u8, fixture_node.kind, "div")) return error.Unsupported;
    if (fixture_node.child_count == 0) return .{ .spacer = .{} };
    if (node_style.display == .flex and !style.directionIsColumn(node_style.direction)) {
        return .{ .row = .{} };
    }
    return .{ .column = .{} };
}

fn variantBoxSizing(variant: []const u8) CaseError!style.BoxSizing {
    if (std.mem.eql(u8, variant, "border_box_ltr") or
        std.mem.eql(u8, variant, "border_box_rtl"))
    {
        return .border_box;
    }
    if (std.mem.eql(u8, variant, "content_box_ltr") or
        std.mem.eql(u8, variant, "content_box_rtl"))
    {
        return .content_box;
    }
    return error.InvalidFixture;
}

fn fixtureStyle(
    resources: *FixtureResources,
    fixture_node: Node,
    variant: []const u8,
) CaseError!style.Style {
    if (fixture_node.writing_mode) |writing_mode| {
        if (!std.mem.eql(u8, writing_mode, "horizontal-tb")) return error.Unsupported;
    }

    var result: style.Style = .{
        .box_sizing = try variantBoxSizing(variant),
    };
    try applyDirection(&result, fixture_node.style.direction);
    setBorder(&result, .top, try pixelsF32(fixture_node.style.border_top));
    setBorder(&result, .right, try pixelsF32(fixture_node.style.border_right));
    setBorder(&result, .bottom, try pixelsF32(fixture_node.style.border_bottom));
    setBorder(&result, .left, try pixelsF32(fixture_node.style.border_left));

    if (fixture_node.attributes) |attributes| {
        const object = switch (attributes) {
            .object => |value| value,
            else => return error.InvalidFixture,
        };
        try applyFixtureAttributes(resources, &result, object);
    }
    if (std.mem.eql(u8, fixture_node.kind, "text")) {
        const text = fixture_node.text orelse "";
        if (hasTextBreakOpportunity(text)) return error.Unsupported;
        const intrinsic = ahemMeasure(text, 0, 0);
        if (dimensionAuto(result.size.width)) {
            result.size.width = .{ .length = textSizingValue(
                intrinsic.width,
                result.border.left + result.border.right + result.padding.left + result.padding.right,
                result.box_sizing,
            ) };
        }
        if (dimensionAuto(result.size.height)) {
            result.size.height = .{ .length = textSizingValue(
                intrinsic.height,
                result.border.top + result.border.bottom + result.padding.top + result.padding.bottom,
                result.box_sizing,
            ) };
        }
    }
    return result;
}
fn textSizingValue(intrinsic: f32, edges: f32, box_sizing: style.BoxSizing) f32 {
    return switch (box_sizing) {
        .content_box => intrinsic,
        .border_box => intrinsic + edges,
    };
}

fn applyFixtureAttributes(
    resources: *FixtureResources,
    result: *style.Style,
    attributes: std.json.ObjectMap,
) CaseError!void {
    var iterator = attributes.iterator();
    while (iterator.next()) |entry| {
        if (isGridTemplateAttribute(entry.key_ptr.*)) continue;
        try applyAttributeWithResources(
            resources,
            result,
            entry.key_ptr.*,
            try jsonString(entry.value_ptr.*),
        );
    }

    iterator = attributes.iterator();
    while (iterator.next()) |entry| {
        if (!isGridTemplateAttribute(entry.key_ptr.*)) continue;
        try applyAttributeWithResources(
            resources,
            result,
            entry.key_ptr.*,
            try jsonString(entry.value_ptr.*),
        );
    }
}

fn isGridTemplateAttribute(name: []const u8) bool {
    return std.mem.eql(u8, name, "grid-template-columns") or std.mem.eql(u8, name, "grid-template-rows");
}

fn isAxisGapAttribute(name: []const u8) bool {
    return std.mem.eql(u8, name, "column-gap") or std.mem.eql(u8, name, "row-gap");
}

fn dimensionAuto(value: style.Dimension) bool {
    return switch (value) {
        .auto => true,
        .length, .percent, .min_content, .max_content, .fit_content => false,
    };
}

fn hasTextBreakOpportunity(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, " \t\n\r") != null or
        std.mem.indexOf(u8, text, "\xE2\x80\x8B") != null;
}

test "fixture text wrap detection is explicit" {
    try std.testing.expect(!hasTextBreakOpportunity("HHHH"));
    try std.testing.expect(hasTextBreakOpportunity("H H"));
    try std.testing.expect(hasTextBreakOpportunity("H\xE2\x80\x8BH"));
}

fn applyAttribute(result: *style.Style, name: []const u8, value: []const u8) CaseError!void {
    return applyAttributeWithResources(null, result, name, value);
}

fn applyAttributeWithResources(
    resources: ?*FixtureResources,
    result: *style.Style,
    name: []const u8,
    value: []const u8,
) CaseError!void {
    if (std.mem.eql(u8, name, "direction")) return applyDirection(result, value);
    if (std.mem.eql(u8, name, "writing-mode")) {
        if (std.mem.eql(u8, value, "horizontal-tb")) return;
        return error.Unsupported;
    }
    if (std.mem.eql(u8, name, "display")) return applyDisplay(result, value);
    if (std.mem.eql(u8, name, "box-sizing")) return applyBoxSizing(result, value);
    if (std.mem.eql(u8, name, "flex-direction")) return applyFlexDirection(result, value);
    if (std.mem.eql(u8, name, "flex-wrap")) return applyFlexWrap(result, value);
    if (std.mem.eql(u8, name, "flex-grow")) return applyFlexGrow(result, value);
    if (std.mem.eql(u8, name, "flex-shrink")) return applyFlexShrink(result, value);
    if (std.mem.eql(u8, name, "flex-basis")) return applyFlexBasis(result, value);
    if (std.mem.eql(u8, name, "gap")) return applyGap(result, value);
    if (std.mem.eql(u8, name, "column-gap")) return applyColumnGap(result, value);
    if (std.mem.eql(u8, name, "row-gap")) return applyRowGap(result, value);
    if (std.mem.eql(u8, name, "justify-content")) {
        return applyJustifyContent(result, value);
    }
    if (std.mem.eql(u8, name, "align-items")) return applyAlignItems(result, value);
    if (std.mem.eql(u8, name, "align-self")) return applyAlignSelf(result, value);
    if (std.mem.eql(u8, name, "align-content")) return applyAlignContent(result, value);
    if (std.mem.eql(u8, name, "justify-items")) return applyJustifyItems(result, value);
    if (std.mem.eql(u8, name, "justify-self")) return applyJustifySelf(result, value);
    if (std.mem.eql(u8, name, "grid-template-columns")) {
        const owner = resources orelse return error.InvalidFixture;
        const width_avail: ?f32 = switch (result.size.width) {
            .length => |w| switch (result.box_sizing) {
                .content_box => w,
                .border_box => @max(
                    0,
                    w - result.border.left - result.border.right - result.padding.left - result.padding.right,
                ),
            },
            else => null,
        };
        const gap = if (result.grid_column_gap != 0)
            result.grid_column_gap
        else if (result.column_gap != 0)
            result.column_gap
        else
            result.gap;
        result.grid_template_columns = try parseGridTemplate(owner, value, width_avail, gap);
        return;
    }
    if (std.mem.eql(u8, name, "grid-template-rows")) {
        const owner = resources orelse return error.InvalidFixture;
        const height_avail: ?f32 = switch (result.size.height) {
            .length => |h| switch (result.box_sizing) {
                .content_box => h,
                .border_box => @max(
                    0,
                    h - result.border.top - result.border.bottom - result.padding.top - result.padding.bottom,
                ),
            },
            else => null,
        };
        const gap = if (result.grid_row_gap != 0)
            result.grid_row_gap
        else if (result.row_gap != 0)
            result.row_gap
        else
            result.gap;
        result.grid_template_rows = try parseGridTemplate(owner, value, height_avail, gap);
        return;
    }
    if (std.mem.eql(u8, name, "grid-auto-columns")) {
        const owner = resources orelse return error.InvalidFixture;
        result.grid_auto_columns = try parseGridAutoTrack(owner, value);
        return;
    }
    if (std.mem.eql(u8, name, "grid-auto-rows")) {
        const owner = resources orelse return error.InvalidFixture;
        result.grid_auto_rows = try parseGridAutoTrack(owner, value);
        return;
    }
    if (std.mem.eql(u8, name, "grid-auto-flow")) {
        result.grid_auto_flow = try parseGridAutoFlow(value);
        return;
    }
    if (std.mem.eql(u8, name, "grid-column-start")) {
        const placement = try parseGridPlacement(value);
        result.grid_column_start = placement;
        result.grid_column.start = placement;
        return;
    }
    if (std.mem.eql(u8, name, "grid-column-end")) {
        const placement = try parseGridPlacement(value);
        result.grid_column_end = placement;
        result.grid_column.end = placement;
        return;
    }
    if (std.mem.eql(u8, name, "grid-row-start")) {
        const placement = try parseGridPlacement(value);
        result.grid_row_start = placement;
        result.grid_row.start = placement;
        return;
    }
    if (std.mem.eql(u8, name, "grid-row-end")) {
        const placement = try parseGridPlacement(value);
        result.grid_row_end = placement;
        result.grid_row.end = placement;
        return;
    }
    if (std.mem.eql(u8, name, "aspect-ratio")) return applyAspectRatio(result, value);
    if (std.mem.eql(u8, name, "overflow-x")) return applyOverflowAxis(&result.overflow.width, value);
    if (std.mem.eql(u8, name, "overflow-y")) return applyOverflowAxis(&result.overflow.height, value);
    if (std.mem.eql(u8, name, "float")) return applyFloat(result, value);
    if (std.mem.eql(u8, name, "clear")) return applyClear(result, value);
    if (std.mem.eql(u8, name, "width")) return setDimension(&result.size.width, try parseDimension(value));
    if (std.mem.eql(u8, name, "height")) return setDimension(&result.size.height, try parseDimension(value));
    if (std.mem.eql(u8, name, "min-width")) return setDimension(&result.min_size.width, try parseDimension(value));
    if (std.mem.eql(u8, name, "min-height")) return setDimension(&result.min_size.height, try parseDimension(value));
    if (std.mem.eql(u8, name, "max-width")) return setDimension(&result.max_size.width, try parseDimension(value));
    if (std.mem.eql(u8, name, "max-height")) return setDimension(&result.max_size.height, try parseDimension(value));
    if (std.mem.eql(u8, name, "position")) return applyPosition(result, value);
    if (std.mem.eql(u8, name, "top")) return setInset(&result.inset.top, try parseInset(value));
    if (std.mem.eql(u8, name, "right")) return setInset(&result.inset.right, try parseInset(value));
    if (std.mem.eql(u8, name, "bottom")) return setInset(&result.inset.bottom, try parseInset(value));
    if (std.mem.eql(u8, name, "left")) return setInset(&result.inset.left, try parseInset(value));
    if (std.mem.eql(u8, name, "margin-top")) return setMargin(result, .top, try parseInset(value));
    if (std.mem.eql(u8, name, "margin-right")) return setMargin(result, .right, try parseInset(value));
    if (std.mem.eql(u8, name, "margin-bottom")) return setMargin(result, .bottom, try parseInset(value));
    if (std.mem.eql(u8, name, "margin-left")) return setMargin(result, .left, try parseInset(value));
    if (std.mem.eql(u8, name, "padding-top")) return setPadding(result, .top, try parseLengthPercentage(value));
    if (std.mem.eql(u8, name, "padding-right")) return setPadding(result, .right, try parseLengthPercentage(value));
    if (std.mem.eql(u8, name, "padding-bottom")) return setPadding(result, .bottom, try parseLengthPercentage(value));
    if (std.mem.eql(u8, name, "padding-left")) return setPadding(result, .left, try parseLengthPercentage(value));
    if (std.mem.eql(u8, name, "border-top")) return setBorder(result, .top, try parseNonnegativeLength(value));
    if (std.mem.eql(u8, name, "border-right")) return setBorder(result, .right, try parseNonnegativeLength(value));
    if (std.mem.eql(u8, name, "border-bottom")) return setBorder(result, .bottom, try parseNonnegativeLength(value));
    if (std.mem.eql(u8, name, "border-left")) return setBorder(result, .left, try parseNonnegativeLength(value));
    return error.Unsupported;
}

test "fixture flex direction and wrap attributes map represented values" {
    const direction_cases = [_]struct {
        value: []const u8,
        expected: style.FlexDirection,
    }{
        .{ .value = "row", .expected = .row },
        .{ .value = "row-reverse", .expected = .row_reverse },
        .{ .value = "column", .expected = .column },
        .{ .value = "column-reverse", .expected = .column_reverse },
    };
    for (direction_cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "flex-direction", case.value);
        try std.testing.expectEqual(case.expected, result.direction);
    }

    const wrap_cases = [_]struct {
        value: []const u8,
        expected: style.FlexWrap,
    }{
        .{ .value = "nowrap", .expected = .nowrap },
        .{ .value = "wrap", .expected = .wrap },
        .{ .value = "wrap-reverse", .expected = .wrap_reverse },
    };
    for (wrap_cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "flex-wrap", case.value);
        try std.testing.expectEqual(case.expected, result.wrap);
        try std.testing.expectEqual(case.expected, result.flex_wrap);
    }
}

test "fixture flex item attributes map typed and legacy fields" {
    var result: style.Style = .{};
    try applyAttribute(&result, "flex-grow", "2.5");
    try applyAttribute(&result, "flex-shrink", "0.5");
    try std.testing.expectEqual(@as(f32, 2.5), result.grow);
    try std.testing.expectEqual(@as(f32, 0.5), result.shrink);

    try applyAttribute(&result, "flex-basis", "12px");
    try std.testing.expectEqual(@as(f32, 12), result.basis);
    try std.testing.expectEqual(style.Dimension{ .length = 12 }, result.flex_basis);

    try applyAttribute(&result, "flex-basis", "25%");
    try std.testing.expectEqual(@as(f32, 0), result.basis);
    try std.testing.expectEqual(style.Dimension{ .percent = 0.25 }, result.flex_basis);

    try applyAttribute(&result, "flex-basis", "min-content");
    try std.testing.expectEqual(@as(f32, 0), result.basis);
    try std.testing.expectEqual(@as(style.Dimension, .min_content), result.flex_basis);

    try applyAttribute(&result, "flex-basis", "max-content");
    try std.testing.expectEqual(@as(f32, 0), result.basis);
    try std.testing.expectEqual(@as(style.Dimension, .max_content), result.flex_basis);

    try applyAttribute(&result, "flex-basis", "fit-content");
    try std.testing.expectEqual(@as(f32, 0), result.basis);
    try std.testing.expectEqual(style.Dimension{ .fit_content = null }, result.flex_basis);

    try applyAttribute(&result, "width", "fit-content(40px)");
    try std.testing.expectEqual(style.Dimension{ .fit_content = 40 }, result.size.width);

    try applyAttribute(&result, "flex-basis", "auto");
    try std.testing.expectEqual(@as(f32, 0), result.basis);
    try std.testing.expectEqual(@as(style.Dimension, .auto), result.flex_basis);
}

test "fixture gap attributes keep generic and axis fields coherent" {
    var result: style.Style = .{};
    try applyAttribute(&result, "gap", "4px");
    try std.testing.expectEqual(@as(f32, 4), result.gap);
    try std.testing.expectEqual(@as(f32, 4), result.column_gap);
    try std.testing.expectEqual(@as(f32, 4), result.row_gap);

    try applyAttribute(&result, "column-gap", "0");
    try std.testing.expectEqual(@as(f32, 0), result.gap);
    try std.testing.expectEqual(@as(f32, 0), result.column_gap);
    try std.testing.expectEqual(@as(f32, 4), result.row_gap);

    try applyAttribute(&result, "row-gap", "6px");
    try std.testing.expectEqual(@as(f32, 0), result.gap);
    try std.testing.expectEqual(@as(f32, 0), result.column_gap);
    try std.testing.expectEqual(@as(f32, 6), result.row_gap);

    var reordered: style.Style = .{};
    try applyAttribute(&reordered, "row-gap", "3px");
    try applyAttribute(&reordered, "column-gap", "2px");
    try applyAttribute(&reordered, "gap", "1px");
    try std.testing.expectEqual(@as(f32, 1), reordered.gap);
    try std.testing.expectEqual(@as(f32, 1), reordered.column_gap);
    try std.testing.expectEqual(@as(f32, 1), reordered.row_gap);
}

test "fixture justify content maps represented values and flex aliases" {
    const cases = [_]struct {
        value: []const u8,
        expected: style.Justify,
    }{
        .{ .value = "start", .expected = .start },
        .{ .value = "flex-start", .expected = .start },
        .{ .value = "center", .expected = .center },
        .{ .value = "end", .expected = .end },
        .{ .value = "flex-end", .expected = .end },
        .{ .value = "space-between", .expected = .space_between },
        .{ .value = "space-around", .expected = .space_around },
        .{ .value = "space-evenly", .expected = .space_evenly },
    };
    for (cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "justify-content", case.value);
        try std.testing.expectEqual(case.expected, result.justify);
    }
}

test "fixture alignment attributes map only represented values" {
    const item_cases = [_]struct {
        value: []const u8,
        expected: style.Align,
    }{
        .{ .value = "stretch", .expected = .stretch },
        .{ .value = "start", .expected = .start },
        .{ .value = "flex-start", .expected = .start },
        .{ .value = "center", .expected = .center },
        .{ .value = "end", .expected = .end },
        .{ .value = "flex-end", .expected = .end },
    };
    for (item_cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "align-items", case.value);
        try std.testing.expectEqual(case.expected, result.@"align");
    }

    const self_cases = [_]struct {
        value: []const u8,
        expected: style.AlignSelf,
    }{
        .{ .value = "auto", .expected = .auto },
        .{ .value = "stretch", .expected = .stretch },
        .{ .value = "start", .expected = .start },
        .{ .value = "flex-start", .expected = .start },
        .{ .value = "center", .expected = .center },
        .{ .value = "end", .expected = .end },
        .{ .value = "flex-end", .expected = .end },
    };
    for (self_cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "align-self", case.value);
        try std.testing.expectEqual(case.expected, result.align_self);
    }

    const content_cases = [_]struct {
        value: []const u8,
        expected: style.AlignContent,
    }{
        .{ .value = "stretch", .expected = .stretch },
        .{ .value = "start", .expected = .start },
        .{ .value = "flex-start", .expected = .start },
        .{ .value = "center", .expected = .center },
        .{ .value = "end", .expected = .end },
        .{ .value = "flex-end", .expected = .end },
        .{ .value = "space-between", .expected = .space_between },
        .{ .value = "space-around", .expected = .space_around },
        .{ .value = "space-evenly", .expected = .space_evenly },
    };
    for (content_cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "align-content", case.value);
        try std.testing.expectEqual(case.expected, result.align_content);
    }
}

test "fixture unsupported alignment values stay explicit" {
    const cases = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "align-items", .value = "safe center" },
        .{ .name = "align-self", .value = "safe center" },
        .{ .name = "align-content", .value = "unsafe center" },
        .{ .name = "justify-content", .value = "baseline" },
        .{ .name = "column-gap", .value = "normal" },
        .{ .name = "aspect-ratio", .value = "1 / 2" },
    };
    for (cases) |case| {
        var result: style.Style = .{};
        try std.testing.expectError(
            error.Unsupported,
            applyAttribute(&result, case.name, case.value),
        );
    }
}

test "fixture aspect ratio and overflow axes map represented values" {
    var result: style.Style = .{};
    try applyAttribute(&result, "aspect-ratio", "1.5");
    try std.testing.expectEqual(@as(?f32, 1.5), result.aspect_ratio);
    try applyAttribute(&result, "aspect-ratio", "auto");
    try std.testing.expectEqual(@as(?f32, null), result.aspect_ratio);

    const overflow_cases = [_]struct {
        value: []const u8,
        expected: style.Overflow,
    }{
        .{ .value = "visible", .expected = .visible },
        .{ .value = "hidden", .expected = .hidden },
        .{ .value = "clip", .expected = .clip },
        .{ .value = "scroll", .expected = .scroll },
        .{ .value = "auto", .expected = .auto },
    };
    for (overflow_cases) |case| {
        var axes: style.Style = .{};
        try applyAttribute(&axes, "overflow-x", case.value);
        try applyAttribute(&axes, "overflow-y", case.value);
        try std.testing.expectEqual(case.expected, axes.overflow.width);
        try std.testing.expectEqual(case.expected, axes.overflow.height);
    }
}

test "fixture float and clear map represented values" {
    const float_cases = [_]struct {
        value: []const u8,
        expected: style.Float,
    }{
        .{ .value = "none", .expected = .none },
        .{ .value = "left", .expected = .left },
        .{ .value = "right", .expected = .right },
        .{ .value = "inline-start", .expected = .inline_start },
        .{ .value = "inline-end", .expected = .inline_end },
    };
    for (float_cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "float", case.value);
        try std.testing.expectEqual(case.expected, result.float);
    }

    const clear_cases = [_]struct {
        value: []const u8,
        expected: style.Clear,
    }{
        .{ .value = "none", .expected = .none },
        .{ .value = "left", .expected = .left },
        .{ .value = "right", .expected = .right },
        .{ .value = "both", .expected = .both },
        .{ .value = "inline-start", .expected = .inline_start },
        .{ .value = "inline-end", .expected = .inline_end },
    };
    for (clear_cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "clear", case.value);
        try std.testing.expectEqual(case.expected, result.clear);
    }
}

test "fixture numeric style values reject malformed and nonfinite input" {
    const cases = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "flex-grow", .value = "nan" },
        .{ .name = "flex-shrink", .value = "-1" },
        .{ .name = "flex-basis", .value = "12pxjunk" },
        .{ .name = "column-gap", .value = "-1px" },
        .{ .name = "row-gap", .value = "inf" },
        .{ .name = "aspect-ratio", .value = "0" },
        .{ .name = "aspect-ratio", .value = "-1" },
        .{ .name = "aspect-ratio", .value = "nan" },
    };
    for (cases) |case| {
        var result: style.Style = .{};
        try std.testing.expectError(
            error.InvalidFixture,
            applyAttribute(&result, case.name, case.value),
        );
    }
}

test "fixture accepts duplicated horizontal writing mode" {
    var result: style.Style = .{};
    try applyAttribute(&result, "writing-mode", "horizontal-tb");
}

test "fixture unmapped style syntax stays unsupported" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    const cases = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "scrollbar-width", .value = "auto" },
        .{ .name = "text-align", .value = "left" },
        .{
            .name = "grid-template-columns",
            .value = "[content-start] 1fr [content-end]",
        },
        .{ .name = "writing-mode", .value = "vertical-rl" },
    };
    for (cases) |case| {
        var result: style.Style = .{};
        try std.testing.expectError(
            error.Unsupported,
            applyAttributeWithResources(
                &fixture_tree.resources,
                &result,
                case.name,
                case.value,
            ),
        );
    }

    const legacy: LegacyStyle = .{
        .direction = "ltr",
        .border_top = "0px",
        .border_right = "0px",
        .border_bottom = "0px",
        .border_left = "0px",
    };
    try std.testing.expectError(error.Unsupported, fixtureStyle(
        &fixture_tree.resources,
        .{
            .kind = "div",
            .writing_mode = "vertical-rl",
            .child_count = 0,
            .style = legacy,
        },
        "border_box_ltr",
    ));
}
test "fixture variants supply generated box sizing defaults" {
    const legacy: LegacyStyle = .{
        .direction = "ltr",
        .border_top = "0px",
        .border_right = "0px",
        .border_bottom = "0px",
        .border_left = "0px",
    };
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);
    const node: Node = .{
        .kind = "div",
        .child_count = 0,
        .style = legacy,
    };
    try std.testing.expectEqual(
        style.BoxSizing.border_box,
        (try fixtureStyle(&fixture_tree.resources, node, "border_box_ltr")).box_sizing,
    );
    try std.testing.expectEqual(
        style.BoxSizing.content_box,
        (try fixtureStyle(&fixture_tree.resources, node, "content_box_rtl")).box_sizing,
    );
}

test "fixture text sizing honors generated box sizing defaults" {
    const legacy: LegacyStyle = .{
        .direction = "ltr",
        .border_top = "2px",
        .border_right = "4px",
        .border_bottom = "6px",
        .border_left = "8px",
    };
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);
    const node: Node = .{
        .kind = "text",
        .text = "HHHH",
        .child_count = 0,
        .style = legacy,
    };
    try std.testing.expect(std.meta.eql(
        @as(style.Dimension, .{ .length = 52 }),
        (try fixtureStyle(&fixture_tree.resources, node, "border_box_ltr")).size.width,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.Dimension, .{ .length = 40 }),
        (try fixtureStyle(&fixture_tree.resources, node, "content_box_ltr")).size.width,
    ));
}

test "fixture grid templates parse all supported track classes" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "12px\t25%\nauto min-content max-content 2fr minmax(0, 1fr)",
    );
    const expected_columns = [_]style.GridTrack{
        .{ .fixed = 12 },
        .{ .percent = 0.25 },
        .auto,
        .min_content,
        .max_content,
        .{ .fr = 2 },
        .{ .minmax = .{ .min = .{ .fixed = 0 }, .max = .{ .fr = 1 } } },
    };
    try std.testing.expectEqual(expected_columns.len, result.grid_template_columns.len);
    for (expected_columns, result.grid_template_columns) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-rows",
        "minmax(10%, max-content) minmax(auto, 3fr)",
    );
    const expected_rows = [_]style.GridTrack{
        .{ .minmax = .{
            .min = .{ .percent = 0.1 },
            .max = .max_content,
        } },
        .{ .minmax = .{
            .min = .auto,
            .max = .{ .fr = 3 },
        } },
    };
    try std.testing.expectEqual(expected_rows.len, result.grid_template_rows.len);
    for (expected_rows, result.grid_template_rows) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }
}

test "fixture grid template allocations remain stable independently" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var first: style.Style = .{};
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &first,
        "grid-template-columns",
        "1fr 20px",
    );
    const stable_tracks = first.grid_template_columns;

    for (0..40) |_| {
        var subsequent: style.Style = .{};
        try applyAttributeWithResources(
            &fixture_tree.resources,
            &subsequent,
            "grid-template-rows",
            "minmax(1px, 1fr)",
        );
    }

    try std.testing.expectEqual(
        @as(usize, 41),
        fixture_tree.resources.grid_track_allocations.items.len,
    );
    try std.testing.expect(
        fixture_tree.resources.grid_track_allocations.items[0].ptr ==
            stable_tracks.ptr,
    );
    for (fixture_tree.resources.grid_track_allocations.items[1..]) |allocation| {
        try std.testing.expect(allocation.ptr != stable_tracks.ptr);
    }
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .{ .fr = 1 }),
        stable_tracks[0],
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .{ .fixed = 20 }),
        stable_tracks[1],
    ));
}

test "fixture grid auto tracks and flow map represented values" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-auto-columns",
        "minmax(10px, 2fr)",
    );
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-auto-rows",
        "max-content",
    );
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .{ .minmax = .{
            .min = .{ .fixed = 10 },
            .max = .{ .fr = 2 },
        } }),
        result.grid_auto_columns,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .max_content),
        result.grid_auto_rows,
    ));

    const flow_cases = [_]struct {
        value: []const u8,
        expected: style.GridAutoFlow,
    }{
        .{ .value = "row", .expected = .row },
        .{ .value = "column", .expected = .column },
        .{ .value = "row dense", .expected = .row_dense },
        .{ .value = "column dense", .expected = .column_dense },
    };
    for (flow_cases) |case| {
        try applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "grid-auto-flow",
            case.value,
        );
        try std.testing.expectEqual(case.expected, result.grid_auto_flow);
    }
}

test "fixture grid templates parse repeat and fit-content patterns" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "repeat(4, 50px)",
    );
    const expected_repeat4 = [_]style.GridTrack{
        .{ .fixed = 50 },
        .{ .fixed = 50 },
        .{ .fixed = 50 },
        .{ .fixed = 50 },
    };
    try std.testing.expectEqual(expected_repeat4.len, result.grid_template_columns.len);
    for (expected_repeat4, result.grid_template_columns) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "10px repeat(2, 1fr 2fr) 20px",
    );
    const expected_mixed = [_]style.GridTrack{
        .{ .fixed = 10 },
        .{ .fr = 1 },
        .{ .fr = 2 },
        .{ .fr = 1 },
        .{ .fr = 2 },
        .{ .fixed = 20 },
    };
    try std.testing.expectEqual(expected_mixed.len, result.grid_template_columns.len);
    for (expected_mixed, result.grid_template_columns) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-rows",
        "fit-content(20px) repeat(2, minmax(10px, 1fr)) fit-content(30px)",
    );
    const expected_rows = [_]style.GridTrack{
        .{ .fit_content = 20 },
        .{ .minmax = .{ .min = .{ .fixed = 10 }, .max = .{ .fr = 1 } } },
        .{ .minmax = .{ .min = .{ .fixed = 10 }, .max = .{ .fr = 1 } } },
        .{ .fit_content = 30 },
    };
    try std.testing.expectEqual(expected_rows.len, result.grid_template_rows.len);
    for (expected_rows, result.grid_template_rows) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-auto-columns",
        "fit-content(50px)",
    );
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .{ .fit_content = 50 }),
        result.grid_auto_columns,
    ));
}

test "fixture grid templates parse auto-fit and auto-fill repeat patterns" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    result.size.width = .{ .length = 200 };
    result.grid_column_gap = 10;
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "repeat(auto-fit, 60px)",
    );
    const expected_fit = [_]style.GridTrack{
        .{ .fixed = 60 },
        .{ .fixed = 60 },
        .{ .fixed = 60 },
    };
    try std.testing.expectEqual(expected_fit.len, result.grid_template_columns.len);
    for (expected_fit, result.grid_template_columns) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "repeat(auto-fill, minmax(40px, 1fr))",
    );
    const expected_fill = [_]style.GridTrack{
        .{ .minmax = .{ .min = .{ .fixed = 40 }, .max = .{ .fr = 1 } } },
        .{ .minmax = .{ .min = .{ .fixed = 40 }, .max = .{ .fr = 1 } } },
        .{ .minmax = .{ .min = .{ .fixed = 40 }, .max = .{ .fr = 1 } } },
        .{ .minmax = .{ .min = .{ .fixed = 40 }, .max = .{ .fr = 1 } } },
    };
    try std.testing.expectEqual(expected_fill.len, result.grid_template_columns.len);
    for (expected_fill, result.grid_template_columns) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }
}

test "fixture grid placements parse lines and positive spans" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-column-start", "3");
    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-column-end", "span 2");
    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-row-start", "-4");
    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-row-end", "auto");

    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .line = 3 }),
        result.grid_column_start,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .span = 2 }),
        result.grid_column_end,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .line = -4 }),
        result.grid_row_start,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .auto),
        result.grid_row_end,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.GridLine, .{
            .start = .{ .line = 3 },
            .end = .{ .span = 2 },
        }),
        result.grid_column,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.GridLine, .{
            .start = .{ .line = -4 },
            .end = .auto,
        }),
        result.grid_row,
    ));

    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-row-end", "span 1024");
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .span = 1024 }),
        result.grid_row_end,
    ));
    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-row-end", "span 255");
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .span = 255 }),
        result.grid_row_end,
    ));
    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-row-end", "span  2");
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .span = 2 }),
        result.grid_row_end,
    ));

    const invalid = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "grid-column-start", .value = "0" },
        .{ .name = "grid-column-start", .value = "32768" },
        .{ .name = "grid-row-start", .value = "-32769" },
        .{ .name = "grid-column-end", .value = "span 0" },
        .{ .name = "grid-row-end", .value = "span -1" },
        .{ .name = "grid-row-end", .value = "span" },
        .{ .name = "grid-row-end", .value = "1 2" },
        .{ .name = "grid-row-end", .value = "span " },
    };
    for (invalid) |case| {
        try std.testing.expectError(
            error.InvalidFixture,
            applyAttributeWithResources(
                &fixture_tree.resources,
                &result,
                case.name,
                case.value,
            ),
        );
    }
    try std.testing.expectError(
        error.Unsupported,
        applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "grid-column-end",
            "span 1025",
        ),
    );
    try std.testing.expectError(
        error.Unsupported,
        applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "grid-row-end",
            "named-line",
        ),
    );
    try std.testing.expectError(
        error.Unsupported,
        applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "grid-row-end",
            "span2",
        ),
    );
}

test "fixture grid alignment and gaps populate grid fields" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-content", "flex-end");
    try std.testing.expectEqual(style.Justify.end, result.justify);
    try std.testing.expectEqual(style.Justify.end, result.grid_justify_content);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-content", "space-evenly");
    try std.testing.expectEqual(style.Justify.space_evenly, result.grid_justify_content);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-content", "space-around");
    try std.testing.expectEqual(style.AlignContent.space_around, result.align_content);
    try std.testing.expectEqual(style.AlignContent.space_around, result.grid_align_content);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-content", "space-evenly");
    try std.testing.expectEqual(style.AlignContent.space_evenly, result.align_content);
    try std.testing.expectEqual(style.AlignContent.space_evenly, result.grid_align_content);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-items", "flex-start");
    try std.testing.expectEqual(style.Align.start, result.grid_justify_items);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-items", "flex-end");
    try std.testing.expectEqual(style.Align.end, result.@"align");
    try std.testing.expectEqual(style.Align.end, result.grid_align_items);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-self", "center");
    try std.testing.expectEqual(style.AlignSelf.center, result.grid_justify_self);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-self", "stretch");
    try std.testing.expectEqual(style.AlignSelf.stretch, result.align_self);
    try std.testing.expectEqual(style.AlignSelf.stretch, result.grid_align_self);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "gap", "4px");
    try std.testing.expectEqual(@as(f32, 4), result.grid_column_gap);
    try std.testing.expectEqual(@as(f32, 4), result.grid_row_gap);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "column-gap", "2px");
    try applyAttributeWithResources(&fixture_tree.resources, &result, "row-gap", "3px");
    try std.testing.expectEqual(@as(f32, 2), result.grid_column_gap);
    try std.testing.expectEqual(@as(f32, 3), result.grid_row_gap);

    const unsupported = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "justify-items", .value = "safe center" },
        .{ .name = "align-items", .value = "safe center" },
        .{ .name = "justify-self", .value = "safe center" },
        .{ .name = "align-self", .value = "safe center" },
        .{ .name = "justify-content", .value = "safe center" },
    };
    for (unsupported) |case| {
        try std.testing.expectError(
            error.Unsupported,
            applyAttributeWithResources(
                &fixture_tree.resources,
                &result,
                case.name,
                case.value,
            ),
        );
    }
}

test "fixture grid representation gaps stay explicitly unsupported" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    const unsupported = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "grid-template-columns", .value = "[content] 1fr" },
        .{ .name = "grid-template-rows", .value = "subgrid" },
        .{ .name = "grid-template-areas", .value = "\"main main\"" },
        .{ .name = "grid-auto-columns", .value = "10px 1fr" },
        .{ .name = "grid-auto-rows", .value = "minmax(10px, 1fr) 20px" },
    };
    for (unsupported) |case| {
        var result: style.Style = .{};
        try std.testing.expectError(
            error.Unsupported,
            applyAttributeWithResources(
                &fixture_tree.resources,
                &result,
                case.name,
                case.value,
            ),
        );
    }

    const invalid = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "grid-template-columns", .value = "" },
        .{ .name = "grid-template-columns", .value = "-1px" },
        .{ .name = "grid-template-columns", .value = "nanfr" },
        .{ .name = "grid-template-columns", .value = "inf%" },
        .{ .name = "grid-template-columns", .value = "1.2.3px" },
        .{ .name = "grid-template-columns", .value = "minmax(, 1fr)" },
        .{ .name = "grid-template-columns", .value = "minmax(1px)" },
        .{ .name = "grid-template-columns", .value = "minmax(1px, -1fr)" },
        .{ .name = "grid-template-columns", .value = "minmax(1px, 2fr, auto)" },
        .{ .name = "grid-template-columns", .value = "minmax(1px, 1fr" },
    };
    for (invalid) |case| {
        var result: style.Style = .{};
        try std.testing.expectError(
            error.InvalidFixture,
            applyAttributeWithResources(
                &fixture_tree.resources,
                &result,
                case.name,
                case.value,
            ),
        );
    }
}

fn applyDirection(result: *style.Style, value: []const u8) CaseError!void {
    result.writing_direction = if (std.mem.eql(u8, value, "ltr"))
        .ltr
    else if (std.mem.eql(u8, value, "rtl"))
        .rtl
    else
        return error.Unsupported;
}

fn applyDisplay(result: *style.Style, value: []const u8) CaseError!void {
    result.display = if (std.mem.eql(u8, value, "block"))
        .block
    else if (std.mem.eql(u8, value, "flex"))
        .flex
    else if (std.mem.eql(u8, value, "grid"))
        .grid
    else if (std.mem.eql(u8, value, "flow-root"))
        .flow_root
    else if (std.mem.eql(u8, value, "none"))
        .none
    else
        return error.Unsupported;
}

fn applyBoxSizing(result: *style.Style, value: []const u8) CaseError!void {
    result.box_sizing = if (std.mem.eql(u8, value, "border-box"))
        .border_box
    else if (std.mem.eql(u8, value, "content-box"))
        .content_box
    else
        return error.Unsupported;
}

fn applyPosition(result: *style.Style, value: []const u8) CaseError!void {
    result.position = if (std.mem.eql(u8, value, "relative"))
        .relative
    else if (std.mem.eql(u8, value, "absolute"))
        .absolute
    else
        return error.Unsupported;
}

fn applyFlexDirection(result: *style.Style, value: []const u8) CaseError!void {
    result.direction = if (std.mem.eql(u8, value, "row"))
        .row
    else if (std.mem.eql(u8, value, "row-reverse"))
        .row_reverse
    else if (std.mem.eql(u8, value, "column"))
        .column
    else if (std.mem.eql(u8, value, "column-reverse"))
        .column_reverse
    else
        return error.Unsupported;
}

fn applyFlexWrap(result: *style.Style, value: []const u8) CaseError!void {
    const wrap: style.FlexWrap = if (std.mem.eql(u8, value, "nowrap"))
        .nowrap
    else if (std.mem.eql(u8, value, "wrap"))
        .wrap
    else if (std.mem.eql(u8, value, "wrap-reverse"))
        .wrap_reverse
    else
        return error.Unsupported;
    result.wrap = wrap;
    result.flex_wrap = wrap;
}

fn applyFlexGrow(result: *style.Style, value: []const u8) CaseError!void {
    const grow = try parseNumber(value);
    if (grow < 0) return error.InvalidFixture;
    result.grow = grow;
}

fn applyFlexShrink(result: *style.Style, value: []const u8) CaseError!void {
    const shrink = try parseNumber(value);
    if (shrink < 0) return error.InvalidFixture;
    result.shrink = shrink;
}

fn applyFlexBasis(result: *style.Style, value: []const u8) CaseError!void {
    if (std.mem.eql(u8, value, "content")) {
        result.flex_basis = .max_content;
        result.basis = 0;
        return;
    }
    const basis = try parseDimension(value);
    result.flex_basis = basis;
    result.basis = switch (basis) {
        .length => |number| number,
        .auto, .percent, .min_content, .max_content, .fit_content => 0,
    };
}

fn applyGap(result: *style.Style, value: []const u8) CaseError!void {
    const gap = try parseGap(value);
    result.gap = gap;
    result.column_gap = gap;
    result.row_gap = gap;
    result.grid_column_gap = gap;
    result.grid_row_gap = gap;
}

fn applyColumnGap(result: *style.Style, value: []const u8) CaseError!void {
    result.gap = 0;
    const gap = try parseGap(value);
    result.column_gap = gap;
    result.grid_column_gap = gap;
}

fn applyRowGap(result: *style.Style, value: []const u8) CaseError!void {
    result.gap = 0;
    const gap = try parseGap(value);
    result.row_gap = gap;
    result.grid_row_gap = gap;
}

fn applyJustifyContent(result: *style.Style, value: []const u8) CaseError!void {
    result.justify = if (std.mem.eql(u8, value, "start") or
        std.mem.eql(u8, value, "flex-start"))
        .start
    else if (std.mem.eql(u8, value, "center"))
        .center
    else if (std.mem.eql(u8, value, "end") or
        std.mem.eql(u8, value, "flex-end"))
        .end
    else if (std.mem.eql(u8, value, "space-between"))
        .space_between
    else if (std.mem.eql(u8, value, "space-around"))
        .space_around
    else if (std.mem.eql(u8, value, "space-evenly"))
        .space_evenly
    else
        return error.Unsupported;
    result.grid_justify_content = result.justify;
}

fn applyAlignItems(result: *style.Style, value: []const u8) CaseError!void {
    result.@"align" = try parseAlign(value);
    result.grid_align_items = result.@"align";
}

fn applyAlignSelf(result: *style.Style, value: []const u8) CaseError!void {
    result.align_self = try parseAlignSelf(value);
    result.grid_align_self = result.align_self;
}

fn applyJustifyItems(result: *style.Style, value: []const u8) CaseError!void {
    result.grid_justify_items = try parseAlign(value);
}

fn applyJustifySelf(result: *style.Style, value: []const u8) CaseError!void {
    result.grid_justify_self = try parseAlignSelf(value);
}

fn applyAlignContent(result: *style.Style, value: []const u8) CaseError!void {
    result.align_content = if (std.mem.eql(u8, value, "stretch"))
        .stretch
    else if (std.mem.eql(u8, value, "start") or
        std.mem.eql(u8, value, "flex-start"))
        .start
    else if (std.mem.eql(u8, value, "center"))
        .center
    else if (std.mem.eql(u8, value, "end") or
        std.mem.eql(u8, value, "flex-end"))
        .end
    else if (std.mem.eql(u8, value, "space-between"))
        .space_between
    else if (std.mem.eql(u8, value, "space-around"))
        .space_around
    else if (std.mem.eql(u8, value, "space-evenly"))
        .space_evenly
    else
        return error.Unsupported;
    result.grid_align_content = result.align_content;
}

fn applyAspectRatio(result: *style.Style, value: []const u8) CaseError!void {
    if (std.mem.eql(u8, value, "auto")) {
        result.aspect_ratio = null;
        return;
    }
    if (std.mem.indexOf(u8, value, "/") != null or
        std.mem.indexOfAny(u8, value, " \t\n\r") != null)
    {
        return error.Unsupported;
    }
    const ratio = try parseNumber(value);
    if (ratio <= 0) return error.InvalidFixture;
    result.aspect_ratio = ratio;
}

fn applyOverflowAxis(target: *style.Overflow, value: []const u8) CaseError!void {
    target.* = if (std.mem.eql(u8, value, "visible"))
        .visible
    else if (std.mem.eql(u8, value, "hidden"))
        .hidden
    else if (std.mem.eql(u8, value, "clip"))
        .clip
    else if (std.mem.eql(u8, value, "scroll"))
        .scroll
    else if (std.mem.eql(u8, value, "auto"))
        .auto
    else
        return error.Unsupported;
}

fn applyFloat(result: *style.Style, value: []const u8) CaseError!void {
    result.float = if (std.mem.eql(u8, value, "none"))
        .none
    else if (std.mem.eql(u8, value, "left"))
        .left
    else if (std.mem.eql(u8, value, "right"))
        .right
    else if (std.mem.eql(u8, value, "inline-start"))
        .inline_start
    else if (std.mem.eql(u8, value, "inline-end"))
        .inline_end
    else
        return error.Unsupported;
}

fn applyClear(result: *style.Style, value: []const u8) CaseError!void {
    result.clear = if (std.mem.eql(u8, value, "none"))
        .none
    else if (std.mem.eql(u8, value, "left"))
        .left
    else if (std.mem.eql(u8, value, "right"))
        .right
    else if (std.mem.eql(u8, value, "both"))
        .both
    else if (std.mem.eql(u8, value, "inline-start"))
        .inline_start
    else if (std.mem.eql(u8, value, "inline-end"))
        .inline_end
    else
        return error.Unsupported;
}

fn parseAlign(value: []const u8) CaseError!style.Align {
    return if (std.mem.eql(u8, value, "stretch"))
        .stretch
    else if (std.mem.eql(u8, value, "start") or
        std.mem.eql(u8, value, "flex-start"))
        .start
    else if (std.mem.eql(u8, value, "center"))
        .center
    else if (std.mem.eql(u8, value, "end") or
        std.mem.eql(u8, value, "flex-end"))
        .end
    else if (std.mem.eql(u8, value, "baseline"))
        .baseline
    else
        error.Unsupported;
}

fn parseAlignSelf(value: []const u8) CaseError!style.AlignSelf {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    return switch (try parseAlign(value)) {
        .stretch => .stretch,
        .start => .start,
        .center => .center,
        .end => .end,
        .baseline => .baseline,
    };
}

const RepeatSpec = struct {
    count: usize,
    body: []const u8,
};

fn trackTokenEstimatedSize(token: []const u8, available_size: ?f32) f32 {
    const track = parseGridTrackToken(token) catch return 0;
    return switch (track) {
        .fixed => |v| v,
        .percent => |p| if (available_size) |avail| p * avail else 0,
        .fit_content => |v| v,
        .minmax => |mm| switch (mm.min) {
            .fixed => |v| v,
            .percent => |p| if (available_size) |avail| p * avail else 0,
            .fit_content => |v| v,
            .auto, .min_content, .max_content => switch (mm.max) {
                .fixed => |v| v,
                .percent => |p| if (available_size) |avail| p * avail else 0,
                .fit_content => |v| v,
                .auto, .min_content, .max_content, .fr => 0,
            },
            .fr => 0,
        },
        .auto, .min_content, .max_content, .fr => 0,
    };
}

fn parseRepeatHeader(token: []const u8, available_size: ?f32, gap: f32) CaseError!RepeatSpec {
    if (!std.mem.endsWith(u8, token, ")")) return error.Unsupported;
    const inner = token[7 .. token.len - 1];
    var comma: ?usize = null;
    var depth: usize = 0;
    for (inner, 0..) |character, index| {
        if (character == '(') {
            depth += 1;
        } else if (character == ')') {
            if (depth == 0) return error.InvalidFixture;
            depth -= 1;
        } else if (character == ',' and depth == 0) {
            if (comma != null) return error.InvalidFixture;
            comma = index;
            break;
        }
    }
    if (depth != 0) return error.InvalidFixture;
    const split = comma orelse return error.InvalidFixture;
    const count_str = std.mem.trim(u8, inner[0..split], " \t\n\r");
    if (count_str.len == 0) return error.InvalidFixture;
    const body = std.mem.trim(u8, inner[split + 1 ..], " \t\n\r");
    if (body.len == 0) return error.InvalidFixture;

    if (std.mem.eql(u8, count_str, "auto-fill") or std.mem.eql(u8, count_str, "auto-fit")) {
        var cursor: usize = 0;
        var pattern_size: f32 = 0;
        var inner_count: usize = 0;
        while (try nextGridTrackToken(body, &cursor)) |inner_token| {
            if (std.mem.startsWith(u8, inner_token, "repeat(")) {
                return error.Unsupported;
            }
            pattern_size += trackTokenEstimatedSize(inner_token, available_size);
            inner_count += 1;
        }
        if (inner_count == 0) return error.InvalidFixture;
        const count: usize = if (available_size) |avail| blk: {
            if (avail > 0 and (pattern_size + gap) > 0) {
                const raw = @floor((avail + gap) / (pattern_size + gap));
                break :blk @max(@as(usize, 1), @as(usize, @intFromFloat(raw)));
            }
            break :blk 1;
        } else 1;
        if (count > 1024) return error.Unsupported;
        return .{ .count = count, .body = body };
    }

    const count = std.fmt.parseInt(usize, count_str, 10) catch {
        return error.InvalidFixture;
    };
    if (count == 0) return error.InvalidFixture;
    if (count > 1024) return error.Unsupported;
    return .{ .count = count, .body = body };
}

fn countRepeatTracks(token: []const u8, available_size: ?f32, gap: f32) CaseError!usize {
    const repeat_spec = try parseRepeatHeader(token, available_size, gap);
    var cursor: usize = 0;
    var inner_count: usize = 0;
    while (try nextGridTrackToken(repeat_spec.body, &cursor)) |inner_token| {
        if (std.mem.startsWith(u8, inner_token, "repeat(")) {
            return error.Unsupported;
        }
        _ = try parseGridTrackToken(inner_token);
        inner_count += 1;
    }
    if (inner_count == 0) return error.InvalidFixture;
    const total = std.math.mul(usize, repeat_spec.count, inner_count) catch return error.Unsupported;
    if (total > 1024) return error.Unsupported;
    return total;
}

fn parseGridTemplate(
    resources: *FixtureResources,
    value: []const u8,
    available_size: ?f32,
    gap: f32,
) CaseError![]const style.GridTrack {
    const count = try countGridTracks(value, available_size, gap);
    const owned = try resources.allocator.alloc(style.GridTrack, count);
    errdefer resources.allocator.free(owned);

    var cursor: usize = 0;
    var index: usize = 0;
    while (try nextGridTrackToken(value, &cursor)) |token| {
        if (std.mem.startsWith(u8, token, "repeat(")) {
            const repeat_spec = try parseRepeatHeader(token, available_size, gap);
            var rep_i: usize = 0;
            while (rep_i < repeat_spec.count) : (rep_i += 1) {
                var inner_cursor: usize = 0;
                while (try nextGridTrackToken(repeat_spec.body, &inner_cursor)) |inner_token| {
                    owned[index] = try parseGridTrackToken(inner_token);
                    index += 1;
                }
            }
        } else {
            owned[index] = try parseGridTrackToken(token);
            index += 1;
        }
    }
    std.debug.assert(index == count);
    try resources.grid_track_allocations.append(resources.allocator, owned);
    return owned;
}

fn countGridTracks(value: []const u8, available_size: ?f32, gap: f32) CaseError!usize {
    var cursor: usize = 0;
    var count: usize = 0;
    while (try nextGridTrackToken(value, &cursor)) |token| {
        if (std.mem.startsWith(u8, token, "repeat(")) {
            count += try countRepeatTracks(token, available_size, gap);
        } else {
            _ = try parseGridTrackToken(token);
            count += 1;
        }
    }
    if (count == 0) return error.InvalidFixture;
    return count;
}

fn nextGridTrackToken(
    value: []const u8,
    cursor: *usize,
) CaseError!?[]const u8 {
    while (cursor.* < value.len and isFixtureWhitespace(value[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* == value.len) return null;

    const start = cursor.*;
    var depth: usize = 0;
    while (cursor.* < value.len) {
        const character = value[cursor.*];
        if (character == '(') {
            depth += 1;
        } else if (character == ')') {
            if (depth == 0) return error.InvalidFixture;
            depth -= 1;
        } else if (isFixtureWhitespace(character) and depth == 0) {
            break;
        }
        cursor.* += 1;
    }
    if (depth != 0) return error.InvalidFixture;
    return value[start..cursor.*];
}

fn isFixtureWhitespace(character: u8) bool {
    return character == ' ' or character == '\t' or character == '\n' or
        character == '\r';
}

fn parseGridAutoTrack(
    resources: *FixtureResources,
    value: []const u8,
) CaseError!style.GridTrack {
    _ = resources;
    return parseSingleGridTrack(value);
}

fn parseSingleGridTrack(value: []const u8) CaseError!style.GridTrack {
    var cursor: usize = 0;
    const token = (try nextGridTrackToken(value, &cursor)) orelse {
        return error.InvalidFixture;
    };
    if ((try nextGridTrackToken(value, &cursor)) != null) {
        return error.Unsupported;
    }
    return parseGridTrackToken(token);
}

fn parseGridTrackToken(token: []const u8) CaseError!style.GridTrack {
    if (token.len == 0) return error.InvalidFixture;
    if (token[0] == '[' or std.mem.startsWith(u8, token, "repeat(")) {
        return error.Unsupported;
    }
    if (std.mem.startsWith(u8, token, "fit-content(")) {
        return .{ .fit_content = try parseGridFitContent(token) };
    }
    if (std.mem.startsWith(u8, token, "minmax(")) {
        return .{ .minmax = try parseGridMinMax(token) };
    }
    if (std.mem.indexOfScalar(u8, token, '(') != null or
        std.mem.indexOfScalar(u8, token, ')') != null)
    {
        return error.Unsupported;
    }
    if (std.mem.eql(u8, token, "auto")) return .auto;
    if (std.mem.eql(u8, token, "min-content")) return .min_content;
    if (std.mem.eql(u8, token, "max-content")) return .max_content;
    if (std.mem.endsWith(u8, token, "fr")) {
        return .{ .fr = try parseGridNonnegativeNumber(
            token[0 .. token.len - 2],
        ) };
    }
    if (std.mem.endsWith(u8, token, "px")) {
        return .{ .fixed = try parseGridNonnegativeNumber(
            token[0 .. token.len - 2],
        ) };
    }
    if (std.mem.endsWith(u8, token, "%")) {
        return .{ .percent = try parseGridNonnegativeNumber(
            token[0 .. token.len - 1],
        ) / 100.0 };
    }
    if (looksLikeFixtureNumber(token)) {
        const number = try parseNumber(token);
        if (number < 0) return error.InvalidFixture;
        if (number == 0) return .{ .fixed = 0 };
    }
    return error.Unsupported;
}
fn parseGridFitContent(token: []const u8) CaseError!f32 {
    if (!std.mem.endsWith(u8, token, ")")) return error.Unsupported;
    const body = std.mem.trim(u8, token[12 .. token.len - 1], " \t\n\r");
    if (body.len == 0) return error.InvalidFixture;
    if (std.mem.endsWith(u8, body, "px")) {
        return parseGridNonnegativeNumber(body[0 .. body.len - 2]);
    }
    if (std.mem.endsWith(u8, body, "%")) {
        const pct_str = body[0 .. body.len - 1];
        const num = std.fmt.parseFloat(f32, pct_str) catch return error.InvalidFixture;
        if (num < 0) return error.InvalidFixture;
        return error.Unsupported;
    }
    const number = std.fmt.parseFloat(f32, body) catch return error.InvalidFixture;
    if (number < 0) return error.InvalidFixture;
    return number;
}

fn parseGridNonnegativeNumber(value: []const u8) CaseError!f32 {
    const number = try parseNumber(value);
    if (number < 0) return error.InvalidFixture;
    return number;
}

fn looksLikeFixtureNumber(value: []const u8) bool {
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, "nan") or std.mem.eql(u8, value, "inf") or
        std.mem.eql(u8, value, "-inf") or std.mem.eql(u8, value, "+inf"))
    {
        return true;
    }
    return switch (value[0]) {
        '+', '-', '.', '0'...'9' => true,
        else => false,
    };
}

fn parseGridMinMax(token: []const u8) CaseError!style.GridMinMax {
    if (!std.mem.endsWith(u8, token, ")")) return error.Unsupported;
    const body = token[7 .. token.len - 1];
    var comma: ?usize = null;
    var depth: usize = 0;
    for (body, 0..) |character, index| {
        if (character == '(') {
            depth += 1;
        } else if (character == ')') {
            if (depth == 0) return error.InvalidFixture;
            depth -= 1;
        } else if (character == ',' and depth == 0) {
            if (comma != null) return error.InvalidFixture;
            comma = index;
        }
    }
    if (depth != 0) return error.InvalidFixture;
    const split = comma orelse return error.InvalidFixture;
    const min_text = std.mem.trim(u8, body[0..split], " \t\n\r");
    const max_text = std.mem.trim(u8, body[split + 1 ..], " \t\n\r");
    if (min_text.len == 0 or max_text.len == 0) return error.InvalidFixture;
    return .{
        .min = try parseGridBreadth(min_text),
        .max = try parseGridBreadth(max_text),
    };
}

fn parseGridBreadth(value: []const u8) CaseError!style.GridTrackBreadth {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "min-content")) return .min_content;
    if (std.mem.eql(u8, value, "max-content")) return .max_content;
    if (std.mem.startsWith(u8, value, "fit-content(")) {
        return .{ .fit_content = try parseGridFitContent(value) };
    }
    if (std.mem.endsWith(u8, value, "fr")) {
        return .{ .fr = try parseGridNonnegativeNumber(
            value[0 .. value.len - 2],
        ) };
    }
    if (std.mem.endsWith(u8, value, "px")) {
        return .{ .fixed = try parseGridNonnegativeNumber(
            value[0 .. value.len - 2],
        ) };
    }
    if (std.mem.endsWith(u8, value, "%")) {
        return .{ .percent = try parseGridNonnegativeNumber(
            value[0 .. value.len - 1],
        ) / 100.0 };
    }
    if (looksLikeFixtureNumber(value)) {
        const number = try parseNumber(value);
        if (number < 0) return error.InvalidFixture;
        if (number == 0) return .{ .fixed = 0 };
    }
    return error.Unsupported;
}

fn parseGridAutoFlow(value: []const u8) CaseError!style.GridAutoFlow {
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    return if (std.mem.eql(u8, trimmed, "row"))
        .row
    else if (std.mem.eql(u8, trimmed, "column"))
        .column
    else if (std.mem.eql(u8, trimmed, "row dense"))
        .row_dense
    else if (std.mem.eql(u8, trimmed, "column dense"))
        .column_dense
    else
        error.Unsupported;
}

fn parseGridPlacement(value: []const u8) CaseError!style.GridPlacement {
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    if (std.mem.eql(u8, trimmed, "auto")) return .auto;
    if (std.mem.eql(u8, trimmed, "span")) return error.InvalidFixture;
    if (std.mem.startsWith(u8, trimmed, "span") and
        std.ascii.isWhitespace(trimmed[4]))
    {
        const span_text = std.mem.trim(u8, trimmed[4..], " \t\n\r");
        if (span_text.len == 0 or
            std.mem.indexOfAny(u8, span_text, " \t\n\r") != null)
        {
            return error.InvalidFixture;
        }
        const parsed_span = std.fmt.parseInt(i64, span_text, 10) catch {
            if (isNamedGridLine(span_text)) return error.Unsupported;
            return error.InvalidFixture;
        };
        if (parsed_span <= 0) return error.InvalidFixture;
        if (parsed_span > 1024) return error.Unsupported;
        return .{ .span = @intCast(parsed_span) };
    }
    if (std.mem.indexOfAny(u8, trimmed, " \t\n\r") != null) {
        return error.InvalidFixture;
    }
    const line = std.fmt.parseInt(i16, trimmed, 10) catch {
        if (isNamedGridLine(trimmed)) return error.Unsupported;
        return error.InvalidFixture;
    };
    if (line == 0) return error.InvalidFixture;
    return .{ .line = line };
}

fn isNamedGridLine(value: []const u8) bool {
    if (value.len == 0) return false;
    var has_name_character = false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            return false;
        }
        if (std.ascii.isAlphabetic(byte) or byte == '_') {
            has_name_character = true;
        }
    }
    return has_name_character;
}

fn parseGap(value: []const u8) CaseError!f32 {
    if (std.mem.eql(u8, value, "normal")) return error.Unsupported;
    if (std.mem.endsWith(u8, value, "%")) {
        const percentage = try parseNumber(value[0 .. value.len - 1]);
        if (percentage < 0) return error.InvalidFixture;
        return error.Unsupported;
    }
    if (std.mem.indexOfAny(u8, value, " \t\n\r") != null) return error.Unsupported;
    return parseNonnegativeLength(value);
}

fn setDimension(target: *style.Dimension, value: style.Dimension) void {
    target.* = value;
}

fn setInset(target: *style.LengthPercentageAuto, value: style.LengthPercentageAuto) void {
    target.* = value;
}

fn setMargin(result: *style.Style, side: Side, value: style.LengthPercentageAuto) void {
    switch (side) {
        .top => result.margin_inset.top = value,
        .right => result.margin_inset.right = value,
        .bottom => result.margin_inset.bottom = value,
        .left => result.margin_inset.left = value,
    }
    const fixed: f32 = switch (value) {
        .length => |number| number,
        .auto, .percent => 0,
    };
    switch (side) {
        .top => result.margin.top = fixed,
        .right => result.margin.right = fixed,
        .bottom => result.margin.bottom = fixed,
        .left => result.margin.left = fixed,
    }
}

fn setPadding(result: *style.Style, side: Side, value: style.LengthPercentage) void {
    switch (side) {
        .top => result.padding_inset.top = value,
        .right => result.padding_inset.right = value,
        .bottom => result.padding_inset.bottom = value,
        .left => result.padding_inset.left = value,
    }
    const fixed: f32 = switch (value) {
        .length => |number| number,
        .percent => 0,
    };
    switch (side) {
        .top => result.padding.top = fixed,
        .right => result.padding.right = fixed,
        .bottom => result.padding.bottom = fixed,
        .left => result.padding.left = fixed,
    }
}

fn setBorder(result: *style.Style, side: Side, value: f32) void {
    switch (side) {
        .top => {
            result.border.top = value;
            result.border_inset.top = .{ .length = value };
        },
        .right => {
            result.border.right = value;
            result.border_inset.right = .{ .length = value };
        },
        .bottom => {
            result.border.bottom = value;
            result.border_inset.bottom = .{ .length = value };
        },
        .left => {
            result.border.left = value;
            result.border_inset.left = .{ .length = value };
        },
    }
}

fn parseDimension(value: []const u8) CaseError!style.Dimension {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "min-content")) return .min_content;
    if (std.mem.eql(u8, value, "max-content")) return .max_content;
    if (std.mem.eql(u8, value, "fit-content")) return .{ .fit_content = null };
    if (std.mem.startsWith(u8, value, "fit-content(") and std.mem.endsWith(u8, value, ")")) {
        const body = std.mem.trim(u8, value[12 .. value.len - 1], " \t\n\r");
        if (body.len == 0) return error.InvalidFixture;
        const length = try parseNonnegativeLength(body);
        return .{ .fit_content = length };
    }
    if (std.mem.endsWith(u8, value, "%")) {
        const fraction = try parseNumber(value[0 .. value.len - 1]);
        if (fraction < 0) return error.InvalidFixture;
        return .{ .percent = fraction / 100 };
    }
    return .{ .length = try parseNonnegativeLength(value) };
}

fn parseInset(value: []const u8) CaseError!style.LengthPercentageAuto {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.endsWith(u8, value, "%")) {
        return .{ .percent = try parseNumber(value[0 .. value.len - 1]) / 100 };
    }
    return .{ .length = try parseNumberWithOptionalPixels(value) };
}

fn parseLengthPercentage(value: []const u8) CaseError!style.LengthPercentage {
    if (std.mem.endsWith(u8, value, "%")) {
        const fraction = try parseNumber(value[0 .. value.len - 1]);
        if (fraction < 0) return error.InvalidFixture;
        return .{ .percent = fraction / 100 };
    }
    return .{ .length = try parseNonnegativeLength(value) };
}

fn parseNonnegativeLength(value: []const u8) CaseError!f32 {
    const number = try parseNumberWithOptionalPixels(value);
    if (number < 0) return error.InvalidFixture;
    return number;
}

fn parseNumberWithOptionalPixels(value: []const u8) CaseError!f32 {
    const number = if (std.mem.endsWith(u8, value, "px"))
        try parseNumber(value[0 .. value.len - 2])
    else
        try parseNumber(value);
    return number;
}

fn parseNumber(value: []const u8) CaseError!f32 {
    if (value.len == 0) return error.InvalidFixture;
    const number = std.fmt.parseFloat(f32, value) catch return error.InvalidFixture;
    if (!std.math.isFinite(number)) return error.InvalidFixture;
    return number;
}

fn jsonString(value: std.json.Value) CaseError![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFixture,
    };
}

fn pixelsF32(value: []const u8) CaseError!f32 {
    const parsed = try parsePixels(value);
    const result: f32 = @floatCast(parsed);
    if (!std.math.isFinite(result)) return error.InvalidFixture;
    return result;
}

fn finiteF32(value: f64) CaseError!f32 {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidFixture;
    const result: f32 = @floatCast(value);
    if (!std.math.isFinite(result) or result < 0) return error.InvalidFixture;
    return result;
}

fn ahemMeasure(text: []const u8, _: f32, _: u8) widget.Size {
    var line_width: f32 = 0;
    var maximum_width: f32 = 0;
    var line_count: f32 = 1;
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], "\xE2\x80\x8B")) {
            index += 3;
            continue;
        }
        const byte = text[index];
        if (byte == '\n') {
            maximum_width = @max(maximum_width, line_width);
            line_width = 0;
            line_count += 1;
        } else if ((byte & 0b1100_0000) != 0b1000_0000) {
            line_width += ahem_glyph_width;
        }
        index += 1;
    }
    return .{
        .width = @max(maximum_width, line_width),
        .height = line_count * ahem_line_height,
    };
}

fn parsePixels(value: []const u8) FixtureError!f64 {
    if (value.len <= 2) return error.InvalidFixture;
    if (!std.mem.endsWith(u8, value, "px")) return error.InvalidFixture;

    const number = std.fmt.parseFloat(f64, value[0 .. value.len - 2]) catch {
        return error.InvalidFixture;
    };
    if (!std.math.isFinite(number)) return error.InvalidFixture;
    if (number < 0.0) return error.InvalidFixture;
    return number;
}

fn validateExpectedRect(rect: Rect) FixtureError!void {
    if (!std.math.isFinite(rect.x)) return error.InvalidFixture;
    if (!std.math.isFinite(rect.y)) return error.InvalidFixture;
    if (!std.math.isFinite(rect.width)) return error.InvalidFixture;
    if (!std.math.isFinite(rect.height)) return error.InvalidFixture;
    if (rect.width < 0.0) return error.InvalidFixture;
    if (rect.height < 0.0) return error.InvalidFixture;
    if (rect.scroll_width) |scroll_width| {
        if (!std.math.isFinite(scroll_width)) return error.InvalidFixture;
        if (scroll_width < 0.0) return error.InvalidFixture;
    }
    if (rect.scroll_height) |scroll_height| {
        if (!std.math.isFinite(scroll_height)) return error.InvalidFixture;
        if (scroll_height < 0.0) return error.InvalidFixture;
    }
}

fn matchesFilter(fixture_case: Case, filter: ?[]const u8) bool {
    const selected = filter orelse return true;
    if (std.mem.eql(u8, fixture_case.id, selected)) return true;
    return std.mem.eql(u8, fixture_case.source, selected);
}

fn matchesVariant(fixture_case: Case, variant: ?[]const u8) bool {
    const selected = variant orelse return true;
    return std.mem.eql(u8, fixture_case.variant, selected);
}

fn scalarMatchesRounded(actual: f64, expected: f64, use_rounding: bool) bool {
    const compared_actual = if (use_rounding) @round(actual) else actual;
    const compared_expected = if (use_rounding) @round(expected) else expected;
    return @abs(compared_actual - compared_expected) < comparison_tolerance;
}

fn rectMatchesRounded(actual: Rect, expected: Rect, use_rounding: bool) bool {
    if (!scalarMatchesRounded(actual.x, expected.x, use_rounding)) return false;
    if (!scalarMatchesRounded(actual.y, expected.y, use_rounding)) return false;
    if (!scalarMatchesRounded(actual.width, expected.width, use_rounding)) return false;
    return scalarMatchesRounded(actual.height, expected.height, use_rounding);
}

fn validSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        const decimal = byte >= '0' and byte <= '9';
        const lowercase_hex = byte >= 'a' and byte <= 'f';
        if (!decimal and !lowercase_hex) return false;
    }
    return true;
}
