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

## Supply chain & tool audits
- Pin tool dependencies (container digests, package versions) and verify checksums before running `bin/mcp-bash` in CI or production.
- Treat `server.d/register.sh` and provider scripts as privileged code paths; require code review and signing, and avoid executing from writable shared volumes.
- Run `shellcheck`/`shfmt`/`pre-commit run --all-files` on contributed tools/resources to prevent obvious injection vectors.
- Periodically review `.registry/*.json` contents for unexpected providers/URIs and revoke filesystem roots that are no longer required.
- Git resource provider is intentionally not constrained by local resource roots; only enable it in trusted environments or sandbox the server to limit which repositories can be fetched. It performs a fresh shallow clone per request; for large or frequently accessed repos, run behind an allowlisted proxy/cache or add a small TMPDIR cache keyed by repo/ref to avoid repeated network pulls.

## Expectations for extensions
- Validate inputs inside your tools; the framework does not guess what your scripts should accept or reject.
- Avoid invoking scripts that run arbitrary input without checks.
- Keep metadata well-formed; malformed registries are rejected and rebuilt.
