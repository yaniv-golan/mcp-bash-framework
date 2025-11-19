# 03-progress-and-cancellation

## Demonstrates
- Emitting progress notifications using the SDK.
- Cancelling an in-flight tool call (`notifications/cancelled`).

## Run
```
./examples/run 03-progress-and-cancellation
```
In another terminal:
```
printf '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"example.slow","_meta":{"progressToken":"token-1"}}}\n' | ./examples/run 03-progress-and-cancellation
```

While the tool runs, send:
```
printf '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"2"}}\n' | ./examples/run 03-progress-and-cancellation
```
Watch for `notifications/progress` and the tool’s final cancellation outcome.

## Tips
- Remove the cancellation request to see the tool finish and respond with text.
- Adjust `timeoutSecs` in `slow.meta.json` to exercise watchdog behaviour.
