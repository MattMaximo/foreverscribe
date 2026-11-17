"""End-to-end encryption for the hosted relay (`relay` transport). Standard library only.

Why AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC). Every party must implement the same envelope without extra
software: the macOS sync agent with the `openssl` and `gzip` command-line tools, the Windows sync agent with .NET
(PowerShell 5.1), and this package with nothing but the Python standard library. CBC with PKCS#7 padding is built
into both `openssl enc` and .NET's `Aes` class (CTR is not in .NET and would need a per-byte loop in PowerShell).
The MAC covers everything and is checked (constant time) before anything is decrypted, so padding errors are never
observable; this is the construction Fernet uses. Python has no AES in its standard library, so AES (FIPS-197) is
implemented below and checked against the FIPS-197 / SP 800-38A vectors and the `openssl` CLI in the tests.

Keys. A pairing has one 256-bit master secret K (43 base64url characters, the `k` in the fs2 code). It never reaches
the relay. Text strings are used as HMAC keys so the bash side can pass them to `openssl dgst -hmac`:
  enc_key = HMAC-SHA256(K, "fs2 enc")                      32 bytes, the AES-256 key
  mac_key = hex(HMAC-SHA256(K, "fs2 mac"))                 64 hex characters, used as an HMAC key string
  blob id = hex(HMAC-SHA256(mac_key, "fs2 name|" + logical name))[:32]    the only name the relay sees

Envelope (what the relay stores):
  header = "FS2E1" + %012d unix time + 32 hex characters of IV        (49 ASCII bytes)
  ct     = AES-256-CBC(enc_key, IV, PKCS#7(plaintext))
  tag    = hex(HMAC-SHA256(mac_key, "fs2|" + channel + "|" + blob id + "\\n" + header + ct))   (64 ASCII bytes)
  blob   = header + ct + tag
  plaintext = logical name + "\\n" + gzip(file)

The logical name (e.g. `sv/<account>/ForeverScribe.lua`, `route`, `prices`) is inside the ciphertext, so the relay
sees neither account nor character names. The tag binds a blob to its channel and blob id, so the relay can't swap
files between names or channels; the receiving side also checks that the blob id matches the logical name inside
and skips blobs older than the last one it accepted for that name.
"""

import base64
import gzip
import hashlib
import hmac
import io
import json
import os
import re
import time
import zlib

MAGIC = b"FS2E1"
MAX_PLAIN = 64 * 1024 * 1024  # a decompressed file larger than this is refused (gzip bomb)
HEADER_LEN = 5 + 12 + 32
TAG_LEN = 64
PREFIX = "fs2."

# ---------------------------------------------------------------- AES (FIPS-197), table based


def _xtime(a):
    a <<= 1
    return (a ^ 0x11B) & 0xFF if a & 0x100 else a


def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xtime(a)
        b >>= 1
    return r


def _build_tables():
    sbox = [0] * 256
    inv = [0] * 256
    p = q = 1
    while True:  # walk the multiplicative group with generator 3 to get inverses, then the affine map
        p = p ^ _xtime(p)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1 | q >> 7) & 0xFF) ^ ((q << 2 | q >> 6) & 0xFF) ^ ((q << 3 | q >> 5) & 0xFF) ^ ((q << 4 | q >> 4) & 0xFF)
        sbox[p] = x ^ 0x63
        if p == 1:
            break
    sbox[0] = 0x63
    for i, v in enumerate(sbox):
        inv[v] = i
    te = [[0] * 256 for _ in range(4)]
    td = [[0] * 256 for _ in range(4)]
    for i in range(256):
        s = sbox[i]
        w = (_mul(s, 2) << 24) | (s << 16) | (s << 8) | _mul(s, 3)
        si = inv[i]
        v = (_mul(si, 14) << 24) | (_mul(si, 9) << 16) | (_mul(si, 13) << 8) | _mul(si, 11)
        for k in range(4):
            te[k][i] = ((w >> (8 * k)) | (w << (32 - 8 * k))) & 0xFFFFFFFF
            td[k][i] = ((v >> (8 * k)) | (v << (32 - 8 * k))) & 0xFFFFFFFF
    return sbox, inv, te, td


