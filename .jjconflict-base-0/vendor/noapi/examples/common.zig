//! Common utilities shared across noapi examples.
//! Provides platform init/deinit, math helpers, GPU upload, and PPM loading.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;

pub const tracy_impl = @import("tracy_impl");
pub const tracy = @import("tracy");
pub const tracy_options: tracy.Options = .{
    .on_demand = false,
    .no_broadcast = false,
    .only_localhost = false,
    .only_ipv4 = false,
    .delayed_init = false,
    .manual_lifetime = false,
};

// ── SDL extension callback ────────────────────────────
// Gpu.init needs a callback to provide instance extensions.
// Since Zig can't pass closures as function pointers, we keep
// a module-level copy that platformInit sets and platformDeinit frees.
var exts_owned: ?[]const [*:0]const u8 = null;

fn getExts() []const [*:0]const u8 {
    return exts_owned orelse &.{};
}

// ── Types ──────────────────────────────────
pub const Vec3 = [3]f32;
pub const Mat4 = [16]f32;

// ── FrameTimer ────────────────────────────────
/// Per-frame delta time + FPS reporting.
pub const FrameTimer = struct {
    fps_timer: u64,
    fps_count: u32,
    fps_freq: u64,
    last_ts: u64,
    delta: f32,
    elapsed: f32,
    max_dt: f32,

    pub fn init() FrameTimer {
        const now = sdl3.timer.getPerformanceCounter();
        const freq = sdl3.timer.getPerformanceFrequency();
        return .{
            .fps_timer = now,
            .fps_count = 0,
            .fps_freq = freq,
            .last_ts = now,
            .delta = 0,
            .elapsed = 0,
            .max_dt = 1.0 / 10.0,
        };
    }

    /// Set a custom max dt (default 1/10s).
    pub fn initMax(max_dt: f32) FrameTimer {
        var t = FrameTimer.init();
        t.max_dt = max_dt;
        return t;
    }

    /// Compute delta time since last tick, accumulate elapsed.
    pub fn tick(self: *FrameTimer) void {
        const now = sdl3.timer.getPerformanceCounter();
        const raw = @as(f32, @floatCast(
            @as(f64, @floatFromInt(now -| self.last_ts)) / @as(f64, @floatFromInt(self.fps_freq)),
        ));
        self.delta = @min(self.max_dt, raw);
        self.elapsed += self.delta;
        self.last_ts = now;
    }

    /// Print FPS every 60 frames.
    pub fn report(self: *FrameTimer) void {
        self.fps_count += 1;
        if (self.fps_count == 60) {
            const now = sdl3.timer.getPerformanceCounter();
            const elapsed_ns = now - self.fps_timer;
            const fps = @as(f64, @floatFromInt(self.fps_freq * self.fps_count)) / @as(f64, @floatFromInt(elapsed_ns));
            const ms = @as(f64, @floatFromInt(elapsed_ns)) /
                @as(f64, @floatFromInt(self.fps_freq * self.fps_count)) * 1000.0;
            std.debug.print("FPS: {d:.1}  frame: {d:.2}ms\n", .{ fps, ms });
            self.fps_timer = now;
            self.fps_count = 0;
        }
    }
};

