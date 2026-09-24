# AgentsConfig

App nativa macOS (SwiftUI) para inspeccionar, editar y auditar las configuraciones
globales de agentes de IA (Claude Code, Codex, Antigravity/Gemini, OpenCode).

## Build & run

```bash
xcodegen generate            # tras añadir/quitar archivos en Sources/ o Tests/
xcodebuild -project AgentsConfig.xcodeproj -scheme AgentsConfig \
  -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/AgentsConfig-*/Build/Products/Debug/AgentsConfig.app
```

## Tests

```bash
xcodegen generate
xcodebuild -project AgentsConfig.xcodeproj -scheme AgentsConfig \
  -configuration Debug -destination 'platform=macOS' test
```

El target `AgentsConfigTests` compila `Sources/` (sin el `@main`) dentro del
bundle de tests: la app nunca arranca, no escanea el home real ni pide
notificaciones. Cada test usa `TestEnvironment` (home temporal canonizado +
suite UserDefaults exclusiva + fixtures ficticios de Claude/Codex/Gemini/
OpenCode). Todas las suites cuelgan de `AgentsConfigTestSuite.serialized`: serializar
hermanas por separado no impide solapamientos durante `await`.

Para correr la app contra un home alternativo (demos, screenshots) sin tocar
tus configs reales:

```bash
AGENTSCONFIG_HOME=/tmp/demo-home \
  .../Build/Products/Debug/AgentsConfig.app/Contents/MacOS/AgentsConfig
```

Límite: `AGENTSCONFIG_HOME` solo redirige rutas. Para UI aislada, usar
`scripts/run-demo.py --app /ruta/AgentsConfigUITestHost.app --wait`: añade una suite exclusiva
`AGENTSCONFIG_DEFAULTS_SUITE` y desactiva Notifier. No ejecutar fixtures MCP.
`scripts/verify-history-processes.py` verifica storage real entre 4 procesos.

## Arquitectura

- `Sources/Services/AgentRegistry.swift` — catálogo declarativo de agentes
  (paths de detección + fuentes de config). Añadir un agente = añadir una entrada.
  `AgentDefinition.localSources` declara las fuentes relativas a la raíz de un
  proyecto (`.claude/settings.json`, `.mcp.json`, `AGENTS.md`, etc.);
  `detectLocal(projectRoot:)` las resuelve en agentes sintéticos
  (`id: "<agentID>::<projectRoot>"`) reutilizando `resolveFiles` sin tocarlo.
  También recorre los submódulos git del proyecto (`.gitmodules`, vía
  `submodulePaths`/`directSubmodulePaths`, acotado a 4 niveles/200 entradas
  como `skillTree`): cada submódulo con config propia se resuelve igual,
  con `absRoot = proyecto/submódulo` — el id ya sale único por ruta absoluta,
  sin lógica especial. `Agent.submodulePath` (relativo al proyecto) es lo
  único nuevo que distingue a estos agentes en el sidebar.
- `Sources/Services/ConfigStore.swift` — `@Observable` store: documentos,
  buffers de edición, cambios externos, historiales, índice MCP, guardado
  atómico con control de conflictos (base de edición explícita + verificación
  del estado real de disco + respaldo previo al reemplazo).
  `projectRoots`/`addProject`/`removeProject`/`pickAndAddProject` gestionan
  proyectos locales registrados (persistidos como `[String]` en
  `UserDefaults["projectRoots"]`, sin normalizar la ruta); `refresh()` los
  añade a `agents`/`definitions` junto a los globales. Sus servidores MCP
  aparecen en el comparador cross-agent en modo solo lectura: no son
  destino válido de copiar/añadir (`mcpDestinationPaths` no se hereda a
  las rutas locales). `skillExpansion` guarda, solo en sesión, qué grupos
  de skills (origen y dueño) están abiertos; `setSkillExpanded` reasigna el
  struct para que `@Observable` publique el cambio.
