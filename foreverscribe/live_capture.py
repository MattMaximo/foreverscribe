"""ForeverScribe live capture (optional, macOS; runs on the computer that plays WoW: Forever).

Reads the tiny pixel strip that the optional ForeverScribe_Live addon draws in
the top-left corner while `/scribe live on`, decodes it, and appends each new
event as one JSON line to a dated file in --out-dir (default: config
[sources] live_dir, else <data_dir>/live). Point it at a folder the agent side
reads (same computer, or a synced folder). Event ids make duplicates
impossible, and SavedVariables later back-fill anything the strip missed.

Read-only: it only takes screenshots of the game window's top-left corner. No
input, no memory reading, nothing is sent to the game.

Decoder and macOS capture approach adapted from wow-ai bridge/capture_mac.py
(https://github.com/chelinho139/wow-ai, Copyright (c) chelinho139, MIT License).

  live_capture.py                         run the capture loop
  live_capture.py --probe out.png         save one capture + decode result, exit
  live_capture.py --test-image strip.png  decode a PNG once, exit
Needs Screen Recording + Accessibility (System Events) permission for the
terminal/launchd job that runs it. Window must be windowed or borderless.
"""

import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile
import time
import zlib

RS, US = "\x1e", "\x1f"


def default_out():
    try:
        from . import config as C
    except ImportError:  # run as a plain script
        return os.path.join(os.path.expanduser("~"), ".local", "share", "foreverscribe", "live")
    cfg = C.load()
    return C._expand((cfg.section("sources").get("live_dir") or "")) or os.path.join(cfg.data_dir, "live")


class Geometry:
    def __init__(self, cell=4, cells=120, rows=24, xslack=8, yslack=80):
        self.cell, self.cells, self.rows = cell, cells, rows
        self.w, self.h = cells * cell, rows * cell
        self.xslack, self.yslack = xslack, yslack


# ---------------------------------------------------------------------------
# Decoder (same rules as wow-ai's capture scripts)
# ---------------------------------------------------------------------------

