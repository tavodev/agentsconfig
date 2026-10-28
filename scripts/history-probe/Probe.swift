import Foundation

// The storage probe links production Models/AppSettings/AtomicWriter/SnapshotStore.
// Only presentation summaries are stubbed: no parser, UI or MCP dependency needed.
enum DiffEngine {
    static func storageSummary(_ changes: [SemanticChange]) -> String { "storage probe" }
}

/// Deliberately public fixture material shared by independent probe processes.
/// This executable is test-only; production always persists random keys in Keychain.
private struct FixtureKeys: HistoryKeyProvider {
    func loadKey(id: String) throws -> Data? { Data(repeating: 0x5A, count: 32) }
    func storeKey(_ data: Data, id: String) throws { precondition(data.count == 32) }
}

@main struct HistoryProbe {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 5 || (arguments.count == 6 && arguments[5] == "encrypted-fixture"))
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let path = arguments[2]
        let encrypted = arguments.count == 6
        let store = SnapshotStore(root: root, historyLimit: { 1_000 },
            keyProvider: encrypted ? FixtureKeys() : nil, isPathTracked: { _ in false })
        if arguments[3] == "encrypt" {
            precondition(encrypted)
            try store.setEncryption(enabled: true)
        } else if arguments[3] == "verify" {
            let status = try store.encryptionStatus()
            precondition(status.enabled == encrypted)
            let history = try store.loadHistory(for: path)
            precondition(history.count == 121, "lost index entries")
            precondition(Set(history.map(\.id)).count == 121, "duplicate IDs")
            let contents = Set(history.compactMap { store.content(for: path, version: $0) })
            precondition(contents.contains("legacy baseline"))
            for worker in 0..<4 {
                for value in 0..<30 { precondition(contents.contains("worker-\(worker)-\(value)")) }
            }
            print("\(encrypted ? "Encrypted" : "Plaintext") fixture: 4 processes; 120 writes plus legacy baseline; 121 unique readable versions")
        } else {
            for value in 0..<30 {
                _ = try store.record(path: path, content: "worker-\(arguments[4])-\(value)", origin: .app, changes: [])
            }
        }
    }
}
