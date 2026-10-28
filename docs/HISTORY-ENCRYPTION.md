# Local history encryption

History encryption is optional and off by default. In **Settings → Privacy**,
choose **Encrypt history…**, review the change and confirm it. The operation
converts existing history and changes how future snapshots are stored; it does
not encrypt or edit agent configuration files. **Decrypt history…** has its own
review and converts existing history back to plaintext protected by filesystem
permissions. Disabling history recording does neither conversion nor deletion.

## Stored data and keys

Each content file uses CryptoKit AES-256-GCM with a fresh nonce, an authentication
tag and a versioned binary header. Encryption covers indexes, content-addressed
blobs, unmigrated legacy history, `.migrated` backups and other regular files
under the history root. Replacement files use `0600`; history directories use
`0700`. Symbolic links are not traversed during conversion.

The random 256-bit root key is stored in the local macOS Keychain as a generic
password with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The service name
uses the running app's bundle identifier plus `.history.encryption`, keeping
Debug and distributed builds separate. The app does not export the key or write
it to preferences, history files, reports or logs. Copying the history directory
does not transfer its Keychain key. The app has no key-export or key-recovery
feature.

The plaintext `.encryption.json` protocol marker contains a format version, a
random key identifier, a phase and an authentication code. It contains no key or
configuration values. HMAC-SHA256 authenticates the marker using a distinct key
derived from the root key with HKDF-SHA256. Editing the mode field cannot
authorize a plaintext downgrade. Do not edit or remove this marker manually.
After encryption has been used, the retained marker remains authenticated even
after decrypting; the original key is still needed to authorize future history
writes.

AES-GCM authenticates each file against its path relative to the history root.
Legacy directory names with repeated `.migrated` suffixes share their original
directory identity, so the normal legacy-to-backup rename remains readable.
File and directory names are not encrypted: legacy names can reveal tracked
configuration paths, and content-addressed blob names still reveal equal content
within the store.

## Conversion and interruption

Conversion publishes an authenticated `encrypting` or `decrypting` phase before
replacing content files. Each replacement is atomic. A completed replacement
stays usable if a later replacement fails; the marker retains the intended
target mode for retry. Mixed encrypted/plaintext reads are permitted only in a
recorded transition. A pending mode transition blocks history writes until it
finishes; failures remain visible instead of silently skipping backup creation.

If the app reports an incomplete change, use **Resume encryption change**.
Recovery also recognizes unfinished AtomicWriter files with the exact reserved
`.<destination>.acfg-tmp-<UUID>` name. Those unpublished temporaries can contain a
partial envelope, or an envelope authenticated for the destination rather than
the temporary filename. Recovery removes only this reserved form under the root
lock, never follows a temporary symlink, and leaves similar names intact. These
temporaries are not indexed versions, blobs or legacy snapshot names.

An unavailable key, invalid authentication tag, damaged marker or unexpected
plaintext does not trigger plaintext fallback. A referenced key identifier is
never replaced with a newly generated key. Restore access to the original key
and valid metadata before using encrypted history again. Retry cannot repair
lost keys or recover authenticated plaintext from corrupted ciphertext.

Replacing current files does not erase plaintext copies retained by independent
backups, filesystem snapshots or earlier exports. Encryption applies to files
in this history store; previews and restored content necessarily exist in app
memory while in use.

## Locking and integrity boundaries

New clients serialize history operations with a root-wide `flock` on the stable
`AgentsConfig/.History.history.lock` beside the history directory. Index
operations retain their per-file `.index.lock`. Purge never unlinks the root
lock. Looking up an absent history root does not create directories, locks,
markers or Keychain entries.

Close older AgentsConfig binaries before converting or accessing this history.
Older binaries do not implement the root mode protocol and must not run
concurrently against it. For older-layout recovery, first decrypt through
Settings and use the separate [history recovery export](HISTORY-RECOVERY.md).

Every affected encrypted file is authenticated when read. Every write obtains
its mode from authenticated root metadata, including background workers and
new store instances; a stale preference cannot make an encrypted store write
plaintext. The root representation preflight is cached using filesystem
identity and timestamps of the root and marker. Removing or replacing the
marker, or recreating the root, invalidates it. Keys and marker authentication
are not cached by that preflight.

The cache avoids scanning all retained versions for every snapshot. It does not
promise immediate discovery of arbitrary manual edits inside unrelated nested
files. Such damage is detected when the affected file is accessed. Root locks
coordinate participating clients; they do not prevent an unrelated process
from modifying paths, links or directories. Resolution and replacement retain
the concurrent-filesystem limitations documented in the README.

## Purge and test isolation

**Delete all history…** deletes indexed versions, legacy backups and stray
content without needing the decryption key. It keeps the mode marker and the
Keychain key so future history uses the chosen mode. Counts and byte summaries
exclude the protocol marker. With a valid transition marker and available key,
an empty purge can complete the target mode.

Purge removes data even if the marker is damaged or its key is unavailable; it
retains that metadata unchanged. Purge does not repair metadata or recover keys.
The encryption status remains an error, and future history writes remain blocked
rather than defaulting to plaintext. A symbolic marker is retained without
following its target. Disabling recording alone never purges existing history.

Tests inject a thread-safe in-memory key provider and use isolated roots.
Production Keychain access is refused when a home override, isolated preferences
or XCTest is present. Tests never use the real history or the real Keychain.
Verification results belong in [VERIFICATION.md](VERIFICATION.md); compiling UI
tests alone is not evidence of UI execution.

The implementation is in [HistoryEncryption.swift](../Sources/Services/HistoryEncryption.swift),
[HistoryKeychain.swift](../Sources/Services/HistoryKeychain.swift) and
[SnapshotStore.swift](../Sources/Services/SnapshotStore.swift).
