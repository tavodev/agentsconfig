# MCP adapter contract

The app edits configuration only; it never starts an MCP process or authenticates
against an endpoint. The mappings below describe the supported adapter contract;
their official sources were checked on 2026-09-10.

| Agent | User destination | Container | Local transport | Remote transport |
| --- | --- | --- | --- | --- |
| Claude Code | `~/.claude.json` | `mcpServers` | `command` string, `args`, `env`, optional `type: stdio` | `type: http` or `sse`, `url`, `headers` |
| Codex | `~/.codex/config.toml` | `mcp_servers` | `command` string, `args`, `env`, `cwd` | Streamable HTTP `url`, `http_headers` |
| Gemini CLI | `~/.gemini/settings.json` | `mcpServers` | `command` string, `args`, `env`, `cwd` | `httpUrl` for Streamable HTTP; `url` for SSE; `headers` |
| OpenCode | `~/.config/opencode/opencode.json` (or existing `.jsonc`) | `mcp` | `type: local`, `command` array, `environment`, `cwd` | `type: remote`, `url`, `headers` |

Sources: [Claude scopes and transports](https://code.claude.com/docs/en/mcp), [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), [Gemini CLI MCP](https://geminicli.com/docs/tools/mcp-server/), [OpenCode MCP](https://opencode.ai/docs/mcp-servers/), [OpenCode configuration](https://opencode.ai/docs/config/).

Codex/OpenCode support an `enabled` boolean. A disabled server cannot be copied into an adapter without equivalent per-server enablement. Claude/Gemini exclusion or trust policies are not inferred from a server object. Cross-agent copies do not transfer authentication sessions, global policies or approvals; the review warns about this scope.

Timeouts are not interchangeable: Gemini documents request milliseconds, OpenCode tool discovery milliseconds, Codex separate startup/tool seconds. Cross-agent conversion rejects these and all other fields without an established mapping instead of dropping them or claiming raw-key compatibility. It also rejects environment interpolation whose syntax/semantics could change across clients. Same-dialect copies preserve extra fields.

Automatic MCP edits target **Gemini CLI**. Antigravity IDE files are inspected
separately; no shared schema or migration is assumed. Unsupported source dialects
require manual Source editing. Local project MCP sources appear in the comparator
but are not copy/add destinations.

Read-only inventory clients are never add/copy destinations; their servers
appear in the comparator only (decision recorded on 2026-10-16, issue #23):

| Client | Inspected MCP files | Why not a destination |
| --- | --- | --- |
| Cursor | `~/.cursor/mcp.json`, `.cursor/mcp.json` | Inventory only; remote transport and interpolation rules are not modelled. |
| Copilot CLI | `~/.copilot/mcp-config.json`, `.mcp.json`, `.github/mcp.json`, plugin `mcp.json` | Inventory only; IDE/cloud policies are not observed. |
| Windsurf / Devin Desktop | `~/.config/devin/mcp_config.json`, `~/.codeium/mcp_config.json`, legacy `~/.codeium/windsurf/mcp_config.json` | Official pages disagree on the loaded file; `${env:}`/`${file:}` interpolation and team allowlists have no mapping. |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | Remote connectors and extensions live in the app; the file needs an app restart and holds secrets in `env`. |

Sources: [Cursor MCP](https://cursor.com/docs/context/mcp), [Copilot CLI configuration directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference), [Devin Desktop MCP](https://docs.devin.ai/desktop/cascade/mcp), [Devin Desktop FAQ](https://docs.devin.ai/desktop/devin-desktop-faq), [Claude Desktop local servers](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

Every add/copy/replacement is staged for diff review before changing a buffer.
Review records the original buffer and disk state; changes to either invalidate
approval. JSONC/TOML normalization warnings are displayed. TOML edits preserve
unrelated typed values; comments/formatting may normalize. Arguments remain an
ordered list, never a string split on spaces.
