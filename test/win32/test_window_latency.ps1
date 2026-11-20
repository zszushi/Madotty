param(
    [string]$BuildDir,
    [string]$OutputDirectory,
    [string[]]$Backend = @('opengl','d3d12','vulkan'),
    [ValidateSet('text','glow')][string[]]$Mode = @('text'),
    [int]$Seconds = 3,
    [int]$Trials = 1,
    [switch]$Produce,
    [string]$TpbPath,
    [string]$ShaderPath
)

$ErrorActionPreference = 'Stop'
if ($Produce) {
    $esc = [string][char]27
    $frames = foreach ($color in '240;30;90','20;210;140','70;90;245','210;150;20') {
        $frame = [Text.StringBuilder]::new($esc + '[?2026h')
        for ($row = 1; $row -le 40; $row++) {
            [void]$frame.Append($esc + '[' + $row + ';1H' + $esc + '[48;2;' + $color + 'm' + (' ' * 120))
        }
        $frame.ToString() + $esc + '[0m' + $esc + '[?2026l'
    }
    $pipe = [IO.Pipes.NamedPipeServerStream]::new($env:MADOTTY_LATENCY_PIPE,[IO.Pipes.PipeDirection]::InOut,1)
    try {
        [Console]::Write($esc + '[?25l' + $esc + '[?7l')
        [Console]::Out.Flush()
        $pipe.WaitForConnection()
        $writer = [IO.BinaryWriter]::new($pipe)
        $reader = [IO.BinaryReader]::new($pipe)
        $geometry = $Host.UI.RawUI.WindowSize
        $writer.Write([int]$geometry.Width)
        $writer.Write([int]$geometry.Height)
        $writer.Flush()
        $duration = $reader.ReadInt32()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $frequency = [double][Diagnostics.Stopwatch]::Frequency
        $count = 0
        $next = 0.0
        while ($clock.Elapsed.TotalSeconds -lt $duration) {
            [Console]::Write($frames[$count % $frames.Count])
            [Console]::Out.Flush()
            $count++
            $next += $frequency / 60
            $late = $clock.ElapsedTicks - $next
            if ($late -gt $frequency / 60) { $next = $clock.ElapsedTicks + $frequency / 60 }
            while ($clock.ElapsedTicks -lt $next) {
                $remaining = ($next - $clock.ElapsedTicks) * 1000 / $frequency
                if ($remaining -gt 2) { [Threading.Thread]::Sleep([int][Math]::Floor($remaining - 1)) }
                else { [void][Threading.Thread]::Yield() }
            }
        }
        $writer.Write([int]$count)
        $writer.Flush()
    } finally {
        $pipe.Dispose()
    }
    return
}

if (-not $BuildDir -or -not $OutputDirectory -or $Seconds -lt 1 -or $Trials -lt 1) {
    throw 'Specify -BuildDir and -OutputDirectory, and positive -Seconds and -Trials values.'
}
$BuildDir = (Resolve-Path -LiteralPath $BuildDir).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$config = [IO.File]::ReadAllText((Join-Path $workspace 'benchmark-results\2026-11-20\config.ghostty'))
if ($Mode -contains 'glow') {
    if (!$ShaderPath) { throw 'Pass -ShaderPath for the glow workload.' }
    $shader = (Resolve-Path -LiteralPath $ShaderPath).Path.Replace('\','/')
}
if ($TpbPath) {
    $tpb = (Get-Item -LiteralPath $TpbPath -ErrorAction Stop).FullName
} else {
    $command = Get-Command tpb.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'Pass -TpbPath with the path to tpb.exe, or add tpb.exe to PATH.' }
    $tpb = $command.Source
}
$script = $PSCommandPath

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class MadottyWindowLatency {
    delegate bool EnumProc(IntPtr window, IntPtr argument);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left,Top,Right,Bottom; }
    [DllImport("user32")] static extern bool EnumWindows(EnumProc it,IntPtr arg);
    [DllImport("user32")] static extern bool EnumChildWindows(IntPtr parent,EnumProc it,IntPtr arg);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd,StringBuilder name,int capacity);
    [DllImport("user32")] static extern bool GetClientRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpi);
    [DllImport("user32",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint msg,IntPtr w,IntPtr l,uint flags,uint timeout,out IntPtr result);
    static bool Owns(IntPtr hwnd,uint pid) { uint found; return GetWindowThreadProcessId(hwnd,out found)!=0 && found==pid; }
    static IntPtr FindWindow(uint pid,string kind,IntPtr parent) {
        IntPtr found=IntPtr.Zero;
        EnumProc each=(hwnd,arg)=>{
            if(!Owns(hwnd,pid)||!IsWindowVisible(hwnd)) return true;
            var name=new StringBuilder(96);
            GetClassName(hwnd,name,name.Capacity);
            if(name.ToString()!=kind) return true;
            found=hwnd;
            return false;
        };
        if(parent==IntPtr.Zero) EnumWindows(each,IntPtr.Zero);
        else if(Owns(parent,pid)) EnumChildWindows(parent,each,IntPtr.Zero);
        return found;
    }
    public static IntPtr Pane(uint pid) {
        var owner=FindWindow(pid,"GhosttyWindow",IntPtr.Zero);
        return owner==IntPtr.Zero ? IntPtr.Zero : FindWindow(pid,"GhosttyTerminal",owner);
    }
    public static int[] Size(uint pid,IntPtr pane) {
        var context=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect rect; if(!Owns(pane,pid)||!GetClientRect(pane,out rect))throw new InvalidOperationException("Fixture HWND is unavailable."); return new []{rect.Right,rect.Bottom}; }
        finally { if(context!=IntPtr.Zero)SetThreadDpiAwarenessContext(context); }
    }
    public sealed class Sample { public double ms; public bool answered; public int error; }
    public static Sample[] Measure(uint pid,IntPtr pane,int seconds) {
        var result = new List<Sample>();
        var clock = Stopwatch.StartNew();
        while(clock.Elapsed.TotalSeconds<seconds) {
            if(!Owns(pane,pid)) throw new InvalidOperationException("Fixture HWND ownership changed.");
            long start=Stopwatch.GetTimestamp();
            IntPtr ignored;
            bool answered=SendMessageTimeout(pane,0,IntPtr.Zero,IntPtr.Zero,3,100,out ignored)!=IntPtr.Zero;
            int error=answered?0:Marshal.GetLastWin32Error();
            result.Add(new Sample { ms=(Stopwatch.GetTimestamp()-start)*1000.0/Stopwatch.Frequency, answered=answered, error=error });
            Thread.Sleep(11+((result.Count*11)%9));
        }
        return result.ToArray();
    }
}
'@

