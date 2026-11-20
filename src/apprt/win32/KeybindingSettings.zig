//! Read the effective key tables for the Windows Settings companion.
const std = @import("std");
const Config = @import("../../config.zig").Config;
const Binding = @import("../../input.zig").Binding;
const Command = @import("../../input.zig").Command;
const PageError = std.mem.Allocator.Error || std.Io.Writer.Error || error{KeybindingTooLarge};

pub const Page = struct {
    rows: []const Row,
    next_offset: ?u32 = null,
};

const Row = struct {
    trigger: []const u8,
    table: ?[]const u8,
    actions: []const []const u8,
    titles: []const []const u8,
    builtin_titles: []const bool,
    global: bool,
    all: bool,
    consumed: bool,
    performable: bool,
};

/// Traverse tables in config order so offsets are stable for the same config.
/// The byte budget covers serialized rows and their separators.
pub fn page(alloc: std.mem.Allocator, config: *const Config, offset: u32, byte_budget: usize) !Page {
    var walker: Walker = .{
        .alloc = alloc,
        .commands = config.@"command-palette-entry".value.items,
        .builtin_count = config.@"command-palette-entry".builtin_count,
        .offset = offset,
        .remaining = byte_budget,
        .trigger = .init(alloc),
    };
    defer walker.trigger.deinit();

    var more = try walker.collect(&config.keybind.set, null);
    if (!more) {
        var tables = config.keybind.tables.iterator();
        while (tables.next()) |entry| {
            more = try walker.collect(entry.value_ptr, entry.key_ptr.*);
            if (more) break;
        }
    }
    return .{
        .rows = walker.rows.items,
        .next_offset = if (more) walker.index else null,
    };
}

const Walker = struct {
    alloc: std.mem.Allocator,
    commands: []const Command,
    builtin_count: usize,
    offset: u32,
    remaining: usize,
    trigger: std.Io.Writer.Allocating,
    rows: std.ArrayList(Row) = .empty,
    index: u32 = 0,

    /// Return true if the next row belongs on another page.
    fn collect(w: *Walker, set: *const Binding.Set, table: ?[]const u8) PageError!bool {
        const prefix = w.trigger.writer.end;
        defer w.trigger.writer.end = prefix;

        var bindings = set.bindings.iterator();
        while (bindings.next()) |entry| {
            w.trigger.writer.end = prefix;
            if (prefix != 0) try w.trigger.writer.writeByte('>');
            try w.trigger.writer.print("{f}", .{entry.key_ptr.*});
            const more = switch (entry.value_ptr.*) {
                .leader => |leader| try w.collect(leader, table),
                .leaf => |*leaf| try w.append(table, leaf.generic()),
                .leaf_chained => |*leaf| try w.append(table, leaf.generic()),
            };
            if (more) return true;
        }
        return false;
    }

    fn append(w: *Walker, table: ?[]const u8, leaf: Binding.Set.GenericLeaf) !bool {
        if (w.index < w.offset) {
            w.index += 1;
            return false;
        }

        const actions = leaf.actionsSlice();
        const values = try w.alloc.alloc([]const u8, actions.len);
        const titles = try w.alloc.alloc([]const u8, actions.len);
        const builtin_titles = try w.alloc.alloc(bool, actions.len);
        for (actions, values, titles, builtin_titles) |action, *value, *title, *builtin_title| {
            value.* = try std.fmt.allocPrint(w.alloc, "{f}", .{action});
            const index = w.commandIndex(action);
            title.* = if (index) |i| w.commands[i].title else "";
            builtin_title.* = if (index) |i| i < w.builtin_count else false;
        }
        var row: Row = .{
            .trigger = w.trigger.written(),
            .table = table,
            .actions = values,
            .titles = titles,
            .builtin_titles = builtin_titles,
            .global = leaf.flags.global,
            .all = leaf.flags.all,
            .consumed = leaf.flags.consumed,
            .performable = leaf.flags.performable,
        };

        // Count the real JSON encoding, including expanded control
        // characters in action values and table names.
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try std.json.Stringify.value(row, .{}, &counter.writer);
        const size = counter.fullCount() + @intFromBool(w.rows.items.len != 0);
        if (size > w.remaining) {
            if (w.rows.items.len == 0) return error.KeybindingTooLarge;
            return true;
        }
        w.remaining -= @intCast(size);
        row.trigger = try w.alloc.dupe(u8, row.trigger);
        try w.rows.append(w.alloc, row);
        w.index += 1;
        return false;
    }

    fn commandIndex(w: *const Walker, action: Binding.Action) ?usize {
        // More recent entries can give a keybind a user-defined label.
        var index = w.commands.len;
        while (index > 0) {
            index -= 1;
            const command = w.commands[index];
            if (command.action.equal(action)) return index;
        }
        return null;
    }
};

