"""v0.7: Polestar + forever-db.

- Polestar's SavedVariables (account PolestarDB, per-character PolestarCharDB) parse into `foreverscribe guide`, merged
  with what the addon read through Polestar's API (fixture sv_v7.lua); a changed or broken file never fails ingestion.
- Per-character files are synced by the macOS agent (http push to the receiver and folder copy).
- forever-db: a synthetic release built from real rows (spawn world yards + map frames) converts to Forever map
  percent matching known in-game/Wowhead points; a tampered download is refused; its own corrections apply.
- The location resolver: trust order, agreement, "⚠ uncertain" with both spots, multi-spawn nearest first.
- Correction drafts in forever-db's corrections/npcs.json format, written to files only.
Everything runs offline: Wowhead and forever-db are stubbed.
"""
import hashlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT, FIX = fsenv.ROOT, fsenv.FIX
sys.path.insert(0, ROOT)
from foreverscribe import (auth, foreverdb as FD, npcs as NP, polestar as PS, queries as Q, resolve as R,  # noqa: E402
                           store, upstream as UP, waypoints as WP)
from test_routes import Sandbox, free_port  # noqa: E402
from test_waypoints import fake_search, fake_tip  # noqa: E402

SYNC = os.path.join(ROOT, "installers", "macos", "foreverscribe-sync.sh")
PFIX = os.path.join(FIX, "polestar")
REALM, CHAR = "Forever-Test", "Pixelpop"

# Real forever-db 2026.11.1 rows (spawn.jsonl / ui_map.jsonl / npc.jsonl) for three NPCs whose Forever position is
# known from Wowhead Forever (tests/test_waypoints.py TIPS) and the in-game fixture: the conversion must land there.
UI_MAP = [
    {"bottom": 825, "left": 3033.333, "map": 0, "right": -1485.417, "top": 3837.5, "ui_map": 1420},
    {"bottom": -10254.166, "left": 1535.417, "map": 0, "right": -1935.417, "top": -7939.583, "ui_map": 1429},
    {"bottom": -9154.17, "left": 1722.92, "map": 0, "right": -14.584, "top": -7995.83, "ui_map": 1453},
    {"bottom": -5096.846, "left": -713.591, "map": 0, "right": -1504.216, "top": -4569.241, "ui_map": 1455},
]
NPC = [{"id": 240, "name": "Marshal Dughan", "level_min": 25, "level_max": 25, "rank": 0, "faction_template": 12},
       {"id": 1738, "name": "Deathguard Terrence", "level_min": 30, "level_max": 30, "rank": 0, "faction_template": 68},
       {"id": 2327, "name": "Shaina Fuller", "subname": "First Aid Trainer", "level_min": 35, "level_max": 35, "rank": 0,
        "faction_template": 12},
       {"id": 5150, "name": "Nissa Firestone", "subname": "First Aid Trainer", "level_min": 35, "level_max": 35, "rank": 0,
        "faction_template": 55},
       {"id": 3649, "name": "Thundris Windweaver", "level_min": 25, "level_max": 25, "rank": 0, "faction_template": 80},
       {"id": 3691, "name": "Raene Wolfrunner", "level_min": 30, "level_max": 30, "rank": 0, "faction_template": 80},
       {"id": 990002, "name": "Wandering Peddler", "level_min": 10, "level_max": 10, "rank": 0, "faction_template": 12}]
SPAWN = [{"id": 240, "kind": "npc", "map": 0, "n": 1, "x": -9465.5, "y": 74.0, "z": 56.8},
         {"id": 1738, "kind": "npc", "map": 0, "n": 1, "x": 2134.0, "y": 165.5, "z": 38.0},
         {"id": 2327, "kind": "npc", "map": 0, "n": 1, "x": -8513.5, "y": 802.0, "z": 106.6},
         {"id": 5150, "kind": "npc", "map": 0, "n": 1, "x": -4876.5, "y": -1149.0, "z": 512.5},
         {"id": 3649, "kind": "npc", "map": 1, "n": 1, "x": 6581.0, "y": 492.0},
         {"id": 3691, "kind": "npc", "map": 1, "n": 1, "x": 2767.0, "y": -412.0},
         # a peddler with two spawns in Elwynn: one near Goldshire, one far east
         {"id": 990002, "kind": "npc", "map": 0, "n": 1, "x": -9460.0, "y": 70.0},
         {"id": 990002, "kind": "npc", "map": 0, "n": 2, "x": -9300.0, "y": -1200.0}]
