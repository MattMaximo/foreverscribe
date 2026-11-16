# Transports: getting SavedVariables from the game to your agent

WoW writes `WTF/Account/<ACCOUNT>/SavedVariables/ForeverScribe.lua` on `/reload`, logout and exit (never while you
play). A transport moves that file to the agent side, where `foreverscribe` ingests it (unchanged files are skipped
by hash, events are de-duplicated by id, older files never overwrite newer data).

Choose with `[transport] mode` in the agent's `config.toml`.

## `local` — same computer

The companion reads every `WTF/Account/*/SavedVariables` folder under `[wow] dir` on each query. Nothing else runs.
Install with `install.sh --addon-only` / `install.ps1 -AddonOnly`. Latency: zero after the save.

## `folder` — any synced folder (no networking)

The game-side sync agent copies each save into `<folder>/<ACCOUNT>/` atomically (temp file + rename). Your sync
service carries it to the agent computer; `[transport] folder` points at the same folder there.

Works with iCloud Drive, Dropbox, OneDrive, Google Drive and Syncthing. Latency is whatever the service needs
(seconds to a few minutes; iCloud can be slower when the Mac is busy). Files still downloading (`.icloud`
placeholders, temp names) are ignored until complete.

## `http` — push to your receiver

The sync agent POSTs each save to `<url>/v1/sv/<ACCOUNT>` (extra addon files to `/v1/sv/<ACCOUNT>/<file>.lua`).
The receiver stores it and ingests at once: an agent sees the new state a second or two after `/reload`.

**Authentication: pairing keys, not addresses.** `foreverscribe pair` creates a random key for one game computer
and prints a code (`fs1.…`) containing the receiver URL, a key id and the key. The installer stores the key in a
file only the user can read. Every push carries:

```
X-FS-Key:  <key id>
X-FS-Time: <unix seconds>
X-FS-Sig:  hex(HMAC-SHA256(key, "fs1\n<time>\nPOST\n<path>\n<sha256 hex of body>"))
```

The key itself never crosses the wire. The receiver rejects unsigned, wrongly-signed, revoked, path-swapped, and
stale (> 10 min clock skew) requests. Revoke with `foreverscribe pair --revoke <id>`; list with `--list`.

Optional extras in `[receiver]`:
- `allow_ips` — also require the source address to be listed (defence in depth on a private network).
- `legacy_unsigned_ips` — **migration only**: accept unsigned pushes from these addresses, for a v0.2 kit that
  predates pairing keys. Remove once every game computer runs the 0.3 kit.

**Reaching the receiver** — any route you control:
- **LAN**: `bind` = the agent computer's LAN address; works at home only.
- **Tailscale / WireGuard**: `bind` = the agent computer's tailnet address; works anywhere both are online.
- **Your own tunnel** (e.g. Cloudflare Tunnel, `cloudflared tunnel --url http://127.0.0.1:8766`): `bind = "127.0.0.1"`,
  `public_url = "https://scribe.example.com"`. The signature still protects the endpoint; adding Cloudflare Access
  in front is a good extra (the sync agents then need a service token, which they don't support yet).

There is no TLS in the receiver itself: keep `bind` on a private interface or behind a TLS tunnel. Signatures
prevent forgery and replays beyond the skew window, not eavesdropping.

**When the receiver is down** the sync agent keeps the newest copy of each file in its `spool/` and retries on every
run (macOS: every save plus every 2 minutes; Windows: every 10 seconds). Nothing is lost, and an old spooled file
never replaces a newer one.

Both `--pair` and `--folder` can be set: the push is fast, the folder is a fallback.

## `pull` — over SSH (optional, ad hoc)

`foreverscribe pull` copies ForeverScribe.lua from `[pull] ssh_host` with `tar` over SSH. Useful for a one-off fetch;
not needed when a transport runs.

## Future: hosted relay (not built)

For players with no shared folder, LAN or tunnel, a small hosted **end-to-end encrypted mailbox** would work:

- `pair` would generate an X25519 key pair on the agent side; the code carries the public key and a mailbox id.
- The sync agent encrypts each file (e.g. libsodium sealed box) and uploads the ciphertext to the relay mailbox.
- The agent side polls (or holds a long-poll / WebSocket) and decrypts locally; the relay sees only opaque blobs,
  sizes and timing, and deletes after delivery or a short TTL.

It needs hosting, abuse limits and a crypto dependency (or a careful stdlib-only design), so it is deliberately left
out of 0.3.

## The other direction: routes (0.5)

`foreverscribe route write` sends a route back to the game computer over the same transport (details:
[`ROUTES-AND-NPCS.md`](ROUTES-AND-NPCS.md)):

- `local`: writes the route slot files in `Interface/AddOns` directly.
- `folder`: writes `<folder>/_route/Route.lua`; the game-side sync agent copies it into the slots (launchd watches
  `_route`; Windows checks every 10 s).
- `http`: the receiver keeps it; the game-side sync agent polls `POST /v1/route` (macOS every 30 s, Windows every 10 s),
  signed with its pairing key (legacy unsigned agents get nothing), with `X-FS-Have: <rev>` so an unchanged route is a
  `304`. The receiver records the fetch for `route status`.

Both sync agents validate the file line by line before copying it into the WoW folder.
