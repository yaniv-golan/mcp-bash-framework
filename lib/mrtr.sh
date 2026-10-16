#!/usr/bin/env bash
# Multi round-trip requests (MCP 2026-07-28) for tools/call.
#
# On the modern path a server can't send the client a request mid-call. A
# question ends the call with resultType "input_required", the questions in
# inputRequests and a requestState; the client calls again with the answers
# in inputResponses and the same requestState. The tool then runs again from
# the start.
#
# Each modern call gets a journal, $MCPBASH_STATE_DIR/journal/<ticket>, where
# the SDK records step outputs (mcp_once) and questions, and the server
# records the answers (sdk/tool-sdk.sh describes the files). The ticket is the
# requestState: 128 random bits, so it can't be guessed, and nothing from the
# journal is sent to the client. The journal belongs to this server process
# (its state dir is removed when it exits), so a retry that reaches another
# process, or comes after the TTL, is told to run the tool again; it is never
# re-run silently, which could repeat a side effect.
#
# One run at a time: a run claims the journal (mkdir run, which is atomic) and
# the server releases it when the run ends. A retry that can't claim it (a
# duplicate of a retry already running) never runs the tool.
#
# Server files besides the SDK's: name, digest (sha256 of the canonical
# arguments), created (epoch of the last round: the TTL counts from it),
# attempt, modes ("F U"), and the claim run/ with run/pid (the process that
# holds it). Files are 0600 in a 0700 directory.

set -euo pipefail

# A new ticket, or failure when no random source is available: then the call
# runs without a journal rather than with a guessable ticket.
mcp_mrtr_new_ticket() {
	local t
	t="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')" || t=""
	mcp_mrtr_valid_ticket "${t}" || return 1
	printf '%s' "${t}"
}

# The client sends requestState, and it names a directory: only this exact
# shape is ever used as a path.
mcp_mrtr_valid_ticket() {
	[[ "${1:-}" =~ ^[0-9a-f]{32}$ ]]
}

mcp_mrtr_journal_root() {
	printf '%s/journal' "${MCPBASH_STATE_DIR}"
}

mcp_mrtr_ttl_secs() {
	local ttl="${MCPBASH_MRTR_TICKET_TTL_SECS:-900}"
	case "${ttl}" in '' | *[!0-9]*) ttl=900 ;; esac
	printf '%s' "${ttl}"
}

# sha256 of the arguments with object keys sorted and numbers in one form
# (jq 1.7+ keeps a number as written, so 1.0 and 1 would differ). jq 1.6
# reads numbers as doubles: integers past 2^53 that differ only in their last
# digits get one digest there.
mcp_mrtr_args_digest() {
	local args="${1:-}"
	[ -n "${args}" ] || args='{}'
	local canonical
	canonical="$(printf '%s' "${args}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'def canon: if type == "object" then to_entries | sort_by(.key) | map(.value |= canon) | from_entries elif type == "array" then map(canon) elif type == "number" then . + 0 else . end; canon' 2>/dev/null)" || return 1
	mcp_ids_sha256 "${canonical}"
}

# Claim DIR for a run: fails when another run holds it. The pid is that of the
# calling process (the worker), not $$, which is the server in every subshell
# on bash 3.2.
mcp_mrtr_claim() {
	local dir="$1"
	mkdir "${dir}/run" 2>/dev/null || return 1
	mcp_lock_self_pid
	printf '%s' "${_MCP_LOCK_SELF_PID}" >"${dir}/run/pid" 2>/dev/null || true
	return 0
}

# Is DIR held by a run that is still alive? A claim without its pid yet is
# being taken, so it counts as held.
mcp_mrtr_claim_live() {
	local dir="$1" pid
	[ -d "${dir}/run" ] || return 1
	pid="$(cat "${dir}/run/pid" 2>/dev/null || true)"
	[ -n "${pid}" ] || return 0
	kill -0 "${pid}" 2>/dev/null
}

