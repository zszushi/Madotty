using System.Globalization;
using System.Resources;
using System.Runtime.InteropServices;

namespace Madotty.Settings;

internal static class UiText
{
    private static readonly ResourceManager Resources = new("Madotty.Settings.Strings", typeof(UiText).Assembly);
    internal static CultureInfo Culture { get; private set; } = CultureInfo.GetCultureInfo("en");

    [DllImport("kernel32.dll")]
    private static extern ushort GetThreadUILanguage();

    internal static void Initialize(string? requestedLanguage = null)
    {
        CultureInfo preferred;
        try
        {
            preferred = requestedLanguage is null
                ? CultureInfo.GetCultureInfo(GetThreadUILanguage())
                : CultureInfo.GetCultureInfo(requestedLanguage);
        }
        catch (CultureNotFoundException)
        {
            preferred = CultureInfo.CurrentUICulture;
        }
        Culture = CultureInfo.GetCultureInfo(preferred.TwoLetterISOLanguageName == "ja" ? "ja-JP" : "en-US");
        CultureInfo.CurrentUICulture = Culture;
        CultureInfo.DefaultThreadCurrentUICulture = Culture;
    }

    internal static string Get(string key) => Resources.GetString(key, Culture) ??
        throw new MissingManifestResourceException($"Missing setting string '{key}'.");

    internal static string? TryGet(string key) => Resources.GetString(key, Culture);

    internal static string Format(string key, params object[] arguments) =>
        string.Format(CultureInfo.CurrentCulture, Get(key), arguments);
}
