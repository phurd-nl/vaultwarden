# 1. Additive fork posture, tracking upstream release tags

Date: 2026-06-09

## Status

Accepted

## Context

We are hardening a fork of Vaultwarden toward NIST SP 800-53B Moderate
(internal corporate, no federal RMF paperwork). The work requires source-code
modifications, not only deployment configuration.

Vaultwarden ships frequent security fixes. The dominant risk of any long-lived
fork is drifting from upstream and silently missing a CVE fix — which would make
the system *less* secure and directly undermine the SI-2 / SR control intent.

Three fork structures were considered:

- **A. Additive, isolated modules** — new behavior lives in new files
  (e.g. `src/audit/`, new config keys, thin middleware hooks). Existing files
  are touched minimally, ideally one-line hook insertions. Rebase on upstream
  tags on a regular cadence.
- **B. Inline modification** — edit existing handlers directly wherever a
  control applies. Large merge-conflict surface.
- **C. Sidecar, zero source change** — enforce controls only at the reverse
  proxy / sidecar / log shipper. No merge cost, but cannot produce
  org-independent in-app audit events.

## Decision

Adopt **A**. New controls are implemented as additive, isolated modules with
thin hook points into existing code. The fork tracks upstream **release tags**
(not `main`) and is rebased/merged on a regular cadence. Every modification to
an existing upstream file must be small and clearly delimited so upstream merges
conflict only at the hook points.

This is a **living fork**, kept current with upstream security releases — not a
point-in-time frozen build.

## Consequences

- Low merge-conflict surface; upstream security patches stay easy to absorb.
- Some controls that genuinely require in-app context (org-independent audit
  events, account lockout, login banner, user session timeout) become possible.
- Discipline required: reviewers must reject inline edits to upstream handlers
  when an additive hook would do.
- A few hook points in upstream files are unavoidable; these are the documented
  exception and must be kept minimal.
