//! Bounded cross-frame shaping for immutable font/style/script configurations.
//! Retained payload is bounded separately from fixed slot bookkeeping and transient runs.

const std = @import("std");
const hb = @import("harfbuzz");
const CounterSink = @import("nogui").CounterSink;

pub const entry_capacity: usize = 256;
pub const byte_capacity: usize = 4 * 1024 * 1024;

const bucket_capacity: usize = entry_capacity * 2;
const SlotIndex = u16;
const no_slot = std.math.maxInt(SlotIndex);
const zero_width_space = "\xE2\x80\x8B";

comptime {
    std.debug.assert(entry_capacity > 0);
    std.debug.assert(entry_capacity < @as(usize, no_slot));
    std.debug.assert(bucket_capacity > entry_capacity);
    std.debug.assert((bucket_capacity & (bucket_capacity - 1)) == 0);
    std.debug.assert(byte_capacity > 0);
}

/// Identifies an immutable font configuration within one Cache lifetime.
/// Layout width belongs in FlowKey, not in glyph shaping identity.
pub const FontKey = struct {
    font_id: u8,
    size: u32,
    content_generation: u64 = 0,
    font_revision: u64 = 0,
    feature_digest: u64 = 0,
    fallback_digest: u64 = 0,
    weight: u16 = 400,
    style: u8 = 0,
    direction: hb.Direction = .ltr,
    paragraph_direction: u8 = 0,
    script: hb.Script = .latin,
};

pub const ShapeOptions = struct {
    direction: hb.Direction = .ltr,
    script: hb.Script = .latin,
    features: []const hb.Feature = &.{},
};

/// Intrinsic widths for one retained shaped text entry.
pub const IntrinsicMetrics = struct {
    min_width: f32,
    max_width: f32,
};

/// Distinguishes the line policy used for a retained flow result.
pub const FlowLinePolicy = enum {
    flow,
    single_line,
};

/// Normalized width and line policy identify one retained flow result.
pub const FlowKey = struct {
    line_policy: FlowLinePolicy,
    normalized_width: f32,
};

/// Width and line count produced by one retained flow measurement.
pub const FlowMetrics = struct {
    width: f32,
    line_count: usize,
};

const flow_slot_capacity: usize = 4;

comptime {
    std.debug.assert(flow_slot_capacity > 0);
    std.debug.assert(flow_slot_capacity <= @as(usize, std.math.maxInt(u8)));
}

const FlowMemo = struct {
    occupied: bool = false,
    key: FlowKey = .{
        .line_policy = .flow,
        .normalized_width = 0,
    },
    metrics: FlowMetrics = .{
        .width = 0,
        .line_count = 0,
    },
};

fn flowKeyEql(left: FlowKey, right: FlowKey) bool {
    if (left.line_policy != right.line_policy) return false;
    return left.normalized_width == right.normalized_width;
}

pub const Glyph = struct {
    gid: u32,
    cluster: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
};

pub const Run = struct {
    text: []const u8,
    glyphs: []const Glyph,
    width: f32,
};

