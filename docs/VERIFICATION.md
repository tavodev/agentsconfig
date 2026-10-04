# Verification

Verification runs locally; GitHub Actions is disabled. Results below are dated
evidence, not an automated claim about every later commit.

## Recorded results

The distribution checks ran on 2026-10-04 from a clean source copy of `9536b54`,
with macOS 26.6.2, Xcode 26.1.1 (17B100), XcodeGen 2.46.0, TOMLKit 0.6.0 and
Yams 6.2.2. Later documentation updates do not change the compiled inputs.

| Check | Result |
| --- | --- |
| Hostless Swift tests | 254 tests in 26 suites passed |
| Isolated graphical suite | 29 tests executed and passed, zero failures |
| Universal Release archive/export | Passed; version 0.1.0 / build 3; arm64 and x86_64 |
| Developer ID signing | Valid signature, hardened runtime and secure timestamp; no development debugging entitlement |
| Apple notarization | App and DMG accepted separately, no reported issues; both tickets stapled and validated |
| Gatekeeper | App and DMG assessed as Notarized Developer ID |
| Installation smoke check | Read-only DMG mount, app copied to an isolated installation folder, valid ticket/signature and successful launch with fictitious configurations |
| Binary path review | Executable contains no personal home paths or temporary build-directory prefixes |
| Multiprocess history | Four writers; 120 writes plus legacy baseline; 121 unique readable versions |
| Publication guard | 10 regression tests passed |
| Generated project | XcodeGen regeneration produced no project or Info.plist drift |
| Dependency notices | Bundled notices matched the repository copy; upstream license texts included |

All runtime fixtures used temporary homes and exclusive preference suites.
Notifications were disabled; MCP servers and hooks were never executed. The
distributed app is signed with Developer ID and notarized. The smoke check
loaded the expected file inventory without saving configuration. Further UI
interaction in that installed copy was not exercised because its window could
not receive focus; the dedicated isolated graphical suite ran separately.

The installation check ran on the current Apple Silicon Mac with isolated app
data. A separate clean macOS user or machine and runtime execution on Intel have
not been tested. This first release is experimental; the clean-machine check
remains tracked in [#6](https://github.com/tavodev/agentsconfig/issues/6).

An earlier live check verified per-file rule muting: the literal-secret
warning disappears while base diagnostics remain, and Show again restores it.
The README screenshot was captured from the isolated host with fictitious
configurations and visually reviewed before inclusion.
Its color-profile description and device manufacturer/model identifiers were
anonymized. The captured pixels, colorimetric tables and rendered sRGB values
remain identical.

Publication review and decisions are tracked in
[#3](https://github.com/tavodev/agentsconfig/issues/3) and
[#5](https://github.com/tavodev/agentsconfig/issues/5). Raw logs, temporary paths
and session inventories are not part of the documentation shipped to readers.

## Reproducing checks

Use the build, hostless and UI commands in [README.md](../README.md), keeping the
committed `Package.resolved`. UI execution requires an unlocked graphical session
and the dedicated fixture host; compiling the suite does not count as execution.

Run storage and publication checks separately:

```bash
python3 scripts/verify-history-processes.py
python3 scripts/test-audit-publication.py
python3 scripts/audit-publication.py
git diff --check
```

The history probe compiles the production storage code and uses four independent
processes with a fictitious legacy baseline. Publication-guard tests use disposable
Git repositories with synthetic tokens and disabled Git hooks/signing.

The publication scan checks working files, reachable historical blobs, commit/tag
metadata and any review exports passed through `--extra-file`. It reports
locations, never matched values. It is heuristic; review images, private paths
and asset provenance separately. Open functional limitations are tracked in
[GitHub Issues](https://github.com/tavodev/agentsconfig/issues), with user-facing
boundaries documented in [README.md](../README.md).
