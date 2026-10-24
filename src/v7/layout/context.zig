const std = @import("std");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");
const text_api = @import("../text.zig");

pub const TextLinePolicy = enum {
    flow,
    single_line,
};

pub const MeasureInput = struct {
    /// Constraints use physical width and height; callbacks map logical axes.
    known_dimensions: sizing.OptionalSize,
    available_space: sizing.AvailableSize,
    /// The resolved text request for the node being measured. Null only where a
    /// node genuinely asks for no text; a provider then uses its own defaults.
    text: ?*const text_api.NodeText = null,
    /// Layout assigns no writing-mode semantics; the callback maps the logical
    /// axes onto the physical constraints above.
    writing_mode: text_api.WritingMode = .horizontal_tb,
    line_policy: TextLinePolicy = .flow,
};

/// The content metrics of one measured request. `first_baseline` is the FIRST
/// shaped line's baseline relative to the text origin, so a final baseline
/// query never needs a second shaping pass.
pub const TextMeasurement = struct {
    width: f32,
    height: f32,
    first_baseline: ?f32 = null,
};

/// A bound measure callback plus the opaque context it reads. The context is
/// passed explicitly on every call: there is no thread-local engine, so a
/// measurement always reaches the service it was bound to.
pub const MeasureSource = struct {
    context: ?*anyopaque = null,
    callback: *const fn (
        ?*anyopaque,
        []const u8,
        MeasureInput,
    ) LayoutError!TextMeasurement,
};

/// The synthetic layout-only fallback. It exists so a tree with no host
/// measures at all; every real provider reports through `TextMeasurement` and
/// its failures through `LayoutError`.
fn syntheticMeasurement(content: []const u8, input: MeasureInput) TextMeasurement {
    const requested = if (input.text) |node| node.fontSize() else 0;
    const scale: f32 = if (requested > 0) requested / 20 else 1;
    const length: f32 = @floatFromInt(content.len);
    return .{ .width = length * 10 * scale, .height = 20 * scale };
}

/// Measure one content string. A real provider's refusal propagates as a
/// `LayoutError`; only a null source falls back to the synthetic estimate.
pub fn measureContent(
    measure: ?MeasureSource,
    content: []const u8,
    input: MeasureInput,
) LayoutError!TextMeasurement {
    var result: TextMeasurement = if (measure) |source|
        try source.callback(source.context, content, input)
    else
        syntheticMeasurement(content, input);
    if (input.known_dimensions.width) |width| result.width = width;
    if (input.known_dimensions.height) |height| result.height = height;
    return result;
}

const NormalizedTextInput = struct {
    input: MeasureInput,
    maximum_width: ?f32,
};

fn normalizeTextInput(
    input: MeasureInput,
    text_overflow: widget.TextOverflow,
    text_max_width: ?f32,
) LayoutError!NormalizedTextInput {
    const maximum_width = if (text_max_width) |value| blk: {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStyle;
        break :blk value;
    } else null;
    var text_input = input;
    const single_line = switch (text_overflow) {
        .visible => false,
        .clip => maximum_width != null,
        .ellipsis => true,
    };
    if (single_line) {
        text_input.available_space.width = .max_content;
        text_input.line_policy = .single_line;
    }
    return .{
        .input = text_input,
        .maximum_width = maximum_width,
    };
}

fn applyTextOverflow(
    measured: TextMeasurement,
    text_overflow: text_api.TextOverflow,
    maximum_width: ?f32,
) TextMeasurement {
    var result = measured;
    if (text_overflow != .visible) {
        if (maximum_width) |value| result.width = @min(result.width, value);
    }
    return result;
}

pub const TextDecoration = struct {
    leading_width: f32 = 0,
    vertical_extent: f32 = 0,
    minimum_width: f32 = 0,
    minimum_height: f32 = 0,
};

/// The ONE measure-side view of `widget.textInsets`. Layout decoration and the
/// paint path read the same table, so a caption's box and its glyphs cannot
/// disagree about the column the text occupies. `minimum_*` are the control's
/// own intrinsic floors, not text insets, so they stay here.
pub fn textDecoration(kind: widget.WidgetKind) TextDecoration {
    const insets = widget.textInsets(kind);
    return .{
        .leading_width = insets.horizontal(),
        .vertical_extent = insets.vertical(),
        .minimum_width = switch (kind) {
            .progress => 100,
            else => 0,
        },
        .minimum_height = switch (kind) {
            .checkbox, .radio, .switch_control => widget.control_indicator_size,
            .progress => 8,
            else => 0,
        },
    };
}

fn applySliderFloors(result: widget.Size, input: MeasureInput) widget.Size {
    var adjusted = result;
    if (input.known_dimensions.width) |width| {
        adjusted.width = width;
    } else {
        adjusted.width = @max(100, adjusted.width);
    }
    if (input.known_dimensions.height) |height| {
        adjusted.height = height;
    } else {
        adjusted.height = @max(widget.slider_rail_height, adjusted.height);
    }
    return adjusted;
}

pub const LayoutError = sizing.Error;

/// Measure one content string with no pass cache. A real provider's refusal
/// propagates as a `LayoutError`; only a null source falls back to the
/// synthetic estimate, which is what keeps the layout goldens unchanged.
pub fn measureText(
    measure: ?MeasureSource,
    content: []const u8,
    input: MeasureInput,
    text_overflow: text_api.TextOverflow,
    text_max_width: ?f32,
) LayoutError!TextMeasurement {
    const normalized = try normalizeTextInput(input, text_overflow, text_max_width);
    const measured = try measureContent(measure, content, normalized.input);
    return applyTextOverflow(measured, text_overflow, normalized.maximum_width);
}

