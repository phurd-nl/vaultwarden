# 2. Structured audit emitter taps existing event choke points

Date: 2026-06-09

## Status

Accepted

## Context

NIST 800-53B Moderate requires audit generation (AU-12), defined event content
(AU-3), and an externalized, reviewable audit trail (AU-2 / AU-6). Vaultwarden's
existing Org Event system persists to the database only, is org-scoped, and is
gated off by default (`org_events_enabled`). The handoff doc explicitly notes
not every event is emitted as an external log line.

Every Org Event already routes through two functions: `log_event` and
`log_user_event` in `src/api/core/events.rs`. `log_user_event` already records
an org-independent row, so the data model already captures user-scoped actions.

## Decision

Add a new `src/audit/` module exposing an `emit()` that writes a structured JSON
**Audit Event** to the application log sink. Insert one call at the top of each
choke point (`log_event`, `log_user_event`) **before** the `org_events_enabled`
early-return, gated by an independent `AUDIT_LOG_ENABLED` config flag.

A small number of security events that do not route through the choke points —
notably `/admin` page logins and failed `ADMIN_TOKEN` attempts in
`src/api/admin.rs` — get explicit `audit::emit()` calls as a deliberate,
documented exception.

## Consequences

- Two hook lines in one upstream file plus a few explicit admin-path calls; the
  entire existing instrumentation surface (login, failed login, password change,
  cipher CRUD, org changes, 2FA) emits to the SIEM with no per-handler work.
- Audit emission is independent of the Bitwarden event-log feature; it works with
  `org_events_enabled` off.
- Sink reuses the existing logging stack, so it honors `LOG_FILE` / `USE_SYSLOG`.
- Consistent with ADR-0001 (additive, minimal hook surface).
