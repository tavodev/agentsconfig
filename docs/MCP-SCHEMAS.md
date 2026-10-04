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

Every add/copy/replacement is staged for diff review before changing a buffer.
Review records the original buffer and disk state; changes to either invalidate
approval. JSONC/TOML normalization warnings are displayed. TOML edits preserve
unrelated typed values; comments/formatting may normalize. Arguments remain an
ordered list, never a string split on spaces.
