//! nogui App Framework — minimal application shell.
//!
//! Provides: App, ServiceRegistry, Plugin, WindowManager, AppContext, Command.
//! 7 types total. Zero bloat. User never touches SDL directly.
//!
//! ## Usage
//!
//! ```zig
//! const MyApp = struct {
//!     fn draw(ctx: *AppContext, dc: *DrawCtx) !*Widget {
//!         _ = ctx;
//!         return dc.tempLabel("Hello", .{});
//!     }
//! };
//!
//! pub fn main(init: std.process.Init) !void {
//!     const io = init.io;
//!     const gpa = init.gpa;
//!
//!     var app = try App.init(.{
//!         .io = io,
//!         .gpa = gpa,
//!         .title = "nogui",
//!         .width = 800,
//!         .height = 600,
//!         .on_frame = null,
//!         .on_event = null,
//!         .on_shutdown = null,
//!     });
//!     defer app.deinit();
//!
//!     // Register a service
//!     var my_service = MyService{ .x = 42 };
//!     app.services().set(&my_service);
//!
//!     // Register a plugin
//!     try app.install(&my_plugin);
//!
//!     try app.run(MyApp);
//! }
//! ```

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;

// ─── ServiceRegistry ───────────────────────────────────────────────

/// Type-indexed singleton map. Keyed by type name hash.
/// Each service type can be registered at most once.
/// Services live for the App's lifetime — the registry does NOT own
/// the storage; the user provides pointers.
///
/// ```zig
/// var font = FontEngine.init();
/// app.services().set(&font);
/// // ... elsewhere:
/// const ft: *FontEngine = app.services().get(FontEngine) orelse @panic("no font engine");
/// ```
pub const ServiceRegistry = struct {
    entries: std.AutoHashMapUnmanaged(u64, *anyopaque) = .{},

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    fn typeKey(comptime T: type) u64 {
        return std.hash.Crc64.hash(@typeName(T));
    }

    /// Register a service. Replaces any existing entry of the same type.
    /// `service` must be a pointer (`*T`). Keyed by `T`.
    pub fn set(self: *@This(), allocator: std.mem.Allocator, service: anytype) !void {
        const info = @typeInfo(@TypeOf(service));
        const base_type = switch (info) {
            .pointer => |ptr_info| ptr_info.child,
            else => @compileError("ServiceRegistry.set: expected pointer, got " ++ @typeName(@TypeOf(service))),
        };
        const mut_ptr = switch (info) {
            .pointer => |ptr_info| switch (ptr_info.size) {
                .one => @as(*anyopaque, @ptrCast(@constCast(service))),
                else => @compileError("ServiceRegistry.set: expected single pointer"),
            },
            else => unreachable,
        };
        try self.entries.put(allocator, comptime typeKey(base_type), mut_ptr);
    }

    /// Retrieve a service by type. Returns null if not registered.
    pub fn get(self: *@This(), comptime T: type) ?*T {
        const entry = self.entries.get(comptime typeKey(T)) orelse return null;
        return @ptrCast(@alignCast(entry));
    }

    /// Check if a service type is registered.
    pub fn has(self: *@This(), comptime T: type) bool {
        return self.entries.contains(comptime typeKey(T));
    }

    /// Remove a service.
    pub fn remove(self: *@This(), comptime T: type) void {
        _ = self.entries.remove(comptime typeKey(T));
    }

    /// Remove all entries (does NOT deallocate services — they are externally owned).
    pub fn clear(self: *@This()) void {
        self.entries.clearRetainingCapacity();
    }
};

// ─── Plugin ─────────────────────────────────────────────────────────

