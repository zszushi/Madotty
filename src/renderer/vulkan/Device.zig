//! Win32 Vulkan loader, surface, and logical graphics device.
const Device = @This();
const std = @import("std");
pub const vk = @import("vulkan_c");

const log = std.log.scoped(.vulkan);
const loader_name = std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll");
const load_library_search_system32 = 0x00000800;
const window_instance_index = -6; // GWLP_HINSTANCE

alloc: std.mem.Allocator,
uploads: ?*@import("Uploads.zig") = null,
module: *anyopaque,
instance: vk.VkInstance,
surface: vk.VkSurfaceKHR,
physical: vk.VkPhysicalDevice,
native: vk.VkDevice,
queue: vk.VkQueue,
queue_family: u32,
properties: vk.VkPhysicalDeviceProperties,
memory: vk.VkPhysicalDeviceMemoryProperties,

get_instance_proc_addr: Proc("vkGetInstanceProcAddr"),
get_device_proc_addr: Proc("vkGetDeviceProcAddr"),
destroy_instance: Proc("vkDestroyInstance"),
destroy_surface: Proc("vkDestroySurfaceKHR"),
destroy_device: Proc("vkDestroyDevice"),

/// The caller owns the HWND and keeps it alive until after deinit.
pub fn init(alloc: std.mem.Allocator, hwnd: vk.HWND) !Device {
    if (hwnd == null) return error.VulkanWindowMissing;
    const hinstance: usize = @bitCast(if (@sizeOf(usize) == 8)
        GetWindowLongPtrW(hwnd, window_instance_index)
    else
        GetWindowLongW(hwnd, window_instance_index));
    if (hinstance == 0) return error.VulkanWindowModuleMissing;
    const module = loadLoader() orelse return error.VulkanLoaderUnavailable;
    errdefer _ = FreeLibrary(module);

    const get_instance_proc_addr: Proc("vkGetInstanceProcAddr") = @ptrCast(
        GetProcAddress(module, "vkGetInstanceProcAddr") orelse return error.VulkanLoaderUnavailable,
    );
    // The version query itself was added in Vulkan 1.1.
    const enumerate_version: Proc("vkEnumerateInstanceVersion") = @ptrCast(
        get_instance_proc_addr(null, "vkEnumerateInstanceVersion") orelse return error.VulkanVersionUnavailable,
    );
    var api_version: u32 = 0;
    try check("vkEnumerateInstanceVersion", enumerate_version(&api_version));
    if (!supportsVulkan13(api_version)) return error.VulkanVersionUnavailable;

    const create_instance = try resolve("vkCreateInstance", get_instance_proc_addr(null, "vkCreateInstance"));
    // The loader exports core functions. Keep its destructor available even
    // if resolving an instance-level entry point fails after creation.
    const destroy_instance: Proc("vkDestroyInstance") = @ptrCast(
        GetProcAddress(module, "vkDestroyInstance") orelse return error.VulkanLoaderUnavailable,
    );
    const instance_extensions = [_][*c]const u8{ "VK_KHR_surface", "VK_KHR_win32_surface" };
    const app_info: vk.VkApplicationInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Madotty",
        .apiVersion = vk.VK_API_VERSION_1_3,
    };
    const instance_info: vk.VkInstanceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = instance_extensions.len,
        .ppEnabledExtensionNames = &instance_extensions,
    };
    var instance: vk.VkInstance = null;
    try check("vkCreateInstance", create_instance(&instance_info, null, &instance));
    errdefer destroy_instance(instance, null);

    const dispatch: InstanceDispatch = try .load(instance, get_instance_proc_addr);
    const surface_info: vk.VkWin32SurfaceCreateInfoKHR = .{
        .sType = vk.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
        .hinstance = @ptrFromInt(hinstance),
        .hwnd = hwnd,
    };
    var surface = std.mem.zeroes(vk.VkSurfaceKHR);
    try check("vkCreateWin32SurfaceKHR", dispatch.create_surface(instance, &surface_info, null, &surface));
    errdefer dispatch.destroy_surface(instance, surface, null);

    const adapter = try selectAdapter(alloc, instance, surface, &dispatch);
    const queue_priority: f32 = 1;
    const queue_info: vk.VkDeviceQueueCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = adapter.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };
    const device_extensions = [_][*c]const u8{"VK_KHR_swapchain"};
    const features: vk.VkPhysicalDeviceVulkan13Features = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .synchronization2 = vk.VK_TRUE,
        .dynamicRendering = vk.VK_TRUE,
    };
    const device_info: vk.VkDeviceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &features,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = device_extensions.len,
        .ppEnabledExtensionNames = &device_extensions,
    };
    var native: vk.VkDevice = null;
    try check("vkCreateDevice", dispatch.create_device(adapter.handle, &device_info, null, &native));
    errdefer dispatch.destroy_device(native, null);

    const destroy_device = try resolve("vkDestroyDevice", dispatch.get_device_proc_addr(native, "vkDestroyDevice"));
    const get_queue = try resolve("vkGetDeviceQueue", dispatch.get_device_proc_addr(native, "vkGetDeviceQueue"));
    var queue: vk.VkQueue = null;
    get_queue(native, adapter.queue_family, 0, &queue);
    if (queue == null) return error.VulkanQueueUnavailable;

    var memory: vk.VkPhysicalDeviceMemoryProperties = undefined;
    dispatch.get_memory_properties(adapter.handle, &memory);
    log.info("selected Vulkan adapter {s}, graphics/present queue family {d}", .{
        std.mem.sliceTo(&adapter.properties.deviceName, 0), adapter.queue_family,
    });

    return .{
        .alloc = alloc,
        .module = module,
        .instance = instance,
        .surface = surface,
        .physical = adapter.handle,
        .native = native,
        .queue = queue,
        .queue_family = adapter.queue_family,
        .properties = adapter.properties,
        .memory = memory,
        .get_instance_proc_addr = get_instance_proc_addr,
        .get_device_proc_addr = dispatch.get_device_proc_addr,
        .destroy_instance = destroy_instance,
        .destroy_surface = dispatch.destroy_surface,
        .destroy_device = destroy_device,
    };
}

