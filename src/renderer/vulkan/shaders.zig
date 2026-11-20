//! Vulkan forms of the shared terminal HLSL stages and their CPU-facing ABI.
const std = @import("std");
const abi = @import("../opengl/shaders.zig");
const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const log = std.log.scoped(.vulkan);

pub const Uniforms = abi.Uniforms;
pub const CellText = abi.CellText;
pub const CellBg = abi.CellBg;
pub const Image = abi.Image;
pub const BgImage = abi.BgImage;

pub const source_path = "src/renderer/directx12/shaders.hlsl";
pub const spirv_args: []const []const u8 = &.{
    "-spirv", "-fspv-target-env=vulkan1.1", "-fvk-t-shift", "1", "0", "-fvk-s-shift", "5", "0",
};

pub const Stage = enum(u32) {
    vertex = 0x00000001,
    fragment = 0x00000010,
};

pub const Entry = enum {
    full_screen_vs,
    bg_color_ps,
    cell_bg_ps,
    cell_text_vs,
    cell_text_ps,
    image_vs,
    image_ps,
    bg_image_vs,
    bg_image_ps,

    pub fn stage(self: Entry) Stage {
        return switch (self) {
            .full_screen_vs, .cell_text_vs, .image_vs, .bg_image_vs => .vertex,
            .bg_color_ps, .cell_bg_ps, .cell_text_ps, .image_ps, .bg_image_ps => .fragment,
        };
    }

    pub fn profile(self: Entry) []const u8 {
        return switch (self.stage()) {
            .vertex => "vs_6_0",
            .fragment => "ps_6_0",
        };
    }

    pub fn embedName(comptime self: Entry) []const u8 {
        return "vulkan_" ++ @tagName(self);
    }
};

pub const DescriptorType = enum(u32) {
    sampler = 0,
    combined_image_sampler = 1,
    sampled_image = 2,
    uniform_buffer = 6,
    storage_buffer = 7,
};

pub const Binding = enum(u32) {
    uniforms = 0,
    texture_0 = 1,
    texture_1 = 2,
    cell_backgrounds = 4,
    image_sampler = 5,
    // This is a separate resource kind from the built-in sampled image at
    // binding 1. Its Vulkan binding index comes from index().
    channel_0,

    pub const set: u32 = 0;

    pub fn index(self: Binding) u32 {
        return switch (self) {
            .channel_0 => 1,
            else => @backingInt(self),
        };
    }

    pub fn descriptorType(self: Binding) DescriptorType {
        return switch (self) {
            .uniforms => .uniform_buffer,
            .texture_0, .texture_1 => .sampled_image,
            .cell_backgrounds => .storage_buffer,
            .image_sampler => .sampler,
            .channel_0 => .combined_image_sampler,
        };
    }
};

pub const VertexFormat = enum(u32) {
    r8_uint = 13,
    r8g8b8a8_unorm = 37,
    r16g16_uint = 81,
    r16g16_sint = 82,
    r32_sfloat = 100,
    r32g32_uint = 101,
    r32g32_sfloat = 103,
    r32g32b32a32_sfloat = 109,
};

pub const VertexAttribute = extern struct {
    location: u32,
    binding: u32 = 0,
    format: VertexFormat,
    offset: u32,
};

pub const VertexInput = struct {
    /// A nonempty input uses binding 0 and VK_VERTEX_INPUT_RATE_INSTANCE.
    stride: u32 = 0,
    attributes: []const VertexAttribute = &.{},
};

fn attribute(comptime T: type, comptime field: []const u8, location: u32, format: VertexFormat) VertexAttribute {
    return .{ .location = location, .format = format, .offset = @offsetOf(T, field) };
}

const cell_text_input: VertexInput = .{
    .stride = @sizeOf(CellText),
    .attributes = &.{
        attribute(CellText, "glyph_pos", 0, .r32g32_uint),
        attribute(CellText, "glyph_size", 1, .r32g32_uint),
        attribute(CellText, "bearings", 2, .r16g16_sint),
        attribute(CellText, "grid_pos", 3, .r16g16_uint),
        attribute(CellText, "color", 4, .r8g8b8a8_unorm),
        attribute(CellText, "atlas", 5, .r8_uint),
        attribute(CellText, "bools", 6, .r8_uint),
    },
};

const image_input: VertexInput = .{
    .stride = @sizeOf(Image),
    .attributes = &.{
        attribute(Image, "grid_pos", 0, .r32g32_sfloat),
        attribute(Image, "cell_offset", 1, .r32g32_sfloat),
        attribute(Image, "source_rect", 2, .r32g32b32a32_sfloat),
        attribute(Image, "dest_size", 3, .r32g32_sfloat),
    },
};

const bg_image_input: VertexInput = .{
    .stride = @sizeOf(BgImage),
    .attributes = &.{
        attribute(BgImage, "opacity", 0, .r32_sfloat),
        attribute(BgImage, "info", 1, .r8_uint),
    },
};

pub const max_vertex_attributes = cell_text_input.attributes.len;

pub const Topology = enum(u32) {
    triangle_list = 3,
    triangle_strip = 4,
};

