#!/bin/bash
# Nextcloud Docker Update Script (Raspberry Pi)
#
# Hardened:
# - Reads NEXTCLOUD_IMAGE from docker-compose.yml (service "app") if not set
# - Optional compose update (UPDATE_COMPOSE_IMAGE=1)
# - Consistent image ID comparison (sha256)
# - DRY_RUN: no mutations
# - DRY_RUN + Pull supported (--pull / PULL_IN_DRY_RUN=1)
# - PULL_ONLY mode (--pull-only) to only pull and exit
# - Pull timeout + optional live output (tee)
# - Downgrade protection (ALLOW_DOWNGRADE=1 to override)
# - Robust maintenance handling:
#   * tracks if script enabled maintenance
#   * EXIT trap attempts to disable maintenance if script enabled it
#   * on upgrade failure, prints actionable recovery hints
# - Optional AUTO_FIX_CONFIG_MAINTENANCE=1:
#   * if occ upgrade indicates "remove maintenance mode from config.php",
#     script will flip 'maintenance' => false in host config.php and retry once
#
# Usage:
#   ./nextcloud_update.sh
#   ./nextcloud_update.sh --dry-run
#   ./nextcloud_update.sh --dry-run --pull
#   ./nextcloud_update.sh --pull-only
#
# Stand: 2026-01-21

set -Eeuo pipefail

# ========================
# CLI
# ========================
DRY_RUN="${DRY_RUN:-0}"
PULL_IN_DRY_RUN="${PULL_IN_DRY_RUN:-0}"
PULL_ONLY="${PULL_ONLY:-0}"

for arg in "${@:-}"; do
  case "$arg" in
    --dry-run|--probe|--probelauf) DRY_RUN=1 ;;
    --pull) PULL_IN_DRY_RUN=1 ;;
    --pull-only) PULL_ONLY=1 ;;
    --help|-h)
      cat <<'EOF'
Usage:
  ./nextcloud_update.sh [--dry-run] [--pull] [--pull-only]

Options:
  --dry-run     Probelauf: keine Änderungen (kein backup, kein restart, kein maintenance)
  --pull        Nur sinnvoll mit --dry-run: erlaubt docker-compose pull zur Statusprüfung
  --pull-only   Führt nur docker-compose pull (app) aus und beendet (kein Backup/Upgrade)

Env:
  NEXTCLOUD_IMAGE=nextcloud:32        Override Zielimage
  UPDATE_COMPOSE_IMAGE=0|1            compose.yml anpassen (default 0)
  ALLOW_DOWNGRADE=0|1                 Downgrade erlauben (default 0)

  DRY_RUN=0|1
  PULL_IN_DRY_RUN=0|1
  PULL_ONLY=0|1

  PULL_TIMEOUT_SECONDS=600            Timeout für Pull (default 600s)
  PULL_VERBOSE=1                      1=zeige Pull-Output live (tee), 0=nur logfile
  PULL_LOG=/tmp/docker_pull.log

  AUTO_FIX_CONFIG_MAINTENANCE=0|1     (default 0) Auto-Fix config.php maintenance->false bei Upgrade-Lock Hinweis
  HOST_NC_ROOT=/mnt/t7/nextcloud      Host-Pfad zum Nextcloud root (enthält config/config.php)

  APP_CONTAINER=nextcloud_app
  DB_CONTAINER=nextcloud_db
  DATA_DIR=/mnt/t7/nextcloud
  BACKUP_DIR=/path/to/backup
  COMPOSE_APP_SERVICE=app

  DB_USER=nextcloud
  DB_PASS=nextcloud
  DB_NAME=nextcloud

  BACKUP_MAX_AGE_HOURS=24
  BACKUP_SKIP_IF_FRESH=1
  BACKUP_FORCE=0
  BACKUP_REQUIRE_SAME_IMAGE=1
  BACKUP_DATA=1
  ALLOW_NO_BACKUP=0
  BACKUP_SPACE_FACTOR=1.2
EOF
      exit 0
      ;;
  esac
