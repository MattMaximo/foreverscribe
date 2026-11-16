"""Live bridge tests: real Lua addon output -> rendered screen pixels -> live_capture
decoder -> JSONL -> companion ingest. Also measures the per-frame pipeline cost."""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT = fsenv.ROOT
sys.path.insert(0, ROOT)
from foreverscribe import live_capture as LC  # noqa: E402
from foreverscribe import store  # noqa: E402

LUA = fsenv.find_lua()


def frames(n):
    out = subprocess.run([LUA, os.path.join(ROOT, "tests", "lua", "live_dump.lua"), str(n)], capture_output=True,
                         text=True, check=True, cwd=ROOT).stdout
    fr, shown = [], None
    for line in out.splitlines():
        if line.startswith("FRAME "):
            _, tag, cells = line.split(" ", 2)
            fr.append((tag, [int(c) for c in cells.split(",")]))
        elif line.startswith("SHOWN "):
            shown = line.split()[1]
    return fr, shown


def render(cells, g, ox=3, oy=52, width=640, height=260, lo=18, hi=236, jitter=12, seed=1):
    """Simulate a Retina capture: offset under a title bar, imperfect gamma, noise."""
    rnd = random.Random(seed)
    grid = {}
    for i, v in enumerate(cells):
        grid[(i % g.cells, i // g.cells)] = v
    bg = (40, 44, 60)

    def px(x, y):
        cx, cy = x - ox, y - oy
        if cx < 0 or cy < 0 or cx >= g.w or cy >= g.h:
            return bg
        v = grid.get((cx // g.cell, cy // g.cell))
        if v is None:
            return bg
        j = rnd.randint(-jitter, jitter)
        return tuple(max(0, min(255, (hi if (v >> s) & 1 else lo) + j)) for s in (2, 1, 0))
    rows = [[px(x, y) for x in range(width)] for y in range(height)]
    return (lambda x, y: rows[y][x]), width, height


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fs-live-", dir=os.environ.get("TMPDIR"))

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def test_strip_roundtrip_ingest_and_latency(self):
        fr, shown = frames(6)
        self.assertEqual(shown, "false", "live off hides the strip")
        g = LC.Geometry()
        sink = LC.Sink(os.path.join(self.d, "live"), host="test")
        state = {}
        con = store.connect(os.path.join(self.d, "db.sqlite"))
        per_frame = []
        total_new = 0
        for tag, cells in fr:
            px, w, h = render(cells, g)
            t0 = time.perf_counter()
            r = LC.handle_frame(px, w, h, g, sink, state)
            res = store.ingest_all(con, [os.path.join(self.d, "live")])
            per_frame.append(time.perf_counter() - t0)
            self.assertFalse(r.get("error"), r)
            total_new += r["new"]
            if tag != "burst":
                ids = [row[0] for row in con.execute("SELECT event_id FROM events")]
                self.assertIn(tag, ids, "newest event reached the DB in the same frame")
        n_db = con.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        self.assertEqual(n_db, total_new)
        types = {row[0] for row in con.execute("SELECT DISTINCT type FROM events")}
        self.assertTrue({"DEATH", "ZONE_CHANGED", "LEVEL_UP"} <= types)
        # identical frame re-seen -> nothing new
        px, w, h = render(fr[-1][1], g, seed=9)
        self.assertTrue(LC.handle_frame(px, w, h, g, sink, state).get("same"))
        worst = max(per_frame)
        avg = sum(per_frame) / len(per_frame)
        interval = 0.25
        report = {"frames": len(per_frame), "decode_ingest_avg_ms": round(avg * 1000, 1),
                  "decode_ingest_worst_ms": round(worst * 1000, 1), "capture_interval_ms": interval * 1000,
                  "expected_worst_case_ms_excl_screencapture_and_transport": round((interval + worst) * 1000, 1)}
        print("\nlive latency (simulated):", report)
        self.assertLess(worst, 1.0)

    def test_corrupted_frame_rejected(self):
        fr, _ = frames(1)
        g = LC.Geometry()
        cells = list(fr[0][1])
        cells[40] ^= 7  # flip one cell
        px, w, h = render(cells, g)
        r = LC.handle_frame(px, w, h, g, LC.Sink(os.path.join(self.d, "l")), {})
        self.assertEqual(r.get("error"), "checksum")

    def test_bmp_from_imageio(self):
        if not shutil.which("sips"):
            self.skipTest("sips not available")
        fr, _ = frames(2)
        g = LC.Geometry()
        px, w, h = render(fr[-1][1], g, width=1200, height=440)
        p = os.path.join(self.d, "probe.png")
        LC.write_png(p, px, w, h)
        b = os.path.join(self.d, "probe.bmp")
        subprocess.run(["sips", "-s", "format", "bmp", p, "--out", b], check=True, capture_output=True)
        t0 = time.perf_counter()
        px2, w2, h2 = LC.read_image(b)
        msg, off = LC.find_and_decode(px2, w2, h2, g)
        dt = time.perf_counter() - t0
        self.assertEqual(LC.parse_payload(msg["text"])[0], "Forever-Test:Pixelpop")
        self.assertLess(dt, 0.2, "BMP read+decode of a Retina-size region must be fast")

    def test_png_file_path(self):
        fr, _ = frames(2)
        g = LC.Geometry()
        px, w, h = render(fr[-1][1], g)
        p = os.path.join(self.d, "probe.png")
        LC.write_png(p, px, w, h)
        px2, w2, h2 = LC.read_png(p)
        msg, off = LC.find_and_decode(px2, w2, h2, g)
        self.assertTrue(abs(off[0] - 3) <= 2 and abs(off[1] - 52) <= 2, off)  # first offset inside the cell centre
        ck, evs = LC.parse_payload(msg["text"])
        self.assertEqual(ck, "Forever-Test:Pixelpop")
        self.assertGreaterEqual(len(evs), 2)


if __name__ == "__main__":
    unittest.main()
