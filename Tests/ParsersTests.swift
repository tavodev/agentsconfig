import Testing
import Foundation


/// Pure parser checks — no global state, safe to run in parallel.
extension AgentsConfigTestSuite {
@Suite("Parsers")
@MainActor
struct ParsersTests {
    @Test func jsoncTrailingCommasDoNotAlterQuotedContent() throws {
        let text = #"{"list":["literal,]",], "url":"https://example.test/a,}",}"#
        let root = try #require(Parsers.parse(text, format: .jsonc).tree as? [String: Any])
        #expect(root["list"] as? [String] == ["literal,]"])
        #expect(root["url"] as? String == "https://example.test/a,}")
        #expect(Parsers.parse("{\"bad\":[1,,2]}", format: .jsonc).error != nil)
    }


    @Test func jsonRoundTrip() {
        let text = "{\"a\":1,\"b\":{\"c\":\"x\"}}"
        let (tree, error) = Parsers.parse(text, format: .json)
        #expect(error == nil)
        let dict = tree as? [String: Any]
        #expect(dict?["a"] as? Int == 1)
        #expect(Parsers.serializeJSON(dict!) != nil)
    }

    @Test func jsoncStripsComments() {
        let text = """
        {
            // line comment
            "a": /* inline */ 1,
            "url": "https://x.y/z"  // not a comment
        }
        """
        let (tree, error) = Parsers.parse(text, format: .jsonc)
        #expect(error == nil)
        let dict = tree as? [String: Any]
        #expect(dict?["a"] as? Int == 1)
        #expect(dict?["url"] as? String == "https://x.y/z")
    }

    @Test func tomlParsesToTree() {
        let text = """
        model = "gpt-fake"
        [mcp_servers.docs]
        command = "npx"
        """
        let (tree, error) = Parsers.parse(text, format: .toml)
        #expect(error == nil)
        let dict = tree as? [String: Any]
        #expect(dict?["model"] as? String == "gpt-fake")
        #expect((dict?["mcp_servers"] as? [String: Any])?["docs"] != nil)
    }

    @Test func invalidJSONReportsError() {
        let (_, error) = Parsers.parse("{ nope", format: .json)
        #expect(error != nil)
    }
}

}
