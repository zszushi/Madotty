//! Translate the shared renderer's passes to Vulkan dynamic rendering.
const RenderPass = @This();
const std = @import("std");
const Device = @import("Device.zig");
const vk = Device.vk;
const Proc = Device.Proc;
const Pipeline = @import("Pipeline.zig");
const Texture = @import("Texture.zig");
const Buffer = @import("buffer.zig").RawBuffer;
const Target = @import("../Vulkan.zig").Target;
const shaders = @import("shaders.zig");

pub const Backbuffer = struct {
    native: vk.VkImage,
    view: vk.VkImageView,
    width: usize,
    height: usize,
    format: vk.VkFormat,
};

/// Built-in image passes share a linear clamp sampler owned by the slot.
pub const Sampler = struct {
    pub const Options = struct {};
    pub fn init(_: @This().Options) !Sampler {
        return .{};
    }
    pub fn deinit(_: Sampler) void {}
};

pub const Options = struct {
    pub const Attachment = struct {
        target: union(enum) { texture: Texture, target: Target },
        clear_color: ?[4]f32 = null,
    };
};

pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?Buffer = null,
    buffers: []const ?Buffer = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: struct {
        type: enum { triangle, triangle_strip },
        vertex_count: usize,
        instance_count: usize = 1,
    },
};

pub const FrameContext = struct {
    alloc: std.mem.Allocator,
    device: *const Device,
    dispatch: Dispatch,
    command: vk.VkCommandBuffer = null,
    failure: ?anyerror = null,
    sampler: vk.VkSampler = null,
    retained: std.ArrayList(Resource) = .empty,
    pools: std.ArrayList(DescriptorPool) = .empty,
    pool_index: usize = 0,

    const pool_capacity = 128;

    const Resource = union(enum) {
        buffer: Buffer,
        texture: Texture,

        fn retain(self: Resource) void {
            switch (self) {
                inline else => |resource| resource.retain(),
            }
        }

        fn release(self: Resource) void {
            switch (self) {
                inline else => |resource| resource.release(),
            }
        }
    };

    const DescriptorPool = struct {
        native: vk.VkDescriptorPool,
        used: u32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator, device: *const Device) !FrameContext {
        var self: FrameContext = .{ .alloc = alloc, .device = device, .dispatch = try .load(device) };
        errdefer self.deinit();
        try Device.check("vkCreateSampler", self.dispatch.vkCreateSampler(device.native, &.{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = vk.VK_FILTER_LINEAR,
            .minFilter = vk.VK_FILTER_LINEAR,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .maxLod = 0,
        }, null, &self.sampler));
        return self;
    }

    /// Call when the slot's submission has completed, before its next use.
    pub fn reset(self: *FrameContext) !void {
        self.command = null;
        self.failure = null;
        self.releaseResources();
        for (self.pools.items) |*pool| {
            if (pool.used == 0) continue;
            try Device.check("vkResetDescriptorPool", self.dispatch.vkResetDescriptorPool(self.device.native, pool.native, 0));
            pool.used = 0;
        }
        self.pool_index = 0;
    }

    /// Call after any pending GPU work referencing the slot has finished.
    pub fn deinit(self: *FrameContext) void {
        const native = self.device.native;
        for (self.pools.items) |pool| self.dispatch.vkDestroyDescriptorPool(native, pool.native, null);
        self.pools.deinit(self.alloc);
        if (self.sampler != null) self.dispatch.vkDestroySampler(native, self.sampler, null);
        self.releaseResources();
        self.retained.deinit(self.alloc);
        self.* = undefined;
    }

    fn releaseResources(self: *FrameContext) void {
        for (self.retained.items) |resource| resource.release();
        self.retained.clearRetainingCapacity();
    }

    fn keep(self: *FrameContext, resource: Resource) !void {
        try self.retained.append(self.alloc, resource);
        resource.retain();
    }

    fn allocateSet(self: *FrameContext, layout: vk.VkDescriptorSetLayout) !vk.VkDescriptorSet {
        const native = self.device.native;
        if (self.pool_index == self.pools.items.len) {
            try self.pools.ensureUnusedCapacity(self.alloc, 1);
            const sizes = [_]vk.VkDescriptorPoolSize{
                .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = pool_capacity },
                .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = pool_capacity },
                .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 2 * pool_capacity },
                .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = pool_capacity },
                .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = pool_capacity },
            };
            var pool: vk.VkDescriptorPool = null;
            try Device.check("vkCreateDescriptorPool", self.dispatch.vkCreateDescriptorPool(native, &.{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                .maxSets = pool_capacity,
                .poolSizeCount = sizes.len,
                .pPoolSizes = &sizes,
            }, null, &pool));
            self.pools.appendAssumeCapacity(.{ .native = pool });
        }

        const pool = &self.pools.items[self.pool_index];
        var set: vk.VkDescriptorSet = null;
        try Device.check("vkAllocateDescriptorSets", self.dispatch.vkAllocateDescriptorSets(native, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool.native,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        }, &set));
        pool.used += 1;
        if (pool.used == pool_capacity) self.pool_index += 1;
        return set;
    }
};

