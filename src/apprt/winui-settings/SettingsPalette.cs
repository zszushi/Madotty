using Windows.UI;

namespace Madotty.Settings;

internal readonly record struct TerminalColors(int Background, int Foreground, int Accent);

internal readonly record struct SettingsPalette(
    Color Canvas, Color Panel, Color Edge, Color Text, Color Muted, Color Accent, Color OnAccent)
{
    private static readonly Color Black = Paint(0);
    private static readonly Color White = Paint(0xFFFFFF);

    internal static bool IsLight(TerminalColors colors) => BestText(Paint(colors.Background)) == Black;

    internal static SettingsPalette Create(bool light, TerminalColors? terminal)
    {
        var neutral = Paint(light ? 0xF5F5F6 : 0x191A1E);
        var background = terminal is { } colors ? Paint(colors.Background) : neutral;
        var canvas = terminal is { } current && IsLight(current) != light
            ? Blend(neutral, background, 0.10) : background;
        var panel = Blend(canvas, White, light ? 0.55 : 0.055);
        var fallback = BestText(canvas);
        if (Contrast(fallback, panel) < 4.5)
            panel = Blend(canvas, Black, 0.055);

        var text = terminal is { } supplied ? Paint(supplied.Foreground) : fallback;
        if (!ReadsOn(text, canvas, panel, 4.5))
            text = fallback;
        var muted = Blend(text, panel, 0.28);
        if (!ReadsOn(muted, canvas, panel, 4.5))
            muted = text;

        var accent = terminal is { } theme ? Paint(theme.Accent) : Paint(light ? 0x3455AA : 0xAFC1FF);
        if (!ReadsOn(accent, canvas, panel, 3))
            accent = text;
        return new(canvas, panel, Blend(panel, text, 0.17), text, muted, accent, BestText(accent));
    }

    private static bool ReadsOn(Color color, Color canvas, Color panel, double ratio) =>
        Contrast(color, canvas) >= ratio && Contrast(color, panel) >= ratio;

    private static Color BestText(Color background) => Contrast(Black, background) >= Contrast(White, background) ? Black : White;

    private static double Contrast(Color first, Color second)
    {
        var a = Luminance(first);
        var b = Luminance(second);
        return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
    }

    private static double Luminance(Color color)
    {
        static double Linear(byte channel)
        {
            var srgb = channel / 255.0;
            return srgb <= 0.04045 ? srgb / 12.92 : Math.Pow((srgb + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Linear(color.R) + 0.7152 * Linear(color.G) + 0.0722 * Linear(color.B);
    }

    private static Color Blend(Color first, Color second, double amount)
    {
        byte Channel(byte a, byte b) => (byte)Math.Round(a + (b - a) * amount);
        return Color.FromArgb(255, Channel(first.R, second.R), Channel(first.G, second.G), Channel(first.B, second.B));
    }

    private static Color Paint(int rgb) => Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    internal static bool Smoke()
    {
        var dark = new TerminalColors(0x1E2430, 0xD7E1EE, 0xDAA9EF);
        var light = new TerminalColors(0xEFE6D7, 0x222222, 0x493468);
        var darkPalette = Create(false, dark);
        var lightPalette = Create(true, light);
        var forcedLight = Create(true, dark);
        var lowContrast = Create(false, new TerminalColors(0x111111, 0x141414, 0x181818));
        return !IsLight(dark) && IsLight(light) && darkPalette.Canvas == Paint(dark.Background) &&
               darkPalette.Text == Paint(dark.Foreground) && darkPalette.Accent == Paint(dark.Accent) &&
               lightPalette.Canvas == Paint(light.Background) && lightPalette.Accent == Paint(light.Accent) &&
               forcedLight.Canvas != darkPalette.Canvas &&
               ReadsOn(lowContrast.Text, lowContrast.Canvas, lowContrast.Panel, 4.5);
    }
}
