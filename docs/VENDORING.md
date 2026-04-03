# Vendoring the mcp-bash Runtime

Vendoring means copying the mcp-bash runtime into your project's git repository so that no system-wide installation is required at runtime. The `mcp-bash vendor` command does this in one step.

## When to vendor vs. bundle vs. system install

| Scenario | Recommended approach |
|----------|---------------------|
| Dev team using a shared repo, CI/CD, or non-MCPB MCP clients | **`mcp-bash vendor`** — runtime lives in repo |
| Distributing to end users via Claude Desktop or another MCPB-compatible client | **`mcp-bash bundle`** — produces a `.mcpb` archive |
| Single developer, full install on their machine | **System install** — `install.sh`, no vendoring needed |

Key distinction: MCPB bundles require the host client to support the MCPB format (Claude Desktop, etc.). Vendoring works with any MCP client that can invoke a shell script.

## Quick start

```bash
# From inside your project directory
mcp-bash vendor
```

This creates `.mcp-bash/` and a `run-server.sh` wrapper in the current directory (or `MCPBASH_PROJECT_ROOT` if set), and writes a `vendor.json` lockfile:

```
my-server/
├── .mcp-bash/           # embedded runtime
│   ├── bin/mcp-bash
│   ├── handlers/
│   ├── lib/
│   ├── providers/
│   ├── sdk/
│   ├── VERSION
│   └── vendor.json      # integrity lockfile
├── run-server.sh        # generated entry point — commit this too
├── tools/
├── resources/
└── server.d/
```

Commit both the runtime tree and the wrapper:

```bash
git add .mcp-bash/ run-server.sh
git commit -m "vendor mcp-bash runtime"
```

## Configuring your MCP client

`mcp-bash vendor` generates a `run-server.sh` wrapper alongside `.mcp-bash/`. This wrapper sources your login shell profiles for GUI app compatibility (pyenv, nvm, rbenv, etc.) and then invokes `.mcp-bash/bin/mcp-bash` by relative path — no system install needed.

Use it as the entry point:

```json
{
  "command": "/path/to/my-server/run-server.sh",
  "env": {
    "MCPBASH_TOOL_ALLOWLIST": "*"
  }
}
```

The wrapper sets `MCPBASH_PROJECT_ROOT` automatically to its own directory, so you do not need to pass it explicitly.

If you prefer to skip the wrapper and point directly at the binary:

```json
{
  "command": "/path/to/my-server/.mcp-bash/bin/mcp-bash",
  "env": {
    "MCPBASH_PROJECT_ROOT": "/path/to/my-server",
    "MCPBASH_TOOL_ALLOWLIST": "*"
  }
}
```

Note: `mcp-bash config --wrapper` generates a **different** style of wrapper that discovers a **system-installed** `mcp-bash` binary from PATH. Use that for non-vendored setups where the framework is installed globally.

## What gets vendored

The vendored tree is the same minimal subset embedded in MCPB bundles:

| Path | Purpose |
|------|---------|
| `bin/mcp-bash` | Main entry point |
| `lib/*.sh` | Runtime library modules |
| `lib/cli/common.sh`, `lib/cli/health.sh` | CLI helpers |
| `handlers/*.sh` | MCP protocol handlers |
| `sdk/tool-sdk.sh` | Tool author SDK |
| `providers/*.sh` | Built-in resource providers (file, https, git, echo, ui) |
| `VERSION` | Framework version |
| `vendor.json` | Integrity lockfile |
| `run-server.sh` | Generated entry-point wrapper (written next to `.mcp-bash/`) |

The full repository (tests, docs, examples, scaffold, scripts) is **not** included.

## The vendor.json lockfile

After each vendor run, `vendor.json` is written inside `.mcp-bash/`:

```json
{
  "version": "1.1.5",
  "sha256": "a1b2c3d4...64hex",
  "vendored_from": "/home/you/.local/share/mcp-bash",
  "vendored_at": "2026-04-03T12:00:00Z"
}
```

| Field | Description |
|-------|-------------|
| `version` | Framework version (`VERSION` file) |
| `sha256` | Merkle-style digest of all vendored files; used by `--verify` |
| `vendored_from` | Source install path (informational) |
| `vendored_at` | ISO-8601 timestamp of the vendor run |

## Verifying integrity

Re-hash the vendored files and compare against `vendor.json`:

```bash
mcp-bash vendor --verify
```

