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
        app.launchArguments = ["-appLanguage", "en", "-menuBarExtra", "NO", "-notificationsEnabled", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        // Resize our own test window explicitly: Zoom is not an unzoom
        // operation when macOS restores the same frame as the standard frame.
        if window.frame.width >= 1300 {
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -2, dy: 0))
            edge.press(forDuration: 0.1, thenDragTo: edge.withOffset(
                CGVector(dx: 1280 - window.frame.width, dy: 0)))
        }
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.frame.width < 1300
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [compact], timeout: 5), .completed)
        return (app, canonical, suite)
    }

    @MainActor func testFirstDiagnosticExportShowsReviewContent() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        click("destination-analysis", in: app)
        let diagnostics = app.radioButtons["Diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.click()
        click("review-diagnostic-export", in: app)
        XCTAssertTrue(app.staticTexts["Review diagnostic export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["save-diagnostic-report"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["save-diagnostic-report"].exists)
    }

    @MainActor private func cleanup(_ app: XCUIApplication, _ home: URL, _ suite: String) {
        app.terminate()
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    @MainActor private func click(_ identifier: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier)\n\(app.debugDescription)")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        if result != .completed {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Interaction failure"; shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertEqual(result, .completed, "\(identifier)\n\(app.debugDescription)")
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
        app.textFields["mcp-argument-0"].click()
        app.textFields["mcp-argument-0"].typeText("two")
        app.typeKey(.space, modifierFlags: [])
        app.textFields["mcp-argument-0"].typeText("words")
        XCTAssertEqual(app.textFields["mcp-argument-0"].value as? String, "two words")
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
        app.activate()
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Zoom"].click()
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
    @MainActor func testRedesignSettingsUsesContentAndPreservesEditorMode() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.textViews["source-editor"].waitForExistence(timeout: 5))
        click("destination-settings", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mask-secrets").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["file-inspector"].exists)
        XCTAssertGreaterThan(app.scrollViews.allElementsBoundByIndex.map { $0.frame.width }.max() ?? 0, 400)
        open(".claude/settings.json", home: home, app: app)
        XCTAssertTrue(app.textViews["source-editor"].waitForExistence(timeout: 5))
        let context = app.staticTexts["editor-context"]
        XCTAssertTrue(((context.value as? String) ?? context.label).contains("Global"))
    }

    @MainActor func testRedesignNamedBooleanAndAdaptiveInspector() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude/settings.json")
        try #"{"enabled":true,"model":"fixture"}"#.write(to: path, atomically: true, encoding: .utf8)
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("1", modifierFlags: .command)
        let toggle = app.switches["enabled"]
        let checkbox = app.checkBoxes["enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5) || checkbox.exists)
        app.typeKey("0", modifierFlags: [.option, .command])
        XCTAssertTrue(app.staticTexts["File information"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["editor-filename"].exists)
    }

    @MainActor func testRedesignMcpMatrixHasWideRowsAndOptionalDetails() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude.json")
        let config = #"{"mcpServers":{"fixture-design-server":{"command":"fake-mcp","args":[]}}}"#
        try config.write(to: path, atomically: true, encoding: .utf8)
        click("rescan", in: app)
        click("destination-mcp", in: app)
        let row = app.descendants(matching: .any).matching(identifier: "mcp-row:fixture-design-server").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(row.frame.width, 600)
        row.click()
        click("mcp-details", in: app)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fake-mcp"].exists)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "MCP details"; shot.lifetime = .keepAlways; add(shot)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), config)
    }

    @MainActor func testRedesignConflictKeepsDraftAndDiskUntilReview() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); app.typeKey("a", modifierFlags: .command)
        editor.typeText(#"{"model":"draft-design"}"#)
        let path = home.appendingPathComponent(".claude/settings.json")
        let external = #"{"model":"external-design"}"#
        try external.write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Conflict with disk"].waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("draft-design"))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Editor conflict"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), external)
    }

    @MainActor func testWideHistoryWithInspectorDoesNotCreateLayoutCycle() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".claude/settings.json", home: home, app: app)
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Zoom"].click()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 1450)
        app.typeKey("0", modifierFlags: [.option, .command])
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Restore this version"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy path"].exists)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Wide history and inspector"; shot.lifetime = .keepAlways; add(shot)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["editor-filename"].exists)
    }

    @MainActor func testProjectsExposeAnAccessibleAddAction() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        app.radioButtons["Projects"].click()
        let add = app.descendants(matching: .any).matching(identifier: "add-project").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable)
    }

    @MainActor func testCompactInspectorCanPresentRestoreReview() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("0", modifierFlags: [.option, .command])
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Restore previous version"].click()
        XCTAssertTrue(app.staticTexts["restore-review"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testCompactMcpDetailsCanPresentCopyReview() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        try #"{"mcpServers":{"fixture-copy":{"command":"fake-mcp","args":[]}}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        click("rescan", in: app)
        click("destination-mcp", in: app)
        click("mcp-row:fixture-copy", in: app)
        click("mcp-details", in: app)
        app.menuButtons["Copy here"].firstMatch.click()
        app.menuItems["config.toml"].click()
        XCTAssertTrue(app.buttons["apply-mcp"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
    }

}
