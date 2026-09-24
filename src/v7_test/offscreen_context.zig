//! Optional real-text GPU test context. Module parameters keep GPU/font
//! dependencies out of callers that use only the deterministic core Context.
const std = @import("std");
const nogui = @import("nogui");
const Context = @import("context.zig").Context;

pub fn OffscreenContext(comptime Frame: type, comptime Render: type) type {
    return struct {
        const Self = @This();
        const Scene = Frame.scene;
        const Noapi = Frame.noapi;

        allocator: std.mem.Allocator,
        base: *Context,
        loader: Frame.SystemVulkanLoader,
        target: Frame.Offscreen,
        text: Frame.TextEngine,
        renderer: Render.Renderer,
        scratch: Scene.SceneScratch,
        cmd: Noapi.CommandBuffer = undefined,
        gpu_frame: nogui.GpuFrame = undefined,
        index: u32 = 0,
        recording: bool = false,
        base_live: bool = true,

        pub const Shaders = struct {
            vert: []const u32,
            frag: []const u32,
            sort: []const u32,
        };

        pub const Options = struct {
            io: std.Io,
            extent: Noapi.Extent2D,
            fonts: []const Frame.native.FontSource,
            shaders: Shaders,
            seed: u64 = 0,
            validation: bool = false,
        };

        pub const Rendered = struct {
            /// Same two-arena lifetime as Context's committed FrameOutput.
            /// The caller owns `frame.json` when serialization is enabled.
            frame: nogui.FrameOutput,
            /// Borrowed Oklab RGBA; valid until the next render or teardown.
            pixels: []const f32,
        };

        /// Creates a noapi device and render target, never SDL, a native
        /// window, a platform surface or a swapchain. Shaders are copied by
        /// the renderer; fonts are copied by the shared TextService.
        pub fn create(allocator: std.mem.Allocator, options: Options) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.allocator = allocator;
            self.index = 0;
            self.recording = false;
            self.base_live = true;
            self.loader = try Frame.SystemVulkanLoader.open();
            errdefer self.loader.close();
            self.target = try Frame.Offscreen.init(.{
                .allocator = allocator,
                .io = options.io,
                .loader = self.loader.options(),
                .extent = options.extent,
                .app_name = "nogui-test-offscreen",
                .validation = options.validation,
            });
            errdefer self.target.deinit();
            self.text = try Frame.TextEngine.init(allocator, self.target.gpu(), options.fonts);
            errdefer self.text.deinit();
            try self.text.setGlyphSlotLimit(Scene.glyph_material_ceiling);
            self.renderer = try Render.Renderer.init(
                self.target.gpu(),
                options.shaders.vert,
                options.shaders.frag,
                options.shaders.sort,
            );
            errdefer self.renderer.deinit();
            self.renderer.configure(.{ .material_bda = self.text.materialBda() });
            self.scratch = Scene.SceneScratch.init(allocator, &self.renderer);
            errdefer self.scratch.deinit();
            self.base = try Context.create(allocator, options.seed);
            errdefer self.base.deinit() catch @panic("offscreen test initialization retained core ownership");
            self.base.app.measure = self.text.measurer();
            self.base.app.surface = .{
                .width = @floatFromInt(options.extent.width),
                .height = @floatFromInt(options.extent.height),
            };
            try self.base.app.attachGpu(self.target.endpoint());
            return self;
        }

        /// Build, lower and submit one actual frame through the same layout,
        /// glyph engine and scene recorder used by the graphical host.
        pub fn render(self: *Self) !Rendered {
            if (!self.base_live or !self.base.app_live) return error.ContextClosed;
            const logical = self.base.app.surface;
            if (!std.math.isFinite(logical.width) or !std.math.isFinite(logical.height) or
                logical.width <= 0 or logical.height <= 0) return error.InvalidLogicalExtent;
            const extent = self.target.extent();
            self.text.setPixelScale(.{
                .x = @as(f32, @floatFromInt(extent.width)) / logical.width,
                .y = @as(f32, @floatFromInt(extent.height)) / logical.height,
            });
            try self.target.beginFrame(self.index, &self.cmd, &self.gpu_frame);
            self.recording = true;
            errdefer self.cancelRecording();
            const output = try self.base.flushGpuFrame(&self.gpu_frame);
            errdefer if (output.json) |json| self.allocator.free(json);
            self.scratch.beginFrame();
            var painted = try Scene.buildFrameScene(&self.scratch, &self.text, .{}, &output, false);
            defer painted.deinit();
            const record: Scene.RecordContext = .{
                .arena = output.tree.allocator,
                .renderer = &self.renderer,
                .text = &self.text,
                .logical = .{ .width = logical.width, .height = logical.height },
                .device = extent,
                .texture_heap = self.target.heap().handle,
                .clips = output.tree.clip_rects[0..output.tree.clip_count],
            };
            _ = try Scene.recordFrameScene(
                &record,
                &self.cmd,
                &self.scratch,
                self.scratch.rects.items,
                &painted,
                self.target.target(),
            );
            const pixels = try self.target.submitRead(&self.gpu_frame);
            self.recording = false;
            self.index = (self.index + 1) % @as(u32, self.target.gpu().frames_in_flight);
            return .{ .frame = output, .pixels = pixels };
        }

        fn cancelRecording(self: *Self) void {
            if (!self.recording) return;
            if (self.gpu_frame.recording == .active) {
                self.gpu_frame.cancelRecording() catch @panic("offscreen test recording cancellation failed");
            }
            self.recording = false;
        }

        /// On LiveModels the App has closed; fonts/device stay alive so the
        /// caller can release retained owners and retry, not render again.
        pub fn deinit(self: *Self) !void {
            std.debug.assert(!self.recording);
            if (self.base_live) {
                try self.base.deinit();
                self.base_live = false;
            }
            try self.target.gpu().waitIdle();
            self.scratch.deinit();
            self.renderer.deinit();
            self.text.deinit();
            self.target.deinit();
            self.loader.close();
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
}
