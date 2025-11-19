# Security Considerations

- Tools/resources inherit the server environment; operators should constrain roots (`MCP_RESOURCES_ROOTS`) and environment variables when running untrusted scripts.
- Logging defaults to `info` and can be tuned with `logging/setLevel` while respecting RFC-5424 levels.
- Manual registration scripts execute in-process; ensure they are trusted before enabling `server.d/register.sh`.
- JSON outputs are escaped and newline-compacted before reaching stdout to protect consumers.
