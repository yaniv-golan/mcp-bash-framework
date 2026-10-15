#!/usr/bin/env bats
# Unit: `mcp-bash validate` points at tools whose annotations are exactly the
# pre-2.0 scaffold defaults (read-only, not destructive, idempotent, closed
# world): some clients call a read-only tool without asking the user. A note,
# not a warning: a tool that really is read-only has the same set, so it must
# not fail --strict.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"
	PROJ="${BATS_TEST_TMPDIR}/proj"
	(cd "${BATS_TEST_TMPDIR}" && mcp-bash new proj >/dev/null 2>&1) || skip "mcp-bash new unavailable"
	mkdir -p "${PROJ}/tools/proj-wipe"
	cat >"${PROJ}/tools/proj-wipe/tool.meta.json" <<'JSON'
{"name":"proj-wipe","description":"deletes things","inputSchema":{"type":"object","properties":{}},
 "annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}}
JSON
	printf '#!/usr/bin/env bash\nprintf "{}"\n' >"${PROJ}/tools/proj-wipe/tool.sh"
	chmod +x "${PROJ}/tools/proj-wipe/tool.sh"
}

@test "validate: the pre-2.0 scaffold annotations get a note" {
	run mcp-bash validate --project-root "${PROJ}"
	assert_output --partial "tools/proj-wipe/tool.meta.json - annotations are the pre-2.0 scaffold defaults"
}

@test "validate: a tool scaffolded with 2.0 gets no note" {
	(cd "${PROJ}" && mcp-bash scaffold tool proj-new >/dev/null 2>&1)
	[ -f "${PROJ}/tools/proj-new/tool.meta.json" ]
	run mcp-bash validate --project-root "${PROJ}"
	assert_output --partial "tools/proj-new/tool.meta.json"
	refute_output --partial "tools/proj-new/tool.meta.json - annotations are"
}

@test "validate: other annotations get no note" {
	local set
	for set in '{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true}' \
		'{"readOnlyHint":true}' '{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}'; do
		jq -c --argjson a "${set}" '.annotations = $a' "${PROJ}/tools/proj-wipe/tool.meta.json" >"${BATS_TEST_TMPDIR}/m.json"
		mv "${BATS_TEST_TMPDIR}/m.json" "${PROJ}/tools/proj-wipe/tool.meta.json"
		run mcp-bash validate --project-root "${PROJ}"
		refute_output --partial "pre-2.0 scaffold defaults"
	done
}

@test "validate: the note doesn't count as a warning, even with --strict" {
	# Only the noted tool, so --strict has nothing else to fail on.
	rm -rf "${PROJ}/tools/hello"
	run mcp-bash validate --project-root "${PROJ}" --json
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq '.warnings')" "0"
	# The symbol isn't part of the message, as for the other levels.
	assert_equal "$(printf '%s' "${output}" | jq -c '[.messages[] | select(.message | contains("pre-2.0 scaffold defaults")) | {level, start: (.message | .[0:21])}]')" \
		'[{"level":"info","start":"tools/proj-wipe/tool."}]'
	run mcp-bash validate --project-root "${PROJ}" --strict
	assert_success
}
