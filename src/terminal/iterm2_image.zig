//! Display OSC 1337 inline images through the terminal's shared image storage.
const std = @import("std");
const terminal = @import("main.zig");
const osc = @import("osc.zig");
const wuffs = @import("wuffs");
const LimitedAllocator = @import("../datastruct/main.zig").LimitedAllocator;
const Allocator = std.mem.Allocator;

/// Bound file accumulation independently of the OSC parser's packet limit.
const max_file_bytes = 32 * 1024 * 1024;
const max_decoded_bytes = 128 * 1024 * 1024;
const max_dimension = 10000;
const max_display_rows = 255;

pub const State = struct {
    transfer: ?Transfer = null,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.transfer) |*transfer| transfer.bytes.deinit(alloc);
        self.* = .{};
    }

    pub fn handle(
        self: *State,
        t: *terminal.Terminal,
        packet: osc.ITermInlineImage,
        cell_width: u32,
        cell_height: u32,
    ) !void {
        if (comptime !terminal.options.kitty_graphics) return;
        const alloc = t.gpa();
        if (!t.screens.active.kitty_images.enabled()) {
            self.deinit(alloc);
            return;
        }

        switch (packet) {
            .cancel => self.deinit(alloc),
            .file => |file| {
                self.deinit(alloc);
                var transfer: Transfer = .{ .options = file.options };
                defer transfer.bytes.deinit(alloc);
                try transfer.appendPart(alloc, file.data);
                try transfer.finish(alloc);
                try display(t, &transfer, cell_width, cell_height);
            },
            .multipart_file => |options| {
                self.deinit(alloc);
                self.transfer = .{ .options = options };
            },
            .file_part => |data| {
                const transfer = if (self.transfer) |*pending| pending else return;
                errdefer self.deinit(alloc);
                try transfer.appendPart(alloc, data);
            },
            .file_end => {
                var transfer = self.transfer orelse return;
                self.transfer = null;
                defer transfer.bytes.deinit(alloc);
                try transfer.finish(alloc);
                try display(t, &transfer, cell_width, cell_height);
            },
        }
    }
};

const Transfer = struct {
    options: osc.ITermImageOptions,
    bytes: std.ArrayList(u8) = .empty,
    tail: [3]u8 = undefined,
    tail_len: u2 = 0,

    fn appendPart(self: *Transfer, alloc: Allocator, text: []const u8) !void {
        var input = text;
        if (self.tail_len != 0) {
            const prefix_len: usize = self.tail_len;
            const fill = 4 - prefix_len;
            if (input.len < fill) {
                try self.saveTail(input, prefix_len);
                return;
            }

            var quantum: [4]u8 = undefined;
            @memcpy(quantum[0..prefix_len], self.tail[0..prefix_len]);
            @memcpy(quantum[prefix_len..], input[0..fill]);
            input = input[fill..];
            if (quantum[3] == '=' and input.len != 0) return error.InvalidBase64;
            try self.decode(alloc, std.base64.standard.Decoder, &quantum);
        }

        const complete = input.len - input.len % 4;
        if (complete > 0 and complete < input.len and input[complete - 1] == '=') return error.InvalidBase64;
        try self.decode(alloc, std.base64.standard.Decoder, input[0..complete]);
        try self.saveTail(input[complete..], 0);
    }

    fn saveTail(self: *Transfer, bytes: []const u8, offset: usize) !void {
        const alphabet = std.base64.standard_alphabet_chars ++ [_]u8{'='};
        if (std.mem.indexOfNone(u8, bytes, &alphabet) != null) return error.InvalidBase64;
        @memcpy(self.tail[offset..][0..bytes.len], bytes);
        self.tail_len = @intCast(offset + bytes.len);
    }

    fn finish(self: *Transfer, alloc: Allocator) !void {
        try self.decode(alloc, std.base64.standard_no_pad.Decoder, self.tail[0..self.tail_len]);
        self.tail_len = 0;
    }

    fn decode(self: *Transfer, alloc: Allocator, decoder: std.base64.Base64Decoder, data: []const u8) !void {
        if (data.len == 0) return;
        const count = decoder.calcSizeForSlice(data) catch return error.InvalidBase64;
        const total = self.bytes.items.len +| count;
        if (total > max_file_bytes) return error.ImageTooLarge;
        if (total > self.bytes.capacity) {
            const capacity = @min(max_file_bytes, @max(total, 4096 + self.bytes.capacity * 2));
            try self.bytes.ensureTotalCapacityPrecise(alloc, capacity);
        }
        const destination = self.bytes.addManyAsSliceAssumeCapacity(count);
        errdefer self.bytes.items.len -= count;
        decoder.decode(destination, data) catch return error.InvalidBase64;
    }
};

