export const meta = {
  name: 'nist-source-slices',
  description: 'Implement the 5 NIST 800-53B Moderate source slices sequentially (shared tree + build cache), then security-review',
  phases: [
    { title: 'Slice 1: Audit foundation' },
    { title: 'Slice 2: Admin audit events' },
    { title: 'Slice 3: AC-7 lockout' },
    { title: 'Slice 4: AC-8 login banner' },
    { title: 'Slice 5: AC-11/12 session' },
    { title: 'Security review' },
  ],
}

const SLICE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['ok', 'build_passed', 'summary', 'files_changed', 'notes'],
  properties: {
    ok: { type: 'boolean', description: 'true only if the slice is complete AND cargo check --features sqlite passes AND the tree is left compiling' },
    build_passed: { type: 'boolean', description: 'true if `cargo check --features sqlite` exited 0 after your changes' },
    test_passed: { type: 'boolean', description: 'true if the slice unit test passed' },
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    config_keys_added: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string', description: 'anything the orchestrator or next slice must know; if you reverted partial work say so here' },
  },
}

const COMMON = `
You are modifying a fork of Vaultwarden (Rust) to add NIST SP 800-53B Moderate controls.
HARD RULES (ADR-0001, additive fork posture):
- Be ADDITIVE. New behavior goes in NEW files. Touch existing upstream files MINIMALLY — ideally one-line hook insertions clearly delimited.
- The build/compile gate is EXACTLY: \`cargo check --features sqlite\` (run from repo root /home/phurd/GitHub/VaultWarden). Do NOT use --all-features (it enables conflicting DB backends and will fail).
- You MUST leave the tree COMPILING. If you cannot finish cleanly, revert your partial changes (git checkout -- <files> / delete new files) so downstream slices build, and report ok=false with details in notes.
- Config keys are added in src/config.rs inside the make_config! macro using the form:
    /// Human label |> longer help
    key_name:  Type, editable_bool, action, default;
  where action is one of: def (has default), option (Option<T>, no default). The macro auto-generates an accessor CONFIG.key_name().
  Add new NIST keys under a new section comment. Also add them to .env.template (if it exists) with a short comment, defaulted to preserve current behavior.
- TDD: write the unit test FIRST, see it fail, then implement until it passes. Prefer extracting a PURE function for the logic so it is unit-testable without I/O. Put tests in a #[cfg(test)] mod at the bottom of the new module file.
- NEVER log or serialize secrets: no passwords, master-password hashes, tokens, ADMIN_TOKEN, refresh tokens, private keys.
- Do NOT git commit. Do NOT run cargo build/test for unrelated features. Keep changes scoped to this slice.
Return ONLY the structured result.
`

phase('Slice 1: Audit foundation')
const s1 = await agent(`${COMMON}
SLICE 1 — Structured Audit Event emitter (NIST AU-2/AU-3/AU-12). See docs/adr/0002.

Goal: when AUDIT_LOG_ENABLED=true, every security event already routed through the two event choke points emits a single-line JSON audit record to the app log (stdout). Independent of org_events_enabled.

Implement:
1. New module src/audit/mod.rs. Register it with \`mod audit;\` in src/main.rs (find the other top-level \`mod\` declarations).
2. New config key in src/config.rs: \`audit_log_enabled: bool, false, def, false;\` under a new "/// Audit logging (NIST AU)" section. Add to .env.template too (commented, default false).
3. In src/audit/mod.rs expose:
   - A PURE function \`pub fn audit_record_json(event_type: i32, event_name: &str, user_uuid: Option<&str>, act_user_uuid: Option<&str>, org_uuid: Option<&str>, cipher_uuid: Option<&str>, device_type: Option<i32>, ip: Option<&str>) -> serde_json::Value\` building an object with keys: ts (RFC3339 UTC, use chrono Utc::now()), event_type, event_name, and the optional ids/fields when present (omit None). NOTE: ts makes this not fully pure; for testability accept an optional timestamp param OR test only the non-ts fields.
   - \`pub fn emit(event_type: i32, source_uuid: Option<&str>, user_uuid: Option<&str>, act_user_uuid: Option<&str>, org_uuid: Option<&str>, device_type: Option<i32>, ip: Option<&str>)\` that returns early if !CONFIG.audit_log_enabled(), else builds the record and logs it as a single line via the \`log\` crate: \`info!(target: "vaultwarden::audit", "{}", record.to_string());\`. Map event_type -> name string (numeric ranges per src/db/models/event.rs EventType, e.g. 1000=user_logged_in, 1005=user_failed_login, 1100=cipher_created, etc.; for unknown use format!("event_{event_type}")).
   - \`pub fn emit_named(event_name: &str, user_uuid: Option<&str>, ip: Option<&str>)\` for non-EventType admin events (used by slice 2). Same gating + single-line JSON.
4. Hooks (the ONLY edits to existing event code) in src/api/core/events.rs:
   - At the very TOP of \`pub async fn log_event(...)\` (currently line ~263), BEFORE the \`if !CONFIG.org_events_enabled()\` early return, insert one call to crate::audit::emit(event_type, Some(source_uuid), None, Some(act_user_id.as_ref()), Some(org_id.as_ref()), Some(device_type), Some(&ip.to_string())). Adjust .as_ref()/types to match (UserId/OrganizationId are newtypes around String — use the right accessor; check how they Display).
   - At the very TOP of \`pub async fn log_user_event(...)\` (line ~222), BEFORE its org_events early return, insert crate::audit::emit(event_type, None, Some(user_id-as-str), Some(user_id-as-str), None, Some(device_type), Some(&ip.to_string())).
5. Unit test in src/audit/mod.rs: assert audit_record_json maps a known event_type to the right event_name and includes provided ids, omits None fields.

Verify: \`cargo check --features sqlite\` passes and \`cargo test --features sqlite audit::\` passes.
`, { schema: SLICE_SCHEMA, label: 'slice1-audit', phase: 'Slice 1: Audit foundation' })

