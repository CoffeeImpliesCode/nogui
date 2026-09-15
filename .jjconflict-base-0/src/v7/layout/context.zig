const std = @import("std");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

pub const TextLinePolicy = enum {
    flow,
    single_line,
};

pub const MeasureInput = struct {
    /// Constraints use physical width and height; callbacks map logical axes.
    known_dimensions: sizing.OptionalSize,
    available_space: sizing.AvailableSize,
    font_size: f32,
    /// Opaque callback selector; layout assigns no writing-mode semantics.
    font_id: u8,
    line_policy: TextLinePolicy = .flow,
};

pub const MeasureFn = *const fn (text: []const u8, input: MeasureInput) widget.Size;

pub fn measureContent(
    measure: ?MeasureFn,
    text: []const u8,
    input: MeasureInput,
) widget.Size {
    var result: widget.Size = if (measure) |callback|
        callback(text, input)
    else fallback: {
        const scale: f32 = if (input.font_size > 0) input.font_size / 20 else 1;
        const length: f32 = @floatFromInt(text.len);
        break :fallback .{
            .width = length * 10 * scale,
            .height = 20 * scale,
        };
    };
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
    measured: widget.Size,
    text_overflow: widget.TextOverflow,
    maximum_width: ?f32,
) widget.Size {
    var result = measured;
    if (text_overflow != .visible) {
        if (maximum_width) |value| result.width = @min(result.width, value);
    }
    return result;
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

pub fn measureText(
    measure: ?MeasureFn,
    text: []const u8,
    input: MeasureInput,
    text_overflow: widget.TextOverflow,
    text_max_width: ?f32,
) LayoutError!widget.Size {
    const normalized = try normalizeTextInput(input, text_overflow, text_max_width);
    const measured = measureContent(measure, text, normalized.input);
    return applyTextOverflow(measured, text_overflow, normalized.maximum_width);
}

pub fn measureSliderContent(
    measure: ?MeasureFn,
    node: *const widget.WidgetNode,
    input: MeasureInput,
) LayoutError!widget.Size {
    const text = widget.sliderVisualLabel(node.kind);
    const result = if (text.len == 0)
        widget.Size{ .width = 100, .height = widget.slider_rail_height }
    else
        try measureText(measure, text, input, node.text_overflow, node.text_max_width);
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
        const tags = [_]u8{
            @intFromBool(percentage_width.present),
            @intFromBool(percentage_height.present),
            @intFromBool(known_border_width.present),
            @intFromBool(known_border_height.present),
            @intCast(@intFromEnum(request.width_mode)),
            @intCast(@intFromEnum(request.height_mode)),
            @intCast(@intFromEnum(request.sizing_mode)),
            if (parent_display) |display|
                @as(u8, @intCast(@intFromEnum(display) + 1))
            else
                0,
        };
        // An odd multiplier spreads node indices without rehashing shared constraints.
        const node_hash = @as(u64, @intCast(node_index)) *% 0x9E37_79B9_7F4A_7C15;
        return .{
            .node_index = node_index,
            .float_bits = float_bits,
            .tags = @bitCast(tags),
            .hash_code = requestHash(&float_bits, &tags) ^ node_hash,
        };
    }

    fn requestHash(float_bits: *const [6]u32, tags: *const [8]u8) u64 {
        const float_bytes = @sizeOf([6]u32);
        var bytes: [float_bytes + @sizeOf([8]u8)]u8 = undefined;
        @memcpy(bytes[0..float_bytes], std.mem.asBytes(float_bits));
        @memcpy(bytes[float_bytes..], tags);
        return std.hash.Wyhash.hash(0, &bytes);
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

/// Exact callback inputs for one layout pass. Node content and the callback
/// stay fixed until the pass ends; LayoutStorage clears entries between passes.
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
        value: widget.Size,
        valid: bool = false,
    };

    const NodeSlots = struct {
        entries: [slots_per_node]Entry,
        next_replacement: usize = 0,
    };

    nodes: std.ArrayListUnmanaged(NodeSlots) = .empty,

    pub fn key(node_index: usize, input: MeasureInput) Key {
        const known_width = optionalFloatKey(input.known_dimensions.width);
        const known_height = optionalFloatKey(input.known_dimensions.height);
        const available_width = availableSpaceKey(input.available_space.width);
        const available_height = availableSpaceKey(input.available_space.height);
        const tags = @as(u32, @intFromBool(known_width.present)) |
            (@as(u32, @intFromBool(known_height.present)) << 1) |
            (@as(u32, available_width.tag) << 2) |
            (@as(u32, available_height.tag) << 4) |
            (@as(u32, input.font_id) << 8) |
            (@as(u32, @intFromEnum(input.line_policy)) << 16);
        return .{
            .node_index = node_index,
            // Tag-first words compare without padding or copying resident keys.
            .input_bits = .{
                tags,
                known_width.bits,
                known_height.bits,
                available_width.bits,
                available_height.bits,
                @as(u32, @bitCast(input.font_size)),
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

    pub fn lookup(self: *const TextMeasurementCache, cache_key: Key) ?widget.Size {
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

    /// Insert after a miss; repeated keys never reach the replacement path.
    pub fn insert(
        self: *TextMeasurementCache,
        allocator: std.mem.Allocator,
        cache_key: Key,
        measured: widget.Size,
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
    measure: ?MeasureFn,
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

    pub fn measureTextCached(
        self: *LayoutContext,
        node_index: usize,
        text: []const u8,
        input: MeasureInput,
        text_overflow: widget.TextOverflow,
        text_max_width: ?f32,
    ) LayoutError!widget.Size {
        const normalized = try normalizeTextInput(input, text_overflow, text_max_width);
        const cache = self.textMeasurementCache();
        const cache_key = TextMeasurementCache.key(node_index, normalized.input);
        const measured = cache.lookup(cache_key) orelse blk: {
            const result = measureContent(self.measure, text, normalized.input);
            try cache.insert(self.textMeasurementAllocator(), cache_key, result);
            break :blk result;
        };
        return applyTextOverflow(measured, text_overflow, normalized.maximum_width);
    }

    pub fn measureSliderContentCached(
        self: *LayoutContext,
        node_index: usize,
        node: *const widget.WidgetNode,
        input: MeasureInput,
    ) LayoutError!widget.Size {
        const text = widget.sliderVisualLabel(node.kind);
        const result = if (text.len == 0)
            widget.Size{ .width = 100, .height = widget.slider_rail_height }
        else
            try self.measureTextCached(
                node_index,
                text,
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
