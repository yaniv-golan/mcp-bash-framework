# Project Structure Guide

## Why this structure

mcp-bash keeps the framework and your project separate so upgrades stay painless and your code stays yours. The project tree is intentionally small: tools, resources, prompts, optional server hooks, nothing else.

## Overview

`mcp-bash` uses a strict **framework/project separation** model. Install the framework once (e.g., `~/mcp-bash-framework` or a Docker base layer) and keep your server code in a separate **project directory**.

## The Model

```
MCPBASH_HOME (Read-Only)                   MCPBASH_PROJECT_ROOT (Your Code)
~/mcp-bash-framework/                      ~/my-mcp-server/
├── bin/mcp-bash               ────────>   ├── tools/
├── lib/                                    │   └── my-tool/
├── handlers/                               │       ├── tool.sh
└── ...                                     │       └── tool.meta.json
                                            ├── prompts/
                                            ├── resources/
                                            ├── server.d/
                                            │   └── register.sh
                                            └── .registry/  (auto-generated cache)
```

## Required configuration

Set `MCPBASH_PROJECT_ROOT` to your project directory; the server refuses to start without it.

### Example: Claude Desktop configuration

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/Users/me/mcp-bash-framework/bin/mcp-bash",
      "env": {
        "MCPBASH_PROJECT_ROOT": "/Users/me/my-mcp-server"
      }
    }
  }
}
```

### Example: Docker deployment

```dockerfile
FROM debian:bookworm-slim

# Install framework (read-only layer)
COPY mcp-bash-framework/ /mcp-bash-framework/

# Copy project (writable layer)
COPY my-server/ /app/

ENV MCPBASH_PROJECT_ROOT=/app

CMD ["/mcp-bash-framework/bin/mcp-bash"]
```

## Path resolution

The framework resolves directories in this order:

| Content Type | Variable | Default |
|--------------|----------|---------|
| Tools | `MCPBASH_TOOLS_DIR` | `$MCPBASH_PROJECT_ROOT/tools` |
| Resources | `MCPBASH_RESOURCES_DIR` | `$MCPBASH_PROJECT_ROOT/resources` |
| Prompts | `MCPBASH_PROMPTS_DIR` | `$MCPBASH_PROJECT_ROOT/prompts` |
| Server Hooks | `MCPBASH_SERVER_DIR` | `$MCPBASH_PROJECT_ROOT/server.d` |
| Registry Cache | `MCPBASH_REGISTRY_DIR` | `$MCPBASH_PROJECT_ROOT/.registry` |

Override individual directories when needed:

```bash
export MCPBASH_PROJECT_ROOT=/app
export MCPBASH_TOOLS_DIR=/app/tools-v2      # Override tools location
export MCPBASH_PROMPTS_DIR=/shared/prompts  # Shared prompts
```

## Completions

Completions are registered via `server.d/register.sh` (not auto-discovered). A minimal example:

```bash
# server.d/register.sh
mcp_completion_manual_begin
mcp_completion_register_manual '{"name":"example.completion","path":"completions/example.sh","timeoutSecs":5}'
mcp_completion_manual_finalize
```

Paths in `path` are resolved relative to `MCPBASH_PROJECT_ROOT`. Registry refresh will load the completions registry and make names available to `completion/complete`.

## Tool SDK discovery

`lib/tools.sh` exports `MCP_SDK` to the framework's `sdk/` directory so tools can `source "${MCP_SDK}/tool-sdk.sh"`. Templates fall back to resolving `sdk/` relative to the script when executed directly. When copying tools into another tree, set `MCP_SDK` yourself (see [SDK Discovery](../README.md#sdk-discovery)) to keep helpers locatable.

## Example project layouts

### Minimal project

```
my-server/
├── tools/
│   └── hello/
│       ├── tool.sh
│       └── tool.meta.json
└── .registry/  (created automatically)
```

Create this structure:

```bash
mkdir -p my-server/tools
export MCPBASH_PROJECT_ROOT=$(pwd)/my-server
~/mcp-bash-framework/bin/mcp-bash scaffold tool hello
```

### Full-featured project

```
my-devops-server/
├── tools/
│   ├── check-k8s/
│   ├── deploy-app/
│   └── rollback/
├── prompts/
│   └── incident-response/
├── resources/
│   └── deployment-history/
├── server.d/
│   └── register.sh
├── lib/
│   └── common.sh          # Your shared utilities
└── .registry/             (auto-generated)
```

### Multi-environment project

```
company-mcp-servers/
├── dev/
│   ├── tools/
│   └── resources/
├── staging/
│   ├── tools/
│   └── resources/
└── production/
    ├── tools/
    └── resources/
```

Configure each environment:

```json
{
  "mcpServers": {
    "dev": {
      "command": "/Users/me/mcp-bash-framework/bin/mcp-bash",
      "env": {
        "MCPBASH_PROJECT_ROOT": "/projects/company-mcp-servers/dev"
      }
    },
    "production": {
      "command": "/Users/me/mcp-bash-framework/bin/mcp-bash",
      "env": {
        "MCPBASH_PROJECT_ROOT": "/projects/company-mcp-servers/production"
      }
    }
  }
}
```

## Version control strategy

Keep your project under version control, but not the framework.

```bash
# Your project repository
my-server/
├── .git/
├── tools/
├── prompts/
├── .gitignore   # Add: .registry/
└── README.md
```

`.gitignore`:
```
.registry/
*.log
```

Upgrade steps:

```bash
# Upgrade framework
cd ~/mcp-bash-framework
git pull

# Your project is unaffected
cd ~/my-server
git status  # Clean
```

## Debugging path resolution

Set `MCPBASH_LOG_LEVEL=debug` to print resolved paths at startup:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/Users/me/mcp-bash-framework/bin/mcp-bash",
      "env": {
        "MCPBASH_PROJECT_ROOT": "/Users/me/my-server",
        "MCPBASH_LOG_LEVEL": "debug"
      }
    }
  }
}
```

Expected output:

```
Resolved paths:
  MCPBASH_HOME=/Users/me/mcp-bash-framework
  MCPBASH_PROJECT_ROOT=/Users/me/my-server
  MCPBASH_TOOLS_DIR=/Users/me/my-server/tools
  MCPBASH_RESOURCES_DIR=/Users/me/my-server/resources
  MCPBASH_PROMPTS_DIR=/Users/me/my-server/prompts
  MCPBASH_REGISTRY_DIR=/Users/me/my-server/.registry
```

## Benefits of this model

1. **Clean upgrades**: Update the framework without touching your code
2. **Version control**: Track your project separately from the framework
3. **Read-only installs**: Framework can live in `/opt`, Docker layers, or NFS mounts
4. **Multi-project**: Run multiple servers from one framework installation
5. **Security**: Framework and project can have different permissions
