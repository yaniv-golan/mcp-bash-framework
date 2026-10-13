#!/usr/bin/env bash
# Decide whether a version tag can be released, and whether as a prerelease.
# Run by the release job in CI; tested by test/unit/check_release_tag.bats.
#
# Usage: scripts/check-release-tag.sh TAG [COMMIT]
#   TAG     vMAJOR.MINOR.PATCH, or vMAJOR.MINOR.PATCH-PRERELEASE (e.g. v2.0.0-beta.1)
#   COMMIT  the tagged commit (default HEAD)
#
# Rules:
# - VERSION at COMMIT must equal the tag without its "v".
# - A release (no "-") must be on origin/main or origin/1.x, so Homebrew only
#   ever points at merged code.
# - A prerelease may also be on an origin/release/* branch (2.0 betas).
# Prints "prerelease=true" or "prerelease=false" (GitHub Actions output
# format) and exits 0, or prints the reason to stderr and exits 1.
set -euo pipefail

tag="${1:-}"
commit="${2:-HEAD}"

fail() {
	printf 'check-release-tag: %s\n' "$1" >&2
	exit 1
}

semver='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.]*)?$'
[[ "${tag}" =~ ${semver} ]] || fail "tag '${tag}' is not vX.Y.Z or vX.Y.Z-PRERELEASE"
version="${tag#v}"

file_version="$(git show "${commit}:VERSION" 2>/dev/null | tr -d '[:space:]')" \
	|| fail "no VERSION file at ${commit}"
[ "${file_version}" = "${version}" ] \
	|| fail "VERSION at the tagged commit is '${file_version}', but the tag says '${version}'"

prerelease=false
case "${version}" in
*-*) prerelease=true ;;
esac

branches="refs/remotes/origin/main refs/remotes/origin/1.x"
if [ "${prerelease}" = "true" ]; then
	branches="${branches} $(git for-each-ref --format='%(refname)' 'refs/remotes/origin/release/' | tr '\n' ' ')"
fi
on=""
for ref in ${branches}; do
	git show-ref --verify --quiet "${ref}" || continue
	if git merge-base --is-ancestor "${commit}" "${ref}"; then
		on="${ref#refs/remotes/origin/}"
		break
	fi
done
if [ -z "${on}" ]; then
	if [ "${prerelease}" = "true" ]; then
		fail "the tagged commit is not on main, 1.x or a release/* branch"
	fi
	fail "a release tag must be on main or 1.x (prereleases, with a '-', may be on release/*)"
fi
printf 'check-release-tag: %s on %s (prerelease: %s)\n' "${tag}" "${on}" "${prerelease}" >&2
printf 'prerelease=%s\n' "${prerelease}"
