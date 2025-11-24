# Contributing

## Developer Prerequisites

Local linting and CI expect a few command-line tools to be present:

- `shellcheck` – static analysis for all shell scripts.
- `shfmt` – enforces consistent formatting (used by `test/lint.sh`). Install via `go install mvdan.cc/sh/v3/cmd/shfmt@latest` (official upstream method) or your OS package manager.
- `gojq` (preferred) or `jq` – deterministic JSON tooling. The Go implementation behaves consistently across Linux/macOS/Windows and avoids known memory limits in the Windows `jq` build. Install with `go install github.com/itchyny/gojq/cmd/gojq@latest` and ensure `$HOME/go/bin` (or your `GOBIN`) is on `PATH`.

Without `shfmt`, the lint step fails immediately with "Required command \"shfmt\" not found in PATH".

## Running Tests

See [TESTING.md](TESTING.md) for detailed instructions on running the test suite.
