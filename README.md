# Local Immich Server

## macOS menu bar app

The native **Immich Control** app provides server controls, cloud and USB backup
status, backup scheduling, login options, and settings. See
[the app guide](macOS/README.md) for building, opening, and adopting the existing
schedules. Build it once with `./macOS/build-app.sh`, then open
`macOS/dist/Immich Control.app`.

The command-line entry points below remain available for compatibility with
existing scheduled jobs and call the app's native helper.

This folder contains a Docker Compose Immich server configured for:

- Web/API: <http://localhost:2283>
- Private remote access: Tailscale on port 2283 (after one-time enrollment)
- Upload library: `./library`
- Postgres data: `./postgres`
- Google Photos Takeout source: `~/Pictures/Takeout/Google Photos`

## Start and Stop

```bash
./start-immich.sh
./stop-immich.sh
```

After a reboot, `./start-immich.sh` will start Colima first if needed.

## Private Remote Access with Tailscale

Immich mobile and web clients connect to the Immich API, not directly to
PostgreSQL. The `tailscale` service exposes only the API to devices in the same
tailnet. PostgreSQL remains private to the Docker network, and Tailscale Funnel
(public internet access) is disabled.

One-time setup:

1. Start Immich:

   ```bash
   ./start-immich.sh
   ```

2. Find the Tailscale login URL and open it in a browser:

   ```bash
   docker compose logs tailscale
   ```

3. Approve the new `immich` device if the tailnet requires device approval.
4. Show the private endpoint:

   ```bash
   docker exec immich_tailscale tailscale serve status
   ```

Install Tailscale on the phone or computer, sign in to the same tailnet, and
use `http://immich:2283` (or the full MagicDNS name shown by `tailscale serve
status`) as Immich's server URL. Although the application URL uses HTTP, the
connection between tailnet devices is encrypted by Tailscale. The endpoint is
not available on the public internet, and no router port forwarding is needed.
Tailnet access-control rules still apply; restrict the `immich` device to the
intended users or devices if the tailnet is shared.

The Tailscale node identity is kept in the `immich_tailscale-state` Docker
volume. Do not delete that volume unless you intend to re-enroll this endpoint.

## Cloud Backup

`backup-immich-r2.sh` creates an encrypted, incremental Restic snapshot in the
private Cloudflare R2 bucket `immich-backup`. It includes the PostgreSQL dump,
original assets, profiles, and deployment configuration. Generated thumbnails
and transcoded videos are excluded because Immich can recreate them.

The scheduled backup runs daily at 3:15 AM. It briefly stops `immich-server`
while creating the dump and snapshot so the database and asset files remain in
sync. PostgreSQL stays running. On Sundays it also applies the retention policy
and checks the repository structure.

Run an online backup without stopping Immich (used for the potentially long
initial upload):

```bash
./backup-immich-r2.sh --online
```

Run the same consistent backup used by the schedule:

```bash
./backup-immich-r2.sh
```

The R2 access key, secret key, and Restic repository password are stored in the
login keychain, not in this directory. The Restic password is required for any
restore and should also be copied to a separate password manager.

The Restic S3 backend uses 15 concurrent connections for R2. This primarily
improves large initial or catch-up uploads; ordinary incremental runs remain
small and deduplicated.

### Restore

Load the credentials from Keychain and inspect the available snapshots:

```bash
export AWS_ACCESS_KEY_ID="$(security find-generic-password -a immich-backup -s immich-r2-access-key-id -w)"
export AWS_SECRET_ACCESS_KEY="$(security find-generic-password -a immich-backup -s immich-r2-secret-access-key -w)"
export AWS_DEFAULT_REGION=auto
export RESTIC_PASSWORD="$(security find-generic-password -a immich-backup -s immich-restic-password -w)"
export RESTIC_REPOSITORY="s3:https://9a195cf61a13d2206e23a52b8ae615d6.r2.cloudflarestorage.com/immich-backup/restic"
restic snapshots --tag immich-r2
```

Restore a selected snapshot into an empty staging directory first:

```bash
mkdir -p /path/to/restore-staging
restic restore SNAPSHOT_ID --target /path/to/restore-staging
```

The restored PostgreSQL dump is under
`Users/tan/server/immich-app/library/backups/`. Follow Immich's current backup
and restore documentation when moving the restored asset directories into a
fresh installation and importing that dump. Never restore over the live server
without first preserving its current data.

## USB Backup

`backup-immich-usb.sh` creates a second encrypted, incremental Restic snapshot
on the `MediaUSB` volume. It verifies the volume UUID before writing, so another
volume mounted at `/Volumes/MediaUSB` cannot be mistaken for the backup stick.
If the expected USB volume is absent, the scheduled run logs the skip and exits
without affecting the Cloudflare R2 backup.

The USB backup runs daily at 5:15 AM, after the 3:15 AM R2 backup, and uses the
same protected file set and retention policy. Its repository is stored at
`/Volumes/MediaUSB/ImmichBackup/restic` and uses the Restic password kept in the
login keychain.

Run an online USB backup without stopping Immich:

```bash
./backup-immich-usb.sh --online
```

Run the consistent backup used by the schedule:

```bash
./backup-immich-usb.sh
```

To inspect USB snapshots while the stick is mounted:

```bash
export RESTIC_PASSWORD="$(security find-generic-password -a immich-backup -s immich-restic-password -w)"
export RESTIC_REPOSITORY="/Volumes/MediaUSB/ImmichBackup/restic"
restic snapshots --tag immich-usb
```

## Import Google Photos Takeout

1. Open <http://localhost:2283> and create the first admin account.
2. In Immich, create an API key for that account.
3. Run:

```bash
IMMICH_API_KEY="paste-your-key-here" ./import-google-photos.sh
```

The import script uses `immich-go upload from-google-photos`, which can read your unpacked Takeout folder and preserve Google Photos metadata/albums where the Takeout JSON allows it.
