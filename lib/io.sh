#!/usr/bin/env bash
# Spec §5: stdout serialization, UTF-8 validation, and cancellation-aware emission.

set -euo pipefail

MCPBASH_STDOUT_LOCK_NAME="stdout"
MCPBASH_ICONV_AVAILABLE=""
MCPBASH_ALLOW_CORRUPT_STDOUT="${MCPBASH_ALLOW_CORRUPT_STDOUT:-false}"

mcp_io_corruption_file() {
  if [ -z "${MCPBASH_STATE_DIR:-}" ]; then
    printf ''
    return 1
  fi
  printf '%s/corruption.log' "${MCPBASH_STATE_DIR}"
}

mcp_io_corruption_count() {
  local file
  file="$(mcp_io_corruption_file || true)"
  if [ -z "${file}" ] || [ ! -f "${file}" ]; then
    printf '0'
    return 0
  fi
  awk 'NF {count++} END {print count+0}' "${file}"
}

mcp_io_log_corruption_summary() {
  local file count window threshold
  file="$(mcp_io_corruption_file || true)"
  if [ -z "${file}" ] || [ ! -f "${file}" ]; then
    return 0
  fi
  count="$(mcp_io_corruption_count)"
  if [ "${count}" -eq 0 ]; then
    return 0
  fi
  window="${MCPBASH_CORRUPTION_WINDOW:-60}"
  threshold="${MCPBASH_CORRUPTION_THRESHOLD:-3}"
  printf '%s\n' "mcp-bash corruption summary: ${count} event(s) recorded within the last ${window}s (threshold ${threshold}, allow override ${MCPBASH_ALLOW_CORRUPT_STDOUT})." >&2
  return 0
}

mcp_io_handle_corruption() {
  local reason="$1"
  local allow="${MCPBASH_ALLOW_CORRUPT_STDOUT:-false}"
  local threshold="${MCPBASH_CORRUPTION_THRESHOLD:-3}"
  local window="${MCPBASH_CORRUPTION_WINDOW:-60}"
  local file
  local preserved=""
  local count=0
  local now line

  file="$(mcp_io_corruption_file || true)"
  if [ -z "${file}" ]; then
    return 0
  fi

  case "${threshold}" in
    ''|*[!0-9]*) threshold=3 ;;
    0) threshold=3 ;;
  esac
  case "${window}" in
    ''|*[!0-9]*) window=60 ;;
  esac

  now="$(date +%s)"
  if [ -f "${file}" ]; then
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      if [ $((now - line)) -lt "${window}" ]; then
        preserved="${preserved}${line}\n"
        count=$((count + 1))
      fi
    done <"${file}"
  fi

  printf '%s\n' "mcp-bash: stdout corruption detected (${reason}); ${count} prior event(s) in the last ${window}s" >&2

  printf '%s%s\n' "${preserved}" "${now}" >"${file}"

  if [ "${allow}" = "true" ]; then
    return 0
  fi

  if [ $((count + 1)) -ge "${threshold}" ]; then
    printf '%s\n' 'mcp-bash: exiting due to repeated stdout corruption (Spec §16).' >&2
    exit 2
  fi

  return 0
}

mcp_io_init() {
  mcp_lock_init
}

mcp_io_stdout_lock_acquire() {
  mcp_lock_acquire "${MCPBASH_STDOUT_LOCK_NAME}"
}

mcp_io_stdout_lock_release() {
  mcp_lock_release "${MCPBASH_STDOUT_LOCK_NAME}"
}

mcp_io_send_line() {
  local payload="$1"
  if [ -z "${payload}" ]; then
    return 0
  fi
  mcp_io_stdout_lock_acquire
  mcp_io_write_payload "${payload}"
  mcp_io_stdout_lock_release
}

mcp_io_send_response() {
  local key="$1"
  local payload="$2"

  if [ -z "${payload}" ]; then
    return 0
  fi

  mcp_io_stdout_lock_acquire
  if [ -n "${key}" ] && mcp_ids_is_cancelled_key "${key}"; then
    mcp_io_stdout_lock_release
    return 0
  fi

  if ! mcp_io_write_payload "${payload}"; then
    mcp_io_stdout_lock_release
    return 1
  fi

  mcp_io_stdout_lock_release
  return 0
}

mcp_io_write_payload() {
  local payload="$1"
  local normalized

  normalized="$(printf '%s' "${payload}" | tr -d '\r')"

  case "${normalized}" in
    *$'\n'*)
      mcp_io_handle_corruption "multi-line payload"
      return 1
      ;;
  esac

  if ! mcp_io_validate_utf8 "${normalized}"; then
    printf '%s\n' 'mcp-bash: dropping non-UTF8 payload to preserve stdout contract (Spec §5).' >&2
    mcp_io_handle_corruption "invalid UTF-8"
    return 1
  fi

  if ! printf '%s\n' "${normalized}"; then
    mcp_io_handle_corruption "stdout write failure"
    return 1
  fi
  return 0
}

mcp_io_validate_utf8() {
  local data="$1"

  if [ -z "${data}" ]; then
    return 0
  fi

  if [ -z "${MCPBASH_ICONV_AVAILABLE}" ]; then
    if command -v iconv >/dev/null 2>&1; then
      MCPBASH_ICONV_AVAILABLE="true"
    else
      MCPBASH_ICONV_AVAILABLE="false"
    fi
  fi

  if [ "${MCPBASH_ICONV_AVAILABLE}" = "false" ]; then
    return 0
  fi

  printf '%s' "${data}" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}
