# MCP Protocol Compliance

This document tracks `mcp-bash` compliance with the [Model Context Protocol Specification](https://modelcontextprotocol.io/specification/2025-06-18) (version **2025-06-18**).

## Protocol Version

| Property | Value |
|----------|-------|
| Target MCP Version | `2025-06-18` |
| Transport | stdio only (HTTP/SSE out of scope) |
| JSON-RPC Version | 2.0 |
| Downgrade Support | Negotiated during `initialize` |
| Unsupported Versions | `initialize` returns `{"code":-32602,"message":"Unsupported protocol version"}` |

## Capability Coverage Matrix

| Area | Description | Implementation |
|------|-------------|----------------|
| **Base Protocol** | | |
| Lifecycle | Bootstrap loop, initialize/initialized handshake | `lib/core.sh`, `handlers/lifecycle.sh` |
| JSON-RPC | Request/response/notification handling, stdout guardrails | `lib/rpc.sh`, `lib/json.sh` |
| Capability Negotiation | Client/server capability exchange | `lib/spec.sh`, lifecycle handler |
| Transports | stdio communication | `lib/io.sh` (HTTP/SSE not supported) |
| **Server Features** | | |
| Tools | Tool discovery, listing, invocation, schema validation | `lib/tools.sh`, `handlers/tools.sh` |
| Resources | Resource discovery, listing, reading, subscriptions | `lib/resources.sh`, `handlers/resources.sh` |
| Prompts | Prompt discovery, listing, retrieval | `lib/prompts.sh`, `handlers/prompts.sh` |
| **Utilities** | | |
| Progress | Progress notifications during long operations | `lib/progress.sh`, SDK integration |
| Cancellation | Request cancellation via `$/cancelRequest` | `lib/core.sh`, worker cancellation |
| Logging | `notifications/message` for log output | `handlers/logging.sh`, `lib/logging.sh` |
| Completion | Argument completion for tools/prompts/resources | `lib/completion.sh`, `handlers/completion.sh` |
| Pagination | Cursor-based result pagination | `lib/paginate.sh` |
| **Infrastructure** | | |
| Runtime Environment | Tooling detection, minimal-mode fallbacks | `bin/mcp-bash`, `lib/runtime.sh` |
| Concurrency Model | Worker orchestration, cancellation, locks | `lib/core.sh`, `lib/ids.sh`, `lib/lock.sh` |
| Timeouts | Watchdogs and cancellation escalations | `lib/timeout.sh`, worker watchdogs |
| Discovery & Notifications | Registry generation, hash tracking, `listChanged` | `lib/tools.sh`, `lib/resources.sh`, `lib/prompts.sh` |
| Error Handling | JSON-RPC error codes, stderr propagation | Error responses, SDK stderr propagation |
| **SDK & Extensions** | | |
| Tool SDK | Tool SDK, progress and logging wiring | `sdk/tool-sdk.sh` |
| Scaffolding | Templates for tools, resources, prompts | `scaffold/` |
| Manual Registration | Extension workflow for custom tools | README manual overrides, examples |
| **Portability** | | |
| macOS | Bash 3.2+ support | Tested, CI verified |
| Linux | Bash 3.2+ support | Tested, CI verified |
| Windows | Git-Bash/WSL compatibility | `providers/file.sh`, `docs/WINDOWS.md` |
| **Documentation** | | |
| Security | Threat model and guardrails | `docs/SECURITY.md` |
| Limits & Performance | Tunable limits, env vars | `docs/LIMITS.md` |
| Testing | Lint/unit/integration workflows | `.github/workflows/ci.yml`, `TESTING.md` |
| Examples | Example MCP servers | `examples/` |

## Features Not Implemented

The following MCP features are currently out of scope:

| Feature | Reason |
|---------|--------|
| HTTP/SSE Transport | stdio-only design; see `docs/REMOTE.md` for proxy guidance |
| OAuth Authorization | Out of scope for stdio transport |
| Sampling (client feature) | Client-side feature, not applicable to servers |
| Roots (client feature) | Client-side feature, not applicable to servers |
| Elicitation (client feature) | Client-side feature, not applicable to servers |

## Verification

Compliance is verified through:

- **Unit tests**: `test/unit/`
- **Integration tests**: `test/integration/`
- **Compatibility tests**: `test/compatibility/` (MCP Inspector)
- **Example validation**: `test/examples/`
- **CI workflow**: `.github/workflows/ci.yml`

## References

- [MCP Specification 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18)
- [MCP Architecture](https://modelcontextprotocol.io/specification/2025-06-18/architecture)
- [MCP Schema Reference](https://modelcontextprotocol.io/specification/2025-06-18/schema)
