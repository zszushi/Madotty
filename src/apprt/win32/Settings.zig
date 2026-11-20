//! Settings storage and presentation for the Windows frontend.
const std = @import("std");
const lang = @import("UiLanguage.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const RendererStartup = @import("RendererStartup.zig");
const w32 = @import("win32.zig");
const Profiles = @import("Profiles.zig");
const ShaderSettings = @import("ShaderSettings.zig");
const KeybindingSettings = @import("KeybindingSettings.zig");
const ThemeSettings = @import("ThemeSettings.zig");

test {
    _ = KeybindingSettings;
    _ = ThemeSettings;
}

const Config = configpkg.Config;
const CursorStyle = @import("../../terminal/main.zig").CursorStyle;
const RGB = @import("../../terminal/color.zig").RGB;
const log = std.log.scoped(.win32);
const ui = std.unicode.utf8ToUtf16LeStringLiteral;

// These IDs are shared with dist/windows/ghostty.rc.
const dialog_resource = 110;
const japanese_dialog_resource = 118;
const font_size_id = 111;
const window_theme_id = 112;
const tab_bar_id = 113;
const edit_file_id = 114;
const opacity_id = 115;
const blur_id = 116;
const default_terminal_id = 117;
const cb_add_string = 0x0143;
const cb_get_selection = 0x0147;
const cb_set_selection = 0x014E;
const bm_get_check = 0x00F0;
const bm_set_check = 0x00F1;

const themes = [_]Config.WindowTheme{ .auto, .system, .light, .dark };
const tab_modes = [_]Config.WindowShowTabBar{ .always, .auto, .never };

const gui_file = "madotty-gui.ghostty";
const gui_include = "config-file = ?" ++ gui_file;
const Edits = struct {
    @"font-size": ?f32 = null,
    @"font-family": ?[]const []const u8 = null,
    @"windows-ui-font-family": ?[]const u8 = null,
    @"cursor-style": ?CursorStyle = null,
    @"copy-on-select": ?Config.CopyOnSelect = null,
    @"right-click-action": ?Config.RightClickAction = null,
    @"clipboard-read": ?Config.ClipboardAccess = null,
    @"clipboard-write": ?Config.ClipboardAccess = null,
    @"clipboard-paste-protection": ?bool = null,
    @"link-url": ?bool = null,
    @"desktop-notifications": ?bool = null,
    @"window-theme": ?Config.WindowTheme = null,
    theme: ?[]const u8 = null,
    @"window-show-tab-bar": ?Config.WindowShowTabBar = null,
    @"progress-style": ?bool = null,
    @"window-new-tab-position": ?Config.WindowNewTabPosition = null,
    @"tab-inherit-working-directory": ?bool = null,
    @"background-opacity": ?f64 = null,
    @"background-blur": ?bool = null,
    @"windows-background-material": ?Config.WindowsBackgroundMaterial = null,
    @"windows-renderer": ?Config.WindowsRenderer = null,
    @"windows-default-profile": ?[]const u8 = null,
    @"custom-shader": ?[]const ShaderSettings.Path = null,
    @"custom-shader-animation": ?Config.CustomShaderAnimation = null,
    @"custom-shader-parameter": ?[]const ShaderSettings.Override = null,
};

/// Colors in the settings wire format use 0xRRGGBB.
const Colors = struct {
    background: u32,
    foreground: u32,
    accent: u32,

    fn fromConfig(config: *const Config) Colors {
        const background = config.background.toTerminalRGB();
        const foreground = config.foreground.toTerminalRGB();
        const selection_bg: ?RGB = if (config.@"selection-background") |value| switch (value) {
            .color => |color| color.toTerminalRGB(),
            .@"cell-foreground" => foreground,
            .@"cell-background" => background,
        } else null;

        // Prefer theme colors that keep controls distinguishable against the
        // settings background. Slots 4 and 12 are ANSI blue and bright blue.
        const accent = accent: {
            for ([_]?RGB{ selection_bg, config.palette.value[4], config.palette.value[12], foreground }) |candidate| {
                const color = candidate orelse continue;
                if (color.contrast(background) >= 3) break :accent color;
            }
            const black: RGB = .{};
            const white: RGB = .{ .r = 255, .g = 255, .b = 255 };
            break :accent if (white.contrast(background) > black.contrast(background)) white else black;
        };

        return .{
            .background = pack(background),
            .foreground = pack(foreground),
            .accent = pack(accent),
        };
    }

    fn pack(color: RGB) u32 {
        return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
    }
};

const Dialog = struct {
    app: *App,
    font_size: f32,
    theme: Config.WindowTheme,
    tab_bar: Config.WindowShowTabBar,
    opacity_percent: f64,
    blur: bool,
};

// The companion has its own message loop. Only the terminal process reads or
// writes Ghostty config, and it services the private pipes on the UI thread.
pub const timer_id: usize = 16;
const wire_limit = 64 * 1024;

const Request = struct {
    action: enum { save, edit, shader_parameters, keybindings, themes },
    edits: Edits = .{},
    path: ?[]const u8 = null,
    offset: u32 = 0,
};

const Reply = struct {
    ok: bool,
    message: ?[]const u8 = null,
    parameters: ?[]const ShaderSettings.Parameter = null,
    keybindings: ?KeybindingSettings.Page = null,
    themes: ?ThemeSettings.Page = null,
};

extern "kernel32" fn PeekNamedPipe(w32.HANDLE, ?*anyopaque, u32, ?*u32, *u32, ?*u32) callconv(.winapi) i32;
extern "kernel32" fn GetProcessId(w32.HANDLE) callconv(.winapi) u32;
extern "user32" fn EnumWindows(*const fn (w32.HWND, isize) callconv(.winapi) i32, isize) callconv(.winapi) i32;

pub const Session = struct {
    child: std.process.Child,
    buffer: []u8 = &.{},
    used: usize = 0,
    waiting_to_open: bool = false,

    fn send(self: *Session, alloc: std.mem.Allocator, value: anytype) !void {
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        try std.json.Stringify.value(value, .{}, &output.writer);
        try output.writer.writeByte('\n');
        if (output.written().len > wire_limit) return error.SettingsMessageTooLarge;
        try self.child.stdin.?.writeStreamingAll(global.io(), output.written());
    }

    fn pump(self: *Session, app: *App) !bool {
        // Neither waiting on the process nor reading an empty pipe may block
        // the terminal's message loop.
        switch (w32.WaitForSingleObject(self.child.id.?, 0)) {
            w32.WAIT_OBJECT_0 => {
                const result = try self.child.wait(global.io());
                if (!result.success()) return error.SettingsProcessFailed;
                return false;
            },
            w32.WAIT_TIMEOUT => {},
            else => return error.SettingsProcessWait,
        }
        const pipe = self.child.stdout.?;
        var available: u32 = 0;
        if (PeekNamedPipe(pipe.handle, null, 0, null, &available, null) == 0 or available == 0) return true;
        const capacity = self.buffer.len - self.used;
        const destination = self.buffer[self.used..][0..@min(capacity, available)];
        self.used += try pipe.readStreaming(global.io(), &.{destination});
        const newline = std.mem.indexOfScalar(u8, self.buffer[0..self.used], '\n') orelse {
            if (self.used == wire_limit) return error.SettingsMessageTooLarge;
            return true;
        };
        if (newline + 1 != self.used) return error.UnexpectedSettingsMessage;
        self.used = 0;
        const alloc = app.core_app.alloc;
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const reply = handleRequest(app, arena.allocator(), self.buffer[0..newline]);
        self.send(alloc, reply) catch |err| switch (err) {
            error.SettingsMessageTooLarge => try self.send(alloc, Reply{ .ok = false, .message = lang.text("This shader has too many parameters to show in Settings.") }),
            else => return err,
        };
        return true;
    }

    fn focus(self: *const Session) bool {
        const pid = GetProcessId(self.child.id.?);
        if (pid == 0) return false;
        var target: FocusTarget = .{ .pid = pid };
        _ = EnumWindows(findProcessWindow, @bitCast(@intFromPtr(&target)));
        const hwnd = target.window orelse return false;
        if (w32.IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
        _ = w32.SetForegroundWindow(hwnd);
        return true;
    }

    fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
        if (self.child.id) |process| {
            // EOF dismisses the companion even when there is no pending edit.
            // The parent need not wait for WinUI shutdown.
            self.child.stdin.?.close(global.io());
            self.child.stdout.?.close(global.io());
            _ = w32.CloseHandle(self.child.thread_handle);
            _ = w32.CloseHandle(process);
        }
    }
};

const FocusTarget = struct {
    pid: u32,
    window: ?w32.HWND = null,
};

fn findProcessWindow(hwnd: w32.HWND, parameter: isize) callconv(.winapi) i32 {
    const target: *FocusTarget = @ptrFromInt(@as(usize, @bitCast(parameter)));
    var pid: u32 = 0;
    _ = w32.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != target.pid or w32.IsWindowVisible_(hwnd) == 0) return 1;
    target.window = hwnd;
    return 0;
}

