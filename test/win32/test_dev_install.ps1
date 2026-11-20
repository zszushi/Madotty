param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot '..\..\dist\windows\install-dev.ps1')
)

# Run with -NoProfile under Windows PowerShell 5.1 or PowerShell 7. All
# fixtures are local Windows files; no executable is launched or input sent.
$ErrorActionPreference = 'Stop'

function Assert-True($condition, [string]$description) {
    if (-not $condition) { throw $description }
    Write-Output "PASS=$description"
}

function Write-Fixture([string]$path, [string]$content) {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [System.IO.File]::WriteAllText($path, $content)
}

function Invoke-Install {
    & $InstallerPath -BuildDir $buildDir -InstallRoot $installRoot -DesktopDir $desktopDir | Out-Host
}

function Get-ShortcutTarget {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    try { return $shortcut.TargetPath }
    finally { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
}

function Assert-RejectedPayload([string]$description) {
    $previousShortcutHash = (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash
    $previousBuildCount = @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'builds') -Directory).Count
    $rejected = $false
    try { Invoke-Install }
    catch { $rejected = $true }
    Assert-True $rejected "$description is rejected"
    Assert-True ((Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash -eq $previousShortcutHash) "$description preserves the desktop shortcut"
    Assert-True ((Get-ShortcutTarget) -eq $newTarget) "$description preserves the installed target"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'builds') -Directory).Count -eq $previousBuildCount) "$description does not create a deployment"
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ghostty-dev-install-' + [guid]::NewGuid().ToString('N'))
$buildDir = Join-Path $testRoot 'build payload'
$installRoot = Join-Path $testRoot 'installed builds'
$desktopDir = Join-Path $testRoot 'Desktop'
$shortcutPath = Join-Path $desktopDir 'Ghostty Dev.lnk'
$exePath = Join-Path $buildDir 'bin\ghostty.exe'
$rendererPath = Join-Path $buildDir 'bin\ghostty-d3d12.exe'
$cliPath = Join-Path $buildDir 'bin\ghostty.com'
$dllPath = Join-Path $buildDir 'bin\conpty.dll'
$hostPath = Join-Path $buildDir 'bin\OpenConsole.exe'
$licensePath = Join-Path $buildDir 'share\licenses\conpty\LICENSE.txt'
$sentinelPath = Join-Path $buildDir 'share\terminfo\ghostty.terminfo'
$themesPath = Join-Path $buildDir 'share\ghostty\themes'
$integrationPath = Join-Path $buildDir 'share\ghostty\shell-integration'
$settingsPath = Join-Path $buildDir 'bin\settings'
$shell = $null
$heldExe = $null
try {
    Write-Fixture $exePath 'dummy development executable one'
    Write-Fixture $cliPath 'dummy console entry point'
    Write-Fixture $dllPath 'dummy console library one'
    Write-Fixture $hostPath 'dummy matching console host'
    Write-Fixture $licensePath 'dummy console license'
    Write-Fixture $sentinelPath 'dummy terminfo sentinel'
    Write-Fixture (Join-Path $themesPath 'Example Theme') 'palette = 0=#123456'
    Write-Fixture (Join-Path $themesPath 'nested\Another Theme') 'palette = 0=#abcdef'
    Write-Fixture (Join-Path $integrationPath 'powershell\ghostty-shell-integration.ps1') '# fixture integration'
    Write-Fixture (Join-Path $integrationPath 'bash\ghostty.bash') '# another integration fixture'
    $hiddenResourcePath = Join-Path $integrationPath 'zsh\.zshenv'
    Write-Fixture $hiddenResourcePath '# hidden integration fixture'
    [System.IO.File]::SetAttributes($hiddenResourcePath, [System.IO.FileAttributes]::Hidden)

    $shell = New-Object -ComObject WScript.Shell
    Invoke-Install
    Assert-True (Test-Path -LiteralPath $shortcutPath -PathType Leaf) 'first install creates the desktop shortcut'
    $firstTarget = Get-ShortcutTarget
    $firstBuild = Split-Path -Parent $firstTarget
    Assert-True ((Split-Path -Leaf $firstTarget) -eq 'ghostty.exe') 'shortcut targets the deployed executable'
    Assert-True ((Split-Path -Parent $firstBuild) -eq (Join-Path $installRoot 'builds')) 'deployment uses a local versioned build directory'
    Assert-True (-not $firstTarget.StartsWith('\\')) 'shortcut target is a local Windows path'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstBuild 'ghostty-d3d12.exe'))) 'a single-renderer build installs without a D3D12 executable'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstBuild 'settings'))) 'a Zig-only build installs without a settings companion'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    try {
        Assert-True ($shortcut.WorkingDirectory -eq [Environment]::GetFolderPath('UserProfile')) 'shortcut starts shells in the user home directory'
    } finally {
        [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
    }
    foreach ($relativePath in @(
        'ghostty.exe',
        'ghostty.com',
        'conpty.dll',
        'OpenConsole.exe',
        'share\licenses\conpty\LICENSE.txt',
        'share\terminfo\ghostty.terminfo',
        'share\ghostty\themes\Example Theme',
        'share\ghostty\themes\nested\Another Theme',
        'share\ghostty\shell-integration\powershell\ghostty-shell-integration.ps1',
        'share\ghostty\shell-integration\bash\ghostty.bash',
        'share\ghostty\shell-integration\zsh\.zshenv'
    )) {
        $sourcePath = if ($relativePath -in @('ghostty.exe', 'ghostty.com', 'conpty.dll', 'OpenConsole.exe')) {
            Join-Path $buildDir ('bin\' + $relativePath)
        } else { Join-Path $buildDir $relativePath }
        $deployedPath = Join-Path $firstBuild $relativePath
        Assert-True ((Test-Path -LiteralPath $deployedPath -PathType Leaf) -and
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $deployedPath -Algorithm SHA256).Hash) "complete portable layout includes $relativePath"
    }

    Invoke-Install
    Assert-True ((Get-ShortcutTarget) -eq $firstTarget) 'unchanged payload reuses its deployment'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'builds') -Directory).Count -eq 1) 'unchanged payload does not create another build'

    Write-Fixture (Join-Path $themesPath 'Example Theme') 'palette = 0=#654321'
    Invoke-Install
    $resourceTarget = Get-ShortcutTarget
    Assert-True ($resourceTarget -ne $firstTarget) 'a resource-only change creates a new deployment'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $resourceTarget) 'share\ghostty\themes\Example Theme')) -eq 'palette = 0=#654321') 'resource-only deployment contains the updated resource'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $firstBuild 'share\ghostty\themes\Example Theme')) -eq 'palette = 0=#123456') 'resource-only update leaves previous resources intact'

    $heldExe = [System.IO.File]::Open($resourceTarget, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    Write-Fixture $exePath 'dummy development executable two'
    Invoke-Install
    $newTarget = Get-ShortcutTarget
    Assert-True ($newTarget -ne $resourceTarget) 'a new executable deploys while the previous executable is held open'
    Assert-True ([System.IO.File]::ReadAllText($newTarget) -eq 'dummy development executable two') 'shortcut selects the newly built executable'
    Assert-True ([System.IO.File]::ReadAllText($resourceTarget) -eq 'dummy development executable one') 'updating never overwrites the previous executable'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'builds') -Directory).Count -eq 3) 'all previous builds remain available'
    $heldExe.Dispose()
    $heldExe = $null

    Write-Fixture $dllPath 'dummy console library two'
    Invoke-Install
    $backendTarget = Get-ShortcutTarget
    Assert-True ($backendTarget -ne $newTarget) 'a console backend update creates a new deployment'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $backendTarget) 'conpty.dll')) -eq 'dummy console library two') 'console backend update is deployed beside the executable'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $newTarget) 'conpty.dll')) -eq 'dummy console library one') 'console backend update preserves the previous build'
    $newTarget = $backendTarget

    foreach ($requiredFile in @($dllPath, $hostPath, $licensePath)) {
        $contents = [System.IO.File]::ReadAllText($requiredFile)
        Remove-Item -LiteralPath $requiredFile
        Assert-RejectedPayload ('missing ' + (Split-Path -Leaf $requiredFile))
        Write-Fixture $requiredFile $contents
    }

    Remove-Item -LiteralPath $exePath
    Assert-RejectedPayload 'missing executable'
    Write-Fixture $exePath 'dummy development executable two'

    Remove-Item -LiteralPath $sentinelPath
    Assert-RejectedPayload 'missing resource sentinel'
    Write-Fixture $sentinelPath 'dummy terminfo sentinel'

    foreach ($resourceDirectory in @($themesPath, $integrationPath)) {
        $savedDirectory = Join-Path $testRoot 'saved resource directory'
        Move-Item -LiteralPath $resourceDirectory -Destination $savedDirectory
        try { Assert-RejectedPayload ('missing ' + (Split-Path -Leaf $resourceDirectory) + ' directory') }
        finally { Move-Item -LiteralPath $savedDirectory -Destination $resourceDirectory }
    }

    Write-Fixture (Join-Path $settingsPath 'Madotty.Settings.exe') 'dummy settings executable'
    Assert-RejectedPayload 'partial settings companion'
    $settingsFiles = @('Madotty.Settings.exe', 'Madotty.Settings.dll', 'Madotty.Settings.deps.json',
        'Madotty.Settings.runtimeconfig.json', 'coreclr.dll', 'Microsoft.UI.Xaml.dll', 'resources.pri',
        'ja-JP\Microsoft.UI.Xaml.dll.mui')
    foreach ($file in $settingsFiles) {
        if ($file -ne 'resources.pri') { Write-Fixture (Join-Path $settingsPath $file) "fixture $file" }
    }
    Assert-RejectedPayload 'missing settings resource index'
    Write-Fixture (Join-Path $settingsPath 'resources.pri') 'fixture resources.pri'
    Invoke-Install
    $settingsTarget = Get-ShortcutTarget
    $deployedSettings = Join-Path (Split-Path -Parent $settingsTarget) 'settings'
    Assert-True ($settingsTarget -ne $newTarget) 'adding settings creates a new deployment'
    foreach ($file in $settingsFiles) {
        $fixtureHash = (Get-FileHash -LiteralPath (Join-Path $settingsPath $file) -Algorithm SHA256).Hash
        $installedHash = (Get-FileHash -LiteralPath (Join-Path $deployedSettings $file) -Algorithm SHA256).Hash
        Assert-True ($fixtureHash -eq $installedHash) "settings deployment includes $file"
    }

    $nestedResource = 'ja-JP\Microsoft.UI.Xaml.dll.mui'
    Write-Fixture (Join-Path $settingsPath $nestedResource) 'updated settings resource'
    Invoke-Install
    $newTarget = Get-ShortcutTarget
    Assert-True ($settingsTarget -ne $newTarget) 'a settings resource change creates a new deployment'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $deployedSettings $nestedResource)) -eq "fixture $nestedResource") 'settings resource change preserves the previous deployment'

    Write-Fixture (Join-Path $buildDir 'bin\dxcompiler.dll') 'fixture DXC compiler'
    Assert-RejectedPayload 'missing DXIL validator'
    Write-Fixture (Join-Path $buildDir 'bin\dxil.dll') 'fixture DXIL validator'
    Invoke-Install
    $compilerTarget = Get-ShortcutTarget
    Assert-True ($compilerTarget -ne $newTarget) 'adding DXC creates a new deployment'
    foreach ($file in @('dxcompiler.dll', 'dxil.dll')) {
        $fixtureHash = (Get-FileHash -LiteralPath (Join-Path $buildDir ('bin\' + $file))).Hash
        $installedHash = (Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $compilerTarget) $file)).Hash
        Assert-True ($fixtureHash -eq $installedHash) "deployment includes $file"
    }

    $newTarget = $compilerTarget
    [void][IO.Directory]::CreateDirectory($rendererPath)
    Assert-RejectedPayload 'directory in place of D3D12 executable'
    Remove-Item -LiteralPath $rendererPath
    Write-Fixture $rendererPath ''
    Assert-RejectedPayload 'empty D3D12 executable'

    Write-Fixture $rendererPath 'first D3D12 renderer executable'
    Invoke-Install
    $pairedTarget = Get-ShortcutTarget
    $pairedBuild = Split-Path -Parent $pairedTarget
    $pairedRenderer = Join-Path $pairedBuild 'ghostty-d3d12.exe'
    Assert-True ($pairedTarget -ne $compilerTarget) 'adding D3D12 creates a new deployment'
    Assert-True ((Split-Path -Leaf $pairedTarget) -eq 'ghostty.exe') 'the paired shortcut still starts the primary executable'
    Assert-True ([IO.File]::ReadAllText($pairedRenderer) -eq 'first D3D12 renderer executable') 'the D3D12 executable is deployed beside the primary executable'
    Assert-True ([IO.File]::Exists((Join-Path $pairedBuild 'settings\Madotty.Settings.exe'))) 'the paired build includes the shared settings companion'
    Assert-True ([IO.File]::Exists((Join-Path $pairedBuild 'dxcompiler.dll'))) 'the paired build includes the shared DXC runtime'

    Write-Fixture $rendererPath 'second D3D12 renderer executable'
    Invoke-Install
    $updatedPair = Get-ShortcutTarget
    Assert-True ($updatedPair -ne $pairedTarget) 'a D3D12-only change creates a new deployment'
    Assert-True ([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $updatedPair) 'ghostty-d3d12.exe')) -eq 'second D3D12 renderer executable') 'the new deployment includes the updated D3D12 executable'
    Assert-True ([IO.File]::ReadAllText($pairedRenderer) -eq 'first D3D12 renderer executable') 'a D3D12 update preserves the previous paired deployment'

    $vulkanPath = Join-Path $buildDir 'bin\ghostty-vulkan.exe'
    Write-Fixture $vulkanPath 'Vulkan renderer executable'
    Invoke-Install
    $vulkanTarget = Get-ShortcutTarget
    $vulkanBuild = Split-Path -Parent $vulkanTarget
    Assert-True ($vulkanTarget -ne $updatedPair) 'adding Vulkan creates a new deployment'
    Assert-True ((Split-Path -Leaf $vulkanTarget) -eq 'ghostty.exe') 'the shortcut still starts the primary executable'
    Assert-True ([IO.File]::ReadAllText((Join-Path $vulkanBuild 'ghostty-vulkan.exe')) -eq 'Vulkan renderer executable') 'the deployment includes the Vulkan executable'
    Assert-True ([IO.File]::Exists((Join-Path $vulkanBuild 'ghostty-d3d12.exe'))) 'the deployment also includes DirectX 12'
    Remove-Item -LiteralPath $vulkanPath

    Remove-Item -LiteralPath $rendererPath
    Invoke-Install
    Assert-True ((Get-ShortcutTarget) -eq $compilerTarget) 'removing the optional D3D12 executable reuses the single-renderer deployment'

    Write-Output "PowerShell $($PSVersionTable.PSVersion) development install checks passed"
} finally {
    if ($null -ne $heldExe) { $heldExe.Dispose() }
    if ($null -ne $shell) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
