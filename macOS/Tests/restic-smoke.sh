#!/usr/bin/env bash
# Opt-in integration test for the local Restic binary.
#
# It creates one private temporary repository, backs up a fixture resembling the
# important Immich asset/dump layout, restores it, and compares the restored
# bytes. It never reads the app's .env, Keychain, server files, or repositories.
set -euo pipefail

if [[ "${RUN_RESTIC_INTEGRATION:-}" != "1" ]]; then
  echo "SKIP: set RUN_RESTIC_INTEGRATION=1 to run the Restic smoke test"
  exit 0
fi

restic_bin="${RESTIC_BIN:-/opt/homebrew/bin/restic}"
if [[ ! -x "$restic_bin" ]]; then
  echo "SKIP: Restic was not found at $restic_bin"
  exit 0
fi

umask 077
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/immich-restic-smoke.XXXXXX")"
cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT INT TERM

source_root="$fixture_root/source"
restore_root="$fixture_root/restore"
mkdir -p "$source_root/library/upload" "$source_root/library/backups"
printf 'fixture photo bytes\n' > "$source_root/library/upload/photo.jpg"
printf 'fixture database dump\n' > "$source_root/library/backups/restic-latest.sql.gz"
printf 'services: {}\n' > "$source_root/docker-compose.yml"

export RESTIC_REPOSITORY="$fixture_root/repository"
export RESTIC_PASSWORD="integration-test-password-not-a-user-secret"
cache_dir="$fixture_root/restic-cache"

"$restic_bin" --cache-dir "$cache_dir" init --json > "$fixture_root/init.json"
"$restic_bin" --cache-dir "$cache_dir" backup --json --tag immich-integration \
  "$source_root/library/upload" \
  "$source_root/library/backups" \
  "$source_root/docker-compose.yml" > "$fixture_root/backup.json"
"$restic_bin" --cache-dir "$cache_dir" snapshots --json --tag immich-integration > "$fixture_root/snapshots.json"
"$restic_bin" --cache-dir "$cache_dir" restore latest --target "$restore_root" --tag immich-integration > "$fixture_root/restore.log"

test -s "$fixture_root/snapshots.json"
cmp "$source_root/library/upload/photo.jpg" "$restore_root$source_root/library/upload/photo.jpg"
cmp "$source_root/library/backups/restic-latest.sql.gz" "$restore_root$source_root/library/backups/restic-latest.sql.gz"
cmp "$source_root/docker-compose.yml" "$restore_root$source_root/docker-compose.yml"

echo "PASS: Restic backup and restore round trip succeeded"
