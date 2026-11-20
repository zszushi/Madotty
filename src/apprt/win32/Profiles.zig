//! Discover local shell profiles when the new-tab menu opens.
const std = @import("std");
const lang = @import("UiLanguage.zig");
const global = @import("../../global.zig");
const w32 = @import("win32.zig");

const Allocator = std.mem.Allocator;
const ui = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.win32);
const Profiles = std.ArrayList(Profile);

pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    argv: []const [:0]const u8,
    alias: ?[]const u8 = null,
    stock_icon: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};

pub const Summary = struct { id: []const u8, alias: ?[]const u8, name: []const u8, icon: ?[]const u8, executable: []const u8 };

pub fn summarize(alloc: Allocator) ![]const Summary {
    const profiles = try discover(alloc);
    const result = try alloc.alloc(Summary, profiles.len);
    for (result, profiles) |*item, profile| item.* = .{ .id = profile.id, .alias = profile.alias, .name = profile.name, .icon = profile.icon, .executable = profile.argv[0] };
    return result;
}

pub fn resolve(alloc: Allocator, id: []const u8) !?Profile {
    if (id.len == 0) return null;
    return find(try discover(alloc), id);
}

fn find(profiles: []const Profile, id: []const u8) ?Profile {
    for (profiles) |profile| if (matchesId(profile, id)) return profile;
    return null;
}

fn matchesId(profile: Profile, id: []const u8) bool {
    return std.ascii.eqlIgnoreCase(profile.id, id) or (profile.alias != null and std.ascii.eqlIgnoreCase(profile.alias.?, id));
}

/// Profile identifiers are safe to write as unquoted Ghostty config values.
pub fn validId(id: []const u8) bool {
    if (id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != ':' and c != '-') return false;
    return true;
}

fn guidId(alloc: Allocator, prefix: []const u8, value: []const u8) !?[]const u8 {
    const guid = if (value.len == 38 and value[0] == '{' and value[37] == '}') value[1..37] else value;
    if (guid.len != 36) return null;
    for (guid, 0..) |c, i| switch (i) {
        8, 13, 18, 23 => if (c != '-') return null,
        else => if (!std.ascii.isHex(c)) return null,
    };
    const result = try alloc.alloc(u8, prefix.len + guid.len);
    @memcpy(result[0..prefix.len], prefix);
    for (result[prefix.len..], guid) |*out, c| out.* = std.ascii.toLower(c);
    return result;
}

