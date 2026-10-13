# Vendored MCP schemas

Official JSON Schemas for each MCP protocol revision the server negotiates,
copied unchanged from
[modelcontextprotocol/modelcontextprotocol](https://github.com/modelcontextprotocol/modelcontextprotocol)
(`schema/<version>/schema.json`): 2024-11-05 to 2025-11-25 at commit
`4a04acdb151b8d3c6963fa566d9435cdfdc7bd43`, 2026-07-28 at commit
`3778656b2e0ba6725035e816fe3085374cbaa736` (the file last changed upstream on
2026-07-28, in `271ecc9`).

`test/integration/test_conformance_schema.sh` validates real server output
against them. Add a revision here when the server starts negotiating it.
The 2026-07-28 session is stateless (no `initialize`; every request carries
`_meta`) and runs with `MCPBASH_MODERN_PROTOCOL=true`.

Upstream licence: specification contributions are Apache-2.0; older
contributions not yet relicensed remain MIT. See the upstream `LICENSE`.

To refresh, replace `<sha>` with the upstream commit:

```bash
for v in 2024-11-05 2025-03-26 2025-06-18 2025-11-25 2026-07-28; do
	curl -sfL -o "test/conformance/schemas/${v}.json" \
		"https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/<sha>/schema/${v}/schema.json"
done
```

Then update the commit above.
