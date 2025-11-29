# 08-roots-basics

**What you’ll learn**
- How MCP Roots scope tool filesystem access
- Using the SDK roots helpers (`mcp_roots_contains`, `MCP_ROOTS_*` env)
- Fallback roots via `config/roots.json` and `MCPBASH_ROOTS`

**Prereqs**
- Bash 3.2+
- jq or gojq

**Run**
```
# From repo root
./examples/run 08-roots-basics
```

**Try it**
```
> tools/call example.roots.read {"arguments":{"path":"./data/sample.txt"}}
< {"result":{"content":[{"type":"text","text":"Contents of /.../data/sample.txt\nHello from roots example!\n"}]}}

> tools/call example.roots.read {"arguments":{"path":"/etc/passwd"}}
< {"error":{"code":-32602,"message":"Path is outside allowed roots"}}
```

**Roots configuration**
- Default fallback: `config/roots.json` includes `./data` so the example works out of the box.
- Override via env: `MCPBASH_ROOTS="/tmp/myroot:/var/tmp/other" ./examples/run 08-roots-basics`
- Client-provided roots: if your MCP client supports roots, the server will request them and use those instead of the fallback.

**Success criteria**
- Reading `./data/sample.txt` succeeds; paths outside configured roots are denied.