extern "kernel32" fn ExpandEnvironmentStringsW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;
extern "shell32" fn CommandLineToArgvW([*:0]const u16, *i32) callconv(.winapi) ?[*][*:0]const u16;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn RegEnumKeyExW(w32.HKEY, u32, [*]u16, *u32, ?*u32, ?[*]u16, ?*u32, ?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn RegGetValueW(w32.HKEY, [*:0]const u16, [*:0]const u16, u32, ?*u32, *anyopaque, *u32) callconv(.winapi) u32;

const MenuItemInfo = extern struct {
    size: u32 = @sizeOf(MenuItemInfo),
    mask: u32 = 0x80, // MIIM_BITMAP
    kind: u32 = 0,
    state: u32 = 0,
    id: u32 = 0,
    submenu: ?w32.HMENU = null,
    checked_bitmap: ?w32.HANDLE = null,
    unchecked_bitmap: ?w32.HANDLE = null,
    data: usize = 0,
    text: ?[*]u16 = null,
    text_len: u32 = 0,
    bitmap: w32.HANDLE,
};

extern "user32" fn SetMenuItemInfoW(w32.HMENU, u32, i32, *const MenuItemInfo) callconv(.winapi) i32;
extern "user32" fn LoadImageW(?w32.HINSTANCE, [*:0]const u16, u32, i32, i32, u32) callconv(.winapi) ?w32.HANDLE;
extern "shell32" fn ExtractIconExW([*:0]const u16, i32, ?*?w32.HICON, *?w32.HICON, u32) callconv(.winapi) u32;
extern "user32" fn DrawIconEx(w32.HDC, i32, i32, w32.HICON, i32, i32, u32, ?w32.HBRUSH, u32) callconv(.winapi) i32;
extern "user32" fn DestroyIcon(w32.HICON) callconv(.winapi) i32;

fn shellIcon(alloc: Allocator, executable: [:0]const u8, custom: ?[]const u8, size: i32) ?w32.HICON {
    if (custom) |path| if (loadIcon(alloc, path, size)) |icon| return icon;
    const exe = resolveOnPath(alloc, executable) catch return null;
    return loadIcon(alloc, exe orelse return null, size);
}

pub const Shell = struct {
    id: u64,
    icon: ?w32.HICON,
    label: ?[]const u8 = null,

    pub fn draw(self: Shell, dc: w32.HDC, x: i32, y: i32, size: i32) bool {
        return DrawIconEx(dc, x, y, self.icon orelse return false, size, size, 0, null, 3) != 0;
    }
};

extern "kernel32" fn QueryFullProcessImageNameW(w32.HANDLE, u32, [*]u16, *u32) callconv(.winapi) i32;

/// The handle is borrowed from the pending console attachment.
pub fn clientExecutable(alloc: Allocator, client: w32.HANDLE) ?[:0]const u8 {
    var path: [32768]u16 = undefined;
    var len: u32 = path.len;
    if (QueryFullProcessImageNameW(client, 0, &path, &len) == 0 or len == 0) return null;
    return std.unicode.utf16LeToUtf8AllocZ(alloc, path[0..len]) catch null;
}

pub fn commandExecutable(arena: Allocator, command: @import("../../config.zig").Command) !?[:0]const u8 {
    return switch (command) {
        .direct => |args| if (args.len != 0) args[0] else return null,
        .shell => |line| exe: {
            if (std.mem.indexOfAny(u8, line, " \t\"") == null) break :exe line;
            const wide = try std.unicode.wtf8ToWtf16LeAlloc(arena, line);
            var it = try std.process.Args.Iterator.Windows.init(arena, wide);
            defer it.deinit();
            break :exe try arena.dupeSentinel(u8, it.next() orelse return null, 0);
        },
    };
}

// Icons are shared by panes and remain valid across tab moves. Resolve and
// extract them during launch, never during a hover or paint.
pub const ShellIcons = struct {
    handles: std.StringHashMapUnmanaged(?w32.HICON) = .empty,

    pub fn lookup(self: *ShellIcons, alloc: Allocator, arena: Allocator, exe: [:0]const u8, profile: ?Profile) !?Shell {
        const name = std.fs.path.basename(exe);
        const stem = if (std.ascii.endsWithIgnoreCase(name, ".exe")) name[0 .. name.len - 4] else name;
        const label = shellLabel(exe);
        if (profile == null and label == null) return null;
        const kind = try std.ascii.allocLowerString(arena, stem);
        const custom = if (profile) |p| p.icon else null;
        const key = try std.mem.concat(arena, u8, &.{ exe, "\x00", custom orelse "" });
        const entry = try self.handles.getOrPut(alloc, key);
        if (!entry.found_existing) {
            errdefer _ = self.handles.remove(key);
            const filename = if (std.fs.path.extension(exe).len == 0)
                try std.fmt.allocPrintSentinel(arena, "{s}.exe", .{exe}, 0)
            else
                exe;
            entry.key_ptr.* = try alloc.dupe(u8, key);
            entry.value_ptr.* = shellIcon(arena, filename, custom, 32);
        }
        return .{ .id = std.hash.Wyhash.hash(0, kind), .icon = entry.value_ptr.*, .label = label };
    }

    pub fn deinit(self: *ShellIcons, alloc: Allocator) void {
        var it = self.handles.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |icon| _ = DestroyIcon(icon);
            alloc.free(entry.key_ptr.*);
        }
        self.handles.deinit(alloc);
    }
};

pub fn executableLabel(exe: []const u8) []const u8 {
    return shellLabel(exe) orelse std.fs.path.basename(exe);
}

fn shellLabel(exe: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(exe);
    const stem = if (std.ascii.endsWithIgnoreCase(name, ".exe")) name[0 .. name.len - 4] else name;
    if (std.ascii.eqlIgnoreCase(stem, "cmd")) return lang.text("Command Prompt");
    if (std.ascii.eqlIgnoreCase(stem, "bash")) {
        if (std.ascii.findIgnoreCase(exe, "\\Git\\") != null or std.ascii.findIgnoreCase(exe, "/Git/") != null) return "Git Bash";
        return "Bash";
    }
    inline for (.{ .{ "pwsh", "PowerShell" }, .{ "powershell", "Windows PowerShell" }, .{ "wsl", "WSL" }, .{ "zsh", "Zsh" }, .{ "fish", "fish" }, .{ "nu", "Nushell" } }) |pair| {
        if (std.ascii.eqlIgnoreCase(stem, pair[0])) return pair[1];
    }
    return null;
}

test "tab bar title reads the handoff client process image and preserves unknown executable names" {
    const alloc = std.testing.allocator;
    const exe = clientExecutable(alloc, std.os.windows.GetCurrentProcess()) orelse return error.ClientImageUnavailable;
    defer alloc.free(exe);
    try std.testing.expect(std.fs.path.isAbsolute(exe));
    try std.testing.expectEqualStrings(std.fs.path.basename(exe), executableLabel(exe));
    try std.testing.expectEqualStrings("開発.exe", executableLabel("C:\\bin\\開発.exe"));
    try std.testing.expectEqualStrings(lang.text("Command Prompt"), executableLabel("C:\\Windows\\System32\\cmd.EXE"));
    try std.testing.expectEqualStrings("Windows PowerShell", executableLabel("powershell.exe"));
}

