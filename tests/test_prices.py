"""v0.6: AH prices in item tooltips. The price-file writer (fetch, compact rows, size cap, validation), delivery
(local addon folder, synced folder, receiver), the macOS sync agent's fetch + validator, the Windows agent's validator
and paths, and the addon loading a file the writer produced. wow.gg is stubbed (prices.FETCH), so everything runs
offline."""

import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT = fsenv.ROOT
sys.path.insert(0, ROOT)
from foreverscribe import auth, prices as P  # noqa: E402

LUA = fsenv.find_lua()
SYNC = os.path.join(ROOT, "installers", "macos", "foreverscribe-sync.sh")
SYNC_PS1 = os.path.join(ROOT, "installers", "windows", "foreverscribe-sync.ps1")
MARKET = "forever.pvp.alliance.us"
CAPTURED = "2026-11-16T17:56:17.000Z"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def row(iid, name, median, mn, qty, d7, d30, other=None, cls="Trade Goods"):
    r = {"itemId": iid, "name": name, "itemClass": cls, "median": median, "minBuyout": mn, "quantity": qty,
         "median7d": d7, "median30d": d30, "vendorSell": 600, "historyPoints": [{"median": 1}] * 50}
    if other is not None:
        r["other"] = {"market": "forever.pvp.horde.us", "median": other}
    return r


ROWS = [row(4305, "Bolt of Silk Cloth", 868, 849, 585, 879, 932, 830), row(4291, "Silken Thread", 50, 45, 300, 55, 60),
        row(10302, "Pattern: Filigreed Silky Circlet", 12500, 11000, 3, 12000, 11800, cls="Recipe"),
        row(10303, "Filigreed Silky Circlet", 21000, 19000, 4, 20000, 18000, 22000, cls="Armor"),
        row(5000, "Coral Band", 9800.4, 9000, 2, 9500, 7746, cls="Armor")]


def fake_pages(calls, rows=ROWS, per=2, captured=CAPTURED):
    pages = max(1, (len(rows) + per - 1) // per)

    def page(market, n):
        calls.append((market, n))
        return {"market": market, "label": "PvP Alliance US", "capturedAt": captured, "pricesAvailable": True,
                "pages": pages, "rows": rows[(n - 1) * per:n * per]}
    return page


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="fs-v6-", dir=os.environ.get("TMPDIR"))
        self.data = os.path.join(self.t, "data")
        self.cfg = os.path.join(self.t, "config.toml")
        self.saved_env = dict(os.environ)
        os.environ.update(FOREVERSCRIBE_CONFIG=self.cfg)
        for k in ("FOREVERSCRIBE_DATA", "WOWGG_KEY", "FOREVERSCRIBE_PRICE_DIR"):
            os.environ.pop(k, None)
        self.calls = []
        self.saved_fetch = dict(P.FETCH)
        P.FETCH["page"] = fake_pages(self.calls)
        self.saved_pause, P.PAGE_PAUSE = P.PAGE_PAUSE, 0
        self.write_cfg()

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_env)
        P.FETCH.clear()
        P.FETCH.update(self.saved_fetch)
        P.PAGE_PAUSE = self.saved_pause
        shutil.rmtree(self.t, ignore_errors=True)

    def write_cfg(self, transport='mode = "local"', wow="", ah=True, extra=""):
        with open(self.cfg, "w") as f:
            f.write('data_dir = "%s"\n[transport]\n%s\n[wow]\ndir = "%s"\n[ah]\nenabled = %s\nwowgg_key = "test-key"\nmarket = "%s"\n%s'
                    % (self.data, transport, wow, "true" if ah else "false", MARKET, extra))

    def make_wow(self, with_prices=True):
        wow = os.path.join(self.t, "wow")
        addons = os.path.join(wow, "Interface", "AddOns")
        os.makedirs(os.path.join(wow, "WTF", "Account"))
        os.makedirs(addons)
        if with_prices:
            shutil.copytree(os.path.join(ROOT, "addon", "ForeverScribe_Prices"), os.path.join(addons, "ForeverScribe_Prices"))
        return wow, addons

    def run_main(self, argv):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = P.main(argv)
        return rc, buf.getvalue()

    def e2e(self, path, *ids):
        if not LUA:
            self.skipTest("no Lua 5.1 (tools/get_lua.sh)")
        r = subprocess.run([LUA, os.path.join(ROOT, "tests", "lua", "prices_e2e.lua"), path] + list(ids),
                           capture_output=True, text=True, cwd=ROOT)
        return json.loads(r.stdout.strip().splitlines()[-1])


