"""Installer tests against a fake HOME + fake WoW folder (never a real machine). launchctl is replaced by a
logger, so nothing is loaded. The Windows installer gets a PowerShell parse check when pwsh exists, else a
static check."""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fsenv  # noqa: E402

ROOT = fsenv.ROOT
sys.path.insert(0, ROOT)
from foreverscribe import __version__, auth  # noqa: E402

DIST = os.path.join(ROOT, "dist")
MAC_KIT = os.path.join(DIST, "ForeverScribe-%s-macos" % __version__)
WIN_KIT = os.path.join(DIST, "ForeverScribe-%s-windows" % __version__)


def tree_hash(path):
    h = hashlib.sha256()
    for base, dirs, files in sorted(os.walk(path)):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(base, f)
            h.update(os.path.relpath(p, path).encode())
            with open(p, "rb") as fh:
                h.update(fh.read())
    return h.hexdigest()


class MacInstaller(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["/bin/bash", os.path.join(ROOT, "tools", "build_dist.sh")], check=True, capture_output=True)

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fs-inst-", dir=os.environ.get("TMPDIR"))
        self.home = os.path.join(self.d, "home")
        self.wow = os.path.join(self.d, "World of Warcraft", "_forever_")
        self.addons = os.path.join(self.wow, "Interface", "AddOns")
        for name in ("Polestar", "auxForever"):
            os.makedirs(os.path.join(self.addons, name))
            with open(os.path.join(self.addons, name, name + ".toc"), "w") as fh:
                fh.write("## Interface: 16001\n")
        self.sv = os.path.join(self.wow, "WTF", "Account", "TESTACCT", "SavedVariables")
        os.makedirs(self.sv)
        with open(os.path.join(self.sv, "Polestar.lua"), "w") as fh:
            fh.write("PolestarDB = {}\n")
        os.makedirs(self.home)
        self.calls = os.path.join(self.d, "launchctl.log")
        self.fake = os.path.join(self.d, "launchctl")
        with open(self.fake, "w") as fh:
            fh.write('#!/bin/bash\necho "$*" >> "%s"\n' % self.calls)
        os.chmod(self.fake, 0o755)
        self.before = tree_hash(self.wow)

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def env(self):
        return dict(os.environ, HOME=self.home, LAUNCHCTL=self.fake)

    def run_kit(self, script, *args, kit=MAC_KIT):
        return subprocess.run(["/bin/bash", os.path.join(kit, script), "--wow-dir", self.wow] + list(args) if script == "install.sh"
                              else ["/bin/bash", os.path.join(kit, script)] + list(args),
                              env=dict(self.env(), FOREVERSCRIBE_WOW_DIR=self.wow), capture_output=True, text=True, timeout=60)

    def support(self, *p):
        return os.path.join(self.home, "Library", "Application Support", "ForeverScribe", *p)

    def test_dry_run_changes_nothing(self):
        code = auth.encode_pairing("http://192.0.2.5:8766", "k1", "fsk_test")
        r = self.run_kit("install.sh", "--pair", code, "--dry-run")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("[dry-run]", r.stdout)
        self.assertEqual(tree_hash(self.wow), self.before)
        self.assertFalse(os.path.exists(os.path.join(self.home, "Library")))
        self.assertFalse(os.path.exists(self.calls))

    def test_requires_a_transport_choice(self):
        r = self.run_kit("install.sh")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--addon-only", r.stdout)

    def test_pair_install_writes_conf_key_and_agent_then_uninstalls_cleanly(self):
        code = auth.encode_pairing("http://192.0.2.5:8766", "k1", "fsk_test")
        r = self.run_kit("install.sh", "--pair", code, "--remind", "30")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.addons, "ForeverScribe", "ForeverScribe.toc")))
        self.assertTrue(os.path.isdir(os.path.join(self.addons, "Polestar")), "other addons untouched")
        with open(os.path.join(self.addons, "ForeverScribe", "Defaults.lua")) as fh:
            self.assertIn("saveReminderMinutes = 30", fh.read())
        with open(self.support("game.conf")) as fh:
            conf = fh.read()
        self.assertIn("PUSH_URL=http://192.0.2.5:8766", conf)
        self.assertIn("KEY_ID=k1", conf)
        self.assertNotIn("fsk_test", conf, "key is not in the conf file")
        with open(self.support("pairing.key")) as fh:
            self.assertEqual(fh.read(), "fsk_test")
        self.assertEqual(oct(os.stat(self.support("pairing.key")).st_mode & 0o777), "0o600")
        plist = os.path.join(self.home, "Library", "LaunchAgents", "io.foreverscribe.sync.plist")
        with open(plist) as fh:
            body = fh.read()
        self.assertIn(self.sv, body)
        self.assertIn("<key>StartInterval</key><integer>120</integer>", body, "retries the spool even without saves")
        with open(self.calls) as fh:
            self.assertIn("bootstrap", fh.read())
        self.assertIn("not reachable", r.stdout)  # TEST-NET address: nothing listens
        # reinstall replaces our own folders in place (no backup of our own install)
        r = self.run_kit("install.sh", "--pair", code)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len([d for d in os.listdir(self.support()) if d.startswith("backup-")]), 0)
        r = self.run_kit("uninstall.sh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.addons, "ForeverScribe")))
        self.assertFalse(os.path.exists(plist))
        self.assertFalse(os.path.exists(self.support()))
        self.assertTrue(os.path.isdir(os.path.join(self.addons, "Polestar")))

    def test_folder_mode_and_existing_addon_backup_restore(self):
        os.makedirs(os.path.join(self.addons, "ForeverScribe"))
        with open(os.path.join(self.addons, "ForeverScribe", "mine.txt"), "w") as fh:
            fh.write("user copy")
        folder = os.path.join(self.d, "Dropbox", "ForeverScribe")
        r = self.run_kit("install.sh", "--folder", folder)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.isdir(folder))
        with open(self.support("game.conf")) as fh:
            conf = fh.read()
        self.assertIn("FOLDER_DEST=", conf)
        self.assertIn("PUSH_URL=''", conf)
        r = self.run_kit("uninstall.sh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(self.addons, "ForeverScribe", "mine.txt")) as fh:
            self.assertEqual(fh.read(), "user copy", "the pre-existing folder is restored")

    def test_addon_only_for_same_computer(self):
        r = self.run_kit("install.sh", "--addon-only")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("setup --mode local", r.stdout)
        self.assertTrue(os.path.isfile(os.path.join(self.addons, "ForeverScribe", "Core.lua")))
        self.assertFalse(os.path.exists(os.path.join(self.home, "Library", "LaunchAgents", "io.foreverscribe.sync.plist")))
        self.assertFalse(os.path.exists(self.support("game.conf")))

    def test_replaces_v02_sync_agent(self):
        agents = os.path.join(self.home, "Library", "LaunchAgents")
        os.makedirs(agents)
        old = os.path.join(agents, "org.example.foreverscribe.sync.plist")
        with open(old, "w") as fh:
            fh.write("<plist/>")
        r = self.run_kit("install.sh", "--pair", auth.encode_pairing("http://192.0.2.5:8766", "k1", "fsk_t"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(old))
        with open(self.calls) as fh:
            self.assertIn("bootout gui/%d/org.example.foreverscribe.sync" % os.getuid(), fh.read())

    def test_bad_pairing_code(self):
        r = self.run_kit("install.sh", "--pair", "nope")
        self.assertEqual(r.returncode, 2)
        r = self.run_kit("install.sh", "--pair", "fs1.AAAA")
        self.assertEqual(r.returncode, 2)

    def test_repo_checkout_works_as_a_kit(self):
        r = subprocess.run(["/bin/bash", os.path.join(ROOT, "installers", "macos", "install.sh"), "--wow-dir", self.wow,
                            "--addon-only", "--dry-run"], env=self.env(), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_kit_contents(self):
        names = set()
        for base, _, files in os.walk(MAC_KIT):
            names |= {os.path.relpath(os.path.join(base, f), MAC_KIT) for f in files}
        for need in ("install.sh", "uninstall.sh", "installers/macos/foreverscribe-sync.sh", "README.md", "LICENSE",
                     "LICENSE-wow-ai.txt", "addon/ForeverScribe/ForeverScribe.toc", "addon/ForeverScribe/Defaults.lua"):
            self.assertIn(need, names)
        self.assertTrue(os.path.exists(os.path.join(DIST, "ForeverScribe-%s-macos.zip" % __version__)))


class WindowsInstaller(unittest.TestCase):
    SCRIPTS = [os.path.join(ROOT, "installers", "windows", n) for n in ("install.ps1", "foreverscribe-sync.ps1")]

    def test_powershell_parses(self):
        pwsh = shutil.which("pwsh") or shutil.which("powershell")
        if not pwsh:
            self.skipTest("pwsh not installed (static checks below still run)")
        for s in self.SCRIPTS:
            cmd = ("$e=$null; [System.Management.Automation.Language.Parser]::ParseFile('%s',[ref]$null,[ref]$e) | Out-Null; "
                   "if ($e.Count) { $e | ForEach-Object { $_.Message }; exit 1 }" % s)
            r = subprocess.run([pwsh, "-NoProfile", "-Command", cmd], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_static_checks(self):
        for s in self.SCRIPTS:
            with open(s, encoding="utf-8") as fh:
                src = fh.read()
            code = re.sub(r"<#.*?#>", "", src, flags=re.S)
            code = re.sub(r"(?m)#.*$", "", code)
            code = re.sub(r'"(?:`.|[^"`])*"', '""', code)
            code = re.sub(r"'[^']*'", "''", code)
            for o, c in ("{}", "()", "[]"):
                self.assertEqual(code.count(o), code.count(c), "%s: unbalanced %s%s" % (os.path.basename(s), o, c))
            self.assertNotIn("Invoke-Expression", src)
            self.assertNotIn("-Verb RunAs", src, "never asks for admin")
        with open(self.SCRIPTS[0], encoding="utf-8") as fh:
            src = fh.read()
        for need in ("-DryRun", "-Uninstall", "-AddonOnly", "-Pair", "-Folder", "Register-ScheduledTask", "/v1/auth-check"):
            self.assertIn(need.lstrip("-") if need.startswith("-") else need, src)

    def test_signature_matches_python(self):
        """The PowerShell signer builds the same canonical string as auth.py."""
        with open(self.SCRIPTS[1], encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn('$canon = "fs1`n$ts`nPOST`n$path`n$digest"', src)
        with open(os.path.join(ROOT, "foreverscribe", "auth.py")) as fh:
            self.assertIn('"fs1\\n%s\\n%s\\n%s\\n%s"', fh.read())

    def test_windows_kit_has_crlf_and_contents(self):
        subprocess.run(["/bin/bash", os.path.join(ROOT, "tools", "build_dist.sh")], check=True, capture_output=True)
        with open(os.path.join(WIN_KIT, "install.ps1"), "rb") as fh:
            body = fh.read()
        self.assertIn(b"\r\n", body)
        self.assertNotIn(b"\r\r\n", body)
        self.assertTrue(os.path.isfile(os.path.join(WIN_KIT, "installers", "windows", "foreverscribe-sync.ps1")))
        self.assertTrue(os.path.isfile(os.path.join(WIN_KIT, "addon", "ForeverScribe", "ForeverScribe.toc")))
        self.assertTrue(os.path.exists(os.path.join(DIST, "ForeverScribe-%s-windows.zip" % __version__)))


if __name__ == "__main__":
    unittest.main()
