# Testing Your MCP Tools

This directory contains tests for your MCP server tools.

## Quick Start

Run all tests:
```bash
./test/run.sh
```

Run with verbose output:
```bash
./test/run.sh --verbose
```

Skip validation errors (useful during development):
```bash
./test/run.sh --force
```

## Adding Tests

Edit `test/run.sh` and add test calls in the marked section:

```bash
# Basic test - tool must succeed
run_test "my-tool" '{"input":"value"}'

# Test with description (shown in output)
run_test "my-tool" '{"input":"value"}' "handles basic input"

# Dry-run - validates args and metadata without executing
run_dry_run "my-tool" '{"input":"value"}'

# Conditional skip
if [[ -z "${REQUIRED_VAR:-}" ]]; then
    skip_test "my-tool" "REQUIRED_VAR not set"
else
    run_test "my-tool" '{"input":"value"}'
fi
```

## Advanced Testing

### Testing with Simulated Roots

Use `mcp-bash run-tool` directly for advanced scenarios:

```bash
# Simulate a single MCP root
mcp-bash run-tool my-tool \
    --args '{"path":"file.txt"}' \
    --roots '/path/to/allowed/dir'

# Multiple roots (comma-separated)
mcp-bash run-tool my-tool \
    --args '{"path":"file.txt"}' \
    --roots '/repo1,/repo2'
```

> **Windows/Git Bash Note**: Set `MSYS2_ARG_CONV_EXCL="*"` before running commands with path arguments to prevent automatic path mangling (e.g., `/repo` becoming `C:/Git/repo`). The scaffolded `test/run.sh` sets this automatically.

### Testing Error Cases

```bash
# Expect failure (invert exit code)
if mcp-bash run-tool my-tool --args '{"invalid":true}' 2>/dev/null; then
    echo "FAIL: Should have rejected invalid input"
    exit 1
fi
echo "PASS: Correctly rejected invalid input"
```

### Testing with Custom Timeout

```bash
mcp-bash run-tool slow-tool --args '{}' --timeout 120
```

### Testing Minimal Mode

```bash
mcp-bash run-tool my-tool --args '{}' --minimal
```

## CI Integration

Add to your GitHub Actions workflow:

```yaml
name: Test
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install dependencies
        run: sudo apt-get update && sudo apt-get install -y jq
      
      - name: Install mcp-bash
        run: |
          curl -fsSL https://raw.githubusercontent.com/yaniv-golan/mcp-bash-framework/main/install.sh | bash -s -- --yes
          echo "$HOME/.local/bin" >> $GITHUB_PATH
          
      - name: Validate project
        run: mcp-bash validate
        
      - name: Run tests
        run: ./test/run.sh
```

> **Note**: Adjust the install step if you're using a fork or specific branch. See the [installation docs](https://github.com/yaniv-golan/mcp-bash-framework#installation) for alternatives.

## Reference

<!-- Note: These paths are relative from test/README.md in the generated project -->
- [Best Practices Guide](https://github.com/yaniv-golan/mcp-bash-framework/blob/main/docs/BEST-PRACTICES.md) - SDK helpers, testing patterns
- [run-tool CLI](https://github.com/yaniv-golan/mcp-bash-framework/blob/main/docs/BEST-PRACTICES.md#testing-tools-with-run-tool) - Full CLI reference

> **Note**: If you have the mcp-bash framework installed locally, you can also reference its docs at `${MCPBASH_HOME}/docs/`.
