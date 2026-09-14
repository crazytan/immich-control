#!/bin/bash
set -euo pipefail

IMMICH_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMMICH_HELPER_PATH="$IMMICH_PROJECT_ROOT/macOS/dist/Immich Control.app/Contents/Helpers/immich-helper"
if [[ ! -x "$IMMICH_HELPER_PATH" ]]; then
  printf 'Immich Control has not been built. Run: %s/macOS/build-app.sh\n' "$IMMICH_PROJECT_ROOT" >&2
  exit 1
fi
exec "$IMMICH_HELPER_PATH" --root "$IMMICH_PROJECT_ROOT" "$@"
