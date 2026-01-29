#!/usr/bin/env bash
# UI Resource Discovery and Management
# Implements MCP Apps (SEP-1865) auto-discovery for ui:// resources

set -euo pipefail

# Registry state (exported for tool authors)
MCP_UI_REGISTRY_JSON=""
export MCP_UI_REGISTRY_HASH=""
export MCP_UI_REGISTRY_PATH=""
MCP_UI_TOTAL=0
MCP_UI_TTL="${MCP_UI_TTL:-5}"
MCP_UI_LAST_SCAN=""
MCP_UI_LOGGER="${MCP_UI_LOGGER:-mcp.ui}"

# Configuration defaults
MCPBASH_MAX_UI_RESOURCE_BYTES="${MCPBASH_MAX_UI_RESOURCE_BYTES:-1048576}"  # 1MB
MCPBASH_UI_CACHE_MAX_TEMPLATES="${MCPBASH_UI_CACHE_MAX_TEMPLATES:-50}"

# --- Discovery functions ---

# Discover all UI resources from filesystem
# Scans: tools/*/ui/ and ui/*/
mcp_ui_discover() {
	local resources=()
	local tools_dir="${MCPBASH_TOOLS_DIR:-${MCPBASH_PROJECT_ROOT:-}/tools}"
	local ui_dir="${MCPBASH_UI_DIR:-${MCPBASH_PROJECT_ROOT:-}/ui}"
	local server_name="${MCPBASH_SERVER_NAME:-mcp-server}"

	# Enable nullglob to handle empty directories
	local restore_nullglob=false
	if ! shopt -q nullglob 2>/dev/null; then
		shopt -s nullglob 2>/dev/null || true
		restore_nullglob=true
	fi

	# Scan tools/*/ui/
	if [ -d "${tools_dir}" ]; then
		local tool_dir
		for tool_dir in "${tools_dir}"/*/; do
			[ -d "${tool_dir}" ] || continue
			local tool_name
			tool_name="$(basename "${tool_dir}")"
			local tool_ui_dir="${tool_dir}ui"

			if [ -d "${tool_ui_dir}" ]; then
				local meta_file="${tool_ui_dir}/ui.meta.json"
				local index_file="${tool_ui_dir}/index.html"

				if [ -f "${meta_file}" ] || [ -f "${index_file}" ]; then
					local resource_json
					resource_json="$(mcp_ui_parse_resource "${tool_name}" "${tool_ui_dir}" "${server_name}")"
					if [ -n "${resource_json}" ]; then
						resources+=("${resource_json}")
					fi
				fi
			fi
		done
	fi

	# Scan ui/*/
	if [ -d "${ui_dir}" ]; then
		local standalone_dir
		for standalone_dir in "${ui_dir}"/*/; do
			[ -d "${standalone_dir}" ] || continue
			local ui_name
			ui_name="$(basename "${standalone_dir}")"
			local meta_file="${standalone_dir}/ui.meta.json"
			local index_file="${standalone_dir}/index.html"

			if [ -f "${meta_file}" ] || [ -f "${index_file}" ]; then
				# Check if already discovered via tool (avoid duplicates)
				local is_duplicate=false
				local existing
				for existing in "${resources[@]+"${resources[@]}"}"; do
					local existing_name
					existing_name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' <<<"${existing}" 2>/dev/null || true)"
					if [ "${existing_name}" = "${ui_name}" ]; then
						is_duplicate=true
						break
					fi
				done

				if [ "${is_duplicate}" = "false" ]; then
					local resource_json
					resource_json="$(mcp_ui_parse_resource "${ui_name}" "${standalone_dir}" "${server_name}")"
					if [ -n "${resource_json}" ]; then
						resources+=("${resource_json}")
					fi
				fi
			fi
		done
	fi

	# Restore nullglob state
	if [ "${restore_nullglob}" = "true" ]; then
		shopt -u nullglob 2>/dev/null || true
	fi

	# Build JSON array from resources
	if [ "${#resources[@]}" -eq 0 ]; then
		printf '[]'
	else
		printf '%s\n' "${resources[@]}" | "${MCPBASH_JSON_TOOL_BIN}" -s '.'
	fi
}

# Parse UI resource from directory
# Returns: JSON object with resource metadata
mcp_ui_parse_resource() {
	local name="$1"
	local dir="$2"
	local server_name="$3"
	local meta_file="${dir}/ui.meta.json"

	local meta='{}'
	if [ -f "${meta_file}" ]; then
		meta="$("${MCPBASH_JSON_TOOL_BIN}" -c '.' "${meta_file}" 2>/dev/null || printf '{}')"
	fi

	# Get entrypoint (default: index.html)
	local entrypoint
	entrypoint="$("${MCPBASH_JSON_TOOL_BIN}" -r '.entrypoint // "index.html"' <<<"${meta}" 2>/dev/null || printf 'index.html')"
	local html_file="${dir}/${entrypoint}"

	# Determine if template-based or static
	local has_html="false"
	[ -f "${html_file}" ] && has_html="true"

	local template
	template="$("${MCPBASH_JSON_TOOL_BIN}" -r '.template // empty' <<<"${meta}" 2>/dev/null || true)"

	# Build resource JSON
	"${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg name "${name}" \
		--arg dir "${dir}" \
		--arg uri "ui://${server_name}/${name}" \
		--arg entrypoint "${entrypoint}" \
		--argjson meta "${meta}" \
		--argjson hasHtml "${has_html}" \
		--arg template "${template}" \
		'{
			name: $name,
			uri: $uri,
			path: $dir,
			entrypoint: $entrypoint,
			hasHtml: $hasHtml,
			template: (if $template != "" then $template else null end),
			description: ($meta.description // "UI resource for \($name)"),
			mimeType: "text/html;profile=mcp-app",
			csp: ($meta.meta.csp // {}),
			permissions: ($meta.meta.permissions // {}),
			prefersBorder: (if $meta.meta.prefersBorder == null then true else $meta.meta.prefersBorder end)
		}'
}

# --- Registry management ---

# Generate UI registry from discovered resources
mcp_ui_generate_registry() {
	local output_file="${MCPBASH_REGISTRY_DIR:-${MCPBASH_STATE_DIR}}/ui-resources.json"
	local resources
	resources="$(mcp_ui_discover)"

	# Calculate content hash (portable: sha256sum or shasum)
	local hash
	if command -v sha256sum >/dev/null 2>&1; then
		hash="$(printf '%s' "${resources}" | sha256sum | cut -d' ' -f1)"
	elif command -v shasum >/dev/null 2>&1; then
		hash="$(printf '%s' "${resources}" | shasum -a 256 | cut -d' ' -f1)"
	else
		# Fallback to cksum
		hash="$(printf '%s' "${resources}" | cksum | cut -d' ' -f1)"
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)"

	local registry_json
	registry_json="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--argjson resources "${resources}" \
		--arg hash "${hash}" \
		--arg timestamp "${timestamp}" \
		'{
			version: 1,
			hash: $hash,
			timestamp: $timestamp,
			uiResources: $resources
		}')"

	# Create directory if needed
	local registry_dir
	registry_dir="$(dirname "${output_file}")"
	[ -d "${registry_dir}" ] || mkdir -p "${registry_dir}"

	# Write atomically
	local tmp_file
	tmp_file="$(mktemp "${output_file}.XXXXXX")"
	printf '%s' "${registry_json}" >"${tmp_file}"
	mv "${tmp_file}" "${output_file}"

	# Update in-memory cache
	MCP_UI_REGISTRY_JSON="${registry_json}"
	MCP_UI_REGISTRY_HASH="${hash}"
	MCP_UI_REGISTRY_PATH="${output_file}"
	MCP_UI_TOTAL="$("${MCPBASH_JSON_TOOL_BIN}" -r '.uiResources | length' <<<"${registry_json}" 2>/dev/null || printf '0')"
	MCP_UI_LAST_SCAN="$(date +%s 2>/dev/null || printf '0')"

	if declare -F mcp_logging_is_enabled >/dev/null 2>&1 && mcp_logging_is_enabled "debug"; then
		mcp_logging_debug "${MCP_UI_LOGGER}" "Generated UI registry: ${MCP_UI_TOTAL} resources, hash=${hash:0:8}"
	fi
}

# Load UI registry from cache file
mcp_ui_load_registry() {
	local registry_file="${MCPBASH_REGISTRY_DIR:-${MCPBASH_STATE_DIR}}/ui-resources.json"

	if [ ! -f "${registry_file}" ]; then
		MCP_UI_REGISTRY_JSON=""
		MCP_UI_REGISTRY_HASH=""
		MCP_UI_TOTAL=0
		return 1
	fi

	MCP_UI_REGISTRY_JSON="$(cat "${registry_file}")"
	MCP_UI_REGISTRY_HASH="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // ""' <<<"${MCP_UI_REGISTRY_JSON}" 2>/dev/null || true)"
	MCP_UI_TOTAL="$("${MCPBASH_JSON_TOOL_BIN}" -r '.uiResources | length' <<<"${MCP_UI_REGISTRY_JSON}" 2>/dev/null || printf '0')"
	MCP_UI_REGISTRY_PATH="${registry_file}"
}

# Check if registry needs refresh
mcp_ui_registry_stale() {
	local now
	now="$(date +%s 2>/dev/null || printf '0')"
	local last="${MCP_UI_LAST_SCAN:-0}"
	local ttl="${MCP_UI_TTL:-5}"

	if [ -z "${MCP_UI_REGISTRY_JSON}" ]; then
		return 0 # Stale: not loaded
	fi

	local elapsed=$((now - last))
	[ "${elapsed}" -ge "${ttl}" ]
}

# Refresh registry if stale
mcp_ui_refresh_registry() {
	if mcp_ui_registry_stale; then
		mcp_ui_generate_registry
	elif [ -z "${MCP_UI_REGISTRY_JSON}" ]; then
		if ! mcp_ui_load_registry; then
			mcp_ui_generate_registry
		fi
	fi
}

# --- Query functions ---

# Get UI resource metadata by name
# Returns: JSON object with csp, permissions, prefersBorder
mcp_ui_get_metadata() {
	local name="$1"

	mcp_ui_refresh_registry

	if [ -z "${MCP_UI_REGISTRY_JSON}" ]; then
		printf '{}'
		return
	fi

	local result
	result="$("${MCPBASH_JSON_TOOL_BIN}" --arg name "${name}" \
		'.uiResources[] | select(.name == $name) | {
			csp: .csp,
			permissions: .permissions,
			prefersBorder: .prefersBorder
		}' <<<"${MCP_UI_REGISTRY_JSON}" 2>/dev/null || true)"

	# Return empty object if not found (use variable to avoid bash brace parsing issue)
	local empty_json='{}'
	printf '%s' "${result:-$empty_json}"
}

# Get UI resource path from registry
# Returns: filesystem path to index.html (or configured entrypoint)
mcp_ui_get_path_from_registry() {
	local name="$1"

	mcp_ui_refresh_registry

	if [ -z "${MCP_UI_REGISTRY_JSON}" ]; then
		return 1
	fi

	local entry
	entry="$("${MCPBASH_JSON_TOOL_BIN}" --arg name "${name}" \
		'.uiResources[] | select(.name == $name)' <<<"${MCP_UI_REGISTRY_JSON}" 2>/dev/null || true)"

	if [ -z "${entry}" ]; then
		return 1
	fi

	local dir entrypoint
	dir="$("${MCPBASH_JSON_TOOL_BIN}" -r '.path' <<<"${entry}")"
	# Strip trailing slash if present
	dir="${dir%/}"
	entrypoint="$("${MCPBASH_JSON_TOOL_BIN}" -r '.entrypoint // "index.html"' <<<"${entry}")"

	local html_path="${dir}/${entrypoint}"
	if [ -f "${html_path}" ]; then
		printf '%s' "${html_path}"
		return 0
	fi

	return 1
}

# List all UI resources (for debugging/introspection)
mcp_ui_list() {
	mcp_ui_refresh_registry

	if [ -z "${MCP_UI_REGISTRY_JSON}" ]; then
		printf '[]\n'
		return
	fi

	"${MCPBASH_JSON_TOOL_BIN}" '.uiResources // []' <<<"${MCP_UI_REGISTRY_JSON}"
}

# Get UI resource count
mcp_ui_count() {
	mcp_ui_refresh_registry
	printf '%d' "${MCP_UI_TOTAL:-0}"
}

# Get UI resource HTML content (static file or generated from template)
# Returns: HTML content on stdout
mcp_ui_get_content() {
	local name="$1"

	mcp_ui_refresh_registry

	if [ -z "${MCP_UI_REGISTRY_JSON}" ]; then
		return 1
	fi

	local entry
	entry="$("${MCPBASH_JSON_TOOL_BIN}" --arg name "${name}" \
		'.uiResources[] | select(.name == $name)' <<<"${MCP_UI_REGISTRY_JSON}" 2>/dev/null || true)"

	if [ -z "${entry}" ]; then
		return 1
	fi

	local has_html template dir entrypoint
	has_html="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hasHtml // false' <<<"${entry}")"
	template="$("${MCPBASH_JSON_TOOL_BIN}" -r '.template // empty' <<<"${entry}")"
	dir="$("${MCPBASH_JSON_TOOL_BIN}" -r '.path' <<<"${entry}")"
	entrypoint="$("${MCPBASH_JSON_TOOL_BIN}" -r '.entrypoint // "index.html"' <<<"${entry}")"

	# If static HTML exists, return it
	if [ "${has_html}" = "true" ]; then
		local html_path="${dir}/${entrypoint}"
		if [ -f "${html_path}" ]; then
			cat "${html_path}"
			return 0
		fi
	fi

	# If template is configured, generate HTML
	if [ -n "${template}" ]; then
		local meta_file="${dir}/ui.meta.json"
		if [ -f "${meta_file}" ]; then
			local config
			config="$("${MCPBASH_JSON_TOOL_BIN}" -c '.config // {}' "${meta_file}" 2>/dev/null || printf '{}')"

			# Check if template generator exists
			if declare -F mcp_ui_generate_from_template >/dev/null 2>&1; then
				mcp_ui_generate_from_template "${template}" "${config}"
				return $?
			fi
		fi
	fi

	return 1
}

# --- CSP Header Generation ---

# Generate Content-Security-Policy header string from UI resource metadata
# Usage: mcp_ui_get_csp_header <resource_name>
# Returns: CSP header string on stdout
# If no metadata found or no CSP configured, returns a restrictive default
mcp_ui_get_csp_header() {
	local name="$1"

	# Default restrictive CSP
	local default_csp="default-src 'self'; script-src 'self' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'"

	mcp_ui_refresh_registry

	if [ -z "${MCP_UI_REGISTRY_JSON}" ]; then
		printf '%s' "${default_csp}"
		return 0
	fi

	local entry
	entry="$("${MCPBASH_JSON_TOOL_BIN}" --arg name "${name}" \
		'.uiResources[] | select(.name == $name)' <<<"${MCP_UI_REGISTRY_JSON}" 2>/dev/null || true)"

	if [ -z "${entry}" ]; then
		printf '%s' "${default_csp}"
		return 0
	fi

	local csp
	csp="$("${MCPBASH_JSON_TOOL_BIN}" -c '.csp // {}' <<<"${entry}" 2>/dev/null || printf '{}')"

	# Check if CSP is empty
	local csp_empty
	csp_empty="$("${MCPBASH_JSON_TOOL_BIN}" -r 'if . == {} then "true" else "false" end' <<<"${csp}" 2>/dev/null || printf 'true')"

	if [ "${csp_empty}" = "true" ]; then
		printf '%s' "${default_csp}"
		return 0
	fi

	# Build CSP from metadata
	local csp_parts=()

	# Default directives
	csp_parts+=("default-src 'self'")
	csp_parts+=("script-src 'self' https://cdn.jsdelivr.net")
	csp_parts+=("style-src 'self' 'unsafe-inline'")
	csp_parts+=("img-src 'self' data:")

	# connectDomains → connect-src
	local connect_domains
	connect_domains="$("${MCPBASH_JSON_TOOL_BIN}" -r '.connectDomains // [] | if length > 0 then join(" ") else empty end' <<<"${csp}" 2>/dev/null || true)"
	if [ -n "${connect_domains}" ]; then
		csp_parts+=("connect-src 'self' ${connect_domains}")
	else
		csp_parts+=("connect-src 'self'")
	fi

	# resourceDomains → font-src, media-src
	local resource_domains
	resource_domains="$("${MCPBASH_JSON_TOOL_BIN}" -r '.resourceDomains // [] | if length > 0 then join(" ") else empty end' <<<"${csp}" 2>/dev/null || true)"
	if [ -n "${resource_domains}" ]; then
		csp_parts+=("font-src 'self' ${resource_domains}")
		csp_parts+=("media-src 'self' ${resource_domains}")
	fi

	# frameDomains → frame-src
	local frame_domains
	frame_domains="$("${MCPBASH_JSON_TOOL_BIN}" -r '.frameDomains // [] | if length > 0 then join(" ") else empty end' <<<"${csp}" 2>/dev/null || true)"
	if [ -n "${frame_domains}" ]; then
		csp_parts+=("frame-src ${frame_domains}")
	else
		csp_parts+=("frame-src 'none'")
	fi

	# baseUriDomains → base-uri
	local base_uri_domains
	base_uri_domains="$("${MCPBASH_JSON_TOOL_BIN}" -r '.baseUriDomains // [] | if length > 0 then join(" ") else empty end' <<<"${csp}" 2>/dev/null || true)"
	if [ -n "${base_uri_domains}" ]; then
		csp_parts+=("base-uri 'self' ${base_uri_domains}")
	else
		csp_parts+=("base-uri 'self'")
	fi

	# Always include frame-ancestors 'none' for security
	csp_parts+=("frame-ancestors 'none'")

	# Join parts with semicolon
	local IFS='; '
	printf '%s' "${csp_parts[*]}"
}

# Build CSP meta JSON object from resource metadata
# Usage: mcp_ui_get_csp_meta <resource_name>
# Returns: JSON object for _meta.ui.csp
mcp_ui_get_csp_meta() {
	local name="$1"

	mcp_ui_refresh_registry

	# Default empty CSP object
	local default_csp='{"connectDomains":[],"resourceDomains":[],"frameDomains":[],"baseUriDomains":[]}'

	if [ -z "${MCP_UI_REGISTRY_JSON}" ]; then
		printf '%s' "${default_csp}"
		return 0
	fi

	local entry
	entry="$("${MCPBASH_JSON_TOOL_BIN}" --arg name "${name}" \
		'.uiResources[] | select(.name == $name)' <<<"${MCP_UI_REGISTRY_JSON}" 2>/dev/null || true)"

	if [ -z "${entry}" ]; then
		printf '%s' "${default_csp}"
		return 0
	fi

	local csp
	csp="$("${MCPBASH_JSON_TOOL_BIN}" -c '.csp // {}' <<<"${entry}" 2>/dev/null || printf '{}')"

	# Ensure all required fields exist with defaults
	"${MCPBASH_JSON_TOOL_BIN}" '{
		connectDomains: (.connectDomains // []),
		resourceDomains: (.resourceDomains // []),
		frameDomains: (.frameDomains // []),
		baseUriDomains: (.baseUriDomains // [])
	}' <<<"${csp}"
}
