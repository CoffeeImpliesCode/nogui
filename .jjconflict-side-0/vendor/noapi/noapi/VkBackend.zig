//! VkBackend — Vulkan 1.4 backend for noapi.
//! Multi-window: each window has its own surface + swapchain, device + queue shared.

const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("tracy");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vk);
const vk = @import("vk.zig");
const Extent2D = @import("Extent2D.zig");
const DeviceLimits = @import("DeviceLimits.zig");
const Stage = @import("Barrier.zig").Stage;
const Hazard = @import("Barrier.zig").Hazard;
const DepthState = @import("DepthState.zig");
const RasterState = @import("RasterState.zig");
const BlendState = @import("BlendState.zig");
const Viewport = @import("Viewport.zig");
const Scissor = @import("Viewport.zig").Scissor;
const PushData = @import("CommandBuffer.zig").PushData;
const IndexFormat = @import("CommandBuffer.zig").IndexFormat;
const Rendering = @import("Rendering.zig");
const MemoryType = @import("GpuError.zig").MemoryType;
const GpuPtr = @import("GpuPtr.zig");
const VertexBinding = @import("VertexInput.zig").VertexBinding;
const VertexAttribute = @import("VertexInput.zig").VertexAttribute;
const Texture = @import("Texture.zig");
const TextureDesc = Texture.TextureDesc;
const TextureViewDesc = Texture.TextureViewDesc;
const SamplerDesc = Texture.SamplerDesc;
const TextureFormat = Texture.TextureFormat;
const TextureType = Texture.TextureType;
const TextureUsage = Texture.TextureUsage;
const TextureRegion = Texture.TextureRegion;
const BlitRect = Texture.BlitRect;
const Filter = Texture.Filter;
const FrameSchedule = @import("Gpu.zig").FrameSchedule;
const FrameResult = @import("Gpu.zig").FrameResult;
const PresentInfo = @import("Gpu.zig").PresentInfo;
const PresentFeedback = @import("Gpu.zig").PresentFeedback;
const TimestampQuerySet = @import("TimestampQuerySet.zig");
const TimestampInfo = TimestampQuerySet.TimestampInfo;

const PresentTimingMode = enum {
    unsupported,
    ext,
    google,
};

const PresentTimingCallResult = enum {
    not_called,
    success,
    suboptimal,
    incomplete,
    failed,
};

const PresentQueueResult = enum {
    not_called,
    success,
    suboptimal,
    out_of_date,
    surface_lost,
    timing_queue_full,
    device_lost,
    failed,
};

const PresentTimingDiagnostics = struct {
    mode: PresentTimingMode = .unsupported,
    swapchain_id: u64 = 0,
    swapchain_generation: u64 = 0,
    present_stage_bits: u32 = 0,
    time_domain_id: u64 = 0,
    time_domain_valid: bool = false,
    last_present_id: u64 = 0,
    last_present_stage_bits: u32 = 0,
    last_present_time_domain_id: u64 = 0,
    last_present_queue_result: PresentQueueResult = .not_called,
    last_present_chain_id2: bool = false,
    last_present_chain_timings: bool = false,
    last_present_chain_google: bool = false,
    timed_present_attempts: u64 = 0,
    timed_present_submitted: u64 = 0,
    outstanding_timed_presents: u32 = 0,
    ext_probe_calls: u64 = 0,
    ext_probe_result: PresentTimingCallResult = .not_called,
    ext_probe_count: u32 = 0,
    ext_empty_probe_polls: u32 = 0,
    ext_probe_timing_properties_counter: u64 = 0,
    ext_probe_time_domains_counter: u64 = 0,
    ext_retrieve_calls: u64 = 0,
    ext_retrieve_result: PresentTimingCallResult = .not_called,
    ext_retrieve_count: u32 = 0,
    ext_retrieve_timing_properties_counter: u64 = 0,
    ext_retrieve_time_domains_counter: u64 = 0,
    ext_last_record_id: u64 = 0,
    ext_last_record_stage_count: u32 = 0,
    ext_last_record_stage_bits: u32 = 0,
    ext_last_record_time: u64 = 0,
    ext_last_record_complete: bool = false,
    ext_complete_records: u32 = 0,
    ext_positive_records: u32 = 0,
    google_probe_calls: u64 = 0,
    google_probe_result: PresentTimingCallResult = .not_called,
    google_probe_count: u32 = 0,
    google_empty_probe_polls: u32 = 0,
    google_retrieve_calls: u64 = 0,
    google_retrieve_result: PresentTimingCallResult = .not_called,
    google_retrieve_count: u32 = 0,
    google_last_record_id: u64 = 0,
    google_last_record_time: u64 = 0,
    google_complete_records: u32 = 0,
    google_positive_records: u32 = 0,
    last_poll_returned: u32 = 0,
    first_timed_present_start_ns: i96 = 0,
    watchdog_last_now_ns: i96 = 0,
    watchdog_elapsed_ns: i96 = 0,
    watchdog_triggered: bool = false,

    fn notePresentRequest(
        self: *PresentTimingDiagnostics,
        mode: PresentTimingMode,
        present_id: u64,
        stage_bits: u32,
        time_domain_id: u64,
    ) void {
        self.mode = mode;
        self.last_present_id = present_id;
        self.last_present_stage_bits = stage_bits;
        self.last_present_time_domain_id = time_domain_id;
        self.last_present_queue_result = .not_called;
        self.last_present_chain_id2 = mode == .ext;
        self.last_present_chain_timings = mode == .ext;
        self.last_present_chain_google = mode == .google;
        self.timed_present_attempts += 1;
    }

    fn notePresentResult(self: *PresentTimingDiagnostics, result: PresentQueueResult) void {
        self.last_present_queue_result = result;
        if (result == .success or result == .suboptimal) {
            self.timed_present_submitted += 1;
        }
    }

    fn notePresentFailure(self: *PresentTimingDiagnostics, result: PresentQueueResult) void {
        self.last_present_queue_result = result;
    }

    fn noteExtProbe(
        self: *PresentTimingDiagnostics,
        result: PresentTimingCallResult,
        count: u32,
        timing_properties_counter: u64,
        time_domains_counter: u64,
    ) void {
        self.ext_probe_calls += 1;
        self.ext_probe_result = result;
        self.ext_probe_count = count;
        self.ext_probe_timing_properties_counter = timing_properties_counter;
        self.ext_probe_time_domains_counter = time_domains_counter;
    }

    fn noteExtRetrieve(
        self: *PresentTimingDiagnostics,
        result: PresentTimingCallResult,
        count: u32,
        timing_properties_counter: u64,
        time_domains_counter: u64,
    ) void {
        self.ext_retrieve_calls += 1;
        self.ext_retrieve_result = result;
        self.ext_retrieve_count = count;
        self.ext_retrieve_timing_properties_counter = timing_properties_counter;
        self.ext_retrieve_time_domains_counter = time_domains_counter;
    }

    fn noteExtRecord(
        self: *PresentTimingDiagnostics,
        present_id: u64,
        stage_count: u32,
        stage: vk.PresentStageFlagsEXT,
        time: u64,
        complete: bool,
    ) void {
        self.ext_last_record_id = present_id;
        self.ext_last_record_stage_count = stage_count;
        self.ext_last_record_stage_bits = @bitCast(stage);
        self.ext_last_record_time = time;
        self.ext_last_record_complete = complete;
        if (complete) {
            self.ext_complete_records +|= 1;
            if (time != 0) self.ext_positive_records +|= 1;
        }
    }

    fn noteGoogleProbe(
        self: *PresentTimingDiagnostics,
        result: PresentTimingCallResult,
        count: u32,
    ) void {
        self.google_probe_calls += 1;
        self.google_probe_result = result;
        self.google_probe_count = count;
    }

    fn noteGoogleRetrieve(
        self: *PresentTimingDiagnostics,
        result: PresentTimingCallResult,
        count: u32,
    ) void {
        self.google_retrieve_calls += 1;
        self.google_retrieve_result = result;
        self.google_retrieve_count = count;
    }

    fn noteGoogleRecord(self: *PresentTimingDiagnostics, present_id: u64, time: u64) void {
        self.google_last_record_id = present_id;
        self.google_last_record_time = time;
        self.google_complete_records +|= 1;
        if (time != 0) self.google_positive_records +|= 1;
    }

    fn notePollResult(self: *PresentTimingDiagnostics, count: usize) void {
        self.last_poll_returned = @intCast(count);
    }
};
fn presentTimingCallResult(result: vk.Result) PresentTimingCallResult {
    return switch (result) {
        .success => .success,
        .suboptimal_khr => .suboptimal,
        .incomplete => .incomplete,
        else => .failed,
    };
}
fn presentQueueResult(result: vk.Result) PresentQueueResult {
    return switch (result) {
        .success => .success,
        .suboptimal_khr => .suboptimal,
        else => .failed,
    };
}

fn presentQueueFailure(err: anyerror) PresentQueueResult {
    return if (err == error.OutOfDateKHR)
        .out_of_date
    else if (err == error.SurfaceLostKHR)
        .surface_lost
    else if (err == error.PresentTimingQueueFullEXT)
        .timing_queue_full
    else if (err == error.DeviceLost)
        .device_lost
    else
        .failed;
}

fn frameResultForPresentQueue(result: PresentQueueResult) FrameResult {
    return .{
        .gpu_blocked_ns = 0,
        .present_out_of_date = result == .out_of_date,
    };
}

const PresentRecord = struct {
    present_id: u64,
    actual_present_ns: u64,
    completed: bool,
};

// One bounded queue is owned per surface for both timing backends.
const max_present_feedback = 64;
// Vulkan timing feedback must become available within the same bounded drain
// window used by the presentation lifecycle. Keep polling nonblocking, then
// report an explicit capability failure instead of substituting CPU time.
const present_timing_deadline_ns: i96 = 5_000_000_000;

const PresentTimingWatchdogDecision = enum {
    wait,
    disable,
};

fn presentTimingWatchdogDecision(
    outstanding: u32,
    first_pending_start_ns: ?i96,
    now_ns: i96,
) PresentTimingWatchdogDecision {
    const start_ns = first_pending_start_ns orelse return .wait;
    if (outstanding == 0 or now_ns < start_ns) return .wait;
    return if (now_ns - start_ns >= present_timing_deadline_ns) .disable else .wait;
}
fn presentTimingWatchdogProgressStart(
    outstanding: u32,
    current_start_ns: ?i96,
    now_ns: i96,
    completed: usize,
) ?i96 {
    if (completed == 0) return current_start_ns;
    return if (outstanding == 0) null else now_ns;
}

fn notePresentTimingProgress(self: *VkBackend, win: *Window, completed: usize) void {
    if (completed == 0) {
        if (win.outstanding_timed_presents == 0) {
            win.first_timed_present_start_ns = null;
            win.present_timing_diagnostics.first_timed_present_start_ns = 0;
        }
        return;
    }
    const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    const current_start_ns = if (win.first_timed_present_start_ns) |start|
        start.nanoseconds
    else
        null;
    const next_start_ns = presentTimingWatchdogProgressStart(
        win.outstanding_timed_presents,
        current_start_ns,
        now_ns,
        completed,
    );
    if (next_start_ns) |start_ns| {
        win.first_timed_present_start_ns = std.Io.Timestamp.fromNanoseconds(start_ns);
        win.present_timing_diagnostics.first_timed_present_start_ns = start_ns;
    } else {
        win.first_timed_present_start_ns = null;
        win.present_timing_diagnostics.first_timed_present_start_ns = 0;
    }
}

const PresentationScratch = struct {
    records: [max_present_feedback]PresentRecord = undefined,
    normalized: [max_present_feedback]PresentFeedback = undefined,
    ext_records: [max_present_feedback]vk.PastPresentationTimingEXT = undefined,
    ext_stages: [max_present_feedback]vk.PresentStageTimeEXT = undefined,
    google_records: [max_present_feedback]vk.PastPresentationTimingGOOGLE = undefined,
};

const PastPresentationTimingPropertiesProbe = extern struct {
    s_type: vk.StructureType = .past_presentation_timing_properties_ext,
    p_next: ?*anyopaque = null,
    timing_properties_counter: u64 = 0,
    time_domains_counter: u64 = 0,
    presentation_timing_count: u32 = 0,
    p_presentation_timings: ?[*]vk.PastPresentationTimingEXT = null,
};

const TimestampQueryEntry = struct {
    valid: bool = false,
    pool: vk.QueryPool = .null_handle,
    count: u32 = 0,
};

const SurfacePresentTimingSupport = struct {
    present_id2: bool = false,
    present_timing: bool = false,
    supported_stages: vk.PresentStageFlagsEXT = .{},
    stage: ?vk.PresentStageFlagsEXT = null,
    time_domain_id: u64 = 0,
    time_domain_valid: bool = false,
};

pub const VkBackend = @This();

// Swapchain recreation strategy: when false, uses deviceWaitIdle (slow but
// safe everywhere). When true, uses VK_EXT_swapchain_maintenance1 fence
// (~10x faster, requires extension + driver support).
const use_swapchain_maintenance1 = false;

// Tracy GPU zones: u16 wire query ids. mr_gpu encodes the frame in the high byte
// so ids are unique across frames. The server resolves GpuTime events through a
// per-id slot array (ctx->query[id]); ids restarting every frame would collide
// across windows. 256 slots per frame (index: u8).
const TracyQueryId = packed struct(u16) {
    pub const cap: u16 = 256; // slots 0..255 per frame
    frame: u8,
    index: u8,
};

// Calibrated timestamp domains: CPU (CLOCK_MONOTONIC_RAW, matches TracyVulkan.hpp
// on Linux) + GPU device domain (the clock vkCmdWriteTimestamp queries use).
const tracy_calib_info = [2]vk.CalibratedTimestampInfoKHR{
    .{ .time_domain = .clock_monotonic_raw_khr },
    .{ .time_domain = .device_khr },
};

// Opaque handle types that the backend uses for resources.
pub const CommandBufferHandle = vk.CommandBuffer;
pub const TimestampQueryHandle = enum(u32) {
    invalid = 0,
    _,
};
pub const ShaderHandle = vk.ShaderEXT;
pub const SemaphoreHandle = vk.Semaphore;
pub const BufferHandle = vk.Buffer;
pub const QueueHandle = vk.Queue;
pub const TextureHandle = @import("TextureHandle.zig");

pub const DeviceIdentity = struct {
    name: []const u8,
    vendor_id: u32,
    device_id: u32,
    driver: []const u8,
};

pub const max_textures = 65536;
pub const max_samplers = 256;

fn propertyString(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

allocator: Allocator = undefined,
b: vk.BaseWrapper = undefined,
vki: vk.InstanceWrapper = undefined,
vkd: vk.DeviceWrapper = undefined,
instance: vk.InstanceProxy = undefined,
debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
physical_device: vk.PhysicalDevice = undefined,
device: vk.DeviceProxy = undefined,
queue: vk.QueueProxy = undefined,
queue_family_index: u32 = undefined,
queue_sem: vk.Semaphore = undefined,
offscreen_cmd_pool: vk.CommandPool = .null_handle,
submitted_work: std.ArrayList(SubmittedWork) = undefined,
timestamp_query_sets: std.ArrayListUnmanaged(TimestampQueryEntry) = .empty,
queue_counter: u64 = 0,
queue_mutex: std.Io.Mutex = std.Io.Mutex.init,
io: std.Io,
// Device-level timing extension availability; the active mode is per surface.
has_ext_present_timing: bool = false,
has_google_present_timing: bool = false,
has_surface_capabilities2: bool = false,

// Shared descriptor set layouts (no_gfx_api pattern: 3 base sets + optional raytracing)
desc_layouts: [3]vk.DescriptorSetLayout = undefined,
pipeline_layout_graphics: vk.PipelineLayout = undefined,
pipeline_layout_compute: vk.PipelineLayout = undefined,

frames_in_flight: u32 = 2,
windows: std.ArrayListUnmanaged(Window) = std.ArrayListUnmanaged(Window).empty,

// Buffer resource pool (no_gfx_api pattern: pooled allocs with handles)
allocs: std.ArrayListUnmanaged(AllocInfo) = .empty,
// Texture pool (index = u32 handle, .id field)
textures: std.ArrayListUnmanaged(TextureInfo) = .empty,
// Descriptor heap pool
desc_heaps: std.ArrayListUnmanaged(DescHeapInfo) = .empty,

// Cache: texture view descriptors (key = (texture_id << 32) | view_desc_hash)
texture_view_cache: std.AutoHashMap(u64, vk.ImageView) = undefined,
// Cache: sampler descriptors (key = sampler_desc_hash)
sampler_cache: std.AutoHashMap(u64, vk.Sampler) = undefined,
// Device limits queried at init from VkPhysicalDeviceProperties
device_limits: DeviceLimits = .{},
selected_device_name: [vk.MAX_PHYSICAL_DEVICE_NAME_SIZE]u8 = undefined,
selected_device_name_len: u32 = 0,
selected_driver_name: [vk.MAX_DRIVER_NAME_SIZE]u8 = undefined,
selected_driver_name_len: u32 = 0,
selected_vendor_id: u32 = 0,
selected_device_id: u32 = 0,
// Memory properties cached at init from vkGetPhysicalDeviceMemoryProperties
mem_props: vk.PhysicalDeviceMemoryProperties = undefined,

// Deferred free list — avoids deviceWaitIdle per individual free
pending_free: std.ArrayList(PendingFree) = .empty,

// Depth attachment state for reverse barrier in cmdEndRendering
last_depth_image: vk.Image = .null_handle,
last_depth_format: vk.Format = .undefined,

// Debug feature flags (set at creation via Options)
enable_debug_utils: bool = false, // VK_EXT_debug_utils object naming + labels
enable_nv_checkpoints: bool = false, // VK_NV_device_diagnostic_checkpoints
enable_nv_diagnostics: bool = false, // VK_NV_device_diagnostics_config
enable_device_fault: bool = false, // VK_EXT_device_fault

// NVIDIA diagnostic checkpoint counter (monotonic)
checkpoint_counter: u32 = 0,

// Generic timestamp queries are independent of Tracy. Tracy zones use a
// separate flag because they also require calibrated timestamp support.
timestamp_queries: bool = false,
timestamp_period: f32 = 0,
timestamp_valid_bits: u7 = 0,
tracy_gpu_zones: bool = false,
tracy_queue: ?tracy.GpuQueue = null,
tracy_prev_calib_cpu: u64 = 0,

const TextureInfo = struct {
    valid: bool = true,
    image: vk.Image,
    default_view: vk.ImageView,
    memory: vk.DeviceMemory = .null_handle,
    format: vk.Format,
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 1,
    mip_levels: u32 = 1,
};

pub const DescHeapInfo = struct {
    valid: bool = true,
    pool: vk.DescriptorPool,
    sets: [3]vk.DescriptorSet, // textures, textures_rw, samplers
};

pub const Window = struct {
    valid: bool = true,
    surface: vk.SurfaceKHR = .null_handle,
    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_format: vk.Format = .b8g8r8a8_srgb,
    extent: Extent2D = .{}, // actual swapchain image extent
    requested_extent: Extent2D = .{}, // pending resize request
    present_mode: vk.PresentModeKHR = .fifo_khr,
    images: std.ArrayListUnmanaged(vk.Image) = .empty,
    views: std.ArrayListUnmanaged(vk.ImageView) = .empty,
    present_sems: std.ArrayListUnmanaged(vk.Semaphore) = .empty,
    frames_in_flight: u32 = 2,
    cmd_pools: std.ArrayListUnmanaged(vk.CommandPool) = .empty,
    cmd_buffers: std.ArrayListUnmanaged(vk.CommandBufferProxy) = .empty,
    cmd_pool_ready: std.ArrayListUnmanaged(vk.Fence) = .empty,
    // Per-frame Tracy GPU query pools (timestamp queries); stay empty unless profiling enabled.
    tracy_query_pools: std.ArrayListUnmanaged(vk.QueryPool) = .empty,
    tracy_queries: std.ArrayListUnmanaged(u16) = .empty,
    // Cached Tracy source-location ids for per-frame GPU zones, keyed by swapchain
    // image index (bounded: alloc'd srclocs are never freed by the profiler).
    tracy_img_srclocs: std.ArrayListUnmanaged(u64) = .empty,
    present_done_fences: std.ArrayListUnmanaged(vk.Fence) = if (use_swapchain_maintenance1) .empty else undefined,
    frame_index: u32 = 0,
    image_index: u32 = 0,
    // CPU nanoseconds spent blocked on the GPU this frame (acquire/present/fence waits).
    slop_ns: u64 = 0,
    needs_resize: bool = false,
    resize_throttle: u32 = 0,
    retired_swapchain: vk.SwapchainKHR = .null_handle,
    // Per-frame pending wait/signal semaphores (submitted with cmd buf in endFrame).
    wait_sems: std.ArrayListUnmanaged(std.ArrayListUnmanaged(vk.Semaphore)) = .empty,
    wait_values: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u64)) = .empty,
    signal_sems: std.ArrayListUnmanaged(std.ArrayListUnmanaged(vk.Semaphore)) = .empty,
    signal_values: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u64)) = .empty,
    last_present_timing_id: u64 = 0,
    last_feedback_id: u64 = 0,
    // Resolved per surface at addWindow from present timing capabilities.
    timing_mode: PresentTimingMode = .unsupported,
    present_stage_queries: vk.PresentStageFlagsEXT = .{},
    present_stage_support: vk.PresentStageFlagsEXT = .{},
    present_time_domains: [8]vk.TimeDomainKHR = undefined,
    present_time_domain_ids: [8]u64 = undefined,
    present_time_domain_count: u32 = 0,
    time_domain_id: u64 = 0,
    time_domain_valid: bool = false,
    outstanding_timed_presents: u32 = 0,
    first_timed_present_start_ns: ?std.Io.Timestamp = null,
    present_timing_diagnostics: PresentTimingDiagnostics = .{},
    present_scratch: PresentationScratch = .{},
};

fn notePresentQueueFailure(win: *Window, err: anyerror) FrameResult {
    const result = frameResultForPresentQueue(presentQueueFailure(err));
    if (result.present_out_of_date) win.needs_resize = true;
    return result;
}

fn advanceFrame(win: *Window, frame: u32) void {
    if (win.resize_throttle > 0) win.resize_throttle -= 1;
    win.frame_index = (frame + 1) % win.frames_in_flight;
}

const SubmittedWork = struct {
    cmds: []const vk.CommandBuffer,
    fence: vk.Fence,
};

pub const Options = struct {
    app_name: [:0]const u8 = "noapi",

    validation: bool = false,
    frames_in_flight: u32 = 2,
    loader: Loader = .{},
    io: std.Io,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    enable_debug_utils: bool = false,
    enable_nv_checkpoints: bool = false,
    enable_nv_diagnostics: bool = false,
    enable_device_fault: bool = false,
    timestamp_queries: bool = false,

    pub const Loader = struct {
        get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null,
        get_instance_extensions: ?*const fn () []const [*:0]const u8 = null,
    };
};

fn timestampQueriesAvailable(period: f32, valid_bits: u7) bool {
    return period > 0 and valid_bits > 0;
}
fn extPresentTimingExtensionsAvailable(
    has_ext_present_timing: bool,
    has_present_id2: bool,
    has_surface_capabilities2: bool,
    has_calibrated_timestamps: bool,
) bool {
    return has_ext_present_timing and has_present_id2 and
        has_surface_capabilities2 and has_calibrated_timestamps;
}

fn needsCalibratedTimestamps(ext_present_timing: bool, tracy_gpu_zones: bool) bool {
    return ext_present_timing or tracy_gpu_zones;
}

fn selectPresentStage(supported: vk.PresentStageFlagsEXT) ?vk.PresentStageFlagsEXT {
    if (supported.image_first_pixel_visible_bit_ext) {
        return .{ .image_first_pixel_visible_bit_ext = true };
    }
    if (supported.image_first_pixel_out_bit_ext) {
        return .{ .image_first_pixel_out_bit_ext = true };
    }
    return null;
}

/// Resolve the final mode after surface capabilities and swapchain time-domain
/// properties are known. EXT is usable only when every prerequisite is present.
fn resolvePresentTimingMode(
    ext_device_support: bool,
    surface_support: SurfacePresentTimingSupport,
    google_device_support: bool,
) PresentTimingMode {
    if (ext_device_support and
        surface_support.present_id2 and
        surface_support.present_timing and
        surface_support.stage != null and
        surface_support.time_domain_valid)
    {
        return .ext;
    }
    if (google_device_support) return .google;
    return .unsupported;
}

/// Resolve the provisional mode used while creating a swapchain. The time
/// domain is queried immediately after creation and can downgrade EXT.
fn resolveSurfacePresentTimingMode(
    ext_device_support: bool,
    surface_support: SurfacePresentTimingSupport,
    google_device_support: bool,
) PresentTimingMode {
    if (ext_device_support and
        surface_support.present_id2 and
        surface_support.present_timing and
        surface_support.stage != null)
    {
        return .ext;
    }
    if (google_device_support) return .google;
    return .unsupported;
}

fn querySurfacePresentTimingSupport(
    self: *VkBackend,
    surface: vk.SurfaceKHR,
) SurfacePresentTimingSupport {
    var support: SurfacePresentTimingSupport = .{};
    if (!self.has_surface_capabilities2 or !self.has_ext_present_timing) return support;

    var present_id2_caps: vk.SurfaceCapabilitiesPresentId2KHR = .{
        .present_id_2_supported = .false,
    };
    var timing_caps: vk.PresentTimingSurfaceCapabilitiesEXT = .{
        .p_next = @ptrCast(&present_id2_caps),
        .present_timing_supported = .false,
        .present_at_absolute_time_supported = .false,
        .present_at_relative_time_supported = .false,
        .present_stage_queries = .{},
    };
    var caps2: vk.SurfaceCapabilities2KHR = .{
        .p_next = @ptrCast(&timing_caps),
        .surface_capabilities = undefined,
    };
    const surface_info: vk.PhysicalDeviceSurfaceInfo2KHR = .{ .surface = surface };
    self.instance.getPhysicalDeviceSurfaceCapabilities2KHR(
        self.physical_device,
        &surface_info,
        &caps2,
    ) catch |err| {
        log.warn("present timing capability query failed: {}", .{err});
        return support;
    };
    support.present_id2 = present_id2_caps.present_id_2_supported == .true;
    support.present_timing = timing_caps.present_timing_supported == .true;
    if (support.present_timing) {
        support.supported_stages = timing_caps.present_stage_queries;
        support.stage = selectPresentStage(timing_caps.present_stage_queries);
    }
    return support;
}

