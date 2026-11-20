//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs. The Window manages the tab
//! bar, tab switching, and window-level state (fullscreen, DPI scale).
const Window = @This();

const std = @import("std");
const lang = @import("UiLanguage.zig");
const build_config = @import("../../build_config.zig");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const Config = @import("../../config.zig").Config;
const Binding = @import("../../input.zig").Binding;

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabOverview = @import("TabOverview.zig");
const Icons = @import("Icons.zig");
const UiFont = @import("UiFont.zig");
const Profiles = @import("Profiles.zig");
const Progress = @import("Progress.zig");
const Settings = @import("Settings.zig");
const global = @import("../../global.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

test {
    _ = Progress;
    _ = UiFont;
}

/// Maximum number of tabs per window.
const MAX_TABS: usize = 64;
const WM_TOGGLE_TAB_OVERVIEW = w32.WM_APP + 5;
const WM_REFRESH_TAB_OVERVIEW = w32.WM_APP + 6;
const WM_REFRESH_PROGRESS = w32.WM_APP + 8;
const WM_CAPTURECHANGED = 0x0215;
const WM_CANCELMODE = 0x001F;
const SC_SETTINGS = 0x1FD0;
const TabButton = enum { new_tab, environment };
extern "user32" fn GetCapture() callconv(.winapi) ?w32.HWND;
extern "user32" fn GetSysColorBrush(i32) callconv(.winapi) ?w32.HBRUSH;
const TAB_HOVER_TIMER: usize = 0x5448;

/// The parent App.
app: *App,
process_elevated: bool = false,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Tab split trees owned by this window (fixed-capacity inline array).
tab_count: usize = 0,
tab_overview: TabOverview = .{},
overview_refresh_pending: bool = false,
tab_trees: [64]SplitTree(Surface) = undefined,

/// The currently focused surface within each tab.
tab_active_surface: [64]*Surface = undefined,

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Whether this window is configured to show the tab bar.
tab_bar_visible: bool = false,

/// Combine progress across live panes without tying it to the active tab.
progress: Progress = .{},
taskbar_progress: ?Progress = Progress{},
taskbar_ready: bool = false,
progress_refresh_pending: bool = false,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// Hit-test rectangles for each tab in the tab bar. Zero-initialized
/// so input handlers that read it before the first paint (e.g., a
/// synthetic WM_LBUTTONDOWN during startup) get a no-match instead of
/// stack garbage.
tab_rects: [64]w32.RECT = std.mem.zeroes([64]w32.RECT),

tab_buttons: [2]w32.RECT = std.mem.zeroes([2]w32.RECT),

/// Index of the tab currently being hovered (-1 = none).
hover_tab: isize = -1,

/// Whether the close button on the hovered tab is being hovered.
hover_close: bool = false,

hover_button: ?TabButton = null,

/// Tab drag state: which tab is being dragged (-1 = none).
drag_tab: isize = -1,
drag_previous_tab: usize = 0,
/// Client coordinates of the original press.
drag_start: w32.POINT = .{ .x = 0, .y = 0 },
/// Whether the drag has exceeded the threshold and is active.
drag_active: bool = false,
drag_on_strip: bool = false,
drag_x: i32 = 0,
drag_anchor: i32 = 0,
drop_slot: ?usize = null,
drag_label: ?w32.HWND = null,
drag_hover_tab: ?usize = null,
split_preview: ?w32.HWND = null,
preview_owner: ?w32.HWND = null,
preview_rect: ?w32.RECT = null,

/// Inline tab rename: Edit control HWND, font, and target tab index.
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_tab: usize = 0,
rename_window: bool = false,

tab_titles: [64]TabTitle = @splat(.{}),

/// Explicit top-level window title override. Null follows the active tab.
window_title_override_len: ?u16 = null,
window_title_override: [256]u16 = undefined,

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style for restoring from fullscreen.
saved_style: u32 = 0,

/// Saved window rect for restoring from fullscreen.
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

ui_font: UiFont = .{},
/// Font shared by the tab bar and the resize overlay.
tab_font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,

/// Temporary override from toggle_background_opacity, shared by every pane.
force_opaque: bool = false,
system_backdrop_active: bool = false,

/// Split divider drag state.
dragging_split: bool = false,
drag_split_handle: SplitTree(Surface).Node.Handle = .root,
drag_split_layout: SplitTree(Surface).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// True after the last tab has been closed and WM_CLOSE has been posted.
/// Input handlers must bail when this is set — between PostMessage(WM_CLOSE)
/// and the dispatch, queued mouse/keyboard messages can otherwise reach
/// handlers that allocate into a window about to be freed (e.g. the
/// new-tab "+" button calling addTab()).
closing: bool = false,

/// Optional resize limits in window-rect pixels (incl. non-client).
/// 0 means "no limit" — the OS default applies. Set by .size_limit
/// and consulted from WM_GETMINMAXINFO.
min_track_w: i32 = 0,
min_track_h: i32 = 0,
max_track_w: i32 = 0,
max_track_h: i32 = 0,

/// Transient "columns × rows" overlay shown while resizing
/// (resize-overlay config). Owned popup: destroyed with the window.
resize_overlay_hwnd: ?w32.HWND = null,

/// True once the initial WM_SIZE has been seen; resize-overlay =
/// after-first suppresses the overlay for that first layout pass.
resize_seen_first: bool = false,

pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    position: ?w32.POINT = null,
    /// If true, start fully opaque regardless of `background-opacity`. Set
    /// when `new_window` inherits from a parent window the user had
    /// toggled to opaque via `toggle_background_opacity`.
    force_opaque: bool = false,
};

/// Read HKCU\...\Themes\Personalize\AppsUseLightTheme. Returns true when the
/// system apps theme is light. A missing/erroring value is treated as light,
/// which is how the Personalize key reads before it is ever written.
pub fn systemUsesLightTheme() bool {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var hkey: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, subkey, 0, w32.KEY_READ, &hkey) !=
        w32.ERROR_SUCCESS) return true;
    defer _ = w32.RegCloseKey(hkey);
    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(hkey, valname, null, &kind, @ptrCast(&val), &cb) !=
        w32.ERROR_SUCCESS) return true;
    if (kind != w32.REG_DWORD or cb != @sizeOf(u32)) return true;
    return val != 0; // 0 = dark, nonzero = light
}

/// Apply the DWM dark/light title bar, honoring `window-theme`: dark/light
/// force the mode, `system` reads the OS apps theme, and `auto`/`ghostty`
/// fall back to the terminal background luminance. The caption is tinted to
/// the terminal background only for the luminance-derived themes; for the
/// explicit dark/light/system themes the caption is reset to the system
/// default so the standard themed title bar (and legible glyphs) is drawn.
fn applyChromeTheme(hwnd: w32.HWND, theme: Config.WindowTheme, bg: Config.Color, system_backdrop: bool) void {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    const by_luminance = luminance < 0.5;
    const dark = switch (theme) {
        .dark => true,
        .light => false,
        .system => !systemUsesLightTheme(),
        // `ghostty` is a Linux/GTK-only theme; treat it as auto on Windows.
        .auto, .ghostty => by_luminance,
    };

    const dark_mode: u32 = if (dark) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const tint_caption = !system_backdrop and switch (theme) {
        .auto, .ghostty => true,
        else => false,
    };
    const caption_color: u32 = if (tint_caption)
        w32.RGB(bg.r, bg.g, bg.b)
    else
        w32.DWMWA_COLOR_DEFAULT;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}

/// Enable/disable the DWM accent blur behind the window (background-blur).
/// Visible where the window is translucent (background-opacity < 1): the
/// desktop behind shows blurred instead of sharp, the acrylic-ish look.
fn applyBackgroundBlur(hwnd: w32.HWND, enabled: bool) void {
    var policy: w32.ACCENT_POLICY = .{
        .AccentState = if (enabled) w32.ACCENT_ENABLE_BLURBEHIND else w32.ACCENT_DISABLED,
        .AccentFlags = 0,
        .GradientColor = 0,
        .AnimationId = 0,
    };
    var data: w32.WINDOWCOMPOSITIONATTRIBDATA = .{
        .Attrib = w32.WCA_ACCENT_POLICY,
        .pvData = @ptrCast(&policy),
        .cbData = @sizeOf(w32.ACCENT_POLICY),
    };
    _ = w32.SetWindowCompositionAttribute(hwnd, &data);
}

fn setWindowOpacity(hwnd: w32.HWND, opacity: f64) void {
    const style = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
    const layered = style & w32.WS_EX_LAYERED != 0;
    if (opacity < 1) {
        if (!layered) _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, style | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(@max(opacity, 0) * 255));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    } else if (layered) {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, style & ~w32.WS_EX_LAYERED);
        _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_ERASE | w32.RDW_INVALIDATE | w32.RDW_FRAME | w32.RDW_ALLCHILDREN);
    }
}

fn setSystemBackdrop(hwnd: w32.HWND, material: w32.DWM_SYSTEMBACKDROP_TYPE) bool {
    const result = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_SYSTEMBACKDROP_TYPE, &material, @sizeOf(w32.DWM_SYSTEMBACKDROP_TYPE));
    if (result < 0) return false;
    const inset: i32 = if (material == .none) 0 else -1;
    if (w32.DwmExtendFrameIntoClientArea(hwnd, &.{ .left = inset, .right = inset, .top = inset, .bottom = inset }) >= 0) return true;
    if (material != .none) {
        const none: w32.DWM_SYSTEMBACKDROP_TYPE = .none;
        _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_SYSTEMBACKDROP_TYPE, &none, @sizeOf(w32.DWM_SYSTEMBACKDROP_TYPE));
    }
    return false;
}

pub fn opaqueSurfaceBackground(self: *const Window) bool {
    // A layered window already applies its opacity to the complete frame.
    // Only a system backdrop needs the renderer to emit translucent pixels.
    return !self.system_backdrop_active;
}

const BackgroundPresentation = struct {
    backdrop: w32.DWM_SYSTEMBACKDROP_TYPE = .none,
    window_opacity: f64 = 1,
    blur: bool = false,

    fn forRenderer(backend: @import("RendererStartup.zig").Backend, material: Config.WindowsBackgroundMaterial, opacity: f64, blur: bool, force_opaque: bool) BackgroundPresentation {
        // Win32 Vulkan presentation covers the system material with an opaque
        // client area. Layer the composed window to apply the configured opacity.
        if (backend == .vulkan and !force_opaque and material != .solid)
            return .{ .window_opacity = opacity };
        return BackgroundPresentation.init(material, opacity, blur, force_opaque);
    }

    fn init(material: Config.WindowsBackgroundMaterial, opacity: f64, blur: bool, force_opaque: bool) BackgroundPresentation {
        if (force_opaque) return .{};
        return switch (material) {
            .auto => .{
                .backdrop = if (blur and opacity < 1) .transient_window else .none,
                // These are the fallback values when DWM rejects the backdrop.
                .window_opacity = opacity,
                .blur = blur and opacity < 1,
            },
            .solid => .{},
            .mica => .{ .backdrop = .main_window },
            .acrylic => .{ .backdrop = .transient_window },
        };
    }
};

fn applyBackground(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const config = &self.app.config;
    const presentation = BackgroundPresentation.forRenderer(@import("RendererStartup.zig").active, config.@"windows-background-material", config.@"background-opacity", config.@"background-blur".enabled(), self.force_opaque);

    // Layered-window alpha and legacy accent blur can prevent DWM from
    // installing a system material. Remove them before enabling that material.
    if (presentation.backdrop != .none) {
        setWindowOpacity(hwnd, 1);
        applyBackgroundBlur(hwnd, false);
    }
    const system_supported = setSystemBackdrop(hwnd, presentation.backdrop);
    self.system_backdrop_active = system_supported and presentation.backdrop != .none;
    if (!self.system_backdrop_active) {
        setWindowOpacity(hwnd, presentation.window_opacity);
        applyBackgroundBlur(hwnd, presentation.blur);
    }
    applyChromeTheme(hwnd, config.@"window-theme", config.background, self.system_backdrop_active);

    const force_opaque = self.opaqueSurfaceBackground();
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.setOpaqueBackground(force_opaque);
    }
}

pub fn toggleBackgroundOpacity(self: *Window) void {
    if (self.app.config.@"background-opacity" >= 1 or self.app.config.@"windows-background-material" == .solid) return;
    self.force_opaque = !self.force_opaque;
    self.applyBackground();
    self.invalidateTabBar();
}

test "win32 window opacity and system backdrop have distinct composition paths" {
    for (std.enums.values(Config.WindowsBackgroundMaterial)) |material| {
        const expected = BackgroundPresentation{ .window_opacity = if (material == .solid) 1 else 0.4 };
        try std.testing.expectEqual(expected, BackgroundPresentation.forRenderer(.vulkan, material, 0.4, true, false));
        try std.testing.expectEqual(BackgroundPresentation{}, BackgroundPresentation.forRenderer(.vulkan, material, 0.4, true, true));
    }
    const automatic = BackgroundPresentation.init(.auto, 0.4, true, false);
    try std.testing.expectEqual(@as(f64, 0.4), automatic.window_opacity);
    try std.testing.expectEqual(w32.DWM_SYSTEMBACKDROP_TYPE.transient_window, automatic.backdrop);
    try std.testing.expect(automatic.blur);
    const clear = BackgroundPresentation.init(.auto, 0.4, false, false);
    try std.testing.expectEqual(w32.DWM_SYSTEMBACKDROP_TYPE.none, clear.backdrop);
    try std.testing.expectEqual(@as(f64, 0.4), clear.window_opacity);
    try std.testing.expect(!clear.blur);
    try std.testing.expectEqual(BackgroundPresentation{}, BackgroundPresentation.init(.auto, 1, true, false));
    for ([_]Config.WindowsBackgroundMaterial{ .mica, .acrylic }, [_]w32.DWM_SYSTEMBACKDROP_TYPE{ .main_window, .transient_window }) |material, expected| {
        const plan = BackgroundPresentation.init(material, 0.4, true, false);
        try std.testing.expectEqual(expected, plan.backdrop);
        try std.testing.expectEqual(@as(f64, 1), plan.window_opacity);
        try std.testing.expect(!plan.blur);
    }
    for (std.enums.values(Config.WindowsBackgroundMaterial)) |material|
        try std.testing.expectEqual(BackgroundPresentation{}, BackgroundPresentation.init(material, 0.4, true, true));
    try std.testing.expectEqual(BackgroundPresentation{}, BackgroundPresentation.init(.solid, 0.4, true, false));
}

fn refreshWindowFonts(self: *Window) void {
    self.ui_font.replace(&self.tab_font, 14, self.scale, &.{ self.resize_overlay_hwnd, self.drag_label });
    if (self.rename_edit != null) self.ui_font.replace(&self.rename_font, 12, self.scale, &.{self.rename_edit});
}

pub fn onConfigChange(self: *Window, background_changed: bool, ui_font_changed: bool) void {
    if (ui_font_changed) {
        self.ui_font = UiFont.resolve(self.app.config.@"windows-ui-font-family");
        self.refreshWindowFonts();
        for (self.tab_trees[0..self.tab_count]) |*tree| {
            var it = tree.iterator();
            while (it.next()) |entry| entry.view.refreshUiFonts();
        }
    }
    if (background_changed) self.force_opaque = false;
    self.applyBackground();
    self.tab_overview.updateAppearance();
    self.updateTabBarVisibility();
    self.invalidateTabBar();
    if (!self.app.config.@"progress-style") {
        for (self.tab_trees[0..self.tab_count]) |*tree| {
            var it = tree.iterator();
            while (it.next()) |entry| entry.view.progress = .{};
        }
        if (self.progress.state != .remove or self.taskbar_progress == null) self.queueProgressRefresh();
    }
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .process_elevated = processElevated(),
        .is_quick_terminal = options.is_quick_terminal,
        .force_opaque = options.force_opaque,
        .ui_font = UiFont.resolve(app.config.@"windows-ui-font-family"),
        .tab_bar_visible = !options.is_quick_terminal and app.config.@"window-show-tab-bar" == .always,
    };

    const style: u32 = if (options.is_quick_terminal)
        w32.WS_POPUP
    else if (app.config.@"window-decoration" == .none)
        // Borderless but still resizable: thin sizing frame, no title bar.
        w32.WS_POPUP | w32.WS_THICKFRAME
    else
        w32.WS_OVERLAPPEDWINDOW;
    const ex_style: u32 = if (options.is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0;

    // Cascade non-quick-terminal windows: stack each new window 30px
    // down/right of the most recently created window. Stops once the
    // offset would push the window off the work area, then resets.
    // Quick terminals are positioned by QuickTerminal.calculateRects.
    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;
    // Honor an explicit configured window position; it takes precedence over
    // the cascade below. Only when BOTH coordinates are set — passing
    // CW_USEDEFAULT for one axis is not a valid literal coordinate (Win32
    // only special-cases it on x, and would use a huge negative y or treat
    // y as nCmdShow), so a partial config falls back to full default.
    if (options.position) |position| {
        cx = position.x;
        cy = position.y;
    } else if (!options.is_quick_terminal) {
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| {
                cx = px;
                cy = py;
            }
        }
    }
    if (options.position == null and !options.is_quick_terminal and
        cx == w32.CW_USEDEFAULT and cy == w32.CW_USEDEFAULT and
        app.windows.items.len > 0)
    {
        // Find the previously created window's position and bump.
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                // Reset the cascade if it would push off-screen.
                if (cx + 800 > w32.GetSystemMetrics(0) or
                    cy + 600 > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        if (self.process_elevated) std.unicode.utf8ToUtf16LeStringLiteral("Admin: Madotty") else std.unicode.utf8ToUtf16LeStringLiteral("Madotty"),
        style,
        cx,
        cy,
        800,
        600,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Store the Window pointer in GWLP_USERDATA for the WndProc.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    if (!self.is_quick_terminal) {
        if (w32.GetSystemMenu(hwnd, 0)) |menu| {
            _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
            _ = w32.AppendMenuW(menu, w32.MF_STRING, SC_SETTINGS, lang.wide("Settings"));
        }
    }

    // Apply dark theme to common controls (scrollbar, etc.).
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    self.applyBackground();

    // Query DPI scale.
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    self.refreshWindowFonts();

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
}

/// Deinitialize the Window: close all tabs, delete font, destroy HWND.
pub fn deinit(self: *Window) void {
    self.tab_overview.deinit();
    // Close all tab surfaces.
    self.cleanupAllSurfaces();

    // Delete the tab bar font.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Returns the tab bar height in pixels, accounting for DPI scale.
/// Returns 0 if the tab bar is not visible.
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the tab bar height from the top.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    return rect;
}

/// Size a hidden handoff window in physical pixels before installing its tab.
pub fn resizeBeforeFirstTab(self: *Window, size: apprt.SurfaceSize) !void {
    std.debug.assert(self.tab_count == 0);
    const hwnd = self.hwnd orelse return error.Win32Error;
    var outer: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &outer) == 0) return error.Win32Error;
    const surface = self.surfaceRect();

    // Keep the existing frame and tab strip. Cap enormous grid requests to
    // the monitor work area before allocating a terminal or renderer.
    var limits: w32.RECT = .{ .left = 0, .top = 0, .right = std.math.maxInt(i32), .bottom = std.math.maxInt(i32) };
    var monitor: w32.MONITORINFO = undefined;
    monitor.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.GetMonitorInfoW(w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST), &monitor) != 0)
        limits = monitor.rcWork;

    const width = @as(i64, size.width) + (outer.right - outer.left) - (surface.right - surface.left);
    const height = @as(i64, size.height) + (outer.bottom - outer.top) - (surface.bottom - surface.top);
    if (w32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        @intCast(std.math.clamp(width, 1, limits.right - limits.left)),
        @intCast(std.math.clamp(height, 1, limits.bottom - limits.top)),
        w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOACTIVATE,
    ) == 0) return error.Win32Error;
}

