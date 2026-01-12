# Security Considerations

## Reporting
- Submit reports via GitHub security advisories (Repository → Security → Report a vulnerability). Include reproduction steps, affected versions, and impact; maintainers acknowledge within 48 hours and coordinate disclosure.
- Keep exploitable bugs out of public issues/PRs until a fix ships.

## Production Deployment Checklist

Before deploying mcp-bash in production or with remote access, verify:

```
□ MCPBASH_TOOL_ALLOWLIST set to explicit tool names (never "*" in production)
□ MCPBASH_TOOL_ENV_MODE=minimal (default; do not change unless necessary)
□ MCPBASH_TOOL_ENV_INHERIT_ALLOW is NOT set to true
□ MCPBASH_DEBUG_PAYLOADS is NOT set (disabled by default)
□ MCPBASH_LOG_VERBOSE is NOT set (disabled by default)
□ MCPBASH_REMOTE_TOKEN set to a cryptographically random ≥32 character secret
□ server.d/policy.sh reviewed and owned by the server user with mode 0600/0700
□ server.d/register.sh reviewed if MCPBASH_ALLOW_PROJECT_HOOKS=true
□ MCPBASH_PROJECT_ROOT is not world-writable
□ All tool scripts under tools/ are owned by server user, not group/world-writable
□ TLS-terminating gateway deployed in front of mcp-bash for remote access
□ Gateway implements request rate limiting (mcp-bash does not rate-limit successful requests)
□ Auth failure logs monitored (rate-limited to MCPBASH_REMOTE_TOKEN_MAX_FAILURES_PER_MIN)
```

## Approach

mcp-bash keeps the attack surface small: every tool is a subprocess with a controlled environment and no shared state. Security comes from reducing what the framework does, not layering more on top.

## Threat model
- **Attack surface**: tool/resource/prompt executables, manual registration hooks (`server.d/register.sh`), declarative registration (`server.d/register.json`), environment passed to tools, and filesystem access through resource providers.
- **Trust boundaries**: operators are trusted; tool authors may be semi-trusted; external callers (clients) are untrusted.

## Runtime guardrails
- Project hooks are **opt-in**: `server.d/register.sh` executes only when `MCPBASH_ALLOW_PROJECT_HOOKS=true` and the file is owned by the current user with no group/world write bits. Treat hooks like code you would ship; never enable on untrusted repos.
- Prefer declarative registration when possible: `server.d/register.json` registers tools/resources/prompts/resource templates/completions **without executing shell code** during list/refresh flows. It is still security-sensitive configuration (it changes exposed surface area) and is refused if ownership/perms are insecure.
- Default tool env is minimal (`MCPBASH_TOOL_ENV_MODE=minimal` keeps PATH/HOME/TMPDIR/LANG plus `MCP_*`/`MCPBASH_*`). Use `allowlist` via `MCPBASH_TOOL_ENV_ALLOWLIST` or `inherit` only when the tool needs it.
- Inherit mode is gated: set `MCPBASH_TOOL_ENV_INHERIT_ALLOW=true` to allow `MCPBASH_TOOL_ENV_MODE=inherit`; otherwise tool calls fail closed to prevent accidental env leaks.
- Tools are **deny-by-default** unless explicitly allowlisted via `MCPBASH_TOOL_ALLOWLIST` (set to `*` only in trusted projects). Tool paths must live under `MCPBASH_TOOLS_DIR` and cannot be group/world writable.
- Scope file access with `MCP_RESOURCES_ROOTS` (resources) and MCP Roots for tools (`MCPBASH_ROOTS`/`config/roots.json` when clients don’t provide roots); avoid mixing Windows/POSIX roots on Git-Bash/MSYS.
- Logging defaults to `info` and follows RFC-5424 levels via `logging/setLevel`. Paths and manual-registration script output are redacted unless `MCPBASH_LOG_VERBOSE=true`; avoid enabling verbose mode in shared or remote environments as it exposes file paths, usernames, and cache locations.
- Payload debug logs scrub common secret fields (best-effort) and should remain disabled in production; combining `MCPBASH_DEBUG_PAYLOADS=true` with remote access still risks secret exposure if logs are forwarded.
- Tool tracing (`MCPBASH_TRACE_TOOLS=true`) is a debugging feature; treat trace files as potentially sensitive. The SDK suppresses xtrace around secret-bearing args/meta payload expansions, but tools can still leak secrets if they print values explicitly.
- JSON parse/extract failure logs are bounded, single-line summaries (byte count, optional hash, sanitized excerpt) to reduce secret leakage and log injection risk. Do not rely on stderr logs to reconstruct full client requests.
  - When you need full request capture for debugging, do it in a controlled layer **outside** mcp-bash:
    - In the **host application** that bridges/feeds stdio (or a wrapper script), tee stdin to a protected file (strict permissions, short retention, and treat as secret-bearing).
    - In the **client tooling** (e.g., MCP Inspector / SDK client), enable request logging/export locally and keep logs private.
