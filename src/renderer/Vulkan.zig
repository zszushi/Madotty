//! Vulkan implementation of the shared terminal renderer on Win32.
const Vulkan = @This();
const std = @import("std");
const renderer = @import("../renderer.zig");
const config = @import("../config.zig");
const font = @import("../font/main.zig");
const w32 = @import("../apprt/win32/win32.zig");
const Surface = @import("../apprt/win32/Surface.zig");
const NativeDevice = @import("vulkan/Device.zig");
const vk = NativeDevice.vk;
const Swapchain = @import("vulkan/Swapchain.zig");
const Uploads = @import("vulkan/Uploads.zig");
const buffer = @import("vulkan/buffer.zig");
const Renderer = renderer.GenericRenderer(Vulkan);
const log = std.log.scoped(.vulkan);

pub const Texture = @import("vulkan/Texture.zig");
pub const Pipeline = @import("vulkan/Pipeline.zig");
pub const RenderPass = @import("vulkan/RenderPass.zig");
pub const Sampler = RenderPass.Sampler;
pub const shaders = @import("vulkan/shaders.zig");
pub const Buffer = buffer.Buffer;
pub const custom_shader_target: renderer.shadertoy.Target = .spirv;
pub const custom_shader_y_is_down = true;
pub const swap_chain_count = Swapchain.frame_count;

