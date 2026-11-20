#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$manager = [Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType=WindowsRuntime]::new()
foreach ($package in (Get-AppxPackage -Name 'Madotty.TerminalHandoff')) {
    $registered = $manager.FindPackageForUser('', $package.PackageFullName)
    if ($registered.UserExternalPath -and
        [IO.Path]::GetFullPath($registered.UserExternalPath).TrimEnd('\') -ieq $root) {
        Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
    }
}
