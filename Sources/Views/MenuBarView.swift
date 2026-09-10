import SwiftUI
import AppKit

/// Menu bar extra: pending changes + recent activity at a glance.
struct MenuBarView: View {
    @Environment(ConfigStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AgentsConfig")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !store.externalChanges.isEmpty {
                    Text(L("%d pending", store.externalChanges.count))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.blue))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if store.activity.isEmpty {
                Text(L("No changes detected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.activity.prefix(6)) { event in
                        Button {
                            store.openFile(event.path)
                        } label: {
                            ActivityRow(event: event)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if event.id != store.activity.prefix(6).last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button(L("Open AgentsConfig")) {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
                Spacer()
                Button(L("Quit")) { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(10)
        }
        .frame(width: 340)
    }
}
