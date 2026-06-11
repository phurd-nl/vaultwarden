# Plan of Action & Milestones (POA&M) — NextVault

**Status:** DRAFT, seeded from the technical audit (2026-06-11) against the
800-53B handoff checklist. Dates/owners are `[SET]`. Risk = residual risk if the
weakness is left unaddressed. "Origin" cites where the gap was identified.

> Several items the audit flagged are now **CLOSED** this session and recorded at
> the bottom for traceability. The open table is the actual action list.

## Open items

| ID | Weakness | Control(s) | Risk | Remediation | Owner | Milestone | Status |
|----|----------|-----------|------|-------------|-------|-----------|--------|
| P-01 | System not formally categorized; Moderate baseline assumed. A credential store likely warrants **High** confidentiality. | RA-2, PL-2 | High | Complete `fips-199-categorization.md` decision; if High, gap-assess vs High baseline. | `[SET]` | `[SET]` | Open |
| P-02 | TLS uses **lab self-signed certs** in production. | SC-8, SC-17 | High | Install internal-CA material (`deploy/tls/README.md`), swap per `VM-BRINGUP.md §9`, add renewal automation + expiry alert. | `[SET]` | `[SET]` | Open — needs cert material |
| P-03 | Logs not shipped to SIEM; alerts unverified. | AU-6, SI-4 | Mod-High | Provide Wazuh manager addr + enrollment key; enroll agent; deploy decoders/rules; run per-rule alert tests. | `[SET]` | `[SET]` | Open — needs SIEM details |
| P-04 | No timed end-to-end restore drill; offsite/immutable backup copy not implemented. | CP-9, CP-10 | Mod-High | Run timed DB+`/data` restore into scratch env, record RTO/RPO; implement offsite copy (object storage + Object Lock). | `[SET]` | `[SET]` | Open |
| P-05 | No warm standby; Availability recovery unproven. | CP-10 | Moderate | Stand up second VM per `deploy/standby/`; run the 6-test failover/failback drill. | `[SET]` | `[SET]` | Open — needs second VM |
| P-06 | No IR plan/runbooks (severity, contacts, notification, tabletops). | IR-1, IR-4, IR-8 | Moderate | Author IR plan + runbooks (rotation, deauth, isolation, evidence export) using the failover runbook's 8-part shape. | `[SET]` | `[SET]` | Open |
| P-07 | No host baseline hardening (CIS/STIG), auditd, unattended security updates; ufw is a single runbook rule, not config-as-code. | CM-6, SI-2, AU-2 | Moderate | Apply CIS/Lynis pass + record deviations; enable auditd + unattended-upgrades; codify ufw default-deny ruleset. | `[SET]` | `[SET]` | Open |
| P-08 | Monitoring blind spots: cert expiry, disk capacity, container restart-loop, (post-standby) replication lag. | SI-4, AU-6 | Moderate | Add systemd-timer/Wazuh checks for each. (Backup-failure alarm already wired.) | `[SET]` | `[SET]` | Open |
| P-09 | Single shared `/admin` token; no named-admin process or periodic access review. | AC-2, AC-6 | Moderate | Document named-admin procedure + quarterly Entra-driven access review; rely on Wazuh rule 100001 for attribution. | `[SET]` | `[SET]` | Open |
| P-10 | FIPS 140-2/3 cryptographic-boundary decision undocumented. | SC-13 | Low-Mod | AO records applicability decision + boundary (likely N/A internal corporate, but the memo is required). | `[SET]` | `[SET]` | Open |
| P-11 | Three CVE exceptions in `.trivyignore` are `Approved-by: PENDING`. | RA-5, SI-2 | Low | System Owner reviews + signs the exception register (expire 2026-09-09). | `[SET]` | `[SET]` | Open |
| P-12 | RMF org docs incomplete: data-flow diagram, asset inventory, role assignments, conmon cadence, privacy-baseline applicability. | PL-2, PM-5, PT-1 | Moderate | Complete SSP `[OWNER]`/`[DECISION NEEDED]` fields; draw data-flow diagram; build asset inventory (SBOMs seed software inventory). | `[SET]` | `[SET]` | Open |

## Closed this session (traceability)

| Was | Control | Closed by |
|---|---|---|
| Deployed ≠ assessed artifact (VM ran postgres 17.5 / caddy 2.8) | CM-2, SR-4 | Rolled VM to scan-passing postgres 17.10 / caddy 2.11.4; **all images pinned** by digest / immutable tag; `AutoUpdate` removed. |
| Image versions failed CRITICAL gate | RA-5, SI-2 | Pin bumps cleared 18 fixable CRITICALs; 3 no-fix CVEs documented in `.trivyignore` (sign-off → P-11). |
| Encrypted storage at rest unconfirmed | SC-28, MP | LUKS confirmed: `/dev/mapper/data_crypt` backs container storage. |
| Backups not enabled | CP-9 | Backup/PITR slice live; first backup **verified restorable** non-destructively; daily timer + WAL archiving + failure alarm. |
| Entra SSO login broken | IA-2, IA-8 | `SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION=true`; SSO verified working end-to-end. |
| Time sync unconfirmed (AU-8) | AU-8 | `NTPSynchronized=yes` confirmed on the VM. |

## Sign-off

| Role | Name | Date | Signature |
|---|---|---|---|
| System Owner | `[OWNER]` | | |
| Authorizing Official | `[AO]` | | `[AO SIGNATURE]` |
