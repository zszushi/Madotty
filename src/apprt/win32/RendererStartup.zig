//! Select the Windows graphics backend before creating a window or starting a command.
const std = @import("std");
const build_config = @import("../../build_config.zig");
const CoreApp = @import("../../App.zig");
const Config = @import("../../config.zig").Config;
const Device = @import("../../renderer.zig").Device;
const global = @import("../../global.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);
const handoff_variable = "MADOTTY_RENDERER_HANDOFF";
const startup_timeout_ms = 15_000;
pub const Backend = enum { opengl, d3d12, vulkan };
pub const active: Backend = switch (build_config.renderer) {
    .d3d12 => .d3d12,
    .vulkan => .vulkan,
    else => .opengl,
};

extern "kernel32" fn WaitForMultipleObjects(u32, [*]const w32.HANDLE, i32, u32) callconv(.winapi) u32;
extern "kernel32" fn SetEnvironmentVariableW([*:0]const u16, ?[*:0]const u16) callconv(.winapi) i32;

pub const Status = struct {
    pub const Problem = enum { missing, startup_failed };
    pub const Snapshot = struct {
        preference: Config.WindowsRenderer,
        active: Backend,
        d3d12_available: bool,
        vulkan_available: bool,
        problem: ?Problem,
    };

    d3d12_available: bool = false,
    vulkan_available: bool = false,
    failure: ?struct { preference: Config.WindowsRenderer, problem: Problem } = null,
    selectable: bool = false,
    handoff: ?Handoff = null,

    pub fn snapshot(self: Status, preference: Config.WindowsRenderer) ?Snapshot {
        if (!self.selectable) return null;
        return .{
            .preference = preference,
            .active = active,
            .d3d12_available = self.d3d12_available,
            .vulkan_available = self.vulkan_available,
            .problem = if (self.failure) |failure|
                if (preference == failure.preference) failure.problem else null
            else
                null,
        };
    }

    pub fn deinit(self: *Status) void {
        if (self.handoff) |handoff| handoff.close();
        self.handoff = null;
    }

    pub fn commit(self: *Status) !void {
        const handoff = self.handoff orelse return;
        defer self.deinit();
        if (w32.SetEvent(handoff.ready) == 0 or
            w32.WaitForSingleObject(handoff.proceed, startup_timeout_ms) != w32.WAIT_OBJECT_0)
            return error.RendererHandoffCancelled;
    }
};

pub fn select(app: *CoreApp, preference: Config.WindowsRenderer) !Status {
    const alloc = app.alloc;
    const marker = global.environ().getAlloc(alloc, handoff_variable) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    defer if (marker) |value| alloc.free(value);

    var result: Status = .{ .selectable = true };
    errdefer result.deinit();
    if (marker) |value| {
        // Reject mismatched binaries before they can dispatch or start a command.
        if (comptime active == .opengl) return error.UnexpectedRendererHandoff;
        result.handoff = try Handoff.parse(value, active);
        if (SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(handoff_variable), null) == 0)
            return error.RendererHandoffEnvironment;
    } else if (comptime active != .opengl) {
        // Standalone backend executables can still run without the launcher.
        return .{};
    }

    const io = global.io();
    const self = try std.process.executablePathAlloc(io, alloc);
    defer alloc.free(self);
    const directory = std.fs.path.dirname(self) orelse return error.InvalidExecutablePath;
    const requested: ?Backend = switch (preference) {
        .auto, .opengl => null,
        .d3d12 => .d3d12,
        .vulkan => .vulkan,
    };
    for ([_]struct { backend: Backend, filename: []const u8, available: *bool }{
        .{ .backend = .d3d12, .filename = "ghostty-d3d12.exe", .available = &result.d3d12_available },
        .{ .backend = .vulkan, .filename = "ghostty-vulkan.exe", .available = &result.vulkan_available },
    }) |candidate| {
        const selected = active == .opengl and requested == candidate.backend;
        const path = try std.fs.path.join(alloc, &.{ directory, candidate.filename });
        defer alloc.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
            if (selected) result.failure = .{
                .preference = preference,
                .problem = if (err == error.FileNotFound) .missing else .startup_failed,
            };
            continue;
        };
        candidate.available.* = true;
        if (selected) {
            launch(alloc, path, candidate.backend) catch |err| {
                log.warn("{t} startup failed, using OpenGL: {t}", .{ candidate.backend, err });
                result.failure = .{ .preference = preference, .problem = .startup_failed };
                continue;
            };
            return error.RendererHandedOff;
        }
    }

    if (comptime active == .d3d12) {
        // The first surface will use the device checked here.
        app.device = try Device.init(alloc, .{});
        try result.commit();
    }
    // Vulkan commits when its first HWND has a graphics device and swapchain.
    return result;
}