pub fn closeCompanion(app: *App) void {
    if (app.settings_session) |*session| {
        if (app.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, timer_id);
        session.deinit(app.core_app.alloc);
        app.settings_session = null;
    }
}

pub fn tick(app: *App) void {
    const session = if (app.settings_session) |*value| value else return;
    if (session.pump(app)) |running| {
        if (running) {
            if (session.waiting_to_open and session.focus()) session.waiting_to_open = false;
            return;
        }
        const reopen = session.waiting_to_open;
        closeCompanion(app);
        if (reopen and app.windows.items.len != 0) {
            if (app.windows.items[0].hwnd) |hwnd| open(app, hwnd);
        }
    } else |err| {
        log.warn("WinUI settings stopped: {t}", .{err});
        closeCompanion(app);
        if (app.windows.items.len != 0) {
            if (app.windows.items[0].hwnd) |hwnd| openNative(app, hwnd);
        }
    }
}

pub fn open(app: *App, owner: w32.HWND) void {
    if (app.settings_session) |*session| {
        if (w32.WaitForSingleObject(session.child.id.?, 0) == w32.WAIT_TIMEOUT) {
            // A closing window can disappear before its process signals.
            // Honor a second open made during that interval.
            session.waiting_to_open = !session.focus();
            return;
        }
        closeCompanion(app);
    }
    if (startCompanion(app)) |_| return else |err| {
        // Keep settings available in a Zig-only build as well as when the
        // companion fails to start.
        if (err != error.FileNotFound) log.warn("could not start WinUI settings: {t}", .{err});
    }
    openNative(app, owner);
}

