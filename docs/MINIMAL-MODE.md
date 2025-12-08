# Minimal Mode

When JSON tooling (jq/gojq) is unavailable or `MCPBASH_FORCE_MINIMAL=true` is set, the runtime enters **minimal mode**:

- Triggered by: no `jq`/`gojq` detected on PATH, or `MCPBASH_FORCE_MINIMAL=true`.
- Capabilities: only lifecycle/ping/logging are exposed (`capabilities={"logging":{}}`); well-behaved clients will skip tools/resources/prompts/completion entirely. If called anyway, handlers return `-32601`.
- Behaviour: JSON parsing falls back to a minimal parser; progress/log notifications still emit text.
- Exit: install jq/gojq or unset `MCPBASH_FORCE_MINIMAL` and restart the server.
