param(
    [Parameter(Mandatory)][string]$ExePath,
    [ValidateSet('opengl', 'd3d12', 'vulkan', 'both')][string]$Renderer = 'both'
)

# Use a local build with its settings companion. UI Automation, window
# messages, and frame capture target only processes started by the test.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'settings_uia.ps1')
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class ShaderSettingsWindows {
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct BitmapInfo {
        public uint Size;
        public int Width, Height;
        public ushort Planes, Bits;
        public uint Compression, SizeImage;
        public int DpiX, DpiY;
        public uint ColorsUsed, ImportantColors;
    }
    delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", SetLastError = true)] static extern bool PostMessage(IntPtr window, uint message, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr target, uint flags);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr data, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();
    [DllImport("dwmapi.dll")] static extern int DwmFlush();

    static bool Owns(IntPtr window, int pid) {
        uint actual;
        return window != IntPtr.Zero && GetWindowThreadProcessId(window, out actual) != 0 && actual == (uint)pid;
    }
    public static IntPtr Find(int pid, string cls, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, parameter) => {
            if (!Owns(window, pid) || !IsWindowVisible(window)) return true;
            var text = new StringBuilder(256);
            if (!String.IsNullOrEmpty(cls) && (GetClassName(window, text, text.Capacity) == 0 || text.ToString() != cls)) return true;
            if (!String.IsNullOrEmpty(title) && (GetWindowText(window, text, text.Capacity) == 0 || text.ToString() != title)) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }
    public static void PostOwned(IntPtr window, int pid, uint message, int value) {
        if (!Owns(window, pid)) throw new InvalidOperationException("Message target is outside the test process.");
        if (!PostMessage(window, message, new IntPtr(value), IntPtr.Zero)) throw new Win32Exception();
    }
    public static int[] Enlarge(IntPtr window, int pid) {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect rect;
            if (!Owns(window, pid) || !GetWindowRect(window, out rect))
                throw new InvalidOperationException("Resize target is outside the test process.");
            int width = rect.Right - rect.Left + 96, height = rect.Bottom - rect.Top + 64;
            const uint noMoveNoZOrderNoActivate = 0x16;
            if (!SetWindowPos(window, IntPtr.Zero, 0, 0, width, height, noMoveNoZOrderNoActivate))
                throw new Win32Exception();
            return new[] { width, height };
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }

    public static int[] FrameColors(IntPtr window, int pid) {
        Rect rect;
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            if (!Owns(window, pid) || !GetWindowRect(window, out rect))
                throw new InvalidOperationException("Capture target is outside the test process.");
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            if (width < 200 || height < 200) return new int[8];
            IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
            if (dc == IntPtr.Zero) throw new InvalidOperationException("CreateCompatibleDC failed.");
            try {
                var info = new BitmapInfo { Size = 40, Width = width, Height = -height, Planes = 1, Bits = 32 };
                IntPtr data;
                IntPtr dib = CreateDIBSection(dc, ref info, 0, out data, IntPtr.Zero, 0);
                if (dib == IntPtr.Zero) throw new InvalidOperationException("CreateDIBSection failed.");
                IntPtr previous = SelectObject(dc, dib);
                try {
                    DwmFlush();
                    if (!PrintWindow(window, dc, 2)) return new int[8];
                    GdiFlush();
                    int[] pixels = new int[width * height];
                    Marshal.Copy(data, pixels, 0, pixels.Length);
                    int[] counts = new int[8];
                    for (int y = height / 5; y < height * 4 / 5; y += 2) {
                        for (int x = width * 3 / 5; x < width * 9 / 10; x += 2) {
                            int rgb = pixels[y * width + x] & 0xffffff;
                            if (rgb == 0xff0000) counts[0]++;
                            if (rgb == 0x0000ff) counts[1]++;
                            if (rgb == 0x443122) counts[3]++;
                            if (rgb == 0x223144) counts[4]++;
                        }
                    }
                    for (int y = height / 15; y < height / 3; y += 2) {
                        for (int x = width / 35; x < width / 3; x += 2) {
                            if ((pixels[y * width + x] & 0xffffff) == 0xfb21fb) counts[2]++;
                        }
                    }
                    counts[5] = pixels[(height / 2) * width + width - 24] & 0xffffff;
                    counts[6] = width;
                    counts[7] = height;
                    return counts;
                } finally { SelectObject(dc, previous); DeleteObject(dib); }
            } finally { DeleteDC(dc); }
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }
}
'@

