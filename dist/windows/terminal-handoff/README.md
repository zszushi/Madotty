# Windows default terminal package

Use the Madotty build prefix for the console delegate and handoff proxy. Run the commands below from the repository root on Windows with Windows SDK 10.0.26100.0 and the Visual Studio x64 C++ tools installed.

```powershell
.\dist\windows\terminal-handoff\build-openconsole.ps1 -BuildDir .\zig-out
.\dist\windows\build-terminal-handoff-proxy.ps1 -BuildDir .\zig-out
.\dist\windows\terminal-handoff\build-sparse-package.ps1 -BuildDir .\zig-out -Publisher 'CN=Madotty Validation' -Version '1.0.0.0' -StageInstall
```

The last command builds an unsigned `Madotty.TerminalHandoff.msix`. It packages the proxy DLL, Ghostty logos, and the applicable licenses. MakeAppx uses `/nv` because the console and terminal executables resolve from the installation directory specified at registration. You can omit `-StageInstall` for a package-only build.

With `-StageInstall`, the script also creates `terminal-handoff-install` in the build prefix. It uses the flat portable layout and embeds the package identity into copies of `ghostty.exe` and `Madotty.OpenConsole.exe` while preserving their existing application manifests. It keeps the bundled `OpenConsole.exe`, ConPTY, and license files beside them. Use a fresh build prefix when staging another build.

For release, use the signing certificate's exact subject as `-Publisher`. Sign the MSIX using a certificate trusted by the target machine, and sign the external executables after staging if the release uses Authenticode. Place the staged files in a stable installation directory. Register the signed package per user with `Add-AppxPackage -Path $package -ExternalLocation $installDirectory` using absolute paths. Registration adds the app's extension declarations. The user chooses the default terminal in Windows. [Microsoft's sparse package documentation](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps)

## Include default terminal integration in the MSI or portable ZIP

Build the OpenConsole delegate and proxy in the final build prefix using the first two commands above. Stage the integration files in a fresh directory on the same drive. Use a four-part package version that increases with each published update.

```powershell
.\dist\windows\terminal-handoff\build-sparse-package.ps1 -BuildDir $prefix -Publisher $certificateSubject -Version $packageVersion -DistributionDir $handoff
signtool sign /fd SHA256 /sha1 $signerThumbprint /tr $timestampUrl /td SHA256 "$handoff\Madotty.TerminalHandoff.msix"
if ($LASTEXITCODE) { throw 'MSIX signing failed.' }
.\dist\windows\build-installer.ps1 -BuildDir $prefix -DxcDir $dxc -HandoffDir $handoff `
    -SigningCertificateThumbprint $signerThumbprint -TimestampUrl $timestampUrl
```

For a direct public release, use a publicly trusted code-signing identity and its provider's RFC 3161 timestamp URL. The MSI builder uses SignTool from the Windows SDK on PATH, or the executable supplied with `-SignTool`. It verifies the signed and timestamped installer before moving it into the output directory. A signing service can also sign the finished MSI externally. To build a regular unsigned installer without default terminal integration, supply just `-BuildDir` and `-DxcDir`.

Pass the same directory to `bash dist/windows/package.sh --full-build=<prefix> --dxc-dir=<dxc> --handoff-dir=<handoff>` for the ZIP. Both packagers verify the MSIX signature and the SHA-256 hashes of its external files. Signers using a remote signing service may sign the staged MSIX there and return it to the same directory. The package contains hashes of the final staged files, so changing the external files requires a new package and signature.

The distributable layout keeps the regular `ghostty.exe` and adds an identity-tagged `Madotty.Terminal.exe`, the console delegate, notices, proxy and signed MSIX next to it. In Madotty Settings, register the package, then select **Madotty** in Windows Settings. Keep a portable installation at the same path after registering. Run the installed `unregister-handoff.ps1` in Windows PowerShell before moving or deleting a registered portable copy. A full MSI uninstall removes the current user's registration when it points to that installation.

## Disposable Windows 11 guest smoke test

Use a checkpointed VM or Windows Sandbox with a visible interactive desktop and enough graphics support to run the staged terminal. Copy the signed MSIX, the complete staged external installation, `test-sparse-package.ps1`, and `NativeConsoleProbe.cs` into the guest. Use a guest-trusted test certificate when testing a development signing identity.

Run the following in Windows PowerShell 5.1 in the guest, with `$package` and `$installDirectory` set to the corresponding absolute guest paths.

```powershell
$baseline = Join-Path $env:TEMP 'madotty-default-before.json'
.\test-sparse-package.ps1 -Phase Capture -BaselinePath $baseline
Add-AppxPackage -Path $package -ExternalLocation $installDirectory
.\test-sparse-package.ps1 -Phase Catalog
.\test-sparse-package.ps1 -Phase Restored -BaselinePath $baseline
```

Open **Settings → System → Advanced → Terminal** in Windows 11 25H2 or later and choose **Madotty**. On earlier Windows 11 versions, look for Terminal under **For developers**. Close any staged Madotty windows so the launch test measures cold activation. [Microsoft's Windows Settings documentation](https://learn.microsoft.com/en-us/windows/advanced-settings)

```powershell
.\test-sparse-package.ps1 -Phase Launch -DisposableVM -InstallDirectory $installDirectory
```

The test starts a new native console process and checks that the installed console delegate and terminal both start. It also checks that a title set by the console client appears in the Madotty window. The script reads the selection and catalogs, and it terminates only its own console client.

Choose the original default in Windows Settings, then verify the restored effective pair and unregister the package inside the guest.

```powershell
.\test-sparse-package.ps1 -Phase Restored -BaselinePath $baseline
Get-AppxPackage -Name 'Madotty.TerminalHandoff' | Remove-AppxPackage
.\test-sparse-package.ps1 -Phase Restored -BaselinePath $baseline
```
