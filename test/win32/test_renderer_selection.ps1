param(
    [Parameter(Mandatory)][string]$ExePath,
    [switch]$RequireVulkan,
    [switch]$TestVulkanDriverFailure
)

# Use a local build with at least one secondary backend. This test sends commands only to the
# windows created by the test and uses an independent config directory.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'settings_uia.ps1')
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class RendererTestWindows {
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
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr window, StringBuilder title, int capacity);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage,
                                                                  out IntPtr data, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();

    static bool Owns(IntPtr window, int pid) {
        uint actual;
        return window != IntPtr.Zero && GetWindowThreadProcessId(window, out actual) != 0 && actual == (uint)pid;
    }

    public static IntPtr Find(int pid, string windowClass, string windowTitle) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((window, parameter) => {
            if (!Owns(window, pid) || !IsWindowVisible(window)) return true;
            var text = new StringBuilder(256);
            if (!String.IsNullOrEmpty(windowClass) && (GetClassName(window, text, text.Capacity) == 0 || text.ToString() != windowClass))
                return true;
            if (!String.IsNullOrEmpty(windowTitle) && (GetWindowText(window, text, text.Capacity) == 0 || text.ToString() != windowTitle))
                return true;
            result = window;
            return false;
        }, IntPtr.Zero);
        return result;
    }

    public static void PostOwned(IntPtr window, int pid, uint message, int wParam) {
        if (!Owns(window, pid)) throw new InvalidOperationException("Message target is outside the test process.");
        if (!PostMessage(window, message, new IntPtr(wParam), IntPtr.Zero)) throw new Win32Exception();
    }

    public static bool HasFallbackPixels(IntPtr window, int pid) {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect rect;
            if (!Owns(window, pid) || !GetWindowRect(window, out rect))
                throw new InvalidOperationException("Capture target is outside the test process.");
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            if (width <= 0 || height <= 0) return false;
            IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
            if (dc == IntPtr.Zero) throw new InvalidOperationException("CreateCompatibleDC failed.");
            try {
                var info = new BitmapInfo { Size = 40, Width = width, Height = -height, Planes = 1, Bits = 32 };
                IntPtr data;
                IntPtr bitmap = CreateDIBSection(dc, ref info, 0, out data, IntPtr.Zero, 0);
                if (bitmap == IntPtr.Zero) throw new InvalidOperationException("CreateDIBSection failed.");
                IntPtr previous = SelectObject(dc, bitmap);
                try {
                    if (!PrintWindow(window, dc, 2)) return false;
                    GdiFlush();
                    var pixels = new int[checked(width * height)];
                    Marshal.Copy(data, pixels, 0, pixels.Length);
                    int count = 0;
                    foreach (int pixel in pixels)
                        if ((pixel & 0xffffff) == 0xfb21f7 && ++count >= 100) return true;
                    return false;
                } finally { SelectObject(dc, previous); DeleteObject(bitmap); }
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
        $result = & $check
        if ($result) { return $result }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt 20)
    throw "Timed out waiting for $description."
}

