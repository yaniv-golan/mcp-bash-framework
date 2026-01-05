#!/usr/bin/env bats
# Unit: README.md render drift detection.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'

@test "README.md is up to date with template" {
	run bash "${BATS_TEST_DIRNAME}/../../scripts/render-readme.sh" --check
	if [ "${status}" -ne 0 ]; then
		echo "README render drift detected. Run:"
		echo "  bash ${BATS_TEST_DIRNAME}/../../scripts/render-readme.sh"
	fi
	assert_success
}
