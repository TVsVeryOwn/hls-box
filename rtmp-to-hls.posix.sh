#!/bin/sh
set -eu

usage() {
  echo "Usage: $(basename "$0") <stream_key>" >&2
  exit 2
}

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

[ $# -eq 1 ] || usage
STREAM_KEY="$1"

# --- Config ---
RTMP_BASE="${RTMP_BASE:-rtmp://rtmp:1935/live}"
OUT_BASE="${OUT_BASE:-/hls}"

HLS_TIME="${HLS_TIME:-5}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-6}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-30}"
CLEAN_TS="${CLEAN_TS:-0}"

# Disk space guard (0 disables). Use either threshold.
HLS_MIN_FREE_KB="${HLS_MIN_FREE_KB:-0}"
HLS_MIN_FREE_PCT="${HLS_MIN_FREE_PCT:-0}"
DISK_GUARD_SLEEP="${DISK_GUARD_SLEEP:-5}"

# Offline slate
OFFLINE_PNG="${OFFLINE_PNG:-/assets/stream-offline.png}"
OFFLINE_AUDIO_RATE="${OFFLINE_AUDIO_RATE:-48000}"
OFFLINE_AUDIO_BITRATE="${OFFLINE_AUDIO_BITRATE:-160k}"
OFFLINE_VIDEO_FPS="${OFFLINE_VIDEO_FPS:-30}"

# Swap behavior: when live segments are fresh, serve live
LIVE_FRESH_SECONDS="${LIVE_FRESH_SECONDS:-15}"
SWAP_POLL_SECONDS="${SWAP_POLL_SECONDS:-1}"

# Live promotion hysteresis
LIVE_CONFIRM_POLLS="${LIVE_CONFIRM_POLLS:-2}"

# Cooldown after going offline (prevents flapping)
OFFLINE_COOLDOWN_SECONDS="${OFFLINE_COOLDOWN_SECONDS:-10}"

# Live ingest retry loop (only matters if ffmpeg exits)
LIVE_RETRY_SECONDS="${LIVE_RETRY_SECONDS:-2}"
LIVE_RETRY_MAX="${LIVE_RETRY_MAX:-5}"

# Offline generator retry loop
OFFLINE_RETRY_SECONDS="${OFFLINE_RETRY_SECONDS:-2}"
OFFLINE_RETRY_MAX="${OFFLINE_RETRY_MAX:-5}"

# How hard we wait for offline readiness before switching public
OFFLINE_READY_TIMEOUT="${OFFLINE_READY_TIMEOUT:-10}"
OFFLINE_READY_SAFETY="${OFFLINE_READY_SAFETY:-2}" # extra segments beyond list end

# IMPORTANT:
# Because /hls/<key>/index.m3u8 is a stable URL, the playlists MUST reference
# segments with a path prefix (live/ or offline/).
LIVE_BASE_URL="${LIVE_BASE_URL:-}"
OFFLINE_BASE_URL="${OFFLINE_BASE_URL:-}"

# --- Derived paths ---
IN_URL="${RTMP_BASE}/${STREAM_KEY}"
OUT_DIR="${OUT_BASE}/${STREAM_KEY}"

PUBLIC_PLAYLIST="${OUT_DIR}/index.m3u8"

LIVE_DIR="${OUT_DIR}/live"
LIVE_PLAYLIST="${LIVE_DIR}/index.m3u8"

OFFLINE_DIR="${OUT_DIR}/offline"
OFFLINE_PLAYLIST="${OFFLINE_DIR}/index.m3u8"

PID_OFF="/tmp/rtmp-to-hls.${STREAM_KEY}.offline.pid"
PID_LIVE="/tmp/rtmp-to-hls.${STREAM_KEY}.live.pid"

ERR_LIVE="/tmp/rtmp-to-hls.${STREAM_KEY}.live.ffmpeg.err"
ERR_OFF="/tmp/rtmp-to-hls.${STREAM_KEY}.offline.ffmpeg.err"

# Cap ffmpeg error logs (0 disables). Size in KB.
ERR_LOG_MAX_KB="${ERR_LOG_MAX_KB:-1024}"
ERR_LOG_CHECK_SECONDS="${ERR_LOG_CHECK_SECONDS:-10}"

PUBLIC_LIVE_MARK="${OUT_DIR}/.LIVE"

mkdir -p "$OUT_DIR" "$LIVE_DIR" "$OFFLINE_DIR"

if [ "$CLEAN_TS" = "1" ]; then
  rm -f "$LIVE_DIR"/*.ts "$LIVE_PLAYLIST" 2>/dev/null || true
  rm -f "$OFFLINE_DIR"/*.ts "$OFFLINE_PLAYLIST" 2>/dev/null || true
  rm -f "$PUBLIC_PLAYLIST" 2>/dev/null || true
  rm -f "$PUBLIC_LIVE_MARK" 2>/dev/null || true
fi

command -v ffmpeg >/dev/null 2>&1 || { log "ffmpeg not found"; exit 1; }

trap 'log "stopping"; exit 0' INT TERM
BOOT_T="$(date +%s)"

# --- Helpers ---
write_public_master() {
  # Atomic write: PUBLIC_PLAYLIST becomes a tiny master playlist that points at
  # either live/index.m3u8 or offline/index.m3u8 (relative path).
  target="$1"
  tmp="${PUBLIC_PLAYLIST}.tmp.$$"

  cat >"$tmp" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=2000000
${target}
EOF

  mv -f "$tmp" "$PUBLIC_PLAYLIST"
}

write_public_media_from() {
  src="$1"
  prefix="$2"
  seq_override="${3:-}"
  inject="${4:-0}"
  tmp="${PUBLIC_PLAYLIST}.tmp.$$"

  [ -r "$src" ] || return 1

  awk -v prefix="$prefix" -v inject="$inject" -v seq_override="$seq_override" '
    BEGIN { injected=0 }
    /^#/ {
      if ($0 ~ /^#EXT-X-MEDIA-SEQUENCE:/ && seq_override != "") {
        print "#EXT-X-MEDIA-SEQUENCE:" seq_override
        next
      }
      print $0
      if (inject && !injected && ($0 ~ /^#EXT-X-MEDIA-SEQUENCE:/ || $0 ~ /^#EXT-X-TARGETDURATION:/)) {
        print "#EXT-X-DISCONTINUITY"
        injected=1
      }
      next
    }
    /^[[:space:]]*$/ { next }
    {
      if ($0 ~ /:\/\// || $0 ~ /^\//) { print $0; next }
      print prefix "/" $0
    }
  ' "$src" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }

  mv -f "$tmp" "$PUBLIC_PLAYLIST"
  return 0
}

mtime_epoch() {
  m="$(stat -c %Y "$1" 2>/dev/null || true)"
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null || true)" ;; esac
  case "$m" in ''|*[!0-9]*) echo 0 ;; *) echo "$m" ;; esac
}

err_log_watch() {
  pid="$1"
  file="$2"
  max_kb="$3"
  check_s="$4"

  case "$max_kb" in ''|*[!0-9]*) return 0 ;; esac
  [ "$max_kb" -gt 0 ] || return 0
  max_bytes=$((max_kb * 1024))

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$check_s" || true
    [ -s "$file" ] || continue
    bytes="$(wc -c <"$file" 2>/dev/null || true)"
    case "$bytes" in ''|*[!0-9]*) continue ;; esac
    if [ "$bytes" -gt "$max_bytes" ]; then
      tmp="${file}.tmp.$$"
      tail -c "$max_bytes" "$file" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; continue; }
      mv -f "$tmp" "$file" 2>/dev/null || true
    fi
  done
}

disk_space_ok() {
  [ "${HLS_MIN_FREE_KB:-0}" -gt 0 ] || [ "${HLS_MIN_FREE_PCT:-0}" -gt 0 ] || return 0

  df_out="$(df -Pk "$OUT_BASE" 2>/dev/null | awk 'NR==2 {print $2, $4}' || true)"
  total_kb="$(printf "%s" "$df_out" | awk '{print $1}' || true)"
  avail_kb="$(printf "%s" "$df_out" | awk '{print $2}' || true)"

  case "$total_kb" in ''|*[!0-9]*) return 0 ;; esac
  case "$avail_kb" in ''|*[!0-9]*) return 0 ;; esac

  if [ "${HLS_MIN_FREE_KB:-0}" -gt 0 ] && [ "$avail_kb" -lt "$HLS_MIN_FREE_KB" ]; then
    log "disk guard: low space on $OUT_BASE (${avail_kb}KB free < ${HLS_MIN_FREE_KB}KB)"
    return 1
  fi

  if [ "${HLS_MIN_FREE_PCT:-0}" -gt 0 ]; then
    free_pct=$((avail_kb * 100 / total_kb))
    if [ "$free_pct" -lt "$HLS_MIN_FREE_PCT" ]; then
      log "disk guard: low space on $OUT_BASE (${free_pct}% free < ${HLS_MIN_FREE_PCT}%)"
      return 1
    fi
  fi

  return 0
}

latest_ts_mtime_in_dir() {
  d="$1"
  newest_m=0
  for f in "$d"/*.ts; do
    [ -e "$f" ] || continue
    m="$(mtime_epoch "$f")"
    case "$m" in ''|*[!0-9]*) continue ;; esac
    if [ "$m" -gt "$newest_m" ]; then
      newest_m="$m"
    fi
  done
  echo "$newest_m"
}

# Return max numeric basename for *.ts in a dir (or -1)
max_ts_number_in_dir() {
  d="$1"
  m=-1

  for f in "$d"/*.ts; do
    [ -e "$f" ] || continue
    b="${f##*/}"
    n="${b%.ts}"
    case "$n" in ''|*[!0-9]*) continue ;; esac

    n="$(echo "$n" | sed 's/^0\{1,\}//')"
    [ -n "$n" ] || n=0

    if [ "$n" -gt "$m" ]; then
      m="$n"
    fi
  done

  echo "$m"
}