function Join-WindowsArguments([string[]]$arguments) {
    $quoted = foreach ($value in $arguments) {
        '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    return $quoted -join ' '
}

function Start-Fixture([string]$path, [string]$name, [string[]]$arguments = @(), [switch]$MissingVulkanDriver) {
    $state = Join-Path $testRoot $name
    [void][IO.Directory]::CreateDirectory($state)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $path
    $start.Arguments = Join-WindowsArguments $arguments
    $start.WorkingDirectory = $testRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $configRoot
    $start.EnvironmentVariables['XDG_STATE_HOME'] = $state
    $start.EnvironmentVariables['GHOSTTY_RESOURCES_DIR'] = $resources
    $start.EnvironmentVariables.Remove('MADOTTY_RENDERER_HANDOFF')
    $start.EnvironmentVariables['MADOTTY_RENDERER_TEST_STATE'] = $state
    $start.EnvironmentVariables['MADOTTY_RENDERER_TEST_TITLE'] = 'madotty-renderer-' + [guid]::NewGuid().ToString('N')
    $start.EnvironmentVariables.Remove('MADOTTY_RENDERER_TEST_PAINT')
    if ($MissingVulkanDriver) {
        # The Vulkan loader reads these only in the new process tree.
        $manifest = Join-Path $state 'nonexistent-driver.json'
        $start.EnvironmentVariables['VK_DRIVER_FILES'] = $manifest
        $start.EnvironmentVariables['VK_ICD_FILENAMES'] = $manifest
        $start.EnvironmentVariables.Remove('VK_ADD_DRIVER_FILES')
        $start.EnvironmentVariables['MADOTTY_RENDERER_TEST_PAINT'] = '1'
    }
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $run = @{
        Process = $process
        Title = $start.EnvironmentVariables['MADOTTY_RENDERER_TEST_TITLE']
        Directory = Split-Path -Parent $path
        State = $state
        Output = $process.StandardOutput.ReadToEndAsync()
        Error = $process.StandardError.ReadToEndAsync()
    }
    $runs.Add($run)
    return $run
}

function Get-OwnedChild($parent, [string]$path) {
    # Keep the parent's process handle across the readiness handoff. Its PID
    # remains associated with this launch even when the parent has exited.
    $name = Split-Path -Leaf $path
    $filter = "ParentProcessId = $($parent.Id) AND Name = '$name'"
    foreach ($entry in Get-CimInstance Win32_Process -Filter $filter) {
        if ($entry.ExecutablePath -ine $path) { continue }
        $id = [int]$entry.ProcessId
        if ($children.ContainsKey($id)) { return $children[$id] }
        $candidate = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -eq $candidate) { continue }
        try { $null = $candidate.Handle }
        catch { $candidate.Dispose(); continue }
        $children.Add($id, $candidate)
        return $candidate
    }
}

function Assert-NoRendererChild($run, [string]$description) {
    foreach ($backend in $backends) {
        $sibling = Join-Path $run.Directory $backend.Executable
        Assert-True (-not (Get-OwnedChild $run.Process $sibling)) "$description started $($backend.Label)."
    }
}

function Wait-Shell($run, $backend, [string[]]$expectedArgs) {
    $sibling = if ($backend) { Join-Path $run.Directory $backend.Executable }
    $terminal = Wait-Result "the '$($run.Title)' terminal and its command witness" {
        $owner = if ($backend) { Get-OwnedChild $run.Process $sibling } else { $run.Process }
        if (-not $owner -or $owner.HasExited) { return }
        $window = [RendererTestWindows]::Find($owner.Id, 'GhosttyWindow', $run.Title)
        if ($window -eq [IntPtr]::Zero) { return }
        $files = @(Get-ChildItem -LiteralPath $run.State -Filter 'shell-*.json' -File)
        Assert-True ($files.Count -le 1) 'A renderer launch started the terminal command more than once.'
        if ($files.Count -ne 1) { return }
        $witness = [IO.File]::ReadAllText($files[0].FullName) | ConvertFrom-Json
        return @{ Owner = $owner; Window = $window; Args = $witness.argv; Handoff = $witness.handoff }
    }
    $actual = ConvertTo-Json -Compress -InputObject @($terminal.Args)
    $expected = ConvertTo-Json -Compress -InputObject @($expectedArgs)
    Assert-True ($actual -ceq $expected) "Terminal command arguments changed. Expected $expected, got $actual."
    Assert-True ($null -eq $terminal.Handoff) 'The terminal command inherited the internal renderer handoff environment.'
    if ($backend) {
        Assert-True ([RendererTestWindows]::Find($run.Process.Id, 'GhosttyWindow', $null) -eq [IntPtr]::Zero) "The OpenGL launcher opened its own terminal during $($backend.Label) handoff."
        Assert-True ($run.Process.WaitForExit(5000) -and $run.Process.ExitCode -eq 0) 'The OpenGL launcher did not hand off successfully.'
    } else {
        Assert-NoRendererChild $run 'An OpenGL invocation unexpectedly'
    }
    $run.Terminal = $terminal
    return $terminal
}

