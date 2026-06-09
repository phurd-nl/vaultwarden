#!/usr/bin/env bash
# =============================================================================
# failover.sh — MANUAL, GUARDED failover from primary to warm standby.
#   (NIST 800-53B Moderate: CP-10, alternate processing / recovery.)
#
# This is active-PASSIVE with MANUAL failover. Nothing here is automatic — it
# runs ONLY when an operator invokes it, and every destructive step is behind a
# typed confirmation. It does, in order:
#   1. PRECONDITIONS — confirm the standby DB replica is healthy and caught up.
#   2. FENCE the old primary app — stop vaultwarden.service so there is never
#      more than one writer (split-brain prevention).
#   3. FINAL /data sync if the primary host is still reachable (shrink /data RPO).
#   4. PROMOTE the replica — pg_promote(); wait until it leaves recovery.
#   5. REPOINT the standby app's DATABASE_URL secret at the promoted DB.
#   6. START the standby app (vaultwarden-standby.service).
#   7. SWITCH Caddy upstream to the standby and reload.
#   8. VALIDATE (delegates to verify.sh; reminds about WebSocket/attachments).
#
# Run from the host that controls the podman stack you are failing OVER TO.
# Idempotent-ish: each step checks current state before acting.
#
# REQUIRED ACCESS: rootless deploy user; podman; ability to edit the Caddyfile
# and reload vw-caddy; the vw_database_url_standby secret.
# =============================================================================
set -euo pipefail

PRIMARY_APP="${PRIMARY_APP:-vaultwarden}"
STANDBY_APP="${STANDBY_APP:-vaultwarden-standby}"
PRIMARY_DB="${PRIMARY_DB:-vw-postgres}"
STANDBY_DB="${STANDBY_DB:-vw-postgres-standby}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
DB_NAME="${DB_NAME:-vaultwarden}"
DB_USER="${DB_USER:-vaultwarden}"
STANDBY_DB_HOST="${STANDBY_DB_HOST:-vw-postgres-standby}"   # cert SAN must cover this
DB_URL_STANDBY_SECRET="${DB_URL_STANDBY_SECRET:-vw_database_url_standby}"
APP_PW_SECRET="${APP_PW_SECRET:-vw_db_app_password}"
CA_PATH_IN_APP="${CA_PATH_IN_APP:-/etc/ssl/certs/internal-ca.crt}"
CADDYFILE="${CADDYFILE:-$HOME/vaultwarden/caddy/Caddyfile}"
CADDY_CONTAINER="${CADDY_CONTAINER:-vw-caddy}"
MAX_LAG_BYTES="${MAX_LAG_BYTES:-16777216}"        # 16 MiB acceptable replay lag
RUN_FINAL_SYNC="${RUN_FINAL_SYNC:-1}"
SC="systemctl --user"

log()  { printf '%s [failover] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf '%s [failover] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }
step() { printf '\n%s [failover] === %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

confirm() {
  local prompt="$1" want="$2" ans
  read -r -p "$prompt [type '$want' to proceed]: " ans
  [[ "$ans" == "$want" ]] || die "confirmation '$ans' != '$want' — aborting."
}

command -v podman >/dev/null 2>&1 || die "podman not found"

step "0. GUARD — this initiates FAILOVER to the standby"
echo "  Primary app : $PRIMARY_APP   Primary DB : $PRIMARY_DB"
echo "  Standby app : $STANDBY_APP   Standby DB : $STANDBY_DB (replica to promote)"
echo "  Caddyfile   : $CADDYFILE"
confirm "Proceed with FAILOVER?" "FAILOVER"

step "1. PRECONDITIONS — standby replica healthy & caught up"
podman container exists "$STANDBY_DB" 2>/dev/null || die "standby DB '$STANDBY_DB' is not running — cannot promote a replica that isn't up."
IN_RECOVERY="$(podman exec "$STANDBY_DB" psql -U "$PG_SUPERUSER" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo error)"
[[ "$IN_RECOVERY" == "t" ]] || die "standby '$STANDBY_DB' is not in recovery (pg_is_in_recovery=$IN_RECOVERY). Already promoted? Refusing to double-promote."

# Replay lag vs the last WAL it has received. If the primary is gone, received
# == replayed and lag is ~0 (we promote with whatever it has). If the primary is
# alive, ensure we are not promoting while far behind.
LAG="$(podman exec "$STANDBY_DB" psql -U "$PG_SUPERUSER" -tAc \
  "SELECT COALESCE(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()),0);" 2>/dev/null || echo unknown)"
log "replica replay lag = ${LAG} bytes (threshold ${MAX_LAG_BYTES})"
if [[ "$LAG" =~ ^[0-9]+$ ]] && (( LAG > MAX_LAG_BYTES )); then
  echo "  WARNING: replica is ${LAG} bytes behind what it has received."
  confirm "Promote anyway (potential data loss up to lag)?" "PROMOTE-BEHIND"
fi

step "2. FENCE the old primary app (split-brain prevention)"
if $SC is-active --quiet "${PRIMARY_APP}.service" 2>/dev/null; then
  log "stopping ${PRIMARY_APP}.service so it can no longer write"
  $SC stop "${PRIMARY_APP}.service" || die "failed to stop ${PRIMARY_APP}.service — DO NOT continue (split-brain risk)."
else
  log "${PRIMARY_APP}.service already inactive (expected if primary host is down)"
fi

step "3. FINAL /data sync (shrink /data RPO) — best effort"
if [[ "$RUN_FINAL_SYNC" == "1" ]] && [[ -x "$(dirname "$0")/data-sync.sh" ]]; then
  if "$(dirname "$0")/data-sync.sh"; then
    log "final /data sync OK — attachments/sends current as of now"
  else
    log "WARNING: final /data sync FAILED or primary host unreachable. /data is"
    log "         consistent only as of the LAST scheduled sync. Note the gap in"
    log "         the incident record (this is the /data RPO realised)."
  fi
