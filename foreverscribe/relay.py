"""foreverscribe relay — sync through a hosted relay when the game computer and this computer are on different
networks (no Tailscale, tunnel or port forwarding). Both sides connect out to the relay over HTTPS; everything is
encrypted end to end (relaycrypto.py), so the relay only ever holds ciphertext.

  foreverscribe relay pair [--relay URL] [--secret S] [--name N]   new channel + the fs2 code for the game computer
  foreverscribe relay pair --show                                   print the current code again
  foreverscribe relay sync [--once] [-v]                            fetch game saves, ingest, send route/prices back
  foreverscribe relay status [--json]                               relay health, last contact, pending files
  foreverscribe relay unpair                                        delete the channel on the relay (revokes both sides)
  foreverscribe relay launchagent [--write]                         macOS LaunchAgent that keeps `relay sync` running
  foreverscribe relay task                                          the Windows Scheduled Task command for the same

Setup: `foreverscribe setup --mode relay --relay-url https://<your relay>` writes config.toml ([relay] url). The
pairing (channel, both tokens, the encryption key) is kept in <data_dir>/relay/relay.json (mode 600). Docs: docs/RELAY.md.
"""
import argparse
import fnmatch
import json
import os
import sys
import time
import urllib.error
import urllib.request

from . import __version__, config as C, relaycrypto as RC

WAIT = 25
STATUS_EVERY = 300
ACTIVE_SECONDS = 15 * 60
DOWN = {"route": "route", "prices": "prices"}


def log(msg):
    print("%s relay %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)


# ---------------------------------------------------------------- files
def relay_dir(cfg):
    return os.path.join(cfg.data_dir, "relay")


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write(path, obj, private=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    try:
        os.remove(tmp)
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600 if private else 0o644)  # never readable by others
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, path)


def pairing(cfg):
    return _read(os.path.join(relay_dir(cfg), "relay.json"))


def state(cfg):
    return _read(os.path.join(relay_dir(cfg), "state.json")) or {"accepted": {}, "sent": {}, "since": 0}


def save_state(cfg, st):
    _write(os.path.join(relay_dir(cfg), "state.json"), st)


def relay_url(cfg, override=None):
    return (override or os.environ.get("FOREVERSCRIBE_RELAY_URL") or cfg.section("relay").get("url") or "").rstrip("/")


# ---------------------------------------------------------------- http
class RelayError(RuntimeError):
    def __init__(self, code, msg):
        RuntimeError.__init__(self, msg)
        self.code = code


MAX_RESPONSE = 16 * 1024 * 1024


def call(url, method="GET", token=None, body=None, headers=None, timeout=40):
    h = {"User-Agent": "foreverscribe/" + __version__}
    if token:
        h["Authorization"] = "Bearer " + token
    if body is not None:
        h["Content-Type"] = "application/octet-stream"
    h.update(headers or {})
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise RelayError(0, "relay answer too big")
            return r.status, raw, dict(r.headers)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            msg = json.loads(raw.decode()).get("error") or raw.decode()[:200]
        except ValueError:
            msg = raw.decode("utf-8", "replace")[:200]
        raise RelayError(e.code, "relay said %d: %s" % (e.code, msg))
    except (urllib.error.URLError, OSError) as e:
        raise RelayError(0, "relay unreachable: %s" % getattr(e, "reason", e))


def call_json(*a, **kw):
    code, body, _ = call(*a, **kw)
    return json.loads(body.decode() or "{}")


