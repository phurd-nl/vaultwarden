//! Account-lockout decision logic (NIST SP 800-53B: AC-7).
//!
//! Additive fork module (see docs/adr/0003). Pure, I/O-free functions so the
//! lockout policy is unit-testable without a database or clock. The login path
//! in `src/api/identity.rs` calls these to decide whether a locked account must
//! be rejected, and whether a failed attempt should trigger a lock.
//!
//! Lockout uses temporary auto-unlock: after `max_attempts` consecutive
//! failures the account is locked for a cooldown, then unlocks automatically.
//! This satisfies AC-7 without an unbounded targeted-DoS vector.

use chrono::{Duration, NaiveDateTime};

/// Result of evaluating the lockout policy for a single login event.
#[derive(Debug, PartialEq, Eq)]
pub struct Decision {
    /// The account is currently locked (cooldown has not yet elapsed); reject
    /// the login before verifying the password.
    pub currently_locked: bool,
    /// The most recent failure pushed the consecutive-failure count to the
    /// threshold; the caller should set `locked_until` and reset the counter.
    pub should_lock: bool,
    /// The new value the caller should persist for `failed_login_count`.
    pub new_failed_count: i32,
    /// The new value the caller should persist for `locked_until`. `Some` only
    /// when `should_lock` is true.
    pub new_locked_until: Option<NaiveDateTime>,
}

/// Is the account currently locked at `now`?
///
/// Returns true only when lockout is enabled and `locked_until` is in the
/// future relative to `now`. A `locked_until` in the past means the cooldown
/// has elapsed and the account has auto-unlocked.
pub fn is_currently_locked(enabled: bool, locked_until: Option<NaiveDateTime>, now: NaiveDateTime) -> bool {
    enabled && matches!(locked_until, Some(t) if t > now)
}

/// Decide what to do after a FAILED password attempt.
///
/// `failed_count` is the user's current consecutive-failure count BEFORE this
/// attempt. When lockout is disabled, this is a no-op decision that leaves the
/// counter untouched. When the incremented count reaches `max_attempts`, the
/// account is locked for `cooldown_seconds` and the counter is reset to 0.
pub fn decide_after_failure(
    enabled: bool,
    failed_count: i32,
    max_attempts: i32,
    cooldown_seconds: i64,
    now: NaiveDateTime,
) -> Decision {
    if !enabled || max_attempts <= 0 {
        return Decision {
            currently_locked: false,
            should_lock: false,
            new_failed_count: failed_count,
            new_locked_until: None,
        };
    }

    let incremented = failed_count.saturating_add(1);
    if incremented >= max_attempts {
        Decision {
            currently_locked: false,
            should_lock: true,
            // Reset the counter once we lock; the lock itself enforces the cooldown.
            new_failed_count: 0,
            new_locked_until: Some(now + Duration::seconds(cooldown_seconds)),
        }
    } else {
        Decision {
            currently_locked: false,
            should_lock: false,
            new_failed_count: incremented,
            new_locked_until: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn t(secs: i64) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(2026, 6, 9).unwrap().and_hms_opt(0, 0, 0).unwrap() + Duration::seconds(secs)
    }

    #[test]
    fn disabled_never_locks_and_leaves_count_untouched() {
        let d = decide_after_failure(false, 4, 5, 900, t(0));
        assert!(!d.should_lock);
        assert!(!d.currently_locked);
        assert_eq!(d.new_failed_count, 4);
        assert_eq!(d.new_locked_until, None);
    }

    #[test]
    fn failure_below_threshold_increments_only() {
        let d = decide_after_failure(true, 2, 5, 900, t(0));
        assert!(!d.should_lock);
        assert_eq!(d.new_failed_count, 3);
        assert_eq!(d.new_locked_until, None);
    }

    #[test]
    fn failure_reaching_threshold_locks_and_resets() {
        // count was 4, this is the 5th consecutive failure -> lock
        let d = decide_after_failure(true, 4, 5, 900, t(0));
        assert!(d.should_lock);
        assert_eq!(d.new_failed_count, 0);
        assert_eq!(d.new_locked_until, Some(t(900)));
    }

    #[test]
    fn is_locked_only_when_enabled_and_future() {
        assert!(is_currently_locked(true, Some(t(100)), t(50)));
        // cooldown elapsed -> auto unlocked
        assert!(!is_currently_locked(true, Some(t(50)), t(100)));
        // disabled -> never locked
        assert!(!is_currently_locked(false, Some(t(100)), t(50)));
        // no lock set
        assert!(!is_currently_locked(true, None, t(50)));
    }

    #[test]
    fn non_positive_max_attempts_disables_locking() {
        let d = decide_after_failure(true, 99, 0, 900, t(0));
        assert!(!d.should_lock);
        assert_eq!(d.new_failed_count, 99);
    }
}
