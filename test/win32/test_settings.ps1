param(
    [Parameter(Mandatory)][string]$ExePath
)

# Run from the Windows desktop session with a complete, locally staged build.
# Only the launched terminal's window and its settings child receive actions.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'settings_uia.ps1')
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class SettingsSmokeWindows {
    delegate bool WindowCallback(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct Point { public int X, Y; }
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);

    public static bool ProfileIconVisible(int processId, int left, int top, int height, bool custom) {
        // The image is decorative and intentionally absent from the UIA control
        // tree. Sample the leading icon slot of this owned UIA element.
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        IntPtr dc = GetDC(IntPtr.Zero);
        try {
            int y = top + height / 2;
            for (int x = left + 3; x < left + height; x += 2) {
                if (!Owns(WindowFromPoint(new Point { X = x, Y = y }), processId)) continue;
                uint color = GetPixel(dc, x, y);
                int red = (int)(color & 255), green = (int)((color >> 8) & 255), blue = (int)((color >> 16) & 255);
                if (custom ? red == 247 && green == 23 && blue == 173 :
                        blue >= 110 && blue > red + 45 && blue > green + 12) return true;
            }
            return false;
        } finally { ReleaseDC(IntPtr.Zero, dc); SetThreadDpiAwarenessContext(previous); }
    }

    [DllImport("user32.dll")]
    static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr window, StringBuilder name, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr window, StringBuilder title, int maxCount);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    static extern int GetWindowLong(IntPtr window, int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);

    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
    [DllImport("user32.dll")] static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
    public static bool PerMonitorV2(IntPtr window) {
        return AreDpiAwarenessContextsEqual(GetWindowDpiAwarenessContext(window),new IntPtr(-4));
    }
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);

    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr window, uint attribute, out int value, uint size);

    public static bool Owns(IntPtr window, int processId) {
        uint actualProcessId;
        return window != IntPtr.Zero && GetWindowThreadProcessId(window, out actualProcessId) != 0
            && actualProcessId == (uint)processId;
    }

    public static IntPtr FindVisible(int processId, string windowClass, string windowTitle) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, parameter) => {
            if (!Owns(window, processId) || !IsWindowVisible(window)) return true;
            if (!String.IsNullOrEmpty(windowClass)) {
                var name = new StringBuilder(256);
                if (GetClassName(window, name, name.Capacity) == 0 || name.ToString() != windowClass) return true;
            }
            if (!String.IsNullOrEmpty(windowTitle)) {
                var title = new StringBuilder(256);
                if (GetWindowText(window, title, title.Capacity) == 0 || title.ToString() != windowTitle) return true;
            }
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static void PostOwned(IntPtr window, int processId, uint message, int wParam) {
        if (!Owns(window, processId)) throw new InvalidOperationException("Target window is not owned by the test process.");
        if (!PostMessage(window, message, new IntPtr(wParam), IntPtr.Zero)) throw new Win32Exception();
    }

    public static bool IsLayered(IntPtr window, int processId) {
        if (!Owns(window, processId)) throw new InvalidOperationException("Target window is not owned by the test process.");
        const int GWL_EXSTYLE = -20;
        const int WS_EX_LAYERED = 0x00080000;
        return (GetWindowLong(window, GWL_EXSTYLE) & WS_EX_LAYERED) != 0;
    }

    public static int SystemBackdrop(IntPtr window, int processId) {
        if (!Owns(window, processId)) throw new InvalidOperationException("Target window is not owned by the test process.");
        const uint DWMWA_SYSTEMBACKDROP_TYPE = 38;
        int value;
        int hr = DwmGetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, out value, sizeof(int));
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        return value;
    }

    public static int TerminalPixel(IntPtr window, int processId) {
        if (!Owns(window, processId)) throw new InvalidOperationException("Target window is not owned by the test process.");
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            IntPtr child = FindWindowEx(window, IntPtr.Zero, "GhosttyTerminal", null);
            Rect outer, inner;
            if (!Owns(child, processId) || !GetWindowRect(window, out outer) || !GetWindowRect(child, out inner))
                return -1;
            int width = outer.Right - outer.Left, height = outer.Bottom - outer.Top;
            if (width <= 0 || height <= 0) return -1;
            int x = inner.Left - outer.Left + (inner.Right - inner.Left) / 2;
            int y = inner.Top - outer.Top + (inner.Bottom - inner.Top) / 2;
            IntPtr target = GetDC(window);
            if (target == IntPtr.Zero) return -1;
            IntPtr dc = CreateCompatibleDC(target);
            IntPtr bitmap = CreateCompatibleBitmap(target, width, height);
            try {
                if (dc == IntPtr.Zero || bitmap == IntPtr.Zero) return -1;
                IntPtr previous = SelectObject(dc, bitmap);
                try {
                    if (!PrintWindow(window, dc, 2)) return -1;
                    uint bgr = GetPixel(dc, x, y);
                    if (bgr == uint.MaxValue) return -1;
                    return (int)(((bgr & 0xff) << 16) | (bgr & 0xff00) | ((bgr >> 16) & 0xff));
                } finally { SelectObject(dc, previous); }
            } finally {
                if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
                if (dc != IntPtr.Zero) DeleteDC(dc);
                ReleaseDC(window, target);
            }
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }
}
'@

function Assert-True($condition, [string]$description) {
    if (-not $condition) { throw $description }
}

function Wait-For([string]$description, [scriptblock]$check, [int]$seconds = 20) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($terminal.HasExited) { throw "Terminal exited with code $($terminal.ExitCode) while waiting for $description." }
        $result = & $check
        if ($result) { return $result }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt $seconds)
    throw "Timed out waiting for $description."
}

