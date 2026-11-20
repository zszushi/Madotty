param(
    [Parameter(Mandatory = $true)][string]$MsiPath,
    [switch]$Gui
)

# Administrative extraction exercises the MSI cabinet without registering an
# installed product or changing the user's default terminal.
$ErrorActionPreference = 'Stop'
$MsiPath = (Get-Item -LiteralPath $MsiPath).FullName
$tempRoot = (Get-Item -LiteralPath $env:TEMP).FullName
$scratch = Join-Path $tempRoot ('madotty-msi-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$configHome = $env:XDG_CONFIG_HOME
$keepScratch = $false
try {
    $extract = Join-Path $scratch 'install'
    $log = Join-Path $scratch 'extract.log'
    $result = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
        -ArgumentList "/a `"$MsiPath`" /qn TARGETDIR=`"$extract`" /l*v `"$log`"" -WindowStyle Hidden -Wait -PassThru
    if ($result.ExitCode -ne 0) { throw "MSI extraction failed with exit code $($result.ExitCode)" }
    $exes = @(Get-ChildItem -LiteralPath $extract -Filter 'ghostty.exe' -File -Recurse)
    if ($exes.Count -ne 1) { throw 'Expected one ghostty.exe in the installer.' }
    $appDir = $exes[0].DirectoryName
    foreach ($name in @('ghostty.com', 'ghostty-d3d12.exe', 'ghostty-vulkan.exe', 'conpty.dll', 'OpenConsole.exe',
            'dxcompiler.dll', 'dxil.dll', 'LICENSE', 'settings\Madotty.Settings.exe', 'settings\coreclr.dll',
            'settings\Microsoft.UI.Xaml.dll', 'settings\App.xbf', 'settings\resources.pri',
            'settings\ja\Madotty.Settings.resources.dll',
            'share\terminfo\ghostty.terminfo', 'share\licenses\conpty\LICENSE.txt',
            'share\licenses\dxc\LICENSE-LLVM.txt', 'share\licenses\dxc\LICENSE-MS.txt',
            'share\licenses\Microsoft.NETCore.App.Runtime.win-x64\THIRD-PARTY-NOTICES.TXT',
            'share\ghostty\shell-integration\powershell\ghostty-shell-integration.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $appDir $name) -PathType Leaf)) {
            throw "Installer is missing $name"
        }
    }
    $developmentFiles = Get-ChildItem -LiteralPath $appDir -File -Recurse | Where-Object {
        $_.Extension -eq '.pdb' -or $_.Name -in @('ghostty-test.exe', 'madotty-vulkan-smoke.exe')
    }
    if ($developmentFiles) {
        throw 'Installer contains development-only output.'
    }

    $env:XDG_CONFIG_HOME = Join-Path $scratch 'config'
    $console = Join-Path $appDir 'ghostty.com'
    $version = & $console +version
    if ($LASTEXITCODE -ne 0 -or ($version -join "`n") -notmatch '^Ghostty \d+\.\d+\.\d+') {
        throw 'Installed ghostty +version failed.'
    }
    $themes = @(& $console +list-themes --plain)
    if ($LASTEXITCODE -ne 0 -or $themes.Count -lt 2) { throw 'Installed ghostty +list-themes failed.' }
    Write-Output "PASS MSI cabinet, installed CLI, $($themes.Count) bundled themes"

    if ($Gui) {
        & (Join-Path $PSScriptRoot 'test_settings.ps1') -ExePath $exes[0].FullName
        & (Join-Path $PSScriptRoot 'test_renderer_selection.ps1') -ExePath $exes[0].FullName -RequireVulkan
    }
} catch {
    $keepScratch = $true
    Write-Warning "Installer test files retained at $scratch"
    throw
} finally {
    $env:XDG_CONFIG_HOME = $configHome
    $item = Get-Item -LiteralPath $scratch -Force
    if (-not $keepScratch -and $item.Parent.FullName -eq $tempRoot -and
        -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}
