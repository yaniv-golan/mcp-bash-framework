#!/usr/bin/env bash
# Shared helpers for building MCP resource content payloads.

set -euo pipefail

mcp_resource_detect_mime() {
	local path="$1"
	local fallback="${2:-text/plain}"

	# If fallback contains a profile suffix (e.g., text/html;profile=mcp-app),
	# trust it directly since `file` command won't preserve profile info
	case "${fallback}" in
	*";profile="*)
		printf '%s' "${fallback}"
		return 0
		;;
	esac

	if command -v file >/dev/null 2>&1; then
		local detected
		# --brief keeps output compact; --mime returns mime + charset where available.
		if detected="$(file --mime --brief -- "${path}" 2>/dev/null || true)"; then
			detected="${detected%%;*}"
			detected="$(printf '%s' "${detected}" | tr '[:upper:]' '[:lower:]' | awk '{$1=$1};1')"
			if [ -n "${detected}" ]; then
				printf '%s' "${detected}"
				return 0
			fi
		fi
	fi

	printf '%s' "${fallback}"
}

mcp_resource_is_binary_mime() {
	local mime="$1"
	local lower
	lower="$(printf '%s' "${mime}" | tr '[:upper:]' '[:lower:]')"

	case "${lower}" in
	*charset=binary*) return 0 ;;
	application/octet-stream | application/x-executable | application/pdf) return 0 ;;
	application/zip | application/x-gzip | application/x-bzip2 | application/x-xz) return 0 ;;
	image/* | audio/* | video/*) return 0 ;;
	esac

	# Treat common textual mime types as non-binary.
	case "${lower}" in
	text/*) return 1 ;;
	*json* | *xml* | *yaml* | *csv* | *javascript* | *x-shellscript* | *x-sh*) return 1 ;;
	*markdown* | *html* | *css*) return 1 ;;
	esac

	# Default: consider mime binary-safe to avoid emitting raw bytes into JSON.
	return 0
}

mcp_resource_should_base64() {
	local path="$1"
	local mime="$2"

	if mcp_resource_is_binary_mime "${mime}"; then
		return 0
	fi

	if command -v od >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then
		if LC_ALL=C od -An -t x1 -N 1024 -- "${path}" 2>/dev/null | LC_ALL=C grep -Eq '(^|[[:space:]])00([[:space:]]|$)'; then
			return 0
		fi
	fi

	return 1
}

mcp_resource_content_object_from_file() {
	local path="$1"
	local mime_hint="${2:-text/plain}"
	local uri="${3:-}"

	if [ ! -r "${path}" ]; then
		return 1
	fi

	local mime
	mime="$(mcp_resource_detect_mime "${path}" "${mime_hint}")"

	local base64_mode=1
	if mcp_resource_should_base64 "${path}" "${mime}"; then
		base64_mode=0
	fi

	local payload
	if [ "${base64_mode}" -eq 0 ]; then
		if ! command -v base64 >/dev/null 2>&1; then
			return 1
		fi
		local blob
		blob="$(LC_ALL=C base64 <"${path}" | tr -d '\r\n')"
		payload="$("${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--arg uri "${uri}" \
			--arg mime "${mime}" \
			--arg blob "${blob}" \
			'{
				uri: $uri,
				mimeType: $mime,
				blob: $blob
			} | del(.uri | select(.==""))' 2>/dev/null || true)"
	else
		local text_content
		text_content="$(cat -- "${path}")"
		payload="$("${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--arg uri "${uri}" \
			--arg mime "${mime}" \
			--arg text "${text_content}" \
			'{
				uri: $uri,
				mimeType: $mime,
				text: $text
			} | del(.uri | select(.==""))' 2>/dev/null || true)"
	fi

	if [ -z "${payload}" ]; then
		return 1
	fi

	printf '%s' "${payload}"
}
