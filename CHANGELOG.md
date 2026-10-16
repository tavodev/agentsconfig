# Changelog

## Unreleased

- Analysis → Context estimates the tokens an agent loads before any task (instructions with imports, skill names and descriptions, MCP server count), per file, with a configurable warning threshold. Labelled as an approximation.
- Static MCP checks per server, shown in the comparator and server cards: missing or non-executable commands, unset variables, empty env values, missing `cwd`/path arguments and malformed URLs. Nothing is launched; Settings can opt into reading PATH from the login shell.
- Analysis → Hooks maps every hook by event and matcher across managed, user, project and local layers and all agents, with the source file and an orphan mark for missing scripts.
- Read-only inventory for Windsurf / Devin Desktop (rules, workflows, skills, hooks and every documented MCP file) and Claude Desktop (`claude_desktop_config.json`, excluded from history); per-file docs with official links for Cursor, Copilot CLI, Windsurf and Claude Desktop. None of them is an MCP add/copy destination.
- Filtering the file list opens every skill group with matches; clearing the filter restores the session's previous expansion.
- Hook audit no longer treats the path of a remote URL (`https://host/scripts/x.sh`) as a local script outside the config root; `file://` paths still count.

## 0.1.0 — 2026-10-04

Initial experimental release, build 3.

- Universal macOS distribution for Apple Silicon and Intel, with Developer ID
  signing, hardened runtime and notarized app/DMG.

- Security diagnostics for broad permissions, approval bypasses, risky hooks,
  unpinned MCP packages and literal secrets, with per-file rule muting.
- Configuration analysis with per-key provenance, instruction and skill inspection,
  context-aware MCP comparison, reviewed diagnostic exports and redacted search.
- Skills in the file list and Configuration → Skills are grouped by origin (personal, project, plugins, system) and nested by owner when more than one is present; skill rows omit the long cache path.
- Native macOS interface for Claude Code, Codex, Gemini/Antigravity and OpenCode configuration inspection.
- Per-repository (project) config inspection, including git submodules, with the same watching, diffing, history and masking as global files; local MCP servers appear read-only in the cross-agent comparator.
- Sidebar Global/Projects switcher with a project picker and root/submodule scope chips.
- De-duplicated structured view (no key shown both in a special card and in "All keys"), with key descriptions shown inline; the cross-agent MCP comparator is a column-aligned table.
- Rendered Markdown preview (real headings, lists, code blocks, quotes) for instruction files.
- Settings reachable inline from the sidebar, in addition to the native macOS Settings window.
- Live file monitoring, structured JSON/JSONC editing and JSON/JSONC/TOML source editing.
- Reviewed saves and restores, conflict detection, local version history and per-file history controls.
- Redacted diffs and masked read-only inspection; editable source contains real values.
- Reviewed MCP add/copy workflows with explicit supported schemas.
- Background processing and paginated editing for files between 2 MB and 16 MB.
- English and Spanish interfaces, activity feed and optional local notifications.
- Isolated hostless tests, multiprocess storage verification and a separate UI regression host.
- Native per-destination navigation: three columns for files/Activity, full-width Settings and MCP comparator, an inspector that adapts between a side panel and a compact sheet, and a History view that switches between a compact version picker and a side-by-side list.
- Product icons for Claude, Codex, Gemini and OpenCode in the sidebar, MCP matrix and MCP cards.
- Twenty-nine XCUITest scenarios covering reviewed save/restore, conflict state, named controls, window-size-driven layout, compact inspector sequencing and integrated editing flows.

See [README.md](README.md) for supported scope and limitations, and
[the release procedure](docs/RELEASING.md) for verification and publication steps.