fn startCompanion(app: *App) !void {
    const hwnd = app.msg_hwnd orelse return error.MissingMessageWindow;
    const io = global.io();
    const alloc = app.core_app.alloc;
    const executable = try std.process.executablePathAlloc(io, alloc);
    defer alloc.free(executable);
    const parent = std.fs.path.dirname(executable) orelse return error.InvalidPath;
    const path = try std.fs.path.join(alloc, &.{ parent, "settings", "Madotty.Settings.exe" });
    defer alloc.free(path);
    try std.Io.Dir.cwd().access(io, path, .{});
    var session: Session = .{ .child = try std.process.spawn(io, .{
        .argv = &.{ path, "--host" },
        .stdin = .pipe,
        .stdout = .pipe,
    }) };
    errdefer session.deinit(alloc);
    session.buffer = try alloc.alloc(u8, wire_limit);
    const config = &app.config;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const profile_id = config.@"windows-default-profile";
    var values = .{
        .font_size = config.@"font-size",
        .terminal_fonts = config.@"font-family".list.items,
        .ui_font_family = config.@"windows-ui-font-family",
        .cursor_style = config.@"cursor-style",
        .copy_on_select = config.@"copy-on-select" == .clipboard or config.@"copy-on-select" == .both,
        .right_click_action = config.@"right-click-action",
        .privacy = .{
            .clipboard_read = config.@"clipboard-read",
            .clipboard_write = config.@"clipboard-write",
            .paste_protection = config.@"clipboard-paste-protection",
            .detect_links = config.@"link-url",
            .notifications = config.@"desktop-notifications",
        },
        .theme = if (config.@"window-theme" == .ghostty) .auto else config.@"window-theme",
        .themes_available = true,
        .terminal_theme = ThemeSettings.format(arena.allocator(), config.theme) catch null,
        .terminal_theme_light = @as(?[]const u8, if (config.theme) |theme| theme.light else null),
        .terminal_theme_dark = @as(?[]const u8, if (config.theme) |theme| theme.dark else null),
        .opacity_percent = 100 * config.@"background-opacity",
        .blur = config.@"background-blur".enabled(),
        .backdrop = config.@"windows-background-material",
        .active_renderer = RendererStartup.active,
        .renderer = app.renderer_startup.snapshot(config.@"windows-renderer"),
        .startup_profile = @as(?[]const u8, if (profile_id.len != 0 and Profiles.validId(profile_id)) profile_id else null),
        .profiles = Profiles.summarize(arena.allocator()) catch &.{},
        .keybindings_available = true,
        .tab_bar = config.@"window-show-tab-bar",
        .progress_style = config.@"progress-style",
        .new_tab_position = config.@"window-new-tab-position",
        .tab_inherit_working_directory = config.@"tab-inherit-working-directory",
        .colors = Colors.fromConfig(config),
        .writable = config.@"config-default-files",
        .shaders = @as(?ShaderSettings.Snapshot, ShaderSettings.snapshot(arena.allocator(), config) catch null),
    };
    session.send(alloc, values) catch |err| switch (err) {
        error.SettingsMessageTooLarge => {
            values.shaders = null;
            session.send(alloc, values) catch |retry_err| switch (retry_err) {
                error.SettingsMessageTooLarge => {
                    values.profiles = &.{};
                    try session.send(alloc, values);
                },
                else => return retry_err,
            };
        },
        else => return err,
    };
    if (w32.SetTimer(hwnd, timer_id, 100, null) == 0) return error.TimerUnavailable;
    app.settings_session = session;
}

fn validateEdits(edits: Edits) !void {
    if (edits.@"font-family") |families| {
        for (families) |family| {
            if (family.len == 0 or !std.unicode.utf8ValidateSlice(family)) return error.InvalidFontFamily;
            for (family) |byte| if (std.ascii.isControl(byte)) return error.InvalidFontFamily;
        }
    }
    if (edits.@"windows-ui-font-family") |family| {
        if (!std.unicode.utf8ValidateSlice(family)) return error.InvalidUiFontFamily;
        for (family) |byte| if (std.ascii.isControl(byte)) return error.InvalidUiFontFamily;
    }
    if (edits.@"font-size") |value| {
        if (!std.math.isFinite(value) or value < 1 or value > 255) return error.InvalidFontSize;
    }
    if (edits.@"background-opacity") |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidOpacity;
    }
    if (edits.@"windows-default-profile") |value| {
        if (!Profiles.validId(value)) return error.InvalidStartupProfile;
    }
}

test "windows UI font settings change and reset independently of the terminal font" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const main = "font-family = Consolas\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "config.ghostty", .data = main });
    const path = try tmp.dir.realPathFileAlloc(io, "config.ghostty", alloc);
    defer alloc.free(path);
    for ([_][]const u8{ "Yu Gothic UI", "メイリオ", "" }) |name| {
        const edits: Edits = .{ .@"windows-ui-font-family" = name };
        try validateEdits(edits);
        try saveAt(io, alloc, tmp.dir, "config.ghostty", edits);
        var config = try Config.default(alloc);
        defer config.deinit();
        try config.loadFile(alloc, path);
        try config.loadRecursiveFiles(alloc);
        try std.testing.expect(editsApplied(&config, edits));
        try std.testing.expectEqualStrings("Consolas", config.@"font-family".list.items[0]);
    }
    try std.testing.expectError(error.InvalidUiFontFamily, validateEdits(.{ .@"windows-ui-font-family" = "name\nfont-size = 1" }));
}

