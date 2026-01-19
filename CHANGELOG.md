# Changelog

All notable changes to mcp-bash-framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.11.0] - 2026-01-19

### Added
- **`--array-path` parameter for `mcp_json_truncate`**: New optional parameter to specify which array to truncate in JSON responses. Allows tool authors to declare their data structure (e.g., `--array-path ".data"`, `--array-path ".hits.items"`) instead of relying on hardcoded heuristics. Returns structured errors (`path_not_found`, `invalid_array_path`, `invalid_path_syntax`) for invalid paths. Path syntax is validated before jq interpolation for security. Backward compatible: without `--array-path`, falls back to top-level arrays and `.results` heuristic. See BEST-PRACTICES.md "Truncating large results" section.

## [0.10.0] - 2026-01-18

### Added
- **`mcp_config_load` / `mcp_config_get` SDK helpers**: Unified configuration loading with standard precedence (env var → file → example → defaults). `mcp_config_load` accepts `--env`, `--file`, `--example`, and `--defaults` flags; performs shallow merge with jq (last-source-wins without jq). `mcp_config_get` extracts values by jq path with optional `--default`. Supports minimal mode (top-level keys only without jq). See BEST-PRACTICES.md "Configuration loading" section.
- **`user_config` bundle support**: Bundles can now declare user-configurable options via `MCPB_USER_CONFIG_FILE`, `MCPB_USER_CONFIG_ENV_MAP`, and `MCPB_USER_CONFIG_ARGS_MAP` in `mcpb.conf`, or via `user_config`, `user_config_env_map`, and `user_config_args_map` in `server.d/server.meta.json`. User config fields are validated for schema correctness (type, title required; type-specific properties like `sensitive`, `min`/`max`, `multiple`). Env and args mappings are validated to reference existing config keys. Generated manifests include `user_config` section and proper `${user_config.KEY}` variable substitution in `mcp_config.env` and `mcp_config.args`. See docs/MCPB.md "User Configuration" section.
- **Additional MCPB manifest fields**: Bundle manifests now support optional metadata fields for registry/marketplace listing: `MCPB_LICENSE` (SPDX identifier), `MCPB_KEYWORDS` (space-separated), `MCPB_HOMEPAGE`, `MCPB_DOCUMENTATION`, `MCPB_SUPPORT`, `MCPB_PRIVACY_POLICIES` (space-separated URLs). Also added compatibility constraints: `MCPB_COMPAT_CLAUDE_DESKTOP` (semver), `MCPB_RUNTIME_PYTHON`, `MCPB_RUNTIME_NODE`. All fields are optional and omitted from manifest when not set.
- **`mcp_error` SDK helper**: Convenience wrapper for tool execution errors with consistent schema. Takes `<type> <message>` with optional `--hint` and `--data` flags. Builds normalized error JSON and delegates to `mcp_result_error`. Logs at debug level for all errors; logs at warn level when hint provided. See BEST-PRACTICES.md "Convenience error helper" section and ERRORS.md "SDK Support" section.
- **`mcp_download_safe` SDK helper**: New function for SSRF-safe HTTPS downloads in tools. Wraps the HTTPS provider with ergonomic API: named flags (`--url`, `--out`, `--allow`), automatic retries with exponential backoff, structured JSON responses (`{"success":true,"bytes":N,"path":"..."}` or `{"success":false,"error":{...}}`), and `set -e` safe (always returns 0). See BEST-PRACTICES.md "Secure downloads" section.
- **`mcp_download_safe_or_fail` SDK helper**: Fail-fast wrapper for `mcp_download_safe` that returns the output path on success or fails the tool with `-32602` on error. Simplifies common "download or die" pattern: `path=$(mcp_download_safe_or_fail --url "$url" --out "$tmp" --allow "example.com")`.
- **`mcp_result_text_with_resource` SDK helper**: Convenience wrapper for tool responses with embedded resources. Combines `mcp_result_success` with resource embedding via `--path`, `--mime`, `--uri` flags. Supports multiple resources. MIME type auto-detected if omitted (requires `file` command). See BEST-PRACTICES.md "Embedding resources in tool responses" section.
- **Redirect detection in HTTPS provider**: URLs that return 3xx redirects now produce a `redirect` error type with the target location in `.error.location`. This helps users identify canonical URLs without silently failing. Redirects are not retried (deterministic behavior).
- **`MCPBASH_HTTPS_USER_AGENT` env var**: Custom User-Agent for HTTPS provider requests. The `mcp_download_safe` SDK helper sets `mcpbash/<version> (tool-sdk)` by default; override via `--user-agent` flag or this env var.

### Fixed
- **Tool arguments corrupted when containing escaped quotes**: Fixed a bug where tool arguments containing escaped quotes (e.g., `Status in ["New", "Intro"]`) would fail to parse with "Command is required" errors. The root cause was jq's `@tsv` filter double-escaping backslashes, turning valid `\"` into invalid `\\"`. Replaced single `@tsv` extraction with separate jq calls. Added JSON validation before tool execution to catch corruption early with clear error messages. See `docs/internal/PLAN-silent-args-parsing-failures.md` for full analysis. 
- **gojq compatibility in debug redaction**: Replaced `keys_unsorted` with `keys` in `mcp_io_debug_redact_payload()`. The `keys_unsorted` function is jq-specific and not available in gojq, causing debug redaction to fail silently when gojq was the JSON tool.
- **Incomplete JSON escaping in minimal mode**: `mcp_json_escape_string()` fallback (used when jq/gojq unavailable) now properly escapes all control characters including `\b` (backspace), `\f` (form feed), and other 0x00-0x1F characters via `\u00XX` encoding. Previously only escaped `\n`, `\r`, `\t`, `\\`, and `\"`, which could produce invalid JSON.
- **Potential secret leakage in debug payload redaction**: When jq is unavailable, `mcp_io_debug_redact_payload()` now emits a secure fingerprint (`[payload hash=... bytes=...]`) instead of attempting fragile regex-based redaction. The previous sed fallback could leak partial secrets when values contained escaped quotes (e.g., `"pass\"word"`). Follows fail-closed security: if we can't redact correctly, we redact everything.
- **Log injection in resources debug log**: Resource names and URIs are now sanitized before writing to `resources.debug.log`, escaping newlines and carriage returns to prevent injection of fake log entries via malicious resource names.

