//! Renderer-neutral text requests and immutable layout value types.
const std = @import("std");

/// One registered face. A widget tree may still store a small integer font
/// selector; a host converts it through the service registry, and only
/// handles and requests cross this module.
pub const FontHandle = struct {
    index: u32,
    generation: u32,
};

/// Layout assigns no writing-mode semantics. A node carries the mode the
/// authored fixture or widget asked for and the measure callback maps the
/// logical axes onto physical width and height.
pub const WritingMode = enum { horizontal_tb, vertical_lr };

/// The failures a real text request can report. Core owns this set and unions
/// it into `sizing.Error`, so a refusal from a real provider reaches App
/// publication instead of being replaced by a synthetic fallback. Every name
/// here is reachable from the validated `LayoutRequest` API; a name the
/// service cannot produce does not belong in it.
pub const TextError = error{
    InvalidFont,
    InvalidFontSize,
    InvalidWeight,
    UnknownFont,
    FontUnavailable,
    HarfbuzzFailed,
    MissingGlyph,
    InvalidRange,
    InvalidUtf8,
    InvalidUtf8Boundary,
    InvalidGraphemeBoundary,
    TextTooLong,
    BidiFailed,
    InvalidWrapWidth,
    InvalidLineHeight,
    InvalidLineClamp,
    InvalidSuffix,
    SuffixTooWide,
};

pub const FontStyle = enum { normal, italic, oblique };
pub const Direction = enum { auto, ltr, rtl };
pub const Wrap = enum { flow, no_wrap };
pub const Align = enum { start, center, end, left, right };
pub const TruncateMode = enum { start, middle, end };
pub const MissingGlyph = enum { notdef, error_if_missing };
pub const CaretAffinity = enum { upstream, downstream };

/// What a text box does with content wider than itself. This is a text request
/// policy, so it lives with the request rather than with the widget that
/// happens to own the box today.
pub const TextOverflow = enum { visible, clip, ellipsis };
/// Renderer-neutral sRGBA components in the 0–1 range.
pub const Color = [4]f32;

pub const Feature = struct {
    tag: u32,
    value: u32,
};

/// HarfBuzz/OpenType tags store their first character in the high byte.
pub fn tag(comptime bytes: *const [4]u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | bytes[3];
}

pub const FontRequest = struct {
    handle: ?FontHandle = null,
    family: []const u8 = "",
    size: f32 = 16,
    weight: u16 = 400,
    style: FontStyle = .normal,
    features: []const Feature = &.{},
    /// These handles are tried in order when the primary face lacks a grapheme.
    fallback: []const FontHandle = &.{},
};
/// A null field inherits its parent. An empty fallback slice clears fallbacks.
pub const FontRequestOverride = struct {
    handle: ?FontHandle = null,
    family: ?[]const u8 = null,
    size: ?f32 = null,
    weight: ?u16 = null,
    style: ?FontStyle = null,
    features: ?[]const Feature = null,
    fallback: ?[]const FontHandle = null,

    /// A family override only reaches a host that resolves by family when the
    /// inherited handle is gone: every host's resolver prefers a live handle
    /// over a name, so a carried-over handle would silently ignore the family
    /// the caller asked for. An override that supplies BOTH keeps the handle —
    /// that is an explicit pairing, not a shadowed name.
    pub fn apply(self: FontRequestOverride, inherited: FontRequest) FontRequest {
        var result = inherited;
        if (self.handle) |value| result.handle = value;
        if (self.family) |value| {
            result.family = value;
            if (self.handle == null) result.handle = null;
        }
        if (self.size) |value| result.size = value;
        if (self.weight) |value| result.weight = value;
        if (self.style) |value| result.style = value;
        if (self.features) |value| result.features = value;
        if (self.fallback) |value| result.fallback = value;
        return result;
    }
};

pub const Decoration = struct {
    color: Color,
    thickness: f32 = 1,
    offset: f32 = 0,
};

pub const TextStyle = struct {
    font: FontRequest = .{},
    foreground: Color = .{ 0, 0, 0, 1 },
    background: ?Color = null,
    underline: bool = false,
    strike: bool = false,
    decoration: ?Decoration = null,

    pub fn resolve(self: TextStyle, changes: TextStyleOverride) TextStyle {
        var result = self;
        if (changes.font) |value| result.font = value;
        result.font = changes.font_fields.apply(result.font);
        if (changes.foreground) |value| result.foreground = value;
        switch (changes.background) {
            .inherit => {},
            .clear => result.background = null,
            .color => |value| result.background = value,
        }
        if (changes.underline) |value| result.underline = value;
        if (changes.strike) |value| result.strike = value;
        switch (changes.decoration) {
            .inherit => {},
            .clear => result.decoration = null,
            .value => |value| result.decoration = value,
        }
        return result;
    }
};