fn handleRequest(app: *App, alloc: std.mem.Allocator, bytes: []const u8) Reply {
    const request = std.json.parseFromSliceLeaky(Request, alloc, bytes, .{}) catch
        return .{ .ok = false, .message = lang.text("Madotty could not read the settings changes.") };
    return handleAction(app, alloc, request) catch |err| {
        log.warn("could not apply WinUI settings action: {t}", .{err});
        const message: []const u8 = switch (err) {
            error.DefaultConfigDisabled => lang.text("This window was opened with the default config file disabled."),
            error.InvalidFontSize, error.InvalidOpacity => lang.text("Check the font size and opacity values."),
            error.InvalidUiFontFamily => lang.text("Choose a valid UI font family."),
            error.InvalidStartupProfile => lang.text("Choose a startup profile from the list."),
            error.ConfigEditorUnavailable => lang.text("Madotty could not open the config file."),
            error.SettingsOverridden => lang.text("Settings were saved, but a later config entry or launch option takes precedence."),
            error.InvalidShaderPath => lang.text("Choose an absolute path to a shader file."),
            error.ShaderFileUnavailable, error.FileNotFound, error.AccessDenied => lang.text("Madotty could not read the shader file."),
            error.InvalidShaderParameter => lang.text("A shader parameter is missing or outside its allowed range."),
            error.KeybindingTooLarge => lang.text("A keybinding is too large to display in Settings."),
            error.InvalidTerminalTheme => lang.text("Choose a valid terminal theme for each appearance."),
            error.TerminalThemeUnavailable => lang.text("The selected terminal theme could not be opened."),
            error.ThemeCatalogItemTooLarge => lang.text("A terminal theme name is too large to display in Settings."),
            else => lang.text("Madotty could not apply the settings. Check that the config folder is writable."),
        };
        return .{ .ok = false, .message = message };
    };
}

fn handleAction(app: *App, alloc: std.mem.Allocator, request: Request) !Reply {
    switch (request.action) {
        .edit => if (!try app.performAction(.app, .open_config, .os_open)) return error.ConfigEditorUnavailable,
        .shader_parameters => return .{
            .ok = true,
            .parameters = try ShaderSettings.inspect(alloc, request.path orelse return error.InvalidShaderPath),
        },
        .keybindings => return .{
            .ok = true,
            // Leave room for the reply and page fields around the rows.
            .keybindings = try KeybindingSettings.page(alloc, &app.config, request.offset, wire_limit - 256),
        },
        .themes => return .{
            .ok = true,
            .themes = try ThemeSettings.page(alloc, request.offset, wire_limit - 256),
        },
        .save => {
            var edits = request.edits;
            try validateEdits(edits);
            if (std.meta.eql(edits, Edits{})) return .{ .ok = true };
            const edited_theme = if (edits.theme) |value| try ThemeSettings.parse(alloc, value) else null;
            if (edits.theme != null) {
                try ThemeSettings.requireAvailable(alloc, edited_theme);
                edits.theme = (try ThemeSettings.format(alloc, edited_theme)) orelse "";
            }
            try ShaderSettings.validate(alloc, &app.config, edits.@"custom-shader", edits.@"custom-shader-parameter");
            try save(app, edits);
            var config = try Config.load(app.core_app.alloc);
            defer config.deinit();
            try app.applyConfig(&config);
            if (!editsApplied(&app.config, edits)) return error.SettingsOverridden;
            if (edits.theme != null and !ThemeSettings.equal(edited_theme, app.config.theme)) return error.SettingsOverridden;
        },
    }
    return .{ .ok = true };
}

fn editsApplied(config: *const Config, edits: Edits) bool {
    if (edits.@"font-family") |families| {
        const applied = config.@"font-family".list.items;
        if (families.len != applied.len) return false;
        for (families, applied) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    }
    return (edits.@"font-size" orelse config.@"font-size") == config.@"font-size" and
        std.mem.eql(u8, edits.@"windows-ui-font-family" orelse config.@"windows-ui-font-family", config.@"windows-ui-font-family") and
        (edits.@"cursor-style" orelse config.@"cursor-style") == config.@"cursor-style" and
        (edits.@"copy-on-select" orelse config.@"copy-on-select") == config.@"copy-on-select" and
        (edits.@"right-click-action" orelse config.@"right-click-action") == config.@"right-click-action" and
        (edits.@"clipboard-read" orelse config.@"clipboard-read") == config.@"clipboard-read" and
        (edits.@"clipboard-write" orelse config.@"clipboard-write") == config.@"clipboard-write" and
        (edits.@"clipboard-paste-protection" orelse config.@"clipboard-paste-protection") == config.@"clipboard-paste-protection" and
        (edits.@"link-url" orelse config.@"link-url") == config.@"link-url" and
        (edits.@"desktop-notifications" orelse config.@"desktop-notifications") == config.@"desktop-notifications" and
        (edits.@"window-theme" orelse config.@"window-theme") == config.@"window-theme" and
        (edits.@"window-show-tab-bar" orelse config.@"window-show-tab-bar") == config.@"window-show-tab-bar" and
        (edits.@"progress-style" orelse config.@"progress-style") == config.@"progress-style" and
        (edits.@"window-new-tab-position" orelse config.@"window-new-tab-position") == config.@"window-new-tab-position" and
        (edits.@"tab-inherit-working-directory" orelse config.@"tab-inherit-working-directory") == config.@"tab-inherit-working-directory" and
        (edits.@"background-opacity" orelse config.@"background-opacity") == config.@"background-opacity" and
        (edits.@"background-blur" orelse config.@"background-blur".enabled()) == config.@"background-blur".enabled() and
        (edits.@"windows-background-material" orelse config.@"windows-background-material") == config.@"windows-background-material" and
        (edits.@"windows-renderer" orelse config.@"windows-renderer") == config.@"windows-renderer" and
        std.mem.eql(u8, edits.@"windows-default-profile" orelse config.@"windows-default-profile", config.@"windows-default-profile") and
        (edits.@"custom-shader-animation" orelse config.@"custom-shader-animation") == config.@"custom-shader-animation" and
        ShaderSettings.editsApplied(config, edits.@"custom-shader", edits.@"custom-shader-parameter");
}

