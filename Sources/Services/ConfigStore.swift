import Foundation
import SwiftUI
import AppKit
import os

/// Scan timings: `log stream --info --predicate 'subsystem == "com.tavodev.agentsconfig"'`,
/// or the "Points of Interest" track in Instruments.
private let scanLog = Logger(subsystem: "com.tavodev.agentsconfig", category: "scan")
private let scanSignposts = OSSignposter(subsystem: "com.tavodev.agentsconfig", category: .pointsOfInterest)

@Observable
@MainActor
final class ConfigStore {

    // MARK: published state
    private(set) var agents: [Agent] = []
    var selectedAgentID: String?
    var selectedPath: String?

    private(set) var documents: [String: ConfigDocument] = [:]
    private(set) var edits: [String: String] = [:]          // unsaved buffers
    /// Content each edit buffer diverged from, captured at first edit and
    /// never updated by the watcher — the base any save is verified against.
    private var editBases: [String: DiskState] = [:]
    private(set) var dirtyPaths: Set<String> = []
    private(set) var conflicts: Set<String> = []            // dirty buffer + disk changed
    private(set) var externalChanges: [String: ExternalChange] = [:]
    private(set) var excludedHistoryPaths = Set(AppSettings.defaults.stringArray(forKey: "excludedHistoryPaths") ?? [])
    /// Security-audit `LintRule` ids silenced per file (`FileIssuesButton`).
    /// Persisted as `[path: [ruleID]]` — a rule's core diagnostics (parse
    /// errors, unknown keys, …) never end up here since they have no `ruleID`.
    private(set) var mutedLintRules: [String: Set<String>] =
        (AppSettings.defaults.dictionary(forKey: "mutedLintRules") as? [String: [String]] ?? [:])
            .mapValues(Set.init)
    private(set) var histories: [String: [FileVersion]] = [:]
    private(set) var saveErrors: [String: String] = [:]
    /// History paths whose index is corrupt or ambiguous (never overwritten).
    private(set) var historyErrors: [String: String] = [:]
    /// Visible failure of the last MCP copy or similar action.
    private(set) var actionError: String?
    /// A restore/revert action awaiting explicit user confirmation.
    /// Set by every restore entry point (history, context menu, inspector,
    /// external-change banner); the single dialog in ContentView acts on it.
    var pendingRestore: RestoreRequest?
    /// History paths whose legacy permissions could not be tightened.
    private(set) var permissionWarnings: [String] = []
    private(set) var lastEventAt: Date?
    private(set) var watchedCount = 0
    private(set) var activity: [ActivityEvent] = []
    private(set) var mcpIndex: [McpServerEntry] = []
    /// Registered project/repository roots inspected for local config,
    /// in addition to the global (home-rooted) agents.
    private(set) var projectRoots: [String] = AppSettings.defaults.stringArray(forKey: "projectRoots") ?? []
    private(set) var projectDiscoveryNotices: [String: [SubmoduleDiscovery.Notice]] = [:]
    private var projectScanDirectories: Set<String> = []
    var selectedEventID: UUID?
    var selectedMcpName: String?
    var mcpProjectFilter = "__all__"
    var mcpProfileFilter = ""
    var comparedMcpSources: [McpComparedSource] {
        McpComparison.sources(mcpIndex, project: mcpProjectFilter == "__all__" ? nil : mcpProjectFilter, profile: mcpProfileFilter)
    }
    var contextualMcpIndex: [McpServerEntry] {
        comparedMcpSources.filter { $0.state != "Outside context" }.map(\.entry)
    }
    var mcpContextPaths: [String] { Array(Set(projectRoots + mcpIndex.compactMap(\.projectPath))).sorted() }

    var requestedTab: EditorTab?
    var findRequest = 0
    var showInspector = false

    /// Session disclosure state for skill origin/owner groups, shared by the
    /// file list and Configuration → Skills so toggles survive switching
    /// agents or leaving Files. Session-only: never persisted.
    var skillExpansion = SkillGroupExpansion()

    /// Reassigns `skillExpansion` so `@Observable` publishes the change —
    /// `SkillGroupExpansion` is a value type with mutating setters.
    func setSkillExpanded(_ origin: SkillOrigin, _ value: Bool) {
        var expansion = skillExpansion
        expansion.set(origin, value)
        skillExpansion = expansion
    }
    func setSkillExpanded(_ origin: SkillOrigin, owner: String, _ value: Bool) {
        var expansion = skillExpansion
        expansion.set(origin, owner: owner, value)
        skillExpansion = expansion
    }

    static let activityID = "__activity__"
    static let mcpID = "__mcp__"
    static let settingsID = "__settings__"
    static let analysisID = "__analysis__"
    static let searchID = "__search__"
    private(set) var analysisRevision = 0

    // MARK: internals
    private var snapshots: SnapshotStore
    private let notifier: Notifier?
    private var selfWriteHashes: [String: String] = [:]
    private var fileOwners: [String: String] = [:]          // path → agentID
    private var dirOwners: [String: String] = [:]           // dir path → agentID
    private var fileSource: [String: ConfigSource] = [:]    // file path → source spec
    private let largeWorker = LargeFileWorker()
    private(set) var loadingPaths: Set<String> = []
    private(set) var savingPaths: Set<String> = []
    @ObservationIgnored private var largeLoads: [String: Task<Void, Never>] = [:]
    private var loadTokens: [String: UUID] = [:]
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    private var reviewToken: UUID?
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    private var definitions: [String: AgentDefinition] = [:]
    /// Ids in `definitions` synthesized for project-local agents — rebuilt
    /// on every `refresh()` so removed/renamed projects don't leave stale
    /// entries behind.
    private var projectDefinitionIDs: Set<String> = []

    @ObservationIgnored private let watcher = FileWatcher(onChange: { _ in })
    /// Directory trees (project folders, skill/plugin folders) via FSEvents;
    /// `watcher` keeps one vnode source per tracked file.
    @ObservationIgnored private let treeWatcher = TreeWatcher()

    /// `notifier: nil` disables UserNotifications entirely — tests pass nil so
    /// constructing a store never touches the real notification center.
    /// `backgroundScan` (the app) returns before the first scan: the window
    /// appears at once and state is published when the scan lands.
    init(notifier: Notifier? = .shared, backgroundScan: Bool = false) {
        self.notifier = notifier
        var tracked = Set<String>()
        for def in AgentRegistry.definitions {
            for src in def.sources { tracked.insert(src.expandedPath) }
        }
        snapshots = SnapshotStore(isPathTracked: {
            tracked.contains($0) || FileManager.default.fileExists(atPath: $0)
        })
        watcher.onChange = { [weak self] path in
            Task { @MainActor in self?.handleWatchEvent(path) }
        }
        treeWatcher.onEvents = { [weak self] events in
            Task { @MainActor in self?.handleTreeEvents(events) }
        }
        // the real number of attached watchers (missing files don't count)
        watcher.onAttachedCount = { [weak self] n in
            Task { @MainActor in self?.watchedCount = n }
        }
        for def in AgentRegistry.definitions { definitions[def.id] = def }
        notifier?.configure()
        notifier?.onSelect = { [weak self] path in self?.openFile(path) }
        // One-time audit: tighten permissions on history written by older
        // versions; failures surface as warnings (no content is deleted).
        guard backgroundScan else {
            permissionWarnings = snapshots.secureExistingPermissions()
            refresh()
            seedActivity()
            return
        }
        scheduleRefresh()
        let audit = UncheckedSendable(snapshots)
        Task { [weak self] in
            let warnings = await Task.detached(priority: .utility) { audit.value.secureExistingPermissions() }.value
            guard let self else { return }
            self.permissionWarnings = warnings
            await self.waitForRefresh()
            self.seedActivity()
        }
    }

    /// Files that get on-disk history. Volatile state files and sources
    /// flagged `excludeFromHistory` (may hold secrets) are never snapshotted.
    private func keepsHistory(_ tf: TrackedFile?) -> Bool {
        AppSettings.historyEnabled && !(tf?.volatile ?? false) && !(tf?.excludeFromHistory ?? false)
            && !(tf.map { excludedHistoryPaths.contains($0.path) } ?? false)
    }

    /// File-list membership. Missing declared paths stay out of the list
    /// unless the user still has work or an error attached to them.
    func listsFile(_ file: TrackedFile) -> Bool {
        file.appearsInFileList(
            dirty: dirtyPaths.contains(file.path),
            pendingExternal: externalChanges[file.path] != nil,
            hasSaveError: saveErrors[file.path] != nil)
    }

    func historyPolicyAllowsRecording(_ path: String) -> Bool {
        guard let file = trackedFile(for: path) else { return false }
        return !file.volatile && !file.excludeFromHistory
    }

    func setHistoryEnabled(_ enabled: Bool, for path: String) {
        guard historyPolicyAllowsRecording(path) else { return }
        if enabled { excludedHistoryPaths.remove(path) } else { excludedHistoryPaths.insert(path) }
        AppSettings.defaults.set(excludedHistoryPaths.sorted(), forKey: "excludedHistoryPaths")
    }

    /// Silences (or restores) one `LintRule` id for a single file. Persisted
    /// immediately; the file's cached diagnostics are also recomputed so the
    /// UI updates without waiting for the next edit/watch event.
    func setLintRuleMuted(_ muted: Bool, ruleID: String, for path: String) {
        var rules = mutedLintRules[path] ?? []
        if muted { rules.insert(ruleID) } else { rules.remove(ruleID) }
        mutedLintRules[path] = rules.isEmpty ? nil : rules
        AppSettings.defaults.set(mutedLintRules.mapValues { Array($0).sorted() }, forKey: "mutedLintRules")
        guard let doc = documents[path], let tf = trackedFile(for: path) else { return }
        let lint = Linter.lint(path: path, text: doc.text, tree: doc.tree, parseError: doc.parseError,
                               format: tf.format, mutedRuleIDs: mutedLintRules[path] ?? [])
        updateFileMeta(path: path) { f in f.issues = lint.issues }
    }