context: *FrameContext,
format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,
texture: ?Texture = null,
active: bool = false,

/// The acquired backbuffer is already in COLOR_ATTACHMENT_OPTIMAL; its
/// transition to PRESENT_SRC_KHR belongs to the swapchain.
pub fn begin(context: *FrameContext, attachments: []const Options.Attachment, backbuffer: Backbuffer) RenderPass {
    var self: RenderPass = .{ .context = context };
    if (context.failure != null) return self;
    self.beginRendering(attachments, backbuffer) catch |err| {
        context.failure = err;
    };
    return self;
}

fn beginRendering(self: *RenderPass, attachments: []const Options.Attachment, backbuffer: Backbuffer) !void {
    if (attachments.len != 1) return error.VulkanOneColorAttachmentRequired;
    const context = self.context;
    const attachment = attachments[0];
    const target: Backbuffer = switch (attachment.target) {
        .target => backbuffer,
        .texture => |texture| target: {
            if (!texture.render_target) return error.VulkanTextureIsNotRenderTarget;
            break :target .{
                .native = texture.native,
                .view = texture.view,
                .width = texture.width,
                .height = texture.height,
                .format = texture.format,
            };
        },
    };
    if (target.native == null or target.view == null or target.width == 0 or target.height == 0)
        return error.VulkanRenderTargetMissing;
    const extent: vk.VkExtent2D = .{
        .width = std.math.cast(u32, target.width) orelse return error.VulkanRenderTargetTooLarge,
        .height = std.math.cast(u32, target.height) orelse return error.VulkanRenderTargetTooLarge,
    };
    if (attachment.target == .texture) {
        const texture = attachment.target.texture;
        try context.keep(.{ .texture = texture });
        self.transition(texture.native, true);
        self.texture = texture;
    }

    const d = &context.dispatch;
    const command = context.command;
    const scissor: vk.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    d.vkCmdBeginRendering(command, &.{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = scissor,
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &.{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = target.view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = if (attachment.clear_color != null)
                vk.VK_ATTACHMENT_LOAD_OP_CLEAR
            else if (attachment.target == .texture)
                vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE
            else
                vk.VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = .{ .color = .{ .float32 = attachment.clear_color orelse @splat(0) } },
        },
    });
    d.vkCmdSetViewport(command, 0, 1, &.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    });
    d.vkCmdSetScissor(command, 0, 1, &scissor);
    self.active = true;
    self.format = target.format;
}

pub fn step(self: *RenderPass, draw: Step) void {
    if (!self.active or self.context.failure != null or draw.draw.instance_count == 0 or draw.draw.vertex_count == 0) return;
    self.drawStep(draw) catch |err| {
        self.context.failure = err;
    };
}

fn drawStep(self: *RenderPass, draw: Step) !void {
    const context = self.context;
    const pipeline = draw.pipeline;
    if (pipeline.native == null or pipeline.format != self.format) return error.VulkanIncompatiblePipeline;
    const count = std.math.cast(u32, draw.draw.vertex_count) orelse return error.VulkanDrawTooLarge;
    const instances = std.math.cast(u32, draw.draw.instance_count) orelse return error.VulkanDrawTooLarge;

    const d = &context.dispatch;
    const command = context.command;
    if (pipeline.vertex_stride != 0) {
        const buffer = element(Buffer, draw.buffers, 0) orelse return error.VulkanVertexBufferMissing;
        if (buffer.native == null or buffer.stride != pipeline.vertex_stride) return error.VulkanVertexBufferMismatch;
        try context.keep(.{ .buffer = buffer });
        d.vkCmdBindVertexBuffers(command, 0, 1, &buffer.native, &@as(vk.VkDeviceSize, 0));
    }

    const set = try self.writeDescriptors(draw);
    d.vkCmdBindPipeline(command, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.native);
    d.vkCmdBindDescriptorSets(command, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.layout, shaders.Binding.set, 1, &set, 0, null);
    d.vkCmdDraw(command, count, instances, 0, 0);
}

fn element(comptime T: type, values: []const ?T, i: usize) ?T {
    return if (i < values.len) values[i] else null;
}

