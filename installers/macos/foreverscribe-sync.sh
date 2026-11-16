#!/bin/bash
# ForeverScribe game-side sync agent (macOS). Ships SavedVariables to wherever your agent runs.
# Read-only towards the game: it never writes inside the WoW folder.
# Triggered by launchd (WatchPaths on each SavedVariables folder + a 2-minute retry interval).
#
# Settings: $SUPPORT/game.conf (written by install.sh), overridable by environment variables:
#   WOW_DIR      the _forever_ folder
#   PUSH_URL     http transport: receiver URL ("" = off). Signed with KEY_ID + the key in $SUPPORT/pairing.key
#   FOLDER_DEST  folder transport: a synced folder (iCloud Drive, Dropbox, OneDrive, Google Drive, Syncthing...)
#   EXTRA_SV     space-separated globs of other addons' SavedVariables to ship too (default "ForeverForge*.lua")
#   LEGACY_UNSIGNED=1   v0.2 receivers only: push without a signature (IP allowlist on the receiver side)
# Failed pushes are kept in $SUPPORT/spool (latest copy per file) and retried on every run.
set -u

SUPPORT="${FOREVERSCRIBE_SUPPORT:-$HOME/Library/Application Support/ForeverScribe}"
CONF="${FOREVERSCRIBE_GAME_CONF:-$SUPPORT/game.conf}"
WOW_DIR="/Applications/World of Warcraft/_forever_"
PUSH_URL=""
KEY_ID=""
FOLDER_DEST=""
EXTRA_SV="ForeverForge*.lua"
LEGACY_UNSIGNED=0
[ -f "$CONF" ] && . "$CONF"
# environment wins over game.conf (tests and one-off runs)
WOW_DIR="${FOREVERSCRIBE_WOW_DIR:-$WOW_DIR}"
PUSH_URL="${FOREVERSCRIBE_PUSH_URL-$PUSH_URL}"
FOLDER_DEST="${FOREVERSCRIBE_DEST-$FOLDER_DEST}"
EXTRA_SV="${FOREVERSCRIBE_EXTRA_SV-$EXTRA_SV}"
KEY_FILE="${FOREVERSCRIBE_KEY_FILE:-$SUPPORT/pairing.key}"
STATE_DIR="${FOREVERSCRIBE_STATE:-$SUPPORT/pushed}"
SPOOL="${FOREVERSCRIBE_SPOOL:-$SUPPORT/spool}"
TRIES="${FOREVERSCRIBE_PUSH_TRIES:-3}"
LOG_TAG="foreverscribe-sync"
PUSH_URL="${PUSH_URL%/}"

log() { printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_TAG" "$*"; }

# The client writes SavedVariables on /reload, logout and exit. Wait until the file stops
# changing and ends with a closing brace so a half-written file is never shipped.
stable_and_complete() {
	local f="$1" s1 s2 tries=0 settle="${FOREVERSCRIBE_SYNC_SETTLE:-2}"
	while [ $tries -lt "${FOREVERSCRIBE_SYNC_TRIES:-15}" ]; do
		s1=$(stat -f '%z:%m' "$f" 2>/dev/null) || return 1
		sleep "$settle"
		s2=$(stat -f '%z:%m' "$f" 2>/dev/null) || return 1
		if [ "$s1" = "$s2" ]; then
			tail -c 64 "$f" | tr -d ' \t\r\n' | grep -q '}$' && return 0
		fi
		tries=$((tries + 1))
	done
	return 1
}

# HMAC-SHA256 request signature (same scheme as foreverscribe/auth.py).
sign() {  # sign <ts> <path> <file>
	local sha canon key
	key="$(cat "$KEY_FILE" 2>/dev/null)" || return 1
	[ -n "$key" ] || return 1
	sha=$(shasum -a 256 "$3" | awk '{print $1}')
	canon=$(printf 'fs1\n%s\nPOST\n%s\n%s' "$1" "$2" "$sha")
	printf '%s' "$canon" | openssl dgst -sha256 -hmac "$key" -hex 2>/dev/null | awk '{print $NF}'
}

push_once() {  # push_once <url-path> <file>
	local ts sig code
	local -a hdr=(-H "Content-Type: application/octet-stream")
	if [ "${LEGACY_UNSIGNED:-0}" != "1" ]; then
		ts=$(date +%s)
		sig=$(sign "$ts" "$1" "$2") || { log "no pairing key at $KEY_FILE (re-run install.sh --pair <code>)"; return 2; }
		hdr+=(-H "X-FS-Key: $KEY_ID" -H "X-FS-Time: $ts" -H "X-FS-Sig: $sig")
	fi
	code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 30 "${hdr[@]}" \
		--data-binary @"$2" "$PUSH_URL$1" 2>/dev/null)
	case "$code" in
		200|202) return 0 ;;
		403) log "receiver refused $1 (403): pairing key revoked or clock skew? re-pair with: foreverscribe pair"; return 2 ;;
		*) return 1 ;;
	esac
}

