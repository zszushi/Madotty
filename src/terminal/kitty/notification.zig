//! State for Kitty OSC 99 desktop notifications.
const std = @import("std");
const Allocator = std.mem.Allocator;
const osc = @import("../osc.zig");
const encoding = @import("../osc/encoding.zig");
const metadata = @import("../osc/kitty_metadata.zig");
const parser = @import("../osc/parsers/kitty_desktop_notification.zig");

const max_pending = 16;
const max_id_bytes = 512;
const max_text_bytes = 4096;
const capabilities = "o=always,unfocused,invisible:p=title,body";

pub const Options = struct {
    focused: bool = true,
    visible: bool = true,
    available: bool = true,

    fn allows(self: Options, occasion: parser.Occasion) bool {
        return switch (occasion) {
            .always => true,
            .unfocused => !self.focused,
            .invisible => !self.focused and !self.visible,
        };
    }
};

pub const Notification = struct {
    title: []u8,
    body: []u8,
};

pub const Result = union(enum) {
    ignored,
    reply: []u8,
    notification: Notification,

    pub fn deinit(self: Result, alloc: Allocator) void {
        switch (self) {
            .ignored => {},
            .reply => |value| alloc.free(value),
            .notification => |value| {
                alloc.free(value.title);
                alloc.free(value.body);
            },
        }
    }
};

pub const State = struct {
    pending: std.ArrayList(Pending) = .empty,

    pub fn deinit(self: *State, alloc: Allocator) void {
        for (self.pending.items) |*entry| entry.deinit(alloc);
        self.pending.deinit(alloc);
        self.* = .{};
    }

    pub fn handle(
        self: *State,
        alloc: Allocator,
        request: osc.Command.KittyDesktopNotification,
        options: Options,
    ) Allocator.Error!Result {
        if (!options.available) return .ignored;
        const id = request.readOption(.i) orelse "";
        if (id.len > max_id_bytes) return .ignored;

        const payload_type = request.readOption(.p);
        switch (payload_type) {
            .query => {
                // The reply uses the same metadata as the request. Only an
                // empty payload is a query, so echoed replies are inert.
                if (request.payload.len != 0) return .ignored;
                return .{ .reply = try std.fmt.allocPrint(
                    alloc,
                    "\x1b]99;i={s}:p=?;" ++ capabilities ++ "{s}",
                    .{ if (id.len == 0) "0" else id, request.terminator.string() },
                ) };
            },
            .title, .body => {},
            .alive, .buttons, .close, .icon, .unknown => return .ignored,
        }

        const encoded = request.readOption(.e);
        const text = request.payload;
        const occasion = requestedOccasion(request.metadata);
        const done = request.readOption(.d);
        if (self.find(id)) |i| {
            if (!try self.pending.items[i].append(alloc, payload_type, text, encoded, occasion)) return .ignored;
            if (!done) return .ignored;

            var entry = self.pending.orderedRemove(i);
            defer entry.deinit(alloc);
            return entry.finish(alloc, options);
        }

        // The blank ID is a single anonymous in-flight notification.
        var entry: Pending = .{};
        defer entry.deinit(alloc);
        if (!try entry.append(alloc, payload_type, text, encoded, occasion)) return .ignored;
        if (done) return entry.finish(alloc, options);

        entry.id = try alloc.dupe(u8, id);
        if (self.pending.items.len == max_pending) {
            var oldest = self.pending.orderedRemove(0);
            oldest.deinit(alloc);
        }
        try self.pending.append(alloc, entry);
        entry = .{};
        return .ignored;
    }

    fn find(self: *const State, id: []const u8) ?usize {
        for (self.pending.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, id)) return i;
        }
        return null;
    }
};

const Pending = struct {
    id: []const u8 = "",
    title: Text = .{},
    body: Text = .{},
    occasion: parser.Occasion = .always,

    fn deinit(self: *Pending, alloc: Allocator) void {
        alloc.free(self.id);
        self.title.bytes.deinit(alloc);
        self.body.bytes.deinit(alloc);
    }

    fn append(
        self: *Pending,
        alloc: Allocator,
        payload_type: parser.Payload,
        text: []const u8,
        encoded: bool,
        occasion: ?parser.Occasion,
    ) Allocator.Error!bool {
        const field = switch (payload_type) {
            .title => &self.title,
            .body => &self.body,
            else => unreachable,
        };
        if (encoded) {
            if (!try field.appendEncoded(alloc, text)) return false;
        } else {
            if (text.len > parser.MAX_PLAIN_PAYLOAD_BYTES or !encoding.isSafeUtf8(text)) return false;
            if (!try field.flushEncoded(alloc)) return false;
            try field.append(alloc, text);
        }
        if (occasion) |value| self.occasion = value;
        return true;
    }

    fn finish(self: *Pending, alloc: Allocator, options: Options) Allocator.Error!Result {
        if (!options.allows(self.occasion) or
            !try self.title.flushEncoded(alloc) or !try self.body.flushEncoded(alloc) or
            !self.title.finish() or !self.body.finish()) return .ignored;
        if (self.title.bytes.items.len == 0) {
            if (self.body.bytes.items.len == 0) return .ignored;
            std.mem.swap(Text, &self.title, &self.body);
        }
        const title = try self.title.bytes.toOwnedSlice(alloc);
        errdefer alloc.free(title);
        return .{ .notification = .{
            .title = title,
            .body = try self.body.bytes.toOwnedSlice(alloc),
        } };
    }
};