/// The content extent only, for callers that need a size and no baseline.
pub fn measureTextSize(
    measure: ?MeasureSource,
    content: []const u8,
    input: MeasureInput,
    text_overflow: text_api.TextOverflow,
    text_max_width: ?f32,
) LayoutError!widget.Size {
    const measured = try measureText(measure, content, input, text_overflow, text_max_width);
    return .{ .width = measured.width, .height = measured.height };
}
fn visibleTextDecoration(text: []const u8, decoration: TextDecoration) TextDecoration {
    var result = decoration;
    if (text.len == 0) result.vertical_extent = 0;
    return result;
}

fn decoratedTextInput(
    input: MeasureInput,
    decoration: TextDecoration,
) LayoutError!MeasureInput {
    try validateConcrete(decoration.leading_width);
    try validateConcrete(decoration.vertical_extent);
    try validateConcrete(decoration.minimum_width);
    try validateConcrete(decoration.minimum_height);
    var result = input;
    if (result.known_dimensions.width) |width| {
        result.known_dimensions.width = @max(0, width - decoration.leading_width);
    }
    if (result.known_dimensions.height) |height| {
        result.known_dimensions.height = @max(0, height - decoration.vertical_extent);
    }
    result.available_space.width = subtractDecoration(
        result.available_space.width,
        decoration.leading_width,
    );
    result.available_space.height = subtractDecoration(
        result.available_space.height,
        decoration.vertical_extent,
    );
    return result;
}

