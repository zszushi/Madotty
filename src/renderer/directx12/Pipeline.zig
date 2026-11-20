//! Native render pipeline. Shader registers are defined by the shared root signature.
const Pipeline = @This();
const std = @import("std");
const Device = @import("Device.zig");
const d3d = @import("d3d12.zig");
const dxgi = @import("dxgi.zig");
const com = @import("com.zig");

pub const Options = struct {
    device: *const Device,
    format: dxgi.DXGI_FORMAT,
    vertex: []const u8,
    pixel: []const u8,
    input: []const d3d.D3D12_INPUT_ELEMENT_DESC = &.{},
    blend: bool = false,
};

pso: ?*d3d.ID3D12PipelineState = null,

pub fn init(opts: Options) !Pipeline {
    const blend: d3d.D3D12_RENDER_TARGET_BLEND_DESC = .{
        .BlendEnable = if (opts.blend) .TRUE else .FALSE,
        .LogicOpEnable = .FALSE,
        .SrcBlend = .ONE,
        .DestBlend = .INV_SRC_ALPHA,
        .BlendOp = .ADD,
        .SrcBlendAlpha = .ONE,
        .DestBlendAlpha = .INV_SRC_ALPHA,
        .BlendOpAlpha = .ADD,
        .LogicOp = .NOOP,
        .RenderTargetWriteMask = @backingInt(d3d.D3D12_COLOR_WRITE_ENABLE.ALL),
    };
    const stencil: d3d.D3D12_DEPTH_STENCILOP_DESC = .{
        .StencilFailOp = .KEEP,
        .StencilDepthFailOp = .KEEP,
        .StencilPassOp = .KEEP,
        .StencilFunc = .ALWAYS,
    };
    const desc: d3d.D3D12_GRAPHICS_PIPELINE_STATE_DESC = .{
        .pRootSignature = opts.device.root_signature,
        .VS = .{ .pShaderBytecode = opts.vertex.ptr, .BytecodeLength = opts.vertex.len },
        .PS = .{ .pShaderBytecode = opts.pixel.ptr, .BytecodeLength = opts.pixel.len },
        .DS = .{ .pShaderBytecode = null, .BytecodeLength = 0 },
        .HS = .{ .pShaderBytecode = null, .BytecodeLength = 0 },
        .GS = .{ .pShaderBytecode = null, .BytecodeLength = 0 },
        .StreamOutput = .{ .pSODeclaration = null, .NumEntries = 0, .pBufferStrides = null, .NumStrides = 0, .RasterizedStream = 0 },
        .BlendState = .{
            .AlphaToCoverageEnable = .FALSE,
            .IndependentBlendEnable = .FALSE,
            .RenderTarget = @splat(blend),
        },
        .SampleMask = std.math.maxInt(u32),
        .RasterizerState = .{
            .FillMode = .SOLID,
            .CullMode = .NONE,
            .FrontCounterClockwise = .FALSE,
            .DepthBias = 0,
            .DepthBiasClamp = 0,
            .SlopeScaledDepthBias = 0,
            .DepthClipEnable = .TRUE,
            .MultisampleEnable = .FALSE,
            .AntialiasedLineEnable = .FALSE,
            .ForcedSampleCount = 0,
            .ConservativeRaster = 0,
        },
        .DepthStencilState = .{
            .DepthEnable = .FALSE,
            .DepthWriteMask = .ZERO,
            .DepthFunc = .ALWAYS,
            .StencilEnable = .FALSE,
            .StencilReadMask = 0,
            .StencilWriteMask = 0,
            .FrontFace = stencil,
            .BackFace = stencil,
        },
        .InputLayout = .{
            .pInputElementDescs = if (opts.input.len == 0) null else opts.input.ptr,
            .NumElements = @intCast(opts.input.len),
        },
        .IBStripCutValue = 0,
        .PrimitiveTopologyType = .TRIANGLE,
        .NumRenderTargets = 1,
        .RTVFormats = .{ opts.format, .UNKNOWN, .UNKNOWN, .UNKNOWN, .UNKNOWN, .UNKNOWN, .UNKNOWN, .UNKNOWN },
        .DSVFormat = .UNKNOWN,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .NodeMask = 0,
        .CachedPSO = .{ .pCachedBlob = null, .CachedBlobSizeInBytes = 0 },
        .Flags = 0,
    };
    var pso: ?*d3d.ID3D12PipelineState = null;
    try com.check("CreateGraphicsPipelineState", opts.device.native.CreateGraphicsPipelineState(
        &desc,
        &d3d.ID3D12PipelineState.IID,
        @ptrCast(&pso),
    ));
    return .{ .pso = pso.? };
}

pub fn deinit(self: Pipeline) void {
    if (self.pso) |pso| _ = pso.Release();
}