class Writer(Sandbox):
    def snap(self):
        from foreverscribe import ah, config as C
        cfg = C.load()
        return P.fetch_market(ah.settings(cfg), MARKET, cfg)[0]

    def test_compact_file_fields_and_validation(self):
        text, st = P.render_lua(self.snap(), MARKET, {"10302": [10303, [[4305, 3], [4291, 2]]], "777": [1, []]}, 1794856945)
        self.assertTrue(P.valid(text), text)
        self.assertIn('\t\t[4305] = "868,849,585,879,932,830",', text)
        self.assertIn('\t\t[4291] = "50,45,300,55,60",', text, "no other-faction value: trailing field dropped")
        self.assertIn('\t\t[5000] = "9800,9000,2,9500,7746",', text, "rounded to whole copper")
        self.assertIn('\t\t[10302] = "10303;4305:3,4291:2",', text)
        self.assertNotIn("[777]", text, "patterns only for recipes listed on this market")
        self.assertIn('\tlabel = "PvP Alliance",', text)
        self.assertIn('\tother = "Horde",', text)
        self.assertIn("\tcaptured = 1794851777,", text)
        self.assertNotIn("historyPoints", text)
        self.assertEqual((st["items"], st["patterns"], st["dropped"]), (5, 1, 0))
        # the validator refuses anything that is not data
        for evil in (text.replace('\tlabel = "PvP Alliance",', '\tlabel = "x" .. os.exit(),'),
                     text.replace('[4305] = "868', '[4305] = loadstring("x")'),
                     text + "os.execute('rm -rf ~')\n",
                     text.replace("ForeverScribe_PriceData = {", "ForeverScribe_PriceData = {} ForeverScribe_PriceData = {")):
            self.assertFalse(P.valid(evil), evil[-200:])

    def test_size_cap_keeps_the_most_listed_items(self):
        rows = [row(1000 + i, "Item %d" % i, 10000 + i, 9000, i + 1, 9500, 9700, 9900) for i in range(3000)]
        P.FETCH["page"] = fake_pages(self.calls, rows=rows, per=200)
        snap = self.snap()
        self.assertEqual(len(snap["items"]), 3000)
        self.assertEqual(len(self.calls), 15, "every page fetched once")
        full, st = P.render_lua(snap, MARKET, {}, 0)
        per_item = st["bytes"] / 3000.0
        self.assertLess(per_item, 45, "compact rows: measured bytes per item")
        text, st = P.render_lua(snap, MARKET, {}, 0, max_bytes=40000)
        self.assertLessEqual(st["bytes"], 40000)
        self.assertGreater(st["bytes"], 38000, "drops only what it must")
        self.assertGreater(st["dropped"], 0)
        self.assertEqual(st["items"] + st["dropped"], 3000)
        self.assertTrue(P.valid(text))
        self.assertIn("[3999] =", text, "most listed survives")
        self.assertNotIn("[1000] =", text, "least listed dropped first")
        # the real cap fits a whole Forever market (~6,500 items) with room to spare
        self.assertGreater(P.MAX_BYTES / per_item, 10000)

    def test_unchanged_scan_costs_one_page_and_keeps_the_same_rev(self):
        wow, addons = self.make_wow()
        self.write_cfg('mode = "local"', wow)
        st1 = P.write()
        n = len(self.calls)
        self.assertEqual(n, 3)
        mtime = os.path.getmtime(os.path.join(addons, "ForeverScribe_Prices", "Prices.lua"))
        time.sleep(0.05)
        st2 = P.write()
        self.assertEqual(len(self.calls), n + 1, "same capturedAt: only page 1 asked")
        self.assertEqual(st2["rev"], st1["rev"])
        self.assertTrue(st2["unchanged"])
        self.assertEqual(os.path.getmtime(os.path.join(addons, "ForeverScribe_Prices", "Prices.lua")), mtime, "not rewritten")
        P.FETCH["page"] = fake_pages(self.calls, captured="2026-11-16T18:26:17.000Z")
        st3 = P.write()
        self.assertNotEqual(st3["rev"], st1["rev"])
        self.assertEqual(st3["captured"], st1["captured"] + 1800)

    def test_off_by_default_and_without_a_market(self):
        self.write_cfg(ah=False)
        rc, out = self.run_main(["write"])
        self.assertEqual(rc, 6)
        self.assertIn("AH prices are off", out)
        self.assertEqual(self.calls, [])
        rc, out = self.run_main(["status"])
        self.assertIn("off", out)

    def test_local_write_and_the_addon_loads_it(self):
        wow, addons = self.make_wow()
        self.write_cfg('mode = "local"', wow)
        rc, out = self.run_main(["write"])
        self.assertEqual(rc, 0, out)
        self.assertIn("5 items", out)
        dest = os.path.join(addons, "ForeverScribe_Prices", "Prices.lua")
        self.assertTrue(P.valid(read(dest)))
        rc, out = self.run_main(["status"])
        self.assertIn(MARKET, out)
        self.assertIn("local: " + dest, out)
        got = self.e2e(dest, "4305", "4305s", "10302", "99999")
        self.assertTrue(got["loaded"], got)
        self.assertEqual(got["errors"], 0)
        self.assertEqual(got["label"], "PvP Alliance")
        self.assertIn("Typical price | 8s 68c", got["lines"]["4305"])
        self.assertIn("Your 12 are worth | 1g 4s 16c", got["lines"]["4305"])
        self.assertIn("Horde side | 8s 30c", got["lines"]["4305s"])
        self.assertIn("No recent listings", got["lines"]["99999"])
        self.assertTrue(got["lines"]["4305"][0].startswith("Auction House | PvP Alliance · "), got["lines"]["4305"])

    def test_shipped_empty_file_and_patterns_table(self):
        empty = os.path.join(ROOT, "addon", "ForeverScribe_Prices", "Prices.lua")
        self.assertEqual(read(empty), P.EMPTY_LUA, "never commit a written price file")
        toc = read(os.path.join(ROOT, "addon", "ForeverScribe_Prices", "ForeverScribe_Prices.toc"))
        self.assertNotIn("LoadOnDemand", toc, "loads with the game so login and /reload pick up the newest file")
        self.assertIn("ForeverScribe_Prices", read(os.path.join(ROOT, "addon", "ForeverScribe", "ForeverScribe.toc")))
        got = self.e2e(empty, "4305")
        self.assertFalse(got["loaded"])
        self.assertEqual(got["lines"]["4305"], [])
        pats = json.loads(read(P.PATTERNS_FILE))["patterns"]
        self.assertGreater(len(pats), 100)
        for k, v in pats.items():
            self.assertTrue(k.isdigit() and isinstance(v[0], int) and all(len(r) == 2 for r in v[1]), (k, v))

    def test_missing_prices_addon_is_reported(self):
        wow, addons = self.make_wow(with_prices=False)
        self.write_cfg('mode = "local"', wow)
        rc, out = self.run_main(["write"])
        self.assertEqual(rc, 2)
        self.assertIn("ForeverScribe_Prices is not installed", out)


