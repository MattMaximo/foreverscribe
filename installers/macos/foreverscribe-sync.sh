#!/bin/bash
# ForeverScribe game-side sync agent (macOS). Ships SavedVariables to wherever your agent runs, and brings back the
# route and AH prices your agent wrote (`foreverscribe route write`, `foreverscribe prices write`). The only things it
# writes inside the WoW folder are Interface/AddOns/ForeverScribe_RouteNN/Route.lua (data-only route slots, read by
# /fs go) and Interface/AddOns/ForeverScribe_Prices/Prices.lua (data-only price file); nothing else.
# Triggered by launchd (WatchPaths on each SavedVariables folder and the synced route folder + a 30-second interval).
#
# Settings: $SUPPORT/game.conf (written by install.sh), overridable by environment variables:
#   WOW_DIR      the _forever_ folder
#   PUSH_URL     http transport: receiver URL ("" = off). Signed with KEY_ID + the key in $SUPPORT/pairing.key
#   RELAY_URL + RELAY_CH   relay transport (fs2 code): a hosted relay both computers connect out to. Upload token and
#                encryption key in $SUPPORT/relay.key. Files are encrypted end to end (AES-256-CBC + HMAC-SHA256,
#                foreverscribe/relaycrypto.py) before they leave this computer.
#   FOLDER_DEST  folder transport: a synced folder (iCloud Drive, Dropbox, OneDrive, Google Drive, Syncthing...)
#   EXTRA_SV     space-separated globs of other addons' SavedVariables to ship too (default "ForeverForge*.lua
#                Polestar.lua"), matched in each account's SavedVariables folder and in every character's
#                WTF/Account/<acct>/<realm>/<char>/SavedVariables folder (Polestar's per-character PolestarCharDB)
#   LEGACY_UNSIGNED=1   v0.2 receivers only: push without a signature (IP allowlist on the receiver side)
# Failed pushes are kept in $SUPPORT/spool (latest copy per file) and retried on every run.
set -u

SUPPORT="${FOREVERSCRIBE_SUPPORT:-$HOME/Library/Application Support/ForeverScribe}"
CONF="${FOREVERSCRIBE_GAME_CONF:-$SUPPORT/game.conf}"
WOW_DIR="/Applications/World of Warcraft/_forever_"
PUSH_URL=""
KEY_ID=""
FOLDER_DEST=""
RELAY_URL=""
RELAY_CH=""
EXTRA_SV="ForeverForge*.lua Polestar.lua"
LEGACY_UNSIGNED=0
[ -f "$CONF" ] && . "$CONF"
# environment wins over game.conf (tests and one-off runs)
WOW_DIR="${FOREVERSCRIBE_WOW_DIR:-$WOW_DIR}"
PUSH_URL="${FOREVERSCRIBE_PUSH_URL-$PUSH_URL}"
FOLDER_DEST="${FOREVERSCRIBE_DEST-$FOLDER_DEST}"
RELAY_URL="${FOREVERSCRIBE_RELAY_URL-$RELAY_URL}"
RELAY_CH="${FOREVERSCRIBE_RELAY_CH-$RELAY_CH}"
RELAY_KEY_FILE="${FOREVERSCRIBE_RELAY_KEY_FILE:-$SUPPORT/relay.key}"
EXTRA_SV="${FOREVERSCRIBE_EXTRA_SV-$EXTRA_SV}"
KEY_FILE="${FOREVERSCRIBE_KEY_FILE:-$SUPPORT/pairing.key}"
STATE_DIR="${FOREVERSCRIBE_STATE:-$SUPPORT/pushed}"
SPOOL="${FOREVERSCRIBE_SPOOL:-$SUPPORT/spool}"
TRIES="${FOREVERSCRIBE_PUSH_TRIES:-3}"
LOG_TAG="foreverscribe-sync"
PUSH_URL="${PUSH_URL%/}"
RELAY_URL="${RELAY_URL%/}"

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
sign() {  # sign <ts> <path> <file> [method]
	local sha canon key
	key="$(cat "$KEY_FILE" 2>/dev/null)" || return 1
	[ -n "$key" ] || return 1
	sha=$(shasum -a 256 "$3" | awk '{print $1}')
	canon=$(printf 'fs1\n%s\n%s\n%s\n%s' "$1" "${4:-POST}" "$2" "$sha")
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

# Percent-encode one path segment (realm folders have spaces); bytes outside A-Za-z0-9._~- become %XX.
urlenc() {
	local LC_ALL=C s="$1" out="" c i
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in [A-Za-z0-9._~-]) out+="$c" ;; *) out+=$(printf '%%%02X' $(( $(printf '%d' "'$c") & 255 ))) ;; esac
	done
	printf '%s' "$out"
}

