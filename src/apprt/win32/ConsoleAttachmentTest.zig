//! Exercise inbound PTY ownership with real Win32 pipes and the bundled
//! ConPTY API. The fixture supplies the console-side handles directly.
const std = @import("std");
const Exec = @import("../../termio/Exec.zig");
const Pty = @import("../../pty.zig").Pty;
const winsize = @import("../../pty.zig").winsize;
const windows = @import("../../os/windows.zig");
const w32 = @import("win32.zig");
const kernel32 = windows.exp.kernel32;
const testing = std.testing;

test "win32 console attachment moves both pipe directions and resizes through ConPTY" {
    const server = try openFixtureProcess();
    defer close(server);
    var reference = try Pipe.open();
    defer reference.deinit();
    var signal = try Pipe.open();
    defer signal.deinit();

    var attachment = try makeAttachment(server, reference.writer.?, signal.writer.?);
    const client = attachment.client;
    const console = attachment.pty.takeConsolePipes();
    defer close(console.input);
    defer close(console.output);

    {
        var exec = Exec.initAttached(testing.allocator, attachment);
        defer exec.deinit();
        try exec.resize(.{ .columns = 51, .rows = 13 }, .{ .width = 510, .height = 260 });
        const endpoints = try exec.subprocess.start(testing.allocator);
        try testing.expect(exec.subprocess.process == null);
        try testing.expect(exec.subprocess.pending_attachment == null);
        try testing.expectEqual(@as(?windows.HANDLE, client), exec.subprocess.attached_client);
        try testing.expectEqual(winsize{
            .ws_col = 51,
            .ws_row = 13,
            .ws_xpixel = 510,
            .ws_ypixel = 260,
        }, try exec.subprocess.pty.?.getSize());
        try expectBytes(signal.reader, &.{ 8, 0, 51, 0, 13, 0 });

        const text = "\x1b[32madopted output\x1b[0m";
        try writeSync(console.output, text);
        try expectBytes(endpoints.read, text);
        try writeOverlapped(endpoints.write, "terminal input\r");
        try expectBytes(console.input, "terminal input\r");

        try exec.resize(.{ .columns = 44, .rows = 12 }, .{ .width = 440, .height = 240 });
        try expectBytes(signal.reader, &.{ 8, 0, 44, 0, 12, 0 });

        // Starting the attachment released the packed reference. The caller
        // still owns its original writer and closing it makes the reader EOF.
        try testing.expect(isOpen(reference.writer.?));
        reference.closeWriter();
        try expectBrokenPipe(reference.reader);
    }

    try testing.expect(!isOpen(client));
    try testing.expect(isOpen(server));
    try testing.expect(isOpen(signal.writer.?));
    try testing.expect(isOpen(console.input));
    try testing.expect(isOpen(console.output));
}

test "win32 console attachment cleans up when the console signal write fails" {
    const server = try openFixtureProcess();
    defer close(server);
    var reference = try Pipe.open();
    defer reference.deinit();
    var signal = try Pipe.open();
    defer signal.deinit();

    const attachment = try makeAttachment(server, reference.writer.?, signal.writer.?);
    const client = attachment.client;
    {
        var exec = Exec.initAttached(testing.allocator, attachment);
        defer exec.deinit();
        // Close the fixture's signal reader to force the initial resize to
        // fail. The pending attachment must still own the packed session.
        signal.closeReader();
        try exec.resize(.{ .columns = 51, .rows = 13 }, .{ .width = 510, .height = 260 });
        try testing.expectError(error.ResizeFailed, exec.subprocess.start(testing.allocator));
        try testing.expect(exec.subprocess.pending_attachment != null);
        try testing.expect(exec.subprocess.pty == null);
        try testing.expect(isOpen(client));
        reference.closeWriter();
        var available: u32 = 0;
        try testing.expectEqual(windows.TRUE, kernel32.PeekNamedPipe(reference.reader, null, 0, null, &available, null));
    }

    try expectBrokenPipe(reference.reader);
    try testing.expect(!isOpen(client));
    try testing.expect(isOpen(server));
    try testing.expect(isOpen(signal.writer.?));
}

test "win32 console attachment closes partial handle duplicates on adoption failure" {
    const server = try openFixtureProcess();
    defer close(server);
    var reference = try Pipe.open();
    defer reference.deinit();

    var result = Pty.adopt(.{}, .{
        .server = server,
        .reference = reference.writer.?,
        .signal = windows.INVALID_HANDLE_VALUE,
    }) catch |err| {
        switch (err) {
            error.ConptyPackUnavailable, error.ConptyReleaseUnavailable => return error.SkipZigTest,
            else => try testing.expectEqual(error.InvalidHandoffHandle, err),
        }
        try testing.expect(isOpen(server));
        try testing.expect(isOpen(reference.writer.?));
        reference.closeWriter();
        try expectBrokenPipe(reference.reader);
        return;
    };
    result.deinit();
    return error.UnexpectedSuccessfulAdoption;
}

