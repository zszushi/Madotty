param(
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\..\..\zig-out'),
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\..\..\zig-out\madotty-openconsole-src')
)

$ErrorActionPreference = 'Stop'
$sourceTag = 'v1.25.2733.0'
$sourceCommit = 'dc8ae365847d41f62d1ebca93815bb00959bc12f'
$consoleClsid = [Guid]'DA74EFEB-11F3-4B6A-8944-E5021D6E02FF'
$patch = Join-Path $PSScriptRoot 'openconsole-stage1.patch'
$BuildDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildDir)
$SourceDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceDir)

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'Visual Studio C++ x64 build tools and Windows SDK 10.0.26100.0 are required.'
}
$vsArgs = '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
$vsPath = & $vswhere @vsArgs -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vsPath) { throw 'Visual Studio C++ x64 build tools were not found.' }
$vsVersion = & $vswhere @vsArgs -property installationVersion
if ($LASTEXITCODE -ne 0 -or -not $vsVersion) { throw 'Could not determine the Visual Studio version.' }
$msbuild = Join-Path $vsPath 'MSBuild\Current\Bin\amd64\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) { throw '64-bit MSBuild was not found.' }
$toolset = if (([version]$vsVersion).Major -ge 18) { 'v145' } else { 'v143' }

if (-not (Test-Path -LiteralPath $SourceDir)) {
    & git -c advice.detachedHead=false clone --quiet --depth 1 --branch $sourceTag https://github.com/microsoft/terminal.git $SourceDir
    if ($LASTEXITCODE -ne 0) { throw 'Could not obtain the pinned OpenConsole source.' }
}
$head = & git -C $SourceDir rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -cne $sourceCommit) {
    throw "Expected OpenConsole commit $sourceCommit at $SourceDir."
}
$alreadyPatched = & {
    $ErrorActionPreference = 'Continue'
    & git -C $SourceDir apply --reverse --check $patch 2>$null
    $LASTEXITCODE -eq 0
}
if (-not $alreadyPatched) {
    & git -C $SourceDir apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply the OpenConsole handoff patch.' }
}

$priorToolset = $env:MADOTTY_OPENCONSOLE_TOOLSET
Push-Location -LiteralPath $SourceDir
try {
    $env:MADOTTY_OPENCONSOLE_TOOLSET = $toolset
    $nuget = Join-Path $SourceDir 'dep\nuget\nuget.exe'
    $msbuildDir = Split-Path -Parent $msbuild
    foreach ($restore in 'OpenConsole.slnx', 'dep\nuget\packages.config') {
        & $nuget restore $restore -NonInteractive -MSBuildPath $msbuildDir -Verbosity quiet
        if ($LASTEXITCODE -ne 0) { throw "OpenConsole NuGet restore failed for $restore." }
    }
    $properties = "/p:Configuration=Release;Platform=x64;WindowsTerminalBranding=Release;PlatformToolset=$toolset"
    & $msbuild 'OpenConsole.slnx' '/t:Conhost\Host_EXE' $properties /m:2 /nr:false /nologo /v:minimal
    if ($LASTEXITCODE -ne 0) { throw 'OpenConsole build failed.' }
} finally {
    Pop-Location
    $env:MADOTTY_OPENCONSOLE_TOOLSET = $priorToolset
}

$exe = Join-Path $SourceDir 'bin\x64\Release\OpenConsole.exe'
$encoding = [Text.Encoding]::GetEncoding(28591)
$image = $encoding.GetString([IO.File]::ReadAllBytes($exe))
if ($image.IndexOf($encoding.GetString($consoleClsid.ToByteArray()), [StringComparison]::Ordinal) -lt 0) {
    throw 'The OpenConsole executable does not contain the Madotty console class.'
}
$bin = Join-Path $BuildDir 'bin'
[IO.Directory]::CreateDirectory($bin) | Out-Null
$destination = Join-Path $bin 'Madotty.OpenConsole.exe'
Copy-Item -LiteralPath $exe -Destination $destination -Force
Copy-Item -LiteralPath (Join-Path $SourceDir 'LICENSE') -Destination (Join-Path $bin 'Madotty.OpenConsole.LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $SourceDir 'NOTICE.md') -Destination (Join-Path $bin 'Madotty.OpenConsole.NOTICE.md') -Force
Write-Output "Console delegate: $destination"