CORR_NPCS = {"1738": {"addSpawns": {"1420": {"f": "e", "pts": [[61.4, 53.4]]}},
                      "source": {"kind": "in-game-check", "ref": "player report"}, "note": "Deathguard Terrence ..."}}


def jsonl(rows):
    return ("\n".join(json.dumps(r, sort_keys=True, separators=(",", ":")) for r in rows) + "\n").encode()


class FakeRelease:
    """Serve a synthetic forever-db release through foreverdb.FETCH, with matching pinned hashes."""

    def __init__(self, tamper=None):
        self.files = {"ui_map": jsonl(UI_MAP), "npc": jsonl(NPC), "object": b"", "spawn": jsonl(SPAWN)}
        self.corr = {"npcs": json.dumps(CORR_NPCS).encode(), "objects": b"{}"}
        self.urls = []
        self.tamper = tamper

    def __enter__(self):
        self.saved = (dict(FD.TABLES), dict(FD.CORRECTIONS), dict(FD.FETCH), os.environ.get("FOREVERSCRIBE_FOREVERDB"),
                      os.environ.get("FOREVERSCRIBE_FOREVERDB_DIR"))
        FD.TABLES.clear()
        FD.TABLES.update({k: hashlib.sha256(v).hexdigest() for k, v in self.files.items()})
        FD.CORRECTIONS.clear()
        FD.CORRECTIONS.update({k: hashlib.sha256(v).hexdigest() for k, v in self.corr.items()})
        self.dir = tempfile.mkdtemp(prefix="fs-fdb-", dir=os.environ.get("TMPDIR"))
        os.environ["FOREVERSCRIBE_FOREVERDB_DIR"] = self.dir
        os.environ.pop("FOREVERSCRIBE_FOREVERDB", None)

        def get(url, timeout=60):
            self.urls.append(url)
            name = url.rsplit("/", 1)[-1]
            if "/corrections/" in url:
                return self.corr[name[:-5]]
            data = self.files[name[:-6]]
            return data + b"x" if self.tamper == name[:-6] else data
        FD.FETCH["get"] = get
        return self

    def __exit__(self, *a):
        FD.TABLES.clear()
        FD.TABLES.update(self.saved[0])
        FD.CORRECTIONS.clear()
        FD.CORRECTIONS.update(self.saved[1])
        FD.FETCH.update(self.saved[2])
        for k, v in (("FOREVERSCRIBE_FOREVERDB", self.saved[3]), ("FOREVERSCRIBE_FOREVERDB_DIR", self.saved[4])):
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.dir, ignore_errors=True)


class ForeverDB(unittest.TestCase):
    def test_world_yards_convert_to_known_forever_points(self):
        with FakeRelease() as rel:
            known = {2327: (1453, 52.8, 44.8), 240: (1429, 42.2, 65.8), 5150: (1455, 54.8, 58.4)}  # Wowhead Forever
            for nid, (mid, x, y) in known.items():
                r = FD.locate("npc", nid)
                self.assertEqual(r["mapID"], mid, nid)
                self.assertAlmostEqual(r["spots"][0]["x"], x, delta=0.5, msg=nid)
                self.assertAlmostEqual(r["spots"][0]["y"], y, delta=0.5, msg=nid)
            self.assertEqual(len([u for u in rel.urls if "/data/" in u]), 4, "each table downloaded once")
            FD.locate("npc", 240)
            self.assertEqual(len([u for u in rel.urls if "/data/" in u]), 4, "cached after the first download")
            self.assertTrue(all("data-v" + FD.RELEASE in u for u in rel.urls if "/data/" in u), "pinned release tag")
            self.assertEqual(FD.find(["first", "aid", "trainer"])[0]["subtitle"], "First Aid Trainer")

    def test_overlapping_zone_frames_pick_the_zone_that_holds_it(self):
        # Astranaar also lies on Stonetalon's frame edge, Auberdine on Felwood's: the most central frame wins
        with FakeRelease():
            r = FD.locate("npc", 3691)
            self.assertEqual((r["zone"], r["spots"][0]["x"], r["spots"][0]["y"]), ("Ashenvale", 36.6, 49.6))  # Wowhead 36.4,49.6
            r = FD.locate("npc", 3649)
            self.assertEqual(r["zone"], "Darkshore")
            r = FD.locate("npc", 3691, prefer=1453)
            self.assertEqual(r["zone"], "Ashenvale", "a hint for a map that doesn't hold it is ignored")

    def test_corrections_replace_the_map_points_in_the_classic_frame(self):
        with FakeRelease():
            r = FD.locate("npc", 1738)
            self.assertEqual(r["mapID"], 1420, "forever-db's correction moves him to Tirisfal")
            self.assertEqual((r["spots"][0]["x"], r["spots"][0]["y"]), WP.era_to_forever(1420, 61.4, 53.4))
            self.assertEqual(r["spots"][0]["frames"], ["forever-db correction"])

    def test_tampered_download_is_refused_and_not_retried_at_once(self):
        with FakeRelease(tamper="spawn") as rel:
            self.assertIsNone(FD.locate("npc", 240))
            self.assertIn("sha256", FD.status()["last_failure"])
            n = len(rel.urls)
            self.assertIsNone(FD.locate("npc", 240))
            self.assertEqual(len(rel.urls), n, "no retry storm after a failure")

    def test_nothing_of_forever_db_is_committed(self):
        tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True).stdout.split()
        self.assertFalse([f for f in tracked if f.endswith(".jsonl") or "forever-db" in f], "GPL tables stay out of the repo")
        notice = open(os.path.join(ROOT, "NOTICE.md"), encoding="utf-8").read()
        self.assertIn("forever-db", notice)
        self.assertIn("GPL-3.0", notice)


