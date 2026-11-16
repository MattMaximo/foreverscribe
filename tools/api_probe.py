#!/usr/bin/env python3
"""Classify candidate API names as doc / ui-source / MISSING for Forever.
Usage: tools/api_probe.py Name [Name ...]   (functions as NS.Func or Func; events in CAPS)"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api_lookup import load  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC = os.path.join(os.environ.get("FOREVERSCRIBE_UI_SOURCE") or os.path.join(ROOT, "research", "wow-ui-source-forever"), "Interface")


def ui_text():
    parts = []
    for base, _, files in os.walk(SRC):
        if "APIDocumentationGenerated" in base:
            continue
        for f in files:
            if f.endswith(".lua"):
                parts.append(open(os.path.join(base, f), encoding="utf-8", errors="replace").read())
    return "\n".join(parts)


if __name__ == "__main__":
    funcs, events, _ = load()
    ui = ui_text()
    for q in sys.argv[1:]:
        if re.fullmatch(r"[A-Z0-9_]+", q):
            st = "doc" if q in events else ("ui-source" if ('"%s"' % q) in ui else "MISSING")
        else:
            ns, _, short = q.rpartition(".")
            doc = any((h[0] or "") == ns for h in funcs.get(short, []))
            n = len(re.findall(r"\b" + re.escape(q) + r"\s*\(", ui))
            st = "doc" if doc else ("ui-source(%d)" % n if n else "MISSING")
        print("%-55s %s" % (q, st))
