"""`foreverscribe way` / MCP `waypoint`: zone resolution, Classic->Forever frame conversion, spot ordering and the
paste command chosen by the character's addons. Wowhead is stubbed with tooltip shapes recorded from
nether.wowhead.com (npc 2327 Shaina Fuller, Forever + Classic), so these run offline."""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT, FIX = fsenv.ROOT, fsenv.FIX
sys.path.insert(0, ROOT)
from foreverscribe import waypoints as WP  # noqa: E402

TIPS = {
    ("npc", 2327, "forever"): {"name": "Shaina Fuller", "tooltip": "<table><tr><td><b>Shaina Fuller</b></td></tr><tr><td>First Aid Trainer</td></tr><tr><td>Level 35 Humanoid (Normal)</td></tr></table>",
                               "map": {"zone": 1519, "coords": {"0": [[42.4, 26.8], [42.8, 26.4], [42.8, 26.6], [52.8, 44.8]]}}},
    ("npc", 2327, "classic"): {"name": "Shaina Fuller", "map": {"zone": 1519, "coords": {"0": [[42.4, 26.8], [42.8, 26.4], [42.8, 26.6]]}}},
    ("npc", 5150, "forever"): {"name": "Nissa Firestone", "tooltip": "<td>First Aid Trainer</td>",
                               "map": {"zone": 1537, "coords": {"0": [[54.8, 58.4], [54.8, 58.6], [55.6, 59.2]]}}},
    ("npc", 240, "forever"): {"name": "Marshal Dughan", "tooltip": "<td>Level 25</td>", "map": {"zone": 12, "coords": {"0": [[42.2, 65.8]]}}},
    ("npc", 5024, "forever"): {"name": "World First Aid Trainer", "tooltip": ""},
    ("object", 1731, "forever"): {"name": "Copper Vein", "tooltip": "<td>Mining Node</td>",
                                  "map": {"zone": 12, "coords": {"0": [[10, 10], [10.5, 10.5], [80, 80], [40, 60]]}}},
    ("zone", 1519, "forever"): {"name": "Stormwind City"}, ("zone", 1537, "forever"): {"name": "Ironforge"},
    ("zone", 12, "forever"): {"name": "Elwynn Forest"},
}
SEARCH = {
    "first aid trainer": [{"type": 1, "id": 5024}, {"type": 100, "id": 34831}, {"type": 1, "id": 2327}, {"type": 1, "id": 5150}],
    "marshal dughan": [{"type": 1, "id": 240}],
}


def fake_tip(kind, eid, flavor="forever"):
    return TIPS.get((kind, int(eid), flavor), {"error": "HTTP Error 404"})


def fake_search(q):
    return SEARCH.get(q.lower(), [])


