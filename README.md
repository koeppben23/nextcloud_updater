# Nextcloud backups and controlled Docker updates

This Linux/Python 3 tool creates **independent full backups**, checks Docker images for updates, and applies an explicitly requested Nextcloud patch update only after a verified backup. It supports the official Nextcloud Apache image and MariaDB 11.4. Docker Compose v2 is required.

The weekly job **does not install updates**. It backs up even when no update exists. Backups on the same USB disk protect against some operator/update failures, **not disk failure, theft or damage**. Keep a separate/off-site copy when possible.

## Backup contents and consistency

Each backup contains:

- `nextcloud.tar`: the entire configured Nextcloud root, including user files, config, apps, versions and trash currently present in that installation.
- `database.sql`: SQL dump produced by `mariadb-dump` (or `mysqldump` fallback).
- `deployment.tar`: compose file, `.env`, and configured deployment files (default: `Caddyfile`).
- `manifest.json`: version, running app/database image IDs, SHA-256 hashes, and the number of tables restored during validation.

Maintenance is enabled, configured workers are stopped, then the app is stopped before dumping the database and archiving files. **Nextcloud is unavailable throughout the backup and verification.** The reverse proxy remains running. On backup failure, the app/workers resume and the previous maintenance state is preserved. External processes must not write directly to the Nextcloud files or database during this window.

A backup becomes `backup-<UTC timestamp>-<id>` only after archive traversal, SQL validation, a full SQL import into an isolated temporary MariaDB container, and hash generation have succeeded. The test container has no network or published ports, uses a 1 GiB RAM-backed database, and is removed afterward. Larger databases may exceed this test limit and fail safely. Failed `.partial-*` directories remain for diagnosis and are never accepted as completed backups.

Archives are uncompressed for predictable performance on a Pi. Expect approximately the full size of the Nextcloud directory per backup. The default keeps three completed backups; old backups are removed **only after** a new backup succeeds and the application resumes. If there is insufficient room for another full backup, the run fails without deleting old backups. Unknown directories, partial backups, symlinks, and backups belonging to another source are never pruned. Failed partial backups may need manual cleanup after inspection.

The USB mount and optionally its UUID are checked before writes. A process lock prevents overlapping runs. There are no database passwords in the updater config: they are read inside the database container from its root-password environment variable. `*_FILE` secret variants are not currently supported. Backup files contain secrets and user data and are owner-only; they are not encrypted at rest.

## Install

On Debian/Raspberry Pi OS with Docker already configured:

```bash
sudo apt-get install python3 python3-yaml tar coreutils util-linux
sudo install -d /opt/nextcloud-updater
sudo install -m 755 nextcloud_update.sh nextcloud_updater.py /opt/nextcloud-updater/
sudo install -m 600 config.example.json /etc/nextcloud-updater.json
```

Edit `/etc/nextcloud-updater.json` for your installation. Paths in the example describe the Fuchscloud deployment:

| Setting | Example/purpose |
| --- | --- |
| `compose_file` | `/opt/fuchscloud/compose.yaml` |
| `nextcloud_root` | `/srv/fuchscloud-disk/live/html`, the **entire** `/var/www/html` bind mount |
| `backup_dir` | `/srv/fuchscloud-disk/full-backups`, outside `nextcloud_root` |
| `required_mount` | `/srv/fuchscloud-disk`, must be a real mounted filesystem |
| `disk_uuid` | Optional expected filesystem UUID; recommended |
| `app_service`, `db_service` | `app`, `db`; container names are discovered from Compose |
| `worker_services` | All services writing to Nextcloud files, e.g. `["cron"]` |
| `database` | `nextcloud` |
| `deployment_files` | Relative files next to Compose, including `.env` and `Caddyfile` |
| `keep_backups` | `3` |
| `check_services` | `["redis", "proxy"]`; app and DB are always checked |
| `pull_timeout`, `startup_timeout` | Bounded waits, in seconds |

Currently the data and backup paths must be under `required_mount`. The tool is intended for this single-disk installation. Supporting a separate backup filesystem requires a separate mount/UUID guard for that destination.

Validate without changing files, pulling images, restarting services, or making backups:

```bash
sudo /opt/nextcloud-updater/nextcloud_update.sh --weekly --dry-run
```

Then install the weekly schedule. Adapt `RequiresMountsFor` in the service if you use another mount path:

```bash
sudo install -m 644 systemd/nextcloud-weekly.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-weekly.timer
```

Runs **Sunday at 03:00 Europe/Berlin**. If the Pi was off, `Persistent=true` causes a catch-up run after it starts. This can mean daytime downtime. The schedule runs directly on the Pi and does not require a Mac or Codex to stay open.

