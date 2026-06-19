# 7. /admin network gating under rootless podman

## Status
Accepted (2026-06-10), discovered during first production bring-up.

## Context
The hardened deployment runs rootless podman. The Caddy reverse proxy publishes
`:443` via `rootlessport` (podman 4.9.3, netavark — pasta is not the default for
published ports in this version). `rootlessport` **masquerades the client source
IP**: by the time a request reaches Caddy, `remote_ip` is a container-network
address (e.g. `10.89.11.x`/`10.89.10.x`), never the real client IP.

The Caddyfile originally gated `/admin` with a `remote_ip` allowlist
(`@admin_denied not remote_ip <ADMIN_CIDR>`) for NIST AC defense-in-depth. Under
rootless this can never match a real client, so it returned 403 to **everyone**,
including legitimate admins — and could never have enforced the intended
restriction even if "opened up".

Confirmed empirically: Caddy access logs showed `"remote_ip":"10.89.11.16"` /
`"10.89.10.35"` for external requests, not the real `132.147.175.10`.

## Decision
Remove the Caddy `remote_ip` allowlist on `/admin`. Gate `/admin` with:
1. **`ADMIN_TOKEN`** — Argon2id PHC, the actual authentication (AC-3/AC-6).
2. **Host firewall** on `:443` — restricted to admin/client CIDRs. The host
   firewall sees the *real* source IP (the masquerade happens later, inside the
   rootless network namespace), so source-IP restriction is enforced there
   (SC-7), at the only layer that can see it.

`/admin` therefore reverse-proxies like any other path; the token + firewall are
the controls.

## Alternatives considered
- **pasta networking** (preserves source IP): not the default port-forwarder on
  podman 4.9.3; uncertain source-IP preservation for published ports; would
  destabilize a working stack. Rejected for now.
- **Caddy on host network** (sees real IPs): breaks the edge/internal network
  isolation model and the app-by-name routing. Rejected.

## Consequences
- Per-path source-IP gating at the proxy is not available under this rootless
  setup; document it rather than ship a control that silently does nothing.
- If strict per-path source-IP gating becomes a hard requirement, revisit pasta
  (podman 5+) or a fronting load balancer that sets a trusted `X-Forwarded-For`.