# The run on DIR stopped at a question: free the journal for the retry, and
# start the TTL of this round now.
mcp_mrtr_release() {
	local dir="$1"
	[ -d "${dir}" ] || return 0
	(umask 077 && date +%s >"${dir}/created.tmp" && mv -f "${dir}/created.tmp" "${dir}/created") 2>/dev/null || true
	rm -f "${dir}/run/pid"
	rmdir "${dir}/run" 2>/dev/null || true
}

# Questions in DIR that have no answer yet?
mcp_mrtr_has_pending() {
	local req
	for req in "$1"/q.*.req; do
		[ -f "${req}" ] || continue
		[ -f "${req%.req}.ans" ] || return 0
	done
	return 1
}

# Remove journals past the TTL, except one a live run holds. Cheap: one
# directory listing per call.
mcp_mrtr_sweep() {
	local root now ttl dir created
	root="$(mcp_mrtr_journal_root)"
	[ -d "${root}" ] || return 0
	now="$(date +%s)"
	ttl="$(mcp_mrtr_ttl_secs)"
	for dir in "${root}"/*; do
		[ -d "${dir}" ] || continue
		if mcp_mrtr_claim_live "${dir}"; then
			continue
		fi
		created="$(cat "${dir}/created" 2>/dev/null || printf 0)"
		case "${created}" in '' | *[!0-9]*) created=0 ;; esac
		if [ $((now - created)) -gt "${ttl}" ]; then
			rm -rf "${dir:?}" 2>/dev/null || true
		fi
	done
}

mcp_mrtr_close() {
	local dir="${1:-}"
	[ -n "${dir}" ] || return 0
	case "${dir}" in "$(mcp_mrtr_journal_root)"/*) ;; *) return 0 ;; esac
	rm -rf "${dir:?}" 2>/dev/null || true
}

# An answer as the tool sees it: the legacy rule (lib/rpc.sh), so a tool
# behaves the same in both eras. Reads the client's result on stdin.
mcp_mrtr_normalize_answer() {
	"${MCPBASH_JSON_TOOL_BIN}" -c '
		(if type == "object" then . else {} end) as $r
		| ($r.action // "unavailable") as $a
		| if ($a | IN("accept", "decline", "cancel")) then
			{action: $a, content: (if ($r.content | type) == "object" then $r.content else null end)}
		else {action: "unavailable", content: null} end
	' 2>/dev/null || printf '{"action":"unavailable","content":null}'
}

# Open the journal for one tools/call.
# Usage: mcp_mrtr_open NAME ARGS_JSON REQUEST_STATE INPUT_RESPONSES_JSON FORM URL
# FORM/URL: 1 when the client can answer form / URL questions.
# Sets MCP_MRTR_OUTCOME:
#   run            run the tool with MCP_MRTR_DIR (MCP_MRTR_TICKET, MCP_MRTR_ATTEMPT)
#   input_required answer with mcp_mrtr_pending_result, without running it
#   error          an error result: MCP_MRTR_ERROR_TYPE, MCP_MRTR_ERROR_MESSAGE
#   invalid        invalid params (-32602): MCP_MRTR_ERROR_MESSAGE
#   none           no journal (no random source): run the tool without one
# The MCP_MRTR_* results are read by the caller (mcp_tools_call).
# shellcheck disable=SC2034
mcp_mrtr_open() {
	# Journal files are 0600 whatever the server's umask.
	local saved_umask
	saved_umask="$(umask)"
	umask 077
	local status=0
	mcp_mrtr_open_journal "$@" || status=$?
	umask "${saved_umask}"
	return "${status}"
}

# shellcheck disable=SC2034
mcp_mrtr_open_journal() {
	local name="$1" args="$2" state="$3" responses="$4" form="${5:-0}" url="${6:-0}"
	MCP_MRTR_OUTCOME="" MCP_MRTR_DIR="" MCP_MRTR_TICKET="" MCP_MRTR_ATTEMPT=""
	MCP_MRTR_ERROR_TYPE="" MCP_MRTR_ERROR_MESSAGE=""
	local root digest dir
	root="$(mcp_mrtr_journal_root)"
	mcp_mrtr_sweep
	if ! digest="$(mcp_mrtr_args_digest "${args}")" || [ -z "${digest}" ]; then
		MCP_MRTR_OUTCOME="invalid"
		MCP_MRTR_ERROR_MESSAGE="Invalid arguments JSON"
		return 0
	fi

	if [ -z "${state}" ]; then
		if [ -n "${responses}" ] && [ "${responses}" != "null" ]; then
			MCP_MRTR_OUTCOME="invalid"
			MCP_MRTR_ERROR_MESSAGE="inputResponses needs the requestState of the call that asked"
			return 0
		fi
		local ticket
		if ! ticket="$(mcp_mrtr_new_ticket)"; then
			MCP_MRTR_OUTCOME="none"
			return 0
		fi
		dir="${root}/${ticket}"
		if ! mkdir -p "${root}" 2>/dev/null || ! mkdir "${dir}" 2>/dev/null || ! mcp_mrtr_claim "${dir}"; then
			MCP_MRTR_OUTCOME="none"
			return 0
		fi
		printf '%s' "${name}" >"${dir}/name"
		printf '%s' "${digest}" >"${dir}/digest"
		date +%s >"${dir}/created"
		printf '%s %s' "${form}" "${url}" >"${dir}/modes"
		printf '1' >"${dir}/attempt"
		MCP_MRTR_OUTCOME="run" MCP_MRTR_DIR="${dir}" MCP_MRTR_TICKET="${ticket}" MCP_MRTR_ATTEMPT=1
		return 0
	fi

	dir="${root}/${state}"
	if ! mcp_mrtr_valid_ticket "${state}" || [ ! -d "${dir}" ] || [ ! -f "${dir}/created" ]; then
		mcp_mrtr_open_expired
		return 0
	fi
	if [ "$(cat "${dir}/name" 2>/dev/null || true)" != "${name}" ] || [ "$(cat "${dir}/digest" 2>/dev/null || true)" != "${digest}" ]; then
		MCP_MRTR_OUTCOME="error"
		MCP_MRTR_ERROR_TYPE="request_mismatch"
		MCP_MRTR_ERROR_MESSAGE="requestState belongs to a call with another tool or other arguments: retry with the same name and arguments, or run the tool again"
		return 0
	fi
	MCP_MRTR_TICKET="${state}" MCP_MRTR_DIR="${dir}"

	# Claim the journal. Another run holds it when a retry with this ticket
	# is already running (a client's duplicate): wait a little, then ask the
	# open questions again, or say it is in progress. Never two runs.
	local waited=0 wait_secs="${MCPBASH_MRTR_INFLIGHT_WAIT_SECS:-2}"
	case "${wait_secs}" in '' | *[!0-9]*) wait_secs=2 ;; esac
	until mcp_mrtr_claim "${dir}"; do
		if [ ! -d "${dir}" ]; then
			mcp_mrtr_open_expired
			return 0
		fi
		if [ "${waited}" -ge $((wait_secs * 10)) ]; then
			if mcp_mrtr_has_pending "${dir}"; then
				MCP_MRTR_OUTCOME="input_required"
			else
				MCP_MRTR_OUTCOME="error"
				MCP_MRTR_ERROR_TYPE="request_in_progress"
				MCP_MRTR_ERROR_MESSAGE="Another call with this requestState is running: wait for its result"
			fi
			return 0
		fi
		sleep 0.1
		waited=$((waited + 1))
	done
	# The journal may have been removed (the run before finished) while the
	# claim was taken: then the claim is all that is left of it.
	if [ ! -f "${dir}/created" ] || [ ! -f "${dir}/name" ]; then
		rm -rf "${dir:?}" 2>/dev/null || true
		mcp_mrtr_open_expired
		return 0
	fi

	# Record the answers to the questions still open.
	local req key answer missing=""
	for req in "${dir}"/q.*.req; do
		[ -f "${req}" ] || continue
		[ -f "${req%.req}.ans" ] && continue
		key="${req##*/q.}"
		key="q${key%.req}"
		answer="$(printf '%s' "${responses:-null}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg k "${key}" 'if type == "object" and has($k) then .[$k] else empty end' 2>/dev/null || true)"
		if [ -z "${answer}" ]; then
			missing=1
			continue
		fi
		printf '%s' "${answer}" | mcp_mrtr_normalize_answer >"${req%.req}.ans.tmp" && mv -f "${req%.req}.ans.tmp" "${req%.req}.ans"
	done
	if [ -n "${missing}" ]; then
		mcp_mrtr_release "${dir}"
		MCP_MRTR_OUTCOME="input_required"
		return 0
	fi

	local attempt
	attempt="$(cat "${dir}/attempt" 2>/dev/null || printf 1)"
	case "${attempt}" in '' | *[!0-9]*) attempt=1 ;; esac
	attempt=$((attempt + 1))
	printf '%s' "${attempt}" >"${dir}/attempt"
	printf '%s %s' "${form}" "${url}" >"${dir}/modes"
	rm -f "${dir}/pos.step" "${dir}/pos.q" "${dir}/stop" "${dir}/diverged" "${dir}/diverged.detail"
	MCP_MRTR_OUTCOME="run" MCP_MRTR_ATTEMPT="${attempt}"
	return 0
}

