//! Optional system-loader adapter. The frame product does not depend on SDL.
const std = @import("std");
const noapi = @import("noapi");

/// Keep this library open until every GPU made from `options()` is destroyed.
pub const SystemVulkanLoader = struct {
    library: std.DynLib,
    get_proc_addr: noapi.vk.PfnGetInstanceProcAddr,

    pub fn open() !SystemVulkanLoader {
        var library = try std.DynLib.open("libvulkan.so.1");
        errdefer library.close();
        const get_proc_addr = library.lookup(
            noapi.vk.PfnGetInstanceProcAddr,
            "vkGetInstanceProcAddr",
        ) orelse return error.VulkanLoaderMissingEntryPoint;
        return .{ .library = library, .get_proc_addr = get_proc_addr };
    }

    pub fn options(self: *const SystemVulkanLoader) noapi.VkBackend.Options.Loader {
        return .{ .get_instance_proc_addr = self.get_proc_addr };
    }

    pub fn close(self: *SystemVulkanLoader) void {
        self.library.close();
        // SAFETY: the library handle is the only resource this value owns and
        // it is closed above, so the poison leaks nothing. A second close, or
        // a lookup through `get_proc_addr`, now traps instead of calling into
        // an unloaded library.
        self.* = undefined;
    }
};