test "tab bar shell identity follows the executable across launch forms" {
    var icons: ShellIcons = .{};
    defer icons.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = (try icons.lookup(std.testing.allocator, a, (try commandExecutable(a, .{ .direct = &.{"cmd.exe"} })).?, null)).?;
    const quoted = (try icons.lookup(std.testing.allocator, a, (try commandExecutable(a, .{ .shell = "\"CMD.EXE\" /d" })).?, null)).?;
    try std.testing.expectEqual(plain.id, quoted.id);
    const other = (try icons.lookup(std.testing.allocator, a, (try commandExecutable(a, .{ .shell = "pwsh -NoLogo" })).?, null)).?;
    try std.testing.expect(other.id != plain.id);
    try std.testing.expectEqualStrings("PowerShell", other.label.?);
    try std.testing.expectEqualStrings(lang.text("Command Prompt"), plain.label.?);
    try std.testing.expectEqual(null, try icons.lookup(std.testing.allocator, a, (try commandExecutable(a, .{ .shell = "custom-program" })).?, null));
}

/// Keep the returned bitmap alive until the native popup menu is destroyed.
pub fn attachIcon(alloc: Allocator, menu: w32.HMENU, id: u32, profile: Profile, scale: f32) ?w32.HANDLE {
    const size: i32 = @intFromFloat(@round(16 * scale));
    const handle = shellIcon(alloc, profile.argv[0], profile.icon, size) orelse return null;
    defer _ = DestroyIcon(handle);

    const dc = w32.CreateCompatibleDC(null) orelse return null;
    defer _ = w32.DeleteDC(dc);
    const info: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = size, .biHeight = -size } };
    var bits: ?*anyopaque = null;
    const bitmap = w32.CreateDIBSection(dc, &info, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    const old = w32.SelectObject(dc, bitmap);
    const painted = DrawIconEx(dc, 0, 0, handle, size, size, 0, null, 3) != 0; // DI_NORMAL
    _ = w32.SelectObject(dc, old);
    if (painted and SetMenuItemInfoW(menu, id, 0, &.{ .bitmap = bitmap }) != 0) return bitmap;
    _ = w32.DeleteObject(bitmap);
    return null;
}

fn loadIcon(alloc: Allocator, path: []const u8, size: i32) ?w32.HICON {
    // Loading an icon is optional. Skip relative paths and app package URIs.
    if (path.len < 3 or path[1] != ':' or !std.fs.path.isAbsolute(path)) return null;
    const extension = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(extension, ".ico") and
        !std.ascii.eqlIgnoreCase(extension, ".exe") and
        !std.ascii.eqlIgnoreCase(extension, ".dll")) return null;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    if (std.ascii.eqlIgnoreCase(extension, ".ico")) {
        const icon = LoadImageW(null, wide, 1, size, size, 0x10) orelse return null;
        return @ptrCast(icon);
    }
    var icon: ?w32.HICON = null;
    if (ExtractIconExW(wide, 0, null, &icon, 1) == 0) return null;
    return icon;
}