/// The caller drains the queue and destroys resources and swapchains first.
pub fn deinit(self: *Device) void {
    if (self.uploads) |uploads| uploads.deinit();
    self.destroy_device(self.native, null);
    self.destroy_surface(self.instance, self.surface, null);
    self.destroy_instance(self.instance, null);
    _ = FreeLibrary(self.module);
    self.* = undefined;
}

pub fn instanceProc(self: *const Device, comptime name: [:0]const u8) error{VulkanEntryPointMissing}!Proc(name) {
    return resolve(name, self.get_instance_proc_addr(self.instance, name));
}

pub fn deviceProc(self: *const Device, comptime name: [:0]const u8) error{VulkanEntryPointMissing}!Proc(name) {
    return resolve(name, self.get_device_proc_addr(self.native, name));
}

pub fn memoryType(self: *const Device, bits: u32, flags: vk.VkMemoryPropertyFlags) error{VulkanMemoryTypeUnavailable}!u32 {
    for (self.memory.memoryTypes[0..self.memory.memoryTypeCount], 0..) |property, i| {
        const allowed = bits & (@as(u32, 1) << @as(u5, @intCast(i))) != 0;
        if (allowed and property.propertyFlags & flags == flags) return @intCast(i);
    }
    return error.VulkanMemoryTypeUnavailable;
}

/// Callers handle expected WSI statuses (for example VK_SUBOPTIMAL_KHR)
/// before passing the result here.
pub fn check(operation: []const u8, result: vk.VkResult) !void {
    if (result == vk.VK_SUCCESS) return;
    log.warn("{s} returned VkResult={d}", .{ operation, result });
    return switch (result) {
        vk.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfMemory,
        vk.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.VulkanOutOfDeviceMemory,
        vk.VK_ERROR_DEVICE_LOST => error.VulkanDeviceLost,
        vk.VK_ERROR_SURFACE_LOST_KHR => error.VulkanSurfaceLost,
        vk.VK_ERROR_OUT_OF_DATE_KHR => error.VulkanSwapchainOutOfDate,
        vk.VK_ERROR_EXTENSION_NOT_PRESENT => error.VulkanExtensionUnavailable,
        vk.VK_ERROR_INCOMPATIBLE_DRIVER => error.VulkanVersionUnavailable,
        else => error.VulkanCallFailed,
    };
}

