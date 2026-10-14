#!/usr/bin/env bash
# Every shipped script must parse with bash 3.2 (/bin/bash on macOS, what GUI
# hosts launch). Its parser differs: an apostrophe in a comment inside $(...)
# ends the substitution, for one. Run by test/lint.sh where /bin/bash is 3.2
# and by the bash32-macos CI job.
# Usage: test/parse-bash32.sh [BASH]   (default /bin/bash)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash32="${1:-/bin/bash}"
if ! "${bash32}" -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' 2>/dev/null; then
	printf 'parse-bash32: %s is not bash 3.2; skipped\n' "${bash32}"
	exit 0
fi
failed=0
while IFS= read -r script; do
	if ! "${bash32}" -n "${script}" 2>/dev/null; then
		printf 'FAIL: %s does not parse with bash 3.2\n' "${script#"${root}"/}" >&2
		"${bash32}" -n "${script}" 2>&1 | head -n 3 >&2
		failed=1
	fi
done < <(
	find "${root}/lib" "${root}/handlers" "${root}/sdk" "${root}/providers" -type f -name '*.sh' 2>/dev/null
	printf '%s\n' "${root}/bin/mcp-bash"
)
[ "${failed}" -eq 0 ] || exit 1
printf 'OK: every shipped script parses with bash 3.2\n'
