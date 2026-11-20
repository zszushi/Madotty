using Microsoft.UI.Dispatching;
using System.Text;
using System.Text.Json;

namespace Madotty.Settings;

internal sealed record RendererSnapshot(string Preference, string Active, bool D3D12Available, bool VulkanAvailable, string? Problem);
internal sealed record ProfileSnapshot(string Id, string Name, string? Icon, string? Executable, string? Alias);
internal sealed record KeybindingSnapshot(string Trigger, string? Table, string[] Actions, string[] Titles,
    bool Global, bool All, bool Consumed, bool Performable, bool[]? BuiltinTitles = null);
internal sealed record KeybindingPage(KeybindingSnapshot[] Rows, uint? NextOffset);
internal sealed record ThemeCatalogPage(string[] Names, uint? NextOffset);
internal sealed record PrivacySnapshot(string ClipboardRead, string ClipboardWrite, bool PasteProtection,
    bool DetectLinks, bool Notifications);

internal sealed record HostSnapshot(
    double FontSize, string Theme, double OpacityPercent, string Backdrop, string TabBar, bool Writable,
    RendererSnapshot? Renderer = null, ShaderSnapshot? Shaders = null)
{
    internal TerminalColors? Colors { get; init; }
    internal string[] TerminalFonts { get; init; } = [];
    internal string UiFontFamily { get; init; } = "";
    internal string? ActiveRenderer { get; init; }
    internal string? UiLanguage { get; init; }
    internal string CursorStyle { get; init; } = "block";
    internal bool CopyOnSelect { get; init; }
    internal string RightClickAction { get; init; } = "context-menu";
    internal string NewTabPosition { get; init; } = "current";
    internal bool TabInheritWorkingDirectory { get; init; } = true;
    internal bool ProgressStyle { get; init; } = true;
    internal string? StartupProfile { get; init; }
    internal ProfileSnapshot[]? Profiles { get; init; }
    internal bool KeybindingsAvailable { get; init; }
    internal PrivacySnapshot? Privacy { get; init; }
    internal bool ThemesAvailable { get; init; }
    internal string? LightTerminalTheme { get; init; }
    internal string? DarkTerminalTheme { get; init; }

    internal static HostSnapshot Preview { get; } = new(13, "auto", 92, "auto", "always", true,
        Shaders: new([], "true", [], []));
}

/// <summary>A single settings session over the host's inherited pipes.</summary>
internal sealed class HostConnection : IDisposable
{
    internal sealed record Reply(bool Ok, string? Message, ShaderDeclaration[]? Parameters, KeybindingPage? Keybindings,
        ThemeCatalogPage? Themes);

    private const int MaxMessageBytes = 65536;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private readonly StreamReader input = new(Console.OpenStandardInput(), Utf8, false);
    private readonly StreamWriter output = new(Console.OpenStandardOutput(), Utf8)
    {
        AutoFlush = true,
        NewLine = "\n"
    };

    // Slots and connection state are owned by the WinUI dispatcher.
    private readonly SemaphoreSlim requestSlot = new(1, 1);
    private TaskCompletionSource<Reply>? pending;
    private bool disconnected;

