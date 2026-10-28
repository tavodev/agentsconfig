#!/usr/bin/env python3
"""Exercise production SnapshotStore migration and flock across four OS processes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
home = Path(tempfile.mkdtemp(prefix="agentsconfig-history-probe-")).resolve()
root = home / "Library/Application Support/AgentsConfig/History"
path = str(home / "config.json")
legacy = root / path.replace("/", "__")
legacy.mkdir(parents=True)
(legacy / "legacy.txt").write_text("legacy baseline")
(legacy / "index.json").write_text(json.dumps([{"ts": 1700000000, "hash": "legacy", "file": "legacy.txt", "origin": "baseline", "changeCount": 0, "summary": "fixture"}]))
executable = home / "history-probe"
sources = ["Sources/Models/Models.swift", "Sources/Services/AppSettings.swift", "Sources/Services/AtomicWriter.swift", "Sources/Services/HistoryKeychain.swift", "Sources/Services/HistoryEncryption.swift", "Sources/Services/SnapshotStore.swift", "scripts/history-probe/Probe.swift"]
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-o", str(executable), *[str(repo / source) for source in sources]], check=True)
environment = dict(os.environ, AGENTSCONFIG_HOME=str(home))
processes = [subprocess.Popen([str(executable), str(root), path, "write", str(worker)], env=environment) for worker in range(4)]
for process in processes:
    if process.wait(timeout=30) != 0:
        raise RuntimeError("history worker failed")
subprocess.run([str(executable), str(root), path, "verify", "0"], env=environment, check=True)
assert legacy.with_name(legacy.name + ".migrated").is_dir()
print("Original legacy preserved at", legacy.with_name(legacy.name + ".migrated"))
print("Probe home:", home)

# The encrypted run uses a deliberately public, fixed fixture provider. It never
# queries Keychain or creates a production key; only test processes know this flag.
encrypted_root = home / "Library/Application Support/AgentsConfigEncrypted/History"
encrypted_path = str(home / "encrypted-config.json")
encrypted_legacy = encrypted_root / encrypted_path.replace("/", "__")
encrypted_legacy.mkdir(parents=True)
(encrypted_legacy / "legacy.txt").write_text("legacy baseline")
(encrypted_legacy / "index.json").write_text(json.dumps([{"ts": 1700000000, "hash": "legacy", "file": "legacy.txt", "origin": "baseline", "changeCount": 0, "summary": "fixture"}]))
def encrypted_command(mode, worker="0"):
    return [str(executable), str(encrypted_root), encrypted_path, mode, str(worker), "encrypted-fixture"]
subprocess.run(encrypted_command("encrypt"), env=environment, check=True)
encrypted_processes = [subprocess.Popen(encrypted_command("write", worker), env=environment) for worker in range(4)]
for process in encrypted_processes:
    if process.wait(timeout=30) != 0:
        raise RuntimeError("encrypted history worker failed")
subprocess.run(encrypted_command("verify"), env=environment, check=True)
assert encrypted_legacy.with_name(encrypted_legacy.name + ".migrated").is_dir()
for blob in encrypted_root.rglob("*"):
    if blob.is_file() and blob.name not in (".index.lock", ".encryption.json"):
        assert blob.read_bytes().startswith(b"AgentsConfigHistoryAESGCM1\0"), "fixture history contains plaintext"
