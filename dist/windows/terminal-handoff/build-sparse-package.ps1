param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Publisher,
    [Parameter(Mandatory)][ValidatePattern('^\d{1,5}(\.\d{1,5}){3}$')][string]$Version,
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\..\..\zig-out'),
    [string]$WindowsSdkDir = (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Windows Kits\10'),
    [switch]$StageInstall,
    [string]$DistributionDir
)

function Assert-Amd64PE([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ($reader.ReadUInt16() -eq 0x5a4d -and $reader.BaseStream.Length -ge 64) {
            $reader.BaseStream.Position = 0x3c
            $offset = $reader.ReadUInt32()
            if ($offset -ge 64 -and $offset -le $reader.BaseStream.Length - 6) {
                $reader.BaseStream.Position = $offset
                if ($reader.ReadUInt32() -eq 0x4550 -and $reader.ReadUInt16() -eq 0x8664) { return }
            }
        }
        throw "Expected an x64 Windows binary at $Path"
    } finally {
        $reader.Dispose()
    }
}

function Add-PackageIdentity([string]$Executable, [string]$AssemblyName, [xml]$PackageManifest) {
    $resource = $Executable + ';#1'
    $manifestPath = Join-Path $work ($AssemblyName + '.manifest')
    & $mt -nologo ('-inputresource:' + $resource) ('-out:' + $manifestPath)
    if ($LASTEXITCODE -ne 0) { throw "Could not read the embedded application manifest for $Executable" }

    [xml]$exeManifest = Get-Content -LiteralPath $manifestPath -Raw
    $assembly = $exeManifest.DocumentElement
    $assemblyNs = 'urn:schemas-microsoft-com:asm.v1'
    $msixNs = 'urn:schemas-microsoft-com:msix.v1'
    if ($assembly.LocalName -cne 'assembly' -or $assembly.NamespaceURI -cne $assemblyNs) {
        throw "Expected a Win32 application manifest in $Executable"
    }
    $namespaces = [Xml.XmlNamespaceManager]::new($exeManifest.NameTable)
    $namespaces.AddNamespace('asm', $assemblyNs)
    $namespaces.AddNamespace('msix', $msixNs)
    if (-not $assembly.SelectSingleNode('asm:assemblyIdentity', $namespaces)) {
        $identity = $exeManifest.CreateElement('assemblyIdentity', $assemblyNs)
        $identity.SetAttribute('name', $AssemblyName)
        $identity.SetAttribute('version', '0.0.0.0')
        [void]$assembly.PrependChild($identity)
    }
    $msix = $assembly.SelectSingleNode('msix:msix', $namespaces)
    if (-not $msix) {
        $msix = $exeManifest.CreateElement('msix', $msixNs)
        [void]$assembly.AppendChild($msix)
    }
    $msix.SetAttribute('publisher', $PackageManifest.Package.Identity.Publisher)
    $msix.SetAttribute('packageName', $PackageManifest.Package.Identity.Name)
    $msix.SetAttribute('applicationId', $PackageManifest.Package.Applications.Application.Id)
    $exeManifest.Save($manifestPath)

    & $mt -nologo -manifest $manifestPath -validate_manifest ('-outputresource:' + $resource)
    if ($LASTEXITCODE -ne 0) { throw "Could not embed package identity in $Executable" }
}

$ErrorActionPreference = 'Stop'
$packageVersion = [version]$Version
if ($packageVersion.Major -eq 0 -or ($Version.Split('.') | Where-Object { [int]$_ -gt 65535 })) {
    throw 'The MSIX version must start with a nonzero major version and each component must be at most 65535.'
}
[void][System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Publisher)
if ($DistributionDir -and $StageInstall) { throw 'Choose one staging layout.' }

$sdk = Get-ChildItem -LiteralPath (Join-Path $WindowsSdkDir 'bin') -Directory |
    Where-Object {
        $_.Name -match '^10\.0\.\d+\.\d+$' -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\makeappx.exe') -PathType Leaf) -and
        ((-not $StageInstall -and -not $DistributionDir) -or (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\mt.exe') -PathType Leaf))
    } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdk) { throw 'A Windows SDK with x64 MakeAppx (and Mt.exe for -StageInstall) is required.' }
$makeAppx = Join-Path $sdk.FullName 'x64\makeappx.exe'
$mt = Join-Path $sdk.FullName 'x64\mt.exe'

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).ProviderPath
$BuildDir = (Resolve-Path -LiteralPath $BuildDir).ProviderPath
$bin = Join-Path $BuildDir 'bin'
$proxy = Join-Path $bin 'Madotty.TerminalHandoffProxy.dll'
$consoleLicense = Join-Path $BuildDir 'share\licenses\conpty\LICENSE.txt'
foreach ($file in $proxy, $consoleLicense) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required package input was not found: $file" }
}
Assert-Amd64PE $proxy
$install = Join-Path $BuildDir 'terminal-handoff-install'
if ($DistributionDir) { $install = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DistributionDir) }
if (($StageInstall -or $DistributionDir) -and (Test-Path -LiteralPath $install)) {
    throw "Use a fresh build prefix. An external install directory already exists at $install"
}