- `Sources/Models/SkillOrigin.swift` — clasificación pura de skills por
  origen (personal/proyecto/plugins/sistema) y dueño (carpeta o paquete),
  a partir de ruta + `readOnly` + raíz de proyecto opcional. La lista de
  archivos y Configuración → Skills usan la misma regla; los tests no
  necesitan home, watchers ni UI. Plugins ganan sobre proyecto; un origen
  con un solo dueño se aplana en la vista. Las filas se ordenan por nombre
  de carpeta (`localizedStandardCompare`).
- `Sources/Services/FileWatcher.swift` — DispatchSource vnode por archivo/dir,
  debounce configurable, reconexión con backoff (150 ms → 15 s) tras
  rename/delete o fichero ausente; `onAttachedCount` reporta watchers reales.
  Solo vigila **archivos** (y directorios fuente aún inexistentes). Presupuesto
  de fds (`maxSources`, ¾ del `RLIMIT_NOFILE` blando que la app sube a 10 240
  al arrancar), en el orden dado; agotar fds aborta `NSApplication.init`.
- `Sources/Services/TreeWatcher.swift` — un único stream FSEvents para los
  árboles (carpetas de proyecto, skills/plugins) sobre `minimalRoots`.
  `ConfigStore.handleTreeEvents` solo reacciona a cambios estructurales:
  carpeta nueva no excluida (`DiscoveryTree.projectSkipNames`) o marcador de
  config (`projectMarkerNames`: primeros componentes de `localSources` +
  `.gitmodules`) → `scheduleRefresh()`; entradas en un dir fuente → rescan
  del agente. Editar código, builds y `node_modules` no re-escanean.
- Escaneo: `refresh()` = `apply(scan(input))`. `scan` es `nonisolated` (detección,
  proyectos, watch plan, lectura+parse+hash+historial de precargas, MCP
  volátil); `apply` solo muta estado en MainActor. `refresh()` sigue síncrono
  (tests/modelo); UI, arranque (`ConfigStore(backgroundScan: true)`) y
  eventos usan `scheduleRefresh()` (coalesce + descarte por generación;
  `waitForRefresh()` para tests). Añadir proyecto es síncrono a propósito.
  `DiscoveryTree` usa `readdir`/`d_type`, rutas `String` nativas (no
  `NSString`: forzaba copias en cada comparación), orden por bytes y caché
  por pasada (`withCache`). Tiempos: `log stream --info --predicate
  'subsystem == "com.tavodev.agentsconfig"'` o Points of Interest.
- `Sources/Services/Parsers.swift` — JSON/JSONC via JSONSerialization,
  TOML via TOMLKit (`TOMLTable.convert(to: .json)` → árbol Foundation).
- `Sources/Services/DiffEngine.swift` — diff semántico por key-path;
  fallback a diff de líneas; los valores bajo claves secretas se emiten
  enmascarados en todos los consumidores.
- `Sources/Services/SnapshotStore.swift` — historial en
  `~/Library/Application Support/AgentsConfig/History/<sha256(path)>/`
  (`index.json` formato 2 + `objects/<sha256(content)>` content-addressed,
  lock de índice `.index.lock`, migración perezosa no destructiva de
  directorios legado `a__b`). Dirs `0700`, archivos `0600`.
- `Sources/Services/AtomicWriter.swift` — escritura atómica con preservación
  de permisos POSIX, escritura a través de symlinks, temporales `0600`
  exclusivos limpiados en éxito y en fallo.
- `Sources/Services/Linter.swift` — issues (hooks huérfanos, parse errors) y
  bloques gestionados por terceros (orca-managed, hooks.state, etc.).
- `Sources/Services/DocsCatalog.swift` — doc por archivo (ⓘ junto al nombre)
  y por clave (ⓘ junto a cada fila en "Todas las claves"/tarjetas). Ambas
  búsquedas emparejan por **sufijo relativo** (`pathSuffixDocs`/
  `keyTableSuffixes`), no por ruta absoluta exacta: así una copia local de
  proyecto (`.codex/config.toml`, `.claude/settings.json`, etc.) obtiene la
  misma documentación que la global sin duplicar entradas.
