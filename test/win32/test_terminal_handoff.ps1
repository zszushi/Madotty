param(
    [Parameter(Mandatory)][string]$ExePath,
    [ValidateSet('OpenGL', 'DirectX12', 'Vulkan')][string]$Renderer
)

# Drive the real COM receiver with a fixture-owned console peer. The peer
# supplies native handles without changing the current Windows terminal default.
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Run this test with 64-bit PowerShell.' }
Add-Type -Path (Join-Path $PSScriptRoot 'terminal_handoff_client.cs')
$exe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$proxy = Join-Path (Split-Path -Parent $exe) 'Madotty.TerminalHandoffProxy.dll'
if (-not (Test-Path -LiteralPath $proxy -PathType Leaf)) { throw "Missing handoff proxy $proxy" }

$class = [TerminalHandoffClient]::ServerClass.ToString('B')
if (Test-Path -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$class\LocalServer32") {
    throw 'Use a test desktop without a registered Madotty local server so COM can only activate the launched fixture.'
}
$servers = Get-CimInstance Win32_Process -Filter "Name = 'ghostty.exe' OR Name = 'ghostty-d3d12.exe' OR Name = 'ghostty-vulkan.exe'" |
    Where-Object { $_.CommandLine -match '(?i)(^|\s)-Embedding(?=\s|$)' }
if ($servers) { throw 'An existing Ghostty embedding process owns the production COM class.' }

$temp = (Resolve-Path -LiteralPath $env:TEMP).ProviderPath
$scratch = Join-Path $temp ('madotty-terminal-handoff-' + [Guid]::NewGuid().ToString('N'))
$config = Join-Path $scratch 'ghostty'
$sentinel = Join-Path $scratch 'unexpected-shell'
$process = $null
$peer = $null
$stderr = $null
$passed = $false

function Wait-TestResult([string]$stage, [scriptblock]$probe) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Embedding process exited with $($process.ExitCode) during $stage." }
        $result = & $probe
        if ($result) { return $result }
        Start-Sleep -Milliseconds 75
    } while ($timer.Elapsed.TotalSeconds -lt 12)
    throw "Timed out waiting for $stage."
}

