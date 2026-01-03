#!/usr/bin/env bash
# CLI publish command - submits MCPB bundles to the MCP Registry.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash publish; BASH_VERSION missing\n' >&2
	exit 1
fi

# Source common helpers
cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh disable=SC1091
. "${cli_dir}/common.sh"

# MCP Registry API endpoint
MCP_REGISTRY_URL="${MCP_REGISTRY_URL:-https://registry.modelcontextprotocol.io}"

mcp_publish_usage() {
	cat <<'EOF'
Usage:
  mcp-bash publish <bundle.mcpb> [options]

Submit an MCPB bundle to the MCP Registry for public listing.

Options:
  --dry-run          Validate without submitting
  --token TOKEN      API token (or set MCP_REGISTRY_TOKEN env var)
  --verbose          Show detailed progress
  --help, -h         Show this help

Prerequisites:
  1. Create an account at https://registry.modelcontextprotocol.io/
  2. Generate an API token in your account settings
  3. Set MCP_REGISTRY_TOKEN environment variable or use --token

Examples:
  mcp-bash publish my-server-1.0.0.mcpb
  mcp-bash publish my-server-1.0.0.mcpb --dry-run
  mcp-bash publish my-server-1.0.0.mcpb --token xxx

The registry will:
  - Validate your bundle structure and manifest
  - Check for naming conflicts
  - List your server for discovery by Claude Desktop users
EOF
	exit 0
}

mcp_publish_validate_bundle() {
	local bundle_path="$1"
	local verbose="$2"

	# Check file exists
	if [ ! -f "${bundle_path}" ]; then
		printf '  \342\234\227 Bundle file not found: %s\n' "${bundle_path}" >&2
		return 1
	fi

	# Check file extension
	if [[ "${bundle_path}" != *.mcpb ]]; then
		printf '  \342\234\227 Invalid file extension (expected .mcpb): %s\n' "${bundle_path}" >&2
		return 1
	fi

	# Check it's a valid ZIP
	if ! unzip -t "${bundle_path}" >/dev/null 2>&1; then
		printf '  \342\234\227 Invalid archive format (not a valid ZIP): %s\n' "${bundle_path}" >&2
		return 1
	fi

	# Extract and validate manifest
	local tmp_dir
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mcpb-validate.XXXXXX")"
	trap 'rm -rf "${tmp_dir}"' RETURN

	unzip -q "${bundle_path}" manifest.json -d "${tmp_dir}" 2>/dev/null || {
		printf '  \342\234\227 Bundle missing manifest.json\n' >&2
		return 1
	}

	# Validate manifest fields
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		local manifest="${tmp_dir}/manifest.json"

		# Required fields
		local name version description
		name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' "${manifest}" 2>/dev/null)"
		version="$("${MCPBASH_JSON_TOOL_BIN}" -r '.version // empty' "${manifest}" 2>/dev/null)"
		description="$("${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' "${manifest}" 2>/dev/null)"

		if [ -z "${name}" ]; then
			printf '  \342\234\227 Manifest missing required field: name\n' >&2
			return 1
		fi
		if [ -z "${version}" ]; then
			printf '  \342\234\227 Manifest missing required field: version\n' >&2
			return 1
		fi
		if [ -z "${description}" ]; then
			printf '  \342\234\227 Manifest missing required field: description\n' >&2
			return 1
		fi

		# Validate author (required by MCPB spec)
		local author_name
		author_name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.author.name // empty' "${manifest}" 2>/dev/null)"
		if [ -z "${author_name}" ]; then
			printf '  \342\232\240 Warning: author.name is missing (required for registry listing)\n' >&2
		fi

		if [ "${verbose}" = "true" ]; then
			printf '  \342\234\223 Manifest validated: %s v%s\n' "${name}" "${version}"
		fi
	fi

	return 0
}

mcp_publish_submit() {
	local bundle_path="$1"
	local token="$2"
	local verbose="$3"

	local bundle_name
	bundle_name="$(basename "${bundle_path}")"

	# Check for curl
	if ! command -v curl >/dev/null 2>&1; then
		printf '  \342\234\227 curl command not found (required for publishing)\n' >&2
		return 1
	fi

	printf 'Submitting %s to MCP Registry...\n' "${bundle_name}"

	# Upload bundle
	local response
	local http_code
	response="$(mktemp)"
	http_code="$(
		curl -s -w '%{http_code}' \
			-X POST \
			-H "Authorization: Bearer ${token}" \
			-H "Content-Type: application/octet-stream" \
			-H "X-Bundle-Name: ${bundle_name}" \
			--data-binary "@${bundle_path}" \
			"${MCP_REGISTRY_URL}/api/v1/bundles" \
			-o "${response}"
	)"

	case "${http_code}" in
	200 | 201)
		printf '  \342\234\223 Bundle submitted successfully\n'
		if [ "${verbose}" = "true" ] && [ -s "${response}" ]; then
			cat "${response}"
		fi
		rm -f "${response}"
		return 0
		;;
	401)
		printf '  \342\234\227 Authentication failed - check your API token\n' >&2
		rm -f "${response}"
		return 1
		;;
	409)
		printf '  \342\234\227 Conflict - bundle with this name/version already exists\n' >&2
		rm -f "${response}"
		return 1
		;;
	422)
		printf '  \342\234\227 Validation failed - bundle does not meet registry requirements\n' >&2
		if [ -s "${response}" ]; then
			cat "${response}" >&2
		fi
		rm -f "${response}"
		return 1
		;;
	*)
		printf '  \342\234\227 Registry request failed (HTTP %s)\n' "${http_code}" >&2
		if [ -s "${response}" ]; then
			cat "${response}" >&2
		fi
		rm -f "${response}"
		return 1
		;;
	esac
}

