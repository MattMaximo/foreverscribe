#!/bin/bash
# ForeverScribe game-side installer for macOS (the computer that plays WoW: Forever).
#
#   ./install.sh --addon-only                 same computer as your agent: just the addon
#   ./install.sh --pair fs1.xxxx              agent on another computer: push over HTTP (code from `foreverscribe pair`)
#   ./install.sh --folder "<synced folder>"   agent on another computer: copy into iCloud Drive/Dropbox/OneDrive/...
#   (--pair and --folder can be combined: push first, the folder is a backup)
# Options: --wow-dir DIR   --remind MINUTES (save reminder, 0 = off)   --extra "ForeverForge*.lua Polestar.lua ..."
#          --dry-run (show, change nothing)
# Touches only: Interface/AddOns/ForeverScribe(_Live, _Prices, _Route01-10), ~/Library/Application Support/ForeverScribe/,
#   ~/Library/LaunchAgents/io.foreverscribe.sync.plist. Undo everything with ./uninstall.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$HERE"; [ -d "$KIT/addon" ] || KIT="$(cd "$HERE/../.." && pwd)"   # zip kit, or a repo checkout
WOW_DIR="${FOREVERSCRIBE_WOW_DIR:-/Applications/World of Warcraft/_forever_}"
SUPPORT="${FOREVERSCRIBE_SUPPORT:-$HOME/Library/Application Support/ForeverScribe}"
AGENTS="${FOREVERSCRIBE_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LABEL="io.foreverscribe.sync"
PLIST="$AGENTS/$LABEL.plist"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
DRY=0; ADDON_ONLY=0; PAIR=""; FOLDER=""; REMIND=""; EXTRA="ForeverForge*.lua Polestar.lua"
ADDON_DIRS="ForeverScribe ForeverScribe_Live ForeverScribe_Prices"
for i in 01 02 03 04 05 06 07 08 09 10; do ADDON_DIRS="$ADDON_DIRS ForeverScribe_Route$i"; done

say() { printf '%s\n' "$*"; }
run() { if [ $DRY -eq 1 ]; then say "  [dry-run] $*"; else "$@"; fi; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY=1 ;;
		--addon-only) ADDON_ONLY=1 ;;
		--pair) PAIR="${2:?--pair needs the code from foreverscribe pair}"; shift ;;
		--folder) FOLDER="${2:?--folder needs a path}"; shift ;;
		--wow-dir) WOW_DIR="${2:?}"; shift ;;
		--remind) REMIND="${2:?}"; shift ;;
		--extra) EXTRA="${2-}"; shift ;;
		-h|--help) usage 0 ;;
		*) say "unknown option: $1"; usage 2 ;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] && { say "Run this as your normal user, not with sudo."; exit 1; }
ADDONS="$WOW_DIR/Interface/AddOns"
[ -d "$ADDONS" ] || { say "AddOns folder not found: $ADDONS"; say "Pass --wow-dir \"<...>/World of Warcraft/_forever_\"."; exit 1; }
for d in $ADDON_DIRS; do
	[ -f "$KIT/addon/$d/$d.toc" ] || { say "Kit is incomplete: missing addon/$d"; exit 1; }
done
case "$REMIND" in ''|*[!0-9]*) [ -n "$REMIND" ] && { say "--remind takes whole minutes"; exit 2; } ;; esac

