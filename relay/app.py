"""ForeverScribe relay: a small encrypted mailbox so a game computer and an agent computer on different networks can
sync without Tailscale, tunnels or port forwarding. Both sides connect out to it over HTTPS.

The relay never sees a file, a file name, an account or a character: clients encrypt end to end
(foreverscribe/relaycrypto.py) and name each blob by an HMAC. It stores the latest blob per name for a short time.

  GET    /v1/health                                   {"ok", "service", "version"}
  POST   /v1/channels                                 new channel: {"channel", "game_token", "agent_token", "limits"}
                                                      (needs X-FS-Relay-Secret when RELAY_CREATE_SECRET is set)
  GET    /v1/ch/<id>                                  channel status (either token)
  DELETE /v1/ch/<id>                                  unpair: drop the channel's blobs, refuse its tokens (agent token)
  PUT    /v1/ch/<id>/files/<up|down>/<blob id>        store a blob (game token -> up/, agent token -> down/)
  GET    /v1/ch/<id>/files/<up|down>/<blob id>        fetch a blob (agent token <- up/, game token <- down/)
  GET    /v1/ch/<id>/events?since=<seq>&wait=<s>      blobs the caller may read with seq > since; waits up to
                                                      `wait` seconds (max 25) for one to arrive (long poll)
Auth: "Authorization: Bearer <token>". A token is an HMAC of the channel id under RELAY_SECRET, so the relay
stores no credentials and channels survive a redeploy (as long as RELAY_SECRET stays the same).

It is a mailbox, not storage: blobs live on the instance's local disk (ephemeral on App Platform). A redeploy or
restart drops blobs nobody fetched yet; the game side sends again on its next save and the agent side re-sends the
route and prices. Sequence numbers start from the clock, so clients keep working across restarts. Run exactly one
instance (blobs are on its local disk). Revoking: `relay unpair` deletes the channel's blobs and refuses its
tokens; that refusal list is on local disk too, so after a redeploy a revoked game token could again upload into a
mailbox nobody reads (the agent side has deleted its key). Changing RELAY_SECRET revokes every channel at once.

Settings (environment): RELAY_SECRET (signs tokens; set a long random value; without one a random secret is kept in
the data dir and channels last until the disk goes), RELAY_CREATE_SECRET (optional invite code: required to create
channels when set), RELAY_DATA_DIR (default ./relay-data), RELAY_MAX_BLOB_MB 8, RELAY_MAX_FILES 64 (per channel), RELAY_TTL_DAYS 7 (blob life),
RELAY_IDLE_DAYS 30 (an unused channel is dropped), RELAY_MAX_TOTAL_MB 1024, RELAY_MAX_CHANNELS 500,
RELAY_RATE_PER_MIN 240 (requests per token), RELAY_CREATE_PER_HOUR 20 (per client address),
RELAY_DAILY_MB 2048 (bytes in + out per channel per day), RELAY_CHANNEL_MB 128 (stored per channel),
RELAY_MAX_UPLOADS 8 (uploads at once), PORT 8080.
Logs carry only the first 8 characters of a channel id, the direction and sizes; never tokens or contents.
"""
import asyncio
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import time

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse

VERSION = "0.9.0"


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


class Limits:
    def __init__(self):
        self.data_dir = os.path.abspath(os.environ.get("RELAY_DATA_DIR") or "relay-data")
        self.secret = os.environ.get("RELAY_SECRET") or ""
        self.create_secret = os.environ.get("RELAY_CREATE_SECRET") or ""
        self.max_blob = _env_int("RELAY_MAX_BLOB_MB", 8) * 1024 * 1024
        self.max_files = _env_int("RELAY_MAX_FILES", 64)
        self.ttl = _env_int("RELAY_TTL_DAYS", 7) * 86400
        self.idle = _env_int("RELAY_IDLE_DAYS", 30) * 86400
        self.max_total = _env_int("RELAY_MAX_TOTAL_MB", 1024) * 1024 * 1024
        self.max_channels = _env_int("RELAY_MAX_CHANNELS", 500)
        self.rate = _env_int("RELAY_RATE_PER_MIN", 240)
        self.create_rate = _env_int("RELAY_CREATE_PER_HOUR", 20)
        self.daily = _env_int("RELAY_DAILY_MB", 2048) * 1024 * 1024
        self.channel_bytes = _env_int("RELAY_CHANNEL_MB", 128) * 1024 * 1024
        self.uploads = _env_int("RELAY_MAX_UPLOADS", 8)
        self.max_wait = 25

    def public(self):
        return {"max_blob_bytes": self.max_blob, "max_files": self.max_files, "ttl_seconds": self.ttl,
                "idle_seconds": self.idle, "daily_bytes": self.daily}


