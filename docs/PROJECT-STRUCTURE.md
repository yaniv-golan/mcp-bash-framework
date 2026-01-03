# Project Structure

Minimum layout for an MCP-Bash project:

- `server.d/server.meta.json` — required server metadata (name/title/version/etc.).
- `tools/` — tool directories (`<tool>/tool.sh` + `<tool>/tool.meta.json`).
- `resources/` — resource providers and metadata.
- `prompts/` — prompt templates and metadata.
- `.registry/` — auto-generated registries (ignored by VCS).
- `lib/` — optional shared helpers you source from tools/resources/prompts.
- `mcpb.conf` — optional bundle configuration for `mcp-bash bundle`.
- `icon.png` or `icon.svg` — optional server icon for client UIs.

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

# Files to exclude from bundle (space-separated patterns)
# MCPB_EXCLUDE="*.log .git test/"
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