const DeviceFeatures = struct {
    vk10: vk.PhysicalDeviceFeatures2 = .{ .features = .{
        .shader_int_64 = .true,
        .shader_float_64 = .true,
        .sampler_anisotropy = .true,
    } },
    vk11: vk.PhysicalDeviceVulkan11Features = .{ .shader_draw_parameters = .true },
    vk12: vk.PhysicalDeviceVulkan12Features = .{},
    vk13: vk.PhysicalDeviceVulkan13Features = .{},
    shader_object: vk.PhysicalDeviceShaderObjectFeaturesEXT = .{},
    descriptor_buffer: vk.PhysicalDeviceDescriptorBufferFeaturesEXT = .{},
    swapchain_maint1: vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT = .{},
    present_id2: vk.PhysicalDevicePresentId2FeaturesKHR = .{},
    present_timing: vk.PhysicalDevicePresentTimingFeaturesEXT = .{},
    diagnostics_config: void = undefined,
    device_fault: void = undefined,

    fn init(
        self: *DeviceFeatures,
        tracy_host_reset: bool,
        present_timing: bool,
    ) void {
        self.vk10.features.shader_int_64 = .true;
        self.vk10.features.shader_float_64 = .true;
        self.vk11.shader_draw_parameters = .true;
        self.vk11.p_next = @constCast(&self.vk12);
        self.vk10.p_next = @constCast(&self.vk11);
        self.vk12 = .{
            .descriptor_indexing = .true,
            .runtime_descriptor_array = .true,
            .shader_sampled_image_array_non_uniform_indexing = .true,
            .shader_storage_image_array_non_uniform_indexing = .true,
            .shader_uniform_buffer_array_non_uniform_indexing = .true,
            .shader_storage_buffer_array_non_uniform_indexing = .true,
            .descriptor_binding_sampled_image_update_after_bind = .true,
            .descriptor_binding_storage_image_update_after_bind = .true,
            .descriptor_binding_partially_bound = .true,
            .timeline_semaphore = .true,
            .buffer_device_address = .true,
            .scalar_block_layout = .true,
            .draw_indirect_count = .true,
            .host_query_reset = if (tracy_host_reset) .true else .false,
            .p_next = @constCast(&self.descriptor_buffer),
        };
        self.descriptor_buffer = .{ .descriptor_buffer = .true, .p_next = @constCast(&self.shader_object) };
        self.shader_object = .{ .shader_object = .true, .p_next = @constCast(&self.vk13) };
        self.vk13 = .{
            .dynamic_rendering = .true,
            .synchronization_2 = .true,
            .p_next = null,
        };
        if (use_swapchain_maintenance1) {
            self.swapchain_maint1 = .{ .swapchain_maintenance_1 = .true, .p_next = @constCast(&self.vk13) };
            self.shader_object.p_next = @constCast(&self.swapchain_maint1);
        }
        if (present_timing) {
            self.present_id2 = .{
                .present_id_2 = .true,
                .p_next = @constCast(&self.present_timing),
            };
            self.present_timing = .{
                .present_timing = .true,
                .p_next = self.shader_object.p_next,
            };
            self.shader_object.p_next = @constCast(&self.present_id2);
        }
    }
};

const AllocInfo = extern struct {
    buf: vk.Buffer,
    memory: vk.DeviceMemory,
    gpu_addr: u64,
    cpu: ?[*]u8,
    size: u64,
};

/// Resources pending deferred destruction. Pushed by gpuFree/textureDestroy/descHeapDestroy,
/// drained by flushPendingFrees which calls deviceWaitIdle once then destroys all.
const PendingFree = union(enum) {
    texture: struct {
        image: vk.Image,
        view: vk.ImageView,
        memory: vk.DeviceMemory,
    },
    buffer: struct {
        buf: vk.Buffer,
        memory: vk.DeviceMemory,
        cpu: ?[*]u8,
    },
    desc_heap: struct {
        pool: vk.DescriptorPool,
        sets: [3]vk.DescriptorSet,
    },
};

const required_device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
    "VK_EXT_shader_object",
    "VK_EXT_descriptor_buffer",
    "VK_KHR_buffer_device_address",
} ++ if (use_swapchain_maintenance1) [_][*:0]const u8{
    "VK_EXT_swapchain_maintenance1",
} else [_][*:0]const u8{};
// Base extensions included unconditionally. Debug/NV/device-fault extensions
// are appended at runtime by init() based on options. See init() for the
// dev_exts ArrayList that replaces this constant at device creation time.

fn hasExtension(extensions: []const vk.ExtensionProperties, wanted: []const u8) bool {
    for (extensions) |extension| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&extension.extension_name)), 0);
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

// Push constant layouts (matches no_gfx_api Graphics_Shader_Push_Constants)
const GraphicsPushConstants = extern struct {
    vert_data: u64,
    frag_data: u64,
    indirect_data: u64,
    screen: [2]f32, // framebuffer size (px); @sizeOf must match PushData
    scene_bda: u64, // the drawable bag (V1b); @sizeOf must match PushData
    perm_bda: u64, // the sorted permutation (V1b); @sizeOf must match PushData
};
const ComputePushConstants = extern struct {
    compute_data: u64,
};

pub fn init(options: Options) !*VkBackend {
    const t_start = std.Io.Timestamp.now(options.io, .real);
    const alloc = options.allocator;
    const enable_tracy_gpu = tracy.enabled and options.timestamp_queries;
    const self = try alloc.create(VkBackend);
    errdefer alloc.destroy(self);
    self.* = .{ .allocator = alloc, .io = options.io };
    self.frames_in_flight = options.frames_in_flight;
    self.enable_debug_utils = options.enable_debug_utils;
    self.enable_nv_checkpoints = options.enable_nv_checkpoints;
    self.enable_nv_diagnostics = options.enable_nv_diagnostics;
    self.enable_device_fault = options.enable_device_fault;
    self.timestamp_queries = options.timestamp_queries;
    self.tracy_gpu_zones = enable_tracy_gpu;
    self.texture_view_cache = std.AutoHashMap(u64, vk.ImageView).init(alloc);
    self.sampler_cache = std.AutoHashMap(u64, vk.Sampler).init(alloc);

    const get_proc_addr = options.loader.get_instance_proc_addr orelse return error.BackendError;
    self.b = vk.BaseWrapper.load(get_proc_addr);
    log.info("Base wrapper loaded", .{});

    const t0 = std.Io.Timestamp.now(options.io, .real);

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = if (options.app_name.len > 0) options.app_name else "noapi",
        .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .p_engine_name = "noapi",
        .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .api_version = @bitCast(vk.makeApiVersion(0, 1, 4, 0)),
    };

    const available_instance_exts = try self.b.enumerateInstanceExtensionPropertiesAlloc(null, alloc);
    defer alloc.free(available_instance_exts);

    var enabled_extensions = std.ArrayList([*:0]const u8).empty;
    defer enabled_extensions.deinit(alloc);

    if (options.loader.get_instance_extensions) |get_exts| {
        try enabled_extensions.appendSlice(alloc, get_exts());
    }
    if (builtin.os.tag == .linux) {
        try enabled_extensions.append(alloc, "VK_KHR_wayland_surface");
        try enabled_extensions.append(alloc, "VK_KHR_xlib_surface");
    }
    try enabled_extensions.append(alloc, "VK_KHR_surface");
    if (hasExtension(available_instance_exts, "VK_KHR_get_surface_capabilities2")) {
        try enabled_extensions.append(alloc, "VK_KHR_get_surface_capabilities2");
    }
    if (options.validation or options.enable_debug_utils) try enabled_extensions.append(alloc, "VK_EXT_debug_utils");
    if (use_swapchain_maintenance1) {
        try enabled_extensions.append(alloc, "VK_EXT_surface_maintenance1");
    }

    const enabled_layers: []const [*:0]const u8 = blk: {
        if (!options.validation) break :blk &.{};
        const layer_props = try self.b.enumerateInstanceLayerPropertiesAlloc(alloc);
        defer alloc.free(layer_props);
        for (layer_props) |lp| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&lp.layer_name)), 0);
            if (std.mem.eql(u8, name, "VK_LAYER_KHRONOS_validation")) break :blk &.{"VK_LAYER_KHRONOS_validation"};
        }
        log.warn("VK_LAYER_KHRONOS_validation not found", .{});
        break :blk &.{};
    };

    var debug_messenger_ci: vk.DebugUtilsMessengerCreateInfoEXT = .{
        .pfn_user_callback = @ptrCast(&debugCallback),
        .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
        .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
    };

    const instance_ci: vk.InstanceCreateInfo = .{
        .p_application_info = &app_info,
        .pp_enabled_layer_names = enabled_layers.ptr,
        .enabled_layer_count = @intCast(enabled_layers.len),
        .pp_enabled_extension_names = enabled_extensions.items.ptr,
        .enabled_extension_count = @intCast(enabled_extensions.items.len),
        .p_next = if (options.validation) @ptrCast(&debug_messenger_ci) else null,
    };

    const instance_handle = try self.b.createInstance(&instance_ci, null);
    self.vki = vk.InstanceWrapper.load(instance_handle, self.b.dispatch.vkGetInstanceProcAddr.?);
    self.instance = vk.InstanceProxy{ .handle = instance_handle, .wrapper = &self.vki };
    {
        const t1 = std.Io.Timestamp.now(options.io, .real);
        const dt = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / @as(f64, std.time.ns_per_ms);
        log.info("Instance created (Vulkan 1.4) — {d:.0}ms", .{dt});
    }

    if (options.validation) {
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&debug_messenger_ci, null);
        log.info("Debug messenger created", .{});
    }

    const devices = try self.instance.enumeratePhysicalDevicesAlloc(alloc);
    defer alloc.free(devices);
    if (devices.len == 0) return error.BackendError;

    var best_score: u32 = 0;
    var best_device: vk.PhysicalDevice = devices[0];
    for (devices) |pd| {
        const props = self.instance.getPhysicalDeviceProperties(pd);
        const score: u32 = switch (props.device_type) {
            .discrete_gpu => 1000,
            .integrated_gpu => 100,
            .virtual_gpu => 50,
            else => 10,
        };
        const qf_props = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pd, alloc);
        defer alloc.free(qf_props);
        const has_graphics = for (qf_props) |qf| {
            if (qf.queue_flags.graphics_bit) break true;
        } else false;
        if (!has_graphics) continue;
        if (score > best_score) {
            best_score = score;
            best_device = pd;
        }
    }
    self.physical_device = best_device;
    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.physical_device);

    const gpu_props = self.instance.getPhysicalDeviceProperties(self.physical_device);
    log.info("GPU: {s}", .{@as([]const u8, &gpu_props.device_name)});

    var driver_props: vk.PhysicalDeviceDriverProperties = .{
        .driver_id = @enumFromInt(0),
        .driver_name = .{0} ** vk.MAX_DRIVER_NAME_SIZE,
        .driver_info = .{0} ** vk.MAX_DRIVER_INFO_SIZE,
        .conformance_version = .{ .major = 0, .minor = 0, .subminor = 0, .patch = 0 },
    };
    var selected_properties: vk.PhysicalDeviceProperties2 = .{
        .p_next = @ptrCast(&driver_props),
        .properties = gpu_props,
    };
    self.instance.getPhysicalDeviceProperties2(self.physical_device, &selected_properties);
    const selected_name = propertyString(&gpu_props.device_name);
    const driver_name = propertyString(&driver_props.driver_name);
    const driver_info = propertyString(&driver_props.driver_info);
    const selected_driver = if (driver_info.len != 0) driver_info else driver_name;
    if (selected_name.len > self.selected_device_name.len) return error.BackendError;
    if (selected_driver.len > self.selected_driver_name.len) return error.BackendError;
    @memcpy(self.selected_device_name[0..selected_name.len], selected_name);
    @memcpy(self.selected_driver_name[0..selected_driver.len], selected_driver);
    self.selected_device_name_len = @intCast(selected_name.len);
    self.selected_driver_name_len = @intCast(selected_driver.len);
    self.selected_vendor_id = gpu_props.vendor_id;
    self.selected_device_id = gpu_props.device_id;

    // Query device limits from Vulkan.
    {
        const L = gpu_props.limits;
        self.device_limits = .{
            .max_anisotropy = L.max_sampler_anisotropy,
            .max_texture_dimension_2d = L.max_image_dimension_2d,
            .max_texture_dimension_3d = L.max_image_dimension_3d,
            .max_texture_array_layers = L.max_image_array_layers,
            .max_push_constants_size = L.max_push_constants_size,
            .max_viewports = L.max_viewports,
            .max_color_attachments = L.max_color_attachments,
            .max_framebuffer_width = L.max_framebuffer_width,
            .max_framebuffer_height = L.max_framebuffer_height,
            .max_framebuffer_layers = L.max_framebuffer_layers,
            .max_compute_work_group_invocations = L.max_compute_work_group_invocations,
            .max_compute_shared_memory_size = L.max_compute_shared_memory_size,
            .min_uniform_buffer_offset_alignment = @intCast(L.min_uniform_buffer_offset_alignment),
            .min_storage_buffer_offset_alignment = @intCast(L.min_storage_buffer_offset_alignment),
            // Feature flags — all enabled by the device features struct in init.
            .shader_object = true,
            .descriptor_buffer = true,
            .buffer_device_address = true,
            .dynamic_rendering = true,
            .timeline_semaphore = true,
            .descriptor_indexing = true,
        };
    }

    const qf_all = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.physical_device, alloc);
    defer alloc.free(qf_all);
    self.queue_family_index = 0;
    var queue_timestamp_valid_bits: u32 = 0;
    for (qf_all, 0..) |qf, i| {
        if (qf.queue_flags.graphics_bit) {
            self.queue_family_index = @intCast(i);
            queue_timestamp_valid_bits = qf.timestamp_valid_bits;
            break;
        }
    }
    log.info("Queue family: {} (timestamp valid bits={})", .{
        self.queue_family_index,
        queue_timestamp_valid_bits,
    });

    const available_device_exts = try self.instance.enumerateDeviceExtensionPropertiesAlloc(
        self.physical_device,
        null,
        alloc,
    );
    defer alloc.free(available_device_exts);
    const has_google_present_timing = hasExtension(available_device_exts, "VK_GOOGLE_display_timing");
    const has_calibrated_timestamps = hasExtension(
        available_device_exts,
        "VK_KHR_calibrated_timestamps",
    );
    const has_ext_present_timing_extensions = extPresentTimingExtensionsAvailable(
        hasExtension(available_device_exts, "VK_EXT_present_timing"),
        hasExtension(available_device_exts, "VK_KHR_present_id2"),
        hasExtension(available_instance_exts, "VK_KHR_get_surface_capabilities2"),
        has_calibrated_timestamps,
    );
    self.has_google_present_timing = has_google_present_timing;
    self.has_surface_capabilities2 = hasExtension(
        available_instance_exts,
        "VK_KHR_get_surface_capabilities2",
    );

    // Query optional feature bits before constructing the enable chain. A
    // feature may only be enabled after the physical device reports support.
    var queried_vk12: vk.PhysicalDeviceVulkan12Features = .{};
    var queried_present_id2: vk.PhysicalDevicePresentId2FeaturesKHR = .{};
    var queried_present_timing: vk.PhysicalDevicePresentTimingFeaturesEXT = .{};
    if (has_ext_present_timing_extensions) {
        queried_present_id2.p_next = @ptrCast(&queried_present_timing);
        queried_vk12.p_next = @ptrCast(&queried_present_id2);
    }
    var queried_features: vk.PhysicalDeviceFeatures2 = .{
        .p_next = @ptrCast(&queried_vk12),
        .features = .{},
    };
    self.instance.getPhysicalDeviceFeatures2(self.physical_device, &queried_features);
    self.has_ext_present_timing = has_ext_present_timing_extensions and
        queried_present_id2.present_id_2 == .true and
        queried_present_timing.present_timing == .true;
    self.tracy_gpu_zones = enable_tracy_gpu and
        has_calibrated_timestamps and queried_vk12.host_query_reset == .true;

    var features: DeviceFeatures = .{};

    features.init(self.tracy_gpu_zones, self.has_ext_present_timing);
    const q_prio = [_]f32{1.0};
    const queue_ci: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = self.queue_family_index,
        .p_queue_priorities = q_prio[0..].ptr,
        .queue_count = 1,
    };
    // Build device extension list at runtime based on feature flags.
    var dev_exts = std.ArrayList([*:0]const u8).empty;
    defer dev_exts.deinit(alloc);
    try dev_exts.appendSlice(alloc, &required_device_extensions);
    if (options.enable_debug_utils) try dev_exts.append(alloc, "VK_EXT_debug_utils");
    if (options.enable_nv_checkpoints) try dev_exts.append(alloc, "VK_NV_device_diagnostic_checkpoints");
    if (options.enable_nv_diagnostics) try dev_exts.append(alloc, "VK_NV_device_diagnostics_config");
    if (options.enable_device_fault) try dev_exts.append(alloc, "VK_EXT_device_fault");
    if (has_calibrated_timestamps and
        needsCalibratedTimestamps(self.has_ext_present_timing, self.tracy_gpu_zones))
    {
        try dev_exts.append(alloc, "VK_KHR_calibrated_timestamps");
    }
    if (self.has_ext_present_timing) {
        try dev_exts.append(alloc, "VK_EXT_present_timing");
        try dev_exts.append(alloc, "VK_KHR_present_id2");
    }
    if (has_google_present_timing) {
        try dev_exts.append(alloc, "VK_GOOGLE_display_timing");
    }
    // NVIDIA diagnostics config for device crash breadcrumbs.
    // Must be chained DIRECTLY to VkDeviceCreateInfo.pNext (NOT inside the features chain).
    var nv_diag_config: ?vk.DeviceDiagnosticsConfigCreateInfoNV = null;
    if (options.enable_nv_diagnostics) {
        nv_diag_config = .{
            .flags = .{ .enable_automatic_checkpoints_bit_nv = true },
            .p_next = @ptrCast(&features.vk10),
        };
    }

    const device_ci: vk.DeviceCreateInfo = .{
        .p_next = if (nv_diag_config) |*cfg| @ptrCast(cfg) else @ptrCast(&features.vk10),
        .p_queue_create_infos = &.{queue_ci},
        .queue_create_info_count = 1,
        .pp_enabled_extension_names = dev_exts.items.ptr,
        .enabled_extension_count = @intCast(dev_exts.items.len),
    };
    // DIAG: enumerate available device extensions to verify required ones.
    for (dev_exts.items) |req| {
        const req_name = std.mem.sliceTo(req, 0);
        if (hasExtension(available_device_exts, req_name)) {
            log.info("DIAG: device extension AVAILABLE: {s}", .{req});
        } else {
            log.warn("DIAG: device extension NOT AVAILABLE: {s}", .{req});
        }
    }
    const device_handle = try self.instance.createDevice(self.physical_device, &device_ci, null);
    self.vkd = vk.DeviceWrapper.load(device_handle, self.vki.dispatch.vkGetDeviceProcAddr.?);
    self.device = vk.DeviceProxy{ .handle = device_handle, .wrapper = &self.vkd };
    const q_handle = self.device.getDeviceQueue(self.queue_family_index, 0);
    self.queue = .{ .handle = q_handle, .wrapper = &self.vkd };

    self.timestamp_period = gpu_props.limits.timestamp_period;
    self.timestamp_valid_bits = @intCast(@min(queue_timestamp_valid_bits, 64));
    const lacks_timestamps = !timestampQueriesAvailable(self.timestamp_period, self.timestamp_valid_bits);
    if (lacks_timestamps) {
        self.timestamp_queries = false;
        self.tracy_gpu_zones = false;
        log.warn(
            "GPU timestamps unavailable (period={d}, valid bits={})",
            .{ self.timestamp_period, self.timestamp_valid_bits },
        );
    }

    // ── Tracy GPU profiling: calibration + queue ──
    if (self.tracy_gpu_zones) {
        var calib: [2]u64 = undefined;
        if (self.calibrateGpuTimestamps(&tracy_calib_info, &calib)) {
            self.tracy_prev_calib_cpu = calib[0];
            self.tracy_queue = tracy.GpuQueue.init(.{
                .gpu_time = calib[1],
                .period = self.timestamp_period,
                .context = 0,
                // Calibrated context: server uses the drift-corrected conversion
                // and accepts per-frame GpuCalibration re-anchors.
                .flags = .{ .calibration = true },
                .type = .vulkan,
                .name = "graphics",
            });
        } else {
            log.warn("Tracy GPU disabled: getCalibratedTimestampsKHR failed", .{});
            self.tracy_gpu_zones = false;
        }
    }

    {
        const t2 = std.Io.Timestamp.now(options.io, .real);
        const dt = @as(f64, @floatFromInt(t2.nanoseconds - t0.nanoseconds)) / @as(f64, std.time.ns_per_ms);
        log.info("Device created (shader objects + descriptor buffer + BDA) — {d:.0}ms total", .{dt});
    }

    // Per-queue timeline semaphore for frame pacing
    self.queue_sem = try self.device.createSemaphore(
        &.{ .p_next = @constCast(&vk.SemaphoreTypeCreateInfo{
            .semaphore_type = .timeline,
            .initial_value = 0,
        }) },
        null,
    );
    self.setDebugName(.semaphore, @intFromEnum(self.queue_sem), "queue_sem");
    log.info("Queue timeline semaphore created", .{});

    // Offscreen command pool (transient, for one-shot command buffers)
    self.offscreen_cmd_pool = try self.device.createCommandPool(&.{
        .queue_family_index = self.queue_family_index,
        .flags = .{ .transient_bit = true },
    }, null);
    self.setDebugName(.command_pool, @intFromEnum(self.offscreen_cmd_pool), "offscreen_cmd_pool");
    log.info("Offscreen command pool created", .{});

    self.submitted_work = .empty;

    // ── Descriptor set layouts (no_gfx_api pattern) ─────────
    {
        const binding_flags: vk.DescriptorBindingFlags = .{
            .update_after_bind_bit = true,
            .partially_bound_bit = true,
        };
        const flags: vk.DescriptorSetLayoutBindingFlagsCreateInfo = .{
            .binding_count = 1,
            .p_binding_flags = @ptrCast(&binding_flags),
        };
        const binding_types = [_]vk.DescriptorType{ .sampled_image, .storage_image, .sampler };
        const binding_counts = [_]u32{ max_textures, max_textures, max_samplers };
        const layout_labels = [_][:0]const u8{ "desc_layout_sampled", "desc_layout_storage", "desc_layout_sampler" };
        for (&binding_types, &binding_counts, &self.desc_layouts, &layout_labels) |dtype, dcount, *layout, label| {
            const bnd: vk.DescriptorSetLayoutBinding = .{
                .binding = 0,
                .descriptor_type = dtype,
                .descriptor_count = dcount,
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true, .compute_bit = true },
            };
            layout.* = try self.device.createDescriptorSetLayout(&.{
                .p_next = @constCast(&flags),
                .flags = .{ .update_after_bind_pool_bit = true },
                .binding_count = 1,
                .p_bindings = @ptrCast(&[_]vk.DescriptorSetLayoutBinding{bnd}),
            }, null);
            self.setDebugName(.descriptor_set_layout, @intFromEnum(layout.*), label);
        }
        log.info("Descriptor set layouts created", .{});
    }

    // ── Shared pipeline layouts (graphics + compute) ────────
    {
        const pc_range_gfx: vk.PushConstantRange = .{
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            .offset = 0,
            .size = @sizeOf(GraphicsPushConstants),
        };
        self.pipeline_layout_graphics = try self.device.createPipelineLayout(&.{
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&pc_range_gfx),
            .set_layout_count = 3,
            .p_set_layouts = @ptrCast(&self.desc_layouts),
        }, null);
        const pc_range_comp: vk.PushConstantRange = .{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            .size = @sizeOf(ComputePushConstants),
        };
        self.pipeline_layout_compute = try self.device.createPipelineLayout(&.{
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&pc_range_comp),
            .set_layout_count = 3,
            .p_set_layouts = @ptrCast(&self.desc_layouts),
        }, null);
        self.setDebugName(.pipeline_layout, @intFromEnum(self.pipeline_layout_graphics), "pipeline_layout_gfx");
        self.setDebugName(.pipeline_layout, @intFromEnum(self.pipeline_layout_compute), "pipeline_layout_comp");
        log.info("Pipeline layouts created", .{});
    }

    {
        const t_end = std.Io.Timestamp.now(options.io, .real);
        const dt = @as(f64, @floatFromInt(t_end.nanoseconds - t_start.nanoseconds)) / @as(f64, std.time.ns_per_ms);
        log.info("VkBackend init complete — {d:.0}ms total", .{dt});
    }

    return self;
}

/// Drain the pending-free list: one deviceWaitIdle, then destroy all deferred resources.
pub fn flushPendingFrees(self: *VkBackend) !void {
    if (self.pending_free.items.len == 0) return;
    {
        const zone_dwi = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
        defer zone_dwi.end();
        self.device.deviceWaitIdle() catch |err| {
            log.warn("flushPendingFrees: deviceWaitIdle failed: {}", .{err});
            if (self.enable_nv_checkpoints) {
                const last_cp = self.queryLastCheckpoint();
                log.warn("flushPendingFrees: last NVIDIA checkpoint marker={}", .{last_cp});
            }
            if (self.enable_device_fault) {
                self.queryDeviceFault();
            }
            return err;
        };
    }
    for (self.pending_free.items) |pf| {
        switch (pf) {
            .buffer => |b| {
                if (b.cpu != null) self.device.unmapMemory(b.memory);
                self.device.destroyBuffer(b.buf, null);
                self.device.freeMemory(b.memory, null);
            },
            .texture => |t| {
                self.device.destroyImageView(t.view, null);
                self.device.destroyImage(t.image, null);
                if (t.memory != .null_handle) self.device.freeMemory(t.memory, null);
            },
            .desc_heap => |d| {
                self.device.freeDescriptorSets(d.pool, d.sets[0..]) catch |err|
                    log.warn("flushPendingFrees: freeDescriptorSets failed: {}", .{err});
                self.device.destroyDescriptorPool(d.pool, null);
            },
        }
    }
    self.pending_free.clearRetainingCapacity();
}

