# Install ForeverScribe (agents)

Goal: the user's WoW: Forever character data reaches you. Do every step yourself; the user only answers your
questions and runs one line on the game computer. Needs Python 3.8+ (stdlib only).
`FS` = `~/foreverscribe/bin/foreverscribe` (Windows `%USERPROFILE%\foreverscribe\bin\foreverscribe.cmd`).

## 1. Clone
```sh
git clone https://github.com/MattMaximo/foreverscribe ~/foreverscribe && FS version
```

## 2. Detect, then ask once
WoW on this computer if `_forever_` exists (macOS `/Applications/World of Warcraft/_forever_`, Windows
`C:\Program Files*\World of Warcraft\_forever_`). Otherwise ask in ONE message: game computer Windows or Mac?
Relay invite code (from whoever shared this)? If no invite: same home network, or a shared Dropbox/iCloud/OneDrive folder?

## 3. Configure (one row)
| Case | Do |
|---|---|
| WoW here | `FS setup --mode local`, then `installers/macos/install.sh --addon-only` (Windows: `powershell -ExecutionPolicy Bypass -File installers\windows\install.ps1 -AddonOnly`) |
| Elsewhere + invite (default) | `FS setup --mode relay --relay-url https://thousand-truths-j6isf.ondigitalocean.app --relay-secret <invite>`; `FS relay pair --name game-pc` (prints the fs2 code); keep sync running: macOS `FS relay launchagent --write` + the `launchctl bootstrap` line it prints, Windows `FS relay task` |
| Elsewhere, same network, no invite | `docs/SETUP-LAN.md` |
| Elsewhere, shared folder | `FS setup --mode folder --folder "<path here>"` |

Own relay instead: `docs/RELAY.md`. Never create cloud accounts or spend money for the user.
AH prices are opt-in (`config.example.toml` `[ah]`, `docs/PRICES.md`).

## 4. Game computer (other-computer cases)
Give the user the zip for their OS from https://github.com/MattMaximo/foreverscribe/releases/latest and ONE line,
run inside the unzipped folder:
- Windows (PowerShell): `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair <fs2 code>` (folder: `-Folder "<path there>"`)
- macOS (Terminal): `./install.sh --pair <fs2 code>` (folder: `--folder "<path there>"`)

Then tell them: "Restart WoW, tick ForeverScribe and ForeverScribe prices under AddOns, log in, /reload."

## 5. Verify
`FS summary` shows the character. If not: `FS doctor`; relay: `FS relay status`; game-side log
`~/Library/Application Support/ForeverScribe/sync.log` / `%LOCALAPPDATA%\ForeverScribe\sync.log`.

## 6. Connect and use
- MCP: `<python3> -m foreverscribe mcp` with `PYTHONPATH=<repo>` (snippets: `docs/AGENT-SETUP.md`). No MCP: same names via the CLI.
- Answering questions: add `skills/AGENT-INSTRUCTIONS.md` to your instructions.

## Rules
- Read-only towards the game; only `route write` and `prices write` send files to it. Never press keys or `/reload` for the user.
- Secrets: fs1./fs2. codes, invite codes, `<data dir>/relay/relay.json`, `receiver-keys.json`. Never post or commit them or the user's config/data.
- Leaked fs2 code: `FS relay unpair`, `FS relay pair`, reinstall the game side.