function Start-Fixture($exe,$directory,$configPath,$token,[string[]]$arguments) {
    $launch = [Diagnostics.ProcessStartInfo]::new($exe)
    $launch.WorkingDirectory = $directory
    $launch.UseShellExecute = $false
    $launch.CreateNoWindow = $true
    $launch.RedirectStandardError = $true
    $launch.Environment['XDG_CONFIG_HOME'] = $directory
    $launch.Environment['XDG_STATE_HOME'] = $directory
    $launch.Environment.Remove('MADOTTY_RENDERER_HANDOFF') | Out-Null
    $launch.Environment.Remove('GHOSTTY_RESOURCES_DIR') | Out-Null
    $launch.Environment['MADOTTY_LATENCY_PIPE'] = $token
    foreach ($arg in @('--config-default-files=false', "--config-file=$configPath", '-e') + $arguments) {
        $launch.ArgumentList.Add($arg)
    }
    [Diagnostics.Process]::Start($launch)
}

function Stop-Fixture($process) {
    if (-not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(2000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(3000)
        }
    }
    $process.Dispose()
}

function Read-Int32($pipe) {
    $data = [byte[]]::new(4)
    for ($offset=0; $offset -lt $data.Length;) {
        $read = $pipe.ReadAsync($data,$offset,$data.Length-$offset)
        if (-not $read.Wait(16000) -or $read.Result -eq 0) { throw 'Fixture pipe closed or failed to respond.' }
        $offset += $read.Result
    }
    [BitConverter]::ToInt32($data,0)
}

