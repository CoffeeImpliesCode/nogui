//! Optional real-font context. Pass the public nogui_text module explicitly;
//! layout-only users keep nogui_test's core-only dependency graph.
const std = @import("std");
const Context = @import("context.zig").Context;

pub fn TextContext(comptime Cpu: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        base: *Context,
        text: Cpu.TextMeasurer,

        pub const Options = struct {
            seed: u64 = 0,
            fonts: []const Cpu.FontSource,
            default_size: f32 = 16,
        };

        /// The context and the measurer stay at stable addresses. Font data is
        /// copied by TextService; caller storage may retire after creation.
        pub fn create(allocator: std.mem.Allocator, options: Options) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.allocator = allocator;
            try self.text.init(allocator, options.fonts, options.default_size);
            errdefer self.text.deinit();
            self.base = try Context.create(allocator, options.seed);
            self.base.app.measure = self.text.source();
            return self;
        }

        /// Release caller-owned layouts/models/tasks first. If core refuses
        /// teardown, its font service remains alive so the caller can repair
        /// ownership and retry; a failed deinit never invalidates live leases.
        pub fn deinit(self: *Self) !void {
            try self.base.deinit();
            self.text.deinit();
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
}
