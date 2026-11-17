"""v0.8: craft cost & profit. The companion's precompute (recipe -> materials -> cost, sells for, profit), the vendor-
cheaper choice, the AH cut, the price-file rows the profession window reads (and the addon reading them), the
store migration, `craft --profit` and its MCP tool. Everything offline on synthetic data."""

import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT = fsenv.ROOT
sys.path.insert(0, ROOT)
from foreverscribe import crafting as K, mcp_server, prices as P, store  # noqa: E402

LUA = fsenv.find_lua()
CK = "Forever-Test:Pixelpop"

# AH rows like the market snapshot: [median, min, listed, d7, d30, other, recipe-flag]
ITEMS = {
    "2996": [62, 55, 900, 60, 61, None, 0],          # Bolt of Linen Cloth
    "2320": [15, 12, 400, 15, 15, None, 0],          # Coarse Thread (vendor 10c is cheaper)
    "2321": [90, 85, 800, 95, 99, None, 0],          # Fine Thread (vendor 100c is dearer: AH wins)
    "2605": [212, 200, 30, 210, 220, None, 0],       # Green Dye
    "2997": [522, 500, 600, 530, 540, None, 0],      # Bolt of Woolen Cloth
    "4340": [342, 300, 12, 340, 350, None, 0],       # Gray Dye
    "4344": [100, 95, 10, 100, 100, None, 0],        # Brown Linen Shirt
    "6385": [7490, 7000, 3, 7400, 7300, None, 0],    # Stylish Green Shirt
    "6888": [50, 45, 40, 50, 52, None, 0],           # Herb Baked Egg
    "6889": [159, 150, 20, 160, 160, None, 0],       # Small Egg
}
VENDOR = {2320: 10, 2321: 100, 2678: 2, 2605: 100, 4340: 350}


def recipe(rid, name, out, reagents, qty=1, prof="Tailoring", diff=0):
    return (CK, prof, str(rid), rid, name, diff, 1, out, json.dumps([{"itemID": i, "qty": n} for i, n in reagents]),
            1794805668, qty)


RECIPES = [
    recipe(3915, "Brown Linen Shirt", 4344, [(2996, 1), (2320, 1)], diff=3),
    recipe(7892, "Stylish Green Shirt", 6385, [(2997, 4), (2605, 2), (4340, 1), (2321, 1)], diff=1),
    recipe(253886, "Novice Arcanist's Sash", 253885, [(2996, 8), (2321, 2)], diff=3),            # bind on pickup
    recipe(253952, "Silky Circlet", 253951, [(2996, 2), (99999, 1)], diff=0),                     # unpriced material
    recipe(6413, "Herb Baked Egg", 6888, [(6889, 1), (2678, 1)], prof="Cooking", diff=2),
    recipe(9999, "Spiced Batch", 6888, [(6889, 1)], qty=5, prof="Cooking", diff=0),               # makes 5
]


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="fs-v8-", dir=os.environ.get("TMPDIR"))
        self.db = os.path.join(self.t, "forever.db")
        self.con = store.connect(self.db)
        with self.con:
            self.con.executemany("INSERT INTO recipes (char_key, profession, recipe_key, recipe_id, name, difficulty,"
                                 " skill_ups, output_item, reagents_json, scanned_at, output_qty)"
                                 " VALUES (?,?,?,?,?,?,?,?,?,?,?)", RECIPES)
        self.saved_vendor = K.shipped_vendor_prices
        K.shipped_vendor_prices = lambda: dict(VENDOR)

    def tearDown(self):
        K.shipped_vendor_prices = self.saved_vendor
        self.con.close()
        shutil.rmtree(self.t, ignore_errors=True)


