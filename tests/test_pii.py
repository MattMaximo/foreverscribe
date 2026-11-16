"""Nothing personal in the tree: generic patterns (IPs, home folders, tokens, keys, e-mail) plus the
maintainer's own denylist, which lives outside the repo (see tools/pii_check.py)."""
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT = fsenv.ROOT
sys.path.insert(0, os.path.join(ROOT, "tools"))
import pii_check  # noqa: E402


class PII(unittest.TestCase):
    def test_tree_is_clean(self):
        real_cfg = os.environ.get("FOREVERSCRIBE_REAL_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".config", "foreverscribe")
        env = dict(os.environ)
        deny = os.path.join(real_cfg, "pii-denylist.txt")
        if os.path.exists(deny):
            env["FOREVERSCRIBE_PII_DENYLIST"] = deny
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "pii_check.py")], cwd=ROOT, env=env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_patterns_catch_the_usual_suspects(self):
        bad = "\n".join([
            "push to http://" + ".".join(["100", "101", "102", "103"]) + ":8766", "cd /Users" + "/realperson/WoW",
            "C:" + "\\Users\\" + "realperson\\AppData",
            "token gho_" + "a" * 36, "key = 'fsk_" + "b" * 40 + "'", "mail me at real.person" + "@" + "gmail.com",
            "X-API-Key: " + "1a2b3c4d" * 6,
        ])
        hits = pii_check.scan_text(bad, "t", ["Moonfluff"])
        self.assertEqual(len(hits), 7, hits)
        ok = "\n".join(["http://192.0.2.5:8766", "/Users/someone/.config", r"C:\Users\someone\AppData", "pet Lil' Smoky",
                        "see https://scribe.example.com", "user@example.com"])
        self.assertEqual(pii_check.scan_text(ok, "t", []), [])
        self.assertEqual(len(pii_check.scan_text("hi Moonfluff!\nmoonfluff's", "t", ["Moonfluff"])), 1,
                         "whole word, case-insensitive; possessive form is a different token")

    def test_fixtures_are_synthetic(self):
        for f in os.listdir(os.path.join(ROOT, "tests", "fixtures")):
            if os.path.isdir(os.path.join(ROOT, "tests", "fixtures", f)):
                continue  # fixtures/polestar: Polestar's files hold no realm or character name at all
            with open(os.path.join(ROOT, "tests", "fixtures", f), encoding="utf-8") as fh:
                text = fh.read()
            self.assertIn("Forever-Test", text, f + " uses the synthetic realm")


if __name__ == "__main__":
    unittest.main()