function Find-Control([System.Windows.Automation.AutomationElement]$root, [string]$id) {
    $property = [System.Windows.Automation.AutomationElement]::AutomationIdProperty
    $condition = [System.Windows.Automation.PropertyCondition]::new($property, $id)
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Open-Settings {
    # WM_SYSCOMMAND with the terminal's SC_SETTINGS menu command.
    [SettingsSmokeWindows]::PostOwned($terminalWindow, $terminal.Id, 0x0112, 0x1FD0)
    $process = Wait-For 'the settings child process' {
        $filter = "ParentProcessId = $($terminal.Id) AND Name = 'Madotty.Settings.exe'"
        foreach ($child in Get-CimInstance Win32_Process -Filter $filter) {
            $childId = [int]$child.ProcessId
            if ($settingsProcesses.ContainsKey($childId)) { continue }
            $candidate = Get-Process -Id $childId -ErrorAction SilentlyContinue
            if ($null -eq $candidate) { continue }
            # Hold a kernel handle so the exit code remains available after a crash.
            $null = $candidate.Handle
            $settingsProcesses.Add($childId, $candidate)
            return $candidate
        }
    }
    return Wait-For 'the Madotty Settings window and its automation controls' {
        if ($process.HasExited) {
            throw ('Settings child {0} exited with code 0x{1:X8} before its automation controls were ready.' -f $process.Id, $process.ExitCode)
        }
        $window = Find-SettingsWindow { param($title) [SettingsSmokeWindows]::FindVisible($process.Id, '', $title) }
        if ($window -ne [IntPtr]::Zero) {
            if (-not [SettingsSmokeWindows]::PerMonitorV2($window)) { throw 'Settings is subject to bitmap DPI scaling.' }
            try {
                $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
                if ($root.Current.ProcessId -ne $process.Id) { return }
                $material = Find-Control $root 'windows-background-material'
                $save = Find-Control $root 'save-settings'
                $cancel = Find-Control $root 'cancel-settings'
                if ($material -and $save -and $cancel) {
                    return @{ ProcessId = $process.Id; Root = $root; Material = $material; Save = $save; Cancel = $cancel }
                }
            } catch [System.Windows.Automation.ElementNotAvailableException] {
                # A startup window can be replaced while building the UIA tree.
            }
        }
    }
}

function Get-ComboValue($combo) {
    $selection = $combo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    $items = $selection.Current.GetSelection()
    if ($items.Length -eq 1) {
        $value = $items[0].Current.Name
        foreach ($english in $settingsLabels.Keys) {
            if ($value -cin $settingsLabels[$english]) { return $english }
        }
        return $value
    }
}

function Get-Material($settings) {
    Get-ComboValue $settings.Material
}

function Select-SettingsPage($settings, [string]$id, [string]$firstControl) {
    $tab = Wait-For "the $id page tab" { Find-Control $settings.Root $id }
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $null = Wait-For "the $id page" {
        $child = Find-Control $settings.Root $firstControl
        if ($child -and -not $child.Current.IsOffscreen) { $child }
    }
}

function Find-SettingsText($root, [string]$text, [object[]]$values = @()) {
    $condition = New-SettingsNameCondition $text $values
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Get-RenderedFont($settings, [string]$label) {
    $element = Wait-For "the $label text" { Find-SettingsText $settings.Root $label }
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    $pattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::FontNameAttribute)
}

function Test-KeybindingPage($settings) {
    Select-SettingsPage $settings 'settings-keybindings' 'keybindings-search'
    $search = (Find-Control $settings.Root 'keybindings-search').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $chord = 'Ctrl+Alt+F10 ' + [char]0x203A + ' G'
    $chain = 'New Tab ' + [char]0x2192 + ' New Window'
    if ($settings.Root.Current.Name -cin $settingsLabels['Madotty Settings']) {
        $chain = $settingsLabels['New tab'][0] + ' ' + [char]0x2192 + ' ' + $settingsLabels['New window'][0]
    }
    $search.SetValue('cTrL+Alt+F10')
    $null = Wait-For 'the resolved chord and ordered actions' {
        (Find-SettingsText $settings.Root $chord) -and (Find-SettingsText $settings.Root $chain)
    }
    $search.SetValue('rEvIeW')
    $null = Wait-For 'the named key table and filtered results' {
        (Find-SettingsText $settings.Root 'Table {0}' @('review')) -and
        -not (Find-SettingsText $settings.Root $chain)
    }
    $search.SetValue('missing-fixture-binding')
    $null = Wait-For 'the empty keybinding search' { Find-SettingsText $settings.Root 'No matching keybindings.' }
    Write-Output 'PASS: Keybinding search shows effective chords, chained actions, and named tables.'
}

function Test-PrivacyPage($settings, [switch]$Saved, [switch]$Change) {
    Select-SettingsPage $settings 'settings-privacy' 'clipboard-read'
    $clipboard = @(
        @{ Id = 'clipboard-read'; Initial = 'Ask'; Edited = 'Deny' },
        @{ Id = 'clipboard-write'; Initial = 'Allow'; Edited = 'Ask' }
    )
    # Change the control currently showing Ask before selecting it in the other.
    if ($Saved) { [Array]::Reverse($clipboard) }
    foreach ($entry in $clipboard) {
        $combo = Wait-For "the $($entry.Id) dropdown" { Find-Control $settings.Root $entry.Id }
        $expected = if ($Saved) { $entry.Edited } else { $entry.Initial }
        Assert-True ((Get-ComboValue $combo) -ceq $expected) "Expected $($entry.Id) to show '$expected'."
        if ($Change) {
            $selection = if ($Saved) { $entry.Initial } else { $entry.Edited }
            Select-ComboOption $settings $combo $selection
        }
    }

    $on = [System.Windows.Automation.ToggleState]::On
    $off = [System.Windows.Automation.ToggleState]::Off
    $expected = if ($Saved) { $off } else { $on }
    $changed = if ($Saved) { $on } else { $off }
    foreach ($id in @('clipboard-paste-protection', 'link-url', 'desktop-notifications')) {
        $control = Wait-For "the $id toggle" { Find-Control $settings.Root $id }
        $toggle = $control.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        Assert-True ($toggle.Current.ToggleState -eq $expected) "Expected $id to be $expected."
        if ($Change) {
            $toggle.Toggle()
            $null = Wait-For "$id to switch $changed" { $toggle.Current.ToggleState -eq $changed }
        }
    }
}

function Get-TerminalThemeEdit($settings, [string]$id) {
    $editType = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $edit = Wait-For "the $id editor" {
        $box = Find-Control $settings.Root $id
        if ($box) {
            if ($box.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit) { return $box }
            $box.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editType)
        }
    }
    $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
}

