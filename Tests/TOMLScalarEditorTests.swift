import Foundation
import Testing
import TOMLKit

extension AgentsConfigTestSuite {
@Suite("TOML scalar edits", .serialized)
struct TOMLScalarEditorTests {
    @Test func editsPreserveOtherBytesCommentsAndNativeTypes() throws {
        let source = "# Configuración 🦊\r\nname   = 'before'  # keep this\r\nenabled = true\r\nlimit = 0xFF\r\nratio = 1e0\r\nwhen = 1979-05-27T07:32:00Z\r\nuntouched = 9_223_372_036_854_775_807\r\n"
        var result = try TOMLScalarEditor.replacing(in: source, path: ["name"], with: .string("after\n\"🦊\""))
        result = try TOMLScalarEditor.replacing(in: result, path: ["enabled"], with: .bool(false))
        result = try TOMLScalarEditor.replacing(in: result, path: ["limit"], with: .integer(9_007_199_254_740_993))
        result = try TOMLScalarEditor.replacing(in: result, path: ["ratio"], with: .float(2.5))
        let expected = "# Configuración 🦊\r\nname   = \"after\\n\\\"🦊\\\"\"  # keep this\r\nenabled = false\r\nlimit = 9007199254740993\r\nratio = 2.5\r\nwhen = 1979-05-27T07:32:00Z\r\nuntouched = 9_223_372_036_854_775_807\r\n"
        #expect(Array(result.utf8) == Array(expected.utf8))
        let native = try TOMLTable(string: result)
        #expect(native["limit"]?.int == 9_007_199_254_740_993)
        #expect(native["untouched"]?.int == Int.max)
        #expect(native["when"]?.type == .dateTime)
        #expect(native["ratio"]?.type == .double)
    }

