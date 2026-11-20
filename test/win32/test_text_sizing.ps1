param(
    [Parameter(Mandatory)][string]$ExePath,
    [ValidateSet('opengl', 'd3d12', 'both')][string]$Renderer = 'both'
)

# Use a raw child on ConPTY for replies and capture or resize only its window.
# This requires WSL with Python 3 and never injects desktop input.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class TextSizingWindow {
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
        public int Count, First = int.MaxValue, Last = -1;
        public int Width { get { return Count == 0 ? 0 : Last - First + 1; } }
        public void Include(int x) {
            Count++;
            First = Math.Min(First, x);
            Last = Math.Max(Last, x);
        }
        public override string ToString() {
            return String.Format("{0}px, width {1}px", Count, Width);
        }
    }

    public class Frame {
        public Pixels Single = new Pixels(), Marker = new Pixels(), Multi = new Pixels();
        public Pixels MultiReplacement = new Pixels(), SingleReplacement = new Pixels();
        public int MultiRuns;
        public override string ToString() {
            return String.Format("x {0}; next cell {1}; multi {2} in {3} runs; replacements {4}, {5}",
                Single, Marker, Multi, MultiRuns, MultiReplacement, SingleReplacement);
        }
    }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string name);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
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
            throw new InvalidOperationException("The window does not belong to the test terminal.");
        return rect;
    }

    public static void Shrink(IntPtr window, int pid, int delta) {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect rect = OwnedRect(window, pid);
            const uint noMoveNoZOrderNoActivate = 0x16;
            if (!SetWindowPos(window, IntPtr.Zero, 0, 0, rect.Right - rect.Left - delta,
                              rect.Bottom - rect.Top, noMoveNoZOrderNoActivate))
                throw new Win32Exception();
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }

    public static Frame Capture(IntPtr window, int pid) {
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect rect = OwnedRect(window, pid);
            IntPtr surface = FindWindowEx(window, IntPtr.Zero, "GhosttyTerminal", null);
            if (surface == IntPtr.Zero) return null;
            Rect content = OwnedRect(surface, pid);
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            int x0 = Math.Max(0, content.Left - rect.Left), x1 = Math.Min(width, content.Right - rect.Left);
            int y0 = Math.Max(0, content.Top - rect.Top), y1 = Math.Min(height, content.Bottom - rect.Top);
            if (width <= 0 || height <= 0) return null;
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
                    var multiColumns = new bool[width];
                    for (int y = y0; y < y1; y++) {
                        for (int x = x0; x < x1; x++) {
                            int rgb = raw[y * width + x] & 0xffffff;
                            switch (rgb) {
                                case 0xff8f35: frame.Marker.Include(x); break;
                                case 0x2cde71: frame.Multi.Include(x); multiColumns[x] = true; break;
                                case 0x3eb8f4: frame.MultiReplacement.Include(x); break;
                                case 0xdfa23b: frame.SingleReplacement.Include(x); break;
                                default:
                                    // The x is antialiased. Count unmistakable magenta ink.
                                    if ((rgb >> 16) > 140 && ((rgb >> 8) & 255) < 102 && (rgb & 255) > 140)
                                        frame.Single.Include(x);
                                    break;
                            }
                        }
                    }
                    for (int x = 0; x < width; x++)
                        if (multiColumns[x] && (x == 0 || !multiColumns[x - 1])) frame.MultiRuns++;
                    return frame;
                } finally { SelectObject(dc, previous); DeleteObject(dib); }
            } finally { DeleteDC(dc); }
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }
}
'@

$childTemplate = @'
import json
import os
import re
import select
import termios
import time
import tty
from pathlib import Path

root = Path(__TEST_ROOT__)
esc = b"\x1b"
csi = esc + b"["
st = esc + b"\\"
block = "\u2588".encode("utf-8")
reset = csi + b"0m"
original = termios.tcgetattr(0)

def read_reply(terminator, deadline):
    output = bytearray()
    while len(output) < 128:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([0], [], [], remaining)[0]:
            break
        part = os.read(0, 128 - len(output))
        if not part:
            break
        output.extend(part)
        if terminator and output.endswith(terminator):
            break
    return bytes(output)

def query(sequence, kind, terminator):
    os.write(1, csi + sequence)
    result = read_reply(terminator, time.monotonic() + 2)
    match = re.fullmatch(kind, result)
    if not match:
        raise AssertionError(f"{sequence!r}: unexpected terminal reply {result!r}")
    return tuple(int(value) for value in match.groups())

def cpr(expected):
    actual = query(b"6n", rb"\x1b\[(\d+);(\d+)R", b"R")
    if actual != expected:
        raise AssertionError(f"CPR expected {expected}, got {actual}")
    return actual

def dimensions():
    return query(b"18t", rb"\x1b\[8;(\d+);(\d+)t", b"t")

def sized(width, text):
    return esc + b"]66;w=" + str(width).encode() + b";" + text + st

def record(stage, **content):
    path = root / (stage + ".tmp")
    path.write_text(json.dumps(content), encoding="utf-8")
    path.rename(root / (stage + ".json"))

def stage(name, **values):
    os.write(1, esc + b"]2;OSC 66 fixture " + name.encode() + st)
    record(name, **values)

def await_host(name):
    until = time.monotonic() + 15
    while not (root / name).exists():
        if time.monotonic() >= until:
            raise TimeoutError(f"Windows fixture did not advance to {name}")
        time.sleep(0.05)