pub fn deinit(self: *VkBackend) void {
    {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        const zone_dwi_d = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
        defer zone_dwi_d.end();
        self.device.deviceWaitIdle() catch |err| log.warn("deinit: deviceWaitIdle failed: {}", .{err});
    }
    // Free all buffer allocations (fixes exit validation errors)
    for (self.allocs.items) |alloc| {
        if (alloc.cpu != null) self.device.unmapMemory(alloc.memory);
        self.device.destroyBuffer(alloc.buf, null);
        self.device.freeMemory(alloc.memory, null);
    }
    self.allocs.deinit(self.allocator);
    // Destroy all texture images + views (skip invalid slots)
    for (self.textures.items) |ti| {
        if (!ti.valid) continue;
        self.device.destroyImageView(ti.default_view, null);
        self.device.destroyImage(ti.image, null);
        if (ti.memory != .null_handle) self.device.freeMemory(ti.memory, null);
    }
    self.textures.deinit(self.allocator);
    // Destroy all descriptor heaps (skip invalid slots)
    for (self.desc_heaps.items) |dh| {
        if (!dh.valid) continue;
        self.device.freeDescriptorSets(dh.pool, dh.sets[0..]) catch |err|
            log.warn("deinit: freeDescriptorSets failed: {}", .{err});
        self.device.destroyDescriptorPool(dh.pool, null);
    }
    self.desc_heaps.deinit(self.allocator);
    self.pending_free.deinit(self.allocator);
    for (self.timestamp_query_sets.items) |entry| {
        if (entry.valid) self.device.destroyQueryPool(entry.pool, null);
    }
    self.timestamp_query_sets.deinit(self.allocator);
    // Destroy cached texture views to prevent VkImageView leaks
    {
        var it = self.texture_view_cache.iterator();
        while (it.next()) |entry| {
            self.device.destroyImageView(entry.value_ptr.*, null);
        }
        self.texture_view_cache.deinit();
    }
    // Destroy cached samplers to prevent VkSampler leaks
    {
        var it = self.sampler_cache.iterator();
        while (it.next()) |entry| {
            self.device.destroySampler(entry.value_ptr.*, null);
        }
        self.sampler_cache.deinit();
    }
    for (self.windows.items) |*win| if (win.valid) destroyWindow(self, win);
    self.windows.deinit(self.allocator);
    self.device.destroyPipelineLayout(self.pipeline_layout_compute, null);
    self.device.destroyPipelineLayout(self.pipeline_layout_graphics, null);
    for (&self.desc_layouts) |*layout| self.device.destroyDescriptorSetLayout(layout.*, null);
    // Free any pending submitted work before destroying the pool.
    for (self.submitted_work.items) |work| {
        self.device.freeCommandBuffers(self.offscreen_cmd_pool, work.cmds);
        self.device.destroyFence(work.fence, null);
        self.allocator.free(work.cmds);
    }
    self.submitted_work.deinit(self.allocator);
    self.device.destroySemaphore(self.queue_sem, null);
    if (self.offscreen_cmd_pool != .null_handle)
        self.device.destroyCommandPool(self.offscreen_cmd_pool, null);
    self.device.destroyDevice(null);
    if (self.debug_messenger != .null_handle)
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);
    self.* = undefined;
}

pub fn numWindows(self: *const VkBackend) u32 {
    return @intCast(self.windows.items.len);
}

pub fn addWindow(
    self: *VkBackend,
    surface: vk.SurfaceKHR,
    initial_extent: Extent2D,
    present_mode: vk.PresentModeKHR,
) !u32 {
    // Find tombstone slot or append.
    for (self.windows.items, 0..) |*w, i| {
        if (!w.valid) {
            log.info("addWindow: reusing tombstone slot {}", .{i});
            const timing_support = self.querySurfacePresentTimingSupport(surface);
            w.* = Window{
                .surface = surface,
                .extent = initial_extent,
                .requested_extent = initial_extent,
                .present_mode = present_mode,
                .frames_in_flight = self.frames_in_flight,
                .timing_mode = resolveSurfacePresentTimingMode(
                    self.has_ext_present_timing,
                    timing_support,
                    self.has_google_present_timing,
                ),
                .present_stage_queries = timing_support.stage orelse .{},
                .present_stage_support = timing_support.supported_stages,
            };
            try initPerFrameSemaphoreLists(self, w);
            try createSwapchainResources(self, w);
            try createPresentSemaphores(self, w);
            if (use_swapchain_maintenance1) {
                try w.present_done_fences.ensureTotalCapacity(self.allocator, self.frames_in_flight);
                var name_buf: [64]u8 = undefined;
                for (0..self.frames_in_flight) |f| {
                    const fence = try self.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
                    const fname = std.fmt.bufPrintSentinel(
                        &name_buf,
                        "present_fence[{}]",
                        .{f},
                        0,
                    ) catch "present_fence";
                    self.setDebugName(.fence, @intFromEnum(fence), fname);
                    w.present_done_fences.appendAssumeCapacity(fence);
                }
            }
            try createPerFrameResources(self, w);
            log.info("addWindow: done (slot {})", .{i});
            return @intCast(i);
        }
    }

    const idx = self.windows.items.len;
    log.info("addWindow: initPerFrameSemaphoreLists", .{});
    const timing_support = self.querySurfacePresentTimingSupport(surface);
    var win: Window = .{
        .surface = surface,
        .extent = initial_extent,
        .requested_extent = initial_extent,
        .present_mode = present_mode,
        .frames_in_flight = self.frames_in_flight,
        .timing_mode = resolveSurfacePresentTimingMode(
            self.has_ext_present_timing,
            timing_support,
            self.has_google_present_timing,
        ),
        .present_stage_queries = timing_support.stage orelse .{},
        .present_stage_support = timing_support.supported_stages,
    };
    try initPerFrameSemaphoreLists(self, &win);
    log.info("addWindow: createSwapchainResources", .{});
    try createSwapchainResources(self, &win);
    log.info("addWindow: createPresentSemaphores", .{});
    try createPresentSemaphores(self, &win);
    if (use_swapchain_maintenance1) {
        try win.present_done_fences.ensureTotalCapacity(self.allocator, self.frames_in_flight);
        var name_buf: [64]u8 = undefined;
        for (0..self.frames_in_flight) |f| {
            const fence = try self.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
            const fname = std.fmt.bufPrintSentinel(
                &name_buf,
                "present_fence[{}]",
                .{f},
                0,
            ) catch "present_fence";
            self.setDebugName(.fence, @intFromEnum(fence), fname);
            win.present_done_fences.appendAssumeCapacity(fence);
        }
    }
    log.info("addWindow: createPerFrameResources", .{});
    try createPerFrameResources(self, &win);
    log.info("addWindow: done (slot {})", .{idx});
    try self.windows.append(self.allocator, win);
    return @intCast(idx);
}

pub fn removeWindow(self: *VkBackend, index: u32) void {
    if (index < self.windows.items.len and self.windows.items[index].valid) {
        // Drain all pending queue operations before destroying this window's resources.
        // The other thread may have submissions referencing our semaphores/fences on the shared queue.
        self.queue_mutex.lockUncancelable(self.io);
        const zone_dwi_r = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
        defer zone_dwi_r.end();
        self.device.deviceWaitIdle() catch |err| log.warn("removeWindow: deviceWaitIdle failed: {}", .{err});
        self.queue_mutex.unlock(self.io);
        destroyWindow(self, &self.windows.items[index]);
        self.windows.items[index].valid = false;
    }
}

pub fn beginFrame(self: *VkBackend, window_index: u32) !FrameSchedule {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;
    win.slop_ns = 0;

    // Handle resize
    if (win.needs_resize) {
        const zone = tracy.Zone.begin(.{ .src = @src() });
        defer zone.end();
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        if (use_swapchain_maintenance1) {
            for (win.present_done_fences.items) |f| {
                const t_wf_resize = std.Io.Timestamp.now(self.io, .awake);
                const zone_wf_resize = tracy.Zone.begin(.{ .name = "waitFences", .src = @src(), .color = .tomato });
                defer zone_wf_resize.end();
                _ = try self.device.waitForFences(
                    &[_]vk.Fence{f},
                    .true,
                    std.math.maxInt(u64),
                );
                win.slop_ns += @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - t_wf_resize.nanoseconds);
            }
        } else {
            const t_dwi = std.Io.Timestamp.now(self.io, .awake);
            const zone_dwi_bf = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
            defer zone_dwi_bf.end();
            try self.device.deviceWaitIdle();
            win.slop_ns += @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - t_dwi.nanoseconds);
        }
        try recreateSwapchain(self, win);
        win.needs_resize = false;
        win.resize_throttle = 2;
    }

    const acq_fence = try self.device.createFence(&.{}, null);
    defer self.device.destroyFence(acq_fence, null);

    const recreated = blk: {
        const zone_acq = tracy.Zone.begin(.{ .name = "acquireImage", .src = @src(), .color = .tomato });
        defer zone_acq.end();
        const t_acq = std.Io.Timestamp.now(self.io, .awake);
        const acq = self.device.acquireNextImageKHR(
            win.swapchain,
            std.math.maxInt(u64),
            .null_handle,
            acq_fence,
        ) catch |e| {
            if (e == error.OutOfDateKHR) {
                win.needs_resize = true;
                return error.OutOfDateKHR;
            }
            return e;
        };
        win.image_index = acq.image_index;
        _ = try self.device.waitForFences(([_]vk.Fence{acq_fence})[0..], .true, std.math.maxInt(u64));
        win.slop_ns += @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - t_acq.nanoseconds);
        break :blk acq.result == .suboptimal_khr;
    };

    // Wait for previous frame to finish before reusing pool/fence
    {
        const t_wf_cmd = std.Io.Timestamp.now(self.io, .awake);
        const zone_wf_cmd = tracy.Zone.begin(.{ .name = "waitFences", .src = @src(), .color = .tomato });
        defer zone_wf_cmd.end();
        _ = try self.device.waitForFences(win.cmd_pool_ready.items[frame..][0..1], .true, std.math.maxInt(u64));
        win.slop_ns += @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - t_wf_cmd.nanoseconds);
    }
    try self.device.resetFences(win.cmd_pool_ready.items[frame..][0..1]);
    if (self.tracy_gpu_zones) try self.collectTracyGpuQueries(win, frame);
    {
        const zone_rcp = tracy.Zone.begin(.{ .name = "resetCmdPool", .src = @src(), .color = .tomato });
        defer zone_rcp.end();
        try self.device.resetCommandPool(win.cmd_pools.items[frame], .{});
    }

    try self.flushPendingFrees();

    // Begin command buffer and transition UNDEFINED -> GENERAL
    win.cmd_buffers.items[frame].beginCommandBuffer(&.{ .flags = .{ .one_time_submit_bit = true } }) catch |err|
        log.err("beginFrame: beginCommandBuffer failed: {}", .{err});
    {
        var name_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&name_buf, "Frame {}", .{self.queue_counter}, 0) catch "Frame";
        self.cmdBeginDebugLabel(win.cmd_buffers.items[frame].handle, label, .{ 0.2, 0.6, 1.0, 1.0 });
    }
    // Tracy GPU frame zone: labels which swapchain image this frame renders into,
    // so in-flight frames are identifiable on the GPU timeline.
    if (self.tracy_gpu_zones) self.beginFrameGpuZone(win, frame, win.image_index);
    {
        const barrier: vk.ImageMemoryBarrier2 = .{
            .image = win.images.items[win.image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .old_layout = .undefined,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
        };
        win.cmd_buffers.items[frame].pipelineBarrier2(&vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    return .{ .next_vblank_us = 16667, .swapchain_recreated = recreated };
}

pub fn currentSwapchainImage(self: *const VkBackend, window_index: u32) TextureHandle {
    const win = &self.windows.items[window_index];
    return .{
        .tag = .swapchain,
        .swapchain = .{ .window_index = window_index, .image_index = win.image_index },
    };
}

pub fn endFrame(self: *VkBackend, window_index: u32, present: ?PresentInfo) !FrameResult {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;
    const img_idx = win.image_index;
    var frame_result = frameResultForPresentQueue(.success);

    // Validate timing IDs before any command recording, submission, or state
    // mutation. All later timing setup is infallible stack construction.
    if (present) |p| {
        if (p.timing_id) |timing_id| {
            if (p.blit_to_swapchain) {
                try validatePresentTimingRequest(
                    win.timing_mode,
                    win.last_present_timing_id,
                    timing_id,
                    win.outstanding_timed_presents,
                    max_present_feedback,
                );
            } else {
                try validatePresentTimingId(win.timing_mode, win.last_present_timing_id, timing_id);
            }
        }
    }

    self.cmdInsertDebugLabel(win.cmd_buffers.items[frame].handle, "Present", .{ 0.2, 0.4, 0.8, 1.0 });

    // Transition GENERAL -> PRESENT_SRC_KHR
    {
        const barrier: vk.ImageMemoryBarrier2 = .{
            .image = win.images.items[img_idx],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .old_layout = .general,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
            .dst_access_mask = .{},
        };
        win.cmd_buffers.items[frame].pipelineBarrier2(&vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    if (self.tracy_gpu_zones) self.endFrameGpuZone(win, frame);

    try win.cmd_buffers.items[frame].endCommandBuffer();

    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);

    // Submit with timeline semaphore for GPU serialization (no_gfx_api pattern)
    const wait_val = self.queue_counter;
    const signal_val = wait_val + 1;
    const present_sem = win.present_sems.items[img_idx];

    // Build wait list: queue_sem + any user-added wait semaphores
    var wait_sems_buf: [16]vk.Semaphore = undefined;
    var wait_vals_buf: [16]u64 = undefined;
    var stage_mask_buf: [16]vk.PipelineStageFlags = undefined;
    var wc: u32 = 0;
    wait_sems_buf[wc] = self.queue_sem;
    wait_vals_buf[wc] = wait_val;
    stage_mask_buf[wc] = .{ .all_commands_bit = true };
    wc += 1;
    const wait_count = @min(win.wait_sems.items[frame].items.len, 16 - wc);
    for (
        win.wait_sems.items[frame].items[0..wait_count],
        win.wait_values.items[frame].items[0..wait_count],
        wc..,
    ) |s, v, i| {
        wait_sems_buf[i] = s;
        wait_vals_buf[i] = v;
        stage_mask_buf[i] = .{ .all_commands_bit = true };
        wc += 1;
    }

    // Build signal list: queue_sem + present_sem + any user-added signal semaphores
    var signal_sems_buf: [16]vk.Semaphore = undefined;
    var signal_vals_buf: [16]u64 = undefined;
    var sc: u32 = 0;
    signal_sems_buf[sc] = self.queue_sem;
    signal_vals_buf[sc] = signal_val;
    sc += 1;
    signal_sems_buf[sc] = present_sem;
    signal_vals_buf[sc] = 0;
    sc += 1;
    const signal_count = @min(win.signal_sems.items[frame].items.len, 16 - sc);
    for (
        win.signal_sems.items[frame].items[0..signal_count],
        win.signal_values.items[frame].items[0..signal_count],
        sc..,
    ) |s, v, i| {
        signal_sems_buf[i] = s;
        signal_vals_buf[i] = v;
        sc += 1;
    }

    const ts_info: vk.TimelineSemaphoreSubmitInfo = .{
        .wait_semaphore_value_count = wc,
        .p_wait_semaphore_values = &wait_vals_buf,
        .signal_semaphore_value_count = sc,
        .p_signal_semaphore_values = &signal_vals_buf,
    };
    const cb_handle = win.cmd_buffers.items[frame].handle;
    {
        const zone_qs = tracy.Zone.begin(.{ .name = "queueSubmit", .src = @src(), .color = .tomato });
        defer zone_qs.end();
        try self.queue.submit(&.{vk.SubmitInfo{
            .p_next = @constCast(&ts_info),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cb_handle),
            .wait_semaphore_count = wc,
            .p_wait_semaphores = &wait_sems_buf,
            .p_wait_dst_stage_mask = &stage_mask_buf,
            .signal_semaphore_count = sc,
            .p_signal_semaphores = &signal_sems_buf,
        }}, win.cmd_pool_ready.items[frame]);
    }
    // Clear per-frame semaphore arrays for next use
    win.wait_sems.items[frame].clearRetainingCapacity();
    win.wait_values.items[frame].clearRetainingCapacity();
    win.signal_sems.items[frame].clearRetainingCapacity();
    win.signal_values.items[frame].clearRetainingCapacity();
    self.queue_counter = signal_val;

    if (present) |p| {
        if (p.blit_to_swapchain) {
            var fence_info: if (use_swapchain_maintenance1) vk.SwapchainPresentFenceInfoEXT else void = undefined;
            var present_id2_info: vk.PresentId2KHR = undefined;
            var present_times_info: vk.PresentTimesInfoGOOGLE = undefined;
            var google_time: vk.PresentTimeGOOGLE = undefined;
            var present_timings_info: vk.PresentTimingsInfoEXT = undefined;
            var timing_info_ext: vk.PresentTimingInfoEXT = undefined;
            var timing_id_copy: u64 = 0;
            const base_present: vk.PresentInfoKHR = .{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&present_sem),
                .swapchain_count = 1,
                .p_swapchains = @ptrCast(&win.swapchain),
                .p_image_indices = @ptrCast(&img_idx),
            };
            var af_present = if (use_swapchain_maintenance1) blk: {
                const pfence = win.present_done_fences.items[frame];
                // Wait for this frame's previous present to complete
                const t_wf_p = std.Io.Timestamp.now(self.io, .awake);
                const zone_wf_p = tracy.Zone.begin(.{ .name = "waitFences", .src = @src(), .color = .tomato });
                defer zone_wf_p.end();
                _ = try self.device.waitForFences(
                    &[_]vk.Fence{pfence},
                    .true,
                    std.math.maxInt(u64),
                );
                win.slop_ns += @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - t_wf_p.nanoseconds);
                try self.device.resetFences(&[_]vk.Fence{pfence});
                fence_info = .{ .swapchain_count = 1, .p_fences = @ptrCast(&pfence) };
                var chained = base_present;
                chained.p_next = @ptrCast(&fence_info);
                break :blk chained;
            } else base_present;
            const present_tail = af_present.p_next;
            if (p.timing_id) |timing_id| {
                timing_id_copy = timing_id;
                const stage_bits: u32 = switch (win.timing_mode) {
                    .ext => @bitCast(win.present_stage_queries),
                    .google, .unsupported => 0,
                };
                const time_domain_id: u64 = if (win.timing_mode == .ext)
                    win.time_domain_id
                else
                    0;
                win.present_timing_diagnostics.notePresentRequest(
                    win.timing_mode,
                    timing_id,
                    stage_bits,
                    time_domain_id,
                );
                switch (win.timing_mode) {
                    .ext => {
                        const stage = win.present_stage_queries;
                        present_timings_info = .{
                            .p_next = present_tail,
                            .swapchain_count = 1,
                            .p_timing_infos = @ptrCast(&timing_info_ext),
                        };
                        timing_info_ext = .{
                            .target_time = 0,
                            .time_domain_id = win.time_domain_id,
                            .present_stage_queries = stage,
                            .target_time_domain_present_stage = stage,
                        };
                        present_id2_info = .{
                            .p_next = @ptrCast(&present_timings_info),
                            .swapchain_count = 1,
                            .p_present_ids = @ptrCast(&timing_id_copy),
                        };
                        af_present.p_next = @ptrCast(&present_id2_info);
                    },
                    .google => {
                        google_time = .{ .present_id = @intCast(timing_id), .desired_present_time = 0 };
                        present_times_info = .{
                            .p_next = present_tail,
                            .swapchain_count = 1,
                            .p_times = @ptrCast(&google_time),
                        };
                        af_present.p_next = @ptrCast(&present_times_info);
                    },
                    .unsupported => unreachable,
                }
            }
            const t_present = std.Io.Timestamp.now(self.io, .awake);
            const zone_present = tracy.Zone.begin(.{ .name = "queuePresent", .src = @src(), .color = .tomato });
            defer zone_present.end();
            if (self.queue.presentKHR(&af_present)) |present_result| {
                const present_result_kind = presentQueueResult(present_result);
                frame_result = frameResultForPresentQueue(present_result_kind);
                if (p.timing_id != null) {
                    win.present_timing_diagnostics.notePresentResult(present_result_kind);
                }
                if (p.timing_id) |timing_id| {
                    win.last_present_timing_id = timing_id;
                    win.outstanding_timed_presents += 1;
                    if (win.first_timed_present_start_ns == null) {
                        win.first_timed_present_start_ns = t_present;
                        win.present_timing_diagnostics.first_timed_present_start_ns = t_present.nanoseconds;
                    }
                    win.present_timing_diagnostics.outstanding_timed_presents = win.outstanding_timed_presents;
                }
                if (win.retired_swapchain != .null_handle) {
                    self.device.destroySwapchainKHR(win.retired_swapchain, null);
                    win.retired_swapchain = .null_handle;
                }
                // Annotate the presentation on the CPU timeline; the GPU frame zone
                // named "img {M}" identifies this frame on the GPU timeline.
                if (self.tracy_gpu_zones) {
                    var msg_buf: [64]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &msg_buf,
                        "present frame {d} (img {d})",
                        .{ signal_val, win.image_index },
                    ) catch "present frame";
                    tracy.message(.{ .text = msg, .color = .green });
                }
            } else |e| {
                const present_failure = presentQueueFailure(e);
                if (p.timing_id != null) {
                    win.present_timing_diagnostics.notePresentFailure(present_failure);
                }
                frame_result = notePresentQueueFailure(win, e);
                if (present_failure == .timing_queue_full) {
                    return e;
                }
                if (!frame_result.present_out_of_date) {
                    log.warn("endFrame: present failed: {}", .{e});
                }
            }
            win.slop_ns += @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - t_present.nanoseconds);
        }
    }

    advanceFrame(win, frame);
    return frame_result;
}
pub fn getCurrentCmdBuf(self: *VkBackend, window_index: u32) CommandBufferHandle {
    const win = &self.windows.items[window_index];
    return win.cmd_buffers.items[win.frame_index].handle;
}

pub fn waitIdle(self: *VkBackend) !void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    const zone_dwi_w = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
    defer zone_dwi_w.end();
    self.device.deviceWaitIdle() catch |err| {
        log.warn("waitIdle: deviceWaitIdle failed: {}", .{err});
        if (self.enable_nv_checkpoints) {
            const last_cp = self.queryLastCheckpoint();
            log.warn("waitIdle: last NVIDIA checkpoint marker={}", .{last_cp});
        }
        return err;
    };
    self.reclaimSubmittedWork();
}

const TimelineWait = struct {
    semaphore: SemaphoreHandle,
    value: u64,
};

const TimelineSignal = struct {
    semaphore: SemaphoreHandle,
    value: u64,
};

fn queueSubmitTracked(
    self: *VkBackend,
    handles: []const CommandBufferHandle,
    wait: ?TimelineWait,
    signal: ?TimelineSignal,
) !void {
    if (handles.len == 0) return;
    if (wait) |wait_timeline| {
        if (signal) |signal_timeline| {
            if (wait_timeline.semaphore == signal_timeline.semaphore and
                wait_timeline.value >= signal_timeline.value)
            {
                return error.InvalidTimelineOrder;
            }
        }
    }

    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);

    const cmds_copy = try self.allocator.dupe(vk.CommandBuffer, handles);
    var tracking_owned = true;
    defer if (tracking_owned) self.allocator.free(cmds_copy);

    try self.submitted_work.ensureUnusedCapacity(self.allocator, 1);
    const fence = try self.device.createFence(&.{}, null);
    var submitted = false;
    errdefer {
        if (!submitted) {
            self.device.freeCommandBuffers(self.offscreen_cmd_pool, handles);
            self.device.destroyFence(fence, null);
        }
    }

    // The preflight above leaves all fallible ownership operations complete before
    // command buffers are ended or submitted.
    if (self.enable_nv_checkpoints) {
        for (handles) |h| {
            self.checkpoint_counter += 1;
            const checkpoint = self.checkpoint_counter;
            self.device.cmdSetCheckpointNV(h, @ptrCast(&checkpoint));
        }
    }
    for (handles) |h| try self.device.endCommandBuffer(h);

    var timeline_info: vk.TimelineSemaphoreSubmitInfo = .{};
    var wait_semaphores: [1]vk.Semaphore = undefined;
    var wait_values: [1]u64 = undefined;
    var wait_stage_masks: [1]vk.PipelineStageFlags = undefined;
    var signal_semaphores: [1]vk.Semaphore = undefined;
    var signal_values: [1]u64 = undefined;
    if (wait) |timeline| {
        wait_semaphores[0] = timeline.semaphore;
        wait_values[0] = timeline.value;
        wait_stage_masks[0] = .{ .all_commands_bit = true };
    }
    if (signal) |timeline| {
        signal_semaphores[0] = timeline.semaphore;
        signal_values[0] = timeline.value;
    }
    timeline_info = .{
        .wait_semaphore_value_count = if (wait != null) 1 else 0,
        .p_wait_semaphore_values = if (wait != null) @ptrCast(&wait_values) else null,
        .signal_semaphore_value_count = if (signal != null) 1 else 0,
        .p_signal_semaphore_values = if (signal != null) @ptrCast(&signal_values) else null,
    };
    const submit_info: vk.SubmitInfo = .{
        .p_next = if (wait != null or signal != null) @ptrCast(&timeline_info) else null,
        .command_buffer_count = @intCast(handles.len),
        .p_command_buffers = handles.ptr,
        .wait_semaphore_count = if (wait != null) 1 else 0,
        .p_wait_semaphores = if (wait != null) @ptrCast(&wait_semaphores) else null,
        .p_wait_dst_stage_mask = if (wait != null) @ptrCast(&wait_stage_masks) else null,
        .signal_semaphore_count = if (signal != null) 1 else 0,
        .p_signal_semaphores = if (signal != null) @ptrCast(&signal_semaphores) else null,
    };
    {
        const zone_qs = tracy.Zone.begin(.{ .name = "queueSubmit", .src = @src(), .color = .tomato });
        defer zone_qs.end();
        try self.queue.submit(&.{submit_info}, fence);
    }

    submitted = true;
    self.submitted_work.appendAssumeCapacity(.{ .cmds = cmds_copy, .fence = fence });
    tracking_owned = false;
}

pub fn queueSubmit(self: *VkBackend, handles: []const CommandBufferHandle) !void {
    try self.queueSubmitTracked(handles, null, null);
}

/// Set an NVIDIA diagnostic checkpoint in a command buffer.
/// After DeviceLost, queryCheckpointData() returns the last checkpoint reached.
pub fn setCheckpoint(self: *VkBackend, cmd: CommandBufferHandle) void {
    if (!self.enable_nv_checkpoints) return;
    self.checkpoint_counter += 1;
    const cp = self.checkpoint_counter;
    self.device.cmdSetCheckpointNV(cmd, @ptrCast(&cp));
}

/// Human-readable name for a Vulkan pipeline stage bit (PipelineStageFlags2).
fn stageName(stage: vk.PipelineStageFlags) [:0]const u8 {
    if (stage.top_of_pipe_bit) return "TOP_OF_PIPE";
    if (stage.draw_indirect_bit) return "DRAW_INDIRECT";
    if (stage.vertex_input_bit) return "VERTEX_INPUT";
    if (stage.vertex_shader_bit) return "VERTEX_SHADER";
    if (stage.tessellation_control_shader_bit) return "TESSELLATION_CONTROL";
    if (stage.tessellation_evaluation_shader_bit) return "TESSELLATION_EVAL";
    if (stage.geometry_shader_bit) return "GEOMETRY_SHADER";
    if (stage.fragment_shader_bit) return "FRAGMENT_SHADER";
    if (stage.early_fragment_tests_bit) return "EARLY_FRAGMENT_TESTS";
    if (stage.late_fragment_tests_bit) return "LATE_FRAGMENT_TESTS";
    if (stage.color_attachment_output_bit) return "COLOR_ATTACHMENT_OUTPUT";
    if (stage.compute_shader_bit) return "COMPUTE_SHADER";
    if (stage.transfer_bit) return "TRANSFER";
    if (stage.bottom_of_pipe_bit) return "BOTTOM_OF_PIPE";
    if (stage.host_bit) return "HOST";
    if (stage.all_commands_bit) return "ALL_COMMANDS";
    if (stage.mesh_shader_bit_ext) return "MESH_SHADER_EXT";
    if (stage.task_shader_bit_ext) return "TASK_SHADER_EXT";
    return "UNKNOWN";
}