const Handoff = struct {
    ready: w32.HANDLE,
    proceed: w32.HANDLE,

    fn parse(marker: []const u8, backend: Backend) !Handoff {
        var fields = std.mem.splitScalar(u8, marker, ':');
        if (!std.mem.eql(u8, fields.first(), @tagName(backend))) return error.UnexpectedRendererHandoff;
        const ready = try std.fmt.parseUnsigned(usize, fields.next() orelse return error.InvalidRendererHandoff, 10);
        const proceed = try std.fmt.parseUnsigned(usize, fields.next() orelse return error.InvalidRendererHandoff, 10);
        if (fields.next() != null) return error.InvalidRendererHandoff;
        if (ready == 0 or proceed == 0 or ready == proceed) return error.InvalidRendererHandoff;
        return .{ .ready = @ptrFromInt(ready), .proceed = @ptrFromInt(proceed) };
    }

    fn close(self: Handoff) void {
        _ = w32.CloseHandle(self.proceed);
        _ = w32.CloseHandle(self.ready);
    }
};

fn launch(alloc: std.mem.Allocator, executable: []const u8, backend: Backend) !void {
    const io = global.io();
    const ready = w32.CreateEventW(null, 1, 0, null) orelse return error.RendererHandoffEvent;
    defer _ = w32.CloseHandle(ready);
    const proceed = w32.CreateEventW(null, 1, 0, null) orelse return error.RendererHandoffEvent;
    defer _ = w32.CloseHandle(proceed);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    const original = try global.args().toSlice(scratch);
    const args = try scratch.alloc([]const u8, @max(1, original.len));
    args[0] = executable;
    for (args[1..], original[@min(1, original.len)..]) |*dest, source| dest.* = source;

    var env = try global.environMap();
    defer env.deinit();
    var marker: [64]u8 = undefined;
    try env.put(handoff_variable, try std.fmt.bufPrint(&marker, "{t}:{d}:{d}", .{ backend, @intFromPtr(ready), @intFromPtr(proceed) }));
    var child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        // Windows handle inheritance works for event objects as well as files.
        .inherit_files = &.{
            .{ .handle = ready, .flags = .{ .nonblocking = false } },
            .{ .handle = proceed, .flags = .{ .nonblocking = false } },
        },
    });
    errdefer child.kill(io);

    // The selected process may start a terminal command only after commit.
    // A failed or timed-out startup is terminated before OpenGL takes over.
    if (WaitForMultipleObjects(2, &.{ ready, child.id.? }, 0, startup_timeout_ms) != w32.WAIT_OBJECT_0 or
        w32.WaitForSingleObject(child.id.?, 0) != w32.WAIT_TIMEOUT or w32.SetEvent(proceed) == 0)
        return error.RendererStartupFailed;

    _ = w32.CloseHandle(child.thread_handle);
    _ = w32.CloseHandle(child.id.?);
}

test "win32 renderer handoff decodes distinct nonzero event handles" {
    const pair = try Handoff.parse("vulkan:42:207", .vulkan);
    try std.testing.expectEqual(@as(usize, 42), @intFromPtr(pair.ready));
    try std.testing.expectEqual(@as(usize, 207), @intFromPtr(pair.proceed));
    try std.testing.expectError(error.UnexpectedRendererHandoff, Handoff.parse("vulkan:42:207", .d3d12));
    try std.testing.expectError(error.InvalidRendererHandoff, Handoff.parse("d3d12:8", .d3d12));
    try std.testing.expectError(error.InvalidRendererHandoff, Handoff.parse("d3d12:0:8", .d3d12));
    try std.testing.expectError(error.InvalidRendererHandoff, Handoff.parse("d3d12:8:8", .d3d12));
}