$work = Join-Path $BuildDir ('.terminal-handoff-msix-' + [Guid]::NewGuid().ToString('N'))
$contents = Join-Path $work 'package'
$assets = Join-Path $contents 'Assets'
[IO.Directory]::CreateDirectory($assets) | Out-Null
$package = Join-Path $BuildDir 'Madotty.TerminalHandoff.msix'
try {
    [xml]$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'AppxManifest.xml') -Raw
    $manifest.Package.Identity.Publisher = $Publisher
    $manifest.Package.Identity.Version = $packageVersion.ToString()
    if ($DistributionDir) {
        $manifest.Package.Applications.Application.Executable = 'Madotty.Terminal.exe'
        $server = $manifest.SelectSingleNode("//*[local-name()='ExeServer' and @Executable='ghostty.exe']")
        $server.SetAttribute('Executable', 'Madotty.Terminal.exe')
    }
    $manifest.Save((Join-Path $contents 'AppxManifest.xml'))
    Copy-Item -LiteralPath $proxy -Destination $contents
    Copy-Item -LiteralPath $consoleLicense -Destination (Join-Path $contents 'WindowsTerminal.LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $contents 'Ghostty.LICENSE.txt')

    Add-Type -AssemblyName System.Drawing
    $applicationIcon = [System.Drawing.Icon]::new((Join-Path $repo 'dist\windows\ghostty.ico'), 256, 256)
    try { $icon = $applicationIcon.ToBitmap() } finally { $applicationIcon.Dispose() }
    try {
        foreach ($logo in @{ StoreLogo = 50; Square44x44Logo = 44; Square150x150Logo = 150 }.GetEnumerator()) {
            $size = $logo.Value
            $image = [System.Drawing.Bitmap]::new($icon, $size, $size)
            try {
                $image.Save((Join-Path $assets ($logo.Key + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
            } finally {
                $image.Dispose()
            }
        }
    } finally {
        $icon.Dispose()
    }

    if ($StageInstall) {
        $staging = Join-Path $work 'install'
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        foreach ($file in 'ghostty.exe', 'ghostty.com', 'conpty.dll', 'OpenConsole.exe',
                 'Madotty.OpenConsole.exe', 'Madotty.OpenConsole.LICENSE.txt', 'Madotty.OpenConsole.NOTICE.md') {
            Copy-Item -LiteralPath (Join-Path $bin $file) -Destination $staging
        }
        foreach ($item in 'ghostty-d3d12.exe', 'ghostty-vulkan.exe', 'dxcompiler.dll', 'dxil.dll', 'settings') {
            $path = Join-Path $bin $item
            if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $staging -Recurse }
        }
        Copy-Item -LiteralPath (Join-Path $BuildDir 'share') -Destination $staging -Recurse
        Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $staging 'LICENSE.txt')

    }
    if ($DistributionDir) {
        $staging = Join-Path $work 'distribution'
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        Copy-Item -LiteralPath (Join-Path $bin 'ghostty.exe') -Destination (Join-Path $staging 'Madotty.Terminal.exe')
        foreach ($name in 'Madotty.OpenConsole.exe', 'Madotty.OpenConsole.LICENSE.txt', 'Madotty.OpenConsole.NOTICE.md') {
            Copy-Item -LiteralPath (Join-Path $bin $name) -Destination $staging
        }
    }
    if ($StageInstall -or $DistributionDir) {
        $terminalExe = Join-Path $staging $manifest.Package.Applications.Application.Executable
        $consoleExe = Join-Path $staging 'Madotty.OpenConsole.exe'
        Assert-Amd64PE $terminalExe
        Assert-Amd64PE $consoleExe
        Add-PackageIdentity $terminalExe 'Madotty.Terminal' $manifest
        Add-PackageIdentity $consoleExe 'Madotty.OpenConsole' $manifest
    }
    if ($DistributionDir) {
        # The MSIX signature also binds the external files and the matching normal executable.
        $hashes = [ordered]@{
            'ghostty.exe' = (Get-FileHash -LiteralPath (Join-Path $bin 'ghostty.exe')).Hash
            'Madotty.TerminalHandoffProxy.dll' = (Get-FileHash -LiteralPath $proxy).Hash
        }
        foreach ($file in (Get-ChildItem -LiteralPath $staging -File)) {
            $hashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }
        $hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $contents 'ExternalFiles.json') -Encoding UTF8
    }

    # The two servers are resolved in the external install directory.
    $packed = Join-Path $work 'Madotty.TerminalHandoff.msix'
    & $makeAppx pack /nv /h SHA256 /d $contents /p $packed
    if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed with exit code $LASTEXITCODE." }
    if ($StageInstall) { [IO.Directory]::Move($staging, $install) }
    if ($DistributionDir) {
        Move-Item -LiteralPath $packed -Destination $staging
        Move-Item -LiteralPath $staging -Destination $install
        $package = Join-Path $install 'Madotty.TerminalHandoff.msix'
    } else {
        Move-Item -LiteralPath $packed -Destination $package -Force
    }
} finally {
    $temporary = Get-Item -LiteralPath $work -Force
    if ((Split-Path -Parent $temporary.FullName) -eq $BuildDir -and $temporary.PSIsContainer -and
        -not ($temporary.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $temporary.FullName -Recurse -Force
    }
}

Write-Output "Unsigned terminal handoff package: $package"
if ($StageInstall) { Write-Output "External install directory: $install" }
