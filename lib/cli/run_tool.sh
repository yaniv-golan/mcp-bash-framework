#!/usr/bin/env bash
# CLI run-tool command and helpers.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash run-tool; BASH_VERSION missing\n' >&2
	exit 1
fi

# Ensure require helper is available (for standalone sourcing).
if ! command -v mcp_require >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/lib/require.sh"
fi

# Ensure roots and JSON helpers are available for validation.
mcp_require roots mcp_roots_normalize_path
mcp_require json mcp_json_extract_file_required

# Globals: usage() from bin, MCPBASH_PROJECT_ROOT, MCPBASH_JSON_TOOL[_BIN], MCPBASH_MODE and runtime globals set by initialize_runtime_paths.

mcp_cli_run_tool_load_cache() {
	local cache_path="${MCPBASH_PROJECT_ROOT}/.registry/tools.json"
	if [ ! -f "${cache_path}" ]; then
		printf 'run-tool: registry cache missing (expected %s)\n' "${cache_path}" >&2
		return 1
	fi
	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		printf 'run-tool: JSON tooling required for --no-refresh\n' >&2
		return 1
	fi
	# shellcheck disable=SC2034  # Globals consumed by tools/runtime after CLI setup
	MCP_TOOLS_REGISTRY_JSON="$(cat "${cache_path}")"
	# shellcheck disable=SC2034
	MCP_TOOLS_REGISTRY_PATH="${cache_path}"
	# shellcheck disable=SC2034
	MCP_TOOLS_REGISTRY_HASH="$(mcp_json_extract_file_required "${cache_path}" "-r" '.hash // empty' "run-tool: invalid tools registry cache")" || return 1
	if [ -z "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		printf 'run-tool: invalid tools registry cache (missing hash)\n' >&2
		return 1
	fi
	# shellcheck disable=SC2034
	MCP_TOOLS_TOTAL="$(mcp_json_extract_file_required "${cache_path}" "-r" '.total // 0 | tostring' "run-tool: invalid tools registry cache")" || return 1
	case "${MCP_TOOLS_TOTAL}" in
	'' | *[!0-9]*)
		printf 'run-tool: invalid tools registry cache (non-numeric total)\n' >&2
		return 1
		;;
	esac
	# shellcheck disable=SC2034
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	MCP_TOOLS_TTL="${MCP_TOOLS_TTL:-31536000}"
}

# A cache loaded from disk counts as fresh for MCP_TOOLS_TTL from the moment it
# is loaded, so a one-shot run-tool never rescanned and missed tools added or
# changed since the last scan. Force a rescan when anything under the tools
# directory (including the directory itself, whose mtime changes when entries
# are added, removed or renamed) is newer than the cache; otherwise keep the
# cache, so unchanged projects stay fast.
mcp_cli_run_tool_mark_stale_cache() {
	local cache_path="${MCPBASH_PROJECT_ROOT}/.registry/tools.json"
	local tools_dir="${MCPBASH_TOOLS_DIR:-${MCPBASH_PROJECT_ROOT}/tools}"
	[ -f "${cache_path}" ] || return 0
	[ -d "${tools_dir}" ] || return 0
	local newer=""
	# Each check stops reading at the first match, which can kill find with
	# SIGPIPE; under pipefail that fails the pipeline, so keep whatever was
	# printed instead of discarding it.
	newer="$(find "${tools_dir}" -newer "${cache_path}" -print 2>/dev/null | head -n 1 || true)"
	if [ -z "${newer}" ]; then
		# BusyBox find compares whole seconds, so an entry changed in the same
		# second the cache was written is not "newer". Where stat -c works (GNU,
		# BusyBox), count such entries too; at worst that costs a rescan.
		local cache_secs=""
		if cache_secs="$(stat -c %Y "${cache_path}" 2>/dev/null)"; then
			case "${cache_secs}" in
			'' | *[!0-9]*) ;;
			*)
				newer="$(find "${tools_dir}" -exec stat -c %Y {} + 2>/dev/null \
					| awk -v c="${cache_secs}" '$1 >= c { print; exit }' || true)"
				;;
			esac
		fi
	fi
	# shellcheck disable=SC2034  # Consumed by mcp_tools_refresh_registry
	if [ -n "${newer}" ]; then
		MCP_TOOLS_LAST_SCAN=0
	else
		# Nothing under tools/ is newer than the cache: it is current, however
		# old. Count it as scanned now, or the loader would date it by its
		# mtime and rescan any cache older than the TTL.
		MCP_TOOLS_LAST_SCAN="$(date +%s)"
	fi
	return 0
}

