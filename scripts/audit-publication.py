#!/usr/bin/env python3
"""Heuristic credential scan of files, reachable Git blobs and commit metadata.

Reports locations and rule names, never matched values. A clean result still
requires a separate review of screenshots, private paths and asset provenance.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path


PATTERNS = {
    "private-key": rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY [B]LOCK-----",
    "github-token": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})",
    "aws-access-key": rb"(?:AKIA|ASIA)[0-9A-Z]{16}",
    "model-api-key": rb"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}",
    "slack-token": rb"xox[baprs]-[A-Za-z0-9-]{20,}",
    "google-api-key": rb"AIza[0-9A-Za-z_-]{35}",
    "gitlab-token": rb"glpat-[A-Za-z0-9_-]{20,}",
    "npm-token": rb"npm_[A-Za-z0-9]{36,}",
    "digitalocean-token": rb"dop_v1_[a-f0-9]{64}",
    "sendgrid-token": rb"SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{30,}",
    "jwt": rb"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
}
COMPILED = {name: re.compile(pattern) for name, pattern in PATTERNS.items()}

# Exact synthetic fixture reviewed on 2026-10-04. Do not ignore arbitrary
# FAKE-prefixed values, test directories or an entire historical blob.
REVIEWED_FIXTURES = {
    ("Tests/LinterTests.swift", "model-api-key", b"sk-ant-api03-" + b"FAKE" * 6),
}


def git(*args):
    return subprocess.check_output(["git", *args])


def inspect(data, location, path, findings, fixtures):
    for rule, pattern in COMPILED.items():
        for match in pattern.finditer(data):
            record = {"location": location, "rule": rule,
                      "line": data[:match.start()].count(b"\n") + 1}
            if (path, rule, match.group()) in REVIEWED_FIXTURES:
                fixtures.append(record)
            else:
                findings.append(record)


def audit(extra_files=()):
    findings, fixtures = [], []
    paths = sorted(set(p for p in git("ls-files", "--cached", "--others",
                                    "--exclude-standard", "-z").split(b"\0") if p))
    for raw in paths:
        path = Path(raw.decode())
        if path.is_symlink():
            findings.append({"location": "working tree: " + str(path),
                             "rule": "symlink-needs-review"})
        elif path.is_file():
            inspect(path.read_bytes(), "working tree: " + str(path),
                    str(path), findings, fixtures)

    # rev-list assigns only one display path to each unique blob. Build the
    # full path set so a blob moved/copied elsewhere cannot inherit a fixture
    # exception from a previous test-only location.
    commits = git("rev-list", "--all").decode().splitlines()
    blob_paths = {}
    for commit in commits:
        for entry in git("ls-tree", "-r", "-z", commit).split(b"\0"):
            if not entry:
                continue
            metadata, path = entry.split(b"\t", 1)
            _, kind, oid = metadata.decode().split()
            if kind == "blob":
                blob_paths.setdefault(oid, set()).add(path.decode())

    blobs = 0
    for entry in git("rev-list", "--objects", "--all").decode().splitlines():
        oid = entry.partition(" ")[0]
        if git("cat-file", "-t", oid).strip() != b"blob":
            continue
        blobs += 1
        paths_for_blob = blob_paths.get(oid, set())
        fixture_path = next(iter(paths_for_blob)) if len(paths_for_blob) == 1 else ""
        inspect(git("cat-file", "blob", oid), "history blob: " + oid,
                fixture_path, findings, fixtures)

    # Removed files, commit messages and annotated tags also become public.
    inspect(git("log", "--all", "--format=%H%x00%an%x00%ae%x00%cn%x00%ce%x00%B"),
            "commit metadata", "", findings, fixtures)
    inspect(git("for-each-ref", "--format=%(refname)%00%(contents)", "refs/tags"),
            "tag metadata", "", findings, fixtures)
    for path in extra_files:
        inspect(path.read_bytes(), "extra file: " + str(path), "", findings, fixtures)
    return {"workingTreePaths": len(paths), "historyBlobs": blobs,
            "commits": len(commits),
            "extraFiles": len(extra_files), "rules": list(PATTERNS),
            "reviewedFixtures": fixtures, "findings": findings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Emit a value-free JSON report")
    parser.add_argument("--extra-file", type=Path, action="append", default=[],
                        help="Also scan an exported issue/PR or other private review file")
    args = parser.parse_args()
    report = audit(args.extra_file)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Checked {report['workingTreePaths']} working-tree paths, "
              f"{report['historyBlobs']} history blobs and {report['commits']} commits.")
        for finding in report["findings"]:
            print(f"{finding['location']} ({finding['rule']})")
        print(f"Reviewed synthetic fixture matches: {len(report['reviewedFixtures'])}.")
        print(f"Credential-pattern findings: {len(report['findings'])}. Manual review is still required.")
    return bool(report["findings"])


if __name__ == "__main__":
    raise SystemExit(main())
