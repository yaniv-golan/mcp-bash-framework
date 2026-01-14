# Minimal Mode

When JSON tooling (jq/gojq) is unavailable or `MCPBASH_FORCE_MINIMAL=true` is set, the runtime enters **minimal mode**:

- Triggered by: no `jq`/`gojq` detected on PATH, or `MCPBASH_FORCE_MINIMAL=true`.
- Capabilities: only lifecycle/ping/logging are exposed (`capabilities={"logging":{}}`); well-behaved clients will skip tools/resources/prompts/completion entirely. If called anyway, handlers return `-32601`.
- Behaviour: JSON parsing falls back to a minimal parser; progress/log notifications still emit text.
- Exit: install jq/gojq or unset `MCPBASH_FORCE_MINIMAL` and restart the server.

## Known Limitations

The minimal mode JSON parser is intentionally simple to avoid external dependencies. The following limitations apply:

### Unicode Escape Sequences

Unicode escape sequences (`\uXXXX`) in JSON strings are **validated but not decoded**. They pass through as literal characters:

```
Input:  {"method": "hello\u0041world"}
Output: method = "hello\u0041world"  (not "helloAworld")
```

**Impact:** Method names, parameters, or other string values containing unicode escapes will retain the escape syntax rather than being converted to actual characters.

**Workaround:** Install jq or gojq for full JSON support. In practice, MCP clients rarely use unicode escapes for method names or simple string parameters.

### Debug Payload Logging

When jq is unavailable, debug payload logging (`MCPBASH_DEBUG_PAYLOADS=true`) emits a secure fingerprint instead of the full redacted payload:

```
[payload hash=abc123... bytes=1234 - install jq for full debug output]
```

This is a security measure: without jq, reliable secret redaction cannot be guaranteed, so the entire payload is redacted to prevent accidental leakage.
