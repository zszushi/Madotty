//! Native presentation strings follow the Windows display language, independently of regional formats.
const std = @import("std");

extern "kernel32" fn GetThreadUILanguage() callconv(.winapi) u16;

pub fn isJapanese() bool {
    return japaneseLanguageId(GetThreadUILanguage());
}

fn japaneseLanguageId(id: u16) bool {
    return (id & 0x03ff) == 0x11;
}

pub fn wide(comptime en: [:0]const u8) [:0]const u16 {
    return if (isJapanese()) std.unicode.utf8ToUtf16LeStringLiteral(japanese(en)) else std.unicode.utf8ToUtf16LeStringLiteral(en);
}

pub fn text(comptime en: [:0]const u8) [:0]const u8 {
    return if (isJapanese()) japanese(en) else en;
}

pub fn print(buffer: []u8, comptime en: []const u8, args: anytype) std.mem.PrintError![]u8 {
    return if (isJapanese()) std.mem.print(buffer, japanese(en), args) else std.mem.print(buffer, en, args);
}

const translations = std.StaticStringMap([:0]const u8).initComptime(.{
    .{ "{d} panes", "{d}個のペイン" },
    .{ "Change Tab Title…", "タブのタイトルを変更…" },
    .{ "Change Terminal Title…", "ターミナルのタイトルを変更…" },
    .{ "Change Window Title…", "ウィンドウのタイトルを変更…" },
    .{ "Check for Updates", "更新を確認" },
    .{ "Close All Windows", "すべてのウィンドウを閉じる" },
    .{ "Close Terminal", "ターミナルを閉じる" },
    .{ "Copy Screen as ANSI Sequences to Temporary File and Copy Path", "画面をANSIシーケンスとして一時ファイルに保存してパスをコピー" },
    .{ "Copy Screen as ANSI Sequences to Temporary File and Open", "画面をANSIシーケンスとして一時ファイルに保存して開く" },
    .{ "Copy Screen as ANSI Sequences to Temporary File and Paste Path", "画面をANSIシーケンスとして一時ファイルに保存してパスを貼り付け" },
    .{ "Copy Screen as HTML to Temporary File and Copy Path", "画面をHTML形式で一時ファイルに保存してパスをコピー" },
    .{ "Copy Screen as HTML to Temporary File and Open", "画面をHTML形式で一時ファイルに保存して開く" },
    .{ "Copy Screen as HTML to Temporary File and Paste Path", "画面をHTML形式で一時ファイルに保存してパスを貼り付け" },
    .{ "Copy Screen to Temporary File and Copy Path", "画面を一時ファイルに保存してパスをコピー" },
    .{ "Copy Screen to Temporary File and Open", "画面を一時ファイルに保存して開く" },
    .{ "Copy Screen to Temporary File and Paste Path", "画面を一時ファイルに保存してパスを貼り付け" },
    .{ "Copy Selection as ANSI Sequences to Clipboard", "選択範囲をANSIシーケンスとしてコピー" },
    .{ "Copy Selection as ANSI Sequences to Temporary File and Copy Path", "選択範囲をANSIシーケンスとして一時ファイルに保存してパスをコピー" },
    .{ "Copy Selection as ANSI Sequences to Temporary File and Open", "選択範囲をANSIシーケンスとして一時ファイルに保存して開く" },
    .{ "Copy Selection as ANSI Sequences to Temporary File and Paste Path", "選択範囲をANSIシーケンスとして一時ファイルに保存してパスを貼り付け" },
    .{ "Copy Selection as HTML to Clipboard", "選択範囲をHTML形式でコピー" },
    .{ "Copy Selection as HTML to Temporary File and Copy Path", "選択範囲をHTML形式で一時ファイルに保存してパスをコピー" },
    .{ "Copy Selection as HTML to Temporary File and Open", "選択範囲をHTML形式で一時ファイルに保存して開く" },
    .{ "Copy Selection as HTML to Temporary File and Paste Path", "選択範囲をHTML形式で一時ファイルに保存してパスを貼り付け" },
    .{ "Copy Selection as Plain Text to Clipboard", "選択範囲をプレーンテキストでコピー" },
    .{ "Copy Selection to Temporary File and Copy Path", "選択範囲を一時ファイルに保存してパスをコピー" },
    .{ "Copy Selection to Temporary File and Open", "選択範囲を一時ファイルに保存して開く" },
    .{ "Copy Selection to Temporary File and Paste Path", "選択範囲を一時ファイルに保存してパスを貼り付け" },
    .{ "Copy Terminal Title to Clipboard", "ターミナルのタイトルをコピー" },
    .{ "End Search", "検索を終了" },
    .{ "Focus Split: Down", "下の分割ウィンドウにフォーカス" },
    .{ "Focus Split: Left", "左の分割ウィンドウにフォーカス" },
    .{ "Focus Split: Next", "次の分割ウィンドウにフォーカス" },
    .{ "Focus Split: Previous", "前の分割ウィンドウにフォーカス" },
    .{ "Focus Split: Right", "右の分割ウィンドウにフォーカス" },
    .{ "Focus Split: Up", "上の分割ウィンドウにフォーカス" },
    .{ "Focus Window: Next", "次のウィンドウにフォーカス" },
    .{ "Focus Window: Previous", "前のウィンドウにフォーカス" },
    .{ "Ghostty", "Ghostty" },
    .{ "Move Tab Left", "タブを左に移動" },
    .{ "Move Tab Right", "タブを右に移動" },
    .{ "Move Tab to New Window", "タブを新しいウィンドウに移動" },
    .{ "Next Search Result", "次の検索結果" },
    .{ "Open Config Using OS editor", "OS既定のエディターで設定ファイルを開く" },
    .{ "Open Config in New Terminal Window", "新しいターミナルウィンドウで設定ファイルを開く" },
    .{ "Paste from Selection", "選択クリップボードから貼り付け" },
    .{ "Previous Search Result", "前の検索結果" },
    .{ "Redo", "やり直す" },
    .{ "Reset Window Size", "ウィンドウサイズをリセット" },
    .{ "Scroll to Selection", "選択範囲へスクロール" },
    .{ "Show On-Screen Keyboard", "スクリーンキーボードを表示" },
    .{ "Show the GTK Inspector", "GTKインスペクターを表示" },
    .{ "Start Search", "検索を開始" },
    .{ "Toggle Float on Top", "最前面表示を切り替え" },
    .{ "Toggle Inspector", "インスペクターの表示を切り替え" },
    .{ "Toggle Read-Only Mode", "読み取り専用モードを切り替え" },
    .{ "Toggle Secure Input", "セキュア入力を切り替え" },
    .{ "Toggle Tab Overview", "タブの一覧表示を切り替え" },
    .{ "Undo", "元に戻す" },
    .{ "Madotty could not apply the settings. Check that the config folder is writable.", "設定を適用できませんでした。設定フォルダーへの書き込み権限を確認してください。" },
    .{ "A terminal theme name is too large to display in Settings.", "テーマ名が長すぎるため、設定に表示できません。" },
    .{ "The selected terminal theme could not be opened.", "選択したターミナルのテーマを開けませんでした。" },
    .{ "Choose a valid terminal theme for each appearance.", "ライトとダークそれぞれに使用できるテーマを選択してください。" },
    .{ "A keybinding is too large to display in Settings.", "キー割り当てが長すぎるため、設定に表示できません。" },
    .{ "A shader parameter is missing or outside its allowed range.", "シェーダーのパラメーターが不足しているか、範囲外の値が指定されています。" },
    .{ "Madotty could not read the shader file.", "シェーダーファイルを読み取れませんでした。" },
    .{ "Choose an absolute path to a shader file.", "シェーダーファイルの絶対パスを指定してください。" },
    .{ "Settings were saved, but a later config entry or launch option takes precedence.", "設定を保存しました。設定ファイルの後続の項目または起動オプションが優先されます。" },
    .{ "Madotty could not open the config file.", "設定ファイルを開けませんでした。" },
    .{ "Choose a startup profile from the list.", "一覧から起動プロファイルを選択してください。" },
    .{ "Choose a valid UI font family.", "画面表示に使用できるフォントを選択してください。" },
    .{ "Check the font size and opacity values.", "フォントサイズと不透明度を確認してください。" },
    .{ "Madotty could not read the settings changes.", "設定の変更内容を読み取れませんでした。" },
    .{ "This shader has too many parameters to show in Settings.", "シェーダーのパラメーターが多すぎるため、設定に表示できません。" },
    .{ "The shell process exited with code {d}.", "シェルが終了コード {d} で終了しました。" },
    .{ "Version {s} is available.\nVisit GitHub releases to download.", "バージョン {s} を GitHub からダウンロードできます。" },
    .{ "Open this terminal-supplied link in its registered application?\nThis may execute commands. Continue only if you trust the target.\n\n{s}", "ターミナルからのリンクを対応するアプリで開きますか？\nコマンドが実行される場合があります。リンク先を信頼できる場合のみ続行してください。\n\n{s}" },
    .{ "{d} of {d} tabs. * marks the active tab.", "{d}/{d} 件のタブ。* は現在のタブです。" },
    .{ "Renderer Unhealthy", "描画エラー" },
    .{ "The GPU renderer is in an unhealthy state; terminal output may stop updating.", "GPU の描画に問題が発生しました。ターミナルの表示が更新されなくなる場合があります。" },
    .{ "Command Succeeded", "コマンドが成功しました" },
    .{ "Command Failed", "コマンドが失敗しました" },
    .{ "Command Finished", "コマンドが終了しました" },
    .{ "Command finished.", "コマンドが終了しました。" },
    .{ "Command took {f} and exited with code {d}.", "実行時間は {f}、終了コードは {d} です。" },
    .{ "Command took {f}.", "実行時間は {f} です。" },
    .{ "&Close tab", "タブを閉じる(&C)" },
    .{ "&Switch", "切り替え(&S)" },
    .{ "A process is still running in this terminal.\nClose anyway?", "このターミナルでプロセスが実行中です。\nターミナルを閉じますか？" },
    .{ "Always", "常に表示" },
    .{ "An application is requesting access to read the clipboard.\n\nAllow this?", "アプリがクリップボードの読み取りを求めています。許可しますか？" },
    .{ "An application is requesting to write to the system clipboard.\n\nAllow this?", "アプリがクリップボードへの書き込みを求めています。許可しますか？" },
    .{ "Cancel", "キャンセル" },
    .{ "Clear Screen", "画面をクリア" },
    .{ "Close Other Tabs", "他のタブを閉じる" },
    .{ "Close Surface", "ペインを閉じる" },
    .{ "Close Tab", "タブを閉じる" },
    .{ "Close Tabs to the Right", "右側のタブを閉じる" },
    .{ "Close Window", "ウィンドウを閉じる" },
    .{ "Command Prompt", "コマンド プロンプト" },
    .{ "Copy", "コピー" },
    .{ "Copy Title to Clipboard", "タイトルをコピー" },
    .{ "Copy URL to Clipboard", "URL をコピー" },
    .{ "Copy to Clipboard", "クリップボードにコピー" },
    .{ "Could not open Windows settings.", "Windows の設定を開けませんでした。" },
    .{ "Could not save settings. Check that the config folder is writable.", "設定を保存できませんでした。設定フォルダーへの書き込み権限を確認してください。" },
    .{ "Dark", "ダーク" },
    .{ "Decrease Font Size", "フォントサイズを小さくする" },
    .{ "Default terminal", "既定のターミナル" },
    .{ "Enter a font size from 1 to 255 pt.", "フォントサイズは 1 ～ 255 pt で入力してください。" },
    .{ "Enter an opacity from 0 to 100%.", "不透明度は 0 ～ 100% で入力してください。" },
    .{ "Equalize Splits", "ペインのサイズを揃える" },
    .{ "Export Terminal IO Events", "ターミナルの入出力イベントをエクスポート" },
    .{ "Find", "検索" },
    .{ "Focus Next Split", "次のペインに移動" },
    .{ "Focus Previous Split", "前のペインに移動" },
    .{ "Focus Split Down", "下のペインに移動" },
    .{ "Focus Split Left", "左のペインに移動" },
    .{ "Focus Split Right", "右のペインに移動" },
    .{ "Focus Split Up", "上のペインに移動" },
    .{ "Ghostty Update Available", "Madotty の更新があります" },
    .{ "Increase Font Size", "フォントサイズを大きくする" },
    .{ "Last Tab", "最後のタブ" },
    .{ "Light", "ライト" },
    .{ "Madotty \u{2014} Authorize Clipboard Access", "Madotty — クリップボードへのアクセス" },
    .{ "Madotty \u{2014} Potentially Unsafe Paste", "Madotty — 貼り付けの確認" },
    .{ "Never", "表示しない" },
    .{ "New Tab", "新しいタブ" },
    .{ "New Window", "新しいウィンドウ" },
    .{ "Next Tab", "次のタブ" },
    .{ "Open Config", "設定を開く" },
    .{ "Open external link?", "外部リンクを開きますか？" },
    .{ "Paste", "貼り付け" },
    .{ "Paste from Clipboard", "クリップボードから貼り付け" },
    .{ "Previous Tab", "前のタブ" },
    .{ "Processes are still running in this tab.\nClose the tab and all its splits?", "このタブでプロセスが実行中です。\nすべてのペインとタブを閉じますか？" },
    .{ "Processes are still running in this window.\nClose anyway?", "このウィンドウでプロセスが実行中です。\nウィンドウを閉じますか？" },
    .{ "Quit", "終了" },
    .{ "Reload Config", "設定を再読み込み" },
    .{ "Reset Font Size", "フォントサイズをリセット" },
    .{ "Reset Mouse Reporting", "マウス入力の通知をリセット" },
    .{ "Reset Terminal", "ターミナルをリセット" },
    .{ "Scroll Page Down", "1 ページ下にスクロール" },
    .{ "Scroll Page Up", "1 ページ上にスクロール" },
    .{ "Scroll to Bottom", "末尾にスクロール" },
    .{ "Scroll to Top", "先頭にスクロール" },
    .{ "Search &tabs", "タブを検索(&T)" },
    .{ "Search Selection", "選択したテキストを検索" },
    .{ "Select All", "すべて選択" },
    .{ "Settings", "設定" },
    .{ "Split Down", "下に分割" },
    .{ "Split Left", "左に分割" },
    .{ "Split Right", "右に分割" },
    .{ "Split Up", "上に分割" },
    .{ "System", "システムに合わせる" },
    .{ "Tab Overview", "タブの一覧" },
    .{ "Tab overview", "タブの一覧" },
    .{ "Terminal background", "ターミナルの背景に合わせる" },
    .{ "Text files (*.txt)\x00*.txt\x00All files (*.*)\x00*.*\x00", "テキスト ファイル (*.txt)\x00*.txt\x00すべてのファイル (*.*)\x00*.*\x00" },
    .{ "The shell process exited unexpectedly.", "シェルが予期せず終了しました。" },
    .{ "The text being pasted contains characters that could run commands unexpectedly (for example, newlines).\n\nPaste anyway?", "貼り付けるテキストに改行などが含まれています。意図しないコマンドが実行される可能性があります。\n\n貼り付けますか？" },
    .{ "This window was opened with the default config file disabled.", "このウィンドウでは既定の設定ファイルが無効です。" },
    .{ "Toggle Background Opacity", "背景の透明化を切り替え" },
    .{ "Toggle Fullscreen", "全画面表示を切り替え" },
    .{ "Toggle Maximize", "最大化を切り替え" },
    .{ "Toggle Mouse Reporting", "マウス入力の通知を切り替え" },
    .{ "Toggle Quick Terminal", "クイックターミナルの表示を切り替え" },
    .{ "Toggle Read-Only", "読み取り専用を切り替え" },
    .{ "Toggle Split Zoom", "ペインの拡大を切り替え" },
    .{ "Toggle Window Decorations", "ウィンドウ枠の表示を切り替え" },
    .{ "Type a command...", "コマンドを入力…" },
    .{ "When multiple tabs are open", "複数のタブがあるときに表示" },
});

pub fn japanese(comptime en: []const u8) [:0]const u8 {
    return comptime translations.get(en) orelse @compileError("Missing Japanese translation: " ++ en);
}

test "native display language recognizes Japanese language variants" {
    try std.testing.expect(japaneseLanguageId(0x0411));
    try std.testing.expect(japaneseLanguageId(0x0811));
    try std.testing.expect(!japaneseLanguageId(0x0409));
    try std.testing.expect(!japaneseLanguageId(0));
    try std.testing.expectEqualStrings("タブを閉じる", japanese("Close Tab"));
    var output: [128]u8 = undefined;
    const formatted = try std.mem.print(&output, japanese("The shell process exited with code {d}."), .{42});
    try std.testing.expectEqualStrings("シェルが終了コード 42 で終了しました。", formatted);
}
