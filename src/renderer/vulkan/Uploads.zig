//! Bounded Vulkan upload staging on the renderer's graphics queue.
const Uploads = @This();
const std = @import("std");
const Device = @import("Device.zig");
const Texture = @import("Texture.zig");
const Mapped = @import("buffer.zig").Mapped;
const vk = Device.vk;
const Proc = Device.Proc;

const slot_count = 3;
const max_cached_bytes = 16 * 1024 * 1024;
const max_operations = 64;

device: *const Device,
fns: Dispatch,
copy_alignment: usize,
slots: [slot_count]Slot = @splat(.{}),
next_slot: usize = 0,

const Operation = struct {
    target: Texture,
    copy: ?vk.VkBufferImageCopy,
};

const Slot = struct {
    pool: vk.VkCommandPool = null,
    command: vk.VkCommandBuffer = null,
    fence: vk.VkFence = null,
    staging: ?Mapped = null,
    used: usize = 0,
    operations: [max_operations]Operation = undefined,
    count: usize = 0,
    submitted: bool = false,

    fn retire(self: *Slot) void {
        for (self.operations[0..self.count]) |operation| operation.target.release();
        self.count = 0;
        self.used = 0;
        self.submitted = false;
        if (self.staging) |staging| {
            if (staging.data.len > max_cached_bytes) {
                staging.deinit();
                self.staging = null;
            }
        }
    }
};

const Dispatch = struct {
    vkCreateCommandPool: Proc("vkCreateCommandPool"),
    vkDestroyCommandPool: Proc("vkDestroyCommandPool"),
    vkResetCommandPool: Proc("vkResetCommandPool"),
    vkAllocateCommandBuffers: Proc("vkAllocateCommandBuffers"),
    vkCreateFence: Proc("vkCreateFence"),
    vkDestroyFence: Proc("vkDestroyFence"),
    vkResetFences: Proc("vkResetFences"),
    vkGetFenceStatus: Proc("vkGetFenceStatus"),
    vkWaitForFences: Proc("vkWaitForFences"),
    vkDeviceWaitIdle: Proc("vkDeviceWaitIdle"),
    vkBeginCommandBuffer: Proc("vkBeginCommandBuffer"),
    vkEndCommandBuffer: Proc("vkEndCommandBuffer"),
    vkCmdPipelineBarrier2: Proc("vkCmdPipelineBarrier2"),
    vkCmdCopyBufferToImage: Proc("vkCmdCopyBufferToImage"),
    vkQueueSubmit2: Proc("vkQueueSubmit2"),

    fn load(device: *const Device) !Dispatch {
        var result: Dispatch = undefined;
        inline for (@typeInfo(Dispatch).@"struct".field_names) |name| {
            @field(result, name) = try device.deviceProc(name);
        }
        return result;
    }
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    data: []const u8,
};

/// Device must be at its final address and outlive this uploader.
pub fn init(device: *const Device) !*Uploads {
    const fns: Dispatch = try .load(device);
    const self = try device.alloc.create(Uploads);
    self.* = .{
        .device = device,
        .fns = fns,
        // All supported texture texels are at most eight bytes. Respect
        // the adapter's preferred transfer offset alignment as well.
        .copy_alignment = @max(8, @as(usize, @intCast(device.properties.limits.optimalBufferCopyOffsetAlignment))),
    };
    errdefer self.deinit();

    for (&self.slots) |*slot| {
        try Device.check("vkCreateCommandPool (upload)", fns.vkCreateCommandPool(device.native, &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
            .queueFamilyIndex = device.queue_family,
        }, null, &slot.pool));
        try Device.check("vkAllocateCommandBuffers (upload)", fns.vkAllocateCommandBuffers(device.native, &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = slot.pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        }, &slot.command));
        try Device.check("vkCreateFence (upload)", fns.vkCreateFence(device.native, &.{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        }, null, &slot.fence));
    }
    return self;
}

pub fn deinit(self: *Uploads) void {
    const native = self.device.native;
    for (&self.slots) |*slot| {
        self.wait(slot) catch {
            _ = self.fns.vkDeviceWaitIdle(native);
        };
        // An unsubmitted batch has no GPU work to wait for.
        slot.retire();
        if (slot.staging) |staging| staging.deinit();
        if (slot.fence != null) self.fns.vkDestroyFence(native, slot.fence, null);
        if (slot.pool != null) self.fns.vkDestroyCommandPool(native, slot.pool, null);
    }
    self.device.alloc.destroy(self);
}

/// Drain completed uploads without blocking a frame. The renderer may use
/// this while it retires the frame's own resources.
pub fn collect(self: *Uploads) !void {
    for (&self.slots) |*slot| {
        if (!slot.submitted) continue;
        switch (self.fns.vkGetFenceStatus(self.device.native, slot.fence)) {
            vk.VK_SUCCESS => slot.retire(),
            vk.VK_NOT_READY => {},
            else => |result| try Device.check("vkGetFenceStatus (upload)", result),
        }
    }
}

