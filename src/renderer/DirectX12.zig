//! Direct3D 12 implementation of the generic terminal renderer.
const DirectX12 = @This();
const std = @import("std");
const renderer = @import("../renderer.zig");
const config = @import("../config.zig");
const font = @import("../font/main.zig");
const w32 = @import("../apprt/win32/win32.zig");
const Surface = @import("../apprt/win32/Surface.zig");
const com = @import("directx12/com.zig");
const d3d = @import("directx12/d3d12.zig");
const dcomp = @import("directx12/dcomp.zig");
const dxgi = @import("directx12/dxgi.zig");
const Context = @import("directx12/Context.zig");
const buffer = @import("directx12/buffer.zig");
const Renderer = renderer.GenericRenderer(DirectX12);
const log = std.log.scoped(.directx12);

pub const Device = @import("directx12/Device.zig");
pub const Texture = @import("directx12/Texture.zig");
pub const Target = struct {
    width: usize,
    height: usize,

    pub fn deinit(_: Target) void {}
};
pub const Pipeline = @import("directx12/Pipeline.zig");
pub const RenderPass = @import("directx12/RenderPass.zig");
pub const Sampler = RenderPass.Sampler;
pub const shaders = @import("directx12/shaders.zig");
pub const Buffer = buffer.Buffer;
pub const custom_shader_target: renderer.shadertoy.Target = .hlsl;
pub const custom_shader_y_is_down = true;
pub const swap_chain_count = Context.frame_count;

const backbuffer_format: dxgi.DXGI_FORMAT = .B8G8R8A8_UNORM;
const chain_count = 2;
const Presentation = struct {
    native: *dxgi.IDXGISwapChain1,
    chain: *dxgi.IDXGISwapChain3,
    composition: *dcomp.IDCompositionDevice,
    window: *dcomp.IDCompositionTarget,
    visual: *dcomp.IDCompositionVisual,
    flags: u32,
    latency_event: ?w32.HANDLE,
    frame_reserved: bool = false,
    width: u32,
    height: u32,

    fn init(context: *Context, hwnd: w32.HWND, width: u32, height: u32) !Presentation {
        var native: ?*dxgi.IDXGISwapChain1 = null;
        var desc: dxgi.DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = width,
            .Height = height,
            .Format = backbuffer_format,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = chain_count,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_SEQUENTIAL,
            .AlphaMode = .PREMULTIPLIED,
            .Flags = dxgi.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT,
        };
        const factory = context.device.factory;
        if (com.FAILED(factory.CreateSwapChainForComposition(@ptrCast(context.queue), &desc, null, &native))) {
            desc.Flags = 0;
            try com.check("CreateSwapChainForComposition", factory.CreateSwapChainForComposition(@ptrCast(context.queue), &desc, null, &native));
        }
        errdefer _ = native.?.Release();
        const chain = try com.query(dxgi.IDXGISwapChain3, native.?);
        errdefer _ = chain.Release();

        const latency_event = if (desc.Flags != 0) configureLatency(native.?) catch null else null;
        errdefer {
            if (latency_event) |event| _ = w32.CloseHandle(event);
        }
        if (latency_event == null) log.warn("DXGI presentation pacing is unavailable; waiting for each frame on the GPU fence", .{});

        var composition: ?*dcomp.IDCompositionDevice = null;
        try com.check("DCompositionCreateDevice2", DCompositionCreateDevice2(null, &dcomp.IDCompositionDevice.IID, @ptrCast(&composition)));
        errdefer _ = composition.?.Release();
        var window: ?*dcomp.IDCompositionTarget = null;
        try com.check("CreateTargetForHwnd", composition.?.CreateTargetForHwnd(hwnd, 1, &window));
        errdefer _ = window.?.Release();
        var visual: ?*dcomp.IDCompositionVisual = null;
        try com.check("CreateVisual", composition.?.CreateVisual(&visual));
        errdefer _ = visual.?.Release();
        try com.check("IDCompositionVisual.SetContent", visual.?.SetContent(@ptrCast(native.?)));
        try com.check("IDCompositionTarget.SetRoot", window.?.SetRoot(visual.?));
        try com.check("IDCompositionDevice.Commit", composition.?.Commit());
        return .{
            .native = native.?,
            .chain = chain,
            .composition = composition.?,
            .window = window.?,
            .visual = visual.?,
            .flags = desc.Flags,
            .latency_event = latency_event,
            .width = width,
            .height = height,
        };
    }

    fn configureLatency(native: *dxgi.IDXGISwapChain1) !w32.HANDLE {
        const chain = try com.query(dxgi.IDXGISwapChain2, native);
        defer _ = chain.Release();
        try com.check("SetMaximumFrameLatency", chain.SetMaximumFrameLatency(1));
        return chain.GetFrameLatencyWaitableObject() orelse error.DirectX12Failure;
    }

    fn deinit(self: *Presentation) void {
        _ = self.window.SetRoot(null);
        _ = self.composition.Commit();
        _ = self.visual.Release();
        _ = self.window.Release();
        _ = self.composition.Release();
        if (self.latency_event) |event| _ = w32.CloseHandle(event);
        _ = self.chain.Release();
        _ = self.native.Release();
    }

    fn resize(self: *Presentation, width: u32, height: u32) !void {
        try com.check("ResizeBuffers", self.native.ResizeBuffers(chain_count, width, height, backbuffer_format, self.flags));
        self.width = width;
        self.height = height;
    }

    fn backBuffer(self: *const Presentation) !*d3d.ID3D12Resource {
        var result: ?*d3d.ID3D12Resource = null;
        try com.check("Get back buffer", self.chain.GetBuffer(self.chain.GetCurrentBackBufferIndex(), &d3d.ID3D12Resource.IID, @ptrCast(&result)));
        return result.?;
    }

    fn reserveFrame(self: *Presentation) bool {
        const event = self.latency_event orelse return false;
        // A failed render may retry without having presented. Keep that
        // reservation until the next Present, which consumes it.
        if (!self.frame_reserved)
            self.frame_reserved = w32.WaitForSingleObject(event, 50) == w32.WAIT_OBJECT_0;
        return self.frame_reserved;
    }

    fn present(self: *Presentation) com.HRESULT {
        self.frame_reserved = false;
        return self.chain.Present(1, 0);
    }
};

