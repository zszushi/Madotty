param(
    [Parameter(Mandatory)][string]$ExePath,
    [switch]$CustomShader,
    [switch]$KittyGraphics,
    [ValidateSet('DirectX12','OpenGL')][string]$Renderer = 'DirectX12',
    [ValidateSet('native','linear','linear-corrected')][string]$AlphaBlending = 'linear-corrected'
)

# Capture only our terminal HWND. No desktop input or screen capture is needed.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;

public static class D3D12PixelTest {
    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    static Rect CheckWindow(IntPtr hwnd, int expectedPid) {
        uint pid;
        Rect rect;
        if (GetWindowThreadProcessId(hwnd, out pid) == 0 || pid != expectedPid || !GetWindowRect(hwnd, out rect))
            throw new InvalidOperationException("Expected the terminal started by this test.");
        return rect;
    }

    public static int[] Colors(IntPtr hwnd, int pid, int glyphColor, int imageColor, bool swapRedBlue) {
        SetThreadDpiAwarenessContext(new IntPtr(-4)); // Per-monitor DPI V2
        Rect rect = CheckWindow(hwnd, pid);
        int[] counts = new int[4];
        using (var bitmap = new Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top)) {
            using (var graphics = Graphics.FromImage(bitmap)) {
                IntPtr dc = graphics.GetHdc();
                try { if (!PrintWindow(hwnd, dc, 2)) throw new InvalidOperationException("PrintWindow failed."); }
                finally { graphics.ReleaseHdc(dc); }
            }
            for (int y = 0; y < bitmap.Height; y += 2) {
                for (int x = 0; x < bitmap.Width; x += 2) {
                    int rgb = bitmap.GetPixel(x, y).ToArgb() & 0xffffff;
                    if (swapRedBlue) rgb = ((rgb & 0xff) << 16) | (rgb & 0xff00) | (rgb >> 16);
                    if (rgb == 0x223144) counts[0]++;
                    if (y < bitmap.Height / 2) {
                        if (rgb == glyphColor) counts[1]++;
                        if (rgb == 0x1fd757) counts[2]++;
                        if (rgb == imageColor) counts[3]++;
                    }
                }
            }
        }
        return counts;
    }

    public static void Resize(IntPtr hwnd, int pid) {
        Rect rect = CheckWindow(hwnd, pid);
        const uint SWP_NOMOVE_NOZORDER_NOACTIVATE = 0x16;
        if (!SetWindowPos(hwnd, IntPtr.Zero, 0, 0, rect.Right - rect.Left - 80,
                          rect.Bottom - rect.Top - 40, SWP_NOMOVE_NOZORDER_NOACTIVATE))
            throw new Win32Exception();
    }
}
'@

$resizeFlag = Join-Path $env:TEMP ('madotty-d3d12-pixels-' + [guid]::NewGuid().ToString('N'))
$shaderPath = $resizeFlag + '.glsl'
$logPath = $resizeFlag + '.log'
$fixture = @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$esc = [string][char]27
function Paint-Image([byte]$r, [byte]$g, [byte]$b) {
    if ('{{KittyGraphics}}' -ne 'True') { return }
    $bytes = [byte[]]::new(32 * 32 * 3)
    for ($i = 0; $i -lt $bytes.Length; $i += 3) {
        $bytes[$i] = $r
        $bytes[$i + 1] = $g
        $bytes[$i + 2] = $b
    }
    [Console]::Write($esc + '[4;2H' + $esc + '_Ga=T,f=24,s=32,v=32,i=31,q=2,C=1;' +
        [Convert]::ToBase64String($bytes) + $esc + '\')
}
[Console]::Write($esc + '[?25l' + $esc + '[38;2;251;33;247m' + ([string][char]0x2588 * 24) + $esc + '[0m' + "`r`n")
[Console]::Write($esc + '[48;2;31;215;87m' + (' ' * 24) + $esc + '[0m' + "`r`n")
Paint-Image 31 172 235
[Console]::Write($esc + ']2;Madotty D3D12 fixture' + [char]7)
[Console]::Out.Flush()
$deadline = [DateTime]::UtcNow.AddSeconds(35)
while (-not [IO.File]::Exists('{{ResizeFlag}}') -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 50
}
[Console]::Write($esc + '[H' + $esc + '[38;2;105;182;249m' + ([string][char]0x2588 * 24) + $esc + '[0m')
Paint-Image 221 120 66
[Console]::Write($esc + ']2;Madotty D3D12 fixture resized' + [char]7)
[Console]::Out.Flush()
Start-Sleep -Seconds 20
'@
$fixture = $fixture.Replace('{{ResizeFlag}}', $resizeFlag.Replace("'", "''"))
$fixture = $fixture.Replace('{{KittyGraphics}}', $KittyGraphics.IsPresent.ToString())
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fixture))
$arguments = '--config-default-files=false --auto-update=off --shell-integration=none --confirm-close-surface=false' +
    " --background=223144 --background-opacity=1 --alpha-blending=$AlphaBlending --window-show-tab-bar=never"