test "win32 keybindings include effective tables, sequences, flags and chains" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var config: Config = .{};
    try config.keybind.parseCLI(alloc, "all:global:ctrl+g=new_tab");
    try config.keybind.parseCLI(alloc, "unconsumed:performable:ctrl+j>k=copy_to_clipboard:plain");
    try config.keybind.parseCLI(alloc, "chain=paste_from_clipboard");
    try config.keybind.parseCLI(alloc, "nav/g>g=scroll_to_top");
    try config.keybind.parseCLI(alloc, "nav/z=new_window");
    try config.keybind.parseCLI(alloc, "nav/z=unbind");
    try config.@"command-palette-entry".init(alloc);
    try config.@"command-palette-entry".value.append(alloc, .{
        .title = "My paste action",
        .action = .paste_from_clipboard,
    });

    const result = try page(alloc, &config, 0, 8192);
    try testing.expectEqual(@as(usize, 3), result.rows.len);
    try testing.expectEqual(null, result.next_offset);
    try testing.expectEqualStrings("ctrl+g", result.rows[0].trigger);
    try testing.expectEqual(null, result.rows[0].table);
    try testing.expect(result.rows[0].global and result.rows[0].all);
    const chain = result.rows[1];
    try testing.expectEqualStrings("ctrl+j>k", chain.trigger);
    try testing.expect(!chain.consumed and chain.performable);
    try testing.expectEqual(@as(usize, 2), chain.actions.len);
    try testing.expectEqualStrings("copy_to_clipboard:plain", chain.actions[0]);
    try testing.expectEqualStrings("paste_from_clipboard", chain.actions[1]);
    try testing.expectEqualStrings("My paste action", chain.titles[1]);
    try testing.expectEqualSlices(bool, &.{ true, false }, chain.builtin_titles);
    try testing.expectEqualStrings("nav", result.rows[2].table.?);
    try testing.expectEqualStrings("g>g", result.rows[2].trigger);
}

test "win32 keybindings paginate by escaped JSON bytes" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var config: Config = .{};
    var text: [300]u8 = undefined;
    @memset(&text, '"');
    const action = try std.fmt.allocPrint(alloc, "text:{s}", .{&text});
    try config.keybind.parseCLI(alloc, try std.fmt.allocPrint(alloc, "ctrl+a={s}", .{action}));
    try config.keybind.parseCLI(alloc, try std.fmt.allocPrint(alloc, "nav/b={s}", .{action}));

    try testing.expectError(error.KeybindingTooLarge, page(alloc, &config, 0, 600));
    const first = try page(alloc, &config, 0, 1000);
    try testing.expectEqual(@as(usize, 1), first.rows.len);
    try testing.expectEqual(@as(?u32, 1), first.next_offset);
    try testing.expectEqualStrings("ctrl+a", first.rows[0].trigger);
    const second = try page(alloc, &config, first.next_offset.?, 1000);
    try testing.expectEqual(@as(usize, 1), second.rows.len);
    try testing.expectEqual(null, second.next_offset);
    try testing.expectEqualStrings("nav", second.rows[0].table.?);
    try testing.expectEqualStrings(action, second.rows[0].actions[0]);
    try testing.expectEqual(@as(usize, 0), (try page(alloc, &config, 2, 1000)).rows.len);
}