$results = [Collections.Generic.List[object]]::new()
for ($trial=1; $trial -le $Trials; $trial++) {
    foreach ($workload in $Mode) {
        foreach ($renderer in $Backend) {
            $suffix = switch ($renderer) { 'opengl' {''} 'd3d12' {'-d3d12'} 'vulkan' {'-vulkan'} default {throw "Unknown backend: $renderer"} }
            $rendererName = switch ($renderer) { 'opengl' {'OpenGL'} 'd3d12' {'DirectX12'} 'vulkan' {'Vulkan'} }
            $exe = (Resolve-Path -LiteralPath (Join-Path $BuildDir "ghostty$suffix.exe")).Path
            $directory = Join-Path $OutputDirectory "$renderer-$workload-$trial"
            if (Test-Path -LiteralPath $directory) { throw "Trial directory already exists: $directory" }
            [void][IO.Directory]::CreateDirectory($directory)
            $settings = Join-Path $directory 'fixture.ghostty'
            $shaderSettings = if ($workload -eq 'glow') { "`ncustom-shader = $shader`ncustom-shader-animation = always" } else { '' }
            [IO.File]::WriteAllText($settings,$config.TrimEnd()+"`nwindow-show-tab-bar = never`ncursor-style-blink = false"+$shaderSettings+"`n")

            $probePath = Join-Path $directory 'tpb-preflight.json'
            $probe = Start-Fixture $exe $directory $settings 'preflight' @($tpb,'--no-bench','--plain','--json',$probePath)
            $probeError = $probe.StandardError.ReadToEndAsync()
            try {
                if (-not $probe.WaitForExit(12000) -or $probe.ExitCode -ne 0) { throw "TPB preflight failed for $renderer" }
                [IO.File]::WriteAllText((Join-Path $directory 'tpb-preflight.stderr.log'),$probeError.GetAwaiter().GetResult())
                $geometry = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
                if ($geometry.aborted -or $geometry.tty.cols -ne 120 -or $geometry.tty.rows -ne 40 -or
                    ($geometry.identity.cell_px -join 'x') -ne '10x20' -or ($geometry.identity.text_area_px -join 'x') -ne '1200x800') {
                    throw "Invalid TPB preflight geometry for $renderer. See $probePath."
                }
            } finally { Stop-Fixture $probe }

            $token = 'madotty-window-latency-' + [guid]::NewGuid().ToString('N')
            $pipe = [IO.Pipes.NamedPipeClientStream]::new('.',$token,[IO.Pipes.PipeDirection]::InOut)
            $terminal = Start-Fixture $exe $directory $settings $token @('powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,'-Produce')
            $stderr = $terminal.StandardError.ReadToEndAsync()
            try {
                $pipe.Connect(12000)
                $fixtureGrid = @((Read-Int32 $pipe),(Read-Int32 $pipe))
                $pane = [MadottyWindowLatency]::Pane($terminal.Id)
                if ($pane -eq [IntPtr]::Zero -or ($fixtureGrid -join 'x') -ne '120x40' -or
                    ([MadottyWindowLatency]::Size($terminal.Id,$pane)-join 'x') -ne '1200x800') { throw "Invalid visible fixture geometry ($fixtureGrid) for $renderer" }

                $duration = $Seconds + 2
                $start = [BitConverter]::GetBytes([int]$duration)
                $pipe.Write($start,0,$start.Length)
                $pipe.Flush()
                Start-Sleep -Milliseconds 1000
                $before = $terminal.TotalProcessorTime.TotalMilliseconds
                $samples = [MadottyWindowLatency]::Measure($terminal.Id,$pane,$Seconds)
                $cpu = $terminal.TotalProcessorTime.TotalMilliseconds - $before
                $frames = Read-Int32 $pipe
                if (-not $terminal.WaitForExit(5000) -or $terminal.ExitCode -ne 0) { throw "Fixture did not close cleanly for $renderer" }
                $log = $stderr.GetAwaiter().GetResult()
                if ($log -notmatch "info: renderer=.*$rendererName" -or $log -match '(?im)^error|device removed|status=\.unhealthy') {
                    throw "Backend failed or renderer mismatch for $renderer"
                }
                if ($workload -eq 'glow' -and ($log -notmatch '(?i)loaded custom shader path=.*glow\.glsl' -or
                    $log -match '(?im)^warning.*(?:custom shader|DXC).*(?:failed|need|does not match)|^warning.*(?:error loading custom shaders|unable to initialize DXC|invalid Vulkan custom shader)')) {
                    throw "Glow shader failed to load for $renderer"
                }
                $ordered = @($samples | Where-Object answered | ForEach-Object ms | Sort-Object)
                if ($ordered.Count -eq 0) { throw "No HWND round trips completed for $renderer" }
                $record = [ordered]@{
                    backend=$renderer; mode=$workload; trial=$trial; duration_s=$Seconds; grid=$fixtureGrid; cell_px=@(10,20); viewport_px=@(1200,800)
                    exe_sha256=(Get-FileHash -LiteralPath $exe).Hash; config_sha256=(Get-FileHash -LiteralPath $settings).Hash
                    tpb_sha256=(Get-FileHash -LiteralPath $tpb).Hash; shader_sha256=if ($workload -eq 'glow') {(Get-FileHash -LiteralPath $shader).Hash} else {$null}
                    process_cpu_ms=$cpu; producer_fps=[Math]::Round($frames/$duration,2); timeouts=$samples.Count-$ordered.Count; completed=$ordered.Count
                    p50_ms=$ordered[[int][Math]::Ceiling($ordered.Count*.50)-1]; p95_ms=$ordered[[int][Math]::Ceiling($ordered.Count*.95)-1]
                    p99_ms=$ordered[[int][Math]::Ceiling($ordered.Count*.99)-1]; max_ms=$ordered[-1]; samples=$samples
                }
                $record | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $directory 'latency.json') -Encoding utf8
                $results.Add([pscustomobject]$record)
                "{0}/{1}/{2}: p95 {3:F3} ms, p99 {4:F3} ms, failed {5}/{6}, producer {7:F1} fps" -f $renderer,$workload,$trial,$record.p95_ms,$record.p99_ms,$record.timeouts,$samples.Count,$record.producer_fps
            } finally {
                $pipe.Dispose()
                Stop-Fixture $terminal
                if($stderr.Wait(1500)){[IO.File]::WriteAllText((Join-Path $directory 'latency.stderr.log'),$stderr.Result)}
            }
        }
    }
}
$results | Select-Object backend,mode,trial,producer_fps,process_cpu_ms,timeouts,completed,p50_ms,p95_ms,p99_ms,max_ms |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding utf8
