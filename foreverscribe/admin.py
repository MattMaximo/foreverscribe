"""Setup and transport commands: setup, pair, receiver, doctor, config.

  foreverscribe setup [--mode local|folder|http|relay] [--wow-dir DIR] [--folder DIR] [--bind IP] [--port N]
                      [--public-url URL] [--relay-url URL] [--relay-secret S] [--data-dir DIR] [--character NAME]
                      [--market M] [--force]
  foreverscribe pair [--name NAME] [--url URL] [--list] [--revoke ID]
  foreverscribe receiver [run | health | launchagent [--write] [--label L]]
  foreverscribe doctor
  foreverscribe config [path | show]
"""

import argparse
import json
import os
import platform
import sys
import urllib.request

from . import __version__, auth, config as C, store

EXAMPLE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config.example.toml")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _p(*a):
    print(*a)


# ---------------------------------------------------------------- setup
def cmd_setup(argv):
    ap = argparse.ArgumentParser(prog="foreverscribe setup", description="write config.toml for this computer (agent side)")
    ap.add_argument("--mode", choices=["local", "folder", "http", "relay"], help="local: WoW on this computer; folder: a "
                    "synced folder brings the files; http: the game computer pushes to this computer's receiver; relay: "
                    "both computers connect out to a hosted relay (different networks, nothing to open)")
    ap.add_argument("--relay-url", help="the hosted relay's https URL (mode relay)")
    ap.add_argument("--relay-secret", help="the relay's create secret, if it has one (mode relay)")
    ap.add_argument("--wow-dir", help="the _forever_ folder (mode local)")
    ap.add_argument("--account", action="append", help="limit to these WTF/Account folder names")
    ap.add_argument("--folder", help="synced folder the game computer copies into (mode folder)")
    ap.add_argument("--bind", help="receiver address (mode http), e.g. a LAN/Tailscale IP or 127.0.0.1 behind a tunnel")
    ap.add_argument("--port", type=int)
    ap.add_argument("--public-url", help="URL the game computer uses to reach the receiver (default http://<bind>:<port>)")
    ap.add_argument("--data-dir")
    ap.add_argument("--character", help="default character (name or Realm:Name)")
    ap.add_argument("--market", help="AH realm market for `ah` (prices stay off until [ah] enabled = true)")
    ap.add_argument("--force", action="store_true", help="overwrite an existing config")
    ap.add_argument("--print", action="store_true", help="print the config instead of writing it")
    a = ap.parse_args(argv)
    path = C.config_path()
    if os.path.exists(path) and not a.force and not a.print:
        _p("Config already exists: %s\nEdit it by hand, or re-run with --force to rewrite it." % path)
        return 1
    cfg = C.load(path=path + ".does-not-exist")  # defaults only
    d = {k: v for k, v in cfg.items() if not k.startswith("_")}
    mode = a.mode
    wow = a.wow_dir or C.wow_dir(cfg)
    if not mode:
        mode = "local" if wow else "http"
    d["transport"]["mode"] = mode
    if a.data_dir:
        d["data_dir"] = a.data_dir
    if a.character:
        d["default_character"] = a.character
    if mode == "local":
        if not wow:
            _p("Couldn't find WoW: Forever. Pass --wow-dir \"<...>/World of Warcraft/_forever_\".")
            return 2
        d["wow"]["dir"] = wow
        d["wow"]["accounts"] = a.account or []
    if mode == "folder":
        if not a.folder:
            _p("mode folder needs --folder <the synced folder the game computer copies into>")
            return 2
        d["transport"]["folder"] = a.folder
    if mode == "http":
        d["receiver"]["bind"] = a.bind or "127.0.0.1"
        d["receiver"]["port"] = a.port or 8766
        d["receiver"]["public_url"] = a.public_url or ""
    if mode == "relay":
        if not a.relay_url:
            _p("mode relay needs --relay-url https://<your relay> (docs/RELAY.md)")
            return 2
        d["relay"]["url"] = a.relay_url.rstrip("/")
        d["relay"]["create_secret"] = a.relay_secret or ""
    if a.market:
        d["ah"]["market"] = a.market
    header = ("# ForeverScribe config (written by `foreverscribe setup` %s). Not part of the repository.\n"
              "# Every key is described in config.example.toml." % __version__)
    if a.print:
        print(C.dump_toml(d, header))
        return 0
    C.write(d, path, header)
    _p("Wrote %s (mode %s)." % (path, mode))
    if mode == "http":
        _p("Next: start the receiver (`foreverscribe receiver`), then `foreverscribe pair` for the game computer.")
    elif mode == "relay":
        _p("Next: `foreverscribe relay pair` (prints the code for the game computer), then keep "
           "`foreverscribe relay sync` running (`foreverscribe relay launchagent --write` on a Mac).")
    elif mode == "folder":
        _p("Next: install the game-side kit with --folder pointing at the same synced folder on that computer.")
    else:
        _p("Next: install the addon (installers/macos/install.sh --addon-only, or installers\\windows\\install.ps1 -AddonOnly), "
           "log in, /reload, then `foreverscribe summary`.")
    return 0


