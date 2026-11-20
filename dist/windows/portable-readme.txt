Madotty — @VERSION@
https://github.com/zszushi/Madotty

QUICK START
  1. Run ghostty.exe
  2. Config file: %LOCALAPPDATA%\ghostty\config.ghostty
     (the legacy filename "config" is also supported)
  Keep ghostty.com, conpty.dll and OpenConsole.exe beside ghostty.exe.
  In PowerShell, list themes with .\ghostty.com +list-themes.

KEYBOARD SHORTCUTS
  Ctrl+Shift+T        New tab
  Ctrl+Shift+W        Close tab/pane
  Ctrl+Shift+N        New window
  Ctrl+Shift+P        Command palette
  Ctrl+Shift+O        Split right
  Ctrl+Shift+E        Split down
  Ctrl+Shift+[ / ]    Navigate splits
  Ctrl+Shift+C / V    Copy / Paste
  Ctrl+Shift+F        Find
  Ctrl+Enter          Toggle fullscreen
  Ctrl+= / - / 0      Zoom in / out / reset
  Ctrl+,              Open config file

SHELL INTEGRATION (PowerShell)
  Windows PowerShell 5.1 (powershell.exe) and PowerShell 7 (pwsh.exe)
  load the bundled integration automatically when enabled.
  No PowerShell profile edit is required. Keep the share/ folder beside
  ghostty.exe wherever you extract this portable package.
  The script is share/ghostty/shell-integration/powershell/ghostty-shell-integration.ps1.
  To disable integration, set shell-integration = none in your config.

For full documentation: https://ghostty.org/docs
