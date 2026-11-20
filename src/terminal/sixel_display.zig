//! Place decoded Sixel images through the terminal's image storage.
const std = @import("std");
const terminal = @import("main.zig");
const sixel = @import("sixel.zig");

pub fn enabled(t: *const terminal.Terminal) bool {
    if (comptime !terminal.options.kitty_graphics) return false;
    return t.screens.active.kitty_images.enabled();
}

pub fn display(t: *terminal.Terminal, command: *terminal.dcs.Command.Sixel) !void {
    if (comptime !terminal.options.kitty_graphics) return;
    if (!enabled(t)) return;

    const screen = t.screens.active;
    const storage = &screen.kitty_images;
    const alloc = t.gpa();
    const background: terminal.color.RGB = t.colors.background.get() orelse .{ .r = 0, .g = 0, .b = 0 };
    const foreground: terminal.color.RGB = t.colors.foreground.get() orelse .{ .r = 255, .g = 255, .b = 255 };
    const image = try sixel.decode(alloc, command.data.written(), .{
        .aspect = command.aspect,
        .background_mode = command.background_mode,
        .background = .{ background.r, background.g, background.b },
        .foreground = .{ foreground.r, foreground.g, foreground.b },
        .max_bytes = storage.total_limit,
    });
    var stored = false;
    defer if (!stored) image.deinit(alloc);
    if (image.width == 0 or image.height == 0) return;

    const fixed = t.modes.get(.sixel_display_mode);
    const cell_width: u32 = @max(1, t.width_px / t.cols);
    const cell_height: u32 = @max(1, t.height_px / t.rows);
    const origin = if (fixed) screen.pages.getTopLeft(.active) else screen.cursor.page_pin.*;
    const right_margin = if (!fixed and
        screen.cursor.x >= t.scrolling_region.left and screen.cursor.x <= t.scrolling_region.right)
        t.scrolling_region.right
    else
        t.cols - 1;
    const width = @min(image.width, (@as(u32, right_margin) + 1 - origin.x) *| cell_width);
    const height = if (fixed) @min(image.height, @as(u32, t.rows) *| cell_height) else image.height;

    const pin = try screen.pages.trackPin(origin);
    errdefer if (!stored) screen.pages.untrackPin(pin);
    try storage.addSixel(t.io(), alloc, screen, .{
        .id = storage.nextImageId(.implicit),
        .width = image.width,
        .height = image.height,
        .format = .rgba,
        .data = .{ .complete = image.rgba },
        .metadata = .{ .transient = true, .implicit_id = true, .sixel = true },
    }, .{
        .location = .{ .pin = pin },
        .source_width = width,
        .source_height = height,
    }, command.background_mode != 1);
    stored = true;

    if (fixed) return;
    const right = t.modes.get(.sixel_cursor_right);
    const rows = std.math.divCeil(u32, height, cell_height) catch unreachable;
    const before_scroll: u32 = t.scrolling_region.bottom -| screen.cursor.y;
    const steps = @min(rows - @intFromBool(right), before_scroll +| @as(u32, t.rows));
    for (0..steps) |_| try t.index();
    if (right) {
        const cols = std.math.divCeil(u32, width, cell_width) catch unreachable;
        const target = @as(u32, origin.x) + cols;
        screen.cursorHorizontalAbsolute(@intCast(@min(right_margin, target)));
        screen.cursor.pending_wrap = target > right_margin;
    } else t.carriageReturn();
}

/// Read or reset the fixed register count, or read graphics geometry.
/// Replies use status zero. Ignore status-zero sequences if echoed.
pub fn query(
    t: *const terminal.Terminal,
    request: terminal.StreamAction.SixelQuery,
    buf: []u8,
) !?[]const u8 {
    if (!enabled(t)) return null;
    return switch (request.item) {
        1 => switch (request.action) {
            1, 2, 4 => try std.fmt.bufPrint(buf, "\x1b[?1;0;{d}S", .{sixel.color_registers}),
            else => null,
        },
        2 => switch (request.action) {
            1 => try std.fmt.bufPrint(buf, "\x1b[?2;0;{d};{d}S", .{
                @min(t.width_px, sixel.max_dimension),
                @min(t.height_px, sixel.max_dimension),
            }),
            4 => try std.fmt.bufPrint(buf, "\x1b[?2;0;{d};{d}S", .{ sixel.max_dimension, sixel.max_dimension }),
            else => null,
        },
        else => null,
    };
}

test "sixel graphics queries honor the image limit and ignore a response echo" {
    if (comptime !terminal.options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\x1b[?1;0;256S", (try query(&t, .{ .item = 1, .action = 1 }, &buf)).?);
    try testing.expect((try query(&t, .{ .item = 1, .action = 0 }, &buf)) == null);
    t.setKittyGraphicsSizeLimit(testing.allocator, 0);
    try testing.expect((try query(&t, .{ .item = 1, .action = 1 }, &buf)) == null);
}
