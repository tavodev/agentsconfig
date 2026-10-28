# Preparing history for an older app

`scripts/export-legacy-history.py` prepares a new, private history folder in the
original layout understood by older AgentsConfig builds. It does not install an
older app, replace the live History folder, rename `.migrated` backups or change
the source's files and permissions. Keep the current history while reviewing the
export and testing recovery with an isolated macOS user.

Close all versions of AgentsConfig before exporting. The tool takes each existing
format-2 index lock while copying that history, but legacy versions did not use
locks. An export represents a consistent snapshot of each indexed history, not
one simultaneous snapshot of the entire store. Concurrent creation/removal of
history folders aborts the operation.

## Export

Use Python 3 on macOS. Both paths must be absolute, without `..` components or
symbolic links. The source must be an explicitly selected History folder; the
destination must not exist and its parent must already exist. There is no default
source pointing at the user's history.

```bash
python3 scripts/export-legacy-history.py \
  --source /absolute/path/to/History \
  --destination /absolute/path/to/recovery/LegacyHistory
```

If history is encrypted or a migration is incomplete, first decrypt it or resume
the migration in the current app's Settings. The exporter never reads Keychain
keys or decrypts files. It accepts an absent encryption marker or the completed
`plain` state, and holds a shared lock on the existing sibling history root lock
before taking index locks. It does not create or alter either lock file.

The destination contains:

- An original-style directory for every active history, with an array
  `index.json` and separate `.txt` content files. Dates, hashes, origins, summaries
  and change counts are preserved. Repeated content and versions created in the
  same second keep distinct content filenames.
- Unmigrated legacy histories in their original layout.
- `legacy-backups/` with complete copies of every `.migrated` backup, including
  backups no longer associated with an active history and unindexed legacy text
  files. These backups do not replace or merge with newer active versions. An
  older app does not discover this subfolder automatically; preserve it for
  separate recovery if needed.
- `export-manifest.json` with counts and the per-history snapshot scope. Format-2
  objects not referenced by an index are counted but are not exported as versions.

All created directories use `0700` and files use `0600`. The exported history
contains full, unencrypted content, just as the older app requires. Keep it in
private storage. The command prints counts, never document paths or content.

## Failure and compatibility rules

The exporter validates the relationship between each format-2 path and directory,
every referenced content hash, UTF-8 text and legacy filenames. A format-2 history
without its existing, regular `.index.lock` is refused. Symbolic links, special
files, unsupported metadata, missing content and unknown files are rejected;
nothing is silently merged or discarded. Two active paths that collapse to the
same legacy directory name are ambiguous and abort the export.

Files are prepared in a private sibling staging directory. Publication uses
macOS `renameatx_np` with `RENAME_EXCL`, so a destination created concurrently is
also preserved. A handled failure removes the staging directory; an abrupt kill
or power loss can leave an unpublished `.agentsconfig-legacy-*` folder in the
destination parent. The source is never a staging or cleanup target. Filesystems
without exclusive rename support fail without using a replacing rename.

Use the exported active tree only with an older app that is stopped while its
history location is prepared. Switching an installation to that copy is a
separate, explicit operation. This tool does not change the older app's limits,
fix corruption already present in a legacy backup, or coordinate with writers
that ignore AgentsConfig's locks. It refuses corruption rather than guessing
which data should win.

## Regression checks

```bash
python3 scripts/test-export-legacy-history.py
```

The tests use temporary histories and fictitious document paths. They cover
exclusive publication races, input preservation, private modes, lock waiting and
replacement, encryption states, symlinks and special files, collisions,
corruption, backup preservation, empty content, Unicode and repeated versions.
They also compile and execute the original repository reader from commit
`14ab9bb`, replacing only its history-root property with a temporary fixture
root, and verify that it reads the exported versions. That compatibility check
requires Git and the local Xcode Swift toolchain; it never reads the real history.
