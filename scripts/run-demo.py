#!/usr/bin/env python3
"""Create fictitious configs and optionally launch an isolated AgentsConfig UI."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, help="Path to AgentsConfig.app")
parser.add_argument("--wait", action="store_true", help="Keep the launcher alive while the demo runs")
parser.add_argument("--language", choices=["en", "es"], default="en")
parser.add_argument("--appearance", choices=["system", "light", "dark"], default="system")
parser.add_argument("--high-contrast", action="store_true", help="Preview the increased-contrast appearance in the isolated app")
parser.add_argument("--reduce-transparency", action="store_true", help="Preview SwiftUI reduced transparency in the isolated app")
args = parser.parse_args()
home = Path(tempfile.mkdtemp(prefix="agentsconfig-demo-")).resolve()
suite = "agentsconfig-demo-" + str(uuid.uuid4())
fixtures = {
    "Projects/Harbor/.codex/config.toml": "model = 'project-fixture'\n",
    "Projects/Harbor/.gitmodules": '[submodule "backend"]\n path = backend\n url = https://example.test/backend.git\n',
    "Projects/Harbor/backend/.codex/config.toml": "model = 'submodule-fixture'\n",
    ".claude/settings.json": json.dumps({"theme": "dark", "model": "fixture", "permissions": {"defaultMode": "default", "allow": ["Read(Sources/**)"], "deny": ["Read(.env)"]}, "env": {"API_KEY": "FAKE-ENV", "MODE": "demo"}, "credentials": {"value": "FAKE-CREDENTIAL"}, "tokens": [{"value": "FAKE-ARRAY"}]}),
    ".claude/CLAUDE.md": "# Fictional instructions\nNo commands should be executed.\n",
    ".claude/skills/collection/deep/SKILL.md": "# Fixture skill\n",
    ".claude.json": json.dumps({"mcpServers": {"fixture-local": {"command": "fake-mcp", "args": ["--token", "FAKE-ARG", ""]}, "fixture-remote": {"type": "http", "url": "https://user:FAKE-PASS@example.test/mcp?api_key=FAKE-QUERY", "headers": {"Authorization": "Bearer FAKE-HEADER"}}}}),
    ".codex/config.toml": "# Fixture config\nmodel = 'fixture'\nwhen = 2026-09-10T12:30:00Z\ninteger = 9223372036854775807\n",
    ".codex/AGENTS.md": "# Fixture instructions\n",
    ".codex/auth.json": json.dumps({"OPENAI_API_KEY": "FAKE-AUTH", "credentials": {"value": "FAKE-READONLY"}}),
    ".gemini/settings.json": "{}",
    ".gemini/GEMINI.md": "# Fixture instructions\n",
    ".config/opencode/opencode.json": "{}",
}
for relative, content in fixtures.items():
    path = home / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content + "\n")
    path.chmod(0o600)
result = {"home": str(home), "defaultsSuite": suite}
if args.app:
    # Accept the dedicated UI host as well as the production app.
    with (args.app.resolve() / "Contents/Info.plist").open("rb") as info_file:
        executable_name = plistlib.load(info_file)["CFBundleExecutable"]
    executable = args.app.resolve() / "Contents/MacOS" / executable_name
    environment = dict(os.environ, AGENTSCONFIG_HOME=str(home), AGENTSCONFIG_DEFAULTS_SUITE=suite)
    if args.high_contrast:
        environment["AGENTSCONFIG_DEMO_HIGH_CONTRAST"] = "1"
    if args.reduce_transparency:
        environment["AGENTSCONFIG_DEMO_REDUCE_TRANSPARENCY"] = "1"
    with (home / "app.log").open("w") as log:
        process = subprocess.Popen([str(executable), "-menuBarExtra", "NO", "-notificationsEnabled", "NO", "-appLanguage", args.language, "-appearance", args.appearance], env=environment, stdout=log, stderr=log)
    result["pid"] = process.pid
(home / "demo-run.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2), flush=True)
if args.app and args.wait:
    try:
        exit_code = process.wait()
        if exit_code:
            raise SystemExit(exit_code if exit_code > 0 else 128 - exit_code)
    except KeyboardInterrupt:
        process.terminate()
        process.wait()
