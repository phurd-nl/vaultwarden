# NextVault — NIST SP 800-53 RMF Package

This directory holds the Risk Management Framework (RMF) artifacts for the
NextVault deployment (a hardened Vaultwarden fork; see `docs/adr/`). It is the
**paperwork track** that complements the implemented technical controls.

> **Status: DRAFT for review.** These documents are scaffolding grounded in the
> actual deployment. Every `[DECISION NEEDED]`, `[OWNER]`, and `[AO SIGNATURE]`
> marker is a spot where a human must decide, fill in, or sign. Producing these
> is **not** an authorization to operate — the AO grants that.

## RMF step coverage

| RMF step | Artifact | State |
|---|---|---|
| **Categorize** | [`fips-199-categorization.md`](fips-199-categorization.md) | Draft — **one key decision open** (confidentiality impact → baseline) |
| **Select** | `fips-199-categorization.md` §4 + [`ssp.md`](ssp.md) §5 | Draft — baseline follows the categorization decision |
| **Implement** | [`ssp.md`](ssp.md) (control implementation summary) | Draft — maps shipped controls to 800-53; cites code/ADRs |
| **Assess** | `ssp.md` §6 + `deploy/supplychain/reports/` + the prior audit | Partial — scan/SBOM evidence exists; full SCA pending |
| **Authorize** | [`poam.md`](poam.md) + AO decision | Draft — POA&M seeded; AO sign-off pending |
| **Monitor** | `ssp.md` §7 + Wazuh slice + `rto-rpo.md` | Partial — design done, SIEM enrollment pending |

## Documents

- **`fips-199-categorization.md`** — impact-level analysis (C/I/A) and the
  resulting baseline. **Read this first** — it has the decision everything else
  hangs on.
- **`ssp.md`** — System Security Plan skeleton: description, authorization
  boundary, and a control-family implementation summary with evidence pointers.
- **`poam.md`** — Plan of Action & Milestones: the open weaknesses (from the
  technical audit) with owners, milestones, and risk.
- **`rto-rpo.md`** — recovery objectives and what the current backup/PITR design
  actually delivers against them.

## How this maps to what's already built

The technical controls are real and live (TLS everywhere, network segmentation,
egress allowlist, podman secrets, LUKS at rest, audit logging, account lockout,
SSO via Entra, backup/PITR, image digest pinning, vuln scanning). The ADRs in
`docs/adr/` and the per-slice READMEs under `deploy/` are the primary evidence;
this package organizes them into the assessor-facing RMF structure and surfaces
the organizational decisions that code can't make.
