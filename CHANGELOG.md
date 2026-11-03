# Changelog

## Unreleased

- Configuration folders managed by Orca are listed as their own agents: one **Claude Code · Orca** per Claude profile (`claude-profiles/<account>/home`, marking the one Orca has selected) and one **Codex · Orca** per account plus the shared runtime home. Their files get the same documentation, value controls and **Add setting** catalog as `~/.claude` / `~/.codex`; folders Orca links back to those homes stay under Claude Code or Codex, Codex credentials are left out, and they are not MCP destinations or part of layer analysis. Files Orca regenerates from those homes before each launch (`settings.json`, the `CLAUDE.md` import, copied loose files, `.claude.json`, Codex `config.toml` and imported global rules) are read-only with a note on where they come from; the inspector shows whether each copy is in sync with its source — ignoring Orca's own status hooks in `settings.json` — or pending Orca's next launch, and **Open source** jumps to the original. Settings → Configuration folders can hide them.
- MCP servers of Orca homes, including per-project servers of Claude profiles, are marked in the MCP comparator as an **Orca mirror** (grouped with their source and left out of divergences), **Differs from source** or **Only in this account**; account-only servers can be promoted to `~/.claude.json` or `~/.codex/config.toml` through the usual reviewed diff. The `config.toml` of each Codex home warns about keys Orca keeps in conflict with `~/.codex` (key names only) and about an unreadable or unrecognized Orca settings baseline.
- Gemini CLI (335 keys) and OpenCode (153 keys) get the same descriptions, value controls and **Add setting** catalog, generated from their official JSON schemas; map entries such as `mcpServers.<name>.command` resolve for any name. Gemini `admin.*` keys are offered only in managed settings.
- Lists of text are edited in place (add, remove, reorder, documented suggestions) in JSON and in TOML; a TOML array is rewritten keeping its single- or multi-line layout and re-parsed to confirm only it changed. Arrays with comments inside stay in Source.
- Documented objects (`worktree`, `sandbox`, `statusLine`, `voice`, `autoMode`, `modelSettings.<model>`, Codex/Gemini tables…) show **+** to add only their documented fields; per-model entries pre-fill the model name.
- When another layer decides a key (a local override, managed settings, a project setting that isn't accepted, an untrusted project), the row explains it with the effective value and the file it comes from. A user file is analysed against the project last chosen in the sidebar. This is an on-disk estimate, like the Configuration view.

- **Add setting** in the structured view lists every documented setting the file can still take (Claude Code `settings.json` / `settings.local.json` and Codex `config.toml`), grouped by topic and searchable, with description, type, default and docs link. Keys for other scopes (e.g. managed-only or `~/.claude.json` keys in a settings file, user-only Codex keys in a project file) and deprecated keys are left out; `<id>` keys ask for a name. The key goes into the edit buffer with its default (or chosen) value and still needs the reviewed save. Codex keys are inserted as text — inside the parent `[table]`, in a new section, or as a dotted key — and the result is re-parsed so only that key changes; comments, formatting and CRLF line endings are preserved.
- Existing values use controls from the official reference: a picker for closed option lists (an unknown value is kept as "Custom"), suggestions for open lists such as `model`, numeric range checks, a "Default: x" badge, and **Reset to default**, which removes the key (in TOML only that line).
- `scripts/refresh-docs-reference.py` refreshes kinds, options, defaults, scopes and topics from the Claude Code settings reference, the SchemaStore schema and the Codex config reference, keeping the Spanish text.
- Key tooltips cover every key in the official Claude Code settings reference (248) and Codex config reference (316, including `<id>` placeholder keys such as `mcp_servers.<id>.command`), in English and Spanish, plus documented sub-fields (`statusLine.*`, `voice.*`, `autoMode.*`, `modelSettings.<model>.*`). Each ⓘ popover links to the official docs — the key's own anchor for Claude Code — and the ⓘ button shows a pointing-hand cursor. Gemini CLI and OpenCode keys link to their configuration pages. App-internal keys the references don't document (e.g. Codex `desktop.*`) stay without a description.

## 0.2.0 — 2026-11-03

Build 4. First release with automatic updates: users of 0.1.0 must download and install it by hand (replace the app in `/Applications`); later releases arrive through Sparkle.

- Optional local history encryption in Settings → Privacy: AES-256-GCM protects existing indexes, snapshots and legacy backups, with a device-local Keychain key, reviewed encryption/decryption, resumable conversion and visible failures instead of plaintext fallback. Config files remain unchanged; old clients must be closed before conversion.
- Structured TOML editing can patch existing text, boolean, Int64 and finite numeric values without rewriting comments or surrounding formatting. Apply updates the buffer and Save still requires review; unsupported types and new keys use Source.
- `scripts/export-legacy-history.py` prepares a new history folder for older releases without changing the original, preserving current versions and legacy backups and rejecting collisions, symlinks, invalid content and existing destinations.
- Synthetic resource-limit regression tests cover exact UTF-8 file-size thresholds, discovery depth/directory/entry/file bounds and redacted diff limits. The deliberate limits remain unchanged.
- Claude Code instruction analysis includes observed inline managed `claudeMd` content with its JSON key path, redacted preview and context cost; uncertain coexistence and managed composition stay explicit.
- Copilot installed-plugin skills and MCP sources retain unverified activation in analysis and comparisons; plugin skill context costs remain conditional even when user definitions share a name.
- Claude Code instruction analysis includes the managed, read-only `CLAUDE.md` before user and project instructions, including in `managed-only` mode and the context estimate; `claudeMdExcludes` cannot exclude this policy file.
- Copilot CLI skills under `.copilot/installed-plugins` are grouped as plugins with their package as owner.
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
