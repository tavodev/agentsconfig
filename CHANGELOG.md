# Changelog

## 0.1.0 — Unreleased

Initial experimental release candidate.

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
