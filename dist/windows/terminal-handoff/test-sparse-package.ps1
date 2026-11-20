#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Catalog', 'Capture', 'Launch', 'Restored')][string]$Phase = 'Catalog',
    [string]$InstallDirectory,
    [string]$BaselinePath,
    [switch]$DisposableVM
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this smoke with Windows PowerShell 5.1.' }
$packageName = 'Madotty.TerminalHandoff'
$consoleId = [Guid]'DA74EFEB-11F3-4B6A-8944-E5021D6E02FF'
$terminalId = [Guid]'A3A39CB0-46F7-4D5D-954E-F311DAE8EB6A'

function Get-EffectiveDelegationPair {
    $console = $terminal = [Guid]::Empty
    $builtInConsole = [Guid]'B23D10C0-E52E-411E-9D5B-C09FDF709C7D'
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Console\%%Startup')
    if ($key) {
        try {
            [void][Guid]::TryParseExact([string]$key.GetValue('DelegationConsole'), 'B', [ref]$console)
            [void][Guid]::TryParseExact([string]$key.GetValue('DelegationTerminal'), 'B', [ref]$terminal)
        } finally {
            $key.Dispose()
        }
    }
    # The host treats an absent/default member as "Let Windows decide".
    if ($console -eq [Guid]::Empty -or $terminal -eq [Guid]::Empty) {
        $console = $terminal = [Guid]::Empty
    } elseif ($console -eq $builtInConsole -or $terminal -eq $builtInConsole) {
        $console = $terminal = $builtInConsole
    }
    [pscustomobject]@{ Console = $console; Terminal = $terminal }
}

function Assert-Catalog {
    $package = @(Get-AppxPackage -Name $packageName)
    if ($package.Count -ne 1 -or $package[0].Architecture -ne 'X64') {
        throw "Expected one x64 $packageName package for the current user."
    }
    $family = $package[0].PackageFamilyName
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $catalogType = [Windows.ApplicationModel.AppExtensions.AppExtensionCatalog, Windows.ApplicationModel.AppExtensions, ContentType=WindowsRuntime]
    $extensionType = [Windows.ApplicationModel.AppExtensions.AppExtension, Windows.ApplicationModel.AppExtensions, ContentType=WindowsRuntime]
    $extensionList = [System.Collections.Generic.IReadOnlyList[object]].GetGenericTypeDefinition().MakeGenericType($extensionType)
    $propertySet = [Windows.Foundation.Collections.IPropertySet, Windows.Foundation, ContentType=WindowsRuntime]
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
        $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -like 'IAsyncOperation*'
    } | Select-Object -First 1

    $expected = [ordered]@{
        'com.microsoft.windows.console.host' = $consoleId
        'com.microsoft.windows.terminal.host' = $terminalId
    }
    foreach ($contract in $expected.Keys) {
        $operation = $catalogType::Open($contract).FindAllAsync()
        $task = $asTask.MakeGenericMethod($extensionList).Invoke($null, @($operation))
        if (-not $task.Wait(10000)) { throw "Timed out reading $contract." }
        $matching = @($task.Result | Where-Object { $_.Package.Id.FamilyName -ceq $family })
        if ($matching.Count -ne 1) { throw "Expected one $contract extension for $family." }

        $operation = $matching[0].GetExtensionPropertiesAsync()
        $task = $asTask.MakeGenericMethod($propertySet).Invoke($null, @($operation))
        if (-not $task.Wait(10000)) { throw "Timed out reading $contract properties." }
        $guid = [Guid]$task.Result['Clsid']['#text']
        if ($guid -ne $expected[$contract]) { throw "Wrong CLSID for $contract ($guid)." }
        Write-Output "PASS $family $contract $guid"
    }
}

function Get-ProcessAtPath([string]$Path) {
    Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Path)) -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -ieq $Path }
}

