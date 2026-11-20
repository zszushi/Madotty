using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace Madotty.Settings;

internal sealed partial class AppearanceWindow
{
    private static readonly string[] ShaderAnimationKeys = ["false", "true", "always"];

    private ShaderDraft? shaderDraft;
    private readonly ListBox shaderList = new() { MaxHeight = 168 };
    private readonly TextBlock shaderEmpty = new();
    private readonly Button shaderAdd = ShaderButton(UiText.Get("AddGlsl"), "shader-add");
    private readonly Button shaderRemove = ShaderButton(UiText.Get("Remove"), "shader-remove");
    private readonly Button shaderMoveUp = ShaderButton(UiText.Get("MoveUp"), "shader-move-up");
    private readonly Button shaderMoveDown = ShaderButton(UiText.Get("MoveDown"), "shader-move-down");
    private readonly CheckBox shaderOptional = new() { Content = UiText.Get("OptionalFile") };
    private readonly ComboBox shaderAnimation = new();
    private readonly StackPanel shaderParameters = new() { Spacing = 6 };
    private readonly List<NumberBox> shaderEditors = [];

    private StackPanel BuildShaders(ShaderSnapshot snapshot)
    {
        shaderDraft = new ShaderDraft(snapshot);
        BindInterfaceFont(shaderList);
        BindInterfaceFont(shaderOptional);
        shaderEmpty.Text = UiText.Get("NoShaders");
        shaderEmpty.Foreground = muted;
        shaderAnimation.ItemsSource = new[] { UiText.Get("WhenContentChanges"), UiText.Get("WhenFocused"), UiText.Get("AlwaysAnimate") };
        shaderAnimation.SelectedIndex = Array.IndexOf(ShaderAnimationKeys, snapshot.Animation);
        AutomationProperties.SetName(shaderList, UiText.Get("ShaderOrder"));
        AutomationProperties.SetAutomationId(shaderList, "shader-list");
        AutomationProperties.SetAutomationId(shaderOptional, "shader-optional");

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var button in new[] { shaderAdd, shaderRemove, shaderMoveUp, shaderMoveDown })
        {
            BindInterfaceFont(button);
            button.Background = panel;
            button.BorderBrush = edge;
            button.Foreground = ink;
            actions.Children.Add(button);
        }

        shaderList.SelectionChanged += (_, _) => ShowSelectedShader();
        FillShaderList(0);
        shaderAdd.Click += (_, _) => AddShader();
        shaderRemove.Click += (_, _) => RemoveShader();
        shaderMoveUp.Click += (_, _) => MoveShader(-1);
        shaderMoveDown.Click += (_, _) => MoveShader(1);
        shaderOptional.Click += (_, _) =>
        {
            var index = shaderList.SelectedIndex;
            if (index >= 0)
            {
                var selected = shaderDraft.Passes[index];
                selected.File = selected.File with { Optional = shaderOptional.IsChecked == true };
            }
        };

