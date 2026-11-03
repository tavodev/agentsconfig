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

## Release 0.3.0

On 2026-11-03 the 0.3.0 / build 5 candidate (`9b23f42`) was verified on macOS
26.6.2 and Xcode 26.1.1 (17B100) with XcodeGen 2.46.0:

| Check | Result |
| --- | --- |
| Hostless Swift tests | 410 tests in 41 suites passed |
| Isolated graphical suite | 34 tests executed and passed, zero failures; none covers the Orca views or the sidebar organization yet |
| Publication guard | No credential-pattern findings; its tests and the legacy-export tests passed |
| Multiprocess history | Plaintext and encrypted: four writers, 121 unique readable versions each |
| Universal Release archive/export | arm64 and x86_64; Developer ID, secure timestamp and hardened runtime on the app and the five Sparkle components; no `get-task-allow`; no personal or build paths in the executable |
| Apple notarization | App and DMG accepted separately, no reported issues; both tickets stapled; Gatekeeper: Notarized Developer ID |
| Sparkle feed | `sign_update --verify` passed for the DMG and the feed; `releases/latest/download/appcast.xml` serves the 0.3.0 feed |

In one earlier full run of the hostless suite the history-encryption
concurrency test failed intermittently ([#33](https://github.com/tavodev/agentsconfig/issues/33));
the candidate runs passed. The Orca integration was checked against fictitious
Orca layouts only. Updating a real 0.2.0 installation through Sparkle and a
clean-machine install remain open in [#6](https://github.com/tavodev/agentsconfig/issues/6).

## Unreleased changes after 0.1.0

On 2026-10-16, after the work for issues #11 and #19–#26, the hostless suite ran
from the working tree with macOS 26.6.2 and Xcode 26.1.1: **273 tests in 31
suites passed**. The Debug app and the `AgentsConfigUI` test bundle compiled; the
graphical suite was **not executed** for these changes. The publication guard
reported no credential-pattern findings. MCP servers, hooks and login shells were
never executed by the tests: the login-shell read is opt-in and disabled in
isolated runs.

On 2026-10-21, after the work for issues #8, #9, #10, #16 and #27, the hostless
suite ran from the working tree with macOS 26.6.2 and Xcode 26.1.1: **300 tests in
31 suites passed**. The `AgentsConfigUI` test bundle compiled; the graphical suite
was **not executed** for these changes. MCP servers, hooks and login shells were
never executed by the tests, and the history purge was exercised only in
temporary homes.

On 2026-10-21, after adding Sparkle 2.10.0 for issue #7, the hostless suite
passed with **307 tests in 32 suites**; the Debug app and the `AgentsConfigUI`
bundle compiled (UI suite **not executed**). A local ad hoc Release archive
embedded `Sparkle.framework` with its helpers for arm64 and x86_64; Developer ID
signing of those helpers and a real update from an appcast are **not yet
verified** (see `RELEASING.md`). The publication guard reported no
credential-pattern findings.

On 2026-10-28, the compiled inputs committed as `8b7274e` (issues #28 and #29)
were verified on macOS 26.6.2 (25G83), Xcode 26.1.1 (17B100) and XcodeGen
2.46.0, with the committed TOMLKit 0.6.0, Yams 6.2.2 and Sparkle 2.10.0 pins:

| Check | Result |
| --- | --- |
| Hostless Swift tests, arm64 | 312 tests in 32 suites passed |
| Hostless Swift tests, x86_64 under Rosetta | 312 tests in 32 suites passed; no Intel hardware execution |
| Isolated graphical suite | 29 tests executed and passed, zero failures; dedicated fixture host |
| Universal Release archive and Developer ID export | Passed; local verification export, unchanged version 0.1.0 / build 3 |
| Sparkle embedded code | App, framework, Autoupdate, Updater.app, Installer.xpc and Downloader.xpc all have valid Developer ID signatures, secure timestamps and hardened runtime; no debugging entitlement; all contain arm64 and x86_64 |
| Signature verification | Individual strict checks and app deep/strict verification passed |
| Updater configuration | HTTPS feed, public key, signed-feed requirement and verification before extraction present |
| Dependency notices | Bundled notices identical to the repository copy |
| Binary path review | No personal home paths or examined temporary/build-directory prefixes in the main executable |
| Multiprocess history | Four writers; 120 writes plus legacy baseline; 121 unique readable versions |
| Publication guard tests | 10 tests passed |
| Publication scan | No credential-pattern findings in the working tree and reachable history |
| Generated project | XcodeGen regeneration produced no project or Info.plist drift |

All runtime checks used fictitious homes and exclusive preference suites; MCP
servers, hooks and login shells were not executed. The x86_64 hostless run used
the same test command with destination `platform=macOS,arch=x86_64`; it verifies
Rosetta execution on Apple Silicon, not an Intel Mac. Archive/export and embedded
signature checks follow [RELEASING.md](RELEASING.md).

The verification export was not submitted for notarization or published. A real
update from an appcast and installation/first launch in a clean macOS user or
machine remain unverified. The demo isolation environment deliberately disables
the updater, and the distributed 0.1.0 has no updater; the update check needs a
separate test installation with two Sparkle-enabled versions. These distribution
checks remain tracked in [#6](https://github.com/tavodev/agentsconfig/issues/6).

Later on 2026-10-28, the compiled inputs committed as `663611b` (including
`773dda1`) were verified in the same environment for issues #12, #14, #16, #30
and #31, with additional synthetic boundary coverage for #15:

| Check | Result |
| --- | --- |
| Hostless Swift tests, arm64 | 357 tests in 36 suites passed |
| Hostless Swift tests, x86_64 under Rosetta | 357 tests in 36 suites passed |
| Graphical suite | All 31 scenarios compiled with the dedicated fixture host; two new scenarios were attempted and failed during fixture activation because the macOS desktop was locked |
| Legacy recovery export | 25 Python tests passed, including execution of the original Swift history reader against the exported fixtures |
| Multiprocess history | Plaintext and encrypted runs each used four independent writers, preserving 121 unique readable versions per run, including the legacy baseline |
| Encryption coverage | Full-tree conversion, metadata/content authentication, missing keys, interrupted encryption/decryption, reserved temporary recovery, per-file integrity, permissions, Unicode, retention, purge and reviewed save/restore flows passed with injected keys |
| TOML coverage | Native scalar type preservation and exact surrounding text, quoted/dotted keys, multiline values, Int64 extremes, unsupported types and invalid edits |
| Resource boundaries | Synthetic UTF-8 2/16 MB boundaries, discovery depth/directories/entries/files and redacted diff limits; limits unchanged |
| Universal archive/export | Developer ID, secure timestamp and hardened runtime valid for app, Sparkle and all four helpers; all six contain arm64 and x86_64; unchanged local verification version 0.1.0 / build 3 |
| Bundle checks | Licenses matched the repository; main executable contained none of the examined personal/build-directory prefixes; updater hardening configuration present |
| Publication checks | 10 guard tests passed; no credential-pattern findings in working files or reachable history |
| Generated project and whitespace | XcodeGen regeneration stable; `git diff --check` passed |

An initial integrated run failed two performance assertions because redundant
directory permission updates invalidated the encryption preflight cache on every
snapshot. Skipping already-private directory updates fixed that behavior; the
final 357-test runs passed on both architectures. Encryption and all runtime
storage tests used fictitious homes and injected keys, with no production
history-key access, MCP, hooks or login shells.

The new UI flows have **not** been verified graphically: both attempted tests
failed at launch before exercising their flow, and the session lock was confirmed
separately. The earlier 29-test graphical result applies to `8b7274e`, not these
later changes. A new unlocked graphical run remains required. The current
verification export was not notarized or published; clean-user/Mac, real Intel
hardware and actual appcast update checks also remain pending in #6.

## Reproducing checks

Use the build, hostless and UI commands in [README.md](../README.md), keeping the
committed `Package.resolved`. UI execution requires an unlocked graphical session
and the dedicated fixture host; compiling the suite does not count as execution.

Run storage and publication checks separately:

```bash
python3 scripts/verify-history-processes.py
python3 scripts/test-export-legacy-history.py
python3 scripts/test-audit-publication.py
python3 scripts/audit-publication.py
git diff --check
```

The history probe compiles the production storage code and uses four independent
processes with a fictitious legacy baseline in each of plaintext and encrypted
modes. The encrypted probe uses a deliberately public fixture key provider,
never the production Keychain. Publication-guard tests use disposable
Git repositories with synthetic tokens and disabled Git hooks/signing.

The publication scan checks working files, reachable historical blobs, commit/tag
metadata and any review exports passed through `--extra-file`. It reports
locations, never matched values. It is heuristic; review images, private paths
and asset provenance separately. Open functional limitations are tracked in
[GitHub Issues](https://github.com/tavodev/agentsconfig/issues), with user-facing
boundaries documented in [README.md](../README.md).