/// Returns the currently active Surface, or null if there are no tabs.
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_active_surface[self.active_tab];
}

pub fn focusPane(self: *Window, surface: *Surface) void {
    const previous = self.getActiveSurface() orelse return;
    if (previous == surface) return;
    self.tab_active_surface[self.active_tab] = surface;
    self.invalidateTabBar();
}

/// Find the tab index containing a given surface.
/// Checks tab_active_surface first, then scans all trees.
pub fn findTabIndex(self: *Window, surface: *Surface) ?usize {
    for (self.tab_active_surface[0..self.tab_count], 0..) |s, i| {
        if (s == surface) return i;
    }
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return i;
        }
    }
    return null;
}

/// Find the Node.Handle for a surface in a given tab's tree.
fn findHandle(self: *Window, tab_idx: usize, surface: *Surface) ?SplitTree(Surface).Node.Handle {
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    return self.app.addDefaultTab(self, .{ .context = .tab });
}

pub const AddTabOptions = Surface.InitOptions;

/// Add a tab with per-surface configuration overrides.
pub fn addTabWithOptions(self: *Window, options: AddTabOptions) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabDrag();
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    surface.initWithOptions(self.app, self, options) catch |err| {
        if (!surface.leaked) alloc.destroy(surface);
        return err;
    };
    // After surface.init succeeds, create the SplitTree which takes ownership
    // via ref(). If this fails, we manually clean up.
    var tree = SplitTree(Surface).init(alloc, surface) catch |err| {
        surface.deinit();
        if (!surface.leaked) alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit(); // tree.deinit() calls unref() which deinits+frees surface

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) {
        self.tab_trees[i] = self.tab_trees[i - 1];
        self.tab_active_surface[i] = self.tab_active_surface[i - 1];
        self.tab_titles[i] = self.tab_titles[i - 1];
    }
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = surface;
    self.tab_count += 1;

    // The core can report a configured title before this tab enters the tree.
    self.tab_titles[pos] = .{};
    self.tab_titles[pos].len = @intCast(encodeTabTitle(self.tab_titles[pos].text[0..255], surface, surface.getTitle() orelse ""));

    if (self.tab_count == 1) {
        // First tab — show the parent window now that the terminal is ready.
        // Quick terminal windows are shown by QuickTerminal.animateIn() instead.
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                _ = w32.ShowWindow(h, options.initial_show);
                _ = w32.UpdateWindow(h);
            }
        }
        self.active_tab = pos;
        self.updateWindowTitle();
        // Set keyboard focus to the child surface so it receives input.
        const focus = switch (options.initial_show) {
            w32.SW_HIDE,
            w32.SW_SHOWMINIMIZED,
            w32.SW_SHOWNOACTIVATE,
            w32.SW_MINIMIZE,
            w32.SW_SHOWMINNOACTIVE,
            w32.SW_SHOWNA,
            w32.SW_FORCEMINIMIZE,
            => false,
            else => true,
        };
        if (!self.is_quick_terminal and focus) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateTabBar();
    return surface;
}

/// The core may hold the renderer lock during an action. Opening an owned
/// window changes focus and re-enters core handlers, so defer to the loop.
pub fn requestToggleTabOverview(self: *Window) bool {
    if (self.closing or self.is_quick_terminal or self.tab_count == 0) return false;
    return w32.PostMessageW(self.hwnd orelse return false, WM_TOGGLE_TAB_OVERVIEW, 0, 0) != 0;
}

/// Close every split in the selected tab, confirming once if any needs it.
pub fn requestCloseOverviewTab(self: *Window, id: u64) void {
    const index = TabOverview.findTab(self, id) orelse return;
    var it = self.tab_trees[index].iterator();
    var needs_confirmation = false;
    while (it.next()) |entry| {
        if (entry.view.core_surface_ready and entry.view.core_surface.needsConfirmQuit()) {
            needs_confirmation = true;
            break;
        }
    }
    if (!needs_confirmation) {
        self.closeTabByIndex(index);
        return;
    }

    const core_app = self.app.core_app;
    const owner_hwnd = self.hwnd;
    const result = w32.MessageBoxW(
        owner_hwnd,
        lang.wide("Processes are still running in this tab.\nClose the tab and all its splits?"),
        std.unicode.utf8ToUtf16LeStringLiteral("Madotty"),
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    );
    if (result != w32.IDOK) return;
    // The modal loop may have processed child exits or destroyed this
    // window. Resolve identity again; never dereference the old self.
    const surface = core_app.findSurfaceByID(id) orelse return;
    const owner = surface.rt_surface.parent_window;
    if (owner.closing or owner.hwnd != owner_hwnd) return;
    owner.closeTabByIndex(TabOverview.findTab(owner, id) orelse return);
}

/// Close a tab by surface pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, surface: *Surface) void {
    log.debug("closeTab called for surface={x} tab_count={}", .{ @intFromPtr(surface), self.tab_count });
    const idx = self.findTabIndex(surface) orelse return;
    self.closeTabByIndex(idx);
}

fn closeTabByIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    self.cancelTabDrag();
    // Cancel any in-progress rename (the edit control may belong to this tab).
    self.cancelTabRename();
    var tree = self.tab_trees[idx];
    tree.deinit(); // This unrefs all surfaces → Surface.unref frees when ref_count=0
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
    }
    self.tab_count -= 1;
    if (self.progress.state != .remove) self.queueProgressRefresh();
    if (self.tab_count == 0) {
        self.closing = true;
        self.tab_overview.hide(false);
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
}

/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => {
            var current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabByIndex(i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabByIndex(i);
            }
        },
    }
}

/// Close a single surface within a split tree. If it's the last surface
/// in the tab, close the entire tab instead.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(surface) orelse {
        log.debug("closeSplitSurface: surface not found in any tab", .{});
        return;
    };
    const tree = &self.tab_trees[tab];

    if (!tree.isSplit()) {
        log.debug("closeSplitSurface: not split, closing whole tab", .{});
        self.closeTab(surface);
        return;
    }

    const handle = self.findHandle(tab, surface) orelse {
        log.debug("closeSplitSurface: handle not found", .{});
        return;
    };
    log.debug("closeSplitSurface: removing handle={} from tab={}", .{ handle.idx(), tab });

    // Find next focus target BEFORE removing.
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);

    // Extract the surface pointer from the next handle before we modify the tree.
    const next_surface: ?*Surface = if (next_handle) |nh| blk: {
        break :blk switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    } else null;
    log.debug("closeSplitSurface: has_next={}", .{next_surface != null});

    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove surface from split tree", .{});
        return;
    };
    log.debug("closeSplitSurface: remove returned, new_tree nodes={}", .{new_tree.nodes.len});

    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    if (self.progress.state != .remove) self.queueProgressRefresh();

    if (next_surface) |ns| {
        log.debug("closeSplitSurface: focusing next surface", .{});
        self.tab_active_surface[tab] = ns;
        self.refreshPaneTitle(tab);
        self.onTabTitleChanged(ns, ns.getTitle() orelse "");
        self.layoutSplits();
        if (!self.tab_overview.active) {
            if (ns.hwnd) |h| _ = w32.SetFocus(h);
        }
        self.invalidateTabBar();
    } else {
        log.debug("closeSplitSurface: no next surface, closing tab", .{});
        self.closeTabByIndex(tab);
    }
}

/// Whether the top-level window can display its active tab. A layout pass can
/// run while hidden (quick terminal, toggle_visibility) or minimized.
fn isVisible(self: *const Window) bool {
    const hwnd = self.hwnd orelse return false;
    return w32.IsWindowVisible_(hwnd) != 0 and w32.IsIconic(hwnd) == 0;
}

/// Publish parent visibility without exposing panes hidden by split zoom.
fn setActiveTabVisible(self: *Window, visible: bool) void {
    if (self.active_tab >= self.tab_count) return;
    const tree = self.tab_trees[self.active_tab];
    var it = tree.iterator();
    while (it.next()) |entry| {
        entry.view.setVisible(visible and (tree.zoomed == null or entry.handle == tree.zoomed.?));
    }
}

/// Switch to the tab at the given index.
pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    self.cancelTabRename();
    self.cancelTabDrag();
    self.showTab(idx, true);
}

fn showTab(self: *Window, idx: usize, focus: bool) void {
    if (self.active_tab < self.tab_count) {
        var it = self.tab_trees[self.active_tab].iterator();
        while (it.next()) |entry| {
            entry.view.setVisible(false);
            if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }
    self.active_tab = idx;
    const surface = self.tab_active_surface[idx];
    self.layoutSplits();
    // An inactive child can exit while the user is searching. Keep focus
    // in the overview; explicit activation hides it before selecting.
    if (focus and !self.tab_overview.active) {
        if (surface.hwnd) |h| _ = w32.SetFocus(h);
    }
    self.updateWindowTitle();
    self.invalidateTabBar();
}

/// Layout split panes for the active tab.
pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                entry.view.setVisible(self.isVisible());
                if (entry.view.hwnd) |h| {
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                entry.view.setVisible(false);
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }
    self.layoutNode(tree, .root, rect);

    // Paint divider lines directly using GetDC (not BeginPaint, which
    // clips to the invalid region and misses the content area gaps).
    if (self.hwnd) |hwnd| {
        const hdc = w32.GetDC(hwnd);
        if (hdc) |dc| {
            self.paintDividers(dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }
}

fn layoutNode(self: *Window, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            view.setVisible(self.isVisible());
            if (view.hwnd) |h| {
                const w = @max(rect.right - rect.left, 1);
                const ht = @max(rect.bottom - rect.top, 1);
                _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, left_rect);
                self.layoutNode(tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, top_rect);
                self.layoutNode(tree, s.right, bottom_rect);
            }
        },
    }
}

/// Paint divider lines between split panes in the active tab.
fn paintDividers(self: *Window, hdc: w32.HDC) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const rect = self.surfaceRect();
    self.paintDividerNode(hdc, tree, .root, rect);
}

fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const line_w: i32 = @max(@as(i32, @intFromFloat(@round(1.0 * self.scale))), 1);

            const pen = w32.CreatePen(0, line_w, 0x00808080) orelse return;
            defer _ = w32.DeleteObject(pen);
            const old_pen = w32.SelectObject(hdc, pen);
            defer _ = w32.SelectObject(hdc, old_pen);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                _ = w32.MoveToEx(hdc, split_x, rect.top, null);
                _ = w32.LineTo(hdc, split_x, rect.bottom);
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, left_rect);
                self.paintDividerNode(hdc, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                _ = w32.MoveToEx(hdc, rect.left, split_y, null);
                _ = w32.LineTo(hdc, rect.right, split_y);
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, top_rect);
                self.paintDividerNode(hdc, tree, s.right, bottom_rect);
            }
        },
    }
}

const DividerHit = struct {
    handle: SplitTree(Surface).Node.Handle,
    layout: SplitTree(Surface).Split.Layout,
};

fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    if (self.tab_count == 0) return null;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return self.hitTestDividerNode(tree, .root, rect, x, y);
}

fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(Surface),
    handle: SplitTree(Surface).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?DividerHit {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            const gap: i32 = @as(i32, @intFromFloat(@round(5.0 * self.scale)));
            const hit_area: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 3);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                if (x >= split_x - hit_area and x <= split_x + hit_area and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, left_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, right_rect, x, y);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                if (y >= split_y - hit_area and y <= split_y + hit_area and x >= rect.left and x <= rect.right) {
                    return .{ .handle = handle, .layout = .vertical };
                }
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, top_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, bottom_rect, x, y);
            }
        },
    }
}

fn startDividerDrag(self: *Window, handle: SplitTree(Surface).Node.Handle, layout: SplitTree(Surface).Split.Layout) void {
    self.dragging_split = true;
    self.drag_split_handle = handle;
    self.drag_split_layout = layout;
    self.drag_start_rect = self.surfaceRect();
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const rect = self.drag_start_rect;
    const handle = self.drag_split_handle;

    const new_ratio: f16 = switch (self.drag_split_layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
            const pos: f32 = @floatFromInt(x - rect.left);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(rect.bottom - rect.top, 1));
            const pos: f32 = @floatFromInt(y - rect.top);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
    };

    self.tab_trees[self.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}

fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}

/// Create a new split in the active tab.
pub fn newSplit(self: *Window, direction: SplitTree(Surface).Split.Direction) !void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    // Create new surface.
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        if (!new_surface.leaked) alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self, .split);
    // A plain named shell profile can also be launched by the split command.
    if (active_surface.plain_profile and active_surface.launch_exe != null and
        active_surface.launch_exe == new_surface.launch_exe)
    {
        new_surface.profile_id = active_surface.profile_id;
        new_surface.plain_profile = true;
        new_surface.launch_title_len = active_surface.launch_title_len;
        @memcpy(new_surface.launch_title[0..new_surface.launch_title_len], active_surface.launch_title[0..active_surface.launch_title_len]);
    }

    // Create a single-node tree for the new surface.
    var insert_tree = try SplitTree(Surface).init(alloc, new_surface);
    defer insert_tree.deinit();

    // Split the current tree at the active surface.
    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    // Replace old tree.
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    self.refreshPaneTitle(tab);

    // Focus the new surface.
    self.focusPane(new_surface);

    self.layoutSplits();
    if (new_surface.hwnd) |h| _ = w32.SetFocus(h);
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const target: SplitTree(Surface).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;

    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |surface| {
            self.focusPane(surface);
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        },
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const layout: SplitTree(Surface).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    const delta: f16 = @floatCast(sign * @as(f32, @floatFromInt(rs.amount)) / dimension);

    const new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Equalize all splits in the active tab.
pub fn equalizeSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Toggle zoom on the active split surface.
pub fn toggleSplitZoom(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    var tree = &self.tab_trees[tab];

    if (!tree.isSplit()) return;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}

fn tabTargetIndex(target: apprt.action.GotoTab, active: usize, count: usize) ?usize {
    if (count <= 1) return null;
    return switch (target) {
        .previous => if (active > 0) active - 1 else count - 1,
        .next => if (active + 1 < count) active + 1 else 0,
        .last => count - 1,
        _ => blk: {
            // Numeric goto_tab actions use one-based positions.
            const raw = @backingInt(target);
            if (raw <= 0) return null;
            break :blk @min(count, @as(usize, @intCast(raw))) - 1;
        },
    };
}

/// Navigate to a tab by GotoTab target (previous, next, last, or position).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    const idx = tabTargetIndex(target, self.active_tab, self.tab_count) orelse return false;
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

test "tab bar numbered actions select one-based positions" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 0), tabTargetIndex(@fromBackingInt(1), 2, 3));
    try testing.expectEqual(@as(?usize, 1), tabTargetIndex(@fromBackingInt(2), 0, 3));
    try testing.expectEqual(@as(?usize, 2), tabTargetIndex(@fromBackingInt(8), 0, 3));
    try testing.expectEqual(@as(?usize, 2), tabTargetIndex(.last, 0, 3));
    try testing.expectEqual(@as(?usize, null), tabTargetIndex(@fromBackingInt(0), 0, 3));
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tab_count <= 1) return;
    const n: isize = @intCast(self.active_tab);
    const count: isize = @intCast(self.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == self.active_tab) return;

    // Swap all tab state between active_tab and new_index.
    std.mem.swap(SplitTree(Surface), &self.tab_trees[self.active_tab], &self.tab_trees[new_index]);
    std.mem.swap(*Surface, &self.tab_active_surface[self.active_tab], &self.tab_active_surface[new_index]);
    std.mem.swap(TabTitle, &self.tab_titles[self.active_tab], &self.tab_titles[new_index]);
    self.active_tab = new_index;
    self.invalidateTabBar();
}

