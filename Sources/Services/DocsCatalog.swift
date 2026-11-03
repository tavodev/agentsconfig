import Foundation

/// Inline documentation: what a config file is for, and what each known
/// key does (with accepted values). English is primary; `*ES` fields hold
/// the Spanish text shown when the app language is Spanish.
enum DocsCatalog {

    struct FileDoc {
        let title: String
        let body: String
        let docsURL: URL?
        var titleES: String? = nil
        var bodyES: String? = nil

        @MainActor var localizedTitle: String { Loc.shared.lang == .es ? (titleES ?? title) : title }
        @MainActor var localizedBody: String { Loc.shared.lang == .es ? (bodyES ?? body) : body }
    }

    struct KeyDoc {
        let summary: String
        var values: [String: String]?   // value → explanation
        var defaultValue: String?
        var summaryES: String? = nil
        var valuesES: [String: String]? = nil
        /// Official page (ideally the key's own anchor) with the full details.
        var docsURL: URL? = nil
        /// Accepted values from the official reference, when it documents them.
        var spec: SettingSpec? = nil

        init(_ s: String, es: String? = nil,
             values: [String: String]? = nil, valuesES: [String: String]? = nil,
             def: String? = nil, docsURL: URL? = nil, spec: SettingSpec? = nil) {
            summary = s; summaryES = es
            self.values = values; self.valuesES = valuesES
            defaultValue = def
            self.docsURL = docsURL
            self.spec = spec
        }

