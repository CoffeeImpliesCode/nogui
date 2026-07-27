//! Thread pool — fixed-size worker pool for background task execution.
//!
//! Architecture:
//!   1. Main thread submits BgTask via submitTask() → pushed to work queue.
//!   2. Idle workers pop from the work queue (spinlock-guarded SLL).
//!   3. Each worker executes the task, produces a Completion.
//!   4. Worker pushes Completion to the externally-owned CompletionQueue.
//!   5. Main thread drains CompletionQueue at frame start.
//!
//! Worker lifecycle:
//!   - Workers are spawned at init() and join()'d at deinit().
//!   - Workers spin-wait with nanosleep backoff when the queue is empty.
//!   - The shutdown flag tells workers to exit.
//!
//! PROTOTYPE — simple spinlock-based queue, no work-stealing.

const std = @import("std");
const builtin = @import("builtin");
const Thread = std.Thread;
const BgTask = @import("bg_task.zig").BgTask;
const executeTask = @import("bg_task.zig").executeTask;
const CompletionQueue = @import("comp_queue.zig").CompletionQueue;
const Spinlock = @import("comp_queue.zig").Spinlock;

/// Default number of worker threads.
/// Set to logical CPU count minus 1 (reserve one for the main thread).
pub const DEFAULT_WORKER_COUNT: u32 = @max(1, if (builtin.cpu.count > 1) builtin.cpu.count - 1 else 1);

/// Active-poll spin count before falling back to nanosleep.
const SPIN_LIMIT = 100_000;

/// A work item wrapping a BgTask with intrusive list node.
const WorkItem = struct {
    task: BgTask,
    node: std.SinglyLinkedList.Node = .{},

    fn fromNode(n: *std.SinglyLinkedList.Node) *WorkItem {
        return @fieldParentPtr("node", n);
    }
};

/// Fixed-size thread pool that executes BgTask items.
pub const ThreadPool = struct {
    /// Queue of pending work (BgTask items).
    work_lock: Spinlock = .{},
    work_list: std.SinglyLinkedList = .{},

    /// Reference to the completion queue for pushing results.
    completion_queue: *CompletionQueue,

    /// Worker thread handles.
    workers: []Thread,

    /// Allocator for worker array and WorkItem nodes.
    allocator: std.mem.Allocator,

    /// Atomic flag: workers check this each iteration.
    shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Number of active workers.
    worker_count: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        completion_queue: *CompletionQueue,
        worker_count: ?u32,
    ) !*ThreadPool {
        const count = worker_count orelse DEFAULT_WORKER_COUNT;
        const workers = try allocator.alloc(Thread, count);
        errdefer allocator.free(workers);

        const pool = try allocator.create(ThreadPool);
        errdefer allocator.destroy(pool);
        pool.* = .{
            .completion_queue = completion_queue,
            .workers = workers,
            .allocator = allocator,
            .worker_count = count,
        };

        // Spawn workers. `pool` is heap-allocated so the pointer passed
        // to each worker stays valid after init returns.
        for (workers, 0..) |*worker, i| {
            worker.* = Thread.spawn(.{}, workerFn, .{pool, @as(u32, @intCast(i))}) catch |err| {
                // Join already-spawned workers, then let the errdefers free
                // `workers` and `pool` on the return — freeing them here
                // too would double-free.
                for (workers[0..i]) |w| w.join();
                return err;
            };
        }

        return pool;
    }

    pub fn deinit(self: *ThreadPool) void {
        // Signal shutdown and wake all workers.
        self.shutdown_flag.store(true, .release);

        // Wait for all workers to finish.
        for (self.workers) |worker| {
            worker.join();
        }
        self.allocator.free(self.workers);

        // Free any queued but unprocessed work. The lock is released
        // BEFORE destroy(self): a deferred unlock would dereference the
        // freed pool.
        self.work_lock.lock();
        while (self.work_list.popFirst()) |node| {
            const item = WorkItem.fromNode(node);
            // No heap allocs inside BgTask variants right now,
            // but in the future we may need to free path strings etc.
            self.allocator.destroy(item);
        }
        self.work_lock.unlock();
        self.allocator.destroy(self);
    }

    /// Submit a background task for execution.
    /// The task is wrapped in a heap-allocated WorkItem and pushed
    /// to the work queue. Workers pick it up on the next iteration.
    pub fn submitTask(self: *ThreadPool, task: BgTask) !void {
        const item = try self.allocator.create(WorkItem);
        item.* = .{ .task = task };

        self.work_lock.lock();
        defer self.work_lock.unlock();
        self.work_list.prepend(&item.node);
    }

    /// Attempt to pop a work item from the queue.
    /// Returns null if empty.
    fn tryPopWork(self: *ThreadPool) ?*WorkItem {
        self.work_lock.lock();
        defer self.work_lock.unlock();
        const node = self.work_list.popFirst() orelse return null;
        return WorkItem.fromNode(node);
    }

    /// Worker entry point.
    /// Loops: pop work → execute → push completion → check shutdown.
    fn workerFn(pool: *ThreadPool, worker_id: u32) void {
        _ = worker_id;
        var spin_count: u64 = 0;

        while (true) {
            // Check shutdown.
            if (pool.shutdown_flag.load(.acquire)) return;

            // Try to pop work.
            const item = pool.tryPopWork() orelse {
                // No work available — back off.
                spin_count += 1;
                if (spin_count >= SPIN_LIMIT) {
                    spin_count = 0;
                    // Sleep 1ms to reduce CPU usage.
                    std.time.sleep(1_000_000);
                } else {
                    std.atomic.spinLoopHint();
                }
                continue;
            };
            spin_count = 0;

            // Execute the task.
            const result = executeTask(&item.task, pool.allocator) catch |err| {
                // On allocation failure, log and skip.
                std.debug.print("thread_pool: task execution failed: {}\n", .{err});
                pool.allocator.destroy(item);
                continue;
            };

            // Push result to completion queue.
            if (result) |completion| {
                pool.completion_queue.push(completion) catch |err| {
                    std.debug.print("thread_pool: failed to push completion: {}\n", .{err});
                };
            }

            // Free the work item (task data already consumed).
            pool.allocator.destroy(item);
        }
    }
};
