# Migration Guide: Framework/Project Separation

## Breaking Change

Starting with version X.X.X, `mcp-bash` requires a strict separation between the framework (engine) and your server code (project). The framework will no longer scan its own `tools/`, `prompts/`, or `resources/` directories.

## Why This Change?

The previous model had significant limitations:

- **Upgrade Problems**: Updating the framework could conflict with your tools
- **Version Control**: Your code and the framework were mixed together
- **Read-Only Installs**: Couldn't install framework in `/opt` or Docker read-only layers
- **Multi-Project**: Couldn't share one framework installation across multiple servers

## What You Need to Do

### 1. Create a Project Directory

Create a new directory **outside** the `mcp-bash` repository:

```bash
mkdir ~/my-mcp-server
```

### 2. Move Your Content

Move your custom directories to the project:

```bash
# If you had custom tools/prompts/resources in the old setup
cd /path/to/old/mcp-bash
mv tools ~/my-mcp-server/
mv prompts ~/my-mcp-server/
mv resources ~/my-mcp-server/
mv server.d ~/my-mcp-server/  # if you had custom server.d/register.sh
```

### 3. Update Your MCP Client Configuration

**Before** (old way):

```json
{
  "mcpServers": {
    "bash": {
      "command": "/Users/me/mcp-bash/bin/mcp-bash",
      "args": []
    }
  }
}
```

**After** (new way):

```json
{
  "mcpServers": {
    "bash": {
      "command": "/opt/mcp-bash/bin/mcp-bash",
      "env": {
        "MCPBASH_PROJECT_ROOT": "/Users/me/my-mcp-server"
      }
    }
  }
}
```

### 4. Clean Up (Optional)

You can now reinstall the framework to a clean location:

```bash
# Move framework to a system location
sudo mv /Users/me/mcp-bash /opt/mcp-bash

# Or clone fresh
git clone https://github.com/yaniv-golan/mcp-bash.git /opt/mcp-bash
```

Your project is now independent and won't be touched by framework upgrades.

## For Docker Users

**Before**:

```dockerfile
FROM debian:bookworm-slim
COPY mcp-bash/ /app/
WORKDIR /app
CMD ["./bin/mcp-bash"]
```

**After**:

```dockerfile
FROM debian:bookworm-slim

# Framework (read-only, can be in a base image)
COPY mcp-bash/ /opt/mcp-bash/

# Project (your code)
COPY my-server/ /app/

ENV MCPBASH_PROJECT_ROOT=/app

CMD ["/opt/mcp-bash/bin/mcp-bash"]
```

## Example Migration: ffmpeg-studio

The `examples/04-ffmpeg-studio` example demonstrates this pattern:

**Before**: Everything in `examples/04-ffmpeg-studio/`

**After**:

```bash
# Framework (installed once)
/opt/mcp-bash/

# Project (your code)
~/ffmpeg-studio/
├── tools/
│   ├── inspect/
│   ├── extract/
│   └── transcode/
├── config/
│   └── media_roots.json
└── lib/
    └── fs_guard.sh
```

Run with:

```bash
export MCPBASH_PROJECT_ROOT=~/ffmpeg-studio
/opt/mcp-bash/bin/mcp-bash
```

## Scaffolding in the New Model

**Before**:

```bash
cd /path/to/mcp-bash
./bin/mcp-bash scaffold tool my-tool
# Created tools/my-tool in the framework directory
```

**After**:

```bash
export MCPBASH_PROJECT_ROOT=~/my-mcp-server
/opt/mcp-bash/bin/mcp-bash scaffold tool my-tool
# Creates ~/my-mcp-server/tools/my-tool
```

## Troubleshooting

### Error: "MCPBASH_PROJECT_ROOT is not set"

You must set `MCPBASH_PROJECT_ROOT` in your MCP client configuration. See [Project Structure Guide](PROJECT-STRUCTURE.md) for examples.

### Error: "No such file or directory: tools/"

Your project directory must exist and contain the expected structure. Create it with:

```bash
mkdir -p ~/my-mcp-server/{tools,prompts,resources}
```

### How to verify paths

Run with `MCPBASH_LOG_LEVEL=debug` to see resolved paths:

```json
{
  "env": {
    "MCPBASH_PROJECT_ROOT": "/Users/me/my-server",
    "MCPBASH_LOG_LEVEL": "debug"
  }
}
```

Check the logs for output like:

```
Resolved paths:
  MCPBASH_PROJECT_ROOT=/Users/me/my-server
  MCPBASH_TOOLS_DIR=/Users/me/my-server/tools
  ...
```

## Benefits After Migration

✅ **Clean Upgrades**: `git pull` in `/opt/mcp-bash` won't touch your tools  
✅ **Version Control**: Your project is a separate git repo  
✅ **Multi-Project**: Run 5 different servers from one framework  
✅ **Docker-Friendly**: Framework in read-only layer, project in writable layer  
✅ **Clear Ownership**: Framework code vs. your code is obvious  

## Questions?

See the [Project Structure Guide](PROJECT-STRUCTURE.md) for detailed examples and deployment patterns.

