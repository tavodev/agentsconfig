import SwiftUI

/// Cross-agent timeline of every detected config change.
struct ActivityFeedView: View {
    @Environment(ConfigStore.self) private var store
    @State private var query = ""

    private var events: [ActivityEvent] {
        guard !query.isEmpty else { return store.activity }
        return store.activity.filter {
            $0.path.localizedCaseInsensitiveContains(query)
                || $0.agentName.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if store.activity.isEmpty {
                ContentUnavailableView(
                    L("No activity yet"),
                    systemImage: "bolt.horizontal",
                    description: Text(L("Every change an agent — or this app — makes to configs will show up here."))
                )
            } else {
                List(selection: $store.selectedEventID) {
                    ForEach(events) { event in
                        ActivityRow(event: event)
                            .tag(event.id)
                            .contextMenu {
                                Button(L("Open file")) { store.openFile(event.path) }
                                Button(L("Show in Finder")) { store.revealInFinder(event.path) }
                            }
                    }
                }
                .listStyle(.inset)
                .searchable(text: $query, prompt: L("Filter changes"))
            }
        }
        .navigationTitle(L("Activity"))
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
                        Text(event.path.replacingOccurrences(of: AppPaths.home, with: "~"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.date, format: .dateTime.hour().minute().second().day().month())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L("Open file")) { store.openFile(event.path) }
                        .controlSize(.small)
                }
                .padding(14)
                Divider()
                if event.changes.isEmpty {
                    ContentUnavailableView(
                        event.summary,
                        systemImage: "doc.badge.clock",
                        description: Text(L("Change detail unavailable for events before this session. Open the file and check its History."))
                    )
                } else {
                    List(event.changes) { c in ChangeRow(change: c) }
                        .listStyle(.inset)
                }
            }
            .navigationTitle(L("Change detail"))
        } else {
            ContentUnavailableView(L("Select an event"),
                                   systemImage: "bolt.horizontal.circle")
        }
    }
}
