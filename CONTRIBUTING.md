# Contributing

## Developer Prerequisites

Local linting and CI expect a few command-line tools to be present:

- `shellcheck` – static analysis for all shell scripts.
- `shfmt` – enforces consistent formatting (used by `test/lint.sh`). Install via `go install mvdan.cc/sh/v3/cmd/shfmt@latest` (official upstream method) or your OS package manager.
- `jq` or `gojq` – deterministic JSON tooling. mcp-bash auto-detects both; for Windows Git Bash/MSYS, `jq` is often more reliable due to observed exec/argument-size limits with `gojq` on some CI runners. CI installs `gojq` for reproducibility, but you can override detection with `MCPBASH_JSON_TOOL` / `MCPBASH_JSON_TOOL_BIN` if needed.
- `bats` – unit tests use [bats-core](https://bats-core.readthedocs.io/) (v1.5.0+). Run `npm install` to install bats and helper libraries (bats-support, bats-assert, bats-file). Alternatively, install bats-core via `brew install bats-core` (macOS) or `apt install bats` (Debian/Ubuntu).

Without `shfmt`, the lint step fails immediately with "Required command \"shfmt\" not found in PATH".

### Pre-commit hooks
Install [`pre-commit`](https://pre-commit.com/) and run `pre-commit install` to mirror CI formatting/linting locally. Hooks cover whitespace, `shfmt`, and shellcheck so commits fail fast when style drifts.

## Running Tests

See [TESTING.md](TESTING.md) for detailed instructions on running the test suite.

For CI parity (GitHub Actions uses these defaults), set `MCPBASH_CI_MODE=1` when reproducing failures locally so log paths, staging tar, and failure summaries match what the runners see.

## Code style & workflow
- Shell scripts must pass `./test/lint.sh` (shellcheck + shfmt). Keep functions small and prefer `set -euo pipefail`.
- Guard against unset variables/arrays when using `set -u`; avoid `BASH_REMATCH` under `set -u` (use parameter expansion or only read captures when a match succeeds).
- `README.md` is generated from `README.md.in`. After modifying `README.md.in`, run `bash scripts/render-readme.sh` and include both files in your PR (CI enforces `bash scripts/render-readme.sh --check`).
- Branches should be short-lived and opened as PRs against `main` with a concise summary of scope and test evidence.
- Contributions are governed by the [Code of Conduct](CODE_OF_CONDUCT.md); escalate concerns via the security contact in `docs/SECURITY.md`.

## Releasing a New Version

Follow this checklist to cut a release:

1. **Bump version & changelog** – run `bash scripts/bump-version.sh X.Y.Z`, update `CHANGELOG.md`, and re-render the README with `bash scripts/render-readme.sh`.
2. **Merge to `main`** – ensure all changes (code, tests, docs, version bump) are on `main` and CI is green.
3. **Create and push the tag** – `git tag vX.Y.Z && git push origin vX.Y.Z`. The CI release workflow triggers on version tags.
4. **Let CI create the release** – the GitHub Actions workflow creates the GitHub Release, uploads `mcp-bash-vX.Y.Z.tar.gz` and `SHA256SUMS` assets, and populates the release body. **Do not** create the release manually before the workflow runs, or the CI step will fail with `already_exists`.
5. **Verify** – confirm the release page has both assets and correct release notes: `gh release view vX.Y.Z --json assets,body,url`.
6. **Backfill assets (if CI release step failed)** – if a race or duplicate prevented asset upload, generate the tarball and checksums locally and upload them:
   ```bash
   git archive --format=tar.gz --prefix="mcp-bash-vX.Y.Z/" "vX.Y.Z" -o "mcp-bash-vX.Y.Z.tar.gz"
   shasum -a 256 "mcp-bash-vX.Y.Z.tar.gz" > SHA256SUMS
   gh release upload "vX.Y.Z" "mcp-bash-vX.Y.Z.tar.gz" SHA256SUMS --clobber
   ```
