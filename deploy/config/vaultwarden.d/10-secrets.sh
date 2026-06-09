# Sourced by /start.sh at container launch (this fork has no native _FILE support,
# but start.sh sources /etc/vaultwarden.d/*.sh). Exports secrets from podman
# secret mount files into the environment so they never appear in env files,
# manifests, or `podman inspect`. NIST IA-5 / SC.

if [ -r /run/secrets/vw_admin_token ]; then
    ADMIN_TOKEN="$(cat /run/secrets/vw_admin_token)"
    export ADMIN_TOKEN
fi

if [ -r /run/secrets/vw_database_url ]; then
    DATABASE_URL="$(cat /run/secrets/vw_database_url)"
    export DATABASE_URL
fi
