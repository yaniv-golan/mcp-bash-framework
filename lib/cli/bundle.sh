#!/usr/bin/env bash
# CLI bundle command - creates MCPB bundles for distribution.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash bundle; BASH_VERSION missing\n' >&2
	exit 1
fi

# Source common helpers
cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh disable=SC1091
. "${cli_dir}/common.sh"

# Required framework files to embed (from bin/mcp-bash line 99 + additional)
BUNDLE_REQUIRED_LIBS="runtime json hash ids lock io paginate logging auth uri policy tools_policy registry spec tools resources prompts completion timeout elicitation roots rpc core validate path resource_content resource_providers progress"

# gojq release version to bundle
GOJQ_VERSION="0.12.16"

# Get gojq download URL for platform/arch (Bash 3 compatible)
_get_gojq_url() {
	local key="$1"
	case "${key}" in
	darwin-amd64) echo "https://github.com/itchyny/gojq/releases/download/v${GOJQ_VERSION}/gojq_v${GOJQ_VERSION}_darwin_amd64.tar.gz" ;;
	darwin-arm64) echo "https://github.com/itchyny/gojq/releases/download/v${GOJQ_VERSION}/gojq_v${GOJQ_VERSION}_darwin_arm64.tar.gz" ;;
	linux-amd64) echo "https://github.com/itchyny/gojq/releases/download/v${GOJQ_VERSION}/gojq_v${GOJQ_VERSION}_linux_amd64.tar.gz" ;;
	linux-arm64) echo "https://github.com/itchyny/gojq/releases/download/v${GOJQ_VERSION}/gojq_v${GOJQ_VERSION}_linux_arm64.tar.gz" ;;
	win32-amd64) echo "https://github.com/itchyny/gojq/releases/download/v${GOJQ_VERSION}/gojq_v${GOJQ_VERSION}_windows_amd64.zip" ;;
	*) echo "" ;;
	esac
}

# Track bundled icon for manifest
BUNDLED_ICON=""

# Track target platforms for manifest
BUNDLE_PLATFORMS="darwin linux win32"

# Track if static registry mode is enabled for manifest
BUNDLE_STATIC_REGISTRY=""

# Helper to check if a space-separated list contains an item
mcp_bundle_list_contains() {
	local list="$1" item="$2"
	case " ${list} " in *" ${item} "*) return 0 ;; esac
	return 1
}

mcp_bundle_usage() {
	cat <<'EOF'
Usage:
  mcp-bash bundle [options]

Create an MCPB bundle for distribution via Claude Desktop.

Options:
  --output DIR       Output directory (default: current directory)
  --name NAME        Bundle name (default: from server.meta.json or directory)
  --version VERSION  Bundle version (default: from VERSION file)
  --platform PLAT    Target platform: darwin, linux, win32, or all (default: all)
  --include-gojq     Bundle gojq binary for systems without jq
  --validate         Validate bundle structure without creating
  --verbose          Show detailed progress
  --help, -h         Show this help

Configuration:
  Create mcpb.conf in your project root to customize the bundle:

    MCPB_NAME="my-server"
    MCPB_VERSION="1.0.0"
    MCPB_DESCRIPTION="My MCP server"
    MCPB_AUTHOR_NAME="Your Name"
    MCPB_AUTHOR_EMAIL="you@example.com"
    MCPB_AUTHOR_URL="https://github.com/you"
    MCPB_REPOSITORY="https://github.com/you/my-server"
    MCPB_INCLUDE=".registry data/templates"  # Additional directories to bundle

Examples:
  mcp-bash bundle                        # Create bundle with defaults
  mcp-bash bundle --validate             # Check without creating
  mcp-bash bundle --output ./dist        # Output to dist directory
  mcp-bash bundle --platform darwin      # macOS-only bundle
  mcp-bash bundle --include-gojq         # Include gojq for JSON processing

The bundle includes:
  - Your tools, resources, and prompts
  - An embedded copy of mcp-bash framework
  - A manifest.json for MCPB compatibility
  - Icon (if icon.png or icon.svg exists in project root)

Next steps after bundling:
  - Double-click the .mcpb file to install in any MCPB-compatible client
  - Or drag it to the client window (e.g., Claude Desktop)
EOF
	exit 0
}

mcp_bundle_check_dependencies() {
	local missing=""

	# Required: zip command
	if ! command -v zip >/dev/null 2>&1; then
		missing="${missing}zip "
	fi

	if [ -n "${missing}" ]; then
		printf '  \342\234\227 Missing required commands: %s\n' "${missing}" >&2
		printf '    Install: brew install %s (macOS), apt install %s (Linux), choco install %s (Windows)\n' "${missing}" "${missing}" "${missing}" >&2
		return 3
	fi

	return 0
}

