param([Parameter(Mandatory)][string]$ExePath)

# Launch the isolated Vulkan smoke executable, then drive its own HWND.
# The desktop fallback reads only individually verified client pixels.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class VulkanSmokeWindow {
    [StructLayout(LayoutKind.Sequential)]
    struct Point {
        public int X, Y;
        public Point(int x, int y) { X = x; Y = y; }
    }

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

    public class Frame {
        public int Width, Height;
        public bool Matches;
        public string Evidence;
    }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
                                            uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage,
                                                                  out IntPtr data, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();
    [DllImport("dwmapi.dll")] static extern int DwmFlush();

    static void Check(IntPtr window, int pid) {
        uint owner;
        var name = new StringBuilder(128);
        if (GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)pid ||
            GetClassName(window, name, name.Capacity) == 0 || name.ToString() != "MadottyVulkanSmoke")
            throw new InvalidOperationException("Expected the window owned by this Vulkan smoke process.");
    }

    public static void PresentPhase(IntPtr window, int pid, int phase) {
        Check(window, pid);
        if (!PostMessage(window, 0x8001, new IntPtr(phase), IntPtr.Zero)) throw new Win32Exception();
    }

    public static void Resize(IntPtr window, int pid, int widthDelta, int heightDelta) {
        Check(window, pid);
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect rect;
            const uint noMoveNoZOrderNoActivate = 0x16;
            if (!GetWindowRect(window, out rect) ||
                !SetWindowPos(window, IntPtr.Zero, 0, 0, rect.Right - rect.Left + widthDelta,
                              rect.Bottom - rect.Top + heightDelta, noMoveNoZOrderNoActivate))
                throw new Win32Exception();
        } finally {
            if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi);
        }
    }

    public static void Close(IntPtr window, int pid) {
        Check(window, pid);
        if (!PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
    }

    static Point[] SamplePoints(int width, int height) {
        var points = new Point[9];
        int index = 0;
        foreach (int y in new[] { 12, height / 2, height - 13 })
            foreach (int x in new[] { 12, width / 2, width - 13 })
                points[index++] = new Point(x, y);
        return points;
    }

    static int[] PrintSamples(IntPtr window, int width, int height, Point[] points) {
        IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
        if (dc == IntPtr.Zero) throw new InvalidOperationException("CreateCompatibleDC failed.");
        try {
            var info = new BitmapInfo { Size = 40, Width = width, Height = -height, Planes = 1, Bits = 32 };
            IntPtr data;
            IntPtr bitmap = CreateDIBSection(dc, ref info, 0, out data, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero) throw new InvalidOperationException("CreateDIBSection failed.");
            IntPtr previous = SelectObject(dc, bitmap);
            try {
                // PW_CLIENTONLY | PW_RENDERFULLCONTENT
                if (!PrintWindow(window, dc, 3)) return null;
                GdiFlush();
                var colors = new int[points.Length];
                for (int i = 0; i < points.Length; i++) {
                    int offset = checked(4 * (points[i].Y * width + points[i].X));
                    colors[i] = Marshal.ReadInt32(data, offset) & 0xffffff;
                }
                return colors;
            } finally { SelectObject(dc, previous); DeleteObject(bitmap); }
        } finally { DeleteDC(dc); }
    }

    static bool IsOnWindow(IntPtr window, Point position) {
        IntPtr pointWindow = WindowFromPoint(position);
        return pointWindow == window || GetAncestor(pointWindow, 2) == window; // GA_ROOT
    }

    static int[] VisibleSamples(IntPtr window, Point[] points) {
        IntPtr dc = GetDC(IntPtr.Zero);
        if (dc == IntPtr.Zero) return null;
        try {
            var colors = new int[points.Length];
            for (int i = 0; i < points.Length; i++) {
                Point position = points[i];
                if (!ClientToScreen(window, ref position) || !IsOnWindow(window, position)) return null;
                uint color = GetPixel(dc, position.X, position.Y);
                if (color == uint.MaxValue || !IsOnWindow(window, position)) return null;
                colors[i] = (int)(((color & 0xff) << 16) | (color & 0xff00) | ((color >> 16) & 0xff));
            }
            return colors;
        } finally { ReleaseDC(IntPtr.Zero, dc); }
    }

    static bool AllMatch(int[] colors, int expected) {
        if (colors == null) return false;
        foreach (int color in colors)
            if (color != expected) return false;
        return true;
    }

    static string Describe(int[] colors) {
        return colors == null ? "unavailable" : String.Join(" ", Array.ConvertAll(colors, x => x.ToString("X6")));
    }

    public static Frame Capture(IntPtr window, int pid, int expected) {
        Check(window, pid);
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect client;
            if (!GetClientRect(window, out client)) throw new Win32Exception();
            var frame = new Frame { Width = client.Right, Height = client.Bottom, Evidence = "empty client" };
            if (frame.Width < 64 || frame.Height < 64) return frame;
            IntPtr result;
            if (SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 0x0003, 300, out result) == IntPtr.Zero) {
                frame.Evidence = "window did not respond";
                return frame;
            }
            var points = SamplePoints(frame.Width, frame.Height);
            DwmFlush();
            int[] printed = PrintSamples(window, frame.Width, frame.Height, points);
            frame.Matches = AllMatch(printed, expected);
            frame.Evidence = "PrintWindow " + Describe(printed);
            if (!frame.Matches) {
                int[] visible = VisibleSamples(window, points);
                frame.Matches = AllMatch(visible, expected);
                frame.Evidence += "; visible owned pixels " + Describe(visible);
            }
            return frame;
        } finally {
            if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi);
        }
    }
}
'@

