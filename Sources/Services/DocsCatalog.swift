import Foundation

/// Inline documentation: what a config file is for, and what each known
/// key does (with accepted values). Content in Spanish, matching the UI.
enum DocsCatalog {

    struct FileDoc {
        let title: String
        let body: String
        let docsURL: URL?
    }

    struct KeyDoc {
        let summary: String
        let values: [String: String]?   // valor → explicación
        let defaultValue: String?

        init(_ s: String, values: [String: String]? = nil, def: String? = nil) {
            summary = s; self.values = values; defaultValue = def
        }
    }

    // MARK: - File docs

    static func fileDoc(for path: String) -> FileDoc? {
        let home = NSHomeDirectory()
        let name = URL(fileURLWithPath: path).lastPathComponent
        switch path {
        case "\(home)/.claude/settings.json":
            return .init(
                title: "Ajustes globales de Claude Code",
                body: "Configuración a nivel usuario que se aplica a todas tus sesiones de Claude Code: modelo por defecto, permisos de herramientas, hooks, plugins activados y variables de entorno.\n\nPrecedencia: sistema gestionado > local > proyecto > usuario (este archivo).",
                docsURL: URL(string: "https://code.claude.com/docs/en/settings")
            )
        case "\(home)/.claude/mcp.json":
            return .init(
                title: "Servidores MCP de Claude",
                body: "Lista de servidores MCP (Model Context Protocol) disponibles para Claude. Cada entrada define un comando local (stdio) o una URL remota que expone herramientas extra al agente.",
                docsURL: nil
            )
        case "\(home)/.claude.json":
            return .init(
                title: "Estado global de Claude Code",
                body: "Archivo grande mantenido por Claude Code con estado global: proyectos conocidos, historial y —dentro de la clave mcpServers— los MCP a nivel usuario.\n\nCambia constantemente: se vigila en vivo pero sin historial.",
                docsURL: nil
            )
        case "\(home)/.codex/config.toml":
            return .init(
                title: "Configuración de Codex",
                body: "Archivo principal de Codex (formato TOML): modelo y esfuerzo de razonamiento, política de aprobación, sandbox, MCP servers, plugins y proyectos de confianza.\n\nCodex reescribe partes de este archivo; las secciones [hooks.state] son estado interno.",
                docsURL: URL(string: "https://developers.openai.com/codex/config-reference")
            )
        case "\(home)/.codex/hooks.json":
            return .init(
                title: "Hooks de Codex",
                body: "Scripts que Codex ejecuta en eventos del ciclo de vida (antes/después de herramientas, al iniciar sesión…). Revisa que las rutas apuntadas existan — los hooks rotos fallan en silencio.",
                docsURL: nil
            )
        case "\(home)/.gemini/settings.json":
            return .init(
                title: "Ajustes de Gemini CLI",
                body: "Preferencias del CLI de Gemini: autenticación seleccionada, tema, integración con IDE, checkpoints y servidores MCP.",
                docsURL: nil
            )
        case "\(home)/.gemini/config/mcp_config.json":
            return .init(
                title: "MCP de Antigravity/Gemini (post-migración)",
                body: "Tras la migración 2.0, Antigravity (app, IDE y CLI) comparte esta carpeta: aquí viven los servidores MCP comunes.",
                docsURL: nil
            )
        case "\(home)/.gemini/antigravity/mcp_config.json":
            return .init(
                title: "MCP de Antigravity (legacy)",
                body: "Ubicación anterior a la migración. Si existe ~/.gemini/config/mcp_config.json, este archivo puede estar ignorado — verifica antes de editar.",
                docsURL: nil
            )
        case "\(home)/.config/opencode/opencode.json":
            return .init(
                title: "Configuración de OpenCode",
                body: "Providers (API keys/endpoints), modelo por defecto, agentes personalizados, MCP servers y atajos de teclado.\n\nDeclara $schema: el archivo es validable contra el esquema oficial.",
                docsURL: nil
            )
        case "\(home)/Library/Application Support/Antigravity/User/settings.json":
            return .init(
                title: "Ajustes del IDE Antigravity",
                body: "Preferencias de la interfaz del IDE (estilo VS Code): tema, fuente, comportamiento del editor.",
                docsURL: nil
            )
        default:
            break
        }
        // Patrones por nombre de archivo
        switch name {
        case "CLAUDE.md":
            return .init(title: "Memoria global de Claude",
                         body: "Instrucciones que Claude Code lee al inicio de cada sesión, en todos los proyectos. Úsalo para preferencias persistentes: estilo, convenciones, herramientas favoritas.",
                         docsURL: nil)
        case "AGENTS.md":
            return .init(title: "Instrucciones para agentes",
                         body: "Convenciones leídas por agentes compatibles (Codex, OpenCode, Devin…) al trabajar. Es el equivalente de CLAUDE.md pero cross-agente.",
                         docsURL: nil)
        case "GEMINI.md":
            return .init(title: "Memoria global de Gemini",
                         body: "Contexto e instrucciones que Gemini CLI carga en cada sesión.",
                         docsURL: nil)
        case "SKILL.md":
            return .init(title: "Skill de agente",
                         body: "Una skill empaqueta instrucciones + recursos que el agente invoca cuando el nombre/disparador coincide. El frontmatter YAML define cuándo aplica.",
                         docsURL: nil)
        case "auth.json", "credentials.json", ".credentials.json":
            return .init(title: "Credenciales",
                         body: "Tokens de autenticación del agente. Solo lectura aquí — edítalo solo a través del agente (login/logout). Los valores se muestran enmascarados.",
                         docsURL: nil)
        case "installed_plugins.json":
            return .init(title: "Plugins instalados",
                         body: "Registro de plugins instalados por el gestor del agente. Normalmente lo mantiene el agente; edítalo solo si sabes qué plugin quieres forzar.",
                         docsURL: nil)
        case "statusline.sh":
            return .init(title: "Status line",
                         body: "Script que alimenta la barra de estado del agente. Debe imprimir por stdout; errores aquí se ven como status vacío.",
                         docsURL: nil)
        default:
            if name.hasSuffix(".rules") {
                return .init(title: "Reglas de permisos",
                             body: "Listas de prefijos de comandos permitidos/denegados (DSL propio del agente). El agente las consulta antes de ejecutar shell commands.",
                             docsURL: nil)
            }
            return nil
        }
    }