fn display(t: *terminal.Terminal, transfer: *const Transfer, cell_width: u32, cell_height: u32) !void {
    if (cell_width == 0 or cell_height == 0) return;
    const screen = t.screens.active;
    const storage = &screen.kitty_images;
    const alloc = t.gpa();
    const data = transfer.bytes.items;
    const decoded_limit = @min(max_decoded_bytes, storage.total_limit);
    // Give the codecs room for their decoder state even if the configured
    // allowance for stored pixels is very small. Pixel bytes are checked
    // separately before they can enter image storage.
    var limited: LimitedAllocator = .init(alloc, @max(1024 * 1024, decoded_limit));
    const image = decodeImage(limited.allocator(), data) catch |err| switch (err) {
        error.OutOfMemory => return if (limited.limit_exceeded) error.ImageTooLarge else err,
        else => return err,
    };
    var stored = false;
    defer if (!stored) alloc.free(image.data);
    if (image.width == 0 or image.height == 0) return error.InvalidImage;
    if (image.data.len > decoded_limit or image.width > max_dimension or image.height > max_dimension)
        return error.ImageTooLarge;

    const origin = screen.cursor.page_pin.*;
    const region = t.scrolling_region;
    const margin = if (screen.cursor.x >= region.left and screen.cursor.x <= region.right)
        region.right
    else
        t.cols - 1;
    const size = imageSize(
        transfer.options,
        .{ .width = image.width, .height = image.height },
        .{ .width = cell_width, .height = cell_height },
        .{ .width = @as(u32, t.cols) *| cell_width, .height = @as(u32, t.rows) *| cell_height },
        .{ .width = (@as(u32, margin) + 1 - origin.x) *| cell_width, .height = max_display_rows *| cell_height },
    );

    // Reserve both the placement and its pin before storing decoded pixels.
    // After storage takes ownership, adding the reserved placement cannot fail.
    try storage.placements.ensureUnusedCapacity(alloc, 1);
    const pin = try screen.pages.trackPin(origin);
    errdefer if (!stored) screen.pages.untrackPin(pin);
    const id = storage.nextImageId(.implicit);
    try storage.addImage(t.io(), alloc, screen, .{
        .id = id,
        .width = image.width,
        .height = image.height,
        .format = .rgba,
        .data = .{ .complete = image.data },
        .metadata = .{ .transient = true, .implicit_id = true },
    });
    stored = true;
    storage.addPlacement(t.io(), alloc, screen, id, 0, .{
        .location = .{ .pin = pin },
        .destination_width = size.image.width,
        .destination_height = size.image.height,
    }) catch unreachable;

    if (transfer.options.do_not_move_cursor) return;
    const cols = std.math.divCeil(u32, size.area.width, cell_width) catch unreachable;
    const rows = std.math.divCeil(u32, size.area.height, cell_height) catch unreachable;
    for (1..rows) |_| try t.index();
    const end = @as(u32, origin.x) + cols;
    screen.cursorHorizontalAbsolute(@intCast(@min(margin, end)));
    screen.cursor.pending_wrap = end > margin;
}

fn decodeImage(alloc: Allocator, data: []const u8) !wuffs.ImageData {
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return wuffs.png.decode(alloc, data);
    if (std.mem.startsWith(u8, data, "\xff\xd8")) return wuffs.jpeg.decode(alloc, data);
    return error.UnsupportedImageFormat;
}

