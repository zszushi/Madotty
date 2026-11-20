const std = @import("std");
const w32 = @import("win32.zig");
const TabText = @This();

const Context = opaque {};
context: ?*Context = null,
initialized: bool = false,

extern fn madotty_tab_text_create() ?*Context;
extern fn madotty_tab_text_destroy(?*Context) void;
extern fn madotty_tab_text_draw(*Context, w32.HDC, *const w32.RECT, [*]const u16, u32, u32, c_int, c_int) c_int;

pub fn deinit(self: *TabText) void {
    madotty_tab_text_destroy(self.context);
    self.* = .{};
}

pub fn draw(self: *TabText, dc: w32.HDC, rect: w32.RECT, text: []const u16, color: u32, center: bool) bool {
    return self.drawShaped(dc, rect, text, color, center, false);
}

pub fn drawShaped(self: *TabText, dc: w32.HDC, rect: w32.RECT, text: []const u16, color: u32, center: bool, require_fit: bool) bool {
    // ASCII labels use the already-selected GDI font without initializing a
    // second renderer. Shape other labels as one string to preserve clusters.
    for (text) |unit| {
        if (unit > 0x7f) break;
    } else return false;
    if (!self.initialized) {
        self.context = madotty_tab_text_create();
        self.initialized = true;
    }
    const context = self.context orelse return false;
    return madotty_tab_text_draw(context, dc, &rect, text.ptr, @intCast(text.len), color, @intFromBool(center), @intFromBool(require_fit)) != 0;
}

test "win32 tab title shapes emoji clusters in color on a GDI background" {
    const width = 216;
    const height = 32;
    const dc = w32.CreateCompatibleDC(null) orelse return error.Win32Error;
    defer _ = w32.DeleteDC(dc);
    var bits: ?*anyopaque = null;
    const bitmap = w32.CreateDIBSection(dc, &.{ .bmiHeader = .{ .biWidth = width, .biHeight = -height } }, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return error.Win32Error;
    defer _ = w32.DeleteObject(bitmap);
    const old_bitmap = w32.SelectObject(dc, bitmap);
    defer _ = w32.SelectObject(dc, old_bitmap);
    const font = @import("UiFont.zig").resolve("Consolas").create(20, 1) orelse return error.Win32Error;
    defer _ = w32.DeleteObject(font);
    const old_font = w32.SelectObject(dc, font);
    defer _ = w32.SelectObject(dc, old_font);
    const pixels: *[width * height]u32 = @ptrCast(@alignCast(bits.?));
    var renderer: TabText = .{};
    defer renderer.deinit();
    const title = std.unicode.utf8ToUtf16LeStringLiteral("👻 日本語 / 👩‍💻 / ❤️");
    const background = 0x00141414;
    const rect = w32.RECT{ .left = 8, .right = width - 8, .top = 2, .bottom = height - 2 };
    @memset(pixels, background);
    try std.testing.expect(renderer.draw(dc, rect, title, 0x00dddddd, true));
    _ = w32.GdiFlush();
    var colors: usize = 0;
    for (pixels, 0..) |pixel, i| {
        const x = i % width;
        const y = i / width;
        const rgb = pixel & 0x00ffffff;
        if (x < 8 or x >= width - 8 or y < 2 or y >= height - 2)
            try std.testing.expectEqual(@as(u32, background), rgb);
        const r: i32 = @intCast(rgb >> 16);
        const b: i32 = @intCast(rgb & 255);
        if (@abs(r - b) > 30) colors += 1;
    }
    try std.testing.expect(colors > 20);
}