const Pipe = struct {
    reader: windows.HANDLE,
    writer: ?windows.HANDLE,
    reader_closed: bool = false,

    fn open() !Pipe {
        var reader: windows.HANDLE = undefined;
        var writer: windows.HANDLE = undefined;
        if (kernel32.CreatePipe(&reader, &writer, null, 0) == windows.FALSE)
            return windows.unexpectedError(windows.GetLastError());
        return .{ .reader = reader, .writer = writer };
    }

    fn deinit(self: *Pipe) void {
        self.closeWriter();
        self.closeReader();
    }

    fn closeReader(self: *Pipe) void {
        if (self.reader_closed) return;
        close(self.reader);
        self.reader_closed = true;
    }

    fn closeWriter(self: *Pipe) void {
        if (self.writer) |writer| close(writer);
        self.writer = null;
    }
};

fn makeAttachment(server: windows.HANDLE, reference: windows.HANDLE, signal: windows.HANDLE) !Exec.Attachment {
    const client = try openFixtureProcess();
    errdefer close(client);
    const pty = Pty.adopt(.{}, .{ .server = server, .reference = reference, .signal = signal }) catch |err| switch (err) {
        error.ConptyPackUnavailable, error.ConptyReleaseUnavailable => return error.SkipZigTest,
        else => return err,
    };
    return .{ .pty = pty, .client = client };
}

fn openFixtureProcess() !windows.HANDLE {
    const query_limited_information = 0x1000;
    return OpenProcess(query_limited_information | windows.SYNCHRONIZE, windows.FALSE, windows.GetCurrentProcessId()) orelse
        return windows.unexpectedError(windows.GetLastError());
}

fn close(handle: windows.HANDLE) void {
    _ = kernel32.CloseHandle(handle);
}

fn isOpen(handle: windows.HANDLE) bool {
    var flags: u32 = undefined;
    return GetHandleInformation(handle, &flags) != windows.FALSE;
}

fn expectBytes(reader: windows.HANDLE, expected: []const u8) !void {
    var available: u32 = 0;
    try testing.expectEqual(windows.TRUE, kernel32.PeekNamedPipe(reader, null, 0, null, &available, null));
    try testing.expect(available >= expected.len);
    var buffer: [64]u8 = undefined;
    const bytes = buffer[0..expected.len];
    var count: u32 = 0;
    try testing.expectEqual(windows.TRUE, kernel32.ReadFile(reader, bytes.ptr, @intCast(bytes.len), &count, null));
    try testing.expectEqual(expected.len, count);
    try testing.expectEqualSlices(u8, expected, bytes);
}

fn expectBrokenPipe(reader: windows.HANDLE) !void {
    var available: u32 = 0;
    const peeked = kernel32.PeekNamedPipe(reader, null, 0, null, &available, null);
    const last_error = windows.GetLastError();
    try testing.expectEqual(windows.FALSE, peeked);
    try testing.expectEqual(.BROKEN_PIPE, last_error);
}

fn writeSync(writer: windows.HANDLE, data: []const u8) !void {
    var count: u32 = 0;
    try testing.expectEqual(windows.TRUE, kernel32.WriteFile(writer, data.ptr, @intCast(data.len), &count, null));
    try testing.expectEqual(data.len, count);
}

fn writeOverlapped(writer: windows.HANDLE, data: []const u8) !void {
    const event = w32.CreateEventW(null, 1, 0, null) orelse return windows.unexpectedError(windows.GetLastError());
    defer close(event);
    var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.hEvent = event;
    var count: u32 = 0;
    const started = kernel32.WriteFile(writer, data.ptr, @intCast(data.len), &count, &overlapped);
    if (started == windows.FALSE) {
        try testing.expectEqual(.IO_PENDING, windows.GetLastError());
        if (w32.WaitForSingleObject(event, 3000) != w32.WAIT_OBJECT_0) {
            _ = kernel32.CancelIoEx(writer, &overlapped);
            _ = GetOverlappedResult(writer, &overlapped, &count, windows.TRUE);
            return error.PipeWriteTimedOut;
        }
        try testing.expectEqual(windows.TRUE, GetOverlappedResult(writer, &overlapped, &count, windows.FALSE));
    }
    try testing.expectEqual(data.len, count);
}

extern "kernel32" fn OpenProcess(u32, windows.BOOL, u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetHandleInformation(windows.HANDLE, *u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetOverlappedResult(windows.HANDLE, *windows.OVERLAPPED, *u32, windows.BOOL) callconv(.winapi) windows.BOOL;