const Pixels = struct { width: u32, height: u32 };
const ImageSize = struct { area: Pixels, image: Pixels };

fn imageSize(options: osc.ITermImageOptions, native: Pixels, cell: Pixels, pane: Pixels, available: Pixels) ImageSize {
    const width = dimensionPixels(options.width, cell.width, pane.width);
    const height = dimensionPixels(options.height, cell.height, pane.height);
    const requested: Pixels = if (width) |w| if (height) |h|
        .{ .width = w, .height = h }
    else
        .{ .width = w, .height = scale(w, native.height, native.width) } else if (height) |h|
        .{ .width = scale(h, native.width, native.height), .height = h }
    else
        native;

    const area = if (requested.width > available.width or requested.height > available.height)
        contain(requested, available)
    else
        requested;
    // iTerm2 moves past the requested box even when fitting an image with
    // a different aspect ratio leaves part of the box uncovered.
    return .{
        .area = area,
        .image = if (options.preserve_aspect_ratio and width != null and height != null)
            contain(native, area)
        else
            area,
    };
}

fn dimensionPixels(dimension: osc.ITermImageDimension, cell: u32, pane: u32) ?u32 {
    return switch (dimension) {
        .auto => null,
        .cells => |value| @max(1, value *| cell),
        .pixels => |value| @max(1, value),
        .percent => |value| @max(1, @as(u32, @intCast(@as(u64, pane) * @min(value, 100) / 100))),
    };
}

fn contain(image: Pixels, bounds: Pixels) Pixels {
    if (@as(u64, image.width) * bounds.height >= @as(u64, image.height) * bounds.width) return .{
        .width = bounds.width,
        .height = scale(bounds.width, image.height, image.width),
    };
    return .{ .width = scale(bounds.height, image.width, image.height), .height = bounds.height };
}

fn scale(value: u32, numerator: u32, denominator: u32) u32 {
    const result = (@as(u64, value) * numerator + denominator / 2) / denominator;
    return @max(1, std.math.cast(u32, result) orelse std.math.maxInt(u32));
}

const red_and_blue_png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8AAQv8BD/kD/YURmXYAAAAASUVORK5CYII=";

test "iTerm2 image dimensions use cells, pixels, percentages, and aspect" {
    const testing = std.testing;
    const native: Pixels = .{ .width = 200, .height = 100 };
    const cell: Pixels = .{ .width = 10, .height = 20 };
    const pane: Pixels = .{ .width = 800, .height = 600 };
    try testing.expectEqual(native, imageSize(.{}, native, cell, pane, pane).image);
    try testing.expectEqual(Pixels{ .width = 30, .height = 15 }, imageSize(.{
        .width = .{ .cells = 3 },
    }, native, cell, pane, pane).image);
    const fitted = imageSize(.{
        .width = .{ .percent = 50 },
        .height = .{ .pixels = 20 },
    }, native, cell, pane, pane);
    try testing.expectEqual(Pixels{ .width = 40, .height = 20 }, fitted.image);
    try testing.expectEqual(Pixels{ .width = 400, .height = 20 }, fitted.area);
    try testing.expectEqual(Pixels{ .width = 400, .height = 20 }, imageSize(.{
        .width = .{ .percent = 50 },
        .height = .{ .pixels = 20 },
        .preserve_aspect_ratio = false,
    }, native, cell, pane, pane).image);
    try testing.expectEqual(Pixels{ .width = 20, .height = 10 }, imageSize(
        .{},
        native,
        cell,
        pane,
        .{ .width = 20, .height = 50 },
    ).image);
}