if (!s1?.ok) {
  log(`Slice 1 did NOT complete cleanly (ok=${s1?.ok}). Aborting dependent slices 2 & 3; will still attempt independent slices 4 & 5.`)
}

phase('Slice 2: Admin audit events')
const s2 = s1?.ok ? await agent(`${COMMON}
SLICE 2 — Explicit admin-path audit events (NIST AU). Depends on slice 1's crate::audit::emit_named. See docs/adr/0002.

In src/api/admin.rs add crate::audit::emit_named(...) calls (additive, one line each) for:
- Successful /admin authentication (find the admin auth success path / the AdminToken guard or post_admin_login).
- Failed ADMIN_TOKEN attempt (the path that rejects a bad admin token).
- Admin configuration change (where config is saved, e.g. post_config / the handler that writes config.json).
Use stable event names like "admin.login.success", "admin.login.failure", "admin.config.changed". Include client IP if available in that handler; never include the token value.
Add a unit test only if a pure helper is introduced; otherwise ensure compile.
Verify \`cargo check --features sqlite\` passes.
`, { schema: SLICE_SCHEMA, label: 'slice2-admin', phase: 'Slice 2: Admin audit events' }) : null

phase('Slice 3: AC-7 lockout')
const s3 = s1?.ok ? await agent(`${COMMON}
SLICE 3 — AC-7 account lockout via temporary auto-unlock. See docs/adr/0003. RISKIEST slice — be precise.

1. Migration in ALL THREE backends. Create dir migrations/{sqlite,mysql,postgresql}/2026-06-09-000000_account_lockout/ each with up.sql and down.sql. up.sql adds to the \`users\` table: failed_login_count (integer, NOT NULL, default 0) and locked_until (nullable timestamp). MATCH the column types/conventions used by existing timestamp columns in each backend (inspect a prior migration in each dir; postgresql uses TIMESTAMP, mysql DATETIME, sqlite TIMESTAMP/TEXT/DATETIME — follow existing). down.sql drops both columns.
2. Diesel schema: add the two columns to the \`users\` table in the schema files (find them: likely src/db/schemas/{sqlite,mysql,postgresql}/schema.rs or src/db/schema.rs). Add to the User struct in src/db/models/user.rs (with sensible defaults in User::new).
3. Config keys (src/config.rs + .env.template), defaults preserve current behavior (lockout OFF by default):
   account_lockout_enabled: bool, false, def, false;
   account_lockout_max_attempts: i32, false, def, 5;
   account_lockout_cooldown_seconds: i64, false, def, 900;
4. Extract a PURE decision function in a new module src/audit/lockout.rs (or src/db/models/user.rs helper) e.g. \`fn lockout_decision(failed_count: i32, max_attempts: i32, locked_until: Option<NaiveDateTime>, now: NaiveDateTime) -> Decision\` returning whether currently locked, and after a failure whether to lock. Unit-test it (TDD first).
5. Wire into the PASSWORD login path. Find _password_login / password_login in src/api/identity.rs.
   - BEFORE verifying the password / issuing tokens: if account_lockout_enabled && user.locked_until is Some(t) && t > now -> reject login with an error (and crate::audit::emit_named("user.login.locked", Some(user_id), ip)).
   - On a FAILED password: increment user.failed_login_count; if it reaches max_attempts, set user.locked_until = now + cooldown, reset count to 0, save user, and crate::audit::emit_named("user.locked", Some(user_id), ip).
   - On SUCCESSFUL login: if failed_login_count>0 or locked_until.is_some(), reset both to 0/None and save.
   Keep edits minimal and clearly commented as NIST AC-7.
Verify \`cargo check --features sqlite\` passes and the lockout unit test passes.
`, { schema: SLICE_SCHEMA, label: 'slice3-lockout', phase: 'Slice 3: AC-7 lockout' }) : null

