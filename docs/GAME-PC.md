# ForeverScribe — game computer kit

This folder installs the ForeverScribe addon for World of Warcraft: Forever and, when your AI agent runs on a
different computer, a small sync agent that ships your SavedVariables to it after every `/reload`, logout or exit.
The addon is read-only: it records your character, it never plays, chats, trades or posts for you.

## macOS

Open Terminal in this folder, then one of:

```sh
./install.sh --addon-only                          # your agent runs on this Mac
./install.sh --pair fs1.xxxxxxxx                   # push to your agent's computer (code from `foreverscribe pair`)
./install.sh --pair fs2.xxxxxxxx                   # through a hosted relay (code from `foreverscribe relay pair`)
./install.sh --folder "$HOME/Dropbox/ForeverScribe"   # or any synced folder: iCloud Drive, OneDrive, Google Drive…
```

Options: `--wow-dir "/Applications/World of Warcraft/_forever_"` (if WoW lives elsewhere), `--remind 30`
(one chat line after 30 min without a save; `/scribe remind off` stops it), `--dry-run` (show, change nothing).
Undo everything: `./uninstall.sh`.

## Windows

Open PowerShell in this folder, then one of:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddonOnly
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair fs1.xxxxxxxx     # or the fs2.… code from `foreverscribe relay pair`
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Folder "$env:USERPROFILE\Dropbox\ForeverScribe"
```

Options: `-WowDir "D:\World of Warcraft\_forever_"`, `-Remind 30`, `-DryRun`. Undo: `.\install.ps1 -Uninstall`.
The sync agent runs as a per-user scheduled task ("ForeverScribe Sync", at logon); no administrator rights.

## After installing

1. Fully quit and restart WoW (needed once: new addon folders are only found at launch).
2. At character select → AddOns, make sure **ForeverScribe** is enabled, including **ForeverScribe prices** and its
   ten "route slot" entries grouped under it (leave ForeverScribe Live off).
3. Log in, type `/scribe status`, then `/reload`. Your agent sees it within a minute.

In-game commands (`/scribe` or `/fs`): `status | last [n] | snapshot | errors | remind <min>|off | played on|off | live on|off | way <x> <y> [zone] [title]` (map pin + arrow; `way clear`) | `npcs` (NPCs noted; `npcs target off`).

Routes from your agent: `/fs go` loads the route it wrote (arrow to each stop, next stop on arrival), `/fs next`,
`/fs back`, `/fs route` (list), `/fs route clear`. Bind `/fs go` and "next stop" under Esc > Options > Keybindings >
AddOns > ForeverScribe. `/fs go` works 10 times per session; `/reload` resets that and keeps your place.

AH prices (0.6, when your agent has them on): item tooltips show an Auction House section (typical price, what your
stack is worth; hold Shift for listings, trend, the other faction and sell-or-vendor). The sync agent brings fresh
prices every ~30 minutes; the game reads them at login or `/reload`. `/scribe tooltip on|off|shift`.

## What it touches

- `Interface/AddOns/ForeverScribe`, `ForeverScribe_Live`, `ForeverScribe_Prices` and `ForeverScribe_Route01`…`10` (an existing folder with
  that name is backed up first and restored on uninstall).
- macOS: `~/Library/Application Support/ForeverScribe/` and `~/Library/LaunchAgents/io.foreverscribe.sync.plist`.
- Windows: `%LOCALAPPDATA%\ForeverScribe\` and the "ForeverScribe Sync" scheduled task.
- With an fs2 (relay) code, files are encrypted on this computer before they leave it; the relay only holds
  ciphertext. The key is in `relay.key` in the folder above (readable only by you).
- It reads `WTF/Account/*/SavedVariables/ForeverScribe.lua` plus files listed in `--extra` (default
  `ForeverForge*.lua Polestar.lua`), both in the account folder and in each character's
  `WTF/Account/<acct>/<realm>/<character>/SavedVariables/` folder (Polestar keeps your guide progress there).
  `--extra ""` ships ForeverScribe's file only. The only things it writes inside the WoW folder are `ForeverScribe_RouteNN/Route.lua` when
  your agent sends a route and `ForeverScribe_Prices/Prices.lua` when it sends AH prices (both checked line by line:
  plain data, never code).
