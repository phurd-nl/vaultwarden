//! SSO department-based collection assignment (NIST AC-2 / AC-6).
//!
//! On SSO login, reconcile a user's access to "department vault" collections
//! against the Entra `department` claim. Department collections are identified
//! by a plaintext `external_id` (the department name) that an admin sets once
//! when creating the collection — the server can't create them itself because
//! collection *names* are end-to-end encrypted with the org key it never holds.
//!
//! Sync semantics (grant + revoke): a collection that carries an `external_id`
//! is considered SSO-managed. On every login the user is granted access to the
//! collection whose `external_id` matches their department claim and removed
//! from any other external_id-tagged collection. Collections without an
//! `external_id` are manual and never touched.
//!
//! Aliases: a collection's `external_id` may hold several department strings
//! separated by `|` (e.g. `Voice over IP|VoIP`). The user matches the collection
//! if their department equals ANY alias (case-insensitive, trimmed). This lets a
//! single department vault absorb the spelling/format variants that real
//! directories accumulate without normalizing the source attribute.

use crate::{
    db::{
        DbConn,
        models::{Collection, CollectionId, CollectionUser, OrganizationId, UserId},
    },
    CONFIG,
};

/// A department-tagged collection in the org, plus whether the user is currently
/// a member. Built from `Collection::find_by_organization` (external_id present)
/// joined against `CollectionUser::find_by_user`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeptColl {
    pub collection_uuid: CollectionId,
    pub external_id: String,
    pub is_member: bool,
}

/// What to do for one department collection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeptAction {
    Grant(CollectionId),
    Revoke(CollectionId),
}

/// Pure reconciliation: given the user's department claim and the set of
/// department-tagged collections, return the grant/revoke actions needed.
///
/// Matching is case-insensitive after trimming. An `external_id` may carry
/// several `|`-delimited aliases; the user matches if their department equals
/// any one of them. A missing/empty department revokes the user from every
/// department collection they are in.
pub fn reconcile_department_access(department: Option<&str>, dept_collections: &[DeptColl]) -> Vec<DeptAction> {
    let dept = department.map(str::trim).filter(|d| !d.is_empty());

    let mut actions = Vec::new();
    for coll in dept_collections {
        let matches = dept.is_some_and(|d| {
            coll.external_id.split('|').any(|alias| {
                let alias = alias.trim();
                !alias.is_empty() && d.eq_ignore_ascii_case(alias)
            })
        });
        match (matches, coll.is_member) {
            (true, false) => actions.push(DeptAction::Grant(coll.collection_uuid.clone())),
            (false, true) => actions.push(DeptAction::Revoke(coll.collection_uuid.clone())),
            // already a member of the match, or not a member of a non-match: nothing to do.
            (true, true) | (false, false) => {}
        }
    }
    actions
}

