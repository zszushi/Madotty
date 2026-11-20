//! Decode the payload of a DEC Sixel DCS into straight-alpha RGBA pixels.
//! https://vt100.net/docs/vt3xx-gp/chapter14.html

const std = @import("std");
const Allocator = std.mem.Allocator;
const RGB = [3]u8;
const RGBA = [4]u8;

pub const color_registers = 256;
pub const max_payload_bytes = 8 * 1024 * 1024;
pub const max_dimension = 8192;

const max_pixels = 16 * 1024 * 1024;
const max_painted_pixels = 4 * max_pixels;

pub const Options = struct {
    /// DCS P1 selects the initial pixel aspect ratio.
    aspect: u32 = 0,
    /// DCS P2 = 1 preserves the existing background through transparency.
    background_mode: u32 = 0,
    background: RGB = .{ 0, 0, 0 },
    foreground: RGB = .{ 255, 255, 255 },
    /// Optional narrower ceiling imposed by the terminal image storage.
    max_bytes: usize = max_pixels * @sizeOf(RGBA),
};

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: Image, alloc: Allocator) void {
        alloc.free(self.rgba);
    }
};

pub const Error = Allocator.Error || error{ InvalidSixel, SixelTooLarge, EmptySixel };

/// Measure the image and bound its drawing work before allocating its pixels.
/// The second pass fills that single allocation directly, including repeats.
pub fn decode(alloc: Allocator, payload: []const u8, options: Options) Error!Image {
    if (payload.len > max_payload_bytes) return error.SixelTooLarge;
    var measure: Decoder = .init(options);
    try measure.parse(payload, null);

    const width = measure.width;
    const height = measure.height * measure.aspect;
    if (width == 0 or height == 0) return error.EmptySixel;
    if (height > max_dimension or width * height > max_pixels or
        width * height > options.max_bytes / @sizeOf(RGBA)) return error.SixelTooLarge;

    const pixels = try alloc.alloc(RGBA, width * height);
    errdefer alloc.free(pixels);
    @memset(pixels, if (options.background_mode == 1)
        .{ 0, 0, 0, 0 }
    else
        withAlpha(options.background));

    var draw: Decoder = .init(options);
    try draw.parse(payload, .{ .pixels = pixels, .width = width });
    return .{ .width = width, .height = height, .rgba = std.mem.sliceAsBytes(pixels) };
}

const Raster = struct {
    pixels: []RGBA,
    width: u32,
};

const Decoder = struct {
    palette: [color_registers]RGB = defaultPalette(),
    color: RGB,
    aspect: u32,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    painted_pixels: u32 = 0,
    started: bool = false,

    fn init(options: Options) Decoder {
        return .{
            .color = options.foreground,
            .aspect = switch (options.aspect) {
                0, 1, 5, 6 => 2,
                2 => 5,
                3, 4 => 3,
                else => 1,
            },
        };
    }

    fn parse(self: *Decoder, payload: []const u8, raster: ?Raster) Error!void {
        var input: Input = .{ .remaining = payload };
        while (input.next()) |byte| {
            switch (byte) {
                '?'...'~' => try self.run(raster, @intCast(byte - '?'), 1),
                '!' => {
                    const count = @max(try input.number() orelse 1, 1);
                    const column = input.next() orelse return error.InvalidSixel;
                    if (column < '?' or column > '~') return error.InvalidSixel;
                    try self.run(raster, @intCast(column - '?'), count);
                },
                '"' => try self.attributes(try input.parameters(4)),
                '#' => try self.selectColor(try input.parameters(5)),
                '$' => self.x = 0,
                '-' => {
                    self.started = true;
                    self.x = 0;
                    self.y += 6;
                    // A final DECGNL after the last band does not add rows.
                    if (self.y > max_dimension + 5) return error.SixelTooLarge;
                },
                else => return error.InvalidSixel,
            }
        }
    }

    fn attributes(self: *Decoder, p: Parameters(4)) Error!void {
        if (self.started) return error.InvalidSixel;
        const pan: u64 = @max(p.values[0] orelse 1, 1);
        const pad: u64 = @max(p.values[1] orelse 1, 1);
        // DEC terminals round the vertical-to-horizontal ratio to an integer.
        const aspect = @max(1, (pan + pad / 2) / pad);
        const width = p.values[2] orelse 0;
        const height = p.values[3] orelse 0;
        if (aspect > max_dimension or width > max_dimension or height > max_dimension) return error.SixelTooLarge;
        self.aspect = @intCast(aspect);
        self.width = width;
        self.height = height;
    }

    fn selectColor(self: *Decoder, p: Parameters(5)) Error!void {
        const index = p.values[0] orelse 0;
        if (index >= self.palette.len) return error.InvalidSixel;
        if (p.len > 1) {
            const x = p.values[2] orelse 0;
            const y = p.values[3] orelse 0;
            const z = p.values[4] orelse 0;
            if (y > 100 or z > 100) return error.InvalidSixel;
            self.palette[index] = switch (p.values[1] orelse 0) {
                1 => if (x <= 360) fromHls(x, y, z) else return error.InvalidSixel,
                2 => if (x <= 100) fromPercent(x, y, z) else return error.InvalidSixel,
                else => return error.InvalidSixel,
            };
        }
        self.color = self.palette[index];
    }

    fn run(self: *Decoder, raster: ?Raster, bits: u6, count: u32) Error!void {
        self.started = true;
        if (count > max_dimension - self.x) return error.SixelTooLarge;
        const start = self.x;
        self.x += count;
        self.width = @max(self.width, self.x);
        const rows: u32 = @max(1, 6 - @clz(bits));
        self.height = @max(self.height, self.y + rows);
        if (self.height > max_dimension) return error.SixelTooLarge;
        if (bits == 0) return;

        const scaled_count: u64 = @as(u64, count) * @popCount(bits) * self.aspect;
        if (scaled_count > max_painted_pixels - self.painted_pixels) return error.SixelTooLarge;
        self.painted_pixels += @intCast(scaled_count);
        const target = raster orelse return;

        var mask = bits;
        while (mask != 0) : (mask &= mask - 1) {
            const bit: u32 = @ctz(mask);
            const y = (self.y + bit) * self.aspect;
            for (y..y + self.aspect) |row| {
                const offset = row * target.width;
                @memset(target.pixels[offset + start .. offset + self.x], withAlpha(self.color));
            }
        }
    }
};

