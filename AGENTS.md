# AGENTS.md

Guidance for anyone (human or AI agent) changing mcp-bash-framework. It covers what
isn't obvious from the code. Setup, test commands and the release checklist live in
[CONTRIBUTING.md](CONTRIBUTING.md) and [TESTING.md](TESTING.md); read those first.

## Repository map

| Path | What it is |
|---|---|
| `bin/mcp-bash` | CLI entry point and server launcher |
| `lib/` | Runtime: read loop and workers (`core.sh`), JSON (`json.sh`), env isolation (`tools.sh`, `meta_env.sh`), resources and template matching (`resources.sh`, `resource_match.sh`), verified file reads (`file_read.sh`), HTTPS/git address policy (`policy.sh`), CLI subcommands (`lib/cli/`) |
| `handlers/` | One file per MCP method family (`lifecycle.sh`, `resources.sh`, `completion.sh`, ...) |
| `providers/` | Built-in resource providers (`file`, `https`, `git`, `ui`) |
| `sdk/` | Helpers sourced by tool scripts (`tool-sdk.sh`) |
| `scaffold/` | Templates for `mcp-bash new` / `scaffold` |
| `examples/` | Numbered examples `00`–`15`, `advanced/`, and `99-test-fixtures` |
| `test/` | `lint.sh`, `smoke.sh`, `run-all.sh`, `unit/` (bats), `integration/`, `examples/`, `stress/`, `compatibility/`, `conformance/`, `benchmark/`, shared helpers in `common/` |
| `hooks/pre-commit` | Git pre-commit hook |
| `tools/` | Go module pinning developer tools |
| `scripts/` | `render-readme.sh`, `bump-version.sh`, ... |
| `docs/` | User docs; `docs/ENV_REFERENCE.md` lists every variable |

`README.md` is generated: edit `README.md.in`, then run `bash scripts/render-readme.sh`.

## Portability traps

The server must run on macOS `/bin/bash` 3.2 (what GUI hosts such as Claude Desktop
launch) and on bash 4+/5, with jq, gojq or jq 1.6, on macOS, Linux and Git Bash.

**bash 3.2:**
- `"${arr[@]}"` on an empty array is an "unbound variable" error under `set -u`. Use
  `${arr[@]+"${arr[@]}"}`.
- `printf '%d' "'c"` is negative for bytes ≥ 0x80. Mask with `$(( code & 255 ))`.
- `read -t` returns 1 on timeout (bash 4+: > 128), so status 1 is not EOF on 3.2.
- With `set -e` and an EXIT trap, a fatal error can exit 0. Don't trust exit status alone
  in tests; check for the expected output too.
- No `BASH_XTRACEFD`, no `${var,,}`, no associative arrays, no `mapfile`.
- After a failed write to stdout (EPIPE), unwritten bytes stay in bash's buffer and leak
  into later `$(...)` output.

**All bash versions:**
- Never write `"${x:-{}}"`: bash ends the expansion at the first `}` and appends a stray `}`
  to a set value. Use `local d='{}'; x="${x:-$d}"`. `test/lint.sh` rejects the pattern.
- Single-quoted escapes are literal: `'\n'` is two characters. Use `$'\n'`.

**jq:**
- Code must work with jq, gojq and jq 1.6. jq 1.6's `index` uses byte offsets.
- Pass large data on stdin, never as an argument: Linux caps one argument at 128 KiB and
  macOS caps the whole argument list at about 1 MiB.
- Pass values with `--arg`/`--argjson`; never splice them into the jq program.

## Security model in brief

Details are in [docs/SECURITY.md](docs/SECURITY.md); keep it accurate when you change any
of this.
- Tools are denied unless allowlisted. A project `server.d/policy.sh` must call
  `mcp_tools_policy_check_default` or it disables the allowlist.
- Tools and providers get a curated environment: framework-owned `MCP_*` names only, and
  never `MCPBASH_REMOTE_TOKEN*`.
- `file://` and `ui://` reads go through `mcp_file_read_verified` (checks the opened file,
  not just the path). New file-reading code paths should too.
- HTTPS/git providers use the single range list in `lib/policy.sh` and pin the resolved
  address. Don't add a second list.
- Fail closed: when a check can't be performed, refuse.

## Tests

- **New integration test → add it to the `TESTS` list in `test/integration/run.sh`.**
  Nothing runs a test that isn't listed.
- Every fix needs a test that fails before it and passes after.
- Run new or changed tests under both shells. For 3.2, put a directory first on `PATH` that
  contains only a `bash -> /bin/bash` symlink, so `env bash` shebangs pick 3.2 too.
- CI runs the integration suite twice: in CI mode (`MCPBASH_CI_MODE`, blocking reads) and
  in real mode (the timed read loop users get). Behaviour can differ; test both.
- Tests must clear debug-retention settings they don't expect (`MCPBASH_KEEP_LOGS`,
  `MCPBASH_PRESERVE_STATE`, `MCPBASH_LOG_DIR`): CI sets them.
- macOS CI runners are sometimes 2x slower. Give timing assertions wide margins, and prefer
  waiting for a condition over fixed sleeps.

## Making changes

- `bash test/lint.sh` must pass. Format with `shfmt -w -bn -kp`, only on lines you changed.
- One logical change per commit, with a `CHANGELOG.md` `[Unreleased]` entry. Behaviour that
  could break an existing setup also goes in the "Behaviour changes" list at the top of the
  section.
- Update the user docs, `docs/ENV_REFERENCE.md` (new variables) and `llms-full.txt` when
  behaviour changes.
- Commit messages and PR text are public: no local paths, and no references to private
  notes or review IDs.
