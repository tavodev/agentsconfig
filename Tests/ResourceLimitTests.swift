import Foundation
import Testing

/// Synthetic boundary checks, not a claim that the limits fit real homes.
/// The enclosing suite serializes AppPaths/defaults and every fixture is local.
extension AgentsConfigTestSuite {
@Suite("Resource limits", .serialized)
@MainActor
struct ResourceLimitTests {
    private func json(bytes: Int) -> String {
        let prefix = "{\"payload\":\"", suffix = "\"}"
        let available = bytes - prefix.utf8.count - suffix.utf8.count
        return prefix + String(repeating: "🦊", count: available / 4)
            + String(repeating: "x", count: available % 4) + suffix
    }

    private func createFiles(in root: URL, count: Int) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<count {
            let path = root.appendingPathComponent("fixture-\(index).txt").path
            guard FileManager.default.createFile(atPath: path, contents: Data(),
                                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    @Test func inspectionBoundaryUsesUTF8BytesAndNeverReturnsPartialText() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        for delta in [-1, 0, 1] {
            let bytes = Parsers.maximumFileBytes + delta
            let text = json(bytes: bytes)
            #expect(text.utf8.count == bytes)
            let file = try env.write("limits/inspection.json", text)
            if delta <= 0 {
                #expect(try Parsers.readText(at: file.path) == text)
                let parsed = Parsers.parse(text, format: .json)
                #expect(parsed.error == nil)
                #expect((parsed.tree as? [String: Any])?["payload"] as? String != nil)
            } else {
                #expect(throws: Parsers.InputError.self) {
                    try Parsers.readText(at: file.path)
                }
                let parsed = Parsers.parse(text, format: .json)
                #expect(parsed.tree == nil && parsed.error != nil)
            }
        }
    }

