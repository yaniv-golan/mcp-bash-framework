#!/usr/bin/env bash
set -euo pipefail

bin="${MCPBASH_JSON_TOOL_BIN:-jq}"
# The request arguments arrive in a file (MCP_COMPLETION_ARGS_FILE).
query=""
if [ -f "${MCP_COMPLETION_ARGS_FILE:-}" ]; then
	query="$("${bin}" -r '(.query // .prefix // "")' <"${MCP_COMPLETION_ARGS_FILE}" 2>/dev/null || printf '')"
fi

cat <<'JSON' | "${bin}" -c --arg q "${query}" '
	[.[] | select(($q == "") or (. | contains($q)))]
	| .[0:3]
'
["--help","--version","--verbose","--quiet"]
JSON
