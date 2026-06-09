# Wazuh log shipping + alerting for Vaultwarden (NIST 800-53B Moderate)

Adds **AU-6** (log review/forwarding), **SI-4** (monitoring), and **IR-4**
(incident handling input) to the hardened podman stack by shipping the
`nextvault::audit` JSON, Caddy JSON access logs, and PostgreSQL logs to an
external **Wazuh manager**, which runs the decoders/rules in this directory and
raises alerts.

```
  nextvault    ┐
  nextvault-caddy     ├─ stdout ─▶ host journald ─▶ wazuh-agent (sidecar) ──TCP 1514──▶ Wazuh manager
  nextvault-postgres  ┘                              reads journald,            (decoders+rules+alerts)
                                              forwards by CONTAINER_NAME
```

The **manager lives OUTSIDE this host** (your central SIEM/SOC box). Only the
**agent** runs here, on the *edge* network (egress only — never the internal DB
network, per SC-7). If the manager is unreachable the agent buffers locally and
the app keeps serving (AU-5 graceful degradation).

## Files

| File | Deploys to | Purpose |
|---|---|---|
| `wazuh-agent.container` | `~/.config/containers/systemd/` (this host) | Agent sidecar quadlet |
| `wazuh-agent.env` | `~/vaultwarden/wazuh/` (this host) | Manager address + agent identity (non-secret) |
| `ossec.conf` | `~/vaultwarden/wazuh/` → mounted into agent | Agent log sources + transport |
| `local_decoder.xml` | **manager** `/var/ossec/etc/decoders/` | Parse Postgres text lines |
| `local_rules.xml` | **manager** `/var/ossec/etc/rules/` | Raise the alerts below |

## Log path strategy (decision)

**Chosen: journald.** Switch the three app containers to `LogDriver=journald`
and have the agent read the host journal, filtering by `CONTAINER_NAME`. This is
simpler and more robust than bind-mounting `~/.local/share/containers/.../`
JSON log files (whose paths are container-id-keyed and rotate), and it keeps the
agent read-only against the log source.

### Required (NOT applied) change to the app/caddy/postgres quadlets

These quadlets live outside `deploy/wazuh/` so this slice does **not** edit them.
Before enabling the agent, add one line to the `[Container]` section of each of
`deploy/quadlet/nextvault.container`, `nextvault-caddy.container`, and
`nextvault-postgres.container`:

```ini
LogDriver=journald
```

(Podman's default rootless driver is usually `journald` already; setting it
explicitly is config-as-code per CM and guarantees the agent's journald reader
sees the streams. After editing, re-run `deploy/scripts/install.sh` and
`systemctl --user daemon-reload`, then restart the stack.)

### Rootless vs rootful journald

- **Rootful** quadlets (`/etc/containers/systemd/`): container logs go to the
  **system** journal under `/var/log/journal` — the agent mounts work as written.
- **Rootless** quadlets (`~/.config/containers/systemd/`, the default here):
  logs go to the **user** journal. Either (a) run the agent rootful so it can
  read the system journal, or (b) set `Storage=persistent` +
  `journalctl --user` semantics and bind the user journal path
  (`~/.local/share/...` / `/run/user/<uid>/...`) instead of `/var/log/journal`
  in `wazuh-agent.container`. Pick one to match how the rest of the stack runs.

## Enroll / register the agent

```bash
# 1. Provide the manager address + agent identity (EDIT all values).
#    install.sh copies this repo's deploy/wazuh/ to ~/vaultwarden/wazuh/.
$EDITOR ~/vaultwarden/wazuh/wazuh-agent.env

# 2. Create the enrollment-key secret (the manager's shared registration
#    password). NIST IA-5: the key never lands in a quadlet or in git.
printf '%s' '<SHARED_ENROLLMENT_PASSWORD_FROM_MANAGER>' \
  | podman secret create vw_wazuh_enrollment_key -

# 3. (External change, see above) add LogDriver=journald to the three app
#    quadlets, re-run install.sh, daemon-reload, restart the stack.

# 4. Install + start the agent.
systemctl --user daemon-reload
systemctl --user start wazuh-agent.service
systemctl --user status wazuh-agent.service

# 5. Confirm enrollment on the MANAGER:
/var/ossec/bin/manage_agents -l        # the agent should appear "Active"

# 6. Deploy the decoders/rules to the MANAGER, then restart it:
cp local_decoder.xml /var/ossec/etc/decoders/local_decoder.xml
cp local_rules.xml   /var/ossec/etc/rules/local_rules.xml
/var/ossec/bin/wazuh-control restart
```

## Time sync (REQUIRED for AU)

