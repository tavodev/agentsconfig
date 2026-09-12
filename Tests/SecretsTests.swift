import Testing
import Foundation

/// F5: secret masking must be consistent across text masking, structured
/// view detection and diffs — no variant leaks its value anywhere.
extension AgentsConfigTestSuite {
@Suite("Secret masking", .serialized)
@MainActor
struct SecretsTests {

    private let masked = "••••••••"

    @Test func embeddedCredentialURLsAndBrokenEscapedKeysAreHidden() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let command = "curl https://demo:FAKE-PASS@example.test/mcp"
        #expect(Secrets.displayText(command) == masked)
        let broken = #"{"credent\u0069als":{"value":"FAKE-BROKEN""#
        let changes = DiffEngine.lineDiff(oldText: broken, newText: broken.replacingOccurrences(of: "FAKE-", with: "NEW-"))
        #expect(changes.allSatisfy { !($0.oldValue ?? "").contains("FAKE-") && !($0.newValue ?? "").contains("NEW-") })
    }

    @Test func presentationPolicyDoesNotMutateSavedValues() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let text = #"{"credentials":{"value":"FAKE-PRIVATE"},"env":{"API_KEY":"FAKE-ENV"},"theme":"dark"}"#
        try env.installClaude(settingsJSON: text)
        let store = env.makeStore()
        let path = env.path(".claude/settings.json")
        let tree = try #require(Parsers.parse(text, format: .json).tree as? [String: Any])
        #expect(Secrets.isSensitive("FAKE-PRIVATE", path: "credentials.value"))
        #expect(Secrets.isSensitive("FAKE-ARRAY", path: "tokens[0].value"))
        #expect(Secrets.isSensitive("FAKE-ARG", path: "mcp.server.args[1]"))
        #expect(!Secrets.isSensitive("dark", path: "theme"))
        #expect(Secrets.mcpEndpoint(["command": ["fake-command", "positional-credential"]]) == "fake-command \(masked)")
        #expect(Secrets.mcpEndpoint(["command": "fake-command", "args": ["positional-credential"]], masking: false).contains("positional-credential"))
        _ = Secrets.redacted(tree)
        var edited = tree
        edited["theme"] = "light"
        store.updateEdit(path: path, text: try #require(Parsers.serializeJSON(edited)))
        store.save(path: path)
        #expect(store.saveErrors[path] == nil)
        #expect(try env.read(".claude/settings.json").contains("FAKE-PRIVATE"))
        #expect(try !env.read(".claude/settings.json").contains(masked))
    }