function Assert-True($condition, [string]$description) {
    if (-not $condition) { throw $description }
}

function Wait-Result([string]$description, [scriptblock]$check) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $result = & $check
            if ($result) { return $result }
        } catch [System.Windows.Automation.ElementNotAvailableException] {
            # Opening settings and moving a list row can rebuild the automation tree.
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt 20)
    throw "Timed out waiting for $description."
}

function Get-OwnedChild($parent, [string]$path) {
    $leaf = Split-Path -Leaf $path
    $filter = "ParentProcessId = $($parent.Id) AND Name = '$leaf'"
    foreach ($entry in Get-CimInstance Win32_Process -Filter $filter) {
        if ($entry.ExecutablePath -ine $path) { continue }
        $id = [int]$entry.ProcessId
        if ($children.ContainsKey($id)) { return $children[$id] }
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        try { $null = $process.Handle }
        catch { $process.Dispose(); continue }
        $children.Add($id, $process)
        return $process
    }
}

function Find-Control($root, [string]$id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Invoke-Control($control) {
    $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Open-Settings($terminal) {
    [ShaderSettingsWindows]::PostOwned($terminal.Window, $terminal.Process.Id, 0x0112, 0x1FD0)
    $null = Wait-Result 'the shader settings page tab' {
        $process = Get-OwnedChild $terminal.Process $settingsPath
        if (-not $process -or $process.HasExited) { return }
        $window = Find-SettingsWindow { param($title) [ShaderSettingsWindows]::Find($process.Id, $null, $title) }
        if ($window -eq [IntPtr]::Zero) { return }
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
        $tab = Find-Control $root 'settings-graphics'
        if ($tab) {
            $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            return $true
        }
    }
    return Wait-Result 'shader settings controls' {
        $process = Get-OwnedChild $terminal.Process $settingsPath
        if (-not $process -or $process.HasExited) { return }
        $window = Find-SettingsWindow { param($title) [ShaderSettingsWindows]::Find($process.Id, $null, $title) }
        if ($window -eq [IntPtr]::Zero) { return }
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
        if ($root.Current.ProcessId -ne $process.Id) { return }
        $list = Find-Control $root 'shader-list'
        $save = Find-Control $root 'save-settings'
        if ($list -and $save) { return @{ Process = $process; Root = $root; List = $list; Save = $save } }
    }
}

function Get-ShaderRows($settings) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    foreach ($row in $settings.List.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) { $row }
}

function Select-ShaderRow($settings, [string]$leaf) {
    $row = Wait-Result "the shader list row containing '$leaf'" {
        Get-ShaderRows $settings | Where-Object { $_.Current.Name -like "*$leaf*" } | Select-Object -First 1
    }
    $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}

function Assert-ShaderOrder($settings, [string]$first, [string]$second) {
    $null = Wait-Result "shader order $first, $second" {
        $rows = @(Get-ShaderRows $settings)
        $rows.Count -eq 2 -and $rows[0].Current.Name -like "*$first*" -and $rows[1].Current.Name -like "*$second*"
    }
}

function Set-Gain($settings, [double]$old, [double]$value) {
    $number = Wait-Result 'the annotated Gain control' { Find-Control $settings.Root 'shader-parameter-GAIN' }
    $editType = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $edit = if ($number.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit) { $number } else {
        $number.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editType)
    }
    Assert-True ($null -ne $edit) 'Gain does not expose an editable value.'
    $culture = [Globalization.CultureInfo]::CurrentCulture
    $editValue = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    Assert-True ([Math]::Abs([double]::Parse($editValue.Current.Value, $culture) - $old) -lt 0.001) "Gain should open at $old."
    $edit.SetFocus()
    $editValue.SetValue($value.ToString('G', $culture))
    $animation = Find-Control $settings.Root 'shader-animation'
    $animation.SetFocus() # NumberBox commits text when its owned editor loses focus.
}

