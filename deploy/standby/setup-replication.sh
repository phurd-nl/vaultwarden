#!/usr/bin/env bash
# =============================================================================
# setup-replication.sh — bootstrap PostgreSQL streaming replication for the
# warm standby (NIST 800-53B Moderate: CP-10).
#
# WHAT IT DOES (run ONCE, when first standing up the replica):
#   1. Creates a least-privilege REPLICATION login role on the PRIMARY
#      (`vw_replicator`, NOT a superuser — REPLICATION + LOGIN only, AC-6).
#   2. Creates a physical replication SLOT on the primary so the primary retains
#      WAL the replica still needs even if the replica is briefly offline.
#   3. Runs pg_basebackup from the primary into the standby-pgdata volume with
#      -R, which writes standby.signal + primary_conninfo (over TLS, verify-full)
#      so the replica streams as soon as vw-postgres-standby starts.
#
# It exec's into the ALREADY-RUNNING primary container for the role/slot SQL and
# runs pg_basebackup in a THROWAWAY postgres container that mounts only the
# standby-pgdata volume — no new published port, rootless, cap-dropped.
#
# PREREQUISITES (documented, applied by you — see README "Primary-side config"):
#   * Primary started with: wal_level=replica, max_wal_senders>=10,
#     max_replication_slots>=10  (added as -c flags to vw-postgres.container Exec)
#   * pg_hba.conf has a hostssl replication line for vw_replicator from the
#     internal subnet (see README "Primary-side pg_hba").
#   * Secret vw_replication_password exists (this script creates it if missing).
#   * The replica server cert/key + CA are in place (deploy/tls).
#
# Re-running is guarded: it refuses to clobber a non-empty standby-pgdata volume
# unless you pass --reseed.
# =============================================================================
set -euo pipefail

PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-vw-postgres}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:17.5}"
PG_NETWORK="${PG_NETWORK:-vaultwarden-internal.network}"
PRIMARY_HOST="${PRIMARY_HOST:-vw-postgres}"          # must match server cert SAN
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPL_ROLE="${REPL_ROLE:-vw_replicator}"
REPL_SLOT="${REPL_SLOT:-vw_standby_slot}"
STANDBY_PGDATA_VOL="${STANDBY_PGDATA_VOL:-standby-pgdata}"
REPL_PW_SECRET="${REPL_PW_SECRET:-vw_replication_password}"
CA_IN_CONTAINER="/etc/ssl/certs/internal-ca.crt"
RESEED=0
[[ "${1:-}" == "--reseed" ]] && RESEED=1

log() { printf '%s [setup-replication] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [setup-replication] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || die "podman not found"
podman container exists "$PRIMARY_CONTAINER" 2>/dev/null || die "primary '$PRIMARY_CONTAINER' not running"

# --- 1. Replication password secret (NIST IA-5) ------------------------------
if ! podman secret exists "$REPL_PW_SECRET" 2>/dev/null; then
  log "creating replication password secret '$REPL_PW_SECRET'"
  REPL_PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"
  printf '%s' "$REPL_PW" | podman secret create "$REPL_PW_SECRET" - >/dev/null
  log "secret created — escrow it in your password manager (used by the replica)."
else
  log "secret '$REPL_PW_SECRET' already exists; reading it to seed pg_basebackup"
  REPL_PW="$(podman secret inspect --showsecret --format '{{.SecretData}}' "$REPL_PW_SECRET" 2>/dev/null)" \
    || die "cannot read existing secret '$REPL_PW_SECRET'"
fi
[[ -n "$REPL_PW" ]] || die "replication password is empty"

# --- 2. Replication role + slot on the PRIMARY (NIST AC-6) -------------------
log "creating replication role '$REPL_ROLE' and slot '$REPL_SLOT' on the primary"
podman exec -i "$PRIMARY_CONTAINER" \
  psql -v ON_ERROR_STOP=1 -U "$PG_SUPERUSER" -d postgres \
  --set=repl_pw="$REPL_PW" --set=repl_role="$REPL_ROLE" --set=repl_slot="$REPL_SLOT" <<'SQL'
-- REPLICATION + LOGIN, NOT superuser (least privilege).
SELECT format('CREATE ROLE %I WITH REPLICATION LOGIN PASSWORD %L', :'repl_role', :'repl_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_role')
\gexec
-- Keep the password in sync if the role already existed.
SELECT format('ALTER ROLE %I WITH REPLICATION LOGIN PASSWORD %L', :'repl_role', :'repl_pw')
\gexec
-- Physical slot so the primary retains WAL for an offline replica.
SELECT pg_create_physical_replication_slot(:'repl_slot')
WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = :'repl_slot');
SQL
log "role + slot present on primary"