function Find-Control($root, [string]$id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Open-GraphicsApi($terminal) {
    [RendererTestWindows]::PostOwned($terminal.Window, $terminal.Owner.Id, 0x0112, 0x1FD0)
    $null = Wait-Result 'the graphics settings page tab' {
        $process = Get-OwnedChild $terminal.Owner $settingsExe
        if (-not $process -or $process.HasExited) { return }
        $window = Find-SettingsWindow { param($title) [RendererTestWindows]::Find($process.Id, $null, $title) }
        if ($window -eq [IntPtr]::Zero) { return }
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
        $tab = Find-Control $root 'settings-graphics'
        if ($tab) {
            $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            return $true
        }
    }
    return Wait-Result 'the graphics API settings controls' {
        $process = Get-OwnedChild $terminal.Owner $settingsExe
        if (-not $process -or $process.HasExited) { return }
        $window = Find-SettingsWindow { param($title) [RendererTestWindows]::Find($process.Id, $null, $title) }
        if ($window -eq [IntPtr]::Zero) { return }
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
            if ($root.Current.ProcessId -ne $process.Id) { return }
            $combo = Find-Control $root 'windows-renderer'
            $save = Find-Control $root 'save-settings'
            $status = Find-Control $root 'windows-renderer-status'
            if ($combo -and $save -and ($status -or -not $vulkanAvailable)) {
                return @{ Process = $process; Root = $root; Combo = $combo; Save = $save; Status = $status }
            }
        } catch [System.Windows.Automation.ElementNotAvailableException] {
            # The window can replace its automation tree during startup.
        }
    }
}

function Assert-GraphicsApi($settings, [string]$preference, [string]$active) {
    $selection = $settings.Combo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    $selected = $selection.Current.GetSelection()
    Assert-True ($selected.Length -eq 1 -and $selected[0].Current.Name -cin @(Get-SettingsLabels $preference)) "Graphics API did not open with '$preference' selected."
    if ($settings.Status) {
        $statusText = $settings.Status.Current.Name
        Assert-True (@(Get-SettingsLabels 'Using {0} now.' @($active) | Where-Object { $statusText.StartsWith($_, [StringComparison]::Ordinal) }).Count -gt 0) "Unexpected graphics API status '$statusText'."
    }
}

function Save-GraphicsApi($terminal, [string]$initial, [string]$value, [string]$active) {
    $settings = Open-GraphicsApi $terminal
    Assert-GraphicsApi $settings $initial $active
    $selection = $settings.Combo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    $expand = $settings.Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    $itemName = New-SettingsNameCondition $value
    $itemType = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $itemCondition = [System.Windows.Automation.AndCondition]::new($itemName, $itemType)
    $processCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $settings.Process.Id)
    $item = Wait-Result "the '$value' graphics API option" {
        try {
            $candidate = $settings.Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $itemCondition)
            if ($candidate -and $candidate.Current.ProcessId -eq $settings.Process.Id) { return $candidate }
            $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Children, $processCondition)
            foreach ($root in $roots) {
                $candidate = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $itemCondition)
                if ($candidate -and $candidate.Current.ProcessId -eq $settings.Process.Id) { return $candidate }
            }
        } catch [System.Windows.Automation.ElementNotAvailableException] {
            # Retry as the popup becomes available to UI Automation.
        }
    }
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    if ($expand.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $expand.Collapse() }
    $null = Wait-Result 'the selected graphics API to be ready to save' {
        $current = $selection.Current.GetSelection()
        $current.Length -eq 1 -and $current[0].Current.Name -cin @(Get-SettingsLabels $value) -and $settings.Save.Current.IsEnabled
    }
    $settings.Save.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Assert-True ($settings.Process.WaitForExit(15000) -and $settings.Process.ExitCode -eq 0) 'The settings child did not acknowledge Save.'
}

function Close-OwnedProcess($process) {
    if ($process.HasExited) { return }
    $window = [RendererTestWindows]::Find($process.Id, 'GhosttyWindow', $null)
    if ($window -eq [IntPtr]::Zero) {
        $window = Find-SettingsWindow { param($title) [RendererTestWindows]::Find($process.Id, $null, $title) }
    }
    if ($window -ne [IntPtr]::Zero) {
        try { [RendererTestWindows]::PostOwned($window, $process.Id, 0x0010, 0) } catch { }
    }
    if (-not $process.WaitForExit(2000)) {
        & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
        $null = $process.WaitForExit(2500)
    }
}

