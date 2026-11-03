import Foundation

/// Per-key layer notes for files in Orca homes. The resolver does not model
/// these homes; what can be said from the files alone is that an account's
/// user layer is its original (`~/.claude/settings.json`, the global Claude
/// state or `~/.codex/config.toml`) plus Orca's status hooks, and which keys
/// the account owns or Orca copies back. Project layers are not invented:
/// Orca does not change them, and they are analyzed from the regular homes.
extension OrcaIntegration {
    /// Codex keys Orca copies from a home back to the Codex config
    /// (`PROMOTED_CODEX_SETTING_KEYS` + `PROMOTED_CODEX_TABLE_SETTING_KEYS`
    /// in `config-toml-promoted-setting-values.ts`).
    static let promotedCodexKeys: Set<String> = [
        "model", "model_reasoning_effort", "approval_policy", "sandbox_mode",
        "tui.status_line", "tui.status_line_use_colors", "tui.terminal_title", "tui.theme",
        "features.daemon_auto_start",
    ]

    /// Most keys annotated per file; very large `.claude.json` files stop here.
    static let layerNoteLimit = 2_000

    // Reasons are fixed strings so `L` translates them by exact match.
    static let noteCopied = "Copied from the original"
    static let noteDiffers = "Differs from the original"
    static let noteMissing = "Not in the original"
    static let noteUnreadable = "Original not readable"
    static let noteStatusHooks = "Orca status hooks"
    static let noteMerged = "Merged from the global state"
    static let noteAccountOwned = "Account's own"
    static let notePromoted = "Copied back to the original"

    static let reasonSettingsCopied = "This account's user settings are the original Claude Code settings plus Orca's status hooks; Orca overwrites this copy before each launch. Project and local settings apply as usual and are not analyzed here."
    static let reasonSettingsDiffers = "Orca replaces this value with the original's on its next launch. Edit the original to change it for this account."
    static let reasonSettingsMissing = "The original settings do not set this key; Orca removes it on its next launch."
    static let reasonStatusHooks = "Orca adds its status hooks to the original's hooks. Analysis → Hooks tells them apart."
    static let reasonUnreadable = "The original file is missing or unreadable, so this copy is not compared. Orca leaves it as it is."
    static let reasonStateMerged = "Orca copies this key from the global Claude Code state before each launch."
    static let reasonStateDiffers = "Orca replaces this value with the global state's on its next launch."
    static let reasonStateAccount = "Sign-in, identity and caches belong to this account; Orca never copies them."
    static let reasonStateEntries = "Orca adds every entry of the global state here before each launch; entries only in this account are kept."
    static let reasonStateOnlyHere = "The global state does not have this key; Orca keeps this account's value."
    static let reasonCodexMirrored = "This home's user config is the Codex config mirrored by Orca before each launch. Project config and profiles apply as usual and are not analyzed here."
    static let reasonCodexDiffers = "Orca mirrors the Codex config over this value on its next launch; it rewrites relative paths, so a difference here may be expected."
    static let reasonCodexPromoted = "A change made here (for example from a session) is copied back to the Codex config by Orca before mirroring; otherwise the Codex config value is used."
    static let reasonCodexPromotedDiffers = "Orca keeps whichever side changed since its last baseline. The baseline is not read, so which value wins is not determined."
    static let reasonCodexHomeOwned = "Project and hook trust belong to this home; Orca keeps them when mirroring."
    static let reasonCodexOwnServer = "MCP server only in this home; Orca keeps it when mirroring."
    static let reasonCodexNotInOrigin = "The Codex config does not set this key. Orca keeps or removes it depending on its baseline, which is not read; not determined."

