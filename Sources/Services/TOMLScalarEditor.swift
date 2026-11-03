import Foundation
import TOMLKit

/// Edits one existing scalar token. The native TOML tree supplies types and
/// validates the result; it is never serialized back over the source document.
enum TOMLScalarEditor {
    enum Kind: String { case string, bool, integer, float }

    enum Scalar: Equatable {
        case string(String), bool(Bool), integer(Int64), float(Double)

        var kind: Kind {
            switch self {
            case .string: .string
            case .bool: .bool
            case .integer: .integer
            case .float: .float
            }
        }

        /// Foundation value as `Parsers` produces it, for tree comparisons.
        var native: Any {
            switch self {
            case .string(let value): value
            case .bool(let value): value
            case .integer(let value): Int(value)
            case .float(let value): value
            }
        }

        /// Plain input text, without converting Int64 through Double/JSON.
        var text: String {
            switch self {
            case .string(let value): value
            case .bool(let value): String(value)
            case .integer(let value): String(value)
            case .float(let value): String(value)
            }
        }
    }

    struct Field: Identifiable, Equatable {
        let path: [String]
        let value: Scalar
        var id: [String] { path }
        var label: String { path.map(TOMLScalarEditor.keyLabel).joined(separator: ".") }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidDocument, unsupportedSyntax, unavailableField, typeMismatch, invalidValue, validationFailed

        var errorDescription: String? {
            switch self {
            case .invalidDocument: "This TOML document cannot be edited here. Use Source to correct it."
            case .unsupportedSyntax: "This TOML syntax requires editing in Source."
            case .unavailableField: "This value requires editing in Source."
            case .typeMismatch: "The replacement must keep the existing TOML type."
            case .invalidValue: "Enter a valid value of the existing TOML type."
            case .validationFailed: "The edit could not be validated without changing other TOML values."
            }
        }
    }

    /// Arrays, inline tables, dates/times and non-finite numbers remain in Source.
    /// Array-of-table members have no key-only path and are omitted too.
    static func fields(in text: String) throws -> [Field] {
        try index(text).fields.map(\.field)
    }

    static func replacing(in text: String, path: [String], with replacement: Scalar) throws -> String {
        let indexed = try index(text)
        guard let selected = indexed.fields.first(where: { $0.field.path == path }) else {
            throw Failure.unavailableField
        }
        guard selected.field.value.kind == replacement.kind else { throw Failure.typeMismatch }
        let token = try encode(replacement)
        if sameValue(selected.field.value, replacement) { return text }
        var bytes = Array(text.utf8)
        bytes.replaceSubrange(selected.range, with: token.utf8)
        let result = String(decoding: bytes, as: UTF8.self)
        let actual = try parse(result)

        // Mutate only the expected native node and compare complete native
        // trees. A lexer/path mistake must fail closed, never edit a neighbor.
        var parent = indexed.table
        for key in path.dropLast() {
            guard let child = parent[key]?.table, !child.inline else { throw Failure.validationFailed }
            parent = child
        }
        guard let key = path.last else { throw Failure.unavailableField }
        switch replacement {
        case .string(let value): parent[key] = value
        case .bool(let value): parent[key] = value
        case .integer(let value): parent[key] = Int(value)
        case .float(let value): parent[key] = value
        }
        guard let changed = value(at: path, in: actual).flatMap(scalar),
              sameValue(changed, replacement), indexed.table == actual else { throw Failure.validationFailed }
        return result
    }

    /// Strings accept plain text. Numeric input is parsed in its native type,
    /// and the original type is always fixed by the selected source token.
    static func replacing(in text: String, path: [String], input: String) throws -> String {
        guard let field = try fields(in: text).first(where: { $0.path == path }) else { throw Failure.unavailableField }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement: Scalar
        switch field.value.kind {
        case .string: replacement = .string(input)
        case .bool:
            guard trimmed == "true" || trimmed == "false" else { throw Failure.invalidValue }
            replacement = .bool(trimmed == "true")
        case .integer:
            guard let number = Int64(trimmed) else { throw Failure.invalidValue }
            replacement = .integer(number)
        case .float:
            guard let number = Double(trimmed), number.isFinite else { throw Failure.invalidValue }
            replacement = .float(number)
        }
        return try replacing(in: text, path: path, with: replacement)
    }