fn openNative(app: *App, owner: w32.HWND) void {
    var dialog: Dialog = .{
        .app = app,
        .font_size = app.config.@"font-size",
        .theme = if (app.config.@"window-theme" == .ghostty) .auto else app.config.@"window-theme",
        .tab_bar = app.config.@"window-show-tab-bar",
        .opacity_percent = 100 * app.config.@"background-opacity",
        .blur = app.config.@"background-blur".enabled(),
    };
    const result = w32.DialogBoxParamW(app.hinstance, @ptrFromInt(if (lang.isJapanese()) @as(usize, japanese_dialog_resource) else @as(usize, dialog_resource)), owner, &dialogProc, @bitCast(@intFromPtr(&dialog)));
    switch (result) {
        w32.IDOK => _ = app.performAction(.app, .reload_config, .{ .soft = false }) catch |err| {
            log.err("failed to apply settings err={}", .{err});
        },
        edit_file_id => _ = app.performAction(.app, .open_config, .os_open) catch |err| {
            log.err("failed to open config err={}", .{err});
        },
        -1 => log.err("failed to open settings dialog", .{}),
        else => {},
    }
}

fn initCombo(hwnd: w32.HWND, id: i32, labels: []const [:0]const u16, current: usize) void {
    const control = w32.GetDlgItem(hwnd, id) orelse return;
    for (labels) |label| _ = w32.SendMessageW(control, cb_add_string, 0, @bitCast(@intFromPtr(label.ptr)));
    _ = w32.SendMessageW(control, cb_set_selection, current, 0);
}

fn selection(hwnd: w32.HWND, id: i32, values: anytype) ?std.meta.Elem(@TypeOf(values)) {
    const control = w32.GetDlgItem(hwnd, id) orelse return null;
    const index = w32.SendMessageW(control, cb_get_selection, 0, 0);
    if (index < 0 or index >= values.len) return null;
    return values[@intCast(index)];
}

fn setNumber(hwnd: w32.HWND, id: i32, value: anytype) void {
    const edit = w32.GetDlgItem(hwnd, id) orelse return;
    var utf8: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&utf8, "{d}", .{value}) catch return;
    var utf16: [49]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&utf16, text) catch unreachable;
    utf16[len] = 0;
    _ = w32.SendMessageW(edit, 0x00C5, 24, 0); // EM_SETLIMITTEXT
    _ = w32.SetWindowTextW(edit, utf16[0..len :0]);
}

fn number(comptime T: type, hwnd: w32.HWND, id: i32, min: T, max: T, message: [*:0]const u16) ?T {
    const edit = w32.GetDlgItem(hwnd, id) orelse return null;
    var utf16: [32]u16 = undefined;
    const len = w32.GetWindowTextW(edit, &utf16, utf16.len);
    var utf8: [96]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8, utf16[0..@intCast(len)]) catch 0;
    const value = std.fmt.parseFloat(T, std.mem.trim(u8, utf8[0..utf8_len], " \t")) catch std.math.nan(T);
    if (std.math.isFinite(value) and value >= min and value <= max) return value;
    _ = w32.MessageBoxW(hwnd, message, lang.wide("Settings"), w32.MB_ICONWARNING);
    _ = w32.SetFocus(edit);
    return null;
}

fn dialogProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        w32.WM_INITDIALOG => {
            const dialog: *Dialog = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, lparam);
            setNumber(hwnd, font_size_id, dialog.font_size);
            setNumber(hwnd, opacity_id, dialog.opacity_percent);
            if (w32.GetDlgItem(hwnd, blur_id)) |blur| {
                _ = w32.SendMessageW(blur, bm_set_check, @intFromBool(dialog.blur), 0);
                if (RendererStartup.active == .vulkan) _ = w32.EnableWindow(blur, 0);
            }
            const theme_labels = [_][:0]const u16{ lang.wide("Terminal background"), lang.wide("System"), lang.wide("Light"), lang.wide("Dark") };
            const tab_labels = [_][:0]const u16{ lang.wide("Always"), lang.wide("When multiple tabs are open"), lang.wide("Never") };
            initCombo(hwnd, window_theme_id, &theme_labels, @backingInt(dialog.theme));
            initCombo(hwnd, tab_bar_id, &tab_labels, std.mem.indexOfScalar(Config.WindowShowTabBar, &tab_modes, dialog.tab_bar) orelse 0);
            return 1;
        },
        w32.WM_COMMAND => switch (wparam & 0xFFFF) {
            default_terminal_id => {
                // Windows owns the list of registered terminal delegates.
                const result = w32.ShellExecuteW(hwnd, ui("open"), ui("ms-settings:developers"), null, null, w32.SW_SHOW);
                if (result <= 32) _ = w32.MessageBoxW(hwnd, lang.wide("Could not open Windows settings."), lang.wide("Default terminal"), w32.MB_ICONWARNING);
                return 1;
            },
            w32.IDOK => {
                const data = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
                if (data == 0) return 0;
                const dialog: *Dialog = @ptrFromInt(@as(usize, @bitCast(data)));
                const font_size = number(f32, hwnd, font_size_id, 1, 255, lang.wide("Enter a font size from 1 to 255 pt.")) orelse return 1;
                const opacity = number(f64, hwnd, opacity_id, 0, 100, lang.wide("Enter an opacity from 0 to 100%.")) orelse return 1;
                const theme = selection(hwnd, window_theme_id, themes) orelse dialog.theme;
                const tab_bar = selection(hwnd, tab_bar_id, tab_modes) orelse dialog.tab_bar;
                const blur = if (w32.GetDlgItem(hwnd, blur_id)) |control|
                    w32.SendMessageW(control, bm_get_check, 0, 0) == 1
                else
                    dialog.blur;
                const edits: Edits = .{
                    .@"font-size" = if (font_size != dialog.font_size) font_size else null,
                    .@"window-theme" = if (theme != dialog.theme) theme else null,
                    .@"window-show-tab-bar" = if (tab_bar != dialog.tab_bar) tab_bar else null,
                    .@"background-opacity" = if (opacity != dialog.opacity_percent) opacity / 100 else null,
                    .@"background-blur" = if (blur != dialog.blur) blur else null,
                };
                if (std.meta.eql(edits, Edits{})) {
                    _ = w32.EndDialog(hwnd, w32.IDCANCEL);
                    return 1;
                }
                save(dialog.app, edits) catch |err| {
                    log.err("failed to save settings err={}", .{err});
                    const message = if (err == error.DefaultConfigDisabled)
                        lang.wide("This window was opened with the default config file disabled.")
                    else
                        lang.wide("Could not save settings. Check that the config folder is writable.");
                    _ = w32.MessageBoxW(hwnd, message, lang.wide("Settings"), w32.MB_ICONWARNING);
                    return 1;
                };
                _ = w32.EndDialog(hwnd, w32.IDOK);
                return 1;
            },
            w32.IDCANCEL, edit_file_id => {
                _ = w32.EndDialog(hwnd, @intCast(wparam & 0xFFFF));
                return 1;
            },
            else => return 0,
        },
        else => return 0,
    }
}