pub fn Proc(comptime name: [:0]const u8) type {
    return @typeInfo(@field(vk, "PFN_" ++ name)).optional.child;
}

fn resolve(comptime name: [:0]const u8, value: vk.PFN_vkVoidFunction) error{VulkanEntryPointMissing}!Proc(name) {
    if (value) |pointer| return @ptrCast(pointer);
    log.warn("Vulkan entry point {s} is unavailable", .{name});
    return error.VulkanEntryPointMissing;
}

fn supportsVulkan13(version: u32) bool {
    return version >> 29 == 0 and version >= vk.VK_API_VERSION_1_3;
}

fn loadLoader() ?*anyopaque {
    var path: [260]u16 = undefined;
    const directory_len: usize = GetSystemDirectoryW(&path, path.len);
    if (directory_len == 0 or directory_len > path.len - loader_name.len - 2) return null;

    path[directory_len] = '\\';
    const end = directory_len + 1 + loader_name.len;
    @memcpy(path[directory_len + 1 .. end], loader_name);
    path[end] = 0;
    return LoadLibraryExW(path[0..end :0], null, load_library_search_system32);
}

const InstanceDispatch = struct {
    create_surface: Proc("vkCreateWin32SurfaceKHR"),
    destroy_surface: Proc("vkDestroySurfaceKHR"),
    enumerate_devices: Proc("vkEnumeratePhysicalDevices"),
    get_properties: Proc("vkGetPhysicalDeviceProperties"),
    get_memory_properties: Proc("vkGetPhysicalDeviceMemoryProperties"),
    get_features: Proc("vkGetPhysicalDeviceFeatures2"),
    get_queues: Proc("vkGetPhysicalDeviceQueueFamilyProperties"),
    surface_support: Proc("vkGetPhysicalDeviceSurfaceSupportKHR"),
    enumerate_extensions: Proc("vkEnumerateDeviceExtensionProperties"),
    create_device: Proc("vkCreateDevice"),
    destroy_device: Proc("vkDestroyDevice"),
    get_device_proc_addr: Proc("vkGetDeviceProcAddr"),

    fn load(instance: vk.VkInstance, get: Proc("vkGetInstanceProcAddr")) !InstanceDispatch {
        return .{
            .create_surface = try resolve("vkCreateWin32SurfaceKHR", get(instance, "vkCreateWin32SurfaceKHR")),
            .destroy_surface = try resolve("vkDestroySurfaceKHR", get(instance, "vkDestroySurfaceKHR")),
            .enumerate_devices = try resolve("vkEnumeratePhysicalDevices", get(instance, "vkEnumeratePhysicalDevices")),
            .get_properties = try resolve("vkGetPhysicalDeviceProperties", get(instance, "vkGetPhysicalDeviceProperties")),
            .get_memory_properties = try resolve("vkGetPhysicalDeviceMemoryProperties", get(instance, "vkGetPhysicalDeviceMemoryProperties")),
            .get_features = try resolve("vkGetPhysicalDeviceFeatures2", get(instance, "vkGetPhysicalDeviceFeatures2")),
            .get_queues = try resolve("vkGetPhysicalDeviceQueueFamilyProperties", get(instance, "vkGetPhysicalDeviceQueueFamilyProperties")),
            .surface_support = try resolve("vkGetPhysicalDeviceSurfaceSupportKHR", get(instance, "vkGetPhysicalDeviceSurfaceSupportKHR")),
            .enumerate_extensions = try resolve("vkEnumerateDeviceExtensionProperties", get(instance, "vkEnumerateDeviceExtensionProperties")),
            .create_device = try resolve("vkCreateDevice", get(instance, "vkCreateDevice")),
            .destroy_device = try resolve("vkDestroyDevice", get(instance, "vkDestroyDevice")),
            .get_device_proc_addr = try resolve("vkGetDeviceProcAddr", get(instance, "vkGetDeviceProcAddr")),
        };
    }
};

const Adapter = struct {
    handle: vk.VkPhysicalDevice,
    properties: vk.VkPhysicalDeviceProperties,
    queue_family: u32,
};