# ---------------------------------------------------------------- pair
def _receiver_url(cfg):
    r = cfg.section("receiver")
    if r.get("public_url"):
        return r["public_url"].rstrip("/")
    bind = r.get("bind") or "127.0.0.1"
    if bind in ("0.0.0.0", "::"):
        return ""
    return "http://%s:%s" % (bind, r.get("port") or 8766)


def keys_file(cfg):
    r = cfg.section("receiver")
    return C._expand(r.get("keys_file") or "") or os.path.join(cfg.data_dir, "receiver-keys.json")


def cmd_pair(argv):
    ap = argparse.ArgumentParser(prog="foreverscribe pair", description="create a pairing key for one game computer")
    ap.add_argument("--name", default="game-pc", help="label for this game computer")
    ap.add_argument("--url", help="receiver URL as the game computer will reach it (default: [receiver] public_url or bind:port)")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--revoke", metavar="KEY_ID")
    ap.add_argument("--code-only", action="store_true", help="print only the pairing code")
    a = ap.parse_args(argv)
    cfg = C.load()
    kf = keys_file(cfg)
    if a.list:
        keys = auth.load_keys(kf)
        for kid, e in sorted(keys.items()):
            _p("%s  %-16s created %s%s" % (kid, e.get("name"), e.get("created"), "  REVOKED" if e.get("revoked") else ""))
        if not keys:
            _p("no pairing keys yet")
        return 0
    if a.revoke:
        ok = auth.revoke_key(kf, a.revoke)
        _p("revoked %s" % a.revoke if ok else "no such key %s" % a.revoke)
        return 0 if ok else 1
    url = (a.url or _receiver_url(cfg)).rstrip("/")
    if not url:
        _p("Which URL will the game computer use? Pass --url http://<this computer's LAN/Tailscale IP>:8766 "
           "(or your tunnel's https URL), or set [receiver] public_url.")
        return 2
    kid, key = auth.add_key(kf, a.name)
    code = auth.encode_pairing(url, kid, key)
    if a.code_only:
        print(code)
        return 0
    _p("Pairing key %s created for %r (stored in %s)." % (kid, a.name, kf))
    _p("On the game computer, run the installer with this code (it is a secret: don't post it):\n")
    _p("  macOS:   ./install.sh --pair %s" % code)
    _p("  Windows: powershell -ExecutionPolicy Bypass -File .\\install.ps1 -Pair %s\n" % code)
    _p("The receiver picks the key up immediately; no restart needed. Revoke: foreverscribe pair --revoke %s" % kid)
    return 0


# ---------------------------------------------------------------- receiver
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
		<string>receiver</string>
		<string>run</string>
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


def cmd_receiver(argv):
    if any(a in ("-h", "--help", "help") for a in argv[:1]):
        _p("usage: foreverscribe receiver [run|health|launchagent [--write] [--label L]]\n"
           "  run          serve pushes (default; address and port from [receiver] in config.toml)\n"
           "  health       check the configured receiver URL\n"
           "  launchagent  print (or --write) a macOS LaunchAgent that keeps the receiver running")
        return 0
    sub = argv[0] if argv and not argv[0].startswith("-") else "run"
    rest = argv[1:] if argv and not argv[0].startswith("-") else argv
    cfg = C.load()
    if sub == "run":
        from . import receiver
        receiver.serve(cfg)
        return 0
    if sub == "health":
        url = _receiver_url(cfg) or "http://127.0.0.1:%s" % (cfg.section("receiver").get("port") or 8766)
        try:
            with urllib.request.urlopen(url + "/v1/health", timeout=5) as r:
                _p("%s -> %s" % (url, r.read().decode()))
            return 0
        except Exception as e:
            _p("%s unreachable: %s" % (url, e))
            return 1
    if sub == "launchagent":
        ap = argparse.ArgumentParser(prog="foreverscribe receiver launchagent")
        ap.add_argument("--label", default="io.foreverscribe.receiver")
        ap.add_argument("--write", action="store_true", help="write ~/Library/LaunchAgents/<label>.plist")
        a = ap.parse_args(rest)
        body = LAUNCHAGENT.format(label=a.label, python=sys.executable, repo=REPO, config=cfg["_path"],
                                  log=os.path.join(cfg.data_dir, "receiver.log"))
        if not a.write:
            print(body)
            return 0
        dest = os.path.expanduser("~/Library/LaunchAgents/%s.plist" % a.label)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as fh:
            fh.write(body)
        _p("wrote %s\nload it once: launchctl bootstrap gui/$(id -u) %s" % (dest, dest))
        return 0
    _p(__doc__)
    return 2


