using System.Text.Json.Serialization;

namespace Madotty.Settings;

internal sealed record ShaderFile(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("optional")] bool Optional);

internal sealed record ShaderOverride(
    [property: JsonPropertyName("pass")] ulong Pass,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("value")] double Value);

internal sealed record ShaderDeclaration(
    string Name, string Label, double Default, double Minimum, double Maximum, double Step, bool Integer)
{
    internal double Normalize(double value)
    {
        if (!double.IsFinite(value))
            value = Default;
        if (Integer)
            value = Math.Round(value, MidpointRounding.AwayFromZero);
        return Math.Clamp(value, Minimum, Maximum);
    }
}

internal sealed record ConfiguredShaderParameter(int Pass, ShaderDeclaration Declaration, double Value);

internal sealed record ShaderSnapshot(
    ShaderFile[] Items, string Animation, ConfiguredShaderParameter[] Parameters, ShaderOverride[] Overrides);

internal sealed class ShaderDraft
{
    internal sealed class Pass(ShaderFile file, ConfiguredShaderParameter[] parameters, ShaderOverride[] overrides)
    {
        private readonly Dictionary<string, double?> changes = new(StringComparer.Ordinal);
        internal ShaderFile File { get; set; } = file;
        internal ConfiguredShaderParameter[] Parameters { get; } = parameters;

        internal double Value(ConfiguredShaderParameter parameter) => changes.TryGetValue(parameter.Declaration.Name, out var value)
            ? value ?? parameter.Declaration.Default : parameter.Value;

        internal void SetValue(ConfiguredShaderParameter parameter, double value)
        {
            var declaration = parameter.Declaration;
            var name = declaration.Name;
            if (value == declaration.Normalize(parameter.Value))
                changes.Remove(name);
            else
                changes[name] = value == declaration.Normalize(declaration.Default) ? null : value;
        }

        internal IEnumerable<ShaderOverride> Overrides(ulong pass)
        {
            // Duplicate entries from the config remain ordered until the user edits that parameter.
            foreach (var entry in overrides)
                if (!changes.ContainsKey(entry.Name))
                    yield return entry with { Pass = pass };
            foreach (var (name, value) in changes)
                if (value is { } number)
                    yield return new ShaderOverride(pass, name, number);
        }
    }

    private ShaderFile[] savedFiles;
    private ShaderOverride[] savedOverrides;
    private string savedAnimation;
    private readonly ShaderOverride[] detachedOverrides;
    internal List<Pass> Passes { get; }

    internal ShaderDraft(ShaderSnapshot snapshot)
    {
        var parameters = snapshot.Parameters.ToLookup(parameter => parameter.Pass);
        var overrides = snapshot.Overrides.ToLookup(parameter => parameter.Pass);
        Passes = snapshot.Items.Select((file, index) =>
            new Pass(file, parameters[index + 1].ToArray(), overrides[(ulong)index + 1].ToArray())).ToList();
        detachedOverrides = snapshot.Overrides.Where(value => value.Pass > (ulong)Passes.Count).ToArray();
        savedFiles = snapshot.Items;
        savedOverrides = CurrentOverrides();
        savedAnimation = snapshot.Animation;
    }

    internal void Add(string path, ShaderDeclaration[] parameters)
    {
        var pass = Passes.Count + 1;
        Passes.Add(new Pass(new ShaderFile(path, false),
            parameters.Select(parameter => new ConfiguredShaderParameter(pass, parameter, parameter.Default)).ToArray(), []));
    }

    internal void AddEdits(Dictionary<string, object> edits, string animation)
    {
        var files = Passes.Select(pass => pass.File).ToArray();
        var overrides = CurrentOverrides();
        if (!files.SequenceEqual(savedFiles))
            edits.Add("custom-shader", files);
        if (animation != savedAnimation)
            edits.Add("custom-shader-animation", animation);
        if (!overrides.SequenceEqual(savedOverrides))
            edits.Add("custom-shader-parameter", overrides);
    }

    internal void SavePreview(string animation)
    {
        savedFiles = Passes.Select(pass => pass.File).ToArray();
        savedOverrides = CurrentOverrides();
        savedAnimation = animation;
    }

    private ShaderOverride[] CurrentOverrides() => Passes.SelectMany((pass, index) => pass.Overrides((ulong)index + 1))
        .Concat(detachedOverrides.Where(entry => entry.Pass > (ulong)Passes.Count))
        .OrderBy(entry => entry.Pass).ThenBy(entry => entry.Name, StringComparer.Ordinal).ToArray();

    internal static bool Smoke()
    {
        var declaration = new ShaderDeclaration("strength", "Strength", 0.25, 0, 1, 0.05, false);
        var draft = new ShaderDraft(new ShaderSnapshot(
            [new ShaderFile("first.glsl", false), new ShaderFile("second.glsl", true)], "true",
            [new ConfiguredShaderParameter(1, declaration, 0.75)], [new ShaderOverride(1, declaration.Name, 0.75)]));
        var edits = new Dictionary<string, object>();
        draft.AddEdits(edits, "true");
        if (edits.Count != 0)
            return false;

        (draft.Passes[0], draft.Passes[1]) = (draft.Passes[1], draft.Passes[0]);
        draft.AddEdits(edits, "always");
        if (edits.Count != 3 || edits["custom-shader"] is not ShaderFile[] files ||
            !files.SequenceEqual(new[] { new ShaderFile("second.glsl", true), new ShaderFile("first.glsl", false) }) ||
            !Equals(edits["custom-shader-animation"], "always") ||
            edits["custom-shader-parameter"] is not ShaderOverride[] overrides ||
            !overrides.SequenceEqual(new[] { new ShaderOverride(2, declaration.Name, 0.75) }))
            return false;

        edits.Clear();
        var moved = draft.Passes[1];
        moved.SetValue(moved.Parameters[0], declaration.Default);
        draft.AddEdits(edits, "true");
        if (edits.Count != 2 || edits["custom-shader-parameter"] is not ShaderOverride[] { Length: 0 })
            return false;

        edits.Clear();
        draft.Passes.Clear();
        draft.AddEdits(edits, "true");
        return edits.Count == 2 && edits["custom-shader"] is ShaderFile[] { Length: 0 } &&
            edits["custom-shader-parameter"] is ShaderOverride[] { Length: 0 };
    }
}