/// Move the tab containing `surface`, including all of its splits, into a new
/// native window without restarting any child processes.
pub fn moveTabToNewWindow(self: *Window, surface: *Surface) !bool {
    if (self.tab_count <= 1) return false;
    return self.moveTabToNewWindowAt(surface, null);
}

fn moveTabToNewWindowAt(self: *Window, surface: *Surface, position: ?w32.POINT) !bool {
    if (self.is_quick_terminal or self.closing) return false;
    const tab_idx = self.findTabIndex(surface) orelse return false;

    const alloc = self.app.core_app.alloc;
    const destination = try alloc.create(Window);
    destination.init(self.app, .{ .position = position }) catch |err| {
        alloc.destroy(destination);
        return err;
    };
    errdefer {
        destination.deinit();
        alloc.destroy(destination);
    }

    try self.app.windows.append(alloc, destination);
    errdefer _ = self.app.windows.pop();
    try self.transferTab(tab_idx, destination, 0);
    return true;
}

fn transferTab(self: *Window, tab_idx: usize, destination: *Window, slot: usize) !void {
    if (destination.tab_count >= MAX_TABS or slot > destination.tab_count) return error.TooManyTabs;
    const destination_hwnd = destination.hwnd orelse return error.Win32Error;
    var moved_tree = self.tab_trees[tab_idx];

    // Move child HWNDs and owned popups before mutating either tab array.
    try reparentTabWindows(&moved_tree, self.hwnd.?, destination_hwnd);

    const moved_active = self.tab_active_surface[tab_idx];
    const moved_title = self.tab_titles[tab_idx];

    self.removeTransferredTab(tab_idx);

    destination.cancelTabRename();
    const append = destination.tab_count;
    destination.tab_trees[append] = moved_tree;
    destination.tab_active_surface[append] = moved_active;
    destination.tab_titles[append] = moved_title;
    destination.tab_count += 1;

    destination.adoptTabPanes(&moved_tree);
    if (self.progress.state != .remove) self.queueProgressRefresh();
    if (destination.tabProgress(append).state != .remove) destination.queueProgressRefresh();

    if (self.tab_count != 0) {
        self.selectTabIndex(self.active_tab);
        self.updateTabBarVisibility();
        self.invalidateTabBar();
    }

    destination.updateTabBarVisibility();
    destination.selectTabIndex(append);
    destination.moveTabTo(append, slot);
    _ = w32.SetForegroundWindow(destination_hwnd);
    _ = w32.ShowWindow(destination_hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(destination_hwnd);
    destination.layoutSplits();
    if (moved_active.hwnd) |h| _ = w32.SetFocus(h);
    if (self.tab_count == 0) {
        self.closing = true;
        self.tab_overview.hide(false);
        if (self.hwnd) |h| _ = w32.PostMessageW(h, w32.WM_CLOSE, 0, 0);
    }
}

/// Splice the dragged tab's entire tree alongside an existing pane. Both
/// trees keep their references until allocation and HWND transfers succeed.
pub fn mergeTabIntoPane(self: *Window, tab_idx: usize, destination: *Window, target: *Surface, direction: SplitTree(Surface).Split.Direction) !void {
    if (self.closing or destination.closing or self.is_quick_terminal or destination.is_quick_terminal or
        self.app != destination.app or tab_idx >= self.tab_count) return error.InvalidTabTarget;
    const target_tab = destination.findTabIndex(target) orelse return error.InvalidTabTarget;
    if (self == destination and tab_idx == target_tab) return error.InvalidTabTarget;
    const handle = destination.findHandle(target_tab, target) orelse return error.InvalidTabTarget;
    const source_hwnd = self.hwnd orelse return error.Win32Error;
    const destination_hwnd = destination.hwnd orelse return error.Win32Error;
    const moved_active = self.tab_active_surface[tab_idx];
    var moved = self.tab_trees[tab_idx];
    var original = destination.tab_trees[target_tab];
    var joined = try original.split(self.app.core_app.alloc, handle, direction, 0.5, &moved);
    errdefer joined.deinit();
    if (self != destination) try reparentTabWindows(&moved, source_hwnd, destination_hwnd);

    // Commit both arrays before calling native UI functions: focus and size
    // messages may immediately look up a moved pane in its new owner.
    destination.tab_trees[target_tab] = joined;
    destination.tab_active_surface[target_tab] = moved_active;
    destination.refreshPaneTitle(target_tab);
    self.removeTransferredTab(tab_idx);
    const new_index = if (self == destination and tab_idx < target_tab) target_tab - 1 else target_tab;
    if (self != destination) destination.adoptTabPanes(&moved);
    original.deinit();
    moved.deinit();

    if (self != destination) {
        if (self.progress.state != .remove) self.queueProgressRefresh();
        if (self.tab_count != 0) {
            self.selectTabIndex(self.active_tab);
            self.updateTabBarVisibility();
        } else {
            self.closing = true;
            self.tab_overview.hide(false);
            _ = w32.PostMessageW(source_hwnd, w32.WM_CLOSE, 0, 0);
        }
    }
    if (destination.tabProgress(new_index).state != .remove) destination.queueProgressRefresh();
    destination.selectTabIndex(new_index);
    destination.updateTabBarVisibility();
    if (self != destination) _ = w32.SetForegroundWindow(destination_hwnd);
    if (moved_active.hwnd) |h| _ = w32.SetFocus(h);
}

/// Remove an array slot whose tree ownership has already been transferred.
fn removeTransferredTab(self: *Window, tab_idx: usize) void {
    var i = tab_idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
    }
    self.tab_count -= 1;
    if (self.active_tab > tab_idx) {
        self.active_tab -= 1;
    } else if (self.tab_count > 0 and self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    }
}

fn adoptTabPanes(destination: *Window, moved: *const SplitTree(Surface)) void {
    var it = moved.iterator();
    while (it.next()) |entry| entry.view.parent_window = destination;
    it = moved.iterator();
    while (it.next()) |entry| {
        entry.view.setOpaqueBackground(destination.opaqueSurfaceBackground());
        entry.view.applyDpiScale(destination.scale);
    }
}

fn reparentTabWindows(tree: *const SplitTree(Surface), source: w32.HWND, destination: w32.HWND) !void {
    const native = struct {
        extern "user32" fn GetFocus() callconv(.winapi) ?w32.HWND;
    };
    const previous_focus = native.GetFocus();
    errdefer if (previous_focus) |hwnd| {
        if (native.GetFocus() != hwnd) _ = w32.SetFocus(hwnd);
    };
    var moved: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        entry.view.reparentNativeWindows(destination) catch |err| {
            var rollback = tree.iterator();
            for (0..moved) |_| {
                rollback.next().?.view.reparentNativeWindows(source) catch |rollback_err| {
                    log.err("tab window transfer rollback failed: {}", .{rollback_err});
                };
            }
            return err;
        };
        moved += 1;
    }
}

test "tab drag split preserves pane identity and rolls back a failed cross-window merge" {
    const a = std.testing.allocator;
    var app: App = undefined;
    var core: @import("../../App.zig") = undefined;
    core.alloc = a;
    app.core_app = &core;
    app.config.@"window-show-tab-bar" = .never;
    var windows = [_]Window{ .{ .app = &app }, .{ .app = &app } };
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    defer for (&windows) |*window| {
        for (window.tab_trees[0..window.tab_count]) |*tree| tree.deinit();
        if (window.hwnd) |hwnd| _ = w32.DestroyWindow(hwnd);
    };
    for (&windows) |*window| {
        window.hwnd = w32.CreateWindowExW(0, class, empty, 0, 0, 0, 40, 40, null, null, null, null) orelse return error.Win32Error;
    }
    var panes: [3]Surface = undefined;
    for (&panes, 0..) |*pane, i| {
        const owner = &windows[@intFromBool(i == 2)];
        // The fixture holds one reference in addition to the owning tree.
        pane.* = .{ .app = &app, .parent_window = owner, .ref_count = 1 };
        pane.hwnd = w32.CreateWindowExW(0, class, empty, w32.WS_CHILD, 0, 0, 1, 1, owner.hwnd, null, null, null) orelse return error.Win32Error;
        const tab = owner.tab_count;
        owner.tab_trees[tab] = try .init(a, pane);
        owner.tab_active_surface[tab] = pane;
        owner.tab_titles[tab].len = 0;
        owner.tab_count += 1;
    }

    const source = &windows[0];
    const destination = &windows[1];
    try std.testing.expectError(error.InvalidTabTarget, source.mergeTabIntoPane(0, source, &panes[0], .left));
    try source.mergeTabIntoPane(0, source, &panes[1], .left);
    try std.testing.expectEqual(@as(usize, 1), source.tab_count);
    try std.testing.expect(source.getActiveSurface().? == &panes[0]);
    const first_split = source.tab_trees[0].nodes[0].split;
    try std.testing.expect(source.tab_trees[0].nodes[first_split.left.idx()].leaf == &panes[0]);
    try std.testing.expect(source.tab_trees[0].nodes[first_split.right.idx()].leaf == &panes[1]);

    panes[1].palette_hwnd = @ptrFromInt(1);
    try std.testing.expectError(error.Win32Error, source.mergeTabIntoPane(0, destination, &panes[2], .down));
    try std.testing.expectEqual(@as(usize, 1), source.tab_count);
    try std.testing.expectEqual(@as(usize, 1), destination.tab_count);
    for (&panes) |*pane| {
        try std.testing.expectEqual(@as(u32, 2), pane.ref_count);
        try std.testing.expectEqual(pane.parent_window.hwnd, w32.GetParent(pane.hwnd.?));
    }
    panes[1].palette_hwnd = null;
    try source.mergeTabIntoPane(0, destination, &panes[2], .down);
    try std.testing.expect(source.closing);
    try std.testing.expectEqual(@as(usize, 0), source.tab_count);
    try std.testing.expect(destination.getActiveSurface().? == &panes[0]);
    const nodes = destination.tab_trees[0].nodes;
    try std.testing.expect(nodes[nodes[0].split.left.idx()].leaf == &panes[2]);
    const subtree = nodes[nodes[0].split.right.idx()].split;
    try std.testing.expect(nodes[subtree.left.idx()].leaf == &panes[0]);
    try std.testing.expect(nodes[subtree.right.idx()].leaf == &panes[1]);
    for (&panes) |*pane| {
        try std.testing.expectEqual(@as(u32, 2), pane.ref_count);
        try std.testing.expect(pane.parent_window == destination);
        try std.testing.expectEqual(destination.hwnd, w32.GetParent(pane.hwnd.?));
    }
}

test "detached tab rolls back child and popup transfers" {
    const testing = std.testing;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    const source = w32.CreateWindowExW(0, class, empty, 0, 0, 0, 1, 1, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(source);
    const destination = w32.CreateWindowExW(0, class, empty, 0, 0, 0, 1, 1, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(destination);

    const first = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(first);
    const second = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(second);
    for ([_]*Surface{ first, second }) |surface| {
        surface.* = .{ .app = undefined };
        surface.hwnd = w32.CreateWindowExW(0, class, empty, w32.WS_CHILD, 0, 0, 1, 1, source, null, null, null) orelse return error.Win32Error;
        surface.search_hwnd = w32.CreateWindowExW(0, class, empty, w32.WS_POPUP, 0, 0, 1, 1, source, null, null, null) orelse return error.Win32Error;
    }
    // Fail after moving the first complete surface and the second surface's
    // child/search popup, exercising both levels of transaction rollback.
    second.palette_hwnd = @ptrFromInt(1);
    const nodes = [_]SplitTree(Surface).Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = @fromBackingInt(1), .right = @fromBackingInt(2) } },
        .{ .leaf = first },
        .{ .leaf = second },
    };
    const tree: SplitTree(Surface) = .{ .arena = undefined, .nodes = &nodes, .zoomed = null };
    try testing.expectError(error.Win32Error, reparentTabWindows(&tree, source, destination));
    for ([_]*Surface{ first, second }) |surface| {
        try testing.expectEqual(@as(?w32.HWND, source), w32.GetParent(surface.hwnd.?));
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(source))), w32.GetWindowLongPtrW(surface.search_hwnd.?, w32.GWLP_HWNDPARENT));
    }

    second.palette_hwnd = null;
    try reparentTabWindows(&tree, source, destination);
    for ([_]*Surface{ first, second }) |surface| {
        try testing.expectEqual(@as(?w32.HWND, destination), w32.GetParent(surface.hwnd.?));
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(destination))), w32.GetWindowLongPtrW(surface.search_hwnd.?, w32.GWLP_HWNDPARENT));
    }
}

fn processElevated() bool {
    const native = struct {
        extern "advapi32" fn GetTokenInformation(w32.HANDLE, u32, *u32, u32, *u32) callconv(.winapi) i32;
    };
    // GetCurrentProcessToken() is an inline Windows SDK pseudo-handle.
    const token: w32.HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
    const token_elevation = 20;
    var elevated: u32 = 0;
    var size: u32 = 0;
    return native.GetTokenInformation(token, token_elevation, &elevated, @sizeOf(u32), &size) != 0 and elevated != 0;
}

const TabTitle = struct {
    text: [256]u16 = undefined,
    len: u16 = 0,
    manual: bool = false,
    panes: [255]u16 = undefined,
    panes_len: u16 = 0,

    fn visible(self: *const TabTitle) []const u16 {
        if (!self.manual and self.panes_len != 0) return self.panes[0..self.panes_len];
        return self.text[0..self.len];
    }
};

pub fn tabLabel(self: *const Window, tab: usize) []const u16 {
    return self.tab_titles[tab].visible();
}

/// Recompute only when panes are added, removed or merged.
fn refreshPaneTitle(self: *Window, tab: usize) void {
    const title = &self.tab_titles[tab];
    title.panes_len = 0;
    const nodes = self.tab_trees[tab].nodes;
    if (nodes.len <= 1) return;
    const first = self.tab_active_surface[tab];
    var common = first.launch_title_len != 0;
    var count: usize = 0;
    for (nodes) |node| switch (node) {
        .leaf => |pane| {
            count += 1;
            common = common and pane.profile_id == first.profile_id and
                (first.profile_id != null or pane.launch_exe == first.launch_exe) and
                std.mem.eql(u16, pane.launch_title[0..pane.launch_title_len], first.launch_title[0..first.launch_title_len]);
        },
        .split => {},
    };
    var buf: [64]u8 = undefined;
    if (!common) {
        const formatted = lang.print(&buf, "{d} panes", .{count}) catch unreachable;
        title.panes_len = @intCast(encodeTitle(&title.panes, formatted));
        return;
    }
    const suffix = std.mem.print(&buf, " × {d}", .{count}) catch unreachable;
    var end: [32]u16 = undefined;
    const end_len = encodeTitle(&end, suffix);
    var len = @min(first.launch_title_len, title.panes.len - end_len);
    if (len != 0 and std.unicode.utf16IsHighSurrogate(first.launch_title[len - 1])) len -= 1;
    @memcpy(title.panes[0..len], first.launch_title[0..len]);
    @memcpy(title.panes[len..][0..end_len], end[0..end_len]);
    title.panes_len = @intCast(len + end_len);
}

pub fn setTabTitle(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const tab = self.findTabIndex(surface) orelse return;
    self.tab_titles[tab].manual = false;
    self.onTabTitleChanged(surface, if (title.len == 0) surface.getTitle() orelse "" else title);
    self.tab_titles[tab].manual = title.len != 0;
    self.invalidateTabBar();
}

const admin_prefix = std.unicode.utf8ToUtf16LeStringLiteral("Admin: ");
const DisplayTitleBuffer = [256 + admin_prefix.len + 1]u16;

fn displayTitle(buf: *DisplayTitleBuffer, title: []const u16, elevated: bool) [:0]const u16 {
    const prefix_len = if (elevated) admin_prefix.len else 0;
    @memcpy(buf[0..prefix_len], admin_prefix[0..prefix_len]);
    @memcpy(buf[prefix_len..][0..title.len], title);
    const end = prefix_len + title.len;
    buf[end] = 0;
    return buf[0..end :0];
}

/// Update the top-level window title to match the active tab's title.
fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0) return;
    const len = self.window_title_override_len orelse
        self.tab_titles[self.active_tab].len;
    const title = if (self.window_title_override_len != null) self.window_title_override[0..len] else self.tab_titles[self.active_tab].text[0..len];
    var buf: DisplayTitleBuffer = undefined;
    _ = w32.SetWindowTextW(hwnd, displayTitle(&buf, title, self.process_elevated));
}

/// Set or clear the explicit top-level window title override.
pub fn setWindowTitle(self: *Window, title: [:0]const u8) void {
    if (title.len == 0) {
        self.window_title_override_len = null;
    } else {
        self.window_title_override_len = @intCast(encodeTitle(&self.window_title_override, title));
    }
    self.updateWindowTitle();
}