/// Human-readable name for DeviceFaultAddressTypeEXT.
fn addressTypeName(t: vk.DeviceFaultAddressTypeEXT) [:0]const u8 {
    return switch (t) {
        .none_ext => "NONE",
        .read_invalid_ext => "READ_INVALID",
        .write_invalid_ext => "WRITE_INVALID",
        .execute_invalid_ext => "EXECUTE_INVALID",
        .instruction_pointer_unknown_ext => "INSTR_PTR_UNKNOWN",
        .instruction_pointer_invalid_ext => "INSTR_PTR_INVALID",
        .instruction_pointer_fault_ext => "INSTR_PTR_FAULT",
        _ => "UNKNOWN",
    };
}

/// Query and log VK_EXT_device_fault info after device loss.
/// Provides the driver's free-form fault description and any fault addresses.
pub fn queryDeviceFault(self: *VkBackend) void {
    if (!self.enable_device_fault) return;
    log.warn("═══ DEVICE FAULT ═══", .{});
    var counts: vk.DeviceFaultCountsEXT = .{};
    if (self.device.getDeviceFaultInfoEXT(&counts, null)) |_| {
        log.warn("  Fault info available: {d} addresses, {d} vendor records, {d} bytes vendor binary", .{
            counts.address_info_count, counts.vendor_info_count, @as(u64, counts.vendor_binary_size),
        });
        var vendor_infos: [4]vk.DeviceFaultVendorInfoEXT = undefined;
        var addr_infos: [16]vk.DeviceFaultAddressInfoEXT = undefined;
        var info: vk.DeviceFaultInfoEXT = undefined;
        for (&info.description) |*c| c.* = 0;
        info.s_type = .device_fault_info_ext;
        info.p_next = null;
        counts.address_info_count = addr_infos.len;
        counts.vendor_info_count = vendor_infos.len;
        info.p_vendor_infos = @ptrCast(&vendor_infos[0]);
        info.p_address_infos = @ptrCast(&addr_infos[0]);
        if (self.device.getDeviceFaultInfoEXT(&counts, &info)) |_| {
            const desc = std.mem.sliceTo(&info.description, 0);
            if (desc.len > 0) log.warn("  Description: {s}", .{desc});
            const vc = @min(counts.vendor_info_count, vendor_infos.len);
            if (vc > 0) {
                log.warn("  Vendor info ({d})", .{vc});
                for (vendor_infos[0..vc]) |vi| {
                    const vd = std.mem.sliceTo(&vi.description, 0);
                    log.warn("    [{s}] code=0x{x} data=0x{x}", .{ vd, vi.vendor_fault_code, vi.vendor_fault_data });
                }
            }
            const ac = @min(counts.address_info_count, addr_infos.len);
            if (ac > 0) {
                log.warn("  Fault addresses ({d})", .{ac});
                for (addr_infos[0..ac]) |ai| {
                    const atype = addressTypeName(ai.address_type);
                    log.warn(
                        "    [{s}] addr=0x{x} precision={d} bytes",
                        .{ atype, ai.reported_address, @as(u64, ai.address_precision) },
                    );
                }
            } else {
                log.warn("  No address info — fault may be a TDR timeout, not a page fault", .{});
            }
        } else |e| {
            log.warn("  Query failed: {}", .{e});
        }
    } else |e| {
        log.warn("  Query not available (device not lost or extension not supported): {}", .{e});
    }
}

/// Query and log NVIDIA checkpoint data after device loss.
/// Returns the last checkpoint value that was reached by the GPU before the fault.
pub fn queryLastCheckpoint(self: *VkBackend) u32 {
    if (!self.enable_nv_checkpoints) return 0;
    var data_count: u32 = 0;
    self.device.getQueueCheckpointDataNV(self.queue.handle, &data_count, null);
    log.warn("═══ NVIDIA GPU CHECKPOINTS ═══", .{});
    if (data_count > 0) {
        const count = @min(data_count, 64);
        var data: [64]vk.CheckpointDataNV = undefined;
        for (&data) |*d| {
            d.* = .{
                .s_type = .checkpoint_data_nv,
                .p_next = null,
                .stage = .{},
                .p_checkpoint_marker = @ptrCast(&d.stage),
            };
        }
        var query_count: u32 = count;
        self.device.getQueueCheckpointDataNV(self.queue.handle, &query_count, &data);
        log.warn("  stage        pipeline                         marker", .{});
        log.warn("  ------------  ------------------------------  --------", .{});
        for (data[0..count]) |*cp| {
            const marker_ptr: *align(1) const u32 = @ptrCast(cp.p_checkpoint_marker);
            const marker: u32 = marker_ptr.*;
            const sname = stageName(cp.stage);
            log.warn("  stage=0x{x:0>8}  {s:<30}  0x{x}", .{ @as(u32, @bitCast(cp.stage)), sname, marker });
        }
        log.warn("  GPU fault occurred between the highest completed stage and the next", .{});
        const last = data[count - 1];
        const marker_ptr: *align(1) const u32 = @ptrCast(last.p_checkpoint_marker);
        const marker: u32 = marker_ptr.*;
        return marker;
    }
    log.warn("  No checkpoints found — GPU fault before any checkpoint was reached.", .{});
    return 0;
}

pub fn queueSubmitSignal(
    self: *VkBackend,
    handles: []const CommandBufferHandle,
    sem: SemaphoreHandle,
    value: u64,
) !void {
    try self.queueSubmitTracked(handles, null, .{ .semaphore = sem, .value = value });
}

pub fn queueSubmitWaitSignal(
    self: *VkBackend,
    handles: []const CommandBufferHandle,
    wait_sem: SemaphoreHandle,
    wait_value: u64,
    signal_sem: SemaphoreHandle,
    signal_value: u64,
) !void {
    try self.queueSubmitTracked(
        handles,
        .{ .semaphore = wait_sem, .value = wait_value },
        .{ .semaphore = signal_sem, .value = signal_value },
    );
}

fn reclaimSubmittedWork(self: *VkBackend) void {
    var index: usize = 0;
    while (index < self.submitted_work.items.len) {
        const work = self.submitted_work.items[index];
        const status = self.device.getFenceStatus(work.fence) catch |err| {
            log.warn("reclaimSubmittedWork: getFenceStatus failed: {}", .{err});
            index += 1;
            continue;
        };
        if (status == .success) {
            self.device.freeCommandBuffers(self.offscreen_cmd_pool, work.cmds);
            self.device.destroyFence(work.fence, null);
            self.allocator.free(work.cmds);
            _ = self.submitted_work.swapRemove(index);
        } else {
            index += 1;
        }
    }
}

pub fn commandsBegin(self: *VkBackend) !CommandBufferHandle {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    self.reclaimSubmittedWork();

    var cb: vk.CommandBuffer = undefined;
    try self.device.allocateCommandBuffers(&.{
        .command_pool = self.offscreen_cmd_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cb));
    try self.device.beginCommandBuffer(cb, &.{ .flags = .{ .one_time_submit_bit = true } });
    return cb;
}

pub fn queueWaitIdle(self: *VkBackend) !void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    const zone_qw = tracy.Zone.begin(.{ .name = "queueWait", .src = @src(), .color = .tomato });
    defer zone_qw.end();
    try self.queue.waitIdle();
}
pub fn timestampInfo(self: *const VkBackend) ?TimestampInfo {
    if (!self.timestamp_queries) return null;
    return .{
        .period_ns = @floatCast(self.timestamp_period),
        .valid_bits = self.timestamp_valid_bits,
    };
}

fn timestampQueryEntry(self: *VkBackend, handle: TimestampQueryHandle) !*TimestampQueryEntry {
    const raw = @intFromEnum(handle);
    if (raw == 0) return error.InvalidTimestampHandle;
    const index: usize = @intCast(raw - 1);
    if (index >= self.timestamp_query_sets.items.len) return error.InvalidTimestampHandle;
    const entry = &self.timestamp_query_sets.items[index];
    if (!entry.valid) return error.InvalidTimestampHandle;
    return entry;
}

pub fn timestampQuerySetCreate(self: *VkBackend, count: u32) !TimestampQueryHandle {
    if (!self.timestamp_queries) return error.TimestampQueriesUnsupported;
    try TimestampQuerySet.validateQueryRange(count, 0, count);
    const pool = try self.device.createQueryPool(&.{
        .query_type = .timestamp,
        .query_count = count,
    }, null);
    errdefer self.device.destroyQueryPool(pool, null);

    for (self.timestamp_query_sets.items, 0..) |*entry, i| {
        if (!entry.valid) {
            entry.* = .{ .valid = true, .pool = pool, .count = count };
            return @enumFromInt(@as(u32, @intCast(i + 1)));
        }
    }
    if (self.timestamp_query_sets.items.len >= std.math.maxInt(u32)) {
        return error.TooManyTimestampQuerySets;
    }
    try self.timestamp_query_sets.append(self.allocator, .{
        .valid = true,
        .pool = pool,
        .count = count,
    });
    return @enumFromInt(@as(u32, @intCast(self.timestamp_query_sets.items.len)));
}

pub fn timestampQuerySetDestroy(self: *VkBackend, handle: TimestampQueryHandle) void {
    const raw = @intFromEnum(handle);
    if (raw == 0) return;
    const index: usize = @intCast(raw - 1);
    if (index >= self.timestamp_query_sets.items.len) return;
    const entry = &self.timestamp_query_sets.items[index];
    if (!entry.valid) return;
    const pool = entry.pool;
    entry.* = .{};
    self.device.destroyQueryPool(pool, null);
}

pub fn timestampQuerySetRead(
    self: *VkBackend,
    handle: TimestampQueryHandle,
    first: u32,
    out: []u64,
) !void {
    if (!self.timestamp_queries) return error.TimestampQueriesUnsupported;
    if (out.len == 0 or out.len > std.math.maxInt(u32)) return error.InvalidTimestampRange;
    const entry = try self.timestampQueryEntry(handle);
    try TimestampQuerySet.validateQueryRange(entry.count, first, @intCast(out.len));
    const result = try self.device.getQueryPoolResults(
        entry.pool,
        first,
        @intCast(out.len),
        out.len * @sizeOf(u64),
        @ptrCast(out.ptr),
        @sizeOf(u64),
        .{ .@"64_bit" = true },
    );
    if (result == .not_ready) return error.NotReady;
}
pub fn presentTimingSupported(self: *const VkBackend, window_index: u32) bool {
    if (window_index >= self.windows.items.len) return false;
    return self.windows.items[window_index].timing_mode != .unsupported;
}

/// Poll completed presentation feedback into caller storage without allocating.
/// The available record count is probed first; OutputTooSmall is returned before
/// any record is consumed so feedback is never truncated or dropped.
pub fn pollPresentFeedback(self: *VkBackend, window_index: u32, out: []PresentFeedback) !usize {
    const win = &self.windows.items[window_index];
    switch (win.timing_mode) {
        .unsupported => return error.PresentTimingUnsupported,
        .ext => return self.pollPresentFeedbackExt(win, out),
        .google => return self.pollPresentFeedbackGoogle(win, out),
    }
}
fn googlePresentTimingIdRangeUsable(win: *const Window) bool {
    const max_google_id: u64 = std.math.maxInt(u32);
    return win.last_present_timing_id < max_google_id and
        win.last_feedback_id < max_google_id;
}

/// Abandon the current timing measurement without retaining its ownership.
/// EXT failures may restart on the independently enabled GOOGLE backend when
/// the next Google ID remains representable; a failed Google block is terminal.
/// Present and feedback high-water marks remain validation state across
/// backend transitions, preventing stale or duplicate IDs after fallback.
fn abandonPresentTiming(win: *Window, google_available: bool) void {
    const use_google = win.timing_mode == .ext and
        google_available and
        googlePresentTimingIdRangeUsable(win);
    win.timing_mode = if (use_google) .google else .unsupported;
    win.present_stage_queries = .{};
    win.present_stage_support = .{};
    win.present_time_domain_count = 0;
    win.time_domain_id = 0;
    win.time_domain_valid = false;
    win.outstanding_timed_presents = 0;
    win.first_timed_present_start_ns = null;
    win.present_timing_diagnostics.mode = win.timing_mode;
    win.present_timing_diagnostics.outstanding_timed_presents = 0;
    win.present_timing_diagnostics.watchdog_triggered = true;
}

fn pollPresentFeedbackExt(self: *VkBackend, win: *Window, out: []PresentFeedback) !usize {
    // The count probe must pass a true null timing pointer. The nullable
    // ABI mirror preserves the required C layout while avoiding a dummy
    // address in the generated non-null Vulkan declaration.
    var probe_properties: PastPresentationTimingPropertiesProbe = .{};
    const probe_info: vk.PastPresentationTimingInfoEXT = .{
        .flags = .{},
        .swapchain = win.swapchain,
    };
    const probe_result = self.device.getPastPresentationTimingEXT(
        &probe_info,
        @ptrCast(&probe_properties),
    ) catch |err| {
        win.present_timing_diagnostics.noteExtProbe(
            .failed,
            0,
            probe_properties.timing_properties_counter,
            probe_properties.time_domains_counter,
        );
        return err;
    };
    const available_u32 = probe_properties.presentation_timing_count;
    win.present_timing_diagnostics.noteExtProbe(
        presentTimingCallResult(probe_result),
        available_u32,
        probe_properties.timing_properties_counter,
        probe_properties.time_domains_counter,
    );
    if (available_u32 == 0) {
        if (win.outstanding_timed_presents != 0) {
            win.present_timing_diagnostics.ext_empty_probe_polls +|= 1;
            const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
            const first_pending_start_ns = if (win.first_timed_present_start_ns) |start|
                start.nanoseconds
            else
                null;
            win.present_timing_diagnostics.watchdog_last_now_ns = now_ns;
            win.present_timing_diagnostics.watchdog_elapsed_ns =
                if (first_pending_start_ns) |start| if (now_ns >= start) now_ns - start else 0 else 0;
            if (presentTimingWatchdogDecision(
                win.outstanding_timed_presents,
                first_pending_start_ns,
                now_ns,
            ) == .disable) {
                abandonPresentTiming(win, self.has_google_present_timing);
                win.present_timing_diagnostics.notePollResult(0);
                return error.PresentTimingDataUnavailable;
            }
        } else {
            win.first_timed_present_start_ns = null;
            win.present_timing_diagnostics.ext_empty_probe_polls = 0;
        }
        win.present_timing_diagnostics.notePollResult(0);
        return 0;
    }
    win.present_timing_diagnostics.ext_empty_probe_polls = 0;
    try validatePresentFeedbackBatch(win.outstanding_timed_presents, available_u32, out.len);
    const available: usize = @intCast(available_u32);

    for (
        win.present_scratch.ext_records[0..available],
        win.present_scratch.ext_stages[0..available],
    ) |*record, *stage| {
        stage.* = .{ .stage = win.present_stage_queries, .time = 0 };
        record.* = .{
            .present_id = 0,
            .target_time = 0,
            .present_stage_count = 1,
            .p_present_stages = @ptrCast(stage),
            .time_domain = .swapchain_local_ext,
            .time_domain_id = win.time_domain_id,
            .report_complete = .false,
        };
    }

    var properties: vk.PastPresentationTimingPropertiesEXT = .{
        .timing_properties_counter = 0,
        .time_domains_counter = 0,
        .presentation_timing_count = available_u32,
        .p_presentation_timings = @ptrCast(win.present_scratch.ext_records[0..available].ptr),
    };
    const retrieve_result = self.device.getPastPresentationTimingEXT(&probe_info, &properties) catch |err| {
        win.present_timing_diagnostics.noteExtRetrieve(
            .failed,
            0,
            properties.timing_properties_counter,
            properties.time_domains_counter,
        );
        return err;
    };
    win.present_timing_diagnostics.noteExtRetrieve(
        presentTimingCallResult(retrieve_result),
        properties.presentation_timing_count,
        properties.timing_properties_counter,
        properties.time_domains_counter,
    );
    if (properties.presentation_timing_count > available_u32) {
        return error.PresentFeedbackBackendError;
    }
    const retrieved: usize = @intCast(properties.presentation_timing_count);
    for (
        win.present_scratch.ext_records[0..retrieved],
        win.present_scratch.records[0..retrieved],
    ) |record, *normalized| {
        const actual_ns = presentStageTimestamp(record);
        const first_stage = if (record.present_stage_count != 0)
            record.p_present_stages[0]
        else
            vk.PresentStageTimeEXT{ .stage = .{}, .time = 0 };
        win.present_timing_diagnostics.noteExtRecord(
            record.present_id,
            record.present_stage_count,
            first_stage.stage,
            actual_ns,
            record.report_complete == .true,
        );
        normalized.* = .{
            .present_id = record.present_id,
            .actual_present_ns = actual_ns,
            .completed = record.report_complete == .true,
        };
    }
    const completed = commitPresentFeedbackBatch(
        .ext,
        &win.last_feedback_id,
        &win.outstanding_timed_presents,
        win.present_scratch.records[0..retrieved],
        win.present_scratch.normalized[0..retrieved],
        out,
    ) catch |err| {
        if (err == error.PresentTimingDataUnavailable) {
            abandonPresentTiming(win, self.has_google_present_timing);
        }
        if (win.outstanding_timed_presents == 0) {
            win.first_timed_present_start_ns = null;
        }
        win.present_timing_diagnostics.outstanding_timed_presents = win.outstanding_timed_presents;
        return err;
    };
    win.present_timing_diagnostics.notePollResult(completed);
    self.notePresentTimingProgress(win, completed);
    win.present_timing_diagnostics.outstanding_timed_presents = win.outstanding_timed_presents;
    return completed;
}

fn pollPresentFeedbackGoogle(self: *VkBackend, win: *Window, out: []PresentFeedback) !usize {
    var available: u32 = 0;
    const probe_result = self.device.getPastPresentationTimingGOOGLE(
        win.swapchain,
        &available,
        null,
    ) catch |err| {
        win.present_timing_diagnostics.noteGoogleProbe(.failed, 0);
        return err;
    };
    win.present_timing_diagnostics.noteGoogleProbe(
        presentTimingCallResult(probe_result),
        available,
    );
    if (available == 0) {
        if (win.outstanding_timed_presents != 0) {
            win.present_timing_diagnostics.google_empty_probe_polls +|= 1;
            const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
            const first_pending_start_ns = if (win.first_timed_present_start_ns) |start|
                start.nanoseconds
            else
                null;
            win.present_timing_diagnostics.watchdog_last_now_ns = now_ns;
            win.present_timing_diagnostics.watchdog_elapsed_ns =
                if (first_pending_start_ns) |start| if (now_ns >= start) now_ns - start else 0 else 0;
            if (presentTimingWatchdogDecision(
                win.outstanding_timed_presents,
                first_pending_start_ns,
                now_ns,
            ) == .disable) {
                abandonPresentTiming(win, self.has_google_present_timing);
                win.present_timing_diagnostics.notePollResult(0);
                return error.PresentTimingDataUnavailable;
            }
        } else {
            win.first_timed_present_start_ns = null;
            win.present_timing_diagnostics.google_empty_probe_polls = 0;
        }
        win.present_timing_diagnostics.notePollResult(0);
        return 0;
    }
    win.present_timing_diagnostics.google_empty_probe_polls = 0;
    try validatePresentFeedbackBatch(win.outstanding_timed_presents, available, out.len);
    const available_len: usize = @intCast(available);
    var retrieved = available;
    const retrieve_result = self.device.getPastPresentationTimingGOOGLE(
        win.swapchain,
        &retrieved,
        @ptrCast(win.present_scratch.google_records[0..available_len].ptr),
    ) catch |err| {
        win.present_timing_diagnostics.noteGoogleRetrieve(.failed, 0);
        return err;
    };
    win.present_timing_diagnostics.noteGoogleRetrieve(
        presentTimingCallResult(retrieve_result),
        retrieved,
    );
    if (retrieved > available) return error.PresentFeedbackBackendError;
    const retrieved_len: usize = @intCast(retrieved);
    for (
        win.present_scratch.google_records[0..retrieved_len],
        win.present_scratch.records[0..retrieved_len],
    ) |record, *normalized| {
        win.present_timing_diagnostics.noteGoogleRecord(
            record.present_id,
            record.actual_present_time,
        );
        normalized.* = .{
            .present_id = record.present_id,
            .actual_present_ns = record.actual_present_time,
            .completed = true,
        };
    }
    const completed = commitPresentFeedbackBatch(
        .google,
        &win.last_feedback_id,
        &win.outstanding_timed_presents,
        win.present_scratch.records[0..retrieved_len],
        win.present_scratch.normalized[0..retrieved_len],
        out,
    ) catch |err| {
        if (err == error.PresentTimingDataUnavailable) {
            abandonPresentTiming(win, self.has_google_present_timing);
        }
        if (win.outstanding_timed_presents == 0) {
            win.first_timed_present_start_ns = null;
        }
        win.present_timing_diagnostics.outstanding_timed_presents = win.outstanding_timed_presents;
        return err;
    };
    win.present_timing_diagnostics.notePollResult(completed);
    self.notePresentTimingProgress(win, completed);
    win.present_timing_diagnostics.outstanding_timed_presents = win.outstanding_timed_presents;
    return completed;
}

fn presentStageTimestamp(record: vk.PastPresentationTimingEXT) u64 {
    var first_pixel_out_ns: u64 = 0;
    const stage_count = @min(record.present_stage_count, 1);
    for (record.p_present_stages[0..stage_count]) |stage| {
        if (stage.stage.image_first_pixel_visible_bit_ext and stage.time != 0) return stage.time;
        if (stage.stage.image_first_pixel_out_bit_ext and stage.time != 0) first_pixel_out_ns = stage.time;
    }
    return first_pixel_out_ns;
}

pub fn cmdTimestampReset(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    handle: TimestampQueryHandle,
    first: u32,
    count: u32,
) !void {
    if (!self.timestamp_queries) return error.TimestampQueriesUnsupported;
    const entry = try self.timestampQueryEntry(handle);
    try TimestampQuerySet.validateQueryRange(entry.count, first, count);
    self.device.cmdResetQueryPool(cmd, entry.pool, first, count);
}

pub fn cmdTimestampWrite(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    handle: TimestampQueryHandle,
    index: u32,
    stage: TimestampQuerySet.TimestampStage,
) !void {
    if (!self.timestamp_queries) return error.TimestampQueriesUnsupported;
    const entry = try self.timestampQueryEntry(handle);
    try TimestampQuerySet.validateQueryRange(entry.count, index, 1);
    const pipeline_stage: vk.PipelineStageFlags = switch (stage) {
        .all_commands_start => .{ .top_of_pipe_bit = true },
        .all_commands_end => .{ .bottom_of_pipe_bit = true },
    };
    self.device.cmdWriteTimestamp(cmd, pipeline_stage, entry.pool, index);
}

// Timestamp query methods follow queue synchronization methods.

pub fn shaderCreate(self: *VkBackend, spv: []const u32, stage: u2, entry: [:0]const u8) !ShaderHandle {
    const vk_stage: vk.ShaderStageFlags = switch (stage) {
        0 => .{ .vertex_bit = true },
        1 => .{ .fragment_bit = true },
        2 => .{ .compute_bit = true },
        else => unreachable,
    };
    const next_stage: vk.ShaderStageFlags = if (vk_stage.vertex_bit) .{ .fragment_bit = true } else .{};
    const pc_range = switch (stage) {
        2 => vk.PushConstantRange{
            .stage_flags = .{ .compute_bit = true },
            .offset = 0,
            .size = @sizeOf(ComputePushConstants),
        },
        else => vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            .offset = 0,
            .size = @sizeOf(GraphicsPushConstants),
        },
    };
    const ci: vk.ShaderCreateInfoEXT = .{
        .code_type = .spirv_ext,
        .code_size = spv.len * @sizeOf(u32),
        .p_code = @ptrCast(spv.ptr),
        .p_name = entry,
        .stage = vk_stage,
        .next_stage = next_stage,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&pc_range),
        .set_layout_count = 3,
        .p_set_layouts = @ptrCast(&self.desc_layouts),
    };
    var shader_out: [1]vk.ShaderEXT = undefined;
    _ = try self.device.createShadersEXT(
        @ptrCast(&[_]vk.ShaderCreateInfoEXT{ci}),
        null,
        &shader_out,
    );
    {
        var name_buf: [64]u8 = undefined;
        const stage_name = switch (stage) {
            0 => "vert",
            1 => "frag",
            else => "comp",
        };
        const sname = std.fmt.bufPrintSentinel(&name_buf, "shader_{s}_{s}", .{ stage_name, entry }, 0) catch "shader";
        self.setDebugName(.shader_ext, @intFromEnum(shader_out[0]), sname);
    }
    return shader_out[0];
}

pub fn shaderDestroy(self: *VkBackend, shader: ShaderHandle) void {
    self.device.destroyShaderEXT(shader, null);
}

// Semaphore methods
pub fn semaphoreCreate(self: *VkBackend, initial_value: u64) !SemaphoreHandle {
    return self.device.createSemaphore(
        &.{ .p_next = @constCast(&vk.SemaphoreTypeCreateInfo{
            .semaphore_type = .timeline,
            .initial_value = initial_value,
        }) },
        null,
    );
}
pub fn semaphoreDestroy(self: *VkBackend, sem: SemaphoreHandle) void {
    self.device.destroySemaphore(sem, null);
}

// ── Command buffer methods (VkCmd*) ─────────────────────────

pub fn cmdSetShaders(self: *VkBackend, cmd: CommandBufferHandle, vert: ShaderHandle, frag: ShaderHandle) void {
    const stages: [2]vk.ShaderStageFlags = .{ .{ .vertex_bit = true }, .{ .fragment_bit = true } };
    const shaders: [2]vk.ShaderEXT = .{ vert, frag };
    self.device.cmdBindShadersEXT(cmd, &stages, &shaders);
}

pub fn cmdSetComputeShader(self: *VkBackend, cmd: CommandBufferHandle, shader: ShaderHandle) void {
    const stage = [_]vk.ShaderStageFlags{.{ .compute_bit = true }};
    const shaders = [_]vk.ShaderEXT{shader};
    self.device.cmdBindShadersEXT(cmd, &stage, &shaders);
}

pub fn cmdSetDepthState(self: *VkBackend, cmd: CommandBufferHandle, state: DepthState) void {
    self.device.cmdSetDepthTestEnable(cmd, if (state.mode.read) @as(vk.Bool32, .true) else @as(vk.Bool32, .false));
    self.device.cmdSetDepthWriteEnable(cmd, if (state.mode.write) @as(vk.Bool32, .true) else @as(vk.Bool32, .false));
    self.device.cmdSetDepthCompareOp(cmd, @as(vk.CompareOp, @enumFromInt(@intFromEnum(state.compare))));
    self.device.cmdSetDepthBiasEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetStencilTestEnable(cmd, @as(vk.Bool32, .false));
}

