//! AC-8 system-use notification (login banner). Additive fork module.
//!
//! The operator-configured banner (`LOGIN_BANNER`) is a system-use notification
//! presented at/around authentication (NIST SP 800-53B: AC-8). This module holds
//! the pure mapping from the configured value to the JSON fragment merged into
//! the client config endpoint, kept side-effect-free so it is unit-testable.
//!
//! Note: the stock Bitwarden web/desktop/mobile clients ignore unknown
//! `GET /api/config` fields, so `loginBanner` will not render on the end-user
//! vault login screen without a custom client. The assessor-facing surface is
//! the `/admin` login page (see `templates/admin/login.hbs`).
//!
//! NEVER serialize secrets here: the banner is operator-authored display text.

use serde_json::{Map, Value};

/// Trim and normalize the configured banner.
///
/// Returns `None` when unset or blank (whitespace-only), so a configured-but-empty
/// value preserves the no-banner default behavior.
fn normalize(banner: Option<&str>) -> Option<&str> {
    match banner {
        Some(b) if !b.trim().is_empty() => Some(b),
        _ => None,
    }
}

/// Build the JSON fragment to merge into the client config endpoint.
///
/// Returns a map containing `"loginBanner"` only when a non-blank banner is set;
/// otherwise an empty map (no field), so existing client behavior is unchanged.
pub fn config_fragment(banner: Option<&str>) -> Map<String, Value> {
    let mut map = Map::new();
    if let Some(b) = normalize(banner) {
        map.insert("loginBanner".to_owned(), Value::String(b.to_owned()));
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn omits_field_when_unset() {
        let frag = config_fragment(None);
        assert!(frag.is_empty());
        assert!(!frag.contains_key("loginBanner"));
    }

    #[test]
    fn omits_field_when_blank() {
        assert!(config_fragment(Some("")).is_empty());
        assert!(config_fragment(Some("   \n\t ")).is_empty());
    }

    #[test]
    fn includes_field_when_set() {
        let frag = config_fragment(Some("Authorized use only."));
        assert_eq!(frag["loginBanner"], Value::String("Authorized use only.".to_owned()));
    }
}
