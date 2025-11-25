# 02-logging-and-levels

## Purpose
Show how tools emit structured logs and how `logging/setLevel` affects visibility.

## Usage
```
./examples/run 02-logging-and-levels
```
Then from another terminal:
```
printf '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":"2","method":"logging/setLevel","params":{"level":"debug"}}\n{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"example.logger"}}\n' | ./examples/run 02-logging-and-levels
```

## SDK Helpers
`examples/run` sets `MCP_SDK` for you so `tools/logger.sh` can source the SDK helpers. Set `MCP_SDK` manually if you execute the script outside of the runner (see [SDK Discovery](../../README.md#sdk-discovery)).

You should see `notifications/message` messages containing `example.logger` before the tool result.

## Troubleshooting
- If logs do not appear, ensure you set the level to `debug` or `info`.
- Minimal mode still supports logging but may degrade structured metadata.