    @Test func quotedDottedKeysAndTablesSelectExactNativePaths() throws {
        let source = #"""
        "model.name" = "literal"
        model.name = "nested"
        [profiles."qa.\"east"."日本語"] # table comment
        'model.name' = 'profile'
        "api\u004Bey" = "fake fixture"
        """#
        let fields = try TOMLScalarEditor.fields(in: source)
        #expect(fields.map(\.path) == [["model.name"], ["model", "name"],
                                     ["profiles", "qa.\"east", "日本語", "model.name"],
                                     ["profiles", "qa.\"east", "日本語", "apiKey"]])
        #expect(fields.first?.label == "\"model.name\"")
        let result = try TOMLScalarEditor.replacing(in: source,
            path: ["profiles", "qa.\"east", "日本語", "model.name"], input: "changed")
        #expect(result == source.replacingOccurrences(of: "'profile'", with: "\"changed\""))
        let rootResult = try TOMLScalarEditor.replacing(in: source, path: ["model.name"], input: "root")
        let native = try TOMLTable(string: rootResult)
        #expect(native["model.name"]?.string == "root")
        #expect(native["model"]?["name"]?.string == "nested")
    }

    @Test func multilineStringsArraysAndCommentsDoNotCreateAssignments() throws {
        let source = #"""
        script = """
        fake = 1
        [profiles.fake]
        escaped = \"\"\"
        """
        literal = '''
        fake = 2
        [profiles.other]
        '''
        values = [
          "fake = 3", # target = 900
          { nested = "[profiles.third]", enabled = true },
          """fake = 4
        [profiles.fourth]"""
        ]
        # target = 901
        target = 5 # real assignment
        """#
        #expect(try TOMLScalarEditor.fields(in: source).map(\.path) == [["script"], ["literal"], ["target"]])
        let result = try TOMLScalarEditor.replacing(in: source, path: ["target"], with: .integer(6))
        #expect(result == source.replacingOccurrences(of: "target = 5 # real", with: "target = 6 # real"))
    }

    @Test func multilineClosingQuoteRunsPreserveFollowingStatements() throws {
        for quote in ["\"", "'"] {
            for count in 3...5 {
                let source = "message = " + String(repeating: quote, count: 3) + "line"
                    + String(repeating: quote, count: count) + "\ntarget = 1\n"
                let fields = try TOMLScalarEditor.fields(in: source)
                #expect(fields.first?.value == .string("line" + String(repeating: quote, count: count - 3)))
                let result = try TOMLScalarEditor.replacing(in: source, path: ["target"], input: "2")
                #expect(result == source.replacingOccurrences(of: "target = 1", with: "target = 2"))
            }
        }
    }

    @Test func arraysInlineTablesDatesAndArrayTablesStayInSource() throws {
        let source = """
        root = 1
        date = 1979-05-27
        time = 07:32:00
        offset = 1979-05-27T07:32:00-08:00
        values = [1, "two", { enabled = true }]
        inline = { count = 2 }
        [[entries]]
        name = "one"
        [[entries]]
        name = "two"
        [after]
        enabled = true
        """
        #expect(try TOMLScalarEditor.fields(in: source).map(\.path) == [["root"], ["after", "enabled"]])
        for path in [["date"], ["time"], ["offset"], ["values"], ["inline", "count"], ["entries", "name"]] {
            #expect(throws: TOMLScalarEditor.Failure.unavailableField) {
                try TOMLScalarEditor.replacing(in: source, path: path, input: "changed")
            }
        }
        let result = try TOMLScalarEditor.replacing(in: source, path: ["root"], input: "9223372036854775807")
        let native = try TOMLTable(string: result)
        #expect(native["root"]?.int == Int.max)
        #expect(native["date"]?.type == .date && native["time"]?.type == .time && native["offset"]?.type == .dateTime)
        #expect(native["entries"]?.array?.count == 2)
        #expect(result == source.replacingOccurrences(of: "root = 1", with: "root = 9223372036854775807"))
    }

    @Test func numericInputKeepsNativePrecisionAndType() throws {
        let source = "integer = -9223372036854775808\nfloating = 1.0\n"
        let fields = try TOMLScalarEditor.fields(in: source)
        #expect(fields.first?.value == .integer(Int64.min))
        #expect(fields.first?.value.text == "-9223372036854775808")
        let changed = try TOMLScalarEditor.replacing(in: source, path: ["integer"], input: "9223372036854775807")
        #expect(try TOMLTable(string: changed)["integer"]?.int == Int.max)
        let floating = try TOMLScalarEditor.replacing(in: source, path: ["floating"], input: "2")
        #expect(floating.contains("floating = 2.0"))
        #expect(try TOMLTable(string: floating)["floating"]?.type == .double)
        #expect(throws: TOMLScalarEditor.Failure.invalidValue) {
            try TOMLScalarEditor.replacing(in: source, path: ["integer"], input: "9223372036854775808")
        }
        #expect(throws: TOMLScalarEditor.Failure.invalidValue) {
            try TOMLScalarEditor.replacing(in: source, path: ["integer"], input: "1.5")
        }
        #expect(throws: TOMLScalarEditor.Failure.typeMismatch) {
            try TOMLScalarEditor.replacing(in: source, path: ["integer"], with: .float(1.0))
        }
    }

    @Test func stringsEscapeControlsAndCannotInjectOtherSettings() throws {
        let source = "message = 'before'\nkeep = true # stable\n"
        let input = "\"\n[evil]\nkey = false\n\\backslash\t\u{1F}\u{7F}🦊"
        let result = try TOMLScalarEditor.replacing(in: source, path: ["message"], input: input)
        let table = try TOMLTable(string: result)
        #expect(table["message"]?.string == input)
        #expect(table["evil"] == nil)
        #expect(result.hasSuffix("\nkeep = true # stable\n"))
        #expect(throws: TOMLScalarEditor.Failure.invalidValue) {
            try TOMLScalarEditor.replacing(in: source, path: ["message"], input: "embedded\0NUL")
        }
    }

    @Test func nonfiniteAndNULStringsRemainUntouched() throws {
        let source = #"integer = 1"# + "\n" + #"nan = nan"# + "\n" + #"infinity = +inf"# + "\n" + #"text = "prefix\u0000suffix""# + "\n"
        #expect(try TOMLScalarEditor.fields(in: source).map(\.path) == [["integer"]])
        #expect(try TOMLScalarEditor.replacing(in: source, path: ["integer"], input: "2")
                == source.replacingOccurrences(of: "integer = 1", with: "integer = 2"))
        #expect(throws: TOMLScalarEditor.Failure.invalidValue) {
            try TOMLScalarEditor.replacing(in: "value = 1.0", path: ["value"], input: "nan")
        }
    }

    @Test func invalidDocumentsMissingKeysAndNullBytesAreRejected() throws {
        for source in ["key = 1\nkey = 2", "key = [", "key = 1\0ignored = 2", String(repeating: "#", count: Parsers.maximumFileBytes + 1)] {
            #expect(throws: TOMLScalarEditor.Failure.invalidDocument) { try TOMLScalarEditor.fields(in: source) }
        }
        #expect(throws: TOMLScalarEditor.Failure.unavailableField) {
            try TOMLScalarEditor.replacing(in: "exists = true", path: ["missing"], input: "false")
        }
        #expect(throws: TOMLScalarEditor.Failure.invalidValue) {
            try TOMLScalarEditor.replacing(in: "exists = true", path: ["exists"], input: "1")
        }
    }

    @Test func noOpPreservesLiteralAndNumericSpellingAndNegativeZeroCanChange() throws {
        let source = "literal = 'same'\nnumber = 0xFF\nfloating = -0.0\n"
        #expect(try TOMLScalarEditor.replacing(in: source, path: ["literal"], input: "same") == source)
        #expect(try TOMLScalarEditor.replacing(in: source, path: ["number"], input: "255") == source)
        let result = try TOMLScalarEditor.replacing(in: source, path: ["floating"], with: .float(0.0))
        #expect(result == source.replacingOccurrences(of: "-0.0", with: "0.0"))
    }
}
}