fn save(app: *App, edits: Edits) !void {
    if (!app.config.@"config-default-files") return error.DefaultConfigDisabled;
    const alloc = app.core_app.alloc;
    const path = try configpkg.edit.openPath(alloc);
    defer alloc.free(path);
    const io = global.io();
    const dir = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(path) orelse return error.InvalidPath, .{});
    defer dir.close(io);
    try saveAt(io, alloc, dir, std.fs.path.basename(path), edits);
}

fn readConfig(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => alloc.dupe(u8, ""),
        else => return err,
    };
}

fn assignment(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const delim = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{ .key = std.mem.trim(u8, line[0..delim], " \t"), .value = std.mem.trim(u8, line[delim + 1 ..], " \t\r\"") };
}

fn saveAt(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, main_name: []const u8, edits: Edits) !void {
    const main = try readConfig(io, alloc, dir, main_name);
    defer alloc.free(main);
    const old_gui = try readConfig(io, alloc, dir, gui_file);
    defer alloc.free(old_gui);

    var gui = try dir.createFileAtomic(io, gui_file, .{ .replace = true });
    defer gui.deinit(io);
    var buffer: [1024]u8 = undefined;
    var writer = gui.file.writer(io, &buffer);
    var lines = std.mem.splitScalar(u8, old_gui, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        const key = if (assignment(line)) |item| item.key else "";
        const replaced = replaced: {
            inline for (comptime std.meta.fieldNames(Edits)) |name| {
                if (@field(edits, name) != null and std.mem.eql(u8, key, name)) break :replaced true;
            }
            break :replaced false;
        };
        if (!replaced) try writer.interface.print("{s}\n", .{line});
    }
    if (edits.@"font-size") |value| try writer.interface.print("font-size = {d}\n", .{value});
    if (edits.@"font-family") |families| {
        try writer.interface.writeAll("font-family =\n");
        for (families) |family| try writer.interface.print("font-family = {s}\n", .{family});
    }
    if (edits.@"windows-ui-font-family") |value| try writer.interface.print("windows-ui-font-family = {s}\n", .{value});
    if (edits.@"cursor-style") |value| try writer.interface.print("cursor-style = {s}\n", .{@tagName(value)});
    if (edits.@"copy-on-select") |value| try writer.interface.print("copy-on-select = {s}\n", .{@tagName(value)});
    if (edits.@"right-click-action") |value| try writer.interface.print("right-click-action = {s}\n", .{@tagName(value)});
    if (edits.@"clipboard-read") |value| try writer.interface.print("clipboard-read = {s}\n", .{@tagName(value)});
    if (edits.@"clipboard-write") |value| try writer.interface.print("clipboard-write = {s}\n", .{@tagName(value)});
    if (edits.@"clipboard-paste-protection") |value| try writer.interface.print("clipboard-paste-protection = {}\n", .{value});
    if (edits.@"link-url") |value| try writer.interface.print("link-url = {}\n", .{value});
    if (edits.@"desktop-notifications") |value| try writer.interface.print("desktop-notifications = {}\n", .{value});
    if (edits.@"window-theme") |value| try writer.interface.print("window-theme = {s}\n", .{@tagName(value)});
    if (edits.theme) |value| try writer.interface.print("theme = {s}\n", .{value});
    if (edits.@"window-show-tab-bar") |value| try writer.interface.print("window-show-tab-bar = {s}\n", .{@tagName(value)});
    if (edits.@"progress-style") |value| try writer.interface.print("progress-style = {}\n", .{value});
    if (edits.@"window-new-tab-position") |value| try writer.interface.print("window-new-tab-position = {s}\n", .{@tagName(value)});
    if (edits.@"tab-inherit-working-directory") |value| try writer.interface.print("tab-inherit-working-directory = {}\n", .{value});
    if (edits.@"background-opacity") |value| try writer.interface.print("background-opacity = {d}\n", .{value});
    if (edits.@"background-blur") |value| try writer.interface.print("background-blur = {}\n", .{value});
    if (edits.@"windows-background-material") |value| try writer.interface.print("windows-background-material = {s}\n", .{@tagName(value)});
    if (edits.@"windows-renderer") |value| try writer.interface.print("windows-renderer = {s}\n", .{@tagName(value)});
    if (edits.@"windows-default-profile") |value| try writer.interface.print("windows-default-profile = {s}\n", .{value});
    if (edits.@"custom-shader-animation") |value| try writer.interface.print("custom-shader-animation = {s}\n", .{@tagName(value)});
    if (edits.@"custom-shader") |items| {
        try writer.interface.writeAll("custom-shader =\n");
        for (items) |item| {
            try writer.interface.print("custom-shader = {s}\"{s}\"\n", .{ if (item.optional) "?" else "", item.path });
        }
    }
    if (edits.@"custom-shader-parameter") |items| {
        try writer.interface.writeAll("custom-shader-parameter =\n");
        for (items) |item| {
            try writer.interface.print("custom-shader-parameter = {d}:{s}:{d}\n", .{ item.pass, item.name, item.value });
        }
    }
    try writer.flush();
    try gui.replace(io);

    lines = std.mem.splitScalar(u8, main, '\n');
    while (lines.next()) |line| {
        const item = assignment(line) orelse continue;
        if (std.mem.eql(u8, item.key, "config-file") and
            std.mem.eql(u8, std.mem.trimStart(u8, item.value, "?"), gui_file)) return;
    }
    var updated = try dir.createFileAtomic(io, main_name, .{ .replace = true });
    defer updated.deinit(io);
    writer = updated.file.writer(io, &buffer);
    const newline = if (std.mem.indexOf(u8, main, "\r\n") != null) "\r\n" else "\n";
    try writer.interface.writeAll(main);
    if (main.len != 0 and main[main.len - 1] != '\n') try writer.interface.writeAll(newline);
    try writer.interface.print("{s}{s}", .{ gui_include, newline });
    try writer.flush();
    try updated.replace(io);
}