/// Called when a tab's title changes. Updates the stored title
/// and refreshes the window title bar / tab bar if needed.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const tab_idx = self.findTabIndex(surface) orelse return;
    var buf: [255]u16 = undefined;
    const written = buf[0..encodeTabTitle(&buf, surface, title)];
    if (self.tab_titles[tab_idx].manual) return;
    const previous = self.tab_titles[tab_idx].text[0..self.tab_titles[tab_idx].len];
    if (std.mem.eql(u16, previous, written)) return;
    @memcpy(self.tab_titles[tab_idx].text[0..written.len], written);
    self.tab_titles[tab_idx].len = @intCast(written.len);
    if (tab_idx == self.active_tab and self.window_title_override_len == null) self.updateWindowTitle();
    self.invalidateTabBar();
}

fn encodeTabTitle(dest: []u16, surface: *const Surface, title: []const u8) usize {
    if (title.len != 0) return encodeTitle(dest, title);
    const label = if (surface.launch_title_len != 0) surface.launch_title[0..surface.launch_title_len] else std.unicode.utf8ToUtf16LeStringLiteral("Madotty");
    @memcpy(dest[0..label.len], label);
    return label.len;
}

test "tab bar title for panes groups profiles and restores a single pane title" {
    const Tree = SplitTree(Surface);
    var window: Window = .{ .app = undefined, .tab_count = 1 };
    var a: Surface = .{ .app = undefined, .profile_id = 1 };
    a.launch_title_len = encodeTitle(&a.launch_title, "PowerShell");
    var b = a;
    const nodes = [_]Tree.Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = @fromBackingInt(1), .right = @fromBackingInt(2) } },
        .{ .leaf = &a },
        .{ .leaf = &b },
    };
    window.tab_trees[0] = .{ .arena = undefined, .nodes = &nodes, .zoomed = null };
    window.tab_active_surface[0] = &a;
    window.refreshPaneTitle(0);
    window.onTabTitleChanged(&a, "build");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("PowerShell × 2"), window.tabLabel(0));

    // Distinct profiles can have exactly the same display name.
    b.profile_id = 2;
    window.refreshPaneTitle(0);
    const mixed = if (lang.isJapanese()) std.unicode.utf8ToUtf16LeStringLiteral("2個のペイン")[0..] else std.unicode.utf8ToUtf16LeStringLiteral("2 panes")[0..];
    try std.testing.expectEqualSlices(u16, mixed, window.tabLabel(0));
    window.setTabTitle(&a, "Workspace");
    window.onTabTitleChanged(&b, "other shell title");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Workspace"), window.tabLabel(0));
    window.setTabTitle(&a, "");
    try std.testing.expectEqualSlices(u16, mixed, window.tabLabel(0));

    window.tab_trees[0].nodes = nodes[1..2];
    window.refreshPaneTitle(0);
    window.onTabTitleChanged(&a, "build");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("build"), window.tabLabel(0));
}

test "tab bar title falls back to the launched profile after an empty title" {
    var pane: Surface = .{ .app = undefined };
    pane.launch_title_len = encodeTitle(&pane.launch_title, "開発用 PowerShell");
    var window: Window = .{ .app = undefined, .tab_count = 1 };
    window.tab_active_surface[0] = &pane;
    window.tab_titles[0].len = 0;
    window.onTabTitleChanged(&pane, "C:\\work");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\work"), window.tab_titles[0].text[0..window.tab_titles[0].len]);
    window.onTabTitleChanged(&pane, "");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("開発用 PowerShell"), window.tab_titles[0].text[0..window.tab_titles[0].len]);
}

pub fn encodeTitle(dest: []u16, title: []const u8) usize {
    // UTF-16 never uses more units than UTF-8 uses bytes. For longer input
    // find the largest prefix that fits, keeping surrogate pairs together.
    var end = title.len;
    if (end > dest.len) {
        end = 0;
        var remaining = dest.len;
        while (end < title.len and remaining > 0) {
            const bytes = std.unicode.utf8ByteSequenceLength(title[end]) catch return 0;
            const units: usize = if (bytes == 4) 2 else 1;
            if (units > remaining or bytes > title.len - end) break;
            remaining -= units;
            end += bytes;
        }
    }
    return std.unicode.utf8ToUtf16Le(dest, title[0..end]) catch 0;
}

test "tab bar title respects UTF-16 capacity at emoji and Japanese boundaries" {
    var storage: [4]u16 = undefined;
    for ([_][]const u8{ "ABCDE", "日本🚀語", "日本語🚀" }, [_][]const u8{ "ABCD", "日本🚀", "日本語" }) |input, expected| {
        const title = storage[0..encodeTitle(&storage, input)];
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, title);
        defer std.testing.allocator.free(utf8);
        try std.testing.expectEqualStrings(expected, utf8);
    }
}

test "elevation prefix follows active and overridden window titles" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    const hwnd = w32.CreateWindowExW(0, wide("STATIC"), wide(""), 0, 0, 0, 1, 1, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(hwnd);
    var window: Window = .{ .app = undefined, .hwnd = hwnd, .tab_count = 1 };
    const original = wide("作業 👻");
    @memcpy(window.tab_titles[0].text[0..original.len], original);
    window.tab_titles[0].len = original.len;
    var buf: DisplayTitleBuffer = undefined;
    window.updateWindowTitle();
    var len: usize = @intCast(w32.GetWindowTextW(hwnd, &buf, buf.len));
    try std.testing.expectEqualSlices(u16, original, buf[0..len]);
    window.process_elevated = true;
    window.setWindowTitle("開発");
    len = @intCast(w32.GetWindowTextW(hwnd, &buf, buf.len));
    try std.testing.expectEqualSlices(u16, wide("Admin: 開発"), buf[0..len]);
    window.setWindowTitle("");
    len = @intCast(w32.GetWindowTextW(hwnd, &buf, buf.len));
    try std.testing.expectEqualSlices(u16, wide("Admin: 作業 👻"), buf[0..len]);
    try std.testing.expectEqualSlices(u16, original, window.tab_titles[0].text[0..original.len]);
}

/// Update tab bar visibility based on config and tab count.
fn updateTabBarVisibility(self: *Window) void {
    if (self.is_quick_terminal) {
        self.tab_bar_visible = false;
        return;
    }
    const show_config = self.app.config.@"window-show-tab-bar";
    const should_show = switch (show_config) {
        .always => true,
        .auto => self.tab_count > 1,
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_overview.active and !self.overview_refresh_pending) {
        self.overview_refresh_pending = w32.PostMessageW(hwnd, WM_REFRESH_TAB_OVERVIEW, 0, 0) != 0;
    }
    self.invalidateTabStrip(hwnd);
}

fn invalidateTabStrip(self: *const Window, hwnd: w32.HWND) void {
    if (!self.tab_bar_visible) return;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return;
    rect.bottom = @min(rect.bottom, self.tabBarHeight());
    if (rect.right <= rect.left or rect.bottom <= rect.top) return;
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

test "tab bar repaint covers the resized client width" {
    const native = struct {
        extern "user32" fn GetUpdateRect(w32.HWND, *w32.RECT, i32) callconv(.winapi) i32;
    };
    // Hidden windows have no update region. Keep this visible popup offscreen
    // and nonactivating so the test can inspect the real GDI update bounds.
    const hwnd = w32.CreateWindowExW(w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), w32.WS_POPUP | w32.WS_VISIBLE_STYLE, -30000, 0, 800, 240, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(hwnd);
    var window: Window = .{ .app = undefined, .tab_bar_visible = true, .scale = 1.5 };
    for ([_]i32{ 800, 520, 1100 }) |width| {
        try std.testing.expect(w32.SetWindowPos(hwnd, null, 0, 0, width, 240, w32.SWP_NOMOVE | w32.SWP_NOACTIVATE | w32.SWP_NOZORDER) != 0);
        _ = w32.ValidateRect(hwnd, null);
        window.invalidateTabStrip(hwnd);
        var dirty: w32.RECT = undefined;
        try std.testing.expect(native.GetUpdateRect(hwnd, &dirty, 0) != 0);
        try std.testing.expectEqual(w32.RECT{ .left = 0, .top = 0, .right = width, .bottom = 48 }, dirty);
    }

    var surface: Surface = .{ .app = undefined };
    window.hwnd = hwnd;
    window.tab_count = 1;
    window.tab_active_surface[0] = &surface;
    window.tab_titles[0].len = 0;
    window.onTabTitleChanged(&surface, "日本語");
    _ = w32.ValidateRect(hwnd, null);
    var dirty: w32.RECT = undefined;
    window.onTabTitleChanged(&surface, "日本語");
    try std.testing.expectEqual(@as(i32, 0), native.GetUpdateRect(hwnd, &dirty, 0));
    window.onTabTitleChanged(&surface, "ターミナル");
    try std.testing.expect(native.GetUpdateRect(hwnd, &dirty, 0) != 0);
}

fn tabProgress(self: *const Window, index: usize) Progress {
    var result: Progress = .{};
    var panes = self.tab_trees[index].iterator();
    while (panes.next()) |entry| result = result.preferred(entry.view.progress);
    return result;
}

fn aggregateProgress(self: *const Window) Progress {
    var result: Progress = .{};
    for (0..self.tab_count) |index| result = result.preferred(self.tabProgress(index));
    return result;
}

test "win32 progress follows the live tabs and split panes" {
    const testing = std.testing;
    var running: Surface = .{ .app = undefined, .progress = .{ .state = .set, .value = 37 } };
    var failed: Surface = .{ .app = undefined, .progress = .{ .state = .@"error", .value = 64 } };
    var empty: Surface = .{ .app = undefined };
    var origin: Window = .{ .app = undefined, .tab_count = 2 };
    origin.tab_trees[0] = .{ .arena = undefined, .nodes = &.{.{ .leaf = &running }}, .zoomed = null };
    origin.tab_trees[1] = .{ .arena = undefined, .nodes = &.{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = @fromBackingInt(@intCast(1)), .right = @fromBackingInt(@intCast(2)) } },
        .{ .leaf = &empty },
        .{ .leaf = &failed },
    }, .zoomed = null };
    try testing.expectEqual(running.progress, origin.tabProgress(0));
    try testing.expectEqual(failed.progress, origin.tabProgress(1));
    try testing.expectEqual(failed.progress, origin.aggregateProgress());
    origin.active_tab = 1;
    try testing.expectEqual(failed.progress, origin.aggregateProgress());

    var destination: Window = .{ .app = undefined, .tab_count = 1 };
    destination.tab_trees[0] = origin.tab_trees[1];
    origin.tab_count = 1;
    try testing.expectEqual(running.progress, origin.aggregateProgress());
    try testing.expectEqual(failed.progress, destination.aggregateProgress());
    destination.tab_trees[0] = .{ .arena = undefined, .nodes = &.{.{ .leaf = &empty }}, .zoomed = null };
    try testing.expectEqual(Progress{}, destination.aggregateProgress());
    try testing.expectEqual(running.progress, origin.aggregateProgress());
}

/// Coalesce reports and update Explorer outside the core action dispatch.
pub fn queueProgressRefresh(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.is_quick_terminal or self.progress_refresh_pending) return;
    self.progress_refresh_pending = w32.PostMessageW(hwnd, WM_REFRESH_PROGRESS, 0, 0) != 0;
}

fn refreshProgress(self: *Window, hwnd: w32.HWND) void {
    self.progress_refresh_pending = false;
    const next = if (self.app.config.@"progress-style") self.aggregateProgress() else Progress{};
    const repaint = next.state != .remove or self.progress.state != .remove;
    self.progress = next;
    if (repaint and self.tab_bar_visible) self.invalidateTabStrip(hwnd);
    if (!self.taskbar_ready) return;
    if (self.taskbar_progress) |previous| {
        if (std.meta.eql(previous, next)) return;
    }
    const published = self.app.setTaskbarProgress(hwnd, self.taskbar_progress, next);
    // Shell COM can dispatch messages while updating a taskbar button.
    if (w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA) != @as(isize, @bitCast(@intFromPtr(self)))) return;
    self.taskbar_progress = if (published) next else null;
}

/// Fill the strip with adjacent tabs, retaining a minimum width on overflow.
fn layoutTabRects(
    rects: []w32.RECT,
    available_w: i32,
    bar_h: i32,
    min_tab_w: i32,
) i32 {
    const tab_count: i32 = @intCast(rects.len);
    if (tab_count == 0) return 0;
    const tab_w = @max(@divTrunc(available_w, tab_count), min_tab_w);
    const remainder: usize = @intCast(@max(available_w - tab_w * tab_count, 0));
    var x: i32 = 0;
    for (rects, 0..) |*rect, i| {
        const width = tab_w + @as(i32, @intFromBool(i < remainder));
        rect.* = .{ .left = x, .top = 0, .right = x + width, .bottom = bar_h };
        x += width;
    }
    return x;
}

/// Select the last tab midpoint crossed by a drag. Remainder pixels make the
/// fitted tabs differ by one pixel, so use their actual rectangles.
fn tabDragTarget(rects: []const w32.RECT, x: i32) usize {
    var target: usize = 0;
    for (rects, 0..) |rect, i| {
        if (x >= rect.left + @divTrunc(rect.right - rect.left, 2)) target = i;
    }
    return target;
}

test "tab bar fills fitted width and retains minimum widths on overflow" {
    const testing = std.testing;
    var rects: [3]w32.RECT = undefined;
    try testing.expectEqual(@as(i32, 965), layoutTabRects(&rects, 965, 32, 60));
    try testing.expectEqual(@as(i32, 322), rects[0].right - rects[0].left);
    try testing.expectEqual(@as(i32, 322), rects[1].right - rects[1].left);
    try testing.expectEqual(@as(i32, 321), rects[2].right - rects[2].left);
    try testing.expectEqual(rects[0].right, rects[1].left);
    try testing.expectEqual(rects[1].right, rects[2].left);
    try testing.expectEqual(@as(i32, 180), layoutTabRects(&rects, 100, 32, 60));
    for (rects) |rect| try testing.expectEqual(@as(i32, 60), rect.right - rect.left);
}

test "tab bar drag reorder follows actual nonuniform tab midpoints" {
    const testing = std.testing;
    // Only the first tab gets the remainder pixel. Multiplying its width
    // for every slot would put the final drag threshold a whole tab late.
    var rects: [64]w32.RECT = undefined;
    _ = layoutTabRects(&rects, 64 * 60 + 1, 32, 60);
    for (rects, 0..) |rect, i| {
        const midpoint = rect.left + @divTrunc(rect.right - rect.left, 2);
        try testing.expectEqual(i, tabDragTarget(&rects, midpoint));
        if (i > 0) try testing.expectEqual(i - 1, tabDragTarget(&rects, midpoint - 1));
    }
    try testing.expectEqual(@as(usize, 0), tabDragTarget(&rects, -100));
    try testing.expectEqual(@as(usize, 63), tabDragTarget(&rects, 10000));
}

test "tab bar shares the full track as tabs are added and keeps the buttons reachable" {
    const testing = std.testing;
    var window: Window = .{ .app = undefined, .tab_count = 1 };
    window.layoutTabStrip(800, 32);
    try testing.expectEqual(@as(i32, 736), window.tab_rects[0].right);
    window.tab_count = 2;
    window.layoutTabStrip(800, 32);
    try testing.expectEqual(@as(i32, 368), window.tab_rects[0].right);
    try testing.expectEqual(@as(i32, 368), window.tab_rects[1].left);
    try testing.expectEqual(@as(i32, 736), window.tab_rects[1].right);
    try testing.expectEqual(@as(?TabButton, .new_tab), window.tabButtonAt(736, 16));
    try testing.expectEqual(@as(?TabButton, .environment), window.tabButtonAt(768, 16));
    try testing.expectEqual(@as(?TabButton, null), window.tabButtonAt(768, 32));

    window.tab_count = 10;
    window.active_tab = 9;
    window.scale = 1.5;
    window.layoutTabStrip(380, 48);
    try testing.expectEqual(@as(?usize, 9), window.tabAt(283, 24));
    try testing.expectEqual(@as(?usize, null), window.tabAt(284, 24));
    try testing.expectEqual(@as(?TabButton, .new_tab), window.tabButtonAt(284, 24));
    try testing.expectEqual(@as(?TabButton, .environment), window.tabButtonAt(379, 24));
}

fn tabColor(bg: Config.Color, fg: Config.Color, weight: u8) u32 {
    const foreground: u16 = weight;
    const background: u16 = 255 - foreground;
    return w32.RGB(
        @intCast((@as(u16, bg.r) * background + @as(u16, fg.r) * foreground + 127) / 255),
        @intCast((@as(u16, bg.g) * background + @as(u16, fg.g) * foreground + 127) / 255),
        @intCast((@as(u16, bg.b) * background + @as(u16, fg.b) * foreground + 127) / 255),
    );
}

fn tabCloseRect(self: *const Window, tab: w32.RECT) w32.RECT {
    const size: i32 = @intFromFloat(@round(24.0 * self.scale));
    const inset: i32 = @intFromFloat(@round(4.0 * self.scale));
    const top = @divTrunc(self.tabBarHeight() - size, 2);
    return .{ .left = tab.right - inset - size, .top = top, .right = tab.right - inset, .bottom = top + size };
}