    internal HostSnapshot ReadSnapshot()
    {
        using var json = ReadLine() ?? throw new EndOfStreamException(UiText.Get("SettingsDataMissing"));
        var root = json.RootElement;
        var fontSize = root.GetProperty("font_size").GetDouble();
        var theme = root.GetProperty("theme").GetString();
        var opacity = root.GetProperty("opacity_percent").GetDouble();
        var backdrop = root.TryGetProperty("backdrop", out var material) ? material.GetString() ?? "auto" : "auto";
        var tabBar = root.GetProperty("tab_bar").GetString();
        var newTab = root.TryGetProperty("new_tab_position", out var position) ? position.GetString() : "current";
        var cursor = root.TryGetProperty("cursor_style", out var shape) ? shape.GetString() : "block";
        var rightClick = root.TryGetProperty("right_click_action", out var click) ? click.GetString() : "context-menu";
        if (!double.IsFinite(fontSize) || !double.IsFinite(opacity) ||
            theme is not ("auto" or "system" or "light" or "dark") ||
            backdrop is not ("auto" or "solid" or "mica" or "acrylic") ||
            tabBar is not ("always" or "auto" or "never") || newTab is not ("current" or "end") ||
            cursor is not ("block" or "bar" or "underline" or "block_hollow") ||
            rightClick is not ("context-menu" or "paste" or "copy" or "copy-or-paste" or "ignore"))
        {
            throw new InvalidDataException(UiText.Get("SettingsDataInvalid"));
        }

        return new HostSnapshot(
            Math.Clamp(fontSize, 1, 255), theme, Math.Clamp(opacity, 0, 100),
            backdrop, tabBar, root.GetProperty("writable").GetBoolean(), ReadRenderer(root), ReadShaders(root))
        {
            Colors = ReadColors(root),
            TerminalFonts = root.TryGetProperty("terminal_fonts", out var fonts) ? fonts.EnumerateArray().Select(f => f.GetString()!).ToArray() : [],
            UiFontFamily = root.TryGetProperty("ui_font_family", out var uiFont) ? uiFont.GetString() ?? "" : "",
            ActiveRenderer = root.TryGetProperty("active_renderer", out var activeRenderer) ? activeRenderer.GetString() : null,
            UiLanguage = root.TryGetProperty("ui_language", out var uiLanguage) ? uiLanguage.GetString() : null,
            CursorStyle = cursor,
            CopyOnSelect = root.TryGetProperty("copy_on_select", out var copy) && copy.GetBoolean(),
            RightClickAction = rightClick,
            NewTabPosition = newTab,
            ProgressStyle = !root.TryGetProperty("progress_style", out var progress) || progress.GetBoolean(),
            TabInheritWorkingDirectory = !root.TryGetProperty("tab_inherit_working_directory", out var inherit) || inherit.GetBoolean(),
            StartupProfile = root.TryGetProperty("startup_profile", out var startup) ? startup.GetString() : null,
            Profiles = ReadProfiles(root),
            KeybindingsAvailable = root.TryGetProperty("keybindings_available", out var keybindings) && keybindings.GetBoolean(),
            Privacy = ReadPrivacy(root),
            ThemesAvailable = root.TryGetProperty("themes_available", out var themes) && themes.GetBoolean(),
            LightTerminalTheme = root.TryGetProperty("terminal_theme_light", out var light) ? light.GetString() : null,
            DarkTerminalTheme = root.TryGetProperty("terminal_theme_dark", out var dark) ? dark.GetString() : null
        };
    }

    private static PrivacySnapshot? ReadPrivacy(JsonElement root)
    {
        if (!root.TryGetProperty("privacy", out var privacy))
            return null;

        var read = RequiredString(privacy, "clipboard_read");
        var write = RequiredString(privacy, "clipboard_write");
        if (read is not ("ask" or "allow" or "deny") || write is not ("ask" or "allow" or "deny"))
            throw new InvalidDataException(UiText.Get("ClipboardPolicyUnknown"));
        return new(read, write, privacy.GetProperty("paste_protection").GetBoolean(),
            privacy.GetProperty("detect_links").GetBoolean(), privacy.GetProperty("notifications").GetBoolean());
    }

    private static TerminalColors? ReadColors(JsonElement root)
    {
        if (!root.TryGetProperty("colors", out var colors))
            return null;

        static int ReadRgb(JsonElement colors, string name)
        {
            var color = colors.GetProperty(name).GetInt32();
            return color is >= 0 and <= 0xFFFFFF ? color : throw new InvalidDataException(UiText.Get("TerminalColorInvalid"));
        }

        return new TerminalColors(ReadRgb(colors, "background"), ReadRgb(colors, "foreground"), ReadRgb(colors, "accent"));
    }

    private static ProfileSnapshot[]? ReadProfiles(JsonElement root)
    {
        if (!root.TryGetProperty("profiles", out var profiles) || profiles.ValueKind == JsonValueKind.Null)
            return null;

        return profiles.EnumerateArray().Select(profile => new ProfileSnapshot(
            profile.GetProperty("id").GetString() ?? throw new InvalidDataException(UiText.Get("ProfileIdMissing")),
            profile.GetProperty("name").GetString() ?? throw new InvalidDataException(UiText.Get("ProfileNameMissing")),
            profile.TryGetProperty("icon", out var icon) ? icon.GetString() : null,
            profile.TryGetProperty("executable", out var exe) ? exe.GetString() : null,
            profile.TryGetProperty("alias", out var alias) ? alias.GetString() : null)).ToArray();
    }

