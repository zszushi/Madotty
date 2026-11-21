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

const Bitmap = opaque {};
extern "gdiplus" fn GdipCreateBitmapFromFile([*:0]const u16, *?*Bitmap) callconv(.winapi) i32;
extern "gdiplus" fn GdipCreateHICONFromBitmap(*Bitmap, *?w32.HICON) callconv(.winapi) i32;
extern "gdiplus" fn GdipDisposeImage(*Bitmap) callconv(.winapi) i32;

/// Decode Windows Terminal profile artwork into a caller-owned icon.
pub fn loadPng(path: [*:0]const u16) ?w32.HICON {
    var bitmap: ?*Bitmap = null;
    if (GdipCreateBitmapFromFile(path, &bitmap) != 0) return null;
    const image = bitmap orelse return null;
    defer _ = GdipDisposeImage(image);
    var icon: ?w32.HICON = null;
    return if (GdipCreateHICONFromBitmap(image, &icon) == 0) icon else null;
}

const Path = opaque {};
const Brush = opaque {};
extern "gdiplus" fn GdipCreatePath(i32, *?*Path) callconv(.winapi) i32;
extern "gdiplus" fn GdipDeletePath(*Path) callconv(.winapi) i32;
extern "gdiplus" fn GdipAddPathArc(*Path, f32, f32, f32, f32, f32, f32) callconv(.winapi) i32;
extern "gdiplus" fn GdipClosePathFigure(*Path) callconv(.winapi) i32;
extern "gdiplus" fn GdipCreateSolidFill(u32, *?*Brush) callconv(.winapi) i32;
extern "gdiplus" fn GdipDeleteBrush(*Brush) callconv(.winapi) i32;
extern "gdiplus" fn GdipFillPath(*Graphics, *Brush, *Path) callconv(.winapi) i32;
extern "gdiplus" fn GdipSetClipRectI(*Graphics, i32, i32, i32, i32, i32) callconv(.winapi) i32;
extern "gdi32" fn GetClipBox(w32.HDC, *w32.RECT) callconv(.winapi) i32;

/// Area coverage at the center of a pixel in a horizontal or vertical capsule.
pub fn pillCoverage(x: i32, y: i32, width: i32, height: i32) u8 {
    const radius = @as(f32, @floatFromInt(@min(width, height))) * 0.5;
    const px = @as(f32, @floatFromInt(x)) + 0.5;
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    const dx = px - std.math.clamp(px, radius, @as(f32, @floatFromInt(width)) - radius);
    const dy = py - std.math.clamp(py, radius, @as(f32, @floatFromInt(height)) - radius);
    const squared = dx * dx + dy * dy;
    if (squared <= (radius - 0.5) * (radius - 0.5)) return 255;
    if (squared >= (radius + 0.5) * (radius + 0.5)) return 0;
    return @intFromFloat(@round(255 * std.math.clamp(radius + 0.5 - @sqrt(squared), 0, 1)));
}

/// Composite an opaque RGB color over a premultiplied ARGB pixel.
pub fn overPixel(background: u32, rgb: u32, coverage: u8) u32 {
    if (coverage == 0) return background;
    if (coverage == 255) return 0xff000000 | rgb;
    const a: u32 = coverage;
    var out: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |shift| {
        const src = if (shift == 24) 255 else (rgb >> shift) & 255;
        const dst = (background >> shift) & 255;
        out |= ((src * a + dst * (255 - a) + 127) / 255) << shift;
    }
    return out;
}

pub fn fillTabPill(dc: w32.HDC, pixels: [*]u32, stride: i32, rect: w32.RECT, inset: i32, color: u32) void {
    var clip: w32.RECT = undefined;
    if (GetClipBox(dc, &clip) <= 1) return;
    const left = rect.left + inset;
    const top = rect.top + inset;
    const width = rect.right - inset - left;
    const height = rect.bottom - inset - top;
    const rgb = ((color & 255) << 16) | (color & 0xff00) | ((color >> 16) & 255);
    _ = GdiFlush();
    var y = @max(top, clip.top);
    while (y < @min(top + height, clip.bottom)) : (y += 1) {
        const first = @max(left, clip.left);
        const last = @min(left + width, clip.right);
        if (first >= last) continue;
        const radius = @divTrunc(@min(width, height) + 1, 2);
        const middle_left = std.math.clamp(left + radius, first, last);
        const middle_right = std.math.clamp(left + width - radius, middle_left, last);
        const row = pixels + @as(usize, @intCast(y * stride));
        var x = first;
        while (x < middle_left) : (x += 1) row[@intCast(x)] = overPixel(row[@intCast(x)], rgb, pillCoverage(x - left, y - top, width, height));
        @memset(row[@intCast(middle_left)..@intCast(middle_right)], 0xff000000 | rgb);
        x = middle_right;
        while (x < last) : (x += 1) row[@intCast(x)] = overPixel(row[@intCast(x)], rgb, pillCoverage(x - left, y - top, width, height));
    }
}

