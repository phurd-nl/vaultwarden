#!/usr/bin/env bash
# =============================================================================
# basebackup.sh — physical base backup for Point-In-Time Recovery (PITR).
#
# NIST 800-53B Moderate: CP-9 (full physical backup), CP-10 (a base backup +
# the WAL archive lets you recover to any point in time), SC-28 (the resulting
# tarball is encrypted at rest, same key as backup.sh).
#
# This is the PITR counterpart to backup.sh's logical pg_dump:
#   * pg_dump (backup.sh)   -> portable, restore into any PG, no time travel.
#   * pg_basebackup (here)  -> physical snapshot; combined with the WAL archive
#     (postgres-archive.conf) it supports recovery to a chosen LSN/time.
#
# Run this periodically (e.g. weekly) so the WAL archive never has to be
# replayed from too far back. Each base backup defines a new PITR baseline; you
# may prune WAL older than the OLDEST base backup you still wish to recover to.
#
# Requirements:
#   * archive_mode=on already active (see postgres-archive.conf + README).
#   * A replication-capable connection. We exec pg_basebackup INSIDE the
#     nextvault-postgres container as the superuser over the local socket, so no
#     network replication slot/role is needed and nothing is published.
# =============================================================================
set -euo pipefail

BACKUP_DEST="${BACKUP_DEST:-./backups}"
BASEBACKUP_SUBDIR="${BASEBACKUP_SUBDIR:-basebackups}"
PG_CONTAINER="${PG_CONTAINER:-nextvault-postgres}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
BACKUP_KEY_SECRET="${BACKUP_KEY_SECRET:-vw_backup_key}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$BACKUP_DEST/$BASEBACKUP_SUBDIR/$TS"

log() { printf '%s [basebackup] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [basebackup] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || die "podman not found"
podman container exists "$PG_CONTAINER" 2>/dev/null || die "container '$PG_CONTAINER' not running"
podman secret exists "$BACKUP_KEY_SECRET" 2>/dev/null || die "secret '$BACKUP_KEY_SECRET' missing"

# Confirm archiving is actually on — a base backup without WAL archiving gives
# you a snapshot but NO point-in-time replay (RPO would silently degrade).
ARCHIVE_MODE="$(podman exec "$PG_CONTAINER" psql -U "$PG_SUPERUSER" -tAc 'SHOW archive_mode;' 2>/dev/null || echo unknown)"
if [[ "$ARCHIVE_MODE" != "on" ]]; then
  log "WARNING: archive_mode='$ARCHIVE_MODE' (expected 'on'). This base backup"
  log "         will NOT support PITR until WAL archiving is enabled — see"
  log "         postgres-archive.conf + README 'Enabling PITR'."
fi

if command -v age >/dev/null 2>&1; then ENC_BACKEND="age"
elif command -v openssl >/dev/null 2>&1; then ENC_BACKEND="openssl"
else die "no encryption backend (age/openssl)"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vw-basebackup.XXXXXX")"; chmod 700 "$WORK"
cleanup() { find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

KEY_FILE="$WORK/backup.key"
podman secret inspect --showsecret --format '{{.SecretData}}' "$BACKUP_KEY_SECRET" > "$KEY_FILE" 2>/dev/null \
  || die "could not read secret '$BACKUP_KEY_SECRET'"
chmod 600 "$KEY_FILE"; [[ -s "$KEY_FILE" ]] || die "key empty"

encrypt() {
  local src="$1" dst="$2"
  case "$ENC_BACKEND" in
    age) AGE_PASSPHRASE="$(cat "$KEY_FILE")" age -p -o "$dst" "$src" 2>/dev/null \
           || { unset AGE_PASSPHRASE; die "age encrypt failed"; }; unset AGE_PASSPHRASE ;;
    openssl) openssl enc -aes-256-gcm -salt -pbkdf2 -iter 600000 -pass "file:$KEY_FILE" \
               -in "$src" -out "$dst" || die "openssl encrypt failed" ;;
  esac
}

mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
log "writing base backup set -> $OUT_DIR (archive_mode=$ARCHIVE_MODE)"

# pg_basebackup with:
#   -Ft  tar format  | -z server-side gzip would need -Z; we gzip the stream.
#   -X stream  fetches the WAL needed to make the base internally consistent.
#   -c fast    issues an immediate checkpoint so the backup starts promptly.
#   -D -       stream the (single, with -Xnone) tar to stdout — but with -Xstream
#              pg_basebackup writes pg_wal.tar too, so we direct -D to a path
#              INSIDE the container's tmpfs, then tar that out. Simpler & robust:
#              write to a container tmp dir, tar it to our stdout, encrypt.
BASE_PLAIN="$WORK/basebackup.tar.gz"
log "running pg_basebackup inside $PG_CONTAINER ..."
podman exec "$PG_CONTAINER" sh -c '
  set -e
  D="$(mktemp -d /tmp/basebackup.XXXXXX)"
  pg_basebackup -U "'"$PG_SUPERUSER"'" -D "$D" -Ft -z -Xstream -c fast -P >&2
  tar -C "$D" -cf - .
  rm -rf "$D"
' > "$BASE_PLAIN" || die "pg_basebackup failed"
[[ -s "$BASE_PLAIN" ]] || die "pg_basebackup produced empty output"
log "pg_basebackup ok ($(wc -c <"$BASE_PLAIN") bytes)"

BASE_ENC="$OUT_DIR/basebackup.tar.enc"
log "encrypting base backup ($ENC_BACKEND) ..."
encrypt "$BASE_PLAIN" "$BASE_ENC"
chmod 600 "$BASE_ENC"

( cd "$OUT_DIR" && sha256sum "$(basename "$BASE_ENC")" > SHA256SUMS )

{
  echo "# Vaultwarden PITR base backup manifest (NIST CP-9/CP-10/SC-28)"
  echo "set_timestamp_utc = $TS"
  echo "pg_container      = $PG_CONTAINER"
  echo "archive_mode      = $ARCHIVE_MODE"
  echo "type              = pg_basebackup -Ft -Xstream -c fast"
  echo "encryption        = $ENC_BACKEND"
  echo "key_secret        = $BACKUP_KEY_SECRET (escrow separately)"
  echo "pitr_note         = recover with this base + WAL archive >= this LSN"
  echo "artifacts:"
  echo "  - $(basename "$BASE_ENC")"
  echo "  - SHA256SUMS"
} > "$OUT_DIR/manifest.txt"
chmod 600 "$OUT_DIR/manifest.txt"

ln -sfn "$TS" "$BACKUP_DEST/$BASEBACKUP_SUBDIR/latest"

log "BASE BACKUP COMPLETE: $OUT_DIR"
log "REMINDER: ship this base AND the WAL archive offsite (MP-5). Prune WAL only"
log "          older than the OLDEST base backup you still want to recover to."