pub const BackgroundOverride = union(enum) { inherit, clear, color: Color };
pub const DecorationOverride = union(enum) { inherit, clear, value: Decoration };
pub const TextStyleOverride = struct {
    font: ?FontRequest = null,
    font_fields: FontRequestOverride = .{},
    foreground: ?Color = null,
    background: BackgroundOverride = .inherit,
    underline: ?bool = null,
    strike: ?bool = null,
    decoration: DecorationOverride = .inherit,

    /// Combine authored layers without filling fields from concrete defaults.
    pub fn resolve(self: TextStyleOverride, changes: TextStyleOverride) TextStyleOverride {
        var result = self;
        if (changes.font) |font| {
            result.font = font;
            result.font_fields = .{};
        }
        if (changes.font_fields.family != null and changes.font_fields.handle == null) {
            result.font_fields.handle = null;
        }
        inline for (@typeInfo(FontRequestOverride).@"struct".field_names) |name| {
            if (@field(changes.font_fields, name)) |value| {
                @field(result.font_fields, name) = value;
            }
        }
        if (changes.foreground) |value| result.foreground = value;
        if (changes.background != .inherit) result.background = changes.background;
        if (changes.underline) |value| result.underline = value;
        if (changes.strike) |value| result.strike = value;
        if (changes.decoration != .inherit) result.decoration = changes.decoration;
        return result;
    }

    /// Keep only defaultable fields. A whole font replaces those fields while
    /// preserving inherited values in the fields the chain already authored.
    pub fn restricted(
        self: TextStyleOverride,
        allowed: u16,
        inherited_font: FontRequest,
    ) TextStyleOverride {
        var result = self;
        if (self.font) |font| {
            var restricted_font = inherited_font;
            inline for (@typeInfo(FontRequestOverride).@"struct".field_names, 0..) |name, index| {
                if (allowed & (@as(u16, 1) << index) != 0) {
                    @field(restricted_font, name) = @field(font, name);
                }
            }
            result.font = restricted_font;
        }
        inline for (@typeInfo(FontRequestOverride).@"struct".field_names, 0..) |name, index| {
            if (allowed & (@as(u16, 1) << index) == 0) {
                @field(result.font_fields, name) = null;
            }
        }
        if (result.foreground != null and allowed & TextOrigins.bit(.foreground) == 0) {
            result.foreground = null;
        }
        if (result.background != .inherit and allowed & TextOrigins.bit(.background) == 0) {
            result.background = .inherit;
        }
        if (result.underline != null and allowed & TextOrigins.bit(.underline) == 0) {
            result.underline = null;
        }
        if (result.strike != null and allowed & TextOrigins.bit(.strike) == 0) {
            result.strike = null;
        }
        if (result.decoration != .inherit and allowed & TextOrigins.bit(.decoration) == 0) {
            result.decoration = .inherit;
        }
        return result;
    }
};

/// Where a resolved style field's value came from. `authored` means a node in
/// the inheritance chain specified it through its own options; `defaulted`
/// means only a default layer did — a component's declared text defaults, or
/// the widget kind's own color. The distinction is load-bearing: a default
/// never outranks a value an ancestor authored, and a node's own kind color
/// never outranks a value the chain supplied at all.
/// A field nobody supplied is `unspecified`, which is also the zero of the
/// masks: the root of the chain decided nothing.
pub const TextOrigin = enum(u2) { unspecified, authored, defaulted };

/// The resolved style fields that carry provenance. The first slots are the
/// `FontRequestOverride` fields in declaration order, so a whole
/// `TextStyleOverride.font` request needs no slot of its own: it is one unit
/// and authors every font field at once.
pub const TextField = enum(u4) {
    handle,
    family,
    size,
    weight,
    style,
    features,
    fallback,
    foreground,
    background,
    underline,
    strike,
    decoration,
};

