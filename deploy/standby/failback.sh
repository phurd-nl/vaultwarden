#!/usr/bin/env bash
# =============================================================================
# failback.sh — MANUAL, GUARDED failback from the standby (now-active) back to
# the original primary. (NIST 800-53B Moderate: CP-10.)
#
# IMPORTANT — failback is NOT just "the reverse switches". After a failover the
# ORIGINAL primary's data dir is STALE and DIVERGED (the standby took writes the
# old primary never saw). You CANNOT simply restart the old primary as primary —
# that loses every write made since failover. So failback first rebuilds the old
# primary as a REPLICA of the now-active standby, lets it catch up, and only then
# performs a controlled switch in the OPPOSITE direction.
#
# STEPS:
#   1. PRECONDITIONS — standby is the live writer; operator confirms.
#   2. RE-SEED the old primary as a replica of the standby (pg_basebackup from
#      the standby). This OVERWRITES the old primary's data dir — guarded.
#   3. Start the old primary as a streaming replica; wait until caught up.
#   4. FENCE the standby app (stop it — single writer).
#   5. FINAL /data sync in REVERSE (standby /data -> primary /data).
#   6. PROMOTE the old primary (now caught up) back to primary.
#   7. Repoint the PRIMARY app DATABASE_URL at the promoted original DB; start it.
#   8. SWITCH Caddy upstream back to vaultwarden:8080; reload.
#   9. VALIDATE; re-establish the standby (standby becomes the replica again).
#
# This is a PLANNED maintenance operation — schedule a brief write-freeze window.
# =============================================================================
set -euo pipefail

PRIMARY_APP="${PRIMARY_APP:-vaultwarden}"
STANDBY_APP="${STANDBY_APP:-vaultwarden-standby}"
PRIMARY_DB="${PRIMARY_DB:-vw-postgres}"
STANDBY_DB="${STANDBY_DB:-vw-postgres-standby}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:17.5}"
PG_NETWORK="${PG_NETWORK:-vaultwarden-internal.network}"
DB_NAME="${DB_NAME:-vaultwarden}"
DB_USER="${DB_USER:-vaultwarden}"
PRIMARY_DB_HOST="${PRIMARY_DB_HOST:-vw-postgres}"
STANDBY_DB_HOST="${STANDBY_DB_HOST:-vw-postgres-standby}"   # cert SAN must cover this
REPL_ROLE="${REPL_ROLE:-vw_replicator}"
REPL_SLOT_BACK="${REPL_SLOT_BACK:-vw_failback_slot}"
REPL_PW_SECRET="${REPL_PW_SECRET:-vw_replication_password}"
DB_URL_PRIMARY_SECRET="${DB_URL_PRIMARY_SECRET:-vw_database_url}"
APP_PW_SECRET="${APP_PW_SECRET:-vw_db_app_password}"
PRIMARY_PGDATA_VOL="${PRIMARY_PGDATA_VOL:-vw-pgdata}"
CA_PATH_IN_APP="${CA_PATH_IN_APP:-/etc/ssl/certs/internal-ca.crt}"
CA_IN_CONTAINER="/etc/ssl/certs/internal-ca.crt"
CADDYFILE="${CADDYFILE:-$HOME/vaultwarden/caddy/Caddyfile}"
CADDY_CONTAINER="${CADDY_CONTAINER:-vw-caddy}"
MAX_LAG_BYTES="${MAX_LAG_BYTES:-16777216}"
SC="systemctl --user"

