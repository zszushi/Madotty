//! Catalog and config values for the WinUI terminal-theme picker.
const std = @import("std");
const cli = @import("../../cli.zig");
const Config = @import("../../config.zig").Config;
const themes = @import("../../config/theme.zig");
const global = @import("../../global.zig");
const w32 = @import("win32.zig");

const Allocator = std.mem.Allocator;
const Source = enum { user, bundled };
const Item = struct {
    name: []const u8,
    value: []const u8,
    source: Source,
};

pub const Page = struct {
    items: []const Item,
    next_offset: ?u32 = null,
};

const Candidate = struct {
    name: []const u8,
    wide: []const u16,
    source: Source,

    fn compareName(a: Candidate, b: Candidate) i32 {
        return w32.CompareStringOrdinal(a.wide.ptr, @intCast(a.wide.len), b.wide.ptr, @intCast(b.wide.len), 1);
    }

    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
        switch (a.compareName(b)) {
            1 => return true,
            3 => return false,
            else => {},
        }
        // The same name resolves to the user directory before resources.
        if (a.source != b.source) return a.source == .user;
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub fn page(alloc: Allocator, offset: u32, byte_budget: usize) !Page {
    const io = global.io();
    var locations: themes.LocationIterator = .{ .arena_alloc = alloc };
    var candidates: std.ArrayList(Candidate) = .empty;
    while (try locations.next()) |loc| {
        const dir = std.Io.Dir.cwd().openDir(io, loc.dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        try collect(alloc, io, dir, switch (loc.location) {
            .user => .user,
            .resources => .bundled,
        }, &candidates);
    }
    return makePage(alloc, candidates.items, offset, byte_budget);
}

fn collect(alloc: Allocator, io: std.Io, dir: std.Io.Dir, source: Source, list: *std.ArrayList(Candidate)) !void {
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, ".DS_Store") or !validValue(entry.name)) continue;
        try list.append(alloc, .{
            .name = try alloc.dupe(u8, entry.name),
            .wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, entry.name),
            .source = source,
        });
    }
}

fn makePage(alloc: Allocator, names: []Candidate, offset: u32, byte_budget: usize) !Page {
    std.mem.sortUnstable(Candidate, names, {}, Candidate.lessThan);
    var items: std.ArrayList(Item) = .empty;
    var remaining = byte_budget;
    var previous: ?Candidate = null;
    var index: u32 = 0;
    for (names) |name| {
        if (previous) |prev| {
            if (prev.compareName(name) == 2) continue;
        }
        previous = name;
        if (index < offset) {
            index += 1;
            continue;
        }
        const item: Item = .{
            .name = name.name,
            .value = (try format(alloc, .{ .light = name.name, .dark = name.name })).?,
            .source = name.source,
        };
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try std.json.Stringify.value(item, .{}, &counter.writer);
        const size = counter.fullCount() + @intFromBool(items.items.len != 0);
        if (size > remaining) {
            if (items.items.len == 0) return error.ThemeCatalogItemTooLarge;
            return .{ .items = items.items, .next_offset = index };
        }
        remaining -= @intCast(size);
        try items.append(alloc, item);
        index += 1;
    }
    return .{ .items = items.items };
}

fn validValue(value: []const u8) bool {
    return value.len <= cli.args.LineIterator.MAX_LINE_SIZE - 16 and
        std.mem.indexOfAny(u8, value, "\x00\r\n") == null and
        std.unicode.utf8ValidateSlice(value);
}

pub fn parse(alloc: Allocator, value: []const u8) !?Config.Theme {
    if (value.len == 0) return null;
    if (!validValue(value)) return error.InvalidTerminalTheme;
    var result: Config.Theme = undefined;
    result.parseCLI(alloc, value) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidTerminalTheme,
    };
    for ([_][]const u8{ result.light, result.dark }) |name| {
        if (name.len == 0 or !validValue(name)) return error.InvalidTerminalTheme;
    }
    try result.finalize(alloc);
    return result;
}

pub fn requireAvailable(alloc: Allocator, selection: ?Config.Theme) !void {
    const chosen = selection orelse return;
    var diagnostics: cli.DiagnosticList = .{};
    const light = try themes.open(alloc, chosen.light, &diagnostics) orelse return error.TerminalThemeUnavailable;
    light.file.close(global.io());
    if (std.mem.eql(u8, chosen.light, chosen.dark)) return;
    const dark = try themes.open(alloc, chosen.dark, &diagnostics) orelse return error.TerminalThemeUnavailable;
    dark.file.close(global.io());
}

