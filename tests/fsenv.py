"""Shared test setup: isolate every test from the developer's real config and data."""
import os
import shutil
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FIX = os.path.join(ROOT, "tests", "fixtures")

_SANDBOX = tempfile.mkdtemp(prefix="fs-sandbox-", dir=os.environ.get("TMPDIR"))
os.environ["FOREVERSCRIBE_CONFIG"] = os.path.join(_SANDBOX, "no-config.toml")
os.environ["FOREVERSCRIBE_DATA"] = os.path.join(_SANDBOX, "data")
os.environ["FOREVERSCRIBE_PUSH_URL"] = ""
os.environ["FOREVERSCRIBE_FOREVERDB"] = "off"  # never download forever-db in tests; tests that need it stub resolve.FDB
for k in ("FOREVERSCRIBE_DB", "FOREVERSCRIBE_SOURCES", "FOREVERSCRIBE_CHAR", "WOWGG_KEY", "FOREVERSCRIBE_ALLOW"):
    os.environ.pop(k, None)


def find_lua():
    """A Lua 5.1 interpreter: tools/lua (tools/get_lua.sh builds it), else lua5.1 / lua on PATH."""
    cand = [os.path.join(ROOT, "tools", "lua", "bin", "lua")]
    for d in os.environ.get("PATH", "").split(os.pathsep):
        cand += [os.path.join(d, "lua5.1"), os.path.join(d, "lua")]
    for c in cand:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            import subprocess
            v = subprocess.run([c, "-v"], capture_output=True, text=True)
            if "5.1" in (v.stdout + v.stderr):
                return c
    return None


def cleanup():
    shutil.rmtree(_SANDBOX, ignore_errors=True)