// ── App ───────────────────────────────────
/// Holds the full platform state created by App.init.
/// Gpu is heap-allocated so the *Gpu pointer stored in Surface stays stable.
pub const App = struct {
    sdl_win: sdl3.video.Window,
    gpu: *noapi.Gpu,
    surf: noapi.Surface,
    gpa: std.mem.Allocator,
    io: Io,
    width: u32,
    height: u32,

    pub fn init(
        comptime app_name: [:0]const u8,
        allocator: std.mem.Allocator,
        io: Io,
        width: u32,
        height: u32,
        frames_in_flight: u5,
        timestamp_queries: bool,
    ) !App {
        // SDL3
        try sdl3.hints.set(.video_driver, "wayland");
        try sdl3.hints.set(.render_driver, "vulkan");
        try sdl3.init(.{ .video = true, .events = true });
        errdefer sdl3.quit(.{ .video = true, .events = true });

        const win = try sdl3.video.Window.init(app_name, width, height, .{
            .resizable = true,
            .high_pixel_density = true,
        });
        errdefer win.deinit();
        try win.show();

        // Vulkan loader via SDL3
        try sdl3.vulkan.loadLibrary(null);
        const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
        const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
        const exts_copy = try allocator.dupe([*:0]const u8, sdl_exts);
        exts_owned = exts_copy;

        // GPU — heap-allocated so *Gpu pointer is stable across App moves
        const gpu = try allocator.create(noapi.Gpu);
        gpu.* = noapi.Gpu.init(.{
            .frames_in_flight = frames_in_flight,
            .app_name = app_name,
            .validation = true,
            .loader = .{
                .get_instance_proc_addr = @ptrCast(get_proc_addr),
                .get_instance_extensions = &getExts,
            },
            .io = io,
            .allocator = allocator,
            .timestamp_queries = timestamp_queries,
        }) catch |err| {
            allocator.destroy(gpu);
            return err;
        };
        errdefer {
            gpu.deinit();
            allocator.destroy(gpu);
        }

        // Surface — pass gpu directly (already a stable heap pointer)
        const sdl_surface = try sdl3.vulkan.Surface.init(
            win,
            @ptrFromInt(@intFromEnum(gpu.instanceHandle())),
            null,
        );
        const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
        const surf = try noapi.Surface.init(gpu, surface, .{
            .extent = .{ .width = width, .height = height },
        });

        return .{
            .gpu = gpu,
            .surf = surf,
            .sdl_win = win,
            .gpa = allocator,
            .io = io,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *App) void {
        self.surf.deinit();
        self.gpu.deinit();
        self.gpa.destroy(self.gpu);
        self.sdl_win.deinit();
        sdl3.quit(.{ .video = true, .events = true });
        if (exts_owned) |e| self.gpa.free(e);
        exts_owned = null;
        self.* = undefined;
    }
};

// ── 3D Vector math ───────────────────────────────

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn normalize(v: Vec3) Vec3 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len == 0) return v;
    const inv_len = 1.0 / len;
    return .{ v[0] * inv_len, v[1] * inv_len, v[2] * inv_len };
}

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

// ── Matrix math (column-major, row-major storage ────────
// Matrix storage convention: Zig flat arrays (row-major memory layout).
// When used as `mat4` in GLSL (column-major), the first 4 elements
// of the flat array become column 0, the next 4 become column 1, etc.
// The perspective/lookAt functions below account for this transpose.

/// Identity matrix.
pub fn id() Mat4 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

/// Uniform scale matrix.
pub fn scale(s: f32) Mat4 {
    return .{
        s, 0, 0, 0,
        0, s, 0, 0,
        0, 0, s, 0,
        0, 0, 0, 1,
    };
}

/// Perspective projection for Vulkan (Z in [0, 1] after w-divide).
/// Row-major storage; GLSL reads as column-major.
/// The negative signs in row 2 map the Z range to Vulkan's [0, 1] depth.
pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fov_y * 0.5);
    return .{
        f / aspect, 0, 0,                            0,
        0,          f, 0,                            0,
        0,          0, -far / (far - near),          -1,
        0,          0, -(far * near) / (far - near), 0,
    };
}

/// Look-at view matrix (world→view). Row-major storage.
/// eye: camera position, center: point to look at, up: up direction.
pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
    const fwd = normalize(sub(center, eye));
    const right = normalize(cross(fwd, up));
    const cam_up = cross(right, fwd);

    return .{
        right[0],         cam_up[0],         -fwd[0],       0,
        right[1],         cam_up[1],         -fwd[1],       0,
        right[2],         cam_up[2],         -fwd[2],       0,
        -dot(right, eye), -dot(cam_up, eye), dot(fwd, eye), 1,
    };
}

/// 4×4 matrix multiply: a * b. Both stored in row-major flat arrays.
pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var m: Mat4 = undefined;
    comptime var i: usize = 0;
    inline while (i < 4) : (i += 1) {
        comptime var j: usize = 0;
        inline while (j < 4) : (j += 1) {
            m[i * 4 + j] = a[i * 4 + 0] * b[0 * 4 + j] +
                a[i * 4 + 1] * b[1 * 4 + j] +
                a[i * 4 + 2] * b[2 * 4 + j] +
                a[i * 4 + 3] * b[3 * 4 + j];
        }
    }
    return m;
}

/// Matrix * Vec4 transform.
pub fn transform(m: Mat4, v: [4]f32) [4]f32 {
    return .{
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2] + m[3] * v[3],
        m[4] * v[0] + m[5] * v[1] + m[6] * v[2] + m[7] * v[3],
        m[8] * v[0] + m[9] * v[1] + m[10] * v[2] + m[11] * v[3],
        m[12] * v[0] + m[13] * v[1] + m[14] * v[2] + m[15] * v[3],
    };
}

