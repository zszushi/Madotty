//! Standalone Win32 presentation test for the shared Vulkan renderer pieces.
const std = @import("std");
const w32 = @import("apprt/win32/win32.zig");
const Device = @import("renderer/vulkan/Device.zig");
const Swapchain = @import("renderer/vulkan/Swapchain.zig");
const Pipeline = @import("renderer/vulkan/Pipeline.zig");
const RenderPass = @import("renderer/vulkan/RenderPass.zig");
const shaders = @import("renderer/vulkan/shaders.zig");
const UniformBuffer = @import("renderer/vulkan/buffer.zig").Buffer(shaders.Uniforms);
const vk = Device.vk;
const program = shaders.Shaders.program(.bg_color);

const phase_message = w32.WM_APP + 1;
const redraw_message = w32.WM_APP + 2;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MadottyVulkanSmoke");
const title = std.unicode.utf8ToUtf16LeStringLiteral("Madotty Vulkan Smoke");
const per_monitor_v2: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

extern "user32" fn SetProcessDpiAwarenessContext(*anyopaque) callconv(.winapi) i32;

pub fn main(init: std.process.Init) !void {
    _ = SetProcessDpiAwarenessContext(per_monitor_v2);
    const module = w32.GetModuleHandleW(null) orelse return error.WindowCreationFailed;
    if (w32.RegisterClassExW(&.{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = module,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    }) == 0) return error.WindowCreationFailed;
    defer _ = w32.UnregisterClassW(class_name, module);
    const hwnd = w32.CreateWindowExW(
        0,
        class_name,
        title,
        w32.WS_OVERLAPPEDWINDOW,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        640,
        360,
        null,
        null,
        module,
        null,
    ) orelse return error.WindowCreationFailed;
    defer _ = w32.DestroyWindow(hwnd);

    var device = try Device.init(init.gpa, @ptrFromInt(@intFromPtr(hwnd)));
    defer device.deinit();
    std.debug.print("vulkan-smoke adapter {s}\n", .{std.mem.sliceTo(&device.properties.deviceName, 0)});
    var app = try App.init(init.gpa, hwnd, &device);
    defer app.deinit();
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&app)));
    defer _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    try app.redraw();

    var message: w32.MSG = undefined;
    while (true) {
        switch (w32.GetMessageW(&message, null, 0, 0)) {
            -1 => return error.MessageLoopFailed,
            0 => return,
            else => {
                _ = w32.TranslateMessage(&message);
                _ = w32.DispatchMessageW(&message);
            },
        }
        if (app.dirty) try app.redraw();
    }
}

