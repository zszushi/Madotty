param([Parameter(Mandatory)][string]$ExePath)

# The child talks to the terminal through ConPTY and WSL, without desktop input.
# The only Shell query is tied to the temporary terminal's callback HWND.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class KittyDesktopWindows {
    const uint DesktopNotificationId = 1; // NOTIF_DESKTOP_UID in the Win32 app

    [StructLayout(LayoutKind.Sequential)]
    struct IconIdentifier { public uint Size; public IntPtr Window; public uint Id; public Guid Guid; }

    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string name);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);

    [DllImport("shell32.dll")]
    static extern int Shell_NotifyIconGetRect(ref IconIdentifier icon, out Rect location);

    public static bool HasNotification(int pid) {
        IntPtr window = IntPtr.Zero;
        while ((window = FindWindowEx(new IntPtr(-3), window, "GhosttyMsg", "GhosttyMsg")) != IntPtr.Zero) {
            uint owner;
            if (GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)pid) continue;
            var icon = new IconIdentifier {
                Size = (uint)Marshal.SizeOf(typeof(IconIdentifier)), Window = window, Id = DesktopNotificationId
            };
            Rect location;
            return Shell_NotifyIconGetRect(ref icon, out location) == 0;
        }
        throw new InvalidOperationException("The test terminal's message window was not found.");
    }
}
'@

$child = @'
import json
import os
import select
import termios
import time
import tty
from pathlib import Path

root = Path(__TEST_ROOT__)
checks = []
esc = b"\x1b"
st = esc + b"\\"
bel = b"\x07"
original = termios.tcgetattr(0)

def osc(number, data, end=st):
    return esc + b"]" + number + b";" + data + end

def receive(seconds, until=None):
    end = time.monotonic() + seconds
    data = bytearray()
    while len(data) < 1024:
        remaining = end - time.monotonic()
        if remaining <= 0 or not select.select([0], [], [], remaining)[0]:
            break
        chunk = os.read(0, 1024 - len(data))
        if not chunk:
            break
        data.extend(chunk)
        if until and data.endswith(until):
            break
    return bytes(data)

def no_reply(description):
    data = receive(0.4)
    if data:
        raise AssertionError(f"{description}: unexpected reply {data!r}")
    checks.append(description)

def ask(description, query, expected, end=st):
    os.write(1, query)
    reply = receive(2, end)
    if reply != expected:
        raise AssertionError(f"{description}: expected {expected!r}, got {reply!r}")
    checks.append(description)
    return reply

def shape(description, expected):
    ask(description, osc(b"22", b"?__current__"), osc(b"22", expected))

def report(stage, error=None):
    data = json.dumps({"stage": stage, "checks": checks, "error": error})
    pending = root / (stage + ".tmp")
    pending.write_text(data, encoding="utf-8")
    pending.rename(root / (stage + ".json"))

def await_host(name):
    deadline = time.monotonic() + 12
    while not (root / name).exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Windows test did not advance stage {name}")
        time.sleep(0.05)

