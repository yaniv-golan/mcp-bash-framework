#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Windows/Git Bash: completion/resources/prompts survive large environments (E2BIG mitigation)."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

case "$(uname -s 2>/dev/null || printf '')" in
MINGW* | MSYS* | CYGWIN*) : ;;
*)
	# This test is specifically about MSYS/Git Bash exec limits.
	exit 0
	;;
esac

test_create_tmpdir

inflate_environment() {
	# Build a large environment without breaking PATH resolution for mcp-bash.
	# Keep this deterministic and fast (CI on Windows can be slow).
	local i=0
	local base_path="${PATH:-}"
	local extra_path=""

	while [ "${i}" -lt 800 ]; do
		extra_path="${extra_path}:/x${i}"
		i=$((i + 1))
	done
	PATH="${base_path}${extra_path}"
	export PATH

	local payload="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
	i=0
	while [ "${i}" -lt 200 ]; do
		export "MCPBASH_TEST_ENV_DUMMY_${i}=${payload}"
		i=$((i + 1))
	done
}

ROOT="${TEST_TMPDIR}/workspace"
test_stage_workspace "${ROOT}"

mkdir -p "${ROOT}/completions"

cat <<'JSON' >"${ROOT}/server.d/register.json"
{
  "version": 1,
  "completions": [
    {"name": "example", "path": "completions/suggest.sh", "timeoutSecs": 5}
  ]
}
JSON

cat <<'SH' >"${ROOT}/completions/suggest.sh"
#!/usr/bin/env bash
set -euo pipefail

dummy="absent"
if [ -n "${MCPBASH_TEST_ENV_DUMMY_1-}" ]; then
	dummy="present"
fi

count=0
for k in $(compgen -e); do
	count=$((count + 1))
done

printf '{"suggestions":["dummy:%s","count:%s"],"hasMore":false}\n' "${dummy}" "${count}"
SH

# Intentionally do NOT chmod +x to exercise the Windows execute-bit fallback.
chmod -x "${ROOT}/completions/suggest.sh" 2>/dev/null || true

mkdir -p "${ROOT}/prompts"
cat <<'EOF_PROMPT' >"${ROOT}/prompts/alpha.txt"
Hello {{name}}!
EOF_PROMPT
cat <<'EOF_META' >"${ROOT}/prompts/alpha.meta.json"
{"name": "prompt.alpha", "description": "Alpha prompt", "arguments": {"type": "object", "properties": {"name": {"type": "string"}}}, "role": "system"}
EOF_META

mkdir -p "${ROOT}/resources"
printf 'hello-resource' >"${ROOT}/resources/data.txt"
resource_uri="file://${ROOT}/resources/data.txt"

cat <<JSON >"${ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"c1","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"example"},"argument":{"name":"query","value":"x"},"limit":2}}
{"jsonrpc":"2.0","id":"r1","method":"resources/read","params":{"uri":"${resource_uri}"}}
{"jsonrpc":"2.0","id":"p1","method":"prompts/get","params":{"name":"prompt.alpha","arguments":{"name":"World"}}}
JSON

cat <<JSON >"${ROOT}/requests_completion_only.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"c1","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"example"},"argument":{"name":"query","value":"x"},"limit":2}}
JSON

# Inflate the environment once (persistently) to keep the test fast while still
# exercising large-env behavior for both run cases.
inflate_environment

run_case() {
	local label="$1"
	local request_file="${2:-requests.ndjson}"
	local provider_mode="${3:-}"
	local provider_allowlist="${4:-}"
	(
		cd "${ROOT}" || exit 1
		if [ -n "${provider_mode}" ]; then
			export MCPBASH_PROVIDER_ENV_MODE="${provider_mode}"
		else
			unset MCPBASH_PROVIDER_ENV_MODE 2>/dev/null || true
		fi
		if [ -n "${provider_allowlist}" ]; then
			export MCPBASH_PROVIDER_ENV_ALLOWLIST="${provider_allowlist}"
		else
			unset MCPBASH_PROVIDER_ENV_ALLOWLIST 2>/dev/null || true
		fi

		MCPBASH_PROJECT_ROOT="${ROOT}" ./bin/mcp-bash <"${request_file}" >"responses_${label}.ndjson"
	)
}

run_case "isolate" "requests.ndjson" "isolate"
# Only exercise completion in allowlist mode (resource/prompt paths are already
# covered by the isolate case above; this keeps the test within Windows CI time budgets).
run_case "allowlist" "requests_completion_only.ndjson" "allowlist" "MCPBASH_TEST_ENV_DUMMY_1"

# --- Verify completion provider env scrubbing ---
resp_isolate="$(grep '"id":"c1"' "${ROOT}/responses_isolate.ndjson" | head -n1)"
dummy_isolate="$(printf '%s' "${resp_isolate}" | jq -r '.result.completion.values[0] // empty')"
assert_eq "dummy:absent" "${dummy_isolate}" "expected dummy env var to be scrubbed in isolate mode"

resp_allow="$(grep '"id":"c1"' "${ROOT}/responses_allowlist.ndjson" | head -n1)"
dummy_allow="$(printf '%s' "${resp_allow}" | jq -r '.result.completion.values[0] // empty')"
assert_eq "dummy:present" "${dummy_allow}" "expected allowlisted dummy env var to be present in allowlist mode"

# --- Verify resources/read still succeeds under large env ---
res_read="$(grep '"id":"r1"' "${ROOT}/responses_isolate.ndjson" | head -n1)"
if printf '%s' "${res_read}" | jq -e '.error' >/dev/null 2>&1; then
	test_fail "resources/read failed under large env (isolate)"
fi
res_text="$(printf '%s' "${res_read}" | jq -r '.result.contents[0].text // empty')"
assert_contains "hello-resource" "${res_text}" "expected resource contents"

# --- Verify prompts/get still succeeds under large env ---
prompt_get="$(grep '"id":"p1"' "${ROOT}/responses_isolate.ndjson" | head -n1)"
if printf '%s' "${prompt_get}" | jq -e '.error' >/dev/null 2>&1; then
	test_fail "prompts/get failed under large env (isolate)"
fi
prompt_text="$(printf '%s' "${prompt_get}" | jq -r '.result.text // empty')"
assert_contains "Hello World!" "${prompt_text}" "expected rendered prompt"
