const std = @import("std");
const sizing = @import("sizing.zig");
const style = @import("../style.zig");
const widget = @import("../widget.zig");

pub const TextLinePolicy = enum {
    flow,
    single_line,
};

pub const MeasureInput = struct {
    known_dimensions: sizing.OptionalSize,
    available_space: sizing.AvailableSize,
    font_size: f32,
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

/// Measure text with the shared overflow line policy.
pub fn measureText(
    measure: ?MeasureFn,
    text: []const u8,
    input: MeasureInput,
    text_overflow: widget.TextOverflow,
    text_max_width: ?f32,
) LayoutError!widget.Size {
    const maximum = if (text_max_width) |value| blk: {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStyle;
        break :blk value;
    } else null;
    var text_input = input;
    const single_line = switch (text_overflow) {
        .visible => false,
        .clip => maximum != null,
        .ellipsis => true,
    };
    if (single_line) {
        text_input.available_space.width = .max_content;
        text_input.line_policy = .single_line;
    }
    var result = measureContent(measure, text, text_input);
    if (text_overflow != .visible) {
        if (maximum) |value| result.width = @min(result.width, value);
    }
    return result;
}
pub const LayoutError = sizing.Error;

pub fn measureSliderContent(
    measure: ?MeasureFn,
    node: *const widget.WidgetNode,
    input: MeasureInput,
) LayoutError!widget.Size {
    const text = widget.sliderVisualLabel(node.kind);
    var result = if (text.len == 0)
        widget.Size{ .width = 100, .height = widget.slider_rail_height }
    else
        try measureText(measure, text, input, node.text_overflow, node.text_max_width);

    if (input.known_dimensions.width) |width| {
        result.width = width;
    } else {
        result.width = @max(100, result.width);
    }
    if (input.known_dimensions.height) |height| {
        result.height = height;
    } else {
        result.height = @max(widget.slider_rail_height, result.height);
    }
    return result;
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

    pub const Key = struct {
        node_index: usize,
        available_width: u32,
        available_height: u32,
        percentage_width: OptionalFloatKey,
        percentage_height: OptionalFloatKey,
        width_mode: MeasureMode,
        height_mode: MeasureMode,
        sizing_mode: SizingMode,
        known_border_width: OptionalFloatKey,
        known_border_height: OptionalFloatKey,
        parent_display: u8,
    };

    map: std.AutoHashMapUnmanaged(Key, Measured) = .empty,

    pub fn key(
        node_index: usize,
        request: Request,
        parent_display: ?style.Display,
    ) Key {
        return .{
            .node_index = node_index,
            .available_width = @as(u32, @bitCast(request.available.width)),
            .available_height = @as(u32, @bitCast(request.available.height)),
            .percentage_width = optionalFloatKey(request.percentage_basis.width),
            .percentage_height = optionalFloatKey(request.percentage_basis.height),
            .width_mode = request.width_mode,
            .height_mode = request.height_mode,
            .sizing_mode = request.sizing_mode,
            .known_border_width = optionalFloatKey(request.known_border.width),
            .known_border_height = optionalFloatKey(request.known_border.height),
            .parent_display = if (parent_display) |display|
                @as(u8, @intCast(@intFromEnum(display) + 1))
            else
                0,
        };
    }

    pub fn lookup(self: *const MeasurementCache, cache_key: Key) ?Measured {
        return self.map.get(cache_key);
    }

    pub fn insert(
        self: *MeasurementCache,
        allocator: std.mem.Allocator,
        cache_key: Key,
        measured: Measured,
    ) LayoutError!void {
        try self.map.put(allocator, cache_key, measured);
    }

    pub fn deinit(self: *MeasurementCache, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.* = undefined;
    }
};

fn optionalFloatKey(value: ?f32) MeasurementCache.OptionalFloatKey {
    return if (value) |number|
        .{ .present = true, .bits = @as(u32, @bitCast(number)) }
    else
        .{ .present = false };
}

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
    flex_measure_cache: MeasurementCache = .{},
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
    pub fn deinit(self: *LayoutContext) void {
        std.debug.assert(self.block_scratch_depth == 0);
        std.debug.assert(self.block_scratch_used_bytes == 0);
        self.flex_measure_cache.deinit(self.allocator);
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