# Hold catalog replies to exercise navigation while two reads overlap. The
# native protocol permits one in-flight message and does not tag replies.
function Test-SlowCatalogNavigation([string]$companion, [string]$language) {
    Add-Type -AssemblyName System.Drawing
    $testIcon = Join-Path ([IO.Path]::GetTempPath()) ('madotty-profile-' + [guid]::NewGuid() + '.png')
    $bitmap = [Drawing.Bitmap]::new(24, 24)
    $drawing = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $drawing.Clear([Drawing.Color]::FromArgb(247, 23, 173))
        $bitmap.Save($testIcon, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $drawing.Dispose(); $bitmap.Dispose() }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $companion
    $start.Arguments = '--host'
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    # .NET Framework selects the pipe writer's encoding from the console.
    # The native host sends BOM-free UTF-8 JSON on this pipe.
    $originalInputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
    } finally {
        [Console]::InputEncoding = $originalInputEncoding
    }
    try {
        $process.StandardInput.AutoFlush = $true
        $snapshot = @{
            font_size = 13; theme = 'auto'; opacity_percent = 100; tab_bar = 'always'
            writable = $true; themes_available = $true; keybindings_available = $true; ui_language = $language
            startup_profile = 'LEGACY:PS'
            profiles = @(
                @{ id = 'builtin:custom'; alias = 'legacy:ps'; name = 'Operations shell'; icon = $testIcon; executable = (Join-Path $env:WINDIR 'System32\cmd.exe') },
                @{ id = 'builtin:powershell'; name = 'PowerShell fixture'; icon = ($testIcon + '.missing'); executable = (Join-Path $PSHOME 'powershell.exe') }
            )
        }
        $process.StandardInput.WriteLine(($snapshot | ConvertTo-Json -Depth 4 -Compress))
        $root = Wait-For 'the delayed catalog fixture' {
            if ($process.HasExited) { throw "Settings fixture exited with $($process.ExitCode)." }
            $hwnd = Find-SettingsWindow { param($title) [SettingsSmokeWindows]::FindVisible($process.Id, '', $title) }
            if ($hwnd -ne [IntPtr]::Zero) {
                $element = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
                if (Find-Control $element 'terminal-theme-light') { $element }
            }
        }
        $expectedTitle = if ($language -eq 'ja-JP') { $settingsLabels['Madotty Settings'][0] } else { 'Madotty Settings' }
        Assert-True ($root.Current.Name -ceq $expectedTitle) "Settings did not use the requested display language $language."
        $settings = @{ Root = $root; ProcessId = $process.Id }
        Select-SettingsPage $settings 'settings-startup' 'windows-default-profile'
        $profiles = Find-Control $root 'windows-default-profile'
        Assert-True ((Get-ComboValue $profiles) -ceq 'Operations shell') 'A saved legacy ID did not resolve to the named profile.'
        $null = Wait-For 'the selected custom profile icon' {
            $box = $profiles.Current.BoundingRectangle
            [SettingsSmokeWindows]::ProfileIconVisible($process.Id, $box.Left, $box.Top, $box.Height, $true)
        }
        $expand = $profiles.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expand.Expand()
        $other = Find-ComboOption $settings 'PowerShell fixture'
        $null = Wait-For 'the fallback executable icon in the menu' {
            $box = $other.Current.BoundingRectangle
            [SettingsSmokeWindows]::ProfileIconVisible($process.Id, $box.Left, $box.Top, $box.Height, $false)
        }
        $expand.Collapse()
        Assert-True (-not (Find-Control $root 'save-settings').Current.IsEnabled) 'Visiting Startup marked a legacy profile ID as edited.'
        Write-Output "PASS: $language shows the custom profile icon and executable fallback, and preserves the saved alias."
        Select-SettingsPage $settings 'settings-appearance' 'terminal-theme-light'
        (Get-TerminalThemeEdit $settings 'terminal-theme-light').SetValue('Day')
        $request = $process.StandardOutput.ReadLineAsync()
        Assert-True ($request.Wait(5000) -and ($request.Result | ConvertFrom-Json).action -ceq 'themes') 'Missing theme catalog request.'
        Select-SettingsPage $settings 'settings-keybindings' 'keybindings-search'
        $cancel = Find-Control $root 'cancel-settings'
        Assert-True $cancel.Current.IsEnabled 'Cancel is disabled while loading the theme catalog.'
        $process.StandardInput.WriteLine('{"ok":true,"themes":{"items":[{"name":"Day"}],"next_offset":null}}')

        $request = $process.StandardOutput.ReadLineAsync()
        Assert-True ($request.Wait(5000) -and ($request.Result | ConvertFrom-Json).action -ceq 'keybindings') 'Navigating during the theme read lost the keybinding request.'
        (Find-Control $root 'keybindings-search').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('zoom')
        $process.StandardInput.WriteLine('{"ok":true,"keybindings":{"rows":[],"next_offset":null}}')
        $null = Wait-For 'the completed keybinding catalog' { Find-SettingsText $root 'No keybindings configured.' }
        $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Assert-True ($process.WaitForExit(5000) -and $process.ExitCode -eq 0) 'Settings did not close cleanly after overlapping catalog reads.'
        Write-Output 'PASS: Theme and shortcut catalogs load across page changes without locking the form.'
    } finally {
        $process.StandardInput.Close()
        if ([IO.File]::Exists($testIcon)) { [IO.File]::Delete($testIcon) }
        if (-not $process.HasExited -and -not $process.WaitForExit(3000)) { $process.Kill() }
        $process.Dispose()
    }
}

function Assert-TerminalThemePixel($process, [IntPtr]$window, [int]$rgb) {
    $null = Wait-For ('terminal background #{0:x6}' -f $rgb) {
        [SettingsSmokeWindows]::TerminalPixel($window, $process.Id) -eq $rgb
    }
}

