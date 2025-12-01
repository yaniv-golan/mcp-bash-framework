# Changelog

All notable changes to mcp-bash-framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-12-02

### Added
- Automatic getting-started mode when `MCPBASH_PROJECT_ROOT` is unset: stages a temporary bootstrap project with a `getting_started` tool, isolated registry cache, and cleanup traps (including HUP) plus clearer help text.
- Framework-only bootstrap helper content and docs updates (Quick Start and Project Structure) explaining the temporary helper and how to configure real projects.
- Integration coverage for the bootstrap path and stricter CLI guard for invalid project roots.
- Go module for gojq (`tools/go.mod`/`go.sum`) and CI caching: `setup-go` module cache plus `GOCACHE` restored, with gojq installed via the module for reproducible tooling across OSes.
- Tar-based test staging for integration/examples: shared `base.tar` with ACL-safe flags, reused across tests, reducing Windows I/O; integration tests now use the shared staging helper instead of per-test `cp -a`.
- Windows CI guardrails: duration gate now warns at 4m and fails at 15m only on warm caches; Windows path handling fixed for Go caches; minor prompt/resource/tool tests refactored to honor staging.
- Unified server metadata via `server.d/server.meta.json`: supports MCP spec fields `name`, `title`, `version`, `description`, `websiteUrl`, and `icons`. Smart defaults derive `name` from project directory, `title` from titlecase of name, and `version` from `VERSION` file or `package.json`.
- Framework `VERSION` file as single source of truth for version; `mcp-bash --version` and bootstrap helper now read from it.
- Default icon (`assets/icon.svg`) and full metadata for the bootstrap getting-started helper.

## [0.1.0] - 2025-11-30

### Added
- Stdio MCP server targeting protocol `2025-06-18` with negotiated downgrades to `2025-03-26` and `2024-11-05`.
- Core surfaces: lifecycle, ping, logging/setLevel, tools (list/call), resources (list/read/subscribe), prompts (list/get), completion, pagination, and `listChanged` notifications.
- Concurrency, cancellation, timeout watchdogs, stdout corruption guards, and JSON-tool detection with minimal-mode fallback.
- Registry system with TTL-based refresh, hash-based change detection, and manual registration hooks.
- Elicitation support (server/client detection, tool helper APIs) and roots integration (server-initiated roots/list with fallbacks).
- Tool SDK with logging/progress helpers, scaffolding commands for tools/resources/prompts, and example projects (hello tool, args/logging/progress/resources/prompts/elicitation/roots, advanced ffmpeg studio).
- Compatibility and integration tests (Inspector harness, integration suites), lint/test scripts, and docs covering architecture, security, limits, performance, and Windows guidance.