class Precompute(Sandbox):
    def test_vendor_price_wins_only_when_cheaper(self):
        self.assertEqual(K.unit_price(2320, ITEMS, VENDOR), (10, "vendor"), "vendor 10c < AH 15c")
        self.assertEqual(K.unit_price(2321, ITEMS, VENDOR), (90, "AH"), "AH 90c < vendor 100c")
        self.assertEqual(K.unit_price(2678, ITEMS, VENDOR), (2, "vendor"), "nobody lists it: vendor")
        self.assertEqual(K.unit_price(2996, ITEMS, VENDOR), (62, "AH"))
        self.assertIsNone(K.unit_price(99999, ITEMS, VENDOR), "no AH row, no vendor: no price")

    def test_profit_after_the_ah_cut(self):
        e = K.evaluate(6385, 1, [(2997, 4), (2605, 2), (4340, 1), (2321, 1)], ITEMS, VENDOR, 0.05)
        self.assertEqual(e["cost"], 4 * 522 + 2 * 100 + 342 + 90)   # dye from the vendor, gray dye + thread from the AH
        self.assertEqual(e["sells"], 7490)
        self.assertEqual(e["cut"], 375, "5% of 74s 90c, half up")
        self.assertEqual(e["profit"], 7490 - 375 - e["cost"])
        loss = K.evaluate(4344, 1, [(2996, 1), (2320, 1)], ITEMS, VENDOR, 0.30)
        self.assertEqual(loss["profit"], 100 - 30 - 72)
        self.assertLess(loss["profit"], 0)

    def test_missing_prices_leave_the_line_out(self):
        bop = K.evaluate(253885, 1, [(2996, 8), (2321, 2)], ITEMS, VENDOR)
        self.assertEqual(bop["cost"], 8 * 62 + 2 * 90)
        self.assertIsNone(bop["sells"]); self.assertIsNone(bop["profit"]); self.assertIsNone(bop["cut"])
        miss = K.evaluate(4344, 1, [(2996, 2), (99999, 1)], ITEMS, VENDOR)
        self.assertIsNone(miss["cost"]); self.assertIsNone(miss["profit"]); self.assertEqual(miss["missing"], [99999])
        self.assertEqual(miss["sells"], 100, "sells for still shown")

    def test_multi_output_recipe_sells_times_count(self):
        e = K.evaluate(6888, 5, [(6889, 1)], ITEMS, VENDOR)
        self.assertEqual(e["sells"], 250)
        self.assertEqual(e["profit"], 250 - 13 - 159)

    def test_ah_cut_default_invoices_config(self):
        self.assertEqual(K.ah_cut(None, self.con), (0.05, "default"))
        mail = {"mails": [{"invoice": {"type": "seller", "item": "Linen Cloak", "buyout": 2000, "fee": 120}},
                          {"invoice": {"type": "seller", "item": "Linen Bag", "buyout": 1000, "fee": 60}},
                          {"invoice": {"type": "buyer", "item": "Silk", "buyout": 500}}]}
        with self.con:
            self.con.execute("INSERT INTO sections (char_key, section, captured_at, sha256, json, ingested_at)"
                             " VALUES (?,?,?,?,?,?)", (CK, "mail", 1, "x", json.dumps(mail), 1))
        self.assertEqual(K.ah_cut(None, self.con), (0.06, "your AH invoices"))

        class Cfg:
            def section(self, name):
                return {"cut": "5.5"} if name == "ah" else {}
        self.assertEqual(K.ah_cut(Cfg(), self.con), (0.055, "config"))

    def test_captured_vendor_prices_beat_the_list(self):
        v = {"npcs": {"5": {"npcID": 5, "items": [
            {"itemID": 2320, "price": 9, "stack": 1},                       # rep discount
            {"itemID": 3371, "price": 20, "stack": 5},                      # 4c each
            {"itemID": 4291, "price": 400, "limited": 3},                   # limited stock: not a price to count on
            {"itemID": 2325, "price": 0, "cost": [{"currencyID": 1}]}]}}}   # currency cost
        with self.con:
            self.con.execute("INSERT INTO sections (char_key, section, captured_at, sha256, json, ingested_at)"
                             " VALUES (?,?,?,?,?,?)", (CK, "vendors", 1, "x", json.dumps(v), 1))
        got = K.vendor_prices(self.con)
        self.assertEqual(got[2320], 9); self.assertEqual(got[3371], 4); self.assertEqual(got[4291] if 4291 in got else None, None)
        self.assertNotIn(2325, got); self.assertEqual(got[2678], 2, "list prices still there")

    def test_shipped_vendor_list_is_game_data_and_sane(self):
        with open(K.VENDOR_FILE, encoding="utf-8") as f:
            d = json.load(f)
        self.assertGreater(len(d["items"]), 20)
        for k, v in d["items"].items():
            self.assertTrue(k.isdigit()); self.assertGreater(v[0], 0); self.assertIsInstance(v[1], str)
        self.assertEqual(d["items"]["3371"][0], 4, "Empty Vial: 20c for 5")
        self.assertEqual(d["items"]["2321"][0], 100, "Fine Thread 1s")