done

# ========================
# Konfiguration
# ========================
APP_CONTAINER="${APP_CONTAINER:-nextcloud_app}"
DB_CONTAINER="${DB_CONTAINER:-nextcloud_db}"

# In deinem Setup ist /mnt/t7/nextcloud sowohl DATA_DIR als auch Nextcloud root (volume -> /var/www/html)
DATA_DIR="${DATA_DIR:-/mnt/t7/nextcloud}"
HOST_NC_ROOT="${HOST_NC_ROOT:-$DATA_DIR}"

BACKUP_DIR_DEFAULT="$HOME/nextcloud-backup-$(date +%F)"
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
COMPOSE_APP_SERVICE="${COMPOSE_APP_SERVICE:-app}"

DB_USER="${DB_USER:-nextcloud}"
DB_PASS="${DB_PASS:-nextcloud}"
DB_NAME="${DB_NAME:-nextcloud}"

BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-24}"
BACKUP_SKIP_IF_FRESH="${BACKUP_SKIP_IF_FRESH:-1}"
BACKUP_FORCE="${BACKUP_FORCE:-0}"
BACKUP_REQUIRE_SAME_IMAGE="${BACKUP_REQUIRE_SAME_IMAGE:-1}"
BACKUP_DATA="${BACKUP_DATA:-1}"
ALLOW_NO_BACKUP="${ALLOW_NO_BACKUP:-0}"
BACKUP_SPACE_FACTOR="${BACKUP_SPACE_FACTOR:-1.2}"

ALLOW_DOWNGRADE="${ALLOW_DOWNGRADE:-0}"
UPDATE_COMPOSE_IMAGE="${UPDATE_COMPOSE_IMAGE:-0}"

PULL_TIMEOUT_SECONDS="${PULL_TIMEOUT_SECONDS:-600}"
PULL_VERBOSE="${PULL_VERBOSE:-1}"
PULL_LOG="${PULL_LOG:-/tmp/docker_pull.log}"

AUTO_FIX_CONFIG_MAINTENANCE="${AUTO_FIX_CONFIG_MAINTENANCE:-0}"

# ========================
# Helpers
# ========================
log() { printf "\n==> %s\n" "$*"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "❌ $1 fehlt. Bitte installieren."; exit 1; }; }

# Mutierende Commands: im DRY_RUN nur anzeigen
run_mut() {
  if [[ "$DRY_RUN" = "1" ]]; then
    echo "[DRY-RUN][SKIP-MUT] $*"
    return 0
  fi
  "$@"
}

occ_ro() { docker exec -u www-data -w /var/www/html "$APP_CONTAINER" php occ "$@"; }
occ_mut() {
  if [[ "$DRY_RUN" = "1" ]]; then
    echo "[DRY-RUN][SKIP-MUT] docker exec -u www-data -w /var/www/html $APP_CONTAINER php occ $*"
    return 0
  fi
  docker exec -u www-data -w /var/www/html "$APP_CONTAINER" php occ "$@"
}

current_app_image_id() { docker inspect -f '{{.Image}}' "$APP_CONTAINER" 2>/dev/null || true; }
tag_image_id_local() { docker image inspect -f '{{.Id}}' "$NEXTCLOUD_IMAGE" 2>/dev/null || true; }

image_nc_version() {
  docker run --rm "$1" php -r '
    foreach (["/var/www/html/version.php","/usr/src/nextcloud/version.php"] as $p) {
      if (file_exists($p)) { include $p;
        echo isset($OC_VersionString) ? $OC_VersionString : implode(".", $OC_Version);
        exit;
      }
    }
  ' 2>/dev/null || true
}

compose_app_image() {
  awk '
    $1=="services:" {ins=1; next}
    ins && $1=="app:" {inapp=1; next}
    ins && inapp && $1=="image:" {print $2; exit}
    ins && inapp && $1 ~ /^[a-zA-Z0-9_-]+:$/ && $1!="app:" {exit}
  ' docker-compose.yml | tr -d "\r"
}

