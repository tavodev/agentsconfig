import SwiftUI

/// Timeline of recorded versions for a file, with diff preview and restore.
struct HistoryView: View {
    @AppStorage("historyEnabled", store: AppSettings.defaults) private var globallyEnabled = true
    let path: String
    @Environment(ConfigStore.self) private var store
    @State private var selected: FileVersion?
    @State private var compareWith: FileVersion?   // nil = actual en disco

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(L("Record history for this file"), isOn: Binding(
                    get: { !store.excludedHistoryPaths.contains(path) && store.historyPolicyAllowsRecording(path) },
                    set: { store.setHistoryEnabled($0, for: path) }
                ))
                .disabled(!store.historyPolicyAllowsRecording(path))
                .accessibilityIdentifier("file-history-enabled")
                Spacer()
                Button(L("Clear file history")) { store.requestHistoryRemoval(path: path) }
                    .disabled(store.history(for: path).isEmpty || store.historyErrors[path] != nil)
                    .accessibilityIdentifier("clear-file-history")
            }.padding(12)
            Text(L("Global history settings and source exclusions still apply. Removing versions does not change the config file or legacy backups."))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            if !globallyEnabled {
                Text(L("History recording is globally disabled in Settings.")).font(.caption).foregroundStyle(.orange)
            }
            if let error = store.historyRemovalErrors[path] {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button(L("Retry content cleanup")) { store.retryHistoryCleanup(path: path) }
                }.padding(8)
            }
            Divider()
            historyContent
        }
    }

    @ViewBuilder private var historyContent: some View {
        let versions = store.history(for: path)
        if let err = store.historyErrors[path] {
            // a corrupt/ambiguous index is surfaced, never silently emptied
            ContentUnavailableView(
                L("History unavailable"),
                systemImage: "exclamationmark.triangle",
                description: Text(err)
            )
        } else if versions.isEmpty {
            ContentUnavailableView(
                L("No history"),
                systemImage: "clock",
                description: Text(L("Snapshots are created when the file changes or you edit it here."))
            )
        } else {
            HSplitView {
                List(selection: $selected) {
                    ForEach(versions) { v in
                        VersionRow(version: v)
                            .tag(v)
                            .contextMenu {
                                Button(L("Remove this version")) { store.requestHistoryRemoval(path: path, version: v) }
                            }
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
            let versions = store.history(for: path)
            let otherContent: String = {
                guard let cw = compareWith, cw != v else {
                    return store.document(for: path)?.text ?? ""
                }
                return store.versionContent(path: path, version: cw) ?? ""
            }()
            let otherLabel = compareWith == nil || compareWith == v
                ? L("Current on disk")
                : L("Another version")
            VStack(spacing: 0) {
                HStack {
                    Text(v.date, style: .date).font(.headline)
                    Text(v.date, style: .time).font(.subheadline).foregroundStyle(.secondary)
                    originBadge(v.origin)
                    Spacer()
                    Picker(L("Compare with"), selection: $compareWith) {
                        Text(L("Current on disk")).tag(FileVersion?.none)
                        ForEach(versions.filter { $0 != v }) { o in
                            Text("\(o.date, style: .date) \(o.date, style: .time) · \(o.summary)")
                                .tag(FileVersion?.some(o))
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 260)
                    Button(L("Restore this version")) {
                        store.requestRestore(path: path, version: v)
                    }
                    .controlSize(.small)
                    .disabled(store.isReadOnly(path))
                }
                .padding(12)
                Divider()
                ScrollView {
                    CompareView(
                        baseText: content,
                        baseLabel: L("This version"),
                        otherText: otherContent,
                        otherLabel: otherLabel,
                        format: store.format(for: path)
                    )
                    .padding(14)
                }
            }
        } else {
            ContentUnavailableView(L("Select a version"),
                                   systemImage: "clock.arrow.2.circlepath")
        }
    }

    private func originBadge(_ o: FileVersion.Origin) -> some View {
        let (label, color): (String, Color) = switch o {
        case .baseline: (L("base"), .gray)
        case .external: (L("external"), .blue)
        case .app: (L("this app"), .green)
        case .revert: (L("revert"), .purple)
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
