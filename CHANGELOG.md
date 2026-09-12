# Changelog

## 0.1.0 — Unreleased

Initial experimental release candidate. No release has been published by this preparation.

- Native macOS interface for Claude Code, Codex, Gemini/Antigravity and OpenCode configuration inspection.
- Per-repository (project) config inspection, including git submodules, with the same watching, diffing, history and masking as global files; local MCP servers appear read-only in the cross-agent comparator.
- Sidebar Global/Projects switcher with a project picker and root/submodule scope chips, replacing nested disclosure trees.
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

See [release notes](docs/releases/0.1.0.md) for limitations and [release preparation](docs/RELEASING.md) for publication gates.