fn tabShortcuts(bindings: Binding.Set, hints: []?Binding.Trigger) void {
    @memset(hints, null);
    if (hints.len <= 1) return;
    var last: ?Binding.Trigger = null;
    var iterator = bindings.bindings.iterator();
    while (iterator.next()) |entry| {
        const action = switch (entry.value_ptr.*) {
            .leaf => |leaf| leaf.action,
            else => continue,
        };
        const hint = switch (action) {
            .goto_tab => |position| if (position > 0 and position <= hints.len)
                &hints[position - 1]
            else
                continue,
            .last_tab => &last,
            else => continue,
        };
        const trigger = entry.key_ptr.*;
        // The reverse map prefers configured bindings but omits the
        // performable defaults used for Alt+digit on Windows.
        const preferred = if (bindings.getTrigger(action)) |lookup|
            std.meta.eql(lookup, trigger)
        else
            false;
        if (hint.* == null or preferred) hint.* = trigger;
    }
    if (hints[hints.len - 1] == null) hints[hints.len - 1] = last;
}

test "tab bar shortcut hints follow active bindings and final tab" {
    var bindings: Binding.Set = .{};
    defer bindings.deinit(std.testing.allocator);
    const first: Binding.Trigger = .{ .key = .{ .physical = .digit_1 }, .mods = .{ .alt = true } };
    const last: Binding.Trigger = .{ .key = .{ .unicode = '9' }, .mods = .{ .ctrl = true } };
    try bindings.putFlags(std.testing.allocator, first, .{ .goto_tab = 1 }, .{ .performable = true });
    try bindings.putFlags(std.testing.allocator, last, .last_tab, .{ .performable = true });
    var hints: [3]?Binding.Trigger = undefined;
    tabShortcuts(bindings, hints[0..1]);
    try std.testing.expectEqual(@as(?Binding.Trigger, null), hints[0]);
    tabShortcuts(bindings, &hints);
    try std.testing.expectEqual(first, hints[0].?);
    try std.testing.expectEqual(@as(?Binding.Trigger, null), hints[1]);
    try std.testing.expectEqual(last, hints[2].?);

    const configured: Binding.Trigger = .{ .key = .{ .physical = .f1 } };
    try bindings.put(std.testing.allocator, configured, .{ .goto_tab = 1 });
    tabShortcuts(bindings, &hints);
    try std.testing.expectEqual(configured, hints[0].?);
}

fn containsPoint(rect: w32.RECT, x: i32, y: i32) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

fn tabButtonAt(self: *const Window, x: i32, y: i32) ?TabButton {
    for (self.tab_buttons, 0..) |rect, i| {
        if (containsPoint(rect, x, y)) return @fromBackingInt(@intCast(i));
    }
    return null;
}

fn tabAt(self: *const Window, x: i32, y: i32) ?usize {
    if (x < 0 or x >= self.tab_buttons[0].left) return null;
    for (self.tab_rects[0..self.tab_count], 0..) |rect, i| {
        if (containsPoint(rect, x, y)) return i;
    }
    return null;
}

fn layoutTabStrip(self: *Window, width: i32, height: i32) void {
    const button_width = @min(@divTrunc(width, 2), @as(i32, @intFromFloat(@round(32 * self.scale))));
    const available = width - 2 * button_width;
    const minimum: i32 = @intFromFloat(@round(72 * self.scale));
    const tabs = self.tab_rects[0..self.tab_count];
    const tab_width = layoutTabRects(tabs, available, height, minimum);
    if (tabs.len > 0 and tab_width > available) {
        const offset = @max(tabs[self.active_tab].right - available, 0);
        for (tabs) |*rect| {
            rect.left -= offset;
            rect.right -= offset;
        }
    }
    self.tab_buttons = .{
        .{ .left = available, .top = 0, .right = available + button_width, .bottom = height },
        .{ .left = available + button_width, .top = 0, .right = width, .bottom = height },
    };
}

fn drawPill(hdc: w32.HDC, rect: w32.RECT, inset: i32, color: u32) void {
    const diameter = @min(rect.right - rect.left, rect.bottom - rect.top) - 2 * inset;
    if (diameter <= 0) return;
    _ = w32.SetDCBrushColor(hdc, color);
    _ = w32.RoundRect(hdc, rect.left + inset, rect.top + inset, rect.right - inset, rect.bottom - inset, diameter, diameter);
}

fn drawTabProgress(self: *const Window, dc: w32.HDC, tab: w32.RECT, progress: Progress) void {
    const slot: usize = switch (progress.state) {
        .remove => return,
        .set, .indeterminate => 2,
        .@"error" => 1,
        .pause => 3,
    };
    const config = &self.app.config;
    const bg = config.background;
    const fg = config.foreground;
    const color = for ([_]usize{ slot, slot + 8 }) |index| {
        const rgb = config.palette.value[index];
        if (rgb.contrast(bg.toTerminalRGB()) >= 3) break w32.RGB(rgb.r, rgb.g, rgb.b);
    } else w32.RGB(fg.r, fg.g, fg.b);

    const width = @min(
        tab.right - tab.left - @as(i32, @intFromFloat(@round(20 * self.scale))),
        @as(i32, @intFromFloat(@round(64 * self.scale))),
    );
    if (width < 5) return;
    const height = @max(1, @as(i32, @intFromFloat(@round(2 * self.scale))));
    const bottom = tab.bottom - @as(i32, @intFromFloat(@round(5 * self.scale)));
    const left = tab.left + @divTrunc(tab.right - tab.left - width, 2);
    var track: w32.RECT = .{ .left = left, .top = bottom - height, .right = left + width, .bottom = bottom };
    drawPill(dc, track, 0, tabColor(bg, fg, 68));
    if (progress.state == .indeterminate) {
        const dash = @min(height + 1, @divTrunc(width, 5));
        for (0..3) |index| {
            track.left = left + @divTrunc(width - 5 * dash, 2) + 2 * dash * @as(i32, @intCast(index));
            track.right = track.left + dash;
            drawPill(dc, track, 0, color);
        }
    } else if (progress.value != 0) {
        track.right = left + @max(1, @divTrunc(width * progress.value + 50, 100));
        drawPill(dc, track, 0, color);
    }
}

fn drawNewTabControl(self: *const Window, dc: w32.HDC, brush: w32.HBRUSH, bg: Config.Color, fg: Config.Color, inset: i32) void {
    const plus = self.tab_buttons[@backingInt(TabButton.new_tab)];
    const menu = self.tab_buttons[@backingInt(TabButton.environment)];
    if (plus.right - plus.left <= 2 * inset) return;
    const control: w32.RECT = .{ .left = plus.left, .top = plus.top, .right = menu.right, .bottom = menu.bottom };
    drawPill(dc, control, inset, tabColor(bg, fg, 15));
    if (self.hover_button) |button| {
        const half = self.tab_buttons[@backingInt(button)];
        const saved = w32.SaveDC(dc);
        if (saved != 0) {
            _ = w32.IntersectClipRect(dc, half.left, half.top, half.right, half.bottom);
            drawPill(dc, control, inset, tabColor(bg, fg, 30));
            _ = w32.RestoreDC(dc, saved);
        }
    }

    const divider_inset: i32 = @intFromFloat(@round(9 * self.scale));
    const divider: w32.RECT = .{
        .left = menu.left,
        .top = control.top + divider_inset,
        .right = menu.left + @max(1, @as(i32, @intFromFloat(@round(self.scale)))),
        .bottom = control.bottom - divider_inset,
    };
    _ = w32.SetDCBrushColor(dc, tabColor(bg, fg, 43));
    _ = w32.FillRect(dc, &divider, brush);

    if (self.app.tab_icon_renderer != null) {
        const painter = Icons.Painter.init(dc, tabColor(bg, fg, 220)) orelse return;
        defer painter.deinit();
        const size = 18 * self.scale;
        painter.draw(.plus, .{ .left = plus.left + inset, .top = plus.top, .right = divider.left, .bottom = plus.bottom }, size);
        painter.draw(.chevron_down, .{ .left = divider.right, .top = menu.top, .right = menu.right - inset, .bottom = menu.bottom }, size);
    }
}

/// Paint the tab bar using double-buffered GDI painting.
/// Draws tab backgrounds, text labels, close buttons (x), and the new-tab (+) button.
fn paintTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;

    var ps: w32.PAINTSTRUCT = undefined;
    const hdc_screen = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    // If the tab bar is not visible, just validate the region and return.
    if (!self.tab_bar_visible) return;

    const bar_h = self.tabBarHeight();
    if (bar_h <= 0) return;

    // Get client rect width.
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_w = client_rect.right - client_rect.left;
    const dirty = w32.RECT{
        .left = @max(0, ps.rcPaint.left),
        .top = @max(0, ps.rcPaint.top),
        .right = @min(client_w, ps.rcPaint.right),
        .bottom = @min(bar_h, ps.rcPaint.bottom),
    };
    if (dirty.left >= dirty.right or dirty.top >= dirty.bottom) return;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    var bitmap_bits: ?*anyopaque = null;
    const mem_bmp = if (self.system_backdrop_active)
        w32.CreateDIBSection(hdc_screen, &.{ .bmiHeader = .{ .biWidth = client_w, .biHeight = -bar_h } }, w32.DIB_RGB_COLORS, &bitmap_bits, null, 0) orelse return
    else
        w32.CreateCompatibleBitmap(hdc_screen, client_w, bar_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    const bg = self.app.config.background;
    const fg = self.app.config.foreground;
    const bar_color = w32.RGB(bg.r, bg.g, bg.b);
    const hover_color = tabColor(bg, fg, 16);
    const active_bg_color = tabColor(bg, fg, 25);
    const close_hover_color = tabColor(bg, fg, 40);
    const active_text_color = w32.RGB(fg.r, fg.g, fg.b);
    const inactive_text_color = tabColor(bg, fg, 195);
    const hint_color = tabColor(bg, fg, 155);
    const brush: w32.HBRUSH = @ptrCast(w32.GetStockObject(w32.DC_BRUSH) orelse return);

    // --- Fill bar background ---
    _ = w32.SetDCBrushColor(mem_dc, bar_color);
    _ = w32.FillRect(mem_dc, &dirty, brush);

    // --- Select font and set text mode ---
    var old_font: ?*anyopaque = null;
    if (self.tab_font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);
    const old_brush = w32.SelectObject(mem_dc, brush);
    defer _ = w32.SelectObject(mem_dc, old_brush);
    const old_pen = w32.SelectObject(mem_dc, w32.GetStockObject(w32.NULL_PEN) orelse return);
    defer _ = w32.SelectObject(mem_dc, old_pen);

    self.layoutTabStrip(client_w, bar_h);
    const title_pad: i32 = @intFromFloat(@round(28.0 * self.scale));
    const hint_gap: i32 = @intFromFloat(@round(6 * self.scale));
    const inset: i32 = @intFromFloat(@round(4.0 * self.scale));
    const tab_area_right = self.tab_buttons[0].left;
    const saved_dc = w32.SaveDC(mem_dc);
    if (saved_dc == 0) return;
    _ = w32.IntersectClipRect(mem_dc, 0, 0, tab_area_right, bar_h);
    var shortcuts: [MAX_TABS]?Binding.Trigger = undefined;
    tabShortcuts(self.app.config.keybind.set, shortcuts[0..self.tab_count]);
    const common_shell = mostFrequentShell(self.tab_active_surface[0..self.tab_count]);

    // --- Draw each tab ---
    // The floating tab is only the reorder preview. Once a hover reveals
    // another tab, show its real position and keep the pane target visible.
    const dragged: ?usize = if (self.drag_active and self.drag_on_strip and
        self.drag_hover_tab != self.active_tab) @intCast(self.drag_tab) else null;
    for (0..self.tab_count) |order| {
        // Draw the moving tab above its neighbours.
        const i = if (dragged) |d| (if (order + 1 == self.tab_count) d else if (order >= d) order + 1 else order) else order;
        var visual = self.tab_rects[i];
        if (dragged) |d| {
            const home = self.tab_rects[d];
            const width = home.right - home.left;
            const left = std.math.clamp(self.drag_x - self.drag_anchor, 0, @max(0, tab_area_right - width));
            const shift = if (i == d) left - home.left else if (i > d)
                -std.math.clamp(left + width - visual.left, 0, width)
            else
                std.math.clamp(visual.right - left, 0, width);
            visual.left += shift;
            visual.right += shift;
        }
        const is_active = (i == self.active_tab);
        const is_hovered = (@as(isize, @intCast(i)) == self.hover_tab);
        const x = visual.left;
        const this_tab_w = visual.right - x;

        if (visual.right <= dirty.left or x >= @min(dirty.right, tab_area_right)) continue;
        if (is_active or is_hovered)
            drawPill(mem_dc, visual, inset, if (is_active) active_bg_color else hover_color);
        if (self.app.config.@"progress-style" and self.progress.state != .remove)
            self.drawTabProgress(mem_dc, visual, self.tabProgress(i));

        const flags = w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX;
        const close_rect = self.tabCloseRect(visual);
        var padding = title_pad;
        if (shortcuts[i]) |trigger| {
            var utf8: [64]u8 = undefined;
            const bytes = Surface.formatTrigger(trigger, &utf8);
            var label: [64]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&label, utf8[0..bytes]) catch 0;
            if (len != 0) {
                var measured = std.mem.zeroes(w32.RECT);
                _ = w32.DrawTextW(mem_dc, &label, @intCast(len), &measured, flags | w32.DT_CALCRECT);
                // Keep a stable slot next to the close button, including on
                // hover. The shortcut is part of the tab's accessory area.
                const hint_right = close_rect.left - hint_gap;
                const with_hint = @max(title_pad, visual.right - hint_right + measured.right + hint_gap);
                // Let the hint give up its space before the title gets too short.
                if (this_tab_w >= 2 * with_hint + 10 * inset) {
                    padding = with_hint;
                    var rect: w32.RECT = .{ .left = x + this_tab_w - with_hint, .top = 0, .right = hint_right, .bottom = bar_h };
                    _ = w32.SetTextColor(mem_dc, hint_color);
                    _ = w32.DrawTextW(mem_dc, &label, @intCast(len), &rect, flags | w32.DT_RIGHT);
                }
            }
        }

        const tab_label = self.tabLabel(i);
        const show_admin = is_active and self.process_elevated and
            (self.is_fullscreen or self.app.config.@"window-decoration" == .none);
        if (tab_label.len > 0 or show_admin) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            var title = tabTitleLayout(this_tab_w, padding, inset, is_hovered);
            if (self.tab_active_surface[i].tab_shell) |shell| {
                if (shell.id != common_shell) {
                    const size = 4 * inset;
                    const leading = 2 * inset + size + inset;
                    // On the narrowest tabs the close affordance takes
                    // priority over the icon while the pointer is inside.
                    if (this_tab_w - leading - title.trailing >= 8 * inset and
                        shell.draw(mem_dc, x + 2 * inset, @divTrunc(bar_h - size, 2), size))
                        title.leading = @max(leading, title.leading);
                }
            }
            const text_rect = w32.RECT{
                .left = x + title.leading,
                .top = 0,
                .right = x + this_tab_w - title.trailing,
                .bottom = bar_h,
            };
            const color = if (is_active) active_text_color else inactive_text_color;
            const pane = self.tab_active_surface[i];
            const path = directoryLabels(&self.tab_titles[i], pane);
            var label_buf: DisplayTitleBuffer = undefined;
            const used_full = if (path != null and (!show_admin or path.?.full.len <= 255)) full: {
                const full = if (show_admin) displayTitle(&label_buf, path.?.full, true) else path.?.full;
                break :full self.drawTabLabel(mem_dc, text_rect, full, color, title.flags, true);
            } else false;
            if (!used_full) {
                const short = if (path) |p| p.short else tab_label;
                const label = if (show_admin) displayTitle(&label_buf, short, true) else short;
                _ = self.drawTabLabel(mem_dc, text_rect, label, color, title.flags, false);
            }
        }

        if (is_hovered) {
            if (self.hover_close) {
                drawPill(mem_dc, close_rect, @divTrunc(inset, 2), close_hover_color);
            }
            if (self.app.tab_icon_renderer != null) {
                const color = if (self.hover_close) active_text_color else inactive_text_color;
                if (Icons.Painter.init(mem_dc, color)) |painter| {
                    defer painter.deinit();
                    painter.draw(.close, close_rect, 18 * self.scale);
                }
            }
        }
    }
    if (self.drop_slot) |slot| {
        const edge = if (slot < self.tab_count) self.tab_rects[slot].left else if (self.tab_count > 0) self.tab_rects[self.tab_count - 1].right else 0;
        const x = std.math.clamp(edge, 0, @max(0, tab_area_right - inset));
        drawPill(mem_dc, .{ .left = x, .right = x + inset, .top = inset, .bottom = bar_h - inset }, 0, active_text_color);
    }
    _ = w32.RestoreDC(mem_dc, saved_dc);

    if (dirty.right > tab_area_right) self.drawNewTabControl(mem_dc, brush, bg, fg, inset);

    if (bitmap_bits) |bits| {
        // GDI leaves alpha unset. DWM would add the strip RGB to its
        // material. Supply the same fill as the WGL window and keep the
        // rasterized tabs, labels, and controls opaque.
        _ = w32.GdiFlush();
        const pixels: [*]u32 = @ptrCast(@alignCast(bits));
        const base_rgb = (@as(u32, bg.r) << 16) | (@as(u32, bg.g) << 8) | bg.b;
        const fill = backdropTabPixel(bg, self.app.config.@"background-opacity", self.app.config.@"alpha-blending");
        for (@intCast(dirty.top)..@intCast(dirty.bottom)) |y| {
            const row = pixels + y * @as(usize, @intCast(client_w));
            for (row[@intCast(dirty.left)..@intCast(dirty.right)]) |*pixel| {
                const rgb = pixel.* & 0x00ffffff;
                pixel.* = if (rgb == base_rgb) fill else rgb | 0xff000000;
            }
        }
    }

    // --- BitBlt to screen ---
    _ = w32.BitBlt(hdc_screen, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top, mem_dc, dirty.left, dirty.top, w32.SRCCOPY);
}

