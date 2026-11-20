//! Graphics pipelines for built-in terminal and custom shader passes.
const Pipeline = @This();
const std = @import("std");
const Device = @import("Device.zig");
const vk = Device.vk;
const Proc = Device.Proc;
const shaders = @import("shaders.zig");

device: vk.VkDevice,
native: vk.VkPipeline = null,
layout: vk.VkPipelineLayout = null,
descriptor_layout: vk.VkDescriptorSetLayout = null,
bindings: []const shaders.Binding,
format: vk.VkFormat,
vertex_stride: u32,
destroy_pipeline: Proc("vkDestroyPipeline"),
destroy_layout: Proc("vkDestroyPipelineLayout"),
destroy_descriptors: Proc("vkDestroyDescriptorSetLayout"),

pub fn init(device: *const Device, format: vk.VkFormat, program: shaders.Program) !Pipeline {
    var self: Pipeline = .{
        .device = device.native,
        .bindings = program.bindings,
        .format = format,
        .vertex_stride = program.input.stride,
        .destroy_pipeline = try device.deviceProc("vkDestroyPipeline"),
        .destroy_layout = try device.deviceProc("vkDestroyPipelineLayout"),
        .destroy_descriptors = try device.deviceProc("vkDestroyDescriptorSetLayout"),
    };
    errdefer self.deinit();

    var binding_storage: [@typeInfo(shaders.Binding).@"enum".field_names.len]vk.VkDescriptorSetLayoutBinding = undefined;
    const bindings = binding_storage[0..program.bindings.len];
    for (bindings, program.bindings) |*binding, resource| binding.* = .{
        .binding = resource.index(),
        .descriptorType = @backingInt(resource.descriptorType()),
        .descriptorCount = 1,
        .stageFlags = switch (resource) {
            .uniforms, .cell_backgrounds => vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .texture_0, .texture_1, .image_sampler, .channel_0 => vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        },
    };
    const create_descriptors = try device.deviceProc("vkCreateDescriptorSetLayout");
    try Device.check("vkCreateDescriptorSetLayout", create_descriptors(device.native, &.{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = @intCast(bindings.len),
        .pBindings = bindings.ptr,
    }, null, &self.descriptor_layout));
    const create_layout = try device.deviceProc("vkCreatePipelineLayout");
    try Device.check("vkCreatePipelineLayout", create_layout(device.native, &.{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &self.descriptor_layout,
    }, null, &self.layout));

    const create_module = try device.deviceProc("vkCreateShaderModule");
    const destroy_module = try device.deviceProc("vkDestroyShaderModule");
    const vertex = try createModule(device.native, create_module, program.vertex);
    defer destroy_module(device.native, vertex, null);
    const fragment = try createModule(device.native, create_module, program.fragment);
    defer destroy_module(device.native, fragment, null);

    var attribute_storage: [shaders.max_vertex_attributes]vk.VkVertexInputAttributeDescription = undefined;
    const attributes = attribute_storage[0..program.input.attributes.len];
    for (attributes, program.input.attributes) |*attribute, input| attribute.* = .{
        .location = input.location,
        .binding = input.binding,
        .format = @backingInt(input.format),
        .offset = input.offset,
    };
    const vertex_binding: vk.VkVertexInputBindingDescription = .{
        .binding = 0,
        .stride = program.input.stride,
        .inputRate = vk.VK_VERTEX_INPUT_RATE_INSTANCE,
    };
    const stages = [_]vk.VkPipelineShaderStageCreateInfo{
        .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = @backingInt(program.vertex.stage), .module = vertex, .pName = program.vertex.name.ptr },
        .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = @backingInt(program.fragment.stage), .module = fragment, .pName = program.fragment.name.ptr },
    };
    const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
    const create_pipeline = try device.deviceProc("vkCreateGraphicsPipelines");
    try Device.check("vkCreateGraphicsPipelines", create_pipeline(device.native, null, 1, &.{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &vk.VkPipelineRenderingCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &format,
        },
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = if (attributes.len == 0) 0 else 1,
            .pVertexBindingDescriptions = if (attributes.len == 0) null else &vertex_binding,
            .vertexAttributeDescriptionCount = @intCast(attributes.len),
            .pVertexAttributeDescriptions = if (attributes.len == 0) null else attributes.ptr,
        },
        .pInputAssemblyState = &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = @backingInt(program.topology),
        },
        .pViewportState = &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        },
        .pRasterizationState = &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .lineWidth = 1,
        },
        .pMultisampleState = &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        },
        .pColorBlendState = &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &.{
                .blendEnable = if (program.blend) vk.VK_TRUE else vk.VK_FALSE,
                .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
                .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .colorBlendOp = vk.VK_BLEND_OP_ADD,
                .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
                .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .alphaBlendOp = vk.VK_BLEND_OP_ADD,
                .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
            },
        },
        .pDynamicState = &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        },
        .layout = self.layout,
        .basePipelineIndex = -1,
    }, null, &self.native));
    return self;
}

fn createModule(device: vk.VkDevice, create: Proc("vkCreateShaderModule"), code: shaders.Bytecode) !vk.VkShaderModule {
    var module: vk.VkShaderModule = null;
    try Device.check("vkCreateShaderModule", create(device, &.{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.words.len * @sizeOf(u32),
        .pCode = code.words.ptr,
    }, null, &module));
    return module;
}

/// Destroy after the last use of the pipeline by submitted commands.
pub fn deinit(self: Pipeline) void {
    if (self.native != null) self.destroy_pipeline(self.device, self.native, null);
    if (self.layout != null) self.destroy_layout(self.device, self.layout, null);
    if (self.descriptor_layout != null) self.destroy_descriptors(self.device, self.descriptor_layout, null);
}
