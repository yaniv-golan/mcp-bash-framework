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
- Default tool env is minimal (`MCPBASH_TOOL_ENV_MODE=minimal` keeps PATH/HOME/TMPDIR/LANG plus `MCP_*`/`MCPBASH_*`). Use `allowlist` via `MCPBASH_TOOL_ENV_ALLOWLIST` or `inherit` only when the tool needs it.
- Scope file access with `MCP_RESOURCES_ROOTS`; avoid mixing Windows/POSIX roots on Git-Bash/MSYS.
- Logging defaults to `info` and follows RFC-5424 levels via `logging/setLevel`.
- Manual registration scripts run in-process; only enable trusted code or wrap it to sanitize output.
- Outbound JSON is escaped and newline-compacted before hitting stdout to keep consumers safe.

## Expectations for extensions
- Validate inputs inside your tools; the framework does not guess what your scripts should accept or reject.
- Avoid invoking scripts that run arbitrary input without checks.
- Keep metadata well-formed; malformed registries are rejected and rebuilt.
