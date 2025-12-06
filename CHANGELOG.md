# Changelog

All notable changes to mcp-bash-framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2025-12-06

### Added
- SDK helper `mcp_require_path` for consistent path normalization, optional single-root defaulting, and roots enforcement in tools.
- SDK type coercion helpers (`mcp_args_bool`, `mcp_args_int`, `mcp_args_require`) for common argument parsing patterns.
- Shared path normalization helpers (`lib/path.sh`) with consistent fallback chain (realpath -m → realpath → readlink -f → manual collapse) used by SDK/runtime/installer; added unit coverage.
- CLI `run-tool` command for direct tool invocation with optional roots, dry-run, timeout override, and verbose stderr streaming.
- Installer supports `--version`/`--ref` aliases for tagged installs and auto-prefixes bare semver tags with `v`.
- CLI `run-tool --print-env` to inspect wiring without executing tools; help/examples updated.
- `mcp-bash validate` now supports `--json`, `--explain-defaults`, and `--strict`; tool naming validation warns on missing namespace/format/length; outputs include defaults in JSON.
- `mcp-bash config` gains richer `--json` output, pasteable JSON for `--client`, and `--wrapper` generator for auto-install scripts.
- `mcp-bash registry status` subcommand to inspect registry cache (hash/mtime/counts) without refresh.
- `mcp-bash doctor --json` for machine-readable environment/project readiness (absorbs readiness summary).
- Tool policy hook (`server.d/policy.sh` + `mcp_tools_policy_check`) invoked before every tool run; default allows all, enabling read-only/allowlist/audit policies without per-tool code.
- Docs for `run-tool` usage/flags and unit coverage for the CLI wrapper.
- `mcp-bash scaffold test` CLI to generate a minimal test harness (`test/run.sh`, `test/README.md`) wrapping `run-tool`, plus integration coverage.

### Fixed
- Manual tool registry refresh now respects hook exit codes: status 1 falls back to a scan, status 2 surfaces as fatal, and missing manual registry files no longer block refresh.
- Stderr streaming no longer re-executes tools on non-zero exits; if process substitution is unavailable, stderr is buffered once with a single notice.
- Stderr buffering now appends across retries/streams to preserve diagnostic output when streaming is unavailable.
- `mcp-bash doctor --json` escapes values before emitting JSON, avoiding malformed output when paths contain quotes or spaces.
- `mcp-bash config --json` escapes server names/paths, preventing invalid snippets for clients.
- `mcp-bash run-tool --no-refresh/--args` now fails fast with a clear error when JSON tooling is unavailable instead of dying later.

### Changed
- CLI commands (`init`, `validate`, `config`, `doctor`, `run-tool`, `registry refresh`, `scaffold`) moved into `lib/cli/*.sh` with a thin dispatcher in `bin/mcp-bash`; shared helpers live in `lib/cli/common.sh`. Behavior unchanged, startup parse overhead slightly reduced.

## [0.3.0] - 2025-12-05

### Added
- CLI project tooling for standalone servers:
  - `mcp-bash init [--name NAME] [--no-hello]` initializes a project in the current directory with `server.d/server.meta.json`, a `tools/` directory, a `.gitignore`, and a working `hello` tool by default.
  - `mcp-bash scaffold server <name>` creates a new project directory with the same structure and example tool, wired to the existing scaffold templates.
  - `mcp-bash validate [--project-root DIR] [--fix]` validates server metadata and all tools/prompts/resources (JSON shape, required fields, script presence, executability, basic schema checks) and can auto-fix missing executable bits.
  - `mcp-bash config [--project-root DIR] [--show|--json|--client NAME]` emits ready-to-paste MCP client configuration snippets (Claude Desktop/CLI, Cursor, Windsurf, LibreChat) and a machine-readable JSON descriptor including `MCPBASH_PROJECT_ROOT`.
  - `mcp-bash doctor` performs environment diagnostics (framework location/version, PATH wiring, jq/gojq availability, basic project metadata, shellcheck/npx presence).
