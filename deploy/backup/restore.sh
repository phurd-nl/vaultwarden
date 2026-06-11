#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore a chosen backup set produced by backup.sh.
#
# NIST 800-53B Moderate: CP-10 (System Recovery & Reconstitution),
# CP-9 (backups are usable — restore is the tested half of the control),
# SC-28 (artifacts decrypted only into a transient 0700 staging dir).
#
# *** DESTRUCTIVE ***
#   --do-db    runs `pg_restore --clean` and OVERWRITES the live "vaultwarden"
#              database (objects are dropped then recreated).
#   --do-data  REPLACES the contents of the nextvault-data volume (attachments, sends,
#              config.json, rsa_key.pem, rsa_key.pub.pem).
# Neither runs without an explicit flag AND an interactive typed confirmation
# (override with FORCE=1 only for tested, isolated environments).
#
# RECOMMENDED ORDER OF OPERATIONS (see README "Test-restore procedure"):
#   1. Restore into an ISOLATED environment first (separate volume / DB name).
#   2. Validate.  3. Only then restore production, with a rollback snapshot.
# =============================================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------
BACKUP_DEST="${BACKUP_DEST:-./backups}"
PG_CONTAINER="${PG_CONTAINER:-nextvault-postgres}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
PG_DB="${PG_DB:-vaultwarden}"
DATA_VOLUME="${DATA_VOLUME:-nextvault-data}"
BACKUP_KEY_SECRET="${BACKUP_KEY_SECRET:-vw_backup_key}"
HELPER_IMAGE="${HELPER_IMAGE:-docker.io/library/postgres:17.10}"
FORCE="${FORCE:-0}"

DO_DB=0
DO_DATA=0
SET_ARG=""

usage() {
  cat <<EOF
Usage: restore.sh [--set <timestamp|latest>] [--do-db] [--do-data] [--list]

  --set <id>   Backup set under \$BACKUP_DEST (e.g. 20260609T031700Z or 'latest').
               Defaults to 'latest'.
  --do-db      DESTRUCTIVE: pg_restore --clean into database "$PG_DB".
  --do-data    DESTRUCTIVE: replace contents of volume "$DATA_VOLUME".
  --list       List available backup sets and exit.

Environment: BACKUP_DEST PG_CONTAINER PG_SUPERUSER PG_DB DATA_VOLUME
             BACKUP_KEY_SECRET HELPER_IMAGE FORCE(=1 to skip prompts)
EOF
}

log() { printf '%s [restore] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [restore] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --set)     SET_ARG="${2:-}"; shift 2 ;;
    --do-db)   DO_DB=1; shift ;;
    --do-data) DO_DATA=1; shift ;;
    --list)    ls -1 "$BACKUP_DEST" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' || echo "(none)"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown arg: $1" ;;
  esac
done

[[ "$DO_DB" -eq 1 || "$DO_DATA" -eq 1 ]] \
  || { usage; die "nothing to do — pass --do-db and/or --do-data"; }

SET_ARG="${SET_ARG:-latest}"
SET_DIR="$BACKUP_DEST/$SET_ARG"
[[ -d "$SET_DIR" ]] || die "backup set not found: $SET_DIR (try --list)"
# Resolve 'latest' symlink to the real timestamp for logging.
REAL_SET="$(readlink -f "$SET_DIR")"
log "selected backup set: $REAL_SET"

# --- Preflight ---------------------------------------------------------------
command -v podman >/dev/null 2>&1 || die "podman not found"
podman secret exists "$BACKUP_KEY_SECRET" 2>/dev/null \
  || die "podman secret '$BACKUP_KEY_SECRET' missing — cannot decrypt"

DB_ENC="$SET_DIR/db-${PG_DB}.dump.enc"
DATA_ENC="$SET_DIR/data-${DATA_VOLUME}.tar.gz.enc"
SUMS="$SET_DIR/SHA256SUMS"

# --- Integrity check BEFORE touching anything (SI-7) -------------------------
if [[ -f "$SUMS" ]]; then
  log "verifying SHA-256 checksums ..."
  ( cd "$SET_DIR" && sha256sum --check --status SHA256SUMS ) \
    || die "checksum verification FAILED — refusing to restore a corrupt set"
  log "checksums OK"
else
  log "WARNING: no SHA256SUMS in set — integrity unverifiable, proceeding"
fi

# --- Decryption backend (must match what backup.sh used) ---------------------
if command -v age >/dev/null 2>&1 && head -c 64 "$DB_ENC" 2>/dev/null | grep -q 'age-encryption.org'; then
  DEC_BACKEND="age"
elif command -v openssl >/dev/null 2>&1; then
  DEC_BACKEND="openssl"
else
  die "no usable decryption backend (need age or openssl matching the set)"
fi
log "decryption backend: $DEC_BACKEND"

