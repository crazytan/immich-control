# Immich Control

A native macOS menu bar application for this Immich installation. It uses the
existing Colima VM, Docker Compose deployment, Restic repositories, and login
Keychain credentials. The application does not contain a second photo library.

## Build and open

Requires macOS 13 or later, the Xcode command line tools with Swift 5.9 or later,
and the existing `colima`, `docker`, and `restic` executables.

```sh
cd macOS
./build-app.sh
open "dist/Immich Control.app"
```

The build creates a locally signed `.app` with an embedded `immich-helper`.
Keep the application at its current location after adopting schedules; scheduled
jobs reference its helper. Rebuilding at the same location updates both together.
Developer ID signing and notarization are separate distribution steps.

To inspect the interface without touching services, credentials, or settings:

```sh
open -n "dist/Immich Control.app" --args --demo
```

## Daily use

- Click the photo stack in the menu bar to see server and destination status.
- Use Start Server, Stop Server, and Open Immich for the local deployment.
- Run an individual cloud or USB backup from its destination row.
- Open Settings to change login behavior, resources, destinations, schedules,
  and retention. Blank credential fields preserve the existing Keychain values.

Opening the app at login and starting the server at login are separate choices.
Stopping Immich leaves Colima running. VM CPU and memory settings apply on a
subsequent Colima start; the existing Compose container limits remain in effect.

The app shows the last successful backup separately from the most recent attempt.
A disconnected USB drive is a skip, and does not imply that a new backup exists.
The app imports completed legacy backup logs when their final recorded event is
a recognized success. Otherwise it shows no recorded success until a native run
completes; it does not infer success from an unrecognized log or a missing drive.

## Background jobs and migration

The root scripts are compatibility entry points into the same native helper used
by the app. Existing LaunchAgents can continue to invoke those paths. A shared
operation lock coordinates server changes with both scheduled and manual backups.

Use **Settings → Backups → Adopt Existing Backup Schedules** to transfer scheduling
to the app-managed LaunchAgent. The migration preserves the previous plists for
recovery and avoids leaving both schedulers active. Once adopted, saving backup
settings updates the LaunchAgent schedules, and the helper reads the saved backup
configuration. The UI does not need to remain open for scheduled backups.
User LaunchAgents run in the logged-in session; they do not make a sleeping or
powered-off Mac into an always-on server.

Non-secret settings live in
`~/Library/Application Support/ImmichControl/Configuration.json`. The initial
import reads this deployment's legacy settings or its ignored `immich.local.json`.
R2 keys and the Restic password remain in the login Keychain under account
`immich-backup`. macOS may request access when a new app/helper first uses them.

Consistent backups stop the Immich application container, create a PostgreSQL
dump, and keep uploads stopped during the Restic snapshot. PostgreSQL stays
running. An interrupted or failed operation attempts to restart Immich if that
operation stopped it. The `--online` compatibility option avoids the pause, with
the same consistency tradeoff as the original scripts. Retention and repository
checks run on Sundays after a successful snapshot.

If the helper is forcibly killed, its recovery record remains. The next server or
backup operation attempts to restart the application container it stopped. A
read-only status check never starts the server.

For recovery of photos and the database, use the root README's restore procedure.
The app does not yet provide a guided restore or Immich version-upgrade workflow.

## Verification

```sh
cd macOS
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
  swift test --disable-sandbox --cache-path "$PWD/.build/cache"
RUN_RESTIC_INTEGRATION=1 ./Tests/restic-smoke.sh
```

The automated suite uses temporary fixtures and injected dependencies. The
optional Restic smoke test creates a disposable local repository and checks a
backup/restore round trip; it does not access the real backup destinations.

## Git hygiene

The repository excludes `.env`, deployment overrides, photos, PostgreSQL files,
logs, backup dumps, and build output. `example.env` contains example values only.
Do not force-add ignored deployment data when preparing a public repository.