$exe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $exe
$start.WorkingDirectory = $env:TEMP
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardError = $true
$start.RedirectStandardOutput = $true
$process = [Diagnostics.Process]::Start($start)
$null = $process.Handle
$stderr = $process.StandardError.ReadToEndAsync()
$stdout = $process.StandardOutput.ReadToEndAsync()
$window = [IntPtr]::Zero
$passed = $false

function Wait-Frame([string]$phase, [int]$color, [int]$width = 0, [int]$height = 0) {
    $timeout = [Diagnostics.Stopwatch]::StartNew()
    $last = 'the smoke window was not found'
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Vulkan smoke process exited with $($process.ExitCode) during $phase." }
        if ($process.MainWindowTitle -eq 'Madotty Vulkan Smoke') {
            $ownedWindow = $process.MainWindowHandle
            $frame = [VulkanSmokeWindow]::Capture($ownedWindow, $process.Id, $color)
            $last = "$($frame.Width)x$($frame.Height) $($frame.Evidence)"
            if ($frame.Matches -and (-not $width -or ($frame.Width -eq $width -and $frame.Height -eq $height))) {
                Write-Host "PASS $phase ($last)"
                return $frame
            }
        }
        Start-Sleep -Milliseconds 100
    } while ($timeout.Elapsed.TotalSeconds -lt 15)
    throw ("Expected {0:X6} Vulkan pixels during {1}; last frame {2}." -f $color, $phase, $last)
}

try {
    $first = Wait-Frame 'first frame' 0x236DAF
    $window = $process.MainWindowHandle
    # Alternate long enough to reuse in-flight slots and presentation images.
    for ($frameNumber = 1; $frameNumber -le 7; $frameNumber++) {
        $phase = $frameNumber % 2
        $color = if ($phase -eq 1) { 0xC64524 } else { 0x236DAF }
        [VulkanSmokeWindow]::PresentPhase($window, $process.Id, $phase)
        $null = Wait-Frame "frame $($frameNumber + 1)" $color $first.Width $first.Height
    }

    $widthDelta = 128
    $heightDelta = 96
    [VulkanSmokeWindow]::Resize($window, $process.Id, $widthDelta, $heightDelta)
    $resized = Wait-Frame 'resized frame' 0xC64524 ($first.Width + $widthDelta) ($first.Height + $heightDelta)

    [VulkanSmokeWindow]::Close($window, $process.Id)
    if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) {
        throw 'The Vulkan smoke process did not close cleanly.'
    }
    $diagnostics = $stderr.GetAwaiter().GetResult()
    $adapter = $diagnostics -split '\r?\n' | Where-Object { $_ -match '^vulkan-smoke adapter .+' } | Select-Object -First 1
    if (-not $adapter) { throw 'The Vulkan smoke process did not identify its hardware adapter.' }
    $firstChain = "vulkan-smoke swapchain $($first.Width)x$($first.Height) generation=1(?:\s|$)"
    $nextChain = "vulkan-smoke swapchain $($resized.Width)x$($resized.Height) generation=2(?:\s|$)"
    if ($diagnostics -notmatch $firstChain -or $diagnostics -notmatch $nextChain) {
        throw 'The Vulkan smoke process did not confirm both swapchain generations at the captured client dimensions.'
    }
    $passed = $true
    Write-Output $adapter
    Write-Output "PASS Vulkan shader frames and swapchain recreation $($first.Width)x$($first.Height) to $($resized.Width)x$($resized.Height)."
} finally {
    if (-not $process.HasExited) {
        if ($window -ne [IntPtr]::Zero) {
            try { [VulkanSmokeWindow]::Close($window, $process.Id) } catch { }
        }
        if (-not $process.WaitForExit(1500)) {
            $process.Kill()
            $null = $process.WaitForExit(3000)
        }
    }
    if (-not $passed) {
        foreach ($stream in $stderr, $stdout) {
            if ($stream.IsCompleted) {
                $stream.GetAwaiter().GetResult() -split '\r?\n' | Where-Object Length -lt 1000 |
                    Select-Object -Last 25 | Write-Host
            }
        }
    }
    $process.Dispose()
}
