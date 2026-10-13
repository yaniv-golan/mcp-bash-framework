#!/usr/bin/env bats
# Unit layer: scripts/check-release-tag.sh, the release job's tag gate.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

# A repository with origin/main, origin/1.x and origin/release/2.0.0, each
# with its own VERSION commit, plus a commit on no branch.
setup() {
	SCRIPT="${MCPBASH_HOME}/scripts/check-release-tag.sh"
	REPO="${BATS_TEST_TMPDIR}/repo"
	git init -q "${REPO}"
	cd "${REPO}"
	git config user.email t@example.com
	git config user.name t
	git config commit.gpgsign false

	commit_version() {
		printf '%s\n' "$1" >VERSION
		git add VERSION
		git commit -q -m "$1"
		git rev-parse HEAD
	}
	MAIN="$(commit_version 1.9.3)"
	git update-ref refs/remotes/origin/main "${MAIN}"
	git update-ref refs/remotes/origin/1.x "$(commit_version 1.9.4)"
	git checkout -q "${MAIN}"
	BETA="$(commit_version 2.0.0-beta.1)"
	git update-ref refs/remotes/origin/release/2.0.0 "${BETA}"
	git checkout -q "${MAIN}"
	STRAY="$(commit_version 1.9.5)"
	STRAY_BETA="$(commit_version 2.0.0-rc.1)"
	ONX="$(git rev-parse refs/remotes/origin/1.x)"
	# A release-shaped VERSION on the release branch.
	git checkout -q "${BETA}"
	FINAL_ON_RELEASE="$(commit_version 2.0.0)"
	git update-ref refs/remotes/origin/release/2.0.0 "${FINAL_ON_RELEASE}"
}

@test "check-release-tag: a release on main" {
	run bash "${SCRIPT}" v1.9.3 "${MAIN}"
	assert_success
	assert_output --partial 'prerelease=false'
}

@test "check-release-tag: a release on 1.x" {
	run bash "${SCRIPT}" v1.9.4 "${ONX}"
	assert_success
	assert_output --partial 'prerelease=false'
}

@test "check-release-tag: a prerelease on a release/* branch" {
	run bash "${SCRIPT}" v2.0.0-beta.1 "${BETA}"
	assert_success
	assert_output --partial 'prerelease=true'
}

@test "check-release-tag: a release on a release/* branch is refused" {
	run bash "${SCRIPT}" v2.0.0 "${FINAL_ON_RELEASE}"
	assert_failure
	assert_output --partial 'must be on main or 1.x'
}

@test "check-release-tag: a commit on no release branch is refused" {
	run bash "${SCRIPT}" v1.9.5 "${STRAY}"
	assert_failure
	run bash "${SCRIPT}" v2.0.0-rc.1 "${STRAY_BETA}"
	assert_failure
	assert_output --partial 'not on main, 1.x or a release/* branch'
}

@test "check-release-tag: VERSION must match the tag" {
	run bash "${SCRIPT}" v1.9.2 "${MAIN}"
	assert_failure
	assert_output --partial "VERSION at the tagged commit is '1.9.3'"
}

@test "check-release-tag: malformed tags are refused" {
	for tag in 1.9.3 v1.9 v1.9.3- v1.9.3_beta vX.Y.Z; do
		run bash "${SCRIPT}" "${tag}" "${MAIN}"
		assert_failure
		assert_output --partial 'is not vX.Y.Z'
	done
}