        var sections = new StackPanel { Spacing = 20 };
        sections.Children.Add(Section(UiText.Get("ShaderPasses"), shaderList, shaderEmpty, actions, shaderOptional, shaderParameters));
        sections.Children.Add(Section(UiText.Get("Playback"), Row(UiText.Get("Animation"), shaderAnimation, shaderAnimation, "shader-animation")));
        return sections;
    }

    private static Button ShaderButton(string label, string id)
    {
        var button = new Button { Content = label };
        AutomationProperties.SetAutomationId(button, id);
        return button;
    }

    private void FillShaderList(int selected)
    {
        shaderList.Items.Clear();
        var passes = shaderDraft!.Passes;
        for (var index = 0; index < passes.Count; index++)
        {
            var entry = passes[index];
            var label = Text($"{index + 1}. {entry.File.Path}", 14, ink, false);
            label.TextTrimming = TextTrimming.CharacterEllipsis;
            ToolTipService.SetToolTip(label, entry.File.Path);
            var item = new ListBoxItem { Content = label };
            BindInterfaceFont(item);
            AutomationProperties.SetName(item, label.Text);
            shaderList.Items.Add(item);
        }
        shaderList.SelectedIndex = Math.Min(selected, shaderList.Items.Count - 1);
        UpdateShaders();
    }

    private void ShowSelectedShader()
    {
        shaderEditors.Clear();
        shaderParameters.Children.Clear();
        var selected = shaderList.SelectedIndex;
        if (selected >= 0)
        {
            var pass = shaderDraft!.Passes[selected];
            shaderOptional.IsChecked = pass.File.Optional;
            if (pass.Parameters.Length != 0)
                shaderParameters.Children.Add(Text(UiText.Get("Parameters"), 13, muted, true));
            foreach (var parameter in pass.Parameters)
                AddShaderEditor(pass, parameter);
        }
        UpdateShaders();
    }

    private void AddShaderEditor(ShaderDraft.Pass pass, ConfiguredShaderParameter parameter)
    {
        var declaration = parameter.Declaration;
        var step = declaration.Integer ? Math.Max(1, Math.Round(declaration.Step)) : declaration.Step;
        if (step <= 0)
            step = 0.01;
        var editor = new NumberBox
        {
            Minimum = declaration.Minimum,
            Maximum = declaration.Maximum,
            SmallChange = step,
            LargeChange = step,
            Value = declaration.Normalize(pass.Value(parameter)),
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact
        };
        ToolTipService.SetToolTip(editor, UiText.Format("DefaultValue", declaration.Default));
        editor.ValueChanged += (_, args) =>
        {
            var value = declaration.Normalize(args.NewValue);
            if (args.NewValue != value)
                editor.Value = value;
            pass.SetValue(parameter, value);
        };
        var label = string.IsNullOrEmpty(declaration.Label) ? declaration.Name : declaration.Label;
        shaderParameters.Children.Add(Row(label, editor, editor, $"shader-parameter-{declaration.Name}"));
        shaderEditors.Add(editor);
    }

    private void UpdateShaders()
    {
        if (shaderDraft is null)
            return;

        var count = shaderDraft.Passes.Count;
        var selected = shaderList.SelectedIndex;
        shaderList.Visibility = count == 0 ? Visibility.Collapsed : Visibility.Visible;
        shaderEmpty.Visibility = count == 0 ? Visibility.Visible : Visibility.Collapsed;
        shaderOptional.Visibility = selected < 0 ? Visibility.Collapsed : Visibility.Visible;
        shaderParameters.Visibility = shaderEditors.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        shaderAdd.IsEnabled = !busy;
        shaderList.IsEnabled = !busy;
        shaderRemove.IsEnabled = !busy && selected >= 0;
        shaderMoveUp.IsEnabled = !busy && selected > 0;
        shaderMoveDown.IsEnabled = !busy && selected >= 0 && selected + 1 < count;
        shaderOptional.IsEnabled = !busy;
        shaderAnimation.IsEnabled = !busy;
        foreach (var editor in shaderEditors)
            editor.IsEnabled = !busy;
    }

    private async void AddShader()
    {
        if (busy || shaderDraft is null)
            return;

        busy = true;
        Update();
        string? error = null;
        try
        {
            var picker = new FileOpenPicker(AppWindow.Id) { Title = UiText.Get("AddShader") };
            picker.FileTypeFilter.Add(".glsl");
            var file = await picker.PickSingleFileAsync();
            if (file is null || closed)
                return;

            ShaderDeclaration[] parameters = [];
            if (host is not null)
            {
                var reply = await host.SendAsync("shader_parameters", path: file.Path);
                if (!reply.Ok)
                {
                    error = reply.Message ?? UiText.Get("LoadShaderFailed");
                    return;
                }
                parameters = reply.Parameters ?? [];
            }

            if (!closed)
            {
                shaderDraft.Add(file.Path, parameters);
                FillShaderList(shaderDraft.Passes.Count - 1);
            }
        }
        catch (Exception exception) when (exception is IOException or COMException)
        {
            error = exception.Message;
        }
        finally
        {
            busy = false;
            if (!closed)
            {
                Update();
                if (error is not null)
                    status.Text = error;
            }
        }
    }

    private void RemoveShader()
    {
        var selected = shaderList.SelectedIndex;
        if (busy || selected < 0 || shaderDraft is null)
            return;

        shaderDraft.Passes.RemoveAt(selected);
        FillShaderList(selected);
    }

    private void MoveShader(int direction)
    {
        var selected = shaderList.SelectedIndex;
        var destination = selected + direction;
        if (busy || selected < 0 || shaderDraft is null || destination < 0 || destination >= shaderDraft.Passes.Count)
            return;

        var passes = shaderDraft.Passes;
        (passes[selected], passes[destination]) = (passes[destination], passes[selected]);
        FillShaderList(destination);
    }
}