function Select-Animation($settings, [string]$name) {
    $combo = Wait-Result 'the shader animation setting' { Find-Control $settings.Root 'shader-animation' }
    $expand = $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    $optionName = New-SettingsNameCondition $name
    $optionType = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $option = [System.Windows.Automation.AndCondition]::new($optionName, $optionType)
    $processCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $settings.Process.Id)
    $item = Wait-Result "the '$name' shader animation option" {
        $candidate = $settings.Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $option)
        if ($candidate -and $candidate.Current.ProcessId -eq $settings.Process.Id) { return $candidate }
        $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $processCondition)
        foreach ($root in $roots) {
            $candidate = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $option)
            if ($candidate -and $candidate.Current.ProcessId -eq $settings.Process.Id) { return $candidate }
        }
    }
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    if ($expand.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $expand.Collapse() }
}

function Save-Settings($settings) {
    $null = Wait-Result 'the shader settings save button' { $settings.Save.Current.IsEnabled }
    Invoke-Control $settings.Save
    Assert-True ($settings.Process.WaitForExit(15000) -and $settings.Process.ExitCode -eq 0) 'The shader settings dialog did not acknowledge Save.'
}

function Assert-Frame($terminal, [string]$phase,
    [ValidateSet('red', 'blue', 'swapped background', 'original background')][string]$color, [int[]]$size) {
    $index = @{ red = 0; blue = 1; 'swapped background' = 3; 'original background' = 4 }[$color]
    $expectedColor = @{ red = 0xff0000; blue = 0x0000ff; 'swapped background' = 0x443122; 'original background' = 0x223144 }[$color]
    $counts = Wait-Result "$phase $color pixels in the owned terminal" {
        if ($terminal.Process.HasExited) { throw "The terminal exited with code $($terminal.Process.ExitCode)." }
        $pixels = [ShaderSettingsWindows]::FrameColors($terminal.Window, $terminal.Process.Id)
        if ($pixels[$index] -gt 1500 -and $pixels[2] -gt 50 -and
            (-not $size -or ($pixels[6] -eq $size[0] -and $pixels[7] -eq $size[1] -and $pixels[5] -eq $expectedColor))) {
            return @{ Effect = $pixels[$index]; Glyph = $pixels[2]; Extent = "$($pixels[6])x$($pixels[7])" }
        }
    }
    Write-Output "PASS $phase renders $color ($($counts.Effect) effect samples, $($counts.Glyph) unchanged glyph samples, $($counts.Extent))."
}

function Read-AnimationColor($terminal) {
    if ($terminal.Process.HasExited) { throw "The terminal exited with code $($terminal.Process.ExitCode)." }
    $pixels = [ShaderSettingsWindows]::FrameColors($terminal.Window, $terminal.Process.Id)
    if ($pixels[2] -gt 50) {
        if ($pixels[0] -gt 1500) { return 'red' }
        if ($pixels[1] -gt 1500) { return 'blue' }
    }
}

function Read-Sidecar([string]$path, [string]$key) {
    if (-not [IO.File]::Exists($path)) { return }
    $prefix = '^\s*' + [regex]::Escape($key) + '\s*=\s*(.*?)\s*$'
    foreach ($line in [IO.File]::ReadLines($path)) {
        if ($line -cmatch $prefix) { $Matches[1] }
    }
}

function Assert-Override($path, [int]$pass) {
    $values = @(Read-Sidecar $path 'custom-shader-parameter' | Where-Object { $_ -ne '' })
    $expected = '\A' + $pass + ':GAIN:0\.75(?:0+)?\z'
    Assert-True ($values.Count -eq 1 -and $values[0] -cmatch $expected) "Gain was not stored on shader pass $pass."
}

