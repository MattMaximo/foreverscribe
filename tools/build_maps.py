#!/usr/bin/env python3
"""Build foreverscribe/gamedata/maps.json from Blizzard's client map tables (via wago.tools).

  tools/build_maps.py [--forever-build 1.60.1.70938] [--era-build 1.15.9.70576] [--csv-dir DIR]

Reads UiMap + UiMapAssignment for the Forever client and for Classic Era and writes, per Forever uiMapID:
name, type, parent, the AreaID it covers, its world bounds in Forever, and its Era bounds when they differ.
Forever redrew some maps (Mulgore, Eastern Plaguelands, Redridge Mountains, Stormwind City): Wowhead Forever
still lists old Classic-frame coordinates for NPCs there, so `foreverscribe way` converts them with these
bounds. Game data (c) Blizzard Entertainment, used as facts for interoperability.
"""
import argparse
import csv
import io
import json
import os
import sys
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "foreverscribe", "gamedata", "maps.json")
UA = {"User-Agent": "Mozilla/5.0 (ForeverScribe build_maps)"}


def table(name, build, csv_dir):
    if csv_dir:
        path = os.path.join(csv_dir, "%s-%s.csv" % (name, build))
        if os.path.exists(path):
            return list(csv.DictReader(open(path, encoding="utf-8")))
    url = "https://wago.tools/db2/%s/csv?build=%s" % (name, build)
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
        return list(csv.DictReader(io.StringIO(r.read().decode("utf-8"))))


def bounds(row):
    # Region_0/1 = world min x/y, Region_3/4 = world max x/y (Region_2/5 are z).
    return [round(float(row["Region_%d" % i]), 3) for i in (0, 1, 3, 4)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--forever-build", default="1.60.1.70938")
    ap.add_argument("--era-build", default="1.15.9.70576")
    ap.add_argument("--csv-dir", help="use <Table>-<build>.csv files from here instead of downloading")
    a = ap.parse_args()
    fmaps = {int(r["ID"]): r for r in table("UiMap", a.forever_build, a.csv_dir)}
    fass = [r for r in table("UiMapAssignment", a.forever_build, a.csv_dir) if r["OrderIndex"] == "0"]
    eass = {int(r["UiMapID"]): r for r in table("UiMapAssignment", a.era_build, a.csv_dir) if r["OrderIndex"] == "0"}
    out = {}
    for r in fass:
        m = int(r["UiMapID"])
        info = fmaps.get(m)
        if not info:
            continue
        d = {"name": info["Name_lang"], "type": int(info["Type"]), "parent": int(info["ParentUiMapID"]),
             "area": int(r["AreaID"]), "continent_map": int(r["MapID"]), "bounds": bounds(r)}
        e = eass.get(m)
        if e and [round(x, 1) for x in bounds(e)] != [round(x, 1) for x in d["bounds"]]:
            d["era_bounds"] = bounds(e)
        out[str(m)] = d
    data = {"source": "wago.tools UiMap + UiMapAssignment", "forever_build": a.forever_build, "era_build": a.era_build,
            "note": "bounds = world [minX, minY, maxX, maxY]; map x% runs from maxY to minY, y% from maxX to minX. "
                    "era_bounds only where Forever redrew the map.", "maps": out}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    redrawn = [v["name"] for v in out.values() if v.get("era_bounds")]
    print("wrote %s: %d maps; redrawn vs Era: %s" % (OUT, len(out), ", ".join(sorted(redrawn))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