next_start_number_global() {
  a="$(max_ts_number_in_dir "$LIVE_DIR")"
  b="$(max_ts_number_in_dir "$OFFLINE_DIR")"

  case "$a" in ''|*[!0-9-]*) a=-1 ;; esac
  case "$b" in ''|*[!0-9-]*) b=-1 ;; esac

  strip0() {
    x="$1"
    case "$x" in
      -*) echo "$x" ;;
      *)
        y="$(echo "$x" | sed 's/^0\{1,\}//')"
        [ -n "$y" ] || y=0
        echo "$y"
        ;;
    esac
  }

  a="$(strip0 "$a")"
  b="$(strip0 "$b")"

  m="$a"
  if [ "$b" -gt "$m" ]; then
    m="$b"
  fi

  if [ "$m" -lt 0 ]; then
    echo 0
  else
    echo $((m + 1))
  fi
}

get_media_seq_file() {
  file="$1"
  [ -r "$file" ] || { echo 0; return; }
  s="$(awk -F: '/^#EXT-X-MEDIA-SEQUENCE:/ { print $2; exit }' "$file" 2>/dev/null \
      | tr -d '\r' | tr -d '[:space:]' || true)"
  case "$s" in ''|*[!0-9]*) echo 0 ;; *) echo "$s" ;; esac
}

