# 09-embedded-resources

**What you’ll learn**
- Attach file content to a tool result via `type:"resource"` content
- TSV vs JSON formats for `MCP_TOOL_RESOURCES_FILE`
- Binary files are auto-base64-encoded (`blob`); text stays in `text`

**Prereqs**
- Bash 3.2+
- jq or gojq required; without it the server enters minimal mode and this example is unavailable

**Run**
```
./examples/run 09-embedded-resources
```

**Transcript**
```
> tools/call {"name":"embed-resource","arguments":{}}
< {"result":{"content":[{"type":"text","text":"See embedded report for details"},{"type":"resource","resource":{"mimeType":"text/plain","text":"Embedded report","uri":"file://./resources/report.txt"}}],"_meta":{"exitCode":0}}}
```

**Success criteria**
- Tool output includes one `type:"resource"` entry with `mimeType` `text/plain`
- The resource text matches the file content (`Embedded report`)

**Troubleshooting**
- Ensure `resources/report.txt` is writable and under the project root (roots enforcement applies).
- Install jq/gojq; minimal mode disables tools/resources/prompts.
- If the embedded resource is missing, run with `MCPBASH_LOG_LEVEL=debug` to see skipped embeds.
