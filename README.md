# Nextcloud Docker Update Script

## Table of Contents

* [About](#nextcloud-docker-update-script)
* [Features](#features)
* [Why this exists](#why-this-exists)
* [Usage](#usage)
* [Configuration](#configuration)
* [License](#license)

This repository provides a hardened Bash script to safely update Nextcloud installations running in Docker or docker-compose environments.

Unlike simple `docker pull && docker-compose up -d` workflows, this script focuses on **operational safety**: it detects real image changes, prevents accidental downgrades, supports dry-run execution, performs validated backups, and handles common Nextcloud maintenance and upgrade edge cases.

The script is designed for self-hosted environments, including Raspberry Pi systems, where reliability and recoverability are critical.

## Features

* **Safe Docker image updates**

  * Compares running container image with target image by digest
  * Pulls images without downtime before deciding to upgrade
  * Prevents accidental downgrades (configurable override)

* **Dry-run and planning modes**

  * `--dry-run` for full execution preview without changes
  * `--dry-run --pull` to check remote image updates safely
  * `--pull-only` to only refresh images and exit

* **Backup-aware workflow**

  * Database-only or full data + database backups
  * Backup age and image-matching validation
  * Disk space estimation with configurable safety factor
  * Optional skip logic for fresh, matching backups

* **Hardened maintenance handling**

  * Tracks maintenance state enabled by the script
  * Ensures maintenance mode is disabled on errors or exit
  * Graceful recovery from interrupted upgrades

* **Upgrade self-recovery (optional)**

  * Detects common Nextcloud upgrade lock states
  * Optional automatic reset of `maintenance` flag in `config.php`
  * Retry logic for failed upgrades (opt-in)

* **Compose-aware**

  * Automatically reads the Nextcloud image from `docker-compose.yml`
  * Optional controlled update of the compose file
  * No dependency on `yq` or external YAML parsers

* **Operational transparency**

  * Explicit logging for every decision step
  * Clear abort reasons with actionable hints
  * Designed to fail early and safely

## Why this exists

Updating Nextcloud in Docker sounds simple, but in practice it often is not.

Real-world installations regularly run into issues such as:

* Image tags changing without local visibility
* Accidental downgrades when switching between tags (e.g. `stable` vs major tags)
* Incomplete or aborted upgrades leaving Nextcloud stuck in maintenance mode
* Insufficient disk space discovered too late during backups
* Unclear upgrade state after container recreation
* Lack of safe preview or planning before an update

This script was created to address these operational gaps.

Its primary goal is **predictability and recoverability**, not speed.
Every step is designed to answer one question clearly:

> “Is it safe to proceed — and if not, how do I recover?”

If you want a fast update, `docker-compose pull && docker-compose up -d` already exists.
If you want a **defensive, production-oriented update workflow**, this script is for you.

## Usage

Clone and run:

```bash
git clone https://github.com/koeppben23/nextcloud_updater.git
cd nextcloud_updater

# Dry-run without pull
./nextcloud_update.sh --dry-run

# Dry-run with pull
./nextcloud_update.sh --dry-run --pull

# Pull only
./nextcloud_update.sh --pull-only

# Run update with DB-only backups
BACKUP_DATA=0 ./nextcloud_update.sh
```

## Configuration

The updater script supports the following environment variables:

| Variable                      | Default      | Description                                     |
| ----------------------------- | ------------ | ----------------------------------------------- |
| `NEXTCLOUD_IMAGE`             | from compose | Target image tag                                |
| `DRY_RUN`                     | 0            | Show actions without changes                    |
| `PULL_IN_DRY_RUN`             | 0            | Allow pulling in dry-run                        |
| `PULL_ONLY`                   | 0            | Only pull and exit                              |
| `ALLOW_DOWNGRADE`             | 0            | Prevent downgrades                              |
| `AUTO_FIX_CONFIG_MAINTENANCE` | 0            | Auto-fix maintenance lock (disabled by default) |
| `BACKUP_DATA`                 | 1            | Include data backup                             |

## License

This project is licensed under the MIT License.
