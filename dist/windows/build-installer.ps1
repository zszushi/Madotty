param(
    [Parameter(Mandatory = $true)][string]$BuildDir,
    [Parameter(Mandatory = $true)][string]$DxcDir,
    [string]$Wix = 'wix',
    [string]$WixUi = 'WixToolset.UI.wixext',
    [string]$NuGetPackages = $(if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }),
    [string]$OutputDir,
    [string]$HandoffDir,
    [ValidatePattern('^[a-fA-F0-9]{40}$')][string]$SigningCertificateThumbprint,
    [uri]$TimestampUrl,
    [string]$SignTool = 'signtool'
)

$ErrorActionPreference = 'Stop'
if ([bool]$SigningCertificateThumbprint -ne [bool]$TimestampUrl) {
    throw 'Supply both -SigningCertificateThumbprint and -TimestampUrl to sign the MSI.'
}
if ($SigningCertificateThumbprint) {
    $signCommand = (Get-Command $SignTool -CommandType Application).Source
}
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot '..\..\zig-out\installer' }
$BuildDir = (Get-Item -LiteralPath $BuildDir).FullName
$DxcDir = (Get-Item -LiteralPath $DxcDir).FullName
$wixCommand = (Get-Command $Wix -CommandType Application).Source
$version = & (Join-Path $PSScriptRoot 'verify-build.ps1') -BuildDir $BuildDir -VerifyX64Host
$msiVersion = [regex]::Match($version, '^\d+\.\d+\.\d+').Value
# Windows Installer compares only three version components. Rebuilding a
# preview at the same commit should replace the previously installed preview.
$allowSameVersion = if ($version -ne $msiVersion) { 'yes' } else { 'no' }

$payload = & (Join-Path $PSScriptRoot 'distribution-files.ps1') -BuildDir $BuildDir -DxcDir $DxcDir -NuGetPackages $NuGetPackages -HandoffDir $HandoffDir