# ---------------------------------------------------------------- pair / unpair
def pair(cfg, url=None, secret=None, name="game-pc", force=False):
    url = relay_url(cfg, url)
    if not url:
        raise ValueError("Which relay? Pass --relay https://<your relay> or set [relay] url "
                         "(`foreverscribe setup --mode relay --relay-url ...`).")
    from urllib.parse import urlparse
    u = urlparse(url)
    if not (u.scheme == "https" or (u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost"))):
        raise ValueError("the relay must be an https:// URL (plain http only for a local test relay)")
    old = pairing(cfg)
    if old and not force:
        raise ValueError("Already paired with %s (channel %s...). `foreverscribe relay pair --show` prints the code "
                         "again; `relay unpair` first (or --force) for a new one." % (old["url"], old["channel"][:8]))
    if old and force:
        try:
            unpair(cfg)
        except RelayError:
            pass
    secret = secret or os.environ.get("FOREVERSCRIBE_RELAY_SECRET") or cfg.section("relay").get("create_secret") or ""
    hdr = {"X-FS-Relay-Secret": secret} if secret else {}
    d = call_json(url + "/v1/channels", "POST", body=b"", headers=hdr, timeout=20)
    p = {"v": 2, "url": url, "channel": d["channel"], "agent_token": d["agent_token"], "game_token": d["game_token"],
         "key": RC.new_master(), "name": name, "created": int(time.time()), "limits": d.get("limits")}
    _write(os.path.join(relay_dir(cfg), "relay.json"), p, private=True)
    save_state(cfg, {"accepted": {}, "sent": {}, "since": 0})
    return p


def code(p):
    return RC.encode_pairing(p["url"], p["channel"], p["game_token"], p["key"])


def unpair(cfg):
    p = pairing(cfg)
    if not p:
        raise ValueError("not paired with a relay")
    try:
        call_json("%s/v1/ch/%s" % (p["url"], p["channel"]), "DELETE", token=p["agent_token"], timeout=20)
        gone = True
    except RelayError as e:
        if e.code not in (403, 404):
            raise
        gone = False
    os.replace(os.path.join(relay_dir(cfg), "relay.json"), os.path.join(relay_dir(cfg), "relay.json.unpaired"))
    try:
        os.chmod(os.path.join(relay_dir(cfg), "relay.json.unpaired"), 0o600)
    except OSError:
        pass
    return gone


# ---------------------------------------------------------------- receive (game -> agent)
_UNSAFE = set(':<>"|?*\\')


def _safe_part(x):
    """A folder name that is the same single folder on macOS, Linux and Windows (no drive, no '..', no device)."""
    import re
    return (x and x.strip(". ") and not any(c in _UNSAFE or ord(c) < 32 for c in x)
            and not re.match(r"(?i)^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$", x))


def _push_dest(cfg, logical, extra):
    """'sv/<acct>/<file>' or 'sv/<acct>/<realm>/<char>/<file>' -> (path under data_dir/push, file name) or ValueError."""
    from .receiver import ACCT_RE, CHARDIR_RE, FILE_RE
    parts = logical.split("/")
    if parts[0] != "sv" or len(parts) not in (3, 5):
        raise ValueError("unexpected file %r" % logical[:80])
    acct, fname = parts[1], parts[-1]
    mid = parts[2:4] if len(parts) == 5 else []
    if (not ACCT_RE.match(acct) or not FILE_RE.match(fname) or any(not CHARDIR_RE.match(x) for x in mid)
            or not all(_safe_part(x) for x in [acct, fname] + mid)):
        raise ValueError("bad account, folder or file name in %r" % logical[:80])
    if not (fname == "ForeverScribe.lua" or any(fnmatch.fnmatch(fname, p) for p in extra)):
        raise ValueError("%s is not a file this agent collects ([sync] extra_saved_variables)" % fname)
    if mid and fname == "ForeverScribe.lua":
        raise ValueError("ForeverScribe.lua has no per-character copy")
    base = os.path.realpath(os.path.join(cfg.data_dir, "push", "Account"))
    dest = os.path.join(base, acct, *mid, "SavedVariables", fname)
    if os.path.commonpath([base, os.path.realpath(dest)]) != base:
        raise ValueError("%r would land outside the push folder" % logical[:80])
    return dest, fname


def receive(cfg, p, st, name, verbose=False):
    """Download one up/ blob, verify, decrypt, store it like the http receiver does and ingest it."""
    from . import store
    import re
    if not re.match(r"^up/[0-9a-f]{32}$", name or ""):
        raise ValueError("relay listed an unexpected name")
    bid = name.split("/", 1)[1]
    try:
        _, blob, _ = call("%s/v1/ch/%s/files/%s" % (p["url"], p["channel"], name), token=p["agent_token"], timeout=60)
    except RelayError as e:
        if e.code == 404:  # expired between the listing and the download
            raise ValueError("blob expired before it was fetched")
        raise
    logical, data, ts = RC.open_blob(p["key"], p["channel"], bid, blob)
    if ts < st["accepted"].get(logical, 0):
        log("skip %s: older than the copy already received" % logical)
        return None
    dest, fname = _push_dest(cfg, logical, C.extra_sv_patterns(cfg))
    if not data.rstrip().endswith(b"}"):
        raise ValueError("%s is incomplete" % logical)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = os.path.join(os.path.dirname(dest), ".%s.tmp.%d" % (fname, os.getpid()))
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, dest)
    st["accepted"][logical] = ts
    con = store.connect(cfg.db)
    try:
        res = store.ingest_sv_file(con, dest) if fname == "ForeverScribe.lua" else store.ingest_raw_file(con, dest)
    finally:
        con.close()
    log("got %s: %d bytes (%d on the wire), %s, events_new=%s" % (logical[3:], len(data), len(blob), res.get("status"),
                                                                 res.get("events_new")))
    return res


# ---------------------------------------------------------------- send (agent -> game)
def _down_sources(cfg):
    from . import prices, routes
    return {"route": os.path.join(routes.route_dir(cfg), "Route.lua"), "prices": prices.receiver_copy(cfg)}


def _rev(path):
    import re
    try:
        with open(path, "rb") as f:
            m = re.search(rb'\trev = "([\w.\-]+)"', f.read(4096))
        return m.group(1).decode() if m else ""
    except OSError:
        return ""


def push_down(cfg, p=None, st=None, force=False):
    """Upload the route and price files when their rev changed since the last upload. Returns what was sent."""
    p = p or pairing(cfg)
    if not p:
        return []
    own = st is None
    st = st if st is not None else state(cfg)
    sent = []
    for logical, src in _down_sources(cfg).items():
        rev = _rev(src)
        if not rev or (st["sent"].get(logical) == rev and not force):
            continue
        with open(src, "rb") as f:
            data = f.read()
        bid, blob = RC.seal(p["key"], p["channel"], logical, data)
        call_json("%s/v1/ch/%s/files/down/%s" % (p["url"], p["channel"], bid), "PUT", token=p["agent_token"], body=blob,
                  timeout=60)
        st["sent"][logical] = rev
        st.setdefault("sent_at", {})[logical] = int(time.time())
        sent.append((logical, rev, len(blob)))
        log("sent %s rev %s (%d bytes encrypted)" % (logical, rev, len(blob)))
    if own:
        save_state(cfg, st)
    return sent


def _pickups(cfg, p, st, status):
    """Record when the game computer fetched the current route / prices (for `route status` and `prices status`)."""
    from . import prices, routes
    files = status.get("files") or {}
    for logical, d in (("route", routes.route_dir(cfg)), ("prices", prices.price_dir(cfg))):
        f = files.get("down/" + RC.blob_id(p["key"], logical))
        if f is None and st["sent"].get(logical):
            st["sent"].pop(logical, None)  # expired or the relay was redeployed: send it again
            continue
        if f and f.get("got") and st["sent"].get(logical):
            path = os.path.join(d, "pickup.json")
            old = _read(path) or {}
            if old.get("at") != f["got"]:
                _write(path, {"rev": st["sent"][logical], "at": f["got"], "by": "relay"})


# ---------------------------------------------------------------- sync loop
def sync_once(cfg, p, st, wait=0, verbose=False):
    ev = call_json("%s/v1/ch/%s/events?since=%d&wait=%d" % (p["url"], p["channel"], st.get("since", 0), wait),
                   token=p["agent_token"], timeout=wait + 20)
    got = 0
    for f in ev.get("files") or []:
        try:
            if receive(cfg, p, st, f.get("name"), verbose):
                got += 1
        except RelayError:
            raise  # network trouble: keep `since`, try this file again
        except Exception as e:  # wrong key / tampered / not ours / unwritable: logged once, never retried
            log("ignored a blob: %s: %s" % (type(e).__name__, e))
        try:
            st["since"] = max(st.get("since", 0), int(f.get("seq") or 0))
        except (TypeError, ValueError):
            pass
    st["peer_seen"] = ev.get("peer_seen")
    if ev.get("peer_seen") and time.time() - ev["peer_seen"] < ACTIVE_SECONDS:
        try:
            from . import prices
            prices.refresh_async(cfg, log=log)  # prices stay fresh while the game computer is around
        except Exception as e:
            log("prices: refresh not started: %s" % e)
    push_down(cfg, p, st)
    save_state(cfg, st)
    return got


def sync(cfg, once=False, verbose=False):
    p = pairing(cfg)
    if not p:
        raise ValueError("not paired with a relay: run `foreverscribe relay pair` first")
    st = state(cfg)
    log("ForeverScribe %s relay sync: %s channel %s..." % (__version__, p["url"], p["channel"][:8]))
    last_status, backoff = 0, 5
    while True:
        try:
            if time.time() - last_status > STATUS_EVERY:
                s = call_json("%s/v1/ch/%s" % (p["url"], p["channel"]), token=p["agent_token"], timeout=20)
                _pickups(cfg, p, st, s)
                last_status = time.time()
            n = sync_once(cfg, p, st, wait=0 if once else WAIT, verbose=verbose)
            if verbose or once:
                log("%d new file(s)" % n)
            backoff = 5
            if once:
                return 0
        except RelayError as e:
            if e.code in (403, 404):
                log("%s. The channel is gone (unpaired, or the relay's RELAY_SECRET changed): run "
                    "`foreverscribe relay pair --force` and re-install the game side with the new code." % e)
                if once:
                    return 3
                time.sleep(60)
                newp = pairing(cfg)  # picked up a re-pair made while this loop was running
                if newp and newp["channel"] != p["channel"]:
                    p, st = newp, state(cfg)
                    log("now using the new pairing: channel %s..." % p["channel"][:8])
            else:
                log(str(e))
                if once:
                    return 2
                time.sleep(backoff)
                backoff = min(backoff * 2, 120)


# ---------------------------------------------------------------- status
def status(cfg):
    p = pairing(cfg)
    url = relay_url(cfg) or (p or {}).get("url") or ""
    out = {"url": url, "paired": bool(p)}
    if url:
        try:
            out["health"] = call_json(url + "/v1/health", timeout=10)
        except RelayError as e:
            out["health_error"] = str(e)
    if p:
        out["channel"] = p["channel"][:8] + "..."
        try:
            s = call_json("%s/v1/ch/%s" % (p["url"], p["channel"]), token=p["agent_token"], timeout=15)
            out["game_seen"] = (s.get("seen") or {}).get("game")
            out["files"] = {"from_game": sum(1 for n in s["files"] if n.startswith("up/")),
                            "to_game": sum(1 for n in s["files"] if n.startswith("down/"))}
            out["usage_today"] = (s.get("usage") or {}).get("bytes", 0)
        except RelayError as e:
            out["channel_error"] = str(e)
        st = state(cfg)
        out["received"] = len(st.get("accepted") or {})
        out["sent"] = st.get("sent") or {}
    return out


def _ago(t):
    if not t:
        return "never"
    d = int(time.time() - t)
    return "%ds ago" % d if d < 90 else "%dm ago" % (d // 60) if d < 5400 else "%.1fh ago" % (d / 3600.0)


def render_status(s):
    if not s["url"]:
        return "No relay configured (`foreverscribe setup --mode relay --relay-url https://...`)."
    lines = ["relay %s: %s" % (s["url"], ("up, version %s" % s["health"].get("version")) if s.get("health") else s.get("health_error"))]
    if not s["paired"]:
        lines.append("not paired yet: `foreverscribe relay pair`")
        return "\n".join(lines)
    if s.get("channel_error"):
        lines.append("channel %s: %s (pair again: `foreverscribe relay pair --force`)" % (s["channel"], s["channel_error"]))
    else:
        lines.append("channel %s: game computer last connected %s; on the relay now: %d file(s) from the game, %d to it; "
                     "%d KB moved today" % (s["channel"], _ago(s.get("game_seen")), s["files"]["from_game"],
                                           s["files"]["to_game"], s.get("usage_today", 0) // 1024))
    lines.append("received %d file(s) so far; sent: %s" % (s.get("received", 0), ", ".join(
        "%s %s" % kv for kv in s["sent"].items()) or "nothing yet"))
    return "\n".join(lines)


# ---------------------------------------------------------------- service helpers
LAUNCHAGENT = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>{label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{python}</string>
		<string>-m</string>
		<string>foreverscribe</string>
		<string>relay</string>
		<string>sync</string>
	</array>
	<key>WorkingDirectory</key><string>{repo}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PYTHONPATH</key><string>{repo}</string>
		<key>FOREVERSCRIBE_CONFIG</key><string>{config}</string>
	</dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>StandardOutPath</key><string>{log}</string>
	<key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"""


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    sub, rest = argv[0], argv[1:]
    cfg = C.load()
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        if sub == "pair":
            ap = argparse.ArgumentParser(prog="foreverscribe relay pair")
            ap.add_argument("--relay", help="relay URL (default [relay] url)")
            ap.add_argument("--secret", help="the relay's create secret, if it has one ([relay] create_secret)")
            ap.add_argument("--name", default="game-pc")
            ap.add_argument("--show", action="store_true", help="print the current pairing code again")
            ap.add_argument("--force", action="store_true", help="unpair the current channel and make a new one")
            ap.add_argument("--code-only", action="store_true")
            a = ap.parse_args(rest)
            p = pairing(cfg) if a.show else pair(cfg, a.relay, a.secret, a.name, a.force)
            if not p:
                print("not paired yet: run `foreverscribe relay pair`")
                return 1
            c = code(p)
            if a.code_only:
                print(c)
                return 0
            print("Relay channel %s... on %s. On the game computer, install the kit with this code (it is a secret: "
                  "don't post it):\n" % (p["channel"][:8], p["url"]))
            print("  macOS:   ./install.sh --pair %s" % c)
            print("  Windows: powershell -ExecutionPolicy Bypass -File .\\install.ps1 -Pair %s\n" % c)
            print("Then keep `foreverscribe relay sync` running here (`foreverscribe relay launchagent --write` on a Mac, "
                  "`foreverscribe relay task` on Windows). Revoke: foreverscribe relay unpair")
            return 0
        if sub == "unpair":
            gone = unpair(cfg)
            print("unpaired: the relay channel is %s; the game computer can no longer upload. Pair again with "
                  "`foreverscribe relay pair`." % ("deleted" if gone else "already gone"))
            return 0
        if sub == "sync":
            ap = argparse.ArgumentParser(prog="foreverscribe relay sync")
            ap.add_argument("--once", action="store_true", help="one pass, then exit")
            ap.add_argument("-v", "--verbose", action="store_true")
            a = ap.parse_args(rest)
            return sync(cfg, once=a.once, verbose=a.verbose)
        if sub == "status":
            s = status(cfg)
            print(json.dumps(s, indent=2) if "--json" in rest else render_status(s))
            return 0 if s.get("health") and s["paired"] and not s.get("channel_error") else 1
        if sub == "launchagent":
            ap = argparse.ArgumentParser(prog="foreverscribe relay launchagent")
            ap.add_argument("--label", default="io.foreverscribe.relay")
            ap.add_argument("--write", action="store_true")
            a = ap.parse_args(rest)
            body = LAUNCHAGENT.format(label=a.label, python=sys.executable, repo=repo, config=cfg["_path"],
                                      log=os.path.join(cfg.data_dir, "relay-sync.log"))
            if not a.write:
                print(body)
                return 0
            dest = os.path.expanduser("~/Library/LaunchAgents/%s.plist" % a.label)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w") as fh:
                fh.write(body)
            print("wrote %s\nload it: launchctl bootstrap gui/$(id -u) %s" % (dest, dest))
            return 0
        if sub == "task":
            py = sys.executable
            if py.lower().endswith("python.exe"):
                py = py[:-len("python.exe")] + "pythonw.exe"  # no console window
            print("Run once in PowerShell (your user, no admin) to keep `relay sync` running after every logon:\n")
            print("  $a = New-ScheduledTaskAction -Execute '%s' -Argument '-m foreverscribe relay sync' "
                  "-WorkingDirectory '%s'" % (py, repo))
            print("  $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 "
                  "-RestartInterval (New-TimeSpan -Minutes 1)")
            print("  Register-ScheduledTask -TaskName 'ForeverScribe Relay Sync' -Action $a -Settings $s "
                  "-Trigger (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME) -Force")
            print("  Start-ScheduledTask -TaskName 'ForeverScribe Relay Sync'")
            return 0
    except (ValueError, RelayError) as e:
        print(str(e))
        return 2
    print(__doc__)
    return 2
