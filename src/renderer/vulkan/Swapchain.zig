//! Win32 Vulkan presentation on a single graphics/present queue.
const Swapchain = @This();
const std = @import("std");
const Device = @import("Device.zig");
const vk = Device.vk;

pub const frame_count = 2;
pub const Status = enum { presented, retry, resize };
pub const Acquired = struct {
    slot: usize,
    index: u32,
    command: vk.VkCommandBuffer,
    native: vk.VkImage,
    view: vk.VkImageView,
    suboptimal: bool,
};
pub const Acquire = union(enum) { frame: Acquired, retry, resize };

alloc: std.mem.Allocator,
device: *const Device,
fns: Dispatch,
native: vk.VkSwapchainKHR = null,
extent: vk.VkExtent2D,
format: vk.VkFormat,
images: []Image = &.{},
slots: [frame_count]Slot = @splat(.{}),

const Image = struct {
    native: vk.VkImage = null,
    view: vk.VkImageView = null,
    // After reacquiring this image, presentation has finished consuming its
    // previous wait semaphore. A frame fence alone cannot guarantee that.
    ready: vk.VkSemaphore = null,
};

const Slot = struct {
    pool: vk.VkCommandPool = null,
    command: vk.VkCommandBuffer = null,
    acquired: vk.VkSemaphore = null,
    done: vk.VkFence = null,
};

const Proc = Device.Proc;

const Dispatch = struct {
    vkCreateSwapchainKHR: Proc("vkCreateSwapchainKHR"),
    vkDestroySwapchainKHR: Proc("vkDestroySwapchainKHR"),
    vkGetSwapchainImagesKHR: Proc("vkGetSwapchainImagesKHR"),
    vkCreateImageView: Proc("vkCreateImageView"),
    vkDestroyImageView: Proc("vkDestroyImageView"),
    vkCreateSemaphore: Proc("vkCreateSemaphore"),
    vkDestroySemaphore: Proc("vkDestroySemaphore"),
    vkCreateFence: Proc("vkCreateFence"),
    vkDestroyFence: Proc("vkDestroyFence"),
    vkWaitForFences: Proc("vkWaitForFences"),
    vkGetFenceStatus: Proc("vkGetFenceStatus"),
    vkResetFences: Proc("vkResetFences"),
    vkCreateCommandPool: Proc("vkCreateCommandPool"),
    vkDestroyCommandPool: Proc("vkDestroyCommandPool"),
    vkResetCommandPool: Proc("vkResetCommandPool"),
    vkAllocateCommandBuffers: Proc("vkAllocateCommandBuffers"),
    vkAcquireNextImageKHR: Proc("vkAcquireNextImageKHR"),
    vkBeginCommandBuffer: Proc("vkBeginCommandBuffer"),
    vkEndCommandBuffer: Proc("vkEndCommandBuffer"),
    vkCmdPipelineBarrier2: Proc("vkCmdPipelineBarrier2"),
    vkQueueSubmit2: Proc("vkQueueSubmit2"),
    vkQueuePresentKHR: Proc("vkQueuePresentKHR"),
    vkDeviceWaitIdle: Proc("vkDeviceWaitIdle"),

    fn load(device: *const Device) !Dispatch {
        var result: Dispatch = undefined;
        inline for (@typeInfo(Dispatch).@"struct".field_names) |name| {
            @field(result, name) = try device.deviceProc(name);
        }
        return result;
    }
};

pub fn init(alloc: std.mem.Allocator, device: *const Device, width: u32, height: u32) !Swapchain {
    const format = try chooseFormat(alloc, device, null);
    return initWithFormat(alloc, device, width, height, format);
}