/// The caller owns the arena that holds the list and its strings.
pub fn discover(alloc: Allocator) ![]const Profile {
    var list: Profiles = .empty;
    var system: [260]u16 = undefined;
    const length = w32.GetSystemDirectoryW(&system, system.len);
    if (length > 0 and length < system.len) {
        const dir = try std.unicode.utf16LeToUtf8Alloc(alloc, system[0..length]);
        try addShell(alloc, &list, "shell:windows-powershell", "Windows PowerShell", dir, "WindowsPowerShell\\v1.0\\powershell.exe", null);
        try addShell(alloc, &list, "shell:cmd", lang.text("Command Prompt"), dir, "cmd.exe", null);
        const wsl = try fullPath(alloc, dir, "wsl.exe");
        if (exists(wsl)) try discoverWsl(alloc, &list, wsl);
    }

    if (global.environ().getAlloc(alloc, "ProgramFiles")) |dir| {
        try addShell(alloc, &list, "shell:powershell", "PowerShell", dir, "PowerShell\\7\\pwsh.exe", null);
        try addShell(alloc, &list, "shell:git-bash", "Git Bash", dir, "Git\\bin\\bash.exe", "--login");
    } else |_| {}

    if (try packageDir(alloc, "Microsoft.PowerShell_8wekyb3d8bbwe")) |dir| {
        const executable = try fullPath(alloc, dir, "pwsh.exe");
        if (exists(executable)) {
            // WT assigns its preferred PowerShell GUID to the Store build.
            // Keep the previously saved Madotty ID on the standalone install.
            if (find(list.items, "shell:powershell") != null) {
                for (list.items) |*profile| {
                    if (!std.mem.eql(u8, profile.id, "shell:powershell")) continue;
                    profile.name = "PowerShell 7";
                    profile.alias = "wt:5fb123f1-af88-5b5c-8953-d14a8def1978";
                }
                try add(alloc, &list, .{ .id = "wt:574e775e-4f2a-5b96-ac1e-a2962a402336", .name = "PowerShell", .argv = try alloc.dupe([:0]const u8, &.{executable}), .stock_icon = "pwsh" });
            } else try addShell(alloc, &list, "shell:powershell", "PowerShell", dir, "pwsh.exe", null);
        }
    }
    if (find(list.items, "shell:powershell") == null) {
        if (try resolveOnPath(alloc, "pwsh.exe")) |path| {
            try add(alloc, &list, .{ .id = "shell:powershell", .name = "PowerShell", .argv = try alloc.dupe([:0]const u8, &.{path}) });
        }
    }
    if (global.environ().getAlloc(alloc, "ProgramData")) |data| {
        try discoverVisualStudio(alloc, &list, data);
        try readFragments(alloc, &list, data);
    } else |_| {}
    if (global.environ().getAlloc(alloc, "LOCALAPPDATA")) |local| {
        try readFragments(alloc, &list, local);
    } else |_| {}

    if (global.environ().getAlloc(alloc, "LOCALAPPDATA")) |local| {
        for ([_][]const u8{
            "Packages\\Microsoft.WindowsTerminal_8wekyb3d8bbwe\\LocalState",
            "Packages\\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\\LocalState",
            "Microsoft\\Windows Terminal",
        }) |dir| {
            const path = try std.fs.path.join(alloc, &.{ local, dir, "settings.json" });
            const source = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(1024 * 1024)) catch continue;
            try mergeTerminalProfiles(alloc, &list, source, .settings);
            break;
        }
    } else |_| {}

    if (try packageDir(alloc, "Microsoft.WindowsTerminal_8wekyb3d8bbwe")) |dir| {
        for (list.items) |*profile| {
            if (profile.icon != null) continue;
            const asset = profile.stock_icon orelse continue;
            const path = try fullPath(alloc, dir, try std.fmt.allocPrint(alloc, "ProfileIcons\\{s}.scale-200.png", .{asset}));
            if (exists(path)) profile.icon = path;
        }
    }
    return list.items;
}

extern "kernel32" fn GetPackagesByPackageFamily([*:0]const u16, *u32, ?[*][*:0]u16, *u32, ?[*]u16) callconv(.winapi) i32;
extern "kernel32" fn GetPackagePathByFullName([*:0]const u16, *u32, ?[*]u16) callconv(.winapi) i32;

fn packageDir(alloc: Allocator, comptime family: [:0]const u8) !?[]const u8 {
    var count: u32 = 0;
    var length: u32 = 0;
    if (GetPackagesByPackageFamily(ui(family), &count, null, &length, null) != 122 or count == 0) return null;
    const names = try alloc.alloc([*:0]u16, count);
    const buffer = try alloc.alloc(u16, length);
    if (GetPackagesByPackageFamily(ui(family), &count, names.ptr, &length, buffer.ptr) != 0) return null;
    for (names[0..count]) |name| {
        var size: u32 = 0;
        if (GetPackagePathByFullName(name, &size, null) != 122 or size == 0) continue;
        const path = try alloc.alloc(u16, size);
        if (GetPackagePathByFullName(name, &size, path.ptr) == 0) return try std.unicode.utf16LeToUtf8Alloc(alloc, path[0 .. size - 1]);
    }
    return null;
}

fn add(alloc: Allocator, list: *Profiles, profile: Profile) !void {
    if (find(list.items, profile.id) != null) return;
    var candidate = profile;
    if (candidate.stock_icon == null) candidate.stock_icon = if (std.mem.eql(u8, profile.id, "shell:cmd")) "{0caa0dad-35be-5f56-a8ff-afceeeaa6101}" else if (std.mem.eql(u8, profile.id, "shell:windows-powershell")) "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}" else if (std.mem.eql(u8, profile.id, "shell:powershell") or std.mem.eql(u8, profile.id, "wt:5fb123f1-af88-5b5c-8953-d14a8def1978")) "pwsh" else null;
    if (candidate.alias == null) candidate.alias = shellGuid(candidate.id);
    try list.append(alloc, candidate);
}

fn shellGuid(id: []const u8) ?[]const u8 {
    const ids = .{
        .{ "shell:cmd", "wt:0caa0dad-35be-5f56-a8ff-afceeeaa6101" },
        .{ "shell:windows-powershell", "wt:61c54bbd-c2c6-5271-96e7-009a87ff44bf" },
        .{ "shell:git-bash", "wt:2ece5bfe-50ed-5f3a-ab87-5cd4baafed2b" },
        .{ "shell:powershell", "wt:574e775e-4f2a-5b96-ac1e-a2962a402336" },
    };
    inline for (ids) |pair| if (std.mem.eql(u8, id, pair[0])) return pair[1];
    return null;
}

