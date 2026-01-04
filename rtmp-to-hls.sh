#!/bin/sh
set -eu

usage() {
  echo "Usage: $(basename "$0") <stream_key>" >&2
  exit 2
}

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"
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

probe_once() {
  ffprobe -hide_banner -loglevel error \
    -rw_timeout 3000000 \
    -select_streams v:0 \
    -show_entries stream=codec_name,width,height \
    -of default=nw=1 \
    "$IN_URL" >/dev/null 2>&1
}

wait_for_publisher() {
  while :; do
    if probe_once; then
      log "publisher detected (video stream present): $STREAM_KEY"
      return 0
    fi
    log "waiting for publisher..."
    sleep 2
  done
}

run_ffmpeg() {
  log "starting ffmpeg: $IN_URL -> $PLAYLIST"

  # IMPORTANT:
  # - do NOT use "-listen 1"
  # - do NOT use any "$INPUT_FLAGS" env var
  # - run in foreground so the wrapper supervises cleanly
  ffmpeg -hide_banner -loglevel info \
    -rw_timeout 15000000 \
    -fflags +genpts \
    -i "$IN_URL" \
    -map 0:v:0 -map 0:a? \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -g $((HLS_TIME * 30)) -keyint_min $((HLS_TIME * 30)) -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*${HLS_TIME})" \
    -c:a aac -ar 48000 -b:a 160k \
    -af "aresample=async=1:first_pts=0" \
    -f hls \
    -hls_time "$HLS_TIME" -hls_list_size "$HLS_LIST_SIZE" \
    -hls_flags delete_segments+independent_segments+temp_file \
    -hls_allow_cache 0 \
    -hls_delete_threshold "$KEEP_SEGMENTS" \
    -hls_segment_filename "${OUT_DIR}/%013d.ts" \
    "$PLAYLIST" 2>"$ERR"
}

while :; do
  wait_for_publisher

  if run_ffmpeg; then
    rc=0
  else
    rc=$?
  fi

  log "ffmpeg exited for $STREAM_KEY (rc=$rc). Last stderr lines:"
  tail -n 25 "$ERR" 2>/dev/null || true

  sleep 2
done
