"""Relay transport: the end-to-end envelope (Python AES vs FIPS-197 / SP 800-38A / openssl, bash, PowerShell), fs2 codes,
and a live run: fake game folder -> macOS sync agent -> relay (uvicorn) -> `relay sync` -> ingest -> summary, then a
route and prices back to the game folder.

The live test needs the relay's venv (python3 -m venv relay/.venv && relay/.venv/bin/pip install -r
relay/requirements-dev.txt); the PowerShell checks need pwsh on PATH (or FOREVERSCRIBE_PWSH)."""
import io
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
import urllib.request
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT, FIX = fsenv.ROOT, fsenv.FIX
sys.path.insert(0, ROOT)
from foreverscribe import relaycrypto as RC  # noqa: E402

SYNC = os.path.join(ROOT, "installers", "macos", "foreverscribe-sync.sh")
SYNC_PS1 = os.path.join(ROOT, "installers", "windows", "foreverscribe-sync.ps1")
VENV_PY = os.path.join(ROOT, "relay", ".venv", "bin", "python")
VECTOR = os.path.join(FIX, "relay_vector.json")
PWSH = os.environ.get("FOREVERSCRIBE_PWSH") or shutil.which("pwsh")
CH = "0f" * 16


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def tmpdir(tag):
    return tempfile.mkdtemp(prefix="fs-relay-%s-" % tag, dir=os.environ.get("TMPDIR"))


def rd(p, mode="rb"):
    with open(p, mode) as f:
        return f.read()


def wr(p, data):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


class Crypto(unittest.TestCase):
    def test_aes_known_answers(self):
        p = bytes.fromhex("00112233445566778899aabbccddeeff")
        for key, ct in ((bytes(range(16)), "69c4e0d86a7b0430d8cdb78070b4c55a"),
                        (bytes(range(24)), "dda97ca4864cdfe06eaf70a0ec0d7191"),
                        (bytes(range(32)), "8ea2b7ca516745bfeafc49904b496089")):  # FIPS-197 appendix C
            a = RC.AES(key)
            self.assertEqual(a.encrypt_block(p).hex(), ct)
            self.assertEqual(a.decrypt_block(bytes.fromhex(ct)), p)
        # SP 800-38A F.2.5 (CBC-AES256), all four blocks
        key = bytes.fromhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        iv = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
        pt = bytes.fromhex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
                           "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
        want = ("f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d"
                "39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b")
        self.assertEqual(RC.cbc_encrypt(key, iv, pt)[:64].hex(), want)
        self.assertEqual(RC.cbc_decrypt(key, iv, RC.cbc_encrypt(key, iv, pt)), pt)

    def test_cbc_matches_openssl(self):
        key, iv = os.urandom(32), os.urandom(16)
        for n in (0, 1, 15, 16, 17, 4097):
            data = os.urandom(n)
            o = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", key.hex(), "-iv", iv.hex()], input=data,
                               capture_output=True, check=True).stdout
            self.assertEqual(RC.cbc_encrypt(key, iv, data), o, n)
            self.assertEqual(RC.cbc_decrypt(key, iv, o), data)

    def test_envelope_binds_key_channel_and_name(self):
        k = RC.new_master()
        bid, blob = RC.seal(k, CH, "sv/ACCT/ForeverScribe.lua", b"ForeverScribeDB = {}\n")
        self.assertEqual(RC.open_blob(k, CH, bid, blob)[:2], ("sv/ACCT/ForeverScribe.lua", b"ForeverScribeDB = {}\n"))
        self.assertNotIn(b"ACCT", blob)  # names are inside the ciphertext
        bad = bytearray(blob)
        bad[60] ^= 1
        for args in ((RC.new_master(), CH, bid, blob), (k, "1" * 32, bid, blob), (k, CH, RC.blob_id(k, "route"), blob),
                     (k, CH, bid, bytes(bad)), (k, CH, bid, blob[:-1]), (k, CH, bid, b"junk")):
            with self.assertRaises(RC.OpenError):
                RC.open_blob(*args)

    def test_fixed_vector(self):
        """tests/fixtures/relay_vector.json: a fixed envelope every implementation must open (and Python reproduces)."""
        v = json.loads(rd(VECTOR, "r"))
        bid, blob = RC.seal(v["key"], v["channel"], v["name"], v["plain"].encode(), now=v["time"], iv=bytes.fromhex(v["iv"]))
        self.assertEqual((bid, blob.hex()), (v["blob_id"], v["blob_hex"]))
        self.assertEqual(RC.mac_key(v["key"]), v["mac_key"])
        self.assertEqual(RC.enc_key(v["key"]).hex(), v["enc_key"])

    def test_bad_gzip_and_bomb_are_open_errors(self):
        import gzip as gz
        k = RC.new_master()
        bid = RC.blob_id(k, "route")
        for body in (b"\x1f\x8b\x08\x00" + b"\x00" * 6 + b"garbage-deflate", gz.compress(b"\0" * (RC.MAX_PLAIN + 1))):
            _, blob = RC.seal(k, CH, "route", body, compress=False)
            with self.assertRaises(RC.OpenError):
                RC.open_blob(k, CH, bid, blob)

    def test_push_dest_stays_inside_push(self):
        from foreverscribe import relay as RL

        class Cfg:
            data_dir = tmpdir("dest")
        try:
            ok, _ = RL._push_dest(Cfg, "sv/ACCT1/Forever-Test/Chär/Polestar.lua", ["Polestar.lua"])
            self.assertTrue(ok.startswith(os.path.realpath(Cfg.data_dir)))
            for bad in ("sv/../ForeverScribe.lua", "sv/./ForeverScribe.lua", "sv/ACCT1/C:/evil/Polestar.lua",
                        "sv/ACCT1/..\\x/y/Polestar.lua", "sv/CON/ForeverScribe.lua", "sv/ACCT1/r/ /Polestar.lua",
                        "sv/ACCT1/Other.lua", "route", "sv/ACCT1/a/b/ForeverScribe.lua"):
                with self.assertRaises(ValueError, msg=bad):
                    RL._push_dest(Cfg, bad, ["Polestar.lua"])
        finally:
            shutil.rmtree(Cfg.data_dir, ignore_errors=True)

    def test_relay_url_must_be_https_or_loopback(self):
        from foreverscribe import relay as RL

        class Cfg:
            data_dir = tmpdir("url")

            def section(self, n):
                return {}
        try:
            for bad in ("http://localhost.evil.com", "http://127.0.0.1.evil.com:80", "http://example.com", "ftp://x"):
                with self.assertRaises(ValueError, msg=bad):
                    RL.pair(Cfg(), bad)
        finally:
            shutil.rmtree(Cfg.data_dir, ignore_errors=True)

    def test_pairing_code(self):
        c = RC.encode_pairing("https://relay.example", CH, "fsg_x", "k" * 43)
        self.assertTrue(c.startswith("fs2."))
        self.assertEqual(RC.decode_pairing(c), {"url": "https://relay.example", "channel": CH, "token": "fsg_x", "key": "k" * 43})
        for bad in ("fs1.abc", "fs2.!!", RC.encode_pairing("u", "nothex", "t", "k")):
            with self.assertRaises(ValueError):
                RC.decode_pairing(bad)