mcp_cli_publish() {
	local bundle_path=""
	local token="${MCP_REGISTRY_TOKEN:-}"
	local dry_run="false"
	local verbose="false"

	# Parse arguments
	while [ $# -gt 0 ]; do
		case "$1" in
		--dry-run)
			dry_run="true"
			;;
		--token)
			shift
			token="${1:-}"
			;;
		--verbose)
			verbose="true"
			;;
		--help | -h)
			mcp_publish_usage
			;;
		-*)
			printf 'Unknown option: %s\n' "$1" >&2
			printf 'Run "mcp-bash publish --help" for usage\n' >&2
			exit 2
			;;
		*)
			if [ -z "${bundle_path}" ]; then
				bundle_path="$1"
			else
				printf 'Unexpected argument: %s\n' "$1" >&2
				exit 2
			fi
			;;
		esac
		shift
	done

	# Validate arguments
	if [ -z "${bundle_path}" ]; then
		printf 'Error: bundle path required\n' >&2
		printf 'Usage: mcp-bash publish <bundle.mcpb>\n' >&2
		exit 2
	fi

	# Initialize runtime for JSON tooling
	require_bash_runtime
	initialize_runtime_paths
	mcp_runtime_detect_json_tool

	# Validate bundle
	printf 'Validating bundle...\n'
	if ! mcp_publish_validate_bundle "${bundle_path}" "${verbose}"; then
		printf '\n\342\234\227 Bundle validation failed.\n' >&2
		exit 1
	fi
	printf '  \342\234\223 Bundle structure valid\n'

	# Dry run stops here
	if [ "${dry_run}" = "true" ]; then
		printf '\n\342\234\223 Dry run complete. Bundle is ready for publishing.\n'
		exit 0
	fi

	# Check for token
	if [ -z "${token}" ]; then
		printf '\n\342\234\227 API token required for publishing.\n' >&2
		printf '\nTo get a token:\n' >&2
		printf '  1. Create an account at %s/\n' "${MCP_REGISTRY_URL}" >&2
		printf '  2. Generate an API token in your account settings\n' >&2
		printf '  3. Set MCP_REGISTRY_TOKEN env var or use --token\n' >&2
		exit 1
	fi

	# Submit to registry
	if ! mcp_publish_submit "${bundle_path}" "${token}" "${verbose}"; then
		exit 1
	fi

	printf '\n\342\234\223 Published to MCP Registry!\n'
	printf '\nYour server will be available at:\n'
	printf '  %s/servers/<your-server-name>\n' "${MCP_REGISTRY_URL}"

	exit 0
}
