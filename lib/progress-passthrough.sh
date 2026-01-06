#!/usr/bin/env bash
# Progress passthrough helpers for running subprocesses with automatic progress forwarding.
# Parses progress from subprocess stderr (or a dedicated file) and forwards via mcp_progress.
#
# Usage:
#   mcp_run_with_progress --pattern 'REGEX' [OPTIONS] -- command args...
#
# See docs/internal/plan-progress-passthrough-2026-01-06.md for design rationale.

set -euo pipefail

# Main helper: run a command and forward progress from its stderr to MCP
mcp_run_with_progress() {
	local pattern="" extract="json" interval="0.2" stdout_file="" dry_run=false
	local progress_file="" total="" quiet=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pattern)
			pattern="$2"
			shift 2
			;;
		--extract)
			extract="$2"
			shift 2
			;;
		--interval)
			interval="$2"
			shift 2
			;;
		--stdout)
			stdout_file="$2"
			shift 2
			;;
		--progress-file)
			progress_file="$2"
			shift 2
			;;
		--total)
			total="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--quiet)
			quiet=true
			shift
			;;
		--)
			shift
			break
			;;
		*)
			break
			;;
		esac
	done

	# Input validation
	if [[ -z "$pattern" ]]; then
		echo "mcp_run_with_progress: --pattern is required" >&2
		return 1
	fi
	case "$extract" in
	json | match1 | ratio) ;;
	*)
		echo "mcp_run_with_progress: unknown extract mode '$extract'" >&2
		return 1
		;;
	esac
	if [[ -n "$total" ]]; then
		case "$total" in
		'' | *[!0-9]* | 0)
			echo "mcp_run_with_progress: --total must be positive integer" >&2
			return 1
			;;
		esac
	fi
	if [[ -n "$interval" ]]; then
		if ! [[ "$interval" =~ ^[0-9]*\.?[0-9]+$ ]] || [[ "$interval" == "0" ]] || [[ "$interval" == "0.0" ]]; then
			echo "mcp_run_with_progress: --interval must be a positive number" >&2
			return 1
		fi
	fi

	local tmpdir stderr_file stdout_tmp source_file pid=""
	tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/mcp-progress.XXXXXX")"
	stderr_file="${tmpdir}/stderr"
	stdout_tmp="${tmpdir}/stdout"

	# Cleanup trap: kill subprocess BEFORE removing tmpdir (avoid orphan processes)
	# Use ${var:-} to guard against unbound variable when trap fires after function returns
	# shellcheck disable=SC2329  # Function is invoked via trap
	__mcp_progress_cleanup() {
		if [[ -n "${pid:-}" ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
		fi
		if [[ -n "${tmpdir:-}" && -d "${tmpdir:-}" ]]; then
			rm -rf "${tmpdir}"
		fi
	}
	trap __mcp_progress_cleanup RETURN EXIT TERM INT

	# Helper to log stderr lines (extracted to avoid duplication)
	__mcp_progress_log_stderr() {
		local file="$1" start="$2"
		tail -c +$((start + 1)) "$file" 2>/dev/null \
			| while IFS= read -r -t 1 line || [[ -n "$line" ]]; do
				mcp_log_debug "mcp_run_with_progress" "subprocess stderr: $line"
			done
	}

	# Determine progress source
	if [[ -n "$progress_file" ]]; then
		source_file="$progress_file"
		# Truncate/create progress file (intentional - see Option Details in plan)
		# Note: If external process creates file between truncation and subprocess start,
		# this could affect unrelated data. Caller should use unique/temp paths.
		: >"$source_file"
	else
		source_file="$stderr_file"
	fi

	# Run command with stderr redirected to temp file (not FIFO for Windows compat)
	# Note: stderr_file always gets subprocess stderr (for logging even with --progress-file)
	"$@" >"${stdout_tmp}" 2>"${stderr_file}" &
	pid=$!

	local last_size=0 current_size last_stderr_size=0
	while kill -0 "$pid" 2>/dev/null; do
		# Check for cancellation
		if mcp_is_cancelled; then
			kill "$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			pid=""
			return 130
		fi

		# Robust whitespace stripping (wc output varies by platform)
		current_size=$(wc -c <"${source_file}" 2>/dev/null | tr -d '[:space:]')
		: "${current_size:=0}"

		if [[ "$current_size" -gt "$last_size" ]]; then
			__mcp_progress_process_lines "${source_file}" "$last_size" "$pattern" "$extract" "$dry_run" "$total" "$quiet"
			last_size=$current_size
		fi

		# When using --progress-file, also process stderr for logging
		if [[ -n "$progress_file" && "$quiet" != "true" ]]; then
			local current_stderr_size
			current_stderr_size=$(wc -c <"${stderr_file}" 2>/dev/null | tr -d '[:space:]')
			: "${current_stderr_size:=0}"
			if [[ "$current_stderr_size" -gt "$last_stderr_size" ]]; then
				__mcp_progress_log_stderr "${stderr_file}" "$last_stderr_size"
				last_stderr_size=$current_stderr_size
			fi
		fi

		sleep "$interval"
	done

	wait "$pid"
	local exit_code=$?
	pid="" # Clear pid so cleanup trap doesn't try to kill again

	# Process any final lines after process exit
	current_size=$(wc -c <"${source_file}" 2>/dev/null | tr -d '[:space:]')
	: "${current_size:=0}"
	if [[ "$current_size" -gt "$last_size" ]]; then
		__mcp_progress_process_lines "${source_file}" "$last_size" "$pattern" "$extract" "$dry_run" "$total" "$quiet"
	fi

	# Final stderr passthrough when using --progress-file
	if [[ -n "$progress_file" && "$quiet" != "true" ]]; then
		local final_stderr_size
		final_stderr_size=$(wc -c <"${stderr_file}" 2>/dev/null | tr -d '[:space:]')
		: "${final_stderr_size:=0}"
		if [[ "$final_stderr_size" -gt "$last_stderr_size" ]]; then
			__mcp_progress_log_stderr "${stderr_file}" "$last_stderr_size"
		fi
	fi

	# Output stdout
	if [[ -n "$stdout_file" ]]; then
		cp "${stdout_tmp}" "$stdout_file"
	else
		cat "${stdout_tmp}"
	fi

	return "$exit_code"
}

# Private helper: process new lines from progress source file
# Double underscore prefix per SDK conventions
__mcp_progress_process_lines() {
	local source_file="$1" start_byte="$2" pattern="$3" extract="$4" dry_run="$5" total="$6" quiet="$7"

	# Read new bytes with timeout to prevent blocking on incomplete lines
	tail -c +$((start_byte + 1)) "$source_file" 2>/dev/null \
		| while IFS= read -r -t 1 line || [[ -n "$line" ]]; do
			if [[ "$line" =~ $pattern ]]; then
				local pct msg
				case "$extract" in
				json)
					# Single jq call with @tsv per json-handling.mdc
					# Use select() to skip lines where .progress is null/missing
					local pct_msg jq_result jq_exit
					# Capture both stdout and stderr, then check exit code
					jq_result=$("${MCPBASH_JSON_TOOL_BIN}" -r \
						'select(.progress != null) | [(.progress | tostring), (.message // "Working...")] | @tsv' \
						<<<"$line" 2>&1)
					jq_exit=$?
					if [[ $jq_exit -ne 0 ]]; then
						# Log parse errors at debug level for troubleshooting
						mcp_log_debug "mcp_run_with_progress" "jq parse error on line: ${line:0:100}"
						continue
					fi
					pct_msg="$jq_result"
					[[ -n "$pct_msg" ]] || continue # select() may produce no output
					pct="${pct_msg%%$'\t'*}"
					msg="${pct_msg#*$'\t'}"
					# Validate pct is numeric
					[[ "$pct" =~ ^[0-9]+$ ]] || continue
					;;
				match1)
					# Guard BASH_REMATCH with :- per bash-conventions.mdc
					local raw_value="${BASH_REMATCH[1]:-}"
					[[ -n "$raw_value" ]] || continue
					if [[ -n "$total" ]]; then
						# Raw value divided by total
						pct=$((raw_value * 100 / total))
					else
						# Direct percentage (0-100)
						pct="$raw_value"
					fi
					msg="$line"
					;;
				ratio)
					# Guard BASH_REMATCH with :- per bash-conventions.mdc
					local current="${BASH_REMATCH[1]:-}" total_count="${BASH_REMATCH[2]:-}"
					[[ -n "$current" && -n "$total_count" && "$total_count" -gt 0 ]] || continue
					pct=$((current * 100 / total_count))
					msg="$line"
					;;
				esac

				if [[ -n "$pct" ]]; then
					if [[ "$dry_run" == "true" ]]; then
						# Output to stderr to avoid mixing with subprocess stdout
						local msg_json
						msg_json=$(__mcp_sdk_json_escape "$msg")
						printf '{"progress":%s,"message":%s}\n' "$pct" "$msg_json" >&2
					else
						mcp_progress "$pct" "$msg"
					fi
				fi
			elif [[ "$quiet" != "true" ]]; then
				mcp_log_debug "mcp_run_with_progress" "subprocess output: $line"
			fi
		done
}