function Test-RendererFallbacks($backend, [string[]]$arguments) {
    $fallbackDir = Join-Path $testRoot ("fallback-" + $backend.Key)
    [void][IO.Directory]::CreateDirectory($fallbackDir)
    foreach ($name in @('ghostty.exe', 'conpty.dll', 'OpenConsole.exe')) {
        Copy-Item -LiteralPath (Join-Path $bin $name) -Destination $fallbackDir
    }
    foreach ($name in @('dxcompiler.dll', 'dxil.dll')) {
        $library = Join-Path $bin $name
        if ([IO.File]::Exists($library)) { Copy-Item -LiteralPath $library -Destination $fallbackDir }
    }

    $primary = Join-Path $fallbackDir 'ghostty.exe'
    $sibling = Join-Path $fallbackDir $backend.Executable
    $key = $backend.Key
    $label = $backend.Label

    $fallback = Start-Fixture $primary "$key-missing-sibling"
    $terminal = Wait-Shell $fallback $null $arguments
    Close-OwnedProcess $terminal.Owner
    Write-Output "PASS: a single-renderer payload falls back to OpenGL with $label configured."

    # This exercises failed CreateProcess without starting a renderer.
    [IO.File]::WriteAllText($sibling, 'invalid executable fixture', $utf8)
    $invalid = Start-Fixture $primary "$key-invalid-sibling"
    $terminal = Wait-Shell $invalid $null $arguments
    Close-OwnedProcess $terminal.Owner
    Write-Output "PASS: an invalid $label executable falls back to OpenGL."

    Copy-Item -LiteralPath $primary -Destination $sibling -Force
    $wrong = Start-Fixture $primary "$key-opengl-sibling"
    $terminal = Wait-Shell $wrong $null $arguments
    Close-OwnedProcess $terminal.Owner
    Assert-True (@(Get-ChildItem -LiteralPath $wrong.State -Filter 'shell-*.json' -File).Count -eq 1) "A stale OpenGL file in place of the $label helper started a duplicate command."
    Write-Output "PASS: a stale OpenGL file in place of the $label helper rejects the handoff and fallback starts the command once."

    foreach ($other in $available) {
        if ($other.Key -eq $key) { continue }
        # Windows may briefly keep the image mapped after the helper exits.
        $null = Wait-Result 'the previous helper image to become writable' {
            try {
                [IO.File]::Copy((Join-Path $bin $other.Executable), $sibling, $true)
                return $true
            } catch [IO.IOException] {
                if (($_.Exception.GetBaseException().HResult -band 0xffff) -ne 32) { throw }
            }
        }
        $wrong = Start-Fixture $primary "$key-wrong-secondary"
        $terminal = Wait-Shell $wrong $null $arguments
        Close-OwnedProcess $terminal.Owner
        Assert-True (@(Get-ChildItem -LiteralPath $wrong.State -Filter 'shell-*.json' -File).Count -eq 1) "A $($other.Label) file in place of the $label helper started a duplicate command."
        Write-Output "PASS: $($other.Label) rejects a $label handoff and fallback starts the command once."
    }

    Assert-True ([IO.File]::ReadAllText($sidecarPath) -cmatch "\Awindows-renderer = $key(?:\r?\n)?\z") 'Falling back changed the saved renderer preference.'
}

function Test-VulkanDriverFallback([string[]]$arguments) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Output 'SKIP: the Vulkan loader ignores driver overrides in elevated processes.'
            return
        }
    } finally { $identity.Dispose() }

    $failedVulkan = Start-Fixture $exe 'vulkan-missing-driver' -MissingVulkanDriver
    $terminal = Wait-Shell $failedVulkan $null $arguments
    $null = Wait-Result 'painted OpenGL fallback after Vulkan initialization failure' {
        [RendererTestWindows]::HasFallbackPixels($terminal.Window, $terminal.Owner.Id)
    }
    $settings = Open-GraphicsApi $terminal
    Assert-GraphicsApi $settings 'Vulkan' 'OpenGL'
    Assert-True (@(Get-SettingsLabels '{0} could not start.' @('Vulkan') | Where-Object { $settings.Status.Current.Name.Contains($_) }).Count -gt 0) 'WinUI did not report the Vulkan startup failure.'
    Close-OwnedProcess $settings.Process
    Close-OwnedProcess $terminal.Owner

    Assert-True (@(Get-ChildItem -LiteralPath $failedVulkan.State -Filter 'shell-*.json' -File).Count -eq 1) 'Vulkan driver failure started a duplicate command.'
    Assert-True ($failedVulkan.Error.Wait(2000) -and
        $failedVulkan.Error.Result -match 'vkCreateInstance returned VkResult=-\d+' -and
        $failedVulkan.Error.Result -match 'vulkan startup failed, using OpenGL') 'The Vulkan driver override did not cause the expected Vulkan startup failure.'
    Assert-True ([IO.File]::ReadAllText($sidecarPath) -cmatch '\Awindows-renderer = vulkan(?:\r?\n)?\z') 'Vulkan driver failure changed the saved preference.'
    Write-Output 'PASS: Vulkan driver initialization failure renders through OpenGL and starts the configured command once.'
}