/// A plugin registers services and injects behavior at lifecycle points.
/// Uses function-pointer vtable for interface dispatch — no trait system needed.
///
/// ```zig
/// const FontPlugin = struct {
///     engine: FontEngine,
///
///     fn onStart(ctx: *AppContext, ptr: *anyopaque) !void {
///         const self: *FontPlugin = @ptrCast(@alignCast(ptr));
///         try ctx.services().set(FontEngine, &self.engine);
///     }
///
///     fn onShutdown(ctx: *AppContext, ptr: *anyopaque) void {
///         const self: *FontPlugin = @ptrCast(@alignCast(ptr));
///         self.engine.deinit();
///     }
///
///     fn deinit(ptr: *anyopaque) void {
///         _ = ptr;
///     }
/// };
/// ```
pub const Plugin = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called during App.start(), after SDL init, before the main loop.
        /// Plugins register services here.
        on_start: *const fn (ctx: *AppContext, plugin: *anyopaque) anyerror!void,

        /// Called during App.deinit(), after the main loop exits.
        /// Plugins clean up here.
        on_shutdown: *const fn (ctx: *AppContext, plugin: *anyopaque) void,

        /// Called during App.deinit() to free plugin resources.
        /// May be null if cleanup is handled in on_shutdown.
        deinit: ?*const fn (plugin: *anyopaque) void = null,
    };

    pub fn onStart(self: *const @This(), ctx: *AppContext) !void {
        try self.vtable.on_start(ctx, self.ptr);
    }

    pub fn onShutdown(self: *const @This(), ctx: *AppContext) void {
        self.vtable.on_shutdown(ctx, self.ptr);
    }

    pub fn deinit(self: *const @This()) void {
        if (self.vtable.deinit) |cb| cb(self.ptr);
    }
};

// ─── FrameData ──────────────────────────────────────────────────────

/// Per-frame render data produced by the main thread, consumed by
/// the window's render thread.
///
/// The main thread builds the widget tree, runs layout, and collects
/// RenderCommands. The result is published as FrameData.
/// The render thread picks it up, uploads GPU resources, records
/// command buffers, and submits to the queue.
///
/// Triple-buffered: main thread writes slot N, render thread reads
/// slot N-1. No blocking on either side (atomic ownership swap).
pub const FrameData = struct {
    /// Surface size at the time this frame was collected.
    surface_width: u32 = 0,
    surface_height: u32 = 0,

    /// Render commands collected from widget tree.
    /// Arena-allocated (frame arena), valid until the next frame.
    commands: []const u8 = &.{},

    /// Material buffer CPU copy (for glyph/material upload).
    material_data: []const u8 = &.{},

    /// Frame counter for diagnostics.
    frame_number: u64 = 0,
};

// ─── WindowHandle ──────────────────────────────────────────────────

/// Opaque handle to a window. Returned by WindowManager.create().
/// Identified by SDL_WindowID for event routing.
///
/// Each window gets its own render thread. The main thread produces
/// FrameData; the render thread consumes it and drives the GPU.
pub const WindowHandle = struct {
    sdl_window: sdl3.video.Window,
    sdl_win_id: u32,
    gpu_window: ?noapi.Surface = null,
    should_close: bool = false,
    userdata: ?*anyopaque = null,

    // ── Render thread ────────────────────────────────
    render_thread: ?std.Thread = null,

    /// Signal to wake the render thread when new frame data is ready.
    frame_ready: std.Thread.Notification = .{},

    /// Signal to tell the render thread to shut down.
    shutdown_requested: bool = false,

    // ── Triple-buffered frame data ───────────────────
    /// Index of the slot the main thread writes to.
    write_slot: u2 = 0,
    /// Index of the slot the render thread reads from.
    read_slot: u2 = 1,
    /// Index of the free slot (neither writing nor reading).
    free_slot: u2 = 2,
    /// Frame data buffers.
    frame_slots: [3]FrameData = .{ .{}, .{}, .{} },

    pub fn renderThreadMain(handle: *WindowHandle) void {
        _ = handle;
        // TODO: render thread loop
        // while (!handle.shutdown_requested) {
        //     handle.frame_ready.wait();
        //     // swap read slot
        //     // upload GPU resources
        //     // record and submit command buffer
        // }
    }
};

// ─── WindowManager ─────────────────────────────────────────────────

