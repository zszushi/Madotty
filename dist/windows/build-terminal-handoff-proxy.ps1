param(
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\..\zig-out'),
    [string]$WindowsSdkDir = (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10')
)

$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'Install the Visual Studio C++ x64 build tools and Windows SDK to build the terminal handoff proxy.'
}
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw 'The Visual Studio C++ x64 build tools were not found.' }
$vcVersion = (Get-Content -LiteralPath (Join-Path $visualStudio 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
$vc = Join-Path $visualStudio "VC\Tools\MSVC\$vcVersion"
$vcBin = Join-Path $vc 'bin\Hostx64\x64'
$compiler = Join-Path $vcBin 'cl.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw "C++ compiler was not found at $compiler" }

$sdkVersion = Get-ChildItem -LiteralPath (Join-Path $WindowsSdkDir 'bin') -Directory |
    Where-Object {
        $_.Name -match '^10\.0\.\d+\.\d+$' -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\midl.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $WindowsSdkDir "Include\$($_.Name)\um\unknwn.idl") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $WindowsSdkDir "Lib\$($_.Name)\um\x64\rpcrt4.lib") -PathType Leaf)
    } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty Name
if (-not $sdkVersion) { throw 'A Windows SDK with MIDL, headers, and x64 libraries is required.' }
$sdkBin = Join-Path $WindowsSdkDir "bin\$sdkVersion\x64"
$sdkInclude = Join-Path $WindowsSdkDir "Include\$sdkVersion"
$sdkLib = Join-Path $WindowsSdkDir "Lib\$sdkVersion"
$midl = Join-Path $sdkBin 'midl.exe'
$dumpbin = Join-Path $vcBin 'dumpbin.exe'

$BuildDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildDir)
$bin = Join-Path $BuildDir 'bin'
$source = Join-Path $PSScriptRoot 'terminal-handoff'
$dll = 'Madotty.TerminalHandoffProxy.dll'
$work = Join-Path $bin ('.terminal-handoff-proxy-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($work) | Out-Null

$previousPath, $previousInclude, $previousLib = $env:PATH, $env:INCLUDE, $env:LIB
$env:PATH = "$vcBin;$sdkBin;$previousPath"
$env:INCLUDE = "$vc\include;$sdkInclude\um;$sdkInclude\shared;$sdkInclude\ucrt"
$env:LIB = "$vc\lib\x64;$sdkLib\um\x64;$sdkLib\ucrt\x64"
Push-Location -LiteralPath $work
try {
    & $midl /nologo /env x64 /target NT100 /robust /protocol all /h TerminalHandoff.h /iid TerminalHandoff_i.c `
        /proxy TerminalHandoff_p.c /dlldata dlldata.c (Join-Path $source 'TerminalHandoff.idl')
    if ($LASTEXITCODE -ne 0) { throw "MIDL failed with exit code $LASTEXITCODE" }

    & $compiler /nologo /LD /MT /O2 /W3 /guard:cf /D_WIN32_WINNT=0x0A00 `
        ('/FI' + (Join-Path $source 'ProxyClass.h')) dlldata.c TerminalHandoff_i.c TerminalHandoff_p.c `
        /link "/OUT:$dll" /GUARD:CF '/EXPORT:DllGetClassObject,PRIVATE' '/EXPORT:DllCanUnloadNow,PRIVATE' `
        /EXPORT:GetProxyDllInfo rpcrt4.lib ole32.lib oleaut32.lib uuid.lib
    if ($LASTEXITCODE -ne 0) { throw "C++ compiler or linker failed with exit code $LASTEXITCODE" }

    $exports = & $dumpbin /nologo /exports $dll | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect $dll" }
    foreach ($export in 'DllGetClassObject', 'DllCanUnloadNow', 'GetProxyDllInfo') {
        if ($exports -notmatch "(?m)\b$export\s*$") { throw "Missing $export export in $dll" }
    }

    $destination = Join-Path $bin $dll
    if ([System.IO.File]::Exists($destination)) {
        [System.IO.File]::Replace((Join-Path $work $dll), $destination, (Join-Path $work 'previous.dll'))
    } else {
        [System.IO.File]::Move((Join-Path $work $dll), $destination)
    }
} finally {
    Pop-Location
    $env:PATH, $env:INCLUDE, $env:LIB = $previousPath, $previousInclude, $previousLib
    $temporary = Get-Item -LiteralPath $work -Force
    if ((Split-Path -Parent $temporary.FullName) -eq $bin -and
        $temporary.PSIsContainer -and -not ($temporary.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $temporary.FullName -Recurse -Force
    }
}

Write-Output "Terminal handoff proxy: $destination"
