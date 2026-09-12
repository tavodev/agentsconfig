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
sources = ["Sources/Models/Models.swift", "Sources/Services/AppSettings.swift", "Sources/Services/AtomicWriter.swift", "Sources/Services/SnapshotStore.swift", "scripts/history-probe/Probe.swift"]
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
