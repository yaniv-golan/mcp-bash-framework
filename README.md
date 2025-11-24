# mcp-bash

[![CI](https://img.shields.io/github/actions/workflow/status/yaniv-golan/mcp-bash-framework/ci.yml?branch=master&label=CI)](https://github.com/yaniv-golan/mcp-bash-framework/actions)
[![License](https://img.shields.io/github/license/yaniv-golan/mcp-bash-framework)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%3E%3D3.2-green.svg)](https://www.gnu.org/software/bash/)
[![MCP Protocol](https://img.shields.io/badge/MCP-2025--06--18-blue)](https://spec.modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#runtime-requirements)

**mcp-bash** is a professional-grade Model Context Protocol (MCP) server implementation written in pure Bash. It allows you to instantly expose shell scripts, binaries, and system commands as secure, AI-ready tools.

- **Zero-Dependency Core**: Runs on standard Bash 3.2+ (macOS default) without heavy runtimes.
- **Production Ready**: Supports concurrency, timeouts, structured logging, and cancellation out of the box.
- **Developer Friendly**: built-in scaffolding generators to write code for you.

## Quick Start

### 1. Configure Your Client
To use mcp-bash with Claude Desktop, add the following to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "bash": {
      "command": "/absolute/path/to/mcp-bash/bin/mcp-bash",
      "args": []
    }
  }
}
```

### 2. Create Your First Tool
Don't write boilerplate. Use the scaffold command:

```bash
# Generate a new tool named "check-disk"
./bin/mcp-bash scaffold tool check-disk
```

This creates `tools/check-disk/` with a ready-to-run script and metadata. Edit `tools/check-disk/tool.sh` to add your logic, and it will automatically appear in your MCP client on the next restart.

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

- **Auto-Discovery**: Simply place scripts in `tools/`, `resources/`, or `prompts/`, and the server finds them.
- **Scaffolding**: Generates compliant tool, resource, and prompt templates (`bin/mcp-bash scaffold <type> <name>`).
- **Stdio Transport**: Safe, standard-input/output communication model.
- **Graceful Degradation**: Automatically detects available JSON tools (`gojq`, `jq`) or falls back to a minimal mode if none are present.

## Configuration

The server supports several environment variables to control behavior and debugging:

| Variable | Default | Description |
|----------|---------|-------------|
| `MCPBASH_LOG_LEVEL` | `info` | Sets the initial log level. Use `debug` to see discovery/subscription traces. |
| `MCPBASH_DEBUG_PAYLOADS` | (unset) | Set to `true` to write full message payloads to `${TMPDIR}/mcpbash.state.*`. |
| `MCPBASH_FORCE_MINIMAL` | (unset) | Set to `true` to force "Minimal Mode" (Ping/Lifecycle only) even if JSON tools are present. |
| `MCPBASH_COMPAT_BATCHES` | (unset) | Set to `true` to enable legacy batch request support (decomposes batches into serial requests). |

## Requirements

### Runtime Requirements
*   **Bash**: version 3.2 or higher (standard on macOS, Linux, and WSL).
*   **JSON Processor**: `gojq` (recommended) or `jq`.
    *   *Note*: If no JSON tool is found, the server runs in "Minimal Mode" (Lifecycle & Ping only).

### Development Requirements
If you plan to contribute to the core framework, see [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions (linting, tests, etc).

---

## Architecture & Deep Dive

For detailed documentation on the internal architecture, lifecycle loop, and concurrency model, please see:

- [**Architecture Guide**](docs/ARCHITECTURE.md) - Deep dive into how the server works internally.
- [**Protocol Compliance**](SPEC-COMPLIANCE.md) - Detailed breakdown of MCP protocol support.
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
