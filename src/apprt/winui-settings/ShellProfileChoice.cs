using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace Madotty.Settings;

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class ShellProfileChoice : INotifyPropertyChanged
{
    private readonly ProfileSnapshot? source;
    private bool requested;

    internal ShellProfileChoice(string name, ProfileSnapshot? source = null) => (Name, this.source) = (name, source);
    public string Name { get; }
    public override string ToString() => Name;
    public ImageSource? Icon { get; private set; }
    public Visibility IconVisibility => Icon is null ? Visibility.Collapsed : Visibility.Visible;
    public event PropertyChangedEventHandler? PropertyChanged;

    internal async Task LoadIcon(Dictionary<string, Task<ImageSource?>> cache)
    {
        if (requested || source is null) return;
        requested = true;
        foreach (var path in new[] { source.Icon, source.Executable })
        {
            // Match native profile icons: a local asset or the shell executable.
            if (path is not { Length: >= 3 } || path[1] != ':' || !Path.IsPathFullyQualified(path)) continue;
            if (!cache.TryGetValue(path, out var load))
                cache[path] = load = ReadIcon(path);
            Icon = await load;
            if (Icon is null) continue;
            PropertyChanged?.Invoke(this, new(nameof(Icon)));
            PropertyChanged?.Invoke(this, new(nameof(IconVisibility)));
            return;
        }
    }

    private static async Task<ImageSource?> ReadIcon(string path)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path.Replace('/', '\\'));
            var image = new BitmapImage { DecodePixelWidth = 64 };
            var extension = Path.GetExtension(path).ToLowerInvariant();
            if (extension is ".ico" or ".png" or ".jpg" or ".jpeg" or ".bmp" or ".gif" or ".webp")
            {
                using var stream = await file.OpenReadAsync();
                await image.SetSourceAsync(stream);
            }
            else if (extension is ".exe" or ".dll")
            {
                using var thumbnail = await file.GetThumbnailAsync(ThumbnailMode.SingleItem, 64);
                if (thumbnail is null) return null;
                await image.SetSourceAsync(thumbnail);
            }
            else return null;
            return image;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or
            NotSupportedException or FormatException or System.Runtime.InteropServices.COMException)
        {
            return null;
        }
    }
}
