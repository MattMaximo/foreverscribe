# Hosted relay: game and agent computers on different networks

Use the `relay` transport when the game computer and the agent computer are on different networks and you don't want
Tailscale, a tunnel or port forwarding. Both computers connect **out** to one small relay over HTTPS. The relay is
an end-to-end encrypted mailbox: it holds ciphertext for a few days and never sees a file, a file name, an account
or a character.

```
 game computer                     relay (DigitalOcean App Platform)            agent computer
 sync agent ── PUT encrypted save ─▶  mailbox: latest blob per name  ◀── long poll + GET ── foreverscribe relay sync
            ◀── GET route/prices ──   (7 days, 8 MB each)            ── PUT encrypted route/prices ──
```

One person hosts the relay (it costs about $5 a month) and can share it with friends: every pairing gets its own
channel and keys.

## 1. Deploy the relay (once, about 10 minutes)

You need a DigitalOcean account with a payment method, and a GitHub account that can see this repository (your own
fork works too).

1. **Create the app.** In the DigitalOcean dashboard: **Create → App Platform**. Pick **GitHub** as the source and
   authorize DigitalOcean for this repository. Choose the repository, branch `main`, source directory `/`. Leave
   **Autodeploy** ticked if you want each push to `main` to redeploy (see *Redeploys* below), or untick it to deploy by
   hand. DigitalOcean finds the `Dockerfile` at the repository root by itself; it builds only the relay
   (`relay/app.py`), not the companion.