const TabTitleLayout = struct { leading: i32, trailing: i32, flags: u32 };

fn mostFrequentShell(panes: []const *Surface) ?u64 {
    var counts: [MAX_TABS]struct { id: u64, count: usize } = undefined;
    var used: usize = 0;
    for (panes) |pane| {
        const shell = pane.tab_shell orelse continue;
        for (counts[0..used]) |*entry| {
            if (entry.id == shell.id) {
                entry.count += 1;
                break;
            }
        } else {
            counts[used] = .{ .id = shell.id, .count = 1 };
            used += 1;
        }
    }
    if (used == 0) return null;
    var common = counts[0];
    for (counts[1..used]) |entry| {
        if (entry.count > common.count) common = entry;
    }
    return common.id;
}

test "tab bar icons distinguish mixed known shells" {
    var first: Surface = undefined;
    var second: Surface = undefined;
    first.tab_shell = .{ .id = 1, .icon = null };
    second.tab_shell = null;
    try std.testing.expectEqual(@as(?u64, 1), mostFrequentShell(&.{ &first, &second }));
    second.tab_shell = first.tab_shell;
    try std.testing.expectEqual(@as(?u64, 1), mostFrequentShell(&.{ &first, &second }));
    second.tab_shell.?.id = 2;
    try std.testing.expectEqual(@as(?u64, 1), mostFrequentShell(&.{ &first, &second }));
    try std.testing.expectEqual(@as(?u64, 2), mostFrequentShell(&.{ &first, &second, &second }));
}

const DirectoryLabels = struct { full: []const u16, short: []const u16 };

fn directoryLabels(title: *const TabTitle, pane: *const Surface) ?DirectoryLabels {
    const dir = pane.reported_directory;
    if (dir.len == 0 or title.manual or title.panes_len != 0) return null;
    const label = title.visible();
    const split = std.mem.lastIndexOfScalar(u16, dir, '\\') orelse return null;
    const leaf = dir[split + 1 ..];
    if (std.mem.eql(u16, label, dir))
        return .{ .full = dir, .short = if (leaf.len == 0) label else leaf };
    if (std.mem.eql(u16, label, leaf) or pane.getTitle() == null)
        return .{ .full = dir, .short = label };
    return null;
}

fn drawTabLabel(self: *Window, dc: w32.HDC, bounds: w32.RECT, label: []const u16, color: u32, alignment: u32, require_fit: bool) bool {
    if (bounds.right <= bounds.left or label.len == 0) return false;
    if (self.app.tab_text.drawShaped(dc, bounds, label, color, alignment == w32.DT_CENTER, require_fit)) return true;
    // If DirectWrite rejected a shaped path, use its short label instead.
    if (require_fit) for (label) |unit| {
        if (unit > 0x7f) return false;
    };
    const flags = w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX;
    var align_flags = alignment;
    if (require_fit or alignment == w32.DT_CENTER) {
        var measured = std.mem.zeroes(w32.RECT);
        if (w32.DrawTextW(dc, label.ptr, @intCast(label.len), &measured, flags | w32.DT_CALCRECT) == 0 or
            measured.right > bounds.right - bounds.left)
        {
            if (require_fit) return false;
            align_flags = w32.DT_LEFT;
        }
    }
    var rect = bounds;
    return w32.DrawTextW(dc, label.ptr, @intCast(label.len), &rect, flags | align_flags) != 0;
}

test "tab bar title offers the full directory only for automatic directory titles" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    var pane: Surface = .{ .app = undefined, .reported_directory = wide("D:\\work\\日本語") };
    var title: TabTitle = .{};
    title.len = @intCast(encodeTitle(&title.text, "日本語"));
    try std.testing.expectEqualSlices(u16, pane.reported_directory, directoryLabels(&title, &pane).?.full);
    title.len = @intCast(encodeTitle(&title.text, "D:\\work\\日本語"));
    try std.testing.expectEqualSlices(u16, wide("日本語"), directoryLabels(&title, &pane).?.short);
    title.manual = true;
    try std.testing.expect(directoryLabels(&title, &pane) == null);
    title.manual = false;
    title.panes_len = 2;
    try std.testing.expect(directoryLabels(&title, &pane) == null);
    title.panes_len = 0;
    pane.title[0..4].* = "Vim".* ++ [_]u8{0};
    pane.title_len = 3;
    title.len = @intCast(encodeTitle(&title.text, "Vim"));
    try std.testing.expect(directoryLabels(&title, &pane) == null);
}

fn tabTitleLayout(width: i32, accessory: i32, inset: i32, hovered: bool) TabTitleLayout {
    // A narrow title starts at a stable position even as the close button
    // appears. Clip its tail so an ellipsis doesn't consume the label.
    if (width - 2 * accessory < 10 * inset) return .{
        .leading = 2 * inset,
        .trailing = if (hovered) accessory else 2 * inset,
        .flags = w32.DT_LEFT,
    };
    return .{ .leading = accessory, .trailing = accessory, .flags = w32.DT_CENTER };
}

test "tab bar narrow titles use the close slot until hovered" {
    const compact = tabTitleLayout(72, 28, 4, false);
    try std.testing.expectEqual(TabTitleLayout{ .leading = 8, .trailing = 8, .flags = w32.DT_LEFT }, compact);
    const hover = tabTitleLayout(108, 42, 6, true);
    try std.testing.expectEqual(TabTitleLayout{ .leading = 12, .trailing = 42, .flags = w32.DT_LEFT }, hover);
    try std.testing.expectEqual(tabTitleLayout(160, 28, 4, true), tabTitleLayout(160, 28, 4, false));
}

fn backdropTabPixel(bg: Config.Color, opacity: f64, blending: Config.AlphaBlending) u32 {
    const alpha: u8 = @intFromFloat(@round(std.math.clamp(opacity, 0, 1) * 255));
    const fraction = @as(f32, @floatFromInt(alpha)) / 255;
    var pixel = @as(u32, alpha) << 24;
    // Match the background shader and the renderer's target format.
    for ([_]u8{ bg.r, bg.g, bg.b }, [_]u5{ 16, 8, 0 }) |channel, shift| {
        const input = @as(f32, @floatFromInt(channel)) / 255;
        const linear = if (!blending.isLinear()) input else if (input <= 0.04045)
            input / 12.92
        else
            std.math.pow(f32, (input + 0.055) / 1.055, 2.4);
        const premultiplied = linear * fraction;
        const encoded = if (build_config.renderer == .d3d12 and !blending.isLinear())
            premultiplied
        else if (premultiplied <= 0.0031308)
            premultiplied * 12.92
        else
            1.055 * std.math.pow(f32, premultiplied, 1.0 / 2.4) - 0.055;
        const output: u8 = @intFromFloat(@round(encoded * 255));
        pixel |= @as(u32, output) << shift;
    }
    return pixel;
}

test "win32 tab bar backdrop matches the renderer background alpha and RGB" {
    const bg: Config.Color = .{ .r = 0x22, .g = 0x31, .b = 0x44 };
    try std.testing.expectEqual(@as(u32, 0), backdropTabPixel(bg, 0, .@"linear-corrected"));
    try std.testing.expectEqual(@as(u32, 0x73141f2d), backdropTabPixel(bg, 0.45, .@"linear-corrected"));
    try std.testing.expectEqual(@as(u32, 0xff223144), backdropTabPixel(bg, 1, .@"linear-corrected"));
    const native_fill: u32 = if (build_config.renderer == .d3d12) 0x730f161f else 0x73455361;
    try std.testing.expectEqual(native_fill, backdropTabPixel(bg, 0.45, .native));
}

/// Honor a program's CSI 8 t resize only when it owns the whole window.
/// Changing the outer dimensions by the surface-size delta accounts for
/// non-client borders without assuming a particular decoration or DPI.
pub fn resizeSurface(self: *Window, surface: *Surface, size: apprt.action.ResizeWindow) bool {
    const hwnd = self.hwnd orelse return false;
    if (self.closing or self.is_quick_terminal or self.is_fullscreen or
        w32.IsZoomed(hwnd) != 0 or w32.IsIconic(hwnd) != 0) return false;
    if (self.tab_count != 1 or self.tab_trees[0].isSplit() or
        self.tab_active_surface[0] != surface) return false;
    const surface_hwnd = surface.hwnd orelse return false;
    var outer: w32.RECT = undefined;
    var client: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &outer) == 0 or
        w32.GetClientRect(surface_hwnd, &client) == 0) return false;

    // The surface's drawable width excludes a reserved (non-overlay)
    // scrollbar strip; the child HWND's client rectangle does not.
    const current = surface.getSize() catch return false;
    var width = resizedDimension(size.width, surface.scale, @intCast(current.width), outer.right - outer.left);
    var height = resizedDimension(size.height, surface.scale, @intCast(current.height), outer.bottom - outer.top);
    var monitor: w32.MONITORINFO = undefined;
    monitor.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.GetMonitorInfoW(w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST), &monitor) != 0) {
        if (size.width > 0) width = @min(width, monitor.rcWork.right - monitor.rcWork.left);
        if (size.height > 0) height = @min(height, monitor.rcWork.bottom - monitor.rcWork.top);
    }
    return w32.SetWindowPos(hwnd, null, 0, 0, width, height, w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOACTIVATE) != 0;
}

fn resizedDimension(requested: u32, scale: f32, current: i32, outer: i32) i32 {
    if (requested == 0) return outer;
    // Bound untrusted terminal requests before converting back to Win32's
    // signed dimensions. Larger sizes are not useful desktop window sizes.
    const px = @min(@as(f64, @floatFromInt(requested)) * scale, 32_767);
    return @max(1, outer - current + @as(i32, @intFromFloat(@ceil(px))));
}

test "program resize preserves zero dimensions and scales points" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 816), resizedDimension(0, 1.5, 800, 816));
    try testing.expectEqual(@as(i32, 916), resizedDimension(600, 1.5, 800, 816));
    try testing.expectEqual(@as(i32, 516), resizedDimension(500, 1, 800, 816));
    try testing.expectEqual(@as(i32, 32_783), resizedDimension(std.math.maxInt(u32), 2, 800, 816));
}