const Entry = struct {
    occupied: bool = false,
    font_key: FontKey = .{ .font_id = 0, .size = 0 },
    hash: u64 = 0,
    text: []const u8 = &.{},
    glyphs: []const Glyph = &.{},
    width: f32 = 0,
    width_matches_prefix: bool = true,
    payload_bytes: usize = 0,
    pin_count: usize = 0,
    intrinsic_metrics: ?IntrinsicMetrics = null,
    flow_memos: [flow_slot_capacity]FlowMemo = [_]FlowMemo{.{}} ** flow_slot_capacity,
    flow_next_slot: u8 = 0,
    bucket_next: SlotIndex = no_slot,
    lru_previous: SlotIndex = no_slot,
    lru_next: SlotIndex = no_slot,
    free_next: SlotIndex = no_slot,
};
const OwnedRun = struct {
    text: []const u8,
    glyphs: []const Glyph,
    width: f32,
    width_matches_prefix: bool,
    payload_bytes: usize,

    fn deinit(self: OwnedRun, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.glyphs);
    }
};
/// Owns a borrow until release, or owns transient data when admission is unavailable.
/// Release exactly once; do not copy a live lease into independent owners.
pub const Lease = struct {
    run: Run,
    ownership: Ownership,

    const Resident = struct {
        cache: *Cache,
        slot: SlotIndex,
    };

    const Ownership = union(enum) {
        resident: Resident,
        uncached: std.mem.Allocator,
    };

    fn initResident(cache: *Cache, slot: SlotIndex) Lease {
        const entry = &cache.entries[slotOffset(slot)];
        std.debug.assert(entry.occupied);
        std.debug.assert(entry.pin_count > 0);
        return .{
            .run = .{
                .text = entry.text,
                .glyphs = entry.glyphs,
                .width = entry.width,
            },
            .ownership = .{ .resident = .{ .cache = cache, .slot = slot } },
        };
    }

    fn initUncached(gpa: std.mem.Allocator, owned: OwnedRun) Lease {
        return .{
            .run = .{
                .text = owned.text,
                .glyphs = owned.glyphs,
                .width = owned.width,
            },
            .ownership = .{ .uncached = gpa },
        };
    }

    pub fn release(self: *Lease) void {
        switch (self.ownership) {
            .resident => |resident| {
                const entry = &resident.cache.entries[slotOffset(resident.slot)];
                std.debug.assert(entry.occupied);
                std.debug.assert(entry.pin_count > 0);
                std.debug.assert(self.run.text.ptr == entry.text.ptr);
                std.debug.assert(self.run.text.len == entry.text.len);
                std.debug.assert(self.run.glyphs.ptr == entry.glyphs.ptr);
                std.debug.assert(self.run.glyphs.len == entry.glyphs.len);

                const pin_count_before = entry.pin_count;
                entry.pin_count = pin_count_before - 1;
                std.debug.assert(entry.pin_count < pin_count_before);
            },
            .uncached => |gpa| {
                gpa.free(self.run.text);
                gpa.free(self.run.glyphs);
            },
        }
        // SAFETY: release consumes the lease; its slices must not be read afterward.
        self.* = undefined;
    }
    /// Returns the shaped width only when it matches prefix accumulation.
    pub fn retainedRunWidth(self: *const Lease) ?f32 {
        const entry = self.residentEntry() orelse return null;
        if (!entry.width_matches_prefix) return null;
        return entry.width;
    }

    /// Returns the retained intrinsic result, or null for a transient lease
    /// or an entry that has not measured its intrinsic widths yet.
    pub fn loadIntrinsicMetrics(self: *const Lease) ?IntrinsicMetrics {
        const entry = self.residentEntry() orelse return null;
        return entry.intrinsic_metrics;
    }

    /// Stores intrinsic widths only while this lease pins a resident entry.
    pub fn storeIntrinsicMetrics(self: *Lease, metrics: IntrinsicMetrics) void {
        const entry = self.residentEntry() orelse return;
        entry.intrinsic_metrics = metrics;
    }

    /// Returns a retained flow result for an exact policy and normalized width.
    pub fn loadFlowMetrics(self: *const Lease, key: FlowKey) ?FlowMetrics {
        const entry = self.residentEntry() orelse return null;
        for (&entry.flow_memos) |*memo| {
            if (memo.occupied and flowKeyEql(memo.key, key)) return memo.metrics;
        }
        return null;
    }

    /// Stores one bounded flow result, replacing the oldest memo slot when full.
    pub fn storeFlowMetrics(self: *Lease, key: FlowKey, metrics: FlowMetrics) void {
        const entry = self.residentEntry() orelse return;
        for (&entry.flow_memos) |*memo| {
            if (memo.occupied and flowKeyEql(memo.key, key)) {
                memo.metrics = metrics;
                return;
            }
        }
        for (&entry.flow_memos) |*memo| {
            if (!memo.occupied) {
                memo.* = .{ .occupied = true, .key = key, .metrics = metrics };
                return;
            }
        }
        const slot: usize = entry.flow_next_slot;
        std.debug.assert(slot < flow_slot_capacity);
        entry.flow_memos[slot] = .{ .occupied = true, .key = key, .metrics = metrics };
        entry.flow_next_slot = @intCast((slot + 1) % flow_slot_capacity);
    }

    fn residentEntry(self: *const Lease) ?*Entry {
        switch (self.ownership) {
            .resident => |resident| {
                const entry = &resident.cache.entries[slotOffset(resident.slot)];
                std.debug.assert(entry.occupied);
                std.debug.assert(entry.pin_count > 0);
                std.debug.assert(self.run.text.ptr == entry.text.ptr);
                std.debug.assert(self.run.text.len == entry.text.len);
                std.debug.assert(self.run.glyphs.ptr == entry.glyphs.ptr);
                std.debug.assert(self.run.glyphs.len == entry.glyphs.len);
                return entry;
            },
            .uncached => return null,
        }
    }
};

