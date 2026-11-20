param(
    [Parameter(Mandatory)][string]$BuildDir,
    [Parameter(Mandatory)][string]$DxcDir,
    [Parameter(Mandatory)][string]$NuGetPackages,
    [string]$HandoffDir
)

$ErrorActionPreference = 'Stop'
$payload = @{}
function Add-File([string]$source, [string]$destination) {
    $file = Get-Item -LiteralPath $source -Force
    if ($file.PSIsContainer -or $file.Length -eq 0 -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a regular, nonempty payload file at $source"
    }
    if ($payload.ContainsKey($destination)) { throw "Duplicate payload path: $destination" }
    $payload[$destination] = $file.FullName
}

foreach ($name in @('ghostty.exe', 'ghostty.com', 'ghostty-d3d12.exe', 'ghostty-vulkan.exe',
        'conpty.dll', 'OpenConsole.exe', 'dxcompiler.dll', 'dxil.dll')) {
    Add-File (Join-Path $BuildDir "bin\$name") $name
}
$proxy = Join-Path $BuildDir 'bin\Madotty.TerminalHandoffProxy.dll'
if (Test-Path -LiteralPath $proxy) {
    Add-File $proxy 'Madotty.TerminalHandoffProxy.dll'
}
if ($HandoffDir) {
    $msix = Join-Path $HandoffDir 'Madotty.TerminalHandoff.msix'
    $signature = Get-AuthenticodeSignature -LiteralPath $msix
    if ($signature.Status -ne 'Valid') {
        throw "Terminal integration requires a trusted signed package: $($signature.Status) ($msix)"
    }
    Add-File $msix 'Madotty.TerminalHandoff.msix'
    Add-File (Join-Path $PSScriptRoot 'terminal-handoff\unregister-handoff.ps1') 'unregister-handoff.ps1'
    foreach ($name in 'Madotty.Terminal.exe', 'Madotty.OpenConsole.exe', 'Madotty.OpenConsole.LICENSE.txt', 'Madotty.OpenConsole.NOTICE.md') {
        Add-File (Join-Path $HandoffDir $name) $name
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($msix)
    try {
        $reader = [IO.StreamReader]::new($archive.GetEntry('ExternalFiles.json').Open())
        try { $hashes = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        foreach ($name in 'ghostty.exe', 'Madotty.TerminalHandoffProxy.dll', 'Madotty.Terminal.exe',
                'Madotty.OpenConsole.exe', 'Madotty.OpenConsole.LICENSE.txt', 'Madotty.OpenConsole.NOTICE.md') {
            if (-not $payload.ContainsKey($name) -or (Get-FileHash -LiteralPath $payload[$name]).Hash -ne $hashes.$name) {
                throw "The signed handoff package does not match the staged $name."
            }
        }
    } finally { $archive.Dispose() }
}
foreach ($name in @('dxcompiler.dll', 'dxil.dll')) {
    if ((Get-FileHash -LiteralPath $payload[$name]).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $DxcDir "bin\x64\$name")).Hash) {
        throw "$name does not match the DXC distribution at $DxcDir"
    }
}
foreach ($name in @('LICENCE-MIT.txt', 'LICENSE-LLVM.txt', 'LICENSE-MS.txt')) {
    Add-File (Join-Path $DxcDir $name) "share\licenses\dxc\$name"
}
foreach ($name in @('share\terminfo\ghostty.terminfo', 'share\licenses\conpty\LICENSE.txt')) {
    Add-File (Join-Path $BuildDir $name) $name
}
Add-File (Join-Path $PSScriptRoot '..\..\LICENSE') 'LICENSE'

foreach ($directory in @('bin\settings', 'share\ghostty\themes', 'share\ghostty\shell-integration')) {
    $source = (Get-Item -LiteralPath (Join-Path $BuildDir $directory)).FullName
    $destination = $directory -replace '^bin\\', ''
    foreach ($file in (Get-ChildItem -LiteralPath $source -File -Recurse)) {
        if ($file.Extension -eq '.pdb') { continue }
        $relative = $file.FullName.Substring($source.Length + 1)
        Add-File $file.FullName "$destination\$relative"
    }
}
foreach ($name in @('Madotty.Settings.exe', 'Madotty.Settings.dll', 'Madotty.Settings.deps.json',
        'Madotty.Settings.runtimeconfig.json', 'coreclr.dll', 'Microsoft.UI.Xaml.dll', 'resources.pri', 'App.xbf')) {
    if (-not $payload.ContainsKey("settings\$name")) { throw "Incomplete WinUI publication: missing $name" }
}

# Use the dependencies of the published app to select matching license versions.
$deps = Get-Content -LiteralPath $payload['settings\Madotty.Settings.deps.json'] -Raw | ConvertFrom-Json
foreach ($dependency in $deps.libraries.PSObject.Properties.Name) {
    $package, $packageVersion = ($dependency -replace '^runtimepack\.', '').Split('/')
    if ($package -eq 'Madotty.Settings') { continue }
    $packagePath = Join-Path $NuGetPackages (Join-Path $package.ToLowerInvariant() $packageVersion)
    $licenses = Get-ChildItem -LiteralPath $packagePath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(licen[cs]e|notice|third[-_. ]*party[-_. ]*notices?)(\..+)?$' }
    if ($package -in @('Microsoft.NETCore.App.Runtime.win-x64', 'Microsoft.WindowsAppSDK.Runtime') -and -not $licenses) {
        throw "Missing runtime licenses under $packagePath. Use the NuGet cache for this settings publication."
    }
    foreach ($license in $licenses) {
        Add-File $license.FullName "share\licenses\$package\$($license.Name)"
    }
}

return $payload