mcp_cli_run_tool_prepare_roots() {
	local roots_arg="$1"
	# shellcheck disable=SC2034  # Consumed by roots helpers after CLI setup
	MCPBASH_ROOTS_PATHS=()
	# shellcheck disable=SC2034
	MCPBASH_ROOTS_URIS=()
	# shellcheck disable=SC2034
	MCPBASH_ROOTS_NAMES=()
	[ -z "${roots_arg}" ] && return 0
	local had_error=0
	local IFS=',' root
	for root in ${roots_arg}; do
		[ -n "${root}" ] || continue
		local norm
		if ! norm="$(mcp_roots_canonicalize_checked "${root}" "--roots" 1)"; then
			had_error=1
			continue
		fi
		mcp_roots_append_unique "${norm}" "$(basename "${norm}")"
	done
	# roots.sh is always sourced for CLI runs, so mcp_roots_wait_ready will see READY=1.
	# shellcheck disable=SC2034  # Used by mcp_roots_wait_ready downstream
	MCPBASH_ROOTS_READY=1
	return "${had_error}"
}

mcp_cli_run_tool_source_env() {
	local file="$1"
	local is_verbose="$2" # Pass verbose state as parameter for proper scoping
	local resolved=""

	# Resolve relative paths against MCPBASH_PROJECT_ROOT
	if [[ "${file}" != /* ]]; then
		resolved="${MCPBASH_PROJECT_ROOT}/${file}"
	else
		resolved="${file}"
	fi

	if [ ! -f "${resolved}" ]; then
		printf 'run-tool: env file not found: %s\n' "${resolved}" >&2
		return 1
	fi

	if [ ! -r "${resolved}" ]; then
		printf 'run-tool: env file not readable: %s\n' "${resolved}" >&2
		return 1
	fi

	# Verbose output for debugging environment issues
	if [ "${is_verbose}" = "true" ]; then
		printf 'run-tool: sourcing %s\n' "${resolved}" >&2
	fi

	# Check syntax first. On bash 3.2 a parse error inside a sourced file (for
	# example a malformed [[ ]]) aborts the shell under set -e, and the EXIT
	# trap then turns that into exit status 0, so run-tool reported success.
	if ! "${BASH:-bash}" -n "${resolved}"; then
		printf 'run-tool: syntax error in env file: %s\n' "${resolved}" >&2
		return 1
	fi

	# Source the file in current shell context
	# shellcheck disable=SC1090
	. "${resolved}"
}

# Print the tool/provider env policy for --print-env. Names and states only;
# values are never printed. Reflects the launch env plus server.meta.json as
# this process sees them now, before --with-server-env / --source files and
# before server.d/policy.sh run.
mcp_cli_run_tool_print_env_policy() {
	mcp_require meta_env mcp_meta_env_report
	printf 'ENV_POLICY (launch env + server.meta.json only; does not include --with-server-env or --source files, or server.d/policy.sh):\n'
	local kind a b c scope_label
	while IFS=$'\t' read -r kind a b c; do
		case "${a}" in
		TOOL) scope_label="tools" ;;
		PROVIDER) scope_label="providers" ;;
		*) scope_label="${a}" ;;
		esac
		case "${kind}" in
		switch) printf '  MCPBASH_IGNORE_META_ENV is set: server.meta.json env is ignored\n' ;;
		policy) printf '  %s: mode %s (from %s)\n' "${scope_label}" "${b}" "${c}" ;;
		name) printf '    %s: %s\n' "${b}" "${c}" ;;
		badname) printf '    %s: allowlist entry %s is not a valid variable name and is skipped\n' "${scope_label}" "${b}" ;;
		inherit) printf '  %s: inherit mode without MCPBASH_%s_ENV_INHERIT_ALLOW=true will be refused\n' "${scope_label}" "${a}" ;;
		refused) printf '  server.meta.json env.%s is ignored (not settable there)\n' "${a}" ;;
		invalid | error) printf '  server.meta.json env.%s: %s\n' "${a}" "${b}" ;;
		esac
	done < <(mcp_meta_env_report)
}

# The inputResponses entry for one question from one --answer value.
# Usage: mcp_cli_run_tool_answer_response PARAMS_JSON ANSWER
# PARAMS_JSON is the question (inputRequests.<key>.params). ANSWER is
# accept, decline, cancel, a JSON object (the content as is), FIELD=VALUE, or
# a bare VALUE for a question with one field. A value is typed by the field's
# schema: boolean, number, integer, or an array split on commas. Prints the
# response, or the reason it can't be built (and returns 1).
mcp_cli_run_tool_answer_response() {
	local reply
	reply="$(printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg a "$2" '
		def fields: (.requestedSchema.properties // {});
		def typed($f; $k; $v):
			($f[$k].type // "string") as $t
			| if $t == "boolean" then
				(if $v == "true" then true elif $v == "false" then false
				else error("\($k) must be true or false") end)
			elif $t == "integer" then
				(($v | tonumber?) // null) as $n
				| if $n == null or ($n | floor) != $n then error("\($k) must be a whole number") else $n end
			elif $t == "number" then
				(($v | tonumber?) // null) as $n
				| if $n == null then error("\($k) must be a number") else $n end
			elif $t == "array" then ($v | split(","))
			else $v end;
		def accept($f; $k; $v):
			if ($f | has($k)) then {action: "accept", content: {($k): typed($f; $k; $v)}}
			else error("the question has no field \($k) (its fields: \($f | keys | join(", ")))") end;
		. as $q
		| fields as $f
		| try (
			if $a == "decline" or $a == "cancel" then {action: $a}
			elif ($q.mode // "form") == "url" then
				(if $a == "accept" then {action: "accept"}
				else error("a URL question takes accept, decline or cancel") end)
			elif $a == "accept" then {action: "accept", content: {}}
			elif ($a | startswith("{")) then
				((try ($a | fromjson) catch null) as $c
				| if ($c | type) == "object" then {action: "accept", content: $c}
				else error("the answer is not a JSON object") end)
			elif ($a | contains("=")) then
				($a | split("=")) as $kv
				| accept($f; $kv[0]; ($kv[1:] | join("=")))
			elif ($f | keys | length) == 1 then accept($f; ($f | keys)[0]; $a)
			else error("answer with FIELD=VALUE (the question'"'"'s fields: \($f | keys | join(", ")))") end
			| {response: .}
		) catch {error: (if type == "string" then . else "invalid answer" end)}
	' 2>/dev/null)" || reply='{"error":"invalid answer"}'
	if printf '%s' "${reply}" | "${MCPBASH_JSON_TOOL_BIN}" -e 'has("response")' >/dev/null 2>&1; then
		printf '%s' "${reply}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.response'
		return 0
	fi
	printf '%s' "${reply}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.error'
	return 1
}

# One line of the replay trace, for run N of a call with questions:
# "run 2: 1 step replayed, 1 executed, stopped at question 2 (Who?)". With
# VERBOSE=true, each step and question follows on its own line.
# Usage: mcp_cli_run_tool_print_trace N OUTCOME TRACE RESULT_JSON VERBOSE
mcp_cli_run_tool_print_trace() {
	local run="$1" outcome="$2" trace="$3" result="$4" verbose="$5"
	local executed=0 replayed=0 line parts="" end=""
	while IFS= read -r line; do
		case "${line}" in
		"step "*" executed"*) executed=$((executed + 1)) ;;
		"step "*" replayed"*) replayed=$((replayed + 1)) ;;
		esac
	done <<<"${trace}"
	if [ "${replayed}" -gt 0 ]; then
		parts="${replayed} step"
		[ "${replayed}" -eq 1 ] || parts="${parts}s"
		parts="${parts} replayed"
		[ "${executed}" -eq 0 ] || parts="${parts}, ${executed} executed"
	elif [ "${executed}" -gt 0 ]; then
		parts="${executed} step"
		[ "${executed}" -eq 1 ] || parts="${parts}s"
		parts="${parts} executed"
	fi
	case "${outcome}" in
	input_required)
		end="$(printf '%s' "${result}" | "${MCPBASH_JSON_TOOL_BIN}" -r '
			.inputRequests | to_entries[0] | "stopped at question \(.key | ltrimstr("q")) (\(.value.params.message // ""))"' 2>/dev/null || printf 'stopped at a question')"
		;;
	diverged) end="diverged${_MCP_TOOLS_MRTR_DETAIL:+: ${_MCP_TOOLS_MRTR_DETAIL}}" ;;
	*) end="completed" ;;
	esac
	printf 'run %s: %s\n' "${run}" "${parts:+${parts}, }${end}" >&2
	if [ "${verbose}" = "true" ] && [ -n "${trace}" ]; then
		while IFS= read -r line; do
			[ -n "${line}" ] && printf '  %s\n' "${line}" >&2
		done <<<"${trace}"
	fi
}

mcp_cli_run_tool() {
	local project_root=""
	local args_json="{}"
	local roots_arg=""
	local dry_run="false"
	local timeout_override=""
	local verbose="false"
	local no_refresh="false"
	local minimal="false"
	local print_env="false"
	local allow_self="false"
	local allow_all="false"
	local allow_names=()
	local tool_name=""
	local with_server_env="false"
	local source_files=()
	local answers=()
	local no_elicitation="false"

	while [ $# -gt 0 ]; do
		case "$1" in
		--args)
			shift
			args_json="${1:-}"
			if [ -z "${args_json}" ]; then
				args_json="{}"
			fi
			;;
		--roots)
			shift
			roots_arg="${1:-}"
			;;
		--dry-run)
			dry_run="true"
			;;
		--timeout)
			shift
			timeout_override="${1:-}"
			;;
		--verbose)
			verbose="true"
			;;
		--no-refresh)
			no_refresh="true"
			;;
		--minimal)
			minimal="true"
			;;
		--print-env)
			print_env="true"
			;;
		--allow-self)
			allow_self="true"
			;;
		--allow)
			shift
			if [ -z "${1:-}" ]; then
				printf 'run-tool: --allow requires a tool name\n' >&2
				exit 1
			fi
			allow_names+=("$1")
			;;
		--allow-all)
			allow_all="true"
			;;
		--project-root)
			shift
			project_root="${1:-}"
			;;
		--with-server-env)
			with_server_env="true"
			;;
		--answer)
			shift
			# A flag after --answer is a missing value, not an answer; a
			# value that starts with -- can still be given as FIELD=--x.
			case "${1:-}" in
			'' | --*)
				printf 'run-tool: --answer requires a value (FIELD=VALUE, VALUE, a JSON object, accept, decline or cancel)\n' >&2
				exit 1
				;;
			esac
			answers+=("$1")
			;;
		--no-elicitation)
			no_elicitation="true"
			;;
		--source)
			shift
			if [ -z "${1:-}" ]; then
				printf 'run-tool: --source requires a file path\n' >&2
				exit 1
			fi
			source_files+=("$1")
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash run-tool <name> [--args JSON] [--roots paths] [--dry-run]
                     [--timeout SECS] [--verbose] [--no-refresh]
                     [--minimal] [--project-root DIR] [--print-env]
                     [--allow-self] [--allow TOOL] [--allow-all]
                     [--with-server-env] [--source FILE]...
                     [--answer ANSWER]... [--no-elicitation]

Invoke a tool directly with the same env wiring used by the server, as a
2026-07-28 client calls it.

Options:
  --with-server-env  Source env.sh from the server dir (server.d, or MCPBASH_SERVER_DIR) before tool execution
  --source FILE      Source FILE before tool execution (repeatable;
                     sourced after --with-server-env, in order specified)
  --answer ANSWER    Answer the tool's next question (repeatable, one per
                     question, in the order asked): FIELD=VALUE, a bare VALUE
                     for a question with one field, a JSON object (the
                     content as is), accept, decline or cancel. The tool runs
                     again from the start for each answer; steps wrapped in
                     mcp_once replay. A trace of the runs goes to stderr
                     (--verbose lists each step). A question with no answer
                     left prints the input_required result and exits 1.
  --no-elicitation   Call as a client that can't ask (such as a Claude
                     Desktop extension): questions answer "unavailable"
                     and --arg answers them, as there.

Examples:
  # Allow just this invocation
  mcp-bash run-tool hello --allow-self --args @args.json
  mcp-bash run-tool hello --allow hello --args @args.json
  # Unsafe (trusted projects only):
  mcp-bash run-tool hello --allow-all --args @args.json
  mcp-bash run-tool hello --args @args.json --roots .
  mcp-bash run-tool hello --print-env --dry-run
  # Source server environment before execution
  mcp-bash run-tool hello --with-server-env --allow-self
  mcp-bash run-tool hello --source config/test.sh --allow-self
  # Answer the tool's questions
  mcp-bash run-tool deploy --allow-self --answer confirmed=true
EOF
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			exit 1
			;;
		*)
			if [ -z "${tool_name}" ]; then
				tool_name="${1}"
			else
				printf 'run-tool: unexpected argument: %s\n' "$1" >&2
				exit 1
			fi
			;;
		esac
		shift
	done

	if [ "${no_elicitation}" = "true" ] && [ "${#answers[@]}" -gt 0 ]; then
		printf 'run-tool: --answer and --no-elicitation do not go together: a client that cannot ask gets no questions\n' >&2
		exit 1
	fi

	if [ -z "${tool_name}" ]; then
		if [ $# -gt 0 ]; then
			tool_name="$1"
			shift
		else
			printf 'run-tool: tool name required\n' >&2
			exit 1
		fi
	fi

	# Per-invocation allow policy for CLI runs. This keeps the global default
	# deny posture while letting explicit CLI calls opt in narrowly.
	if [ "${allow_all}" = "true" ]; then
		MCPBASH_TOOL_ALLOWLIST="*"
		export MCPBASH_TOOL_ALLOWLIST
	elif [ "${allow_self}" = "true" ] || [ "${#allow_names[@]}" -gt 0 ] 2>/dev/null; then
		local allowlist="${tool_name}"
		if [ "${allow_self}" != "true" ]; then
			allowlist=""
		fi
		local idx
		for idx in "${!allow_names[@]}"; do
			local entry="${allow_names[${idx}]}"
			[ -n "${entry}" ] || continue
			if [ -n "${allowlist}" ]; then
				allowlist="${allowlist} ${entry}"
			else
				allowlist="${entry}"
			fi
		done
		MCPBASH_TOOL_ALLOWLIST="${allowlist}"
		export MCPBASH_TOOL_ALLOWLIST
	fi

	# Allow explicit project override
	if [ -n "${project_root}" ]; then
		MCPBASH_PROJECT_ROOT="${project_root}"
		export MCPBASH_PROJECT_ROOT
	fi

	require_bash_runtime
	initialize_runtime_paths
	if [ "${minimal}" = "true" ]; then
		MCPBASH_FORCE_MINIMAL=true
		export MCPBASH_FORCE_MINIMAL
	fi
	mcp_runtime_init_paths "cli"
	mcp_runtime_detect_json_tool

	if [ "${no_refresh}" = "true" ]; then
		mcp_cli_run_tool_load_cache || exit 1
	else
		mcp_cli_run_tool_mark_stale_cache
	fi

	if ! mcp_cli_run_tool_prepare_roots "${roots_arg}"; then
		printf 'run-tool: invalid --roots value; see log for details\n' >&2
		exit 1
	fi

	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ] || [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
		if [ "${args_json}" != "{}" ]; then
			printf 'run-tool: JSON tooling required to parse --args\n' >&2
		else
			printf 'run-tool: JSON tooling required (jq or gojq)\n' >&2
		fi
		exit 1
	fi

	if [ "${print_env}" = "true" ]; then
		printf 'MCPBASH_PROJECT_ROOT=%s\n' "${MCPBASH_PROJECT_ROOT}"
		printf 'MCPBASH_HOME=%s\n' "${MCPBASH_HOME}"
		printf 'MCP_SDK=%s\n' "${MCP_SDK:-}"
		printf 'MCPBASH_MODE=%s\n' "${MCPBASH_MODE:-}"

		# Show env sources that would be applied (not actually sourced in --print-env mode)
		# Check for env var trigger
		local will_source_server_env="${with_server_env}"
		if [ "${MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV:-}" = "1" ] || [ "${MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV:-}" = "true" ]; then
			will_source_server_env="true"
		fi
		if [ "${will_source_server_env}" = "true" ]; then
			local server_env
			server_env="$(mcp_runtime_effective_server_dir)/env.sh"
			if [ -f "${server_env}" ]; then
				printf 'WILL_SOURCE_SERVER_ENV=%s\n' "${server_env}"
			else
				printf 'WILL_SOURCE_SERVER_ENV=(not found: %s)\n' "${server_env}"
			fi
		fi
		# Guard for empty array on Windows/Git Bash
		if [ "${#source_files[@]}" -gt 0 ] 2>/dev/null; then
			local idx resolved
			for idx in "${!source_files[@]}"; do
				resolved="${source_files[${idx}]}"
				if [[ "${resolved}" != /* ]]; then
					resolved="${MCPBASH_PROJECT_ROOT}/${resolved}"
				fi
				if [ -f "${resolved}" ]; then
					printf 'WILL_SOURCE[%d]=%s\n' "${idx}" "${resolved}"
				else
					printf 'WILL_SOURCE[%d]=(not found: %s)\n' "${idx}" "${resolved}"
				fi
			done
		fi

		if [ "${#MCPBASH_ROOTS_PATHS[@]}" -gt 0 ] 2>/dev/null; then
			local idx
			for idx in "${!MCPBASH_ROOTS_PATHS[@]}"; do
				printf 'ROOT[%d]=%s\n' "${idx}" "${MCPBASH_ROOTS_PATHS[${idx}]}"
			done
		else
			printf 'ROOTS=none\n'
		fi
		mcp_cli_run_tool_print_env_policy
		exit 0
	fi

	# Source environment files (after --print-env to avoid side effects in diagnostic mode)
	if [ "${MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV:-}" = "1" ] || [ "${MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV:-}" = "true" ]; then
		with_server_env="true"
	fi

	# Source server.d/env.sh if requested
	if [ "${with_server_env}" = "true" ]; then
		local server_env
		server_env="$(mcp_runtime_effective_server_dir)/env.sh"
		if [ -f "${server_env}" ]; then
			mcp_cli_run_tool_source_env "${server_env}" "${verbose}" || exit 1
		fi
		# Note: silently skip if server.d/env.sh doesn't exist (optional file)
	fi

	# Source any explicitly specified files (guard for empty array on Windows/Git Bash)
	if [ "${#source_files[@]}" -gt 0 ] 2>/dev/null; then
		local idx
		for idx in "${!source_files[@]}"; do
			mcp_cli_run_tool_source_env "${source_files[${idx}]}" "${verbose}" || exit 1
		done
	fi

	# Same declarative env policy as the server, so local runs match production.
	# Applied after sourced env files, which count as launch env (they win per
	# scope, exactly like variables set before launching the server).
	mcp_require meta_env mcp_meta_env_apply
	mcp_meta_env_apply

	if ! printf '%s' "${args_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e 'type=="object"' >/dev/null 2>&1; then
		printf 'run-tool: --args must be a JSON object\n' >&2
		exit 1
	fi

	local metadata=""
	if ! metadata="$(mcp_tools_metadata_for_name "${tool_name}")"; then
		printf 'run-tool: tool not found: %s\n' "${tool_name}" >&2
		exit 1
	fi

	local metadata_timeout
	metadata_timeout="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN:-}" -r '.timeoutSecs // "" | tostring' 2>/dev/null || printf '')"
	if [ "${metadata_timeout}" = "null" ]; then
		metadata_timeout=""
	fi
	local effective_timeout="${timeout_override:-${metadata_timeout}}"

	if [ "${dry_run}" = "true" ]; then
		local roots_count=0
		if [ "${#MCPBASH_ROOTS_PATHS[@]}" -gt 0 ] 2>/dev/null; then
			roots_count="${#MCPBASH_ROOTS_PATHS[@]}"
		fi
		printf 'Tool: %s\n' "${tool_name}"
		printf 'Args: %s bytes\n' "$(printf '%s' "${args_json}" | wc -c | tr -d ' ')"
		printf 'Roots: %d\n' "${roots_count}"
		printf 'Timeout: %s\n' "${effective_timeout:-none}"
		printf 'Answers: %d\n' "${#answers[@]}"
		printf 'Status: Ready to execute (re-run without --dry-run to run)\n'
		exit 0
	fi

	if [ "${verbose}" = "true" ]; then
		MCPBASH_TOOL_STREAM_STDERR=true
		export MCPBASH_TOOL_STREAM_STDERR
	fi

	# Let the policy layer tailor error messages for explicit CLI invocations.
	MCPBASH_TOOL_POLICY_CONTEXT="run-tool"
	export MCPBASH_TOOL_POLICY_CONTEXT

	# Call the tool as a 2026-07-28 client that can answer questions: a
	# question ends the run with input_required, and the next --answer goes
	# into the retry. With --no-elicitation, as one that can't ask.
	local can_ask=1
	[ "${no_elicitation}" != "true" ] || can_ask=0
	# shellcheck disable=SC2034  # Read by mcp_tools_call and lib/elicitation.sh
	MCPBASH_PROTOCOL_ERA="modern"
	# shellcheck disable=SC2034
	MCPBASH_CLIENT_SUPPORTS_ELICITATION="${can_ask}"
	# shellcheck disable=SC2034
	MCPBASH_CLIENT_ELICIT_FORM="${can_ask}"
	# shellcheck disable=SC2034
	MCPBASH_CLIENT_ELICIT_URL="${can_ask}"
	# shellcheck disable=SC2034  # Read by mcp_tools_call (lib/tools.sh)
	MCPBASH_MRTR_REQUEST_STATE=""
	# shellcheck disable=SC2034
	MCPBASH_MRTR_INPUT_RESPONSES=""

	local result_json="" call_status run=0 used=0
	local question_key question_params response
	while :; do
		run=$((run + 1))
		call_status=0
		# CLI invocations don't have request _meta; pass empty object
		mcp_tools_call "${tool_name}" "${args_json}" "${effective_timeout}" "{}" || call_status=$?
		result_json="${_MCP_TOOLS_RESULT:-}"
		if [ "${run}" -gt 1 ] || [ "${_MCP_TOOLS_MRTR_OUTCOME:-}" = "input_required" ]; then
			mcp_cli_run_tool_print_trace "${run}" "${_MCP_TOOLS_MRTR_OUTCOME:-}" "${_MCP_TOOLS_MRTR_TRACE:-}" "${result_json}" "${verbose}"
		fi
		[ "${call_status}" -eq 0 ] || break
		printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.resultType == "input_required"' >/dev/null 2>&1 || break
		question_key="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.inputRequests | keys[0]')"
		question_params="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg k "${question_key}" '.inputRequests[$k].params')"
		if [ "${used}" -ge "${#answers[@]}" ]; then
			printf '%s\n' "${result_json}"
			printf '%s' "${question_params}" | "${MCPBASH_JSON_TOOL_BIN}" -r --arg k "${question_key}" '
				"run-tool: the tool asks question \($k | ltrimstr("q")): \(.message // "")\n"
				+ "Answer it with --answer "
				+ (if (.mode // "form") == "url" then "accept, decline or cancel"
				else ((.requestedSchema.properties // {}) | keys) as $f
					| if ($f | length) == 0 then "accept, decline or cancel"
					else "\($f[0])=VALUE (its fields: \($f | join(", "))), decline or cancel" end
				end)' >&2
			exit 1
		fi
		if ! response="$(mcp_cli_run_tool_answer_response "${question_params}" "${answers[${used}]}")"; then
			printf 'run-tool: --answer %s for question %s: %s\n' "${answers[${used}]}" "${question_key#q}" "${response}" >&2
			exit 1
		fi
		used=$((used + 1))
		# shellcheck disable=SC2034  # Read by mcp_tools_call (lib/tools.sh)
		MCPBASH_MRTR_REQUEST_STATE="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.requestState')"
		# shellcheck disable=SC2034
		MCPBASH_MRTR_INPUT_RESPONSES="$("${MCPBASH_JSON_TOOL_BIN}" -n -c --arg k "${question_key}" --argjson r "${response}" '{($k): $r}')"
	done
	if [ "${used}" -lt "${#answers[@]}" ]; then
		local unused=$((${#answers[@]} - used))
		if [ "${unused}" -eq 1 ]; then
			printf 'run-tool: 1 --answer value was not used\n' >&2
		else
			printf 'run-tool: %d --answer values were not used\n' "${unused}" >&2
		fi
	fi

	if [ "${call_status}" -eq 0 ]; then
		printf '%s\n' "${result_json}"
		# Any error result (isError: true), a policy denial included, exits 1,
		# so scripts and CI that run a tool see that it failed.
		if [ "${_MCP_TOOLS_POLICY_DENIED:-false}" = "true" ]; then
			exit 1
		fi
		if printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.isError == true' >/dev/null 2>&1; then
			exit 1
		fi
		exit 0
	else
		if [ -n "${_MCP_TOOLS_RESULT:-}" ]; then
			printf '%s\n' "${_MCP_TOOLS_RESULT}"
		elif [ "${_MCP_TOOLS_ERROR_CODE:-0}" != "0" ] && [ -n "${_MCP_TOOLS_ERROR_MESSAGE:-}" ]; then
			# Early refusals (inherit gate, path policy, missing executable) set only
			# the error variables.
			printf 'run-tool: %s\n' "${_MCP_TOOLS_ERROR_MESSAGE}"
		else
			printf 'run-tool: tool execution failed\n'
		fi
		exit 1
	fi
}
