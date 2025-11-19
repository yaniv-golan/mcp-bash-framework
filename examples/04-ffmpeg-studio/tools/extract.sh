#!/usr/bin/env bash
set -euo pipefail

# Handle SDK path if not set
if [ -z "${MCPBASH_SDK:-}" ]; then
    MCPBASH_SDK="$(cd "$(dirname "$0")/../../../sdk" && pwd)"
fi

source "${MCPBASH_SDK}/tool-sdk.sh"

if [ $# -ne 3 ]; then
  mcp_tool_error -32602 "Missing required arguments: input, time, output"
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
timestamp="$2"
output_path="$3"

media_dir="$(cd "$(dirname "$0")/../media" && pwd)"
full_input="$(realpath_m "$(cd "$(dirname "$0")/../media" && pwd)/${input_path}")"
full_output="$(realpath_m "$(cd "$(dirname "$0")/../media" && pwd)/${output_path}")"


# Validation
if [[ "${full_input}" != "${media_dir}"* ]] || [[ "${full_output}" != "${media_dir}"* ]]; then
  mcp_tool_error -32602 "Access denied: Paths must be within media directory"
  exit 1
fi

if [ ! -f "${full_input}" ]; then
  mcp_tool_error -32602 "Input file not found"
  exit 1
fi

# Run ffmpeg to extract single frame
ffmpeg -ss "${timestamp}" -i "${full_input}" -frames:v 1 -y "${full_output}" >/dev/null 2>&1

if [ $? -eq 0 ]; then
  mcp_emit_text "Frame extracted to ${output_path}"
else
  mcp_tool_error -32603 "Failed to extract frame"
  exit 1
fi

