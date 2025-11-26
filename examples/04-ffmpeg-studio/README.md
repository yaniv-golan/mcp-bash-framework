# Example 04: FFmpeg Studio

This example demonstrates a high-value, complex MCP server that acts as a media processing engine. It showcases **long-running operations** with real-time **progress reporting** and safe, sandboxed file access.

## Features

*   **Structured Inspection**: Instead of parsing raw text output, `inspect_media` returns clean JSON metadata about video files.
*   **Progress Bars**: The `transcode` tool uses `ffmpeg`'s progress pipe to send real-time percentage updates to the MCP client (real-time updates).
*   **Sandboxing**: File operations are confined to an allowlist of media roots (default `./media/`) so ffmpeg never escapes your chosen directories.
*   **Presets**: Simplifies complex `ffmpeg` command flags into semantic choices (e.g., "1080p", "gif").

## Prerequisites

This example requires `ffmpeg` and `ffprobe` to be installed on your system and available in your `$PATH`.

```bash
# macOS
brew install ffmpeg

# Debian/Ubuntu
sudo apt-get install ffmpeg
```

## SDK Helpers
`examples/run` exports `MCP_SDK` so the `tools/*.sh` scripts can source `sdk/tool-sdk.sh`. If you execute a tool directly (for debugging or integration), set `MCP_SDK` accordingly (see [SDK Discovery](../../README.md#sdk-discovery)).

## Usage

1.  Place a test video file (e.g., `test.mp4`) into one of the configured media roots (defaults to the bundled `media/` directory).
2.  Run the server:
    ```bash
    ./examples/run 04-ffmpeg-studio
    ```
3.  Use an MCP client (like Claude Desktop or Inspector) to interact with the tools.
   The runner automatically executes `check-env` so `ffmpeg`/`ffprobe` are validated and the `media/` directory is created.

## Configuring Media Roots

Media access is controlled by `config/media_roots.json`. Each entry defines a `path` (absolute or relative to this example directory) and an optional `mode`:

```json
{
  "roots": [
    { "path": "./media", "mode": "rw" },
    { "path": "/Volumes/samples", "mode": "ro" }
  ]
}
```

* `mode: "rw"` allows tools to read and write; `"ro"` permits read-only operations.
* Paths are normalized and any request that resolves outside the allowlist is rejected with `Access denied`.
* When a relative path is supplied to a tool, it is resolved against the first matching root; use absolute paths to target a specific directory when multiple roots exist.
* Directories listed here must exist before launching the server—`check-env` still creates the default `media/` directory for convenience.

### Example Prompts

*   "Inspect `test.mp4` and tell me its resolution."
*   "Convert `test.mp4` to a high-quality GIF named `output.gif`."
*   "Extract a frame from `test.mp4` at 5 seconds."

## Technical Details

### Progress Reporting

The `transcode.sh` script demonstrates how to handle long-running CLI processes. It calculates the total duration of the video first, then monitors `ffmpeg`'s machine-readable progress output to emit `mcp_progress` notifications.

Include `_meta.progressToken` in your `tools/call` request to receive progress updates. Example:

```
{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"transcode","arguments":{"input":"./media/test.mp4","output":"./media/out.mp4","preset":"720p"},"_meta":{"progressToken":"demo-progress"}}}
```

### Cancellation

If the user cancels the operation in the client, `mcp-bash` sends a signal which the script handles to clean up partial output files.
