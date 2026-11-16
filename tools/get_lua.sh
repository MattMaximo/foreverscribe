#!/bin/bash
# Build Lua 5.1.5 (the WoW addon dialect) into tools/lua for the addon tests.
# Skip this if `lua5.1` or a Lua 5.1 `lua` is already on PATH.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL https://www.lua.org/ftp/lua-5.1.5.tar.gz -o "$WORK/lua.tgz"
echo "2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333  $WORK/lua.tgz" | shasum -a 256 -c -
tar xzf "$WORK/lua.tgz" -C "$WORK"
case "$(uname -s)" in Darwin) PLAT=macosx ;; Linux) PLAT=linux ;; *) PLAT=posix ;; esac
make -C "$WORK/lua-5.1.5" "$PLAT" >/dev/null
make -C "$WORK/lua-5.1.5" install INSTALL_TOP="$HERE/lua" >/dev/null
"$HERE/lua/bin/lua" -v