fn fullPath(alloc: Allocator, dir: []const u8, name: []const u8) ![:0]const u8 {
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    return alloc.dupeSentinel(u8, path, 0);
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(global.io(), path, .{}) catch return false;
    return true;
}

fn addShell(alloc: Allocator, list: *Profiles, id: []const u8, name: []const u8, dir: []const u8, file: []const u8, arg: ?[:0]const u8) !void {
    const exe = try fullPath(alloc, dir, file);
    if (!exists(exe)) return;
    const args: []const [:0]const u8 = if (arg) |value| &.{ exe, value } else &.{exe};
    try add(alloc, list, .{ .id = id, .name = name, .argv = try alloc.dupe([:0]const u8, args) });
}

fn discoverWsl(alloc: Allocator, list: *Profiles, exe: [:0]const u8) !void {
    var root: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, ui("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"), 0, w32.KEY_READ, &root) != 0) return;
    defer _ = w32.RegCloseKey(root);

    var index: u32 = 0;
    var found = false;
    while (true) : (index += 1) {
        var key: [256:0]u16 = undefined;
        var key_len: u32 = key.len;
        if (RegEnumKeyExW(root, index, &key, &key_len, null, null, null, null) != 0) break;
        key[key_len] = 0;
        var name_w: [256]u16 = undefined;
        var len: u32 = @sizeOf(@TypeOf(name_w));
        if (RegGetValueW(root, &key, ui("DistributionName"), 2, null, &name_w, &len) != 0 or len < 4) continue;
        const name = try std.unicode.utf16LeToUtf8Alloc(alloc, name_w[0 .. len / 2 - 1]);
        found = true;
        // Docker's internal distributions are services, not interactive shell profiles.
        if (std.mem.startsWith(u8, name, "docker-desktop")) continue;
        const key_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, key[0..key_len]);
        try add(alloc, list, .{
            .id = (try guidId(alloc, "wsl:", key_utf8)) orelse continue,
            .name = try std.fmt.allocPrint(alloc, "{s} (WSL)", .{name}),
            .argv = try alloc.dupe([:0]const u8, &.{ exe, "--distribution", try alloc.dupeSentinel(u8, name, 0), "--cd", "~" }),
        });
    }
    if (found) try add(alloc, list, .{ .id = "shell:wsl", .name = "WSL", .argv = try alloc.dupe([:0]const u8, &.{exe}) });
}

fn resolveOnPath(alloc: Allocator, name: [:0]const u8) !?[:0]const u8 {
    const filename = if (std.fs.path.extension(name).len == 0) try std.fmt.allocPrintSentinel(alloc, "{s}.exe", .{name}, 0) else name;
    if (std.fs.path.isAbsolute(filename)) return if (exists(filename)) filename else null;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return null;
    const path = global.environ().getAlloc(alloc, "PATH") catch return null;
    var dirs = std.mem.splitScalar(u8, path, ';');
    while (dirs.next()) |raw| {
        const dir = std.mem.trim(u8, raw, "\" ");
        if (!std.fs.path.isAbsolute(dir)) continue;
        const file = try fullPath(alloc, dir, filename);
        if (exists(file)) return file;
    }
    return null;
}

