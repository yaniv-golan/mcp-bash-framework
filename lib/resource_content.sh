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

	local detected
	detected="$(mcp_resource_detect_mime_raw "${path}")"
	if [ -n "${detected}" ]; then
		printf '%s' "${detected}"
		return 0
	fi

	printf '%s' "${fallback}"
}

# Print what `file --mime` reports for PATH, lowercased and trimmed, with its
# parameters (e.g. "text/plain; charset=us-ascii"), or nothing when `file` is
# unavailable or reports nothing.
mcp_resource_detect_mime_full() {
	local path="$1"
	if ! command -v file >/dev/null 2>&1; then
		return 0
	fi
	local detected
	# --brief keeps output compact; --mime returns mime + charset where available.
	detected="$(file --mime --brief -- "${path}" 2>/dev/null || true)"
	printf '%s' "${detected}" | tr '[:upper:]' '[:lower:]' | awk '{$1=$1};1'
}

# Like mcp_resource_detect_mime_full, without the parameters.
mcp_resource_detect_mime_raw() {
	local detected
	detected="$(mcp_resource_detect_mime_full "$1")"
	detected="${detected%%;*}"
	printf '%s' "${detected}" | awk '{$1=$1};1'
}

# True when a DECLARED mime type names a known binary class. Unlike
# mcp_resource_is_binary_mime there is no "unknown means binary" default, so a
# declared text-ish type such as application/toml never forces base64.
mcp_resource_declared_mime_is_binary() {
	local lower
	lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
	lower="${lower%%;*}"
	lower="$(printf '%s' "${lower}" | awk '{$1=$1};1')"
	case "${lower}" in
	image/* | audio/* | video/*) return 0 ;;
	application/pdf | application/octet-stream) return 0 ;;
	application/zip | application/gzip | application/x-gzip) return 0 ;;
	application/x-bzip2 | application/x-xz) return 0 ;;
	esac
	return 1
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

# mcp_resource_content_object_from_file PATH HINT URI [DECLARED]
#   DECLARED=true: HINT is the reported mimeType exactly as given (the label).
#   DECLARED absent/false: `file --mime` overrides HINT (except `;profile=` hints).
# Either way detection decides text vs base64: base64 when the detected type is
# binary, when the first 1 KB holds a NUL byte, or when a declared HINT names a
# known binary class.
mcp_resource_content_object_from_file() {
	local path="$1"
	local mime_hint="${2:-text/plain}"
	local uri="${3:-}"
	local declared="${4:-false}"

	if [ ! -r "${path}" ]; then
		return 1
	fi

	local mime detected
	if [ "${declared}" = "true" ]; then
		mime="${mime_hint}"
		detected="$(mcp_resource_detect_mime_full "${path}")"
		case "${detected}" in
		# Bytes `file` cannot read as text in any charset: keep them intact.
		*charset=binary* | *charset=unknown-8bit*) detected="application/octet-stream" ;;
		*) detected="$(printf '%s' "${detected%%;*}" | awk '{$1=$1};1')" ;;
		esac
		# Without `file`, use text/plain so only the NUL sniff and the
		# declared binary class decide (no "unknown means binary" default).
		[ -n "${detected}" ] || detected="text/plain"
	else
		mime="$(mcp_resource_detect_mime "${path}" "${mime_hint}")"
		# Undeclared: encoding follows the reported type, as before.
		detected="${mime}"
	fi

	local base64_mode=1
	if mcp_resource_should_base64 "${path}" "${detected}"; then
		base64_mode=0
	elif [ "${declared}" = "true" ] && mcp_resource_declared_mime_is_binary "${mime}"; then
		base64_mode=0
	fi

	local payload
	if [ "${base64_mode}" -eq 0 ]; then
		if ! command -v base64 >/dev/null 2>&1; then
			return 1
		fi
		# The content goes to jq on stdin, never as an argument: Linux caps one
		# argument at 128 KiB (MAX_ARG_STRLEN) and macOS caps all of them at 1 MiB.
		if ! payload="$(LC_ALL=C base64 <"${path}" | tr -d '\r\n' | "${MCPBASH_JSON_TOOL_BIN}" -c -R -s \
			--arg uri "${uri}" \
			--arg mime "${mime}" \
			'{
				uri: $uri,
				mimeType: $mime,
				blob: .
			} | del(.uri | select(.==""))')"; then
			return 1
		fi
	else
		local text_content
		text_content="$(cat -- "${path}")"
		if ! payload="$(printf '%s' "${text_content}" | "${MCPBASH_JSON_TOOL_BIN}" -c -R -s \
			--arg uri "${uri}" \
			--arg mime "${mime}" \
			'{
				uri: $uri,
				mimeType: $mime,
				text: .
			} | del(.uri | select(.==""))')"; then
			return 1
		fi
	fi

	if [ -z "${payload}" ]; then
		return 1
	fi

	printf '%s' "${payload}"
}
