const std = @import("std");

const FrameNodeId = @import("../id.zig").FrameNodeId;
const layout = @import("root.zig");
const layout_context = @import("context.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const text_api = @import("../text.zig");

const cases_path = "testdata/taffy-v0.13.0/normalized/cases.json";
const manifest_path = "testdata/taffy-v0.13.0/MANIFEST.json";

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
const AhemWritingMode = text_api.WritingMode;

pub const FixtureSummary = struct {
    passed: usize = 0,
    failed: usize = 0,
    unsupported: usize = 0,
    unsupported_sha256: [32]u8,
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
    viewport_mode: ViewportMode,
    nodes: []const Node,
    expected: []const Rect,
};

const Size = struct {
    width: f64,
    height: f64,
};

const ViewportMode = struct {
    width: layout_context.MeasureMode,
    height: layout_context.MeasureMode,
};

const Node = struct {
    kind: []const u8,
    text: ?[]const u8 = null,
    writing_mode: ?[]const u8 = null,
    child_count: usize,
    attributes: ?std.json.Value = null,
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

    try validateCorpus(allocator, parsed_corpus.value, parsed_manifest.value);
    try validateSelection(parsed_corpus.value.cases, parsed_manifest.value.selection);
    var unsupported_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    if (count) |maximum| {
        if (maximum == 0) {
            return .{ .unsupported_sha256 = emptyUnsupportedSha256() };
        }
    }

    // SAFETY: The hasher writes the complete digest before this summary returns.
    var summary: FixtureSummary = .{ .unsupported_sha256 = undefined };
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
                    std.log.warn(
                        "fixture\tunsupported\t{s}\t{s}\n",
                        .{ fixture_case.id, fixture_case.variant },
                    );
                    unsupported_hasher.update(fixture_case.id);
                    unsupported_hasher.update("\t");
                    unsupported_hasher.update(fixture_case.variant);
                    unsupported_hasher.update("\n");
                    summary.unsupported += 1;
                    continue;
                },
                error.LayoutFailed => {
                    std.log.warn(
                        "fixture\tlayout_failed\t{s}\t{s}\n",
                        .{ fixture_case.id, fixture_case.variant },
                    );
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
            std.log.warn(
                "fixture\tcompare_failed\t{s}\t{s}\n",
                .{ fixture_case.id, fixture_case.variant },
            );
            summary.failed += 1;
        }
    }

    if (!found) return error.FixtureNotFound;
    unsupported_hasher.final(&summary.unsupported_sha256);
    return summary;
}
fn emptyUnsupportedSha256() [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
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

fn validateCorpus(
    allocator: std.mem.Allocator,
    corpus: Corpus,
    manifest: Manifest,
) FixtureError!void {
    if (corpus.schema != 2) return error.InvalidFixture;
    if (manifest.schema != 2) return error.InvalidFixture;
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
    if (manifest.generator_version != 2) return error.InvalidFixture;
    if (manifest.source_count != manifest.sources.len) return error.InvalidFixture;
    if (manifest.case_count != corpus.cases.len) return error.InvalidFixture;
    if (corpus.cases.len == 0) return error.InvalidFixture;

    var source_hashes: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer source_hashes.deinit(allocator);
    for (manifest.sources) |source| {
        if (!validSha256(source.sha256)) return error.InvalidFixture;
        if (!std.mem.startsWith(u8, source.path, source_prefix)) {
            return error.InvalidFixture;
        }
        if (source_hashes.contains(source.path)) return error.InvalidFixture;
        try source_hashes.put(allocator, source.path, source.sha256);
    }

    var variants_by_source: std.StringHashMapUnmanaged(
        std.StringHashMapUnmanaged(void),
    ) = .empty;
    defer {
        var iterator = variants_by_source.valueIterator();
        while (iterator.next()) |variants| variants.deinit(allocator);
        variants_by_source.deinit(allocator);
    }
    for (corpus.cases) |fixture_case| {
        try validateCaseRecord(fixture_case, &source_hashes);
        const variants = if (variants_by_source.getPtr(fixture_case.source)) |value|
            value
        else blk: {
            const empty: std.StringHashMapUnmanaged(void) = .empty;
            try variants_by_source.put(allocator, fixture_case.source, empty);
            break :blk variants_by_source.getPtr(fixture_case.source) orelse
                return error.InvalidFixture;
        };
        if (variants.*.contains(fixture_case.variant)) return error.InvalidFixture;
        try variants.*.put(allocator, fixture_case.variant, {});
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

fn validateCaseRecord(
    fixture_case: Case,
    source_hashes: *const std.StringHashMapUnmanaged([]const u8),
) FixtureError!void {
    if (!std.mem.startsWith(u8, fixture_case.source, source_prefix)) {
        return error.InvalidFixture;
    }
    if (!std.mem.eql(u8, fixture_case.id, fixture_case.source[source_prefix.len..])) {
        return error.InvalidFixture;
    }
    if (!validSha256(fixture_case.source_sha256)) return error.InvalidFixture;
    if (fixture_case.nodes.len != fixture_case.expected.len) return error.InvalidFixture;
    if (fixture_case.nodes.len == 0) return error.InvalidFixture;

    const source_sha256 = source_hashes.get(fixture_case.source) orelse {
        return error.InvalidFixture;
    };
    if (!std.mem.eql(u8, source_sha256, fixture_case.source_sha256)) {
        return error.InvalidFixture;
    }

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
    source_ids: []FrameNodeId,
    resources: FixtureResources,

    fn init(allocator: std.mem.Allocator, node_count: usize) CaseError!FixtureTree {
        const source_ids = try allocator.alloc(FrameNodeId, node_count);
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

    fn buildRoot(self: *TreeBuilder) CaseError!FrameNodeId {
        const root_id = try self.buildNode(.root);
        if (self.source_index != self.fixture_case.nodes.len) return error.InvalidFixture;
        return root_id;
    }

    fn buildNode(self: *TreeBuilder, parent: FrameNodeId) CaseError!FrameNodeId {
        if (self.source_index >= self.fixture_case.nodes.len) return error.InvalidFixture;
        const index = self.source_index;
        self.source_index += 1;
        if (index >= std.math.maxInt(u32)) return error.InvalidFixture;
        if (index >= self.fixture_case.expected.len) return error.InvalidFixture;
        const id: FrameNodeId = @enumFromInt(@as(u32, @intCast(index + 1)));
        const fixture_node = self.fixture_case.nodes[index];
        const expected = self.fixture_case.expected[index];
        const writing_mode = try fixtureWritingMode(fixture_node);
        const node_style = try fixtureStyle(
            &self.result.resources,
            fixture_node,
        );
        const kind = try fixtureKind(fixture_node, node_style);
        const scroll = try fixtureScrollSpec(&self.result.resources, index, expected);

        var children: std.ArrayList(FrameNodeId) = .empty;
        defer children.deinit(self.allocator);
        for (0..fixture_node.child_count) |_| {
            try children.append(self.allocator, try self.buildNode(id));
        }

        self.result.tree.appendNode(.{
            .id = id,
            .kind = kind,
            .parent = parent,
            .style = node_style,
            .writing_mode = writing_mode,
            .scroll = scroll,
        }) catch |append_error| switch (append_error) {
            error.DuplicateWidgetKey => return error.InvalidFixture,
            error.OutOfMemory => return error.OutOfMemory,
        };
        for (children.items) |child_id| {
            // A missing parent means the fixture's preorder structure is malformed.
            self.result.tree.appendChild(id, child_id) catch |append_error| switch (append_error) {
                error.InvalidStyle => return error.InvalidFixture,
                error.OutOfMemory => return error.OutOfMemory,
            };
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
    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 1 },
        .{ .kind = "text", .text = "H", .child_count = 0 },
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
        .viewport_mode = .{ .width = .definite, .height = .definite },
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
    const child_index = fixture_tree.tree.nodeIndex(child_id) orelse
        return error.TestUnexpectedResult;
    const root_index = fixture_tree.tree.nodeIndex(root_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(child_index < root_index);
    const root = fixture_tree.tree.nodeConst(root_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(child_id, root.children.items[0]);
    const child = fixture_tree.tree.nodeConst(child_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(root_id, child.parent);
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
        fixture_tree.resources.scroll_states_by_source[0] orelse
            return error.TestUnexpectedResult,
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
    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 3 },
        .{ .kind = "div", .child_count = 0 },
        .{ .kind = "div", .child_count = 0 },
        .{ .kind = "div", .child_count = 0 },
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
        .viewport_mode = .{ .width = .definite, .height = .definite },
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
        const node = fixture_tree.tree.nodeConst(fixture_tree.source_ids[source_index]) orelse
            return error.TestUnexpectedResult;
        const owned_state = fixture_tree.resources.scroll_states_by_source[source_index];
        if (expected_axis) |axis| {
            const scroll = node.scroll orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(axis, scroll.axis);
            try std.testing.expectEqual(
                owned_state orelse return error.TestUnexpectedResult,
                scroll.state,
            );
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
    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 0 },
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
        .viewport_mode = .{ .width = .definite, .height = .definite },
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
    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 0 },
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
        .viewport_mode = .{ .width = .definite, .height = .definite },
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

    const state = fixture_tree.resources.scroll_states_by_source[0] orelse
        return error.TestUnexpectedResult;
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
    const node = fixture_tree.tree.node(fixture_tree.source_ids[0]) orelse
        return error.TestUnexpectedResult;
    node.scroll = null;
    try std.testing.expect(!try compareFixtureTree(fixture_case, &fixture_tree));
}

test "fixture rounded comparison derives size from absolute opposing edges" {
    const actual: Rect = .{
        .x = 33.333332,
        .y = 0,
        .width = 33.333332,
        .height = 10,
    };
    const expected_rounded: Rect = .{
        .x = 33,
        .y = 0,
        .width = 34,
        .height = 10,
    };
    try std.testing.expect(rectMatchesRounded(actual, expected_rounded, true));
    try std.testing.expect(!rectMatchesRounded(actual, expected_rounded, false));
    const negative_half: Rect = .{ .x = -0.5, .y = -0.5, .width = 10, .height = 10 };
    const zero_origin: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try std.testing.expect(rectMatchesRounded(negative_half, zero_origin, true));

    const nodes = [_]Node{
        .{ .kind = "div", .child_count = 1 },
        .{ .kind = "div", .child_count = 0 },
    };
    var expected = [_]Rect{
        .{ .x = 40, .y = 20, .width = 70, .height = 20 },
        .{ .x = -7, .y = 0, .width = 34, .height = 10 },
    };
    const fixture_case: Case = .{
        .id = "test",
        .source = "test_fixtures/test.html",
        .source_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .variant = "border_box_ltr",
        .grid_feature = false,
        .use_rounding = true,
        .viewport = .{ .width = 100, .height = 100 },
        .viewport_mode = .{ .width = .definite, .height = .definite },
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

    const root_node = fixture_tree.tree.node(fixture_tree.source_ids[0]) orelse
        return error.TestUnexpectedResult;
    root_node.rect = .{
        .x = 40,
        .y = 20,
        .w = 70,
        .h = 20,
    };
    const child_node = fixture_tree.tree.node(fixture_tree.source_ids[1]) orelse
        return error.TestUnexpectedResult;
    child_node.rect = .{
        .x = -6.666668,
        .y = 0,
        .w = 33.333332,
        .h = 10,
    };
    try std.testing.expect(try compareFixtureTree(fixture_case, &fixture_tree));
    expected[0] = .{ .x = 4, .y = 0, .width = 10, .height = 10 };
    expected[1] = .{ .x = 2, .y = 0, .width = 2, .height = 2 };
    root_node.rect = .{
        .x = 3.5,
        .y = 0,
        .w = 10,
        .h = 10,
    };
    child_node.rect = .{
        .x = 1.5,
        .y = 0,
        .w = 2,
        .h = 2,
    };
    try std.testing.expect(try compareFixtureTree(fixture_case, &fixture_tree));
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
    _ = try builder.buildRoot();

    const available: widget.Size = .{
        .width = try finiteF32(fixture_case.viewport.width),
        .height = try finiteF32(fixture_case.viewport.height),
    };
    layout.layoutTree(&fixture_tree.tree, .{
        .allocator = allocator,
        .available = available,
        .measure = ahemMeasureSource(),
        .width_mode = fixture_case.viewport_mode.width,
        .height_mode = fixture_case.viewport_mode.height,
    }) catch |layout_error| {
        if (layout_error == error.OutOfMemory) return error.OutOfMemory;
        std.log.warn("fixture_layout_error\t{s}\n", .{@errorName(layout_error)});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        return error.LayoutFailed;
    };
    return compareFixtureTree(fixture_case, &fixture_tree);
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
    const origin: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return compareFixtureNode(
        fixture_case,
        fixture_tree,
        &source_index,
        origin,
        origin,
        origin,
    );
}

fn compareFixtureNode(
    fixture_case: Case,
    fixture_tree: *const FixtureTree,
    source_index: *usize,
    expected_parent: Rect,
    actual_parent_unrounded: Rect,
    actual_parent_rounded: Rect,
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
    const actual_unrounded: Rect = .{
        .x = @floatCast(actual_rect.x),
        .y = @floatCast(actual_rect.y),
        .width = @floatCast(actual_rect.w),
        .height = @floatCast(actual_rect.h),
    };
    const actual = if (fixture_case.use_rounding) Rect{
        .x = actual_parent_rounded.x +
            fixtureRound(actual_unrounded.x - actual_parent_unrounded.x),
        .y = actual_parent_rounded.y +
            fixtureRound(actual_unrounded.y - actual_parent_unrounded.y),
        .width = fixtureRound(actual_unrounded.x + actual_unrounded.width) -
            fixtureRound(actual_unrounded.x),
        .height = fixtureRound(actual_unrounded.y + actual_unrounded.height) -
            fixtureRound(actual_unrounded.y),
    } else actual_unrounded;
    if (!rectMatchesRounded(actual, expected_absolute, false)) {
        std.log.warn(
            "fixture_rect\t{s}\t{s}\t{d}\t{s}\tactual={d:.3},{d:.3}," ++
                "{d:.3},{d:.3}\texpected={d:.3},{d:.3},{d:.3},{d:.3}\n",
            .{
                fixture_case.id,
                fixture_case.variant,
                index,
                fixture_case.nodes[index].kind,
                actual.x,
                actual.y,
                actual.width,
                actual.height,
                expected_absolute.x,
                expected_absolute.y,
                expected_absolute.width,
                expected_absolute.height,
            },
        );
        return false;
    }

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
    )) {
        const actual_axis = if (node.scroll) |scroll| @tagName(scroll.axis) else "none";
        const actual_x = if (node.scroll) |scroll| scroll.state.max_offset[0] else -1;
        const actual_y = if (node.scroll) |scroll| scroll.state.max_offset[1] else -1;
        std.log.warn(
            "fixture_scroll\t{s}\t{s}\t{d}\t{s}\taxis={s}\tactual={d:.3},{d:.3}\t" ++
                "expected={d:.3},{d:.3}\n",
            .{
                fixture_case.id,
                fixture_case.variant,
                index,
                fixture_case.nodes[index].kind,
                actual_axis,
                actual_x,
                actual_y,
                expected.scroll_width orelse -1,
                expected.scroll_height orelse -1,
            },
        );
        return false;
    }

    for (0..fixture_case.nodes[index].child_count) |_| {
        if (!try compareFixtureNode(
            fixture_case,
            fixture_tree,
            source_index,
            expected_absolute,
            actual_unrounded,
            actual,
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

fn fixtureWritingMode(fixture_node: Node) CaseError!AhemWritingMode {
    const writing_mode = fixture_node.writing_mode orelse return .horizontal_tb;
    if (std.mem.eql(u8, writing_mode, "horizontal-tb")) return .horizontal_tb;
    if (!std.mem.eql(u8, writing_mode, "vertical-lr")) return error.Unsupported;
    if (!std.mem.eql(u8, fixture_node.kind, "text")) return error.Unsupported;
    return .vertical_lr;
}

fn fixtureStyle(
    resources: *FixtureResources,
    fixture_node: Node,
) CaseError!style.Style {
    const writing_mode = try fixtureWritingMode(fixture_node);

    var result: style.Style = .{ .box_sizing = .border_box };

    var has_flex_direction = false;
    if (fixture_node.attributes) |attributes| {
        const object = switch (attributes) {
            .object => |value| value,
            else => return error.InvalidFixture,
        };
        has_flex_direction = object.contains("flex-direction");
        try applyFixtureAttributes(
            resources,
            &result,
            object,
            writing_mode,
        );
    }
    if (std.mem.eql(u8, fixture_node.kind, "div") and
        result.display == .flex and
        !has_flex_direction)
    {
        result.direction = .row;
    }
    return result;
}

fn validateFixtureWritingModeAttribute(
    writing_mode: AhemWritingMode,
    value: []const u8,
) CaseError!void {
    const expected = switch (writing_mode) {
        .horizontal_tb => "horizontal-tb",
        .vertical_lr => "vertical-lr",
    };
    if (!std.mem.eql(u8, value, expected)) return error.Unsupported;
}

fn applyFixtureAttributes(
    resources: *FixtureResources,
    result: *style.Style,
    attributes: std.json.ObjectMap,
    writing_mode: AhemWritingMode,
) CaseError!void {
    var iterator = attributes.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (isGridTemplateAttribute(name)) continue;
        const value = try jsonString(entry.value_ptr.*);
        if (std.mem.eql(u8, name, "writing-mode")) {
            try validateFixtureWritingModeAttribute(writing_mode, value);
            continue;
        }
        try applyAttributeWithResources(resources, result, name, value);
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

test "fixture Ahem breaks only at zero-width spaces" {
    const measured = try ahemMeasure("H H", .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .{ .definite = 25 }, .height = .max_content },
        .writing_mode = .horizontal_tb,
    });

    try std.testing.expectEqual(@as(f32, 30), measured.width);
    try std.testing.expectEqual(ahem_line_height, measured.height);
}

test "fixture Ahem measures UTF-8 byte lengths" {
    const measured = try ahemMeasure("\xC3\xA9", .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .writing_mode = .horizontal_tb,
    });

    try std.testing.expectEqual(@as(f32, 20), measured.width);
    try std.testing.expectEqual(ahem_line_height, measured.height);
}

// The box owns the reported width, while the ink owns the line count: an
// unbreakable Ahem segment still occupies its min-content glyphs when the
// known box is narrower, and a wider known box merges segments that fit.
test "fixture Ahem wraps unbreakable ink under a known box width" {
    const collapsed = try ahemMeasure("HH\xE2\x80\x8BHH", .{
        .known_dimensions = .{ .width = 0, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .writing_mode = .horizontal_tb,
    });

    try std.testing.expectEqual(@as(f32, 0), collapsed.width);
    try std.testing.expectEqual(@as(f32, 20), collapsed.height);

    const roomy = try ahemMeasure("HH\xE2\x80\x8BHH", .{
        .known_dimensions = .{ .width = 100, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .writing_mode = .horizontal_tb,
    });

    try std.testing.expectEqual(@as(f32, 100), roomy.width);
    try std.testing.expectEqual(ahem_line_height, roomy.height);
}

test "fixture vertical Ahem max-content maps inline size to height" {
    const measured = try ahemMeasure("HH\xE2\x80\x8BHH\xE2\x80\x8BHH", .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .writing_mode = .vertical_lr,
    });

    try std.testing.expectEqual(@as(f32, 10), measured.width);
    try std.testing.expectEqual(@as(f32, 60), measured.height);
}

test "fixture vertical Ahem min-content wraps each unbreakable segment" {
    const measured = try ahemMeasure("HH\xE2\x80\x8BHH\xE2\x80\x8BHH", .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .min_content },
        .writing_mode = .vertical_lr,
    });

    try std.testing.expectEqual(@as(f32, 30), measured.width);
    try std.testing.expectEqual(@as(f32, 20), measured.height);
}

test "fixture vertical Ahem definite height wraps into columns" {
    const measured = try ahemMeasure("HH\xE2\x80\x8BHH\xE2\x80\x8BHH", .{
        .known_dimensions = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .{ .definite = 40 } },
        .writing_mode = .vertical_lr,
    });

    try std.testing.expectEqual(@as(f32, 20), measured.width);
    try std.testing.expectEqual(@as(f32, 40), measured.height);
}

test "fixture vertical Ahem known height overrides available inline size" {
    const measured = try ahemMeasure("HH\xE2\x80\x8BHH\xE2\x80\x8BHH", .{
        .known_dimensions = .{ .width = null, .height = 30 },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .writing_mode = .vertical_lr,
    });

    try std.testing.expectEqual(@as(f32, 30), measured.width);
    try std.testing.expectEqual(@as(f32, 30), measured.height);
}

test "fixture vertical Ahem known width overrides measured block size" {
    const measured = try ahemMeasure("HH\xE2\x80\x8BHH\xE2\x80\x8BHH", .{
        .known_dimensions = .{ .width = 25, .height = null },
        .available_space = .{ .width = .max_content, .height = .{ .definite = 40 } },
        .writing_mode = .vertical_lr,
    });

    try std.testing.expectEqual(@as(f32, 25), measured.width);
    try std.testing.expectEqual(@as(f32, 40), measured.height);
}

test "fixture horizontal Ahem zero-width breaks wrap under definite width" {
    var attributes: std.json.ObjectMap = .empty;
    defer attributes.deinit(std.testing.allocator);
    try attributes.put(std.testing.allocator, "width", .{ .string = "10px" });

    const nodes = [_]Node{.{
        .kind = "text",
        .text = "H\xE2\x80\x8BH",
        .writing_mode = "horizontal-tb",
        .child_count = 0,
        .attributes = .{ .object = attributes },
    }};
    const expected = [_]Rect{
        .{ .x = 0, .y = 0, .width = 10, .height = 20 },
    };
    const fixture_case: Case = .{
        .id = "test",
        .source = "test_fixtures/test.html",
        .source_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .variant = "border_box_ltr",
        .grid_feature = false,
        .use_rounding = false,
        .viewport = .{ .width = 10, .height = 100 },
        .viewport_mode = .{ .width = .definite, .height = .definite },
        .nodes = &nodes,
        .expected = &expected,
    };

    try std.testing.expect(try runCase(std.testing.allocator, fixture_case));
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
    if (std.mem.eql(u8, name, "text-align")) return applyTextAlign(result, value);
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
        result.grid_template_columns = try parseGridTemplate(owner, value);
        return;
    }
    if (std.mem.eql(u8, name, "grid-template-rows")) {
        const owner = resources orelse return error.InvalidFixture;
        result.grid_template_rows = try parseGridTemplate(owner, value);
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
        result.grid_column.start = try parseGridPlacement(value);
        return;
    }
    if (std.mem.eql(u8, name, "grid-column-end")) {
        result.grid_column.end = try parseGridPlacement(value);
        return;
    }
    if (std.mem.eql(u8, name, "grid-row-start")) {
        result.grid_row.start = try parseGridPlacement(value);
        return;
    }
    if (std.mem.eql(u8, name, "grid-row-end")) {
        result.grid_row.end = try parseGridPlacement(value);
        return;
    }
    if (std.mem.eql(u8, name, "aspect-ratio")) return applyAspectRatio(result, value);
    if (std.mem.eql(u8, name, "overflow-x")) return applyOverflowAxis(&result.overflow.width, value);
    if (std.mem.eql(u8, name, "overflow-y")) return applyOverflowAxis(&result.overflow.height, value);
    if (std.mem.eql(u8, name, "scrollbar-width")) {
        result.scrollbar_width = try parseNonnegativeLength(value);
        return;
    }
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
        try std.testing.expectEqual(case.expected, result.flex_wrap);
    }
}

test "fixture flex display defaults to row unless direction is explicit" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var implicit_attributes: std.json.ObjectMap = .empty;
    defer implicit_attributes.deinit(std.testing.allocator);
    const implicit_style = try fixtureStyle(
        &fixture_tree.resources,
        .{
            .kind = "div",
            .child_count = 0,
            .attributes = .{ .object = implicit_attributes },
        },
    );

    var default_attributes: std.json.ObjectMap = .empty;
    defer default_attributes.deinit(std.testing.allocator);
    try default_attributes.put(std.testing.allocator, "display", .{ .string = "flex" });
    const default_style = try fixtureStyle(
        &fixture_tree.resources,
        .{
            .kind = "div",
            .child_count = 0,
            .attributes = .{ .object = default_attributes },
        },
    );

    var block_attributes: std.json.ObjectMap = .empty;
    defer block_attributes.deinit(std.testing.allocator);
    try block_attributes.put(std.testing.allocator, "display", .{ .string = "block" });
    const block_style = try fixtureStyle(
        &fixture_tree.resources,
        .{
            .kind = "div",
            .child_count = 0,
            .attributes = .{ .object = block_attributes },
        },
    );

    var explicit_attributes: std.json.ObjectMap = .empty;
    defer explicit_attributes.deinit(std.testing.allocator);
    try explicit_attributes.put(
        std.testing.allocator,
        "flex-direction",
        .{ .string = "column" },
    );
    try explicit_attributes.put(std.testing.allocator, "display", .{ .string = "flex" });
    const explicit_style = try fixtureStyle(
        &fixture_tree.resources,
        .{
            .kind = "div",
            .child_count = 0,
            .attributes = .{ .object = explicit_attributes },
        },
    );

    try std.testing.expectEqual(style.Display.flex, implicit_style.display);
    try std.testing.expectEqual(style.FlexDirection.row, implicit_style.direction);
    try std.testing.expectEqual(style.Display.flex, default_style.display);
    try std.testing.expectEqual(style.FlexDirection.row, default_style.direction);
    try std.testing.expectEqual(style.Display.block, block_style.display);
    try std.testing.expectEqual(style.FlexDirection.column, block_style.direction);
    try std.testing.expectEqual(style.Display.flex, explicit_style.display);
    try std.testing.expectEqual(style.FlexDirection.column, explicit_style.direction);
}

test "fixture flex item attributes map canonical values" {
    var result: style.Style = .{};
    try applyAttribute(&result, "flex-grow", "2.5");
    try applyAttribute(&result, "flex-shrink", "0.5");
    try std.testing.expectEqual(@as(f32, 2.5), result.grow);
    try std.testing.expectEqual(@as(f32, 0.5), result.shrink);

    try applyAttribute(&result, "flex-basis", "12px");
    try std.testing.expectEqual(style.Dimension{ .length = 12 }, result.flex_basis);

    try applyAttribute(&result, "flex-basis", "25%");
    try std.testing.expectEqual(style.Dimension{ .percent = 0.25 }, result.flex_basis);

    try applyAttribute(&result, "flex-basis", "min-content");
    try std.testing.expectEqual(@as(style.Dimension, .min_content), result.flex_basis);

    try applyAttribute(&result, "flex-basis", "max-content");
    try std.testing.expectEqual(@as(style.Dimension, .max_content), result.flex_basis);

    try applyAttribute(&result, "flex-basis", "fit-content");
    try std.testing.expectEqual(style.Dimension{ .fit_content = null }, result.flex_basis);

    try applyAttribute(&result, "width", "fit-content(40px)");
    try std.testing.expectEqual(style.Dimension{ .fit_content = 40 }, result.size.width);

    try applyAttribute(&result, "flex-basis", "auto");
    try std.testing.expectEqual(@as(style.Dimension, .auto), result.flex_basis);
}

test "fixture gap attributes map canonical fields" {
    var result: style.Style = .{};
    try applyAttribute(&result, "gap", "4px");
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 4 }), result.gap));
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 4 }), result.column_gap));
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 4 }), result.row_gap));

    try applyAttribute(&result, "column-gap", "0");
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 0 }), result.gap));
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 0 }), result.column_gap));
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 4 }), result.row_gap));

    try applyAttribute(&result, "row-gap", "6px");
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 0 }), result.gap));
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 0 }), result.column_gap));
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 6 }), result.row_gap));

    var reordered: style.Style = .{};
    try applyAttribute(&reordered, "row-gap", "3px");
    try applyAttribute(&reordered, "column-gap", "2px");
    try applyAttribute(&reordered, "gap", "1px");
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 1 }), reordered.gap));
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 1 }), reordered.column_gap));
    try std.testing.expect(std.meta.eql(@as(style.LengthPercentage, .{ .length = 1 }), reordered.row_gap));
}

