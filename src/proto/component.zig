//! Component trait and registry.
//!
//! Components are long-lived stateful objects that own widget state
//! across frames. They participate in the async command lifecycle:
//!
//!   1. During draw(), component calls ctx.submitBgTask(LoadFont{...})
//!      to enqueue background work.
//!   2. Thread pool worker loads the font asynchronously.
//!   3. Worker pushes a Completion to the CompletionQueue with the
//!      component's ID and the loaded font data.
//!   4. At the start of the next frame, App drains the CompletionQueue
//!      and calls component.onComplete() for each result.
//!   5. The component updates its state (e.g., font_loaded = true).
//!   6. Next frame's draw() reads the updated state.
//!
//! The component ID is the index into the registry's components array.
//! This gives O(1) lookup during completion dispatch.
//!
//! PROTOTYPE — may be replaced by a generative interface in the future.

const std = @import("std");
const Completion = @import("comp_queue.zig").Completion;
const CompletionQueue = @import("comp_queue.zig").CompletionQueue;

/// Maximum number of registered components.
pub const max_components = 256;

/// Tags for the Completion.tag field — identifies which bg task completed.
/// Components can extend this with their own tag space (tags >= USER_TAG_BASE).
pub const CompletionTag = enum(u32) {
    /// Placeholder / uninitialized.
    unused = 0,

    /// LoadFont task completed.
    load_font = 1,

    /// LoadImage task completed.
    load_image = 2,

    /// ReadFile task completed.
    read_file = 3,

    /// First tag available for application-defined tasks.
    user_base = 256,
};

/// Component virtual method table.
/// Every component must provide these.
pub const ComponentVTable = struct {
    /// Called when a background task completes.
    /// The component should interpret the Completion data, update
    /// its state, and free any heap-allocated result memory.
    ///
    /// The completion node is owned by the caller and will be recycled
    /// after this call. If the component needs the data beyond this
    /// callback, it must copy it.
    onComplete: *const fn (ptr: *anyopaque, completion: *const Completion) void,

    /// Called during gcStates: if the component hasn't been touched
    /// in `max_age` frames, it may be deinitialised to reclaim memory.
    /// Return true to allow eviction.
    isExpired: *const fn (ptr: *anyopaque, last_frame: u64, current_frame: u64) bool,

    /// Clean up component resources.
    deinit: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,
};

/// Opaque component handle wrapping a vtable + pointer.
pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const ComponentVTable,

    pub fn onComplete(self: Component, completion: *const Completion) void {
        self.vtable.onComplete(self.ptr, completion);
    }

    pub fn isExpired(self: Component, last_frame: u64, current_frame: u64) bool {
        return self.vtable.isExpired(self.ptr, last_frame, current_frame);
    }

    pub fn deinit(self: Component, allocator: std.mem.Allocator) void {
        self.vtable.deinit(allocator, self.ptr);
    }
};

/// Result of registering a component.
pub const ComponentRef = struct {
    /// Component ID — used in Completion.component_id to route results.
    id: u32,
    /// Borrowed reference to the component.
    component: Component,
};

/// Registry of all active components.
/// Provides O(1) lookup by component_id for completion dispatch.
pub const ComponentRegistry = struct {
    /// Flat array of component slots. A slot is active when .ptr != null.
    slots: [max_components]?Component = .{null} ** max_components,

    /// Last-frame-touched timestamp for GC.
    last_frame: [max_components]u64 = .{0} ** max_components,

    pub fn init() ComponentRegistry {
        return .{};
    }

    /// Register a new component. Returns the component ID.
    /// Fails with error.OutOfMemory if all slots are occupied.
    pub fn register(self: *ComponentRegistry, component: Component, current_frame: u64) !u32 {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = component;
                self.last_frame[i] = current_frame;
                return @intCast(i);
            }
        }
        return error.OutOfMemory;
    }

    /// Unregister a component by ID. Does NOT call deinit — the caller
    /// must deinit first if needed.
    pub fn unregister(self: *ComponentRegistry, id: u32) void {
        if (id < max_components) {
            self.slots[id] = null;
        }
    }

    /// Look up a component by ID.
    /// Returns null if the slot is empty or out of range.
    pub fn get(self: *const ComponentRegistry, id: u32) ?Component {
        if (id >= max_components) return null;
        return self.slots[id];
    }

    /// Touch a component to mark it as active this frame.
    pub fn touch(self: *ComponentRegistry, id: u32, frame: u64) void {
        if (id < max_components) {
            self.last_frame[id] = frame;
        }
    }

    /// Look up a component and touch it (atomic in semantics, not in execution).
    pub fn getAndTouch(self: *ComponentRegistry, id: u32, frame: u64) ?Component {
        const comp = self.get(id) orelse return null;
        self.touch(id, frame);
        return comp;
    }

    /// Handle a completion by routing it to the correct component's onComplete.
    /// Called from the main thread during the frame loop's drain phase.
    pub fn dispatchCompletion(self: *ComponentRegistry, completion: *const Completion, current_frame: u64) void {
        const component = self.getAndTouch(completion.component_id, current_frame) orelse return;
        component.onComplete(completion);
    }

    /// GC stale components that haven't been touched in `max_age` frames.
    pub fn gc(self: *ComponentRegistry, allocator: std.mem.Allocator, current_frame: u64, max_age: u64) void {
        for (&self.slots, 0..) |*slot, i| {
            const comp = slot.* orelse continue;
            if (current_frame - self.last_frame[i] > max_age) {
                if (comp.isExpired(self.last_frame[i], current_frame)) {
                    comp.deinit(allocator);
                    slot.* = null;
                }
            }
        }
    }
};

// ─── Tests ─────────────────────────────────

const testing = std.testing;

test "ComponentRegistry: register and lookup" {
    var registry = ComponentRegistry.init();

    // A minimal test component.
    const TestComp = struct {
        fn onComplete(_: *anyopaque, _: *const Completion) void {}
        fn isExpired(_: *anyopaque, _: u64, _: u64) bool {
            return true;
        }
        fn deinit(_: std.mem.Allocator, ptr: *anyopaque) void {
            ptr.* = undefined;
        }

        const vtable: ComponentVTable = .{
            .onComplete = onComplete,
            .isExpired = isExpired,
            .deinit = deinit,
        };
    };

    var test_comp: TestComp = .{};
    const component: Component = .{
        .ptr = &test_comp,
        .vtable = &TestComp.vtable,
    };

    const id = try registry.register(component, 0);
    try testing.expectEqual(@as(u32, 0), id); // first slot
    try testing.expect(registry.get(id) != null);
    try testing.expect(registry.get(999) == null); // out of range
}

test "ComponentRegistry: unregister frees slot" {
    var registry = ComponentRegistry.init();

    const TestComp = struct {
        fn onComplete(_: *anyopaque, _: *const Completion) void {}
        fn isExpired(_: *anyopaque, _: u64, _: u64) bool {
            return true;
        }
        fn deinit(_: std.mem.Allocator, ptr: *anyopaque) void {
            ptr.* = undefined;
        }
        const vtable: ComponentVTable = .{
            .onComplete = onComplete,
            .isExpired = isExpired,
            .deinit = deinit,
        };
    };

    var comp: TestComp = .{};
    const id = try registry.register(.{ .ptr = &comp, .vtable = &TestComp.vtable }, 0);
    registry.unregister(id);
    try testing.expect(registry.get(id) == null);
}