    private static RendererSnapshot? ReadRenderer(JsonElement root)
    {
        if (!root.TryGetProperty("renderer", out var renderer) || renderer.ValueKind == JsonValueKind.Null)
            return null;

        var preference = renderer.GetProperty("preference").GetString();
        var active = renderer.GetProperty("active").GetString();
        var problem = renderer.TryGetProperty("problem", out var reason) ? reason.GetString() : null;
        if (preference is not ("auto" or "opengl" or "d3d12" or "vulkan") ||
            active is not ("opengl" or "d3d12" or "vulkan") ||
            problem is not (null or "missing" or "startup_failed"))
        {
            throw new InvalidDataException(UiText.Get("GraphicsApiInvalid"));
        }

        return new RendererSnapshot(preference, active, renderer.GetProperty("d3d12_available").GetBoolean(),
            renderer.TryGetProperty("vulkan_available", out var vulkan) && vulkan.GetBoolean(), problem);
    }

    internal static bool Smoke()
    {
        using var older = JsonDocument.Parse("""
            {"renderer":{"preference":"d3d12","active":"d3d12","d3d12_available":true}}
            """);
        using var current = JsonDocument.Parse("""
            {"renderer":{"preference":"vulkan","active":"vulkan","d3d12_available":false,"vulkan_available":true,"problem":null}}
            """);
        return ReadRenderer(older.RootElement) == new RendererSnapshot("d3d12", "d3d12", true, false, null) &&
            ReadRenderer(current.RootElement) == new RendererSnapshot("vulkan", "vulkan", false, true, null);
    }

    private static ShaderSnapshot? ReadShaders(JsonElement root)
    {
        if (!root.TryGetProperty("shaders", out var shaders) || shaders.ValueKind == JsonValueKind.Null)
            return null;

        var animation = shaders.GetProperty("animation").GetString();
        if (animation is not ("true" or "false" or "always"))
            throw new InvalidDataException(UiText.Get("ShaderAnimationInvalid"));

        return new ShaderSnapshot(
            shaders.GetProperty("items").EnumerateArray().Select(item => new ShaderFile(
                RequiredString(item, "path"), item.GetProperty("optional").GetBoolean())).ToArray(), animation,
            shaders.GetProperty("parameters").EnumerateArray().Select(parameter => new ConfiguredShaderParameter(
                checked((int)PassNumber(parameter)), ReadDeclaration(parameter), FiniteNumber(parameter, "value"))).ToArray(),
            shaders.GetProperty("overrides").EnumerateArray().Select(parameter => new ShaderOverride(
                PassNumber(parameter), RequiredString(parameter, "name"), FiniteNumber(parameter, "value"))).ToArray());
    }

    private static KeybindingPage? ReadKeybindings(JsonElement root)
    {
        if (!root.TryGetProperty("keybindings", out var page) || page.ValueKind == JsonValueKind.Null)
            return null;

        var rows = page.GetProperty("rows").EnumerateArray().Select(row => new KeybindingSnapshot(
            RequiredString(row, "trigger"), row.GetProperty("table").GetString(),
            ReadStrings(row.GetProperty("actions")), ReadStrings(row.GetProperty("titles")),
            row.GetProperty("global").GetBoolean(), row.GetProperty("all").GetBoolean(),
            row.GetProperty("consumed").GetBoolean(), row.GetProperty("performable").GetBoolean(),
            row.TryGetProperty("builtin_titles", out var titles) && titles.ValueKind == JsonValueKind.Array
                ? titles.EnumerateArray().Select(value => value.GetBoolean()).ToArray() : null)).ToArray();
        var next = page.GetProperty("next_offset");
        return new(rows, next.ValueKind == JsonValueKind.Null ? null : next.GetUInt32());
    }

    private static string[] ReadStrings(JsonElement value) => value.EnumerateArray()
        .Select(item => item.GetString() ?? throw new InvalidDataException(UiText.Get("InvalidKeybinding"))).ToArray();

    private static ThemeCatalogPage? ReadThemeCatalog(JsonElement root)
    {
        if (!root.TryGetProperty("themes", out var page) || page.ValueKind == JsonValueKind.Null)
            return null;

        var items = page.GetProperty("items").EnumerateArray().Select(item =>
            RequiredString(item, "name")).ToArray();
        var next = page.GetProperty("next_offset");
        return new(items, next.ValueKind == JsonValueKind.Null ? null : next.GetUInt32());
    }

