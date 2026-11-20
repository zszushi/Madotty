//! Surface-scoped command recording and fence-backed transfer.
const Context = @This();
const std = @import("std");
const com = @import("com.zig");
const d3d = @import("d3d12.zig");
const Device = @import("Device.zig");
const win = @import("../../apprt/win32/win32.zig");

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

pub const texture_state: d3d.D3D12_RESOURCE_STATES = @fromBackingInt(@intCast(0xc0));
pub const frame_count = 2;
pub const srv_count = 8192;
pub const rtv_count = 128;

const Commands = struct {
    allocator: *d3d.ID3D12CommandAllocator,
    list: *d3d.ID3D12GraphicsCommandList,
    submitted: u64 = 0,
    retained: std.ArrayList(*d3d.ID3D12Resource) = .empty,

    fn init(device: *d3d.ID3D12Device) !Commands {
        var allocator: ?*d3d.ID3D12CommandAllocator = null;
        try com.check("CreateCommandAllocator", device.CreateCommandAllocator(.DIRECT, &d3d.ID3D12CommandAllocator.IID, @ptrCast(&allocator)));
        errdefer _ = allocator.?.Release();
        var list: ?*d3d.ID3D12GraphicsCommandList = null;
        try com.check("CreateCommandList", device.CreateCommandList(0, .DIRECT, allocator.?, null, &d3d.ID3D12GraphicsCommandList.IID, @ptrCast(&list)));
        errdefer _ = list.?.Release();
        try com.check("Close initial command list", list.?.Close());
        return .{ .allocator = allocator.?, .list = list.? };
    }

    fn deinit(self: *Commands) void {
        self.releaseRetained();
        self.retained.deinit(std.heap.smp_allocator);
        _ = self.list.Release();
        _ = self.allocator.Release();
    }

    fn reset(self: *Commands) !void {
        std.debug.assert(self.submitted == 0 and self.retained.items.len == 0);
        try com.check("Reset command allocator", self.allocator.Reset());
        try com.check("Reset command list", self.list.Reset(self.allocator, null));
    }

    fn releaseRetained(self: *Commands) void {
        for (self.retained.items) |resource| _ = resource.Release();
        self.retained.clearRetainingCapacity();
    }
};

device: *const Device,
queue: *d3d.ID3D12CommandQueue,
frames: [frame_count]Commands,
transfer: Commands,
frame_index: usize = 0,
fence: *d3d.ID3D12Fence,
event: std.os.windows.HANDLE,
srv: *d3d.ID3D12DescriptorHeap,
rtv: *d3d.ID3D12DescriptorHeap,
next_fence: u64 = 0,
signaled_fence: u64 = 0,
srv_used: u32 = 0,
rtv_used: u32 = 0,
failed: bool = false,
redirection_needs_clear: bool = true,

pub fn init(device: *const Device) !Context {
    const d = device.native;
    var queue: ?*d3d.ID3D12CommandQueue = null;
    try com.check("CreateCommandQueue", d.CreateCommandQueue(&.{
        .Type = .DIRECT,
        .Priority = 0,
        .Flags = .NONE,
        .NodeMask = 0,
    }, &d3d.ID3D12CommandQueue.IID, @ptrCast(&queue)));
    errdefer _ = queue.?.Release();

    var frames: [frame_count]Commands = undefined;
    var initialized: usize = 0;
    errdefer for (frames[0..initialized]) |*frame| frame.deinit();
    for (&frames) |*frame| {
        frame.* = try .init(d);
        initialized += 1;
    }
    var transfer: Commands = try .init(d);
    errdefer transfer.deinit();

    var fence: ?*d3d.ID3D12Fence = null;
    try com.check("CreateFence", d.CreateFence(0, .NONE, &d3d.ID3D12Fence.IID, @ptrCast(&fence)));
    errdefer _ = fence.?.Release();
    const event = win.CreateEventW(null, 0, 0, null) orelse return error.DirectX12Failure;
    errdefer _ = win.CloseHandle(event);

    const srv = try makeHeap(d, .CBV_SRV_UAV, frame_count * srv_count, .SHADER_VISIBLE);
    errdefer _ = srv.Release();
    const rtv = try makeHeap(d, .RTV, frame_count * rtv_count, .NONE);
    return .{ .device = device, .queue = queue.?, .frames = frames, .transfer = transfer, .fence = fence.?, .event = event, .srv = srv, .rtv = rtv };
}

