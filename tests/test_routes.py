"""v0.5: NPC sightings (ingest, `way` preferring them over Wowhead, disagreement, shared export without PII) and
routes (route add/write, the slot file the addon loads, local/folder/http delivery, the sync agent's validator).
Wowhead is stubbed with the tooltip shapes from test_waypoints.py, so everything runs offline."""

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

ROOT, FIX = fsenv.ROOT, fsenv.FIX
sys.path.insert(0, ROOT)
from foreverscribe import auth, npcs as NP, routes as RT, store, waypoints as WP  # noqa: E402
from test_waypoints import fake_search, fake_tip  # noqa: E402

LUA = fsenv.find_lua()
SYNC = os.path.join(ROOT, "installers", "macos", "foreverscribe-sync.sh")
SLOTS = ["ForeverScribe_Route%02d" % i for i in range(1, 11)]


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Sandbox(unittest.TestCase):
    """A data dir + config per test, with the v0.5 fixture (sv_v5.lua: three NPC sightings) as the only source."""

    fixture = "sv_v5.lua"

    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="fs-v5-", dir=os.environ.get("TMPDIR"))
        self.data = os.path.join(self.t, "data")
        self.inbox = os.path.join(self.t, "inbox", "Account", "TESTACCT", "SavedVariables")
        os.makedirs(self.inbox)
        if self.fixture:
            shutil.copy(os.path.join(FIX, self.fixture), os.path.join(self.inbox, "ForeverScribe.lua"))
        self.cfg = os.path.join(self.t, "config.toml")
        self.write_cfg()
        self.saved_env = dict(os.environ)
        os.environ.update(FOREVERSCRIBE_CONFIG=self.cfg, FOREVERSCRIBE_SOURCES=os.path.join(self.t, "inbox"))
        os.environ.pop("FOREVERSCRIBE_DATA", None)
        self.saved_fetch = dict(WP.FETCH)
        WP.FETCH.update(tooltip=fake_tip, search=fake_search)
        self.saved_char = WP.character
        WP.character = lambda char=None: {}
        NP._SHARED = None
        self.saved_shared = NP.SHARED
        NP.SHARED = os.path.join(self.t, "shared.json")

    def write_cfg(self, transport='mode = "local"', wow=""):
        with open(self.cfg, "w") as f:
            f.write('data_dir = "%s"\n[transport]\n%s\n[wow]\ndir = "%s"\n' % (self.data, transport, wow))

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_env)
        WP.FETCH.update(self.saved_fetch)
        WP.character = self.saved_char
        NP.SHARED = self.saved_shared
        NP._SHARED = None
        shutil.rmtree(self.t, ignore_errors=True)

    def run_main(self, fn, argv):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = fn(argv)
        return rc, buf.getvalue()


