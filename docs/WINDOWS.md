# Windows Support Notes

mcp-bash works on Windows, but only reliably under WSL. Git Bash and MSYS can run it, but signal handling and performance vary.

## Guidance
- Use WSL for predictable behavior and clean signal handling.
- Git Bash/MSYS may drop signals; prefer short timeouts for long-running tools.
- Providers translate `C:\foo` to `/c/foo`; avoid mixing Windows and POSIX roots.
- Set `MSYS2_ARG_CONV_EXCL=*` when passing raw Windows paths to tools.
- Install JSON tooling manually (`pacman -S jq` or a downloaded `gojq`).

## Executable detection
Windows fakes execute bits. The scanner falls back to `.sh`/`.bash` extensions and shebangs when `-x` is unreliable. Use `.sh` plus `#!/usr/bin/env bash` or register tools manually via `server.d/register.sh`.

## gojq notes
`gojq` v0.12.16 struggles with `--slurpfile` on Windows. Prefer `cat file.ndjson | jq -s '...'` and use standard `jq` when available.

## CI (GitHub Actions)
- Git Bash runners can hit `Argument list too long` (`E2BIG`) when `gojq` launches with a large PATH/env.
- Export `MCPBASH_JSON_TOOL=jq` and `MCPBASH_JSON_TOOL_BIN="$(command -v jq)"` before invoking `mcp-bash` to pin jq and avoid the Windows exec-limit issue.
- Stick to `jq` for CI to bypass the Git Bash argument-length ceiling; fall back to `gojq` only on platforms without the Windows exec limit.
