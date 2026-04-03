#!/usr/bin/env bash
# Shared framework embedding logic used by both 'bundle' and 'vendor'.
# Provides: EMBED_REQUIRED_LIBS, mcp_embed_framework(), mcp_embed_compute_hash()

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash embed helpers; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: MCPBASH_HOME (from bin/mcp-bash)

# Required framework lib files to embed.
# Must stay in sync with the direct '. "${MCPBASH_HOME}/lib/..."' sources in bin/mcp-bash.
# Enforced by test/unit/bundle_libs_sync.bats.
EMBED_REQUIRED_LIBS="require runtime json hash ids lock io paginate logging auth uri policy tools_policy registry spec tools resources prompts completion timeout elicitation roots rpc core handler_helpers validate path resource_content resource_providers progress progress-passthrough capabilities ui ui-templates"

# mcp_embed_framework <dest_dir> <verbose>
#
# Copy the minimal runtime subset into <dest_dir>/.mcp-bash/.
# <dest_dir> is the staging or project root directory.
# <verbose> is "true" or "false".
#
# Copies: bin/mcp-bash, lib/ (EMBED_REQUIRED_LIBS + cli/common + cli/health),
#         handlers/*.sh, sdk/tool-sdk.sh, providers/*.sh, VERSION
mcp_embed_framework() {
	local dest_dir="$1"
	local verbose="${2:-false}"

	local framework_dir="${dest_dir}/.mcp-bash"
	mkdir -p "${framework_dir}/bin"
	mkdir -p "${framework_dir}/lib/cli"
	mkdir -p "${framework_dir}/sdk"
	mkdir -p "${framework_dir}/handlers"
	mkdir -p "${framework_dir}/providers"

	# Copy main entry point
	cp "${MCPBASH_HOME}/bin/mcp-bash" "${framework_dir}/bin/"
	chmod +x "${framework_dir}/bin/mcp-bash"

	# Copy required runtime libs
	local lib
	for lib in ${EMBED_REQUIRED_LIBS}; do
		if [[ -f "${MCPBASH_HOME}/lib/${lib}.sh" ]]; then
			cp "${MCPBASH_HOME}/lib/${lib}.sh" "${framework_dir}/lib/"
		fi
	done

	# Copy cli helpers needed by the embedded mcp-bash binary
	cp "${MCPBASH_HOME}/lib/cli/common.sh" "${framework_dir}/lib/cli/"
	cp "${MCPBASH_HOME}/lib/cli/health.sh" "${framework_dir}/lib/cli/"

	# Copy SDK
	if [[ -f "${MCPBASH_HOME}/sdk/tool-sdk.sh" ]]; then
		cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${framework_dir}/sdk/"
	fi

	# Copy all handlers
	if [[ -d "${MCPBASH_HOME}/handlers" ]]; then
		cp "${MCPBASH_HOME}/handlers/"*.sh "${framework_dir}/handlers/" 2>/dev/null || true
	fi

	# Copy built-in resource providers.
	# lib/resources.sh and sdk/tool-sdk.sh resolve these via ${MCPBASH_HOME}/providers/,
	# so they must be present in the embedded tree.
	if [[ -d "${MCPBASH_HOME}/providers" ]]; then
		cp "${MCPBASH_HOME}/providers/"*.sh "${framework_dir}/providers/" 2>/dev/null || true
	fi

	# Copy VERSION
	if [[ -f "${MCPBASH_HOME}/VERSION" ]]; then
		cp "${MCPBASH_HOME}/VERSION" "${framework_dir}/"
	fi

	if [[ "${verbose}" == "true" ]]; then
		local size
		size="$(du -sh "${framework_dir}" 2>/dev/null | cut -f1)"
		printf '    Embedded framework (%s)\n' "${size}"
	fi
}

# mcp_embed_generate_wrapper <dest_dir>
#
# Write a run-server.sh wrapper script into <dest_dir>/ that launches the
# server via the embedded .mcp-bash/bin/mcp-bash binary.  This is the same
# wrapper used by MCPB bundles, pulled into the shared embed module so that
# both 'bundle' and 'vendor' produce consistent entry points.
#
# Reads the template from scaffold/bundle/run-server.sh.template when present,
# otherwise falls back to an inlined copy.
mcp_embed_generate_wrapper() {
	local dest_dir="$1"
	local template="${MCPBASH_HOME}/scaffold/bundle/run-server.sh.template"
	local output="${dest_dir}/run-server.sh"

	if [[ -f "${template}" ]]; then
		cp "${template}" "${output}"
	else
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

# Set project root to this server's directory
export MCPBASH_PROJECT_ROOT="${SCRIPT_DIR}"

# Use embedded gojq if present
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

# Internal: hash a single file. Requires _MCPBASH_EMBED_SHA_TOOL to be set.
_mcp_embed_sha256_file() {
	local path="$1"
	if [[ "${_MCPBASH_EMBED_SHA_TOOL}" == "sha256sum" ]]; then
		sha256sum "${path}" | awk '{print $1}'
	else
		shasum -a 256 "${path}" | awk '{print $1}'
	fi
}

# Internal: hash a string. Requires _MCPBASH_EMBED_SHA_TOOL to be set.
_mcp_embed_sha256_string() {
	local str="$1"
	if [[ "${_MCPBASH_EMBED_SHA_TOOL}" == "sha256sum" ]]; then
		printf '%s' "${str}" | sha256sum | awk '{print $1}'
	else
		printf '%s' "${str}" | shasum -a 256 | awk '{print $1}'
	fi
}

# mcp_embed_compute_hash <framework_dir>
#
# Compute a deterministic SHA-256 digest of all files under <framework_dir>.
# Algorithm: sort all file paths, hash each file's content, concatenate
# "<relpath>:<filehash>\n" lines, then hash the result.
# Excludes vendor.json itself so the hash is stable before the file is written.
#
# Outputs the hex digest on stdout. Returns 1 if no hash tool is available.
mcp_embed_compute_hash() {
	local framework_dir="$1"

	_MCPBASH_EMBED_SHA_TOOL=""
	if command -v sha256sum >/dev/null 2>&1; then
		_MCPBASH_EMBED_SHA_TOOL="sha256sum"
	elif command -v shasum >/dev/null 2>&1; then
		_MCPBASH_EMBED_SHA_TOOL="shasum"
	fi

	if [[ -z "${_MCPBASH_EMBED_SHA_TOOL}" ]]; then
		return 1
	fi

	local manifest=""
	local file rel_path file_hash

	while IFS= read -r file; do
		rel_path="${file#"${framework_dir}"/}"
		# Exclude vendor.json so the hash is stable before writing it
		[[ "${rel_path}" == "vendor.json" ]] && continue
		file_hash="$(_mcp_embed_sha256_file "${file}")"
		manifest="${manifest}${rel_path}:${file_hash}"$'\n'
	done < <(find "${framework_dir}" -type f | sort)

	_mcp_embed_sha256_string "${manifest}"
}
