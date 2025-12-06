# Contributing

## Developer Prerequisites

Local linting and CI expect a few command-line tools to be present:

- `shellcheck` – static analysis for all shell scripts.
- `shfmt` – enforces consistent formatting (used by `test/lint.sh`). Install via `go install mvdan.cc/sh/v3/cmd/shfmt@latest` (official upstream method) or your OS package manager.
- `gojq` (preferred) or `jq` – deterministic JSON tooling. The Go implementation behaves consistently across Linux/macOS/Windows and avoids known memory limits in the Windows `jq` build. Install with `go install github.com/itchyny/gojq/cmd/gojq@latest` and ensure `$HOME/go/bin` (or your `GOBIN`) is on `PATH`.

Without `shfmt`, the lint step fails immediately with "Required command \"shfmt\" not found in PATH".

### Pre-commit hooks
Install [`pre-commit`](https://pre-commit.com/) and run `pre-commit install` to mirror CI formatting/linting locally. Hooks cover whitespace, `shfmt`, and shellcheck so commits fail fast when style drifts.

## Running Tests

See [TESTING.md](TESTING.md) for detailed instructions on running the test suite.

## Code style & workflow
- Shell scripts must pass `./test/lint.sh` (shellcheck + shfmt). Keep functions small and prefer `set -euo pipefail`.
- Guard against unset variables/arrays when using `set -u`; avoid `BASH_REMATCH` under `set -u` (use parameter expansion or only read captures when a match succeeds).
- Branches should be short-lived and opened as PRs against `main` with a concise summary of scope and test evidence.
- Releases should update `CHANGELOG.md` and note any breaking protocol or SDK changes.
- Contributions are governed by the [Code of Conduct](CODE_OF_CONDUCT.md); escalate concerns via the security contact in `docs/SECURITY.md`.
