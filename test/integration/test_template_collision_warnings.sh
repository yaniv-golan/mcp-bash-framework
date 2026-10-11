#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Registered templates are checked against resources without a spurious 'registry unavailable' warning."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq
test_create_tmpdir

failures=0
fail() {
	printf 'FAIL: %s\n' "$1" >&2
	failures=$((failures + 1))
}

# $1: register.sh or register.json; $2: template name. One auto-discovered
# static resource named "a". Prints "templates|warnings".
run_case() {
	local how="$1" template_name="$2"
	local ws="${TEST_TMPDIR}/${how}-${template_name}"
	test_stage_workspace "${ws}"
	rm -f "${ws}/server.d/register.sh" "${ws}/server.d/register.json"
	rm -rf "${ws}/resources"
	mkdir -p "${ws}/resources"
	printf 'x\n' >"${ws}/resources/a.txt"
	printf '{"name": "a", "uri": "file://%s/resources/a.txt"}\n' "${ws}" >"${ws}/resources/a.meta.json"
	local template
	template="{\"name\": \"${template_name}\", \"uriTemplate\": \"file:///tmp/{x}\"}"
	case "${how}" in
	sh)
		printf '#!/usr/bin/env bash\nmcp_resources_templates_register_manual %q\n' "${template}" >"${ws}/server.d/register.sh"
		chmod +x "${ws}/server.d/register.sh"
		;;
	json)
		printf '{"version": 1, "resourceTemplates": [%s]}\n' "${template}" >"${ws}/server.d/register.json"
		;;
	esac
	chmod -R go-w "${ws}"
	cat <<'JSON' >"${ws}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"templates","method":"resources/templates/list","params":{}}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
JSON
	test_run_mcp "${ws}" "${ws}/requests.ndjson" "${ws}/responses.ndjson"
	assert_json_lines "${ws}/responses.ndjson"
	local templates warnings
	templates="$(jq -c 'select(.id=="templates") | [.result.resourceTemplates[].name]' "${ws}/responses.ndjson")"
	warnings="$(jq -r 'select(.method=="notifications/message" and .params.level=="warning") | .params.data | tostring' "${ws}/responses.ndjson")"
	printf '%s|%s' "${templates}" "${warnings}"
}

for how in sh json; do
	# No collision: the template is kept and nothing claims the resource
	# registry is unavailable.
	out="$(run_case "${how}" t1)"
	[ "${out%%|*}" = '["t1"]' ] || fail "${how}: templates are ${out%%|*}, expected [\"t1\"]"
	case "${out#*|}" in
	*"registry unavailable"*) fail "${how}: spurious warning: ${out#*|}" ;;
	esac
	# A real collision is still caught once the resources are known.
	out="$(run_case "${how}" a)"
	[ "${out%%|*}" = '[]' ] || fail "${how}: colliding template kept: ${out%%|*}"
	case "${out#*|}" in
	*"conflicts with existing resource 'a'"*) ;;
	*) fail "${how}: no conflict warning; warnings were: ${out#*|}" ;;
	esac
	case "${out#*|}" in
	*"registry unavailable"*) fail "${how}: spurious warning with a collision: ${out#*|}" ;;
	esac
done

if [ "${failures}" -gt 0 ]; then
	test_fail "${failures} template collision check(s) failed"
fi
printf ' -> collisions caught, no spurious registry warning\n'
