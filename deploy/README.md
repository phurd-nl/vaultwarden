# Vaultwarden — hardened podman deployment (NIST 800-53B Moderate)

Active-passive-ready, rootless **podman** deployment (no compose) of the
NIST-hardened Vaultwarden fork: Caddy (TLS) → Vaultwarden → PostgreSQL (TLS),
managed as **systemd quadlets** (config-as-code, NIST CM).

```
                        host:8443 (TLS)
                              │
                    ┌─────────▼─────────┐   vaultwarden-edge (egress + publish)
                    │      vw-caddy     │
                    └─────────┬─────────┘
   vaultwarden-internal (Internal=true, NO egress, NOT published)
              ┌───────────────┼────────────────┐
      ┌───────▼───────┐               ┌─────────▼─────────┐
      │  vaultwarden  │──TLS verify──▶│    vw-postgres    │
      │  :8080        │  -full        │  TLS + SCRAM      │
      └───────┬───────┘               └─────────┬─────────┘
         vw-data volume                    vw-pgdata volume
```

## What's implemented here

| Area | Control | How |
|---|---|---|
| Reverse proxy + TLS + HSTS | SC-8/SC-13 | `caddy/Caddyfile`, internal-CA cert |
| `/admin` network restriction | AC-3/AC-6 | Caddy `remote_ip` allowlist (EDIT CIDRs) |
| WebSocket upgrade (101) | functional | Caddy transparent upgrade |
| DB TLS `verify-full` + SCRAM | SC-8/IA-5 | `postgres/pg_hba.conf`, server SAN=`vw-postgres` |
| Least-privilege DB role | AC-6 | `postgres/init/01-app-role.sh` (non-superuser, owns only its DB) |
| Secrets out of config/git | IA-5/SC-28 | `podman secret` + `/etc/vaultwarden.d/10-secrets.sh` |
| No public DB; egress restricted | SC-7 | `Internal=true` network; DB never published |
| Non-root, cap-drop, read-only FS, limits | AC-6/SC | quadlet hardening keys |
| Audit + lockout + banner + session | AU/AC | fork features, on in `config/vaultwarden.env` |
| Image from controlled source | SR-3/CM-2 | `scripts/build-image.sh`, pin digest |

## Deploy (first time)

```bash
# 0. Prereqs: podman >= 4.4, rootless configured. Put the volumes' backing
#    store (~/.local/share/containers/storage) on an ENCRYPTED filesystem (MP/SC-28).
loginctl enable-linger "$USER"          # keep services up after logout

# 1. Install config + quadlets (copies to ~/vaultwarden, units to systemd)
deploy/scripts/install.sh

# 2. TLS material from your internal CA  → see deploy/tls/README.md
#    (lab self-signed quickstart is in that file)

# 3. Edit for your environment:
#    ~/vaultwarden/config/vaultwarden.env   (DOMAIN, lockout, banner)
#    ~/vaultwarden/caddy/Caddyfile          (hostname, /admin allowlist CIDRs)

# 4. Create DB secrets, then set the admin token yourself
deploy/secrets/create-secrets.sh
#    (follow the printed 'vaultwarden hash' step for vw_admin_token)

# 5. Build the hardened image from this fork
deploy/scripts/build-image.sh
#    then pin the printed digest in ~/vaultwarden/.../vaultwarden.container

# 6. Start (Caddy pulls up the whole dependency chain)
systemctl --user start vw-caddy.service
systemctl --user status vaultwarden vw-postgres vw-caddy

# 7. Acceptance checks
BASE=https://vaultwarden.example.com:8443 deploy/scripts/verify.sh
```

## Operational notes / gotchas

- **Port 443 (rootless):** default is `8443`. For real `443` either
  `sudo sysctl net.ipv4.ip_unprivileged_port_start=443` (persist in
  `/etc/sysctl.d/`), or install the quadlets rootful under
  `/etc/containers/systemd/`. Then set `PublishPort=443:8443` and the Caddy
  site address to `:443`.
- **Postgres TLS key permissions:** the mounted `server.key` must be `chmod 600`
  and readable by the container's postgres UID. If startup fails on key perms,
  the simplest fix is to bake the cert/key into a tiny derived postgres image
  with correct ownership, or use a podman secret of `type=mount,mode=0400` for
  the key and point `ssl_key_file` at it.
- **Config drift (CM-6):** `config/vaultwarden.env` is the source of truth. Do
  not change settings in the `/admin` UI — that writes `config.json` and
  overrides env. Treat any `config.json` as drift.
- **Image digest pinning (CM-2/SR):** replace the `:latest`/`:tag` images in the
  `.container` units with `name@sha256:...` before production.

## Not yet built (next deployment slices)

- **Backups/PITR (CP-9/CP-10):** encrypted `pg_dump` + WAL archiving + `/data`
  (attachments, sends, `rsa_key.pem`) to offsite immutable storage, with a
  tested restore. *Next slice.*
- **Log shipping (AU-6):** forward the `vaultwarden::audit` JSON lines + Caddy +
  Postgres logs to your SIEM. *Needs the SIEM product name.*
- **Warm standby + manual failover (CP-10):** second app instance against the
  same DB + replicated `/data`, with a failover runbook.
- **SBOM + image scan (SR-3/RA-5):** generate SBOM and scan the built image.
