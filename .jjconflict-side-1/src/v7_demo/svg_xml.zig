//! libxml2-backed SVG document reader for the v7 demo: the XML front-end
//! for the XML-independent parser core in svg.zig.
//!
//! `parseSvg` parses an SVG document buffer with libxml2 (xmlReadMemory),
//! walks the element tree, and hands each `<path>` element's `d` attribute
//! to `svg.parsePath`. The result is an arena-owned `SvgDoc`: the doc arena
//! owns the `paths` slice, and every path owns its own command arena (per
//! `svg.parsePath`'s contract). `SvgDoc.deinit` releases the paths first,
//! then the doc arena — the whole document in one call.
//!
//! NAIVE READING — deliberate simplifications, matching the demo's scope:
//! - Only `<path>` elements are collected (groups are traversed, other
//!   elements are skipped silently). No transforms, no `<use>`, no shapes.
//! - Fill inheritance is naive: the root `<svg>` element's `fill` is the
//!   document default, applied to every path without its own `fill`
//!   attribute. Group (`<g>`) inheritance is out of scope. Fills are
//!   `#RGB`/`#RRGGBB` hex or `none`; a malformed value is tolerated as
//!   black, never an error.
//! - Namespace prefixes: libxml2 stores the *local* name in `node.name`
//!   when the prefix is declared (xmlns:svg), but keeps the full "svg:path"
//!   name when it is not. `isLocalName` matches either (see below).
//! - A malformed `d` attribute skips that path and parsing continues; a
//!   malformed *document* is an error. A missing `d` skips the path. A
//!   bad width/height/viewBox attribute is ignored (null), never an error.
//! - An empty document (no root element) yields an empty `SvgDoc`; a
//!   well-formedness failure returns `error.InvalidXml` (libxml2's fatal
//!   path). This module never panics.
//!
//! Demo-side only: like text.zig, this file MAY import the v7 core.

const std = @import("std");
const svg = @import("svg.zig");
const nogui = @import("nogui");
const Rect = nogui.widget.Rect;
const Command = svg.Command;

// One C import, owned by the libxml2 binding: parser.h pulls in tree.h and
// the rest of the core headers, so this exposes the full DOM API we need.
const c = @cImport({
    @cInclude("libxml/parser.h");
    @cInclude("libxml/tree.h");
});