fn subtractDecoration(
    available: sizing.AvailableSpace,
    extent: f32,
) sizing.AvailableSpace {
    return switch (available) {
        .definite => |value| .{ .definite = @max(0, value - extent) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

/// Combine a decorated measurement with its decoration. The result keeps the
/// shaped line's own baseline, so a control's baseline needs no second query.
fn combineDecoratedText(
    measured: TextMeasurement,
    input: MeasureInput,
    decoration: TextDecoration,
) LayoutError!TextMeasurement {
    try validateConcrete(measured.width);
    try validateConcrete(measured.height);
    var result: TextMeasurement = .{
        .width = @max(
            decoration.minimum_width,
            measured.width + decoration.leading_width,
        ),
        .height = @max(
            decoration.minimum_height,
            measured.height + decoration.vertical_extent,
        ),
    };
    if (measured.first_baseline) |baseline| {
        result.first_baseline = baseline + decoration.vertical_extent;
    }
    if (input.known_dimensions.width) |width| result.width = width;
    if (input.known_dimensions.height) |height| result.height = height;
    try validateConcrete(result.width);
    try validateConcrete(result.height);
    return result;
}

/// Measure decorated text with no pass cache. The returned measurement carries
/// the baseline, so a caller that needs one never measures twice.
pub fn measureDecoratedText(
    measure: ?MeasureSource,
    content: []const u8,
    input: MeasureInput,
    text_overflow: text_api.TextOverflow,
    text_max_width: ?f32,
    decoration: TextDecoration,
) LayoutError!TextMeasurement {
    const text_decoration = visibleTextDecoration(content, decoration);
    const text_input = try decoratedTextInput(input, text_decoration);
    const measured = if (content.len == 0) blk: {
        _ = try normalizeTextInput(text_input, text_overflow, text_max_width);
        break :blk TextMeasurement{ .width = 0, .height = 0 };
    } else try measureText(
        measure,
        content,
        text_input,
        text_overflow,
        text_max_width,
    );
    return combineDecoratedText(measured, input, text_decoration);
}

/// The content extent only, for callers that need a size and no baseline.
pub fn measureDecoratedTextSize(
    measure: ?MeasureSource,
    content: []const u8,
    input: MeasureInput,
    text_overflow: text_api.TextOverflow,
    text_max_width: ?f32,
    decoration: TextDecoration,
) LayoutError!widget.Size {
    const measured = try measureDecoratedText(
        measure,
        content,
        input,
        text_overflow,
        text_max_width,
        decoration,
    );
    return .{ .width = measured.width, .height = measured.height };
}

pub fn validateLeafGeometry(kind: widget.WidgetKind) LayoutError!void {
    switch (kind) {
        .progress => |progress| {
            if (!std.math.isFinite(progress.value)) return error.InvalidStyle;
            if (!std.math.isFinite(progress.min)) return error.InvalidStyle;
            if (!std.math.isFinite(progress.max)) return error.InvalidStyle;
            if (progress.max <= progress.min) return error.InvalidStyle;
        },
        .separator => |separator| {
            try validateConcrete(separator.thickness);
            if (separator.thickness == 0) return error.InvalidStyle;
        },
        .checkbox, .switch_control, .radio, .label, .button, .slider, .spacer, .row, .column, .element => {},
    }
}

/// Element payloads are immutable during a pass. The canonical dispatcher
/// clears layout caches between passes, so revisions never share entries.
pub fn measureElement(node: *const widget.WidgetNode, input: MeasureInput) LayoutError!widget.Size {
    const frame = node.kind.element;
    var result = try frame.ops.measure(frame.payload, input);
    try validateConcrete(result.width);
    try validateConcrete(result.height);
    if (input.known_dimensions.width) |known| result.width = known;
    if (input.known_dimensions.height) |known| result.height = known;
    return result;
}

/// The first baseline of the text a node paints, measured once. `measured` is
/// the decorated measurement of that text, so the shaped line's own baseline
/// wins when the provider supplied one and the synthetic rule survives only as
/// the no-baseline fallback. A node with no visible text has no baseline here
/// and the caller falls back to its own box.
pub fn textNodeBaseline(
    node: *const widget.WidgetNode,
    top_inset: f32,
    measured: ?TextMeasurement,
) LayoutError!?f32 {
    if (visibleNodeText(node).len == 0) return null;
    const baseline = try measuredTextBaseline(node, top_inset, measured);
    return baseline;
}

fn measuredTextBaseline(
    node: *const widget.WidgetNode,
    top_inset: f32,
    measured: ?TextMeasurement,
) LayoutError!f32 {
    try validateConcrete(top_inset);
    // A real provider's shaped line wins outright: the synthetic rule below
    // exists only for a request that supplied no baseline at all.
    if (measured) |value| {
        if (value.first_baseline) |baseline| {
            const result = top_inset + baseline;
            try validateConcrete(result);
            return result;
        }
    }
    const requested = requestedFontSize(node);
    const size = if (requested > 0) requested else synthetic_default_font_size;
    const baseline = top_inset + size * 0.8;
    try validateConcrete(baseline);
    return baseline;
}

/// The size the node asks for. A resolved, frame-published record is
/// authoritative. A directly assembled tree that no frame resolved carries
/// only its authored input, so the same resolver reads that with no inherited
/// base; a node that authored no size still answers zero, which is the host
/// default and keeps the Ahem and layout-only goldens unchanged.
fn requestedFontSize(node: *const widget.WidgetNode) f32 {
    if (node.text_request) |request| return request.fontSize();
    const authored = node.text_input orelse return 0;
    return text_api.resolveNodeText(null, authored, null).style.font.size;
}

/// The size a host default stands in for when nothing else is known. It is a
/// baseline fallback only; the request itself keeps size zero so the provider
/// supplies its own default.
pub const synthetic_default_font_size: f32 = 16;

/// The caption a control shows, or an empty slice when it shows none.
pub fn controlCaption(node: *const widget.WidgetNode) []const u8 {
    return switch (node.kind) {
        .checkbox => |value| value.label,
        .switch_control => |value| value.label,
        .radio => |value| value.label,
        .progress => |value| value.label,
        else => "",
    };
}

/// The text a node paints itself: a label's own text, a button's visible
/// label, a control's caption. Empty when the node paints no text.
pub fn visibleNodeText(node: *const widget.WidgetNode) []const u8 {
    return switch (node.kind) {
        .label => |value| value.text,
        .button => widget.buttonVisualLabel(node.kind),
        .slider => widget.sliderVisualLabel(node.kind),
        else => controlCaption(node),
    };
}

pub fn measureSliderContent(
    measure: ?MeasureSource,
    node: *const widget.WidgetNode,
    input: MeasureInput,
) LayoutError!widget.Size {
    const content = widget.sliderVisualLabel(node.kind);
    const result = if (content.len == 0)
        widget.Size{ .width = 100, .height = widget.slider_rail_height }
    else
        try measureTextSize(measure, content, input, node.text_overflow, node.text_max_width);
    return applySliderFloors(result, input);
}

pub const MeasureMode = enum {
    definite,
    min_content,
    max_content,
};

pub const SizingMode = enum {
    inherent,
    content,
};

pub const Request = struct {
    available: widget.Size,
    percentage_basis: style.Size(?f32),
    width_mode: MeasureMode = .definite,
    height_mode: MeasureMode = .definite,
    /// Inherent sizing uses style values unless a known border axis overrides them.
    /// Content sizing makes known_border complete: null axes ignore style sizing,
    /// including preferred, minimum, maximum, and aspect-ratio values.
    sizing_mode: SizingMode = .inherent,
    /// Values are border-box sizes; content sizing still applies box-model floors,
    /// and conversion to content-box dimensions occurs only at a leaf callback.
    known_border: sizing.OptionalSize = .{ .width = null, .height = null },
};

pub const LayoutRequest = struct {
    available: widget.Size,
    percentage_basis: style.Size(?f32),
    border: widget.Size,
};
/// Validate the concrete parts of a natural-measurement request.
/// A missing percentage basis is an indefinite axis, not invalid input.
/// Percentage-dependent values defer until a later definite layout pass.
pub fn validateNaturalRequest(
    _: *const widget.WidgetTree,
    _: *const widget.WidgetNode,
    request: Request,
) LayoutError!void {
    try validateConcrete(request.available.width);
    try validateConcrete(request.available.height);
    if (request.known_border.width) |width| try validateConcrete(width);
    if (request.known_border.height) |height| try validateConcrete(height);

    if (request.percentage_basis.width) |basis| try validateConcrete(basis);
    if (request.percentage_basis.height) |basis| try validateConcrete(basis);
}

fn validateConcrete(value: f32) LayoutError!void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidStyle;
}

pub const Measured = struct {
    content: widget.Size,
    border: widget.Size,
};

pub const MeasurementCache = struct {
    pub const OptionalFloatKey = struct {
        present: bool,
        bits: u32 = 0,
    };

    /// Immutable request identity. Construct it with key() to prepare its hash.
    pub const Key = struct {
        node_index: usize,
        float_bits: [6]u32,
        tags: u64,
        /// Prepared once, then reused by lookup, insertion, and table growth.
        hash_code: u64,
    };
    pub const KeyContext = struct {
        pub fn hash(_: MeasurementCache.KeyContext, cache_key: MeasurementCache.Key) u64 {
            return cache_key.hash_code;
        }

        pub fn eql(_: MeasurementCache.KeyContext, left: MeasurementCache.Key, right: MeasurementCache.Key) bool {
            return left.node_index == right.node_index and
                left.float_bits[0] == right.float_bits[0] and
                left.float_bits[1] == right.float_bits[1] and
                left.float_bits[2] == right.float_bits[2] and
                left.float_bits[3] == right.float_bits[3] and
                left.float_bits[4] == right.float_bits[4] and
                left.float_bits[5] == right.float_bits[5] and
                left.tags == right.tags;
        }
    };
    map: std.HashMapUnmanaged(
        Key,
        Measured,
        KeyContext,
        std.hash_map.default_max_load_percentage,
    ) = .empty,

    pub fn key(
        node_index: usize,
        request: Request,
        parent_display: ?style.Display,
    ) Key {
        const percentage_width = optionalFloatKey(request.percentage_basis.width);
        const percentage_height = optionalFloatKey(request.percentage_basis.height);
        const known_border_width = optionalFloatKey(request.known_border.width);
        const known_border_height = optionalFloatKey(request.known_border.height);
        const float_bits = [_]u32{
            @bitCast(request.available.width),
            @bitCast(request.available.height),
            percentage_width.bits,
            percentage_height.bits,
            known_border_width.bits,
            known_border_height.bits,
        };
        const tags = std.mem.bytesToValue(u64, &[_]u8{
            @intFromBool(percentage_width.present),
            @intFromBool(percentage_height.present),
            @intFromBool(known_border_width.present),
            @intFromBool(known_border_height.present),
            @intCast(@backingInt(request.width_mode)),
            @intCast(@backingInt(request.height_mode)),
            @intCast(@backingInt(request.sizing_mode)),
            if (parent_display) |display|
                @as(u8, @intCast(@backingInt(display) + 1))
            else
                0,
        });
        // An odd multiplier spreads node indices without rehashing shared constraints.
        const node_hash = @as(u64, @intCast(node_index)) *% 0x9E37_79B9_7F4A_7C15;
        const hash_code = requestHash(&float_bits, tags) ^ node_hash;
        const cache_key: Key = .{
            .node_index = node_index,
            .float_bits = float_bits,
            .tags = tags,
            .hash_code = hash_code,
        };
        return cache_key;
    }

    fn requestHash(float_bits: *const [6]u32, tags: u64) u64 {
        // Array layout preserves the request byte order without depending on Key field placement.
        const float_words = std.mem.bytesToValue([3]u64, std.mem.asBytes(float_bits));
        const request_words: [4]u64 = .{
            float_words[0],
            float_words[1],
            float_words[2],
            tags,
        };
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&request_words));
    }

    pub fn lookup(self: *const MeasurementCache, cache_key: Key) ?Measured {
        return self.map.getContext(cache_key, .{});
    }

    pub fn insert(
        self: *MeasurementCache,
        allocator: std.mem.Allocator,
        cache_key: Key,
        measured: Measured,
    ) LayoutError!void {
        try self.map.putContext(allocator, cache_key, measured, .{});
    }
    pub fn clearRetainingCapacity(self: *MeasurementCache) void {
        self.map.clearRetainingCapacity();
    }
    pub fn deinit(self: *MeasurementCache, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.* = undefined;
    }
};