ver_gt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]; }

compose_pull_app() {
  local svc="$COMPOSE_APP_SERVICE"
  log "docker-compose pull $svc (timeout: ${PULL_TIMEOUT_SECONDS}s, log: $PULL_LOG)"
  if [[ "$DRY_RUN" = "1" && "$PULL_IN_DRY_RUN" != "1" ]]; then
    echo "[DRY-RUN] pull übersprungen (PULL_IN_DRY_RUN=0)"
    return 0
  fi
  if [[ "$PULL_VERBOSE" = "1" ]]; then
    if ! timeout "$PULL_TIMEOUT_SECONDS" docker-compose pull "$svc" 2>&1 | tee "$PULL_LOG"; then
      echo "❌ Pull fehlgeschlagen oder Timeout. Siehe Log: $PULL_LOG"
      return 1
    fi
  else
    if ! timeout "$PULL_TIMEOUT_SECONDS" docker-compose pull "$svc" >"$PULL_LOG" 2>&1; then
      echo "❌ Pull fehlgeschlagen oder Timeout. Siehe Log: $PULL_LOG"
      return 1
    fi
  fi
}

# Maintenance handling (hardened)
MAINTENANCE_WAS_ENABLED_BY_SCRIPT=0

enable_maintenance() {
  log "Wartungsmodus aktivieren..."
  if occ_mut maintenance:mode --on; then
    MAINTENANCE_WAS_ENABLED_BY_SCRIPT=1
    return 0
  fi
  echo "❌ Konnte Wartungsmodus nicht aktivieren. Abbruch."
  return 1
}

disable_maintenance_best_effort() {
  # Always best-effort; never fail hard here.
  if [[ "$DRY_RUN" = "1" ]]; then
    echo "[DRY-RUN] maintenance off (skip)"
    return 0
  fi
  occ_mut maintenance:mode --off >/dev/null 2>&1 || true
  MAINTENANCE_WAS_ENABLED_BY_SCRIPT=0
}

host_config_path() {
  echo "$HOST_NC_ROOT/config/config.php"
}

auto_fix_config_maintenance_false() {
  local cfg
  cfg="$(host_config_path)"
  if [[ "$AUTO_FIX_CONFIG_MAINTENANCE" != "1" ]]; then
    return 1
  fi
  if [[ ! -f "$cfg" ]]; then
    echo "⚠️  AUTO_FIX_CONFIG_MAINTENANCE=1, aber config.php nicht gefunden: $cfg"
    return 1
  fi
  log "AUTO_FIX: Setze 'maintenance' => false in $cfg"
  sudo sed -i "s/'maintenance'[[:space:]]*=>[[:space:]]*\(true\|false\)/'maintenance' => false/" "$cfg" || return 1
  return 0
}

# Upgrade wrapper with recovery hints + optional auto-fix
occ_upgrade_hardened() {
  local out rc
  out="$({ occ_mut upgrade --no-interaction; } 2>&1)" || rc=$? || true
  rc="${rc:-0}"

  if [[ "$rc" -eq 0 ]]; then
    echo "$out"
    return 0
  fi

  echo "$out"
  echo "❌ occ upgrade fehlgeschlagen (rc=$rc)."

  # Common lock hint
  if echo "$out" | grep -qiE "Maybe an upgrade is already in process|remove the \"maintenance mode\" from config\.php|remove the maintenance mode from config\.php"; then
    echo
    echo "Hinweis: Nextcloud meldet einen Upgrade-Lock / Maintenance-State."
    echo " - Prüfe Log: $HOST_NC_ROOT/data/nextcloud.log"
    echo " - Prüfe config.php: $(host_config_path)"
    echo

    # Optional auto-fix and retry once
    if [[ "$AUTO_FIX_CONFIG_MAINTENANCE" = "1" ]]; then
      if auto_fix_config_maintenance_false; then
        echo "AUTO_FIX erfolgreich. Starte Container neu und versuche Upgrade 1x erneut..."
        docker-compose up -d >/dev/null 2>&1 || true
        sleep 3
        local out2 rc2
        out2="$({ occ_mut upgrade --no-interaction; } 2>&1)" || rc2=$? || true
        rc2="${rc2:-0}"
        echo "$out2"
        if [[ "$rc2" -eq 0 ]]; then
          return 0
        fi
        echo "❌ occ upgrade nach AUTO_FIX erneut fehlgeschlagen (rc=$rc2). Bitte Log prüfen."
      else
        echo "AUTO_FIX nicht erfolgreich (keine Änderung möglich). Bitte manuell prüfen."
      fi
    fi
  fi

  return 1
}