        @MainActor var localizedSummary: String { Loc.shared.lang == .es ? (summaryES ?? summary) : summary }
        /// Summary without Markdown code ticks, for native tooltips and VoiceOver.
        @MainActor var plainSummary: String { localizedSummary.replacingOccurrences(of: "`", with: "") }
        /// Summary rendered as inline Markdown so `code` spans show as code.
        @MainActor var attributedSummary: AttributedString {
            (try? AttributedString(markdown: localizedSummary,
                                   options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(localizedSummary)
        }
        @MainActor var localizedValues: [String: String]? {
            Loc.shared.lang == .es ? (valuesES ?? values) : values
        }

        /// Values to offer in a picker or suggestion menu: the reference's
        /// options, plus curated examples unless the list is closed.
        var suggestedValues: [String] {
            let options = spec?.options ?? []
            if spec?.isEnum == true { return options }
            return options + (values?.keys.sorted() ?? []).filter { !options.contains($0) }
        }
    }

    // MARK: - File docs

    static func fileDoc(for path: String) -> FileDoc? {
        if let equivalent = OrcaIntegration.equivalentPath(for: path) { return fileDoc(for: equivalent) }
        let home = AppPaths.home
        let name = URL(fileURLWithPath: path).lastPathComponent
        // Home-only files: no project-local equivalent exists for these.
        switch path {
        case "\(home)/.claude.json":
            return .init(
                title: "Claude Code global state",
                body: "Large file maintained by Claude Code holding global state: known projects, history and —inside the mcpServers key— user-level MCP servers.\n\nIt changes constantly: watched live but without history.",
                docsURL: nil,
                titleES: "Estado global de Claude Code",
                bodyES: "Archivo grande mantenido por Claude Code con estado global: proyectos conocidos, historial y —dentro de la clave mcpServers— los MCP a nivel usuario.\n\nCambia constantemente: se vigila en vivo pero sin historial."
            )
        case "\(home)/Library/Application Support/Antigravity/User/settings.json":
            return .init(
                title: "Antigravity IDE settings",
                body: "IDE interface preferences (VS Code style): theme, font, editor behavior.",
                docsURL: nil,
                titleES: "Ajustes del IDE Antigravity",
                bodyES: "Preferencias de la interfaz del IDE (estilo VS Code): tema, fuente, comportamiento del editor."
            )
        default:
            break
        }
        // Matched by relative suffix, so the same doc applies whether the
        // file lives under the global agent home or a registered project
        // root (Codex/Claude/Gemini/OpenCode local config).
        if let doc = pathSuffixDocs.first(where: { ConfigFileContext.matches(path, suffix: $0.0) })?.1 {
            return doc
        }
        // Patterns by file name
        switch name {
        case "CLAUDE.md":
            return instructionDoc(path: path, product: "Claude", userPath: ".claude/CLAUDE.md",
                                  url: "https://code.claude.com/docs/en/memory")
        case "AGENTS.md":
            return .init(title: "Agent instructions",
                         body: "Conventions read by compatible agents (Codex, OpenCode, Devin…) when working. The cross-agent equivalent of CLAUDE.md.",
                         docsURL: nil,
                         titleES: "Instrucciones para agentes",
                         bodyES: "Convenciones leídas por agentes compatibles (Codex, OpenCode, Devin…) al trabajar. Es el equivalente de CLAUDE.md pero cross-agente.")
        case "GEMINI.md":
            return instructionDoc(path: path, product: "Gemini", userPath: ".gemini/GEMINI.md",
                                  url: "https://geminicli.com/docs/cli/gemini-md/")
        case "SKILL.md":
            return .init(title: "Agent skill",
                         body: "A skill packages instructions + resources the agent invokes when its name/trigger matches. The YAML frontmatter defines when it applies.",
                         docsURL: nil,
                         titleES: "Skill de agente",
                         bodyES: "Una skill empaqueta instrucciones + recursos que el agente invoca cuando el nombre/disparador coincide. El frontmatter YAML define cuándo aplica.")
        case "auth.json", "credentials.json", ".credentials.json":
            return .init(title: "Credentials",
                         body: "Agent authentication tokens. Read-only here — edit only through the agent itself (login/logout). Values are shown masked.",
                         docsURL: nil,
                         titleES: "Credenciales",
                         bodyES: "Tokens de autenticación del agente. Solo lectura aquí — edítalo solo a través del agente (login/logout). Los valores se muestran enmascarados.")
        case "installed_plugins.json":
            return .init(title: "Installed plugins",
                         body: "Registry of plugins installed by the agent's manager. Normally agent-maintained; edit only to force a specific plugin.",
                         docsURL: nil,
                         titleES: "Plugins instalados",
                         bodyES: "Registro de plugins instalados por el gestor del agente. Normalmente lo mantiene el agente; edítalo solo si sabes qué plugin quieres forzar.")
        case "statusline.sh":
            return .init(title: "Status line",
                         body: "Script feeding the agent's status bar. It must print to stdout; errors here surface as an empty status.",
                         docsURL: nil,
                         titleES: "Status line",
                         bodyES: "Script que alimenta la barra de estado del agente. Debe imprimir por stdout; errores aquí se ven como status vacío.")
        default:
            if name.hasSuffix(".mdc") {
                return .init(title: "Cursor rule",
                             body: "Project rule for Cursor. Its frontmatter (description, globs, alwaysApply) decides when it is attached. Inventoried read-only here.",
                             docsURL: URL(string: "https://cursor.com/docs/context/rules"),
                             titleES: "Regla de Cursor",
                             bodyES: "Regla de proyecto de Cursor. Su frontmatter (description, globs, alwaysApply) decide cuándo se adjunta. Aquí se inventaría en solo lectura.")
            }
            if name.hasSuffix(".instructions.md") {
                return .init(title: "Copilot path-specific instructions",
                             body: "Instructions GitHub Copilot applies to files matching the applyTo glob in the frontmatter. Inventoried read-only here.",
                             docsURL: URL(string: "https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions"),
                             titleES: "Instrucciones de Copilot por ruta",
                             bodyES: "Instrucciones que GitHub Copilot aplica a los archivos que coinciden con el glob applyTo del frontmatter. Aquí se inventaría en solo lectura.")
            }
            if name.hasSuffix(".rules") {
                return .init(title: "Permission rules",
                             body: "Lists of allowed/denied command prefixes (the agent's own DSL). Consulted before running shell commands.",
                             docsURL: nil,
                             titleES: "Reglas de permisos",
                             bodyES: "Listas de prefijos de comandos permitidos/denegados (DSL propio del agente). El agente las consulta antes de ejecutar shell commands.")
            }
            return nil
        }
    }

    private static func instructionDoc(path: String, product: String, userPath: String, url: String) -> FileDoc {
        if ConfigFileContext.isUserFile(path, relativePath: userPath) {
            return .init(title: product + " global instructions",
                         body: "User-level instructions shared across projects. Project instructions can contribute additional context; actual loading depends on the client and session.",
                         docsURL: URL(string: url),
                         titleES: "Instrucciones globales de " + product,
                         bodyES: "Instrucciones de usuario compartidas entre proyectos. Las instrucciones del proyecto pueden aportar contexto adicional; la carga real depende del cliente y de la sesión.")
        }
        return .init(title: product + " project instructions",
                     body: "Instructions for this project or folder. Their scope depends on directory hierarchy and the client's discovery rules; finding this file does not confirm that a session loaded it.",
                     docsURL: URL(string: url),
                     titleES: "Instrucciones de proyecto de " + product,
                     bodyES: "Instrucciones para este proyecto o carpeta. Su alcance depende de la jerarquía de directorios y de las reglas del cliente; encontrar este archivo no confirma que una sesión lo haya cargado.")
    }

    /// (relative suffix, doc) pairs — matched against the end of an absolute
    /// path, so the same entry covers both `~/.codex/config.toml` and any
    /// registered project's `.codex/config.toml`. Order matters only where
    /// one suffix could be a tail of another; none of these overlap.
    private static let pathSuffixDocs: [(String, FileDoc)] = [
        (".claude/settings.json", .init(
            title: "Claude Code settings",
            body: "Configuration applied to Claude Code sessions: default model, tool permissions, hooks, enabled plugins and environment variables.\n\nPrecedence: managed > CLI > local > project > user. Lists and certain keys have specific merge rules.",
            docsURL: URL(string: "https://code.claude.com/docs/en/settings"),
            titleES: "Ajustes de Claude Code",
            bodyES: "Configuración aplicada a las sesiones de Claude Code: modelo por defecto, permisos de herramientas, hooks, plugins activados y variables de entorno.\n\nPrecedencia: sistema gestionado > CLI > local > proyecto > usuario. Las listas y ciertas claves tienen reglas de combinación específicas."
        )),
        (".claude/settings.local.json", .init(
            title: "Claude Code local overrides",
            body: "Personal overrides layered on top of settings.json for this project — meant to stay out of version control (usually gitignored), so teammates don't inherit them.",
            docsURL: URL(string: "https://code.claude.com/docs/en/settings"),
            titleES: "Overrides locales de Claude Code",
            bodyES: "Ajustes personales que se superponen a settings.json en este proyecto — pensados para quedar fuera del control de versiones (normalmente en .gitignore), así el equipo no los hereda."
        )),
        (".claude/mcp.json", .init(
            title: "Claude MCP servers (nonstandard)",
            body: "MCP servers for Claude in a nonstandard location. The standard project file is .mcp.json at the project root.",
            docsURL: nil,
            titleES: "Servidores MCP de Claude (no estándar)",
            bodyES: "Servidores MCP para Claude en una ubicación no estándar. El archivo estándar de proyecto es .mcp.json en la raíz del proyecto."
        )),
        (".mcp.json", .init(
            title: "Project MCP servers",
            body: "Standard Claude Code file for project-scoped MCP servers. Checked into the repo and shared with the team, unlike user-level servers in ~/.claude.json.",
            docsURL: URL(string: "https://code.claude.com/docs/en/mcp"),
            titleES: "Servidores MCP del proyecto",
            bodyES: "Archivo estándar de Claude Code para servidores MCP a nivel de proyecto. Se versiona y se comparte con el equipo, a diferencia de los servidores a nivel usuario en ~/.claude.json."
        )),
        (".codex/config.toml", .init(
            title: "Codex configuration",
            body: "Codex file (TOML): model and reasoning effort, approval policy, sandbox, MCP servers, subagents and hooks.\n\nA project-level copy overrides the user one for the same keys, and is only loaded if the project is trusted.",
            docsURL: URL(string: "https://developers.openai.com/codex/config-reference"),
            titleES: "Configuración de Codex",
            bodyES: "Archivo de Codex (TOML): modelo y esfuerzo de razonamiento, política de aprobación, sandbox, servidores MCP, subagentes y hooks.\n\nUna copia de proyecto sobrescribe la de usuario para las mismas claves, y solo se carga si el proyecto es de confianza."
        )),
        (".codex/hooks.json", .init(
            title: "Codex hooks",
            body: "Scripts Codex runs on lifecycle events (before/after tools, on session start…). Check that the referenced paths exist — broken hooks fail silently.",
            docsURL: nil,
            titleES: "Hooks de Codex",
            bodyES: "Scripts que Codex ejecuta en eventos del ciclo de vida (antes/después de herramientas, al iniciar sesión…). Revisa que las rutas apuntadas existan — los hooks rotos fallan en silencio."
        )),
        (".gemini/settings.json", .init(
            title: "Gemini CLI settings",
            body: "Gemini CLI preferences: selected authentication, theme, IDE integration, checkpoints and MCP servers.\n\nA project-level copy overrides the user one for the same keys.",
            docsURL: nil,
            titleES: "Ajustes de Gemini CLI",
            bodyES: "Preferencias del CLI de Gemini: autenticación seleccionada, tema, integración con IDE, checkpoints y servidores MCP.\n\nUna copia de proyecto sobrescribe la de usuario para las mismas claves."
        )),
        (".gemini/config/mcp_config.json", .init(
            title: "Antigravity/Gemini MCP (post-migration)",
            body: "After the 2.0 migration, Antigravity (app, IDE and CLI) shares this folder: the common MCP servers live here.",
            docsURL: nil,
            titleES: "MCP de Antigravity/Gemini (post-migración)",
            bodyES: "Tras la migración 2.0, Antigravity (app, IDE y CLI) comparte esta carpeta: aquí viven los servidores MCP comunes."
        )),
        (".gemini/antigravity/mcp_config.json", .init(
            title: "Antigravity MCP (legacy)",
            body: "Pre-migration location. If ~/.gemini/config/mcp_config.json exists, this file may be ignored — verify before editing.",
            docsURL: nil,
            titleES: "MCP de Antigravity (legacy)",
            bodyES: "Ubicación anterior a la migración. Si existe ~/.gemini/config/mcp_config.json, este archivo puede estar ignorado — verifica antes de editar."
        )),
        (".cursor/mcp.json", .init(
            title: "Cursor MCP servers",
            body: "MCP servers for Cursor (mcpServers). The user file applies to every workspace; a project's .cursor/mcp.json applies to that project. Inventoried read-only here.",
            docsURL: URL(string: "https://cursor.com/docs/context/mcp"),
            titleES: "Servidores MCP de Cursor",
            bodyES: "Servidores MCP de Cursor (mcpServers). El archivo de usuario aplica a todos los workspaces; el .cursor/mcp.json de un proyecto aplica solo a ese proyecto. Aquí se inventaría en solo lectura."
        )),
        (".cursor/cli-config.json", .init(
            title: "Cursor CLI configuration",
            body: "Cursor CLI settings: permissions, editor mode, model and other CLI preferences. Inventoried read-only here.",
            docsURL: URL(string: "https://cursor.com/docs/cli/reference/configuration"),
            titleES: "Configuración de Cursor CLI",
            bodyES: "Ajustes de Cursor CLI: permisos, modo de editor, modelo y otras preferencias del CLI. Aquí se inventaría en solo lectura."
        )),
        (".cursor/hooks.json", .init(
            title: "Cursor hooks",
            body: "Commands Cursor runs on agent lifecycle events. Hook scripts are inspected, never executed. Inventoried read-only here.",
            docsURL: URL(string: "https://cursor.com/docs/hooks"),
            titleES: "Hooks de Cursor",
            bodyES: "Comandos que Cursor ejecuta en eventos del ciclo de vida del agente. Los scripts se inspeccionan, nunca se ejecutan. Aquí se inventaría en solo lectura."
        )),
        (".copilot/settings.json", .init(
            title: "Copilot CLI settings",
            body: "GitHub Copilot CLI user settings (JSONC): model, theme, trusted folders and other preferences. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference"),
            titleES: "Ajustes de Copilot CLI",
            bodyES: "Ajustes de usuario de GitHub Copilot CLI (JSONC): modelo, tema, carpetas de confianza y otras preferencias. Aquí se inventaría en solo lectura."
        )),
        (".copilot/config.json", .init(
            title: "Copilot CLI state",
            body: "State maintained by Copilot CLI, which may include authentication data. Watched live, without history. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference"),
            titleES: "Estado de Copilot CLI",
            bodyES: "Estado mantenido por Copilot CLI, que puede incluir datos de autenticación. Se vigila en vivo, sin historial. Aquí se inventaría en solo lectura."
        )),
        (".copilot/mcp-config.json", .init(
            title: "Copilot CLI MCP servers",
            body: "User-level MCP servers for GitHub Copilot CLI. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference"),
            titleES: "Servidores MCP de Copilot CLI",
            bodyES: "Servidores MCP a nivel usuario de GitHub Copilot CLI. Aquí se inventaría en solo lectura."
        )),
        (".copilot/permissions-config.json", .init(
            title: "Copilot CLI permissions",
            body: "Tool and path permissions remembered by Copilot CLI. Runtime permission decisions are not inferred. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference"),
            titleES: "Permisos de Copilot CLI",
            bodyES: "Permisos de herramientas y rutas que recuerda Copilot CLI. Las decisiones de permisos en tiempo de ejecución no se infieren. Aquí se inventaría en solo lectura."
        )),
        (".copilot/providers.json", .init(
            title: "Copilot CLI model providers",
            body: "Custom model providers for Copilot CLI. May hold credentials: excluded from history. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference"),
            titleES: "Proveedores de modelos de Copilot CLI",
            bodyES: "Proveedores de modelos personalizados de Copilot CLI. Puede contener credenciales: excluido del historial. Aquí se inventaría en solo lectura."
        )),
        (".copilot/copilot-instructions.md", .init(
            title: "Copilot CLI global instructions",
            body: "User-level instructions Copilot CLI adds in every repository. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference"),
            titleES: "Instrucciones globales de Copilot CLI",
            bodyES: "Instrucciones de usuario que Copilot CLI añade en todos los repositorios. Aquí se inventaría en solo lectura."
        )),
        (".github/copilot-instructions.md", .init(
            title: "Copilot repository instructions",
            body: "Repository-wide custom instructions for GitHub Copilot. Path-specific files live in .github/instructions/*.instructions.md. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions"),
            titleES: "Instrucciones de repositorio de Copilot",
            bodyES: "Instrucciones personalizadas de GitHub Copilot para todo el repositorio. Las específicas por ruta viven en .github/instructions/*.instructions.md. Aquí se inventaría en solo lectura."
        )),
        (".github/mcp.json", .init(
            title: "Copilot repository MCP servers",
            body: "MCP servers declared for GitHub Copilot in this repository. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference"),
            titleES: "Servidores MCP de Copilot del repositorio",
            bodyES: "Servidores MCP declarados para GitHub Copilot en este repositorio. Aquí se inventaría en solo lectura."
        )),
        (".codeium/windsurf/memories/global_rules.md", .init(
            title: "Windsurf / Devin Desktop global rules",
            body: "Single always-on rules file applied to every workspace (6,000-character limit). Inventoried read-only here.",
            docsURL: URL(string: "https://docs.devin.ai/desktop/cascade/memories"),
            titleES: "Reglas globales de Windsurf / Devin Desktop",
            bodyES: "Archivo único de reglas siempre activo en todos los workspaces (límite de 6000 caracteres). Aquí se inventaría en solo lectura."
        )),
        (".config/devin/mcp_config.json", .init(
            title: "Devin Desktop MCP servers",
            body: "MCP servers for the Cascade agent (mcpServers; serverUrl or url for remote servers). Values may use ${env:VAR} or ${file:/path} interpolation. Official pages also list ~/.codeium/mcp_config.json; which file a session loads is not verified. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.devin.ai/desktop/cascade/mcp"),
            titleES: "Servidores MCP de Devin Desktop",
            bodyES: "Servidores MCP del agente Cascade (mcpServers; serverUrl o url para servidores remotos). Los valores pueden usar interpolación ${env:VAR} o ${file:/ruta}. Las páginas oficiales también citan ~/.codeium/mcp_config.json; no se verifica qué archivo carga una sesión. Aquí se inventaría en solo lectura."
        )),
        (".codeium/mcp_config.json", .init(
            title: "Devin Desktop MCP servers (FAQ location)",
            body: "MCP config location listed in the Devin Desktop FAQ. The MCP page documents ~/.config/devin/mcp_config.json instead; which one a session loads is not verified. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.devin.ai/desktop/devin-desktop-faq"),
            titleES: "Servidores MCP de Devin Desktop (ubicación del FAQ)",
            bodyES: "Ubicación de la config MCP que cita el FAQ de Devin Desktop. La página de MCP documenta ~/.config/devin/mcp_config.json; no se verifica cuál carga una sesión. Aquí se inventaría en solo lectura."
        )),
        (".codeium/windsurf/mcp_config.json", .init(
            title: "Windsurf MCP servers (legacy)",
            body: "MCP config location used by Windsurf before the Devin Desktop rename. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.devin.ai/desktop/devin-desktop-faq"),
            titleES: "Servidores MCP de Windsurf (legacy)",
            bodyES: "Ubicación de la config MCP que usaba Windsurf antes de renombrarse Devin Desktop. Aquí se inventaría en solo lectura."
        )),
        (".codeium/windsurf/hooks.json", .init(
            title: "Windsurf / Devin Desktop user hooks",
            body: "Commands Cascade runs on agent events, for every workspace. System and workspace hooks.json files are combined with it. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.devin.ai/desktop/cascade/hooks"),
            titleES: "Hooks de usuario de Windsurf / Devin Desktop",
            bodyES: "Comandos que Cascade ejecuta en eventos del agente, en todos los workspaces. Se combinan con los hooks.json de sistema y de workspace. Aquí se inventaría en solo lectura."
        )),
        (".devin/hooks.json", .init(
            title: "Devin Desktop workspace hooks",
            body: "Workspace hooks for Cascade. Takes precedence over the legacy .windsurf/hooks.json. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.devin.ai/desktop/cascade/hooks"),
            titleES: "Hooks de workspace de Devin Desktop",
            bodyES: "Hooks de workspace de Cascade. Tiene prioridad sobre el .windsurf/hooks.json legacy. Aquí se inventaría en solo lectura."
        )),
        (".windsurf/hooks.json", .init(
            title: "Windsurf workspace hooks (legacy)",
            body: "Used only when .devin/hooks.json is absent or defines no hooks. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.devin.ai/desktop/cascade/hooks"),
            titleES: "Hooks de workspace de Windsurf (legacy)",
            bodyES: "Solo se usa si .devin/hooks.json no existe o no define hooks. Aquí se inventaría en solo lectura."
        )),
        (".windsurfrules", .init(
            title: "Windsurf rules (legacy single file)",
            body: "Legacy workspace rules file, still read. New rules belong in .devin/rules/*.md (preferred) or .windsurf/rules/*.md. Inventoried read-only here.",
            docsURL: URL(string: "https://docs.devin.ai/desktop/devin-desktop-faq"),
            titleES: "Reglas de Windsurf (archivo único legacy)",
            bodyES: "Archivo de reglas de workspace legacy, todavía se lee. Las reglas nuevas van en .devin/rules/*.md (preferido) o .windsurf/rules/*.md. Aquí se inventaría en solo lectura."
        )),
        ("Library/Application Support/Claude/claude_desktop_config.json", .init(
            title: "Claude Desktop configuration",
            body: "Local MCP servers Claude Desktop launches at startup (mcpServers: command, args, env). Restart the app after changes. Remote connectors and extensions are managed in the app. Excluded from history: env values often hold secrets. Inventoried read-only here.",
            docsURL: URL(string: "https://modelcontextprotocol.io/docs/develop/connect-local-servers"),
            titleES: "Configuración de Claude Desktop",
            bodyES: "Servidores MCP locales que Claude Desktop lanza al arrancar (mcpServers: command, args, env). Reinicia la app tras cambiarlo. Los conectores remotos y las extensiones se gestionan en la app. Excluido del historial: los valores de env suelen contener secretos. Aquí se inventaría en solo lectura."
        )),
        ("opencode.json", .init(
            title: "OpenCode configuration",
            body: "Providers (API keys/endpoints), default model, custom agents, MCP servers and keybindings.\n\nIt declares $schema: the file is validatable against the official schema. A project-level copy merges with, and takes precedence over, the user one.",
            docsURL: nil,
            titleES: "Configuración de OpenCode",
            bodyES: "Providers (API keys/endpoints), modelo por defecto, agentes personalizados, MCP servers y atajos de teclado.\n\nDeclara $schema: el archivo es validable contra el esquema oficial. Una copia de proyecto se combina con la de usuario y tiene prioridad sobre ella."
        )),
        ("opencode.jsonc", .init(
            title: "OpenCode configuration (JSONC)",
            body: "Same as opencode.json, with comments allowed.",
            docsURL: nil,
            titleES: "Configuración de OpenCode (JSONC)",
            bodyES: "Igual que opencode.json, mismo esquema pero con comentarios permitidos."
        )),
    ]

    // MARK: - Key docs

    /// Resolution order: the official reference entry for the exact key
    /// (keeping curated value lists and defaults), the curated entry for the
    /// exact key, a reference `<id>` placeholder pattern, and finally the
    /// curated entry for the last segment. Every result links to the docs.
    static func keyDoc(filePath: String, keyPath: [String]) -> KeyDoc? {
        if let equivalent = OrcaIntegration.equivalentPath(for: filePath) { return keyDoc(filePath: equivalent, keyPath: keyPath) }
        guard let source = keySources.first(where: { ConfigFileContext.matches(filePath, suffix: $0.suffix) }) else { return nil }
        let curated = source.curated[keyPath.joined(separator: ".")]
            ?? matchReferenceKey(keyPath, in: source.curatedPatterns).flatMap { source.curated[$0.key] }
        if let ref = source.reference(keyPath), ref.exact || curated == nil {
            var doc = ref.doc
            if let curated {
                doc.values = curated.values
                doc.valuesES = curated.valuesES
                doc.defaultValue = curated.defaultValue
            }
            return doc
        }
        guard var doc = curated ?? keyPath.last.flatMap({ source.curated[$0] }) else { return nil }
        if doc.docsURL == nil { doc.docsURL = source.url(keyPath) }
        return doc
    }

    private struct KeySource: Sendable {
        let suffix: String
        let curated: [String: KeyDoc]
        /// Entry from the generated official reference, already linked.
        var reference: @Sendable ([String]) -> (doc: KeyDoc, exact: Bool)? = { _ in nil }
        /// Best official link for a curated key.
        let url: @Sendable ([String]) -> URL?

        /// Curated keys with `<name>` placeholders (e.g. `modelSettings.<model>`).
        var curatedPatterns: [(key: String, segs: [String])] {
            curated.keys.filter { $0.contains("<") }.map { ($0, $0.split(separator: ".").map(String.init)) }
        }
    }

    private static let claudeSource = KeySource(
        suffix: ".claude/settings.json", curated: claudeKeys,
        reference: { claudeReferenceDoc($0) },
        url: { claudeReferenceURL($0) ?? URL(string: "https://code.claude.com/docs/en/settings") })
    private static let codexSource = KeySource(
        suffix: ".codex/config.toml", curated: codexKeys,
        reference: { codexReferenceDoc($0) },
        url: { _ in codexReferenceURL })
    private static let opencodeURL = URL(string: "https://opencode.ai/docs/config/")
    private static let geminiURL = URL(string: "https://geminicli.com/docs/reference/configuration/")

    /// (relative suffix, key table) pairs — same suffix-matching rationale
    /// as `pathSuffixDocs`, so per-key docs apply to project-local files too.
    private static let keySources: [KeySource] = [
        claudeSource,
        KeySource(suffix: ".claude/settings.local.json", curated: claudeKeys,
                  reference: claudeSource.reference, url: claudeSource.url),
        codexSource,
        KeySource(suffix: "opencode.json", curated: opencodeKeys,
                  reference: { patternReferenceDoc($0, table: opencodeReference, patterns: opencodePatterns, url: opencodeURL) },
                  url: { _ in opencodeURL }),
        KeySource(suffix: "opencode.jsonc", curated: opencodeKeys,
                  reference: { patternReferenceDoc($0, table: opencodeReference, patterns: opencodePatterns, url: opencodeURL) },
                  url: { _ in opencodeURL }),
        KeySource(suffix: ".gemini/settings.json", curated: geminiKeys,
                  reference: { patternReferenceDoc($0, table: geminiReference, patterns: geminiPatterns, url: geminiURL) },
                  url: { _ in geminiURL }),
    ]

    // MARK: Official references (generated tables in DocsCatalogReference.swift)

    static let codexReferenceURL = URL(string: "https://developers.openai.com/codex/config-reference")

    /// `settings-reference` anchors are the dotted key, lowercased, with
    /// dots turned into dashes (e.g. `permissions.allow` → `#permissions-allow`).
    /// Sub-fields documented inside their parent's section link to the
    /// nearest documented ancestor (`statusLine.command` → `#statusline`).
    static func claudeReferenceURL(_ keyPath: [String]) -> URL? {
        for length in stride(from: keyPath.count, to: 0, by: -1) {
            let dotted = keyPath.prefix(length).joined(separator: ".")
            guard claudeReference[dotted] != nil else { continue }
            let anchor = dotted.lowercased().replacingOccurrences(of: ".", with: "-")
            return URL(string: "https://code.claude.com/docs/en/settings-reference#" + anchor)
        }
        return nil
    }

    private static func claudeReferenceDoc(_ keyPath: [String]) -> (doc: KeyDoc, exact: Bool)? {
        guard let entry = claudeReference[keyPath.joined(separator: ".")] else { return nil }
        var doc = KeyDoc(entry.en, es: entry.es, docsURL: claudeReferenceURL(keyPath))
        doc.spec = entry.spec
        return (doc, true)
    }

    private static func codexReferenceDoc(_ keyPath: [String]) -> (doc: KeyDoc, exact: Bool)? {
        patternReferenceDoc(keyPath, table: codexReference, patterns: codexReferencePatterns, url: codexReferenceURL)
    }

    private static func patternReferenceDoc(_ keyPath: [String], table: [String: ReferenceEntry],
                                            patterns: [(key: String, segs: [String])],
                                            url: URL?) -> (doc: KeyDoc, exact: Bool)? {
        guard let match = matchReferenceKey(keyPath, in: patterns),
              let entry = table[match.key] else { return nil }
        var doc = KeyDoc(entry.en, es: entry.es, docsURL: url)
        doc.spec = entry.spec
        return (doc, match.wildcards == 0)
    }

    static func referencePatterns(_ table: [String: ReferenceEntry]) -> [(key: String, segs: [String])] {
        table.keys.filter { !$0.contains(" ") }.map { key in
            (key, key.replacingOccurrences(of: "[]", with: "").split(separator: ".").map(String.init))
        }
    }
    private static let geminiPatterns = referencePatterns(geminiReference)
    private static let opencodePatterns = referencePatterns(opencodeReference)

    /// Reference keys split into segments; `[]` array markers are dropped
    /// (the tree's key path skips array indices) and `<name>` segments
    /// match any single key.
    private static let codexReferencePatterns = referencePatterns(codexReference)

    /// Curated table for a settings file (used to add documented sub-fields).
    static func curatedKeys(filePath: String) -> [String: KeyDoc] {
        if let equivalent = OrcaIntegration.equivalentPath(for: filePath) { return curatedKeys(filePath: equivalent) }
        return keySources.first { ConfigFileContext.matches(filePath, suffix: $0.suffix) }?.curated ?? [:]
    }

    /// Spec for a curated sub-field: scopes and topic come from the parent
    /// key's reference entry, so it is offered exactly where the parent is.
    private static func claudeSub(_ parent: String, _ kind: SettingSpec.Kind, options: [String] = [],
                                  def: String? = nil, min: Double? = nil, max: Double? = nil) -> SettingSpec? {
        guard let base = claudeReference[parent]?.spec else { return nil }
        return SettingSpec(kind: kind, options: options, allowsCustom: options.isEmpty, defaultJSON: def,
                           scopes: base.scopes, topic: base.topic, deprecated: false, min: min, max: max)
    }

    /// Picks the pattern matching `keyPath` with the fewest placeholders, so
    /// `apps._default.enabled` wins over `apps.<id>.enabled`.
    static func matchReferenceKey(_ keyPath: [String], in patterns: [(key: String, segs: [String])]) -> (key: String, wildcards: Int)? {
        var best: (key: String, wildcards: Int)?
        for p in patterns where p.segs.count == keyPath.count {
            var wildcards = 0
            var ok = true
            for (seg, key) in zip(p.segs, keyPath) {
                if seg.hasPrefix("<") && seg.hasSuffix(">") { wildcards += 1 }
                else if seg != key { ok = false; break }
            }
            if ok, best == nil || wildcards < best!.wildcards || (wildcards == best!.wildcards && p.key < best!.key) {
                best = (p.key, wildcards)
            }
        }
        return best
    }

    private static let claudeKeys: [String: KeyDoc] = [
        "model": .init("Claude Code's default model.",
                       es: "Modelo por defecto de Claude Code.",
                       values: ["default": "Your account's default model", "best": "Fable where available, otherwise Opus",
                                "fable": "Fable, for the hardest and longest tasks", "opus": "Latest Opus, complex reasoning",
                                "sonnet": "Latest Sonnet, daily coding", "haiku": "Haiku, fast and simple tasks",
                                "opusplan": "Opus in plan mode, Sonnet to execute"],
                       valuesES: ["default": "Modelo por defecto de tu cuenta", "best": "Fable si está disponible; si no, Opus",
                                  "fable": "Fable, para las tareas más difíciles y largas", "opus": "Último Opus, razonamiento complejo",
                                  "sonnet": "Último Sonnet, programación diaria", "haiku": "Haiku, tareas rápidas y simples",
                                  "opusplan": "Opus en modo plan, Sonnet al ejecutar"]),
        "effortLevel": .init("Model reasoning effort level.",
                             es: "Nivel de esfuerzo de razonamiento del modelo.",
                             values: ["low": "Least reasoning, latency-sensitive tasks", "medium": "Saves tokens, trades some intelligence",
                                      "high": "Balances tokens and intelligence", "xhigh": "Deeper reasoning, more tokens"],
                             valuesES: ["low": "Mínimo razonamiento, tareas sensibles a la latencia", "medium": "Ahorra tokens a cambio de algo de inteligencia",
                                        "high": "Equilibra tokens e inteligencia", "xhigh": "Razonamiento más profundo, más tokens"]),
        "permissions": .init("What Claude can do without asking you: allowed, denied or ask-first tools and commands.",
                             es: "Qué puede hacer Claude sin pedirte aprobación: herramientas y comandos permitidos, denegados o que preguntan."),
        "permissions.allow": .init("Rules allowed without confirmation. E.g. \"Bash(git status)\" allows that exact command; \"Bash(npm run *)\" allows the pattern.",
                                   es: "Reglas permitidas sin confirmación. Ej: \"Bash(git status)\" permite ese comando exacto; \"Bash(npm run *)\" permite el patrón."),
        "permissions.deny": .init("Always-denied rules — the agent can't run them even if it asks.",
                                  es: "Reglas siempre denegadas — el agente no puede ejecutarlas aunque las pida."),
        "permissions.ask": .init("Rules that always ask for confirmation, even if allowed elsewhere.",
                                 es: "Reglas que siempre piden confirmación, aunque estén permitidas en otra capa."),
        "permissions.defaultMode": .init("Default behavior for unlisted tools.",
                                         es: "Comportamiento por defecto ante herramientas no listadas.",
                                         values: ["default": "Asks depending on the tool",
                                                  "acceptEdits": "Auto-accepts file edits",
                                                  "bypassPermissions": "Never asks (dangerous)",
                                                  "plan": "Plans only, doesn't execute"],
                                         valuesES: ["default": "Pregunta según la herramienta",
                                                    "acceptEdits": "Auto-acepta ediciones de archivos",
                                                    "bypassPermissions": "Nunca pregunta (peligroso)",
                                                    "plan": "Solo planea, no ejecuta"]),
        "permissions.additionalDirectories": .init("Extra directories the agent can access outside the project.",
                                                   es: "Directorios extra a los que el agente puede acceder fuera del proyecto."),
        "env": .init("Environment variables injected into every Claude Code session (timeouts, feature flags, endpoints).",
                     es: "Variables de entorno inyectadas a cada sesión de Claude Code (timeouts, feature flags, endpoints)."),
        "hooks": .init("Scripts run on events: PreToolUse, PostToolUse, SessionStart, UserPromptSubmit… Each hook receives JSON context via stdin.",
                       es: "Scripts ejecutados en eventos: PreToolUse, PostToolUse, SessionStart, UserPromptSubmit… Cada hook recibe contexto JSON por stdin."),
        "statusLine": .init("Command whose output shows in the bottom status bar.",
                            es: "Comando cuya salida se muestra en la barra de estado inferior."),
        "enabledPlugins": .init("Enabled plugins, per marketplace (e.g. \"name@marketplace\": true).",
                                es: "Plugins activados, por marketplace (ej. \"nombre@marketplace\": true)."),
        "extraKnownMarketplaces": .init("Additional plugin marketplaces the agent knows about.",
                                        es: "Marketplaces de plugins adicionales que el agente conoce."),
        "mcpServers": .init("User-level MCP servers (can also live in ~/.claude/mcp.json).",
                            es: "Servidores MCP a nivel usuario (también pueden vivir en ~/.claude/mcp.json)."),
        "apiKeyHelper": .init("Script that generates the API key dynamically (for rotating auth).",
                              es: "Script que genera la API key dinámicamente (para auth rotativa)."),
        "cleanupPeriodDays": .init("Days after which old chat histories are deleted.", es: "Días tras los cuales se borran historiales de chat viejos.", def: "30"),
        "includeCoAuthoredBy": .init("Adds \"Co-Authored-By: Claude\" to commits the agent makes.", es: "Añade \"Co-Authored-By: Claude\" a los commits que haga el agente.", def: "true"),
        "autoUpdates": .init("Automatic Claude Code updates.", es: "Actualizaciones automáticas de Claude Code.", def: "true"),
        "language": .init("Language of the agent's answers.", es: "Idioma de las respuestas del agente."),
        "alwaysThinkingEnabled": .init("Keeps extended-reasoning mode always on.", es: "Mantiene el modo de razonamiento extendido siempre activo."),
        "autoMode": .init("Autonomy mode: how much the agent decides without asking.", es: "Modo de autonomía: cuánto decide el agente sin consultar."),
        "voiceEnabled": .init("Voice input in the CLI.", es: "Entrada por voz en el CLI."),
        "verbose": .init("Verbose logging of agent operations.", es: "Log detallado de las operaciones del agente."),
        "theme": .init("CLI interface theme.", es: "Tema de la interfaz del CLI."),
        "$schema": .init("JSON Schema URL editors use to validate and autocomplete this file. Claude Code ignores it at runtime.",
                         es: "URL del JSON Schema que usan los editores para validar y autocompletar este archivo. Claude Code la ignora al ejecutarse."),
        "statusLine.type": .init("Kind of status line; \"command\" runs your own script.", es: "Tipo de status line; \"command\" ejecuta tu propio script.",
                    spec: claudeSub("statusLine", .string, options: ["command"])),
        "statusLine.command": .init("Command whose stdout becomes the status line. It receives session context as JSON on stdin.",
                                    es: "Comando cuya salida estándar se convierte en la status line. Recibe el contexto de la sesión como JSON por stdin.",
                    spec: claudeSub("statusLine", .string)),
        "statusLine.padding": .init("Horizontal spacing, in characters, around the status line.", es: "Espaciado horizontal, en caracteres, alrededor de la status line.",
                    spec: claudeSub("statusLine", .integer, min: 0)),
        "statusLine.refreshInterval": .init("Seconds between periodic re-runs of the command (minimum 1).", es: "Segundos entre re-ejecuciones periódicas del comando (mínimo 1).",
                    spec: claudeSub("statusLine", .integer, min: 1)),
        "statusLine.hideVimModeIndicator": .init("Hides the built-in vim mode indicator when your script renders it itself.",
                                                 es: "Oculta el indicador de modo vim integrado cuando tu script lo muestra por su cuenta.",
                    spec: claudeSub("statusLine", .bool)),
        "subagentStatusLine.type": .init("Kind of subagent row renderer; \"command\" runs your own script.", es: "Tipo de renderizador de filas de subagentes; \"command\" ejecuta tu propio script.",
                    spec: claudeSub("subagentStatusLine", .string, options: ["command"])),
        "subagentStatusLine.command": .init("Command that receives the visible subagent rows as JSON on stdin and writes back {\"id\", \"content\"} lines to replace them.",
                                            es: "Comando que recibe las filas visibles de subagentes como JSON por stdin y devuelve líneas {\"id\", \"content\"} para reemplazarlas.",
                    spec: claudeSub("subagentStatusLine", .string)),
        "voice.enabled": .init("Turns voice dictation on or off.", es: "Activa o desactiva el dictado por voz.",
                    spec: claudeSub("voice", .bool)),
        "voice.mode": .init("How the dictation key behaves.", es: "Cómo se comporta la tecla de dictado.",
                            values: ["hold": "Hold while speaking, release to stop", "tap": "Tap to start, tap again to send"],
                            valuesES: ["hold": "Mantén pulsada mientras hablas y suelta para parar", "tap": "Pulsa para empezar y otra vez para enviar"],
                            def: "hold",
                    spec: claudeSub("voice", .string, options: ["hold", "tap"], def: "\"hold\"")),
        "voice.autoSubmit": .init("In hold mode, sends the prompt when you release the key.", es: "En modo hold, envía el prompt al soltar la tecla.",
                    spec: claudeSub("voice", .bool)),
        "autoMode.environment": .init("Prose rules describing your trusted environment (repos, buckets, domains) for the auto mode classifier. Include \"$defaults\" to keep the built-in rules.",
                                      es: "Reglas en prosa que describen tu entorno de confianza (repos, buckets, dominios) para el clasificador del modo auto. Incluye \"$defaults\" para conservar las reglas integradas.",
                    spec: claudeSub("autoMode", .array)),
        "autoMode.allow": .init("Prose rules for actions the auto mode classifier should allow. Include \"$defaults\" to keep the built-in rules.",
                                es: "Reglas en prosa de acciones que el clasificador del modo auto debe permitir. Incluye \"$defaults\" para conservar las reglas integradas.",
                    spec: claudeSub("autoMode", .array)),
        "autoMode.soft_deny": .init("Prose rules for actions the auto mode classifier blocks unless you approve them. Include \"$defaults\" to keep the built-in rules.",
                                    es: "Reglas en prosa de acciones que el clasificador del modo auto bloquea salvo que las apruebes. Incluye \"$defaults\" para conservar las reglas integradas.",
                    spec: claudeSub("autoMode", .array)),
        "autoMode.hard_deny": .init("Prose rules for actions the auto mode classifier always blocks. Include \"$defaults\" to keep the built-in rules.",
                                    es: "Reglas en prosa de acciones que el clasificador del modo auto siempre bloquea. Incluye \"$defaults\" para conservar las reglas integradas.",
                    spec: claudeSub("autoMode", .array)),
        "modelSettings.<model>": .init("Saved settings for this model (canonical name such as claude-opus-5-5): effortLevel, maxEffortLevel and autoCompactWindow.",
                                       es: "Ajustes guardados para este modelo (nombre canónico como claude-opus-5-5): effortLevel, maxEffortLevel y autoCompactWindow.",
                    spec: claudeSub("modelSettings", .object)),
        "modelSettings.<model>.effortLevel": .init("Effort level saved for this model (low, medium, high or xhigh); overrides the top-level effortLevel in the same file.",
                                                   es: "Nivel de esfuerzo guardado para este modelo (low, medium, high o xhigh); tiene prioridad sobre el effortLevel general del mismo archivo.",
                    spec: claudeSub("modelSettings", .string, options: ["low", "medium", "high", "xhigh"])),
        "modelSettings.<model>.maxEffortLevel": .init("Highest effort level this model may run at.", es: "Nivel de esfuerzo máximo con el que puede ejecutarse este modelo.",
                    spec: claudeSub("modelSettings", .string, options: ["low", "medium", "high", "xhigh", "max"])),
        "modelSettings.<model>.autoCompactWindow": .init("Tokens (100000–1000000) or \"auto\" for this model's auto-compact window; overrides the top-level autoCompactWindow.",
                                                         es: "Tokens (100000–1000000) o \"auto\" para la ventana de auto-compactación de este modelo; tiene prioridad sobre el autoCompactWindow general."),
        "remote": .init("Settings for Claude Code on the web and remote sessions.", es: "Ajustes de Claude Code en la web y de las sesiones remotas."),
        "skillOverrides": .init("Per-skill overrides: enable/disable specific skills without deleting them.", es: "Overrides por skill: permite activar/desactivar skills concretas sin borrarlas."),
    ]

    private static let codexKeys: [String: KeyDoc] = [
        "model": .init("Model used by Codex (e.g. gpt-5).", es: "Modelo usado por Codex (ej. gpt-5, gpt-6-astra)."),
        "model_reasoning_effort": .init("How much the model reasons before answering.",
                                        es: "Cuánto razona el modelo antes de responder.",
                                        values: ["minimal": "Minimum — fastest", "low": "Low", "medium": "Balanced",
                                                 "high": "High — better for complex tasks", "xhigh": "Extra high, slower"],
                                        valuesES: ["minimal": "Mínimo — más rápido", "low": "Bajo", "medium": "Equilibrado",
                                                   "high": "Alto — mejor en tareas complejas", "xhigh": "Extra alto, más lento"]),
        "model_context_window": .init("Context window size in tokens. Lower it if your plan limits context.",
                                      es: "Tamaño de la ventana de contexto en tokens. Bájalo si tu plan limita el contexto."),
        "model_auto_compact_token_limit": .init("Token threshold where Codex auto-compacts the session history.",
                                                es: "Umbral de tokens donde Codex compacta automáticamente el historial de la sesión."),
        "model_reasoning_summary": .init("How much of the model's reasoning is summarized and shown.",
                                         es: "Cuánto del razonamiento del modelo se resume y se muestra.",
                                         values: ["auto": "Codex decides", "concise": "Short summary",
                                                  "detailed": "Full summary", "none": "Hidden"],
                                         valuesES: ["auto": "Codex decide", "concise": "Resumen breve",
                                                    "detailed": "Resumen completo", "none": "Oculto"]),
        "approval_policy": .init("When Codex asks for approval before acting. Can also be a table for granular control (per sandbox/rule/MCP elicitation).",
                                 es: "Cuándo Codex pide aprobación antes de actuar. También puede ser una tabla con control granular (por sandbox/regla/elicitación MCP).",
                                 values: ["on-request": "The model decides when to ask", "never": "Never asks — use with a strict sandbox"],
                                 valuesES: ["on-request": "El modelo decide cuándo pedir", "never": "Nunca pide — usa con sandbox estricto"]),
        "sandbox_mode": .init("Isolation level when running commands.",
                              es: "Nivel de aislamiento al ejecutar comandos.",
                              values: ["read-only": "Only reads your filesystem",
                                       "workspace-write": "Can write inside the project",
                                       "danger-full-access": "Full access — no sandbox"],
                              valuesES: ["read-only": "Solo lee tu sistema de archivos",
                                         "workspace-write": "Puede escribir en el proyecto",
                                         "danger-full-access": "Acceso total — sin sandbox"]),
        "approvals_reviewer": .init("Who reviews approval requests.",
                                    es: "Quién revisa las solicitudes de aprobación.",
                                    values: ["user": "You review each request", "auto_review": "Codex reviews them automatically"],
                                    valuesES: ["user": "Tú revisas cada solicitud", "auto_review": "Codex las revisa automáticamente"]),
        "notify": .init("Command Codex sends event notifications to (e.g. a sound script or a toast).",
                        es: "Comando al que Codex envía notificaciones de eventos (ej. un script de sonido o un toast)."),
        "projects": .init("Directories marked as trusted. Codex treats trusted vs new projects differently.",
                          es: "Directorios marcados como de confianza. Codex trata diferente los proyectos trusted vs nuevos."),
        "mcp_servers": .init("MCP servers available to Codex: [mcp_servers.name] with command/args/env or a remote url. Per-server options include timeouts and an approval mode for its tools.",
                             es: "Servidores MCP disponibles para Codex: [mcp_servers.nombre] con command/args/env o url remota. Por servidor se pueden definir timeouts y un modo de aprobación para sus herramientas."),
        "startup_timeout_sec": .init("Seconds Codex waits for an MCP server to start before giving up.",
                                     es: "Segundos que Codex espera a que un servidor MCP arranque antes de desistir."),
        "tool_timeout_sec": .init("Seconds Codex waits for an MCP tool call to finish.",
                                  es: "Segundos que Codex espera a que termine una llamada a herramienta MCP."),
        "default_tools_approval_mode": .init("Default approval requirement for this MCP server's tools.",
                                             es: "Requisito de aprobación por defecto para las herramientas de este servidor MCP.",
                                             values: ["auto": "No approval needed", "prompt": "Always asks",
                                                      "writes": "Only asks for write-like actions", "approve": "Requires explicit approval"],
                                             valuesES: ["auto": "No requiere aprobación", "prompt": "Siempre pregunta",
                                                        "writes": "Solo pregunta en acciones de escritura", "approve": "Requiere aprobación explícita"]),
        "features": .init("Experimental or beta feature flags Codex recognizes (e.g. hooks, apps, multi_agent, network_proxy, memories, shell_tool) — most default to off.",
                          es: "Feature flags experimentales o beta que Codex reconoce (p. ej. hooks, apps, multi_agent, network_proxy, memories, shell_tool) — la mayoría vienen desactivados por defecto."),
        "plugins": .init("Installed plugins and their state (enabled, and which of their MCP servers are on).",
                         es: "Plugins instalados y su estado (enabled, y cuáles de sus servidores MCP están activos)."),
        "marketplaces": .init("Configured plugin marketplaces: where to fetch them from (git repo or local path) and which ref/subpaths to use.",
                              es: "Marketplaces de plugins configurados: de dónde se obtienen (repo git o ruta local) y qué ref/subrutas usar."),
        "desktop": .init("Codex desktop app settings, including custom file handlers (which app opens which file type).",
                         es: "Ajustes de la app de escritorio de Codex, incluidos manejadores de archivo personalizados (qué app abre qué tipo de archivo)."),
        "shell_environment_policy": .init("Which environment variables commands run by Codex inherit: inherit mode (all/core/none), include/exclude filters and extra variables to set.",
                                          es: "Qué variables de entorno heredan los comandos que ejecuta Codex: modo de herencia (all/core/none), filtros de inclusión/exclusión y variables extra a definir."),
        "tui": .init("Terminal UI settings: notifications, keymaps, theme, vim mode, raw output mode, animations.",
                     es: "Ajustes de la interfaz de terminal: notificaciones, atajos de teclado, tema, modo vim, modo de salida cruda, animaciones."),
        "hooks": .init("Lifecycle hook scripts, grouped by event (PreToolUse, PostToolUse, SessionStart, SessionEnd, SubagentStart, SubagentStop, UserPromptSubmit, Stop, Interrupt). Gated behind features.hooks (off by default); [hooks.state] holds internal hashes Codex uses to detect changes.",
                       es: "Scripts de hooks agrupados por evento (PreToolUse, PostToolUse, SessionStart, SessionEnd, SubagentStart, SubagentStop, UserPromptSubmit, Stop, Interrupt). Depende de features.hooks (desactivado por defecto); [hooks.state] guarda hashes internos que Codex usa para detectar cambios."),
        "hooks.PreToolUse": .init("Runs before Codex executes a tool call.", es: "Se ejecuta antes de que Codex corra una llamada a herramienta."),
        "hooks.PostToolUse": .init("Runs after a tool call finishes.", es: "Se ejecuta después de que termina una llamada a herramienta."),
        "hooks.SessionStart": .init("Runs when a new Codex session starts.", es: "Se ejecuta al iniciar una nueva sesión de Codex."),
        "hooks.SessionEnd": .init("Runs when a Codex session ends.", es: "Se ejecuta al terminar una sesión de Codex."),
        "hooks.SubagentStart": .init("Runs when Codex spawns a subagent.", es: "Se ejecuta cuando Codex crea un subagente."),
        "hooks.SubagentStop": .init("Runs when a subagent finishes.", es: "Se ejecuta cuando un subagente termina."),
        "hooks.UserPromptSubmit": .init("Runs when the user submits a prompt.", es: "Se ejecuta cuando el usuario envía un prompt."),
        "hooks.Stop": .init("Runs when the main agent stops responding.", es: "Se ejecuta cuando el agente principal deja de responder."),
        "hooks.Interrupt": .init("Runs when a running agent is interrupted.", es: "Se ejecuta cuando se interrumpe un agente en curso."),
        "permissions": .init("Named permission profiles ([permissions.<name>]): filesystem, workspace roots and network rules. Select one with default_permissions.",
                             es: "Perfiles de permisos con nombre ([permissions.<name>]): sistema de archivos, raíces del workspace y reglas de red. Se elige uno con default_permissions."),
        "permissions.<name>": .init("A named permission profile; select it with default_permissions.",
                                    es: "Un perfil de permisos con nombre; se elige con default_permissions."),
        "permissions.<name>.network": .init("Network access rules for this permission profile (enabled, mode, domains, proxy, unix sockets).",
                                            es: "Reglas de acceso a red de este perfil de permisos (enabled, mode, domains, proxy, unix sockets)."),
        "skills": .init("Skill settings: bundled skills, per-skill entries in skills.config, and context budget.",
                        es: "Ajustes de skills: skills incluidas, entradas por skill en skills.config y presupuesto de contexto."),
        "features.js_repl": .init("Retired feature switch: the official reference lists js_repl = true as rejected.",
                                  es: "Interruptor retirado: la referencia oficial indica que js_repl = true se rechaza."),
        "profiles": .init("Legacy inline profiles. Codex 0.134.0 and later selects separate <name>.config.toml files with --profile; it no longer reads this table.",
                          es: "Perfiles inline antiguos. Codex 0.134.0 y posteriores seleccionan archivos <nombre>.config.toml mediante --profile; ya no leen esta tabla."),
        "personality": .init("Tone/style of the agent's answers.",
                             es: "Tono/estilo de las respuestas del agente.",
                             values: ["friendly": "Warm", "pragmatic": "Direct", "none": "Neutral"],
                             valuesES: ["friendly": "Cercano", "pragmatic": "Directo", "none": "Neutral"]),
        "review_model": .init("Separate model for code review (/review), if you want it different from the main one.",
                              es: "Modelo distinto usado para code review (/review), si quieres separarlo del principal."),
        "hide_agent_reasoning": .init("Hides agent reasoning in the TUI and codex exec (cleaner answers). See also show_raw_agent_reasoning.",
                                      es: "Oculta el razonamiento del agente en el TUI y en codex exec (respuestas más limpias). Ver también show_raw_agent_reasoning."),
        "show_raw_agent_reasoning": .init("Shows the model's raw, unsummarized reasoning instead of the default summary.",
                                          es: "Muestra el razonamiento crudo del modelo, sin resumir, en vez del resumen por defecto."),
        "agents": .init("Multi-agent / subagent settings: default model and reasoning effort for spawned subagents, and how many can run concurrently.",
                        es: "Ajustes de multi-agente/subagentes: modelo y esfuerzo de razonamiento por defecto para los subagentes que se crean, y cuántos pueden correr a la vez."),
        "agents.enabled": .init("Enables multi-agent tools (spawning subagents).", es: "Activa las herramientas de multi-agente (creación de subagentes).", def: "true"),
        "agents.default_subagent_model": .init("Default model used for subagents Codex spawns.",
                                                es: "Modelo por defecto usado para los subagentes que crea Codex."),
        "agents.default_subagent_reasoning_effort": .init("Default reasoning effort for those subagents.",
                                                           es: "Esfuerzo de razonamiento por defecto de esos subagentes."),
        "agents.max_concurrent_threads_per_session": .init("Maximum number of subagent threads running at once, per session.",
                                                            es: "Máximo de hilos de subagentes corriendo a la vez, por sesión."),
        "agents.interrupt_message": .init("Shows the model a visible message when a subagent gets interrupted.",
                                          es: "Muestra al modelo un mensaje visible cuando se interrumpe un subagente.", def: "true"),
    ]

    private static let opencodeKeys: [String: KeyDoc] = [
        "provider": .init("Model providers (OpenAI, Anthropic, compatible endpoints). API keys, baseURL and per-provider options go here.",
                          es: "Providers de modelos (OpenAI, Anthropic, endpoints compatibles). Aquí van API keys, baseURL y opciones por provider."),
        "mcp": .init("MCP servers: \"local\" uses command (array) + environment; \"remote\" uses url. \"enabled\" toggles.",
                     es: "Servidores MCP: \"local\" usa command (array) + environment; \"remote\" usa url. \"enabled\" activa/desactiva."),
        "agent": .init("Custom agents: prompt, model and tools per agent (primary, build, plan…).",
                       es: "Agentes personalizados: prompt, modelo y herramientas por agente (primary, build, plan…)."),
        "model": .init("Default model in \"provider/model\" format.",
                       es: "Modelo por defecto en formato \"provider/modelo\"."),
        "small_model": .init("Lightweight model for small tasks (titles, summaries) — saves cost.",
                             es: "Modelo ligero para tareas pequeñas (títulos, resúmenes) — ahorra coste."),
        "theme": .init("OpenCode TUI theme.", es: "Tema del TUI de OpenCode."),
        "keybinds": .init("Keyboard shortcut remapping.", es: "Reasignación de atajos de teclado de la interfaz."),
        "autoshare": .init("Automatically shares sessions (opencode.ai).",
                          es: "Comparte sesiones automáticamente (opencode.ai).",
                          values: ["auto": "Always share", "disabled": "Never"],
                          valuesES: ["auto": "Comparte siempre", "disabled": "Nunca"]),
        "autoupdate": .init("Automatic CLI updates.", es: "Actualizaciones automáticas del CLI."),
        "disabled_providers": .init("Installed but disabled providers — not offered as an option.",
                                    es: "Providers instalados pero desactivados — no se ofrecen como opción."),
        "permission": .init("Per-tool permissions (edit, bash, webfetch…): allow/ask/deny.",
                            es: "Permisos por herramienta (edit, bash, webfetch…): allow/ask/deny."),
        "instructions": .init("Extra instruction files the agent loads besides AGENTS.md.",
                              es: "Archivos extra de instrucciones que el agente carga además de AGENTS.md."),
        "formatter": .init("Per-language code formatters (command + extensions).",
                           es: "Formateadores de código por lenguaje (comando + extensiones)."),
        "lsp": .init("LSP servers OpenCode starts to understand your code.",
                     es: "Servidores LSP que OpenCode arranca para entender tu código."),
        "watcher": .init("Configures the agent's file watcher (ignored patterns).",
                         es: "Configura el file-watcher del agente (patrones ignorados)."),
        "compaction": .init("Context compaction: when and how history is summarized.",
                            es: "Compactación del contexto: cuándo y cómo se resume el historial."),
    ]

    private static let geminiKeys: [String: KeyDoc] = [
        "general": .init("General Gemini CLI preferences, including editor and session behavior.", es: "Preferencias generales de Gemini CLI, incluido el editor y el comportamiento de sesión."),
        "ui": .init("Terminal interface preferences such as theme and visibility.", es: "Preferencias de interfaz de terminal, como tema y visibilidad."),
        "context": .init("Instruction discovery and file filtering settings.", es: "Ajustes de descubrimiento de instrucciones y filtrado de archivos."),
        "context.fileName": .init("Instruction filename or list of filenames used for context discovery.", es: "Nombre o lista de nombres de archivos usados para descubrir instrucciones."),
        "tools": .init("Tool behavior and execution settings.", es: "Ajustes de comportamiento y ejecución de herramientas."),
        "hooks": .init("Lifecycle hooks configured for this scope. Finding a hook does not confirm it runs in a session.", es: "Hooks del ciclo de vida configurados para este alcance. Encontrarlos no confirma su ejecución en una sesión."),
        "model.name": .init("Model selected in the model settings object.", es: "Modelo seleccionado dentro del objeto de ajustes de modelo."),
        "selectedAuthType": .init("How you authenticate with Gemini.",
                                  es: "Cómo te autenticas con Gemini.",
                                  values: ["oauth-personal": "Personal Google account", "gemini-api-key": "API key", "vertex-ai": "Vertex AI (GCP)"],
                                  valuesES: ["oauth-personal": "Cuenta Google personal", "gemini-api-key": "API key", "vertex-ai": "Vertex AI (GCP)"]),
        "theme": .init("CLI interface theme.", es: "Tema de la interfaz del CLI."),
        "ide": .init("IDE integration: shares context (open file, selection) with the editor.",
                     es: "Integración con IDE: comparte contexto (archivo abierto, selección) con el editor."),
        "security": .init("Security options: auth type, tool restrictions.",
                          es: "Opciones de seguridad: auth type, restricciones de herramientas."),
        "mcpServers": .init("MCP servers available to Gemini CLI.",
                            es: "Servidores MCP disponibles para Gemini CLI."),
        "contextFileName": .init("Name of the context file Gemini reads by default (usually GEMINI.md).",
                                 es: "Nombre del archivo de contexto que Gemini lee por defecto (normalmente GEMINI.md)."),
        "checkpointing": .init("Project checkpoints: lets you revert agent-made changes.",
                               es: "Checkpoints del proyecto: permite revertir cambios hechos por el agente."),
        "telemetry": .init("Telemetry/OTel: destination of agent metrics and logs.",
                           es: "Telemetría/OTel: destino de métricas y logs del agente."),
        "usageStatisticsEnabled": .init("Sends usage statistics to Google.",
                                        es: "Envío de estadísticas de uso a Google."),
        "maxSessionTurns": .init("Maximum turns per session before stopping (-1 = unlimited).",
                                 es: "Máximo de turnos por sesión antes de parar (-1 = sin límite)."),
        "preferredEditor": .init("Preferred editor for opening diffs/files from the CLI.",
                                 es: "Editor preferido para abrir diffs/archivos desde el CLI."),
        "autoAccept": .init("Auto-accepts actions without asking.",
                            es: "Acepta acciones automáticamente sin preguntar."),
        "hideTips": .init("Hides UI tips.", es: "Oculta los tips de la interfaz."),
    ]
}
