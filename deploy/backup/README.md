# Vaultwarden — encrypted backups, PITR & tested restore (NIST CP-9/CP-10/MP)

Backup / recovery slice for the hardened podman deployment. Implements the
"Not yet built → Backups/PITR (CP-9/CP-10)" item from `deploy/README.md`.

Everything new lives in **`deploy/backup/`**. Nothing outside this directory is
edited; the one change needed to an existing file (the `nextvault-postgres` quadlet, to
turn on WAL archiving) is **documented, not applied** — see *Enabling PITR*.

## Files in this directory

| File | Purpose | NIST control |
|---|---|---|
| `backup.sh` | Daily encrypted backup: `pg_dump -Fc` of DB `vaultwarden` + tar of the `nextvault-data` volume (read-only mount), SHA-256 checksums, timestamped manifest. | CP-9, SC-28, SI-7, MP-5 |
| `restore.sh` | Restore a chosen set: integrity-check → decrypt → `pg_restore --clean` and/or replace `nextvault-data`. DESTRUCTIVE guards. | CP-10, SC-28, SI-7 |
| `basebackup.sh` | Physical `pg_basebackup` baseline for PITR (pairs with WAL archive). | CP-9, CP-10, SC-28 |
| `postgres-archive.conf` | WAL-archiving settings (documents the `-c` flags + WAL volume to add to the quadlet). | CP-9, CP-10, SC-28 |
| `create-backup-key.sh` | Creates the `vw_backup_key` podman secret; prints the key to escrow separately. | SC-12, SC-28, IA-5 |
| `nextvault-backup.service` | systemd **user** oneshot that runs `backup.sh`. | CP-9 |
| `nextvault-backup.timer` | systemd **user** timer — daily at **03:17** (off-peak, non-`:00`). | CP-9 |
| `README.md` | This file: operating procedure, RTO/RPO, offsite/immutable, separate-key, test-restore. | CP-9/CP-10/MP |

## Threat / design summary

- **Encryption at rest (SC-28):** every artifact is encrypted before it lands on
  `BACKUP_DEST`. Backend selection at runtime:
  - **`age`** if installed (`age -p`, scrypt symmetric, passphrase from the secret).
  - else **`openssl enc -aes-256-gcm`** with PBKDF2 (`-iter 600000`, random salt).
    **Choice & rationale:** `age` is preferred (modern AEAD, simple format) but is
    not installed on the current host, so the default in practice is
    `openssl aes-256-gcm` — an AEAD cipher providing confidentiality **and**
    integrity. Both read the key from the `vw_backup_key` podman secret; the key
    is materialised only into a `0700` tmp dir that is `shred`-ed on exit.
- **Least-privilege backup access:** scripts run **rootless** as the deploy user.
  The DB dump uses the existing superuser secret only via `podman exec` into the
  already-running container (no new published port, no new network role). The
  `nextvault-data` volume is mounted **read-only** (`:ro`) into a throwaway container
  with `--network=none --cap-drop=ALL --security-opt no-new-privileges`. Restore
  is the only path that mounts read-write, and only behind a typed confirmation.
- **Integrity (SI-7):** `SHA256SUMS` over the *ciphertext*; `restore.sh` verifies
  it **before** decrypting and refuses a corrupt set.

## Separate key (mandatory — SC-12/SC-28/IA-5)

The backup **encryption key** must be stored **separately** from the backups:

- The key lives only in the podman secret `vw_backup_key` (run
  `create-backup-key.sh`, which prints it once).
- **Escrow the printed key out-of-band** — password manager / KMS / HSM — and
  keep an offsite copy in a **different trust domain** than the offsite backups.
- A key co-located with the ciphertext provides no protection; a lost key makes
  every backup permanently unrecoverable. Both failure modes are called out in
  `create-backup-key.sh`.

## Offsite / immutable storage (MP-5, CP-9)

`BACKUP_DEST` (default `~/vaultwarden/backups`) is **local staging only** — not a
durable backup. You **must**:

1. **Replicate offsite** — to a remote host / object store in a different failure
   domain than the Vaultwarden host (and different from the key escrow).
2. **Make it write-once / immutable where available** — e.g. S3 Object Lock
   (compliance mode) or a WORM-capable target, so ransomware / a compromised
   deploy user cannot rewrite or delete history. The local `RETENTION_DAYS` prune
   only trims staging; the immutable offsite copy is the system of record.