pub fn cmdSetRasterState(self: *VkBackend, cmd: CommandBufferHandle, state: RasterState) void {
    self.device.cmdSetPrimitiveTopology(cmd, @enumFromInt(@intFromEnum(state.topology)));
    self.device.cmdSetCullMode(cmd, @as(vk.CullModeFlags, @bitCast(@as(u32, @intFromEnum(state.cull_mode)))));
    self.device.cmdSetFrontFace(cmd, @as(vk.FrontFace, @enumFromInt(@intFromEnum(state.front_face))));
}

pub fn cmdSetBlendState(self: *VkBackend, cmd: CommandBufferHandle, state: BlendState) void {
    const enable = if (state.enable) @as(vk.Bool32, .true) else @as(vk.Bool32, .false);
    self.device.cmdSetColorBlendEnableEXT(cmd, 0, @as([]const vk.Bool32, &.{enable}));
    const eq: vk.ColorBlendEquationEXT = .{
        .src_color_blend_factor = @as(vk.BlendFactor, @enumFromInt(@intFromEnum(state.src_color_factor))),
        .dst_color_blend_factor = @as(vk.BlendFactor, @enumFromInt(@intFromEnum(state.dst_color_factor))),
        .color_blend_op = @as(vk.BlendOp, @enumFromInt(@intFromEnum(state.color_op))),
        .src_alpha_blend_factor = @as(vk.BlendFactor, @enumFromInt(@intFromEnum(state.src_alpha_factor))),
        .dst_alpha_blend_factor = @as(vk.BlendFactor, @enumFromInt(@intFromEnum(state.dst_alpha_factor))),
        .alpha_blend_op = @as(vk.BlendOp, @enumFromInt(@intFromEnum(state.alpha_op))),
    };
    self.device.cmdSetColorBlendEquationEXT(cmd, 0, @as([]const vk.ColorBlendEquationEXT, &.{eq}));
    const write_mask: vk.ColorComponentFlags = @bitCast(@as(u32, @as(u4, @bitCast(state.color_write_mask))));
    self.device.cmdSetColorWriteMaskEXT(cmd, 0, @as([]const vk.ColorComponentFlags, &.{write_mask}));
}

pub fn cmdSetBlendEnable(self: *VkBackend, cmd: CommandBufferHandle, enable: bool) void {
    const vk_enable: vk.Bool32 = if (enable) .true else .false;
    self.device.cmdSetColorBlendEnableEXT(cmd, 0, &.{vk_enable});
}

pub fn cmdSetViewport(self: *VkBackend, cmd: CommandBufferHandle, vp: Viewport) void {
    const vk_vp: vk.Viewport = .{
        .x = vp.x,
        .y = vp.y,
        .width = vp.width,
        .height = vp.height,
        .min_depth = vp.depth_min,
        .max_depth = vp.depth_max,
    };
    self.device.cmdSetViewportWithCount(cmd, &.{vk_vp});
}

pub fn cmdSetScissor(self: *VkBackend, cmd: CommandBufferHandle, sc: Scissor) void {
    const vk_sc: vk.Rect2D = .{
        .offset = .{ .x = sc.x, .y = sc.y },
        .extent = .{ .width = sc.width, .height = sc.height },
    };
    self.device.cmdSetScissorWithCount(cmd, &.{vk_sc});
}

pub fn cmdPushConstantsGraphics(self: *VkBackend, cmd: CommandBufferHandle, data: PushData) void {
    self.device.cmdPushConstants(cmd, self.pipeline_layout_graphics, .{
        .vertex_bit = true,
        .fragment_bit = true,
    }, 0, @sizeOf(PushData), @ptrCast(&data));
}

pub fn cmdPushConstantsCompute(self: *VkBackend, cmd: CommandBufferHandle, data: u64) void {
    self.device.cmdPushConstants(cmd, self.pipeline_layout_compute, .{
        .compute_bit = true,
    }, 0, @sizeOf(u64), @ptrCast(&data));
}

pub fn cmdBindIndexBuffer(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    buf: BufferHandle,
    offset: u64,
    fmt: IndexFormat,
) void {
    self.device.cmdBindIndexBuffer(cmd, buf, offset, @as(vk.IndexType, @enumFromInt(@intFromEnum(fmt))));
}

pub fn cmdDraw(self: *VkBackend, cmd: CommandBufferHandle, vertex_count: u32, instance_count: u32) void {
    self.device.cmdDraw(cmd, vertex_count, instance_count, 0, 0);
}

pub fn cmdDrawIndexed(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
) void {
    self.cmdInsertDebugLabel(cmd, "DrawIndexed", .{ 1.0, 0.8, 0.2, 1.0 });
    self.device.cmdDrawIndexed(cmd, index_count, instance_count, first_index, vertex_offset, 0);
}

pub fn cmdDrawIndexedIndirect(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    buffer: BufferHandle,
    offset: u64,
    draw_count: u32,
    stride: u32,
) void {
    self.device.cmdDrawIndexedIndirect(cmd, buffer, offset, draw_count, stride);
}

pub fn cmdDrawIndexedIndirectMulti(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    buffer: BufferHandle,
    offset: u64,
    stride: u32,
    count_buffer: BufferHandle,
    count_offset: u64,
    max_draws: u32,
) void {
    self.device.cmdDrawIndexedIndirectCount(cmd, buffer, offset, count_buffer, count_offset, max_draws, stride);
}

pub fn cmdDispatch(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    group_count_x: u32,
    group_count_y: u32,
    group_count_z: u32,
) void {
    self.device.cmdDispatch(cmd, group_count_x, group_count_y, group_count_z);
}

pub fn cmdDispatchIndirect(self: *VkBackend, cmd: CommandBufferHandle, buffer: BufferHandle, offset: u64) void {
    self.device.cmdDispatchIndirect(cmd, buffer, offset);
}

/// Convert Stage packed struct to Vulkan pipeline stage flags explicitly.
/// Avoids fragile @bitCast dependency on matching bit layouts.
fn toVkStageFlags(stage: Stage) vk.PipelineStageFlags2 {
    var flags: vk.PipelineStageFlags2 = .{};
    if (stage.vertex) flags.vertex_shader_bit = true;
    if (stage.fragment) flags.fragment_shader_bit = true;
    if (stage.color_output) flags.color_attachment_output_bit = true;
    if (stage.compute) flags.compute_shader_bit = true;
    if (stage.transfer) flags.all_transfer_bit = true;
    return flags;
}

pub fn cmdBarrier(self: *VkBackend, cmd: CommandBufferHandle, before: Stage, after: Stage, hazards: Hazard) void {
    const src_stage = toVkStageFlags(before);
    const dst_stage = toVkStageFlags(after);
    var src_access: vk.AccessFlags2 = .{};
    var dst_access: vk.AccessFlags2 = .{};
    if (!hazards.descriptors and !hazards.draw_arguments and !hazards.depth_stencil) {
        src_access = .{ .memory_write_bit = true };
        dst_access = .{ .memory_read_bit = true, .memory_write_bit = true };
    } else {
        if (hazards.descriptors) {
            if (before.compute or before.vertex or before.fragment) {
                src_access.shader_write_bit = true;
                dst_access.shader_read_bit = true;
            }
            if (before.transfer) {
                src_access.transfer_write_bit = true;
                dst_access.transfer_read_bit = true;
            }
        }
        if (hazards.draw_arguments) {
            if (before.compute or before.vertex or before.fragment) {
                src_access.shader_write_bit = true;
            }
            dst_access.indirect_command_read_bit = true;
        }
        if (hazards.depth_stencil) {
            src_access.depth_stencil_attachment_write_bit = true;
            dst_access.depth_stencil_attachment_read_bit = true;
            dst_access.depth_stencil_attachment_write_bit = true;
        }
    }
    const barrier: vk.MemoryBarrier2 = .{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
    };
    self.device.cmdPipelineBarrier2(cmd, @ptrCast(&vk.DependencyInfo{
        .memory_barrier_count = 1,
        .p_memory_barriers = @ptrCast(&barrier),
    }));
}

fn resolveTextureDimensions(self: *VkBackend, tex: TextureHandle) ?struct { width: u32, height: u32 } {
    if (tex.isSwapchain()) {
        const s = tex.swapchain;
        if (s.window_index >= self.windows.items.len) return null;
        const win = &self.windows.items[s.window_index];
        return .{ .width = win.extent.width, .height = win.extent.height };
    }
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return null;
    const info = &self.textures.items[t.id - 1];
    if (!info.valid) return null;
    return .{ .width = info.width, .height = info.height };
}

pub fn cmdBeginRendering(self: *VkBackend, cmd: CommandBufferHandle, desc: Rendering) void {
    const width = if (desc.render_area_size[0] != 0)
        desc.render_area_size[0]
    else if (desc.color_attachments.len > 0)
        (self.resolveTextureDimensions(desc.color_attachments[0].texture) orelse return).width
    else
        0;

    const height = if (desc.render_area_size[1] != 0)
        desc.render_area_size[1]
    else if (desc.color_attachments.len > 0)
        (self.resolveTextureDimensions(desc.color_attachments[0].texture) orelse return).height
    else
        0;

    var color_attach: [8]vk.RenderingAttachmentInfo = undefined;
    // Zero out inactive entries so the validation layer doesn't see garbage image_views
    for (&color_attach) |*ca| ca.* = .{
        .image_view = .null_handle,
        .image_layout = .undefined,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .dont_care,
        .store_op = .dont_care,
        .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
    };
    const color_count: u32 = @intCast(desc.color_attachments.len);
    if (color_count > 8) {
        log.warn("cmdBeginRendering: color_attachment count {} exceeds max 8, clamping", .{color_count});
    }
    const color_attach_count = @min(color_count, 8);
    for (desc.color_attachments[0..color_attach_count], 0..) |ca, i| {
        const vk_iv = self.resolveTextureView(ca.texture) orelse return;
        color_attach[i] = .{
            .image_view = vk_iv,
            .image_layout = .general,
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = @as(vk.AttachmentLoadOp, @enumFromInt(@intFromEnum(ca.load_op))),
            .store_op = @as(vk.AttachmentStoreOp, @enumFromInt(@intFromEnum(ca.store_op))),
            .clear_value = .{ .color = .{ .float_32 = ca.clear_color } },
        };
    }

    var depth_ci: vk.RenderingAttachmentInfo = undefined;
    if (desc.depth_attachment) |da| {
        const vk_iv = self.resolveTextureView(da.texture) orelse return;
        depth_ci = .{
            .image_view = vk_iv,
            .image_layout = .depth_stencil_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = @as(vk.AttachmentLoadOp, @enumFromInt(@intFromEnum(da.load_op))),
            .store_op = @as(vk.AttachmentStoreOp, @enumFromInt(@intFromEnum(da.store_op))),
            .clear_value = .{ .depth_stencil = .{ .depth = da.clear_depth, .stencil = da.clear_stencil } },
        };
    }

    // Transition depth from GENERAL to DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    if (desc.depth_attachment) |depth| {
        const depth_image = self.resolveTextureImage(depth.texture) orelse return;
        const depth_format = self.textures.items[depth.texture.texture.id - 1].format;
        self.last_depth_image = depth_image;
        self.last_depth_format = depth_format;
        const depth_barrier: vk.ImageMemoryBarrier2 = .{
            .image = depth_image,
            .subresource_range = .{
                .aspect_mask = imageAspect(depth_format),
                .base_mip_level = 0,
                .level_count = vk.REMAINING_MIP_LEVELS,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
            .old_layout = .general,
            .new_layout = .depth_stencil_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .early_fragment_tests_bit = true },
            .dst_access_mask = .{
                .depth_stencil_attachment_read_bit = true,
                .depth_stencil_attachment_write_bit = true,
            },
        };
        self.device.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&depth_barrier),
        });
    }

    var stencil_ci: vk.RenderingAttachmentInfo = undefined;
    if (desc.stencil_attachment) |sa| {
        const vk_iv = self.resolveTextureView(sa.texture) orelse return;
        stencil_ci = .{
            .image_view = vk_iv,
            .image_layout = .depth_stencil_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = @as(vk.AttachmentLoadOp, @enumFromInt(@intFromEnum(sa.load_op))),
            .store_op = @as(vk.AttachmentStoreOp, @enumFromInt(@intFromEnum(sa.store_op))),
            .clear_value = .{ .depth_stencil = .{ .depth = sa.clear_depth, .stencil = sa.clear_stencil } },
        };
    }

    self.cmdInsertDebugLabel(cmd, "RenderPass", .{ 0.3, 0.8, 0.3, 1.0 });
    self.device.cmdBeginRendering(cmd, &.{
        .render_area = .{
            .offset = .{ .x = desc.render_area_offset[0], .y = desc.render_area_offset[1] },
            .extent = .{ .width = width, .height = height },
        },
        .layer_count = if (desc.layer_count != 0) desc.layer_count else 1,
        .view_mask = desc.view_mask,
        .color_attachment_count = color_attach_count,
        .p_color_attachments = if (color_count > 0) &color_attach else null,
        .p_depth_attachment = if (desc.depth_attachment != null) @ptrCast(&depth_ci) else null,
        .p_stencil_attachment = if (desc.stencil_attachment != null) @ptrCast(&stencil_ci) else null,
    });

    // Set default dynamic state (no_gfx_api pattern)
    self.device.cmdSetStencilTestEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetRasterizerDiscardEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetPolygonModeEXT(cmd, .fill);
    self.device.cmdSetRasterizationSamplesEXT(cmd, .{ .@"1_bit" = true });
    self.device.cmdSetPrimitiveTopology(cmd, .triangle_list);
    self.device.cmdSetCullMode(cmd, .{ .back_bit = true });
    self.device.cmdSetFrontFace(cmd, .counter_clockwise);
    self.device.cmdSetDepthTestEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetDepthWriteEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetDepthCompareOp(cmd, .less);
    self.device.cmdSetDepthBiasEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetDepthBoundsTestEnable(cmd, @as(vk.Bool32, .false));
    self.device.cmdSetVertexInputEXT(cmd, null, null);
    self.device.cmdSetPrimitiveRestartEnable(cmd, @as(vk.Bool32, .false));
    const sample_mask: vk.SampleMask = 0xFF;
    self.device.cmdSetSampleMaskEXT(cmd, .{ .@"1_bit" = true }, @ptrCast(&sample_mask));
    self.device.cmdSetAlphaToCoverageEnableEXT(cmd, @as(vk.Bool32, .false));
    {
        var blend_enables: [8]vk.Bool32 = undefined;
        @memset(blend_enables[0..color_attach_count], @as(vk.Bool32, .false));
        self.device.cmdSetColorBlendEnableEXT(cmd, 0, blend_enables[0..color_attach_count]);
    }
    {
        var color_masks: [8]vk.ColorComponentFlags = undefined;
        @memset(color_masks[0..color_attach_count], .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true });
        self.device.cmdSetColorWriteMaskEXT(cmd, 0, color_masks[0..color_attach_count]);
    }
    {
        var blend_eqs: [8]vk.ColorBlendEquationEXT = undefined;
        for (blend_eqs[0..color_attach_count]) |*e| {
            e.* = .{
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one_minus_src_alpha,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .one_minus_src_alpha,
                .alpha_blend_op = .add,
            };
        }
        self.device.cmdSetColorBlendEquationEXT(cmd, 0, blend_eqs[0..color_attach_count]);
    }
    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .min_depth = 0,
        .max_depth = 1,
    };
    self.device.cmdSetViewportWithCount(cmd, &.{viewport});
    const scissor: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
    self.device.cmdSetScissorWithCount(cmd, &.{scissor});
}

pub fn cmdEndRendering(self: *VkBackend, cmd: CommandBufferHandle) void {
    self.device.cmdEndRendering(cmd);
    // Reverse depth barrier: DEPTH_STENCIL_ATTACHMENT_OPTIMAL → GENERAL
    if (self.last_depth_image != .null_handle) {
        const depth_barrier: vk.ImageMemoryBarrier2 = .{
            .image = self.last_depth_image,
            .subresource_range = .{
                .aspect_mask = imageAspect(self.last_depth_format),
                .base_mip_level = 0,
                .level_count = vk.REMAINING_MIP_LEVELS,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
            .old_layout = .depth_stencil_attachment_optimal,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .src_stage_mask = .{ .late_fragment_tests_bit = true },
            .src_access_mask = .{ .depth_stencil_attachment_write_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{},
        };
        self.device.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&depth_barrier),
        });
        self.last_depth_image = .null_handle;
    }
}

// ── Tracy GPU zones (Vulkan timestamp queries) ─────────────
const CmdOwner = struct {
    win: *Window,
    frame: u32,
};

/// Find the window + frame owning a command buffer handle.
/// Returns null for offscreen/compute command buffers; those are silently skipped.
fn findCmdOwner(self: *VkBackend, cmd: CommandBufferHandle) ?CmdOwner {
    for (self.windows.items) |*win| {
        for (win.cmd_buffers.items, 0..) |cb, f| {
            if (cb.handle == cmd) return .{ .win = win, .frame = @intCast(f) };
        }
    }
    return null;
}

/// Calibrate the device timestamp clock against the CPU clock for Tracy.
/// Mirrors TracyVulkan.hpp: probe 32 samples and take the minimum driver-reported
/// deviation, then retry until the deviation is at most 1.5× that minimum.
/// A single blind sample can be off by the full deviation (µs..ms) if the GPU is
/// busy at init, which would misplace every GPU zone on the CPU timeline.
/// Returns false only on driver failure; on retry exhaustion the last sample wins.
fn calibrateGpuTimestamps(
    self: *VkBackend,
    info: []const vk.CalibratedTimestampInfoKHR,
    out: *[2]u64,
) bool {
    var min_dev: u64 = std.math.maxInt(u64);
    var ts: [2]u64 = undefined;
    for (0..32) |_| {
        const dev = self.device.getCalibratedTimestampsKHR(info, &ts) catch return false;
        if (dev < min_dev) {
            min_dev = dev;
            out.* = ts;
        }
    }
    const threshold = min_dev * 3 / 2;
    for (0..64) |_| {
        const dev = self.device.getCalibratedTimestampsKHR(info, &ts) catch return false;
        out.* = ts;
        if (dev <= threshold) return true;
    }
    return true;
}

/// Source-location id for a swapchain image's per-frame GPU zone.
/// Called every frame from beginFrameGpuZone, but registers lazily: allocSrclocName
/// runs only on first use per image index (and again only if the swapchain grows
/// more images on recreation). Allocated srclocs are never freed by the profiler,
/// so the leak is bounded by the image count, not the frame count.
fn tracyImgSrcloc(self: *VkBackend, win: *Window, image_index: u32) ?u64 {
    const idx: usize = @intCast(image_index);
    if (win.tracy_img_srclocs.items.len <= idx) {
        const old_len = win.tracy_img_srclocs.items.len;
        win.tracy_img_srclocs.resize(self.allocator, idx + 1) catch return null;
        @memset(win.tracy_img_srclocs.items[old_len..], 0);
    }
    if (win.tracy_img_srclocs.items[idx] == 0) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "img {d}", .{image_index}) catch "img";
        win.tracy_img_srclocs.items[idx] = tracy.allocSrclocName(
            @src(),
            name,
            .{ .r = 105, .g = 105, .b = 105, .a = 255 }, // dim gray
        );
    }
    const id = win.tracy_img_srclocs.items[idx];
    return if (id == 0) null else id;
}

/// Begin the per-frame GPU zone named by swapchain image index. Each image is
/// in flight at most once, so the name identifies the in-flight frame.
fn beginFrameGpuZone(self: *VkBackend, win: *Window, frame: u32, image_index: u32) void {
    if (win.tracy_queries.items[frame] >= TracyQueryId.cap) return;
    const srcloc = self.tracyImgSrcloc(win, image_index) orelse return;
    const id = win.tracy_queries.items[frame];
    win.tracy_queries.items[frame] += 1;
    const query_id: TracyQueryId = .{ .index = @intCast(id), .frame = @intCast(frame) };
    self.tracy_queue.?.beginZoneAlloc(.{ .srcloc = srcloc, .query_id = @bitCast(query_id) });
    self.device.cmdWriteTimestamp(
        win.cmd_buffers.items[frame].handle,
        .{ .bottom_of_pipe_bit = true },
        win.tracy_query_pools.items[frame],
        query_id.index,
    );
}

/// End the per-frame GPU zone.
fn endFrameGpuZone(self: *VkBackend, win: *Window, frame: u32) void {
    if (win.tracy_queries.items[frame] >= TracyQueryId.cap) return;
    const id = win.tracy_queries.items[frame];
    win.tracy_queries.items[frame] += 1;
    const query_id: TracyQueryId = .{ .index = @intCast(id), .frame = @intCast(frame) };
    self.device.cmdWriteTimestamp(
        win.cmd_buffers.items[frame].handle,
        .{ .bottom_of_pipe_bit = true },
        win.tracy_query_pools.items[frame],
        query_id.index,
    );
    self.tracy_queue.?.endZone(@bitCast(query_id));
}

pub fn cmdBufBeginZone(self: *VkBackend, cmd: CommandBufferHandle, loc: *const tracy.SourceLocation) void {
    if (!self.tracy_gpu_zones) return;
    const owner = findCmdOwner(self, cmd) orelse return;
    const win = owner.win;
    const frame = owner.frame;
    if (win.tracy_queries.items[frame] >= TracyQueryId.cap) @panic("out of tracy gpu queries");
    const id = win.tracy_queries.items[frame];
    win.tracy_queries.items[frame] += 1;
    const query_id: TracyQueryId = .{ .index = @intCast(id), .frame = @intCast(frame) };
    self.tracy_queue.?.beginZone(.{ .query_id = @bitCast(query_id), .loc = loc });
    self.device.cmdWriteTimestamp(
        cmd,
        .{ .bottom_of_pipe_bit = true },
        win.tracy_query_pools.items[frame],
        query_id.index,
    );
    if (self.enable_debug_utils) self.cmdBeginDebugLabel(cmd, std.mem.span(loc.name orelse loc.function), .{
        @as(f32, @floatFromInt(loc.color.r)) / 255.0,
        @as(f32, @floatFromInt(loc.color.g)) / 255.0,
        @as(f32, @floatFromInt(loc.color.b)) / 255.0,
        1.0,
    });
}

pub fn cmdBufEndZone(self: *VkBackend, cmd: CommandBufferHandle) void {
    if (!self.tracy_gpu_zones) return;
    const owner = findCmdOwner(self, cmd) orelse return;
    const win = owner.win;
    const frame = owner.frame;
    if (win.tracy_queries.items[frame] >= TracyQueryId.cap) @panic("out of tracy gpu queries");
    const id = win.tracy_queries.items[frame];
    win.tracy_queries.items[frame] += 1;
    const query_id: TracyQueryId = .{ .index = @intCast(id), .frame = @intCast(frame) };
    self.device.cmdWriteTimestamp(
        cmd,
        .{ .bottom_of_pipe_bit = true },
        win.tracy_query_pools.items[frame],
        query_id.index,
    );
    self.tracy_queue.?.endZone(@bitCast(query_id));
    if (self.enable_debug_utils) self.cmdEndDebugLabel(cmd);
}

/// Read back completed timestamp queries and feed them to the Tracy GPU queue.
/// Called from beginFrame once the previous frame's fence has signaled.
fn collectTracyGpuQueries(self: *VkBackend, win: *Window, frame: u32) !void {
    const queries = win.tracy_queries.items[frame];
    if (queries == 0) return;
    const results = try self.allocator.alloc(u64, @as(usize, queries) * 2);
    defer self.allocator.free(results);
    const result = self.device.getQueryPoolResults(
        win.tracy_query_pools.items[frame],
        0,
        queries,
        results.len * @sizeOf(u64),
        @ptrCast(results.ptr),
        @sizeOf(u64) * 2,
        .{ .@"64_bit" = true, .with_availability_bit = true },
    ) catch |err| {
        log.warn("collectTracyGpuQueries: getQueryPoolResults failed: {}", .{err});
        self.device.resetQueryPool(win.tracy_query_pools.items[frame], 0, TracyQueryId.cap);
        win.tracy_queries.items[frame] = 0;
        return;
    };
    switch (result) {
        // Unsubmitted command buffers leave their queries never-written; skip via availability bit.
        .success, .not_ready => {},
        else => {
            log.warn("collectTracyGpuQueries: getQueryPoolResults returned {}", .{result});
            self.device.resetQueryPool(win.tracy_query_pools.items[frame], 0, TracyQueryId.cap);
            win.tracy_queries.items[frame] = 0;
            return;
        },
    }
    for (0..queries) |i| {
        if (results[i * 2 + 1] != 0) {
            self.tracy_queue.?.emitTime(.{
                .query_id = @bitCast(TracyQueryId{ .index = @intCast(i), .frame = @intCast(frame) }),
                .gpu_time = results[i * 2],
            });
        }
    }
    // Re-anchor the GPU↔CPU timeline every frame: fresh calibrated pair;
    // cpuDelta = CPU-clock advance since the last calibration. The server
    // recomputes calibrationMod from it, compensating GPU clock drift.
    var calib: [2]u64 = undefined;
    if (self.device.getCalibratedTimestampsKHR(&tracy_calib_info, &calib)) |_| {
        const delta: i64 = @as(i64, @intCast(calib[0])) - @as(i64, @intCast(self.tracy_prev_calib_cpu));
        if (delta > 0) {
            self.tracy_prev_calib_cpu = calib[0];
            self.tracy_queue.?.calibrate(.{ .gpu_time = calib[1], .cpu_delta = delta });
        }
    } else |err| {
        log.warn("collectTracyGpuQueries: re-calibration failed: {}", .{err});
    }
    self.device.resetQueryPool(win.tracy_query_pools.items[frame], 0, TracyQueryId.cap);
    win.tracy_queries.items[frame] = 0;
}

pub fn cmdBeginDebugLabel(self: *VkBackend, cmd: CommandBufferHandle, name: [:0]const u8, color: [4]f32) void {
    if (!self.enable_debug_utils) return;
    if (self.debug_messenger == .null_handle) return;
    self.device.cmdBeginDebugUtilsLabelEXT(cmd, @ptrCast(&vk.DebugUtilsLabelEXT{
        .p_label_name = name,
        .color = color,
    }));
}

pub fn cmdEndDebugLabel(self: *VkBackend, cmd: CommandBufferHandle) void {
    if (!self.enable_debug_utils) return;
    if (self.debug_messenger == .null_handle) return;
    self.device.cmdEndDebugUtilsLabelEXT(cmd);
}

/// Insert a single-point debug label in a command buffer. No-op if debug messenger not active.
pub fn cmdInsertDebugLabel(self: *VkBackend, cmd: CommandBufferHandle, name: [:0]const u8, color: [4]f32) void {
    if (!self.enable_debug_utils) return;
    if (self.debug_messenger == .null_handle) return;
    const label: vk.DebugUtilsLabelEXT = .{ .p_label_name = name, .color = color };
    self.device.cmdInsertDebugUtilsLabelEXT(cmd, &label);
}