class Resolver(Sandbox):
    """Sightings from sv_v5.lua: Shaina Fuller (agrees everywhere), Nissa Firestone (in-game spot far from both
    databases), Quartermaster Vell (only the game knows him)."""

    def test_trust_order_and_agreement(self):
        with FakeRelease():
            r = WP.answer("npc=2327")
            self.assertEqual(r["agreement"]["using"], "sighting")
            self.assertEqual(r["agreement"]["status"], "agree")
            self.assertEqual([s["key"] for s in r["sources"]], ["sighting", "foreverdb", "wowhead"])
            self.assertNotIn("uncertain", WP.render(r))

    def test_uncertain_when_databases_disagree_and_no_sighting(self):
        tips = dict(fake_tip=None)

        def tip(kind, eid, flavor="forever"):
            if int(eid) == 240 and flavor == "forever":  # Wowhead puts Dughan across Goldshire
                return {"name": "Marshal Dughan", "tooltip": "", "map": {"zone": 12, "coords": {"0": [[46.0, 62.0]]}}}
            return fake_tip(kind, eid, flavor)
        WP.FETCH["tooltip"] = tip
        with FakeRelease():
            r = WP.answer("npc=240")
            text = WP.render(r)
        self.assertTrue(r.get("uncertain"))
        self.assertEqual(r["agreement"]["using"], "foreverdb", "forever-db outranks Wowhead")
        self.assertEqual((r["mapID"], r["spots"][0]["x"]), (1429, 42.1))
        ru = r["agreement"]["runner_up"]
        self.assertEqual(ru["key"], "wowhead")
        self.assertGreater(ru["yards"], 25)
        self.assertIn("⚠ uncertain: forever-db and Wowhead Forever disagree (%d yd apart)" % ru["yards"], text)
        self.assertIn("Wowhead Forever puts it at Elwynn Forest 46, 62", text)
        self.assertIn("This command uses forever-db's spot", text)
        self.assertIn("help fix: talk to Marshal Dughan once", text)
        self.assertIn("foreverscribe correction draft 240", text)
        self.assertIn("1429,0.421,0.659", r["paste"]["cmd"])

    def test_own_sighting_wins_and_offers_a_correction(self):
        with FakeRelease():
            r = WP.answer("npc=5150")
            text = WP.render(r)
        self.assertEqual(r["agreement"]["status"], "own-sighting-disagrees")
        self.assertFalse(r.get("uncertain"), "the player's own sighting is not uncertain")
        self.assertIn("1455,0.501,0.502", r["paste"]["cmd"])
        self.assertIn("forever-db is", text)
        self.assertIn("foreverscribe correction draft 5150", text)

    def test_multi_spawn_nearest_first(self):
        saved = WP.character
        WP.character = lambda char=None: {"mapID": 1429, "x": 80.0, "y": 60.0}
        try:
            with FakeRelease():
                r = WP.answer("npc=990002")
        finally:
            WP.character = saved
        self.assertEqual(r["agreement"]["using"], "foreverdb")
        self.assertEqual(len(r["spots"]), 2)
        self.assertGreater(r["spots"][0]["x"], 60, "the eastern spawn, nearer the player, comes first")

    def test_forever_db_down_falls_back_to_wowhead_without_error(self):
        os.environ["FOREVERSCRIBE_FOREVERDB"] = "off"
        r = WP.answer("npc=240")
        self.assertEqual(r["agreement"]["using"], "wowhead")
        self.assertEqual(r["agreement"]["status"], "single-source")


