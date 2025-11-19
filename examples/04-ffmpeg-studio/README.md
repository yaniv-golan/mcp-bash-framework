# Example 04: FFmpeg Studio

This example demonstrates a high-value, complex MCP server that acts as a media processing engine. It showcases **long-running operations** with real-time **progress reporting** and safe, sandboxed file access.

## Features

*   **Structured Inspection**: Instead of parsing raw text output, `inspect_media` returns clean JSON metadata about video files.
*   **Progress Bars**: The `transcode` tool uses `ffmpeg`'s progress pipe to send real-time percentage updates to the MCP client (real-time updates).
*   **Sandboxing**: All file operations are strictly limited to the `media/` subdirectory to prevent unauthorized system access.
*   **Presets**: Simplifies complex `ffmpeg` command flags into semantic choices (e.g., "1080p", "gif").

## Prerequisites

This example requires `ffmpeg` and `ffprobe` to be installed on your system and available in your `$PATH`.

```bash
# macOS
brew install ffmpeg

# Debian/Ubuntu
sudo apt-get install ffmpeg
```

## Usage

1.  Place a test video file (e.g., `test.mp4`) into the `media/` directory.
2.  Run the server:
    ```bash
    ./run 04-ffmpeg-studio
    ```
3.  Use an MCP client (like Claude Desktop or Inspector) to interact with the tools.

### Example Prompts

*   "Inspect `test.mp4` and tell me its resolution."
*   "Convert `test.mp4` to a high-quality GIF named `output.gif`."
*   "Extract a frame from `test.mp4` at 5 seconds."

## Technical Details

### Progress Reporting

The `transcode.sh` script demonstrates how to handle long-running CLI processes. It calculates the total duration of the video first, then monitors `ffmpeg`'s machine-readable progress output to emit `mcp_progress` notifications.

### Cancellation

If the user cancels the operation in the client, `mcp-bash` sends a signal which the script handles to clean up partial output files.

