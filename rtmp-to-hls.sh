#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET="${SCRIPT_DIR}/rtmp-to-hls.posix.sh"

if [ ! -x "$TARGET" ]; then
  echo "rtmp-to-hls.posix.sh not found or not executable: $TARGET" >&2
  exit 1
fi

exec "$TARGET" "$@"
