# Vaultwarden hardened fork — fresh-VM bring-up runbook

Turnkey, copy-paste bring-up for a **new internal VM**. Target posture chosen for
this deployment:

- Real internal deployment, served at a real **FQDN on :443**.
- **Lab self-signed TLS now** (smoke-test), swap in real internal-CA material later.
- `/admin` locked to a **tight CIDR allowlist** you specify.
- Rootless podman, systemd quadlets, no compose.

Run everything as the **non-root service user** unless a step says `sudo`.

Fill these in once and reuse below:

```bash
FQDN=vault.example.internal          # <-- your real hostname
ADMIN_CIDR=10.20.5.0/24              # <-- network(s) allowed to reach /admin (space-separate multiples)
SVC_USER=$(id -un)                  # the rootless service user (this account)
```

---

## 0. VM prerequisites (one-time)

```bash
# 0.1 Base packages (Debian/Ubuntu shown; use dnf on RHEL-family).
sudo apt-get update
sudo apt-get install -y podman git openssl curl
podman --version                      # need >= 4.4

# 0.2 Keep rootless services running after logout.
sudo loginctl enable-linger "$SVC_USER"

# 0.3 ENCRYPTED STORAGE (NIST MP/SC-28): the container storage backing the
#     volumes MUST sit on an encrypted FS. This VM uses two disks: a LUKS OS
#     disk (encrypt it in the OS installer) and a LUKS data disk that
#     auto-unlocks when root unlocks. Set the data disk up with:
#
#       sudo deploy/scripts/setup-data-disk-luks.sh --device /dev/vdb --user "$SVC_USER"
#
#     (DESTRUCTIVE on the target disk; interactive passphrase; wires a keyfile
#     on encrypted root + /etc/crypttab + /etc/fstab and mounts it at the
#     service user's container storage dir. See the script's --help.)
#     Then verify it's on the encrypted mount:
findmnt -no SOURCE,FSTYPE "$HOME/.local/share/containers" || true
#     If this VM's disks are not encrypted at rest, stop and fix that first.

# 0.4 Allow rootless bind to :443 and persist it.
echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-vaultwarden-port443.conf
sudo sysctl --system

# 0.5 Host firewall: allow 443/tcp inbound from your client networks only.
#     (ufw shown; adapt to firewalld/nftables as appropriate.)
sudo ufw allow proto tcp from "$ADMIN_CIDR" to any port 443 || true
#     Add additional allow rules for the user-facing client networks as needed.
```

---

## 1. Get the code and build the image

```bash
git clone https://github.com/phurd-nl/vaultwarden.git ~/src/vaultwarden
cd ~/src/vaultwarden
git checkout nist-800-53b-source        # or the release tag once merged to main

# Build the hardened image from this fork (DB=postgresql, OCI docker format).
deploy/scripts/build-image.sh
podman images | grep vaultwarden-nist    # confirm localhost/vaultwarden-nist:latest exists

# Build the egress allowlist proxy image (SSO -> Entra path, see step 4b).
deploy/scripts/build-egress-proxy.sh
podman images | grep vw-egress-proxy     # confirm localhost/vw-egress-proxy:latest exists
```

---

## 2. Install config + quadlets (copies files, starts nothing)

```bash
cd ~/src/vaultwarden
deploy/scripts/install.sh
# Installs:
#   ~/vaultwarden/{config,caddy,postgres,tls}
#   ~/.config/containers/systemd/*.{network,volume,container}
```

---

## 3. TLS material — lab self-signed now (swap real CA later)

`vw-postgres` server cert SAN is fixed (`vw-postgres`); the Caddy cert SAN must be
your real `$FQDN`.

```bash
cd ~/vaultwarden/tls

# Internal CA
openssl req -x509 -newkey rsa:4096 -nodes -keyout ca/internal-ca.key \
  -out ca/internal-ca.crt -days 3650 -subj "/CN=Internal Lab CA"

# Postgres server cert (SAN=vw-postgres)
openssl req -newkey rsa:2048 -nodes -keyout postgres/server.key \
  -out postgres/server.csr -subj "/CN=vw-postgres" \
  -addext "subjectAltName=DNS:vw-postgres"
openssl x509 -req -in postgres/server.csr -CA ca/internal-ca.crt \
  -CAkey ca/internal-ca.key -CAcreateserial -days 825 \
  -extfile <(printf "subjectAltName=DNS:vw-postgres") -out postgres/server.crt
cp ca/internal-ca.crt postgres/ca.crt

# Caddy cert (SAN = your real FQDN)
openssl req -newkey rsa:2048 -nodes -keyout caddy/server.key \
  -out caddy/server.csr -subj "/CN=$FQDN" \
  -addext "subjectAltName=DNS:$FQDN"
openssl x509 -req -in caddy/server.csr -CA ca/internal-ca.crt \
  -CAkey ca/internal-ca.key -CAcreateserial -days 825 \
  -extfile <(printf "subjectAltName=DNS:%s" "$FQDN") -out caddy/server.crt

# Permissions (Postgres refuses to start on a group/world-readable key).
chmod 600 postgres/server.key caddy/server.key
chmod 644 postgres/server.crt postgres/ca.crt caddy/server.crt ca/internal-ca.crt
```

