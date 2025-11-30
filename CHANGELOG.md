# Changelog

All notable changes to mcp-bash-framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-11-30

### Added
- Stdio MCP server targeting protocol `2025-06-18` with negotiated downgrades to `2025-03-26` and `2024-11-05`.
- Core surfaces: lifecycle, ping, logging/setLevel, tools (list/call), resources (list/read/subscribe), prompts (list/get), completion, pagination, and `listChanged` notifications.
- Concurrency, cancellation, timeout watchdogs, stdout corruption guards, and JSON-tool detection with minimal-mode fallback.
- Registry system with TTL-based refresh, hash-based change detection, and manual registration hooks.
- Elicitation support (server/client detection, tool helper APIs) and roots integration (server-initiated roots/list with fallbacks).
- Tool SDK with logging/progress helpers, scaffolding commands for tools/resources/prompts, and example projects (hello tool, args/logging/progress/resources/prompts/elicitation/roots, advanced ffmpeg studio).
- Compatibility and integration tests (Inspector harness, integration suites), lint/test scripts, and docs covering architecture, security, limits, performance, and Windows guidance.