pub const Bytecode = struct {
    stage: Stage,
    name: [:0]const u8,
    words: []const u32,

    fn embed(comptime entry: Entry) Bytecode {
        const data = &struct {
            const bytes align(@alignOf(u32)) = @embedFile(entry.embedName()).*;
        }.bytes;
        comptime {
            if (data.len < 20 or data.len % @sizeOf(u32) != 0 or
                std.mem.readInt(u32, data[0..4], .little) != 0x07230203)
                @compileError("Invalid SPIR-V bytecode: " ++ @tagName(entry));
        }
        return .{ .stage = entry.stage(), .name = @tagName(entry), .words = std.mem.bytesAsSlice(u32, data) };
    }

    fn copyFragment(alloc: std.mem.Allocator, bytes: []const u8) !Bytecode {
        if (bytes.len < 20 or bytes.len % @sizeOf(u32) != 0 or
            std.mem.readInt(u32, bytes[0..4], .little) != 0x07230203)
            return error.SpirvInvalid;
        const words = try alloc.alloc(u32, bytes.len / @sizeOf(u32));
        @memcpy(std.mem.sliceAsBytes(words), bytes);
        return .{ .stage = .fragment, .name = "main", .words = words };
    }
};

pub const Pass = enum { bg_color, cell_bg, cell_text, image, bg_image };

pub const Program = struct {
    vertex: Bytecode,
    fragment: Bytecode,
    vertex_count: u32 = 3,
    topology: Topology = .triangle_list,
    input: VertexInput = .{},
    bindings: []const Binding,
    /// These passes output premultiplied pixels.
    blend: bool = false,
};

pub const Shaders = struct {
    const Pipelines = struct {
        bg_color: Pipeline,
        cell_bg: Pipeline,
        cell_text: Pipeline,
        image: Pipeline,
        bg_image: Pipeline,
    };

    pipelines: Pipelines,
    post_pipelines: []const Pipeline = &.{},
    defunct: bool = false,

    pub const uninit: Shaders = .{ .pipelines = undefined, .defunct = true };

    pub fn init(alloc: std.mem.Allocator, device: *const Device, format: Device.vk.VkFormat, custom: []const [:0]const u8) !Shaders {
        var result: Shaders = .{ .pipelines = undefined };
        var initialized: usize = 0;
        const passes = @typeInfo(Pass).@"enum".field_names;
        errdefer inline for (passes, 0..) |name, i| {
            if (i < initialized) @field(result.pipelines, name).deinit();
        };
        inline for (passes) |name| {
            @field(result.pipelines, name) = try .init(device, format, program(@field(Pass, name)));
            initialized += 1;
        }
        result.post_pipelines = try initPostPipelines(alloc, device, format, custom);
        return result;
    }

    pub fn deinit(self: *Shaders, alloc: std.mem.Allocator) void {
        if (self.defunct) return;
        inline for (@typeInfo(Pass).@"enum".field_names) |name| @field(self.pipelines, name).deinit();
        for (self.post_pipelines) |pipeline| pipeline.deinit();
        alloc.free(self.post_pipelines);
        self.* = .uninit;
    }

    fn initPostPipelines(
        alloc: std.mem.Allocator,
        device: *const Device,
        format: Device.vk.VkFormat,
        custom: []const [:0]const u8,
    ) ![]const Pipeline {
        if (custom.len == 0) return &.{};

        var pipelines: std.ArrayList(Pipeline) = .empty;
        defer pipelines.deinit(alloc);
        errdefer for (pipelines.items) |pipeline| pipeline.deinit();
        try pipelines.ensureTotalCapacity(alloc, custom.len);

        for (custom, 1..) |source, index| {
            const fragment = Bytecode.copyFragment(alloc, source) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.SpirvInvalid => {
                    log.warn("invalid Vulkan custom shader bytecode for pass {d}", .{index});
                    continue;
                },
            };
            defer alloc.free(fragment.words);
            const pipeline = Pipeline.init(device, format, .{
                .vertex = .embed(.full_screen_vs),
                .fragment = fragment,
                .bindings = &.{ .uniforms, .channel_0 },
            }) catch |err| {
                log.warn("Vulkan custom shader pass {d} pipeline failed: {t}", .{ index, err });
                continue;
            };
            pipelines.appendAssumeCapacity(pipeline);
        }

        return try pipelines.toOwnedSlice(alloc);
    }

    pub fn program(comptime pass: Pass) Program {
        return switch (pass) {
            .bg_color => .{
                .vertex = .embed(.full_screen_vs),
                .fragment = .embed(.bg_color_ps),
                .bindings = &.{.uniforms},
            },
            .cell_bg => .{
                .vertex = .embed(.full_screen_vs),
                .fragment = .embed(.cell_bg_ps),
                .bindings = &.{ .uniforms, .cell_backgrounds },
                .blend = true,
            },
            .cell_text => .{
                .vertex = .embed(.cell_text_vs),
                .fragment = .embed(.cell_text_ps),
                .vertex_count = 4,
                .topology = .triangle_strip,
                .input = cell_text_input,
                .bindings = &.{ .uniforms, .texture_0, .texture_1, .cell_backgrounds },
                .blend = true,
            },
            .image => .{
                .vertex = .embed(.image_vs),
                .fragment = .embed(.image_ps),
                .vertex_count = 4,
                .topology = .triangle_strip,
                .input = image_input,
                .bindings = &.{ .uniforms, .texture_0, .image_sampler },
                .blend = true,
            },
            .bg_image => .{
                .vertex = .embed(.bg_image_vs),
                .fragment = .embed(.bg_image_ps),
                .input = bg_image_input,
                .bindings = &.{ .uniforms, .texture_0, .image_sampler },
            },
        };
    }
};

comptime {
    if (@sizeOf(Uniforms) != 144 or @sizeOf(CellBg) != 4 or
        @sizeOf(CellText) != 32 or @sizeOf(Image) != 48 or @sizeOf(BgImage) != 8)
        @compileError("Vulkan terminal shader layout changed");
}
