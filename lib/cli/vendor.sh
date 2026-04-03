#!/usr/bin/env bash
# CLI vendor command - embeds the mcp-bash runtime into a project's .mcp-bash/ directory.
#
# The vendored tree is committed to the project's git repository, eliminating
# the need for a system-wide mcp-bash install at runtime.  This is the recommended
# approach for dev teams, CI, and clients that don't support MCPB bundles.
#
# See docs/VENDORING.md for full documentation.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash vendor; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: MCPBASH_HOME (from bin/mcp-bash)

cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh disable=SC1091
. "${cli_dir}/common.sh"
# shellcheck source=embed.sh disable=SC1091
. "${cli_dir}/embed.sh"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Write vendor.json using jq/gojq when available, falling back to printf.
mcp_cli_vendor_write_lockfile() {
	local framework_dir="$1"
	local version="$2"
	local sha256="$3"
	local source_home="$4"
	local vendored_at="$5"

	local lockfile="${framework_dir}/vendor.json"

	if [[ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]] && command -v "${MCPBASH_JSON_TOOL_BIN}" >/dev/null 2>&1; then
		"${MCPBASH_JSON_TOOL_BIN}" -n \
			--arg version "${version}" \
			--arg sha256 "${sha256}" \
			--arg vendored_from "${source_home}" \
			--arg vendored_at "${vendored_at}" \
			'{version: $version, sha256: $sha256, vendored_from: $vendored_from, vendored_at: $vendored_at}' \
			>"${lockfile}"
	else
		# Minimal fallback when no JSON tool is available.
		# The 4 fields contain only safe characters (hex, paths, ISO timestamps).
		printf '{"version":"%s","sha256":"%s","vendored_from":"%s","vendored_at":"%s"}\n' \
			"${version}" "${sha256}" "${source_home}" "${vendored_at}" >"${lockfile}"
	fi
}

# Verify the sha256 in vendor.json matches a fresh hash of the vendored files.
mcp_cli_vendor_verify() {
	local output_dir="$1"
	local framework_dir="${output_dir}/.mcp-bash"

	if [[ ! -f "${framework_dir}/vendor.json" ]]; then
		printf 'vendor: no vendor.json found in %s\n' "${framework_dir}" >&2
		printf 'Run "mcp-bash vendor" first.\n' >&2
		return 1
	fi

	local recorded_sha recorded_version
	if [[ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]] && command -v "${MCPBASH_JSON_TOOL_BIN}" >/dev/null 2>&1; then
		recorded_sha="$("${MCPBASH_JSON_TOOL_BIN}" -r '.sha256 // empty' "${framework_dir}/vendor.json" 2>/dev/null)"
		recorded_version="$("${MCPBASH_JSON_TOOL_BIN}" -r '.version // empty' "${framework_dir}/vendor.json" 2>/dev/null)"
	else
		# Minimal extraction without jq: field values are simple strings
		recorded_sha="$(grep -o '"sha256":"[^"]*"' "${framework_dir}/vendor.json" | cut -d'"' -f4)"
		recorded_version="$(grep -o '"version":"[^"]*"' "${framework_dir}/vendor.json" | cut -d'"' -f4)"
	fi

	if [[ -z "${recorded_sha}" ]]; then
		printf 'vendor --verify: vendor.json is missing the sha256 field\n' >&2
		return 1
	fi

	local current_sha
	if ! current_sha="$(mcp_embed_compute_hash "${framework_dir}")"; then
		printf 'vendor --verify: no sha256 tool available (sha256sum/shasum)\n' >&2
		return 1
	fi

	if [[ "${current_sha}" == "${recorded_sha}" ]]; then
		printf 'vendor --verify: OK (version %s, sha256 %s)\n' "${recorded_version}" "${recorded_sha}"
		return 0
	else
		printf 'vendor --verify: FAILED\n' >&2
		printf '  recorded: %s\n' "${recorded_sha}" >&2
		printf '  current:  %s\n' "${current_sha}" >&2
		printf '\nThe vendored framework has been modified since it was last vendored.\n' >&2
		printf 'Run "mcp-bash vendor --upgrade" to re-vendor from the current install.\n' >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

mcp_cli_vendor() {
	local output_dir=""
	local upgrade="false"
	local verify_only="false"
	local dry_run="false"
	local verbose="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output)
			if [[ -z "${2:-}" ]]; then
				printf 'vendor: --output requires a directory path\n' >&2
				exit 1
			fi
			output_dir="$2"
			shift 2
			;;
		--upgrade)
			upgrade="true"
			shift
			;;
		--verify)
			verify_only="true"
			shift
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		--verbose)
			verbose="true"
			shift
			;;
		--help | -h)
			cat <<'EOF'
Usage: mcp-bash vendor [options]

Embed the mcp-bash runtime into .mcp-bash/ in the project directory.
Commit that directory to git so that no system install is needed at runtime.

Options:
  --output DIR   Target directory (default: MCPBASH_PROJECT_ROOT, or current directory)
  --upgrade      Re-vendor from the current install, replacing existing files
  --verify       Check that vendor.json hash matches files on disk; exit 0=ok 1=fail
  --dry-run      Show what would be copied without copying anything
  --verbose      Show each file as it is copied
  --help, -h     Show this help

After vendoring, configure your MCP client with:
  command: /path/to/project/.mcp-bash/bin/mcp-bash
  env:     MCPBASH_PROJECT_ROOT=/path/to/project
           MCPBASH_TOOL_ALLOWLIST=*

