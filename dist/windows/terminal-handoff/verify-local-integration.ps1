#Requires -Version 5.1
param([Parameter(Mandatory)][string]$Directory)

# Verify content and signer without importing a certificate or deploying a package.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security, System.IO.Compression.FileSystem
$app = Join-Path $Directory 'Madotty'
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $Directory 'Madotty-Local.cer'))
$archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $app 'Madotty.TerminalHandoff.msix'))
$sha = [Security.Cryptography.SHA256]::Create()
function Read-Entry([string]$Name) {
    $entry = $archive.GetEntry($Name)
    if (-not $entry) { throw "Missing MSIX file: $Name" }
    $reader = [IO.BinaryReader]::new($entry.Open())
    try { return ,$reader.ReadBytes([int]$entry.Length) } finally { $reader.Dispose() }
}
try {
    $bytes = Read-Entry 'AppxSignature.p7x'
    if ([Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'PKCX') { throw 'Invalid package signature header.' }
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
    $cms.Decode([byte[]]$bytes[4..($bytes.Length-1)])
    $cms.CheckSignature($true)
    if ($cms.SignerInfos.Count -ne 1 -or $cms.SignerInfos[0].Certificate.Thumbprint -ne $cert.Thumbprint) {
        throw 'The MSIX signer does not match the adjacent public certificate.'
    }
    $blockMap = Read-Entry 'AppxBlockMap.xml'
    $signedContent = $cms.ContentInfo.Content
    $offset = [Text.Encoding]::ASCII.GetString($signedContent).IndexOf('APPXAXPC', [StringComparison]::Ordinal)
    # SHA-256 AppX SIP digest records contain a four-byte label and 32 digest bytes.
    $blockRecord = $offset + 4 + 3 * 36
    if ($offset -lt 0 -or [Text.Encoding]::ASCII.GetString($signedContent,$blockRecord,4) -cne 'AXBM' -or
            [Convert]::ToBase64String($signedContent,$blockRecord+4,32) -cne [Convert]::ToBase64String($sha.ComputeHash($blockMap))) {
        throw 'The signed MSIX block map hash does not match.'
    }
    [xml]$map = [Text.Encoding]::UTF8.GetString($blockMap).TrimStart([char]0xFEFF)
    foreach ($file in $map.BlockMap.File) {
        $content = Read-Entry ($file.Name.Replace('\','/'))
        $pos = 0
        foreach ($block in $file.Block) {
            $size = [Math]::Min(65536, $content.Length - $pos)
            if ([Convert]::ToBase64String($sha.ComputeHash($content,$pos,$size)) -cne $block.Hash) {
                throw "MSIX block checksum failed: $($file.Name)"
            }
            $pos += $size
        }
        if ($pos -ne [int]$file.Size -or $pos -ne $content.Length) { throw "Wrong MSIX file size: $($file.Name)" }
    }
    [xml]$manifest = [Text.Encoding]::UTF8.GetString((Read-Entry 'AppxManifest.xml')).TrimStart([char]0xFEFF)
    if ($manifest.Package.Identity.Name -cne 'Madotty.TerminalHandoff' -or
            $manifest.Package.Identity.Publisher -cne $cert.Subject -or
            $manifest.Package.Applications.Application.Executable -cne 'Madotty.Terminal.exe') {
        throw 'Unexpected sparse package identity or executable.'
    }
    $hashes = [Text.Encoding]::UTF8.GetString((Read-Entry 'ExternalFiles.json')).TrimStart([char]0xFEFF) | ConvertFrom-Json
    foreach ($name in 'ghostty.exe','Madotty.Terminal.exe','Madotty.OpenConsole.exe','Madotty.TerminalHandoffProxy.dll',
            'Madotty.OpenConsole.NOTICE.md','Madotty.OpenConsole.LICENSE.txt') {
        if ((Get-FileHash -LiteralPath (Join-Path $app $name)).Hash -ne $hashes.$name) {
            throw "External file checksum failed: $name"
        }
    }
    Write-Output "Verified local MSIX content, external files, and signer $($cert.Thumbprint)"
} finally {
    $sha.Dispose()
    $archive.Dispose()
    $cert.Dispose()
}
