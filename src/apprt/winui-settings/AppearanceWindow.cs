using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Madotty.Settings;

internal sealed partial class AppearanceWindow : Window
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);
    private record struct Draft(double FontSize, int Theme, double Opacity, int Material, int TabBar,
        string? Graphics = null, int NewTabPosition = 0, bool InheritDirectory = true, string? StartupProfile = null,
        int CursorStyle = 0, bool CopyOnSelect = false, int RightClickAction = 0, PrivacyDraft? Privacy = null,
        bool ShowProgress = true, ThemeDraft? TerminalTheme = null, string UiFontFamily = "", string TerminalFont = "");
    private static readonly string[] ThemeKeys = ["auto", "system", "light", "dark"];
    private static readonly string[] MaterialKeys = ["auto", "solid", "mica", "acrylic"];
    private static readonly string[] TabBarKeys = ["always", "auto", "never"];
    private static readonly string[] TabPositionKeys = ["current", "end"];
    private static readonly string[] CursorStyleKeys = ["block", "bar", "underline", "block_hollow"];
    private static readonly string[] RightClickKeys = ["context-menu", "paste", "copy", "copy-or-paste", "ignore"];
    private static readonly CornerRadius SectionCorners = new(8);

    private readonly HostConnection? host;
    private readonly TerminalColors? terminalColors;
    private readonly bool writable;
    private Draft saved;
    private bool busy;
    private bool closed;
    private bool? lightPalette;
    private readonly SolidColorBrush canvas = new();
    private readonly SolidColorBrush panel = new();
    private readonly SolidColorBrush edge = new();
    private readonly SolidColorBrush ink = new();
    private readonly SolidColorBrush muted = new();
    private readonly SolidColorBrush accent = new();
    private readonly SolidColorBrush onAccent = new();
    private readonly SolidColorBrush selection = new() { Opacity = 0.18 };
    private readonly Grid root = new();
    private readonly ContentPresenter content = new()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch
    };
    private readonly NavigationView navigation = new()
    {
        PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
        OpenPaneLength = 168,
        IsPaneOpen = true,
        IsPaneToggleButtonVisible = false,
        IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
        IsSettingsVisible = false,
        AlwaysShowHeader = false
    };
    private readonly NumberBox fontSize = new()
    {
        Minimum = 1, Maximum = 255, SmallChange = 1, LargeChange = 4,
        SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact
    };
    private readonly ComboBox theme = new();
    private readonly ComboBox uiFont = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox terminalFont = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly string[] terminalFallbacks;
    private readonly Slider opacity = new() { Minimum = 0, Maximum = 100, StepFrequency = 0.1, SmallChange = 1 };
    private readonly ComboBox material = new();
    private readonly ComboBox tabBar = new();
    private readonly ComboBox newTabPosition = new();
    private readonly ToggleSwitch inheritDirectory = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ToggleSwitch showProgress = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ComboBox cursorStyle = new();
    private readonly ComboBox rightClickAction = new();
    private readonly ToggleSwitch copyOnSelect = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ComboBox? startupProfile;
    private readonly ComboBox? graphics;
    private readonly Button save = new() { Content = UiText.Get("Save") };
    private readonly Button cancel = new() { Content = UiText.Get("Cancel") };
    private readonly Button editConfig = new() { Content = UiText.Get("EditConfig") };
    private readonly TextBlock status = new();
    private readonly TextBlock percent = new();

    internal AppearanceWindow(HostSnapshot initial, HostConnection? host)
    {
        this.host = host;
        terminalColors = initial.Colors;
        writable = initial.Writable;
        privacyAvailable = initial.Privacy is not null;
        themeEditorAvailable = host is not null && initial.ThemesAvailable;
        var systemMaterialsAvailable = (initial.ActiveRenderer ?? initial.Renderer?.Active) != "vulkan";
        var materialIndex = Array.IndexOf(MaterialKeys, initial.Backdrop);
        // Compare edits against the effective selection. An unrelated change
        // must preserve the material configured for another renderer.
        if (!systemMaterialsAvailable && materialIndex is 2 or 3)
            materialIndex = 0;
        var profileId = initial.StartupProfile ?? "";
        if (profileId.Length != 0 && initial.Profiles is not null)
            profileId = initial.Profiles.FirstOrDefault(p =>
                string.Equals(p.Id, profileId, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(p.Alias, profileId, StringComparison.OrdinalIgnoreCase))?.Id ?? profileId;
        saved = new(initial.FontSize, Array.IndexOf(ThemeKeys, initial.Theme), initial.OpacityPercent,
            materialIndex, Array.IndexOf(TabBarKeys, initial.TabBar),
            initial.Renderer?.Preference, Array.IndexOf(TabPositionKeys, initial.NewTabPosition),
            initial.TabInheritWorkingDirectory, profileId,
            Array.IndexOf(CursorStyleKeys, initial.CursorStyle), initial.CopyOnSelect,
            Array.IndexOf(RightClickKeys, initial.RightClickAction),
            initial.Privacy is { } privacy ? new PrivacyDraft(privacy) : null, initial.ProgressStyle,
            themeEditorAvailable ? new ThemeDraft(initial.LightTerminalTheme, initial.DarkTerminalTheme) : null,
            initial.UiFontFamily, initial.TerminalFonts.FirstOrDefault() ?? "");
        terminalFallbacks = initial.TerminalFonts.Skip(1).ToArray();
        Closed += (_, _) => closed = true;

        Title = UiText.Get("SettingsTitle");
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Madotty.ico"));
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        AppWindow.Resize(new SizeInt32(Math.Min(work.Width, (int)Math.Round(860 * scale)),
            Math.Min(work.Height, (int)Math.Round(680 * scale))));
        root.Language = UiText.Culture.IetfLanguageTag;
        root.Background = canvas;
        ApplyInterfaceFont(initial.UiFontFamily);
        BindInterfaceFont(navigation);
        root.Resources["NavigationViewSelectionIndicatorForeground"] = accent;
        root.Resources["NavigationViewExpandedPaneBackground"] = panel;
        root.Resources["ComboBoxItemPillFillBrush"] = accent;
        foreach (var state in new[] { "", "PointerOver", "Pressed" })
        {
            root.Resources[$"SliderTrackValueFill{state}"] = accent;
            root.Resources[$"SliderThumbBackground{state}"] = accent;
            root.Resources[$"CheckBoxCheckBackgroundFillChecked{state}"] = accent;
            root.Resources[$"CheckBoxCheckBackgroundStrokeChecked{state}"] = accent;
            root.Resources[$"CheckBoxCheckGlyphForegroundChecked{state}"] = onAccent;
            root.Resources[$"ToggleSwitchFillOn{state}"] = accent;
            root.Resources[$"ToggleSwitchStrokeOn{state}"] = accent;
            root.Resources[$"ToggleSwitchKnobFillOn{state}"] = onAccent;
            root.Resources[$"ListBoxItemBackgroundSelected{state}"] = selection;
        }
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        theme.ItemsSource = new[] { UiText.Get("TerminalBackground"), UiText.Get("System"), UiText.Get("Light"), UiText.Get("Dark") };
        foreach (var (key, label) in MaterialKeys.Zip(new[] { UiText.Get("FollowConfig"), UiText.Get("Solid"), UiText.Get("Mica"), UiText.Get("Acrylic") }))
            material.Items.Add(new ComboBoxItem
            {
                Content = label,
                IsEnabled = systemMaterialsAvailable || key is "auto" or "solid"
            });
        tabBar.ItemsSource = new[] { UiText.Get("Always"), UiText.Get("MultipleTabs"), UiText.Get("Never") };
        newTabPosition.ItemsSource = new[] { UiText.Get("AfterActive"), UiText.Get("AtEnd") };
        cursorStyle.ItemsSource = new[] { UiText.Get("Block"), UiText.Get("Bar"), UiText.Get("Underline"), UiText.Get("HollowBlock") };
        rightClickAction.ItemsSource = new[] { UiText.Get("ContextMenu"), UiText.Get("Paste"), UiText.Get("Copy"), UiText.Get("CopyOrPaste"), UiText.Get("DoNothing") };
        var opacityPair = new Grid { ColumnSpacing = 12 };
        opacityPair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        opacityPair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
        opacityPair.Children.Add(opacity);
        percent.FontSize = 13;
        percent.Foreground = muted;
        percent.HorizontalAlignment = HorizontalAlignment.Right;
        percent.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(percent, 1);
        opacityPair.Children.Add(percent);

        var appearance = new List<UIElement>
        {
            Section(UiText.Get("Typography"), Row(UiText.Get("InterfaceFont"), uiFont, uiFont, "windows-ui-font-family"),
                Row(UiText.Get("TerminalFont"), terminalFont, terminalFont, "font-family"),
                Row(UiText.Get("TerminalFontSize"), fontSize, fontSize, "font-size"))
        };
        if (themeEditorAvailable)
            appearance.Add(BuildTerminalTheme(host!));
        var opacityRow = Row(UiText.Get("WindowOpacity"), opacityPair, opacity, "background-opacity");
        var opacityLabel = (TextBlock)opacityRow.Children[0];
        appearance.Add(Section(UiText.Get("Window"),
            Row(UiText.Get("WindowTheme"), theme, theme, "window-theme"),
            Row(UiText.Get("BackgroundMaterial"), material, material, "windows-background-material"),
            opacityRow));
        var appearancePage = AddPage(UiText.Get("Appearance"), "settings-appearance", appearance.ToArray());

        var startupRows = new List<UIElement> { DefaultTerminalRow() };
        if (initial.Profiles is { } profiles)
        {
            startupProfile = new ComboBox { ItemTemplate = (DataTemplate)Application.Current.Resources["ShellProfileTemplate"] };
            var iconCache = new Dictionary<string, Task<Microsoft.UI.Xaml.Media.ImageSource?>>(StringComparer.OrdinalIgnoreCase);
            void AddProfile(string id, string label, ProfileSnapshot? profile = null, bool enabled = true)
            {
                var choice = new ShellProfileChoice(label, profile);
                var item = new ComboBoxItem { Content = choice, ContentTemplate = startupProfile.ItemTemplate, Tag = id, IsEnabled = enabled };
                AutomationProperties.SetName(item, label);
                startupProfile.Items.Add(item);
            }
            AddProfile("", UiText.Get("FollowConfig"));
            foreach (var profile in profiles)
                AddProfile(profile.Id, profile.Name, profile);
            if (saved.StartupProfile is { Length: > 0 } missing && !profiles.Any(profile => profile.Id == missing))
                AddProfile(missing, UiText.Get("UnavailableProfile"), enabled: false);
            startupProfile.Loaded += async (_, _) =>
            {
                if (startupProfile.SelectedItem is ComboBoxItem { Content: ShellProfileChoice choice })
                    await choice.LoadIcon(iconCache);
            };
            startupProfile.DropDownOpened += async (_, _) =>
            {
                foreach (ComboBoxItem item in startupProfile.Items)
                    await ((ShellProfileChoice)item.Content).LoadIcon(iconCache);
            };
            startupRows.Add(Row(UiText.Get("DefaultProfile"), startupProfile, startupProfile, "windows-default-profile"));
        }
        AddPage(UiText.Get("Startup"), "settings-startup", Section(null, startupRows.ToArray()));

        AddPage(UiText.Get("Terminal"), "settings-terminal",
            Section(UiText.Get("Cursor"), Row(UiText.Get("DefaultShape"), cursorStyle, cursorStyle, "cursor-style")),
            Section(UiText.Get("SelectionMouse"),
                Row(UiText.Get("CopyOnSelect"), copyOnSelect, copyOnSelect, "copy-on-select"),
                Row(UiText.Get("RightClick"), rightClickAction, rightClickAction, "right-click-action")));

        AddPage(UiText.Get("Tabs"), "settings-tabs",
            Section(UiText.Get("TabBar"), Row(UiText.Get("Visibility"), tabBar, tabBar, "window-show-tab-bar")),
            Section(UiText.Get("NewTabs"),
                Row(UiText.Get("Position"), newTabPosition, newTabPosition, "window-new-tab-position"),
                Row(UiText.Get("InheritDirectory"), inheritDirectory, inheritDirectory, "tab-inherit-working-directory")),
            Section(UiText.Get("ProgressIndicators"),
                Row(UiText.Get("ShowProgress"), showProgress, showProgress, "progress-style")));

        var rendering = new List<FrameworkElement>();
        if (initial.Renderer is { } renderer)
        {
            graphics = new ComboBox();
            foreach (var (key, available) in GraphicsChoices(renderer))
            {
                var label = GraphicsLabel(key);
                graphics.Items.Add(new ComboBoxItem
                {
                    Content = available ? label : UiText.Format("UnavailableItem", label),
                    Tag = key,
                    IsEnabled = available
                });
            }

            var hint = Text(GraphicsHint(renderer), 13, muted, false);
            hint.TextWrapping = TextWrapping.Wrap;
            AutomationProperties.SetAutomationId(hint, "windows-renderer-status");
            rendering.Add(Section(null, Row(UiText.Get("GraphicsApi"), graphics, graphics, "windows-renderer"), hint));
        }
        if (initial.Shaders is { } shaders)
            rendering.Add(BuildShaders(shaders));
        if (rendering.Count > 0)
            AddPage(UiText.Get("Rendering"), "settings-graphics", rendering.ToArray());
        if (host is not null && initial.KeybindingsAvailable)
            AddPageContent(UiText.Get("Keybindings"), "settings-keybindings", BuildKeybindings(host));
        if (privacyAvailable)
            AddPage(UiText.Get("Privacy"), "settings-privacy", BuildPrivacy());

        AutomationProperties.SetName(navigation, UiText.Get("SettingsPages"));
        navigation.SelectionChanged += (sender, args) =>
        {
            if (args.SelectedItem is NavigationViewItem { Tag: UIElement page })
                sender.Content = page;
        };
        navigation.SelectedItem = appearancePage;
        root.Children.Add(navigation);
        root.SizeChanged += (_, args) =>
        {
            var mode = args.NewSize.Width < 640 ? NavigationViewPaneDisplayMode.Top : NavigationViewPaneDisplayMode.Left;
            if (navigation.PaneDisplayMode == mode)
                return;
            navigation.PaneDisplayMode = mode;
            if (mode == NavigationViewPaneDisplayMode.Left)
                navigation.IsPaneOpen = true;
        };

        var footer = new Grid { Padding = new Thickness(28, 14, 28, 16), ColumnSpacing = 10 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        status.Foreground = muted;
        status.VerticalAlignment = VerticalAlignment.Center;
        status.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        Grid.SetColumn(status, 1);
        footer.Children.Add(status);
        foreach (var button in new[] { editConfig, cancel, save })
        {
            BindInterfaceFont(button);
            button.Padding = new Thickness(18, 7, 18, 7);
            button.Background = panel;
            button.BorderBrush = edge;
            button.Foreground = ink;
        }
        save.Background = accent;
        save.BorderBrush = accent;
        save.Foreground = onAccent;
        AutomationProperties.SetAutomationId(editConfig, "edit-config");
        AutomationProperties.SetAutomationId(cancel, "cancel-settings");
        AutomationProperties.SetAutomationId(save, "save-settings");
        if (host is not null)
            footer.Children.Add(editConfig);
        Grid.SetColumn(cancel, 2);
        Grid.SetColumn(save, 3);
        footer.Children.Add(cancel);
        footer.Children.Add(save);
        var footerBorder = new Border
        {
            BorderBrush = edge,
            BorderThickness = new Thickness(0, 1, 0, 0),
            Background = panel,
            Child = footer
        };
        Grid.SetRow(footerBorder, 1);
        root.Children.Add(footerBorder);
        content.Content = root;
        Content = content;

        Present(saved);
        // Compare against what the controls actually display, so any initial
        // normalization of an untouched value never turns into a config edit.
        saved = Read();
        fontSize.ValueChanged += (_, _) => Update();
        ConfigureFontPicker(uiFont, true);
        ConfigureFontPicker(terminalFont, false);
        theme.SelectionChanged += (_, _) => Update();
        const double suggestedMaterialOpacity = 70;
        bool suggestedOpacity = false;
        bool UsesSystemMaterial() => material.SelectedIndex is 2 or 3;
        void UpdateOpacityLabel() => opacityLabel.Text = UsesSystemMaterial() ? UiText.Get("TintOpacity") : UiText.Get("WindowOpacity");
        UpdateOpacityLabel();
        opacity.ValueChanged += (_, args) =>
        {
            if (args.NewValue != suggestedMaterialOpacity)
                suggestedOpacity = false;
            Update();
        };
        material.SelectionChanged += (_, _) =>
        {
            UpdateOpacityLabel();
            // At 100% the terminal color covers the whole material. Offer a
            // visible starting tint only when the user chooses the material.
            if (UsesSystemMaterial() && opacity.Value == 100)
            {
                suggestedOpacity = true;
                opacity.Value = suggestedMaterialOpacity;
            }
            else if (!UsesSystemMaterial() && suggestedOpacity)
            {
                suggestedOpacity = false;
                opacity.Value = 100;
            }
            Update();
        };
        tabBar.SelectionChanged += (_, _) => Update();
        newTabPosition.SelectionChanged += (_, _) => Update();
        inheritDirectory.Toggled += (_, _) => Update();
        showProgress.Toggled += (_, _) => Update();
        cursorStyle.SelectionChanged += (_, _) => Update();
        copyOnSelect.Toggled += (_, _) => Update();
        rightClickAction.SelectionChanged += (_, _) => Update();
        if (startupProfile is not null)
            startupProfile.SelectionChanged += (_, _) => Update();
        if (graphics is not null)
            graphics.SelectionChanged += (_, _) => Update();
        save.Click += (_, _) => Save();
        cancel.Click += (_, _) => CloseWindow();
        editConfig.Click += (_, _) => EditConfig();
        Update();
    }

    private NavigationViewItem AddPage(string name, string automationId, params UIElement[] sections)
    {
        var form = new StackPanel { Spacing = 20, Padding = new Thickness(28, 22, 28, 24) };
        form.Children.Add(PageHeading(name));
        foreach (var section in sections)
            form.Children.Add(section);

        var page = new ScrollViewer
        {
            Content = form,
            MaxWidth = 680,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        return AddPageContent(name, automationId, page);
    }

    private TextBlock PageHeading(string name)
    {
        var heading = Text(name, 28, ink, true);
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level1);
        return heading;
    }

    private NavigationViewItem AddPageContent(string name, string automationId, UIElement page)
    {
        var item = new NavigationViewItem { Content = name, Tag = page };
        BindInterfaceFont(item);
        AutomationProperties.SetAutomationId(item, automationId);
        navigation.MenuItems.Add(item);
        return item;
    }

    private StackPanel Section(string? name, params UIElement[] rows)
    {
        var section = new StackPanel { Spacing = 7 };
        if (name is not null)
        {
            var heading = Text(name, 14, muted, true);
            AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
            section.Children.Add(heading);
        }
        var controls = new StackPanel { Spacing = 10, Padding = new Thickness(15, 10, 15, 10) };
        foreach (var row in rows)
            controls.Children.Add(row);
        section.Children.Add(new Border
        {
            Background = panel,
            BorderBrush = edge,
            BorderThickness = new Thickness(1),
            CornerRadius = SectionCorners,
            Child = controls
        });
        return section;
    }

    private Grid Row(string name, FrameworkElement content, Control focusTarget, string automationId)
    {
        BindInterfaceFont(focusTarget);
        if (focusTarget is ToggleSwitch toggle)
        {
            toggle.OnContent = UiText.Get("On");
            toggle.OffContent = UiText.Get("Off");
        }
        var row = new Grid { MinHeight = 34, ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = 230 });
        var label = Text(name, 14, ink, false);
        label.VerticalAlignment = VerticalAlignment.Center;
        label.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetLabeledBy(focusTarget, label);
        AutomationProperties.SetAutomationId(focusTarget, automationId);
        row.Children.Add(label);
        content.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(content, 1);
        row.Children.Add(content);
        return row;
    }

    private static TextBlock Text(string value, double size, Brush brush, bool semibold) => new()
    {
        Text = value, FontSize = size, Foreground = brush,
        FontWeight = semibold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal
    };

    private static IEnumerable<(string Key, bool Available)> GraphicsChoices(RendererSnapshot renderer)
    {
        yield return ("auto", true);
        yield return ("opengl", true);
        if (renderer.D3D12Available || renderer.Preference == "d3d12")
            yield return ("d3d12", renderer.D3D12Available);
        if (renderer.VulkanAvailable || renderer.Preference == "vulkan")
            yield return ("vulkan", renderer.VulkanAvailable);
    }

    private static string GraphicsLabel(string key) => key switch
    {
        "opengl" => "OpenGL",
        "d3d12" => "DirectX 12",
        "vulkan" => "Vulkan",
        _ => UiText.Get("Automatic")
    };

    private static string GraphicsHint(RendererSnapshot renderer)
    {
        var preferred = GraphicsLabel(renderer.Preference);
        var fallback = renderer.Problem switch
        {
            "missing" => " " + UiText.Format("RendererUnavailable", preferred),
            "startup_failed" => " " + UiText.Format("RendererFailed", preferred),
            _ => ""
        };
        return UiText.Format("CurrentRenderer", GraphicsLabel(renderer.Active)) + fallback + "\n" + UiText.Get("NextLaunch");
    }

    private Draft Read() => new(fontSize.Value, theme.SelectedIndex, opacity.Value, material.SelectedIndex,
        tabBar.SelectedIndex, (graphics?.SelectedItem as ComboBoxItem)?.Tag as string,
        newTabPosition.SelectedIndex, inheritDirectory.IsOn, (startupProfile?.SelectedItem as ComboBoxItem)?.Tag as string,
        cursorStyle.SelectedIndex, copyOnSelect.IsOn, rightClickAction.SelectedIndex,
        privacyAvailable ? ReadPrivacy() : null, showProgress.IsOn, themeEditorAvailable ? ReadTerminalTheme() : null,
        SelectedFont(uiFont), SelectedFont(terminalFont));

    private static string SelectedFont(ComboBox picker) =>
        picker.SelectedIndex > 0 ? picker.SelectedItem as string ?? "" : "";

    private static void SetFontChoices(ComboBox picker, string[] choices, string family)
    {
        picker.ItemsSource = choices;
        picker.SelectedIndex = family.Length == 0 ? 0 : Array.IndexOf(choices, family);
    }

    private void ConfigureFontPicker(ComboBox picker, bool previewInterface)
    {
        bool loaded = false;
        picker.DropDownOpened += (_, _) =>
        {
            if (loaded) return;
            loaded = true;
            var family = SelectedFont(picker);
            SetFontChoices(picker, InterfaceFonts.Installed(family), family);
        };
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedIndex < 0) return;
            if (previewInterface) ApplyInterfaceFont(SelectedFont(picker));
            Update();
        };
    }

    private void ApplyInterfaceFont(string name)
    {
        var family = name.Length > 0 ? new FontFamily(name) : FontFamily.XamlAutoFontFamily;
        root.Resources["ContentControlThemeFontFamily"] = family;
        content.FontFamily = family;
    }

    // Existing templates retain resolved theme resources until a theme change.
    // Bind the application's text controls so a font selection previews live.
    // Native icon elements keep their template fonts.
    private void BindInterfaceFont(Control control) => control.SetBinding(Control.FontFamilyProperty, new Binding
    {
        Source = content, Path = new PropertyPath(nameof(ContentPresenter.FontFamily)), Mode = BindingMode.OneWay
    });

    private void Present(Draft draft)
    {
        fontSize.Value = draft.FontSize;
        SetFontChoices(terminalFont, draft.TerminalFont.Length == 0 ? [UiText.Get("SystemDefault")] : [UiText.Get("SystemDefault"), draft.TerminalFont], draft.TerminalFont);
        SetFontChoices(uiFont, draft.UiFontFamily.Length == 0 ? [UiText.Get("SystemDefault")] : [UiText.Get("SystemDefault"), draft.UiFontFamily],
            draft.UiFontFamily);
        theme.SelectedIndex = draft.Theme;
        opacity.Value = draft.Opacity;
        material.SelectedIndex = draft.Material;
        tabBar.SelectedIndex = draft.TabBar;
        newTabPosition.SelectedIndex = draft.NewTabPosition;
        inheritDirectory.IsOn = draft.InheritDirectory;
        showProgress.IsOn = draft.ShowProgress;
        if (draft.TerminalTheme is { } terminalTheme)
            PresentTerminalTheme(terminalTheme);
        cursorStyle.SelectedIndex = draft.CursorStyle;
        copyOnSelect.IsOn = draft.CopyOnSelect;
        rightClickAction.SelectedIndex = draft.RightClickAction;
        if (draft.Privacy is { } privacy)
            PresentPrivacy(privacy);
        if (startupProfile is not null)
            startupProfile.SelectedItem = startupProfile.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Equals(item.Tag, draft.StartupProfile));
        if (graphics is not null)
            graphics.SelectedItem = graphics.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Equals(item.Tag, draft.Graphics));
        Update();
    }

    private static Dictionary<string, object> Edits(Draft saved, Draft draft, string[]? fallbackFamilies = null)
    {
        var edits = new Dictionary<string, object>();
        if (draft.FontSize != saved.FontSize) edits.Add("font-size", draft.FontSize);
        if (draft.TerminalFont != saved.TerminalFont)
        {
            string[] families = draft.TerminalFont.Length == 0 ? [] : [draft.TerminalFont, .. (fallbackFamilies ?? []).Where(f => !StringComparer.OrdinalIgnoreCase.Equals(f, draft.TerminalFont))];
            edits.Add("font-family", families);
        }
        if (draft.UiFontFamily != saved.UiFontFamily) edits.Add("windows-ui-font-family", draft.UiFontFamily);
        if (draft.Theme != saved.Theme) edits.Add("window-theme", ThemeKeys[draft.Theme]);
        if (draft.TabBar != saved.TabBar) edits.Add("window-show-tab-bar", TabBarKeys[draft.TabBar]);
        if (draft.Opacity != saved.Opacity) edits.Add("background-opacity", draft.Opacity / 100);
        if (draft.Material != saved.Material) edits.Add("windows-background-material", MaterialKeys[draft.Material]);
        if (draft.Graphics is not null && draft.Graphics != saved.Graphics)
            edits.Add("windows-renderer", draft.Graphics);
        if (draft.NewTabPosition != saved.NewTabPosition)
            edits.Add("window-new-tab-position", TabPositionKeys[draft.NewTabPosition]);
        if (draft.InheritDirectory != saved.InheritDirectory)
            edits.Add("tab-inherit-working-directory", draft.InheritDirectory);
        if (draft.ShowProgress != saved.ShowProgress)
            edits.Add("progress-style", draft.ShowProgress);
        if (draft.TerminalTheme is { } terminalTheme && terminalTheme.Value != saved.TerminalTheme?.Value)
            edits.Add("theme", terminalTheme.Value);
        if (draft.StartupProfile is not null && draft.StartupProfile != saved.StartupProfile)
            edits.Add("windows-default-profile", draft.StartupProfile);
        if (draft.CursorStyle != saved.CursorStyle)
            edits.Add("cursor-style", CursorStyleKeys[draft.CursorStyle]);
        if (draft.CopyOnSelect != saved.CopyOnSelect)
            edits.Add("copy-on-select", draft.CopyOnSelect ? "clipboard" : "none");
        if (draft.RightClickAction != saved.RightClickAction)
            edits.Add("right-click-action", RightClickKeys[draft.RightClickAction]);
        if (saved.Privacy is { } oldPrivacy && draft.Privacy is { } privacy)
            privacy.AddEdits(oldPrivacy, edits);
        return edits;
    }

    private async void Save()
    {
        if (!save.IsEnabled)
            return;

        var draft = Read();
        if (host is null)
        {
            saved = draft;
            shaderDraft?.SavePreview(ShaderAnimationKeys[shaderAnimation.SelectedIndex]);
            status.Text = UiText.Get("PreviewSaved");
            return;
        }

        var edits = Edits(saved, draft, terminalFallbacks);
        shaderDraft?.AddEdits(edits, ShaderAnimationKeys[shaderAnimation.SelectedIndex]);
        if (edits.Count == 0 || await Send("save", edits))
            CloseWindow();
    }

    private async void EditConfig()
    {
        if (!busy)
            await Send("edit");
    }

    private async Task<bool> Send(string action, Dictionary<string, object>? edits = null)
    {
        busy = true;
        Update();
        try
        {
            var reply = await host!.SendAsync(action, edits);
            if (reply.Ok && action == "save")
                return true;
            busy = false;
            Update();
            if (!reply.Ok)
                status.Text = reply.Message ?? UiText.Get("ChangeFailed");
            return reply.Ok;
        }
        catch (IOException exception)
        {
            busy = false;
            if (!closed)
            {
                Update();
                status.Text = exception.Message;
            }
            return false;
        }
    }

    internal void CloseFromHost()
    {
        if (root.IsLoaded)
        {
            CloseWindow();
            return;
        }
        root.Loaded += CloseWhenLoaded;
    }

    private void CloseWhenLoaded(object sender, RoutedEventArgs args)
    {
        root.Loaded -= CloseWhenLoaded;
        CloseWindow();
    }

    private void CloseWindow()
    {
        // Let control and popup updates finish before destroying their window.
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (!closed)
                Close();
        });
    }

    private void Update()
    {
        var draft = Read();
        percent.Text = $"{draft.Opacity:0.#}%";
        save.IsEnabled = writable && !busy && double.IsFinite(draft.FontSize) &&
            draft.Theme >= 0 && draft.Material >= 0 && draft.TabBar >= 0 && draft.NewTabPosition >= 0 &&
            draft.CursorStyle >= 0 && draft.RightClickAction >= 0 &&
            (draft.Privacy?.IsValid ?? true) &&
            (draft.TerminalTheme?.IsValid ?? true) &&
            (graphics is null || draft.Graphics is not null) && (startupProfile is null || draft.StartupProfile is not null);
        editConfig.IsEnabled = !busy;
        cancel.IsEnabled = !busy;
        foreach (var control in new Control[] { fontSize, uiFont, terminalFont, theme, material, tabBar, newTabPosition, inheritDirectory,
                     showProgress, cursorStyle, copyOnSelect, rightClickAction })
            control.IsEnabled = !busy;
        if (privacyAvailable)
            SetPrivacyEnabled(!busy);
        if (themeEditorAvailable)
            SetThemeEditorEnabled(!busy);
        if (startupProfile is not null)
            startupProfile.IsEnabled = !busy;
        if (graphics is not null)
            graphics.IsEnabled = !busy;
        UpdateShaders();
        opacity.IsEnabled = !busy && draft.Material != Array.IndexOf(MaterialKeys, "solid");
        status.Text = busy ? UiText.Get("Waiting") : writable ? "" : UiText.Get("SavingDisabled");
        Palette(draft.Theme switch
        {
            0 => terminalColors is { } colors && SettingsPalette.IsLight(colors),
            1 => Application.Current.RequestedTheme == ApplicationTheme.Light,
            2 => true,
            _ => false
        });
    }

    private void Palette(bool light)
    {
        if (lightPalette == light)
            return;
        lightPalette = light;
        var palette = SettingsPalette.Create(light, terminalColors);
        root.RequestedTheme = light ? ElementTheme.Light : ElementTheme.Dark;
        canvas.Color = palette.Canvas;
        panel.Color = palette.Panel;
        edge.Color = palette.Edge;
        ink.Color = palette.Text;
        muted.Color = palette.Muted;
        accent.Color = palette.Accent;
        onAccent.Color = palette.OnAccent;
        selection.Color = palette.Accent;

        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            var titleBar = AppWindow.TitleBar;
            titleBar.BackgroundColor = titleBar.InactiveBackgroundColor = palette.Canvas;
            titleBar.ButtonBackgroundColor = titleBar.ButtonInactiveBackgroundColor = palette.Canvas;
            titleBar.ForegroundColor = titleBar.ButtonForegroundColor = palette.Text;
            titleBar.InactiveForegroundColor = titleBar.ButtonInactiveForegroundColor = palette.Muted;
            titleBar.ButtonHoverBackgroundColor = palette.Panel;
            titleBar.ButtonHoverForegroundColor = palette.Text;
            titleBar.ButtonPressedBackgroundColor = palette.Edge;
            titleBar.ButtonPressedForegroundColor = palette.Text;
        }
    }

    internal static int Smoke()
    {
        var original = new Draft(13, 0, 92.37, 0, 0);
        var acrylic = original with { Material = 3 };
        var changeMaterial = Edits(original, acrylic);
        var restoreDefault = Edits(acrylic, original);
        var all = Edits(original, new Draft(17, 2, 72, 2, 2));
        var opengl = original with { Graphics = "opengl" };
        var directx = original with { Graphics = "d3d12" };
        var vulkan = original with { Graphics = "vulkan" };
        var changeGraphics = Edits(opengl, directx);
        var changeToVulkan = Edits(opengl, vulkan);
        var tabEdits = Edits(original, original with { NewTabPosition = 1, InheritDirectory = false });
        var profileEdits = Edits(original, original with { StartupProfile = "builtin:powershell" });
        var separateTheme = new ThemeDraft(true, "Light Sample", @"C:\themes\dark,variant");
        var themeEdits = Edits(original with { TerminalTheme = new ThemeDraft("Old", "Old") },
            original with { TerminalTheme = separateTheme });
        var terminalEdits = Edits(original, original with { CursorStyle = 3, CopyOnSelect = true, RightClickAction = 2 });
        var restoreAutomatic = Edits(vulkan, original with { Graphics = "auto" });
        var vulkanAvailable = new RendererSnapshot("auto", "vulkan", false, true, null);
        var vulkanMissing = new RendererSnapshot("vulkan", "opengl", true, false, "missing");
        return Edits(original, original).Count == 0 &&
               changeMaterial.Count == 1 && Equals(changeMaterial["windows-background-material"], "acrylic") &&
               restoreDefault.Count == 1 && Equals(restoreDefault["windows-background-material"], "auto") &&
               all.Count == 5 &&
               Equals(all["font-size"], 17.0) &&
               Equals(all["window-theme"], "light") &&
               Equals(all["window-show-tab-bar"], "never") &&
               Equals(all["background-opacity"], 0.72) &&
               Equals(all["windows-background-material"], "mica") &&
               Edits(directx, directx).Count == 0 &&
               changeGraphics.Count == 1 && Equals(changeGraphics["windows-renderer"], "d3d12") &&
               changeToVulkan.Count == 1 && Equals(changeToVulkan["windows-renderer"], "vulkan") &&
               tabEdits.Count == 2 && Equals(tabEdits["window-new-tab-position"], "end") &&
               Equals(tabEdits["tab-inherit-working-directory"], false) &&
               profileEdits.Count == 1 && Equals(profileEdits["windows-default-profile"], "builtin:powershell") &&
               separateTheme.IsValid && !new ThemeDraft(true, "Light Sample", "").IsValid &&
               themeEdits.Count == 1 && Equals(themeEdits["theme"], "light:\"Light Sample\",dark:\"C:\\\\themes\\\\dark,variant\"") &&
               terminalEdits.Count == 3 && Equals(terminalEdits["cursor-style"], "block_hollow") &&
               Equals(terminalEdits["copy-on-select"], "clipboard") && Equals(terminalEdits["right-click-action"], "copy") &&
               restoreAutomatic.Count == 1 && Equals(restoreAutomatic["windows-renderer"], "auto") &&
               GraphicsChoices(vulkanAvailable).SequenceEqual(new[] { ("auto", true), ("opengl", true), ("vulkan", true) }) &&
               GraphicsChoices(vulkanMissing).Last() == ("vulkan", false) &&
               GraphicsHint(vulkanAvailable).StartsWith(UiText.Format("CurrentRenderer", "Vulkan"), StringComparison.Ordinal) &&
               GraphicsHint(vulkanMissing).Contains(UiText.Format("RendererUnavailable", "Vulkan"), StringComparison.Ordinal) &&
               HostConnection.Smoke() && ShaderDraft.Smoke() && SettingsPalette.Smoke() && KeybindingDisplay.LocalizationSmoke() ? 0 : 2;
    }
}