    private static ShaderDeclaration ReadDeclaration(JsonElement parameter)
    {
        var minimum = FiniteNumber(parameter, "min");
        var maximum = FiniteNumber(parameter, "max");
        if (minimum > maximum)
            throw new InvalidDataException(UiText.Get("ShaderRangeInvalid"));

        return new ShaderDeclaration(
            RequiredString(parameter, "name"), RequiredString(parameter, "label"),
            FiniteNumber(parameter, "default"), minimum, maximum,
            FiniteNumber(parameter, "step"), parameter.GetProperty("integer").GetBoolean());
    }

    private static string RequiredString(JsonElement item, string key) =>
        item.GetProperty(key).GetString() ?? throw new InvalidDataException(UiText.Format("ShaderFieldString", key));

    private static double FiniteNumber(JsonElement item, string key)
    {
        var number = item.GetProperty(key).GetDouble();
        if (!double.IsFinite(number))
            throw new InvalidDataException(UiText.Format("ShaderFieldFinite", key));
        return number;
    }

    private static ulong PassNumber(JsonElement parameter)
    {
        var pass = parameter.GetProperty("pass").GetUInt64();
        if (pass == 0)
            throw new InvalidDataException(UiText.Get("ShaderPassInvalid"));
        return pass;
    }

    internal async Task<Reply> SendAsync(string action, Dictionary<string, object>? edits = null, string? path = null,
        uint? offset = null)
    {
        // Replies have no request ID. A foreground edit and a background
        // catalog read can overlap, but only one request can be on the wire.
        await requestSlot.WaitAsync();
        try
        {
            if (disconnected)
                throw new IOException(UiText.Get("ConnectionUnavailable"));
            pending = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var line = path is not null ? JsonSerializer.Serialize(new { action, path }) :
                edits is not null ? JsonSerializer.Serialize(new { action, edits }) :
                offset is not null ? JsonSerializer.Serialize(new { action, offset }) :
                JsonSerializer.Serialize(new { action });
            if (Utf8.GetByteCount(line) >= MaxMessageBytes)
                throw new IOException(UiText.Get("SettingsMessageTooLarge"));
            await output.WriteLineAsync(line);
            return await pending.Task;
        }
        finally
        {
            pending = null;
            requestSlot.Release();
        }
    }

    internal void Listen(DispatcherQueue dispatcher, Action onClosed)
    {
        // A redirected Win32 standard stream can use synchronous I/O. Read it
        // on a worker so an idle host cannot block the dispatcher.
        _ = Task.Run(() =>
        {
            try
            {
                while (ReadLine() is { } json)
                {
                    using (json)
                    {
                        var root = json.RootElement;
                        var reply = new Reply(
                            root.GetProperty("ok").GetBoolean(),
                            root.TryGetProperty("message", out var message) ? message.GetString() : null,
                            root.TryGetProperty("parameters", out var parameters) && parameters.ValueKind != JsonValueKind.Null
                                ? parameters.EnumerateArray().Select(ReadDeclaration).ToArray() : null,
                            ReadKeybindings(root), ReadThemeCatalog(root));
                        if (!dispatcher.TryEnqueue(() => pending?.TrySetResult(reply)))
                            break;
                    }
                }
            }
            catch (Exception exception) when (exception is IOException or JsonException or
                DecoderFallbackException or ObjectDisposedException or InvalidOperationException or KeyNotFoundException or
                InvalidDataException or FormatException)
            {
                // Malformed data and a broken pipe both end the session.
            }
            finally
            {
                _ = dispatcher.TryEnqueue(() =>
                {
                    disconnected = true;
                    pending?.TrySetException(new IOException(UiText.Get("ConnectionClosed")));
                    onClosed();
                });
            }
        });
    }

    private JsonDocument? ReadLine()
    {
        var line = input.ReadLine();
        if (line is null)
            return null;
        if (Utf8.GetByteCount(line) >= MaxMessageBytes)
            throw new InvalidDataException(UiText.Get("SettingsMessageTooLarge"));
        return JsonDocument.Parse(line);
    }

    public void Dispose()
    {
        input.Dispose();
        output.Dispose();
    }
}