test "fixture alignment attributes preserve flex-relative tokens" {
    const cases = [_]struct {
        value: []const u8,
        expected: style.Justify,
    }{
        .{ .value = "start", .expected = .start },
        .{ .value = "flex-start", .expected = .flex_start },
        .{ .value = "center", .expected = .center },
        .{ .value = "safe center", .expected = .safe_center },
        .{ .value = "unsafe center", .expected = .unsafe_center },
        .{ .value = "end", .expected = .end },
        .{ .value = "flex-end", .expected = .flex_end },
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

test "fixture item alignment preserves represented tokens" {
    const item_cases = [_]struct {
        value: []const u8,
        expected: style.Align,
    }{
        .{ .value = "stretch", .expected = .stretch },
        .{ .value = "start", .expected = .start },
        .{ .value = "flex-start", .expected = .flex_start },
        .{ .value = "center", .expected = .center },
        .{ .value = "safe center", .expected = .safe_center },
        .{ .value = "unsafe center", .expected = .unsafe_center },
        .{ .value = "end", .expected = .end },
        .{ .value = "flex-end", .expected = .flex_end },
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
        .{ .value = "flex-start", .expected = .flex_start },
        .{ .value = "center", .expected = .center },
        .{ .value = "safe center", .expected = .safe_center },
        .{ .value = "unsafe center", .expected = .unsafe_center },
        .{ .value = "end", .expected = .end },
        .{ .value = "flex-end", .expected = .flex_end },
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
        .{ .value = "flex-start", .expected = .flex_start },
        .{ .value = "center", .expected = .center },
        .{ .value = "safe center", .expected = .safe_center },
        .{ .value = "unsafe center", .expected = .unsafe_center },
        .{ .value = "end", .expected = .end },
        .{ .value = "flex-end", .expected = .flex_end },
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

test "fixture alignment parser maps future positions" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    const justify_content_cases = [_]struct {
        value: []const u8,
        expected: style.Justify,
    }{
        .{ .value = "safe end", .expected = .safe_end },
        .{ .value = "unsafe end", .expected = .unsafe_end },
    };
    for (justify_content_cases) |case| {
        var result: style.Style = .{};
        try applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "justify-content",
            case.value,
        );
        try std.testing.expectEqual(case.expected, result.justify);
        try std.testing.expectEqual(case.expected, result.grid_justify_content);
    }

    const align_content_cases = [_]struct {
        value: []const u8,
        expected: style.AlignContent,
    }{
        .{ .value = "safe end", .expected = .safe_end },
        .{ .value = "unsafe end", .expected = .unsafe_end },
    };
    for (align_content_cases) |case| {
        var result: style.Style = .{};
        try applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "align-content",
            case.value,
        );
        try std.testing.expectEqual(case.expected, result.align_content);
        try std.testing.expectEqual(case.expected, result.grid_align_content);
    }

    const align_items_cases = [_]struct {
        value: []const u8,
        expected: style.Align,
    }{
        .{ .value = "safe end", .expected = .safe_end },
        .{ .value = "unsafe end", .expected = .unsafe_end },
        .{ .value = "self-start", .expected = .self_start },
        .{ .value = "self-end", .expected = .self_end },
    };
    for (align_items_cases) |case| {
        var result: style.Style = .{};
        try applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "align-items",
            case.value,
        );
        try std.testing.expectEqual(case.expected, result.@"align");
        try std.testing.expectEqual(case.expected, result.grid_align_items);
    }

    const align_self_cases = [_]struct {
        value: []const u8,
        expected: style.AlignSelf,
    }{
        .{ .value = "safe end", .expected = .safe_end },
        .{ .value = "unsafe end", .expected = .unsafe_end },
        .{ .value = "self-start", .expected = .self_start },
        .{ .value = "self-end", .expected = .self_end },
    };
    for (align_self_cases) |case| {
        var result: style.Style = .{};
        try applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "align-self",
            case.value,
        );
        try std.testing.expectEqual(case.expected, result.align_self);
        try std.testing.expectEqual(case.expected, result.grid_align_self);
    }

    const justify_items_cases = [_]struct {
        value: []const u8,
        expected: style.Align,
    }{
        .{ .value = "safe end", .expected = .safe_end },
        .{ .value = "unsafe end", .expected = .unsafe_end },
        .{ .value = "self-start", .expected = .self_start },
        .{ .value = "self-end", .expected = .self_end },
    };
    for (justify_items_cases) |case| {
        var result: style.Style = .{};
        try applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "justify-items",
            case.value,
        );
        try std.testing.expectEqual(case.expected, result.grid_justify_items);
    }

    const justify_self_cases = [_]struct {
        value: []const u8,
        expected: style.AlignSelf,
    }{
        .{ .value = "safe end", .expected = .safe_end },
        .{ .value = "unsafe end", .expected = .unsafe_end },
        .{ .value = "self-start", .expected = .self_start },
        .{ .value = "self-end", .expected = .self_end },
    };
    for (justify_self_cases) |case| {
        var result: style.Style = .{};
        try applyAttributeWithResources(
            &fixture_tree.resources,
            &result,
            "justify-self",
            case.value,
        );
        try std.testing.expectEqual(case.expected, result.grid_justify_self);
    }
}