fn Parameters(comptime n: usize) type {
    return struct {
        values: [n]?u32 = @splat(null),
        len: usize = 1,
    };
}

const Input = struct {
    remaining: []const u8,

    fn peek(self: *Input) ?u8 {
        while (self.remaining.len > 0) {
            switch (self.remaining[0]) {
                ' ', '\t', '\r', '\n', 0x7f => self.remaining = self.remaining[1..],
                else => return self.remaining[0],
            }
        }
        return null;
    }

    fn next(self: *Input) ?u8 {
        const byte = self.peek() orelse return null;
        self.remaining = self.remaining[1..];
        return byte;
    }

    fn number(self: *Input) Error!?u32 {
        var value: ?u32 = null;
        while (self.peek()) |byte| {
            if (byte < '0' or byte > '9') break;
            self.remaining = self.remaining[1..];
            const shifted = std.math.mul(u32, value orelse 0, 10) catch return error.SixelTooLarge;
            value = std.math.add(u32, shifted, byte - '0') catch return error.SixelTooLarge;
        }
        return value;
    }

    fn parameters(self: *Input, comptime n: usize) Error!Parameters(n) {
        var result: Parameters(n) = .{};
        while (true) {
            result.values[result.len - 1] = try self.number();
            if (self.peek() != ';') return result;
            self.remaining = self.remaining[1..];
            if (result.len == n) return error.InvalidSixel;
            result.len += 1;
        }
    }
};

fn withAlpha(rgb: RGB) RGBA {
    return .{ rgb[0], rgb[1], rgb[2], 255 };
}

fn fromPercent(r: u32, g: u32, b: u32) RGB {
    return .{ percentChannel(r), percentChannel(g), percentChannel(b) };
}

fn percentChannel(percent: u32) u8 {
    return @intCast((percent * 255 + 50) / 100);
}

fn fromHls(hue: u32, lightness: u32, saturation: u32) RGB {
    // DEC hue 0 is blue. Standard HSL hue 0 is red.
    const angle = (hue + 240) % 360;
    const l = @as(f64, @floatFromInt(lightness)) / 100;
    const s = @as(f64, @floatFromInt(saturation)) / 100;
    const c = (1 - @abs(2 * l - 1)) * s;
    const x = c * (1 - @abs(@as(f64, @floatFromInt(angle % 120)) / 60 - 1));
    const m = l - c / 2;
    const components: [3]f64 = switch (angle / 60) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    return .{
        @intFromFloat(@round((components[0] + m) * 255)),
        @intFromFloat(@round((components[1] + m) * 255)),
        @intFromFloat(@round((components[2] + m) * 255)),
    };
}

