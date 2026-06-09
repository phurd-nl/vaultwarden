# TLS material (internal/enterprise CA)

Drop your CA-issued material here before starting the stack. Nothing in this
directory is committed — keep private keys out of git (the repo `.gitignore`
should exclude `*.key`/`*.pem`).

## Files expected

| Path | Purpose | SAN requirement |
|---|---|---|
| `ca/internal-ca.crt` | CA root/chain the **app** trusts to validate Postgres (`sslmode=verify-full`) and that **clients** trust for Caddy. | n/a |
| `postgres/server.crt` + `postgres/server.key` + `postgres/ca.crt` | PostgreSQL server cert/key + issuing CA. | server cert SAN **must** include `nextvault-postgres` (the in-network hostname the app connects to). |
| `caddy/server.crt` + `caddy/server.key` | Caddy TLS cert/key for user/admin ingress. | SAN **must** include your `DOMAIN` host (e.g. `vaultwarden.example.com`). |

## Permissions

PostgreSQL refuses to start if the key is group/world readable. After placing files:

```bash
chmod 600 postgres/server.key caddy/server.key
chmod 644 postgres/server.crt postgres/ca.crt caddy/server.crt ca/internal-ca.crt
```

Because rootless podman maps container UIDs through your user namespace, the
mounted key must be readable by the container's postgres UID. If Postgres logs
`private key file ... has group or world access`, see deploy/README.md →
"Postgres TLS key permissions".

## Lab-only self-signed (NOT for production)

To smoke-test the stack before real certs are issued:

```bash
# Internal CA
openssl req -x509 -newkey rsa:4096 -nodes -keyout ca/internal-ca.key \
  -out ca/internal-ca.crt -days 3650 -subj "/CN=Internal Lab CA"

# Postgres server cert (SAN=nextvault-postgres)
openssl req -newkey rsa:2048 -nodes -keyout postgres/server.key \
  -out postgres/server.csr -subj "/CN=nextvault-postgres" \
  -addext "subjectAltName=DNS:nextvault-postgres"
openssl x509 -req -in postgres/server.csr -CA ca/internal-ca.crt \
  -CAkey ca/internal-ca.key -CAcreateserial -days 825 \
  -extfile <(printf "subjectAltName=DNS:nextvault-postgres") -out postgres/server.crt
cp ca/internal-ca.crt postgres/ca.crt

# Caddy cert (SAN=your DOMAIN)
openssl req -newkey rsa:2048 -nodes -keyout caddy/server.key \
  -out caddy/server.csr -subj "/CN=vaultwarden.example.com" \
  -addext "subjectAltName=DNS:vaultwarden.example.com"
openssl x509 -req -in caddy/server.csr -CA ca/internal-ca.crt \
  -CAkey ca/internal-ca.key -CAcreateserial -days 825 \
  -extfile <(printf "subjectAltName=DNS:vaultwarden.example.com") -out caddy/server.crt

chmod 600 postgres/server.key caddy/server.key
```
