#!/usr/bin/env python3
"""Export AgentsConfig history to a new, private folder readable by older apps.

The source is explicit and read-only. Format-2 histories are snapshotted under
their existing index locks; .migrated backups are preserved separately. Nothing
is installed, renamed or removed in the original History folder.
"""
import argparse
from contextlib import contextmanager
import ctypes
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import PurePosixPath
import posixpath
import re
import shutil
import stat
import sys
import uuid


# macOS SDK <sys/stdio.h>; see `man 2 rename`. No replacing-rename fallback.
RENAME_EXCL = 0x00000004
HEX = re.compile(r"[0-9a-f]{64}\Z")
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
ENCRYPTION_MARKER = ".encryption.json"


class ExportError(Exception):
    """Messages deliberately omit document paths, index values and content."""


def inode(info):
    return info.st_dev, info.st_ino


def fingerprint(info):
    return inode(info), info.st_size, info.st_mtime_ns, info.st_ctime_ns


def absolute_path(value):
    path = PurePosixPath(os.fspath(value))
    if not path.is_absolute() or ".." in path.parts or str(path).startswith("//"):
        raise ExportError("Use absolute paths without '..' components.")
    return str(path)


@contextmanager
def directory_path(path):
    """Open each component relative to a held directory; never follow links."""
    path = absolute_path(path)
    fd = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in PurePosixPath(path).parts[1:]:
            next_fd = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd
    finally:
        os.close(fd)


def same_directory(parent, name, fd):
    current = os.stat(name, dir_fd=parent, follow_symlinks=False)
    return stat.S_ISDIR(current.st_mode) and inode(current) == inode(os.fstat(fd))


@contextmanager
def child_directory(parent, name):
    fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent)
    try:
        yield fd
        if not same_directory(parent, name, fd):
            raise ExportError("A source directory changed during export; retry from a stable copy.")
    finally:
        os.close(fd)


def read_regular(parent, name):
    fd = os.open(name, FILE_FLAGS, dir_fd=parent)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ExportError("History contains a non-regular file; nothing was exported.")
        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(fd)
        current = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if fingerprint(before) != fingerprint(after) or fingerprint(after) != fingerprint(current):
            raise ExportError("A source file changed during export; retry from a stable copy.")
        return b"".join(chunks)
    finally:
        os.close(fd)


def write_new(parent, name, data):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 0o600, dir_fd=parent)
    with os.fdopen(fd, "wb") as handle:
        os.fchmod(handle.fileno(), 0o600)
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


@contextmanager
def new_directory(parent, name):
    os.mkdir(name, 0o700, dir_fd=parent)
    fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent)
    try:
        os.fchmod(fd, 0o700)
        yield fd
    finally:
        os.close(fd)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def parse_index(data):
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ExportError("A history index contains duplicate keys.")
            result[key] = value
        return result

    def invalid_constant(_):
        raise ExportError("A history index contains a non-finite number.")

    try:
        return json.loads(data, object_pairs_hook=object_pairs, parse_constant=invalid_constant)
    except (ValueError, UnicodeError):
        raise ExportError("A history index is not valid JSON.") from None


def entries_checked(entries, format_two):
    if not isinstance(entries, list):
        raise ExportError("A history index has an unsupported entries structure.")
    for entry in entries:
        if not isinstance(entry, dict):
            raise ExportError("A history entry has an unsupported structure.")
        ts = entry.get("ts")
        try:
            valid_date = type(ts) in (int, float) and math.isfinite(ts)
        except OverflowError:
            valid_date = False
        if not valid_date:
            raise ExportError("A history entry has an invalid date.")
        digest = entry.get("hash")
        name = entry.get("file")
        if not isinstance(digest, str) or not HEX.fullmatch(digest):
            raise ExportError("A history entry has an invalid content hash.")
        if not isinstance(name, str) or not name or "/" in name or ".." in name or "\0" in name:
            raise ExportError("A history entry has an unsafe content filename.")
        try:
            name.encode("utf-8")
        except UnicodeError:
            raise ExportError("A history entry has an invalid content filename.") from None
        if format_two and name != digest:
            raise ExportError("A format-2 entry does not reference its content hash.")
        if not format_two and not name.endswith(".txt"):
            raise ExportError("A legacy entry has an unsupported content filename.")
        if not isinstance(entry.get("origin"), str):
            raise ExportError("A history entry has an invalid origin.")
        count = entry.get("changeCount", 0)
        if type(count) is not int or not -(2 ** 63) <= count < 2 ** 63 or not isinstance(entry.get("summary", ""), str):
            raise ExportError("A history entry has invalid change metadata.")
    return entries


