# AgentsConfig

App nativa macOS (SwiftUI) para inspeccionar, editar y auditar las configuraciones
globales de agentes de IA (Claude Code, Codex, Antigravity/Gemini, OpenCode).

## Build & run

```bash
xcodegen generate            # tras añadir/quitar archivos en Sources/
xcodebuild -project AgentsConfig.xcodeproj -scheme AgentsConfig \
  -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/AgentsConfig-*/Build/Products/Debug/AgentsConfig.app
```

Para correr la app contra un home alternativo (demos, screenshots, tests)
sin tocar tus configs reales:

```bash
AGENTSCONFIG_HOME=/tmp/demo-home \
  .../Build/Products/Debug/AgentsConfig.app/Contents/MacOS/AgentsConfig
```

## Arquitectura

- `Sources/Services/AgentRegistry.swift` — catálogo declarativo de agentes
  (paths de detección + fuentes de config). Añadir un agente = añadir una entrada.
- `Sources/Services/ConfigStore.swift` — `@Observable` store: documentos,
  buffers de edición, cambios externos, historiales, guardado atómico.
- `Sources/Services/FileWatcher.swift` — DispatchSource vnode por archivo/dir,
  debounce 350ms, re-attach tras rename (atomic saves).
- `Sources/Services/Parsers.swift` — JSON/JSONC via JSONSerialization,
  TOML via TOMLKit (`TOMLTable.convert(to: .json)` → árbol Foundation).
- `Sources/Services/DiffEngine.swift` — diff semántico por key-path;
  fallback a diff de líneas (`CollectionDifference`).
- `Sources/Services/SnapshotStore.swift` — historial en
  `~/Library/Application Support/AgentsConfig/History/` (index.json + contenido).
- `Sources/Services/Linter.swift` — issues (hooks huérfanos, parse errors) y
  bloques gestionados por terceros (orca-managed, hooks.state, etc.).
- `Sources/Views/` — NavigationSplitView de 3 columnas: Sidebar (agentes +
  paneles fijos Actividad/MCP) → lista (archivos | feed | matriz MCP) →
  Editor (Estructurado | Fuente | Historial) + banners de cambio.
- `Sources/Services/Notifier.swift` — notificaciones macOS de cambios
  externos con app en background; click → selecciona el archivo.
- `Sources/Services/Secrets.swift` — detección/enmascaramiento de
  apiKeys/tokens en vistas estructurada y fuente read-only.
- `Sources/Services/AppSettings.swift` — preferencias (UserDefaults) usadas
  por watcher/snapshots/notifier; editables en la escena Settings (⌘,).

## Convenciones

- Toda resolución de `~` y de Application Support pasa por
  `AppPaths` (Models.swift); `AGENTSCONFIG_HOME` los redirige.
- `volatile: true` en un `ConfigSource` = se vigila en vivo pero sin historial
  ni badges (para `~/.claude.json` y otros archivos de estado ruidosos).
- Escritura estructurada solo para JSON/JSONC; TOML se edita en pestaña Fuente.
- Guardado atómico preservando permisos POSIX originales.
- `selfWriteHashes` distingue escrituras propias de cambios externos.
