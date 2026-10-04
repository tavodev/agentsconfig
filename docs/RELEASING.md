# Release procedure

The source publication candidate is experimental 0.1.0 (build 2), under MIT.
Preparation produces a reviewed local commit and verification evidence. Pushes,
tags, releases, public visibility and signing-service submissions require the
owner's publication instruction after reviewing that candidate.

## Candidate verification

1. Review all tracked and new files. Run `python3 scripts/audit-publication.py` as a baseline credential-pattern check, then perform a broader private secret/provenance review against the working tree and all Git history intended for publication. Investigate findings privately; never paste secret values into logs. Review screenshots and asset provenance separately.
2. From a clean source copy, resolve only Package.resolved versions, regenerate with a verified XcodeGen version (2.46.0 in the current preparation), check generated-file drift, run `git diff --check` (worktree and `git diff --check <base>..HEAD` for the candidate range), build Release and run hostless tests. Use `-onlyUsePackageVersionsFromResolvedFile` for the first build, then `-disableAutomaticPackageResolution` for subsequent builds using those checkouts.
3. Run `python3 scripts/verify-history-processes.py`.
4. Compile and execute `AgentsConfigUI` on an unlocked macOS desktop. Complete the live matrix in repair-plan/VERIFICATION.md using fictional data. Preserve failures and limitations.
5. Reconcile README, CHANGELOG, draft release notes, version/build in project.yml and generated Info.plist, and third-party notices. Record results in RELEASE_READINESS.md.
6. Review the complete diff and prepare focused commits using English gitmoji summaries and descriptive bodies. Obtain explicit publication authorization before pushing or tagging.

Also run `python3 scripts/test-audit-publication.py` after changing the scanner.
The scanner covers reachable blobs, commit and annotated-tag metadata, and extra
files supplied with `--extra-file`. Its one exact reviewed token-shaped fixture
is restricted to `Tests/LinterTests.swift`; other credentials in that same file
remain findings. A clean scan is not a comprehensive security audit.

## Source publication

The existing repository is `tavodev/agentsconfig`, with GitHub Actions disabled
at repository level and no hosted CI configuration. The owner requested open-source
preparation on 2026-10-04; this supersedes the earlier decision to stop preparation
at the private source repository. Actual publication remains a separate step.
The security email was confirmed monitored on 2026-09-19.

Before approval, reconcile [release readiness](RELEASE_READINESS.md) and
[the private-material review](audits/2026-10-04-publication.md). Public visibility
exposes reachable Git history, author metadata, issue/PR bodies and comments,
including closed items. Local privacy review must cover all of these. Historical
images require visual inspection; deleting a file in a new commit does not remove
its historical blobs.

After the owner approves the reviewed candidate:

1. Verify account `tavodev`, the expected local/remote `main`, a clean working tree,
   and `gh api repos/tavodev/agentsconfig/actions/permissions` (`enabled: false`).
2. Push the prepared candidate to the existing private `main` and verify the remote
   commit before changing visibility. Never overwrite unexpected remote changes.
3. Change visibility only if the instruction explicitly authorizes it. Verify the
   resulting repository visibility and that Actions remains disabled.
4. Create `v0.1.0` and a GitHub source release only if those actions are authorized;
   use [the prepared release notes](releases/0.1.0.md). Source publication can also
   proceed without a tag/release. Remove the draft wording when publishing.
5. Record the owner decision and actual publication URLs in release readiness and
   issue #5. Only the owner closes release-decision issues.

Do not claim hosted CI results or a downloadable notarized app. A signed DMG and
clean-machine installation verification remain independent work in issue #6.

## Optional binary distribution

Use an owner-provided Developer ID identity, hardened runtime and appropriate signing configuration. Build Release, verify bundled licenses and version, sign all relevant code, submit for notarization, staple the accepted ticket and verify Gatekeeper assessment on a clean Mac. Produce an archive and SHA-256 checksum from the validated artifact. Never commit signing keys, certificates with private keys or notarization credentials. Test installation and first launch independently of the development checkout.

Unsigned/ad-hoc development builds must not be described as Developer ID signed or notarized. Source-only publication does not require binary signing. No binary publication workflow is enabled automatically.