log()  { printf '%s [failback] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf '%s [failback] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }
step() { printf '\n%s [failback] === %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
confirm() { local p="$1" w="$2" a; read -r -p "$p [type '$w' to proceed]: " a; [[ "$a" == "$w" ]] || die "confirmation mismatch — aborting."; }

command -v podman >/dev/null 2>&1 || die "podman not found"

step "0. GUARD — failback returns service to the ORIGINAL primary"
echo "  This will OVERWRITE the original primary DB ('$PRIMARY_DB' / volume '$PRIMARY_PGDATA_VOL')"
echo "  by re-seeding it from the now-live standby. Schedule a short write-freeze window."
confirm "Proceed with FAILBACK?" "FAILBACK"

step "1. PRECONDITIONS — standby must be the live writer"
podman container exists "$STANDBY_DB" 2>/dev/null || die "standby DB '$STANDBY_DB' not running — nothing to fail back FROM."
SR="$(podman exec "$STANDBY_DB" psql -U "$PG_SUPERUSER" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo error)"
[[ "$SR" == "f" ]] || die "standby '$STANDBY_DB' is not a writable primary (pg_is_in_recovery=$SR). Did failover complete?"

# Replication role/slot for the standby->primary direction.
log "ensuring replication role + failback slot exist on the (now-primary) standby"
REPL_PW="$(podman secret inspect --showsecret --format '{{.SecretData}}' "$REPL_PW_SECRET" 2>/dev/null)" \
  || die "cannot read replication password secret '$REPL_PW_SECRET'"
podman exec -i "$STANDBY_DB" psql -v ON_ERROR_STOP=1 -U "$PG_SUPERUSER" -d postgres \
  --set=repl_pw="$REPL_PW" --set=repl_role="$REPL_ROLE" --set=repl_slot="$REPL_SLOT_BACK" <<'SQL'
SELECT format('CREATE ROLE %I WITH REPLICATION LOGIN PASSWORD %L', :'repl_role', :'repl_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_role')
\gexec
SELECT format('ALTER ROLE %I WITH REPLICATION LOGIN PASSWORD %L', :'repl_role', :'repl_pw') \gexec
SELECT pg_create_physical_replication_slot(:'repl_slot')
WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = :'repl_slot');
SQL

step "2. RE-SEED the original primary as a REPLICA of the standby (DESTRUCTIVE)"
echo "  About to WIPE '$PRIMARY_PGDATA_VOL' and pg_basebackup it from '$STANDBY_DB_HOST'."
confirm "Wipe and re-seed the original primary data dir?" "RESEED-PRIMARY"
# Stop the old primary DB if it is somehow up (it must not hold the volume).
$SC stop "${PRIMARY_DB}.service" 2>/dev/null || true
log "wiping '$PRIMARY_PGDATA_VOL'"
podman run --rm --cap-drop=ALL --security-opt no-new-privileges \
  -v "$PRIMARY_PGDATA_VOL":/d "$PG_IMAGE" sh -c 'rm -rf /d/* /d/.[!.]* 2>/dev/null || true'
log "pg_basebackup from standby into '$PRIMARY_PGDATA_VOL'"
podman run --rm --network "$PG_NETWORK" --cap-drop=ALL --security-opt no-new-privileges \
  -e PGPASSWORD="$REPL_PW" \
  -v "$PRIMARY_PGDATA_VOL":/var/lib/postgresql/data:Z \
  -v "$HOME/vaultwarden/tls/ca/internal-ca.crt":"$CA_IN_CONTAINER":ro,Z \
  "$PG_IMAGE" \
  bash -c 'pg_basebackup -h "'"$STANDBY_DB_HOST"'" -p 5432 -U "'"$REPL_ROLE"'" \
    -d "sslmode=verify-full sslrootcert='"$CA_IN_CONTAINER"'" \
    -D /var/lib/postgresql/data -Fp -Xstream -P -R -C -S "'"$REPL_SLOT_BACK"'" --write-recovery-conf' \
  || die "pg_basebackup from standby failed"
unset REPL_PW

step "3. Start the original primary as a streaming replica; wait for catch-up"
$SC start "${PRIMARY_DB}.service" || die "failed to start ${PRIMARY_DB}.service as replica"
for i in $(seq 1 120); do
  RR="$(podman exec "$PRIMARY_DB" psql -U "$PG_SUPERUSER" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo t)"
  LAG="$(podman exec "$PRIMARY_DB" psql -U "$PG_SUPERUSER" -tAc \
    "SELECT COALESCE(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()),0);" 2>/dev/null || echo 999999999)"
  log "primary-as-replica recovery=$RR lag=${LAG}B"
  [[ "$RR" == "t" && "$LAG" =~ ^[0-9]+$ && "$LAG" -le "$MAX_LAG_BYTES" ]] && break
  sleep 2
done
[[ "$RR" == "t" ]] || die "original primary is not streaming as a replica — investigate."

