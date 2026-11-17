#!/usr/bin/env python3
"""Rebuild data/vendor-prices.json: crafting materials any ordinary vendor sells, with the price per unit.

  python3 tools/build_vendor_prices.py <ItemSparse.csv> <wowhead-pages-dir> [--min-vendors 50]

Inputs (game data, nothing personal):
- ItemSparse.csv: Forever's own client item table, from wago.tools
  (https://wago.tools/db2/ItemSparse/csv?build=<Forever build>, product `wowf`). BuyPrice is the vendor's list price
  for VendorStackCount items, so one unit costs BuyPrice / VendorStackCount (Empty Vial: 20c for 5 = 4c each).
- <wowhead-pages-dir>/<itemID>.md: each material's Wowhead Forever page as markdown (its "Sold by" tab / "Vendor
  Locations" line). An item counts as vendor-sold only when at least --min-vendors vendor spots list it, or as many
  unlimited-stock (∞) rows: threads, dyes, spices, vials, flux, water, salt, flour. One-off sellers (the Black
  Market's Arcane Crystal, a few herbs, essences) are left out on purpose: their stock is limited, so their price is not
  a price you can count on.

The companion prefers a price this character actually saw at a vendor (ForeverScribe 0.3+ merchant capture) over
this list price; reputation discounts make the two differ by a few percent.
"""
import csv
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "vendor-prices.json")


def vendor_spots(text):
    """Number of vendor spots on a Wowhead item page: its 'can be purchased in A (n), B, ...' line, or ∞ rows."""
    n = 0
    m = re.search(r"This item can be purchased in (.+?)\.\s*\n", text)
    if m:
        for part in re.split(r",\s*(?:and\s+)?|\s+and\s+", m.group(1)):
            if part.strip():
                k = re.search(r"\((\d+)\)", part)
                n += int(k.group(1)) if k else 1
    return max(n, text.count("\u221e"))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    sparse, pages = argv[0], argv[1]
    need = 50
    if "--min-vendors" in argv:
        need = int(argv[argv.index("--min-vendors") + 1])
    spots = {}
    for f in os.listdir(pages):
        if f.endswith(".md") and f[:-3].isdigit():
            with open(os.path.join(pages, f), encoding="utf-8", errors="replace") as fh:
                spots[int(f[:-3])] = vendor_spots(fh.read())
    items = {}
    with open(sparse, encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            iid = int(r["ID"])
            if spots.get(iid, 0) < need:
                continue
            buy, per = int(r["BuyPrice"] or 0), max(1, int(r["VendorStackCount"] or 1))
            if buy <= 0:
                continue
            items[str(iid)] = [-(-buy // per), r["Display_lang"]]  # round a fraction of a copper up
    out = {"about": ("Crafting materials ordinary vendors sell (Wowhead Forever: >= %d vendor spots) and the price of one "
                     "unit in copper (Forever client ItemSparse BuyPrice / VendorStackCount, via wago.tools). Rebuilt "
                     "with tools/build_vendor_prices.py. A price the character saw at a vendor wins over this list "
                     "price." % need),
           "items": dict(sorted(items.items(), key=lambda kv: int(kv[0])))}
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print("%d vendor-sold materials -> %s" % (len(items), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
