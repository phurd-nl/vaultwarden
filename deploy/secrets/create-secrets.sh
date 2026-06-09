#!/usr/bin/env bash
# Create the podman secrets for the Vaultwarden stack (NIST IA-5 / SC).
# Idempotent-ish: refuses to overwrite an existing secret unless --force.
#
# Creates:
#   vw_pg_superuser_password  - postgres bootstrap superuser password
#   vw_db_app_password        - least-privilege app role password
#   vw_database_url           - full DATABASE_URL (TLS verify-full) for the app
#
# Does NOT create vw_admin_token — you set that yourself (see end of script),
# so the admin credential never passes through this tooling.
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# EDIT to match deploy/config/vaultwarden.env DOMAIN host and the cert SAN.
DB_HOST="nextvault-postgres"
DB_NAME="vaultwarden"
DB_USER="vaultwarden"
CA_PATH_IN_APP="/etc/ssl/certs/internal-ca.crt"

gen_pw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40; }

put_secret() {
	local name="$1" value="$2"
	if podman secret exists "$name" 2>/dev/null; then
		if [[ "$FORCE" -eq 1 ]]; then
			podman secret rm "$name" >/dev/null
		else
			echo "[skip] secret '$name' already exists (use --force to replace)"
			return 0
		fi
	fi
	printf '%s' "$value" | podman secret create "$name" - >/dev/null
	echo "[ok]   created secret '$name'"
}

SUPER_PW="$(gen_pw)"
APP_PW="$(gen_pw)"   # alnum only => safe to embed in a URL without escaping
DATABASE_URL="postgresql://${DB_USER}:${APP_PW}@${DB_HOST}:5432/${DB_NAME}?sslmode=verify-full&sslrootcert=${CA_PATH_IN_APP}"

put_secret vw_pg_superuser_password "$SUPER_PW"
put_secret vw_db_app_password       "$APP_PW"
put_secret vw_database_url           "$DATABASE_URL"

cat <<'EOF'

--------------------------------------------------------------------------
DB secrets created. Now set the admin token yourself (NIST IA-5):

  # Generate an Argon2id PHC string interactively and store it as a secret.
  # 'vaultwarden hash' prompts for the token and prints the PHC.
  podman run --rm -it localhost/nextvault:latest /vaultwarden hash \
    | tail -n1 | podman secret create vw_admin_token -

  # Keep the PLAINTEXT token in your password manager — you type it at /admin.
  # Only the Argon2 hash is stored as the secret.

Also set the Entra SSO client secret yourself (NIST IA-5), same posture:

  # Paste the client-secret VALUE from the Entra app registration
  # (Certificates & secrets). It never passes through this tooling.
  printf '%s' '<ENTRA_CLIENT_SECRET_VALUE>' | podman secret create vw_sso_client_secret -
--------------------------------------------------------------------------
EOF
