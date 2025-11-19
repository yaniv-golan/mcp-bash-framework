#!/usr/bin/env bash
set -euo pipefail

# Handle SDK path if not set
if [ -z "${MCPBASH_SDK:-}" ]; then
	MCPBASH_SDK="$(cd "$(dirname "$0")/../../../sdk" && pwd)"
fi

# shellcheck source=../../../sdk/tool-sdk.sh disable=SC1091
source "${MCPBASH_SDK}/tool-sdk.sh"

# Validation: Check args
if [ $# -lt 3 ]; then
	mcp_tool_error -32602 "Missing required arguments: input, output, preset"
	exit 1
fi

# Cross-platform realpath shim
realpath_m() {
	if command -v realpath >/dev/null 2>&1; then
		realpath -m "$1"
	else
		local dir base
		dir="$(dirname "$1")"
		base="$(basename "$1")"
		(cd "$dir" 2>/dev/null && pwd -P | sed "s|$|/$base|") || echo "$1"
	fi
}

input_path="$1"
output_path="$2"
preset="$3"
start_time="${4:-}"
duration="${5:-}"

media_dir="$(cd "$(dirname "$0")/../media" && pwd)"
full_input="$(realpath_m "$(cd "$(dirname "$0")/../media" && pwd)/${input_path}")"
full_output="$(realpath_m "$(cd "$(dirname "$0")/../media" && pwd)/${output_path}")"

# Validation: Sandbox check
if [[ "${full_input}" != "${media_dir}"* ]] || [[ "${full_output}" != "${media_dir}"* ]]; then
	mcp_tool_error -32602 "Access denied: Paths must be within media directory"
	exit 1
fi

# Validation: Input exists
if [ ! -f "${full_input}" ]; then
	mcp_tool_error -32602 "Input file not found: ${input_path}"
	exit 1
fi

# Validation: Output collision
if [ -f "${full_output}" ]; then
	mcp_tool_error -32602 "Output file already exists: ${output_path}"
	exit 1
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
	mcp_tool_error -32602 "Invalid preset: ${preset}"
	exit 1
	;;
esac

# Get total duration in microseconds for progress calculation
total_duration_us=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${full_input}" | awk '{print int($1 * 1000000)}')

if [ -z "${total_duration_us}" ] || [ "${total_duration_us}" -eq 0 ]; then
	# Fallback if duration unknown
	total_duration_us=1
fi

# Run ffmpeg with progress pipe
# We use a temp file for the pipe since bash pipes can be tricky with exit codes
mcp_progress 0 "Starting transcoding..."

ffmpeg "${ffmpeg_args[@]}" -i "${full_input}" -progress pipe:1 "${full_output}" | while read -r line; do
	key=${line%%=*}
	value=${line#*=}

	if [[ "$key" == "out_time_us" ]]; then
		current_us=$value
		# Avoid division by zero
		if [ "${total_duration_us}" -gt 0 ]; then
			pct=$((current_us * 100 / total_duration_us))
			# Clamp to 100
			if [ $pct -gt 100 ]; then pct=100; fi
			mcp_progress "${pct}" "Transcoding... ${pct}%"
		fi
	fi

	# Check cancellation
	if mcp_is_cancelled; then
		rm -f "${full_output}"
		exit 1
	fi
done

mcp_emit_text "Transcoding complete: ${output_path}"
