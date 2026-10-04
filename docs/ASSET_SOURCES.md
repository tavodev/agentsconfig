# Icon sources

Product marks identify the corresponding configuration sources. Assets were
obtained on 2026-09-12 from the following official product surfaces.

| Product | Asset source |
| --- | --- |
| Claude Code | `https://claude.ai/favicon.svg` |
| Codex | `ChatGPT.app/Contents/Resources/icon-codex-dark-color.png` |
| Gemini / Antigravity | `https://www.gstatic.com/lamda/images/gemini_sparkle_aurora_33f86dc0c0257da337c63.svg` |
| OpenCode | `https://opencode.ai/brand` |

Product marks remain property of their owners and are retained solely for
nominative identification, subject to their official brand guidelines. This
project does not claim or grant broader trademark rights.

## Application icon

`Resources/icon.png` is the owner-selected source artwork for the configurable
AI chip icon. Regenerate the standalone ICNS and the ten macOS asset-catalog
representations (16–1024 pixels, with alpha) using:

```bash
swift scripts/make_icon.swift
```

Xcode compiles `Resources/Assets.xcassets/AppIcon.appiconset`. The raw source PNG
and standalone ICNS are excluded from resource copying to avoid duplicate output.
The app declares the catalog icon and assigns it to `NSApplication` at launch.
