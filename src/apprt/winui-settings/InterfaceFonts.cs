using System.Runtime.InteropServices;

namespace Madotty.Settings;

internal static class InterfaceFonts
{
    // LOGFONTW is also the first field of ENUMLOGFONTEXW.
    [StructLayout(LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct LogFont
    {
        internal int Height, Width, Escapement, Orientation, Weight;
        internal byte Italic, Underline, Strikeout, CharSet, OutPrecision, ClipPrecision, Quality, PitchAndFamily;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string FaceName;
    }

    private delegate int FontCallback(in LogFont font, IntPtr metrics, uint type, IntPtr context);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr device);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr device);
    [DllImport("gdi32.dll")] private static extern int EnumFontFamiliesExW(IntPtr device, in LogFont filter,
        FontCallback callback, IntPtr context, uint flags);

    internal static string[] Installed(string configured)
    {
        var families = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (configured.Length > 0)
            families.Add(configured);
        var dc = CreateCompatibleDC(IntPtr.Zero);
        if (dc != IntPtr.Zero)
        {
            try
            {
                var filter = new LogFont { CharSet = 1, FaceName = "" }; // DEFAULT_CHARSET enumerates all scripts.
                EnumFontFamiliesExW(dc, filter, (in LogFont font, IntPtr metrics, uint type, IntPtr context) =>
                {
                    if (font.FaceName.Length is > 0 and <= 31 && font.FaceName[0] != '@' && !font.FaceName.Any(char.IsControl))
                        families.Add(font.FaceName);
                    return 1;
                }, IntPtr.Zero, 0);
            }
            finally
            {
                DeleteDC(dc);
            }
        }
        return families.Order(StringComparer.CurrentCultureIgnoreCase).Prepend(UiText.Get("SystemDefault")).ToArray();
    }
}