# Hardened traps:
on_err() {
  echo
  echo "❌ Fehler aufgetreten."
  # Best-effort maintenance rollback if we enabled it
  if [[ "$MAINTENANCE_WAS_ENABLED_BY_SCRIPT" = "1" ]]; then
    echo "   Script hatte Wartungsmodus aktiviert. Versuche Wartungsmodus zu deaktivieren (best effort)..."
    disable_maintenance_best_effort
  fi
}
on_exit() {
  # EXIT is always executed: ensure we don't leave maintenance on if we enabled it
  if [[ "$DRY_RUN" != "1" && "$MAINTENANCE_WAS_ENABLED_BY_SCRIPT" = "1" ]]; then
    echo
    echo "==> Exit-Härtung: Wartungsmodus war vom Script aktiv – setze ihn zurück (best effort)..."
    disable_maintenance_best_effort
  fi
}
trap on_err ERR
trap on_exit EXIT

# ========================
# Preflight
# ========================
require_cmd docker
require_cmd docker-compose
require_cmd pv
require_cmd awk
require_cmd sed
require_cmd tar
require_cmd gzip
require_cmd du
require_cmd df
require_cmd date
require_cmd sort
require_cmd timeout
require_cmd tee

if [[ ! -f docker-compose.yml ]]; then
  echo "❌ docker-compose.yml nicht gefunden (aktuelles Verzeichnis)."
  exit 1
fi

log "DRY_RUN: $DRY_RUN (PULL_IN_DRY_RUN=$PULL_IN_DRY_RUN) | PULL_ONLY=$PULL_ONLY"
log "UPDATE_COMPOSE_IMAGE: $UPDATE_COMPOSE_IMAGE  |  ALLOW_DOWNGRADE: $ALLOW_DOWNGRADE"
log "PULL_VERBOSE=$PULL_VERBOSE  PULL_TIMEOUT_SECONDS=$PULL_TIMEOUT_SECONDS  PULL_LOG=$PULL_LOG"
log "AUTO_FIX_CONFIG_MAINTENANCE=$AUTO_FIX_CONFIG_MAINTENANCE  HOST_NC_ROOT=$HOST_NC_ROOT"

# ========================
# Ziel-Image bestimmen
# ========================
if [[ -z "${NEXTCLOUD_IMAGE:-}" ]]; then
  NEXTCLOUD_IMAGE="$(compose_app_image || true)"
fi
if [[ -z "${NEXTCLOUD_IMAGE:-}" ]]; then
  echo "❌ Konnte NEXTCLOUD_IMAGE nicht bestimmen (weder ENV noch compose app.image)."
  exit 1
fi
log "Ziel-Image: $NEXTCLOUD_IMAGE"

# Optional: compose.yml setzen (nur wenn gewünscht)
if [[ "$UPDATE_COMPOSE_IMAGE" = "1" ]]; then
  log "docker-compose.yml Image für Service '$COMPOSE_APP_SERVICE' setzen: $NEXTCLOUD_IMAGE"
  run_mut sed -i "s|^[[:space:]]*image:[[:space:]]*nextcloud:.*|    image: $NEXTCLOUD_IMAGE|" docker-compose.yml
else
  log "docker-compose.yml wird nicht verändert (UPDATE_COMPOSE_IMAGE=0)."
fi