    /// An existing array whose items are all strings.
    struct ListField: Identifiable, Equatable {
        let path: [String]
        let values: [String]
        var id: [String] { path }
        var label: String { path.map(TOMLScalarEditor.keyLabel).joined(separator: ".") }
    }

    /// String arrays that can be rewritten in place. Arrays with comments
    /// inside them stay in Source, since rewriting would drop the comments.
    static func stringLists(in text: String) throws -> [ListField] {
        let table = try parse(text)
        var scanner = Scanner(bytes: Array(text.utf8))
        let tokens = try scanner.scan()
        let counts = Dictionary(grouping: tokens, by: \.path).mapValues(\.count)
        return tokens.compactMap { token in
            guard counts[token.path] == 1, scanner.bytes[token.range.lowerBound] == 0x5B,
                  !hasComment(scanner.bytes[token.range]),
                  let array = value(at: token.path, in: table)?.array else { return nil }
            var values: [String] = []
            for index in 0..<array.count {
                guard let item = array[index].string else { return nil }
                values.append(item)
            }
            return ListField(path: token.path, values: values)
        }
    }

    /// Replaces a string array, keeping its single- or multi-line layout.
    static func replacingStringList(in text: String, path: [String], with values: [String]) throws -> String {
        guard try stringLists(in: text).contains(where: { $0.path == path }) else { throw Failure.unavailableField }
        var scanner = Scanner(bytes: Array(text.utf8))
        let tokens = try scanner.scan()
        guard let token = tokens.first(where: { $0.path == path }) else { throw Failure.unavailableField }
        let raw = String(decoding: scanner.bytes[token.range], as: UTF8.self)
        let items = try values.map { try encode(.string($0)) }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let replacement: String
        if raw.contains("\n") && !items.isEmpty {
            let lines: [String] = items.map { item in "  " + item + "," + newline }
            replacement = "[" + newline + lines.joined() + "]"
        } else {
            replacement = "[" + items.joined(separator: ", ") + "]"
        }
        var bytes = scanner.bytes
        bytes.replaceSubrange(token.range, with: Array(replacement.utf8))
        let result = String(decoding: bytes, as: UTF8.self)
        guard var expected = Parsers.parseInBackground(text, format: .toml).tree as? [String: Any] else { throw Failure.invalidDocument }
        setAt(&expected, path.map(Seg.key), values)
        guard (try? parse(result)) != nil,
              let actual = Parsers.parseInBackground(result, format: .toml).tree as? [String: Any],
              NSDictionary(dictionary: actual).isEqual(to: expected) else { throw Failure.validationFailed }
        return result
    }

    /// True when a `#` appears outside string literals.
    private static func hasComment(_ bytes: ArraySlice<UInt8>) -> Bool {
        var quote: UInt8?
        var escaped = false
        for byte in bytes {
            if let q = quote {
                if escaped { escaped = false } else if byte == 0x5C && q == 0x22 { escaped = true } else if byte == q { quote = nil }
            } else if byte == 0x22 || byte == 0x27 { quote = byte } else if byte == 0x23 { return true }
        }
        return false
    }

    /// What a new key holds. Tables become a `[header]`; arrays start empty.
    enum NewValue: Equatable {
        case scalar(Scalar), emptyArray, table
    }

