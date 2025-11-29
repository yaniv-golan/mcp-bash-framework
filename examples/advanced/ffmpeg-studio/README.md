# Advanced Example: FFmpeg Studio

**Optional/advanced** – requires `ffmpeg`/`ffprobe`.

**What you’ll learn**
- Long-running tool orchestration with progress updates and cancellation
- Structured inspection vs text scraping for media metadata
- Sandboxed file access via MCP Roots (client-provided roots) with a safe default fallback
- Optional elicitation confirmation before overwriting outputs (if the client supports elicitation)

**What it does**
- `inspect_media`: runs `ffprobe` and returns normalized JSON (duration, streams, codecs, resolution) instead of raw text.
- `transcode`: converts an input to a preset (e.g., 720p, gif), emitting progress and honoring cancellation; keeps output inside allowed roots. If the client supports elicitation, it will ask before overwriting an existing output; otherwise it refuses to overwrite.
- `extract_frame`: grabs a frame at a timestamp to an output file under the media root.
- Preset configs keep invocations short while still exposing meaningful parameters.

**Prereqs**
- Bash 3.2+
- `ffmpeg` and `ffprobe` on PATH
- jq or gojq (used for args parsing/JSON handling)

**Run**
```
./examples/run advanced/ffmpeg-studio

# Quick start with bundled sample (12s clip at ./media/example.mp4)
./examples/run advanced/ffmpeg-studio -- \
  tools/call inspect_media '{"arguments":{"path":"./media/example.mp4"}}'
```

**Transcript (abridged)**
```
> tools/call transcode {"arguments":{"input":"./media/example.mp4","output":"./media/out-720p.mp4","preset":"720p"},"_meta":{"progressToken":"demo-progress"}}
< notifications/progress ... "10%"
< notifications/progress ... "50%"
< {"result":{"content":[{"type":"text","text":"Transcode complete"}]}}
```
Include `_meta.progressToken` to receive progress updates.

**Success criteria**
- Media roots created (runner calls `check-env` to provision `media/` with `example.mp4` ready to use)
- Progress notifications arrive during long runs; cancellation returns `-32001`
- Inspect/transcode/extract complete without escaping configured roots

**Troubleshooting**
- Missing `ffmpeg`/`ffprobe`: install via `brew install ffmpeg` (macOS) or `apt-get install ffmpeg` (Debian/Ubuntu).
- No progress? Ensure `_meta.progressToken` is set on the call and `MCPBASH_ENABLE_LIVE_PROGRESS=true` if you want streaming mid-flight.
- Access denied: use the bundled `./media/example.mp4`, or update `config/media_roots.json` to include your media paths.
- Long runtimes: this example is heavy; it’s excluded from the quick smoke ladder.

**Roots and file access**
- By default (no client roots / env / config), the example falls back to the bundled `./media` directory so you can run immediately and use `./media/example.mp4`.
- Preferred: let your MCP client provide roots. The server will request `roots/list` after initialization and the tools will only operate inside those roots.
- Override via env for quick testing: `MCPBASH_ROOTS="/path/one:/path/two"`.
- Project config (optional): create `examples/advanced/ffmpeg-studio/config/roots.json` if you want a project default. Example:
  ```json
  {
    "roots": [
      { "path": "./media", "name": "Sample Media" },
      { "path": "/Volumes/samples", "name": "External Samples" }
    ]
  }
  ```
All paths are normalized; accesses outside the configured roots are denied. Read/write enforcement relies on your filesystem permissions (no custom mode overlay).
