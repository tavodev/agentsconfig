import SwiftUI

/// Timeline of recorded versions for a file, with diff preview and restore.
struct HistoryView: View {
    let path: String
    @Environment(ConfigStore.self) private var store
    @State private var selected: FileVersion?
    @State private var compareWith: FileVersion?   // nil = actual en disco
    @State private var confirmRestore = false

    var body: some View {
        let versions = store.history(for: path)
        if versions.isEmpty {
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
                    Button(L("Restore this version")) { confirmRestore = true }
                        .controlSize(.small)
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
            .confirmationDialog(
                L("Restore this version?"),
                isPresented: $confirmRestore,
                titleVisibility: .visible
            ) {
                Button(L("Restore")) { store.restoreVersion(path: path, version: v) }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(L("Current content will be kept as another history snapshot."))
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
