#!/usr/bin/env bash
set -euo pipefail

# Minimal demo completion script.
# Reads MCP_COMPLETION_ARGS_FILE and returns suggestions based on `.query` / `.prefix`.

bin="${MCPBASH_JSON_TOOL_BIN:-jq}"
# The request arguments arrive in a file (MCP_COMPLETION_ARGS_FILE).
query=""
if [ -f "${MCP_COMPLETION_ARGS_FILE:-}" ]; then
	query="$("${bin}" -r '(.query // .prefix // "")' <"${MCP_COMPLETION_ARGS_FILE}" 2>/dev/null || printf '')"
fi

# Small static catalog; filter by substring.
cat <<'JSON' | "${bin}" -c --arg q "${query}" '
	[.[] | select(($q == "") or (. | contains($q)))]
	| .[0:3]
'
["retry","review","reset","rebase","reflog","remote"]
JSON