test "iTerm2 image renders decoded PNG into a pin and advances like iTerm2" {
    if (comptime !terminal.options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit(testing.allocator);
    var state: State = .{};
    defer state.deinit(testing.allocator);
    try state.handle(&t, .{ .file = .{
        .options = .{
            .width = .{ .pixels = 13 },
            .height = .{ .pixels = 19 },
            .preserve_aspect_ratio = false,
        },
        .data = red_and_blue_png,
    } }, 8, 16);

    const screen = t.screens.active;
    const storage = &screen.kitty_images;
    try testing.expectEqual(1, storage.images.count());
    try testing.expectEqual(1, storage.placements.count());
    var images = storage.images.valueIterator();
    const image = images.next().?.*;
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }, image.data.complete);
    var placements = storage.placements.valueIterator();
    const placement = placements.next().?.*;
    try testing.expectEqual(13, placement.destination_width);
    try testing.expectEqual(19, placement.destination_height);
    try testing.expectEqual(0, placement.location.pin.x);
    try testing.expectEqual(2, screen.cursor.x);
    try testing.expectEqual(1, screen.cursor.y);
    try testing.expect(!screen.cursor.pending_wrap);
}

test "iTerm2 image multipart decodes split quanta and cancels invalid transfers" {
    if (comptime !terminal.options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit(testing.allocator);
    var state: State = .{};
    defer state.deinit(testing.allocator);
    const screen = t.screens.active;
    screen.cursorHorizontalAbsolute(3);

    try state.handle(&t, .{ .multipart_file = .{ .do_not_move_cursor = true } }, 8, 16);
    try state.handle(&t, .{ .file_part = red_and_blue_png[0..5] }, 8, 16);
    try testing.expectError(error.InvalidBase64, state.handle(&t, .{ .file_part = "%bad" }, 8, 16));
    try state.handle(&t, .file_end, 8, 16);
    try testing.expectEqual(0, screen.kitty_images.images.count());

    try state.handle(&t, .{ .multipart_file = .{ .do_not_move_cursor = true } }, 8, 16);
    try state.handle(&t, .{ .file_part = red_and_blue_png[0..5] }, 8, 16);
    try state.handle(&t, .{ .file_part = red_and_blue_png[5..6] }, 8, 16);
    try state.handle(&t, .{ .file_part = red_and_blue_png[6..] }, 8, 16);
    try testing.expectEqual(0, screen.kitty_images.images.count());
    try state.handle(&t, .file_end, 8, 16);
    try testing.expectEqual(1, screen.kitty_images.images.count());
    var placements = screen.kitty_images.placements.valueIterator();
    try testing.expectEqual(3, placements.next().?.location.pin.x);
    try testing.expectEqual(3, screen.cursor.x);
    try testing.expectEqual(0, screen.cursor.y);
}

test "iTerm2 image rejects pixels above the image storage budget" {
    if (comptime !terminal.options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit(testing.allocator);
    t.setKittyGraphicsSizeLimit(testing.allocator, 4);
    var state: State = .{};
    defer state.deinit(testing.allocator);
    try testing.expectError(error.ImageTooLarge, state.handle(&t, .{ .file = .{
        .options = .{},
        .data = red_and_blue_png,
    } }, 8, 16));
    try testing.expectEqual(0, t.screens.active.kitty_images.images.count());
    try testing.expectEqual(0, t.screens.active.kitty_images.placements.count());
    try testing.expectEqual(0, t.screens.active.cursor.x);
}

test "iTerm2 image decodes JPEG without a renderer-specific decoder" {
    if (comptime !terminal.options.kitty_graphics) return error.SkipZigTest;
    const jpeg = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMU" ++
        "FRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU" ++
        "FBQUFBQUFBQUFBT/wAARCAABAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIE" ++
        "AwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUp" ++
        "TVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW" ++
        "19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcF" ++
        "BAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK" ++
        "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU" ++
        "1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDj6KKK/FD+LD//2Q==";
    const testing = std.testing;
    var file: Transfer = .{ .options = .{} };
    defer file.bytes.deinit(testing.allocator);
    try file.appendPart(testing.allocator, jpeg);
    try file.finish(testing.allocator);
    const result = try decodeImage(testing.allocator, file.bytes.items);
    defer testing.allocator.free(result.data);
    try testing.expectEqual(2, result.width);
    try testing.expectEqual(1, result.height);
    try testing.expectEqual(8, result.data.len);
}
