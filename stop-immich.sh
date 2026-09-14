#!/bin/bash
set -euo pipefail

# Compatibility entry point; Immich Control owns orchestration and locking.
IMMICH_PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$IMMICH_PROJECT_ROOT/macOS/run-helper.sh" server stop "$@"