- One-line installer script `install.sh`:
  - Clones the framework into a safe, dedicated install directory, configures shell PATH for common shells, verifies `mcp-bash --version`, and warns when jq/gojq is missing.
  - Supports `--dir`, `--branch`, and `--yes` flags for CI and advanced setups.
- New SDK JSON helpers in `sdk/tool-sdk.sh`:
  - `mcp_json_escape` for quoting strings as JSON string literals.
  - `mcp_json_obj` / `mcp_json_arr` for building simple string-keyed objects and string-only arrays, using gojq/jq when available with a safe fallback when not.
- Test coverage for the new behavior:
  - Unit tests for the SDK JSON helpers.
  - Integration tests for the new CLI commands (`init`, `validate`, `config`, `doctor`) and their happy-path behavior across platforms.

### Changed
- Project root handling:
  - Runtime now auto-detects `MCPBASH_PROJECT_ROOT` by walking up from the current directory to find `server.d/server.meta.json`, explicitly skipping framework-internal paths (bootstrap, examples, scaffold).
  - CLI commands that require a project (`scaffold tool/prompt/resource`, `validate`, `config`, `registry refresh`) now work out of the box inside a project directory without exporting `MCPBASH_PROJECT_ROOT`, while still honoring an explicit env var or `--project-root` when provided.
- Tool and example boilerplate:
  - Scaffolded tools and all shipped examples now use a minimal, canonical pattern: `source "${MCP_SDK:?...}/tool-sdk.sh"`, `mcp_args_get` for input, and the new `mcp_json_*` helpers for structured output, instead of in-repo `../../sdk` fallbacks and ad-hoc JSON builders.
  - `scaffold/tool/README.md` and example READMEs point to the new pattern and SDK helpers as the recommended starting point for standalone servers.
- Documentation and metadata:
  - `README.md` Quick Start updated to favor the installer, `mcp-bash init`, auto-detected project roots, `mcp-bash config`, and `mcp-bash doctor` as the primary workflow for third-party servers.
  - `docs/PROJECT-STRUCTURE.md` updated to reflect `init`/`scaffold server`, the presence of `server.d/server.meta.json` in minimal projects, and the simplified SDK discovery model.
  - `scaffold/server/server.meta.json` simplified to match the defaults produced by `mcp-bash init`/`mcp-bash scaffold server`, leaving optional fields like `websiteUrl`/`icons` for authors to add explicitly.
- Tool discovery now ignores root-level scripts under `tools/`; automatic discovery requires each tool to live in a subdirectory (for example `tools/hello/tool.sh` with `tools/hello/tool.meta.json`). This is a breaking change for projects that relied on flat layouts like `tools/foo.sh`.
- All bundled examples and stress/integration tests have been updated to use the per-tool directory layout, matching the scaffolder output (`mcp-bash scaffold tool <name>`).
- Documentation (README, best practices, registry contracts, LLM guide) no longer advertises flat layouts as supported; the canonical layout is `tools/<name>/tool.sh` + `tools/<name>/tool.meta.json`.

## [0.2.1] - 2025-12-03

### Changed
- Hardened HTTPS provider: blocks private/loopback hosts, optional host allow/deny via `MCPBASH_HTTPS_ALLOW_HOSTS` / `MCPBASH_HTTPS_DENY_HOSTS`, disables redirects/protocol downgrades, and caps timeouts/size (timeout ≤60s, max bytes ≤20MB).
- Hardened git provider: disabled by default (`MCPBASH_ENABLE_GIT_PROVIDER=true` to enable), host allow/deny lists added, private/loopback blocked, shallow clones enforced, timeout bounded (default 30s, max 60s), and repository size capped via `MCPBASH_GIT_MAX_KB` (default 50MB, max 1GB).
- Introduced shared host policy helper (`lib/policy.sh`) for consistent allow/deny handling across providers.
- Tightened state/lock/registry permissions with `umask 077`; debug mode now uses a randomized 0700 directory.
- File provider now rejects symlinks and rechecks before read to reduce TOCTOU/symlink escape risk.
- Scaffold commands validate names to prevent path traversal.
 - Added `llms.txt` and `llms-full.txt` for LLM-specific repository guidance and compressed, agent-optimized reference content.

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
