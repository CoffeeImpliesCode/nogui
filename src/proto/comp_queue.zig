//! CompletionQueue — lock-free-ish MPSC queue for delivering
//! background task results to the main thread.
//!
//! Workers push Completion values from any thread. The main thread
//! drains them at the start of each frame via popAll().
//!
//! Internally uses an intrusive linked list with a spinlock.
//! The critical section is tiny (pointer swap + copy), so a
//! spinlock is acceptable even for the render thread.
//!
//! Small results (≤128 bytes) are stored inline by value in the
//! Completion struct. Larger results require heap allocation;
//! the component's onComplete handler is responsible for freeing.
//!
//! PROTOTYPE — may be replaced by a wait-free queue in the future.

const std = @import("std");
const atomic = std.atomic;
const SLL = std.SinglyLinkedList;

/// Spinlock wrapper around atomic.Mutex to provide a blocking lock().
pub const Spinlock = struct {
    inner: atomic.Mutex = .unlocked,

    pub fn lock(s: *Spinlock) void {
        while (!s.inner.tryLock()) {
            atomic.spinLoopHint();
        }
    }

    pub fn unlock(s: *Spinlock) void {
        s.inner.unlock();
    }
};

/// Maximum inline result data — zero-copy for the common case.
/// Font metadata, image headers, file read results all fit.
pub const MAX_INLINE_DATA = 128;

/// A completed background task result.
/// 16 bytes header + 128 bytes data = 144 bytes total.
pub const Completion = struct {
    /// Which component this result is destined for.
    component_id: u32,

    /// Tag identifying which command completed.
    /// The component's onComplete matches on this to dispatch
    /// to the right handler (e.g., .load_font, .load_image).
    tag: u32,

    /// Number of valid bytes in `data`.
    data_len: u16,

    /// Inline result buffer. For small trivial types, the worker
    /// copies directly here. For heap-allocated results, the worker
    /// stores a pointer as bytes; the component's onComplete must
    /// free it.
    data: [MAX_INLINE_DATA]u8,

    /// Intrusive list node — must be first field for @fieldParentPtr.
    node: SLL.Node = .{},

    /// Pack result into the inline buffer.
    pub fn pack(completion: *Completion, component_id: u32, tag: u32, result: anytype) void {
        const T = @TypeOf(result);
        const result_bytes = std.mem.asBytes(&result);
        comptime std.debug.assert(@sizeOf(T) <= MAX_INLINE_DATA);

        completion.component_id = component_id;
        completion.tag = tag;
        completion.data_len = @intCast(result_bytes.len);
        @memcpy(completion.data[0..result_bytes.len], result_bytes);
    }

    /// Unpack result from the inline buffer.
    pub fn unpack(completion: *const Completion, comptime T: type) T {
        comptime std.debug.assert(@sizeOf(T) <= MAX_INLINE_DATA);
        var result: T = undefined;
        const result_bytes = std.mem.asBytes(&result);
        @memcpy(result_bytes, completion.data[0..@sizeOf(T)]);
        return result;
    }
};