Exits 0 if the files match, 1 if anything has been modified or is missing.

### CI integration

Add a CI step to detect accidental edits to vendored files:

```yaml
# GitHub Actions example
- name: Verify vendored runtime
  run: mcp-bash vendor --verify
```

Or as a pre-commit hook (`.git/hooks/pre-commit`):

```bash
#!/usr/bin/env bash
if [ -d .mcp-bash ]; then
  mcp-bash vendor --verify || { echo "Vendored runtime modified; run 'mcp-bash vendor --upgrade'"; exit 1; }
fi
```

**Important:** Always run `vendor --verify` from a **system-installed** `mcp-bash` (in your PATH), not from the vendored copy at `.mcp-bash/bin/mcp-bash`. A compromised vendored binary could lie about its own integrity. CI runners and pre-commit hooks naturally use the system install.

### Automatic updates with Renovate

[Renovate](https://docs.renovatebot.com/) can open automatic PRs whenever a new mcp-bash release is published. Add one line to your `renovate.json`:

```json
{ "extends": ["github>yaniv-golan/mcp-bash-framework//renovate-preset"] }
```

When a new version is released, Renovate opens a PR that bumps the `"version"` field in `.mcp-bash/vendor.json`. Merging the PR does **not** automatically update the embedded files — it signals that an upgrade is available. After merging, run:

```bash
mcp-bash vendor --upgrade
git add .mcp-bash/
git commit -m "upgrade mcp-bash runtime to $(cat .mcp-bash/VERSION)"
```

This two-step approach keeps the PR review lightweight (just a version string diff) and lets you audit the actual file changes in a separate commit.

If you do not use Renovate, `mcp-bash doctor` will warn when a newer framework version is available.

### Security model and limitations

`vendor --verify` protects against **accidental modification** (someone hand-edits a `.sh` file in `.mcp-bash/`, a merge silently changes vendored content) and against **one-file tampering** (an attacker modifies a script but forgets to update `vendor.json`).

It does **not** protect against a determined attacker who has write access to the repository. An attacker who can modify `.mcp-bash/` can also replace `vendor.json` with a hash matching their tampered files. This is inherent to any lockfile-only integrity model — the same limitation applies to `go.sum`, `package-lock.json`, etc.

**Recommended defenses:**
- Require code review on all PRs touching `.mcp-bash/` — treat vendored runtime changes like dependency upgrades
- Use GitHub's `CODEOWNERS` to gate `.mcp-bash/` behind a security-aware reviewer
- Verify source authenticity *before* vendoring (see below)

### Source authenticity

`vendor --verify` checks that vendored files match the hash recorded at vendor time — it detects post-vendor drift. To verify the *source* of the framework install before vendoring, use the official release checksums published alongside each GitHub release:

```bash
version=v1.2.0
curl -fsSLO "https://github.com/yaniv-golan/mcp-bash-framework/releases/download/${version}/mcp-bash-${version}.tar.gz"
curl -fsSLO "https://github.com/yaniv-golan/mcp-bash-framework/releases/download/${version}/SHA256SUMS"
sha256sum -c SHA256SUMS
bash install.sh --archive "mcp-bash-${version}.tar.gz" --version "${version}"
# Then vendor from the verified install
mcp-bash vendor
```

## Upgrading

Re-vendor from the currently installed framework version:

```bash
mcp-bash vendor --upgrade
```

This replaces the existing `.mcp-bash/` tree and updates `vendor.json`. If you have previously verified and committed a vendored copy, review the diff before committing the upgrade:

```bash
mcp-bash vendor --upgrade
git diff .mcp-bash/
git add .mcp-bash/
git commit -m "upgrade mcp-bash runtime to $(cat .mcp-bash/VERSION)"
```

## Command reference

```
mcp-bash vendor [options]

Options:
  --output DIR   Target directory (default: MCPBASH_PROJECT_ROOT or current directory)
  --upgrade      Re-vendor from current install, replacing existing files without prompting
  --verify       Verify vendor.json hash matches files on disk; exit 0=ok 1=fail
  --dry-run      Show what would be copied without doing it
  --verbose      Show each file as it is copied
  --help, -h     Show help
```

## See also

- [MCPB Bundles](MCPB.md) — one-click distribution via Claude Desktop and MCP Registry
- [Project Structure](PROJECT-STRUCTURE.md) — server directory layout
- [Security Considerations](SECURITY.md) — supply chain and integrity guidance
