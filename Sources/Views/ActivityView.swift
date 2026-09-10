import SwiftUI

/// Cross-agent timeline of every detected config change.
struct ActivityFeedView: View {
    @Environment(ConfigStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.activity.isEmpty {
                ContentUnavailableView(
                    "Sin actividad todavía",
                    systemImage: "bolt.horizontal",
                    description: Text("Aquí aparecerá cada cambio que un agente —o esta app— haga en las configuraciones.")
                )
            } else {
                List(selection: $store.selectedEventID) {
                    ForEach(store.activity) { event in
                        ActivityRow(event: event)
                            .tag(event.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Actividad")
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    private var originStyle: (String, Color) {
        switch event.origin {
        case .external: return ("arrow.down.circle.fill", .blue)
        case .app: return ("arrow.up.circle.fill", .green)
        case .revert: return ("arrow.uturn.backward.circle.fill", .purple)
        case .baseline: return ("flag.circle.fill", .gray)
        }
    }

    var body: some View {
        let (icon, color) = originStyle
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: event.path).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                    Text(event.agentName)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Text(event.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(event.date, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// Detail pane for the selected activity event.
struct ActivityDetailView: View {
    @Environment(ConfigStore.self) private var store

    private var event: ActivityEvent? {
        store.activity.first { $0.id == store.selectedEventID }
    }

    var body: some View {
        if let event {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: event.path).lastPathComponent)
                            .font(.system(size: 14, weight: .semibold))
                        Text(event.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.date, format: .dateTime.hour().minute().second().day().month())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Abrir archivo") { store.openFile(event.path) }
                        .controlSize(.small)
                }
                .padding(14)
                Divider()
                if event.changes.isEmpty {
                    ContentUnavailableView(
                        event.summary,
                        systemImage: "doc.badge.clock",
                        description: Text("Detalle de cambios no disponible para eventos previos a esta sesión. Abre el archivo y revisa su Historial.")
                    )
                } else {
                    List(event.changes) { c in ChangeRow(change: c) }
                        .listStyle(.inset)
                }
            }
            .navigationTitle("Detalle del cambio")
        } else {
            ContentUnavailableView("Selecciona un evento",
                                   systemImage: "bolt.horizontal.circle")
        }
    }
}
