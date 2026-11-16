"""ForeverScribe push receiver (agent side of the `http` transport).

The game-side sync agent POSTs a SavedVariables file here the moment WoW writes it (/reload,
logout, exit). The file is stored atomically under <data_dir>/push/Account/<acct>/SavedVariables/
and ingested at once, so the agent sees the new state within seconds.

  GET  /v1/health                       -> {"ok": true}
  POST /v1/auth-check                   -> checks the signature only, stores nothing
  POST /v1/sv/<account>                 -> ForeverScribe.lua
  POST /v1/sv/<account>/<file.lua>      -> ForeverScribe.lua or a file matching sync.extra_saved_variables
  POST /v1/route                        -> the route the agent wrote (`foreverscribe route write`), as the slot file;
                                           204 none, 304 when X-FS-Have names the current rev. Signed only (no legacy).
  POST /v1/prices                       -> the AH price file (`foreverscribe prices write`) for the tooltip; same
                                           204/304 rules. Each ask also refreshes the file in the background when it
                                           is older than 30 minutes (only with [ah] enabled).

Authentication: every push is signed with a per-install pairing key (see auth.py; create one
with `foreverscribe pair`). Optional extras in [receiver]: `allow_ips` (also require the
source address to be listed) and `legacy_unsigned_ips` (migration only: accept unsigned pushes
from these addresses, e.g. an older kit on a WireGuard/Tailscale peer).

Bind to a private interface (127.0.0.1, a LAN or Tailscale address) or put a user-run tunnel
in front of it; the signature protects the endpoint either way, but there is no TLS here.
"""

import fnmatch
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import __version__, auth, config as C, prices, routes, store

MAX_BYTES = 32 * 1024 * 1024
ACCT_RE = re.compile(r"^[A-Za-z0-9#_.\-]{1,64}$")
FILE_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,96}\.lua$")
LOCK = threading.Lock()


