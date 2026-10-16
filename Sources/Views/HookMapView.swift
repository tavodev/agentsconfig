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
        .accessibilityIdentifier("hook-entry:" + entry.id)
    }
}