def cell_value(px, g, c, r, ox=0, oy=0):
    rr, gg, bb = px(ox + c * g.cell + g.cell // 2, oy + r * g.cell + g.cell // 2)
    return (4 if rr >= 128 else 0) + (2 if gg >= 128 else 0) + (1 if bb >= 128 else 0)


def has_magic(px, g, ox, oy):
    acc = 0
    for i in range(6):
        acc = (acc << 3) | cell_value(px, g, i, 0, ox, oy)
    return (acc >> 2) == 0xC71A


def decode(px, g, ox=0, oy=0):
    acc, nbits, out, needed = 0, 0, bytearray(), 6
    total = g.cells * g.rows
    for i in range(total):
        acc = (acc << 3) | cell_value(px, g, i % g.cells, i // g.cells, ox, oy)
        nbits += 3
        while nbits >= 8:
            out.append((acc >> (nbits - 8)) & 0xFF)
            nbits -= 8
            acc &= (1 << nbits) - 1
            if len(out) == 2 and (out[0] != 0xC7 or out[1] != 0x1A):
                return None
            if len(out) == 6:
                needed = 8 + out[4] * 256 + out[5]
                if needed > total * 3 // 8:
                    return {"error": "length"}
            if len(out) >= needed:
                break
        if len(out) >= needed:
            break
    if len(out) < needed:
        return {"error": "truncated"}
    length = out[4] * 256 + out[5]
    s1 = s2 = 0
    for k in range(2, 6 + length):
        s1 = (s1 + out[k]) % 255
        s2 = (s2 + s1) % 255
    if out[6 + length] != s1 or out[7 + length] != s2:
        return {"error": "checksum"}
    return {"id": out[2] * 256 + out[3], "text": bytes(out[6:6 + length]).decode("utf-8", errors="replace")}


def find_and_decode(px, width, height, g, hint=None):
    cands = [hint] if hint else []
    cands += [(dx, dy) for dy in range(g.yslack + 1) for dx in range(g.xslack + 1)]
    for ox, oy in cands:
        if ox + g.w > width or oy + g.h > height:
            continue
        if has_magic(px, g, ox, oy):
            return decode(px, g, ox, oy), (ox, oy)
    return None, hint


def parse_payload(text):
    """'FS1' US charKey (RS id US type US t US json)* -> (charKey, [event dicts])"""
    parts = text.split(RS)
    head = parts[0].split(US)
    if len(head) < 2 or head[0] != "FS1":
        raise ValueError("not a ForeverScribe strip")
    events = []
    for rec in parts[1:]:
        f = rec.split(US, 3)
        if len(f) != 4:
            continue
        try:
            payload = json.loads(f[3])
        except ValueError:
            payload = {"unparsed": f[3][:200]}
        try:
            t = int(f[2])
        except ValueError:
            t = None
        events.append({"id": f[0], "type": f[1], "t": t, "payload": payload})
    return head[1], events


# ---------------------------------------------------------------------------
# PNG I/O (stdlib only)
# ---------------------------------------------------------------------------

def read_png(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat = 8, b""
    width = height = depth = ctype = None
    while pos < len(data):
        (n,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            width, height, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if depth != 8 or ctype not in (2, 6):
        raise ValueError("only 8-bit RGB/RGBA PNGs are supported")
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                if f == 1:
                    line[i] = (line[i] + a) & 0xFF
                elif f == 2:
                    line[i] = (line[i] + b) & 0xFF
                elif f == 3:
                    line[i] = (line[i] + (a + b) // 2) & 0xFF
                elif f == 4:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                    line[i] = (line[i] + pr) & 0xFF
        rows.append(line)
        prev = line

    def px(x, y):
        o = x * bpp
        row = rows[y]
        return row[o], row[o + 1], row[o + 2]
    return px, width, height


def read_bmp(path):
    """Uncompressed 24/32-bit BMP (what `screencapture -t bmp` / ImageIO writes). Much
    cheaper than PNG in pure Python: no inflate, no per-byte filters."""
    with open(path, "rb") as fh:
        d = fh.read()
    if d[:2] != b"BM":
        raise ValueError("not a BMP")
    off = int.from_bytes(d[10:14], "little")
    width = int.from_bytes(d[18:22], "little", signed=True)
    height = int.from_bytes(d[22:26], "little", signed=True)
    bpp = int.from_bytes(d[28:30], "little") // 8
    comp = int.from_bytes(d[30:34], "little")
    if bpp not in (3, 4) or comp not in (0, 3):
        raise ValueError("unsupported BMP (bpp=%d compression=%d)" % (bpp * 8, comp))
    top_down = height < 0
    height = abs(height)
    stride = (width * bpp + 3) & ~3

    def px(x, y):
        row = y if top_down else height - 1 - y
        o = off + row * stride + x * bpp
        return d[o + 2], d[o + 1], d[o]
    return px, width, height


def read_image(path):
    with open(path, "rb") as fh:
        magic = fh.read(2)
    return read_bmp(path) if magic == b"BM" else read_png(path)


def write_png(path, px, width, height):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(px(x, y))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


# ---------------------------------------------------------------------------
# Output sink
# ---------------------------------------------------------------------------

class Sink:
    """Appends unseen events as JSON lines to <out_dir>/live-<host>-<date>.jsonl."""

    def __init__(self, out_dir, host=None, seen_cap=5000):
        self.out_dir = out_dir
        self.host = (host or os.uname().nodename.split(".")[0]).replace(" ", "-")
        self.seen, self.order, self.cap = set(), [], seen_cap
        os.makedirs(out_dir, exist_ok=True)

    def path(self, now=None):
        return os.path.join(self.out_dir, "live-%s-%s.jsonl" % (self.host, time.strftime("%Y-%m-%d", time.localtime(now))))

    def write(self, char_key, events, captured_at=None):
        captured_at = captured_at or time.time()
        new = [e for e in events if e["id"] not in self.seen]
        if not new:
            return 0
        lines = []
        for e in new:
            self.seen.add(e["id"])
            self.order.append(e["id"])
            rec = dict(e, char_key=char_key, captured_at=int(captured_at), captured_at_ms=int(captured_at * 1000),
                       source_channel="pixel_strip")
            lines.append(json.dumps(rec, ensure_ascii=False, separators=(",", ":")))
        while len(self.order) > self.cap:
            self.seen.discard(self.order.pop(0))
        with open(self.path(captured_at), "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")  # one write call: readers only consume complete lines
        return len(new)


def handle_frame(px, width, height, g, sink, state):
    msg, state["hint"] = find_and_decode(px, width, height, g, state.get("hint"))
    if not msg:
        return None
    if msg.get("error"):
        return msg
    key = (msg["id"], msg["text"])
    if key == state.get("last"):
        return {"same": True}
    state["last"] = key
    try:
        char_key, events = parse_payload(msg["text"])
    except ValueError as e:
        return {"error": str(e)}
    n = sink.write(char_key, events)
    return {"char": char_key, "events": len(events), "new": n}


# ---------------------------------------------------------------------------
# macOS window discovery and capture
# ---------------------------------------------------------------------------

def run_osascript(script):
    fd, path = tempfile.mkstemp(suffix=".scpt")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(script)
        proc = subprocess.run(["osascript", path], capture_output=True, text=True, timeout=10)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "osascript failed")
    return proc.stdout.strip()


def find_window_bounds(process_name):
    script = '''tell application "System Events"
    set pList to every process whose name contains "%s"
    if (count pList) = 0 then
        return ""
    end if
    set p to item 1 of pList
    tell p
        if not (exists front window) then
            return ""
        end if
        set w to front window
        tell w
            set {x, y} to position
            set {ww, hh} to size
        end tell
        return (x as string) & "," & (y as string) & "," & (ww as string) & "," & (hh as string)
    end tell
end tell
return ""''' % process_name.replace('"', '\\"')
    out = run_osascript(script)
    parts = out.split(",") if out else []
    if len(parts) != 4:
        return None
    return tuple(int(float(p.strip())) for p in parts)


CAPTURE_FMT = ["bmp"]  # falls back to png once if this macOS build can't write BMP


def capture_region(x, y, w, h, out_path):
    subprocess.run(["screencapture", "-R%d,%d,%d,%d" % (x, y, w, h), "-x", "-t", CAPTURE_FMT[0], out_path],
                   check=True, timeout=5)
    try:
        return read_image(out_path)
    except ValueError:
        if CAPTURE_FMT[0] == "bmp":
            CAPTURE_FMT[0] = "png"
            log({"info": "BMP capture unsupported here; using PNG"})
        raise


def log(obj):
    sys.stderr.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stderr.flush()


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--out-dir", default=os.environ.get("FOREVERSCRIBE_LIVE_DIR") or None)
    p.add_argument("--interval-ms", type=int, default=250)
    p.add_argument("--process-name", default="World of Warcraft")
    p.add_argument("--region-w", type=int, default=600, help="points")
    p.add_argument("--region-h", type=int, default=220, help="points")
    p.add_argument("--test-image")
    p.add_argument("--probe")
    a = p.parse_args(argv)
    g = Geometry()

    if a.test_image:
        px, w, h = read_image(a.test_image)
        msg, off = find_and_decode(px, w, h, g)
        print(json.dumps({"msg": msg, "offset": off}))
        return 0

    sink = Sink(a.out_dir or default_out())
    state = {}
    bounds, bounds_at, idle_logged = None, 0, 0
    while True:
        start = time.time()
        if bounds is None or start - bounds_at > 5:
            try:
                bounds = find_window_bounds(a.process_name)
            except Exception as e:  # permissions, System Events hiccup
                bounds = None
                if start - idle_logged > 60:
                    log({"warn": "window lookup failed: %s" % e})
                    idle_logged = start
            bounds_at = start
        if not bounds:
            if a.probe:
                log({"error": "no game window found"})
                return 1
            time.sleep(3)
            continue
        x, y, ww, wh = bounds
        fd, tmp = tempfile.mkstemp(suffix=".img")
        os.close(fd)
        try:
            try:
                px, width, height = capture_region(x, y, min(a.region_w, ww), min(a.region_h, wh), tmp)
            except Exception as e:
                log({"warn": "capture failed: %s" % e})
                time.sleep(1)
                continue
            if a.probe:
                write_png(a.probe, px, width, height)
                msg, off = find_and_decode(px, width, height, g)
                print(json.dumps({"saved": a.probe, "size": [width, height], "strip": msg, "offset": off}))
                return 0
            r = handle_frame(px, width, height, g, sink, state)
            if r and (r.get("error") or r.get("new")):
                log(r)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        time.sleep(max(0, a.interval_ms / 1000.0 - (time.time() - start)))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