test "fixture text align maps physical values and WebKit aliases" {
    const cases = [_]struct {
        value: []const u8,
        expected: style.TextAlign,
    }{
        .{ .value = "-webkit-left", .expected = .left },
        .{ .value = "-webkit-center", .expected = .center },
        .{ .value = "-webkit-right", .expected = .right },
    };
    for (cases) |case| {
        var result: style.Style = .{};
        try applyAttribute(&result, "text-align", case.value);
        try std.testing.expectEqual(case.expected, result.text_align);
    }
}

test "fixture unsupported alignment values stay explicit" {
    const cases = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "justify-content", .value = "baseline" },
        .{ .name = "aspect-ratio", .value = "1 / 2" },
        .{ .name = "text-align", .value = "diagonal" },
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

test "fixture scrollbar width parses finite nonnegative values" {
    var result: style.Style = .{};
    if (comptime @hasField(style.Style, "scrollbar_width")) {
        try applyAttribute(&result, "scrollbar-width", "15");
        try std.testing.expectEqual(@as(f32, 15), @field(result, "scrollbar_width"));

        const invalid_values = [_][]const u8{ "-1", "nan", "inf", "15pxjunk" };
        for (invalid_values) |value| {
            var invalid: style.Style = .{};
            try std.testing.expectError(
                error.InvalidFixture,
                applyAttribute(&invalid, "scrollbar-width", value),
            );
        }
    } else {
        // Keep the RED phase behavioral: the unsupported parser result is
        // reported by the test instead of an absent-field compile error.
        try applyAttribute(&result, "scrollbar-width", "15");
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

    try std.testing.expectError(error.Unsupported, fixtureStyle(
        &fixture_tree.resources,
        .{
            .kind = "div",
            .writing_mode = "vertical-rl",
            .child_count = 0,
        },
    ));
}
test "fixture omitted box sizing uses pinned border box default" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);
    const node: Node = .{
        .kind = "div",
        .child_count = 0,
    };
    const default_style = try fixtureStyle(&fixture_tree.resources, node);

    var attributes: std.json.ObjectMap = .empty;
    defer attributes.deinit(std.testing.allocator);
    try attributes.put(std.testing.allocator, "box-sizing", .{ .string = "content-box" });
    const explicit_style = try fixtureStyle(&fixture_tree.resources, .{
        .kind = "div",
        .child_count = 0,
        .attributes = .{ .object = attributes },
    });

    try std.testing.expectEqual(style.BoxSizing.border_box, default_style.box_sizing);
    try std.testing.expectEqual(style.BoxSizing.content_box, explicit_style.box_sizing);
}