    struct HistoryRemoval: Identifiable {
        let id = UUID()
        let path: String
        let ids: Set<String>
        let expectedIDs: Set<String>
    }
    private(set) var pendingHistoryRemoval: HistoryRemoval?
    private(set) var historyRemovalErrors: [String: String] = [:]

    func requestHistoryRemoval(path: String, version: FileVersion? = nil) {
        refreshHistory(path: path)
        guard historyErrors[path] == nil else { return }
        let all = Set(history(for: path).map(\.id))
        let ids = version.map { Set([$0.id]) } ?? all
        guard !ids.isEmpty, ids.isSubset(of: all) else { return }
        pendingHistoryRemoval = HistoryRemoval(path: path, ids: ids, expectedIDs: all)
    }

    func cancelHistoryRemoval() { pendingHistoryRemoval = nil }

    func retryHistoryCleanup(path: String) {
        do {
            try snapshots.cleanupOrphans(for: path)
            historyRemovalErrors.removeValue(forKey: path)
        } catch { historyRemovalErrors[path] = error.localizedDescription }
    }

    func confirmHistoryRemoval() {
        guard let request = pendingHistoryRemoval else { return }
        pendingHistoryRemoval = nil
        do {
            try snapshots.removeVersions(for: request.path, ids: request.ids, expectedIDs: request.expectedIDs)
            historyRemovalErrors.removeValue(forKey: request.path)
        } catch { historyRemovalErrors[request.path] = L(error.localizedDescription) }
        refreshHistory(path: request.path)
    }

    /// History reads that surface corrupt/ambiguous indexes instead of
    /// silently treating them as empty.
    private func safeLoadHistory(_ path: String) -> [FileVersion] {
        do {
            let h = try snapshots.loadHistory(for: path)
            historyErrors.removeValue(forKey: path)
            return h
        } catch {
            historyErrors[path] = error.localizedDescription
            return []
        }
    }

