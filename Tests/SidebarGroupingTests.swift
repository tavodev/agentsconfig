import Foundation
import Testing

extension AgentsConfigTestSuite {
@Suite("Sidebar grouping", .serialized)
struct SidebarGroupingTests {
    private let ids = ["claude-code", "codex", "gemini-cli", "cursor", "claude-desktop",
                       "claude-code:orca:aaaa1111", "codex:orca:bbbb2222", "codex:orca:runtime"]

    @Test func productModeNestsOrcaAccountsUnderTheirAgent() {
        let sections = SidebarGrouping.sections(ids: ids, mode: .product, order: [], hidden: [])
        #expect(sections.count == 1)
        let groups = sections[0].groups
        #expect(groups.map(\.agentID) == ["claude-code", "codex", "gemini-cli", "cursor", "claude-desktop"])
        #expect(groups[0].children == ["claude-code:orca:aaaa1111"])
        #expect(groups[1].children == ["codex:orca:bbbb2222", "codex:orca:runtime"])
    }

    @Test func orcaAccountsStayVisibleWhenTheirProductIsHidden() {
        let groups = SidebarGrouping.sections(ids: ids, mode: .product, order: [], hidden: ["codex"])[0].groups
        #expect(!groups.contains { $0.agentID == "codex" })
        #expect(groups.suffix(2).map(\.agentID) == ["codex:orca:bbbb2222", "codex:orca:runtime"])
    }

    @Test func kindModeSplitsEditableInventoryAndOrca() {
        let sections = SidebarGrouping.sections(ids: ids, mode: .kind, order: [], hidden: ["gemini-cli"])
        #expect(sections.map(\.kind) == [.editable, .inventory, .orca])
        #expect(sections[0].groups.map(\.agentID) == ["claude-code", "codex"])
        #expect(sections[1].groups.map(\.agentID) == ["cursor", "claude-desktop"])
        #expect(sections[2].groups.count == 3)
    }

    @Test func userOrderWinsAndUnknownIdsKeepCatalogOrder() {
        let flat = SidebarGrouping.sections(ids: ids, mode: .flat, order: ["cursor", "codex", "gone"], hidden: [])
        #expect(Array(flat[0].groups.map(\.agentID).prefix(3)) == ["cursor", "codex", "claude-code"])
    }

    @Test func movingRowsPersistsTheNewOrder() {
        let section = SidebarGrouping.sections(ids: ids, mode: .product, order: [], hidden: [])[0]
        let order = SidebarGrouping.moving(section, from: [3], to: 0, order: ["kept-elsewhere"])
        #expect(order == ["cursor", "claude-code", "codex", "gemini-cli", "claude-desktop", "kept-elsewhere"])
        let regrouped = SidebarGrouping.sections(ids: ids, mode: .product, order: order, hidden: [])[0]
        #expect(regrouped.groups.first?.agentID == "cursor")
        #expect(regrouped.groups[1].children == ["claude-code:orca:aaaa1111"])
    }

    @Test func nestedOrcaNamesDropTheProductPrefix() {
        #expect(SidebarGrouping.displayName("Claude Code · Orca aaaa1111", id: "claude-code:orca:aaaa1111", nested: true) == "Orca aaaa1111")
        #expect(SidebarGrouping.displayName("Claude Code · Orca aaaa1111", id: "claude-code:orca:aaaa1111", nested: false) == "Claude Code · Orca aaaa1111")
        #expect(SidebarGrouping.displayName("Codex", id: "codex", nested: true) == "Codex")
    }
}
}