test "fixture text preserves automatic dimensions for canonical measurement" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);
    const node: Node = .{
        .kind = "text",
        .text = "HHHH",
        .child_count = 0,
    };
    const text_style = try fixtureStyle(&fixture_tree.resources, node);
    try std.testing.expectEqual(@as(style.Dimension, .auto), text_style.size.width);
    try std.testing.expectEqual(@as(style.Dimension, .auto), text_style.size.height);
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
    try std.testing.expectEqual(@as(usize, 1), result.grid_auto_columns.len);
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .{ .minmax = .{
            .min = .{ .fixed = 10 },
            .max = .{ .fr = 2 },
        } }),
        result.grid_auto_columns[0],
    ));
    try std.testing.expectEqual(@as(usize, 1), result.grid_auto_rows.len);
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .max_content),
        result.grid_auto_rows[0],
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

test "fixture grid auto columns cycle the complete track list" {
    var attributes: std.json.ObjectMap = .empty;
    defer attributes.deinit(std.testing.allocator);
    try attributes.put(std.testing.allocator, "display", .{ .string = "grid" });
    try attributes.put(std.testing.allocator, "width", .{ .string = "70px" });
    try attributes.put(std.testing.allocator, "height", .{ .string = "10px" });
    try attributes.put(std.testing.allocator, "grid-auto-flow", .{ .string = "column" });
    try attributes.put(
        std.testing.allocator,
        "grid-auto-columns",
        .{ .string = "10px 20px 30px" },
    );

    const nodes = [_]Node{
        .{
            .kind = "div",
            .child_count = 4,
            .attributes = .{ .object = attributes },
        },
        .{ .kind = "div", .child_count = 0 },
        .{ .kind = "div", .child_count = 0 },
        .{ .kind = "div", .child_count = 0 },
        .{ .kind = "div", .child_count = 0 },
    };
    const expected = [_]Rect{
        .{ .x = 0, .y = 0, .width = 70, .height = 10 },
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .{ .x = 10, .y = 0, .width = 20, .height = 10 },
        .{ .x = 30, .y = 0, .width = 30, .height = 10 },
        .{ .x = 60, .y = 0, .width = 10, .height = 10 },
    };
    const fixture_case: Case = .{
        .id = "test",
        .source = "test_fixtures/test.html",
        .source_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .variant = "border_box_ltr",
        .grid_feature = true,
        .use_rounding = false,
        .viewport = .{ .width = 70, .height = 10 },
        .viewport_mode = .{ .width = .definite, .height = .definite },
        .nodes = &nodes,
        .expected = &expected,
    };

    try std.testing.expect(try runCase(std.testing.allocator, fixture_case));
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
    try expectSemanticRepeat(
        result.grid_template_columns,
        .{ .count = 4 },
        &[_]style.GridTrack{.{ .fixed = 50 }},
    );

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "10px repeat(2, 1fr 2fr) 20px",
    );
    const expected_mixed = [_]style.GridTrack{
        .{ .fixed = 10 },
        .{ .repeat = .{
            .kind = .{ .count = 2 },
            .tracks = &.{ .{ .fr = 1 }, .{ .fr = 2 } },
        } },
        .{ .fixed = 20 },
    };
    try std.testing.expectEqual(expected_mixed.len, result.grid_template_columns.len);
    for (expected_mixed, result.grid_template_columns) |expected, actual| {
        switch (expected) {
            .repeat => |expected_repeat| switch (actual) {
                .repeat => |actual_repeat| {
                    try std.testing.expectEqual(expected_repeat.kind, actual_repeat.kind);
                    try std.testing.expectEqual(expected_repeat.tracks.len, actual_repeat.tracks.len);
                    for (expected_repeat.tracks, actual_repeat.tracks) |nested_expected, nested_actual| {
                        try std.testing.expect(std.meta.eql(nested_expected, nested_actual));
                    }
                },
                else => try std.testing.expect(false),
            },
            else => try std.testing.expect(std.meta.eql(expected, actual)),
        }
    }

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-rows",
        "fit-content(20px) repeat(2, minmax(10px, 1fr)) fit-content(30px)",
    );
    const expected_rows = [_]style.GridTrack{
        .{ .fit_content = .{ .length = 20 } },
        .{ .repeat = .{
            .kind = .{ .count = 2 },
            .tracks = &.{.{ .minmax = .{
                .min = .{ .fixed = 10 },
                .max = .{ .fr = 1 },
            } }},
        } },
        .{ .fit_content = .{ .length = 30 } },
    };
    try std.testing.expectEqual(expected_rows.len, result.grid_template_rows.len);
    for (expected_rows, result.grid_template_rows) |expected, actual| {
        switch (expected) {
            .repeat => |expected_repeat| switch (actual) {
                .repeat => |actual_repeat| {
                    try std.testing.expectEqual(expected_repeat.kind, actual_repeat.kind);
                    try std.testing.expectEqual(expected_repeat.tracks.len, actual_repeat.tracks.len);
                    for (expected_repeat.tracks, actual_repeat.tracks) |nested_expected, nested_actual| {
                        try std.testing.expect(std.meta.eql(nested_expected, nested_actual));
                    }
                },
                else => try std.testing.expect(false),
            },
            else => try std.testing.expect(std.meta.eql(expected, actual)),
        }
    }

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-auto-columns",
        "fit-content(50px)",
    );
    try std.testing.expectEqual(@as(usize, 1), result.grid_auto_columns.len);
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .{ .fit_content = .{ .length = 50 } }),
        result.grid_auto_columns[0],
    ));

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "fit-content(50%)",
    );
    try std.testing.expectEqual(
        style.GridTrack{ .fit_content = .{ .percent = 0.5 } },
        result.grid_template_columns[0],
    );
}