const Text = struct {
    bytes: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    // A Base64 quantum can span several OSC chunks.
    encoded_tail: [3]u8 = undefined,
    encoded_len: u2 = 0,

    fn append(self: *Text, alloc: Allocator, text: []const u8) Allocator.Error!void {
        if (self.truncated) return;
        const len = @min(text.len, max_text_bytes - self.bytes.items.len);
        try self.bytes.appendSlice(alloc, text[0..len]);
        self.truncated = len != text.len;
    }

    fn appendEncoded(self: *Text, alloc: Allocator, text: []const u8) Allocator.Error!bool {
        if (self.truncated) return true;
        const alphabet = std.base64.standard.alphabet_chars ++ [_]u8{'='};
        if (text.len > parser.MAX_ENCODED_PAYLOAD_BYTES or
            std.mem.indexOfNone(u8, text, &alphabet) != null) return false;

        var storage: [parser.MAX_ENCODED_PAYLOAD_BYTES + 3]u8 = undefined;
        const input = storage[0 .. @as(usize, self.encoded_len) + text.len];
        @memcpy(input[0..self.encoded_len], self.encoded_tail[0..self.encoded_len]);
        @memcpy(input[self.encoded_len..], text);
        const complete = input[0 .. input.len - input.len % 4];
        const remaining = input[complete.len..];
        if (remaining.len != 0 and complete.len != 0 and complete[complete.len - 1] == '=') return false;

        var output: [parser.MAX_ENCODED_PAYLOAD_BYTES / 4 * 3]u8 = undefined;
        const decoder = std.base64.standard.Decoder;
        const decoded = output[0 .. decoder.calcSizeForSlice(complete) catch return false];
        decoder.decode(decoded, complete) catch return false;
        try self.append(alloc, decoded);
        @memcpy(self.encoded_tail[0..remaining.len], remaining);
        self.encoded_len = @intCast(remaining.len);
        return true;
    }

    fn flushEncoded(self: *Text, alloc: Allocator) Allocator.Error!bool {
        if (self.encoded_len == 0 or self.truncated) return true;
        // OSC 99 also permits omitting the padding on the final quantum.
        const decoder = std.base64.standard_no_pad.Decoder;
        const encoded = self.encoded_tail[0..self.encoded_len];
        var tail: [2]u8 = undefined;
        const decoded = tail[0 .. decoder.calcSizeForSlice(encoded) catch return false];
        decoder.decode(decoded, encoded) catch return false;
        try self.append(alloc, decoded);
        self.encoded_len = 0;
        return true;
    }

    fn finish(self: *Text) bool {
        // Decoded text may contain line breaks, but the desktop notification
        // effects that store NUL-terminated strings cannot carry embedded NUL.
        if (std.mem.indexOfScalar(u8, self.bytes.items, 0) != null) return false;
        if (std.unicode.utf8ValidateSlice(self.bytes.items)) return true;
        if (!self.truncated) return false;

        // A four-byte UTF-8 sequence at the cap can leave up to three bytes.
        const max_excess: usize = @min(self.bytes.items.len, 3);
        for (1..max_excess + 1) |excess| {
            const prefix = self.bytes.items[0 .. self.bytes.items.len - excess];
            if (!std.unicode.utf8ValidateSlice(prefix)) continue;
            self.bytes.items.len = prefix.len;
            return true;
        }
        return false;
    }
};

fn requestedOccasion(values: []const u8) ?parser.Occasion {
    // The parser's readOption applies the default when omitted. On a later
    // chunk, an omitted occasion must preserve the earlier explicit value.
    var iterator: metadata.ValueIterator("o", "abcdefghijklmnopqrstuvwxyz") = .init(values);
    const value = iterator.next() orelse return null;
    return std.meta.stringToEnum(parser.Occasion, value);
}

const testing = std.testing;

fn expectIgnored(result: Result) !void {
    defer result.deinit(testing.allocator);
    try testing.expect(result == .ignored);
}

fn expectNotification(result: Result, title: []const u8, body: []const u8) !void {
    defer result.deinit(testing.allocator);
    try testing.expect(result == .notification);
    try testing.expectEqualStrings(title, result.notification.title);
    try testing.expectEqualStrings(body, result.notification.body);
}

fn command(values: []const u8, text: []const u8) parser.OSC {
    return .{ .metadata = values, .payload = text, .terminator = .st };
}

