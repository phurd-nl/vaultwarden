// NIST SP 800-53B Moderate — AC-11 (session lock) / AC-12 (session termination)
//
// Additive fork module (see docs/adr/0001, 0004). Pure, I/O-free session-timeout
// logic so it is unit-testable without a database or clock. The single hook into
// upstream lives in `auth::refresh_tokens`.
//
// Default-safe: idle timeout is OFF unless an operator sets a positive minute value,
// preserving the historical "never sign me out randomly" behavior.

use chrono::{NaiveDateTime, TimeDelta};

/// Returns true if a session should be considered idle-expired and forced to re-login.
///
/// - `last_used`:   the device's last-use timestamp (UTC, e.g. `device.updated_at`).
/// - `idle_minutes`: the configured idle window. `None` (or a non-positive value)
///   disables idle timeout entirely, so this always returns `false` in that case.
/// - `now`:         the current time (UTC).
///
/// Pure function: no I/O, no global clock, no config lookup — all inputs are explicit
/// so the caller can be tested deterministically.
pub fn idle_expired(last_used: NaiveDateTime, idle_minutes: Option<i64>, now: NaiveDateTime) -> bool {
    match idle_minutes {
        // Unset => idle timeout OFF (current behavior).
        None => false,
        // Non-positive minutes are treated as "off" to avoid locking everyone out
        // from a misconfiguration (e.g. 0 or a negative value).
        Some(m) if m <= 0 => false,
        Some(m) => match TimeDelta::try_minutes(m) {
            Some(window) => now.signed_duration_since(last_used) > window,
            // Overflow on an absurd value => fail open (do not expire).
            None => false,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn ts(h: u32, m: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(2026, 6, 9).unwrap().and_hms_opt(h, m, 0).unwrap()
    }

    #[test]
    fn none_never_expires() {
        // Idle timeout unset must always be false, even with a very old last-use.
        let last = ts(0, 0);
        let now = ts(23, 59);
        assert!(!idle_expired(last, None, now));
    }

    #[test]
    fn within_window_not_expired() {
        let last = ts(10, 0);
        let now = ts(10, 14); // 14 minutes later
        assert!(!idle_expired(last, Some(15), now));
    }

    #[test]
    fn exactly_at_window_not_expired() {
        let last = ts(10, 0);
        let now = ts(10, 15); // exactly 15 minutes => not strictly greater
        assert!(!idle_expired(last, Some(15), now));
    }

    #[test]
    fn past_window_expired() {
        let last = ts(10, 0);
        let now = ts(10, 16); // 16 minutes later
        assert!(idle_expired(last, Some(15), now));
    }

    #[test]
    fn non_positive_minutes_treated_as_off() {
        let last = ts(0, 0);
        let now = ts(23, 59);
        assert!(!idle_expired(last, Some(0), now));
        assert!(!idle_expired(last, Some(-5), now));
    }
}
