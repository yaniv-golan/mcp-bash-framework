# AGENTS.md

## Project Overview

`mcp-bash-framework` is a Bash-first framework for building MCP (Model Context Protocol) servers over stdio.

- Primary language: Bash (Bash 3.2+)
- Runtime focus: minimal dependencies, shell-native workflows
- Core capabilities are implemented across tools, resources, prompts, roots, progress, cancellation, and related protocol features
- Main CLI: `mcp-bash`

This repository combines:
- framework/runtime code
- scaffolding templates
- example MCP servers
- multi-layer testing infrastructure
- extensive documentation

## Repository Structure

Validated top-level structure:

- `bin/` — CLI entrypoints and executable command surface
- `lib/` — shared framework/core Bash libraries
- `handlers/` — protocol request/notification handlers
- `hooks/` — hook implementations and hook-related logic
- `providers/` — provider integrations (including project-level provider behavior)
- `sdk/` — SDK helpers sourced by generated and user tools
- `bootstrap/` — bootstrap/runtime startup components
- `server.d/` — server metadata/config conventions
- `tools/` — built-in or framework tool assets
- `scaffold/` — templates and scaffolding content
- `examples/` — numbered learning examples (`00-hello-tool` through `15-cli-wrapper`, plus `advanced/`)
- `docs/` — focused documentation (security, environment reference, remote, etc.)
- `test/` — lint, smoke, unit (`*.bats`), integration (`test_*.sh`), compatibility, stress, benchmark
- `scripts/` — repo automation scripts (including README rendering)
- `assets/` — images and static documentation assets

Key root docs/config files:
- `README.md` (generated)
- `README.md.in` (source template)
- `CONTRIBUTING.md`
- `TESTING.md`
- `SPEC-COMPLIANCE.md`
- `SECURITY.md`
- `package.json`

## Development Guidelines

### 1) Keep README generation flow intact

`README.md` is generated from `README.md.in`.

- Edit: `README.md.in`
- Render/update: `bash scripts/render-readme.sh`
- Validation mode: `bash scripts/render-readme.sh --check`

Do not hand-edit `README.md` directly when content originates from template placeholders.

### 2) Follow shell quality expectations

From contribution guidance:

- Prefer robust shell patterns (`set -euo pipefail`)
- Keep functions focused and small
- Run linting before PRs

Local prerequisites used by lint/tests include:
- `shellcheck`
- `shfmt`
- `jq` or `gojq`
- `bats` (+ bats support libraries via `npm install`)

### 3) Use documented test entrypoints

Primary scripts:

- Lint: `./test/lint.sh`
- Smoke: `./test/smoke.sh`
- Unit: `./test/unit/run.sh`
- Integration: `./test/integration/run.sh`
- Examples: `./test/examples/run.sh`
- Compatibility: `./test/compatibility/run.sh`
- Stress: `./test/stress/run.sh`
- Full suite orchestrator: `./test/run-all.sh`

For CI-parity debugging, `CONTRIBUTING.md` recommends setting:

```bash
MCPBASH_CI_MODE=1
```

### 4) Respect project workflow conventions

- Open short-lived branches and PR against `main`
- Include concise test evidence in PR descriptions
- Use pre-commit hooks where possible (`pre-commit install`)

## Code Patterns

## Language and file conventions

- Bash-heavy codebase with strict lint/format checks
- Integration tests follow `test/integration/test_*.sh`
- Unit tests are Bats files under `test/unit/*.bats`
- Examples are progression-based and numbered (`examples/00-*` … `examples/15-*`)

## Runtime and policy patterns

- Security defaults are explicit (for example, tool allowlist expectations and hooks gating are emphasized in docs)
- JSON tooling is first-class (`jq`/`gojq` detection and configuration)
- CLI and protocol behavior are validated through end-to-end shell harnesses

## Documentation patterns

- Root README provides onboarding and deep links
- Topic-specific docs live under `docs/`
- Testing behavior and env knobs are centralized in `TESTING.md`

## Quality Standards

Before opening a PR, at minimum:

1. Run lint:

```bash
./test/lint.sh
```

2. Run relevant tests for your scope (at least unit + impacted integration paths):

```bash
./test/unit/run.sh
./test/integration/run.sh
```

3. If README template changed, re-render and ensure consistency:

```bash
bash scripts/render-readme.sh
bash scripts/render-readme.sh --check
```

4. If changing examples or scaffolding behavior, include:

```bash
./test/examples/run.sh
```

Use `./test/run-all.sh` for broad validation when touching multiple subsystems.

## Critical Rules

- Do not bypass shell formatting/linting standards (`shfmt` + `shellcheck` via `./test/lint.sh`).
- Do not edit generated README content without updating `README.md.in` and rendering.
- Do not introduce undocumented commands in docs—keep commands aligned with scripts and docs present in repo.
- Do not assume CI-only behavior locally; use documented env flags (`MCPBASH_CI_MODE`, verbosity/timeouts/filter knobs in `TESTING.md`).
- Keep security defaults and policy controls explicit when modifying execution, hooks, or allowlist-sensitive flows.

## Common Tasks

### Install test dependencies

```bash
npm install
```

### Run lint and core tests

```bash
./test/lint.sh
./test/unit/run.sh
./test/integration/run.sh
```

### Run everything (with selective skips available)

```bash
./test/run-all.sh
```

### Re-generate README after template/version edits

```bash
bash scripts/render-readme.sh
```

### Verify README is up to date (CI-style check)

```bash
bash scripts/render-readme.sh --check
```

### Quick smoke pass

```bash
./test/smoke.sh
```

## Reference Examples

Representative examples validated in `examples/`:

- `examples/00-hello-tool/` — minimal tool baseline
- `examples/01-args-and-validation/` — arguments and validation patterns
- `examples/05-resources-basics/` — resource fundamentals
- `examples/07-prompts-basics/` — prompt definitions and usage
- `examples/10-completions/` — completion features
- `examples/13-ui-basics/` and `examples/14-ui-templates/` — UI-related patterns
- `examples/15-cli-wrapper/` — CLI wrapper pattern
- `examples/advanced/` — more complex end-to-end examples

Representative tests validated:

- Unit runner: `test/unit/run.sh`
- Integration runner: `test/integration/run.sh`
- Integration naming pattern: `test/integration/test_*.sh`
- Example suite: `test/examples/run.sh`
- Full orchestrator: `test/run-all.sh`

## Additional Resources

Core docs to consult before non-trivial changes:

- `README.md` / `README.md.in` — onboarding + canonical commands
- `CONTRIBUTING.md` — workflow, lint/tool prerequisites, release guidance
- `TESTING.md` — suites, filters, env toggles, test behavior
- `SPEC-COMPLIANCE.md` — MCP feature/support matrix
- `docs/ENV_REFERENCE.md` — environment variable reference
- `docs/REMOTE.md` — remote connectivity and health/token notes
- `SECURITY.md` and `docs/SECURITY.md` — security reporting and policy context

---

If this file and other docs diverge, treat repository scripts and source docs (`README.md.in`, `TESTING.md`, `CONTRIBUTING.md`) as authoritative and update this file accordingly.
