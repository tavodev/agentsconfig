import Foundation

// The storage probe links production Models/AppSettings/AtomicWriter/SnapshotStore.
// Only presentation summaries are stubbed: no parser, UI or MCP dependency needed.
enum DiffEngine {
    static func storageSummary(_ changes: [SemanticChange]) -> String { "storage probe" }
}

@main struct HistoryProbe {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 5)
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let path = arguments[2]
        let store = SnapshotStore(root: root, historyLimit: { 1_000 }, isPathTracked: { _ in false })
        if arguments[3] == "verify" {
            let history = try store.loadHistory(for: path)
            precondition(history.count == 121, "lost index entries")
            precondition(Set(history.map(\.id)).count == 121, "duplicate IDs")
            let contents = Set(history.compactMap { store.content(for: path, version: $0) })
            precondition(contents.contains("legacy baseline"))
            for worker in 0..<4 {
                for value in 0..<30 { precondition(contents.contains("worker-\(worker)-\(value)")) }
            }
            print("4 processes; 120 writes plus legacy baseline; 121 unique readable versions")
        } else {
            for value in 0..<30 {
                _ = try store.record(path: path, content: "worker-\(arguments[4])-\(value)", origin: .app, changes: [])
            }
        }
    }
}