test "fixture grid templates parse auto-fit and auto-fill repeat patterns" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    result.size.width = .{ .length = 200 };
    result.column_gap = .{ .length = 10 };
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "repeat(auto-fit, 60px)",
    );
    try expectSemanticRepeat(
        result.grid_template_columns,
        .auto_fit,
        &[_]style.GridTrack{.{ .fixed = 60 }},
    );

    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "repeat(auto-fill, minmax(40px, 1fr))",
    );
    try expectSemanticRepeat(
        result.grid_template_columns,
        .auto_fill,
        &[_]style.GridTrack{.{ .minmax = .{
            .min = .{ .fixed = 40 },
            .max = .{ .fr = 1 },
        } }},
    );
}

test "fixture grid auto-fill preserves semantic repeat under border-box sizing" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    try applyAttribute(&result, "display", "grid");
    try applyAttribute(&result, "box-sizing", "border-box");
    try applyAttribute(&result, "width", "100px");
    try applyAttribute(&result, "overflow-y", "scroll");
    try applyAttribute(&result, "scrollbar-width", "15");
    try applyAttribute(&result, "gap", "0");
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "repeat(auto-fill, 30px)",
    );

    try expectSemanticRepeat(result.grid_template_columns, .auto_fill, &[_]style.GridTrack{
        .{ .fixed = 30 },
    });
}

