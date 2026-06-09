# Vaultwarden — warm standby + manual failover (NIST 800-53B Moderate, CP-10)

Active-**passive** warm standby for the hardened podman deployment. Implements
the "Not yet built → Warm standby + manual failover (CP-10)" item from
`deploy/README.md`.

Everything new lives in **`deploy/standby/`**. Nothing outside this directory is
edited. The changes needed to the EXISTING primary (extra `-c` flags on the
`vw-postgres` quadlet Exec line, one `pg_hba.conf` line, one new secret) are
**documented here, not applied** — see *Primary-side config additions*.

## HA model (decided)

**Active-passive, single-active, MANUAL failover.** Exactly one app instance
serves traffic at a time. The standby app and the streaming DB replica run warm
(replica streaming WAL; `/data` rsynced on a timer) but the standby is **not in
Caddy's upstream** and is **not auto-started** until an operator runs
`failover.sh`. This deliberately avoids split-brain: we never load-balance writes
across two app instances or two databases.

```
   NORMAL (active)                         AFTER failover.sh (passive promoted)
   ───────────────                         ────────────────────────────────────
   vw-caddy ─► vaultwarden:8080            vw-caddy ─► vaultwarden-standby:8080
                  │                                          │
            vw-postgres (RW)  ──stream──►  vw-postgres-standby (RO, hot standby)
                  │           WAL/TLS+slot         │ pg_promote() ► RW
            vw-data  ──data-sync.sh (rsync)──►  standby-data
```

## Files in this directory

| File | Purpose | NIST control |
|---|---|---|
| `vaultwarden-standby.container` | Second app instance quadlet, byte-identical hardening to the primary; **no `[Install]`** so it is never auto-started; mounts `vw_database_url_standby`. | CP-10, AC-6, SC-8 |
| `standby-data.volume` | The standby app's `/data` (rsync target of `vw-data`). | CP-10, MP, SC-28 |
| `vw-postgres-standby.container` | PostgreSQL streaming **replica** (hot standby): `primary_conninfo` + physical slot over TLS `verify-full`. No `[Install]`. | CP-10, SC-8, IA-5 |
| `standby-pgdata.volume` | Replica data dir (seeded by `pg_basebackup`, then WAL-streamed). | CP-10, MP, SC-28 |
| `setup-replication.sh` | One-time bootstrap: creates the least-priv replication role + slot on the primary and `pg_basebackup -R` seeds the replica. | CP-10, AC-6, IA-5 |
| `data-sync.sh` | rsync `vw-data` → `standby-data` (two-host / shared / local modes). | CP-10, MP-5 |
| `vw-data-sync.service` / `.timer` | systemd **user** timer that runs `data-sync.sh` every 5 min. | CP-10 |
| `failover.sh` | Guarded promote-and-cutover runbook script. | CP-10 |
| `failback.sh` | Guarded reverse: re-seed old primary as replica, catch up, switch back. | CP-10 |
| `Caddyfile.standby-upstream.snippet` | The exact Caddy upstream edit + reload (documented alt to the in-place `sed`). | CP-10, SC-8 |
| `README.md` | This file: runbooks, RTO/RPO, acceptance criteria, NIST mapping. | CP-10 |

## NIST control mapping (CP-10 and supporting)

| Artifact | Primary control | Why |
|---|---|---|
| `vw-postgres-standby.container` + `setup-replication.sh` | **CP-10** (recovery/reconstitution) | A continuously-updated copy of the DB to recover onto. |
| `data-sync.sh` + timer | **CP-10**, MP-5 | The non-DB state (`/data`: attachments, sends, `rsa_key.pem`) is also replicated. |
| `vaultwarden-standby.container` | **CP-10**, AC-6 | A pre-built, identically-hardened app ready to take over; least-privilege preserved. |
| `failover.sh` / `failback.sh` | **CP-10** | Tested, repeatable recovery and reconstitution procedures with split-brain guards. |
| TLS `verify-full` on `primary_conninfo` + `hostssl` replication | SC-8, IA-5 | Replication traffic is encrypted and mutually validated; replication role is SCRAM, non-superuser. |
| Distinct `vw_database_url_standby` secret | IA-5 | Failover repoints the DB without touching the primary's secret. |
| Encrypted backing store for `standby-*` volumes | SC-28, MP | Standby copies get the same at-rest protection as production. |

> CP-10 is "transaction recovery / reconstitution." Streaming replication + the
> `/data` sync provide the up-to-date alternate copy; the runbook scripts provide
> the tested procedure to reconstitute service onto it. This composes with the
> `deploy/backup/` slice (CP-9 backups + PITR), which remains the cold-recovery
> path of last resort.

---

## Primary-side config additions (DOCUMENTED — do NOT edit existing files)

