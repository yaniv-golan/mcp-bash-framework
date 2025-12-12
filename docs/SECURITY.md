# Security Considerations

## Reporting
- Submit reports via GitHub security advisories (Repository → Security → Report a vulnerability). Include reproduction steps, affected versions, and impact; maintainers acknowledge within 48 hours and coordinate disclosure.
- Keep exploitable bugs out of public issues/PRs until a fix ships.

## Approach

mcp-bash keeps the attack surface small: every tool is a subprocess with a controlled environment and no shared state. Security comes from reducing what the framework does, not layering more on top.

## Threat model
- **Attack surface**: tool/resource/prompt executables, manual registration hooks (`server.d/register.sh`), environment passed to tools, and filesystem access through resource providers.
- **Trust boundaries**: operators are trusted; tool authors may be semi-trusted; external callers (clients) are untrusted.

## Runtime guardrails
- Project hooks are **opt-in**: `server.d/register.sh` executes only when `MCPBASH_ALLOW_PROJECT_HOOKS=true` and the file is owned by the current user with no group/world write bits. Treat hooks like code you would ship; never enable on untrusted repos.
- Default tool env is minimal (`MCPBASH_TOOL_ENV_MODE=minimal` keeps PATH/HOME/TMPDIR/LANG plus `MCP_*`/`MCPBASH_*`). Use `allowlist` via `MCPBASH_TOOL_ENV_ALLOWLIST` or `inherit` only when the tool needs it.
- Inherit mode is gated: set `MCPBASH_TOOL_ENV_INHERIT_ALLOW=true` to allow `MCPBASH_TOOL_ENV_MODE=inherit`; otherwise tool calls fail closed to prevent accidental env leaks.
- Tools are **deny-by-default** unless explicitly allowlisted via `MCPBASH_TOOL_ALLOWLIST` (set to `*` only in trusted projects). Tool paths must live under `MCPBASH_TOOLS_DIR` and cannot be group/world writable.
- Scope file access with `MCP_RESOURCES_ROOTS` (resources) and MCP Roots for tools (`MCPBASH_ROOTS`/`config/roots.json` when clients don’t provide roots); avoid mixing Windows/POSIX roots on Git-Bash/MSYS.
- Logging defaults to `info` and follows RFC-5424 levels via `logging/setLevel`. Paths and manual-registration script output are redacted unless `MCPBASH_LOG_VERBOSE=true`; avoid enabling verbose mode in shared or remote environments as it exposes file paths, usernames, and cache locations.
- Payload debug logs redact remote tokens and should remain disabled in production; combining `MCPBASH_DEBUG_PAYLOADS=true` with remote access still risks secret exposure if logs are forwarded.
- Manual registration scripts run in-process; only enable trusted code or wrap it to sanitize output. Project `server.d/policy.sh` is sourced with full shell privileges; keep it in trusted, non-writable locations.
- Outbound JSON is escaped and newline-compacted before hitting stdout to keep consumers safe.
- State/lock/registry directories are created with `umask 077`; debug mode uses a randomized 0700 directory rather than a predictable path.

## Supply chain & tool audits
- Pin tool dependencies (container digests, package versions) and verify checksums before running `bin/mcp-bash` in CI or production.
- Treat `server.d/register.sh` and provider scripts as privileged code paths; require code review and signing, and avoid executing from writable shared volumes.
- Run `shellcheck`/`shfmt`/`pre-commit run --all-files` on contributed tools/resources to prevent obvious injection vectors.
- Periodically review `.registry/*.json` contents for unexpected providers/URIs and revoke filesystem roots that are no longer required.
- Prefer verified downloads over `curl | bash` for installs; if using the installer, validate checksums/signatures first.
- HTTPS provider hardening: private/loopback hosts are blocked; host allow/deny lists via `MCPBASH_HTTPS_ALLOW_HOSTS` / `MCPBASH_HTTPS_DENY_HOSTS` (**allow list required unless `MCPBASH_HTTPS_ALLOW_ALL=true`**); timeouts and size are bounded (timeouts capped at 60s, max bytes capped at 20MB), redirects/protocol downgrades disabled. Hostnames are resolved before fetch; obfuscated private IPs (e.g., decimal) are rejected.
- Git resource provider: disabled by default; enable with `MCPBASH_ENABLE_GIT_PROVIDER=true`. Private/loopback blocked; allow list required (`MCPBASH_GIT_ALLOW_HOSTS` or explicit `MCPBASH_GIT_ALLOW_ALL=true`), shallow clone enforced, timeout bounded (default 30s, max 60s), repository size capped via `MCPBASH_GIT_MAX_KB` (default 50MB, max 1GB) with pre-clone space checks. Use behind an allowlisted proxy/cache where possible.
- Remote token guard: minimum 32-character shared secret enforced; bad tokens are throttled (`MCPBASH_REMOTE_TOKEN_MAX_FAILURES_PER_MIN`, default 10) to blunt brute force.
- Diagnostic commands like `mcp-bash doctor` and `mcp-bash validate` are intended for local use; they reveal filesystem paths, environment details, and project layout. Avoid exposing them as remotely callable tools in multi-tenant or untrusted environments.

## Expectations for extensions
- Validate inputs inside your tools; the framework does not guess what your scripts should accept or reject.
- Avoid invoking scripts that run arbitrary input without checks.
- Keep metadata well-formed; malformed registries are rejected and rebuilt.
