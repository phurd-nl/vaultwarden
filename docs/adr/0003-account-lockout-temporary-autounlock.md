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

## Scope / coverage limits

The counter increments only on the credential-verification failure paths in
`password_login`: a wrong master password and a bad passwordless auth-request
access code. The following are deliberately **not** counted toward lockout in
v1, and an assessor should be aware of the boundary:

- **Second-factor (2FA) failures** after a correct password
  (`UserFailedLogIn2fa`). The master password — the brute-forceable secret — is
  already protected; 2FA failures are throttled by the existing login
  rate-limit.
- **SSO logins**, which authenticate through the identity provider on a separate
  code path; account lockout there is the IdP's responsibility (and a federal
  deployment would lean on the IdP's AC-7).
- **Failed logins against a non-existent username**, which return before a
  `users` row exists and therefore cannot be attributed to (or counted against)
  an account. Login rate-limiting still applies.

These gaps do not weaken protection of the password secret; they scope the
control to the vector AC-7 is primarily concerned with (master-password
guessing).
