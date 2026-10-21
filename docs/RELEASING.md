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

#### Sparkle's embedded code

The app embeds `Contents/Frameworks/Sparkle.framework`, which ships ad hoc signed
helpers: `Versions/B/Autoupdate`, `Versions/B/Updater.app` and
`Versions/B/XPCServices/{Installer,Downloader}.xpc`. The Developer ID export
re-signs them; the archive alone does not. Check every one of them in the
exported app before notarizing:

```bash
APP=release-artifacts/export/AgentsConfig.app
F=$APP/Contents/Frameworks/Sparkle.framework
for code in "$F/Versions/B/XPCServices/Installer.xpc" \
            "$F/Versions/B/XPCServices/Downloader.xpc" \
            "$F/Versions/B/Autoupdate" "$F/Versions/B/Updater.app" "$F" "$APP"; do
  codesign -dvv "$code" 2>&1 | grep -E '^(Authority=Developer ID Application|Timestamp=|CodeDirectory.*runtime)'
done
codesign --verify --deep --strict --verbose=2 "$APP"
```

Each item must show the Developer ID authority, a timestamp and the `runtime`
flag. If one does not, re-sign inside-out with the same identity, without
`--deep` (it would drop the Downloader service's entitlements), then re-sign the
app preserving its entitlements, and verify again:

```bash
codesign -f -s "$RELEASE_CERTIFICATE_HASH" -o runtime --timestamp "$F/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$RELEASE_CERTIFICATE_HASH" -o runtime --timestamp --preserve-metadata=entitlements "$F/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$RELEASE_CERTIFICATE_HASH" -o runtime --timestamp "$F/Versions/B/Autoupdate"
codesign -f -s "$RELEASE_CERTIFICATE_HASH" -o runtime --timestamp "$F/Versions/B/Updater.app"
codesign -f -s "$RELEASE_CERTIFICATE_HASH" -o runtime --timestamp "$F"
codesign -f -s "$RELEASE_CERTIFICATE_HASH" -o runtime --timestamp --preserve-metadata=entitlements,requirements,flags "$APP"
```

Also confirm the bundle's `SUFeedURL`, `SUPublicEDKey` and update defaults:
`plutil -p "$APP/Contents/Info.plist" | grep '"SU'`.

### Notarize and staple

Use an existing `notarytool` keychain profile. Submit a ZIP made with
`ditto -c -k --keepParent`, wait for acceptance, inspect the notary log, and staple
the exported app with `xcrun stapler staple`. Build the signed UDZO DMG from that
stapled app, then submit the DMG separately and staple it after acceptance.
Validate both tickets and Gatekeeper before attaching checksums and binaries
to a GitHub Release. Raw build logs, signing configuration and notarization
credentials remain outside the repository and published assets.

## Automatic updates (Sparkle)

Installed apps check
`https://github.com/tavodev/agentsconfig/releases/latest/download/appcast.xml`
once a day and download, verify and install the update it lists. Every release
from the first Sparkle-enabled version on must publish a signed `appcast.xml`,
or installed copies never learn about it.

### Signing key

The EdDSA (ed25519) key pair lives in the release owner's login keychain
(item `https://sparkle-project.org`, account `ed25519`). Only the public key is
in the repository (`SUPublicEDKey` in `project.yml` → `Support/Info.plist`).
Sparkle's tools come with the resolved package, in
`~/Library/Developer/Xcode/DerivedData/AgentsConfig-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
`generate_keys -p` prints the public key; it must equal `SUPublicEDKey`.

- Keep an offline backup of the private key (`generate_keys -x <file>` to an
  encrypted volume or password manager, then delete the file). Without it no
  further update can be signed for installed copies; with
  `SUVerifyUpdateBeforeExtraction` the only recovery path is a Developer ID
  signed DMG carrying a new key, so treat loss as serious.
- Never commit, attach, log or paste the private key or an exported key file.

### Publish an update

1. Bump `MARKETING_VERSION`/`CFBundleShortVersionString` and
   `CURRENT_PROJECT_VERSION`/`CFBundleVersion` in `project.yml` (Sparkle compares
   `CFBundleVersion`, which must increase), regenerate, and run the candidate
   verification above.
2. Archive, export, verify Sparkle's embedded code, notarize and staple the app
   and the DMG as described above. The update archive is the stapled DMG
   (preferred: Developer ID signed, which is also the key-rotation fallback) or a
   `ditto -c -k --keepParent` ZIP of the stapled app.
3. Write the release notes for this version to a Markdown file (from
   CHANGELOG), then build the feed:

   ```bash
   python3 scripts/make-appcast.py --archive release-artifacts/AgentsConfig.dmg \
     --version 0.2.0 --build 4 --notes release-artifacts/notes-0.2.0.md \
     --out release-artifacts/appcast-0.2.0
   ```

   The script uses the pinned `generate_appcast`, which signs the archive and
   the feed with the keychain key (macOS may ask to allow keychain access). It
   writes a feed containing only this version, with the download URL
   `https://github.com/tavodev/agentsconfig/releases/download/v<version>/AgentsConfig-<version>.dmg`,
   embedded notes, `minimumSystemVersion`, the archive's EdDSA signature and the
   feed signature, and fails if any of these does not match the arguments.
   For a manual check, `sign_update --verify <archive> <edSignature>` verifies
   the item and `sign_update --verify appcast.xml` the feed. Do not edit the
   feed by hand after signing; regenerate it.
4. Create the GitHub Release for tag `v<version>` and attach both files from the
   output folder with exactly those names (`appcast.xml` and
   `AgentsConfig-<version>.dmg`), plus checksums. Publish it as a regular
   release marked **Latest**: `releases/latest` ignores drafts and
   pre-releases, so a pre-release would leave installed copies on the previous
   feed.
5. Confirm with `curl -sIL https://github.com/tavodev/agentsconfig/releases/latest/download/appcast.xml`
   that the URL resolves to the new asset, then check for updates from an
   installed previous version on a test Mac or user.

### Upgrading from 0.1.0

0.1.0 has no updater. Its users must download and install the first
Sparkle-enabled release by hand (replace the app in `/Applications`); say so in
that release's notes. Later releases arrive through Sparkle.