/// Manages window lifecycle and event routing.
/// Each window has an SDL window, optional GPU surface, and its own
/// render thread. The main thread never touches GPU — it produces
/// FrameData and signals the render thread.
pub const WindowManager = struct {
    windows: std.ArrayListUnmanaged(*WindowHandle) = .{},
    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        // Windows are externally owned and destroyed.
        self.windows.deinit(self.allocator);
    }

    /// Create a new window. Returns a handle.
    /// `gpu` may be null for headless windows.
    /// Spawns a dedicated render thread for this window.
    pub fn create(self: *@This(), title: [:0]const u8, width: u32, height: u32, gpu: ?*noapi.Gpu) !*WindowHandle {
        const sdl_win = try sdl3.video.Window.init(title, width, height, .{ .resizable = true });
        try sdl_win.show();
        const win_id = try sdl_win.getId();

        var gpu_window: ?noapi.Surface = null;
        if (gpu) |g| {
            var sdl_vk_surface = try sdl3.vulkan.Surface.init(
                sdl_win,
                @ptrFromInt(@intFromEnum(g.instanceHandle())),
                null,
            );
            const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_vk_surface.surface));
            sdl_vk_surface.surface = null;
            gpu_window = try noapi.Surface.init(g, surface, .{ .extent = .{ .width = width, .height = height } });
        }

        const handle = try self.allocator.create(WindowHandle);
        handle.* = .{
            .sdl_window = sdl_win,
            .sdl_win_id = win_id,
            .gpu_window = gpu_window,
        };

        // Spawn render thread
        handle.render_thread = try std.Thread.spawn(.{}, WindowHandle.renderThreadMain, .{handle});

        try self.windows.append(self.allocator, handle);
        return handle;
    }

    /// Destroy a window and remove it from the manager.
    /// Joins the render thread before destroying GPU resources.
    pub fn destroy(self: *@This(), handle: *WindowHandle, gpu: ?*noapi.Gpu) void {
        // Signal render thread to stop
        handle.shutdown_requested = true;
        handle.frame_ready.set();

        // Join render thread
        if (handle.render_thread) |thread| {
            thread.join();
        }

        // Destroy GPU surface (render thread is done with it)
        if (handle.gpu_window) |*gw| {
            if (gpu) |g| {
                gw.deinit();
                _ = g;
            }
        }
        handle.sdl_window.deinit();

        // Remove from list
        for (self.windows.items, 0..) |win, i| {
            if (win == handle) {
                _ = self.windows.swapRemove(i);
                break;
            }
        }
        self.allocator.destroy(handle);
    }

    /// Route an SDL event to the correct window.  Returns the window
    /// whose ID matches, or null if no match.
    pub fn routeEvent(self: *@This(), sdl_win_id: u32) ?*WindowHandle {
        for (self.windows.items) |win| {
            if (win.sdl_win_id == sdl_win_id) return win;
        }
        return null;
    }

    /// Number of open windows.
    pub fn count(self: *@This()) usize {
        return self.windows.items.len;
    }

    /// Iterate all windows.
    pub fn iter(self: *@This()) std.SliceIterator(*WindowHandle) {
        return .{ .items = self.windows.items };
    }

    /// Publish frame data for a window. Called by the main thread
    /// after building the widget tree and collecting render commands.
    /// Non-blocking: writes to the current write slot, then signals
    /// the render thread.
    pub fn publishFrame(_: *@This(), _: *WindowHandle) void {
        // TODO: atomic triple-buffer swap + signal
        // handle.write_slot → mark as readable
        // advance write_slot to free_slot
        // handle.frame_ready.set()
    }
};

// ─── Command ────────────────────────────────────────────────────────

/// A deferred async operation. When the command completes, it produces
/// an Event that is delivered to the component tree on the next frame.
///
/// Commands run via std.Io stackful coroutines — no OS threads needed.
/// The runtime polls all active commands between frames.
///
/// ```zig
/// const cmd = Command.from(struct {
///     fn run(io: std.Io) !Event {
///         const data = try io.file.readAll(...);
///         return .{ .custom = .{ .id = 42, .data = @intFromPtr(data.ptr) } };
///     }
/// }.run);
/// app.submitCommand(cmd);
/// ```
pub const Command = struct {
    /// The function that executes the async work.
    /// Runs on a std.Io stackful coroutine. Produces exactly one Event
    /// when complete (may be a no-op event).
    run_fn: *const fn (io: std.Io, userdata: ?*anyopaque) anyerror!Event,

    /// Opaque data passed to run_fn.
    userdata: ?*anyopaque = null,

    /// Allocator with the same lifetime as the command. May be null if
    /// userdata is stack-allocated or global.
    allocator: ?std.mem.Allocator = null,

    /// Create a command from a bare function.
    pub fn from(comptime run_fn: anytype) @This() {
        const T = @TypeOf(run_fn);
        return switch (@typeInfo(T)) {
            .@"fn" => .{
                .run_fn = @ptrCast(&run_fn),
            },
            else => @compileError("Command.from: expected a function, got " ++ @typeName(T)),
        };
    }

    /// Create a command with a closure-like userdata payload.
    pub fn withData(comptime run_fn: anytype, data: anytype) @This() {
        const T = @TypeOf(data);
        const ptr = if (@sizeOf(T) > 0)
            // Heap-allocate a copy to pass as userdata.
            @panic("Command.withData: heap allocation not yet implemented, use pointer")
        else
            null;
        return .{
            .run_fn = @ptrCast(&run_fn),
            .userdata = ptr,
        };
    }

    /// Convenience: a no-op command (fires immediately with event).
    pub fn immediate(event: Event) @This() {
        return .{
            .run_fn = struct {
                fn run(_: std.Io, _: ?*anyopaque) anyerror!Event {
                    return event;
                }
            }.run,
        };
    }
};

