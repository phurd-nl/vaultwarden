# 5. SSO via Microsoft Entra ID through an egress allowlist proxy (IA-2/IA-8/AC-17)

Date: 2026-06-09

## Status

Accepted

## Context

Onboarding ~1000 users by hand-issued invitations does not scale, and a federal-
adjacent deployment wants centralized authentication and deprovisioning. This
fork already carries the OIDC SSO stack (`src/sso.rs`, `src/sso_client.rs`,
`SSO_*` config keys). The chosen IdP is **Microsoft Entra ID**, enforced
**SSO-only** (`SSO_ONLY=true`).

OIDC is not purely browser-mediated. The **server** must reach the IdP directly
for the back-channel token exchange (code → tokens), provider discovery, and
JWKS retrieval (and, on some paths, the userinfo endpoint). For Entra these are
`login.microsoftonline.com` and `graph.microsoft.com`.

This collides with the deployment's network posture (ADR-0001 / the deploy
slice): the app and database run on a podman `Internal=true` network with **no
egress** (SC-7). `Internal=true` blocks *all* outbound at the network level —
there is no per-host allowlist at that layer.

Options for giving the app the required, *minimal* egress:

- **A. Forward proxy with an FQDN allowlist.** App stays on the no-egress
  internal network; a small forward proxy (tinyproxy, default-deny + domain
  filter) sits on a dedicated egress network and permits only the Entra hosts.
  The app's reqwest client routes OIDC calls via `HTTPS_PROXY`. TLS stays
  end-to-end (the proxy only `CONNECT`-tunnels; it does not terminate TLS).
- **B. Dedicated egress network + host firewall.** App joins an egress-capable
  network; host nftables restricts outbound to Microsoft's `AzureActiveDirectory`
  service-tag ranges. No proxy, but the ranges are broad and change over time.
- **C. App on the edge network.** Simplest; gives the app general egress, walked
  back by host firewall rules. Weakest SC-7 story.

Two enabling facts were verified in code before deciding:

1. `http_client::get_reqwest_client_builder()` does **not** call `.no_proxy()`,
   so reqwest honors `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`. The OIDC client
   (`sso_client.rs`) builds on that builder, so proxy env routes its calls. The
   PostgreSQL connection is raw TCP (diesel), unaffected by proxy env.
2. The native `<KEY>_FILE` mechanism (`util.rs get_env_str_value`, reached by the
   config macro for every key) works for the `Pass`-typed `SSO_CLIENT_SECRET`, so
   the client secret is delivered as a podman secret via `SSO_CLIENT_SECRET_FILE`.

## Decision

Adopt **A**. Add a hardened `vw-egress-proxy` (tinyproxy) container on a new
`vaultwarden-egress` network (egress-capable, no published ports) **and** the
internal network (reachable by the app at a static internal IP). tinyproxy runs
`FilterDefaultDeny Yes` with a domain allowlist of `login.microsoftonline.com`
and `graph.microsoft.com`, and `ConnectPort 443` so only TLS tunnels to those
hosts are possible. The app receives `HTTPS_PROXY`/`HTTP_PROXY` pointing at the
proxy's static internal IP and `NO_PROXY` for internal targets.

The Entra **client secret** is a podman secret (`vw_sso_client_secret`), set by
the operator (never by tooling), mounted and read via `SSO_CLIENT_SECRET_FILE` —
the same posture as `ADMIN_TOKEN`.

Edge (ingress, Caddy only) and egress (outbound, proxy only) stay separate
networks so each direction has a single, named, auditable path.

**Rollout:** ship `SSO_ONLY=true` as the target, but bring up with
`SSO_ONLY=false`, verify an end-to-end Entra login works, then flip to `true`.
`/admin` authenticates separately via `ADMIN_TOKEN`, so an IdP outage does not
lock administrators out of the admin panel.

## Consequences

- One documented egress exception, expressed as an explicit FQDN allowlist on a
  dedicated path — the form an assessor expects for an SC-7 tailoring, rather
  than blanket egress.
- TLS to Entra remains end-to-end; the proxy cannot read token traffic.
- New build artifact: a minimal `alpine + tinyproxy` image (controlled source,
  SR-3/CM-2); tinyproxy config is mounted config-as-code, not baked.
- Entra specifics that must be set for first login to succeed (documented in the
  bring-up runbook): tenant-scoped v2.0 authority URL, the `email` **optional
  claim** added to the app registration, redirect URI
  `https://<DOMAIN>/identity/connect/oidc-signin`, and `offline_access` in scopes
  for refresh tokens.
- SSO-only means an Entra outage blocks user login (not admin). Accepted; the
  verify-then-enforce sequence mitigates rollout risk.
- The master password still encrypts the vault (Bitwarden E2E model); SSO
  replaces authentication, not vault unlock. No Key Connector in this fork.