    /// Notes keyed by dotted key path. Empty for files Orca does not
    /// regenerate from a settings file (account-owned files, `CLAUDE.md`,
    /// rules, loose files other than `settings.json`).
    @MainActor
    static func layerNotes(relation: Relation, kind: Kind, fileName: String,
                           copy: [String: Any], origin: [String: Any]?, originPath: String?) -> [String: LayerNote] {
        var notes: [String: LayerNote] = [:]
        func note(_ path: [String], _ state: String, _ reason: String, informational: Bool, originValue: Any? = nil) {
            guard notes.count < layerNoteLimit else { return }
            notes[path.joined(separator: ".")] = LayerNote(
                state: state, reason: reason,
                effectiveValue: originValue.map { ConfigurationResolver.render($0, key: path) },
                effectiveSource: originValue == nil ? nil : originPath,
                project: nil, informational: informational)
        }
        /// Copy vs original: equal keys are informational and recurse so
        /// nested rows are explained too; differing values show the original's.
        func compare(_ value: Any, _ originValue: Any?, _ path: [String],
                     same: String, differs: String, missing: (state: String, reason: String, informational: Bool)) {
            guard notes.count < layerNoteLimit else { return }
            guard let originValue else {
                note(path, missing.state, missing.reason, informational: missing.informational); return
            }
            if isEqualValue(value, originValue) {
                note(path, noteCopied, same, informational: true)
            } else {
                note(path, noteDiffers, differs, informational: false, originValue: originValue)
            }
            if let table = value as? [String: Any], let originTable = originValue as? [String: Any] {
                for key in table.keys.sorted() {
                    compare(table[key]!, originTable[key], path + [key], same: same, differs: differs, missing: missing)
                }
            }
        }

        switch (relation, kind) {
        case (.mirroredCopy, .claude) where fileName == "settings.json":
            for key in copy.keys.sorted() {
                if key == "hooks" {
                    note([key], noteStatusHooks, reasonStatusHooks, informational: true); continue
                }
                guard let origin else { note([key], noteUnreadable, reasonUnreadable, informational: false); continue }
                compare(copy[key]!, origin[key], [key], same: reasonSettingsCopied, differs: reasonSettingsDiffers,
                        missing: (noteMissing, reasonSettingsMissing, false))
            }
        case (.mergedState, .claude):
            for key in copy.keys.sorted() {
                if isAccountBoundState(key) {
                    note([key], noteAccountOwned, reasonStateAccount, informational: true); continue
                }
                guard let origin else { note([key], noteUnreadable, reasonUnreadable, informational: false); continue }
                let value = copy[key]!
                if key == "projects" || key == "mcpServers", let entries = value as? [String: Any] {
                    note([key], noteMerged, reasonStateEntries, informational: true)
                    let originEntries = origin[key] as? [String: Any] ?? [:]
                    for name in entries.keys.sorted() {
                        guard let originEntry = originEntries[name] else {
                            note([key, name], noteAccountOwned, reasonStateOnlyHere, informational: true); continue
                        }
                        if isEqualValue(entries[name]!, originEntry) {
                            note([key, name], noteMerged, reasonStateMerged, informational: true)
                        } else {
                            note([key, name], noteDiffers, reasonStateDiffers, informational: false, originValue: originEntry)
                        }
                    }
                    continue
                }
                guard let originValue = origin[key] else {
                    note([key], noteAccountOwned, reasonStateOnlyHere, informational: true); continue
                }
                if isEqualValue(value, originValue) {
                    note([key], noteMerged, reasonStateMerged, informational: true)
                } else {
                    note([key], noteDiffers, reasonStateDiffers, informational: false, originValue: originValue)
                }
            }
        case (.mergedState, .codex):
            /// Like `compare`, but promoted keys (at any depth) say Orca may copy them back.
            func codexCompare(_ value: Any, _ originValue: Any?, _ path: [String]) {
                guard notes.count < layerNoteLimit else { return }
                let promoted = promotedCodexKeys.contains(path.joined(separator: "."))
                guard let originValue else {
                    note(path, noteMissing, reasonCodexNotInOrigin, informational: false); return
                }
                if isEqualValue(value, originValue) {
                    note(path, promoted ? notePromoted : noteCopied,
                         promoted ? reasonCodexPromoted : reasonCodexMirrored, informational: true)
                } else {
                    note(path, noteDiffers, promoted ? reasonCodexPromotedDiffers : reasonCodexDiffers,
                         informational: false, originValue: originValue)
                }
                if let table = value as? [String: Any], let originTable = originValue as? [String: Any] {
                    for key in table.keys.sorted() { codexCompare(table[key]!, originTable[key], path + [key]) }
                }
            }
            for key in copy.keys.sorted() {
                let value = copy[key]!
                if key == "projects" || key == "hooks" {
                    note([key], noteAccountOwned, reasonCodexHomeOwned, informational: true); continue
                }
                guard let origin else { note([key], noteUnreadable, reasonUnreadable, informational: false); continue }
                if key == "mcp_servers", let servers = value as? [String: Any] {
                    let originServers = origin[key] as? [String: Any] ?? [:]
                    for name in servers.keys.sorted() {
                        if let originServer = originServers[name] {
                            codexCompare(servers[name]!, originServer, [key, name])
                        } else {
                            note([key, name], noteAccountOwned, reasonCodexOwnServer, informational: true)
                        }
                    }
                    continue
                }
                codexCompare(value, origin[key], [key])
            }
        default:
            break
        }
        return notes
    }

    /// Order-insensitive deep equality of parsed values.
    static func isEqualValue(_ a: Any, _ b: Any) -> Bool {
        (a as AnyObject).isEqual(b as AnyObject)
    }
}