class Delivery(Sandbox):
    def sync(self, wow, support, folder="", url="", key_id=""):
        with open(os.path.join(support, "game.conf"), "w") as fh:
            fh.write("KEY_ID=%s\n" % key_id)
        env = dict(os.environ, HOME=os.path.join(self.t, "home"), FOREVERSCRIBE_SUPPORT=support, FOREVERSCRIBE_WOW_DIR=wow,
                   FOREVERSCRIBE_DEST=folder, FOREVERSCRIBE_PUSH_URL=url, FOREVERSCRIBE_SYNC_SETTLE="0.1",
                   FOREVERSCRIBE_PUSH_TRIES="1", FOREVERSCRIBE_PRICE_EVERY="0")
        return subprocess.run(["bash", SYNC, "-v"], env=env, capture_output=True, text=True, timeout=60).stdout

    def test_folder_transport_sync_agent_copies_and_rejects_code(self):
        wow, addons = self.make_wow()
        folder = os.path.join(self.t, "synced")
        self.write_cfg('mode = "folder"\nfolder = "%s"' % folder)
        rc, out = self.run_main(["write"])
        self.assertEqual(rc, 0, out)
        src = os.path.join(folder, "_prices", "Prices.lua")
        self.assertTrue(os.path.isfile(src))
        support = os.path.join(self.t, "support")
        os.makedirs(support)
        log = self.sync(wow, support, folder=folder)
        self.assertIn("from synced folder written", log)
        dest = os.path.join(addons, "ForeverScribe_Prices", "Prices.lua")
        self.assertEqual(read(dest), read(src))
        self.assertNotIn("prices", self.sync(wow, support, folder=folder), "same file: quiet")
        good = read(src)
        for evil in (good.replace('\tlabel = "PvP Alliance",', '\tlabel = "x" .. os.exit(),'), good + "os.exit()\n",
                     good.replace('"868,849', '"868" .. x .. "')):
            with open(src, "w") as f:
                f.write(evil)
            log = self.sync(wow, support, folder=folder)
            self.assertIn("ignored: not a ForeverScribe price file", log)
            self.assertEqual(read(dest), good)
        # the price file in the synced folder is never mistaken for SavedVariables
        from foreverscribe import store
        self.assertEqual([k for k, _ in store.discover([folder])], [])
        # a kit without the prices addon (0.5) is left alone
        shutil.rmtree(os.path.join(addons, "ForeverScribe_Prices"))
        with open(src, "w") as f:
            f.write(good)
        self.assertNotIn("prices", self.sync(wow, support, folder=folder))
        self.assertFalse(os.path.exists(os.path.join(addons, "ForeverScribe_Prices")))

    def test_http_receiver_serves_prices_to_signed_sync_agent_only(self):
        wow, addons = self.make_wow()
        port = free_port()
        self.write_cfg('mode = "http"', extra='[receiver]\nbind = "127.0.0.1"\nport = %d\n' % port)
        env = dict(os.environ, PYTHONPATH=ROOT)
        code = subprocess.run([sys.executable, "-m", "foreverscribe", "pair", "--name", "test-pc", "--code-only"], env=env,
                              cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
        p = auth.decode_pairing(code)
        support = os.path.join(self.t, "support")
        os.makedirs(support)
        with open(os.path.join(support, "pairing.key"), "w") as fh:
            fh.write(p["key"])
        rx = subprocess.Popen([sys.executable, "-m", "foreverscribe", "receiver", "run"], env=env, cwd=ROOT,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            url = "http://127.0.0.1:%d" % port
            for _ in range(80):
                try:
                    urllib.request.urlopen(url + "/v1/health", timeout=1)
                    break
                except Exception:
                    time.sleep(0.1)
            # written now, so the receiver's 30-minute background refresh does not fire (it would need wow.gg)
            rc, out = self.run_main(["write"])
            self.assertEqual(rc, 0, out)
            self.assertIn("http: " + os.path.join(self.data, "prices", "Prices.lua"), out)
            req = urllib.request.Request(url + "/v1/prices", data=b"prices", method="POST")
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(req, timeout=5)
            self.assertEqual(cm.exception.code, 403, "unsigned is refused")
            log = self.sync(wow, support, url=url, key_id=p["key_id"])
            self.assertIn("from receiver written", log)
            dest = os.path.join(addons, "ForeverScribe_Prices", "Prices.lua")
            rev = P.file_rev(dest)
            self.assertEqual(rev, P.status()["written"]["rev"])
            self.assertEqual(json.loads(read(os.path.join(self.data, "prices", "pickup.json")))["rev"], rev)
            self.assertNotIn("prices", self.sync(wow, support, url=url, key_id=p["key_id"]), "304: unchanged")
            rc, out = self.run_main(["status"])
            self.assertIn("game computer fetched %s" % rev, out)
            # the 5-minute throttle: with a file in place the next pass does not ask
            env2 = dict(os.environ, HOME=os.path.join(self.t, "home"), FOREVERSCRIBE_SUPPORT=support, FOREVERSCRIBE_WOW_DIR=wow,
                        FOREVERSCRIBE_PUSH_URL=url, FOREVERSCRIBE_SYNC_SETTLE="0.1", FOREVERSCRIBE_PUSH_TRIES="1")
            before = os.path.getmtime(os.path.join(self.data, "prices", "pickup.json"))
            stamp = os.path.join(support, "prices-checked")
            self.assertTrue(os.path.isfile(stamp))
            subprocess.run(["bash", SYNC], env=env2, capture_output=True, text=True, timeout=60)
            self.assertEqual(os.path.getmtime(os.path.join(self.data, "prices", "pickup.json")), before)
        finally:
            rx.terminate()
            rx.wait()

    def test_receiver_refresh_runs_in_background_and_only_when_stale(self):
        from foreverscribe import config as C
        wow, addons = self.make_wow()
        self.write_cfg('mode = "http"')
        cfg = C.load()
        logs = []
        P._STATE.update(running=False, last_try=0)
        self.assertTrue(P.refresh_async(cfg, log=logs.append), "no file yet: refresh")
        for _ in range(100):
            if not P._STATE["running"]:
                break
            time.sleep(0.05)
        self.assertTrue(os.path.isfile(P.receiver_copy(cfg)))
        self.assertTrue(any("refreshed" in m for m in logs), logs)
        P._STATE.update(last_try=0)
        self.assertFalse(P.refresh_async(cfg), "fresh file: nothing to do")
        self.write_cfg('mode = "http"', ah=False)
        self.assertFalse(P.refresh_async(C.load()), "AH prices off: never")

    def test_sync_agents_share_the_writers_line_rules_and_paths(self):
        text, _ = P.render_lua(Writer.snap(self), MARKET, {"10302": [10303, [[4305, 3]]]}, 0)  # type: ignore[arg-type]
        sh = read(SYNC)
        m = re.search(r"^PRICE_LINE='(.*)'$", sh, re.M)
        sh_re = re.compile(m.group(1).replace("@", "\t"))
        ps = read(SYNC_PS1)
        m = re.search(r"^\$PriceLine = '(.*)'$", ps, re.M)
        ps_re = re.compile(m.group(1).replace(r"\t", "\t"))
        bad = ['\tlabel = "x" .. os.exit(),', 'os.exit()', '\t\t[1] = "1" .. x,', '\trev = "a"; os.exit() --",']
        for name, rx in (("macOS", sh_re), ("Windows", ps_re)):
            for line in text.split("\n"):
                self.assertTrue(rx.match(line), "%s rejects a writer line: %r" % (name, line))
            for line in bad:
                self.assertFalse(rx.match(line), "%s accepts %r" % (name, line))
        # Windows: the only game-folder write is ForeverScribe_Prices\Prices.lua; folder pickup from _prices\Prices.lua
        self.assertIn(r'Join-Path $c.wowDir "Interface\AddOns\ForeverScribe_Prices"', ps)
        self.assertIn(r'Join-Path $c.folderDest "_prices\Prices.lua"', ps)
        self.assertIn('"/v1/prices"', ps)
        self.assertIn("Prices-Pickup $c", ps)
        self.assertIn("Valid-Prices $text", ps)
        # macOS: same
        self.assertIn('PRICE_DIR="$ADDONS/ForeverScribe_Prices"', sh)
        self.assertIn('"$FOLDER_DEST/_prices/Prices.lua"', sh)
        # both installers ship and remove the prices addon
        self.assertIn("ForeverScribe_Prices", read(os.path.join(ROOT, "installers", "macos", "install.sh")))
        self.assertIn("ForeverScribe_Prices", read(os.path.join(ROOT, "installers", "macos", "uninstall.sh")))
        self.assertIn('"ForeverScribe_Prices"', read(os.path.join(ROOT, "installers", "windows", "install.ps1")))

    def test_targets_per_transport(self):
        from foreverscribe import config as C
        wow, addons = self.make_wow()
        folder = os.path.join(self.t, "synced")
        self.write_cfg('mode = "http"\nfolder = "%s"' % folder, wow)
        kinds = [k for k, _ in P.targets(C.load())]
        self.assertEqual(kinds, ["folder", "http"])
        self.assertEqual([k for k, _ in P.targets(C.load(), "all")], ["local", "folder", "http"])
        self.write_cfg('mode = "local"', wow)
        self.assertEqual(P.targets(C.load()), [("local", os.path.join(addons, "ForeverScribe_Prices"))])


if __name__ == "__main__":
    unittest.main()
