param([Parameter(Mandatory)][string]$ExePath)

# Run a native PowerShell child in ConPTY, then capture and resize only the
# terminal window owned by this test. No desktop input is injected.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class VulkanTerminalWindow {
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

    public class ColorBlock {
        public int X = int.MaxValue, Y = int.MaxValue, Right = -1, Bottom = -1, Count;
        public int Width { get { return Count == 0 ? 0 : Right - X + 1; } }
        public int Height { get { return Count == 0 ? 0 : Bottom - Y + 1; } }
        public void Include(int x, int y) {
            X = Math.Min(X, x);
            Y = Math.Min(Y, y);
            Right = Math.Max(Right, x);
            Bottom = Math.Max(Bottom, y);
            Count++;
        }
        public bool IsBlock(int width, int height) {
            return Width == width && Height == height && Count == width * height;
        }
        public override string ToString() {
            return Count == 0 ? "0px" : String.Format("{0}px at ({1},{2}) covering {3}x{4}", Count, X, Y, Width, Height);
        }
    }

    public class Frame {
        public int Width, Height, Background;
        public ColorBlock Ink = new ColorBlock(), Cells = new ColorBlock(), Image = new ColorBlock();
        public ColorBlock FreshInk = new ColorBlock(), FreshImage = new ColorBlock();
        public override string ToString() {
            return String.Format("{0}x{1}; background {2}px; ink {3}; cells {4}; image {5}; fresh ink {6}; fresh image {7}",
                Width, Height, Background, Ink, Cells, Image, FreshInk, FreshImage);
        }
    }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string name);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam,
                                                                     IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage,
                                                                  out IntPtr data, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();
    [DllImport("dwmapi.dll")] static extern int DwmFlush();

    static Rect OwnedRect(IntPtr window, int pid, string className) {
        uint owner;
        Rect rect;
        var name = new StringBuilder(128);
        if (GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)pid ||
            GetClassName(window, name, name.Capacity) == 0 || name.ToString() != className ||
            !GetWindowRect(window, out rect))
            throw new InvalidOperationException("Expected an HWND belonging to the test terminal.");
        return rect;
    }

    public static void Shrink(IntPtr window, int pid, int width, int height) {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect rect = OwnedRect(window, pid, "GhosttyWindow");
            const uint noMoveNoZOrderNoActivate = 0x16;
            if (!SetWindowPos(window, IntPtr.Zero, 0, 0, rect.Right - rect.Left - width,
                              rect.Bottom - rect.Top - height, noMoveNoZOrderNoActivate))
                throw new Win32Exception();
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }

    public static Frame Capture(IntPtr window, int pid) {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect outer = OwnedRect(window, pid, "GhosttyWindow");
            IntPtr surface = FindWindowEx(window, IntPtr.Zero, "GhosttyTerminal", null);
            if (surface == IntPtr.Zero) return null;
            Rect content = OwnedRect(surface, pid, "GhosttyTerminal");
            IntPtr messageResult;
            if (SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 3, 300, out messageResult) == IntPtr.Zero)
                return null;
            int width = outer.Right - outer.Left, height = outer.Bottom - outer.Top;
            int x0 = Math.Max(0, content.Left - outer.Left), x1 = Math.Min(width, content.Right - outer.Left);
            int y0 = Math.Max(0, content.Top - outer.Top), y1 = Math.Min(height, content.Bottom - outer.Top);
            if (x0 >= x1 || y0 >= y1) return null;

            IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
            if (dc == IntPtr.Zero) throw new InvalidOperationException("CreateCompatibleDC failed.");
            try {
                var info = new BitmapInfo { Size = 40, Width = width, Height = -height, Planes = 1, Bits = 32 };
                IntPtr data;
                IntPtr bitmap = CreateDIBSection(dc, ref info, 0, out data, IntPtr.Zero, 0);
                if (bitmap == IntPtr.Zero) throw new InvalidOperationException("CreateDIBSection failed.");
                IntPtr previous = SelectObject(dc, bitmap);
                try {
                    DwmFlush();
                    if (!PrintWindow(window, dc, 2)) return null;
                    GdiFlush();
                    int[] raw = new int[checked(width * height)];
                    Marshal.Copy(data, raw, 0, raw.Length);
                    var frame = new Frame { Width = x1 - x0, Height = y1 - y0 };
                    for (int y = y0; y < y1; y++) {
                        for (int x = x0; x < x1; x++) {
                            switch (raw[y * width + x] & 0xffffff) {
                                case 0x223144: frame.Background++; break;
                                case 0xfb21f7: frame.Ink.Include(x - x0, y - y0); break;
                                case 0x1fd757: frame.Cells.Include(x - x0, y - y0); break;
                                case 0x1faceb: frame.Image.Include(x - x0, y - y0); break;
                                case 0x69b6f9: frame.FreshInk.Include(x - x0, y - y0); break;
                                case 0xdd7842: frame.FreshImage.Include(x - x0, y - y0); break;
                            }
                        }
                    }
                    return frame;
                } finally { SelectObject(dc, previous); DeleteObject(bitmap); }
            } finally { DeleteDC(dc); }
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }
}
'@

