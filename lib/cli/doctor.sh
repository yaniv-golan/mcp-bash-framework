#!/usr/bin/env bash
# CLI doctor command.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash doctor; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: MCPBASH_HOME, MCPBASH_PROJECT_ROOT (optional), usage() from bin, runtime globals from initialize_runtime_paths.

# Project root for doctor. When MCPBASH_SERVER_DIR points at a custom server
# dir holding server.meta.json, MCPBASH_PROJECT_ROOT is the project (the
# upward walk below only recognises <root>/server.d/server.meta.json).
mcp_doctor_find_project_root() {
	if [ -n "${MCPBASH_SERVER_DIR:-}" ] && [ -n "${MCPBASH_PROJECT_ROOT:-}" ] && [ -f "${MCPBASH_SERVER_DIR}/server.meta.json" ]; then
		printf '%s' "${MCPBASH_PROJECT_ROOT}"
		return 0
	fi
	mcp_runtime_find_project_root "${PWD}"
}

# Check the registration file the server will actually use, the way it uses
# it (mcp_registry_register_apply): register.json when it is a file; otherwise
# register.sh, only with project hooks enabled and when it is executable or
# has a shebang. Prints one TAB-separated line per refusal: <file> <message>.
mcp_doctor_register_permission_issues() {
	local project_root="$1"
	command -v mcp_registry_register_check_permissions >/dev/null 2>&1 || . "${MCPBASH_HOME}/lib/registry.sh"
	local server_dir
	server_dir="$(mcp_runtime_effective_server_dir "${project_root}")"
	local file=""
	if [ -f "${server_dir}/register.json" ]; then
		file="register.json"
	elif [ -f "${server_dir}/register.sh" ] && mcp_registry_register_hooks_allowed; then
		if [ -x "${server_dir}/register.sh" ] || head -n1 "${server_dir}/register.sh" 2>/dev/null | grep -q '^#!'; then
			file="register.sh"
		fi
	fi
	[ -n "${file}" ] || return 0
	if ! MCPBASH_PROJECT_ROOT="${project_root}" mcp_registry_register_check_permissions "${server_dir}/${file}"; then
		printf '%s\t%s\n' "${file}" "$(MCPBASH_PROJECT_ROOT="${project_root}" mcp_registry_register_permission_message "$(mcp_runtime_server_dir_label "${project_root}")/${file}")"
	fi
}

# Render the tool/provider env policy (text mode). Names and states only; values
# are never printed. Results describe this shell, not the host that launches the
# server (for example Claude Desktop, which injects its own variables).
mcp_doctor_print_env_policy() {
	local meta_file="$1"
	local json_tool_bin="$2"
	command -v mcp_meta_env_report >/dev/null 2>&1 || . "${MCPBASH_HOME}/lib/meta_env.sh"
	local json_tool="none"
	[ -n "${json_tool_bin}" ] && json_tool="$(basename "${json_tool_bin}")"
	printf '\nTool/provider environment policy (in this shell):\n'
	local kind a b c scope_label
	while IFS=$'\t' read -r kind a b c; do
		case "${a}" in
		TOOL) scope_label="tools" ;;
		PROVIDER) scope_label="providers" ;;
		*) scope_label="${a}" ;;
		esac
		case "${kind}" in
		switch) printf '  ⚠ MCPBASH_IGNORE_META_ENV is set: server.meta.json env is ignored\n' ;;
		policy) printf '  ✓ %s: mode %s (from %s)\n' "${scope_label}" "${b}" "${c}" ;;
		name)
			case "${c}" in
			set) printf '      ✓ %s: set\n' "${b}" ;;
			*) printf '      · %s: %s here (a host such as Claude Desktop may inject it at launch)\n' "${b}" "${c}" ;;
			esac
			;;
		badname) printf '      ✗ %s: allowlist entry %s is not a valid variable name and is skipped\n' "${scope_label}" "${b}" ;;
		inherit) printf '  ⚠ %s: inherit mode without MCPBASH_%s_ENV_INHERIT_ALLOW=true will be refused\n' "${scope_label}" "${a}" ;;
		refused) printf '  ⚠ server.meta.json env.%s is ignored (not settable there)\n' "${a}" ;;
		invalid | error) printf '  ⚠ server.meta.json env.%s: %s\n' "${a}" "${b}" ;;
		esac
	done < <(MCPBASH_JSON_TOOL="${json_tool}" MCPBASH_JSON_TOOL_BIN="${json_tool_bin}" mcp_meta_env_report "${meta_file}")
	printf '  · A login profile exporting MCPBASH_*_ENV_* overrides server.meta.json for bundles too (run-server.sh sources it).\n'
}

mcp_cli_doctor() {
	local json_mode="false"
	local fix_mode="false"
	local dry_run_mode="false"
	local min_version=""
	local install_ref=""
	local install_archive=""
	local verify_sha256=""
	local allow_downgrade="false"

	while [ $# -gt 0 ]; do
		case "$1" in
		--json)
			json_mode="true"
			;;
		--fix)
			fix_mode="true"
			;;
		--dry-run)
			dry_run_mode="true"
			;;
		--min-version)
			shift
			min_version="${1:-}"
			if [ -z "${min_version}" ]; then
				printf '%s\n' "doctor: --min-version requires a value like 0.8.1" >&2
				exit 2
			fi
			;;
		--ref | --version)
			shift
			install_ref="${1:-}"
			if [ -z "${install_ref}" ]; then
				printf '%s\n' "doctor: --ref/--version requires a value like v0.8.1 or a commit SHA" >&2
				exit 2
			fi
			;;
		--archive)
			shift
			install_archive="${1:-}"
			if [ -z "${install_archive}" ]; then
				printf '%s\n' "doctor: --archive requires a local path or URL to a tar.gz" >&2
				exit 2
			fi
			;;
		--verify)
			shift
			verify_sha256="${1:-}"
			if [ -z "${verify_sha256}" ]; then
				printf '%s\n' "doctor: --verify requires a SHA256 checksum value" >&2
				exit 2
			fi
			;;
		--allow-downgrade)
			allow_downgrade="true"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash doctor [--json] [--dry-run|--fix]
                  [--min-version X.Y.Z]
                  [--archive PATH|URL --verify SHA256]
                  [--ref REF] [--allow-downgrade]

Diagnose environment and project setup.

Modes:
  doctor            Show current state (read-only).
  doctor --dry-run  Show proposed actions (read-only).
  doctor --fix      Apply safe repairs when allowed by policy.

Upgrade/install options (managed installs only):
  --min-version X.Y.Z  If current framework version is lower, propose/apply an upgrade.
  --archive SRC        Install/upgrade from a tar.gz (local path or URL).
  --verify SHA256      Verify the archive checksum (required with --archive).
  --ref REF            Install/upgrade from a git ref (tag/branch/commit). For tags like vX.Y.Z, doctor fetches + verifies release assets.
  --allow-downgrade    Allow installing a version lower than the current one.

Exit codes:
  0  Healthy (no errors)
  1  Errors found
  2  Invalid usage / unsupported operation / configuration error
  3  Policy refusal (e.g., refusing to modify a user-managed install)