    // MARK: - Key docs

    /// Documentación por key: lookup por ruta punteada dentro del archivo
    /// (ej. "permissions.allow"), con fallback a top-level.
    static func keyDoc(filePath: String, keyPath: [String]) -> KeyDoc? {
        guard let table = keyTables[filePath] else { return nil }
        let dotted = keyPath.joined(separator: ".")
        return table[dotted] ?? keyPath.last.flatMap { table[$0] }
    }

    private static var keyTables: [String: [String: KeyDoc]] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.claude/settings.json": claudeKeys,
            "\(home)/.codex/config.toml": codexKeys,
            "\(home)/.config/opencode/opencode.json": opencodeKeys,
            "\(home)/.gemini/settings.json": geminiKeys,
        ]
    }

    private static let claudeKeys: [String: KeyDoc] = [
        "model": .init("Modelo por defecto de Claude Code.",
                       values: ["sonnet": "Equilibrado, rápido", "opus": "Máxima capacidad", "haiku": "Más barato y veloz"]),
        "effortLevel": .init("Nivel de esfuerzo de razonamiento del modelo.",
                             values: ["low": "Respuestas rápidas", "high": "Razona más profundo", "max": "Máximo esfuerzo"]),
        "permissions": .init("Qué puede hacer Claude sin pedirte aprobación: herramientas y comandos permitidos, denegados o que preguntan."),
        "permissions.allow": .init("Reglas permitidas sin confirmación. Ej: \"Bash(git status)\" permite ese comando exacto; \"Bash(npm run *)\" permite el patrón."),
        "permissions.deny": .init("Reglas siempre denegadas — el agente no puede ejecutarlas aunque las pida."),
        "permissions.ask": .init("Reglas que siempre piden confirmación, aunque estén permitidas en otra capa."),
        "permissions.defaultMode": .init("Comportamiento por defecto ante herramientas no listadas.",
                                         values: ["default": "Pregunta según la herramienta",
                                                  "acceptEdits": "Auto-acepta ediciones de archivos",
                                                  "bypassPermissions": "Nunca pregunta (peligroso)",
                                                  "plan": "Solo planea, no ejecuta"]),
        "permissions.additionalDirectories": .init("Directorios extra a los que el agente puede acceder fuera del proyecto."),
        "env": .init("Variables de entorno inyectadas a cada sesión de Claude Code (timeouts, feature flags, endpoints)."),
        "hooks": .init("Scripts ejecutados en eventos: PreToolUse, PostToolUse, SessionStart, UserPromptSubmit… Cada hook recibe contexto JSON por stdin."),
        "statusLine": .init("Comando cuya salida se muestra en la barra de estado inferior."),
        "enabledPlugins": .init("Plugins activados, por marketplace (ej. \"nombre@marketplace\": true)."),
        "extraKnownMarketplaces": .init("Marketplaces de plugins adicionales que el agente conoce."),
        "mcpServers": .init("Servidores MCP a nivel usuario (también pueden vivir en ~/.claude/mcp.json)."),
        "apiKeyHelper": .init("Script que genera la API key dinámicamente (para auth rotativa)."),
        "cleanupPeriodDays": .init("Días tras los cuales se borran historiales de chat viejos.", def: "30"),
        "includeCoAuthoredBy": .init("Añade \"Co-Authored-By: Claude\" a los commits que haga el agente.", def: "true"),
        "autoUpdates": .init("Actualizaciones automáticas de Claude Code.", def: "true"),
        "language": .init("Idioma de las respuestas del agente."),
        "alwaysThinkingEnabled": .init("Mantiene el modo de razonamiento extendido siempre activo."),
        "autoMode": .init("Modo de autonomía: cuánto decide el agente sin consultar."),
        "voiceEnabled": .init("Entrada por voz en el CLI."),
        "verbose": .init("Log detallado de las operaciones del agente."),
        "theme": .init("Tema de la interfaz del CLI."),
        "skillOverrides": .init("Overrides por skill: permite activar/desactivar skills concretas sin borrarlas."),
    ]

    private static let codexKeys: [String: KeyDoc] = [
        "model": .init("Modelo usado por Codex (ej. gpt-5, gpt-6-astra)."),
        "model_reasoning_effort": .init("Cuánto razona el modelo antes de responder.",
                                        values: ["minimal": "Mínimo — más rápido", "low": "Bajo", "medium": "Equilibrado",
                                                 "high": "Alto — mejor en tareas complejas", "xhigh": "Extra alto, más lento"]),
        "model_context_window": .init("Tamaño de la ventana de contexto en tokens. Bájalo si tu plan limita el contexto."),
        "model_auto_compact_token_limit": .init("Umbral de tokens donde Codex compacta automáticamente el historial de la sesión."),
        "approval_policy": .init("Cuándo Codex pide aprobación antes de actuar.",
                                 values: ["untrusted": "Pregunta ante todo no-confiable", "on-failure": "Solo si un comando falla",
                                          "on-request": "El modelo decide cuándo pedir", "never": "Nunca pide — usa con sandbox estricto"]),
        "sandbox_mode": .init("Nivel de aislamiento al ejecutar comandos.",
                              values: ["read-only": "Solo lee tu sistema de archivos",
                                       "workspace-write": "Puede escribir en el proyecto",
                                       "danger-full-access": "Acceso total — sin sandbox"]),
        "approvals_reviewer": .init("Quién revisa las aprobaciones (guardian / usuario)."),
        "notify": .init("Comando al que Codex envía notificaciones de eventos (ej. un script de sonido o un toast)."),
        "projects": .init("Directorios marcados como de confianza. Codex trata diferente los proyectos trusted vs nuevos."),
        "mcp_servers": .init("Servidores MCP disponibles para Codex: [mcp_servers.nombre] con command/args/env o url remota."),
        "features": .init("Feature flags experimentales o beta que Codex reconoce."),
        "plugins": .init("Plugins instalados y su estado (enabled, ruta, marketplace)."),
        "marketplaces": .init("Marketplaces de plugins configurados (GitHub repos, locales…)."),
        "desktop": .init("Ajustes de la app de escritorio de Codex (notificaciones, comportamiento)."),
        "shell_environment_policy": .init("Qué variables de entorno heredan los comandos que ejecuta Codex (incluir/excluir/patrones)."),
        "tui": .init("Ajustes de la interfaz de terminal (animaciones, notificaciones de terminal, paste multi-línea)."),
        "hooks": .init("Hooks de ciclo de vida + [hooks.state] = hashes internos que Codex usa para detectar cambios."),
        "profiles": .init("Perfiles nombrados de configuración — activables con --profile o CODEX_PROFILE."),
        "personality": .init("Tono/estilo de las respuestas del agente.",
                             values: ["friendly": "Cercano", "pragmatic": "Directo", "none": "Neutral"]),
        "review_model": .init("Modelo distinto usado para code review, si quieres separarlo del principal."),
        "hide_agent_reasoning": .init("Oculta el razonamiento del agente en la UI (respuestas más limpias)."),
    ]

    private static let opencodeKeys: [String: KeyDoc] = [
        "provider": .init("Providers de modelos (OpenAI, Anthropic, endpoints compatibles). Aquí van API keys, baseURL y opciones por provider."),
        "mcp": .init("Servidores MCP: \"local\" usa command (array) + environment; \"remote\" usa url. \"enabled\" activa/desactiva."),
        "agent": .init("Agentes personalizados: prompt, modelo y herramientas por agente (primary, build, plan…)."),
        "model": .init("Modelo por defecto en formato \"provider/modelo\"."),
        "small_model": .init("Modelo ligero para tareas pequeñas (títulos, resúmenes) — ahorra coste."),
        "theme": .init("Tema del TUI de OpenCode."),
        "keybinds": .init("Reasignación de atajos de teclado de la interfaz."),
        "autoshare": .init("Comparte sesiones automáticamente (opencode.ai).",
                          values: ["true/false": "—", "auto": "Comparte siempre", "disabled": "Nunca"]),
        "autoupdate": .init("Actualizaciones automáticas del CLI."),
        "disabled_providers": .init("Providers instalados pero desactivados — no se ofrecen como opción."),
        "permission": .init("Permisos por herramienta (edit, bash, webfetch…): allow/ask/deny."),
        "instructions": .init("Archivos extra de instrucciones que el agente carga además de AGENTS.md."),
        "formatter": .init("Formateadores de código por lenguaje (comando + extensiones)."),
        "lsp": .init("Servidores LSP que OpenCode arranca para entender tu código."),
        "watcher": .init("Configura el file-watcher del agente (patrones ignorados)."),
        "compaction": .init("Compactación del contexto: cuándo y cómo se resume el historial."),
    ]

    private static let geminiKeys: [String: KeyDoc] = [
        "selectedAuthType": .init("Cómo te autenticas con Gemini.",
                                  values: ["oauth-personal": "Cuenta Google personal", "gemini-api-key": "API key", "vertex-ai": "Vertex AI (GCP)"]),
        "theme": .init("Tema de la interfaz del CLI."),
        "ide": .init("Integración con IDE: comparte contexto (archivo abierto, selección) con el editor."),
        "security": .init("Opciones de seguridad: auth type, restricciones de herramientas."),
        "mcpServers": .init("Servidores MCP disponibles para Gemini CLI."),
        "contextFileName": .init("Nombre del archivo de contexto que Gemini lee por defecto (normalmente GEMINI.md)."),
        "checkpointing": .init("Checkpoints del proyecto: permite revertir cambios hechos por el agente."),
        "telemetry": .init("Telemetría/OTel: destino de métricas y logs del agente."),
        "usageStatisticsEnabled": .init("Envío de estadísticas de uso a Google."),
        "maxSessionTurns": .init("Máximo de turnos por sesión antes de parar (-1 = sin límite)."),
        "preferredEditor": .init("Editor preferido para abrir diffs/archivos desde el CLI."),
        "autoAccept": .init("Acepta acciones automáticamente sin preguntar."),
        "hideTips": .init("Oculta los tips de la interfaz."),
    ]
}
