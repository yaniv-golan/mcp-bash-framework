# Operational Limits

- Default concurrency: 16 worker slots (`MAX_CONCURRENT_REQUESTS`) configurable via env.
- Default tool timeout: 30 seconds; override globally or per metadata (`timeoutSecs`).
- Tool output greater than 10MB is truncated and returned as an error with diagnostics.
- Progress notifications throttled to 100/minute per request; rate can be tuned with `MAX_PROGRESS_PER_MIN`.
