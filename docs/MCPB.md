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

# Author information (recommended for registry listing)
MCPB_AUTHOR_NAME="Your Name"
MCPB_AUTHOR_EMAIL="you@example.com"
MCPB_AUTHOR_URL="https://github.com/you"

# Repository URL
MCPB_REPOSITORY="https://github.com/you/my-server"
```

If `mcpb.conf` is not present, values are resolved from:
1. Command-line options (`--name`, `--version`)
2. `server.d/server.meta.json`
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
  "author": {
    "name": "Your Name",
    "email": "you@example.com",
    "url": "https://github.com/you"
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/you/my-server"
  },
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
    "platforms": ["darwin", "linux"]
  }
}
```

**Required fields:** `manifest_version`, `name`, `version`, `description`, `author`, `server`

**Note:** The `author` field is required by the MCPB spec. If not provided via `mcpb.conf` or `server.meta.json`, the bundler falls back to git config.

## Platform Compatibility

Bundles are compatible with:
- **macOS** (darwin): Native support
- **Linux**: Native support

Windows support is not currently included due to bash script requirements. Future versions may add Windows support via bundled shell environments.

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
   ```

## Publishing to MCP Registry

To list your server in the official MCP Registry:

1. Ensure your `mcpb.conf` has complete author information
2. Create a public GitHub repository
3. Submit to [registry.modelcontextprotocol.io](https://registry.modelcontextprotocol.io/)

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