# ========================
# Pull-only Mode
# ========================
if [[ "$PULL_ONLY" = "1" ]]; then
  log "PULL_ONLY aktiv: führe nur Pull aus und beende."
  compose_pull_app
  echo "✅ Pull abgeschlossen (oder best-effort)."
  exit 0
fi

# ========================
# Laufende Version + Zielversion (READ-ONLY)
# ========================
CURRENT_NC_VER="$(occ_ro status 2>/dev/null | awk -F': ' '/versionstring:/{print $2; exit}' || true)"
log "Laufende Nextcloud-Version: ${CURRENT_NC_VER:-unbekannt}"

IMAGE_NC_VER_BEFORE_PULL="$(image_nc_version "$NEXTCLOUD_IMAGE")"
log "Im Image ($NEXTCLOUD_IMAGE) enthaltene Version (best effort, vor Pull): ${IMAGE_NC_VER_BEFORE_PULL:-unbekannt}"

# Downgrade-Schutz (vor Pull)
if [[ -n "${CURRENT_NC_VER:-}" && -n "${IMAGE_NC_VER_BEFORE_PULL:-}" ]]; then
  if ver_gt "$CURRENT_NC_VER" "$IMAGE_NC_VER_BEFORE_PULL" && [[ "$ALLOW_DOWNGRADE" != "1" ]]; then
    echo "❌ Downgrade-Schutz: Ziel-Image ist älter als die laufende Installation (vor Pull)."
    echo "   Laufend: $CURRENT_NC_VER"
    echo "   Image:   $IMAGE_NC_VER_BEFORE_PULL"
    echo "   Abbruch. (Nur mit ALLOW_DOWNGRADE=1 möglich – nicht empfohlen.)"
    exit 1
  fi
fi

# ========================
# Pull + Image-ID Vergleich
# ========================
RUNNING_IMAGE_ID="$(current_app_image_id)"

if [[ "$DRY_RUN" = "1" ]]; then
  if [[ "$PULL_IN_DRY_RUN" = "1" ]]; then
    log "DRY_RUN: Pull ist erlaubt (--pull)."
    compose_pull_app
  else
    log "DRY_RUN: kein Pull. Vergleich gegen lokal vorhandenes Image."
  fi
else
  log "Prüfe, ob ein neues Image verfügbar ist (docker pull, ohne Downtime)..."
  compose_pull_app
fi

TAG_IMAGE_ID_AFTER="$(tag_image_id_local)"
if [[ -z "${TAG_IMAGE_ID_AFTER:-}" ]]; then
  echo "❌ Ziel-Image '$NEXTCLOUD_IMAGE' ist lokal nicht vorhanden (oder inspect fehlgeschlagen)."
  echo "   Prüfe Pull-Log: $PULL_LOG"
  exit 1
fi

IMAGE_NC_VER_AFTER_PULL="$(image_nc_version "$NEXTCLOUD_IMAGE")"
log "Im Image ($NEXTCLOUD_IMAGE) enthaltene Version (best effort, nach Pull): ${IMAGE_NC_VER_AFTER_PULL:-unbekannt}"

# Downgrade-Schutz (nach Pull, entscheidend)
if [[ -n "${CURRENT_NC_VER:-}" && -n "${IMAGE_NC_VER_AFTER_PULL:-}" ]]; then
  if ver_gt "$CURRENT_NC_VER" "$IMAGE_NC_VER_AFTER_PULL" && [[ "$ALLOW_DOWNGRADE" != "1" ]]; then
    echo "❌ Downgrade-Schutz: Ziel-Image ist älter als die laufende Installation (nach Pull)."
    echo "   Laufend: $CURRENT_NC_VER"
    echo "   Image:   $IMAGE_NC_VER_AFTER_PULL"
    echo "   Abbruch. (Nur mit ALLOW_DOWNGRADE=1 möglich – nicht empfohlen.)"
    exit 1
  fi
fi

# Entscheidung: Update nötig?
if [[ -n "${RUNNING_IMAGE_ID:-}" && "$RUNNING_IMAGE_ID" != "$TAG_IMAGE_ID_AFTER" ]]; then
  log "Image-Differenz erkannt (running != target). Update wäre erforderlich."