test "program resize native window guards and zero dimensions" {
    const testing = std.testing;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("");
    // Hidden system-class windows need neither a renderer nor an application.
    const hwnd = w32.CreateWindowExW(0, class, title, w32.WS_OVERLAPPEDWINDOW, 0, 0, 400, 300, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(hwnd);
    const child = w32.CreateWindowExW(0, class, title, w32.WS_CHILD, 0, 0, 200, 100, hwnd, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(child);
    var surface: Surface = undefined;
    surface.hwnd = child;
    surface.scale = 1;
    // Simulate a 20-pixel scrollbar reservation within the 200-pixel child.
    surface.width = 180;
    surface.height = 100;
    var window: Window = .{ .app = undefined, .hwnd = hwnd, .tab_count = 1 };
    window.tab_active_surface[0] = &surface;
    window.tab_trees[0] = .{ .arena = undefined, .nodes = &.{.{ .leaf = &surface }}, .zoomed = null };

    var before: w32.RECT = undefined;
    var after: w32.RECT = undefined;
    try testing.expect(w32.GetWindowRect(hwnd, &before) != 0);
    try testing.expect(window.resizeSurface(&surface, .{ .width = 220, .height = 0 }));
    try testing.expect(w32.GetWindowRect(hwnd, &after) != 0);
    try testing.expectEqual(before.right - before.left + 40, after.right - after.left);
    try testing.expectEqual(before.bottom - before.top, after.bottom - after.top);
    before = after;
    try testing.expect(window.resizeSurface(&surface, .{ .width = 0, .height = 120 }));
    try testing.expect(w32.GetWindowRect(hwnd, &after) != 0);
    try testing.expectEqual(before.right - before.left, after.right - after.left);
    try testing.expectEqual(before.bottom - before.top + 20, after.bottom - after.top);

    window.is_fullscreen = true;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.is_fullscreen = false;
    window.is_quick_terminal = true;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.is_quick_terminal = false;
    window.tab_count = 2;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.tab_count = 1;
    window.tab_trees[0].nodes = &.{.{ .split = undefined }};
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null, self.saved_rect.left, self.saved_rect.top, self.saved_rect.right - self.saved_rect.left, self.saved_rect.bottom - self.saved_rect.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}

/// Handle WM_SIZE: re-layout the active tab's split panes and repaint tab bar.
/// Timer id used to auto-hide the resize overlay.
const RESIZE_OVERLAY_TIMER_ID: usize = 0x5247; // 'RG'

fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
    self.showResizeOverlay();
}

/// Show the transient "columns × rows" overlay during a resize, honoring
/// the resize-overlay / -position / -duration config. Auto-hides via a
/// timer that each subsequent resize re-arms.
fn showResizeOverlay(self: *Window) void {
    switch (self.app.config.@"resize-overlay") {
        .never => return,
        .@"after-first" => if (!self.resize_seen_first) {
            // Suppress for the initial layout pass at window creation.
            self.resize_seen_first = true;
            return;
        },
        .always => {},
    }
    self.resize_seen_first = true;
    const hwnd = self.hwnd orelse return;

    // Grid dimensions from the active surface.
    const surface = self.getActiveSurface() orelse return;
    if (!surface.core_surface_ready) return;
    const grid = surface.core_surface.size.grid();

    var buf8: [32]u8 = undefined;
    const text8 = std.mem.print(&buf8, "{d} \u{00D7} {d}", .{
        grid.columns,
        grid.rows,
    }) catch return;
    var buf16: [32]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch return;
    buf16[len16] = 0;

    if (self.resize_overlay_hwnd == null) {
        self.resize_overlay_hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            hwnd,
            null,
            self.app.hinstance,
            null,
        );
        if (self.resize_overlay_hwnd) |h| {
            if (self.tab_font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const overlay = self.resize_overlay_hwnd orelse return;
    _ = w32.SetWindowTextW(overlay, @ptrCast(&buf16));

    // Position within the client area per resize-overlay-position.
    const s = self.scale;
    const ow: i32 = @intFromFloat(@round(110.0 * s));
    const oh: i32 = @intFromFloat(@round(34.0 * s));
    const margin: i32 = @intFromFloat(@round(16.0 * s));
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(hwnd, &client);
    const cw = client.right - client.left;
    const ch = client.bottom - client.top;
    const cx = @divTrunc(cw - ow, 2);
    const cy = @divTrunc(ch - oh, 2);
    var pt: w32.POINT = switch (self.app.config.@"resize-overlay-position") {
        .center => .{ .x = cx, .y = cy },
        .@"top-left" => .{ .x = margin, .y = margin },
        .@"top-center" => .{ .x = cx, .y = margin },
        .@"top-right" => .{ .x = cw - ow - margin, .y = margin },
        .@"bottom-left" => .{ .x = margin, .y = ch - oh - margin },
        .@"bottom-center" => .{ .x = cx, .y = ch - oh - margin },
        .@"bottom-right" => .{ .x = cw - ow - margin, .y = ch - oh - margin },
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(overlay, null, pt.x, pt.y, ow, oh, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(overlay, w32.SW_SHOWNOACTIVATE);

    // (Re-)arm the auto-hide timer. asMilliseconds saturates, so huge
    // configured durations don't overflow the u32 SetTimer argument.
    const dur_ms: u32 = @max(1, self.app.config.@"resize-overlay-duration".asMilliseconds());
    _ = w32.SetTimer(hwnd, RESIZE_OVERLAY_TIMER_ID, dur_ms, null);
}

/// Handle a left-button click in the tab bar region.
/// Dispatches to addTab, closeTab, or selectTabIndex depending on hit position.
fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (self.tabButtonAt(x, y)) |button| {
        switch (button) {
            .new_tab => _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
                return;
            },
            .environment => self.openEnvironmentMenu(),
        }
        return;
    }

    const i = self.tabAt(x, y) orelse return;
    if (containsPoint(self.tabCloseRect(self.tab_rects[i]), x, y)) {
        self.closeTabByIndex(i);
    } else {
        const previous = self.active_tab;
        self.selectTabIndex(i);
        self.drag_tab = @intCast(i);
        self.drag_previous_tab = previous;
        self.drag_start = .{ .x = x, .y = y };
        self.drag_anchor = x - self.tab_rects[i].left;
        self.drag_x = x;
        self.drag_active = false;
        if (self.hwnd) |h| {
            _ = w32.SetCapture(h);
            if (GetCapture() != h) self.cancelTabDrag();
        }
        self.invalidateTabBar();
    }
}

const SplitDirection = SplitTree(Surface).Split.Direction;
const PaneDrop = struct { direction: SplitDirection, rect: w32.RECT };
const DropTarget = struct {
    window: *Window,
    target: union(enum) {
        none,
        strip: usize,
        pane: struct { surface: *Surface, drop: PaneDrop },
    },
};

/// The edge bands occupy at most a third of the pane. At corners prefer the
/// closer edge relative to its band, including on very narrow or short panes.
fn paneDrop(rect: w32.RECT, point: w32.POINT, scale: f32) ?PaneDrop {
    if (!containsPoint(rect, point.x, point.y)) return null;
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    const gap: i32 = @intFromFloat(@round(5 * scale));
    const limit: i32 = @max(1, @as(i32, @intFromFloat(@round(96 * scale))));
    const band_x = @min(@divTrunc(width, 3), limit);
    const band_y = @min(@divTrunc(height, 3), limit);
    const left = point.x - rect.left;
    const right = rect.right - 1 - point.x;
    const top = point.y - rect.top;
    const bottom = rect.bottom - 1 - point.y;
    const dx = @min(left, right);
    const dy = @min(top, bottom);
    const x_edge = width >= gap + 2 and dx < band_x;
    const y_edge = height >= gap + 2 and dy < band_y;
    if (!x_edge and !y_edge) return null;
    var preview = rect;
    if (x_edge and (!y_edge or @as(i64, dx) * band_y <= @as(i64, dy) * band_x)) {
        const mid = rect.left + @divTrunc(width, 2);
        if (left <= right) preview.right = mid - @divTrunc(gap, 2) else preview.left = mid + @divTrunc(gap + 1, 2);
        return .{ .direction = if (left <= right) .left else .right, .rect = preview };
    }
    const mid = rect.top + @divTrunc(height, 2);
    if (top <= bottom) preview.bottom = mid - @divTrunc(gap, 2) else preview.top = mid + @divTrunc(gap + 1, 2);
    return .{ .direction = if (top <= bottom) .up else .down, .rect = preview };
}

test "win32 tab drag pane edges preview the inserted split" {
    const rect: w32.RECT = .{ .left = -300, .top = 20, .right = -100, .bottom = 120 };
    const left = paneDrop(rect, .{ .x = -295, .y = 70 }, 1).?;
    try std.testing.expectEqual(SplitDirection.left, left.direction);
    try std.testing.expectEqual(@as(i32, -202), left.rect.right);
    const right = paneDrop(rect, .{ .x = -104, .y = 70 }, 1).?;
    try std.testing.expectEqual(SplitDirection.right, right.direction);
    try std.testing.expectEqual(@as(i32, -197), right.rect.left);
    const up = paneDrop(rect, .{ .x = -200, .y = 23 }, 2).?;
    try std.testing.expectEqual(SplitDirection.up, up.direction);
    try std.testing.expectEqual(@as(i32, 65), up.rect.bottom);
    const down = paneDrop(rect, .{ .x = -200, .y = 118 }, 2).?;
    try std.testing.expectEqual(SplitDirection.down, down.direction);
    try std.testing.expectEqual(@as(i32, 75), down.rect.top);
    try std.testing.expect(paneDrop(rect, .{ .x = -201, .y = 68 }, 1) == null);
    try std.testing.expect(paneDrop(rect, .{ .x = -100, .y = 60 }, 1) == null);
    try std.testing.expect(paneDrop(.{ .left = 0, .top = 0, .right = 6, .bottom = 6 }, .{ .x = 0, .y = 0 }, 1) == null);
}

fn dropTarget(self: *Window, screen: w32.POINT) ?DropTarget {
    var hit = w32.WindowFromPoint(screen) orelse return null;
    if (hit == self.split_preview) hit = self.preview_owner orelse return null;
    while (w32.GetParent(hit)) |parent| hit = parent;
    for (self.app.windows.items) |other| {
        if (other.hwnd != hit or other.closing or other.is_quick_terminal or other.tab_count == 0) continue;
        const none: DropTarget = .{ .window = other, .target = .none };
        var local = screen;
        if (w32.ScreenToClient(hit, &local) == 0) return none;
        if (local.y < 0 or (other.tab_bar_visible and local.y < other.tabBarHeight())) {
            if (other == self) {
                if (local.y < 0 or local.x < 0 or local.x >= self.tab_buttons[0].left) return none;
                return .{ .window = self, .target = .{ .strip = tabDragTarget(self.tab_rects[0..self.tab_count], local.x) } };
            }
            if (other.tab_count >= MAX_TABS) return none;
            var slot: usize = 0;
            if (other.tab_bar_visible and local.y >= 0) {
                for (other.tab_rects[0..other.tab_count]) |rect| {
                    if (local.x < rect.left + @divTrunc(rect.right - rect.left, 2)) break;
                    slot += 1;
                }
            } else slot = other.tab_count;
            return .{ .window = other, .target = .{ .strip = slot } };
        }
        if (other == self and self.drag_tab == @as(isize, @intCast(other.active_tab))) return none;
        var panes = other.tab_trees[other.active_tab].iterator();
        while (panes.next()) |entry| {
            const hwnd = entry.view.hwnd orelse continue;
            var rect: w32.RECT = undefined;
            if (w32.IsWindowVisible_(hwnd) == 0 or w32.GetWindowRect(hwnd, &rect) == 0) continue;
            if (paneDrop(rect, screen, other.scale)) |drop|
                return .{ .window = other, .target = .{ .pane = .{ .surface = entry.view, .drop = drop } } };
        }
        return none;
    }
    return null;
}

fn showDropTarget(self: *Window, target: ?DropTarget) void {
    for (self.app.windows.items) |other| {
        const slot: ?usize = if (target) |t| (if (t.window == other and other != self and t.target == .strip) t.target.strip else null) else null;
        if (other.drop_slot != slot) {
            other.drop_slot = slot;
            other.invalidateTabBar();
        }
    }
    if (target) |t| if (t.target == .pane) {
        const rect = t.target.pane.drop.rect;
        if (self.preview_rect) |old| if (std.meta.eql(old, rect) and self.preview_owner == t.window.hwnd) return;
        if (self.split_preview == null) {
            self.split_preview = w32.CreateWindowExW(w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW | w32.WS_EX_TRANSPARENT | w32.WS_EX_LAYERED, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), w32.WS_POPUP, 0, 0, 0, 0, self.hwnd, null, self.app.hinstance, null) orelse return;
            _ = w32.SetLayeredWindowAttributes(self.split_preview.?, 0, 90, w32.LWA_ALPHA);
        }
        self.preview_rect = rect;
        self.preview_owner = t.window.hwnd;
        _ = w32.SetWindowPos(self.split_preview.?, w32.HWND_TOPMOST, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW);
        return;
    };
    if (self.preview_rect != null) {
        self.preview_rect = null;
        self.preview_owner = null;
        if (self.split_preview) |popup| _ = w32.ShowWindow(popup, w32.SW_HIDE);
    }
}

fn setDragHover(self: *Window, idx: ?usize) void {
    if (self.drag_hover_tab == idx) return;
    const hwnd = self.hwnd orelse return;
    _ = w32.KillTimer(hwnd, TAB_HOVER_TIMER);
    self.drag_hover_tab = idx;
    if (idx) |tab| if (tab != self.active_tab) {
        _ = w32.SetTimer(hwnd, TAB_HOVER_TIMER, 350, null);
    };
}

fn showDraggedTitle(self: *Window, point: w32.POINT, on_strip: bool) void {
    if (on_strip) {
        if (self.drag_label) |label| _ = w32.ShowWindow(label, w32.SW_HIDE);
        return;
    }
    if (self.drag_label == null) {
        const i: usize = @intCast(self.drag_tab);
        var title: [257]u16 = undefined;
        const visible = self.tabLabel(i);
        const len = visible.len;
        @memcpy(title[0..len], visible);
        title[len] = 0;
        const label = w32.CreateWindowExW(w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW | w32.WS_EX_TRANSPARENT | w32.WS_EX_LAYERED, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), @ptrCast(&title), w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTER | w32.SS_CENTERIMAGE | w32.SS_NOPREFIX | w32.SS_ENDELLIPSIS, 0, 0, 0, 0, self.hwnd, null, self.app.hinstance, null) orelse return;
        self.drag_label = label;
        _ = w32.SetLayeredWindowAttributes(label, 0, 230, w32.LWA_ALPHA);
        if (self.tab_font) |font| _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(font), 0);
    }
    const gap: i32 = @intFromFloat(14 * self.scale);
    _ = w32.SetWindowPos(self.drag_label.?, w32.HWND_TOPMOST, point.x + gap, point.y + gap, @intFromFloat(184 * self.scale), @intFromFloat(32 * self.scale), w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW);
}

pub fn cancelTabDrag(self: *Window) void {
    self.endTabDrag(true);
}

fn endTabDrag(self: *Window, restore: bool) void {
    if (self.drag_tab < 0) return;
    const tab = self.drag_previous_tab;
    self.setDragHover(null);
    self.showDropTarget(null);
    self.drag_tab = -1;
    self.drag_active = false;
    self.drag_on_strip = false;
    if (self.split_preview) |popup| {
        self.split_preview = null;
        _ = w32.DestroyWindow(popup);
    }
    if (self.drag_label) |label| {
        self.drag_label = null;
        _ = w32.DestroyWindow(label);
    }
    self.invalidateTabBar();
    if (self.hwnd) |hwnd| {
        if (GetCapture() == hwnd) _ = w32.ReleaseCapture();
        if (restore and !self.closing and tab < self.tab_count and self.active_tab != tab)
            self.showTab(tab, w32.GetForegroundWindow() == hwnd);
    }
}

fn tabDragStarted(start: w32.POINT, point: w32.POINT, scale: f32) bool {
    const threshold: i64 = @intFromFloat(@ceil(5 * scale));
    return @abs(@as(i64, point.x) - start.x) > threshold or
        @abs(@as(i64, point.y) - start.y) > threshold;
}

fn beginTabDrag(self: *Window, point: w32.POINT) void {
    if (self.drag_active or !tabDragStarted(self.drag_start, point, self.scale)) return;
    self.drag_active = true;
    // Pressing an inactive tab selects it for a normal click. On a drag,
    // restore the pane that was under the pointer before the press.
    if (self.drag_previous_tab < self.tab_count and self.active_tab != self.drag_previous_tab)
        self.showTab(self.drag_previous_tab, false);
}

fn finishTabDrag(self: *Window, point: w32.POINT) void {
    if (self.drag_tab < 0) return;
    const tab: usize = @intCast(self.drag_tab);
    self.beginTabDrag(point);
    if (!self.drag_active or tab >= self.tab_count) {
        self.endTabDrag(false);
        return;
    }

    const hwnd = self.hwnd orelse return;
    var position = point;
    var outer: w32.RECT = undefined;
    if (w32.ClientToScreen(hwnd, &position) == 0 or w32.GetWindowRect(hwnd, &outer) == 0) {
        self.cancelTabDrag();
        return;
    }
    const target = self.dropTarget(position);
    const previous = self.drag_previous_tab;
    self.endTabDrag(if (target) |t| t.window != self or t.target != .pane else true);
    if (target) |t| {
        switch (t.target) {
            .none => {},
            .strip => |slot| if (t.window == self) {
                if (self.active_tab != tab) self.showTab(tab, w32.GetForegroundWindow() == hwnd);
                self.moveTabTo(tab, slot);
            } else {
                self.transferTab(tab, t.window, slot) catch |err| log.err("failed to merge dragged tab: {}", .{err});
            },
            .pane => |pane| self.mergeTabIntoPane(tab, t.window, pane.surface, pane.drop.direction) catch |err| {
                if (t.window == self and previous < self.tab_count) self.showTab(previous, w32.GetForegroundWindow() == hwnd);
                log.err("failed to split dragged tab: {}", .{err});
            },
        }
        return;
    }
    if (containsPoint(outer, position.x, position.y)) return;

    if (w32.MonitorFromPoint(position, w32.MONITOR_DEFAULTTONEAREST)) |handle| {
        var monitor: w32.MONITORINFO = undefined;
        monitor.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(handle, &monitor) != 0) {
            // Keep a usable corner of the title bar on the destination monitor.
            const margin: i32 = @intFromFloat(@ceil(32 * self.scale));
            position = clampTabDrop(position, monitor.rcWork, margin);
        }
    }
    _ = self.moveTabToNewWindowAt(self.tab_active_surface[tab], position) catch |err|
        log.err("failed to detach dragged tab: {}", .{err});
}

fn clampTabDrop(point: w32.POINT, work: w32.RECT, margin: i32) w32.POINT {
    return .{
        .x = std.math.clamp(point.x, work.left, @max(work.left, work.right - margin)),
        .y = std.math.clamp(point.y, work.top, @max(work.top, work.bottom - margin)),
    };
}

test "win32 tab drag threshold uses both axes and DPI" {
    const start: w32.POINT = .{ .x = 100, .y = 20 };
    try std.testing.expect(!tabDragStarted(start, .{ .x = 93, .y = 14 }, 1.5));
    try std.testing.expect(tabDragStarted(start, .{ .x = 91, .y = 20 }, 1.5));
    try std.testing.expect(tabDragStarted(start, .{ .x = 100, .y = 29 }, 1.5));
}

test "win32 tab drag drop stays reachable on a negative-coordinate monitor" {
    const work: w32.RECT = .{ .left = -1280, .top = -200, .right = 0, .bottom = 760 };
    try std.testing.expectEqual(w32.POINT{ .x = -640, .y = 50 }, clampTabDrop(.{ .x = -640, .y = 50 }, work, 48));
    try std.testing.expectEqual(w32.POINT{ .x = -48, .y = 712 }, clampTabDrop(.{ .x = 0, .y = 750 }, work, 48));
}

fn openEnvironmentMenu(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var arena = std.heap.ArenaAllocator.init(self.app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const environments = Profiles.discover(alloc) catch |err| failed: {
        log.err("failed to discover shell profiles: {t}", .{err});
        break :failed &.{};
    };
    const icons = alloc.alloc(?w32.HANDLE, environments.len) catch return;
    @memset(icons, null);
    defer for (icons) |icon| {
        if (icon) |bitmap| _ = w32.DeleteObject(bitmap);
    };
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    for (environments, 0..) |environment, i| {
        const name = std.mem.replaceOwned(u8, alloc, environment.name, "&", "&&") catch return;
        const label = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch continue;
        const flags = if (self.tab_count >= MAX_TABS) w32.MF_GRAYED else w32.MF_STRING;
        if (w32.AppendMenuW(menu, flags, i + 1, label) != 0) {
            icons[i] = Profiles.attachIcon(alloc, menu, @intCast(i + 1), environment, self.scale);
        }
    }
    const settings_id = environments.len + 1;
    if (environments.len != 0) _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, settings_id, lang.wide("Settings"));

    const anchor = self.tab_buttons[@backingInt(TabButton.environment)];
    var pt: w32.POINT = .{ .x = anchor.left, .y = anchor.bottom };
    if (w32.ClientToScreen(hwnd, &pt) == 0) return;
    const owner: isize = @bitCast(@intFromPtr(self));
    const choice = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, pt.x, pt.y, hwnd, null);
    // The native menu runs a nested message loop; the owner may have closed.
    if (w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA) != owner or self.closing) return;
    if (choice == settings_id) {
        Settings.open(self.app, hwnd);
    } else if (choice > 0 and choice <= environments.len) {
        const profile = environments[@intCast(choice - 1)];
        const command: Config.Command = .{ .direct = profile.argv };
        _ = self.addTabWithOptions(.{
            .context = .tab,
            .command = &command,
            .profile = profile,
            .working_directory = profile.directory,
            // Shell integration can add flags that change the meaning of
            // a profile's command (for example PowerShell's -Command).
            .preserve_command = profile.argv.len > 1,
        }) catch |err| {
            log.err("failed to open environment err={}", .{err});
            return;
        };
    }
}

/// Move a tab from one index to another, shifting intermediate tabs.
fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.cancelTabRename();

    // Save the source tab state
    const saved_tree = self.tab_trees[from];
    const saved_surface = self.tab_active_surface[from];
    const saved_title = self.tab_titles[from];

    if (from < to) {
        // Shift left: move [from+1..to+1] to [from..to]
        var i: usize = from;
        while (i < to) : (i += 1) {
            self.tab_trees[i] = self.tab_trees[i + 1];
            self.tab_active_surface[i] = self.tab_active_surface[i + 1];
            self.tab_titles[i] = self.tab_titles[i + 1];
        }
    } else {
        // Shift right: move [to..from] to [to+1..from+1]
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.tab_trees[i] = self.tab_trees[i - 1];
            self.tab_active_surface[i] = self.tab_active_surface[i - 1];
            self.tab_titles[i] = self.tab_titles[i - 1];
        }
    }

    // Place the saved tab at the destination
    self.tab_trees[to] = saved_tree;
    self.tab_active_surface[to] = saved_surface;
    self.tab_titles[to] = saved_title;

    self.active_tab = to;
    self.invalidateTabBar();
}

/// Handle mouse movement over the tab bar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;

    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    const tab = self.tabAt(x, y);
    const new_hover: isize = if (tab) |i| @intCast(i) else -1;
    const new_close = if (tab) |i| containsPoint(self.tabCloseRect(self.tab_rects[i]), x, y) else false;
    const new_button = self.tabButtonAt(x, y);

    if (new_hover != self.hover_tab or new_close != self.hover_close or new_button != self.hover_button) {
        self.invalidateTabHover();
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_button = new_button;
        self.invalidateTabHover();
    }
}

fn invalidateTabHover(self: *const Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.hover_tab >= 0 and self.hover_tab < @as(isize, @intCast(self.tab_count))) {
        _ = w32.InvalidateRect(hwnd, &self.tab_rects[@intCast(self.hover_tab)], 0);
    }
    if (self.hover_button) |button| {
        _ = w32.InvalidateRect(hwnd, &self.tab_buttons[@backingInt(button)], 0);
    }
}

// Context menu command IDs.
const TAB_CTX_CLOSE: usize = 9001;
const TAB_CTX_CLOSE_OTHERS: usize = 9002;
const TAB_CTX_CLOSE_RIGHT: usize = 9003;
const TAB_CTX_NEW_TAB: usize = 9004;