class Sightings(Sandbox):
    def test_ingest_fills_npc_sightings(self):
        con = store.connect(os.path.join(self.data, "forever.db"))
        try:
            store.ingest_all(con, [os.path.join(self.t, "inbox")])
            rows = {r["npc_id"]: dict(r) for r in con.execute("SELECT * FROM npc_sightings")}
        finally:
            con.close()
        self.assertEqual(set(rows), {2327, 5150, 990001})
        s = rows[2327]
        self.assertEqual((s["map_id"], s["name"], s["subtitle"], s["count"], s["kind"]), (1453, "Shaina Fuller", "First Aid Trainer", 2, "gossip"))
        self.assertAlmostEqual(s["x"], 52.64, places=2)
        self.assertEqual(s["zone"], "Stormwind City")
        self.assertIsNone(s["subzone"], "empty subzone not stored")

    def test_older_file_never_rolls_a_sighting_back(self):
        con = store.connect(os.path.join(self.data, "forever.db"))
        try:
            store._store_npcs(con, "R:C", {"1:1453": {"id": 1, "map": 1453, "x": 10, "y": 10, "n": 3, "t": 2000}}, 1)
            store._store_npcs(con, "R:C", {"1:1453": {"id": 1, "map": 1453, "x": 90, "y": 90, "n": 1, "t": 1000}}, 2)
            store._store_npcs(con, "R:C", {"1:1453": {"id": "x", "map": 1453, "x": 900, "y": 1}}, 3)  # junk: skipped
            r = con.execute("SELECT x, count FROM npc_sightings").fetchall()
        finally:
            con.close()
        self.assertEqual([(row["x"], row["count"]) for row in r], [(10, 3)])

    def test_way_prefers_own_sighting_and_agrees_with_wowhead(self):
        r = WP.answer("npc=2327")
        self.assertTrue(r.get("confirmed"))
        self.assertEqual(r["mapID"], 1453)
        self.assertEqual((r["spots"][0]["x"], r["spots"][0]["y"]), (52.6, 44.9))
        self.assertIn("confirmed in game by Pixelpop", r["source"])
        self.assertIn("2 visits", r["source"])
        self.assertFalse(any("off" in n for n in r["notes"]), r["notes"])
        self.assertIn("/scribe way 52.6 44.9 Stormwind City Shaina Fuller", WP.render(dict(r, paste={"cmd": "/scribe way 52.6 44.9 Stormwind City Shaina Fuller", "why": ""})))

    def test_way_flags_wowhead_pin_far_off(self):
        r = WP.answer("npc=5150")
        self.assertTrue(r.get("confirmed"))
        self.assertGreater(r["wowhead_off_yards"], 25)
        self.assertTrue(any(re.search(r"Wowhead's pin is ~\d+ yd off", n) for n in r["notes"]), r["notes"])
        self.assertIn("1455,0.501,0.502", r["paste"]["cmd"])

    def test_way_by_name_without_wowhead(self):
        r = WP.answer("Quartermaster Vell")  # Wowhead search knows nothing; the game does
        self.assertNotIn("error", r)
        self.assertEqual((r["mapID"], r["spots"][0]["x"]), (1429, 44.0))
        self.assertTrue(any("location from the game" in n or "Wowhead lookup failed" in n for n in r["notes"]), r["notes"])
        r2 = WP.answer("supplies elwynn forest")  # by <subtitle> + zone words
        self.assertEqual(r2.get("id"), 990001)

    def test_wowhead_npc_lookup_shows_in_game_location(self):
        from foreverscribe import wowhead as WH
        saved = WH.tooltip
        WH.tooltip = lambda kind, eid, flavor="forever": fake_tip(kind, eid, flavor)
        try:
            rc, out = self.run_main(WH.main, ["npc", "5150"])
        finally:
            WH.tooltip = saved
        self.assertIn("location: Ironforge 50.1, 50.2 (uiMapID 1455) — confirmed in game", out)
        self.assertRegex(out, r"Wowhead's pin is ~\d+ yd off")

    def test_npcs_listing_and_disagree(self):
        rc, out = self.run_main(NP.main, [])
        self.assertEqual(rc, 0)
        self.assertIn("3 NPCs met in game", out)
        self.assertIn("Shaina Fuller <First Aid Trainer> (npc=2327) — Stormwind City 52.6, 44.9; 2 visits", out)
        rc, out = self.run_main(NP.main, ["--disagree"])
        self.assertIn("Nissa Firestone", out)
        self.assertNotIn("Shaina Fuller", out, "agrees within 25 yd")
        self.assertRegex(out, r"Wowhead ~\d+ yd off")
        rc, out = self.run_main(NP.main, ["--json", "nissa"])
        self.assertEqual(json.loads(out)["npcs"][0]["npcID"], 5150)

    def test_shared_file_used_after_personal_and_before_wowhead(self):
        NP.write_json(NP.SHARED, NP.document([{"npcID": 240, "name": "Marshal Dughan", "mapID": 1429, "x": 41.9, "y": 65.6,
                                               "count": 7, "lastSeen": "2026-11-01"}]))
        r = WP.answer("npc=240")
        self.assertEqual((r["spots"][0]["x"], r["spots"][0]["y"]), (41.9, 65.6))
        self.assertIn("ForeverScribe shared sightings (7", r["source"])
        r = WP.answer("npc=2327")  # personal still wins over shared
        self.assertIn("confirmed in game", r["source"])

    def test_export_shared_has_no_personal_data(self):
        out = os.path.join(self.t, "export.json")
        rc, text = self.run_main(NP.main, ["--export-shared", out])
        self.assertEqual(rc, 0)
        raw = read(out)
        doc = json.loads(raw)
        self.assertEqual(len(doc["npcs"]), 3)
        for e in doc["npcs"]:
            self.assertEqual(set(e), {"npcID", "name", "mapID", "x", "y", "count", "lastSeen"})
            self.assertRegex(e["lastSeen"], r"^\d{4}-\d\d-\d\d$")
        for secret in ("Pixelpop", "Forever-Test", "TESTACCT", "Thelsamar", "gossip", "First Aid Trainer", self.t):
            self.assertNotIn(secret, raw)
        self.assertNotRegex(raw, r"\b1763\d{6}\b", "no timestamps, only dates")
        # merge into the repo-style file: same spot within 5 yd adds up, a new NPC is appended
        target = os.path.join(self.t, "npc-locations.json")
        NP.write_json(target, NP.document([{"npcID": 2327, "name": "Shaina Fuller", "mapID": 1453, "x": 52.7, "y": 44.9,
                                            "count": 4, "lastSeen": "2026-10-01"}]))
        rc, _ = self.run_main(NP.main, ["--merge", target, "--from", out])
        merged = {(e["npcID"], e["mapID"]): e for e in json.loads(read(target))["npcs"]}
        self.assertEqual(merged[(2327, 1453)]["count"], 6)
        self.assertEqual(len(merged), 3)

    def test_repo_shared_file_starts_empty_and_valid(self):
        doc = json.loads(read(os.path.join(ROOT, "data", "npc-locations.json")))
        self.assertEqual(doc["format"], 1)
        self.assertEqual(doc["npcs"], [])