else
  log "Kein neueres Image relativ zum laufenden Container."
  echo "✅ Nichts zu tun."
  exit 0
fi

# DRY_RUN Ende
if [[ "$DRY_RUN" = "1" ]]; then
  echo
  echo "✅ DRY_RUN beendet nach erfolgreicher Analyse."
  echo "   Ergebnis: Update wäre notwendig (Image-Differenz erkannt)."
  if [[ "$PULL_IN_DRY_RUN" = "1" ]]; then
    echo "   Pull wurde ausgeführt. Log: $PULL_LOG"
  else
    echo "   Hinweis: Für Remote-Prüfung nutze --pull."
  fi
  exit 0
fi

# ========================
# Backup-Skip-Logik
# ========================
should_skip_backup() {
  [[ "$BACKUP_FORCE" = "1" ]] && return 1
  [[ "$BACKUP_SKIP_IF_FRESH" = "1" ]] || return 1
  [[ -s "$BACKUP_DIR/nextcloud-db.sql" ]] || return 1
  if [[ "$BACKUP_DATA" = "1" ]]; then
    [[ -s "$BACKUP_DIR/nextcloud-data.tar.gz" ]] || return 1
  fi

  local cutoff db_mtime data_mtime
  cutoff="$(date -d "-${BACKUP_MAX_AGE_HOURS} hours" +%s 2>/dev/null || true)"
  [[ -n "$cutoff" ]] || return 1

  db_mtime="$(date -r "$BACKUP_DIR/nextcloud-db.sql" +%s)"
  [[ "$db_mtime" -ge "$cutoff" ]] || return 1

  if [[ "$BACKUP_DATA" = "1" ]]; then
    data_mtime="$(date -r "$BACKUP_DIR/nextcloud-data.tar.gz" +%s)"
    [[ "$data_mtime" -ge "$cutoff" ]] || return 1
  fi

  if [[ "$BACKUP_REQUIRE_SAME_IMAGE" = "1" ]]; then
    local cur_app_img_id meta_img_id
    cur_app_img_id="$(current_app_image_id)"
    if [[ -s "$BACKUP_DIR/backup.meta" ]]; then
      meta_img_id="$(awk -F'=' '/^app_image_id=/{print $2}' "$BACKUP_DIR/backup.meta" | tr -d '\r')"
      [[ -n "$meta_img_id" && -n "$cur_app_img_id" && "$meta_img_id" = "$cur_app_img_id" ]] || return 1
    else
      return 1
    fi
  fi

  return 0
}

if should_skip_backup; then
  log "Frische & passende Backups gefunden (<${BACKUP_MAX_AGE_HOURS}h) – Backups werden übersprungen."
  SKIP_BACKUP=1
else
  SKIP_BACKUP=0
fi