/// Handle a right-button click in the tab bar region.
/// Shows a context menu for the clicked tab.
fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Hit-test to find which tab was right-clicked.
    const clicked_tab = self.tabAt(x, y);

    // If clicked on empty area (not a tab), only show "New Tab".
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    if (clicked_tab) |tab| {
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, lang.wide("Close Tab"));
        _ = w32.AppendMenuW(menu, if (self.tab_count > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, lang.wide("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < self.tab_count) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, lang.wide("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, lang.wide("New Tab"));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = @intCast(x), .y = @intCast(y) };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.closeTabByIndex(tab);
        },
        TAB_CTX_CLOSE_OTHERS => {
            if (clicked_tab) |tab| {
                var current = tab;
                var i: usize = self.tab_count;
                while (i > 0) {
                    i -= 1;
                    if (i != current) {
                        self.closeTabByIndex(i);
                        if (i < current) current -= 1;
                    }
                }
            }
        },
        TAB_CTX_CLOSE_RIGHT => {
            if (clicked_tab) |tab| {
                var i: usize = self.tab_count;
                while (i > tab + 1) {
                    i -= 1;
                    self.closeTabByIndex(i);
                }
            }
        },
        TAB_CTX_NEW_TAB => {
            _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        else => {},
    }
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    if (self.hover_tab != -1 or self.hover_button != null) {
        self.invalidateTabHover();
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_button = null;
    }
}

/// Rename edit control child ID.
const RENAME_EDIT_ID: u16 = 300;

/// Start inline editing of a tab title. Creates a small Edit control
/// overlay on the tab and pre-fills it with the current title.
pub fn startTabRename(self: *Window, tab_idx: usize) void {
    // Cancel any existing rename
    self.cancelTabRename();
    self.rename_window = false;

    const hwnd = self.hwnd orelse return;
    const rect = rect: {
        if (self.tab_bar_visible) break :rect self.tab_rects[tab_idx];

        // A single-tab window has no tab bar. Use a compact editor at the
        // top of the client area so prompt_*_title remains usable.
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        break :rect w32.RECT{
            .left = 8,
            .top = 8,
            .right = @max(168, client.right - 8),
            .bottom = 38,
        };
    };

    // CreateWindowExW requires a NUL-terminated title.
    var title_buf: [257]u16 = undefined;
    const visible = self.tabLabel(tab_idx);
    const tlen = visible.len;
    @memcpy(title_buf[0..tlen], visible);
    title_buf[tlen] = 0;

    // Create an Edit control overlaid on the tab
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    self.ui_font.replace(&self.rename_font, 12, self.scale, &.{edit});

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    _ = w32.SetFocus(edit);
    self.rename_edit = edit;
    self.rename_tab = tab_idx;
}

/// Prompt for an explicit top-level window title using the same lightweight
/// inline editor as tab renaming.
pub fn startWindowRename(self: *Window) void {
    self.startTabRename(self.active_tab);
    const edit = self.rename_edit orelse return;
    self.rename_window = true;

    var title: [257]u16 = undefined;
    const len: usize = if (self.window_title_override_len) |override_len| len: {
        @memcpy(title[0..override_len], self.window_title_override[0..override_len]);
        break :len override_len;
    } else @intCast(w32.GetWindowTextW(self.hwnd.?, &title, 256));
    title[len] = 0;
    _ = w32.SetWindowTextW(edit, @ptrCast(&title));
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)
}

/// Apply the edit text as the new tab title and destroy the edit control.
pub fn finishTabRename(self: *Window) void {
    const edit = self.rename_edit orelse return;
    const tab_idx = self.rename_tab;

    // Read the edit control text
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    if (self.rename_window) {
        if (wlen == 0) {
            self.window_title_override_len = null;
        } else {
            const len: u16 = @intCast(@min(wlen, 255));
            @memcpy(self.window_title_override[0..len], wbuf[0..len]);
            self.window_title_override_len = len;
        }
        self.updateWindowTitle();
    } else if (wlen == 0) {
        self.setTabTitle(self.tab_active_surface[tab_idx], "");
    } else if (!std.mem.eql(u16, self.tabLabel(tab_idx), wbuf[0..wlen])) {
        self.tab_titles[tab_idx].manual = true;
        const len: u16 = @intCast(@min(wlen, 255));
        @memcpy(self.tab_titles[tab_idx].text[0..len], wbuf[0..len]);
        self.tab_titles[tab_idx].len = len;
        if (tab_idx == self.active_tab) self.updateWindowTitle();
    }

    // Clear our state BEFORE DestroyWindow: the Edit synchronously emits
    // EN_KILLFOCUS as it's torn down, which re-enters this function via
    // the WM_COMMAND handler. The early `orelse return` then makes that
    // re-entrant call a no-op.
    self.rename_edit = null;
    self.rename_window = false;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.invalidateTabBar();

    // Return focus to the active surface
    if (self.getActiveSurface()) |s| {
        if (s.hwnd) |h| _ = w32.SetFocus(h);
    }
}

/// Cancel inline rename without applying changes.
pub fn cancelTabRename(self: *Window) void {
    if (self.rename_edit) |edit| {
        // Same re-entry concern as finishTabRename: null before destroy.
        self.rename_edit = null;
        self.rename_window = false;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| {
            _ = w32.DeleteObject(f);
            self.rename_font = null;
        }
        if (self.getActiveSurface()) |s| {
            if (s.hwnd) |h| _ = w32.SetFocus(h);
        }
    }
}

/// Return true if it is safe to close this whole window. If any tab still
/// has a running process, show a single aggregate confirmation dialog
/// (mirroring macOS/GTK, which confirm once per window) and return whether
/// the user approved. Whole-window close paths (title-bar X, Alt+F4,
/// close_window) previously skipped this check entirely; the per-surface
/// close path (Ctrl+Shift+W) still confirms separately in Surface.close.
/// When the last tab has already been closed (tab_count == 0) there is
/// nothing to confirm, so this returns true silently.
pub fn confirmCloseIfNeeded(self: *Window) bool {
    var needs = false;
    outer: for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            if (surface.core_surface_ready and
                surface.core_surface.needsConfirmQuit())
            {
                needs = true;
                break :outer;
            }
        }
    }
    if (!needs) return true;

    const result = w32.MessageBoxW(
        self.hwnd,
        lang.wide("Processes are still running in this window.\nClose anyway?"),
        std.unicode.utf8ToUtf16LeStringLiteral("Madotty"),
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    );
    return result == w32.IDOK;
}

/// Handle WM_CLOSE: clean up all tabs, then destroy the window.
/// OpenGL contexts and DCs must be released BEFORE DestroyWindow,
/// because Win32 destroys child HWNDs during DestroyWindow and the
/// OpenGL driver crashes if contexts are still active on destroyed windows.
pub fn close(self: *Window) void {
    self.tab_overview.deinit();
    // First, cleanly shut down all surfaces (renderer/IO threads, WGL, DC).
    self.cleanupAllSurfaces();

    // Now safe to destroy the parent HWND (children already cleaned up).
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

/// Deinit and free all tab trees (which unrefs and frees surfaces).
fn cleanupAllSurfaces(self: *Window) void {
    // Deinit in place and reset to .empty. SplitTree.deinit sets self.*
    // to undefined; deinit'ing a local copy would only mark the copy,
    // leaving stale arena/node pointers in tab_trees that any post-WM_CLOSE
    // message walking the slot could dereference.
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        tree.deinit();
        tree.* = .empty;
    }
    self.tab_count = 0;
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    const app = self.app;
    self.endTabDrag(false);
    for (app.windows.items) |source| {
        if (source.preview_rect != null and source.preview_owner == self.hwnd)
            source.showDropTarget(null);
    }
    self.tab_overview.deinit();

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        if (self.tab_font) |font| {
            _ = w32.DeleteObject(font);
            self.tab_font = null;
        }
        self.hwnd = null;
        // QuickTerminal handles the rest of cleanup (freeing self, quit timer).
        if (app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }

    // Remove from App's window list.
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }

    // Clean up Window-level resources.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }
    self.hwnd = null;

    // Free the Window allocation.
    app.core_app.alloc.destroy(self);

    // If no windows remain (and no quick terminal), start the quit timer.
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}

/// Window procedure for top-level container HWNDs (GhosttyWindow class).
/// GWLP_USERDATA stores a *Window pointer.
pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    if (window.app.taskbar_created_message != 0 and msg == window.app.taskbar_created_message) {
        window.taskbar_ready = true;
        window.taskbar_progress = Progress{};
        if (window.progress.state != .remove) window.queueProgressRefresh();
        return 0;
    }

    // Once the last tab is closed and WM_CLOSE has been posted, drop any
    // input messages still queued for this window. They could otherwise
    // mutate state (allocate, capture mouse, start drags) on a window
    // about to be destroyed. WM_CLOSE/WM_DESTROY/paint/size still flow
    // through so close itself can complete cleanly.
    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_RBUTTONUP,
        w32.WM_MBUTTONDOWN,
        w32.WM_MOUSEMOVE,
        w32.WM_MOUSELEAVE,
        w32.WM_MOUSEWHEEL,
        w32.WM_MOUSEHWHEEL,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_SYSKEYDOWN,
        w32.WM_SYSKEYUP,
        w32.WM_CHAR,
        w32.WM_SETFOCUS,
        w32.WM_SETCURSOR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };

    switch (msg) {
        w32.WM_SETTINGCHANGE => {
            // Windows broadcasts the app theme change with wParam == 0.
            // Check the actual preference without depending on lParam text.
            if (!window.closing and wparam == 0) window.app.queueColorSchemeCheck();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SYSCOMMAND => {
            if (wparam & 0xFFF0 == SC_SETTINGS and !window.closing) {
                Settings.open(window.app, hwnd);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_TOGGLE_TAB_OVERVIEW => {
            window.tab_overview.toggle(window) catch |err| {
                log.warn("unable to open tab overview err={}", .{err});
            };
            return 0;
        },
        WM_REFRESH_TAB_OVERVIEW => {
            window.overview_refresh_pending = false;
            window.tab_overview.refresh();
            return 0;
        },
        WM_REFRESH_PROGRESS => {
            window.refreshProgress(hwnd);
            return 0;
        },
        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT on the
            // top-level window too. See the matching handler in
            // App.surfaceWndProc for the rationale: returning 0 here
            // prevents oleacc from creating an AccWrap proxy whose
            // later destruction can re-enter our WindowProc via
            // SetFocus and deadlock on a COM marshaling reply.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_TIMER => {
            if (wparam == TAB_HOVER_TIMER) {
                _ = w32.KillTimer(hwnd, TAB_HOVER_TIMER);
                if (window.drag_hover_tab) |idx| if (window.drag_active and idx < window.tab_count and
                    idx != window.active_tab and GetCapture() == hwnd)
                {
                    window.showTab(idx, false);
                };
                return 0;
            }
            if (wparam == RESIZE_OVERLAY_TIMER_ID) {
                if (window.resize_overlay_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
                _ = w32.KillTimer(hwnd, RESIZE_OVERLAY_TIMER_ID);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLORSTATIC => {
            if (window.split_preview) |preview| if (@intFromPtr(preview) == @as(usize, @bitCast(lparam))) {
                if (GetSysColorBrush(13)) |brush| return @bitCast(@intFromPtr(brush)); // COLOR_HIGHLIGHT
            };
            // Dark theming for the STATIC popups owned by this window
            // (hovered-URL link preview, resize overlay). Static controls
            // send this to their owner, i.e. here — not to surfaceWndProc.
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (window.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SHOWWINDOW => {
            // ShowWindow sends this before updating WS_VISIBLE, so use its
            // new state rather than querying the old native style. This also
            // covers quick-terminal animation completion and app hide/show.
            window.setActiveTabVisible(wparam != 0 and w32.IsIconic(hwnd) == 0);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_DPICHANGED => {
            const dpi: u16 = @truncate(wparam);
            if (dpi == 0) return 0;
            window.scale = @as(f32, @floatFromInt(dpi)) / 96;
            window.refreshWindowFonts();
            for (window.tab_trees[0..window.tab_count]) |*tree| {
                var it = tree.iterator();
                while (it.next()) |entry| entry.view.applyDpiScale(window.scale);
            }
            if (lparam != 0) {
                const rect: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
            }
            window.layoutSplits();
            window.invalidateTabBar();
            return 0;
        },
        w32.WM_SIZE => {
            // Minimizing does not hide child surface HWNDs, so tell the core
            // to stop rendering the active tab while minimized. Return early:
            // the client rect is 0x0 while minimized, so re-laying-out would
            // both re-mark the surfaces visible (undoing the occlusion) and
            // collapse the grid, and the resize overlay would flash offscreen.
            if (wparam == w32.SIZE_MINIMIZED) {
                window.setActiveTabVisible(false);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setActiveTabVisible(window.isVisible());
            }
            window.handleResize();
            return 0;
        },
        w32.WM_POWERBROADCAST => {
            // After system sleep/resume nothing else kicks a re-present:
            // the renderer has no vsync/power awareness, so without this
            // the last pre-sleep frame can stay on screen stale (the same
            // bug as microsoft/terminal#14483). Invalidate every surface
            // in the active tab; the surface WM_PAINT handler validates
            // and wakes the renderer thread, driving a full re-present
            // through the existing pipeline. Both resume events may
            // arrive for a single resume; the redundant invalidation is
            // harmless. Return TRUE per the message contract.
            if (wparam == w32.PBT_APMRESUMEAUTOMATIC or
                wparam == w32.PBT_APMRESUMESUSPEND)
            {
                if (window.active_tab < window.tab_count) {
                    var it = window.tab_trees[window.active_tab].iterator();
                    while (it.next()) |entry| {
                        if (entry.view.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
                    }
                }
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOVE => {
            // Top-level move: child surface HWNDs do NOT receive WM_MOVE
            // (their position relative to the parent is unchanged), but the
            // scrollbar is a screen-positioned popup that must follow its
            // owner. Reposition every surface's scrollbar across all tabs
            // so hidden tabs don't surface a stale position when activated.
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    if (entry.view.scrollbar) |sb| _ = sb.repositionAndResize();
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETMINMAXINFO => {
            // Apply user-configured size limits if any. lparam points
            // to a MINMAXINFO the OS will consult for resize clamping.
            if (window.min_track_w > 0 or window.min_track_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (window.min_track_w > 0) mmi.ptMinTrackSize.x = window.min_track_w;
                if (window.min_track_h > 0) mmi.ptMinTrackSize.y = window.min_track_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            // No limits → fall through to DefWindowProc.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ENTERSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = true;
            }
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = false;
            }
            return 0;
        },
        w32.WM_CLOSE => {
            // Title-bar X / Alt+F4 / close_all_windows land here. Confirm
            // once for the whole window if any tab has a running process.
            if (!window.confirmCloseIfNeeded()) return 0;
            window.close();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },
        w32.WM_PAINT => {
            window.paintTabBar();
            return 0;
        },
        w32.WM_DWMCOMPOSITIONCHANGED => {
            window.applyBackground();
            window.invalidateTabBar();
            return 0;
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            // Tab rename Edit lost focus — commit (standard Win32
            // convention, matches Explorer file rename and Edge tabs).
            // Esc still cancels via the message-loop intercept that
            // catches VK_ESCAPE before it reaches the Edit.
            if (control_id == RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
                window.finishTabRename();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            // Forward keyboard focus to the active child surface.
            // Without this, keyboard input stays on the parent and
            // is never delivered to the terminal.
            if (window.getActiveSurface()) |s| {
                if (s.hwnd) |h| _ = w32.SetFocus(h);
            }
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.hitTestDivider(x, y)) |hit| {
                window.startDividerDrag(hit.handle, hit.layout);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarClick(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                window.endDividerDrag();
                return 0;
            }
            window.finishTabDrag(.{ .x = @as(i16, @truncate(lparam)), .y = @as(i16, @truncate(lparam >> 16)) });
            return 0;
        },
        WM_CAPTURECHANGED => {
            window.cancelTabDrag();
            window.dragging_split = false;
            return 0;
        },
        WM_CANCELMODE => {
            window.cancelTabDrag();
            window.endDividerDrag();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (y < window.tabBarHeight()) {
                if (window.tabAt(x, y)) |i| window.startTabRename(i);
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            if (y < window.tabBarHeight()) {
                window.handleTabBarRightClick(x, y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.dragging_split) {
                window.updateDividerDrag(x, y);
                return 0;
            }
            // Handle tab drag reorder
            if (window.drag_tab >= 0) {
                window.beginTabDrag(.{ .x = x, .y = y });
                if (window.drag_active) {
                    window.drag_x = x;
                    var screen: w32.POINT = .{ .x = x, .y = y };
                    if (w32.ClientToScreen(hwnd, &screen) != 0) {
                        const target = window.dropTarget(screen);
                        window.showDropTarget(target);
                        const on_strip = y >= 0 and y < window.tabBarHeight() and x >= 0 and x < window.tab_buttons[0].left;
                        window.drag_on_strip = on_strip;
                        const hover = if (on_strip) window.tabAt(x, y) else null;
                        window.setDragHover(if (hover == @as(usize, @intCast(window.drag_tab))) null else hover);
                        const over_pane = if (target) |t| t.target == .pane else false;
                        window.showDraggedTitle(screen, on_strip or over_pane);
                    }
                    window.invalidateTabBar();
                }
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                if (window.hwnd) |h| _ = w32.ScreenToClient(h, &pt);
                if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                    const cursor_id: usize = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
                    if (w32.LoadCursorW(null, cursor_id)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            window.handleTabBarMouseLeave();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    qt.onFocusLost();
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