function Assert-NativeLaunch {
    if (-not $DisposableVM) { throw 'Launch requires -DisposableVM in an isolated Windows guest.' }
    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($env:USERNAME -ne 'WDAGUtilityAccount' -and
        $system.Manufacturer -notmatch 'VMware|QEMU|Xen|Parallels' -and
        $system.Model -notmatch 'Virtual Machine|VirtualBox|KVM|HVM domU') {
        throw 'Launch requires a supported virtual machine or Windows Sandbox.'
    }
    if (-not $InstallDirectory) { throw 'Launch requires -InstallDirectory using the registered external path.' }
    $install = (Resolve-Path -LiteralPath $InstallDirectory).ProviderPath
    $consoleExe = (Resolve-Path -LiteralPath (Join-Path $install 'Madotty.OpenConsole.exe')).ProviderPath
    $terminalExe = Join-Path $install 'Madotty.Terminal.exe'
    if (-not (Test-Path -LiteralPath $terminalExe)) { $terminalExe = Join-Path $install 'ghostty.exe' }
    $terminalExe = (Resolve-Path -LiteralPath $terminalExe).ProviderPath
    $pair = Get-EffectiveDelegationPair
    if ($pair.Console -ne $consoleId -or $pair.Terminal -ne $terminalId) {
        throw 'Choose Madotty in the Windows default terminal dropdown before running Launch.'
    }
    if ((Get-ProcessAtPath $consoleExe) -or (Get-ProcessAtPath $terminalExe)) {
        throw 'Close the staged Madotty GUI and console delegate before checking cold activation.'
    }
    Assert-Catalog

    Add-Type -Path (Join-Path $PSScriptRoot 'NativeConsoleProbe.cs')
    $token = [Guid]::NewGuid().ToString('N')
    $outputTitle = 'Madotty smoke output ' + $token
    $work = Join-Path $env:TEMP ('MadottyDefterm-' + $token)
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $command = Join-Path $work 'native-console.cmd'
    $ready = Join-Path $work 'client.ready'
    $client = $null
    try {
        @('@echo off', "title $outputTitle", ">client.ready echo $token", "echo $outputTitle", 'pause >nul') |
            Set-Content -LiteralPath $command -Encoding ASCII
        $client = [NativeConsoleProbe]::Start($work, ('Madotty smoke startup ' + $token))
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            $console = Get-ProcessAtPath $consoleExe | Select-Object -First 1
            $terminal = Get-ProcessAtPath $terminalExe | Where-Object {
                $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle.Contains($outputTitle)
            } | Select-Object -First 1
            if ($console -and $terminal -and (Test-Path -LiteralPath $ready -PathType Leaf) -and
                (Get-Content -LiteralPath $ready -Raw).Trim() -ceq $token) {
                Write-Output "PASS cold native client $($client.Id) via console $($console.Id) and terminal $($terminal.Id)"
                return
            }
            if ($client.Exited) { throw 'The native cmd.exe client exited before delegation completed.' }
            Start-Sleep -Milliseconds 100
        } while ($clock.Elapsed.TotalSeconds -lt 30)
        throw 'Timed out waiting for the installed console delegate, terminal window title, and native client marker.'
    } finally {
        if ($client) { $client.Dispose() }
        foreach ($file in $command, $ready) {
            if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file }
        }
        [IO.Directory]::Delete($work)
    }
}

switch ($Phase) {
    'Catalog' { Assert-Catalog }
    'Launch' { Assert-NativeLaunch }
    default {
        if (-not $BaselinePath) { throw "$Phase requires -BaselinePath." }
        $machine = [Environment]::MachineName
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $pair = Get-EffectiveDelegationPair
        if ($Phase -eq 'Capture') {
            [pscustomobject]@{ Machine = $machine; User = $user; Pair = $pair } | ConvertTo-Json |
                Out-File -LiteralPath $BaselinePath -Encoding UTF8 -NoClobber
            Write-Output "Captured effective delegation pair $($pair.Console) / $($pair.Terminal)."
        } else {
            $original = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
            if ($original.Machine -cne $machine -or $original.User -cne $user -or
                [Guid]$original.Pair.Console -ne $pair.Console -or [Guid]$original.Pair.Terminal -ne $pair.Terminal) {
                throw 'The effective default terminal pair differs from the baseline for this machine and user.'
            }
            Write-Output 'PASS the original default terminal choice was restored.'
        }
    }
}
