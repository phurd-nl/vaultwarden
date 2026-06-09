#!/usr/bin/env bash
# =============================================================================
# create-backup-key.sh — create the podman secret holding the BACKUP ENCRYPTION
# KEY (vw_backup_key) used by backup.sh / basebackup.sh / restore.sh.
#
# NIST 800-53B Moderate: SC-12 (key establishment), SC-28 (the key protects
# backups at rest), IA-5 (the key is a credential — escrow it, don't lose it).
#
# *** SEPARATE-KEY REQUIREMENT (mandatory) ***
#   A backup encrypted with a key stored next to it is NOT protected. After
#   creating this secret you MUST escrow the plaintext key OUT-OF-BAND:
#     - print it (below) and store it in your password manager / KMS / HSM, AND
#     - keep it OFF the same media/host as the backups (offsite copy of the key
#       lives in a different trust domain than the offsite copy of the backups).
#   If you lose this key, every backup is permanently unrecoverable. If an
#   attacker gets BOTH the backups and this key, encryption bought you nothing.
#
# Idempotent-ish: refuses to overwrite an existing secret unless --force.
# Mirrors deploy/secrets/create-secrets.sh conventions.
# =============================================================================
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

SECRET_NAME="vw_backup_key"

# A long, high-entropy passphrase. Works for both backends:
#   - openssl enc  : used as the PBKDF2 passphrase.
#   - age -p       : used as the scrypt symmetric passphrase (AGE_PASSPHRASE).
gen_key() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64; }

if podman secret exists "$SECRET_NAME" 2>/dev/null; then
  if [[ "$FORCE" -eq 1 ]]; then
    podman secret rm "$SECRET_NAME" >/dev/null
  else
    echo "[skip] secret '$SECRET_NAME' already exists (use --force to replace)."
    echo "       WARNING: replacing the key makes EXISTING backups undecryptable."
    exit 0
  fi
fi

KEY="$(gen_key)"
printf '%s' "$KEY" | podman secret create "$SECRET_NAME" - >/dev/null
echo "[ok]   created secret '$SECRET_NAME'"

cat <<EOF

--------------------------------------------------------------------------
BACKUP ENCRYPTION KEY (escrow this NOW, then clear your scrollback):

  $KEY

NIST SC-12/SC-28/IA-5 — store this key SEPARATELY from the backups:
  * password manager / KMS / HSM entry, AND
  * an offsite copy in a different trust domain than the backup media.

Losing this key = unrecoverable backups. Co-locating it with backups =
no protection. (See deploy/backup/README.md "Separate key".)
--------------------------------------------------------------------------
EOF
