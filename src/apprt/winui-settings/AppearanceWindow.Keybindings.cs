using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Madotty.Settings;

internal sealed partial class AppearanceWindow
{
    private Grid BuildKeybindings(HostConnection connection)
    {
        var page = new Grid { MaxWidth = 680, Padding = new Thickness(28, 22, 28, 24), RowSpacing = 14 };
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        page.Children.Add(PageHeading(UiText.Get("Keybindings")));

        var search = new TextBox { PlaceholderText = UiText.Get("SearchActions") };
        BindInterfaceFont(search);
        AutomationProperties.SetName(search, UiText.Get("SearchKeybindings"));
        AutomationProperties.SetAutomationId(search, "keybindings-search");
        Grid.SetRow(search, 1);
        page.Children.Add(search);

        var list = new ItemsRepeater { ItemTemplate = new KeybindingRows(ink, muted) };
        var scroll = new ScrollViewer
        {
            Content = list,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            IsTabStop = true
        };
        AutomationProperties.SetName(scroll, UiText.Get("Keybindings"));
        AutomationProperties.SetAutomationId(scroll, "keybindings-list");
        var notice = Text(UiText.Get("LoadingKeybindings"), 14, muted, false);
        notice.Margin = new Thickness(16);
        notice.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetLiveSetting(notice, AutomationLiveSetting.Polite);
        AutomationProperties.SetAutomationId(notice, "keybindings-status");
        var body = new Grid();
        body.Children.Add(scroll);
        body.Children.Add(notice);
        var card = new Border
        {
            Child = body, Background = panel, BorderBrush = edge,
            BorderThickness = new Thickness(1), CornerRadius = SectionCorners
        };
        Grid.SetRow(card, 2);
        page.Children.Add(card);

        KeybindingDisplay[]? bindings = null;
        bool loading = false;
        void Refresh()
        {
            if (bindings is null)
                return;
            var terms = search.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            var visible = terms.Length == 0 ? bindings : bindings.Where(binding => binding.Matches(terms)).ToArray();
            list.ItemsSource = visible;
            notice.Text = bindings.Length == 0 ? UiText.Get("NoKeybindings") : UiText.Get("NoKeybindingMatches");
            notice.Visibility = visible.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        search.TextChanged += (_, _) => Refresh();
        page.Loaded += async (_, _) =>
        {
            if (bindings is not null || loading || closed)
                return;

            loading = true;
            notice.Text = UiText.Get("LoadingKeybindings");
            try
            {
                var rows = new List<KeybindingDisplay>();
                uint offset = 0;
                while (!closed)
                {
                    var reply = await connection.SendAsync("keybindings", offset: offset);
                    if (!reply.Ok || reply.Keybindings is not { } result)
                    {
                        notice.Text = reply.Message ?? UiText.Get("LoadKeybindingsFailed");
                        return;
                    }
                    rows.AddRange(result.Rows.Select(row => new KeybindingDisplay(row)));
                    if (result.NextOffset is not { } next)
                        break;
                    if (next <= offset)
                        throw new IOException(UiText.Get("KeybindingListStalled"));
                    offset = next;
                }
                if (!closed)
                {
                    bindings = rows.OrderBy(row => row.Title, StringComparer.OrdinalIgnoreCase)
                        .ThenBy(row => row.Shortcut, StringComparer.OrdinalIgnoreCase).ToArray();
                    Refresh();
                }
            }
            catch (IOException exception)
            {
                notice.Text = exception.Message;
            }
            finally
            {
                loading = false;
            }
        };
        return page;
    }

    private sealed partial class KeybindingRows(Brush ink, Brush muted) : IElementFactory
    {
        private readonly FontFamily mono = new("Consolas");

        public UIElement GetElement(ElementFactoryGetArgs args)
        {
            var binding = (KeybindingDisplay)args.Data;
            var row = new Grid { Padding = new Thickness(14, 8, 14, 8), ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
            var action = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            var title = Text(binding.Title, 14, ink, false);
            title.TextWrapping = TextWrapping.Wrap;
            action.Children.Add(title);
            if (binding.Scope.Length != 0)
            {
                var scope = Text(binding.Scope, 12, muted, false);
                scope.TextWrapping = TextWrapping.Wrap;
                action.Children.Add(scope);
            }

            var shortcut = Text(binding.Shortcut, 13, muted, false);
            shortcut.FontFamily = mono;
            shortcut.TextWrapping = TextWrapping.Wrap;
            shortcut.TextAlignment = TextAlignment.Right;
            shortcut.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(shortcut, 1);
            row.Children.Add(action);
            row.Children.Add(shortcut);
            ToolTipService.SetToolTip(row, binding.Definition);
            return row;
        }

        public void RecycleElement(ElementFactoryRecycleArgs args)
        {
            if (args.Parent is Panel parent)
                parent.Children.Remove(args.Element);
        }
    }
}

internal sealed class KeybindingDisplay
{
    internal string Title { get; }
    internal string Shortcut { get; }
    internal string Scope { get; }
    internal string Definition { get; }

    internal KeybindingDisplay(KeybindingSnapshot row)
    {
        Title = string.Join(" → ", row.Actions.Select((action, index) =>
        {
            var builtIn = row.BuiltinTitles is { } flags && index < flags.Length && flags[index];
            var suppliedTitle = index < row.Titles.Length ? row.Titles[index] : "";
            if (suppliedTitle.Length == 0 || (builtIn && UiText.Culture.TwoLetterISOLanguageName == "ja"))
                return ActionTitle(action);
            return suppliedTitle;
        }));
        Shortcut = string.Join(" › ", row.Trigger.Split('>').Select(step =>
            string.Join("+", step.Split('+').Select(key => key == "super" ? "Win" : Capitalize(key.Replace('_', ' '))))));
        var scope = new List<string>();
        if (row.Table is { } table) scope.Add(UiText.Format("BindingTable", table));
        if (row.Global) scope.Add(UiText.Get("Global"));
        if (row.All) scope.Add(UiText.Get("AllTerminals"));
        if (!row.Consumed) scope.Add(UiText.Get("PassInput"));
        if (row.Performable) scope.Add(UiText.Get("WhenAvailable"));
        Scope = string.Join(" · ", scope);
        var trigger = row.Trigger;
        if (row.Performable) trigger = "performable:" + trigger;
        if (!row.Consumed) trigger = "unconsumed:" + trigger;
        if (row.All) trigger = "all:" + trigger;
        if (row.Global) trigger = "global:" + trigger;
        if (row.Table is { } tableName) trigger = $"{tableName}/{trigger}";
        Definition = string.Join("\n", row.Actions.Select((action, index) => $"{(index == 0 ? trigger : "chain")}={action}"));
    }

    internal bool Matches(string[] terms) => terms.All(term => Title.Contains(term, StringComparison.OrdinalIgnoreCase) ||
        Shortcut.Contains(term, StringComparison.OrdinalIgnoreCase) || Scope.Contains(term, StringComparison.OrdinalIgnoreCase) ||
        Definition.Contains(term, StringComparison.OrdinalIgnoreCase));

    private static string ActionTitle(string action)
    {
        var separator = action.IndexOf(':');
        var name = separator < 0 ? action : action[..separator];
        var title = UiText.TryGet("Action_" + name) ?? Capitalize(name.Replace('_', ' '));
        if (separator < 0) return title;
        var argument = action[(separator + 1)..];
        if (name is "new_split" or "goto_split" or "goto_window" or "navigate_search" or
            "adjust_selection" or "copy_to_clipboard" or "inspector")
            argument = UiText.TryGet("Option_" + argument) ?? argument;
        return $"{title} ({argument})";
    }

    internal static bool LocalizationSmoke()
    {
        var previous = UiText.Culture.Name;
        try
        {
            var row = new KeybindingSnapshot("ctrl+t", null, ["new_tab", "text:right"], ["New Tab", "My title"],
                false, false, true, false, [true, false]);
            UiText.Initialize("ja-JP");
            var japanese = new KeybindingDisplay(row);
            var legacy = new KeybindingDisplay(row with { BuiltinTitles = null });
            if (japanese.Title != "新しいタブを開く → My title" || legacy.Title != "New Tab → My title" ||
                !japanese.Definition.Contains("text:right", StringComparison.Ordinal)) return false;
            UiText.Initialize("fr-FR");
            return UiText.Get("Save") == "Save" && new KeybindingDisplay(row).Title == legacy.Title;
        }
        finally { UiText.Initialize(previous); }
    }

    private static string Capitalize(string value) => value.Length == 0 ? value : char.ToUpperInvariant(value[0]) + value[1..];
}