class Routes(Sandbox):
    def make_wow(self):
        wow = os.path.join(self.t, "wow")
        addons = os.path.join(wow, "Interface", "AddOns")
        os.makedirs(addons)
        for s in SLOTS:
            shutil.copytree(os.path.join(ROOT, "addon", s), os.path.join(addons, s))
        os.makedirs(os.path.join(wow, "WTF", "Account"))
        return wow, addons

    def build(self):
        self.assertEqual(self.run_main(RT.main, ["add", "npc=2327"])[0], 0)
        self.assertEqual(self.run_main(RT.main, ["add", "--title", "Bank", "--radius", "25", "60", "50", "Stormwind", "City"])[0], 0)
        rc, out = self.run_main(RT.main, ["add-json", json.dumps([{"title": 'Flight "master" | x', "mapID": 1453, "x": 70.9, "y": 72.5}])])
        self.assertEqual(rc, 0, out)
        d = RT.load()
        self.assertEqual([s["title"] for s in d["stops"]], ["Shaina Fuller", "Bank", "Flight master x"])
        self.assertEqual(d["stops"][0]["source"][:17], "confirmed in game")
        self.assertEqual(d["stops"][1]["r"], 25)

    def test_route_editing_and_validation(self):
        self.build()
        self.assertEqual(self.run_main(RT.main, ["move", "3", "1"])[0], 0)
        self.assertEqual(RT.load()["stops"][0]["title"], "Flight master x")
        self.assertEqual(self.run_main(RT.main, ["remove", "1"])[0], 0)
        self.assertEqual(len(RT.load()["stops"]), 2)
        rc, out = self.run_main(RT.main, ["add-json", '[{"mapID": 1453, "x": 120, "y": 5}]'])
        self.assertEqual(rc, 2)
        self.assertIn("0-100", out)
        rc, out = self.run_main(RT.main, ["add", "npc=5024"])  # Wowhead has no position: no stop
        self.assertEqual(rc, 2)
        rc, out = self.run_main(RT.main, ["write"])  # local mode, no WoW folder configured
        self.assertEqual(rc, 2)
        self.assertIn("nowhere to write", out)

    def test_local_write_rewrites_every_slot_and_the_addon_loads_it(self):
        wow, addons = self.make_wow()
        self.write_cfg('mode = "local"', wow)
        self.build()
        rc, out = self.run_main(RT.main, ["write", "--name", "Errands"])
        self.assertEqual(rc, 0, out)
        self.assertIn("10 route slots", out)
        self.assertIn("/fs go", out)
        texts = {read(os.path.join(addons, s, "Route.lua")) for s in SLOTS}
        self.assertEqual(len(texts), 1)
        text = texts.pop()
        self.assertIn('name = "Errands"', text)
        self.assertNotIn('"master"', text)
        self.assertNotIn("|", text.split("\n", 2)[2])
        if not LUA:
            self.skipTest("no Lua 5.1 (tools/get_lua.sh)")
        r = subprocess.run([LUA, os.path.join(ROOT, "tests", "lua", "route_e2e.lua"), addons], capture_output=True, text=True, cwd=ROOT)
        got = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual((got["rev"], got["name"], got["stops"], got["i"], got["errors"]), (RT.load()["rev"], "Errands", 3, 1, 0), r.stdout + r.stderr)
        self.assertEqual(got["waypoint"]["map"], 1453)
        self.assertAlmostEqual(got["waypoint"]["x"], 0.526, places=3)
        # status shows it was written; nothing fetched it (local mode)
        rc, out = self.run_main(RT.main, ["status"])
        self.assertIn("Errands", out)

    def sync(self, wow, support, folder="", url="", key_id=""):
        with open(os.path.join(support, "game.conf"), "w") as fh:
            fh.write("KEY_ID=%s\n" % key_id)
        env = dict(os.environ, HOME=os.path.join(self.t, "home"), FOREVERSCRIBE_SUPPORT=support, FOREVERSCRIBE_WOW_DIR=wow,
                   FOREVERSCRIBE_DEST=folder, FOREVERSCRIBE_PUSH_URL=url, FOREVERSCRIBE_SYNC_SETTLE="0.1", FOREVERSCRIBE_PUSH_TRIES="1")
        return subprocess.run(["bash", SYNC, "-v"], env=env, capture_output=True, text=True, timeout=60).stdout

    def test_folder_transport_sync_agent_copies_into_slots_and_rejects_code(self):
        wow, addons = self.make_wow()
        folder = os.path.join(self.t, "synced")
        self.write_cfg('mode = "folder"\nfolder = "%s"' % folder)
        self.build()
        rc, out = self.run_main(RT.main, ["write"])
        self.assertEqual(rc, 0, out)
        src = os.path.join(folder, "_route", "Route.lua")
        self.assertTrue(os.path.isfile(src))
        support = os.path.join(self.t, "support")
        os.makedirs(support)
        log = self.sync(wow, support, folder=folder)
        self.assertIn("written to 10 slots: press /fs go", log)
        self.assertEqual(read(os.path.join(addons, SLOTS[4], "Route.lua")), read(src))
        self.assertNotIn("press /fs go", self.sync(wow, support, folder=folder), "same rev: quiet")
        # a tampered file (code in it) is never copied into the game
        good = read(src)
        with open(src, "w") as f:
            f.write(good.replace('\tname = "Route",', '\tname = "x" .. os.exit(),'))
        log = self.sync(wow, support, folder=folder)
        self.assertIn("ignored: not a ForeverScribe route slot file", log)
        self.assertEqual(read(os.path.join(addons, SLOTS[0], "Route.lua")), good)
        # SavedVariables shipping is untouched by the route file in the same folder (it isn't ingested)
        self.assertEqual([k for k, _ in store.discover([folder])], [])

    def test_http_transport_receiver_serves_route_to_signed_sync_agent_only(self):
        wow, addons = self.make_wow()
        port = free_port()
        with open(self.cfg, "w") as f:
            f.write('data_dir = "%s"\n[transport]\nmode = "http"\n[receiver]\nbind = "127.0.0.1"\nport = %d\n' % (self.data, port))
        env = dict(os.environ, PYTHONPATH=ROOT)
        code = subprocess.run([sys.executable, "-m", "foreverscribe", "pair", "--name", "test-pc", "--code-only"], env=env, cwd=ROOT,
                              capture_output=True, text=True, check=True).stdout.strip()
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
            # nothing written yet: 204, slots stay empty
            self.assertNotIn("press /fs go", self.sync(wow, support, url=url, key_id=p["key_id"]))
            self.build()
            rc, out = self.run_main(RT.main, ["write"])
            self.assertEqual(rc, 0, out)
            self.assertIn("fetches it within ~30 s", out)
            # unsigned (even from an allowed address) is refused
            req = urllib.request.Request(url + "/v1/route", data=b"route", method="POST")
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(req, timeout=5)
            self.assertEqual(cm.exception.code, 403)
            log = self.sync(wow, support, url=url, key_id=p["key_id"])
            self.assertIn("from receiver written to 10 slots", log)
            rev = RT.load()["rev"]
            self.assertIn('rev = "%s"' % rev, read(os.path.join(addons, SLOTS[9], "Route.lua")))
            pk = json.loads(read(os.path.join(self.data, "route", "pickup.json")))
            self.assertEqual(pk["rev"], rev)
            self.assertNotIn("press /fs go", self.sync(wow, support, url=url, key_id=p["key_id"]), "304: unchanged")
            rc, out = self.run_main(RT.main, ["status"])
            self.assertIn("game computer fetched rev %s" % rev, out)
        finally:
            rx.terminate()
            rx.wait()

    def test_mcp_route_and_npcs_tools(self):
        env = dict(os.environ, PYTHONPATH=ROOT)
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                                                            "clientInfo": {"name": "t", "version": "0"}}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "route", "arguments": {
                    "action": "add_stops", "stops": [{"title": "Goldshire", "mapID": 1429, "x": 42.1, "y": 65.3}]}}},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "route", "arguments": {"action": "show"}}},
                {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "npcs", "arguments": {"search": "shaina"}}}]
        r = subprocess.run([os.path.join(ROOT, "bin", "foreverscribe"), "mcp"], input="\n".join(json.dumps(m) for m in msgs) + "\n",
                           env=env, capture_output=True, text=True, timeout=60)
        by = {m["id"]: m for m in (json.loads(l) for l in r.stdout.splitlines() if l.strip())}
        names = {t["name"] for t in by[2]["result"]["tools"]}
        self.assertTrue({"route", "npcs"} <= names)
        self.assertIn("Goldshire — Elwynn Forest 42.1, 65.3", by[4]["result"]["content"][0]["text"])
        self.assertIn("Shaina Fuller", by[5]["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
