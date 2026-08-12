//! Background task types — the "Command" in the Command pattern.
//!
//! A BgTask describes a unit of background work that can be executed
//! by the thread pool. The worker thread executes it and pushes a
//! Completion to the CompletionQueue.
//!
//! Small results (≤128 bytes) use the inline Completion.data buffer.
//! Larger results are heap-allocated by the worker and freed by the
//! component's onComplete handler.
//!
//! To add a new task type:
//!   1. Add a variant to the BgTask union
//!   2. Implement the execute function for it
//!   3. Define the Completion struct for the result
//!
//! PROTOTYPE — may be replaced by a generative comptime interface.

const std = @import("std");
const CompletionQueue = @import("comp_queue.zig").CompletionQueue;
const Completion = @import("comp_queue.zig").Completion;
const Spinlock = @import("comp_queue.zig").Spinlock;

/// A background task to be executed by the thread pool.
///
/// Each variant describes WHAT to do. The worker thread reads the
/// variant, executes, and writes the result into a Completion value
/// pushed to the CompletionQueue.
pub const BgTask = union(enum) {
    /// Load a font file from disk and produce a FontData result.
    /// component_id is embedded in the task so the worker can
    /// write it directly into the Completion.
    load_font: struct {
        /// Absolute or relative path to the font file.
        path: []const u8,
        /// Font pixel size to load at.
        pixel_size: u32,
        /// Component to route the result to.
        component_id: u32,
        /// Tag for this specific command (for components that
        /// issue multiple load_font commands).
        tag: u32,
    },

    /// Load an image file from disk.
    load_image: struct {
        path: []const u8,
        component_id: u32,
        tag: u32,
    },

    /// Read a file from disk into a heap-allocated buffer.
    read_file: struct {
        path: []const u8,
        component_id: u32,
        tag: u32,
    },

    /// Placeholder / no-op (for idle workers).
    none: void,
};

/// Results produced by background tasks.
/// These are packed into the Completion.data field (≤128 bytes).
/// Result of loading a font.
pub const LoadFontResult = packed struct(u64) {
    /// Number of glyphs loaded.
    glyph_count: u32,
    /// Font pixel size.
    pixel_size: u32,
};

/// Result of loading an image (metadata only; pixel data is heap-allocated).
pub const LoadImageResult = struct {
    width: u32,
    height: u32,
    channels: u32,
    /// Heap-allocated pixel data (RGBA). Must be freed by onComplete.
    pixels: ?[]u8,
};

/// Result of reading a file.
pub const ReadFileResult = struct {
    /// Heap-allocated file contents. Must be freed by onComplete.
    data: ?[]u8,
};

/// Tag values for built-in task types.
/// Components can add their own by starting at USER_TAG_BASE.
pub const TaskTag = enum(u32) {
    load_font = 1,
    load_image = 2,
    read_file = 3,
    user_base = 256,
};

/// Execute a background task and write the result into a Completion.
/// Returns the Completion, or null if the task was .none.
/// The caller (worker thread) owns the returned Completion and must
/// push it to the CompletionQueue.
pub fn executeTask(task: *const BgTask, allocator: std.mem.Allocator) !?Completion {
    return switch (task.*) {
        .load_font => |lt| blk: {
            // Simulated font loading. In production, this would call
            // FreeType to load the font, extract curves, etc.
            // The result data is produced as a small inline value.
            var comp = Completion{
                .component_id = lt.component_id,
                .tag = lt.tag,
                .data_len = 0,
                .data = undefined,
            };
            // For now, produce a stub result that would carry metadata.
            const result = LoadFontResult{
                .glyph_count = 95, // ASCII printable
                .pixel_size = lt.pixel_size,
            };
            comp.pack(lt.component_id, lt.tag, result);
            // In a real loading scenario, the worker would also allocate
            // GPU curve buffers and push them via the completion queue or
            // a separate GPU upload queue.
            //
            // For large results (GPU curve data), the worker would:
            //   1. Allocate a heap buffer with the loaded data
            //   2. Store the pointer + size in Completion.data
            //   3. The component's onComplete frees it after copying to GPU
            break :blk comp;
        },
        .load_image => |li| blk: {
            // Simulated image loading.
            const result = try allocator.create(LoadImageResult);
            result.* = .{
                .width = 0,
                .height = 0,
                .channels = 0,
                .pixels = null,
            };
            // In production: stb_image or similar to load + decode.
            var comp = Completion{
                .component_id = li.component_id,
                .tag = li.tag,
                .data_len = @sizeOf(*LoadImageResult),
                .data = undefined,
            };
            @memcpy(comp.data[0..@sizeOf(*LoadImageResult)], std.mem.asBytes(&result));
            break :blk comp;
        },
        .read_file => |rf| blk: {
            const data = try std.fs.cwd().readFileAlloc(allocator, rf.path, 1024 * 1024 * 16);
            const result = try allocator.create(ReadFileResult);
            result.* = .{ .data = data };
            var comp = Completion{
                .component_id = rf.component_id,
                .tag = rf.tag,
                .data_len = @sizeOf(*ReadFileResult),
                .data = undefined,
            };
            @memcpy(comp.data[0..@sizeOf(*ReadFileResult)], std.mem.asBytes(&result));
            break :blk comp;
        },
        .none => null,
    };
}
