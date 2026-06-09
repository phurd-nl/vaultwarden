//! Structured audit event emitter (NIST SP 800-53B: AU-2, AU-3, AU-12).
//!
//! Additive fork module (see docs/adr/0002). When `AUDIT_LOG_ENABLED=true`,
//! every security event routed through the two event choke points
//! (`log_event` / `log_user_event` in `src/api/core/events.rs`) emits a single
//! line of JSON to the application log on the `nextvault::audit` target.
//!
//! This is independent of the upstream `ORG_EVENTS_ENABLED` feature.
//!
//! NEVER serialize secrets here: only event metadata and resource identifiers.

use chrono::{SecondsFormat, Utc};
use serde_json::{Map, Value};

use crate::CONFIG;

// NIST AC-7 account lockout decision logic (additive, see docs/adr/0003).
pub mod lockout;

// NIST AC-8 system-use notification (login banner) fragment builder (additive).
pub mod banner;

/// Map an upstream `EventType` numeric code to a stable, snake_case audit name.
///
/// Values mirror `src/db/models/event.rs` `EventType`. Unknown codes fall back
/// to `event_<code>` so the audit trail never silently drops an event.
fn event_name(event_type: i32) -> String {
    let name = match event_type {
        // User
        1000 => "user_logged_in",
        1001 => "user_changed_password",
        1002 => "user_updated_2fa",
        1003 => "user_disabled_2fa",
        1004 => "user_recovered_2fa",
        1005 => "user_failed_login",
        1006 => "user_failed_login_2fa",
        1007 => "user_client_exported_vault",
        1010 => "user_requested_device_approval",
        // Cipher
        1100 => "cipher_created",
        1101 => "cipher_updated",
        1102 => "cipher_deleted",
        1103 => "cipher_attachment_created",
        1104 => "cipher_attachment_deleted",
        1105 => "cipher_shared",
        1106 => "cipher_updated_collections",
        1107 => "cipher_client_viewed",
        1108 => "cipher_client_toggled_password_visible",
        1109 => "cipher_client_toggled_hidden_field_visible",
        1110 => "cipher_client_toggled_card_code_visible",
        1111 => "cipher_client_copied_password",
        1112 => "cipher_client_copied_hidden_field",
        1113 => "cipher_client_copied_card_code",
        1114 => "cipher_client_autofilled",
        1115 => "cipher_soft_deleted",
        1116 => "cipher_restored",
        1117 => "cipher_client_toggled_card_number_visible",
        // Collection
        1300 => "collection_created",
        1301 => "collection_updated",
        1302 => "collection_deleted",
        // Group
        1400 => "group_created",
        1401 => "group_updated",
        1402 => "group_deleted",
        // OrganizationUser
        1500 => "organization_user_invited",
        1501 => "organization_user_confirmed",
        1502 => "organization_user_updated",
        1503 => "organization_user_removed",
        1504 => "organization_user_updated_groups",
        1505 => "organization_user_unlinked_sso",
        1506 => "organization_user_reset_password_enroll",
        1507 => "organization_user_reset_password_withdraw",
        1508 => "organization_user_admin_reset_password",
        1511 => "organization_user_revoked",
        1512 => "organization_user_restored",
        1513 => "organization_user_approved_auth_request",
        1514 => "organization_user_rejected_auth_request",
        1515 => "organization_user_deleted",
        1516 => "organization_user_left",
        // Organization
        1600 => "organization_updated",
        1601 => "organization_purged_vault",
        1602 => "organization_client_exported_vault",
        // Policy
        1700 => "policy_updated",
        _ => return format!("event_{event_type}"),
    };
    name.to_owned()
}

/// Insert `key => value` into `map` only when `value` is `Some`.
fn insert_opt(map: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(v) = value {
        map.insert(key.to_owned(), Value::String(v.to_owned()));
    }
}

/// Build the structured audit record as a `serde_json::Value`.
///
/// `ts` is the RFC3339/UTC timestamp string. It is passed in (rather than read
/// from the clock) so the field-mapping logic is unit-testable as a pure
/// function. All `Option` fields are omitted from the object when `None`.
#[expect(clippy::too_many_arguments)]
fn audit_record_json_at(
    ts: &str,
    event_type: i32,
    event_name: &str,
    user_uuid: Option<&str>,
    act_user_uuid: Option<&str>,
    org_uuid: Option<&str>,
    cipher_uuid: Option<&str>,
    device_type: Option<i32>,
    ip: Option<&str>,
) -> Value {
    let mut map = Map::new();
    map.insert("ts".to_owned(), Value::String(ts.to_owned()));
    map.insert("event_type".to_owned(), Value::from(event_type));
    map.insert("event_name".to_owned(), Value::String(event_name.to_owned()));
    insert_opt(&mut map, "user_uuid", user_uuid);
    insert_opt(&mut map, "act_user_uuid", act_user_uuid);
    insert_opt(&mut map, "org_uuid", org_uuid);
    insert_opt(&mut map, "cipher_uuid", cipher_uuid);
    if let Some(dt) = device_type {
        map.insert("device_type".to_owned(), Value::from(dt));
    }
    insert_opt(&mut map, "ip", ip);
    Value::Object(map)
}

