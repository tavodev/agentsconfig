import Testing

/// Skills are shown grouped by origin. The rule is pure (path + readOnly +
/// optional project root), so it is exercised here with fictitious paths and
/// no home, watchers or UI.
extension AgentsConfigTestSuite {
@Suite("Skill grouping", .serialized)
struct SkillGroupingTests {
    private struct Item {
        let path: String
        let readOnly: Bool
    }

    @Test func personalMarkersClassifyEverySupportedAgentAsPersonal() {
        for marker in ["/.agents/skills/", "/.claude/skills/", "/.codex/skills/",
                       "/.gemini/skills/", "/.opencode/skills/",
                       "/.cursor/skills/", "/.copilot/skills/"] {
            let path = "/Users/fixture" + marker + "demo/SKILL.md"
            #expect(SkillGrouping.origin(path: path, readOnly: false) == .personal, "\(path)")
        }
    }

    @Test func projectRootWinsOverPersonalMarker() {
        let root = "/Users/fixture/repo"
        #expect(SkillGrouping.origin(path: root + "/.claude/skills/demo/SKILL.md",
                                     readOnly: false, projectRoot: root) == .project)
        #expect(SkillGrouping.origin(path: "/Users/fixture/.claude/skills/demo/SKILL.md",
                                     readOnly: false, projectRoot: root) == .personal)
    }

    @Test func pluginPathsArePluginsEvenWhenInsideAProjectOrReadOnly() {
        #expect(SkillGrouping.origin(path: "/Users/fixture/.codex/plugins/cache/x/SKILL.md",
                                     readOnly: true) == .plugins)
        #expect(SkillGrouping.origin(path: "/Users/fixture/.gemini/extensions/x/SKILL.md",
                                     readOnly: true) == .plugins)
        #expect(SkillGrouping.origin(path: "/Users/fixture/repo/.claude/plugins/cache/x/SKILL.md",
                                     readOnly: false, projectRoot: "/Users/fixture/repo") == .plugins)
    }

    @Test func readOnlyForeignSkillIsSystemAndUnknownNonReadOnlyFallsBackToPersonal() {
        #expect(SkillGrouping.origin(path: "/Users/fixture/.codeium/windsurf/skills/x/SKILL.md",
                                     readOnly: true) == .system)
        #expect(SkillGrouping.origin(path: "/Users/fixture/.codeium/windsurf/skills/x/SKILL.md",
                                     readOnly: false) == .personal)
    }

    // MARK: - Read-only inventories (issue #10)

    /// Cursor and Copilot CLI sources are all `readOnly` (inventory only), but
    /// their global skills live in the user's home: they are personal, with
    /// the skills root as owner, exactly like the editable agents.
    @Test func cursorAndCopilotGlobalSkillsArePersonalDespiteReadOnly() {
        let home = "/Users/fixture"
        for (path, root) in [
            (home + "/.cursor/skills/demo/SKILL.md", "~/.cursor/skills"),
            (home + "/.cursor/skills/team/nested/SKILL.md", "~/.cursor/skills"),
            (home + "/.copilot/skills/demo/SKILL.md", "~/.copilot/skills"),
        ] {
            #expect(SkillGrouping.origin(path: path, readOnly: true) == .personal, "\(path)")
            // a project context doesn't claim skills that live outside it
            #expect(SkillGrouping.origin(path: path, readOnly: true,
                                         projectRoot: home + "/repo") == .personal, "\(path)")
            #expect(owner(path, .personal, home: home) == root, "\(path)")
        }
    }

    @Test func cursorAndCopilotProjectSkillsAreProjectDespiteReadOnly() {
        let root = "/Users/fixture/repo"
        let cursor = root + "/.cursor/skills/demo/SKILL.md"
        let copilot = root + "/.github/skills/demo/SKILL.md"
        #expect(SkillGrouping.origin(path: cursor, readOnly: true, projectRoot: root) == .project)
        #expect(SkillGrouping.origin(path: copilot, readOnly: true, projectRoot: root) == .project)
        #expect(owner(cursor, .project, projectRoot: root) == ".cursor/skills")
        #expect(owner(copilot, .project, projectRoot: root) == ".github/skills")
        // a submodule's Copilot skills stay inside the project too
        #expect(SkillGrouping.origin(path: root + "/sub/.github/skills/s/SKILL.md",
                                     readOnly: true, projectRoot: root) == .project)
    }

    /// Plugin-packaged Copilot skills keep the rule they had: the personal
    /// marker needs `/.copilot/skills/`, so `installed-plugins` never matches.
    @Test func copilotInstalledPluginSkillsAreNotPersonal() {
        let path = "/Users/fixture/.copilot/installed-plugins/mkt/plug/skills/s/SKILL.md"
        #expect(SkillGrouping.origin(path: path, readOnly: true) == .system)
    }

    /// Regression: the new markers don't change other agents' origins.
    @Test func otherAgentsKeepTheirOriginsAfterAddingInventoryMarkers() {
        let home = "/Users/fixture"
        let root = home + "/repo"
        #expect(SkillGrouping.origin(path: home + "/.claude/skills/a/SKILL.md",
                                     readOnly: false, projectRoot: root) == .personal)
        #expect(SkillGrouping.origin(path: root + "/.claude/skills/a/SKILL.md",
                                     readOnly: false, projectRoot: root) == .project)
        #expect(SkillGrouping.origin(path: home + "/.claude/plugins/cache/m/p/1.0/skills/a/SKILL.md",
                                     readOnly: true) == .plugins)
        #expect(SkillGrouping.origin(path: "/etc/codex/skills/a/SKILL.md",
                                     readOnly: true) == .system)
        // Windsurf / Devin Desktop global skills are read-only inventory too
        // and stay system: only Cursor and Copilot gained markers.
        #expect(SkillGrouping.origin(path: home + "/.config/devin/skills/a/SKILL.md",
                                     readOnly: true) == .system)
        #expect(SkillGrouping.origin(path: home + "/.agents/skills/a/SKILL.md",
                                     readOnly: true) == .personal)
    }

    @Test func groupsOmitEmptyBucketsAndKeepDisplayOrder() {
        let root = "/Users/fixture/repo"
        let items = [
            Item(path: "/etc/codex/skills/sys/SKILL.md", readOnly: true),
            Item(path: "/Users/fixture/.codex/plugins/cache/plug/SKILL.md", readOnly: true),
            Item(path: root + "/.agents/skills/proj/SKILL.md", readOnly: false),
            Item(path: "/Users/fixture/.agents/skills/personal/SKILL.md", readOnly: false),
        ]
        let groups = SkillGrouping.group(items, path: \.path, readOnly: \.readOnly,
                                         projectRoot: root)
        #expect(groups.map(\.origin) == [.personal, .project, .plugins, .system])
        #expect(groups.first(where: { $0.origin == .project })?.items.map(\.path)
                == [root + "/.agents/skills/proj/SKILL.md"])
        #expect(groups.allSatisfy { !$0.items.isEmpty })
    }

    @Test func expansionDefaultsAndUserOverrides() {
        var expansion = SkillGroupExpansion()
        #expect(expansion.isExpanded(.personal, count: 50))
        #expect(expansion.isExpanded(.project, count: 1))
        #expect(expansion.isExpanded(.system, count: 20))
        #expect(expansion.isExpanded(.plugins, count: 5))
        #expect(!expansion.isExpanded(.plugins, count: 6))
        expansion.set(.plugins, true)
        #expect(expansion.isExpanded(.plugins, count: 6))
    }

    // MARK: - Ordering and flattening

    @Test func itemsInsideAnOwnerSortBySkillFolderName() {
        let items = [
            Item(path: "/Users/fixture/.claude/skills/zeta/SKILL.md", readOnly: false),
            Item(path: "/Users/fixture/.claude/skills/alpha/SKILL.md", readOnly: false),
        ]
        let groups = SkillGrouping.group(items, path: \.path, readOnly: \.readOnly,
                                         projectRoot: nil, home: "/Users/fixture")
        let personal = groups.first { $0.origin == .personal }
        let sorted = ["/Users/fixture/.claude/skills/alpha/SKILL.md",
                      "/Users/fixture/.claude/skills/zeta/SKILL.md"]
        #expect(personal?.owners.count == 1)
        #expect(personal?.owners.first?.items.map(\.path) == sorted)
        // the flat origin list gets the same order
        #expect(personal?.items.map(\.path) == sorted)
    }

    @Test func ownerOrderStaysFirstSeenAndOriginsKeepDisplayOrder() {
        let root = "/Users/fixture/repo"
        let home = "/Users/fixture"
        let items = [
            // `.agents` sorts before `.claude`, but `.claude` was seen first
            Item(path: "/Users/fixture/.claude/skills/b/SKILL.md", readOnly: false),
            Item(path: "/Users/fixture/.agents/skills/a/SKILL.md", readOnly: false),
            Item(path: root + "/.claude/skills/p/SKILL.md", readOnly: false),
            Item(path: "/Users/fixture/.codex/plugins/cache/mkt/plug/1.0/skills/s/SKILL.md",
                 readOnly: true),
        ]
        let groups = SkillGrouping.group(items, path: \.path, readOnly: \.readOnly,
                                         projectRoot: root, home: home)
        #expect(groups.map(\.origin) == [.personal, .project, .plugins])
        #expect(groups.first { $0.origin == .personal }?.owners.map(\.owner)
                == ["~/.claude/skills", "~/.agents/skills"])
    }

    @Test func nestsOwnersOnlyWhenAnOriginHasMoreThanOneOwner() {
        let home = "/Users/fixture"
        let oneOwner = [
            Item(path: "/Users/fixture/.claude/skills/a/SKILL.md", readOnly: false),
            Item(path: "/Users/fixture/.claude/skills/b/SKILL.md", readOnly: false),
        ]
        let single = SkillGrouping.group(oneOwner, path: \.path, readOnly: \.readOnly,
                                         projectRoot: nil, home: home).first
        // the model still reports the owner group; only the view flattens
        #expect(single?.owners.map(\.owner) == ["~/.claude/skills"])
        #expect(single?.nestsOwners == false)

        let twoOwners = oneOwner + [
            Item(path: "/Users/fixture/.agents/skills/c/SKILL.md", readOnly: false),
        ]
        let multi = SkillGrouping.group(twoOwners, path: \.path, readOnly: \.readOnly,
                                        projectRoot: nil, home: home).first
        #expect(multi?.owners.count == 2)
        #expect(multi?.nestsOwners == true)
    }

    @Test func skillRowsDropThePathSubtitle() {
        let skill = TrackedFile(path: "/Users/fixture/.claude/skills/demo/SKILL.md",
                                format: .markdown, role: .skills, volatile: false,
                                excludeFromHistory: false, readOnly: false,
                                note: nil, exists: true, size: 0, mtime: nil)
        #expect(skill.rowSubtitle == nil)
        #expect(skill.displayName == "demo")

        let pluginSkill = TrackedFile(
            path: "/Users/fixture/.claude/plugins/cache/mkt/plug/abc123/skills/review/SKILL.md",
            format: .markdown, role: .skills, volatile: false,
            excludeFromHistory: false, readOnly: true,
            note: nil, exists: true, size: 0, mtime: nil)
        #expect(pluginSkill.rowSubtitle == nil)
        #expect(pluginSkill.displayName == "review")

        let settings = TrackedFile(path: "/Users/fixture/.claude/settings.json",
                                   format: .json, role: .settings, volatile: false,
                                   excludeFromHistory: false, readOnly: false,
                                   note: nil, exists: true, size: 0, mtime: nil)
        #expect(settings.rowSubtitle == settings.shortPath)
    }

    @Test func missingFilesStayOutOfTheFileListUnlessWorkIsAttached() {
        let missing = TrackedFile(path: "/proj/.codex/hooks.json", format: .json, role: .hooks,
                                  volatile: false, excludeFromHistory: false, readOnly: false,
                                  note: nil, exists: false, size: 0, mtime: nil)
        #expect(missing.appearsInFileList(dirty: false, pendingExternal: false, hasSaveError: false) == false)
        #expect(missing.appearsInFileList(dirty: true, pendingExternal: false, hasSaveError: false))
        #expect(missing.appearsInFileList(dirty: false, pendingExternal: true, hasSaveError: false))
        #expect(missing.appearsInFileList(dirty: false, pendingExternal: false, hasSaveError: true))

        let present = TrackedFile(path: "/proj/AGENTS.md", format: .markdown, role: .instructions,
                                  volatile: false, excludeFromHistory: false, readOnly: false,
                                  note: nil, exists: true, size: 12, mtime: nil)
        #expect(present.appearsInFileList(dirty: false, pendingExternal: false, hasSaveError: false))
    }

    /// Expansion state lives on the store (session-only) so it survives the
    /// file list being rebuilt; the value type must be reassigned through
    /// the setters for `@Observable` to publish.
    @Test @MainActor func storeKeepsSkillExpansionOverridesAcrossWrites() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let store = env.makeStore()
        #expect(!store.skillExpansion.isExpanded(.plugins, count: 6))
        store.setSkillExpanded(.plugins, true)
        #expect(store.skillExpansion.isExpanded(.plugins, count: 6))
        store.setSkillExpanded(.plugins, owner: "mkt / plug", false)
        #expect(!store.skillExpansion.isExpanded(.plugins, owner: "mkt / plug", count: 3))
        store.setSkillExpanded(.plugins, false)
        #expect(!store.skillExpansion.isExpanded(.plugins, count: 3))
    }

    /// Issue #11: a search opens every group with matches, toggles made
    /// during it are scoped to it, and clearing restores the session state.
    @Test @MainActor func searchOpensMatchingGroupsAndRestoresExpansion() throws {
        let env = try TestEnvironment()
        defer { env.teardown() }
        let store = env.makeStore()
        store.setSkillExpanded(.personal, false)
        store.setSkillExpanded(.plugins, owner: "mkt / plug", false)
        #expect(store.skillExpansion.isExpandedForSearch(.personal))
        #expect(store.skillExpansion.isExpandedForSearch(.plugins, owner: "mkt / plug"))

        store.setSkillSearchExpanded(.personal, false)
        store.setSkillSearchExpanded(.plugins, owner: "mkt / plug", true)
        #expect(!store.skillExpansion.isExpandedForSearch(.personal))
        // Session state is untouched while searching.
        #expect(!store.skillExpansion.isExpanded(.personal, count: 1))
        #expect(!store.skillExpansion.isExpanded(.plugins, owner: "mkt / plug", count: 1))

        store.endSkillSearch()
        #expect(store.skillExpansion.isExpandedForSearch(.personal))
        #expect(!store.skillExpansion.isExpanded(.personal, count: 1))
        #expect(!store.skillExpansion.isExpanded(.plugins, owner: "mkt / plug", count: 1))
        #expect(!store.skillExpansion.isExpanded(.plugins, count: 6))
    }

    // MARK: - Owner labels

    private func owner(_ path: String, _ origin: SkillOrigin,
                       projectRoot: String? = nil,
                       home: String = "/Users/fixture") -> String {
        SkillGrouping.owner(path: path, origin: origin,
                            projectRoot: projectRoot, home: home)
    }

    @Test func pluginCacheOwnerIsThePluginPackageNotEveryDirectory() {
        let base = "/Users/fixture/.claude/plugins/cache"
        // marketplace + plugin + commit-hash version + skills wrapper
        #expect(owner("\(base)/claude-plugins-official/figma/ae7e5e5f80da/skills/figma-use/SKILL.md",
                      .plugins) == "claude-plugins-official / figma")
        // numeric version and skills-* wrapper are skipped
        #expect(owner("\(base)/mkt/api-review/2.0/skills-extra/review/SKILL.md",
                      .plugins) == "mkt / api-review")
        // plugin without a marketplace folder
        #expect(owner("\(base)/superpowers/1.2.3/skills/brainstorm/SKILL.md",
                      .plugins) == "superpowers")
        // marketplace equal to the plugin collapses to one label
        #expect(owner("\(base)/pixel-plugin/pixel-plugin/0.5.0/skills/pixel-art/SKILL.md",
                      .plugins) == "pixel-plugin")
        // SKILL.md straight under the cache: the skill folder is never the owner
        #expect(owner("\(base)/x/SKILL.md", .plugins) == "cache")
    }

    @Test func nonCachePluginAndExtensionOwnersAreTheFirstPackageFolder() {
        #expect(owner("/Users/fixture/.gemini/extensions/ext-a/myskill/SKILL.md",
                      .plugins) == "ext-a")
        #expect(owner("/Users/fixture/.claude/plugins/local/myskill/SKILL.md",
                      .plugins) == "local")
        // SKILL.md directly under the marker root labels the root itself
        #expect(owner("/Users/fixture/.gemini/extensions/x/SKILL.md",
                      .plugins) == "~/.gemini/extensions")
    }

    @Test func personalOwnerIsTheSkillsRootShortenedWithTilde() {
        #expect(owner("/Users/fixture/.claude/skills/demo/SKILL.md", .personal)
                == "~/.claude/skills")
        #expect(owner("/Users/fixture/.agents/skills/a/SKILL.md", .personal)
                == "~/.agents/skills")
        // outside home the full root is shown instead of a tilde
        #expect(owner("/opt/agent/.codex/skills/b/SKILL.md", .personal)
                == "/opt/agent/.codex/skills")
        // nested SKILL.md trees still resolve to the declared root
        #expect(owner("/Users/fixture/.gemini/config/skills/cat/s/SKILL.md", .personal)
                == "~/.gemini/config/skills")
    }

    @Test func projectOwnerIsTheProjectRelativeSkillsFolder() {
        let root = "/Users/fixture/repo"
        #expect(owner(root + "/.claude/skills/demo/SKILL.md", .project, projectRoot: root)
                == ".claude/skills")
        // submodule prefix is part of the owner
        #expect(owner(root + "/sub/.agents/skills/s/SKILL.md", .project, projectRoot: root)
                == "sub/.agents/skills")
        // nested project sources keep their folder prefix
        #expect(owner(root + "/pkg/backend/.claude/skills/s/SKILL.md", .project,
                      projectRoot: root) == "pkg/backend/.claude/skills")
    }

    @Test func systemOwnerIsTheParentDirectoryOfTheSkillFolder() {
        #expect(owner("/usr/lib/myskill/SKILL.md", .system) == "/usr/lib")
        #expect(owner("/Users/fixture/share/myskill/SKILL.md", .system)
                == "~/share")
        // a skill folder at the filesystem root has no discriminating parent
        #expect(owner("/myskill/SKILL.md", .system) == "System")
    }

    @Test func groupsNestItemsUnderOwnersEvenWithASingleOwner() {
        let root = "/Users/fixture/repo"
        let home = "/Users/fixture"
        let items = [
            Item(path: "/Users/fixture/.claude/skills/p1/SKILL.md", readOnly: false),
            Item(path: "/Users/fixture/.claude/skills/p2/SKILL.md", readOnly: false),
            Item(path: "/Users/fixture/.agents/skills/p3/SKILL.md", readOnly: false),
            Item(path: root + "/.claude/skills/proj/SKILL.md", readOnly: false),
            Item(path: "/Users/fixture/.claude/plugins/cache/mkt/plug/1.0/skills/s/SKILL.md",
                 readOnly: true),
        ]
        let groups = SkillGrouping.group(items, path: \.path, readOnly: \.readOnly,
                                         projectRoot: root, home: home)
        let personal = groups.first { $0.origin == .personal }
        #expect(personal?.owners.map(\.owner) == ["~/.claude/skills", "~/.agents/skills"])
        #expect(personal?.owners.first?.items.count == 2)
        // a single skill still gets its own owner group — no flattening
        #expect(groups.first { $0.origin == .project }?.owners.map(\.owner)
                == [".claude/skills"])
        #expect(groups.first { $0.origin == .plugins }?.owners.map(\.owner) == ["mkt / plug"])
        #expect(groups.allSatisfy { $0.owners.allSatisfy { !$0.items.isEmpty } })
    }

    @Test func ownerExpansionDefaultsCollapseAtSixAndOverrideSticks() {
        var expansion = SkillGroupExpansion()
        #expect(expansion.isExpanded(.plugins, owner: "mkt / plug", count: 5))
        #expect(!expansion.isExpanded(.plugins, owner: "mkt / plug", count: 6))
        // owner state is per origin + owner and independent of origin state
        expansion.set(.plugins, owner: "mkt / plug", false)
        #expect(!expansion.isExpanded(.plugins, owner: "mkt / plug", count: 3))
        #expect(expansion.isExpanded(.plugins, owner: "other", count: 3))
        #expect(expansion.isExpanded(.personal, owner: "mkt / plug", count: 3))
        expansion.set(.plugins, owner: "mkt / plug", true)
        #expect(expansion.isExpanded(.plugins, owner: "mkt / plug", count: 6))
    }

    @Test func sanitizedOwnerIDsKeepPathCharactersReadable() {
        #expect(SkillGrouping.sanitizedOwnerID("claude-plugins-official / figma")
                == "claude-plugins-official-figma")
        #expect(SkillGrouping.sanitizedOwnerID("~/.claude/skills") == ".claude-skills")
        #expect(SkillGrouping.sanitizedOwnerID("sub/.agents/skills") == "sub-.agents-skills")
        #expect(SkillGrouping.sanitizedOwnerID("mkt / plug") == "mkt-plug")
    }
}
}