try {
    $null = New-Item -ItemType Directory -Path $config
    $unexpectedCommand = "[IO.File]::WriteAllText('" + $sentinel.Replace("'", "''") + "', 'started')"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($unexpectedCommand))
    @(
        'auto-update = off'
        'shell-integration = none'
        'window-save-state = never'
        'confirm-close-surface = false'
        'quit-after-last-window-closed = true'
        'background = 223144'
        'background-opacity = 1'
        'alpha-blending = linear-corrected'
        'font-family = Cascadia Code'
        'font-size = 12'
        'adjust-cell-width = 1'
        'adjust-cell-height = 1'
        'window-padding-x = 0'
        'window-padding-y = 0'
        'window-show-tab-bar = never'
        'window-width = 48'
        'window-height = 20'
        "command = powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
    ) | Set-Content -LiteralPath (Join-Path $config 'config.ghostty') -Encoding ASCII

    $peer = [TerminalHandoffClient]::new($proxy, (Join-Path $scratch 'reference'))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.Arguments = '-Embedding'
    $start.WorkingDirectory = $scratch
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $scratch
    $start.EnvironmentVariables['XDG_STATE_HOME'] = $scratch
    $start.EnvironmentVariables.Remove('GHOSTTY_RESOURCES_DIR')
    $start.EnvironmentVariables.Remove('MADOTTY_RENDERER_HANDOFF')
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $stderr = $process.StandardError.ReadToEndAsync()

    $null = Wait-TestResult 'ITerminalHandoff3 COM activation' { $peer.TryConnect() }
    if ($process.MainWindowHandle -ne [IntPtr]::Zero -or (Test-Path -LiteralPath $sentinel)) {
        throw 'Embedding mode started a window or configured shell before the handoff.'
    }

    $title = 'Madotty console handoff ' + [Guid]::NewGuid().ToString('N')
    $peer.Establish($title, 60, 18)
    $window = Wait-TestResult 'owned handoff window and startup title' {
        if ($process.MainWindowTitle -eq $title) { $process.MainWindowHandle }
    }
    $initialGrid = Wait-TestResult 'first ConPTY startup resize signal' { $peer.ReadGrid() }
    if ($initialGrid -ne '60x18') { throw "First ConPTY resize must be 60x18. Received $initialGrid." }
    $null = Wait-TestResult 'release of the adopted ConPTY lifetime reference' { $peer.ConsoleReferenceReleased() }

    $peer.PaintAndQuery()
    $reply = [Text.StringBuilder]::new()
    $expectedReply = [string][char]27 + '[3;7R'
    $null = Wait-TestResult 'CPR through the handed-off input pipe' {
        $null = $reply.Append($peer.ReadReply())
        if ($reply.ToString().Contains($expectedReply)) { return $true }
        if ($reply.Length -gt 4096) { throw 'Unexpectedly large reply from the terminal.' }
    }
    if ($reply.ToString() -cne $expectedReply) {
        throw "Unexpected input pipe data $([BitConverter]::ToString([Text.Encoding]::ASCII.GetBytes($reply.ToString())))"
    }
    $initial = Wait-TestResult 'exact foreground and background pixels' {
        $frame = [TerminalHandoffWindow]::Capture($window, $process.Id)
        if ($frame.HasFixtureColors -and [Math]::Floor($frame.Width / $frame.CellWidth) -eq 60 -and
            [Math]::Floor($frame.Height / $frame.CellHeight) -eq 18) { return $frame }
        Write-Verbose "Initial frame $frame"
    }

    $extraGrid = $peer.ReadGrid()
    if ($extraGrid) { throw "Unexpected ConPTY startup resize $extraGrid before the window was resized." }
    Write-Output "PASS COM handoff, single $initialGrid startup resize, native input/output and rendered VT ($initial)."
    [TerminalHandoffWindow]::Shrink($window, $process.Id, (8 * $initial.CellWidth), (2 * $initial.CellHeight))
    $resizedGrid = Wait-TestResult 'ConPTY signal after resizing the window' { $peer.ReadGrid() }
    if ($resizedGrid -ne '52x16') { throw "Expected the next ConPTY resize to be 52x16. Received $resizedGrid." }
    $resized = Wait-TestResult 'handed-off content preserved after resize' {
        $frame = [TerminalHandoffWindow]::Capture($window, $process.Id)
        if ($frame.HasFixtureColors -and $frame.Ink -eq $initial.Ink -and $frame.Green -eq $initial.Green -and
            $frame.Width -eq $initial.Width - 8 * $initial.CellWidth -and
            $frame.Height -eq $initial.Height - 2 * $initial.CellHeight) { return $frame }
        Write-Verbose "Resized frame $frame"
    }

    $peer.EndOutput()
    if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) {
        throw 'The embedding process did not exit cleanly on console output EOF.'
    }
    if (Test-Path -LiteralPath $sentinel) { throw 'The configured shell ran during console attachment.' }
    if ($Renderer -and $stderr.GetAwaiter().GetResult() -notmatch "renderer=[^\r\n]*\b$Renderer\b") {
        throw "Expected the $Renderer renderer."
    }
    $passed = $true
    Write-Output "PASS $resizedGrid native resize preserved content ($resized) and output EOF closed the attached terminal."
} finally {
    if ($peer) { $peer.Dispose() }
    if ($process) {
        if (-not $process.HasExited) {
            $null = $process.CloseMainWindow()
            if (-not $process.WaitForExit(3000)) {
                $process.Kill()
                $null = $process.WaitForExit(3000)
            }
        }
        $process.Dispose()
    }
    if (-not $passed -and $stderr -and $stderr.IsCompleted) {
        $stderr.GetAwaiter().GetResult() -split '\r?\n' | Where-Object Length -lt 1000 |
            Select-Object -Last 30 | Write-Host
    }
    if (Test-Path -LiteralPath $scratch) {
        $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
        if ($resolved -eq $scratch -and (Split-Path -Parent $resolved) -eq $temp) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