/// Native devices currently belong to the surface whose HWND was used to
/// select its presentation queue.
pub const Device = struct {
    pub const Options = struct {};

    pub fn init(alloc: std.mem.Allocator, _: Options) !*Device {
        const result = try alloc.create(Device);
        result.* = .{};
        return result;
    }

    pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

pub const Target = struct {
    width: usize,
    height: usize,

    pub fn deinit(_: Target) void {}
};

const Context = struct {
    device: NativeDevice,
    frames: [swap_chain_count]RenderPass.FrameContext,
    index: usize = 0,
    swap: ?Swapchain = null,
    format: vk.VkSurfaceFormatKHR,
    recreate: bool = false,
};

alloc: std.mem.Allocator,
surface: *Surface,
context: *Context,
blending: config.Config.AlphaBlending,

pub fn init(alloc: std.mem.Allocator, _: *const Device, options: renderer.Options) !Vulkan {
    const surface = options.rt_surface;
    const hwnd = surface.hwnd orelse return error.MissingSurface;
    const context = try alloc.create(Context);
    errdefer alloc.destroy(context);
    context.* = .{
        .device = try .init(alloc, @ptrFromInt(@intFromPtr(hwnd))),
        .frames = undefined,
        .format = undefined,
    };
    errdefer context.device.deinit();
    context.device.uploads = try Uploads.init(&context.device);

    const blending = options.config.blending;
    context.format = try Swapchain.chooseFormat(alloc, &context.device, blending.isLinear());
    var initialized: usize = 0;
    errdefer for (context.frames[0..initialized]) |*frame| frame.deinit();
    for (&context.frames) |*frame| {
        frame.* = try .init(alloc, &context.device);
        initialized += 1;
    }
    const result: Vulkan = .{ .alloc = alloc, .surface = surface, .context = context, .blending = blending };

    // Test presentation on the actual terminal HWND before the launcher
    // commits and a command can start. Keep these resources for rendering.
    const startup = &surface.app.renderer_startup;
    if (startup.handoff != null) {
        const size = try result.surfaceSize();
        context.swap = try Swapchain.initWithFormat(alloc, &context.device, size.width, size.height, context.format);
        errdefer if (context.swap) |*swap| swap.deinit();
        try startup.commit();
    }
    return result;
}

pub fn deinit(self: *Vulkan) void {
    const context = self.context;
    if (context.swap) |*swap| swap.deinit() else self.waitGpuIdle() catch {};
    for (&context.frames) |*frame| frame.deinit();
    context.device.deinit();
    self.alloc.destroy(context);
}

pub fn requestDraw(self: *Vulkan) void {
    self.surface.requestVulkanDraw();
}

/// A new or out-of-date swapchain follows the normal creation path.
pub fn frameSlotReady(self: *const Vulkan, index: usize) !bool {
    if (self.context.recreate) return true;
    const swap = if (self.context.swap) |*current| current else return true;
    return swap.slotReady(index);
}

pub fn prepareFrame(self: *Vulkan, index: usize) !void {
    const context = self.context;
    if (context.recreate) self.discardSwapchain();
    if (context.swap) |*swap| try swap.waitSlot(index);
    try context.device.uploads.?.collect();
    context.index = index;
    try context.frames[index].reset();
}

fn discardSwapchain(self: *Vulkan) void {
    if (self.context.swap) |*swap| swap.deinit();
    self.context.swap = null;
}

pub fn waitGpuIdle(self: *Vulkan) !void {
    const device = &self.context.device;
    try device.uploads.?.flush();
    const idle = try device.deviceProc("vkDeviceWaitIdle");
    try NativeDevice.check("vkDeviceWaitIdle", idle(device.native));
}

pub fn surfaceSize(self: *const Vulkan) !struct { width: u32, height: u32 } {
    var rect: w32.RECT = undefined;
    const hwnd = self.surface.hwnd orelse return error.MissingSurface;
    if (w32.GetClientRect(hwnd, &rect) == 0) return error.MissingSurface;
    return .{ .width = @intCast(@max(0, rect.right - rect.left)), .height = @intCast(@max(0, rect.bottom - rect.top)) };
}

pub fn drawFrameStart(_: *Vulkan) void {}
pub fn drawFrameEnd(_: *Vulkan) void {}

pub fn initShaders(self: *Vulkan, alloc: std.mem.Allocator, custom: []const [:0]const u8) !shaders.Shaders {
    const context = self.context;
    const format = try Swapchain.chooseFormat(alloc, &context.device, self.blending.isLinear());
    const result = try shaders.Shaders.init(alloc, &context.device, format.format, custom);
    context.recreate = context.recreate or format.format != context.format.format;
    context.format = format;
    return result;
}

pub fn initTarget(_: *const Vulkan, width: usize, height: usize) !Target {
    return .{ .width = width, .height = height };
}

fn bufferOptions(self: Vulkan) buffer.Options {
    return .{ .device = &self.context.device };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub fn textureOptions(self: Vulkan) Texture.Options {
    return .{ .device = &self.context.device, .format = self.context.format.format, .render_target = true };
}

pub fn samplerOptions(_: Vulkan) Sampler.Options {
    return .{};
}

pub const ImageTextureFormat = enum { gray, rgba, bgra };

pub fn imageTextureOptions(self: Vulkan, pixel_format: ImageTextureFormat, srgb: bool) Texture.Options {
    return .{
        .device = &self.context.device,
        .format = switch (pixel_format) {
            .gray => vk.VK_FORMAT_R8_UNORM,
            .rgba => if (srgb) vk.VK_FORMAT_R8G8B8A8_SRGB else vk.VK_FORMAT_R8G8B8A8_UNORM,
            .bgra => if (srgb) vk.VK_FORMAT_B8G8R8A8_SRGB else vk.VK_FORMAT_B8G8R8A8_UNORM,
        },
    };
}

pub fn initAtlasTexture(self: *const Vulkan, atlas: *const font.Atlas) Texture.Error!Texture {
    const format: ImageTextureFormat = switch (atlas.format) {
        .grayscale => .gray,
        .bgra => .bgra,
        .bgr => return error.UnsupportedAtlasFormat,
    };
    return Texture.init(self.imageTextureOptions(format, true), atlas.size, atlas.size, null);
}

const Frame = struct {
    api: *Vulkan,
    terminal_renderer: *Renderer,
    acquired: Swapchain.Acquired,
    frame_context: *RenderPass.FrameContext,

    pub fn renderPass(self: *const Frame, attachments: []const RenderPass.Options.Attachment) RenderPass {
        const swap = &self.api.context.swap.?;
        return RenderPass.begin(self.frame_context, attachments, .{
            .native = self.acquired.native,
            .view = self.acquired.view,
            .width = swap.extent.width,
            .height = swap.extent.height,
            .format = swap.format,
        });
    }

    pub fn complete(self: *const Frame, sync: bool) void {
        self.present(sync) catch |err| {
            log.warn("Vulkan frame failed: {t}", .{err});
            self.api.context.recreate = true;
            self.terminal_renderer.cells_rebuilt = true;
            self.terminal_renderer.frameCompleted(.unhealthy);
            return;
        };
        self.terminal_renderer.frameCompleted(.healthy);
    }

    fn present(self: *const Frame, sync: bool) !void {
        const swap = &self.api.context.swap.?;
        const status = try swap.submit(self.acquired);
        if (sync) try swap.waitSlot(self.acquired.slot);
        if (self.frame_context.failure) |failure| return failure;
        if (status == .presented) {
            self.api.surface.signalFrameDrawn();
        } else {
            self.api.context.recreate = status == .resize;
            self.terminal_renderer.cells_rebuilt = true;
            self.api.requestDraw();
        }
    }
};

pub fn beginFrame(self: *Vulkan, terminal_renderer: *Renderer, target: *Target) !Frame {
    const context = self.context;
    // All texture copies recorded while preparing the frame precede its draw
    // commands on the same queue, with a single submit for the whole batch.
    try context.device.uploads.?.flush();
    const width: u32 = @intCast(target.width);
    const height: u32 = @intCast(target.height);
    if (context.swap) |swap| {
        context.recreate = context.recreate or swap.extent.width != width or swap.extent.height != height;
    }
    for (0..2) |_| {
        if (context.recreate) self.discardSwapchain();
        if (context.swap == null) {
            context.swap = try Swapchain.initWithFormat(self.alloc, &context.device, width, height, context.format);
            context.recreate = false;
        }
        const status = context.swap.?.acquire(context.index) catch |err| {
            context.recreate = true;
            return err;
        };
        switch (status) {
            .retry => {
                self.requestDraw();
                return error.VulkanImageNotReady;
            },
            .resize => context.recreate = true,
            .frame => |acquired| {
                const frame_context = &context.frames[context.index];
                frame_context.command = acquired.command;
                return .{ .api = self, .terminal_renderer = terminal_renderer, .acquired = acquired, .frame_context = frame_context };
            },
        }
    }
    self.requestDraw();
    return error.VulkanSurfaceChanging;
}