// Imported profiles can outlive their bootstrap scripts. Only inspect literal
// script paths at invocation positions. Never run a profile during discovery.
fn startupScriptExists(args: []const [:0]const u8) bool {
    const exe = std.fs.path.basename(args[0]);
    for (args[1..], 1..) |token, i| {
        if (i + 1 >= args.len) break;
        const cmd_script = std.ascii.eqlIgnoreCase(exe, "cmd.exe") and (std.ascii.eqlIgnoreCase(token, "/k") or std.ascii.eqlIgnoreCase(token, "/c"));
        const ps = std.ascii.eqlIgnoreCase(exe, "powershell.exe") or std.ascii.eqlIgnoreCase(exe, "pwsh.exe");
        const ps_file = ps and std.ascii.eqlIgnoreCase(token, "-File");
        const invocation = ps and i > 1 and std.ascii.eqlIgnoreCase(args[i - 1], "-Command") and std.mem.eql(u8, token, "&");
        if (!cmd_script and !ps_file and !invocation) continue;
        const path = std.mem.trim(u8, args[i + 1], "'");
        if (!std.fs.path.isAbsolute(path)) continue;
        const ext = std.fs.path.extension(path);
        if ((cmd_script and (std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd"))) or
            ((ps_file or invocation) and std.ascii.eqlIgnoreCase(ext, ".ps1"))) return exists(path);
    }
    return true;
}

fn member(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

fn string(value: std.json.Value) ?[]const u8 {
    return if (value == .string and value.string.len != 0 and
        std.mem.indexOfScalar(u8, value.string, 0) == null) value.string else null;
}

const Layer = enum { settings, fragment };

fn readFragments(alloc: Allocator, list: *Profiles, base: []const u8) !void {
    const io = global.io();
    const root = try std.fs.path.join(alloc, &.{ base, "Microsoft\\Windows Terminal\\Fragments" });
    const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var sources = dir.iterate();
    while (sources.next(io) catch null) |source| {
        if (source.kind != .directory) continue;
        const sub = dir.openDir(io, source.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var children = sub.iterate();
        while (children.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".json")) continue;
            const document = sub.readFileAlloc(io, entry.name, alloc, .limited(1024 * 1024)) catch continue;
            try mergeTerminalProfiles(alloc, list, document, .fragment);
        }
    }
}

fn visualStudioId(alloc: Allocator, kind: []const u8, instance: []const u8) ![]const u8 {
    // Windows Terminal's VisualStudioGenerator uses UUIDv5 over the UTF-16LE seed.
    const ns = [_]u8{ 0x2b, 0xde, 0x4a, 0x90, 0xd0, 0x5f, 0x40, 0x1c, 0x94, 0x92, 0xe4, 0x08, 0x84, 0xea, 0xd1, 0xd8 };
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(&ns);
    for ([_][]const u8{ kind, instance }) |part| for (part) |ch| hash.update(&.{ ch, 0 });
    var digest = hash.finalResult();
    digest[6] = (digest[6] & 15) | 0x50;
    digest[8] = (digest[8] & 63) | 0x80;
    const h = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return std.fmt.allocPrint(alloc, "wt:{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
}

fn discoverVisualStudio(alloc: Allocator, list: *Profiles, data: []const u8) !void {
    const io = global.io();
    const root = try std.fs.path.join(alloc, &.{ data, "Microsoft\\VisualStudio\\Packages\\_Instances" });
    const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var instances = dir.iterate();
    while (instances.next(io) catch null) |instance| {
        if (instance.kind != .directory or instance.name.len != 8) continue;
        const valid = for (instance.name) |c| {
            if (!std.ascii.isHex(c)) break false;
        } else true;
        if (valid) {
            const file = try fullPath(alloc, instance.name, "state.json");
            const source = dir.readFileAlloc(io, file, alloc, .limited(1024 * 1024)) catch continue;
            const state = std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{ .duplicate_field_behavior = .use_last }) catch continue;
            const path = string(member(state, "installationPath")) orelse continue;
            if (!std.fs.path.isAbsolute(path)) continue;
            const year = string(member(member(state, "catalogInfo"), "productLineVersion")) orelse continue;
            try addVisualStudio(alloc, list, path, instance.name, year);
        }
    }
}

fn addVisualStudio(alloc: Allocator, list: *Profiles, path: []const u8, instance: []const u8, year: []const u8) !void {
    for ([_]bool{ false, true }) |powershell| {
        const shell = find(list.items, if (powershell) "shell:windows-powershell" else "shell:cmd") orelse continue;
        const tool = try fullPath(alloc, path, if (powershell) "Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll" else "Common7\\Tools\\VsDevCmd.bat");
        if (!exists(tool)) continue;
        const args = if (powershell) args: {
            const escaped = try std.mem.replaceOwned(u8, alloc, tool, "'", "''");
            const command = try std.fmt.allocPrintSentinel(alloc, "Import-Module '{s}'; Enter-VsDevShell {s} -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'", .{ escaped, instance }, 0);
            break :args try alloc.dupe([:0]const u8, &.{ shell.argv[0], "-NoExit", "-Command", command });
        } else try alloc.dupe([:0]const u8, &.{ shell.argv[0], "/d", "/k", tool, "-startdir=none", "-arch=x64", "-host_arch=x64" });

        try add(alloc, list, .{
            .id = try visualStudioId(alloc, if (powershell) "VsDevShell" else "VsDevCmd", instance),
            .name = try std.fmt.allocPrint(alloc, "Developer {s} for VS {s}", .{ if (powershell) "PowerShell" else "Command Prompt", year }),
            .argv = args,
            .stock_icon = if (powershell) "vs-powershell" else "vs-cmd",
        });
    }
}

fn mergeTerminalProfiles(alloc: Allocator, list: *Profiles, source: []u8, layer: Layer) !void {
    return mergeEntries(alloc, list, source, layer, true);
}

fn mergeEntries(alloc: Allocator, list: *Profiles, source: []u8, layer: Layer, check_files: bool) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, normalizeJsonc(source), .{ .duplicate_field_behavior = .use_last }) catch return;
    const profiles = member(root, "profiles");
    const entries = if (profiles == .array) profiles else member(profiles, "list");
    if (entries != .array) return;
    const defaults = member(profiles, "defaults");
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (entries.array.items) |entry| {
        const name = string(member(entry, "name"));
        const guid = string(member(entry, "guid")) orelse string(member(entry, "updates"));
        const id = if (guid) |g| (try guidId(alloc, "wt:", g)) orelse continue else if (name) |n|
            try std.fmt.allocPrint(alloc, "wt-name:{x:0>16}", .{std.hash.Wyhash.hash(0, n)})
        else
            continue;
        if ((try seen.getOrPut(alloc, id)).found_existing) continue;
        var index: ?usize = for (list.items, 0..) |profile, i| {
            if (matchesId(profile, id)) break i;
        } else null;
        const hidden = member(entry, "hidden");
        if (hidden == .bool and hidden.bool) {
            if (index) |i| _ = list.orderedRemove(i);
            continue;
        }
        const raw = string(member(entry, "commandline"));
        const args: []const [:0]const u8 = if (raw) |commandline| args: {
            const command = try expand(alloc, commandline);
            var count: i32 = 0;
            const parts = CommandLineToArgvW(command, &count) orelse continue;
            defer _ = LocalFree(@ptrCast(parts));
            if (count <= 0 or parts[0][0] == 0) continue;
            const args = try alloc.alloc([:0]const u8, @intCast(count));
            for (args, parts[0..args.len]) |*arg, part| {
                arg.* = try alloc.dupeSentinel(u8, try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(part)), 0);
            }
            if (check_files) {
                args[0] = (try resolveOnPath(alloc, args[0])) orelse {
                    if (index) |i| _ = list.orderedRemove(i);
                    continue;
                };
                if (!startupScriptExists(args)) {
                    if (index) |i| _ = list.orderedRemove(i);
                    continue;
                }
            }
            break :args args;
        } else if (index) |i| list.items[i].argv else continue;

        // A distribution fragment specifies its actual WSL registration GUID.
        if (index == null and layer == .fragment and args.len == 3 and std.ascii.eqlIgnoreCase(std.fs.path.basename(args[0]), "wsl.exe") and
            std.mem.eql(u8, args[1], "--distribution-id"))
        {
            const distro = (try guidId(alloc, "wsl:", args[2])) orelse continue;
            index = for (list.items, 0..) |profile, i| {
                if (matchesId(profile, distro)) break i;
            } else null;
            if (index == null) continue;
        }
        const prior = if (index) |i| list.items[i] else null;
        const label = name orelse if (prior) |p| p.name else continue;
        const dir_text = string(member(entry, "startingDirectory")) orelse string(member(defaults, "startingDirectory"));
        const directory = if (dir_text) |d| if (std.mem.eql(u8, d, "~")) null else try std.unicode.utf16LeToUtf8Alloc(alloc, try expand(alloc, d)) else if (prior) |p| p.directory else null;
        const icon = if (string(member(entry, "icon"))) |path| try std.unicode.utf16LeToUtf8Alloc(alloc, try expand(alloc, path)) else if (prior) |p| p.icon else null;
        const result: Profile = .{ .id = if (prior) |p| p.id else id, .alias = if (prior) |p| if (!std.mem.eql(u8, p.id, id)) id else p.alias else null, .stock_icon = if (prior) |p| p.stock_icon else null, .name = label, .argv = args, .directory = directory, .icon = icon };
        if (index) |i| list.items[i] = result else try add(alloc, list, result);
    }
}

