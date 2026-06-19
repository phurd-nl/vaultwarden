# Context Glossary

Canonical vocabulary for the NIST SP 800-53B Moderate hardening of this
Vaultwarden fork. Glossary only — no implementation details. See `docs/adr/`
for decisions.

## Terms

### Audit Event
A structured (JSON) record of a security-relevant action, emitted to the
application log sink (stdout by default; honors `LOG_FILE`/`USE_SYSLOG`) so it
can be shipped to a SIEM. Distinct from an **Org Event**. Gated by its own
`AUDIT_LOG_ENABLED` flag, independent of `org_events_enabled`. Serves NIST
AU-2 / AU-3 / AU-12.

### Org Event
The pre-existing Bitwarden-compatible event-log feature
(`src/db/models/event.rs`, `EventType`). Persisted to the database, org-scoped,
surfaced in the org admin console, gated by `org_events_enabled` (off by
default). NOT a substitute for an Audit Event — it is DB-only and off by
default.

### Choke point
The two functions every Org Event already routes through — `log_event` and
`log_user_event` in `src/api/core/events.rs`. The Audit Event emitter taps these
so all existing instrumentation lights up at once. See ADR-0002.

### Account Lockout (AC-7)
Temporary disabling of authentication for a specific account after a configured
number of consecutive failed login attempts. Distinct from **login
rate-limiting** (`login_ratelimit_seconds`), which only throttles request rate
and does not lock an account.

### Login Banner (AC-8)
A system-use notification message presented at/around authentication, configured
by the operator and recorded as acknowledged where the client supports it.

### Session Timeout (AC-11 / AC-12)
Idle and absolute lifetime limits on a user's authenticated session. Today only
`admin_session_lifetime` exists, and only for the `/admin` page; regular user
sessions use a long-lived refresh token with no idle-timeout knob.

### Hardened Deployment
The podman-based, active-passive (manual failover) runtime around the app:
reverse proxy + TLS, PostgreSQL, podman secrets, encrypted storage, backups,
log shipping. The bulk of 800-53B Moderate lives here, not in source.
