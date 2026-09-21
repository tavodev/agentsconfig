import XCTest
import CryptoKit
import AppKit

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
        // The window can be left behind another app on a shared desktop even
        // when launch reports success; raise it before any synthesized input.
        app.activate()
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
        // Covered elements are never hittable: raise the fixture app so its
        // windows sit in front before measuring hit points or scrolling.
        app.activate()
        reveal(element, identifier: identifier, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        if result != .completed {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Interaction failure"; shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertEqual(result, .completed, "\(identifier)\n\(app.debugDescription)")
        element.click()
    }

    /// Same as `click` but matches the visible label/title instead of an
    /// accessibility identifier (banner and sheet buttons carry none).
    @MainActor private func clickLabel(_ label: String, in app: XCUIApplication) {
        let element = app.buttons.matching(NSPredicate(
            format: "label == %@ OR title == %@", label, label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(label)\n\(app.debugDescription)")
        app.activate()
        reveal(element, identifier: element.identifier, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                       "\(label)\n\(app.debugDescription)")
        element.click()
    }

    /// Scrolls the innermost scroll view containing `element` until the
    /// element's frame enters the viewport. The native Settings scene keeps
    /// part of the Form below the fold: off-screen controls exist in the
    /// accessibility tree but are never hittable, so they must be revealed
    /// before `click` can reach them. The scroll direction comes from the
    /// frame gap and is flipped whenever a scroll moves the element away or
    /// stalls against an edge, so it makes no sign assumption about
    /// `scroll(byDeltaX:deltaY:)`.
    @MainActor private func reveal(_ element: XCUIElement, identifier: String, in app: XCUIApplication) {
        guard element.exists, !element.isHittable else { return }
        guard let scrollView = app.scrollViews
            .containing(.any, identifier: identifier)
            .allElementsBoundByIndex.last else { return }
        var direction: CGFloat = 1
        var stalled = false
        for _ in 0..<8 {
            guard element.exists, !element.isHittable else { return }
            let viewport = scrollView.frame
            let frame = element.frame
            if viewport.contains(frame) { return }
            scrollView.scroll(byDeltaX: 0, deltaY: direction * (frame.midY - viewport.midY))
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                element.frame != frame
            }, object: nil)
            if XCTWaiter.wait(for: [moved], timeout: 1) != .completed {
                guard !stalled else { return }
                stalled = true
                direction = -direction
                continue
            }
            stalled = false
            if abs(element.frame.midY - viewport.midY) > abs(frame.midY - viewport.midY) {
                direction = -direction
            }
        }
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

    // MARK: - R05 visual matrix

    /// Structured view: env values, `credentials.*` and deeper nested tokens
    /// stay masked even after expanding the tree, while ordinary keys such as
    /// mode/theme remain visible and editable.
    @MainActor func testStructuredMasksNestedCredentialsAndKeepsPlainKeysUsable() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude/settings.json")
        try #"{"credentials":{"inner":{"deep":"FAKE-UI-DEEP"},"token":"FAKE-UI-TOK","value":"FAKE-UI-CRED"},"env":{"API_KEY":"FAKE-UI-SECRET"},"mode":"auto","model":"fixture","theme":"dark"}"#
            .write(to: path, atomically: true, encoding: .utf8)
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("1", modifierFlags: .command)
        let secrets = ["FAKE-UI-CRED", "FAKE-UI-TOK", "FAKE-UI-DEEP", "FAKE-UI-SECRET"]
        for secret in secrets {
            XCTAssertFalse(app.debugDescription.contains(secret), secret)
        }
        // The "credentials" key name is itself sensitive, so the collapsed
        // node renders masked; expanding it must keep every child masked.
        // The chevron glyph sits inside the row element, right of its leading
        // edge: sweep a few horizontal offsets until the triangle toggles.
        let disclosure = app.disclosureTriangles.firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), app.debugDescription)
        app.activate()
        for dx in stride(from: 0.15, through: 0.45, by: 0.05) {
            disclosure.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).click()
            let toggled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (app.disclosureTriangles.firstMatch.value as? Int) == 1
            }, object: nil)
            if XCTWaiter.wait(for: [toggled], timeout: 1.5) == .completed { break }
        }
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (app.disclosureTriangles.firstMatch.value as? Int) == 1
                    || app.staticTexts.matching(
                        NSPredicate(format: "label == %@ OR label == %@", "value", "inner")).count > 0
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed, app.debugDescription)
        for secret in secrets {
            XCTAssertFalse(app.debugDescription.contains(secret), "leaked \(secret)\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.debugDescription.contains("••••••••"), app.debugDescription)
        // Non-sensitive siblings stay visible and editable.
        let theme = app.textFields.matching(NSPredicate(format: "label == %@ OR value == %@", "theme", "dark")).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "label == %@ OR value == %@", "mode", "auto")).firstMatch.exists)
        theme.click(); app.typeKey("a", modifierFlags: .command); theme.typeText("light")
        XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 5))
        clickLabel("Discard", in: app)
        XCTAssertTrue(app.staticTexts["In sync with disk"].waitForExistence(timeout: 5))
    }

    /// MCP matrix + server detail never expose argument values or
    /// credential-bearing URLs — not in labels, values or help text.
    @MainActor func testMcpEndpointsMaskArgsAndCredentialURLs() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude.json")
        let config = #"{"mcpServers":{"arg-srv":{"command":"fake-mcp","args":["--key","FAKE-UI-ARG"],"env":{"API_KEY":"FAKE-UI-ENV"}},"cred-url":{"type":"http","url":"https://user:FAKE-UI-PW@example.com/hook"}}}"#
        try config.write(to: path, atomically: true, encoding: .utf8)
        click("rescan", in: app)
        click("destination-mcp", in: app)
        click("mcp-row:arg-srv", in: app)
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-ARG"), app.debugDescription)
        click("mcp-details", in: app)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), app.debugDescription)
        for secret in ["FAKE-UI-ARG", "FAKE-UI-PW", "FAKE-UI-ENV"] {
            XCTAssertFalse(app.debugDescription.contains(secret), "leaked \(secret)\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.debugDescription.contains("••••••••"), app.debugDescription)
        click("mcp-row:cred-url", in: app)
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-PW"), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), config)
    }

    /// Editable Source: the real-values warning is visible and the original
    /// content stays editable (buffer accepts edits, nothing silently masked).
    @MainActor func testEditableSourceShowsWarningAndStaysEditable() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Source shows real values, including secrets. Edits are saved exactly as entered."]
            .waitForExistence(timeout: 5), app.debugDescription)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("FAKE-UI-SECRET"))
        editor.click(); app.typeKey("a", modifierFlags: .command)
        editor.typeText(#"{"model":"typed-live"}"#)
        XCTAssertTrue((editor.value as? String ?? "").contains("typed-live"))
        XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 5))
        clickLabel("Discard", in: app)
        XCTAssertTrue(app.staticTexts["In sync with disk"].waitForExistence(timeout: 5))
    }

    /// External-change surfaces are always redacted: the diff sheet, the
    /// Activity feed detail, the History compare and the format-only
    /// (markdown) fallback never show the raw secret.
    @MainActor func testExternalChangeSurfacesStayRedacted() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude/settings.json")
        open(".claude/settings.json", home: home, app: app)
        try #"{"env":{"API_KEY":"FAKE-UI-NEW"},"model":"external"}"#
            .write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Modified outside the app"].waitForExistence(timeout: 10), app.debugDescription)
        clickLabel("View diff", in: app)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        for secret in ["FAKE-UI-NEW", "FAKE-UI-SECRET"] {
            XCTAssertFalse(sheet.debugDescription.contains(secret), "diff leaked \(secret)\n\(sheet.debugDescription)")
        }
        XCTAssertTrue(sheet.debugDescription.contains("••••••••"), sheet.debugDescription)
        app.typeKey(.escape, modifierFlags: [])

        click("destination-activity", in: app)
        let event = app.staticTexts["settings.json"].firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5), app.debugDescription)
        event.click()
        let detailSecret = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.debugDescription.contains("••••••••") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [detailSecret], timeout: 5), .completed, app.debugDescription)
        for secret in ["FAKE-UI-NEW", "FAKE-UI-SECRET"] {
            XCTAssertFalse(app.debugDescription.contains(secret), "activity leaked \(secret)")
        }

        // History compare of the external snapshot is masked too.
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("3", modifierFlags: .command)
        if app.popUpButtons["history-version"].waitForExistence(timeout: 5) {
            app.activate()
            let popup = app.popUpButtons["history-version"]
            popup.click()
            // Baseline entries carry the "no semantic changes" summary; popup
            // menu items surface their text as title rather than label.
            let match = NSPredicate(
                format: "label CONTAINS %@ OR title CONTAINS %@",
                "no semantic changes", "no semantic changes")
            let baseline = popup.descendants(matching: .menuItem).matching(match).firstMatch
            if !baseline.waitForExistence(timeout: 2) {
                let alt = app.descendants(matching: .menuItem).matching(match).firstMatch
                XCTAssertTrue(alt.waitForExistence(timeout: 5),
                              "popupItems=\(popup.descendants(matching: .menuItem).allElementsBoundByIndex.map { "\($0.label)|\($0.title)" })")
                alt.click()
            } else { baseline.click() }
        } else {
            XCTAssertTrue(app.staticTexts["base"].firstMatch.waitForExistence(timeout: 5))
            app.staticTexts["base"].firstMatch.click()
        }
        let maskedHistory = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.debugDescription.contains("••••••••") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [maskedHistory], timeout: 5), .completed, app.debugDescription)
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-NEW"), app.debugDescription)

        // Format-only fallback: a markdown file has no structured parse, so
        // line masking applies — the secret line renders as the mask.
        try "# Fixture\n\nToken: FAKE-UI-MD\n".write(
            to: home.appendingPathComponent(".claude/CLAUDE.md"), atomically: true, encoding: .utf8)
        click("rescan", in: app)
        open(".claude/CLAUDE.md", home: home, app: app)
        app.typeKey("1", modifierFlags: .command)
        let heading = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-MD"), app.debugDescription)
        XCTAssertTrue(app.debugDescription.contains("••••••••"), app.debugDescription)
    }

    /// A/B buffers stay independent through a save: committing B writes B's
    /// disk only, while A keeps its draft and its disk content.
    @MainActor func testSavingOneBufferLeavesOtherUntouched() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let aPath = home.appendingPathComponent(".claude/settings.json")
        let bPath = home.appendingPathComponent(".claude/mcp.json")
        let aOriginal = try String(contentsOf: aPath, encoding: .utf8)
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"draft-A"}"#)
        open(".claude/mcp.json", home: home, app: app)
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"draft-B"}"#)
        app.typeKey("s", modifierFlags: .command)
        click("confirm-save", in: app)
        let savedB = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: bPath, encoding: .utf8))?.contains("draft-B") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [savedB], timeout: 5), .completed)
        // A: buffer still dirty with the draft; disk untouched.
        open(".claude/settings.json", home: home, app: app)
        XCTAssertTrue((editor.value as? String ?? "").contains("draft-A"))
        XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: aPath, encoding: .utf8), aOriginal)
    }

    /// Save raced by an external write: the conflict surfaces with both
    /// resolutions — Keep mine writes the draft; Use disk version loads disk.
    @MainActor func testPreDebounceConflictResolvesBothWays() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude/settings.json")
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"mine-one"}"#)
        // External write, then save immediately — before the debounce lands.
        try #"{"model":"disk-one"}"#.write(to: path, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Edit conflict"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Keep mine"].exists && app.buttons["Use disk version"].exists)
        XCTAssertFalse((try String(contentsOf: path, encoding: .utf8)).contains("mine-one"))
        clickLabel("Keep mine", in: app)
        XCTAssertTrue(app.buttons["confirm-save"].waitForExistence(timeout: 5), app.debugDescription)
        click("confirm-save", in: app)
        let wrote = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: path, encoding: .utf8))?.contains("mine-one") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wrote], timeout: 5), .completed)

        // Second round: accept the disk version instead.
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"mine-two"}"#)
        try #"{"model":"disk-two"}"#.write(to: path, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Edit conflict"].waitForExistence(timeout: 5), app.debugDescription)
        clickLabel("Use disk version", in: app)
        let reverted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "disk-two"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [reverted], timeout: 5), .completed,
                       "editor=\(String(describing: editor.value)) conflict=\(app.staticTexts["Edit conflict"].exists)/\(app.staticTexts["Conflict with disk"].exists)\n\(app.debugDescription)")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), #"{"model":"disk-two"}"#)
        XCTAssertTrue(app.staticTexts["In sync with disk"].waitForExistence(timeout: 5))
    }

    /// External-change banner Revert goes through the single restore review;
    /// cancel keeps the disk version, confirm restores the previous content.
    @MainActor func testExternalBannerRevertUsesOneConfirmation() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude/settings.json")
        let original = try String(contentsOf: path, encoding: .utf8)
        open(".claude/settings.json", home: home, app: app)
        try #"{"model":"external-banner"}"#.write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Modified outside the app"].waitForExistence(timeout: 10), app.debugDescription)
        clickLabel("Revert", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "restore-review").firstMatch
            .waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("external-banner"))
        clickLabel("Revert", in: app)
        click("confirm-restore", in: app)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: path, encoding: .utf8)) == original
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
    }

    /// History tab restore uses the same single confirmation; cancel keeps
    /// the current file, confirm writes the selected version to disk.
    @MainActor func testHistoryTabRestoreUsesOneConfirmation() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude/settings.json")
        let original = try String(contentsOf: path, encoding: .utf8)
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"history-v2"}"#)
        app.typeKey("s", modifierFlags: .command)
        click("confirm-save", in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: path, encoding: .utf8))?.contains("history-v2") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)

        app.typeKey("3", modifierFlags: .command)
        // Compact width → version picker; wide → list rows. Pick the oldest
        // (baseline) snapshot either way: its summary is "no semantic changes".
        if app.popUpButtons["history-version"].waitForExistence(timeout: 5) {
            app.activate()
            let popup = app.popUpButtons["history-version"]
            popup.click()
            let match = NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@",
                                    "no semantic changes", "no semantic changes")
            let baseline = popup.descendants(matching: .menuItem).matching(match).firstMatch
            if !baseline.waitForExistence(timeout: 2) {
                let alt = app.descendants(matching: .menuItem).matching(match).firstMatch
                XCTAssertTrue(alt.waitForExistence(timeout: 5), app.debugDescription)
                alt.click()
            } else { baseline.click() }
        } else {
            XCTAssertTrue(app.staticTexts["base"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            app.staticTexts["base"].firstMatch.click()
        }
        clickLabel("Restore this version", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "restore-review").firstMatch
            .waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("history-v2"))
        clickLabel("Restore this version", in: app)
        click("confirm-restore", in: app)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: path, encoding: .utf8)) == original
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
    }

    /// Copying a server with options the destination cannot express is
    /// rejected explicitly; re-adding an existing name warns of replacement.
    @MainActor func testMcpCopyRejectsUnknownOptionsAndReplacementWarns() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let claudePath = home.appendingPathComponent(".claude.json")
        let codexPath = home.appendingPathComponent(".codex/config.toml")
        let claudeConfig = #"{"mcpServers":{"odd":{"command":"fake-mcp","customOption":"x"}}}"#
        let codexOriginal = try String(contentsOf: codexPath, encoding: .utf8)
        try claudeConfig.write(to: claudePath, atomically: true, encoding: .utf8)
        click("rescan", in: app)
        click("destination-mcp", in: app)
        click("mcp-row:odd", in: app)
        click("mcp-details", in: app)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), app.debugDescription)
        app.activate()
        app.menuButtons["Copy here"].firstMatch.click()
        app.menuItems["config.toml"].click()
        let failure = app.staticTexts["MCP operation failed"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5), app.debugDescription)
        let match = NSPredicate(
            format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@",
            "Cannot transfer these MCP options safely",
            "Cannot transfer these MCP options safely",
            "Cannot transfer these MCP options safely")
        let message = app.descendants(matching: .any).matching(match).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5),
                      "alerts=\(app.alerts.count) dialogs=\(app.dialogs.count) sheets=\(app.sheets.count)\n\(app.debugDescription)")
        // The alert's OK is its default button; an app-wide query can hit a
        // Touch Bar twin, so dismiss with Return instead of a raw click.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try String(contentsOf: codexPath, encoding: .utf8), codexOriginal)
        // The details sheet may close together with the alert.
        if app.buttons["Done"].firstMatch.waitForExistence(timeout: 2) {
            clickLabel("Done", in: app)
        }

        // Re-adding an existing name must warn that it replaces the server.
        open(".claude.json", home: home, app: app)
        click("add-mcp", in: app)
        app.textFields["mcp-name"].click(); app.textFields["mcp-name"].typeText("odd")
        app.textFields["mcp-command"].click(); app.textFields["mcp-command"].typeText("fake-two")
        click("review-mcp", in: app)
        XCTAssertTrue(app.staticTexts["This replaces the existing server named odd."]
            .waitForExistence(timeout: 5), app.debugDescription)
        clickLabel("Cancel", in: app)
        XCTAssertEqual(try String(contentsOf: claudePath, encoding: .utf8), claudeConfig)
    }

    /// Empty MCP destination: adding the first server goes through review,
    /// lands in the editor buffer only, and reaches disk after the save review.
    @MainActor func testEmptyMcpMatrixAddReviewApplySave() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let path = home.appendingPathComponent(".claude.json")
        let original = try String(contentsOf: path, encoding: .utf8)
        open(".claude.json", home: home, app: app)
        click("add-mcp", in: app)
        XCTAssertTrue(app.textFields["mcp-name"].waitForExistence(timeout: 5), app.debugDescription)
        app.textFields["mcp-name"].click(); app.textFields["mcp-name"].typeText("first")
        app.textFields["mcp-command"].click(); app.textFields["mcp-command"].typeText("fake-mcp")
        click("add-mcp-argument", in: app)
        app.textFields["mcp-argument-0"].click(); app.textFields["mcp-argument-0"].typeText("--flag")
        click("review-mcp", in: app)
        // Review shows the proposed diff; applying updates only the buffer.
        XCTAssertTrue(app.buttons["apply-mcp"].waitForExistence(timeout: 5), app.debugDescription)
        click("apply-mcp", in: app)
        XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original)
        app.typeKey("s", modifierFlags: .command)
        click("confirm-save", in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: path, encoding: .utf8))?.contains("\"first\"") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        // The persisted structure keeps the argument list intact.
        let disk = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(disk.contains("fake-mcp") && disk.contains("--flag"), disk)
    }

    /// Watcher recovery: deleting a tracked config flips its existence state
    /// and drops its MCP entries; recreating reloads content and the matrix.
    @MainActor func testDeleteAndRecreateRecoversWatcherState() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let settingsPath = home.appendingPathComponent(".claude/settings.json")
        let claudePath = home.appendingPathComponent(".claude.json")
        try #"{"mcpServers":{"watch-srv":{"command":"fake-mcp"}}}"#
            .write(to: claudePath, atomically: true, encoding: .utf8)
        click("rescan", in: app)
        click("destination-mcp", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mcp-row:watch-srv")
            .firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        open(".claude/settings.json", home: home, app: app)
        try FileManager.default.removeItem(at: settingsPath)
        XCTAssertTrue(app.staticTexts["Not found on disk"].waitForExistence(timeout: 10), app.debugDescription)
        try FileManager.default.removeItem(at: claudePath)
        click("destination-mcp", in: app)
        let rowGone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.descendants(matching: .any).matching(identifier: "mcp-row:watch-srv").firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rowGone], timeout: 10), .completed, app.debugDescription)

        // Recreate both: the file reloads and the MCP row comes back.
        try #"{"model":"recreated"}"#.write(to: settingsPath, atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"watch-srv":{"command":"fake-mcp"}}}"#
            .write(to: claudePath, atomically: true, encoding: .utf8)
        let rowBack = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.descendants(matching: .any).matching(identifier: "mcp-row:watch-srv").firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rowBack], timeout: 10), .completed, app.debugDescription)
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let reloaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "recreated"),
                                                 object: app.textViews["source-editor"])
        XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 10), .completed, app.debugDescription)
    }

    // MARK: - R11 integrated scenario

    /// One continuous flow: A/B edits + undo → pre-debounce conflict →
    /// keep mine → banner revert via history → masking on every view →
    /// delete/recreate → MCP add/review/apply/save.
    @MainActor func testIntegratedRepairFlow() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let aPath = home.appendingPathComponent(".claude/settings.json")
        let bPath = home.appendingPathComponent(".claude/mcp.json")
        let aOriginal = try String(contentsOf: aPath, encoding: .utf8)

        // 1) Independent buffers + per-file undo.
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"int-A"}"#)
        open(".claude/mcp.json", home: home, app: app)
        editor.click(); app.typeKey("a", modifierFlags: .command); editor.typeText(#"{"model":"int-B"}"#)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse((editor.value as? String ?? "").contains("int-B"))
        open(".claude/settings.json", home: home, app: app)
        XCTAssertTrue((editor.value as? String ?? "").contains("int-A"))

        // 2) Pre-debounce external write → conflict → keep mine.
        try #"{"model":"int-disk"}"#.write(to: aPath, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Edit conflict"].waitForExistence(timeout: 5), app.debugDescription)
        clickLabel("Keep mine", in: app)
        click("confirm-save", in: app)
        let wrote = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: aPath, encoding: .utf8))?.contains("int-A") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wrote], timeout: 5), .completed)
        XCTAssertFalse(try String(contentsOf: bPath, encoding: .utf8).contains("int-B"))

        // 3) External change → banner revert through the single review.
        try #"{"env":{"API_KEY":"FAKE-UI-LIVE"},"model":"int-ext"}"#
            .write(to: aPath, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Modified outside the app"].waitForExistence(timeout: 10), app.debugDescription)
        clickLabel("Revert", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "restore-review").firstMatch
            .waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(try String(contentsOf: aPath, encoding: .utf8).contains("int-ext"))
        clickLabel("Revert", in: app)
        click("confirm-restore", in: app)
        let reverted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: aPath, encoding: .utf8))?.contains("int-A") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reverted], timeout: 5), .completed)

        // 4) Masking holds on structured/source/history with the new secret.
        try #"{"env":{"API_KEY":"FAKE-UI-LIVE"},"model":"int-ext"}"#
            .write(to: aPath, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Modified outside the app"].waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-LIVE"), app.debugDescription)
        app.typeKey("3", modifierFlags: .command)
        // Pick the baseline snapshot so the compare is non-empty and masked.
        if app.popUpButtons["history-version"].waitForExistence(timeout: 5) {
            app.activate()
            let popup = app.popUpButtons["history-version"]
            popup.click()
            let baseline = app.descendants(matching: .menuItem).matching(NSPredicate(
                format: "label CONTAINS %@ OR title CONTAINS %@",
                "no semantic changes", "no semantic changes")).firstMatch
            if baseline.waitForExistence(timeout: 3) { baseline.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }
        XCTAssertFalse(app.debugDescription.contains("FAKE-UI-LIVE"), app.debugDescription)
        open(".codex/auth.json", agent: "codex", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String ?? "").contains("FAKE-UI-AUTH"))

        // 5) Delete/recreate: existence + reload through the watcher.
        open(".claude/settings.json", home: home, app: app)
        try FileManager.default.removeItem(at: aPath)
        XCTAssertTrue(app.staticTexts["Not found on disk"].waitForExistence(timeout: 10), app.debugDescription)
        try aOriginal.write(to: aPath, atomically: true, encoding: .utf8)
        open(".claude/settings.json", home: home, app: app)
        app.typeKey("2", modifierFlags: .command)
        let reloaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "fixture"),
                                                 object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 10), .completed, app.debugDescription)

        // 6) Empty MCP matrix → add → review → apply → save.
        let oPath = home.appendingPathComponent(".config/opencode/opencode.json")
        open(".config/opencode/opencode.json", agent: "opencode", home: home, app: app)
        click("add-mcp", in: app)
        app.textFields["mcp-name"].click(); app.textFields["mcp-name"].typeText("int-srv")
        app.textFields["mcp-command"].click(); app.textFields["mcp-command"].typeText("fake-mcp")
        click("review-mcp", in: app)
        XCTAssertTrue(app.buttons["apply-mcp"].waitForExistence(timeout: 5), app.debugDescription)
        click("apply-mcp", in: app)
        XCTAssertFalse(try String(contentsOf: oPath, encoding: .utf8).contains("int-srv"))
        app.typeKey("s", modifierFlags: .command)
        click("confirm-save", in: app)
        let mcpSaved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: oPath, encoding: .utf8))?.contains("int-srv") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [mcpSaved], timeout: 5), .completed)
    }

    /// Selectable markdown `Text` may surface as AXTextArea instead of
    /// AXStaticText, so match content by exact label/title/value across all
    /// element types.
    @MainActor private func textElement(_ content: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@",
                                  content, content, content))
            .firstMatch
    }

    /// Markdown preview second delivery: frontmatter card, table, task items,
    /// working Contents menu (scrolls to the tapped heading) and Copy code
    /// writing the exact block text to the pasteboard. Runs against the
    /// isolated fixture app (own home + defaults suite); restores the user's
    /// pasteboard afterwards.
    @MainActor func testMarkdownContentsJumpsAndCopyCodeWritesPasteboard() throws {
        let (app, home, suite) = try fixture(); defer { cleanup(app, home, suite) }
        let priorPasteboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let priorPasteboard {
                NSPasteboard.general.setString(priorPasteboard, forType: .string)
            }
        }
        var doc = """
        ---
        name: fixture-doc
        description: UI fixture frontmatter
        ---

        # Top section

        ```text
        FAKE-CODE-123
        ```

        """
        for index in 0..<60 {
            doc += "Filler paragraph \(index) pushes the bottom section off screen.\n\n"
        }
        // Task items go last: the intent parser merges a following unindented
        // paragraph into the final list item's run, so trailing content here
        // would ride along inside the checked item's accessibility text.
        doc += """
        ## Bottom section

        | Key | Value |
        | --- | ----- |
        | Alpha | 1 |

        - [ ] pending fixture task
        - [x] done fixture task
        """
        try doc.write(to: home.appendingPathComponent(".claude/CLAUDE.md"),
                      atomically: true, encoding: .utf8)
        click("rescan", in: app)
        open(".claude/CLAUDE.md", home: home, app: app)

        // Frontmatter renders as a metadata card; the raw --- fence is gone.
        XCTAssertTrue(textElement("fixture-doc", in: app).waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertTrue(textElement("UI fixture frontmatter", in: app).exists)
        XCTAssertTrue(textElement("done fixture task", in: app).exists, app.debugDescription)

        // Copy code puts the exact code-block text on the pasteboard.
        let copy = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "markdown-copy-code"))
            .firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        app.activate()
        reveal(copy, identifier: copy.identifier, in: app)
        XCTAssertTrue(copy.isHittable)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "FAKE-CODE-123\n")

        // Contents jumps to the matching heading: "Bottom section" starts
        // below the viewport (exists but not hittable) and becomes hittable.
        let bottom = textElement("Bottom section", in: app)
        XCTAssertTrue(bottom.waitForExistence(timeout: 5))
        XCTAssertFalse(bottom.isHittable, "fixture doc should be taller than the viewport")
        click("markdown-contents", in: app)
        let item = app.menuItems
            .matching(NSPredicate(format: "title CONTAINS %@ OR label CONTAINS %@",
                                  "Bottom section", "Bottom section"))
            .firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let revealed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: bottom)
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 5), .completed)
        // After the jump, the table under the bottom heading is on screen.
        XCTAssertTrue(textElement("Alpha", in: app).isHittable)
    }

}
