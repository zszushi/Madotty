このフォルダーは、この PC で Madotty を既定のターミナルとして試すためのものです。
「Madotty」フォルダーは、登録後も同じ場所に置いてください。

1. このファイルの隣にある Madotty-Local.cer を開き、「詳細」の「拇印」を確認します。
   拇印（SHA-1）　@THUMBPRINT@
   有効期限（UTC）　@EXPIRY@
2. 「証明書のインストール」で「ローカル コンピューター」を選び、管理者の確認を行います。
   「証明書をすべて次のストアに配置する」から「信頼されたユーザー（Trusted People）」を選びます。
3. Madotty\settings\Madotty.Settings.exe を起動します。「起動」→「既定のターミナル アプリ」で
   「Madotty を登録」を押し、開いた Windows 設定のターミナルの一覧で「Madotty」を選びます。
4. 新しいコマンドプロンプトを開き、Madotty で起動することを確認します。

元に戻すには、Windows 設定で以前のターミナルを選び、Windows PowerShell で
Madotty\unregister-handoff.ps1 を実行します。「コンピューター証明書の管理」の
「信頼されたユーザー」から上記の拇印の証明書を削除すると、この証明書への信頼も解除できます。
