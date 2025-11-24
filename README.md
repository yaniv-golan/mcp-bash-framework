# mcp-bash

[![CI](https://img.shields.io/github/actions/workflow/status/yaniv-golan/mcp-bash-framework/ci.yml?branch=master&label=CI)](https://github.com/yaniv-golan/mcp-bash-framework/actions)
[![License](https://img.shields.io/github/license/yaniv-golan/mcp-bash-framework)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%3E%3D3.2-green.svg)](https://www.gnu.org/software/bash/)
[![MCP Protocol](https://img.shields.io/badge/MCP-2025--06--18-blue)](https://spec.modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#runtime-requirements)

**mcp-bash** is a professional-grade Model Context Protocol (MCP) server framework written in pure Bash. It allows you to instantly expose shell scripts, binaries, and system commands as secure, AI-ready tools.

- **Zero-Dependency Core**: Runs on standard Bash 3.2+ (macOS default) without heavy runtimes.
- **Production Ready**: Supports concurrency, timeouts, structured logging, and cancellation out of the box.
- **Developer Friendly**: Built-in scaffolding generators and clean separation between framework and your code.
- **Upgrade-Safe**: Framework and project are separate—upgrade the engine without touching your tools.

## Quick Start

### 1. Install the Framework

Clone or install `mcp-bash` to a permanent location (it's the engine, not your code):

```bash
git clone https://github.com/yaniv-golan/mcp-bash.git /opt/mcp-bash
```

### 2. Create Your Project

Your server code lives in a separate project directory:

```bash
mkdir ~/my-mcp-server
cd ~/my-mcp-server
export MCPBASH_PROJECT_ROOT=$(pwd)
```

### 3. Scaffold Your First Tool

```bash
/opt/mcp-bash/bin/mcp-bash scaffold tool check-disk
```

This creates `tools/check-disk/tool.sh` and `tools/check-disk/tool.meta.json` in your project. Edit the script to add your logic.

### 4. Configure Your MCP Client

Add to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/opt/mcp-bash/bin/mcp-bash",
      "env": {
        "MCPBASH_PROJECT_ROOT": "/Users/you/my-mcp-server"
      }
    }
  }
}
```

Restart Claude Desktop. Your tool is now available!

## Project Structure

```
Framework (Install Once)          Your Project (Version Control This)
/opt/mcp-bash/                    ~/my-mcp-server/
├── bin/mcp-bash                  ├── tools/
├── lib/                          │   └── check-disk/
├── handlers/                     │       ├── tool.sh
└── ...                           │       └── tool.meta.json
                                  ├── prompts/
                                  ├── resources/
                                  └── .registry/ (auto-generated)
```

See [**Project Structure Guide**](docs/PROJECT-STRUCTURE.md) for detailed layouts, Docker deployment, and multi-environment setups.

## Learn by Example

We provide a comprehensive suite of examples in the [`examples/`](examples/) directory to help you master the framework:

| Example | Concepts Covered |
|---------|------------------|
| [**00-hello-tool**](examples/00-hello-tool/) | Basic "Hello World" tool structure and metadata. |
| [**01-args-and-validation**](examples/01-args-and-validation/) | Handling JSON arguments and input validation. |
| [**02-logging-and-levels**](examples/02-logging-and-levels/) | Sending logs to the client and managing verbosity. |
| [**03-progress-and-cancellation**](examples/03-progress-and-cancellation/) | Long-running tasks, reporting progress, and handling user cancellation. |
| [**04-ffmpeg-studio**](examples/04-ffmpeg-studio/) | Real-world application: Video processing pipeline with media inspection. |

## Features at a Glance

- **Auto-Discovery**: Place scripts in your project's `tools/`, `resources/`, or `prompts/` directories—the framework finds them automatically.
- **Scaffolding**: Generate compliant tool, resource, and prompt templates (`mcp-bash scaffold <type> <name>`).
- **Stdio Transport**: Safe, standard-input/output communication model.
- **Framework/Project Separation**: Install the framework once, create unlimited projects.
- **Graceful Degradation**: Automatically detects available JSON tools (`gojq`, `jq`) or falls back to minimal mode if none are present.

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
| `MCPBASH_LOG_LEVEL` | `info` | Log level. Use `debug` to see path resolution and discovery traces. |
| `MCPBASH_DEBUG_PAYLOADS` | (unset) | Set to `true` to write full message payloads to `${TMPDIR}/mcpbash.state.*`. |
| `MCPBASH_FORCE_MINIMAL` | (unset) | Set to `true` to force "Minimal Mode" (Ping/Lifecycle only). |
| `MCPBASH_COMPAT_BATCHES` | (unset) | Set to `true` to enable legacy batch request support. |

## Requirements

### Runtime Requirements
*   **Bash**: version 3.2 or higher (standard on macOS, Linux, and WSL).
*   **JSON Processor**: `gojq` (recommended) or `jq`.
    *   *Note*: If no JSON tool is found, the server runs in "Minimal Mode" (Lifecycle & Ping only).

### Development Requirements
If you plan to contribute to the core framework, see [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions (linting, tests, etc).

---

## Documentation

### Getting Started
- [**Project Structure Guide**](docs/PROJECT-STRUCTURE.md) - Layouts, Docker deployment, multi-environment setups.
- [**Examples**](examples/) - Learn by example: hello-world, args, logging, progress, real-world video processing.

### Deep Dive
- [**Architecture Guide**](docs/ARCHITECTURE.md) - Internal architecture, lifecycle loop, concurrency model.
- [**Protocol Compliance**](SPEC-COMPLIANCE.md) - Detailed MCP protocol support breakdown.
- [**Security Policy**](docs/SECURITY.md) - Input validation and execution safety.
- [**Windows Support**](docs/WINDOWS.md) - Running on Git Bash/WSL.

### Scope and Goals
- Bash-only Model Context Protocol server verified on macOS Bash 3.2, Linux Bash ≥3.2, and experimental Git-Bash/WSL environments.
- Targets MCP protocol version `2025-06-18` while supporting negotiated downgrades.
- Transport support is limited to stdio; HTTP/SSE/OAuth transports remain out of scope.

### Protocol Version Compatibility
This server targets MCP protocol version `2025-06-18` (the current stable specification) and supports negotiated downgrades during `initialize`.

| Version | Status |
|---------|--------|
| `2025-06-18` | ✅ Fully supported (default) |
| `2025-03-26` | ✅ Supported |
| `2024-11-05` | ❌ **Not supported** |
