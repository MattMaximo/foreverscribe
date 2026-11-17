#!/usr/bin/env python3
"""Scan the working tree (and optionally git history) for personal data and secrets before a push.

  python3 tools/pii_check.py            working tree (tracked + untracked, minus .gitignore'd)
  python3 tools/pii_check.py --history  also every patch in `git log -p --all`

Two layers:
1. Generic patterns shipped here: CGNAT/Tailscale-range and LAN IPs, personal home folders, tokens,
   API-key-shaped strings, e-mail addresses.
2. Your own denylist, kept OUTSIDE the repo so the repo never contains it: one string per line in
   $FOREVERSCRIBE_PII_DENYLIST or <config dir>/pii-denylist.txt (character names, account folder,
   usernames, IPs, keys). Matching is case-insensitive and whole-word.
Exit 1 when anything is found.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)

PLACEHOLDER_USERS = {"someone", "you", "me", "username", "name", "user", "shared", "runner", "example", "<you>", "$user"}
PATTERNS = [
    ("tailscale/CGNAT IP", re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b")),
    ("LAN IP", re.compile(r"\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b")),
    ("home folder", re.compile(r"(?:/Users/|/home/|[Cc]:\\\\?Users\\\\?)([A-Za-z0-9._$<>-]+)")),
    ("GitHub token", re.compile(r"\bgh[opsu]_[A-Za-z0-9]{20,}")),
    ("API key", re.compile(r"\b(?:sk|xox[bp])-[A-Za-z0-9-]{20,}")),
    ("Telegram bot token", re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b")),
    ("pairing key", re.compile(r"\bfsk_[A-Za-z0-9_-]{30,}")),
    ("48-char key", re.compile(r"\b(?=[0-9a-z]*\d)(?=[0-9a-z]*[a-z])[0-9a-z]{48}\b")),
    ("e-mail", re.compile(r"\b[A-Za-z0-9._%+-]+@(?!example\.(?:com|org))[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
]
SKIP_DIRS = {".git", "dist", "data", "research", "__pycache__", "lua", "src", ".venv"}
SKIP_SUFFIX = (".zip", ".png", ".db", ".pyc")


def denylist():
    path = os.environ.get("FOREVERSCRIBE_PII_DENYLIST")
    if not path:
        from foreverscribe import config as C
        path = os.path.join(os.path.dirname(C.config_path()), "pii-denylist.txt")
    words = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            words = [w.strip() for w in fh if w.strip() and not w.startswith("#")]
    return path, words


def files():
    try:
        out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.split("\n")
        return [f for f in out if f and not f.endswith(SKIP_SUFFIX)]
    except (OSError, subprocess.CalledProcessError):
        res = []
        for base, dirs, fs in os.walk(ROOT):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            res += [os.path.relpath(os.path.join(base, f), ROOT) for f in fs if not f.endswith(SKIP_SUFFIX)]
        return res


def scan_text(text, where, words):
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        for label, rx in PATTERNS:
            for m in rx.finditer(line):
                if label == "home folder" and m.group(1).lower().strip("<>") in PLACEHOLDER_USERS | {x.strip("<>") for x in PLACEHOLDER_USERS}:
                    continue
                hits.append("%s:%d: %s: %s" % (where, n, label, m.group(0)))
        for w in words:
            if re.search(r"(?<![A-Za-z0-9])" + re.escape(w) + r"(?![A-Za-z0-9'])", line, re.I):
                hits.append("%s:%d: denylisted string #%d" % (where, n, words.index(w) + 1))
    return hits


def scan_tree(words):
    hits = []
    for rel in files():
        p = os.path.join(ROOT, rel)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        hits += scan_text(text, rel, words)
    return hits


def scan_history(words):
    try:
        log = subprocess.run(["git", "log", "-p", "--all", "--no-color"], cwd=ROOT, capture_output=True, text=True,
                             errors="replace").stdout
    except OSError:
        return []
    added = "\n".join(l[1:] for l in log.splitlines() if l.startswith("+") and not l.startswith("+++"))
    return scan_text(added, "git-history", words)


def main(argv):
    path, words = denylist()
    hits = scan_tree(words)
    if "--history" in argv:
        hits += scan_history(words)
    print("pii_check: %d personal strings from %s%s" % (len(words), path, "" if words else " (none: generic patterns only)"))
    for h in hits:
        print(h)
    print("pii_check: %s" % ("CLEAN" if not hits else "%d finding(s)" % len(hits)))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
