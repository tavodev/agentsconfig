# Release procedure

Publication decisions are tracked in [GitHub Issues](https://github.com/tavodev/agentsconfig/issues).
A release owner authorizes pushes, tags, public visibility changes and signing-service
submissions after reviewing the candidate. Source publication and signed binary
distribution are separate operations.

## Verify a candidate

1. Start from a clean source copy. Resolve the committed `Package.resolved`,
   regenerate with a verified XcodeGen version, and check generated-file drift.
   Use `-onlyUsePackageVersionsFromResolvedFile` for the first build and
   `-disableAutomaticPackageResolution` for subsequent builds using those checkouts.
2. Run the hostless suite, build Release and run the multiprocess history probe.
   Execute `AgentsConfigUI` on an unlocked desktop with the dedicated fixture host.
   Use only fictitious configurations. Commands and coverage are in
   [README.md](../README.md) and [VERIFICATION.md](VERIFICATION.md).
3. Run the publication guard and its tests. Privately review all reachable Git
   history, author metadata, issue/PR bodies and comments, screenshots and asset
   provenance. Deleting a file in a new commit leaves its old blobs in history.
   Keep credential values and private review inventories out of logs and commits.
4. Reconcile README, CHANGELOG, `project.yml`, generated Info.plist and bundled
   dependency notices. Review the complete diff and run `git diff --check` for
   both the working tree and the candidate commit range.
5. Record the exact revision, environment, commands and actual results in the
   release issue and update the dated summary in [VERIFICATION.md](VERIFICATION.md).
   Distinguish compiled UI tests from executed tests; retain failures and limits.

## Publish source

After the owner approves the candidate:

1. Verify the authenticated account, expected local/remote branch and clean working
   tree. Confirm Actions is disabled with
   `gh api repos/tavodev/agentsconfig/actions/permissions` (`enabled: false`).
2. Push the reviewed candidate and verify its remote revision. Integrate unexpected
   remote changes before publishing; never overwrite them.
3. If authorized, change repository visibility and verify the resulting state.
   Actions stays disabled; no hosted workflow is configured by this procedure.
4. If a tag/release is authorized, tag the reviewed revision and publish notes based
   on [CHANGELOG.md](../CHANGELOG.md) and the README's supported scope. Source can
   also be published without a release. Attach binaries only after their own checks.
5. Record the publication URLs and owner decision in the release issue. The owner
   closes release-decision issues.

## Distribute a macOS binary

Use archive/export with Developer ID signing and hardened runtime. Verify bundle
version, entitlements and notices; a normal development build can contain
`get-task-allow` and is not a distribution artifact. Notarize and staple the app.
For a DMG, sign it, notarize it separately and staple its accepted ticket.

Verify Gatekeeper, installation and first launch on a clean Mac or user. Publish
checksums with the validated artifact. Never commit private keys, signing
certificates containing private keys or notarization credentials. Locally signed
builds must not be described as Developer ID signed or notarized.

### Archive and export

Supply the team ID and certificate fingerprint locally; do not store them in the
repository. Release enables hardened runtime, disables development base
entitlements and maps source paths to relative paths. Build both architectures:

```bash
xcodebuild -project AgentsConfig.xcodeproj -scheme AgentsConfig \
  -configuration Release -destination 'generic/platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile \
  -archivePath release-artifacts/AgentsConfig.xcarchive \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$RELEASE_TEAM_ID" \
  CODE_SIGN_IDENTITY="$RELEASE_CERTIFICATE_HASH" archive
xcodebuild -exportArchive \
  -archivePath release-artifacts/AgentsConfig.xcarchive \
  -exportPath release-artifacts/export \
  -exportOptionsPlist /private/path/to/ExportOptions.plist
```

The private export plist uses `method=developer-id`, `destination=export`,
`signingStyle=manual`, `teamID` and `signingCertificate`. Verify that the exported
app has a secure timestamp and no `com.apple.security.get-task-allow` entitlement.

### Notarize and staple

Use an existing `notarytool` keychain profile. Submit a ZIP made with
`ditto -c -k --keepParent`, wait for acceptance, inspect the notary log, and staple
the exported app with `xcrun stapler staple`. Build the signed UDZO DMG from that
stapled app, then submit the DMG separately and staple it after acceptance.
Validate both tickets and Gatekeeper before attaching checksums and binaries
to a GitHub Release. Raw build logs, signing configuration and notarization
credentials remain outside the repository and published assets.
