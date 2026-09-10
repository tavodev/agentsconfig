import Foundation

/// In-app language. English is the source of truth in code; Spanish lives
/// in the `es` table below. `Loc.shared.lang` is @Observable, so every
/// `L(...)` call inside a view body re-renders instantly on switch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, es
    var id: String { rawValue }
    var label: String { self == .en ? "English" : "Español" }
}

@Observable
@MainActor
final class Loc {
    static let shared = Loc()

    var lang: AppLanguage {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "appLanguage") }
    }

    private init() {
        lang = AppLanguage(rawValue:
            UserDefaults.standard.string(forKey: "appLanguage") ?? "en") ?? .en
    }

    func t(_ en: String) -> String {
        guard lang == .es, let s = Self.es[en] else { return en }
        return s
    }

    func t(_ en: String, _ args: CVarArg...) -> String {
        String(format: t(en), arguments: args)
    }

    // MARK: - Spanish translations (key = English source string)

    private static let es: [String: String] = [
        // Sidebar / panels
        "Activity": "Actividad",
        "change feed": "feed de cambios",
        "cross-agent comparator": "comparador entre agentes",
        "Detected agents": "Agentes detectados",
        "No agents": "Sin agentes",
        "No AI agents detected in ~": "No se detectaron agentes de IA en ~",
        "Files": "Archivos",
        "Filter files": "Filtrar archivos",
        "Filter changes": "Filtrar cambios",
        "Filter servers": "Filtrar servidores",
        "%d files watched": "%d archivos vigilados",
        "%d files": "%d archivos",
        "%d external change(s)": "%d cambio(s) externo(s)",
        "%d pending": "%d pendiente(s)",

        // Menus & actions
        "Show in Finder": "Mostrar en Finder",
        "Open folder in Finder": "Abrir carpeta en Finder",
        "Open with default app": "Abrir con app por defecto",
        "Copy path": "Copiar ruta",
        "Restore previous version": "Restaurar versión anterior",
        "Dismiss change banner": "Descartar banner de cambios",
        "Re-scan": "Re-escanear",
        "Save": "Guardar",
        "Discard": "Descartar",
        "Cancel": "Cancelar",
        "Restore": "Restaurar",
        "Close": "Cerrar",
        "Add": "Añadir",
        "Open": "Abrir",
        "Open file": "Abrir archivo",
        "Open AgentsConfig": "Abrir AgentsConfig",
        "Quit": "Salir",
        "Open history folder": "Abrir carpeta de historial",
        "Find in file": "Buscar en el archivo",
        "Show inspector": "Mostrar inspector",
        "Hide inspector": "Ocultar inspector",
        "Copy here": "Copiar aquí",
        "Copy %@ to %@": "Copiar «%@» a %@",
        "Restore this version": "Restaurar esta versión",
        "Restore this version?": "¿Restaurar esta versión?",

        // Status / tooltips
        "Modified outside the app — check the diff": "Modificado fuera de la app — revisa el diff",
        "Modified outside the app": "Modificado fuera de la app",
        "You have unsaved changes": "Tienes cambios sin guardar",
        "File does not exist on disk": "El archivo no existe en disco",
        "Read-only": "Solo lectura",
        "read-only": "solo lectura",
        "State file — changes frequently": "Archivo de estado — muy activo",
        "Issues detected": "Problemas detectados",
        "Issues": "Problemas",
        "Unsaved": "Sin guardar",
        "In sync with disk": "Sincronizado con disco",
        "View diff": "Ver diff",
        "Revert": "Revertir",
        "Edit conflict": "Conflicto de edición",
        "The file changed on disk while you had unsaved edits.": "El archivo cambió en disco mientras tenías ediciones sin guardar.",
        "Keep mine": "Mantener mi versión",
        "Use disk version": "Usar la de disco",
        "Managed by a third party": "Contenido gestionado por terceros",
        "Managed by third parties": "Gestionado por terceros",

        // Tabs
        "Structured": "Estructurado",
        "Source": "Fuente",
        "History": "Historial",

        // Empty states & hints
        "Select a file": "Selecciona un archivo",
        "Pick an agent and a config file to inspect it.": "Elige un agente y un archivo de configuración para inspeccionarlo.",
        "What is this file?": "¿Qué es este archivo?",
        "Official docs": "Documentación oficial",
        "Empty file — edit it in the Source tab.": "Archivo vacío — edítalo en la pestaña Fuente.",
        "Rendered preview — edit in the Source tab.": "Vista previa renderizada — edita en la pestaña Fuente.",
        "No structured view for %@": "Sin vista estructurada para %@",
        "This format is edited as text.": "Este formato se edita como texto.",
        "Go to Source": "Ir a Fuente",
        "No selection": "Sin selección",

        // Activity
        "No activity yet": "Sin actividad todavía",
        "Every change an agent — or this app — makes to configs will show up here.": "Aquí aparecerá cada cambio que un agente —o esta app— haga en las configuraciones.",
        "Change detail": "Detalle del cambio",
        "Select an event": "Selecciona un evento",
        "Change detail unavailable for events before this session. Open the file and check its History.": "Detalle de cambios no disponible para eventos previos a esta sesión. Abre el archivo y revisa su Historial.",

        // MCP
        "MCP servers": "Servidores MCP",
        "No MCP servers": "Sin MCP servers",
        "No agent declares MCP servers in its config.": "Ningún agente declara servidores MCP en su configuración.",
        "remote": "remoto",
        "local": "local",
        "%d of %d agents": "%d de %d agentes",
        "Select a server": "Selecciona un servidor",
        "Pick an MCP server to compare its configuration across agents.": "Elige un MCP server para comparar su configuración entre agentes.",
        "enabled": "activo",
        "disabled": "desactivado",
        "not configured": "no configurado",

        // History
        "No history": "Sin historial",
        "Snapshots are created when the file changes or you edit it here.": "Los snapshots se crean cuando el archivo cambia o lo editas desde aquí.",
        "Compare with": "Comparar con",
        "Current on disk": "Actual en disco",
        "Another version": "Otra versión",
        "This version": "Esta versión",
        "Current content will be kept as another history snapshot.": "El contenido actual quedará guardado como un snapshot más del historial.",
        "Select a version": "Selecciona una versión",
        "base": "base",
        "external": "externo",
        "this app": "esta app",
        "revert": "revert",

        // Diff
        "Changes detected": "Cambios detectados",
        "No semantic differences": "Sin diferencias semánticas",
        "Content changed only in formatting or comments.": "El contenido cambió solo en formato o comentarios.",
        "No differences": "Sin diferencias",
        "no semantic changes": "sin cambios semánticos",

        // Inspector / metadata
        "Metadata": "Metadatos",
        "Format": "Formato",
        "Role": "Rol",
        "Size": "Tamaño",
        "Modified": "Modificado",
        "Permissions": "Permisos",
        "Type": "Tipo",
        "volatile (state)": "volátil (estado)",
        "Access": "Acceso",
        "Actions": "Acciones",

        // Roles
        "Settings": "Ajustes",
        "Instructions": "Instrucciones",
        "Hooks": "Hooks",
        "Skills": "Skills",
        "Sub-agents": "Subagentes",
        "Plugins": "Plugins",
        "State": "Estado",
        "Other": "Otro",

        // Structured view
        "Fix the error in the Source tab to enable the structured view.": "Corrige el error en la pestaña Fuente para activar la vista estructurada.",
        "This file is not a structured JSON/TOML object.": "Este archivo no es un objeto JSON/TOML estructurado.",
        "Read-only structured view — edit in the Source tab (%@ format).": "Vista estructurada de solo lectura — edita en la pestaña Fuente (formato %@).",
        "Structured editing rewrites the TOML — comments and formatting are normalized on save.": "La edición estructurada reescribe el TOML — comentarios y formato se normalizan al guardar.",
        "Enabled plugins": "Plugins habilitados",
        "Environment variables": "Variables de entorno",
        "Default: %@": "Por defecto: %@",
        "Name": "Nombre",
        "Command (e.g. npx)": "Comando (p. ej. npx)",
        "Args (space-separated)": "Args (separados por espacio)",
        "or remote URL (http…)": "o URL remota (http…)",
        "Command available": "Comando disponible",
        "Missing path: %@": "Ruta inexistente: %@",
        "value": "valor",
        "All keys": "Todas las claves",
        "Add rule…": "Añadir regla…",

        // Settings
        "Appearance": "Apariencia",
        "Language": "Idioma",
        "Theme": "Tema",
        "System": "Sistema",
        "Light": "Claro",
        "Dark": "Oscuro",
        "Menu bar icon": "Icono en la barra de menús",
        "Monitoring": "Monitoreo",
        "Notify when an agent modifies a config": "Notificación cuando un agente modifica una config",
        "Watcher debounce": "Debounce del watcher",
        "History per file: %d versions": "Historial por archivo: %d versiones",
        "Privacy": "Privacidad",
        "Mask secrets (API keys, tokens…)": "Enmascarar secretos (api keys, tokens…)",
        "config modified": "config modificada",
        "No changes detected": "Sin cambios detectados",

        // Linter / engine messages (computed at event time)
        "Hook points to a missing file: %@": "Hook referencia un archivo inexistente: %@",
        "Orca hooks detected but ~/.orca no longer exists — they are inert.": "Hooks de Orca detectados pero ~/.orca ya no existe — son inertes.",
        "Empty file.": "Archivo vacío.",
        "Unrecognized key: «%@» — typo or new agent key?": "Clave no reconocida: «%@» — ¿typo o key nueva del agente?",
        "Delimited block «%@» — managed by an external tool": "Bloque delimitado «%@» — gestionado por herramienta externa",
        "hooks.state — trust hashes managed by Codex": "hooks.state — hashes de confianza gestionados por Codex",
        "plugins/marketplaces — managed by the Codex app": "plugins/marketplaces — gestionados por la app de Codex",
        "Internal state (projects, surveys) — rewrites itself": "Estado interno (projects, surveys) — se reescribe solo",
        "TOML→JSON empty": "TOML→JSON vacío",
        "Invalid TOML: %@": "TOML inválido: %@",
        "Invalid JSON — error near line %d: %@": "JSON inválido — error cerca de la línea %d: %@",
        "Invalid JSON: %@": "JSON inválido: %@",

        // Agent & file notes (AgentRegistry)
        "Global user settings": "Ajustes globales de usuario",
        "Global instructions (memory)": "Instrucciones globales (memoria)",
        "Global instructions": "Instrucciones globales",
        "Hook scripts": "Scripts de hooks",
        "Custom commands": "Comandos personalizados",
        "Status line": "Status line",
        "Global state + MCP servers (very active, live view only)": "Estado global + MCP servers (muy activo, solo vista en vivo)",
        "Precedence: managed > local > project > user. Global MCP servers live in ~/.claude.json → mcpServers.": "Precedencia: managed > local > proyecto > usuario. Los MCP globales viven en ~/.claude.json → mcpServers.",
        "Main config (TOML): model, sandbox, MCP, plugins, projects": "Config principal (TOML): modelo, sandbox, MCP, plugins, proyectos",
        "Prefix rules (allow/deny)": "Reglas de prefijos (allow/deny)",
        "Credentials — read-only": "Credenciales — solo lectura",
        "Profiles: ~/.codex/<name>.config.toml. Per-project overrides in .codex/config.toml.": "Perfiles: ~/.codex/<nombre>.config.toml. Overrides por proyecto en .codex/config.toml.",
        "Gemini CLI / shared": "Gemini CLI / compartido",
        "Shared MCP (post-migration 2.0)": "MCP compartido (post-migración 2.0)",
        "Plugins + userSettings": "Plugins + userSettings",
        "Legacy (pre-migration): may be ignored": "Legacy (pre-migración): puede estar ignorado",
        "IDE settings (VS Code style)": "Ajustes del IDE (estilo VS Code)",
        "Antigravity app, IDE and CLI share ~/.gemini/config after migration (marker: .migrated).": "Antigravity app, IDE y CLI comparten ~/.gemini/config tras la migración (marca: .migrated).",
        "Providers, models and MCP": "Providers, modelos y MCP",
        "Declares $schema — validatable against https://opencode.ai/config.json.": "Declara $schema — validable contra https://opencode.ai/config.json.",
    ]
}

/// Shorthand used everywhere: `Text(L("Save"))`, `L("%d files watched", n)`.
@MainActor
@inline(__always) func L(_ en: String) -> String { Loc.shared.t(en) }
@MainActor
@inline(__always) func L(_ en: String, _ args: CVarArg...) -> String {
    Loc.shared.t(en, args)
}