The existing `deploy/quadlet/vw-postgres.container` and
`deploy/postgres/pg_hba.conf` need three small additions to support a replica.
Apply these to your **installed** copies (`~/vaultwarden/...`) or to the repo
files in a separate, reviewed change — they are intentionally not applied here.

### 1. `vw-postgres.container` Exec flags

Add these `-c` flags to the existing `Exec=postgres \` block (PG 17 defaults to
`wal_level=replica`, but pin it for clarity; senders/slots must be raised):

```
  -c wal_level=replica \
  -c max_wal_senders=10 \
  -c max_replication_slots=10 \
  -c wal_keep_size=512MB \
  -c hot_standby=on
```

`wal_keep_size` is a safety margin so a briefly-disconnected replica can resume
from the slot without a full re-seed. (If you already added the `deploy/backup/`
PITR flags, `wal_level=replica` is shared — set it once.)

### 2. `pg_hba.conf` — replication line

Add a TLS-only SCRAM line for the special `replication` pseudo-database from the
internal subnet (mirrors the existing app/superuser style):

```
# Streaming replication for the warm standby (NIST CP-10): TLS-only, SCRAM.
hostssl     replication  vw_replicator  10.89.10.0/24    scram-sha-256
```

Place it **above** the catch-all `reject` lines. `setup-replication.sh` creates
the `vw_replicator` role and password secret.

### 3. New podman secret

`setup-replication.sh` creates `vw_replication_password` automatically if absent;
escrow it like the other secrets. The replica quadlet mounts it; the primary
stores only the SCRAM verifier.

### TLS for the replica

The replica reuses `~/vaultwarden/tls/postgres` (so a promoted replica still
satisfies the app's `verify-full`). In a two-host topology the server cert SAN
**must also cover the replica's hostname** (`vw-postgres-standby`, or whatever
name the app connects to after promotion). Add that SAN when you issue the cert.

### Standby `DATABASE_URL` secret

Create the standby app's DB URL once (initially pointing at the replica host;
`failover.sh` rewrites it on promotion):

```bash
APP_PW=$(podman secret inspect --showsecret --format '{{.SecretData}}' vw_db_app_password)
printf '%s' "postgresql://vaultwarden:${APP_PW}@vw-postgres-standby:5432/vaultwarden?sslmode=verify-full&sslrootcert=/etc/ssl/certs/internal-ca.crt" \
  | podman secret create vw_database_url_standby -
