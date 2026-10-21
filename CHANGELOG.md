# Changelog

## Unreleased

- Automatic updates with Sparkle 2.10.0: the distributed build checks a signed appcast on GitHub Releases once a day and downloads and installs EdDSA-signed updates on its own. **AgentsConfig → Check for Updates…** checks on demand and Settings → Updates can turn off automatic checks or automatic installation. This is the app's only network traffic; Debug builds, the UI test host and isolated/demo runs never start the updater. Users of 0.1.0 must install the first release with Sparkle by hand.
- Settings → Privacy can delete all local history (current, legacy and `.migrated` backups) after a confirmation that states what will be removed; symlinks are unlinked, never followed. Turning history off still keeps existing versions.
- Claude Code instruction analysis models the `AGENTS.md` / `.claude/AGENTS.md` fallback when no CLAUDE file exists from the project root to the working folder, the "Project instructions" setting (user/managed scope only) and its version gates, and stops `@` imports at four hops.
- Cursor and Copilot CLI skills in their home folders are grouped as personal, and those inside a project as project, instead of system.
- Markdown preview keeps GFM table cells beyond the header's column count as extra unnamed columns. A paragraph after a list now has tests pinning CommonMark behavior (lazy continuation joins the item; a blank line ends the list).
- `docs/PRECEDENCE.md` documents, per agent and with official links, the settings layers and merge rules the analysis models, the instruction load order, the scope/version/trust assumptions and the cases left unresolved.
- Export setup writes a redacted folder with a manifest (agent, relative path, SHA-256) of global and project configuration; Import setup previews each file and stages a diff review in which redacted values keep the local value or are left out. Redaction is documented as best-effort.
- Analysis → Alignment detects instructions, skills and MCP definitions that differ between agents, with a redacted diff and reviewed actions (copy text, `@import`, copy a single-file skill, match an MCP definition). The comparator flags servers defined differently and the sidebar shows the divergence count.
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
