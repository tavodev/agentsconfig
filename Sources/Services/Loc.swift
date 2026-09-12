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
        didSet { AppSettings.defaults.set(lang.rawValue, forKey: "appLanguage") }
    }

    private init() {
        lang = AppLanguage(rawValue:
            AppSettings.defaults.string(forKey: "appLanguage") ?? "en") ?? .en
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
        // Requested improvements
        "A save is still in progress. Wait before quitting.": "Hay un guardado en curso. Espera antes de salir.",
        "Clear file history": "Vaciar historial del archivo",
        "Confirm save": "Confirmar guardado",
        "Global history settings and source exclusions still apply. Removing versions does not change the config file or legacy backups.": "Siguen vigentes los ajustes globales y las exclusiones. Eliminar versiones no cambia la configuración ni los respaldos legados.",
        "History recording is globally disabled in Settings.": "El registro de historial está desactivado globalmente en Ajustes.",
        "Large files use Source editing. Validation and saving run in the background; structured inspection and MCP indexing are omitted.": "Los archivos grandes se editan en Fuente. La validación y el guardado se ejecutan en segundo plano; se omiten la vista estructurada y el índice MCP.",
        "Large-file pages have separate undo stacks. Save reviews and validates the entire file, including other pages.": "Cada página tiene su propio deshacer. Guardar revisa y valida el archivo completo, incluidas las otras páginas.",
        "Large-file review: %d bytes on disk → %d proposed bytes. Detailed diff is omitted; inspect Source before confirming.": "Revisión de archivo grande: %d bytes en disco → %d bytes propuestos. Se omite el diff detallado; revisa Fuente antes de confirmar.",
        "Loading and validating file…": "Cargando y validando archivo…",
        "Next page": "Página siguiente",
        "Previous page": "Página anterior",
        "Preparing review…": "Preparando revisión…",
        "Record history for this file": "Registrar historial de este archivo",
        "Remove %d recorded version(s) for this file? This cannot be undone. The config file and legacy backups are kept; future changes may create new versions.": "¿Eliminar %d versiones de este archivo? No se puede deshacer. Se conservan la configuración y los respaldos legados; futuros cambios pueden crear nuevas versiones.",
        "Remove history versions?": "¿Eliminar versiones del historial?",
        "Remove this version": "Eliminar esta versión",
        "Remove versions": "Eliminar versiones",
        "Retry content cleanup": "Reintentar limpieza del contenido",
        "Review restore": "Revisar restauración",
        "Review save": "Revisar guardado",
        "Secret values remain hidden in the review. Saving writes the original values.": "Los secretos permanecen ocultos en la revisión. Se guardan los valores originales.",
        "Source page %d of %d": "Página de Fuente %d de %d",
        "The buffer changed while reading disk. Try again.": "El buffer cambió mientras se leía el disco. Inténtalo de nuevo.",
        "The buffer or history setting changed. Review the save again.": "Cambió el buffer o el ajuste de historial. Revisa el guardado de nuevo.",
        "The pasted text exceeds the page editing limit. Use smaller edits or an external editor.": "El texto pegado supera el límite de edición de la página. Usa cambios más pequeños o un editor externo.",
        "This character sequence is too large to display safely. Use an external editor.": "Esta secuencia de caracteres es demasiado grande para mostrarla de forma segura. Usa un editor externo.",
        "This save replaces the conflicting disk version.": "Este guardado reemplaza la versión de disco en conflicto.",
        "File exceeds the 16 MB background limit. Use an external editor.": "El archivo supera el límite de 16 MB. Usa un editor externo.",
        "File exceeds the 16 MB limit.": "El archivo supera el límite de 16 MB.",
        "History changed during review. Review the removal again.": "El historial cambió durante la revisión. Revisa la eliminación de nuevo.",

        // Repair acceptance: privacy, MCP review and bounded inspection
        "A local MCP server requires a command.": "Un servidor MCP local requiere un comando.",
        "A remote MCP server requires an HTTP or HTTPS URL.": "Un servidor MCP remoto requiere una URL HTTP o HTTPS.",
        "Add MCP server": "Añadir servidor MCP",
        "Add argument": "Añadir argumento",
        "An MCP server name is required.": "Se requiere un nombre para el servidor MCP.",
        "Apply to editor": "Aplicar al editor",
        "Apply updates the editor only. Save writes the file. Secret values stay hidden in this diff.": "Aplicar solo actualiza el editor. Guardar escribe el archivo. Los secretos permanecen ocultos en este diff.",
        "Argument": "Argumento",
        "Arguments (one row per argument; empty rows are preserved)": "Argumentos (una fila por argumento; se conservan las filas vacías)",
        "Cannot transfer these MCP options safely: %@": "No se pueden transferir estas opciones MCP de forma segura: %@",
        "Copy value": "Copiar valor",
        "Current": "Actual",
        "Environment or file expansion needs manual conversion between clients.": "La expansión de entorno o archivos requiere conversión manual entre clientes.",
        "Hide value": "Ocultar valor",
        "History is disabled for this destination; saving will not create a backup.": "El historial está desactivado para este destino; guardar no creará un respaldo.",
        "Invalid OpenCode MCP type.": "Tipo MCP de OpenCode inválido.",
        "JSONC comments and formatting will be normalized.": "Se normalizarán los comentarios y el formato JSONC.",
        "Large diff omitted": "Diff grande omitido",
        "MCP command and arguments have invalid types.": "El comando y los argumentos MCP tienen tipos inválidos.",
        "MCP enabled must be a boolean.": "El campo enabled de MCP debe ser booleano.",
        "MCP env and headers must map names to strings.": "Los campos env y headers de MCP deben asociar nombres con cadenas.",
        "MCP operation failed": "Falló la operación MCP",
        "MCP transport and fields disagree.": "El transporte MCP no coincide con sus campos.",
        "No supported MCP source or destination for this operation.": "No hay un origen o destino MCP compatible para esta operación.",
        "OK": "Aceptar",
        "Only this server definition is copied. Client-wide policies, approvals and login sessions are not transferred.": "Solo se copia la definición del servidor. No se transfieren políticas globales, aprobaciones ni sesiones del cliente.",
        "OpenCode command must be a nonempty string array.": "El comando de OpenCode debe ser una lista no vacía de cadenas.",
        "OpenCode remote transport may negotiate differently; the destination will use Streamable HTTP.": "El transporte remoto de OpenCode puede negociar de otra forma; el destino usará Streamable HTTP.",
        "Proposed": "Propuesto",
        "Reveal value": "Revelar valor",
        "Review MCP change": "Revisar cambio MCP",
        "Review change": "Revisar cambio",
        "Server URL": "URL del servidor",
        "Source shows real values, including secrets. Edits are saved exactly as entered.": "Fuente muestra los valores reales, incluidos secretos. Los cambios se guardan tal como se escriben.",
        "TOML comments and formatting will be normalized. Unrelated values keep their TOML types.": "Se normalizarán comentarios y formato TOML. Los demás valores conservarán sus tipos TOML.",
        "The MCP container must be an object.": "El contenedor MCP debe ser un objeto.",
        "The destination cannot preserve a disabled server in this object.": "El destino no permite conservar un servidor desactivado en este objeto.",
        "The destination changed during review. Review the operation again.": "El destino cambió durante la revisión. Revisa la operación de nuevo.",
        "The destination must contain a valid configuration object.": "El destino debe contener un objeto de configuración válido.",
        "This MCP value cannot be represented safely in TOML.": "Este valor MCP no se puede representar de forma segura en TOML.",
        "This destination cannot preserve an explicit SSE transport.": "Este destino no permite conservar un transporte SSE explícito.",
        "This file has no supported MCP adapter.": "Este archivo no tiene un adaptador MCP compatible.",
        "This replaces the existing server named %@.": "Esto reemplaza el servidor existente llamado %@.",
        "This source schema does not define per-server enabled state here.": "Este esquema de origen no define aquí un estado enabled por servidor.",
        "This source schema does not use a type field.": "Este esquema de origen no usa un campo type.",
        "Transport": "Transporte",
        "Unsaved changes": "Cambios sin guardar",
        "Unsupported MCP transport.": "Transporte MCP no compatible.",
        "File exceeds the 2 MB inspection limit. Use an external editor.": "El archivo supera el límite de inspección de 2 MB. Usa un editor externo.",
        "Record local history": "Registrar historial local",
        "New snapshots and save backups are disabled. Existing history is retained; restore with unsaved edits is blocked.": "Las nuevas versiones y respaldos están desactivados. Se conserva el historial existente; la restauración con cambios sin guardar está bloqueada.",

        // Sidebar / panels
        "Activity": "Actividad",
        "change feed": "feed de cambios",
        "cross-agent comparator": "comparador entre agentes",
        "Detected agents": "Agentes detectados",
        "No agents": "Sin agentes",
        "No AI agents detected in ~": "No se detectaron agentes de IA en ~",
        "Projects": "Proyectos",
        "Add project…": "Añadir proyecto…",
        "Remove project": "Quitar proyecto",
        "No known agent config found in this folder yet.": "Aún no se encontró configuración de ningún agente conocido en esta carpeta.",
        "Git submodule": "Submódulo de git",
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
        "The file was deleted on disk while you had unsaved edits.": "El archivo se borró en disco mientras tenías ediciones sin guardar.",
        "Keep mine": "Mantener mi versión",
        "Use disk version": "Usar la de disco",
        "Read-only file": "Archivo de solo lectura",
        "Could not read the current file": "No se pudo leer el archivo actual",
        "Backup failed — not writing: %@": "Falló el respaldo — no se escribió: %@",
        "Could not write: %@": "No se pudo escribir: %@",
        "Could not restore: %@": "No se pudo restaurar: %@",
        "Unsaved changes — save or discard before restoring": "Hay cambios sin guardar — guarda o descarta antes de restaurar",
        "Version content unavailable": "Contenido de la versión no disponible",
        "No writable config file for %@": "Sin archivo de configuración escribible para %@",
        "Cannot copy — %@ has invalid content; fix it first": "No se puede copiar — %@ tiene contenido inválido; corrígelo primero",
        "'%@' already exists in %@": "'%@' ya existe en %@",
        "Cannot serialize %@": "No se pudo serializar %@",
        "Restore version?": "¿Restaurar esta versión?",
        "The current disk content will be replaced by the previous version.": "El contenido actual en disco se reemplazará por la versión anterior.",
        "You have unsaved edits — they will be archived as a history snapshot, not lost.": "Tienes cambios sin guardar — se archivarán como una versión del historial, no se perderán.",
        "Current content will be kept as another history snapshot.": "El contenido actual se conservará como otra versión del historial.",
        "Retry": "Reintentar",
        "Dismiss": "Descartar",
        "Not found on disk": "No se encuentra en disco",
        "%d file(s) have unsaved edits. Quitting discards them — they are not saved to disk or history.": "%d archivo(s) tienen cambios sin guardar. Salir los descarta — no se guardan en disco ni en el historial.",
        "Quit anyway": "Salir de todos modos",
        "History unavailable": "Historial no disponible",
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
        "Empty file — nothing to show yet.": "Archivo vacío — todavía no hay nada que mostrar.",
        "This file doesn't exist on disk yet.": "Este archivo todavía no existe en disco.",
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
        "Restore is blocked: this file has unsaved edits and history is disabled. Save or discard the edits first.": "Restauración bloqueada: este archivo tiene cambios sin guardar y el historial está desactivado. Guarda o descarta los cambios primero.",
        "History is disabled for this file. Restoring replaces the current disk content without a history backup.": "El historial está desactivado para este archivo. Restaurar reemplaza el contenido actual sin una copia en el historial.",
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