CH_RE = re.compile(r"^[0-9a-f]{32}$")
BLOB_RE = re.compile(r"^[0-9a-f]{32}$")
ROLE_WRITES = {"game": "up", "agent": "down"}
ROLE_READS = {"game": "down", "agent": "up"}
OTHER = {"game": "agent", "agent": "game"}


def log(msg):
    print("%s relay %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)


def token_for(secret, cid, role):
    mac = hmac.new(secret.encode("utf-8"), ("fs relay token|%s|%s" % (role, cid)).encode(), hashlib.sha256).digest()
    return {"game": "fsg_", "agent": "fsa_"}[role] + base64.urlsafe_b64encode(mac).decode().rstrip("=")


class Bucket:
    """Token bucket: `rate` requests per `per` seconds."""

    def __init__(self, rate, per):
        self.rate, self.per = float(rate), float(per)
        self.tokens, self.t = float(rate), time.time()

    def take(self):
        now = time.time()
        self.tokens = min(self.rate, self.tokens + (now - self.t) * self.rate / self.per)
        self.t = now
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False


class Store:
    """Channels in memory, mirrored to <data_dir>/<channel>/{meta.json, blobs}. Single event loop: no locks needed."""

    def __init__(self, L):
        self.L = L
        self.ch = {}
        self.cond = {}
        self.buckets = {}
        self.create_buckets = {}
        os.makedirs(L.data_dir, exist_ok=True)
        if not L.secret:
            p = os.path.join(L.data_dir, "relay-secret")
            if not os.path.isfile(p):
                with open(p, "w") as f:
                    f.write(secrets.token_urlsafe(32))
            with open(p) as f:
                L.secret = f.read().strip()
            log("RELAY_SECRET not set: using a random one in the data dir; channels end when this disk does")
        self.revoked = set((self._load(os.path.join(L.data_dir, "revoked.json")) or []))
        for cid in os.listdir(L.data_dir):
            p = os.path.join(L.data_dir, cid, "meta.json")
            if CH_RE.match(cid) and os.path.isfile(p):
                try:
                    with open(p, encoding="utf-8") as f:
                        self.ch[cid] = json.load(f)
                except (OSError, ValueError):
                    shutil.rmtree(os.path.join(L.data_dir, cid), ignore_errors=True)
        self.sweep()

    # ---- persistence
    @staticmethod
    def _load(p):
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def revoke(self, cid):
        self.revoked.add(cid)
        tmp = os.path.join(self.L.data_dir, "revoked.json.tmp")
        with open(tmp, "w") as f:
            json.dump(sorted(self.revoked), f)
        os.replace(tmp, os.path.join(self.L.data_dir, "revoked.json"))

    def new_channel(self, cid):
        now = int(time.time())
        self.ch[cid] = {"created": now, "seq": int(time.time() * 1000), "files": {}, "seen": {}, "usage": {}}
        self.save(cid)
        return self.ch[cid]

    def _dir(self, cid):
        return os.path.join(self.L.data_dir, cid)

    def save(self, cid):
        d = self._dir(cid)
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, "meta.json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.ch[cid], f)
        os.replace(tmp, os.path.join(d, "meta.json"))

    def channel_bytes(self, c):
        return sum(f["size"] for f in c["files"].values())

    def total_bytes(self):
        return sum(f["size"] for c in self.ch.values() for f in c["files"].values())

    def drop(self, cid, why):
        self.ch.pop(cid, None)
        shutil.rmtree(self._dir(cid), ignore_errors=True)
        c = self.cond.pop(cid, None)
        log("ch %s dropped (%s)" % (cid[:8], why))
        return c

    def sweep(self):
        now = time.time()
        for cid in list(self.ch):
            c = self.ch[cid]
            if now - max(c.get("seen", {}).values() or [c["created"]]) > self.L.idle:
                self.drop(cid, "idle")
                continue
            gone = [n for n, f in c["files"].items() if now - f["t"] > self.L.ttl]
            for n in gone:
                c["files"].pop(n)
                try:
                    os.remove(os.path.join(self._dir(cid), n.replace("/", "-")))
                except OSError:
                    pass
            if gone:
                self.save(cid)

    # ---- auth / limits
    def role(self, cid, request):
        """(channel record, role) for a valid token; the record is (re)made on first use after a restart."""
        h = request.headers.get("authorization") or ""
        tok = h[7:].strip() if h.lower().startswith("bearer ") else ""
        if not tok or cid in self.revoked:
            return None, None
        for role in ("game", "agent"):
            if hmac.compare_digest(tok.encode(), token_for(self.L.secret, cid, role).encode()):
                c = self.ch.get(cid)
                if c is None:
                    if len(self.ch) >= self.L.max_channels:
                        self.sweep()
                    if len(self.ch) >= self.L.max_channels:
                        return None, "full"
                    c = self.new_channel(cid)
                return c, role
        return None, None

    def allow(self, key):
        b = self.buckets.get(key)
        if not b:
            b = self.buckets[key] = Bucket(self.L.rate, 60)
            if len(self.buckets) > 10000:
                self.buckets.clear()
        return b.take()

    def allow_create(self, ip):
        b = self.create_buckets.get(ip)
        if not b:
            b = self.create_buckets[ip] = Bucket(self.L.create_rate, 3600)
            if len(self.create_buckets) > 10000:
                self.create_buckets.clear()
        return b.take()

    def spend(self, c, n):
        day = time.strftime("%Y-%m-%d", time.gmtime())
        u = c.setdefault("usage", {})
        if u.get("day") != day:
            u.clear()
            u["day"], u["bytes"] = day, 0
        if u["bytes"] + n > self.L.daily:
            return False
        u["bytes"] += n
        return True

    def condition(self, cid):
        c = self.cond.get(cid)
        if c is None:
            c = self.cond[cid] = asyncio.Condition()
        return c


def client_ip(request):
    # App Platform's edge sets do-connecting-ip (a client can't override it there). X-Forwarded-For is never trusted.
    ip = request.headers.get("do-connecting-ip") if os.environ.get("RELAY_TRUST_DO_IP", "1") == "1" else ""
    return ip or (request.client.host if request.client else "?")


def err(code, msg, **extra):
    return JSONResponse(dict(error=msg, **extra), status_code=code)


def create_app(limits=None):
    L = limits or Limits()
    S = Store(L)
    upload_slots = asyncio.Semaphore(max(1, L.uploads))
    app = FastAPI(title="ForeverScribe relay", version=VERSION, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.store = S

    async def sweeper():
        while True:
            await asyncio.sleep(600)
            try:
                S.sweep()
            except Exception as e:  # never take the relay down
                log("sweep failed: %s" % e)

    @app.on_event("startup")
    async def _start():
        asyncio.get_event_loop().create_task(sweeper())
        log("ForeverScribe relay %s up: %d channels, data %s, channel creation %s" % (
            VERSION, len(S.ch), L.data_dir, "needs the create secret" if L.create_secret else "open"))

    @app.middleware("http")
    async def headers(request, call_next):
        resp = await call_next(request)
        resp.headers["Cache-Control"] = "no-store"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        return resp

    @app.get("/v1/health")
    async def health():
        return {"ok": True, "service": "foreverscribe-relay", "version": VERSION}

    @app.post("/v1/channels")
    async def create(request: Request):
        if "change-me" in (L.create_secret, L.secret):
            return err(503, "this relay isn't set up yet: give RELAY_SECRET and RELAY_CREATE_SECRET your own values "
                            "in its settings (docs/RELAY.md)")
        if L.create_secret and not hmac.compare_digest(request.headers.get("x-fs-relay-secret") or "", L.create_secret):
            return err(403, "this relay needs its create secret (foreverscribe relay pair --secret ...)")
        if not S.allow_create(client_ip(request)):
            return err(429, "too many new channels from this address; try again later")
        S.sweep()
        if len(S.ch) >= L.max_channels:
            return err(507, "relay is full (too many channels)")
        cid = secrets.token_hex(16)
        while cid in S.ch or cid in S.revoked:
            cid = secrets.token_hex(16)
        S.new_channel(cid)["seen"]["agent"] = int(time.time())
        S.save(cid)
        log("ch %s created" % cid[:8])
        return {"channel": cid, "game_token": token_for(L.secret, cid, "game"), "agent_token": token_for(L.secret, cid, "agent"),
                "limits": L.public(), "version": VERSION}

    def _auth(cid, request):
        if "change-me" in (L.create_secret, L.secret):
            return None, None, err(503, "this relay isn't set up yet (RELAY_SECRET / RELAY_CREATE_SECRET)")
        if not CH_RE.match(cid):
            return None, None, err(404, "no such channel")
        c, role = S.role(cid, request)
        if role == "full":
            return None, None, err(507, "relay is full (too many channels)")
        if c is None:
            return None, None, err(403, "bad token, or this channel was unpaired (pair again: foreverscribe relay pair --force)")
        if not S.allow(cid + role):
            return None, None, err(429, "slow down")
        c.setdefault("seen", {})[role] = int(time.time())
        return c, role, None

    @app.get("/v1/ch/{cid}")
    async def status(cid: str, request: Request):
        c, role, e = _auth(cid, request)
        if e:
            return e
        files = {n: {"seq": f["seq"], "size": f["size"], "t": f["t"], "got": f.get("got")} for n, f in c["files"].items()}
        return {"channel": cid, "role": role, "seq": c["seq"], "created": c["created"], "seen": c.get("seen", {}),
                "files": files, "usage": c.get("usage", {}), "limits": L.public(), "version": VERSION}

    @app.delete("/v1/ch/{cid}")
    async def unpair(cid: str, request: Request):
        c, role, e = _auth(cid, request)
        if e:
            return e
        if role != "agent":
            return err(403, "only the agent side can unpair")
        S.revoke(cid)
        cond = S.drop(cid, "unpaired")
        if cond:
            async with cond:
                cond.notify_all()
        return {"ok": True}

    @app.put("/v1/ch/{cid}/files/{box}/{bid}")
    async def put(cid: str, box: str, bid: str, request: Request):
        c, role, e = _auth(cid, request)
        if e:
            return e
        if box != ROLE_WRITES[role] or not BLOB_RE.match(bid):
            return err(403, "this token may only write %s/<blob id>" % ROLE_WRITES[role])
        name = "%s/%s" % (box, bid)
        try:
            declared = int(request.headers.get("content-length") or 0)
        except ValueError:
            declared = 0
        if declared > L.max_blob:
            return err(413, "blob too big (max %d bytes)" % L.max_blob)
        in_box = sum(1 for n_ in c["files"] if n_.startswith(box + "/"))
        if name not in c["files"] and in_box >= L.max_files:  # per box: uploads can't crowd out route/prices
            return err(507, "too many files in this channel (max %d)" % L.max_files)
        if upload_slots.locked():
            return err(503, "relay busy; try again shortly")
        d = S._dir(cid)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, name.replace("/", "-"))
        tmp = "%s.tmp.%s" % (path, secrets.token_hex(4))
        n = 0
        async with upload_slots:  # streamed to disk, a few uploads at a time: memory stays small
            try:
                with open(tmp, "wb") as f:
                    async for chunk in request.stream():
                        n += len(chunk)
                        if n > L.max_blob:
                            raise OverflowError
                        f.write(chunk)
            except OverflowError:
                os.remove(tmp)
                return err(413, "blob too big (max %d bytes)" % L.max_blob)
            except Exception:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
                raise
        if n == 0:
            os.remove(tmp)
            return err(400, "empty body")
        old = c["files"].get(name, {}).get("size", 0)
        if S.channel_bytes(c) - old + n > L.channel_bytes:
            os.remove(tmp)
            return err(507, "this channel holds too much (max %d bytes)" % L.channel_bytes)
        if S.total_bytes() - old + n > L.max_total:
            S.sweep()
            if S.total_bytes() - old + n > L.max_total:
                os.remove(tmp)
                return err(507, "relay storage is full; try again later")
        if not S.spend(c, n):
            os.remove(tmp)
            return err(429, "daily transfer limit for this channel reached")
        if cid not in S.ch:  # unpaired while uploading
            os.remove(tmp)
            return err(403, "this channel was unpaired")
        os.replace(tmp, path)
        c["seq"] += 1
        c["files"][name] = {"seq": c["seq"], "size": n, "t": int(time.time())}
        S.save(cid)
        log("ch %s put %s %d B seq %d" % (cid[:8], box, n, c["seq"]))
        cond = S.condition(cid)
        async with cond:
            cond.notify_all()
        return {"ok": True, "seq": c["seq"]}

    @app.get("/v1/ch/{cid}/files/{box}/{bid}")
    async def get(cid: str, box: str, bid: str, request: Request):
        c, role, e = _auth(cid, request)
        if e:
            return e
        if box != ROLE_READS[role] or not BLOB_RE.match(bid):
            return err(403, "this token may only read %s/<blob id>" % ROLE_READS[role])
        name = "%s/%s" % (box, bid)
        f = c["files"].get(name)
        if not f:
            return err(404, "no such blob")
        path = os.path.join(S._dir(cid), name.replace("/", "-"))
        if not os.path.isfile(path):
            c["files"].pop(name, None)
            S.save(cid)
            return err(404, "no such blob")
        if not S.spend(c, f["size"]):
            return err(429, "daily transfer limit for this channel reached")
        f["got"] = int(time.time())
        S.save(cid)
        log("ch %s get %s %d B" % (cid[:8], box, f["size"]))
        return FileResponse(path, media_type="application/octet-stream", headers={"X-FS-Seq": str(f["seq"])})

    @app.get("/v1/ch/{cid}/events")
    async def events(cid: str, request: Request, since: int = 0, wait: int = 0):
        c, role, e = _auth(cid, request)
        if e:
            return e
        box = ROLE_READS[role] + "/"
        wait = max(0, min(int(wait), L.max_wait))

        def newer():
            cur = S.ch.get(cid)
            if cur is None:
                return None
            return [{"name": n, "seq": f["seq"], "size": f["size"], "t": f["t"]}
                    for n, f in sorted(cur["files"].items(), key=lambda kv: kv[1]["seq"]) if n.startswith(box) and f["seq"] > since]

        got = newer()
        if got == [] and wait:
            cond = S.condition(cid)
            deadline = time.time() + wait
            async with cond:
                while got == [] and time.time() < deadline:
                    try:
                        await asyncio.wait_for(cond.wait(), timeout=max(0.05, deadline - time.time()))
                    except asyncio.TimeoutError:
                        pass
                    got = newer()
        if got is None:
            return err(403, "this channel was unpaired")
        cur = S.ch[cid]
        return {"seq": cur["seq"], "files": got, "peer_seen": cur.get("seen", {}).get(OTHER[role])}

    @app.exception_handler(404)
    async def nf(request, exc):
        return err(404, "not found")

    return app


app = create_app() if os.environ.get("RELAY_NO_AUTOAPP") != "1" else None


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=os.environ.get("HOST", "0.0.0.0"), port=_env_int("PORT", 8080), access_log=False,
                proxy_headers=False, limit_concurrency=200)