/// Build the structured audit record. The `ts` field is stamped from
/// `Utc::now()` (RFC3339, seconds precision); all other fields are mapped
/// purely from the arguments and omitted when `None`.
#[expect(clippy::too_many_arguments)]
pub fn audit_record_json(
    event_type: i32,
    event_name: &str,
    user_uuid: Option<&str>,
    act_user_uuid: Option<&str>,
    org_uuid: Option<&str>,
    cipher_uuid: Option<&str>,
    device_type: Option<i32>,
    ip: Option<&str>,
) -> Value {
    let ts = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
    audit_record_json_at(&ts, event_type, event_name, user_uuid, act_user_uuid, org_uuid, cipher_uuid, device_type, ip)
}

/// Emit an audit record for an upstream `EventType`-coded security event.
///
/// No-op unless `AUDIT_LOG_ENABLED` is set. Logs a single JSON line on the
/// `nextvault::audit` target.
pub fn emit(
    event_type: i32,
    source_uuid: Option<&str>,
    user_uuid: Option<&str>,
    act_user_uuid: Option<&str>,
    org_uuid: Option<&str>,
    device_type: Option<i32>,
    ip: Option<&str>,
) {
    if !CONFIG.audit_log_enabled() {
        return;
    }
    let name = event_name(event_type);
    // Cipher events (1100..=1199) carry the cipher id in source_uuid.
    let cipher_uuid = if (1100..=1199).contains(&event_type) {
        source_uuid
    } else {
        None
    };
    let record = audit_record_json(event_type, &name, user_uuid, act_user_uuid, org_uuid, cipher_uuid, device_type, ip);
    info!(target: "nextvault::audit", "{record}");
}

/// Emit an audit record for a non-`EventType` administrative security event
/// (e.g. `/admin` logins). No-op unless `AUDIT_LOG_ENABLED` is set.
pub fn emit_named(event_name: &str, user_uuid: Option<&str>, ip: Option<&str>) {
    if !CONFIG.audit_log_enabled() {
        return;
    }
    let ts = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
    let mut map = Map::new();
    map.insert("ts".to_owned(), Value::String(ts));
    map.insert("event_name".to_owned(), Value::String(event_name.to_owned()));
    insert_opt(&mut map, "user_uuid", user_uuid);
    insert_opt(&mut map, "ip", ip);
    let record = Value::Object(map);
    info!(target: "nextvault::audit", "{record}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_known_event_type_to_name() {
        assert_eq!(event_name(1000), "user_logged_in");
        assert_eq!(event_name(1005), "user_failed_login");
        assert_eq!(event_name(1100), "cipher_created");
    }

    #[test]
    fn unknown_event_type_falls_back() {
        assert_eq!(event_name(9999), "event_9999");
    }

    #[test]
    fn record_includes_provided_ids_and_omits_none() {
        let record = audit_record_json_at(
            "2026-06-09T00:00:00Z",
            1100,
            "cipher_created",
            Some("user-1"),
            Some("act-1"),
            Some("org-1"),
            Some("cipher-1"),
            Some(7),
            Some("203.0.113.5"),
        );
        let obj = record.as_object().expect("object");
        assert_eq!(obj["ts"], Value::String("2026-06-09T00:00:00Z".to_owned()));
        assert_eq!(obj["event_type"], Value::from(1100));
        assert_eq!(obj["event_name"], Value::String("cipher_created".to_owned()));
        assert_eq!(obj["user_uuid"], Value::String("user-1".to_owned()));
        assert_eq!(obj["act_user_uuid"], Value::String("act-1".to_owned()));
        assert_eq!(obj["org_uuid"], Value::String("org-1".to_owned()));
        assert_eq!(obj["cipher_uuid"], Value::String("cipher-1".to_owned()));
        assert_eq!(obj["device_type"], Value::from(7));
        assert_eq!(obj["ip"], Value::String("203.0.113.5".to_owned()));
    }

    #[test]
    fn record_omits_none_fields() {
        let record = audit_record_json_at(
            "2026-06-09T00:00:00Z",
            1000,
            "user_logged_in",
            Some("user-1"),
            Some("user-1"),
            None,
            None,
            Some(1),
            None,
        );
        let obj = record.as_object().expect("object");
        assert!(!obj.contains_key("org_uuid"));
        assert!(!obj.contains_key("cipher_uuid"));
        assert!(!obj.contains_key("ip"));
        assert!(obj.contains_key("user_uuid"));
        assert!(obj.contains_key("device_type"));
    }
}
