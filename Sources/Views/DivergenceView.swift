import SwiftUI

/// Analysis → Alignment: instructions, skills and MCP definitions that
/// differ between agents (issue #19). Every action stages a review.
struct DivergenceView: View {
    @Environment(ConfigStore.self) private var store
    let projectRoot: String
    let query: String

    private func filtered(_ items: [Divergence]) -> [Divergence] {
        items.filter { query.isEmpty || $0.subject.localizedCaseInsensitiveContains(query)
            || $0.members.contains { $0.path.localizedCaseInsensitiveContains(query) } }
    }

    var body: some View {
        let project = projectRoot.isEmpty ? [] : filtered(store.divergences(projectRoot: projectRoot))
        let global = filtered(store.divergences(projectRoot: ""))
        List {
            Section {
                Text(L("Files and definitions that should match across agents but differ. Nothing is synchronized automatically: each action shows a diff first."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if project.isEmpty && global.isEmpty {
                ContentUnavailableView(L("No divergences"), systemImage: "checkmark.seal",
                    description: Text(L("Instructions, skills and MCP servers agree across agents in this context.")))
            }
            if !project.isEmpty {
                Section(L("This project")) { ForEach(project) { DivergenceRow(divergence: $0) } }
            }
            if !global.isEmpty {
                Section(L("Global")) { ForEach(global) { DivergenceRow(divergence: $0) } }
            }
        }.listStyle(.inset)
    }
}

private struct DivergenceRow: View {
    @Environment(ConfigStore.self) private var store
    let divergence: Divergence
    @State private var basePath = ""
    @State private var otherPath = ""

    private var base: Divergence.Member? { divergence.members.first { $0.path == basePath } ?? divergence.members.first }
    private var other: Divergence.Member? {
        divergence.members.first { $0.path == otherPath && $0.path != base?.path }
            ?? divergence.members.first { $0.path != base?.path }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(divergence.summary)).font(.callout).foregroundStyle(.secondary)
                ForEach(divergence.members) { member in
                    HStack {
                        Text(member.familyName).font(.caption.bold())
                        Text(member.path.replacingOccurrences(of: AppPaths.home, with: "~"))
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button(L("Open")) { store.openFile(member.path) }.controlSize(.small)
                    }
                }
                if !divergence.missingFamilies.isEmpty, let source = divergence.members.first {
                    HStack {
                        Text(L("Missing for")).font(.caption)
                        ForEach(divergence.missingFamilies, id: \.self) { family in
                            Button(L("Copy to %@", AgentRegistry.definitions.first { $0.id == family }?.name ?? family)) {
                                store.copySkill(from: source.path, to: family, scope: divergence.scope)
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("copy-skill:" + divergence.subject + ":" + family)
                        }
                    }
                }
                if divergence.kind == .mcp {
                    Button(L("Compare in MCP")) {
                        store.selectedMcpName = divergence.subject
                        store.selectedAgentID = ConfigStore.mcpID
                    }.controlSize(.small)
                } else if divergence.members.count > 1, let base, let other {
                    compare(base: base, other: other)
                }
            }.padding(.vertical, 4)
        } label: {
            HStack {
                Text(L(divergence.kind.rawValue)).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Text(divergence.subject).font(.body.monospaced())
                Spacer()
                Text(divergence.members.map(\.familyName).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityIdentifier("divergence:" + divergence.id)
    }

    @ViewBuilder
    private func compare(base: Divergence.Member, other: Divergence.Member) -> some View {
        HStack {
            Picker(L("Reference"), selection: Binding(get: { base.path }, set: { basePath = $0 })) {
                ForEach(divergence.members) { Text($0.familyName).tag($0.path) }
            }
            Picker(L("Compare with"), selection: Binding(get: { other.path }, set: { otherPath = $0 })) {
                ForEach(divergence.members.filter { $0.path != base.path }) { Text($0.familyName).tag($0.path) }
            }
        }
        CompareView(baseText: base.text, baseLabel: base.familyName, otherText: other.text,
                    otherLabel: other.familyName, format: .markdown)
            .frame(minHeight: 120, maxHeight: 320)
        HStack {
            Button(L("Make %@ match %@", other.familyName, base.familyName)) {
                store.alignText(target: other.path, toMatch: base.path)
            }
            .disabled(store.isReadOnly(other.path))
            .accessibilityIdentifier("align:" + other.path)
            let sameFolder = URL(fileURLWithPath: other.path).deletingLastPathComponent() == URL(fileURLWithPath: base.path).deletingLastPathComponent()
            if divergence.kind == .instructions, sameFolder,
               ["CLAUDE.md", "GEMINI.md"].contains(URL(fileURLWithPath: other.path).lastPathComponent) {
                Button(L("Import %@ instead", URL(fileURLWithPath: base.path).lastPathComponent)) {
                    store.alignText(target: other.path, toMatch: base.path, importOnly: true)
                }
                .disabled(store.isReadOnly(other.path))
                .help(L("Replace the file with a single @import line so both agents read the same text."))
            }
        }.controlSize(.small)
    }
}
