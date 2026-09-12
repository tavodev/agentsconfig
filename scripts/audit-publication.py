#!/usr/bin/env python3
"""Conservative publication check. Prints locations only, never matched values.
This is a heuristic check, not proof that a repository contains no secrets.
"""
import re
import subprocess
import sys
from pathlib import Path

PATTERNS = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}"),
    re.compile(rb"xox[baprs]-[A-Za-z0-9-]{20,}"),
]

def git(*args):
    return subprocess.check_output(["git", *args])

def suspicious(data):
    return any(p.search(data) for p in PATTERNS)

findings = []
paths = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
for raw in paths:
    if not raw:
        continue
    path = Path(raw.decode())
    if path.is_file() and suspicious(path.read_bytes()):
        findings.append("working tree: " + str(path))
objects = git("rev-list", "--objects", "--all").decode().splitlines()
blobs = 0
for entry in objects:
    oid = entry.split(" ", 1)[0]
    if git("cat-file", "-t", oid).strip() != b"blob":
        continue
    blobs += 1
    if suspicious(git("cat-file", "blob", oid)):
        findings.append("history blob: " + oid)
print(f"Checked {len([p for p in paths if p])} working-tree paths and {blobs} history blobs.")
for finding in findings:
    print(finding)
print(f"Credential-pattern findings: {len(findings)}. Manual review is still required.")
sys.exit(bool(findings))