/// Exact callback inputs for one layout pass, and the measurements they
/// produced. The stored value is the full `TextMeasurement`, so a later
/// baseline query for the same constraints is answered from this cache and
/// never shapes the text again. Node content and the resolved text request stay
/// fixed until the pass ends; `LayoutStorage` clears entries between passes.
pub const TextMeasurementCache = struct {
    pub const slots_per_node: usize = 8;

    pub const AvailableSpaceKey = struct {
        tag: u8,
        bits: u32 = 0,
    };

    pub const Key = struct {
        node_index: usize,
        input_bits: [6]u32,
    };

    const Entry = struct {
        input_bits: [6]u32,
        value: TextMeasurement,
        valid: bool = false,
    };

    const NodeSlots = struct {
        entries: [slots_per_node]Entry,
        next_replacement: usize = 0,
        unconstrained: ?TextMeasurement = null,
        /// The request identity the unconstrained entry was taken under. A
        /// different request must not reuse it, so the fast path stays keyed
        /// by the same text, writing mode and line policy the entry was
        /// recorded with.
        unconstrained_text: ?*const text_api.NodeText = null,
        unconstrained_writing_mode: text_api.WritingMode = .horizontal_tb,
        unconstrained_line_policy: TextLinePolicy = .flow,
        unconstrained_available_height: AvailableSpaceKey = .{ .tag = 2 },
    };

    nodes: std.ArrayListUnmanaged(NodeSlots) = .empty,

    /// The constraint-aware key for one measure call. The resolved text request
    /// is a frame-owned immutable record addressed by the node, so the node
    /// index identifies it; the writing mode and line policy are part of the
    /// key because they change what the callback answers.
    pub fn key(node_index: usize, input: MeasureInput) Key {
        const known_width = optionalFloatKey(input.known_dimensions.width);
        const known_height = optionalFloatKey(input.known_dimensions.height);
        const available_width = availableSpaceKey(input.available_space.width);
        const available_height = availableSpaceKey(input.available_space.height);
        const tags = @as(u32, @intFromBool(known_width.present)) |
            (@as(u32, @intFromBool(known_height.present)) << 1) |
            (@as(u32, available_width.tag) << 2) |
            (@as(u32, available_height.tag) << 4) |
            (@as(u32, @backingInt(input.writing_mode)) << 8) |
            (@as(u32, @backingInt(input.line_policy)) << 16);
        return .{
            .node_index = node_index,
            // Tag-first words compare without padding or copying resident keys.
            .input_bits = .{
                tags,
                known_width.bits,
                known_height.bits,
                available_width.bits,
                available_height.bits,
                if (input.text) |request| @as(u32, @bitCast(request.fontSize())) else 0,
            },
        };
    }

    fn availableSpaceKey(value: sizing.AvailableSpace) AvailableSpaceKey {
        return switch (value) {
            .definite => |number| .{
                .tag = 0,
                .bits = @as(u32, @bitCast(number)),
            },
            .min_content => .{ .tag = 1 },
            .max_content => .{ .tag = 2 },
        };
    }

    fn resetNodeSlots(slots: *NodeSlots) void {
        for (&slots.entries) |*entry| entry.valid = false;
        slots.next_replacement = 0;
        slots.unconstrained = null;
        slots.unconstrained_text = null;
    }

    fn ensureNode(
        self: *TextMeasurementCache,
        allocator: std.mem.Allocator,
        node_index: usize,
    ) LayoutError!*NodeSlots {
        if (node_index >= self.nodes.items.len) {
            const old_len = self.nodes.items.len;
            const new_len = std.math.add(usize, node_index, 1) catch
                return error.InvalidStyle;
            self.nodes.resize(allocator, new_len) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            for (self.nodes.items[old_len..]) |*slots| resetNodeSlots(slots);
        }
        return &self.nodes.items[node_index];
    }

    pub fn lookup(self: *const TextMeasurementCache, cache_key: Key) ?TextMeasurement {
        if (cache_key.node_index >= self.nodes.items.len) return null;
        const slots = &self.nodes.items[cache_key.node_index];
        for (&slots.entries) |*entry| {
            if (entry.valid) {
                if (entry.input_bits[0] == cache_key.input_bits[0] and
                    entry.input_bits[1] == cache_key.input_bits[1] and
                    entry.input_bits[2] == cache_key.input_bits[2] and
                    entry.input_bits[3] == cache_key.input_bits[3] and
                    entry.input_bits[4] == cache_key.input_bits[4] and
                    entry.input_bits[5] == cache_key.input_bits[5])
                {
                    return entry.value;
                }
            }
        }
        return null;
    }

    /// Reuse an unconstrained measurement for a constraint that cannot change
    /// it. The entry is only valid under the same text request, writing mode
    /// and line policy it was recorded with, and only for a width at least as
    /// large as the measured ink: a narrower box may wrap, so it takes the
    /// exact key.
    pub fn lookupUnconstrained(
        self: *const TextMeasurementCache,
        node_index: usize,
        input: MeasureInput,
    ) ?TextMeasurement {
        if (node_index >= self.nodes.items.len) return null;
        const slots = &self.nodes.items[node_index];
        const unconstrained = slots.unconstrained orelse return null;
        if (slots.unconstrained_text != input.text) return null;
        if (slots.unconstrained_writing_mode != input.writing_mode) return null;
        if (slots.unconstrained_line_policy != input.line_policy) return null;
        const height_key = availableSpaceKey(input.available_space.height);
        if (slots.unconstrained_available_height.tag != height_key.tag or
            slots.unconstrained_available_height.bits != height_key.bits)
        {
            return null;
        }
        return switch (input.available_space.width) {
            .max_content => unconstrained,
            .definite => |width| if (width >= unconstrained.width) unconstrained else null,
            .min_content => null,
        };
    }

    pub fn recordUnconstrained(
        self: *TextMeasurementCache,
        node_index: usize,
        input: MeasureInput,
        measured: TextMeasurement,
    ) void {
        if (node_index >= self.nodes.items.len) return;
        const slots = &self.nodes.items[node_index];
        slots.unconstrained = measured;
        slots.unconstrained_available_height = availableSpaceKey(input.available_space.height);
        slots.unconstrained_text = input.text;
        slots.unconstrained_writing_mode = input.writing_mode;
        slots.unconstrained_line_policy = input.line_policy;
    }

    /// Insert after a miss; repeated keys never reach the replacement path.
    pub fn insert(
        self: *TextMeasurementCache,
        allocator: std.mem.Allocator,
        cache_key: Key,
        measured: TextMeasurement,
    ) LayoutError!void {
        const slots = try self.ensureNode(allocator, cache_key.node_index);
        const replacement_index = slots.next_replacement;
        slots.next_replacement = if (replacement_index + 1 == slots_per_node)
            0
        else
            replacement_index + 1;
        slots.entries[replacement_index] = .{
            .input_bits = cache_key.input_bits,
            .value = measured,
            .valid = true,
        };
    }

    pub fn clearRetainingCapacity(self: *TextMeasurementCache) void {
        for (self.nodes.items) |*slots| resetNodeSlots(slots);
    }

    pub fn deinit(self: *TextMeasurementCache, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.* = undefined;
    }
};

