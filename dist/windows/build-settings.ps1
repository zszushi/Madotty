param(
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\..\zig-out'),
    [string]$Dotnet = 'dotnet'
)

$ErrorActionPreference = 'Stop'
$dotnetCommand = Get-Command $Dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dotnetCommand) {
    throw 'A .NET 8 or newer SDK is required. Pass -Dotnet with the path to dotnet.exe if needed.'
}

$project = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\src\apprt\winui-settings\Madotty.Settings.csproj')).FullName
$BuildDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildDir)
$bin = Join-Path $BuildDir 'bin'
$settings = Join-Path $bin 'settings'
$artifacts = Join-Path $BuildDir 'settings-obj'
$id = [guid]::NewGuid().ToString('N')
$staging = Join-Path $bin ('.settings-publish-' + $id)
$backup = Join-Path $bin ('.settings-backup-' + $id)
[System.IO.Directory]::CreateDirectory($staging) | Out-Null

function Remove-TemporarySettingsDirectory([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if ((Split-Path -Parent $item.FullName) -ne $bin -or -not $item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Unexpected temporary settings directory: $($item.FullName)"
    }
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
}

try {
    & $dotnetCommand.Source publish $project --configuration Release --runtime win-x64 --self-contained true `
        -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --artifacts-path $artifacts --output $staging
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

    foreach ($file in @('Madotty.Settings.exe', 'Madotty.Settings.dll', 'Madotty.Settings.deps.json',
            'Madotty.Settings.runtimeconfig.json', 'coreclr.dll', 'Microsoft.UI.Xaml.dll', 'resources.pri')) {
        if (-not (Test-Path -LiteralPath (Join-Path $staging $file) -PathType Leaf)) {
            throw "Incomplete settings publication: missing $file"
        }
    }

    # Keep an existing build usable if publishing or swapping the directory fails.
    if (Test-Path -LiteralPath $settings) {
        $current = Get-Item -LiteralPath $settings -Force
        if (-not $current.PSIsContainer -or ($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Expected a regular settings directory at $settings"
        }
        Rename-Item -LiteralPath $settings -NewName (Split-Path -Leaf $backup)
    }
    try {
        Rename-Item -LiteralPath $staging -NewName 'settings'
    } catch {
        if (Test-Path -LiteralPath $backup) { Rename-Item -LiteralPath $backup -NewName 'settings' }
        throw
    }

    Remove-TemporarySettingsDirectory $backup
} finally {
    Remove-TemporarySettingsDirectory $staging
}

Write-Output "Settings companion: $(Join-Path $settings 'Madotty.Settings.exe')"