3. **Ship the WAL archive too** (for PITR) alongside the base backups.

Suggested offsite step (run after the timer, or as a second timer):
`rclone copy ~/vaultwarden/backups <remote>:nextvault-backups --immutable` (or
`aws s3 sync ... --no-overwrite` against an Object-Lock bucket).

## RTO / RPO (operator to fill in)

These are commitments the operator/AO must set and test against; placeholders:

| Metric | Definition | Target (FILL IN) | Met by |
|---|---|---|---|
| **RPO** (Recovery Point Objective) | Max acceptable data loss. | `____` (e.g. ≤ 24h logical-only, or ≤ 5 min with PITR) | Daily `backup.sh` ⇒ ≤24h. WAL `archive_timeout=300s` ⇒ ≤5 min with PITR. |
| **RTO** (Recovery Time Objective) | Max acceptable time to restore service. | `____` (e.g. ≤ 2h) | `restore.sh` for logical; base backup + WAL replay for PITR. |
| **Base-backup cadence** | How often `basebackup.sh` runs. | `____` (e.g. weekly) | bounds WAL replay length. |
| **Restore-test cadence** | How often the test-restore below is exercised. | `____` (e.g. quarterly) | proves CP-9/CP-10. |

## Operating procedure

### One-time setup
```bash
# 1) Create the backup encryption key secret (escrow the printed key SEPARATELY).
deploy/backup/create-backup-key.sh

# 2) (Recommended) install age for stronger/simpler encryption; otherwise the
#    scripts fall back to openssl aes-256-gcm automatically.
#    e.g.  sudo apt install age   /   dnf install age

# 3) Install the systemd user timer (see Scheduling below).
```

### Manual backup
```bash
BACKUP_DEST=~/vaultwarden/backups deploy/backup/backup.sh
```
Produces `~/vaultwarden/backups/<UTC-timestamp>/` with `db-vaultwarden.dump.enc`,
`data-nextvault-data.tar.gz.enc`, `SHA256SUMS`, `manifest.txt`, and a `latest` symlink.

### Manual base backup (PITR baseline)
```bash
deploy/backup/basebackup.sh         # requires archive_mode=on (see below)
```

## Scheduling (systemd USER timer)

Quadlets can't express timers, so these are plain user units. Install to
`~/.config/systemd/user/`:

```bash
install -Dm644 deploy/backup/nextvault-backup.service ~/.config/systemd/user/nextvault-backup.service
install -Dm644 deploy/backup/nextvault-backup.timer   ~/.config/systemd/user/nextvault-backup.timer

# Make the scripts executable (repo ships them with shebangs; chmod here):
chmod +x deploy/backup/*.sh

# So the timer fires while you're logged out:
loginctl enable-linger "$USER"

systemctl --user daemon-reload
systemctl --user enable --now nextvault-backup.timer
systemctl --user list-timers nextvault-backup.timer      # confirm next run ~03:17
journalctl --user -u nextvault-backup.service            # last run's log
```
The service runs `%h/vaultwarden/deploy/backup/backup.sh`. If you keep the repo
elsewhere, edit `ExecStart=`/`Documentation=` in `nextvault-backup.service` accordingly,
or symlink `~/vaultwarden/deploy` to your checkout.

## Enabling PITR — DOCUMENTED edit to `nextvault-postgres.container` (not applied)

PITR needs (a) WAL archiving turned on and (b) a writable WAL-archive volume
(the postgres rootfs is `ReadOnly=true`). **These are documented here; do not
expect this slice to have edited the quadlet.** Apply them yourself in
`deploy/quadlet/`:

**1. New WAL-archive volume** — create `deploy/quadlet/nextvault-pgwal.volume`:
```ini
[Unit]
Description=PostgreSQL WAL archive for Vaultwarden PITR (NIST CP-9/CP-10)

[Volume]
VolumeName=nextvault-pgwal
# NIST MP/SC-28: must reside on encrypted-at-rest storage (same as nextvault-pgdata).

[Install]
WantedBy=default.target
```

**2. In `deploy/quadlet/nextvault-postgres.container`:**

- Add the volume + its ordering. Under `[Unit]` extend the existing lines:
  ```ini
  Requires=nextvault-pgdata-volume.service nextvault-pgwal-volume.service nextvault-internal-network.service
  After=nextvault-pgdata-volume.service nextvault-pgwal-volume.service nextvault-internal-network.service
  ```