else
  log "skipping final /data sync (RUN_FINAL_SYNC=$RUN_FINAL_SYNC)"
fi

step "4. PROMOTE the replica to primary (pg_promote)"
PROMOTED="$(podman exec "$STANDBY_DB" psql -U "$PG_SUPERUSER" -tAc 'SELECT pg_promote(wait := true, wait_seconds := 60);' 2>/dev/null || echo error)"
[[ "$PROMOTED" == "t" ]] || die "pg_promote did not confirm (returned '$PROMOTED'). Check '$STANDBY_DB' logs."
for i in $(seq 1 30); do
  R="$(podman exec "$STANDBY_DB" psql -U "$PG_SUPERUSER" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo t)"
  [[ "$R" == "f" ]] && break
  sleep 1
done
[[ "$R" == "f" ]] || die "replica still in recovery after promote — aborting before repointing the app."
log "replica PROMOTED and accepting writes."

step "5. REPOINT the standby app DATABASE_URL at the promoted DB"
# Rebuild the app DATABASE_URL pointing at the promoted host, reusing the same
# least-privilege app-role password secret. The standby quadlet mounts
# vw_database_url_standby as /run/secrets/vw_database_url.
APP_PW="$(podman secret inspect --showsecret --format '{{.SecretData}}' "$APP_PW_SECRET" 2>/dev/null)" \
  || die "cannot read app password secret '$APP_PW_SECRET'"
NEW_URL="postgresql://${DB_USER}:${APP_PW}@${STANDBY_DB_HOST}:5432/${DB_NAME}?sslmode=verify-full&sslrootcert=${CA_PATH_IN_APP}"
podman secret exists "$DB_URL_STANDBY_SECRET" 2>/dev/null && podman secret rm "$DB_URL_STANDBY_SECRET" >/dev/null
printf '%s' "$NEW_URL" | podman secret create "$DB_URL_STANDBY_SECRET" - >/dev/null
unset APP_PW NEW_URL
log "secret '$DB_URL_STANDBY_SECRET' now points at '$STANDBY_DB_HOST'"

step "6. START the standby app"
$SC start "${STANDBY_APP}.service" || die "failed to start ${STANDBY_APP}.service"
for i in $(seq 1 30); do
  podman healthcheck run "$STANDBY_APP" >/dev/null 2>&1 && break
  podman container exists "$STANDBY_APP" 2>/dev/null && podman exec "$STANDBY_APP" true 2>/dev/null && break
  sleep 1
done
podman container exists "$STANDBY_APP" 2>/dev/null || die "standby app container did not come up"
log "standby app '$STANDBY_APP' is running"

step "7. SWITCH Caddy upstream to the standby"
# Repoint reverse_proxy targets from the primary app name to the standby. The
# Caddyfile uses 'vaultwarden:8080'; the standby listens as 'vaultwarden-standby:8080'.
if grep -q 'vaultwarden-standby:8080' "$CADDYFILE"; then
  log "Caddyfile already points at the standby upstream"
else
  cp -a "$CADDYFILE" "${CADDYFILE}.pre-failover.$(date -u +%Y%m%dT%H%M%SZ)"
  # Only the bare upstream token, not the site address / comments.
  sed -i 's/reverse_proxy vaultwarden:8080/reverse_proxy vaultwarden-standby:8080/g' "$CADDYFILE"
  grep -q 'vaultwarden-standby:8080' "$CADDYFILE" || die "Caddyfile rewrite did not take — edit it manually."
  log "Caddyfile upstream switched to vaultwarden-standby:8080 (backup saved)"
fi
# Reload Caddy in place (no downtime) — it must be able to resolve the standby
# container name on the internal network (it is, both are on vaultwarden-internal).
if podman container exists "$CADDY_CONTAINER" 2>/dev/null; then
  podman exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
    || { log "caddy reload failed; restarting vw-caddy"; $SC restart "${CADDY_CONTAINER}.service" || die "could not reload or restart Caddy"; }
  log "Caddy reloaded with the standby upstream"
else
  log "WARNING: '$CADDY_CONTAINER' not running on this host. Start/redeploy Caddy here, or update the active Caddy host's upstream manually."
fi

step "8. VALIDATE"
log "running acceptance checks (override BASE for your URL):"
if [[ -x "$HOME/vaultwarden/scripts/verify.sh" ]]; then
  "$HOME/vaultwarden/scripts/verify.sh" || log "verify.sh reported failures — investigate before declaring failover complete."
else
  log "verify.sh not found at \$HOME/vaultwarden/scripts/verify.sh — run deploy/scripts/verify.sh manually."
fi
cat <<'EOF'

  MANUAL VALIDATION (do these before declaring DONE — see README "Validation"):
    [ ] Log in via web vault; unlock succeeds (same rsa_key => no forced re-auth).
    [ ] WebSocket reconnects: /notifications/hub returns 101 and the client shows
        "connected" (edit an item on another device, see it sync live).
    [ ] Open an existing ATTACHMENT and create+download a SEND (proves /data synced).
    [ ] Two clients edit different items concurrently; both save without error.
    [ ] podman logs vaultwarden-standby shows DB connected + audit lines.

  EXPECTED EVIDENCE: pg_is_in_recovery()='f' on the promoted DB; vw-caddy access
  log shows upstream vaultwarden-standby:8080; standby app audit lines present.
EOF
log "FAILOVER COMPLETE. Record RTO actual + /data RPO gap in the incident log."
log "When the original primary is repaired, use failback.sh to return to it."