wait_for_offline_seq_at_least() {
  want="$1"
  timeout="${2:-10}"
  start="$(date +%s)"

  while :; do
    have="$(get_media_seq_file "$OFFLINE_PLAYLIST")"
    case "$have" in ''|*[!0-9]*) have=0 ;; esac

    if [ -r "$OFFLINE_PLAYLIST" ] && [ "$have" -ge "$want" ]; then
      log "offline ready: have_seq=$have want_seq=$want"
      return 0
    fi

    now="$(date +%s)"
    if [ $((now - start)) -ge "$timeout" ]; then
      log "offline wait timed out: have_seq=$have want_seq=$want"
      return 1
    fi

    sleep 0.2 || true
  done
}

ensure_offline_playlist_stub() {
  [ -d "$OFFLINE_DIR" ] || mkdir -p "$OFFLINE_DIR"

  if [ ! -s "$OFFLINE_PLAYLIST" ]; then
    tmp="${OFFLINE_PLAYLIST}.tmp.$$"
    cat >"$tmp" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:${HLS_TIME}
#EXT-X-MEDIA-SEQUENCE:0
EOF
    mv -f "$tmp" "$OFFLINE_PLAYLIST"
  fi
}

inject_discontinuity_once() {
  file="$1"
  [ -r "$file" ] || return 1

  if grep -q '^#EXT-X-DISCONTINUITY' "$file" 2>/dev/null; then
    return 0
  fi

  tmp="${file}.tmp.$$"

  awk '
    BEGIN { injected=0 }
    {
      print $0
      if (!injected && ($0 ~ /^#EXT-X-MEDIA-SEQUENCE:/ || $0 ~ /^#EXT-X-TARGETDURATION:/)) {
        print "#EXT-X-DISCONTINUITY"
        injected=1
      }
    }
  ' "$file" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }

  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  return 0
}

bump_offline_generator() {
  [ -r "$PID_OFF" ] || return 0
  p="$(cat "$PID_OFF" 2>/dev/null || true)"
  case "$p" in ''|*[!0-9]*) return 0 ;; esac

  log "bump_offline: pidfile=$PID_OFF pid=$p"

  comm="$(ps -o comm= -p "$p" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ "$comm" != "ffmpeg" ]; then
    log "bump_offline: REFUSING to kill pid=$p (comm='$comm' != ffmpeg)"
    return 0
  fi

  log "bumping offline ffmpeg (pid=$p) to reseed segment numbering"
  kill -TERM "$p" 2>/dev/null || true

  i=0
  while kill -0 "$p" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge 30 ] && break
    sleep 0.1 || true
  done
}