/// Parsing/ownership failures from `parseSvg`.
pub const ParseError = error{
    /// The input is not well-formed XML (libxml2's fatal parse error), or
    /// too large for libxml2's length field.
    InvalidXml,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Document model
// ---------------------------------------------------------------------------

/// An arena-owned SVG document: the paths of every `<path>` element in
/// document order, plus the root element's size attributes.
pub const SvgDoc = struct {
    /// The parsed paths, in document order. Each path owns its own arena.
    paths: []svg.SvgPath,
    /// The root `<svg>` element's width attribute, when present and
    /// parseable as a number.
    width: ?f32 = null,
    /// The root `<svg>` element's height attribute, when present and
    /// parseable as a number.
    height: ?f32 = null,
    /// The root element's viewBox ("min-x min-y width height"), when
    /// present and holding exactly four numbers.
    view_box: ?[4]f32 = null,
    /// Owns the `paths` slice.
    arena: std.heap.ArenaAllocator,

    /// Release everything the document owns: each path's command arena
    /// first, then the doc arena.
    pub fn deinit(self: *SvgDoc) void {
        for (self.paths) |*path| path.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Document parsing
// ---------------------------------------------------------------------------

/// Parse an SVG document. `xml` is the raw document bytes (UTF-8);
/// everything the returned `SvgDoc` owns lives in its arena.
pub fn parseSvg(allocator: std.mem.Allocator, xml: []const u8) ParseError!SvgDoc {
    // The doc arena owns only the `paths` slice. Each parsed path owns its
    // own command arena (svg.parsePath's contract); the path arenas must
    // NOT be children of the doc arena: the doc arena's buffer churns as
    // the path list grows, which would dangle the child arenas' nodes.
    var arena = std.heap.ArenaAllocator.init(allocator);
    var paths = std.ArrayList(svg.SvgPath).empty;
    errdefer {
        // Release any paths collected before the failure (each owns an
        // arena from `allocator`), then the doc arena.
        for (paths.items) |*path| path.deinit();
        arena.deinit();
    }

    if (xml.len > std.math.maxInt(c_int)) return error.InvalidXml;

    // XML_PARSE_NONET: forbid network access from the parser (external
    // entity loading can otherwise hit the network). NOERROR/NOWARNING:
    // the naive reading tolerates undeclared namespace prefixes and other
    // recoverable quirks — libxml2's stderr diagnostics would otherwise
    // pollute the process's stderr (and trip the test runner).
    const doc = c.xmlReadMemory(
        xml.ptr,
        @intCast(xml.len),
        null,
        null,
        c.XML_PARSE_NONET | c.XML_PARSE_NOERROR | c.XML_PARSE_NOWARNING,
    ) orelse
        return error.InvalidXml;
    defer c.xmlFreeDoc(doc);

    const a = arena.allocator();

    var width: ?f32 = null;
    var height: ?f32 = null;
    var view_box: ?[4]f32 = null;

    // An empty document parses to a root-less doc: yield an empty SvgDoc
    // instead of an error (the naive reading).
    if (c.xmlDocGetRootElement(doc)) |root| {
        // The root is treated as the <svg> element whatever it is named
        // (naive): its size attributes are read when present.
        width = attrFloat(root, "width");
        height = attrFloat(root, "height");
        view_box = attrViewBox(root);
        // The root's `fill` is the document default: paths without their
        // own `fill` inherit it. (Group-level inheritance is out of
        // scope — the naive reading.)
        const default_fill = attrFill(root) orelse .{ 0, 0, 0, 1 };
        const default_stroke = attrStroke(root);
        const default_stroke_width = attrFloat(root, "stroke-width") orelse 1;
        try collectPaths(a, allocator, &paths, root, default_fill, default_stroke, default_stroke_width, identity);
    }

    return .{
        .paths = try paths.toOwnedSlice(a),
        .width = width,
        .height = height,
        .view_box = view_box,
        .arena = arena,
    };
}

/// The identity affine. Transforms accumulate down the tree: a group's
/// transform post-multiplies its parent's (SVG's nesting semantics).
const identity = [6]f32{ 1, 0, 0, 1, 0, 0 };

fn isIdentity(m: [6]f32) bool {
    return m[0] == 1 and m[1] == 0 and m[2] == 0 and m[3] == 1 and m[4] == 0 and m[5] == 0;
}

/// Compose two affines: `parent` then `child` (child's points transform
/// through `parent` first — the SVG nesting order).
fn composeTransform(parent: [6]f32, child: [6]f32) [6]f32 {
    return .{
        parent[0] * child[0] + parent[2] * child[1],
        parent[1] * child[0] + parent[3] * child[1],
        parent[0] * child[2] + parent[2] * child[3],
        parent[1] * child[2] + parent[3] * child[3],
        parent[0] * child[4] + parent[2] * child[5] + parent[4],
        parent[1] * child[4] + parent[3] * child[5] + parent[5],
    };
}

/// Append a parsed `SvgPath` for every `<path>` element reachable from
/// `node` (siblings and descendants; groups are just traversed). `a` owns
/// the growing path list; `base` is the caller's allocator that each path's
/// own arena is built on. `default_fill` is the document default (the root
/// `<svg>`'s `fill`): applied to paths without their own `fill`. `m` is
/// the accumulated affine from the enclosing groups.
fn collectPaths(
    a: std.mem.Allocator,
    base: std.mem.Allocator,
    out: *std.ArrayList(svg.SvgPath),
    node: [*c]c.xmlNode,
    default_fill: [4]f32,
    default_stroke: ?[4]f32,
    default_stroke_width: f32,
    m: [6]f32,
) !void {
    var cur: [*c]c.xmlNode = node;
    while (cur) |n| {
        cur = n.*.next; // advance first so `continue` can never spin
        if (n.*.type != c.XML_ELEMENT_NODE) continue;

        // A group's transform post-multiplies the accumulated one; the
        // tiger's root g carries a matrix() the parser must honor. The
        // group's `fill` likewise overrides the inherited fill for its
        // children (the tiger's g6 fill="#FFF" colors every path in it).
        var m_child = m;
        if (attrTransform(n)) |tm| m_child = composeTransform(m, tm);
        var fill_child = default_fill;
        if (attrFill(n)) |f| fill_child = f;
        // The stroke inherits like the fill: the nearest enclosing
        // group's stroke + stroke-width win (the tiger's g6 stroke="#000"
        // stroke-width="0.172" outlines every path in it).
        var stroke_child = default_stroke;
        if (attrStroke(n)) |s| stroke_child = s;
        var stroke_width_child = default_stroke_width;
        if (attrFloat(n, "stroke-width")) |w| stroke_width_child = w;

        if (isLocalName(std.mem.span(n.*.name), "path")) {
            if (c.xmlGetProp(n, "d")) |d_raw| {
                defer if (c.xmlFree) |free_fn| free_fn(d_raw); // xmlFree is a function-pointer global
                // Tolerant: a malformed `d` skips the path; the document
                // survives (the naive reading).
                var path = svg.parsePath(base, std.mem.span(d_raw)) catch |err| switch (err) {
                    error.InvalidPathData => continue,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                // The path's own `fill` wins; without one it inherits the
                // enclosing group's fill (or the document default).
                path.fill = attrFill(n) orelse fill_child;
                if (attrStroke(n)) |s| {
                    path.stroke = s;
                } else if (stroke_child) |s| {
                    path.stroke = s;
                }
                path.stroke_width = attrFloat(n, "stroke-width") orelse stroke_width_child;
                // The enclosing groups' transform: the tiger's root g
                // scales+translates the whole drawing.
                if (!isIdentity(m_child)) svg.transformPath(&path, m_child);
                // The path's arena is NOT a child of the doc arena (see
                // parseSvg): if the append below fails, the just-parsed
                // path would leak. The success path hands it to the list.
                errdefer path.deinit();
                try out.append(a, path);
            }
            // A missing `d` attribute: skip the element silently.
        }

        if (n.*.children != null) try collectPaths(
            a,
            base,
            out,
            n.*.children,
            fill_child,
            stroke_child,
            stroke_width_child,
            m_child,
        );
    }
}

/// Parse a group's `transform` attribute: the `matrix(a,b,c,d,e,f)` form
/// (the tiger's root g; the common scale/translate forms are expressible
/// as matrices). Other transform functions (rotate/skew) return null —
/// the naive reading keeps them out of scope. Malformed values yield
/// null; a bad attribute never fails the document.
fn attrTransform(node: [*c]c.xmlNode) ?[6]f32 {
    const raw = c.xmlGetProp(node, "transform") orelse return null;
    defer if (c.xmlFree) |free_fn| free_fn(raw);
    const s = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    if (!std.mem.startsWith(u8, s, "matrix(") or !std.mem.endsWith(u8, s, ")")) return null;
    const inner = s["matrix(".len .. s.len - 1];
    var it = std.mem.tokenizeAny(u8, inner, " ,\t\r\n");
    var m: [6]f32 = undefined;
    for (&m) |*v| {
        v.* = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    }
    if (it.next() != null) return null; // trailing junk
    // The fixed array is returned by value: Zig copies all six scalars into
    // the caller's result; no pointer into this stack frame escapes.
    return m;
}

/// Parse a numeric attribute (width/height). Missing or malformed values
/// yield null — a bad attribute never fails the document.
fn attrFloat(node: [*c]c.xmlNode, name: [*c]const u8) ?f32 {
    const raw = c.xmlGetProp(node, name) orelse return null;
    defer if (c.xmlFree) |free_fn| free_fn(raw);
    // Invalid SVG size attributes are intentionally treated as absent. This
    // is the parser's documented tolerant-input behavior, not an ignored
    // operational failure.
    return std.fmt.parseFloat(f32, std.mem.span(raw)) catch |err| switch (err) {
        error.InvalidCharacter => null,
    };
}

/// Parse the viewBox attribute: exactly four numbers separated by wsp —
/// space, tab, line feed, form feed, carriage return (SVG 2 §8.3.1) — or
/// commas ("min-x min-y width height").
fn attrViewBox(node: [*c]c.xmlNode) ?[4]f32 {
    const raw = c.xmlGetProp(node, "viewBox") orelse return null;
    defer if (c.xmlFree) |free_fn| free_fn(raw);
    var it = std.mem.tokenizeAny(u8, std.mem.span(raw), " \t\r\n\x0c,");
    var out: [4]f32 = undefined;
    var count: usize = 0;
    while (it.next()) |tok| {
        if (count == 4) return null; // more than four numbers
        out[count] = std.fmt.parseFloat(f32, tok) catch return null;
        count += 1;
    }
    // Like attrTransform, this fixed array is copied into the optional
    // return value; it does not retain stack storage.
    return if (count == 4) out else null;
}

/// Parse the `fill` attribute of an element, or null when the attribute
/// is absent. A present-but-malformed value is tolerated as black — a bad
/// fill never fails the document (the naive reading).
fn attrFill(node: [*c]c.xmlNode) ?[4]f32 {
    const raw = c.xmlGetProp(node, "fill") orelse return null;
    defer if (c.xmlFree) |free_fn| free_fn(raw);
    return parseFillColor(std.mem.span(raw)) orelse .{ 0, 0, 0, 1 };
}

/// Parse the `stroke` attribute: the color, or null for `stroke="none"`
/// (and for absent/malformed — the naive reading).
fn attrStroke(node: [*c]c.xmlNode) ?[4]f32 {
    const raw = c.xmlGetProp(node, "stroke") orelse return null;
    defer if (c.xmlFree) |free_fn| free_fn(raw);
    if (std.mem.eql(u8, std.mem.span(raw), "none")) return null;
    return parseFillColor(std.mem.span(raw));
}

/// Parse an SVG fill value into sRGB with alpha: `#RGB`/`#RRGGBB` hex
/// (case-insensitive), or `none` (no fill — alpha 0). Anything else
/// yields null. Named colors and other color syntaxes are out of scope.
fn parseFillColor(s: []const u8) ?[4]f32 {
    if (std.mem.eql(u8, s, "none")) return .{ 0, 0, 0, 0 };
    if (s.len < 2 or s[0] != '#') return null;
    const digits = s.len - 1;
    // #RGB or #RRGGBB, nothing else.
    if (digits != 3 and digits != 6) return null;
    var out: [4]f32 = .{ 0, 0, 0, 1 };
    const per = digits / 3; // 1 for #RGB, 2 for #RRGGBB
    for (0..3) |i| {
        const hi = hexVal(s[1 + i * per]) orelse return null;
        // #RGB expands each digit to a channel pair (#f00 → #ff0000).
        const lo = if (per == 2) hexVal(s[2 + i * per]) orelse return null else hi;
        out[i] = @as(f32, @floatFromInt((hi << 4) | lo)) / 255.0;
    }
    return out;
}

/// A hex nibble (case-insensitive), or null for a non-hex character.
fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// Naive namespace handling: match the bare local name, or any name that
/// ends in ":local". libxml2 strips a declared prefix into the ns pointer
/// (node.name is then already the local name), but keeps the full
/// "svg:path" name when the prefix is undeclared — this covers both.
fn isLocalName(name: []const u8, local: []const u8) bool {
    if (std.mem.eql(u8, name, local)) return true;
    return name.len > local.len and
        name[name.len - local.len - 1] == ':' and
        std.mem.eql(u8, name[name.len - local.len ..], local);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "minimal svg: size attributes, one path, bbox" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator, "<svg width=\"100\" height=\"50\"><path d=\"M0 0 L10 10 Z\"/></svg>");
    defer doc.deinit();
    try t.expectEqual(@as(?f32, 100), doc.width);
    try t.expectEqual(@as(?f32, 50), doc.height);
    try t.expectEqual(@as(usize, 1), doc.paths.len);
    try t.expectEqual(@as(usize, 3), doc.paths[0].commands.len);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 10, .h = 10 }, doc.paths[0].bbox);
}

test "paths nested in a group" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator, "<svg><g><path d=\"M0 0 10 10\"/><path d=\"M5 5 L15 5\"/></g></svg>");
    defer doc.deinit();
    try t.expectEqual(@as(usize, 2), doc.paths.len);
    // "M0 0 10 10" is a moveto plus an implicit lineto.
    try t.expectEqual(@as(usize, 2), doc.paths[0].commands.len);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 10, .h = 10 }, doc.paths[0].bbox);
    try t.expectEqual(Rect{ .x = 5, .y = 5, .w = 10, .h = 0 }, doc.paths[1].bbox);
}