try:
    tty.setraw(0)
    read_reply(None, time.monotonic() + 0.25)
    cell_height, cell_width = query(b"16t", rb"\x1b\[6;(\d+);(\d+)t", b"t")
    rows, cols = dimensions()
    os.write(1, csi + b"?25l" + csi + b"1;1H" + csi + b"38;2;251;33;247m" + sized(3, b"x"))
    single = cpr((1, 4))
    os.write(1, csi + b"38;2;255;143;53m" + block + reset + csi + b"3;2H" +
             csi + b"38;2;44;222;113m" + sized(5, block + b" " + block) + reset)
    multi = cpr((3, 7))
    stage("initial", cell_width=cell_width, cell_height=cell_height, single=single, multi=multi, cols=cols)

    await_host("overwrite-multi")
    # Column 5 is inside the explicit span but beyond both payload glyphs.
    os.write(1, csi + b"3;5H" + csi + b"38;2;62;184;244m" + block + reset)
    stage("multi-erased", replacement=cpr((3, 6)))

    await_host("resize")
    until = time.monotonic() + 6
    new_rows, new_cols = dimensions()
    while new_cols >= cols and time.monotonic() < until:
        time.sleep(0.075)
        new_rows, new_cols = dimensions()
    if new_rows != rows or not (7 < new_cols < cols):
        raise AssertionError(f"Expected a narrower grid that still fits the span; got {rows}x{cols} -> {new_rows}x{new_cols}")
    stage("resized", cols=new_cols)

    await_host("overwrite-single")
    os.write(1, csi + b"1;2H" + csi + b"38;2;223;162;59m" + block + reset)
    stage("single-erased", replacement=cpr((1, 3)))
    await_host("finish")
except Exception as error:
    record("failed", error=str(error))
finally:
    termios.tcsetattr(0, termios.TCSANOW, original)
'@

$terminal = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$temp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$backends = if ($Renderer -eq 'both') { @('opengl', 'd3d12') } else { @($Renderer) }

function Wait-Phase([string]$stage, [scriptblock]$matches) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $reportPath = Join-Path $scratch ($stage + '.json')
    $failure = Join-Path $scratch 'failed.json'
    $frame = $null
    do {
        if (Test-Path -LiteralPath $failure) {
            $errorReport = Get-Content -Raw -LiteralPath $failure | ConvertFrom-Json
            throw $errorReport.error
        }
        $process.Refresh()
        if ($process.HasExited) { throw "The $backend terminal exited before $stage." }
        if ((Test-Path -LiteralPath $reportPath) -and $process.MainWindowTitle -eq "OSC 66 fixture $stage") {
            $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
            $frame = [TextSizingWindow]::Capture($process.MainWindowHandle, $process.Id)
            if ($frame -and (& $matches $frame $report)) {
                Write-Host "PASS $backend $stage ($frame)"
                return $report
            }
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt 15)
    throw "Unexpected $backend pixels at $stage. Last frame: $frame"
}

foreach ($backend in $backends) {
    $exe = $terminal
    if ($Renderer -eq 'both' -and $backend -eq 'd3d12') {
        $exe = Join-Path (Split-Path -Parent $terminal) 'ghostty-d3d12.exe'
    }
    $exe = (Resolve-Path -LiteralPath $exe).ProviderPath
    $scratch = Join-Path $temp ('madotty-text-sizing-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $scratch
    $process = $null
    $stderr = $null
    $passed = $false
    try {
        $linuxPath = & wsl.exe --exec wslpath -u $scratch
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the test directory in WSL.' }
        $child = $childTemplate.Replace('__TEST_ROOT__', ($linuxPath.Trim() | ConvertTo-Json -Compress))
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

        $initial = Wait-Phase 'initial' {
            param($frame, $report)
            $offset = $frame.Marker.First - $frame.Single.First
            $area = $report.cell_width * $report.cell_height
            $frame.Single.Count -gt 0 -and $frame.Marker.Count -ge $area / 2 -and
                $offset -ge 2 * $report.cell_width -and $offset -le 3 * $report.cell_width -and
                $frame.MultiRuns -eq 2 -and $frame.Multi.Width -ge 2 * $report.cell_width -and
                $frame.Multi.Count -gt $area
        }
        $cellArea = $initial.cell_width * $initial.cell_height
        $xAndReplacement = {
            param($frame)
            $frame.Single.Count -gt 0 -and $frame.Marker.Count -ge $cellArea / 2 -and
                $frame.Multi.Count -eq 0 -and $frame.MultiReplacement.Count -ge $cellArea / 2
        }
        [IO.File]::WriteAllText((Join-Path $scratch 'overwrite-multi'), '')
        $multiErased = Wait-Phase 'multi-erased' $xAndReplacement
        [TextSizingWindow]::Shrink($process.MainWindowHandle, $process.Id, (8 * $initial.cell_width))
        [IO.File]::WriteAllText((Join-Path $scratch 'resize'), '')
        $resized = Wait-Phase 'resized' $xAndReplacement

        [IO.File]::WriteAllText((Join-Path $scratch 'overwrite-single'), '')
        $singleErased = Wait-Phase 'single-erased' {
            param($frame)
            $frame.Single.Count -eq 0 -and $frame.Marker.Count -ge $cellArea / 2 -and
                $frame.Multi.Count -eq 0 -and $frame.MultiReplacement.Count -ge $cellArea / 2 -and
                $frame.SingleReplacement.Count -ge $cellArea / 2
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
        Write-Output ("PASS $backend CPR {0}, {1}, {2}, {3}; resized columns {4} to {5}." -f
            ($initial.single -join ';'), ($initial.multi -join ';'), ($multiErased.replacement -join ';'),
            ($singleErased.replacement -join ';'), $initial.cols, $resized.cols)
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