function Close-OwnedProcess($process) {
    if ($process.HasExited) { return }
    $window = [ShaderSettingsWindows]::Find($process.Id, 'GhosttyWindow', $null)
    if ($window -eq [IntPtr]::Zero) { $window = Find-SettingsWindow { param($title) [ShaderSettingsWindows]::Find($process.Id, $null, $title) } }
    if ($window -ne [IntPtr]::Zero) {
        try { [ShaderSettingsWindows]::PostOwned($window, $process.Id, 0x0010, 0) } catch { }
    }
    if (-not $process.WaitForExit(2000)) {
        & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
        $null = $process.WaitForExit(2000)
    }
}

function Start-ShaderTerminal([string]$mode, [string]$root, [string]$title) {
    $sibling = $secondaries[$mode]
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.WorkingDirectory = $testRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $root
    $start.EnvironmentVariables['XDG_STATE_HOME'] = $root
    $start.EnvironmentVariables.Remove('GHOSTTY_RESOURCES_DIR')
    $start.EnvironmentVariables.Remove('MADOTTY_RENDERER_HANDOFF')
    $launcher = [Diagnostics.Process]::Start($start)
    $null = $launcher.Handle
    $null = $launcher.StandardOutput.ReadToEndAsync()
    $run = @{ Process = $launcher; Error = $launcher.StandardError.ReadToEndAsync(); Sibling = $sibling }
    $runs.Add($run)
    return Wait-Result "$mode terminal" {
        $owner = if ($sibling) { Get-OwnedChild $launcher $sibling } else { $launcher }
        if (-not $owner -or $owner.HasExited) { return }
        $window = [ShaderSettingsWindows]::Find($owner.Id, 'GhosttyWindow', $title)
        if ($window -ne [IntPtr]::Zero) { return @{ Process = $owner; Window = $window; Run = $run } }
    }
}

function Start-VulkanShaderCase([string]$name, [string]$source, [string]$baseConfig, [string]$shellTemplate, [switch]$MissingOptional) {
    $caseRoot = Join-Path $testRoot ('vulkan-' + $name)
    $configDir = Join-Path $caseRoot 'ghostty'
    [void][IO.Directory]::CreateDirectory($configDir)
    $shader = Join-Path $caseRoot ($name + '.glsl')
    if (-not $MissingOptional) { [IO.File]::WriteAllText($shader, $source, $utf8) }
    $shaderEntry = if ($MissingOptional) { '?' + $shader } else { $shader }
    $title = 'madotty-vulkan-shader-' + $name + '-' + [guid]::NewGuid().ToString('N')
    $shell = $shellTemplate.Replace('{{TITLE}}', $title)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($shell))
    $lines = @($baseConfig -split '\r?\n' | Where-Object { $_ -cnotmatch '^(custom-shader|custom-shader-animation|command)\s*=' })
    $lines += 'custom-shader = ' + $shaderEntry
    $lines += 'custom-shader-animation = false'
    $lines += 'command = powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded
    [IO.File]::WriteAllText((Join-Path $configDir 'config.ghostty'), ($lines -join [Environment]::NewLine), $utf8)
    return @{
        Terminal = Start-ShaderTerminal 'vulkan' $caseRoot $title
        Sidecar = Join-Path $configDir 'madotty-gui.ghostty'
        Shader = $shader
    }
}