fn makeHeap(d: *d3d.ID3D12Device, kind: d3d.D3D12_DESCRIPTOR_HEAP_TYPE, count: u32, flags: d3d.D3D12_DESCRIPTOR_HEAP_FLAGS) !*d3d.ID3D12DescriptorHeap {
    var result: ?*d3d.ID3D12DescriptorHeap = null;
    try com.check("CreateDescriptorHeap", d.CreateDescriptorHeap(&.{
        .Type = kind,
        .NumDescriptors = count,
        .Flags = flags,
        .NodeMask = 0,
    }, &d3d.ID3D12DescriptorHeap.IID, @ptrCast(&result)));
    return result.?;
}

pub fn deinit(self: *Context) void {
    self.waitIdle() catch {};
    for (&self.frames) |*frame| frame.deinit();
    self.transfer.deinit();
    _ = self.rtv.Release();
    _ = self.srv.Release();
    _ = win.CloseHandle(self.event);
    _ = self.fence.Release();
    _ = self.queue.Release();
}

/// Match the generic renderer's mapped upload buffers to our command allocator
/// and descriptors. Wait before the CPU changes any data owned by this frame.
pub fn prepareFrame(self: *Context, index: usize) !void {
    try com.check("GetDeviceRemovedReason", self.device.native.GetDeviceRemovedReason());
    try self.retire(&self.frames[index]);
    self.frame_index = index;
}

pub fn beginFrame(self: *Context) !*d3d.ID3D12GraphicsCommandList {
    try self.frames[self.frame_index].reset();
    self.srv_used = 0;
    self.rtv_used = 0;
    self.failed = false;
    return self.commandList();
}

pub fn commandList(self: *const Context) *d3d.ID3D12GraphicsCommandList {
    return self.frames[self.frame_index].list;
}

/// Keep resources such as image placement buffers and swap-chain back buffers
/// alive until this frame's fence has completed.
pub fn keepResource(self: *Context, resource: *d3d.ID3D12Resource) !void {
    try keep(&self.frames[self.frame_index], resource);
}

fn keep(commands: *Commands, resource: *d3d.ID3D12Resource) !void {
    try commands.retained.append(std.heap.smp_allocator, resource);
    _ = resource.AddRef();
}

pub fn discardFrame(self: *Context) !void {
    const commands = &self.frames[self.frame_index];
    defer commands.releaseRetained();
    try com.check("Close rejected command list", commands.list.Close());
}

fn execute(self: *Context, commands: *Commands) !void {
    com.check("Close command list", commands.list.Close()) catch |err| {
        commands.releaseRetained();
        return err;
    };
    self.queue.ExecuteCommandLists(1, &.{commands.list});
    self.next_fence += 1;
    commands.submitted = self.next_fence;
}

pub fn executeFrame(self: *Context) !void {
    try self.execute(&self.frames[self.frame_index]);
}

/// Signal after Present so the fence covers all queue work for the frame.
pub fn finishFrame(self: *Context, sync: bool) !void {
    try self.signal();
    if (sync) try self.retire(&self.frames[self.frame_index]);
}

pub fn beginTransfer(self: *Context, source: *d3d.ID3D12Resource, target: *d3d.ID3D12Resource) !*d3d.ID3D12GraphicsCommandList {
    try self.retire(&self.transfer);
    try self.transfer.retained.ensureUnusedCapacity(std.heap.smp_allocator, 2);
    try self.transfer.reset();
    self.transfer.retained.appendAssumeCapacity(source);
    self.transfer.retained.appendAssumeCapacity(target);
    _ = source.AddRef();
    _ = target.AddRef();
    return self.transfer.list;
}

