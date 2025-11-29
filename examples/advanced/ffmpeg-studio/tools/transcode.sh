#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	if fallback_sdk="$(cd "${script_dir}/../../../sdk" 2>/dev/null && pwd)"; then
		if [ -f "${fallback_sdk}/tool-sdk.sh" ]; then
			MCP_SDK="${fallback_sdk}"
		fi
	fi
fi

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	printf 'mcp: SDK helpers not found (set MCP_SDK to your framework sdk/ path or keep this example inside the framework repo; expected %s/tool-sdk.sh)\n' "${MCP_SDK:-<unset>}" >&2
	exit 1
fi

# shellcheck source=../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK}/tool-sdk.sh"
# shellcheck source=../lib/roots.sh disable=SC1091
source "${script_dir}/../lib/roots.sh"

input_path="$(mcp_args_get '.input // empty' 2>/dev/null || true)"
output_path="$(mcp_args_get '.output // empty' 2>/dev/null || true)"
preset="$(mcp_args_get '.preset // empty' 2>/dev/null || true)"
start_time="$(mcp_args_get '.start_time // empty' 2>/dev/null || true)"
duration="$(mcp_args_get '.duration // empty' 2>/dev/null || true)"

if [ -z "${input_path}" ] && [ $# -ge 1 ]; then
	input_path="$1"
fi
if [ -z "${output_path}" ] && [ $# -ge 2 ]; then
	output_path="$2"
fi
if [ -z "${preset}" ] && [ $# -ge 3 ]; then
	preset="$3"
fi
if [ -z "${start_time}" ] && [ $# -ge 4 ]; then
	start_time="$4"
fi
if [ -z "${duration}" ] && [ $# -ge 5 ]; then
	duration="$5"
fi

if [ -z "${input_path}" ] || [ -z "${output_path}" ] || [ -z "${preset}" ]; then
	mcp_fail_invalid_args "Missing required arguments: input, output, preset"
fi

full_input="$(ffmpeg_resolve_path "${input_path}" "read")"
full_output="$(ffmpeg_resolve_path "${output_path}" "write")"

# Validation: Input exists
if [ ! -f "${full_input}" ]; then
	mcp_fail -32602 "Input file not found: ${input_path}"
fi

# Validation: Output collision with elicitation-based confirmation
if [ -f "${full_output}" ]; then
	if [ "${MCP_ELICIT_SUPPORTED:-0}" != "1" ]; then
		mcp_fail -32602 "Output file exists and elicitation is not supported; refusing to overwrite ${output_path}"
	fi
	overwrite_resp="$(mcp_elicit_confirm "Output ${output_path} exists. Overwrite?")"
	overwrite_action="$(printf '%s' "${overwrite_resp}" | jq -r '.action')"
	if [ "${overwrite_action}" != "accept" ]; then
		mcp_fail -32602 "Overwrite declined for ${output_path}"
	fi
	confirmed="$(printf '%s' "${overwrite_resp}" | jq -r '.content.confirmed // false')"
	if [ "${confirmed}" != "true" ]; then
		mcp_fail -32602 "Overwrite not confirmed for ${output_path}"
	fi
fi

# Determine ffmpeg args based on preset
ffmpeg_args=("-hide_banner" "-y")

if [ -n "${start_time}" ]; then
	ffmpeg_args+=("-ss" "${start_time}")
fi
if [ -n "${duration}" ]; then
	ffmpeg_args+=("-t" "${duration}")
fi

case "${preset}" in
"1080p")
	ffmpeg_args+=("-c:v" "libx264" "-preset" "fast" "-crf" "23" "-vf" "scale=-2:1080" "-c:a" "aac" "-b:a" "128k")
	;;
"720p")
	ffmpeg_args+=("-c:v" "libx264" "-preset" "fast" "-crf" "23" "-vf" "scale=-2:720" "-c:a" "aac" "-b:a" "128k")
	;;
"audio-only")
	ffmpeg_args+=("-vn" "-c:a" "libmp3lame" "-b:a" "192k")
	;;
"gif")
	# Complex filter for high quality GIF
	ffmpeg_args+=("-vf" "fps=10,scale=320:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse")
	;;
*)
	mcp_fail -32602 "Invalid preset: ${preset}"
	;;
esac

# Get total duration in microseconds for progress calculation
total_duration_us=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${full_input}" | awk '{print int($1 * 1000000)}')

if [ -z "${total_duration_us}" ] || [ "${total_duration_us}" -eq 0 ]; then
	# Fallback if duration unknown
	total_duration_us=1
fi

# Run ffmpeg with a dedicated progress pipe so we can track cancellation and exit codes accurately.
mcp_progress 0 "Starting transcoding..."
progress_fifo="$(mktemp -u "${TMPDIR:-/tmp}/mcp-ffmpeg-progress.XXXXXX")"
mkfifo "${progress_fifo}"
cleanup_fifo() {
	rm -f "${progress_fifo}"
}
trap cleanup_fifo EXIT INT TERM

ffmpeg "${ffmpeg_args[@]}" -i "${full_input}" -progress "${progress_fifo}" "${full_output}" &
ffmpeg_pid=$!

while IFS= read -r line; do
	key=${line%%=*}
	value=${line#*=}

	if [[ "$key" == "out_time_us" ]]; then
		current_us=$value
		if [ "${total_duration_us}" -gt 0 ]; then
			pct=$((current_us * 100 / total_duration_us))
			[ $pct -gt 100 ] && pct=100
			mcp_progress "${pct}" "Transcoding... ${pct}%"
		fi
	fi

	if mcp_is_cancelled; then
		kill "${ffmpeg_pid}" 2>/dev/null || true
		wait "${ffmpeg_pid}" 2>/dev/null || true
		rm -f "${full_output}"
		mcp_fail -32001 "Cancelled"
	fi
done <"${progress_fifo}"

wait_status=0
if ! wait "${ffmpeg_pid}"; then
	wait_status=$?
fi
rm -f "${progress_fifo}"
trap - EXIT INT TERM

if [ "${wait_status}" -ne 0 ]; then
	rm -f "${full_output}"
	mcp_fail -32603 "Transcode failed (ffmpeg exit ${wait_status})"
fi

json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
if [ -z "${json_tool}" ] || ! command -v "${json_tool}" >/dev/null 2>&1; then
	json_tool=""
fi

emit_message_json() {
	local message="$1"
	if [ -n "${json_tool}" ]; then
		mcp_emit_json "$("${json_tool}" -n --arg message "${message}" '{message:$message}')" || mcp_emit_text "${message}"
	else
		mcp_emit_text "${message}"
	fi
}

emit_message_json "Transcoding complete: ${output_path}"
