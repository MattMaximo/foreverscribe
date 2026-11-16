#!/bin/bash
# Reverses install.sh: stops the sync agent, removes the ForeverScribe addon folders it installed,
# restores any folders it had backed up, and removes ~/Library/Application Support/ForeverScribe
# (the sync log is kept in ~/Library/Logs). Your SavedVariables (WTF/.../ForeverScribe.lua) and any
# copies already on the agent side are left alone.
#   ./uninstall.sh [--dry-run]
set -uo pipefail

SUPPORT="${FOREVERSCRIBE_SUPPORT:-$HOME/Library/Application Support/ForeverScribe}"
AGENTS="${FOREVERSCRIBE_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
MANIFEST="$SUPPORT/install-manifest.txt"
WOW_DIR="${FOREVERSCRIBE_WOW_DIR:-/Applications/World of Warcraft/_forever_}"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
run() { if [ $DRY -eq 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

[ "$(id -u)" -eq 0 ] && { echo "Run this as your normal user, not with sudo."; exit 1; }
[ -f "$MANIFEST" ] && WOW_DIR="$(sed -n 's/^wow_dir=//p' "$MANIFEST" | head -1)"
ADDONS="$WOW_DIR/Interface/AddOns"

for plist in "$AGENTS"/*.foreverscribe.sync.plist; do
	label="$(basename "$plist" .plist)"
	if [ -f "$AGENTS/$label.plist" ]; then
		run "$LAUNCHCTL" bootout "gui/$(id -u)/$label"
		run rm -f "$AGENTS/$label.plist"
		echo "sync agent $label removed"
	fi
done

for d in ForeverScribe ForeverScribe_Live ForeverScribe_Route01 ForeverScribe_Route02 ForeverScribe_Route03 ForeverScribe_Route04 ForeverScribe_Route05 ForeverScribe_Route06 ForeverScribe_Route07 ForeverScribe_Route08 ForeverScribe_Route09 ForeverScribe_Route10; do
	if [ -f "$SUPPORT/installed-$d" ] && [ -d "$ADDONS/$d" ]; then
		run rm -rf "$ADDONS/$d"
		echo "removed AddOns/$d"
	fi
	backup="$( [ -f "$MANIFEST" ] && sed -n "s/^backup_$d=//p" "$MANIFEST" | tail -1 )"
	if [ -n "$backup" ] && [ -d "$backup" ] && { [ $DRY -eq 1 ] || [ ! -e "$ADDONS/$d" ]; }; then
		run mv "$backup" "$ADDONS/$d"
		echo "restored previous AddOns/$d"
	fi
done

if [ -d "$SUPPORT" ]; then
	if [ -f "$SUPPORT/sync.log" ]; then
		run mkdir -p "$HOME/Library/Logs"
		run mv "$SUPPORT/sync.log" "$HOME/Library/Logs/foreverscribe-uninstall-$(date +%Y%m%d-%H%M%S).log"
	fi
	run rm -rf "$SUPPORT"
fi
echo "ForeverScribe uninstalled. Restart WoW to unload the addon."