- Under `[Container]`, mount the WAL volume:
  ```ini
  Volume=nextvault-pgwal.volume:/var/lib/postgresql/wal-archive:Z
  ```
- Append these flags to the existing `Exec=postgres \` line (mirrors
  `postgres-archive.conf`):
  ```
    -c archive_mode=on \
    -c wal_level=replica \
    -c archive_command='test ! -f /var/lib/postgresql/wal-archive/%f && cp %p /var/lib/postgresql/wal-archive/%f' \
    -c archive_timeout=300 \
    -c max_wal_size=1GB \
    -c log_checkpoints=on
  ```
  > `archive_mode` is **not** reloadable — this requires a container restart:
  > `systemctl --user daemon-reload && systemctl --user restart nextvault-postgres`.

Then run `basebackup.sh` to establish a baseline and ship both the base backup
and the `nextvault-pgwal` archive offsite. To recover to a point in time, restore a base
backup into a fresh data dir and set `recovery_target_time` with
`restore_command` pointing at the archived WAL (standard PostgreSQL PITR — out of
scope to script here, but the artifacts this slice produces are exactly what it
consumes).

## TEST-RESTORE procedure (proves CP-9/CP-10 acceptance)

Map to the handoff doc's CP acceptance criteria: *"backups exist, are encrypted,
and a restore has been demonstrated."* Run on the restore-test cadence above.

**Always restore into an ISOLATED environment first — never validate by
restoring over production.**

```bash
# 0. Pick a set (or 'latest') and list what's available.
deploy/backup/restore.sh --list

# 1. Stand up an ISOLATED target: a scratch postgres container + scratch volume,
#    NOT the production nextvault-postgres / nextvault-data. Example (rootless, throwaway):
podman volume create nextvault-data-test
podman run -d --name nextvault-postgres-test \
  --network=none -e POSTGRES_PASSWORD=test -e POSTGRES_DB=vaultwarden \
  -v nextvault-pgdata-test:/var/lib/postgresql/data docker.io/library/postgres:17.10

# 2. Restore the SET into the isolated targets (point the script at them):
PG_CONTAINER=nextvault-postgres-test PG_SUPERUSER=postgres PG_DB=vaultwarden \
DATA_VOLUME=nextvault-data-test \
  deploy/backup/restore.sh --set latest --do-db --do-data
#   (Use FORCE=1 here since it's a disposable test env.)

# 3. VALIDATE:
#    - DB: row counts on key tables are sane, no pg_restore errors.
podman exec nextvault-postgres-test psql -U postgres -d vaultwarden \
  -c "select count(*) from users;" -c "select count(*) from ciphers;"
#    - Data: rsa_key.pem / config.json present, attachments/ and sends/ restored.
podman run --rm --network=none -v nextvault-data-test:/d:ro docker.io/library/postgres:17.10 \
  sh -c 'ls -la /d && test -f /d/rsa_key.pem && echo "rsa key present"'

# 4. KEEP ROLLBACK: only after validation, restore production — and FIRST take a
#    rollback snapshot so a bad restore is reversible:
deploy/backup/backup.sh                       # fresh pre-restore safety set
#    then run restore.sh against the REAL nextvault-postgres / nextvault-data (no FORCE — type
#    RESTORE at the prompt). restore.sh stops nextvault.service during the data
#    restore and restarts it after.

# 5. TEAR DOWN the isolated env.
podman rm -f nextvault-postgres-test; podman volume rm nextvault-data-test nextvault-pgdata-test
```

Record each test (date, set restored, RTO observed, pass/fail) as evidence for
CP-9/CP-10.

## Documented (NOT applied) edits to existing files

This slice did **not** modify anything outside `deploy/backup/`. To go live you
must apply, in `deploy/quadlet/`:

1. **New `nextvault-pgwal.volume`** unit (full content above) — the WAL-archive volume.
2. **`nextvault-postgres.container`** — add the `nextvault-pgwal` volume + ordering and the
   `archive_*` / `wal_level` / `max_wal_size` / `log_checkpoints` `-c` flags to
   the `Exec=` line (exact lines above), then restart the container.

No other existing files require changes for the daily logical backup path; PITR
is the only part that needs the quadlet edits.