EOF
			exit 0
			;;
		*)
			usage
			exit 2
			;;
		esac
		shift
	done

	if [ "${fix_mode}" = "true" ] && [ "${dry_run_mode}" = "true" ]; then
		printf '%s\n' "doctor: --fix and --dry-run are mutually exclusive" >&2
		exit 2
	fi

	require_bash_runtime
	initialize_runtime_paths

	mcp_doctor_semver_tuple() {
		local raw="${1:-}"
		raw="${raw#v}"
		local major="" minor="" patch=""
		IFS='.' read -r major minor patch _ <<<"${raw}"
		if [[ ! "${major}" =~ ^[0-9]+$ ]]; then
			return 1
		fi
		if [ -z "${minor}" ]; then
			minor="0"
		fi
		if [ -z "${patch}" ]; then
			patch="0"
		fi
		if [[ ! "${minor}" =~ ^[0-9]+$ ]] || [[ ! "${patch}" =~ ^[0-9]+$ ]]; then
			return 1
		fi
		printf '%s %s %s' "${major}" "${minor}" "${patch}"
		return 0
	}

	mcp_doctor_semver_cmp() {
		local a="${1:-}"
		local b="${2:-}"
		local at bt
		at="$(mcp_doctor_semver_tuple "${a}" 2>/dev/null || printf '')"
		bt="$(mcp_doctor_semver_tuple "${b}" 2>/dev/null || printf '')"
		if [ -z "${at}" ] || [ -z "${bt}" ]; then
			return 2
		fi
		# shellcheck disable=SC2086  # Intentional splitting of tuple.
		set -- ${at}
		local a1="$1" a2="$2" a3="$3"
		# shellcheck disable=SC2086  # Intentional splitting of tuple.
		set -- ${bt}
		local b1="$1" b2="$2" b3="$3"
		if [ "${a1}" -lt "${b1}" ]; then
			printf '%s' "-1"
		elif [ "${a1}" -gt "${b1}" ]; then
			printf '%s' "1"
		elif [ "${a2}" -lt "${b2}" ]; then
			printf '%s' "-1"
		elif [ "${a2}" -gt "${b2}" ]; then
			printf '%s' "1"
		elif [ "${a3}" -lt "${b3}" ]; then
			printf '%s' "-1"
		elif [ "${a3}" -gt "${b3}" ]; then
			printf '%s' "1"
		else
			printf '%s' "0"
		fi
	}

	mcp_doctor_sha256_tool() {
		if command -v sha256sum >/dev/null 2>&1; then
			printf '%s' "sha256sum"
			return 0
		fi
		if command -v shasum >/dev/null 2>&1; then
			printf '%s' "shasum"
			return 0
		fi
		return 1
	}

	mcp_doctor_compute_sha256() {
		local path="$1"
		local tool=""
		tool="$(mcp_doctor_sha256_tool 2>/dev/null || printf '')"
		if [ -z "${tool}" ]; then
			return 1
		fi
		if [ "${tool}" = "sha256sum" ]; then
			sha256sum "${path}" | awk '{print $1}'
		else
			shasum -a 256 "${path}" | awk '{print $1}'
		fi
	}

	mcp_doctor_fetch_url() {
		local url="$1"
		local out="$2"
		if ! command -v curl >/dev/null 2>&1; then
			return 1
		fi
		curl -fsSL "${url}" -o "${out}"
	}

	mcp_doctor_lock_acquire_timeout() {
		local lock_dir="$1"
		local timeout_secs="${2:-10}"
		local poll_secs="${3:-0.05}"
		local start now
		start="$(date +%s)"

		while :; do
			if mkdir "${lock_dir}" 2>/dev/null; then
				printf '%s' "${BASHPID:-$$}" >"${lock_dir}/pid" 2>/dev/null || true
				return 0
			fi

			if [ -f "${lock_dir}/pid" ]; then
				local owner=""
				owner="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
				if [ -n "${owner}" ] && ! kill -0 "${owner}" 2>/dev/null; then
					rm -rf "${lock_dir}" 2>/dev/null || true
					continue
				fi
			fi

			if [ "${timeout_secs}" -gt 0 ]; then
				now="$(date +%s)"
				if [ $((now - start)) -ge "${timeout_secs}" ]; then
					return 1
				fi
			else
				return 1
			fi
			sleep "${poll_secs}"
		done
	}

	mcp_doctor_lock_release() {
		local lock_dir="$1"
		rm -rf "${lock_dir}" 2>/dev/null || true
	}

	mcp_doctor_stage_from_local_source() {
		local src="$1"
		local dest="$2"
		[ -d "${src}" ] || return 1
		[ -d "${dest}" ] || return 1
		if ! command -v tar >/dev/null 2>&1; then
			return 1
		fi
		(cd "${src}" && tar -cf - --exclude .git .) | (cd "${dest}" && tar -xf -)
	}

	mcp_doctor_stage_from_archive() {
		local archive_path="$1"
		local dest="$2"
		[ -f "${archive_path}" ] || return 1
		[ -d "${dest}" ] || return 1
		if ! command -v tar >/dev/null 2>&1; then
			return 1
		fi
		tar -xzf "${archive_path}" -C "${dest}" --strip-components 1
	}

	mcp_doctor_make_stage_dir() {
		local target_parent="$1"
		mktemp -d "${target_parent%/}/.mcp-bash.stage.XXXXXX" 2>/dev/null
	}

	mcp_doctor_atomic_swap_dir() {
		local target_dir="$1"
		local stage_dir="$2"
		local keep_backup="${3:-false}"
		local ts=""
		ts="$(date +%s 2>/dev/null || printf '%s' "${BASHPID:-$$}")"
		local backup_dir="${target_dir}.backup.${ts}.$$"

		if [ -d "${target_dir}" ]; then
			if ! mv "${target_dir}" "${backup_dir}" 2>/dev/null; then
				return 1
			fi
		fi

		if mv "${stage_dir}" "${target_dir}" 2>/dev/null; then
			if [ "${keep_backup}" != "true" ] && [ -d "${backup_dir}" ]; then
				rm -rf "${backup_dir}" 2>/dev/null || true
			fi
			return 0
		fi

		# Swap failed; attempt rollback if we had a backup.
		if [ -d "${backup_dir}" ]; then
			rm -rf "${target_dir}" 2>/dev/null || true
			mv "${backup_dir}" "${target_dir}" 2>/dev/null || true
		fi
		return 1
	}

	mcp_doctor_write_installer_marker() {
		local install_dir="$1"
		local source="$2"
		local ref="$3"
		local verified="$4"
		local installed_at=""
		installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
		local version=""
		if [ -f "${install_dir}/VERSION" ]; then
			version="$(tr -d '[:space:]' <"${install_dir}/VERSION" 2>/dev/null || printf '')"
		fi
		local commit=""
		if [ -d "${install_dir}/.git" ] && command -v git >/dev/null 2>&1; then
			commit="$(git -C "${install_dir}" rev-parse HEAD 2>/dev/null || printf '')"
		fi
		mcp_doctor_json_escape() {
			local s="$1"
			s="${s//\\/\\\\}"
			s="${s//\"/\\\"}"
			s="${s//$'\n'/ }"
			printf '%s' "${s}"
		}
		cat >"${install_dir}/INSTALLER.json" <<EOF
{
  "managed": true,
  "installedAt": "$(mcp_doctor_json_escape "${installed_at}")",
  "source": "$(mcp_doctor_json_escape "${source}")",
  "ref": "$(mcp_doctor_json_escape "${ref}")",
  "version": "$(mcp_doctor_json_escape "${version}")",
  "commit": "$(mcp_doctor_json_escape "${commit}")",
  "verified": ${verified}
}
EOF
	}

	local errors=0
	local warnings=0

	if [ "${json_mode}" = "true" ]; then
		local schema_version=1
		local exit_code=0
		local findings_json="[]"
		local proposed_actions_json="[]"
		local actions_taken_json="[]"

		append_to_array() {
			local arr="$1"
			local item="$2"
			if [ "${arr}" = "[]" ]; then
				printf '[%s]' "${item}"
			else
				printf '%s,%s]' "${arr%"]"}" "${item}"
			fi
		}

		json_null_or_string() {
			local val="${1:-}"
			if [ -z "${val}" ]; then
				printf 'null'
			else
				mcp_json_escape_string "${val}"
			fi
		}

		add_finding() {
			local id="$1"
			local severity="$2"
			local message="$3"
			local fixable="$4"
			local suggested_command="${5:-}"
			local obj=""

			obj="$(
				printf '{"id":%s,"severity":%s,"message":%s,"fixable":%s,"suggestedCommand":%s}' \
					"$(mcp_json_escape_string "${id}")" \
					"$(mcp_json_escape_string "${severity}")" \
					"$(mcp_json_quote_text "${message}")" \
					"${fixable}" \
					"$(json_null_or_string "${suggested_command}")"
			)"
			findings_json="$(append_to_array "${findings_json}" "${obj}")"
		}

		add_action() {
			local arr_name="$1" # "proposed" | "taken"
			local id="$2"
			local message="$3"
			local command="${4:-}"
			local obj=""

			obj="$(
				printf '{"id":%s,"message":%s,"command":%s}' \
					"$(mcp_json_escape_string "${id}")" \
					"$(mcp_json_quote_text "${message}")" \
					"$(json_null_or_string "${command}")"
			)"
			if [ "${arr_name}" = "proposed" ]; then
				proposed_actions_json="$(append_to_array "${proposed_actions_json}" "${obj}")"
			else
				actions_taken_json="$(append_to_array "${actions_taken_json}" "${obj}")"
			fi
		}

		resolve_physical_path() {
			local path="$1"
			local resolved=""
			if command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1; then
				resolved="$(realpath -m "${path}" 2>/dev/null || printf '')"
			elif command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
				resolved="$(readlink -f "${path}" 2>/dev/null || printf '')"
			fi
			if [ -n "${resolved}" ]; then
				printf '%s' "${resolved}"
			else
				printf '%s' "${path}"
			fi
		}

		local framework_home="${MCPBASH_HOME}"
		local framework_exists="false"
		local framework_version="unknown"
		local path_ok="false"
		local jq_path gojq_path json_tool="none"
		local tmp_root="${MCPBASH_TMP_ROOT:-}"
		local tmp_root_writable="false"
		local project_root="" server_meta_valid="null" tools_count=0 registry_exists="false" env_policy_json="null"
		local is_darwin="false" quarantine_supported="false"
		local framework_quarantine="null" project_quarantine="null"
		local is_msys="false" msys_hint=""

		local managed_root="${XDG_DATA_HOME:-$HOME/.local/share}/mcp-bash"
		local installer_marker="${framework_home%/}/INSTALLER.json"
		local marker_present="false"
		local install_managed="false"
		local install_reason=""

		local bin_dir="${HOME}/.local/bin"
		if [ -n "${XDG_BIN_HOME:-}" ]; then
			bin_dir="${XDG_BIN_HOME}"
		fi
		local shim_path="${bin_dir%/}/mcp-bash"
		local shim_target="${framework_home%/}/bin/mcp-bash"
		local shim_status="missing"
		local shim_detail=""

		local uname_s
		uname_s="$(uname -s 2>/dev/null || printf '')"

		if [ -d "${framework_home}" ]; then
			framework_exists="true"
		else
			errors=$((errors + 1))
			add_finding "framework.missing" "error" "Framework location not found: ${framework_home}" "false" ""
		fi

		if [ -f "${framework_home}/VERSION" ]; then
			framework_version="$(tr -d '[:space:]' <"${framework_home}/VERSION" 2>/dev/null || printf 'unknown')"
		else
			warnings=$((warnings + 1))
			add_finding "framework.version_missing" "warning" "VERSION file missing at ${framework_home}/VERSION" "false" ""
		fi

		local resolved
		resolved="$(command -v mcp-bash 2>/dev/null || printf '')"
		if [ -n "${resolved}" ] && [ "${resolved}" = "${framework_home}/bin/mcp-bash" ]; then
			path_ok="true"
		else
			warnings=$((warnings + 1))
			add_finding "path.not_configured" "warning" "PATH does not resolve mcp-bash to ${framework_home}/bin/mcp-bash" "false" "export PATH=\"${framework_home}/bin:\\$PATH\""
		fi

		jq_path="$(command -v jq 2>/dev/null || printf '')"
		gojq_path="$(command -v gojq 2>/dev/null || printf '')"
		if [ -n "${jq_path}" ]; then
			json_tool="jq"
		elif [ -n "${gojq_path}" ]; then
			json_tool="gojq"
		else
			errors=$((errors + 1))
			add_finding "runtime.json_tool_missing" "error" "jq/gojq not installed (required for full functionality)" "false" "brew install jq"
		fi

		if [ -n "${tmp_root}" ]; then
			if mkdir -p "${tmp_root}" 2>/dev/null; then
				local tmp_probe=""
				tmp_probe="$(mktemp "${tmp_root%/}/mcpbash.doctor.XXXXXX" 2>/dev/null || printf '')"
				if [ -n "${tmp_probe}" ]; then
					tmp_root_writable="true"
					rm -f "${tmp_probe}" 2>/dev/null || true
				else
					errors=$((errors + 1))
					add_finding "runtime.tmp_root_not_writable" "error" "TMP root not writable: ${tmp_root}" "false" ""
				fi
			else
				errors=$((errors + 1))
				add_finding "runtime.tmp_root_not_writable" "error" "TMP root not writable: ${tmp_root}" "false" ""
			fi
		else
			warnings=$((warnings + 1))
			add_finding "runtime.tmp_root_unset" "warning" "MCPBASH_TMP_ROOT not set (using system TMPDIR)" "false" ""
		fi

		if project_root="$(mcp_doctor_find_project_root 2>/dev/null)"; then
			if [ -f "$(mcp_runtime_effective_server_dir "${project_root}")/server.meta.json" ] && [ -n "${jq_path}${gojq_path}" ]; then
				if [ -n "${jq_path}" ]; then
					if jq -e '.' "$(mcp_runtime_effective_server_dir "${project_root}")/server.meta.json" >/dev/null 2>&1; then
						server_meta_valid="true"
					else
						server_meta_valid="false"
						warnings=$((warnings + 1))
						add_finding "project.server_meta_invalid" "warning" "$(mcp_runtime_server_dir_label "${project_root}")/server.meta.json is invalid JSON" "false" ""
					fi
				else
					if gojq -e '.' "$(mcp_runtime_effective_server_dir "${project_root}")/server.meta.json" >/dev/null 2>&1; then
						server_meta_valid="true"
					else
						server_meta_valid="false"
						warnings=$((warnings + 1))
						add_finding "project.server_meta_invalid" "warning" "$(mcp_runtime_server_dir_label "${project_root}")/server.meta.json is invalid JSON" "false" ""
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
				add_finding "project.registry_missing" "warning" ".registry/ does not exist (will be created on demand)" "false" ""
			fi

			local reg_file reg_message
			while IFS=$'\t' read -r reg_file reg_message; do
				[ -n "${reg_file}" ] || continue
				errors=$((errors + 1))
				add_finding "project.register_permissions" "error" "${reg_message}" "false" ""
			done < <(mcp_doctor_register_permission_issues "${project_root}")

			# Tool/provider env policy, as seen from this shell. Names and states
			# only; values are never included.
			local env_json_tool="${gojq_path:-${jq_path}}"
			if [ -n "${env_json_tool}" ]; then
				command -v mcp_meta_env_report >/dev/null 2>&1 || . "${MCPBASH_HOME}/lib/meta_env.sh"
				local env_report
				env_report="$(MCPBASH_JSON_TOOL="$(basename "${env_json_tool}")" MCPBASH_JSON_TOOL_BIN="${env_json_tool}" mcp_meta_env_report "$(mcp_runtime_effective_server_dir "${project_root}")/server.meta.json")"
				env_policy_json="$(printf '%s\n' "${env_report}" | "${env_json_tool}" -R -s -c '
					[split("\n")[] | select(length > 0) | split("\t")] as $l
					| def scope($s):
						($l | map(select(.[0] == "policy" and .[1] == $s)) | .[0]) as $p
						| {mode: $p[2], source: $p[3],
							allowlist: [$l[] | select(.[0] == "name" and .[1] == $s) | {name: .[2], state: .[3]}],
							invalidNames: [$l[] | select(.[0] == "badname" and .[1] == $s) | .[2]],
							inheritBlocked: any($l[]; .[0] == "inherit" and .[1] == $s)};
					{scope: "this shell", metaIgnored: any($l[]; .[0] == "switch"),
						tool: scope("TOOL"), provider: scope("PROVIDER"),
						refusedKeys: [$l[] | select(.[0] == "refused") | .[1]],
						invalidKeys: [$l[] | select(.[0] == "invalid" or .[0] == "error") | {key: .[1], reason: .[2]}]}
				' 2>/dev/null || printf 'null')"
				local env_kind env_a env_b
				while IFS=$'\t' read -r env_kind env_a env_b _; do
					case "${env_kind}" in
					refused)
						warnings=$((warnings + 1))
						add_finding "project.env_key_refused" "warning" "server.meta.json env.${env_a} is ignored (only the tool/provider env-policy keys may be set there)" "false" ""
						;;
					invalid | error)
						warnings=$((warnings + 1))
						add_finding "project.env_key_invalid" "warning" "server.meta.json env.${env_a}: ${env_b}" "false" ""
						;;
					inherit)
						warnings=$((warnings + 1))
						add_finding "project.env_inherit_blocked" "warning" "${env_a} env mode is inherit but MCPBASH_${env_a}_ENV_INHERIT_ALLOW is not true; it will be refused" "false" ""
						;;
					badname)
						warnings=$((warnings + 1))
						add_finding "project.env_allowlist_invalid_name" "warning" "${env_a} env allowlist entry ${env_b} is not a valid variable name and is skipped" "false" ""
						;;
					esac
				done <<<"${env_report}"
			fi
		fi

		# Optional project requirements descriptor (<server dir>/requirements.json).
		# When present, use it to derive a minimum required framework version and
		# surface missing dependency tools as actionable findings.
		local requirements_path=""
		local requirements_min_version=""
		if [ -n "${project_root}" ]; then
			requirements_path="$(mcp_runtime_effective_server_dir "${project_root}")/requirements.json"
			if [ -f "${requirements_path}" ] && { [ -n "${jq_path}" ] || [ -n "${gojq_path}" ]; }; then
				local req_tool=""
				if [ -n "${jq_path}" ]; then
					req_tool="${jq_path}"
				else
					req_tool="${gojq_path}"
				fi
				if "${req_tool}" -e '.' "${requirements_path}" >/dev/null 2>&1; then
					requirements_min_version="$("${req_tool}" -r '.framework.minVersion // empty' "${requirements_path}" 2>/dev/null || printf '')"
					if [ -z "${min_version}" ] && [ -n "${requirements_min_version}" ]; then
						min_version="${requirements_min_version}"
					fi
					# Basic dependency existence checks (version parsing is intentionally deferred).
					local deps_json=""
					deps_json="$("${req_tool}" -c '.dependencies // []' "${requirements_path}" 2>/dev/null || printf '[]')"
					if [ -n "${deps_json}" ] && [ "${deps_json}" != "[]" ]; then
						# Iterate each dependency object.
						local dep name ors found cand
						while IFS= read -r dep; do
							[ -n "${dep}" ] || continue
							name="$("${req_tool}" -r '.name // empty' <<<"${dep}" 2>/dev/null || printf '')"
							ors="$("${req_tool}" -r '.or? // empty | if type=="array" then .[] else empty end' <<<"${dep}" 2>/dev/null || printf '')"
							if [ -n "${ors}" ]; then
								found="false"
								while IFS= read -r cand; do
									[ -n "${cand}" ] || continue
									if command -v "${cand}" >/dev/null 2>&1; then
										found="true"
										break
									fi
								done <<<"${ors}"
								if [ "${found}" != "true" ]; then
									errors=$((errors + 1))
									add_finding "deps.missing" "error" "Missing dependency (need one of: ${ors//$'\n'/, })" "false" ""
								fi
							elif [ -n "${name}" ]; then
								if ! command -v "${name}" >/dev/null 2>&1; then
									errors=$((errors + 1))
									add_finding "deps.missing" "error" "Missing dependency: ${name}" "false" ""
								fi
							fi
						done < <(printf '%s\n' "${deps_json}" | "${req_tool}" -c '.[]' 2>/dev/null || true)
					fi
				else
					warnings=$((warnings + 1))
					add_finding "project.requirements_invalid" "warning" "requirements.json is invalid JSON: ${requirements_path}" "false" ""
				fi
			fi
		fi

		if [ "${uname_s}" = "Darwin" ]; then
			is_darwin="true"
			if command -v xattr >/dev/null 2>&1; then
				quarantine_supported="true"
				if [ -e "${framework_home}/bin/mcp-bash" ] && xattr -p com.apple.quarantine "${framework_home}/bin/mcp-bash" >/dev/null 2>&1; then
					framework_quarantine="true"
					errors=$((errors + 1))
					add_finding "macos.framework_quarantined" "error" "Framework binary is quarantined: ${framework_home}/bin/mcp-bash" "true" "xattr -d com.apple.quarantine \"${framework_home}/bin/mcp-bash\""
				elif [ -e "${framework_home}/bin/mcp-bash" ]; then
					framework_quarantine="false"
				fi
				if [ -n "${project_root}" ] && [ -e "${project_root}" ] && xattr -p com.apple.quarantine "${project_root}" >/dev/null 2>&1; then
					project_quarantine="true"
					errors=$((errors + 1))
					add_finding "macos.project_quarantined" "error" "Project path is quarantined: ${project_root}" "true" "xattr -r -d com.apple.quarantine \"${project_root}\""
				elif [ -n "${project_root}" ] && [ -e "${project_root}" ]; then
					project_quarantine="false"
				fi
			else
				warnings=$((warnings + 1))
				add_finding "macos.xattr_missing" "warning" "xattr not found; cannot check com.apple.quarantine" "false" ""
			fi
		fi

		case "${uname_s}" in
		MINGW* | MSYS* | CYGWIN*)
			is_msys="true"
			msys_hint="Set MCPBASH_JSON_TOOL=jq and MSYS2_ARG_CONV_EXCL=* to avoid Windows/MSYS path and exec-limit issues."
			warnings=$((warnings + 1))
			add_finding "windows.msys_detected" "warning" "MSYS/Git Bash detected; see guidance for path normalization and jq behavior." "false" ""
			;;
		esac

		if [ -f "${installer_marker}" ]; then
			marker_present="true"
		fi
		framework_home_norm="$(resolve_physical_path "${framework_home}")"
		managed_root_norm="$(resolve_physical_path "${managed_root}")"
		case "${framework_home_norm%/}/" in
		"${managed_root_norm%/}/"*)
			if [ "${marker_present}" = "true" ]; then
				install_managed="true"
			else
				install_reason="missing marker file INSTALLER.json under managed root"
			fi
			;;
		*)
			install_reason="framework path is outside managed root"
			;;
		esac
		if [ "${install_managed}" = "true" ] && [ "${framework_home_norm%/}" != "${managed_root_norm%/}" ]; then
			install_managed="false"
			install_reason="framework path does not match managed root"
		fi

		if [ -L "${shim_path}" ]; then
			if [ -e "${shim_path}" ]; then
				link_target="$(readlink "${shim_path}" 2>/dev/null || printf '')"
				expected_resolved="$(resolve_physical_path "${shim_target}")"
				actual_resolved="$(resolve_physical_path "${link_target}")"
				if [ -n "${link_target}" ] && [ "${actual_resolved}" = "${expected_resolved}" ]; then
					shim_status="ok"
					shim_detail="symlink"
				else
					shim_status="wrong_target"
					shim_detail="${link_target}"
				fi
			else
				shim_status="broken"
				shim_detail="broken symlink"
			fi
		elif [ -e "${shim_path}" ]; then
			if [ "${is_msys}" = "true" ] && [ -f "${shim_path}" ] && grep -q 'mcp-bash managed shim; generated by doctor --fix' "${shim_path}" 2>/dev/null; then
				shim_status="ok"
				shim_detail="wrapper"
			else
				shim_status="not_symlink"
				shim_detail="existing file"
			fi
		else
			shim_status="missing"
		fi

		case "${shim_status}" in
		ok) ;;
		*)
			warnings=$((warnings + 1))
			add_finding "shim.status" "warning" "Shim is not ok (${shim_status}): ${shim_path}" "true" ""
			;;
		esac

		local upgrade_needed="false"
		local current_version="${framework_version}"
		if ! mcp_doctor_semver_tuple "${current_version}" >/dev/null 2>&1; then
			current_version="0.0.0"
		fi
		if [ -n "${min_version}" ]; then
			if ! mcp_doctor_semver_tuple "${min_version}" >/dev/null 2>&1; then
				errors=$((errors + 1))
				add_finding "doctor.min_version_invalid" "error" "Invalid --min-version value: ${min_version}" "false" ""
				if [ "${fix_mode}" = "true" ] || [ "${dry_run_mode}" = "true" ]; then
					exit_code=2
				fi
			else
				vcmp="$(mcp_doctor_semver_cmp "${current_version}" "${min_version}" 2>/dev/null || printf '')"
				if [ -n "${vcmp}" ] && [ "${vcmp}" -lt 0 ]; then
					upgrade_needed="true"
					add_finding "framework.version_too_old" "warning" "Framework version ${framework_version} is below required minimum ${min_version}" "true" ""
				fi
			fi
		fi

		local lock_acquired="false"
		local lock_dir="${managed_root_norm}.doctor.fix.lock"
		local lock_timeout="${MCPBASH_DOCTOR_LOCK_TIMEOUT_SECS:-10}"
		local lock_poll="${MCPBASH_DOCTOR_LOCK_POLL_SECS:-0.05}"
		local local_source="${MCPBASH_DOCTOR_LOCAL_SOURCE:-${MCPBASH_INSTALL_LOCAL_SOURCE:-}}"
		local keep_backup="${MCPBASH_DOCTOR_KEEP_BACKUP:-false}"
		local install_requested="false"
		if [ -n "${install_archive}" ] || [ -n "${install_ref}" ]; then
			install_requested="true"
		fi

		if [ "${fix_mode}" = "true" ] || [ "${dry_run_mode}" = "true" ]; then
			if [ "${install_managed}" != "true" ]; then
				exit_code=3
				add_action "proposed" "policy.refuse_user_managed" "Refusing to modify user-managed install (managed install required for --fix)." ""
			else
				if [ "${upgrade_needed}" = "true" ] || [ "${install_requested}" = "true" ]; then
					local upgrade_action_msg=""
					if [ "${upgrade_needed}" = "true" ]; then
						upgrade_action_msg="Upgrade managed framework install to satisfy minimum version ${min_version}"
					elif [ -n "${install_archive}" ]; then
						upgrade_action_msg="Install managed framework from archive ${install_archive}"
					elif [ -n "${install_ref}" ]; then
						upgrade_action_msg="Install managed framework from ref ${install_ref}"
					else
						upgrade_action_msg="Install managed framework from MCPBASH_DOCTOR_LOCAL_SOURCE"
					fi
					add_action "proposed" "self.upgrade" "${upgrade_action_msg}" ""
					if [ "${upgrade_needed}" = "true" ] && [ -z "${install_archive}${install_ref}${local_source}" ]; then
						add_finding "self.upgrade_source_missing" "error" "Upgrade required but no source provided; use --archive+--verify, --ref, or set MCPBASH_DOCTOR_LOCAL_SOURCE." "false" ""
						if [ "${fix_mode}" = "true" ]; then
							exit_code=2
						else
							errors=$((errors + 1))
						fi
					elif [ -n "${install_archive}" ] && [ -z "${verify_sha256}" ]; then
						add_finding "self.upgrade_verify_missing" "error" "--archive requires --verify SHA256 for safe upgrades." "false" ""
						exit_code=2
					elif [ "${fix_mode}" = "true" ] && [ "${exit_code}" -eq 0 ]; then
						if mcp_doctor_lock_acquire_timeout "${lock_dir}" "${lock_timeout}" "${lock_poll}"; then
							lock_acquired="true"
						else
							errors=$((errors + 1))
							add_finding "self.upgrade_lock_timeout" "error" "Timed out waiting for doctor fix lock: ${lock_dir}" "false" ""
						fi

						if [ "${lock_acquired}" = "true" ] && [ "${errors}" -eq 0 ]; then
							if [ "${upgrade_needed}" = "true" ] && [ "${install_requested}" != "true" ]; then
								# Concurrency safety: re-check the live managed install after acquiring the lock.
								live_version="$(tr -d '[:space:]' <"${managed_root_norm}/VERSION" 2>/dev/null || printf '')"
								if [ -n "${live_version}" ] && mcp_doctor_semver_tuple "${live_version}" >/dev/null 2>&1; then
									current_version="${live_version}"
									live_cmp="$(mcp_doctor_semver_cmp "${current_version}" "${min_version}" 2>/dev/null || printf '')"
									if [ -n "${live_cmp}" ] && [ "${live_cmp}" -ge 0 ]; then
										upgrade_needed="false"
									fi
								fi
							fi

							if [ "${upgrade_needed}" != "true" ] && [ "${install_requested}" != "true" ]; then
								:
							else
								target_parent="$(dirname "${managed_root_norm}")"
								stage_dir="$(mcp_doctor_make_stage_dir "${target_parent}" 2>/dev/null || printf '')"
								if [ -z "${stage_dir}" ] || [ ! -d "${stage_dir}" ]; then
									errors=$((errors + 1))
									add_finding "self.upgrade_stage_failed" "error" "Failed to create staging directory under ${target_parent}" "false" ""
								else
									upgrade_source="unknown"
									upgrade_ref=""
									upgrade_verified="false"
									cleanup_archive="false"
									archive_path="${install_archive}"

									if [ -n "${install_archive}" ]; then
										upgrade_source="archive"
										upgrade_ref="${install_archive}"
										case "${archive_path}" in
										http://* | https://*)
											tmp_archive="$(mktemp "${TMPDIR:-/tmp}/mcpbash.doctor.archive.XXXXXX.tar.gz" 2>/dev/null || printf '')"
											if [ -z "${tmp_archive}" ]; then
												errors=$((errors + 1))
												add_finding "self.upgrade_download_failed" "error" "Failed to allocate temp path for archive download" "false" ""
											elif ! mcp_doctor_fetch_url "${archive_path}" "${tmp_archive}" >/dev/null 2>&1; then
												errors=$((errors + 1))
												add_finding "self.upgrade_download_failed" "error" "Failed to download archive: ${archive_path}" "false" ""
												rm -f "${tmp_archive}" 2>/dev/null || true
											else
												archive_path="${tmp_archive}"
												cleanup_archive="true"
											fi
											;;
										file://*)
											archive_path="${archive_path#file://}"
											;;
										esac

										if [ "${errors}" -eq 0 ]; then
											computed_sha="$(mcp_doctor_compute_sha256 "${archive_path}" 2>/dev/null || printf '')"
											if [ -z "${computed_sha}" ]; then
												errors=$((errors + 1))
												add_finding "self.upgrade_verify_failed" "error" "No SHA256 tool available for verification (need sha256sum or shasum)" "false" ""
											elif [ "${computed_sha}" != "${verify_sha256}" ]; then
												errors=$((errors + 1))
												add_finding "self.upgrade_verify_failed" "error" "Archive checksum mismatch (expected ${verify_sha256}, got ${computed_sha})" "false" ""
											else
												upgrade_verified="true"
												if ! mcp_doctor_stage_from_archive "${archive_path}" "${stage_dir}" >/dev/null 2>&1; then
													errors=$((errors + 1))
													add_finding "self.upgrade_stage_failed" "error" "Failed to extract archive into staging directory" "false" ""
												fi
											fi
										fi
									elif [ -n "${install_ref}" ]; then
										upgrade_ref="${install_ref}"
										case "${install_ref}" in
										[0-9]*.[0-9]*.[0-9]*)
											upgrade_ref="v${install_ref}"
											;;
										esac
										case "${upgrade_ref}" in
										v*.*.*)
											upgrade_source="release"
											tar_url="https://github.com/yaniv-golan/mcp-bash-framework/releases/download/${upgrade_ref}/mcp-bash-${upgrade_ref}.tar.gz"
											sums_url="https://github.com/yaniv-golan/mcp-bash-framework/releases/download/${upgrade_ref}/SHA256SUMS"
											tmp_archive="$(mktemp "${TMPDIR:-/tmp}/mcpbash.doctor.release.XXXXXX.tar.gz" 2>/dev/null || printf '')"
											tmp_sums="$(mktemp "${TMPDIR:-/tmp}/mcpbash.doctor.sums.XXXXXX" 2>/dev/null || printf '')"
											if [ -z "${tmp_archive}" ] || [ -z "${tmp_sums}" ]; then
												errors=$((errors + 1))
												add_finding "self.upgrade_download_failed" "error" "Failed to allocate temp paths for release assets" "false" ""
											elif ! mcp_doctor_fetch_url "${sums_url}" "${tmp_sums}" >/dev/null 2>&1; then
												errors=$((errors + 1))
												add_finding "self.upgrade_download_failed" "error" "Failed to download SHA256SUMS: ${sums_url}" "false" ""
											elif ! mcp_doctor_fetch_url "${tar_url}" "${tmp_archive}" >/dev/null 2>&1; then
												errors=$((errors + 1))
												add_finding "self.upgrade_download_failed" "error" "Failed to download release archive: ${tar_url}" "false" ""
											else
												canonical_file="mcp-bash-${upgrade_ref}.tar.gz"
												expected_sha="$(awk -v f="${canonical_file}" '
													NF >= 2 {
														file=$2
														sub(/^\*/, "", file)
														if (file == f) { print $1; exit 0 }
													}
												' "${tmp_sums}" 2>/dev/null || true)"
												if [ -z "${expected_sha}" ]; then
													errors=$((errors + 1))
													add_finding "self.upgrade_verify_failed" "error" "SHA256SUMS missing entry for ${canonical_file}" "false" ""
												else
													computed_sha="$(mcp_doctor_compute_sha256 "${tmp_archive}" 2>/dev/null || printf '')"
													if [ -z "${computed_sha}" ] || [ "${computed_sha}" != "${expected_sha}" ]; then
														errors=$((errors + 1))
														add_finding "self.upgrade_verify_failed" "error" "Release archive checksum mismatch" "false" ""
													else
														upgrade_verified="true"
														if ! mcp_doctor_stage_from_archive "${tmp_archive}" "${stage_dir}" >/dev/null 2>&1; then
															errors=$((errors + 1))
															add_finding "self.upgrade_stage_failed" "error" "Failed to extract release archive into staging directory" "false" ""
														fi
													fi
												fi
											fi
											rm -f "${tmp_archive}" "${tmp_sums}" 2>/dev/null || true
											;;
										*)
											upgrade_source="git"
											repo_url="${MCPBASH_INSTALL_REPO_URL:-https://github.com/yaniv-golan/mcp-bash-framework.git}"
											if ! command -v git >/dev/null 2>&1; then
												errors=$((errors + 1))
												add_finding "self.upgrade_git_missing" "error" "git is required for --ref installs" "false" ""
											else
												if [[ "${upgrade_ref}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
													git init -q "${stage_dir}" >/dev/null 2>&1 || true
													git -C "${stage_dir}" remote add origin "${repo_url}" >/dev/null 2>&1 || true
													if git -C "${stage_dir}" fetch -q --depth 1 origin "${upgrade_ref}" >/dev/null 2>&1 && git -C "${stage_dir}" checkout -q FETCH_HEAD >/dev/null 2>&1; then
														head_sha="$(git -C "${stage_dir}" rev-parse HEAD 2>/dev/null || printf '')"
														case "${head_sha}" in
														"${upgrade_ref}"*) upgrade_verified="true" ;;
														esac
													else
														errors=$((errors + 1))
														add_finding "self.upgrade_git_failed" "error" "Failed to fetch/checkout git ref: ${upgrade_ref}" "false" ""
													fi
												else
													if ! git clone -q --depth 1 --branch "${upgrade_ref}" "${repo_url}" "${stage_dir}" >/dev/null 2>&1; then
														errors=$((errors + 1))
														add_finding "self.upgrade_git_failed" "error" "Failed to clone git ref: ${upgrade_ref}" "false" ""
													fi
												fi
											fi
											;;
										esac
									elif [ -n "${local_source}" ]; then
										upgrade_source="local"
										upgrade_ref="${local_source}"
										if ! mcp_doctor_stage_from_local_source "${local_source}" "${stage_dir}" >/dev/null 2>&1; then
											errors=$((errors + 1))
											add_finding "self.upgrade_stage_failed" "error" "Failed to stage install from local source: ${local_source}" "false" ""
										fi
									fi

									if [ "${cleanup_archive}" = "true" ] && [ -n "${archive_path}" ]; then
										rm -f "${archive_path}" 2>/dev/null || true
									fi

									if [ "${errors}" -eq 0 ]; then
										if [ ! -f "${stage_dir}/VERSION" ] || [ ! -f "${stage_dir}/lib/runtime.sh" ] || [ ! -f "${stage_dir}/bin/mcp-bash" ]; then
											errors=$((errors + 1))
											add_finding "self.upgrade_stage_invalid" "error" "Staged install missing required files (VERSION/bin/lib)" "false" ""
										fi
									fi

									if [ "${errors}" -eq 0 ]; then
										stage_version="$(tr -d '[:space:]' <"${stage_dir}/VERSION" 2>/dev/null || printf '0.0.0')"
										if [ -n "${min_version}" ] && mcp_doctor_semver_tuple "${stage_version}" >/dev/null 2>&1; then
											need_cmp="$(mcp_doctor_semver_cmp "${stage_version}" "${min_version}" 2>/dev/null || printf '')"
											if [ -n "${need_cmp}" ] && [ "${need_cmp}" -lt 0 ]; then
												errors=$((errors + 1))
												add_finding "self.upgrade_stage_too_old" "error" "Staged version ${stage_version} does not satisfy minimum ${min_version}" "false" ""
											fi
										fi

										if [ "${errors}" -eq 0 ] && mcp_doctor_semver_tuple "${stage_version}" >/dev/null 2>&1 && mcp_doctor_semver_tuple "${current_version}" >/dev/null 2>&1; then
											dcmp="$(mcp_doctor_semver_cmp "${stage_version}" "${current_version}" 2>/dev/null || printf '')"
											if [ -n "${dcmp}" ] && [ "${dcmp}" -lt 0 ] && [ "${allow_downgrade}" != "true" ]; then
												exit_code=3
												add_finding "self.upgrade_downgrade_refused" "error" "Refusing to downgrade from ${current_version} to ${stage_version} (use --allow-downgrade to override)" "false" ""
												errors=$((errors + 1))
											fi
										fi
									fi

									if [ "${errors}" -eq 0 ] && [ "${exit_code}" -eq 0 ]; then
										mcp_doctor_write_installer_marker "${stage_dir}" "${upgrade_source}" "${upgrade_ref}" "${upgrade_verified}"
										if mcp_doctor_atomic_swap_dir "${managed_root_norm}" "${stage_dir}" "${keep_backup}"; then
											framework_version="$(tr -d '[:space:]' <"${managed_root_norm}/VERSION" 2>/dev/null || printf 'unknown')"
											marker_present="true"
											add_action "taken" "self.upgrade" "Updated managed install to version ${framework_version}" ""
										else
											errors=$((errors + 1))
											add_finding "self.upgrade_swap_failed" "error" "Atomic swap into ${managed_root_norm} failed (no changes applied)" "false" ""
											rm -rf "${stage_dir}" 2>/dev/null || true
										fi
									else
										rm -rf "${stage_dir}" 2>/dev/null || true
									fi
								fi
							fi
						fi
					fi
				fi

				if [ "${shim_status}" != "ok" ]; then
					add_action "proposed" "shim.ensure" "Ensure ${shim_path} points to ${shim_target}" "ln -sf \"${shim_target}\" \"${shim_path}\""
					if [ "${fix_mode}" = "true" ] && [ "${exit_code}" -eq 0 ]; then
						if [ "${lock_acquired}" != "true" ]; then
							if mcp_doctor_lock_acquire_timeout "${lock_dir}" "${lock_timeout}" "${lock_poll}"; then
								lock_acquired="true"
							else
								errors=$((errors + 1))
								add_finding "shim.lock_timeout" "error" "Timed out waiting for doctor fix lock: ${lock_dir}" "false" ""
							fi
						fi
						if [ "${errors}" -eq 0 ]; then
							mkdir -p "${bin_dir}" 2>/dev/null || true
							if [ -e "${shim_path}" ] && [ ! -L "${shim_path}" ]; then
								errors=$((errors + 1))
								add_finding "shim.refuse_overwrite" "error" "Refusing to overwrite non-symlink at shim path: ${shim_path}" "false" "rm -f \"${shim_path}\""
							else
								if [ "${is_msys}" = "true" ]; then
									cat >"${shim_path}" <<EOF
#!/usr/bin/env bash
# mcp-bash managed shim; generated by doctor --fix
exec "$(printf '%s' "${shim_target}")" "\$@"
EOF
									chmod +x "${shim_path}" 2>/dev/null || true
									add_action "taken" "shim.ensure" "Wrote wrapper shim at ${shim_path}" ""
								else
									ln -sf "${shim_target}" "${shim_path}"
									add_action "taken" "shim.ensure" "Updated symlink at ${shim_path}" ""
								fi
								shim_status="ok"
							fi
						fi
					fi
				fi
			fi
		fi

		if [ "${lock_acquired}" = "true" ]; then
			mcp_doctor_lock_release "${lock_dir}"
		fi

		if [ "${exit_code}" -eq 0 ] && [ "${errors}" -gt 0 ]; then
			exit_code=1
		fi

		cat <<EOF
{
  "schemaVersion": ${schema_version},
  "exitCode": ${exit_code},
  "findings": ${findings_json},
  "proposedActions": ${proposed_actions_json},
  "actionsTaken": ${actions_taken_json},
  "framework": {
    "path": $(mcp_json_escape_string "${framework_home}"),
    "exists": ${framework_exists},
    "version": $(mcp_json_escape_string "${framework_version}"),
    "pathConfigured": ${path_ok}
  },
  "runtime": {
    "bashVersion": $(mcp_json_escape_string "${BASH_VERSION}"),
    "jqPath": $(mcp_json_escape_string "${jq_path}"),
    "gojqPath": $(mcp_json_escape_string "${gojq_path}"),
    "jsonTool": $(mcp_json_escape_string "${json_tool}"),
    "tmpRoot": $(mcp_json_escape_string "${tmp_root}"),
    "tmpRootWritable": ${tmp_root_writable}
  },
  "install": {
    "managedRoot": $(mcp_json_escape_string "${managed_root}"),
    "markerPath": $(mcp_json_escape_string "${installer_marker}"),
    "markerPresent": ${marker_present},
    "managed": ${install_managed},
    "reason": $(mcp_json_escape_string "${install_reason}")
  },
  "shim": {
    "path": $(mcp_json_escape_string "${shim_path}"),
    "target": $(mcp_json_escape_string "${shim_target}"),
    "status": $(mcp_json_escape_string "${shim_status}"),
    "detail": $(mcp_json_escape_string "${shim_detail}")
  },
  "macOS": {
    "detected": ${is_darwin},
    "quarantineCheckSupported": ${quarantine_supported},
    "frameworkQuarantined": ${framework_quarantine},
    "projectQuarantined": ${project_quarantine}
  },
  "windows": {
    "msysDetected": ${is_msys},
    "hint": $(mcp_json_escape_string "${msys_hint}")
  },
  "project": {
    "root": $(mcp_json_escape_string "${project_root}"),
    "serverMetaValid": ${server_meta_valid},
    "toolsCount": ${tools_count},
    "registryExists": ${registry_exists}
  },
  "envPolicy": ${env_policy_json},
  "errors": ${errors},
  "warnings": ${warnings}
}
EOF
		exit "${exit_code}"
	fi

	printf 'mcp-bash Environment Check\n'
	printf '==========================\n\n'

	# Framework -----------------------------------------------------------
	printf 'Framework:\n'
	local framework_home="${MCPBASH_HOME}"
	local managed_root="${XDG_DATA_HOME:-$HOME/.local/share}/mcp-bash"
	local installer_marker="${framework_home%/}/INSTALLER.json"
	local marker_present="false"
	local install_managed="false"
	local install_reason=""
	local uname_s=""
	uname_s="$(uname -s 2>/dev/null || printf '')"

	local bin_dir="${HOME}/.local/bin"
	if [ -n "${XDG_BIN_HOME:-}" ]; then
		bin_dir="${XDG_BIN_HOME}"
	fi
	local shim_path="${bin_dir%/}/mcp-bash"
	local shim_target="${framework_home%/}/bin/mcp-bash"
	local shim_status="missing"
	local shim_detail=""
	local is_msys="false"
	case "${uname_s}" in
	MINGW* | MSYS* | CYGWIN*)
		is_msys="true"
		;;
	esac

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
	if [ -n "${min_version}" ]; then
		current_version="${framework_version}"
		if ! mcp_doctor_semver_tuple "${current_version}" >/dev/null 2>&1; then
			current_version="0.0.0"
		fi
		if mcp_doctor_semver_tuple "${min_version}" >/dev/null 2>&1; then
			vcmp="$(mcp_doctor_semver_cmp "${current_version}" "${min_version}" 2>/dev/null || printf '')"
			if [ -n "${vcmp}" ] && [ "${vcmp}" -lt 0 ]; then
				printf '  ⚠ Version below minimum requirement: %s < %s\n' "${framework_version}" "${min_version}"
				warnings=$((warnings + 1))
			fi
		fi
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

	local tmp_root="${MCPBASH_TMP_ROOT:-}"
	if [ -z "${tmp_root}" ]; then
		printf '  ⚠ MCPBASH_TMP_ROOT not set (using system TMPDIR)\n'
		warnings=$((warnings + 1))
	elif mkdir -p "${tmp_root}" 2>/dev/null && tmp_probe="$(mktemp "${tmp_root%/}/mcpbash.doctor.XXXXXX" 2>/dev/null || printf '')"; then
		printf '  ✓ TMP root writable: %s\n' "${tmp_root}"
		rm -f "${tmp_probe}" 2>/dev/null || true
	else
		printf '  ✗ TMP root not writable: %s\n' "${tmp_root}"
		errors=$((errors + 1))
	fi

	# Optional project requirements descriptor (<server dir>/requirements.json).
	local req_project_root=""
	req_project_root="$(mcp_doctor_find_project_root 2>/dev/null || printf '')"
	if [ -n "${req_project_root}" ] && [ -z "${min_version}" ]; then
		local req_path
		req_path="$(mcp_runtime_effective_server_dir "${req_project_root}")/requirements.json"
		if [ -f "${req_path}" ] && { [ -n "${jq_path}" ] || [ -n "${gojq_path}" ]; }; then
			local req_tool=""
			if [ -n "${gojq_path}" ]; then
				req_tool="${gojq_path}"
			else
				req_tool="${jq_path}"
			fi
			if "${req_tool}" -e '.' "${req_path}" >/dev/null 2>&1; then
				min_version="$("${req_tool}" -r '.framework.minVersion // empty' "${req_path}" 2>/dev/null || printf '')"
			else
				warnings=$((warnings + 1))
				printf '  ⚠ requirements.json invalid JSON: %s\n' "${req_path}"
			fi
		fi
	fi

	# Managed install + shim ------------------------------------------------
	if [ -f "${installer_marker}" ]; then
		marker_present="true"
	fi
	framework_home_norm="${framework_home}"
	managed_root_norm="${managed_root}"
	if [ -d "${framework_home}" ]; then
		framework_home_norm="$(cd -P "${framework_home}" 2>/dev/null && pwd -P || printf '%s' "${framework_home}")"
	fi
	if [ -d "${managed_root}" ]; then
		managed_root_norm="$(cd -P "${managed_root}" 2>/dev/null && pwd -P || printf '%s' "${managed_root}")"
	fi
	case "${framework_home_norm%/}/" in
	"${managed_root_norm%/}/"*)
		if [ "${marker_present}" = "true" ]; then
			install_managed="true"
		else
			install_reason="missing marker file INSTALLER.json under managed root"
		fi
		;;
	*)
		install_reason="framework path is outside managed root"
		;;
	esac
	if [ "${install_managed}" = "true" ] && [ "${framework_home_norm%/}" != "${managed_root_norm%/}" ]; then
		install_managed="false"
		install_reason="framework path does not match managed root"
	fi

	if [ -L "${shim_path}" ]; then
		if [ -e "${shim_path}" ]; then
			link_target="$(readlink "${shim_path}" 2>/dev/null || printf '')"
			shim_status="wrong_target"
			shim_detail="${link_target}"
			if [ -n "${link_target}" ] && [ "${link_target}" = "${shim_target}" ]; then
				shim_status="ok"
				shim_detail="symlink"
			fi
		else
			shim_status="broken"
			shim_detail="broken symlink"
		fi
	elif [ -e "${shim_path}" ]; then
		if [ "${is_msys}" = "true" ] && [ -f "${shim_path}" ] && grep -q 'mcp-bash managed shim; generated by doctor --fix' "${shim_path}" 2>/dev/null; then
			shim_status="ok"
			shim_detail="wrapper"
		else
			shim_status="not_symlink"
			shim_detail="existing file"
		fi
	else
		shim_status="missing"
	fi

	printf '\nInstall management:\n'
	printf '  Managed root: %s\n' "${managed_root}"
	if [ "${install_managed}" = "true" ]; then
		printf '  ✓ Managed install: yes (marker: %s)\n' "${installer_marker}"
	else
		printf '  ⚠ Managed install: no (%s)\n' "${install_reason:-unknown}"
	fi
	printf '  Shim: %s\n' "${shim_path}"
	case "${shim_status}" in
	ok)
		printf '  ✓ Shim ok (%s)\n' "${shim_detail:-ok}"
		;;
	*)
		printf '  ⚠ Shim status: %s\n' "${shim_status}"
		warnings=$((warnings + 1))
		;;
	esac

	if [ "${dry_run_mode}" = "true" ] || [ "${fix_mode}" = "true" ]; then
		printf '\nActions:\n'
		if [ "${install_managed}" != "true" ]; then
			printf '  ✗ Refusing: user-managed install (managed install required for --fix)\n'
			exit 3
		fi

		local lock_dir="${managed_root_norm}.doctor.fix.lock"
		local lock_timeout="${MCPBASH_DOCTOR_LOCK_TIMEOUT_SECS:-10}"
		local lock_poll="${MCPBASH_DOCTOR_LOCK_POLL_SECS:-0.05}"
		local lock_acquired="false"
		local local_source="${MCPBASH_DOCTOR_LOCAL_SOURCE:-${MCPBASH_INSTALL_LOCAL_SOURCE:-}}"
		local current_version="${framework_version}"
		if ! mcp_doctor_semver_tuple "${current_version}" >/dev/null 2>&1; then
			current_version="0.0.0"
		fi
		local install_requested="false"
		if [ -n "${install_archive}" ] || [ -n "${install_ref}" ]; then
			install_requested="true"
		fi

		local upgrade_needed="false"
		if [ -n "${min_version}" ]; then
			if ! mcp_doctor_semver_tuple "${min_version}" >/dev/null 2>&1; then
				printf '  ✗ Invalid --min-version: %s\n' "${min_version}"
				exit 2
			fi
			vcmp="$(mcp_doctor_semver_cmp "${current_version}" "${min_version}" 2>/dev/null || printf '')"
			if [ -n "${vcmp}" ] && [ "${vcmp}" -lt 0 ]; then
				upgrade_needed="true"
				printf '  ⚠ Framework version %s is below required minimum %s\n' "${framework_version}" "${min_version}"
			fi
		fi

		local action_needed="false"
		if [ "${upgrade_needed}" = "true" ] || [ "${install_requested}" = "true" ]; then
			action_needed="true"
		fi

		if [ "${action_needed}" = "true" ]; then
			if [ "${upgrade_needed}" = "true" ] && [ -z "${install_archive}${install_ref}${local_source}" ]; then
				printf '  ✗ Upgrade required but no source provided (use --archive+--verify, --ref, or MCPBASH_DOCTOR_LOCAL_SOURCE)\n'
				exit 2
			fi
			if [ -n "${install_archive}" ] && [ -z "${verify_sha256}" ]; then
				printf '  ✗ --archive requires --verify SHA256 for safe upgrades\n'
				exit 2
			fi

			if [ "${dry_run_mode}" = "true" ]; then
				if [ "${upgrade_needed}" = "true" ]; then
					printf '  ⚠ Would upgrade managed install to satisfy minimum version %s\n' "${min_version}"
				elif [ -n "${install_archive}" ]; then
					printf '  ⚠ Would install managed install from archive %s\n' "${install_archive}"
				elif [ -n "${install_ref}" ]; then
					printf '  ⚠ Would install managed install from ref %s\n' "${install_ref}"
				else
					printf '  ⚠ Would install managed install from local source %s\n' "${local_source}"
				fi
			else
				if mcp_doctor_lock_acquire_timeout "${lock_dir}" "${lock_timeout}" "${lock_poll}"; then
					lock_acquired="true"
				else
					printf '  ✗ Timed out waiting for doctor fix lock: %s\n' "${lock_dir}"
					exit 1
				fi

				if [ "${upgrade_needed}" = "true" ] && [ "${install_requested}" != "true" ]; then
					# Concurrency safety: re-check the live managed install after acquiring the lock.
					live_version="$(tr -d '[:space:]' <"${managed_root_norm}/VERSION" 2>/dev/null || printf '')"
					if [ -n "${live_version}" ] && mcp_doctor_semver_tuple "${live_version}" >/dev/null 2>&1; then
						current_version="${live_version}"
						live_cmp="$(mcp_doctor_semver_cmp "${current_version}" "${min_version}" 2>/dev/null || printf '')"
						if [ -n "${live_cmp}" ] && [ "${live_cmp}" -ge 0 ]; then
							upgrade_needed="false"
						fi
					fi
				fi
				if [ "${upgrade_needed}" != "true" ] && [ "${install_requested}" != "true" ]; then
					printf '  ✓ Upgrade no longer needed (another process updated the managed install)\n'
				else
					target_parent="$(dirname "${managed_root_norm}")"
					stage_dir="$(mcp_doctor_make_stage_dir "${target_parent}" 2>/dev/null || printf '')"
					if [ -z "${stage_dir}" ] || [ ! -d "${stage_dir}" ]; then
						printf '  ✗ Failed to create staging directory under %s\n' "${target_parent}"
						mcp_doctor_lock_release "${lock_dir}"
						exit 1
					fi

					upgrade_source="unknown"
					upgrade_ref=""
					upgrade_verified="false"
					cleanup_archive="false"
					archive_path="${install_archive}"

					if [ -n "${install_archive}" ]; then
						upgrade_source="archive"
						upgrade_ref="${install_archive}"
						case "${archive_path}" in
						http://* | https://*)
							tmp_archive="$(mktemp "${TMPDIR:-/tmp}/mcpbash.doctor.archive.XXXXXX.tar.gz" 2>/dev/null || printf '')"
							if [ -z "${tmp_archive}" ] || ! mcp_doctor_fetch_url "${archive_path}" "${tmp_archive}" >/dev/null 2>&1; then
								printf '  ✗ Failed to download archive: %s\n' "${archive_path}"
								rm -f "${tmp_archive}" 2>/dev/null || true
								rm -rf "${stage_dir}" 2>/dev/null || true
								mcp_doctor_lock_release "${lock_dir}"
								exit 1
							fi
							archive_path="${tmp_archive}"
							cleanup_archive="true"
							;;
						file://*)
							archive_path="${archive_path#file://}"
							;;
						esac

						computed_sha="$(mcp_doctor_compute_sha256 "${archive_path}" 2>/dev/null || printf '')"
						if [ -z "${computed_sha}" ] || [ "${computed_sha}" != "${verify_sha256}" ]; then
							printf '  ✗ Archive checksum verification failed\n'
							rm -f "${archive_path}" 2>/dev/null || true
							rm -rf "${stage_dir}" 2>/dev/null || true
							mcp_doctor_lock_release "${lock_dir}"
							exit 1
						fi
						upgrade_verified="true"
						if ! mcp_doctor_stage_from_archive "${archive_path}" "${stage_dir}" >/dev/null 2>&1; then
							printf '  ✗ Failed to extract archive into staging directory\n'
							rm -f "${archive_path}" 2>/dev/null || true
							rm -rf "${stage_dir}" 2>/dev/null || true
							mcp_doctor_lock_release "${lock_dir}"
							exit 1
						fi
					elif [ -n "${install_ref}" ]; then
						upgrade_ref="${install_ref}"
						case "${install_ref}" in
						[0-9]*.[0-9]*.[0-9]*)
							upgrade_ref="v${install_ref}"
							;;
						esac
						case "${upgrade_ref}" in
						v*.*.*)
							upgrade_source="release"
							tar_url="https://github.com/yaniv-golan/mcp-bash-framework/releases/download/${upgrade_ref}/mcp-bash-${upgrade_ref}.tar.gz"
							sums_url="https://github.com/yaniv-golan/mcp-bash-framework/releases/download/${upgrade_ref}/SHA256SUMS"
							tmp_archive="$(mktemp "${TMPDIR:-/tmp}/mcpbash.doctor.release.XXXXXX.tar.gz" 2>/dev/null || printf '')"
							tmp_sums="$(mktemp "${TMPDIR:-/tmp}/mcpbash.doctor.sums.XXXXXX" 2>/dev/null || printf '')"
							if [ -z "${tmp_archive}" ] || [ -z "${tmp_sums}" ]; then
								printf '  ✗ Failed to allocate temp paths for release assets\n'
								rm -rf "${stage_dir}" 2>/dev/null || true
								mcp_doctor_lock_release "${lock_dir}"
								exit 1
							fi
							if ! mcp_doctor_fetch_url "${sums_url}" "${tmp_sums}" >/dev/null 2>&1 || ! mcp_doctor_fetch_url "${tar_url}" "${tmp_archive}" >/dev/null 2>&1; then
								printf '  ✗ Failed to download release assets\n'
								rm -f "${tmp_archive}" "${tmp_sums}" 2>/dev/null || true
								rm -rf "${stage_dir}" 2>/dev/null || true
								mcp_doctor_lock_release "${lock_dir}"
								exit 1
							fi
							canonical_file="mcp-bash-${upgrade_ref}.tar.gz"
							expected_sha="$(awk -v f="${canonical_file}" '
								NF >= 2 {
									file=$2
									sub(/^\*/, "", file)
									if (file == f) { print $1; exit 0 }
								}
							' "${tmp_sums}" 2>/dev/null || true)"
							computed_sha="$(mcp_doctor_compute_sha256 "${tmp_archive}" 2>/dev/null || printf '')"
							if [ -z "${expected_sha}" ] || [ -z "${computed_sha}" ] || [ "${computed_sha}" != "${expected_sha}" ]; then
								printf '  ✗ Release archive checksum verification failed\n'
								rm -f "${tmp_archive}" "${tmp_sums}" 2>/dev/null || true
								rm -rf "${stage_dir}" 2>/dev/null || true
								mcp_doctor_lock_release "${lock_dir}"
								exit 1
							fi
							upgrade_verified="true"
							if ! mcp_doctor_stage_from_archive "${tmp_archive}" "${stage_dir}" >/dev/null 2>&1; then
								printf '  ✗ Failed to extract release archive into staging directory\n'
								rm -f "${tmp_archive}" "${tmp_sums}" 2>/dev/null || true
								rm -rf "${stage_dir}" 2>/dev/null || true
								mcp_doctor_lock_release "${lock_dir}"
								exit 1
							fi
							rm -f "${tmp_archive}" "${tmp_sums}" 2>/dev/null || true
							;;
						*)
							upgrade_source="git"
							repo_url="${MCPBASH_INSTALL_REPO_URL:-https://github.com/yaniv-golan/mcp-bash-framework.git}"
							if ! command -v git >/dev/null 2>&1; then
								printf '  ✗ git is required for --ref installs\n'
								rm -rf "${stage_dir}" 2>/dev/null || true
								mcp_doctor_lock_release "${lock_dir}"
								exit 1
							fi
							if [[ "${upgrade_ref}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
								git init -q "${stage_dir}" >/dev/null 2>&1 || true
								git -C "${stage_dir}" remote add origin "${repo_url}" >/dev/null 2>&1 || true
								if ! git -C "${stage_dir}" fetch -q --depth 1 origin "${upgrade_ref}" >/dev/null 2>&1 || ! git -C "${stage_dir}" checkout -q FETCH_HEAD >/dev/null 2>&1; then
									printf '  ✗ Failed to fetch/checkout git ref: %s\n' "${upgrade_ref}"
									rm -rf "${stage_dir}" 2>/dev/null || true
									mcp_doctor_lock_release "${lock_dir}"
									exit 1
								fi
							else
								if ! git clone -q --depth 1 --branch "${upgrade_ref}" "${repo_url}" "${stage_dir}" >/dev/null 2>&1; then
									printf '  ✗ Failed to clone git ref: %s\n' "${upgrade_ref}"
									rm -rf "${stage_dir}" 2>/dev/null || true
									mcp_doctor_lock_release "${lock_dir}"
									exit 1
								fi
							fi
							;;
						esac
					elif [ -n "${local_source}" ]; then
						upgrade_source="local"
						upgrade_ref="${local_source}"
						if ! mcp_doctor_stage_from_local_source "${local_source}" "${stage_dir}" >/dev/null 2>&1; then
							printf '  ✗ Failed to stage install from local source: %s\n' "${local_source}"
							rm -rf "${stage_dir}" 2>/dev/null || true
							mcp_doctor_lock_release "${lock_dir}"
							exit 1
						fi
					fi

					if [ "${cleanup_archive}" = "true" ] && [ -n "${archive_path}" ]; then
						rm -f "${archive_path}" 2>/dev/null || true
					fi

					if [ ! -f "${stage_dir}/VERSION" ] || [ ! -f "${stage_dir}/lib/runtime.sh" ] || [ ! -f "${stage_dir}/bin/mcp-bash" ]; then
						printf '  ✗ Staged install missing required files (VERSION/bin/lib)\n'
						rm -rf "${stage_dir}" 2>/dev/null || true
						mcp_doctor_lock_release "${lock_dir}"
						exit 1
					fi

					stage_version="$(tr -d '[:space:]' <"${stage_dir}/VERSION" 2>/dev/null || printf '0.0.0')"
					if [ -n "${min_version}" ]; then
						need_cmp="$(mcp_doctor_semver_cmp "${stage_version}" "${min_version}" 2>/dev/null || printf '')"
						if [ -n "${need_cmp}" ] && [ "${need_cmp}" -lt 0 ]; then
							printf '  ✗ Staged version %s does not satisfy minimum %s\n' "${stage_version}" "${min_version}"
							rm -rf "${stage_dir}" 2>/dev/null || true
							mcp_doctor_lock_release "${lock_dir}"
							exit 1
						fi
					fi
					dcmp="$(mcp_doctor_semver_cmp "${stage_version}" "${current_version}" 2>/dev/null || printf '')"
					if [ -n "${dcmp}" ] && [ "${dcmp}" -lt 0 ] && [ "${allow_downgrade}" != "true" ]; then
						printf '  ✗ Refusing to downgrade from %s to %s (use --allow-downgrade)\n' "${current_version}" "${stage_version}"
						rm -rf "${stage_dir}" 2>/dev/null || true
						mcp_doctor_lock_release "${lock_dir}"
						exit 3
					fi

					mcp_doctor_write_installer_marker "${stage_dir}" "${upgrade_source}" "${upgrade_ref}" "${upgrade_verified}"
					if ! mcp_doctor_atomic_swap_dir "${managed_root_norm}" "${stage_dir}" "${MCPBASH_DOCTOR_KEEP_BACKUP:-false}"; then
						printf '  ✗ Atomic swap into %s failed (no changes applied)\n' "${managed_root_norm}"
						rm -rf "${stage_dir}" 2>/dev/null || true
						mcp_doctor_lock_release "${lock_dir}"
						exit 1
					fi
					framework_version="$(tr -d '[:space:]' <"${managed_root_norm}/VERSION" 2>/dev/null || printf 'unknown')"
					printf '  ✓ Updated managed install to version %s\n' "${framework_version}"
				fi
			fi
		fi

		if [ "${shim_status}" != "ok" ]; then
			if [ "${dry_run_mode}" = "true" ]; then
				printf '  ⚠ Would ensure shim: %s -> %s\n' "${shim_path}" "${shim_target}"
			else
				if [ "${lock_acquired}" != "true" ]; then
					if mcp_doctor_lock_acquire_timeout "${lock_dir}" "${lock_timeout}" "${lock_poll}"; then
						lock_acquired="true"
					else
						printf '  ✗ Timed out waiting for doctor fix lock: %s\n' "${lock_dir}"
						exit 1
					fi
				fi
				mkdir -p "${bin_dir}" 2>/dev/null || true
				if [ -e "${shim_path}" ] && [ ! -L "${shim_path}" ]; then
					printf '  ✗ Refusing to overwrite non-symlink at shim path: %s\n' "${shim_path}"
					errors=$((errors + 1))
				else
					if [ "${is_msys}" = "true" ]; then
						cat >"${shim_path}" <<EOF
#!/usr/bin/env bash
# mcp-bash managed shim; generated by doctor --fix
exec "$(printf '%s' "${shim_target}")" "\$@"
EOF
						chmod +x "${shim_path}" 2>/dev/null || true
						printf '  ✓ Wrote wrapper shim at %s\n' "${shim_path}"
					else
						ln -sf "${shim_target}" "${shim_path}"
						printf '  ✓ Updated symlink at %s\n' "${shim_path}"
					fi
				fi
			fi
		elif [ "${action_needed}" != "true" ]; then
			printf '  (no actions)\n'
		fi

		if [ "${lock_acquired}" = "true" ]; then
			mcp_doctor_lock_release "${lock_dir}"
		fi
	fi

	# Project (optional) --------------------------------------------------
	printf '\nProject (if in project directory):\n'
	local detected_root=""
	if detected_root="$(mcp_doctor_find_project_root 2>/dev/null)"; then
		printf '  ✓ Project root: %s\n' "${detected_root}"
		local meta
		meta="$(mcp_runtime_effective_server_dir "${detected_root}")/server.meta.json"
		if [ -f "${meta}" ] && { [ -n "${jq_path}" ] || [ -n "${gojq_path}" ]; }; then
			local meta_tool=""
			if [ -n "${gojq_path}" ]; then
				meta_tool="${gojq_path}"
			else
				meta_tool="${jq_path}"
			fi
			if "${meta_tool}" -e '.' "${meta}" >/dev/null 2>&1; then
				printf '  ✓ %s/server.meta.json: valid\n' "$(mcp_runtime_server_dir_label "${detected_root}")"
			else
				printf '  ⚠ %s/server.meta.json: invalid JSON\n' "$(mcp_runtime_server_dir_label "${detected_root}")"
				warnings=$((warnings + 1))
			fi
		else
			printf '  ⚠ %s/server.meta.json: not found or JSON tooling unavailable\n' "$(mcp_runtime_server_dir_label "${detected_root}")"
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

		local reg_file reg_message
		while IFS=$'\t' read -r reg_file reg_message; do
			[ -n "${reg_file}" ] || continue
			printf '  ✗ %s (every tools/resources/prompts list fails until fixed)\n' "${reg_message}"
			errors=$((errors + 1))
		done < <(mcp_doctor_register_permission_issues "${detected_root}")

		mcp_doctor_print_env_policy "$(mcp_runtime_effective_server_dir "${detected_root}")/server.meta.json" "${gojq_path:-${jq_path}}"
	else
		printf '  (no project detected in current directory)\n'
	fi

	case "${uname_s}" in
	MINGW* | MSYS* | CYGWIN*)
		printf '\nWindows/MSYS guidance:\n'
		printf '  ⚠ Set MCPBASH_JSON_TOOL=jq and MSYS2_ARG_CONV_EXCL="*" to avoid path mangling and jq exec-limit issues.\n'
		;;
	esac

	if [ "${uname_s}" = "Darwin" ]; then
		printf '\nmacOS checks:\n'
		if ! command -v xattr >/dev/null 2>&1; then
			printf '  ⚠ xattr not found; cannot check com.apple.quarantine\n'
			warnings=$((warnings + 1))
		else
			local framework_binary="${framework_home}/bin/mcp-bash"
			if [ -e "${framework_binary}" ] && xattr -p com.apple.quarantine "${framework_binary}" >/dev/null 2>&1; then
				printf '  ✗ Framework binary is quarantined: %s\n' "${framework_binary}"
				printf '    Clear with: xattr -d com.apple.quarantine "%s"\n' "${framework_binary}"
				errors=$((errors + 1))
			else
				printf '  ✓ Framework binary not quarantined\n'
			fi

			if [ -n "${detected_root}" ] && [ -e "${detected_root}" ]; then
				if xattr -p com.apple.quarantine "${detected_root}" >/dev/null 2>&1; then
					printf '  ✗ Project path is quarantined: %s\n' "${detected_root}"
					printf '    Clear with: xattr -r -d com.apple.quarantine "%s"\n' "${detected_root}"
					errors=$((errors + 1))
				else
					printf '  ✓ Project path not quarantined\n'
				fi
			fi
		fi
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
