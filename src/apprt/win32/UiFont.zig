//! GDI font used by native window chrome. Resolve the family only when
//! configuration changes; individual controls keep their own sized handles.
const UiFont = @This();
const std = @import("std");
const w32 = @import("win32.zig");

// LF_FACESIZE includes the terminating NUL.
face: [32]u16 = @splat(0),

const FontEnumProc = *const fn (*const anyopaque, *const anyopaque, u32, isize) callconv(.winapi) i32;
extern "gdi32" fn EnumFontFamiliesW(w32.HDC, [*:0]const u16, FontEnumProc, isize) callconv(.winapi) i32;

fn foundFamily(_: *const anyopaque, _: *const anyopaque, _: u32, context: isize) callconv(.winapi) i32 {
    const found: *bool = @ptrFromInt(@as(usize, @bitCast(context)));
    found.* = true;
    return 0;
}

pub fn resolve(name: []const u8) UiFont {
    if (name.len == 0 or name.len > 31 * 3 or std.mem.indexOfScalar(u8, name, 0) != null) return .{};
    const len = std.unicode.calcUtf16LeLen(name) catch return .{};
    if (len >= 32) return .{};
    var result: UiFont = .{};
    _ = std.unicode.utf8ToUtf16Le(&result.face, name) catch return .{};
    // CreateFontW silently substitutes an arbitrary font for unknown names.
    // Use the same Segoe UI fallback for those as for an empty setting.
    const dc = w32.CreateCompatibleDC(null) orelse return .{};
    defer _ = w32.DeleteDC(dc);
    var found = false;
    _ = EnumFontFamiliesW(dc, @ptrCast(&result.face), foundFamily, @bitCast(@intFromPtr(&found)));
    return if (found) result else .{};
}

pub fn create(self: *const UiFont, size: f32, scale: f32) ?*anyopaque {
    const family: [*:0]const u16 = if (self.face[0] != 0) @ptrCast(&self.face) else std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    return w32.CreateFontW(-@as(i32, @intFromFloat(@round(size * scale))), 0, 0, 0, w32.FW_NORMAL, 0, 0, 0, w32.DEFAULT_CHARSET, 0, 0, 0, 0, family);
}

pub fn replace(self: *const UiFont, slot: *?*anyopaque, size: f32, scale: f32, controls: []const ?w32.HWND) void {
    const next = self.create(size, scale) orelse return;
    const old = slot.*;
    slot.* = next;
    for (controls) |maybe| if (maybe) |control| {
        _ = w32.SendMessageW(control, w32.WM_SETFONT, @intFromPtr(next), 1);
    };
    if (old) |font| _ = w32.DeleteObject(font);
}

test "win32 UI font resolves installed families and rejects invalid GDI names" {
    const chosen = resolve("Consolas");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Consolas"), std.mem.sliceTo(&chosen.face, 0));
    for ([_][]const u8{ "", "Madotty Missing Font XYZ", "01234567890123456789012345678901", "\xff", "Arial\x00Extra" }) |name| {
        try std.testing.expectEqual(UiFont{}, resolve(name));
    }
}

test "win32 UI font replaces the live control handle on a family and DPI change" {
    const native = struct {
        extern "gdi32" fn GetObjectW(*anyopaque, i32, *anyopaque) callconv(.winapi) i32;
        const LogFont = extern struct {
            height: i32,
            metrics: [4]i32,
            flags: [8]u8,
            name: [32]u16,
        };
    };
    const instance = w32.GetModuleHandleW(null) orelse return error.Win32Error;
    var slot: ?*anyopaque = null;
    defer if (slot) |f| {
        _ = w32.DeleteObject(f);
    };
    const edit = w32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), std.unicode.utf8ToUtf16LeStringLiteral(""), w32.WS_POPUP, 0, 0, 120, 30, null, null, instance, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(edit);
    for ([_][]const u8{ "Consolas", "" }, [_]f32{ 1, 1.5 }, [_]i32{ -16, -24 }, [_][]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("Consolas"), std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI") }) |name, scale, height, expected| {
        const family = resolve(name);
        family.replace(&slot, 16, scale, &.{edit});
        const font = slot orelse return error.Win32Error;
        try std.testing.expectEqual(@intFromPtr(font), @as(usize, @bitCast(w32.SendMessageW(edit, 0x0031, 0, 0)))); // WM_GETFONT
        var logical: native.LogFont = undefined;
        try std.testing.expectEqual(@as(i32, @sizeOf(native.LogFont)), native.GetObjectW(font, @sizeOf(native.LogFont), &logical));
        try std.testing.expectEqual(height, logical.height);
        try std.testing.expectEqualSlices(u16, expected, std.mem.sliceTo(&logical.name, 0));
    }
}