$exe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$bin = Split-Path -Parent $exe
Assert-True ((Split-Path -Leaf $exe) -ieq 'ghostty.exe' -and -not $bin.StartsWith('\\')) 'Use a local primary ghostty.exe.'
$backends = @(
    @{ Key = 'd3d12'; Label = 'DirectX 12'; Executable = 'ghostty-d3d12.exe' },
    @{ Key = 'vulkan'; Label = 'Vulkan'; Executable = 'ghostty-vulkan.exe' }
)
$available = @($backends | Where-Object { [IO.File]::Exists((Join-Path $bin $_.Executable)) })
$vulkanAvailable = [IO.File]::Exists((Join-Path $bin 'ghostty-vulkan.exe'))
Assert-True ($available.Count -gt 0) 'The build must include at least one renderer companion.'
Assert-True (-not ($RequireVulkan -or $TestVulkanDriverFailure) -or $vulkanAvailable) 'The required Vulkan companion ghostty-vulkan.exe is missing.'
$cli = Join-Path $bin 'ghostty.com'
$settingsExe = Join-Path $bin 'settings\Madotty.Settings.exe'
foreach ($path in @($cli, $settingsExe)) {
    Assert-True ([IO.File]::Exists($path)) "Required paired payload is missing $path."
}
$resources = foreach ($dir in @($bin, (Split-Path -Parent $bin))) {
    if ([IO.File]::Exists((Join-Path $dir 'share\terminfo\ghostty.terminfo'))) {
        Join-Path $dir 'share\ghostty'
        break
    }
}
Assert-True ($null -ne $resources) 'The matching terminal resources are missing.'