class PriceFile(Sandbox):
    def snap(self):
        return {"market": "forever.pvp.alliance.us", "label": "PvP Alliance US", "capturedAt": "2026-11-16T22:21:42.000Z",
                "items": ITEMS}

    def test_rows_written_and_valid_and_small(self):
        vendor, crafts, cut = K.price_file_rows(self.con, ITEMS)
        self.assertEqual(cut, 0.05)
        self.assertEqual(crafts[3915], "4344,1,72,100;2996:1,2320:1")
        self.assertEqual(crafts[253886], "253885,1,676,;2996:8,2321:2", "bind on pickup: no sells-for")
        self.assertEqual(crafts[253952], "253951,1,,;2996:2,99999:1", "unpriced material: no cost")
        self.assertEqual(crafts[9999], "6888,5,159,250;6889:1")
        self.assertEqual(set(vendor), {2320, 2321, 2678, 2605, 4340}, "only materials a known recipe uses")
        text, st = P.render_lua(self.snap(), "forever.pvp.alliance.us", {}, 1794856945, vendor=vendor, crafts=crafts, cut=cut)
        self.assertTrue(P.valid(text))
        self.assertIn('\t\t[2320] = "15,12,400,15,15,,10",', text, "vendor price is the 7th field")
        self.assertIn('\t\t[2678] = ",,,,,,2",', text, "vendor-only material gets a row")
        self.assertIn('\t\t[100003915] = "4344,1,72,100;2996:1,2320:1",', text)
        self.assertIn('\t\t[100000000] = "500",', text, "AH cut in basis points")
        self.assertEqual(st["crafts"], 6)
        base, _ = P.render_lua(self.snap(), "forever.pvp.alliance.us", {}, 1794856945)
        self.assertLess(len(text) - len(base), 600, "6 recipes cost a few hundred bytes")

    def test_sync_agents_accept_the_new_rows(self):
        vendor, crafts, cut = K.price_file_rows(self.con, ITEMS)
        text, _ = P.render_lua(self.snap(), "forever.pvp.alliance.us", {}, 1794856945, vendor=vendor, crafts=crafts, cut=cut)
        with open(os.path.join(ROOT, "installers", "macos", "foreverscribe-sync.sh"), encoding="utf-8") as f:
            sh = f.read()
        import re
        rule = re.search(r"^PRICE_LINE='(.*)'$", sh, re.M).group(1).replace("@", "\t")
        for line in text.splitlines():
            self.assertRegex(line, rule)

    def test_addon_shows_the_precomputed_numbers(self):
        if not LUA:
            self.skipTest("no Lua 5.1 (tools/get_lua.sh)")
        vendor, crafts, cut = K.price_file_rows(self.con, ITEMS)
        text, _ = P.render_lua(self.snap(), "forever.pvp.alliance.us", {}, 1794856945, vendor=vendor, crafts=crafts, cut=cut)
        path = os.path.join(self.t, "Prices.lua")
        with open(path, "w") as f:
            f.write(text)
        r = subprocess.run([LUA, os.path.join(ROOT, "tests", "lua", "prices_e2e.lua"), path, "r7892", "r253886", "r3915s"],
                           capture_output=True, text=True, cwd=ROOT)
        out = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertTrue(out["loaded"], out)
        e = K.evaluate(6385, 1, [(2997, 4), (2605, 2), (4340, 1), (2321, 1)], ITEMS, VENDOR)
        shirt = out["lines"]["r7892"]
        self.assertIn("Cost to craft | %s" % K.money(e["cost"]).replace("g ", "g ").strip(), shirt)
        self.assertIn("Sells for | 74s 90c", shirt)
        self.assertIn("Profit | +" + K.money(e["profit"]), shirt)
        sash = out["lines"]["r253886"]
        self.assertIn("Cost to craft | 6s 76c", sash)
        self.assertFalse([x for x in sash if x.startswith(("Sells for", "Profit"))], sash)
        self.assertIn("Coarse Thread  0/1 | 10c each · vendor", out["lines"]["r3915s"])
        self.assertEqual(out["errors"], 0)