test "fixture grid auto-fill preserves semantic repeat under content-box sizing" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    try applyAttribute(&result, "display", "grid");
    try applyAttribute(&result, "box-sizing", "content-box");
    try applyAttribute(&result, "width", "100px");
    try applyAttribute(&result, "overflow-y", "scroll");
    try applyAttribute(&result, "scrollbar-width", "15");
    try applyAttribute(&result, "gap", "0");
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-template-columns",
        "repeat(auto-fill, 30px)",
    );

    try expectSemanticRepeat(result.grid_template_columns, .auto_fill, &[_]style.GridTrack{
        .{ .fixed = 30 },
    });
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
        result.grid_row.end,
    ));
    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-row-end", "span 255");
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .span = 255 }),
        result.grid_row.end,
    ));
    try applyAttributeWithResources(&fixture_tree.resources, &result, "grid-row-end", "span  2");
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .span = 2 }),
        result.grid_row.end,
    ));

    const invalid = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "grid-column-start", .value = "0" },
        .{ .name = "grid-column-end", .value = "span 0" },
        .{ .name = "grid-row-end", .value = "span -1" },
        .{ .name = "grid-row-end", .value = "span" },
        .{ .name = "grid-row-end", .value = "1 2" },
        .{ .name = "grid-row-end", .value = "span " },
        .{ .name = "grid-column-start", .value = "32768" },
        .{ .name = "grid-row-start", .value = "-32769" },
        .{ .name = "grid-column-end", .value = "span 65536" },
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
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-column-end",
        "span 1025",
    );
    try std.testing.expectEqual(
        @as(style.GridPlacement, .{ .span = 1025 }),
        result.grid_column.end,
    );
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-column-start",
        "32767",
    );
    try std.testing.expectEqual(
        @as(style.GridPlacement, .{ .line = 32767 }),
        result.grid_column.start,
    );
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "grid-row-start",
        "-32768",
    );
    try std.testing.expectEqual(
        @as(style.GridPlacement, .{ .line = -32768 }),
        result.grid_row.start,
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

test "fixture grid values preserve representable integer bounds" {
    try std.testing.expect(std.meta.eql(
        @as(style.GridPlacement, .{ .span = 65535 }),
        try parseGridPlacement("span 65535"),
    ));
    try std.testing.expectError(
        error.InvalidFixture,
        parseGridPlacement("span 65536"),
    );

    const repeat = try parseRepeatHeader("repeat(65535, 1px)");
    try std.testing.expectEqual(
        @as(style.GridRepeatKind, .{ .count = 65535 }),
        repeat.kind,
    );
    try std.testing.expectError(
        error.InvalidFixture,
        parseRepeatHeader("repeat(65536, 1px)"),
    );
    try std.testing.expectEqualStrings("1px", repeat.body);
}

test "fixture grid alignment and gaps map canonical fields" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var result: style.Style = .{};
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-content", "flex-end");
    try std.testing.expectEqual(style.Justify.flex_end, result.justify);
    try std.testing.expectEqual(style.Justify.flex_end, result.grid_justify_content);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-content", "space-evenly");
    try std.testing.expectEqual(style.Justify.space_evenly, result.grid_justify_content);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-content", "space-around");
    try std.testing.expectEqual(style.AlignContent.space_around, result.align_content);
    try std.testing.expectEqual(style.AlignContent.space_around, result.grid_align_content);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-content", "space-evenly");
    try std.testing.expectEqual(style.AlignContent.space_evenly, result.align_content);
    try std.testing.expectEqual(style.AlignContent.space_evenly, result.grid_align_content);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-items", "flex-start");
    try std.testing.expectEqual(style.Align.flex_start, result.grid_justify_items);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-items", "flex-end");
    try std.testing.expectEqual(style.Align.flex_end, result.@"align");
    try std.testing.expectEqual(style.Align.flex_end, result.grid_align_items);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-self", "center");
    try std.testing.expectEqual(style.AlignSelf.center, result.grid_justify_self);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-self", "stretch");
    try std.testing.expectEqual(style.AlignSelf.stretch, result.align_self);
    try std.testing.expectEqual(style.AlignSelf.stretch, result.grid_align_self);
    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-content", "safe center");
    try std.testing.expectEqual(style.Justify.safe_center, result.justify);
    try std.testing.expectEqual(style.Justify.safe_center, result.grid_justify_content);
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "justify-content",
        "unsafe center",
    );
    try std.testing.expectEqual(style.Justify.unsafe_center, result.justify);
    try std.testing.expectEqual(style.Justify.unsafe_center, result.grid_justify_content);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-content", "safe center");
    try std.testing.expectEqual(style.AlignContent.safe_center, result.align_content);
    try std.testing.expectEqual(style.AlignContent.safe_center, result.grid_align_content);
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "align-content",
        "unsafe center",
    );
    try std.testing.expectEqual(style.AlignContent.unsafe_center, result.align_content);
    try std.testing.expectEqual(style.AlignContent.unsafe_center, result.grid_align_content);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-items", "safe center");
    try std.testing.expectEqual(style.Align.safe_center, result.grid_justify_items);
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "justify-items",
        "unsafe center",
    );
    try std.testing.expectEqual(style.Align.unsafe_center, result.grid_justify_items);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-items", "safe center");
    try std.testing.expectEqual(style.Align.safe_center, result.@"align");
    try std.testing.expectEqual(style.Align.safe_center, result.grid_align_items);
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "align-items",
        "unsafe center",
    );
    try std.testing.expectEqual(style.Align.unsafe_center, result.@"align");
    try std.testing.expectEqual(style.Align.unsafe_center, result.grid_align_items);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "justify-self", "safe center");
    try std.testing.expectEqual(style.AlignSelf.safe_center, result.grid_justify_self);
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "justify-self",
        "unsafe center",
    );
    try std.testing.expectEqual(style.AlignSelf.unsafe_center, result.grid_justify_self);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "align-self", "safe center");
    try std.testing.expectEqual(style.AlignSelf.safe_center, result.align_self);
    try std.testing.expectEqual(style.AlignSelf.safe_center, result.grid_align_self);
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &result,
        "align-self",
        "unsafe center",
    );
    try std.testing.expectEqual(style.AlignSelf.unsafe_center, result.align_self);
    try std.testing.expectEqual(style.AlignSelf.unsafe_center, result.grid_align_self);

    try applyAttributeWithResources(&fixture_tree.resources, &result, "gap", "4px");
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 4 }),
        result.gap,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 4 }),
        result.column_gap,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 4 }),
        result.row_gap,
    ));
    try applyAttributeWithResources(&fixture_tree.resources, &result, "column-gap", "2px");
    try applyAttributeWithResources(&fixture_tree.resources, &result, "row-gap", "3px");
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 2 }),
        result.column_gap,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 3 }),
        result.row_gap,
    ));
}

test "fixture unsupported grid representations remain rejected" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    const unsupported = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "grid-template-columns", .value = "[content] 1fr" },
        .{ .name = "grid-template-rows", .value = "subgrid" },
        .{ .name = "grid-template-areas", .value = "\"main main\"" },
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

    var auto_tracks: style.Style = .{};
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &auto_tracks,
        "grid-auto-columns",
        "10px 1fr",
    );
    try std.testing.expectEqual(@as(usize, 2), auto_tracks.grid_auto_columns.len);
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .{ .fixed = 10 }),
        auto_tracks.grid_auto_columns[0],
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.GridTrack, .{ .fr = 1 }),
        auto_tracks.grid_auto_columns[1],
    ));
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &auto_tracks,
        "grid-auto-rows",
        "minmax(10px, 1fr) 20px",
    );
    try std.testing.expectEqual(@as(usize, 2), auto_tracks.grid_auto_rows.len);

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
    result.flex_wrap = if (std.mem.eql(u8, value, "nowrap"))
        .nowrap
    else if (std.mem.eql(u8, value, "wrap"))
        .wrap
    else if (std.mem.eql(u8, value, "wrap-reverse"))
        .wrap_reverse
    else
        return error.Unsupported;
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
        return;
    }
    result.flex_basis = try parseDimension(value);
}

fn applyGap(result: *style.Style, value: []const u8) CaseError!void {
    const gap = try parseGap(value);
    result.gap = gap;
    result.column_gap = gap;
    result.row_gap = gap;
}

fn applyColumnGap(result: *style.Style, value: []const u8) CaseError!void {
    result.gap = .{ .length = 0 };
    result.column_gap = try parseGap(value);
}

fn applyRowGap(result: *style.Style, value: []const u8) CaseError!void {
    result.gap = .{ .length = 0 };
    result.row_gap = try parseGap(value);
}

fn applyTextAlign(result: *style.Style, value: []const u8) CaseError!void {
    result.text_align = if (std.mem.eql(u8, value, "-webkit-left"))
        .left
    else if (std.mem.eql(u8, value, "-webkit-center"))
        .center
    else if (std.mem.eql(u8, value, "-webkit-right"))
        .right
    else
        return error.Unsupported;
}