test "win32 settings companion accepts sparse edits and validates numeric values" {
    const testing = std.testing;
    const request = try std.json.parseFromSlice(
        Request,
        testing.allocator,
        "{\"action\":\"save\",\"edits\":{\"window-theme\":\"dark\",\"background-opacity\":0.93,\"windows-background-material\":\"acrylic\",\"windows-renderer\":\"d3d12\",\"window-new-tab-position\":\"end\",\"tab-inherit-working-directory\":false}}",
        .{},
    );
    defer request.deinit();
    try validateEdits(request.value.edits);
    try testing.expectEqual(Edits{
        .@"window-theme" = .dark,
        .@"window-new-tab-position" = .end,
        .@"tab-inherit-working-directory" = false,
        .@"background-opacity" = 0.93,
        .@"windows-background-material" = .acrylic,
        .@"windows-renderer" = .d3d12,
    }, request.value.edits);
    try testing.expectError(error.InvalidFontSize, validateEdits(.{ .@"font-size" = -1 }));
    try testing.expectError(error.InvalidOpacity, validateEdits(.{ .@"background-opacity" = std.math.nan(f64) }));
}

test "win32 settings companion uses resolved theme colors and a readable accent" {
    const testing = std.testing;
    var config: Config = .{
        .background = .{ .r = 0x20, .g = 0x2a, .b = 0x35 },
        .foreground = .{ .r = 0xb3, .g = 0xc7, .b = 0xd8 },
        .@"selection-background" = .{ .color = .{ .r = 0xf0, .g = 0xa0, .b = 0x40 } },
    };
    config.palette.value[4] = .{ .r = 0x42, .g = 0x8f, .b = 0xff };
    try testing.expectEqual(Colors{ .background = 0x202a35, .foreground = 0xb3c7d8, .accent = 0xf0a040 }, Colors.fromConfig(&config));
    config.@"selection-background" = .@"cell-foreground";
    try testing.expectEqual(@as(u32, 0xb3c7d8), Colors.fromConfig(&config).accent);
    config.@"selection-background" = .@"cell-background";
    try testing.expectEqual(@as(u32, 0x428fff), Colors.fromConfig(&config).accent);

    config.background = .{ .r = 0xf0, .g = 0xee, .b = 0xe8 };
    config.foreground = config.background;
    config.palette.value[4] = config.background.toTerminalRGB();
    config.palette.value[12] = config.palette.value[4];
    try testing.expectEqual(@as(u32, 0x000000), Colors.fromConfig(&config).accent);
}

test "win32 settings companion checks applied tab preferences" {
    const testing = std.testing;
    var config: Config = .{};
    const edits: Edits = .{ .@"window-new-tab-position" = .end, .@"tab-inherit-working-directory" = false };
    try testing.expect(!editsApplied(&config, edits));
    config.@"window-new-tab-position" = .end;
    try testing.expect(!editsApplied(&config, edits));
    config.@"tab-inherit-working-directory" = false;
    try testing.expect(editsApplied(&config, edits));
}