    /// Adds a key that does not exist yet without touching any other byte
    /// of the document: inside its parent's `[table]` section when there is
    /// one, otherwise in a new section at the end, or as a dotted key. Each
    /// candidate is re-parsed and must change exactly that key.
    static func inserting(in text: String, path: [String], value: NewValue) throws -> String {
        guard let key = path.last, !path.contains(where: \.isEmpty) else { throw Failure.unavailableField }
        let table = try parse(text)
        guard self.value(at: path, in: table) == nil else { throw Failure.unavailableField }
        var scanner = Scanner(bytes: Array(text.utf8))
        let tokens = try scanner.scan()
        let parent = Array(path.dropLast())
        let label = path.map(keyLabel).joined(separator: ".")
        let assignment: (String) throws -> String = { lhs in
            switch value {
            case .scalar(let scalar): return lhs + " = " + (try encode(scalar)) + "\n"
            case .emptyArray: return lhs + " = []\n"
            case .table: return ""
            }
        }
        var candidates: [(offset: Int, insert: String)] = []
        if case .table = value {
            candidates.append((scanner.bytes.count, "\n[" + label + "]\n"))
        } else if parent.isEmpty {
            let rootEnd = tokens.filter { $0.header == nil }.map(\.statement.upperBound).max()
            let offset = rootEnd ?? scanner.headers.first?.lineStart ?? scanner.bytes.count
            candidates.append((offset, try assignment(keyLabel(key)) + (rootEnd == nil && !scanner.headers.isEmpty ? "\n" : "")))
        } else {
            if let section = scanner.headers.last(where: { $0.path == parent && !$0.isArray }) {
                candidates.append((section.bodyEnd, try assignment(keyLabel(key))))
            }
            candidates.append((scanner.bytes.count, "\n[" + parent.map(keyLabel).joined(separator: ".") + "]\n"
                               + (try assignment(keyLabel(key)))))
            let rootEnd = tokens.filter { $0.header == nil }.map(\.statement.upperBound).max()
                ?? scanner.headers.first?.lineStart ?? scanner.bytes.count
            candidates.append((rootEnd, try assignment(label)))
        }
        guard var expected = Parsers.parseInBackground(text, format: .toml).tree as? [String: Any] else { throw Failure.invalidDocument }
        switch value {
        case .scalar(let scalar): setAt(&expected, path.map(Seg.key), scalar.native)
        case .emptyArray: setAt(&expected, path.map(Seg.key), [Any]())
        case .table: setAt(&expected, path.map(Seg.key), [String: Any]())
        }
        for candidate in candidates {
            var bytes = scanner.bytes
            var insert = candidate.insert
            if candidate.offset > 0 && bytes[candidate.offset - 1] != 0x0A { insert = "\n" + insert }
            if text.contains("\r\n") { insert = insert.replacingOccurrences(of: "\n", with: "\r\n") }
            bytes.insert(contentsOf: Array(insert.utf8), at: candidate.offset)
            let result = String(decoding: bytes, as: UTF8.self)
            guard (try? parse(result)) != nil,
                  let actual = Parsers.parseInBackground(result, format: .toml).tree as? [String: Any],
                  NSDictionary(dictionary: actual).isEqual(to: expected) else { continue }
            return result
        }
        throw Failure.validationFailed
    }

    /// Removes one single-line `key = value` statement (and its trailing
    /// comment), so the agent falls back to the key's default.
    static func removing(in text: String, path: [String]) throws -> String {
        var scanner = Scanner(bytes: Array(text.utf8))
        let tokens = try scanner.scan()
        let matches = tokens.filter { $0.path == path }
        guard matches.count == 1, let token = matches.first else { throw Failure.unavailableField }
        var bytes = scanner.bytes
        bytes.removeSubrange(token.statement)
        let result = String(decoding: bytes, as: UTF8.self)
        guard var expected = Parsers.parseInBackground(text, format: .toml).tree as? [String: Any] else { throw Failure.invalidDocument }
        removeAt(&expected, path.map(Seg.key))
        guard (try? parse(result)) != nil,
              let actual = Parsers.parseInBackground(result, format: .toml).tree as? [String: Any],
              NSDictionary(dictionary: actual).isEqual(to: expected) else { throw Failure.validationFailed }
        return result
    }

    private struct Token {
        let path: [String]
        let range: Range<Int>
        /// Whole `key = value` line, including its comment and newline.
        var statement: Range<Int> = 0..<0
        /// Index into `Scanner.headers` of the enclosing table, nil at root.
        var header: Int? = nil
    }
    private struct Header {
        let path: [String]
        let isArray: Bool
        /// Start of the header's line and end of its last statement.
        let lineStart: Int
        var bodyEnd: Int
    }
    private struct IndexedField {
        let field: Field
        let range: Range<Int>
    }
    private struct Index {
        let table: TOMLTable
        let fields: [IndexedField]
    }

