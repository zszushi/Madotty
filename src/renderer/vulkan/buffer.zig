//! Persistently mapped Vulkan inputs. Each in-flight frame owns its writes.
const std = @import("std");
const Device = @import("Device.zig");
const vk = Device.vk;
const Proc = Device.Proc;

pub const Options = struct { device: *const Device };

pub const RawBuffer = struct {
    native: vk.VkBuffer,
    size: u32,
    stride: u32,
    allocation: *Allocation,

    /// Retain a recorded command's resource until the frame fence completes.
    pub fn retain(self: RawBuffer) void {
        _ = self.allocation.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: RawBuffer) void {
        if (self.allocation.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = self.allocation.mapped.device.alloc;
        self.allocation.mapped.deinit();
        alloc.destroy(self.allocation);
    }
};

const Allocation = struct {
    refs: std.atomic.Value(u32) = .init(1),
    mapped: Mapped,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: RawBuffer,

        pub fn init(opts: Options, count: usize) !Self {
            const size = try byteSize(count);
            const minimum = @max(size, 256);
            const capacity = std.math.ceilPowerOfTwo(usize, minimum) catch minimum;
            const allocation = try opts.device.alloc.create(Allocation);
            errdefer opts.device.alloc.destroy(allocation);
            allocation.* = .{
                .mapped = try .init(opts.device, capacity, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                    vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT),
            };
            return .{ .buffer = .{
                .native = allocation.mapped.native,
                .size = size,
                .stride = @sizeOf(T),
                .allocation = allocation,
            } };
        }

        pub fn initFill(opts: Options, values: []const T) !Self {
            var self = try init(opts, values.len);
            errdefer self.deinit();
            try self.sync(values);
            return self;
        }

        pub fn deinit(self: Self) void {
            self.buffer.release();
        }

        fn byteSize(count: usize) error{BufferTooLarge}!u32 {
            const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.BufferTooLarge;
            return std.math.cast(u32, bytes) orelse error.BufferTooLarge;
        }

        fn resize(self: *Self, count: usize) ![]u8 {
            const size = try byteSize(count);
            if (size > self.buffer.allocation.mapped.data.len) {
                const grown = try init(.{ .device = self.buffer.allocation.mapped.device }, count);
                self.deinit();
                self.* = grown;
            }
            self.buffer.size = size;
            return self.buffer.allocation.mapped.data[0..size];
        }

        pub fn sync(self: *Self, values: []const T) !void {
            const bytes = try self.resize(values.len);
            @memcpy(bytes, std.mem.sliceAsBytes(values));
        }

        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var count: usize = 0;
            for (lists) |list| {
                count = std.math.add(usize, count, list.items.len) catch return error.BufferTooLarge;
            }
            var dst = try self.resize(count);
            for (lists) |list| {
                const bytes = std.mem.sliceAsBytes(list.items);
                @memcpy(dst[0..bytes.len], bytes);
                dst = dst[bytes.len..];
            }
            return count;
        }
    };
}

/// Host-visible coherent memory shared by frame inputs and upload staging.
/// Its caller controls access with the appropriate frame or transfer fence.
pub const Mapped = struct {
    device: *const Device,
    destroy_buffer: Proc("vkDestroyBuffer"),
    free_memory: Proc("vkFreeMemory"),
    unmap_memory: Proc("vkUnmapMemory"),
    native: vk.VkBuffer = null,
    memory: vk.VkDeviceMemory = null,
    data: []u8 = &.{},

    pub fn init(device: *const Device, size: usize, usage: vk.VkBufferUsageFlags) !Mapped {
        std.debug.assert(size != 0);
        var self: Mapped = .{
            .device = device,
            .destroy_buffer = try device.deviceProc("vkDestroyBuffer"),
            .free_memory = try device.deviceProc("vkFreeMemory"),
            .unmap_memory = try device.deviceProc("vkUnmapMemory"),
        };
        errdefer self.deinit();

        const create_buffer = try device.deviceProc("vkCreateBuffer");
        try Device.check("vkCreateBuffer", create_buffer(device.native, &.{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        }, null, &self.native));

        const get_requirements = try device.deviceProc("vkGetBufferMemoryRequirements");
        var requirements: vk.VkMemoryRequirements = undefined;
        get_requirements(device.native, self.native, &requirements);
        const memory_type = try device.memoryType(requirements.memoryTypeBits, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const allocate_memory = try device.deviceProc("vkAllocateMemory");
        try Device.check("vkAllocateMemory", allocate_memory(device.native, &.{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        }, null, &self.memory));

        const bind_memory = try device.deviceProc("vkBindBufferMemory");
        try Device.check("vkBindBufferMemory", bind_memory(device.native, self.native, self.memory, 0));
        const map_memory = try device.deviceProc("vkMapMemory");
        var address: ?*anyopaque = null;
        try Device.check("vkMapMemory", map_memory(device.native, self.memory, 0, size, 0, &address));
        self.data = @as([*]u8, @ptrCast(address.?))[0..size];
        return self;
    }

    pub fn deinit(self: Mapped) void {
        const device = self.device.native;
        if (self.data.len != 0) self.unmap_memory(device, self.memory);
        if (self.native != null) self.destroy_buffer(device, self.native, null);
        if (self.memory != null) self.free_memory(device, self.memory, null);
    }
};