/// Single-threaded cache. Its address must remain stable while resident leases are live.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    entries: [entry_capacity]Entry,
    buckets: [bucket_capacity]SlotIndex,
    free_head: SlotIndex,
    lru_head: SlotIndex = no_slot,
    lru_tail: SlotIndex = no_slot,
    resident_count: usize = 0,
    retained_bytes: usize = 0,
    shapes_count: u64 = 0,

    /// Includes transient runs; a cache hit does not increase this count.
    pub fn shapeCount(self: *const Cache) u64 {
        return self.shapes_count;
    }

    pub fn init(gpa: std.mem.Allocator) Cache {
        var cache: Cache = .{
            .gpa = gpa,
            .entries = [_]Entry{.{}} ** entry_capacity,
            .buckets = [_]SlotIndex{no_slot} ** bucket_capacity,
            .free_head = 0,
        };
        for (&cache.entries, 0..) |*entry, index| {
            entry.free_next = if (index + 1 < entry_capacity)
                @intCast(index + 1)
            else
                no_slot;
        }
        std.debug.assert(cache.free_head != no_slot);
        std.debug.assert(cache.lru_head == no_slot);
        std.debug.assert(cache.lru_tail == no_slot);
        return cache;
    }

    pub fn deinit(self: *Cache) void {
        var removed_count: usize = 0;
        while (removed_count < entry_capacity) : (removed_count += 1) {
            if (self.lru_tail == no_slot) break;
            const entry = &self.entries[slotOffset(self.lru_tail)];
            std.debug.assert(entry.occupied);
            std.debug.assert(entry.pin_count == 0);
            self.evict(self.lru_tail);
        }
        std.debug.assert(self.lru_head == no_slot);
        std.debug.assert(self.lru_tail == no_slot);
        std.debug.assert(self.resident_count == 0);
        std.debug.assert(self.retained_bytes == 0);
        for (self.buckets) |bucket| std.debug.assert(bucket == no_slot);
        self.* = undefined;
    }

    /// Cache hits allocate and shape nothing. Admission failure preserves uncached output.
    pub fn acquire(
        self: *Cache,
        font_key: FontKey,
        font: hb.Font,
        text: []const u8,
        sink: *const CounterSink,
    ) !Lease {
        return self.acquireWith(font_key, font, text, .{}, sink);
    }

    /// The caller must bind `font` to the exact revision, size and style in
    /// `font_key`; otherwise two distinct glyph streams could share an entry.
    pub fn acquireWith(
        self: *Cache,
        font_key: FontKey,
        font: hb.Font,
        text: []const u8,
        options: ShapeOptions,
        sink: *const CounterSink,
    ) !Lease {
        std.debug.assert(font_key.direction == options.direction);
        std.debug.assert(font_key.script == options.script);
        const hash = hashKey(font_key, text);
        if (self.lookup(font_key, text, hash)) |slot| {
            const entry = &self.entries[slotOffset(slot)];
            const pin_count_before = entry.pin_count;
            entry.pin_count = std.math.add(usize, pin_count_before, 1) catch
                @panic("text shaping lease count overflow");
            std.debug.assert(entry.pin_count > pin_count_before);
            self.touch(slot);
            return Lease.initResident(self, slot);
        }

        self.shapes_count = std.math.add(u64, self.shapes_count, 1) catch @panic("shape count overflow");
        const owned = try shapeOwned(self.gpa, font, text, options, sink);
        errdefer owned.deinit(self.gpa);

        if (owned.payload_bytes > byte_capacity) {
            return Lease.initUncached(self.gpa, owned);
        }
        if (!self.admissionPossible(owned.payload_bytes)) {
            return Lease.initUncached(self.gpa, owned);
        }

        self.makeRoom(owned.payload_bytes);
        const slot = self.admit(font_key, hash, owned);
        return Lease.initResident(self, slot);
    }

    fn lookup(
        self: *const Cache,
        font_key: FontKey,
        text: []const u8,
        hash: u64,
    ) ?SlotIndex {
        var slot = self.buckets[bucketIndex(hash)];
        var inspected_count: usize = 0;
        while (inspected_count < entry_capacity) : (inspected_count += 1) {
            if (slot == no_slot) return null;
            const entry = &self.entries[slotOffset(slot)];
            std.debug.assert(entry.occupied);
            if (entry.hash == hash) {
                if (fontKeyEql(entry.font_key, font_key)) {
                    if (std.mem.eql(u8, entry.text, text)) return slot;
                }
            }
            slot = entry.bucket_next;
        }
        std.debug.assert(slot == no_slot);
        return null;
    }

    fn admissionPossible(self: *const Cache, payload_bytes: usize) bool {
        std.debug.assert(payload_bytes <= byte_capacity);
        std.debug.assert(self.resident_count <= entry_capacity);
        std.debug.assert(self.retained_bytes <= byte_capacity);
        var count_after = self.resident_count + 1;
        var bytes_after = self.retained_bytes + payload_bytes;
        var cursor = self.lru_tail;
        var inspected_count: usize = 0;
        var eviction_count: usize = 0;

        while (count_after > entry_capacity or bytes_after > byte_capacity) {
            std.debug.assert(eviction_count < entry_capacity);
            const victim = self.nextEvictionCandidate(&cursor, &inspected_count) orelse
                return false;
            const entry = &self.entries[slotOffset(victim)];
            std.debug.assert(count_after > 0);
            std.debug.assert(bytes_after >= entry.payload_bytes);
            count_after -= 1;
            bytes_after -= entry.payload_bytes;
            eviction_count += 1;
        }
        return true;
    }

    fn makeRoom(self: *Cache, payload_bytes: usize) void {
        std.debug.assert(payload_bytes <= byte_capacity);
        var cursor = self.lru_tail;
        var inspected_count: usize = 0;
        var evicted_count: usize = 0;
        while (self.needsRoom(payload_bytes)) {
            std.debug.assert(evicted_count < entry_capacity);
            const victim = self.nextEvictionCandidate(&cursor, &inspected_count) orelse
                unreachable;
            self.evict(victim);
            evicted_count += 1;
        }
        std.debug.assert(self.resident_count < entry_capacity);
        std.debug.assert(self.retained_bytes <= byte_capacity - payload_bytes);
        std.debug.assert(self.free_head != no_slot);
    }

    fn needsRoom(self: *const Cache, payload_bytes: usize) bool {
        std.debug.assert(payload_bytes <= byte_capacity);
        if (self.resident_count >= entry_capacity) return true;
        return self.retained_bytes > byte_capacity - payload_bytes;
    }

    fn nextEvictionCandidate(
        self: *const Cache,
        cursor: *SlotIndex,
        inspected_count: *usize,
    ) ?SlotIndex {
        while (inspected_count.* < entry_capacity) : (inspected_count.* += 1) {
            const slot = cursor.*;
            if (slot == no_slot) return null;
            const entry = &self.entries[slotOffset(slot)];
            std.debug.assert(entry.occupied);
            cursor.* = entry.lru_previous;
            if (entry.pin_count == 0) {
                inspected_count.* += 1;
                return slot;
            }
        }
        return null;
    }

    fn admit(self: *Cache, font_key: FontKey, hash: u64, owned: OwnedRun) SlotIndex {
        std.debug.assert(!self.needsRoom(owned.payload_bytes));
        const slot = self.takeFreeSlot();
        const entry = &self.entries[slotOffset(slot)];
        entry.* = .{
            .occupied = true,
            .font_key = font_key,
            .hash = hash,
            .text = owned.text,
            .glyphs = owned.glyphs,
            .width = owned.width,
            .width_matches_prefix = owned.width_matches_prefix,
            .payload_bytes = owned.payload_bytes,
            .pin_count = 1,
        };
        self.bucketInsert(slot);
        self.lruInsertHead(slot);

        const count_before = self.resident_count;
        const bytes_before = self.retained_bytes;
        self.resident_count = count_before + 1;
        self.retained_bytes = bytes_before + owned.payload_bytes;
        std.debug.assert(self.resident_count > count_before);
        std.debug.assert(self.resident_count <= entry_capacity);
        std.debug.assert(self.retained_bytes >= bytes_before);
        std.debug.assert(self.retained_bytes <= byte_capacity);
        return slot;
    }

    fn evict(self: *Cache, slot: SlotIndex) void {
        const entry = &self.entries[slotOffset(slot)];
        std.debug.assert(entry.occupied);
        std.debug.assert(entry.pin_count == 0);
        std.debug.assert(self.resident_count > 0);
        std.debug.assert(self.retained_bytes >= entry.payload_bytes);

        const text = entry.text;
        const glyphs = entry.glyphs;
        const payload_bytes = entry.payload_bytes;
        self.bucketRemove(slot);
        self.lruRemove(slot);
        self.resident_count -= 1;
        self.retained_bytes -= payload_bytes;

        self.gpa.free(text);
        self.gpa.free(glyphs);
        entry.* = .{ .free_next = self.free_head };
        self.free_head = slot;
        std.debug.assert(!entry.occupied);
        std.debug.assert(entry.pin_count == 0);
    }

    fn takeFreeSlot(self: *Cache) SlotIndex {
        const slot = self.free_head;
        std.debug.assert(slot != no_slot);
        const entry = &self.entries[slotOffset(slot)];
        std.debug.assert(!entry.occupied);
        self.free_head = entry.free_next;
        entry.free_next = no_slot;
        return slot;
    }

    fn bucketInsert(self: *Cache, slot: SlotIndex) void {
        const entry = &self.entries[slotOffset(slot)];
        std.debug.assert(entry.occupied);
        const bucket = &self.buckets[bucketIndex(entry.hash)];
        entry.bucket_next = bucket.*;
        bucket.* = slot;
        const found_slot = self.lookup(entry.font_key, entry.text, entry.hash);
        std.debug.assert(found_slot != null);
        std.debug.assert(found_slot.? == slot);
    }

    fn bucketRemove(self: *Cache, slot: SlotIndex) void {
        const entry = &self.entries[slotOffset(slot)];
        std.debug.assert(entry.occupied);
        var link = &self.buckets[bucketIndex(entry.hash)];
        var inspected_count: usize = 0;
        while (inspected_count < entry_capacity) : (inspected_count += 1) {
            const linked_slot = link.*;
            if (linked_slot == no_slot) break;
            if (linked_slot == slot) {
                link.* = entry.bucket_next;
                entry.bucket_next = no_slot;
                const found_slot = self.lookup(entry.font_key, entry.text, entry.hash);
                std.debug.assert(found_slot == null);
                return;
            }
            const linked_entry = &self.entries[slotOffset(linked_slot)];
            std.debug.assert(linked_entry.occupied);
            link = &linked_entry.bucket_next;
        }
        unreachable;
    }

    fn touch(self: *Cache, slot: SlotIndex) void {
        const entry = &self.entries[slotOffset(slot)];
        std.debug.assert(entry.occupied);
        if (self.lru_head == slot) {
            std.debug.assert(entry.lru_previous == no_slot);
            return;
        }
        self.lruRemove(slot);
        self.lruInsertHead(slot);
        std.debug.assert(self.lru_head == slot);
    }

    fn lruInsertHead(self: *Cache, slot: SlotIndex) void {
        const entry = &self.entries[slotOffset(slot)];
        std.debug.assert(entry.occupied);
        std.debug.assert(entry.lru_previous == no_slot);
        std.debug.assert(entry.lru_next == no_slot);

        entry.lru_next = self.lru_head;
        if (self.lru_head == no_slot) {
            std.debug.assert(self.lru_tail == no_slot);
            self.lru_tail = slot;
        } else {
            self.entries[slotOffset(self.lru_head)].lru_previous = slot;
        }
        self.lru_head = slot;
        std.debug.assert(entry.lru_previous == no_slot);
    }

    fn lruRemove(self: *Cache, slot: SlotIndex) void {
        const entry = &self.entries[slotOffset(slot)];
        std.debug.assert(entry.occupied);
        const previous = entry.lru_previous;
        const next = entry.lru_next;

        if (previous == no_slot) {
            std.debug.assert(self.lru_head == slot);
            self.lru_head = next;
        } else {
            self.entries[slotOffset(previous)].lru_next = next;
        }
        if (next == no_slot) {
            std.debug.assert(self.lru_tail == slot);
            self.lru_tail = previous;
        } else {
            self.entries[slotOffset(next)].lru_previous = previous;
        }
        entry.lru_previous = no_slot;
        entry.lru_next = no_slot;
    }
};