fn selectAdapter(
    alloc: std.mem.Allocator,
    instance: vk.VkInstance,
    surface: vk.VkSurfaceKHR,
    dispatch: *const InstanceDispatch,
) !Adapter {
    var adapters = try enumerate(
        vk.VkPhysicalDevice,
        alloc,
        "vkEnumeratePhysicalDevices",
        dispatch.enumerate_devices,
        .{instance},
    );
    defer adapters.deinit(alloc);

    var selected: ?Adapter = null;
    var selected_rank: u8 = 0;
    for (adapters.items) |physical| {
        var properties: vk.VkPhysicalDeviceProperties = undefined;
        dispatch.get_properties(physical, &properties);
        const rank: u8 = switch (properties.deviceType) {
            vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 2,
            vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 1,
            else => continue,
        };
        if (rank <= selected_rank or !supportsVulkan13(properties.apiVersion)) continue;

        var features13: vk.VkPhysicalDeviceVulkan13Features = .{ .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
        var features: vk.VkPhysicalDeviceFeatures2 = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &features13,
        };
        dispatch.get_features(physical, &features);
        if (features13.synchronization2 == vk.VK_FALSE or features13.dynamicRendering == vk.VK_FALSE) continue;
        if (!try supportsSwapchain(alloc, physical, dispatch)) continue;
        const queue_family = try presentQueueFamily(alloc, physical, surface, dispatch) orelse continue;

        selected = .{ .handle = physical, .properties = properties, .queue_family = queue_family };
        selected_rank = rank;
    }
    return selected orelse error.VulkanHardwareAdapterUnavailable;
}

fn supportsSwapchain(alloc: std.mem.Allocator, physical: vk.VkPhysicalDevice, dispatch: *const InstanceDispatch) !bool {
    var extensions = try enumerate(
        vk.VkExtensionProperties,
        alloc,
        "vkEnumerateDeviceExtensionProperties",
        dispatch.enumerate_extensions,
        .{ physical, null },
    );
    defer extensions.deinit(alloc);
    for (extensions.items) |*extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extensionName, 0), "VK_KHR_swapchain")) return true;
    }
    return false;
}

fn presentQueueFamily(
    alloc: std.mem.Allocator,
    physical: vk.VkPhysicalDevice,
    surface: vk.VkSurfaceKHR,
    dispatch: *const InstanceDispatch,
) !?u32 {
    var count: u32 = 0;
    dispatch.get_queues(physical, &count, null);
    if (count == 0) return null;
    const queues = try alloc.alloc(vk.VkQueueFamilyProperties, count);
    defer alloc.free(queues);
    dispatch.get_queues(physical, &count, queues.ptr);
    for (queues[0..count], 0..) |family, i| {
        if (family.queueCount == 0 or family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT == 0) continue;
        const index: u32 = @intCast(i);
        var supported: vk.VkBool32 = vk.VK_FALSE;
        try check("vkGetPhysicalDeviceSurfaceSupportKHR", dispatch.surface_support(physical, index, surface, &supported));
        if (supported != vk.VK_FALSE) return index;
    }
    return null;
}

fn enumerate(
    comptime T: type,
    alloc: std.mem.Allocator,
    operation: []const u8,
    function: anytype,
    args: anytype,
) !std.ArrayList(T) {
    var values: std.ArrayList(T) = .empty;
    errdefer values.deinit(alloc);
    // Hot-plugging can make a count-based Vulkan enumeration incomplete.
    for (0..3) |_| {
        var count: u32 = 0;
        try check(operation, @call(.auto, function, args ++ .{ &count, null }));
        if (count == 0) return values;
        try values.ensureTotalCapacityPrecise(alloc, count);
        const result = @call(.auto, function, args ++ .{ &count, values.allocatedSlice().ptr });
        if (result == vk.VK_INCOMPLETE) continue;
        try check(operation, result);
        values.items = values.allocatedSlice()[0..count];
        return values;
    }
    return error.VulkanEnumerationChanged;
}

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetSystemDirectoryW(buffer: [*]u16, capacity: u32) callconv(.winapi) u32;
extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
extern "user32" fn GetWindowLongPtrW(hwnd: vk.HWND, index: c_int) callconv(.winapi) isize;
extern "user32" fn GetWindowLongW(hwnd: vk.HWND, index: c_int) callconv(.winapi) i32;
