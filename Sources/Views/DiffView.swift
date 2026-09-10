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
                    Text("Cambios detectados")
                        .font(.headline)
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(DiffEngine.summary(change.changes))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if change.changes.isEmpty {
                ContentUnavailableView("Sin diferencias semánticas",
                                       systemImage: "equal.circle",
                                       description: Text("El contenido cambió solo en formato o comentarios."))
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
                Label("Sin diferencias", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                ForEach(changes) { c in ChangeRow(change: c) }
            }
        }
    }
}
