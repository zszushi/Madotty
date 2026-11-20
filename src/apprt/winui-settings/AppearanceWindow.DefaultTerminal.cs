using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Win32;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Xml.Linq;
using Windows.ApplicationModel.AppExtensions;
using Windows.Foundation.Collections;
using Windows.Management.Deployment;
using Windows.System;

namespace Madotty.Settings;

internal sealed partial class AppearanceWindow
{
    private static readonly Guid ConsoleDelegate = new("DA74EFEB-11F3-4B6A-8944-E5021D6E02FF");
    private static readonly Guid TerminalDelegate = new("A3A39CB0-46F7-4D5D-954E-F311DAE8EB6A");

    private static async Task<HashSet<string>> FindTerminalExtensions(string contract, Guid expected)
    {
        var packages = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var extension in await AppExtensionCatalog.Open(contract).FindAllAsync())
        {
            if (extension.Package.Id.Name != "Madotty.TerminalHandoff" || !extension.Package.Status.VerifyIsOK())
                continue;
            var properties = await extension.GetExtensionPropertiesAsync();
            if (properties.TryGetValue("Clsid", out var property) && property is IPropertySet clsid &&
                clsid.TryGetValue("#text", out var value) && Guid.TryParse(value as string, out var guid) && guid == expected)
                packages.Add(extension.Package.Id.FullName);
        }
        return packages;
    }

    private static async Task<bool> TerminalRegistered()
    {
        var consoles = await FindTerminalExtensions("com.microsoft.windows.console.host", ConsoleDelegate);
        if (consoles.Count == 0) return false;
        return consoles.Overlaps(await FindTerminalExtensions("com.microsoft.windows.terminal.host", TerminalDelegate));
    }

    private static bool MadottyIsDefault()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Console\%%Startup");
        return Guid.TryParse(key?.GetValue("DelegationConsole") as string, out var console) && console == ConsoleDelegate &&
            Guid.TryParse(key.GetValue("DelegationTerminal") as string, out var terminal) && terminal == TerminalDelegate;
    }

    private Grid DefaultTerminalRow()
    {
        var info = Text("", 14, muted, false);
        info.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetAutomationId(info, "default-terminal-status");
        var action = new Button { HorizontalAlignment = HorizontalAlignment.Left, Content = UiText.Get("Register"), IsEnabled = false };
        var group = new StackPanel { Spacing = 4, Children = { info, action } };
        var row = Row(UiText.Get("DefaultTerminal"), group, action, "default-terminal-action");
        var label = (TextBlock)row.Children[0];
        bool pending = false;

        Task<TerminalCapability> Inspect() => TerminalCapability.Check(
            OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000), TerminalRegistered,
            () => Task.Run(TerminalPackage), MadottyIsDefault);

        void Display(TerminalCapability capability, string? failure = null)
        {
            action.Content = UiText.Get(capability.Registered ? "ChooseInWindows" : "Register");
            action.IsEnabled = capability.Available;
            label.Foreground = capability.Available ? ink : muted;
            info.Text = failure ?? (capability.StatusKey is string key ? UiText.Get(key) : "");
            info.Visibility = info.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        async Task Refresh()
        {
            if (!row.IsLoaded || pending) return;
            pending = true;
            action.IsEnabled = false;
            try
            {
                var capability = await Inspect();
                if (!closed) Display(capability);
            }
            finally { pending = false; }
        }

        row.Loaded += async (_, _) => await Refresh();
        Activated += async (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated) await Refresh();
        };
        action.Click += async (_, _) =>
        {
            if (pending || !action.IsEnabled) return;
            pending = true;
            action.IsEnabled = false;
            string? failure = null;
            try
            {
                // Recheck on invocation: registration or the bundle can change
                // while the settings page stays open.
                var capability = await Inspect();
                if (closed || !capability.Available) return;
                if (capability.Package is string package)
                {
                    var result = await new PackageManager().AddPackageByUriAsync(new Uri(package), new AddPackageOptions
                    {
                        ExternalLocationUri = new Uri(Path.GetDirectoryName(package)! + Path.DirectorySeparatorChar)
                    });
                    if (result.ExtendedErrorCode is Exception error) throw error;
                    if (!await TerminalRegistered()) throw new InvalidOperationException(UiText.Get("TerminalNotListed"));
                }
                if (!closed && !await Launcher.LaunchUriAsync(new Uri("ms-settings:developers")))
                    throw new InvalidOperationException(UiText.Get("OpenSettingsFailed"));
            }
            catch (Exception ex) { failure = ex.Message; }
            finally
            {
                if (!closed)
                {
                    var capability = await Inspect();
                    if (!closed) Display(capability, failure);
                }
                pending = false;
            }
        };
        return row;
    }

    private static string? TerminalPackage()
    {
        var directory = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
        var package = Path.Combine(directory, "Madotty.TerminalHandoff.msix");
        if (!File.Exists(package) || !File.Exists(Path.Combine(directory, "Madotty.OpenConsole.exe")) ||
            !File.Exists(Path.Combine(directory, "Madotty.Terminal.exe")) ||
            !File.Exists(Path.Combine(directory, "Madotty.TerminalHandoffProxy.dll"))) return null;
        if (!TrustedPackage(package)) return null;
        using var archive = ZipFile.OpenRead(package);
        using var manifest = archive.GetEntry("AppxManifest.xml")?.Open();
        if (manifest is null) return null;
        var root = XDocument.Load(manifest).Root;
        XNamespace schema = "http://schemas.microsoft.com/appx/manifest/foundation/windows10";
        return (string?)root?.Element(schema + "Identity")?.Attribute("Name") == "Madotty.TerminalHandoff"
            ? package : null;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct TrustFile
    {
        public uint Size;
        [MarshalAs(UnmanagedType.LPWStr)] public string Path;
        public nint Handle, Subject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData
    {
        public uint Size;
        public nint PolicyCallback, SipClient;
        public uint UiChoice, RevocationChecks, UnionChoice;
        public nint File;
        public uint StateAction;
        public nint StateData, Url;
        public uint ProviderFlags, UiContext;
        public nint SignatureSettings;
    }

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern int WinVerifyTrust(nint window, in Guid action, ref TrustData data);

    private static bool TrustedPackage(string path)
    {
        var file = new TrustFile { Size = (uint)Marshal.SizeOf<TrustFile>(), Path = path };
        var data = new TrustData
        {
            Size = (uint)Marshal.SizeOf<TrustData>(), UiChoice = 2, UnionChoice = 1,
            File = Marshal.AllocHGlobal((int)file.Size), ProviderFlags = 0x1000 // Cache-only trust check for the UI.
        };
        try
        {
            Marshal.StructureToPtr(file, data.File, false);
            var policy = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
            return WinVerifyTrust(-1, in policy, ref data) == 0;
        }
        finally
        {
            Marshal.DestroyStructure<TrustFile>(data.File);
            Marshal.FreeHGlobal(data.File);
        }
    }
}
