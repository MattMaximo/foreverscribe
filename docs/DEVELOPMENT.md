# Development

## Layout and rules

- `addon/ForeverScribe/` — Lua 5.1, read-only. Every game call goes through `U.Call("Namespace.Func", ...)` (pcall'd,
  missing APIs return nil) and every stored value through `U.Clean`/`U.Sanitize` (secret values dropped). Collectors
  in `Collect.lua` return plain data or nil on an empty read; `Core.lua` wires events and never lets an empty read
  replace good data (`state.leaving` blocks scans during logout teardown).
- Never add: network, chat output beyond `Print`, chat capture beyond the auction format-string match, protected
  calls, input automation, `ReloadUI`, AH queries, buy/sell/post/mail actions. `tests/lua/test_addon.lua` greps the
  addon source for the obvious ones.
- Exceptions to "never write towards the game" are deliberate and narrow: the companion/sync agent may rewrite only
  `Interface/AddOns/ForeverScribe_RouteNN/Route.lua` (data-only route slots, loaded only by the player's `/fs go`) and
  `Interface/AddOns/ForeverScribe_Prices/Prices.lua` (data-only AH prices, read at login/`/reload`; see `docs/PRICES.md`).
- `foreverscribe/` — Python 3.8+ standard library only (macOS ships 3.9). Config parsing falls back to a small TOML
  subset parser when `tomllib` (3.11+) is missing.

## Tests

```sh
tools/get_lua.sh                               # once: builds Lua 5.1.5 into tools/lua (or have lua5.1 on PATH)
python3 -m unittest discover -s tests          # Python + the Lua addon suite (tests/test_config_mcp_v3.py runs it)
tools/lua/bin/lua tests/lua/test_addon.lua tests/fixtures   # Lua only; also regenerates the synthetic fixtures
```

Fixtures in `tests/fixtures/` are produced by the simulated client (`tests/lua/wow_stub*.lua`) on the synthetic realm
`Forever-Test`; never commit a real SavedVariables file.

API checks against Forever's UI source (clone once: `git clone --depth 1 -b forever https://github.com/Gethe/wow-ui-source research/wow-ui-source-forever`):

```sh
python3 tools/check_api.py          # every Call()/event used: doc / ui-source / UNVERIFIED
python3 tools/api_lookup.py Name    # signature from the generated docs
```

## Before every push

```sh
python3 tools/pii_check.py --history    # generic patterns + your own denylist (kept outside the repo)
```

Put personal strings (character names, account folder, usernames, IPs, keys) one per line in
`~/.config/foreverscribe/pii-denylist.txt` (or `$FOREVERSCRIBE_PII_DENYLIST`). The test suite runs the same check.

## Release kits

```sh
tools/build_dist.sh                  # dist/ForeverScribe-<ver>-macos.zip, -windows.zip, -addon-<ver>.zip, SHA256SUMS
```

Bump the version in three places together: `addon/ForeverScribe/ForeverScribe.toc`, `addon/ForeverScribe/Core.lua`
(`FS.VERSION`), `foreverscribe/__init__.py` (the build refuses a mismatch); also the route slot TOCs
(`addon/ForeverScribe_RouteNN/*.toc`, `## Version`) and the installers' manifest `version=`. A TOC file-list change
or a new addon folder needs a full game restart, not just `/reload`.

Price file: `addon/ForeverScribe_Prices/Prices.lua` ships empty (`build_dist.sh` refuses otherwise). Its format lives in
`foreverscribe/prices.py` (`render_lua`, `LINE_RE`) and both sync agents (`PRICE_LINE` / `$PriceLine`): change all
three together.

Route slots: `addon/ForeverScribe_Route01-10` ship with an empty `Route.lua`; never commit a written route there.
The slot file format is defined once in `foreverscribe/routes.py` (`render_lua`) and checked line by line by both
sync agents (`ROUTE_LINE` / `$RouteLine`): change all three together. `tests/lua/route_e2e.lua` boots the simulated
client against a slot folder for the Python tests.