### Documentation
- **Minimal mode limitations**: Documented known limitations in `docs/MINIMAL-MODE.md` including unicode escape sequences (`\uXXXX`) not being decoded (passed through as literals) and debug payload logging emitting fingerprints instead of full content.
- **MCPB code signing**: Added optional code signing workflow to `docs/MCPB.md` using the official MCPB CLI (`@anthropic-ai/mcpb`) for production distribution. Documents `mcpb sign`, `mcpb verify`, and related commands.

## [0.9.13] - 2026-01-13

### Added
- **Bundle libs sync test**: New CI test (`test/unit/bundle_libs_sync.bats`) that verifies `BUNDLE_REQUIRED_LIBS` includes all libraries sourced by `bin/mcp-bash`. Prevents broken releases with missing bundled libraries (e.g., 0.9.9, 0.9.10).

### Fixed
- **errexit (set -e) state leak in functions**: Fixed a bug where `mcp_with_retry` and several internal functions would modify the caller's errexit shell state. Functions using `set +e; cmd; rc=$?; set -e` patterns would leave errexit enabled even if the caller had it disabled, causing unexpected script termination. Replaced with errexit-safe `cmd && rc=0 || rc=$?` pattern. Affected functions: `mcp_with_retry` (SDK), `mcp_tools_validate_output_schema`, `mcp_tools_call`, `mcp_registry_register_execute`, `mcp_cli_health`.

## [0.9.12] - 2026-01-13

### Added
- **`mcp_extract_cli_error` SDK helper**: New function to extract error messages from CLI tools that output structured JSON errors to stdout (common with `--json` flags) instead of stderr. Checks common patterns (`.error.message`, `.error` string, `.message` with status flags, `.errors[0].message`) before falling back to stderr. Improves LLM self-correction by providing meaningful error messages instead of empty strings. See BEST-PRACTICES.md §4.4 "Handling CLIs with structured JSON errors".

### Fixed
- **Incorrect JSON-RPC error code for tool errors**: Changed "Tool path unavailable" and "Tool executable missing" errors from `-32601` (Method not found) to `-32602` (Invalid params) per JSON-RPC 2.0 and MCP specifications. The `-32601` code is reserved for when the RPC method itself doesn't exist; tool-related errors are parameter validation failures and should use `-32602`. This aligns with the existing "Tool not found" error which correctly uses `-32602`.

## [0.9.11] - 2026-01-12

### Added
- **`--stderr-file` option for `mcp_run_with_progress`**: New option to capture non-progress stderr lines to a file while still forwarding progress notifications to MCP. Enables MCP tools to report detailed CLI error messages when using progress forwarding. See BEST-PRACTICES.md §4.9 "Capturing non-progress stderr".

### Documentation
- **SECURITY.md**: Added production deployment checklist, critical `policy.sh` security warning, known security limitations section (rate limiting, TOCTOU, input validation, debug logging, env inheritance), and gateway requirements for remote access.

## [0.9.10] - 2026-01-08

### Fixed
- **Bundle missing progress-passthrough.sh**: Added `progress-passthrough` to `BUNDLE_REQUIRED_LIBS` in bundle.sh. This library is sourced by `sdk/tool-sdk.sh` for `mcp_run_with_progress` functionality and was missing from bundles.

## [0.9.9] - 2026-01-08

### Fixed
- **Bundle missing handler_helpers.sh**: Added `handler_helpers` to `BUNDLE_REQUIRED_LIBS` in bundle.sh. This library is sourced by `core.sh` and was missing from bundles, causing runtime failures.

## [0.9.8] - 2026-01-08

### Changed
- **CI/CD improvements**: Bundle validation is now part of release gates via new `bundle-sanity` job that validates `mcp-bash bundle --help` and `mcp-bash bundle --validate` on every push. Prevents broken bundle functionality from reaching releases when non-bundle-path changes break bundle code. Full bundle creation tests remain in separate `bundle.yml` workflow for thorough path-triggered testing.
- **Consistent Windows CI policy**: `bundle.yml` now uses `continue-on-error` for Windows matrix jobs, matching the main CI workflow policy. Windows failures are reported but don't block the workflow.
- **CI workflow cleanup**: Removed unreachable Windows-specific code from Ubuntu-only jobs (`lint`, `unit`, `stress`). These jobs never run on Windows, so the conditional Windows path setup was dead code.

### Fixed
- **Bundle corrupted resources.json for parameterized resources**: `mcp_resources_scan()` now correctly skips resources with `uriTemplate` field. Previously, resources defining a `uriTemplate` (for parameterized access like `file:///{path}`) would get incorrectly added to `resources.json` with a fabricated `file://` URI based on the meta.json path, corrupting the registry. These resources now only appear in `resource-templates.json` as intended per MCP spec.

## [0.9.7] - 2026-01-08

### Changed
- **Internal refactoring**: Minor internal improvements and bug fixes from v0.9.6.

## [0.9.6] - 2026-01-08

### Added
- **`mcp_require` helper**: New function for conditional library sourcing with duplicate-load prevention. Simplifies optional dependency loading in tools and SDK code. See `lib/require.sh`.

### Changed
- **Release workflow**: Release job now runs as part of CI workflow with `needs:` dependency on core test jobs. Releases are created after lint, unit, integration (Ubuntu + macOS), and compatibility tests pass. Windows integration tests run in parallel but do not block releases (failures are reported as warnings with artifacts). Previously, all three OS integration tests were required, causing Windows slowness to delay releases.
- **Internal refactoring**: Consolidated error response formatting in handlers and standardized error variable naming to `_ERROR_CODE`/`_ERROR_MESSAGE` for consistency across the codebase.

### Fixed
- **Malformed JSON in notifications/message**: Fixed edge case where `mcp_logging_emit()` could emit malformed JSON (`"logger":,"data":}`) when the internal quote function failed silently. Added defensive validation to ensure quoted strings are never empty.
- **Validator missing uriTemplate support**: `mcp-bash validate` now accepts `uriTemplate` as a valid alternative to `uri` for resource templates, per MCP spec. Previously, resources with only `uriTemplate` (no `uri`) failed validation with "missing required uri". The validator now:
  - Accepts either `uri` OR `uriTemplate` (not both required)
  - Warns when both are present (mutually exclusive per spec)
  - Validates that `uriTemplate` contains `{variable}` placeholders

## [0.9.5] - 2025-01-08

