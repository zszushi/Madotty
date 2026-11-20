#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$BuildDir,
    [Parameter(Mandatory)][string]$DxcDir,
    [Parameter(Mandatory)][string]$ConsoleBin,
    [Parameter(Mandatory)][string]$OutputDir,
    [Parameter(Mandatory)][string]$Version,
    [string]$NuGetPackages = $(if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' })
)

$ErrorActionPreference = 'Stop'
$subject = 'CN=Madotty Local Integration'
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
if (Test-Path -LiteralPath $output) { throw "Choose a new local output directory: $output" }
$tools = Get-ChildItem -LiteralPath "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
    Where-Object { $_.Name -match '^10\.0\.\d+\.\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\signtool.exe')) } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $tools) { throw 'Install the Windows SDK signing tools.' }
$work = Join-Path $env:TEMP ('madotty-local-integration-' + [guid]::NewGuid().ToString('N'))
$bundle = $output + '.pending-' + [guid]::NewGuid().ToString('N')
$key = [Security.Cryptography.RSACng]::new(3072)
try {
    $bin = New-Item -Type Directory -Path (Join-Path $work 'bin') -Force
    $license = New-Item -Type Directory -Path (Join-Path $work 'share\licenses\conpty') -Force
    foreach ($name in 'ghostty.exe', 'Madotty.TerminalHandoffProxy.dll') {
        Copy-Item -LiteralPath (Join-Path $BuildDir "bin\$name") -Destination $bin.FullName
    }
    foreach ($name in 'Madotty.OpenConsole.exe', 'Madotty.OpenConsole.LICENSE.txt', 'Madotty.OpenConsole.NOTICE.md') {
        Copy-Item -LiteralPath (Join-Path $ConsoleBin $name) -Destination $bin.FullName
    }
    Copy-Item -LiteralPath (Join-Path $BuildDir 'share\licenses\conpty\LICENSE.txt') -Destination $license.FullName
    $staged = Join-Path $work 'handoff'
    & (Join-Path $PSScriptRoot 'build-sparse-package.ps1') -BuildDir $work -Publisher $subject -Version $Version -DistributionDir $staged
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new($subject, $key,
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $oids = [Security.Cryptography.OidCollection]::new()
    [void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new('DigitalSignature',$true))
    $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-10), [DateTimeOffset]::UtcNow.AddYears(1))
    $pfx = Join-Path $work 'temporary-signing.pfx'
    $password = [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($pfx, $cert.Export('Pfx', $password))
        $package = Join-Path $staged 'Madotty.TerminalHandoff.msix'
        & (Join-Path $tools.FullName 'x64\signtool.exe') sign /fd SHA256 /f $pfx /p $password $package
        if ($LASTEXITCODE) { throw 'Could not sign the local MSIX.' }
    } finally { if (Test-Path -LiteralPath $pfx) { Remove-Item -LiteralPath $pfx -Force } }

    $app = (New-Item -Type Directory -Path (Join-Path $bundle 'Madotty') -Force).FullName
    $files = & (Join-Path $PSScriptRoot '..\distribution-files.ps1') -BuildDir $BuildDir -DxcDir $DxcDir -NuGetPackages $NuGetPackages
    foreach ($item in $files.GetEnumerator()) {
        $dest = Join-Path $app $item.Key
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
        Copy-Item -LiteralPath $item.Value -Destination $dest
    }
    foreach ($file in (Get-ChildItem -LiteralPath $staged -File)) { Copy-Item -LiteralPath $file.FullName -Destination $app }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'unregister-handoff.ps1') -Destination $app
    [IO.File]::WriteAllBytes((Join-Path $bundle 'Madotty-Local.cer'), $cert.Export('Cert'))
    $thumbprint = $cert.Thumbprint
    & (Join-Path $PSScriptRoot 'verify-local-integration.ps1') -Directory $bundle
    $guide = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'local-integration-readme.txt'))
    $instructions = $guide.Replace('@THUMBPRINT@', $thumbprint).Replace('@EXPIRY@', $cert.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd'))
    [IO.File]::WriteAllText((Join-Path $bundle 'README.txt'), $instructions)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
    Move-Item -LiteralPath $bundle -Destination $output
    Write-Output "Local integration: $output"
} finally {
    if ($cert) { $cert.Dispose() }
    $key.Dispose()
    $temporary = Get-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
    if ($temporary -and $temporary.Parent.FullName -eq [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -and
            -not ($temporary.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $temporary.FullName -Recurse -Force
    }
    $partial = Get-Item -LiteralPath $bundle -Force -ErrorAction SilentlyContinue
    if ($partial -and $partial.Parent.FullName -eq [IO.Path]::GetDirectoryName($output) -and
            -not ($partial.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $partial.FullName -Recurse -Force
    }
}