$exe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$bin = Split-Path -Parent $exe
$settingsPath = Join-Path $bin 'settings\Madotty.Settings.exe'
$secondaries = @{
    d3d12 = Join-Path $bin 'ghostty-d3d12.exe'
    vulkan = Join-Path $bin 'ghostty-vulkan.exe'
}
Assert-True (-not $exe.StartsWith('\\') -and [IO.File]::Exists($settingsPath)) 'Use a local build with the settings companion.'
if ($Renderer -in @('d3d12', 'both')) {
    Assert-True ([IO.File]::Exists($secondaries.d3d12) -and [IO.File]::Exists((Join-Path $bin 'dxcompiler.dll')) -and
        [IO.File]::Exists((Join-Path $bin 'dxil.dll'))) 'The DirectX 12 case needs the paired renderer and DXC/DXIL runtime.'
}
if ($Renderer -eq 'vulkan') {
    Assert-True ([IO.File]::Exists($secondaries.vulkan)) 'The Vulkan case needs ghostty-vulkan.exe beside the primary ghostty.exe.'
}
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $temp ('madotty-shader-settings-' + [Guid]::NewGuid().ToString('N'))
$children = [Collections.Generic.Dictionary[int, Diagnostics.Process]]::new()
$runs = [Collections.Generic.List[object]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)
$failed = $false
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $parameterShader = Join-Path $testRoot 'gain.glsl'
    $swapShader = Join-Path $testRoot 'swap.glsl'
    $parameterSource = @'
#pragma parameter GAIN "Gain" 0.25 0 1 0.05
const float GAIN = 0.25;
void mainImage(out vec4 color, in vec2 pixel) {
    if (pixel.x < iResolution.x * 0.5) {
        color = texture(iChannel0, pixel / iResolution.xy);
    } else {
        color = GAIN < 0.5 ? vec4(1, 0, 0, 1) : vec4(0, 0, 1, 1);
    }
}
'@
    $swapSource = @'
