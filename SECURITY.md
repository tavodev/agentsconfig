# Security Policy

AgentsConfig reads and writes your AI agents' global configuration
files and detects (and masks) secrets stored in them. If you find a
vulnerability — especially anything involving credential handling,
file writes outside the documented paths, or snapshot storage — please
report it through a **private** channel:

- **Email:** hola@tavo.dev (monitored; owner-confirmed 2026-09-19)

Please do **not** file public GitHub issues for unpatched
vulnerabilities, and do not disclose the issue publicly until it has
been addressed. There is no formal SLA; this is a personal open-source
project, but reports are taken seriously.

## Supported versions

Before the first release, fixes target the current development branch. The first release is experimental; older snapshots and forks have no maintenance guarantee. Once published, report the exact version or commit affected.

## What to include

Describe the affected operation, expected and actual behavior, macOS version and a minimal reproduction with fictitious values. Never send live credentials or a full personal history directory. If credentials were exposed, revoke them with their provider.

## Security boundaries

The app operates locally; it does not invoke a model or run configured hooks/MCP servers. History stores plaintext with restricted filesystem permissions. Visual masking is heuristic, and editable source contains real values. See the README for concurrent-write and symlink limitations. AI-assisted development does not constitute an independent security audit.