# --- 3. Guard the target volume ----------------------------------------------
if podman volume exists "$STANDBY_PGDATA_VOL" 2>/dev/null; then
  NONEMPTY="$(podman run --rm --network=none --cap-drop=ALL --security-opt no-new-privileges \
    -v "$STANDBY_PGDATA_VOL":/d:ro "$PG_IMAGE" sh -c 'ls -A /d 2>/dev/null | head -1')"
  if [[ -n "$NONEMPTY" && "$RESEED" -ne 1 ]]; then
    die "standby volume '$STANDBY_PGDATA_VOL' is NOT empty. Refusing to overwrite a seeded replica. Re-run with --reseed to wipe and re-seed."
  fi
  if [[ -n "$NONEMPTY" && "$RESEED" -eq 1 ]]; then
    log "--reseed: wiping existing standby data dir"
    podman run --rm --cap-drop=ALL --security-opt no-new-privileges \
      -v "$STANDBY_PGDATA_VOL":/d "$PG_IMAGE" sh -c 'rm -rf /d/* /d/.[!.]* 2>/dev/null || true'
  fi
else
  log "volume '$STANDBY_PGDATA_VOL' does not exist yet; podman will create it on mount"
fi

# --- 4. pg_basebackup seed into the standby volume ---------------------------
# -R writes standby.signal + primary_conninfo (incl. the slot + TLS verify-full)
# into the data dir so the replica streams immediately on start.
# We pass the password via PGPASSWORD inside the throwaway container only.
PRIMARY_CONNINFO="host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=${REPL_ROLE} sslmode=verify-full sslrootcert=${CA_IN_CONTAINER}"
log "running pg_basebackup from '$PRIMARY_CONNINFO' (slot=$REPL_SLOT) into volume '$STANDBY_PGDATA_VOL'"

podman run --rm \
  --network "$PG_NETWORK" \
  --cap-drop=ALL --security-opt no-new-privileges \
  -e PGPASSWORD="$REPL_PW" \
  -v "$STANDBY_PGDATA_VOL":/var/lib/postgresql/data:Z \
  -v "$HOME/vaultwarden/tls/ca/internal-ca.crt":"$CA_IN_CONTAINER":ro,Z \
  "$PG_IMAGE" \
  bash -c '
    set -e
    pg_basebackup \
      -h "'"$PRIMARY_HOST"'" -p "'"$PRIMARY_PORT"'" -U "'"$REPL_ROLE"'" \
      -d "sslmode=verify-full sslrootcert='"$CA_IN_CONTAINER"'" \
      -D /var/lib/postgresql/data \
      -Fp -Xstream -P -R \
      -C -S "'"$REPL_SLOT"'" \
      --write-recovery-conf
  ' || die "pg_basebackup failed (check primary pg_hba hostssl replication line + max_wal_senders)"

log "pg_basebackup complete; standby.signal + primary_conninfo written into the data dir"
log "NEXT:"
log "  1) confirm secret '$REPL_PW_SECRET' is mounted by vw-postgres-standby.container"
log "  2) systemctl --user start vw-postgres-standby.service"
log "  3) verify streaming on the PRIMARY:"
log "       podman exec $PRIMARY_CONTAINER psql -U $PG_SUPERUSER -xc \\"
log "         \"SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;\""
log "     and on the REPLICA (should report 't'):"
log "       podman exec vw-postgres-standby psql -U $PG_SUPERUSER -tAc 'SELECT pg_is_in_recovery();'"