// ─── Hooks ─────────────────────────────────────────────────────────

/// Lifecycle hooks. Part of AppConfig. All optional.
pub const Hooks = struct {
    /// Called once per frame, BEFORE the component tree is built.
    /// Use this for global per-frame updates (poll sensors, etc.).
    on_frame: ?*const fn (ctx: *AppContext) void = null,

    /// Global event filter. Called for every SDL event BEFORE it is
    /// dispatched to the widget tree. Return true to consume the event
    /// (preventing widget-level dispatch).
    on_event: ?*const fn (ctx: *AppContext, ev: *const Event) bool = null,

    /// Called once during App.deinit(), after the main loop exits.
    /// Plugins are notified first, then this hook fires.
    on_shutdown: ?*const fn (ctx: *AppContext) void = null,
};

// ─── AppContext ────────────────────────────────────────────────────

/// Lightweight context reference passed to plugins, commands, and hooks.
/// Provides access to App services without exposing the full App.
pub const AppContext = struct {
    services: *ServiceRegistry,
    window_manager: *WindowManager,
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Submit an async command. The runtime will execute it and deliver
    /// the resulting Event to the widget tree on the next frame.
    pub fn submitCommand(_: *@This(), _: Command) !void {
        // TODO: wire into App's command queue
        @compileError("commands not yet wired into main loop");
    }
};

// ─── Event (re-export for Command) ─────────────────────────────────

/// Minimal event type for the app framework.
/// Re-uses the existing proto event model.
pub const Event = @import("proto/event.zig").Event;

// ─── AppConfig ─────────────────────────────────────────────────────

/// Configuration for App initialization.
pub const AppConfig = struct {
    // ── Required ────────────────────────────────────
    io: std.Io,
    gpa: std.mem.Allocator,

    // ── Window defaults ─────────────────────────────
    title: [:0]const u8 = "nogui",
    width: u32 = 800,
    height: u32 = 600,

    // ── GPU ─────────────────────────────────────────
    /// Set to null to run in headless mode (no rendering).
    gpu_options: ?GpuOptions = null,

    // ── Threading ───────────────────────────────────
    thread_pool_size: u32 = 0, // 0 = no thread pool

    // ── Lifecycle hooks ─────────────────────────────
    hooks: Hooks = .{},

    // ── Plugins ─────────────────────────────────────
    // Plugins are installed via App.install(), not in config.
};

pub const GpuOptions = struct {
    frames_in_flight: u32 = 2,
    app_name: [:0]const u8 = "nogui",
    validation: bool = @import("builtin").mode == .Debug,
    loader: noapi.Gpu.LoaderOptions,
};

// ─── App ────────────────────────────────────────────────────────────

