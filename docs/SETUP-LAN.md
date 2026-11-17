# Setup: WoW on one computer, agent on another, same home network (no Tailscale)

Example: WoW on a Windows PC, the AI agent on a Mac mini, both on the same Wi-Fi/router.

## On the agent computer (Mac mini)
1. Get the code: `git clone <this repo URL> && cd foreverscribe`
2. Find its network address: `ipconfig getifaddr en0` (Wi-Fi; try `en1` if empty). Example `<mac-mini-ip>`.
   Better: reserve that address for the Mac mini in your router, or use its Bonjour name (`<name>.local`, shown in
   System Settings → General → Sharing), so it doesn't change.
3. Configure: `bin/foreverscribe setup --mode http --bind 0.0.0.0 --public-url http://<mac-mini-ip>:8766`
4. Keep the receiver running: `bin/foreverscribe receiver launchagent --write`, then
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.foreverscribe.receiver.plist`.
   If macOS asks whether Python may accept incoming connections, click **Allow**.
5. Make a pairing code for the game PC: `bin/foreverscribe pair --name game-pc`. It prints the Windows install line.
   The code is a secret; send it privately.
6. Connect your agent: follow `SETUP-FOR-AGENTS.md` step 6 (MCP), or just ask it to run `bin/foreverscribe summary`.

## On the game PC (Windows)
1. Download the Windows zip from the latest release (this repo → Releases → latest)
   and unzip it.
2. In that folder, open PowerShell and run the line `pair` printed, e.g.
   `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair fs1.xxxxxxxx`
   (add `-WowDir "D:\...\_forever_"` if WoW isn't in the default folder).
3. Fully restart WoW, tick **ForeverScribe** (and its **ForeverScribe · Prices** / **Route** entries) under AddOns, log in, `/scribe status`, `/reload`.

## Check
On the Mac mini: `bin/foreverscribe receiver health` and `bin/foreverscribe summary` (should show your character
within a few seconds of the `/reload`). If nothing arrives: same network? Mac firewall allowed Python? Address changed?
