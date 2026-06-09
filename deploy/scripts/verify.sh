#!/usr/bin/env bash
# Acceptance checks for the deployed stack (maps to handoff Workstream 13).
# Run after the stack is up. Override BASE/CACERT for your environment.
set -uo pipefail

BASE="${BASE:-https://vaultwarden.example.com:8443}"
RESOLVE="${RESOLVE:-}"            # e.g. "vaultwarden.example.com:8443:127.0.0.1"
CACERT="${CACERT:-$HOME/vaultwarden/tls/ca/internal-ca.crt}"
CURL=(curl -sS --max-time 10)
[[ -f "$CACERT" ]] && CURL+=(--cacert "$CACERT")
[[ -n "$RESOLVE" ]] && CURL+=(--resolve "$RESOLVE")

pass=0 fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== TLS reachable =="
code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/alive" 2>/dev/null)"
[[ "$code" =~ ^(200|404)$ ]] && ok "HTTPS endpoint responds ($code)" || bad "endpoint not reachable ($code)"

echo "== Public registration disabled (NIST AC) =="
reg="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST "$BASE/identity/accounts/register" \
	-H 'Content-Type: application/json' -d '{"email":"probe@example.com","masterPasswordHash":"x"}' 2>/dev/null)"
[[ "$reg" != "200" ]] && ok "registration refused ($reg)" || bad "registration ACCEPTED — signups not disabled"

echo "== WebSocket upgrade returns 101 (NIST functional) =="
ws="$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
	-H 'Connection: Upgrade' -H 'Upgrade: websocket' \
	-H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
	"$BASE/notifications/hub" 2>/dev/null)"
[[ "$ws" == "101" ]] && ok "WebSocket upgrade -> 101" || bad "WebSocket upgrade did not return 101 ($ws)"

echo "== Audit log emitting (NIST AU) =="
"${CURL[@]}" -o /dev/null "$BASE/admin" 2>/dev/null || true
if podman logs vaultwarden 2>&1 | grep -q 'vaultwarden::audit'; then
	ok "audit records present on vaultwarden::audit target"
else
	echo "  WARN: no audit lines yet (trigger a login, then re-check 'podman logs vaultwarden')"
fi

echo "== PostgreSQL not published to host (NIST SC) =="
if podman port vw-postgres 2>/dev/null | grep -q .; then
	bad "postgres has a published host port"
else
	ok "postgres has no host port mapping"
fi

echo
echo "Result: $pass passed, $fail failed."
[[ "$fail" -eq 0 ]]