/// Set debug name for a Vulkan object. No-op if debug messenger not active.
pub fn setDebugName(self: *VkBackend, object_type: vk.ObjectType, handle: u64, name: [:0]const u8) void {
    if (!self.enable_debug_utils) return;
    if (self.debug_messenger == .null_handle) return;
    const info: vk.DebugUtilsObjectNameInfoEXT = .{
        .object_type = object_type,
        .object_handle = handle,
        .p_object_name = name,
    };
    self.device.setDebugUtilsObjectNameEXT(&info) catch |err| {
        // Silently ignore if the extension is not available
        log.debug("setDebugUtilsObjectNameEXT failed: {}", .{err});
    };
}

pub fn cmdAddWaitSemaphore(self: *VkBackend, window_index: u32, sem: SemaphoreHandle, value: u64) void {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;
    win.wait_sems.items[frame].append(self.allocator, sem) catch |e|
        log.warn("cmdAddWaitSemaphore: append failed: {}", .{e});
    win.wait_values.items[frame].append(self.allocator, value) catch |e|
        log.warn("cmdAddWaitSemaphore: append value failed: {}", .{e});
}
pub fn cmdAddSignalSemaphore(self: *VkBackend, window_index: u32, sem: SemaphoreHandle, value: u64) void {
    const win = &self.windows.items[window_index];
    const frame = win.frame_index;
    win.signal_sems.items[frame].append(self.allocator, sem) catch |e|
        log.warn("cmdAddSignalSemaphore: append failed: {}", .{e});
    win.signal_values.items[frame].append(self.allocator, value) catch |e|
        log.warn("cmdAddSignalSemaphore: append value failed: {}", .{e});
}
pub fn cmdBindDescriptorSets(self: *VkBackend, cmd: CommandBufferHandle, heap: u32) void {
    if (heap < self.desc_heaps.items.len) {
        const dh = self.desc_heaps.items[heap];
        // Bind to both graphics and compute (no_gfx_api pattern)
        self.device.cmdBindDescriptorSets(cmd, .graphics, self.pipeline_layout_graphics, 0, dh.sets[0..], null);
        self.device.cmdBindDescriptorSets(cmd, .compute, self.pipeline_layout_compute, 0, dh.sets[0..], null);
    }
}

pub fn deviceLimits(self: *const VkBackend) DeviceLimits {
    return self.device_limits;
}

pub fn deviceIdentity(self: *const VkBackend) DeviceIdentity {
    return .{
        .name = self.selected_device_name[0..self.selected_device_name_len],
        .vendor_id = self.selected_vendor_id,
        .device_id = self.selected_device_id,
        .driver = self.selected_driver_name[0..self.selected_driver_name_len],
    };
}
pub fn surfaceSize(self: *const VkBackend, window_index: u32) Extent2D {
    if (window_index < self.windows.items.len) return self.windows.items[window_index].extent;
    return .{ .width = 800, .height = 600 };
}
pub fn notifyResize(self: *VkBackend, window_index: u32, size: Extent2D) void {
    if (window_index < self.windows.items.len) {
        const win = &self.windows.items[window_index];
        if (win.requested_extent.width != size.width or win.requested_extent.height != size.height) {
            win.requested_extent = size;
            if (win.resize_throttle == 0) {
                log.info("notifyResize: setting needs_resize (size={}x{})", .{ size.width, size.height });
                win.needs_resize = true;
            } else {
                log.info(
                    "notifyResize: deferring (size={}x{}, throttle={})",
                    .{ size.width, size.height, win.resize_throttle },
                );
            }
        }
    }
}

fn recreateSwapchain(self: *VkBackend, win: *Window) !void {
    if (use_swapchain_maintenance1) {
        // Wait on ALL per-frame present fences before destroying old swapchain.
        // Each frame's present must complete before we can safely recreate.
        for (win.present_done_fences.items) |f| {
            const zone_wf_rs = tracy.Zone.begin(.{ .name = "waitFences", .src = @src(), .color = .tomato });
            defer zone_wf_rs.end();
            _ = try self.device.waitForFences(
                &[_]vk.Fence{f},
                .true,
                std.math.maxInt(u64),
            );
        }
    } else {
        // deviceWaitIdle: Khronos-recommended workaround for spec bug #1678.
        // No fence/semaphore reliably signals when the present engine is done
        // with old swapchain images. deviceWaitIdle is the only safe fallback.
        const zone_dwi_rs = tracy.Zone.begin(.{ .name = "deviceWait", .src = @src(), .color = .tomato });
        defer zone_dwi_rs.end();
        try self.device.deviceWaitIdle();
        // Destroy old swapchain + views immediately (Odin pattern).
        // Passing old_swapchain to createSwapchainKHR can trigger driver faults
        // on some NVIDIA + Wayland configurations.
        for (win.views.items) |v| self.device.destroyImageView(v, null);
        win.views.clearRetainingCapacity();
        win.images.clearRetainingCapacity();
        self.device.destroySwapchainKHR(win.swapchain, null);
        win.swapchain = .null_handle;
    }
    // Destroy present semaphores
    for (win.present_sems.items) |s| self.device.destroySemaphore(s, null);
    win.present_sems.deinit(self.allocator);
    win.present_sems = .empty;
    // Recreate swapchain (handles old swapchain + images + views)
    try createSwapchainResources(self, win);
    // Recreate present semaphores for new image count
    try createPresentSemaphores(self, win);
    win.needs_resize = false;
    log.info("Swapchain recreated after resize", .{});
}

fn querySwapchainTimeDomain(self: *VkBackend, win: *Window) !void {
    var properties: vk.SwapchainTimeDomainPropertiesEXT = .{
        .time_domain_count = 0,
        .p_time_domains = null,
        .p_time_domain_ids = null,
    };
    _ = try self.device.getSwapchainTimeDomainPropertiesEXT(win.swapchain, &properties, null);
    if (properties.time_domain_count == 0) return error.NoPresentTimeDomain;

    var domains: [8]vk.TimeDomainKHR = undefined;
    var ids: [8]u64 = undefined;
    if (properties.time_domain_count > domains.len) return error.TooManyPresentTimeDomains;
    properties.p_time_domains = @ptrCast(&domains);
    properties.p_time_domain_ids = @ptrCast(&ids);
    _ = try self.device.getSwapchainTimeDomainPropertiesEXT(win.swapchain, &properties, null);
    if (properties.time_domain_count == 0) return error.NoPresentTimeDomain;
    if (properties.time_domain_count > domains.len) return error.TooManyPresentTimeDomains;

    win.present_time_domain_count = properties.time_domain_count;
    @memcpy(
        win.present_time_domains[0..properties.time_domain_count],
        domains[0..properties.time_domain_count],
    );
    @memcpy(
        win.present_time_domain_ids[0..properties.time_domain_count],
        ids[0..properties.time_domain_count],
    );

    var selected: usize = 0;
    for (domains[0..properties.time_domain_count], 0..) |domain, i| {
        if (domain == .clock_monotonic_raw_khr) {
            selected = i;
            break;
        }
        if (domain == .clock_monotonic_khr) selected = i;
    }
    win.time_domain_id = ids[selected];
    win.time_domain_valid = true;
}

fn createSwapchainResources(self: *VkBackend, win: *Window) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    const alloc = self.allocator;
    const old_swapchain = win.swapchain;

    // Surface capabilities
    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, win.surface);
    log.info("Surface caps: {}x{} -> {}x{}", .{
        caps.current_extent.width,   caps.current_extent.height,
        caps.min_image_extent.width, caps.max_image_extent.width,
    });

    var extent = caps.current_extent;
    if (extent.width == 0xFFFFFFFF or extent.width == 0) {
        extent.width = @max(caps.min_image_extent.width, @min(win.requested_extent.width, caps.max_image_extent.width));
        extent.height = @max(
            caps.min_image_extent.height,
            @min(win.requested_extent.height, caps.max_image_extent.height),
        );
    }
    win.extent = .{ .width = extent.width, .height = extent.height }; // actual extent

    // Surface formats, preferred order: b8g8r8a8_srgb/srgb_nonlinear ->
    // r8g8b8a8_srgb/srgb_nonlinear -> b8g8r8a8_unorm/srgb_nonlinear -> first entry.
    const formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, win.surface, alloc);
    defer alloc.free(formats);
    if (formats.len == 0) return error.OutOfDateKHR;
    const preferences = [_]vk.SurfaceFormatKHR{
        .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr },
        .{ .format = .r8g8b8a8_srgb, .color_space = .srgb_nonlinear_khr },
        .{ .format = .b8g8r8a8_unorm, .color_space = .srgb_nonlinear_khr },
    };
    var chosen_format: vk.SurfaceFormatKHR = formats[0];
    outer: for (preferences) |want| {
        for (formats) |f| {
            if (f.format == want.format and f.color_space == want.color_space) {
                chosen_format = f;
                break :outer;
            }
        }
    }

    // Present modes
    const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
        self.physical_device,
        win.surface,
        alloc,
    );
    defer alloc.free(present_modes);
    var chosen_present = vk.PresentModeKHR.fifo_khr;
    var requested_supported = false;
    for (present_modes) |mode| {
        if (mode == win.present_mode) {
            chosen_present = mode;
            requested_supported = true;
            break;
        }
    }
    if (!requested_supported) {
        const fallback_modes: []const vk.PresentModeKHR = switch (win.present_mode) {
            .immediate_khr => &.{ .mailbox_khr, .fifo_relaxed_khr, .fifo_khr },
            .mailbox_khr => &.{ .fifo_relaxed_khr, .fifo_khr },
            .fifo_relaxed_khr => &.{.fifo_khr},
            .fifo_khr => &.{.fifo_khr},
            else => &.{.fifo_khr},
        };
        for (fallback_modes) |fallback| {
            for (present_modes) |mode| {
                if (mode == fallback) {
                    chosen_present = mode;
                    break;
                }
            }
            if (chosen_present == fallback) break;
        }
        log.warn(
            "Requested present mode {} unavailable; using {}",
            .{ win.present_mode, chosen_present },
        );
    }
    log.info("Present mode: {} ({} modes supported)", .{ chosen_present, present_modes.len });

    // Hand the surface to the device for swapchain maintenance
    const swapchain_ci: vk.SwapchainCreateInfoKHR = .{
        .surface = win.surface,
        .min_image_count = caps.min_image_count + 1,
        .image_format = chosen_format.format,
        .image_color_space = chosen_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = chosen_present,
        // Present timing requires the swapchain created with both feature flags.
        .flags = if (win.timing_mode == .ext)
            .{ .present_id_2_bit_khr = true, .present_timing_bit_ext = true }
        else
            .{},
        .clipped = .true,
        .old_swapchain = old_swapchain,
    };
    win.swapchain = try self.device.createSwapchainKHR(&swapchain_ci, null);
    self.setDebugName(.swapchain_khr, @intFromEnum(win.swapchain), "swapchain");
    if (win.timing_mode == .ext) {
        // Queue capacity is part of EXT support. Do not advertise EXT after
        // silently discarding a failed setup call.
        _ = try self.device.setSwapchainPresentTimingQueueSizeEXT(win.swapchain, max_present_feedback);
        if (self.querySwapchainTimeDomain(win)) |_| {
            win.timing_mode = resolvePresentTimingMode(
                self.has_ext_present_timing,
                .{
                    .present_id2 = true,
                    .present_timing = true,
                    .stage = selectPresentStage(win.present_stage_queries),
                    .time_domain_id = win.time_domain_id,
                    .time_domain_valid = win.time_domain_valid,
                },
                self.has_google_present_timing,
            );
        } else |err| {
            log.warn("swapchain time-domain query failed; downgrading timing: {}", .{err});
            win.time_domain_valid = false;
            win.timing_mode = if (self.has_google_present_timing) .google else .unsupported;
        }
    }
    if (old_swapchain != .null_handle) {
        for (win.views.items) |v| self.device.destroyImageView(v, null);
        win.views.clearRetainingCapacity();
        win.images.clearRetainingCapacity();
        // First recreation: the on-screen swapchain is retired (destroyed after present).
        // Subsequent recreations (retry loop): the intermediate swapchain was never
        // presented — destroy it immediately.
        if (win.retired_swapchain == .null_handle) {
            win.retired_swapchain = old_swapchain;
        } else {
            self.device.destroySwapchainKHR(old_swapchain, null);
        }
    }

    // Get swapchain images
    const swap_images = try self.device.getSwapchainImagesAllocKHR(win.swapchain, alloc);
    defer alloc.free(swap_images);
    try win.images.appendSlice(alloc, swap_images);
    {
        var name_buf: [64]u8 = undefined;
        for (win.images.items, 0..) |img, i| {
            const name = std.fmt.bufPrintSentinel(&name_buf, "swapchain_img[{}]", .{i}, 0) catch "swapchain_img";
            self.setDebugName(.image, @intFromEnum(img), name);
        }
    }

    // Build views atomically: create all into temp list, then swap
    var new_views = std.ArrayList(vk.ImageView).empty;
    errdefer for (new_views.items) |v| self.device.destroyImageView(v, null);
    errdefer new_views.deinit(alloc);
    try new_views.ensureTotalCapacity(alloc, swap_images.len);
    {
        var name_buf: [64]u8 = undefined;
        for (swap_images, 0..) |img, i| {
            const view = try self.device.createImageView(&.{
                .image = img,
                .view_type = .@"2d",
                .format = win.swapchain_format,
                .components = .{ .r = .r, .g = .g, .b = .b, .a = .a },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
            const vname = std.fmt.bufPrintSentinel(&name_buf, "swapchain_view[{}]", .{i}, 0) catch "swapchain_view";
            self.setDebugName(.image_view, @intFromEnum(view), vname);
            new_views.appendAssumeCapacity(view);
        }
    }
    // Swap atomically: deinit old, take new
    win.views.deinit(alloc);
    win.views = new_views;
    // A new swapchain owns a fresh bounded timing queue.
    win.outstanding_timed_presents = 0;
    win.first_timed_present_start_ns = null;
    const swapchain_generation = win.present_timing_diagnostics.swapchain_generation + 1;
    win.present_timing_diagnostics = .{
        .mode = win.timing_mode,
        .swapchain_id = @intFromEnum(win.swapchain),
        .swapchain_generation = swapchain_generation,
        .present_stage_bits = @bitCast(win.present_stage_queries),
        .time_domain_id = win.time_domain_id,
        .time_domain_valid = win.time_domain_valid,
    };
    log.info("Swapchain created: {} images, format {}, extent {}x{}", .{
        swap_images.len, win.swapchain_format, extent.width, extent.height,
    });
}
fn createPerFrameResources(self: *VkBackend, win: *Window) !void {
    const alloc = self.allocator;
    const frames = win.frames_in_flight;

    try win.cmd_pools.ensureTotalCapacity(alloc, frames);
    try win.cmd_buffers.ensureTotalCapacity(alloc, frames);
    try win.cmd_pool_ready.ensureTotalCapacity(alloc, frames);

    for (0..frames) |f| {
        const pool = try self.device.createCommandPool(&.{
            .queue_family_index = self.queue_family_index,
            .flags = .{ .reset_command_buffer_bit = true },
        }, null);
        {
            var name_buf: [64]u8 = undefined;
            const pname = std.fmt.bufPrintSentinel(&name_buf, "cmd_pool[{}]", .{f}, 0) catch "cmd_pool";
            self.setDebugName(.command_pool, @intFromEnum(pool), pname);
        }
        win.cmd_pools.appendAssumeCapacity(pool);

        var cb_handle: vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cb_handle));
        {
            var name_buf: [64]u8 = undefined;
            const cname = std.fmt.bufPrintSentinel(&name_buf, "cmd_buf[{}]", .{f}, 0) catch "cmd_buf";
            self.setDebugName(.command_buffer, @intFromEnum(cb_handle), cname);
        }
        win.cmd_buffers.appendAssumeCapacity(.{ .handle = cb_handle, .wrapper = &self.vkd });

        const fence = try self.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        {
            var name_buf: [64]u8 = undefined;
            const fname = std.fmt.bufPrintSentinel(&name_buf, "cmd_fence[{}]", .{f}, 0) catch "cmd_fence";
            self.setDebugName(.fence, @intFromEnum(fence), fname);
        }
        win.cmd_pool_ready.appendAssumeCapacity(fence);
    }
    // Tracy GPU query pools: one per frame, host-reset (host_query_reset feature).
    if (self.tracy_gpu_zones) {
        try win.tracy_query_pools.ensureTotalCapacity(alloc, frames);
        try win.tracy_queries.ensureTotalCapacity(alloc, frames);
        for (0..frames) |_| {
            const pool = try self.device.createQueryPool(&.{
                .query_type = .timestamp,
                .query_count = TracyQueryId.cap,
            }, null);
            self.device.resetQueryPool(pool, 0, TracyQueryId.cap);
            win.tracy_query_pools.appendAssumeCapacity(pool);
            win.tracy_queries.appendAssumeCapacity(0);
        }
    }
    log.info("Per-frame resources created: {} frames", .{frames});
}

fn initPerFrameSemaphoreLists(self: *VkBackend, win: *Window) !void {
    const alloc = self.allocator;
    const frames = self.frames_in_flight;
    try win.wait_sems.ensureTotalCapacity(alloc, frames);
    try win.wait_values.ensureTotalCapacity(alloc, frames);
    try win.signal_sems.ensureTotalCapacity(alloc, frames);
    try win.signal_values.ensureTotalCapacity(alloc, frames);
    for (0..frames) |_| {
        win.wait_sems.appendAssumeCapacity(.empty);
        win.wait_values.appendAssumeCapacity(.empty);
        win.signal_sems.appendAssumeCapacity(.empty);
        win.signal_values.appendAssumeCapacity(.empty);
    }
}

fn createPresentSemaphores(self: *VkBackend, win: *Window) !void {
    const alloc = self.allocator;
    try win.present_sems.ensureTotalCapacity(alloc, win.images.items.len);
    {
        var name_buf: [64]u8 = undefined;
        for (win.images.items, 0..) |_, i| {
            const sem = try self.device.createSemaphore(&.{}, null);
            const sname = std.fmt.bufPrintSentinel(&name_buf, "present_sem[{}]", .{i}, 0) catch "present_sem";
            self.setDebugName(.semaphore, @intFromEnum(sem), sname);
            win.present_sems.appendAssumeCapacity(sem);
        }
    }
}
fn destroyWindow(self: *VkBackend, win: *Window) void {
    const alloc = self.allocator;
    for (win.views.items) |v| self.device.destroyImageView(v, null);
    win.views.deinit(alloc);
    for (win.present_sems.items) |s| self.device.destroySemaphore(s, null);
    win.present_sems.deinit(alloc);
    win.images.deinit(alloc);
    for (win.wait_sems.items) |*l| l.deinit(alloc);
    win.wait_sems.deinit(alloc);
    for (win.wait_values.items) |*l| l.deinit(alloc);
    win.wait_values.deinit(alloc);
    for (win.signal_sems.items) |*l| l.deinit(alloc);
    win.signal_sems.deinit(alloc);
    for (win.signal_values.items) |*l| l.deinit(alloc);
    win.signal_values.deinit(alloc);
    if (win.swapchain != .null_handle) {
        self.device.destroySwapchainKHR(win.swapchain, null);
        win.swapchain = .null_handle;
    }
    if (win.retired_swapchain != .null_handle) {
        self.device.destroySwapchainKHR(win.retired_swapchain, null);
        win.retired_swapchain = .null_handle;
    }
    for (win.cmd_pools.items) |p| self.device.destroyCommandPool(p, null);
    win.cmd_pools.deinit(alloc);
    win.cmd_buffers.deinit(alloc);
    for (win.cmd_pool_ready.items) |f| self.device.destroyFence(f, null);
    win.cmd_pool_ready.deinit(alloc);
    if (self.tracy_gpu_zones) {
        for (win.tracy_query_pools.items) |p| self.device.destroyQueryPool(p, null);
        win.tracy_query_pools.deinit(alloc);
        win.tracy_queries.deinit(alloc);
        win.tracy_img_srclocs.deinit(alloc);
    }
    if (use_swapchain_maintenance1) {
        for (win.present_done_fences.items) |f| self.device.destroyFence(f, null);
        win.present_done_fences.deinit(alloc);
    }
    if (win.surface != .null_handle) {
        self.instance.destroySurfaceKHR(win.surface, null);
        win.surface = .null_handle;
    }
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    data: [*c]const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = user_data;
    const prefix = if (severity.error_bit_ext) "ERROR" else if (severity.warning_bit_ext) "WARN" else "INFO";
    const tag = if (msg_type.validation_bit_ext) "VAL" else if (msg_type.performance_bit_ext) "PERF" else "GEN";
    if (data.*.p_message) |msg| log.info("[{s}:{s}] {s}", .{ tag, prefix, msg });
    return @as(vk.Bool32, .false);
}

// ── GPU memory allocation (no_gfx_api pattern: VkBuffer + VkDeviceMemory) ─

fn toVkFormat(fmt: TextureFormat) vk.Format {
    return switch (fmt) {
        .default => .undefined,
        .r8_unorm => .r8_unorm,
        .rg8_unorm => .r8g8_unorm,
        .rgba8_unorm => .r8g8b8a8_unorm,
        .abgr8_unorm => .a8b8g8r8_unorm_pack32,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .r8_srgb => .r8_srgb,
        .rg8_srgb => .r8g8_srgb,
        .rgba8_srgb => .r8g8b8a8_srgb,
        .abgr8_srgb => .a8b8g8r8_srgb_pack32,
        .bgra8_srgb => .b8g8r8a8_srgb,
        .r16_unorm => .r16_unorm,
        .rg16_unorm => .r16g16_unorm,
        .rgba16_unorm => .r16g16b16a16_unorm,
        .d16_unorm => .d16_unorm,
        .d16_unorm_s8_uint => .d16_unorm_s8_uint,
        .d24_unorm_pack32 => .x8_d24_unorm_pack32,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
        .d32_float => .d32_sfloat,
        .r16_float => .r16_sfloat,
        .rg16_float => .r16g16_sfloat,
        .rgba16_float => .r16g16b16a16_sfloat,
        .r32_float => .r32_sfloat,
        .rg32_float => .r32g32_sfloat,
        .rgba32_float => .r32g32b32a32_sfloat,
        .bc1_rgba_unorm => .bc1_rgba_unorm_block,
        .bc3_rgba_unorm => .bc3_unorm_block,
        .bc4_r_unorm => .bc4_unorm_block,
        .bc5_rg_unorm => .bc5_unorm_block,
        .bc6h_rgb_float => .bc6h_ufloat_block,
        .bc7_rgba_unorm => .bc7_unorm_block,
        .bc7_rgba_srgb => .bc7_srgb_block,
        .astc_4x4_rgba_unorm => .astc_4x_4_unorm_block,
        .etc2_rgb8_unorm => .etc2_r8g8b8_unorm_block,
        .etc2_rgba8_unorm => .etc2_r8g8b8a8_unorm_block,
        .eac_r11_unorm => .eac_r11_unorm_block,
        .eac_rg11_unorm => .eac_r11g11_unorm_block,
    };
}
fn toVkImageType(t: TextureType) vk.ImageType {
    return switch (t) {
        .@"1d", .@"1d_array" => .@"1d",
        .@"2d", .@"2d_array", .cube, .cube_array => .@"2d",
        .@"3d" => .@"3d",
    };
}
fn toVkImageViewType(t: TextureType) vk.ImageViewType {
    return switch (t) {
        .@"1d" => .@"1d",
        .@"1d_array" => .@"1d_array",
        .@"2d" => .@"2d",
        .@"2d_array" => .@"2d_array",
        .cube => .cube,
        .cube_array => .cube_array,
        .@"3d" => .@"3d",
    };
}
fn toVkImageUsageFlags(u: TextureUsage) vk.ImageUsageFlags {
    var flags: vk.ImageUsageFlags = .{};
    if (u.sampled) flags.sampled_bit = true;
    if (u.storage) flags.storage_bit = true;
    if (u.transfer_src) flags.transfer_src_bit = true;
    if (u.color_attachment) flags.color_attachment_bit = true;
    if (u.depth_stencil_attachment) flags.depth_stencil_attachment_bit = true;
    return flags;
}
fn toVkFilter(f: Filter) vk.Filter {
    return switch (f) {
        .linear => .linear,
        .nearest => .nearest,
    };
}
fn toVkAddressMode(m: Texture.AddressMode) vk.SamplerAddressMode {
    return switch (m) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
    };
}
fn imageAspect(vk_format: vk.Format) vk.ImageAspectFlags {
    return switch (vk_format) {
        .d16_unorm, .d32_sfloat, .x8_d24_unorm_pack32 => .{ .depth_bit = true },
        .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_sfloat_s8_uint => .{ .depth_bit = true, .stencil_bit = true },
        else => .{ .color_bit = true },
    };
}

