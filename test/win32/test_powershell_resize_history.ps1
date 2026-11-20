param(
    [Parameter(Mandatory)][string]$ExePath,
    [string]$Shell = 'powershell.exe',
    [string]$IntegrationPath
)

# Post messages only to the terminal owned by this test process. The dump
# action pastes into the controlled child, so it does not touch the clipboard.
$ErrorActionPreference = 'Stop'
if (!$IntegrationPath) {
    $IntegrationPath = Join-Path $PSScriptRoot '../../src/shell-integration/powershell/ghostty-shell-integration.ps1'
}
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class PowerShellResize {
    delegate bool WindowCallback(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr top, WindowCallback callback, IntPtr param);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder buffer, int size);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    static bool IsOwner(IntPtr hwnd, int expected) {
        uint pid;
        return hwnd != IntPtr.Zero && GetWindowThreadProcessId(hwnd, out pid) != 0 && pid == (uint)expected;
    }
    public static IntPtr Pane(IntPtr top, int pid) {
        if (!IsOwner(top, pid)) return IntPtr.Zero;
        IntPtr result = IntPtr.Zero;
        EnumChildWindows(top, delegate(IntPtr hwnd, IntPtr param) {
            var name = new StringBuilder(128);
            GetClassName(hwnd, name, name.Capacity);
            if (IsOwner(hwnd, pid) && name.ToString() == "GhosttyTerminal") { result = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
    public static void Key(IntPtr pane, int pid, int vk) {
        if (!IsOwner(pane, pid)) throw new Exception("Test terminal closed");
        if (!PostMessage(pane, 0x100, new IntPtr(vk), new IntPtr(1)) ||
            !PostMessage(pane, 0x101, new IntPtr(vk), new IntPtr(unchecked((int)0xc0000001))))
            throw new Win32Exception();
    }
    public static void Resize(IntPtr top, int pid) {
        if (!IsOwner(top, pid)) throw new Exception("Test window closed");
        if (!SetWindowPos(top, IntPtr.Zero, 0, 0, 640, 340, 0x16)) throw new Win32Exception();
    }
}
'@
function Wait-For($condition, $description) {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $result = & $condition
        if ($result) { return $result }
        if ($process.HasExited) { throw "Terminal exited during $description" }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "Timeout waiting for $description"
}
$work = Join-Path $env:TEMP ('ghostty-resize-history-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $work
$child = @'
$ErrorActionPreference = 'Stop'
1..45 | ForEach-Object { [Console]::WriteLine(('HISTORY-{0:D3}' -f $_)) }
$env:GHOSTTY_SHELL_FEATURES = 'cursor:steady'
function prompt { 'KEEP-PROMPT' }
. $env:GHOSTTY_TEST_INTEGRATION
[Console]::WriteLine((prompt))
# Commands invoked without the PSReadLine Enter handler can emit text
# before the shell sends a command-start marker.
1..3 | ForEach-Object { [Console]::WriteLine(('RECENT-{0:D3}' -f $_)) }
[Console]::Write('CURRENT-INPUT')
while ($true) {
    $size = '{0}x{1}' -f [Console]::WindowWidth, [Console]::WindowHeight
    $file = Join-Path $env:TEMP ('size-' + $size)
    if (!(Test-Path -LiteralPath $file)) { [IO.File]::WriteAllText($file, '') }
    Start-Sleep -Milliseconds 100
}
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
$config = Join-Path $work 'config'
$shellPath = (Get-Command $Shell -CommandType Application | Select-Object -First 1).Source
$lines = @(('command = "' + $shellPath + '" -NoProfile -NoLogo -EncodedCommand ' + $encoded),
    'shell-integration = none', 'keybind = f4=write_screen_file:paste',
    'keybind = f6=increase_font_size:4')
[IO.File]::WriteAllLines($config, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = (Resolve-Path -LiteralPath $ExePath).Path
$start.WorkingDirectory = $work
$start.UseShellExecute = $false
$start.Arguments = '--config-default-files=false --config-file="' + $config + '"'
foreach ($name in 'TEMP','TMP','TMPDIR') { $start.EnvironmentVariables[$name] = $work }
$start.EnvironmentVariables['GHOSTTY_TEST_INTEGRATION'] = (Resolve-Path -LiteralPath $IntegrationPath).Path
$process = [Diagnostics.Process]::Start($start)
try {
    $initial = Wait-For { Get-ChildItem $work -Filter 'size-*' | Select-Object -First 1 } 'child startup'
    $pane = Wait-For {
        $process.Refresh()
        $candidate = [PowerShellResize]::Pane($process.MainWindowHandle, $process.Id)
        if ($candidate -ne [IntPtr]::Zero) { $candidate }
    } 'test terminal'
    $sizes = @($initial.Name)
    foreach ($stage in 'initial','font','viewport') {
        $existing = @(Get-ChildItem $work -Recurse -Filter screen.txt | ForEach-Object FullName)
        switch ($stage) {
            font { [PowerShellResize]::Key($pane, $process.Id, 0x75) }
            viewport { [PowerShellResize]::Resize($process.MainWindowHandle, $process.Id) }
        }
        if ($stage -ne 'initial') {
            $size = Wait-For { Get-ChildItem $work -Filter 'size-*' | Where-Object { $sizes -notcontains $_.Name } | Select-Object -First 1 } "$stage grid dimensions"
            $sizes += $size.Name
        }
        [PowerShellResize]::Key($pane, $process.Id, 0x73)
        $dump = Wait-For { Get-ChildItem $work -Recurse -Filter screen.txt | Where-Object { $_.Length -gt 0 -and $existing -notcontains $_.FullName } | Select-Object -First 1 } "$stage screen dump"
        $contents = [IO.File]::ReadAllText($dump.FullName)
        $markers = @(1..45 | ForEach-Object { 'HISTORY-{0:D3}' -f $_ }) + 'KEEP-PROMPT' +
            @(1..3 | ForEach-Object { 'RECENT-{0:D3}' -f $_ }) + 'CURRENT-INPUT'
        $offset = 0
        foreach ($marker in $markers) {
            $next = $contents.IndexOf($marker, $offset, [StringComparison]::Ordinal)
            if ($next -lt 0) { throw "$stage lost or reordered $marker in $($sizes[-1])" }
            $offset = $next + $marker.Length
        }
        Write-Output "PASS=$stage $($sizes[-1]) preserved scrollback, recent output, prompt, and input"
    }
} finally {
    if (!$process.HasExited) {
        $null = $process.CloseMainWindow()
        if (!$process.WaitForExit(2000)) { $process.Kill(); $process.WaitForExit() }
    }
    $process.Dispose()
    Remove-Item -LiteralPath $work -Recurse -Force
}
