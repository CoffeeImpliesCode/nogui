//! Texture resource + format/type/view/sampler descriptors.
const std = @import("std");
const Gpu = @import("Gpu.zig");
const TextureHandle = @import("TextureHandle.zig");
const Texture = @This();

pub const TextureFormat = enum(u8) {
    default,
    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    abgr8_unorm,
    bgra8_unorm,
    r8_srgb,
    rg8_srgb,
    rgba8_srgb,
    abgr8_srgb,
    bgra8_srgb,
    r16_unorm,
    rg16_unorm,
    rgba16_unorm,
    d16_unorm,
    d16_unorm_s8_uint,
    d24_unorm_pack32,
    d24_unorm_s8_uint,
    d32_float,
    r16_float,
    rg16_float,
    rgba16_float,
    r32_float,
    rg32_float,
    rgba32_float,
    bc1_rgba_unorm,
    bc3_rgba_unorm,
    bc4_r_unorm,
    bc5_rg_unorm,
    bc6h_rgb_float,
    bc7_rgba_unorm,
    bc7_rgba_srgb,
    astc_4x4_rgba_unorm,
    etc2_rgb8_unorm,
    etc2_rgba8_unorm,
    eac_r11_unorm,
    eac_rg11_unorm,
};

pub const TextureType = enum(u3) { @"2d", @"3d", @"1d", cube, @"2d_array", @"1d_array", cube_array };

pub const TextureUsage = packed struct {
    sampled: bool = true,
    storage: bool = false,
    transfer_src: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
};

pub const TextureDesc = struct {
    type: TextureType = .@"2d",
    dimensions: [3]u32 = .{ 1, 1, 1 },
    mip_count: u32 = 1,
    layer_count: u32 = 1,
    sample_count: u32 = 1,
    format: TextureFormat = .rgba8_unorm,
    usage: TextureUsage = .{},
};

pub const TextureViewDesc = struct {
    type: TextureType = .@"2d",
    format: TextureFormat = .default,
    base_mip: u32 = 0,
    mip_count: u8 = 0,
    base_layer: u16 = 0,
    layer_count: u16 = 0,
};

pub const SamplerDesc = struct {
    min_filter: Filter = .linear,
    mag_filter: Filter = .linear,
    mip_filter: Filter = .linear,
    address_mode_u: AddressMode = .repeat,
    address_mode_v: AddressMode = .repeat,
    address_mode_w: AddressMode = .repeat,
    mip_lod_bias: f32 = 0,
    min_lod: f32 = 0,
    max_lod: f32 = 32,
    max_anisotropy: f32 = 1,
};

pub const Filter = enum(u1) { linear, nearest };
pub const AddressMode = enum(u3) { repeat, mirrored_repeat, clamp_to_edge };

pub const TextureRegion = struct {
    rect: [3]i32 = .{ 0, 0, 0 },
    size: [3]u32 = .{ 0, 0, 0 },
    mip_level: u32 = 0,
    base_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const BlitRect = struct {
    offset_a: [3]i32 = .{ 0, 0, 0 },
    offset_b: [3]i32 = .{ 0, 0, 0 },
    mip_level: u32 = 0,
    base_layer: u32 = 0,
    layer_count: u32 = 1,
};

gpu: *Gpu,
handle: TextureHandle = .{},
type: TextureType = .@"2d",
dimensions: [3]u32 = .{ 0, 0, 0 },
format: TextureFormat = .rgba8_unorm,
mip_count: u32 = 1,
layer_count: u32 = 1,
sample_count: u32 = 1,

pub fn create(gpu: *Gpu, desc: TextureDesc) !Texture {
    const handle = try gpu.textureCreate(desc);
    return .{
        .gpu = gpu,
        .handle = handle,
        .type = desc.type,
        .dimensions = desc.dimensions,
        .format = desc.format,
        .mip_count = desc.mip_count,
        .layer_count = desc.layer_count,
        .sample_count = desc.sample_count,
    };
}

pub fn destroy(self: *Texture) void {
    self.gpu.textureDestroy(self.handle);
}

/// OwnedTexture pairs texture lifetime with memory management.
/// Backend self-allocates memory using the image's memory_type_bits
/// (avoids the buffer→image memory type mismatch from gpuMalloc).
pub const OwnedTexture = struct {
    texture: Texture,

    pub fn allocAndCreate(gpu: *Gpu, desc: TextureDesc) !OwnedTexture {
        const handle = try gpu.textureCreate(desc);
        return .{
            .texture = .{
                .gpu = gpu,
                .handle = handle,
                .type = desc.type,
                .dimensions = desc.dimensions,
                .format = desc.format,
                .mip_count = desc.mip_count,
                .layer_count = desc.layer_count,
                .sample_count = desc.sample_count,
            },
        };
    }

    pub fn deinit(self: *OwnedTexture) void {
        self.texture.destroy();
        self.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