fn applyJustifyContent(result: *style.Style, value: []const u8) CaseError!void {
    result.justify = if (std.mem.eql(u8, value, "normal"))
        .normal
    else if (std.mem.eql(u8, value, "start"))
        .start
    else if (std.mem.eql(u8, value, "flex-start"))
        .flex_start
    else if (std.mem.eql(u8, value, "center"))
        .center
    else if (std.mem.eql(u8, value, "safe center"))
        .safe_center
    else if (std.mem.eql(u8, value, "unsafe center"))
        .unsafe_center
    else if (std.mem.eql(u8, value, "end"))
        .end
    else if (std.mem.eql(u8, value, "flex-end"))
        .flex_end
    else if (std.mem.eql(u8, value, "safe end"))
        .safe_end
    else if (std.mem.eql(u8, value, "unsafe end"))
        .unsafe_end
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
    else if (std.mem.eql(u8, value, "start"))
        .start
    else if (std.mem.eql(u8, value, "flex-start"))
        .flex_start
    else if (std.mem.eql(u8, value, "center"))
        .center
    else if (std.mem.eql(u8, value, "safe center"))
        .safe_center
    else if (std.mem.eql(u8, value, "unsafe center"))
        .unsafe_center
    else if (std.mem.eql(u8, value, "end"))
        .end
    else if (std.mem.eql(u8, value, "flex-end"))
        .flex_end
    else if (std.mem.eql(u8, value, "safe end"))
        .safe_end
    else if (std.mem.eql(u8, value, "unsafe end"))
        .unsafe_end
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
    else if (std.mem.eql(u8, value, "start"))
        .start
    else if (std.mem.eql(u8, value, "flex-start"))
        .flex_start
    else if (std.mem.eql(u8, value, "center"))
        .center
    else if (std.mem.eql(u8, value, "safe center"))
        .safe_center
    else if (std.mem.eql(u8, value, "unsafe center"))
        .unsafe_center
    else if (std.mem.eql(u8, value, "end"))
        .end
    else if (std.mem.eql(u8, value, "flex-end"))
        .flex_end
    else if (std.mem.eql(u8, value, "safe end"))
        .safe_end
    else if (std.mem.eql(u8, value, "unsafe end"))
        .unsafe_end
    else if (std.mem.eql(u8, value, "self-start"))
        .self_start
    else if (std.mem.eql(u8, value, "self-end"))
        .self_end
    else if (std.mem.eql(u8, value, "baseline"))
        .baseline
    else
        error.Unsupported;
}

fn parseAlignSelf(value: []const u8) CaseError!style.AlignSelf {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "safe end")) return .safe_end;
    if (std.mem.eql(u8, value, "unsafe end")) return .unsafe_end;
    return switch (try parseAlign(value)) {
        .stretch => .stretch,
        .start => .start,
        .flex_start => .flex_start,
        .center => .center,
        .safe_center => .safe_center,
        .unsafe_center => .unsafe_center,
        .end => .end,
        .flex_end => .flex_end,
        .safe_end => .safe_end,
        .unsafe_end => .unsafe_end,
        .self_start => .self_start,
        .self_end => .self_end,
        .baseline => .baseline,
    };
}

const RepeatSpec = struct {
    kind: style.GridRepeatKind,
    body: []const u8,
};

fn parseRepeatHeader(token: []const u8) CaseError!RepeatSpec {
    if (!std.mem.startsWith(u8, token, "repeat(") or
        !std.mem.endsWith(u8, token, ")"))
    {
        return error.Unsupported;
    }
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
        }
    }
    if (depth != 0) return error.InvalidFixture;
    const split = comma orelse return error.InvalidFixture;
    const count_text = std.mem.trim(u8, inner[0..split], " \t\n\r");
    const body = std.mem.trim(u8, inner[split + 1 ..], " \t\n\r");
    if (count_text.len == 0 or body.len == 0) return error.InvalidFixture;

    const kind: style.GridRepeatKind = if (std.mem.eql(u8, count_text, "auto-fill"))
        .auto_fill
    else if (std.mem.eql(u8, count_text, "auto-fit"))
        .auto_fit
    else
        .{ .count = try parseGridCount(count_text) };
    return .{ .kind = kind, .body = body };
}

fn parseGridCount(value: []const u8) CaseError!u16 {
    if (value.len == 0) return error.InvalidFixture;
    var start: usize = 0;
    if (value[0] == '+') start = 1;
    if (start == value.len) return error.InvalidFixture;

    var count: u16 = 0;
    var has_digit = false;
    for (value[start..]) |character| {
        if (character < '0' or character > '9') return error.InvalidFixture;
        has_digit = true;
        const digit: u16 = @intCast(character - '0');
        count = std.math.mul(u16, count, 10) catch return error.InvalidFixture;
        count = std.math.add(u16, count, digit) catch return error.InvalidFixture;
    }
    if (!has_digit or count == 0) return error.InvalidFixture;
    return count;
}

fn parseGridTemplate(
    resources: *FixtureResources,
    value: []const u8,
) CaseError![]const style.GridTrack {
    return parseGridTrackList(resources, value, value.len);
}

fn parseGridTrackList(
    resources: *FixtureResources,
    value: []const u8,
    depth: usize,
) CaseError![]const style.GridTrack {
    if (value.len == 0 or depth == 0) return error.InvalidFixture;
    const count = try countGridTrackTokens(value);
    const owned = try resources.allocator.alloc(style.GridTrack, count);
    resources.grid_track_allocations.append(resources.allocator, owned) catch |allocation_error| {
        resources.allocator.free(owned);
        return allocation_error;
    };

    var cursor: usize = 0;
    var index: usize = 0;
    while (try nextGridTrackToken(value, &cursor)) |token| {
        if (index >= owned.len) return error.InvalidFixture;
        owned[index] = try parseGridTrackValue(resources, token, depth - 1);
        index += 1;
    }
    if (index != owned.len) return error.InvalidFixture;
    return owned;
}

fn countGridTrackTokens(value: []const u8) CaseError!usize {
    var cursor: usize = 0;
    var count: usize = 0;
    while ((try nextGridTrackToken(value, &cursor)) != null) {
        if (count == std.math.maxInt(usize)) return error.InvalidFixture;
        count += 1;
    }
    if (count == 0) return error.InvalidFixture;
    return count;
}

fn parseGridTrackValue(
    resources: *FixtureResources,
    token: []const u8,
    depth: usize,
) CaseError!style.GridTrack {
    if (std.mem.startsWith(u8, token, "repeat(")) {
        const repeat = try parseRepeatHeader(token);
        const tracks = try parseGridTrackList(resources, repeat.body, depth);
        return .{ .repeat = .{ .kind = repeat.kind, .tracks = tracks } };
    }
    return parseGridTrackToken(token);
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
) CaseError![]const style.GridTrack {
    return parseGridTrackList(resources, value, value.len);
}

fn expectSemanticRepeat(
    actual: []const style.GridTrack,
    expected_kind: style.GridRepeatKind,
    expected_tracks: []const style.GridTrack,
) !void {
    try std.testing.expectEqual(@as(usize, 1), actual.len);
    switch (actual[0]) {
        .repeat => |repeat| {
            try std.testing.expectEqual(expected_kind, repeat.kind);
            try std.testing.expectEqual(expected_tracks.len, repeat.tracks.len);
            for (expected_tracks, repeat.tracks) |expected, track| {
                try std.testing.expect(std.meta.eql(expected, track));
            }
        },
        else => try std.testing.expect(false),
    }
}

