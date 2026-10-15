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
	# The tool a 2.0 scaffold writes doesn't.
	refute_output --partial "tools/hello/tool.meta.json - annotations are"
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
	run mcp-bash validate --project-root "${PROJ}" --json
	local with_note="${output}"
	assert_equal "$(printf '%s' "${with_note}" | jq -c '[.messages[] | select(.message | contains("pre-2.0 scaffold defaults")) | .level]')" '["info"]'
	jq -c '.annotations.openWorldHint = true' "${PROJ}/tools/proj-wipe/tool.meta.json" >"${BATS_TEST_TMPDIR}/m.json"
	mv "${BATS_TEST_TMPDIR}/m.json" "${PROJ}/tools/proj-wipe/tool.meta.json"
	run mcp-bash validate --project-root "${PROJ}" --json
	assert_equal "$(printf '%s' "${with_note}" | jq '.warnings')" "$(printf '%s' "${output}" | jq '.warnings')"
	# --strict passes or fails the same with the note as without it.
	local st_without st_with
	run mcp-bash validate --project-root "${PROJ}" --strict
	st_without="${status}"
	jq -c '.annotations.openWorldHint = false' "${PROJ}/tools/proj-wipe/tool.meta.json" >"${BATS_TEST_TMPDIR}/m.json"
	mv "${BATS_TEST_TMPDIR}/m.json" "${PROJ}/tools/proj-wipe/tool.meta.json"
	run mcp-bash validate --project-root "${PROJ}" --strict
	st_with="${status}"
	assert_equal "${st_with}" "${st_without}"
}