class Corrections(Sandbox):
    def setUp(self):
        super().setUp()
        self.up = os.path.join(self.t, "upstream")
        os.environ["FOREVERSCRIBE_UPSTREAM_DIR"] = self.up

    def test_draft_in_forever_db_corrections_format(self):
        with FakeRelease():
            rc, out = self.run_main(UP.main, ["draft", "5150"])
        self.assertEqual(rc, 0, out)
        self.assertIn("Nothing was sent", out)
        one = json.load(open(os.path.join(self.up, "forever-db", "npc-5150.json")))
        e = one["5150"]
        self.assertEqual(set(e), {"addSpawns", "source", "note"})
        self.assertEqual(e["addSpawns"], {"1455": {"f": "l", "pts": [[50.1, 50.2]]}})
        self.assertIn(e["source"]["kind"], ("recording", "in-game-check", "client", "eg", "cmangos", "tdb", "questie",
                                            "pfquest", "factoruide"))
        self.assertRegex(e["source"]["ref"], r"\d{4}-\d\d-\d\d, client ")
        self.assertIn("Nissa Firestone (npc 5150) stands at Ironforge 50.1,50.2 (map 1455", e["note"])
        self.assertIn("forever-db has Ironforge 55.1,58.2", e["note"])
        self.assertNotIn("wowhead", e["note"].lower(), "forever-db notes cite in-game checks, never a website")
        batch = json.load(open(os.path.join(self.up, "forever-db", "npcs.json")))
        self.assertEqual(list(batch), ["5150"])
        wh = open(os.path.join(self.up, "wowhead", "npc-5150.txt")).read()
        self.assertIn("Ironforge 50.1, 50.2", wh)
        self.assertTrue(os.path.exists(os.path.join(self.up, "README.md")))

    def test_disagree_lists_and_drafts_only_what_is_off(self):
        with FakeRelease():
            rc, out = self.run_main(NP.main, ["--disagree"])
        self.assertIn("Nissa Firestone", out)
        self.assertIn("forever-db ~", out)
        self.assertNotIn("Shaina Fuller", out)
        self.assertIn("npc-5150.json", out)
        self.assertFalse(os.path.exists(os.path.join(self.up, "forever-db", "npc-2327.json")), "agreeing NPC: no draft")

    def test_no_sighting_no_draft(self):
        rc, out = self.run_main(UP.main, ["draft", "240"])
        self.assertEqual(rc, 3)
        self.assertIn("no sighting of 240 yet", out)

    def test_upstream_module_never_posts(self):
        src = open(os.path.join(ROOT, "foreverscribe", "upstream.py")).read()
        for bad in ("urlopen", "Request(", "requests", "subprocess", "gh ", "git push"):
            self.assertNotIn(bad, src)