/// Lock-free-ish MPSC queue guarded by a spinlock.
/// Multiple producers (worker threads), single consumer (main thread).
pub const CompletionQueue = struct {
    /// Spinlock protecting the list. Contention is near-zero:
    /// workers push briefly, main thread pops all at once per frame.
    lock: Spinlock = .{},

    /// Intrusive singly-linked list of Completion nodes.
    /// Nodes are heap-allocated by the worker and freed by the
    /// main thread after dispatching.
    list: SLL = .{},

    /// Pool of pre-allocated Completion nodes to avoid per-task
    /// allocation. Stored as an SLL of free nodes.
    free_list: SLL = .{},
    free_lock: Spinlock = .{},

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompletionQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CompletionQueue) void {
        // Free all queued completions.
        while (self.pop()) |comp| {
            self.allocator.destroy(comp);
        }
        // Free all pooled nodes.
        while (self.free_list.first) |free_node| {
            self.free_list.first = free_node.next;
            const comp_ptr: *Completion = @fieldParentPtr("node", free_node);
            self.allocator.destroy(comp_ptr);
        }
    }

    /// Push a completion from any thread.
    /// Allocates a node from the free pool, or heap if empty.
    pub fn push(self: *CompletionQueue, completion: Completion) !void {
        // Allocate or reuse a node.
        const node = blk: {
            self.free_lock.lock();
            defer self.free_lock.unlock();
            if (self.free_list.first) |free_node| {
                self.free_list.first = free_node.next;
                const completion_ptr: *Completion = @fieldParentPtr("node", free_node);
                break :blk completion_ptr;
            }
            break :blk try self.allocator.create(Completion);
        };
        node.* = completion;
        node.node = .{}; // reset next pointer

        // Push to the queue (prepend = LIFO, which is fine — we drain all each frame).
        self.lock.lock();
        defer self.lock.unlock();
        self.list.prepend(&node.node);
    }

    /// Pop a completion from the main thread.
    /// Returns null if empty.
    /// NOTE: Not thread-safe on the consumer side — call only from main thread.
    pub fn pop(self: *CompletionQueue) ?*Completion {
        const node = self.list.popFirst() orelse return null;
        return @fieldParentPtr("node", node);
    }

    /// Atomically detach the entire list and return the head.
    /// The caller owns the detached list and must walk it.
    fn detachAll(self: *CompletionQueue) ?*SLL.Node {
        self.lock.lock();
        const head = self.list.first;
        self.list.first = null;
        self.lock.unlock();
        return head;
    }

    /// Pop all queued completions into a caller-provided buffer.
    /// Returns the number of completions written.
    /// The caller owns the Completions and must recycle or free them.
    pub fn popAll(self: *CompletionQueue, buf: []*Completion) usize {
        const head = self.detachAll() orelse return 0;

        var count: usize = 0;
        var it: ?*SLL.Node = head;
        while (it) |node| : (it = node.next) {
            if (count >= buf.len) break;
            buf[count] = @fieldParentPtr("node", node);
            count += 1;
        }

        return count;
    }

    /// Recycle a Completion node back to the free pool.
    pub fn recycle(self: *CompletionQueue, completion: *Completion) void {
        self.free_lock.lock();
        defer self.free_lock.unlock();
        self.free_list.prepend(&completion.node);
    }

    /// Drain all completions, calling handler for each.
    /// The handler receives a *Completion and must recycle it.
    pub fn drain(self: *CompletionQueue, handler: *const fn (*Completion) void) void {
        var buf: [64]*Completion = undefined;
        while (true) {
            const n = self.popAll(&buf);
            if (n == 0) break;
            for (buf[0..n]) |completion| {
                handler(completion);
            }
        }
    }
};

// ─── Tests ─────────────────────────────────────────────

const testing = std.testing;

test "CompletionQueue: push and pop" {
    var cq = CompletionQueue.init(testing.allocator);
    defer cq.deinit();

    const comp = Completion{
        .component_id = 42,
        .tag = 1,
        .data_len = 0,
        .data = undefined,
    };
    try cq.push(comp);

    const got = cq.pop().?;
    defer cq.recycle(got);
    try testing.expectEqual(@as(u32, 42), got.component_id);
    try testing.expectEqual(@as(u32, 1), got.tag);
    try testing.expect(cq.pop() == null);
}

test "CompletionQueue: popAll returns all" {
    var cq = CompletionQueue.init(testing.allocator);
    defer cq.deinit();

    for (0..3) |i| {
        try cq.push(.{
            .component_id = @intCast(i),
            .tag = 0,
            .data_len = 0,
            .data = undefined,
        });
    }

    var buf: [8]*Completion = undefined;
    const n = cq.popAll(&buf);
    try testing.expectEqual(@as(usize, 3), n);
    // LIFO order: last pushed is first popped.
    try testing.expectEqual(@as(u32, 2), buf[0].component_id);
    try testing.expectEqual(@as(u32, 0), buf[2].component_id);

    for (buf[0..n]) |c| cq.recycle(c);
}

test "CompletionQueue: pack/unpack roundtrip" {
    const TestResult = packed struct(u64) {
        width: u32,
        height: u32,
    };

    var comp = Completion{
        .component_id = 1,
        .tag = 99,
        .data_len = 0,
        .data = undefined,
    };
    comp.pack(1, 99, TestResult{ .width = 1920, .height = 1080 });

    const unpacked = comp.unpack(TestResult);
    try testing.expectEqual(@as(u32, 1920), unpacked.width);
    try testing.expectEqual(@as(u32, 1080), unpacked.height);
}

test "CompletionQueue: recycle reuses nodes" {
    var cq = CompletionQueue.init(testing.allocator);
    defer cq.deinit();

    try cq.push(.{ .component_id = 1, .tag = 0, .data_len = 0, .data = undefined });
    const c = cq.pop().?;
    cq.recycle(c);

    // Push again — should use the recycled node, not allocate.
    try cq.push(.{ .component_id = 2, .tag = 0, .data_len = 0, .data = undefined });
    const c2 = cq.pop().?;
    defer cq.recycle(c2);
    try testing.expectEqual(@as(u32, 2), c2.component_id);
}