comptime {
    const slots = @typeInfo(TextField).@"enum".field_names;
    const font_fields = @typeInfo(FontRequestOverride).@"struct".field_names;
    if (slots.len != font_fields.len + 5) {
        @compileError("TextField must mirror every authored TextStyleOverride field");
    }
    for (font_fields, 0..) |name, index| {
        if (!std.mem.eql(u8, slots[index], name)) {
            @compileError("TextField must keep the FontRequestOverride field order");
        }
    }
}

/// How many leading slots belong to the font request.
const font_field_count = @typeInfo(TextField).@"enum".field_names.len - 5;

/// Per-field provenance of a resolved style: one bit per field per origin.
/// Two bit masks rather than a sparse record, so the resolved `NodeText` stays
/// copyable and merging two layers is two bitwise operations.
pub const TextOrigins = struct {
    authored: u16 = 0,
    defaulted: u16 = 0,

    /// Every declared field.
    const all: u16 = (@as(u16, 1) << @typeInfo(TextField).@"enum".field_names.len) - 1;
    const font_fields: u16 = (@as(u16, 1) << font_field_count) - 1;

    fn bit(field: TextField) u16 {
        return @as(u16, 1) << @backingInt(field);
    }

    /// True when the chain supplied this field at all, authored or defaulted.
    pub fn supplied(self: TextOrigins, field: TextField) bool {
        return self.authored & bit(field) != 0 or self.defaulted & bit(field) != 0;
    }

    /// Add one layer. Authorship outranks a default for the same field, so a
    /// field that ends up authored is never also recorded as defaulted.
    pub fn merge(self: TextOrigins, added: TextOrigins) TextOrigins {
        const authored = (self.authored | added.authored) & all;
        return .{
            .authored = authored,
            .defaulted = (self.defaulted | added.defaulted) & ~authored & all,
        };
    }

    /// The fields a default layer may still fill: everything the chain did not
    /// author. `TextStyleOverride.restricted` writes exactly these.
    pub fn defaultable(self: TextOrigins) u16 {
        return ~self.authored & all;
    }

    /// The provenance one override layer supplies.
    pub fn fromLayer(layer: TextStyleOverride, origin: TextOrigin) TextOrigins {
        var fields: u16 = 0;
        if (layer.font != null) fields |= font_fields;
        inline for (@typeInfo(FontRequestOverride).@"struct".field_names, 0..) |name, index| {
            if (@field(layer.font_fields, name) != null) {
                fields |= @as(u16, 1) << index;
            }
        }
        if (layer.font_fields.family != null and layer.font_fields.handle == null) {
            fields |= bit(.handle);
        }
        if (layer.foreground != null) fields |= bit(.foreground);
        if (layer.background != .inherit) fields |= bit(.background);
        if (layer.underline != null) fields |= bit(.underline);
        if (layer.strike != null) fields |= bit(.strike);
        if (layer.decoration != .inherit) fields |= bit(.decoration);
        return switch (origin) {
            .authored => .{ .authored = fields },
            .defaulted => .{ .defaulted = fields },
            // A layer with no origin supplies nothing.
            .unspecified => .{},
        };
    }
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const StyledRange = struct {
    range: ByteRange,
    override: TextStyleOverride = .{},
};

pub const Truncation = struct {
    mode: TruncateMode = .end,
    /// UTF-8 text placed at the truncation site; never an implicit ellipsis.
    suffix: []const u8,
};

pub const Paragraph = struct {
    wrap: Wrap = .flow,
    wrap_width: ?f32 = null,
    alignment: Align = .start,
    direction: Direction = .auto,
    line_height: ?f32 = null,
    max_lines: ?usize = null,
    truncate: ?Truncation = null,
};

pub const LayoutRequest = struct {
    content: []const u8,
    content_generation: u64 = 0,
    style: TextStyle = .{},
    ranges: []const StyledRange = &.{},
    paragraph: Paragraph = .{},
    missing_glyph: MissingGlyph = .notdef,
};
/// An authored paragraph policy. A null field keeps the box default instead
/// of pretending that the default was authored, so an explicit option can
/// override what overflow and width resolution derived.
pub const ParagraphOverride = struct {
    wrap: ?Wrap = null,
    wrap_width: ?f32 = null,
    alignment: ?Align = null,
    direction: ?Direction = null,
    line_height: ?f32 = null,
    max_lines: ?usize = null,
    truncate: ?Truncation = null,

    /// Preserve unauthored fields for inheritance and the host's box policy.
    pub fn resolve(self: ParagraphOverride, changes: ParagraphOverride) ParagraphOverride {
        var result = self;
        inline for (@typeInfo(ParagraphOverride).@"struct".field_names) |name| {
            if (@field(changes, name)) |value| @field(result, name) = value;
        }
        return result;
    }

    /// Layer the authored fields over a derived paragraph.
    pub fn apply(self: ParagraphOverride, base: Paragraph) Paragraph {
        var result = base;
        if (self.wrap) |value| result.wrap = value;
        if (self.wrap_width) |value| result.wrap_width = value;
        if (self.alignment) |value| result.alignment = value;
        if (self.direction) |value| result.direction = value;
        if (self.line_height) |value| result.line_height = value;
        if (self.max_lines) |value| result.max_lines = value;
        if (self.truncate) |value| result.truncate = value;
        return result;
    }
};

/// The non-style half of a resolved node request. A node keeps this behind one
/// shared pointer so a default text request needs no allocation at all.
pub const TextExtra = struct {
    ranges: []const StyledRange = &.{},
    paragraph: ParagraphOverride = .{},
    missing_glyph: MissingGlyph = .notdef,
};

/// The resolved, frame-owned text request for one node. Immutable after
/// publication: a host reads it, the layout pass reads it, and neither writes
/// through it. A `style.font.size` of zero means the host default here and
/// only here; the validated `LayoutRequest` API still refuses it.
pub const NodeText = struct {
    style: TextStyle = .{},
    extra: ?*const TextExtra = null,

    /// Which style fields the chain specified, and which only a default layer
    /// supplied. A descendant's default fills neither, so a widget kind's own
    /// color can never mask a foreground the tree already decided.
    origins: TextOrigins = .{},

    pub fn ranges(self: NodeText) []const StyledRange {
        const extra = self.extra orelse return &.{};
        return extra.ranges;
    }

    pub fn paragraph(self: NodeText) ParagraphOverride {
        const extra = self.extra orelse return .{};
        return extra.paragraph;
    }

    pub fn missingGlyph(self: NodeText) MissingGlyph {
        const extra = self.extra orelse return .notdef;
        return extra.missing_glyph;
    }

    pub fn fontSize(self: NodeText) f32 {
        return self.style.font.size;
    }
};

/// The authored per-node text override, copied into the frame arena. It never
/// carries a parent's resolved style: inheritance is resolved once, immediately
/// before layout. Its three layers are separate records because their
/// precedences differ — component defaults, then the inherited container
/// style, then the widget's own options.
pub const TextInput = struct {
    /// What this node's options authored: the strongest layer.
    style: TextStyleOverride = .{},
    /// The component's declared text defaults. A default layer: it fills only
    /// a field the inherited chain left unauthored.
    defaults: TextStyleOverride = .{},
    /// The widget kind's own caption color, when it has one. The weakest
    /// layer: it fills only a field the chain never supplied at all.
    kind_foreground: ?Color = null,
    extra: ?TextExtra = null,
};

/// The resolved text for one node, before the frame takes ownership of it.
/// A null `extra` means the request needs no separate record.
pub const ResolvedText = struct {
    style: TextStyle,
    origins: TextOrigins = .{},
    extra: ?TextExtra = null,
};

/// The root of the inheritance chain. A node that authors nothing resolves to
/// this, so an unset size stays zero and the host's default applies instead of
/// the `TextStyle` default leaking in as a silent 16px.
pub const default_node_text: NodeText = .{ .style = .{ .font = .{ .size = 0 } } };

/// Resolve parent inheritance exactly once. `inherited` is the parent's
/// already-resolved record, `input` this node's authored override, and
/// `alignment` the physical text alignment the node's style resolved to.
///
/// The layers are applied weakest first: a component's declared text defaults
/// fill only what the inherited chain left unauthored, the widget's own
/// options outrank both, and the widget kind's own color fills only a field
/// the chain never supplied. A dense resolved style cannot say which of its
/// fields were authored, so the provenance travels beside it.
pub fn resolveNodeText(
    inherited: ?*const NodeText,
    input: ?*const TextInput,
    alignment: ?Align,
) ResolvedText {
    const base = inherited orelse &default_node_text;
    var style = base.style;
    var origins = base.origins;
    var source: ?TextExtra = if (base.extra) |extra| extra.* else null;
    if (input) |authored| {
        const defaultable = origins.defaultable();
        const defaults = if (defaultable == 0)
            TextOrigins{}
        else
            TextOrigins.fromLayer(authored.defaults, .defaulted);
        if (defaults.defaulted != 0) {
            const inherited_handle = style.font.handle;
            style = style.resolve(authored.defaults.restricted(defaultable, style.font));
            if (defaultable & TextOrigins.bit(.handle) == 0) {
                style.font.handle = inherited_handle;
            }
            origins = origins.merge(defaults);
        }
        const explicit = TextOrigins.fromLayer(authored.style, .authored);
        if (explicit.authored != 0) {
            style = style.resolve(authored.style);
            origins = origins.merge(explicit);
        }
        if (authored.kind_foreground) |color| {
            if (!origins.supplied(.foreground)) {
                style.foreground = color;
                origins = origins.merge(.{ .defaulted = TextOrigins.bit(.foreground) });
            }
        }
        if (authored.extra) |extra| {
            // The inherited paragraph is read BEFORE `source` is reassigned.
            // Naming `source` inside the right-hand side of its own assignment
            // reads a payload whose optional tag the compiler may already have
            // committed to `some`, so the un-written fields of the old record
            // reach the new one as allocator poison. Copying the base out first
            // makes the two values independent and the result identical.
            const inherited_paragraph: ParagraphOverride = if (source) |current| current.paragraph else .{};
            source = .{
                .ranges = extra.ranges,
                // An empty base resolves to exactly the authored policy, so
                // this one expression covers both the inherited and the
                // un-inherited case.
                .paragraph = inherited_paragraph.resolve(extra.paragraph),
                .missing_glyph = extra.missing_glyph,
            };
        }
    }
    const requested: ?Align = if (source) |current| current.paragraph.alignment else null;
    if (alignment != null and requested == null) {
        // The alignment is written through the live record instead of being
        // read back out of `source` to rebuild it: an in-place field write
        // cannot observe its own target's storage.
        if (source) |*current| {
            current.paragraph.alignment = alignment;
        } else {
            source = TextExtra{ .paragraph = .{ .alignment = alignment } };
        }
    }
    if (source == null) return .{ .style = style, .origins = origins };
    return .{ .style = style, .origins = origins, .extra = source.? };
}

/// The box policy one request builder folds into a `LayoutRequest`. Measure and
/// paint pass the same value, so a box cannot measure one way and paint
/// another; only the width legitimately differs.
pub const NodeRequestOptions = struct {
    /// The width the node's content box offers. Null leaves the paragraph
    /// unconstrained, which is how a content probe is taken.
    width: ?f32 = null,
    /// The overflow policy for a box narrower than the text. Null keeps the
    /// node's own authored policy and flows the text.
    overflow: ?TextOverflow = null,
    /// UTF-8 text placed at the truncation site for `.ellipsis`.
    suffix: []const u8 = "...",
};

/// The single request builder. Both measure and paint construct the request
/// here, so the resolved style, the inline ranges, the missing-glyph policy
/// and the final paragraph policy can never disagree between the two.
///
/// The request BORROWS: every slice it names is owned by `content` or by the
/// immutable frame-owned `NodeText`, which lives at least as long as any layout
/// built from this request. Copying them here would duplicate the whole font
/// request on every measure and every paint; only the final `TextLayout` owns
/// copies, because it outlives the frame that produced it.
pub fn nodeRequest(
    content: []const u8,
    node: *const NodeText,
    options: NodeRequestOptions,
) LayoutRequest {
    var paragraph: Paragraph = .{};
    if (options.width) |width| {
        paragraph.wrap_width = width;
        paragraph.wrap = switch (options.overflow orelse .visible) {
            .visible => .flow,
            .clip, .ellipsis => .no_wrap,
        };
        if (options.overflow == .ellipsis) {
            paragraph.truncate = .{ .mode = .end, .suffix = options.suffix };
        }
    } else {
        // A content probe asks what the text wants, never how it would break.
        paragraph.wrap = .no_wrap;
    }
    var ranges: []const StyledRange = &.{};
    var missing_glyph: MissingGlyph = .notdef;
    if (node.extra) |extra| {
        paragraph = extra.paragraph.apply(paragraph);
        missing_glyph = extra.missing_glyph;
        ranges = extra.ranges;
    }
    return .{
        .content = content,
        .style = node.style,
        .ranges = ranges,
        .paragraph = paragraph,
        .missing_glyph = missing_glyph,
    };
}
/// True when a published record already says exactly what this resolution says.
/// A repeated `layoutTree` over an unchanged tree keeps the existing record, so
/// its address stays stable; a re-parented node — whose inherited base changed —
/// publishes a new one.
pub fn nodeTextMatches(record: *const NodeText, resolved: ResolvedText) bool {
    if (!std.meta.eql(record.style, resolved.style)) return false;
    if (record.origins.authored != resolved.origins.authored) return false;
    if (record.origins.defaulted != resolved.origins.defaulted) return false;
    if ((record.extra == null) != (resolved.extra == null)) return false;
    const record_extra = record.extra orelse return true;
    const resolved_extra = resolved.extra.?;
    return record_extra.missing_glyph == resolved_extra.missing_glyph and
        std.meta.eql(record_extra.paragraph, resolved_extra.paragraph) and
        record_extra.ranges.ptr == resolved_extra.ranges.ptr and
        record_extra.ranges.len == resolved_extra.ranges.len;
}

/// Copy a resolution into allocator-owned storage. Layout uses the tree's
/// text-record arena, so direct layout callers need no separate record cleanup.
/// `NodeText.extra` stays separate because nodes may share one immutable value.
pub fn publishNodeText(
    allocator: std.mem.Allocator,
    resolved: ResolvedText,
) std.mem.Allocator.Error!*const NodeText {
    var extra: ?*const TextExtra = null;
    if (resolved.extra) |value| {
        const record = try allocator.create(TextExtra);
        record.* = value;
        extra = record;
    }
    const node = try allocator.create(NodeText);
    node.* = .{
        .style = resolved.style,
        .extra = extra,
        .origins = resolved.origins,
    };
    return node;
}

pub const FontMetrics = struct {
    ascent: f32,
    descent: f32,
    line_gap: f32,
    line_height: f32,
    underline_position: f32,
    underline_thickness: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const TextPosition = struct {
    byte: usize,
    line: usize,
    x: f32,
    y: f32,
    affinity: CaretAffinity,
};

comptime {
    std.debug.assert(@sizeOf(FontHandle) == 8);
}

test "authored text override precedence preserves inheritance and full font replacement" {
    const defaults: TextStyleOverride = .{
        .font_fields = .{ .size = 12, .weight = 600 },
        .foreground = .{ 1, 0, 0, 1 },
        .background = .{ .color = .{ 0, 0, 1, 1 } },
    };
    const explicit: TextStyleOverride = .{
        .font_fields = .{ .size = 18 },
        .background = .clear,
    };
    const parent: TextStyle = .{
        .font = .{ .family = "Parent", .size = 30 },
        .strike = true,
    };
    const resolved = parent.resolve(defaults.resolve(explicit));
    try std.testing.expectEqualStrings("Parent", resolved.font.family);
    try std.testing.expectEqual(@as(f32, 18), resolved.font.size);
    try std.testing.expectEqual(@as(u16, 600), resolved.font.weight);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0, 0, 1 }, &resolved.foreground);
    try std.testing.expectEqual(@as(?Color, null), resolved.background);
    try std.testing.expect(resolved.strike);

    const replacement = parent.resolve(defaults.resolve(.{
        .font = .{ .family = "Replacement", .size = 24, .weight = 400 },
        .font_fields = .{ .style = .italic },
    }));
    try std.testing.expectEqualStrings("Replacement", replacement.font.family);
    try std.testing.expectEqual(@as(f32, 24), replacement.font.size);
    try std.testing.expectEqual(@as(u16, 400), replacement.font.weight);
    try std.testing.expectEqual(FontStyle.italic, replacement.font.style);
}

test "authored paragraph fields inherit without replacing explicit start alignment" {
    const parent: NodeText = .{
        .extra = &.{
            .paragraph = .{ .direction = .rtl, .line_height = 20, .alignment = .center },
        },
    };
    const resolved = resolveNodeText(&parent, &.{
        .extra = .{ .paragraph = .{ .wrap = .no_wrap, .alignment = .start } },
    }, .center);
    const paragraph = resolved.extra.?.paragraph;
    try std.testing.expectEqual(@as(?Direction, .rtl), paragraph.direction);
    try std.testing.expectEqual(@as(?f32, 20), paragraph.line_height);
    try std.testing.expectEqual(@as(?Wrap, .no_wrap), paragraph.wrap);
    try std.testing.expectEqual(@as(?Align, .start), paragraph.alignment);
}
