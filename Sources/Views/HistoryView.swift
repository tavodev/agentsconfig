import SwiftUI

/// Timeline of recorded versions for a file, with diff preview and restore.
struct HistoryView: View {
    let path: String
    @Environment(ConfigStore.self) private var store
    @State private var selected: FileVersion?
    @State private var confirmRestore = false

    var body: some View {
        let versions = store.history(for: path)
        if versions.isEmpty {
            ContentUnavailableView(
                "Sin historial",
                systemImage: "clock",
                description: Text("Los snapshots se crean cuando el archivo cambia o lo editas desde aquí.")
            )
        } else {
            HSplitView {
                List(selection: $selected) {
                    ForEach(versions) { v in
                        VersionRow(version: v)
                            .tag(v)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 260, idealWidth: 300)

                versionDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var versionDetail: some View {
        if let v = selected,
           let content = store.versionContent(path: path, version: v) {
            let current = store.document(for: path)?.text ?? ""
            VStack(spacing: 0) {
                HStack {
                    Text(v.date, style: .date).font(.headline)
                    Text(v.date, style: .time).font(.subheadline).foregroundStyle(.secondary)
                    originBadge(v.origin)
                    Spacer()
                    Button("Restaurar esta versión") { confirmRestore = true }
                        .controlSize(.small)
                }
                .padding(12)
                Divider()
                ScrollView {
                    CompareView(
                        baseText: content,
                        baseLabel: "Esta versión",
                        otherText: current,
                        otherLabel: "Actual en disco",
                        format: store.format(for: path)
                    )
                    .padding(14)
                }
            }
            .confirmationDialog(
                "¿Restaurar esta versión?",
                isPresented: $confirmRestore,
                titleVisibility: .visible
            ) {
                Button("Restaurar") { store.restoreVersion(path: path, version: v) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("El contenido actual quedará guardado como un snapshot más del historial.")
            }
        } else {
            ContentUnavailableView("Selecciona una versión",
                                   systemImage: "clock.arrow.2.circlepath")
        }
    }

    private func originBadge(_ o: FileVersion.Origin) -> some View {
        let (label, color): (String, Color) = switch o {
        case .baseline: ("base", .gray)
        case .external: ("externo", .blue)
        case .app: ("esta app", .green)
        case .revert: ("revert", .purple)
        }
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct VersionRow: View {
    let version: FileVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(version.date, style: .time)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(version.date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(version.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
