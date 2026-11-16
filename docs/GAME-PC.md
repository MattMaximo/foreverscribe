# ForeverScribe — game computer kit

This folder installs the ForeverScribe addon for World of Warcraft: Forever and, when your AI agent runs on a
different computer, a small sync agent that ships your SavedVariables to it after every `/reload`, logout or exit.
The addon is read-only: it records your character, it never plays, chats, trades or posts for you.

## macOS

Open Terminal in this folder, then one of:

```sh
./install.sh --addon-only                          # your agent runs on this Mac
./install.sh --pair fs1.xxxxxxxx                   # push to your agent's computer (code from `foreverscribe pair`)
./install.sh --folder "$HOME/Dropbox/ForeverScribe"   # or any synced folder: iCloud Drive, OneDrive, Google Drive…
```

Options: `--wow-dir "/Applications/World of Warcraft/_forever_"` (if WoW lives elsewhere), `--remind 30`
(one chat line after 30 min without a save; `/scribe remind off` stops it), `--dry-run` (show, change nothing).
Undo everything: `./uninstall.sh`.

## Windows

Open PowerShell in this folder, then one of:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddonOnly
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair fs1.xxxxxxxx
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Folder "$env:USERPROFILE\Dropbox\ForeverScribe"
```

Options: `-WowDir "D:\World of Warcraft\_forever_"`, `-Remind 30`, `-DryRun`. Undo: `.\install.ps1 -Uninstall`.
The sync agent runs as a per-user scheduled task ("ForeverScribe Sync", at logon); no administrator rights.

## After installing

1. Fully quit and restart WoW.
2. At character select → AddOns, make sure **ForeverScribe** is enabled.
3. Log in, type `/scribe status`, then `/reload`. Your agent sees it within a minute.

In-game commands: `/scribe status | last [n] | snapshot | errors | remind <min>|off | played on|off | live on|off`.

## What it touches

- `Interface/AddOns/ForeverScribe` and `ForeverScribe_Live` (an existing folder with that name is backed up first
  and restored on uninstall).
- macOS: `~/Library/Application Support/ForeverScribe/` and `~/Library/LaunchAgents/io.foreverscribe.sync.plist`.
- Windows: `%LOCALAPPDATA%\ForeverScribe\` and the "ForeverScribe Sync" scheduled task.
- It reads `WTF/Account/*/SavedVariables/ForeverScribe.lua` (plus files listed in `--extra`, default
  `ForeverForge*.lua`) and never writes inside the WoW folder.
