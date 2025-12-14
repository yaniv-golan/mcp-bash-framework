# Changelog

All notable changes to mcp-bash-framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.1] - Unreleased

### Added

### Changed
- Tool environment isolation no longer spawns external `env`; uses bash built-ins (`compgen -e`, `unset`) to avoid `E2BIG`/`Argument list too long` failures on Windows/Git Bash with large environments.
- **BREAKING**: Completion/resource providers now run under a curated environment by default (`MCPBASH_PROVIDER_ENV_MODE=isolate`) to reduce `E2BIG` risk; opt into inheritance with `MCPBASH_PROVIDER_ENV_MODE=inherit` + `MCPBASH_PROVIDER_ENV_INHERIT_ALLOW=true` or selectively pass variables via `MCPBASH_PROVIDER_ENV_MODE=allowlist`.
- **BREAKING**: `completion/complete` requests are now **spec-shape only** (MCP `2025-11-25`: `params.ref` + `params.argument`). The legacy `params.name`/`params.arguments` shape is no longer accepted.
- CI: Windows integration runs default to non-verbose output and use a PR allowlist to reduce runtime; scheduled runs keep the full suite with per-test timeouts and better log preservation on cancellation.

### Fixed
- Error-path JSON stderr logs no longer print full request payloads on parse/extract failures; logs now include bounded, single-line summaries (bytes/hash/excerpt).
- Tool tracing no longer dumps full args/_meta payloads into xtrace output for SDK helpers; traces remain usable while reducing accidental secret leakage.
- Completion results are now spec-shaped: `result.completion.values` is emitted as `string[]` (MCP `2025-11-25`).
- Completion providers, resource providers, and prompt rendering no longer rely on spawning external `env` in their execution paths (improves Windows/Git Bash reliability with large environments).
- CI env snapshots no longer rely on spawning external `env` when estimating environment size.

### Documentation
- Expanded MCP Inspector troubleshooting (origin allowlist + large `PATH` causing connect failures) and clarified completion request shape expectations in completion docs/examples.
- Updated `examples/10-completions` to include a demo prompt so completions can be exercised directly from the MCP Inspector UI (Prompts tab).

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
