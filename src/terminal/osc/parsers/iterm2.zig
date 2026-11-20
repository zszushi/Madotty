const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;
const lib = @import("../../lib.zig");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;

const log = std.log.scoped(.osc_iterm2);

pub const ImageDimension = union(enum) {
    auto,
    cells: u32,
    pixels: u32,
    percent: u32,
};

pub const ImageOptions = struct {
    width: ImageDimension = .auto,
    height: ImageDimension = .auto,
    preserve_aspect_ratio: bool = true,
    do_not_move_cursor: bool = false,
};

pub const InlineImage = union(enum) {
    file: struct { options: ImageOptions, data: []const u8 },
    multipart_file: ImageOptions,
    file_part: []const u8,
    file_end,
    cancel,

    pub const C = void;

    pub fn cval(_: InlineImage) C {}
};

const Key = enum {
    AddAnnotation,
    AddHiddenAnnotation,
    Block,
    Button,
    ClearCapturedOutput,
    ClearScrollback,
    Copy,
    CopyToClipboard,
    CurrentDir,
    CursorShape,
    Custom,
    Disinter,
    EndCopy,
    File,
    FileEnd,
    FilePart,
    HighlightCursorLine,
    MultipartFile,
    OpenURL,
    PopKeyLabels,
    PushKeyLabels,
    RemoteHost,
    ReportCellSize,
    ReportVariable,
    RequestAttention,
    RequestUpload,
    SetBackgroundImageFile,
    SetBadgeFormat,
    SetColors,
    SetKeyLabel,
    SetMark,
    SetProfile,
    SetUserVar,
    ShellIntegrationVersion,
    StealFocus,
    UnicodeVersion,
};

// Instead of using `std.meta.stringToEnum` we set up a StaticStringMap so
// that we can get ASCII case-insensitive lookups.
const Map = std.StaticStringMapWithEql(Key, std.ascii.eqlIgnoreCase);
const map: Map = .initComptime(
    map: {
        const fields = @typeInfo(Key).@"enum".field_names;
        const values = @typeInfo(Key).@"enum".field_values;
        var tmp: [fields.len]struct { [:0]const u8, Key } = undefined;
        for (fields, values, 0..) |field, value, i| {
            tmp[i] = .{ field, @fromBackingInt(value) };
        }
        break :map tmp;
    },
);

pub fn isImage(data: []const u8) bool {
    return switch (map.get(std.mem.sliceTo(data, '=')) orelse return false) {
        .File, .MultipartFile, .FilePart, .FileEnd => true,
        else => false,
    };
}

/// Only the packets carrying encoded data need more than the fixed OSC buffer.
pub fn largeCaptureLimit(data: []const u8, max_bytes: usize) usize {
    return imageCaptureLimit(map.get(std.mem.sliceTo(data, '=')) orelse return 0, max_bytes) orelse 0;
}

fn imageCaptureLimit(key: Key, max_bytes: usize) ?usize {
    return switch (key) {
        .File => max_bytes,
        .FilePart => @min(max_bytes, 1024 * 1024),
        else => null,
    };
}

pub fn cancelImage(parser: *Parser) *Command {
    parser.command = .{ .iterm_inline_image = .cancel };
    return &parser.command;
}

/// Parse OSC 1337. https://iterm2.com/documentation-images.html
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"1337");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    const split = std.mem.indexOfScalar(u8, data, '=');
    const key = map.get(data[0 .. split orelse data.len]) orelse {
        parser.command = .invalid;
        return null;
    };

    switch (key) {
        .Copy => {
            var value = terminatedValue(parser, split) orelse {
                parser.command = .invalid;
                return null;
            };

            // Sending a blank entry to clear the clipboard is an OSC 52-ism,
            // make sure that is invalid here.
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }

            // base64 value must be prefixed by a colon
            if (value[0] != ':') {
                parser.command = .invalid;
                return null;
            }

            value = value[1..value.len :0];

            // Sending a blank entry to clear the clipboard is an OSC 52-ism,
            // make sure that is invalid here.
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }

            // Sending a '?' to query the clipboard is an OSC 52-ism, make sure
            // that is invalid here.
            if (value.len == 1 and value[0] == '?') {
                parser.command = .invalid;
                return null;
            }

            // It would be better to check for valid base64 data here, but that
            // would mean parsing the base64 data twice in the "normal" case.

            parser.command = .{
                .clipboard_contents = .{
                    .kind = 'c',
                    .data = value,
                },
            };
            return &parser.command;
        },

        .CurrentDir => {
            const value = terminatedValue(parser, split) orelse {
                parser.command = .invalid;
                return null;
            };
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }
            parser.command = .{
                .report_pwd = .{
                    .value = value,
                },
            };
            return &parser.command;
        },

        .ReportCellSize => {
            if (split != null) return null;
            parser.command = .{ .iterm_report_cell_size = .init(terminator_ch) };
        },

        .File, .MultipartFile, .FilePart, .FileEnd => {
            const value = if (split) |index| data[index + 1 ..] else null;
            if (imageCaptureLimit(key, parser.max_allocating_bytes)) |limit| {
                if (data.len > limit) return cancelImage(parser);
            }
            parser.command = .{ .iterm_inline_image = parseImage(key, value) orelse .cancel };
        },

        .AddAnnotation,
        .AddHiddenAnnotation,
        .Block,
        .Button,
        .ClearCapturedOutput,
        .ClearScrollback,
        .CopyToClipboard,
        .CursorShape,
        .Custom,
        .Disinter,
        .EndCopy,
        .HighlightCursorLine,
        .OpenURL,
        .PopKeyLabels,
        .PushKeyLabels,
        .RemoteHost,
        .ReportVariable,
        .RequestAttention,
        .RequestUpload,
        .SetBackgroundImageFile,
        .SetBadgeFormat,
        .SetColors,
        .SetKeyLabel,
        .SetMark,
        .SetProfile,
        .SetUserVar,
        .ShellIntegrationVersion,
        .StealFocus,
        .UnicodeVersion,
        => {
            log.debug("unimplemented OSC 1337: {t}", .{key});
            parser.command = .invalid;
            return null;
        },
    }
    return &parser.command;
}