test "win32 pill edges preserve backdrop coverage" {
    try std.testing.expectEqual(@as(u32, 0x80808080), overPixel(0, 0xffffff, 128));
    try std.testing.expectEqual(@as(u32, 0xc0505050), overPixel(0x80202020, 0x808080, 128));
    try std.testing.expectEqual(@as(u8, 0), pillCoverage(0, 0, 100, 20));
    try std.testing.expectEqual(@as(u8, 255), pillCoverage(50, 4, 100, 20));
    const edge = pillCoverage(2, 3, 100, 20);
    try std.testing.expect(edge > 0 and edge < 255);
}
pub fn fillRounded(dc: w32.HDC, rect: w32.RECT, inset: i32, radius: i32, color: u32) bool {
    const width = rect.right - rect.left - 2 * inset;
    const height = rect.bottom - rect.top - 2 * inset;
    if (@min(width, height) <= 0) return true;
    var graphics: ?*Graphics = null;
    if (GdipCreateFromHDC(dc, &graphics) != 0) return false;
    const g = graphics.?;
    defer _ = GdipDeleteGraphics(g);
    var clip: w32.RECT = undefined;
    if (GetClipBox(dc, &clip) == 0 or GdipSetClipRectI(g, clip.left, clip.top, clip.right - clip.left, clip.bottom - clip.top, 0) != 0) return false;
    _ = GdipSetSmoothingMode(g, .antialias);
    _ = GdipSetPixelOffsetMode(g, .half);
    var path: ?*Path = null;
    if (GdipCreatePath(0, &path) != 0) return false;
    defer _ = GdipDeletePath(path.?);
    const x: f32 = @floatFromInt(rect.left + inset);
    const y: f32 = @floatFromInt(rect.top + inset);
    if (radius <= 0) return false;
    const size: f32 = @floatFromInt(@min(@min(width, height), 2 * radius));
    const right = x + @as(f32, @floatFromInt(width)) - size;
    const bottom = y + @as(f32, @floatFromInt(height)) - size;
    if (GdipAddPathArc(path.?, x, y, size, size, 180, 90) != 0 or
        GdipAddPathArc(path.?, right, y, size, size, 270, 90) != 0 or
        GdipAddPathArc(path.?, right, bottom, size, size, 0, 90) != 0 or
        GdipAddPathArc(path.?, x, bottom, size, size, 90, 90) != 0 or
        GdipClosePathFigure(path.?) != 0) return false;
    var brush: ?*Brush = null;
    const argb = 0xff000000 | ((color & 0xff) << 16) | (color & 0xff00) | (color >> 16);
    if (GdipCreateSolidFill(argb, &brush) != 0) return false;
    defer _ = GdipDeleteBrush(brush.?);
    return GdipFillPath(g, brush.?, path.?) == 0;
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

    @memset(pixels, 0);
    const pill = w32.RECT{ .left = 4, .top = 10, .right = 60, .bottom = 40 };
    try testing.expect(fillRounded(dc, pill, 2, 20, w32.RGB(255, 255, 255)));
    _ = GdiFlush();
    var soft_edge = false;
    for (pixels, 0..) |pixel, index| {
        const channel = pixel & 255;
        const x = index % side;
        const y = index / side;
        if (x < 6 or x >= 58 or y < 12 or y >= 38) try testing.expectEqual(@as(u32, 0), channel);
        if (channel > 0 and channel < 255) soft_edge = true;
    }
    try testing.expect(soft_edge);
    try testing.expectEqual(@as(u32, 255), pixels[25 * side + 32] & 255);

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
