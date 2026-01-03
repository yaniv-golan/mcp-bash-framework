#!/usr/bin/env bash
# Render README.md from README.md.in using VERSION as source of truth.
#
# This keeps versioned install snippets current without hard-coding checksums.
#
# Usage:
#   scripts/render-readme.sh            # writes README.md if needed
#   scripts/render-readme.sh --check    # exits non-zero if README.md is stale
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

check_only=0
explicit_version=""
while [ $# -gt 0 ]; do
	case "$1" in
	--check)
		check_only=1
		shift
		;;
	--version)
		if [ -z "${2:-}" ]; then
			printf 'render-readme: --version requires a value\n' >&2
			exit 2
		fi
		explicit_version="$2"
		shift 2
		;;
	--help)
		printf 'Usage: %s [--check] [--version X.Y.Z]\n' "$0"
		exit 0
		;;
	*)
		printf 'render-readme: unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
done

template_path="${REPO_ROOT}/README.md.in"
output_path="${REPO_ROOT}/README.md"
version_path="${REPO_ROOT}/VERSION"

if [ ! -f "${template_path}" ]; then
	printf 'render-readme: missing template: %s\n' "${template_path}" >&2
	exit 2
fi

version="${explicit_version}"
if [ -z "${version}" ]; then
	if [ ! -f "${version_path}" ]; then
		printf 'render-readme: missing VERSION file: %s\n' "${version_path}" >&2
		exit 2
	fi
	version="$(tr -d '[:space:]' <"${version_path}")"
fi

if [ -z "${version}" ]; then
	printf 'render-readme: empty version\n' >&2
	exit 2
fi

version_v="v${version}"
tmp_out="$(mktemp "${TMPDIR:-/tmp}/mcpbash.readme.XXXXXX")"
trap 'rm -f "${tmp_out}" || true' EXIT

# NOTE: Keep placeholder tokens simple to avoid sed portability issues.
sed \
	-e "s/@VERSION_V@/${version_v}/g" \
	-e "s/@VERSION@/${version}/g" \
	"${template_path}" >"${tmp_out}"

if [ "${check_only}" -eq 1 ]; then
	if [ ! -f "${output_path}" ]; then
		printf 'render-readme: README.md is missing (run scripts/render-readme.sh)\n' >&2
		exit 1
	fi
	if ! cmp -s "${tmp_out}" "${output_path}"; then
		printf 'render-readme: README.md is out of date (run scripts/render-readme.sh)\n' >&2
		exit 1
	fi
	exit 0
fi

if [ -f "${output_path}" ] && cmp -s "${tmp_out}" "${output_path}"; then
	exit 0
fi

mv "${tmp_out}" "${output_path}"
trap - EXIT
printf 'Rendered README.md for version %s\n' "${version}"
