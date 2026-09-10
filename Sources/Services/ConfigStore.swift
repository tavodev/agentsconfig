import Foundation
import SwiftUI
import AppKit

@Observable
@MainActor
final class ConfigStore {

    // MARK: published state
    private(set) var agents: [Agent] = []
    var selectedAgentID: String?
    var selectedPath: String?

    private(set) var documents: [String: ConfigDocument] = [:]
    private(set) var edits: [String: String] = [:]          // unsaved buffers
    private(set) var dirtyPaths: Set<String> = []
    private(set) var conflicts: Set<String> = []            // dirty buffer + disk changed
    private(set) var externalChanges: [String: ExternalChange] = [:]
    private(set) var histories: [String: [FileVersion]] = [:]
    private(set) var saveErrors: [String: String] = [:]
    private(set) var lastEventAt: Date?
    private(set) var watchedCount = 0
    private(set) var activity: [ActivityEvent] = []
    var selectedEventID: UUID?
    var findRequest = 0

    static let activityID = "__activity__"

    // MARK: internals
    private let snapshots = SnapshotStore()
    private var selfWriteHashes: [String: String] = [:]
    private var fileOwners: [String: String] = [:]          // path → agentID
    private var dirOwners: [String: String] = [:]           // dir path → agentID
    private var fileSource: [String: ConfigSource] = [:]    // file path → source spec
    private var definitions: [String: AgentDefinition] = [:]

    @ObservationIgnored private let watcher = FileWatcher(onChange: { _ in })

    init() {
        watcher.onChange = { [weak self] path in
            Task { @MainActor in self?.handleWatchEvent(path) }
        }
        for def in AgentRegistry.definitions { definitions[def.id] = def }
        Notifier.shared.configure()
        Notifier.shared.onSelect = { [weak self] path in self?.openFile(path) }
        refresh()
        seedActivity()
    }

    /// Seed the activity feed from persisted snapshot indexes (recent history).
    private func seedActivity() {
        var events: [ActivityEvent] = []
        for agent in agents {
            for f in agent.files where !f.volatile {
                for v in snapshots.loadHistory(for: f.path).prefix(15) {
                    events.append(ActivityEvent(
                        date: v.date, path: f.path, agentID: agent.id,
                        agentName: agent.name, origin: v.origin,
                        summary: v.summary, changeCount: v.changeCount
                    ))
                }
            }
        }
        activity = events.sorted { $0.date > $1.date }.prefix(300).map { $0 }
    }

    private func logActivity(path: String, origin: FileVersion.Origin,
                             changes: [SemanticChange]) {
        let agentID = fileOwners[path]
        let name = agents.first { $0.id == agentID }?.name ?? "?"
        activity.insert(ActivityEvent(
            date: Date(), path: path, agentID: agentID, agentName: name,
            origin: origin, summary: DiffEngine.summary(changes),
            changeCount: changes.count, changes: changes
        ), at: 0)
        if activity.count > 300 { activity.removeLast(activity.count - 300) }
    }

    // MARK: - scanning

    func refresh() {
        agents = AgentRegistry.detect()
        fileOwners.removeAll(); dirOwners.removeAll(); fileSource.removeAll()
        var watchPaths: [String] = []

        for agent in agents {
            guard let def = definitions[agent.id] else { continue }
            for src in def.sources {
                let p = src.expandedPath
                if src.isDirectory {
                    dirOwners[p] = agent.id
                    watchPaths.append(p)
                }
            }
            for f in agent.files {
                fileOwners[f.path] = agent.id
                fileSource[f.path] = ConfigSource(
                    path: f.path, format: f.format, role: f.role,
                    volatile: f.volatile, readOnly: f.readOnly, note: f.note
                )
                watchPaths.append(f.path)
            }
        }
        watcher.watch(watchPaths)
        watchedCount = watchPaths.count
        if selectedAgentID == nil { selectedAgentID = agents.first?.id }
        // Preload all tracked files so external changes can be diffed even
        // before the user opens them. Skip anything over ~2MB.
        for agent in agents {
            for f in agent.files where f.exists && f.size < 2_000_000 && documents[f.path] == nil {
                _ = load(f.path)
            }
        }
    }