test "OSC 99 notification capability reply and echo" {
    const alloc = testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    var osc_parser: osc.Parser = .init(alloc);
    defer osc_parser.deinit();

    for ("99;i=terminal.test:p=?;") |byte| osc_parser.next(byte);
    const request = osc_parser.end('\x1b').?.kitty_desktop_notification;
    const st = try state.handle(alloc, request, .{});
    defer st.deinit(alloc);
    try testing.expect(st == .reply);
    try testing.expectEqualStrings("\x1b]99;i=terminal.test:p=?;o=always,unfocused,invisible:p=title,body\x1b\\", st.reply);

    osc_parser.reset();
    for (st.reply[2 .. st.reply.len - 2]) |byte| osc_parser.next(byte);
    const echoed = osc_parser.end('\x1b').?.kitty_desktop_notification;
    try expectIgnored(try state.handle(alloc, echoed, .{}));

    const bel = try state.handle(alloc, .{
        .metadata = "i=invalid/id:p=?",
        .payload = "",
        .terminator = .bel,
    }, .{});
    defer bel.deinit(alloc);
    try testing.expect(bel == .reply);
    try testing.expectEqualStrings("\x1b]99;i=0:p=?;o=always,unfocused,invisible:p=title,body\x07", bel.reply);
    try expectIgnored(try state.handle(alloc, command("i=blocked:p=?", ""), .{ .available = false }));
}

test "OSC 99 notification assembles independent identified titles and bodies" {
    const alloc = testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try expectIgnored(try state.handle(alloc, command("i=one:d=0", "Hello"), .{}));
    try expectIgnored(try state.handle(alloc, command("i=two:d=0", "Second"), .{}));
    try expectIgnored(try state.handle(alloc, command("i=one:d=0", " world"), .{}));
    try expectNotification(try state.handle(alloc, command("i=two:p=body", "Separate"), .{}), "Second", "Separate");
    try expectNotification(try state.handle(alloc, command("i=one:p=body:e=1", "4pyTCnJlYWR5"), .{}), "Hello world", "✓\nready");
    try expectNotification(try state.handle(alloc, command("i=one:p=body", "Fresh"), .{}), "Fresh", "");
    try expectIgnored(try state.handle(alloc, command("p=body", ""), .{}));
    try expectIgnored(try state.handle(alloc, command("p=icon", "Unsupported"), .{}));
    try expectIgnored(try state.handle(alloc, command("i=bad:e=1", "!bad"), .{}));
    try expectIgnored(try state.handle(alloc, command("i=bad:e=1", "/w=="), .{}));
    try expectIgnored(try state.handle(alloc, command("i=bad:e=1", "AA=="), .{}));
    try expectIgnored(try state.handle(alloc, command("e=1:d=0", "MTLi"), .{}));
    try expectIgnored(try state.handle(alloc, command("e=1:d=0", "n"), .{}));
    try expectNotification(try state.handle(alloc, command("e=1", "JM"), .{}), "12✓", "");
    try testing.expectEqual(0, state.pending.items.len);
}

test "OSC 99 notification occasions apply to the completed message" {
    const alloc = testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try expectIgnored(try state.handle(alloc, command("i=pending:d=0:o=unfocused", "Title"), .{}));
    try expectIgnored(try state.handle(alloc, command("i=pending:p=body", "Body"), .{}));
    try expectIgnored(try state.handle(alloc, command("i=hidden:p=body:o=invisible", "Visible"), .{ .focused = false }));
    try expectNotification(try state.handle(alloc, command("o=invisible", "Hidden"), .{
        .focused = false,
        .visible = false,
    }), "Hidden", "");
    try expectIgnored(try state.handle(alloc, command("i=pending:d=0:o=unfocused", "Title"), .{}));
    try expectNotification(try state.handle(alloc, command("i=pending:p=body:o=always", "Body"), .{}), "Title", "Body");
}

test "OSC 99 notification bounds in-flight IDs and keeps a valid UTF-8 prefix" {
    const alloc = testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    for (0..max_pending + 1) |i| {
        var buffer: [50]u8 = undefined;
        const values = try std.fmt.bufPrint(&buffer, "i={d}:d=0", .{i});
        try expectIgnored(try state.handle(alloc, command(values, "Pending"), .{}));
    }
    try testing.expectEqual(max_pending, state.pending.items.len);
    try expectNotification(try state.handle(alloc, command("i=0:p=body", "Evicted"), .{}), "Evicted", "");
    try expectNotification(try state.handle(alloc, command("i=1:p=body", "Second"), .{}), "Pending", "Second");

    const initial: [parser.MAX_PLAIN_PAYLOAD_BYTES]u8 = @splat('a');
    const second: [max_text_bytes - parser.MAX_PLAIN_PAYLOAD_BYTES - 1]u8 = @splat('b');
    try expectIgnored(try state.handle(alloc, command("i=long:d=0", &initial), .{}));
    try expectIgnored(try state.handle(alloc, command("i=long:d=0", &second), .{}));
    try expectIgnored(try state.handle(alloc, command("i=long:d=0", "✓"), .{}));
    try expectNotification(try state.handle(alloc, command("i=long", "C"), .{}), &(initial ++ second), "");
}