$child = @'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = '__FIXTURE_ROOT__'
$esc = [string][char]27
$blocks = [string][char]0x2588 * 12

function Report-Grid([string]$stage) {
    $grid = @{ cols = [Console]::WindowWidth; rows = [Console]::WindowHeight }
    [IO.File]::WriteAllText((Join-Path $root "$stage.tmp"), ($grid | ConvertTo-Json -Compress))
    [IO.File]::Move((Join-Path $root "$stage.tmp"), (Join-Path $root "$stage.json"))
}

function Paint-Image([string]$position, [int]$id, [byte]$r, [byte]$g, [byte]$b) {
    $bytes = [byte[]]::new(32 * 32 * 3)
    for ($i = 0; $i -lt $bytes.Length; $i += 3) {
        $bytes[$i] = $r
        $bytes[$i + 1] = $g
        $bytes[$i + 2] = $b
    }
    [Console]::Write($esc + "[$position" + 'H' + $esc + "_Ga=T,f=24,s=32,v=32,i=$id,q=2,C=1;" +
        [Convert]::ToBase64String($bytes) + $esc + '\')
}

function Wait-Host([string]$file) {
    $until = [DateTime]::UtcNow.AddSeconds(20)
    while (-not [IO.File]::Exists((Join-Path $root $file))) {
        if ([DateTime]::UtcNow -ge $until) { throw "Host handshake did not reach $file." }
        Start-Sleep -Milliseconds 50
    }
}

try {
    [Console]::Write($esc + '[?25l' + $esc + '[1;1H' + $esc + '[38;2;251;33;247m' + $blocks + $esc + '[0m' +
        $esc + '[2;1H' + $esc + '[48;2;31;215;87m' + (' ' * 12) + $esc + '[0m')
    Paint-Image '4;2' 31 31 172 235
    [Console]::Write($esc + ']2;Madotty Vulkan terminal fixture' + [char]7)
    [Console]::Out.Flush()
    $cols = [Console]::WindowWidth
    $rows = [Console]::WindowHeight
    Report-Grid 'initial'

    Wait-Host 'resize'
    $until = [DateTime]::UtcNow.AddSeconds(10)
    while ([Console]::WindowWidth -eq $cols -or [Console]::WindowHeight -eq $rows) {
        if ([DateTime]::UtcNow -ge $until) { throw 'ConPTY did not observe both resized dimensions.' }
        Start-Sleep -Milliseconds 50
    }
    # Announce the new grid without changing the screen content.
    Report-Grid 'resized'

    Wait-Host 'fresh'
    [Console]::Write($esc + '[1;1H' + $esc + '[38;2;105;182;249m' + $blocks + $esc + '[0m')
    Paint-Image '7;7' 32 221 120 66
    [Console]::Write($esc + ']2;Madotty Vulkan terminal fixture refreshed' + [char]7)
    [Console]::Out.Flush()
    Report-Grid 'fresh-frame'
    Wait-Host 'finish'
} catch {
    [IO.File]::WriteAllText((Join-Path $root 'child-error'), $_.ToString())
    exit 1
}
'@

$exe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$temp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$scratch = Join-Path $temp ('madotty-vulkan-terminal-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$process = $null
$stderr = $null
$passed = $false

function Wait-Frame([string]$stage, [string]$title, [scriptblock]$matches) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $gridFile = Join-Path $scratch ($stage + '.json')
    $childError = Join-Path $scratch 'child-error'
    $frame = $null
    $grid = $null
    do {
        if (Test-Path -LiteralPath $childError) { throw (Get-Content -LiteralPath $childError -Raw) }
        $process.Refresh()
        if ($process.HasExited) { throw "Vulkan terminal exited with $($process.ExitCode) before $stage." }
        if ((Test-Path -LiteralPath $gridFile) -and $process.MainWindowTitle -eq $title) {
            $grid = Get-Content -LiteralPath $gridFile -Raw | ConvertFrom-Json
            $frame = [VulkanTerminalWindow]::Capture($process.MainWindowHandle, $process.Id)
            if ($frame -and (& $matches $frame $grid)) {
                Write-Host "PASS $stage ($($grid.cols)x$($grid.rows) cells; $frame)"
                return @{ Frame = $frame; Grid = $grid }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt 15)
    throw "Unexpected pixels or geometry at $stage. Last grid $($grid.cols)x$($grid.rows); last frame $frame"
}

function Test-OriginalContent($frame, $ink, $grid) {
    if ($frame.Cells.Width -lt 12 -or $frame.Cells.Width % 12 -ne 0 -or $frame.Cells.Height -eq 0) {
        return $false
    }
    $w = [int]($frame.Cells.Width / 12)
    $h = $frame.Cells.Height
    $frame.Background -ge 1000 -and $frame.Cells.IsBlock((12 * $w), $h) -and $ink.IsBlock((12 * $w), $h) -and
        $ink.X -eq $frame.Cells.X -and $frame.Cells.Y - $ink.Y -eq $h -and
        $frame.Image.IsBlock(32, 32) -and $frame.Image.X - $ink.X -eq $w -and $frame.Image.Y - $ink.Y -eq 3 * $h -and
        [Math]::Floor($frame.Width / $w) -eq $grid.cols -and [Math]::Floor($frame.Height / $h) -eq $grid.rows
}

try {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
        $child.Replace('__FIXTURE_ROOT__', $scratch.Replace("'", "''"))))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.WorkingDirectory = $scratch
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $scratch
    $start.EnvironmentVariables['XDG_STATE_HOME'] = $scratch
    $start.EnvironmentVariables.Remove('GHOSTTY_RESOURCES_DIR')
    $start.EnvironmentVariables.Remove('MADOTTY_RENDERER_HANDOFF')
    $start.Arguments = '--config-default-files=false --auto-update=off --shell-integration=none' +
        ' --window-save-state=never --confirm-close-surface=false --quit-after-last-window-closed=true' +
        ' --background=223144 --background-opacity=1 --alpha-blending=linear-corrected' +
        ' --font-family="Cascadia Code" --font-size=12 --adjust-cell-width=1 --adjust-cell-height=1' +
        ' --window-padding-x=0 --window-padding-y=0 --window-show-tab-bar=never --window-width=48 --window-height=18' +
        ' -e powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $stderr = $process.StandardError.ReadToEndAsync()

    $title = 'Madotty Vulkan terminal fixture'
    $initial = Wait-Frame 'initial' $title {
        param($frame, $grid)
        (Test-OriginalContent $frame $frame.Ink $grid) -and $frame.FreshInk.Count -eq 0 -and
            $frame.FreshImage.Count -eq 0 -and $grid.cols -eq 48 -and $grid.rows -eq 18
    }
    $cellWidth = [int]($initial.Frame.Cells.Width / 12)
    $cellHeight = $initial.Frame.Cells.Height
    [VulkanTerminalWindow]::Shrink($process.MainWindowHandle, $process.Id, (8 * $cellWidth), (2 * $cellHeight))
    [IO.File]::WriteAllText((Join-Path $scratch 'resize'), '')
    $resized = Wait-Frame 'resized' $title {
        param($frame, $grid)
        (Test-OriginalContent $frame $frame.Ink $grid) -and $frame.FreshInk.Count -eq 0 -and
            $frame.FreshImage.Count -eq 0 -and $grid.cols -eq 40 -and $grid.rows -eq 16 -and
            $frame.Width -eq $initial.Frame.Width - 8 * $cellWidth -and
            $frame.Height -eq $initial.Frame.Height - 2 * $cellHeight
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'fresh'), '')
    $null = Wait-Frame 'fresh-frame' "$title refreshed" {
        param($frame, $grid)
        (Test-OriginalContent $frame $frame.FreshInk $grid) -and $frame.Ink.Count -eq 0 -and $frame.FreshImage.IsBlock(32, 32) -and
            $frame.FreshImage.X - $frame.FreshInk.X -eq 6 * $cellWidth -and
            $frame.FreshImage.Y - $frame.FreshInk.Y -eq 6 * $cellHeight -and
            $grid.cols -eq $resized.Grid.cols -and $grid.rows -eq $resized.Grid.rows -and
            $frame.Width -eq $resized.Frame.Width -and $frame.Height -eq $resized.Frame.Height
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'finish'), '')
    if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) {
        throw 'The Vulkan terminal did not exit cleanly.'
    }
    $diagnostics = $stderr.GetAwaiter().GetResult()
    if ($diagnostics -notmatch 'renderer=[^\r\n]*Vulkan' -or
        $diagnostics -match 'error\(vulkan\)|Vulkan frame failed|VK_ERROR_DEVICE_LOST|renderer health status change status=\.unhealthy') {
        throw 'Expected a healthy Vulkan renderer.'
    }
    $passed = $true
    Write-Output "PASS Vulkan terminal preserved its graphics across $($initial.Grid.cols)x$($initial.Grid.rows) to $($resized.Grid.cols)x$($resized.Grid.rows) resize ($($cellWidth)x$($cellHeight)px cells) and displayed new content."
} finally {
    if ($process) {
        if (-not $process.HasExited) {
            $null = $process.CloseMainWindow()
            if (-not $process.WaitForExit(3000)) { & taskkill.exe /PID $process.Id /T /F | Out-Null }
        }
        $process.Dispose()
    }
    if (-not $passed -and $stderr -and $stderr.IsCompleted) {
        $stderr.GetAwaiter().GetResult() -split '\r?\n' | Where-Object Length -lt 1000 |
            Select-Object -Last 30 | Write-Host
    }
    $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
    if ($resolved -eq $scratch -and (Split-Path -Parent $resolved) -eq $temp) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
