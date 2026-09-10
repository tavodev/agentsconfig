# AgentsConfig

A native macOS app (SwiftUI) to inspect, edit and audit the global
configuration of your AI coding agents — Claude Code, Codex,
Antigravity/Gemini and OpenCode — from one place.

![AgentsConfig](docs/screenshot.png)

## What it does

- **Detects installed agents** and their global config files via a
  declarative registry — adding support for a new agent is one entry in
  `AgentRegistry.swift`.
- **Watches files live** (`DispatchSource` vnode watchers, debounced,
  resilient to atomic saves) and flags external changes with banners.
- **Semantic diffs** on every change: key-path level for
  JSON/JSONC/TOML, line diff as fallback.
- **Versioned history** per file, stored locally, with revert and
  arbitrary version-to-version comparison.
- **Structured editing** for JSON/JSONC and TOML (MCP servers,
  permissions, env vars, plugins…) on top of a syntax-highlighted
  source editor with find bar.
- **Cross-agent MCP comparator**: a matrix of every configured MCP
  server × agent, with copy-to-agent to sync specs across tools.
- **Secrets masking**: API keys and tokens render masked in the
  structured and read-only views.
- **In-app docs**: explains what each file and each known setting does,
  with links to the official documentation.
- Activity feed, macOS notifications on external changes, menu bar
  extra, inspector panel, light/dark mode, English/Spanish UI
  switchable live.

## Privacy

Everything happens locally. The app reads and writes your agent config
files (`~/.claude/`, `~/.codex/`, etc.) and keeps snapshots under
`~/Library/Application Support/AgentsConfig/History/`. No telemetry,
no network calls.

## Requirements

- macOS 15 or later
- Xcode with Swift 6 toolchain
- [XcodeGen](https://github.com/yonsm/XcodeGen) (`brew install xcodegen`)

## Build & run

```bash
xcodegen generate            # regenerate the .xcodeproj after adding/removing files in Sources/
xcodebuild -project AgentsConfig.xcodeproj -scheme AgentsConfig \
  -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/AgentsConfig-*/Build/Products/Debug/AgentsConfig.app
```

The app is built unsigned (`CODE_SIGN_IDENTITY = "-"`), intended to run
on the machine that compiled it.

## Development

See [AGENTS.md](AGENTS.md) for the architecture overview and project
conventions.

This project is developed with the assistance of AI coding agents —
fitting, since it is a tool for auditing their configuration.
Contributions (human or AI-assisted) are welcome; whoever opens a pull
request is responsible for reviewing and understanding the code they
submit.

## Third-party licenses

Bundled dependencies and their licenses are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

[MIT](LICENSE) © 2026 tavodev
