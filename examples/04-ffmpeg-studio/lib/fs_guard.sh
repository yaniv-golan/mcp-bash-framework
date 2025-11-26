#!/usr/bin/env bash
# shellcheck shell=bash

# Guard helpers that confine media access to configured roots.

declare -ga MCP_FFMPEG_ROOTS=()
declare -ga MCP_FFMPEG_MODES=()
declare -g MCP_FFMPEG_GUARD_READY=0
declare -g MCP_FFMPEG_GUARD_BASE=""

mcp_ffmpeg_guard_realpath() {
	local target="$1"
	if command -v realpath >/dev/null 2>&1; then
		realpath -m "${target}"
		return
	fi
	echo "mcp_ffmpeg_guard: realpath is required" >&2
	return 1
}

mcp_ffmpeg_guard_path_contains() {
	local root="$1"
	local candidate="$2"
	if [[ "${candidate}" == "${root}" ]] || [[ "${candidate}" == "${root}/"* ]]; then
		return 0
	fi
	return 1
}

mcp_ffmpeg_guard_init() {
	if [[ "${MCP_FFMPEG_GUARD_READY}" == "1" ]]; then
		return 0
	fi

	local base="$1"
	if [[ -z "${base}" ]]; then
		base="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	fi
	MCP_FFMPEG_GUARD_BASE="${base}"

	local config="${base}/config/media_roots.json"
	if [[ ! -f "${config}" ]]; then
		echo "mcp_ffmpeg_guard: missing config ${config}" >&2
		return 1
	fi

	local -a entries=()
	if ! mapfile -t entries < <(jq -r '
		.roots as $roots
		| if ($roots | type) != "array" or ($roots | length) == 0 then
			error("media_roots.json must define a non-empty \"roots\" array")
		  else
			$roots[]
			| if (.path | type) != "string" or (.path | length) == 0 then
				error("each root entry requires a non-empty \"path\"")
			  else
				"\(.path)\t\(.mode // \"rw\")"
			  end
		  end
	' "${config}"); then
		echo "mcp_ffmpeg_guard: invalid config in ${config}" >&2
		return 1
	fi

	if [[ "${#entries[@]}" -eq 0 ]]; then
		echo "mcp_ffmpeg_guard: no media roots configured" >&2
		return 1
	fi

	MCP_FFMPEG_ROOTS=()
	MCP_FFMPEG_MODES=()
	local -A seen=()

	for entry in "${entries[@]}"; do
		local raw_path="${entry%%$'\t'*}"
		local mode="${entry#*$'\t'}"
		case "${mode}" in
		rw | ro) ;;
		*)
			echo "mcp_ffmpeg_guard: invalid mode \"${mode}\" for path ${raw_path}" >&2
			return 1
			;;
		esac

		local abs_path
		if [[ "${raw_path}" == /* ]]; then
			abs_path="${raw_path}"
		else
			abs_path="${base}/${raw_path}"
		fi

		if ! abs_path="$(mcp_ffmpeg_guard_realpath "${abs_path}")"; then
			return 1
		fi

		if [[ "${abs_path}" != "/" ]]; then
			abs_path="${abs_path%/}"
		fi

		if [[ ! -d "${abs_path}" ]]; then
			echo "mcp_ffmpeg_guard: configured root ${abs_path} does not exist" >&2
			return 1
		fi

		if [[ -n "${seen[${abs_path}]:-}" ]]; then
			continue
		fi
		seen["${abs_path}"]=1
		MCP_FFMPEG_ROOTS+=("${abs_path}")
		MCP_FFMPEG_MODES+=("${mode}")
	done

	if [[ "${#MCP_FFMPEG_ROOTS[@]}" -eq 0 ]]; then
		echo "mcp_ffmpeg_guard: no usable media roots found" >&2
		return 1
	fi

	MCP_FFMPEG_GUARD_READY=1
	return 0
}

mcp_ffmpeg_guard_root_index() {
	local candidate="$1"
	for i in "${!MCP_FFMPEG_ROOTS[@]}"; do
		if mcp_ffmpeg_guard_path_contains "${MCP_FFMPEG_ROOTS[$i]}" "${candidate}"; then
			printf '%s' "${i}"
			return 0
		fi
	done
	return 1
}

mcp_ffmpeg_guard_resolve() {
	local desired_mode="$1"
	local user_path="$2"

	if [[ -z "${user_path}" ]]; then
		echo "mcp_ffmpeg_guard: path cannot be empty" >&2
		return 1
	fi

	if [[ "${MCP_FFMPEG_GUARD_READY}" != "1" ]]; then
		if ! mcp_ffmpeg_guard_init "${MCP_FFMPEG_GUARD_BASE}"; then
			return 1
		fi
	fi

	if [[ "${user_path}" == "~"* ]]; then
		user_path="${user_path/#\~/${HOME}}"
	fi

	local canonical=""
	local matched_index=-1

	if [[ "${user_path}" == /* ]]; then
		if ! canonical="$(mcp_ffmpeg_guard_realpath "${user_path}")"; then
			return 1
		fi
		if ! matched_index="$(mcp_ffmpeg_guard_root_index "${canonical}")"; then
			echo "mcp_ffmpeg_guard: ${canonical} is not within an allowed media root" >&2
			return 1
		fi
	else
		for i in "${!MCP_FFMPEG_ROOTS[@]}"; do
			local root="${MCP_FFMPEG_ROOTS[$i]}"
			local attempt
			if ! attempt="$(mcp_ffmpeg_guard_realpath "${root}/${user_path}")"; then
				return 1
			fi
			if mcp_ffmpeg_guard_path_contains "${root}" "${attempt}"; then
				canonical="${attempt}"
				matched_index="${i}"
				break
			fi
		done

		if [[ "${matched_index}" -lt 0 ]]; then
			echo "mcp_ffmpeg_guard: ${user_path} is not within an allowed media root" >&2
			return 1
		fi
	fi

	if [[ -z "${canonical}" ]]; then
		echo "mcp_ffmpeg_guard: failed to resolve ${user_path}" >&2
		return 1
	fi

	local root_mode="${MCP_FFMPEG_MODES[$matched_index]}"
	if [[ "${desired_mode}" == "write" && "${root_mode}" != "rw" ]]; then
		echo "mcp_ffmpeg_guard: ${MCP_FFMPEG_ROOTS[$matched_index]} is read-only" >&2
		return 1
	fi

	if [[ "${desired_mode}" == "write" ]]; then
		local parent
		parent="$(dirname "${canonical}")"
		if ! mcp_ffmpeg_guard_path_contains "${MCP_FFMPEG_ROOTS[$matched_index]}" "${parent}"; then
			echo "mcp_ffmpeg_guard: parent directory escapes the allowed root" >&2
			return 1
		fi
		if [[ ! -d "${parent}" ]]; then
			if ! mkdir -p "${parent}"; then
				echo "mcp_ffmpeg_guard: unable to create ${parent}" >&2
				return 1
			fi
		fi
	fi

	printf '%s' "${canonical}"
	return 0
}

mcp_ffmpeg_guard_read_path() {
	mcp_ffmpeg_guard_resolve "read" "$1"
}

mcp_ffmpeg_guard_write_path() {
	mcp_ffmpeg_guard_resolve "write" "$1"
}
