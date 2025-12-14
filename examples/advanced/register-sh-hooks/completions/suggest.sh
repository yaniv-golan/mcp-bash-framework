#!/usr/bin/env bash
set -euo pipefail

# Minimal demo completion script.
# Reads MCP_COMPLETION_ARGS_JSON and returns suggestions based on `.query` / `.prefix`.

bin="${MCPBASH_JSON_TOOL_BIN:-jq}"
args="${MCP_COMPLETION_ARGS_JSON:-{}}"
query="$(printf '%s' "${args}" | "${bin}" -r '(.query // .prefix // "")' 2>/dev/null || printf '')"

# Small static catalog; filter by substring.
cat <<'JSON' | "${bin}" -c --arg q "${query}" '
	[.[] | select(($q == "") or (. | contains($q)))]
	| .[0:3]
'
["retry","review","reset","rebase","reflog","remote"]
JSON