test "win32 settings preserve config text and update only edited values" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "# My config\r\nconfig-file = ?personal.ghostty\r\nfont-size = 11";
    try tmp.dir.writeFile(io, .{ .sub_path = "config.ghostty", .data = original });
    try saveAt(io, alloc, tmp.dir, "config.ghostty", .{
        .@"font-size" = 13,
        .@"window-theme" = .dark,
        .@"windows-background-material" = .auto,
        .@"window-new-tab-position" = .current,
        .@"tab-inherit-working-directory" = true,
    });
    try saveAt(io, alloc, tmp.dir, "config.ghostty", .{ .@"font-size" = 14, .@"window-show-tab-bar" = .auto, .@"background-opacity" = 0.875, .@"background-blur" = true });
    try saveAt(io, alloc, tmp.dir, "config.ghostty", .{
        .@"windows-background-material" = .mica,
        .@"window-new-tab-position" = .end,
        .@"tab-inherit-working-directory" = false,
    });
    const main = try readConfig(io, alloc, tmp.dir, "config.ghostty");
    defer alloc.free(main);
    try testing.expectEqualStrings(original ++ "\r\n" ++ gui_include ++ "\r\n", main);
    const gui = try readConfig(io, alloc, tmp.dir, gui_file);
    defer alloc.free(gui);
    try testing.expectEqualStrings("window-theme = dark\nfont-size = 14\nwindow-show-tab-bar = auto\nbackground-opacity = 0.875\nbackground-blur = true\nwindow-new-tab-position = end\ntab-inherit-working-directory = false\nwindows-background-material = mica\n", gui);
}

test "win32 settings replace ordered shader lists and overrides with explicit resets" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.ghostty", .data = "custom-shader = original.glsl\n" ++ gui_include ++ "\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = gui_file, .data = "custom-shader = stale.glsl\ncustom-shader-parameter = 2:OLD:1\nfont-size = 14\n" });
    try saveAt(io, alloc, tmp.dir, "config.ghostty", .{
        .@"custom-shader" = &.{ .{ .path = "C:\\Shaders\\First pass.glsl" }, .{ .path = "C:\\Shaders\\second.glsl", .optional = true } },
        .@"custom-shader-animation" = .false,
        .@"custom-shader-parameter" = &.{.{ .pass = 2, .name = "GAIN", .value = 0.75 }},
    });
    const updated = try readConfig(io, alloc, tmp.dir, gui_file);
    defer alloc.free(updated);
    try testing.expectEqualStrings(
        "font-size = 14\ncustom-shader-animation = false\n" ++
            "custom-shader =\ncustom-shader = \"C:\\Shaders\\First pass.glsl\"\ncustom-shader = ?\"C:\\Shaders\\second.glsl\"\n" ++
            "custom-shader-parameter =\ncustom-shader-parameter = 2:GAIN:0.75\n",
        updated,
    );
    try saveAt(io, alloc, tmp.dir, "config.ghostty", .{ .@"custom-shader" = &.{}, .@"custom-shader-parameter" = &.{} });
    const cleared = try readConfig(io, alloc, tmp.dir, gui_file);
    defer alloc.free(cleared);
    try testing.expectEqualStrings("font-size = 14\ncustom-shader-animation = false\ncustom-shader =\ncustom-shader-parameter =\n", cleared);
}

test "win32 themes keep explicit config colors and reset the managed selection" {
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const main = "# Keep these overrides.\r\nbackground = 223344\r\nwindow-theme = system\r\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "config.ghostty", .data = main });
    try tmp.dir.writeFile(io, .{ .sub_path = "Day", .data = "foreground = 112233\nbackground = ededed\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Night, bold", .data = "foreground = dcdcdc\nbackground = 111111\n" });
    const config_path = try tmp.dir.realPathFileAlloc(io, "config.ghostty", alloc);
    const theme: Config.Theme = .{
        .light = try tmp.dir.realPathFileAlloc(io, "Day", alloc),
        .dark = try tmp.dir.realPathFileAlloc(io, "Night, bold", alloc),
    };
    const value = (try ThemeSettings.format(alloc, theme)).?;
    try ThemeSettings.requireAvailable(alloc, try ThemeSettings.parse(alloc, value));
    try saveAt(io, gpa, tmp.dir, "config.ghostty", .{ .theme = value });
    try testing.expectEqualStrings(main ++ gui_include ++ "\r\n", try readConfig(io, alloc, tmp.dir, "config.ghostty"));

    var config = try Config.default(gpa);
    defer config.deinit();
    try config.loadFile(gpa, config_path);
    try config.loadRecursiveFiles(gpa);
    try config.finalize();
    try testing.expect(ThemeSettings.equal(theme, config.theme));
    try testing.expectEqual(@as(u32, 0x223344), Colors.fromConfig(&config).background);
    try testing.expectEqual(@as(u32, 0x112233), Colors.fromConfig(&config).foreground);
    var dark = (try config.changeConditionalState(.{ .theme = .dark })).?;
    defer dark.deinit();
    try testing.expectEqual(@as(u32, 0x223344), Colors.fromConfig(&dark).background);
    try testing.expectEqual(@as(u32, 0xdcdcdc), Colors.fromConfig(&dark).foreground);
    try testing.expectEqual(Config.WindowTheme.system, dark.@"window-theme");

    try saveAt(io, gpa, tmp.dir, "config.ghostty", .{ .theme = "" });
    try testing.expectEqualStrings("theme = \n", try readConfig(io, alloc, tmp.dir, gui_file));
    var reset = try Config.default(gpa);
    defer reset.deinit();
    try reset.loadFile(gpa, config_path);
    try reset.loadRecursiveFiles(gpa);
    try reset.finalize();
    try testing.expectEqual(null, reset.theme);
    try testing.expectEqual(@as(u32, 0x223344), Colors.fromConfig(&reset).background);
}
