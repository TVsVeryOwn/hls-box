# hls-box

**Stable, restart-safe live HLS with permanent URLs**

`hls-box` is a small but opinionated live-streaming stack designed to solve a very specific problem:

> Keeping HLS URLs stable and playable across restarts, crashes, and redeploys.

If you have ever run a live HLS setup where:

- playlists randomly stop updating
- players freeze or fall behind
- CDNs serve stale segments
- FFmpeg restarts break all viewers

This repository exists because those problems were debugged in production — not theory.

## Why this exists

Live HLS looks simple on paper, but in practice it fails in subtle ways:

- FFmpeg restarts reuse segment filenames
- `#EXT-X-MEDIA-SEQUENCE` jumps backwards
- nginx-rtmp’s built-in HLS breaks on restart
- CDNs cache playlists they should never cache
- players request segments that no longer exist

Most tutorials ignore these issues because they only test:

- short-lived streams
- localhost playback
- single-process setups

This project was built by observing real failure modes and locking down every moving part so that:

- segment filenames are never reused
- media sequence numbers never rewind
- playlists remain live across restarts
- caching is explicitly disabled
- ingest, transcode, and HTTP are isolated

## Design goals

This project intentionally optimizes for:

- permanent HLS URLs
- safe FFmpeg restarts
- predictable player behavior
- clear operational boundaries
- minimal magic

It intentionally does not try to be:

- a one-click streaming platform
- a CDN replacement
- a transcoding ladder generator
- an OBS plugin

## Architecture

OBS does one thing: publish RTMP.

Everything else is separated on purpose:

- nginx-rtmp (ingest only)
- FFmpeg (HLS generation, restart-safe)
- nginx (static HTTP only)
- Cloudflare Tunnel (optional public access)

### Why this separation matters

- nginx-rtmp never touches HLS files
- FFmpeg can restart without breaking URLs
- HTTP serving is dumb and cache-controlled
- Cloudflare never sees RTMP or FFmpeg
- failures are contained to one layer

## What this guarantees (and what it doesn’t)

### Guarantees

- stable playlist URLs (`index.m3u8`)
- monotonic segment numbering
- no playlist rewinds
- no stale cache behavior
- safe FFmpeg restarts
- multiple simultaneous streams

### Non-goals

- adaptive bitrate ladders
- DVR / rewind support
- authentication or DRM
- viewer analytics
## Design decisions

### Why not nginx-rtmp HLS?

Because it:

- rewrites playlists on restart
- reuses segment names
- breaks long-running streams
- offers no restart safety

### Why not let FFmpeg serve HTTP?

Because:

- it has no proper cache control
- it complicates restarts
- it mixes concerns
- it is fragile under load

### Why are segment numbers large or non-sequential?

Segment numbers are intentionally monotonic, not contiguous.

Gaps do not matter in HLS.  
Rewinds do.

### Why is caching disabled everywhere?

Because any caching of live HLS eventually causes:

- frozen players
- missing segments
- “works locally but not publicly” bugs

## Requirements

- Docker
- Docker Compose
- OBS (or any RTMP publisher)
- optional: Cloudflare account for public access

## Quick start (local)

```sh
git clone https://github.com/yourname/hls-box.git
cd hls-box
docker compose up -d
```

Local playback URL:

```http://127.0.0.1:8080/hls/nginx0/index.m3u8```
### OBS configuration

Create one OBS profile per stream.

Stream settings:

* Server: rtmp://127.0.0.1:1935/live

* Stream Key: nginx0 (or nginx1, nginx2, etc.)

Each stream key maps to its own HLS output directory.

### Local playback

Test with VLC, mpv, ffplay, or any HLS-capable player:

```ffplay http://127.0.0.1:8080/hls/nginx0/index.m3u8```

## Optional: Cloudflare Tunnel (public access)

This stack is designed to work **locally first**. Public access is optional.

If you want permanent public HLS URLs without opening ports, `hls-box` supports
Cloudflare Tunnel.

### What Cloudflare does here

- Exposes **HTTP only** (never RTMP)
- Does **not** cache playlists or segments
- Provides stable public URLs
- Keeps your origin private

Cloudflare **never** touches FFmpeg or RTMP.

Example public URL:

```https://hls.example.com/hls/nginx0/index.m3u8```

---

### Prerequisites

- A Cloudflare account
- A domain added to Cloudflare
- `cloudflared` tunnel token

---

### Setup steps

1. Create a tunnel in Cloudflare:

   https://one.dash.cloudflare.com → Zero Trust → Networks → Tunnels

2. Copy the **tunnel token**

3. Create a `.env` file in the project root:


4. Update your hostname in `docker-compose.yml` if needed:

```hls.example.com → http://http:8080```


5. Start the stack:

docker compose up -d  

---

### Public playback URL

Once running, your stream will be available at:
```https://hls.example.com/hls/nginx0/index.m3u8```

Additional streams:

```
https://hls.example.com/hls/nginx1/index.m3u8
https://hls.example.com/hls/nginx2/index.m3u8
```


---

### Important Cloudflare notes

- Cloudflare caching is **explicitly disabled**
- Playlists are marked `no-store`
- Segments are treated as dynamic content
- Query-string cache busting is supported

If Cloudflare caching is enabled, **live HLS will break**.


#### Notes:

* caching is explicitly disabled

* playlists are marked no-store

* segments are treated as dynamic content

### Multi-stream support

Multiple streams are supported simultaneously:

nginx0, nginx1, nginx2, etc.

Each stream runs:

* its own FFmpeg container

* its own HLS directory

* its own playlist lifecycle

### Debugging & sanity checks

Check playlist updates:

```watch -n 2 tail hls/nginx0/index.m3u8```


Verify playlist content:

```curl -s http://127.0.0.1:8080/hls/nginx0/index.m3u8 | tail -n 10```


Probe a segment:

```ffprobe hls/nginx0/69.ts```