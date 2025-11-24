# Windows Support Notes

- Git-Bash/MSYS drive prefixes (e.g., `C:\foo`) are translated to `/c/foo` by providers to avoid lookup failures.
- Signal delivery (`kill -TERM`) may be unreliable; prefer WSL for production deployments.
- Ensure `MSYS2_ARG_CONV_EXCL=*` is set when passing raw Windows paths to tools to avoid unwanted conversion.
- JSON tooling (`jq` or `gojq`) may need manual installation (`pacman -S jq`).

## Known Issues

### Executable Permission Detection
Windows does not have native Unix execute permissions. Git Bash/MSYS2 simulates execute bits based on file extensions (`.sh`, `.bash`) or shebang lines (`#!/usr/bin/env bash`). The tool discovery scanner includes fallback logic to detect executable tools by:
1. Checking the `-x` test (may be unreliable on Windows)
2. Falling back to checking for `.sh`/`.bash` extensions
3. Falling back to checking for shebang lines in the file header

To ensure tools are discovered reliably on Windows:
- Use `.sh` extension for all tool scripts
- Include a shebang line (`#!/usr/bin/env bash`) at the start of each tool script
- Alternatively, use manual tool registration via `server.d/register.sh`

### gojq Compatibility
`gojq` v0.12.16 has known issues on Windows with the `--slurpfile` option, which can cause excessive memory allocation or OOM errors. Tests and scripts should prefer:
- `cat file.ndjson | jq -s '...'` instead of `jq -n --slurpfile messages file.ndjson '...'`
- Standard `jq` when available, falling back to `gojq` only when necessary
