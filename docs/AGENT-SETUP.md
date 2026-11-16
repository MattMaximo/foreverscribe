# Connect your agent

ForeverScribe ships a **stdio MCP server** (`foreverscribe mcp`, standard library only) and a CLI. In the snippets
below replace `/path/to/foreverscribe` with your clone (Windows: `C:\\Users\\you\\foreverscribe`). Verify any of them
by asking the agent to call the `summary` tool.

## Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or
`%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "foreverscribe": {
      "command": "/path/to/foreverscribe/bin/foreverscribe",
      "args": ["mcp"]
    }
  }
}
```

Windows:

```json
{
  "mcpServers": {
    "foreverscribe": {
      "command": "py",
      "args": ["-3", "-m", "foreverscribe", "mcp"],
      "env": { "PYTHONPATH": "C:\\Users\\you\\foreverscribe" }
    }
  }
}
```

Restart Claude Desktop after editing.

## Claude Code

```sh
claude mcp add foreverscribe -- /path/to/foreverscribe/bin/foreverscribe mcp
```

or in a project's `.mcp.json`:

```json
{ "mcpServers": { "foreverscribe": { "command": "/path/to/foreverscribe/bin/foreverscribe", "args": ["mcp"] } } }
```

## Codex CLI

`~/.codex/config.toml`:

```toml
[mcp_servers.foreverscribe]
command = "/path/to/foreverscribe/bin/foreverscribe"
args = ["mcp"]
```

## Hermes Agent

`~/.hermes/config.yaml`:

```yaml
mcp_servers:
  foreverscribe:
    command: /path/to/foreverscribe/bin/foreverscribe
    args: [mcp]
```

Or skip MCP and install the skill in `skills/hermes/wow-forever-companion/` (it drives the CLI directly):
copy that folder into `~/.hermes/skills/`.

## Any other agent / no MCP

Every MCP tool is a CLI command: `foreverscribe summary`, `foreverscribe quest 307`, `foreverscribe --json mail`, …
Give your agent shell access to `bin/foreverscribe` and point it at [`skills/AGENT-INSTRUCTIONS.md`](../skills/AGENT-INSTRUCTIONS.md).

## ChatGPT and claude.ai (web)

The web apps only talk to **remote** MCP servers over HTTPS, which ForeverScribe does not host. If you want them:

1. Run a stdio-to-HTTP MCP bridge yourself on the agent computer (for example an MCP "proxy"/"gateway" tool that
   exposes a stdio server as Streamable HTTP), pointed at `bin/foreverscribe mcp`.
2. Publish it with your own HTTPS tunnel (Cloudflare Tunnel, Tailscale Funnel, ngrok) **with authentication in front**
   (Cloudflare Access, an OAuth proxy, or the bridge's own token). Your character data is personal; never expose an
   unauthenticated endpoint.
3. Add the HTTPS URL as a connector in ChatGPT (developer mode) or claude.ai (Settings → Connectors).

This is entirely optional and user-run. The CLI and local MCP clients need none of it.

## Tool list

| Tier | Tools |
|---|---|
| HOT | `summary` (call first) |
| WARM | `freshness`, `characters`, `quest`, `equipment`, `inventory`, `professions`, `reputation`, `talents`, `explored`, `achievements`, `collections`, `stats`, `currencies`, `lockouts`, `mail`, `auctions`, `vendor`, `events`, `history`, `compare`, `dungeons`, `gear`, `rate`, `craft`, `wowhead`, `import_page`, `ah_price` |
| COLD | `cold` (`addons`, `keybinds`, `actionbars`, `macros`) |
| Setup | `doctor` |

Every tool accepts an optional `character`.