    /// Re-resolve one agent's file list (called when a watched dir changes).
    private func rescan(agentID: String) {
        guard let def = definitions[agentID],
              let idx = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let oldPaths = Set(agents[idx].files.map(\.path))
        let updated = Agent(
            id: def.id, name: def.name, symbol: def.symbol, color: def.color,
            files: AgentRegistry.resolveFiles(def), detectionPath: agents[idx].detectionPath,
            notes: def.notes
        )
        agents[idx] = updated
        for f in updated.files where !oldPaths.contains(f.path) {
            fileOwners[f.path] = agentID
        }
        refreshWatchList()
    }

    private func refreshWatchList() {
        var paths = Array(dirOwners.keys)
        for agent in agents {
            paths.append(contentsOf: agent.files.map(\.path))
            for f in agent.files {
                fileOwners[f.path] = agent.id
                fileSource[f.path] = ConfigSource(
                    path: f.path, format: f.format, role: f.role,
                    volatile: f.volatile, readOnly: f.readOnly, note: f.note
                )
            }
        }
        watcher.watch(paths)
        watchedCount = paths.count
    }

    // MARK: - documents

    func document(for path: String) -> ConfigDocument? {
        if documents[path] == nil { load(path) }
        return documents[path]
    }

    func text(for path: String) -> String {
        edits[path] ?? documents[path]?.text ?? ""
    }

    private func trackedFile(for path: String) -> TrackedFile? {
        for agent in agents { if let f = agent.files.first(where: { $0.path == path }) { return f } }
        return nil
    }

    func format(for path: String) -> ConfigFormat {
        trackedFile(for: path)?.format ?? AgentRegistry.inferFormat(path: path)
    }

    @discardableResult
    private func load(_ path: String) -> ConfigDocument? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let format = format(for: path)
        // Same throttle as handleFileChanged: skip parsing huge volatile files
        // unless the user is actually looking at them.
        let heavyVolatile = (trackedFile(for: path)?.volatile ?? false)
            && text.utf8.count > 300_000 && path != selectedPath
        let parsed = heavyVolatile ? (tree: Any?.none, error: String?.none)
                                   : Parsers.parse(text, format: format)
        let doc = ConfigDocument(
            text: text, tree: parsed.tree, parseError: parsed.error,
            loadedAt: Date(), hash: SnapshotStore.sha256(text)
        )
        documents[path] = doc

        // lint + managed blocks onto the TrackedFile
        let lint = Linter.lint(path: path, text: text, tree: parsed.tree,
                               parseError: parsed.error, format: format)
        updateFileMeta(path: path) { f in
            f.issues = lint.issues
            f.managedBlocks = lint.managed
        }
        if histories[path] == nil { histories[path] = snapshots.loadHistory(for: path) }

