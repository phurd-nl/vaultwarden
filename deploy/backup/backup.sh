#!/usr/bin/env bash
# =============================================================================
# backup.sh — encrypted, scheduled-friendly backup of the Vaultwarden stack.
#
# NIST 800-53B Moderate: CP-9 (System Backup), CP-10 (recovery support),
# SC-28 (Protection of Information at Rest — backups are encrypted),
# MP-5 (Media Transport — see offsite note in README), AU (manifest is an
# audit record of what was captured).
#
# What it captures, per run, into a timestamped set under $BACKUP_DEST:
#   1. Logical PostgreSQL dump   — `pg_dump -Fc` (custom format) of DB
#      "vaultwarden" via the running container nextvault-postgres (superuser postgres).
#   2. The nextvault-data volume        — attachments, sends, config.json,
#      rsa_key.pem, rsa_key.pub.pem — tarred from a throwaway READ-ONLY mount.
#   3. A manifest + SHA-256 checksums of every artifact (integrity, SI-7).
#
# Encryption (SC-28): each artifact is encrypted at rest. `age` is used if
# present, otherwise `openssl enc -aes-256-gcm` (PBKDF2). The choice and the
# SEPARATE-KEY requirement are documented in deploy/backup/README.md.
#
# The ENCRYPTION KEY is read from the podman secret `vw_backup_key` and MUST be
# stored separately from the backups themselves (a backup you can decrypt with
# a key sitting next to it is not a backup — see README "Separate key").
#
# Idempotent: each run writes a fresh, uniquely-timestamped set; re-running
# never clobbers a prior set. Safe to invoke from a systemd timer.
# =============================================================================
set -euo pipefail

# --- Configuration (override via environment / EnvironmentFile) --------------
BACKUP_DEST="${BACKUP_DEST:-./backups}"          # where backup sets are written
PG_CONTAINER="${PG_CONTAINER:-nextvault-postgres}"      # running postgres container
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"         # superuser (used for dump only)
PG_DB="${PG_DB:-vaultwarden}"                    # database to dump
DATA_VOLUME="${DATA_VOLUME:-nextvault-data}"            # app /data podman volume
BACKUP_KEY_SECRET="${BACKUP_KEY_SECRET:-vw_backup_key}"  # podman secret w/ key
# Tiny, pinned helper image for the throwaway volume-tar container. Reuse the
# postgres image already present on the host to avoid an extra pull; only its
# `tar` + `sh` are used (read-only mount, so nothing is written back).
HELPER_IMAGE="${HELPER_IMAGE:-docker.io/library/postgres:17.10}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"           # prune sets older than N days; 0=keep all

TS="$(date -u +%Y%m%dT%H%M%SZ)"                  # NIST: all timestamps UTC
SET_DIR="$BACKUP_DEST/$TS"
HOSTNAME_TAG="$(hostname -s 2>/dev/null || echo host)"

log()  { printf '%s [backup] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf '%s [backup] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
command -v podman >/dev/null 2>&1 || die "podman not found on PATH"
podman secret exists "$BACKUP_KEY_SECRET" 2>/dev/null \
  || die "podman secret '$BACKUP_KEY_SECRET' missing — run create-backup-key.sh"
podman container exists "$PG_CONTAINER" 2>/dev/null \
  || die "container '$PG_CONTAINER' not found (is the stack running?)"
podman volume exists "$DATA_VOLUME" 2>/dev/null \
  || die "volume '$DATA_VOLUME' not found"

# Choose an encryption backend. Documented in README.
if command -v age >/dev/null 2>&1; then
  ENC_BACKEND="age"
elif command -v openssl >/dev/null 2>&1; then
  ENC_BACKEND="openssl"
else
  die "neither 'age' nor 'openssl' available for encryption"
fi
log "encryption backend: $ENC_BACKEND"

# --- Materialise the encryption key from the podman secret -------------------
# The key never touches disk in plaintext: it lives in a 0700 tmp dir that is
# unconditionally shredded on exit. For `age` the secret is an age recipient
# (public) string OR an identity; we treat it as a passphrase-style recipient
# via `age -p`-compatible symmetric flow using the secret as the passphrase.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nextvault-backup.XXXXXX")"
chmod 700 "$WORK"
cleanup() {
  # Best-effort secure wipe of any key material / staging.
  find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

KEY_FILE="$WORK/backup.key"
# `podman secret inspect --showsecret` prints the raw value (podman >= 4.x).
podman secret inspect --showsecret --format '{{.SecretData}}' "$BACKUP_KEY_SECRET" \
  > "$KEY_FILE" 2>/dev/null \
  || die "could not read secret '$BACKUP_KEY_SECRET' (need podman >= 4.x with --showsecret)"
chmod 600 "$KEY_FILE"
[[ -s "$KEY_FILE" ]] || die "backup key is empty"

# encrypt <plaintext-path> <ciphertext-path>
encrypt() {
  local src="$1" dst="$2"
  case "$ENC_BACKEND" in
    age)
      # Symmetric: the secret value is used as the passphrase. AGE_PASSPHRASE
      # avoids an interactive prompt; -p selects scrypt symmetric mode.
      AGE_PASSPHRASE="$(cat "$KEY_FILE")" age -p -o "$dst" "$src" 2>/dev/null \
        || { unset AGE_PASSPHRASE; die "age encryption failed for $src"; }
      unset AGE_PASSPHRASE
      ;;
    openssl)
      # AES-256-GCM (AEAD: confidentiality + integrity). Key derived from the
      # secret via PBKDF2 with a random salt embedded in the output header.
      openssl enc -aes-256-gcm -salt -pbkdf2 -iter 600000 \
        -pass "file:$KEY_FILE" -in "$src" -out "$dst" \
        || die "openssl encryption failed for $src"
      ;;
  esac
}

