//! The bindless texture heap: set 0 = registered textures, set 2 = one
//! shared linear/clamp sampler at index 0, plus the handle -> index map the
//! scene rects sample through.
//!
//! MOVED verbatim from `src/v7_demo/window.zig` (the demo's `TextureRegistry`),
//! renamed `BindlessHeap` because `TextureRegistry` is also the core's vtable
//! name (`nogui.TextureRegistry`). The `heap` field is `handle`; the two
//! component-storage entry points are public so a host can bridge them into
//! the core vtable through `runtimeRegistry`.
//!
//! The noapi descriptor heap is created once with capacity hints only; the
//! backend forces the pool to the device maximum regardless. The frame binds
//! the heap with ONE `bindDescriptorSets` before the renderer draw — bindings
//! are not draws, so the one-draw invariant holds. The fragment shader samples
//! `textures[NonUniformResourceIndex(tex_idx)]` (set 0 binding 0) with
//! `samplers[0]` (set 2 binding 0); `descHeapSetTextures` writes each
//! registration's image-view descriptor at its index.
//!
//! Index lifetime: a released index is reusable, but only once the frames
//! that sampled its descriptor have retired. `release` and `unregister`
//! PARK the index instead of returning it, and the next registration asks
//! the device (`gpu.waitIdle`) whether those frames are done. Until it says
//! yes the newcomer draws a fresh index, so no in-flight frame can ever read
//! the newcomer's texture through a released index. See
//! `ExternalTextureSlots` for the accounting and its proofs.

const std = @import("std");
const noapi = @import("noapi");
const nogui = @import("nogui");

/// Slot allocation shared by map-owned and component-owned textures.
/// Indices freed by external component textures are reusable by any
/// subsequent registration, including ordinary map-owned textures — but
/// NEVER while a frame that could still sample them is in flight. A frame
/// samples `textures[index]` through the descriptor this heap wrote, so
/// handing the index to a newcomer before the frames that named it retire
/// repaints those frames with the newcomer's image. A released index
/// therefore parks in `retiring_indices`, out of the free list, until the
/// device reports idle; a newcomer draws a fresh index until then.
pub const ExternalTextureSlots = struct {
    pub const Self = ExternalTextureSlots;

    next_idx: u32 = 0,
    reusable_indices: std.ArrayListUnmanaged(u32) = .empty,
    /// Indices whose in-flight frames have not been proven retired. Nothing
    /// here may reach a newcomer until `promoteRetiring` moves it across.
    retiring_indices: std.ArrayListUnmanaged(u32) = .empty,
    live_indices: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.reusable_indices.deinit(gpa);
        self.retiring_indices.deinit(gpa);
        self.live_indices.deinit(gpa);
        self.* = undefined;
    }

    /// True while a released index is still waiting on the device. The heap
    /// reads this to skip the idle wait when there is nothing to retire.
    fn hasRetiring(self: *const Self) bool {
        return self.retiring_indices.items.len != 0;
    }

    /// `gpu_idle` is the device's own report that no submitted frame can
    /// still sample a released index. It is the ONLY thing that promotes a
    /// retiring slot into the free list, so a missing report can only cost a
    /// fresh index — never a descriptor an in-flight frame still reads.
    fn promoteRetiring(self: *Self, gpa: std.mem.Allocator, gpu_idle: bool) void {
        if (!gpu_idle or self.retiring_indices.items.len == 0) return;
        self.reusable_indices.appendSlice(gpa, self.retiring_indices.items) catch
            @panic("external texture slot free-list allocation failed");
        self.retiring_indices.clearRetainingCapacity();
    }

    fn take(self: *Self, gpa: std.mem.Allocator, gpu_idle: bool) u32 {
        self.promoteRetiring(gpa, gpu_idle);
        if (self.reusable_indices.pop()) |idx| return idx;
        const idx = self.next_idx;
        self.next_idx += 1;
        return idx;
    }

    fn restore(self: *Self, gpa: std.mem.Allocator, idx: u32) void {
        self.retiring_indices.append(gpa, idx) catch
            @panic("external texture slot retirement-list allocation failed");
    }

    fn register(self: *Self, gpa: std.mem.Allocator, gpu_idle: bool) !u32 {
        const idx = self.take(gpa, gpu_idle);
        errdefer self.restore(gpa, idx);
        try self.live_indices.put(gpa, idx, {});
        return idx;
    }

    fn unregister(self: *Self, gpa: std.mem.Allocator, idx: u32) bool {
        if (self.live_indices.fetchRemove(idx) == null) return false;
        self.restore(gpa, idx);
        return true;
    }
};