- Manual registration scripts run in-process; only enable trusted code or wrap it to sanitize output.

> **⚠️ CRITICAL: `server.d/policy.sh` Security**
>
> The policy hook file `server.d/policy.sh` is **sourced with full shell privileges** during tool execution. This means:
> - Any code in this file runs as the mcp-bash server user
> - An attacker who can write to this file achieves arbitrary code execution
> - The file is sourced automatically (unlike `register.sh` which requires opt-in)
>
> **Protections enforced by the framework:**
> - File must be owned by the current user
> - File must not be group or world writable (no 020 or 002 permission bits)
> - File must not be a symlink
> - Parent directory (`server.d/`) must not be a symlink
> - `MCPBASH_PROJECT_ROOT` must not be a symlink
>
> **Operator responsibilities:**
> - Review `policy.sh` contents before deployment (treat as privileged code)
> - Set restrictive permissions: `chmod 600 server.d/policy.sh`
> - Do not deploy in directories writable by untrusted users
> - Consider using environment-only policy (`MCPBASH_TOOL_ALLOWLIST`) instead of `policy.sh` when possible
> - In shared environments, verify no other user has the same UID
- Outbound JSON is escaped and newline-compacted before hitting stdout to keep consumers safe.
- State/lock/registry directories are created with `umask 077`; debug mode uses a randomized 0700 directory rather than a predictable path.
- The `mcp-bash run-tool --source` flag executes arbitrary shell code from the specified file before tool execution. Only use with trusted files; treat `--source` paths the same as tool scripts themselves (user explicitly requests execution, implying trust). The `--with-server-env` flag sources only `server.d/env.sh` from the project root.

## Supply chain & tool audits
- Pin tool dependencies (container digests, package versions) and verify checksums before running `bin/mcp-bash` in CI or production.
- Treat `server.d/register.sh` and provider scripts as privileged code paths; require code review and signing, and avoid executing from writable shared volumes.
- Run `shellcheck`/`shfmt`/`pre-commit run --all-files` on contributed tools/resources to prevent obvious injection vectors.
- Periodically review `.registry/*.json` contents for unexpected providers/URIs and revoke filesystem roots that are no longer required.
- Prefer verified downloads over `curl | bash` for installs; if using the installer, validate checksums/signatures first.
- HTTPS provider hardening: private/loopback hosts are blocked; host allow/deny lists via `MCPBASH_HTTPS_ALLOW_HOSTS` / `MCPBASH_HTTPS_DENY_HOSTS` (**allow list required unless `MCPBASH_HTTPS_ALLOW_ALL=true`**); timeouts and size are bounded (timeouts capped at 60s, max bytes capped at 20MB), redirects/protocol downgrades disabled. Hostnames are resolved before fetch and the connection is pinned to vetted IPs via `--resolve` (curl-only) to mitigate DNS rebinding; obfuscated private IPs (e.g., decimal) are rejected.
- Git resource provider: disabled by default; enable with `MCPBASH_ENABLE_GIT_PROVIDER=true`. Only `git+https://` URIs are supported (no plaintext `git://`). Private/loopback blocked; allow list required (`MCPBASH_GIT_ALLOW_HOSTS` or explicit `MCPBASH_GIT_ALLOW_ALL=true`), shallow clone enforced, timeout bounded (default 30s, max 60s), repository size capped via `MCPBASH_GIT_MAX_KB` (default 50MB, max 1GB) with pre-clone space checks. Use behind an allowlisted proxy/cache where possible.
- Remote token guard: minimum 32-character shared secret enforced; bad tokens are throttled (`MCPBASH_REMOTE_TOKEN_MAX_FAILURES_PER_MIN`, default 10) to blunt brute force.
- Diagnostic commands like `mcp-bash doctor` and `mcp-bash validate` are intended for local use; they reveal filesystem paths, environment details, and project layout. Avoid exposing them as remotely callable tools in multi-tenant or untrusted environments.

