"""Config loading (macOS/Linux/Windows paths, TOML subset), the MCP server, v0.3 companion queries
(pending mail, auctions, invoices, vendors, cold tier, news), the AH off-by-default gate, and the
Lua addon suite (run from here so one `unittest discover` covers everything)."""

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
from foreverscribe import ah, cli, config as C, mcp_server, queries as Q, store  # noqa: E402


class Config(unittest.TestCase):
    def test_paths_per_platform(self):
        mac = {"HOME": "/Users/someone"}
        self.assertEqual(C.config_path(mac, "darwin"), "/Users/someone/.config/foreverscribe/config.toml")
        self.assertEqual(C.default_data_dir(mac, "darwin"), "/Users/someone/.local/share/foreverscribe")
        lin = {"HOME": "/home/someone", "XDG_CONFIG_HOME": "/home/someone/.cfg", "XDG_DATA_HOME": "/srv/d"}
        self.assertEqual(C.config_path(lin, "linux"), "/home/someone/.cfg/foreverscribe/config.toml")
        self.assertEqual(C.default_data_dir(lin, "linux"), "/srv/d/foreverscribe")
        win = {"APPDATA": r"C:\Users\someone\AppData\Roaming", "LOCALAPPDATA": r"C:\Users\someone\AppData\Local"}
        self.assertEqual(C.config_path(win, "win32"), r"C:\Users\someone\AppData\Roaming\foreverscribe\config.toml")
        self.assertEqual(C.default_data_dir(win, "win32"), r"C:\Users\someone\AppData\Local\foreverscribe")
        self.assertEqual(C.config_path({"FOREVERSCRIBE_CONFIG": "/x.toml"}, "win32"), "/x.toml")

    def test_toml_subset_and_example_parse(self):
        d = C.parse_toml('a = "x # not a comment" # comment\nb = 3\n[t]\nc = [\n "one",\n \'C:\\\\two\',\n]\nd = true\ne = 1.5\n')
        self.assertEqual(d, {"a": "x # not a comment", "b": 3, "t": {"c": ["one", "C:\\\\two"], "d": True, "e": 1.5}})
        with open(os.path.join(ROOT, "config.example.toml")) as fh:
            ex = C.parse_toml(fh.read())
        self.assertEqual(ex["transport"]["mode"], "local")
        self.assertFalse(ex["ah"]["enabled"], "AH stays off by default")
        self.assertEqual(ex["sync"]["extra_saved_variables"], ["ForeverForge*.lua"])
        with self.assertRaises(C.ConfigError):
            C.parse_toml("x = unquoted")

    def test_dump_roundtrip_windows_paths(self):
        d = {"data_dir": r"D:\Games\fs data", "wow": {"dir": r'C:\Program Files (x86)\World of Warcraft\_forever_', "accounts": ["A1"]},
             "ah": {"enabled": False, "market": 'x"y'}}
        self.assertEqual(C.parse_toml(C.dump_toml(d)), d)

    def test_load_resolves_sources_by_mode(self):
        t = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
        try:
            wow = os.path.join(t, "_forever_")
            os.makedirs(os.path.join(wow, "WTF", "Account", "A1", "SavedVariables"))
            os.makedirs(os.path.join(wow, "WTF", "Account", "A2", "SavedVariables"))
            p = os.path.join(t, "c.toml")
            with open(p, "w") as fh:
                fh.write('data_dir = "%s/d"\n[wow]\ndir = "%s"\naccounts = ["A2"]\n[sources]\nextra = ["~/x"]\n' % (t, wow))
            cfg = C.load(p, env={"HOME": "/h"})
            self.assertEqual(cfg.data_dir, t + "/d")
            self.assertIn(os.path.join(wow, "WTF", "Account", "A2", "SavedVariables"), cfg.sources)
            self.assertNotIn(os.path.join(wow, "WTF", "Account", "A1", "SavedVariables"), cfg.sources)
            self.assertIn("/h/x", cfg.sources)
            with open(p, "w") as fh:
                fh.write('data_dir = "%s/d"\n[transport]\nmode = "http"\n[wow]\ndir = "%s"\n' % (t, wow))
            cfg = C.load(p, env={"HOME": "/h"})
            self.assertEqual(cfg.sources, [t + "/d/push", t + "/d/pull"], "http mode reads only what was pushed")
            self.assertFalse(C.load(os.path.join(t, "missing.toml"), env={"HOME": "/h"})["_exists"])
        finally:
            shutil.rmtree(t, ignore_errors=True)

    def test_setup_writes_config_outside_repo(self):
        t = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
        try:
            env = dict(os.environ, FOREVERSCRIBE_CONFIG=os.path.join(t, "cfg", "config.toml"), PYTHONPATH=ROOT)
            r = subprocess.run([sys.executable, "-m", "foreverscribe", "setup", "--mode", "http", "--bind", "127.0.0.1",
                                "--data-dir", os.path.join(t, "data"), "--market", "forever.normal.horde.eu"],
                               env=env, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            cfg = C.load(os.path.join(t, "cfg", "config.toml"))
            self.assertEqual(cfg["transport"]["mode"], "http")
            self.assertEqual(cfg["ah"]["market"], "forever.normal.horde.eu")
            self.assertFalse(cfg["ah"]["enabled"])
            r = subprocess.run([sys.executable, "-m", "foreverscribe", "setup"], env=env, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(r.returncode, 1, "never overwrites without --force")
            r = subprocess.run([sys.executable, "-m", "foreverscribe", "doctor"], env=env, cwd=ROOT, capture_output=True, text=True)
            self.assertIn("pairing key", r.stdout)
        finally:
            shutil.rmtree(t, ignore_errors=True)


class V3(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fs-v3-", dir=os.environ.get("TMPDIR"))
        self.db = os.path.join(self.d, "f.db")
        inbox = os.path.join(self.d, "inbox", "Account", "TESTACCT", "SavedVariables")
        os.makedirs(inbox)
        shutil.copy(os.path.join(FIX, "sv_v3.lua"), os.path.join(inbox, "ForeverScribe.lua"))
        os.environ["FOREVERSCRIBE_DB"] = self.db
        os.environ["FOREVERSCRIBE_SOURCES"] = os.path.join(self.d, "inbox")
        self.con = store.connect(self.db)
        store.ingest_all(self.con, [os.path.join(self.d, "inbox")])
        self.ck = Q.resolve_char(self.con, None)

    def tearDown(self):
        self.con.close()
        os.environ.pop("FOREVERSCRIBE_DB", None)
        os.environ.pop("FOREVERSCRIBE_SOURCES", None)
        shutil.rmtree(self.d, ignore_errors=True)

    def cli(self, *argv):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cli.main(list(argv))
        return rc, buf.getvalue()

    def test_mail_pending_invoice_auctions_vendor(self):
        m = Q.mail_v3(self.con, self.ck)
        self.assertTrue(m["new_mail"]["waiting"])
        self.assertEqual(m["new_mail"]["from"], ["Stormwind Auction House"])
        inv = [x for x in m["mail"] if x.get("auction_invoice")][0]["auction_invoice"]
        self.assertEqual((inv["type"], inv["item"], inv["sale"]), ("seller", "Linen Cloth", "90s 0c"))
        a = Q.auctions(self.con, self.ck, now=Q.now_ts())
        self.assertEqual(a["count"], 1)
        self.assertEqual(a["auctions"][0]["buyout"], "90s 0c")
        self.assertIn("Auction sold", a["outcomes_14d"][0]["what"])
        v = Q.vendor(self.con, self.ck)
        self.assertEqual(v["vendors"][0]["name"], "Mivin Shadowweave")
        one = Q.vendor(self.con, self.ck, "mivin")
        self.assertEqual(one["items"][0]["cost"], "30 Merchant's Favor")
        self.assertTrue(one["items"][0]["known"])
        self.assertEqual(Q.vendor(self.con, self.ck, "256735")["npcID"], 256735)

    def test_cold_tier_only_through_cold(self):
        self.assertEqual(Q.cold(self.con, self.ck, "addons")["count"], 3)
        self.assertEqual(Q.cold(self.con, self.ck, "keybinds")["keybinds"][0]["keys"], ["W", "UP"])
        self.assertEqual(Q.cold(self.con, self.ck, "actionbars")["slots"][0]["name"], "Fireball")
        self.assertEqual(Q.cold(self.con, self.ck, "macros")["character"], ["Sheep"])
        s = Q.summary(self.con, self.ck, mark=False)
        for cold in ("Polestar", "MOVEFORWARD", "Sheep"):
            self.assertNotIn(cold, s, "cold data never in the hot tier")
        full = json.dumps(Q.everything(self.con, self.ck), default=str)
        self.assertNotIn("MOVEFORWARD", full, "everything = warm sections; cold stays behind `cold`")

    def test_summary_hot_tier_short_with_news_once(self):
        s = Q.summary(self.con, self.ck, consumer="t1")
        self.assertLess(len(s.splitlines()), 40)
        self.assertIn("Mail: NEW mail waiting from Stormwind Auction House", s)
        self.assertIn("Auction sold: 20x Linen Cloth (listed at 90s 0c)", s)
        self.assertIn("Auctions (as of", s)
        s2 = Q.summary(self.con, self.ck, consumer="t1")
        self.assertIn("New since last check", s2)
        self.assertNotIn("Auction sold", s2.split("New since last check")[1], "news is reported once per consumer")
        s3 = Q.summary(self.con, self.ck, consumer="other-agent")
        self.assertIn("Auction sold", s3, "each consumer has its own marker")

    def test_cli_v3_commands(self):
        for argv in (["mail"], ["auctions"], ["vendor"], ["vendor", "mivin"], ["cold", "addons"], ["cold", "keybinds"],
                     ["cold", "actionbars"], ["cold", "macros"], ["files"], ["summary", "--peek"], ["--json", "auctions"]):
            rc, out = self.cli(*argv)
            self.assertEqual(rc, 0, argv)
            self.assertTrue(out.strip(), argv)
        rc, out = self.cli("vendor", "nobody")
        self.assertIn("No captured vendor", out)

    def test_ah_off_by_default(self):
        rc, out = self.cli("ah", "Linen Cloth")
        self.assertEqual(rc, 6)
        self.assertIn("AH prices are off", out)
        s = ah.settings(C.load())
        self.assertFalse(s["enabled"])


class MCP(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fs-mcp-", dir=os.environ.get("TMPDIR"))
        inbox = os.path.join(self.d, "inbox", "Account", "TESTACCT", "SavedVariables")
        os.makedirs(inbox)
        shutil.copy(os.path.join(FIX, "sv_v3.lua"), os.path.join(inbox, "ForeverScribe.lua"))
        self.env = dict(os.environ, FOREVERSCRIBE_DB=os.path.join(self.d, "f.db"), FOREVERSCRIBE_SOURCES=os.path.join(self.d, "inbox"),
                        PYTHONPATH=ROOT)

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def session(self, *msgs):
        inp = "\n".join(json.dumps(m) for m in msgs) + "\n"
        r = subprocess.run([os.path.join(ROOT, "bin", "foreverscribe"), "mcp"], input=inp, env=self.env, capture_output=True,
                           text=True, timeout=60)
        return [json.loads(l) for l in r.stdout.splitlines() if l.strip()]

    def test_initialize_list_call(self):
        out = self.session(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "summary", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "cold", "arguments": {"kind": "addons"}}},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "nope", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 6, "method": "bogus/method"},
            {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "vendor", "arguments": {"npc": "256735"}}},
        )
        by = {m["id"]: m for m in out}
        self.assertEqual(len(out), 7, "notification gets no reply")
        self.assertEqual(by[1]["result"]["serverInfo"]["name"], "foreverscribe")
        self.assertEqual(by[1]["result"]["protocolVersion"], "2025-06-18")
        names = {t["name"] for t in by[2]["result"]["tools"]}
        for need in ("summary", "quest", "equipment", "inventory", "professions", "reputation", "talents", "explored",
                     "achievements", "collections", "stats", "currencies", "mail", "auctions", "vendor", "gear", "rate",
                     "craft", "ah_price", "events", "history", "freshness", "cold"):
            self.assertIn(need, names)
        for t in by[2]["result"]["tools"]:
            self.assertEqual(t["inputSchema"]["type"], "object")
        text = by[3]["result"]["content"][0]["text"]
        self.assertIn("Pixelpop", text)
        self.assertFalse(by[3]["result"]["isError"])
        self.assertIn("Polestar", by[4]["result"]["content"][0]["text"])
        self.assertEqual(by[5]["error"]["code"], -32602)
        self.assertEqual(by[6]["error"]["code"], -32601)
        self.assertIn("Merchant's Favor", by[7]["result"]["content"][0]["text"])

    def test_stdout_is_protocol_only(self):
        out = self.session({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "doctor", "arguments": {}}})
        self.assertEqual(len(out), 1)
        self.assertIn("foreverscribe", out[0]["result"]["content"][0]["text"])

    def test_in_process_handle(self):
        r = mcp_server.handle({"jsonrpc": "2.0", "id": 9, "method": "ping"})
        self.assertEqual(r, {"jsonrpc": "2.0", "id": 9, "result": {}})


class LuaAddon(unittest.TestCase):
    def test_addon_suite(self):
        lua = fsenv.find_lua()
        if not lua:
            self.skipTest("no Lua 5.1 (run tools/get_lua.sh)")
        r = subprocess.run([lua, os.path.join(ROOT, "tests", "lua", "test_addon.lua")], cwd=ROOT, capture_output=True, text=True,
                           timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr[-2000:])
        self.assertIn(" 0 failed", r.stdout)


if __name__ == "__main__":
    unittest.main()
