//! Translate a generic terminal render pass to native draw calls.
const RenderPass = @This();
const std = @import("std");
const Context = @import("Context.zig");
const Device = @import("Device.zig");
const Texture = @import("Texture.zig");
const Target = @import("../DirectX12.zig").Target;
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("buffer.zig").RawBuffer;
const d3d = @import("d3d12.zig");
const dxgi = @import("dxgi.zig");

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

context: *Context,
target: ?Texture = null,
target_state: d3d.D3D12_RESOURCE_STATES = Context.texture_state,

const RenderTargetView = extern struct {
    format: dxgi.DXGI_FORMAT,
    dimension: u32 = 4,
    view: [3]u32 = .{ 0, 0, 0 },
};

pub fn begin(context: *Context, attachments: []const Options.Attachment, backbuffer: Texture) RenderPass {
    std.debug.assert(attachments.len == 1);
    if (context.rtv_used == Context.rtv_count) {
        context.failed = true;
        return .{ .context = context };
    }
    const attachment = attachments[0];
    const target, const target_state = switch (attachment.target) {
        .texture => |texture| .{ texture, Context.texture_state },
        .target => .{ backbuffer, d3d.D3D12_RESOURCE_STATES.PRESENT },
    };
    const size = context.device.native.GetDescriptorHandleIncrementSize(.RTV);
    const start = context.rtv.GetCPUDescriptorHandleForHeapStart().ptr;
    const rtv: d3d.D3D12_CPU_DESCRIPTOR_HANDLE = .{
        .ptr = start + size * (context.frame_index * Context.rtv_count + context.rtv_used),
    };
    context.rtv_used += 1;

    context.transition(target.resource, target_state, .RENDER_TARGET);
    const view: RenderTargetView = .{ .format = target.format };
    context.device.native.CreateRenderTargetView(target.resource, &view, rtv);
    const list = context.commandList();
    list.OMSetRenderTargets(1, &.{rtv}, .FALSE, null);
    list.RSSetViewports(1, &.{.{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(target.width),
        .Height = @floatFromInt(target.height),
        .MinDepth = 0,
        .MaxDepth = 1,
    }});
    list.RSSetScissorRects(1, &.{.{
        .left = 0,
        .top = 0,
        .right = @intCast(target.width),
        .bottom = @intCast(target.height),
    }});
    if (attachment.clear_color) |color| list.ClearRenderTargetView(rtv, &color, 0, null);
    return .{ .context = context, .target = target, .target_state = target_state };
}

pub fn step(self: *RenderPass, draw: Step) void {
    const context = self.context;
    if (context.failed or draw.draw.instance_count == 0) return;
    const pipeline = draw.pipeline.pso orelse {
        context.failed = true;
        return;
    };
    if (context.srv_used + 2 > Context.srv_count) {
        context.failed = true;
        return;
    }
    const d = context.device.native;
    const list = context.commandList();
    if (draw.buffers.len > 0) if (draw.buffers[0]) |vertices| {
        context.keepResource(vertices.resource) catch {
            context.failed = true;
            return;
        };
    };
    list.SetPipelineState(pipeline);
    if (draw.uniforms) |uniforms| {
        list.SetGraphicsRootConstantBufferView(Device.uniforms_slot, uniforms.resource.GetGPUVirtualAddress());
    }
    if (draw.buffers.len > 0) if (draw.buffers[0]) |vertices| {
        list.IASetVertexBuffers(0, 1, &.{.{
            .BufferLocation = vertices.resource.GetGPUVirtualAddress(),
            .SizeInBytes = vertices.size,
            .StrideInBytes = vertices.stride,
        }});
    };
    if (draw.buffers.len > 1) if (draw.buffers[1]) |cells| {
        list.SetGraphicsRootShaderResourceView(Device.cells_slot, cells.resource.GetGPUVirtualAddress());
    };

    const increment = d.GetDescriptorHandleIncrementSize(.CBV_SRV_UAV);
    const offset = increment * (context.frame_index * Context.srv_count + context.srv_used);
    const start_cpu = context.srv.GetCPUDescriptorHandleForHeapStart().ptr + offset;
    const start_gpu = context.srv.GetGPUDescriptorHandleForHeapStart().ptr + offset;
    context.srv_used += 2;
    for (0..2) |i| {
        const texture = if (i < draw.textures.len) draw.textures[i] else null;
        // Kitty and background images can be replaced independently of the
        // frame slot. The shader-visible descriptor does not retain them.
        if (texture) |tex| context.keepResource(tex.resource) catch {
            context.failed = true;
            return;
        };
        const view: d3d.D3D12_SHADER_RESOURCE_VIEW_DESC = .{
            .Format = if (texture) |tex| tex.format else .R8G8B8A8_UNORM,
            .ViewDimension = .TEXTURE2D,
            .Shader4ComponentMapping = d3d.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING,
            .u = .{ .Texture2D = .{
                .MostDetailedMip = 0,
                .MipLevels = 1,
                .PlaneSlice = 0,
                .ResourceMinLODClamp = 0,
            } },
        };
        d.CreateShaderResourceView(if (texture) |tex| tex.resource else null, &view, .{ .ptr = start_cpu + increment * i });
    }
    list.SetGraphicsRootDescriptorTable(Device.textures_slot, .{ .ptr = start_gpu });
    list.IASetPrimitiveTopology(switch (draw.draw.type) {
        .triangle => .TRIANGLELIST,
        .triangle_strip => .TRIANGLESTRIP,
    });
    list.DrawInstanced(@intCast(draw.draw.vertex_count), @intCast(draw.draw.instance_count), 0, 0);
}

pub fn complete(self: *const RenderPass) void {
    if (self.target) |target| self.context.transition(target.resource, .RENDER_TARGET, self.target_state);
}
