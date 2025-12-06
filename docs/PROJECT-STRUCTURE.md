# Shared Libraries Convention

Projects can share reusable bash helpers by placing them under `lib/` and sourcing via `MCPBASH_PROJECT_ROOT`, for example:

```
# tools/my-tool/tool.sh
# shellcheck source=../../lib/helpers.sh disable=SC1091
source "${MCPBASH_PROJECT_ROOT}/lib/helpers.sh"
```

Keep shared code under your project roots so roots enforcement and path guards remain effective. A `lib/README.md` describing available helpers is recommended for maintainers.
