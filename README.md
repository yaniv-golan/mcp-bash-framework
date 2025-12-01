# mcp-bash

[![mcp-bash framework banner](assets/mcp-bash-framework.png)](assets/mcp-bash-framework.png)

[![CI](https://img.shields.io/github/actions/workflow/status/yaniv-golan/mcp-bash-framework/ci.yml?branch=main&label=CI)](https://github.com/yaniv-golan/mcp-bash-framework/actions)
[![License](https://img.shields.io/github/license/yaniv-golan/mcp-bash-framework)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%3E%3D3.2-green.svg)](https://www.gnu.org/software/bash/)
[![MCP Protocol](https://img.shields.io/badge/MCP-2025--06--18-blue)](https://spec.modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#runtime-requirements)
[![MCP Badge](https://lobehub.com/badge/mcp/yaniv-golan-mcp-bash-framework)](https://lobehub.com/mcp/yaniv-golan-mcp-bash-framework)

> **Repository:** [`mcp-bash-framework`](https://github.com/yaniv-golan/mcp-bash-framework) &nbsp;•&nbsp; **CLI/Binary:** `mcp-bash`

**mcp-bash** lets you expose Bash scripts and binaries directly to AI systems with zero ceremony.

- Runs on the Bash you already have. No runtimes, no dependency chain.
- Handles concurrency, timeouts and cancellation the way real systems need.
- You write the tools. The framework stays out of your way.

## Why this exists

Most MCP servers assume you’re willing to spin up heavyweight runtimes and frameworks just to wrap a few shell commands. That’s a lot of machinery for very little gain. mcp-bash takes the opposite approach: your shell is already your automation layer, and the framework is a thin, predictable bridge to MCP clients. If you’re comfortable running Bash in production, you shouldn’t need anything else to expose tools to AI systems.

## Design Principles

- Tools shouldn’t need another runtime to talk to AI.
- Everything must be inspectable. No magic.
- If it’s not needed in production, it isn’t in the framework.
- Your project stays yours. The framework upgrades cleanly.

## Quick Start

### 1. Install the Framework

```bash
git clone https://github.com/yaniv-golan/mcp-bash-framework.git ~/mcp-bash-framework
```

### 1.5 (Optional) Verify Your Install

Run the tiny hello example to confirm `mcp-bash` starts, registers a tool, and returns a response:

```bash
cd ~/mcp-bash-framework
npx @modelcontextprotocol/inspector --transport stdio -- ./examples/run 00-hello-tool
```

If you don't have Node/npx, you can also point any stdio MCP client at `./examples/run 00-hello-tool`.

### 2. Create Your Project

Your server code lives in a separate project directory:

```bash
mkdir ~/my-mcp-server
cd ~/my-mcp-server
export MCPBASH_PROJECT_ROOT=$(pwd)
```

### 3. Scaffold Your First Tool

```bash
~/mcp-bash-framework/bin/mcp-bash scaffold tool check-disk
```

This scaffolds `tools/check-disk/tool.sh` and `tools/check-disk/tool.meta.json` in your project. You write the logic.

### 4. Configure Your MCP Client

Set `MCPBASH_PROJECT_ROOT=/path/to/your/project` and point your MCP client at `/path/to/mcp-bash-framework/bin/mcp-bash`. See [Client Recipes](#client-recipes) for one-line configs for Claude Desktop/CLI/Code, Cursor, Windsurf, LibreChat, and OpenAI Agents SDK.

## Client Recipes

Every client works the same way: point it at the framework and tell it where your project lives:

1. Set `MCPBASH_PROJECT_ROOT=/path/to/your/project`.
2. Point it at your framework install (`/path/to/mcp-bash-framework/bin/mcp-bash`).

- **Claude Desktop**: Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows) and add:
  ```jsonc
  "mcpServers": {
    "mcp-bash": {
      "command": "/Users/you/mcp-bash-framework/bin/mcp-bash",
      "env": {"MCPBASH_PROJECT_ROOT": "/Users/you/my-mcp-server"}
    }
  }
  ```
- **Claude CLI/Claude Code**: Run once:
  ```bash
  claude mcp add --transport stdio mcp-bash \
    --env MCPBASH_PROJECT_ROOT="$HOME/my-mcp-server" \
    -- "$HOME/mcp-bash-framework/bin/mcp-bash"
  ```
- **Cursor**: Create `~/.cursor/mcp.json` (or `.cursor/mcp.json` in a project) with the same `mcpServers` JSON as above.
- **Windsurf (Cascade)**: Edit `~/.codeium/windsurf/mcp_config.json` via Settings → Advanced → Cascade, and add the same `mcpServers` entry.
- **LibreChat**: In `librechat.yaml` add:
  ```yaml
  mcpServers:
    mcp-bash:
      type: stdio
      command: /Users/you/mcp-bash-framework/bin/mcp-bash
      env:
        MCPBASH_PROJECT_ROOT: /Users/you/my-mcp-server
  ```
- **OpenAI Agents SDK (Python)**: In your code:
  ```python
  os.environ["MCPBASH_PROJECT_ROOT"] = "/Users/you/my-mcp-server"
  async with MCPServerStdio(name="mcp-bash",
                            params={"command": "/Users/you/mcp-bash-framework/bin/mcp-bash"}) as server:
      ...
  ```
- **Windows note**: Use Git Bash or WSL so `/usr/bin/env bash` and your paths resolve; adjust paths to `C:\Users\you\...` as needed.

## Project Structure

```
Framework (Install Once)               Your Project (Version Control This)
~/mcp-bash-framework/                  ~/my-mcp-server/
├── bin/mcp-bash                       ├── tools/
├── lib/                               │   └── check-disk/
├── handlers/                          │       ├── tool.sh
└── ...                                │       └── tool.meta.json
                                       ├── prompts/
                                       ├── resources/
                                       └── .registry/ (auto-generated)
```

The scaffolder creates nested directories per tool (e.g., `tools/check-disk/tool.sh`); the examples stay flat for readability. Both layouts are supported by discovery.

See [**Project Structure Guide**](docs/PROJECT-STRUCTURE.md) for detailed layouts, Docker deployment, and multi-environment setups.

## SDK Discovery

Every tool sources shared helpers from `sdk/tool-sdk.sh`. When `mcp-bash` launches a tool it exports `MCP_SDK=/path/to/framework/sdk`, so tool scripts can run:

```bash
source "${MCP_SDK}/tool-sdk.sh"
```

When you run the bundled examples or scaffolded scripts directly, they automatically fall back to locating `sdk/` relative to their location so you can prototype without additional setup. If you copy a tool out of this repository (or build your own project layout), set `MCP_SDK` before executing the script:

```bash
export MCP_SDK=/path/to/mcp-bash-framework/sdk
```

If the SDK can’t be resolved, the script exits with a clear error.

## Roots (scoping filesystem access)
- If the client supports MCP Roots, mcp-bash requests them after `initialized` and exposes them to tools via env (`MCP_ROOTS_JSON`, `MCP_ROOTS_PATHS`, `MCP_ROOTS_COUNT`) and SDK helpers (`mcp_roots_list`, `mcp_roots_count`, `mcp_roots_contains`).
- If the client does not provide roots or times out, you can supply them via `MCPBASH_ROOTS="/path/one:/path/two"` or an optional `config/roots.json` in your project. Paths are normalized and enforced consistently.

## Completions

Completions are registered via `server.d/register.sh` (they are not auto-discovered). A minimal registration snippet:

```bash
# server.d/register.sh
mcp_completion_manual_begin
mcp_completion_register_manual '{"name":"example.completion","path":"completions/example.sh","timeoutSecs":5}'
mcp_completion_manual_finalize
```

Paths are resolved relative to `MCPBASH_PROJECT_ROOT`, and registry refreshes pick them up automatically.

## Learn by Example

The [`examples/`](examples/) directory shows common patterns end-to-end:

| Example | Concepts Covered |
|---------|------------------|
| [**00-hello-tool**](examples/00-hello-tool/) | Basic "Hello World" tool structure and metadata. |
| [**01-args-and-validation**](examples/01-args-and-validation/) | Handling JSON arguments and input validation. |
| [**02-logging-and-levels**](examples/02-logging-and-levels/) | Sending logs to the client and managing verbosity. |
| [**03-progress-and-cancellation**](examples/03-progress-and-cancellation/) | Long-running tasks, reporting progress, and handling user cancellation. |
| [**04-resources-basics**](examples/04-resources-basics/) | Listing and reading resources via the built-in file provider. |
| [**05-prompts-basics**](examples/05-prompts-basics/) | Discovering and rendering prompt templates. |
| [**06-manual-registration**](examples/06-manual-registration/) | Manual registry overrides, live progress streaming, and a custom resource provider. |
| [**07-elicitation**](examples/07-elicitation/) | Client-driven elicitation prompts that gate tool execution. |
| [**08-roots-basics**](examples/08-roots-basics/) | MCP roots scoping for tools; allows/denies file reads based on configured roots. |
| [**Advanced: ffmpeg-studio**](examples/advanced/ffmpeg-studio/) | Real-world application: video processing pipeline with media inspection (optional, heavy deps). |

## Features at a Glance

- **Auto-Discovery**: Place scripts in your project's `tools/`, `resources/`, or `prompts/` directories—the framework finds them automatically.
- **Scaffolding**: Generate compliant tool, resource, and prompt templates (`mcp-bash scaffold <type> <name>`).
- **Stdio Transport**: Standard input/output. No custom daemons or sidecars.
- **Framework/Project Separation**: Install the framework once, create unlimited projects.
- **Graceful Degradation**: Automatically detects available JSON tools (`gojq`, `jq`) or falls back to minimal mode if none are present.
- **Progress Streaming**: Emits progress and log notifications; set `MCPBASH_ENABLE_LIVE_PROGRESS=true` to stream them during execution.
- **Debug Mode**: Run `mcp-bash debug` to capture all JSON-RPC messages for analysis. See [docs/DEBUGGING.md](docs/DEBUGGING.md).

## Configuration

### Required Configuration

| Variable | Description |
|----------|-------------|
| `MCPBASH_PROJECT_ROOT` | **Required.** Path to your project directory containing `tools/`, `prompts/`, `resources/`. |

### Optional Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MCPBASH_TOOLS_DIR` | `$MCPBASH_PROJECT_ROOT/tools` | Override tools location. |
| `MCPBASH_RESOURCES_DIR` | `$MCPBASH_PROJECT_ROOT/resources` | Override resources location. |
| `MCPBASH_PROMPTS_DIR` | `$MCPBASH_PROJECT_ROOT/prompts` | Override prompts location. |
| `MCPBASH_SERVER_DIR` | `$MCPBASH_PROJECT_ROOT/server.d` | Override server hooks location. |
| `MCPBASH_REGISTRY_DIR` | `$MCPBASH_PROJECT_ROOT/.registry` | Override registry cache location. |
| `MCPBASH_REGISTRY_MAX_BYTES` | `104857600` | Maximum serialized registry size (bytes) before discovery fails fast. |
| `MCPBASH_MAX_CONCURRENT_REQUESTS` | `16` | Cap concurrent worker slots. |
| `MCPBASH_LOG_LEVEL` | `info` | Log level. Falls back to `MCPBASH_LOG_LEVEL_DEFAULT` when unset; use `debug` to see path resolution and discovery traces. |
| `MCPBASH_LOG_VERBOSE` | (unset) | Set to `true` to include full paths and manual-registration script output in logs. **Security note**: exposes file paths and usernames; use only in trusted environments. See [docs/LOGGING.md](docs/LOGGING.md). |
| `MCPBASH_RESOURCES_POLL_INTERVAL_SECS` | `2` | Background polling interval for resource subscriptions; set to `0` to disable. |
| `MCPBASH_ENABLE_LIVE_PROGRESS` | `false` | Stream progress/log notifications as they are produced instead of after handler completion. |
| `MCPBASH_PROGRESS_FLUSH_INTERVAL` | `0.5` | Flush interval (seconds) for live progress/log streaming when enabled. |
| `MCPBASH_DEBUG_PAYLOADS` | (unset) | Set to `true` to write full message payloads to `${TMPDIR}/mcpbash.state.*`. See [docs/DEBUGGING.md](docs/DEBUGGING.md). |
| `MCPBASH_PRESERVE_STATE` | (unset) | Set to `true` to keep state directory after server exit (useful with `MCPBASH_DEBUG_PAYLOADS`). |
| `MCPBASH_FORCE_MINIMAL` | (unset) | Set to `true` to force "Minimal Mode" (Lifecycle, ping, and logging only). |
| `MCPBASH_ENV_PAYLOAD_THRESHOLD` | `65536` | Spill args/metadata to temp files once payloads exceed this many bytes. |
| `MCPBASH_MAX_TOOL_STDERR_SIZE` | `$MCPBASH_MAX_TOOL_OUTPUT_SIZE` | Maximum stderr captured from a tool before failing the call. |
| `MCPBASH_MAX_RESOURCE_BYTES` | `$MCPBASH_MAX_TOOL_OUTPUT_SIZE` | Maximum resource payload size accepted before failing fast. |
| `MCPBASH_CORRUPTION_WINDOW` | `60` | Time window (seconds) for tracking stdout corruption events. |
| `MCPBASH_CORRUPTION_THRESHOLD` | `3` | Number of stdout corruption events allowed within the window before exit. |
| `MCPBASH_TOOL_ENV_MODE` | `minimal` | Tool environment isolation: `minimal` (default), `inherit`, or `allowlist`. |
| `MCPBASH_TOOL_ENV_ALLOWLIST` | (unset) | Extra env var names permitted when `MCPBASH_TOOL_ENV_MODE=allowlist`. |
| `MCPBASH_REGISTRY_REFRESH_PATH` | (unset) | Optional subpath to limit `registry refresh` scanning scope (defaults to full tools/resources/prompts trees). |
| `MCPBASH_COMPAT_BATCHES` | (unset) | Set to `true` to enable legacy batch request support. |

### Tool SDK environment
- `MCPBASH_JSON_TOOL` and `MCPBASH_JSON_TOOL_BIN` point to the detected JSON processor (`gojq`/`jq`) and are injected into tool processes when available.
- `MCPBASH_MODE` is `full` when JSON tooling is present and `minimal` otherwise; SDK helpers warn and downgrade behaviour when running in minimal mode.
- `MCPBASH_TOOL_ENV_MODE` controls isolation for tool processes (`minimal`, `inherit`, or `allowlist`), but MCPBASH/MCP-prefixed variables (including JSON tool hints) are always propagated.

### Capability Modes

| Mode | Supported surface | Limitations / when it applies |
|------|-------------------|--------------------------------|
| Full | Lifecycle, ping, logging/setLevel, tools/resources/prompts (list, call/read/subscribe), completion, pagination, `listChanged` notifications | Requires `jq`/`gojq` available; default mode. |
| Minimal | Lifecycle, ping, logging/setLevel | Tools/resources/prompts/completion are disabled and registry notifications are suppressed. Activated when no JSON tool is found or `MCPBASH_FORCE_MINIMAL=true`. |

### Registry Maintenance
- Auto-refresh: registries re-scan on TTL expiry (default 5s) and use lightweight file-list hashing to skip rebuilds when nothing changed.
- Manual refresh: `bin/mcp-bash registry refresh [--project-root DIR] [--no-notify] [--quiet] [--filter PATH]` rebuilds `.registry/*.json` and returns a status JSON. In minimal mode the command is skipped gracefully.

## Requirements

### Runtime Requirements
*   **Bash**: version 3.2 or higher (standard on macOS, Linux, and WSL).
*   **JSON Processor**: `gojq` (recommended) or `jq`.
    *   *Note*: If no JSON tool is found, the server runs in "Minimal Mode" (Lifecycle & Ping only).

### Development Requirements
If you plan to contribute to the core framework, see [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions (linting, tests, etc).

### Testing (quick start)
From the repo root:
```bash
./test/lint.sh
./test/unit/run.sh
./test/integration/run.sh
# Optional:
# ./test/compatibility/run.sh
# ./test/stress/run.sh
```

### Windows Notes
- Signals from the client may not reliably terminate subprocesses on Git Bash; prefer explicit `shutdown`/`exit` and short tool timeouts.
- Paths are normalized to `/c/...` style; avoid mixing Windows- and POSIX-style roots in the same project.
- Large payloads can be slower under MSYS; keep registry TTLs reasonable.
See [docs/WINDOWS.md](docs/WINDOWS.md) for full guidance and workarounds.

---

## Documentation

### Getting Started
- [**Project Structure Guide**](docs/PROJECT-STRUCTURE.md) - Layouts, Docker deployment, multi-environment setups.
- [**Examples**](examples/) - Learn by example: hello-world, args, logging, progress, real-world video processing.

### Deep Dive
- [**Architecture Guide**](docs/ARCHITECTURE.md) - Internal architecture, lifecycle loop, concurrency model.
- [**Protocol Compliance**](SPEC-COMPLIANCE.md) - Detailed MCP protocol support breakdown.
- [**Performance Guide**](docs/PERFORMANCE.md) - Tuning concurrency, timeouts, and registry scans.
- [**Security Policy**](docs/SECURITY.md) - Input validation and execution safety.
- [**Minimal Mode**](docs/MINIMAL-MODE.md) - Behavior when jq/gojq is missing or minimal mode is forced.
- [**Changelog**](CHANGELOG.md) - Notable changes between releases.
- [**Windows Support**](docs/WINDOWS.md) - Running on Git Bash/WSL.
- [**Remote Connectivity**](docs/REMOTE.md) - Exposing mcp-bash over HTTP/SSE via external gateways.

### Scope and Goals
- Bash-only Model Context Protocol server verified on macOS Bash 3.2, Linux Bash ≥3.2, and experimental Git-Bash/WSL environments.
- Targets MCP protocol version `2025-06-18` while supporting negotiated downgrades.
- Transport support is limited to stdio; HTTP/SSE/OAuth transports remain out of scope (see [Remote Connectivity](docs/REMOTE.md) for gateway options).

### Protocol Version Compatibility
This server targets MCP protocol version `2025-06-18` (the current stable specification) and supports negotiated downgrades during `initialize`.

| Version | Status |
|---------|--------|
| `2025-06-18` | ✅ Fully supported (default) |
| `2025-03-26` | ✅ Supported (downgrade) |
| `2024-11-05` | ✅ Supported (downgrade) |
| `2024-10-07` | ❌ **Not supported** |

Unsupported versions receive an `initialize` error payload: `{"code":-32602,"message":"Unsupported protocol version"}`.

## FAQ

### Why is the repository named `mcp-bash-framework` but the CLI is `mcp-bash`?

The repository name `mcp-bash-framework` reflects what this project is: a framework you install once and use to create multiple MCP server projects. The CLI/binary is named `mcp-bash` because that's what you invoke—short and memorable. The name `mcp-bash` was already taken on GitHub, so we chose `mcp-bash-framework` to accurately describe the architecture while avoiding namespace conflicts.

---

mcp-bash is intentionally small. It gives you control, clarity, and a predictable surface for AI systems. **Build tools, not infrastructure.**
