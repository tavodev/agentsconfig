#!/usr/bin/env python3
"""Publication guard regressions, using disposable Git repos and fake tokens."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("audit-publication.py").resolve()
TOKEN = "ghp_" + "A" * 36
FIXTURE = "sk-ant-api03-" + "FAKE" * 6


class PublicationAuditTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="agentsconfig-audit-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q", "--template=")
        hooks = self.root / "disabled-hooks"
        hooks.mkdir()
        self.git("config", "core.hooksPath", str(hooks))
        self.git("config", "commit.gpgSign", "false")
        self.git("config", "tag.gpgSign", "false")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.test")
        self.write("README.md", "Fictional repository\n")
        self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.PIPE)

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message="Fixture baseline"):
        self.git("add", "--all")
        self.git("commit", "-qm", message)

    def scan(self, *args):
        result = subprocess.run(["python3", str(SCRIPT), "--json", *args],
                                cwd=self.root, capture_output=True, text=True)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_clean_repository(self):
        code, report = self.scan()
        self.assertEqual(code, 0)
        self.assertEqual(report["findings"], [])

    def test_untracked_token_is_rejected_without_printing_it(self):
        self.write("config.json", TOKEN)
        code, report = self.scan()
        self.assertEqual(code, 1)
        self.assertTrue(any(f["location"] == "working tree: config.json" for f in report["findings"]))

    def test_additional_credential_formats_are_rejected(self):
        examples = {
            "private-key": "-----BEGIN " + "PGP PRIVATE KEY BLOCK-----",
            "aws-access-key": "ASIA" + "A" * 16,
            "model-api-key": "sk-proj-" + "A" * 40,
            "slack-token": "xoxb-" + "A" * 24,
            "google-api-key": "AIza" + "A" * 35,
            "gitlab-token": "glpat-" + "A" * 24,
            "npm-token": "npm_" + "A" * 36,
            "digitalocean-token": "dop_v1_" + "a" * 64,
            "sendgrid-token": "SG." + "A" * 22 + "." + "B" * 43,
            "jwt": "eyJ" + "A" * 20 + "." + "B" * 24 + "." + "C" * 24,
        }
        self.write("config.json", "\n".join(examples.values()))
        code, report = self.scan()
        self.assertEqual(code, 1)
        self.assertEqual({f["rule"] for f in report["findings"]}, set(examples))
        for value in examples.values():
            self.assertNotIn(value, json.dumps(report))

    def test_removed_file_is_still_scanned(self):
        self.write("removed.json", TOKEN)
        self.commit()
        (self.root / "removed.json").unlink()
        self.commit("Remove fixture")
        code, report = self.scan()
        self.assertEqual(code, 1)
        self.assertTrue(any(f["location"].startswith("history blob:") for f in report["findings"]))

    def test_commit_and_tag_messages_are_scanned(self):
        self.git("commit", "--allow-empty", "-qm", TOKEN)
        self.git("tag", "-a", "fixture", "-m", TOKEN)
        code, report = self.scan()
        self.assertEqual(code, 1)
        locations = {f["location"] for f in report["findings"]}
        self.assertIn("commit metadata", locations)
        self.assertIn("tag metadata", locations)

    def test_only_the_exact_reviewed_fixture_at_its_test_path_is_allowed(self):
        self.write("Tests/LinterTests.swift", FIXTURE)
        self.commit()
        code, report = self.scan()
        self.assertEqual(code, 0)
        self.assertEqual(len(report["reviewedFixtures"]), 2)
        self.write("config.json", FIXTURE)
        self.assertEqual(self.scan()[0], 1)

    def test_fixture_does_not_hide_another_token_in_the_same_blob(self):
        self.write("Tests/LinterTests.swift", FIXTURE + "\n" + TOKEN)
        self.commit()
        code, report = self.scan()
        self.assertEqual(code, 1)
        self.assertTrue(any(f["location"].startswith("history blob:") for f in report["findings"]))

    def test_relocated_fixture_does_not_inherit_its_test_path_exception(self):
        self.write("Tests/LinterTests.swift", FIXTURE)
        self.commit()
        self.write("config.json", FIXTURE)
        self.commit("Copy the same blob outside tests")
        (self.root / "config.json").unlink()
        self.commit("Remove the copied fixture")
        code, report = self.scan()
        self.assertEqual(code, 1)
        self.assertTrue(any(f["location"].startswith("history blob:") for f in report["findings"]))

    def test_symlink_requires_review_without_reading_its_target(self):
        (self.root / "external.json").symlink_to("/nonexistent-fixture-target")
        code, report = self.scan()
        self.assertEqual(code, 1)
        self.assertIn("symlink-needs-review", {f["rule"] for f in report["findings"]})

    def test_exported_github_material_is_scanned(self):
        self.write("ignored.json", TOKEN)
        self.write(".gitignore", "ignored.json\n")
        self.assertEqual(self.scan()[0], 0)
        code, report = self.scan("--extra-file", "ignored.json")
        self.assertEqual(code, 1)
        self.assertEqual(report["extraFiles"], 1)


if __name__ == "__main__":
    unittest.main()