pub fn initWithFormat(
    alloc: std.mem.Allocator,
    device: *const Device,
    width: u32,
    height: u32,
    format: vk.VkSurfaceFormatKHR,
) !Swapchain {
    if (width == 0 or height == 0) return error.SurfaceNotDrawable;

    const capabilities_fn = try device.instanceProc("vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    var caps: vk.VkSurfaceCapabilitiesKHR = undefined;
    try Device.check("vkGetPhysicalDeviceSurfaceCapabilitiesKHR", capabilities_fn(device.physical, device.surface, &caps));
    if (caps.supportedUsageFlags & vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT == 0) return error.SurfaceNotDrawable;
    const extent: vk.VkExtent2D = if (caps.currentExtent.width != std.math.maxInt(u32))
        caps.currentExtent
    else
        .{
            .width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
            .height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
        };
    if (extent.width == 0 or extent.height == 0) return error.SurfaceNotDrawable;

    var self: Swapchain = .{
        .alloc = alloc,
        .device = device,
        .fns = try .load(device),
        .extent = extent,
        .format = format.format,
    };
    errdefer self.release();
    const alpha: vk.VkCompositeAlphaFlagBitsKHR = alpha: {
        for ([_]vk.VkCompositeAlphaFlagBitsKHR{
            vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
            vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
            vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
        }) |mode| {
            if (caps.supportedCompositeAlpha & @as(vk.VkCompositeAlphaFlagsKHR, @intCast(mode)) != 0) break :alpha mode;
        }
        return error.SurfaceNotDrawable;
    };
    var image_count = caps.minImageCount +| 1;
    if (caps.maxImageCount != 0) image_count = @min(image_count, caps.maxImageCount);
    try Device.check("vkCreateSwapchainKHR", self.fns.vkCreateSwapchainKHR(device.native, &.{
        .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = device.surface,
        .minImageCount = image_count,
        .imageFormat = format.format,
        .imageColorSpace = format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = alpha,
        .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
        .clipped = vk.VK_TRUE,
    }, null, &self.native));

    try self.initImages();
    for (&self.slots) |*slot| try self.initSlot(slot);
    return self;
}

pub fn chooseFormat(alloc: std.mem.Allocator, device: *const Device, linear: ?bool) !vk.VkSurfaceFormatKHR {
    const formats_fn = try device.instanceProc("vkGetPhysicalDeviceSurfaceFormatsKHR");
    var count: u32 = 0;
    try Device.check("vkGetPhysicalDeviceSurfaceFormatsKHR", formats_fn(device.physical, device.surface, &count, null));
    const formats = try alloc.alloc(vk.VkSurfaceFormatKHR, count);
    defer alloc.free(formats);
    try Device.check("vkGetPhysicalDeviceSurfaceFormatsKHR", formats_fn(device.physical, device.surface, &count, formats.ptr));
    for ([_]vk.VkFormat{
        vk.VK_FORMAT_B8G8R8A8_UNORM,
        vk.VK_FORMAT_R8G8B8A8_UNORM,
        vk.VK_FORMAT_B8G8R8A8_SRGB,
        vk.VK_FORMAT_R8G8B8A8_SRGB,
    }) |desired| {
        const is_srgb = desired == vk.VK_FORMAT_B8G8R8A8_SRGB or desired == vk.VK_FORMAT_R8G8B8A8_SRGB;
        if (linear) |required| {
            if (required != is_srgb) continue;
        }
        for (formats[0..count]) |format| {
            if (format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR and
                (format.format == desired or format.format == vk.VK_FORMAT_UNDEFINED))
            {
                return .{ .format = desired, .colorSpace = format.colorSpace };
            }
        }
    }
    return error.UnsupportedSurfaceFormat;
}

fn initImages(self: *Swapchain) !void {
    const device = self.device.native;
    var count: u32 = 0;
    try Device.check("vkGetSwapchainImagesKHR", self.fns.vkGetSwapchainImagesKHR(device, self.native, &count, null));
    if (count == 0) return error.SurfaceNotDrawable;
    const native_images = try self.alloc.alloc(vk.VkImage, count);
    defer self.alloc.free(native_images);
    try Device.check("vkGetSwapchainImagesKHR", self.fns.vkGetSwapchainImagesKHR(device, self.native, &count, native_images.ptr));
    self.images = try self.alloc.alloc(Image, count);
    @memset(self.images, .{});
    for (self.images, native_images[0..count]) |*image, native| {
        image.native = native;
        try Device.check("vkCreateImageView", self.fns.vkCreateImageView(device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = native,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.format,
            .subresourceRange = range,
        }, null, &image.view));
        try self.initSemaphore(&image.ready);
    }
}

fn initSemaphore(self: *Swapchain, out: *vk.VkSemaphore) !void {
    try Device.check("vkCreateSemaphore", self.fns.vkCreateSemaphore(self.device.native, &.{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    }, null, out));
}

fn initSlot(self: *Swapchain, slot: *Slot) !void {
    const device = self.device.native;
    try self.initSemaphore(&slot.acquired);
    try Device.check("vkCreateFence", self.fns.vkCreateFence(device, &.{
        .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
    }, null, &slot.done));
    try Device.check("vkCreateCommandPool", self.fns.vkCreateCommandPool(device, &.{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = vk.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = self.device.queue_family,
    }, null, &slot.pool));
    try Device.check("vkAllocateCommandBuffers", self.fns.vkAllocateCommandBuffers(device, &.{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = slot.pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    }, &slot.command));
}

pub fn waitIdle(self: *const Swapchain) !void {
    try Device.check("vkDeviceWaitIdle", self.fns.vkDeviceWaitIdle(self.device.native));
}

pub fn deinit(self: *Swapchain) void {
    self.waitIdle() catch {};
    self.release();
    self.* = undefined;
}