# ---- relay transport (fs2): end-to-end encrypted blobs in a hosted mailbox. Same envelope as relaycrypto.py.
pushing() { [ -n "$PUSH_URL" ] || [ -n "$RELAY_URL" ]; }
RELAY_TOKEN=""; RELAY_KEY=""; EK=""; MACK=""; RELAY_HDR=""
relay_keys() {  # load the token and key once, derive the AES and MAC keys
	[ -n "$EK" ] && return 0
	RELAY_TOKEN="$(sed -n 1p "$RELAY_KEY_FILE" 2>/dev/null)"; RELAY_KEY="$(sed -n 2p "$RELAY_KEY_FILE" 2>/dev/null)"
	[ -n "$RELAY_TOKEN" ] && [ -n "$RELAY_KEY" ] && [ -n "$RELAY_CH" ] || { log "no relay key at $RELAY_KEY_FILE (re-run install.sh --pair <fs2 code>)"; return 1; }
	# the bearer token goes to curl from a private file, not on its command line (where `ps` would show it)
	RELAY_HDR="$(mktemp "${TMPDIR:-/tmp}/fs-hdr.XXXXXX")" && chmod 600 "$RELAY_HDR" &&
		printf 'Authorization: Bearer %s\n' "$RELAY_TOKEN" > "$RELAY_HDR" || return 1
	trap 'rm -f "$RELAY_HDR"' EXIT
	EK=$(printf 'fs2 enc' | openssl dgst -sha256 -hmac "$RELAY_KEY" -hex 2>/dev/null | awk '{print $NF}')
	MACK=$(printf 'fs2 mac' | openssl dgst -sha256 -hmac "$RELAY_KEY" -hex 2>/dev/null | awk '{print $NF}')
	[ ${#EK} -eq 64 ] && [ ${#MACK} -eq 64 ]
}
relay_bid() { printf 'fs2 name|%s' "$1" | openssl dgst -sha256 -hmac "$MACK" -hex 2>/dev/null | awk '{print substr($NF,1,32)}'; }
relay_tag() {  # relay_tag <bid> <file with header+ct>
	{ printf 'fs2|%s|%s\n' "$RELAY_CH" "$1"; cat "$2"; } | openssl dgst -sha256 -hmac "$MACK" -hex 2>/dev/null | awk '{print $NF}'
}
relay_seal() {  # relay_seal <logical name> <src> <out>: gzip, encrypt, MAC
	local w iv bid hdr
	w="$(mktemp -d "${TMPDIR:-/tmp}/fs-seal.XXXXXX")" || return 1
	iv=$(openssl rand -hex 16) && bid=$(relay_bid "$1") || { rm -rf "$w"; return 1; }
	hdr="FS2E1$(printf '%012d' "$(date +%s)")$iv"
	{ printf '%s\n' "$1"; gzip -n -c "$2"; } > "$w/plain" &&
		{ printf '%s' "$hdr"; openssl enc -aes-256-cbc -K "$EK" -iv "$iv" -in "$w/plain"; } > "$w/body" &&
		{ cat "$w/body"; printf '%s' "$(relay_tag "$bid" "$w/body")"; } > "$3"
	local rc=$?; rm -rf "$w"; return $rc
}
relay_open() {  # relay_open <blob> <bid> <expected logical name> <out>: verify the MAC first, then decrypt and gunzip
	local size w iv name
	size=$(wc -c < "$1" | tr -d ' ')
	[ "$size" -gt 129 ] && [ "$(head -c 5 "$1")" = "FS2E1" ] || return 1
	w="$(mktemp -d "${TMPDIR:-/tmp}/fs-open.XXXXXX")" || return 1
	head -c $((size - 64)) "$1" > "$w/body"
	if [ "$(relay_tag "$2" "$w/body")" != "$(tail -c 64 "$1" | tr 'A-F' 'a-f')" ]; then rm -rf "$w"; log "relay blob failed authentication: ignored"; return 1; fi
	iv=$(head -c 49 "$1" | tail -c 32)
	tail -c +50 "$w/body" > "$w/ct" && openssl enc -d -aes-256-cbc -K "$EK" -iv "$iv" -in "$w/ct" -out "$w/plain" 2>/dev/null || { rm -rf "$w"; return 1; }
	name="$(head -n 1 "$w/plain")"
	[ "$name" = "$3" ] || { rm -rf "$w"; log "relay blob is not $3: ignored"; return 1; }
	tail -c +$(( $(printf '%s' "$name" | wc -c) + 2 )) "$w/plain" | gunzip -c > "$4" 2>/dev/null   # bytes, not characters
	local rc=$?; rm -rf "$w"; return $rc
}

relay_put() {  # relay_put <acct>[/<realm>/<char>] <name> <file>: 0 ok, 1 retry later, 2 don't retry now
	relay_keys || return 2
	local blob bid code
	bid=$(relay_bid "sv/$1/$2"); blob="$(mktemp "${TMPDIR:-/tmp}/fs-blob.XXXXXX")"
	relay_seal "sv/$1/$2" "$3" "$blob" || { rm -f "$blob"; log "could not encrypt $1/$2"; return 2; }
	code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 120 -X PUT \
		-H @"$RELAY_HDR" -H "Content-Type: application/octet-stream" \
		--data-binary @"$blob" "$RELAY_URL/v1/ch/$RELAY_CH/files/up/$bid" 2>/dev/null)
	rm -f "$blob"
	case "$code" in
		200) return 0 ;;
		403|404) log "relay refused $1/$2 ($code): channel unpaired or relay redeployed. On your agent computer run: foreverscribe relay pair --force, then re-install here with the new code"; return 2 ;;
		413) log "relay refused $1/$2: too big even compressed"; return 2 ;;
		*) return 1 ;;
	esac
}

