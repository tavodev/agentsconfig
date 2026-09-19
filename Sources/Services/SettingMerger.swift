import Foundation

@MainActor enum SettingMerger {
    private struct Working { var raw: Any; var setting: ResolvedSetting }
    static func resolve(_ sources: [SourceObservation], agentID: String, version: String = "",
                        trust: AnalysisContext.Trust = .unknown) -> [ResolvedSetting] {
        var values: [[String]: Working] = [:]
        let localPaths = Set(sources.filter { ["Project", "Local"].contains($0.label) }.map(\.path))
        func visit(_ tree: Any, path: [String], body: ([String], Any) -> Void) {
            if let dict = tree as? [String: Any], !dict.isEmpty, path.count < 20 {
                for key in dict.keys.sorted() { visit(dict[key]!, path: path + [key], body: body) }
            } else { body(path, tree) }
        }
        for source in sources where source.label != "Constraints" {
            guard let tree = source.tree else { continue }
            visit(tree, path: []) { key, raw in
                guard !key.isEmpty, values.count < 500 || values[key] != nil else { return }
                var state = source.state
                var reason = source.reason
                let top = key[0]
                let local = ["Project", "Local"].contains(source.label)
                if agentID == "codex", source.label == "Project",
                   ["model_provider", "model_providers", "openai_base_url", "chatgpt_base_url", "notify", "otel", "profile", "profiles", "apps_mcp_product_sku", "experimental_realtime_ws_base_url"].contains(top) {
                    state = "Excluded"; reason = "This key is not accepted in project configuration."
                }
                if agentID == "claude-code", local {
                    if top == "modelPicker" || (key == ["permissions", "defaultMode"] &&
                        ["auto", "bypassPermissions"].contains(raw as? String ?? "") &&
                        ConfigurationResolver.version(version, atLeast: "2.1.257")) {
                        state = "Excluded"; reason = "This setting is not accepted at project/local scope for this version."
                    } else if trust != .trusted && (key == ["permissions", "allow"] || top == "env" ||
                                top == "extraKnownMarketplaces" || key == ["permissions", "additionalDirectories"]) {
                        state = trust == .untrusted ? "Excluded" : "Conditional"; reason = "Activation requires project trust."
                    }
                }
                if agentID == "claude-code", ["modelSettings", "crossSessionInbound", "maxEffortLevel", "useAutoModeDuringPlan", "syncClaudeAiSkills"].contains(top) {
                    state = "Unresolved"; reason = "This key has additional field-specific rules; inspect the source and client for its effective value."
                }
                if agentID == "claude-code", local, top == "remoteControlAtStartup", raw as? Bool == true {
                    state = "Excluded"; reason = "A project may disable remote control, but cannot enable it with this key."
                }
                var origin = ValueOrigin(source: source.path, state: state,
                    value: ConfigurationResolver.render(raw, key: key), reason: reason)
                if ["Excluded", "Unresolved", "Missing"].contains(state) {
                    if values[key] == nil { values[key] = Working(raw: NSNull(), setting: .init(key: key, value: "—", state: state, origins: [])) }
                    values[key]?.setting.origins.append(origin)
                    if state == "Unresolved" { values[key]?.setting.state = "Unresolved" }
                    return
                }
                var incoming = raw
                var previous = values[key]
                var merged = false
                if let old = previous?.raw, let list = incoming as? [Any], let oldList = old as? [Any] {
                    if (agentID == "claude-code" && !["fallbackModel", "modelPicker"].contains(top) &&
                        !(top == "availableModels" && source.label == "Managed")) ||
                        (agentID == "opencode" && ["plugin", "instructions"].contains(top)) {
                        var seen = Set<String>()
                        incoming = (oldList + list).filter {
                            let data = (try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys])) ?? Data()
                            return seen.insert(data.base64EncodedString()).inserted
                        }
                        merged = true
                    } else if agentID == "gemini-cli" {
                        origin.state = "Unresolved"; origin.reason = "Array composition is field-specific; inspect the client."
                        previous?.setting.origins.append(origin); previous?.setting.state = "Unresolved"
                        values[key] = previous; return
                    }
                }
                if agentID == "claude-code", let old = previous?.raw as? Bool, let new = raw as? Bool {
                    let strictTrue = ["disableClaudeAiConnectors", "isolatePeerMachines", "disableArtifact"]
                    let strictFalse = ["enableArtifact"] + (localPaths.contains(previous?.setting.origins.last(where: { ["Applied", "Conditional", "Merged"].contains($0.state) })?.source ?? "") ? ["remoteControlAtStartup"] : [])
                    if (strictTrue.contains(top) && old && !new) || (strictFalse.contains(top) && !old && new) {
                        origin.state = "Restricted"; origin.reason = "A restrictive value from another scope remains in force."
                        previous?.setting.origins.append(origin); values[key] = previous; return
                    }
                }
                for other in Array(values.keys) where other != key && (other.starts(with: key) || key.starts(with: other)) {
                    if values[other]?.setting.value != "—" {
                        values[other]?.setting.state = "Shadowed"
                        values[other]?.setting.origins.append(.init(source: source.path, state: "Shadowed", value: "—", reason: "Replaced by a different value shape."))
                    }
                }
                var origins = previous?.setting.origins ?? []
                if !merged { origins = origins.map { item in
                    var item = item
                    if ["Applied", "Conditional", "Merged"].contains(item.state) { item.state = "Shadowed" }
                    return item
                } }
                origin.state = merged ? "Merged" : state
                origins.append(origin)
                values[key] = Working(raw: incoming, setting: .init(key: key, value: ConfigurationResolver.render(incoming, key: key),
                    state: state == "Conditional" || (merged && previous?.setting.state == "Conditional") ? "Conditional" : "Estimated", origins: origins))
            }
        }
        for source in sources where source.label == "Constraints" {
            guard let tree = source.tree else { continue }
            for (requirement, key) in [("allowed_approval_policies", "approval_policy"), ("allowed_sandbox_modes", "sandbox_mode"), ("allowed_permission_profiles", "default_permissions")] {
                if let allowed = tree[requirement] as? [String], let existing = values[[key]], let selected = existing.raw as? String, !allowed.contains(selected) {
                    values[[key]]?.setting.state = "Restricted"
                    values[[key]]?.setting.origins.append(.init(source: source.path, state: "Restricted",
                        value: ConfigurationResolver.render(allowed, key: [requirement]),
                        reason: "The selected value is outside the managed allowlist; client behavior must be confirmed."))
                }
            }
        }
        // Enforcement-only options must not be advertised as ordinary overrides.
        if agentID == "claude-code", let managed = sources.last(where: { $0.label == "Managed" && $0.tree != nil && $0.state == "Applied" }) {
            if managed.tree?["allowManagedPermissionRulesOnly"] as? Bool == true {
                for key in [["permissions", "allow"], ["permissions", "deny"], ["permissions", "ask"]] {
                    guard var working = values[key] else { continue }
                    let permissions = managed.tree?["permissions"] as? [String: Any]
                    working.raw = permissions?[key[1]] ?? [String]()
                    working.setting.value = ConfigurationResolver.render(working.raw, key: key)
                    working.setting.origins.append(.init(source: managed.path, state: "Restricted", value: working.setting.value,
                        reason: "Managed-only permission rules exclude rules from other scopes."))
                    working.setting.state = "Restricted"; values[key] = working
                }
            }
        }
        if agentID == "claude-code", sources.contains(where: { $0.tree?["modelSettings"] != nil }), values[["effortLevel"]] != nil {
            values[["effortLevel"]]?.setting.state = "Unresolved"
        }
        return values.values.map(\.setting).sorted { $0.id < $1.id }
    }
}

