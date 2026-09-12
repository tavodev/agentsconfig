import SwiftUI

/// Sheet listing semantic changes detected in a file.
struct DiffSheet: View {
    let path: String
    let change: ExternalChange
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Changes detected"))
                        .font(.headline)
                    Text(path.replacingOccurrences(of: AppPaths.home, with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(DiffEngine.summary(change.changes))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Button(L("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if change.changes.isEmpty {
                ContentUnavailableView(L("No semantic differences"),
                                       systemImage: "equal.circle",
                                       description: Text(L("Content changed only in formatting or comments.")))
            } else {
                List(change.changes) { c in
                    ChangeRow(change: c)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

struct ChangeRow: View {
    let change: SemanticChange

    private var badgeColor: Color {
        switch change.kind {
        case .added: return .green
        case .removed: return .red
        case .modified: return .orange
        }
    }
    private var badgeText: String {
        switch change.kind {
        case .added: return "+"
        case .removed: return "−"
        case .modified: return "~"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(badgeText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(badgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(change.keyPath)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                HStack(spacing: 6) {
                    if let old = change.oldValue {
                        Text(old)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.red)
                            .strikethrough(change.kind == .modified)
                            .lineLimit(2)
                    }
                    if change.kind == .modified {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    if let new = change.newValue {
                        Text(new)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(change.kind == .added ? .green : .primary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Inline two-pane diff: version vs current. Used by HistoryView.
struct CompareView: View {
    let baseText: String
    let baseLabel: String
    let otherText: String
    let otherLabel: String
    let format: ConfigFormat

    private var changes: [SemanticChange] {
        let o = Parsers.parse(baseText, format: format)
        let n = Parsers.parse(otherText, format: format)
        return DiffEngine.diff(oldText: baseText, newText: otherText,
                               oldTree: o.tree, newTree: n.tree)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(baseLabel, systemImage: "clock.arrow.circlepath")
                Image(systemName: "arrow.right")
                Label(otherLabel, systemImage: "doc")
                Spacer()
                Text(DiffEngine.summary(changes))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if changes.isEmpty {
                Label(L("No differences"), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                ForEach(changes) { c in ChangeRow(change: c) }
            }
        }
    }
}

struct SaveReviewSheet: View {
    let review: ConfigStore.SaveReview
    @Environment(ConfigStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Review save")).font(.headline)
            Text(review.path.replacingOccurrences(of: AppPaths.home, with: "~")).font(.caption)
            if review.overwritesConflict {
                Label(L("This save replaces the conflicting disk version."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !review.historyEnabled {
                Text(L("History is disabled for this destination; saving will not create a backup."))
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(L("Secret values remain hidden in the review. Saving writes the original values."))
                .font(.caption).foregroundStyle(.secondary)
            if review.original.utf8.count > Parsers.maximumFileBytes || review.proposed.utf8.count > Parsers.maximumFileBytes {
                Text(L("Large-file review: %d bytes on disk → %d proposed bytes. Detailed diff is omitted; inspect Source before confirming.", review.original.utf8.count, review.proposed.utf8.count))
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            ScrollView {
                CompareView(baseText: review.original, baseLabel: L("Current on disk"),
                            otherText: review.proposed, otherLabel: L("Proposed"), format: review.format)
            }
            HStack {
                Button(L("Cancel")) { store.cancelSaveReview() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Confirm save")) { store.confirmSaveReview() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("confirm-save")
            }
        }.padding(20).frame(minWidth: 650, minHeight: 420)
        .accessibilityIdentifier("save-review")
    }
}

struct RestoreReviewSheet: View {
    let request: RestoreRequest
    @Environment(ConfigStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Review restore")).font(.headline)
            Text(store.restoreExplanation(for: request)).font(.caption).foregroundStyle(.secondary)
            if store.preparingRestore { ProgressView(L("Preparing review…")) }
            else if let proposed = store.restoreProposedText {
                ScrollView {
                    CompareView(baseText: store.restoreOriginalText, baseLabel: L("Current on disk"),
                                otherText: proposed, otherLabel: L("Proposed"), format: store.format(for: request.path))
                }
            } else { Text(L("Version content unavailable")).foregroundStyle(.red) }
            HStack {
                Button(L("Cancel")) { store.cancelRestore() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Restore")) { store.confirmRestore() }
                    .disabled(store.preparingRestore || store.restoreProposedText == nil || store.isReadOnly(request.path))
                    .accessibilityIdentifier("confirm-restore")
            }
        }.padding(20).frame(minWidth: 650, minHeight: 420)
        .accessibilityIdentifier("restore-review")
    }
}
