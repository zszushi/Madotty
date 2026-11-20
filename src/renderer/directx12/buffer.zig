//! A persistently mapped upload buffer for renderer inputs.
const std = @import("std");
const Device = @import("Device.zig");
const Context = @import("Context.zig");
const com = @import("com.zig");
const d3d = @import("d3d12.zig");

pub const Options = struct { device: *const Device };

pub const RawBuffer = struct {
    resource: *d3d.ID3D12Resource,
    size: u32,
    stride: u32,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        opts: Options,
        buffer: RawBuffer,
        data: [*]u8,
        capacity: usize,

        pub fn init(opts: Options, count: usize) !Self {
            const size = std.math.mul(usize, @sizeOf(T), count) catch return error.BufferTooLarge;
            const minimum = @max(size, 256);
            if (minimum > std.math.maxInt(u32)) return error.BufferTooLarge;
            const resource = try Context.uploadBuffer(opts.device, minimum);
            errdefer _ = resource.Release();
            var data: ?*anyopaque = null;
            try com.check("Map upload buffer", resource.Map(0, &.{ .Begin = 0, .End = 0 }, &data));
            return .{
                .opts = opts,
                .buffer = .{ .resource = resource, .size = @intCast(size), .stride = @sizeOf(T) },
                .data = @ptrCast(data.?),
                .capacity = minimum,
            };
        }

        pub fn initFill(opts: Options, values: []const T) !Self {
            var result = try init(opts, values.len);
            try result.sync(values);
            return result;
        }

        pub fn deinit(self: Self) void {
            self.buffer.resource.Unmap(0, null);
            _ = self.buffer.resource.Release();
        }

        fn resize(self: *Self, count: usize) !void {
            const size = std.math.mul(usize, @sizeOf(T), count) catch return error.BufferTooLarge;
            if (size > self.capacity) {
                const expanded = try init(self.opts, count);
                self.deinit();
                self.* = expanded;
            }
            self.buffer.size = @intCast(size);
        }

        pub fn sync(self: *Self, values: []const T) !void {
            try self.resize(values.len);
            @memcpy(self.data[0..self.buffer.size], std.mem.sliceAsBytes(values));
        }

        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var count: usize = 0;
            for (lists) |list| count += list.items.len;
            try self.resize(count);
            var offset: usize = 0;
            for (lists) |list| {
                const bytes = std.mem.sliceAsBytes(list.items);
                @memcpy(self.data[offset..][0..bytes.len], bytes);
                offset += bytes.len;
            }
            return count;
        }
    };
}