PUSH_URL=""; KEY_ID=""; KEY=""
if [ -n "$PAIR" ]; then
	case "$PAIR" in fs1.*) ;; *) say "That isn't a ForeverScribe pairing code (it starts with fs1.)"; exit 2 ;; esac
	b="${PAIR#fs1.}"; b="$(printf '%s' "$b" | tr '_-' '/+')"
	while [ $(( ${#b} % 4 )) -ne 0 ]; do b="$b="; done
	json="$(printf '%s' "$b" | base64 -D 2>/dev/null || printf '%s' "$b" | base64 -d 2>/dev/null)" || true
	PUSH_URL="$(printf '%s' "$json" | sed -n 's/.*"u":"\([^"]*\)".*/\1/p')"
	KEY_ID="$(printf '%s' "$json" | sed -n 's/.*"i":"\([^"]*\)".*/\1/p')"
	KEY="$(printf '%s' "$json" | sed -n 's/.*"k":"\([^"]*\)".*/\1/p')"
	[ -n "$PUSH_URL" ] && [ -n "$KEY_ID" ] && [ -n "$KEY" ] || { say "Pairing code is damaged; copy it again."; exit 2; }
fi
if [ $ADDON_ONLY -eq 0 ] && [ -z "$PUSH_URL" ] && [ -z "$FOLDER" ]; then
	say "Choose how the files reach your agent:"
	say "  same computer:      ./install.sh --addon-only"
	say "  another computer:   ./install.sh --pair <code from 'foreverscribe pair'>   and/or   --folder <synced folder>"
	exit 2
fi
if pgrep -xq "World of Warcraft" 2>/dev/null; then
	say "Note: WoW is running. New addons are picked up after you fully quit and restart the game."
fi

TS="$(date +%Y%m%d-%H%M%S)"
run mkdir -p "$SUPPORT"
MANIFEST="$SUPPORT/install-manifest.txt"
[ $DRY -eq 0 ] && { echo "installed_at=$TS"; echo "wow_dir=$WOW_DIR"; echo "version=0.8.2"; } > "$MANIFEST.new"

say "1) Addon -> $ADDONS"
for d in $ADDON_DIRS; do
	if [ -e "$ADDONS/$d" ]; then
		if [ -f "$SUPPORT/installed-$d" ]; then
			run rm -rf "$ADDONS/$d"   # our own previous install: replace in place
		else
			run mkdir -p "$SUPPORT/backup-$TS"
			run mv "$ADDONS/$d" "$SUPPORT/backup-$TS/$d"
			[ $DRY -eq 0 ] && echo "backup_$d=$SUPPORT/backup-$TS/$d" >> "$MANIFEST.new"
			say "   existing $d moved to $SUPPORT/backup-$TS/"
		fi
	fi
	run cp -R "$KIT/addon/$d" "$ADDONS/$d"
	run touch "$SUPPORT/installed-$d"
	[ $DRY -eq 0 ] && echo "addon=$ADDONS/$d" >> "$MANIFEST.new"
done
if [ -n "$REMIND" ]; then
	say "   save reminder: every $REMIND min without a /reload"
	if [ $DRY -eq 0 ]; then
		printf -- '-- Written by install.sh. `/scribe remind <min>|off` in game overrides it.\nForeverScribe_Defaults = {\n\tsaveReminderMinutes = %d,\n}\n' "$REMIND" > "$ADDONS/ForeverScribe/Defaults.lua"
	fi
fi
if [ $DRY -eq 0 ] && [ -f "$MANIFEST" ]; then grep '^backup_' "$MANIFEST" >> "$MANIFEST.new" || true; fi

# stop an older ForeverScribe sync agent (v0.2 kits used another label) so only one ships files
for old in "$AGENTS"/*.foreverscribe.sync.plist; do
	[ -f "$old" ] || continue
	old_label="$(basename "$old" .plist)"
	[ "$old_label" = "$LABEL" ] && continue
	say "   replacing the older sync agent ($old_label)"
	run "$LAUNCHCTL" bootout "gui/$(id -u)/$old_label" || true
	run rm -f "$old"
done

if [ $ADDON_ONLY -eq 1 ]; then
	if [ -f "$PLIST" ]; then run "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" || true; run rm -f "$PLIST"; fi
	[ $DRY -eq 0 ] && mv -f "$MANIFEST.new" "$MANIFEST"
	say ""
	say "Done (addon only). Your agent reads $WOW_DIR/WTF directly: run 'foreverscribe setup --mode local' there."
	say "Next: fully quit and restart WoW, enable ForeverScribe at character select, log in, /scribe status, /reload."
	exit 0
fi

say "2) Sync agent -> $SUPPORT"
run rm -f "$SUPPORT/prices-checked"   # fetch prices on the first run
run cp "$KIT/installers/macos/foreverscribe-sync.sh" "$SUPPORT/foreverscribe-sync.sh" 2>/dev/null || run cp "$HERE/foreverscribe-sync.sh" "$SUPPORT/foreverscribe-sync.sh"
run chmod 755 "$SUPPORT/foreverscribe-sync.sh"
[ -f "$KIT/foreverscribe/live_capture.py" ] && run cp "$KIT/foreverscribe/live_capture.py" "$SUPPORT/live_capture.py"
if [ $DRY -eq 0 ]; then
	umask 077
	{
		echo "# ForeverScribe game-side settings (install.sh $TS). Sourced by foreverscribe-sync.sh."
		printf 'WOW_DIR=%q\n' "$WOW_DIR"
		printf 'PUSH_URL=%q\n' "$PUSH_URL"
		printf 'KEY_ID=%q\n' "$KEY_ID"
		printf 'FOLDER_DEST=%q\n' "$FOLDER"
		printf 'EXTRA_SV=%q\n' "$EXTRA"
	} > "$SUPPORT/game.conf"
	if [ -n "$KEY" ]; then printf '%s' "$KEY" > "$SUPPORT/pairing.key"; chmod 600 "$SUPPORT/pairing.key"; fi
	umask 022
else
	say "  [dry-run] write $SUPPORT/game.conf (push ${PUSH_URL:-off}, folder ${FOLDER:-off})"
fi
[ -n "$FOLDER" ] && run mkdir -p "$FOLDER"
run mkdir -p "$AGENTS"

# launchd WatchPaths needs concrete folders: every account's SavedVariables folder that exists
# now, plus the Account folder itself (new accounts / first save).
WATCH="		<string>$WOW_DIR/WTF/Account</string>"
if [ -n "$FOLDER" ]; then  # routes the agent writes into the synced folder (foreverscribe route write)
	run mkdir -p "$FOLDER/_route" "$FOLDER/_prices"
	WATCH="$WATCH
		<string>$FOLDER/_route</string>
		<string>$FOLDER/_prices</string>"
fi
shopt -s nullglob
for sv in "$WOW_DIR"/WTF/Account/*/SavedVariables; do
	WATCH="$WATCH
		<string>$sv</string>"
done
PLIST_BODY="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$SUPPORT/foreverscribe-sync.sh</string>
	</array>
	<key>WatchPaths</key>
	<array>
$WATCH
	</array>
	<key>StartInterval</key><integer>30</integer>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>RunAtLoad</key><true/>
	<key>ProcessType</key><string>Background</string>
	<key>StandardOutPath</key><string>$SUPPORT/sync.log</string>
	<key>StandardErrorPath</key><string>$SUPPORT/sync.log</string>
</dict>
</plist>"
if [ $DRY -eq 1 ]; then
	say "  [dry-run] write $PLIST and load it"
else
	printf '%s\n' "$PLIST_BODY" > "$PLIST"
	"$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
	"$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST"
	echo "plist=$PLIST" >> "$MANIFEST.new"
	mv -f "$MANIFEST.new" "$MANIFEST"
fi

if [ -n "$PUSH_URL" ] && [ $DRY -eq 0 ]; then
	say "3) Checking the receiver at $PUSH_URL"
	body="$(mktemp)"; printf 'check' > "$body"
	ts=$(date +%s); sha=$(shasum -a 256 "$body" | awk '{print $1}')
	sig=$(printf 'fs1\n%s\nPOST\n/v1/auth-check\n%s' "$ts" "$sha" | openssl dgst -sha256 -hmac "$KEY" -hex | awk '{print $NF}')
	code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 10 -H "X-FS-Key: $KEY_ID" -H "X-FS-Time: $ts" \
		-H "X-FS-Sig: $sig" --data-binary @"$body" "$PUSH_URL/v1/auth-check" 2>/dev/null || true)
	rm -f "$body"
	case "$code" in
		200) say "   receiver OK, pairing key accepted" ;;
		403) say "   receiver reachable but it refused the key: run 'foreverscribe pair' again and re-install with the new code" ;;
		*) say "   receiver not reachable right now ($code). Files will wait in the spool and go out once it is." ;;
	esac
fi

say ""
say "Done. Next: fully quit and restart WoW, check 'ForeverScribe' is enabled at character select,"
say "log in, type /scribe status, then /reload. Within a minute your agent sees it ('foreverscribe summary')."
say "Routes: when your agent writes one, press /fs go (bind it under Keybindings > AddOns > ForeverScribe)."
say "AH prices: if your agent has them on, item tooltips show them after the next login or /reload (/scribe tooltip)."
say "Undo everything with ./uninstall.sh"