# shellcheck disable=SC2034
mcp_mrtr_open_expired() {
	MCP_MRTR_OUTCOME="error"
	MCP_MRTR_ERROR_TYPE="request_expired"
	MCP_MRTR_ERROR_MESSAGE="This request expired or is unknown to this server: run the tool again"
}

# The input_required result for the questions still open in DIR.
mcp_mrtr_pending_result() {
	local dir="$1" ticket="$2" req key
	{
		for req in "${dir}"/q.*.req; do
			[ -f "${req}" ] || continue
			[ -f "${req%.req}.ans" ] && continue
			key="${req##*/q.}"
			printf '%s\t' "q${key%.req}"
			cat "${req}"
			printf '\n'
		done
	} | "${MCPBASH_JSON_TOOL_BIN}" -R -s -c --arg t "${ticket}" '
		[split("\n")[] | select(length > 0) | split("\t") | {key: .[0], value: {method: "elicitation/create", params: (.[1:] | join("\t") | fromjson)}}]
		| {resultType: "input_required", inputRequests: from_entries, requestState: $t}
	'
}

# Which journal a worker's call uses, so a cancel (which stops the worker
# with a signal, before it can clean up) can remove it.
mcp_mrtr_bind_worker() {
	local key="$1" dir="$2"
	if [ -z "${key}" ] || [ -z "${MCPBASH_STATE_DIR:-}" ]; then
		return 0
	fi
	printf '%s' "${dir}" >"${MCPBASH_STATE_DIR}/mrtr.${key}" 2>/dev/null || true
}

# The call answered: a later cancel of its id no longer concerns the journal.
mcp_mrtr_unbind_worker() {
	local key="$1"
	if [ -z "${key}" ] || [ -z "${MCPBASH_STATE_DIR:-}" ]; then
		return 0
	fi
	rm -f "${MCPBASH_STATE_DIR}/mrtr.${key}"
}

# The worker's call was cancelled: remove its journal.
mcp_mrtr_abandon_worker() {
	local key="$1" dir
	if [ -z "${key}" ] || [ -z "${MCPBASH_STATE_DIR:-}" ]; then
		return 0
	fi
	dir="$(cat "${MCPBASH_STATE_DIR}/mrtr.${key}" 2>/dev/null || true)"
	mcp_mrtr_close "${dir}"
	rm -f "${MCPBASH_STATE_DIR}/mrtr.${key}"
}

# How the run on DIR ended: input_required, diverged or complete.
mcp_mrtr_run_outcome() {
	local dir="$1" stop
	stop="$(cat "${dir}/stop" 2>/dev/null || true)"
	case "${stop}" in
	input_required | diverged) printf '%s' "${stop}" ;;
	*) printf 'complete' ;;
	esac
}