try:
    tty.setraw(0)
    receive(0.3)
    reply = ask("OSC 22 default, grabbed and shape support",
                osc(b"22", b"?__current__,__default__,__grabbed__,pointer,crosshair,no-such-name"),
                osc(b"22", b"0,text,default,1,1,0"))
    os.write(1, reply)
    no_reply("OSC 22 reflected support reply stays silent")
    os.write(1, osc(b"22", b"=pointer"))
    shape("OSC 22 sets pointer", b"pointer")
    os.write(1, osc(b"22", b">wait,crosshair"))
    shape("OSC 22 pushes multiple shapes in order", b"crosshair")
    os.write(1, osc(b"22", b"<ignored"))
    shape("OSC 22 pops one shape", b"wait")
    os.write(1, esc + b"[?1049h")
    shape("OSC 22 alternate screen starts with its own stack", b"0")
    os.write(1, osc(b"22", b"crosshair"))
    shape("OSC 22 sets the alternate screen's stack independently", b"crosshair")
    os.write(1, esc + b"[?1049l")
    shape("OSC 22 restores the main screen's stack", b"wait")
    os.write(1, osc(b"22", b"<"))
    shape("OSC 22 restores the underlying pointer", b"pointer")
    os.write(1, osc(b"22", b""))
    shape("OSC 22 resets the current pointer", b"0")

    for end, name in [(st, "ST"), (bel, "BEL")]:
        query = osc(b"99", b"i=madotty-query:p=?;", end)
        expected = osc(b"99", b"i=madotty-query:p=?;o=always,unfocused,invisible:p=title,body", end)
        reply = ask(f"OSC 99 reports capabilities with {name}", query, expected, end)
        os.write(1, reply)
        no_reply(f"OSC 99 reflected {name} reply stays silent")
    report("queried")
    await_host("send-title")
    os.write(1, osc(b"99", b"i=madotty-test:d=0;Madotty notification test"))
    report("title")
    await_host("send-body")
    os.write(1, osc(b"99", b"i=madotty-test:p=body:o=always;OSC 99 integration test"))
    no_reply("OSC 99 delivery stays silent")
    report("delivered")
    await_host("finish")
except Exception as error:
    report("failed", str(error))
finally:
    termios.tcsetattr(0, termios.TCSANOW, original)
'@

$terminal = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$temp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$scratch = Join-Path $temp ('madotty-kitty-desktop-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$process = $null
$stderr = $null
$passed = $false

function Wait-Stage([string]$expected) {
    $failure = Join-Path $scratch 'failed.json'
    $report = Join-Path $scratch ($expected + '.json')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-Path -LiteralPath $failure) {
            $errorReport = Get-Content -Raw -LiteralPath $failure | ConvertFrom-Json
            throw $errorReport.error
        }
        if (Test-Path -LiteralPath $report) {
            return (Get-Content -Raw -LiteralPath $report | ConvertFrom-Json)
        }
        if ($process.HasExited) { throw "Terminal exited before stage $expected." }
        Start-Sleep -Milliseconds 50
    } while ($timer.Elapsed.TotalSeconds -lt 20)
    throw "Timed out waiting for stage $expected."
}

function Assert-NoNotification([string]$phase) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ([KittyDesktopWindows]::HasNotification($process.Id)) {
            throw "A notification was unexpectedly registered $phase."
        }
        Start-Sleep -Milliseconds 50
    } while ($timer.Elapsed.TotalMilliseconds -lt 300)
}

try {
    $linuxPath = & wsl.exe --exec wslpath -u $scratch
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the test directory in WSL.' }
    $child = $child.Replace('__TEST_ROOT__', ($linuxPath.Trim() | ConvertTo-Json -Compress))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($child))
    $bootstrap = "exec(__import__('base64').b64decode('$encoded'))"
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $terminal
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
        ' --desktop-notifications=true -e wsl.exe --exec python3 -c ' + $bootstrap

    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $stderr = $process.StandardError.ReadToEndAsync()

    $null = Wait-Stage 'queried'
    Assert-NoNotification 'after queries and echoed replies'
    [IO.File]::WriteAllText((Join-Path $scratch 'send-title'), '')
    $null = Wait-Stage 'title'
    Assert-NoNotification 'after the incomplete title'
    [IO.File]::WriteAllText((Join-Path $scratch 'send-body'), '')

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not [KittyDesktopWindows]::HasNotification($process.Id)) {
        if ($timer.Elapsed.TotalSeconds -ge 4) { throw 'Windows Shell did not register the completed OSC 99 notification.' }
        Start-Sleep -Milliseconds 50
    }
    $result = Wait-Stage 'delivered'
    [IO.File]::WriteAllText((Join-Path $scratch 'finish'), '')
    if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) {
        throw 'The test terminal did not exit cleanly.'
    }
    foreach ($description in $result.checks) { Write-Output "PASS $description" }
    Write-Output 'PASS Windows Shell registered the completed OSC 99 notification.'
    $passed = $true
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
