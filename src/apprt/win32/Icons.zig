//! Antialiased window controls using the MIT-licensed Feather SVG geometry.
//! https://github.com/feathericons/feather/tree/main/icons
const std = @import("std");
const w32 = @import("win32.zig");

const StartupInput = extern struct {
    version: u32 = 1,
    debug_callback: ?*const anyopaque = null,
    suppress_background_thread: i32 = 0,
    suppress_external_codecs: i32 = 1,
};
const Point = extern struct { x: f32, y: f32 };
const Graphics = opaque {};
const Pen = opaque {};

pub const Icon = enum {
    plus,
    chevron_down,
    close,

    // Points are in the original 24 × 24 SVG viewbox.
    fn strokes(self: Icon) []const []const Point {
        return switch (self) {
            .plus => &.{
                &.{ .{ .x = 5, .y = 12 }, .{ .x = 19, .y = 12 } },
                &.{ .{ .x = 12, .y = 5 }, .{ .x = 12, .y = 19 } },
            },
            .chevron_down => &.{&.{ .{ .x = 6, .y = 9 }, .{ .x = 12, .y = 15 }, .{ .x = 18, .y = 9 } }},
            .close => &.{
                &.{ .{ .x = 18, .y = 6 }, .{ .x = 6, .y = 18 } },
                &.{ .{ .x = 6, .y = 6 }, .{ .x = 18, .y = 18 } },
            },
        };
    }
};

