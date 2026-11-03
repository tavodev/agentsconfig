# Integración con Orca

[Orca](https://onorca.dev) (stablyai) lanza Claude Code y Codex con una carpeta
de configuración propia por cuenta. AgentsConfig lista esas carpetas como agentes
separados, en solo lectura donde Orca las regenera, y explica de dónde sale cada
archivo, cada clave y cada hook. Este documento es el contrato de esa integración.

- **Versión verificada:** Orca 1.4.246, código fuente `stablyai/orca` en el commit
  `747acba`. Otra versión de Orca puede cambiar rutas o reglas sin aviso.
- **Código de AgentsConfig:** `Sources/Services/OrcaIntegration.swift` (detección y
  agentes), `OrcaMirror.swift` (relación, origen y estado de sincronización),
  `OrcaDetection.swift` (carpeta de datos, cuenta seleccionada, hooks gestionados),
  `OrcaLayerNotes.swift` (notas por clave), `Sources/Models/HookMap.swift` (mapa de hooks).

## Carpeta de datos de Orca

Orca guarda todo bajo su carpeta de datos (`getOrcaUserDataPath`):

1. `ORCA_USER_DATA_PATH`, si está definida y no vacía;
2. si no, `~/Library/Application Support/orca` en macOS
   (`%APPDATA%\orca` en Windows, `$XDG_CONFIG_HOME/orca` en Linux).

Los builds de desarrollo de Orca usan `orca-dev` u `ORCA_DEV_USER_DATA_PATH`, y
el CLI fija la carpeta con `--user-data-dir` y `ORCA_USER_DATA_PATH`.

AgentsConfig la resuelve así (`OrcaIntegration.dataRootResolution`):

1. la carpeta elegida en **Ajustes → Carpetas de configuración → Carpeta de datos
   de Orca** (`UserDefaults["orcaDataPath"]`; «Usar predeterminada» la borra);
2. `ORCA_USER_DATA_PATH` del entorno de la app, **solo fuera de ejecuciones
   aisladas**. Con `AppPaths.overrideHome` o `AGENTSCONFIG_HOME` siempre se usa la
   ruta bajo el home aislado. Una app abierta desde el Finder no hereda las
   variables de la terminal, así que lo habitual es elegir la carpeta en Ajustes;
3. `~/Library/Application Support/orca`.

`~` se expande y una ruta relativa se resuelve contra el home (Orca la resolvería
contra su directorio de trabajo, que en una app gráfica no significa nada).

## Rutas

| Ruta bajo la carpeta de datos | Qué es | Agente en AgentsConfig |
|---|---|---|
| `claude-profiles/<cuenta>/home` | `CLAUDE_CONFIG_DIR` de una cuenta de Claude Code | `claude-code:orca:<cuenta>` |
| `claude-profiles/<cuenta>/profile.json` | marcador de propiedad `{version, accountId, runtime, distro}`, escrito al terminar la preparación | no se lista |
| `claude-profiles/selected-host` | puntero con la ruta del home seleccionado; vacío = «System default» | marca «seleccionada» |
| `codex-accounts/<cuenta>/home` | `CODEX_HOME` de una cuenta de Codex (marcador `.orca-managed-home` con el id) | `codex:orca:<cuenta>` |
| `codex-runtime-home/home` | home compartido de ejecución de Codex | `codex:orca:runtime` |
| `claude-accounts/<cuenta>/…` | carpetas antiguas de credenciales (Orca ya no las borra) | nunca se lee |
| `orca-data.json` / SQLite | almacén de ajustes de Orca, con el registro de cuentas y secretos sellados | nunca se lee |

La cuenta «System default» no tiene carpeta propia: usa `~/.claude` y `~/.codex`
(o la raíz elegida en Ajustes), que siguen siendo los agentes Claude Code y Codex.

## Qué hace Orca con cada archivo

`OrcaIntegration.relation(for:)` clasifica cada archivo de un home de Orca:

- **Espejo (`mirroredCopy`)**: Orca lo sobrescribe desde el origen.
  - Claude `settings.json`: copia de `~/.claude/settings.json` (o de
    `CLAUDE_CONFIG_DIR`) a la que Orca añade sus hooks de estado
    (`agent-hooks/claude-hook.{sh,cmd,ps1}` o el lanzador nativo
    `orca-agent-hook.exe claude`). Orca compara ambos lados sin esos hooks antes de recopiar.
  - Archivos sueltos compartidos de la carpeta de Claude Code (por ejemplo
    `statusline.sh`), excepto estado de ejecución, historial y `settings.json`.
  - Codex `AGENTS.md` cuando Orca tuvo que copiarlo (si es enlace se lista en Codex)
    y `rules/_orca-global-*.rules` (copias de `~/.codex/rules/*.rules`).
- **Stub (`importStub`)**: el `CLAUDE.md` del perfil se reescribe como
  `@~/.claude/CLAUDE.md` cuando el origen es `~/.claude`; con otra raíz es una copia.
- **Estado fusionado (`mergedState`)**:
  - Claude `.claude.json`: Orca fusiona las claves compartidas del estado global
    (`~/.claude.json`, o el de `CLAUDE_CONFIG_DIR`); `projects` y `mcpServers` por
    entrada (las entradas solo de la cuenta se conservan) y nunca copia las claves de
    la cuenta (inicio de sesión, identidad, cachés: `isAccountBoundState`).
  - Codex `config.toml`: Orca refleja `~/.codex/config.toml` y conserva lo propio
    del home: confianza de `projects` y `hooks`, servidores MCP que solo están ahí y
    la protección del socket del daemon. Reescribe rutas relativas.
- **Propio de la cuenta (`accountOwned`)**: todo lo demás (historial, sesiones,
  `hooks.json` de Codex, reglas propias…). No tiene origen.
- **Enlaces**: skills, plugins, `AGENTS.md` y otras carpetas que Orca enlaza a
  `~/.claude`/`~/.codex` no se repiten en el agente Orca; se ven en Claude Code o Codex.

### Promoción inversa en Codex

Antes de reflejar `~/.codex/config.toml`, Orca copia de vuelta al origen los
cambios hechos en el home (por ejemplo desde `/model` en una sesión) de estas claves
(`config-toml-promoted-setting-values.ts`): `model`, `model_reasoning_effort`,
`approval_policy`, `sandbox_mode`, `tui.status_line`, `tui.status_line_use_colors`,
`tui.terminal_title`, `tui.theme` y `features.daemon_auto_start`. Decide qué lado
cambió con una línea base que guarda junto al home; AgentsConfig no la lee, así que
una diferencia en esas claves queda «no determinada».

### Cuándo sincroniza Orca

- **Claude Code**: al preparar cada lanzamiento de una cuenta
  (`ClaudeProfileRouter.prepareLaunch` → `provisionClaudeProfile`; las
  actualizaciones posteriores pueden agotar el tiempo sin bloquear el lanzamiento) y
  en segundo plano cuando publica la selección de cuenta (`ClaudeProfileRouter.publish`).
- **Codex**: al arrancar el servicio de cuentas, al añadir o seleccionar una cuenta,
  al instalar o mantener sus hooks y antes de cada lanzamiento de Codex
  (`syncSystemConfigIntoManagedCodexHome`).

Entre una sincronización y la siguiente la copia puede ir por detrás del origen: el
inspector lo muestra como «pendiente».

## Qué muestra AgentsConfig

- **Agentes**: un «Claude Code · Orca <cuenta>» por perfil y un «Codex · Orca
  <cuenta>» por cuenta, más el home de ejecución. Las credenciales de Codex
  (`auth.json`) no se listan.
- **Solo lectura y origen**: los archivos espejo, stub y fusionados son de solo
  lectura con una nota; el inspector indica si están sincronizados, pendientes,
  difieren o no se puede determinar, y «Abrir origen» abre el original.
- **Notas por clave** (`OrcaIntegration.layerNotes`): en `settings.json`,
  `.claude.json` y `config.toml` cada clave explica que la capa de usuario efectiva
  de esa cuenta es el origen más los hooks de Orca: copiada, distinta (con el valor
  del origen), ausente en el origen, propia de la cuenta o del home, o promovida al
  origen. No se inventa precedencia de proyecto: Orca no toca las capas de proyecto,
  que se analizan desde los homes normales. El resolver de `~/.claude`/`~/.codex`
  no cambia.
- **Mapa de hooks**: cada hook de un home de Orca lleva su cuenta (y si es la
  seleccionada) y su papel: «Gestionado por Orca» (hook de estado, también en los
  homes normales que usa «System default»), «Heredado de <origen>» (el mismo hook que
  el original, no uno nuevo), «No está en <origen>» (Orca lo quitará en su próximo
  lanzamiento) o «Propio de la cuenta».
- **Cuenta seleccionada**: solo para Claude Code, desde `selected-host`.

## Qué no hace

- No escribe en ningún archivo de Orca ni ejecuta Orca, sus hooks ni su CLI.
- No lee credenciales (`auth.json`, `.credentials.json`, `claude-accounts/*/auth`,
  Llavero) ni el almacén de ajustes de Orca.
- **No marca perfiles huérfanos.** El registro de cuentas (`claudeManagedAccounts`)
  vive en el almacén de ajustes de Orca, junto a secretos sellados; `profile.json`
  solo prueba que la preparación terminó, no que la cuenta siga registrada. Orca
  borra la carpeta al eliminar una cuenta, pero conserva a propósito homes retirados
  de Codex para su historial. Sin leer ese almacén no es determinable.
- **No indica la cuenta de Codex seleccionada.** Está en
  `activeCodexManagedAccountId` del mismo almacén; el home de ejecución solo contiene
  una copia de las credenciales de esa cuenta. No hay un indicador no secreto y fiable.
- No infiere qué home usa una terminal concreta ni las variables de entorno de otras
  terminales.
- No modela WSL ni los homes remotos de Orca.

## Límites

- Las comparaciones son estáticas sobre archivos; Orca puede tener una
  sincronización en curso o fallida que solo él conoce.
- La promoción inversa y la reescritura de rutas de Codex dependen de la línea base
  de Orca, que no se lee.
- Los cambios de formato o reglas de futuras versiones de Orca pueden dejar este
  contrato desactualizado; se verifica contra el commit indicado.

## Fuentes (stablyai/orca @ 747acba)

- `src/main/codex/codex-home-paths.ts` — `getOrcaUserDataPath`, recursos enlazados.
- `src/cli/runtime/launch-user-data-path.ts`, `src/main/startup/configure-process.ts` — carpeta de datos del CLI y de desarrollo.
- `src/main/claude-accounts/claude-profile-paths.ts` — `describeClaudeProfile`, `profile.json`.
- `src/main/claude-accounts/claude-profile-homes.ts` — listado de perfiles.
- `src/main/claude-accounts/claude-profile-router.ts` — `selected-host`, preparación de lanzamientos.
- `src/main/claude-accounts/claude-account-folder.ts` — borrado de cuentas; `claude-accounts/` antiguas intactas.
- `src/main/claude-accounts/claude-account-registration.ts`, `claude-account-selection.ts` — registro en los ajustes de Orca.
- `src/main/claude-accounts/claude-profile-provisioning.ts`, `claude-profile-sharing.ts`, `claude-observed-config-dirs.ts` — copia del perfil.
- `src/main/claude/hook-settings.ts`, `src/main/agent-hooks/installer-utils.ts` — hooks gestionados (`createManagedCommandMatcher`).
- `src/main/claude/claude-config-dir-pin.ts` — `defaultClaudeConfigDir`: `CLAUDE_CONFIG_DIR` o `~/.claude`.
- `src/main/codex/codex-config-mirror.ts`, `src/main/codex-accounts/codex-config-mirror.ts` — reflejo de `config.toml`.
- `src/main/codex/config-toml-promoted-setting-values.ts` — claves promovidas.
- `src/main/codex/codex-managed-home-rules.ts` — reglas `_orca-global-*`.
- `src/main/codex/codex-account-home-hook.ts`, `codex-hook-identity.ts` — hooks de Codex por cuenta.
- `src/main/codex/codex-account-home-discovery.ts` — homes de Codex retirados.
- `src/main/codex-accounts/runtime-selection.ts`, `runtime-home-service-launch.ts`, `service.ts` — selección y momentos de sincronización.
- `src/shared/managed-account-types.ts` — tipos de cuenta.

## Documentación oficial

- [Claude Code en Orca](https://onorca.dev/docs/agents/claude-code)
- [Codex en Orca](https://onorca.dev/docs/agents/codex)
- [Cambio de cuenta de Codex en caliente](https://onorca.dev/docs/agents/codex-hot-swap)
- [Hooks y memoria](https://onorca.dev/docs/agents/hooks-memory)
- [Ajustes](https://onorca.dev/docs/settings)
