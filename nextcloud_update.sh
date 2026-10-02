#!/usr/bin/env bash
set -euo pipefail
exec python3 "$(dirname "$(readlink -f "$0")")/nextcloud_updater.py" "$@"
