# Advanced Example: FFmpeg Studio

**Optional/advanced** – requires `ffmpeg`/`ffprobe`.

**What you’ll learn**
- Long-running tool orchestration with progress updates and cancellation
- Structured inspection vs text scraping for media metadata
- Sandboxed file access via configured media roots

**What it does**
- `inspect_media`: runs `ffprobe` and returns normalized JSON (duration, streams, codecs, resolution) instead of raw text.
- `transcode`: converts an input to a preset (e.g., 720p, gif), emitting progress and honoring cancellation; keeps output inside allowed roots.
- `extract_frame`: grabs a frame at a timestamp to an output file under the media root.
- Preset configs keep invocations short while still exposing meaningful parameters.

**Prereqs**
- Bash 3.2+
- `ffmpeg` and `ffprobe` on PATH
- jq or gojq (required; fs_guard uses it to parse media roots)

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

**Configuring media roots**
Edit `config/media_roots.json` to set allowed paths:
```json
{
  "roots": [
    { "path": "./media", "mode": "rw" },
    { "path": "/Volumes/samples", "mode": "ro" }
  ]
}
```
`mode: "rw"` allows read/write; `"ro"` is read-only. Paths are normalized; requests outside the allowlist are denied.