fn expand(alloc: Allocator, input: []const u8) ![:0]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAllocZ(alloc, input);
    const capacity = ExpandEnvironmentStringsW(raw, null, 0);
    if (capacity == 0) return raw;
    const output = try alloc.allocSentinel(u16, capacity - 1, 0);
    const length = ExpandEnvironmentStringsW(raw, output.ptr, capacity);
    return if (length > 0 and length <= capacity) output[0 .. length - 1 :0] else raw;
}

/// Replace JSONC comments and trailing commas with spaces without changing
/// quoted values or line numbers.
fn normalizeJsonc(source: []u8) []const u8 {
    const text = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) source[3..] else source;
    var cursor: usize = 0;
    var quoted = false;
    var previous: ?usize = null;
    while (cursor < text.len) : (cursor += 1) {
        const c = text[cursor];
        if (quoted) {
            if (c == '\\' and cursor + 1 < text.len) {
                cursor += 1;
            } else if (c == '"') {
                quoted = false;
                previous = cursor;
            }
            continue;
        }
        if (c == '/' and cursor + 1 < text.len) switch (text[cursor + 1]) {
            '/' => {
                const end = std.mem.indexOfAnyPos(u8, text, cursor + 2, "\r\n") orelse text.len;
                @memset(text[cursor..end], ' ');
                cursor = end - 1;
                continue;
            },
            '*' => {
                const end = (std.mem.indexOfPos(u8, text, cursor + 2, "*/") orelse return text) + 2;
                for (text[cursor..end]) |*byte| {
                    if (byte.* != '\r' and byte.* != '\n') byte.* = ' ';
                }
                cursor = end - 1;
                continue;
            },
            else => {},
        };
        if (std.ascii.isWhitespace(c)) continue;
        if (c == '"') quoted = true;
        if (c == '}' or c == ']') {
            if (previous) |index| {
                if (text[index] == ',') text[index] = ' ';
            }
        }
        previous = cursor;
    }
    return text;
}

