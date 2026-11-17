#!/usr/bin/env python3
"""Cross-check every game API function and event ForeverScribe uses against the
Forever client's generated API docs (Gethe/wow-ui-source, branch `forever`).
Usage: tools/check_api.py [path-to-wow-ui-source-forever]"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC = sys.argv[1] if len(sys.argv) > 1 else (os.environ.get("FOREVERSCRIBE_UI_SOURCE") or os.path.join(ROOT, "research", "wow-ui-source-forever"))
if not os.path.isdir(SRC):
    sys.exit("Forever UI source not found at %s.\nClone it once: git clone --depth 1 -b forever https://github.com/Gethe/wow-ui-source research/wow-ui-source-forever\n(or set FOREVERSCRIBE_UI_SOURCE)" % SRC)
DOCS = os.path.join(SRC, "Interface", "AddOns", "Blizzard_APIDocumentationGenerated")

funcs, events = {}, set()
for f in os.listdir(DOCS):
    if not f.endswith(".lua"):
        continue
    text = open(os.path.join(DOCS, f), encoding="utf-8", errors="replace").read()
    m = re.search(r'Namespace = "([A-Za-z_]+)"', text)
    ns = m.group(1) if m else None
    for block in re.finditer(r'Name = "([A-Za-z0-9_]+)",\s*\n\s*Type = "Function"', text):
        funcs.setdefault(block.group(1), set()).add(ns)
    events.update(re.findall(r'LiteralName = "([A-Z0-9_]+)"', text))

ui_text = []
for base, _, files in os.walk(os.path.join(SRC, "Interface")):
    if "APIDocumentationGenerated" in base:
        continue
    for f in files:
        if f.endswith(".lua"):
            ui_text.append(open(os.path.join(base, f), encoding="utf-8", errors="replace").read())
ui = "\n".join(ui_text)

code = ""
for rel in ("addon/ForeverScribe/Collect.lua", "addon/ForeverScribe/Core.lua", "addon/ForeverScribe/Waypoint.lua", "addon/ForeverScribe/Npcs.lua", "addon/ForeverScribe/Route.lua", "addon/ForeverScribe/Tooltip.lua", "addon/ForeverScribe/Craft.lua", "addon/ForeverScribe_Live/Live.lua"):  # Util/Defaults call no game API
    code += open(os.path.join(ROOT, rel)).read()
used = set(re.findall(r'(?:Call|U\.Fn)\("([A-Za-z_\.]+)"', code))
used |= {"CreateFrame", "GetPhysicalScreenSize"}
handlers = set(re.findall(r'^function H\.([A-Z_]+)', code, re.M)) | set(re.findall(r'^H\.([A-Z_]+)\s*[,=]', code, re.M))
handlers |= set(re.findall(r'^H\.[A-Z_]+, H\.([A-Z_]+) =', code, re.M))

print("Functions:")
for n in sorted(used):
    ns, _, short = n.rpartition(".")
    ok_doc = short in funcs and ((ns or None) in funcs[short] or (not ns and None in funcs[short]) or (not ns))
    if ns and short in funcs and ns not in funcs[short]:
        ok_doc = False
    in_ui = re.search(r'\b' + re.escape(n) + r'\s*\(', ui) is not None
    status = "doc" if ok_doc else ("ui-source" if in_ui else "UNVERIFIED (Classic-era fallback / optional)")
    print("  %-45s %s" % (n, status))
print("Events (%d handlers):" % len(handlers))
for e in sorted(handlers):
    status = "doc" if e in events else ("ui-source" if ('"%s"' % e) in ui else "UNVERIFIED (registration is pcall-guarded)")
    print("  %-45s %s" % (e, status))