- `Sources/Views/` — navegación nativa por destino: tres columnas para
  archivos/Actividad y dos para Ajustes/MCP. En ventanas menores de 1180 pt
  la navegación de archivos inicia con sidebar oculta y permite recuperarla.
  `WorkspaceStyle.swift` presenta inspectores como panel con espacio suficiente
  o como sheet compacto; nunca reduce el editor para forzar cuatro columnas.
  Las revisiones raíz esperan al `onDismiss` del inspector compacto antes de
  presentarse; no se cancelan ni se sustituyen sus datos pendientes.
  El Sidebar conserva Global/Proyectos y menús nativos de proyecto y
  alcance, persistidos en `AppSettings.defaults`. La identidad del editor se
  obtiene del propietario del archivo, no del filtro del sidebar. Modos en
  fila separada; metadatos completos en inspector; guardado mediante revisión.
  `StructuredView.GenericInspector` excluye las claves cubiertas por tarjetas;
  `NodeRow` muestra ayuda legible y controles con nombres accesibles.
  `McpMatrixView` compara familias de agentes en una tabla amplia y abre
  fuentes concretas en detalle opcional. Historial usa selector de versión
  compacto o lista lateral según el ancho disponible.
  `MarkdownPreview` parsea bloques `PresentationIntent` completos y distingue
  archivos ausentes de archivos vacíos.
  Las skills de la lista de archivos y de Configuración → Skills se agrupan
  por origen y, si hay más de un dueño, por carpeta o paquete; la fila de
  skill no repite el path largo (el dueño ya lo nombra).
- `Sources/Views/SettingsView.swift` — `AppSettingsView`, en archivo propio
  (no en `AgentsConfigApp.swift`) porque el target de tests excluye ese
  archivo por el `@main`; se reusa tal cual desde la escena `Settings`
  nativa (Cmd+,, con ventana de 620 × 620 pt) y como destino de
  sidebar (`ConfigStore.settingsID`, sin frame fijo — se adapta al panel).
- `Sources/Services/Notifier.swift` — notificaciones macOS de cambios
  externos con app en background; click → selecciona el archivo.
  Inyectable (`ConfigStore(notifier:)`).
- `Sources/Services/Secrets.swift` — detección/enmascaramiento de
  apiKeys/tokens: una sola lista de tokens alimenta `isSecretKey`,
  `maskText` (JSON/TOML/shell) y `maskLine` (diffs por líneas).
- `Sources/Services/AppSettings.swift` — preferencias (UserDefaults) usadas
  por watcher/snapshots/notifier; `AppSettings.defaults` es el seam de tests.

## Convenciones

- Debug usa bundle id `com.tavodev.agentsconfig.debug`; Release (instalada con
  Developer ID) usa `com.tavodev.agentsconfig`. Así no comparten permisos TCC
  (Documents) ni UserDefaults: un build ad hoc guarda el permiso por cdhash y
  pisaba el de la app instalada.

- Toda resolución de `~` y de Application Support pasa por
  `AppPaths` (Models.swift); `AGENTSCONFIG_HOME` los redirige.
- `volatile: true` en un `ConfigSource` = se vigila en vivo pero sin historial
  ni badges (para `~/.claude.json` y otros archivos de estado ruidosos).
- `excludeFromHistory: true` = nunca se hace snapshot (ficheros con secretos).
- Escritura estructurada solo para JSON/JSONC. TOML se edita en la pestaña
  Fuente; alta/copia MCP hacia Codex modifica el árbol TOML nativo y conserva
  tipos ajenos a MCP. Normaliza comentarios/formato, con revisión explícita
  de diff antes de modificar el buffer y guardado posterior por el usuario.
- Guardado atómico preservando permisos POSIX originales; symlinks escriben
  a su destino; enlaces colgantes/ciclos se rechazan; nuevos nacen en `0600`.
  La comprobación previa + rename no es CAS: cambios externos posteriores al
  respaldo pueden perderse y no quedan recuperados por dicho respaldo.
