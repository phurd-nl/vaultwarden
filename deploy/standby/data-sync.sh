#!/usr/bin/env bash
# =============================================================================
# data-sync.sh — replicate the Vaultwarden /data volume (vw-data) to the warm
# standby's /data (standby-data) on a schedule (NIST 800-53B Moderate: CP-10).
#
# WHY THIS EXISTS
#   PostgreSQL streaming replication (setup-replication.sh) keeps the DATABASE
#   consistent, but Vaultwarden also stores state OUTSIDE the DB in /data:
#     * attachments/        (encrypted file attachments)
#     * sends/              (Bitwarden Send payloads)
#     * rsa_key.pem / .pub  (the keypair that signs/validates JWTs — CRITICAL:
#                            if the standby has a DIFFERENT rsa_key, every issued
#                            token is invalid after failover and ALL clients are
#                            forced to re-auth. Syncing /data carries the SAME
#                            key over, so sessions survive failover.)
#     * config.json         (only if drift exists; treat as drift — see README)
#   This script rsyncs vw-data -> standby-data so the failed-over app serves the
#   same attachments/sends and the same JWT signing key.
#
# TWO TOPOLOGIES (pick one; both supported):
#   * SHARED STORAGE  — both app instances mount the SAME /data (e.g. the volume
#     backing store is on shared/replicated block or NFS). Then you do NOT need
#     this script at all; set MODE=shared to make it a no-op that just records
#     that /data is shared. RPO for /data = 0.
#   * TWO HOSTS       — primary and standby on different hosts. This script
#     rsyncs over SSH from the primary host into the standby host's standby-data
#     volume backing path. RPO for /data = up to one sync interval.
#
# CONSISTENCY CAVEAT (called out in README "Consistency caveat"):
#   /data is rsynced on an INTERVAL while the primary is live, so it is
#   crash-consistent, NOT transactionally consistent with the DB. On failover,
#   attachments/sends created AFTER the last successful sync may be missing even
#   though the DB row exists (the replica streamed the row but the file hadn't
#   synced). failover.sh runs a FINAL sync if the primary host is still
#   reachable to shrink this window to ~0; if the primary is GONE, the gap = the
#   data written since the last scheduled sync. This is the /data RPO.
#
# This runs READ-ONLY against the source: the vw-data volume is mounted :ro into
# a throwaway, network-isolated, cap-dropped container that tars it to stdout, or
# rsync reads it directly. Nothing writes to vw-data.
# =============================================================================
set -euo pipefail

MODE="${MODE:-twohost}"                       # twohost | shared | local
SRC_VOLUME="${SRC_VOLUME:-vw-data}"
DST_VOLUME="${DST_VOLUME:-standby-data}"       # used in MODE=local (single host)
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:17.5}"  # any image with rsync; reuse a present one

# MODE=twohost settings — EDIT for your standby host.
STANDBY_SSH="${STANDBY_SSH:-deploy@standby-host}"     # ssh user@host of the standby
# Path on the STANDBY host where the standby-data volume backing store lives.
# For rootless podman that is typically:
#   ~/.local/share/containers/storage/volumes/standby-data/_data
STANDBY_DATA_PATH="${STANDBY_DATA_PATH:-/home/deploy/.local/share/containers/storage/volumes/standby-data/_data}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o BatchMode=yes}"

log() { printf '%s [data-sync] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s [data-sync] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || die "podman not found"

case "$MODE" in
  shared)
    log "MODE=shared: /data is on shared/replicated storage; no rsync needed (RPO=0)."
    log "Ensure both vaultwarden.container and vaultwarden-standby.container mount the SAME backing path."
    exit 0
    ;;

  local)
    # Single host: rsync between two local volumes via a throwaway container that
    # mounts SOURCE read-only and DEST read-write. --delete keeps them identical;
    # we exclude tmp/lock-ish paths. -a preserves perms/owner so rsa_key.pem keeps mode.
    podman volume exists "$SRC_VOLUME" 2>/dev/null || die "source volume '$SRC_VOLUME' missing"
    log "MODE=local: rsync $SRC_VOLUME (ro) -> $DST_VOLUME"
    podman run --rm --network=none --cap-drop=ALL --security-opt no-new-privileges \
      -v "$SRC_VOLUME":/src:ro -v "$DST_VOLUME":/dst \
      "$PG_IMAGE" \
      sh -c 'command -v rsync >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq rsync >/dev/null);
             rsync -a --delete --exclude="tmp/" /src/ /dst/' \
      || die "local rsync failed"
    log "local /data sync complete (crash-consistent; see consistency caveat)."
    ;;

  twohost)
    # Two hosts: stream the source volume over SSH and rsync into the standby
    # host's backing path. We rsync from a local checkout of the volume via
    # `podman volume export`-style tar OR a direct bind. Simplest robust path:
    # mount the source :ro into a throwaway container and rsync over SSH.
    podman volume exists "$SRC_VOLUME" 2>/dev/null || die "source volume '$SRC_VOLUME' missing"
    command -v rsync >/dev/null 2>&1 || die "rsync not found on the primary host (needed for MODE=twohost)"
    command -v ssh   >/dev/null 2>&1 || die "ssh not found"

    # Resolve the source volume's backing mountpoint on this host (rootless).
    SRC_PATH="$(podman volume inspect "$SRC_VOLUME" --format '{{.Mountpoint}}' 2>/dev/null)" \
      || die "cannot inspect volume '$SRC_VOLUME'"
    [[ -d "$SRC_PATH" ]] || die "source mountpoint '$SRC_PATH' not a directory"

    log "MODE=twohost: rsync $SRC_PATH/ -> $STANDBY_SSH:$STANDBY_DATA_PATH/"
    # -a preserve attrs (rsa_key.pem mode), -z compress, --delete mirror,
    # --partial resume, exclude transient tmp. The dest path MUST be the standby
    # volume's backing dir; the standby app must be STOPPED when it reads it
    # (it is, until failover) so there is no writer on the dest.
    rsync -az --delete --partial --exclude='tmp/' \
      -e "ssh $SSH_OPTS" \
      "$SRC_PATH/" "$STANDBY_SSH:$STANDBY_DATA_PATH/" \
      || die "rsync over SSH failed (check key auth, path, and SELinux on the standby)"
    log "two-host /data sync complete (crash-consistent; see consistency caveat)."
    ;;

  *)
    die "unknown MODE='$MODE' (expected: twohost | shared | local)"
    ;;
esac

log "OK. RPO for /data = time since this ran. failover.sh runs a FINAL sync if"
log "    the primary is still reachable to shrink the gap to ~0."