function Set-Material($settings, [string]$name) {
    Select-ComboOption $settings $settings.Material $name
}

function Select-ComboOption($settings, $combo, [string]$name, [switch]$FromTop) {
    $expand = $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    if ($FromTop) {
        # WinUI virtualizes long font lists around the selected family.
        $scroll = $combo.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    }
    $item = Find-ComboOption $settings $name
    $select = $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $select.Select()
    if ($expand.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) {
        $expand.Collapse()
    }
    $null = Wait-For "'$name' to be selected and the popup to close" {
        if ($expand.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Collapsed) { return }
        $selection = $combo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
        $selection.Length -eq 1 -and $selection[0].Current.Name -cin @(Get-SettingsLabels $name)
    }
}

function Find-ComboOption($settings, [string]$name) {
    $itemName = New-SettingsNameCondition $name
    $itemType = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $condition = [System.Windows.Automation.AndCondition]::new($itemName, $itemType)
    return Wait-For "the '$name' option" {
        try {
            $child = $settings.Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($child -and $child.Current.ProcessId -eq $settings.ProcessId) { return $child }

            # WinUI may expose the expanded list in a separate popup HWND.
            $processCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $settings.ProcessId)
            $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Children, $processCondition)
            foreach ($root in $roots) {
                $child = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
                if ($child -and $child.Current.ProcessId -eq $settings.ProcessId) { return $child }
            }
        } catch [System.Windows.Automation.ElementNotAvailableException] {
            # Retry if the popup is still replacing its automation tree.
        }
    }
}

function Invoke-SettingsButton($settings, [string]$button) {
    $invoke = $settings[$button].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invoke.Invoke()
    $process = $settingsProcesses[$settings.ProcessId]
    $null = Wait-For "the settings child to exit after $button" { $process.HasExited }
    if ($process.ExitCode -ne 0) {
        throw ('Settings child {0} exited with code 0x{1:X8} after {2}.' -f $process.Id, $process.ExitCode, $button)
    }
}

function Assert-WindowBackground([bool]$layered, [int]$backdrop) {
    $actualLayered = [SettingsSmokeWindows]::IsLayered($terminalWindow, $terminal.Id)
    Assert-True ($actualLayered -eq $layered) "Expected WS_EX_LAYERED=$layered after Save, got $actualLayered."
    if ($supportsSystemBackdrop) {
        $actualBackdrop = [SettingsSmokeWindows]::SystemBackdrop($terminalWindow, $terminal.Id)
        Assert-True ($actualBackdrop -eq $backdrop) "Expected DWM backdrop $backdrop after Save, got $actualBackdrop."
    }
}

$exe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
Assert-True ([IO.File]::Exists($exe) -and -not $exe.StartsWith('\\')) 'Stage the terminal executable on a local Windows drive.'
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $temp ('madotty-settings-test-' + [Guid]::NewGuid().ToString('N'))
$configDir = Join-Path $testRoot 'ghostty'
$themeDir = Join-Path $configDir 'themes'
$dayTheme = 'Madotty Fixture Day'
$nightTheme = 'Madotty Fixture Night, Contrast'
$profileDir = Join-Path $testRoot 'local\Microsoft\Windows Terminal'
$profileGuid = '{C9D29D16-15A3-42FD-946B-83AEEB6ED424}'
$profileScript = Join-Path $testRoot 'profile.ps1'
$profileMarker = Join-Path $testRoot 'profile-started'
$explicitScript = Join-Path $testRoot 'explicit.ps1'
$explicitMarker = Join-Path $testRoot 'explicit-started'
$mainConfig = Join-Path $configDir 'config.ghostty'
$sidecar = Join-Path $configDir 'madotty-gui.ghostty'
$windowsBuild = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber
$supportsSystemBackdrop = [int]$windowsBuild -ge 22621
$autoLayered = -not $supportsSystemBackdrop
$autoBackdrop = if ($supportsSystemBackdrop) { 3 } else { 1 }
$original = @(
    '# Keep this text and its CRLF formatting.',
    'cursor-style = bar',
    'font-family = Consolas',
    'font-family = Yu Gothic',
    'font-size = 17',
    'config-file = ?personal.ghostty',
    'background-opacity = 0.87321',
    'background-blur = true',
    'command = cmd.exe /d /q',
    'shell-integration = none',
    'confirm-close-surface = false',
    'quit-after-last-window-closed = true',
    'keybind = ctrl+alt+f10>g=new_tab',
    'keybind = chain=new_window',
    'keybind = review/ctrl+shift+f11=reload_config',
    'auto-update = off'
) -join "`r`n"

