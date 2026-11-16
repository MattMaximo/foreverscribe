#!/bin/bash
# Build the game-side kits into dist/:
#   ForeverScribe-<ver>-macos.zip     addon + install.sh/uninstall.sh + sync agent (+ optional live capture)
#   ForeverScribe-<ver>-windows.zip   addon + install.ps1 + sync agent
#   ForeverScribe-addon-<ver>.zip     just the addon folders: ForeverScribe, _Live, _Prices, _Route01-10 (same-computer installs)
# Usage: tools/build_dist.sh [--copy-to DIR]   (copies the macOS kit + addon zip + sums to DIR)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(sed -n 's/^## Version: //p' "$ROOT/addon/ForeverScribe/ForeverScribe.toc")"
PYVER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/foreverscribe/__init__.py")"
[ "$VER" = "$PYVER" ] || { echo "version mismatch: addon $VER vs package $PYVER" >&2; exit 1; }
DIST="$ROOT/dist"
COPY_TO=""
[ "${1:-}" = "--copy-to" ] && COPY_TO="${2:?--copy-to needs a folder}"

rm -rf "$DIST"
mkdir -p "$DIST"

common() {  # common <kit dir>
	mkdir -p "$1/addon"
	cp -R "$ROOT/addon/ForeverScribe" "$ROOT/addon/ForeverScribe_Live" "$ROOT/addon/ForeverScribe_Prices" "$ROOT"/addon/ForeverScribe_Route[0-9][0-9] "$1/addon/"
	cp "$ROOT/LICENSE" "$1/LICENSE"
	cp "$ROOT/NOTICE.md" "$1/NOTICE.md"
	cp "$ROOT/addon/ForeverScribe_Live/LICENSE-wow-ai.txt" "$1/LICENSE-wow-ai.txt"
	cp "$ROOT/docs/GAME-PC.md" "$1/README.md"
}

MAC="$DIST/ForeverScribe-$VER-macos"
common "$MAC"
mkdir -p "$MAC/installers/macos" "$MAC/foreverscribe"
cp "$ROOT/installers/macos/install.sh" "$ROOT/installers/macos/uninstall.sh" "$MAC/"
cp "$ROOT/installers/macos/foreverscribe-sync.sh" "$MAC/installers/macos/"
cp "$ROOT/foreverscribe/live_capture.py" "$MAC/foreverscribe/"
chmod 755 "$MAC"/*.sh "$MAC/installers/macos/"*.sh

WIN="$DIST/ForeverScribe-$VER-windows"
common "$WIN"
mkdir -p "$WIN/installers/windows"
cp "$ROOT/installers/windows/install.ps1" "$WIN/"
cp "$ROOT/installers/windows/foreverscribe-sync.ps1" "$WIN/installers/windows/"
# Windows text files get CRLF line endings
for f in "$WIN/install.ps1" "$WIN/installers/windows/foreverscribe-sync.ps1" "$WIN/README.md"; do
	perl -pi -e 's/\r?\n/\r\n/' "$f"
done

find "$DIST" -name '.DS_Store' -delete
for k in "$MAC" "$WIN"; do  # never ship a written price file or route
	grep -q '^ForeverScribe_PriceData = nil$' "$k/addon/ForeverScribe_Prices/Prices.lua" || { echo "addon/ForeverScribe_Prices/Prices.lua is not the empty file" >&2; exit 1; }
done
(cd "$DIST" && COPYFILE_DISABLE=1 zip -qrX "ForeverScribe-$VER-macos.zip" "$(basename "$MAC")")
(cd "$DIST" && COPYFILE_DISABLE=1 zip -qrX "ForeverScribe-$VER-windows.zip" "$(basename "$WIN")")
(cd "$MAC/addon" && COPYFILE_DISABLE=1 zip -qrX "$DIST/ForeverScribe-addon-$VER.zip" ForeverScribe ForeverScribe_Live ForeverScribe_Prices ForeverScribe_Route[0-9][0-9])
(cd "$DIST" && shasum -a 256 ./*.zip > SHA256SUMS)
echo "built $DIST (v$VER)"

if [ -n "$COPY_TO" ]; then
	mkdir -p "$COPY_TO"
	cp "$DIST/ForeverScribe-$VER-macos.zip" "$DIST/ForeverScribe-addon-$VER.zip" "$DIST/SHA256SUMS" "$COPY_TO/"
	cp "$ROOT/docs/GAME-PC.md" "$COPY_TO/INSTALL-$VER.md"
	echo "copied to $COPY_TO"
fi