class Report(Sandbox):
    def test_profit_report_ranks_and_explains(self):
        saved = K.market_snapshot
        K.market_snapshot = lambda cfg: {"market": "forever.pvp.alliance.us", "capturedAt": "2026-11-16T22:21:42.000Z",
                                         "items": ITEMS}
        try:
            rep = K.profit_report(self.con, CK, None)
            tailoring = K.profit_report(self.con, CK, None, "tailoring")
        finally:
            K.market_snapshot = saved
        names = [x["recipe"] for x in rep["best"]]
        self.assertEqual(names[0], "Stylish Green Shirt")
        self.assertEqual([x["profit"] for x in rep["best"]], sorted((x["profit"] for x in rep["best"]), reverse=True))
        self.assertEqual(rep["best"][0]["skill_up"], "yellow")
        self.assertEqual({x["recipe"] for x in rep["not_priced"]}, {"Novice Arcanist's Sash", "Silky Circlet"})
        self.assertTrue(all(x["profit"] is None for x in rep["not_priced"]))
        self.assertEqual({x["profession"] for x in tailoring["best"] + tailoring["not_priced"]}, {"Tailoring"})
        text = K.render(rep)
        self.assertIn("Stylish Green Shirt (Tailoring)", text)
        self.assertIn("AH cut 5% (default)", text)

    def test_mcp_tool_listed_and_mapped(self):
        self.assertIn("craft_profit", mcp_server.TOOLS)
        argv = mcp_server.TOOLS["craft_profit"][2]({"profession": "Cooking", "limit": 5})
        self.assertEqual(argv, ["craft", "--profit", "Cooking", "--limit", "5"])

    def test_store_migration_adds_output_qty_and_rereads_saved_variables(self):
        old = os.path.join(self.t, "old.db")
        c = sqlite3.connect(old)
        c.executescript("CREATE TABLE recipes (char_key TEXT NOT NULL, profession TEXT NOT NULL, recipe_key TEXT NOT NULL,"
                        " recipe_id INTEGER, name TEXT, difficulty INTEGER, skill_ups INTEGER, output_item INTEGER,"
                        " reagents_json TEXT, scanned_at INTEGER, PRIMARY KEY (char_key, profession, recipe_key));"
                        "CREATE TABLE ingest_runs (id INTEGER PRIMARY KEY, started_at INTEGER, finished_at INTEGER,"
                        " source_path TEXT, kind TEXT, sha256 TEXT, size INTEGER, status TEXT, chars INTEGER,"
                        " events_new INTEGER, events_dup INTEGER, error TEXT);"
                        "INSERT INTO ingest_runs (kind, sha256, status) VALUES ('sv', 'abc', 'ok');")
        c.commit(); c.close()
        con = store.connect(old)
        cols = [r[1] for r in con.execute("PRAGMA table_info(recipes)")]
        self.assertIn("output_qty", cols)
        self.assertEqual(con.execute("SELECT status FROM ingest_runs").fetchone()[0], "ok-pre-0.8")
        con.close()
        con = store.connect(old)  # second open: no-op
        self.assertEqual(con.execute("SELECT status FROM ingest_runs").fetchone()[0], "ok-pre-0.8")
        con.close()

    def test_ingest_keeps_the_craft_quantity(self):
        sv = os.path.join(fsenv.FIX, "sv_v5.lua")
        con = store.connect(os.path.join(self.t, "ing.db"))
        store.ingest_sv_file(con, sv)
        rows = con.execute("SELECT output_qty FROM recipes WHERE recipe_id IS NOT NULL").fetchall()
        con.close()
        if rows:
            self.assertTrue(all(r[0] in (None, 1) or r[0] > 0 for r in rows))

    def test_cli_route(self):
        from foreverscribe import cli
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cli.main(["craft", "--profit", "--help"])
        self.assertEqual(rc, 0)
        self.assertIn("Cost to craft", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