# --- Key + staging -----------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vw-restore.XXXXXX")"
chmod 700 "$WORK"
cleanup() {
  find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

KEY_FILE="$WORK/backup.key"
podman secret inspect --showsecret --format '{{.SecretData}}' "$BACKUP_KEY_SECRET" \
  > "$KEY_FILE" 2>/dev/null || die "could not read secret '$BACKUP_KEY_SECRET'"
chmod 600 "$KEY_FILE"
[[ -s "$KEY_FILE" ]] || die "backup key is empty"

# decrypt <ciphertext> <plaintext>
decrypt() {
  local src="$1" dst="$2"
  case "$DEC_BACKEND" in
    age)
      AGE_PASSPHRASE="$(cat "$KEY_FILE")" age -d -o "$dst" "$src" 2>/dev/null \
        || { unset AGE_PASSPHRASE; die "age decryption failed (wrong key?) for $src"; }
      unset AGE_PASSPHRASE ;;
    openssl)
      openssl enc -d -aes-256-gcm -salt -pbkdf2 -iter 600000 \
        -pass "file:$KEY_FILE" -in "$src" -out "$dst" \
        || die "openssl decryption failed (wrong key?) for $src" ;;
  esac
}

confirm() {
  # $1 = action description. Honors FORCE=1.
  [[ "$FORCE" == "1" ]] && { log "FORCE=1 — skipping confirmation for: $1"; return 0; }
  echo
  echo "  *** DESTRUCTIVE OPERATION ***"
  echo "  About to: $1"
  echo "  Target container : $PG_CONTAINER   DB: $PG_DB   volume: $DATA_VOLUME"
  echo "  This OVERWRITES live data. Have a rollback snapshot (CP-10)."
  read -r -p "  Type the word RESTORE to proceed: " ans
  [[ "$ans" == "RESTORE" ]] || die "confirmation declined — aborting"
}

# --- DB restore --------------------------------------------------------------
if [[ "$DO_DB" -eq 1 ]]; then
  [[ -f "$DB_ENC" ]] || die "DB artifact missing: $DB_ENC"
  podman container exists "$PG_CONTAINER" 2>/dev/null \
    || die "container '$PG_CONTAINER' not running — start the stack first"
  confirm "pg_restore --clean into database '$PG_DB' (drops & recreates objects)"

  DB_PLAIN="$WORK/db.dump"
  log "decrypting DB dump ..."
  decrypt "$DB_ENC" "$DB_PLAIN"

  # --clean drops objects before recreating; --if-exists avoids errors on a
  # fresh DB; --no-owner/--no-privileges so the dump (taken as superuser) can be
  # replayed without requiring the original role grants to pre-exist.
  # We pipe the dump in on stdin so no host path needs to be visible in-container.
  log "pg_restore --clean --if-exists into '$PG_DB' ..."
  podman exec -i "$PG_CONTAINER" \
    pg_restore --clean --if-exists --no-owner --no-privileges \
      -U "$PG_SUPERUSER" -d "$PG_DB" < "$DB_PLAIN" \
    || die "pg_restore reported errors — review output above; DB may be partial"
  log "DB restore complete."
  log "NOTE: re-grant app-role privileges if needed (the app uses role"
  log "      'vaultwarden', not 'postgres'); see postgres/init/01-app-role.sh."
fi

# --- /data volume restore ----------------------------------------------------
if [[ "$DO_DATA" -eq 1 ]]; then
  [[ -f "$DATA_ENC" ]] || die "data artifact missing: $DATA_ENC"
  confirm "REPLACE contents of volume '$DATA_VOLUME' (attachments, sends, rsa keys, config.json)"

  DATA_PLAIN="$WORK/data.tar.gz"
  log "decrypting data archive ..."
  decrypt "$DATA_ENC" "$DATA_PLAIN"

  # Stop the app first if it's running, so we don't restore under a live writer.
  if systemctl --user is-active --quiet nextvault.service 2>/dev/null; then
    log "stopping nextvault.service before data restore ..."
    systemctl --user stop nextvault.service || log "WARNING: could not stop nextvault.service"
    RESTART_APP=1
  else
    RESTART_APP=0
  fi

  # Throwaway container, READ-WRITE mount this time. It first wipes the volume
  # then extracts the archive piped on stdin. No network, dropped caps.
  log "restoring archive into volume '$DATA_VOLUME' (wipe + extract) ..."
  podman run --rm -i --network=none \
    --security-opt no-new-privileges --cap-drop=ALL \
    -v "${DATA_VOLUME}:/vwdata:Z" \
    "$HELPER_IMAGE" \
    sh -c 'set -e; rm -rf /vwdata/* /vwdata/.[!.]* /vwdata/..?* 2>/dev/null || true; tar -C /vwdata -xzf -' \
    < "$DATA_PLAIN" \
    || die "data restore failed — volume may be in a partial state"
  log "data restore complete."

  if [[ "${RESTART_APP:-0}" -eq 1 ]]; then
    log "restarting nextvault.service ..."
    systemctl --user start nextvault.service || log "WARNING: restart failed — start it manually"
  fi
fi

log "RESTORE COMPLETE from set $REAL_SET"
log "VALIDATE: log in, open a vault item with an attachment, confirm sends and"
log "          that the org/user RSA key (rsa_key.pem) decrypts existing data."
