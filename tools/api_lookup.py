#!/usr/bin/env python3
"""Look up functions/events in Forever's generated API docs.
Usage: tools/api_lookup.py C_Reputation.GetFactionDataByIndex GetNumFactions UPDATE_FACTION ...
Prints doc status, arguments and returns (one line each) so collectors match real shapes."""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
UI_SOURCE = os.environ.get("FOREVERSCRIBE_UI_SOURCE") or os.path.join(ROOT, "research", "wow-ui-source-forever")
DOCS = os.path.join(UI_SOURCE, "Interface", "AddOns", "Blizzard_APIDocumentationGenerated")


def load():
    funcs, events, tables = {}, {}, {}
    for f in sorted(os.listdir(DOCS)):
        if not f.endswith(".lua"):
            continue
        text = open(os.path.join(DOCS, f), encoding="utf-8", errors="replace").read()
        m = re.search(r'Namespace = "([A-Za-z_]+)"', text)
        ns = m.group(1) if m else None
        for b in re.finditer(r'\{\s*Name = "([A-Za-z0-9_]+)",\s*Type = "Function",(.*?)\n\t\t\},', text, re.S):
            funcs.setdefault(b.group(1), []).append((ns, f, b.group(2)))
        for b in re.finditer(r'\{\s*Name = "([A-Za-z0-9_]+)",\s*Type = "Event",\s*LiteralName = "([A-Z0-9_]+)"(.*?)\n\t\t\},', text, re.S):
            events[b.group(2)] = (f, b.group(3))
        for b in re.finditer(r'\{\s*Name = "([A-Za-z0-9_]+)",\s*Type = "Structure",(.*?)\n\t\t\},', text, re.S):
            tables[b.group(1)] = (f, b.group(2))
    return funcs, events, tables


def fields(body, key):
    m = re.search(key + r' =\s*\{(.*?)\n\t\t\t\}', body, re.S)
    if not m:
        return ""
    return ", ".join("%s:%s" % (a, b) for a, b in re.findall(r'Name = "(\w+)", Type = "(\w+)"', m.group(1)))


if __name__ == "__main__":
    funcs, events, tables = load()
    for q in sys.argv[1:]:
        if q.isupper() and q in events:
            f, body = events[q]
            print("EVENT %-40s %s  payload(%s)" % (q, f, fields(body, "Payload")))
            continue
        if q.startswith("struct:"):
            name = q[7:]
            if name in tables:
                f, body = tables[name]
                print("STRUCT %s %s  {%s}" % (name, f, fields(body, "Fields")))
            else:
                print("STRUCT %s MISSING" % name)
            continue
        ns, _, short = q.rpartition(".")
        hits = [h for h in funcs.get(short, []) if (h[0] or "") == ns]
        if not hits:
            print("MISSING %s%s" % (q, ("  (exists in: %s)" % [h[0] for h in funcs.get(short, [])]) if short in funcs else ""))
            continue
        for h in hits:
            print("FUNC %-50s %s  args(%s) -> (%s)" % (q, h[1], fields(h[2], "Arguments"), fields(h[2], "Returns")))
