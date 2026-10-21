# Configuration precedence by agent

What the **Configuration** analysis (`ConfigurationResolver` + `SettingMerger`)
models for each agent, and what it cannot see. Official sources were checked on
2026-10-16 (Claude Code's [Memory](https://code.claude.com/docs/en/memory) page
again on 2026-10-21); the resolver's documented contract is dated
`ConfigurationResolver.referenceDate` (2026-09-13).

The analysis reads files on disk. It never runs a client, so it cannot observe
CLI flags, environment variables exported in another terminal, server-delivered
or MDM policies, or which files a running session actually loaded. Every value
is labelled as an estimate, and anything outside the model stays explicit
(`Conditional`, `Unresolved`, `Excluded`, `Restricted`).

## Settings layers

Layers are listed from lowest to highest precedence, the order the resolver
applies them (a later layer overrides an earlier one for the same key path).

| Agent | Layers modelled (low → high) | Combination rules modelled | Not observed | Official reference |
| --- | --- | --- | --- | --- |
| Claude Code | `~/.claude/settings.json` (user) → `.claude/settings.json` (project) → `.claude/settings.local.json` (local) → `/Library/Application Support/ClaudeCode/managed-settings.json` (managed) | Lists merge across files (union), except `fallbackModel` and `modelPicker` (whole value from the highest file; `modelPicker` ignored at project/local) and managed `availableModels` (applied as-is). Strict booleans keep the restrictive value. `allowManagedPermissionRulesOnly` drops other scopes' permission rules. Trust-gated keys (`permissions.allow`, `env`, `permissions.additionalDirectories`, `extraKnownMarketplaces`) are `Conditional`/`Excluded` without trust. `pluginConfigs` entries of the built-in AGENTS.md plugin (`cc-plugin-agents-md@builtin`, `agents-md@builtin`) are `Excluded` at project/local scope. | `--settings`, server-managed (claude.ai console) and MDM policies; environment variables (decided per key pair, not a level); `managedSourcesBehavior` composition | [Settings files and precedence](https://code.claude.com/docs/en/settings), [Managed settings](https://code.claude.com/docs/en/managed-settings) |
| Codex | `/etc/codex/config.toml` (system) → `~/.codex/config.toml` (user) → profile → `.codex/config.toml` from the project root down to the working folder (closest wins) | Project layers apply only to trusted projects (trust read from `[projects."<path>"].trust_level` or the analysis assumption). Keys not accepted in project config (`model_provider(s)`, `profile(s)`, `notify`, `otel`, base URLs…) are `Excluded`. `/etc/codex/requirements.toml` is a constraint, not a layer: approval, sandbox and permission-profile allowlists mark values `Restricted`. | CLI flags and `--config`; cloud-managed defaults for a signed-in workspace; requirements other than the three allowlists | [Config basics](https://learn.chatgpt.com/docs/config-file/config-basic), [Config reference](https://developers.openai.com/codex/config-reference), [Advanced config](https://developers.openai.com/codex/config-advanced) |
| Gemini CLI | `/Library/Application Support/GeminiCli/system-defaults.json` → `~/.gemini/settings.json` (user) → `.gemini/settings.json` (project) → `/Library/Application Support/GeminiCli/settings.json` (system overrides) | Scalars and objects by key path. Arrays are `Unresolved`: merging is documented per setting, not in general. | Environment variables and command-line arguments (both above the system file); folder trust (`trustedFolders.json`) does not gate the project layer in the model | [Configuration reference](https://geminicli.com/docs/reference/configuration) |
| OpenCode | `~/.config/opencode/opencode.json[c]` (global) → nearest `opencode.json[c]` from the working folder up to the project root → `/Library/Application Support/opencode/opencode.json[c]` (managed) | Configs combine; later sources win for conflicting keys. `plugin` and `instructions` arrays are unioned. JSON and JSONC side by side in one layer are `Unresolved`. | Remote `.well-known/opencode` defaults; `OPENCODE_CONFIG`; `.opencode` directory contents as settings; `OPENCODE_CONFIG_CONTENT`; MDM preferences (`ai.opencode.managed`) | [Config](https://opencode.ai/docs/config/) |
| Antigravity | `~/.gemini/config/config.json` (user), always `Conditional` | None: the version and migration state decide what the client reads. | IDE and CLI settings are not merged speculatively | [Antigravity docs](https://antigravity.google/docs) |
| Cursor, Copilot CLI, Windsurf / Devin Desktop, Claude Desktop | — | Inventory only: files are listed and documented, no settings resolution is claimed. | Everything at runtime | See `docs/MCP-SCHEMAS.md` and the per-file docs |

Gemini CLI's own page notes that it was replaced by Antigravity CLI for unpaid
and Google One tiers on 2026-06-18. The Gemini CLI model above applies to
installations that still use `~/.gemini/settings.json`.

## Instruction files

`KnowledgeInspector` lists instruction candidates in load order; a candidate
does not prove that a session loaded it.

| Agent | Order modelled | Limits and conditions | Official reference |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/CLAUDE.md`, then from the project root down to the working folder: `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, and — when **Project instructions** lets it — that folder's `AGENTS.md` and `.claude/AGENTS.md`; rules in `.claude/rules/` are `Conditional` (`paths` frontmatter) | `@imports` followed inside the project up to four hops (a fifth is `Not loaded`); `claudeMdExcludes` excludes matches, `AGENTS.md` included. **Project instructions** (`pluginConfigs.<plugin>.options.instructionFiles`, read from user and managed settings only): `claude-md-or-agents-md` (default) makes `AGENTS.md` a `Candidate` only when no `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` exists from the project root to the working folder, otherwise `Replaced`; `claude-md-and-agents-md` lists both, an `AGENTS.md` already imported once is `Already included`; `claude-md` marks `AGENTS.md` `Excluded`; `managed-only` marks project, local and user `CLAUDE.md`, `AGENTS.md` and non-path-scoped rules `Excluded`. An undocumented value, or different values under the two plugin IDs, leaves `AGENTS.md` `Conditional`. Folders above the project root, `--settings`, `/plugin` disabling the built-in plugin and subfolder on-demand loading are not observed; the managed `CLAUDE.md` is not listed. | [Memory](https://code.claude.com/docs/en/memory) |
| Codex | `~/.codex`: first non-empty of `AGENTS.override.md`, `AGENTS.md`; then each directory from the project root down: override, `AGENTS.md`, then `project_doc_fallback_filenames` — one file per directory | Concatenated root → working folder; stops at `project_doc_max_bytes` (32 KiB by default) and marks the rest `Truncated` | [AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md) |
| Gemini CLI | `~/.gemini/GEMINI.md`, then `GEMINI.md` (or the names in `context.fileName`) from the project root down | Concatenated; `@file` imports followed inside the project. Just-in-time loading in subfolders is not modelled. | [GEMINI.md](https://geminicli.com/docs/cli/gemini-md/) |
| OpenCode | `~/.config/opencode/AGENTS.md`, then `AGENTS.md` from the project root down, plus the `instructions` option (paths and globs inside the project) | Remote `instructions` URLs are not fetched | [Rules](https://opencode.ai/docs/rules/) |
| Copilot CLI | `~/.copilot/copilot-instructions.md`, `.github/copilot-instructions.md`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.github/instructions/*.instructions.md` (`applyTo`) | Copilot combines sources without a general precedence order | [Repository instructions](https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions) |

## Scope, version and trust assumptions

- **Scope.** The analysis takes an agent, a registered project (or Global), a
  working folder inside it and, for Codex, a profile name. Project layers and
  instruction files are collected from the project root down to that folder.
  A working folder outside the project is rejected rather than guessed.
- **Version.** Empty means "the documented contract on the reference date".
  Supplying a version only switches documented gates: Codex named profile files
  (`<name>.config.toml`, 0.134.0 and later) versus inline `[profiles.<name>]`, and
  Claude Code's project/local exclusion of `permissions.defaultMode`
  `auto`/`bypassPermissions` (2.1.257 and later), Claude Code's direct reading of
  `AGENTS.md` (2.1.277 and later; earlier versions mark it `Excluded`) and the
  `cc-plugin-agents-md@builtin` plugin ID (2.1.285 and later; earlier versions
  read only `agents-md@builtin`).
- **Trust.** Unknown, Trusted or Untrusted. For Codex, an unknown assumption
  falls back to the `trust_level` recorded in `~/.codex/config.toml`. Unknown
  trust keeps trust-gated values `Conditional`; Untrusted marks them
  `Excluded`. The controls never change any client setting or grant trust.

## Cases left unresolved on purpose

- Claude Code managed drop-ins (`managed-settings.d/*.json`) and multiple
  managed sources: their composition depends on `managedSourcesBehavior` and on
  the delivery mechanism, so they are `Unresolved` / `Conditional`.
- Claude Code keys with field-specific rules: `modelSettings` (resolved per
  model with `effortLevel`), `crossSessionInbound`, `maxEffortLevel`,
  `useAutoModeDuringPlan`, `syncClaudeAiSkills`.
- Gemini CLI arrays.
- OpenCode with both `opencode.json` and `opencode.jsonc` in the same layer.
- Codex `requirements.toml` keys other than the approval, sandbox and
  permission-profile allowlists (listed under Sources).
- Antigravity settings as a whole.
- Anything a client reads from the environment, the command line, the network
  or an MDM profile.
