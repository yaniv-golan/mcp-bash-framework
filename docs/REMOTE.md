# Remote Connectivity

mcp-bash implements only the stdio transport. HTTP, SSE, OAuth, and remote access are handled by external gateways and proxies.

## TL;DR (for operators)

- Require a shared secret (≥32 chars) by setting `MCPBASH_REMOTE_TOKEN` (default `_meta["mcpbash/remoteToken"]`; configurable key, legacy fallback optional).
- Have your gateway map `Authorization: Bearer <token>` → `_meta["mcpbash/remoteToken"]`, and forward `Mcp-Session-Id` / `MCP-Protocol-Version`.
- Use `mcp-bash --health [--project-root DIR]` in liveness/readiness probes (no registry writes or notifications, exits 0/1/2).
- Keep TLS, rate limiting, and token rotation on the gateway; never log token values.

## Choose Your Gateway

| Use Case | Recommended Tool |
|----------|------------------|
| Docker Desktop users | [Docker MCP Gateway](https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/) |
| Lightweight standalone proxy | [mcp-proxy](https://github.com/sparfenyuk/mcp-proxy) |
| Kubernetes deployments | [Microsoft MCP Gateway](https://github.com/microsoft/mcp-gateway) |
| APISIX API gateway users | [mcp-bridge plugin](https://dev.to/apisix/from-stdio-to-http-sse-host-your-mcp-server-with-apisix-api-gateway-26i2) |

These gateways are **optional** and external to mcp-bash. You do not need Python/Node to run mcp-bash itself; choose a gateway that fits your environment (Docker/Kubernetes/Go/Python, etc.) only when you need HTTP/SSE exposure.

---

## Proxy Mode Requirements

- Export `MCPBASH_PROJECT_ROOT` (and optionally `MCPBASH_TMP_ROOT`) so the server discovers your tools/resources/prompts.
- Set a shared secret: `MCPBASH_REMOTE_TOKEN=$(openssl rand -base64 32)` and keep it out of shell history.
- Default `_meta` key is `mcpbash/remoteToken`; override with `MCPBASH_REMOTE_TOKEN_KEY` if your gateway needs a different mapping. A legacy `_meta.remoteToken` fallback is accepted for compatibility.
- Gateways must forward session headers untouched: `Mcp-Session-Id`, `MCP-Protocol-Version`, and any client-provided cancellation/progress headers.
- Server-initiated traffic (progress, cancel notifications, server-driven roots/list) is exempt from auth.

## Shared-Secret Guard (_meta)

- When `MCPBASH_REMOTE_TOKEN` is set, every request must include the token in `_meta["mcpbash/remoteToken"]` (or your configured key). Missing/invalid tokens return `-32602` with `Remote token missing or invalid`.
- Generate at least 256 bits of entropy (`openssl rand -base64 32` → ~44 chars). Rotate on a schedule (e.g., every 90 days); rotation requires clients to reconnect so the proxy can send the new token.
- Keep the token base64-safe. Do not log or echo it; payload debug logs redact the token but should be disabled in production.
- Per-request enforcement only; there is no session binding or downgrade to unauthenticated traffic.

### Header → _meta mapping

| HTTP header | _meta key | Notes |
|-------------|-----------|-------|
| `Authorization: Bearer <token>` | `mcpbash/remoteToken` | Recommended default; strip before forwarding outside the gateway. |
| `X-MCPBash-Remote-Token: <token>` | `mcpbash/remoteToken` | Use when `Authorization` is reserved for upstream auth. |
| `X-MCP-Remote-Token: <token>` | `remoteToken` | Legacy fallback; set `MCPBASH_REMOTE_TOKEN_FALLBACK_KEY=""` to disable. |

Gateways that support header → `_meta` mapping should translate one of the headers above into the target key and omit it from external logs.

## Gateway Snippets

These examples focus on env wiring, token injection, and header forwarding. Adjust syntax to your gateway’s configuration format.

### mcp-proxy (standalone)

```bash
pip install mcp-proxy
export MCPBASH_PROJECT_ROOT=/srv/mcp-project
export MCPBASH_REMOTE_TOKEN="$(openssl rand -base64 32)"

mcp-proxy \
  --host 0.0.0.0 \
  --port 8080 \
  --env MCPBASH_PROJECT_ROOT="$MCPBASH_PROJECT_ROOT" \
  --env MCPBASH_REMOTE_TOKEN="$MCPBASH_REMOTE_TOKEN" \
  mcp-bash
# Configure mcp-proxy header→_meta mapping so Authorization → _meta["mcpbash/remoteToken"].
```

Clients connect to `http://<host>:8080/sse`. Keep CORS and auth handling in the proxy (e.g., `--allow-origin`, named server configs).

### Docker MCP Gateway

```yaml
# Example server stanza (adapt to Docker MCP Gateway config keys)
servers:
  - name: my-mcp-bash
    command: mcp-bash
    env:
      MCPBASH_PROJECT_ROOT: /srv/mcp-project
      MCPBASH_REMOTE_TOKEN: ${REMOTE_TOKEN}
    headerToMeta:
      Authorization: mcpbash/remoteToken
    forwardHeaders:
      - Mcp-Session-Id
      - MCP-Protocol-Version
```

### Microsoft MCP Gateway (Kubernetes)

```yaml
# Example deployment values (adapt to gateway CRD/Helm fields)
env:
  MCPBASH_PROJECT_ROOT: /srv/mcp-project
  MCPBASH_REMOTE_TOKEN: ${REMOTE_TOKEN}
headerToMeta:
  Authorization: mcpbash/remoteToken
forwardHeaders:
  - Mcp-Session-Id
  - MCP-Protocol-Version
command: ["mcp-bash"]
```

### APISIX MCP bridge

```yaml
plugins:
  - name: mcp-bridge
    config:
      cmd: mcp-bash
      env:
        MCPBASH_PROJECT_ROOT: /srv/mcp-project
        MCPBASH_REMOTE_TOKEN: ${REMOTE_TOKEN}
      header_to_meta:
        Authorization: mcpbash/remoteToken
      forward_headers:
        - Mcp-Session-Id
        - MCP-Protocol-Version
```

## Health/Readiness Probes

- `mcp-bash --health [--project-root DIR] [--timeout SECS]` exits `0` (ready), `1` (unhealthy/transient), `2` (misconfigured, e.g., missing project or JSON tooling).
- The probe refreshes registries without writing `.registry` files or emitting `list_changed` notifications and self-times out (default 5s). Suitable for container liveness/readiness endpoints.

## Security Checklist

- Terminate TLS at the gateway and keep the MCP port off the public internet.
- Rate limit and audit auth failures at the gateway; never log token contents.
- mcp-bash also rate-limits bad remote tokens (`MCPBASH_REMOTE_TOKEN_MAX_FAILURES_PER_MIN`, defaults to 10) to blunt brute-force attempts.
- Rotate `MCPBASH_REMOTE_TOKEN` regularly and restart the proxy to pick up the new value.
- Forward session headers intact (`Mcp-Session-Id`, `MCP-Protocol-Version`, cancellation/progress headers) to preserve client affinity.

## Protocol Notes

When bridging stdio to HTTP, gateways must:

- Maintain session headers (`Mcp-Session-Id`, `MCP-Protocol-Version`)
- Support streamable HTTP semantics (POST for RPC, GET for SSE)
- Handle backwards-compatible HTTP+SSE for older clients

See the [MCP Transports specification](https://modelcontextprotocol.io/docs/concepts/transports) for wire semantics.

## Scope

OAuth, SSE, and HTTP transports remain out of scope for the mcp-bash core runtime. Consult gateway documentation before exposing mcp-bash beyond localhost.
