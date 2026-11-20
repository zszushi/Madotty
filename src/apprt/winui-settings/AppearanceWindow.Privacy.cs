using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Madotty.Settings;

internal sealed partial class AppearanceWindow
{
    private static readonly string[] ClipboardPolicyKeys = ["ask", "allow", "deny"];
    private static readonly string[] ClipboardPolicyLabels = [UiText.Get("Ask"), UiText.Get("Allow"), UiText.Get("Deny")];

    private readonly bool privacyAvailable;
    private readonly ComboBox clipboardRead = new() { ItemsSource = ClipboardPolicyLabels };
    private readonly ComboBox clipboardWrite = new() { ItemsSource = ClipboardPolicyLabels };
    private readonly ToggleSwitch pasteProtection = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ToggleSwitch detectLinks = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ToggleSwitch notifications = new() { HorizontalAlignment = HorizontalAlignment.Left };

    private record struct PrivacyDraft(int ClipboardRead, int ClipboardWrite, bool PasteProtection, bool DetectLinks, bool Notifications)
    {
        internal PrivacyDraft(PrivacySnapshot initial) : this(
            Array.IndexOf(ClipboardPolicyKeys, initial.ClipboardRead), Array.IndexOf(ClipboardPolicyKeys, initial.ClipboardWrite),
            initial.PasteProtection, initial.DetectLinks, initial.Notifications)
        { }

        internal bool IsValid => ClipboardRead >= 0 && ClipboardWrite >= 0;

        internal void AddEdits(PrivacyDraft saved, Dictionary<string, object> edits)
        {
            if (ClipboardRead != saved.ClipboardRead) edits.Add("clipboard-read", ClipboardPolicyKeys[ClipboardRead]);
            if (ClipboardWrite != saved.ClipboardWrite) edits.Add("clipboard-write", ClipboardPolicyKeys[ClipboardWrite]);
            if (PasteProtection != saved.PasteProtection) edits.Add("clipboard-paste-protection", PasteProtection);
            if (DetectLinks != saved.DetectLinks) edits.Add("link-url", DetectLinks);
            if (Notifications != saved.Notifications) edits.Add("desktop-notifications", Notifications);
        }
    }

    private FrameworkElement[] BuildPrivacy()
    {
        clipboardRead.SelectionChanged += (_, _) => Update();
        clipboardWrite.SelectionChanged += (_, _) => Update();
        pasteProtection.Toggled += (_, _) => Update();
        detectLinks.Toggled += (_, _) => Update();
        notifications.Toggled += (_, _) => Update();
        return
        [
            Section(UiText.Get("Clipboard"),
                Row(UiText.Get("ReadAccess"), clipboardRead, clipboardRead, "clipboard-read"),
                Row(UiText.Get("WriteAccess"), clipboardWrite, clipboardWrite, "clipboard-write"),
                Row(UiText.Get("ConfirmPaste"), pasteProtection, pasteProtection, "clipboard-paste-protection")),
            Section(UiText.Get("LinksNotifications"),
                Row(UiText.Get("DetectUrls"), detectLinks, detectLinks, "link-url"),
                Row(UiText.Get("AllowNotifications"), notifications, notifications, "desktop-notifications"))
        ];
    }

    private PrivacyDraft ReadPrivacy() => new(clipboardRead.SelectedIndex, clipboardWrite.SelectedIndex,
        pasteProtection.IsOn, detectLinks.IsOn, notifications.IsOn);

    private void PresentPrivacy(PrivacyDraft draft)
    {
        clipboardRead.SelectedIndex = draft.ClipboardRead;
        clipboardWrite.SelectedIndex = draft.ClipboardWrite;
        pasteProtection.IsOn = draft.PasteProtection;
        detectLinks.IsOn = draft.DetectLinks;
        notifications.IsOn = draft.Notifications;
    }

    private void SetPrivacyEnabled(bool enabled)
    {
        clipboardRead.IsEnabled = clipboardWrite.IsEnabled = enabled;
        pasteProtection.IsEnabled = detectLinks.IsEnabled = notifications.IsEnabled = enabled;
    }
}