/// nogui Application. Single entry point for the entire lifecycle.
///
/// Owns:
///   - GPU (optional, only in GUI mode)
///   - ThreadPool (optional)
///   - WindowManager (with per-window render threads)
///   - ServiceRegistry
///   - Plugin list
///   - Root component (the widget tree)
///   - Command queue
///
/// ## Lifecycle
///
/// ```text
/// App.init() ─→ install plugins ─→ App.run(Gui)
///                                      │
///                                      ├─ SDL init
///                                      ├─ GPU init
///                                      ├─ Create primary window + spawn render thread
///                                      ├─ Plugin.on_start()
///                                      │
///                                      ├─ [Main loop]
///                                      │    ├─ Hooks.on_frame()
///                                      │    ├─ Poll events → Hooks.on_event() filter
///                                      │    ├─ gui.draw(ctx, dc) → widget tree
///                                      │    ├─ Layout widget tree
///                                      │    ├─ Collect RenderCommands → FrameData
///                                      │    ├─ Publish FrameData → signal render thread (non-blocking)
///                                      │    └─ Process commands (std.Io coroutines)
///                                      │
///                                      ├─ Signal all render threads → join
///                                      ├─ SDL shutdown
///                                      └─ Hooks.on_shutdown()
///                                           └─ Plugin.on_shutdown()
/// App.deinit()
/// ```
///
/// ## Threading Model
///
/// The main thread handles events, component tree building, and layout.
/// Each window has its own render thread that consumes FrameData and
/// drives the GPU. Communication is via triple-buffered frame slots
/// with atomic ownership — no blocking on the main thread.
///
/// ```text
/// Main Thread           Per-Window Render Thread
/// ────────────          ─────────────────────────
/// poll events
/// build widget tree
/// run layout
/// produce FrameData ──→ wait for FrameData
/// signal render thread   upload GPU resources
/// process commands       record command buffer
/// next frame             submit to GPU queue
/// ```
pub const App = struct {
    // ── Core subsystems ─────────────────────────────
    io: std.Io,
    gpa: std.mem.Allocator,
    services_: ServiceRegistry,
    window_manager: WindowManager,
    config: AppConfig,

    // ── Optional GPU ───────────────────────────────
    gpu: ?noapi.Gpu = null,

    // ── Optional ThreadPool ────────────────────────
    thread_pool: ?std.Thread.Pool = null,

    // ── Plugins ─────────────────────────────────────
    plugins: std.ArrayListUnmanaged(Plugin) = .{},

    // ── GPU state (initialized at run()) ────────────
    /// Vulkan loader functions from SDL
    spv_extensions: []const [*:0]const u8 = &.{},

    // ── Window state ────────────────────────────────
    primary_window: ?*WindowHandle = null,

    // ── Init ────────────────────────────────────────

    pub fn init(config: AppConfig) @This() {
        return .{
            .io = config.io,
            .gpa = config.gpa,
            .services_ = ServiceRegistry{},
            .window_manager = WindowManager.init(config.gpa),
            .config = config,
        };
    }

    pub fn deinit(self: *@This()) void {
        // Notify shutdown hooks
        const shutdown_ctx = AppContext{
            .services = &self.services_,
            .window_manager = &self.window_manager,
            .allocator = self.gpa,
            .io = self.io,
        };

        if (self.config.hooks.on_shutdown) |cb| cb(&shutdown_ctx);

        // Notify plugins (reverse order)
        var i: usize = self.plugins.items.len;
        while (i > 0) {
            i -= 1;
            self.plugins.items[i].onShutdown(&shutdown_ctx);
            self.plugins.items[i].deinit();
        }
        self.plugins.deinit(self.gpa);

        // Deinit subsystems
        self.window_manager.deinit();
        self.services_.deinit(self.gpa);

        // Destroy GPU if owned
        if (self.gpu) |*gpu| {
            gpu.waitIdle();
            gpu.deinit();
        }

        // Destroy thread pool if owned
        if (self.thread_pool) |*tp| {
            tp.deinit();
        }
    }

    // ── Plugin management ──────────────────────────

    /// Install a plugin. Registered before App.run().
    pub fn install(self: *@This(), plugin: Plugin) !void {
        try self.plugins.append(self.gpa, plugin);
    }

    // ── Service access ─────────────────────────────

    pub fn services(self: *@This()) *ServiceRegistry {
        return &self.services_;
    }

    pub fn windowManager(self: *@This()) *WindowManager {
        return &self.window_manager;
    }

    pub fn window(self: *@This()) ?*WindowHandle {
        return self.primary_window;
    }

    // ── Run ─────────────────────────────────────────

    /// The single entry point. Sets up SDL, initializes the GPU,
    /// starts plugins, runs the main loop, then shuts down cleanly.
    ///
    /// `gui` is any type with a method:
    ///   `draw(ctx: *AppContext, dc: *DrawCtx) anyerror!*Widget`
    ///
    /// The user's draw() function builds and returns the widget tree
    /// each frame.
    pub fn run(self: *@This(), gui: anytype) !void {
        _ = gui;
        // ── 0. Validate ───────────────────────────────
        const has_gpu = self.config.gpu_options != null;

        // ── 1. SDL init ────────────────────────────────
        try sdl3.hints.set(.video_driver, "wayland");
        try sdl3.hints.set(.render_driver, "vulkan");
        try sdl3.init(.{ .video = has_gpu, .events = true });
        errdefer sdl3.quit(.{ .video = has_gpu, .events = true });

        // ── 2. GPU init (optional) ─────────────────────
        if (self.config.gpu_options) |gpu_opts| {
            try sdl3.vulkan.loadLibrary(null);
            const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
            const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
            self.spv_extensions = try self.gpa.dupe([*:0]const u8, sdl_exts);

            self.gpu = try noapi.Gpu.init(.{
                .frames_in_flight = gpu_opts.frames_in_flight,
                .app_name = gpu_opts.app_name,
                .validation = gpu_opts.validation,
                .loader = .{
                    .get_instance_proc_addr = @ptrCast(get_proc_addr),
                    .get_instance_extensions = &self.getSdlExtensions,
                },
                .io = self.io,
            });
            errdefer if (self.gpu) |*g| g.deinit();
        }

        // ── 3. Thread pool (optional) ──────────────────
        if (self.config.thread_pool_size > 0) {
            self.thread_pool = try std.Thread.Pool.init(.{
                .allocator = self.gpa,
                .n_jobs = @intCast(self.config.thread_pool_size),
            });
        }
        errdefer if (self.thread_pool) |*tp| tp.deinit();

        // ── 4. Create primary window ───────────────────
        if (has_gpu) {
            self.primary_window = try self.window_manager.create(
                self.config.title,
                self.config.width,
                self.config.height,
                if (self.gpu) |*g| g else null,
            );
        }

        // ── 5. Start plugins ───────────────────────────
        {
            const ctx = AppContext{
                .services = &self.services_,
                .window_manager = &self.window_manager,
                .allocator = self.gpa,
                .io = self.io,
            };
            for (self.plugins.items) |*plugin| {
                try plugin.onStart(&ctx);
            }
        }

        // ── 6. Main loop ───────────────────────────────
        var should_close = false;
        const gpu_ptr = if (self.gpu) |*g| g else null;

        while (!should_close) {
            // ── a. Hooks.on_frame() ────────────────────
            {
                const ctx = AppContext{
                    .services = &self.services_,
                    .window_manager = &self.window_manager,
                    .allocator = self.gpa,
                    .io = self.io,
                };
                if (self.config.hooks.on_frame) |cb| cb(&ctx);
            }

            // ── b. Poll events ─────────────────────────
            var any_closed = false;
            while (sdl3.events.poll()) |ev| {
                const ctx = AppContext{
                    .services = &self.services_,
                    .window_manager = &self.window_manager,
                    .allocator = self.gpa,
                    .io = self.io,
                };

                // Convert SDL event → proto Event
                const app_event = sdlEventToAppEvent(ev);

                // Global event filter (hooks)
                if (self.config.hooks.on_event) |cb| {
                    if (cb(&ctx, &app_event)) continue; // consumed
                }

                // Route to window
                switch (ev) {
                    .quit => should_close = true,
                    .window_close_requested => {
                        should_close = true;
                        any_closed = true;
                    },
                    else => {},
                }
            }

            // ── c. Build + render widget tree ──────────
            if (gpu_ptr) |gpu| {
                if (self.primary_window) |win| {
                    if (win.gpu_window) |*gw| {
                        _ = gpu;
                        _ = gw;
                        // TODO: full draw + layout + render pipeline
                        // This is where the existing Window.beginFrame/endFrame
                        // logic gets called. For the framework MVP,
                        // we need DrawCtx and the widget tree integration.
                    }
                }
            }

            // ── d. Process commands ────────────────────
            // TODO: advance command queue, deliver events

            // ── e. Exit check ─────────────────────────
            if (any_closed) break;
        }

        // ── 7. Shutdown ──────────────────────────────
        if (gpu_ptr) |gpu| gpu.waitIdle();
        sdl3.quit(.{ .video = has_gpu, .events = true });
    }

    fn getSdlExtensions(self: *@This()) []const [*:0]const u8 {
        return self.spv_extensions;
    }
};

// ─── SDL Event → App Event translation ────────────────────────────

fn sdlEventToAppEvent(ev: sdl3.events.Event) Event {
    _ = ev;
    // Minimal translation — full mapping from window.zig will be shared.
    return .{ .custom = .{ .id = 0, .data = 0 } };
}
