# Recovery Objectives (RTO / RPO) — NextVault

**Status:** DRAFT — targets are `[DECISION NEEDED]`; the "delivered" column
reflects what the current backup/PITR + standby design actually provides.

## Definitions
- **RTO (Recovery Time Objective):** max tolerable time to restore service after
  an outage.
- **RPO (Recovery Point Objective):** max tolerable data loss, measured as time
  between the last recoverable state and the incident.

## Targets vs. delivered

| Scenario | RTO target | RPO target | What the current design delivers |
|---|---|---|---|
| DB corruption / bad write | `[SET]` | `[SET]` | **RPO ≈ ≤5 min** via WAL archiving (`archive_timeout=300`) + base backup → PITR replay; **RTO** = restore-drill time (see below), currently **measured non-destructively only**. |
| Full VM loss | `[SET]` | `[SET]` | **RPO ≤ 24 h** from the daily encrypted backup (timer ~03:17 UTC) — **less** if base+WAL are shipped offsite. **RTO** = VM rebuild via `deploy/VM-BRINGUP.md` + restore; **not yet timed end-to-end.** |
| `/data` loss (attachments/Sends/keys) | `[SET]` | `[SET]` | Captured in the same daily set (`data-*.tar.gz.enc`); RPO = backup interval. |
| Region/site loss | `[SET]` | `[SET]` | **Gap** — offsite/immutable backup copy not yet implemented (`BACKUP_DEST` is local staging); warm standby not yet stood up (second VM). |

## Current backup capability (evidence)

- **Daily encrypted backup** — `deploy/backup/` slice live on the VM: `pg_dump`
  (custom format) + `/data` tar, age-encrypted (X25519 identity), `SHA256SUMS`
  integrity, 30-day retention, `OnFailure=` alarm. **Verified restorable**
  non-destructively (decrypt + `pg_restore --list` → valid TOC, 132 entries).
- **PITR** — WAL archiving on (`archive_mode=on`, `archive_command` → encrypted-
  at-rest `nextvault-pgwal` volume, `archive_timeout=300`). Base backup via
  `deploy/backup/basebackup.sh`.
- **DR runbooks** — restore (`deploy/backup/restore.sh` + README), manual
  failover/failback (`deploy/standby/README.md`).

## Open items to make these real `[DECISION NEEDED]` / work

1. **Set the four target pairs above** (owner + AO) — drives whether the standby
   (second VM) is required for the Availability categorization.
2. **Run a timed end-to-end restore drill** (DB + `/data` into a scratch
   environment) and record observed RTO/RPO here as assessment evidence. The
   non-destructive `pg_restore --list` test passed; a full timed restore has not
   been done.
3. **Implement offsite/immutable backup copy** (e.g. rclone → object storage
   with Object Lock) — closes the region/site-loss row. The backup key (age
   identity) is already escrowed off-host in a separate trust domain.
4. **Stand up + drill the warm standby** (`deploy/standby/`) if the Availability
   target requires it.

## Sign-off

| Role | Name | RTO/RPO approved | Date | Signature |
|---|---|---|---|---|
| System Owner | `[OWNER]` | | | |
| Authorizing Official | `[AO]` | | | `[AO SIGNATURE]` |
