import Foundation

/// How the sidebar lays out global agents. Pure: the view passes the agents
/// and the persisted preferences, tests check the result without UI.
enum SidebarGrouping {
    enum Mode: String, CaseIterable { case product, kind, flat }

    enum Kind: Int, CaseIterable, Comparable {
        case editable, inventory, orca
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .editable: "Configurable agents"
            case .inventory: "Read-only inventory"
            case .orca: "Orca accounts"
            }
        }
    }

    /// One top-level row: an agent plus the agents nested under it.
    struct Group: Identifiable, Equatable {
        var agentID: String
        var children: [String] = []
        var id: String { agentID }
    }

    struct Section: Identifiable, Equatable {
        var kind: Kind?          // nil: a single untitled section
        var groups: [Group]
        var id: String { kind.map { "\($0.rawValue)" } ?? "all" }
    }

    /// Inventory-only products (no MCP destination, every source read-only).
    static let inventoryIDs: Set<String> = ["cursor", "copilot-cli", "windsurf", "claude-desktop"]

    static func family(_ id: String) -> String { OrcaIntegration.baseAgentID(id) }

    static func kind(_ id: String) -> Kind {
        if OrcaIntegration.isOrcaAgentID(id) { return .orca }
        return inventoryIDs.contains(id) ? .inventory : .editable
    }

    /// Sidebar name of an agent: Orca accounts drop the product prefix when
    /// they are nested under it ("Orca 1a2b3c4d").
    static func displayName(_ name: String, id: String, nested: Bool) -> String {
        guard nested, OrcaIntegration.isOrcaAgentID(id), let range = name.range(of: " · ") else { return name }
        return String(name[range.upperBound...])
    }

    /// `ids` in catalog order. `order` (user drag order of top-level ids)
    /// wins for the ids it names; the rest keep their catalog position after
    /// them. Hidden ids are left out, children included.
    static func sections(ids: [String], mode: Mode, order: [String], hidden: Set<String>) -> [Section] {
        let visible = ids.filter { !hidden.contains($0) }
        func sorted(_ list: [String]) -> [String] {
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let catalog = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return list.sorted {
                switch (rank[$0], rank[$1]) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return catalog[$0, default: 0] < catalog[$1, default: 0]
                }
            }
        }
        switch mode {
        case .flat:
            return [Section(kind: nil, groups: sorted(visible).map { Group(agentID: $0) })]
        case .kind:
            return Kind.allCases.compactMap { kind in
                let members = sorted(visible.filter { self.kind($0) == kind })
                return members.isEmpty ? nil : Section(kind: kind, groups: members.map { Group(agentID: $0) })
            }
        case .product:
            let parents = visible.filter { !OrcaIntegration.isOrcaAgentID($0) }
            var groups = sorted(parents).map { parent in
                Group(agentID: parent, children: visible.filter { OrcaIntegration.isOrcaAgentID($0) && family($0) == parent })
            }
            // Orca accounts whose product is hidden or absent stay visible on their own.
            let nested = Set(groups.flatMap(\.children))
            groups += sorted(visible.filter { OrcaIntegration.isOrcaAgentID($0) && !nested.contains($0) }).map { Group(agentID: $0) }
            return [Section(kind: nil, groups: groups)]
        }
    }

    /// New persisted order after moving top-level rows of one section.
    static func moving(_ section: Section, from offsets: IndexSet, to destination: Int, order: [String]) -> [String] {
        var ids = section.groups.map(\.agentID)
        let moved = offsets.sorted().map { ids[$0] }
        let insertAt = destination - offsets.filter { $0 < destination }.count
        ids.removeAll { moved.contains($0) }
        ids.insert(contentsOf: moved, at: min(max(insertAt, 0), ids.count))
        return ids + order.filter { !ids.contains($0) }
    }
}