/// Stage a copy or initialize an empty image for shader reads. The uploader
/// takes ownership of staged bytes and an image reference now. Call flush
/// before recording commands that use the image.
pub fn upload(self: *Uploads, texture: Texture, region: ?Region) !void {
    const bytes = if (region) |copy| copy.data.len else 0;
    const oversized = bytes > max_cached_bytes;
    if (oversized) {
        try self.flush();
        // A previous exceptional wait can fail. Do not allocate another
        // oversized mapping until the old one can be retired.
        for (&self.slots) |*slot| {
            if (slot.staging) |staging| {
                if (staging.data.len > max_cached_bytes) try self.wait(slot);
            }
        }
    } else if (self.pending()) |slot| {
        const offset = if (bytes == 0) slot.used else std.mem.alignForward(usize, slot.used, self.copy_alignment);
        if (slot.count == max_operations or offset > max_cached_bytes - bytes) try self.flush();
    }

    const slot = &self.slots[self.next_slot];
    try self.wait(slot);
    const copy = if (region) |r| area: {
        const offset = std.mem.alignForward(usize, slot.used, self.copy_alignment);
        const end = offset + bytes;
        try self.reserve(slot, end);
        @memcpy(slot.staging.?.data[offset..end], r.data);
        slot.used = end;
        break :area vk.VkBufferImageCopy{
            .bufferOffset = offset,
            .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
            .imageOffset = .{ .x = @intCast(r.x), .y = @intCast(r.y), .z = 0 },
            .imageExtent = .{ .width = r.width, .height = r.height, .depth = 1 },
        };
    } else null;

    texture.retain();
    slot.operations[slot.count] = .{ .target = texture, .copy = copy };
    slot.count += 1;
    if (oversized) {
        self.flush() catch |err| {
            // The oversized operation has no predecessors in this batch.
            // Its caller sees the failure, so discard just this operation.
            slot.retire();
            return err;
        };
        // Retire the exceptional staging allocation promptly even if the
        // terminal becomes idle after this upload.
        try self.wait(slot);
    }
}

fn reserve(self: *Uploads, slot: *Slot, needed: usize) !void {
    if (slot.staging) |staging| {
        if (staging.data.len >= needed) return;
    }
    const capacity = if (needed > max_cached_bytes) needed else std.math.ceilPowerOfTwo(usize, @max(4096, needed)) catch unreachable;
    const staging: Mapped = try .init(self.device, capacity, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    if (slot.staging) |previous| {
        // Commands haven't been recorded yet, so changing the staging
        // buffer needs only a copy of the range already reserved.
        @memcpy(staging.data[0..slot.used], previous.data[0..slot.used]);
        previous.deinit();
    }
    slot.staging = staging;
}

fn pending(self: *Uploads) ?*Slot {
    const slot = &self.slots[self.next_slot];
    return if (!slot.submitted and slot.count != 0) slot else null;
}

/// Submit the staged batch without blocking on its completion. Failed
/// submissions leave the batch intact so its accepted uploads can be retried.
pub fn flush(self: *Uploads) !void {
    const slot = self.pending() orelse return;
    const f = &self.fns;
    const native = self.device.native;

    try Device.check("vkResetCommandPool (upload)", f.vkResetCommandPool(native, slot.pool, 0));
    const cmd = slot.command;
    try Device.check("vkBeginCommandBuffer (upload)", f.vkBeginCommandBuffer(cmd, &.{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    }));

    const operations = slot.operations[0..slot.count];
    for (operations, 0..) |operation, index| {
        var layout = operation.target.uploadLayout();
        // The committed state does not include earlier operations in this
        // batch yet. In particular, only the first may use UNDEFINED.
        if (layout == vk.VK_IMAGE_LAYOUT_UNDEFINED) {
            for (operations[0..index]) |previous| {
                if (previous.target.native != operation.target.native) continue;
                layout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                break;
            }
        }
        self.record(slot, operation, layout);
    }

    try Device.check("vkEndCommandBuffer (upload)", f.vkEndCommandBuffer(cmd));
    try Device.check("vkResetFences (upload)", f.vkResetFences(native, 1, &slot.fence));
    const command_info: vk.VkCommandBufferSubmitInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = cmd,
        .deviceMask = 1,
    };
    try Device.check("vkQueueSubmit2 (upload)", f.vkQueueSubmit2(self.device.queue, 1, &.{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &command_info,
    }, slot.fence));
    slot.submitted = true;
    for (operations) |operation| operation.target.markUploaded();
    self.next_slot = (self.next_slot + 1) % slot_count;
}

fn wait(self: *Uploads, slot: *Slot) !void {
    if (!slot.submitted) return;
    try Device.check("vkWaitForFences (upload)", self.fns.vkWaitForFences(
        self.device.native,
        1,
        &slot.fence,
        vk.VK_TRUE,
        std.math.maxInt(u64),
    ));
    slot.retire();
}

fn record(self: *Uploads, slot: *const Slot, operation: Operation, layout: vk.VkImageLayout) void {
    const command = slot.command;
    const image = operation.target.native;
    const source: Scope = if (layout == vk.VK_IMAGE_LAYOUT_UNDEFINED) .{} else .{
        .stage = vk.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT | vk.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        .access = vk.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT | vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | vk.VK_ACCESS_2_TRANSFER_WRITE_BIT,
    };
    if (operation.copy) |copy| {
        const transfer: Scope = .{
            .stage = vk.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            .access = vk.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        };
        self.transition(command, image, layout, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, source, transfer);
        self.fns.vkCmdCopyBufferToImage(command, slot.staging.?.native, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        self.transition(command, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, transfer, sampling);
    } else if (layout == vk.VK_IMAGE_LAYOUT_UNDEFINED) {
        self.transition(command, image, layout, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, source, sampling);
    }
}

const Scope = struct {
    stage: vk.VkPipelineStageFlags2 = 0,
    access: vk.VkAccessFlags2 = 0,
};

const sampling: Scope = .{
    .stage = vk.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
    .access = vk.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
};

fn transition(
    self: *Uploads,
    command: vk.VkCommandBuffer,
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    source: Scope,
    destination: Scope,
) void {
    const barrier: vk.VkImageMemoryBarrier2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = source.stage,
        .srcAccessMask = source.access,
        .dstStageMask = destination.stage,
        .dstAccessMask = destination.access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = Texture.color_range,
    };
    self.fns.vkCmdPipelineBarrier2(command, &.{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    });
}