extern "dcomp" fn DCompositionCreateDevice2(?*com.IUnknown, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT;
extern "gdi32" fn PatBlt(w32.HDC, i32, i32, i32, i32, u32) callconv(.winapi) i32;

surface: *Surface,
alloc: std.mem.Allocator,
context: *Context,
blending: config.Config.AlphaBlending,
presentation: ?Presentation = null,

pub fn init(alloc: std.mem.Allocator, device: *const Device, options: renderer.Options) !DirectX12 {
    const context = try alloc.create(Context);
    errdefer alloc.destroy(context);
    context.* = try .init(device);
    return .{ .surface = options.rt_surface, .alloc = alloc, .context = context, .blending = options.config.blending };
}

pub fn deinit(self: *DirectX12) void {
    self.waitGpuIdle() catch {};
    if (self.presentation) |*presentation| presentation.deinit();
    self.context.deinit();
    self.alloc.destroy(self.context);
}

pub fn prepareFrame(self: *DirectX12, index: usize) !void {
    try self.context.prepareFrame(index);
}

pub fn waitGpuIdle(self: *DirectX12) !void {
    try self.context.waitIdle();
}

pub fn surfaceSize(self: *const DirectX12) !struct { width: u32, height: u32 } {
    const hwnd = self.surface.hwnd orelse return error.MissingSurface;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return error.MissingSurface;
    return .{ .width = @intCast(@max(0, rect.right - rect.left)), .height = @intCast(@max(0, rect.bottom - rect.top)) };
}

pub fn drawFrameStart(_: *DirectX12) void {}
pub fn drawFrameEnd(_: *DirectX12) void {}

fn format(self: DirectX12) dxgi.DXGI_FORMAT {
    return if (self.blending.isLinear()) .B8G8R8A8_UNORM_SRGB else .B8G8R8A8_UNORM;
}

pub fn initShaders(self: *const DirectX12, alloc: std.mem.Allocator, custom_shaders: []const [:0]const u8) !shaders.Shaders {
    return shaders.Shaders.init(alloc, self.context.device, self.format(), custom_shaders);
}

pub fn initTarget(self: *const DirectX12, width: usize, height: usize) !Target {
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidTextureExtent;
    // The generic renderer recreates targets after resize and when a hidden
    // surface is shown again, including when its dimensions stay the same.
    self.context.redirection_needs_clear = true;
    return .{ .width = width, .height = height };
}

pub fn textureOptions(self: DirectX12) Texture.Options {
    return .{ .context = self.context, .format = self.format(), .resource_format = .B8G8R8A8_TYPELESS, .render_target = true };
}

pub fn samplerOptions(_: DirectX12) Sampler.Options {
    return .{};
}

fn bufferOptions(self: DirectX12) buffer.Options {
    return .{ .device = self.context.device };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub const ImageTextureFormat = enum { gray, rgba, bgra };

pub fn imageTextureOptions(self: DirectX12, pixel_format: ImageTextureFormat, srgb: bool) Texture.Options {
    return .{ .context = self.context, .format = switch (pixel_format) {
        .gray => .R8_UNORM,
        .rgba => if (srgb) .R8G8B8A8_UNORM_SRGB else .R8G8B8A8_UNORM,
        .bgra => if (srgb) .B8G8R8A8_UNORM_SRGB else .B8G8R8A8_UNORM,
    } };
}

pub fn initAtlasTexture(self: *const DirectX12, atlas: *const font.Atlas) Texture.Error!Texture {
    return Texture.init(self.imageTextureOptions(switch (atlas.format) {
        .grayscale => .gray,
        .bgra => .bgra,
        else => return error.UnsupportedAtlasFormat,
    }, true), atlas.size, atlas.size, null);
}

const Frame = struct {
    api: *DirectX12,
    terminal_renderer: *Renderer,
    target: *Target,
    backbuffer: *d3d.ID3D12Resource,
    wait_for_gpu: bool,

    pub fn renderPass(self: *const Frame, attachments: []const RenderPass.Options.Attachment) RenderPass {
        return RenderPass.begin(self.api.context, attachments, .{
            .context = self.api.context,
            .resource = self.backbuffer,
            // DXGI stores this buffer as UNORM. An sRGB RTV performs the same
            // encoding as the offscreen textures for linear blending.
            .format = self.api.format(),
            .width = self.target.width,
            .height = self.target.height,
        });
    }

    pub fn complete(self: *const Frame, sync: bool) void {
        self.present(sync or self.wait_for_gpu) catch |err| {
            log.warn("D3D12 frame failed: {t}", .{err});
            self.terminal_renderer.frameCompleted(.unhealthy);
            return;
        };
        self.clearRedirection();
        self.terminal_renderer.frameCompleted(.healthy);
        self.api.surface.signalFrameDrawn();
    }

    fn clearRedirection(self: *const Frame) void {
        const context = self.api.context;
        if (!context.redirection_needs_clear) return;
        const hwnd = self.api.surface.hwnd orelse return;
        if (w32.IsWindowVisible_(hwnd) == 0) return;
        const dc = w32.GetDC(hwnd) orelse return;
        defer _ = w32.ReleaseDC(hwnd, dc);
        // The swap-chain visual is composed over the child HWND's GDI plane.
        // Clear that plane's bits before relying on transparent pixels to
        // show the same material as the surrounding top-level window.
        const blackness = 0x00000042;
        if (PatBlt(dc, 0, 0, @intCast(self.target.width), @intCast(self.target.height), blackness) == 0) return;
        if (w32.GdiFlush() == 0) return;
        context.redirection_needs_clear = false;
    }

    fn present(self: *const Frame, sync: bool) !void {
        const context = self.api.context;
        if (context.failed) {
            try context.discardFrame();
            return error.RenderDescriptorLimit;
        }
        try context.executeFrame();
        const result = self.api.presentation.?.present();
        try context.finishFrame(sync);
        try com.check("Present", result);
    }
};

pub fn beginFrame(self: *DirectX12, terminal_renderer: *Renderer, target: *Target) !Frame {
    const width: u32 = @intCast(target.width);
    const height: u32 = @intCast(target.height);
    var resized = false;
    if (self.presentation == null) {
        self.presentation = try .init(self.context, self.surface.hwnd orelse return error.MissingSurface, width, height);
        resized = true;
    } else if (self.presentation.?.width != width or self.presentation.?.height != height) {
        // DXGI requires the application to release every back-buffer reference
        // before replacing the swap-chain buffers.
        try self.waitGpuIdle();
        try self.presentation.?.resize(width, height);
        resized = true;
    }
    const paced = self.presentation.?.reserveFrame();
    const backbuffer = try self.presentation.?.backBuffer();
    defer _ = backbuffer.Release();
    const commands = try self.context.beginFrame();
    errdefer self.context.discardFrame() catch {};
    try self.context.keepResource(backbuffer);
    commands.SetDescriptorHeaps(1, &.{self.context.srv});
    commands.SetGraphicsRootSignature(self.context.device.root_signature);
    return .{ .api = self, .terminal_renderer = terminal_renderer, .target = target, .backbuffer = backbuffer, .wait_for_gpu = resized or !paced };
}
