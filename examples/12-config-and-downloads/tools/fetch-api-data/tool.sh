#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# ============================================================
# Example: Configuration loading and secure downloads (v0.10.0)
# ============================================================
# Demonstrates:
# - mcp_config_load: Load config from env var / file / defaults
# - mcp_config_get: Extract values with fallbacks
# - mcp_download_safe: SSRF-protected HTTPS downloads
# - mcp_error --hint: LLM-friendly error messages
# ============================================================

# Load configuration with precedence: env var > file > example > defaults
mcp_config_load \
	--env FETCH_API_CONFIG \
	--file "${MCPBASH_PROJECT_ROOT}/config.json" \
	--example "${MCPBASH_PROJECT_ROOT}/config.example.json" \
	--defaults '{"timeout": 30, "max_bytes": 1048576, "allowed_hosts": ["httpbin.org"]}'

# Extract config values
timeout=$(mcp_config_get '.timeout' --default 30)
max_bytes=$(mcp_config_get '.max_bytes' --default 1048576)
# Note: allowed_hosts from config is informational; actual enforcement is via --allow flag

# Get required URL argument
url=$(mcp_args_require '.url')

# Validate URL format
if [[ ! "${url}" =~ ^https:// ]]; then
	mcp_error "validation_error" "URL must use HTTPS protocol" \
		--hint "Change the URL to start with https:// instead of http://" \
		--data "$(mcp_json_obj received "${url}")"
fi

# Extract host for allowlist
host=$(echo "${url}" | sed -E 's|^https://([^/]+).*|\1|')

# Create temp file for download
tmp_file=$(mktemp)
trap 'rm -f "${tmp_file}"' EXIT

# Download with SSRF protection
mcp_log_info "fetch-api-data" "Fetching ${url} (timeout=${timeout}s, max=${max_bytes} bytes)"

result=$(mcp_download_safe \
	--url "${url}" \
	--out "${tmp_file}" \
	--allow "${host}" \
	--timeout "${timeout}" \
	--max-bytes "${max_bytes}")

# Check download result
if [[ $(echo "${result}" | jq -r '.success') == "true" ]]; then
	# Success - return preview of downloaded content
	bytes=$(echo "${result}" | jq -r '.bytes')
	preview=$(head -c 500 "${tmp_file}" 2>/dev/null || echo "(binary content)")

	mcp_result_success "$(mcp_json_obj \
		bytes "${bytes}" \
		preview "${preview}" \
		url "${url}")"
else
	# Error - provide LLM-friendly hint based on error type
	error_type=$(echo "${result}" | jq -r '.error.type')
	error_msg=$(echo "${result}" | jq -r '.error.message')

	case "${error_type}" in
	redirect)
		location=$(echo "${result}" | jq -r '.error.location // "unknown"')
		mcp_error "redirect" "URL redirected to a different location" \
			--hint "The URL redirected to ${location}. Try fetching that URL directly instead." \
			--data "$(mcp_json_obj original_url "${url}" redirect_location "${location}")"
		;;
	host_blocked)
		mcp_error "host_blocked" "Host is not in the allowlist" \
			--hint "Add '${host}' to MCPBASH_HTTPS_ALLOW_HOSTS or use a different URL from an allowed host" \
			--data "$(mcp_json_obj blocked_host "${host}" url "${url}")"
		;;
	network_error)
		mcp_error "network_error" "${error_msg}" \
			--hint "Check if the URL is accessible and try again. The server may be temporarily unavailable." \
			--data "$(mcp_json_obj url "${url}")"
		;;
	size_exceeded)
		mcp_error "size_exceeded" "Response exceeds maximum size" \
			--hint "The response is larger than ${max_bytes} bytes. Try a different endpoint or increase max_bytes in config." \
			--data "$(mcp_json_obj url "${url}" max_bytes "${max_bytes}")"
		;;
	*)
		mcp_error "${error_type}" "${error_msg}" \
			--hint "Check the URL and try again" \
			--data "$(mcp_json_obj url "${url}" error_type "${error_type}")"
		;;
	esac
fi
