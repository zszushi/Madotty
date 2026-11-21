param(
    [Parameter(Mandatory)][string]$BuildDir,
    [Parameter(Mandatory)][string]$DxcDir,
    [string]$NuGetPackages = $(if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }),
    [string]$OutputDir,
    [string]$ExpectedVersion = '',
    [switch]$RequireFast,
    [string]$HandoffDir
)

# Package a complete published prefix, including the same binaries, WinUI
# dependencies, and notices as the MSI. Supported by Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = $PSScriptRoot }
$BuildDir = (Get-Item -LiteralPath $BuildDir).FullName
$DxcDir = (Get-Item -LiteralPath $DxcDir).FullName
$verify = Join-Path $PSScriptRoot 'verify-build.ps1'
$version = & $verify -VerifyX64Host -BuildDir $BuildDir -ExpectedVersion $ExpectedVersion -RequireFast:$RequireFast
$payload = & (Join-Path $PSScriptRoot 'distribution-files.ps1') -BuildDir $BuildDir -DxcDir $DxcDir -NuGetPackages $NuGetPackages -HandoffDir $HandoffDir
$OutputDir = (New-Item -Type Directory -Path $OutputDir -Force).FullName
$scratch = (New-Item -Type Directory -Path (Join-Path $OutputDir ('.zip-' + [guid]::NewGuid().ToString('N')))).FullName
try {
    $name = "ghostty-windows-x64-$version.zip"
    $archivePath = Join-Path $scratch $name
    $readme = Join-Path $scratch 'README.txt'
    $template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'portable-readme.txt'))
    [IO.File]::WriteAllText($readme, $template.Replace('@VERSION@', $version))
    $payload.Add('README.txt', $readme)

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($path in ($payload.Keys | Sort-Object)) {
            $entry = 'ghostty/' + $path.Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $payload[$path], $entry) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }

    # Verify the actual extracted payload before replacing any existing ZIP.
    $expanded = Join-Path $scratch 'extract'
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $expanded)
    $portable = Join-Path $expanded 'ghostty'
    & $verify -VerifyX64Host -BuildDir $portable -Portable -ExpectedVersion $version | Out-Null
    foreach ($path in $payload.Keys) {
        $file = Get-Item -LiteralPath (Join-Path $portable $path)
        if ($file.Length -ne (Get-Item -LiteralPath $payload[$path]).Length) {
            throw "Incomplete ZIP entry: $path"
        }
    }
    $destination = Join-Path $OutputDir $name
    if ([IO.File]::Exists($destination)) {
        [IO.File]::Replace($archivePath, $destination, (Join-Path $scratch 'previous.zip'))
    } else {
        [IO.File]::Move($archivePath, $destination)
    }
    Write-Output $destination
} finally {
    $temporary = Get-Item -LiteralPath $scratch -Force
    if ($temporary.Parent.FullName -eq $OutputDir -and
        -not ($temporary.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $temporary.FullName -Recurse -Force
    }
}
