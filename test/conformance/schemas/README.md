# Vendored MCP schemas

Official JSON Schemas for each MCP protocol revision the server negotiates,
copied unchanged from
[modelcontextprotocol/modelcontextprotocol](https://github.com/modelcontextprotocol/modelcontextprotocol)
(`schema/<version>/schema.json`) at commit
`4a04acdb151b8d3c6963fa566d9435cdfdc7bd43`.

`test/integration/test_conformance_schema.sh` validates real server output
against them. Add a revision here when the server starts negotiating it.
2026-07-28 is published upstream but not vendored: 1.x doesn't negotiate it
(clients that probe `server/discover` fall back to `initialize` and
2025-11-25). It arrives with the stateless path in 2.0.

Upstream licence: specification contributions are Apache-2.0; older
contributions not yet relicensed remain MIT. See the upstream `LICENSE`.

To refresh, replace `<sha>` with the upstream commit:

```bash
for v in 2024-11-05 2025-03-26 2025-06-18 2025-11-25; do
	curl -sfL -o "test/conformance/schemas/${v}.json" \
		"https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/<sha>/schema/${v}/schema.json"
done
```

Then update the commit above.