def log(msg):
    print("%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)


class Settings:
    def __init__(self, cfg):
        r = cfg.section("receiver")
        env = os.environ
        self.cfg = cfg
        self.data = env.get("FOREVERSCRIBE_DATA") or cfg.data_dir
        self.push_dir = os.path.join(self.data, "push", "Account")
        self.db = env.get("FOREVERSCRIBE_DB") or os.path.join(self.data, "forever.db")
        self.bind = env.get("FOREVERSCRIBE_BIND") or r.get("bind") or "127.0.0.1"
        self.port = int(env.get("FOREVERSCRIBE_PORT") or r.get("port") or 8766)
        self.allow_ips = set(r.get("allow_ips") or [])
        legacy = r.get("legacy_unsigned_ips") or []
        if env.get("FOREVERSCRIBE_ALLOW") is not None:  # v0.2 env name: unsigned allowlist
            legacy = [x.strip() for x in env["FOREVERSCRIBE_ALLOW"].split(",") if x.strip()]
        self.legacy = set(legacy)
        self.keys_file = C._expand(r.get("keys_file") or "") or os.path.join(self.data, "receiver-keys.json")
        self.max_skew = int(r.get("max_skew_seconds") or 600)
        self.extra = C.extra_sv_patterns(cfg)

    def keys(self):
        return auth.load_keys(self.keys_file)

    def file_allowed(self, name):
        return name == "ForeverScribe.lua" or any(fnmatch.fnmatch(name, p) for p in self.extra)


def make_handler(S):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ForeverScribe/" + __version__

        def log_message(self, format, *args):  # noqa: A002 - quiet default access log
            pass

        def _send(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/v1/health":
                return self._send(200, {"ok": True, "version": __version__})
            self._send(404, {"error": "not found"})

        def _read_body(self):
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                n = -1
            if n < 0 or n > MAX_BYTES:
                return None
            body = self.rfile.read(n) if n else b""
            return body if len(body) == n else None

        def _authorize(self, body):
            ip = self.client_address[0]
            if self.headers.get("X-FS-Sig"):
                ok, why = auth.verify(S.keys(), self.headers, "POST", self.path, body, max_skew=S.max_skew)
                if ok and (not S.allow_ips or ip in S.allow_ips or ip in S.legacy):
                    return True, "key " + why
                if ok:
                    return False, "address %s not in allow_ips" % ip
                return False, why
            if ip in S.legacy:
                return True, "legacy unsigned from %s" % ip
            return False, "unsigned"

        def do_POST(self):
            path = self.path
            if path == "/v1/auth-check":
                body = self._read_body()
                if body is None:
                    return self._send(413, {"error": "bad size"})
                ok, why = self._authorize(body)
                if not ok:
                    log("rejected auth-check from %s: %s" % (self.client_address[0], why))
                    return self._send(403, {"error": "forbidden", "reason": why})
                return self._send(200, {"ok": True, "auth": why, "version": __version__})
            if path == "/v1/route":
                return self._route()
            if path == "/v1/prices":
                return self._prices()
            m = re.match(r"^/v1/sv/([^/?]+)(?:/([^/?]+))?$", path)
            if not m:
                return self._send(404, {"error": "not found"})
            acct, fname = m.group(1), m.group(2) or "ForeverScribe.lua"
            body = self._read_body()
            if body is None or not body:
                return self._send(413, {"error": "bad size"})
            ok, why = self._authorize(body)
            if not ok:
                log("rejected push from %s: %s" % (self.client_address[0], why))
                return self._send(403, {"error": "forbidden", "reason": why})
            if not ACCT_RE.match(acct) or not FILE_RE.match(fname) or not S.file_allowed(fname):
                return self._send(400, {"error": "bad account or file name"})
            if not body.rstrip().endswith(b"}"):
                return self._send(400, {"error": "incomplete file"})
            t0 = time.time()
            dest_dir = os.path.join(S.push_dir, acct, "SavedVariables")
            os.makedirs(dest_dir, exist_ok=True)
            dest = os.path.join(dest_dir, fname)
            tmp = os.path.join(dest_dir, ".%s.tmp.%d" % (fname, os.getpid()))
            with open(tmp, "wb") as f:
                f.write(body)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, dest)
            try:
                with LOCK:
                    con = store.connect(S.db)
                    try:
                        if fname == "ForeverScribe.lua":
                            res = store.ingest_sv_file(con, dest)
                        else:
                            res = store.ingest_raw_file(con, dest)
                    finally:
                        con.close()
            except Exception as e:  # file is saved; normal query-time ingest will retry
                log("push %s/%s saved but ingest failed: %s" % (acct, fname, e))
                return self._send(202, {"saved": True, "ingested": False, "error": str(e)})
            ms = int((time.time() - t0) * 1000)
            log("push %s/%s (%s): %d bytes, %s, events_new=%s, %d ms" % (
                acct, fname, why, len(body), res.get("status"), res.get("events_new"), ms))
            self._send(200, {"saved": True, "ingested": True, "status": res.get("status"),
                             "events_new": res.get("events_new"), "ms": ms})

        def _route(self):
            """The game-side sync agent asks for the route the agent wrote (routes.py). Signed like a push; the answer is
            the slot file (data-only Lua) or 204 when none was written. Records the pickup for `route status`."""
            body = self._read_body()
            if body is None:
                return self._send(413, {"error": "bad size"})
            ok, why = self._authorize(body) if self.headers.get("X-FS-Sig") else (False, "unsigned (route fetches need a pairing key)")
            if not ok:
                log("rejected route fetch from %s: %s" % (self.client_address[0], why))
                return self._send(403, {"error": "forbidden", "reason": why})
            src = os.path.join(routes.route_dir(S.cfg), "Route.lua")
            try:
                with open(src, "rb") as f:
                    text = f.read()
            except OSError:
                self.send_response(204)
                self.end_headers()
                return
            m = re.search(rb'rev = "([\w.\-]+)"', text)
            rev = m.group(1).decode() if m else ""
            have = (self.headers.get("X-FS-Have") or "").strip()
            if rev and have == rev:
                self.send_response(304)
                self.end_headers()
                return
            try:
                p = os.path.join(routes.route_dir(S.cfg), "pickup.json")
                with open(p + ".tmp", "w") as f:
                    json.dump({"rev": rev, "at": int(time.time()), "by": why}, f)
                os.replace(p + ".tmp", p)
            except OSError:
                pass
            log("route %s fetched (%s)" % (rev or "?", why))
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("X-FS-Route-Rev", rev)
            self.send_header("Content-Length", str(len(text)))
            self.end_headers()
            self.wfile.write(text)

        def _prices(self):
            """The sync agent asks for the AH price file (prices.py). Signed like a route fetch."""
            body = self._read_body()
            if body is None:
                return self._send(413, {"error": "bad size"})
            ok, why = self._authorize(body) if self.headers.get("X-FS-Sig") else (False, "unsigned (price fetches need a pairing key)")
            if not ok:
                log("rejected price fetch from %s: %s" % (self.client_address[0], why))
                return self._send(403, {"error": "forbidden", "reason": why})
            try:
                prices.refresh_async(S.cfg, log=log)
            except Exception as e:  # never fail the fetch over a refresh problem
                log("prices: refresh not started: %s" % e)
            src = prices.receiver_copy(S.cfg)
            try:
                with open(src, "rb") as f:
                    text = f.read()
            except OSError:
                self.send_response(204)
                self.end_headers()
                return
            m = re.search(rb'\trev = "([\w.\-]+)"', text[:4096])
            rev = m.group(1).decode() if m else ""
            have = (self.headers.get("X-FS-Have") or "").strip()
            if rev and have == rev:
                self.send_response(304)
                self.end_headers()
                return
            try:
                p = os.path.join(prices.price_dir(S.cfg), "pickup.json")
                with open(p + ".tmp", "w") as f:
                    json.dump({"rev": rev, "at": int(time.time()), "by": why}, f)
                os.replace(p + ".tmp", p)
            except OSError:
                pass
            log("prices %s fetched (%s, %d bytes)" % (rev or "?", why, len(text)))
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("X-FS-Prices-Rev", rev)
            self.send_header("Content-Length", str(len(text)))
            self.end_headers()
            self.wfile.write(text)

    return Handler


def serve(cfg=None):
    cfg = cfg or C.load()
    S = Settings(cfg)
    srv = ThreadingHTTPServer((S.bind, S.port), make_handler(S))
    log("ForeverScribe %s receiver listening on %s:%d (keys %d, legacy unsigned %s, allow_ips %s)" % (
        __version__, S.bind, S.port, len([k for k in S.keys().values() if not k.get("revoked")]),
        ",".join(sorted(S.legacy)) or "off", ",".join(sorted(S.allow_ips)) or "any"))
    srv.serve_forever()


def main(argv=None):
    serve()


if __name__ == "__main__":
    import sys
    sys.exit("run it as: python -m foreverscribe receiver")