    @Test func formattingOnlyJSONDiffHidesEscapedSecret() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let text = #"{"api\u004bey":"FAKE-FORMAT","theme":"dark"}"#
        let formatted = "\n" + text + "\n"
        let tree = Parsers.parse(text, format: .json).tree
        let changes = DiffEngine.diff(oldText: text, newText: formatted, oldTree: tree, newTree: tree)
        #expect(changes.allSatisfy { !($0.oldValue ?? "").contains("FAKE-FORMAT") && !($0.newValue ?? "").contains("FAKE-FORMAT") })
    }

    @Test func contextContainersEscapesAndEndpointsArePrivate() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let text = #"{"credentials":{"value":"FAKE-CRED"},"tokens":[{"value":"FAKE-ARRAY"}],"env":{"API_KEY":"FAKE-ENV"},"headers":{"Authorization":"FAKE-HEADER"},"url":"https://user:FAKE-PASS@example.test/mcp?api_key=FAKE-QUERY","args":["--token","FAKE-ARG"],"api\u004bey":"FAKE-ESCAPE","theme":"dark"}"#
        let out = Secrets.maskText(text, format: .json)
        for marker in ["FAKE-CRED", "FAKE-ARRAY", "FAKE-ENV", "FAKE-HEADER", "FAKE-PASS", "FAKE-QUERY", "FAKE-ARG", "FAKE-ESCAPE"] {
            #expect(!out.contains(marker))
        }
        #expect(out.contains("dark"))
        let next = text.replacingOccurrences(of: "FAKE-", with: "NEW-")
        let changes = DiffEngine.diff(oldText: text, newText: next,
            oldTree: Parsers.parse(text, format: .json).tree,
            newTree: Parsers.parse(next, format: .json).tree)
        #expect(changes.allSatisfy { !($0.oldValue ?? "").contains("FAKE-") && !($0.newValue ?? "").contains("NEW-") })
    }

    @Test func multilineQuotedTomlAndInvalidJSONAreConservativelyHidden() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let toml = "[credentials]\nvalue = \"\"\"FAKE-FIRST\nFAKE-SECOND\"\"\"\n[env]\n\"API_KEY\" = 'FAKE-QUOTED'\n"
        #expect(!Secrets.maskText(toml, format: .toml).contains("FAKE-"))
        let invalid = "{\"credentials\": {\n\"value\": \"FAKE-BROKEN\""
        #expect(!Secrets.maskText(invalid, format: .json).contains("FAKE-"))
        let changes = DiffEngine.lineDiff(oldText: toml, newText: toml.replacingOccurrences(of: "FAKE-", with: "NEW-"))
        #expect(changes.allSatisfy { !($0.oldValue ?? "").contains("FAKE-") && !($0.newValue ?? "").contains("NEW-") })
    }

    @Test func diffCreatedWhileMaskingIsOffNeverCachesSecrets() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        AppSettings.defaults.set(false, forKey: "maskSecrets")
        let changes = DiffEngine.lineDiff(oldText: "API_KEY=FAKE-OLD", newText: "API_KEY=FAKE-NEW")
        AppSettings.defaults.set(true, forKey: "maskSecrets")
        #expect(changes.allSatisfy { !($0.oldValue ?? "").contains("FAKE-") && !($0.newValue ?? "").contains("FAKE-") })
    }

    @Test func jsonMaskingCoversAllKeyVariants() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let text = """
        {"apiKey":"sk-1","access_key":"ak-2","Authorization":"Bearer t-3",
         "private_key":"pk-4","client_secret":"cs-5","theme":"dark","nested":
         {"db":{"password":"pw-6"}}}
        """
        let out = Secrets.maskText(text, format: .json)
        for secret in ["sk-1", "ak-2", "t-3", "pk-4", "cs-5", "pw-6"] {
            #expect(!out.contains(secret), "leaked \(secret)")
        }
        #expect(out.contains("\"dark\""))       // non-secret values untouched
        #expect(out.contains("apiKey"))         // key names stay visible
    }

    @Test func tomlMaskingCoversAllKeyVariants() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let text = """
        access_key = "ak-1"
        authorization = "Bearer t-1"
        refresh_token = 'rt-1'
        model = "gpt-fake"
        """
        let out = Secrets.maskText(text, format: .toml)
        for secret in ["ak-1", "t-1", "rt-1"] {
            #expect(!out.contains(secret), "leaked \(secret)")
        }
        #expect(out.contains("gpt-fake"))
    }

    @Test func shellMaskingCoversExports() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let text = """
        export API_TOKEN=abc123
        DB_PASSWORD="pw-9"
        echo hello
        """
        let out = Secrets.maskText(text, format: .shell)
        #expect(!out.contains("abc123"))
        #expect(!out.contains("pw-9"))
        #expect(out.contains("echo hello"))
    }

    /// Repro: a semantic diff used to embed raw secret values in
    /// oldValue/newValue — shown in DiffSheet, CompareView and history.
    @Test func semanticDiffMasksSecretLeafValues() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let oldTree = Parsers.parse(#"{"apiKey":"sk-old","theme":"a"}"#, format: .json).tree
        let newTree = Parsers.parse(#"{"apiKey":"sk-new","theme":"b"}"#, format: .json).tree
        let changes = DiffEngine.diff(oldText: "", newText: "",
                                      oldTree: oldTree, newTree: newTree)
        let api = try #require(changes.first { $0.keyPath == "apiKey" })
        #expect(api.oldValue?.contains("sk-old") == false)
        #expect(api.newValue?.contains("sk-new") == false)
        #expect(api.newValue?.contains(masked) == true)
        // non-secret leaf keeps real values
        let theme = try #require(changes.first { $0.keyPath == "theme" })
        #expect(theme.oldValue == #""a""#)
        #expect(theme.newValue == #""b""#)
    }

    /// Repro: the line-diff fallback embedded whole raw lines, secrets and all.
    @Test func lineDiffMasksSecretLines() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let old = "{\n  \"apiKey\": \"sk-old\"\n}"
        let new = "{\n  \"apiKey\": \"sk-new\"\n}"
        let changes = DiffEngine.lineDiff(oldText: old, newText: new)
        for c in changes {
            for v in [c.oldValue, c.newValue].compactMap({ $0 }) {
                #expect(!v.contains("sk-old"))
                #expect(!v.contains("sk-new"))
            }
        }
    }

    /// Nested/array key paths are masked by their leaf key, and
    /// non-secret sibling keys still show values.
    @Test func nestedAndIndexedSecretsAreMasked() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let old = #"{"env":{"API_KEY":"sk-1"},"tokens":["t-1"]}"#
        let new = #"{"env":{"API_KEY":"sk-2"},"tokens":["t-2"],"name":"x"}"#
        let changes = DiffEngine.diff(
            oldText: old, newText: new,
            oldTree: Parsers.parse(old, format: .json).tree,
            newTree: Parsers.parse(new, format: .json).tree)
        let all = changes.flatMap { [$0.oldValue, $0.newValue].compactMap { $0 } }
        for s in ["sk-1", "sk-2", "t-1", "t-2"] {
            #expect(!all.contains { $0.contains(s) }, "leaked \(s)")
        }
        #expect(changes.contains { $0.keyPath == "name" && $0.newValue == #""x""# })
    }
}

}
