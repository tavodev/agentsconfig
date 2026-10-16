import SwiftUI

/// Analysis → Context: estimated context an agent loads before any task,
/// broken down per file, with the configurable warning threshold.
struct ContextBudgetView: View {
    @Environment(ConfigStore.self) private var store
    let budget: ContextBudget
    let query: String

    private var items: [ContextBudgetItem] {
        budget.items.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query)
            || $0.path.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    metric(L("Estimated total"), "≈ " + budget.total.formatted(), prominent: true)
                    metric(L("Instructions"), "≈ " + budget.tokens(.instruction).formatted())
                    metric(L("Skills"), "≈ " + budget.tokens(.skill).formatted())
                    metric(L("MCP servers"), budget.mcpServers.formatted())
                }
                if budget.exceedsThreshold {
                    Label(L("Above the warning threshold of %d estimated tokens.", budget.threshold),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("context-budget-warning")
                }
                let conditional = budget.tokens(nil, .conditional)
                if conditional > 0 {
                    Text(L("Conditional sources could add ≈ %d more.", conditional))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(L("Approximate: bytes ÷ 4, not a tokenizer. Skills count name and description only. MCP tool definitions are unknown without starting the servers, so only servers are counted."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach([ContextBudgetItem.Kind.instruction, .skill, .mcp], id: \.self) { kind in
                let rows = items.filter { $0.kind == kind }
                if !rows.isEmpty {
                    Section(L(kind.rawValue)) {
                        ForEach(rows) { item in row(item) }
                    }
                }
            }
        }.listStyle(.inset)
    }

    private func metric(_ title: String, _ value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(prominent ? .title2.monospacedDigit().bold() : .title3.monospacedDigit())
        }
    }

    private func row(_ item: ContextBudgetItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(item.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            Text(L(item.inclusion.rawValue)).font(.caption)
                .foregroundStyle(item.inclusion == .counted ? Color.primary : Color.secondary)
            Text(item.kind == .mcp ? "—" : "≈ " + item.estimatedTokens.formatted())
                .font(.body.monospacedDigit()).frame(minWidth: 70, alignment: .trailing)
            Button(L("Open")) { store.openFile(item.path) }
        }
        .help(L(item.reason))
        .accessibilityIdentifier("context-item:" + item.id)
    }
}
