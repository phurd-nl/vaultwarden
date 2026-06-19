//! SSO default-organization auto-enrollment (NIST AC-2 account provisioning).
//!
//! When `SSO_DEFAULT_ORG` is set to an organization UUID, every successful SSO
//! login ensures the user holds a membership in that organization. New members
//! are created in `Accepted`/`User` state with an empty org key; an org admin
//! must still `Confirm` them. The confirm step is what delivers the org key
//! encrypted to the member's (by-then-existing) public key, so the server never
//! holds the org key and end-to-end encryption is preserved.
//!
//! The behaviour is idempotent and best-effort: an existing membership of any
//! type is left untouched (so manually-elevated Admins/Owners are never
//! downgraded), and any failure is logged without aborting the login.

use crate::{
    db::{
        DbConn,
        models::{Membership, MembershipStatus, MembershipType, Organization, OrganizationId, User, UserId},
    },
    CONFIG,
};

/// Whether an SSO login should create a default-org membership. True only when a
/// default org is configured and the user is not already a member of it.
pub fn should_auto_enroll(default_org: &str, already_member: bool) -> bool {
    !default_org.trim().is_empty() && !already_member
}

/// Build the membership stub for an auto-enrolled SSO user: a regular `User` in
/// `Accepted` state with no org key. `Accepted` (not `Invited`) is required so an
/// admin can immediately `Confirm` the member — `confirm_invite_impl` rejects any
/// other status with "User in invalid state".
pub fn build_default_org_membership(user_uuid: UserId, org_uuid: OrganizationId) -> Membership {
    let mut member = Membership::new(user_uuid, org_uuid, None);
    member.atype = MembershipType::User as i32;
    member.status = MembershipStatus::Accepted as i32;
    member
}

/// Ensure the SSO user is a member of the configured default org. Best-effort:
/// never returns an error that would abort login.
pub async fn ensure_default_org_membership(user: &User, conn: &DbConn) {
    let default_org = CONFIG.sso_default_org();
    let default_org = default_org.trim();
    if default_org.is_empty() {
        return;
    }

    let org_id = OrganizationId::from(default_org.to_string());

    let already_member = Membership::find_by_user_and_org(&user.uuid, &org_id, conn).await.is_some();
    if !should_auto_enroll(default_org, already_member) {
        return;
    }

    if Organization::find_by_uuid(&org_id, conn).await.is_none() {
        error!("SSO_DEFAULT_ORG '{org_id}' does not exist; skipping auto-enrollment for user {}", user.uuid);
        return;
    }

    let member = build_default_org_membership(user.uuid.clone(), org_id.clone());
    if let Err(e) = member.save(conn).await {
        error!("Failed to auto-enroll user {} into default org {org_id}: {e:?}", user.uuid);
        return;
    }

    info!("Auto-enrolled SSO user {} into default org {org_id} (pending admin confirmation)", user.uuid);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_enroll_when_default_org_unset() {
        assert!(!should_auto_enroll("", false));
        assert!(!should_auto_enroll("   ", false));
    }

    #[test]
    fn enroll_when_configured_and_not_member() {
        assert!(should_auto_enroll("3f1c0c1e-0000-0000-0000-000000000000", false));
    }

    #[test]
    fn no_enroll_when_already_member() {
        // Never re-enroll: protects manually-elevated Admins/Owners from downgrade.
        assert!(!should_auto_enroll("3f1c0c1e-0000-0000-0000-000000000000", true));
    }

    #[test]
    fn membership_stub_is_accepted_user_with_no_key() {
        let member = build_default_org_membership(
            UserId::from("11111111-1111-1111-1111-111111111111".to_string()),
            OrganizationId::from("22222222-2222-2222-2222-222222222222".to_string()),
        );
        assert_eq!(member.atype, MembershipType::User as i32, "auto-enrolled members must be regular Users");
        assert_eq!(member.status, MembershipStatus::Accepted as i32, "must be Accepted so admins can Confirm");
        assert!(member.akey.is_empty(), "server must not hold an org key for the member");
        assert!(!member.access_all, "regular users do not get access_all");
    }
}