    private static func parse(_ text: String) throws -> TOMLTable {
        // TOMLKit's C bridge accepts a NUL-terminated string. Reject embedded
        // NUL rather than silently inspecting a truncated document.
        guard text.utf8.count <= Parsers.maximumFileBytes, !text.utf8.contains(0),
              let table = try? TOMLTable(string: text) else { throw Failure.invalidDocument }
        return table
    }

    private static func index(_ text: String) throws -> Index {
        let table = try parse(text)
        var scanner = Scanner(bytes: Array(text.utf8))
        let tokens = try scanner.scan()
        let counts = Dictionary(grouping: tokens, by: \.path).mapValues(\.count)
        var fields: [IndexedField] = []
        for token in tokens where counts[token.path] == 1 {
            guard let native = value(at: token.path, in: table), let value = scalar(native) else { continue }
            let raw = String(decoding: scanner.bytes[token.range], as: UTF8.self)
            // Native strings/keys containing escaped NUL cannot be read
            // faithfully through TOMLKit's String(cString:) accessors.
            if value.kind == .string && containsNULescape(raw) { continue }
            fields.append(.init(field: .init(path: token.path, value: value), range: token.range))
        }
        return Index(table: table, fields: fields)
    }

    private static func value(at path: [String], in table: TOMLTable) -> TOMLValue? {
        guard !path.isEmpty else { return nil }
        var current = table
        for key in path.dropLast() {
            guard let child = current[key]?.table, !child.inline else { return nil }
            current = child
        }
        return current[path.last!]?.tomlValue
    }

    private static func scalar(_ value: TOMLValue) -> Scalar? {
        switch value.type {
        case .string: value.string.map(Scalar.string)
        case .bool: value.bool.map(Scalar.bool)
        case .int: value.int.map { .integer(Int64($0)) }
        case .double: value.double.flatMap { $0.isFinite ? .float($0) : nil }
        default: nil
        }
    }

    private static func sameValue(_ lhs: Scalar, _ rhs: Scalar) -> Bool {
        if case .float(let a) = lhs, case .float(let b) = rhs { return a.bitPattern == b.bitPattern }
        return lhs == rhs
    }

    private static func encode(_ value: Scalar) throws -> String {
        switch value {
        case .string(let string):
            guard !string.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Failure.invalidValue }
            return quoted(string)
        case .float(let number):
            guard number.isFinite else { throw Failure.invalidValue }
            return String(number)
        default: return value.text
        }
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0..<0x20, 0x7F: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func keyLabel(_ value: String) -> String {
        !value.isEmpty && value.utf8.allSatisfy(Scanner.isBareKey) ? value : quoted(value)
    }

    private static func containsNULescape(_ raw: String) -> Bool {
        raw.contains("\\u0000") || raw.contains("\\U00000000")
    }

    /// A source lexer, not a second TOML parser: validity and types come from
    /// TOMLKit. Any syntax it cannot locate unambiguously stays in Source.
    private struct Scanner {
        let bytes: [UInt8]
        var offset = 0
        var tablePath: [String] = []
        var headers: [Header] = []

        mutating func scan() throws -> [Token] {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { offset = 3 }
            var tokens: [Token] = []
            while true {
                skipTrivia()
                guard offset < bytes.count else { return tokens }
                var lineStart = offset
                while lineStart > 0 && isHorizontal(bytes[lineStart - 1]) { lineStart -= 1 }
                if bytes[offset] == 0x5B {
                    offset += 1
                    let array = peek() == 0x5B
                    if array { offset += 1 }
                    tablePath = try key(until: 0x5D)
                    offset += 1
                    if array {
                        guard peek() == 0x5D else { throw Failure.unsupportedSyntax }
                        offset += 1
                    }
                    try finishStatement()
                    headers.append(.init(path: tablePath, isArray: array, lineStart: lineStart, bodyEnd: offset))
                } else {
                    let path = tablePath + (try key(until: 0x3D))
                    offset += 1
                    skipHorizontal()
                    let start = offset
                    try skipValue()
                    var end = offset
                    while end > start && isHorizontal(bytes[end - 1]) { end -= 1 }
                    guard end > start else { throw Failure.unsupportedSyntax }
                    try finishStatement()
                    tokens.append(.init(path: path, range: start..<end, statement: lineStart..<offset,
                                        header: headers.isEmpty ? nil : headers.count - 1))
                    if !headers.isEmpty { headers[headers.count - 1].bodyEnd = offset }
                }
            }
        }