$terminal = $null
$themeTerminal = $null
$themeWindow = [IntPtr]::Zero
$profileTerminal = $null
$explicitTerminal = $null
$terminalError = $null
$terminalWindow = [IntPtr]::Zero
$failed = $false
$settingsProcesses = [Collections.Generic.Dictionary[int, Diagnostics.Process]]::new()
try {
    [IO.Directory]::CreateDirectory($configDir) | Out-Null
    [IO.File]::WriteAllText($mainConfig, $original, [Text.UTF8Encoding]::new($false))
    $directVulkan = [IO.Path]::GetFileName($exe) -ieq 'ghostty-vulkan.exe'
    if ($directVulkan) {
        [IO.File]::AppendAllText($mainConfig, "`r`nwindows-background-material = mica`r`n")
    }
    [IO.Directory]::CreateDirectory($themeDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $themeDir $dayTheme), "background = edebe2`nforeground = 222222`n")
    [IO.File]::WriteAllText((Join-Path $themeDir $nightTheme), "background = 172940`nforeground = eeeeee`n")
    [IO.Directory]::CreateDirectory($profileDir) | Out-Null
    [IO.File]::WriteAllText($profileScript, '[IO.File]::WriteAllText($env:MADOTTY_TEST_PROFILE_MARKER, "started")')
    $profileCommand = '"' + (Join-Path $PSHOME 'powershell.exe') + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $profileScript + '"'
    $profileList = @{ profiles = @{ list = @(@{ guid = $profileGuid; name = 'Smoke test shell'; commandline = $profileCommand }) } }
    [IO.File]::WriteAllText((Join-Path $profileDir 'settings.json'), ($profileList | ConvertTo-Json -Depth 5))

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.WorkingDirectory = $testRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $testRoot
    $start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $testRoot 'local'
    $start.EnvironmentVariables['MADOTTY_TEST_PROFILE_MARKER'] = $profileMarker
    $start.EnvironmentVariables.Remove('GHOSTTY_RESOURCES_DIR')
    $terminal = [Diagnostics.Process]::Start($start)
    $null = $terminal.StandardOutput.ReadToEndAsync()
    $terminalError = $terminal.StandardError.ReadToEndAsync()
    $terminalWindow = Wait-For 'the launched terminal window' {
        $window = [SettingsSmokeWindows]::FindVisible($terminal.Id, 'GhosttyWindow', '')
        if ($window -ne [IntPtr]::Zero) { $window }
    }
    $settingsFilter = "ParentProcessId = $($terminal.Id) AND Name = 'Madotty.Settings.exe'"
    Assert-True (-not (Get-CimInstance Win32_Process -Filter $settingsFilter)) 'Terminal startup launched the settings process.'
    if ($directVulkan) {
        Assert-WindowBackground $true 1
        $settings = Open-Settings
        Assert-True ((Get-Material $settings) -ceq 'Follow Ghostty config') 'Vulkan should show its effective material.'
        $expand = $settings.Material.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expand.Expand()
        foreach ($label in 'Mica','Acrylic','Solid','Follow Ghostty config') {
            $item = Find-ComboOption $settings $label
            Assert-True ($item.Current.IsEnabled -eq ($label -in 'Solid','Follow Ghostty config')) "Unexpected availability for $label."
        }
        $expand.Collapse()
        $slider = Wait-For 'the enabled Vulkan opacity control' {
            $control = Find-Control $settings.Root 'background-opacity'
            if ($control -and $control.Current.IsEnabled) { return $control }
        }
        Assert-True $slider.Current.IsEnabled 'Vulkan window opacity must remain editable.'
        $slider.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue(62)
        Invoke-SettingsButton $settings 'Save'
        $edits = [IO.File]::ReadAllText($sidecar)
        Assert-True ($edits -match 'background-opacity = 0\.62' -and $edits -notmatch 'windows-background-material') 'Editing Vulkan opacity overwrote the saved material.'
        $settings = Open-Settings
        Set-Material $settings 'Solid'
        Invoke-SettingsButton $settings 'Save'
        Assert-WindowBackground $false 1
        Assert-True ([IO.File]::ReadAllText($sidecar) -match 'windows-background-material = solid') 'Vulkan did not save an explicit material edit.'
        Write-Output 'PASS: Direct Vulkan disables system materials, preserves configured Mica, and supports opacity and Solid.'
        return
    }
    Assert-WindowBackground $autoLayered $autoBackdrop

    foreach ($language in 'ja-JP','en-US') {
        Test-SlowCatalogNavigation (Join-Path (Split-Path $exe) 'settings\Madotty.Settings.exe') $language
    }

    $settings = Open-Settings
    $fontSize = Find-Control $settings.Root 'font-size'
    Assert-True ($null -ne $fontSize) 'The font size control is missing.'
    $fontBounds = $fontSize.Current.BoundingRectangle
    $saveBounds = $settings.Save.Current.BoundingRectangle
    Assert-True (-not $fontBounds.IsEmpty -and -not $saveBounds.IsEmpty -and
        $fontBounds.Right -le ($saveBounds.Right + 1)) 'The first settings control clips outside the form.'
    Write-Output 'PASS: The settings form fits inside the window at its default size.'
    Assert-True ((Get-Material $settings) -ceq 'Follow Ghostty config') 'The material should open in Follow Ghostty config.'
    Set-Material $settings 'Solid'
    Select-SettingsPage $settings 'settings-startup' 'windows-default-profile'
    $action = Wait-For 'the default terminal capability check' {
        $button = Find-Control $settings.Root 'default-terminal-action'
        $info = Find-Control $settings.Root 'default-terminal-status'
        if ($button -and -not $button.Current.IsOffscreen -and ($button.Current.IsEnabled -or
            ($info -and -not $info.Current.IsOffscreen -and $info.Current.Name))) { $button }
    }
    $profile = Find-Control $settings.Root 'windows-default-profile'
    Assert-True $profile.Current.IsEnabled 'The default profile must remain available independently of Windows registration.'
    if ([int]$windowsBuild -lt 22000) {
        Assert-True (-not $action.Current.IsEnabled) 'Default terminal registration requires Windows 11.'
    } elseif ($action.Current.IsEnabled) {
        Assert-True ($null -ne $action.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)) 'The enabled default terminal control has no action.'
    } else {
        Assert-True (-not (Find-SettingsText $settings.Root 'Could not check terminal registration.')) 'The default terminal catalog could not be read.'
        Assert-True ($null -ne (Find-SettingsText $settings.Root 'Registration requires a trusted integration package.')) 'A disabled terminal action needs its reason.'
    }
    Write-Output 'PASS: Startup exposes Windows terminal integration according to capability; the profile stays editable.'
    Select-SettingsPage $settings 'settings-terminal' 'cursor-style'
    Test-PrivacyPage $settings -Change
    Select-SettingsPage $settings 'settings-tabs' 'window-new-tab-position'
    Select-SettingsPage $settings 'settings-graphics' 'windows-renderer'
    $null = Wait-For 'shader controls on the rendering page' { Find-Control $settings.Root 'shader-animation' }
    Test-KeybindingPage $settings
    Select-SettingsPage $settings 'settings-appearance' 'windows-background-material'
    $settings.Material = Find-Control $settings.Root 'windows-background-material'
    Assert-True ((Get-Material $settings) -ceq 'Solid') 'Changing settings pages lost the unsaved material change.'
    Write-Output 'PASS: All settings pages open and preserve unsaved changes when switching.'
    Invoke-SettingsButton $settings 'Cancel'
    Assert-True (-not [IO.File]::Exists($sidecar)) 'Cancel created the managed settings file.'
    Assert-True ([IO.File]::ReadAllText($mainConfig) -ceq $original) 'Cancel changed the main config.'
    Assert-WindowBackground $autoLayered $autoBackdrop
    Write-Output 'PASS: WinUI settings Cancel leaves both config paths untouched.'

    $expectedMainConfig = $original + "`r`nconfig-file = ?madotty-gui.ghostty`r`n"
    $previous = 'Follow Ghostty config'
    $materials = @(
        @{ Name = 'Mica'; Key = 'mica'; Layered = $false; Backdrop = 2 },
        @{ Name = 'Acrylic'; Key = 'acrylic'; Layered = $false; Backdrop = 3 },
        @{ Name = 'Solid'; Key = 'solid'; Layered = $false; Backdrop = 1 },
        @{ Name = 'Follow Ghostty config'; Key = 'auto'; Layered = $autoLayered; Backdrop = $autoBackdrop }
    )
    foreach ($material in $materials) {
        $settings = Open-Settings
        Assert-True ((Get-Material $settings) -ceq $previous) "The settings window should reopen with '$previous' selected."
        Set-Material $settings $material.Name
        Invoke-SettingsButton $settings 'Save'
        Assert-True ([IO.File]::Exists($sidecar)) 'Save did not create the managed settings file.'
        $expectedSetting = '\Awindows-background-material = ' + $material.Key + '(?:\r?\n)?\z'
        Assert-True ([IO.File]::ReadAllText($sidecar) -cmatch $expectedSetting) "Save should persist only the '$($material.Key)' material setting."
        Assert-True ([IO.File]::ReadAllText($mainConfig) -ceq $expectedMainConfig) 'Save changed unrelated config text or did not append the managed include.'
        Assert-WindowBackground $material.Layered $material.Backdrop
        Write-Output "PASS: '$($material.Name)' saves and updates the running terminal."
        $previous = $material.Name
    }

    $settings = Open-Settings
    Assert-True ((Get-Material $settings) -ceq $previous) "The settings window should reopen with '$previous' selected."
    Invoke-SettingsButton $settings 'Cancel'
    Write-Output 'PASS: saved materials reopen correctly and Follow Ghostty config restores legacy opacity.'

    $settings = Open-Settings
    $uiFont = Find-Control $settings.Root 'windows-ui-font-family'
    Assert-True ((Get-ComboValue $uiFont) -ceq 'System default') 'Interface font should initially follow Windows.'
    $defaultFace = Get-RenderedFont $settings 'Typography'
    Select-ComboOption $settings $uiFont 'Arial'
    Assert-True ((Get-RenderedFont $settings 'Typography') -ceq 'Arial') 'The settings text did not preview the selected interface font.'
    Invoke-SettingsButton $settings 'Save'
    $savedFont = [IO.File]::ReadAllText($sidecar)
    Assert-True ($savedFont -cmatch '(?m)^windows-ui-font-family = Arial\r?$') 'Saving the interface font did not persist the family.'
    Assert-True ($savedFont -cnotmatch '(?m)^font-(family|size)\s*=') 'Changing the interface font also wrote a terminal font setting.'
    Assert-True ([IO.File]::ReadAllText($mainConfig) -ceq $expectedMainConfig) 'Changing the interface font changed the original terminal configuration.'
    $settings = Open-Settings
    $uiFont = Find-Control $settings.Root 'windows-ui-font-family'
    Assert-True ((Get-ComboValue $uiFont) -ceq 'Arial' -and (Get-RenderedFont $settings 'Typography') -ceq 'Arial') 'The saved interface family did not reopen.'
    Select-ComboOption $settings $uiFont 'System default'
    Assert-True ((Get-RenderedFont $settings 'Typography') -ceq $defaultFace) 'The settings preview did not restore the system font.'
    Invoke-SettingsButton $settings 'Save'
    $settings = Open-Settings
    Assert-True ((Get-ComboValue (Find-Control $settings.Root 'windows-ui-font-family')) -ceq 'System default' -and
        (Get-RenderedFont $settings 'Typography') -ceq $defaultFace) 'The default interface font did not reopen.'
    Invoke-SettingsButton $settings 'Cancel'
    Write-Output 'PASS: Interface font previews, persists, and resets independently of terminal typography.'
    $settings = Open-Settings
    $terminalFont = Find-Control $settings.Root 'font-family'
    Assert-True ((Get-ComboValue $terminalFont) -ceq 'Consolas') 'The terminal font picker did not read the existing primary family.'
    Select-ComboOption $settings $terminalFont 'Arial' -FromTop
    Invoke-SettingsButton $settings 'Save'
    Assert-True ([IO.File]::ReadAllText($sidecar) -match 'font-family = Arial\r?\nfont-family = Yu Gothic') 'Changing the primary terminal face lost a configured fallback.'
    $settings = Open-Settings
    $terminalFont = Find-Control $settings.Root 'font-family'
    Assert-True ((Get-ComboValue $terminalFont) -ceq 'Arial') 'The selected terminal font did not reopen.'
    Assert-True ((Get-ComboValue (Find-Control $settings.Root 'windows-ui-font-family')) -ceq 'System default') 'Changing the terminal font changed the interface font.'
    Select-ComboOption $settings $terminalFont 'System default' -FromTop
    Invoke-SettingsButton $settings 'Save'
    $settings = Open-Settings
    Assert-True ((Get-ComboValue (Find-Control $settings.Root 'font-family')) -ceq 'System default') 'The default terminal font did not reopen.'
    Invoke-SettingsButton $settings 'Cancel'
    Write-Output 'PASS: Terminal font reads existing configuration, saves, reopens and resets independently of the UI font.'

    $settings = Open-Settings
    $slider = (Find-Control $settings.Root 'background-opacity').GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
    $slider.SetValue(100)
    Set-Material $settings 'Mica'
    Assert-True ($slider.Current.Value -eq 70) 'Selecting Mica over an opaque terminal should offer a visible tint.'
    Set-Material $settings 'Follow Ghostty config'
    Assert-True ($slider.Current.Value -eq 100) 'Deselecting the material should restore the original opacity.'
    Set-Material $settings 'Acrylic'
    Assert-True ($slider.Current.Value -eq 70) 'Acrylic did not offer a visible tint.'
    Invoke-SettingsButton $settings 'Save'
    $savedTint = [IO.File]::ReadAllText($sidecar)
    Assert-True ($savedTint -cmatch '(?m)^background-opacity = 0\.7\r?$' -and
        $savedTint -cmatch '(?m)^windows-background-material = acrylic\r?$') 'The displayed material tint was not saved.'
    $settings = Open-Settings
    $slider = (Find-Control $settings.Root 'background-opacity').GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
    Assert-True ($slider.Current.Value -eq 70 -and (Get-Material $settings) -ceq 'Acrylic') 'The material tint did not reopen.'
    $slider.SetValue(100)
    Invoke-SettingsButton $settings 'Save'
    $settings = Open-Settings
    $slider = (Find-Control $settings.Root 'background-opacity').GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
    Assert-True ($slider.Current.Value -eq 100 -and (Get-Material $settings) -ceq 'Acrylic') 'An explicit opaque tint was replaced on reopen.'
    Invoke-SettingsButton $settings 'Cancel'
    Write-Output 'PASS: System materials offer a visible tint, retain customized opacity, and reopen with the saved value.'

    $settings = Open-Settings
    Select-SettingsPage $settings 'settings-tabs' 'window-new-tab-position'
    Select-ComboOption $settings (Find-Control $settings.Root 'window-new-tab-position') 'At the end'
    $inherit = Wait-For 'the working-directory inheritance toggle' {
        Find-Control $settings.Root 'tab-inherit-working-directory'
    }
    $toggle = $inherit.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    Assert-True ($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) 'Working-directory inheritance should start enabled.'
    $toggle.Toggle()
    $progress = Wait-For 'the terminal progress toggle' { Find-Control $settings.Root 'progress-style' }
    $progressToggle = $progress.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    Assert-True ($progressToggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) 'Progress indicators should start enabled.'
    $progressToggle.Toggle()
    Invoke-SettingsButton $settings 'Save'
    $savedText = [IO.File]::ReadAllText($sidecar)
    Assert-True ($savedText -cmatch '(?m)^window-new-tab-position = end\r?$') 'The new-tab position did not persist.'
    Assert-True ($savedText -cmatch '(?m)^tab-inherit-working-directory = false\r?$') 'The directory inheritance setting did not persist.'
    Assert-True ($savedText -cmatch '(?m)^progress-style = false\r?$') 'The progress indicator setting did not persist.'
    Write-Output 'PASS: Tab position, directory inheritance, and progress indicators save as Ghostty config keys.'

    $settings = Open-Settings
    $windowTheme = Wait-For 'the window theme dropdown' { Find-Control $settings.Root 'window-theme' }
    $lightEditor = Get-TerminalThemeEdit $settings 'terminal-theme-light'
    Assert-True ($lightEditor.Current.Value -ceq '') 'The terminal theme should start empty.'
    $lightEditor.SetValue($dayTheme)
    $separate = (Find-Control $settings.Root 'separate-terminal-themes').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $separate.Toggle()
    (Get-TerminalThemeEdit $settings 'terminal-theme-dark').SetValue($nightTheme)
    $null = Wait-For 'window theme editing after loading suggestions' { $windowTheme.Current.IsEnabled }
    Select-ComboOption $settings $windowTheme 'Dark'
    Set-Material $settings 'Solid'
    $null = Wait-For 'theme settings to be ready to save' { $settings.Save.Current.IsEnabled }
    Invoke-SettingsButton $settings 'Save'
    $pair = 'theme = light:' + $dayTheme + ',dark:"' + $nightTheme + '"'
    $savedTheme = [IO.File]::ReadAllText($sidecar)
    Assert-True ($savedTheme -cmatch ('(?m)^' + [regex]::Escape($pair) + '\r?$')) 'The selected theme pair did not persist.'
    Assert-TerminalThemePixel $terminal $terminalWindow 0x172940
    $themeTerminal = [Diagnostics.Process]::Start($start)
    $null = $themeTerminal.StandardOutput.ReadToEndAsync()
    $null = $themeTerminal.StandardError.ReadToEndAsync()
    $themeWindow = Wait-For 'a new terminal using the dark theme' {
        if ($themeTerminal.HasExited) { throw "Theme test terminal exited with $($themeTerminal.ExitCode)." }
        $window = [SettingsSmokeWindows]::FindVisible($themeTerminal.Id, 'GhosttyWindow', '')
        if ($window -ne [IntPtr]::Zero) { $window }
    }
    Assert-TerminalThemePixel $themeTerminal $themeWindow 0x172940
    [SettingsSmokeWindows]::PostOwned($themeWindow, $themeTerminal.Id, 0x0010, 0)
    $null = Wait-For 'the new theme test terminal to close' { $themeTerminal.HasExited }

    $settings = Open-Settings
    $windowTheme = Wait-For 'the window theme dropdown' { Find-Control $settings.Root 'window-theme' }
    Assert-True ((Get-TerminalThemeEdit $settings 'terminal-theme-light').Current.Value -ceq $dayTheme) 'The light terminal theme did not reopen.'
    Assert-True ((Get-TerminalThemeEdit $settings 'terminal-theme-dark').Current.Value -ceq $nightTheme) 'The dark terminal theme did not reopen.'
    Select-ComboOption $settings $windowTheme 'Light'
    Invoke-SettingsButton $settings 'Save'
    Assert-TerminalThemePixel $terminal $terminalWindow 0xedebe2
    Assert-True ([IO.File]::ReadAllText($mainConfig) -ceq $expectedMainConfig) 'Theme settings changed unrelated config text.'
    Write-Output 'PASS: Custom light/dark themes save and reopen, startup follows Dark, and switching to Light updates terminal pixels.'

    $settings = Open-Settings
    Select-SettingsPage $settings 'settings-tabs' 'progress-style'
    $progress = Find-Control $settings.Root 'progress-style'
    Assert-True ($progress.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq
        [System.Windows.Automation.ToggleState]::Off) 'The progress switch did not reopen as disabled.'
    Select-SettingsPage $settings 'settings-startup' 'windows-default-profile'
    Select-ComboOption $settings (Find-Control $settings.Root 'windows-default-profile') 'Smoke test shell'
    Select-SettingsPage $settings 'settings-terminal' 'cursor-style'
    Select-ComboOption $settings (Find-Control $settings.Root 'cursor-style') 'Hollow block'
    $rightClick = Wait-For 'the right-click action dropdown' { Find-Control $settings.Root 'right-click-action' }
    Select-ComboOption $settings $rightClick 'Copy'
    $copy = Wait-For 'the copy-on-select toggle' { Find-Control $settings.Root 'copy-on-select' }
    $copy.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Test-PrivacyPage $settings -Change
    Invoke-SettingsButton $settings 'Save'
    $savedText = [IO.File]::ReadAllText($sidecar)
    Assert-True ($savedText -match ('(?m)^windows-default-profile = .*' + [regex]::Escape($profileGuid.Trim('{}')))) 'The selected profile ID did not persist.'
    foreach ($line in @('cursor-style = block_hollow', 'right-click-action = copy', 'copy-on-select = clipboard')) {
        Assert-True ($savedText -cmatch ('(?m)^' + [regex]::Escape($line) + '\r?$')) "Terminal setting did not save: $line"
    }
    Write-Output 'PASS: Cursor, copy and mouse settings save as Ghostty config keys.'
    foreach ($line in @(
        'clipboard-read = deny',
        'clipboard-write = ask',
        'clipboard-paste-protection = false',
        'link-url = false',
        'desktop-notifications = false'
    )) {
        Assert-True ($savedText -cmatch ('(?m)^' + [regex]::Escape($line) + '\r?$')) "Privacy setting did not save: $line"
    }
    $settings = Open-Settings
    Test-PrivacyPage $settings -Saved -Change
    Invoke-SettingsButton $settings 'Cancel'
    Assert-True ([IO.File]::ReadAllText($sidecar) -ceq $savedText) 'Cancel changed the saved privacy settings.'
    Assert-True ([IO.File]::ReadAllText($mainConfig) -ceq $expectedMainConfig) 'Privacy settings changed unrelated config text.'
    Write-Output 'PASS: Privacy settings save and reopen as Ghostty config keys, and Cancel preserves the saved configuration.'

    $profileTerminal = [Diagnostics.Process]::Start($start)
    $null = $profileTerminal.StandardOutput.ReadToEndAsync()
    $null = $profileTerminal.StandardError.ReadToEndAsync()
    $null = Wait-For 'the configured Windows Terminal profile to start' { [IO.File]::Exists($profileMarker) }
    Write-Output 'PASS: The GUI saves an imported profile and ordinary startup runs it.'

    [IO.File]::WriteAllText($explicitScript, '[IO.File]::WriteAllText($env:MADOTTY_TEST_PROFILE_MARKER, "explicit")')
    $start.Arguments = '-e "' + (Join-Path $PSHOME 'powershell.exe') + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $explicitScript + '"'
    $start.EnvironmentVariables['MADOTTY_TEST_PROFILE_MARKER'] = $explicitMarker
    $explicitTerminal = [Diagnostics.Process]::Start($start)
    $null = $explicitTerminal.StandardOutput.ReadToEndAsync()
    $null = $explicitTerminal.StandardError.ReadToEndAsync()
    $null = Wait-For 'the explicit command to start' { [IO.File]::Exists($explicitMarker) }
    Assert-True ([IO.File]::ReadAllText($explicitMarker) -ceq 'explicit') 'A default profile overrode -e.'
    Write-Output 'PASS: An explicit -e command takes precedence over the saved startup profile.'
    if (-not $supportsSystemBackdrop) { Write-Output 'SKIP: querying system backdrop needs Windows build 22621 or newer.' }
} catch {
    $failed = $true
    throw
} finally {
    if ($themeTerminal -and -not $themeTerminal.HasExited -and $themeWindow -ne [IntPtr]::Zero) {
        try { [SettingsSmokeWindows]::PostOwned($themeWindow, $themeTerminal.Id, 0x0010, 0) } catch { }
    }
    foreach ($started in @($themeTerminal, $profileTerminal, $explicitTerminal)) {
        if (-not $started) { continue }
        if (-not $started.HasExited -and -not $started.WaitForExit(3000)) {
            $started.Kill()
            $null = $started.WaitForExit(2000)
        }
        $started.Dispose()
    }
    foreach ($process in $settingsProcesses.Values) {
        if (-not $process.HasExited) {
            $window = Find-SettingsWindow { param($title) [SettingsSmokeWindows]::FindVisible($process.Id, '', $title) }
            if ($window -ne [IntPtr]::Zero) {
                try { [SettingsSmokeWindows]::PostOwned($window, $process.Id, 0x0010, 0) } catch { }
            }
            if (-not $process.WaitForExit(1500)) { $process.Kill() }
        }
        $process.Dispose()
    }
    if ($terminal) {
        if (-not $terminal.HasExited) {
            if ($terminalWindow -ne [IntPtr]::Zero) {
                try { [SettingsSmokeWindows]::PostOwned($terminalWindow, $terminal.Id, 0x0010, 0) } catch { }
            }
            if (-not $terminal.WaitForExit(2000)) {
                & taskkill.exe /PID $terminal.Id /T /F 2>$null | Out-Null
                $null = $terminal.WaitForExit(2000)
            }
        }
        $terminal.Dispose()
        if ($failed -and $terminalError -and $terminalError.Wait(1000)) {
            $terminalError.Result | Write-Host
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath
        if ($resolvedRoot -eq $testRoot -and (Split-Path -Parent $resolvedRoot).TrimEnd('\') -eq $temp.TrimEnd('\')) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        }
    }
}