void mainImage(out vec4 color, in vec2 pixel) {
    color = texture(iChannel0, pixel / iResolution.xy).bgra;
}
'@
    [IO.File]::WriteAllText($parameterShader, $parameterSource, $utf8)
    [IO.File]::WriteAllText($swapShader, $swapSource, $utf8)
    $parameterHash = (Get-FileHash -LiteralPath $parameterShader -Algorithm SHA256).Hash
    $swapHash = (Get-FileHash -LiteralPath $swapShader -Algorithm SHA256).Hash
    $modes = if ($Renderer -eq 'both') { @('opengl', 'd3d12') } else { @($Renderer) }
    foreach ($mode in $modes) {
        $root = Join-Path $testRoot $mode
        $configDir = Join-Path $root 'ghostty'
        [void][IO.Directory]::CreateDirectory($configDir)
        $config = Join-Path $configDir 'config.ghostty'
        $sidecar = Join-Path $configDir 'madotty-gui.ghostty'
        $title = 'madotty-shaders-' + [Guid]::NewGuid().ToString('N')
        $shellTemplate = @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$esc = [string][char]27
[Console]::Write($esc + '[?25l' + $esc + '[3;3H' + $esc + '[38;2;251;33;251m' +
    ([string][char]0x2588 * 18) + $esc + '[0m' + $esc + ']2;{{TITLE}}' + [char]7)
[Console]::Out.Flush()
while ($true) { Start-Sleep -Seconds 1 }
'@
        $shell = $shellTemplate.Replace('{{TITLE}}', $title)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($shell))
        $original = @(
            '# User comment and unrelated settings stay verbatim.',
            'cursor-style = bar',
            'background = #223144',
            'background-opacity = 1',
            'window-show-tab-bar = never',
            'alpha-blending = linear-corrected',
            ('windows-renderer = ' + $mode),
            ('custom-shader = ' + $parameterShader),
            ('custom-shader = ?' + $swapShader),
            'custom-shader-animation = true',
            ('command = powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded),
            'shell-integration = none',
            'confirm-close-surface = false',
            'window-save-state = never',
            'auto-update = off'
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($config, $original, $utf8)
        $terminal = Start-ShaderTerminal $mode $root $title
        Assert-Frame $terminal "$mode initial chain" 'blue'

        $settings = Open-Settings $terminal
        Assert-ShaderOrder $settings 'gain.glsl' 'swap.glsl'
        Select-ShaderRow $settings 'gain.glsl'
        Set-Gain $settings 0.25 0.75
        Select-Animation $settings 'When content changes'
        Save-Settings $settings
        Assert-Override $sidecar 1
        Assert-True ((Read-Sidecar $sidecar 'custom-shader-animation') -ceq 'false') 'Shader animation was not written to the managed config.'
        Assert-True (@(Read-Sidecar $sidecar 'custom-shader').Count -eq 0) 'Saving Gain unexpectedly rewrote the existing shader list.'
        Assert-Frame $terminal "$mode after saving Gain" 'red'
        if ($mode -eq 'vulkan') {
            $newSize = [ShaderSettingsWindows]::Enlarge($terminal.Window, $terminal.Process.Id)
            Assert-Frame $terminal 'vulkan chain at expanded window edge' 'red' $newSize
        }

        $settings = Open-Settings $terminal
        Assert-ShaderOrder $settings 'gain.glsl' 'swap.glsl'
        Select-ShaderRow $settings 'swap.glsl'
        $null = Wait-Result 'the shader without parameters to hide the Gain control' {
            -not (Find-Control $settings.Root 'shader-parameter-GAIN')
        }
        $move = Wait-Result 'the enabled move-up button' {
            $control = Find-Control $settings.Root 'shader-move-up'
            if ($control -and $control.Current.IsEnabled) { $control }
        }
        Invoke-Control $move
        Assert-ShaderOrder $settings 'swap.glsl' 'gain.glsl'
        Save-Settings $settings
        $newOrder = @(Read-Sidecar $sidecar 'custom-shader' | Where-Object { $_ -ne '' })
        Assert-True ($newOrder.Count -eq 2 -and $newOrder[0] -ieq ('?"' + $swapShader + '"') -and
            $newOrder[1] -ieq ('"' + $parameterShader + '"')) 'The saved shader order or optional flag changed unexpectedly.'
        Assert-Override $sidecar 2
        Assert-Frame $terminal "$mode after moving the pass" 'blue'

        $settings = Open-Settings $terminal
        Assert-ShaderOrder $settings 'swap.glsl' 'gain.glsl'
        Select-ShaderRow $settings 'gain.glsl'
        Invoke-Control (Find-Control $settings.Root 'shader-remove')
        $null = Wait-Result 'the remaining swap shader' {
            $rows = @(Get-ShaderRows $settings)
            $rows.Count -eq 1 -and $rows[0].Current.Name -like '*swap.glsl*'
        }
        Save-Settings $settings
        $remaining = @(Read-Sidecar $sidecar 'custom-shader' | Where-Object { $_ -ne '' })
        Assert-True ($remaining.Count -eq 1 -and $remaining[0] -ieq ('?"' + $swapShader + '"')) 'Removing Gain changed the remaining shader.'
        Assert-True (@(Read-Sidecar $sidecar 'custom-shader-parameter' | Where-Object { $_ -ne '' }).Count -eq 0) 'Removing Gain left an override active.'
        Assert-Frame $terminal "$mode after removing Gain" 'swapped background'

        $expected = $original + [Environment]::NewLine + 'config-file = ?madotty-gui.ghostty' + [Environment]::NewLine
        Assert-True ([IO.File]::ReadAllText($config) -ceq $expected) 'Shader settings changed unrelated user config.'
        Assert-True ((Get-FileHash -LiteralPath $parameterShader -Algorithm SHA256).Hash -eq $parameterHash -and
            (Get-FileHash -LiteralPath $swapShader -Algorithm SHA256).Hash -eq $swapHash) 'Shader settings changed the GLSL files.'
        Close-OwnedProcess $terminal.Process
        Write-Output "PASS $mode saved shader parameters, order, and animation without modifying GLSL."

        if ($mode -eq 'vulkan') {
            $run = $terminal.Run
            Assert-True ($run.Error.Wait(2000) -and $run.Error.Result -match 'renderer=[^\r\n]*Vulkan' -and
                $run.Error.Result -notmatch 'Vulkan frame failed|VK_ERROR_DEVICE_LOST|status=\.unhealthy') 'The Vulkan chain logged a renderer failure.'

            $invalidCase = Start-VulkanShaderCase 'invalid' 'void mainImage(out vec4 color, in vec2 pixel) { color = vec4(; }' $original $shellTemplate
            $invalidTerminal = $invalidCase.Terminal
            Assert-Frame $invalidTerminal 'vulkan after invalid shader' 'original background'
            Close-OwnedProcess $invalidTerminal.Process
            Assert-True ($invalidTerminal.Run.Error.Wait(2000) -and $invalidTerminal.Run.Error.Result -match 'renderer=[^\r\n]*Vulkan' -and
                $invalidTerminal.Run.Error.Result -match 'spirv error path=[^\r\n]*invalid\.glsl' -and
                $invalidTerminal.Run.Error.Result -notmatch 'Vulkan frame failed|VK_ERROR_DEVICE_LOST|status=\.unhealthy') 'The invalid GLSL case did not report an isolated shader compile failure.'

            $animatedSource = @'
void mainImage(out vec4 color, in vec2 pixel) {
    if (pixel.x < iResolution.x * 0.5) {
        color = texture(iChannel0, pixel / iResolution.xy);
    } else {
        color = mod(iTime, 0.8) < 0.4 ? vec4(1, 0, 0, 1) : vec4(0, 0, 1, 1);
    }
}
'@
            $animationCase = Start-VulkanShaderCase 'animation' $animatedSource $original $shellTemplate -MissingOptional
            $animatedTerminal = $animationCase.Terminal
            Assert-Frame $animatedTerminal 'vulkan before optional shader exists' 'original background'
            [IO.File]::WriteAllText($animationCase.Shader, $animatedSource, $utf8)
            $settings = Open-Settings $animatedTerminal
            Select-ShaderRow $settings 'animation.glsl'
            $optional = Find-Control $settings.Root 'shader-optional'
            $toggle = $optional.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            Assert-True ($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) 'The pending shader was not optional.'
            $toggle.Toggle()
            $null = Wait-Result 'the required shader option' {
                $toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::Off
            }
            Select-Animation $settings 'Always'
            Save-Settings $settings
            Assert-True ((Read-Sidecar $animationCase.Sidecar 'custom-shader-animation') -ceq 'always') 'Always was not saved to the managed config.'
            $required = @(Read-Sidecar $animationCase.Sidecar 'custom-shader' | Where-Object { $_ -ne '' })
            Assert-True ($required.Count -eq 1 -and $required[0] -ieq ('"' + $animationCase.Shader + '"')) 'The required animated shader was not saved.'
            $observed = @{ Last = $null; Changes = 0 }
            $null = Wait-Result 'two visible shader color transitions without shell output' {
                $sample = Read-AnimationColor $animatedTerminal
                if (-not $sample) { return }
                if ($observed.Last -and $observed.Last -ne $sample) { $observed.Changes++ }
                $observed.Last = $sample
                $observed.Changes -ge 2
            }
            Close-OwnedProcess $animatedTerminal.Process
            Assert-True ($animatedTerminal.Run.Error.Wait(2000) -and
                $animatedTerminal.Run.Error.Result -notmatch 'Vulkan frame failed|VK_ERROR_DEVICE_LOST|status=\.unhealthy') 'The animated Vulkan shader logged a renderer failure.'
            Write-Output 'PASS loading an animated Vulkan shader re-arms an idle terminal without new shell output.'
        }
    }
} catch {
    $failed = $true
    throw
} finally {
    foreach ($run in $runs) {
        if ($run.Sibling) {
            $rendererChild = Get-OwnedChild $run.Process $run.Sibling
            if ($rendererChild) { $null = Get-OwnedChild $rendererChild $settingsPath }
        }
        $null = Get-OwnedChild $run.Process $settingsPath
    }
    foreach ($process in $children.Values) {
        Close-OwnedProcess $process
        $process.Dispose()
    }
    foreach ($run in $runs) {
        Close-OwnedProcess $run.Process
        if ($failed -and $run.Error.Wait(1000)) {
            $run.Error.Result -split '\r?\n' | Where-Object { $_.Length -lt 800 } | Select-Object -Last 35 | Write-Host
        }
        $run.Process.Dispose()
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
        if ($resolved -eq $testRoot -and (Split-Path -Parent $resolved) -eq $temp) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