### Added
- **Debug file detection**: Create `server.d/.debug` to enable `MCPBASH_LOG_LEVEL=debug` persistently per-project. Eliminates boilerplate debug detection in `server.d/env.sh`. Environment variable takes precedence if set. See [DEBUGGING.md](docs/DEBUGGING.md#debug-file-persistent-debug-mode).
- **Progress-aware timeout extension**: Long-running tools that emit progress can now extend their timeout dynamically instead of being killed after a fixed duration. Opt-in via `MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true` (global) or `"progressExtendsTimeout": true` in `tool.meta.json` (per-tool). The watchdog resets its idle timer on each progress emission, with a hard cap via `MCPBASH_MAX_TIMEOUT_SECS` (default 600s) to prevent runaway processes. Three timeout variants are now distinguished in error messages: fixed timeout, idle timeout (no progress for N seconds), and max exceeded (hard cap reached). When a tool emits progress but times out with the feature disabled, a warning is logged suggesting enablement. See [BEST-PRACTICES.md](docs/BEST-PRACTICES.md) §4.3 and [ENV_REFERENCE.md](docs/ENV_REFERENCE.md).
- **Debug EXIT trap**: New `MCPBASH_DEBUG=true` enables an EXIT trap that logs exit location and call stack on non-zero exits, helping diagnose `set -e` failures. Use `MCPBASH_DEBUG_ALL_EXITS=true` to log all exits (not just failures). Installed automatically in `lib/timeout.sh` when sourced.
- **Integration test debug mode**: New `MCPBASH_INTEGRATION_DEBUG_FAILED=true` re-runs failed integration tests with `bash -x` tracing and outputs the last 50 lines of trace for easier debugging.
- **Custom lint check**: `test/lint.sh` now warns about the dangerous `local var; var=$(cmd)` pattern that causes `set -e` to exit on command failure. The safe pattern is `local var=$(cmd)` which masks the exit code via the `local` builtin.

### Changed

### Fixed
- **set -e exit in with_timeout**: Fixed a bug where `with_timeout` would exit prematurely when grep found no timeout marker in the watchdog state file. The pattern `local var; var=$(grep ...)` causes `set -e` to exit on grep's non-zero return code (no match). Fixed by combining declaration and assignment (`local var=$(grep ...)`), which masks the exit code via the `local` builtin.

## [0.9.4] - 2026-01-07

### Added
- **Static registry mode** (`MCPBASH_STATIC_REGISTRY=1`): Opt-in mode for bundle deployments that skips runtime discovery and uses pre-generated `.registry/*.json` cache files directly. Reduces cold start time by skipping TTL checks, fastpath detection, and directory scanning. When enabled:
  - Loads pre-generated cache immediately without freshness checks
  - Skips `register.sh` execution (shell code) but still honors `register.json` (data-only declarative overrides)
  - Falls back to normal discovery if cache is missing/invalid
  - Respects CLI forced refresh (`mcp-bash registry refresh` still works)
  - Logs info message on first request to alert developers if static mode is accidentally left enabled
  - Cache format versioning (`format_version: 1`) for future compatibility
- **MCPB_STATIC bundle config**: Bundles now use static registry mode by default for zero-config fast cold start. The bundler automatically:
  - Runs `registry refresh` to pre-generate `.registry/*.json` files
  - Adds `.registry` to `MCPB_INCLUDE` if not present
  - Sets `MCPBASH_STATIC_REGISTRY=1` in bundle manifest environment
  - To opt out, set `MCPB_STATIC=false` in `mcpb.conf` (accepts `false`, `0`, `no`, `off`)
- **LLM context documentation**: New `docs/LLM-CONTEXT.md` guide covering patterns for building MCP servers that LLM agents can use effectively. Includes writing effective tool descriptions, parameter documentation, including examples in metadata, documenting tool relationships, creating domain model resources, discovery tool patterns, client compatibility workarounds for custom URI schemes, and anti-patterns to avoid. Includes documentation quality checklist.
- **BEST-PRACTICES.md §4.2 "LLM-friendly tool metadata"**: Quick reference for rich descriptions, parameter docs, and domain resources with cross-reference to full LLM-CONTEXT.md guide.
- **docs/README.md**: Added LLM context patterns entry to documentation index.

### Changed
- **Scaffold template improvements**: `scaffold/tool/tool.meta.json` now generates description placeholders with "When to use", "Not for", and "Examples" sections to encourage LLM-friendly documentation from the start. Parameter descriptions include format examples.
- **BEST-PRACTICES.md section renumbering**: Sections §4.3-§4.9 renumbered to accommodate new §4.2.

### Fixed
- **Tool error code propagation**: Fixed bug where early-exit tool errors (e.g., "tool not found", "path unavailable") returned generic `-32603 "Tool execution failed"` instead of specific error codes (`-32602`, `-32601`). The `mcp_tools_error()` function now properly sets `_MCP_TOOLS_RESULT` so handlers receive the specific error code and message. Policy hook errors now surface correctly with their original error codes and data payloads.
- **`mcp_result_success` default max_text_bytes increased to 100KB**: Changed default from 4096 to 102400 bytes. The previous 4KB limit caused LLMs to see unhelpful summaries like "Success: object with 3 keys" instead of actual data when tools returned moderately-sized JSON. New default ensures typical LLM responses are included in full. Configurable via `MCPBASH_MAX_TEXT_BYTES` environment variable for edge cases (e.g., constrained environments or explicit summarization).
- **Multi-line descriptions in resource metadata**: Fixed `lib/resources.sh` registry parsing to handle multi-line descriptions in `resource.meta.json`. Previously, descriptions with embedded newlines would break the field array parsing, causing resources to silently fall back to default names and empty descriptions. Now uses individual jq calls per field (matching the pattern already used in `lib/tools.sh`).
- **Registry cache loading not setting LAST_SCAN**: Fixed `lib/tools.sh`, `lib/resources.sh`, and `lib/prompts.sh` to set `*_LAST_SCAN` to current time after successfully loading registry cache from disk. Previously, loading a valid cache file would leave `*_LAST_SCAN` uninitialized, causing the TTL check to always fail and trigger unnecessary full directory scans on the first request. This caused timeouts in Claude Desktop when `tools/list` took too long. The fix trusts pre-generated caches and starts the TTL window from now (not file mtime, which would fail for freshly extracted bundles). Uses empty string as the "uninitialized" state to distinguish from explicit `LAST_SCAN=0` (used by CLI commands to force a scan).

## [0.9.3] - 2025-01-06

### Added
- **`mcp_run_with_progress` SDK helper**: Forward subprocess progress to MCP notifications. Wraps external CLIs and parses their stderr (or a dedicated progress file) to emit progress events. Supports three extraction modes: `json` (NDJSON output), `match1` (percentage patterns like `50%`), and `ratio` (counter patterns like `[5/10]`). Includes `--progress-file` option for ffmpeg-style CLIs that write progress to dedicated files. See BEST-PRACTICES.md §4.8 for common patterns and usage examples.
- **MCPB_INCLUDE config option**: New `mcpb.conf` setting to include custom directories in bundles beyond the defaults (tools, resources, prompts, completions, server.d, lib, providers). Supports nested paths like `config/schemas`. Rejects path traversal (`..`) and absolute paths for security. Warns on missing directories.
- **run-tool environment sourcing**: New options for sourcing environment files before tool execution:
  - `--with-server-env`: Sources `server.d/env.sh` before running the tool, matching server runtime behavior
  - `--source FILE`: Sources any env file before execution (repeatable; sourced after `--with-server-env`)
  - `MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV=1`: Environment variable to implicitly enable `--with-server-env` for all invocations
  - `--print-env` now shows `WILL_SOURCE_SERVER_ENV` and `WILL_SOURCE[N]` for debugging without execution
- **Debug enhancements**:
  - `MCPBASH_FRAMEWORK_VERSION`: New read-only env var exposing framework version (from `${MCPBASH_HOME}/VERSION`) at startup. Useful for consuming projects to log version banners without file reads.
  - Client identity logging: When `MCPBASH_LOG_LEVEL=debug`, the server now logs connecting client's name/version at initialize (e.g., `Client: claude-ai/0.1.0 pid=12345`). Helps identify which mcp-bash process serves which client when multiple instances run.

### Changed

### Fixed


## [0.9.2] - 2026-01-05

### Added
- **CallToolResult response helpers**: New SDK functions for building MCP CallToolResult responses with consistent `{success, result}` envelope patterns:
  - `mcp_result_success` - Emit success CallToolResult with `structuredContent.success=true` and `isError=false`
  - `mcp_result_error` - Emit error CallToolResult with `structuredContent.success=false` and `isError=true`
  - `mcp_json_truncate` - Binary-search truncation for large JSON arrays with metadata (`truncated`, `kept`, `total`)
  - `mcp_is_valid_json` - Validate single JSON value (handles `false`/`null` correctly via slurp mode)
  - `mcp_byte_length` - UTF-8 safe byte length measurement
- Documentation: Added BEST-PRACTICES.md §4.7 "Building CallToolResult responses" with examples and comparison table. Added "Capturing stdout and stderr separately" pattern to §4.3 for CLI wrapper tools.
- Tests: Unit tests (`test/unit/sdk_result_helpers.bats`) and integration tests (`test/integration/test_result_helpers.sh`) for all new helpers.

### Changed
- **Test framework modernization**: Unit tests now use proper bats-core syntax with `@test` functions (219 tests across 40 files). Migrated from custom test runner to direct bats invocation with parallel execution support (`--jobs N` when GNU parallel available). Bats helper libraries (bats-support, bats-assert, bats-file) installed via npm instead of vendored. CI now outputs JUnit XML for test result visualization.
- **Examples updated to best practices**: All examples now use `mcp_result_success` / `mcp_result_error` helpers instead of legacy `mcp_emit_json` patterns, with corresponding `outputSchema` updates using the `{success, result}` envelope.
- **Scaffold templates updated**: Tool scaffolds (`scaffold/tool/`, `mcpbash init` inline template) now generate code using `mcp_result_success` with proper `outputSchema` envelope pattern.
- **Documentation examples updated**: ERRORS.md and BEST-PRACTICES.md code examples now demonstrate the recommended `mcp_result_success` / `mcp_result_error` patterns.
- **ffmpeg-studio examples**: Added stderr capture for better error reporting in `extract` and `inspect` tools.

### Fixed
- **CallToolResult passthrough**: Framework now detects when tools emit pre-formatted CallToolResult JSON (from `mcp_result_success` / `mcp_result_error`) and uses it directly instead of wrapping it again. The `outputSchema` validation now correctly validates `structuredContent` from CallToolResult outputs.

## [0.9.1] - 2026-01-03

### Added
- Installer now uses exit code 3 for policy refusal (user declined prompt or `MCPBASH_HOME` is set), allowing CI/CD scripts to distinguish "user/policy declined" from actual failures (exit 1).
- Installer help text now documents exit codes (0=success, 1=error, 2=invalid args, 3=policy refusal).
- README now includes installer exit codes table and CI/CD installation patterns (tarball+SHA256 and git+SHA verification).

### Fixed
- Installer color escape codes now render correctly (use `$'\033[...]'` syntax instead of single-quoted literals).
- Installer now prompts interactively via `/dev/tty` when run via `curl | bash`, instead of auto-confirming overwrites.
- Installer messaging clarifies when auto-confirm is due to `--yes` flag vs no TTY available.
- Installer verification error messages now include filename, expected/actual SHA values, and guidance on possible causes (corrupted download, MITM attack, version mismatch).

## [0.9.0] - 2026-01-03

### Added
- **MCPB bundle support**: `mcp-bash bundle` creates distributable `.mcpb` packages for one-click installation in MCPB-compatible clients (e.g., Claude Desktop). Bundles include the embedded framework, tools, resources, prompts, and a generated manifest following MCPB specification v0.3.
- **`mcp_with_retry` SDK helper**: Retry commands with exponential backoff + jitter for transient failures. Exit codes 0-2 are not retried (permanent); 3+ trigger retry. Example: `mcp_with_retry 3 1.0 -- curl -sf "$url"`.
- **Health checks hook**: Optional `server.d/health-checks.sh` verifies external dependencies (CLIs, env vars) before serving. Helpers `mcp_health_check_command` and `mcp_health_check_env` report results to `mcp-bash health` output as `projectChecks: ok|failed`.
- Optional `mcpb.conf` configuration file for customizing bundle metadata (name, version, author, repository). Values fall back to `server.d/server.meta.json`, `VERSION` file, and git config.
- Automatic icon inclusion: `icon.png` or `icon.svg` in project root is bundled for client UI display.
- **Platform-specific builds**: `mcp-bash bundle --platform darwin|linux|win32|all` creates bundles targeting specific platforms.
- **gojq bundling**: `mcp-bash bundle --include-gojq` embeds gojq binary for systems without jq installed.
- **Registry publishing**: `mcp-bash publish` command submits bundles to the MCP Registry with validation, dry-run support, and API token authentication.
- New documentation: `docs/MCPB.md` covers bundle creation, configuration, structure, publishing, and troubleshooting.
- GitHub Actions workflow `.github/workflows/bundle.yml` for CI testing of bundle creation across platforms.
- Example Makefile with `make bundle` target in `examples/00-hello-tool/`.
- Unit tests for `bundle` and `publish` commands.
- Pre-commit hook for automatic README.md rendering from template.

### Changed
- Renamed default icon from `assets/icon.svg` to `assets/mcp-bash-framework-icon.svg` for clarity.
- `mcp-bash new` now includes `mcp-bash bundle` in the "Next steps" output.

### Fixed
- Project root detection now recognizes valid projects under `MCPBASH_HOME` (e.g., `examples/`) by checking for `server.d/server.meta.json` before skipping framework-internal paths.
- Unknown CLI commands now display an error message instead of silently entering server mode.
- `registry status` and `registry refresh` subcommands now exit properly instead of falling through to "Unknown command" error.
- MCPB bundles now include `lib/` and `providers/` directories when present in the project.

### Documentation
- Added "Calling external CLI tools" section to BEST-PRACTICES.md with safe jq pipeline patterns, fallback defaults table, and error preservation patterns.
- Added "Retry with exponential backoff", "Parallel external calls", and "Rate limiting external APIs" patterns to BEST-PRACTICES.md.
- Added "External dependency health checks" section documenting the `server.d/health-checks.sh` hook.
- Added jq parse error troubleshooting entry to ERRORS.md with cross-reference to BEST-PRACTICES.md.
- Added server hooks table to PROJECT-STRUCTURE.md documenting all `server.d/` hook files.

## [0.8.4] - 2026-01-01

### Added
- **Project-level resource providers**: Projects can now define custom resource providers in `${MCPBASH_PROJECT_ROOT}/providers/`. Project providers are checked before framework providers, enabling custom URI schemes (e.g., `xaffinity://`, `myapi://`) without modifying the framework installation. See `docs/REGISTRY.md` for details.
- New environment variable `MCPBASH_PROVIDERS_DIR` for overriding the providers directory location.

### Fixed
- Shell profile sourcing now loads all relevant profiles (`.zprofile`, `.zshrc`, `.bash_profile`, `.profile`, `.bashrc`) instead of only the first one found. Ensures version managers like pyenv, nvm, and rbenv are properly available when MCP servers are launched from GUI applications like Claude Desktop.
- `config --wrapper` and `--wrapper-env` now work on macOS system bash (3.2) by avoiding heredocs inside command substitutions.

## [0.8.3] - 2025-12-26

### Added
- `mcp-bash validate` now validates icons format per MCP spec: icons must be objects with `src` property, not plain strings. Catches the common "expected object, received string" error that causes strict MCP clients (Cursor, Claude Desktop, MCP Inspector) to reject servers.
- `mcp-bash validate --inspector` flag prints the command to run MCP Inspector CLI for strict schema validation.

### Documentation
- Added "Common Schema Errors" section to DEBUGGING.md documenting icons format errors and strict client validation failures.
- Added troubleshooting flowchart to DEBUGGING.md for diagnosing "works from CLI but fails in clients" issues.

## [0.8.2] - 2025-12-23

### Added
- Tools now receive a per-invocation debug log path via `MCPBASH_DEBUG_LOG`; the SDK exposes `mcp_debug` to write to it.
- Output schema validation errors can include diagnostic metadata when `MCPBASH_DEBUG_ERRORS=true`.

### Fixed
- Tool tracing on bash 3.2 now reconstructs trace logs from stderr to avoid empty trace files on macOS runners.

### Documentation
- Documented the new debug log channel and opt-in error diagnostics.

## [0.8.1] - 2025-12-20

### Added
- `mcp-bash doctor`: added `--dry-run` (propose actions) and `--fix` (managed-install-only repairs), plus `--min-version`/`--archive`/`--verify`/`--ref` upgrade inputs, a concurrency lock, and JSON contract fields `schemaVersion`, `exitCode`, `findings`, `proposedActions`, and `actionsTaken`.
- Installer now writes `INSTALLER.json` into managed installs so `doctor --fix` can reliably distinguish managed vs user-managed installs.

### Fixed
- Windows/Git Bash: registry builds no longer pass large item payloads via `--argjson`, avoiding `E2BIG`/`Argument list too long` failures when icons are inlined.

### Documentation
- Clarified resource template discoverability: templates are listed via `resources/templates/list` and are not advertised via a dedicated capabilities flag; clients should probe the method (treat `-32601` as unsupported).

## [0.8.0] - 2025-12-16

### Added

### Changed
- Tool environment isolation no longer spawns external `env`; uses bash built-ins (`compgen -e`, `unset`) to avoid `E2BIG`/`Argument list too long` failures on Windows/Git Bash with large environments.
- **BREAKING**: Completion/resource providers now run under a curated environment by default (`MCPBASH_PROVIDER_ENV_MODE=isolate`) to reduce `E2BIG` risk; opt into inheritance with `MCPBASH_PROVIDER_ENV_MODE=inherit` + `MCPBASH_PROVIDER_ENV_INHERIT_ALLOW=true` or selectively pass variables via `MCPBASH_PROVIDER_ENV_MODE=allowlist`.
- **BREAKING**: `completion/complete` requests are now **spec-shape only** (MCP `2025-11-25`: `params.ref` + `params.argument`). The legacy `params.name`/`params.arguments` shape is no longer accepted.
- **BREAKING**: Prompt templating only substitutes `{{var}}` placeholders from `prompts/get` arguments; other placeholder syntaxes are treated as literal text.
- CI: Windows integration runs default to non-verbose output and use a PR allowlist to reduce runtime; scheduled runs keep the full suite with per-test timeouts and better log preservation on cancellation.
- When `MCPBASH_PRESERVE_STATE=true`, per-request worker stderr logs (`stderr.*.log`) are preserved for debugging.
- Dev: Unit test runner supports filtering and enforces per-test timeouts (`MCPBASH_UNIT_TEST_TIMEOUT_SECONDS`) to avoid hangs and orphaned subprocesses.

### Fixed
- `mcp-bash validate` no longer warns about directory/tool name mismatches when tool names use the server namespace prefix with camelCase (e.g., `git-hex-cherryPickSingle` in a `cherry-pick-single` directory). The validator now strips the server name prefix from `server.meta.json` before comparing.
- Error-path JSON stderr logs no longer print full request payloads on parse/extract failures; logs now include bounded, single-line summaries (bytes/hash/excerpt).
- Tool tracing no longer dumps full args/_meta payloads into xtrace output for SDK helpers; traces remain usable while reducing accidental secret leakage.
- Completion results are now spec-shaped: `result.completion.values` is emitted as `string[]` (MCP `2025-11-25`).
- Completion providers, resource providers, and prompt rendering no longer rely on spawning external `env` in their execution paths (improves Windows/Git Bash reliability with large environments).
- CI env snapshots no longer rely on spawning external `env` when estimating environment size.
- Resource provider execution no longer breaks under Bash 3.2 `set -u` when running in curated environments (fixes macOS CI integration failures).
- Windows/Git Bash: curated provider env scrubbing is faster (batch unsets), avoiding provider-suite timeouts under very large environments.
- Windows/Git Bash: provider isolation no longer preserves arbitrary `MCPBASH_*` variables (reduces env bloat); use `MCPBASH_PROVIDER_ENV_MODE=allowlist` to pass custom `MCPBASH_*` variables to providers.

### Documentation
- Expanded MCP Inspector troubleshooting (origin allowlist + large `PATH` causing connect failures) and clarified completion request shape expectations in completion docs/examples.
- Updated `examples/10-completions` to include a demo prompt so completions can be exercised directly from the MCP Inspector UI (Prompts tab).
- Fixed minor README grammar in the run-tool section.

## [0.7.0] - 2025-12-13

### Documentation
- Clarified Windows support: Git Bash is CI-tested; WSL works like Linux but is not separately validated in CI.
- README MCP spec coverage table now marks Resources as fully supported (templates/binary included).
- Fixed `docs/ERRORS.md` examples to reflect that `result.isError=true` is derived from a non-zero tool exit.
- Added `docs/INSPECTOR.md` with MCP Inspector recipes and strict-client schema/shape pitfalls.
- Clarified completion script argument parsing: `MCP_COMPLETION_ARGS_JSON` is `params.arguments` (use `.query` / `.prefix`).

### Added
- Declarative project registration via `server.d/register.json` (data-only alternative to `server.d/register.sh`) with strict validation, safe-permissions checks, and per-kind override semantics.
- `mcp-bash run-tool` now supports per-invocation allowlisting via `--allow-self`, `--allow <tool>`, and `--allow-all`.
- Installer verification flag `--verify` to validate downloaded archives against published SHA256 checksums; pairs with release-published tarball and SHA256SUMS.
- Installer `--archive` flag to install from a local tar.gz (or URL) after verifying it externally (or via `--verify`).
- GitHub Actions release workflow (tag-triggered) builds a tarball and publishes SHA256SUMS for installer verification.
- Release prep automation: `scripts/bump-version.sh`, `scripts/render-readme.sh`, and a `Prepare Release` workflow to open a PR that bumps `VERSION` and re-renders `README.md`.
- CI/release guards: validate that `VERSION` matches the tag and that `README.md` is rendered from `README.md.in` for the release version.
- Unified test wrapper `test/run-all.sh` to sequence lint/unit/integration/examples/stress/smoke suites with skip flags.
- Windows Git Bash/MSYS guidance surfaced in `mcp-bash doctor` (stdout and `--json`) to set `MCPBASH_JSON_TOOL=jq` and `MSYS2_ARG_CONV_EXCL="*"`.
- Documentation updates: README troubleshooting section, installer verification example, allowlist env mode examples in README/ENV_REFERENCE, CI-mode guidance in CONTRIBUTING.
- Resource templates: auto-discovery of `uriTemplate` metadata, manual registration helpers, `.registry/resource-templates.json` cache with hash-based pagination, and shared `resources/list_changed` notifications. New example and docs cover client-side expansion and collision rules.
- Documentation updates: clarified batching (legacy/opt-in) in `SPEC-COMPLIANCE.md`, noted minimal mode capability omissions, added `docs/README.md` index and project structure clarifications, documented `resources/subscribe` notification shape, and added registry-size guidance in `PERFORMANCE.md`.
- Windows CI guidance in `docs/WINDOWS.md` recommends jq overrides (`MCPBASH_JSON_TOOL=jq`, `MCPBASH_JSON_TOOL_BIN=$(command -v jq)`) to avoid gojq exec-limit failures on GitHub Actions runners.
- `mcp-bash scaffold completion <name>` generates a starter completion script, registers it in `server.d/register.sh`, and wires a default timeout.

### Changed
- Installer `--verify` for tagged releases now targets the release-published tarball (`releases/download/vX.Y.Z/mcp-bash-vX.Y.Z.tar.gz`) so it stays in sync with the `SHA256SUMS` asset.
- Tagged archive installs now attempt to verify against `SHA256SUMS` automatically when available (without requiring `--verify`).
- Outgoing request IDs are now allocated via a lock-backed counter in the state dir to prevent cross-process ID reuse; elicitation polling in the flusher uses the shared counter.
- Background workers now start lazily: resource subscription polling begins on first `resources/subscribe`, and the progress flusher runs only when live progress is enabled or elicitation is supported (reduces overhead on Windows runners).
- All example tool/resource names switched to hyphenated form to match the validated naming regex.
- Server now advertises the spec-compliant `completions` capability in initialize responses; tests assert capability presence.
- Tool metadata parsing consolidates to a single jq pass per meta file, reducing per-tool process overhead during registry scans.
- Scaffolded tool template now treats `name` as optional with a default, matching the description.
- JSON tool detection now prefers jq over gojq, supports explicit MCPBASH_JSON_TOOL(_BIN) overrides, and validates candidates via `--version` before enabling full protocol mode.
- CI env snapshot now runs after JSON tool detection and records PATH/env byte sizes plus `jsonTool`/`jsonToolBin` metadata (counts only; no env contents captured).
- JSON-RPC batch handling is now protocol-aware: protocol `2025-03-26` auto-accepts batch arrays; newer protocols reject arrays unless `MCPBASH_COMPAT_BATCHES=true` is set for legacy clients, with clearer error messaging.
- Worker wait loop sleep increased to reduce busy-wait CPU churn when slots are full.
- Security hardening: git provider now requires allowlists, canonicalizes repo paths, and pre-checks disk space; HTTPS provider resolves hosts and blocks obfuscated private IPs; remote token guard enforces 32+ char secrets, throttles failures, and redacts tokens in debug logs; `MCPBASH_TOOL_ENV_MODE=inherit` now requires explicit opt-in via `MCPBASH_TOOL_ENV_INHERIT_ALLOW=true`; JSON tool overrides are ignored for root unless explicitly allowed (`MCPBASH_ALLOW_JSON_TOOL_OVERRIDE_FOR_ROOT=true`); tool metadata parsing no longer uses eval.
- **BREAKING**: Project registry hooks are now disabled by default; set `MCPBASH_ALLOW_PROJECT_HOOKS=true` to execute `server.d/register.sh`. Hooks are refused if the file is group/world writable or ownership mismatches the current user.
- **BREAKING**: Tool execution now defaults to deny unless explicitly allowlisted via `MCPBASH_TOOL_ALLOWLIST` (set to `*` to allow all in trusted projects). Paths are validated for ownership and safe permissions before execution.
- Debug payload redaction now scrubs common secret keys beyond `remoteToken`.
- Installer/docs now prefer verified downloads over `curl | bash` (one-liner retained as a labeled fallback).
- List endpoints now report total counts via `result._meta["mcpbash/total"]` (and no longer emit a top-level `total`) for stricter MCP client compatibility.
- `resources/subscribe` now returns only `{subscriptionId}` (spec-shaped) instead of including extra fields.
- `notifications/resources/updated` is now spec-shaped and emits only `params.uri`; clients should call `resources/read` to fetch updated content.
- Completion results no longer include the non-spec `result._meta.cursor` field (use `result.completion.nextCursor`).
- HTTPS provider is now deny-by-default for public hosts: set `MCPBASH_HTTPS_ALLOW_HOSTS` (preferred) or `MCPBASH_HTTPS_ALLOW_ALL=true` to permit outbound HTTPS fetches; URL host parsing strips userinfo to prevent SSRF bypasses.
- HTTPS provider no longer falls back to wget; curl is required to support DNS pinning via `--resolve`.
- Git provider path canonicalization now fails closed without `realpath` or `readlink -f` to prevent symlink-based escapes.
- Git provider now only accepts `git+https://` URIs (plaintext `git://` removed).

### Fixed
- Manual registration hook size-limit errors now set status for `resourceTemplates` consistently.
- JSON-RPC handlers no longer emit error `code: 0` when underlying registry failures occur (falls back to `-32603`).
- Removed duplicate YAML meta from the progress-and-cancellation example (JSON is canonical).
- Windows CI failures caused by `gojq` `E2BIG` exec errors are avoided by the jq-first detection order and exec sanity check.
- Windows Git Bash example flakiness: runtime now guarantees `MCPBASH_STATE_DIR`/`MCPBASH_LOCK_ROOT` exist (with a short-path fallback), and example tests capture server stderr and fail fast on shutdown watchdog timeouts or `mktemp` template failures.
- Progress/log streaming is more reliable across platforms: portable byte offsets in the flusher and explicit flushes before worker cleanup reduce missing tail output.
- HTTPS provider pins curl connections to vetted IPs via `--resolve` to mitigate DNS rebinding SSRF between pre-check and fetch.
- Registry refresh-path and git repo-root containment checks now use literal (non-glob) prefix comparisons to avoid metacharacter bypasses.
- Debug payload redaction now scrubs common secret keys across the full JSON payload (not only `_meta`) to reduce accidental leakage during debugging.
- `mcp_json_trim` rewritten to avoid O(n^2) trimming on large payloads.
- Shutdown finish branch corrected to prevent a syntax error in staged environments.
- `MCPBASH_SHUTDOWN_TIMEOUT=0` is now treated as "use the default" to avoid accidental zero-timeout shutdowns.
- `tools/call` now returns `-32602` (Invalid params) for tool not found, instead of `-32601` (Method not found), for JSON-RPC spec compliance.
- `resources/read` now returns `-32002` (Resource not found) for missing resources, instead of `-32601` (Method not found), per MCP spec.
- Resource providers no longer require the executable bit (more reliable on Git Bash/MSYS and some filesystems).
- Git Bash CRLF handling: strip `\r` from env passthrough and metadata keys to prevent subtle Windows-only failures.
- Completion scripts and custom providers work more reliably across platforms.
- JSON-RPC error responses omit `id` when the request `id` is invalid/unknown (strict JSON-RPC compliance).

## [0.6.0] - 2025-12-08

### Added
- Documentation discoverability improvements: README now links feature guides (elicitation, roots, registry, limits, errors, best practices, completions) and a new `docs/COMPLETION.md` covers completion providers, pagination, and script contracts.
- New example `examples/10-completions` demonstrating manual completion registration, query filtering, and hasMore/cursor pagination; included in the examples ladder.
- Comprehensive MCP Feature Support Matrix in `SPEC-COMPLIANCE.md` tracking all MCP features across protocol versions (2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25) with mcpbash version support status. Table includes 60+ features with implementation status, notes, and version history.
- Request metadata (`_meta`) support for `tools/call`: clients can now pass arbitrary metadata via `params._meta` which is exposed to tools as `MCP_TOOL_META_JSON` (or `MCP_TOOL_META_FILE` for large payloads). SDK helpers `mcp_meta_raw` and `mcp_meta_get` provide easy access. Use cases: pass auth context, rate limiting IDs, or behavior flags not generated by the LLM.
- Tools can now return embedded resources in results: write paths (optional mime/uri) to `MCP_TOOL_RESOURCES_FILE` and the framework will emit `type:"resource"` entries, including binary-safe handling.
- Resource reads detect binary MIME and emit base64 `blob` payloads instead of raw text to prevent malformed JSON on binary files.
- Tool errors now include structured exit codes and bounded stderr tails in `error.data` (mirrored in `_meta.stderr`); timeout responses surface the actual exit status and tail. Tunables: `MCPBASH_TOOL_STDERR_CAPTURE`, `MCPBASH_TOOL_STDERR_TAIL_LIMIT`, `MCPBASH_TOOL_TIMEOUT_CAPTURE`.
- Optional tool tracing: set `MCPBASH_TRACE_TOOLS=true` to enable `set -x` traces for shell tools with configurable `PS4` (`MCPBASH_TRACE_PS4`) and trace size cap (`MCPBASH_TRACE_MAX_BYTES`); traces are written under `MCPBASH_STATE_DIR`.
- CI mode enhancements: `MCPBASH_CI_MODE` now sets safe defaults (tmp root, log dir, keep-logs, timestamped logs, optional debug via `MCPBASH_CI_VERBOSE`), writes `failure-summary.jsonl` and `env-snapshot.json` under the log dir, and emits GitHub Actions `::error` annotations when tracing provides file/line.
- Tool annotations support (MCP 2025-03-26): tools can declare behavior hints (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) in `.meta.json` or inline `# mcp:` comments. Annotations are surfaced in `tools/list` responses for clients to present appropriate UI cues.
- Shared-secret guard for proxied runs: set `MCPBASH_REMOTE_TOKEN` (default `_meta["mcpbash/remoteToken"]`, configurable key, timing-safe compare) to reject unauthenticated requests with `-32602`.
- Readiness/health probe: `mcp-bash --health|--ready [--project-root DIR] [--timeout SECS]` refreshes registries without side effects and exits `0/1/2` for probes.

### Changed
- **BREAKING**: Installer now uses XDG Base Directory compliant paths. Framework installs to `~/.local/share/mcp-bash` (or `$XDG_DATA_HOME/mcp-bash`) with a symlink at `~/.local/bin/mcp-bash`. Previous default was `~/mcp-bash-framework`. Users upgrading should either re-run the installer (which will use the new location) or specify `--dir ~/mcp-bash-framework` to keep the old path.
- Roots handling is quieter and stricter: fallback roots load immediately (env → config/roots.json → project root), client timeouts keep the existing cache without noisy warnings, roots must exist/read, drive letters are normalized for Windows/MSYS, and `run-tool --roots`/`MCPBASH_ROOTS` fail fast on invalid paths.
- `config --show` now prefixes each client snippet with a heading to make the target client clear; docs call out the multi-client output and `--client`/`--json` filters.
- Documentation updated to reflect MCP protocol version `2025-11-25` as the current target (was `2025-06-18`); the runtime now targets `2025-11-25` by default, and README/SPEC-COMPLIANCE.md include links to all supported protocol versions.
- Environment surface simplified: runtime timeout defaults use a single tier (30s tool, 120s subscribe, 5s shutdown), dead `MCPBASH_PROCESS_GROUP_WARNED` removed, README optional config trimmed to essentials, and a new authoritative `docs/ENV_REFERENCE.md` lists all user-facing knobs with defaults/caps.
- Tool invocations now log arguments, timeout, meta keys, roots, and trace status to the `mcp.tools` logger for easier diagnostics.

### Fixed
- `mcp-bash` now resolves symlinked launchers correctly, restoring accurate version detection and wrapper path handling when the binary is invoked via symlinks.
- `mcp-bash doctor` verifies the configured temporary root (`MCPBASH_TMP_ROOT` when set) is writable and reports misconfigurations instead of proceeding silently.

## [0.5.0] - 2025-12-08

### Added
- Protocol version `2025-11-25` support for compatibility with MCP Inspector v0.17+ and latest MCP SDK.
- Icons support for tools, resources, and prompts (SEP-973): add an `icons` array to any `.meta.json` file to provide visual identifiers in compatible clients. Icons are passed through in `tools/list`, `resources/list`, and `prompts/list` responses. Local file paths (e.g., `"./icon.svg"`) are automatically converted to data URIs for stdio transport compatibility.
- Documentation on Protocol Errors vs Tool Execution Errors (SEP-1303): `ERRORS.md` and `BEST-PRACTICES.md` now explain when to use each error type to enable LLM self-correction. Examples updated to demonstrate best practices.
- Elicitation SDK helpers for SEP-1330 enum improvements: `mcp_elicit_titled_choice` (choices with display labels) and `mcp_elicit_multi_choice` / `mcp_elicit_titled_multi_choice` (multi-select checkboxes). The 08-elicitation example demonstrates all patterns.
- SEP-1036 URL mode elicitation support: `mcp_elicit_url` helper for secure out-of-band interactions (OAuth, payments, sensitive data). The framework now detects client form/url mode capabilities and includes `mode` in elicitation requests.
- `mcp-bash config --inspector` prints a ready-to-run MCP Inspector command (stdio transport) with `MCPBASH_PROJECT_ROOT` pre-populated for the current project.
- Test session helper `test/common/session.sh` for sequential interactive tool calls in tests; documented in `TESTING.md` (note: skips notifications, overwrites EXIT traps).
- `mcp-bash config --wrapper-env` generates a wrapper that sources `.zshrc`/`.bash_profile`/`.bashrc` before exec (for Claude Desktop macOS non-login shells).
- `mcp-bash doctor` detects macOS `com.apple.quarantine` on the framework binary and project path and prints remediation commands; helper script `scripts/macos-dequarantine.sh` added.
- README and debugging docs include macOS Claude Desktop troubleshooting (PATH/env gaps, quarantine clearing, wrapper guidance).
- `validate` warns when tool names lack a namespace-style prefix (e.g., `myproj-hello`) to encourage safer naming.

### Fixed
- Unsupported protocol version errors now include the requested version and list of supported versions for easier debugging.
- Startup diagnostics detect stdio transport and log to stderr (transport, cwd, project root, JSON tool) to keep stdout JSON-only for clients.
- README OpenAI Agents SDK example matches the current `MCPServerStdio` signature (no `name` kwarg, optional args/env/cwd shown).
- README notes that client configs can point to generated wrapper scripts (`config --wrapper`/`--wrapper-env`) instead of the raw binary.
- README clarifies when to choose `config --wrapper` vs `--wrapper-env` and how to distribute both options (GUI vs CI/Linux).

### Changed
- Replaced `mcp-bash scaffold server` with `mcp-bash new <name> [--no-hello]`; server scaffolding now lives under the new command and `scaffold server` is removed.
- `mcp-bash config --wrapper` now creates `<project-root>/<server-name>.sh` and `chmod +x` when stdout is a TTY (with filename validation and collision checks) while preserving stdout output for piped/redirected use; help/docs/tests updated.
- Documentation clarifies the MCP name regex (alphanumeric, underscores, hyphens only) and switches tool examples to hyphenated names to match the limitations of some clients; `validate` now warns on names outside the supported regex and scaffolding rejects dotted names up front.
- JSON tooling detection success logs are quiet by default; set `MCPBASH_LOG_JSON_TOOL=log` or `MCPBASH_LOG_VERBOSE=true` to surface them. Minimal-mode warnings still emit when JSON tooling is missing.
- Startup summary log is suppressed by default; set `MCPBASH_LOG_STARTUP=true` or `MCPBASH_LOG_VERBOSE=true` to print it.

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
