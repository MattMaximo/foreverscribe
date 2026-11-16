"""Companion tests. Run: /usr/bin/python3 -m unittest discover -s tests -v
Fixtures in tests/fixtures are produced by the Lua addon running in the simulated
client (tests/lua/test_addon.lua tests/fixtures), so these tests exercise the real
addon output format end to end.
"""

import io
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402,F401  (isolates config/data before the package loads)

ROOT = fsenv.ROOT
sys.path.insert(0, ROOT)

from foreverscribe import cli, queries as Q, store  # noqa: E402
from foreverscribe.svparse import SVParseError, parse_saved_variables  # noqa: E402

FIX = os.path.join(ROOT, "tests", "fixtures")
LUA = fsenv.find_lua()


def setUpModule():
    # Regenerate fixtures from the addon so they never drift from the Lua code.
    if LUA:
        subprocess.run([LUA, os.path.join(ROOT, "tests", "lua", "test_addon.lua"), FIX], check=True,
                       capture_output=True, cwd=ROOT)


class Tmp(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fs-test-", dir=os.environ.get("TMPDIR"))
        self.db = os.path.join(self.d, "forever.db")
        self.con = store.connect(self.db)

    def tearDown(self):
        self.con.close()
        shutil.rmtree(self.d, ignore_errors=True)

    def sv(self, name, account="ACCT1"):
        dest = os.path.join(self.d, "inbox", "sv", account)
        os.makedirs(dest, exist_ok=True)
        p = os.path.join(dest, "ForeverScribe.lua")
        shutil.copy(os.path.join(FIX, name), p)
        os.utime(p, None)
        return p

    def count(self, sql, *a):
        return self.con.execute(sql, a).fetchone()[0]


class ParserTests(unittest.TestCase):
    def test_client_format(self):
        text = '\nFoo = {\n\t["a"] = "x\\"y\\\\z\\n",\n\t[3] = -1.5e3,\n\t["t"] = true,\n\t{\n\t\t1, -- [1]\n\t}, -- [1]\n\t["h"] = 0x1F,\n}\nBar = nil\nBaz = "caf\\195\\169"\n'
        r = parse_saved_variables(text)
        self.assertEqual(r["Foo"]["a"], 'x"y\\z\n')
        self.assertEqual(r["Foo"][3], -1500.0)
        self.assertEqual(r["Foo"][1], [1])
        self.assertEqual(r["Foo"]["h"], 31)
        self.assertIsNone(r["Bar"])
        self.assertEqual(r["Baz"], "café")

    def test_array_vs_map(self):
        r = parse_saved_variables("X = { 5, 6, 7 }\nY = { [1] = 1, [3] = 3 }\nZ = {}")
        self.assertEqual(r["X"], [5, 6, 7])
        self.assertEqual(r["Y"], {1: 1, 3: 3})
        self.assertEqual(r["Z"], {})

    def test_comments_and_utf8(self):
        r = parse_saved_variables('--[[ header ]]\nX = { ["n"] = "Gnomeregan — ⚙" } -- tail')
        self.assertEqual(r["X"]["n"], "Gnomeregan — ⚙")

    def test_truncated_rejected(self):
        with open(os.path.join(FIX, "sv_v1.lua")) as fh:
            text = fh.read()
        for cut in (10, len(text) // 3, len(text) // 2, len(text) - 3):
            with self.assertRaises(SVParseError):
                parse_saved_variables(text[:cut])

    def test_fixture_roundtrip(self):
        with open(os.path.join(FIX, "sv_v2.lua")) as fh:
            r = parse_saved_variables(fh.read())
        chars = r["ForeverScribeDB"]["chars"]
        self.assertEqual(set(chars), {"Forever-Test:Pixelpop", "Forever-Test:Coilbyte"})


class IngestTests(Tmp):
    def test_dedup_across_reloads(self):
        p = self.sv("sv_v1.lua")
        r1 = store.ingest_sv_file(self.con, p)
        self.assertEqual(r1["status"], "ok")
        n1 = self.count("SELECT COUNT(*) FROM events")
        self.assertGreater(n1, 4)
        # same file again -> skipped by hash
        self.assertEqual(store.ingest_sv_file(self.con, p)["status"], "skipped")
        # later file (after /reload + relog) still contains the old events -> only new ones inserted
        p = self.sv("sv_v2.lua")
        r2 = store.ingest_sv_file(self.con, p)
        self.assertEqual(r2["events_dup"], n1)
        n2 = self.count("SELECT COUNT(*) FROM events")
        self.assertEqual(n2, n1 + r2["events_new"])
        self.assertEqual(self.count("SELECT COUNT(*) FROM events WHERE type='LEVEL_UP'"), 1)
        self.assertEqual(self.count("SELECT COUNT(DISTINCT event_id) FROM events"), n2)

    def test_restart_reopen_db(self):
        store.ingest_sv_file(self.con, self.sv("sv_v1.lua"))
        n = self.count("SELECT COUNT(*) FROM events")
        self.con.close()
        self.con = store.connect(self.db)
        self.assertEqual(store.ingest_sv_file(self.con, self.sv("sv_v1.lua"))["status"], "skipped")
        # touched file with identical bytes is still a no-op
        self.assertEqual(self.count("SELECT COUNT(*) FROM events"), n)

    def test_truncated_file_does_not_corrupt(self):
        store.ingest_sv_file(self.con, self.sv("sv_v1.lua"))
        before = self.count("SELECT COUNT(*) FROM events")
        snap_before = self.count("SELECT COUNT(*) FROM snapshots")
        p = self.sv("sv_v2.lua")
        with open(p, "rb") as fh:
            data = fh.read()
        with open(p, "wb") as fh:
            fh.write(data[: len(data) // 2])  # iCloud mid-sync / crash mid-write
        r = store.ingest_sv_file(self.con, p)
        self.assertEqual(r["status"], "error")
        self.assertEqual(self.count("SELECT COUNT(*) FROM events"), before)
        self.assertEqual(self.count("SELECT COUNT(*) FROM snapshots"), snap_before)
        # the error is visible to freshness
        f = Q.freshness(self.con, "Forever-Test:Pixelpop")
        self.assertIn("last_ingest_error", f)
        # once the complete file lands, it ingests
        shutil.copy(os.path.join(FIX, "sv_v2.lua"), p)
        self.assertEqual(store.ingest_sv_file(self.con, p)["status"], "ok")

    def test_multi_character(self):
        store.ingest_sv_file(self.con, self.sv("sv_v2.lua"))
        rows = {r["char_key"]: r for r in Q.characters(self.con)}
        self.assertEqual(rows["Forever-Test:Pixelpop"]["class"], "MAGE")
        self.assertEqual(rows["Forever-Test:Pixelpop"]["level"], 24)
        self.assertEqual(rows["Forever-Test:Coilbyte"]["class"], "WARLOCK")
        self.assertEqual(rows["Forever-Test:Coilbyte"]["account"], "ACCT1")
        mage = Q.professions(self.con, "Forever-Test:Pixelpop")["professions"]
        lock = Q.professions(self.con, "Forever-Test:Coilbyte")["professions"]
        self.assertEqual({p["name"] for p in mage}, {"Tailoring", "First Aid"})
        self.assertEqual({p["name"]: p["rank"] for p in lock}, {"Mining": 141, "Engineering": 150})
        self.assertEqual(Q.resolve_char(self.con, "coilbyte"), "Forever-Test:Coilbyte")
        self.assertEqual(Q.resolve_char(self.con, "warlock"), "Forever-Test:Coilbyte")
        self.assertEqual(self.count("SELECT COUNT(*) FROM events WHERE char_key='Forever-Test:Coilbyte' AND type='PROFESSION_SKILL_UP'"), 1)

    def test_older_file_does_not_overwrite_newer_state(self):
        store.ingest_sv_file(self.con, self.sv("sv_v2.lua"))
        store.ingest_sv_file(self.con, self.sv("sv_v1.lua", account="OLDCOPY"))
        eq = Q.equipment(self.con, "Forever-Test:Pixelpop")["equipped"]
        self.assertEqual(eq[0]["name"], "Bright Bracers")

    def test_completed_quests(self):
        store.ingest_sv_file(self.con, self.sv("sv_v1.lua"))
        ck = "Forever-Test:Pixelpop"
        r = Q.quest(self.con, ck, "307")["matches"][0]
        self.assertEqual(r["status"], "completed")
        self.assertEqual(r["title"], "Filthy Paws")
        r = Q.quest(self.con, ck, "filthy paws")["matches"]
        self.assertEqual(len(r), 1)
        r = Q.quest(self.con, ck, "33")["matches"][0]
        self.assertEqual(r["completed_at"], "before tracking began")
        r = Q.quest(self.con, ck, "9999")["matches"][0]
        self.assertEqual(r["status"], "not completed and not in quest log")

    def test_live_jsonl_partial_lines_and_overlap(self):
        store.ingest_sv_file(self.con, self.sv("sv_v1.lua"))
        live = os.path.join(self.d, "inbox", "live")
        os.makedirs(live)
        lp = os.path.join(live, "live-2026-11-15.jsonl")
        existing = self.con.execute("SELECT event_id FROM events LIMIT 1").fetchone()[0]
        now = int(time.time())
        lines = [
            {"char_key": "Forever-Test:Pixelpop", "id": existing, "type": "LEVEL_UP", "t": now, "payload": {}, "captured_at": now},
            {"char_key": "Forever-Test:Pixelpop", "id": "9-live-1:1", "type": "ZONE_CHANGED", "t": now, "payload": {"zone": "Wetlands"}, "captured_at": now},
        ]
        with open(lp, "w") as fh:
            fh.write("\n".join(json.dumps(x) for x in lines) + "\n")
            fh.write('{"char_key": "Forever-Test:Pixelpop", "id": "9-live-1:2", "ty')  # half-written line
        r = store.ingest_live_file(self.con, lp)
        self.assertEqual((r["events_new"], r["events_dup"]), (1, 1))
        with open(lp, "a") as fh:
            fh.write('pe": "DEATH", "t": %d, "payload": {}, "captured_at": %d}\n' % (now, now))
        r = store.ingest_live_file(self.con, lp)
        self.assertEqual(r["events_new"], 1)
        self.assertEqual(store.ingest_live_file(self.con, lp)["events_new"], 0)
        f = Q.freshness(self.con, "Forever-Test:Pixelpop", now=now + 30)
        self.assertEqual(f["status"], "fresh")


class FreshnessAndQueries(Tmp):
    def test_stale_flag(self):
        store.ingest_sv_file(self.con, self.sv("sv_v1.lua"))
        ck = "Forever-Test:Pixelpop"
        cap = self.count("SELECT last_captured_at FROM characters WHERE char_key=?", ck)
        self.assertEqual(Q.freshness(self.con, ck, now=cap + 60)["status"], "fresh")
        self.assertEqual(Q.freshness(self.con, ck, now=cap + 3 * 3600)["status"], "recent")
        f = Q.freshness(self.con, ck, now=cap + 7 * 3600)
        self.assertTrue(f["stale"])
        self.assertIn("STALE", Q.summary(self.con, ck, now=cap + 7 * 3600))

    def test_session_summary_and_history(self):
        store.ingest_sv_file(self.con, self.sv("sv_v2.lua"))
        ck = "Forever-Test:Pixelpop"
        h = Q.history(self.con, ck, "all")["summary"]
        self.assertEqual(h["levels"], [24])
        self.assertIn("Filthy Paws [307]", h["quests_completed"])
        self.assertIn("First Aid", h["skill_ups"])
        self.assertIn("5x Linen Cloth", h["items_gained"])
        last = Q.history(self.con, ck, "last-session")
        self.assertIn("last play session", last["timeframe"])
        self.assertIn("Dun Morogh", last["summary"].get("zones", []))
        s = Q.summary(self.con, ck)
        self.assertLess(len(s), 2000)
        self.assertIn("Tailoring 75/150", s)

    def test_timeframes(self):
        now = 1763250000 + 13 * 3600
        s, u, _ = Q.parse_timeframe("today", now=now)
        self.assertLessEqual(s, now)
        self.assertGreater(s, now - 86400)
        s2, u2, _ = Q.parse_timeframe("yesterday", now=now)
        self.assertEqual(u2, s)
        self.assertEqual(Q.parse_timeframe("90m", now=now)[0], now - 5400)
        with self.assertRaises(ValueError):
            Q.parse_timeframe("fortnight-ish")

    def test_equipment_compare_and_inventory(self):
        store.ingest_sv_file(self.con, self.sv("sv_v2.lua"))
        ck = "Forever-Test:Pixelpop"
        c = Q.compare(self.con, ck, "pioneer")["comparisons"][0]
        self.assertEqual(c["candidate"]["stats"]["ITEM_MOD_INTELLECT_SHORT"], 3)
        self.assertEqual(c["equipped_in_slot"][0]["name"], "Bright Bracers")
        inv = Q.inventory(self.con, ck)
        names = {i["name"]: i["count"] for i in inv["items"]}
        self.assertEqual(names["Linen Cloth"], 12)
        self.assertEqual(inv["bank_captured_at"], "bank never opened")

    def test_cli_end_to_end_and_export(self):
        self.sv("sv_v2.lua")
        os.environ["FOREVERSCRIBE_DB"] = self.db
        os.environ["FOREVERSCRIBE_SOURCES"] = os.path.join(self.d, "inbox")
        self.addCleanup(os.environ.pop, "FOREVERSCRIBE_DB", None)
        self.addCleanup(os.environ.pop, "FOREVERSCRIBE_SOURCES", None)
        for argv in (["summary"], ["-c", "pixelpop", "state"], ["events", "--limit", "3"], ["quest", "307"],
                     ["equipment"], ["inventory", "linen"], ["professions", "--recipes"], ["flightpaths"],
                     ["dungeons"], ["history", "all"], ["freshness"], ["characters"], ["--json", "summary"]):
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(argv)
            self.assertEqual(rc, 0, argv)
            self.assertTrue(buf.getvalue().strip(), argv)
        buf = io.StringIO()
        with redirect_stdout(buf):
            cli.main(["-c", "pixelpop", "export", "--out", os.path.join(self.d, "x.json")])
        with open(os.path.join(self.d, "x.json")) as fh:
            data = json.load(fh)
        self.assertIn(307, data["quests_completed"])

    def test_pull_over_fake_ssh(self):
        remote = os.path.join(self.d, "remote", "Account")
        os.makedirs(os.path.join(remote, "ACCT9", "SavedVariables"))
        shutil.copy(os.path.join(FIX, "sv_v1.lua"), os.path.join(remote, "ACCT9", "SavedVariables", "ForeverScribe.lua"))
        with open(os.path.join(remote, "ACCT9", "SavedVariables", "Polestar.lua"), "w") as fh:
            fh.write("PolestarDB = {}\n")
        fake = os.path.join(self.d, "fake_ssh.sh")
        with open(fake, "w") as fh:
            fh.write('#!/bin/bash\nshift\nexec /bin/bash -c "$*"\n')
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
        cfgp = os.path.join(self.d, "config.toml")
        with open(cfgp, "w") as fh:
            fh.write('data_dir = "%s"\n[transport]\nmode = "folder"\n[pull]\nssh_host = "gamer@game-pc"\nremote_account_dir = "%s"\n'
                     % (self.d, remote))
        env = {"FOREVERSCRIBE_CONFIG": cfgp, "FOREVERSCRIBE_SSH": fake, "FOREVERSCRIBE_DB": self.db, "FOREVERSCRIBE_DATA": self.d}
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(["pull"])
        finally:
            for k, v in old.items():
                os.environ.pop(k) if v is None else os.environ.__setitem__(k, v)
        self.assertEqual(rc, 0, buf.getvalue())
        pulled = os.path.join(self.d, "pull", "Account", "ACCT9", "SavedVariables")
        self.assertEqual(os.listdir(pulled), ["ForeverScribe.lua"])  # other addons' files are not copied
        self.assertEqual(Q.characters(self.con)[0]["account"], "ACCT9")


class V2SectionTests(Tmp):
    ck = "Forever-Test:Pixelpop"

    def test_sections_ingested_and_queried(self):
        store.ingest_sv_file(self.con, self.sv("sv_v2.lua"))
        r = Q.reputation(self.con, self.ck)
        names = {f["faction"]: f for f in r["factions"]}
        self.assertEqual(names["Ironforge"]["standing"], "Friendly")
        self.assertEqual(names["Ironforge"]["progress"], "100/6000")
        self.assertTrue(names["Defias Brotherhood"]["at_war"])
        self.assertEqual(r["legacy_reward_track"]["level"], 3)
        t = Q.talents(self.con, self.ck)
        self.assertEqual(t["legacy"]["points_unspent"], 2)
        self.assertEqual(t["legacy"]["trees"][0]["tree"], "Legacy Adventure")
        self.assertIn("Hearty Appetite 0/1", t["legacy"]["trees"][0]["not_taken"][0])
        ex = Q.explored(self.con, self.ck)
        zones = {z["zone"]: z for z in ex["zones"]}
        self.assertEqual(zones["Loch Modan"]["explored_overlays"], 2)
        self.assertEqual(zones["Loch Modan"]["areas"], ["Thelsamar", "Silver Stream Mine"])
        self.assertEqual(zones["Dun Morogh"]["areas"], ["Kharanos"])
        a = Q.achievements(self.con, self.ck, which="todo")
        self.assertEqual({x["name"] for x in a["list"]}, {"Polymorph Master", "Explore Loch Modan"})
        pm = next(x for x in a["list"] if x["name"] == "Polymorph Master")
        self.assertEqual(pm["remaining"], ["Polymorph a humanoid"])
        self.assertEqual(pm["legacy_points"], 10)
        self.assertEqual(a["statistics"]["Total deaths"], 12)
        col = Q.collections(self.con, self.ck)
        self.assertEqual(col["mounts"], ["Black Ram"])
        self.assertEqual(col["current_title"], "Private <name>")
        st = Q.stats(self.con, self.ck)
        self.assertEqual(st["health"], 640)
        self.assertEqual(st["primary"]["int"], 78)
        self.assertEqual(st["guild"]["name"], "Muffin Mafia")
        self.assertEqual(Q.currencies(self.con, self.ck)["currencies"][0]["name"], "Honor Points")
        lk = Q.lockouts(self.con, self.ck, now=1763250000)
        self.assertEqual(lk["active"][0]["instance"], "The Deadmines")
        self.assertEqual(lk["active"][0]["bosses"], "2/6")
        # quest titles from the client cache backfill completed quests from before tracking
        self.assertEqual(Q.quest(self.con, self.ck, "33")["matches"][0]["title"], "Collecting Kelp")
        h = Q.history(self.con, self.ck, "all")["summary"]
        self.assertEqual(h["reputation"]["Ironforge"], "+600")
        self.assertIn("Kharanos", h["explored"])
        s = Q.summary(self.con, self.ck)
        self.assertIn("Legacy: track rank 3", s)
        self.assertIn("Reputation (4)", s)
        self.assertLess(len(s), 2600)

    def test_empty_section_never_replaces_good_data(self):
        store.ingest_sv_file(self.con, self.sv("sv_v2.lua"))
        p = self.sv("sv_v2.lua")
        with open(p) as fh:
            text = fh.read()
        # A later file whose sections came back empty (teardown read): bump times so it is "newer".
        from foreverscribe.svparse import parse_saved_variables
        data = parse_saved_variables(text)["ForeverScribeDB"]
        c = data["chars"][self.ck]
        c["reputation"] = {"factions": [], "count": 0, "scannedAt": 1999999999}
        c["achievements"] = {"list": {}, "total": 0, "scannedAt": 1999999999}
        c["explored"] = {"zones": {}, "scannedAt": 1999999999}
        c["collections"] = {"scannedAt": 1999999999}
        c["legacy"] = {"trees": [], "scannedAt": 1999999999}
        c["snapshot"]["capturedAt"] = 1999999999
        con2 = self.con
        store._store_sections(con2, self.ck, c, 1999999999, int(time.time()))
        con2.commit()
        self.assertEqual(Q.reputation(self.con, self.ck)["count"], 4)
        self.assertEqual(Q.achievements(self.con, self.ck)["total"], 3)
        self.assertTrue(Q.explored(self.con, self.ck)["zones"])
        self.assertEqual(Q.collections(self.con, self.ck)["counts"]["mounts"], 1)
        self.assertEqual(Q.talents(self.con, self.ck)["legacy"]["trees"][0]["tree"], "Legacy Adventure")
        # a partial (much smaller) achievement read is also ignored
        c["achievements"] = {"list": {"1": {"n": "x"}}, "total": 1, "scannedAt": 1999999999}
        store._store_sections(con2, self.ck, c, 1999999999, int(time.time()))
        self.assertEqual(Q.achievements(self.con, self.ck)["total"], 3)
        # an older file arriving late never replaces newer sections
        c["reputation"] = {"factions": [{"id": 1, "name": "Old"}], "scannedAt": 5}
        store._store_sections(con2, self.ck, c, 5, int(time.time()))
        self.assertEqual(Q.reputation(self.con, self.ck)["count"], 4)

    def test_section_history_keeps_distinct_versions(self):
        store.ingest_sv_file(self.con, self.sv("sv_v1.lua"))
        store.ingest_sv_file(self.con, self.sv("sv_v2.lua"))
        n = self.count("SELECT COUNT(*) FROM section_history WHERE char_key=? AND section='reputation'", self.ck)
        self.assertEqual(n, 2)  # Ironforge went Neutral -> Friendly between the two files

    def test_cli_v2_commands(self):
        self.sv("sv_v2.lua")
        os.environ["FOREVERSCRIBE_DB"] = self.db
        os.environ["FOREVERSCRIBE_SOURCES"] = os.path.join(self.d, "inbox")
        self.addCleanup(os.environ.pop, "FOREVERSCRIBE_DB", None)
        self.addCleanup(os.environ.pop, "FOREVERSCRIBE_SOURCES", None)
        for argv in (["reputation"], ["reputation", "iron"], ["talents"], ["talents", "--taken-only"], ["explored"],
                     ["explored", "loch"], ["achievements"], ["achievements", "todo"], ["achievements", "--search", "frost"],
                     ["collections"], ["stats"], ["currencies"], ["lockouts"], ["mail"], ["dump"], ["--json", "talents"],
                     ["-c", "pixelpop", "everything", "--out", os.path.join(self.d, "all.json")]):
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(argv)
            self.assertEqual(rc, 0, argv)
            self.assertTrue(buf.getvalue().strip(), argv)
        with open(os.path.join(self.d, "all.json")) as fh:
            data = json.load(fh)
        for k in ("reputation", "talents", "explored", "achievements", "collections", "stats", "currencies",
                  "lockouts", "mail", "spellbook", "quests_completed"):
            self.assertIn(k, data)
        self.assertEqual(data["mail"]["mail"][1]["from"], "player")
        self.assertNotIn("Fizzwick", json.dumps(data))


if __name__ == "__main__":
    unittest.main()


class ZoneBounceTests(unittest.TestCase):
    def ev(self, t, zone, frm):
        return {"type": "ZONE_CHANGED", "t": t, "payload": {"zone": zone, "from": frm}}

    def test_border_bouncing_collapses(self):
        rows = [self.ev(0, "Arathi Highlands", "Wetlands"), self.ev(5, "Hillsbrad Foothills", "Arathi Highlands"),
                self.ev(9, "Arathi Highlands", "Hillsbrad Foothills"), self.ev(12, "Hillsbrad Foothills", "Arathi Highlands"),
                {"type": "LOOT", "t": 200, "payload": {}},
                self.ev(300, "Arathi Highlands", "Hillsbrad Foothills"), self.ev(305, "Hillsbrad Foothills", "Arathi Highlands")]
        out = Q.collapse_zone_bounces(rows)
        zones = [(e["payload"]["from"], e["payload"]["zone"]) for e in out if e["type"] == "ZONE_CHANGED"]
        self.assertEqual(zones, [("Wetlands", "Hillsbrad Foothills")])  # round trip at 300s dropped
        self.assertEqual(len([e for e in out if e["type"] == "LOOT"]), 1)