fn shapeOwned(
    gpa: std.mem.Allocator,
    font: hb.Font,
    text: []const u8,
    options: ShapeOptions,
    sink: *const CounterSink,
) !OwnedRun {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    var buffer = try hb.Buffer.create();
    defer buffer.destroy();
    buffer.addUTF8(text);
    buffer.setDirection(options.direction);
    buffer.setScript(options.script);
    sink.add(.harfbuzz_shapes, 1);
    hb.shape(font, buffer, if (options.features.len == 0) null else options.features);

    const infos = buffer.getGlyphInfos();
    const positions = buffer.getGlyphPositions() orelse &.{};
    const glyph_count = @min(infos.len, positions.len);
    const glyph_bytes = std.math.mul(usize, glyph_count, @sizeOf(Glyph)) catch
        return error.OutOfMemory;
    const payload_bytes = std.math.add(usize, text.len, glyph_bytes) catch
        return error.OutOfMemory;

    const glyphs = try gpa.alloc(Glyph, glyph_count);
    errdefer gpa.free(glyphs);
    const owned_text = try gpa.dupe(u8, text);
    var width: f32 = 0;
    var width_matches_prefix = true;
    var previous_cluster: u32 = 0;
    var has_previous_cluster = false;
    for (glyphs, infos[0..glyph_count], positions[0..glyph_count]) |*glyph, info, position| {
        if (@as(usize, @intCast(info.cluster)) >= text.len) {
            width_matches_prefix = false;
        }
        if (has_previous_cluster and info.cluster < previous_cluster) {
            width_matches_prefix = false;
        }
        previous_cluster = info.cluster;
        has_previous_cluster = true;
        const control = textClusterIsControl(text, info.cluster);
        const x_advance = if (control) 0 else fixedToF32(position.x_advance);
        width += x_advance;
        glyph.* = .{
            .gid = if (control) 0 else info.codepoint,
            .cluster = info.cluster,
            .x_advance = x_advance,
            .y_advance = if (control) 0 else fixedToF32(position.y_advance),
            .x_offset = if (control) 0 else fixedToF32(position.x_offset),
            .y_offset = if (control) 0 else fixedToF32(position.y_offset),
        };
    }

    return .{
        .text = owned_text,
        .glyphs = glyphs,
        .width = width,
        .width_matches_prefix = width_matches_prefix,
        .payload_bytes = payload_bytes,
    };
}

