#!/usr/bin/env bash
# Unit layer: SDK JSON helpers fallback paths (no gojq/jq in PATH).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=sdk/tool-sdk.sh
# shellcheck disable=SC1091
# Top-level source is used for the jq-fallback check; the subshell below
# sources tool-sdk.sh again in a stripped PATH to exercise the manual escape.
. "${REPO_ROOT}/sdk/tool-sdk.sh"

# Shell out to an environment where jq/gojq are not discoverable, but still
# validate the produced JSON using the real jq from this environment.

REAL_JQ_BIN="${TEST_JSON_TOOL_BIN}"

run_in_minimal_json_env() {
	local script="$1"
	# Use a subshell to avoid polluting the outer environment.
	bash -c '
set -euo pipefail
REPO_ROOT="$1"
REAL_JQ_BIN="$2"

# Remove jq/gojq from PATH for the helper under test.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN

# shellcheck source=sdk/tool-sdk.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/sdk/tool-sdk.sh"

case "'"${script}"'" in
escape)
	out="$(mcp_json_escape "value \"with\" emoji 😄 and
newlines")"
	;;
obj)
	out="$(mcp_json_obj message "Hello \"World\"" empty "" unicode "snowman ☃")"
	;;
arr)
	out="$(mcp_json_arr "one" "two" "three" "" "emoji 😄")"
	;;
esac

printf "%s\n" "${out}"
' _ "${REPO_ROOT}" "${REAL_JQ_BIN}"
}

printf ' -> mcp_json_escape fallback JSON is valid\n'
escaped="$(run_in_minimal_json_env escape)"
printf '%s\n' "${escaped}" | "${REAL_JQ_BIN}" -e '.' >/dev/null

printf ' -> mcp_json_obj fallback JSON is valid\n'
obj="$(run_in_minimal_json_env obj)"
printf '%s\n' "${obj}" | "${REAL_JQ_BIN}" -e '.' >/dev/null

printf ' -> mcp_json_arr fallback JSON is valid\n'
arr="$(run_in_minimal_json_env arr)"
printf '%s\n' "${arr}" | "${REAL_JQ_BIN}" -e '.' >/dev/null

printf ' -> mcp_json_escape uses jq fallback when MCPBASH_JSON_TOOL_BIN is unset\n'
unset MCPBASH_JSON_TOOL_BIN
escaped_jq="$(mcp_json_escape 'via jq fallback')"
printf '%s\n' "${escaped_jq}" | "${REAL_JQ_BIN}" -e '.' >/dev/null

printf 'SDK JSON helper fallback tests passed.\n'
