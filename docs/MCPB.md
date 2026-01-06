# MCPB Bundles

MCPB (MCP Bundles) is the official distribution format for MCP servers, enabling one-click installation in MCPB-compatible clients such as Claude Desktop.

## Quick Start

```bash
# Create a bundle from your project
mcp-bash bundle

# Output: my-server-1.0.0.mcpb
```

To install, double-click the `.mcpb` file or drag it to Claude Desktop.

## Bundle Configuration

Create `mcpb.conf` in your project root to customize the bundle:

```bash
# mcpb.conf - Bundle configuration

# Server metadata (overrides server.meta.json)
MCPB_NAME="my-server"
MCPB_VERSION="1.0.0"
MCPB_DESCRIPTION="My MCP server built with mcp-bash"

# Long description (markdown file for extension stores)
MCPB_LONG_DESCRIPTION_FILE="docs/DESCRIPTION.md"

# Author information (recommended for registry listing)
MCPB_AUTHOR_NAME="Your Name"
MCPB_AUTHOR_EMAIL="you@example.com"
MCPB_AUTHOR_URL="https://github.com/you"

# Repository URL
MCPB_REPOSITORY="https://github.com/you/my-server"
```

If `mcpb.conf` is not present, values are resolved from:
1. Command-line options (`--name`, `--version`)
2. `server.d/server.meta.json` (including `long_description_file`)
3. `VERSION` file
4. Git config (for author info)
5. Git remote (for repository URL)

## Command-Line Options

```bash
mcp-bash bundle [options]

Options:
  --output DIR       Output directory (default: current directory)
  --name NAME        Bundle name (default: from server.meta.json)
  --version VERSION  Bundle version (default: from VERSION file)
  --platform PLAT    Target platform: darwin, linux, win32, or all (default: all)
  --include-gojq     Bundle gojq binary for systems without jq
  --validate         Validate bundle structure without creating
  --verbose          Show detailed progress
  --help, -h         Show help
```

### Examples

```bash
# Create bundle with defaults
mcp-bash bundle

# Output to specific directory
mcp-bash bundle --output ./dist

# Validate without creating
mcp-bash bundle --validate

# Override version
mcp-bash bundle --version 2.0.0

# Create macOS-only bundle
mcp-bash bundle --platform darwin

# Include gojq for systems without jq
mcp-bash bundle --include-gojq
```

## Bundle Structure

The generated `.mcpb` file is a ZIP archive with this structure:

```
my-server-1.0.0.mcpb
├── manifest.json           # MCPB manifest (v0.3)
├── icon.png                # Optional: server icon
└── server/
    ├── run-server.sh       # Entry point wrapper
    ├── .mcp-bash/          # Embedded framework
    │   ├── bin/mcp-bash
    │   ├── lib/
    │   ├── sdk/
    │   └── handlers/
    ├── tools/
    ├── resources/
    ├── prompts/
    ├── completions/
    ├── lib/                # Optional: project shared libraries
    ├── providers/          # Optional: custom resource providers
    └── server.d/
```

## Manifest Format

The generated `manifest.json` follows MCPB specification v0.3:

```json
{
  "manifest_version": "0.3",
  "name": "my-server",
  "version": "1.0.0",
  "display_name": "My Server",
  "description": "Description of your server",
  "long_description": "# My Server\n\nDetailed markdown description...",
  "author": {
    "name": "Your Name",
    "email": "you@example.com",
    "url": "https://github.com/you"
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/you/my-server"
  },
  "tools_generated": true,
  "prompts_generated": true,
  "server": {
    "type": "binary",
    "entry_point": "server/run-server.sh",
    "mcp_config": {
      "command": "${__dirname}/server/run-server.sh",
      "args": [],
      "env": {
        "MCPBASH_PROJECT_ROOT": "${__dirname}/server",
        "MCPBASH_TOOL_ALLOWLIST": "*"
      }
    }
  },
  "compatibility": {
    "platforms": ["darwin", "linux", "win32"]
  }
}
```

**Required fields:** `manifest_version`, `name`, `version`, `description`, `author`, `server`

**Optional fields:**
- `long_description` - markdown content for extension stores (via `long_description_file`)
- `tools_generated` - automatically set to `true` when `tools/` directory has content
- `prompts_generated` - automatically set to `true` when `prompts/` directory has content