/// Reconcile the user's department-collection access against their `department`
/// claim, within the configured default org. Best-effort: logs and never aborts
/// login. No-op unless `SSO_SYNC_DEPARTMENT_COLLECTIONS` is on and
/// `SSO_DEFAULT_ORG` is set. Only collections carrying a plaintext `external_id`
/// (the department name) are considered SSO-managed; manual collections are
/// untouched. Grants use `hide_passwords=true` (use/autofill, can't reveal).
pub async fn sync_department_access(user_uuid: &UserId, department: Option<&str>, conn: &DbConn) {
    if !CONFIG.sso_sync_department_collections() {
        return;
    }

    let default_org = CONFIG.sso_default_org();
    let default_org = default_org.trim();
    if default_org.is_empty() {
        return;
    }
    let org_id = OrganizationId::from(default_org.to_string());

    // Department vaults = collections in the default org tagged with a non-empty external_id.
    let mut dept_collections: Vec<DeptColl> = Vec::new();
    for collection in Collection::find_by_organization(&org_id, conn).await {
        let Some(external_id) = collection.external_id.clone() else {
            continue;
        };
        if external_id.trim().is_empty() {
            continue;
        }
        let is_member = CollectionUser::find_by_collection_and_user(&collection.uuid, user_uuid, conn).await.is_some();
        dept_collections.push(DeptColl {
            collection_uuid: collection.uuid,
            external_id,
            is_member,
        });
    }

    if dept_collections.is_empty() {
        return;
    }

    for action in reconcile_department_access(department, &dept_collections) {
        match action {
            DeptAction::Grant(collection_uuid) => {
                // read_only=false, hide_passwords=true (use/autofill, can't reveal), manage=false.
                if let Err(e) = CollectionUser::save(user_uuid, &collection_uuid, false, true, false, conn).await {
                    error!("SSO dept-sync: failed to grant collection {collection_uuid} to user {user_uuid}: {e:?}");
                } else {
                    info!("SSO dept-sync: granted collection {collection_uuid} to user {user_uuid} (department match)");
                }
            }
            DeptAction::Revoke(collection_uuid) => {
                if let Some(membership) =
                    CollectionUser::find_by_collection_and_user(&collection_uuid, user_uuid, conn).await
                {
                    if let Err(e) = membership.delete(conn).await {
                        error!("SSO dept-sync: failed to revoke collection {collection_uuid} from user {user_uuid}: {e:?}");
                    } else {
                        info!("SSO dept-sync: revoked collection {collection_uuid} from user {user_uuid} (department changed)");
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn coll(id: &str, ext: &str, is_member: bool) -> DeptColl {
        DeptColl {
            collection_uuid: CollectionId::from(id.to_string()),
            external_id: ext.to_string(),
            is_member,
        }
    }

    #[test]
    fn grants_matching_and_revokes_others() {
        let colls = vec![coll("c-fin", "Finance", false), coll("c-it", "IT", true)];
        let actions = reconcile_department_access(Some("Finance"), &colls);
        assert!(actions.contains(&DeptAction::Grant(CollectionId::from("c-fin".to_string()))));
        assert!(actions.contains(&DeptAction::Revoke(CollectionId::from("c-it".to_string()))));
        assert_eq!(actions.len(), 2);
    }

    #[test]
    fn no_action_when_already_member_of_match() {
        let colls = vec![coll("c-fin", "Finance", true)];
        let actions = reconcile_department_access(Some("Finance"), &colls);
        assert!(actions.is_empty());
    }

    #[test]
    fn case_insensitive_and_trims() {
        let colls = vec![coll("c-fin", "Finance", false)];
        let actions = reconcile_department_access(Some("  finance "), &colls);
        assert_eq!(actions, vec![DeptAction::Grant(CollectionId::from("c-fin".to_string()))]);
    }

    #[test]
    fn missing_department_revokes_all_memberships() {
        let colls = vec![coll("c-fin", "Finance", true), coll("c-it", "IT", false)];
        let actions = reconcile_department_access(None, &colls);
        assert_eq!(actions, vec![DeptAction::Revoke(CollectionId::from("c-fin".to_string()))]);
    }

    #[test]
    fn unknown_department_revokes_current_memberships() {
        let colls = vec![coll("c-fin", "Finance", true)];
        let actions = reconcile_department_access(Some("Marketing"), &colls);
        assert_eq!(actions, vec![DeptAction::Revoke(CollectionId::from("c-fin".to_string()))]);
    }

    #[test]
    fn grants_when_department_matches_any_pipe_alias() {
        let colls = vec![coll("c-voip", "Voice over IP|VoIP", false)];
        // Either spelling grants the same collection.
        assert_eq!(
            reconcile_department_access(Some("VoIP"), &colls),
            vec![DeptAction::Grant(CollectionId::from("c-voip".to_string()))]
        );
        assert_eq!(
            reconcile_department_access(Some("  voice over ip "), &colls),
            vec![DeptAction::Grant(CollectionId::from("c-voip".to_string()))]
        );
    }

    #[test]
    fn revokes_aliased_collection_when_no_alias_matches() {
        let colls = vec![coll("c-voip", "Voice over IP|VoIP", true)];
        assert_eq!(
            reconcile_department_access(Some("Marketing"), &colls),
            vec![DeptAction::Revoke(CollectionId::from("c-voip".to_string()))]
        );
    }

    #[test]
    fn empty_aliases_from_stray_pipes_never_match() {
        // A stray/trailing pipe must not produce an empty alias that matches an
        // empty-ish department; non-empty departments simply don't match empties.
        let colls = vec![coll("c-x", "Engineering||", false)];
        assert_eq!(
            reconcile_department_access(Some("Engineering"), &colls),
            vec![DeptAction::Grant(CollectionId::from("c-x".to_string()))]
        );
        assert!(reconcile_department_access(Some(" "), &colls).is_empty());
    }
}