> Clients will not trust the lab CA. Either import `ca/internal-ca.crt` into the
> client trust store for the smoke-test, or accept the warning. For production,
> replace all of `~/vaultwarden/tls/` with real internal-CA material (same paths,
> same SAN rules) — see `deploy/tls/README.md` — then restart the stack.

---

## 4. Wire the environment-specific config

```bash
cd ~/vaultwarden

# 4.1 DOMAIN -> your real https URL on :443
sed -i "s#^DOMAIN=.*#DOMAIN=https://$FQDN#" config/vaultwarden.env

# 4.2 Caddy site address -> "$FQDN:443"
sed -i "s#^vaultwarden.example.com:8443 {#$FQDN:443 {#" caddy/Caddyfile

# 4.3 /admin allowlist -> your tight CIDR(s).
#     Replace the default RFC1918 ranges on the @admin_denied line.
sed -i "s#not remote_ip .*#not remote_ip $ADMIN_CIDR#" caddy/Caddyfile

# 4.4 Review the banner / lockout / session values in config/vaultwarden.env.
#     Idle timeout stays OFF (no random sign-outs) unless you opt in.
grep -nE 'DOMAIN|ACCOUNT_LOCKOUT|LOGIN_BANNER|SESSION_|AUDIT_LOG' config/vaultwarden.env
grep -nE ':443 \{|remote_ip' caddy/Caddyfile
```

Sanity-check the two edits above by eye before continuing.

Then set the SSO values (Entra) in `config/vaultwarden.env` — fill in from step 4b:

```bash
cd ~/vaultwarden
sed -i "s#<TENANT_ID>#$TENANT_ID#"                 config/vaultwarden.env
sed -i "s#<ENTRA_APPLICATION_CLIENT_ID>#$CLIENT_ID#" config/vaultwarden.env
grep -nE 'SSO_|_PROXY' config/vaultwarden.env
```

> Rollout safety: leave `SSO_ONLY=false` for the first boot, confirm an
> end-to-end Entra login works (step 7), **then** set `SSO_ONLY=true` and
> `systemctl --user restart vaultwarden`.

---

## 4b. Entra app registration (Azure portal — see docs/adr/0005)

Set these once and reuse in steps 4 and 5:

```bash
TENANT_ID=<your-entra-tenant-guid>
CLIENT_ID=<application-client-id>
```

In **Entra admin center → App registrations → New registration**:

1. **Redirect URI** (platform = Web): `https://$FQDN/identity/connect/oidc-signin`
   (this is exactly what Vaultwarden derives from `DOMAIN`).
2. **Authority** is tenant-scoped v2.0 — already wired in step 4 as
   `https://login.microsoftonline.com/<TENANT_ID>/v2.0`.
3. **Certificates & secrets → New client secret** → copy the **Value** (not the
   Secret ID). You store it as a podman secret in step 5.
4. **Token configuration → Add optional claim → ID → `email`** (and `upn` if you
   want it). REQUIRED: this fork matches users by email; without the optional
   `email` claim Entra omits it and SSO login fails to map users. Ensure your
   users actually have a mail attribute.
5. **API permissions:** the default delegated `openid profile email offline_access`
   (User.Read) is sufficient; grant admin consent if your tenant requires it.

No inbound firewall change is needed for Entra — only the app's *outbound* path,
which the `vw-egress-proxy` already restricts to `login.microsoftonline.com` and
`graph.microsoft.com`.

---

## 5. Secrets (DB auto-generated; admin token set by you)

