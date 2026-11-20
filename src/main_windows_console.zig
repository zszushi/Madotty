//! Console entry point so Windows shells wait for Ghostty CLI actions.
const std = @import("std");

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("Ghostty: could not run ghostty.exe ({t})\n", .{err});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const original = try init.minimal.args.toSlice(alloc);
    const args = try alloc.alloc([]const u8, original.len);
    const self = try std.process.executablePathAlloc(init.io, alloc);
    const directory = std.fs.path.dirname(self) orelse return error.InvalidExecutablePath;
    args[0] = try std.fs.path.join(alloc, &.{ directory, "ghostty.exe" });
    for (args[1..], original[1..]) |*dest, source| dest.* = source;

    // CLI actions and their errors are observable by the calling shell.
    // Arguments following -e belong to the command run in a new window.
    var help = false;
    const cli = for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-e")) break false;
        if (std.mem.startsWith(u8, arg, "+") or std.mem.eql(u8, arg, "--version")) break true;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) help = true;
    } else help;

    const stream: std.process.SpawnOptions.StdIo = if (cli) .inherit else .ignore;
    var child = try std.process.spawn(init.io, .{
        .argv = args,
        .stdin = stream,
        .stdout = stream,
        .stderr = stream,
    });
    if (!cli) {
        std.os.windows.CloseHandle(child.thread_handle);
        std.os.windows.CloseHandle(child.id.?);
        return 0;
    }
    return switch (try child.wait(init.io)) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 1,
    };
}