# ---------------------------------------------------------------- doctor / config
def cmd_doctor(argv):
    cfg = C.load()
    ok = True
    _p("foreverscribe %s, Python %s on %s" % (__version__, platform.python_version(), sys.platform))
    _p("config: %s (%s)" % (cfg["_path"], "found" if cfg["_exists"] else "MISSING: run `foreverscribe setup`"))
    ok &= cfg["_exists"]
    mode = cfg.section("transport").get("mode") or "local"
    _p("mode: %s; data dir: %s" % (mode, cfg.data_dir))
    _p("database: %s (%s)" % (cfg.db, "exists" if os.path.exists(cfg.db) else "created on first query"))
    if mode == "local":
        wd = C.wow_dir(cfg)
        _p("WoW folder: %s" % (wd or "NOT FOUND: set [wow] dir"))
        ok &= bool(wd)
    found = 0
    for src in cfg.sources:
        n = len([1 for k, _ in store.discover([src], C.extra_sv_patterns(cfg))]) if os.path.exists(src) else 0
        found += n
        _p("  source %-60s %s" % (src, ("%d file(s)" % n) if os.path.exists(src) else "(not there yet)"))
    if not found:
        _p("No ForeverScribe.lua found yet: install the addon, log in, /reload (or log out) once.")
    if mode == "http":
        r = cfg.section("receiver")
        keys = [k for k in auth.load_keys(keys_file(cfg)).values() if not k.get("revoked")]
        _p("receiver: bind %s:%s, %d pairing key(s)%s%s" % (r.get("bind"), r.get("port"), len(keys),
                                                         ", allow_ips %s" % r["allow_ips"] if r.get("allow_ips") else "",
                                                         ", legacy unsigned %s" % r["legacy_unsigned_ips"] if r.get("legacy_unsigned_ips") else ""))
        rc = cmd_receiver(["health"])
        ok &= rc == 0
        if not keys and not r.get("legacy_unsigned_ips"):
            _p("No pairing keys: run `foreverscribe pair` for the game computer.")
    if mode == "relay":
        from . import relay
        s = relay.status(cfg)
        _p(relay.render_status(s))
        ok &= bool(s.get("health")) and s["paired"] and not s.get("channel_error")
    a = cfg.section("ah")
    _p("AH prices: %s" % ("on (%s)" % a.get("market") if a.get("enabled") and a.get("wowgg_key") else "off (see config.example.toml [ah])"))
    _p("OK" if ok else "Some checks need attention (above).")
    return 0 if ok else 1


def cmd_config(argv):
    sub = argv[0] if argv else "show"
    cfg = C.load()
    if sub == "path":
        print(cfg["_path"])
        return 0
    shown = {k: v for k, v in cfg.items() if not k.startswith("_")}
    a = dict(shown.get("ah") or {})
    if a.get("wowgg_key"):
        a["wowgg_key"] = "<set>"
    shown["ah"] = a
    rl = dict(shown.get("relay") or {})
    if rl.get("create_secret"):
        rl["create_secret"] = "<set>"
    shown["relay"] = rl
    shown["resolved"] = {"config": cfg["_path"], "exists": cfg["_exists"], "data_dir": cfg.data_dir, "db": cfg.db,
                         "sources": cfg.sources, "wow_dir": C.wow_dir(cfg)}
    print(json.dumps(shown, indent=2))
    return 0


def main(cmd, argv):
    fn = {"setup": cmd_setup, "pair": cmd_pair, "receiver": cmd_receiver, "doctor": cmd_doctor, "config": cmd_config}.get(cmd)
    if not fn:
        _p(__doc__)
        return 2
    return fn(argv)
