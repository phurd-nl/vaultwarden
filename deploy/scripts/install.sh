#!/usr/bin/env bash
# Install config + quadlets for rootless systemd (NIST CM: config-as-code).
# Copies runtime config to ~/vaultwarden and quadlet units to the systemd
# user generator dir, then reloads. Does NOT start anything (review first).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/deploy"
DEST="$HOME/vaultwarden"
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

echo "Installing runtime config to $DEST ..."
mkdir -p "$DEST"
# Runtime config the quadlets reference via %h/vaultwarden/...
cp -r "$SRC/config"   "$DEST/"
cp -r "$SRC/caddy"    "$DEST/"
cp -r "$SRC/postgres" "$DEST/"
# TLS dirs are created empty; you drop your internal-CA material in (see tls/README.md).
mkdir -p "$DEST/tls/ca" "$DEST/tls/postgres" "$DEST/tls/caddy"
chmod +x "$DEST/postgres/init/"*.sh 2>/dev/null || true

echo "Installing quadlet units to $QUADLET_DIR ..."
mkdir -p "$QUADLET_DIR"
cp "$SRC/quadlet/"*.network "$SRC/quadlet/"*.volume "$SRC/quadlet/"*.container "$QUADLET_DIR/"

echo "Reloading systemd user units ..."
systemctl --user daemon-reload

cat <<EOF

Installed. Next:
  1) Drop internal-CA TLS material in $DEST/tls/   (see deploy/tls/README.md)
  2) deploy/secrets/create-secrets.sh              (then set vw_admin_token)
  3) deploy/scripts/build-image.sh                 (build the fork image)
  4) systemctl --user start vw-caddy.service       (pulls up the dependency chain)
  5) deploy/scripts/verify.sh                      (acceptance checks)

Tip: 'loginctl enable-linger \$USER' keeps the services running after logout.
EOF
