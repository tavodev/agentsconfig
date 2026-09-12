# Contributing

AgentsConfig is an experimental native macOS application. Changes must protect users' configuration files and credentials.

## Getting started

Use macOS 15+, Xcode 26.1.1 and XcodeGen 2.45.4. Follow the build and test commands in [README.md](README.md). Architecture and safety invariants are in [AGENTS.md](AGENTS.md).

Discuss substantial changes in an issue before implementation. Keep pull requests focused, explain the user-visible behavior, and include relevant verification. Use English for code, documentation and pull requests; preserve both English and Spanish UI translations. Commit messages use a gitmoji and an English summary, with a detailed body where useful.

## Safe development

- Never use personal agent configurations as test fixtures. Use `TestEnvironment` or `scripts/run-demo.py`.
- Never execute fixture MCP servers, commands or hooks.
- Do not include credentials, personal configuration, real history or identifying screenshots in issues, logs or PRs.
- Preserve reviewed saves/restores, conflict checks, private file permissions and redacted diffs.
- Run the hostless tests for behavior changes and the multiprocess probe for storage changes. Run UI tests only in an unlocked graphical session with the isolated host. Compilation alone is not a UI pass.
- Regenerate the Xcode project when adding or removing source files. Commit the generated project and locked package resolution together.

## AI-assisted contributions

AI-assisted contributions are welcome. The contributor remains responsible for understanding and reviewing every submitted change, verifying claims, running appropriate tests and checking the origin and licensing of contributed material. Mention substantial AI assistance in the PR; tool names are optional and private transcripts are not required. Do not submit secrets or private user configurations to a model. Generated tests, documentation and security claims need the same review as code. Do not invent test results or provenance.

## Review and conduct

Be respectful, discuss the work rather than the person, and provide reproducible examples. Maintainers may close abusive, spam or unreviewed bulk-generated submissions. Report vulnerabilities privately through [SECURITY.md](SECURITY.md).