$OutputDir = (New-Item -ItemType Directory -Path $OutputDir -Force).FullName
$scratch = Join-Path $OutputDir ('.msi-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $namespace = 'http://wixtoolset.org/schemas/v4/wxs'
    [xml]$source = "<Wix xmlns='$namespace'><Fragment><DirectoryRef Id='INSTALLFOLDER'/><ComponentGroup Id='MadottyPayload'/></Fragment></Wix>"
    $fragment = $source.DocumentElement.FirstChild
    $components = $fragment.LastChild
    $directories = @{ '' = $fragment.FirstChild }

    function Add-Element($parent, [string]$name, [hashtable]$attributes) {
        $element = $source.CreateElement($name, $namespace)
        foreach ($attribute in $attributes.Keys) { $element.SetAttribute($attribute, $attributes[$attribute]) }
        return $parent.AppendChild($element)
    }

    # Directory components use HKCU keypaths since the MSI is per-user. Keep
    # IDs stable across builds and remove empty directories on uninstall.
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        function Get-PathId([string]$relativePath) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($relativePath.ToLowerInvariant())
            return [BitConverter]::ToString($hasher.ComputeHash($bytes), 0, 16).Replace('-', '')
        }

        function Get-Directory([string]$relativePath) {
            if (-not $directories.ContainsKey($relativePath)) {
                $parent = Get-Directory (Split-Path -Parent $relativePath)
                $directories[$relativePath] = Add-Element $parent 'Directory' @{
                    Id = 'Dir_' + (Get-PathId $relativePath)
                    Name = Split-Path -Leaf $relativePath
                }
            }
            return $directories[$relativePath]
        }

        $groups = $payload.Keys | Sort-Object | Group-Object { Split-Path -Parent $_ }
        foreach ($group in $groups) {
            $directory = Get-Directory $group.Name
            $id = 'Payload_' + (Get-PathId $group.Name)
            $guid = [guid]::ParseExact((Get-PathId ('Madotty MSI component:' + $group.Name)), 'N')
            $component = Add-Element $directory 'Component' @{ Id = $id; Guid = $guid.ToString() }
            Add-Element $component 'RegistryValue' @{
                Root = 'HKCU'; Key = 'Software\Madotty\Installer\Payload'; Name = $id
                Type = 'integer'; Value = '1'; KeyPath = 'yes'
            } | Out-Null
            Add-Element $components 'ComponentRef' @{ Id = $id } | Out-Null
            if ($group.Name -eq '') { $rootComponent = $component }
            foreach ($path in $group.Group) {
                Add-Element $component 'File' @{
                    Id = 'File_' + (Get-PathId $path); Name = Split-Path -Leaf $path; Source = $payload[$path]
                } | Out-Null
            }
        }
        # Include intermediate directories that have no files of their own.
        $directoryIds = @('MadottyPrograms') + @($directories.Values | ForEach-Object { $_.Id })
        foreach ($id in $directoryIds) {
            Add-Element $rootComponent 'RemoveFolder' @{ Id = "Remove_$id"; Directory = $id; On = 'uninstall' } | Out-Null
        }
    } finally {
        $hasher.Dispose()
    }

    $payloadSource = Join-Path $scratch 'Payload.wxs'
    $source.Save($payloadSource)
    $licenseRtf = Join-Path $scratch 'License.rtf'
    $sdkLicense = $payload['share\licenses\Microsoft.WindowsAppSDK.Runtime\license.txt']
    $terms = "Madotty is distributed under the MIT License.`r`n`r`n" +
        [IO.File]::ReadAllText($payload['LICENSE']) + "`r`n`r`n" +
        "The included Windows App SDK is subject to the following Microsoft terms.`r`n`r`n" +
        [IO.File]::ReadAllText($sdkLicense)
    $rtf = $terms.Replace('\', '\\').Replace('{', '\{').Replace('}', '\}') -replace '\r?\n', "\par `n"
    $rtf = [regex]::Replace($rtf, '[^\x00-\x7f]', { param($ch) '\u' + [int][char]$ch.Value + '?' })
    [IO.File]::WriteAllText($licenseRtf, '{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}\f0\fs18 ' + $rtf + '}')
    $msiName = "Madotty-windows-x64-$version.msi"
    $stagedMsi = Join-Path $scratch $msiName
    $handoffArgs = @()
    if ($HandoffDir) { $handoffArgs = @('-d', 'HandoffIncluded=yes') }
    # WixUI draws its dialog text over the right side of the welcome image
    # and the left side of the progress banner. Keep both regions white.
    Add-Type -AssemblyName System.Drawing
    $iconPath = Join-Path $PSScriptRoot 'ghostty.ico'
    function Write-SetupArtwork($name, $width, $height, $x, $y, $size) {
        $icon = [Drawing.Icon]::new($iconPath, $size, $size)
        try {
            $bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.Clear([Drawing.Color]::White)
                    $graphics.DrawIcon($icon, [Drawing.Rectangle]::new($x, $y, $size, $size))
                } finally { $graphics.Dispose() }
                $bitmap.Save((Join-Path $scratch $name), [Drawing.Imaging.ImageFormat]::Bmp)
            } finally { $bitmap.Dispose() }
        } finally { $icon.Dispose() }
    }
    Write-SetupArtwork 'dialog.bmp' 493 312 28 36 96
    Write-SetupArtwork 'banner.bmp' 493 58 443 9 40
    & $wixCommand build -arch x64 -ext $WixUi -d "Version=$msiVersion" -d "AllowSameVersion=$allowSameVersion" -d "LicenseRtf=$licenseRtf" `
        -d "IconPath=$iconPath" -d "ArtworkDir=$scratch" `
        @handoffArgs -dcl high -pdbtype none (Join-Path $PSScriptRoot 'Madotty.wxs') $payloadSource -o $stagedMsi
    if ($LASTEXITCODE -ne 0) { throw "WiX build failed with exit code $LASTEXITCODE" }
    if ($SigningCertificateThumbprint) {
        & $signCommand sign /fd SHA256 /sha1 $SigningCertificateThumbprint /tr $TimestampUrl.AbsoluteUri /td SHA256 $stagedMsi
        if ($LASTEXITCODE -ne 0) { throw "MSI signing failed with exit code $LASTEXITCODE" }
        & $signCommand verify /pa /tw $stagedMsi
        if ($LASTEXITCODE -ne 0) { throw "MSI signature verification failed with exit code $LASTEXITCODE" }
    }
    $msi = Join-Path $OutputDir $msiName
    Move-Item -LiteralPath $stagedMsi -Destination $msi -Force
    Write-Output "Installer: $msi"
} finally {
    $temporary = Get-Item -LiteralPath $scratch -Force
    if ($temporary.Parent.FullName -eq $OutputDir -and
        -not ($temporary.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $temporary.FullName -Recurse -Force
    }
}
