//! Win32 application runtime for Ghostty on Windows.
//! Uses native Win32 API for windowing, input, and clipboard.

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");

test {
    // Discover native runtime tests even when a filter excludes App's tests.
    _ = App;
    _ = Surface;
    _ = @import("win32/Window.zig");
    _ = @import("win32/TabOverview.zig");
    _ = @import("win32/Profiles.zig");
    _ = @import("win32/Settings.zig");
    _ = @import("win32/RendererStartup.zig");
    _ = @import("win32/ConsoleAttachmentTest.zig");
    _ = @import("win32/TerminalHandoff.zig");
    _ = @import("win32/Icons.zig");
    _ = @import("win32/TabText.zig");
    _ = @import("win32/UiLanguage.zig");
}

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;
