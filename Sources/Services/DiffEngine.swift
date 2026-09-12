import Foundation

@MainActor enum DiffEngine {

    /// Semantic diff between two parsed trees. Falls back to line diff when
    /// either side is nil or when trees are scalars/text.
    static func diff(oldText: String, newText: String, oldTree: Any?, newTree: Any?) -> [SemanticChange] {
        guard oldText.utf8.count <= Parsers.maximumFileBytes,
              newText.utf8.count <= Parsers.maximumFileBytes else {
            return [.init(keyPath: L("Large diff omitted"), kind: .modified, oldValue: nil, newValue: nil)]
        }
        if let oldTree, let newTree {
            var changes: [SemanticChange] = []
            walk(old: oldTree, new: newTree, path: "", into: &changes)
            if changes.isEmpty && oldText != newText {
                // identical trees but different text (formatting, comments)
                return lineDiff(oldText: oldText, newText: newText)
            }
            return cap(changes)
        }
        return lineDiff(oldText: oldText, newText: newText)
    }

    private static func walk(old: Any, new: Any, path: String, into out: inout [SemanticChange]) {
        guard out.count < 500 else { return }
        switch (old, new) {
        case let (o as [String: Any], n as [String: Any]):
            for key in unionKeys(o, n) {
                let child = path.isEmpty ? key : "\(path).\(key)"
                switch (o[key], n[key]) {
                case let (ov?, nv?):
                    walk(old: ov, new: nv, path: child, into: &out)
                case (.none, .some(let nv)):
                    emit(&out, path: child, kind: .added, old: nil, new: nv)
                case (.some(let ov), .none):
                    emit(&out, path: child, kind: .removed, old: ov, new: nil)
                case (.none, .none):
                    break
                }
            }
        case let (o as [Any], n as [Any]):
            let maxCount = max(o.count, n.count)
            for i in 0..<maxCount {
                let child = "\(path)[\(i)]"
                switch (i < o.count ? o[i] : nil, i < n.count ? n[i] : nil) {
                case let (ov?, nv?):
                    walk(old: ov, new: nv, path: child, into: &out)
                case (.none, .some(let nv)):
                    emit(&out, path: child, kind: .added, old: nil, new: nv)
                case (.some(let ov), .none):
                    emit(&out, path: child, kind: .removed, old: ov, new: nil)
                case (.none, .none):
                    break
                }
            }
        default:
            if !scalarEqual(old, new) {
                let p = path.isEmpty ? "(root)" : path
                emit(&out, path: p, kind: .modified, old: old, new: new)
            }
        }
    }

    /// Diffs are always safe to cache, including while masking is disabled.
    private static func emit(_ out: inout [SemanticChange], path: String,
                             kind: SemanticChange.Kind, old: Any?, new: Any?) {
        out.append(.init(keyPath: path, kind: kind,
                         oldValue: old.map { display(Secrets.redacted($0, path: path)) },
                         newValue: new.map { display(Secrets.redacted($0, path: path)) }))
    }

    private static func unionKeys(_ a: [String: Any], _ b: [String: Any]) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for k in a.keys where seen.insert(k).inserted { keys.append(k) }
        for k in b.keys where seen.insert(k).inserted { keys.append(k) }
        return keys
    }

    private static func scalarEqual(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull && b is NSNull { return true }
        if let na = a as? NSNumber, let nb = b as? NSNumber {
            // NSNumber bridges bool & number — compare via objCType + value
            if na === nb { return true }
            if CFGetTypeID(na) == CFBooleanGetTypeID() || CFGetTypeID(nb) == CFBooleanGetTypeID() {
                return na.boolValue == nb.boolValue && CFGetTypeID(na) == CFGetTypeID(nb)
            }
            return na == nb
        }
        if let sa = a as? String, let sb = b as? String { return sa == sb }
        return (a as AnyObject).isEqual(b)
    }

    /// Compact display for a value (scalar → literal, container → summary).
    static func display(_ v: Any) -> String {
        switch v {
        case is NSNull: return "null"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let s as String: return "\"\(s)\""
        case let a as [Any]: return "[\(a.count) elementos]"
        case let d as [String: Any]: return "{\(d.count) keys}"
        default: return String(describing: v)
        }
    }

    /// Line-level fallback: produces added/removed entries per contiguous hunk.
    static func lineDiff(oldText: String, newText: String) -> [SemanticChange] {
        // Full-document context protects continuation lines under sensitive
        // tables/arrays, even when the changed line has only a generic key.
        let hideLines = Secrets.containsSecrets(oldText, format: .text)
            || Secrets.containsSecrets(newText, format: .text)
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        guard oldLines.count <= 2_000, newLines.count <= 2_000 else {
            return [.init(keyPath: L("Large diff omitted"), kind: .modified, oldValue: nil, newValue: nil)]
        }
        let diff = newLines.difference(from: oldLines)
        var out: [SemanticChange] = []
        for change in diff {
            switch change {
            case .remove(let offset, let element, _):
                out.append(.init(keyPath: "L\(offset + 1)", kind: .removed,
                                 oldValue: hideLines ? Secrets.maskedValue : Secrets.maskLine(element), newValue: nil))
            case .insert(let offset, let element, _):
                out.append(.init(keyPath: "L\(offset + 1)", kind: .added,
                                 oldValue: nil, newValue: hideLines ? Secrets.maskedValue : Secrets.maskLine(element)))
            }
        }
        return cap(out)
    }

    private static func cap(_ changes: [SemanticChange]) -> [SemanticChange] {
        if changes.count > 500 { return Array(changes.prefix(500)) }
        return changes
    }

    /// Short human summary like "+3 · −1 · ~2".
    @MainActor
    static func summary(_ changes: [SemanticChange]) -> String { L(storageSummary(changes)) }

    nonisolated static func storageSummary(_ changes: [SemanticChange]) -> String {
        let a = changes.filter { $0.kind == .added }.count
        let r = changes.filter { $0.kind == .removed }.count
        let m = changes.filter { $0.kind == .modified }.count
        var parts: [String] = []
        if a > 0 { parts.append("+\(a)") }
        if m > 0 { parts.append("~\(m)") }
        if r > 0 { parts.append("−\(r)") }
        return parts.isEmpty ? "no semantic changes" : parts.joined(separator: "  ")
    }
}
