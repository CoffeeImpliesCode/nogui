const std = @import("std");

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
const ahem_glyph_width: f64 = 10.0;
const ahem_line_height: f64 = 10.0;
const comparison_tolerance: f64 = 0.1;

pub const FixtureSummary = struct {
    passed: usize = 0,
    failed: usize = 0,
};

pub const FixtureError = error{
    FixtureNotFound,
    InvalidFixture,
} || std.mem.Allocator.Error;

const Corpus = struct {
    schema: u32,
    cases: []const Case,
};

const Case = struct {
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
    style: LeafStyle,
};

const LeafStyle = struct {
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

    var summary: FixtureSummary = .{};
    var found = false;
    for (parsed_corpus.value.cases) |fixture_case| {
        if (!matchesFilter(fixture_case, filter)) continue;
        found = true;

        const actual = try layoutLeaf(fixture_case);
        if (rectMatches(actual, fixture_case.expected[0])) {
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

fn layoutLeaf(fixture_case: Case) FixtureError!Rect {
    if (!std.mem.eql(u8, fixture_case.id, canonical_id)) return error.InvalidFixture;
    if (!std.mem.eql(u8, fixture_case.source, canonical_source)) return error.InvalidFixture;
    if (!std.mem.eql(u8, fixture_case.variant, "border_box_ltr")) {
        return error.InvalidFixture;
    }
    if (fixture_case.grid_feature) return error.InvalidFixture;
    if (!fixture_case.use_rounding) return error.InvalidFixture;
    if (fixture_case.viewport.width != 800.0) return error.InvalidFixture;
    if (fixture_case.viewport.height != 600.0) return error.InvalidFixture;
    if (fixture_case.nodes.len != 1) return error.InvalidFixture;
    if (fixture_case.expected.len != 1) return error.InvalidFixture;

    const node = fixture_case.nodes[0];
    if (!std.mem.eql(u8, node.kind, "text")) return error.InvalidFixture;
    if (node.child_count != 0) return error.InvalidFixture;
    const text = node.text orelse return error.InvalidFixture;
    if (!std.mem.eql(u8, text, "HHHH")) return error.InvalidFixture;
    if (!std.mem.eql(u8, node.style.direction, "ltr")) return error.InvalidFixture;

    const border_top = try parsePixels(node.style.border_top);
    const border_right = try parsePixels(node.style.border_right);
    const border_bottom = try parsePixels(node.style.border_bottom);
    const border_left = try parsePixels(node.style.border_left);
    if (border_top != 2.0) return error.InvalidFixture;
    if (border_right != 4.0) return error.InvalidFixture;
    if (border_bottom != 6.0) return error.InvalidFixture;
    if (border_left != 8.0) return error.InvalidFixture;

    try validateExpectedRect(fixture_case.expected[0]);

    const content_width = @as(f64, @floatFromInt(text.len)) * ahem_glyph_width;
    var rect: Rect = .{
        .x = 0.0,
        .y = 0.0,
        .width = border_left + content_width + border_right,
        .height = border_top + ahem_line_height + border_bottom,
    };
    if (fixture_case.use_rounding) {
        rect.x = @round(rect.x);
        rect.y = @round(rect.y);
        rect.width = @round(rect.width);
        rect.height = @round(rect.height);
    }
    return rect;
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

fn rectMatches(actual: Rect, expected: Rect) bool {
    if (@abs(actual.x - expected.x) >= comparison_tolerance) return false;
    if (@abs(actual.y - expected.y) >= comparison_tolerance) return false;
    if (@abs(actual.width - expected.width) >= comparison_tolerance) return false;
    return @abs(actual.height - expected.height) < comparison_tolerance;
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
