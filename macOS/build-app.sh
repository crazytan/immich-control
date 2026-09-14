#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/dist/Immich Control.app"

cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --cache-path "$ROOT/.build/cache" -c "$BUILD_CONFIGURATION"
BIN="$(swift build --disable-sandbox --cache-path "$ROOT/.build/cache" -c "$BUILD_CONFIGURATION" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/ImmichControl" "$APP/Contents/MacOS/ImmichControl"
cp "$BIN/immich-helper" "$APP/Contents/Helpers/immich-helper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  ICONSET="$ROOT/.build/AppIcon.iconset"
  swift "$ROOT/Resources/generate-icon.swift" "$ICONSET" "$ROOT/Resources/AppIcon.icns"
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# A stable local identity is sufficient for a personal build. Set SIGN_IDENTITY
# to a Developer ID certificate when preparing a notarized distribution.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP/Contents/Helpers/immich-helper"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
