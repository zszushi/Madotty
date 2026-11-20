param(
    [Parameter(Mandatory)][string]$ExePath,
    [ValidateSet('opengl', 'd3d12', 'both')][string]$Renderer = 'both'
)

# A raw WSL Python 3 child exercises the real terminal over ConPTY. The host
# reads pixels only from the terminal HWND it launched.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ItermImageWindow {
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

    public class Pixels {
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
            return Count == 0 ? "0px" : String.Format("{0}px at ({1},{2}) to ({3},{4})", Count, X, Y, Right, Bottom);
        }
    }

    public class Frame {
        public Pixels Red = new Pixels(), Green = new Pixels(), Blue = new Pixels(), Marker = new Pixels();
        public override string ToString() {
            return String.Format("red {0}; green {1}; blue {2}; marker {3}", Red, Green, Blue, Marker);
        }
    }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string name);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr data, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();
    [DllImport("dwmapi.dll")] static extern int DwmFlush();

    static Rect OwnedRect(IntPtr window, int pid) {
        uint owner;
        Rect rect;
        if (GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)pid ||
            !GetWindowRect(window, out rect))
            throw new InvalidOperationException("Capture target is outside the test process.");
        return rect;
    }

    public static Frame Capture(IntPtr window, int pid) {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect rect = OwnedRect(window, pid);
            IntPtr surface = FindWindowEx(window, IntPtr.Zero, "GhosttyTerminal", null);
            if (surface == IntPtr.Zero) return null;
            Rect content = OwnedRect(surface, pid);
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            if (width <= 0 || height <= 0) return null;
            int x0 = Math.Max(0, content.Left - rect.Left), x1 = Math.Min(width, content.Right - rect.Left);
            int y0 = Math.Max(0, content.Top - rect.Top), y1 = Math.Min(height, content.Bottom - rect.Top);
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
                    var raw = new int[checked(width * height)];
                    Marshal.Copy(data, raw, 0, raw.Length);
                    var frame = new Frame();
                    for (int y = y0; y < y1; y++) {
                        for (int x = x0; x < x1; x++) {
                            switch (raw[y * width + x] & 0xffffff) {
                                case 0xe92a34: frame.Red.Include(x, y); break;
                                case 0x21df8b: frame.Green.Include(x, y); break;
                                case 0x307bfa: frame.Blue.Include(x, y); break;
                                case 0xfb21f7: frame.Marker.Include(x, y); break;
                            }
                        }
                    }
                    return frame;
                } finally { SelectObject(dc, previous); DeleteObject(dib); }
            } finally { DeleteDC(dc); }
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }
}
'@

$template = @'
import base64
import json
import os
import re
import select
import struct
import termios
import time
import tty
import zlib
from pathlib import Path

root = Path(__TEST_ROOT__)
esc = b"\x1b"
csi = esc + b"["
st = esc + b"\\"
bel = b"\x07"
original = termios.tcgetattr(0)

def osc(payload, terminator=st):
    return esc + b"]1337;" + payload + terminator

def receive(terminator=None, seconds=2):
    deadline = time.monotonic() + seconds
    data = bytearray()
    while len(data) < 512:
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([0], [], [], left)[0]:
            break
        chunk = os.read(0, 512 - len(data))
        if not chunk:
            break
        data.extend(chunk)
        if terminator and data.endswith(terminator):
            break
    return bytes(data)

def request(query, pattern, terminator):
    os.write(1, query)
    reply = receive(terminator)
    match = re.fullmatch(pattern, reply)
    if not match:
        raise AssertionError(f"{query!r}: unexpected terminal reply {reply!r}")
    return match.groups(), reply

def cpr(row, col):
    reply, _ = request(csi + b"6n", rb"\x1b\[(\d+);(\d+)R", b"R")
    actual = tuple(map(int, reply))
    if actual != (row, col):
        raise AssertionError(f"CPR expected {(row, col)}, got {actual}")
    return actual

def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

def png(rgb_row, height, compression=6):
    width = len(rgb_row) // 3
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
            chunk(b"IDAT", zlib.compress((b"\x00" + rgb_row) * height, compression)) + chunk(b"IEND", b""))

def metadata(image, width, height):
    return f"inline=1;size={len(image)};width={width}px;height={height}px;preserveAspectRatio=0".encode()

def report(name, **fields):
    pending = root / (name + ".tmp")
    pending.write_text(json.dumps(fields), encoding="utf-8")
    pending.rename(root / (name + ".json"))

