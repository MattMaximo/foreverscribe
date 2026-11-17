"""Relay server tests (FastAPI TestClient). Run: relay/.venv/bin/python -m unittest discover -s relay -p 'test_*.py'
(set up once: python3 -m venv relay/.venv && relay/.venv/bin/pip install -r relay/requirements-dev.txt)."""
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest

os.environ["RELAY_NO_AUTOAPP"] = "1"
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import app as relay  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

BID = "0123456789abcdef0123456789abcdef"


class RelayTest(unittest.TestCase):
    def make(self, **env):
        if getattr(self, "tmp", None):
            self.__dict__.setdefault("_old", []).append(self.tmp)
        self.tmp = tempfile.mkdtemp(prefix="fs-relay-", dir=os.environ.get("TMPDIR"))
        old = {k: os.environ.get(k) for k in env}
        os.environ["RELAY_DATA_DIR"] = self.tmp
        os.environ.update({k: str(v) for k, v in env.items()})
        try:
            L = relay.Limits()
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.app = relay.create_app(L)
        self.close()
        self._cm = TestClient(self.app)
        self.c = self._cm.__enter__()  # one event loop for every request (long polls share it)
        return self.c

    def close(self):
        if getattr(self, "_cm", None):
            self._cm.__exit__(None, None, None)
            self._cm = None

    def tearDown(self):
        self.close()
        for t in [getattr(self, "tmp", "")] + getattr(self, "_old", []):
            shutil.rmtree(t, ignore_errors=True)

    def channel(self, **hdr):
        r = self.c.post("/v1/channels", headers=hdr)
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.g = {"Authorization": "Bearer " + d["game_token"]}
        self.a = {"Authorization": "Bearer " + d["agent_token"]}
        self.cid = d["channel"]
        return d

    def test_health(self):
        c = self.make()
        r = c.get("/v1/health")
        self.assertEqual(r.json(), {"ok": True, "service": "foreverscribe-relay", "version": relay.VERSION})
        self.assertEqual(r.headers.get("access-control-allow-origin"), None)  # CORS off
        self.assertEqual(c.get("/docs").status_code, 404)

    def test_roles_and_flow(self):
        c = self.make()
        d = self.channel()
        self.assertRegex(d["channel"], "^[0-9a-f]{32}$")
        base = "/v1/ch/%s/files" % self.cid
        # game writes up/, agent reads up/; not the other way round
        s1 = c.put(base + "/up/" + BID, content=b"one", headers=self.g).json()["seq"]
        self.assertGreater(s1, 1700000000000)  # starts from the clock: never goes backwards across a restart
        self.assertEqual(c.put(base + "/down/" + BID, content=b"x", headers=self.g).status_code, 403)
        self.assertEqual(c.put(base + "/up/" + BID, content=b"x", headers=self.a).status_code, 403)
        self.assertEqual(c.get(base + "/up/" + BID, headers=self.g).status_code, 403)
        self.assertEqual(c.put(base + "/up/" + BID, content=b"x", headers={"Authorization": "Bearer nope"}).status_code, 403)
        self.assertEqual(c.put(base + "/up/" + BID, content=b"x").status_code, 403)
        self.assertEqual(c.put(base + "/up/../etc", content=b"x", headers=self.g).status_code, 404)
        r = c.get(base + "/up/" + BID, headers=self.a)
        self.assertEqual((r.content, r.headers["x-fs-seq"]), (b"one", str(s1)))
        # latest per name, events by seq
        c.put(base + "/up/" + BID, content=b"two", headers=self.g)
        ev = c.get("/v1/ch/%s/events?since=0" % self.cid, headers=self.a).json()
        self.assertEqual([(f["name"], f["seq"]) for f in ev["files"]], [("up/" + BID, s1 + 1)])
        self.assertEqual(c.get("/v1/ch/%s/events?since=%d" % (self.cid, s1 + 1), headers=self.a).json()["files"], [])
        self.assertEqual(c.get("/v1/ch/%s/events?since=0" % self.cid, headers=self.g).json()["files"], [])  # game sees down/
        c.put(base + "/down/" + BID, content=b"route", headers=self.a)
        ev = c.get("/v1/ch/%s/events?since=0" % self.cid, headers=self.g).json()
        self.assertEqual(ev["files"][0]["name"], "down/" + BID)
        self.assertIsNotNone(ev["peer_seen"])
        st = c.get("/v1/ch/" + self.cid, headers=self.a).json()
        self.assertEqual(st["files"]["up/" + BID]["size"], 3)
        self.assertIsNone(st["files"]["up/" + BID]["got"])  # the new version was not fetched yet
        c.get(base + "/up/" + BID, headers=self.a)
        self.assertTrue(c.get("/v1/ch/" + self.cid, headers=self.a).json()["files"]["up/" + BID]["got"])
        # only the agent unpairs
        self.assertEqual(c.delete("/v1/ch/" + self.cid, headers=self.g).status_code, 403)
        self.assertEqual(c.delete("/v1/ch/" + self.cid, headers=self.a).json(), {"ok": True})
        self.assertEqual(c.get("/v1/ch/" + self.cid, headers=self.a).status_code, 403)
        self.assertEqual(c.put(base + "/up/" + BID, content=b"x", headers=self.g).status_code, 403)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, self.cid)))
        # the refusal survives a restart on the same disk
        c2 = TestClient(relay.create_app(self.app.state.store.L))
        self.assertEqual(c2.put(base + "/up/" + BID, content=b"x", headers=self.g).status_code, 403)
        # a made-up channel id with a made-up token is refused
        self.assertEqual(c.get("/v1/ch/" + "f" * 32, headers=self.g).status_code, 403)

    def test_limits(self):
        c = self.make(RELAY_MAX_BLOB_MB=1, RELAY_MAX_FILES=2, RELAY_RATE_PER_MIN=1000)
        self.channel()
        base = "/v1/ch/%s/files/up/" % self.cid
        self.assertEqual(c.put(base + BID, content=b"x" * (1024 * 1024 + 1), headers=self.g).status_code, 413)
        self.assertEqual(c.put(base + BID, content=b"", headers=self.g).status_code, 400)
        self.assertEqual(c.put(base + "1" * 32, content=b"a", headers=self.g).status_code, 200)
        self.assertEqual(c.put(base + "2" * 32, content=b"a", headers=self.g).status_code, 200)
        self.assertEqual(c.put(base + "3" * 32, content=b"a", headers=self.g).status_code, 507)
        self.assertEqual(c.put(base + "2" * 32, content=b"b", headers=self.g).status_code, 200)  # overwrite ok

    def test_rate_limit_and_daily(self):
        c = self.make(RELAY_RATE_PER_MIN=3, RELAY_DAILY_MB=1)
        self.channel()
        codes = [c.get("/v1/ch/" + self.cid, headers=self.g).status_code for _ in range(5)]
        self.assertEqual(codes[:3], [200, 200, 200])
        self.assertEqual(codes[-1], 429)
        shutil.rmtree(self.tmp, ignore_errors=True)
        c = self.make(RELAY_DAILY_MB=1)
        self.channel()
        base = "/v1/ch/%s/files/up/" % self.cid
        self.assertEqual(c.put(base + BID, content=b"x" * 700000, headers=self.g).status_code, 200)
        self.assertEqual(c.get(base + BID, headers=self.a).status_code, 429)  # 1.4 MB > 1 MB today

    def test_create_secret_and_create_rate(self):
        c = self.make(RELAY_CREATE_SECRET="s3cret", RELAY_CREATE_PER_HOUR=2)
        self.assertEqual(c.post("/v1/channels").status_code, 403)
        self.assertEqual(c.post("/v1/channels", headers={"X-FS-Relay-Secret": "nope"}).status_code, 403)
        self.channel(**{"X-FS-Relay-Secret": "s3cret"})
        self.channel(**{"X-FS-Relay-Secret": "s3cret"})
        self.assertEqual(c.post("/v1/channels", headers={"X-FS-Relay-Secret": "s3cret"}).status_code, 429)
        c = self.make(RELAY_CREATE_SECRET="x", RELAY_SECRET="change-me")
        self.assertEqual(c.post("/v1/channels", headers={"X-FS-Relay-Secret": "x"}).status_code, 503)
        c = self.make(RELAY_CREATE_SECRET="change-me")
        self.assertEqual(c.post("/v1/channels", headers={"X-FS-Relay-Secret": "change-me"}).status_code, 503)

    def test_ttl_and_restart(self):
        c = self.make(RELAY_SECRET="fixed-secret")
        self.channel()
        c.put("/v1/ch/%s/files/up/%s" % (self.cid, BID), content=b"keep", headers=self.g)
        # a restart reloads blobs from disk
        app2 = relay.create_app(self.app.state.store.L)
        c2 = TestClient(app2)
        self.assertEqual(c2.get("/v1/ch/%s/files/up/%s" % (self.cid, BID), headers=self.a).content, b"keep")
        S = app2.state.store
        S.ch[self.cid]["files"]["up/" + BID]["t"] -= 8 * 86400
        S.sweep()
        self.assertEqual(c2.get("/v1/ch/%s/files/up/%s" % (self.cid, BID), headers=self.a).status_code, 404)
        S.ch[self.cid]["seen"] = {"agent": int(time.time()) - 31 * 86400}
        S.sweep()
        self.assertNotIn(self.cid, S.ch)
        # a redeploy (empty disk, same RELAY_SECRET) keeps the pairing working; blobs nobody fetched are gone
        old = self.tmp
        self.make(RELAY_SECRET="fixed-secret")
        shutil.rmtree(old, ignore_errors=True)
        r = self.c.get("/v1/ch/%s/events?since=0" % self.cid, headers=self.a)
        self.assertEqual((r.status_code, r.json()["files"]), (200, []))
        self.assertEqual(self.c.put("/v1/ch/%s/files/up/%s" % (self.cid, BID), content=b"again", headers=self.g).status_code, 200)
        # a different secret means none of the old tokens work
        self.make(RELAY_SECRET="other-secret")
        self.assertEqual(self.c.get("/v1/ch/%s/events" % self.cid, headers=self.a).status_code, 403)

    def test_storage_cap(self):
        c = self.make(RELAY_MAX_TOTAL_MB=1)
        self.channel()
        base = "/v1/ch/%s/files/up/" % self.cid
        self.assertEqual(c.put(base + "1" * 32, content=b"x" * 600000, headers=self.g).status_code, 200)
        self.assertEqual(c.put(base + "2" * 32, content=b"x" * 600000, headers=self.g).status_code, 507)

    def test_long_poll_wakes(self):
        c = self.make()
        self.channel()
        res = {}

        def poll():
            t = time.time()
            res["r"] = c.get("/v1/ch/%s/events?since=0&wait=10" % self.cid, headers=self.a).json()
            res["dt"] = time.time() - t

        th = threading.Thread(target=poll)
        th.start()
        time.sleep(0.5)
        c.put("/v1/ch/%s/files/up/%s" % (self.cid, BID), content=b"wake", headers=self.g)
        th.join(15)
        self.assertEqual(len(res["r"]["files"]), 1)
        self.assertLess(res["dt"], 5)
        t = time.time()
        r = c.get("/v1/ch/%s/events?since=%d&wait=1" % (self.cid, res["r"]["seq"]), headers=self.a).json()
        self.assertEqual(r["files"], [])
        self.assertGreaterEqual(time.time() - t, 0.9)

    def test_no_secrets_in_logs(self):
        import contextlib
        import io
        c = self.make()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            d = self.channel()
            c.put("/v1/ch/%s/files/up/%s" % (self.cid, BID), content=b"secret-payload", headers=self.g)
            c.get("/v1/ch/%s/files/up/%s" % (self.cid, BID), headers=self.a)
        out = buf.getvalue()
        self.assertIn(self.cid[:8], out)
        for s in (self.cid, d["game_token"], d["agent_token"], "secret-payload", BID):
            self.assertNotIn(s, out)

    def test_review_hardening(self):
        # per-box file limit: game uploads can't crowd out the agent's route/prices
        c = self.make(RELAY_MAX_FILES=1, RELAY_CHANNEL_MB=1, RELAY_MAX_BLOB_MB=1)
        self.channel()
        base = "/v1/ch/%s/files/" % self.cid
        self.assertEqual(c.put(base + "up/" + "1" * 32, content=b"a", headers=self.g).status_code, 200)
        self.assertEqual(c.put(base + "up/" + "2" * 32, content=b"a", headers=self.g).status_code, 507)
        self.assertEqual(c.put(base + "down/" + "1" * 32, content=b"r" * 600000, headers=self.a).status_code, 200)
        # per-channel byte quota (600000 down + 600000 up > 1 MB); a too-big upload is cut off while streaming
        self.assertEqual(c.put(base + "up/" + "1" * 32, content=b"x" * (1024 * 1024 + 10), headers=self.g).status_code, 413)
        self.assertEqual(c.put(base + "up/" + "1" * 32, content=b"x" * 600000, headers=self.g).status_code, 507)
        self.assertEqual(os.listdir(os.path.join(self.tmp, self.cid)).count("up-" + "1" * 32), 1)
        self.assertFalse([f for f in os.listdir(os.path.join(self.tmp, self.cid)) if ".tmp" in f], "no temp files left")
        # X-Forwarded-For never decides the client address
        c = self.make(RELAY_CREATE_PER_HOUR=1)
        self.assertEqual(c.post("/v1/channels", headers={"X-Forwarded-For": "1.1.1.1"}).status_code, 200)
        self.assertEqual(c.post("/v1/channels", headers={"X-Forwarded-For": "2.2.2.2"}).status_code, 429)
        # an unconfigured relay (spec defaults) refuses everything, not just channel creation
        c = self.make(RELAY_SECRET="good")
        self.channel()
        L = self.app.state.store.L
        L.secret = "change-me"
        self.assertEqual(c.get("/v1/ch/%s/events" % self.cid, headers=self.a).status_code, 503)

    def test_tokens_are_bound_to_channel_and_role(self):
        c = self.make()
        d1 = self.channel()
        g1 = self.g
        self.channel()
        self.assertEqual(c.get("/v1/ch/%s" % self.cid, headers=g1).status_code, 403)  # channel 1's token on channel 2
        self.assertNotEqual(d1["game_token"], d1["agent_token"])


if __name__ == "__main__":
    unittest.main()
