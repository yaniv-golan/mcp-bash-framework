#!/usr/bin/env bash
set -euo pipefail

# Handle SDK path if not set
if [ -z "${MCPBASH_SDK:-}" ]; then
	MCPBASH_SDK="$(cd "$(dirname "$0")/../../../sdk" && pwd)"
fi

# shellcheck source=../../../sdk/tool-sdk.sh disable=SC1091
source "${MCPBASH_SDK}/tool-sdk.sh"

# Validation: Check args
if [ $# -ne 1 ]; then
	mcp_tool_error -32602 "Missing required argument: path"
	exit 1
fi

# Cross-platform realpath shim
realpath_m() {
	if command -v realpath >/dev/null 2>&1; then
		realpath -m "$1"
	else
		# Fallback for macOS/BSD without coreutils
		local dir base
		dir="$(dirname "$1")"
		base="$(basename "$1")"
		# Best effort normalization
		(cd "$dir" 2>/dev/null && pwd -P | sed "s|$|/$base|") || echo "$1"
	fi
}

path="$1"
media_dir="$(cd "$(dirname "$0")/../media" && pwd)"
full_path="$(realpath_m "$(cd "$(dirname "$0")/../media" && pwd)/${path}")"

# Validation: Sandbox check
if [[ "${full_path}" != "${media_dir}"* ]]; then
	mcp_tool_error -32602 "Access denied: Path must be within media directory"
	exit 1
fi

# Validation: File exists
if [ ! -f "${full_path}" ]; then
	mcp_tool_error -32602 "File not found: ${path}"
	exit 1
fi

# Run ffprobe
if ! output=$(ffprobe -v quiet -print_format json -show_format -show_streams "${full_path}" 2>/dev/null); then
	mcp_tool_error -32603 "Failed to inspect media file"
	exit 1
fi

mcp_emit_text "${output}"