fn release(self: *Swapchain) void {
    const device = self.device.native;
    for (self.slots) |slot| {
        if (slot.pool != null) self.fns.vkDestroyCommandPool(device, slot.pool, null);
        if (slot.done != null) self.fns.vkDestroyFence(device, slot.done, null);
        if (slot.acquired != null) self.fns.vkDestroySemaphore(device, slot.acquired, null);
    }
    for (self.images) |image| {
        if (image.ready != null) self.fns.vkDestroySemaphore(device, image.ready, null);
        if (image.view != null) self.fns.vkDestroyImageView(device, image.view, null);
    }
    self.alloc.free(self.images);
    if (self.native != null) self.fns.vkDestroySwapchainKHR(device, self.native, null);
}

const range: vk.VkImageSubresourceRange = .{
    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
    .levelCount = 1,
    .layerCount = 1,
};

/// Wait before updating any CPU-written data owned by this frame slot.
pub fn waitSlot(self: *const Swapchain, index: usize) !void {
    try Device.check("vkWaitForFences", self.fns.vkWaitForFences(
        self.device.native,
        1,
        &self.slots[index].done,
        vk.VK_TRUE,
        std.math.maxInt(u64),
    ));
}

/// Check prior GPU reads without waiting or changing the slot.
pub fn slotReady(self: *const Swapchain, index: usize) !bool {
    const result = self.fns.vkGetFenceStatus(self.device.native, self.slots[index].done);
    if (result == vk.VK_NOT_READY) return false;
    try Device.check("vkGetFenceStatus", result);
    return true;
}

/// Acquire an image and open its command buffer. The slot must be idle.
pub fn acquire(self: *Swapchain, slot_index: usize) !Acquire {
    const slot = &self.slots[slot_index];
    const device = self.device.native;
    const f = &self.fns;
    var index: u32 = 0;
    const status = f.vkAcquireNextImageKHR(device, self.native, 50 * std.time.ns_per_ms, slot.acquired, null, &index);
    switch (status) {
        vk.VK_ERROR_OUT_OF_DATE_KHR => return .resize,
        vk.VK_NOT_READY, vk.VK_TIMEOUT => return .retry,
        vk.VK_SUCCESS, vk.VK_SUBOPTIMAL_KHR => {},
        else => try Device.check("vkAcquireNextImageKHR", status),
    }
    const image = self.images[index];
    try Device.check("vkResetCommandPool", f.vkResetCommandPool(device, slot.pool, 0));
    try Device.check("vkBeginCommandBuffer", f.vkBeginCommandBuffer(slot.command, &.{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    }));
    self.transition(slot.command, image.native, true);
    return .{ .frame = .{
        .slot = slot_index,
        .index = index,
        .command = slot.command,
        .native = image.native,
        .view = image.view,
        .suboptimal = status == vk.VK_SUBOPTIMAL_KHR,
    } };
}

/// Close a recorded frame and present its image.
pub fn submit(self: *Swapchain, frame: Acquired) !Status {
    const slot = &self.slots[frame.slot];
    const image = self.images[frame.index];
    const device = self.device.native;
    const f = &self.fns;
    self.transition(slot.command, image.native, false);
    try Device.check("vkEndCommandBuffer", f.vkEndCommandBuffer(slot.command));

    try Device.check("vkResetFences", f.vkResetFences(device, 1, &slot.done));
    try Device.check("vkQueueSubmit2", f.vkQueueSubmit2(self.device.queue, 1, &.{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = &.{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = slot.acquired,
            .stageMask = vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        },
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = slot.command,
        },
        .signalSemaphoreInfoCount = 1,
        .pSignalSemaphoreInfos = &.{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = image.ready,
            .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        },
    }, slot.done));
    const present = f.vkQueuePresentKHR(self.device.queue, &.{
        .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &image.ready,
        .swapchainCount = 1,
        .pSwapchains = &self.native,
        .pImageIndices = &frame.index,
    });
    switch (present) {
        vk.VK_ERROR_OUT_OF_DATE_KHR, vk.VK_SUBOPTIMAL_KHR => return .resize,
        vk.VK_SUCCESS => return if (frame.suboptimal) .resize else .presented,
        else => {
            try Device.check("vkQueuePresentKHR", present);
            unreachable;
        },
    }
}

fn transition(self: *const Swapchain, cmd: vk.VkCommandBuffer, image: vk.VkImage, begin: bool) void {
    const color_stage = vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    const color_write = vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
    self.fns.vkCmdPipelineBarrier2(cmd, &.{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = color_stage,
            .srcAccessMask = if (begin) 0 else color_write,
            .dstStageMask = if (begin) color_stage else vk.VK_PIPELINE_STAGE_2_NONE,
            .dstAccessMask = if (begin) color_write else 0,
            .oldLayout = if (begin) vk.VK_IMAGE_LAYOUT_UNDEFINED else vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .newLayout = if (begin) vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL else vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = range,
        },
    });
}
