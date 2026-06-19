# System Security Plan (SSP) — NextVault

**Status:** DRAFT skeleton for review. Org-specific fields are `[OWNER]` /
`[DECISION NEEDED]`. Control rows cite the live implementation as evidence.

## 1. System identification

| Field | Value |
|---|---|
| System name | NextVault |
| Description | Self-hosted, NextVault-branded password manager (hardened Vaultwarden fork — Rust, Bitwarden-compatible, zero-knowledge E2E). |
| System type | Internal corporate (ADR-0001). Not federal; not a cloud offering. |
| Categorization | See `fips-199-categorization.md` — provisional **High** (C) / Moderate (I) / Moderate (A); **baseline decision open**. |
| Baseline | 800-53B **Moderate** as built; revisit per the categorization decision. |
| Authorization boundary | §3 below. |
| System owner / ISSO / AO | `[OWNER]` / `[ISSO]` / `[AO]` |
| Source of truth | This repo (config-as-code) + HiveBrain session history. |

## 2. Environment & architecture

Single host (`10.2.15.62`), rootless **podman** with systemd **quadlets** (no
podman-compose). Containers:
- **nextvault** — the app (built from this fork, image pinned by per-build tag).
- **nextvault-postgres** — PostgreSQL 17.10 (TLS, SCRAM, least-priv app role).
- **nextvault-caddy** — TLS-terminating reverse proxy (only `:443` published).
- **nextvault-egress-proxy** — tinyproxy default-deny allowlist for Entra egress.

Three networks: `edge` (Caddy ↔ host), `internal` (app ↔ DB, `Internal=true`,
no egress), `egress` (proxy → Entra only). Data on a **LUKS** disk
(`/dev/mapper/data_crypt`, confirmed).

## 3. Authorization boundary `[OWNER to confirm/diagram]`

**Inside:** the four containers, their podman volumes (`nextvault-data`,
`nextvault-pgdata`, `nextvault-pgwal`, caddy data), the three networks, host OS,
and the backup artifacts. **Boundary interfaces:** (1) HTTPS `:443` to
users/admins via Caddy; (2) outbound to Microsoft Entra via the egress proxy
allowlist; (3) SSH admin plane (off-net exception per network policy); (4) Wazuh
agent → external SIEM (once enrolled). **Inherited / external:** Microsoft Entra
(IdP — IA-2/IA-8), the internal CA (TLS material), the Wazuh manager (AU-6/SI-4),
host platform/hypervisor. *Action: attach a data-flow diagram.*

## 4. Roles `[DECISION NEEDED]`

System Owner, Data Owner, ISSO/Security Officer, AO, Operations Owner, Backup
Owner — **assign named individuals.** Admin access to `/admin` is a single
shared `ADMIN_TOKEN` (Argon2id, podman secret) — an inherent Vaultwarden limit;
compensate with a named-admin process + access logging (Wazuh rule 100001).

## 5. Control implementation summary

Evidence is in this repo unless noted. ✅ implemented · ◐ partial · ○ gap (see
`poam.md`) · N/A (tailored out, with reason).

| Family | State | Implementation & evidence |
|---|---|---|
| **AC** Access Control | ◐ | SSO-gated access + `SSO_ONLY` (IA-2); account lockout AC-7 (ADR-0003); session idle timeout AC-12 (ADR-0004); `/admin` source-IP + token model (ADR-0007). Gap: formal access reviews, named-admin process. |
| **AU** Audit | ✅/◐ | Fork audit emitter at choke points (ADR-0002, `AUDIT_LOG_ENABLED`); org-event log retained 365d; Caddy + Postgres logging; `log_statement=ddl`. Forwarding to SIEM ◐ (Wazuh agent not yet enrolled). |
| **AT** Awareness/Training | ○ | Organizational — outside the technical boundary. |
| **CM** Config Mgmt | ✅/◐ | Config-as-code (quadlets/env in git); images pinned by digest/immutable tag, `AutoUpdate` removed (CM-2/SR-4). Gap: formal change-approval + drift detection. |
| **CP** Contingency | ◐ | Backup/PITR live + verified restorable (CP-9), WAL archiving (CP-10); restore/failover runbooks. Gap: timed restore drill, offsite copy, standby stood up — see `rto-rpo.md`. |
| **IA** Identification/Auth | ✅ | Entra OIDC SSO (IA-2/IA-8, ADR-0005, PKCE, refresh tokens); master password preserves E2E (no Key Connector — unsupported); secrets via `_FILE` podman secrets (IA-5). |
| **IR** Incident Response | ○ | Mechanisms exist (token/cred rotation, session deauth, edge isolation); **no IR plan/runbooks** — see `poam.md`. |
| **MA** Maintenance | ◐ | Turnkey rebuild runbook (`VM-BRINGUP.md`); patch via rebuild. Gap: maintenance-window/upgrade-rollback runbooks. |
| **MP** Media Protection | ✅ | LUKS at rest (`/dev/mapper/data_crypt`); backups encrypted (age); key escrowed off-host. |
| **PE** Physical | N/A→inherit | Inherited from the hosting facility — `[OWNER to document inheritance]`. |
| **PL/PM** Planning/Program | ◐ | This package + ADRs. Gap: completed SSP, POA&M sign-off. |
| **RA** Risk Assessment | ✅/◐ | Trivy scan + CRITICAL gate (passing), SBOMs per digest (RA-5); product-risk write-up (`supplychain/README.md §1`). Gap: host/IaC scanning, exception sign-off. |
| **CA** Assessment/Auth | ◐ | Prior technical audit = informal assessment; this package feeds authorization. Gap: formal SCA + ATO. |
| **SC** System/Comms Protection | ✅ | TLS everywhere + HSTS (SC-8); network segmentation + DB never published (SC-7); egress default-deny allowlist; secrets management (SC-12/SC-28). Gap: TLS = lab certs until internal-CA material installed; FIPS-140 boundary decision. |
| **SI** System Integrity | ◐ | Vuln scan/gate (SI-2); audit-based monitoring design (SI-4, Wazuh). Gap: SIEM enrollment, alerting blind spots (cert expiry, backup failure wired but others pending). |
| **SR** Supply Chain | ✅ | Build-from-source provenance; SBOM (CycloneDX+SPDX); digest pinning; documented OSS/exception process. Gap: private registry / signing optional. |
| **PT/Privacy** | ○ | `[DECISION NEEDED]` — privacy baseline applicability. |

## 6. Assessment evidence (pointers)

`deploy/supplychain/reports/` (scan), `deploy/supplychain/sbom/` (SBOMs),
`docs/adr/0001-0007`, per-slice `deploy/*/README.md`, `deploy/scripts/verify.sh`
(TLS/registration/WS/DB-not-published checks), this `docs/compliance/` package.

## 7. Continuous monitoring `[DECISION NEEDED — cadence]`

Planned: Wazuh alerts (AU-6/SI-4) once enrolled; recurring `scan.sh` (RA-5);
backup success/`OnFailure` alarm (CP-9); cert-expiry + capacity alerts (gaps).
Define review cadence and the monitoring owner.

## 8. Sign-off

| Role | Name | Date | Signature |
|---|---|---|---|
| System Owner | `[OWNER]` | | |
| ISSO | `[ISSO]` | | |
| Authorizing Official | `[AO]` | | `[AO SIGNATURE]` |
