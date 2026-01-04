#!/bin/sh
set -eu

# rtmp-to-hls.posix.sh
# Robust RTMP -> HLS with:
# - publisher detection via ffprobe (patient + stderr ignored)
# - requires a video stream before starting ffmpeg
# - runs ffmpeg in foreground; restarts on exit
# - avoids leaving 0-byte playlists as much as possible

usage() {
  echo "Usage: $(basename "$0") <stream_key>" >&2
  exit 2
}

log() {
  # ISO-ish timestamp
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

[ $# -eq 1 ] || usage
STREAM_KEY="$1"

RTMP_BASE="${RTMP_BASE:-rtmp://rtmp:1935/live}"
OUT_BASE="${OUT_BASE:-/hls}"
HLS_TIME="${HLS_TIME:-5}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-6}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-30}"
CLEAN_TS="${CLEAN_TS:-0}"

IN_URL="${RTMP_BASE}/${STREAM_KEY}"
OUT_DIR="${OUT_BASE}/${STREAM_KEY}"
PLAYLIST="${OUT_DIR}/index.m3u8"
ERR="/tmp/rtmp-to-hls.${STREAM_KEY}.ffmpeg.err"

mkdir -p "$OUT_DIR"

if [ "$CLEAN_TS" = "1" ]; then
  rm -f "$OUT_DIR"/*.ts "$PLAYLIST" 2>/dev/null || true
fi

command -v ffprobe >/dev/null 2>&1 || { log "ffprobe not found"; exit 1; }
command -v ffmpeg  >/dev/null 2>&1 || { log "ffmpeg not found";  exit 1; }

cleanup() { log "stopping"; }
trap cleanup INT TERM

# ffprobe flags: match the "patient" probe that you confirmed works
PROBE_FLAGS='
  -hide_banner
  -loglevel error
  -rw_timeout 15000000
  -analyzeduration 5M
  -probesize 5M
  -select_streams v:0
  -show_entries stream=codec_name,width,height
  -of default=nw=1
'

# Try to confirm publisher is really present by requiring 2 consecutive OK probes.
probe_once() {
  # IMPORTANT:
  # - mpp[...] noise goes to stderr; we discard stderr so parsing can't break.
  # - output goes to stdout; we just check exit code.
  # shellcheck disable=SC2086
  ffprobe $PROBE_FLAGS "$IN_URL" >/dev/null 2>/dev/null
}

wait_for_publisher() {
  while :; do
    if probe_once; then
      sleep 1
      if probe_once; then
        log "publisher detected (video stream present): $STREAM_KEY"
        return 0
      fi
    fi
    log "waiting for publisher..."
    sleep 2
  done
}

# ffmpeg input flags: keep it patient; RTMP can stall briefly
INPUT_FLAGS='
  -rw_timeout 15000000
  -analyzeduration 10M
  -probesize 10M
'


# Main loop: wait -> run ffmpeg -> restart on exit
while :; do
  wait_for_publisher

  # Optional: clear stale zero-byte playlist if present
  if [ -f "$PLAYLIST" ] && [ ! -s "$PLAYLIST" ]; then
    rm -f "$PLAYLIST" 2>/dev/null || true
  fi

  log "starting ffmpeg: $IN_URL -> $PLAYLIST"
  : >"$ERR" || true

  # Run ffmpeg in FOREGROUND so container logs show what happens and restarts behave sanely
  # shellcheck disable=SC2086
  ffmpeg -hide_banner -loglevel info \
    -fflags +genpts \
    $INPUT_FLAGS \
    -i "$IN_URL" \
    -map 0:v? -map 0:a? \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -g $((HLS_TIME * 30)) -keyint_min $((HLS_TIME * 30)) -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*${HLS_TIME})" \
    -c:a aac -ar 48000 -b:a 160k \
    -af "aresample=async=1:first_pts=0" \
    -f hls \
    -hls_time "$HLS_TIME" -hls_list_size "$HLS_LIST_SIZE" \
    -hls_flags delete_segments+independent_segments+temp_file \
    -hls_delete_threshold "$KEEP_SEGMENTS" \
    -hls_allow_cache 0 \
    -hls_segment_filename "${OUT_DIR}/%013d.ts" \
    "$PLAYLIST" \
    2>>"$ERR"

  RC=$?
  log "ffmpeg exited for $STREAM_KEY (rc=$RC). Last stderr lines:"
  tail -n 40 "$ERR" 2>/dev/null || true

  # Keep directory from exploding if delete_segments isn't keeping up
  if [ -n "$KEEP_SEGMENTS" ] 2>/dev/null; then
    # Best-effort prune: keep only the newest N .ts
    ls -1t "$OUT_DIR"/*.ts 2>/dev/null | awk "NR>${KEEP_SEGMENTS} {print}" | xargs -r rm -f 2>/dev/null || true
  fi

  # Backoff before retrying to avoid hot-looping
  sleep 2
done
