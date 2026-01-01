#!/usr/bin/env bash
# Unit: project-level provider discovery and precedence

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"
# shellcheck source=lib/resources.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/resources.sh"

test_create_tmpdir

export MCPBASH_TMP_ROOT="${TEST_TMPDIR}"
export MCPBASH_HOME="${TEST_TMPDIR}/home"
export MCPBASH_PROJECT_ROOT="${TEST_TMPDIR}/project"
export MCPBASH_PROVIDERS_DIR="${MCPBASH_PROJECT_ROOT}/providers"
export MCPBASH_RESOURCES_DIR="${MCPBASH_PROJECT_ROOT}/resources"

mkdir -p "${MCPBASH_HOME}/providers"
mkdir -p "${MCPBASH_PROVIDERS_DIR}"
mkdir -p "${MCPBASH_RESOURCES_DIR}"

# --- Test 1: Project provider is used when present ---
printf ' -> project provider takes precedence over framework provider\n'

cat >"${MCPBASH_HOME}/providers/test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'framework-provider'
EOF
chmod +x "${MCPBASH_HOME}/providers/test.sh"

cat >"${MCPBASH_PROVIDERS_DIR}/test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'project-provider'
EOF
chmod +x "${MCPBASH_PROVIDERS_DIR}/test.sh"

out="$(mcp_resources_read_via_provider "test" "test://anything")"
# assert_eq: expected, actual, message
assert_eq "project-provider" "${out}" "expected project provider to run"

# --- Test 2: Framework provider is used when no project provider ---
printf ' -> falls back to framework provider when project provider absent\n'

rm "${MCPBASH_PROVIDERS_DIR}/test.sh"

out="$(mcp_resources_read_via_provider "test" "test://anything")"
assert_eq "framework-provider" "${out}" "expected framework provider fallback"

# --- Test 3: Works when MCPBASH_PROVIDERS_DIR doesn't exist ---
printf ' -> works when providers/ directory does not exist\n'

rmdir "${MCPBASH_PROVIDERS_DIR}" 2>/dev/null || rm -rf "${MCPBASH_PROVIDERS_DIR}"

out="$(mcp_resources_read_via_provider "test" "test://anything")"
assert_eq "framework-provider" "${out}" "expected framework provider when no project dir"

# --- Test 4: Custom URI scheme with project provider ---
printf ' -> custom URI scheme works with project provider\n'

mkdir -p "${MCPBASH_PROVIDERS_DIR}"
cat >"${MCPBASH_PROVIDERS_DIR}/custom.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
uri="${1:-}"
case "${uri}" in
custom://hello)
    printf '{"message":"hello from custom provider"}'
    ;;
*)
    printf 'Unknown URI: %s\n' "${uri}" >&2
    exit 3
    ;;
esac
EOF
chmod +x "${MCPBASH_PROVIDERS_DIR}/custom.sh"

out="$(mcp_resources_read_via_provider "custom" "custom://hello")"
assert_eq '{"message":"hello from custom provider"}' "${out}" "expected custom provider output"

# --- Test 5: Provider not found in either location ---
printf ' -> returns error when provider not found anywhere\n'

# Remove both project and framework test providers
rm -f "${MCPBASH_PROVIDERS_DIR}/custom.sh" 2>/dev/null || true
rm -f "${MCPBASH_HOME}/providers/nonexistent.sh" 2>/dev/null || true

# Attempt to use non-existent provider should fail
if mcp_resources_read_via_provider "nonexistent" "nonexistent://test" 2>/dev/null; then
    test_fail "expected error for non-existent provider"
fi

printf 'project-level provider tests passed.\n'

