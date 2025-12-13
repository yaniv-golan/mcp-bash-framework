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

VERBOSE="${VERBOSE:-0}"
UNICODE="${UNICODE:-0}"

PASS_ICON="[PASS]"
FAIL_ICON="[FAIL]"
if [ "${UNICODE}" = "1" ]; then
	PASS_ICON="✅"
	FAIL_ICON="❌"
fi

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
		done < <(find "${MCPBASH_HOME}/examples/${example_id}/tools" -maxdepth 2 -type f \( -name '*.meta.json' -o -name '*.meta.yaml' -o -name '*.meta.yml' \) | sort)
	fi

	cat <<'JSON' >"${workdir}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON

	if [ -n "${tool_name}" ]; then
		printf '{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{"limit":5}}\n' >>"${workdir}/requests.ndjson"
		if [ "${example_id}" = "06-embedded-resources" ]; then
			printf '{"jsonrpc":"2.0","id":"embed-call","method":"tools/call","params":{"name":"%s","arguments":{}}}\n' "${tool_name}" >>"${workdir}/requests.ndjson"
		fi
	fi

	cat <<'JSON' >>"${workdir}/requests.ndjson"
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON

	# Keep temp roots short on Windows/Git Bash to avoid path length issues.
	# Prefer runner temp when available; otherwise fall back to TMPDIR.
	local tmp_base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
	tmp_base="${tmp_base%/}"
	export MCPBASH_TMP_ROOT="${tmp_base}"
	unset MCPBASH_LOCK_ROOT

	test_run_mcp "${workdir}" "${workdir}/requests.ndjson" "${workdir}/responses.ndjson"
	local stderr_file="${workdir}/responses.ndjson.stderr"
	if [ -f "${stderr_file}" ]; then
		# Phase 3: gate on high-signal, low-false-positive patterns.
		if grep -q -- 'mktemp: failed to create file via template' "${stderr_file}"; then
			printf '%s\n' "Example ${example_id}: detected mktemp failure in server stderr (${stderr_file})." >&2
			printf '%s\n' '--- server stderr (excerpt) ---' >&2
			tail -n 200 "${stderr_file}" >&2 || true
			printf '%s\n' '--- end server stderr ---' >&2
			return 1
		fi
		# Match the actual watchdog log line, not Bash job-control "Terminated ( ... printf ... )"
		# lines that may include the string as part of the terminated subshell command.
		if grep -Eq -- '^mcp-bash: shutdown timeout \\([0-9]+s\\) elapsed; terminating\\.$' "${stderr_file}"; then
			local timeout_line=""
			timeout_line="$(grep -m1 -E -- '^mcp-bash: shutdown timeout \\([0-9]+s\\) elapsed; terminating\\.$' "${stderr_file}" 2>/dev/null || true)"
			printf '%s\n' "Example ${example_id}: detected shutdown watchdog timeout in server stderr (${stderr_file})." >&2
			if [ -n "${timeout_line}" ]; then
				printf '%s\n' "  ${timeout_line}" >&2
			fi
			printf '%s\n' '--- server stderr (excerpt) ---' >&2
			tail -n 200 "${stderr_file}" >&2 || true
			printf '%s\n' '--- end server stderr ---' >&2
			return 1
		fi
	fi
	assert_json_lines "${workdir}/responses.ndjson"

	jq -e -s '
		def by_id(id): first(.[] | select(.id == id));
		by_id("init").result.protocolVersion == "2025-11-25"
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

	if [ "${example_id}" = "06-embedded-resources" ]; then
		jq -e -s '
			def by_id(id): first(.[] | select(.id == id));
			(by_id("embed-call").result.content // []) as $content |
			($content | map(select(.type=="resource")) | length) == 1 and
			($content | map(select(.type=="resource") | .resource.mimeType) | first) == "text/plain" and
			($content | map(select(.type=="resource") | .resource.text) | first) == "Embedded report"
		' "${workdir}/responses.ndjson" >/dev/null
	fi
}

examples=()
while IFS= read -r entry; do
	examples+=("${entry}")
done < <(discover_examples)

if [ "${#examples[@]}" -eq 0 ]; then
	printf 'No examples discovered under %s\n' "${MCPBASH_HOME}/examples" >&2
	exit 1
fi

total="${#examples[@]}"
index=1
passed=0
failed=0

for example in "${examples[@]}"; do
	printf '[%02d/%02d] %s ... ' "${index}" "${total}" "${example}"
	if run_example_suite "${example}"; then
		printf '%s\n' "${PASS_ICON}"
		passed=$((passed + 1))
	else
		printf '%s\n' "${FAIL_ICON}" >&2
		failed=$((failed + 1))
	fi
	index=$((index + 1))
done

printf '\nExamples summary: %d passed, %d failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