Audit value depends on accurate, correlatable timestamps (NIST **AU-8**). The
app stamps `ts` in UTC RFC3339; Wazuh stamps its own receive time. **Run NTP on
both this host and the manager** (e.g. `chronyd` synced to the same source) so
the frequency/timeframe rules (admin/user brute force, DB brute force) count
events in the correct window and alert timelines line up with the audit `ts`.

```bash
sudo systemctl enable --now chronyd
chronyc tracking      # confirm "Leap status : Normal" and small offset
```

## Alert → NIST control mapping

| Rule ID | Level | Alert | Source event | NIST control |
|---|---|---|---|---|
| 100001 | 6 | `/admin` login success | `admin.login.success` | AC-6, AU-2 |
| 100002 | 10 | `/admin` login failure | `admin.login.failure` | AC-7, AU-6 |
| 100003 | 13 | `/admin` brute force (5/5m) | repeated `admin.login.failure` | AC-7, SI-4 |
| 100004 | 9 | Admin config changed (registration/invitation) | `admin.config.changed` | CM-3, CM-6 |
| 100010 | 10 | Account lockout reached | `user.locked` | AC-7 |
| 100011 | 7 | Login attempt on locked account | `user.login.locked` | AC-7 |
| 100020 | 4 | User failed login (single) | `user_failed_login` | AC-7 |
| 100021 | 12 | User-login brute force (8/2m) | volume of `user_failed_login` | AC-7, SI-4 |
| 100030 | 5 | Session idle timeout | `user.session.idle_timeout` | AC-12 |
| 100101 | 5 | `/admin` accessed via proxy | Caddy JSON access log | AC-6, SC-7 |
| 100102 | 9 | `/admin` denied by allowlist (403) | Caddy JSON, `status=403` | AC-6, SC-7 |
| 100201 | 10 | DB authentication failure | Postgres `FATAL ... password` | AC-7, IA-5 |
| 100202 | 13 | DB auth brute force (5/2m) | volume of 100201 | AC-7, SI-4 |
| 100203 | 9 | DB connection rejected by pg_hba | Postgres `FATAL no pg_hba / client cert` | SC-7, SC-8 |

Base/correlation rules `100000` (audit JSON), `100100` (Caddy `/admin`),
`100200` (Postgres line) are level 0 (no alert; selectors for the children).

## Test that each alert fires (acceptance: "alerts fire during test events")

Watch alerts on the **manager** while triggering each event:

```bash
# On the manager, tail JSON alerts (or use the Wazuh dashboard "Security alerts").
tail -f /var/ossec/logs/alerts/alerts.json | grep -Eo '"id":"10[0-9]{4}"'
```

| Rule | How to trigger from a client |
|---|---|
| 100002 / 100003 | Hit `/admin` with a wrong token 1×, then 5× within 5 min |
| 100001 | Log in to `/admin` with the correct token |
| 100004 | In `/admin`, change *Allow new signups* / invitations and Save |
| 100020 / 100021 | Fail user login 1×, then 8× in 2 min from the same IP |
| 100010 / 100011 | Fail one user's login past `LOCKOUT_MAX_RETRIES`; then try again while locked |
| 100030 | Stay idle past `SESSION_IDLE_TIMEOUT_MINUTES`, then make a request |
| 100101 / 100102 | `curl -k https://<host>:8443/admin` from an allowed IP (→100101) and from an IP outside the Caddy allowlist (→100102, 403) |
| 100201 / 100202 | `psql 'host=nextvault-postgres user=vaultwarden ...'` with a wrong password 1×, then 5× in 2 min (run from a container on the internal net) |
| 100203 | Attempt a non-TLS connection to Postgres (rejected by `pg_hba` `hostssl`) |

Each test event should produce a matching alert id in `alerts.json` (or the
dashboard) within the agent's `notify_time` (30s). If an audit event does not
appear, confirm `AUDIT_LOG_ENABLED=true` in `vaultwarden.env`, that the app
quadlet has `LogDriver=journald`, and that `CONTAINER_NAME` filters in
`ossec.conf` match the actual container names (`nextvault`, `nextvault-caddy`,
`nextvault-postgres`).

## Notes / gotchas

- **Image pinning (CM-2/SR):** replace `wazuh/wazuh-agent:4.9.2` with
  `...@sha256:...` and match the agent minor version to your manager.
- **Manager-side custom files:** `local_decoder.xml` / `local_rules.xml` are
  evaluated on the **manager**, not the agent — copying them only into the agent
  has no effect.
- **No secrets in logs:** the audit module never serializes secrets; rules only
  reference metadata (event_name, user_uuid, ip), so alerts are safe to forward.
- **`same_field` support:** the frequency rules use `<same_field>` (Wazuh ≥ 4.x).
  On older managers substitute `<same_source_ip/>` where the field is `ip`.