fn parseGridTrackToken(token: []const u8) CaseError!style.GridTrack {
    if (token.len == 0) return error.InvalidFixture;
    if (token[0] == '[') {
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
fn parseGridFitContent(token: []const u8) CaseError!style.LengthPercentage {
    if (!std.mem.endsWith(u8, token, ")")) return error.Unsupported;
    const body = std.mem.trim(u8, token[12 .. token.len - 1], " \t\n\r");
    if (body.len == 0) return error.InvalidFixture;
    return parseLengthPercentage(body);
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
        const parsed_span = parseGridCount(span_text) catch {
            if (isNamedGridLine(span_text)) return error.Unsupported;
            return error.InvalidFixture;
        };
        return .{ .span = parsed_span };
    }
    if (std.mem.indexOfAny(u8, trimmed, " \t\n\r") != null) {
        return error.InvalidFixture;
    }
    const line = parseGridLine(trimmed) catch {
        if (isNamedGridLine(trimmed)) return error.Unsupported;
        return error.InvalidFixture;
    };
    return .{ .line = line };
}

fn parseGridLine(value: []const u8) CaseError!i16 {
    if (value.len == 0) return error.InvalidFixture;
    var index: usize = 0;
    var negative = false;
    if (value[0] == '-' or value[0] == '+') {
        negative = value[0] == '-';
        index = 1;
    }
    if (index == value.len) return error.InvalidFixture;

    var magnitude: u16 = 0;
    for (value[index..]) |character| {
        if (character < '0' or character > '9') return error.InvalidFixture;
        const digit: u16 = @intCast(character - '0');
        magnitude = std.math.mul(u16, magnitude, 10) catch return error.InvalidFixture;
        magnitude = std.math.add(u16, magnitude, digit) catch return error.InvalidFixture;
    }
    if (magnitude == 0) return error.InvalidFixture;
    if (negative) {
        if (magnitude > 32768) return error.InvalidFixture;
        if (magnitude == 32768) return std.math.minInt(i16);
        return -@as(i16, @intCast(magnitude));
    }
    if (magnitude > 32767) return error.InvalidFixture;
    return @intCast(magnitude);
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

fn parseGap(value: []const u8) CaseError!style.LengthPercentage {
    if (std.mem.indexOfAny(u8, value, " \t\n\r") != null) return error.Unsupported;
    if (std.mem.eql(u8, value, "normal")) return .{ .length = 0 };
    return parseLengthPercentage(value);
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
}

fn setPadding(result: *style.Style, side: Side, value: style.LengthPercentage) void {
    switch (side) {
        .top => result.padding_inset.top = value,
        .right => result.padding_inset.right = value,
        .bottom => result.padding_inset.bottom = value,
        .left => result.padding_inset.left = value,
    }
}

fn setBorder(result: *style.Style, side: Side, value: f32) void {
    switch (side) {
        .top => result.border_inset.top = .{ .length = value },
        .right => result.border_inset.right = .{ .length = value },
        .bottom => result.border_inset.bottom = .{ .length = value },
        .left => result.border_inset.left = .{ .length = value },
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

fn finiteF32(value: f64) CaseError!f32 {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidFixture;
    const result: f32 = @floatCast(value);
    if (!std.math.isFinite(result) or result < 0) return error.InvalidFixture;
    return result;
}

const AhemMetrics = struct {
    min_line_length: usize = 0,
    max_line_length: usize = 0,
};

fn ahemMeasure(
    content: []const u8,
    input: layout_context.MeasureInput,
) layout_context.LayoutError!layout_context.TextMeasurement {
    return layout_context.measureContent(ahemMeasureSource(), content, input);
}

fn ahemMeasureSource() layout_context.MeasureSource {
    return .{ .callback = ahemMeasureBase };
}

/// The synthetic Ahem provider. It maps the logical axes onto the physical
/// constraints and reports no baseline, so core's historical 0.8-of-size
/// fallback keeps the fixture goldens identical.
fn ahemMeasureBase(
    _: ?*anyopaque,
    content: []const u8,
    input: layout_context.MeasureInput,
) layout_context.LayoutError!layout_context.TextMeasurement {
    const horizontal = switch (input.writing_mode) {
        .horizontal_tb => ahemMeasureHorizontal(content, input),
        .vertical_lr => ahemMeasureVertical(content, input),
    };
    return horizontal;
}

fn ahemMeasureHorizontal(
    content: []const u8,
    input: layout_context.MeasureInput,
) layout_context.TextMeasurement {
    const metrics = measureAhemMetrics(content);
    const width = ahemInlineSize(metrics, input);
    const line_count = ahemLineCount(content, width);
    const height: f32 = @floatCast(
        @as(f64, @floatFromInt(line_count)) * @as(f64, ahem_line_height),
    );
    return .{ .width = width, .height = height };
}

fn ahemMeasureVertical(
    content: []const u8,
    input: layout_context.MeasureInput,
) layout_context.TextMeasurement {
    var horizontal_input = input;
    horizontal_input.known_dimensions = .{
        .width = input.known_dimensions.height,
        .height = input.known_dimensions.width,
    };
    horizontal_input.available_space = .{
        .width = input.available_space.height,
        .height = input.available_space.width,
    };
    horizontal_input.writing_mode = .horizontal_tb;
    const horizontal = ahemMeasureHorizontal(content, horizontal_input);
    return .{ .width = horizontal.height, .height = horizontal.width };
}

fn measureAhemMetrics(text: []const u8) AhemMetrics {
    var metrics: AhemMetrics = .{};
    var segments = std.mem.splitSequence(u8, text, "\xE2\x80\x8B");
    while (segments.next()) |segment| {
        metrics.min_line_length = @max(metrics.min_line_length, segment.len);
        metrics.max_line_length += segment.len;
    }
    return metrics;
}

fn ahemInlineSize(metrics: AhemMetrics, input: layout_context.MeasureInput) f32 {
    const min_content_width: f32 = @floatCast(
        @as(f64, @floatFromInt(metrics.min_line_length)) * @as(f64, ahem_glyph_width),
    );
    const max_content_width: f32 = @floatCast(
        @as(f64, @floatFromInt(metrics.max_line_length)) * @as(f64, ahem_glyph_width),
    );
    const available_width: f32 = if (input.known_dimensions.width) |known| blk: {
        break :blk finiteAhemWidth(known);
    } else switch (input.available_space.width) {
        .min_content => min_content_width,
        .max_content => max_content_width,
        .definite => |available| finiteAhemWidth(available),
    };
    return @max(min_content_width, @min(available_width, max_content_width));
}

fn finiteAhemWidth(value: f32) f32 {
    if (!std.math.isFinite(value) or value < 0) return 0;
    return value;
}

fn ahemLineCount(text: []const u8, available_width: f32) usize {
    const inline_capacity: usize = @intFromFloat(
        @floor(available_width / ahem_glyph_width),
    );
    var line_count: usize = 1;
    var current_line_length: usize = 0;
    var segments = std.mem.splitSequence(u8, text, "\xE2\x80\x8B");
    while (segments.next()) |segment| {
        const combined = current_line_length + segment.len;
        if (combined > inline_capacity) {
            if (current_line_length > 0) line_count += 1;
            current_line_length = segment.len;
        } else {
            current_line_length = combined;
        }
    }
    return line_count;
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
    const compared_actual = if (use_rounding) fixtureRound(actual) else actual;
    const compared_expected = if (use_rounding) fixtureRound(expected) else expected;
    return @abs(compared_actual - compared_expected) < comparison_tolerance;
}

fn rectMatchesRounded(actual: Rect, expected: Rect, use_rounding: bool) bool {
    if (!use_rounding) {
        if (!scalarMatchesRounded(actual.x, expected.x, false)) return false;
        if (!scalarMatchesRounded(actual.y, expected.y, false)) return false;
        if (!scalarMatchesRounded(actual.width, expected.width, false)) return false;
        return scalarMatchesRounded(actual.height, expected.height, false);
    }

    const actual_left = fixtureRound(actual.x);
    const actual_top = fixtureRound(actual.y);
    const actual_right = fixtureRound(actual.x + actual.width);
    const actual_bottom = fixtureRound(actual.y + actual.height);
    const expected_left = fixtureRound(expected.x);
    const expected_top = fixtureRound(expected.y);
    const expected_right = fixtureRound(expected.x + expected.width);
    const expected_bottom = fixtureRound(expected.y + expected.height);

    if (!scalarMatchesRounded(actual_left, expected_left, false)) return false;
    if (!scalarMatchesRounded(actual_top, expected_top, false)) return false;
    if (!scalarMatchesRounded(
        actual_right - actual_left,
        expected_right - expected_left,
        false,
    )) return false;
    return scalarMatchesRounded(
        actual_bottom - actual_top,
        expected_bottom - expected_top,
        false,
    );
}
fn fixtureRound(value: f64) f64 {
    return @floor(value + 0.5);
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

test "fixture gap percentages retain typed tags across canonical gap fields" {
    var result: style.Style = .{};
    try applyAttribute(&result, "gap", "50%");

    const expected: style.LengthPercentage = .{ .percent = 0.5 };
    try std.testing.expect(std.meta.eql(expected, result.gap));
    try std.testing.expect(std.meta.eql(expected, result.column_gap));
    try std.testing.expect(std.meta.eql(expected, result.row_gap));
}

test "fixture column percentage gap clears generic fallback" {
    var result: style.Style = .{};
    try applyAttribute(&result, "gap", "4px");
    try applyAttribute(&result, "column-gap", "25%");

    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 0 }),
        result.gap,
    ));
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .percent = 0.25 }),
        result.column_gap,
    ));
}

test "fixture normal gaps map to typed zero and whitespace stays unsupported" {
    const zero: style.LengthPercentage = .{ .length = 0 };

    var generic: style.Style = .{};
    try applyAttribute(&generic, "gap", "normal");
    try std.testing.expect(std.meta.eql(zero, generic.gap));
    try std.testing.expect(std.meta.eql(zero, generic.column_gap));
    try std.testing.expect(std.meta.eql(zero, generic.row_gap));

    var row: style.Style = .{};
    try applyAttribute(&row, "row-gap", "normal");
    try std.testing.expect(std.meta.eql(zero, row.gap));
    try std.testing.expect(std.meta.eql(zero, row.row_gap));

    try std.testing.expectError(
        error.Unsupported,
        applyAttribute(&row, "gap", " 50%"),
    );
}

test "fixture auto-fill preserves percentage gap and semantic repeat" {
    var fixture_tree = try FixtureTree.init(std.testing.allocator, 0);
    defer fixture_tree.deinit(std.testing.allocator);

    var definite: style.Style = .{};
    definite.size.width = .{ .length = 200 };
    try applyAttribute(&definite, "column-gap", "10%");
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &definite,
        "grid-template-columns",
        "repeat(auto-fill, 60px)",
    );
    try expectSemanticRepeat(
        definite.grid_template_columns,
        .auto_fill,
        &[_]style.GridTrack{.{ .fixed = 60 }},
    );

    var indefinite: style.Style = .{};
    indefinite.size.width = .{ .percent = 0.5 };
    try applyAttribute(&indefinite, "column-gap", "10%");
    try applyAttributeWithResources(
        &fixture_tree.resources,
        &indefinite,
        "grid-template-columns",
        "repeat(auto-fill, 60px)",
    );
    try expectSemanticRepeat(
        indefinite.grid_template_columns,
        .auto_fill,
        &[_]style.GridTrack{.{ .fixed = 60 }},
    );
}