push_file() {  # push_file <acct>[/<realm>/<char>] <name> <file>; retries with backoff
	if [ -n "$RELAY_URL" ]; then
		local i=1 rc
		while :; do
			relay_put "$1" "$2" "$3"; rc=$?
			[ $rc -eq 0 ] && return 0
			[ $rc -eq 2 ] && return 1
			[ $i -ge "$TRIES" ] && return 1
			sleep $((i * 2)); i=$((i + 1))
		done
	fi
	[ -n "$PUSH_URL" ] || return 1
	local path="/v1/sv/$1" i=1 rc a r c
	case "$1" in
		*/*/*) a="${1%%/*}"; r="${1#*/}"; c="${r#*/}"; r="${r%%/*}"
			path="/v1/sv/$(urlenc "$a")/$(urlenc "$r")/$(urlenc "$c")/$2" ;;
		*) [ "$2" = "ForeverScribe.lua" ] || path="/v1/sv/$1/$2" ;;
	esac
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
	if pushing; then
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

# ---- route slots (agent -> game) ----
ADDONS="$WOW_DIR/Interface/AddOns"
ROUTE_STATE="${FOREVERSCRIBE_ROUTE_STATE:-$SUPPORT/route-rev}"

# A slot file is data only. Every line must be one of the shapes routes.py writes (strings without quotes or
# backslashes cannot break out), so a damaged or hostile file can never put code into the game.
ROUTE_LINE='^(-- [^[].*|ForeverScribe_RouteData = (\{|nil)|	v = [0-9]+,|	rev = "[A-Za-z0-9_.-]+",|	name = "[^"\\]*",|	created = [0-9]+,|	stops = \{|		\{ map = [0-9]+, x = [0-9.]+, y = [0-9.]+, r = [0-9]+, title = "[^"\\]*" \},|	\},|\})?$'
valid_route() {
	head -c 200 "$1" | grep -q '^-- ForeverScribe route slot' || return 1
	grep -q '^ForeverScribe_RouteData = {$' "$1" || return 1
	! LC_ALL=C grep -Evq "$ROUTE_LINE" "$1"
}

