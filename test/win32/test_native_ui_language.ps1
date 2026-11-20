#Requires -Version 7.0
param([Parameter(Mandatory)][string]$ExePath)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeLanguageProbe {
    [DllImport("kernel32.dll")] public static extern ushort GetThreadUILanguage();
    [DllImport("user32.dll")] static extern IntPtr GetSystemMenu(IntPtr window, bool revert);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetMenuString(IntPtr menu, uint item, StringBuilder label, int count, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryEx(string file, IntPtr unused, uint flags);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", EntryPoint="FindResourceExW", SetLastError=true)] static extern IntPtr FindResourceEx(IntPtr module, IntPtr type, IntPtr id, ushort language);
    [DllImport("kernel32.dll")] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll")] static extern uint SizeofResource(IntPtr module, IntPtr resource);

    public static string MenuLabel(IntPtr window) {
        var label = new StringBuilder(64);
        GetMenuString(GetSystemMenu(window, false), 0x1FD0, label, label.Capacity, 0);
        return label.ToString();
    }

    public static string DialogStrings(string file, int id, ushort language) {
        var module = LoadLibraryEx(file, IntPtr.Zero, 0x22);
        if (module == IntPtr.Zero) throw new Win32Exception();
        try {
            var resource = FindResourceEx(module, (IntPtr)5, (IntPtr)id, language);
            if (resource == IntPtr.Zero) throw new Win32Exception();
            var data = LockResource(LoadResource(module, resource));
            return Marshal.PtrToStringUni(data, checked((int)SizeofResource(module, resource) / 2));
        } finally { FreeLibrary(module); }
    }
}
'@
$exe = (Get-Item -LiteralPath $ExePath).FullName
if (-not [NativeLanguageProbe]::DialogStrings($exe, 110, 0).Contains('Open &Windows settings') -or
    -not [NativeLanguageProbe]::DialogStrings($exe, 118, 0x411).Contains('Windows の設定を開く(&I)')) {
    throw 'Missing English or Japanese fallback settings dialog.'
}
$expected = if (([NativeLanguageProbe]::GetThreadUILanguage() -band 0x3ff) -eq 0x11) { '設定' } else { 'Settings' }
$start = [Diagnostics.ProcessStartInfo]::new($exe)
$start.UseShellExecute = $false
$start.WorkingDirectory = $env:TEMP
foreach ($arg in '--config-default-files=false','--window-save-state=never','--confirm-close-surface=false','--auto-update=off','-e',
        "$env:SystemRoot\System32\cmd.exe", '/d', '/k') { $start.ArgumentList.Add($arg) }
$process = [Diagnostics.Process]::Start($start)
try {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Terminal exited with code $($process.ExitCode)." }
        $window = $process.MainWindowHandle
        if ($window -ne [IntPtr]::Zero) { $label = [NativeLanguageProbe]::MenuLabel($window) }
        if ($label) { break }
        Start-Sleep -Milliseconds 50
    } while ($clock.Elapsed.TotalSeconds -lt 12)
    if ($label -cne $expected) { throw "Expected native menu '$expected', found '$label'." }
    Write-Output "PASS native menu '$label' and both fallback dialog resources"
} finally {
    if (-not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(3000)) { $process.Kill($true); $process.WaitForExit() }
    }
    $process.Dispose()
}