step "4. FENCE the standby app (begin write-freeze)"
$SC stop "${STANDBY_APP}.service" 2>/dev/null || true
log "standby app stopped — no new writes from here on"

step "5. FINAL /data sync in REVERSE (standby -> primary)"
if [[ -x "$(dirname "$0")/data-sync.sh" ]]; then
  # Reverse direction: swap src/dst via env. Operator must set the reverse SSH
  # target; document in the incident plan. Best effort.
  SRC_VOLUME=standby-data DST_VOLUME=vw-data MODE="${FAILBACK_SYNC_MODE:-local}" \
    "$(dirname "$0")/data-sync.sh" || log "WARNING: reverse /data sync failed — verify /data manually."
else
  log "data-sync.sh not found — sync /data standby->primary manually before promoting."
fi

step "6. PROMOTE the original primary back to primary"
P="$(podman exec "$PRIMARY_DB" psql -U "$PG_SUPERUSER" -tAc 'SELECT pg_promote(wait := true, wait_seconds := 60);' 2>/dev/null || echo error)"
[[ "$P" == "t" ]] || die "pg_promote on original primary did not confirm ('$P')."
for i in $(seq 1 30); do
  R="$(podman exec "$PRIMARY_DB" psql -U "$PG_SUPERUSER" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo t)"
  [[ "$R" == "f" ]] && break; sleep 1
done
[[ "$R" == "f" ]] || die "original primary still in recovery after promote."
log "original primary PROMOTED and writable again."

step "7. Repoint + start the PRIMARY app"
APP_PW="$(podman secret inspect --showsecret --format '{{.SecretData}}' "$APP_PW_SECRET" 2>/dev/null)" \
  || die "cannot read app password secret '$APP_PW_SECRET'"
NEW_URL="postgresql://${DB_USER}:${APP_PW}@${PRIMARY_DB_HOST}:5432/${DB_NAME}?sslmode=verify-full&sslrootcert=${CA_PATH_IN_APP}"
podman secret exists "$DB_URL_PRIMARY_SECRET" 2>/dev/null && podman secret rm "$DB_URL_PRIMARY_SECRET" >/dev/null
printf '%s' "$NEW_URL" | podman secret create "$DB_URL_PRIMARY_SECRET" - >/dev/null
unset APP_PW NEW_URL
$SC start "${PRIMARY_APP}.service" || die "failed to start ${PRIMARY_APP}.service"
log "primary app restarted against the promoted original DB"

step "8. SWITCH Caddy upstream back to the primary"
if grep -q 'reverse_proxy vaultwarden-standby:8080' "$CADDYFILE"; then
  cp -a "$CADDYFILE" "${CADDYFILE}.pre-failback.$(date -u +%Y%m%dT%H%M%SZ)"
  sed -i 's/reverse_proxy vaultwarden-standby:8080/reverse_proxy vaultwarden:8080/g' "$CADDYFILE"
  grep -q 'reverse_proxy vaultwarden:8080' "$CADDYFILE" || die "Caddyfile rewrite back failed — edit manually."
  log "Caddyfile upstream restored to vaultwarden:8080 (backup saved)"
else
  log "Caddyfile already points at the primary upstream"
fi
if podman container exists "$CADDY_CONTAINER" 2>/dev/null; then
  podman exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
    || { $SC restart "${CADDY_CONTAINER}.service" || die "could not reload/restart Caddy"; }
  log "Caddy reloaded with the primary upstream"
fi

step "9. RE-ESTABLISH the standby as a replica of the restored primary"
log "Now rebuild the standby DB as a replica again so you are protected:"
log "  systemctl --user stop vw-postgres-standby.service"
log "  ./setup-replication.sh --reseed        # standby re-seeds from the primary"
log "  systemctl --user start vw-postgres-standby.service"
log "  systemctl --user start vw-data-sync.timer   # resume forward /data sync"
cat <<'EOF'

  VALIDATE (see README "Validation"): log in, WebSocket 101 + live sync,
  open an attachment, create/download a Send, concurrent edit on two clients,
  and confirm vw-caddy access log shows upstream vaultwarden:8080 again.
EOF
log "FAILBACK COMPLETE. Confirm streaming replication is healthy before closing the incident."
