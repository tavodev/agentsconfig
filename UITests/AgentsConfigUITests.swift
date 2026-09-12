import XCTest
import CryptoKit

/// Dedicated opt-in scheme: never part of the hostless test run. Every test
/// launches the application with its own fixture home and UserDefaults suite.
final class AgentsConfigUITests: XCTestCase {
    @MainActor private func fixture() throws -> (XCUIApplication, URL, String) {
        continueAfterFailure = false
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentsconfig-ui-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let canonical = home.resolvingSymlinksInPath()
        let suite = "agentsconfig-ui-\(UUID())"
        for (path, content) in [
            ".claude/settings.json": #"{"env":{"API_KEY":"FAKE-UI-SECRET"},"model":"fixture"}"#,
            ".claude/mcp.json": #"{"env":{"API_KEY":"FAKE-UI-OTHER"}}"#,
            ".claude.json": #"{"mcpServers":{}}"#,
            ".codex/config.toml": "model = 'fixture'\n",
            ".codex/auth.json": #"{"OPENAI_API_KEY":"FAKE-UI-AUTH"}"#,
            ".config/opencode/opencode.json": "{}"
        ] {
            let url = canonical.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let app = XCUIApplication(bundleIdentifier: "com.tavodev.agentsconfig.ui-fixture")
        app.launchEnvironment["AGENTSCONFIG_HOME"] = canonical.path
        app.launchEnvironment["AGENTSCONFIG_DEFAULTS_SUITE"] = suite
        app.launchArguments = ["-appLanguage", "en", "-menuBarExtra", "NO", "-notificationsEnabled", "NO"]
        app.launch()
        return (app, canonical, suite)
    }

    @MainActor private func cleanup(_ app: XCUIApplication, _ home: URL, _ suite: String) {
        app.terminate()
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    @MainActor private func click(_ identifier: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier)\n\(app.debugDescription)")
        element.click()
    }

    @MainActor private func open(_ relative: String, agent: String = "claude-code", home: URL, app: XCUIApplication) {
        click("agent-row:\(agent)", in: app)
        click("file-row:\(home.appendingPathComponent(relative).path)", in: app)
    }

    @MainActor func testRestorePreviousVersionShowsReviewAndCanCancel() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude/settings.json")
        let original = try Data(contentsOf: path)
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"restore-me"}"#)
        app.typeKey("s", modifierFlags: .command); click("confirm-save", in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: path, encoding: .utf8))?.contains("restore-me") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "file-row:\(path.path)")).firstMatch
        row.rightClick(); app.menuItems["Restore previous version"].click()
        XCTAssertTrue(app.buttons["confirm-restore"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("restore-me"))
        row.rightClick(); app.menuItems["Restore previous version"].click()
        click("confirm-restore", in: app)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: path)) == original
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
    }

    @MainActor func testSourceBuffersAndUndoStayWithTheirFile() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"draft-A"}"#)
        open(".claude/mcp.json", home: home, app: app)
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"draft-B"}"#)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse((editor.value as? String ?? "").contains("draft-A"))
        open(".claude/settings.json", home: home, app: app)
        XCTAssertTrue((editor.value as? String ?? "").contains("draft-A"))
        XCTAssertFalse(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8).contains("draft-A"))
    }

    @MainActor func testMcpArgumentsAreReviewedBeforeSaving() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".config/opencode/opencode.json", agent: "opencode", home: home, app: app)
        click("add-mcp", in: app)
        app.textFields["mcp-name"].click(); app.textFields["mcp-name"].typeText("ui-server")
        app.textFields["mcp-command"].click(); app.textFields["mcp-command"].typeText("fake-mcp")
        click("add-mcp-argument", in: app)
        app.textFields["mcp-argument-0"].click(); app.textFields["mcp-argument-0"].typeText("two words")
        click("add-mcp-argument", in: app) // preserve the empty second argument
        click("review-mcp", in: app)
        let path = home.appendingPathComponent(".config/opencode/opencode.json")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "{}")
        click("apply-mcp", in: app)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "{}")
        app.typeKey("s", modifierFlags: .command)
        click("confirm-save", in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: path, encoding: .utf8))?.contains("ui-server") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let servers = try XCTUnwrap(root["mcp"] as? [String: Any])
        let server = try XCTUnwrap(servers["ui-server"] as? [String: Any])
        XCTAssertEqual(server["command"] as? [String], ["fake-mcp", "two words", ""])
    }

    @MainActor func testMaskPreferenceUpdatesAnOpenReadOnlySource() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".codex/auth.json", agent: "codex", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String ?? "").contains("FAKE-UI-AUTH"))
        app.typeKey(",", modifierFlags: .command)
        click("mask-secrets", in: app)
        let revealed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "FAKE-UI-AUTH"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 5), .completed)
        click("mask-secrets", in: app)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS %@)", "FAKE-UI-AUTH"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
    }

    @MainActor func testSourceSaveRequiresReviewAndCancelKeepsDisk() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"ui-reviewed"}"#)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["confirm-save"].waitForExistence(timeout: 5), app.debugDescription)
        let path = home.appendingPathComponent(".claude/settings.json")
        XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains("ui-reviewed"))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue((editor.value as? String)?.contains("ui-reviewed") == true)
        app.typeKey("s", modifierFlags: .command)
        click("confirm-save", in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: path, encoding: .utf8))?.contains("ui-reviewed") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
    }

    @MainActor func testRevealResetsAcrossFilesAndReadOnlySourceIsMasked() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".claude/settings.json", home: home, app: app)
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-SECRET"))
        click("reveal-secret", in: app)
        XCTAssertTrue(app.debugDescription.contains("FAKE-UI-SECRET"))
        open(".claude/mcp.json", home: home, app: app)
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-OTHER"))
        open(".claude/settings.json", home: home, app: app)
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-SECRET"))
        open(".codex/auth.json", agent: "codex", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String ?? "").contains("FAKE-UI-AUTH"))
    }

    @MainActor func testFileHistoryRemovalHasConfirmationAndDoesNotChangeConfig() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude/settings.json")
        let original = try Data(contentsOf: path)
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("3", modifierFlags: .command)
        click("file-history-enabled", in: app)
        click("clear-file-history", in: app)
        XCTAssertTrue(app.buttons["Remove versions"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        click("clear-file-history", in: app)
        app.windows.buttons["Remove versions"].firstMatch.click()
        XCTAssertEqual(try Data(contentsOf: path), original)
        let hash = SHA256.hash(data: Data(path.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let index = home.appendingPathComponent("Library/Application Support/AgentsConfig/History/\(hash)/index.json")
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: index), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (object["entries"] as? [Any])?.isEmpty == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 5), .completed)
    }
}
