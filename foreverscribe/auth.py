"""Pairing keys and request signing for the http transport.

A pairing key is a random secret shared by one game PC and this receiver. The game side never
sends the key: each push carries an HMAC-SHA256 signature over a timestamp, the method, the path
and the SHA-256 of the body. The same scheme is implemented in installers/macos/foreverscribe-sync.sh
(openssl) and installers/windows/foreverscribe-sync.ps1 (.NET).

  canonical = "fs1\\n" + <unix time> + "\\n" + <METHOD> + "\\n" + <path> + "\\n" + <sha256 hex of body>
  X-FS-Key: <key id>   X-FS-Time: <unix time>   X-FS-Sig: <hex hmac_sha256(key_utf8, canonical)>

Pairing code (what `foreverscribe pair` prints for the game-side installer):
  fs1.<base64url(json {"u": receiver url, "i": key id, "k": key})>
"""

import base64
import hashlib
import hmac
import json
import os
import secrets
import time

PREFIX = "fs1."


def new_key():
    return "fsk_" + secrets.token_urlsafe(32)


def new_key_id():
    return secrets.token_hex(4)


def canonical(ts, method, path, body_sha256):
    return "fs1\n%s\n%s\n%s\n%s" % (int(ts), method.upper(), path, body_sha256)


def sign(key, ts, method, path, body):
    digest = hashlib.sha256(body).hexdigest()
    return hmac.new(key.encode("utf-8"), canonical(ts, method, path, digest).encode("utf-8"), hashlib.sha256).hexdigest()


def headers(key_id, key, method, path, body, now=None):
    ts = int(now or time.time())
    return {"X-FS-Key": key_id, "X-FS-Time": str(ts), "X-FS-Sig": sign(key, ts, method, path, body)}


def verify(keys, hdrs, method, path, body, now=None, max_skew=600):
    """Return (ok, key_id or reason). `keys` maps id -> {"key": ...}."""
    kid = hdrs.get("X-FS-Key") or ""
    ts = hdrs.get("X-FS-Time") or ""
    sig = (hdrs.get("X-FS-Sig") or "").lower()
    if not kid or not ts or not sig:
        return False, "unsigned"
    entry = keys.get(kid)
    if not entry or entry.get("revoked"):
        return False, "unknown key"
    try:
        t = int(ts)
    except ValueError:
        return False, "bad time"
    if abs(int(now or time.time()) - t) > max_skew:
        return False, "clock skew (check the game PC's clock)"
    want = sign(entry["key"], t, method, path, body)
    if not hmac.compare_digest(want, sig):
        return False, "bad signature"
    return True, kid


def encode_pairing(url, key_id, key):
    raw = json.dumps({"u": url, "i": key_id, "k": key}, separators=(",", ":")).encode()
    return PREFIX + base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_pairing(code):
    code = (code or "").strip()
    if not code.startswith(PREFIX):
        raise ValueError("not a ForeverScribe pairing code (should start with %s)" % PREFIX)
    b = code[len(PREFIX):]
    b += "=" * (-len(b) % 4)
    d = json.loads(base64.urlsafe_b64decode(b.encode()).decode())
    if not d.get("u") or not d.get("i") or not d.get("k"):
        raise ValueError("pairing code is incomplete")
    return {"url": d["u"], "key_id": d["i"], "key": d["k"]}


# ---------------------------------------------------------------- key store (receiver side)
def load_keys(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        return d.get("keys") or {}
    except (OSError, ValueError):
        return {}


def save_keys(path, keys):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"keys": keys}, fh, indent=1, sort_keys=True)
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)


def add_key(path, name):
    keys = load_keys(path)
    kid = new_key_id()
    while kid in keys:
        kid = new_key_id()
    key = new_key()
    keys[kid] = {"key": key, "name": name, "created": int(time.time())}
    save_keys(path, keys)
    return kid, key


def revoke_key(path, kid):
    keys = load_keys(path)
    if kid not in keys:
        return False
    keys[kid]["revoked"] = int(time.time())
    save_keys(path, keys)
    return True
