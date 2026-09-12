#!/usr/bin/env python3
"""Create fictitious configs and optionally launch an isolated AgentsConfig UI."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, help="Path to AgentsConfig.app")
args = parser.parse_args()
home = Path(tempfile.mkdtemp(prefix="agentsconfig-demo-")).resolve()
suite = "agentsconfig-demo-" + str(uuid.uuid4())
fixtures = {
    ".claude/settings.json": json.dumps({"theme": "dark", "model": "fixture", "env": {"API_KEY": "FAKE-ENV", "MODE": "demo"}, "credentials": {"value": "FAKE-CREDENTIAL"}, "tokens": [{"value": "FAKE-ARRAY"}]}),
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
    executable = args.app.resolve() / "Contents/MacOS/AgentsConfig"
    environment = dict(os.environ, AGENTSCONFIG_HOME=str(home), AGENTSCONFIG_DEFAULTS_SUITE=suite)
    with (home / "app.log").open("w") as log:
        process = subprocess.Popen([str(executable), "-menuBarExtra", "NO", "-notificationsEnabled", "NO"], env=environment, stdout=log, stderr=log)
    result["pid"] = process.pid
(home / "demo-run.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
