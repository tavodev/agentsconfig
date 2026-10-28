#!/usr/bin/env python3
"""History export regressions; all source histories and content are fictitious."""
from collections import Counter
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("export-legacy-history.py").resolve()
REPO = SCRIPT.parent.parent
SPEC = importlib.util.spec_from_file_location("legacy_history_export", SCRIPT)
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)


@unittest.skipUnless(sys.platform == "darwin", "exclusive directory publication uses macOS renameatx_np")
class LegacyHistoryExportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="agentsconfig-legacy-export-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "History"
        self.source.mkdir(mode=0o700)
        self.output = self.root / "LegacyHistory"

    def entry(self, content, ordinal=0):
        digest = hashlib.sha256(content).hexdigest()
        return {"id": f"fixture-{ordinal}", "ts": 1_700_000_000.25,
                "hash": digest, "file": digest, "origin": "app",
                "changeCount": ordinal, "summary": "Fictional change"}

    def format_two(self, path="/fixture/alpha/config.json", contents=(b"first", b"second")):
        name = hashlib.sha256(path.encode()).hexdigest()
        directory = self.source / name
        directory.mkdir(mode=0o700)
        (directory / ".index.lock").touch(mode=0o600)
        objects = directory / "objects"
        objects.mkdir(mode=0o700)
        entries = []
        for ordinal, content in enumerate(contents):
            entry = self.entry(content, ordinal)
            (objects / entry["file"]).write_bytes(content)
            entries.append(entry)
        (directory / "index.json").write_text(json.dumps({"format": 2, "path": path, "entries": entries}))
        return directory

    def legacy(self, name="__fixture__orphan__config.json.migrated", content=b"legacy baseline"):
        directory = self.source / name
        directory.mkdir(mode=0o700)
        entry = self.entry(content)
        entry.pop("id")
        entry["file"] = "1700000000-original.txt"
        (directory / entry["file"]).write_bytes(content)
        (directory / "index.json").write_text(json.dumps([entry]))
        return directory

    def snapshot(self, root=None):
        root = root or self.source
        result = {}
        for path in [root, *sorted(root.rglob("*"))]:
            info = path.lstat()
            value = path.read_bytes() if stat.S_ISREG(info.st_mode) else None
            link = os.readlink(path) if stat.S_ISLNK(info.st_mode) else None
            result[str(path.relative_to(root))] = (info.st_mode, info.st_mtime_ns, value, link)
        return result

    def export(self):
        return EXPORT.export_history(str(self.source), str(self.output))

    def assert_no_staging(self):
        self.assertEqual(list(self.root.glob(".agentsconfig-legacy-*")), [])

    def assert_failure_unchanged(self):
        before = self.snapshot()
        with self.assertRaises((EXPORT.ExportError, OSError)):
            self.export()
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.output.exists())
        self.assert_no_staging()

    def test_repeated_content_same_timestamp_empty_and_unicode_are_preserved(self):
        contents = [b"A", b"B", b"A", b"", "Ficción 🦀\n".encode()]
        self.format_two(contents=contents)
        before = self.snapshot()
        report = self.export()
        self.assertEqual(report["versions"], 5)
        directory = self.output / "__fixture__alpha__config.json"
        entries = json.loads((directory / "index.json").read_text())
        self.assertEqual(len({entry["file"] for entry in entries}), 5)
        self.assertEqual([entry["ts"] for entry in entries], [1_700_000_000.25] * 5)
        self.assertEqual([entry["changeCount"] for entry in entries], list(range(5)))
        self.assertEqual([entry["id"] for entry in entries], [f"fixture-{i}" for i in range(5)])
        self.assertEqual([(directory / entry["file"]).read_bytes() for entry in entries], contents)
        self.assertEqual(self.snapshot(), before)
        for path in [self.output, *self.output.rglob("*")]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700 if path.is_dir() else 0o600)
        self.assert_no_staging()

    def test_original_legacy_reader_reads_the_export(self):
        contents = [b"A", b"B", b"A", b"", "Ficción 🦀\n".encode()]
        self.format_two(contents=contents)
        self.export()
        # Actual reader from the first repository commit. Only its root property
        # is replaced, so the production reader never visits Application Support.
        source = subprocess.check_output(["git", "show", "14ab9bb:Sources/Services/SnapshotStore.swift"], cwd=REPO, text=True)
        source, count = re.subn(r"    private var root: URL \{.*?\n    \}",
                                "    private var root: URL { fixtureHistoryRoot }", source, count=1, flags=re.DOTALL)
        self.assertEqual(count, 1)
        prelude = '''
import Foundation
let fixtureHistoryRoot = URL(fileURLWithPath: CommandLine.arguments[1])
struct SemanticChange {}
enum DiffEngine { static func summary(_ changes: [SemanticChange]) -> String { "" } }
struct FileVersion {
    enum Origin: String { case app, external, baseline }
    var date: Date
    var hash: String
    var file: String
    var origin: Origin
    var changeCount: Int
    var summary: String
}
'''
        epilogue = '''
let store = SnapshotStore()
let document = "/fixture/alpha/config.json"
let versions = store.loadHistory(for: document)
var contents = [String]()
for version in versions {
    guard let text = store.content(for: document, version: version) else { exit(3) }
    contents.append(text)
}
let data = try JSONSerialization.data(withJSONObject: contents)
FileHandle.standardOutput.write(data)
'''
        swift = self.root / "main.swift"
        swift.write_text(prelude + source + epilogue)
        executable = self.root / "legacy-reader"
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(self.root / "swift-cache"),
                        str(swift), "-o", str(executable)], capture_output=True, check=True)
        result = subprocess.check_output([str(executable), str(self.output)])
        self.assertEqual(Counter(json.loads(result)), Counter(text.decode() for text in contents))

    def test_legacy_active_and_unassociated_migrated_backup_are_preserved(self):
        self.format_two()
        active = self.legacy("__fixture__separate__config.json", b"active legacy")
        backup = self.legacy()
        (backup / "1700000001-unindexed.txt").write_text("unindexed backup content")
        before = self.snapshot()
        report = self.export()
        self.assertEqual(report["activeHistories"], 2)
        self.assertEqual(report["legacyBackups"], 1)
        self.assertEqual(report["backupVersions"], 1)
        for path in backup.iterdir():
            self.assertEqual((self.output / "legacy-backups" / backup.name / path.name).read_bytes(), path.read_bytes())
        for path in active.iterdir():
            self.assertEqual((self.output / active.name / path.name).read_bytes(), path.read_bytes())
        self.assertEqual(self.snapshot(), before)

    def test_associated_backup_does_not_replace_newer_active_history(self):
        self.format_two(contents=[b"newer"])
        backup = self.legacy("__fixture__alpha__config.json.migrated")
        self.export()
        active = self.output / "__fixture__alpha__config.json"
        entries = json.loads((active / "index.json").read_text())
        self.assertEqual((active / entries[0]["file"]).read_bytes(), b"newer")
        self.assertTrue((self.output / "legacy-backups" / backup.name / "index.json").is_file())

    def test_existing_destination_is_never_changed(self):
        self.format_two()
        self.output.mkdir()
        marker = self.output / "keep.txt"
        marker.write_text("existing destination")
        before = self.snapshot()
        with self.assertRaises(EXPORT.ExportError):
            self.export()
        self.assertEqual(marker.read_text(), "existing destination")
        self.assertEqual(self.snapshot(), before)
        self.assert_no_staging()

    def test_publication_race_does_not_replace_new_destination(self):
        self.format_two()
        publish = EXPORT.publish_exclusive

        def competing_destination(parent, staging, destination):
            self.output.mkdir()
            (self.output / "keep.txt").write_text("created concurrently")
            return publish(parent, staging, destination)

        with mock.patch.object(EXPORT, "publish_exclusive", competing_destination):
            with self.assertRaises(EXPORT.ExportError):
                self.export()
        self.assertEqual((self.output / "keep.txt").read_text(), "created concurrently")
        self.assert_no_staging()

    def test_path_collision_is_rejected(self):
        self.format_two("/fixture/a/b.json")
        self.format_two("/fixture/a__b.json")
        self.assert_failure_unchanged()

    def test_format_two_index_path_must_match_folder_and_be_canonical(self):
        directory = self.format_two()
        index_path = directory / "index.json"
        original = json.loads(index_path.read_text())
        for path in ["/fixture/other/config.json", "/fixture/alpha/../alpha/config.json", "relative.json"]:
            with self.subTest(path=path):
                index_path.write_text(json.dumps(dict(original, path=path)))
                self.assert_failure_unchanged()

    def test_missing_or_corrupt_content_is_rejected(self):
        directory = self.format_two()
        blob = next((directory / "objects").iterdir())
        blob.write_bytes(b"corrupt content")
        self.assert_failure_unchanged()
        blob.unlink()
        self.assert_failure_unchanged()

    def test_unrecognized_data_is_rejected_instead_of_omitted(self):
        self.format_two()
        (self.source / "unexpected.txt").write_text("must not silently disappear")
        self.assert_failure_unchanged()

    def test_source_and_destination_parent_components_cannot_be_symlinks(self):
        self.format_two()
        link = self.root / "linked-source"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(OSError):
            EXPORT.export_history(str(link), str(self.output))
        parent_link = self.root / "linked-parent"
        parent_link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            EXPORT.export_history(str(self.source), str(parent_link / "output"))
        self.output.symlink_to(self.root / "not-present")
        with self.assertRaises(EXPORT.ExportError):
            self.export()
        self.assertTrue(self.output.is_symlink())
        self.assert_no_staging()

    def test_symlinked_index_lock_objects_and_content_are_rejected(self):
        directory = self.format_two()
        for name in ["index.json", ".index.lock", "objects"]:
            with self.subTest(name=name):
                path = directory / name
                retained = self.root / (name + ".retained")
                path.rename(retained)
                path.symlink_to(retained, target_is_directory=retained.is_dir())
                self.assert_failure_unchanged()
                path.unlink()
                retained.rename(path)
        blob = next((directory / "objects").iterdir())
        content = self.root / "external-content.txt"
        content.write_bytes(blob.read_bytes())
        blob.unlink()
        blob.symlink_to(content)
        self.assert_failure_unchanged()

    def test_unreferenced_symlink_or_fifo_is_rejected(self):
        directory = self.format_two()
        extra = directory / "objects" / ("0" * 64)
        extra.symlink_to(self.root / "missing")
        self.assert_failure_unchanged()
        extra.unlink()
        os.mkfifo(extra)
        self.assert_failure_unchanged()

    def test_unreferenced_regular_objects_are_counted_and_not_activated(self):
        directory = self.format_two()
        content = b"unreferenced format-2 object"
        (directory / "objects" / hashlib.sha256(content).hexdigest()).write_bytes(content)
        report = self.export()
        self.assertEqual(report["unreferencedFormat2Objects"], 1)
        self.assertEqual(report["versions"], 2)

    def test_missing_lock_aborts_without_creating_one(self):
        directory = self.format_two()
        (directory / ".index.lock").unlink()
        self.assert_failure_unchanged()

    def test_encrypted_or_transitioning_history_is_refused(self):
        self.format_two()
        marker = self.source / ".encryption.json"
        for phase in ["encrypted", "encrypting", "decrypting", "unknown"]:
            with self.subTest(phase=phase):
                marker.write_text(json.dumps({"format": 1, "keyID": "fictional-key-id", "phase": phase}))
                self.assert_failure_unchanged()

    def test_plaintext_marker_is_not_exported_as_history(self):
        self.format_two()
        (self.source / ".encryption.json").write_text(json.dumps({"format": 1, "keyID": "fictional-key-id", "phase": "plain"}))
        (self.root / ".History.history.lock").touch(mode=0o600)
        before = self.snapshot()
        self.assertEqual(self.export()["versions"], 2)
        self.assertFalse((self.output / ".encryption.json").exists())
        self.assertEqual(self.snapshot(), before)

    def test_shared_root_guard_waits_for_migration_lock(self):
        self.format_two()
        root_lock = self.root / ".History.history.lock"
        root_lock.touch(mode=0o600)
        with root_lock.open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            process = subprocess.Popen([sys.executable, str(SCRIPT), "--source", str(self.source),
                                        "--destination", str(self.output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.wait(timeout=0.3)
                self.assertFalse(self.output.exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
                out, err = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, err.decode())
                self.assertEqual(json.loads(out)["versions"], 2)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_new_root_guard_mid_export_prevents_publication(self):
        self.format_two()
        export = EXPORT.export_format_two

        def introduce_root_lock(*args):
            result = export(*args)
            (self.root / ".History.history.lock").touch(mode=0o600)
            return result

        with mock.patch.object(EXPORT, "export_format_two", introduce_root_lock):
            with self.assertRaises(EXPORT.ExportError):
                self.export()
        self.assertFalse(self.output.exists())
        self.assert_no_staging()

    def test_symlinked_root_guard_is_rejected(self):
        self.format_two()
        (self.root / ".History.history.lock").symlink_to(self.root / "missing")
        self.assert_failure_unchanged()

    def test_waits_for_existing_index_lock(self):
        directory = self.format_two()
        with (directory / ".index.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            process = subprocess.Popen([sys.executable, str(SCRIPT), "--source", str(self.source),
                                        "--destination", str(self.output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.wait(timeout=0.3)
                self.assertFalse(self.output.exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
                out, err = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, err.decode())
                self.assertEqual(json.loads(out)["versions"], 2)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_lock_inode_replacement_is_detected(self):
        directory = self.format_two()
        lock = directory / ".index.lock"
        real_flock = fcntl.flock

        def replace_on_acquire(fd, operation):
            if operation == fcntl.LOCK_EX:
                lock.unlink()
                lock.touch(mode=0o600)
            return real_flock(fd, operation)

        with mock.patch.object(EXPORT.fcntl, "flock", replace_on_acquire):
            with self.assertRaises(EXPORT.ExportError):
                self.export()
        self.assertFalse(self.output.exists())
        self.assert_no_staging()

    def test_invalid_legacy_hash_and_escape_filename_are_rejected(self):
        directory = self.legacy()
        index_path = directory / "index.json"
        entries = json.loads(index_path.read_text())
        for change in [{"hash": "0" * 64}, {"file": "../outside.txt"}, {"file": "bad\0.txt"},
                       {"file": "\udcff.txt"}, {"changeCount": 2 ** 100}, {"ts": 10 ** 400}]:
            with self.subTest(change=change):
                index_path.write_text(json.dumps([dict(entries[0], **change)]))
                self.assert_failure_unchanged()

    def test_cli_failure_does_not_print_document_path_or_content(self):
        private_path = "/fixture/PRIVATE-PATH/config.json"
        directory = self.format_two(private_path, [b"PRIVATE-CONTENT"])
        next((directory / "objects").iterdir()).write_bytes(b"PRIVATE-CORRUPT-CONTENT")
        proc = subprocess.run([sys.executable, str(SCRIPT), "--source", str(self.source),
                               "--destination", str(self.output)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)
        self.assertNotIn(private_path, proc.stdout + proc.stderr)
        self.assertNotIn("PRIVATE-CONTENT", proc.stdout + proc.stderr)
        self.assertNotIn("PRIVATE-CORRUPT-CONTENT", proc.stdout + proc.stderr)
        self.assert_no_staging()

    def test_explicit_paths_and_destination_outside_source_are_required(self):
        self.format_two()
        for source, destination in [("relative", str(self.output)), (str(self.source), "relative"),
                                    (str(self.source), str(self.source / "nested")),
                                    (str(self.source / ".." / "History"), str(self.output))]:
            with self.subTest(source=source, destination=destination):
                with self.assertRaises(EXPORT.ExportError):
                    EXPORT.export_history(source, destination)
        self.assert_no_staging()


if __name__ == "__main__":
    unittest.main()