        mutating func key(until terminator: UInt8) throws -> [String] {
            var parts: [String] = []
            while true {
                skipHorizontal()
                let start = offset
                if peek() == 0x22 || peek() == 0x27 {
                    try skipString(multilineAllowed: false)
                    let raw = String(decoding: bytes[start..<offset], as: UTF8.self)
                    guard !TOMLScalarEditor.containsNULescape(raw),
                          let decoded = try? TOMLTable(string: "key = " + raw)["key"]?.string else {
                        throw Failure.unsupportedSyntax
                    }
                    parts.append(decoded)
                } else {
                    while offset < bytes.count && Self.isBareKey(bytes[offset]) { offset += 1 }
                    guard offset > start else { throw Failure.unsupportedSyntax }
                    parts.append(String(decoding: bytes[start..<offset], as: UTF8.self))
                }
                skipHorizontal()
                if peek() == terminator { return parts }
                guard peek() == 0x2E else { throw Failure.unsupportedSyntax }
                offset += 1
            }
        }

        mutating func skipValue() throws {
            guard let first = peek() else { throw Failure.unsupportedSyntax }
            if first == 0x22 || first == 0x27 { try skipString(multilineAllowed: true); return }
            if first == 0x5B || first == 0x7B {
                var closing: [UInt8] = []
                while offset < bytes.count {
                    let byte = bytes[offset]
                    if byte == 0x22 || byte == 0x27 { try skipString(multilineAllowed: true); continue }
                    if byte == 0x23 { skipComment(); continue }
                    if byte == 0x5B { closing.append(0x5D) }
                    else if byte == 0x7B { closing.append(0x7D) }
                    else if byte == 0x5D || byte == 0x7D {
                        guard closing.popLast() == byte else { throw Failure.unsupportedSyntax }
                        offset += 1
                        if closing.isEmpty { return }
                        continue
                    }
                    offset += 1
                }
                throw Failure.unsupportedSyntax
            }
            while let byte = peek(), byte != 0x23 && byte != 0x0A && byte != 0x0D { offset += 1 }
        }

        mutating func skipString(multilineAllowed: Bool) throws {
            guard let quote = peek() else { throw Failure.unsupportedSyntax }
            let triple = offset + 2 < bytes.count && bytes[offset + 1] == quote && bytes[offset + 2] == quote
            guard !triple || multilineAllowed else { throw Failure.unsupportedSyntax }
            offset += triple ? 3 : 1
            while offset < bytes.count {
                let byte = bytes[offset]
                if quote == 0x22 && byte == 0x5C {
                    guard offset + 1 < bytes.count else { throw Failure.unsupportedSyntax }
                    offset += 2
                } else if byte == quote {
                    if !triple { offset += 1; return }
                    var end = offset
                    while end < bytes.count && bytes[end] == quote { end += 1 }
                    let count = end - offset
                    offset = end
                    if count >= 3 { return }
                } else { offset += 1 }
            }
            throw Failure.unsupportedSyntax
        }

        mutating func finishStatement() throws {
            skipHorizontal()
            if peek() == 0x23 { skipComment() }
            guard offset == bytes.count || peek() == 0x0A || peek() == 0x0D else { throw Failure.unsupportedSyntax }
            if peek() == 0x0D { offset += 1 }
            if peek() == 0x0A { offset += 1 }
        }

        mutating func skipTrivia() {
            while let byte = peek() {
                if isHorizontal(byte) || byte == 0x0A || byte == 0x0D { offset += 1 }
                else if byte == 0x23 { skipComment() }
                else { return }
            }
        }
        mutating func skipHorizontal() { while let byte = peek(), isHorizontal(byte) { offset += 1 } }
        mutating func skipComment() { while let byte = peek(), byte != 0x0A && byte != 0x0D { offset += 1 } }
        func peek() -> UInt8? { offset < bytes.count ? bytes[offset] : nil }
        func isHorizontal(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
        static func isBareKey(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2D
        }
    }
}
