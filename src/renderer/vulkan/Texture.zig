//! Sampled Vulkan images for font atlases, inline images and render targets.
const Texture = @This();
const std = @import("std");
const Device = @import("Device.zig");
const vk = Device.vk;
const Proc = Device.Proc;

pub const Error = anyerror;
pub const Options = struct {
    device: *const Device,
    format: vk.VkFormat,
    render_target: bool = false,
};

pub const color_range: vk.VkImageSubresourceRange = .{
    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
    .levelCount = 1,
    .layerCount = 1,
};

native: vk.VkImage,
view: vk.VkImageView,
format: vk.VkFormat,
width: usize,
height: usize,
render_target: bool,
allocation: *Allocation,

const Allocation = struct {
    refs: std.atomic.Value(u32) = .init(1),
    device: *const Device,
    destroy_image: Proc("vkDestroyImage"),
    destroy_view: Proc("vkDestroyImageView"),
    free_memory: Proc("vkFreeMemory"),
    image: vk.VkImage = null,
    view: vk.VkImageView = null,
    memory: vk.VkDeviceMemory = null,
    initialized: bool = false,

    fn release(self: *Allocation) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.deinit();
    }

    fn deinit(self: *Allocation) void {
        const native_device = self.device.native;
        if (self.view != null) self.destroy_view(native_device, self.view, null);
        if (self.image != null) self.destroy_image(native_device, self.image, null);
        if (self.memory != null) self.free_memory(native_device, self.memory, null);
        self.device.alloc.destroy(self);
    }
};

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Texture {
    const device = opts.device;
    const uploads = device.uploads orelse return error.VulkanUploadsUnavailable;
    const limit = device.properties.limits.maxImageDimension2D;
    if (width == 0 or height == 0 or width > limit or height > limit) return error.InvalidTextureExtent;
    _ = try pixelStride(opts.format);

    const create_image = try device.deviceProc("vkCreateImage");
    const blank: Allocation = .{
        .device = device,
        .destroy_image = try device.deviceProc("vkDestroyImage"),
        .destroy_view = try device.deviceProc("vkDestroyImageView"),
        .free_memory = try device.deviceProc("vkFreeMemory"),
    };
    const allocation = try device.alloc.create(Allocation);
    allocation.* = blank;
    // The initialization owner is released on error, but a submitted upload
    // keeps its own reference until its fence can retire.
    errdefer allocation.release();

    const usage: vk.VkImageUsageFlags = vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    const attachment_usage: vk.VkImageUsageFlags = if (opts.render_target)
        vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT
    else
        0;
    try Device.check("vkCreateImage", create_image(device.native, &.{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = opts.format,
        .extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = usage | attachment_usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    }, null, &allocation.image));

    const get_requirements = try device.deviceProc("vkGetImageMemoryRequirements");
    var requirements: vk.VkMemoryRequirements = undefined;
    get_requirements(device.native, allocation.image, &requirements);
    const memory_type = try device.memoryType(requirements.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    const allocate_memory = try device.deviceProc("vkAllocateMemory");
    try Device.check("vkAllocateMemory (image)", allocate_memory(device.native, &.{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_type,
    }, null, &allocation.memory));
    const bind_image = try device.deviceProc("vkBindImageMemory");
    try Device.check("vkBindImageMemory", bind_image(device.native, allocation.image, allocation.memory, 0));

    const create_view = try device.deviceProc("vkCreateImageView");
    try Device.check("vkCreateImageView", create_view(device.native, &.{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = allocation.image,
        .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
        .format = opts.format,
        .subresourceRange = color_range,
    }, null, &allocation.view));

    const self: Texture = .{
        .native = allocation.image,
        .view = allocation.view,
        .format = opts.format,
        .width = width,
        .height = height,
        .render_target = opts.render_target,
        .allocation = allocation,
    };
    if (data) |bytes| {
        try self.replaceRegion(0, 0, width, height, bytes);
    } else {
        try uploads.upload(self, null);
    }
    return self;
}

pub fn deinit(self: Texture) void {
    self.release();
}

pub fn retain(self: Texture) void {
    _ = self.allocation.refs.fetchAdd(1, .monotonic);
}

pub fn release(self: Texture) void {
    self.allocation.release();
}

pub fn replaceRegion(self: Texture, x: usize, y: usize, width: usize, height: usize, data: []const u8) Error!void {
    if (x > self.width or y > self.height or width > self.width - x or height > self.height - y) return error.InvalidTextureExtent;
    if (width == 0 or height == 0) return;
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidTextureExtent;
    const bytes = std.math.mul(usize, pixels, try pixelStride(self.format)) catch return error.InvalidTextureData;
    if (data.len < bytes) return error.InvalidTextureData;
    const uploads = self.allocation.device.uploads orelse return error.VulkanUploadsUnavailable;
    try uploads.upload(self, .{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(width),
        .height = @intCast(height),
        .data = data[0..bytes],
    });
}

/// Queued uploads and rendering use one externally synchronized queue.
/// Render passes must return sampled textures to this stable layout.
pub fn uploadLayout(self: Texture) vk.VkImageLayout {
    return if (self.allocation.initialized) vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else vk.VK_IMAGE_LAYOUT_UNDEFINED;
}

pub fn markUploaded(self: Texture) void {
    self.allocation.initialized = true;
}

fn pixelStride(format: vk.VkFormat) error{UnsupportedTextureFormat}!usize {
    return switch (format) {
        vk.VK_FORMAT_R8_UNORM => 1,
        vk.VK_FORMAT_R8G8B8A8_UNORM,
        vk.VK_FORMAT_R8G8B8A8_SRGB,
        vk.VK_FORMAT_B8G8R8A8_UNORM,
        vk.VK_FORMAT_B8G8R8A8_SRGB,
        vk.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
        vk.VK_FORMAT_A2R10G10B10_UNORM_PACK32,
        => 4,
        vk.VK_FORMAT_R16G16B16A16_SFLOAT => 8,
        else => error.UnsupportedTextureFormat,
    };
}
