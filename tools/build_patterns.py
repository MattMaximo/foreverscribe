#!/usr/bin/env python3
"""Build data/patterns.json: recipe item -> crafted item + materials, for the AH tooltip's pattern lines.

  python3 tools/build_patterns.py <market snapshot json> [...]     (<data_dir>/prices/market-*.json, from `prices write`)

Takes every recipe item listed in the given market snapshots, reads its Wowhead Forever tooltip (nether.wowhead.com,
cached 7 days, ~4 per second) and keeps the created item id and reagents. Game data only; no personal data.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from foreverscribe import prices as P, wowhead as WH  # noqa: E402

OUT = os.path.join(ROOT, "data", "patterns.json")


def main(paths):
    ids = set()
    for p in paths:
        with open(p, encoding="utf-8") as f:
            snap = json.load(f)
        ids |= {int(k) for k, r in snap["items"].items() if isinstance(r, list) and len(r) > 6 and r[6]}
    old = {}
    if os.path.isfile(OUT):
        with open(OUT, encoding="utf-8") as f:
            old = json.load(f).get("patterns", {})
    out, miss = dict(old), []
    for n, iid in enumerate(sorted(ids), 1):
        if str(iid) in out:
            continue
        t = P.from_wowhead(WH.item(iid, follow=False))
        if t:
            out[str(iid)] = t
        else:
            miss.append(iid)
        if n % 50 == 0:
            print("%d/%d" % (n, len(ids)), flush=True)
    doc = {"about": "Recipe item -> [created item id, [[reagent item id, count], ...]]. From Wowhead Forever tooltips "
                    "(tools/build_patterns.py). Game data only.",
           "patterns": {k: out[k] for k in sorted(out, key=int)}}
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
        f.write("\n")
    print("wrote %s: %d patterns (%d recipe items without a crafted item: books, plans for other things)" % (
        OUT, len(doc["patterns"]), len(miss)))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1:])
