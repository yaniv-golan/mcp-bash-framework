# Error Handling Guidelines

- Tool/resource failures return `isError=true` with `_meta.exitCode` and captured stderr.
- Malformed tool output triggers a substitution with an error payload and a logged incident.
- Registry or discovery errors fall back to minimal capabilities while emitting `notifications/message` with severity `error`.
- Manual overrides should return well-formed JSON; otherwise auto-discovery resumes and issues `listChanged` notifications.