install_route() {  # install_route <file> <from>
	local src="$1" n=0 slot dest tmp rev
	valid_route "$src" || { log "route from $2 ignored: not a ForeverScribe route slot file"; return 1; }
	rev=$(sed -n 's/.*rev = "\([A-Za-z0-9_.-]*\)".*/\1/p' "$src" | head -1)
	for slot in "$ADDONS"/ForeverScribe_Route[0-9][0-9]; do
		[ -f "$slot/$(basename "$slot").toc" ] || continue
		dest="$slot/Route.lua"
		cmp -s "$src" "$dest" && { n=$((n + 1)); continue; }
		tmp="$slot/.Route.lua.tmp.$$"
		cp "$src" "$tmp" && mv -f "$tmp" "$dest" && n=$((n + 1))
	done
	if [ $n -eq 0 ]; then log "route $rev from $2: no route slots in $ADDONS (install ForeverScribe 0.5 and restart WoW)"; return 1; fi
	if [ "$(cat "$ROUTE_STATE" 2>/dev/null)" != "$rev" ]; then
		printf '%s' "$rev" > "$ROUTE_STATE"
		log "route $rev from $2 written to $n slots: press /fs go in game"
	fi
	return 0
}

fetch_route() {  # http: ask the receiver for the route (signed); 200 = new file, 304 = unchanged, 204 = none
	local ts sig code body out have
	body="$(mktemp "${TMPDIR:-/tmp}/fs-route-req.XXXXXX")"; out="$(mktemp "${TMPDIR:-/tmp}/fs-route.XXXXXX")"
	printf 'route' > "$body"
	ts=$(date +%s)
	sig=$(sign "$ts" "/v1/route" "$body") || { rm -f "$body" "$out"; return 0; }
	have="$(cat "$ROUTE_STATE" 2>/dev/null)"
	code=$(curl -sS -o "$out" -w '%{http_code}' --connect-timeout 4 --max-time 15 -H "X-FS-Key: $KEY_ID" -H "X-FS-Time: $ts" \
		-H "X-FS-Sig: $sig" -H "X-FS-Have: $have" --data-binary @"$body" "$PUSH_URL/v1/route" 2>/dev/null)
	case "$code" in
		200) install_route "$out" "receiver" ;;
		403) log "receiver refused the route fetch (403): re-pair with: foreverscribe pair" ;;
	esac
	rm -f "$body" "$out"
}