# ========================
# Backups
# ========================
if [[ "$SKIP_BACKUP" = "0" ]]; then
  mkdir -p "$BACKUP_DIR"

  log "Sichere docker-compose.yml ..."
  cp docker-compose.yml "$BACKUP_DIR/docker-compose.yml.bak"

  log "Datenbankgröße ermitteln..."
  DB_SIZE_BYTES="$(docker exec -i "$DB_CONTAINER" sh -lc \
    "mysql -u$DB_USER -p$DB_PASS -Nse \"SELECT IFNULL(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema='$DB_NAME';\" 2>/dev/null || echo 0"
  )"
  DB_SIZE_BYTES="${DB_SIZE_BYTES:-0}"
  echo "   geschätzte DB-Größe: $DB_SIZE_BYTES Bytes"

  DIR_SIZE=0
  if [[ "$BACKUP_DATA" = "1" ]]; then
    log "Datenverzeichnisgröße ermitteln..."
    DIR_SIZE="$(du -sb "$DATA_DIR" | awk '{print $1}' || echo 0)"
    DIR_SIZE="${DIR_SIZE:-0}"
    echo "   Datenverzeichnis: $DIR_SIZE Bytes"
  fi

  calc_dir="$DIR_SIZE"
  if [[ "$BACKUP_DATA" != "1" ]]; then
    calc_dir=0
  fi

  AVAIL_BYTES="$(df -P -B1 "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
  REQ_BYTES=$(awk -v db="$DB_SIZE_BYTES" -v dir="$calc_dir" -v f="$BACKUP_SPACE_FACTOR" 'BEGIN{printf "%.0f",(db+dir)*f}')
  echo "   verfügbarer Platz: $AVAIL_BYTES Bytes, benötigt (geschätzt): $REQ_BYTES Bytes"
  if [[ "$AVAIL_BYTES" -lt "$REQ_BYTES" ]]; then
    if [[ "$ALLOW_NO_BACKUP" = "1" ]]; then
      echo "⚠️  Nicht genug Platz, aber ALLOW_NO_BACKUP=1 gesetzt – fahre OHNE Backups fort."
      SKIP_BACKUP=1
    else
      echo "❌ Nicht genug freier Platz im Ziel-Dateisystem für Backups."
      echo "   Tipp: BACKUP_DIR auf /mnt/t7 legen oder BACKUP_DATA=0."
      exit 1
    fi
  fi

  if [[ "$SKIP_BACKUP" = "0" ]]; then
    log "Datenbank sichern..."
    if [[ "$DB_SIZE_BYTES" -gt 0 ]]; then
      docker exec -i "$DB_CONTAINER" mysqldump \
        --single-transaction --quick --routines --events \
        -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
        | pv -s "$DB_SIZE_BYTES" > "$BACKUP_DIR/nextcloud-db.sql"
    else
      docker exec -i "$DB_CONTAINER" mysqldump \
        --single-transaction --quick --routines --events \
        -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
        | pv > "$BACKUP_DIR/nextcloud-db.sql"
    fi

    if [[ "$BACKUP_DATA" = "1" ]]; then
      log "Datenverzeichnis sichern..."
      tar -cf - -C "$DATA_DIR" . | pv -s "$DIR_SIZE" | gzip > "$BACKUP_DIR/nextcloud-data.tar.gz"
    else
      log "Datenverzeichnis-Backup übersprungen (BACKUP_DATA=0)."
    fi

    APP_IMG_ID_BEFORE="$(current_app_image_id)"
    {
      echo "created=$(date -Iseconds)"
      echo "app_image_id=${APP_IMG_ID_BEFORE}"
    } > "$BACKUP_DIR/backup.meta"
  fi
else
  log "Backups werden übersprungen."
fi

# ========================
# Maintenance / Restart / Upgrade
# ========================
enable_maintenance

log "Container neu starten..."
docker-compose up -d

log "Warten bis Nextcloud/DB bereit sind..."
until occ_ro status >/dev/null 2>&1; do
  echo "   warte auf Nextcloud/DB …"
  sleep 3
done

log "Upgrade/Repair..."
if ! occ_upgrade_hardened; then
  echo "Abbruch: occ upgrade konnte nicht abgeschlossen werden."
  echo "Hinweis: Prüfe Log: $HOST_NC_ROOT/data/nextcloud.log"
  exit 1
fi

occ_mut db:add-missing-indices || true
occ_mut maintenance:repair || true

disable_maintenance_best_effort

log "Apps aktualisieren (optional)..."
occ_mut app:update --all || true

FINAL_NC_VER="$(occ_ro status 2>/dev/null | awk -F': ' '/versionstring:/{print $2; exit}' || true)"
log "Final installierte Nextcloud-Version: ${FINAL_NC_VER:-unbekannt}"

echo
echo "✅ Update abgeschlossen!"
echo "   Vorher: ${CURRENT_NC_VER:-unbekannt}"
echo "   Image:  ${IMAGE_NC_VER_AFTER_PULL:-unbekannt}"
echo "   Jetzt:  ${FINAL_NC_VER:-unbekannt}"
echo "   Backup-Ort: $BACKUP_DIR"

