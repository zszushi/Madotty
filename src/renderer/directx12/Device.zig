//! The app-scoped Direct3D device and pipeline binding layout.
const Device = @This();
const std = @import("std");
const com = @import("com.zig");
const d3d = @import("d3d12.zig");
const dxgi = @import("dxgi.zig");

pub const Options = struct {};

native: *d3d.ID3D12Device,
factory: *dxgi.IDXGIFactory2,
root_signature: *d3d.ID3D12RootSignature,

pub const uniforms_slot = 0;
pub const textures_slot = 1;
pub const cells_slot = 2;

pub fn init(alloc: std.mem.Allocator, _: Options) !*Device {
    var native: ?*d3d.ID3D12Device = null;
    try com.check("D3D12CreateDevice", d3d.D3D12CreateDevice(null, 0xb000, &d3d.ID3D12Device.IID, @ptrCast(&native)));
    errdefer _ = native.?.Release();
    try requireShaderModel6(native.?);

    var factory: ?*dxgi.IDXGIFactory2 = null;
    try com.check("CreateDXGIFactory2", dxgi.CreateDXGIFactory2(0, &dxgi.IDXGIFactory2.IID, @ptrCast(&factory)));
    errdefer _ = factory.?.Release();

    const root = try createRootSignature(native.?);
    errdefer _ = root.Release();

    const result = try alloc.create(Device);
    result.* = .{
        .native = native.?,
        .factory = factory.?,
        .root_signature = root,
    };
    return result;
}

fn requireShaderModel6(device: *d3d.ID3D12Device) !void {
    const feature_shader_model = 7;
    const shader_model_6_0 = 0x60;
    const FeatureData = extern struct { highest_shader_model: u32 };
    var support: FeatureData = .{ .highest_shader_model = shader_model_6_0 };
    const status = device.vtable.CheckFeatureSupport(device, feature_shader_model, &support, @sizeOf(FeatureData));
    if (com.FAILED(status) or support.highest_shader_model < shader_model_6_0) {
        std.log.scoped(.directx12).warn("Shader Model 6.0 is unavailable (HRESULT=0x{x:0>8}, level=0x{x})", .{
            @as(u32, @bitCast(status)), support.highest_shader_model,
        });
        return error.ShaderModel60Unavailable;
    }
}

pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
    _ = self.root_signature.Release();
    _ = self.factory.Release();
    _ = self.native.Release();
    alloc.destroy(self);
}

fn createRootSignature(native: *d3d.ID3D12Device) !*d3d.ID3D12RootSignature {
    const textures = [_]d3d.D3D12_DESCRIPTOR_RANGE{.{
        .RangeType = .SRV,
        .NumDescriptors = 2,
        .BaseShaderRegister = 0,
        .RegisterSpace = 0,
        .OffsetInDescriptorsFromTableStart = 0,
    }};
    const params = [_]d3d.D3D12_ROOT_PARAMETER{
        .{
            .ParameterType = .CBV,
            .ShaderVisibility = .ALL,
            .u = .{ .Descriptor = .{ .ShaderRegister = 0, .RegisterSpace = 0 } },
        },
        .{
            .ParameterType = .DESCRIPTOR_TABLE,
            .ShaderVisibility = .ALL,
            .u = .{ .DescriptorTable = .{ .NumDescriptorRanges = textures.len, .pDescriptorRanges = &textures } },
        },
        .{
            .ParameterType = .SRV,
            .ShaderVisibility = .ALL,
            .u = .{ .Descriptor = .{ .ShaderRegister = 3, .RegisterSpace = 0 } },
        },
    };
    const samplers = [_]d3d.D3D12_STATIC_SAMPLER_DESC{.{
        .Filter = .MIN_MAG_MIP_LINEAR,
        .AddressU = .CLAMP,
        .AddressV = .CLAMP,
        .AddressW = .CLAMP,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = .ALWAYS,
        .BorderColor = .TRANSPARENT_BLACK,
        .MinLOD = 0,
        .MaxLOD = 0,
        .ShaderRegister = 0,
        .RegisterSpace = 0,
        .ShaderVisibility = .ALL,
    }};
    const desc = d3d.D3D12_VERSIONED_ROOT_SIGNATURE_DESC{
        .Version = .VERSION_1_0,
        .u = .{ .Desc_1_0 = .{
            .NumParameters = params.len,
            .pParameters = &params,
            .NumStaticSamplers = samplers.len,
            .pStaticSamplers = &samplers,
            .Flags = .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
        } },
    };
    var blob: ?*d3d.ID3DBlob = null;
    var diagnostics: ?*d3d.ID3DBlob = null;
    const hr = d3d.D3D12SerializeVersionedRootSignature(&desc, &blob, &diagnostics);
    if (diagnostics) |msg| {
        defer _ = msg.Release();
        const bytes: [*]const u8 = @ptrCast(msg.GetBufferPointer());
        std.log.scoped(.directx12).warn("root signature: {s}", .{bytes[0..msg.GetBufferSize()]});
    }
    defer if (blob) |value| {
        _ = value.Release();
    };
    try com.check("D3D12SerializeVersionedRootSignature", hr);

    var root: ?*d3d.ID3D12RootSignature = null;
    try com.check("CreateRootSignature", native.CreateRootSignature(
        0,
        blob.?.GetBufferPointer(),
        blob.?.GetBufferSize(),
        &d3d.ID3D12RootSignature.IID,
        @ptrCast(&root),
    ));
    return root.?;
}