See docs/VENDORING.md for full documentation.
EOF
			exit 0
			;;
		*)
			printf 'vendor: unknown option: %s\n' "$1" >&2
			printf 'Run "mcp-bash vendor --help" for usage.\n' >&2
			exit 1
			;;
		esac
	done

	# Resolve output directory
	if [[ -z "${output_dir}" ]]; then
		output_dir="${MCPBASH_PROJECT_ROOT:-$(pwd)}"
	fi
	output_dir="$(cd "${output_dir}" && pwd)"

	local framework_dir="${output_dir}/.mcp-bash"

	# --verify mode: check existing vendor without modifying anything
	if [[ "${verify_only}" == "true" ]]; then
		mcp_cli_vendor_verify "${output_dir}"
		exit $?
	fi

	# Guard against accidental overwrite of existing vendor tree
	if [[ -d "${framework_dir}" ]] && [[ "$(ls -A "${framework_dir}" 2>/dev/null)" != "" ]] && [[ "${upgrade}" != "true" ]]; then
		if [[ -t 0 ]]; then
			printf '.mcp-bash/ already exists in %s\n' "${output_dir}"
			printf 'Use --upgrade to replace it, or --verify to check integrity.\n'
			printf 'Proceed with upgrade? [y/N] '
			local answer
			read -r answer
			case "${answer}" in
			[yY]*) upgrade="true" ;;
			*)
				printf 'Aborted.\n'
				exit 0
				;;
			esac
		else
			printf 'vendor: .mcp-bash/ already exists in %s\n' "${output_dir}" >&2
			printf 'Use --upgrade to replace it.\n' >&2
			exit 1
		fi
	fi

	# Dry-run: show what would happen
	if [[ "${dry_run}" == "true" ]]; then
		local version=""
		[[ -f "${MCPBASH_HOME}/VERSION" ]] && version="$(cat "${MCPBASH_HOME}/VERSION")"
		printf 'Would vendor mcp-bash %s from %s\n' "${version}" "${MCPBASH_HOME}"
		printf 'Into: %s\n' "${framework_dir}"
		printf '\nFiles that would be created:\n'
		printf '  .mcp-bash/bin/mcp-bash\n'
		printf '  .mcp-bash/lib/{runtime libs}\n'
		printf '  .mcp-bash/lib/cli/common.sh, .mcp-bash/lib/cli/health.sh\n'
		printf '  .mcp-bash/handlers/*.sh\n'
		printf '  .mcp-bash/sdk/tool-sdk.sh\n'
		printf '  .mcp-bash/providers/*.sh\n'
		printf '  .mcp-bash/VERSION\n'
		printf '  .mcp-bash/vendor.json (lockfile)\n'
		printf '  run-server.sh (wrapper, if not already present)\n'
		exit 0
	fi

	# Clean the target before re-populating (avoids stale files from old versions)
	if [[ -d "${framework_dir}" ]]; then
		rm -rf "${framework_dir}"
	fi

	printf 'Vendoring mcp-bash framework...\n'

	mcp_embed_framework "${output_dir}" "${verbose}"

	# Generate run-server.sh wrapper alongside the vendored tree
	if [[ ! -f "${output_dir}/run-server.sh" ]]; then
		mcp_embed_generate_wrapper "${output_dir}"
		if [[ "${verbose}" == "true" ]]; then
			printf '    Generated run-server.sh\n'
		fi
	fi

	# Compute integrity hash and write lockfile
	local version=""
	[[ -f "${framework_dir}/VERSION" ]] && version="$(cat "${framework_dir}/VERSION")"

	local sha256=""
	if sha256="$(mcp_embed_compute_hash "${framework_dir}")"; then
		:
	else
		printf '  (skipping hash: no sha256 tool available)\n'
	fi

	local vendored_at
	vendored_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u)"

	mcp_cli_vendor_write_lockfile \
		"${framework_dir}" \
		"${version}" \
		"${sha256}" \
		"${MCPBASH_HOME}" \
		"${vendored_at}"

	# Summary
	local file_count size
	file_count="$(find "${framework_dir}" -type f | wc -l | tr -d ' ')"
	size="$(du -sh "${framework_dir}" 2>/dev/null | cut -f1)"

	printf '\n\342\234\223 Vendored mcp-bash %s into %s\n' "${version}" "${framework_dir}"
	printf '  %s files, %s\n' "${file_count}" "${size}"
	if [[ -n "${sha256}" ]]; then
		printf '  sha256: %s\n' "${sha256}"
	fi
	printf '\nCommit to git:\n'
	printf '  git add .mcp-bash/ run-server.sh\n'
	printf '\nConfigure your MCP client to use the wrapper:\n'
	printf '  command: %s/run-server.sh\n' "${output_dir}"
	printf '  env MCPBASH_TOOL_ALLOWLIST: *\n'
	printf '\nOr point directly at the binary:\n'
	printf '  command: %s/.mcp-bash/bin/mcp-bash\n' "${output_dir}"
	printf '  env MCPBASH_PROJECT_ROOT: %s\n' "${output_dir}"
	printf '  env MCPBASH_TOOL_ALLOWLIST: *\n'
	printf '\nVerify integrity later with: mcp-bash vendor --verify\n'
	printf '\nAutomatic upgrades with Renovate:\n'
	printf '  Add to renovate.json: {"extends": ["github>yaniv-golan/mcp-bash-framework//renovate-preset"]}\n'
}