fn optionalFloatKey(value: ?f32) MeasurementCache.OptionalFloatKey {
    return if (value) |number|
        .{ .present = true, .bits = @as(u32, @bitCast(number)) }
    else
        .{ .present = false };
}

pub const ResolvedEdges = struct {
    border: style.Sides,
    padding: style.Sides,
    raw_padding: style.Sides,
    box_horizontal: f32,
    box_vertical: f32,
    horizontal: f32,
    vertical: f32,
};

pub const EdgeResolutionCache = struct {
    const OptionalFloatKey = MeasurementCache.OptionalFloatKey;

    const Entry = struct {
        basis: OptionalFloatKey,
        edges: ResolvedEdges,
    };

    const NodeEntries = struct {
        indefinite: Entry,
        definite: Entry,
        indefinite_valid: bool = false,
        definite_valid: bool = false,
    };

    entries: std.ArrayListUnmanaged(NodeEntries) = .empty,

    pub fn prepare(
        self: *EdgeResolutionCache,
        allocator: std.mem.Allocator,
        node_count: usize,
    ) LayoutError!void {
        const old_len = self.entries.items.len;
        self.entries.resize(allocator, node_count) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        const initialized_len = @min(old_len, node_count);
        for (self.entries.items[initialized_len..]) |*entry| resetNodeEntries(entry);
    }

    fn resetNodeEntries(entry: *NodeEntries) void {
        entry.indefinite_valid = false;
        entry.definite_valid = false;
    }
    pub fn lookup(
        self: *const EdgeResolutionCache,
        node_index: usize,
        basis: ?f32,
    ) ?ResolvedEdges {
        if (node_index >= self.entries.items.len) return null;
        const key = optionalFloatKey(basis);
        const node_entries = &self.entries.items[node_index];
        const entry: ?*const Entry = if (key.present) blk: {
            if (!node_entries.definite_valid) break :blk null;
            break :blk &node_entries.definite;
        } else blk: {
            if (!node_entries.indefinite_valid) break :blk null;
            break :blk &node_entries.indefinite;
        };
        if (entry) |value| {
            if (value.basis.present == key.present and value.basis.bits == key.bits) {
                return value.edges;
            }
        }
        return null;
    }

    pub fn insert(
        self: *EdgeResolutionCache,
        node_index: usize,
        basis: ?f32,
        edges: ResolvedEdges,
    ) LayoutError!void {
        if (node_index >= self.entries.items.len) return error.InvalidStyle;
        const key = optionalFloatKey(basis);
        const entry: Entry = .{ .basis = key, .edges = edges };
        if (key.present) {
            self.entries.items[node_index].definite = entry;
            self.entries.items[node_index].definite_valid = true;
        } else {
            self.entries.items[node_index].indefinite = entry;
            self.entries.items[node_index].indefinite_valid = true;
        }
    }

    pub fn clearRetainingCapacity(self: *EdgeResolutionCache) void {
        for (self.entries.items) |*entry| resetNodeEntries(entry);
    }

    pub fn deinit(self: *EdgeResolutionCache, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = undefined;
    }
};