/// The GUI bindless texture heap plus the app's handle -> heap-index map.
/// Published so a host-side image or SVG view can register its own textures
/// through the same heap instead of opening a second one.
pub const BindlessHeap = struct {
    pub const Self = BindlessHeap;

    gpu: *noapi.Gpu,
    gpa: std.mem.Allocator,
    /// The noapi descriptor heap the frame binds before the renderer draw.
    handle: noapi.DescriptorHeap,
    /// Global descriptor slot allocation. External ownership is tracked
    /// separately by `external_slots`; map entries remain heap-owned.
    external_slots: ExternalTextureSlots = .{},
    /// The app's texture handle -> heap index.
    map: std.AutoHashMapUnmanaged(noapi.TextureHandle, u32) = .empty,
    /// The storage-image table has one active slot for the compute component.
    storage_owner: ?u32 = null,

    pub fn init(gpa: std.mem.Allocator, gpu: *noapi.Gpu) !Self {
        const heap = try gpu.descHeapCreate(16, 0, 1);
        errdefer gpu.descHeapDestroy(heap);
        const sampler = gpu.samplerDescriptor(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mip_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        gpu.descHeapSetSamplers(heap, 0, &.{sampler});
        return .{ .gpu = gpu, .gpa = gpa, .handle = heap };
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        // Map-owned textures remain heap-owned. Component textures release
        // their slots and free themselves during deinitGpu; unused descriptor
        // entries need no null write before the heap is destroyed.
        var it = self.map.keyIterator();
        while (it.next()) |h| self.gpu.textureDestroy(h.*);
        self.map.deinit(gpa);
        self.external_slots.deinit(gpa);
        self.gpu.descHeapDestroy(self.handle);
        self.* = undefined;
    }

    /// Register a texture: write its view descriptor into the heap at a
    /// stable index (returned) — descHeapSetTextures, once per texture.
    /// Idempotent: a handle already registered returns its index.
    pub fn register(self: *Self, gpa: std.mem.Allocator, tex: noapi.TextureHandle) !u32 {
        if (self.map.get(tex)) |idx| return idx;
        const idx = self.takeSlot(gpa);
        errdefer self.external_slots.restore(gpa, idx);
        const desc = self.gpu.textureViewDescriptor(tex, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.handle, idx, &.{desc});
        try self.map.put(gpa, tex, idx);
        return idx;
    }

    /// The device's answer to "may a released index be handed out again?".
    /// True when nothing is parked; otherwise it is `gpu.waitIdle`, which
    /// retires every submitted frame — the only proof available that no
    /// in-flight frame still samples a retired descriptor. A failed wait
    /// answers NO: parked indices stay parked and the newcomer draws a fresh
    /// one, so a broken wait costs a slot, never a wrong pixel.
    fn gpuIdleForReuse(self: *Self) bool {
        if (!self.external_slots.hasRetiring()) return true;
        self.gpu.waitIdle() catch return false;
        return true;
    }

    fn takeSlot(self: *Self, gpa: std.mem.Allocator) u32 {
        return self.external_slots.take(gpa, self.gpuIdleForReuse());
    }

    /// Retire a map-owned texture's slot. The index stops being a candidate
    /// for a newcomer the moment this returns: the frames that sampled its
    /// descriptor may still be in flight, so the slot parks in the retirement
    /// list until the device reports idle. The caller still destroys the
    /// handle in the same breath; the backend defers the image, and the
    /// descriptor keeps naming a live view until this index is reused.
    pub fn release(self: *Self, gpa: std.mem.Allocator, tex: noapi.TextureHandle) void {
        const entry = self.map.fetchRemove(tex) orelse return;
        self.external_slots.restore(gpa, entry.value);
    }

    /// Register a component-owned storage texture outside the destruction map.
    /// unregisterExternal retires its slot; registration overwrites its views.
    pub fn registerExternal(self: *Self, tex: noapi.TextureHandle) !u32 {
        const idx = try self.external_slots.register(self.gpa, self.gpuIdleForReuse());
        const desc = self.gpu.textureViewDescriptor(tex, .{ .format = .default });
        self.gpu.descHeapSetTextures(self.handle, idx, &.{desc});
        const rw_desc = self.gpu.textureRwViewDescriptor(tex, .{ .format = .default });
        self.gpu.descHeapSetTexturesRw(self.handle, idx, &.{rw_desc});
        self.gpu.descHeapSetTexturesRw(self.handle, 0, &.{rw_desc});
        self.storage_owner = idx;
        return idx;
    }

    /// Unregister a component-owned texture. The live-index set makes this
    /// idempotent, so a repeated deinit cannot reuse a slot twice.
    pub fn unregisterExternal(self: *Self, idx: u32) void {
        if (!self.external_slots.unregister(self.gpa, idx)) return;
        if (self.storage_owner) |owner| {
            if (owner == idx) {
                self.storage_owner = null;
            }
        }
    }

    /// The core vtable a `nogui.GpuEndpoint` publishes. The returned struct
    /// borrows `self`; the caller owns the storage and keeps it alive for the
    /// whole endpoint lifetime.
    pub fn runtimeRegistry(self: *Self) nogui.TextureRegistry {
        return .{
            .ptr = self,
            .register = registerRuntimeTexture,
            .unregister = unregisterRuntimeTexture,
        };
    }
};

fn registerRuntimeTexture(ptr: *anyopaque, texture: noapi.TextureHandle) anyerror!u32 {
    const heap: *BindlessHeap = @ptrCast(@alignCast(ptr));
    return heap.registerExternal(texture);
}

fn unregisterRuntimeTexture(ptr: *anyopaque, index: u32) void {
    const heap: *BindlessHeap = @ptrCast(@alignCast(ptr));
    heap.unregisterExternal(index);
}

test "TextureRegistry: external slots reuse released indices once the frames retire" {
    var slots: ExternalTextureSlots = .{};
    defer slots.deinit(std.testing.allocator);

    const first = try slots.register(std.testing.allocator, true);
    const second = try slots.register(std.testing.allocator, true);
    try std.testing.expectEqual(@as(u32, 0), first);
    try std.testing.expectEqual(@as(u32, 1), second);
    try std.testing.expect(slots.unregister(std.testing.allocator, first));

    const reused = try slots.register(std.testing.allocator, true);
    try std.testing.expectEqual(first, reused);
}

test "TextureRegistry: double external unregister is idempotent" {
    var slots: ExternalTextureSlots = .{};
    defer slots.deinit(std.testing.allocator);

    const index = try slots.register(std.testing.allocator, true);
    try std.testing.expect(slots.unregister(std.testing.allocator, index));
    try std.testing.expect(!slots.unregister(std.testing.allocator, index));

    const reused = try slots.register(std.testing.allocator, true);
    try std.testing.expectEqual(index, reused);
    const next = try slots.register(std.testing.allocator, true);
    try std.testing.expectEqual(index + 1, next);
}

test "TextureRegistry: a released index is not reused while a frame can still sample it" {
    // The invariant under test is the ORDER, and only the real slot functions
    // decide it: `unregister` releases while a frame is in flight (the next
    // registration reports the device is NOT idle), so the newcomer must draw
    // a FRESH index rather than the parked one. Only the following
    // registration, which reports those frames retired, may hand the parked
    // index over.
    var slots: ExternalTextureSlots = .{};
    defer slots.deinit(std.testing.allocator);

    const first = try slots.register(std.testing.allocator, true);
    const second = try slots.register(std.testing.allocator, true);
    try std.testing.expectEqual(@as(u32, 0), first);
    try std.testing.expectEqual(@as(u32, 1), second);

    try std.testing.expect(slots.unregister(std.testing.allocator, first));
    try std.testing.expect(slots.hasRetiring());

    // A frame that sampled textures[first] is still in flight: the newcomer
    // must get its own index, never the one those frames read through.
    const blocked = try slots.register(std.testing.allocator, false);
    try std.testing.expect(blocked != first);
    try std.testing.expectEqual(@as(u32, 2), blocked);

    // Same answer while the device keeps reporting frames in flight.
    const still_blocked = try slots.register(std.testing.allocator, false);
    try std.testing.expect(still_blocked != first);
    try std.testing.expectEqual(@as(u32, 3), still_blocked);

    // Those frames retired, so the parked index is the one handed out now.
    const reused = try slots.register(std.testing.allocator, true);
    try std.testing.expectEqual(first, reused);
    try std.testing.expect(!slots.hasRetiring());
}

test "TextureRegistry: a failed retirement parks the index until a later idle" {
    // A wait that cannot prove retirement must not be read as permission. The
    // parked index is still withheld, and a LATER successful wait — not the
    // failed one — is what releases it.
    var slots: ExternalTextureSlots = .{};
    defer slots.deinit(std.testing.allocator);

    const first = try slots.register(std.testing.allocator, true);
    try std.testing.expect(slots.unregister(std.testing.allocator, first));

    const blocked = try slots.register(std.testing.allocator, false);
    try std.testing.expect(blocked != first);
    try std.testing.expect(slots.hasRetiring());

    const reused = try slots.register(std.testing.allocator, true);
    try std.testing.expectEqual(first, reused);
}