        // baseline snapshot for files that have none yet (skip volatile)
        if let tf = trackedFile(for: path), !tf.volatile,
           (histories[path]?.isEmpty ?? true) {
            snapshots.record(path: path, content: text, origin: .baseline, changes: [])
            histories[path] = snapshots.loadHistory(for: path)
        }
        return doc
    }

    private func updateFileMeta(path: String, _ mutate: (inout TrackedFile) -> Void) {
        for ai in agents.indices {
            if let fi = agents[ai].files.firstIndex(where: { $0.path == path }) {
                mutate(&agents[ai].files[fi])
                return
            }
        }
    }

    // MARK: - editing

    func updateEdit(path: String, text: String) {
        edits[path] = text
        if let doc = documents[path], doc.text == text {
            dirtyPaths.remove(path)
        } else {
            dirtyPaths.insert(path)
        }
    }

    func discardEdit(path: String) {
        edits.removeValue(forKey: path)
        dirtyPaths.remove(path)
        conflicts.remove(path)
    }

    var selectedFormat: ConfigFormat {
        guard let p = selectedPath else { return .text }
        return format(for: p)
    }

    var canSaveSelected: Bool {
        guard let p = selectedPath else { return false }
        return dirtyPaths.contains(p)
    }

    func saveSelected() {
        guard let p = selectedPath else { return }
        save(path: p)
    }

    func save(path: String) {
        guard let text = edits[path] else { return }
        guard let tf = trackedFile(for: path), !tf.readOnly else {
            saveErrors[path] = "Archivo de solo lectura"
            return
        }

        // validate
        let parsed = Parsers.parse(text, format: tf.format)
        if let err = parsed.error {
            saveErrors[path] = err
            return
        }
        saveErrors.removeValue(forKey: path)

        // snapshot current disk version before overwriting
        var changeList: [SemanticChange] = []
        if let current = documents[path]?.text, current != text {
            let prevTree = documents[path]?.tree
            changeList = DiffEngine.diff(oldText: current, newText: text,
                                         oldTree: prevTree, newTree: parsed.tree)
            if !tf.volatile {
                snapshots.record(path: path, content: current, origin: .app, changes: changeList)
            }
        }
        logSave(path: path, changes: changeList)

        do {
            try writeAtomic(text, to: path)
            selfWriteHashes[path] = SnapshotStore.sha256(text)
            edits.removeValue(forKey: path)
            dirtyPaths.remove(path)
            conflicts.remove(path)
            externalChanges.removeValue(forKey: path)
            reload(path, origin: .app)
        } catch {
            saveErrors[path] = "No se pudo escribir: \(error.localizedDescription)"
        }
    }

    /// Write preserving existing POSIX permissions (configs are often 600).
    private func writeAtomic(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var perms: NSNumber? = nil
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            perms = attrs[.posixPermissions] as? NSNumber
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).acfg-tmp-\(UUID().uuidString.prefix(8))")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        if let perms {
            try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
        }
        if fm.fileExists(atPath: path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    // MARK: - watch events

    private func handleWatchEvent(_ path: String) {
        lastEventAt = Date()

        if let agentID = dirOwners[path] {
            rescan(agentID: agentID)
            // files inside may have changed too — reload any open docs under it
            for docPath in documents.keys where docPath.hasPrefix(path + "/") {
                handleFileChanged(docPath)
            }
            return
        }
        handleFileChanged(path)
    }

    private func handleFileChanged(_ path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            updateFileMeta(path: path) { $0.exists = false }
            return
        }
        guard let data = fm.contents(atPath: path),
              let newText = String(data: data, encoding: .utf8) else { return }

        let newHash = SnapshotStore.sha256(newText)

        // self-write → silent refresh
        if let pending = selfWriteHashes[path], pending == newHash {
            selfWriteHashes.removeValue(forKey: path)
            reload(path, origin: nil)
            return
        }

        let oldText = documents[path]?.text
        guard oldText != newText || documents[path] == nil else {
            reload(path, origin: nil)
            return
        }

        // diff vs what we had
        let format = format(for: path)
        let oldDoc = documents[path]
        let tf = trackedFile(for: path)

        // Throttle: for big volatile files, only compute a tree diff while the
        // user is looking at the file; otherwise record a lightweight marker.
        let heavyVolatile = (tf?.volatile ?? false) && newText.utf8.count > 300_000
            && path != selectedPath

        let newParsed = heavyVolatile ? (tree: Any?.none, error: String?.none)
                                      : Parsers.parse(newText, format: format)
        let changes: [SemanticChange]
        if let oldDoc, !heavyVolatile {
            changes = DiffEngine.diff(oldText: oldDoc.text, newText: newText,
                                      oldTree: oldDoc.tree, newTree: newParsed.tree)
        } else {
            changes = []
        }

        if !(tf?.volatile ?? false) {
            if let v = snapshots.record(path: path, content: newText,
                                        origin: .external, changes: changes) {
                var h = histories[path] ?? []
                h.insert(v, at: 0)
                histories[path] = h
            }
        }

        logActivity(path: path, origin: .external, changes: changes)

        externalChanges[path] = ExternalChange(changes: changes, previousContent: oldText)

        reload(path, origin: nil)

        if !(tf?.volatile ?? false), !changes.isEmpty {
            let agentName = agents.first { $0.id == fileOwners[path] }?.name ?? "Agente"
            Notifier.shared.postChange(path: path, agentName: agentName,
                                       summary: DiffEngine.summary(changes))
        }

        // dirty buffer → conflict (don't clobber user's typing)
        if dirtyPaths.contains(path) {
            conflicts.insert(path)
        } else {
            edits.removeValue(forKey: path)
        }
    }

    private func reload(_ path: String, origin: FileVersion.Origin?) {
        _ = origin
        documents.removeValue(forKey: path)
        _ = load(path)
        // refresh exists/size/mtime
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = attrs[.modificationDate] as? Date
            updateFileMeta(path: path) { f in
                f.exists = true; f.size = size; f.mtime = mtime
            }
        }
    }

    // MARK: - external change actions

    func acknowledgeExternal(path: String) {
        externalChanges.removeValue(forKey: path)
    }

    /// User keeps their unsaved buffer despite a disk change.
    func resolveConflictKeepMine(path: String) {
        conflicts.remove(path)
        externalChanges.removeValue(forKey: path)
    }

    func revertExternal(path: String) {
        guard let prev = externalChanges[path]?.previousContent else { return }
        applyContent(path: path, text: prev, origin: .revert)
        externalChanges.removeValue(forKey: path)
    }

    func restoreVersion(path: String, version: FileVersion) {
        guard let content = snapshots.content(for: path, version: version) else { return }
        applyContent(path: path, text: content, origin: .revert)
    }

    private func applyContent(path: String, text: String, origin: FileVersion.Origin) {
        let tf = trackedFile(for: path)
        if let current = documents[path]?.text {
            let parsed = Parsers.parse(text, format: format(for: path))
            let ch = DiffEngine.diff(oldText: current, newText: text,
                                     oldTree: documents[path]?.tree, newTree: parsed.tree)
            if !(tf?.volatile ?? false) {
                snapshots.record(path: path, content: current, origin: .app, changes: ch)
            }
        }
        do {
            try writeAtomic(text, to: path)
            selfWriteHashes[path] = SnapshotStore.sha256(text)
            edits.removeValue(forKey: path)
            dirtyPaths.remove(path)
            conflicts.remove(path)
            reload(path, origin: origin)
            if !(tf?.volatile ?? false) {
                if let v = snapshots.record(path: path, content: text,
                                            origin: origin, changes: []) {
                    var h = histories[path] ?? []
                    h.insert(v, at: 0)
                    histories[path] = h
                }
            }
        } catch {
            saveErrors[path] = "No se pudo restaurar: \(error.localizedDescription)"
        }
    }

    func history(for path: String) -> [FileVersion] {
        if histories[path] == nil { histories[path] = snapshots.loadHistory(for: path) }
        return histories[path] ?? []
    }

    func versionContent(path: String, version: FileVersion) -> String? {
        snapshots.content(for: path, version: version)
    }

    // MARK: - file actions (context menus, notifications)

    /// Navigate to a file: selects its agent + file in the UI.
    func openFile(_ path: String) {
        if let agentID = fileOwners[path] ?? agentID(forPath: path) {
            selectedAgentID = agentID
            selectedPath = path
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func agentID(forPath path: String) -> String? {
        for agent in agents where agent.files.contains(where: { $0.path == path }) {
            return agent.id
        }
        return nil
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInDefaultApp(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Restore the most recent snapshot that differs from the current content.
    func restorePrevious(_ path: String) {
        let currentHash = documents[path]?.hash
        guard let target = history(for: path).first(where: { $0.hash != currentHash }) else { return }
        restoreVersion(path: path, version: target)
    }

    func requestFind() { findRequest += 1 }

    /// Log an app-originated save into the activity feed.
    private func logSave(path: String, changes: [SemanticChange]) {
        logActivity(path: path, origin: .app, changes: changes)
    }
}