mcp_bundle_download_gojq() {
	local target_dir="$1"
	local platform="$2"
	local verbose="$3"

	# Determine architecture
	local arch
	case "$(uname -m)" in
	x86_64 | amd64) arch="amd64" ;;
	arm64 | aarch64) arch="arm64" ;;
	*)
		printf '  \342\234\227 Unsupported architecture: %s\n' "$(uname -m)" >&2
		return 1
		;;
	esac

	local url_key="${platform}-${arch}"
	local url
	url="$(_get_gojq_url "${url_key}")"

	if [ -z "${url}" ]; then
		printf '  \342\234\227 No gojq binary available for %s-%s\n' "${platform}" "${arch}" >&2
		return 1
	fi

	# Create temp directory for download
	local tmp_dir
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/gojq.XXXXXX")"
	trap 'rm -rf "${tmp_dir}"' RETURN

	if [ "${verbose}" = "true" ]; then
		printf '    Downloading gojq for %s-%s...\n' "${platform}" "${arch}"
	fi

	# Download
	local archive="${tmp_dir}/gojq.tar.gz"
	if [ "${platform}" = "win32" ]; then
		archive="${tmp_dir}/gojq.zip"
	fi

	if ! curl -fsSL "${url}" -o "${archive}" 2>/dev/null; then
		printf '  \342\234\227 Failed to download gojq from %s\n' "${url}" >&2
		return 1
	fi

	# Extract
	mkdir -p "${tmp_dir}/extracted"
	if [ "${platform}" = "win32" ]; then
		unzip -q "${archive}" -d "${tmp_dir}/extracted"
	else
		tar -xzf "${archive}" -C "${tmp_dir}/extracted"
	fi

	# Find and copy gojq binary
	local gojq_bin
	gojq_bin="$(find "${tmp_dir}/extracted" -name 'gojq*' -type f | head -1)"

	if [ -z "${gojq_bin}" ] || [ ! -f "${gojq_bin}" ]; then
		printf '  \342\234\227 Could not find gojq binary in archive\n' >&2
		return 1
	fi

	mkdir -p "${target_dir}"
	local target_name="gojq"
	if [ "${platform}" = "win32" ]; then
		target_name="gojq.exe"
	fi

	cp "${gojq_bin}" "${target_dir}/${target_name}"
	chmod +x "${target_dir}/${target_name}"

	if [ "${verbose}" = "true" ]; then
		printf '    Bundled gojq v%s for %s-%s\n' "${GOJQ_VERSION}" "${platform}" "${arch}"
	fi

	return 0
}

mcp_bundle_embed_gojq() {
	local staging_server="$1"
	local platforms="$2"
	local verbose="$3"

	local gojq_dir="${staging_server}/.mcp-bash/bin"
	mkdir -p "${gojq_dir}"

	# For single-platform bundles, download that platform's gojq
	# For multi-platform, download current platform (user can re-bundle on target)
	local platform
	for platform in ${platforms}; do
		if mcp_bundle_download_gojq "${gojq_dir}" "${platform}" "${verbose}"; then
			return 0
		fi
	done

	printf '  \342\232\240 Could not bundle gojq - bundle will require jq on target system\n' >&2
	return 1
}