class CrossImplementation(unittest.TestCase):
    """The same envelope from Python, bash (openssl + gzip) and PowerShell (.NET), each opened by the others."""

    def setUp(self):
        self.t = tmpdir("x")
        self.k = RC.new_master()
        wr(os.path.join(self.t, "relay.key"), "fsg_test\n%s\n" % self.k)
        self.data = os.urandom(5000) + "Ünïcode tail }\n".encode()
        wr(os.path.join(self.t, "src"), self.data)
        self.name = "sv/ACCT/Réalm Name/Chär/Polestar.lua"

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def env(self):
        return dict(os.environ, FOREVERSCRIBE_SUPPORT=self.t, FOREVERSCRIBE_GAME_CONF=os.devnull,
                    FOREVERSCRIBE_RELAY_URL="http://127.0.0.1:9", FOREVERSCRIBE_RELAY_CH=CH)

    def bash(self, *args):
        return subprocess.run(["bash", SYNC] + list(args), env=self.env(), capture_output=True, text=True, timeout=60)

    def pwsh(self, *args):
        return subprocess.run([PWSH, "-NoProfile", "-File", SYNC_PS1, "-Support", self.t] + list(args), env=self.env(),
                              capture_output=True, text=True, timeout=120)

    def test_python_and_bash(self):
        p = os.path.join(self.t, "p")
        bid, blob = RC.seal(self.k, CH, self.name, self.data)
        wr(os.path.join(self.t, "py.blob"), blob)
        r = self.bash("--relay-open", os.path.join(self.t, "py.blob"), self.name, p)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(rd(p), self.data)
        r = self.bash("--relay-seal", self.name, os.path.join(self.t, "src"), os.path.join(self.t, "sh.blob"))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, bid))
        self.assertEqual(RC.open_blob(self.k, CH, bid, rd(os.path.join(self.t, "sh.blob")))[:2], (self.name, self.data))
        # bash refuses a blob for another name and a changed blob
        self.assertNotEqual(self.bash("--relay-open", os.path.join(self.t, "py.blob"), "route", p).returncode, 0)
        bad = bytearray(blob)
        bad[70] ^= 1
        wr(os.path.join(self.t, "bad.blob"), bytes(bad))
        self.assertNotEqual(self.bash("--relay-open", os.path.join(self.t, "bad.blob"), self.name, p).returncode, 0)

    def test_fixed_vector_opens_in_bash_and_powershell(self):
        v = json.loads(rd(VECTOR, "r"))
        wr(os.path.join(self.t, "relay.key"), "fsg_test\n%s\n" % v["key"])
        wr(os.path.join(self.t, "v.blob"), bytes.fromhex(v["blob_hex"]))
        out = os.path.join(self.t, "v.out")
        env_ch = v["channel"]
        r = subprocess.run(["bash", SYNC, "--relay-open", os.path.join(self.t, "v.blob"), v["name"], out],
                           env=dict(self.env(), FOREVERSCRIBE_RELAY_CH=env_ch), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(rd(out).decode(), v["plain"])
        if PWSH:
            os.remove(out)
            r = subprocess.run([PWSH, "-NoProfile", "-File", SYNC_PS1, "-Support", self.t, "-RelayOpen", v["name"], "-InFile",
                                os.path.join(self.t, "v.blob"), "-OutFile", out], env=dict(self.env(), FOREVERSCRIBE_RELAY_CH=env_ch),
                               capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(rd(out).decode(), v["plain"])

    @unittest.skipUnless(PWSH, "pwsh not installed (the Windows agent is then only static-checked)")
    def test_powershell_both_ways(self):
        bid, blob = RC.seal(self.k, CH, self.name, self.data)
        wr(os.path.join(self.t, "py.blob"), blob)
        out = os.path.join(self.t, "ps.out")
        r = self.pwsh("-RelayOpen", self.name, "-InFile", os.path.join(self.t, "py.blob"), "-OutFile", out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(rd(out), self.data)
        r = self.pwsh("-RelaySeal", self.name, "-InFile", os.path.join(self.t, "src"), "-OutFile", os.path.join(self.t, "ps.blob"))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, bid), r.stderr)
        ps_blob = os.path.join(self.t, "ps.blob")
        self.assertEqual(RC.open_blob(self.k, CH, bid, rd(ps_blob))[:2], (self.name, self.data))
        r = self.bash("--relay-open", ps_blob, self.name, os.path.join(self.t, "sh.out"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(rd(os.path.join(self.t, "sh.out")), self.data)
        r = self.bash("--relay-seal", "route", os.path.join(self.t, "src"), os.path.join(self.t, "sh.blob"))
        self.assertEqual(self.pwsh("-RelayOpen", "route", "-InFile", os.path.join(self.t, "sh.blob"), "-OutFile", out).returncode, 0)
        self.assertEqual(rd(out), self.data)
        self.assertNotEqual(self.pwsh("-RelayOpen", "prices", "-InFile", os.path.join(self.t, "sh.blob"), "-OutFile", out).returncode, 0)


@unittest.skipUnless(os.path.exists(VENV_PY), "relay venv missing (relay/requirements-dev.txt)")
class LiveRelay(unittest.TestCase):
    """uvicorn relay on 127.0.0.1 + the real macOS kit (install.sh --pair fs2...) + `foreverscribe relay sync`."""

    def setUp(self):
        self.t = tmpdir("live")
        self.port = free_port()
        self.url = "http://127.0.0.1:%d" % self.port
        self.relay_data = os.path.join(self.t, "relay-data")
        self.rx = self.start_relay()
        # agent computer
        self.data = os.path.join(self.t, "agent-data")
        self.cfg = os.path.join(self.t, "agent.toml")
        # game computer: a fake WoW folder + home
        self.home = os.path.join(self.t, "home")
        self.wow = os.path.join(self.t, "wow")
        self.sv = os.path.join(self.wow, "WTF", "Account", "ACCT1", "SavedVariables")
        os.makedirs(self.sv)
        os.makedirs(os.path.join(self.wow, "Interface", "AddOns"))
        os.makedirs(self.home)
        self.fake_launchctl = os.path.join(self.t, "launchctl")
        wr(self.fake_launchctl, "#!/bin/bash\nexit 0\n")
        os.chmod(self.fake_launchctl, 0o755)
        self.saved_env = dict(os.environ)

    def start_relay(self, secret="test-relay-secret"):
        env = dict(os.environ, RELAY_DATA_DIR=self.relay_data, RELAY_SECRET=secret, RELAY_CREATE_SECRET="invite-123")
        rx = subprocess.Popen([VENV_PY, "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", str(self.port), "--workers", "1",
                               "--no-access-log", "--proxy-headers", "--forwarded-allow-ips", "*"],
                              cwd=os.path.join(ROOT, "relay"), env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                with urllib.request.urlopen(self.url + "/v1/health", timeout=1) as r:
                    if json.loads(r.read())["ok"]:
                        return rx
            except Exception:
                time.sleep(0.1)
        rx.kill()
        self.fail("relay did not start: %s" % rx.stdout.read().decode())

    def stop_relay(self):
        self.rx.terminate()
        out = self.rx.communicate(timeout=20)[0].decode()
        self.rx = None
        return out

    def tearDown(self):
        if self.rx:
            self.stop_relay()
        os.environ.clear()
        os.environ.update(self.saved_env)
        shutil.rmtree(self.t, ignore_errors=True)

    def fs(self, *args, check=True):
        env = dict(os.environ, FOREVERSCRIBE_CONFIG=self.cfg, PYTHONPATH=ROOT)
        env.pop("FOREVERSCRIBE_DATA", None)
        r = subprocess.run([sys.executable, "-m", "foreverscribe"] + list(args), env=env, cwd=ROOT, capture_output=True,
                           text=True, timeout=120)
        if check:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def kit(self, *args):
        env = dict(os.environ, HOME=self.home, LAUNCHCTL=self.fake_launchctl, FOREVERSCRIBE_WOW_DIR=self.wow)
        return subprocess.run(["/bin/bash", os.path.join(ROOT, "installers", "macos", "install.sh"), "--wow-dir", self.wow] + list(args),
                              env=env, capture_output=True, text=True, timeout=120)

    def game_sync(self):
        support = os.path.join(self.home, "Library", "Application Support", "ForeverScribe")
        env = dict(os.environ, HOME=self.home, FOREVERSCRIBE_SYNC_SETTLE="0.1", FOREVERSCRIBE_PUSH_TRIES="1",
                   FOREVERSCRIBE_SUPPORT=support)
        r = subprocess.run(["bash"] + (["-x"] if os.environ.get("FS_DEBUG") else []) + [os.path.join(support, "foreverscribe-sync.sh"), "-v"], env=env, capture_output=True,
                           text=True, timeout=120)
        return r.stdout + r.stderr

    def events(self):
        con = sqlite3.connect(os.path.join(self.data, "forever.db"))
        try:
            return con.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        finally:
            con.close()

    def test_game_to_agent_and_back(self):
        # 1) agent: setup + pair (needs the invite code)
        self.fs("setup", "--mode", "relay", "--relay-url", self.url, "--data-dir", self.data, "--force")
        bad = self.fs("relay", "pair", "--code-only", check=False)
        self.assertIn("create secret", bad)
        code = self.fs("relay", "pair", "--secret", "invite-123", "--code-only").strip()
        self.assertTrue(code.startswith("fs2."), code)
        p = RC.decode_pairing(code)
        self.assertEqual(p["url"], self.url)
        self.assertEqual(oct(os.stat(os.path.join(self.data, "relay", "relay.json")).st_mode & 0o777), "0o600")
        # 2) game: install the kit with the fs2 code
        r = self.kit("--pair", code)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("relay OK, channel found", r.stdout)
        support = os.path.join(self.home, "Library", "Application Support", "ForeverScribe")
        conf = rd(os.path.join(support, "game.conf"), "r")
        self.assertIn("RELAY_CH=" + p["channel"], conf)
        self.assertNotIn(p["key"], conf)
        self.assertNotIn(p["token"], conf)
        self.assertEqual(rd(os.path.join(support, "relay.key"), "r"), "%s\n%s\n" % (p["token"], p["key"]))
        # 3) a save on the game computer -> relay -> agent -> ingest
        shutil.copy(os.path.join(FIX, "sv_v1.lua"), os.path.join(self.sv, "ForeverScribe.lua"))
        wr(os.path.join(self.sv, "Polestar.lua"), "PolestarDB = {\n}\n")
        log = self.game_sync()
        self.assertIn("pushed ACCT1/ForeverScribe.lua", log)
        self.assertIn("pushed ACCT1/Polestar.lua", log)
        rlog = self.stop_relay()
        self.assertNotIn("ACCT1", rlog)  # the relay never sees account or file names
        self.assertNotIn(p["channel"], rlog)
        self.assertIn(p["channel"][:8], rlog)
        self.rx = self.start_relay()
        # relay restarted on the same disk: the blobs are still there
        out = self.fs("relay", "sync", "--once")
        self.assertIn("got ACCT1/ForeverScribe.lua", out)
        self.assertIn("got ACCT1/Polestar.lua", out)
        self.assertGreater(self.events(), 0)
        self.assertTrue(os.path.isfile(os.path.join(self.data, "push", "Account", "ACCT1", "SavedVariables", "Polestar.lua")))
        summ = self.fs("summary", "--peek")
        self.assertIn("Pixelpop", self.fs("characters"))
        self.assertTrue(summ.strip())
        n = self.events()
        self.assertIn("0 new file(s)", self.fs("relay", "sync", "--once"))
        self.assertEqual(self.events(), n)
        st = self.fs("relay", "status")
        self.assertIn("game computer last connected", st)
        self.assertIn("up, version", st)
        # 4) route + prices back to the game computer
        addons = os.path.join(self.wow, "Interface", "AddOns")
        self.assertTrue(os.path.isfile(os.path.join(addons, "ForeverScribe_Route01", "ForeverScribe_Route01.toc")))
        os.environ.update(FOREVERSCRIBE_CONFIG=self.cfg)
        os.environ.pop("FOREVERSCRIBE_DATA", None)
        from foreverscribe import routes as RT, prices as P
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = RT.main(["add-json", json.dumps([{"title": "Bank", "mapID": 1453, "x": 60.0, "y": 50.0}])])
            self.assertEqual(rc, 0, buf.getvalue())
            rc = RT.main(["write"])
        self.assertEqual(rc, 0, buf.getvalue())
        self.assertIn("relay: encrypted and uploaded", buf.getvalue())
        rev = RT.load()["rev"]
        # prices: a fake market scan, written in relay mode
        sys.path.insert(0, os.path.join(ROOT, "tests"))
        from test_prices import fake_pages, MARKET
        with open(self.cfg, "a") as f:
            f.write('\n[ah]\nenabled = true\nwowgg_key = "test-key"\nmarket = "%s"\n' % MARKET)
        saved = dict(P.FETCH)
        P.FETCH["page"] = fake_pages([])
        saved_pause, P.PAGE_PAUSE = P.PAGE_PAUSE, 0
        try:
            st = P.write()
        finally:
            P.FETCH.clear()
            P.FETCH.update(saved)
            P.PAGE_PAUSE = saved_pause
        self.assertIn("relay", [d["transport"] for d in st["written_to"]])
        log = self.game_sync()
        self.assertIn("route %s from relay written to 10 slots" % rev, log)
        self.assertIn("from relay written", log)
        self.assertIn('rev = "%s"' % rev, rd(os.path.join(addons, "ForeverScribe_Route10", "Route.lua"), "r"))
        self.assertEqual(P.file_rev(os.path.join(addons, "ForeverScribe_Prices", "Prices.lua")), st["rev"])
        self.assertNotIn("from relay", self.game_sync(), "unchanged: not fetched again")
        # a relay replaying an older, validly signed route under a new seq is refused by the game side
        from foreverscribe import relay as RL0, config as C0
        pr0 = RL0.pairing(C0.load())
        old_route = rd(os.path.join(addons, "ForeverScribe_Route10", "Route.lua"))
        bid, blob = RC.seal(pr0["key"], pr0["channel"], "route", old_route.replace(rev.encode(), b"1000000000-deadbeef"),
                            now=int(time.time()) - 3600)
        RL0.call_json("%s/v1/ch/%s/files/down/%s" % (pr0["url"], pr0["channel"], bid), "PUT", token=pr0["agent_token"], body=blob)
        self.assertIn("relay offered an older route", self.game_sync())
        self.assertIn('rev = "%s"' % rev, rd(os.path.join(addons, "ForeverScribe_Route10", "Route.lua"), "r"))
        # the pickup shows up in `route status` after the agent's next status poll
        from foreverscribe import relay as RL, config as C
        cfg = C.load()
        pr = RL.pairing(cfg)
        s = RL.call_json("%s/v1/ch/%s" % (pr["url"], pr["channel"]), token=pr["agent_token"])
        st2 = RL.state(cfg)
        RL._pickups(cfg, pr, st2, s)
        self.assertEqual(RT.pickup(cfg).get("rev"), rev)
        # 5) a redeploy: empty disk, same RELAY_SECRET -> the pairing keeps working, files are re-sent
        self.stop_relay()
        shutil.rmtree(self.relay_data)
        self.rx = self.start_relay()
        shutil.copy(os.path.join(FIX, "sv_v2.lua"), os.path.join(self.sv, "ForeverScribe.lua"))
        self.assertIn("pushed ACCT1/ForeverScribe.lua", self.game_sync())
        self.assertIn("got ACCT1/ForeverScribe.lua", self.fs("relay", "sync", "--once"))
        self.assertGreater(self.events(), n)
        # 6) unpair revokes: the game computer is refused
        self.assertIn("unpaired", self.fs("relay", "unpair"))
        shutil.copy(os.path.join(FIX, "sv_v1.lua"), os.path.join(self.sv, "ForeverScribe.lua"))
        self.assertIn("channel unpaired or relay redeployed", self.game_sync())
        self.assertNotEqual(subprocess.run([sys.executable, "-m", "foreverscribe", "relay", "status"], cwd=ROOT,
                                           env=dict(os.environ, PYTHONPATH=ROOT), capture_output=True).returncode, 0)

    def test_relay_down_spools_then_delivers(self):
        self.fs("setup", "--mode", "relay", "--relay-url", self.url, "--data-dir", self.data, "--force")
        code = self.fs("relay", "pair", "--secret", "invite-123", "--code-only").strip()
        self.assertEqual(self.kit("--pair", code).returncode, 0)
        self.stop_relay()
        shutil.copy(os.path.join(FIX, "sv_v1.lua"), os.path.join(self.sv, "ForeverScribe.lua"))
        self.assertIn("kept in spool", self.game_sync())
        self.rx = self.start_relay()
        self.assertIn("delivered spooled ACCT1/ForeverScribe.lua", self.game_sync())
        self.assertIn("got ACCT1/ForeverScribe.lua", self.fs("relay", "sync", "--once"))

    def test_agent_rejects_files_it_does_not_collect(self):
        """A valid envelope (right key) for a name the agent doesn't collect, or a hostile path, is ignored."""
        self.fs("setup", "--mode", "relay", "--relay-url", self.url, "--data-dir", self.data, "--force")
        p = RC.decode_pairing(self.fs("relay", "pair", "--secret", "invite-123", "--code-only").strip())
        for name in ("sv/ACCT1/evil.lua", "sv/../../etc/ForeverScribe.lua", "sv/ACCT1/x/y/ForeverScribe.lua", "route"):
            bid, blob = RC.seal(p["key"], p["channel"], name, b"X = {}\n")
            req = urllib.request.Request("%s/v1/ch/%s/files/up/%s" % (self.url, p["channel"], bid), data=blob, method="PUT",
                                         headers={"Authorization": "Bearer " + p["token"]})
            urllib.request.urlopen(req, timeout=5).read()
        # and one with valid MAC but a corrupt gzip stream: ignored, sync keeps going
        bid, blob = RC.seal(p["key"], p["channel"], "sv/ACCT1/ForeverScribe.lua", b"\x1f\x8b\x08\x00" + b"\x00" * 6 + b"bad", compress=False)
        req = urllib.request.Request("%s/v1/ch/%s/files/up/%s" % (self.url, p["channel"], bid), data=blob, method="PUT",
                                     headers={"Authorization": "Bearer " + p["token"]})
        urllib.request.urlopen(req, timeout=5).read()
        out = self.fs("relay", "sync", "--once")
        self.assertEqual(out.count("ignored a blob"), 5, out)
        self.assertIn("0 new file(s)", self.fs("relay", "sync", "--once"), "not retried")
        self.assertFalse(os.path.exists(os.path.join(self.data, "push")))
        self.assertFalse(os.path.exists(os.path.join(self.t, "etc")))


if __name__ == "__main__":
    unittest.main()
