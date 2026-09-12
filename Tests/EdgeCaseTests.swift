import Testing
import Foundation

/// F10 "additional checks": numeric edge cases in the structured editor and
/// the TOML round-trip's documented type/precision limits.
extension AgentsConfigTestSuite {
@Suite("Edge cases", .serialized)
@MainActor
struct EdgeCaseTests {

    @Test func integerLimitsRemainExact() throws {
        for value in [Int.min, Int.min + 1, -9_007_199_254_740_993,
                      9_007_199_254_740_993, Int.max - 1, Int.max] {
            let parsed = try #require(NodeRow.parseNumber(String(value)) as? Int)
            #expect(parsed == value)
            let json = try #require(Parsers.serializeJSON(["number": parsed]))
            let tree = try #require(Parsers.parse(json, format: .json).tree as? [String: Any])
            #expect((tree["number"] as? NSNumber)?.int64Value == Int64(value))
        }
    }

    @Test func maximumIntegerDoesNotTrap() {
        #expect(NodeRow.parseNumber("9223372036854775807") as? Int == Int.max)
    }

    @Test func outsideIntegerRangeUsesFiniteDouble() {
        for text in ["9223372036854775808", "-9223372036854775809", "1e300",
                     "1.5", "42.0", "42e0"] {
            #expect(NodeRow.parseNumber(text) as? Double == Double(text))
        }
        for text in ["NaN", "Infinity", "-inf", "1e309", "", "-"] {
            #expect(NodeRow.parseNumber(text) == nil)
        }
    }

    /// Repro: `Int(d)` trapped on non-finite or out-of-range doubles.
    @Test func numberFieldNeverCrashesOnExtremes() {
        // non-finite / non-numeric → rejected, no mutation
        #expect(NodeRow.parseNumber("inf") == nil)
        #expect(NodeRow.parseNumber("nan") == nil)
        #expect(NodeRow.parseNumber("abc") == nil)

        // plain integers → Int
        #expect(NodeRow.parseNumber("42") as? Int == 42)
        #expect(NodeRow.parseNumber("-7") as? Int == -7)

        // decimals / scientific / huge → Double, never trapped
        #expect(NodeRow.parseNumber("1.5") as? Double == 1.5)
        #expect(NodeRow.parseNumber("1e300") as? Double == 1e300)
        #expect(NodeRow.parseNumber("9999999999999999999999") as? Double
                == 1e22)
        // huge integral text must NOT go through Int(d) — it would trap
        #expect(!(NodeRow.parseNumber("9999999999999999999999") is Int))
    }

    /// Pins down the documented TOML limitation: datetimes and exotic
    /// numerics do not survive a parse → reserialize round-trip with their
    /// TOML type intact — MCP copy to Codex shares this path, which is why
    /// it requires explicit user review before saving.
    @Test func tomlRoundTripTypeLimitsArePinned() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let src = """
        when = 1979-05-27T07:32:00Z
        big = 9223372036854775807
        name = "ok"
        """
        let parsed = Parsers.parse(src, format: .toml)
        let tree = try #require(parsed.tree as? [String: Any])
        let out = try #require(Parsers.serializeTOML(tree))
        let round = try #require(
            Parsers.parse(out, format: .toml).tree as? [String: Any])

        // strings survive verbatim
        #expect(round["name"] as? String == "ok")
        // datetime survives only as a *string*, not a TOML datetime —
        // pinned so any future fix flips this expectation deliberately
        let when = round["when"]
        #expect(!(when is NSDate) && !(when is Date))
        // big integer stays readable as a number (may lose precision as
        // Double — documented loss, never a crash)
        #expect(round["big"] is NSNumber)
    }
}

}