```bash
cd ~/src/vaultwarden
deploy/secrets/create-secrets.sh
# Creates: vw_pg_superuser_password, vw_db_app_password, vw_database_url
# (DATABASE_URL uses sslmode=verify-full against the CA you placed in step 3.)

# Set the admin token YOURSELF — only the Argon2id hash is stored as a secret.
# Keep the PLAINTEXT in your password manager; you type it at /admin.
podman run --rm -it localhost/vaultwarden-nist:latest /vaultwarden hash \
  | tail -n1 | podman secret create vw_admin_token -


# Set the Entra SSO client secret yourself (the "Value" from step 4b.3):
printf '%s' '<ENTRA_CLIENT_SECRET_VALUE>' | podman secret create vw_sso_client_secret -

podman secret ls    # expect vw_pg_superuser_password, vw_db_app_password,
                     #         vw_database_url, vw_admin_token, vw_sso_client_secret
```

---

## 6. Start (Caddy pulls up the whole dependency chain)

```bash
systemctl --user daemon-reload
systemctl --user start vw-caddy.service
systemctl --user status vaultwarden vw-postgres vw-caddy --no-pager

# Tail logs if anything is not 'active (running)':
journalctl --user -u vw-postgres -u vaultwarden -u vw-caddy -n 100 --no-pager
```

Common first-boot snag — **Postgres TLS key permissions under rootless userns**:
if `vw-postgres` logs `private key file ... has group or world access`, see
`deploy/README.md` → "Postgres TLS key permissions" (bake cert/key into a derived
image with correct ownership, or mount the key as a `type=mount,mode=0400` secret).

---

## 7. Acceptance checks

```bash
cd ~/src/vaultwarden
BASE=https://$FQDN deploy/scripts/verify.sh
# Checks: TLS up, self-registration denied, WebSocket 101 upgrade,
#         audit log emitting, DB port NOT published to the host.

# Manual: from an ALLOWED admin CIDR, /admin loads and shows the banner;
#         from a non-allowed source, /admin returns 403.
curl -sk -o /dev/null -w '%{http_code}\n' "https://$FQDN/admin"
```

**Verify SSO (with `SSO_ONLY=false`):** from a client on the VPN, open
`https://$FQDN`, choose "Enterprise Single Sign-On" / log in with SSO, and
complete the Entra flow. Confirm:
- the user is created/matched by email (check the audit log for the SSO login),
- `journalctl --user -u vw-egress-proxy` shows the `CONNECT ... login.microsoftonline.com` line.
If SSO fails on a missing email, revisit step 4b.4 (the `email` optional claim).

**Then enforce SSO-only:** set `SSO_ONLY=true` in `config/vaultwarden.env` and
`systemctl --user restart vaultwarden`. Admins still reach `/admin` via
`ADMIN_TOKEN` regardless of the IdP.

Create the first account: it is auto-provisioned on first SSO login (matched by
email). For non-SSO/break-glass admin tasks, use `/admin` with the admin token.

---

## 8. Production hardening (before real traffic)

- [ ] Replace lab certs in `~/vaultwarden/tls/` with **real internal-CA** material; restart.
- [ ] **Pin the image digest**: replace `localhost/vaultwarden-nist:latest` in the
      `.container` units with `...@sha256:<digest>` (see `deploy/supplychain/pin-digests.sh`).
- [ ] Confirm `~/.local/share/containers/storage` is on the **encrypted** FS (step 0.3).
- [ ] Run `deploy/supplychain/scan.sh` (Trivy/Grype severity gate) and `sbom.sh`.
- [ ] Enable the **backup/PITR** slice — `deploy/backup/README.md`.
- [ ] Ship audit logs to **Wazuh/SIEM** — `deploy/wazuh/README.md`.
- [ ] Stand up the **warm standby** if CP-10 requires it — `deploy/standby/README.md`.
- [ ] Org workstreams (not codeable): FIPS-199 categorization, SSP, POA&M, AO sign-off.

---

## 9. Real-cert swap (later, zero-downtime-ish)

```bash
# Drop CA-issued files into the same paths, fix perms, restart Caddy + Postgres.
chmod 600 ~/vaultwarden/tls/postgres/server.key ~/vaultwarden/tls/caddy/server.key
systemctl --user restart vw-postgres.service vw-caddy.service
```

---

### Quick teardown (smoke-test do-over)

```bash
systemctl --user stop vw-caddy.service vaultwarden.service vw-postgres.service
podman volume rm vw-data vw-pgdata vw-caddy-data 2>/dev/null || true
# Secrets persist; remove only if rotating: podman secret rm vw_admin_token ...
```
