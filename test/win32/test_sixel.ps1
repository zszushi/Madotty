param(
    [Parameter(Mandatory)][string]$ExePath,
    [ValidateSet('opengl', 'd3d12', 'vulkan', 'both')][string]$Renderer = 'both'
)

$ErrorActionPreference = 'Stop'

# Capture only the terminal that this test launched. No desktop input is used.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SixelFrame {
    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct BitmapInfo {
        public uint Size;
        public int Width, Height;
        public ushort Planes, Bits;
        public uint Compression, SizeImage;
        public int DpiX, DpiY;
        public uint ColorsUsed, ImportantColors;
    }

    class ColorBounds {
        public int X = int.MaxValue, Y = int.MaxValue, Right = -1, Bottom = -1, Count;
        public void Include(int x, int y) {
            X = Math.Min(X, x);
            Y = Math.Min(Y, y);
            Right = Math.Max(Right, x);
            Bottom = Math.Max(Bottom, y);
            Count++;
        }
        public bool IsBlock(int width, int height) {
            return Count == width * height && Right - X + 1 == width && Bottom - Y + 1 == height;
        }
        public override string ToString() {
            if (Count == 0) return "0 pixels";
            return String.Format("{0} pixels at ({1},{2}) to ({3},{4})", Count, X, Y, Right, Bottom);
        }
    }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr data, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();
    [DllImport("dwmapi.dll")] static extern int DwmFlush();

    static int[] ReadPixels(IntPtr window, int width, int height) {
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
                if (!PrintWindow(window, dc, 2)) return null;
                GdiFlush();
                int[] pixels = new int[checked(width * height)];
                Marshal.Copy(data, pixels, 0, pixels.Length);
                return pixels;
            } finally { SelectObject(dc, previous); DeleteObject(dib); }
        } finally { DeleteDC(dc); }
    }

    public static bool Verify(IntPtr window, int pid, out string details) {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            uint actualPid;
            Rect rect;
            if (GetWindowThreadProcessId(window, out actualPid) == 0 ||
                actualPid != (uint)pid || !GetWindowRect(window, out rect))
                throw new InvalidOperationException("Capture target is outside the test process.");
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            int[] pixels = width > 0 && height > 0 ? ReadPixels(window, width, height) : null;
            details = "Window frame unavailable.";
            if (pixels == null) return false;

            var red = new ColorBounds();
            var green = new ColorBounds();
            var blue = new ColorBounds();
            int canceled = 0, glyph = 0;
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    switch (pixels[y * width + x] & 0xffffff) {
                        case 0xff0000: red.Include(x, y); break;
                        case 0x00ff00: green.Include(x, y); break;
                        case 0x0000ff: blue.Include(x, y); break;
                        case 0xffff00:
                        case 0x00ffff: canceled++; break;
                        case 0xfb21f7: glyph++; break;
                    }
                }
            }

            int underlay = 0;
            if (red.IsBlock(12, 18) && green.IsBlock(12, 18) &&
                green.X == red.X + 24 && green.Y == red.Y) {
                for (int y = red.Y; y <= red.Bottom; y++)
                    for (int x = red.Right + 1; x < green.X; x++)
                        if ((pixels[y * width + x] & 0xffffff) == 0x244572) underlay++;
            }
            details = String.Format("red: {0}; green: {1}; blue: {2}; underlay: {3}; canceled: {4}; glyph: {5}",
                red, green, blue, underlay, canceled, glyph);
            return underlay == 12 * 18 && blue.IsBlock(18, 12) &&
                blue.X == red.X && blue.Y > red.Bottom && canceled == 0 && glyph >= 100;
        } finally {
            if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi);
        }
    }
}
'@

$fixture = @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$esc = [string][char]27
$st = $esc + '\'
[Console]::Write($esc + '[?25l' + $esc + '[38;2;251;33;247m' + ([string][char]0x2588 * 12) + $esc + '[0m')
foreach ($row in 4..6) {
    [Console]::Write($esc + '[' + $row + ';4H' + $esc + '[48;2;36;69;114m' + (' ' * 16) + $esc + '[0m')
}
# Three sixel bands. A question mark advances a column without painting it.
$band = '#1!12~!12?#2!12~'
[Console]::Write($esc + '[4;4H' + $esc + 'P0;1q"1;1;36;18#1;2;100;0;0#2;2;0;100;0' +
    $band + '-' + $band + '-' + $band + $st)