test "win32 profiles read JSONC and keep command line arguments intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const input = try alloc.dupe(u8,
        \\{
        \\  // Array written by Windows Terminal
        \\  "profiles": { "list": [
        \\    {"guid": "{C9D29D16-15A3-42FD-946B-83AEEB6ED424}", "name": "Custom & shell",
        \\     "commandline": "\"C:\\Program Files\\shell.exe\" --url https://example.org",},
        \\    {"name": "Hidden", "commandline": "cmd.exe", "hidden": true},
        \\  ], }, /* keep object structure */
        \\}
    );
    var list: Profiles = .empty;
    try mergeEntries(alloc, &list, input, .settings, false);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("Custom & shell", list.items[0].name);
    try std.testing.expectEqualStrings("wt:c9d29d16-15a3-42fd-946b-83aeeb6ed424", list.items[0].id);
    try std.testing.expectEqualStrings("C:\\Program Files\\shell.exe", list.items[0].argv[0]);
    try std.testing.expectEqualStrings("https://example.org", list.items[0].argv[2]);
}

test "win32 profile identity survives display name changes and missing IDs fall back" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const id = "wt:c9d29d16-15a3-42fd-946b-83aeeb6ed424";
    var list: Profiles = .empty;
    const initial = try alloc.dupe(u8,
        \\{"profiles":[{"guid":"{C9D29D16-15A3-42FD-946B-83AEEB6ED424}","name":"Original","commandline":"cmd.exe"}]}
    );
    try mergeEntries(alloc, &list, initial, .settings, false);
    try testing.expectEqualStrings("Original", find(list.items, id).?.name);

    list.clearRetainingCapacity();
    const updated = try alloc.dupe(u8,
        \\{"profiles":[
        \\  {"name":"Other","commandline":"cmd.exe"},
        \\  {"guid":"c9d29d16-15a3-42fd-946b-83aeeb6ed424","name":"Renamed","commandline":"pwsh.exe"},
        \\  {"guid":"{C9D29D16-15A3-42FD-946B-83AEEB6ED424}","name":"Duplicate","commandline":"other.exe"}
        \\]}
    );
    try mergeEntries(alloc, &list, updated, .settings, false);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("Renamed", find(list.items, id).?.name);
    try testing.expectEqualStrings("pwsh.exe", find(list.items, id).?.argv[0]);
    try testing.expect(find(list.items, "wsl:c9d29d16-15a3-42fd-946b-83aeeb6ed424") == null);
    try testing.expect(try resolve(alloc, "") == null);
    try testing.expect(validId(id));
    try testing.expect(!validId("shell:cmd\ncommand=unexpected"));
}

test "win32 profiles match Visual Studio instance IDs and preserve distinct toolchains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("wt:c27756f0-1c8e-5c4a-89e3-ae3f1b0933fa", try visualStudioId(a, "VsDevCmd", "a8f4c814"));
    try std.testing.expectEqualStrings("wt:34ee96c2-1313-5ae4-aa98-fe8681ad2156", try visualStudioId(a, "VsDevShell", "c03e42ec"));
    var list: Profiles = .empty;
    try add(a, &list, .{ .id = "shell:cmd", .name = "Command Prompt", .argv = &.{"cmd.exe"} });
    try add(a, &list, .{ .id = "wt:c27756f0-1c8e-5c4a-89e3-ae3f1b0933fa", .name = "Developer", .argv = &.{ "cmd.exe", "/k", "vsdevcmd.bat" } });
    const doc = try a.dupe(u8,
        \\{"profiles":[{"guid":"{0caa0dad-35be-5f56-a8ff-afceeeaa6101}","name":"Renamed shell","commandline":"cmd.exe"},{"guid":"{c27756f0-1c8e-5c4a-89e3-ae3f1b0933fa}","source":"Windows.Terminal.VisualStudio","name":"VS 2019"},{"name":"Different toolchain","commandline":"cmd.exe /k other.bat"},{"source":"Unknown","name":"No executable"}]}
    );
    try mergeEntries(a, &list, doc, .settings, false);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("Renamed shell", find(list.items, "shell:cmd").?.name);
    try std.testing.expectEqualStrings("shell:cmd", find(list.items, "wt:0caa0dad-35be-5f56-a8ff-afceeeaa6101").?.id);
    try std.testing.expectEqualStrings("vsdevcmd.bat", list.items[1].argv[2]);
    try mergeEntries(a, &list, try a.dupe(u8,
        \\{"profiles":[{"guid":"{c27756f0-1c8e-5c4a-89e3-ae3f1b0933fa}","hidden":true}]}
    ), .settings, false);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}