push_file() {  # push_file <acct> <name> <file>; retries with backoff
	[ -n "$PUSH_URL" ] || return 1
	local path="/v1/sv/$1" i=1 rc
	[ "$2" = "ForeverScribe.lua" ] || path="/v1/sv/$1/$2"
	while :; do
		push_once "$path" "$3"; rc=$?
		[ $rc -eq 0 ] && return 0
		[ $rc -eq 2 ] && return 1
		[ $i -ge "$TRIES" ] && return 1
		sleep $((i * 2)); i=$((i + 1))
	done
}

ship() {  # ship <acct> <name> <src>
	local acct="$1" name="$2" src="$3" pushed="$STATE_DIR/$1/$2" spooled="$SPOOL/$1/$2"
	local need_push=0 need_copy=0 dest_dir dest
	if [ -n "$PUSH_URL" ]; then
		{ [ -f "$pushed" ] && cmp -s "$src" "$pushed"; } || need_push=1
	fi
	if [ -n "$FOLDER_DEST" ]; then
		dest_dir="$FOLDER_DEST/$acct"; dest="$dest_dir/$name"
		{ [ -f "$dest" ] && cmp -s "$src" "$dest"; } || need_copy=1
	fi
	[ $need_push -eq 0 ] && [ $need_copy -eq 0 ] && return 0
	stable_and_complete "$src" || { log "skip $acct/$name: still changing or incomplete"; return 0; }
	if [ $need_push -eq 1 ]; then
		mkdir -p "$STATE_DIR/$acct" "$SPOOL/$acct"
		cp "$src" "$spooled.tmp.$$" && mv -f "$spooled.tmp.$$" "$spooled"   # the spool holds the newest copy until delivered
		if push_file "$acct" "$name" "$spooled"; then
			mv -f "$spooled" "$pushed"
			log "pushed $acct/$name"
		else
			log "push failed for $acct/$name (receiver unreachable?); kept in spool, retrying next run"
		fi
	fi
	if [ $need_copy -eq 1 ]; then
		mkdir -p "$dest_dir" || { log "cannot create $dest_dir"; return 0; }
		local tmp="$dest_dir/.$name.tmp.$$"
		if cp "$src" "$tmp" && mv -f "$tmp" "$dest"; then
			copied=$((copied + 1)); log "copied $acct/$name to folder ($(stat -f '%z' "$dest") bytes)"
		else
			rm -f "$tmp"; log "copy failed for $acct/$name"
		fi
	fi
}

shopt -s nullglob
copied=0
[ -z "$PUSH_URL" ] && [ -z "$FOLDER_DEST" ] && { [ "${1:-}" = "-v" ] && log "no transport configured (local mode): nothing to do"; exit 0; }

# 1) retry anything still in the spool whose source hasn't changed since (changed files are re-shipped below)
if [ -n "$PUSH_URL" ]; then
	for spooled in "$SPOOL"/*/*.lua; do
		acct="$(basename "$(dirname "$spooled")")"; name="$(basename "$spooled")"
		src="$WOW_DIR/WTF/Account/$acct/SavedVariables/$name"
		[ -f "$src" ] && ! cmp -s "$src" "$spooled" && continue
		if push_file "$acct" "$name" "$spooled"; then
			mkdir -p "$STATE_DIR/$acct"; mv -f "$spooled" "$STATE_DIR/$acct/$name"; log "delivered spooled $acct/$name"
		fi
	done
fi

# 2) ForeverScribe plus any extra SavedVariables listed in EXTRA_SV (split without globbing here)
set -f; PATS=($EXTRA_SV); set +f
for svdir in "$WOW_DIR"/WTF/Account/*/SavedVariables; do
	acct="$(basename "$(dirname "$svdir")")"
	[ -f "$svdir/ForeverScribe.lua" ] && ship "$acct" "ForeverScribe.lua" "$svdir/ForeverScribe.lua"
	for pat in ${PATS[@]+"${PATS[@]}"}; do
		case "$pat" in */*|*..*) continue ;; esac
		for f in "$svdir"/$pat; do
			case "$f" in *.lua) [ -f "$f" ] && ship "$acct" "$(basename "$f")" "$f" ;; esac
		done
	done
done
[ $copied -eq 0 ] && [ "${1:-}" = "-v" ] && log "nothing new to copy"
exit 0