test "relative moveto and arc from xml" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator, "<svg><path d=\"m1 2 a 3 4 0 0 1 5 6\"/></svg>");
    defer doc.deinit();
    try t.expectEqual(@as(usize, 1), doc.paths.len);
    try t.expectEqual(@as(usize, 2), doc.paths[0].commands.len);
    try t.expectEqual(Command{ .move_to = .{ .abs = false, .x = 1, .y = 2 } }, doc.paths[0].commands[0]);
    try t.expectEqual(Command{ .arc_to = .{
        .abs = false,
        .rx = 3,
        .ry = 4,
        .x_axis_rotation = 0,
        .large_arc_flag = false,
        .sweep_flag = true,
        .x = 5,
        .y = 6,
    } }, doc.paths[0].commands[1]);
}

test "malformed xml returns InvalidXml" {
    const t = std.testing;
    try t.expectError(error.InvalidXml, parseSvg(t.allocator, "<svg><path"));
    try t.expectError(error.InvalidXml, parseSvg(t.allocator, "<svg></svg"));
}

test "viewBox attribute" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator, "<svg viewBox=\"0 0 100 100\"><path d=\"M0 0 Z\"/></svg>");
    defer doc.deinit();
    const view_box = doc.view_box orelse return error.TestUnexpectedResult;
    try t.expectEqual([4]f32{ 0, 0, 100, 100 }, view_box);
}

