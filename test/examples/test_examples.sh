#!/usr/bin/env bash
# Spec §18.2 (Examples layer): replay example workspaces with canned NDJSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"
# shellcheck source=../common/fixtures.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/fixtures.sh"

test_require_command jq

discover_examples() {
	local entry
	for entry in "${MCPBASH_HOME}/examples/"[0-9][0-9]-*; do
		[ -d "${entry}" ] || continue
		basename "${entry}"
	done
}

run_example_suite() {
	local example_id="$1"
	printf 'Example %s\n' "${example_id}"

	test_stage_example "${example_id}"
	local workdir="${MCP_TEST_WORKDIR}"

	local tool_name=""
	if command -v jq >/dev/null 2>&1 && [ -d "${MCPBASH_HOME}/examples/${example_id}/tools" ]; then
		while IFS= read -r meta_file; do
			case "${meta_file}" in
			*.json)
				tool_name="$(jq -r '.name // empty' "${meta_file}" 2>/dev/null || true)"
				;;
			*.yaml | *.yml)
				tool_name="$(grep -E '^[[:space:]]*name:' "${meta_file}" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*name:[[:space:]]*//' | tr -d '"' || true)"
				;;
			esac
			tool_name="${tool_name%$'\r'}"
			if [ -n "${tool_name}" ]; then
				break
			fi
		done < <(find "${MCPBASH_HOME}/examples/${example_id}/tools" -maxdepth 1 -type f \( -name '*.meta.json' -o -name '*.meta.yaml' -o -name '*.meta.yml' \) | sort)
	fi

	cat <<'JSON' >"${workdir}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON

	if [ -n "${tool_name}" ]; then
		printf '{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{"limit":5}}\n' >>"${workdir}/requests.ndjson"
	fi

	cat <<'JSON' >>"${workdir}/requests.ndjson"
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON

	# Use per-workspace tmp root to avoid cross-example contention.
	export MCPBASH_TMP_ROOT="${workdir}"
	unset MCPBASH_LOCK_ROOT

	test_run_mcp "${workdir}" "${workdir}/requests.ndjson" "${workdir}/responses.ndjson"
	assert_json_lines "${workdir}/responses.ndjson"

	jq -e -s '
		def by_id(id): first(.[] | select(.id == id));
		by_id("init").result.protocolVersion == "2025-06-18"
	' "${workdir}/responses.ndjson" >/dev/null

	jq -e -s --arg tool_name "${tool_name}" '
		def by_id(id): first(.[] | select(.id == id));
		(by_id("init").result.capabilities.logging != null) and
		(
			if ($tool_name | length) == 0 then
				true
			else
				((by_id("tools").result.items // by_id("tools").result.tools // []) | map(.name) | any(. == $tool_name))
			end
		)
	' "${workdir}/responses.ndjson" >/dev/null
}

examples=()
while IFS= read -r entry; do
	examples+=("${entry}")
done < <(discover_examples)

if [ "${#examples[@]}" -eq 0 ]; then
	printf 'No examples discovered under %s\n' "${MCPBASH_HOME}/examples" >&2
	exit 1
fi

for example in "${examples[@]}"; do
	run_example_suite "${example}"
done