def stage(name, **fields):
    os.write(1, esc + b"]2;OSC 1337 fixture " + name.encode() + st)
    report(name, **fields)

def await_host(name):
    deadline = time.monotonic() + 15
    while not (root / name).exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Windows test did not advance to {name}")
        time.sleep(0.05)

try:
    tty.setraw(0)
    receive(seconds=0.25)
    size, _ = request(csi + b"16t", rb"\x1b\[6;(\d+);(\d+)t", b"t")
    cell_h, cell_w = map(int, size)
    number = rb"([0-9]+(?:\.[0-9]+)?)"
    cell_report, wire = request(osc(b"ReportCellSize"),
                                rb"\x1b\]1337;ReportCellSize=" + number + b";" + number +
                                rb"(?:;" + number + rb")?(?:\x07|\x1b\\)", (st, bel))
    points_h, points_w, scale = (float(value) if value else 1.0 for value in cell_report)
    if (scale <= 0 or abs(points_h * scale - cell_h) > 0.05 or abs(points_w * scale - cell_w) > 0.05):
        raise AssertionError(f"OSC cell size {cell_report!r} does not match {(cell_h, cell_w)} physical pixels")
    os.write(1, wire)
    echoed = receive(seconds=0.3)
    if echoed:
        raise AssertionError(f"Echoed ReportCellSize reply generated input {echoed!r}")

    direct_height = max(24, cell_h + 4)
    direct_cols = (24 + cell_w - 1) // cell_w
    direct_rows = (direct_height + cell_h - 1) // cell_h
    # An uncompressed stream makes this OSC exceed the inline parser buffer.
    direct_png = png(bytes.fromhex("e92a34") * 12 + bytes.fromhex("21df8b") * 12, direct_height, compression=0)
    os.write(1, csi + b"?25l" + csi + b"4;3H" +
             osc(b"File=" + metadata(direct_png, 24, direct_height) + b":" + base64.b64encode(direct_png)))
    # iTerm2 advances to the next column on the final occupied row.
    direct_cursor = cpr(4 + direct_rows - 1, 3 + direct_cols)
    os.write(1, csi + b"38;2;251;33;247m" + "\u2588".encode("utf-8") + csi + b"0m")
    stage("direct", cell_h=cell_h, cell_w=cell_w, scale=scale, points_h=points_h, points_w=points_w,
          height=direct_height, image_rows=direct_rows, image_cols=direct_cols, cursor=direct_cursor)

    await_host("send-parts")
    split_png = png(bytes.fromhex("307bfa") * 18, 12)
    encoded = base64.b64encode(split_png)
    mid = 4 * (len(encoded) // 8) + 1
    os.write(1, csi + b"8;7H" + osc(b"MultipartFile=" + metadata(split_png, 18, 12) + b";doNotMoveCursor=1", bel) +
             osc(b"FilePart=" + encoded[:mid]) + osc(b"FilePart=" + encoded[mid:], bel))
    stage("parts", cursor=cpr(8, 7))

    await_host("end-file")
    os.write(1, osc(b"FileEnd"))
    stage("complete", cursor=cpr(8, 7))
    await_host("finish")
except Exception as error:
    report("failed", error=str(error))
finally:
    termios.tcsetattr(0, termios.TCSANOW, original)
'@

$terminal = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$temp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$backends = if ($Renderer -eq 'both') { @('opengl', 'd3d12') } else { @($Renderer) }

function Wait-Phase([string]$name, [scriptblock]$matches, [int]$StableMilliseconds = 0) {
    $timeout = [Diagnostics.Stopwatch]::StartNew()
    $stagePath = Join-Path $scratch ($name + '.json')
    $failure = Join-Path $scratch 'failed.json'
    $frame = $null
    $stableSince = -1
    do {
        if (Test-Path -LiteralPath $failure) {
            $childError = Get-Content -LiteralPath $failure -Raw | ConvertFrom-Json
            throw $childError.error
        }
        $process.Refresh()
        if ($process.HasExited) { throw "Terminal exited before $name." }
        if ((Test-Path -LiteralPath $stagePath) -and $process.MainWindowTitle -eq "OSC 1337 fixture $name") {
            $stage = Get-Content -LiteralPath $stagePath -Raw | ConvertFrom-Json
            $frame = [ItermImageWindow]::Capture($process.MainWindowHandle, $process.Id)
            if ($frame -and (& $matches $frame $stage)) {
                if ($stableSince -lt 0) { $stableSince = $timeout.ElapsedMilliseconds }
                if ($timeout.ElapsedMilliseconds -ge $stableSince + $StableMilliseconds) {
                    Write-Host "PASS $backend $name ($frame)"
                    return $stage
                }
            } else {
                $stableSince = -1
            }
        }
        Start-Sleep -Milliseconds 100
    } while ($timeout.Elapsed.TotalSeconds -lt 15)
    throw "Unexpected $backend pixels at $name. Last frame: $frame"
}

function Test-DirectFrame($frame, $stage) {
    $frame.Red.IsBlock(12, $stage.height) -and $frame.Green.IsBlock(12, $stage.height) -and
        $frame.Green.X -eq $frame.Red.X + 12 -and $frame.Red.Y -eq $frame.Green.Y -and
        $frame.Marker.Count -ge $stage.cell_h * $stage.cell_w / 2 -and
        $frame.Marker.X - $frame.Red.X -eq $stage.image_cols * $stage.cell_w -and
        $frame.Marker.Y - $frame.Red.Y -eq ($stage.image_rows - 1) * $stage.cell_h
}

foreach ($backend in $backends) {
    $exe = $terminal
    if ($Renderer -eq 'both' -and $backend -eq 'd3d12') {
        $exe = Join-Path (Split-Path -Parent $terminal) 'ghostty-d3d12.exe'
    }
    $exe = (Resolve-Path -LiteralPath $exe).ProviderPath
    $scratch = Join-Path $temp ('madotty-iterm-image-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $scratch
    $process = $null
    $stderr = $null
    $passed = $false
    try {
        $linuxPath = & wsl.exe --exec wslpath -u $scratch
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the test directory in WSL.' }
        $child = $template.Replace('__TEST_ROOT__', ($linuxPath.Trim() | ConvertTo-Json -Compress))
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($child))
        $bootstrap = "exec(__import__('base64').b64decode('$encoded'))"
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
            ' --window-show-tab-bar=never --window-width=48 --window-height=18' +
            ' -e wsl.exe --exec python3 -c ' + $bootstrap
        $process = [Diagnostics.Process]::Start($start)
        $null = $process.Handle
        $stderr = $process.StandardError.ReadToEndAsync()

        $direct = Wait-Phase 'direct' {
            param($frame, $stage)
            (Test-DirectFrame $frame $stage) -and $frame.Blue.Count -eq 0
        }
        [IO.File]::WriteAllText((Join-Path $scratch 'send-parts'), '')
        $parts = Wait-Phase 'parts' {
            param($frame)
            (Test-DirectFrame $frame $direct) -and $frame.Blue.Count -eq 0
        } -StableMilliseconds 300
        [IO.File]::WriteAllText((Join-Path $scratch 'end-file'), '')
        $complete = Wait-Phase 'complete' {
            param($frame)
            (Test-DirectFrame $frame $direct) -and $frame.Blue.IsBlock(18, 12) -and
                $frame.Blue.X - $frame.Red.X -eq 4 * $direct.cell_w -and
                $frame.Blue.Y - $frame.Red.Y -eq 4 * $direct.cell_h
        }
        [IO.File]::WriteAllText((Join-Path $scratch 'finish'), '')
        if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) {
            throw "The $backend test terminal did not exit cleanly."
        }
        $diagnostics = $stderr.GetAwaiter().GetResult()
        $expected = if ($backend -eq 'd3d12') { 'DirectX12' } else { 'OpenGL' }
        if ($diagnostics -notmatch "renderer=[^\r\n]*$expected" -or
            $diagnostics -match 'error\(directx12\)|renderer health status change status=\.unhealthy') {
            throw "Expected a healthy $expected renderer."
        }
        $passed = $true
        Write-Output ("PASS $backend cell {0}x{1}px = {2}x{3}pt at scale {4}; CPR {5}, {6}, {7}." -f
            $direct.cell_w, $direct.cell_h, $direct.points_w, $direct.points_h, $direct.scale,
            ($direct.cursor -join ';'), ($parts.cursor -join ';'), ($complete.cursor -join ';'))
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
                Select-Object -Last 25 | Write-Host
        }
        $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
        if ($resolved -eq $scratch -and (Split-Path -Parent $resolved) -eq $temp) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