2. **Size and port.** On the resources step, edit the web service: plan **Basic**, size **$5/mo (512 MB RAM, 1 shared
   vCPU)**, **1 container** (it must be exactly one; the relay keeps its mailbox on that container's disk). HTTP port
   `8080`. Under **Health checks** set the HTTP path to `/v1/health`.
3. **Environment variables** (on the same screen or later under *Settings → relay → Environment Variables*). Add both
   and tick **Encrypt**:
   - `RELAY_SECRET`: a long random value, e.g. the output of `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`.
     It signs every pairing's tokens. Keep it the same forever: changing it revokes every pairing at once.
   - `RELAY_CREATE_SECRET`: a second random value. This is the invite code people need to make a pairing on your
     relay; give it only to friends you share the relay with. Leave it unset and anyone who finds the URL can make
     channels (they still can't read anyone else's).
4. **Region and name.** Pick the region closest to you (e.g. New York), name the app `foreverscribe-relay`, then
   **Create Resources**. The first build takes a few minutes.
5. **Get the URL.** When the deploy is green, copy the app's URL from the top of its page:
   `https://foreverscribe-relay-xxxxx.ondigitalocean.app`. Check it in a browser: `…/v1/health` should show
   `{"ok":true,"service":"foreverscribe-relay","version":"0.9.0"}`.

Using `doctl` instead of the dashboard: edit `.do/app.yaml` (your GitHub user and both secrets), then
`doctl apps create --spec .do/app.yaml`.

**Cost.** One $5/month container (the free static-site tier can't run a service). It includes 50 GiB of outbound
transfer a month; a busy player moves a few MB a day. Price as of November 2026: check
<https://www.digitalocean.com/pricing/app-platform>.

## 2. Agent computer

```sh
FS setup --mode relay --relay-url https://foreverscribe-relay-xxxxx.ondigitalocean.app --relay-secret <RELAY_CREATE_SECRET>
FS relay pair --name "game PC"        # prints the fs2 code and the install line for the game computer
```

Keep `FS relay sync` running. It long-polls the relay (a new save arrives within a second or two), decrypts,
ingests, and sends routes and AH prices back:

- macOS: `FS relay launchagent --write`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.foreverscribe.relay.plist`
- Windows: `FS relay task` prints the PowerShell lines that register a Scheduled Task (your user, at logon)
- Linux: a `systemd --user` service running `python3 -m foreverscribe relay sync` with `PYTHONPATH=<repo>`

`FS relay status` (or `FS doctor`) shows the relay's health, when the game computer last connected and what's
waiting. `FS route status` / `FS prices status` say when the game computer picked up the last route or price file.

## 3. Game computer

Unzip the kit for its OS and run the line `relay pair` printed:

```sh
./install.sh --pair fs2.…                                                  # macOS
```
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair fs2.…         # Windows
```

The installer checks the relay and the channel. Restart WoW, log in, `/reload`; `FS summary` on the agent computer
shows the character a few seconds later.

## Security

- **End to end.** The fs2 code carries a 256-bit key made on the agent computer. Each file is gzipped, encrypted
  with AES-256-CBC under a key derived from it, and authenticated with HMAC-SHA256 over the channel id, the blob
  name, the timestamp and the ciphertext (encrypt-then-MAC; the tag is checked before anything is decrypted). The
  relay only stores the result. File names travel inside the ciphertext; the relay sees a 32-hex HMAC instead.
  Format and the reasons for these primitives: `foreverscribe/relaycrypto.py`. All three implementations (Python
  standard library, bash with `openssl`, PowerShell with .NET) are tested against each other and against a fixed
  vector (`tests/fixtures/relay_vector.json`).
- **Capabilities, not accounts.** The game computer's token can only upload saves and read the route and price
  files; the agent's token can only read saves, upload route and prices, and unpair. Tokens are HMACs under
  `RELAY_SECRET`, so the relay stores no credentials. A stolen game token lets someone fill that channel's mailbox
  with junk the agent side rejects; it can't read your data or pretend to be your saves (they wouldn't carry a
  valid tag).
- **What the relay can see:** that a channel exists, blob sizes and times, and the IP addresses that connect. Its
  log has the first 8 characters of a channel id, directions and sizes; never tokens or contents.
- **The fs2 code is a secret** (it holds the key). Don't post it. If it leaks: `FS relay unpair` then
  `FS relay pair` and re-install the game side with the new code.
- **Rollback.** Each side refuses an authenticated file older than the one it already has (the time is inside the
  signed header), so a relay can't quietly swap an old save, route or price file back in.
- On a game Mac, the derived AES and MAC keys are passed to `openssl` on its command line for a moment (other
  accounts on that Mac could see them with `ps`); the upload token goes to `curl` from a private file.
- HTTPS is terminated by App Platform; CORS is off; there are no docs or other pages. The relay ignores
  `X-Forwarded-For` (only App Platform's own `do-connecting-ip` counts for the per-address limit).

## Limits (environment variables, defaults)

| Variable | Default | Meaning |
|---|---|---|
| `RELAY_MAX_BLOB_MB` | 8 | largest single file (after gzip + encryption; a big ForeverScribe.lua is ~4x smaller) |
| `RELAY_MAX_FILES` | 64 | files per channel and direction (the latest copy per name is kept) |
| `RELAY_CHANNEL_MB` | 128 | stored per channel |
| `RELAY_MAX_UPLOADS` | 8 | uploads streamed at the same time (keeps memory small on the 512 MB container) |
| `RELAY_TTL_DAYS` | 7 | a blob nobody replaced is deleted after this |
| `RELAY_IDLE_DAYS` | 30 | a channel nobody used is deleted after this |
| `RELAY_MAX_TOTAL_MB` | 1024 | all channels together |
| `RELAY_MAX_CHANNELS` | 500 | |
| `RELAY_RATE_PER_MIN` | 240 | requests per token per minute |
| `RELAY_CREATE_PER_HOUR` | 20 | new channels per client address per hour |
| `RELAY_DAILY_MB` | 2048 | bytes in + out per channel per day |

## Redeploys, restarts and revoking

The relay is a mailbox, not storage. App Platform's disk is wiped on every deploy or restart, so blobs nobody had
fetched yet are lost. That is fine: the game computer sends again on its next save (or `/reload`), and the agent
side re-sends the route and prices when it sees they're gone. Pairings survive a redeploy because tokens are
derived from `RELAY_SECRET`.

`FS relay unpair` deletes the channel's blobs and makes the relay refuse both tokens; the agent side also forgets
the key. The refusal list lives on the container disk, so after a later redeploy a revoked game token could upload
into that channel again, but nobody holds the key to read it any more and the channel expires after 30 idle days.
To cut every pairing off for good, change `RELAY_SECRET`.

Run the relay yourself for testing (Python 3.9+):

```sh
python3 -m venv relay/.venv && relay/.venv/bin/pip install -r relay/requirements-dev.txt
cd relay && RELAY_SECRET=dev RELAY_DATA_DIR=/tmp/relay-data .venv/bin/python -m uvicorn app:app --host 127.0.0.1 --port 8080
```

Plain `http://` relay URLs are accepted only for `127.0.0.1`/`localhost`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| installer: "relay not reachable" | the URL is wrong or the app is still deploying; files wait in the game-side spool |
| game log: "relay refused … channel unpaired or relay redeployed" | `FS relay pair --force` on the agent, re-install the game side with the new code |
| `relay pair`: "needs its create secret" | `--secret <RELAY_CREATE_SECRET>` (or `[relay] create_secret`) |
| `relay pair`: "isn't set up yet" | the app still has the `change-me` values from `.do/app.yaml`: set both secrets |
| agent log: "ignored a blob: authentication failed" | someone uploaded with the game token but without the key (leaked token): re-pair |
| nothing arrives | `FS relay status`: when did the game computer last connect? Game side: `sync.log` in the kit's support folder |