pub const LayoutStorage = struct {
    allocator: std.mem.Allocator,
    flex_measure_cache: MeasurementCache = .{},
    flex_edge_cache: EdgeResolutionCache = .{},
    text_measure_cache: TextMeasurementCache = .{},

    pub fn init(allocator: std.mem.Allocator) LayoutStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LayoutStorage) void {
        self.flex_measure_cache.deinit(self.allocator);
        self.flex_edge_cache.deinit(self.allocator);
        self.text_measure_cache.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *LayoutStorage) void {
        self.flex_measure_cache.clearRetainingCapacity();
        self.flex_edge_cache.clearRetainingCapacity();
        self.text_measure_cache.clearRetainingCapacity();
    }
};
pub const MeasureNodeFn = *const fn (
    self: *LayoutContext,
    tree: *widget.WidgetTree,
    node: *const widget.WidgetNode,
    request: Request,
) LayoutError!Measured;

pub const LayoutNodeFn = *const fn (
    self: *LayoutContext,
    tree: *widget.WidgetTree,
    node: *widget.WidgetNode,
    request: LayoutRequest,
) LayoutError!void;

const scratch_word_bytes: usize = @sizeOf(u128);

const ScratchMark = struct {
    byte_offset: usize,
};

pub const LayoutContext = struct {
    allocator: std.mem.Allocator,
    measure: ?MeasureSource,
    measure_node: MeasureNodeFn,
    layout_node: LayoutNodeFn,
    storage: ?*LayoutStorage = null,
    flex_measure_cache: MeasurementCache = .{},
    flex_edge_cache: EdgeResolutionCache = .{},
    text_measure_cache: TextMeasurementCache = .{},
    flex_edge_cache_depth: usize = 0,
    block_scratch_words: ?[]u128 = null,
    block_scratch_byte_limit: usize = 0,
    block_scratch_used_bytes: usize = 0,
    block_scratch_item_size: usize = 0,
    block_scratch_item_alignment: usize = 0,
    block_scratch_marks: std.ArrayListUnmanaged(ScratchMark) = .empty,
    block_scratch_depth: usize = 0,
    grid_cache_words: ?[]u128 = null,
    grid_cache_initialized_items: usize = 0,
    grid_cache_next_replacement: usize = 0,
    pub fn flexMeasurementCache(self: *LayoutContext) *MeasurementCache {
        if (self.storage) |storage| return &storage.flex_measure_cache;
        return &self.flex_measure_cache;
    }

    pub fn flexMeasurementAllocator(self: *const LayoutContext) std.mem.Allocator {
        if (self.storage) |storage| return storage.allocator;
        return self.allocator;
    }

    pub fn textMeasurementCache(self: *LayoutContext) *TextMeasurementCache {
        if (self.storage) |storage| return &storage.text_measure_cache;
        return &self.text_measure_cache;
    }

    pub fn textMeasurementAllocator(self: *const LayoutContext) std.mem.Allocator {
        if (self.storage) |storage| return storage.allocator;
        return self.allocator;
    }

    /// Measure one content string through the pass cache and return the full
    /// measurement, so a caller that needs the baseline never re-measures.
    pub fn measureTextCached(
        self: *LayoutContext,
        node_index: usize,
        content: []const u8,
        input: MeasureInput,
        text_overflow: text_api.TextOverflow,
        text_max_width: ?f32,
    ) LayoutError!TextMeasurement {
        const normalized = try normalizeTextInput(input, text_overflow, text_max_width);
        const cache = self.textMeasurementCache();
        const cache_key = TextMeasurementCache.key(node_index, normalized.input);
        const is_unconstrained_candidate = (normalized.input.known_dimensions.width == null and
            normalized.input.known_dimensions.height == null) and
            (normalized.input.line_policy == .single_line or
                std.mem.indexOfScalar(u8, content, '\n') == null);
        const cached = if (is_unconstrained_candidate)
            cache.lookupUnconstrained(node_index, normalized.input) orelse
                cache.lookup(cache_key)
        else
            cache.lookup(cache_key);

        const measured = cached orelse blk: {
            const result = try measureContent(self.measure, content, normalized.input);
            try cache.insert(self.textMeasurementAllocator(), cache_key, result);
            if (is_unconstrained_candidate) {
                const can_record = switch (normalized.input.available_space.width) {
                    .max_content => true,
                    .definite, .min_content => false,
                };
                if (can_record) {
                    cache.recordUnconstrained(node_index, normalized.input, result);
                }
            }
            break :blk result;
        };
        return applyTextOverflow(measured, text_overflow, normalized.maximum_width);
    }

    /// The content extent only, for callers that need a size and no baseline.
    pub fn measureTextSizeCached(
        self: *LayoutContext,
        node_index: usize,
        content: []const u8,
        input: MeasureInput,
        text_overflow: text_api.TextOverflow,
        text_max_width: ?f32,
    ) LayoutError!widget.Size {
        const measured = try self.measureTextCached(
            node_index,
            content,
            input,
            text_overflow,
            text_max_width,
        );
        return .{ .width = measured.width, .height = measured.height };
    }

    /// Measure the text a node actually paints through the same pass cache and
    /// return the decorated measurement. The baseline it carries is the shaped
    /// line's own, so `textNodeBaseline` needs no second call.
    pub fn measureVisibleNodeTextCached(
        self: *LayoutContext,
        node_index: usize,
        node: *const widget.WidgetNode,
        input: MeasureInput,
    ) LayoutError!TextMeasurement {
        return self.measureDecoratedTextCached(
            node_index,
            visibleNodeText(node),
            input,
            node.text_overflow,
            node.text_max_width,
            textDecoration(node.kind),
        );
    }

    pub fn measureDecoratedTextCached(
        self: *LayoutContext,
        node_index: usize,
        content: []const u8,
        input: MeasureInput,
        text_overflow: text_api.TextOverflow,
        text_max_width: ?f32,
        decoration: TextDecoration,
    ) LayoutError!TextMeasurement {
        const text_decoration = visibleTextDecoration(content, decoration);
        const text_input = try decoratedTextInput(input, text_decoration);
        const measured = if (content.len == 0) blk: {
            _ = try normalizeTextInput(text_input, text_overflow, text_max_width);
            break :blk TextMeasurement{ .width = 0, .height = 0 };
        } else try self.measureTextCached(
            node_index,
            content,
            text_input,
            text_overflow,
            text_max_width,
        );
        return combineDecoratedText(measured, input, text_decoration);
    }

    /// The content extent only, for callers that need a size and no baseline.
    pub fn measureDecoratedTextSizeCached(
        self: *LayoutContext,
        node_index: usize,
        content: []const u8,
        input: MeasureInput,
        text_overflow: text_api.TextOverflow,
        text_max_width: ?f32,
        decoration: TextDecoration,
    ) LayoutError!widget.Size {
        const measured = try self.measureDecoratedTextCached(
            node_index,
            content,
            input,
            text_overflow,
            text_max_width,
            decoration,
        );
        return .{ .width = measured.width, .height = measured.height };
    }

    pub fn measureSliderContentCached(
        self: *LayoutContext,
        node_index: usize,
        node: *const widget.WidgetNode,
        input: MeasureInput,
    ) LayoutError!widget.Size {
        const content = widget.sliderVisualLabel(node.kind);
        const result = if (content.len == 0)
            widget.Size{ .width = 100, .height = widget.slider_rail_height }
        else
            try self.measureTextSizeCached(
                node_index,
                content,
                input,
                node.text_overflow,
                node.text_max_width,
            );
        return applySliderFloors(result, input);
    }

    pub fn flexEdgeCache(self: *LayoutContext) *EdgeResolutionCache {
        if (self.storage) |storage| return &storage.flex_edge_cache;
        return &self.flex_edge_cache;
    }

    pub fn flexEdgeAllocator(self: *const LayoutContext) std.mem.Allocator {
        if (self.storage) |storage| return storage.allocator;
        return self.allocator;
    }

    pub fn beginFlexEdgePass(self: *LayoutContext, node_count: usize) LayoutError!void {
        const cache = self.flexEdgeCache();
        if (self.storage == null and self.flex_edge_cache_depth == 0) {
            cache.clearRetainingCapacity();
        }
        try cache.prepare(self.flexEdgeAllocator(), node_count);
        self.flex_edge_cache_depth += 1;
    }

    pub fn endFlexEdgePass(self: *LayoutContext) void {
        std.debug.assert(self.flex_edge_cache_depth > 0);
        self.flex_edge_cache_depth -= 1;
        if (self.storage == null and self.flex_edge_cache_depth == 0) {
            self.flexEdgeCache().clearRetainingCapacity();
        }
    }

    pub fn deinit(self: *LayoutContext) void {
        std.debug.assert(self.block_scratch_depth == 0);
        std.debug.assert(self.block_scratch_used_bytes == 0);
        std.debug.assert(self.flex_edge_cache_depth == 0);
        self.flex_measure_cache.deinit(self.allocator);
        self.flex_edge_cache.deinit(self.allocator);
        self.text_measure_cache.deinit(self.allocator);
        if (self.block_scratch_words) |words| self.allocator.free(words);
        self.block_scratch_marks.deinit(self.allocator);
        if (self.grid_cache_words) |words| self.allocator.free(words);
        self.* = undefined;
    }

    /// Acquire the unused suffix of one tree-sized scratch buffer.
    ///
    /// Nested Block measurements partition the same buffer at the current
    /// committed offset. Each live ScratchFloat belongs to one disjoint
    /// subtree, so their combined count cannot exceed the tree node count.
    pub fn acquireBlockScratch(
        self: *LayoutContext,
        comptime T: type,
        tree_item_count: usize,
    ) LayoutError![]T {
        comptime {
            std.debug.assert(@sizeOf(T) > 0);
            std.debug.assert(@alignOf(T) <= @alignOf(u128));
            std.debug.assert(@sizeOf(T) % @alignOf(T) == 0);
        }
        if (tree_item_count == 0) return error.InvalidStyle;
        const byte_limit = try storageByteCount(T, tree_item_count);
        const word_count = try storageWordCount(T, tree_item_count);
        if (self.block_scratch_depth == 0) {
            if (self.block_scratch_words == null or self.block_scratch_words.?.len < word_count) {
                const replacement = try self.allocator.alloc(u128, word_count);
                if (self.block_scratch_words) |words| self.allocator.free(words);
                self.block_scratch_words = replacement;
            }
            self.block_scratch_byte_limit = byte_limit;
            self.block_scratch_item_size = @sizeOf(T);
            self.block_scratch_item_alignment = @alignOf(T);
        } else if (byte_limit != self.block_scratch_byte_limit or
            @sizeOf(T) != self.block_scratch_item_size or
            @alignOf(T) != self.block_scratch_item_alignment)
        {
            return error.InvalidStyle;
        }
        if (self.block_scratch_used_bytes > self.block_scratch_byte_limit) {
            return error.InvalidStyle;
        }
        const mark: ScratchMark = .{ .byte_offset = self.block_scratch_used_bytes };
        if (self.block_scratch_depth == self.block_scratch_marks.items.len) {
            try self.block_scratch_marks.append(self.allocator, mark);
        } else {
            self.block_scratch_marks.items[self.block_scratch_depth] = mark;
        }
        self.block_scratch_depth += 1;

        const byte_pointer: [*]u8 = @ptrCast(self.block_scratch_words.?.ptr);
        const item_pointer: [*]T = @ptrCast(@alignCast(
            byte_pointer + self.block_scratch_used_bytes,
        ));
        const remaining_bytes = self.block_scratch_byte_limit - self.block_scratch_used_bytes;
        return item_pointer[0 .. remaining_bytes / @sizeOf(T)];
    }

    /// Commit the number of items used by the current nested acquisition.
    pub fn setBlockScratchCount(
        self: *LayoutContext,
        comptime T: type,
        count: usize,
    ) LayoutError!void {
        if (self.block_scratch_depth == 0) return error.InvalidStyle;
        if (@sizeOf(T) != self.block_scratch_item_size or
            @alignOf(T) != self.block_scratch_item_alignment)
        {
            return error.InvalidStyle;
        }
        const mark_index = std.math.sub(usize, self.block_scratch_depth, 1) catch
            return error.InvalidStyle;
        if (mark_index >= self.block_scratch_marks.items.len) return error.InvalidStyle;
        const mark = self.block_scratch_marks.items[mark_index];
        const used_bytes = try storageByteCount(T, count);
        const end = std.math.add(usize, mark.byte_offset, used_bytes) catch
            return error.InvalidStyle;
        if (end > self.block_scratch_byte_limit) return error.InvalidStyle;
        self.block_scratch_used_bytes = end;
    }

    pub fn releaseBlockScratch(self: *LayoutContext) void {
        std.debug.assert(self.block_scratch_depth > 0);
        self.block_scratch_depth -= 1;
        const mark = self.block_scratch_marks.items[self.block_scratch_depth];
        self.block_scratch_used_bytes = mark.byte_offset;
        if (self.block_scratch_depth == 0) {
            self.block_scratch_byte_limit = 0;
            self.block_scratch_item_size = 0;
            self.block_scratch_item_alignment = 0;
        }
    }

    pub fn gridCacheStorage(
        self: *LayoutContext,
        comptime T: type,
        count: usize,
    ) LayoutError![]T {
        comptime {
            std.debug.assert(@sizeOf(T) > 0);
            std.debug.assert(@alignOf(T) <= @alignOf(u128));
        }
        if (count == 0) return error.InvalidStyle;
        const word_count = try storageWordCount(T, count);
        if (self.grid_cache_words == null or self.grid_cache_words.?.len < word_count) {
            const replacement = try self.allocator.alloc(u128, word_count);
            if (self.grid_cache_words) |words| self.allocator.free(words);
            self.grid_cache_words = replacement;
            self.grid_cache_initialized_items = 0;
            self.grid_cache_next_replacement = 0;
        }
        const words = self.grid_cache_words orelse return error.InvalidStyle;
        const items: [*]T = @ptrCast(words.ptr);
        return items[0..count];
    }
};

fn storageByteCount(comptime T: type, count: usize) LayoutError!usize {
    return std.math.mul(usize, @sizeOf(T), count) catch |err| switch (err) {
        error.Overflow => error.InvalidStyle,
    };
}

fn storageWordCount(comptime T: type, count: usize) LayoutError!usize {
    const byte_count = try storageByteCount(T, count);
    const rounded = std.math.add(usize, byte_count, scratch_word_bytes - 1) catch
        return error.InvalidStyle;
    return rounded / scratch_word_bytes;
}