phase('Slice 4: AC-8 login banner')
const s4 = await agent(`${COMMON}
SLICE 4 — AC-8 system-use notification (login banner). See CONTEXT.md.

1. Config key (src/config.rs + .env.template): \`login_banner: String, true, option;\` (Option, empty/unset by default => no banner; preserves current behavior).
2. Surface it in the most visible SAFE way without breaking clients:
   - Expose it in the server config endpoint that clients fetch (find GET /config or /api/config, likely in src/api/core/mod.rs or src/api/mod.rs) by adding a field like "loginBanner" only when set. Do not remove or rename existing fields.
   - If there is an /admin login template (src/static/templates/admin/login.hbs or similar), render the banner above the login form when set.
3. Unit test: a pure helper that returns the banner JSON fragment given Some/None, or test the config accessor wiring.
Verify \`cargo check --features sqlite\` passes.
Note in your result exactly where you surfaced the banner.
`, { schema: SLICE_SCHEMA, label: 'slice4-banner', phase: 'Slice 4: AC-8 login banner' })

phase('Slice 5: AC-11/12 session')
const s5 = await agent(`${COMMON}
SLICE 5 — AC-11/AC-12 session timeout knobs. See docs/adr/0004. CRITICAL: defaults MUST preserve today's behavior (no random sign-outs).

In src/auth.rs the statics are: BW_EXPIRATION (5m), DEFAULT_REFRESH_VALIDITY (30 days), MOBILE_REFRESH_VALIDITY (90 days), DEFAULT_ACCESS_VALIDITY (2h).
1. Config keys (src/config.rs + .env.template), defaults EQUAL current values:
   session_refresh_validity_days: i64, false, def, 30;
   session_mobile_refresh_validity_days: i64, false, def, 90;
   session_idle_timeout_minutes: i64, false, option;   // unset => idle timeout OFF (current behavior)
2. Replace the places that USE DEFAULT_REFRESH_VALIDITY / MOBILE_REFRESH_VALIDITY with values derived from config (keep the consts as fallback). Find their usages (grep DEFAULT_REFRESH_VALIDITY / MOBILE_REFRESH_VALIDITY).
3. Optional idle timeout in auth::refresh_tokens: if session_idle_timeout_minutes is Some(m), and the device's last-use timestamp (device.updated_at) is older than m minutes, reject the refresh (force re-login). When unset, behavior is unchanged. Device.updated_at is updated on refresh (see refresh_login in identity.rs). Emit nothing or crate::audit::emit_named("user.session.idle_timeout", ...) if slice 1 is present (guard with cfg/availability — if unsure, skip the audit call).
4. Extract a PURE function \`fn idle_expired(last_used: NaiveDateTime, idle_minutes: Option<i64>, now: NaiveDateTime) -> bool\` and unit-test it (must return false when idle_minutes is None).
Verify \`cargo check --features sqlite\` passes and the idle unit test passes. Confirm in notes that defaults preserve 30/90-day + idle-off behavior.
`, { schema: SLICE_SCHEMA, label: 'slice5-session', phase: 'Slice 5: AC-11/12 session' })

phase('Security review')
const diffSummary = [s1, s2, s3, s4, s5].map((s, i) => `Slice ${i + 1}: ok=${s?.ok} build=${s?.build_passed} files=${(s?.files_changed || []).join(', ')} notes=${s?.notes || ''}`).join('\n')
const review = await agent(`You are a security reviewer for a Vaultwarden fork hardened toward NIST 800-53B Moderate.
Run \`git -C /home/phurd/GitHub/VaultWarden diff\` (and check new untracked files via git status) to see ALL changes from the 5 slices below, then adversarially review.

${diffSummary}

Check specifically:
1. SECRET LEAKS: does the audit emitter or any new log line ever output a password, master-password hash, token, ADMIN_TOKEN, refresh token, or private key? It must not.
2. AC-7 lockout: can it be BYPASSED (login succeeds while locked)? Does it create an unbounded DoS (no auto-unlock)? Does success correctly reset the counter? Is the pre-check before token issuance?
3. SESSION defaults: confirm refresh validity defaults to 30/90 days and idle timeout defaults OFF — i.e. zero behavior change unless an operator opts in (hard project constraint: "don't sign me out randomly").
4. Migration safety: are the new columns nullable/defaulted so existing rows and all 3 backends migrate cleanly? down.sql present?
5. Additive discipline: are edits to existing upstream files minimal hook points (ADR-0001)? Flag any large inline rewrites.
6. Does \`cargo check --features sqlite\` currently pass? Run it.
Report findings as a prioritized list (CRITICAL/HIGH/MEDIUM/LOW) with file:line and a concrete fix for each. If clean, say so explicitly.`, { label: 'security-review', phase: 'Security review' })

return { slices: { s1, s2, s3, s4, s5 }, review }