**Note:** The `author` field is required by the MCPB spec. If not provided via `mcpb.conf` or `server.meta.json`, the bundler falls back to git config.

**Note:** The `*_generated` flags indicate that tools/prompts are discovered dynamically at runtime. Clients should query `tools/list` and `prompts/list` to discover available capabilities.

## Platform Compatibility

Bundles are compatible with:
- **macOS** (darwin): Native support
- **Linux**: Native support
- **Windows** (win32): Requires bash (Git Bash, WSL, or MSYS2)

On Windows, ensure one of the following is installed and in PATH:
- **Git for Windows** (includes Git Bash) - recommended
- **WSL** (Windows Subsystem for Linux)
- **MSYS2** or **Cygwin**

The wrapper script (`run-server.sh`) sources login shell profiles for GUI app compatibility, ensuring tools like pyenv, nvm, and rbenv work correctly when launched from MCPB-compatible clients.

To disable login shell sourcing (for faster startup), set:
```bash
MCPB_SKIP_LOGIN_SHELL=1
```

## Adding an Icon

Place `icon.png` or `icon.svg` in your project root. It will be automatically included in the bundle and displayed in Claude Desktop.

Recommended specifications:
- PNG: 512x512 pixels, transparent background
- SVG: Vector format preferred

## Testing Your Bundle

1. **Create the bundle:**
   ```bash
   mcp-bash bundle --output ./dist
   ```

2. **Install in an MCPB-compatible client:**
   - Double-click the `.mcpb` file, or
   - Drag it to the client window (e.g., Claude Desktop)

3. **Verify installation:**
   - Open the client's settings/extensions view
   - Check that your server appears in the extensions list
   - Test your tools in a conversation

4. **Debug issues:**
   ```bash
   # Extract bundle to inspect contents
   unzip -d /tmp/bundle-test my-server-1.0.0.mcpb

   # Test the wrapper script directly
   /tmp/bundle-test/server/run-server.sh --health

   # Run in debug mode for full payload logging
   MCPBASH_PROJECT_ROOT=/tmp/bundle-test/server /tmp/bundle-test/server/.mcp-bash/bin/mcp-bash debug
   ```

   See [DEBUGGING.md](DEBUGGING.md) for comprehensive debugging guidance including MCP Inspector integration, log analysis, and troubleshooting flowcharts.

## Publishing to MCP Registry

To list your server in the official MCP Registry:

1. Ensure your `mcpb.conf` has complete author information
2. Create a public GitHub repository
3. Get an API token from [registry.modelcontextprotocol.io](https://registry.modelcontextprotocol.io/)
4. Publish using the CLI:

```bash
# Set your API token
export MCP_REGISTRY_TOKEN="your-token-here"

# Validate before publishing
mcp-bash publish my-server-1.0.0.mcpb --dry-run

# Submit to registry
mcp-bash publish my-server-1.0.0.mcpb
```

### Publish Command Options

```bash
mcp-bash publish <bundle.mcpb> [options]

Options:
  --dry-run          Validate without submitting
  --token TOKEN      API token (or set MCP_REGISTRY_TOKEN env var)
  --verbose          Show detailed progress
  --help, -h         Show help
```

## Troubleshooting

### Bundle fails to create

**Missing `server.d/server.meta.json`:**
```bash
mcp-bash init  # Initialize project structure
```

**Missing `zip` command:**
```bash
# macOS
brew install zip

# Linux
sudo apt install zip
```

### Bundle installs but tools don't work

**Check jq/gojq availability:**
The framework requires `jq` or `gojq` for JSON processing. If not available on the target system, the server runs in minimal mode.

**Check shell profile:**
If tools rely on environment variables from your shell profile, ensure login shell sourcing is enabled (default behavior).

### Icons not showing

- Ensure icon is named exactly `icon.png` or `icon.svg`
- Place in project root (not in subdirectory)
- PNG should be at least 256x256 pixels

## See Also

- [MCPB Specification](https://github.com/modelcontextprotocol/mcpb)
- [MANIFEST.md](https://github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md)
- [MCP Registry](https://registry.modelcontextprotocol.io/)
