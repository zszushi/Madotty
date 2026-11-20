using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Madotty.Settings;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            return args switch
            {
                ["--host"] => RunHosted(),
                ["--smoke"] => AppearanceWindow.Smoke(),
                [] => Run(HostSnapshot.Preview, null),
                _ => 2
            };
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"Madotty Settings: {exception.Message}");
            return 1;
        }
    }

    private static int RunHosted()
    {
        using var host = new HostConnection();
        return Run(host.ReadSnapshot(), host);
    }

    private static int Run(HostSnapshot initial, HostConnection? host)
    {
        UiText.Initialize(initial.UiLanguage);
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new SettingsApp(initial, host);
        });
        return Environment.ExitCode;
    }

}

public sealed partial class SettingsApp : Application
{
    private readonly HostSnapshot initial;
    private readonly HostConnection? host;
    private AppearanceWindow? window;

    internal SettingsApp(HostSnapshot initial, HostConnection? host)
    {
        this.initial = initial;
        this.host = host;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            // App.xaml supplies the SDK-generated XAML metadata and merged PRI.
            // Load control styles after the app starts from that resource index.
            Resources.MergedDictionaries.Add(new XamlControlsResources());
            Resources["ControlCornerRadius"] = new CornerRadius(6);
            Resources["OverlayCornerRadius"] = new CornerRadius(10);
            window = new AppearanceWindow(initial, host);
            window.Activate();
            host?.Listen(window.DispatcherQueue, window.CloseFromHost);
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"Madotty Settings: {exception.Message}");
            Environment.ExitCode = 1;
            Exit();
        }
    }
}