## Commands and reports

```bash
# Start one complete run now (backup, then update check)
sudo systemctl start --no-block nextcloud-weekly.service

# Backup only, or update check only
sudo /opt/nextcloud-updater/nextcloud_update.sh --backup-only
sudo /opt/nextcloud-updater/nextcloud_update.sh --check

# Progress, next scheduled run, last outcome and update candidates
sudo journalctl -u nextcloud-weekly.service -f
systemctl list-timers nextcloud-weekly.timer
sudo cat /var/lib/nextcloud-updater/last-run.json
sudo cat /var/lib/nextcloud-updater/updates.json
```

Reports are local; **no email/push notification is configured**. A failed backup still allows an update check to be attempted, but the service exits as failed. Check timestamps: a failed check must not be mistaken for “up to date”. The check pulls images but does not recreate running containers. It compares the running Nextcloud image with `nextcloud:<current-major>-apache`, so a deployment pinned to a patch release still detects newer patches. Other configured services are compared against their configured tags. New major releases and OS package updates are outside this tool's scope.

## Apply an update deliberately

Use an exact, available patch image in the same major release:

```bash
sudo /opt/nextcloud-updater/nextcloud_update.sh --update --target-image nextcloud:35.0.2-apache
```

The version above is an example, not a promise that it is released. Check the actual update report first. The tool rejects downgrades, major changes and non-versioned target tags. It pulls before downtime, creates a fresh full backup, changes **both app and worker images**, and waits for the official image's entrypoint and HTTP status to confirm the upgrade. Other services are not updated automatically. If an upgrade fails, maintenance stays enabled and workers stay stopped; the tool does not blindly reopen a half-upgraded installation or automatically roll back a migrated database.

Do not use the web updater to update the Docker image. Update database/Redis/Caddy versions separately after reviewing their release notes and creating a backup.

## Restore

Do not extract over a running installation. Keep the broken installation intact until recovery is verified.

1. Stop the app and workers, and keep public access on a maintenance page.
2. Select a completed backup and verify its `sha256` entries in `manifest.json` against all three files. For example, from its directory:
   ```bash
   python3 - <<'PY'
   import hashlib, json
   from pathlib import Path
   manifest = json.loads(Path('manifest.json').read_text())
   assert manifest['format'] == 1 and manifest['complete'] is True
   for name, expected in manifest['sha256'].items():
       with open(name, 'rb') as stream:
           actual = hashlib.file_digest(stream, 'sha256').hexdigest()
       assert actual == expected, name
   print('Checksums verified')
   PY
   ```
3. Extract `deployment.tar` and `nextcloud.tar` into **empty recovery directories**, retaining ownership/permissions. They contain secrets; keep access restricted. Recreate the recorded app/database versions (image IDs are in the manifest; keep those local images or retrieve the matching release).
4. Start an empty MariaDB instance with the backed-up credentials and database name. Import `database.sql` into that empty database. Do not merge it into an existing populated database.
5. Point the recovered Compose bind mounts to the recovered directories. Start the matching app, check `occ status`, then turn off maintenance after validating users/files. Use `occ maintenance:data-fingerprint` when restoring an older state so sync clients can recognize recovery.
6. Start workers, test HTTPS/WebDAV, then reopen public access. Preserve the failed installation until the recovery is confirmed.

The automated SQL restore test verifies database import, **not a complete disaster-recovery rehearsal**. These archives are not a whole-Pi image and do not include OS configuration, Docker image layers, router settings, the original pre-reinstallation files, or files on unlisted external storage. Regenerate HTTPS certificates if needed.

## Changes from the old Bash updater

The previous environment-variable interface (`BACKUP_DATA`, `ALLOW_NO_BACKUP`, `AUTO_FIX_CONFIG_MAINTENANCE`, etc.) is replaced by the JSON configuration and explicit modes. No arguments now mean **check only**, not update. `--dry-run` is genuinely read-only and does not run temporary image containers. Unsupported old flags fail instead of silently enabling a dangerous fallback. There is no “skip backup”, stale-backup reuse, forced downgrade, or automatic maintenance-unlock option.

## Tests

```bash
python3 -m unittest discover -s tests -v
python3 -m py_compile nextcloud_updater.py
shellcheck nextcloud_update.sh
```

The tests cover downtime ordering, recovery after backup errors, preservation of pre-existing maintenance, keeping failed upgrades closed, failed-dump rejection, retention boundaries and version restrictions. Run a real full backup plus the built-in SQL restore test on the target host before relying on the schedule.

## License

MIT, see [LICENSE](LICENSE).