/// Matrix inverse for a general 4×4 matrix (row-major storage).
/// Uses Gauss-Jordan elimination.
pub fn inv(m: Mat4) Mat4 {
    var a = m;
    var inv_m: Mat4 = id();

    comptime var col: usize = 0;
    inline while (col < 4) : (col += 1) {
        // Find pivot
        var pivot = col;
        while (pivot < 4 and @abs(a[pivot * 4 + col]) < 1e-10) : (pivot += 0) {
            pivot += 1;
        }
        if (pivot >= 4) return id(); // singular

        // Swap rows
        if (pivot != col) {
            comptime var i: usize = 0;
            inline while (i < 4) : (i += 1) {
                const tmp = a[col * 4 + i];
                a[col * 4 + i] = a[pivot * 4 + i];
                a[pivot * 4 + i] = tmp;
                const tmp2 = inv_m[col * 4 + i];
                inv_m[col * 4 + i] = inv_m[pivot * 4 + i];
                inv_m[pivot * 4 + i] = tmp2;
            }
        }

        // Scale row
        const d = a[col * 4 + col];
        comptime var j: usize = 0;
        inline while (j < 4) : (j += 1) {
            a[col * 4 + j] /= d;
            inv_m[col * 4 + j] /= d;
        }

        // Eliminate other rows
        comptime var row: usize = 0;
        inline while (row < 4) : (row += 1) {
            if (row == col) continue;
            const factor = a[row * 4 + col];
            comptime var j2: usize = 0;
            inline while (j2 < 4) : (j2 += 1) {
                a[row * 4 + j2] -= factor * a[col * 4 + j2];
                inv_m[row * 4 + j2] -= factor * inv_m[col * 4 + j2];
            }
        }
    }
    return inv_m;
}

/// Transpose a 4×4 matrix (row-major ↔ column-major).
pub fn transpose(m: Mat4) Mat4 {
    return .{
        m[0], m[4], m[8],  m[12],
        m[1], m[5], m[9],  m[13],
        m[2], m[6], m[10], m[14],
        m[3], m[7], m[11], m[15],
    };
}

// ── GPU upload helper ──────────────────────────────

/// Allocate a GPU buffer of type `.default` and copy data into it.
/// Returns the GpuPtr for the uploaded data.
pub fn gpuCreate(comptime T: type, gpu: *noapi.Gpu, data: []const T, alignment: u29) !noapi.GpuPtr {
    const size = data.len * @sizeOf(T);
    if (size == 0) return error.ZeroSize;
    const ptr = try gpu.gpuMalloc(size, alignment, .default);
    @memcpy(ptr.cpu[0..size], std.mem.sliceAsBytes(data));
    return ptr;
}

// ── PPM loader ────────────────────────────────

/// Result of loading a PPM P6 file.
pub const PpmData = struct {
    data: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PpmData) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

/// Load a binary PPM (P6) file. Returns raw RGB pixel data.
/// The caller owns the returned memory (freed via PpmData.deinit).
pub fn loadPpm(allocator: std.mem.Allocator, io: Io, path: []const u8) !PpmData {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);

    if (bytes.len < 3 or bytes[0] != 'P' or bytes[1] != '6')
        return error.InvalidPpm;

    var pos: usize = 3;
    // Skip newline after magic + skip comments
    while (pos < bytes.len and (bytes[pos] == '\n' or bytes[pos] == '#')) {
        if (bytes[pos] == '#') {
            while (pos < bytes.len and bytes[pos] != '\n') pos += 1;
        }
        if (pos < bytes.len and bytes[pos] == '\n') pos += 1;
    }

    // Width
    var width: u32 = 0;
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') : (pos += 1)
        width = width * 10 + (bytes[pos] - '0');
    if (pos < bytes.len and bytes[pos] == '\n') pos += 1;
    // Skip comments after width
    while (pos < bytes.len and (bytes[pos] == '\n' or bytes[pos] == '#')) {
        if (bytes[pos] == '#') {
            while (pos < bytes.len and bytes[pos] != '\n') pos += 1;
        }
        if (pos < bytes.len and bytes[pos] == '\n') pos += 1;
    }

    // Height
    var height: u32 = 0;
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') : (pos += 1)
        height = height * 10 + (bytes[pos] - '0');
    if (pos < bytes.len and bytes[pos] == '\n') pos += 1;

    // Maxval line
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') pos += 1;
    if (pos < bytes.len and bytes[pos] == '\n') pos += 1;

    const pixel_count = width * height * 3;
    if (pos + pixel_count > bytes.len) return error.InvalidPpm;

    const data = try allocator.dupe(u8, bytes[pos .. pos + pixel_count]);
    return .{
        .data = data,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}