fn terminatedValue(parser: *Parser, index: ?usize) ?[:0]const u8 {
    const start = (index orelse return null) + 1;
    const cap = &parser.capture.?;
    cap.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const bytes = cap.trailing();
    return bytes[start .. bytes.len - 1 :0];
}

fn parseImage(key: Key, value: ?[]const u8) ?InlineImage {
    return switch (key) {
        .File => file: {
            const body = value orelse return null;
            const delimiter = std.mem.indexOfScalar(u8, body, ':') orelse return null;
            const data = body[delimiter + 1 ..];
            if (data.len == 0) return null;
            break :file .{ .file = .{
                .options = parseOptions(body[0..delimiter]) orelse return null,
                .data = data,
            } };
        },
        .MultipartFile => .{ .multipart_file = parseOptions(value orelse return null) orelse return null },
        .FilePart => part: {
            const data = value orelse return null;
            if (data.len == 0) return null;
            break :part .{ .file_part = data };
        },
        .FileEnd => if (value == null) .file_end else null,
        else => unreachable,
    };
}

fn parseOptions(data: []const u8) ?ImageOptions {
    var result: ImageOptions = .{};
    var inline_display = false;
    var args = std.mem.splitScalar(u8, data, ';');
    while (args.next()) |arg| {
        if (arg.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
        const key = arg[0..eq];
        const value = arg[eq + 1 ..];
        if (std.mem.eql(u8, key, "inline")) {
            inline_display = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "width")) {
            result.width = parseDimension(value) orelse return null;
        } else if (std.mem.eql(u8, key, "height")) {
            result.height = parseDimension(value) orelse return null;
        } else if (std.mem.eql(u8, key, "preserveAspectRatio")) {
            result.preserve_aspect_ratio = !std.mem.eql(u8, value, "0");
        } else if (std.mem.eql(u8, key, "doNotMoveCursor")) {
            result.do_not_move_cursor = std.mem.eql(u8, value, "1");
        }
        // Filename and size are for non-inline downloads or progress UI.
    }
    return if (inline_display) result else null;
}

fn parseDimension(data: []const u8) ?ImageDimension {
    if (std.mem.eql(u8, data, "auto")) return .auto;
    const kind: enum { cells, pixels, percent }, const num: []const u8 =
        if (std.mem.endsWith(u8, data, "px")) .{ .pixels, data[0 .. data.len - 2] } else if (std.mem.endsWith(u8, data, "%")) .{ .percent, data[0 .. data.len - 1] } else .{ .cells, data };
    const value = lib.parseInt(u32, num, 10) catch return null;
    if (value == 0) return null;
    return switch (kind) {
        .cells => .{ .cells = value },
        .pixels => .{ .pixels = value },
        .percent => .{ .percent = value },
    };
}

test "OSC: 1337: test valid unimplemented key with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid unimplemented key with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid unimplemented key with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with only prefix colon" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with question mark" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:?";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is invalid base64" {
    // For performance reasons, we don't check for valid base64 data
    // right now.
    return error.SkipZigTest;

    // const testing = std.testing;

    // var p: Parser = .init(testing.allocator);
    // defer p.deinit();

    // const input = "1337;Copy=:abc123";
    // for (input) |ch| p.next(ch);

    // try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is valid base64 but not prefixed with a colon" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=YWJjMTIz";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is valid base64" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:YWJjMTIz";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expectEqual('c', cmd.clipboard_contents.kind);
    try testing.expectEqualStrings("YWJjMTIz", cmd.clipboard_contents.data);
}