test "namespaced path elements" {
    const t = std.testing;
    // Declared prefix: libxml2 stores the local name, "path".
    var declared = try parseSvg(
        t.allocator,
        "<svg:svg xmlns:svg=\"http://www.w3.org/2000/svg\"><svg:path d=\"M1 1 L2 2\"/></svg:svg>",
    );
    defer declared.deinit();
    try t.expectEqual(@as(usize, 1), declared.paths.len);
    // Undeclared prefix: libxml2 keeps the full "svg:path" name; the naive
    // local-name match still finds it (and the prefixed root).
    var undeclared = try parseSvg(t.allocator, "<svg:svg width=\"10\"><svg:path d=\"M0 0 L1 1\"/></svg:svg>");
    defer undeclared.deinit();
    try t.expectEqual(@as(usize, 1), undeclared.paths.len);
    try t.expectEqual(@as(?f32, 10), undeclared.width);
}

test "empty document" {
    const t = std.testing;
    // libxml2 reports a truly empty input as a fatal "Document is empty"
    // error; a root-less parse is fine. Handle both without panicking.
    var doc = parseSvg(t.allocator, "") catch |err| switch (err) {
        error.InvalidXml => return,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer doc.deinit();
    try t.expectEqual(@as(usize, 0), doc.paths.len);
    // A self-closing root parses to a document with no paths.
    var root_only = try parseSvg(t.allocator, "<svg/>");
    defer root_only.deinit();
    try t.expectEqual(@as(usize, 0), root_only.paths.len);
}

test "path without d is skipped" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator, "<svg><path/><path d=\"M0 0\"/><rect/></svg>");
    defer doc.deinit();
    try t.expectEqual(@as(usize, 1), doc.paths.len);
    // Only the element with a valid d attribute is collected.
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, doc.paths[0].bbox);
}

