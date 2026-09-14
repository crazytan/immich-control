#!/usr/bin/env bash
set -euo pipefail

TAKEOUT_PATH="${TAKEOUT_PATH:-$HOME/Pictures/Takeout/Google Photos}"
IMMICH_SERVER_URL="${IMMICH_SERVER_URL:-http://localhost:2283}"

if ! command -v immich-go >/dev/null 2>&1; then
  echo "immich-go is not installed or not on PATH." >&2
  exit 1
fi

if [ -z "${IMMICH_API_KEY:-}" ]; then
  echo "Set IMMICH_API_KEY to an Immich API key before importing." >&2
  echo "Example: IMMICH_API_KEY=your-key ./import-google-photos.sh" >&2
  exit 1
fi

if [ ! -d "$TAKEOUT_PATH" ]; then
  echo "Takeout path not found: $TAKEOUT_PATH" >&2
  exit 1
fi

immich-go upload from-google-photos \
  --server="$IMMICH_SERVER_URL" \
  --api-key="$IMMICH_API_KEY" \
  --concurrent-tasks=4 \
  --client-timeout=60m \
  --on-errors=continue \
  --manage-heic-jpeg=StackCoverJPG \
  --manage-raw-jpeg=StackCoverRaw \
  --manage-burst=Stack \
  --session-tag \
  "$TAKEOUT_PATH"