class PolestarSV(Sandbox):
    fixture = "sv_v7.lua"

    def add_polestar(self, root=None):
        acct = os.path.join(root or os.path.join(self.t, "inbox", "Account", "TESTACCT"))
        shutil.copy(os.path.join(PFIX, "account.lua"), os.path.join(acct, "SavedVariables", "Polestar.lua"))
        cdir = os.path.join(acct, REALM, CHAR, "SavedVariables")
        os.makedirs(cdir, exist_ok=True)
        shutil.copy(os.path.join(PFIX, "char.lua"), os.path.join(cdir, "Polestar.lua"))
        return cdir

    def ingest(self):
        con = store.connect(os.path.join(self.data, "forever.db"))
        try:
            return store.ingest_all(con, [os.path.join(self.t, "inbox")], extra=("Polestar.lua",)), con
        except Exception:
            con.close()
            raise

    def test_parse_char_and_account(self):
        from foreverscribe import svparse
        c = PS.parse_char(svparse.parse_file(os.path.join(PFIX, "char.lua"))[0]["PolestarCharDB"])
        self.assertEqual(c["guide"], "forever/alliance/02-westfall")
        self.assertEqual(c["tabs"], ["forever/alliance/02-westfall", "forever/professions/first-aid"])
        g = c["guides"]["forever/alliance/02-westfall"]
        self.assertEqual((g["title"], g["ticked_goals"], g["skipped_steps"], g["skipped_goals"], g["viewing_step"]),
                         ("Westfall", 2, [7], 1, 12))
        self.assertEqual(c["finished_guides"], ["forever/alliance/01-elwynn-forest"])
        self.assertEqual(c["flight"]["to"], "Sentinel Hill, Westfall")
        self.assertEqual(c["flight_paths_known"], 2)
        self.assertEqual(c["unknown_fields"], ["someFutureField"])
        a = PS.parse_account(svparse.parse_file(os.path.join(PFIX, "account.lua"))[0]["PolestarDB"])
        self.assertEqual(a["packs_off"], ["community-pack"])

    def test_guide_merges_live_read_and_saved_file(self):
        self.add_polestar()
        res, con = self.ingest()
        try:
            ck = "%s:%s" % (REALM, CHAR)
            row = con.execute("SELECT scope, char_key, status FROM polestar_state WHERE scope='char'").fetchone()
            self.assertEqual(tuple(row), ("char", ck, "ok"))
            st = PS.state(con, ck)
            self.assertEqual(st["guide"]["title"], "Westfall")
            self.assertEqual((st["guide"]["step"], st["guide"]["steps"]), (11, 70))
            self.assertEqual(st["current_step"]["title"], "Sentinel Hill")
            self.assertEqual(st["current_step"]["goals"][1]["progress"], "3/15")
            self.assertEqual(st["travel"]["to"], "Gryan Stoutmantle")
            self.assertEqual(st["travel"]["next_leg"]["kind"], "taxi")
            self.assertEqual(st["saved"]["guides"]["forever/alliance/02-westfall"]["ticked_goals"], 2)
            text = PS.render(st)
            self.assertIn("guide: Westfall (forever/alliance/02-westfall) — step 11 of 70", text)
            self.assertIn("• Kill Defias Trappers (3/15)", text)
            hot = Q.summary(con, ck, mark=False)
            self.assertIn("Polestar: Westfall step 11/70 — Sentinel Hill: Hand in The People's Militia; Kill Defias "
                          "Trappers 3/15", hot)
        finally:
            con.close()

    def test_broken_or_changed_file_never_fails_ingestion(self):
        cdir = self.add_polestar()
        with open(os.path.join(cdir, "Polestar.lua"), "w") as f:
            f.write("PolestarCharDB = {\n\t[\"guide\"] = function() end,\n}\n")
        res, con = self.ingest()
        try:
            self.assertTrue(all(r["status"] in ("ok", "skipped") for r in res), res)
            row = con.execute("SELECT status, error FROM polestar_state WHERE scope='char'").fetchone()
            self.assertEqual(row[0], "unparsed")
            rows = con.execute("SELECT name FROM raw_files").fetchall()
            self.assertEqual(sorted(r[0] for r in rows), ["Polestar.lua", "Polestar.lua"], "both files kept")
            st = PS.state(con, "%s:%s" % (REALM, CHAR))
            self.assertEqual(st["guide"]["title"], "Westfall", "the live read still answers")
        finally:
            con.close()
        # a different shape (a list where a table was): read what can be read
        with open(os.path.join(cdir, "Polestar.lua"), "w") as f:
            f.write("PolestarCharDB = {\n\t[\"tabs\"] = \"oops\",\n\t[\"manual\"] = 5,\n\t[\"guide\"] = \"g/x\",\n}\n")
        res, con = self.ingest()
        try:
            row = con.execute("SELECT status, summary FROM polestar_state WHERE scope='char'").fetchone()
            self.assertEqual(row[0], "ok")
            self.assertEqual(json.loads(row[1])["guide"], "g/x")
        finally:
            con.close()

    def test_guide_cli_and_mcp(self):
        self.add_polestar()
        from foreverscribe import cli, mcp_server
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cli.main(["guide"])
        self.assertEqual(rc or 0, 0)
        self.assertIn("this step: Sentinel Hill", buf.getvalue())
        res = mcp_server.call_tool("guide", {})
        self.assertIn("Westfall", json.dumps(res))