$test = $null
$passed = $false
$previousConfigHome = $env:XDG_CONFIG_HOME
$configRoot = $resizeFlag + '-config'
try {
    $env:XDG_CONFIG_HOME = $configRoot
    if ($CustomShader) {
        [IO.File]::WriteAllText($shaderPath, @'
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 terminalPixel = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = terminalPixel.bgra;
}
'@)
        $arguments += ' --custom-shader="' + $shaderPath + '"'
    }
    $arguments += ' --command="powershell.exe -NoLogo -NoProfile -EncodedCommand ' + $encoded + '"'
    $test = Start-Process -FilePath $ExePath -ArgumentList $arguments -WorkingDirectory $env:TEMP -RedirectStandardError $logPath -PassThru
    $null = $test.Handle

    function Assert-Frame([string]$description, [string]$title, [int]$glyphColor, [int]$imageColor) {
        $limit = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $test.Refresh()
            if ($test.HasExited) { throw "Terminal exited with code $($test.ExitCode)." }
            if ($test.MainWindowHandle -ne [IntPtr]::Zero -and $test.MainWindowTitle -eq $title) {
                $colors = [D3D12PixelTest]::Colors($test.MainWindowHandle, $test.Id, $glyphColor, $imageColor, $CustomShader.IsPresent)
                if ($colors[0] -ge 2000 -and $colors[1] -ge 100 -and $colors[2] -ge 100 -and
                    (-not $KittyGraphics -or $colors[3] -ge 100)) {
                    Write-Output "PASS $description (background, glyph, truecolor cell, image samples: $($colors -join ', '))"
                    return
                }
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $limit)
        throw "Missing expected pixels $description. Last result: $($colors -join ', ')."
    }

    Assert-Frame 'before resize' 'Madotty D3D12 fixture' 0xFB21F7 0x1FACEB
    [D3D12PixelTest]::Resize($test.MainWindowHandle, $test.Id)
    [IO.File]::WriteAllText($resizeFlag, '')
    Assert-Frame 'after resize' 'Madotty D3D12 fixture resized' 0x69B6F9 0xDD7842
    $null = $test.CloseMainWindow()
    if (-not $test.WaitForExit(5000)) { throw 'The test terminal did not close in time.' }
    if ($test.ExitCode -ne 0) { throw ('The test terminal closed with 0x{0:X8}.' -f $test.ExitCode) }
    $diagnostics = [IO.File]::ReadAllText($logPath)
    if ($diagnostics -notmatch "renderer=[^\r\n]*$Renderer") { throw "Expected the $Renderer renderer." }
    if ($diagnostics -match "error\($Renderer\)|renderer health status change status=\.unhealthy") {
        throw "The $Renderer renderer reported an error while drawing the fixture."
    }
    $passed = $true
} finally {
    $env:XDG_CONFIG_HOME = $previousConfigHome
    if ($test) {
        if (-not $test.HasExited) {
            $null = $test.CloseMainWindow()
            if (-not $test.WaitForExit(3000)) { & taskkill.exe /PID $test.Id /T /F | Out-Null }
        }
        $test.Dispose()
    }
    if (-not $passed -and [IO.File]::Exists($logPath)) {
        Get-Content -LiteralPath $logPath -Tail 35 | Where-Object Length -lt 1000 | Write-Host
    }
    [IO.File]::Delete($resizeFlag)
    [IO.File]::Delete($shaderPath)
    [IO.File]::Delete($logPath)
    if (Test-Path -LiteralPath $configRoot -PathType Container) {
        $resolvedConfigRoot = (Resolve-Path -LiteralPath $configRoot).ProviderPath
        $tempPath = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
        if ($resolvedConfigRoot -eq $configRoot -and (Split-Path -Parent $resolvedConfigRoot) -eq $tempPath) {
            Remove-Item -LiteralPath $resolvedConfigRoot -Recurse -Force
        }
    }
}
