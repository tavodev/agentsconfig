import Foundation

enum DiffEngine {

    /// Semantic diff between two parsed trees. Falls back to line diff when
    /// either side is nil or when trees are scalars/text.
    static func diff(oldText: String, newText: String, oldTree: Any?, newTree: Any?) -> [SemanticChange] {
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
        switch (old, new) {
        case let (o as [String: Any], n as [String: Any]):
            for key in unionKeys(o, n) {
                let child = path.isEmpty ? key : "\(path).\(key)"
                switch (o[key], n[key]) {
                case let (ov?, nv?):
                    walk(old: ov, new: nv, path: child, into: &out)
                case (.none, .some(let nv)):
                    out.append(.init(keyPath: child, kind: .added, oldValue: nil, newValue: display(nv)))
                case (.some(let ov), .none):
                    out.append(.init(keyPath: child, kind: .removed, oldValue: display(ov), newValue: nil))
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
                    out.append(.init(keyPath: child, kind: .added, oldValue: nil, newValue: display(nv)))
                case (.some(let ov), .none):
                    out.append(.init(keyPath: child, kind: .removed, oldValue: display(ov), newValue: nil))
                case (.none, .none):
                    break
                }
            }
        default:
            if !scalarEqual(old, new) {
                out.append(.init(keyPath: path.isEmpty ? "(root)" : path, kind: .modified,
                                 oldValue: display(old), newValue: display(new)))
            }
        }
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
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)
        var out: [SemanticChange] = []
        for change in diff {
            switch change {
            case .remove(let offset, let element, _):
                out.append(.init(keyPath: "L\(offset + 1)", kind: .removed,
                                 oldValue: element, newValue: nil))
            case .insert(let offset, let element, _):
                out.append(.init(keyPath: "L\(offset + 1)", kind: .added,
                                 oldValue: nil, newValue: element))
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
    static func summary(_ changes: [SemanticChange]) -> String {
        let a = changes.filter { $0.kind == .added }.count
        let r = changes.filter { $0.kind == .removed }.count
        let m = changes.filter { $0.kind == .modified }.count
        var parts: [String] = []
        if a > 0 { parts.append("+\(a)") }
        if m > 0 { parts.append("~\(m)") }
        if r > 0 { parts.append("−\(r)") }
        return parts.isEmpty ? L("no semantic changes") : parts.joined(separator: "  ")
    }
}
