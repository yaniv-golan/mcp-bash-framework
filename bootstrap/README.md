# Bootstrap Getting-Started Helper

This bootstrap project is staged automatically when you run `mcp-bash` without `MCPBASH_PROJECT_ROOT` set. It registers a single `getting_started` tool that explains how to configure a real project and points to the core docs.

The staged project is temporary, writable, and cleaned up on exit. It is never copied into scaffolded projects and is only used for the “no project configured” path.