- `McpAdapter.swift` comparte esquemas entre alta/copia; destinos explícitos en
  AgentRegistry y contrato en `docs/repair-plan/MCP-SCHEMAS.md`. No se asumen
  equivalencias de auth/timeouts/opciones desconocidas. Review invalidado si
  cambia buffer o disco; arguments son lista, nunca split por espacios.
- Hasta 2 MB: inspección estructurada. Entre 2 y 16 MB: `LargeFileWorker`
  lee/valida/guarda fuera de MainActor; `LargeSourceEditor` pagina Fuente sin
  cortar caracteres. Deshacer/Buscar por página; límite de pegado visible.
  Fuera del índice MCP, diff detallado omitido con aviso. Más de 16 MB se rechaza.
  Diff de líneas máximo
  2,000 por lado; salida semántica máxima 500. Skills hasta 8 niveles/1,000
  directorios, sin symlinks de directorio ni `.git`.
- Diffs siempre redactados; vistas reactivas a máscara, reveal reinicia al
  cambiar de archivo. Source editable advierte que contiene valores reales.
- Un archivo declarado que no existe en disco o está vacío nunca se muestra
  como una tarjeta en blanco sin explicación: `StructuredView`/`MarkdownPreview`
  distinguen "no existe todavía" de "vacío" y muestran una etiqueta acorde.
- `historyEnabled` desactiva nuevos snapshots/respaldos sin purgar existentes.
  HistoryView permite exclusión por archivo y eliminación confirmada de versiones;
  ID set revisado bajo lock, publicación antes de GC, errores de limpieza reintentables.
- Guardados UI usan `requestSave` + review/confirmación (incluye Retry/Keep mine).
  `save(path:)` es primitiva para tests del modelo, no para controles UI.
  Restauración también muestra diff y fija el contenido/estado revisado.
  Guardado conserva al menos 2 versiones durante la operación; restore con
  draft conserva 3, después aplica retención configurada.
- `selfWriteHashes` distingue escrituras propias de cambios externos.
- Restaurar/revertir pasa siempre por `pendingRestore` + confirmación única
  en `ContentView`; un buffer sucio se archiva en el historial antes de
  descartarse; si falla el archivo se aborta, y si el historial está
  deshabilitado/excluido se bloquea la restauración de buffers dirty.
- Errores de guardado en `saveErrors[path]` (visibles con Retry/Dismiss en
  el footer, independientes del flag dirty); errores de historial en
  `historyErrors[path]` (nunca se sobrescribe un índice corrupto).
- Al salir con buffers dirty, `AppDelegate.applicationShouldTerminate`
  pide confirmación: los edits sin guardar no persisten en disco.

## Reparaciones en curso

- **Tracking vigente: GitHub Issues** de `tavodev/agentsconfig` (cuenta `gh` `tavodev`).
  Pendientes, decisiones de publicación y limitaciones conocidas (`known-limitation`)
  se abren y cierran ahí; los docs de `repair-plan/` quedan como registro histórico
  y de evidencia.
- Plan de reparación: `docs/repair-plan/FOLLOWUP.md`. Mejoras nuevas autorizadas:
  `docs/repair-plan/IMPROVEMENTS.md`.
- `AgentsConfigUI` compila `UITests/` con host propio `AgentsConfigUITestHost`
  (`com.tavodev.agentsconfig.ui-fixture`), separado de la app real y del esquema hostless.
  El host exige home+defaults aislados para arrancar. Compilar con
  build-for-testing; ejecutar solo con sesión gráfica desbloqueada. Nunca afirmar
  ejecución UI por el hecho de que compile.
- Antes de retomar reparaciones, leer su punto de reanudación y comprobar el
  estado/diff de Git: la primera implementación contiene cambios sin commit.
- Actualizar tablero, evidencia y próxima acción después de cada reproducción,
  implementación y verificación relevante; no esperar al final de la sesión.
- El registro de primera ronda en `docs/repair-plan/PLAN.md` no certifica cierre:
  la auditoría reabrió garantías de historial, restauración, máscara y escritura.
