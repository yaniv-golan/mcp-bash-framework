#!/usr/bin/env bash
set -euo pipefail

json_bin="${MCPBASH_JSON_TOOL_BIN:-}"
if [ -z "${json_bin}" ]; then
	printf '[]\n'
	exit 0
fi

args_json="${MCP_COMPLETION_ARGS_JSON:-{}}"
query="$("${json_bin}" -r '(.query // .prefix // "")' <<<"${args_json}" 2>/dev/null || printf '')"

limit="${MCP_COMPLETION_LIMIT:-5}"
offset="${MCP_COMPLETION_OFFSET:-0}"

"${json_bin}" -n -c \
	--arg query "${query}" \
	--argjson limit "${limit}" \
	--argjson offset "${offset}" '
		def matches($q):
			if ($q | length) == 0 then true
			else (.text | ascii_downcase | contains($q | ascii_downcase))
			end;

		[
			{type:"text", text:"__NAME__ task one"},
			{type:"text", text:"__NAME__ task two"},
			{type:"text", text:"__NAME__ task three"},
			{type:"text", text:"__NAME__ task four"}
		] as $all
		| ($all | map(select(matches($query)))) as $filtered
		| ($filtered[$offset:$offset+$limit]) as $page
		| {
			suggestions: $page,
			hasMore: (($offset + ($page | length)) < ($filtered | length)),
			next: (if (($offset + ($page | length)) < ($filtered | length)) then $offset + ($page | length) else null end)
		}
	'