mcp_bundle_validate_project() {
	local project_root="$1"
	local verbose="${2:-false}"
	local errors=0
	local warnings=0

	# Required: server.d/server.meta.json
	if [ ! -f "${project_root}/server.d/server.meta.json" ]; then
		printf '  \342\234\227 Missing required server.d/server.meta.json\n' >&2
		printf '    \342\206\222 Run "mcp-bash init" to create project structure\n' >&2
		errors=$((errors + 1))
	fi

	# Check for at least one tool, resource, or prompt
	local has_content="false"
	for dir in tools resources prompts; do
		if [ -d "${project_root}/${dir}" ]; then
			local count
			count="$(find "${project_root}/${dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
			if [ "${count}" -gt 0 ]; then
				has_content="true"
				break
			fi
		fi
	done

	if [ "${has_content}" = "false" ]; then
		printf '  \342\232\240 No tools, resources, or prompts found\n' >&2
		warnings=$((warnings + 1))
	fi

	# Validate server.meta.json is valid JSON if we have JSON tooling
	if [ "${errors}" -eq 0 ] && [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		if ! "${MCPBASH_JSON_TOOL_BIN}" '.' "${project_root}/server.d/server.meta.json" >/dev/null 2>&1; then
			printf '  \342\234\227 Invalid JSON in server.d/server.meta.json\n' >&2
			errors=$((errors + 1))
		fi
	fi

	# Check for mcpb.conf
	if [ ! -f "${project_root}/mcpb.conf" ]; then
		if [ "${verbose}" = "true" ]; then
			printf '  \342\232\240 No mcpb.conf found (optional but recommended for author info)\n' >&2
		fi
	fi

	return "${errors}"
}

mcp_bundle_warn_missing_author() {
	# MCPB spec requires author field - warn if we couldn't resolve one
	if [ -z "${RESOLVED_AUTHOR_NAME:-}" ]; then
		printf '  \342\232\240 Warning: No author name found (required by MCPB spec)\n' >&2
		printf '    \342\206\222 Add MCPB_AUTHOR_NAME to mcpb.conf or set git user.name\n' >&2
	fi
}

mcp_bundle_load_config() {
	local project_root="$1"
	local config_file="${project_root}/mcpb.conf"

	# Reset config variables (using MCPB_* prefix as per proposal)
	MCPB_NAME=""
	MCPB_VERSION=""
	MCPB_DESCRIPTION=""
	MCPB_AUTHOR_NAME=""
	MCPB_AUTHOR_EMAIL=""
	MCPB_AUTHOR_URL=""
	MCPB_REPOSITORY=""
	MCPB_INCLUDE=""
	MCPB_STATIC=""

	if [ -f "${config_file}" ]; then
		# Source config file (simple KEY=VALUE format)
		# shellcheck disable=SC1090
		. "${config_file}"
	fi
}

mcp_bundle_resolve_metadata() {
	local project_root="$1"
	local name_override="$2"
	local version_override="$3"

	# Priority: CLI override > mcpb.conf > server.meta.json > defaults

	# Name resolution
	if [ -n "${name_override}" ]; then
		RESOLVED_NAME="${name_override}"
	elif [ -n "${MCPB_NAME:-}" ]; then
		RESOLVED_NAME="${MCPB_NAME}"
	elif [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		RESOLVED_NAME="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	if [ -z "${RESOLVED_NAME:-}" ]; then
		RESOLVED_NAME="$(basename "${project_root}")"
	fi

	# Version resolution
	if [ -n "${version_override}" ]; then
		RESOLVED_VERSION="${version_override}"
	elif [ -n "${MCPB_VERSION:-}" ]; then
		RESOLVED_VERSION="${MCPB_VERSION}"
	elif [ -f "${project_root}/VERSION" ]; then
		RESOLVED_VERSION="$(tr -d '[:space:]' <"${project_root}/VERSION")"
	elif [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		RESOLVED_VERSION="$("${MCPBASH_JSON_TOOL_BIN}" -r '.version // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	if [ -z "${RESOLVED_VERSION:-}" ]; then
		RESOLVED_VERSION="0.1.0"
	fi

	# Title resolution
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		RESOLVED_TITLE="$("${MCPBASH_JSON_TOOL_BIN}" -r '.title // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	if [ -z "${RESOLVED_TITLE:-}" ]; then
		# Title-case the name
		RESOLVED_TITLE="$(mcp_runtime_titlecase "${RESOLVED_NAME}")"
	fi

	# Description resolution
	if [ -n "${MCPB_DESCRIPTION:-}" ]; then
		RESOLVED_DESCRIPTION="${MCPB_DESCRIPTION}"
	elif [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		RESOLVED_DESCRIPTION="$("${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	if [ -z "${RESOLVED_DESCRIPTION:-}" ]; then
		RESOLVED_DESCRIPTION="MCP server built with mcp-bash"
	fi

	# Author resolution (from mcpb.conf or server.meta.json)
	if [ -n "${MCPB_AUTHOR_NAME:-}" ]; then
		RESOLVED_AUTHOR_NAME="${MCPB_AUTHOR_NAME}"
	elif [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		RESOLVED_AUTHOR_NAME="$("${MCPBASH_JSON_TOOL_BIN}" -r '.author.name // .author // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	if [ -z "${RESOLVED_AUTHOR_NAME:-}" ]; then
		# Try to get from git config
		RESOLVED_AUTHOR_NAME="$(git config user.name 2>/dev/null || echo "")"
	fi

	if [ -n "${MCPB_AUTHOR_EMAIL:-}" ]; then
		RESOLVED_AUTHOR_EMAIL="${MCPB_AUTHOR_EMAIL}"
	elif [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		RESOLVED_AUTHOR_EMAIL="$("${MCPBASH_JSON_TOOL_BIN}" -r '.author.email // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	if [ -z "${RESOLVED_AUTHOR_EMAIL:-}" ]; then
		# Try to get from git config
		RESOLVED_AUTHOR_EMAIL="$(git config user.email 2>/dev/null || echo "")"
	fi

	if [ -n "${MCPB_AUTHOR_URL:-}" ]; then
		RESOLVED_AUTHOR_URL="${MCPB_AUTHOR_URL}"
	elif [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		RESOLVED_AUTHOR_URL="$("${MCPBASH_JSON_TOOL_BIN}" -r '.author.url // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	if [ -z "${RESOLVED_AUTHOR_URL:-}" ]; then
		RESOLVED_AUTHOR_URL=""
	fi

	# Repository resolution
	if [ -n "${MCPB_REPOSITORY:-}" ]; then
		RESOLVED_REPOSITORY="${MCPB_REPOSITORY}"
	elif [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		RESOLVED_REPOSITORY="$("${MCPBASH_JSON_TOOL_BIN}" -r '.repository // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	if [ -z "${RESOLVED_REPOSITORY:-}" ]; then
		# Try to get from git remote
		RESOLVED_REPOSITORY="$(git config --get remote.origin.url 2>/dev/null | sed 's/\.git$//' || echo "")"
	fi

	# Long description resolution (file-based)
	RESOLVED_LONG_DESCRIPTION=""
	local long_desc_file=""
	if [ -n "${MCPB_LONG_DESCRIPTION_FILE:-}" ]; then
		long_desc_file="${MCPB_LONG_DESCRIPTION_FILE}"
	elif [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -f "${project_root}/server.d/server.meta.json" ]; then
		long_desc_file="$("${MCPBASH_JSON_TOOL_BIN}" -r '.long_description_file // empty' "${project_root}/server.d/server.meta.json" 2>/dev/null || true)"
	fi
	# Read file content if file reference exists
	if [ -n "${long_desc_file}" ]; then
		# Resolve relative path from project root
		local full_path="${long_desc_file}"
		if [ "${long_desc_file#/}" = "${long_desc_file}" ]; then
			full_path="${project_root}/${long_desc_file}"
		fi
		if [ -f "${full_path}" ]; then
			RESOLVED_LONG_DESCRIPTION="$(cat "${full_path}")"
		else
			printf '  ⚠ Warning: long_description_file not found: %s\n' "${long_desc_file}" >&2
		fi
	fi

	export RESOLVED_NAME RESOLVED_VERSION RESOLVED_TITLE RESOLVED_DESCRIPTION
	export RESOLVED_AUTHOR_NAME RESOLVED_AUTHOR_EMAIL RESOLVED_AUTHOR_URL RESOLVED_REPOSITORY
	export RESOLVED_LONG_DESCRIPTION
}

mcp_bundle_copy_project() {
	local project_root="$1"
	local staging_server="$2"
	local verbose="$3"

	# Reset icon tracking
	BUNDLED_ICON=""

	# Default directories to copy
	local default_dirs="tools resources prompts completions server.d lib providers"

	# Copy default project directories if they exist
	local dir
	for dir in ${default_dirs}; do
		if [ -d "${project_root}/${dir}" ]; then
			cp -R "${project_root}/${dir}" "${staging_server}/"
			if [ "${verbose}" = "true" ]; then
				printf '    Copied %s/\n' "${dir}"
			fi
		fi
	done

	# Copy custom directories from MCPB_INCLUDE (with validation)
	local custom_count=0
	if [ -n "${MCPB_INCLUDE:-}" ]; then
		for dir in ${MCPB_INCLUDE}; do
			# Normalize: strip trailing slash to ensure consistent cp -R behavior
			dir="${dir%/}"

			# Security: reject absolute paths, explicit ./ prefix, and path traversal
			# Pattern catches: .., ../, /foo, foo/../bar, foo/..
			# Note: ./.. is caught by ./* pattern (absolute/relative), not path traversal
			case "${dir}" in
			/* | ./*)
				printf '  \342\232\240 Warning: MCPB_INCLUDE rejects absolute/relative path: %s\n' "${dir}" >&2
				continue
				;;
			.. | */.. | ../* | */../*)
				printf '  \342\232\240 Warning: MCPB_INCLUDE rejects path traversal: %s\n' "${dir}" >&2
				continue
				;;
			esac

			# Skip if path starts with or equals a default directory (avoid overlaps)
			local skip="false"
			local default
			for default in ${default_dirs}; do
				case "${dir}" in
				"${default}" | "${default}"/*)
					if [ "${verbose}" = "true" ]; then
						printf '    Skipped %s/ (overlaps with default %s/)\n' "${dir}" "${default}"
					fi
					skip="true"
					break
					;;
				esac
			done
			[ "${skip}" = "true" ] && continue

			if [ -d "${project_root}/${dir}" ]; then
				# Handle nested paths (e.g., config/schemas) vs top-level (e.g., .registry)
				local target_parent
				target_parent="$(dirname "${dir}")"
				if [ "${target_parent}" = "." ]; then
					cp -R "${project_root}/${dir}" "${staging_server}/"
				else
					mkdir -p "${staging_server}/${target_parent}"
					cp -R "${project_root}/${dir}" "${staging_server}/${target_parent}/"
				fi
				custom_count=$((custom_count + 1))
				if [ "${verbose}" = "true" ]; then
					printf '    Copied %s/ (custom)\n' "${dir}"
				fi
			else
				printf '  \342\232\240 Warning: MCPB_INCLUDE directory not found: %s\n' "${dir}" >&2
			fi
		done

		if [ "${verbose}" = "true" ] && [ "${custom_count}" -gt 0 ]; then
			printf '  \342\234\223 Included %s custom director%s\n' "${custom_count}" "$([ "${custom_count}" -eq 1 ] && echo "y" || echo "ies")"
		fi
	fi

	# Copy VERSION file if present
	if [ -f "${project_root}/VERSION" ]; then
		cp "${project_root}/VERSION" "${staging_server}/"
		if [ "${verbose}" = "true" ]; then
			printf '    Copied VERSION\n'
		fi
	fi

	# Copy icon if present (prefer PNG over SVG)
	for icon in icon.png icon.svg; do
		if [ -f "${project_root}/${icon}" ]; then
			cp "${project_root}/${icon}" "${staging_server}/../"
			BUNDLED_ICON="${icon}"
			if [ "${verbose}" = "true" ]; then
				printf '    Copied %s\n' "${icon}"
			fi
			break
		fi
	done
}

mcp_bundle_embed_framework() {
	local staging_server="$1"
	local verbose="$2"

	local framework_dir="${staging_server}/.mcp-bash"
	mkdir -p "${framework_dir}/bin"
	mkdir -p "${framework_dir}/lib"
	mkdir -p "${framework_dir}/sdk"
	mkdir -p "${framework_dir}/handlers"

	# Copy main entry point
	cp "${MCPBASH_HOME}/bin/mcp-bash" "${framework_dir}/bin/"
	chmod +x "${framework_dir}/bin/mcp-bash"

	# Copy required libs
	local lib
	for lib in ${BUNDLE_REQUIRED_LIBS}; do
		if [ -f "${MCPBASH_HOME}/lib/${lib}.sh" ]; then
			cp "${MCPBASH_HOME}/lib/${lib}.sh" "${framework_dir}/lib/"
		fi
	done

	# Copy cli helpers needed by embedded mcp-bash
	mkdir -p "${framework_dir}/lib/cli"
	cp "${MCPBASH_HOME}/lib/cli/common.sh" "${framework_dir}/lib/cli/"
	cp "${MCPBASH_HOME}/lib/cli/health.sh" "${framework_dir}/lib/cli/"

	# Copy SDK
	if [ -f "${MCPBASH_HOME}/sdk/tool-sdk.sh" ]; then
		cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${framework_dir}/sdk/"
	fi

	# Copy all handlers
	if [ -d "${MCPBASH_HOME}/handlers" ]; then
		cp "${MCPBASH_HOME}/handlers/"*.sh "${framework_dir}/handlers/" 2>/dev/null || true
	fi

	# Copy VERSION
	if [ -f "${MCPBASH_HOME}/VERSION" ]; then
		cp "${MCPBASH_HOME}/VERSION" "${framework_dir}/"
	fi

	if [ "${verbose}" = "true" ]; then
		local size
		size="$(du -sh "${framework_dir}" 2>/dev/null | cut -f1)"
		printf '    Embedded framework (%s)\n' "${size}"
	fi
}

mcp_bundle_generate_wrapper() {
	local staging_server="$1"
	local template="${MCPBASH_HOME}/scaffold/bundle/run-server.sh.template"
	local output="${staging_server}/run-server.sh"

	if [ -f "${template}" ]; then
		cp "${template}" "${output}"
	else
		# Inline template if file doesn't exist
		cat >"${output}" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

# Resolve script directory (works with symlinks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source login shell profiles for GUI app compatibility (pyenv, nvm, rbenv, etc.)
# Set MCPB_SKIP_LOGIN_SHELL=1 to disable this behavior
if [[ -z "${MCPB_SKIP_LOGIN_SHELL:-}" ]]; then
  for rc in "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bashrc"; do
    if [[ -f "$rc" ]]; then
      # shellcheck disable=SC1090
      source "$rc" 2>/dev/null || true
      break
    fi
  done
fi

# Set project root to this bundle's server directory
export MCPBASH_PROJECT_ROOT="${SCRIPT_DIR}"

# Use bundled gojq if present (Phase 2)
if [[ -f "${SCRIPT_DIR}/.mcp-bash/bin/gojq" ]]; then
  export MCPBASH_JSON_TOOL="gojq"
  export MCPBASH_JSON_TOOL_BIN="${SCRIPT_DIR}/.mcp-bash/bin/gojq"
fi

# Execute the embedded framework
exec "${SCRIPT_DIR}/.mcp-bash/bin/mcp-bash" "$@"
WRAPPER
	fi

	chmod +x "${output}"
}

mcp_bundle_generate_manifest() {
	local staging_dir="$1"
	local project_root="$2"
	local template="${MCPBASH_HOME}/scaffold/bundle/manifest.json.template"
	local output="${staging_dir}/manifest.json"

	# Build platforms array from BUNDLE_PLATFORMS
	local platforms_json="["
	local first=true
	for p in ${BUNDLE_PLATFORMS}; do
		if [ "${first}" = "true" ]; then
			platforms_json="${platforms_json}\"${p}\""
			first=false
		else
			platforms_json="${platforms_json}, \"${p}\""
		fi
	done
	platforms_json="${platforms_json}]"

	# Detect if tools/prompts exist (for *_generated flags)
	local has_tools="false"
	local has_prompts="false"
	local has_static="false"
	if [ -d "${project_root}/tools" ] && [ -n "$(ls -A "${project_root}/tools" 2>/dev/null)" ]; then
		has_tools="true"
	fi
	if [ -d "${project_root}/prompts" ] && [ -n "$(ls -A "${project_root}/prompts" 2>/dev/null)" ]; then
		has_prompts="true"
	fi
	if [ "${BUNDLE_STATIC_REGISTRY:-}" = "true" ]; then
		has_static="true"
	fi

	# Use JSON tool to build manifest if available, otherwise use template
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		# Build manifest with proper JSON escaping per MCPB v0.3 spec
		local manifest
		manifest="$(
			"${MCPBASH_JSON_TOOL_BIN}" -n \
				--arg name "${RESOLVED_NAME}" \
				--arg version "${RESOLVED_VERSION}" \
				--arg display_name "${RESOLVED_TITLE}" \
				--arg description "${RESOLVED_DESCRIPTION}" \
				--arg long_description "${RESOLVED_LONG_DESCRIPTION:-}" \
				--arg author_name "${RESOLVED_AUTHOR_NAME:-}" \
				--arg author_email "${RESOLVED_AUTHOR_EMAIL:-}" \
				--arg author_url "${RESOLVED_AUTHOR_URL:-}" \
				--arg repository_url "${RESOLVED_REPOSITORY:-}" \
				--arg icon "${BUNDLED_ICON:-}" \
				--argjson platforms "${platforms_json}" \
				--argjson tools_generated "${has_tools}" \
				--argjson prompts_generated "${has_prompts}" \
				--argjson static_registry "${has_static}" \
				'{
				manifest_version: "0.3",
				name: $name,
				version: $version,
				display_name: $display_name,
				description: $description
			}
			| if $long_description != "" then . + {long_description: $long_description} else . end
			| if $icon != "" then . + {icon: $icon} else . end
			| if $author_name != "" then . + {author: {name: $author_name}} else . end
			| if $author_email != "" then .author.email = $author_email else . end
			| if $author_url != "" then .author.url = $author_url else . end
			| if $repository_url != "" then . + {repository: {type: "git", url: $repository_url}} else . end
			| if $tools_generated then . + {tools_generated: true} else . end
			| if $prompts_generated then . + {prompts_generated: true} else . end
			| . + {
				server: {
					type: "binary",
					entry_point: "server/run-server.sh",
					mcp_config: {
						command: "${__dirname}/server/run-server.sh",
						args: [],
						env: ({
							MCPBASH_PROJECT_ROOT: "${__dirname}/server",
							MCPBASH_TOOL_ALLOWLIST: "*"
						} + (if $static_registry then {MCPBASH_STATIC_REGISTRY: "1"} else {} end))
					}
				},
				compatibility: {
					platforms: $platforms
				}
			}'
		)"
		printf '%s\n' "${manifest}" >"${output}"
	elif [ -f "${template}" ]; then
		# Fallback to template substitution (doesn't support dynamic platforms/icon)
		mcp_template_render "${template}" "${output}" \
			"__NAME__=${RESOLVED_NAME}" \
			"__VERSION__=${RESOLVED_VERSION}" \
			"__DISPLAY_NAME__=${RESOLVED_TITLE}" \
			"__DESCRIPTION__=${RESOLVED_DESCRIPTION}" \
			"__AUTHOR_NAME__=${RESOLVED_AUTHOR_NAME:-Unknown}" \
			"__AUTHOR_EMAIL__=${RESOLVED_AUTHOR_EMAIL:-}" \
			"__AUTHOR_URL__=${RESOLVED_AUTHOR_URL:-}" \
			"__REPOSITORY_URL__=${RESOLVED_REPOSITORY:-}"
	else
		# Inline fallback per MCPB v0.3 spec (limited functionality without JSON tool)
		local icon_line=""
		local static_registry_line=""
		if [ -n "${BUNDLED_ICON:-}" ]; then
			icon_line="\"icon\": \"${BUNDLED_ICON}\","
		fi
		if [ "${BUNDLE_STATIC_REGISTRY:-}" = "true" ]; then
			static_registry_line=',
        "MCPBASH_STATIC_REGISTRY": "1"'
		fi
		cat >"${output}" <<EOF
{
  "manifest_version": "0.3",
  "name": "${RESOLVED_NAME}",
  "version": "${RESOLVED_VERSION}",
  "display_name": "${RESOLVED_TITLE}",
  "description": "${RESOLVED_DESCRIPTION}",
  ${icon_line}
  "server": {
    "type": "binary",
    "entry_point": "server/run-server.sh",
    "mcp_config": {
      "command": "\${__dirname}/server/run-server.sh",
      "args": [],
      "env": {
        "MCPBASH_PROJECT_ROOT": "\${__dirname}/server",
        "MCPBASH_TOOL_ALLOWLIST": "*"${static_registry_line}
      }
    }
  },
  "compatibility": {
    "platforms": ${platforms_json}
  }
}
EOF
	fi
}

mcp_bundle_create_archive() {
	local staging_dir="$1"
	local output_path="$2"
	local verbose="$3"

	# Create ZIP archive
	(
		cd "${staging_dir}"
		zip -rq "${output_path}" .
	)

	if [ "${verbose}" = "true" ]; then
		local size
		size="$(du -h "${output_path}" 2>/dev/null | cut -f1)"
		printf '    Created archive (%s)\n' "${size}"
	fi
}

mcp_bundle_count_components() {
	local project_root="$1"
	local tools=0
	local resources=0
	local prompts=0

	if [ -d "${project_root}/tools" ]; then
		tools="$(find "${project_root}/tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
	fi
	if [ -d "${project_root}/resources" ]; then
		resources="$(find "${project_root}/resources" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
	fi
	if [ -d "${project_root}/prompts" ]; then
		prompts="$(find "${project_root}/prompts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
	fi

	echo "${tools}:${resources}:${prompts}"
}

mcp_cli_bundle() {
	local output_dir=""
	local name_override=""
	local version_override=""
	local platform_override=""
	local include_gojq="false"
	local validate_only="false"
	local verbose="false"

	# Parse arguments
	while [ $# -gt 0 ]; do
		case "$1" in
		--output)
			shift
			output_dir="${1:-}"
			;;
		--name)
			shift
			name_override="${1:-}"
			;;
		--version)
			shift
			version_override="${1:-}"
			;;
		--platform)
			shift
			platform_override="${1:-}"
			;;
		--include-gojq)
			include_gojq="true"
			;;
		--validate)
			validate_only="true"
			;;
		--verbose)
			verbose="true"
			;;
		--help | -h)
			mcp_bundle_usage
			;;
		*)
			printf 'Unknown option: %s\n' "$1" >&2
			printf 'Run "mcp-bash bundle --help" for usage\n' >&2
			exit 2
			;;
		esac
		shift
	done

	# Default output directory
	if [ -z "${output_dir}" ]; then
		output_dir="${PWD}"
	fi

	# Handle platform selection
	if [ -n "${platform_override}" ]; then
		case "${platform_override}" in
		darwin | linux | win32)
			BUNDLE_PLATFORMS="${platform_override}"
			;;
		all)
			BUNDLE_PLATFORMS="darwin linux win32"
			;;
		*)
			printf 'Unknown platform: %s\n' "${platform_override}" >&2
			printf 'Valid platforms: darwin, linux, win32, all\n' >&2
			exit 2
			;;
		esac
	fi

	# Initialize runtime for JSON tooling and project detection
	require_bash_runtime
	initialize_runtime_paths

	# Detect JSON tool
	mcp_runtime_detect_json_tool

	# Find project root
	mcp_scaffold_require_project_root

	# Validate project
	printf 'Validating project...\n'
	if ! mcp_bundle_validate_project "${MCPBASH_PROJECT_ROOT}" "${verbose}"; then
		printf '\n\342\234\227 Bundle validation failed.\n' >&2
		exit 1
	fi
	printf '  \342\234\223 Validated project structure\n'

	# Load config and resolve metadata
	mcp_bundle_load_config "${MCPBASH_PROJECT_ROOT}"
	mcp_bundle_resolve_metadata "${MCPBASH_PROJECT_ROOT}" "${name_override}" "${version_override}"

	# Warn if author is missing (required by MCPB spec)
	mcp_bundle_warn_missing_author

	# Static registry mode handling (default: true for zero-config fast cold start)
	# Bundle creators can opt out with MCPB_STATIC=false in mcpb.conf
	case "${MCPB_STATIC:-true}" in
	false | 0 | no | off) BUNDLE_STATIC_REGISTRY="" ;;
	*) BUNDLE_STATIC_REGISTRY="true" ;;
	esac

	if [ "${BUNDLE_STATIC_REGISTRY}" = "true" ]; then
		if [ "${verbose}" = "true" ]; then
			printf '  Pre-generating registry cache for static mode...\n'
		fi
		# Pre-generate registries (uses MCPBASH_HOME which is set by common.sh)
		local refresh_output=""
		if ! refresh_output=$("${MCPBASH_HOME}/bin/mcp-bash" registry refresh --project-root "${MCPBASH_PROJECT_ROOT}" --no-notify 2>&1); then
			printf '  \342\232\240 Warning: Failed to pre-generate registries for static mode\n' >&2
			if [ -n "${refresh_output}" ]; then
				printf '    %s\n' "${refresh_output}" >&2
			fi
			printf '    Bundle will work but may have slower cold start\n' >&2
			# Don't fail the bundle - static mode is an optimization
		else
			if [ "${verbose}" = "true" ]; then
				printf '    Registry cache generated successfully\n'
			fi
		fi
		# Ensure .registry is included (MCPB_INCLUDE is space-separated)
		if ! mcp_bundle_list_contains "${MCPB_INCLUDE:-}" ".registry"; then
			MCPB_INCLUDE="${MCPB_INCLUDE:+$MCPB_INCLUDE }.registry"
		fi
	fi

	if [ "${verbose}" = "true" ]; then
		printf '  \342\234\223 Resolved metadata: %s v%s\n' "${RESOLVED_NAME}" "${RESOLVED_VERSION}"
		if [ -n "${RESOLVED_AUTHOR_NAME:-}" ]; then
			printf '    Author: %s\n' "${RESOLVED_AUTHOR_NAME}"
		fi
	fi

	# If validate only, stop here
	if [ "${validate_only}" = "true" ]; then
		printf '\n\342\234\223 Validation passed. Bundle would be: %s-%s.mcpb\n' "${RESOLVED_NAME}" "${RESOLVED_VERSION}"
		exit 0
	fi

	# Check dependencies (only needed for actual bundling, not validation)
	if ! mcp_bundle_check_dependencies; then
		exit 3
	fi

	# Create staging directory
	local staging_dir
	staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/mcpbash.bundle.XXXXXX")"
	trap 'rm -rf "${staging_dir}"' EXIT

	local staging_server="${staging_dir}/server"
	mkdir -p "${staging_server}"

	# Copy project content
	printf 'Bundling project...\n'
	mcp_bundle_copy_project "${MCPBASH_PROJECT_ROOT}" "${staging_server}" "${verbose}"

	# Embed framework
	mcp_bundle_embed_framework "${staging_server}" "${verbose}"

	# Embed gojq if requested
	if [ "${include_gojq}" = "true" ]; then
		if mcp_bundle_embed_gojq "${staging_server}" "${BUNDLE_PLATFORMS}" "${verbose}"; then
			printf '  \342\234\223 Embedded gojq for JSON processing\n'
		fi
	fi

	# Generate wrapper script
	mcp_bundle_generate_wrapper "${staging_server}"
	if [ "${verbose}" = "true" ]; then
		printf '    Generated run-server.sh\n'
	fi

	# Generate manifest
	mcp_bundle_generate_manifest "${staging_dir}" "${MCPBASH_PROJECT_ROOT}"
	printf '  \342\234\223 Generated manifest.json\n'

	# Create output directory if needed and resolve to absolute path
	mkdir -p "${output_dir}"
	output_dir="$(cd "${output_dir}" && pwd)"

	# Create archive
	local bundle_filename="${RESOLVED_NAME}-${RESOLVED_VERSION}.mcpb"
	local output_path="${output_dir}/${bundle_filename}"

	# Remove existing bundle if present
	rm -f "${output_path}"

	mcp_bundle_create_archive "${staging_dir}" "${output_path}" "${verbose}"

	# Count components
	local counts
	counts="$(mcp_bundle_count_components "${MCPBASH_PROJECT_ROOT}")"
	local tools="${counts%%:*}"
	local rest="${counts#*:}"
	local resources="${rest%%:*}"
	local prompts="${rest#*:}"

	# Get framework size
	local fw_size
	fw_size="$(du -sh "${staging_server}/.mcp-bash" 2>/dev/null | cut -f1)"

	# Final output
	local size
	size="$(du -h "${output_path}" 2>/dev/null | cut -f1)"

	printf '  \342\234\223 Bundled framework (%s)\n' "${fw_size}"
	printf '  \342\234\223 Included %s tools, %s resources, %s prompts\n' "${tools}" "${resources}" "${prompts}"
	if [ -n "${BUNDLED_ICON:-}" ]; then
		printf '  \342\234\223 Included icon: %s\n' "${BUNDLED_ICON}"
	fi
	printf '  \342\234\223 Target platforms: %s\n' "${BUNDLE_PLATFORMS}"
	printf '\n'
	printf 'Created: %s (%s)\n' "${output_path}" "${size}"
	printf '\n'
	printf 'Next steps:\n'
	printf '  \342\200\242 Install: Double-click the .mcpb file or drag to an MCPB-compatible client\n'
	printf '    (e.g., Claude Desktop, or any app supporting the MCPB format)\n'
	printf '  \342\200\242 Verify: Check that your tools appear in the client\n'
	printf '  \342\200\242 Publish: Submit to https://registry.modelcontextprotocol.io/\n'

	exit 0
}