SBOX, INV_SBOX, TE, TD = _build_tables()
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


class AES:
    """AES-128/192/256 block cipher (encrypt and decrypt one 16-byte block)."""

    def __init__(self, key):
        if len(key) not in (16, 24, 32):
            raise ValueError("AES key must be 16, 24 or 32 bytes")
        nk = len(key) // 4
        self.rounds = nk + 6
        w = [int.from_bytes(key[4 * i:4 * i + 4], "big") for i in range(nk)]
        for i in range(nk, 4 * (self.rounds + 1)):
            t = w[i - 1]
            if i % nk == 0:
                t = ((t << 8) | (t >> 24)) & 0xFFFFFFFF
                t = (SBOX[t >> 24] << 24) | (SBOX[(t >> 16) & 255] << 16) | (SBOX[(t >> 8) & 255] << 8) | SBOX[t & 255]
                t ^= _RCON[i // nk - 1] << 24
            elif nk > 6 and i % nk == 4:
                t = (SBOX[t >> 24] << 24) | (SBOX[(t >> 16) & 255] << 16) | (SBOX[(t >> 8) & 255] << 8) | SBOX[t & 255]
            w.append(w[i - nk] ^ t)
        self.ek = w
        # decryption round keys: reversed, InvMixColumns applied to the middle rounds
        dk = []
        for r in range(self.rounds, -1, -1):
            rk = w[4 * r:4 * r + 4]
            if 0 < r < self.rounds:
                rk = [TD[0][SBOX[x >> 24]] ^ TD[1][SBOX[(x >> 16) & 255]] ^ TD[2][SBOX[(x >> 8) & 255]] ^ TD[3][SBOX[x & 255]]
                      for x in rk]
            dk += rk
        self.dk = dk

    def encrypt_words(self, s0, s1, s2, s3):
        k = self.ek
        T0, T1, T2, T3 = TE
        s0 ^= k[0]
        s1 ^= k[1]
        s2 ^= k[2]
        s3 ^= k[3]
        i = 4
        for _ in range(self.rounds - 1):
            t0 = T0[s0 >> 24] ^ T1[(s1 >> 16) & 255] ^ T2[(s2 >> 8) & 255] ^ T3[s3 & 255] ^ k[i]
            t1 = T0[s1 >> 24] ^ T1[(s2 >> 16) & 255] ^ T2[(s3 >> 8) & 255] ^ T3[s0 & 255] ^ k[i + 1]
            t2 = T0[s2 >> 24] ^ T1[(s3 >> 16) & 255] ^ T2[(s0 >> 8) & 255] ^ T3[s1 & 255] ^ k[i + 2]
            t3 = T0[s3 >> 24] ^ T1[(s0 >> 16) & 255] ^ T2[(s1 >> 8) & 255] ^ T3[s2 & 255] ^ k[i + 3]
            s0, s1, s2, s3 = t0, t1, t2, t3
            i += 4
        S = SBOX
        return ((S[s0 >> 24] << 24 | S[(s1 >> 16) & 255] << 16 | S[(s2 >> 8) & 255] << 8 | S[s3 & 255]) ^ k[i],
                (S[s1 >> 24] << 24 | S[(s2 >> 16) & 255] << 16 | S[(s3 >> 8) & 255] << 8 | S[s0 & 255]) ^ k[i + 1],
                (S[s2 >> 24] << 24 | S[(s3 >> 16) & 255] << 16 | S[(s0 >> 8) & 255] << 8 | S[s1 & 255]) ^ k[i + 2],
                (S[s3 >> 24] << 24 | S[(s0 >> 16) & 255] << 16 | S[(s1 >> 8) & 255] << 8 | S[s2 & 255]) ^ k[i + 3])

    def decrypt_words(self, s0, s1, s2, s3):
        k = self.dk
        T0, T1, T2, T3 = TD
        s0 ^= k[0]
        s1 ^= k[1]
        s2 ^= k[2]
        s3 ^= k[3]
        i = 4
        for _ in range(self.rounds - 1):
            t0 = T0[s0 >> 24] ^ T1[(s3 >> 16) & 255] ^ T2[(s2 >> 8) & 255] ^ T3[s1 & 255] ^ k[i]
            t1 = T0[s1 >> 24] ^ T1[(s0 >> 16) & 255] ^ T2[(s3 >> 8) & 255] ^ T3[s2 & 255] ^ k[i + 1]
            t2 = T0[s2 >> 24] ^ T1[(s1 >> 16) & 255] ^ T2[(s0 >> 8) & 255] ^ T3[s3 & 255] ^ k[i + 2]
            t3 = T0[s3 >> 24] ^ T1[(s2 >> 16) & 255] ^ T2[(s1 >> 8) & 255] ^ T3[s0 & 255] ^ k[i + 3]
            s0, s1, s2, s3 = t0, t1, t2, t3
            i += 4
        S = INV_SBOX
        return ((S[s0 >> 24] << 24 | S[(s3 >> 16) & 255] << 16 | S[(s2 >> 8) & 255] << 8 | S[s1 & 255]) ^ k[i],
                (S[s1 >> 24] << 24 | S[(s0 >> 16) & 255] << 16 | S[(s3 >> 8) & 255] << 8 | S[s2 & 255]) ^ k[i + 1],
                (S[s2 >> 24] << 24 | S[(s1 >> 16) & 255] << 16 | S[(s0 >> 8) & 255] << 8 | S[s3 & 255]) ^ k[i + 2],
                (S[s3 >> 24] << 24 | S[(s2 >> 16) & 255] << 16 | S[(s1 >> 8) & 255] << 8 | S[s0 & 255]) ^ k[i + 3])

    def encrypt_block(self, b):
        w = self.encrypt_words(*[int.from_bytes(b[i:i + 4], "big") for i in (0, 4, 8, 12)])
        return b"".join(x.to_bytes(4, "big") for x in w)

    def decrypt_block(self, b):
        w = self.decrypt_words(*[int.from_bytes(b[i:i + 4], "big") for i in (0, 4, 8, 12)])
        return b"".join(x.to_bytes(4, "big") for x in w)


def _words(data):
    import struct
    return struct.unpack(">%dI" % (len(data) // 4), data)


def cbc_encrypt(key, iv, plaintext):
    """AES-CBC with PKCS#7 padding (the same as `openssl enc -aes-256-cbc` and .NET's Aes in CBC/PKCS7)."""
    import struct
    if len(iv) != 16:
        raise ValueError("IV must be 16 bytes")
    pad = 16 - len(plaintext) % 16
    data = plaintext + bytes([pad]) * pad
    a = AES(key)
    w = _words(data)
    c0, c1, c2, c3 = _words(iv)
    out = []
    enc = a.encrypt_words
    for i in range(0, len(w), 4):
        c0, c1, c2, c3 = enc(w[i] ^ c0, w[i + 1] ^ c1, w[i + 2] ^ c2, w[i + 3] ^ c3)
        out += (c0, c1, c2, c3)
    return struct.pack(">%dI" % len(out), *out)


def cbc_decrypt(key, iv, ciphertext):
    import struct
    if len(iv) != 16 or not ciphertext or len(ciphertext) % 16:
        raise ValueError("bad ciphertext length")
    a = AES(key)
    w = _words(ciphertext)
    p0, p1, p2, p3 = _words(iv)
    out = []
    dec = a.decrypt_words
    for i in range(0, len(w), 4):
        c = w[i:i + 4]
        d0, d1, d2, d3 = dec(*c)
        out += (d0 ^ p0, d1 ^ p1, d2 ^ p2, d3 ^ p3)
        p0, p1, p2, p3 = c
    data = struct.pack(">%dI" % len(out), *out)
    pad = data[-1]
    if not 1 <= pad <= 16 or data[-pad:] != bytes([pad]) * pad:
        raise ValueError("bad padding")
    return data[:-pad]


# ---------------------------------------------------------------- keys, ids, envelope
def new_master():
    return base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")


def enc_key(master):
    return hmac.new(master.encode("utf-8"), b"fs2 enc", hashlib.sha256).digest()


def mac_key(master):
    return hmac.new(master.encode("utf-8"), b"fs2 mac", hashlib.sha256).hexdigest()


def blob_id(master, logical):
    return hmac.new(mac_key(master).encode(), ("fs2 name|" + logical).encode("utf-8"), hashlib.sha256).hexdigest()[:32]


def _tag(master, channel, bid, header, ct):
    h = hmac.new(mac_key(master).encode(), ("fs2|%s|%s\n" % (channel, bid)).encode(), hashlib.sha256)
    h.update(header)
    h.update(ct)
    return h.hexdigest().encode()


class OpenError(ValueError):
    pass


def seal(master, channel, logical, data, now=None, iv=None, compress=True):
    """Encrypt one file for the relay. Returns (blob id, envelope bytes)."""
    bid = blob_id(master, logical)
    body = gzip.compress(data, mtime=0) if compress else data
    plain = logical.encode("utf-8") + b"\n" + body
    iv = iv or os.urandom(16)
    header = MAGIC + ("%012d" % int(now if now is not None else time.time())).encode() + iv.hex().encode()
    ct = cbc_encrypt(enc_key(master), iv, plain)
    return bid, header + ct + _tag(master, channel, bid, header, ct)


def open_blob(master, channel, bid, blob):
    """Verify and decrypt one envelope. Returns (logical name, file bytes, unix time). Raises OpenError."""
    if len(blob) < HEADER_LEN + 16 + TAG_LEN or not blob.startswith(MAGIC):
        raise OpenError("not a ForeverScribe relay envelope")
    header, ct, tag = blob[:HEADER_LEN], blob[HEADER_LEN:-TAG_LEN], blob[-TAG_LEN:]
    if not hmac.compare_digest(_tag(master, channel, bid, header, ct), tag.lower()):
        raise OpenError("authentication failed (wrong key, wrong channel, or the blob was changed)")
    try:
        ts = int(header[5:17])
        iv = bytes.fromhex(header[17:49].decode())
        plain = cbc_decrypt(enc_key(master), iv, ct)
    except ValueError as e:
        raise OpenError("cannot decrypt: %s" % e)
    nl = plain.find(b"\n")
    if nl < 1:
        raise OpenError("missing file name")
    logical = plain[:nl].decode("utf-8", "replace")
    if blob_id(master, logical) != bid:
        raise OpenError("blob id does not match its file name")
    try:
        data = gzip.GzipFile(fileobj=io.BytesIO(plain[nl + 1:])).read(MAX_PLAIN + 1)
    except (OSError, EOFError, zlib.error) as e:
        raise OpenError("bad gzip: %s" % e)
    if len(data) > MAX_PLAIN:
        raise OpenError("file too big once decompressed")
    return logical, data, ts


# ---------------------------------------------------------------- the fs2 pairing code (game side)
def encode_pairing(url, channel, token, master):
    raw = json.dumps({"v": 2, "u": url, "c": channel, "t": token, "k": master}, separators=(",", ":")).encode()
    return PREFIX + base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_pairing(code):
    code = (code or "").strip()
    if not code.startswith(PREFIX):
        raise ValueError("not a ForeverScribe relay pairing code (should start with %s)" % PREFIX)
    b = code[len(PREFIX):]
    b += "=" * (-len(b) % 4)
    d = json.loads(base64.urlsafe_b64decode(b.encode()).decode())
    if not all(d.get(k) for k in ("u", "c", "t", "k")):
        raise ValueError("pairing code is incomplete")
    if not re.match(r"^[0-9a-f]{32}$", d["c"]):
        raise ValueError("pairing code has a bad channel id")
    return {"url": d["u"], "channel": d["c"], "token": d["t"], "key": d["k"]}
