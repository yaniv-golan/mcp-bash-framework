#!/usr/bin/env bash
# Regenerate TESTING.md from canonical test entrypoints.

set -euo pipefail

print_block() {
	local title="$1"
	shift
	printf '## %s\n\n' "${title}"
	for cmd in "$@"; do
		printf '```\n%s\n```\n\n' "${cmd}"
	done
}

cat <<'EOF'
# Testing Guide

EOF

print_block "Linting" "./test/lint.sh"
print_block "Smoke Tests" "./test/smoke.sh"
print_block "Unit Tests" "./test/unit/run.sh"
print_block "Integration Tests" "./test/integration/run.sh"
print_block "Examples Suite" "./test/examples/run.sh"
print_block "Compatibility Suite" "./test/compatibility/run.sh"
print_block "Stress Suite" "./test/stress/run.sh"

cat <<'EOF'
Regenerate this file with:
```
scripts/generate-testing-docs.sh > TESTING.md
```
EOF
