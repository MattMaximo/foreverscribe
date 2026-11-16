"""Transports: game-side sync script -> signed http receiver -> SQLite; folder transport; spool + retry;
legacy unsigned allowlist; extra SavedVariables (Forever Forge) kept raw; pairing codes."""
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT, FIX = fsenv.ROOT, fsenv.FIX
sys.path.insert(0, ROOT)
from foreverscribe import auth  # noqa: E402

SYNC = os.path.join(ROOT, "installers", "macos", "foreverscribe-sync.sh")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class PushTest(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="fs-push-", dir=os.environ.get("TMPDIR"))
        self.sv = os.path.join(self.t, "wow", "WTF", "Account", "ACCT1", "SavedVariables")
        os.makedirs(self.sv)
        self.support = os.path.join(self.t, "support")
        os.makedirs(self.support)
        self.port = free_port()
        self.data = os.path.join(self.t, "data")
        self.cfg = os.path.join(self.t, "config.toml")
        self.rx = None

    def tearDown(self):
        if self.rx:
            self.rx.terminate()
            self.rx.wait()
        shutil.rmtree(self.t, ignore_errors=True)

    def write_cfg(self, extra=""):
        with open(self.cfg, "w") as fh:
            fh.write('data_dir = "%s"\n[transport]\nmode = "http"\n[receiver]\nbind = "127.0.0.1"\nport = %d\n%s'
                     % (self.data, self.port, extra))

    def env(self, **extra):
        env = dict(os.environ, FOREVERSCRIBE_CONFIG=self.cfg, PYTHONPATH=ROOT)
        env.pop("FOREVERSCRIBE_DATA", None)
        env.update(extra)
        return env

    def start_rx(self, extra="", env_extra=None):
        self.write_cfg(extra)
        self.rx = subprocess.Popen([sys.executable, "-m", "foreverscribe", "receiver", "run"], env=self.env(**(env_extra or {})),
                                   cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(80):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/v1/health" % self.port, timeout=1)
                return
            except Exception:
                time.sleep(0.1)
        self.fail("receiver did not start")

    def pair(self):
        self.write_cfg()
        code = subprocess.run([sys.executable, "-m", "foreverscribe", "pair", "--name", "test-pc", "--code-only"], env=self.env(),
                              cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
        p = auth.decode_pairing(code)
        self.assertEqual(p["url"], "http://127.0.0.1:%d" % self.port)
        with open(os.path.join(self.support, "pairing.key"), "w") as fh:
            fh.write(p["key"])
        return p

    def sync(self, fixture=None, push=True, folder=False, key_id="", legacy=False, name="ForeverScribe.lua"):
        if fixture:
            shutil.copy(os.path.join(FIX, fixture), os.path.join(self.sv, name))
        with open(os.path.join(self.support, "game.conf"), "w") as fh:
            fh.write("KEY_ID=%s\nLEGACY_UNSIGNED=%d\n" % (key_id, 1 if legacy else 0))
        env = dict(os.environ, HOME=os.path.join(self.t, "home"), FOREVERSCRIBE_SUPPORT=self.support,
                   FOREVERSCRIBE_WOW_DIR=os.path.join(self.t, "wow"),
                   FOREVERSCRIBE_DEST=os.path.join(self.t, "folder") if folder else "",
                   FOREVERSCRIBE_PUSH_URL=("http://127.0.0.1:%d" % self.port) if push else "",
                   FOREVERSCRIBE_SYNC_SETTLE="0.1", FOREVERSCRIBE_PUSH_TRIES="1")
        return subprocess.run(["bash", SYNC, "-v"], env=env, capture_output=True, text=True, timeout=60).stdout

    def events(self):
        con = sqlite3.connect(os.path.join(self.data, "forever.db"))
        try:
            return con.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        finally:
            con.close()

    def post(self, path, body, headers=None):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), data=body, method="POST",
                                     headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    # ------------------------------------------------------------------ tests
    def test_signed_push_ingests_immediately_and_dedups(self):
        p = self.pair()
        self.start_rx()
        t0 = time.time()
        out = self.sync("sv_v1.lua", key_id=p["key_id"])
        self.assertIn("pushed ACCT1/ForeverScribe.lua", out)
        self.assertLess(time.time() - t0, 5)
        n1 = self.events()
        self.assertGreater(n1, 0)
        self.assertIn("nothing new", self.sync(None, key_id=p["key_id"]))
        self.sync("sv_v2.lua", key_id=p["key_id"])
        n2 = self.events()
        self.assertGreater(n2, n1)
        self.sync("sv_v1.lua", key_id=p["key_id"])  # an older file again: no duplicate events
        self.assertEqual(self.events(), n2)

    def test_unsigned_and_wrong_key_are_refused(self):
        p = self.pair()
        self.start_rx()
        body = b"ForeverScribeDB = {}"
        code, resp = self.post("/v1/sv/ACCT1", body)
        self.assertEqual((code, resp.get("reason")), (403, "unsigned"))
        h = auth.headers(p["key_id"], "fsk_wrong", "POST", "/v1/sv/ACCT1", body)
        self.assertEqual(self.post("/v1/sv/ACCT1", body, h)[1].get("reason"), "bad signature")
        h = auth.headers(p["key_id"], p["key"], "POST", "/v1/sv/ACCT1", body, now=time.time() - 3600)
        self.assertIn("clock skew", self.post("/v1/sv/ACCT1", body, h)[1].get("reason"))
        h = auth.headers(p["key_id"], p["key"], "POST", "/v1/sv/ACCT2", body)  # signature is bound to the path
        self.assertEqual(self.post("/v1/sv/ACCT1", body, h)[0], 403)
        h = auth.headers(p["key_id"], p["key"], "POST", "/v1/auth-check", b"check")
        self.assertEqual(self.post("/v1/auth-check", b"check", h)[0], 200)

    def test_revoked_key_is_refused(self):
        p = self.pair()
        self.assertTrue(auth.revoke_key(os.path.join(self.data, "receiver-keys.json"), p["key_id"]))
        self.start_rx()
        self.assertIn("refused", self.sync("sv_v1.lua", key_id=p["key_id"]))

    def test_legacy_unsigned_allowlist_keeps_old_kits_working(self):
        self.start_rx('legacy_unsigned_ips = ["127.0.0.1"]\n')
        self.assertIn("pushed ACCT1", self.sync("sv_v1.lua", legacy=True))
        self.assertGreater(self.events(), 0)

    def test_v02_env_allowlist_still_honoured(self):
        # the v0.2 LaunchAgent passed FOREVERSCRIBE_ALLOW; an unlisted address is refused, the listed one accepted
        self.start_rx(env_extra={"FOREVERSCRIBE_ALLOW": "192.0.2.10"})
        self.assertEqual(self.post("/v1/sv/ACCT1", b"ForeverScribeDB = {}")[0], 403)
        rx = self.rx
        assert rx is not None
        rx.terminate()
        rx.wait()
        self.start_rx(env_extra={"FOREVERSCRIBE_ALLOW": "127.0.0.1"})
        self.assertIn("pushed ACCT1", self.sync("sv_v1.lua", legacy=True))

    def test_allow_ips_is_an_extra_requirement(self):
        p = self.pair()
        self.start_rx('allow_ips = ["192.0.2.10"]\n')
        h = auth.headers(p["key_id"], p["key"], "POST", "/v1/auth-check", b"x")
        code, body = self.post("/v1/auth-check", b"x", h)
        self.assertEqual(code, 403)
        self.assertIn("allow_ips", body["reason"])

    def test_receiver_down_spools_then_delivers(self):
        p = self.pair()
        out = self.sync("sv_v1.lua", key_id=p["key_id"], folder=True)
        self.assertIn("kept in spool", out)
        self.assertTrue(os.path.exists(os.path.join(self.support, "spool", "ACCT1", "ForeverScribe.lua")))
        self.assertTrue(os.path.exists(os.path.join(self.t, "folder", "ACCT1", "ForeverScribe.lua")), "folder copy still made")
        self.start_rx()
        out = self.sync(None, key_id=p["key_id"])
        self.assertIn("delivered spooled ACCT1/ForeverScribe.lua", out)
        self.assertFalse(os.path.exists(os.path.join(self.support, "spool", "ACCT1", "ForeverScribe.lua")))
        self.assertGreater(self.events(), 0)

    def test_folder_transport_without_network(self):
        out = self.sync("sv_v1.lua", push=False, folder=True)
        self.assertIn("copied ACCT1/ForeverScribe.lua", out)
        cfg = os.path.join(self.t, "agent.toml")
        with open(cfg, "w") as fh:
            fh.write('data_dir = "%s"\n[transport]\nmode = "folder"\nfolder = "%s"\n' % (self.data, os.path.join(self.t, "folder")))
        r = subprocess.run([sys.executable, "-m", "foreverscribe", "characters"], env=self.env(FOREVERSCRIBE_CONFIG=cfg),
                           cwd=ROOT, capture_output=True, text=True)
        self.assertIn("Pixelpop", r.stdout)

    def test_no_transport_means_local_mode_noop(self):
        self.assertIn("local mode", self.sync("sv_v1.lua", push=False, folder=False))

    def test_extra_saved_variables_are_shipped_and_kept_raw(self):
        p = self.pair()
        self.start_rx()
        with open(os.path.join(self.sv, "ForeverForge.lua"), "w") as fh:
            fh.write("ForeverForgeDB = {\n\t[\"scan\"] = 1,\n}\n")
        with open(os.path.join(self.sv, "Questie.lua"), "w") as fh:
            fh.write("QuestieConfig = {}\n")
        out = self.sync("sv_v1.lua", key_id=p["key_id"])
        self.assertIn("pushed ACCT1/ForeverForge.lua", out)
        self.assertNotIn("Questie", out, "only files in extra_saved_variables are shipped")
        stored = os.path.join(self.data, "push", "Account", "ACCT1", "SavedVariables")
        self.assertEqual(sorted(os.listdir(stored)), ["ForeverForge.lua", "ForeverScribe.lua"])
        con = sqlite3.connect(os.path.join(self.data, "forever.db"))
        row = con.execute("SELECT name, status FROM raw_files").fetchone()
        con.close()
        self.assertEqual(row, ("ForeverForge.lua", "unparsed"))
        # a file not listed in extra_saved_variables is refused even with a valid key
        body = b"QuestieConfig = {}"
        h = auth.headers(p["key_id"], p["key"], "POST", "/v1/sv/ACCT1/Questie.lua", body)
        self.assertEqual(self.post("/v1/sv/ACCT1/Questie.lua", body, h)[0], 400)
        # per-character: only listed files, never ForeverScribe.lua, never a path in the folder names
        for path in ("/v1/sv/ACCT1/Realm/Char/Questie.lua", "/v1/sv/ACCT1/Realm/Char/ForeverScribe.lua",
                     "/v1/sv/ACCT1/..%2F../Char/Polestar.lua", "/v1/sv/ACCT1/Realm/.%2E/Polestar.lua"):
            h = auth.headers(p["key_id"], p["key"], "POST", path, body)
            self.assertEqual(self.post(path, body, h)[0], 400, path)

    def test_rejects_truncated_and_bad_account(self):
        p = self.pair()
        self.start_rx()
        for path, body in (("/v1/sv/ACCT1", b"ForeverScribeDB = { [1] = "), ("/v1/sv/..%2Fetc", b"ForeverScribeDB = {}")):
            h = auth.headers(p["key_id"], p["key"], "POST", path, body)
            self.assertEqual(self.post(path, body, h)[0], 400, path)


class PairingCode(unittest.TestCase):
    def test_roundtrip_and_bad_codes(self):
        code = auth.encode_pairing("https://scribe.example.com", "ab12cd34", "fsk_x")
        self.assertTrue(code.startswith("fs1."))
        self.assertEqual(auth.decode_pairing(code), {"url": "https://scribe.example.com", "key_id": "ab12cd34", "key": "fsk_x"})
        for bad in ("", "fs2.abc", "fs1.%%%"):
            with self.assertRaises(Exception):
                auth.decode_pairing(bad)

    def test_shell_and_python_signatures_match(self):
        body = b"ForeverScribeDB = {}\n"
        tmp = tempfile.NamedTemporaryFile(delete=False, dir=os.environ.get("TMPDIR"))
        tmp.write(body)
        tmp.close()
        try:
            sha = subprocess.run(["shasum", "-a", "256", tmp.name], capture_output=True, text=True).stdout.split()[0]
            canon = "fs1\n1700000000\nPOST\n/v1/sv/A\n%s" % sha
            sig = subprocess.run(["openssl", "dgst", "-sha256", "-hmac", "fsk_k", "-hex"], input=canon, capture_output=True,
                                 text=True).stdout.split()[-1]
        finally:
            os.unlink(tmp.name)
        self.assertEqual(sig, auth.sign("fsk_k", 1700000000, "POST", "/v1/sv/A", body))


if __name__ == "__main__":
    unittest.main()