$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $temp ('madotty-renderer-test-' + [guid]::NewGuid().ToString('N'))
$configRoot = Join-Path $testRoot 'config'
$configDir = Join-Path $configRoot 'ghostty'
$configPath = Join-Path $configDir 'config.ghostty'
$sidecarPath = Join-Path $configDir 'madotty-gui.ghostty'
$witnessPath = Join-Path $testRoot 'shell witness.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shellArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $witnessPath)
$runs = [Collections.Generic.List[object]]::new()
$children = [Collections.Generic.Dictionary[int, Diagnostics.Process]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)
$failed = $false
try {
    [void][IO.Directory]::CreateDirectory($configDir)
    @'
$commandLine = [Environment]::GetCommandLineArgs()
$index = [Array]::IndexOf($commandLine, $PSCommandPath)
if ($index -lt 0) { throw 'The fixture script was missing in the shell command line.' }
$argv = @($commandLine | Select-Object -Skip ($index + 1))
$state = Join-Path $env:MADOTTY_RENDERER_TEST_STATE "shell-$PID.json"
$handoff = [Environment]::GetEnvironmentVariable('MADOTTY_RENDERER_HANDOFF')
[IO.File]::WriteAllText($state + '.tmp', (ConvertTo-Json -Compress -InputObject @{ argv = $argv; handoff = $handoff }))
[IO.File]::Move($state + '.tmp', $state)
$esc = [string][char]27
if ($env:MADOTTY_RENDERER_TEST_PAINT -eq '1') {
    [Console]::Write($esc + '[1;1H' + $esc + '[48;2;251;33;247m' + (' ' * 18) + $esc + '[0m')
}
[Console]::Write($esc + ']2;' + $env:MADOTTY_RENDERER_TEST_TITLE + [char]7)
while ($true) { Start-Sleep -Seconds 1 }
'@ | Set-Content -Encoding Ascii -LiteralPath $witnessPath
    $configuredArgs = @('configured')
    $command = (Join-WindowsArguments (@($powershell) + $shellArguments)) + ' configured'
    $original = @(
        '# Keep the existing config text.',
        'windows-renderer = auto',
        ('command = ' + $command),
        'shell-integration = none',
        'confirm-close-surface = false',
        'window-save-state = never',
        'quit-after-last-window-closed = true',
        'auto-update = off'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($configPath, $original, $utf8)

    $auto = Start-Fixture $exe 'auto'
    $sourceTerminal = Wait-Shell $auto $null $configuredArgs
    $sourceRun = $auto
    $sourceSelection = 'Automatic'
    $sourceRenderer = 'OpenGL'
    $expectedConfig = $original + [Environment]::NewLine + 'config-file = ?madotty-gui.ghostty' + [Environment]::NewLine
    $raw = @('two words', '', 'embedded "quotes"', 'C:\folder with spaces\', '+version', '--windows-renderer=opengl',
        '-Embedding', '/Embedding', 'A&B|C')
    $executeArgs = @('-e', $powershell) + $shellArguments + $raw

    foreach ($backend in $available) {
        $key = $backend.Key
        $label = $backend.Label
        Save-GraphicsApi $sourceTerminal $sourceSelection $label $sourceRenderer
        Assert-True ([IO.File]::ReadAllText($sidecarPath) -cmatch "\Awindows-renderer = $key(?:\r?\n)?\z") 'Save did not persist exactly the renderer selection.'
        Assert-True ([IO.File]::ReadAllText($configPath) -ceq $expectedConfig) 'Save changed unrelated config text.'
        Assert-True (-not $sourceTerminal.Owner.HasExited -and
            [RendererTestWindows]::Find($sourceTerminal.Owner.Id, 'GhosttyWindow', $sourceRun.Title) -eq $sourceTerminal.Window) "Saving changed or closed the running $sourceRenderer terminal."
        foreach ($candidate in $backends) {
            $sibling = Join-Path $bin $candidate.Executable
            Assert-True (-not (Get-OwnedChild $sourceTerminal.Owner $sibling)) "Saving started $($candidate.Label) in the running session."
        }
        Write-Output "PASS: saving $label leaves the running $sourceRenderer terminal in place."
        Close-OwnedProcess $sourceTerminal.Owner

        $next = Start-Fixture $exe "$key-next-launch"
        $sourceTerminal = Wait-Shell $next $backend $configuredArgs
        $sourceRun = $next
        $sourceSelection = $label
        $sourceRenderer = $label
        $currentSettings = Open-GraphicsApi $sourceTerminal
        Assert-GraphicsApi $currentSettings $label $label
        Close-OwnedProcess $currentSettings.Process
        Write-Output "PASS: the next primary launch hands off to $label before starting the configured command."

        $execute = Start-Fixture $exe "$key-execute" $executeArgs
        $execTerminal = Wait-Shell $execute $backend $raw
        Close-OwnedProcess $execTerminal.Owner
        Write-Output "PASS: $label handoff preserves quoted, empty, and option-like arguments after -e."

        foreach ($entryPoint in @($cli, $exe)) {
            $cliRun = Start-Fixture $entryPoint "$key-version-$(Split-Path -Leaf $entryPoint)" @('+version')
            Assert-True ($cliRun.Process.WaitForExit(10000) -and $cliRun.Process.ExitCode -eq 0) 'The CLI version action did not complete successfully.'
            Assert-True ($cliRun.Output.Wait(2000) -and $cliRun.Output.Result -match '(?im)renderer\s*:\s*[^\r\n]*OpenGL') "The CLI renderer report changed when $label was selected."
            Assert-NoRendererChild $cliRun 'A CLI action unexpectedly'
        }
        Write-Output "PASS: both executable entry points preserve the CLI action with $label configured."

        Test-RendererFallbacks $backend $configuredArgs
        if ($key -eq 'vulkan' -and $TestVulkanDriverFailure) { Test-VulkanDriverFallback $configuredArgs }
    }
    Close-OwnedProcess $sourceTerminal.Owner
} catch {
    $failed = $true
    throw
} finally {
    foreach ($run in $runs) {
        # Discover a helper even if the test failed before it was ready.
        foreach ($backend in $backends) {
            $null = Get-OwnedChild $run.Process (Join-Path $run.Directory $backend.Executable)
        }
    }
    foreach ($process in $children.Values) {
        Close-OwnedProcess $process
        $process.Dispose()
    }
    foreach ($run in $runs) {
        Close-OwnedProcess $run.Process
        if ($failed -and $run.Error.Wait(1000)) { $run.Error.Result | Write-Host }
        $run.Process.Dispose()
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
        if ($resolved -eq $testRoot -and (Split-Path -Parent $resolved) -eq $temp) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
