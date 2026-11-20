using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Madotty.Settings;

internal sealed partial class AppearanceWindow
{
    private readonly bool themeEditorAvailable;
    private readonly AutoSuggestBox lightTerminalTheme = new() { PlaceholderText = UiText.Get("SearchThemes") };
    private readonly AutoSuggestBox darkTerminalTheme = new() { PlaceholderText = UiText.Get("SearchThemes") };
    private readonly ToggleSwitch separateTerminalThemes = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private Grid? darkThemeRow;
    private TextBlock? lightThemeLabel;
    private string[]? themeCatalog;
    private AutoSuggestBox? themeSearch;
    private bool loadingThemes;

    private record struct ThemeDraft(bool Separate, string Light, string Dark)
    {
        internal ThemeDraft(string? light, string? dark) : this(
            !string.Equals(light, dark, StringComparison.Ordinal), light ?? "", dark ?? "")
        { }

        internal bool IsValid => (!Separate || (Light.Length != 0 && Dark.Length != 0)) &&
            Light.IndexOfAny(['\r', '\n', '\0']) < 0 && Dark.IndexOfAny(['\r', '\n', '\0']) < 0;

        internal string Value => Separate ? PairValue(Light, Dark) : SingleValue(Light);

        private static string SingleValue(string name)
        {
            var colon = name.IndexOf(':');
            return name.IndexOfAny([',', '=']) >= 0 || (colon >= 0 && colon != 1)
                ? PairValue(name, name) : name;
        }

        private static string PairValue(string light, string dark) => $"light:{Quoted(light)},dark:{Quoted(dark)}";

        // Ghostty reads quoted components as Zig string literals.
        private static string Quoted(string name) => $"\"{name.Replace("\\", "\\\\").Replace("\"", "\\\"")}\"";
    }

    private StackPanel BuildTerminalTheme(HostConnection connection)
    {
        var lightRow = Row(UiText.Get("Theme"), lightTerminalTheme, lightTerminalTheme, "terminal-theme-light");
        lightThemeLabel = (TextBlock)lightRow.Children[0];
        darkThemeRow = Row(UiText.Get("DarkTheme"), darkTerminalTheme, darkTerminalTheme, "terminal-theme-dark");
        foreach (var box in new[] { lightTerminalTheme, darkTerminalTheme })
        {
            box.GotFocus += async (_, _) => await SuggestTerminalThemes(connection, box);
            box.TextChanged += async (_, args) =>
            {
                Update();
                if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
                    await SuggestTerminalThemes(connection, box);
            };
            box.SuggestionChosen += (_, args) =>
            {
                if (args.SelectedItem is string name)
                    box.Text = name;
            };
        }
        separateTerminalThemes.Toggled += (_, _) =>
        {
            if (separateTerminalThemes.IsOn && darkTerminalTheme.Text.Length == 0)
                darkTerminalTheme.Text = lightTerminalTheme.Text;
            PresentThemeMode();
            Update();
        };
        return Section(UiText.Get("TerminalColors"),
            Row(UiText.Get("SeparateThemes"), separateTerminalThemes, separateTerminalThemes, "separate-terminal-themes"),
            lightRow, darkThemeRow);
    }

    private void PresentTerminalTheme(ThemeDraft draft)
    {
        lightTerminalTheme.Text = draft.Light;
        darkTerminalTheme.Text = draft.Dark;
        separateTerminalThemes.IsOn = draft.Separate;
        PresentThemeMode();
    }

    private void PresentThemeMode()
    {
        lightThemeLabel!.Text = separateTerminalThemes.IsOn ? UiText.Get("LightTheme") : UiText.Get("Theme");
        darkThemeRow!.Visibility = separateTerminalThemes.IsOn ? Visibility.Visible : Visibility.Collapsed;
    }

    private ThemeDraft ReadTerminalTheme() => new(separateTerminalThemes.IsOn,
        lightTerminalTheme.Text.Trim(), darkTerminalTheme.Text.Trim());

    private void SetThemeEditorEnabled(bool enabled)
    {
        lightTerminalTheme.IsEnabled = darkTerminalTheme.IsEnabled = separateTerminalThemes.IsEnabled = enabled;
    }

    private async Task SuggestTerminalThemes(HostConnection connection, AutoSuggestBox box)
    {
        if (closed || busy)
            return;
        themeSearch = box;
        if (themeCatalog is null)
        {
            if (loadingThemes)
                return;

            loadingThemes = true;
            try
            {
                var themes = new List<string>();
                uint offset = 0;
                while (!closed)
                {
                    var reply = await connection.SendAsync("themes", offset: offset);
                    if (!reply.Ok || reply.Themes is not { } page)
                    {
                        if (!closed && !busy && box.IsLoaded)
                            status.Text = reply.Message ?? UiText.Get("LoadThemesFailed");
                        return;
                    }
                    themes.AddRange(page.Names);
                    if (page.NextOffset is not { } next)
                        break;
                    if (next <= offset)
                        throw new IOException(UiText.Get("ThemeListStalled"));
                    offset = next;
                }
                themeCatalog = themes.ToArray();
            }
            catch (IOException exception)
            {
                if (!closed && !busy && box.IsLoaded)
                    status.Text = exception.Message;
            }
            finally
            {
                loadingThemes = false;
            }
        }

        if (!closed && !busy && themeCatalog is not null && themeSearch is { IsLoaded: true } editor &&
            ContainsKeyboardFocus(editor))
        {
            var query = editor.Text.Trim();
            var matches = themeCatalog.Where(name => name.Contains(query, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(name => name.StartsWith(query, StringComparison.OrdinalIgnoreCase))
                .Take(12).ToArray();
            editor.ItemsSource = matches;
            editor.IsSuggestionListOpen = matches.Length != 0;
        }
    }

    private static bool ContainsKeyboardFocus(AutoSuggestBox editor)
    {
        // The editable text is a child of the AutoSuggestBox.
        var focused = FocusManager.GetFocusedElement(editor.XamlRoot) as DependencyObject;
        while (focused is not null)
        {
            if (focused == editor)
                return true;
            focused = VisualTreeHelper.GetParent(focused);
        }
        return false;
    }
}