prune_segments_best_effort() {
  d="$1"
  [ -n "$KEEP_SEGMENTS" ] || return 0

  # Avoid relying on xargs -r (not always available in busybox).
  files="$(ls -1t "$d"/*.ts 2>/dev/null | awk "NR>${KEEP_SEGMENTS} {print}" || true)"
  [ -n "$files" ] || return 0
  echo "$files" | xargs rm -f 2>/dev/null || true
}

PUBLIC_STATE="offline"
PUBLIC_NEED_DISCONTINUITY=1
PUBLIC_MEDIA_SEQ=0
PUBLIC_DISCONTINUITY_SECONDS="${PUBLIC_DISCONTINUITY_SECONDS:-10}"
PUBLIC_DISCONTINUITY_UNTIL=0
PUBLIC_LAST_SRC_SEQ=0
PUBLIC_LAST_SRC_SEG=""

sync_public_media() {
  case "$PUBLIC_STATE" in
    live)
      src="$LIVE_PLAYLIST"
      prefix="live"
      ;;
    offline)
      src="$OFFLINE_PLAYLIST"
      prefix="offline"
      ;;
    *)
      return 1
      ;;
  esac

  src_seq="$(get_media_seq_file "$src")"
  case "$src_seq" in ''|*[!0-9]*) src_seq=0 ;; esac
  case "$PUBLIC_MEDIA_SEQ" in ''|*[!0-9]*) PUBLIC_MEDIA_SEQ=0 ;; esac
  if [ "$src_seq" -gt "$PUBLIC_MEDIA_SEQ" ]; then
    PUBLIC_MEDIA_SEQ="$src_seq"
  fi

  src_seg="$(awk '!/^#/ && NF { last=$0 } END { if (last) print last }' "$src" 2>/dev/null || true)"

  now="$(date +%s)"
  inject=0
  if [ "$PUBLIC_NEED_DISCONTINUITY" -eq 1 ] || [ "$now" -lt "$PUBLIC_DISCONTINUITY_UNTIL" ]; then
    inject=1
  fi

  case "$PUBLIC_LAST_SRC_SEQ" in ''|*[!0-9]*) PUBLIC_LAST_SRC_SEQ=0 ;; esac
  if [ "$inject" -eq 0 ] && [ "$src_seq" -le "$PUBLIC_LAST_SRC_SEQ" ] && [ "$src_seg" = "$PUBLIC_LAST_SRC_SEG" ]; then
    return 0
  fi

  if write_public_media_from "$src" "$prefix" "$PUBLIC_MEDIA_SEQ" "$inject"; then
    PUBLIC_NEED_DISCONTINUITY=0
    PUBLIC_LAST_SRC_SEQ="$src_seq"
    PUBLIC_LAST_SRC_SEG="$src_seg"
  fi
}

switch_public_to_offline() {
  mkdir -p "$OUT_DIR" 2>/dev/null || true
  PUBLIC_STATE="offline"
  PUBLIC_NEED_DISCONTINUITY=1
  PUBLIC_DISCONTINUITY_UNTIL=$(( $(date +%s) + PUBLIC_DISCONTINUITY_SECONDS ))
  sync_public_media || true
  rm -f "$PUBLIC_LIVE_MARK" 2>/dev/null || true
  log "PUBLIC -> offline"
}

switch_public_to_live() {
  mkdir -p "$OUT_DIR" 2>/dev/null || true
  PUBLIC_STATE="live"
  PUBLIC_NEED_DISCONTINUITY=1
  PUBLIC_DISCONTINUITY_UNTIL=$(( $(date +%s) + PUBLIC_DISCONTINUITY_SECONDS ))
  sync_public_media || true
  : >"$PUBLIC_LIVE_MARK" 2>/dev/null || true
  log "PUBLIC -> live"
}

live_is_fresh() {
  now="$(date +%s)"
  m="$(latest_ts_mtime_in_dir "$LIVE_DIR")"
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  [ "$m" -gt 0 ] || return 1
  [ "$m" -gt "$BOOT_T" ] || return 1
  age=$((now - m))
  [ "$age" -le "$LIVE_FRESH_SECONDS" ]
}