# --- Begin the set -----------------------------------------------------------
mkdir -p "$SET_DIR"
chmod 700 "$SET_DIR"
log "writing backup set -> $SET_DIR"

DB_PLAIN="$WORK/db-${PG_DB}.dump"
DB_ENC="$SET_DIR/db-${PG_DB}.dump.enc"
DATA_PLAIN="$WORK/data-${DATA_VOLUME}.tar.gz"
DATA_ENC="$SET_DIR/data-${DATA_VOLUME}.tar.gz.enc"

# 1) Logical DB dump (custom format -> supports selective pg_restore, parallel).
log "pg_dump ${PG_DB} (custom format) from container ${PG_CONTAINER} ..."
podman exec "$PG_CONTAINER" pg_dump -U "$PG_SUPERUSER" -Fc "$PG_DB" > "$DB_PLAIN" \
  || die "pg_dump failed"
[[ -s "$DB_PLAIN" ]] || die "pg_dump produced an empty file"
log "pg_dump ok ($(wc -c <"$DB_PLAIN") bytes)"

# 2) nextvault-data volume — throwaway container, READ-ONLY mount, no network, no caps.
#    We tar to stdout so nothing is written into the volume.
log "archiving volume ${DATA_VOLUME} (read-only mount) ..."
podman run --rm --network=none --read-only \
  --security-opt no-new-privileges --cap-drop=ALL \
  -v "${DATA_VOLUME}:/vwdata:ro,Z" \
  "$HELPER_IMAGE" \
  tar -C /vwdata -czf - . > "$DATA_PLAIN" \
  || die "volume archive failed"
[[ -s "$DATA_PLAIN" ]] || die "volume archive produced an empty file"
log "volume archive ok ($(wc -c <"$DATA_PLAIN") bytes)"

# 3) Encrypt both artifacts (SC-28).
log "encrypting artifacts ($ENC_BACKEND) ..."
encrypt "$DB_PLAIN"   "$DB_ENC"
encrypt "$DATA_PLAIN" "$DATA_ENC"
chmod 600 "$DB_ENC" "$DATA_ENC"

# --- Checksums (integrity / SI-7) --------------------------------------------
# Checksum the CIPHERTEXT (what actually lands on storage) so restore can
# verify integrity before attempting decryption.
SUMS="$SET_DIR/SHA256SUMS"
( cd "$SET_DIR" && sha256sum "$(basename "$DB_ENC")" "$(basename "$DATA_ENC")" > "SHA256SUMS" )
log "checksums written -> $SUMS"

# --- Manifest (audit record of the set) --------------------------------------
MANIFEST="$SET_DIR/manifest.txt"
{
  echo "# Vaultwarden backup manifest"
  echo "# NIST CP-9/CP-10/SC-28 — encrypted backup set"
  echo "set_timestamp_utc = $TS"
  echo "host             = $HOSTNAME_TAG"
  echo "pg_container      = $PG_CONTAINER"
  echo "pg_database       = $PG_DB"
  echo "pg_dump_format    = custom (-Fc)"
  echo "data_volume       = $DATA_VOLUME"
  echo "data_contents     = attachments, sends, config.json, rsa_key.pem, rsa_key.pub.pem"
  echo "encryption        = $ENC_BACKEND"
  echo "openssl_cipher    = aes-256-gcm pbkdf2 iter=600000 (if backend=openssl)"
  echo "key_secret        = $BACKUP_KEY_SECRET (stored SEPARATELY from backups — see README)"
  echo "podman_version    = $(podman --version 2>/dev/null)"
  echo "artifacts:"
  echo "  - $(basename "$DB_ENC")"
  echo "  - $(basename "$DATA_ENC")"
  echo "  - SHA256SUMS"
} > "$MANIFEST"
chmod 600 "$MANIFEST"
log "manifest written -> $MANIFEST"

# --- Update a 'latest' pointer (idempotent convenience for restore) ----------
ln -sfn "$TS" "$BACKUP_DEST/latest"

# --- Retention prune (CP-9: keep recent sets; offsite copy is the durable one) -
if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  log "pruning local sets older than ${RETENTION_DAYS} days ..."
  # Only prune timestamped set dirs (YYYYMMDDTHHMMSSZ), never 'latest'.
  find "$BACKUP_DEST" -maxdepth 1 -type d -name '????????T??????Z' \
    -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} + 2>/dev/null || true
fi

log "BACKUP COMPLETE: $SET_DIR"
log "REMINDER: copy this set to OFFSITE / write-once storage (MP-5); the local"
log "          copy is not durable. The decryption key lives only in secret"
log "          '$BACKUP_KEY_SECRET' and MUST be escrowed separately."
