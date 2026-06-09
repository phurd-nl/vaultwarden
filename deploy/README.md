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
| Secrets out of config/git | IA-5/SC-28 | `podman secret` mounted as files + native `<KEY>_FILE` (`ADMIN_TOKEN_FILE`, `DATABASE_URL_FILE`) |
| No public DB; egress restricted | SC-7 | `Internal=true` network; DB never published |
| Non-root, cap-drop, read-only FS, limits | AC-6/SC | quadlet hardening keys |
| Audit + lockout + banner + session | AU/AC | fork features, on in `config/vaultwarden.env` |
| SSO (Entra OIDC), SSO-only | IA-2/IA-8 | `SSO_*` in `config/vaultwarden.env`; client secret as a podman secret (see ADR-0005) |
| Egress allowlist to Entra only | SC-7 | `vw-egress-proxy` (tinyproxy, default-deny) on `vaultwarden-egress`; app routes OIDC via `HTTPS_PROXY` |
| Image from controlled source | SR-3/CM-2 | `scripts/build-image.sh` + `scripts/build-egress-proxy.sh`, pin digests |

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

# 5. Build the hardened image from this fork (+ the SSO egress proxy)
deploy/scripts/build-image.sh
deploy/scripts/build-egress-proxy.sh
#    then pin the printed digests in the matching .container units

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

## Extensions (built; opt-in at deploy time)

Each lives in its own subdirectory with its own README and exact enable steps.
They are opt-in because enabling them edits the core quadlets/Postgres config in
environment-specific ways (WAL volume, replication seeding, journald driver,
real image digests) that belong to deploy time.

| Subdir | Control | What it adds | Enable |
|---|---|---|---|
| `backup/` | CP-9/CP-10/MP | Encrypted `pg_dump` + `/data` archive, WAL archiving + `pg_basebackup` for PITR, daily user timer, restore + test-restore runbook | `backup/README.md` |
| `wazuh/` | AU-6/SI/IR | Wazuh agent sidecar + decoders/rules for the `vaultwarden::audit` JSON, Caddy, and Postgres logs; alerts mapped to the handoff alert list | `wazuh/README.md` |
| `standby/` | CP-10 | Warm standby app + streaming-replica Postgres, `/data` rsync, manual failover/failback runbooks | `standby/README.md` |
| `supplychain/` | SR-3/SR-4/RA-5/CM-2 | SBOM (CycloneDX+SPDX), Trivy/Grype scan with severity gate + exceptions, digest-pinning helper, provenance/EOL policy | `supplychain/README.md` |

Each subdir's README lists the precise core-quadlet edits its feature needs;
apply them only when you turn that feature on.

## Still your org (not codeable)

FIPS 199 categorization, System Security Plan, POA&M, AO sign-off, access
reviews, IR tabletops — see the handoff doc's Workstreams 1 and 16.
