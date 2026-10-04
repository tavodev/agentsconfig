# Verification

Verification runs locally; GitHub Actions is disabled. Results below are dated
evidence, not an automated claim about every later commit.

## Recorded results

The full runtime checks ran on 2026-10-04 from a clean source copy of `9c34cf6`,
with macOS 26.6.2, Xcode 26.1.1 (17B100), XcodeGen 2.46.0, TOMLKit 0.6.0 and
Yams 6.2.2. Publication-guard checks used the implementation in `2efad7a`.

| Check | Result |
| --- | --- |
| Hostless Swift tests | 254 tests in 26 suites passed |
| Isolated graphical suite | 29 tests executed and passed, zero failures |
| Release build | Passed; version 0.1.0 / build 2 |
| Multiprocess history | Four writers; 120 writes plus legacy baseline; 121 unique readable versions |
| Publication guard | 10 regression tests passed |
| Generated project | XcodeGen regeneration produced no project or Info.plist drift |
| Dependency notices | Bundled notices matched the repository copy; upstream license texts included |

All runtime fixtures used temporary homes and exclusive preference suites.
Notifications were disabled; MCP servers and hooks were never executed. The
Release verification build was locally signed, not a notarized distribution.

An additional live check verified per-file rule muting: the literal-secret
warning disappears while base diagnostics remain, and Show again restores it.
The README screenshot was captured from the isolated host with fictitious
configurations and visually reviewed before inclusion.

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