fn writeDescriptors(self: *RenderPass, draw: Step) !vk.VkDescriptorSet {
    const context = self.context;
    const bindings = draw.pipeline.bindings;
    const max_bindings = @typeInfo(shaders.Binding).@"enum".field_names.len;
    var writes: [max_bindings]vk.VkWriteDescriptorSet = undefined;
    var buffers: [max_bindings]vk.VkDescriptorBufferInfo = undefined;
    var images: [max_bindings]vk.VkDescriptorImageInfo = undefined;
    const set = try context.allocateSet(draw.pipeline.descriptor_layout);
    for (bindings, 0..) |binding, i| {
        const write = &writes[i];
        write.* = .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = binding.index(),
            .descriptorCount = 1,
            .descriptorType = @backingInt(binding.descriptorType()),
        };
        switch (binding) {
            .uniforms, .cell_backgrounds => {
                const buffer = (if (binding == .uniforms) draw.uniforms else element(Buffer, draw.buffers, 1)) orelse
                    return error.VulkanDescriptorBufferMissing;
                if (buffer.native == null or buffer.size == 0) return error.VulkanDescriptorBufferMissing;
                try context.keep(.{ .buffer = buffer });
                buffers[i] = .{ .buffer = buffer.native, .offset = 0, .range = buffer.size };
                write.pBufferInfo = &buffers[i];
            },
            .texture_0, .texture_1, .channel_0 => {
                const texture = element(Texture, draw.textures, @intFromBool(binding == .texture_1)) orelse
                    return error.VulkanDescriptorTextureMissing;
                if (texture.view == null) return error.VulkanDescriptorTextureMissing;
                // Sampling the active render attachment is not a supported pass.
                if (self.texture) |target| {
                    if (target.native == texture.native) return error.VulkanTextureFeedback;
                }
                try context.keep(.{ .texture = texture });
                images[i] = .{
                    .sampler = if (binding == .channel_0) context.sampler else null,
                    .imageView = texture.view,
                    .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                };
                write.pImageInfo = &images[i];
            },
            .image_sampler => {
                images[i] = .{ .sampler = context.sampler };
                write.pImageInfo = &images[i];
            },
        }
    }
    context.dispatch.vkUpdateDescriptorSets(context.device.native, @intCast(bindings.len), &writes, 0, null);
    return set;
}

pub fn complete(self: *const RenderPass) void {
    if (!self.active) return;
    const context = self.context;
    context.dispatch.vkCmdEndRendering(context.command);
    if (self.texture) |texture| self.transition(texture.native, false);
}

fn transition(self: *const RenderPass, image: vk.VkImage, begin_pass: bool) void {
    const context = self.context;
    const sampled = vk.VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT | vk.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    const attachment = vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    const read_sample = vk.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT;
    const write_attachment = vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | vk.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT;
    context.dispatch.vkCmdPipelineBarrier2(context.command, &.{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = if (begin_pass) sampled else attachment,
            .srcAccessMask = if (begin_pass) read_sample else write_attachment,
            .dstStageMask = if (begin_pass) attachment else sampled,
            .dstAccessMask = if (begin_pass) write_attachment else read_sample,
            .oldLayout = if (begin_pass) vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .newLayout = if (begin_pass) vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL else vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = Texture.color_range,
        },
    });
}

const Dispatch = struct {
    vkCreateSampler: Proc("vkCreateSampler"),
    vkDestroySampler: Proc("vkDestroySampler"),
    vkCreateDescriptorPool: Proc("vkCreateDescriptorPool"),
    vkDestroyDescriptorPool: Proc("vkDestroyDescriptorPool"),
    vkResetDescriptorPool: Proc("vkResetDescriptorPool"),
    vkAllocateDescriptorSets: Proc("vkAllocateDescriptorSets"),
    vkUpdateDescriptorSets: Proc("vkUpdateDescriptorSets"),
    vkCmdPipelineBarrier2: Proc("vkCmdPipelineBarrier2"),
    vkCmdBeginRendering: Proc("vkCmdBeginRendering"),
    vkCmdEndRendering: Proc("vkCmdEndRendering"),
    vkCmdSetViewport: Proc("vkCmdSetViewport"),
    vkCmdSetScissor: Proc("vkCmdSetScissor"),
    vkCmdBindPipeline: Proc("vkCmdBindPipeline"),
    vkCmdBindVertexBuffers: Proc("vkCmdBindVertexBuffers"),
    vkCmdBindDescriptorSets: Proc("vkCmdBindDescriptorSets"),
    vkCmdDraw: Proc("vkCmdDraw"),

    fn load(device: *const Device) !Dispatch {
        var result: Dispatch = undefined;
        inline for (@typeInfo(Dispatch).@"struct".field_names) |name| {
            @field(result, name) = try device.deviceProc(name);
        }
        return result;
    }
};
