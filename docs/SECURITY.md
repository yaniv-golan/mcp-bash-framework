# Security Considerations

## Reporting
- Please submit security reports via GitHub’s security advisories (Repository → Security → Report a vulnerability). Include reproduction steps, affected versions, and impact; maintainers will acknowledge within 48 hours and coordinate disclosure.
- Avoid public issues/PRs for exploitable bugs until a fix is available.

## Threat model
- **Attack surface**: executable tools/resources/prompts under project control, manual registration hooks (`server.d/register.sh`), environment variables injected into tool processes, and filesystem access for resource providers.
- **Trust boundaries**: operators are trusted; tool authors may be semi-trusted; external callers (clients) are untrusted.

## Runtime guardrails
- Tools/resources inherit the server environment; when running untrusted extensions, prefer a curated env (e.g., invoke server via `env -i` plus explicit allowlist) and set `MCP_RESOURCES_ROOTS` to limit file access.
- Logging defaults to `info` and can be tuned with `logging/setLevel` while respecting RFC-5424 levels.
- Manual registration scripts execute in-process; ensure they are trusted before enabling `server.d/register.sh` and consider wrapper scripts that sanitize output.
- JSON outputs are escaped and newline-compacted before reaching stdout to protect consumers.

## Input validation
- JSON-RPC requests are validated for method presence, ids, and payload shape; unknown methods return `-32601`.
- Tool/resource/prompt metadata is schema-normalized before use; malformed registries are rejected and rebuilt.
- Environment variables and arguments passed to tools are not automatically sanitized—extensions must validate inputs and reject untrusted values explicitly.