class Waypoints(unittest.TestCase):
    def setUp(self):
        self.saved = dict(WP.FETCH)
        WP.FETCH.update(tooltip=fake_tip, search=fake_search)
        self.char = WP.character
        WP.character = lambda char=None: {}

    def tearDown(self):
        WP.FETCH.update(self.saved)
        WP.character = self.char

    def test_zone_resolution(self):
        self.assertEqual(WP.resolve_zone("Stormwind City"), (1453, None))
        self.assertEqual(WP.resolve_zone("stormwind")[0], 1453)
        self.assertEqual(WP.resolve_zone("#1429")[0], 1429)
        self.assertIsNone(WP.resolve_zone("Narnia")[0])
        self.assertEqual(WP.resolve_zone("Kalimdor")[0], 1414, "continent of the live world map, not the old 1464")
        mid, rest = WP.zone_in_query("first aid trainer stormwind".split())
        self.assertEqual((mid, rest), (1453, ["first", "aid", "trainer"]))

    def test_era_frame_conversion_matches_forever_points(self):
        # Wowhead Forever lists Shaina's old Classic point (42.4, 26.8) beside the Forever one (52.8, 44.8).
        x, y = WP.era_to_forever(1453, 42.4, 26.8)
        self.assertAlmostEqual(x, 52.5, delta=0.4)
        self.assertAlmostEqual(y, 45.2, delta=0.5)
        self.assertEqual(WP.era_to_forever(1429, 42.2, 65.8), (42.2, 65.8), "unchanged maps pass through")

    def test_locate_merges_frames_into_one_spot(self):
        r = WP.locate("npc", 2327)
        self.assertEqual((r["zone"], r["mapID"], r["subtitle"]), ("Stormwind City", 1453, "First Aid Trainer"))
        self.assertEqual(len(r["spots"]), 1, r["spots"])
        s = r["spots"][0]
        self.assertEqual((s["x"], s["y"], s["points"]), (52.8, 44.8, 4), "Forever-recorded point leads the cluster")
        self.assertIn("converted from Classic frame", s["frames"])
        self.assertTrue(any("Classic-frame" in n for n in r["notes"]))

    def test_redrawn_map_without_classic_lookup_is_labelled_unverified(self):
        WP.FETCH["tooltip"] = lambda k, e, f="forever": {"error": "down"} if f == "classic" else fake_tip(k, e, f)
        r = WP.locate("npc", 2327)
        self.assertTrue(any(n.startswith("UNVERIFIED") for n in r["notes"]))

    def test_where_is_stormwind_first_aid_trainer(self):
        r = WP.answer("Stormwind First Aid trainer")
        self.assertEqual(r["name"], "Shaina Fuller")
        self.assertEqual(r["paste"]["style"], "native", "no telemetry: Forever's own pin")
        self.assertEqual(r["paste"]["cmd"], "/run C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1453,0.528,0.448)) "
                                            "C_SuperTrack.SetSuperTrackedUserWaypoint(true)")
        self.assertEqual([a["cmd"] for a in r["alternatives"] if a["style"] == "mappin"], ["/mappin 1453 52.8 44.8"])
        names = [c["name"] for c in r["other_matches"]]
        self.assertIn("Nissa Firestone", names)
        self.assertNotIn("World First Aid Trainer", names[:1])
        text = WP.render(r)
        self.assertIn("Shaina Fuller <First Aid Trainer> — Stormwind City 52.8, 44.8", text)
        self.assertIn("source: Wowhead Forever npc=2327", text)

    def test_command_choice_by_addons(self):
        cmd = lambda ch, force=None: WP.commands(1453, 52.8, 44.8, 'Shaina "x" Fuller|r', ch, force, {"kind": "npc", "id": 2327})
        p, _ = cmd({"scribe_version": "0.4.0", "addons": {"foreverscribe": "0.4.0", "polestar": "0.4.0"}})
        self.assertEqual(p["cmd"], "/scribe way 52.8 44.8 Stormwind City Shaina x Fullerr")
        p, _ = cmd({"scribe_version": "0.3.0", "addons": {"foreverscribe": "0.3.0", "polestar": "0.4.0"}})
        self.assertEqual(p["cmd"], '/run Polestar.Nav.API.Navigate("ForeverScribe",1453,0.528,0.448,"Shaina x Fullerr")')
        p, _ = cmd({"scribe_version": "0.3.0", "addons": {"tomtom": "v4.4.1", "polestar": "0.4.0"}})
        self.assertEqual(p["cmd"], "/way #1453 52.8 44.8 Shaina x Fullerr")
        p, alts = cmd({"addons": {"questie": "12.9.0"}})
        self.assertEqual(p["style"], "native")
        self.assertEqual(alts[0]["cmd"], "/questie tomap npc 2327")
        p, _ = cmd({"scribe_version": "0.4.0", "addons": {"polestar": "0.4.0"}})
        self.assertEqual(p["style"], "polestar", "ForeverScribe not loaded any more")
        p, _ = cmd({"scribe_version": "0.4.0"})
        self.assertEqual(p["style"], "scribe", "no addon list yet but the snapshot came from 0.4")
        self.assertEqual(cmd({}, "tomtom")[0]["style"], "tomtom")
        with self.assertRaises(ValueError):
            cmd({}, "bogus")
        # a map name used twice in Forever (Zephras Isle) goes by id
        self.assertTrue(WP.commands(2521, 1, 2, "", {"scribe_version": "0.4.0"})[0]["cmd"].startswith("/scribe way 1 2 2521"))

    def test_coordinates_query(self):
        r = WP.answer("42.1 65.3 Elwynn Forest")
        self.assertEqual((r["mapID"], r["paste"]["cmd"]), (1429, "/run C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1429,"
                                                                    "0.421,0.653)) C_SuperTrack.SetSuperTrackedUserWaypoint(true)"))
        self.assertEqual(WP.answer("Elwynn Forest 42,1 65")["spots"][0]["x"], 42.1)
        self.assertEqual(WP.answer("42, 65 Elwynn Forest")["spots"][0]["y"], 65.0)
        self.assertIn("0-100", WP.answer("142 65 Elwynn Forest")["error"])
        self.assertIn("which zone", WP.answer("42 65")["error"])
        self.assertIn("no Forever map", WP.answer("42 65 Narnia")["error"])

    def test_unknown_location_gives_no_command(self):
        r = WP.answer("npc=5024")
        self.assertNotIn("paste", r)
        self.assertEqual(r["spots"], [])
        self.assertIn("no position", r["notes"][0])
        self.assertIn("Not found", WP.render(WP.answer("nobody at all")))

    def test_spots_nearest_first(self):
        WP.character = lambda char=None: {"mapID": 1429, "x": 79.0, "y": 79.0, "addons": {}}
        r = WP.answer("object=1731")
        self.assertEqual((r["spots"][0]["x"], r["spots"][0]["y"]), (80.0, 80.0))
        self.assertLess(r["spots"][0]["yards"], r["spots"][1]["yards"])
        self.assertEqual(len(r["spots"]), 3, "10/10.5 cluster into one spot")

    def test_cli_and_json(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = WP.main(["--json", "--addon", "mappin", "marshal", "dughan"])
        self.assertEqual(rc, 0)
        d = json.loads(buf.getvalue())
        self.assertEqual(d["paste"]["cmd"], "/mappin 1429 42.2 65.8")


class WaypointTelemetry(unittest.TestCase):
    """character() reads the cold-tier addon list + snapshot version from a real (synthetic) SavedVariables file."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fs-way-", dir=os.environ.get("TMPDIR"))
        inbox = os.path.join(self.d, "inbox", "Account", "TESTACCT", "SavedVariables")
        os.makedirs(inbox)
        shutil.copy(os.path.join(FIX, "sv_v3.lua"), os.path.join(inbox, "ForeverScribe.lua"))
        self.env = dict(os.environ, FOREVERSCRIBE_DB=os.path.join(self.d, "f.db"), FOREVERSCRIBE_SOURCES=os.path.join(self.d, "inbox"))

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def test_character_context_from_fixture(self):
        code = ("import json,sys; sys.path.insert(0, %r); from foreverscribe import waypoints as W; print(json.dumps(W.character()))" % ROOT)
        r = subprocess.run([sys.executable, "-c", code], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertTrue(r.stdout.strip(), r.stderr)
        ch = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertIn("polestar", ch["addons"])
        self.assertIn("foreverscribe", ch["addons"])
        self.assertTrue(ch["scribe_version"])
        p, _ = WP.commands(1453, 52.8, 44.8, "Shaina Fuller", ch)
        self.assertEqual(p["style"], "scribe" if WP._ver(ch["scribe_version"]) >= WP.SCRIBE_MIN else "polestar")

    def test_mcp_waypoint_tool(self):
        env = dict(self.env, PYTHONPATH=ROOT)
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                                                            "clientInfo": {"name": "t", "version": "0"}}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "waypoint", "arguments": {"query": "42.1 65.3 Elwynn Forest"}}}]
        r = subprocess.run([os.path.join(ROOT, "bin", "foreverscribe"), "mcp"], input="\n".join(json.dumps(m) for m in msgs) + "\n",
                           env=env, capture_output=True, text=True, timeout=60)
        by = {m["id"]: m for m in (json.loads(l) for l in r.stdout.splitlines() if l.strip())}
        tool = [t for t in by[2]["result"]["tools"] if t["name"] == "waypoint"][0]
        self.assertIn("Never invent coordinates", tool["description"])
        text = by[3]["result"]["content"][0]["text"]
        self.assertIn("Elwynn Forest", text)
        self.assertIn("1429", text)


if __name__ == "__main__":
    unittest.main()
