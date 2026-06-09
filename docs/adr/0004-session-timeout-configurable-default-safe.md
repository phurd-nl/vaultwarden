# 4. Session timeout: configurable knobs with current-behavior defaults (AC-11 / AC-12)

Date: 2026-06-09

## Status

Accepted

## Context

NIST 800-53B Moderate AC-11 (session lock) and AC-12 (session termination) push
toward idle and absolute session limits. Vaultwarden's effective session is the
refresh-token lifetime (30 days default, 90 on mobile); clients silently refresh
the 2h access token, and there is no server-side idle tracking.

A hard constraint from the project owner: "I don't want them to sign me out
randomly" and "don't break anything." Aggressive default expiry would violate
this.

## Decision

Adopt **A + C**:

- **A (capability exists):** Make the refresh-token absolute lifetime
  configurable via new `SESSION_*` config keys, and add an *optional* idle-timeout
  check in `auth::refresh_tokens` keyed on the device's last-use timestamp. Both
  default to today's behavior (absolute lifetime = current 30/90 days; idle check
  off), so nothing changes unless an operator opts in.
- **C (lean on the client):** Document that interactive session *lock* (AC-11) is
  additionally provided by the Bitwarden client vault-timeout (enforceable
  org-wide via the Vault Timeout policy), and that session *termination* (AC-12)
  is met by the configurable absolute lifetime plus existing
  deauth-on-password-change (security stamp).

The control is "a configurable, enforced timeout exists," not a punishing
default. The operator selects a policy value.

## Consequences

- AC-11/12 are demonstrably enforceable to an assessor without changing default
  behavior or risking unexpected sign-outs.
- Idle logic is confined to `auth::refresh_tokens`; absolute lifetime replaces
  two static consts with config lookups.
- The chosen policy value becomes documented evidence, not a code default.