// ── Texture methods ─────────────────────
pub fn textureSizeAndAlign(self: *VkBackend, desc: TextureDesc) struct { size: u64, alignment: u64 } {
    const img_info: vk.ImageCreateInfo = .{
        .image_type = toVkImageType(desc.type),
        .format = toVkFormat(desc.format),
        .extent = .{ .width = desc.dimensions[0], .height = desc.dimensions[1], .depth = desc.dimensions[2] },
        .mip_levels = desc.mip_count,
        .array_layers = desc.layer_count,
        .samples = @as(vk.SampleCountFlags, @bitCast(desc.sample_count)),
        .tiling = .optimal,
        .usage = toVkImageUsageFlags(desc.usage),
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    var mem_reqs: vk.MemoryRequirements2 = .{
        .memory_requirements = .{
            .size = 0,
            .alignment = 0,
            .memory_type_bits = 0,
        },
    };
    self.device.getDeviceImageMemoryRequirements(&.{
        .p_create_info = &img_info,
        .plane_aspect = .{},
    }, &mem_reqs);
    return .{ .size = mem_reqs.memory_requirements.size, .alignment = mem_reqs.memory_requirements.alignment };
}
pub fn textureCreate(self: *VkBackend, desc: TextureDesc, storage: GpuPtr, queue_index: u32) !TextureHandle {
    _ = queue_index;
    const img_info: vk.ImageCreateInfo = .{
        .image_type = toVkImageType(desc.type),
        .format = toVkFormat(desc.format),
        .extent = .{ .width = desc.dimensions[0], .height = desc.dimensions[1], .depth = desc.dimensions[2] },
        .mip_levels = desc.mip_count,
        .array_layers = desc.layer_count,
        .samples = switch (desc.sample_count) {
            1 => vk.SampleCountFlags{ .@"1_bit" = true },
            2 => vk.SampleCountFlags{ .@"2_bit" = true },
            4 => vk.SampleCountFlags{ .@"4_bit" = true },
            8 => vk.SampleCountFlags{ .@"8_bit" = true },
            else => vk.SampleCountFlags{ .@"1_bit" = true },
        },
        .tiling = .optimal,
        .usage = blk: {
            var u = toVkImageUsageFlags(desc.usage);
            u.transfer_dst_bit = true;
            break :blk u;
        },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    const image = try self.device.createImage(&img_info, null);
    errdefer self.device.destroyImage(image, null);
    {
        var name_buf: [64]u8 = undefined;
        const iname = std.fmt.bufPrintSentinel(
            &name_buf,
            "tex_img[{}]",
            .{self.textures.items.len + 1},
            0,
        ) catch "tex_img";
        self.setDebugName(.image, @intFromEnum(image), iname);
    }

    const owned_memory = storage.vk_buffer == 0;
    const image_memory: vk.DeviceMemory = if (!owned_memory) blk: {
        const target_buf: vk.Buffer = @enumFromInt(storage.vk_buffer);
        break :blk for (self.allocs.items) |a| {
            if (a.buf == target_buf) break a.memory;
        } else return error.OutOfMemory;
    } else blk: {
        const mem_reqs = self.device.getImageMemoryRequirements(image);
        const mem_type_idx = findMemoryType(
            self,
            mem_reqs.memory_type_bits,
            .{ .device_local_bit = true },
        ) orelse return error.OutOfMemory;
        break :blk try self.device.allocateMemory(&.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type_idx,
        }, null);
    };
    errdefer if (owned_memory) self.device.freeMemory(image_memory, null);
    try self.device.bindImageMemory(image, image_memory, 0);

    // Transition UNDEFINED -> GENERAL
    {
        const pool = try self.device.createCommandPool(&.{
            .queue_family_index = self.queue_family_index,
            .flags = .{ .transient_bit = true },
        }, null);
        defer self.device.destroyCommandPool(pool, null);
        var cb: vk.CommandBuffer = undefined;
        try self.device.allocateCommandBuffers(&.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cb));
        try self.device.beginCommandBuffer(cb, &.{ .flags = .{ .one_time_submit_bit = true } });
        {
            const aspect = imageAspect(toVkFormat(desc.format));
            const barrier: vk.ImageMemoryBarrier2 = .{
                .image = image,
                .subresource_range = .{
                    .aspect_mask = aspect,
                    .base_mip_level = 0,
                    .level_count = desc.mip_count,
                    .base_array_layer = 0,
                    .layer_count = desc.layer_count,
                },
                .old_layout = .undefined,
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .src_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
            };
            self.device.cmdPipelineBarrier2(cb, @ptrCast(&vk.DependencyInfo{
                .image_memory_barrier_count = 1,
                .p_image_memory_barriers = @ptrCast(&barrier),
            }));
        }
        try self.device.endCommandBuffer(cb);
        const cb_handle = cb;
        {
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            {
                const zone_tc = tracy.Zone.begin(.{ .name = "textureUpload", .src = @src(), .color = .tomato });
                defer zone_tc.end();
                try self.queue.submit(&.{vk.SubmitInfo{
                    .command_buffer_count = 1,
                    .p_command_buffers = @ptrCast(&cb_handle),
                }}, .null_handle);
                try self.queue.waitIdle();
            }
        }
    }

    const view_info: vk.ImageViewCreateInfo = .{
        .image = image,
        .view_type = toVkImageViewType(desc.type),
        .format = toVkFormat(desc.format),
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = imageAspect(toVkFormat(desc.format)),
            .base_mip_level = 0,
            .level_count = desc.mip_count,
            .base_array_layer = 0,
            .layer_count = desc.layer_count,
        },
    };
    const default_view = try self.device.createImageView(&view_info, null);
    errdefer self.device.destroyImageView(default_view, null);
    {
        var name_buf: [64]u8 = undefined;
        const vname = std.fmt.bufPrintSentinel(
            &name_buf,
            "tex_view[{}]",
            .{self.textures.items.len + 1},
            0,
        ) catch "tex_view";
        self.setDebugName(.image_view, @intFromEnum(default_view), vname);
    }

    try self.textures.append(self.allocator, .{
        .image = image,
        .default_view = default_view,
        .memory = if (owned_memory) image_memory else .null_handle,
        .format = toVkFormat(desc.format),
        .width = desc.dimensions[0],
        .height = desc.dimensions[1],
        .depth = desc.dimensions[2],
        .mip_levels = desc.mip_count,
    });
    return .{ .tag = .texture, .texture = .{ .id = @intCast(self.textures.items.len), .birth_frame = 0 } };
}

/// Resolve TextureHandle to vk.Image.
fn resolveTextureImage(self: *VkBackend, tex: TextureHandle) ?vk.Image {
    if (tex.isSwapchain()) {
        const s = tex.swapchain;
        if (s.window_index >= self.windows.items.len) return null;
        const win = &self.windows.items[s.window_index];
        if (s.image_index >= win.images.items.len) return null;
        return win.images.items[s.image_index];
    }
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return null;
    const info = &self.textures.items[t.id - 1];
    if (!info.valid) return null;
    return info.image;
}
fn resolveTextureFormat(self: *VkBackend, tex: TextureHandle) vk.Format {
    if (tex.isSwapchain()) {
        const s = tex.swapchain;
        if (s.window_index >= self.windows.items.len) return .undefined;
        return self.windows.items[s.window_index].swapchain_format;
    }
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return .undefined;
    const info = &self.textures.items[t.id - 1];
    if (!info.valid) return .undefined;
    return info.format;
}

/// Resolve TextureHandle to vk.ImageView.
fn resolveTextureView(self: *VkBackend, tex: TextureHandle) ?vk.ImageView {
    if (tex.isSwapchain()) {
        const s = tex.swapchain;
        if (s.window_index >= self.windows.items.len) return null;
        const win = &self.windows.items[s.window_index];
        if (s.image_index >= win.views.items.len) return null;
        return win.views.items[s.image_index];
    }
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return null;
    const info = &self.textures.items[t.id - 1];
    if (!info.valid) return null;
    return info.default_view;
}

pub fn textureDestroy(self: *VkBackend, tex: TextureHandle) void {
    if (tex.isSwapchain()) return;
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return;
    // Destroy all cached views for this texture
    {
        var keys_to_remove = std.ArrayList(u64).empty;
        defer keys_to_remove.deinit(self.allocator);
        var it = self.texture_view_cache.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* >> 32 == t.id) {
                self.device.destroyImageView(entry.value_ptr.*, null);
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch |err|
                    log.warn("textureCleanup: append failed: {}", .{err});
            }
        }
        for (keys_to_remove.items) |key| {
            _ = self.texture_view_cache.remove(key);
        }
    }
    const info = &self.textures.items[t.id - 1];
    self.pending_free.append(self.allocator, .{ .texture = .{
        .image = info.image,
        .view = info.default_view,
        .memory = info.memory,
    } }) catch |err| log.warn("textureDestroy: append failed: {}", .{err});
    info.* = .{
        .valid = false,
        .image = .null_handle,
        .default_view = .null_handle,
        .memory = .null_handle,
        .format = .undefined,
    };
}

pub fn textureViewDescriptor(self: *VkBackend, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    if (tex.isSwapchain()) return 0;
    const t = tex.texture;
    if (t.id == 0 or t.id > self.textures.items.len) return 0;
    const ti = self.textures.items[t.id - 1];

    // Hash the view desc fields (lower 32 bits) + texture id (upper 32 bits)
    var h = std.hash.Wyhash.init(0);
    h.update(&[_]u8{ @intFromEnum(view_desc.type), @intFromEnum(view_desc.format), view_desc.mip_count });
    h.update(std.mem.asBytes(&view_desc.base_mip));
    h.update(std.mem.asBytes(&view_desc.base_layer));
    h.update(std.mem.asBytes(&view_desc.layer_count));
    const view_desc_hash: u32 = @truncate(h.final());
    const cache_key: u64 = (@as(u64, t.id) << 32) | view_desc_hash;

    // Cache hit — return existing view
    if (self.texture_view_cache.get(cache_key)) |cached_view| {
        return @intFromEnum(cached_view);
    }

    // Cache miss — create new view
    const vk_format = if (view_desc.format == .default) ti.format else toVkFormat(view_desc.format);
    const view_info: vk.ImageViewCreateInfo = .{
        .image = ti.image,
        .view_type = toVkImageViewType(view_desc.type),
        .format = vk_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = imageAspect(vk_format),
            .base_mip_level = view_desc.base_mip,
            .level_count = if (view_desc.mip_count == 0) vk.REMAINING_MIP_LEVELS else view_desc.mip_count,
            .base_array_layer = view_desc.base_layer,
            .layer_count = if (view_desc.layer_count == 0) blk: {
                // 3D images require layerCount=1 (VUID-VkImageViewCreateInfo-image-04971)
                break :blk if (view_desc.type == .@"3d") 1 else vk.REMAINING_ARRAY_LAYERS;
            } else view_desc.layer_count,
        },
    };
    const v = self.device.createImageView(&view_info, null) catch return 0;
    self.texture_view_cache.put(cache_key, v) catch {
        self.device.destroyImageView(v, null);
        return 0;
    };
    return @intFromEnum(v);
}
pub fn textureRwViewDescriptor(self: *VkBackend, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.textureViewDescriptor(tex, view_desc);
}
pub fn samplerDescriptor(self: *VkBackend, desc: SamplerDesc) u64 {
    // Hash the sampler desc fields for cache lookup
    var h = std.hash.Wyhash.init(0);
    h.update(&[_]u8{
        @intFromEnum(desc.min_filter),     @intFromEnum(desc.mag_filter),     @intFromEnum(desc.mip_filter),
        @intFromEnum(desc.address_mode_u), @intFromEnum(desc.address_mode_v), @intFromEnum(desc.address_mode_w),
    });
    h.update(std.mem.asBytes(&desc.mip_lod_bias));
    h.update(std.mem.asBytes(&desc.min_lod));
    h.update(std.mem.asBytes(&desc.max_lod));
    h.update(std.mem.asBytes(&desc.max_anisotropy));
    const cache_key: u64 = h.final();

    // Cache hit — return existing sampler
    if (self.sampler_cache.get(cache_key)) |cached_sampler| {
        return @intFromEnum(cached_sampler);
    }

    // Cache miss — create new sampler
    const sampler_info: vk.SamplerCreateInfo = .{
        .mag_filter = toVkFilter(desc.mag_filter),
        .min_filter = toVkFilter(desc.min_filter),
        .mipmap_mode = if (desc.mip_filter == .linear) .linear else .nearest,
        .address_mode_u = toVkAddressMode(desc.address_mode_u),
        .address_mode_v = toVkAddressMode(desc.address_mode_v),
        .address_mode_w = toVkAddressMode(desc.address_mode_w),
        .mip_lod_bias = desc.mip_lod_bias,
        .anisotropy_enable = if (desc.max_anisotropy > 0) @as(vk.Bool32, .true) else .false,
        .max_anisotropy = desc.max_anisotropy,
        .compare_enable = @as(vk.Bool32, @enumFromInt(0)),
        .compare_op = .never,
        .min_lod = desc.min_lod,
        .max_lod = desc.max_lod,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = @as(vk.Bool32, @enumFromInt(0)),
    };
    const s = self.device.createSampler(&sampler_info, null) catch return 0;
    self.sampler_cache.put(cache_key, s) catch {
        self.device.destroySampler(s, null);
        return 0;
    };
    return @intFromEnum(s);
}

// Descriptor heap methods
pub fn descHeapCreate(self: *VkBackend, texture_count: u32, texture_rw_count: u32, sampler_count: u32) !u32 {
    // Pool sizes must be at least as large as the descriptor set layout bindings
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .sampled_image, .descriptor_count = @max(texture_count, max_textures) },
        .{ .type = .storage_image, .descriptor_count = @max(texture_rw_count, max_textures) },
        .{ .type = .sampler, .descriptor_count = @max(sampler_count, max_samplers) },
    };
    const pool = try self.device.createDescriptorPool(&.{
        .flags = .{ .update_after_bind_bit = true, .free_descriptor_set_bit = true },
        .max_sets = 3,
        .pool_size_count = 3,
        .p_pool_sizes = &pool_sizes,
    }, null);
    errdefer self.device.destroyDescriptorPool(pool, null);

    var sets: [3]vk.DescriptorSet = undefined;
    try self.device.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = 3,
        .p_set_layouts = @ptrCast(&self.desc_layouts),
    }, &sets);

    const idx: u32 = @intCast(self.desc_heaps.items.len);
    {
        var name_buf: [64]u8 = undefined;
        const pname = std.fmt.bufPrintSentinel(&name_buf, "desc_pool[{}]", .{idx}, 0) catch "desc_pool";
        self.setDebugName(.descriptor_pool, @intFromEnum(pool), pname);
        const set_labels = [_][]const u8{ "tex", "tex_rw", "samp" };
        for (&sets, set_labels) |*s, label| {
            const sn = std.fmt.bufPrintSentinel(&name_buf, "desc_set_{s}[{}]", .{ label, idx }, 0) catch "desc_set";
            self.setDebugName(.descriptor_set, @intFromEnum(s.*), sn);
        }
    }
    try self.desc_heaps.append(self.allocator, .{ .pool = pool, .sets = sets });
    return idx;
}
pub fn descHeapDestroy(self: *VkBackend, heap_idx: u32) void {
    if (heap_idx < self.desc_heaps.items.len) {
        const dh = &self.desc_heaps.items[heap_idx];
        self.pending_free.append(self.allocator, .{ .desc_heap = .{
            .pool = dh.pool,
            .sets = dh.sets,
        } }) catch |err| log.warn("descHeapDestroy: append failed: {}", .{err});
        // Mark slot invalid instead of swap-removing (keeps indices stable)
        dh.* = .{
            .valid = false,
            .pool = .null_handle,
            .sets = .{ .null_handle, .null_handle, .null_handle },
        };
    }
}
pub fn descHeapSetTextures(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    const buf = self.allocator.alloc(vk.DescriptorImageInfo, descriptors.len) catch return;
    defer self.allocator.free(buf);
    for (descriptors, 0..) |desc, i| {
        buf[i] = .{
            .image_view = @enumFromInt(desc),
            .image_layout = .general,
            .sampler = .null_handle,
        };
    }
    const write: vk.WriteDescriptorSet = .{
        .dst_set = dh.sets[0],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(descriptors.len),
        .descriptor_type = .sampled_image,
        .p_image_info = buf.ptr,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    self.device.updateDescriptorSets(&.{write}, &.{});
}
pub fn descHeapSetTexturesRw(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    const buf = self.allocator.alloc(vk.DescriptorImageInfo, descriptors.len) catch return;
    defer self.allocator.free(buf);
    for (descriptors, 0..) |desc, i| {
        buf[i] = .{
            .image_view = @enumFromInt(desc),
            .image_layout = .general,
            .sampler = .null_handle,
        };
    }
    const write: vk.WriteDescriptorSet = .{
        .dst_set = dh.sets[1],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(descriptors.len),
        .descriptor_type = .storage_image,
        .p_image_info = buf.ptr,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    self.device.updateDescriptorSets(&.{write}, &.{});
}
pub fn descHeapSetSamplers(self: *VkBackend, heap_idx: u32, start_idx: u32, descriptors: []const u64) void {
    if (heap_idx >= self.desc_heaps.items.len or descriptors.len == 0) return;
    const dh = &self.desc_heaps.items[heap_idx];
    const buf = self.allocator.alloc(vk.DescriptorImageInfo, descriptors.len) catch return;
    defer self.allocator.free(buf);
    for (descriptors, 0..) |desc, i| {
        buf[i] = .{
            .sampler = @enumFromInt(desc),
            .image_view = .null_handle,
            .image_layout = .undefined,
        };
    }
    const write: vk.WriteDescriptorSet = .{
        .dst_set = dh.sets[2],
        .dst_binding = 0,
        .dst_array_element = start_idx,
        .descriptor_count = @intCast(descriptors.len),
        .descriptor_type = .sampler,
        .p_image_info = buf.ptr,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    self.device.updateDescriptorSets(&.{write}, &.{});
}

pub fn semaphoreWait(self: *VkBackend, sem: SemaphoreHandle, value: u64) !void {
    _ = try self.device.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = @ptrCast(&sem),
        .p_values = @ptrCast(&value),
    }, std.math.maxInt(u64));
}

fn isBlockCompressed(fmt: vk.Format) bool {
    return switch (fmt) {
        .bc1_rgb_unorm_block,
        .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block,
        .bc1_rgba_srgb_block,
        .bc2_unorm_block,
        .bc2_srgb_block,
        .bc3_unorm_block,
        .bc3_srgb_block,
        .bc4_unorm_block,
        .bc4_snorm_block,
        .bc5_unorm_block,
        .bc5_snorm_block,
        .bc6h_ufloat_block,
        .bc6h_sfloat_block,
        .bc7_unorm_block,
        .bc7_srgb_block,
        => true,
        else => false,
    };
}

pub fn cmdCopyToTexture(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    tex: TextureHandle,
    src: BufferHandle,
    region: TextureRegion,
) void {
    const image = self.resolveTextureImage(tex) orelse return;
    const tex_format = self.resolveTextureFormat(tex);
    const compressed = isBlockCompressed(tex_format);
    const copy: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = if (compressed) 0 else region.size[0],
        .buffer_image_height = if (compressed) 0 else region.size[1],
        .image_subresource = .{
            .aspect_mask = imageAspect(tex_format),
            .mip_level = region.mip_level,
            .base_array_layer = region.base_layer,
            .layer_count = region.layer_count,
        },
        .image_offset = .{
            .x = @as(i32, @intCast(region.rect[0])),
            .y = @as(i32, @intCast(region.rect[1])),
            .z = @as(i32, @intCast(region.rect[2])),
        },
        .image_extent = .{ .width = region.size[0], .height = region.size[1], .depth = region.size[2] },
    };
    self.device.cmdCopyBufferToImage(cmd, src, image, .general, &.{copy});
}

pub fn cmdCopyFromTexture(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    src: TextureHandle,
    dst: BufferHandle,
    region: TextureRegion,
) void {
    const image = self.resolveTextureImage(src) orelse return;
    const tex_format = self.resolveTextureFormat(src);
    const compressed = isBlockCompressed(tex_format);
    const copy: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = if (compressed) 0 else region.size[0],
        .buffer_image_height = if (compressed) 0 else region.size[1],
        .image_subresource = .{
            .aspect_mask = imageAspect(tex_format),
            .mip_level = region.mip_level,
            .base_array_layer = region.base_layer,
            .layer_count = region.layer_count,
        },
        .image_offset = .{
            .x = @as(i32, @intCast(region.rect[0])),
            .y = @as(i32, @intCast(region.rect[1])),
            .z = @as(i32, @intCast(region.rect[2])),
        },
        .image_extent = .{ .width = region.size[0], .height = region.size[1], .depth = region.size[2] },
    };
    self.device.cmdCopyImageToBuffer(cmd, image, .general, dst, &.{copy});
}

pub fn cmdBlitTexture(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    dst: TextureHandle,
    dst_rect: BlitRect,
    src: TextureHandle,
    src_rect: BlitRect,
    filter: Filter,
) void {
    const src_img = self.resolveTextureImage(src) orelse return;
    const dst_img = self.resolveTextureImage(dst) orelse return;
    const src_format = self.resolveTextureFormat(src);
    const dst_format = self.resolveTextureFormat(dst);

    // Resolve zero-rect (both offsets zero) as full-mip blit.
    var src_offsets: [2]vk.Offset3D = .{
        .{ .x = src_rect.offset_a[0], .y = src_rect.offset_a[1], .z = src_rect.offset_a[2] },
        .{ .x = src_rect.offset_b[0], .y = src_rect.offset_b[1], .z = src_rect.offset_b[2] },
    };
    var dst_offsets: [2]vk.Offset3D = .{
        .{ .x = dst_rect.offset_a[0], .y = dst_rect.offset_a[1], .z = dst_rect.offset_a[2] },
        .{ .x = dst_rect.offset_b[0], .y = dst_rect.offset_b[1], .z = dst_rect.offset_b[2] },
    };

    if (src_rect.offset_a[0] == 0 and src_rect.offset_a[1] == 0 and src_rect.offset_a[2] == 0 and
        src_rect.offset_b[0] == 0 and src_rect.offset_b[1] == 0 and src_rect.offset_b[2] == 0)
    {
        if (!src.isSwapchain()) {
            const t = src.texture;
            if (t.id > 0 and t.id <= self.textures.items.len) {
                const info = &self.textures.items[t.id - 1];
                if (info.valid) {
                    const mip_w = @max(1, info.width >> @as(u5, @intCast(src_rect.mip_level)));
                    const mip_h = @max(1, info.height >> @as(u5, @intCast(src_rect.mip_level)));
                    src_offsets[1] = .{ .x = @as(i32, @intCast(mip_w)), .y = @as(i32, @intCast(mip_h)), .z = 1 };
                }
            }
        }
    }
    if (dst_rect.offset_a[0] == 0 and dst_rect.offset_a[1] == 0 and dst_rect.offset_a[2] == 0 and
        dst_rect.offset_b[0] == 0 and dst_rect.offset_b[1] == 0 and dst_rect.offset_b[2] == 0)
    {
        if (!dst.isSwapchain()) {
            const t = dst.texture;
            if (t.id > 0 and t.id <= self.textures.items.len) {
                const info = &self.textures.items[t.id - 1];
                if (info.valid) {
                    const mip_w = @max(1, info.width >> @as(u5, @intCast(dst_rect.mip_level)));
                    const mip_h = @max(1, info.height >> @as(u5, @intCast(dst_rect.mip_level)));
                    dst_offsets[1] = .{ .x = @as(i32, @intCast(mip_w)), .y = @as(i32, @intCast(mip_h)), .z = 1 };
                }
            }
        }
    }

    const blit: vk.ImageBlit = .{
        .src_subresource = .{
            .aspect_mask = imageAspect(src_format),
            .mip_level = src_rect.mip_level,
            .base_array_layer = src_rect.base_layer,
            .layer_count = src_rect.layer_count,
        },
        .src_offsets = src_offsets,
        .dst_subresource = .{
            .aspect_mask = imageAspect(dst_format),
            .mip_level = dst_rect.mip_level,
            .base_array_layer = dst_rect.base_layer,
            .layer_count = dst_rect.layer_count,
        },
        .dst_offsets = dst_offsets,
    };
    self.device.cmdBlitImage(cmd, src_img, .general, dst_img, .general, &.{blit}, toVkFilter(filter));
}

