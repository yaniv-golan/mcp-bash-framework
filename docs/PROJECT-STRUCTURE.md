# Project Structure

Minimum layout for an MCP-Bash project:

- `server.d/server.meta.json` — required server metadata (name/title/version/etc.).
- `tools/` — tool directories (`<tool>/tool.sh` + `<tool>/tool.meta.json`).
- `resources/` — resource providers and metadata.
- `prompts/` — prompt templates and metadata.
- `ui/` — standalone UI resources for MCP Apps (dashboards, monitors). See [UI Resources Guide](guides/ui-resources.md).
- `.registry/` — auto-generated registries (ignored by VCS).
- `lib/` — optional shared helpers you source from tools/resources/prompts.
- `mcpb.conf` — optional bundle configuration for `mcp-bash bundle`.
- `icon.png` or `icon.svg` — optional server icon for client UIs.

## Server Hooks (server.d/)

Optional hooks in `server.d/` customize server behavior:

| Hook | Purpose | Docs |
|------|---------|------|
| `env.sh` | Inject environment variables at startup | [BEST-PRACTICES.md §3](BEST-PRACTICES.md#3-project-layout-primer) |
| `policy.sh` | Gate tool execution (allowlists, read-only mode) | [BEST-PRACTICES.md §4.2](BEST-PRACTICES.md#centralized-tool-policy-serverdpolicysh) |
| `health-checks.sh` | Verify external dependencies (CLIs, env vars) | [BEST-PRACTICES.md §4.2](BEST-PRACTICES.md#external-dependency-health-checks-serverdhealth-checkssh) |
| `register.sh` | Dynamic/imperative tool registration | [REGISTRY.md](REGISTRY.md) |
| `register.json` | Declarative tool overrides | [REGISTRY.md](REGISTRY.md) |

Example health checks:
```bash
#!/usr/bin/env bash
# server.d/health-checks.sh
mcp_health_check_command "jq" "JSON processor"
mcp_health_check_env "API_TOKEN" "Required API token"
```

## Bundle Configuration (mcpb.conf)

Optional shell-sourceable configuration for `mcp-bash bundle`:

```bash
# mcpb.conf - Bundle configuration (optional)

# Server metadata (overrides server.meta.json if set)
# MCPB_NAME="my-server"
# MCPB_VERSION="1.0.0"
# MCPB_DESCRIPTION="My MCP server built with mcp-bash"

# Author information (recommended for registry listing)
MCPB_AUTHOR_NAME="Your Name"
MCPB_AUTHOR_EMAIL="you@example.com"
MCPB_AUTHOR_URL="https://github.com/you"

# Repository URL
MCPB_REPOSITORY="https://github.com/you/my-server"

# Additional directories to include in bundle (space-separated)
# Default: tools, resources, prompts, completions, server.d, lib, providers
# MCPB_INCLUDE=".registry data/templates"
```

Values fall back to `server.d/server.meta.json`, `VERSION` file, and git config when not specified. See [docs/MCPB.md](MCPB.md) for complete bundling documentation.

Shared library convention:

```
# tools/my-tool/tool.sh
# shellcheck source=../../lib/helpers.sh disable=SC1091
source "${MCPBASH_PROJECT_ROOT}/lib/helpers.sh"
```

Keep shared code under your project roots so roots enforcement and path guards remain effective. A `lib/README.md` describing available helpers is recommended for maintainers.

Bootstrap helper note: the built-in `bootstrap/tools/getting-started/tool.sh` falls back to the repository `sdk/` when `MCP_SDK` is unset so it can run before a project is configured; scaffolded tools should rely on `MCP_SDK` being set by the framework and do not include that fallback.
