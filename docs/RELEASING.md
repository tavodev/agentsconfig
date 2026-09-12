# Release procedure

Preparation does not authorize publication, tags, pushes, repository visibility changes or signing-service submissions.

## Candidate verification

1. Review all tracked and new files. Run `python3 scripts/audit-publication.py` as a baseline credential-pattern check, then perform a broader private secret/provenance review against the working tree and all Git history intended for publication. Investigate findings privately; never paste secret values into logs. Review screenshots and asset provenance separately.
2. From a clean source copy, resolve only Package.resolved versions, regenerate with XcodeGen 2.45.4, check generated-file drift, build Release and run hostless tests.
3. Run `python3 scripts/verify-history-processes.py`.
4. Compile and execute `AgentsConfigUI` on an unlocked macOS desktop. Complete the live matrix in repair-plan/VERIFICATION.md using fictional data. Preserve failures and limitations.
5. Reconcile README, CHANGELOG, draft release notes, version/build in project.yml and generated Info.plist, and third-party notices. Record results in RELEASE_READINESS.md.
6. Review the complete diff and prepare focused commits using English gitmoji summaries and descriptive bodies. Obtain explicit publication authorization before pushing or tagging.

## Source publication

After authorization, commit the reviewed candidate, run hosted CI on that exact commit, and require successful checks before creating the version tag and release. Configure default-branch protections and private vulnerability reporting where available. Confirm the security email is monitored. Do not claim hosted CI passed from local results.

## Optional binary distribution

Use an owner-provided Developer ID identity, hardened runtime and appropriate signing configuration. Build Release, verify bundled licenses and version, sign all relevant code, submit for notarization, staple the accepted ticket and verify Gatekeeper assessment on a clean Mac. Produce an archive and SHA-256 checksum from the validated artifact. Never commit signing keys, certificates with private keys or notarization credentials. Test installation and first launch independently of the development checkout.

Unsigned/ad-hoc development builds must not be described as Developer ID signed or notarized. Source-only publication does not require binary signing. No binary publication workflow is enabled automatically.
