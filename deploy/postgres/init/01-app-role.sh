#!/bin/bash
# Runs once on first DB init (docker-entrypoint-initdb.d). Creates the
# least-privilege application role (NIST AC-6). The app role is NOT a superuser;
# it owns only its own database so diesel migrations can run DDL.
set -euo pipefail

APP_PW="$(cat /run/secrets/vw_db_app_password)"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=app_pw="$APP_PW" <<'SQL'
SELECT format('CREATE ROLE vaultwarden WITH LOGIN PASSWORD %L', :'app_pw')
\gexec
ALTER DATABASE vaultwarden OWNER TO vaultwarden;
ALTER SCHEMA public OWNER TO vaultwarden;
GRANT ALL ON SCHEMA public TO vaultwarden;
REVOKE ALL ON DATABASE vaultwarden FROM PUBLIC;
SQL

echo "[init] least-privilege role 'vaultwarden' created and granted ownership of database 'vaultwarden'."