pub fn executeTransfer(self: *Context) !void {
    try self.execute(&self.transfer);
    try self.retire(&self.transfer);
}

fn signal(self: *Context) !void {
    if (self.signaled_fence == self.next_fence) return;
    try com.check("Signal queue", self.queue.Signal(self.fence, self.next_fence));
    self.signaled_fence = self.next_fence;
}

fn wait(self: *Context, value: u64) !void {
    if (value > self.signaled_fence) try self.signal();
    if (self.fence.GetCompletedValue() < value) {
        var use_event = com.SUCCEEDED(self.fence.SetEventOnCompletion(value, self.event));
        while (self.fence.GetCompletedValue() < value) {
            try com.check("GetDeviceRemovedReason", self.device.native.GetDeviceRemovedReason());
            // Event registration can fail under memory pressure. Continue
            // checking the fence before releasing the GPU's resources.
            if (use_event) {
                switch (win.WaitForSingleObject(self.event, 250)) {
                    win.WAIT_OBJECT_0, win.WAIT_TIMEOUT => {},
                    else => use_event = false,
                }
            } else Sleep(1);
        }
    }
    try com.check("GetDeviceRemovedReason", self.device.native.GetDeviceRemovedReason());
}

fn retire(self: *Context, commands: *Commands) !void {
    if (commands.submitted == 0) return;
    try self.wait(commands.submitted);
    commands.submitted = 0;
    commands.releaseRetained();
}

pub fn waitIdle(self: *Context) !void {
    if (self.next_fence == 0) return;
    try self.wait(self.next_fence);
    for (&self.frames) |*frame| {
        frame.submitted = 0;
        frame.releaseRetained();
    }
    self.transfer.submitted = 0;
    self.transfer.releaseRetained();
}

pub fn transition(self: *const Context, resource: *d3d.ID3D12Resource, from: d3d.D3D12_RESOURCE_STATES, to: d3d.D3D12_RESOURCE_STATES) void {
    transitionOn(self.commandList(), resource, from, to);
}

pub fn transitionOn(commands: *d3d.ID3D12GraphicsCommandList, resource: *d3d.ID3D12Resource, from: d3d.D3D12_RESOURCE_STATES, to: d3d.D3D12_RESOURCE_STATES) void {
    if (from == to) return;
    commands.ResourceBarrier(1, &.{.{
        .Type = .TRANSITION,
        .Flags = .NONE,
        .u = .{ .Transition = .{
            .pResource = resource,
            .Subresource = 0xffffffff,
            .StateBefore = from,
            .StateAfter = to,
        } },
    }});
}

pub fn createResource(device: *const Device, heap: d3d.D3D12_HEAP_TYPE, desc: *const d3d.D3D12_RESOURCE_DESC, state: d3d.D3D12_RESOURCE_STATES) !*d3d.ID3D12Resource {
    const properties: d3d.D3D12_HEAP_PROPERTIES = .{
        .Type = heap,
        .CPUPageProperty = 0,
        .MemoryPoolPreference = 0,
        .CreationNodeMask = 1,
        .VisibleNodeMask = 1,
    };
    var result: ?*d3d.ID3D12Resource = null;
    try com.check("CreateCommittedResource", device.native.CreateCommittedResource(
        &properties,
        0,
        desc,
        state,
        null,
        &d3d.ID3D12Resource.IID,
        @ptrCast(&result),
    ));
    return result.?;
}

pub fn uploadBuffer(device: *const Device, size: usize) !*d3d.ID3D12Resource {
    return createResource(device, .UPLOAD, &.{
        .Dimension = .BUFFER,
        .Alignment = 0,
        .Width = size,
        .Height = 1,
        .DepthOrArraySize = 1,
        .MipLevels = 1,
        .Format = .UNKNOWN,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Layout = .ROW_MAJOR,
        .Flags = .NONE,
    }, .GENERIC_READ);
}
