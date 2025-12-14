#!/usr/bin/env bash
set -euo pipefail

bin="${MCPBASH_JSON_TOOL_BIN:-jq}"
args="${MCP_COMPLETION_ARGS_JSON:-{}}"
query="$(printf '%s' "${args}" | "${bin}" -r '(.query // .prefix // "")' 2>/dev/null || printf '')"

cat <<'JSON' | "${bin}" -c --arg q "${query}" '
	[.[] | select(($q == "") or (. | contains($q)))]
	| .[0:3]
'
["--help","--version","--verbose","--quiet"]
JSON
