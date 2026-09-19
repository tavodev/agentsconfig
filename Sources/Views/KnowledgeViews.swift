import SwiftUI

struct InstructionListView: View {
    let items: [InstructionSource]
    let notices: [String]
    var body: some View {
        List {
            ForEach(notices, id: \.self) { Text(L($0)).font(.callout).foregroundStyle(.secondary) }
            if items.isEmpty { Text(L("No instructions found for this context.")) }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                DisclosureGroup {
                    Text(L(item.reason)).font(.callout).foregroundStyle(.secondary)
                    if let origin = item.importedBy { Text(L("Imported by") + ": " + origin).font(.caption.monospaced()) }
                    Text(item.path).font(.caption.monospaced()).textSelection(.enabled)
                    Text("\(item.includedBytes) / \(item.bytes) bytes").font(.caption.monospaced())
                    Text(item.text).font(.body.monospaced()).textSelection(.enabled)
                } label: {
                    HStack {
                        Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(item.path).font(.body.monospaced()).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Text(L(item.state)).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("instruction:" + String(index))
            }
        }.listStyle(.inset)
    }
}

struct SkillPackagesView: View {
    let packages: [SkillPackage]
    @State private var preview: ResourceSelection?
    struct ResourceSelection: Identifiable {
        var id: String { resource.path }
        let resource: KnowledgeResource
        let root: String
    }
    var body: some View {
        List {
            if packages.isEmpty { Text(L("No skills found for this context.")) }
            ForEach(packages) { package in
                DisclosureGroup {
                    Text(package.path).font(.caption.monospaced()).textSelection(.enabled)
                    Text(L("Consumers") + ": " + package.consumers.joined(separator: ", ")).font(.callout)
                    Text("\(package.bytes) bytes").font(.caption.monospaced())
                    ForEach(package.metadata.keys.sorted(), id: \.self) { key in
                        LabeledContent(L(key), value: package.metadata[key] ?? "")
                    }
                    ForEach(package.issues, id: \.self) { Label(L($0), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    DisclosureGroup(L("Instructions preview")) { Text(package.body).font(.body.monospaced()).textSelection(.enabled) }
                    DisclosureGroup(L("Package resources")) {
                        ForEach(package.resources) { resource in
                            HStack {
                                Text(resource.name).font(.caption.monospaced())
                                Spacer()
                                Text(L(resource.state)).font(.caption).foregroundStyle(.secondary)
                                Button(L("Preview")) { preview = .init(resource: resource, root: (package.path as NSString).deletingLastPathComponent) }
                                    .disabled(resource.state != "Available")
                            }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(package.name).font(.headline)
                            Spacer()
                            Text(L(package.state)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(package.description).font(.callout).lineLimit(3)
                    }
                }.accessibilityIdentifier("skill-package:" + package.name)
            }
        }.listStyle(.inset)
        .sheet(item: $preview) { selection in ResourcePreviewView(selection: selection) }
    }
}

private struct ResourcePreviewView: View {
    let selection: SkillPackagesView.ResourceSelection
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selection.resource.name).font(.headline)
            Text(L("Read-only preview. Scripts are never executed.")).font(.callout).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) { Text(text).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer(); Button(L("Close")) { dismiss() } }
        }.padding(20).frame(minWidth: 620, idealWidth: 760, minHeight: 440)
        .task {
            guard let path = KnowledgeInspector.safeReference(selection.resource.name, base: selection.root, boundary: selection.root) else {
                text = L("Resource is outside the package or its path cannot be resolved."); return
            }
            let value = await Task.detached(priority: .userInitiated) { try? Parsers.readText(at: path) }.value
            if let value { text = Secrets.maskText(value, format: AgentRegistry.inferFormat(path: path), masking: true) }
            else { text = L("Resource is unreadable, binary, or exceeds the preview limit.") }
        }
    }
}

