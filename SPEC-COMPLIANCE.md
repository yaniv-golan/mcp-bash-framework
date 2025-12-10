# MCP Protocol Compliance

This document tracks `mcp-bash` compliance with the [Model Context Protocol Specification](https://modelcontextprotocol.io/specification/2025-11-25) (version **2025-11-25**).

## Feature Support Matrix

This table shows when features were introduced in the MCP specification and when mcp-bash added support.

| MCP Feature | MCP Version | mcpbash Version | Status | Notes |
|-------------|-------------|-----------------|--------|-------|
| **Core Protocol** | | | | |
| JSON-RPC 2.0 | 2024-11-05 | 0.1.0 | ✅ Full | Standard message format |
| Lifecycle (initialize/initialized) | 2024-11-05 | 0.1.0 | ✅ Full | Bootstrap handshake |
| Strict Lifecycle (initialize → initialized required) | 2025-06-18 | 0.1.0 | ✅ Full | State machine enforced before serving requests |
| Ping | 2024-11-05 | 0.1.0 | ✅ Full | Heartbeat mechanism |
| Capability Negotiation | 2024-11-05 | 0.1.0 | ✅ Full | Client/server capabilities |
| Protocol Downgrades | 2024-11-05 | 0.1.0 | ✅ Full | Supports 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05 |
| Server Info (name, version, title) | 2024-11-05 | 0.1.0 | ✅ Full | Required fields in initialize response |
| Server Info (description, websiteUrl, icons) | 2024-11-05 | 0.2.0 | ✅ Full | Optional fields via server.meta.json |
| **Transport** | | | | |
| Stdio Transport | 2024-11-05 | 0.1.0 | ✅ Full | Standard input/output |
| HTTP/SSE Transport | 2024-11-05 | ❌ Not supported | ❌ Not supported | Stdio-only design; see REMOTE.md for proxy options |
| Streamable HTTP Transport | 2025-03-26 | ❌ Not supported | ❌ Not supported | Stdio-only design |
| **Tools** | | | | |
| Tools (list/call) | 2024-11-05 | 0.1.0 | ✅ Full | Auto-discovery and execution |
| Tool Annotations | 2025-03-26 | 0.6.0 | ✅ Full | Read-only/destructive behavior metadata |
| Tools listChanged Notification | 2025-06-18 | 0.1.0 | ✅ Full | Registry change detection |
| Request Metadata (`_meta`) | 2025-06-18 | 0.6.0 | ✅ Full | Client-provided metadata surfaced to tools (MCP_TOOL_META_JSON / MCP_TOOL_META_FILE) |
| Tool Execution Errors (SEP-1303) | 2025-11-25 | 0.5.0 | ✅ Full | isError flag for LLM self-correction |
| Tool Icons (SEP-973) | 2025-11-25 | 0.5.0 | ✅ Full | Local files converted to data URIs |
| **Resources** | | | | |
| Resources (list/read) | 2024-11-05 | 0.1.0 | ✅ Full | File/HTTPS/Git providers |
| Resource Subscriptions | 2024-11-05 | 0.1.0 | ✅ Full | Change notifications |
| Resource Templates | 2024-11-05 | 0.6.1 | ✅ Full | Auto-discovery + manual registration with hash-based pagination |
| Resource Icons (SEP-973) | 2025-11-25 | 0.5.0 | ✅ Full | Local files converted to data URIs |
| Resources listChanged Notification | 2025-06-18 | 0.1.0 | ✅ Full | Registry change detection |
| Binary-safe Resource Payloads | 2024-11-05 | 0.6.0 | ✅ Full | Detect binary MIME and emit `blob` base64 instead of raw text |
| **Prompts** | | | | |
| Prompts (list/get) | 2024-11-05 | 0.1.0 | ✅ Full | Template discovery and execution |
| Prompt Arguments | 2024-11-05 | 0.1.0 | ✅ Full | Dynamic prompt parameters |
| Prompt Icons (SEP-973) | 2025-11-25 | 0.5.0 | ✅ Full | Local files converted to data URIs |
| Prompts listChanged Notification | 2025-06-18 | 0.1.0 | ✅ Full | Registry change detection |
| **Utilities** | | | | |
| Progress Notifications | 2024-11-05 | 0.1.0 | ✅ Full | Long-running operation updates |
| Progress Message Field | 2025-03-26 | 0.1.0 | ✅ Full | Descriptive status updates |
| Cancellation | 2024-11-05 | 0.1.0 | ✅ Full | notifications/cancelled support |
| Logging (notifications/message) | 2024-11-05 | 0.1.0 | ✅ Full | Server-to-client logging |
| Logging (logging/setLevel) | 2024-11-05 | 0.1.0 | ✅ Full | Dynamic log level control |
| Completion (completion/complete) | 2025-06-18 | 0.1.0 | ✅ Full | Argument autocompletion |
| Completions Capability | 2025-06-18 | 0.1.0 | ✅ Full | Explicit capability advertisement |
| **Pagination** | | | | |
| Cursor-based Pagination | 2024-11-05 | 0.1.0 | ✅ Full | Opaque cursor format |
| nextCursor Field | 2024-11-05 | 0.1.0 | ✅ Full | Standard pagination field |
| **Authorization** | | | | |
| OAuth 2.1 Framework | 2025-03-26 | ❌ Not applicable | ❌ Not applicable | Only applies to HTTP transport |
| Resource Indicators (RFC 8707) | 2025-06-18 | ❌ Not applicable | ❌ Not applicable | OAuth-only; out of scope for stdio transport |
| **Content Types** | | | | |
| Text Content | 2024-11-05 | 0.1.0 | ✅ Full | Standard text output |
| Image Content | 2024-11-05 | 0.1.0 | ✅ Full | Base64 or URL references |
| Embedded Resources | 2024-11-05 | 0.6.0 | ✅ Full | Tool results can embed resource content (text/blob) |
| Audio Content | 2025-03-26 | ❌ Not yet | ❌ Not yet | Audio data in content responses |
| **Roots** | | | | |
| Roots (roots/list) | 2024-11-05 | 0.1.0 | ✅ Full | Server→client request |
| Roots listChanged Notification | 2024-11-05 | 0.1.0 | ✅ Full | Client notification handled; server re-requests roots and updates env |
| **Elicitation** | | | | |
| Elicitation (Form Mode) | 2025-06-18 | 0.1.0 | ✅ Full | In-band user input |
| Elicitation URL Mode (SEP-1036) | 2025-11-25 | 0.5.0 | ✅ Full | OAuth/payments via browser |
| Elicitation Enum (basic) | 2025-06-18 | 0.1.0 | ✅ Full | Single-select choices |
| Elicitation Titled Enum (SEP-1330) | 2025-11-25 | 0.5.0 | ✅ Full | oneOf with const/title |
| Elicitation Multi-choice (SEP-1330) | 2025-11-25 | 0.5.0 | ✅ Full | Array of enum values |
| Elicitation Titled Multi-choice (SEP-1330) | 2025-11-25 | 0.5.0 | ✅ Full | anyOf with const/title |
| **Advanced Features** | | | | |
| JSON-RPC Batching | 2025-03-26 | ⚠️ Protocol-gated | ⚠️ Legacy | Required for protocol 2025-03-26 (auto-accepted); removed in 2025-06-18; `MCPBASH_COMPAT_BATCHES=true` enables legacy batches for newer protocols |
| Async Operations (job/poll pattern) | 2025-11-25 | ❌ Not yet | ❌ Not yet | Fire-and-forget jobs with polling responses |
| Server Identity Discovery | 2025-11-25 | ❌ Not applicable | ❌ Not applicable | HTTP-only; stdio servers use initialize response |
| Sampling (sampling/createMessage) | 2025-11-25 | ❌ Not yet | ❌ Not yet | Server-initiated LLM requests with `includeContext` for agent loops |

### Legend
- ✅ Full: Complete implementation
- ⚠️ Stub: Partial/stub implementation
- ❌ Not yet: Planned but not yet implemented
- ❌ Not supported: Intentionally out of scope

## Protocol Version

| Property | Value |
|----------|-------|
| Target MCP Version | `2025-11-25` |
| Transport | stdio only (HTTP/SSE out of scope) |
| JSON-RPC Version | 2.0 |
| Downgrade Support | Negotiated during `initialize` (to `2025-06-18`, `2025-03-26`, or `2024-11-05` when requested) |
| Accepted Versions | `2025-11-25` (default), `2025-06-18`, `2025-03-26`, `2024-11-05` |
| Unsupported Versions | Older protocols (for example `2024-10-07`) receive `{"code":-32602,"message":"Unsupported protocol version"}` |

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
| Cancellation | Cancellation notifications via `notifications/cancelled` | `lib/core.sh`, worker cancellation |
| Logging | `notifications/message` for log output | `handlers/logging.sh`, `lib/logging.sh` |
| Completion | Argument completion for tools/prompts/resources | `lib/completion.sh`, `handlers/completion.sh` |
| Pagination | Cursor-based result pagination | `lib/paginate.sh` |
| Resource Templates | `resources/templates/list` with auto/manual discovery (`.registry/resource-templates.json`) | `handlers/resources.sh`, `lib/resources.sh`, `lib/registry.sh`, `docs/RESOURCE-TEMPLATES.md` |
| **Infrastructure** | | |
| Runtime Environment | Tooling detection, minimal-mode fallbacks | `bin/mcp-bash`, `lib/runtime.sh` |
| Concurrency Model | Worker orchestration, cancellation, locks | `lib/core.sh`, `lib/ids.sh`, `lib/lock.sh` |
| Timeouts | Watchdogs and cancellation escalations | `lib/timeout.sh`, worker watchdogs |
| Discovery & Notifications | Registry generation, hash tracking, `list_changed` notifications | `lib/tools.sh`, `lib/resources.sh`, `lib/prompts.sh` |
| Error Handling | JSON-RPC error codes, stderr propagation | Error responses, SDK stderr propagation |
| **SDK & Extensions** | | |
| Tool SDK | Tool SDK, progress and logging wiring | `sdk/tool-sdk.sh` |
| Scaffolding | Templates for tools, resources, prompts | `scaffold/` |
| Manual Registration | Extension workflow for custom tools | README manual overrides, examples |
| **Portability** | | |
| macOS | Bash 3.2+ support | Tested, CI verified |
| Linux | Bash 3.2+ support | Tested, CI verified |
| Windows | Git Bash (CI-tested), WSL (Linux-like) | `providers/file.sh`, `docs/WINDOWS.md` |
| **Documentation** | | |
| Security | Threat model and guardrails | `docs/SECURITY.md` |
| Limits & Performance | Tunable limits, env vars | `docs/LIMITS.md` |
| Testing | Lint/unit/integration workflows | `.github/workflows/ci.yml`, `TESTING.md` |
| Examples | Example MCP servers | `examples/` |

## Features Not Implemented

The following MCP features are currently not implemented:

| Feature | Status | Reason |
|---------|--------|--------|
| HTTP/SSE Transport | Not supported | stdio-only design; see `docs/REMOTE.md` for proxy guidance |
| OAuth Authorization | Not applicable | Out of scope for stdio transport |
| Resource Indicators (RFC 8707) | Not applicable | OAuth-only; stdio transport |
| JSON-RPC Batching | Protocol-gated legacy | Auto-accepted when protocol is 2025-03-26; removed from spec in 2025-06-18; set `MCPBASH_COMPAT_BATCHES=true` to accept legacy batch arrays on newer protocols |
| Async Operations (job/poll pattern) | Not yet | Fire-and-forget jobs with polling surface |
| Server Identity Discovery | Not applicable | HTTP-only (.well-known endpoint); stdio servers return identity via initialize |
| Sampling (sampling/createMessage) | Not yet | Server-initiated LLM requests; could be useful for agentic tool behaviors |
| Audio Content | Not yet | Content type support for audio data |

**Applicability notes**

- Roots: Implemented as a server→client request (`roots/list`) per spec; server capabilities do not advertise a roots surface.
- Elicitation: Implemented when clients advertise support; tools can pause and request additional user input.
- Resource templates: Auto-discovery scans `resources/*.meta.json` for `uriTemplate`, merges manual registrations (manual wins), enforces name collision guard against resources, and shares the `notifications/resources/list_changed` surface. Responses include `limit`/`total` as an allowed extension.
- Completions: Capability is advertised only for protocol versions `2025-06-18` and newer; older protocol downgrades omit completion.
- List pagination: `tools/list`, `resources/list`, and `prompts/list` include a `total` field alongside the required arrays and optional `nextCursor`. The MCP list result schemas permit additional properties, so `total` is an intentional, spec-compliant extension for clients that want the full count.
- “Partial” surfaces (e.g., older protocol versions without `listChanged`) are intentionally reduced per back-compat behavior.

## Verification

Compliance is verified through:

- **Unit tests**: `test/unit/`
- **Integration tests**: `test/integration/`
- **Compatibility tests**: `test/compatibility/` (MCP Inspector)
- **Example validation**: `test/examples/`
- **CI workflow**: `.github/workflows/ci.yml`

## References

- [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25)
- [MCP Specification 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18)
- [MCP Specification 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26)
- [MCP Specification 2024-11-05](https://modelcontextprotocol.io/specification/2024-11-05)
- [MCP Architecture](https://modelcontextprotocol.io/specification/2025-11-25/architecture)
- [MCP Schema Reference](https://modelcontextprotocol.io/specification/2025-11-25/schema)