extern "gdiplus" fn GdiplusStartup(*usize, *const StartupInput, ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdiplusShutdown(usize) callconv(.winapi) void;
extern "gdiplus" fn GdipCreateFromHDC(w32.HDC, *?*Graphics) callconv(.winapi) i32;
extern "gdiplus" fn GdipDeleteGraphics(*Graphics) callconv(.winapi) i32;
extern "gdiplus" fn GdipSetSmoothingMode(*Graphics, enum(i32) { antialias = 4 }) callconv(.winapi) i32;
extern "gdiplus" fn GdipSetPixelOffsetMode(*Graphics, enum(i32) { half = 4 }) callconv(.winapi) i32;
extern "gdiplus" fn GdipCreatePen1(u32, f32, enum(i32) { pixel = 2 }, *?*Pen) callconv(.winapi) i32;
extern "gdiplus" fn GdipDeletePen(*Pen) callconv(.winapi) i32;
extern "gdiplus" fn GdipSetPenWidth(*Pen, f32) callconv(.winapi) i32;
const LineCap = enum(i32) { round = 2 };
extern "gdiplus" fn GdipSetPenLineCap197819(*Pen, LineCap, LineCap, enum(i32) { flat = 0 }) callconv(.winapi) i32;
extern "gdiplus" fn GdipSetPenLineJoin(*Pen, enum(i32) { round = 2 }) callconv(.winapi) i32;
extern "gdiplus" fn GdipDrawLines(*Graphics, *Pen, [*]const Point, i32) callconv(.winapi) i32;

pub fn startup() ?usize {
    var token: usize = 0;
    return if (GdiplusStartup(&token, &.{}, null) == 0) token else null;
}

pub fn shutdown(token: usize) void {
    GdiplusShutdown(token);
}

pub const Painter = struct {
    graphics: *Graphics,
    pen: *Pen,

    pub fn init(dc: w32.HDC, color: u32) ?Painter {
        var graphics_ptr: ?*Graphics = null;
        if (GdipCreateFromHDC(dc, &graphics_ptr) != 0) return null;
        const graphics = graphics_ptr orelse return null;

        const argb = 0xff000000 | ((color & 0xff) << 16) | (color & 0xff00) | (color >> 16);
        var pen_ptr: ?*Pen = null;
        if (GdipCreatePen1(argb, 1, .pixel, &pen_ptr) != 0 or pen_ptr == null) {
            _ = GdipDeleteGraphics(graphics);
            return null;
        }
        const pen = pen_ptr.?;
        _ = GdipSetSmoothingMode(graphics, .antialias);
        _ = GdipSetPixelOffsetMode(graphics, .half);
        _ = GdipSetPenLineCap197819(pen, .round, .round, .flat);
        _ = GdipSetPenLineJoin(pen, .round);
        return .{ .graphics = graphics, .pen = pen };
    }

    pub fn deinit(self: Painter) void {
        _ = GdipDeletePen(self.pen);
        _ = GdipDeleteGraphics(self.graphics);
    }

    /// Place the SVG viewbox around the center of a pixel-space rectangle.
    /// Keep fractional coordinates through scaling and round only in GDI+.
    pub fn draw(self: Painter, comptime icon: Icon, rect: w32.RECT, size_px: f32) void {
        const center_x = @as(f32, @floatFromInt(rect.left + rect.right)) * 0.5;
        const center_y = @as(f32, @floatFromInt(rect.top + rect.bottom)) * 0.5;
        const unit = size_px / 24;
        _ = GdipSetPenWidth(self.pen, 2 * unit);
        inline for (comptime icon.strokes()) |stroke| {
            var points: [stroke.len]Point = undefined;
            for (&points, stroke) |*point, source| point.* = .{
                .x = center_x + (source.x - 12) * unit,
                .y = center_y + (source.y - 12) * unit,
            };
            _ = GdipDrawLines(self.graphics, self.pen, &points, points.len);
        }
    }
};

extern "gdi32" fn GdiFlush() callconv(.winapi) i32;

test "win32 icons render centered antialiased strokes at common DPI scales" {
    const testing = std.testing;
    const token = startup() orelse return error.GdiPlusStartup;
    defer shutdown(token);
    const dc = w32.CreateCompatibleDC(null) orelse return error.CreateCompatibleDC;
    defer _ = w32.DeleteDC(dc);

    const side = 64;
    const info: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = side, .biHeight = -side } };
    var bits: ?*anyopaque = null;
    const bitmap = w32.CreateDIBSection(dc, &info, w32.DIB_RGB_COLORS, &bits, null, 0) orelse
        return error.CreateDIBSection;
    defer _ = w32.DeleteObject(bitmap);
    const old = w32.SelectObject(dc, bitmap);
    defer _ = w32.SelectObject(dc, old);
    const pixels: *[side * side]u32 = @ptrCast(@alignCast(bits orelse return error.MissingBitmapPixels));

    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        // Exercise both integer and half-pixel centers.
        for ([_]usize{ side, side + 1 }) |diameter| {
            const rect: w32.RECT = .{ .left = 4, .top = 4, .right = @intCast(diameter - 4), .bottom = @intCast(diameter - 4) };
            inline for ([_]Icon{ .plus, .chevron_down, .close }) |icon| {
                @memset(pixels, 0);
                {
                    const painter = Painter.init(dc, w32.RGB(255, 255, 255)) orelse return error.IconPainter;
                    defer painter.deinit();
                    painter.draw(icon, rect, 18 * scale);
                }
                _ = GdiFlush();

                var min_x: usize = side;
                var min_y: usize = side;
                var max_x: usize = 0;
                var max_y: usize = 0;
                var has_soft_edge = false;
                var coverage: u32 = 0;
                var imbalanced: u32 = 0;
                for (0..side) |y| {
                    for (1..side) |x| {
                        const value: i32 = @intCast(pixels[y * side + x] & 0xff);
                        const mirror: i32 = @intCast(pixels[y * side + diameter - 1 - x] & 0xff);
                        coverage += @intCast(value);
                        imbalanced += @abs(value - mirror);
                        if (value == 0) continue;
                        min_x = @min(min_x, x);
                        min_y = @min(min_y, y);
                        max_x = @max(max_x, x);
                        max_y = @max(max_y, y);
                        has_soft_edge = has_soft_edge or value < 255;
                    }
                }
                if (coverage == 0 or !has_soft_edge or imbalanced * 4 > coverage) {
                    std.debug.print(
                        "{t} at scale {d}: coverage {d}, horizontal imbalance {d}, antialiased {}\n",
                        .{ icon, scale, coverage, imbalanced, has_soft_edge },
                    );
                    return error.IconPixelCoverage;
                }
                try testing.expect(max_x - min_x + 1 >= @as(usize, @intFromFloat(9 * scale)));
                try testing.expect(max_y - min_y + 1 >= @as(usize, @intFromFloat(4 * scale)));
                try testing.expect(@abs(@as(i32, @intCast(min_x + max_x + 1)) - @as(i32, @intCast(diameter))) <= 1);
                try testing.expect(@abs(@as(i32, @intCast(min_y + max_y + 1)) - @as(i32, @intCast(diameter))) <= 1);
                if (icon == .chevron_down) {
                    const center_x = diameter / 2;
                    try testing.expect(pixels[max_y * side + center_x] & 0xff != 0);
                    try testing.expect(pixels[(min_y + 1) * side + center_x] & 0xff < 64);
                }
            }
        }
    }
}
