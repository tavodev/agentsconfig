import SwiftUI

struct McpDefinitionDiffView: View {
    let entries: [McpServerEntry]
    @State private var firstID = ""
    @State private var secondID = ""
    private var first: McpServerEntry? { entries.first { $0.id == firstID } ?? entries.first }
    private var second: McpServerEntry? { entries.first { $0.id == secondID } ?? entries.dropFirst().first }
    private func label(_ entry: McpServerEntry) -> String {
        entry.agentName + " · " + L(entry.scope) + " · " + (entry.projectPath ?? URL(fileURLWithPath: entry.sourcePath).lastPathComponent)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Definition differences")).font(.headline)
            Picker(L("First source"), selection: Binding(get: { first?.id ?? "" }, set: { firstID = $0 })) {
                ForEach(entries) { Text(label($0)).tag($0.id) }
            }
            Picker(L("Second source"), selection: Binding(get: { second?.id ?? "" }, set: { secondID = $0 })) {
                ForEach(entries) { Text(label($0)).tag($0.id) }
            }
            if let first, let second {
                let changes = McpComparison.differences(first, second)
                if changes.isEmpty { Text(L("Same inspected definition. Runtime behavior is not verified.")).font(.callout).foregroundStyle(.secondary) }
                else { ForEach(changes) { ChangeRow(change: $0) } }
            }
            Text(L("Arguments keep their order. Secrets remain hidden. Client-specific options are compared without assuming equivalence."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