## Expectations for extensions
- Validate inputs inside your tools; the framework does not guess what your scripts should accept or reject.
- Avoid invoking scripts that run arbitrary input without checks.
- Keep metadata well-formed; malformed registries are rejected and rebuilt.

## Known Security Limitations

The following are documented residual risks that operators should understand:

### Rate limiting scope
mcp-bash rate-limits **authentication failures** only (`MCPBASH_REMOTE_TOKEN_MAX_FAILURES_PER_MIN`). Successful requests are not rate-limited at the framework level. For production deployments, implement rate limiting at the gateway/proxy layer to prevent:
- Resource exhaustion via rapid tool invocations
- Amplification attacks through tools that call external services
- DoS of upstream dependencies

### Symlink race window (TOCTOU)
File and tool path validation uses a double-check pattern: the path is verified as non-symlink, opened, then re-verified. A small race window exists between the first check and file open. Mitigations:
- Race window is minimal (microseconds)
- Attacker requires write access to the containing directory
- Both checks must pass for successful read

In high-security environments, consider mounting content directories read-only or using filesystem-level protections (e.g., immutable attributes).

### Input schema validation
`inputSchema` declared in tool metadata is **not enforced** by the framework. Tools receive arguments as-is and must perform their own validation. This is intentional to preserve flexibility, but means:
- Malformed arguments may cause tool-specific errors
- Type coercion is tool-dependent
- Required field enforcement is tool-dependent

Use the SDK helper `mcp_args_require` in tools to validate required arguments.

### Debug logging secret coverage
Payload debug logging (`MCPBASH_DEBUG_PAYLOADS=true`) redacts common secret field names but:
- Custom/unusual field names are not redacted
- Tool stdout/stderr content is not redacted
- Binary or encoded secrets may bypass pattern matching

Never enable debug payload logging in production; if needed for troubleshooting, do so briefly and delete logs immediately after.

### Environment inheritance risks
`MCPBASH_TOOL_ENV_MODE=inherit` exposes the **entire host environment** to tools, including:
- Cloud credentials (`AWS_SECRET_ACCESS_KEY`, `AZURE_CLIENT_SECRET`, etc.)
- Database connection strings with passwords
- API tokens and service account keys
- SSH agent sockets and GPG passphrases

This mode requires `MCPBASH_TOOL_ENV_INHERIT_ALLOW=true` as an explicit acknowledgment. Prefer `allowlist` mode with `MCPBASH_TOOL_ENV_ALLOWLIST` to pass specific variables.

## Gateway Requirements for Remote Access

mcp-bash communicates via stdio and does **not** implement HTTP/TLS directly. For remote access:

### Required gateway responsibilities
1. **TLS termination** - All remote traffic must be encrypted
2. **Authentication** - Map HTTP auth headers to `_meta.mcpbash/remoteToken` in JSON-RPC requests
3. **Rate limiting** - Protect against request floods (mcp-bash does not rate-limit successful requests)
4. **Request logging** - Maintain audit trail at gateway level
5. **Connection management** - Handle HTTP/2, keep-alive, and timeouts

### Header mapping example
```
Authorization: Bearer <token>  →  params._meta["mcpbash/remoteToken"]
X-MCPBash-Remote-Token: <token>  →  params._meta["mcpbash/remoteToken"]
```

### Recommended gateway configuration
- Maximum request body size: Match `MCPBASH_MAX_TOOL_OUTPUT_SIZE` (default 10MB)
- Request timeout: Match tool timeouts plus buffer (default 30s + 5s)
- Rate limit: Start with 10 requests/second per client, adjust based on usage
- Health endpoint: Use `mcp-bash --health` for liveness probes

See `docs/REMOTE.md` for detailed gateway setup instructions.