pub fn gpuMalloc(self: *VkBackend, size: u64, alignment: u29, mem_type: MemoryType) !GpuPtr {
    if (size == 0) return .{};

    const usage: vk.BufferUsageFlags = .{
        .shader_device_address_bit = true,
        .storage_buffer_bit = true,
        .vertex_buffer_bit = true,
        .index_buffer_bit = true,
        .transfer_src_bit = true,
        .transfer_dst_bit = true,
        .indirect_buffer_bit = true,
    };
    const buf = try self.device.createBuffer(&vk.BufferCreateInfo{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer self.device.destroyBuffer(buf, null);
    {
        var name_buf: [64]u8 = undefined;
        const mem_label = switch (mem_type) {
            .gpu => "gpu",
            .default => "host",
            .readback => "read",
        };
        const bname = std.fmt.bufPrintSentinel(
            &name_buf,
            "buf_{s}[{}]",
            .{ mem_label, self.allocs.items.len },
            0,
        ) catch "buf";
        self.setDebugName(.buffer, @intFromEnum(buf), bname);
    }

    const mem_reqs = self.device.getBufferMemoryRequirements(buf);
    const mem_props: vk.MemoryPropertyFlags = switch (mem_type) {
        .default => .{ .host_visible_bit = true, .host_coherent_bit = true },
        .gpu => .{ .device_local_bit = true },
        .readback => .{ .host_visible_bit = true, .host_cached_bit = true, .host_coherent_bit = true },
    };

    const mem_type_index = findMemoryType(self, mem_reqs.memory_type_bits, mem_props) orelse return error.OutOfMemory;
    const flags_info: vk.MemoryAllocateFlagsInfo = .{
        .flags = .{ .device_address_bit = true },
        .device_mask = 0,
    };
    const memory = try self.device.allocateMemory(&vk.MemoryAllocateInfo{
        .p_next = @ptrCast(&flags_info),
        .allocation_size = blk: {
            const aligned_size = (mem_reqs.size + alignment - 1) & ~(@as(u64, alignment) - 1);
            break :blk aligned_size;
        },
        .memory_type_index = mem_type_index,
    }, null);
    errdefer self.device.freeMemory(memory, null);

    try self.device.bindBufferMemory(buf, memory, 0);

    var cpu: ?[*]u8 = null;
    if (mem_type != .gpu) {
        cpu = @ptrCast((try self.device.mapMemory(memory, 0, size, .{})).?);
    }

    const addr_info: vk.BufferDeviceAddressInfo = .{ .buffer = buf };
    const gpu_addr = self.device.getBufferDeviceAddress(&addr_info);

    try self.allocs.append(self.allocator, .{
        .buf = buf,
        .memory = memory,
        .gpu_addr = gpu_addr,
        .cpu = cpu,
        .size = size,
    });
    return .{
        .cpu = if (cpu) |c| c else @ptrCast(@constCast(&[0]u8{})),
        .gpu = gpu_addr,
        .vk_buffer = @intFromEnum(buf),
    };
}

pub fn gpuFree(self: *VkBackend, ptr: GpuPtr) void {
    const target: vk.Buffer = @enumFromInt(ptr.vk_buffer);
    for (self.allocs.items, 0..) |info, i| {
        if (info.buf == target) {
            self.pending_free.append(self.allocator, .{ .buffer = .{
                .buf = info.buf,
                .memory = info.memory,
                .cpu = info.cpu,
            } }) catch |err| log.warn("gpuFree: append failed: {}", .{err});
            _ = self.allocs.swapRemove(i);
            return;
        }
    }
}

pub fn gpuHostToDevicePointer(self: *VkBackend, cpu_ptr: [*]u8) GpuPtr {
    for (self.allocs.items) |alloc| {
        if (alloc.cpu) |base| {
            const start = @intFromPtr(base);
            const end = start + alloc.size;
            const ptr = @intFromPtr(cpu_ptr);
            if (ptr >= start and ptr < end) {
                return .{
                    .cpu = cpu_ptr,
                    .gpu = alloc.gpu_addr + @as(u64, @intCast(ptr - start)),
                };
            }
        }
    }
    return .{ .cpu = cpu_ptr, .gpu = @intFromPtr(cpu_ptr) };
}

pub fn cmdMemCopy(self: *VkBackend, cmd: CommandBufferHandle, src: BufferHandle, dst: BufferHandle, bytes: u64) void {
    self.device.cmdCopyBuffer(cmd, src, dst, &.{vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = bytes,
    }});
}

pub fn cmdSetVertexInput(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    bindings: []const VertexBinding,
    attributes: []const VertexAttribute,
) void {
    var vk_bindings: [8]vk.VertexInputBindingDescription2EXT = undefined;
    var vk_attribs: [16]vk.VertexInputAttributeDescription2EXT = undefined;
    const binding_count = @min(bindings.len, 8);
    const attrib_count = @min(attributes.len, 16);
    for (bindings[0..binding_count], 0..) |b, i| {
        vk_bindings[i] = .{
            .binding = b.binding,
            .stride = b.stride,
            .input_rate = @enumFromInt(b.input_rate),
            .divisor = 1,
        };
    }
    for (attributes[0..attrib_count], 0..) |a, i| {
        vk_attribs[i] = .{
            .location = a.location,
            .binding = a.binding,
            .format = @enumFromInt(a.format),
            .offset = a.offset,
        };
    }
    self.device.cmdSetVertexInputEXT(cmd, vk_bindings[0..binding_count], vk_attribs[0..attrib_count]);
}

pub fn cmdBindVertexBuffer(
    self: *VkBackend,
    cmd: CommandBufferHandle,
    binding: u32,
    buf: BufferHandle,
    offset: u64,
) void {
    self.device.cmdBindVertexBuffers(cmd, binding, &.{buf}, &.{offset});
}

fn findMemoryType(self: *VkBackend, type_bits: u32, properties: vk.MemoryPropertyFlags) ?u32 {
    for (self.mem_props.memory_types, 0..) |mt, i| {
        if ((type_bits & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and
            mt.property_flags.contains(properties)) return @intCast(i);
    }
    return null;
}

/// Validate an application present ID against the active timing extension.
/// Zero and non-monotonic IDs are invalid; the Google fallback is u32-bounded.
fn validatePresentTimingId(mode: PresentTimingMode, last_id: u64, timing_id: u64) !void {
    if (mode == .unsupported) return error.PresentTimingUnsupported;
    if (timing_id == 0) return error.InvalidPresentTimingId;
    if (timing_id <= last_id) return error.InvalidPresentTimingId;
    if (mode == .google and timing_id > std.math.maxInt(u32)) return error.PresentTimingIdOutOfRange;
}
fn validatePresentTimingRequest(
    mode: PresentTimingMode,
    last_id: u64,
    timing_id: u64,
    outstanding: u32,
    capacity: u32,
) !void {
    try validatePresentTimingId(mode, last_id, timing_id);
    if (outstanding >= capacity) return error.PresentTimingQueueFull;
}

/// Validate the driver count before retrieval. The count must fit both the
/// fixed scratch storage and the timed presents still owned by this surface.
fn validatePresentFeedbackBatch(
    outstanding: u32,
    available: u32,
    out_len: usize,
) !void {
    if (available > max_present_feedback or available > outstanding)
        return error.PresentFeedbackBackendError;
    if (available > out_len) return error.OutputTooSmall;
}

fn presentTimingBatchHasCompleteZero(records: []const PresentRecord) bool {
    for (records) |record| {
        if (record.completed and record.actual_present_ns == 0) return true;
    }
    return false;
}

/// A successful driver retrieval consumes every returned record, including
/// records that later normalize as incomplete or invalid.
fn commitPresentFeedbackBatch(
    mode: PresentTimingMode,
    last_completed_id: *u64,
    outstanding: *u32,
    records: []const PresentRecord,
    normalized: []PresentFeedback,
    out: []PresentFeedback,
) !usize {
    if (records.len > max_present_feedback or records.len > outstanding.*)
        return error.PresentFeedbackBackendError;
    if (records.len > out.len) return error.OutputTooSmall;
    outstanding.* -= @intCast(records.len);
    if (presentTimingBatchHasCompleteZero(records))
        return error.PresentTimingDataUnavailable;
    return normalizePresentFeedback(mode, last_completed_id, records, normalized, out);
}

/// Normalize injected backend presentation records into sorted completed
/// feedback. Pure function so tests stay deterministic; the real poll feeds it
/// driver records. Nothing is consumed or mutated on failure.
fn normalizePresentFeedback(
    mode: PresentTimingMode,
    last_completed_id: *u64,
    records: []const PresentRecord,
    normalized: []PresentFeedback,
    out: []PresentFeedback,
) !usize {
    if (records.len > normalized.len) return error.OutputTooSmall;
    var completed_count: usize = 0;
    for (records) |record| {
        if (!record.completed or record.actual_present_ns == 0) continue;
        completed_count += 1;
    }
    // Reject before consuming anything so no feedback is ever dropped.
    if (completed_count > out.len) return error.OutputTooSmall;

    var index: usize = 0;

    for (records) |record| {
        if (!record.completed or record.actual_present_ns == 0) continue;
        try validatePresentTimingId(mode, last_completed_id.*, record.present_id);
        normalized[index] = .{
            .present_id = record.present_id,
            .actual_present_ns = record.actual_present_ns,
        };
        index += 1;
    }
    const completed = normalized[0..completed_count];
    std.mem.sort(PresentFeedback, completed, {}, struct {
        fn lessThan(_: void, a: PresentFeedback, b: PresentFeedback) bool {
            return a.present_id < b.present_id;
        }
    }.lessThan);
    // One monotonic pass covers both adjacent duplicates and cross-poll
    // regression; avoids len-1 indexing.
    var previous_id = last_completed_id.*;
    for (completed) |feedback| {
        if (feedback.present_id <= previous_id) return error.DuplicatePresentFeedback;
        previous_id = feedback.present_id;
    }
    @memcpy(out[0..completed_count], completed);
    last_completed_id.* = previous_id;
    return completed_count;
}

test "task4 presentation timing rejects unsupported zero duplicate and Google overflow IDs" {
    try std.testing.expectError(
        error.PresentTimingUnsupported,
        validatePresentTimingId(.unsupported, 0, 1),
    );
    try std.testing.expectError(
        error.InvalidPresentTimingId,
        validatePresentTimingId(.ext, 0, 0),
    );
    try std.testing.expectError(
        error.InvalidPresentTimingId,
        validatePresentTimingId(.ext, 7, 7),
    );
    try std.testing.expectError(
        error.PresentTimingIdOutOfRange,
        validatePresentTimingId(.google, 0, @as(u64, std.math.maxInt(u32)) + 1),
    );
}

test "task4 presentation feedback sorts completed records and rejects duplicates" {
    var last_completed_id: u64 = 1;
    var out: [3]PresentFeedback = undefined;
    var normalized: [3]PresentFeedback = undefined;
    const count = try normalizePresentFeedback(
        .ext,
        &last_completed_id,
        &.{
            .{ .present_id = 4, .actual_present_ns = 400, .completed = true },
            .{ .present_id = 2, .actual_present_ns = 200, .completed = true },
            .{ .present_id = 3, .actual_present_ns = 300, .completed = false },
        },
        &normalized,
        &out,
    );
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u64, 2), out[0].present_id);
    try std.testing.expectEqual(@as(u64, 4), out[1].present_id);
    try std.testing.expectEqual(@as(u64, 4), last_completed_id);

    last_completed_id = 1;
    try std.testing.expectError(
        error.DuplicatePresentFeedback,
        normalizePresentFeedback(
            .google,
            &last_completed_id,
            &.{
                .{ .present_id = 2, .actual_present_ns = 200, .completed = true },
                .{ .present_id = 2, .actual_present_ns = 201, .completed = true },
            },
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), last_completed_id);
}

test "task4 presentation output too small and invalid data consume nothing" {
    var last_completed_id: u64 = 1;
    const sentinel = [_]PresentFeedback{.{ .present_id = 91, .actual_present_ns = 910 }};
    var out = sentinel;
    var normalized: [2]PresentFeedback = undefined;
    try std.testing.expectError(
        error.OutputTooSmall,
        normalizePresentFeedback(
            .ext,
            &last_completed_id,
            &.{
                .{ .present_id = 2, .actual_present_ns = 200, .completed = true },
                .{ .present_id = 3, .actual_present_ns = 300, .completed = true },
            },
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqualDeep(sentinel, out);
    try std.testing.expectEqual(@as(u64, 1), last_completed_id);

    try std.testing.expectError(
        error.InvalidPresentTimingId,
        normalizePresentFeedback(
            .ext,
            &last_completed_id,
            &.{.{ .present_id = 0, .actual_present_ns = 1, .completed = true }},
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqualDeep(sentinel, out);
    try std.testing.expectEqual(@as(u64, 1), last_completed_id);

    var outstanding: u32 = 2;
    try std.testing.expectError(
        error.OutputTooSmall,
        commitPresentFeedbackBatch(
            .ext,
            &last_completed_id,
            &outstanding,
            &.{
                .{ .present_id = 2, .actual_present_ns = 200, .completed = true },
                .{ .present_id = 3, .actual_present_ns = 300, .completed = true },
            },
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqual(@as(u32, 2), outstanding);
    try std.testing.expectEqual(@as(u64, 1), last_completed_id);
    try std.testing.expectEqualDeep(sentinel, out);
}

test "task4 per-surface timing mode prefers ext only with complete support" {
    const visible: vk.PresentStageFlagsEXT = .{ .image_first_pixel_visible_bit_ext = true };
    const support: SurfacePresentTimingSupport = .{
        .present_id2 = true,
        .present_timing = true,
        .stage = visible,
        .time_domain_id = 7,
        .time_domain_valid = true,
    };
    try std.testing.expectEqual(
        PresentTimingMode.ext,
        resolvePresentTimingMode(true, support, true),
    );

    var incomplete = support;
    incomplete.present_id2 = false;
    try std.testing.expectEqual(
        PresentTimingMode.google,
        resolvePresentTimingMode(true, incomplete, true),
    );
    incomplete = support;
    incomplete.time_domain_valid = false;
    try std.testing.expectEqual(
        PresentTimingMode.unsupported,
        resolvePresentTimingMode(true, incomplete, false),
    );
    try std.testing.expectEqual(
        PresentTimingMode.google,
        resolveSurfacePresentTimingMode(false, incomplete, true),
    );
}

test "task4 EXT timing requires calibrated timestamps and enables them once" {
    try std.testing.expect(extPresentTimingExtensionsAvailable(true, true, true, true));
    try std.testing.expect(!extPresentTimingExtensionsAvailable(true, true, true, false));
    try std.testing.expect(needsCalibratedTimestamps(true, false));
    try std.testing.expect(needsCalibratedTimestamps(false, true));
    try std.testing.expect(needsCalibratedTimestamps(true, true));
    try std.testing.expect(!needsCalibratedTimestamps(false, false));
}

test "task4 timed presents permit 64 outstanding and reject the 65th" {
    inline for (.{ PresentTimingMode.ext, PresentTimingMode.google }) |mode| {
        try validatePresentTimingRequest(mode, 63, 64, 63, max_present_feedback);
        try std.testing.expectError(
            error.PresentTimingQueueFull,
            validatePresentTimingRequest(mode, 64, 65, 64, max_present_feedback),
        );
    }
}

test "task4 feedback batches reclaim every consumed timing slot" {
    inline for (.{ PresentTimingMode.ext, PresentTimingMode.google }) |mode| {
        var last_completed_id: u64 = 1;
        var outstanding: u32 = 4;
        var normalized: [3]PresentFeedback = undefined;
        var out: [3]PresentFeedback = undefined;
        const completed = try commitPresentFeedbackBatch(
            mode,
            &last_completed_id,
            &outstanding,
            &.{
                .{ .present_id = 2, .actual_present_ns = 200, .completed = true },
                .{ .present_id = 3, .actual_present_ns = 0, .completed = false },
                .{ .present_id = 4, .actual_present_ns = 400, .completed = true },
            },
            &normalized,
            &out,
        );
        try std.testing.expectEqual(@as(usize, 2), completed);
        try std.testing.expectEqual(@as(u32, 1), outstanding);
        try std.testing.expectEqual(@as(u64, 4), last_completed_id);
        try std.testing.expectEqual(@as(u64, 2), out[0].present_id);
        try std.testing.expectEqual(@as(u64, 4), out[1].present_id);
    }
}

test "task4 failed commit reclaims consumed slots transactionally" {
    try std.testing.expectError(
        error.PresentFeedbackBackendError,
        validatePresentFeedbackBatch(max_present_feedback, max_present_feedback + 1, 65),
    );
    try std.testing.expectError(
        error.OutputTooSmall,
        validatePresentFeedbackBatch(4, 4, 3),
    );

    var last_completed_id: u64 = 1;
    var outstanding: u32 = 2;
    const sentinel = [_]PresentFeedback{
        .{ .present_id = 91, .actual_present_ns = 910 },
        .{ .present_id = 92, .actual_present_ns = 920 },
    };
    var normalized: [2]PresentFeedback = undefined;
    var out = sentinel;
    try std.testing.expectError(
        error.DuplicatePresentFeedback,
        commitPresentFeedbackBatch(
            .google,
            &last_completed_id,
            &outstanding,
            &.{
                .{ .present_id = 2, .actual_present_ns = 200, .completed = true },
                .{ .present_id = 2, .actual_present_ns = 201, .completed = true },
            },
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), outstanding);
    try std.testing.expectEqual(@as(u64, 1), last_completed_id);
    try std.testing.expectEqualDeep(sentinel, out);
}

test "task4 generic timestamps need only a period and queue valid bits" {
    try std.testing.expect(timestampQueriesAvailable(1.0, 32));
    try std.testing.expect(!timestampQueriesAvailable(0.0, 32));
    try std.testing.expect(!timestampQueriesAvailable(1.0, 0));
}

test "task4 timestamp query handles are compact noapi tokens" {
    try std.testing.expectEqual(@as(usize, @sizeOf(u32)), @sizeOf(TimestampQueryHandle));
}

test "task4 feedback normalization leaves output untouched on error" {
    var last_completed_id: u64 = 1;
    const sentinel = [_]PresentFeedback{
        .{ .present_id = 91, .actual_present_ns = 910 },
        .{ .present_id = 92, .actual_present_ns = 920 },
    };
    var out = sentinel;
    var normalized: [2]PresentFeedback = undefined;
    try std.testing.expectError(
        error.DuplicatePresentFeedback,
        normalizePresentFeedback(
            .google,
            &last_completed_id,
            &.{
                .{ .present_id = 2, .actual_present_ns = 200, .completed = true },
                .{ .present_id = 2, .actual_present_ns = 201, .completed = true },
            },
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqualDeep(sentinel, out);
    try std.testing.expectEqual(@as(u64, 1), last_completed_id);

    const completed = try normalizePresentFeedback(
        .google,
        &last_completed_id,
        &.{
            .{ .present_id = 2, .actual_present_ns = 0, .completed = true },
            .{ .present_id = 3, .actual_present_ns = 300, .completed = true },
        },
        &normalized,
        &out,
    );
    try std.testing.expectEqual(@as(usize, 1), completed);
    try std.testing.expectEqual(@as(u64, 3), out[0].present_id);
}
test "task4 presentation diagnostics retain bounded EXT query evidence" {
    var diagnostics: PresentTimingDiagnostics = .{};
    diagnostics.noteExtProbe(.success, 2, 11, 13);
    diagnostics.noteExtRetrieve(.incomplete, 1, 17, 19);
    diagnostics.noteExtRecord(
        42,
        1,
        .{ .image_first_pixel_out_bit_ext = true },
        1234,
        true,
    );

    try std.testing.expectEqual(@as(u64, 1), diagnostics.ext_probe_calls);
    try std.testing.expectEqual(PresentTimingCallResult.success, diagnostics.ext_probe_result);
    try std.testing.expectEqual(@as(u32, 2), diagnostics.ext_probe_count);
    try std.testing.expectEqual(@as(u64, 11), diagnostics.ext_probe_timing_properties_counter);
    try std.testing.expectEqual(@as(u64, 13), diagnostics.ext_probe_time_domains_counter);
    try std.testing.expectEqual(PresentTimingCallResult.incomplete, diagnostics.ext_retrieve_result);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.ext_retrieve_count);
    try std.testing.expectEqual(@as(u64, 17), diagnostics.ext_retrieve_timing_properties_counter);
    try std.testing.expectEqual(@as(u64, 19), diagnostics.ext_retrieve_time_domains_counter);
    try std.testing.expectEqual(@as(u64, 42), diagnostics.ext_last_record_id);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.ext_last_record_stage_count);
    try std.testing.expectEqual(@as(u32, 4), diagnostics.ext_last_record_stage_bits);
    try std.testing.expectEqual(@as(u64, 1234), diagnostics.ext_last_record_time);
    try std.testing.expect(diagnostics.ext_last_record_complete);
}

test "task4 present timing watchdog uses monotonic deadline boundaries" {
    const start: i96 = 100;
    try std.testing.expectEqual(
        PresentTimingWatchdogDecision.wait,
        presentTimingWatchdogDecision(1, start, start + 4_999_999_999),
    );
    try std.testing.expectEqual(
        PresentTimingWatchdogDecision.disable,
        presentTimingWatchdogDecision(1, start, start + 5_000_000_000),
    );
    try std.testing.expectEqual(
        PresentTimingWatchdogDecision.wait,
        presentTimingWatchdogDecision(0, start, start + 5_000_000_000),
    );
    try std.testing.expectEqual(
        PresentTimingWatchdogDecision.wait,
        presentTimingWatchdogDecision(1, null, start + 5_000_000_000),
    );
}
test "task4 present timing watchdog resets after completed progress" {
    const initial_start: ?i96 = 100;
    const progressed_start = presentTimingWatchdogProgressStart(
        1,
        initial_start,
        5_000_000_100,
        1,
    );
    try std.testing.expectEqual(@as(?i96, 5_000_000_100), progressed_start);
    try std.testing.expectEqual(
        PresentTimingWatchdogDecision.wait,
        presentTimingWatchdogDecision(1, progressed_start, 9_999_999_999),
    );
    try std.testing.expectEqual(
        PresentTimingWatchdogDecision.disable,
        presentTimingWatchdogDecision(1, progressed_start, 10_000_000_100),
    );
    try std.testing.expectEqual(
        @as(?i96, null),
        presentTimingWatchdogProgressStart(0, progressed_start, 10_000_000_100, 1),
    );
    try std.testing.expectEqual(
        initial_start,
        presentTimingWatchdogProgressStart(1, initial_start, 10_000_000_100, 0),
    );
}

test "task4 runtime timing failure falls back EXT to Google then unsupported" {
    var win: Window = .{
        .timing_mode = .ext,
        .present_stage_queries = .{ .image_first_pixel_out_bit_ext = true },
        .present_stage_support = .{ .image_first_pixel_out_bit_ext = true },
        .present_time_domain_count = 1,
        .time_domain_id = 17,
        .time_domain_valid = true,
        .last_present_timing_id = 23,
        .last_feedback_id = 22,
        .outstanding_timed_presents = 3,
        .first_timed_present_start_ns = std.Io.Timestamp.fromNanoseconds(100),
        .present_timing_diagnostics = .{
            .mode = .ext,
            .outstanding_timed_presents = 3,
            .ext_last_record_id = 21,
            .ext_last_record_time = 2_100,
            .ext_complete_records = 4,
            .ext_positive_records = 3,
        },
    };

    abandonPresentTiming(&win, true);
    try std.testing.expectEqual(PresentTimingMode.google, win.timing_mode);
    try std.testing.expectEqual(@as(u64, 23), win.last_present_timing_id);
    try std.testing.expectEqual(@as(u64, 22), win.last_feedback_id);
    try std.testing.expectError(
        error.InvalidPresentTimingId,
        validatePresentTimingId(.google, win.last_present_timing_id, 22),
    );
    try std.testing.expectError(
        error.InvalidPresentTimingId,
        validatePresentTimingId(.google, win.last_present_timing_id, 23),
    );
    try validatePresentTimingId(.google, win.last_present_timing_id, 24);
    try std.testing.expectEqual(@as(u32, 0), win.outstanding_timed_presents);
    try std.testing.expectEqual(@as(?std.Io.Timestamp, null), win.first_timed_present_start_ns);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(win.present_stage_queries)));
    try std.testing.expectEqual(@as(u32, 0), win.present_time_domain_count);
    try std.testing.expectEqual(PresentTimingMode.google, win.present_timing_diagnostics.mode);
    try std.testing.expectEqual(@as(u64, 21), win.present_timing_diagnostics.ext_last_record_id);
    try std.testing.expectEqual(@as(u64, 2_100), win.present_timing_diagnostics.ext_last_record_time);
    try std.testing.expectEqual(@as(u32, 4), win.present_timing_diagnostics.ext_complete_records);
    try std.testing.expectEqual(@as(u32, 3), win.present_timing_diagnostics.ext_positive_records);

    win.last_present_timing_id = 7;
    win.last_feedback_id = 6;
    win.outstanding_timed_presents = 1;
    win.first_timed_present_start_ns = std.Io.Timestamp.fromNanoseconds(200);
    abandonPresentTiming(&win, true);
    try std.testing.expectEqual(PresentTimingMode.unsupported, win.timing_mode);
    try std.testing.expectEqual(@as(u64, 7), win.last_present_timing_id);
    try std.testing.expectEqual(@as(u64, 6), win.last_feedback_id);
    try std.testing.expectEqual(@as(u32, 0), win.outstanding_timed_presents);
    try std.testing.expectEqual(@as(?std.Io.Timestamp, null), win.first_timed_present_start_ns);
}

test "task4 EXT runtime fallback requires a usable Google ID range" {
    var no_google: Window = .{
        .timing_mode = .ext,
        .last_present_timing_id = 1,
    };
    abandonPresentTiming(&no_google, false);
    try std.testing.expectEqual(PresentTimingMode.unsupported, no_google.timing_mode);

    var exhausted_google: Window = .{
        .timing_mode = .ext,
        .last_present_timing_id = std.math.maxInt(u32),
    };
    abandonPresentTiming(&exhausted_google, true);
    try std.testing.expectEqual(PresentTimingMode.unsupported, exhausted_google.timing_mode);

    var exhausted_feedback: Window = .{
        .timing_mode = .ext,
        .last_feedback_id = std.math.maxInt(u32),
    };
    abandonPresentTiming(&exhausted_feedback, true);
    try std.testing.expectEqual(PresentTimingMode.unsupported, exhausted_feedback.timing_mode);
}

test "task4 Google feedback high-water survives EXT fallback" {
    var win: Window = .{
        .timing_mode = .ext,
        .last_present_timing_id = 50,
        .last_feedback_id = 10,
    };
    abandonPresentTiming(&win, true);
    try std.testing.expectEqual(PresentTimingMode.google, win.timing_mode);

    var normalized: [1]PresentFeedback = undefined;
    var out: [1]PresentFeedback = undefined;
    try std.testing.expectError(
        error.InvalidPresentTimingId,
        normalizePresentFeedback(
            .google,
            &win.last_feedback_id,
            &.{.{ .present_id = 9, .actual_present_ns = 900, .completed = true }},
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqual(@as(u64, 10), win.last_feedback_id);
    try std.testing.expectError(
        error.InvalidPresentTimingId,
        normalizePresentFeedback(
            .google,
            &win.last_feedback_id,
            &.{.{ .present_id = 10, .actual_present_ns = 1_000, .completed = true }},
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqual(@as(u64, 10), win.last_feedback_id);
    try std.testing.expectEqual(
        @as(usize, 1),
        try normalizePresentFeedback(
            .google,
            &win.last_feedback_id,
            &.{.{ .present_id = 11, .actual_present_ns = 1_100, .completed = true }},
            &normalized,
            &out,
        ),
    );
    try std.testing.expectEqual(@as(u64, 11), win.last_feedback_id);
}

test "task4 mixed positive and complete-zero batch fails before output commit" {
    inline for (.{ PresentTimingMode.ext, PresentTimingMode.google }) |mode| {
        var last_completed_id: u64 = 4;
        var outstanding: u32 = 3;
        var normalized: [2]PresentFeedback = undefined;
        const sentinel = [_]PresentFeedback{
            .{ .present_id = 91, .actual_present_ns = 910 },
            .{ .present_id = 92, .actual_present_ns = 920 },
        };
        var out = sentinel;

        try std.testing.expectError(
            error.PresentTimingDataUnavailable,
            commitPresentFeedbackBatch(
                mode,
                &last_completed_id,
                &outstanding,
                &.{
                    .{ .present_id = 5, .actual_present_ns = 500, .completed = true },
                    .{ .present_id = 6, .actual_present_ns = 0, .completed = true },
                },
                &normalized,
                &out,
            ),
        );
        try std.testing.expectEqual(@as(u64, 4), last_completed_id);
        try std.testing.expectEqual(@as(u32, 1), outstanding);
        try std.testing.expectEqualDeep(sentinel, out);
    }
}

test "task4 incomplete zero and later positive batches remain usable" {
    inline for (.{ PresentTimingMode.ext, PresentTimingMode.google }) |mode| {
        var last_completed_id: u64 = 4;
        var outstanding: u32 = 3;
        var normalized: [2]PresentFeedback = undefined;
        var out: [2]PresentFeedback = undefined;

        const completed = try commitPresentFeedbackBatch(
            mode,
            &last_completed_id,
            &outstanding,
            &.{
                .{ .present_id = 5, .actual_present_ns = 0, .completed = false },
                .{ .present_id = 6, .actual_present_ns = 600, .completed = true },
            },
            &normalized,
            &out,
        );
        try std.testing.expectEqual(@as(usize, 1), completed);
        try std.testing.expectEqual(@as(u64, 6), last_completed_id);
        try std.testing.expectEqual(@as(u32, 1), outstanding);
        try std.testing.expectEqual(@as(u64, 6), out[0].present_id);
    }
}

test "task4 frame result marks only OutOfDate presents" {
    try std.testing.expect(!frameResultForPresentQueue(.success).present_out_of_date);
    try std.testing.expect(!frameResultForPresentQueue(.suboptimal).present_out_of_date);
    try std.testing.expect(frameResultForPresentQueue(.out_of_date).present_out_of_date);
    try std.testing.expect(!frameResultForPresentQueue(.surface_lost).present_out_of_date);
}

test "task4 OutOfDate preserves timing state and advances frame recovery" {
    var win: Window = .{
        .frames_in_flight = 2,
        .frame_index = 0,
        .last_present_timing_id = 17,
        .last_feedback_id = 16,
        .outstanding_timed_presents = 2,
    };

    const failed = notePresentQueueFailure(&win, error.OutOfDateKHR);
    try std.testing.expect(failed.present_out_of_date);
    try std.testing.expect(win.needs_resize);
    try std.testing.expectEqual(@as(u32, 0), win.frame_index);
    try std.testing.expectEqual(@as(u64, 17), win.last_present_timing_id);
    try std.testing.expectEqual(@as(u64, 16), win.last_feedback_id);
    try std.testing.expectEqual(@as(u32, 2), win.outstanding_timed_presents);

    advanceFrame(&win, 0);
    try std.testing.expectEqual(@as(u32, 1), win.frame_index);
    const recovered = frameResultForPresentQueue(.success);
    try std.testing.expect(!recovered.present_out_of_date);
    advanceFrame(&win, 1);
    try std.testing.expectEqual(@as(u32, 0), win.frame_index);
}