fn defaultPalette() [color_registers]RGB {
    // VT340 registers, followed by the extended cube and grayscale ramp.
    const base: [16]RGB = .{
        .{ 0, 0, 0 },    .{ 20, 20, 80 }, .{ 80, 13, 13 }, .{ 20, 80, 20 },
        .{ 80, 20, 80 }, .{ 20, 80, 80 }, .{ 80, 80, 20 }, .{ 53, 53, 53 },
        .{ 26, 26, 26 }, .{ 33, 33, 60 }, .{ 60, 26, 26 }, .{ 33, 60, 33 },
        .{ 60, 33, 60 }, .{ 33, 60, 60 }, .{ 60, 60, 33 }, .{ 80, 80, 80 },
    };
    var palette: [color_registers]RGB = undefined;
    for (base, 0..) |rgb, i| palette[i] = fromPercent(rgb[0], rgb[1], rgb[2]);
    for (palette[16..232], 0..) |*entry, i| {
        entry.* = .{ @intCast(i / 36 * 42), @intCast(i / 6 % 6 * 42), @intCast(i % 6 * 42) };
    }
    for (palette[232..], 0..) |*entry, i| entry.* = @splat(@intCast(i * 11));
    return palette;
}

test "sixel repeats, transparent gaps, overlay, and sixel band advance" {
    const testing = std.testing;
    const image = try decode(testing.allocator, "\"1;1;4;7#2;2;100;0;0!3@$#3;2;0;100;0?@-??@", .{
        .background_mode = 1,
    });
    defer image.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4), image.width);
    try testing.expectEqual(@as(u32, 7), image.height);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0 }, image.rgba[0..16]);
    try testing.expectEqualSlices(u8, &@as([80]u8, @splat(0)), image.rgba[16..96]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0, 0 }, image.rgba[96..112]);
}

test "sixel uses DEC HLS hue and only redefines subsequent pixels" {
    const testing = std.testing;
    const image = try decode(testing.allocator, "#1;1;0;50;100@#1;1;120;50;100@#1;1;240;50;100@#1;1;360;50;100@", .{
        .aspect = 7,
    });
    defer image.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), image.height);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255 }, image.rgba);
}

test "sixel aspect, defined background, and raster dimensions" {
    const testing = std.testing;
    const image = try decode(testing.allocator, "\"3;2;1;2@?", .{
        .aspect = 2,
        .background_mode = 2,
        .foreground = .{ 10, 20, 30 },
        .background = .{ 40, 50, 60 },
    });
    defer image.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), image.width);
    try testing.expectEqual(@as(u32, 4), image.height);
    const pixels = std.mem.bytesAsSlice(RGBA, image.rgba);
    try testing.expectEqualSlices(RGBA, &.{
        .{ 10, 20, 30, 255 }, .{ 40, 50, 60, 255 },
        .{ 10, 20, 30, 255 }, .{ 40, 50, 60, 255 },
        .{ 40, 50, 60, 255 }, .{ 40, 50, 60, 255 },
        .{ 40, 50, 60, 255 }, .{ 40, 50, 60, 255 },
    }, pixels);

    const macro = try decode(testing.allocator, "@-", .{ .aspect = 2 });
    defer macro.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 5), macro.height);
}

test "sixel rejects malformed payloads and separately bounds image and paint work" {
    const testing = std.testing;
    try testing.expectError(error.InvalidSixel, decode(testing.allocator, "!2#", .{}));
    try testing.expectError(error.InvalidSixel, decode(testing.allocator, "#8;2;101;0;0@", .{}));
    try testing.expectError(error.InvalidSixel, decode(testing.allocator, "@\"1;1;2;2", .{}));
    try testing.expectError(error.EmptySixel, decode(testing.allocator, "#3", .{}));
    try testing.expectError(error.SixelTooLarge, decode(testing.allocator, "!4294967296@", .{}));
    try testing.expectError(error.SixelTooLarge, decode(testing.allocator, "!8193?", .{}));
    try testing.expectError(error.SixelTooLarge, decode(testing.allocator, "\"1;1;8192;8192", .{}));
    try testing.expectError(error.SixelTooLarge, decode(testing.allocator, "\"1;1;3;1", .{ .max_bytes = 11 }));
    const run = "!8192~$";
    var overdraw: [run.len * 300]u8 = undefined;
    for (0..300) |i| @memcpy(overdraw[i * run.len ..][0..run.len], run);
    try testing.expectError(error.SixelTooLarge, decode(testing.allocator, &overdraw, .{ .aspect = 2 }));
}