# CAN and an ESC followed by a new CSI both discard incomplete DCS strings.
[Console]::Write($esc + '[8;12H' + $esc + 'Pq"1;1;18;12#4;2;100;100;0!18~-!18~' + [char]24)
[Console]::Write($esc + '[8;18H' + $esc + 'Pq"1;1;18;12#5;2;0;100;100!18~-!18~')
[Console]::Write($esc + '[8;4H' + $esc + 'Pq"1;1;18;12#3;2;0;0;100!18~-!18~' + $st)
[Console]::Write($esc + ']2;Madotty Sixel rendering fixture' + [char]7)
[Console]::Out.Flush()
Start-Sleep -Seconds 45
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fixture))
$terminal = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$backends = if ($Renderer -eq 'both') { @('opengl', 'd3d12') } else { @($Renderer) }

foreach ($backend in $backends) {
    $executable = $terminal
    if ($Renderer -eq 'both' -and $backend -eq 'd3d12') {
        $executable = Join-Path (Split-Path -Parent $terminal) 'ghostty-d3d12.exe'
    }
    $executable = (Resolve-Path -LiteralPath $executable).ProviderPath
    $scratch = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('madotty-sixel-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $scratch
    $process = $null
    $stderr = $null
    $passed = $false
    try {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $executable
        $start.WorkingDirectory = $scratch
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $scratch
        $start.EnvironmentVariables['XDG_STATE_HOME'] = $scratch
        $start.EnvironmentVariables.Remove('GHOSTTY_RESOURCES_DIR')
        $start.EnvironmentVariables.Remove('MADOTTY_RENDERER_HANDOFF')
        $start.Arguments = '--config-default-files=false --window-save-state=never --auto-update=off' +
            ' --shell-integration=none --confirm-close-surface=false --quit-after-last-window-closed=true' +
            ' --background=223144 --background-opacity=1 --alpha-blending=linear-corrected' +
            ' --window-show-tab-bar=never --window-width=48 --window-height=18' +
            ' -e powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded

        $process = [Diagnostics.Process]::Start($start)
        $null = $process.Handle
        $stderr = $process.StandardError.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $details = 'Fixture window not found.'
        $matched = $false
        do {
            $process.Refresh()
            if ($process.HasExited) { throw "Terminal exited with code $($process.ExitCode)." }
            if ($process.MainWindowTitle -eq 'Madotty Sixel rendering fixture') {
                $matched = [SixelFrame]::Verify($process.MainWindowHandle, $process.Id, [ref]$details)
                if ($matched) { break }
            }
            Start-Sleep -Milliseconds 100
        } while ($timer.Elapsed.TotalSeconds -lt 15)
        if (-not $matched) { throw "Unexpected $backend Sixel pixels. $details" }

        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) {
            throw "The $backend test terminal did not close cleanly."
        }
        $diagnostics = $stderr.GetAwaiter().GetResult()
        $expectedRenderer = switch ($backend) {
            'd3d12' { 'DirectX12' }
            'vulkan' { 'Vulkan' }
            default { 'OpenGL' }
        }
        if ($diagnostics -notmatch "renderer=[^\r\n]*$expectedRenderer") {
            throw "Use a $expectedRenderer executable for this case."
        }
        if ($diagnostics -match 'error\(directx12\)|Vulkan frame failed|renderer health status change status=\.unhealthy') {
            throw "The $expectedRenderer renderer reported an error."
        }
        $passed = $true
        Write-Output "PASS $backend Sixel rendering. $details"
    } finally {
        if ($process) {
            if (-not $process.HasExited) {
                $null = $process.CloseMainWindow()
                if (-not $process.WaitForExit(3000)) { & taskkill.exe /PID $process.Id /T /F | Out-Null }
            }
            $process.Dispose()
        }
        if (-not $passed -and $stderr -and $stderr.IsCompleted) {
            $stderr.GetAwaiter().GetResult() -split "\r?\n" | Where-Object Length -lt 1000 |
                Select-Object -Last 25 | Write-Host
        }
        $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
        if ($resolved -eq $scratch -and (Split-Path -Parent $resolved) -eq [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
