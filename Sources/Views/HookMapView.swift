import SwiftUI

/// Analysis → Hooks: every hook command by event and matcher, across layers
/// and agents, with its source file and the orphan mark the Linter uses.
struct HookMapView: View {
    @Environment(ConfigStore.self) private var store
    let entries: [HookMapEntry]
    let selectedAgentID: String
    let query: String
    @State private var onlySelectedAgent = false

    private var visible: [HookMapEntry] {
        entries.filter { entry in
            (!onlySelectedAgent || entry.agentID == selectedAgentID) &&
            (query.isEmpty || entry.event.localizedCaseInsensitiveContains(query)
                || (entry.matcher ?? "").localizedCaseInsensitiveContains(query)
                || Secrets.maskLine(entry.command).localizedCaseInsensitiveContains(query)
                || entry.sourcePath.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section {
                Toggle(L("Only the selected agent"), isOn: $onlySelectedAgent)
                    .accessibilityIdentifier("hook-map-only-agent")
                Text(L("Listed by agent, layer (managed → user → project → local) and declaration order. The client decides the execution order, and hooks of different agents never run together."))
                    .font(.callout).foregroundStyle(.secondary)
                if entries.contains(where: { $0.orcaAccount != nil }) {
                    Text(L("Each Orca account runs the hooks of its own copy: the original user settings plus Orca's status hooks. Inherited hooks are the same as the original's, not extra ones."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if visible.isEmpty {
                ContentUnavailableView(L("No hooks found"), systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(L("No configuration file in this context declares hooks.")))
            }
            ForEach(HookMap.grouped(visible)) { group in
                Section {
                    ForEach(group.entries) { entry in row(entry) }
                } header: {
                    HStack {
                        Text(group.event).font(.headline.monospaced())
                        Text(group.matcher.map { L("matcher") + ": " + $0 } ?? L("all tools"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("hook-event:" + group.id)
            }
        }.listStyle(.inset)
    }

    private func row(_ entry: HookMapEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.agentName).font(.caption.bold())
                Text(L(entry.layer.rawValue)).font(.caption).foregroundStyle(.secondary)
                if let account = entry.orcaAccount {
                    Text(L("Orca account %@", account) + (entry.orcaSelected ? " · " + L("selected") : ""))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let role = entry.orcaRole { orcaBadge(role) }
                if !entry.missingPaths.isEmpty {
                    Label(L("Orphan"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button(L("Open")) { store.openFile(entry.sourcePath) }
            }
            HookCommandRow(command: entry.command)
            Text(entry.sourcePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .opacity((entry.orcaRole.map(Self.isCopy) ?? false) ? 0.75 : 1)
        .accessibilityIdentifier("hook-entry:" + entry.id)
    }

    private static func isCopy(_ role: OrcaHookRole) -> Bool {
        if case .inherited = role { return true }
        return false
    }

    /// Managed by Orca, inherited from the original (not a new hook), only in
    /// Orca's stale copy, or the account's own.
    @ViewBuilder
    private func orcaBadge(_ role: OrcaHookRole) -> some View {
        switch role {
        case .managed:
            Label(L("Managed by Orca"), systemImage: "gearshape.2")
                .font(.caption).foregroundStyle(.secondary)
                .help(L("Status hook Orca installs and removes by itself."))
        case .inherited(let origin):
            Label(L("Inherited from %@", tilde(origin)), systemImage: "arrow.turn.down.right")
                .font(.caption).foregroundStyle(.secondary)
                .help(L("Orca copies this hook from the original file; it is the same hook, not a new one."))
        case .staleCopy(let origin):
            Label(L("Not in %@", tilde(origin)), systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.orange)
                .help(L("Only in Orca's copy: the original no longer declares it, so Orca drops it on its next launch."))
        case .accountOwned:
            Label(L("Account's own"), systemImage: "person.crop.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tilde(_ path: String) -> String { path.replacingOccurrences(of: AppPaths.home, with: "~") }
}