# relay: one small poll per run; fetch the route / price blob only when its seq moved and its addon is installed
RELAY_GOT="${FOREVERSCRIBE_RELAY_GOT:-$SUPPORT/relay-got}"
has_slots() { local s; for s in "$ADDONS"/ForeverScribe_Route[0-9][0-9]; do [ -f "$s/$(basename "$s").toc" ] && return 0; done; return 1; }
relay_pickup() {
	relay_keys || return 0
	local ev code rb pb name seq have out blob ts last
	ev="$(mktemp "${TMPDIR:-/tmp}/fs-ev.XXXXXX")"
	code=$(curl -sS -o "$ev" -w '%{http_code}' --connect-timeout 6 --max-time 20 -H @"$RELAY_HDR" \
		"$RELAY_URL/v1/ch/$RELAY_CH/events?since=0" 2>/dev/null)
	case "$code" in
		200) ;;
		403|404) log "relay refused the poll ($code): channel unpaired or relay redeployed. On your agent computer run: foreverscribe relay pair --force"; rm -f "$ev"; return 0 ;;
		*) rm -f "$ev"; return 0 ;;
	esac
	rb=$(relay_bid route); pb=$(relay_bid prices)
	mkdir -p "$RELAY_GOT"
	{ tr '{' '\n' < "$ev"; echo; } | sed -n 's/.*"name":"down\/\([0-9a-f]\{32\}\)","seq":\([0-9]*\).*/\1 \2/p' | while read -r b seq; do
		case "$b" in "$rb") name=route ;; "$pb") name=prices ;; *) continue ;; esac
		have="$(cat "$RELAY_GOT/$name" 2>/dev/null)"; case "$have" in ''|*[!0-9]*) have=0 ;; esac
		[ "$seq" -gt "$have" ] || continue
		if [ $name = route ]; then has_slots || continue
		else [ -f "$PRICE_DIR/ForeverScribe_Prices.toc" ] || continue; fi
		blob="$(mktemp "${TMPDIR:-/tmp}/fs-dl.XXXXXX")"; out="$(mktemp "${TMPDIR:-/tmp}/fs-dl.XXXXXX")"
		code=$(curl -sS -o "$blob" -w '%{http_code}' --connect-timeout 6 --max-time 60 -H @"$RELAY_HDR" \
			"$RELAY_URL/v1/ch/$RELAY_CH/files/down/$b" 2>/dev/null)
		if [ "$code" = 200 ]; then
			if relay_open "$blob" "$b" "$name" "$out"; then
				# the signed time inside the envelope must not go backwards: a relay can't roll us back to an older file
				ts=$(head -c 17 "$blob" | tail -c 12); ts=$((10#$ts))
				last="$(cat "$RELAY_GOT/$name.t" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
				if [ "$ts" -lt "$last" ]; then
					log "relay offered an older $name than the one installed: ignored"
				else
					if [ $name = route ]; then install_route "$out" "relay"; else install_prices "$out" "relay"; fi
					printf '%s' "$ts" > "$RELAY_GOT/$name.t"
				fi
			fi
			printf '%s' "$seq" > "$RELAY_GOT/$name"   # a bad file is not fetched again until a new one is uploaded
		fi
		rm -f "$blob" "$out"
	done
	rm -f "$ev"
}

route_pickup() {
	[ -d "$ADDONS" ] || return 0
	if [ -n "$FOLDER_DEST" ] && [ -f "$FOLDER_DEST/_route/Route.lua" ]; then
		install_route "$FOLDER_DEST/_route/Route.lua" "synced folder" || true
	fi
	if [ -n "$PUSH_URL" ] && [ "${LEGACY_UNSIGNED:-0}" != "1" ] && [ -f "$KEY_FILE" ]; then
		fetch_route
	fi
}

# ---- prices (agent -> game) ----
# `foreverscribe prices write` makes Interface/AddOns/ForeverScribe_Prices/Prices.lua: data only, read by the game at
# login and /reload for the AH price tooltip. Same rules as a route slot: every line must match PRICE_LINE.
PRICE_DIR="$ADDONS/ForeverScribe_Prices"
PRICE_STAMP="${FOREVERSCRIBE_PRICE_STAMP:-$SUPPORT/prices-checked}"
PRICE_EVERY="${FOREVERSCRIBE_PRICE_EVERY:-300}"   # ask the receiver at most every 5 minutes
PRICE_MAX=1048576
PRICE_LINE='^(-- [^[].*|ForeverScribe_PriceData = (\{|nil)|@(v|captured|written|items) = [0-9]+,|@(rev|market|label|other|source) = "[A-Za-z0-9 _.-]*",|@[dp] = \{|@@\[[0-9]+\] = "[0-9,:;]*",|@\},|\})?$'
PRICE_LINE="${PRICE_LINE//@/	}"
valid_prices() {
	[ "$(wc -c < "$1" | tr -d ' ')" -le $PRICE_MAX ] || return 1
	head -c 200 "$1" | grep -q '^-- ForeverScribe prices' || return 1
	grep -q '^ForeverScribe_PriceData = {$' "$1" || return 1
	tail -c 4 "$1" | grep -q '}' || return 1
	! LC_ALL=C grep -Evq "$PRICE_LINE" "$1"
}
price_rev() { sed -n 's/^	rev = "\([A-Za-z0-9_.-]*\)",$/\1/p' "$1" 2>/dev/null | head -1; }

install_prices() {  # install_prices <file> <from>
	local src="$1" dest="$PRICE_DIR/Prices.lua" tmp
	[ -f "$PRICE_DIR/ForeverScribe_Prices.toc" ] || return 1   # 0.6 not installed (yet)
	cmp -s "$src" "$dest" && return 0
	valid_prices "$src" || { log "prices from $2 ignored: not a ForeverScribe price file"; return 1; }
	tmp="$PRICE_DIR/.Prices.lua.tmp.$$"
	cp "$src" "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; log "could not write $dest"; return 1; }
	log "prices $(price_rev "$dest") from $2 written ($(wc -c < "$dest" | tr -d ' ') bytes): they load at your next login or /reload"
}

fetch_prices() {  # http: signed ask; 200 = new file, 304 = unchanged, 204 = none written yet
	local ts sig code body out
	body="$(mktemp "${TMPDIR:-/tmp}/fs-prices-req.XXXXXX")"; out="$(mktemp "${TMPDIR:-/tmp}/fs-prices.XXXXXX")"
	printf 'prices' > "$body"
	ts=$(date +%s)
	sig=$(sign "$ts" "/v1/prices" "$body") || { rm -f "$body" "$out"; return 0; }
	code=$(curl -sS -o "$out" -w '%{http_code}' --connect-timeout 4 --max-time 60 -H "X-FS-Key: $KEY_ID" -H "X-FS-Time: $ts" \
		-H "X-FS-Sig: $sig" -H "X-FS-Have: $(price_rev "$PRICE_DIR/Prices.lua")" --data-binary @"$body" "$PUSH_URL/v1/prices" 2>/dev/null)
	case "$code" in
		200) install_prices "$out" "receiver" ;;
		403) log "receiver refused the price fetch (403): re-pair with: foreverscribe pair" ;;
	esac
	rm -f "$body" "$out"
}

