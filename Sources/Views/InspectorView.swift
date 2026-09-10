import SwiftUI
import AppKit

/// Right-edge inspector (Xcode-style): metadata, issues and quick actions
/// for the selected file. macOS 26 renders it as edge-to-edge glass.
struct FileInspectorView: View {
    let path: String?
    @Environment(ConfigStore.self) private var store

    private var file: TrackedFile? {
        guard let path else { return nil }
        for agent in store.agents {
            if let f = agent.files.first(where: { $0.path == path }) { return f }
        }
        return nil
    }

    var body: some View {
        if let path, let file {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let fd = DocsCatalog.fileDoc(for: path) {
                        aboutSection(fd)
                    }
                    metaSection(path: path, file: file)
                    if !file.issues.isEmpty { issuesSection(file) }
                    if !file.managedBlocks.isEmpty { managedSection(file) }
                    actionsSection(path: path)
                }
                .padding(14)
            }
            .inspectorColumnWidth(min: 210, ideal: 250, max: 320)
        } else {
            ContentUnavailableView("Sin selección", systemImage: "sidebar.trailing")
        }
    }

    private func aboutSection(_ doc: DocsCatalog.FileDoc) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(doc.title, systemImage: "questionmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(doc.body)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = doc.docsURL {
                Link("Documentación oficial ↗", destination: url)
                    .font(.caption2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func metaSection(path: String, file: TrackedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadatos").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            metaRow("Formato", file.format.badge)
            metaRow("Rol", file.role.label)
            metaRow("Tamaño", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
            if let m = file.mtime {
                metaRow("Modificado", m.formatted(date: .abbreviated, time: .shortened))
            }
            if let perms = posixPerms(path) { metaRow("Permisos", perms) }
            if file.volatile { metaRow("Tipo", "volátil (estado)") }
            if file.readOnly { metaRow("Acceso", "solo lectura") }
            if let note = file.note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    private func issuesSection(_ file: TrackedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Problemas").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(file.issues.enumerated()), id: \.offset) { _, i in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: i.severity == .error ? "xmark.octagon.fill" :
                                    i.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(i.severity == .error ? .red :
                                            i.severity == .warning ? .orange : .blue)
                    Text(i.message).font(.caption2)
                }
            }
        }
    }

    private func managedSection(_ file: TrackedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gestionado por terceros").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(file.managedBlocks.enumerated()), id: \.offset) { _, b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.owner).font(.caption.bold())
                    Text(b.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionsSection(path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Acciones").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            InspectorAction(icon: "folder", label: "Mostrar en Finder") {
                store.revealInFinder(path)
            }
            InspectorAction(icon: "app.badge", label: "Abrir con app por defecto") {
                store.openInDefaultApp(path)
            }
            InspectorAction(icon: "doc.on.doc", label: "Copiar ruta") {
                store.copyPath(path)
            }
            InspectorAction(icon: "arrow.uturn.backward", label: "Restaurar versión anterior") {
                store.restorePrevious(path)
            }
            .disabled(store.history(for: path).isEmpty)
        }
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func posixPerms(_ path: String) -> String? {
        guard let n = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        else { return nil }
        return String(format: "%o", n)
    }
}

struct InspectorAction: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .padding(.vertical, 2)
    }
}