    /// Seed the activity feed from persisted snapshot indexes (recent history).
    private func seedActivity() {
        var events: [ActivityEvent] = []
        var seenPaths = Set<String>()
        for agent in agents {
            for f in agent.files where keepsHistory(f) {
                guard seenPaths.insert(f.path).inserted else { continue }
                // The scan just loaded most histories; don't read them again.
                for v in (histories[f.path] ?? safeLoadHistory(f.path)).prefix(15) {
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

    func knowledgeAnalysis(_ context: AnalysisContext, configuration: ConfigurationAnalysis) -> KnowledgeAnalysis {
        KnowledgeInspector.build(context: context, agents: agents, configuration: configuration) { path in
            self.documents[path]?.text ?? (try? Parsers.readText(at: path))
        }
    }

    func searchCatalog(_ query: String) async -> [CatalogSearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var hits: [CatalogSearchHit] = []
        var seen = Set<String>()
        for file in agents.flatMap(\.files) where file.exists && seen.insert(file.path).inserted {
            guard !Task.isCancelled, hits.count < 100 else { break }
            let pathMatch = file.path.localizedCaseInsensitiveContains(query)
            let safe: String
            if let document = documents[file.path], document.text.utf8.count <= Parsers.maximumFileBytes {
                safe = Secrets.maskText(document.text, format: file.format, masking: true)
            } else { safe = "" }
            if let range = safe.range(of: query, options: .caseInsensitive) {
                let start = safe.index(range.lowerBound, offsetBy: -80, limitedBy: safe.startIndex) ?? safe.startIndex
                let end = safe.index(range.upperBound, offsetBy: 120, limitedBy: safe.endIndex) ?? safe.endIndex
                hits.append(.init(path: file.path, excerpt: String(safe[start..<end])))
            } else if pathMatch { hits.append(.init(path: file.path, excerpt: L(file.role.label))) }
            await Task.yield()
        }
        return hits
    }

    var preferredAnalysisProject: String {
        let saved = AppSettings.defaults.string(forKey: "sidebarProject") ?? ""
        return projectRoots.contains(saved) ? saved : projectRoots.first ?? ""
    }
    func projectLabel(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return projectRoots.filter { URL(fileURLWithPath: $0).lastPathComponent == name }.count > 1
            ? name + " — " + path.replacingOccurrences(of: AppPaths.home, with: "~") : name
    }

    func configurationAnalysis(_ context: AnalysisContext) -> ConfigurationAnalysis {
        ConfigurationResolver.analyze(context) { path in
            if let document = self.documents[path] { return document }
            guard let text = try? Parsers.readText(at: path) else { return nil }
            let parsed = Parsers.parse(text, format: AgentRegistry.inferFormat(path: path))
            return ConfigDocument(text: text, tree: parsed.tree, parseError: parsed.error,
                                  loadedAt: Date(), hash: SnapshotStore.sha256(text))
        }
    }

    // MARK: - scanning

    /// Main-actor state a scan depends on, captured so the disk work can run
    /// off the main thread.
    struct ScanInput: Sendable {
        var generation: Int
        var projectRoots: [String]
        var selectedPath: String?
        /// Texts already in `documents`: not re-read, reused for volatile MCP.
        var knownTexts: [String: String]
        /// Histories already in memory are not re-read.
        var knownHistories: Set<String>
        var snapshots: UncheckedSendable<SnapshotStore>
    }

    /// A tracked file read and parsed off the main actor.
    struct PreloadedDocument: @unchecked Sendable {
        var text: String
        var tree: Any?
        var parseError: String?   // unlocalized, as `parseInBackground` returns it
        var hash: String
        /// Loaded under the index lock off the main actor; nil when the
        /// history was already in memory at scan time.
        var history: Result<[FileVersion], HistoryReadError>?
    }

    struct HistoryReadError: Error { var message: String }

    /// Everything `refresh()` learns from disk. Built by `scan(_:)` without
    /// touching store state; `apply(_:)` publishes it on the main actor.
    struct ScanResult: @unchecked Sendable {
        var generation: Int
        var definitions: [String: AgentDefinition] = [:]
        var projectDefinitionIDs: Set<String> = []
        var agents: [Agent] = []
        var projectDiscoveryNotices: [String: [SubmoduleDiscovery.Notice]] = [:]
        var projectScanDirectories: Set<String> = []
        /// Directories of each agent's directory sources, in source order.
        var sourceDirectories: [String: [String]] = [:]
        var preloaded: [String: PreloadedDocument] = [:]
        var readErrors: [String: String] = [:]
        var volatileMcpEntries: [McpServerEntry] = []
        /// Watch plan, computed here so `apply` does no filesystem checks.
        var treeRoots: [String] = []
        var missingSourceDirectories: Set<String> = []
    }

    /// True while a background scan is in flight (drives the sidebar spinner).
    private(set) var isScanning = false
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshQueued = false

    private func scanInput() -> ScanInput {
        refreshGeneration += 1
        return ScanInput(generation: refreshGeneration, projectRoots: projectRoots,
                         selectedPath: selectedPath, knownTexts: documents.mapValues(\.text),
                         knownHistories: Set(histories.keys), snapshots: UncheckedSendable(snapshots))
    }

    /// Synchronous scan: tests and model-level callers rely on the state
    /// being current when it returns. UI and watcher paths use `scheduleRefresh()`.
    func refresh() {
        let result = Self.scan(scanInput())
        measured("apply") { apply(result) }
    }

    private func measured(_ phase: StaticString, _ body: () -> Void) {
        let state = scanSignposts.beginInterval(phase)
        let start = ContinuousClock.now
        body()
        scanSignposts.endInterval(phase, state)
        scanLog.info("\(phase, privacy: .public) \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// Scans on a background thread and publishes on the main actor. Requests
    /// arriving mid-scan coalesce into one follow-up pass; a result is dropped
    /// if a synchronous `refresh()` published newer state meanwhile.
    func scheduleRefresh() {
        guard refreshTask == nil else { refreshQueued = true; return }
        isScanning = true
        refreshTask = Task { [weak self] in
            while let self {
                self.refreshQueued = false
                let input = self.scanInput()
                let result = await Task.detached(priority: .userInitiated) { Self.scan(input) }.value
                if result.generation == self.refreshGeneration { self.measured("apply") { self.apply(result) } }
                guard self.refreshQueued else { break }
            }
            self?.refreshTask = nil
            self?.isScanning = false
        }
    }

    /// Awaits any scheduled scan (test and startup seam).
    func waitForRefresh() async {
        while let task = refreshTask { await task.value }
    }

    nonisolated static func scan(_ input: ScanInput) -> ScanResult {
        let state = scanSignposts.beginInterval("scan")
        let start = ContinuousClock.now
        defer {
            scanSignposts.endInterval("scan", state)
            scanLog.info("scan \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        }
        return DiscoveryTree.withCache {
            var result = ScanResult(generation: input.generation)
            result.definitions = Dictionary(uniqueKeysWithValues: AgentRegistry.definitions.map { ($0.id, $0) })
            result.agents = AgentRegistry.detect()
            for root in input.projectRoots {
                let scan = SubmoduleDiscovery.scan(root: root)
                result.projectDiscoveryNotices[root] = Array(Set(scan.notices)).sorted { ($0.manifest, $0.problem.rawValue) < ($1.manifest, $1.problem.rawValue) }
                result.projectScanDirectories.formUnion(scan.directories)
                var folders: [String: DiscoveryTree.Result] = [:]
                for directory in scan.directories {
                    let tree = DiscoveryTree.projectFolders(root: directory, collectFiles: false)
                    folders[directory] = tree
                    result.projectScanDirectories.formUnion(tree.directories)
                }
                for (def, agent) in AgentRegistry.detectLocal(projectRoot: root, submodules: scan, folders: folders) {
                    result.definitions[agent.id] = def
                    result.projectDefinitionIDs.insert(agent.id)
                    result.agents.append(agent)
                }
            }
            var existingDirectories: [String] = []
            for agent in result.agents {
                guard let def = result.definitions[agent.id] else { continue }
                let directories = def.sources.flatMap(AgentRegistry.watchDirectories(for:))
                result.sourceDirectories[agent.id] = directories
                for directory in directories {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue {
                        existingDirectories.append(directory)
                    } else { result.missingSourceDirectories.insert(directory) }
                }
            }
            result.treeRoots = TreeWatcher.minimalRoots(existingDirectories + Array(result.projectScanDirectories))
            // Preload all tracked files so external changes can be diffed even
            // before the user opens them. Skip anything over ~2MB. The first
            // agent listing a path decides its format, as `format(for:)` does.
            var seen = Set<String>()
            for agent in result.agents {
                for f in agent.files where f.exists && f.size < 2_000_000
                    && input.knownTexts[f.path] == nil && seen.insert(f.path).inserted {
                    do {
                        let text = try Parsers.readText(at: f.path)
                        // Same throttle as handleFileChanged: skip parsing huge
                        // volatile files unless the user is looking at them.
                        let heavyVolatile = f.volatile && text.utf8.count > 300_000 && f.path != input.selectedPath
                        let parsed = heavyVolatile ? (tree: Any?.none, error: String?.none)
                                                   : Parsers.parseInBackground(text, format: f.format)
                        var history: Result<[FileVersion], HistoryReadError>?
                        if !input.knownHistories.contains(f.path) {
                            do { history = .success(try input.snapshots.value.loadHistory(for: f.path)) }
                            catch { history = .failure(HistoryReadError(message: error.localizedDescription)) }
                        }
                        result.preloaded[f.path] = PreloadedDocument(text: text, tree: parsed.tree,
                                                                     parseError: parsed.error, hash: SnapshotStore.sha256(text),
                                                                     history: history)
                    } catch {
                        if FileManager.default.fileExists(atPath: f.path) { result.readErrors[f.path] = error.localizedDescription }
                    }
                }
            }
            // Parse volatile files once per scan so their MCP entries appear in
            // the index (we skip per-event reparsing of these heavy files).
            for agent in result.agents {
                for f in agent.files where f.exists && f.volatile {
                    guard let text = input.knownTexts[f.path] ?? result.preloaded[f.path]?.text
                            ?? (try? Parsers.readText(at: f.path)),
                          text.utf8.count <= Parsers.maximumFileBytes else { continue }
                    let reused = input.knownTexts[f.path] == nil ? result.preloaded[f.path]?.tree : nil
                    guard let tree = (reused ?? Parsers.parseInBackground(text, format: f.format).tree) as? [String: Any]
                    else { continue }
                    result.volatileMcpEntries += mcpEntries(in: tree, agentID: agent.id,
                                                            agentName: agent.name, sourcePath: f.path)
                }
            }
            return result
        }
    }

    private func apply(_ result: ScanResult) {
        analysisRevision += 1
        definitions = result.definitions
        projectDefinitionIDs = result.projectDefinitionIDs
        projectDiscoveryNotices = result.projectDiscoveryNotices
        projectScanDirectories = result.projectScanDirectories
        agents = result.agents
        rebuildFileIndex()
        for index in agents.indices {
            agents[index].files = agents[index].files.map(applyingDocumentDiagnostics)
        }
        fileOwners.removeAll(); dirOwners.removeAll(); fileSource.removeAll()
        // Priority order for the watcher's descriptor budget: tracked files,
        // then source directories. Project folders go to the tree watcher.
        var watchPaths: [String] = []
        var sourceDirectories: [String] = []
        for agent in agents {
            for p in result.sourceDirectories[agent.id] ?? [] {
                dirOwners[p] = agent.id
                sourceDirectories.append(p)
            }
            for f in agent.files {
                registerFilePolicy(f, agentID: agent.id)
                watchPaths.append(f.path)
            }
        }
        watcher.watch(watchPaths + sourceDirectories.filter(result.missingSourceDirectories.contains))
        treeWatcher.watch(result.treeRoots)
        if selectedAgentID == nil { selectedAgentID = agents.first?.id }
        for agent in agents {
            for f in agent.files where f.exists && f.size < 2_000_000 && documents[f.path] == nil {
                if let pre = result.preloaded[f.path] {
                    installDocument(f.path, preloaded: pre)
                } else if let error = result.readErrors[f.path] {
                    saveErrors[f.path] = L(error)
                } else {
                    // Known when the scan started but dropped since.
                    _ = load(f.path)
                }
            }
        }
        volatileMcpEntries = result.volatileMcpEntries
        rebuildMcpIndex()
    }

    // MARK: - Projects (local per-repository config)

    /// Registers a project root for local-config inspection (idempotent) and
    /// rescans. History for its files is content-addressed by absolute path,
    /// so nothing special is needed to start/resume tracking it.
    func addProject(path: String, background: Bool = false) {
        // No `standardizingPath`/realpath normalization: kept exactly as
        // given so it matches the resolved `TrackedFile` paths built from it
        // (which are plain string concatenations, like the global sources).
        guard !projectRoots.contains(path) else { return }
        projectRoots.append(path)
        AppSettings.defaults.set(projectRoots, forKey: "projectRoots")
        if background { scheduleRefresh() } else { refresh() }
    }

    /// Unregisters a project: stops watching/showing it. Its on-disk history
    /// is retained (same policy as elsewhere — purging is always manual) and
    /// resumes automatically if the same root is re-added later.
    func removeProject(path: String, background: Bool = false) {
        guard let idx = projectRoots.firstIndex(of: path) else { return }
        projectRoots.remove(at: idx)
        AppSettings.defaults.set(projectRoots, forKey: "projectRoots")
        guard background else { refresh(); return }
        // Hide it right away; the scan then rebuilds owners and watch lists.
        agents.removeAll { $0.projectRoot == path }
        scheduleRefresh()
    }

    /// Presents a folder picker and registers the chosen directory as a
    /// project, if any.
    func pickAndAddProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Synchronous on purpose: the sidebar selects the new project's
        // first agent right after this returns.
        addProject(path: url.path)
    }

    func setConfigurationRoot(agentID: String, path: String?) {
        guard dirtyPaths.isEmpty, savingPaths.isEmpty else {
            actionError = L("Save or discard drafts before changing configuration roots."); return
        }
        var roots = AppSettings.defaults.dictionary(forKey: "agentConfigRoots") as? [String: String] ?? [:]
        roots[agentID] = path
        AppSettings.defaults.set(roots, forKey: "agentConfigRoots")
        selectedPath = nil
        refresh()
    }

    func pickConfigurationRoot(agentID: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setConfigurationRoot(agentID: agentID, path: url.path)
    }

    // MARK: - MCP index (cross-agent)

    private nonisolated static let mcpContainerKeys = ["mcpServers", "mcp_servers", "mcp", "servers"]

    private var volatileMcpEntries: [McpServerEntry] = []

    func rebuildMcpIndex() {
        var out = volatileMcpEntries
        for agent in agents {
            for f in agent.files where f.exists && !f.volatile {
                guard let tree = documents[f.path]?.tree as? [String: Any] else { continue }
                out += Self.mcpEntries(in: tree, agentID: agent.id,
                                       agentName: agent.name, sourcePath: f.path)
            }
        }
        mcpIndex = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Extract MCP entries from a parsed tree.
    private nonisolated static func mcpEntries(in tree: [String: Any], agentID: String,
                                   agentName: String, sourcePath: String) -> [McpServerEntry] {
        var out: [McpServerEntry] = []
        for key in mcpContainerKeys {
            guard let servers = tree[key] as? [String: Any] else { continue }
            for (name, raw) in servers {
                guard let spec = raw as? [String: Any] else { continue }
                var entry = normalizeMcp(name: name, spec: spec,
                                        agentID: agentID, agentName: agentName,
                                        sourcePath: sourcePath, container: key)
                entry.sourceKeyPath = [key]
                let filename = URL(fileURLWithPath: sourcePath).lastPathComponent
                if agentID == "codex", filename.hasSuffix(".config.toml") {
                    entry.profileName = String(filename.dropLast(".config.toml".count)); entry.scope = "Profile"
                }
                if let separator = agentID.range(of: "::") {
                    entry.projectPath = String(agentID[separator.upperBound...]); entry.scope = "Project"
                } else if sourcePath.contains("/extensions/") || sourcePath.contains("/plugins/") { entry.scope = "Extension" }
                else if sourcePath.hasPrefix(AppPaths.systemPath("/etc/") ) || sourcePath.hasPrefix(AppPaths.systemPath("/Library/")) { entry.scope = "Managed" }
                out.append(entry)
            }
        }
        if agentID == "claude-code", let projects = tree["projects"] as? [String: Any] {
            for (project, value) in projects.sorted(by: { $0.key < $1.key }) {
                guard let record = value as? [String: Any], let servers = record["mcpServers"] as? [String: Any] else { continue }
                for (name, raw) in servers {
                    guard let raw = raw as? [String: Any] else { continue }
                    var entry = normalizeMcp(name: name, spec: raw, agentID: agentID, agentName: agentName,
                                             sourcePath: sourcePath, container: "mcpServers")
                    entry.projectPath = project; entry.scope = "Private project"
                    entry.sourceKeyPath = ["projects", project, "mcpServers"]
                    out.append(entry)
                }
            }
        }
        return out
    }

    /// Re-extract a volatile file's MCP entries after it changed on disk or
    /// was written by us — otherwise the index would keep stale servers until
    /// the next full scan.
    private func refreshVolatileMcp(path: String) {
        guard let tf = trackedFile(for: path), tf.volatile else { return }
        volatileMcpEntries.removeAll { $0.sourcePath == path }
        guard let text = documents[path]?.text,
              let tree = Parsers.parse(text, format: tf.format).tree as? [String: Any],
              let agent = agents.first(where: { $0.id == fileOwners[path] })
        else { return }
        volatileMcpEntries += Self.mcpEntries(in: tree, agentID: agent.id,
                                              agentName: agent.name,
                                              sourcePath: path)
    }

    private nonisolated static func normalizeMcp(name: String, spec: [String: Any],
                                     agentID: String, agentName: String,
                                     sourcePath: String, container: String) -> McpServerEntry {
        var command: String? = spec["command"] as? String
        var args = (spec["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let arr = spec["command"] as? [Any] {   // opencode local: command is an array
            command = arr.first as? String
            args += arr.dropFirst().compactMap { $0 as? String }
        }
        let url = spec["url"] as? String ?? spec["serverUrl"] as? String ?? spec["httpUrl"] as? String
        let env = (spec["env"] ?? spec["environment"]) as? [String: Any]
        var enabled = spec["enabled"] as? Bool
        if enabled == nil, let d = spec["disabled"] as? Bool { enabled = !d }
        let transport = spec["transport"] as? String ?? spec["type"] as? String
        let isRemote = url != nil || transport == "sse" || transport == "http"
            || transport == "remote" || transport == "streamable_http"
        return McpServerEntry(
            name: name, agentID: agentID, agentName: agentName,
            sourcePath: sourcePath, containerKey: container,
            isRemote: isRemote, command: command, args: args, url: url,
            envKeys: env?.keys.sorted() ?? [], enabled: enabled, raw: spec
        )
    }

    var mcpNames: [String] {
        Array(Set(mcpIndex.map(\.name))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func mcpEntries(for name: String) -> [McpServerEntry] {
        mcpIndex.filter { $0.name == name }
    }

    /// Known user-scope destinations, independent of existing MCP entries.
    /// Multiple existing files require an explicit selection instead of guessing
    /// precedence. If none exists, offer only the declared default path.
    func mcpTargetFiles(for agentID: String) -> [TrackedFile] {
        guard let agent = agents.first(where: { $0.id == agentID }),
              let definition = definitions[agentID] else { return [] }
        let paths = definition.mcpDestinationPaths.map(AppPaths.expand)
        let candidates = paths.compactMap { path in agent.files.first { $0.path == path && !$0.readOnly } }
        let existing = candidates.filter { $0.exists }
        let selected = existing.isEmpty ? Array(candidates.prefix(1)) : existing
        return selected.filter { !usesBackgroundProcessing($0.path) }
    }

    func mcpTargetFile(for agentID: String) -> TrackedFile? {
        let candidates = mcpTargetFiles(for: agentID)
        return candidates.count == 1 ? candidates.first : nil
    }

    func isMcpDestination(_ path: String) -> Bool {
        guard let agentID = fileOwners[path], !isReadOnly(path), !usesBackgroundProcessing(path) else { return false }
        return definitions[agentID]?.mcpDestinationPaths.map(AppPaths.expand).contains(path) == true
    }

    struct McpReview: Identifiable {
        let id = UUID()
        let path: String
        let agentID: String
        let name: String
        let originalText: String
        let proposedText: String
        let format: ConfigFormat
        let replacesExisting: Bool
        let warnings: [String]
    }
    private(set) var pendingMcpReview: McpReview?
    private var mcpReviewDisk: DiskState?

    /// Stages an operation. Neither the disk nor the edit buffer changes until
    /// the user approves the concrete diff in McpReviewSheet.
    @discardableResult
    func copyMcpServer(_ entry: McpServerEntry, to agentID: String, targetPath: String? = nil) -> Bool {
        actionError = nil
        let selectedTarget = targetPath.flatMap { path in mcpTargetFiles(for: agentID).first { $0.path == path } }
            ?? (targetPath == nil ? mcpTargetFile(for: agentID) : nil)
        guard let target = selectedTarget,
              let sourceDialect = McpAdapter.dialect(agentID: entry.agentID, path: entry.sourcePath),
              let targetDialect = McpAdapter.dialect(agentID: agentID, path: target.path) else {
            actionError = L("No supported MCP source or destination for this operation.")
            return false
        }
        do {
            let converted = try McpAdapter.convert(entry.raw, from: sourceDialect, to: targetDialect)
            return try prepareMcpReview(path: target.path, agentID: agentID,
                name: entry.name, spec: converted.spec, warnings: converted.warnings)
        } catch { actionError = error.localizedDescription; return false }
    }

    @discardableResult
    func addMcpServer(path: String, name: String, transport: McpAdapter.Transport,
                      command: String, args: [String], url: String) -> Bool {
        actionError = nil
        guard isMcpDestination(path), let agentID = fileOwners[path],
              let dialect = McpAdapter.dialect(agentID: agentID, path: path) else {
            actionError = L("This file has no supported MCP adapter.")
            return false
        }
        do {
            let spec = try McpAdapter.makeSpec(dialect: dialect, transport: transport,
                                             command: command, args: args, url: url)
            return try prepareMcpReview(path: path, agentID: agentID, name: name,
                                        spec: spec, warnings: [])
        } catch { actionError = error.localizedDescription; return false }
    }

    private func prepareMcpReview(path: String, agentID: String, name: String,
                                  spec: [String: Any], warnings: [String]) throws -> Bool {
        pendingMcpReview = nil
        mcpReviewDisk = nil
        guard isMcpDestination(path), let target = trackedFile(for: path), !target.readOnly,
              let dialect = McpAdapter.dialect(agentID: agentID, path: path) else {
            throw McpAdapter.Failure(message: L("Read-only file"))
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw McpAdapter.Failure(message: L("An MCP server name is required."))
        }
        let disk = readDiskState(path)
        guard disk != .unreadable else { throw McpAdapter.Failure(message: L("Could not read the current file")) }
        let original = edits[path] ?? disk.text ?? ""
        let root: [String: Any]
        if disk == .missing && edits[path] == nil { root = [:] }
        else {
            guard let parsed = Parsers.parse(original, format: target.format).tree as? [String: Any] else {
                throw McpAdapter.Failure(message: L("The destination must contain a valid configuration object."))
            }
            root = parsed
        }
        let container = dialect.container
        guard root[container] == nil || root[container] is [String: Any] else {
            throw McpAdapter.Failure(message: L("The MCP container must be an object."))
        }
        var servers = root[container] as? [String: Any] ?? [:]
        let replacing = servers[name] != nil
        servers[name] = spec
        var proposedRoot = root
        proposedRoot[container] = servers
        let proposed: String
        var notices = warnings
        if target.format == .toml {
            proposed = try Parsers.updatingTOMLMcp(original, container: container, name: name, spec: spec)
            notices.append(L("TOML comments and formatting will be normalized. Unrelated values keep their TOML types."))
        } else {
            guard let serialized = Parsers.serializeJSON(proposedRoot) else {
                throw McpAdapter.Failure(message: L("Cannot serialize %@", URL(fileURLWithPath: path).lastPathComponent))
            }
            proposed = serialized
            if target.format == .jsonc { notices.append(L("JSONC comments and formatting will be normalized.")) }
        }
        if !keepsHistory(target) {
            notices.append(L("History is disabled for this destination; saving will not create a backup."))
        }
        // Refresh an unedited document to the exact state used by this review.
        if edits[path] == nil {
            if let text = disk.text { installDocument(path, text: text) }
            else { documents.removeValue(forKey: path) }
        }
        pendingMcpReview = McpReview(path: path, agentID: agentID, name: name,
            originalText: original, proposedText: proposed, format: target.format,
            replacesExisting: replacing, warnings: notices)
        mcpReviewDisk = disk
        return true
    }

    func cancelMcpReview() { pendingMcpReview = nil; mcpReviewDisk = nil }

    @discardableResult
    func confirmMcpReview() -> Bool {
        guard let review = pendingMcpReview, let disk = mcpReviewDisk else { return false }
        guard !isReadOnly(review.path), text(for: review.path) == review.originalText,
              readDiskState(review.path) == disk else {
            actionError = L("The destination changed during review. Review the operation again.")
            cancelMcpReview()
            return false
        }
        updateEdit(path: review.path, text: review.proposedText)
        selectedAgentID = review.agentID
        selectedPath = review.path
        requestedTab = .structured
        cancelMcpReview()
        return true
    }

    func clearActionError() { actionError = nil }

    /// Re-resolve one agent's file list (called when a watched dir changes).
    /// Uses the existing agent's `name`/`projectRoot` rather than `def`'s,
    /// since a project-local agent's display name (with its folder suffix)
    /// and `projectRoot` only live on the resolved `Agent`, not on the
    /// synthetic `AgentDefinition` registered for it.
    private func rescan(agentID: String) {
        guard let def = definitions[agentID],
              let idx = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let oldPaths = Set(agents[idx].files.map(\.path))
        let updated = Agent(
            id: def.id, name: agents[idx].name, symbol: def.symbol, color: def.color,
            files: AgentRegistry.resolveFiles(def).map(applyingDocumentDiagnostics), detectionPath: agents[idx].detectionPath,
            notes: def.notes, projectRoot: agents[idx].projectRoot, submodulePath: agents[idx].submodulePath
        )
        agents[idx] = updated
        for f in updated.files where !oldPaths.contains(f.path) {
            fileOwners[f.path] = agentID
        }
        refreshWatchList()
    }

    /// Rebuilding the catalog must not erase diagnostics for cached documents.
    private func applyingDocumentDiagnostics(_ file: TrackedFile) -> TrackedFile {
        guard file.exists, let doc = documents[file.path] else { return file }
        var result = file
        let lint = Linter.lint(path: file.path, text: doc.text, tree: doc.tree,
                               parseError: doc.parseError, format: file.format,
                               mutedRuleIDs: mutedLintRules[file.path] ?? [])
        result.issues = lint.issues
        result.managedBlocks = lint.managed
        return result
    }

    private func registerFilePolicy(_ file: TrackedFile, agentID: String) {
        var source = ConfigSource(path: file.path, format: file.format, role: file.role,
            volatile: file.volatile, excludeFromHistory: file.excludeFromHistory, readOnly: file.readOnly, note: file.note)
        if let previous = fileSource[file.path] {
            let protected = previous.role == .state || file.role == .state ||
                previous.note?.hasPrefix("Managed system source") == true || file.note?.hasPrefix("Managed system source") == true
            source.readOnly = protected ? (previous.readOnly || file.readOnly) : previous.readOnly && file.readOnly
            source.volatile = previous.volatile || file.volatile
            source.excludeFromHistory = previous.excludeFromHistory || file.excludeFromHistory
            if previous.readOnly && !file.readOnly && !protected { fileOwners[file.path] = agentID }
        } else { fileOwners[file.path] = agentID }
        fileSource[file.path] = source
    }

    private func refreshWatchList() {
        dirOwners.removeAll(); fileOwners.removeAll(); fileSource.removeAll()
        for agent in agents {
            for source in definitions[agent.id]?.sources ?? [] {
                for path in AgentRegistry.watchDirectories(for: source) { dirOwners[path] = agent.id }
            }
        }
        var files: [String] = []
        for agent in agents {
            files.append(contentsOf: agent.files.map(\.path))
            for f in agent.files {
                registerFilePolicy(f, agentID: agent.id)
            }
        }
        applyWatchLists(files: files, directories: Array(dirOwners.keys))
        rebuildMcpIndex()
    }

    /// Tracked files get vnode sources (listed first: they matter most under
    /// the descriptor budget). Existing directories are covered by one
    /// FSEvents stream; a directory that does not exist yet stays on the
    /// vnode watcher, whose retry picks up its creation without holding an fd.
    private func applyWatchLists(files: [String], directories: [String]) {
        var existing: [String] = []
        var missing: [String] = []
        for directory in directories {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue {
                existing.append(directory)
            } else { missing.append(directory) }
        }
        watcher.watch(files + missing)
        treeWatcher.watch(TreeWatcher.minimalRoots(existing + Array(projectScanDirectories)))
    }

    /// First path components of every project-local source (`.claude`,
    /// `AGENTS.md`, `.mcp.json`…) plus `.gitmodules`: the only entry names
    /// whose appearance inside a project folder can change discovery.
    private static let projectMarkerNames: Set<String> = {
        var names: Set<String> = [".gitmodules"]
        for def in AgentRegistry.definitions {
            for source in def.localSources {
                if let first = source.path.split(separator: "/").first { names.insert(String(first)) }
            }
        }
        return names
    }()

    /// FSEvents batch → the same reactions vnode directory events had, but
    /// only for structural changes that matter: a project rescan when its
    /// folder structure or a config marker changes (edits, builds and
    /// dependency folders no longer trigger one), a per-agent rescan when a
    /// watched source directory gains or loses entries.
    func handleTreeEvents(_ events: [TreeWatcher.Event]) {
        var projectChanged = false
        var sourceDirectories: [String] = []
        for event in events {
            if event.mustRescan { projectChanged = true; break }
            guard event.structural else { continue }
            let parent = (event.path as NSString).deletingLastPathComponent
            for directory in [event.path, parent] where dirOwners[directory] != nil && !sourceDirectories.contains(directory) {
                sourceDirectories.append(directory)
            }
            if projectScanDirectories.contains(event.path) { projectChanged = true; continue }
            // Walk up to the nearest scanned folder: a new subfolder there, or
            // anything under a marker entry (e.g. `.claude/settings.json`
            // inside an already existing, unscanned `.claude`), counts.
            var child = event.path, directory = parent
            for depth in 0..<4 {
                if projectScanDirectories.contains(directory) {
                    let name = (child as NSString).lastPathComponent
                    // A new folder counts unless discovery skips it anyway
                    // (node_modules, build, .git…); config markers always count.
                    if (depth == 0 && event.isDirectory && !DiscoveryTree.projectSkipNames.contains(name))
                        || Self.projectMarkerNames.contains(name) { projectChanged = true }
                    break
                }
                child = directory
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        guard projectChanged || !sourceDirectories.isEmpty else { return }
        lastEventAt = Date()
        if projectChanged { scheduleRefresh(); return }
        for directory in sourceDirectories { handleWatchEvent(directory) }
    }

    func usesBackgroundProcessing(_ path: String) -> Bool {
        (trackedFile(for: path)?.size ?? 0) > Int64(Parsers.maximumFileBytes)
            || (documents[path]?.text.utf8.count ?? 0) > Parsers.maximumFileBytes
            || (edits[path]?.utf8.count ?? 0) > Parsers.maximumFileBytes
    }

    private func backgroundHistory(_ path: String, minimum: Int = 1) -> LargeFileWorker.HistoryPolicy {
        let boundary = AppPaths.applicationSupport
        return .init(root: boundary.appendingPathComponent("AgentsConfig/History"), boundary: boundary,
                     enabled: keepsHistory(trackedFile(for: path)), limit: max(minimum, AppSettings.historyLimit))
    }

    func loadLargeFile(_ path: String) {
        guard !savingPaths.contains(path) else { return }
        largeLoads[path]?.cancel()
        let token = UUID()
        loadTokens[path] = token
        loadingPaths.insert(path)
        let format = format(for: path)
        let previous = documents[path]
        let policy = backgroundHistory(path)
        let worker = largeWorker
        largeLoads[path] = Task { [weak self] in
            do {
                let loaded = try await worker.load(path, format: format, previousHash: previous?.hash, history: policy)
                guard !Task.isCancelled, let self, self.loadTokens[path] == token else { return }
                if let previous, previous.hash != loaded.hash {
                    if self.dirtyPaths.contains(path) { self.flagConflict(path: path, disk: .content(loaded.text)) }
                    else {
                        self.externalChanges[path] = ExternalChange(changes: [], previousContent: previous.text,
                                                                   diskContent: loaded.text)
                    }
                }
                self.installLargeResult(path, loaded)
            } catch {
                guard !Task.isCancelled, let self, self.loadTokens[path] == token else { return }
                self.saveErrors[path] = error.localizedDescription
            }
            guard let self, self.loadTokens[path] == token else { return }
            self.loadingPaths.remove(path)
            self.largeLoads.removeValue(forKey: path)
        }
    }

    private func installLargeResult(_ path: String, _ result: LargeFileWorker.Loaded) {
        updateFileMeta(path: path) { $0.exists = true; $0.size = Int64(result.text.utf8.count) }
        if result.text.utf8.count <= Parsers.maximumFileBytes { installDocument(path, text: result.text) }
        else {
            documents[path] = ConfigDocument(text: result.text, tree: nil, parseError: Parsers.localizedError(result.parseError),
                                            loadedAt: Date(), hash: result.hash)
        }
        saveErrors.removeValue(forKey: path)
        if keepsHistory(trackedFile(for: path)) { histories[path] = safeLoadHistory(path) }
        if let error = result.historyError { historyErrors[path] = error }
        volatileMcpEntries.removeAll { $0.sourcePath == path }
        if result.text.utf8.count <= Parsers.maximumFileBytes { refreshVolatileMcp(path: path) }
        rebuildMcpIndex()
    }

    func waitForBackgroundWork(path: String) async {
        await largeLoads[path]?.value
        await reviewTask?.value
        await restoreTask?.value
        await saveTasks[path]?.value
        await largeLoads[path]?.value
    }

    // MARK: - documents

    func document(for path: String) -> ConfigDocument? {
        if documents[path] == nil {
            if usesBackgroundProcessing(path) {
                if !loadingPaths.contains(path), saveErrors[path] == nil { loadLargeFile(path) }
            } else { load(path) }
        }
        return documents[path]
    }

    func text(for path: String) -> String {
        edits[path] ?? documents[path]?.text ?? ""
    }

    private func trackedFile(for path: String) -> TrackedFile? {
        fileLocation(path).map { agents[$0.agent].files[$0.file] }
    }

    /// First (agent, file) position of each tracked path. Validated on every
    /// lookup and rebuilt when `agents` changed shape, so it never returns a
    /// stale entry; turns per-file lookups during preload from O(n) into O(1).
    @ObservationIgnored private var fileIndex: [String: (agent: Int, file: Int)] = [:]

    private func rebuildFileIndex() {
        fileIndex.removeAll(keepingCapacity: true)
        for (ai, agent) in agents.enumerated() {
            for (fi, file) in agent.files.enumerated() where fileIndex[file.path] == nil {
                fileIndex[file.path] = (ai, fi)
            }
        }
    }

    private func fileLocation(_ path: String) -> (agent: Int, file: Int)? {
        func valid(_ l: (agent: Int, file: Int)) -> Bool {
            agents.indices.contains(l.agent) && agents[l.agent].files.indices.contains(l.file)
                && agents[l.agent].files[l.file].path == path
        }
        if let l = fileIndex[path], valid(l) { return l }
        rebuildFileIndex()
        if let l = fileIndex[path], valid(l) { return l }
        return nil
    }

    func format(for path: String) -> ConfigFormat {
        trackedFile(for: path)?.format ?? AgentRegistry.inferFormat(path: path)
    }

    @discardableResult
    private func load(_ path: String) -> ConfigDocument? {
        do {
            let text = try Parsers.readText(at: path)
            return installDocument(path, text: text)
        } catch {
            if FileManager.default.fileExists(atPath: path) { saveErrors[path] = L(error.localizedDescription) }
            return nil
        }
    }

    @discardableResult
    private func installDocument(_ path: String, text: String) -> ConfigDocument {
        let format = format(for: path)
        // Same throttle as handleFileChanged: skip parsing huge volatile files
        // unless the user is actually looking at them.
        let heavyVolatile = (trackedFile(for: path)?.volatile ?? false)
            && text.utf8.count > 300_000 && path != selectedPath
        let parsed = heavyVolatile ? (tree: Any?.none, error: String?.none)
                                   : Parsers.parse(text, format: format)
        return installParsed(path, text: text, tree: parsed.tree, parseError: parsed.error,
                             hash: SnapshotStore.sha256(text), format: format)
    }

    /// Installs a document read and parsed by a background scan; only the
    /// error localization, lint and history bookkeeping run here.
    @discardableResult
    private func installDocument(_ path: String, preloaded: PreloadedDocument) -> ConfigDocument {
        if histories[path] == nil, let history = preloaded.history {
            switch history {
            case .success(let versions): histories[path] = versions; historyErrors.removeValue(forKey: path)
            case .failure(let error): histories[path] = []; historyErrors[path] = error.message
            }
        }
        return installParsed(path, text: preloaded.text, tree: preloaded.tree,
                      parseError: Parsers.localizedError(preloaded.parseError),
                      hash: preloaded.hash, format: format(for: path))
    }

    private func installParsed(_ path: String, text: String, tree: Any?, parseError: String?,
                               hash: String, format: ConfigFormat) -> ConfigDocument {
        let doc = ConfigDocument(
            text: text, tree: tree, parseError: parseError,
            loadedAt: Date(), hash: hash
        )
        documents[path] = doc
        analysisRevision += 1

        // lint + managed blocks onto the TrackedFile
        let lint = Linter.lint(path: path, text: text, tree: tree,
                               parseError: parseError, format: format,
                               mutedRuleIDs: mutedLintRules[path] ?? [])
        updateFileMeta(path: path) { f in
            f.issues = lint.issues
            f.managedBlocks = lint.managed
        }
        if histories[path] == nil { histories[path] = safeLoadHistory(path) }

        // baseline snapshot for files that have none yet (skip volatile/excluded)
        if let tf = trackedFile(for: path), keepsHistory(tf),
           historyErrors[path] == nil, (histories[path]?.isEmpty ?? true) {
            do {
                try recordSnapshot(path: path, content: text, origin: .baseline, changes: [])
            } catch {
                historyErrors[path] = error.localizedDescription
            }
        }
        return doc
    }

    private func recordSnapshot(path: String, content: String, origin: FileVersion.Origin,
                                changes: [SemanticChange]) throws {
        _ = try snapshots.record(path: path, content: content, origin: origin, changes: changes)
        histories[path] = try snapshots.loadHistory(for: path)
        historyErrors.removeValue(forKey: path)
    }

    private func updateFileMeta(path: String, _ mutate: (inout TrackedFile) -> Void) {
        guard let l = fileLocation(path) else { return }
        mutate(&agents[l.agent].files[l.file])
    }

    // MARK: - editing

    func updateEdit(path: String, text: String) {
        guard !savingPaths.contains(path), !loadingPaths.contains(path) else { return }
        if edits[path] == nil {
            // capture the base this buffer diverges from, once — the watcher
            // must not silently rebase an in-flight edit
            editBases[path] = documents[path].map { .content($0.text) }
                ?? readDiskState(path)
        }
        edits[path] = text
        if let doc = documents[path], doc.text == text {
            dirtyPaths.remove(path)
        } else {
            dirtyPaths.insert(path)
        }
    }

    func discardEdit(path: String) {
        guard !savingPaths.contains(path) else { return }
        edits.removeValue(forKey: path)
        editBases.removeValue(forKey: path)
        dirtyPaths.remove(path)
        conflicts.remove(path)
        externalChanges.removeValue(forKey: path)
    }

    var selectedFormat: ConfigFormat {
        guard let p = selectedPath else { return .text }
        return format(for: p)
    }

    var canSaveSelected: Bool {
        guard let p = selectedPath else { return false }
        return dirtyPaths.contains(p) && !savingPaths.contains(p)
    }

    func saveSelected() {
        guard let p = selectedPath else { return }
        requestSave(path: p)
    }

    struct SaveReview: Identifiable {
        let id = UUID()
        let path: String
        let original: String
        let proposed: String
        let format: ConfigFormat
        let overwritesConflict: Bool
        let historyEnabled: Bool
    }
    private(set) var pendingSaveReview: SaveReview?
    private(set) var preparingSavePath: String?
    private var saveReviewDisk: DiskState?

    /// UI entry point: capture a concrete, redacted preview before committing.
    func requestSave(path: String, overwrite: Bool = false) {
        cancelSaveReview()
        guard let proposed = edits[path], let file = trackedFile(for: path) else { return }
        guard !isReadOnly(path), !savingPaths.contains(path) else { saveErrors[path] = L("Read-only file"); return }
        if usesBackgroundProcessing(path) { requestLargeSave(path: path, proposed: proposed, overwrite: overwrite); return }
        if let error = Parsers.parse(proposed, format: file.format).error {
            saveErrors[path] = error; return
        }
        let disk = readDiskState(path)
        guard disk != .unreadable else { saveErrors[path] = L("Could not read the current file"); return }
        let expected: DiskState?
        if overwrite {
            guard let change = externalChanges[path], conflicts.contains(path) else { return }
            expected = change.isDeletion ? .missing : change.diskContent.map { .content($0) }
        } else { expected = baseFor(path) ?? .missing }
        guard disk == expected else { flagConflict(path: path, disk: disk); return }
        saveErrors.removeValue(forKey: path)
        pendingSaveReview = SaveReview(path: path, original: disk.text ?? "", proposed: proposed,
            format: file.format, overwritesConflict: overwrite, historyEnabled: keepsHistory(file))
        saveReviewDisk = disk
    }

    func cancelSaveReview() {
        pendingSaveReview = nil; saveReviewDisk = nil; preparingSavePath = nil
        reviewTask?.cancel(); reviewTask = nil; reviewToken = nil
    }

    func confirmSaveReview() {
        guard let review = pendingSaveReview, let disk = saveReviewDisk else { return }
        cancelSaveReview()
        guard edits[review.path] == review.proposed,
              keepsHistory(trackedFile(for: review.path)) == review.historyEnabled else {
            saveErrors[review.path] = L("The buffer or history setting changed. Review the save again.")
            return
        }
        if usesBackgroundProcessing(review.path) {
            commitLargeSave(review, disk: disk)
            return
        }
        // commitWrite rechecks this exact disk state, including deletions.
        attemptSave(path: review.path, mode: .force(expected: disk))
    }

    private func requestLargeSave(path: String, proposed: String, overwrite: Bool) {
        let token = UUID()
        reviewToken = token
        preparingSavePath = path
        let format = format(for: path)
        let base = baseFor(path) ?? .missing
        let change = externalChanges[path]
        let expected = overwrite ? (change?.isDeletion == true ? DiskState.missing : change?.diskContent.map { .content($0) }) : base
        let historyEnabled = keepsHistory(trackedFile(for: path))
        let worker = largeWorker
        reviewTask = Task { [weak self] in
            defer { if self?.reviewToken == token { self?.preparingSavePath = nil } }
            do {
                if let error = try await worker.validate(proposed, format: format) {
                    guard let self, self.reviewToken == token else { return }
                    self.saveErrors[path] = Parsers.localizedError(error); return
                }
                let state = try await worker.disk(path)
                guard !Task.isCancelled, let self, self.reviewToken == token, self.edits[path] == proposed else { return }
                let disk: DiskState = switch state { case .missing: .missing; case .content(let text): .content(text) }
                guard disk == expected else { self.flagConflict(path: path, disk: disk); return }
                self.saveErrors.removeValue(forKey: path)
                self.pendingSaveReview = SaveReview(path: path, original: disk.text ?? "", proposed: proposed,
                    format: format, overwritesConflict: overwrite, historyEnabled: historyEnabled)
                self.saveReviewDisk = disk
            } catch {
                guard !Task.isCancelled, let self, self.reviewToken == token else { return }
                self.saveErrors[path] = error.localizedDescription
            }
        }
    }

    private func commitLargeSave(_ review: SaveReview, disk: DiskState,
                                 origin: FileVersion.Origin = .app, draft: String? = nil) {
        guard !isReadOnly(review.path), !savingPaths.contains(review.path) else { return }
        let expected: LargeFileWorker.Disk
        switch disk {
        case .missing: expected = .missing
        case .content(let text): expected = .content(text)
        case .unreadable: saveErrors[review.path] = L("Could not read the current file"); return
        }
        let path = review.path
        largeLoads[path]?.cancel()
        loadTokens.removeValue(forKey: path)
        loadingPaths.remove(path)
        savingPaths.insert(path)
        let policy = backgroundHistory(path, minimum: draft == nil ? 2 : 3)
        let worker = largeWorker
        saveTasks[path] = Task { [weak self] in
            let result = await worker.save(path, proposed: review.proposed, format: review.format, expected: expected, history: policy, origin: origin, draft: draft)
            guard let self else { return }
            self.savingPaths.remove(path)
            switch result {
            case .saved(let loaded):
                self.discardEdit(path: path)
                self.selfWriteHashes[path] = loaded.hash
                self.installLargeResult(path, loaded)
                self.logActivity(path: path, origin: origin, changes: [])
                self.loadLargeFile(path) // detect writes that arrived while the UI was saving
            case .conflict(let state):
                self.flagConflict(path: path, disk: state == .missing ? .missing : {
                    if case .content(let text) = state { return DiskState.content(text) }; return .unreadable
                }())
            case .failed(let error): self.saveErrors[path] = Parsers.localizedError(error)
            }
            self.saveTasks.removeValue(forKey: path)
        }
    }

    /// Commit primitive for model tests. App controls call requestSave instead.
    func save(path: String) {
        attemptSave(path: path, mode: .guarded)
    }

    /// What is actually on disk right now.
    private enum DiskState: Equatable {
        case missing, unreadable, content(String)
        var text: String? {
            if case .content(let s) = self { return s }
            return nil
        }
    }

    /// `.guarded` — write only if the live disk state still equals the base
    /// the buffer diverged from. `.force(expected:)` — the user explicitly
    /// confirmed overwriting a *specific* disk state; a nil expectation
    /// overwrites unconditionally (e.g. a file that never existed).
    private enum WriteMode {
        case guarded
        case force(expected: DiskState?)
    }

    private enum CommitOutcome {
        case written
        case conflict(DiskState)
        case failed(String)
    }

    private func readDiskState(_ path: String) -> DiskState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard !isDirectory.boolValue, let text = try? Parsers.readText(at: path) else { return .unreadable }
        return .content(text)
    }

    /// The base a write is verified against: the buffer's own base when one
    /// exists, else the last document read from disk.
    private func baseFor(_ path: String) -> DiskState? {
        editBases[path] ?? documents[path].map { .content($0.text) }
    }

    /// The single write path for save / restore / revert:
    /// verify the live disk state, back up the content actually found on
    /// disk, atomically replace it, then update in-memory state + history.
    ///
    /// This is *not* a compare-and-swap: a non-cooperative writer landing
    /// between the check and `rename` can still be lost. The window is one
    /// short synchronous stretch; the backup cannot recover a later external write.
    private func commitWrite(path: String, text: String, tf: TrackedFile,
                             origin: FileVersion.Origin, mode: WriteMode,
                             postRecord: Bool) -> CommitOutcome {
        let disk = readDiskState(path)
        let base = baseFor(path)

        switch mode {
        case .guarded:
            if case .unreadable = disk {
                return .failed(L("Could not read the current file"))
            }
            let inSync = base.map { disk == $0 } ?? (disk == .missing)
            guard inSync else { return .conflict(disk) }
        case .force(let expected):
            if case .unreadable = disk {
                return .failed(L("Could not read the current file"))
            }
            if let expected, disk != expected { return .conflict(disk) }
        }

        // Back up the content really found on disk before replacing it;
        // if the required backup fails, abort — never write blind.
        if keepsHistory(tf) {
            do {
                if case .content(let d) = disk, d != text {
                    let fmt = tf.format
                    let ch = DiffEngine.diff(
                        oldText: d, newText: text,
                        oldTree: Parsers.parse(d, format: fmt).tree,
                        newTree: Parsers.parse(text, format: fmt).tree)
                    try recordSnapshot(path: path, content: d, origin: .app, changes: ch)
                } else if disk == .missing, let b = base?.text {
                    // externally deleted — keep the pre-edit base recoverable
                    try recordSnapshot(path: path, content: b, origin: .external, changes: [])
                }
            } catch {
                return .failed(L("Backup failed — not writing: %@",
                                 error.localizedDescription))
            }
        }

        do {
            try writeAtomic(text, to: path)
        } catch {
            return .failed(L("Could not write: %@", error.localizedDescription))
        }

        selfWriteHashes[path] = SnapshotStore.sha256(text)
        edits.removeValue(forKey: path)
        editBases.removeValue(forKey: path)
        dirtyPaths.remove(path)
        conflicts.remove(path)
        externalChanges.removeValue(forKey: path)
        saveErrors.removeValue(forKey: path)
        reload(path, origin: nil)

        var changes: [SemanticChange] = []
        if let d = disk.text, d != text {
            let fmt = format(for: path)
            changes = DiffEngine.diff(
                oldText: d, newText: text,
                oldTree: Parsers.parse(d, format: fmt).tree,
                newTree: Parsers.parse(text, format: fmt).tree)
        }
        if postRecord, keepsHistory(tf) {
            do {
                try recordSnapshot(path: path, content: text, origin: origin, changes: changes)
            } catch {
                historyErrors[path] = error.localizedDescription
            }
        }
        refreshVolatileMcp(path: path)
        rebuildMcpIndex()
        // success activity is logged only after the write really happened
        logActivity(path: path, origin: origin, changes: changes)
        return .written
    }

    /// Mark a detected divergence: keep the buffer, surface a conflict with
    /// the disk content captured so resolution can be verified again later.
    private func flagConflict(path: String, disk: DiskState) {
        conflicts.insert(path)
        var changes: [SemanticChange] = []
        if let d = disk.text, let b = baseFor(path)?.text {
            let f = format(for: path)
            changes = DiffEngine.diff(oldText: b, newText: d,
                                      oldTree: Parsers.parse(b, format: f).tree,
                                      newTree: Parsers.parse(d, format: f).tree)
        }
        externalChanges[path] = ExternalChange(
            changes: changes,
            previousContent: baseFor(path)?.text,
            diskContent: disk.text,
            isDeletion: disk == .missing)
    }

    private func attemptSave(path: String, mode: WriteMode) {
        guard !savingPaths.contains(path) else { return }
        guard let text = edits[path] else { return }
        guard let tf = trackedFile(for: path) else { return }
        guard !isReadOnly(path) else {
            saveErrors[path] = L("Read-only file")
            return
        }
        let parsed = Parsers.parse(text, format: tf.format)
        if let err = parsed.error {
            saveErrors[path] = err
            return
        }
        saveErrors.removeValue(forKey: path)
        let previousLimit = snapshots.historyLimit
        snapshots.historyLimit = { max(2, previousLimit()) }
        defer { snapshots.historyLimit = previousLimit }
        switch commitWrite(path: path, text: text, tf: tf,
                           origin: .app, mode: mode, postRecord: true) {
        case .written:
            break
        case .conflict(let disk):
            flagConflict(path: path, disk: disk)
        case .failed(let msg):
            saveErrors[path] = msg
        }
    }

    /// Write preserving existing POSIX permissions (configs are often 600);
    /// resolves symlinks to the real target. See `AtomicWriter` for policy.
    private func writeAtomic(_ text: String, to path: String) throws {
        try AtomicWriter.writePreservingPermissions(text, toPath: path)
    }

    // MARK: - watch events

    func handleWatchEvent(_ path: String) {
        lastEventAt = Date()

        if projectScanDirectories.contains(path) {
            refresh()
            return
        }
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

    /// Also a test seam: suites call it directly to simulate watcher events.
    func handleFileChanged(_ path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            largeLoads[path]?.cancel(); loadTokens.removeValue(forKey: path); loadingPaths.remove(path)
            let previous = documents[path]?.text
            updateFileMeta(path: path) {
                $0.exists = false; $0.size = 0; $0.mtime = nil
                $0.issues = []; $0.managedBlocks = []
            }
            if dirtyPaths.contains(path) { flagConflict(path: path, disk: .missing) }
            else if let previous {
                externalChanges[path] = ExternalChange(changes: [], previousContent: previous,
                                                       diskContent: nil, isDeletion: true)
            }
            documents.removeValue(forKey: path)
            selfWriteHashes.removeValue(forKey: path)
            volatileMcpEntries.removeAll { $0.sourcePath == path }
            rebuildMcpIndex()
            return
        }
        if savingPaths.contains(path) { return }
        let attributes = try? fm.attributesOfItem(atPath: path)
        updateFileMeta(path: path) {
            $0.exists = true
            $0.size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            $0.mtime = attributes?[.modificationDate] as? Date
        }
        if usesBackgroundProcessing(path) { loadLargeFile(path); return }
        let newText: String
        do { newText = try Parsers.readText(at: path) }
        catch {
            saveErrors[path] = L(error.localizedDescription)
            if dirtyPaths.contains(path) { flagConflict(path: path, disk: .unreadable) }
            documents.removeValue(forKey: path)
            volatileMcpEntries.removeAll { $0.sourcePath == path }
            rebuildMcpIndex()
            return
        }

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

        if keepsHistory(tf) {
            do {
                try recordSnapshot(path: path, content: newText, origin: .external, changes: changes)
            } catch {
                historyErrors[path] = error.localizedDescription
            }
        }

        logActivity(path: path, origin: .external, changes: changes)

        externalChanges[path] = ExternalChange(changes: changes,
                                               previousContent: oldText,
                                               diskContent: newText)

        reload(path, origin: nil)
        refreshVolatileMcp(path: path)
        rebuildMcpIndex()

        if !(tf?.volatile ?? false), !changes.isEmpty {
            let agentName = agents.first { $0.id == fileOwners[path] }?.name ?? "Agente"
            notifier?.postChange(path: path, agentName: agentName,
                                 summary: DiffEngine.summary(changes))
        }

        // dirty buffer → conflict (don't clobber user's typing)
        if dirtyPaths.contains(path) {
            conflicts.insert(path)
        } else {
            edits.removeValue(forKey: path)
            editBases.removeValue(forKey: path)
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

    /// "Keep mine": overwrite — but only the disk state the conflict was
    /// flagged on. If disk moved again, this re-flags instead of clobbering
    /// the newer change.
    func resolveConflictKeepMine(path: String) {
        let e = externalChanges[path]
        let expected: DiskState? = e?.isDeletion == true
            ? .missing
            : e?.diskContent.map { .content($0) }
        attemptSave(path: path, mode: .force(expected: expected))
    }

    /// Accept one fresh read. A read failure keeps the draft and conflict;
    /// accepting a deletion clears the stale document and MCP entries.
    func resolveConflictUseDisk(path: String) {
        guard !savingPaths.contains(path) else { return }
        if usesBackgroundProcessing(path) { takeLargeDiskVersion(path); return }
        let disk = readDiskState(path)
        switch disk {
        case .unreadable:
            saveErrors[path] = L("Could not read the current file")
            return
        case .content(let text):
            installDocument(path, text: text)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            updateFileMeta(path: path) {
                $0.exists = true
                $0.size = Int64(text.utf8.count)
                $0.mtime = attrs?[.modificationDate] as? Date
            }
        case .missing:
            documents.removeValue(forKey: path)
            updateFileMeta(path: path) {
                $0.exists = false; $0.size = 0; $0.mtime = nil
                $0.issues = []; $0.managedBlocks = []
            }
        }
        discardEdit(path: path)
        saveErrors.removeValue(forKey: path)
        selfWriteHashes.removeValue(forKey: path)
        refreshVolatileMcp(path: path)
        rebuildMcpIndex()
    }

    private func takeLargeDiskVersion(_ path: String) {
        let originalBuffer = edits[path]
        let worker = largeWorker
        let format = format(for: path)
        loadingPaths.insert(path)
        largeLoads[path]?.cancel()
        let token = UUID(); loadTokens[path] = token
        largeLoads[path] = Task { [weak self] in
            do {
                let disk = try await worker.disk(path)
                let parsedError: String?
                if case .content(let text) = disk { parsedError = try await worker.validate(text, format: format) }
                else { parsedError = nil }
                let contentHash: String?
                if case .content(let text) = disk { contentHash = await worker.hash(text) } else { contentHash = nil }
                guard !Task.isCancelled, let self, self.loadTokens[path] == token else { return }
                guard self.edits[path] == originalBuffer else {
                    self.saveErrors[path] = L("The buffer changed while reading disk. Try again.")
                    self.loadingPaths.remove(path); return
                }
                self.discardEdit(path: path)
                switch disk {
                case .content(let text):
                    self.installLargeResult(path, .init(text: text, hash: contentHash!, parseError: parsedError, historyError: nil))
                case .missing:
                    self.documents.removeValue(forKey: path)
                    self.updateFileMeta(path: path) { $0.exists = false; $0.size = 0; $0.mtime = nil }
                    self.volatileMcpEntries.removeAll { $0.sourcePath == path }
                    self.rebuildMcpIndex()
                }
            } catch {
                if !Task.isCancelled { self?.saveErrors[path] = error.localizedDescription }
            }
            guard let self, self.loadTokens[path] == token else { return }
            self.loadingPaths.remove(path); self.largeLoads.removeValue(forKey: path)
        }
    }

    func revertExternal(path: String) {
        guard let change = externalChanges[path],
              let prev = change.previousContent else { return }
        let expected: DiskState? = change.isDeletion
            ? .missing
            : change.diskContent.map { .content($0) }
        applyContent(path: path, text: prev, origin: .revert,
                     mode: .force(expected: expected))
    }

    // MARK: - restore confirmation flow

    private(set) var restoreOriginalText = ""
    private(set) var restoreProposedText: String?
    private(set) var preparingRestore = false
    private var restoreDisk: DiskState?
    private var restoreBuffer: String?
    private var restoreHistoryEnabled = false
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    func requestRestore(path: String, version: FileVersion) {
        prepareRestore(RestoreRequest(kind: .version, path: path, version: version))
    }

    func requestRestorePrevious(_ path: String) {
        let version = history(for: path).first { $0.hash != documents[path]?.hash }
        prepareRestore(RestoreRequest(kind: .previous, path: path, version: version))
    }

    func requestRevertExternal(_ path: String) {
        prepareRestore(RestoreRequest(kind: .revertExternal, path: path, version: nil))
    }

    private func prepareRestore(_ request: RestoreRequest) {
        cancelRestore()
        guard !savingPaths.contains(request.path) else { return }
        pendingRestore = request
        restoreBuffer = edits[request.path]
        restoreHistoryEnabled = keepsHistory(trackedFile(for: request.path))
        let previous = externalChanges[request.path]?.previousContent
        if usesBackgroundProcessing(request.path) {
            preparingRestore = true
            let worker = largeWorker
            let policy = backgroundHistory(request.path)
            restoreTask = Task { [weak self] in
                do {
                    let disk = try await worker.disk(request.path)
                    let target: String?
                    if request.kind == .revertExternal { target = previous }
                    else if let version = request.version { target = await worker.versionContent(path: request.path, version: version, history: policy) }
                    else { target = nil }
                    guard !Task.isCancelled, let self, self.pendingRestore?.id == request.id else { return }
                    self.restoreDisk = disk == .missing ? .missing : {
                        if case .content(let text) = disk { return DiskState.content(text) }; return .unreadable
                    }()
                    self.restoreOriginalText = self.restoreDisk?.text ?? ""
                    self.restoreProposedText = target
                } catch { if !Task.isCancelled { self?.saveErrors[request.path] = error.localizedDescription } }
                if self?.pendingRestore?.id == request.id { self?.preparingRestore = false }
            }
        } else {
            restoreDisk = readDiskState(request.path)
            restoreOriginalText = restoreDisk?.text ?? ""
            restoreProposedText = request.kind == .revertExternal ? previous
                : request.version.flatMap { snapshots.content(for: request.path, version: $0) }
        }
    }

    func cancelRestore() {
        pendingRestore = nil; restoreTask?.cancel(); restoreTask = nil
        restoreDisk = nil; restoreProposedText = nil; restoreOriginalText = ""; preparingRestore = false
    }

    /// The preview pins target content, disk and draft; watcher reloads cannot
    /// silently broaden what the user approved while the sheet was open.
    func confirmRestore() {
        guard let request = pendingRestore, !preparingRestore else { return }
        let target = restoreProposedText
        let expected = restoreDisk
        let originalBuffer = restoreBuffer
        let historyEnabled = restoreHistoryEnabled
        cancelRestore()
        guard !isReadOnly(request.path) else { saveErrors[request.path] = L("Read-only file"); return }
        guard let target, let expected, expected != .unreadable else {
            saveErrors[request.path] = L("Version content unavailable"); return
        }
        guard edits[request.path] == originalBuffer,
              keepsHistory(trackedFile(for: request.path)) == historyEnabled else {
            saveErrors[request.path] = L("The buffer or history setting changed. Review the save again."); return
        }
        applyContent(path: request.path, text: target, origin: .revert, mode: .force(expected: expected))
    }

    /// What the confirm dialog should explain for this request.
    func restoreExplanation(for req: RestoreRequest) -> String {
        let historyEnabled = keepsHistory(trackedFile(for: req.path))
        if dirtyPaths.contains(req.path) {
            return historyEnabled
                ? L("You have unsaved edits — they will be archived as a history snapshot, not lost.")
                : L("Restore is blocked: this file has unsaved edits and history is disabled. Save or discard the edits first.")
        }
        if !historyEnabled {
            return L("History is disabled for this file. Restoring replaces the current disk content without a history backup.")
        }
        if req.kind == .revertExternal {
            return L("The current disk content will be replaced by the previous version.")
        }
        return L("Current content will be kept as another history snapshot.")
    }

    func clearSaveError(path: String) { saveErrors.removeValue(forKey: path) }

    /// Read-only check usable by UI entry points (menus, inspector).
    func isReadOnly(_ path: String) -> Bool {
        (fileSource[path]?.readOnly ?? trackedFile(for: path)?.readOnly ?? false)
            || (trackedFile(for: path)?.size ?? 0) > Int64(Parsers.maximumBackgroundBytes)
    }

    func restoreVersion(path: String, version: FileVersion, overwrite: Bool = false) {
        guard trackedFile(for: path) != nil, !isReadOnly(path) else {
            saveErrors[path] = L("Read-only file")
            return
        }
        guard let content = snapshots.content(for: path, version: version) else {
            saveErrors[path] = L("Version content unavailable")
            return
        }
        if dirtyPaths.contains(path) && !overwrite {
            // never silently drop unsaved work
            saveErrors[path] = L("Unsaved changes — save or discard before restoring")
            return
        }
        applyContent(path: path, text: content, origin: .revert, mode: .guarded)
    }

    private func applyContent(path: String, text: String,
                              origin: FileVersion.Origin, mode: WriteMode) {
        guard !savingPaths.contains(path) else { return }
        guard let tf = trackedFile(for: path) else { return }
        guard !isReadOnly(path) else {
            saveErrors[path] = L("Read-only file")
            return
        }
        if usesBackgroundProcessing(path) || text.utf8.count > Parsers.maximumFileBytes {
            let draft = dirtyPaths.contains(path) ? edits[path] : nil
            guard draft == nil || keepsHistory(tf) else {
                saveErrors[path] = L("Restore is blocked: this file has unsaved edits and history is disabled. Save or discard the edits first.")
                return
            }
            let expected: DiskState
            switch mode {
            case .guarded: expected = baseFor(path) ?? .missing
            case .force(let state): expected = state ?? baseFor(path) ?? .missing
            }
            let review = SaveReview(path: path, original: expected.text ?? "", proposed: text,
                format: tf.format, overwritesConflict: false, historyEnabled: keepsHistory(tf))
            commitLargeSave(review, disk: expected, origin: origin, draft: draft)
            return
        }
        if let error = Parsers.parse(text, format: tf.format).error {
            saveErrors[path] = error
            return
        }
        let dirty = dirtyPaths.contains(path)
        guard !dirty || keepsHistory(tf) else {
            saveErrors[path] = L("Restore is blocked: this file has unsaved edits and history is disabled. Save or discard the edits first.")
            return
        }
        let previousLimit = snapshots.historyLimit
        snapshots.historyLimit = { max(dirty ? 3 : 2, previousLimit()) }
        defer { snapshots.historyLimit = previousLimit }
        // restoring over a dirty buffer is only reachable via an explicit
        // overwrite — preserve the buffer in history before dropping it
        if dirty, let buf = edits[path] {
            do {
                try recordSnapshot(path: path, content: buf, origin: .app, changes: [])
            } catch {
                historyErrors[path] = error.localizedDescription
                saveErrors[path] = L("Backup failed — not writing: %@", error.localizedDescription)
                return
            }
        }
        switch commitWrite(path: path, text: text, tf: tf,
                           origin: origin, mode: mode, postRecord: true) {
        case .written:
            break
        case .conflict(let disk):
            flagConflict(path: path, disk: disk)
        case .failed(let msg):
            saveErrors[path] = msg
        }
    }

    func history(for path: String) -> [FileVersion] {
        if histories[path] == nil { histories[path] = safeLoadHistory(path) }
        return histories[path] ?? []
    }

    /// Re-read persisted history for a path (after external repairs/tests).
    func refreshHistory(path: String) {
        histories.removeValue(forKey: path)
        histories[path] = safeLoadHistory(path)
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
    func restorePrevious(_ path: String, overwrite: Bool = false) {
        let currentHash = documents[path]?.hash
        guard let target = history(for: path).first(where: { $0.hash != currentHash }) else { return }
        restoreVersion(path: path, version: target, overwrite: overwrite)
    }

    func requestFind() { findRequest += 1 }

    func setWatchDebounce(_ interval: TimeInterval) { watcher.setDebounce(interval) }
}

/// Hands a value to a detached task when the caller knows it is only read
/// there (e.g. a `SnapshotStore` copy for the permission audit).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