prices_pickup() {
	[ -f "$PRICE_DIR/ForeverScribe_Prices.toc" ] || return 0
	if [ -n "$FOLDER_DEST" ] && [ -f "$FOLDER_DEST/_prices/Prices.lua" ]; then
		install_prices "$FOLDER_DEST/_prices/Prices.lua" "synced folder" || true
	fi
	if [ -n "$PUSH_URL" ] && [ "${LEGACY_UNSIGNED:-0}" != "1" ] && [ -f "$KEY_FILE" ]; then
		local last now; now=$(date +%s); last=$(cat "$PRICE_STAMP" 2>/dev/null || echo 0)
		case "$last" in ''|*[!0-9]*) last=0 ;; esac
		[ -f "$PRICE_DIR/Prices.lua" ] && [ -n "$(price_rev "$PRICE_DIR/Prices.lua")" ] && [ $((now - last)) -lt "$PRICE_EVERY" ] && return 0
		printf '%s' "$now" > "$PRICE_STAMP"
		fetch_prices
	fi
}

# troubleshooting / tests: encrypt or decrypt one file with this install's relay key, then exit
case "${1:-}" in
	--relay-seal) relay_keys && relay_seal "$2" "$3" "$4" && relay_bid "$2"; exit $? ;;
	--relay-open) relay_keys && relay_open "$2" "$(relay_bid "$3")" "$3" "$4"; exit $? ;;
esac

shopt -s nullglob
copied=0
[ -z "$PUSH_URL" ] && [ -z "$FOLDER_DEST" ] && [ -z "$RELAY_URL" ] && { [ "${1:-}" = "-v" ] && log "no transport configured (local mode): nothing to do"; exit 0; }
route_pickup
prices_pickup
[ -n "$RELAY_URL" ] && [ -d "$ADDONS" ] && relay_pickup

# 1) retry anything still in the spool whose source hasn't changed since (changed files are re-shipped below)
if pushing; then
	for spooled in "$SPOOL"/*/*.lua "$SPOOL"/*/*/*/*.lua; do
		name="$(basename "$spooled")"; key="${spooled#"$SPOOL"/}"; key="${key%/*}"   # <acct> or <acct>/<realm>/<char>
		case "$key" in
			*/*/*) src="$WOW_DIR/WTF/Account/$key/SavedVariables/$name" ;;
			*) src="$WOW_DIR/WTF/Account/$key/SavedVariables/$name" ;;
		esac
		[ -f "$src" ] && ! cmp -s "$src" "$spooled" && continue
		if push_file "$key" "$name" "$spooled"; then
			mkdir -p "$STATE_DIR/$key"; mv -f "$spooled" "$STATE_DIR/$key/$name"; log "delivered spooled $key/$name"
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
# 3) the same globs in every character's own SavedVariables (WTF/Account/<acct>/<realm>/<char>/SavedVariables),
#    e.g. Polestar's PolestarCharDB. ForeverScribe itself has no per-character file.
for svdir in "$WOW_DIR"/WTF/Account/*/*/*/SavedVariables; do
	chr="$(basename "$(dirname "$svdir")")"; realm="$(basename "$(dirname "$(dirname "$svdir")")")"
	acct="$(basename "$(dirname "$(dirname "$(dirname "$svdir")")")")"
	case "$realm$chr" in */*|*..*) continue ;; esac
	[ "$realm" = "SavedVariables" ] && continue
	for pat in ${PATS[@]+"${PATS[@]}"}; do
		case "$pat" in */*|*..*) continue ;; esac
		for f in "$svdir"/$pat; do
			case "$f" in *.lua) [ -f "$f" ] && ship "$acct/$realm/$chr" "$(basename "$f")" "$f" ;; esac
		done
	done
done
[ $copied -eq 0 ] && [ "${1:-}" = "-v" ] && log "nothing new to copy"
exit 0