const App = struct {
    alloc: std.mem.Allocator,
    hwnd: w32.HWND,
    device: *const Device,
    swap: ?Swapchain = null,
    pipeline: ?Pipeline = null,
    frames: [Swapchain.frame_count]Slot,
    next_frame: usize = 0,
    generation: usize = 0,
    phase: u1 = 0,
    dirty: bool = true,
    resized: bool = true,

    const Slot = struct {
        pass: RenderPass.FrameContext,
        uniforms: UniformBuffer,

        fn init(alloc: std.mem.Allocator, device: *const Device) !Slot {
            var pass = try RenderPass.FrameContext.init(alloc, device);
            errdefer pass.deinit();
            return .{ .pass = pass, .uniforms = try .init(.{ .device = device }, 1) };
        }

        fn deinit(self: *Slot) void {
            self.pass.deinit();
            self.uniforms.deinit();
        }
    };

    fn init(alloc: std.mem.Allocator, hwnd: w32.HWND, device: *const Device) !App {
        var app: App = .{ .alloc = alloc, .hwnd = hwnd, .device = device, .frames = undefined };
        var initialized: usize = 0;
        errdefer for (app.frames[0..initialized]) |*frame| frame.deinit();
        for (&app.frames) |*frame| {
            frame.* = try .init(alloc, device);
            initialized += 1;
        }
        return app;
    }

    fn deinit(self: *App) void {
        if (self.swap) |*swap| swap.deinit();
        if (self.pipeline) |pipeline| pipeline.deinit();
        for (&self.frames) |*frame| frame.deinit();
    }

    fn redraw(self: *App) !void {
        self.dirty = false;
        if (self.resized) {
            var rect: w32.RECT = undefined;
            if (w32.GetClientRect(self.hwnd, &rect) == 0) return error.WindowGeometryUnavailable;
            const width: u32 = @intCast(@max(0, rect.right - rect.left));
            const height: u32 = @intCast(@max(0, rect.bottom - rect.top));
            if (width == 0 or height == 0) return;

            const old_format = if (self.swap) |*swap| format: {
                const format = swap.format;
                swap.deinit();
                break :format format;
            } else vk.VK_FORMAT_UNDEFINED;
            self.swap = null;
            self.swap = Swapchain.init(self.alloc, self.device, width, height) catch |err| switch (err) {
                error.SurfaceNotDrawable => return,
                else => return err,
            };
            const swap = &self.swap.?;
            if (self.pipeline == null or swap.format != old_format) {
                if (self.pipeline) |pipeline| pipeline.deinit();
                self.pipeline = null;
                self.pipeline = try .init(self.device, swap.format, program);
            }
            self.resized = false;
            self.generation += 1;
            std.debug.print("vulkan-smoke swapchain {d}x{d} generation={d}\n", .{
                swap.extent.width, swap.extent.height, self.generation,
            });
        }

        const swap = if (self.swap) |*swap| swap else return;
        const state = try self.draw(swap);
        switch (state) {
            .presented => {},
            .resize => {
                self.resized = true;
                _ = w32.PostMessageW(self.hwnd, redraw_message, 0, 0);
            },
            .retry => _ = w32.PostMessageW(self.hwnd, redraw_message, 0, 0),
        }
    }

    fn draw(self: *App, swap: *Swapchain) !Swapchain.Status {
        const index = self.next_frame;
        const slot = &self.frames[index];
        try swap.waitSlot(index);
        try slot.pass.reset();
        var uniforms = std.mem.zeroes(shaders.Uniforms);
        uniforms.bg_color = switch (self.phase) {
            0 => .{ 35, 109, 175, 255 },
            1 => .{ 198, 69, 36, 255 },
        };
        uniforms.bools.use_linear_blending = swap.format == vk.VK_FORMAT_B8G8R8A8_SRGB or
            swap.format == vk.VK_FORMAT_R8G8B8A8_SRGB;
        try slot.uniforms.sync(&.{uniforms});

        const frame = switch (try swap.acquire(index)) {
            .frame => |frame| frame,
            .resize => return .resize,
            .retry => return .retry,
        };
        slot.pass.command = frame.command;
        var pass = RenderPass.begin(&slot.pass, &.{.{
            .target = .{ .target = .{ .width = swap.extent.width, .height = swap.extent.height } },
            .clear_color = .{ 0, 0, 0, 1 },
        }}, .{
            .native = frame.native,
            .view = frame.view,
            .width = swap.extent.width,
            .height = swap.extent.height,
            .format = swap.format,
        });
        pass.step(.{
            .pipeline = self.pipeline.?,
            .uniforms = slot.uniforms.buffer,
            .draw = .{ .type = .triangle, .vertex_count = program.vertex_count },
        });
        pass.complete();
        self.next_frame = (index + 1) % Swapchain.frame_count;
        const result = try swap.submit(frame);
        if (slot.pass.failure) |failure| return failure;
        return result;
    }
};

fn wndProc(hwnd: w32.HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const raw = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const app: ?*App = @ptrFromInt(@as(usize, @bitCast(raw)));
    if (app) |state| switch (message) {
        w32.WM_SIZE => {
            const size: usize = @bitCast(lparam);
            if (state.swap) |*swap| {
                if (swap.extent.width == (size & 0xffff) and
                    swap.extent.height == ((size >> 16) & 0xffff)) return 0;
            }
            state.resized = true;
            _ = w32.PostMessageW(hwnd, redraw_message, 0, 0);
            return 0;
        },
        w32.WM_PAINT => {
            _ = w32.ValidateRect(hwnd, null);
            state.dirty = true;
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_CLOSE => {
            w32.PostQuitMessage(0);
            return 0;
        },
        redraw_message => {
            state.dirty = true;
            return 0;
        },
        phase_message => {
            if (wparam <= 1) {
                state.phase = @intCast(wparam);
                _ = w32.PostMessageW(hwnd, redraw_message, 0, 0);
            }
            return 0;
        },
        else => {},
    };
    return w32.DefWindowProcW(hwnd, message, wparam, lparam);
}