offline_is_fresh() {
  now="$(date +%s)"
  m="$(latest_ts_mtime_in_dir "$OFFLINE_DIR")"
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  [ "$m" -gt 0 ] || return 1

  OFFLINE_FRESH_SECONDS="${OFFLINE_FRESH_SECONDS:-15}"
  age=$((now - m))
  [ "$age" -le "$OFFLINE_FRESH_SECONDS" ]
}

count_playlist_segments() {
  file="$1"
  [ -r "$file" ] || { echo 0; return; }
  n="$(awk '/^#EXTINF:/ { c++ } END { print (c+0) }' "$file" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

live_playlist_ready() {
  min="${LIVE_READY_MIN_SEGMENTS:-2}"

  [ -r "$LIVE_PLAYLIST" ] || return 1

  seq="$(get_media_seq_file "$LIVE_PLAYLIST")"
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  [ "$seq" -gt 0 ] || return 1

  segs="$(count_playlist_segments "$LIVE_PLAYLIST")"
  case "$segs" in ''|*[!0-9]*) segs=0 ;; esac
  [ "$segs" -ge "$min" ] || return 1

  live_is_fresh
}

watch_playlist_or_kill() {
  label="$1"
  pid="$2"
  file="$3"
  max_stall="${4:-20}"
  interval="${5:-2}"
  startup_grace="${6:-30}"

  start_t="$(date +%s)"

  get_media_seq() {
    if [ -r "$file" ]; then
      s="$(awk -F: '/^#EXT-X-MEDIA-SEQUENCE:/ { print $2; exit }' "$file" 2>/dev/null | tr -d '\r' | tr -d '[:space:]' || true)"
      case "$s" in ''|*[!0-9]*) echo 0 ;; *) echo "$s" ;; esac
    else
      echo 0
    fi
  }

  last_m=0
  last_seq=0
  last_t="$start_t"

  while kill -0 "$pid" 2>/dev/null; do
    m="$(mtime_epoch "$file")"
    seq="$(get_media_seq)"
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    now="$(date +%s)"

    if [ "$m" -gt 0 ]; then
      last_m="$m"
      last_seq="$seq"
      last_t="$now"
      break
    fi

    if [ $((now - start_t)) -ge "$startup_grace" ]; then
      log "WATCHDOG($label): playlist never appeared within ${startup_grace}s; killing ffmpeg pid=$pid"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2 || true
      kill -KILL "$pid" 2>/dev/null || true
      return 0
    fi

    sleep "$interval" || true
  done

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$interval" || true

    m="$(mtime_epoch "$file")"
    seq="$(get_media_seq)"
    now="$(date +%s)"

    advanced=0
    if [ "$m" -ne "$last_m" ] && [ "$m" -gt 0 ]; then
      last_m="$m"
      advanced=1
    fi
    if [ "$seq" -ne "$last_seq" ] && [ "$seq" -gt 0 ]; then
      last_seq="$seq"
      advanced=1
    fi

    if [ "$advanced" -eq 1 ]; then
      last_t="$now"
      continue
    fi

    if [ $((now - last_t)) -ge "$max_stall" ]; then
      log "WATCHDOG($label): playlist not advancing (mtime+media-seq) >= ${max_stall}s; killing ffmpeg pid=$pid"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2 || true
      kill -KILL "$pid" 2>/dev/null || true
      return 0
    fi
  done
}

