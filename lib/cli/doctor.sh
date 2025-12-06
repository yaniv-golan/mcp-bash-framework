#!/usr/bin/env bash
# CLI doctor command.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash doctor; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: MCPBASH_HOME, MCPBASH_PROJECT_ROOT (optional), usage() from bin, runtime globals from initialize_runtime_paths.

mcp_cli_doctor() {
	local json_mode="false"

	while [ $# -gt 0 ]; do
		case "$1" in
		--json)
			json_mode="true"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash doctor [--json]

Diagnose environment and project setup.
EOF
			exit 0
			;;
		*)
			usage
			exit 1
			;;
		esac
		shift
	done

	require_bash_runtime
	initialize_runtime_paths

	local errors=0
	local warnings=0

	if [ "${json_mode}" = "true" ]; then
		local framework_home="${MCPBASH_HOME}"
		local framework_exists="false"
		local framework_version="unknown"
		local path_ok="false"
		local jq_path gojq_path json_tool="none"
		local project_root="" server_meta_valid="null" tools_count=0 registry_exists="false"

		if [ -d "${framework_home}" ]; then
			framework_exists="true"
		fi
		if [ -f "${framework_home}/VERSION" ]; then
			framework_version="$(tr -d '[:space:]' <"${framework_home}/VERSION" 2>/dev/null || printf 'unknown')"
		else
			warnings=$((warnings + 1))
		fi

		local resolved
		resolved="$(command -v mcp-bash 2>/dev/null || printf '')"
		if [ -n "${resolved}" ] && [ "${resolved}" = "${framework_home}/bin/mcp-bash" ]; then
			path_ok="true"
		else
			warnings=$((warnings + 1))
		fi

		jq_path="$(command -v jq 2>/dev/null || printf '')"
		gojq_path="$(command -v gojq 2>/dev/null || printf '')"
		if [ -n "${jq_path}" ]; then
			json_tool="jq"
		elif [ -n "${gojq_path}" ]; then
			json_tool="gojq"
		else
			errors=$((errors + 1))
		fi

		if project_root="$(mcp_runtime_find_project_root "${PWD}" 2>/dev/null)"; then
			if [ -f "${project_root}/server.d/server.meta.json" ] && [ -n "${jq_path}${gojq_path}" ]; then
				if [ -n "${jq_path}" ]; then
					if jq -e '.' "${project_root}/server.d/server.meta.json" >/dev/null 2>&1; then
						server_meta_valid="true"
					else
						server_meta_valid="false"
						warnings=$((warnings + 1))
					fi
				else
					if gojq -e '.' "${project_root}/server.d/server.meta.json" >/dev/null 2>&1; then
						server_meta_valid="true"
					else
						server_meta_valid="false"
						warnings=$((warnings + 1))
					fi
				fi
			fi
			if [ -d "${project_root}/tools" ]; then
				tools_count="$(find "${project_root}/tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
			fi
			if [ -d "${project_root}/.registry" ]; then
				registry_exists="true"
			else
				warnings=$((warnings + 1))
			fi
		fi

		cat <<EOF
{
  "framework": {
    "path": "${framework_home}",
    "exists": ${framework_exists},
    "version": "${framework_version}",
    "pathConfigured": ${path_ok}
  },
  "runtime": {
    "bashVersion": "${BASH_VERSION}",
    "jqPath": "${jq_path}",
    "gojqPath": "${gojq_path}",
    "jsonTool": "${json_tool}"
  },
  "project": {
    "root": "${project_root}",
    "serverMetaValid": ${server_meta_valid},
    "toolsCount": ${tools_count},
    "registryExists": ${registry_exists}
  },
  "errors": ${errors},
  "warnings": ${warnings}
}
EOF
		if [ "${errors}" -gt 0 ]; then
			exit 1
		fi
		exit 0
	fi

	printf 'mcp-bash Environment Check\n'
	printf '==========================\n\n'

	# Framework -----------------------------------------------------------
	printf 'Framework:\n'
	local framework_home="${MCPBASH_HOME}"
	if [ -d "${framework_home}" ]; then
		printf '  ✓ Location: %s\n' "${framework_home}"
	else
		printf '  ✗ Location not found: %s\n' "${framework_home}"
		errors=$((errors + 1))
	fi

	local version_file="${framework_home}/VERSION"
	local framework_version="unknown"
	if [ -f "${version_file}" ]; then
		framework_version="$(tr -d '[:space:]' <"${version_file}" 2>/dev/null || printf 'unknown')"
		printf '  ✓ Version: %s\n' "${framework_version}"
	else
		printf '  ⚠ VERSION file missing at %s\n' "${version_file}"
		warnings=$((warnings + 1))
	fi

	local resolved
	resolved="$(command -v mcp-bash 2>/dev/null || printf '')"
	if [ -n "${resolved}" ] && [ "${resolved}" = "${framework_home}/bin/mcp-bash" ]; then
		printf '  ✓ PATH configured correctly\n'
	else
		# PATH is recommended but not strictly required when invoking the
		# framework via an absolute path, so treat this as a warning rather
		# than a hard error to avoid failing doctor in local dev setups.
		printf '  ⚠ PATH not configured (run: export PATH="%s/bin:$PATH")\n' "${framework_home}"
		warnings=$((warnings + 1))
	fi

	# Runtime -------------------------------------------------------------
	printf '\nRuntime:\n'
	printf '  ✓ Bash version: %s (>= 3.2 required)\n' "${BASH_VERSION}"

	local jq_path gojq_path
	jq_path="$(command -v jq 2>/dev/null || printf '')"
	gojq_path="$(command -v gojq 2>/dev/null || printf '')"

	if [ -n "${jq_path}" ] || [ -n "${gojq_path}" ]; then
		if [ -n "${jq_path}" ]; then
			printf '  ✓ jq installed: %s\n' "${jq_path}"
		else
			printf '  ⚠ jq not installed (gojq will be used)\n'
			warnings=$((warnings + 1))
		fi
		if [ -n "${gojq_path}" ]; then
			printf '  ✓ gojq installed: %s\n' "${gojq_path}"
		else
			printf '  ⚠ gojq not installed (optional, faster than jq)\n'
			warnings=$((warnings + 1))
		fi
	else
		printf '  ✗ jq/gojq not installed (required for full functionality)\n'
		printf '    Install: brew install jq  OR  apt install jq\n'
		errors=$((errors + 1))
	fi

	# Project (optional) --------------------------------------------------
	printf '\nProject (if in project directory):\n'
	local detected_root=""
	if detected_root="$(mcp_runtime_find_project_root "${PWD}" 2>/dev/null)"; then
		printf '  ✓ Project root: %s\n' "${detected_root}"
		local meta="${detected_root}/server.d/server.meta.json"
		if [ -f "${meta}" ] && { [ -n "${jq_path}" ] || [ -n "${gojq_path}" ]; }; then
			local meta_tool=""
			if [ -n "${gojq_path}" ]; then
				meta_tool="${gojq_path}"
			else
				meta_tool="${jq_path}"
			fi
			if "${meta_tool}" -e '.' "${meta}" >/dev/null 2>&1; then
				printf '  ✓ server.d/server.meta.json: valid\n'
			else
				printf '  ⚠ server.d/server.meta.json: invalid JSON\n'
				warnings=$((warnings + 1))
			fi
		else
			printf '  ⚠ server.d/server.meta.json: not found or JSON tooling unavailable\n'
			warnings=$((warnings + 1))
		fi

		local tools_count=0
		if [ -d "${detected_root}/tools" ]; then
			tools_count="$(find "${detected_root}/tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
		fi
		printf '  ✓ Tools found: %s\n' "${tools_count}"

		if [ -d "${detected_root}/.registry" ]; then
			printf '  ✓ Registry: .registry/ exists\n'
		else
			printf '  ⚠ Registry: .registry/ does not exist (will be created on demand)\n'
			warnings=$((warnings + 1))
		fi
	else
		printf '  (no project detected in current directory)\n'
	fi

	# Optional dependencies -----------------------------------------------
	printf '\nOptional dependencies:\n'
	local shellcheck_path npx_path
	shellcheck_path="$(command -v shellcheck 2>/dev/null || printf '')"
	if [ -n "${shellcheck_path}" ]; then
		printf '  ✓ shellcheck: %s (for validation)\n' "${shellcheck_path}"
	else
		printf '  ⚠ shellcheck: not found (for validation)\n'
		warnings=$((warnings + 1))
	fi

	npx_path="$(command -v npx 2>/dev/null || printf '')"
	if [ -n "${npx_path}" ]; then
		printf '  ✓ npx: %s (for MCP Inspector)\n' "${npx_path}"
	else
		printf '  ⚠ npx: not found (for MCP Inspector)\n'
		warnings=$((warnings + 1))
	fi

	printf '\n'
	if [ "${errors}" -gt 0 ]; then
		printf '%d error(s), %d warning(s) found.\n' "${errors}" "${warnings}"
		printf '\nTip: Run '\''mcp-bash validate'\'' to check your project structure.\n'
		exit 1
	fi

	if [ "${warnings}" -gt 0 ]; then
		printf 'Checks passed with %d warning(s). Review the notes above before production use.\n' "${warnings}"
	else
		printf 'All checks passed! Ready to build MCP servers.\n'
	fi
	exit 0
}