test "OSC: 1337: test CurrentDir with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test CurrentDir with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test CurrentDir with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir=abc123";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .report_pwd);
    try testing.expectEqualStrings("abc123", cmd.report_pwd.value);
}

test "OSC 1337 ReportCellSize requires a bare request and preserves the terminator" {
    const testing = std.testing;
    var p: Parser = .init(null);
    defer p.deinit();

    p.nextSlice("1337;ReportCellSize");
    try testing.expectEqual(Terminator.bel, p.end(0x07).?.iterm_report_cell_size);
    p.reset();
    p.nextSlice("1337;reportcellsize");
    try testing.expectEqual(Terminator.st, p.end('\\').?.iterm_report_cell_size);
    p.reset();
    p.nextSlice("1337;ReportCellSize=20;10;1.0");
    try testing.expect(p.end('\\') == null);
}

test "OSC 1337 File and multipart packets retain metadata and encoded data" {
    const testing = std.testing;
    var p: Parser = .init(null);
    defer p.deinit();

    p.nextSlice("1337;File=name=YQ==;size=1;width=4;height=16px;inline=1;preserveAspectRatio=0;doNotMoveCursor=1:QQ==");
    const file = p.end('\\').?.iterm_inline_image.file;
    try testing.expectEqualDeep(ImageOptions{
        .width = .{ .cells = 4 },
        .height = .{ .pixels = 16 },
        .preserve_aspect_ratio = false,
        .do_not_move_cursor = true,
    }, file.options);
    try testing.expectEqualStrings("QQ==", file.data);

    p.reset();
    p.nextSlice("1337;MultipartFile=width=25%;height=auto;inline=1;");
    const options = p.end(0x07).?.iterm_inline_image.multipart_file;
    try testing.expectEqualDeep(ImageOptions{ .width = .{ .percent = 25 } }, options);

    p.reset();
    p.nextSlice("1337;FilePart=YWJj");
    try testing.expectEqualStrings("YWJj", p.end('\\').?.iterm_inline_image.file_part);
    p.reset();
    p.nextSlice("1337;FileEnd");
    try testing.expect(p.end('\\').?.iterm_inline_image == .file_end);
}

test "OSC 1337 malformed image packets cancel multipart" {
    const testing = std.testing;
    var p: Parser = .init(null);
    defer p.deinit();
    const malformed = [_][]const u8{
        "1337;File=inline=1",
        "1337;File=inline=0:QQ==",
        "1337;File=inline=1:",
        "1337;MultipartFile=name=YQ==;width=2",
        "1337;MultipartFile=inline=1;height=4294967296px",
        "1337;MultipartFile=inline=1;width=0",
        "1337;MultipartFile=inline=1;width=4_2%",
        "1337;FilePart",
        "1337;FilePart=",
        "1337;FileEnd=unexpected",
    };
    for (malformed) |input| {
        p.reset();
        p.nextSlice(input);
        try testing.expect(p.end('\\').?.iterm_inline_image == .cancel);
    }
    p.reset();
    p.nextSlice("1337;FilePart=YWJj");
    try testing.expect(p.end(0x18).?.iterm_inline_image == .cancel);
}

test "OSC 1337 promotes only large image data and enforces its bounds" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    var data: [4096]u8 = @splat('A');
    data[Parser.MAX_BUF - 1] = '/';
    data[Parser.MAX_BUF + 1] = 'B';
    data[data.len - 1] = '=';

    p.nextSlice("1337;File=inline=1:");
    p.nextSlice(&data);
    try testing.expectEqualSlices(u8, &data, p.end('\\').?.iterm_inline_image.file.data);

    p.reset();
    p.nextSlice("1337;FilePart=");
    for (data) |byte| p.next(byte);
    try testing.expectEqualSlices(u8, &data, p.end('\\').?.iterm_inline_image.file_part);

    p.reset();
    p.max_allocating_bytes = Parser.MAX_BUF + 4;
    p.nextSlice("1337;FilePart=");
    p.nextSlice(&data);
    try testing.expectEqual(Parser.State.iterm2_image_discard, p.state);
    try testing.expect(p.end('\\').?.iterm_inline_image == .cancel);

    p.reset();
    p.max_allocating_bytes = Parser.MAX_BUF - 16;
    p.nextSlice("1337;File=inline=1:");
    p.nextSlice(data[0 .. Parser.MAX_BUF - 20]);
    try testing.expect(p.end('\\').?.iterm_inline_image == .cancel);

    p.reset();
    p.nextSlice("1337;Copy=:");
    p.nextSlice(&data);
    try testing.expect(p.end('\\') == null);
    p.reset();
    p.nextSlice("1337;CurrentDir=");
    p.nextSlice(&data);
    try testing.expect(p.end('\\') == null);
}