unset APP_PW
```

### Install the quadlets/units

Copy the standby quadlets next to the others and the timer/service into the
user units dir, then `daemon-reload`:

```bash
cp deploy/standby/*.container deploy/standby/*.volume "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/"
cp deploy/standby/vw-data-sync.{service,timer}        "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/"
cp -r deploy/standby                                   "$HOME/vaultwarden/standby"   # scripts referenced by the unit
systemctl --user daemon-reload
chmod +x "$HOME/vaultwarden/standby/"*.sh
```

---

## Standing up the standby (one time)

```bash
# 0. Apply the primary-side additions above and restart vw-postgres so
#    wal_level/max_wal_senders/the hostssl replication line take effect.
systemctl --user restart vw-postgres.service

# 1. Create the replication role + slot on the primary and seed the replica.
deploy/standby/setup-replication.sh

# 2. Start the replica; confirm it is streaming.
systemctl --user start vw-postgres-standby.service
podman exec vw-postgres psql -U postgres -xc \
  "SELECT client_addr,state,sync_state,replay_lag FROM pg_stat_replication;"
podman exec vw-postgres-standby psql -U postgres -tAc 'SELECT pg_is_in_recovery();'  # => t

# 3. Create the vw_database_url_standby secret (see above).

# 4. Pick a /data topology and enable the sync timer (default MODE=twohost;
#    EDIT vw-data-sync.service for shared/local + your STANDBY_SSH/PATH).
systemctl --user enable --now vw-data-sync.timer
systemctl --user start vw-data-sync.service   # first sync now
```

The standby app (`vaultwarden-standby.service`) stays **stopped** — it is started
only by `failover.sh`.

## `/data` replication — topologies & the consistency caveat

`data-sync.sh` supports three `MODE`s:

- **`shared`** — both app instances mount the **same** `/data` backing store
  (shared/replicated block, NFS, etc.). No rsync; `/data` RPO = 0. Simplest
  consistency story, but the storage layer must itself be HA.
- **`twohost`** *(default)* — primary and standby on **different hosts**;
  `data-sync.sh` rsyncs `vw-data` over SSH into the standby host's
  `standby-data` backing path. `/data` RPO = up to one sync interval (5 min).
- **`local`** — both on one host, two local volumes (useful for testing the
  failover mechanics before you have a second host).

**Consistency caveat (mandatory read before failover):** the DB is replicated
*synchronously-ish* via WAL streaming (seconds of lag), but `/data` is rsynced on
an **interval** and is only **crash-consistent**, not transactionally consistent
with the DB. After a hard primary loss, an attachment/Send whose DB row was
streamed to the replica but whose **file** had not yet synced will be **missing**
on the standby (a dangling reference). `failover.sh` runs a **final sync** if the
old primary host is still reachable, shrinking this to ~0; if the primary is
gone, the gap equals everything written since the last scheduled sync — **this is
the `/data` RPO**, and it can differ from the DB RPO. Record the realised gap in
the incident log. Choose `shared` storage if a non-zero `/data` RPO is
unacceptable.

> `rsa_key.pem` lives in `/data` and signs JWTs. Syncing `/data` carries the
> **same** signing key to the standby, so existing client sessions survive
> failover (no forced re-auth). If you ever regenerate it on only one side,
> every token becomes invalid after cutover.

---

## RTO / RPO (placeholders — fill in after a timed drill)

| Metric | Target (PLACEHOLDER — set per your policy) | Notes |
|---|---|---|
| **RTO** (time to restore service) | `____` (e.g. ≤ 15 min) | Measured wall-clock for `failover.sh` from invocation to validated service. |
| **RPO — database** | `____` (e.g. ≤ a few seconds) | Bounded by streaming replication lag at failure. ~0 if the primary was reachable for a final flush; otherwise the un-streamed WAL tail. |
| **RPO — `/data`** | `____` (e.g. ≤ 5 min) | Bounded by the `vw-data-sync.timer` interval, unless `MODE=shared` (RPO 0) or a successful final sync. |

Fill these from the acceptance drill below; CP-10 expects documented, *tested*
objectives, not aspirational ones.

---

## RUNBOOK — MANUAL FAILOVER

**Purpose:** restore service onto the warm standby when the primary app or DB is
lost or must be taken down. (NIST CP-10.)

**Preconditions**
- Replica is streaming and caught up: `pg_stat_replication.state = 'streaming'`,
  replay lag within `MAX_LAG_BYTES` (default 16 MiB).
- `vw-data-sync.timer` has been running (recent successful sync).
- `vw_database_url_standby` secret exists.
- You have decided failover is warranted (primary down, or planned).

**Required access**
- The rootless **deploy user** shell on the host that runs (or will run) Caddy +
  the standby. `podman`, `systemctl --user`, and write access to the Caddyfile.

**Steps**
1. Announce the maintenance/incident; note start time (RTO clock starts).
2. Run the guarded script:
   ```bash
   deploy/standby/failover.sh
   ```
   It will, with typed confirmations: check replica health → **stop the old
   primary app** (fence) → final `/data` sync (best effort) → `pg_promote()` →
   repoint `vw_database_url_standby` → start `vaultwarden-standby` → switch the
   Caddy upstream to `vaultwarden-standby:8080` and reload → run `verify.sh`.
3. If the primary HOST is gone, run on the standby host; the fence step is a
   no-op (already down) and the final sync will warn — record the `/data` gap.

**Validation** (do all; this is the CP-10 evidence)
- `verify.sh` passes (TLS reachable, signups disabled, **WebSocket → 101**, no
  published DB port).
- Promoted DB is writable: `podman exec vw-postgres-standby psql -U postgres -tAc
  'SELECT pg_is_in_recovery();'` → `f`.
- **WebSocket reconnect:** log in to the web vault; the client shows "connected";
  edit an item on a second device and watch it sync live (proves `/notifications/hub`
  upgrades through Caddy to the standby).
- **Attachments / Sends:** open an existing attachment and create + download a
  Send (proves `/data` synced and `rsa_key.pem` matches).
- **Concurrent editing:** two clients edit different items simultaneously; both
  save without conflict errors.
- `vw-caddy` access log shows upstream `vaultwarden-standby:8080`.

**Expected logs / evidence**
- `vw-postgres-standby`: `database system is ready to accept connections` and a
  promotion line (`received promote request` / `selected new timeline ID`).
- `vaultwarden-standby`: DB connection established + `vaultwarden::audit` lines on
  the first login.
- Saved Caddyfile backup `Caddyfile.pre-failover.<ts>`.

**Rollback (failover didn't take)**
- If promotion succeeded but cutover failed, the safest path is to finish cutover
  (the DB is already promoted; you cannot un-promote without a re-seed).
- If you must abort BEFORE promotion: restart the primary app
  (`systemctl --user start vaultwarden.service`), leave the replica streaming, and
  restore the Caddyfile from the `.pre-failover.<ts>` backup, then
  `podman exec vw-caddy caddy reload --config /etc/caddy/Caddyfile`.

**Escalation**
- DB will not promote / replica corrupt → fall back to the `deploy/backup/`
  PITR restore (CP-9) onto a fresh DB; this is a longer-RTO path.
- Split-brain suspected (both apps wrote) → STOP both apps, identify the
  authoritative DB by latest LSN/timeline, escalate to the DBA on-call before
  resuming. Never run two app instances against two diverged DBs.

---

## RUNBOOK — MANUAL FAILBACK

**Purpose:** return service from the standby to the original primary after it is
repaired. **Planned** operation with a short write-freeze. (NIST CP-10.)

**Preconditions**
- Standby is the live, writable primary (`pg_is_in_recovery()` → `f`).
- Original primary host/DB is repaired and reachable on the internal network.
- A maintenance window is scheduled (brief write freeze during the switch).

**Required access** — same as failover, on the host controlling the stack.

**Key point:** the old primary's data dir is **stale and diverged** after a
failover. `failback.sh` does **not** just flip switches — it **re-seeds** the old
primary as a replica of the now-live standby, lets it catch up, and only then
switches in the reverse direction.

**Steps**
1. Schedule/announce the window.
2. Run:
   ```bash
   deploy/standby/failback.sh
   ```
   With confirmations it: re-seeds `vw-pgdata` from the standby (`pg_basebackup`,
   **destructive**) → starts the old primary as a streaming replica → waits for
   catch-up → **stops the standby app** (write freeze) → reverse `/data` sync →
   `pg_promote()` the original primary → repoint `vw_database_url` → start
   `vaultwarden` → switch Caddy upstream back to `vaultwarden:8080` and reload.
3. Re-establish protection (script prints the commands): re-seed the standby DB
   as a replica again and re-enable `vw-data-sync.timer`.

**Validation** — same checklist as failover (login, WebSocket 101 + live sync,
attachment, Send, concurrent edit), plus: `vw-caddy` access log shows upstream
`vaultwarden:8080` again, and `vw-postgres-standby` is back in recovery
(streaming) once re-established.

**Rollback** — if catch-up never completes or promotion of the original fails,
**stay on the standby** (it is unaffected until the write-freeze step), restore
the Caddyfile from the `.pre-failback.<ts>` backup if it was touched, and
re-investigate the primary.

**Escalation** — same as failover.

---

## HA acceptance criteria (CP-10 — run as a timed drill in a staging copy)

Each must pass; record results + timings and use them to fill the RTO/RPO table.

| # | Test | Pass criterion |
|---|---|---|
| 1 | **Restart active app** — `systemctl --user restart vaultwarden.service` | Service returns; clients reconnect; WebSocket → 101; no data loss. |
| 2 | **Kill active app** — `systemctl --user stop vaultwarden.service` (no failover) | Caddy returns 502 for the primary upstream; standby is NOT auto-serving (proves active-passive, manual). |
| 3 | **Fail over** — `failover.sh` | Standby promoted + serving; full validation checklist passes; RTO recorded. |
| 4 | **Fail back** — `failback.sh` | Original primary serving again; replica re-established; validation passes. |
| 5 | **Fail DB primary** — `systemctl --user stop vw-postgres.service`, then `failover.sh` | Promotion succeeds on whatever WAL the replica had; DB RPO = streamed lag at stop; service restored on the standby. |
| 6 | **Concurrent editing** — two authenticated clients edit different items at once, before and after a failover | Both edits persist; live sync via WebSocket works on both; no split-brain (single live DB throughout). |

Drill in a **staging copy** of the stack first; production drills require a
maintenance window.

## Operational notes / gotchas

- **One writer, always.** The standby app has no `[Install]` and the replica is
  read-only until promoted. `failover.sh` fences the old primary app before
  promoting. Do not start `vaultwarden-standby.service` by hand against the
  read-only replica — it will fail to write and may confuse clients.
- **Image/version parity.** Replica and primary Postgres **major versions must
  match** for streaming; pin the same digest. The two app instances must run the
  identical fork image so behaviour and `config.json` semantics match (CM-2).
- **Replication slot disk use.** A physical slot makes the primary retain WAL for
  an offline replica indefinitely — if the standby is down for a long time, WAL
  can fill the primary's disk. Monitor `pg_replication_slots.wal_status`; drop a
  dead slot (`pg_drop_replication_slot`) if you abandon the replica.
- **`config.json` drift.** As in the base deployment, don't change settings via
  `/admin`; the env file is the source of truth. A `config.json` synced in `/data`
  is treated as drift on both sides.
- **Timer collision.** `vw-data-sync.timer` (every 5 min) is randomized 30s and
  is `Nice`/`idle`-scheduled so it never contends with the 03:17 backup timer.
- **This composes with `deploy/backup/`.** Streaming replication is *not* a
  backup (a bad `DELETE` replicates instantly). Keep CP-9 backups + PITR as the
  recovery-of-last-resort; the standby is for fast CP-10 service continuity.
```
