//! Hardware verification of D3D12 frame-slot and temporary resource lifetime.
const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const Device = @import("Device.zig");
const com = @import("com.zig");
const d3d = @import("d3d12.zig");
const win = @import("../../apprt/win32/win32.zig");

const GateWatchdog = struct {
    fence: *d3d.ID3D12Fence,
    completed: std.os.windows.HANDLE,
    timed_out: std.atomic.Value(bool) = .init(false),

    fn run(self: *GateWatchdog) void {
        if (win.WaitForSingleObject(self.completed, 10_000) != win.WAIT_OBJECT_0) {
            self.timed_out.store(true, .release);
            // Unstick the test if submission accidentally starts waiting
            // for the queued work before control returns to the test.
            _ = self.fence.Signal(1);
        }
    }
};

test "d3d12 frame queue holds two pending submissions and retires resources" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const device = Device.init(std.testing.allocator, .{}) catch |err| switch (err) {
        error.ShaderModel60Unavailable => {
            std.log.warn("D3D12 queue gate test requires Shader Model 6.0", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer device.deinit(std.testing.allocator);

    var gate_storage: ?*d3d.ID3D12Fence = null;
    try com.check("Create queue gate fence", device.native.CreateFence(
        0,
        .NONE,
        &d3d.ID3D12Fence.IID,
        @ptrCast(&gate_storage),
    ));
    const gate = gate_storage.?;
    defer _ = gate.Release();

    const blocks = [_][8]u8{
        .{ 0x12, 0x80, 0x45, 0x00, 0x51, 0xff, 0x02, 0x76 },
        .{ 0x98, 0x02, 0xc0, 0x80, 0x39, 0x1a, 0x44, 0xff },
    };
    const readback = try Context.createResource(device, .READBACK, &.{
        .Dimension = .BUFFER,
        .Alignment = 0,
        .Width = @sizeOf(@TypeOf(blocks)),
        .Height = 1,
        .DepthOrArraySize = 1,
        .MipLevels = 1,
        .Format = .UNKNOWN,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Layout = .ROW_MAJOR,
        .Flags = .NONE,
    }, .COPY_DEST);
    defer _ = readback.Release();

    var context = try Context.init(device);
    defer context.deinit();

    const completed = win.CreateEventW(null, 1, 0, null) orelse return error.DirectX12Failure;
    defer _ = win.CloseHandle(completed);
    var watchdog: GateWatchdog = .{ .fence = gate, .completed = completed };
    const watchdog_thread = try std.Thread.spawn(.{}, GateWatchdog.run, .{&watchdog});
    defer {
        _ = gate.Signal(1);
        _ = win.SetEvent(completed);
        watchdog_thread.join();
    }

    try com.check("Gate the D3D12 queue", context.queue.Wait(gate, 1));
    for (blocks, 0..) |bytes, index| {
        try recordCopy(&context, index, readback, index * bytes.len, &bytes);
        try context.executeFrame();
        try context.finishFrame(false);
    }

    try std.testing.expect(!watchdog.timed_out.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), context.next_fence);
    try std.testing.expectEqual(context.next_fence, context.signaled_fence);
    const fence_before_release = context.fence.GetCompletedValue();
    for (context.frames[0..blocks.len], 1..) |frame, submitted| {
        try std.testing.expectEqual(@as(u64, @intCast(submitted)), frame.submitted);
        try std.testing.expect(fence_before_release < frame.submitted);
        try std.testing.expectEqual(@as(usize, 1), frame.retained.items.len);
    }

    try com.check("Release the D3D12 queue gate", gate.Signal(1));
    _ = win.SetEvent(completed);
    try context.prepareFrame(0);
    try std.testing.expectEqual(@as(u64, 0), context.frames[0].submitted);
    try std.testing.expectEqual(@as(usize, 0), context.frames[0].retained.items.len);
    try context.waitIdle();
    for (context.frames) |frame| {
        try std.testing.expectEqual(@as(u64, 0), frame.submitted);
        try std.testing.expectEqual(@as(usize, 0), frame.retained.items.len);
    }

    var mapped: ?*anyopaque = null;
    const size = @sizeOf(@TypeOf(blocks));
    try com.check("Map queue gate readback", readback.Map(0, &.{ .Begin = 0, .End = size }, &mapped));
    defer readback.Unmap(0, &.{ .Begin = 0, .End = 0 });
    const bytes: [*]const u8 = @ptrCast(mapped.?);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&blocks), bytes[0..size]);
}

fn recordCopy(
    context: *Context,
    slot: usize,
    readback: *d3d.ID3D12Resource,
    offset: usize,
    bytes: []const u8,
) !void {
    try context.prepareFrame(slot);
    const list = try context.beginFrame();
    errdefer context.discardFrame() catch {};

    const upload = try Context.uploadBuffer(context.device, bytes.len);
    defer _ = upload.Release();

    var mapped: ?*anyopaque = null;
    try com.check("Map queue gate upload", upload.Map(0, &.{ .Begin = 0, .End = 0 }, &mapped));
    const dst: [*]u8 = @ptrCast(mapped.?);
    @memcpy(dst[0..bytes.len], bytes);
    upload.Unmap(0, &.{ .Begin = 0, .End = bytes.len });

    try context.keepResource(upload);
    list.CopyBufferRegion(readback, offset, upload, 0, bytes.len);
    // The caller submits after this function releases the upload's owner.
}