prune_root_ts_legacy() {
  [ -d "$LIVE_DIR" ] || return 0
  [ -d "$OFFLINE_DIR" ] || return 0

  max_age="${PRUNE_ROOT_TS_AGE_SECONDS:-3600}"
  now="$(date +%s)"

  for f in "$OUT_DIR"/*.ts; do
    [ -e "$f" ] || continue
    m="$(mtime_epoch "$f")"
    case "$m" in ''|*[!0-9]*) continue ;; esac
    age=$((now - m))
    if [ "$age" -ge "$max_age" ]; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
}

# --- OFFLINE continuous generator (writes to offline/) ---
run_offline_once() {
  if [ ! -f "$OFFLINE_PNG" ]; then
    log "OFFLINE png missing: $OFFLINE_PNG (offline generator will not start)"
    sleep 5 || true
    return 1
  fi

  START_NUM="$(next_start_number_global)"
  case "$START_NUM" in ''|*[!0-9]*) START_NUM=0 ;; esac

  log "OFFLINE generator starting: $STREAM_KEY (start_number=$START_NUM)"
  : >"$ERR_OFF" || true

  # IMPORTANT:
  # If OFFLINE_PLAYLIST lives inside OFFLINE_DIR (offline/index.m3u8),
  # then segment URIs should be plain filenames (000...ts).
  # Therefore, DO NOT pass -hls_base_url unless you *really* want a prefix.
  OFF_BASE_ARGS=""
  if [ -n "${OFFLINE_BASE_URL:-}" ]; then
    OFF_BASE_ARGS="-hls_base_url ${OFFLINE_BASE_URL}"
  fi

  ffmpeg -hide_banner -loglevel info -stats -stats_period 5 \
    -re \
    -stream_loop -1 -framerate "$OFFLINE_VIDEO_FPS" -i "$OFFLINE_PNG" \
    -f lavfi -i "anullsrc=r=${OFFLINE_AUDIO_RATE}:cl=stereo" \
    -map 0:v:0 -map 1:a:0 -sn -dn \
    -vf "scale=640:-2" \
    -c:v libx264 -preset ultrafast -tune stillimage \
    -crf 28 -maxrate 800k -bufsize 1600k \
    -pix_fmt yuv420p \
    -r "$OFFLINE_VIDEO_FPS" \
    -g $((HLS_TIME * OFFLINE_VIDEO_FPS)) -keyint_min $((HLS_TIME * OFFLINE_VIDEO_FPS)) -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*${HLS_TIME})" \
    -c:a aac -b:a "$OFFLINE_AUDIO_BITRATE" -ar "$OFFLINE_AUDIO_RATE" \
    -f hls \
    -start_number "$START_NUM" \
    -hls_time "$HLS_TIME" -hls_list_size "$HLS_LIST_SIZE" \
    -hls_flags temp_file+independent_segments+omit_endlist+discont_start \
    -hls_allow_cache 0 \
    $OFF_BASE_ARGS \
    -hls_segment_filename "${OFFLINE_DIR}/%013d.ts" \
    "$OFFLINE_PLAYLIST" \
    >>"$ERR_OFF" 2>&1 &
  pid="$!"
  echo "$pid" >"$PID_OFF" 2>/dev/null || true

  watch_playlist_or_kill "offline" "$pid" "$OFFLINE_PLAYLIST" 60 1 15 &
  wpid="$!"
  err_log_watch "$pid" "$ERR_OFF" "$ERR_LOG_MAX_KB" "$ERR_LOG_CHECK_SECONDS" &
  ewpid="$!"

  rc=0
  if wait "$pid"; then rc=0; else rc=$?; fi
  rm -f "$PID_OFF" 2>/dev/null || true
  kill "$wpid" 2>/dev/null || true
  kill "$ewpid" 2>/dev/null || true

  [ "$rc" -eq 0 ] || {
    log "OFFLINE ffmpeg exited rc=$rc (see $ERR_OFF)"
    tail -n 40 "$ERR_OFF" 2>/dev/null || true
  }
  return "$rc"
}


offline_supervisor() {
  off_fail=0
  while :; do
    if ! disk_space_ok; then
      sleep "$DISK_GUARD_SLEEP" || true
      continue
    fi
    if run_offline_once; then
      off_fail=0
    else
      off_fail=$((off_fail + 1))
      log "offline generator failed ($off_fail/${OFFLINE_RETRY_MAX}); retrying"
      tail -n 30 "$ERR_OFF" 2>/dev/null || true

      if [ "$off_fail" -ge "$OFFLINE_RETRY_MAX" ]; then
        log "offline generator failed too many times; backing off"
        off_fail=0
        sleep 5 || true
      else
        sleep "$OFFLINE_RETRY_SECONDS" || true
      fi
    fi
  done
}

# --- LIVE ingest (writes to live/) ---
run_live_once() {
  START_NUM="$(next_start_number_global)"
  case "$START_NUM" in ''|*[!0-9]*) START_NUM=0 ;; esac

  log "LIVE ingest starting: $STREAM_KEY (start_number=$START_NUM)"
  : >"$ERR_LIVE" || true

  # IMPORTANT:
  # If LIVE_PLAYLIST lives inside LIVE_DIR (live/index.m3u8),
  # then segment URIs should be plain filenames (000...ts).
  # Therefore, DO NOT pass -hls_base_url unless you *really* want a prefix.
  LIVE_BASE_ARGS=""
  if [ -n "${LIVE_BASE_URL:-}" ]; then
    LIVE_BASE_ARGS="-hls_base_url ${LIVE_BASE_URL}"
  fi

  STREAM_COPY="${STREAM_COPY:-1}"

  if [ "$STREAM_COPY" = "1" ]; then
    log "LIVE using stream copy (H.264/AAC passthrough)"
    ffmpeg -hide_banner -loglevel info -stats -stats_period 5 \
      -fflags +genpts \
      -rw_timeout 60000000 \
      -analyzeduration 10M -probesize 10M \
      -i "$IN_URL" \
      -map 0:v:0 -map 0:a:0? -sn -dn \
      -c:v copy \
      -c:a copy \
      -f hls \
      -start_number "$START_NUM" \
      -hls_time "$HLS_TIME" -hls_list_size "$HLS_LIST_SIZE" \
      -hls_flags temp_file+independent_segments+omit_endlist+discont_start \
      -hls_allow_cache 0 \
      $LIVE_BASE_ARGS \
      -hls_segment_filename "${LIVE_DIR}/%013d.ts" \
      "$LIVE_PLAYLIST" \
      >>"$ERR_LIVE" 2>&1 &
  else
    log "LIVE using re-encode (libx264/aac)"
    VBV_MAXRATE="${VBV_MAXRATE:-3000k}"
    VBV_BUFSIZE="${VBV_BUFSIZE:-6000k}"

    ffmpeg -hide_banner -loglevel info -stats -stats_period 5 \
      -fflags +genpts \
      -rw_timeout 60000000 \
      -analyzeduration 10M -probesize 10M \
      -i "$IN_URL" \
      -map 0:v:0 -map 0:a:0? -sn -dn \
      -c:v libx264 -preset veryfast -tune zerolatency \
      -b:v "$VBV_MAXRATE" -maxrate "$VBV_MAXRATE" -bufsize "$VBV_BUFSIZE" \
      -g $((HLS_TIME * 30)) -keyint_min $((HLS_TIME * 30)) -sc_threshold 0 \
      -force_key_frames "expr:gte(t,n_forced*${HLS_TIME})" \
      -c:a aac -ar 48000 -b:a 160k \
      -af "aresample=async=1:first_pts=0" \
      -f hls \
      -start_number "$START_NUM" \
      -hls_time "$HLS_TIME" -hls_list_size "$HLS_LIST_SIZE" \
      -hls_flags temp_file+independent_segments+omit_endlist+discont_start \
      -hls_allow_cache 0 \
      $LIVE_BASE_ARGS \
      -hls_segment_filename "${LIVE_DIR}/%013d.ts" \
      "$LIVE_PLAYLIST" \
      >>"$ERR_LIVE" 2>&1 &
  fi

  pid="$!"
  echo "$pid" >"$PID_LIVE" 2>/dev/null || true

  watch_playlist_or_kill "live" "$pid" "$LIVE_PLAYLIST" 60 1 30 &
  wpid="$!"
  err_log_watch "$pid" "$ERR_LIVE" "$ERR_LOG_MAX_KB" "$ERR_LOG_CHECK_SECONDS" &
  ewpid="$!"

  rc=0
  if wait "$pid"; then rc=0; else rc=$?; fi
  rm -f "$PID_LIVE" 2>/dev/null || true
  kill "$wpid" 2>/dev/null || true
  kill "$ewpid" 2>/dev/null || true

  log "LIVE ffmpeg exited rc=$rc (see $ERR_LIVE)"
  tail -n 40 "$ERR_LIVE" 2>/dev/null || true
  return "$rc"
}


live_supervisor() {
  PROBE_INTERVAL="${LIVE_PROBE_INTERVAL:-2}"
  PROBE_TIMEOUT="${LIVE_PROBE_TIMEOUT:-3}"
  PROBE_OK_REQUIRED="${LIVE_PROBE_OK_REQUIRED:-2}"
  PROBE_DISABLED="${LIVE_PROBE_DISABLED:-0}"

  LIVE_FAILFAST_SECONDS="${LIVE_FAILFAST_SECONDS:-5}"
  LIVE_FAILFAST_SLEEP="${LIVE_FAILFAST_SLEEP:-2}"
  LIVE_FAILFAST_SLEEP_MAX="${LIVE_FAILFAST_SLEEP_MAX:-20}"

  failfast_sleep="$LIVE_FAILFAST_SLEEP"

  while :; do
    if ! disk_space_ok; then
      sleep "$DISK_GUARD_SLEEP" || true
      continue
    fi
    probe_ok=0
    if [ "$PROBE_DISABLED" != "1" ]; then
      while [ "$probe_ok" -lt "$PROBE_OK_REQUIRED" ]; do
        if command -v ffprobe >/dev/null 2>&1; then
          if timeout "${PROBE_TIMEOUT}s" ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
            -of default=nw=1:nk=1 "$IN_URL" >/dev/null 2>&1; then
            probe_ok=$((probe_ok + 1))
          else
            probe_ok=0
          fi
        else
          if timeout "${PROBE_TIMEOUT}s" ffmpeg -nostdin -hide_banner -loglevel error -i "$IN_URL" -t 1 -f null - \
            >/dev/null 2>&1; then
            probe_ok=$((probe_ok + 1))
          else
            probe_ok=0
          fi
        fi

        [ "$probe_ok" -ge "$PROBE_OK_REQUIRED" ] && break
        sleep "$PROBE_INTERVAL" || true
      done
    else
      log "live probe disabled; starting ingest without pre-check"
    fi

    start_t="$(date +%s)"
    run_live_once || true
    end_t="$(date +%s)"
    ran_for=$((end_t - start_t))

    if [ "$ran_for" -lt "$LIVE_FAILFAST_SECONDS" ]; then
      log "live ingest exited quickly (${ran_for}s). backoff ${failfast_sleep}s"
      tail -n 40 "$ERR_LIVE" 2>/dev/null || true
      sleep "$failfast_sleep" || true
      failfast_sleep=$((failfast_sleep * 2))
      [ "$failfast_sleep" -gt "$LIVE_FAILFAST_SLEEP_MAX" ] && failfast_sleep="$LIVE_FAILFAST_SLEEP_MAX"
      continue
    fi

    failfast_sleep="$LIVE_FAILFAST_SLEEP"
    sleep "$LIVE_RETRY_SECONDS" || true
  done
}

# --- Swap FSM ---
swap_fsm() {
  state="OFFLINE"
  live_ok=0
  live_stale=0
  offline_until=0

  to_live() {
    inject_discontinuity_once "$LIVE_PLAYLIST" 2>/dev/null || true
    switch_public_to_live
    state="LIVE"
    live_ok=0
  }

  to_offline() {
    live_seq="$(get_media_seq_file "$LIVE_PLAYLIST")"
    case "$live_seq" in ''|*[!0-9]*) live_seq=0 ;; esac
    want=$((live_seq + OFFLINE_READY_SAFETY))

    off_seq="$(get_media_seq_file "$OFFLINE_PLAYLIST")"
    case "$off_seq" in ''|*[!0-9]*) off_seq=0 ;; esac

    log "live->offline: live_seq=$live_seq want_offline_seq>=$want (offline_seq=$off_seq)"

    if [ "$off_seq" -ge "$want" ] && offline_is_fresh; then
      log "live->offline: offline ready; switching immediately"
      switch_public_to_offline
      state="OFFLINE"
      live_ok=0
      offline_until=$(( $(date +%s) + OFFLINE_COOLDOWN_SECONDS ))
      return 0
    fi

    log "live->offline: offline behind/stale; bumping + waiting"
    bump_offline_generator
    wait_for_offline_seq_at_least "$want" "$OFFLINE_READY_TIMEOUT" || true

    switch_public_to_offline
    state="OFFLINE"
    live_ok=0
    offline_until=$(( $(date +%s) + OFFLINE_COOLDOWN_SECONDS ))
  }

  while :; do
    now="$(date +%s)"

    if live_playlist_ready; then
      live_ok=$((live_ok + 1))
    else
      live_ok=0
    fi
    if live_is_fresh; then
      live_stale=0
    else
      live_stale=$((live_stale + 1))
    fi

    case "$state" in
      OFFLINE)
        if [ "$now" -lt "$offline_until" ]; then
          live_ok=0
        fi
        if [ "$live_ok" -ge "$LIVE_CONFIRM_POLLS" ]; then
          to_live
        fi
        ;;
      LIVE)
        stale_need="${LIVE_STALE_CONFIRM_POLLS:-3}"
        if [ "$live_stale" -ge "$stale_need" ]; then
          to_offline
        fi
        ;;
      *)
        log "swap_fsm: unknown state '$state' -> forcing OFFLINE"
        switch_public_to_offline
        state="OFFLINE"
        live_ok=0
        offline_until=$((now + OFFLINE_COOLDOWN_SECONDS))
        ;;
    esac

    sync_public_media || true
    sleep "$SWAP_POLL_SECONDS" || true
  done
}

# --- Boot ---
ensure_offline_playlist_stub
switch_public_to_offline

offline_supervisor &
swap_fsm &
live_supervisor &

while :; do
  prune_segments_best_effort "$LIVE_DIR"
  prune_segments_best_effort "$OFFLINE_DIR"
  prune_root_ts_legacy
  sleep 2 || true
done