def checked_text(data, digest=None):
    try:
        data.decode("utf-8")
    except UnicodeError:
        raise ExportError("A history content file is not UTF-8.") from None
    if digest is not None and hashlib.sha256(data).hexdigest() != digest:
        raise ExportError("A history content file does not match its recorded hash.")
    return data


@contextmanager
def index_lock(directory):
    # The store always creates this before publishing format 2. Opening an
    # existing lock read-only preserves the source's files and permissions.
    fd = os.open(".index.lock", FILE_FLAGS, dir_fd=directory)
    try:
        held = os.fstat(fd)
        if not stat.S_ISREG(held.st_mode):
            raise ExportError("A format-2 history has an unsafe lock file.")
        fcntl.flock(fd, fcntl.LOCK_EX)
        current = os.stat(".index.lock", dir_fd=directory, follow_symlinks=False)
        if inode(held) != inode(current) or not stat.S_ISREG(current.st_mode):
            raise ExportError("A history lock changed while waiting; retry from a stable copy.")
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


@contextmanager
def history_guard(source_path):
    """Cooperate with encryption/purge before taking any per-index lock.

    Older stores have no root lock. Do not create one in a read-only export;
    instead reject publication if another process introduces it mid-export.
    """
    parent_path, source_name = posixpath.split(source_path)
    lock_name = "." + source_name + ".history.lock"
    with directory_path(parent_path) as parent:
        try:
            fd = os.open(lock_name, FILE_FLAGS, dir_fd=parent)
        except FileNotFoundError:
            def unchanged():
                try:
                    os.stat(lock_name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    return
                raise ExportError("History protection changed during export; retry after migration finishes.")
            yield unchanged
            return
        try:
            held = os.fstat(fd)
            if not stat.S_ISREG(held.st_mode):
                raise ExportError("History has an unsafe root lock.")
            fcntl.flock(fd, fcntl.LOCK_SH)

            def unchanged():
                current = os.stat(lock_name, dir_fd=parent, follow_symlinks=False)
                if not stat.S_ISREG(current.st_mode) or inode(held) != inode(current):
                    raise ExportError("The history root lock changed while waiting; retry.")

            unchanged()
            yield unchanged
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def plaintext_marker(source, names):
    if ENCRYPTION_MARKER not in names:
        return None
    data = read_regular(source, ENCRYPTION_MARKER)
    marker = parse_index(data)
    if not isinstance(marker, dict) or type(marker.get("format")) is not int or marker.get("format") != 1:
        raise ExportError("History encryption metadata is unsupported; open the current app first.")
    if marker.get("phase") != "plain":
        raise ExportError("History is encrypted or migrating. Decrypt or resume migration in Settings before exporting for an older app.")
    return data


def verify_listing(directory, names, allowed):
    if set(names) - allowed:
        raise ExportError("History contains unrecognized items; no data was silently omitted.")
    for name in names:
        mode = os.stat(name, dir_fd=directory, follow_symlinks=False).st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ExportError("History contains a symbolic link or special file.")


def reserve_name(name, names, destination):
    if name in names:
        raise ExportError("Two active histories map to the same legacy folder; refusing to guess.")
    if len(os.fsencode(name)) > os.fpathconf(destination, "PC_NAME_MAX"):
        raise ExportError("A legacy folder name exceeds the destination filesystem's name limit.")
    names.add(name)


def export_format_two(source, source_name, output, used_names):
    with child_directory(source, source_name) as directory, index_lock(directory):
        before_names = set(os.listdir(directory))
        verify_listing(directory, before_names, {"index.json", ".index.lock", "objects"})
        index_data = read_regular(directory, "index.json")
        index = parse_index(index_data)
        if not isinstance(index, dict) or index.get("format") != 2 or type(index.get("format")) is not int:
            raise ExportError("A hashed history has an unsupported index format.")
        if set(index) != {"format", "path", "entries"}:
            raise ExportError("A format-2 index has unsupported metadata.")
        path = index.get("path")
        if not isinstance(path, str) or "\0" in path or not path.startswith("/") or path.startswith("//") or posixpath.normpath(path) != path:
            raise ExportError("A format-2 index has a non-canonical document path.")
        try:
            path_digest = hashlib.sha256(path.encode("utf-8")).hexdigest()
        except UnicodeError:
            raise ExportError("A format-2 index contains an invalid document path.") from None
        if path_digest != source_name:
            raise ExportError("A format-2 index does not belong to its history folder.")
        entries = entries_checked(index["entries"], True)
        name = path.replace("/", "__")
        reserve_name(name, used_names, output)
        with child_directory(directory, "objects") as objects, new_directory(output, name) as target:
            object_names = set(os.listdir(objects))
            if any(not HEX.fullmatch(blob) for blob in object_names):
                raise ExportError("A content directory contains an unrecognized object.")
            for blob in object_names:
                if not stat.S_ISREG(os.stat(blob, dir_fd=objects, follow_symlinks=False).st_mode):
                    raise ExportError("A content directory contains a symbolic link or special file.")
            exported = []
            for ordinal, entry in enumerate(entries):
                data = checked_text(read_regular(objects, entry["file"]), entry["hash"])
                filename = f"{ordinal:08d}-{uuid.uuid4().hex}.txt"
                write_new(target, filename, data)
                legacy = dict(entry, file=filename)
                legacy.setdefault("changeCount", 0)
                legacy.setdefault("summary", "")
                exported.append(legacy)
            write_new(target, "index.json", json_bytes(exported))
            if set(os.listdir(objects)) != object_names:
                raise ExportError("History objects changed during export.")
        if read_regular(directory, "index.json") != index_data or set(os.listdir(directory)) != before_names:
            raise ExportError("A history changed during export.")
        return len(entries), len(object_names - {entry["file"] for entry in entries})


def export_legacy(source, name, output):
    """Legacy writers do not lock: require a stopped app and verify all hashes."""
    with child_directory(source, name) as directory, new_directory(output, name) as target:
        names = set(os.listdir(directory))
        if "index.json" not in names:
            raise ExportError("A legacy history has no index.")
        allowed = {item for item in names if item == "index.json" or
                   (item.endswith(".txt") and ".." not in item)}
        verify_listing(directory, names, allowed)
        index_data = read_regular(directory, "index.json")
        entries = entries_checked(parse_index(index_data), False)
        expected = {}
        for entry in entries:
            previous = expected.setdefault(entry["file"], entry["hash"])
            if previous != entry["hash"]:
                raise ExportError("Legacy entries share a file with different hashes; recovery is ambiguous.")
        if not set(expected).issubset(names):
            raise ExportError("A legacy index references missing content.")
        # Preserve orphan text files too; .migrated backups remain byte-for-byte
        # copies rather than being merged into a newer, potentially retained index.
        for filename in sorted(names - {"index.json"}):
            data = checked_text(read_regular(directory, filename), expected.get(filename))
            write_new(target, filename, data)
        write_new(target, "index.json", index_data)
        if read_regular(directory, "index.json") != index_data or set(os.listdir(directory)) != names:
            raise ExportError("A legacy history changed during export; close all app versions first.")
        return len(entries)


def publish_exclusive(parent, staging, destination):
    if sys.platform != "darwin":
        raise ExportError("Exclusive publication requires macOS renameatx_np; no unsafe fallback is used.")
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(parent, os.fsencode(staging), parent, os.fsencode(destination), RENAME_EXCL) != 0:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise ExportError("The destination already exists; nothing was replaced.")
        raise ExportError(f"Exclusive publication failed (errno {code}); nothing was replaced.")


def export_history(source_path, destination_path):
    source_path = absolute_path(source_path)
    destination_path = absolute_path(destination_path)
    parent_path, destination = posixpath.split(destination_path)
    if not destination or destination in {".", ".."}:
        raise ExportError("The destination must name a new folder.")
    if posixpath.commonpath([source_path, parent_path]) == source_path:
        raise ExportError("The destination cannot be inside the source history.")
    with history_guard(source_path) as protection_unchanged, directory_path(source_path) as source, directory_path(parent_path) as parent:
        try:
            os.stat(destination, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ExportError("The destination already exists; nothing was replaced.")
        staging = ".agentsconfig-legacy-" + uuid.uuid4().hex
        with new_directory(parent, staging) as output:
            published = False
            try:
                names = set(os.listdir(source))
                marker_data = plaintext_marker(source, names)
                used_names = {"legacy-backups", "export-manifest.json"}
                summary = {"format": 1, "activeHistories": 0, "versions": 0,
                           "legacyBackups": 0, "backupVersions": 0,
                           "unreferencedFormat2Objects": 0,
                           "snapshotScope": "per-history; no global instant is claimed"}
                backups = []
                for name in sorted(names):
                    if name == ENCRYPTION_MARKER:
                        continue
                    mode = os.stat(name, dir_fd=source, follow_symlinks=False).st_mode
                    if not stat.S_ISDIR(mode):
                        raise ExportError("The source contains a symbolic link, special file or unrecognized root item.")
                    if HEX.fullmatch(name):
                        count, orphans = export_format_two(source, name, output, used_names)
                        summary["activeHistories"] += 1
                        summary["versions"] += count
                        summary["unreferencedFormat2Objects"] += orphans
                    elif name.startswith("__") and name.endswith(".migrated"):
                        backups.append(name)
                    elif name.startswith("__") and ".." not in name:
                        reserve_name(name, used_names, output)
                        summary["versions"] += export_legacy(source, name, output)
                        summary["activeHistories"] += 1
                    else:
                        raise ExportError("The source contains an unrecognized history folder; nothing was omitted.")
                if backups:
                    with new_directory(output, "legacy-backups") as backup_output:
                        for name in backups:
                            summary["backupVersions"] += export_legacy(source, name, backup_output)
                            summary["legacyBackups"] += 1
                if set(os.listdir(source)) != names:
                    raise ExportError("The source history folders changed during export; retry.")
                if plaintext_marker(source, names) != marker_data:
                    raise ExportError("History encryption state changed during export; retry.")
                protection_unchanged()
                # Confirm path components still identify the held roots before
                # publication. Reads/writes above use held descriptors throughout.
                with directory_path(source_path) as current_source, directory_path(parent_path) as current_parent:
                    if inode(os.fstat(source)) != inode(os.fstat(current_source)) or inode(os.fstat(parent)) != inode(os.fstat(current_parent)):
                        raise ExportError("A source or destination parent changed during export.")
                write_new(output, "export-manifest.json", json_bytes(summary))
                if not same_directory(parent, staging, output):
                    raise ExportError("The staging folder changed; nothing was published.")
                publish_exclusive(parent, staging, destination)
                published = True
                return summary
            finally:
                if not published:
                    try:
                        if same_directory(parent, staging, output):
                            shutil.rmtree(staging, dir_fd=parent)
                    except FileNotFoundError:
                        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="Absolute History folder; no real-home default")
    parser.add_argument("--destination", required=True, help="Absolute new folder in an existing parent")
    args = parser.parse_args()
    try:
        summary = export_history(args.source, args.destination)
    except ExportError as error:
        print("export-legacy-history: " + str(error), file=sys.stderr)
        return 1
    except OSError as error:
        print(f"export-legacy-history: filesystem operation failed (errno {error.errno}); no existing destination was replaced.", file=sys.stderr)
        return 1
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