pub fn equal(a: ?Config.Theme, b: ?Config.Theme) bool {
    const first = a orelse return b == null;
    const second = b orelse return false;
    return std.mem.eql(u8, first.light, second.light) and std.mem.eql(u8, first.dark, second.dark);
}

pub fn format(alloc: Allocator, selection: ?Config.Theme) !?[]const u8 {
    const chosen = selection orelse return null;
    if (!validValue(chosen.light) or !validValue(chosen.dark)) return error.InvalidTerminalTheme;
    if (std.mem.eql(u8, chosen.light, chosen.dark) and plainSingle(chosen.light)) return chosen.light;
    var value: std.Io.Writer.Allocating = .init(alloc);
    errdefer value.deinit();
    try value.writer.writeAll("light:");
    try writePairName(&value.writer, chosen.light);
    try value.writer.writeAll(",dark:");
    try writePairName(&value.writer, chosen.dark);
    if (!validValue(value.written())) return error.InvalidTerminalTheme;
    return try value.toOwnedSlice();
}

fn plainSingle(name: []const u8) bool {
    if (needsQuoting(name) or std.mem.indexOfScalar(u8, name, '=') != null) return false;
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return true;
    return colon == 1; // Windows drive letter.
}

fn needsQuoting(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, ",\"") != null or
        std.mem.trim(u8, name, cli.args.whitespace).len != name.len;
}

fn writePairName(writer: *std.Io.Writer, name: []const u8) !void {
    if (needsQuoting(name))
        try writer.print("\"{f}\"", .{std.zig.fmtString(name)})
    else
        try writer.writeAll(name);
}

test "win32 themes catalog uses user priority and stable byte paging" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testing.io;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "user");
    try temp.dir.createDirPath(io, "bundled");
    const user = try temp.dir.openDir(io, "user", .{ .iterate = true });
    defer user.close(io);
    const bundled = try temp.dir.openDir(io, "bundled", .{ .iterate = true });
    defer bundled.close(io);
    try user.writeFile(io, .{ .sub_path = "bLue", .data = "" });
    try user.writeFile(io, .{ .sub_path = "Rose, Dark", .data = "" });
    try bundled.writeFile(io, .{ .sub_path = "Atom", .data = "" });
    try bundled.writeFile(io, .{ .sub_path = "Blue", .data = "" });
    try bundled.writeFile(io, .{ .sub_path = ".DS_Store", .data = "" });
    try user.createDirPath(io, "Not a file");

    var entries: std.ArrayList(Candidate) = .empty;
    try collect(alloc, io, bundled, .bundled, &entries);
    try collect(alloc, io, user, .user, &entries);
    const first = try makePage(alloc, entries.items, 0, 80);
    try testing.expectEqual(@as(usize, 1), first.items.len);
    try testing.expectEqualStrings("Atom", first.items[0].name);
    try testing.expectEqual(Source.bundled, first.items[0].source);
    try testing.expectEqual(@as(?u32, 1), first.next_offset);
    const second = try makePage(alloc, entries.items, first.next_offset.?, 1024);
    try testing.expectEqual(@as(usize, 2), second.items.len);
    try testing.expectEqualStrings("bLue", second.items[0].name);
    try testing.expectEqual(Source.user, second.items[0].source);
    try testing.expectEqualStrings("light:\"Rose, Dark\",dark:\"Rose, Dark\"", second.items[1].value);
    try testing.expectEqual(null, second.next_offset);
}

test "win32 themes round trip native names paths and quoted pairs" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const pair: Config.Theme = .{ .light = "Day Theme", .dark = "C:\\Themes\\Dark, Contrast" };
    const pair_text = (try format(alloc, pair)).?;
    try testing.expect(equal(pair, try parse(alloc, pair_text)));
    const single: Config.Theme = .{ .light = "Lunar=B", .dark = "Lunar=B" };
    try testing.expect(equal(single, try parse(alloc, (try format(alloc, single)).?)));
    try testing.expectEqualStrings("C:\\Themes\\Single", (try format(alloc, try parse(alloc, "C:\\Themes\\Single"))).?);
    try testing.expectEqual(null, try parse(alloc, ""));
    try testing.expectError(error.InvalidTerminalTheme, parse(alloc, "light:Day Only"));
    try testing.expectError(error.InvalidTerminalTheme, parse(alloc, "Day\ncommand = invalid"));
    try testing.expectError(error.InvalidTerminalTheme, parse(alloc, "light:\"line\\nbreak\",dark:Day"));
}
