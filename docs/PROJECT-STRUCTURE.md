# Project Structure

Minimum layout for an MCP-Bash project:

- `server.d/server.meta.json` — required server metadata (name/title/version/etc.).
- `tools/` — tool directories (`<tool>/tool.sh` + `<tool>/tool.meta.json`).
- `resources/` — resource providers and metadata.
- `prompts/` — prompt templates and metadata.
- `.registry/` — auto-generated registries (ignored by VCS).
- `lib/` — optional shared helpers you source from tools/resources/prompts.

Shared library convention:

```
# tools/my-tool/tool.sh
# shellcheck source=../../lib/helpers.sh disable=SC1091
source "${MCPBASH_PROJECT_ROOT}/lib/helpers.sh"
```

Keep shared code under your project roots so roots enforcement and path guards remain effective. A `lib/README.md` describing available helpers is recommended for maintainers.

Bootstrap helper note: the built-in `bootstrap/tools/getting-started/tool.sh` falls back to the repository `sdk/` when `MCP_SDK` is unset so it can run before a project is configured; scaffolded tools should rely on `MCP_SDK` being set by the framework and do not include that fallback.
