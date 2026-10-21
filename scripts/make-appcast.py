#!/usr/bin/env python3
"""Build the signed Sparkle appcast for one release from its notarized archive.

Runs Sparkle's `generate_appcast` (pinned SPM artifact) in a fresh directory,
so the feed lists exactly this version. The EdDSA private key is read from the
login keychain by Sparkle itself; this script never reads, prints or writes it.
Nothing is uploaded: the output directory holds the two files to attach to the
GitHub Release (`appcast.xml` and the archive under the name the feed expects).
See docs/RELEASING.md.
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NoReturn

REPO = "tavodev/agentsconfig"
ROOT = Path(__file__).resolve().parent.parent
RESOLVED = ROOT / "AgentsConfig.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def fail(message) -> NoReturn:
    sys.exit("make-appcast: " + message)


def pinned_sparkle_version():
    pins = json.loads(RESOLVED.read_text())["pins"]
    for pin in pins:
        if pin["identity"] == "sparkle":
            return pin["state"]["version"]
    fail("Sparkle is not pinned in Package.resolved")


def sparkle_bin(explicit, version):
    """The bin/ folder of the resolved Sparkle artifact, at the pinned version."""
    candidates = [Path(explicit)] if explicit else [Path(p) for p in sorted(glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/AgentsConfig-*/SourcePackages/artifacts/sparkle/Sparkle/bin")))]
    for candidate in candidates:
        changelog = candidate.parent / "CHANGELOG"
        if (candidate / "generate_appcast").is_file() and changelog.is_file() \
                and re.match(r"#?\s*" + re.escape(version) + r"\s", changelog.read_text(errors="replace")):
            return candidate
    fail(f"no Sparkle {version} tools found; resolve packages (xcodebuild -resolvePackageDependencies) "
         "or pass --sparkle-bin")


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--archive", type=Path, required=True,
                        help="Notarized and stapled DMG (preferred) or ZIP of the exported app")
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, e.g. 0.2.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion, e.g. 4")
    parser.add_argument("--notes", type=Path, required=True, help="Markdown release notes for this version")
    parser.add_argument("--out", type=Path, required=True, help="New, empty output directory")
    parser.add_argument("--tag", help="Release tag (default: v<version>)")
    parser.add_argument("--sparkle-bin", help="Sparkle bin/ folder (default: resolved SPM artifact)")
    parser.add_argument("--ed-key-file", help=argparse.SUPPRESS)  # tests only; releases use the keychain
    parser.add_argument("--skip-staple-check", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        fail("--version must look like 1.2.3")
    if not re.fullmatch(r"\d+", args.build):
        fail("--build must be an integer (CFBundleVersion)")
    extension = args.archive.suffix.lower()
    if extension not in (".dmg", ".zip") or not args.archive.is_file():
        fail("--archive must be an existing .dmg or .zip")
    if not args.notes.is_file():
        fail("--notes must be an existing Markdown file")
    if args.out.exists() and any(args.out.iterdir()):
        fail("--out must be new or empty, so the feed contains only this release")
    if extension == ".dmg" and not args.skip_staple_check:
        if subprocess.run(["xcrun", "stapler", "validate", str(args.archive)],
                          capture_output=True).returncode != 0:
            fail("the DMG has no valid stapled notarization ticket")

    tag = args.tag or "v" + args.version
    tools = sparkle_bin(args.sparkle_bin, pinned_sparkle_version())
    args.out.mkdir(parents=True, exist_ok=True)
    name = f"AgentsConfig-{args.version}{extension}"
    shutil.copy2(args.archive, args.out / name)
    shutil.copy2(args.notes, args.out / f"AgentsConfig-{args.version}.md")

    prefix = f"https://github.com/{REPO}/releases/download/{tag}/"
    command = [str(tools / "generate_appcast"), "--download-url-prefix", prefix,
               "--embed-release-notes", "--maximum-deltas", "0",
               "-o", str(args.out / "appcast.xml")]
    if args.ed_key_file:
        command += ["--ed-key-file", args.ed_key_file]
    subprocess.run(command + [str(args.out)], check=True)
    # The notes are embedded in the feed; only the two release assets remain.
    (args.out / f"AgentsConfig-{args.version}.md").unlink()

    feed = (args.out / "appcast.xml").read_text()
    items = ET.fromstring(feed).findall("./channel/item")
    if len(items) != 1:
        fail(f"expected one item in the feed, found {len(items)}")
    item = items[0]
    enclosure = item.find("enclosure")
    checks = {
        "sparkle:version": item.findtext(f"{{{SPARKLE_NS}}}version") == args.build,
        "sparkle:shortVersionString": item.findtext(f"{{{SPARKLE_NS}}}shortVersionString") == args.version,
        "enclosure url": enclosure is not None and enclosure.get("url") == prefix + name,
        "enclosure length": enclosure is not None
                            and enclosure.get("length") == str((args.out / name).stat().st_size),
        "EdDSA signature": enclosure is not None and bool(enclosure.get(f"{{{SPARKLE_NS}}}edSignature")),
        "minimum macOS": bool(item.findtext(f"{{{SPARKLE_NS}}}minimumSystemVersion")),
        "signed feed": "sparkle-signatures" in feed,
    }
    failed = [label for label, ok in checks.items() if not ok]
    if failed:
        fail("generated feed does not match the release: " + ", ".join(failed))
    print(f"Attach to the GitHub Release {tag} (published as Latest, not a pre-release):")
    for asset in ("appcast.xml", name):
        print("  " + str(args.out / asset))


if __name__ == "__main__":
    main()