fn textClusterIsControl(text: []const u8, cluster: u32) bool {
    const index: usize = @intCast(cluster);
    if (index >= text.len) return false;
    if (text[index] == '\n') return true;
    if (text[index] == '\r') return true;
    return std.mem.startsWith(u8, text[index..], zero_width_space);
}

fn fixedToF32(value: i32) f32 {
    return @floatCast(@as(f64, @floatFromInt(value)) / 64.0);
}

fn hashKey(font_key: FontKey, text: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&font_key.font_id));
    hasher.update(std.mem.asBytes(&font_key.size));
    hasher.update(std.mem.asBytes(&font_key.content_generation));
    hasher.update(std.mem.asBytes(&font_key.font_revision));
    hasher.update(std.mem.asBytes(&font_key.feature_digest));
    hasher.update(std.mem.asBytes(&font_key.fallback_digest));
    hasher.update(std.mem.asBytes(&font_key.weight));
    hasher.update(std.mem.asBytes(&font_key.style));
    const direction: u8 = @intFromEnum(font_key.direction);
    const script: u32 = @intFromEnum(font_key.script);
    hasher.update(std.mem.asBytes(&direction));
    hasher.update(std.mem.asBytes(&font_key.paragraph_direction));
    hasher.update(std.mem.asBytes(&script));
    hasher.update(text);
    return hasher.final();
}

fn fontKeyEql(left: FontKey, right: FontKey) bool {
    return left.font_id == right.font_id and
        left.size == right.size and
        left.content_generation == right.content_generation and
        left.font_revision == right.font_revision and
        left.feature_digest == right.feature_digest and
        left.fallback_digest == right.fallback_digest and
        left.weight == right.weight and
        left.style == right.style and
        left.direction == right.direction and
        left.paragraph_direction == right.paragraph_direction and
        left.script == right.script;
}

fn bucketIndex(hash: u64) usize {
    return @intCast(hash & @as(u64, bucket_capacity - 1));
}

fn slotOffset(slot: SlotIndex) usize {
    std.debug.assert(slot != no_slot);
    return @intCast(slot);
}
