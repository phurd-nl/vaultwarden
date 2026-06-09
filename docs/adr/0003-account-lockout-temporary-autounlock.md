# 3. Account lockout via temporary auto-unlock (AC-7)

Date: 2026-06-09

## Status

Accepted

## Context

NIST 800-53B Moderate AC-7 requires disabling an account after a configured
number of consecutive failed login attempts. Vaultwarden today has only login
rate-limiting (`login_ratelimit_seconds`), which throttles request rate but does
not lock an account.

Pure per-account lockout introduces a denial-of-service vector: an attacker can
lock any user out by submitting failed logins against their email address.

Options considered:

- **A. Temporary auto-unlock** — lock for a configurable cooldown after N
  consecutive failures, then auto-unlock; counter resets on success.
- **B. Lock until admin unlock** — high targeted-DoS risk.
- **C. Rate-limit only** — document throttling as a compensating control; weaker
  and may not satisfy an assessor.

## Decision

Adopt **A**. Add `failed_login_count` and `locked_until` columns to the `users`
table via a migration. At the single failed-login choke point in
`src/api/identity.rs`, increment the counter and, once it crosses a configurable
threshold, set `locked_until = now + cooldown`. A locked account rejects auth
until the cooldown elapses; a successful login resets the counter. Threshold and
cooldown are both configurable. Emit an `UserLocked` Audit Event on lockout.

For v1, unlock is automatic (time-based) only. A manual admin "unlock now"
action is deferred to the admin/IR work.

## Consequences

- AC-7 satisfied without an unbounded DoS vector; complements existing
  rate-limiting.
- Requires a schema migration (additive columns, backward compatible).
- Login-path change is confined to the failed-login and successful-login points.
- Locked-out legitimate users recover automatically after the cooldown.