test "malformed d attribute skips the path" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator, "<svg><path d=\"M0 0 L\"/><path d=\"M5 5 L15 5\"/></svg>");
    defer doc.deinit();
    try t.expectEqual(@as(usize, 1), doc.paths.len);
    try t.expectEqual(Rect{ .x = 5, .y = 5, .w = 10, .h = 0 }, doc.paths[0].bbox);
}

test "malformed size attributes are ignored" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator, "<svg width=\"wide\" height=\"50\" viewBox=\"0 0\"><path d=\"M0 0\"/></svg>");
    defer doc.deinit();
    try t.expectEqual(@as(?f32, null), doc.width);
    try t.expectEqual(@as(?f32, 50), doc.height);
    try t.expectEqual(@as(?[4]f32, null), doc.view_box);
}

test "fill attribute: hex, shorthand, none, missing" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator,
        \\<svg>
        \\  <path d="M0 0" fill="#cc7226"/>
        \\  <path d="M0 0" fill="#F06"/>
        \\  <path d="M0 0" fill="none"/>
        \\  <path d="M0 0"/>
        \\</svg>
    );
    defer doc.deinit();
    try t.expectEqual(@as(usize, 4), doc.paths.len);
    // #cc7226 → 204/255, 114/255, 38/255, opaque.
    try t.expectApproxEqAbs(@as(f32, 0.8), doc.paths[0].fill[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 114.0 / 255.0), doc.paths[0].fill[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 38.0 / 255.0), doc.paths[0].fill[2], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1), doc.paths[0].fill[3], 1e-6);
    // #F06 expands each digit: #FF0066 → {1, 0, 0.4, 1}.
    try t.expectEqual([4]f32{ 1, 0, 0.4, 1 }, doc.paths[1].fill);
    // fill="none" paints nothing: alpha 0.
    try t.expectEqual([4]f32{ 0, 0, 0, 0 }, doc.paths[2].fill);
    // No fill attribute: SVG's initial value, opaque black.
    try t.expectEqual([4]f32{ 0, 0, 0, 1 }, doc.paths[3].fill);
}