    @Test func backgroundBoundaryAcceptsCompleteUTF8AndRejectsOneExtraByte() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        for delta in [-1, 0, 1] {
            let bytes = Parsers.maximumBackgroundBytes + delta
            let text = json(bytes: bytes)
            #expect(text.utf8.count == bytes)
            let file = try env.write("limits/background.json", text)
            if delta <= 0 {
                #expect(try Parsers.readText(at: file.path, limit: Parsers.maximumBackgroundBytes) == text)
                let parsed = Parsers.parseInBackground(text, format: .json)
                #expect(parsed.error == nil)
                #expect((parsed.tree as? [String: Any])?["payload"] as? String != nil)
            } else {
                #expect(throws: Parsers.InputError.self) {
                    try Parsers.readText(at: file.path, limit: Parsers.maximumBackgroundBytes)
                }
                let parsed = Parsers.parseInBackground(text, format: .json)
                #expect(parsed.tree == nil && parsed.error != nil)
            }
        }
    }

    @Test func defaultDepthKeepsLevelEightAndSkipsLevelNineGitAndLinks() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let root = URL(fileURLWithPath: env.path("depth"))
        var expected = Set<String>()
        var relative = "depth"
        for level in 0...9 {
            let file = try env.write(relative + "/SKILL.md", "# Level \(level)")
            if level <= 8 { expected.insert(file.path) }
            relative += "/next"
        }
        try env.write("depth/.git/ignored/SKILL.md", "# Git fixture")
        let external = try env.write("external/SKILL.md", "# Link fixture").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"),
                                                  withDestinationURL: external)
        let limited = DiscoveryTree.scan(root: root.path)
        #expect(Set(limited.files) == expected)
        #expect(limited.truncated && limited.skippedLinks == 1)
        #expect(Set(AgentRegistry.skillTree(at: root.path).files) == expected)
        #expect(!limited.directories.contains { $0.contains("/.git/") || $0.hasSuffix("/.git") || $0.hasSuffix("/linked") })

        // Remove only depth 9; depth 8 itself is supported and no longer truncated.
        let ninth = root.appendingPathComponent(Array(repeating: "next", count: 9).joined(separator: "/"))
        try FileManager.default.removeItem(at: ninth)
        let complete = DiscoveryTree.scan(root: root.path)
        #expect(Set(complete.files) == expected)
        #expect(!complete.truncated && complete.skippedLinks == 1)
    }

    @Test func defaultDirectoryBudgetIncludesRootAndReportsOverflow() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let root = URL(fileURLWithPath: env.path("directories"))
        let rootFile = try env.write("directories/SKILL.md", "# Root")
        for index in 0..<999 {
            try env.write("directories/child-\(index)/SKILL.md", "# Child")
        }
        let complete = DiscoveryTree.scan(root: root.path)
        #expect(complete.directories.count == 1_000 && complete.files.count == 1_000)
        #expect(!complete.truncated)
        try env.write("directories/overflow/SKILL.md", "# Overflow")
        let limited = DiscoveryTree.scan(root: root.path)
        #expect(limited.directories.count == 1_000 && limited.files.count == 1_000)
        #expect(limited.files.contains(rootFile.path))
        #expect(limited.truncated)
        let skills = AgentRegistry.skillTree(at: root.path)
        #expect(skills.directories.count == 1_000 && skills.files.count == 1_000)
        #expect(skills.files.contains(rootFile.path))
    }

    @Test func directoryEntryBudgetSignalsTheFirstOmittedEntry() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let root = URL(fileURLWithPath: env.path("entries"))
        try createFiles(in: root, count: 10_000)
        let complete = DiscoveryTree.scan(root: root.path)
        #expect(complete.files.count == 10_000 && !complete.truncated)
        try env.write("entries/overflow.txt", "fixture")
        let limited = DiscoveryTree.scan(root: root.path)
        #expect(limited.files.count == 10_000 && limited.truncated)
        #expect(limited.childNames[root.path]?.count == 10_001)
    }

    @Test func genericFileBudgetAlsoAppliesAcrossSmallDirectories() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let root = URL(fileURLWithPath: env.path("aggregate"))
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try createFiles(in: first, count: 5_001)
        try createFiles(in: second, count: 5_001)
        let limited = DiscoveryTree.scan(root: root.path)
        #expect(limited.directories.count == 3)
        #expect(limited.childNames[first.path]?.count == 5_001)
        #expect(limited.childNames[second.path]?.count == 5_001)
        #expect(limited.files.count == 10_000 && limited.truncated)
        // Folder-only traversal has no file omission and must not inherit that flag.
        let folders = DiscoveryTree.scan(root: root.path, collectFiles: false)
        #expect(folders.files.isEmpty && folders.directories.count == 3 && !folders.truncated)
    }

    @Test func semanticLimitPreservesRedactionWithDisplayMaskingDisabled() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        AppSettings.defaults.set(false, forKey: "maskSecrets")
        for count in [499, 500, 501] {
            let before: [String: Any] = ["credentials": Array(repeating: "FAKE-BEFORE", count: count)]
            let after: [String: Any] = ["credentials": Array(repeating: "FAKE-AFTER", count: count)]
            let changes = DiffEngine.diff(oldText: try #require(Parsers.serializeJSON(before)),
                                          newText: try #require(Parsers.serializeJSON(after)),
                                          oldTree: before, newTree: after)
            #expect(changes.count == min(count, 500))
            #expect(changes.first?.keyPath == "credentials[0]")
            #expect(changes.last?.keyPath == "credentials[\(min(count, 500) - 1)]")
            for change in changes {
                #expect(change.kind == .modified)
                #expect(change.oldValue?.contains(Secrets.maskedValue) == true)
                #expect(change.newValue?.contains(Secrets.maskedValue) == true)
                #expect(change.oldValue?.contains("FAKE-BEFORE") == false)
                #expect(change.newValue?.contains("FAKE-AFTER") == false)
            }
        }
    }

    @Test func lineLimitKeepsBoundaryDiffAndOmitsOversizedDetails() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        var lines = (0..<2_000).map { "fixture line \($0)" }
        let before = lines.joined(separator: "\n")
        lines[1_999] = "changed fixture line"
        let atBoundary = DiffEngine.lineDiff(oldText: before, newText: lines.joined(separator: "\n"))
        #expect(atBoundary.count == 2)
        #expect(atBoundary.contains { $0.kind == .removed && $0.oldValue == "fixture line 1999" })
        #expect(atBoundary.contains { $0.kind == .added && $0.newValue == "changed fixture line" })

        lines.append("api_key = 'FAKE-LINE-SECRET'")
        let omitted = DiffEngine.lineDiff(oldText: before, newText: lines.joined(separator: "\n"))
        #expect(omitted.count == 1)
        #expect(omitted.first?.keyPath == L("Large diff omitted"))
        #expect(omitted.first?.oldValue == nil && omitted.first?.newValue == nil)

        // Under the limit, credential context must mask even changed generic lines.
        lines.removeLast()
        lines[0] = "api_key = 'FAKE-CONTEXT'"
        let sensitiveBefore = lines.joined(separator: "\n")
        lines[1_999] = "generic = 'FAKE-NEW-LINE'"
        let sensitive = DiffEngine.lineDiff(oldText: sensitiveBefore, newText: lines.joined(separator: "\n"))
        #expect(sensitive.count == 2)
        #expect(sensitive.allSatisfy {
            ($0.oldValue == nil || $0.oldValue == Secrets.maskedValue)
                && ($0.newValue == nil || $0.newValue == Secrets.maskedValue)
        })
    }
}
}