class PerCharacterSync(unittest.TestCase):
    """The macOS sync agent ships WTF/Account/<acct>/<realm>/<char>/SavedVariables/Polestar.lua."""

    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="fs-pc-", dir=os.environ.get("TMPDIR"))
        self.acct = os.path.join(self.t, "wow", "WTF", "Account", "ACCT1")
        os.makedirs(os.path.join(self.acct, "SavedVariables"))
        shutil.copy(os.path.join(FIX, "sv_v7.lua"), os.path.join(self.acct, "SavedVariables", "ForeverScribe.lua"))
        self.realm = "Forever Test Realm"  # realm folders have spaces
        cdir = os.path.join(self.acct, self.realm, CHAR, "SavedVariables")
        os.makedirs(cdir)
        shutil.copy(os.path.join(PFIX, "char.lua"), os.path.join(cdir, "Polestar.lua"))
        with open(os.path.join(cdir, "Other.lua"), "w") as f:
            f.write("OtherDB = {}\n")
        self.support = os.path.join(self.t, "support")
        os.makedirs(self.support)
        self.data = os.path.join(self.t, "data")
        self.port = free_port()
        self.cfg = os.path.join(self.t, "config.toml")
        with open(self.cfg, "w") as f:
            f.write('data_dir = "%s"\n[transport]\nmode = "http"\n[receiver]\nbind = "127.0.0.1"\nport = %d\n' % (
                self.data, self.port))
        self.rx = None

    def tearDown(self):
        if self.rx:
            self.rx.terminate()
            self.rx.wait()
        shutil.rmtree(self.t, ignore_errors=True)

    def env(self):
        e = dict(os.environ, FOREVERSCRIBE_CONFIG=self.cfg, PYTHONPATH=ROOT)
        e.pop("FOREVERSCRIBE_DATA", None)
        return e

    def sync(self, push, folder, key_id=""):
        with open(os.path.join(self.support, "game.conf"), "w") as fh:
            fh.write("KEY_ID=%s\n" % key_id)
        env = dict(os.environ, HOME=os.path.join(self.t, "home"), FOREVERSCRIBE_SUPPORT=self.support,
                   FOREVERSCRIBE_WOW_DIR=os.path.join(self.t, "wow"),
                   FOREVERSCRIBE_DEST=os.path.join(self.t, "folder") if folder else "",
                   FOREVERSCRIBE_PUSH_URL=("http://127.0.0.1:%d" % self.port) if push else "",
                   FOREVERSCRIBE_SYNC_SETTLE="0.1", FOREVERSCRIBE_PUSH_TRIES="1")
        env.pop("FOREVERSCRIBE_EXTRA_SV", None)
        return subprocess.run(["bash", SYNC, "-v"], env=env, capture_output=True, text=True, timeout=60).stdout

    def test_folder_copy(self):
        out = self.sync(push=False, folder=True)
        dest = os.path.join(self.t, "folder", "ACCT1", self.realm, CHAR, "Polestar.lua")
        self.assertTrue(os.path.exists(dest), out)
        self.assertFalse(os.path.exists(os.path.join(os.path.dirname(dest), "Other.lua")))
        self.assertEqual(PS.char_from_path(dest, per_character=True), ("ACCT1", self.realm, CHAR))

    def test_http_push_to_receiver_and_ingest(self):
        code = subprocess.run([sys.executable, "-m", "foreverscribe", "pair", "--name", "t", "--code-only"], env=self.env(),
                              cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
        p = auth.decode_pairing(code)
        with open(os.path.join(self.support, "pairing.key"), "w") as fh:
            fh.write(p["key"])
        self.rx = subprocess.Popen([sys.executable, "-m", "foreverscribe", "receiver", "run"], env=self.env(), cwd=ROOT,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(80):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/v1/health" % self.port, timeout=1)
                break
            except Exception:
                time.sleep(0.1)
        out = self.sync(push=True, folder=False, key_id=p["key_id"])
        self.assertIn("pushed ACCT1/%s/%s/Polestar.lua" % (self.realm, CHAR), out)
        stored = os.path.join(self.data, "push", "Account", "ACCT1", self.realm, CHAR, "SavedVariables", "Polestar.lua")
        self.assertTrue(os.path.exists(stored), out)
        con = sqlite3.connect(os.path.join(self.data, "forever.db"))
        try:
            row = con.execute("SELECT scope, status FROM polestar_state").fetchone()
        finally:
            con.close()
        self.assertEqual(row, ("char", "ok"))
        again = self.sync(push=True, folder=False, key_id=p["key_id"])
        self.assertNotIn("pushed", again, "unchanged files are not pushed twice")
        # a traversal attempt is refused even when signed
        from foreverscribe import receiver
        self.assertFalse(receiver.CHARDIR_RE.match(".."))


if __name__ == "__main__":
    unittest.main()