test "root svg fill is the document default" {
    const t = std.testing;
    var doc = try parseSvg(
        t.allocator,
        "<svg fill=\"#ffffff\"><path d=\"M0 0\"/><path d=\"M1 1\" fill=\"#000\"/></svg>",
    );
    defer doc.deinit();
    // The path without its own fill inherits the root's white.
    try t.expectEqual([4]f32{ 1, 1, 1, 1 }, doc.paths[0].fill);
    // An explicit fill still wins.
    try t.expectEqual([4]f32{ 0, 0, 0, 1 }, doc.paths[1].fill);
}

test "a malformed fill is black, not the document default; hex is case-insensitive" {
    const t = std.testing;
    var doc = try parseSvg(t.allocator,
        \\<svg fill="#ffffff">
        \\  <path d="M0 0" fill="#AbCdEf"/>
        \\  <path d="M0 0" fill="red"/>
        \\  <path d="M0 0" fill="#1234"/>
        \\</svg>
    );
    defer doc.deinit();
    try t.expectEqual(@as(usize, 3), doc.paths.len);
    // Uppercase hex parses: #AbCdEf → {171, 205, 239}/255.
    try t.expectApproxEqAbs(@as(f32, 171.0 / 255.0), doc.paths[0].fill[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 205.0 / 255.0), doc.paths[0].fill[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 239.0 / 255.0), doc.paths[0].fill[2], 1e-6);
    // A present-but-malformed fill is tolerated as black, never inherited.
    try t.expectEqual([4]f32{ 0, 0, 0, 1 }, doc.paths[1].fill);
    // Wrong hex length: same tolerance.
    try t.expectEqual([4]f32{ 0, 0, 0, 1 }, doc.paths[2].fill);
}

test "the reference tiger parses end to end" {
    const t = std.testing;
    var io_impl = std.Io.Threaded.init(t.allocator, .{});
    defer io_impl.deinit();
    const xml = std.Io.Dir.cwd().readFileAlloc(
        io_impl.io(),
        "notes/research/tiger.svg",
        t.allocator,
        .unlimited,
    ) catch {
        // The corpus file may be absent in a packaged environment — the
        // parse itself is covered by the inline fixtures above.
        return;
    };
    defer t.allocator.free(xml);
    var doc = try parseSvg(t.allocator, xml);
    defer doc.deinit();
    try t.expect(doc.paths.len > 200);
}
